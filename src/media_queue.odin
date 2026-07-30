package main

import "core:sync"
import "core:time"
import task_queue "task_queue:."

MEDIA_QUEUE_CONCURRENCY :: 4
MEDIA_DOWNLOAD_CONCURRENCY :: 2
MEDIA_EXPORT_CONCURRENCY :: 2

Media_Task_Completion :: struct {
	mutex: sync.Mutex,
	condition: sync.Cond,
	processed: bool,
}

media_task_completion_finish :: proc(completion: ^Media_Task_Completion) {
	sync.mutex_lock(&completion.mutex)
	completion.processed = true
	sync.cond_broadcast(&completion.condition)
	sync.mutex_unlock(&completion.mutex)
}

media_task_completion_processed :: proc(
	completion: ^Media_Task_Completion,
) -> bool {
	sync.mutex_lock(&completion.mutex)
	processed := completion.processed
	sync.mutex_unlock(&completion.mutex)
	return processed
}

media_task_completion_wait :: proc(
	completion: ^Media_Task_Completion,
) -> bool {
	for {
		sync.mutex_lock(&completion.mutex)
		if completion.processed {
			sync.mutex_unlock(&completion.mutex)
			return true
		}
		_ = sync.cond_wait_with_timeout(
			&completion.condition,
			&completion.mutex,
			10 * time.Millisecond,
		)
		processed := completion.processed
		sync.mutex_unlock(&completion.mutex)
		if processed {
			return true
		}
		if media_queue_is_shutting_down() {
			return false
		}
	}
}

Media_Task_Class :: enum {
	Download,
	Export,
}

Media_Task_Policy_Data :: struct {
	class:        Media_Task_Class,
	barrier:      bool,
	resource_key: u64,
}

Media_Queue_Policy_State :: struct {
	active_downloads: int,
	active_exports:   int,
	barrier_active:   bool,
	active_resources: [MEDIA_QUEUE_CONCURRENCY]u64,
	active_resource_count: int,
}

media_queue: task_queue.Queue
media_queue_initialized: bool
media_queue_shutting_down: bool
media_queue_state_mutex: sync.Mutex
media_queue_policy_state: Media_Queue_Policy_State
import_jobs: [dynamic]^Import_Job
import_completed_jobs: [dynamic]^Import_Job
import_completion_mutex: sync.Mutex

media_queue_is_shutting_down :: proc() -> bool {
	sync.mutex_lock(&media_queue_state_mutex)
	shutting_down := media_queue_shutting_down
	sync.mutex_unlock(&media_queue_state_mutex)
	return shutting_down
}

media_queue_begin_shutdown :: proc() {
	sync.mutex_lock(&media_queue_state_mutex)
	media_queue_shutting_down = true
	sync.mutex_unlock(&media_queue_state_mutex)
}

media_queue_policy_encode :: proc(
	class: Media_Task_Class,
	barrier := false,
	resource_key: u64 = 0,
) -> rawptr {
	value := u64(class) |
	         (barrier ? u64(1) << 1 : 0) |
	         (resource_key & ((u64(1) << 62) - 1)) << 2
	return rawptr(uintptr(value))
}

media_queue_policy_data :: proc(
	item: task_queue.Policy_Item,
) -> Media_Task_Policy_Data {
	value := u64(uintptr(item.policy_data))
	return {
		class = Media_Task_Class(value & 1),
		barrier = value & (u64(1) << 1) != 0,
		resource_key = value >> 2,
	}
}

media_queue_resource_active :: proc(
	policy: ^Media_Queue_Policy_State,
	resource_key: u64,
) -> bool {
	if resource_key == 0 {
		return false
	}
	for active in policy.active_resources[:policy.active_resource_count] {
		if active == resource_key {
			return true
		}
	}
	return false
}

media_queue_resource_key :: proc(
	workflow: Workflow_Kind,
	video_id: string,
) -> u64 {
	if len(video_id) == 0 {
		return 0
	}
	hash := u64(14695981039346656037)
	hash = (hash ~ u64(workflow)) * 1099511628211
	for byte in transmute([]u8)video_id {
		hash = (hash ~ u64(byte)) * 1099511628211
	}
	if hash == 0 {
		return 1
	}
	return hash
}

media_queue_policy_select :: proc(
	items: []task_queue.Policy_Item,
	snapshot: task_queue.Queue_Snapshot,
	data: rawptr,
) -> int {
	policy := (^Media_Queue_Policy_State)(data)
	if policy.barrier_active {
		return -1
	}
	earliest_barrier_sequence: u64
	has_earlier_waiting := false
	for item in items {
		task_data := media_queue_policy_data(item)
		if task_data.barrier &&
		   (earliest_barrier_sequence == 0 ||
		    item.sequence < earliest_barrier_sequence) {
			earliest_barrier_sequence = item.sequence
		}
	}
	if earliest_barrier_sequence != 0 {
		for item in items {
			if item.sequence < earliest_barrier_sequence {
				has_earlier_waiting = true
				break
			}
		}
		if !has_earlier_waiting && snapshot.running == 0 {
			for item, index in items {
				if item.sequence == earliest_barrier_sequence {
					return index
				}
			}
		}
	}
	selected := -1
	for item, index in items {
		if earliest_barrier_sequence != 0 &&
		   item.sequence >= earliest_barrier_sequence {
			continue
		}
		task_data := media_queue_policy_data(item)
		if media_queue_resource_active(
			policy,
			task_data.resource_key,
		) {
			continue
		}
		if task_data.class == .Download &&
		   policy.active_downloads >= MEDIA_DOWNLOAD_CONCURRENCY {
			continue
		}
		if task_data.class == .Export &&
		   policy.active_exports >= MEDIA_EXPORT_CONCURRENCY {
			continue
		}
		if selected < 0 ||
		   item.priority > items[selected].priority ||
		   item.priority == items[selected].priority &&
		   item.sequence < items[selected].sequence {
			selected = index
		}
	}
	return selected
}

media_queue_policy_notify :: proc(
	transition: task_queue.Policy_Transition,
	item: task_queue.Policy_Item,
	data: rawptr,
) {
	policy := (^Media_Queue_Policy_State)(data)
	task_data := media_queue_policy_data(item)
	change := 1
	if transition == .Finished {
		change = -1
	}
	if task_data.class == .Download {
		policy.active_downloads += change
	} else {
		policy.active_exports += change
	}
	if task_data.resource_key != 0 {
		if transition == .Activated {
			assert(
				policy.active_resource_count <
				len(policy.active_resources),
			)
			policy.active_resources[policy.active_resource_count] =
				task_data.resource_key
			policy.active_resource_count += 1
		} else {
			for resource, index in
			    policy.active_resources[:policy.active_resource_count] {
				if resource != task_data.resource_key {
					continue
				}
				policy.active_resource_count -= 1
				policy.active_resources[index] =
					policy.active_resources[policy.active_resource_count]
				policy.active_resources[policy.active_resource_count] = 0
				break
			}
		}
	}
	if task_data.barrier {
		policy.barrier_active = transition == .Activated
	}
}

media_queue_init :: proc() -> bool {
	if media_queue_initialized {
		return true
	}
	media_queue_policy_state = {}
	media_queue_shutting_down = false
	init_error := task_queue.queue_init(
		&media_queue,
		{
			concurrency = MEDIA_QUEUE_CONCURRENCY,
			policy = {
				select_procedure = media_queue_policy_select,
				notify_procedure = media_queue_policy_notify,
				data = &media_queue_policy_state,
			},
		},
	)
	media_queue_initialized = init_error == .None
	return media_queue_initialized
}

media_queue_import_cancel :: proc(data: rawptr) {
	import_job_cancel((^Import_Job)(data))
}

media_queue_import_finalize :: proc(data: rawptr) {
	job := (^Import_Job)(data)
	if media_task_completion_processed(&job.completion) {
		import_job_destroy(job)
	}
}

media_queue_import_task :: proc(
	task_context: ^task_queue.Task_Context,
) -> task_queue.Task_Outcome {
	job := (^Import_Job)(task_context.data)
	import_job_execute(job)
	if media_queue_is_shutting_down() {
		return {}
	}
	sync.mutex_lock(&import_completion_mutex)
	append(&import_completed_jobs, job)
	sync.mutex_unlock(&import_completion_mutex)
	msg_void_sel_id_b(
		job.completion_target,
		sel_registerName("performSelectorOnMainThread:withObject:waitUntilDone:"),
		sel_registerName("importFinished:"),
		nil,
		false,
	)
	_ = media_task_completion_wait(&job.completion)
	return {}
}

media_queue_export_task :: proc(
	task_context: ^task_queue.Task_Context,
) -> task_queue.Task_Outcome {
	job := (^Export_Job)(task_context.data)
	job.success = export_job_execute(job)
	if media_queue_is_shutting_down() {
		return {}
	}
	sync.mutex_lock(&export_completion_mutex)
	append(&export_completed_jobs, job)
	sync.mutex_unlock(&export_completion_mutex)
	msg_void_sel_id_b(
		job.completion_target,
		sel_registerName("performSelectorOnMainThread:withObject:waitUntilDone:"),
		sel_registerName("exportFinished:"),
		nil,
		false,
	)
	_ = media_task_completion_wait(&job.completion)
	return {}
}

media_queue_export_finalize :: proc(data: rawptr) {
	job := (^Export_Job)(data)
	if media_task_completion_processed(&job.completion) {
		export_job_destroy(job)
	}
}

media_queue_probe_task :: proc(
	task_context: ^task_queue.Task_Context,
) -> task_queue.Task_Outcome {
	job := (^Source_Probe_Job)(task_context.data)
	source_probe_execute(job)
	if media_queue_is_shutting_down() {
		return {}
	}
	msg_void_sel_id_b(
		job.completion_target,
		sel_registerName("performSelectorOnMainThread:withObject:waitUntilDone:"),
		sel_registerName("sourceProbeFinished:"),
		nil,
		false,
	)
	_ = media_task_completion_wait(&job.completion)
	return {}
}

media_queue_probe_cancel :: proc(data: rawptr) {
	source_probe_job_cancel((^Source_Probe_Job)(data))
}

media_queue_probe_finalize :: proc(data: rawptr) {
	job := (^Source_Probe_Job)(data)
	if media_task_completion_processed(&job.completion) {
		source_probe_job_destroy(job)
	}
}

media_queue_library_replacement_finalize :: proc(data: rawptr) {
	job := (^Library_Replacement_Job)(data)
	if media_task_completion_processed(&job.completion) {
		library_replacement_job_destroy(job)
	}
}

media_queue_library_replacement_task :: proc(
	task_context: ^task_queue.Task_Context,
) -> task_queue.Task_Outcome {
	job := (^Library_Replacement_Job)(task_context.data)
	if media_queue_is_shutting_down() {
		return {}
	}
	msg_void_sel_id_b(
		state.delegate_target,
		sel_registerName("performSelectorOnMainThread:withObject:waitUntilDone:"),
		sel_registerName("libraryReplacementReady:"),
		nil,
		false,
	)
	_ = media_task_completion_wait(&job.completion)
	return {}
}

media_queue_schedule_import :: proc(
	job: ^Import_Job,
	barrier := false,
) -> bool {
	if job == nil || !media_queue_initialized {
		return false
	}
	resource_key: u64
	if !barrier {
		video_id, valid := parse_video_id(job.input)
		if valid {
			resource_key = media_queue_resource_key(
				job.workflow,
				video_id,
			)
		}
	}
	id, add_error := task_queue.add(
		&media_queue,
		{
			procedure = media_queue_import_task,
			data = job,
			cancel_procedure = media_queue_import_cancel,
			finalize_procedure = media_queue_import_finalize,
			policy_data = media_queue_policy_encode(
				.Download,
				barrier,
				resource_key,
			),
			release_on_finish = true,
			label = "Download source",
		},
	)
	if add_error != .None {
		return false
	}
	job.task_id = id
	append(&import_jobs, job)
	return true
}

media_queue_schedule_export :: proc(
	job: ^Export_Job,
	barrier := false,
) -> bool {
	if job == nil || !media_queue_initialized {
		return false
	}
	id, add_error := task_queue.add(
		&media_queue,
		{
			procedure = media_queue_export_task,
			data = job,
			cancel_procedure = media_queue_export_cancel,
			finalize_procedure = media_queue_export_finalize,
			policy_data = media_queue_policy_encode(.Export, barrier),
			release_on_finish = true,
			label = "Export clip",
		},
	)
	if add_error != .None {
		return false
	}
	job.task_id = id
	export_jobs_add(job)
	return true
}

media_queue_export_cancel :: proc(data: rawptr) {
	export_job_cancel((^Export_Job)(data))
}

media_queue_schedule_probe :: proc(job: ^Source_Probe_Job) -> bool {
	if job == nil || !media_queue_initialized {
		return false
	}
	id, add_error := task_queue.add(
		&media_queue,
		{
			procedure = media_queue_probe_task,
			data = job,
			cancel_procedure = media_queue_probe_cancel,
			finalize_procedure = media_queue_probe_finalize,
			policy_data = media_queue_policy_encode(.Download),
			release_on_finish = true,
			label = "Check source metadata",
		},
	)
	if add_error != .None {
		return false
	}
	job.task_id = id
	return true
}

media_queue_cancel_probe :: proc(job: ^Source_Probe_Job) -> bool {
	if job == nil || !media_queue_initialized {
		return false
	}
	previous_state, changed := task_queue.cancel_with_state(
		&media_queue,
		job.task_id,
	)
	if !changed {
		return false
	}
	if previous_state == .Waiting {
		source_probe_job_cancel(job)
		if source_probe_job == job {
			source_probe_job = nil
		}
		_ = notification_finish(
			job.notification_id,
			.Interrupted,
			"Metadata check stopped",
		)
		media_task_completion_finish(&job.completion)
		source_probe_job_destroy(job)
		ui.needs_redraw = true
	}
	return true
}

media_queue_schedule_library_replacement :: proc(
	job: ^Library_Replacement_Job,
) -> bool {
	if job == nil || !media_queue_initialized {
		return false
	}
	id, add_error := task_queue.add(
		&media_queue,
		{
			procedure = media_queue_library_replacement_task,
			data = job,
			finalize_procedure =
				media_queue_library_replacement_finalize,
			policy_data = media_queue_policy_encode(
				.Download,
				barrier = true,
			),
			release_on_finish = true,
			label = "Replace library",
		},
	)
	if add_error != .None {
		return false
	}
	job.task_id = id
	return true
}

media_queue_cancel :: proc(id: task_queue.Task_ID) -> bool {
	if !media_queue_initialized || id == 0 {
		return false
	}
	return task_queue.cancel(&media_queue, id)
}

media_queue_cancel_import :: proc(job: ^Import_Job) -> bool {
	if job == nil || !media_queue_initialized {
		return false
	}
	previous_state, changed := task_queue.cancel_with_state(
		&media_queue,
		job.task_id,
	)
	if !changed {
		return false
	}
	if previous_state == .Waiting {
		import_job_cancel(job)
		finish_import_job(job)
		import_job_destroy(job)
	}
	return true
}

media_queue_cancel_export :: proc(job: ^Export_Job) -> bool {
	if job == nil || !media_queue_initialized {
		return false
	}
	previous_state, changed := task_queue.cancel_with_state(
		&media_queue,
		job.task_id,
	)
	if !changed {
		return false
	}
	if previous_state == .Waiting {
		export_job_cancel(job)
		if export_jobs_remove(job) {
			finish_export_job(job)
			media_task_completion_finish(&job.completion)
			export_job_destroy(job)
		}
	}
	return true
}

media_queue_cancel_library_replacement :: proc(
	job: ^Library_Replacement_Job,
) -> bool {
	if job == nil || !media_queue_initialized {
		return false
	}
	previous_state, changed := task_queue.cancel_with_state(
		&media_queue,
		job.task_id,
	)
	if !changed {
		return false
	}
	job.cancelled = true
	if previous_state == .Waiting {
		library_replacement_job = nil
		finish_library_replacement_job(job)
		media_task_completion_finish(&job.completion)
		library_replacement_job_destroy(job)
	}
	return true
}

media_queue_release :: proc(id: task_queue.Task_ID) {
	if media_queue_initialized && id != 0 {
		_ = task_queue.release(&media_queue, id)
	}
}

import_jobs_remove :: proc(job: ^Import_Job) -> bool {
	for candidate, index in import_jobs {
		if candidate != job {
			continue
		}
		last := pop(&import_jobs)
		if index < len(import_jobs) {
			import_jobs[index] = last
		}
		return true
	}
	return false
}

import_jobs_any :: proc() -> bool {
	return len(import_jobs) > 0
}

import_job_for_notification :: proc(notification_id: i64) -> ^Import_Job {
	for job in import_jobs {
		if job.notification_id == notification_id {
			return job
		}
	}
	return nil
}

export_job_for_notification :: proc(notification_id: i64) -> ^Export_Job {
	for job in export_jobs {
		if job.notification_id == notification_id {
			return job
		}
	}
	return nil
}
