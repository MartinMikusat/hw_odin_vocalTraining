package main

import "core:fmt"
import "core:math"
import os "core:os/old"
import "core:strings"
import "base:runtime"
import task_queue "task_queue:."

BPM_DETECTOR_REVISION :: 2
BPM_AUTO_APPLY_MIN_CONFIDENCE :: 0.35

BPM_Runtime_State :: enum {
	Idle,
	Analyzing,
	Ready,
	Low_Confidence,
	No_Audio,
	Unavailable,
	Cancelled,
}

BPM_Runtime_Result :: struct {
	clip_id: string,
	clip_path: string,
	state: BPM_Runtime_State,
	estimate: BPM_Estimate,
}

BPM_Job :: struct {
	task_id: task_queue.Task_ID,
	completion_target: Id,
	clip_id: string,
	clip_path: string,
	detector_revision: int,
	cancellation: BPM_Cancellation_Token,
	status: BPM_Analysis_Status,
	estimate: BPM_Estimate,
	completion: Media_Task_Completion,
}

bpm_job: ^BPM_Job
bpm_runtime_result: BPM_Runtime_Result

bpm_runtime_result_clear :: proc() {
	delete(bpm_runtime_result.clip_id)
	delete(bpm_runtime_result.clip_path)
	bpm_runtime_result = {}
}

bpm_runtime_result_set :: proc(
	clip_id: string,
	clip_path: string,
	state_value: BPM_Runtime_State,
	estimate: BPM_Estimate = {},
) -> bool {
	clip_id_copy, error := strings.clone(clip_id)
	if error != nil {return false}
	clip_path_copy, path_error := strings.clone(clip_path)
	if path_error != nil {
		delete(clip_id_copy)
		return false
	}
	bpm_runtime_result_clear()
	bpm_runtime_result = {
		clip_id = clip_id_copy,
		clip_path = clip_path_copy,
		state = state_value,
		estimate = estimate,
	}
	return true
}

bpm_runtime_result_matches_clip :: proc(clip: ^Clip) -> bool {
	return clip != nil &&
	       bpm_runtime_result.clip_id == clip.id &&
	       bpm_runtime_result.clip_path == clip.clip_path &&
	       bpm_runtime_result.state != .Idle &&
	       bpm_runtime_result.state != .Cancelled
}

bpm_confidence_label :: proc(confidence: f32) -> string {
	if confidence >= 0.65 {return "HIGH"}
	if confidence >= BPM_AUTO_APPLY_MIN_CONFIDENCE {return "MEDIUM"}
	return "LOW"
}

bpm_runtime_status_text :: proc(
	result: BPM_Runtime_Result,
	clip: ^Clip,
) -> string {
	if clip == nil || result.clip_id != clip.id || result.clip_path != clip.clip_path {
		return "AUTO / WAITING..."
	}
	switch result.state {
	case .Idle:           return "AUTO / WAITING..."
	case .Analyzing:      return "AUTO / ANALYZING..."
	case .Low_Confidence: return "AUTO / LOW CONFIDENCE"
	case .No_Audio:       return "AUTO / NO AUDIO"
	case .Unavailable:    return "AUTO / UNAVAILABLE"
	case .Cancelled:      return "AUTO / CANCELLED"
	case .Ready:
		if !result.estimate.valid {return "AUTO / LOW CONFIDENCE"}
		if result.estimate.alternative_count > 0 {
			return fmt.tprintf(
				"AUTO / %.0f OR %.0f",
				result.estimate.bpm,
				result.estimate.alternatives[0],
			)
		}
		return fmt.tprintf(
			"AUTO / %.0f BPM · %s",
			result.estimate.bpm,
			bpm_confidence_label(result.estimate.confidence),
		)
	}
	return "AUTO / UNAVAILABLE"
}

bpm_runtime_estimate_value :: proc(
	result: BPM_Runtime_Result,
	clip: ^Clip,
) -> (int, bool) {
	if clip == nil || result.clip_id != clip.id || result.clip_path != clip.clip_path ||
	   result.state != .Ready || !result.estimate.valid ||
	   result.estimate.bpm < 40 || result.estimate.bpm > 240 {
		return 0, false
	}
	return clamp(int(math.round(result.estimate.bpm)), 40, 240), true
}

bpm_job_destroy :: proc(job: ^BPM_Job) {
	if job == nil {return}
	delete(job.clip_id)
	delete(job.clip_path)
	free(job)
}

bpm_job_create :: proc(clip: ^Clip, completion_target: Id) -> (^BPM_Job, bool) {
	if clip == nil {return nil, false}
	job := new(BPM_Job)
	job.completion_target = completion_target
	job.detector_revision = BPM_DETECTOR_REVISION
	hw_bpm_cancellation_token_init(&job.cancellation)
	copied := false
	defer if !copied {bpm_job_destroy(job)}
	value, error := strings.clone(clip.id)
	if error != nil {return nil, false}
	job.clip_id = value
	value, error = strings.clone(clip.clip_path)
	if error != nil {return nil, false}
	job.clip_path = value
	copied = true
	return job, true
}

bpm_job_cancel :: proc(job: ^BPM_Job) {
	if job == nil {return}
	hw_bpm_cancellation_token_cancel(&job.cancellation)
}

bpm_job_execute :: proc(job: ^BPM_Job) {
	if job == nil {return}
	path := strings.clone_to_cstring(job.clip_path)
	defer delete(path)
	values: [^]f32
	count: uint
	rate_hz: f64
	job.status = hw_bpm_copy_onset_envelope(
		path,
		&job.cancellation,
		&values,
		&count,
		&rate_hz,
	)
	if values != nil {defer hw_bpm_free_onset_envelope(values)}
	if job.status != .OK || values == nil || count == 0 {return}
	job.estimate = estimate_bpm_from_onset_envelope(values[:count], rate_hz)
}

bpm_estimate_auto_applicable :: proc(estimate: BPM_Estimate) -> bool {
	return estimate.valid &&
	       estimate.confidence >= BPM_AUTO_APPLY_MIN_CONFIDENCE &&
	       estimate.alternative_count == 0 &&
	       estimate.bpm >= 40 && estimate.bpm <= 240
}

bpm_apply_estimate :: proc(clip: ^Clip, estimate: BPM_Estimate) -> bool {
	if clip == nil || clip.workflow != .Dancing || !estimate.valid ||
	   estimate.bpm < 40 || estimate.bpm > 240 ||
	   estimate.confidence < 0 || estimate.confidence > 1 {
		return false
	}
	clip.dance_detected_bpm = estimate.bpm
	clip.dance_bpm_confidence = estimate.confidence
	clip.dance_bpm_detector_revision = BPM_DETECTOR_REVISION
	if !clip.dance_bpm_user_set && bpm_estimate_auto_applicable(estimate) {
		clip.dance_count_in_bpm = clamp(int(math.round(estimate.bpm)), 40, 240)
		period := estimate.beat_period_seconds
		if period < 0.25 || period > 1.5 {period = 60.0 / estimate.bpm}
		clip.dance_beat_period_seconds = period
		if clip.dance_beat_phase_user_set {
			clip.dance_beat_grid_offset_seconds = bpm_normalize_grid_offset(
				clip.dance_beat_grid_offset_seconds,
				period,
			)
		} else if estimate.phase_valid {
			clip.dance_beat_grid_offset_seconds = estimate.beat_phase_seconds
			clip.dance_beat_phase_confidence = estimate.phase_confidence
		}
	}
	return true
}

bpm_clip_has_current_result :: proc(clip: ^Clip) -> bool {
	return clip != nil &&
	       clip.dance_bpm_detector_revision == BPM_DETECTOR_REVISION &&
	       bpm_persisted_detection_valid(
	        clip.dance_detected_bpm,
	        clip.dance_bpm_confidence,
	        clip.dance_bpm_detector_revision,
	       )
}

bpm_analysis_source_has_audio :: proc(clip: ^Clip) -> bool {
	if clip == nil {return false}
	index := source_index_for_id(state.sources[:], clip.source_id)
	return index >= 0 && state.sources[index].has_audio
}

bpm_analysis_schedule :: proc(clip: ^Clip) -> bool {
	if clip == nil || clip.workflow != .Dancing || bpm_job != nil ||
	   len(clip.id) == 0 || bpm_runtime_result_matches_clip(clip) {
		return false
	}
	if !bpm_analysis_source_has_audio(clip) {
		_ = bpm_runtime_result_set(clip.id, clip.clip_path, .No_Audio)
		return false
	}
	if len(clip.clip_path) == 0 || !os.exists(clip.clip_path) {
		_ = bpm_runtime_result_set(clip.id, clip.clip_path, .Unavailable)
		return false
	}
	if bpm_clip_has_current_result(clip) {
		_ = bpm_runtime_result_set(
			clip.id,
			clip.clip_path,
			.Ready,
			BPM_Estimate{
				bpm = clip.dance_detected_bpm,
				confidence = clip.dance_bpm_confidence,
				beat_period_seconds = clip.dance_beat_period_seconds,
				beat_phase_seconds = clip.dance_beat_grid_offset_seconds,
				phase_confidence = clip.dance_beat_phase_confidence,
				phase_valid = clip.dance_beat_phase_confidence >= BPM_PHASE_MIN_CONFIDENCE,
				valid = true,
			},
		)
		return false
	}
	job, created := bpm_job_create(clip, state.delegate_target)
	if !created {return false}
	bpm_job = job
	_ = bpm_runtime_result_set(clip.id, clip.clip_path, .Analyzing)
	if !media_queue_schedule_bpm(job) {
		bpm_job = nil
		_ = bpm_runtime_result_set(clip.id, clip.clip_path, .Unavailable)
		bpm_job_destroy(job)
		return false
	}
	ui.needs_redraw = true
	return true
}

bpm_analysis_maybe_schedule_active :: proc() {
	clip := active_dance_clip()
	if clip == nil {
		if bpm_job != nil {_ = media_queue_cancel_bpm(bpm_job)}
		return
	}
	if bpm_job != nil {
		if bpm_job.clip_id != clip.id || bpm_job.clip_path != clip.clip_path {
			_ = media_queue_cancel_bpm(bpm_job)
		}
		return
	}
	if bpm_runtime_result_matches_clip(clip) {return}
	_ = bpm_analysis_schedule(clip)
}

bpm_analysis_retry_active :: proc() -> bool {
	clip := active_dance_clip()
	if clip == nil {return false}
	if bpm_job != nil {_ = media_queue_cancel_bpm(bpm_job); return false}
	previous_detected := clip.dance_detected_bpm
	previous_confidence := clip.dance_bpm_confidence
	previous_revision := clip.dance_bpm_detector_revision
	previous_period := clip.dance_beat_period_seconds
	previous_grid := clip.dance_beat_grid_offset_seconds
	previous_phase_confidence := clip.dance_beat_phase_confidence
	clip.dance_detected_bpm = 0
	clip.dance_bpm_confidence = 0
	clip.dance_bpm_detector_revision = 0
	if !clip.dance_beat_phase_user_set {
		clip.dance_beat_grid_offset_seconds = 0
		clip.dance_beat_phase_confidence = 0
	}
	if !save_library() {
		clip.dance_detected_bpm = previous_detected
		clip.dance_bpm_confidence = previous_confidence
		clip.dance_bpm_detector_revision = previous_revision
		clip.dance_beat_period_seconds = previous_period
		clip.dance_beat_grid_offset_seconds = previous_grid
		clip.dance_beat_phase_confidence = previous_phase_confidence
		return false
	}
	bpm_runtime_result_clear()
	return bpm_analysis_schedule(clip)
}

on_bpm_analysis_finished :: proc "c" (self: Id, command: Sel, sender: Id) {
	context = runtime.default_context()
	job := bpm_job
	if job == nil {return}
	defer media_task_completion_finish(&job.completion)
	bpm_job = nil
	clip_index := -1
	for clip, index in state.clips {
		if clip.id == job.clip_id {clip_index = index; break}
	}
	if clip_index < 0 || state.clips[clip_index].clip_path != job.clip_path ||
	   job.detector_revision != BPM_DETECTOR_REVISION {
		bpm_runtime_result_clear()
		bpm_analysis_maybe_schedule_active()
		return
	}
	clip := &state.clips[clip_index]
	switch job.status {
	case .Cancelled:
		_ = bpm_runtime_result_set(job.clip_id, job.clip_path, .Cancelled)
	case .No_Audio:
		_ = bpm_runtime_result_set(job.clip_id, job.clip_path, .No_Audio)
	case .Unreadable:
		_ = bpm_runtime_result_set(job.clip_id, job.clip_path, .Unavailable)
	case .OK:
		if !job.estimate.valid {
			_ = bpm_runtime_result_set(job.clip_id, job.clip_path, .Low_Confidence)
			break
		}
		previous_detected := clip.dance_detected_bpm
		previous_confidence := clip.dance_bpm_confidence
		previous_revision := clip.dance_bpm_detector_revision
		previous_bpm := clip.dance_count_in_bpm
		previous_period := clip.dance_beat_period_seconds
		previous_grid := clip.dance_beat_grid_offset_seconds
		previous_phase_confidence := clip.dance_beat_phase_confidence
		if bpm_apply_estimate(clip, job.estimate) && save_library() {
			_ = bpm_runtime_result_set(job.clip_id, job.clip_path, .Ready, job.estimate)
		} else {
			clip.dance_detected_bpm = previous_detected
			clip.dance_bpm_confidence = previous_confidence
			clip.dance_bpm_detector_revision = previous_revision
			clip.dance_count_in_bpm = previous_bpm
			clip.dance_beat_period_seconds = previous_period
			clip.dance_beat_grid_offset_seconds = previous_grid
			clip.dance_beat_phase_confidence = previous_phase_confidence
			_ = bpm_runtime_result_set(job.clip_id, job.clip_path, .Unavailable)
		}
	}
	ui.needs_redraw = true
	bpm_analysis_maybe_schedule_active()
}
