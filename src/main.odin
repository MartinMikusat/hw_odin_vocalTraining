package main

import "core:fmt"
import "core:encoding/json"
import "core:math"
import "core:math/rand"
import "core:mem"
import os "core:os/old"
import os2 "core:os"

import "core:path/filepath"
import "core:strings"
import "core:thread"
import "core:sync"
import "base:runtime"
import mem_virtual "core:mem/virtual"
import match_sorter "match_sorter:."
import task_queue "task_queue:."

Id  :: rawptr
Sel :: rawptr

SEARCH_RESERVE_SIZE :: uint(64 * mem.Megabyte)
SEARCH_COMMIT_SIZE :: uint(64 * mem.Kilobyte)
MANAGED_HEVC_QUALITY :: 60
MANAGED_HEVC_CODEC :: "hevc"
MANAGED_HEVC_TAG :: "hvc1"

foreign import objc "system:objc"
foreign objc {
	objc_getClass           :: proc "c" (name: cstring) -> Id ---
	objc_getProtocol        :: proc "c" (name: cstring) -> Id ---
	sel_registerName        :: proc "c" (name: cstring) -> Sel ---
	objc_allocateClassPair  :: proc "c" (superclass: Id, name: cstring, extra: uint) -> Id ---
	objc_registerClassPair  :: proc "c" (cls: Id) ---
	class_addMethod         :: proc "c" (cls: Id, name: Sel, imp: rawptr, types: cstring) -> bool ---
	class_addProtocol       :: proc "c" (cls: Id, protocol: Id) -> bool ---
}

foreign import libc "system:System.framework"
foreign libc {
	getenv :: proc "c" (name: cstring) -> cstring ---
	kill   :: proc "c" (pid, signal: i32) -> i32 ---
}

Point :: struct { x, y: f64 }
Size  :: struct { width, height: f64 }
Rect  :: struct { origin: Point, size: Size }
CMTime :: struct { value: i64, timescale: i32, flags: u32, epoch: i64 }

Source_Metadata_Status :: enum i32 {
	Missing,
	Available,
	Unavailable,
}

Source_Kind :: enum i32 {
	YouTube,
	Local,
}

Workflow_Kind :: enum i32 {
	Vocal,
	Dancing,
}

Source_Video :: struct {
	id: string,
	workflow: Workflow_Kind,
	kind: Source_Kind,
	video_id: string,
	title: string,
	url: string,
	original_filename: string,
	content_sha256: string,
	has_audio: bool,
	media_path: string,
	duration: f64,
	metadata: Source_Context_Metadata,
	metadata_status: Source_Metadata_Status,
	media_available: bool,
}

Transcript_Segment :: struct {
	id: string,
	source_id: string,
	start_seconds: f64,
	duration_seconds: f64,
	text: string,
}

Transcript_Source_Span :: struct {
	source_id: string,
	start: int,
	count: int,
}

Import_Hint :: struct {
	source_id: string,
	seconds: f64,
}

Clip :: struct {
	id: string,
	source_id: string,
	workflow: Workflow_Kind,
	name: string,
	start_seconds: f64,
	end_seconds: f64,
	clip_path: string,
	last_randomized_sequence: i64 `json:"-"`,
	dance_mirrored: bool,
	dance_loop: bool,
	dance_count_in_beats: int,
	dance_count_each_loop: bool,
	dance_count_in_bpm: int,
	dance_detected_bpm: f64,
	dance_bpm_confidence: f32,
	dance_bpm_detector_revision: int,
	dance_bpm_user_set: bool,
	dance_beat_period_seconds: f64,
	dance_beat_grid_offset_seconds: f64,
	dance_beat_phase_confidence: f32,
	dance_beat_phase_user_set: bool,
	dance_metronome_enabled: bool,
	dance_playback_rate: f32,
}

Clip_Draft :: struct {
	source_id: string,
	start_seconds: f64,
	end_seconds: f64,
	has_start: bool,
	has_end: bool,
	name: string,
	revision: i64,
}

Clip_Draft_Clear_Request :: struct {
	source_id: string,
	revision: i64,
	cleared: bool,
}

App_State :: struct {
	window: Id,
	url_input: Id,
	status: Id,
	player: Id,
	clip_name_input: Id,
	source_search_input: Id,
	clip_search_input: Id,
	delegate_target: Id,
	active_source: int,
	range_start: f64,
	range_end: f64,
	has_start: bool,
	has_end: bool,
	pending_hint: f64,
	has_pending_hint: bool,
	sources: [dynamic]Source_Video,
	transcripts: Transcript_Generation,
	hints: [dynamic]Import_Hint,
	clips: [dynamic]Clip,
}

state: App_State
send_address: rawptr

Major_Change_Pending_Kind :: enum {
	None,
	Source_Import,
	Source_Refetch,
	Source_Delete,
	Local_Source_Relink,
	Library_Replacement,
}

Major_Change_Pending :: struct {
	open: bool,
	allow_once: bool,
	kind: Major_Change_Pending_Kind,
	source_index: int,
	maximum_height: int,
	auth_browser: Source_Auth_Browser,
	detail: string,
}

major_change_pending: Major_Change_Pending
major_change_backup_override: bool
system_address: rawptr
last_imported_source: int = -1
source_local_paths: [dynamic]string
source_local_titles: [dynamic]string
pending_local_relink_path: string
pending_source_delete_id: string
pending_clip_delete_id: string

Helper_Status :: struct {
	checked: bool,
	available: bool,
	reason: string,
}

yt_dlp_helper_status: Helper_Status
ffmpeg_helper_status: Helper_Status
ffprobe_helper_status: Helper_Status

Import_Phase :: enum {
	Preparing,
	Inspecting_Local_Media,
	Processing_Local_Media,
	Validating_Local_Media,
	Validating_Existing_Media,
	Downloading,
	Encoding_Downloaded_Media,
	Validating_Downloaded_Media,
	Rebuilding_Clips,
}

Import_Job :: struct {
	task_id: task_queue.Task_ID,
	completion_target: Id,
	arena: ^mem_virtual.Arena,
	operation_id: u64,
	progress_path: string,
	log_path: string,
	input: string,
	local_path: string,
	local_title: string,
	workflow: Workflow_Kind,
	sources: [dynamic]Source_Video,
	hints: [dynamic]Import_Hint,
	clips: [dynamic]Clip,
	new_sources: [dynamic]Source_Video,
	new_hints: [dynamic]Import_Hint,
	qualities: [dynamic]Import_Quality,
	snapshot_transcripts: Transcript_Generation,
	transcripts: Transcript_Generation,
	has_transcript_update: bool,
	updated_source: Source_Video,
	has_source_update: bool,
	replace_video_id: string,
	last_video_id: string,
	pending_hint: f64,
	has_pending_hint: bool,
	allow_without_backup: bool,
	accepted: int,
	failed: int,
	existing_sources: int,
	updated_hints: int,
	latest_updated_hint: f64,
	refreshed_clips: int,
	failed_clip_refreshes: int,
	missing_merged_media: int,
	invalid_merged_media: int,
	process_mutex: sync.Mutex,
	process: os2.Process,
	has_process: bool,
	cancelled: bool,
	phase: Import_Phase,
	notification_id: i64,
	last_notification_phase: Import_Phase,
	has_notification_phase: bool,
	library_recovery_source: bool,
	recovery_index: int,
	recovery_total: int,
	reuse_existing_media: bool,
	applied_source_index: int,
	cli_work: ^CLI_IPC_Work,
	cli_existing_source: bool,
	cli_existing_hint_count: int,
	completion: Media_Task_Completion,
}

Import_Quality :: struct {
	video_id: string,
	height: int,
	exact: bool,
	auth_browser: Source_Auth_Browser,
}

Export_Operation :: enum {
	Save,
	Preview,
	Repair,
}

Export_Job :: struct {
	task_id: task_queue.Task_ID,
	completion_target: Id,
	arena: ^mem_virtual.Arena,
	operation_id: u64,
	clip: Clip,
	source_path: string,
	has_audio: bool,
	log_path: string,
	operation: Export_Operation,
	notification_id: i64,
	draft_revision: i64,
	success: bool,
	process_mutex: sync.Mutex,
	process: os2.Process,
	has_process: bool,
	cancelled: bool,
	cli_work: ^CLI_IPC_Work,
	completion: Media_Task_Completion,
}

Clip_Normalize_Job :: struct {
	task_id: task_queue.Task_ID,
	completion_target: Id,
	library: App_State,
	operation_id: u64,
	log_path: string,
	notification_id: i64,
	total: int,
	rebuilt: int,
	failures: [dynamic]CLI_Clip_Normalize_Failure,
	process_mutex: sync.Mutex,
	process: os2.Process,
	has_process: bool,
	cancelled: bool,
	cli_work: ^CLI_IPC_Work,
	completion: Media_Task_Completion,
}

clip_normalize_job: ^Clip_Normalize_Job

Library_Recovery_Entry :: struct {
	video_id: string,
	height:   int,
	workflow: Workflow_Kind,
}

Library_Recovery :: struct {
	entries:   [dynamic]Library_Recovery_Entry,
	next:      int,
	recovered: int,
	failed:    int,
	cancelled: bool,
	notification_id: i64,
}

library_recovery: ^Library_Recovery

Library_Replacement_Job :: struct {
	task_id: task_queue.Task_ID,
	library: App_State,
	scope: Portable_Library_Scope,
	allow_without_backup: bool,
	notification_id: i64,
	cancelled: bool,
	completion: Media_Task_Completion,
}

library_replacement_job: ^Library_Replacement_Job
pending_library_import: App_State
pending_library_import_scope: Portable_Library_Scope

Source_Metadata_Job :: struct {
	thread: ^thread.Thread,
	completion_target: Id,
	video_id: string,
	workflow: Workflow_Kind,
	media_path: string,
	metadata: Source_Context_Metadata,
	metadata_loaded: bool,
}

export_jobs: [dynamic]^Export_Job
export_completed_jobs: [dynamic]^Export_Job
export_completion_mutex: sync.Mutex
source_metadata_job: ^Source_Metadata_Job
media_operation_sequence: u64

msg_id :: proc(receiver: Id, selector: Sel) -> Id {
	p := transmute(proc "c" (Id, Sel) -> Id)send_address
	return p(receiver, selector)
}
msg_void :: proc(receiver: Id, selector: Sel) {
	p := transmute(proc "c" (Id, Sel))send_address
	p(receiver, selector)
}
msg_id_id :: proc(receiver: Id, selector: Sel, a: Id) -> Id {
	p := transmute(proc "c" (Id, Sel, Id) -> Id)send_address
	return p(receiver, selector, a)
}
msg_void_id :: proc(receiver: Id, selector: Sel, a: Id) {
	p := transmute(proc "c" (Id, Sel, Id))send_address
	p(receiver, selector, a)
}
msg_void_i :: proc(receiver: Id, selector: Sel, a: int) {
	p := transmute(proc "c" (Id, Sel, int))send_address
	p(receiver, selector, a)
}
msg_uint :: proc(receiver: Id, selector: Sel) -> uint {
	p := transmute(proc "c" (Id, Sel) -> uint)send_address
	return p(receiver, selector)
}
msg_id_uint :: proc(receiver: Id, selector: Sel, a: uint) -> Id {
	p := transmute(proc "c" (Id, Sel, uint) -> Id)send_address
	return p(receiver, selector, a)
}
msg_id_id_id :: proc(receiver: Id, selector: Sel, a, b: Id) -> Id {
	p := transmute(proc "c" (Id, Sel, Id, Id) -> Id)send_address
	return p(receiver, selector, a, b)
}
msg_id_f64_f64 :: proc(receiver: Id, selector: Sel, a, b: f64) -> Id {
	p := transmute(proc "c" (Id, Sel, f64, f64) -> Id)send_address
	return p(receiver, selector, a, b)
}
msg_f64 :: proc(receiver: Id, selector: Sel) -> f64 {
	p := transmute(proc "c" (Id, Sel) -> f64)send_address
	return p(receiver, selector)
}
msg_f32 :: proc(receiver: Id, selector: Sel) -> f32 {
	p := transmute(proc "c" (Id, Sel) -> f32)send_address
	return p(receiver, selector)
}
msg_id_rect :: proc(receiver: Id, selector: Sel, rect: Rect) -> Id {
	p := transmute(proc "c" (Id, Sel, Rect) -> Id)send_address
	return p(receiver, selector, rect)
}
msg_void_rect :: proc(receiver: Id, selector: Sel, rect: Rect) {
	p := transmute(proc "c" (Id, Sel, Rect))send_address
	p(receiver, selector, rect)
}
msg_rect :: proc(receiver: Id, selector: Sel) -> Rect {
	p := transmute(proc "c" (Id, Sel) -> Rect)send_address
	return p(receiver, selector)
}
msg_void_rect_b :: proc(receiver: Id, selector: Sel, rect: Rect, value: bool) {
	p := transmute(proc "c" (Id, Sel, Rect, bool))send_address
	p(receiver, selector, rect, value)
}
msg_id_rect_u_u_b :: proc(receiver: Id, selector: Sel, rect: Rect, style, backing: uint, defer_window: bool) -> Id {
	p := transmute(proc "c" (Id, Sel, Rect, uint, uint, bool) -> Id)send_address
	return p(receiver, selector, rect, style, backing, defer_window)
}
msg_time :: proc(receiver: Id, selector: Sel) -> CMTime {
	p := transmute(proc "c" (Id, Sel) -> CMTime)send_address
	return p(receiver, selector)
}
msg_void_time :: proc(receiver: Id, selector: Sel, value: CMTime) {
	p := transmute(proc "c" (Id, Sel, CMTime))send_address
	p(receiver, selector, value)
}

msg_void_time_time_time :: proc(receiver: Id, selector: Sel, value, tolerance_before, tolerance_after: CMTime) {
	p := transmute(proc "c" (Id, Sel, CMTime, CMTime, CMTime))send_address
	p(receiver, selector, value, tolerance_before, tolerance_after)
}
msg_void_sel_id_b :: proc(receiver: Id, selector: Sel, action: Sel, object: Id, wait: bool) {
	p := transmute(proc "c" (Id, Sel, Sel, Id, bool))send_address
	p(receiver, selector, action, object, wait)
}

nsstring :: proc(s: string) -> Id {
	cls := objc_getClass("NSString")
	c_text := strings.clone_to_cstring(s)
	defer delete(c_text)
	return msg_id_id(cls, sel_registerName("stringWithUTF8String:"), rawptr(c_text))
}

set_text :: proc(control: Id, text: string) {
	if control == state.status {
		_ = notification_post_info(
			text,
			persist = ui_automation_persistent_side_effects_allowed(),
		)
		return
	}
	if control == state.clip_name_input {
		ui_set_string(&ui.clip_name, text)
		ui.needs_redraw = true
		return
	}
	msg_void_id(control, sel_registerName("setStringValue:"), nsstring(text))
}

set_success_status :: proc(text: string) {
	_ = notification_post_success(
		text,
		persist = ui_automation_persistent_side_effects_allowed(),
	)
}

set_error_status :: proc(text: string) {
	_ = notification_post_error(
		text,
		persist = ui_automation_persistent_side_effects_allowed(),
	)
}

set_status_source :: proc(video_id: string) {
	_ = notification_set_action(
		notification_history.current_id,
		.View_Source,
		video_id,
	)
}

should_load_completed_source :: proc(source_update: bool, active_source, completed_source: int) -> bool {
	return completed_source >= 0 && (!source_update || active_source == completed_source)
}

import_success_status :: proc(new_sources, existing_sources, updated_hints: int, latest_hint := -1.0) -> string {
	if new_sources > 0 && updated_hints == 1 && latest_hint >= 0 {return fmt.tprintf("Imported %d source%s; added timestamp %s to an existing source", new_sources, new_sources == 1 ? "" : "s", format_timestamp(latest_hint))}
	if new_sources > 0 && updated_hints > 0 {return fmt.tprintf("Imported %d source%s; added %d timestamps to existing sources", new_sources, new_sources == 1 ? "" : "s", updated_hints)}
	if new_sources > 0 {return fmt.tprintf("Imported %d source%s", new_sources, new_sources == 1 ? "" : "s")}
	if updated_hints == 1 && latest_hint >= 0 {return fmt.tprintf("Added timestamp %s to the existing source", format_timestamp(latest_hint))}
	if updated_hints > 0 {return fmt.tprintf("Added %d timestamps to existing sources", updated_hints)}
	return fmt.tprintf("%d source%s already in the register", existing_sources, existing_sources == 1 ? "" : "s")
}

field_text :: proc(control: Id) -> string {
	if control == nil { return "" }
	if control == state.url_input { return ui.url_input }
	if control == state.source_search_input { return ui.source_search }
	if control == state.clip_search_input { return ui.clip_search }
	if control == state.clip_name_input { return ui.clip_name }
	value := msg_id(control, sel_registerName("stringValue"))
	utf8 := msg_id(value, sel_registerName("UTF8String"))
	if utf8 == nil { return "" }
	return string(cstring(utf8))
}

timestamp_seconds :: proc(value: string) -> (f64, bool) {
	if len(value) == 0 { return 0, false }
	total: f64
	number: f64
	found := false
	for c in value {
		if c >= '0' && c <= '9' {
			number = number*10 + f64(c-'0')
			found = true
		} else if c == 'h' {
			total += number*3600; number = 0
		} else if c == 'm' {
			total += number*60; number = 0
		} else if c == 's' {
			total += number; number = 0
		} else { break }
	}
	return total+number, found
}

format_timestamp :: proc(seconds: f64) -> string {
	whole_seconds := int(seconds)
	if whole_seconds < 0 { whole_seconds = 0 }
	hours := whole_seconds / 3600
	minutes := whole_seconds % 3600 / 60
	remaining_seconds := whole_seconds % 60
	return fmt.tprintf("%02d:%02d:%02d", hours, minutes, remaining_seconds)
}

parse_video_id :: proc(raw_url: string) -> (string, bool) {
	url := strings.trim_space(raw_url)
	lower := strings.to_lower(url, context.temp_allocator)
	scheme_end := strings.index(lower, "://")
	if scheme_end < 0 {return "", false}
	scheme := lower[:scheme_end]
	if scheme != "https" && scheme != "http" {return "", false}
	authority_start := scheme_end + 3
	authority_end := len(lower)
	if separator := strings.index_any(lower[authority_start:], "/?#");
	   separator >= 0 {
		authority_end = authority_start + separator
	}
	if authority_end <= authority_start {return "", false}
	host := lower[authority_start:authority_end]
	remainder := url[authority_end:]
	lower_remainder := lower[authority_end:]
	if host == "youtu.be" || host == "www.youtu.be" {
		if len(remainder) < 2 || remainder[0] != '/' {return "", false}
		video_id := remainder[1:]
		if end := strings.index_any(video_id, "/?&#"); end >= 0 {
			video_id = video_id[:end]
		}
		return video_id, len(video_id) > 0
	}
	if host != "youtube.com" && !strings.has_suffix(host, ".youtube.com") {
		return "", false
	}
	query_start := strings.index(lower_remainder, "?")
	if query_start < 0 {return "", false}
	path := lower_remainder[:query_start]
	if path != "/watch" {return "", false}
	query := remainder[query_start + 1:]
	if fragment := strings.index(query, "#"); fragment >= 0 {
		query = query[:fragment]
	}
	remaining := query
	for parameter in strings.split_iterator(&remaining, "&") {
		equals := strings.index(parameter, "=")
		if equals < 0 || parameter[:equals] != "v" {continue}
		video_id := parameter[equals + 1:]
		return video_id, len(video_id) > 0
	}
	return "", false
}

parse_timestamp :: proc(url: string) -> (f64, bool) {
	keys := [2]string{"t=", "start="}
	for key in keys {
		if i := strings.index(url, key); i >= 0 {
			v := url[i+len(key):]
			if e := strings.index_any(v, "&#"); e >= 0 { v = v[:e] }
			return timestamp_seconds(v)
		}
	}
	return 0, false
}

shell_quote :: proc(s: string) -> string {
	escaped, _ := strings.replace_all(s, "'", "'\\''")
	return fmt.tprintf("'%s'", escaped)
}

app_support_migration_conflict: bool

default_app_support_dir :: proc(name: string) -> string {
	home := getenv("HOME")
	return fmt.tprintf("%s/Library/Application Support/%s", string(home), name)
}

app_support_dir :: proc() -> string {
	if override := getenv("HW_VIDEO_CLIPS_APP_SUPPORT_DIR"); override != nil && len(string(override)) > 0 {
		return string(override)
	}
	return default_app_support_dir("hw_videoClips")
}

migrate_legacy_app_support_paths :: proc(
	current,
	legacy: string,
) -> bool {
	current_exists := os.exists(current)
	legacy_exists := os.exists(legacy)
	if !legacy_exists {return true}
	if current_exists {
		app_support_migration_conflict =
			os.exists(fmt.tprintf("%s/library.sqlite3", current)) &&
			os.exists(fmt.tprintf("%s/library.sqlite3", legacy))
		return true
	}
	if os.rename(legacy, current) {return true}
	fmt.eprintln(
		"Unable to move the existing VocalTraining library to ",
		current,
		". The original library remains unchanged.",
	)
	return false
}

migrate_legacy_app_support_dir :: proc() -> bool {
	if override := getenv("HW_VIDEO_CLIPS_APP_SUPPORT_DIR"); override != nil &&
	   len(string(override)) > 0 {
		return true
	}
	return migrate_legacy_app_support_paths(
		default_app_support_dir("hw_videoClips"),
		default_app_support_dir("VocalTraining"),
	)
}

diagnostic_log_path :: proc(name: string) -> string {
	return fmt.tprintf("%s/%s.log", app_support_dir(), name)
}

next_media_operation_id :: proc() -> u64 {
	media_operation_sequence += 1
	return media_operation_sequence
}

clip_export_log_path :: proc(clip_id: string, operation_id: u64 = 0) -> string {
	if operation_id > 0 {
		return fmt.tprintf(
			"%s/ffmpeg-%s-%020d.log",
			app_support_dir(),
			clip_id,
			operation_id,
		)
	}
	return fmt.tprintf("%s/ffmpeg-%s.log", app_support_dir(), clip_id)
}

import_log_path :: proc(operation_id: u64) -> string {
	return fmt.tprintf(
		"%s/yt-dlp-%020d.log",
		app_support_dir(),
		operation_id,
	)
}

import_progress_path :: proc(operation_id: u64 = 0) -> string {
	if operation_id > 0 {
		return fmt.tprintf(
			"%s/yt-dlp-progress-%020d.log",
			app_support_dir(),
			operation_id,
		)
	}
	return fmt.tprintf("%s/yt-dlp-progress.log", app_support_dir())
}

download_progress_status :: proc(contents: string) -> (string, bool) {
	latest := ""
	remaining_lines := contents
	for line in strings.split_lines_iterator(&remaining_lines) {
		if strings.has_prefix(line, "HW_VIDEO_CLIPS_PROGRESS|") {latest = line}
	}
	if len(latest) == 0 {return "", false}
	fields: [5]string
	field_count := 0
	remaining_fields := latest
	for field in strings.split_iterator(&remaining_fields, "|") {
		if field_count >= len(fields) {return "", false}
		fields[field_count] = field
		field_count += 1
	}
	if field_count != len(fields) {return "", false}
	percent := strings.trim_space(fields[1])
	total := strings.trim_space(fields[2])
	speed := strings.trim_space(fields[3])
	eta := strings.trim_space(fields[4])
	return fmt.tprintf("Downloading %s / %s / %s / ETA %s", percent, total, speed, eta), true
}

import_job_set_phase :: proc(job: ^Import_Job, phase: Import_Phase) {
	sync.mutex_lock(&job.process_mutex)
	job.phase = phase
	sync.mutex_unlock(&job.process_mutex)
}

import_job_phase :: proc(job: ^Import_Job) -> Import_Phase {
	sync.mutex_lock(&job.process_mutex)
	phase := job.phase
	sync.mutex_unlock(&job.process_mutex)
	return phase
}

import_progress_status :: proc(job: ^Import_Job, contents: string) -> string {
	prefix := ""
	if job.library_recovery_source {
		prefix = fmt.tprintf(
			"Recovering source %d of %d: ",
			job.recovery_index,
			job.recovery_total,
		)
	}
	switch import_job_phase(job) {
	case .Preparing:
		return fmt.tprintf("%spreparing media", prefix)
	case .Inspecting_Local_Media:
		return fmt.tprintf("%sinspecting local media", prefix)
	case .Processing_Local_Media:
		return fmt.tprintf("%scopying or normalizing local media", prefix)
	case .Validating_Local_Media:
		return fmt.tprintf("%svalidating local media", prefix)
	case .Validating_Existing_Media:
		return fmt.tprintf("%svalidating existing media", prefix)
	case .Downloading:
		if status, ok := download_progress_status(contents); ok {
			if strings.contains(status, "Downloading 100.0%") &&
			   strings.has_suffix(status, "ETA NA") {
				return fmt.tprintf("%sfinalizing downloaded media", prefix)
			}
			return fmt.tprintf("%s%s", prefix, status)
		}
		return fmt.tprintf("%sstarting media download", prefix)
	case .Encoding_Downloaded_Media:
		return fmt.tprintf("%sencoding downloaded media as HEVC", prefix)
	case .Validating_Downloaded_Media:
		return fmt.tprintf("%svalidating downloaded media", prefix)
	case .Rebuilding_Clips:
		return fmt.tprintf("%srebuilding clips", prefix)
	}
	return fmt.tprintf("%spreparing media", prefix)
}

refresh_import_progress :: proc() {
	for job in import_jobs {
		contents, _ := os.read_entire_file(
			job.progress_path,
			context.temp_allocator,
		)
		status := import_progress_status(job, string(contents))
		if job.notification_id == 0 {
			set_text(state.status, status)
			continue
		}
		phase := import_job_phase(job)
		source_progress := ""
		if job.library_recovery_source {
			source_progress = fmt.tprintf(
				"%d of %d",
				job.recovery_index,
				job.recovery_total,
			)
		}
		operation := job.library_recovery_source ? "Library recovery" : (len(job.local_path) > 0 ? "Local file import" : "Media download")
		detail := len(job.local_path) > 0 ? "The application inspects, copies or normalizes, validates, and registers the local media." : "The application downloads, validates, and registers the source media."
		fields := [3]Notification_Field{
			{label="Operation", value=operation},
			{label="Source", value=source_progress},
			{label="Phase", value=fmt.tprintf("%v", phase)},
		}
		phase_changed := !job.has_notification_phase ||
		                 job.last_notification_phase != phase
		job.last_notification_phase = phase
		job.has_notification_phase = true
		_ = notification_update(
			job.notification_id,
			status,
			detail,
			fields[:],
			persist_now = phase_changed,
		)
	}
}

embedded_helper_path :: proc(executable_path, name: string) -> string {
	executable_dir := filepath.dir(executable_path)
	path, _ := filepath.join(
		[]string{executable_dir, "..", "Resources", "helpers", name},
		context.temp_allocator,
	)
	return path
}

helper_command :: proc(name: string) -> string {
	executable_path, err := os2.get_executable_path(context.temp_allocator)
	if err == nil {
		candidate := embedded_helper_path(executable_path, name)
		if os.exists(candidate) { return candidate }
	}
	return helper_path_from_search(name, string(getenv("PATH")))
}

helper_path_from_search :: proc(name, search_path: string) -> string {
	remaining := search_path
	for directory in strings.split_iterator(&remaining, ":") {
		if len(directory) == 0 {continue}
		candidate, join_error := filepath.join([]string{directory, name}, context.temp_allocator)
		if join_error == nil && os.exists(candidate) {return candidate}
	}
	return name
}

youtube_download_command :: proc(url, output, log_path: string, yt_dlp := "", ffmpeg := "") -> string {
	yt_dlp_command := yt_dlp
	ffmpeg_command := ffmpeg
	if len(yt_dlp_command) == 0 { yt_dlp_command = helper_command("yt-dlp") }
	if len(ffmpeg_command) == 0 { ffmpeg_command = helper_command("ffmpeg") }
	return fmt.tprintf("%s --no-playlist --force-overwrites --write-info-json --write-subs --write-auto-subs --sub-langs 'en,.*-orig' --sub-format json3 --ffmpeg-location %s -f 'bv*[ext=mp4]+ba[ext=m4a]/b[ext=mp4]/bv*+ba/b' -S 'res,vcodec:h264' --merge-output-format mp4 -o %s %s >> %s 2>&1", shell_quote(yt_dlp_command), shell_quote(ffmpeg_command), shell_quote(output), shell_quote(url), shell_quote(log_path))
}

clip_export_command :: proc(
	source_path,
	clip_path: string,
	start_seconds,
	end_seconds: f64,
	ffmpeg := "",
	log_path := "",
	has_audio := true,
) -> string {
	ffmpeg_command := ffmpeg
	if len(ffmpeg_command) == 0 { ffmpeg_command = helper_command("ffmpeg") }
	output_log := log_path
	if len(output_log) == 0 {output_log = diagnostic_log_path("ffmpeg")}
	if !has_audio {
		return fmt.tprintf("%s -y -loglevel error -ss %.3f -i %s -t %.3f -vf 'setpts=PTS-STARTPTS' -an -c:v hevc_videotoolbox -profile:v main -pix_fmt yuv420p -q:v %d -tag:v hvc1 -movflags +faststart %s >> %s 2>&1", shell_quote(ffmpeg_command), start_seconds, shell_quote(source_path), end_seconds-start_seconds, MANAGED_HEVC_QUALITY, shell_quote(clip_path), shell_quote(output_log))
	}
	return fmt.tprintf("%s -y -loglevel error -ss %.3f -i %s -t %.3f -vf 'setpts=PTS-STARTPTS' -af 'asetpts=PTS-STARTPTS' -c:v hevc_videotoolbox -profile:v main -pix_fmt yuv420p -q:v %d -tag:v hvc1 -c:a aac -movflags +faststart %s >> %s 2>&1", shell_quote(ffmpeg_command), start_seconds, shell_quote(source_path), end_seconds-start_seconds, MANAGED_HEVC_QUALITY, shell_quote(clip_path), shell_quote(output_log))
}

workflow_source_directory :: proc(workflow: Workflow_Kind) -> string {
	if workflow == .Dancing {
		return fmt.tprintf("%s/dancing/sources", app_support_dir())
	}
	return fmt.tprintf("%s/sources", app_support_dir())
}

workflow_clip_directory :: proc(workflow: Workflow_Kind) -> string {
	if workflow == .Dancing {
		return fmt.tprintf("%s/dancing/clips", app_support_dir())
	}
	return fmt.tprintf("%s/clips", app_support_dir())
}

source_id_for_workflow :: proc(workflow: Workflow_Kind, video_id: string) -> string {
	if workflow == .Dancing {return fmt.tprintf("dancing-%s", video_id)}
	return video_id
}

import_url :: proc(url: string) -> bool {
	video_id, ok := parse_video_id(url)
	if !ok { return false }
	for source, index in state.sources {
		if source.workflow == ui.workflow && source.video_id == video_id {
			last_imported_source = index
			if seconds, has_time := parse_timestamp(url); has_time {
				duplicate := false
				for hint in state.hints { if hint.source_id == source.id && hint.seconds == seconds { duplicate = true; break } }
				if !duplicate { append(&state.hints, Import_Hint{source_id=strings.clone(source.id), seconds=seconds}) }
				state.pending_hint, state.has_pending_hint = seconds, true
			}
			return true
		}
	}
	source_directory := workflow_source_directory(ui.workflow)
	os.make_directory(source_directory)
	output := fmt.tprintf("%s/%s.%%(ext)s", source_directory, video_id)
	command := youtube_download_command(url, output, diagnostic_log_path("yt-dlp"))
	c_command := strings.clone_to_cstring(command)
	defer delete(c_command)
	run := transmute(proc "c" (cstring) -> int)system_address
	result := run(c_command)
	if result != 0 { return false }
	media_path := fmt.tprintf("%s/%s.mp4", source_directory, video_id)
	if !os.exists(media_path) {return false}
	id_copy := strings.clone(source_id_for_workflow(ui.workflow, video_id))
	url_copy := strings.clone(url)
	append(&state.sources, Source_Video{
		id=id_copy,
		workflow=ui.workflow,
		kind=.YouTube,
		video_id=strings.clone(video_id),
		title=strings.clone(video_id),
		url=url_copy,
		media_path=strings.clone(media_path),
		media_available=true,
		has_audio=true,
	})
	last_imported_source = len(state.sources)-1
	if metadata, loaded := load_download_metadata(video_id, ui.workflow); loaded {
		delete(state.sources[len(state.sources)-1].title)
		state.sources[len(state.sources)-1].title = strings.clone(metadata.title)
		state.sources[len(state.sources)-1].duration = metadata.duration
		delete(metadata.title)
	}
	if seconds, has_time := parse_timestamp(url); has_time {
		append(
			&state.hints,
			Import_Hint{
				source_id=strings.clone(
					state.sources[len(state.sources)-1].id,
				),
				seconds=seconds,
			},
		)
		state.pending_hint, state.has_pending_hint = seconds, true
	}
	load_youtube_transcript(&state.sources[len(state.sources)-1])
	return true
}

helper_available :: proc(name: string) -> (available: bool, reason: string) {
	command_path := helper_command(name)
	lookup := fmt.tprintf("command -v %s >/dev/null 2>&1", shell_quote(command_path))
	c_lookup := strings.clone_to_cstring(lookup)
	run := transmute(proc "c" (cstring) -> int)system_address
	found := run(c_lookup) == 0
	delete(c_lookup)
	if !found { return false, fmt.tprintf("%s was not found", name) }

	version_flag := "--version"
	expected_output := "[0-9]*.[0-9]*.[0-9]*"
	if name == "ffmpeg" || name == "ffprobe" {
		version_flag = "-version"
		expected_output = name == "ffmpeg" ? "ffmpeg\\ version\\ *" : "ffprobe\\ version\\ *"
	}
	os.make_directory(app_support_dir())
	log_path := diagnostic_log_path(name)
	command := fmt.tprintf(
		"output=$(%s %s 2>&1); status=$?; if [ \"$status\" -eq 0 ]; then case \"$output\" in %s) exit 0 ;; esac; fi; printf '%%s\\n' \"$output\" >> %s 2>/dev/null || true; exit 1",
		shell_quote(command_path),
		version_flag,
		expected_output,
		shell_quote(log_path),
	)
	c_command := strings.clone_to_cstring(command)
	defer delete(c_command)
	if run(c_command) != 0 {
		return false, fmt.tprintf("%s could not run or returned an invalid version; details: %s", name, log_path)
	}
	return true, ""
}

helper_status :: proc(name: string) -> ^Helper_Status {
	switch name {
	case "yt-dlp":
		return &yt_dlp_helper_status
	case "ffmpeg":
		return &ffmpeg_helper_status
	case "ffprobe":
		return &ffprobe_helper_status
	}
	return nil
}

check_helper_once :: proc(name: string) -> ^Helper_Status {
	status := helper_status(name)
	if status == nil {return nil}
	if status.checked {return status}
	available, reason := helper_available(name)
	status.available = available
	status.reason = strings.clone(reason)
	status.checked = true
	return status
}

helper_statuses_destroy :: proc() {
	delete(yt_dlp_helper_status.reason)
	delete(ffmpeg_helper_status.reason)
	delete(ffprobe_helper_status.reason)
	yt_dlp_helper_status = {}
	ffmpeg_helper_status = {}
	ffprobe_helper_status = {}
}

require_helper :: proc(name: string) -> bool {
	status := check_helper_once(name)
	if status == nil {
		set_text(state.status, fmt.tprintf("%s is not a supported media helper", name))
		return false
	}
	if status.available { return true }
	set_text(state.status, status.reason)
	return false
}

validate_startup_helpers :: proc() {
	yt_dlp := check_helper_once("yt-dlp")
	ffmpeg := check_helper_once("ffmpeg")
	ffprobe := check_helper_once("ffprobe")
	if yt_dlp.available && ffmpeg.available && ffprobe.available { return }

	message := "hw_videoClips checked its media helpers before starting."
	if !yt_dlp.available {
		message = fmt.tprintf("%s\n\n%s. YouTube import and refetch are unavailable.", message, yt_dlp.reason)
	}
	if !ffmpeg.available {
		message = fmt.tprintf("%s\n\n%s. Import, refetch, preview, and clip export are unavailable.", message, ffmpeg.reason)
	}
	if !ffprobe.available {
		message = fmt.tprintf("%s\n\n%s. Local video import is unavailable.", message, ffprobe.reason)
	}
	message = fmt.tprintf("%s\n\nNo media task was started. Contact the person who provided this app.", message)
	set_text(state.status, message)

	alert := msg_id(msg_id(objc_getClass("NSAlert"), sel_registerName("alloc")), sel_registerName("init"))
	msg_void_id(alert, sel_registerName("setMessageText:"), nsstring("Media helpers are unavailable"))
	msg_void_id(alert, sel_registerName("setInformativeText:"), nsstring(message))
	_ = msg_id_id(alert, sel_registerName("addButtonWithTitle:"), nsstring("OK"))
	msg_void_i(alert, sel_registerName("setAlertStyle:"), 2)
	_ = msg_uint(alert, sel_registerName("runModal"))
	msg_void(alert, sel_registerName("release"))
}

configure_helper_path :: proc() {
	current := getenv("PATH")
	updated := fmt.tprintf("/opt/homebrew/bin:/usr/local/bin:%s", string(current))
	os.set_env("PATH", updated)
}

current_seconds :: proc() -> (f64, bool) {
	if state.player == nil { return 0, false }
	t := msg_time(state.player, sel_registerName("currentTime"))
	if t.timescale == 0 { return 0, false }
	return f64(t.value)/f64(t.timescale), true
}

valid_clip_range :: proc(start, end, source_duration: f64) -> bool {
	return start >= 0 &&
	       end - start >= 1 &&
	       (source_duration <= 0 || end <= source_duration)
}

active_clip_range_is_valid :: proc() -> bool {
	if state.active_source < 0 || state.active_source >= len(state.sources) {return false}
	return state.has_start &&
	       state.has_end &&
	       valid_clip_range(
			state.range_start,
			state.range_end,
			state.sources[state.active_source].duration,
		)
}

source_index_for_id :: proc(sources: []Source_Video, source_id: string) -> int {
	for source, index in sources {
		if source.id == source_id {return index}
	}
	return -1
}

clip_index_for_id :: proc(clips: []Clip, clip_id: string) -> int {
	for clip, index in clips {
		if clip.id == clip_id {return index}
	}
	return -1
}

source_index_for_clip :: proc(
	sources: []Source_Video,
	clips: []Clip,
	clip_index: int,
) -> int {
	if clip_index < 0 || clip_index >= len(clips) {return -1}
	return source_index_for_id(sources, clips[clip_index].source_id)
}

rename_clip :: proc(index: int, name: string) -> bool {
	if index < 0 || index >= len(state.clips) {return false}
	trimmed := strings.trim_space(name)
	if len(trimmed) == 0 {return false}
	clip := &state.clips[index]
	if clip.name == trimmed {return true}
	replacement, err := strings.clone(trimmed)
	if err != nil {return false}
	original := clip.name
	clip.name = replacement
	if !save_library() {
		clip.name = original
		delete(replacement)
		return false
	}
	delete(original)
	refresh_clips()
	return true
}

seek_video_seconds :: proc(
	seconds: f64,
	warm_paused_frame := true,
	exact := false,
) {
	if state.player == nil { return }
	t := CMTime{value=i64(seconds*600), timescale=600, flags=1}
	tolerance := CMTime{value=10, timescale=600, flags=1}
	if exact {tolerance = CMTime{value=0, timescale=1, flags=1}}
	msg_void_time_time_time(
		state.player,
		sel_registerName("seekToTime:toleranceBefore:toleranceAfter:"),
		t,
		tolerance,
		tolerance,
	)
	request_video_frame_refresh()
	if warm_paused_frame &&
	   msg_f32(state.player, sel_registerName("rate")) == 0 {
		request_paused_video_frame_warmup()
	}
}

seek_seconds :: proc(
	seconds: f64,
	warm_paused_frame := true,
	exact := false,
) {
	if state.player == nil { return }
	cancel_dance_count_in()
	ui.playback_completion_pending = false
	request_transcript_follow_to(seconds)
	resume := playback_actively_playing()
	if ui.metronome != nil {hw_metronome_stop(ui.metronome)}
	seek_video_seconds(seconds, warm_paused_frame, exact)
	metal_audio_seek(seconds, resume)
	if resume {dance_schedule_continuous_metronome(active_dance_clip(), seconds)}
}

scrub_player_by :: proc(delta: f64) {
	if state.player == nil {return}
	seconds, ok := current_seconds()
	if !ok {return}
	seek_seconds(min(max(seconds + delta, 0), ui.player_duration))
	ui.needs_redraw = true
}

start_prepared_playback :: proc(media_seconds := 0.0) {
	if state.player == nil {return}
	cancel_paused_video_frame_warmup()
	cancel_dance_count_in()
	ui.playback_completion_pending = false
	if metal_audio_play() {
		msg_void_f32(state.player, sel_registerName("setRate:"), ui.playback_rate)
		dance_schedule_continuous_metronome(active_dance_clip(), media_seconds)
	} else {
		set_error_status("Unable to start audio playback")
	}
}

start_loaded_playback_at :: proc(seconds: f64) {
	if state.player == nil {return}
	request_transcript_follow_to(seconds)
	seek_video_seconds(seconds)
	metal_audio_seek(seconds, false)
	start_prepared_playback(seconds)
}

cancel_dance_count_in :: proc() {
	ui.count_in_active = false
	ui.count_in_value = 0
	ui.count_in_remaining = 0
	ui.count_in_deadline_ms = 0
	ui.count_in_playback_deadline_ms = 0
	ui.count_in_host_scheduled = false
	ui.count_in_for_loop = false
}

dance_count_in_interval_ms :: proc(bpm: int) -> i64 {
	return max(i64(1), i64(60_000 / max(1, bpm)))
}

dance_beat_period :: proc(clip: ^Clip) -> f64 {
	if clip == nil {return 0}
	if clip.dance_beat_period_seconds >= 0.25 &&
	   clip.dance_beat_period_seconds <= 1.5 {
		return clip.dance_beat_period_seconds
	}
	return 60.0 / f64(clamp(clip.dance_count_in_bpm, 40, 240))
}

dance_beat_grid_available :: proc(clip: ^Clip) -> bool {
	return clip != nil && dance_beat_period(clip) > 0 &&
	       (clip.dance_beat_phase_user_set ||
	        clip.dance_beat_phase_confidence >= BPM_PHASE_MIN_CONFIDENCE)
}

dance_grid_offset_normalized :: proc(clip: ^Clip) -> f64 {
	period := dance_beat_period(clip)
	if period <= 0 {return 0}
	bar := period * 4
	offset := math.mod(clip.dance_beat_grid_offset_seconds, bar)
	if offset < 0 {offset += bar}
	return offset
}

dance_count_in_preroll_seconds :: proc(clip: ^Clip) -> f64 {
	if clip == nil || clip.dance_count_in_beats <= 0 {return 0}
	period := dance_beat_period(clip)
	if period <= 0 {return 0}
	phase := math.mod(dance_grid_offset_normalized(clip), period)
	return f64(clip.dance_count_in_beats)*period - phase
}

dance_schedule_metronome_clicks :: proc(
	clip: ^Clip,
	first_click_host, playback_host: u64,
) {
	if clip == nil || ui.metronome == nil {return}
	period := dance_beat_period(clip)
	rate := f64(max(ui.playback_rate, 0.1))
	for beat in 0 ..< clip.dance_count_in_beats {
		host := hw_host_time_after_seconds(
			first_click_host,
			f64(beat)*period/rate,
		)
		_ = hw_metronome_schedule(ui.metronome, host, beat%4 == 0)
	}
	if clip.dance_metronome_enabled {
		offset := dance_grid_offset_normalized(clip)
		beat_index := int(math.ceil(-offset/period))
		for scheduled := 0; scheduled < 4096; scheduled += 1 {
			media_seconds := offset + f64(beat_index)*period
			if media_seconds > ui.player_duration {break}
			if media_seconds >= 0 {
				host := hw_host_time_after_seconds(
					playback_host,
					media_seconds/rate,
				)
				accent_index := beat_index % 4
				if accent_index < 0 {accent_index += 4}
				_ = hw_metronome_schedule(
					ui.metronome,
					host,
					accent_index == 0,
				)
			}
			beat_index += 1
		}
	}
	hw_metronome_play(ui.metronome)
}

dance_schedule_continuous_metronome :: proc(
	clip: ^Clip,
	media_seconds: f64,
) {
	if ui.metronome == nil {return}
	hw_metronome_stop(ui.metronome)
	if clip == nil || !clip.dance_metronome_enabled ||
	   !dance_beat_grid_available(clip) || !metal_audio_prepare_engine() {
		return
	}
	period := dance_beat_period(clip)
	offset := dance_grid_offset_normalized(clip)
	rate := f64(max(ui.playback_rate, 0.1))
	beat_index := int(math.ceil((media_seconds-offset)/period))
	anchor_host := hw_host_time_now()
	for scheduled := 0; scheduled < 4096; scheduled += 1 {
		beat_seconds := offset + f64(beat_index)*period
		if beat_seconds > ui.player_duration {break}
		delay := (beat_seconds-media_seconds)/rate
		if delay >= 0.03 {
			host := hw_host_time_after_seconds(anchor_host, delay)
			accent_index := beat_index % 4
			if accent_index < 0 {accent_index += 4}
			_ = hw_metronome_schedule(
				ui.metronome,
				host,
				accent_index == 0,
			)
		}
		beat_index += 1
	}
	hw_metronome_play(ui.metronome)
}

dance_schedule_count_in_start :: proc(clip: ^Clip) -> (i64, bool) {
	if !dance_beat_grid_available(clip) || ui.metronome == nil ||
	   ui.audio_player == nil || !metal_audio_prepare_engine() {
		return 0, false
	}
	period := dance_beat_period(clip)
	pre_roll := dance_count_in_preroll_seconds(clip)
	rate := f64(max(ui.playback_rate, 0.1))
	delay := pre_roll / rate
	first_click_host := hw_host_time_after_seconds(hw_host_time_now(), 0.06)
	playback_host := hw_host_time_after_seconds(first_click_host, delay)
	dance_schedule_metronome_clicks(clip, first_click_host, playback_host)
	pitch_latency := 0.0
	if ui.audio_pitch != nil {
		pitch_latency = max(0.0, msg_f64(ui.audio_pitch, sel_registerName("latency")))
	}
	song_host := hw_host_time_before_seconds(playback_host, pitch_latency)
	if !hw_audio_player_play_at_host_time(ui.audio_player, song_host) {
		hw_metronome_stop(ui.metronome)
		return 0, false
	}
	return numbered_action_time_ms() + i64((delay+0.06)*1000), true
}

dance_count_in_should_start_on_resume :: proc(
	clip: ^Clip,
	seconds: f64,
	already_active: bool,
) -> bool {
	return !already_active &&
	       clip != nil &&
	       clip.workflow == .Dancing &&
	       clip.dance_count_in_beats > 0 &&
	       seconds <= 0.05
}

begin_dance_count_in :: proc(for_loop: bool) -> bool {
	clip := active_dance_clip()
	if state.player == nil ||
	   clip == nil ||
	   clip.dance_count_in_beats == 0 ||
	   (for_loop && !clip.dance_count_each_loop) {
		return false
	}
	cancel_dance_count_in()
	cancel_paused_video_frame_warmup()
	msg_void(state.player, sel_registerName("pause"))
	metal_audio_pause()
	seek_video_seconds(0, false, true)
	metal_audio_seek(0, false)
	request_transcript_follow_to(0)
	ui.playback_completion_pending = false
	ui.count_in_active = true
	ui.count_in_value = 1
	ui.count_in_remaining = clip.dance_count_in_beats
	ui.count_in_for_loop = for_loop
	playback_deadline, host_scheduled := dance_schedule_count_in_start(clip)
	ui.count_in_host_scheduled = host_scheduled
	ui.count_in_playback_deadline_ms = playback_deadline
	interval_ms := i64(dance_beat_period(clip) /
		f64(max(ui.playback_rate, 0.1)) * 1000)
	ui.count_in_deadline_ms = numbered_action_time_ms() + max(i64(1), interval_ms)
	set_text(
		state.status,
		fmt.tprintf(
			"Count-in %d of %d",
			ui.count_in_value,
			clip.dance_count_in_beats,
		),
	)
	ui.needs_redraw = true
	return true
}

start_active_clip_from_beginning :: proc(for_loop: bool) {
	if begin_dance_count_in(for_loop) {return}
	start_loaded_playback_at(0)
}

advance_dance_count_in :: proc(now_ms: i64) -> bool {
	if !ui.count_in_active {return false}
	clip := active_dance_clip()
	if clip == nil || state.player == nil {
		cancel_dance_count_in()
		return true
	}
	interval := max(
		i64(1),
		i64(dance_beat_period(clip)/f64(max(ui.playback_rate, 0.1))*1000),
	)
	changed := false
	for ui.count_in_active && now_ms >= ui.count_in_deadline_ms {
		changed = true
		if ui.count_in_remaining <= 1 {
			cancel_dance_count_in()
			start_prepared_playback(0)
			break
		}
		ui.count_in_remaining -= 1
		ui.count_in_value += 1
		if ui.count_in_remaining == 1 && ui.count_in_host_scheduled {
			ui.count_in_deadline_ms = ui.count_in_playback_deadline_ms
		} else {
			ui.count_in_deadline_ms += interval
		}
		set_text(
			state.status,
			fmt.tprintf(
				"Count-in %d of %d",
				ui.count_in_value,
				clip.dance_count_in_beats,
			),
		)
	}
	if changed {ui.needs_redraw = true}
	return changed
}

source_initial_seconds :: proc(source_index: int) -> f64 {
	if source_index < 0 || source_index >= len(state.sources) {return 0}
	source_id := state.sources[source_index].id
	for i := len(state.hints) - 1; i >= 0; i -= 1 {
		if state.hints[i].source_id == source_id {return state.hints[i].seconds}
	}
	return 0
}

source_hint_count :: proc(source_index: int) -> int {
	if source_index < 0 || source_index >= len(state.sources) {return 0}
	source_id := state.sources[source_index].id
	count := 0
	for hint in state.hints {if hint.source_id == source_id {count += 1}}
	return count
}

sorted_hint_values :: proc(hints: []Import_Hint, source_id: string, allocator := context.allocator) -> [dynamic]f64 {
	values := make([dynamic]f64, allocator)
	for hint in hints {if hint.source_id == source_id {append(&values, hint.seconds)}}
	for i in 1 ..< len(values) {
		value := values[i]
		j := i
		for j > 0 && values[j - 1] > value {values[j] = values[j - 1]; j -= 1}
		values[j] = value
	}
	return values
}

source_hint_values :: proc(source_index: int, allocator := context.allocator) -> [dynamic]f64 {
	if source_index < 0 || source_index >= len(state.sources) {return make([dynamic]f64, allocator)}
	return sorted_hint_values(state.hints[:], state.sources[source_index].id, allocator)
}

promote_source_hint :: proc(hints: []Import_Hint, source_id: string, seconds: f64) -> bool {
	hint_index := -1
	for hint, index in hints {
		if hint.source_id == source_id && hint.seconds == seconds {hint_index = index; break}
	}
	if hint_index < 0 {return false}
	selected := hints[hint_index]
	for index in hint_index ..< len(hints) - 1 {hints[index] = hints[index + 1]}
	hints[len(hints) - 1] = selected
	return true
}

select_source_hint :: proc(source_index: int, seconds: f64) -> bool {
	if source_index < 0 || source_index >= len(state.sources) {return false}
	source_id := state.sources[source_index].id
	if !promote_source_hint(state.hints[:], source_id, seconds) {return false}
	if source_index == state.active_source && state.player != nil {seek_seconds(seconds)}
	_ = save_library()
	set_success_status(fmt.tprintf("Selected source timestamp %s", format_timestamp(seconds)))
	ui.needs_redraw = true
	return true
}

stop_player_playback :: proc() {
	if state.player == nil {return}
	cancel_paused_video_frame_warmup()
	cancel_dance_count_in()
	ui.playback_completion_pending = false
	msg_void(state.player, sel_registerName("pause"))
	metal_audio_pause()
	if ui.metronome != nil {hw_metronome_stop(ui.metronome)}
	seek_seconds(0, false, true)
	ui.needs_redraw = true
}

pause_player_playback :: proc() {
	if state.player == nil {return}
	cancel_dance_count_in()
	ui.playback_completion_pending = false
	msg_void(state.player, sel_registerName("pause"))
	metal_audio_pause()
	if ui.metronome != nil {hw_metronome_stop(ui.metronome)}
	ui.needs_redraw = true
}

resume_player_playback :: proc() -> bool {
	if state.player == nil {return false}
	if ui.count_in_active {return true}
	cancel_paused_video_frame_warmup()
	seconds, ok := current_seconds()
	if !ok {return false}
	if dance_count_in_should_start_on_resume(
		active_dance_clip(),
		seconds,
		ui.count_in_active,
	) {
		start_active_clip_from_beginning(false)
		return ui.count_in_active
	}
	if playback_position_finished(seconds, ui.player_duration) {
		start_active_clip_from_beginning(false)
		return ui.count_in_active ||
		       msg_f32(state.player, sel_registerName("rate")) > 0
	}
	metal_audio_seek(seconds, false)
	if !metal_audio_play() {return false}
	msg_void_f32(state.player, sel_registerName("setRate:"), ui.playback_rate)
	dance_schedule_continuous_metronome(active_dance_clip(), seconds)
	ui.needs_redraw = true
	return true
}

playback_position_finished :: proc(seconds, duration: f64) -> bool {
	return duration > 0 && seconds >= max(0, duration - 0.05)
}

clip_autoplay_should_advance :: proc(
	enabled,
	completion_pending,
	source_playback: bool,
	mode: UI_Mode,
	active_clip,
	clip_count: int,
) -> bool {
	return enabled &&
	       completion_pending &&
	       !source_playback &&
	       mode == .Play &&
	       active_clip >= 0 &&
	       active_clip < clip_count
}

reset_player_playback :: proc() {
	if state.player == nil {return}
	seconds := 0.0
	if ui.source_playback_active && state.active_source >= 0 {
		seconds = source_initial_seconds(state.active_source)
	}
	seek_seconds(seconds)
	ui.needs_redraw = true
}

active_clip_draft :: proc() -> (Clip_Draft, bool) {
	if state.active_source < 0 || state.active_source >= len(state.sources) {
		return {}, false
	}
	return Clip_Draft{
		source_id = state.sources[state.active_source].id,
		start_seconds = state.range_start,
		end_seconds = state.range_end,
		has_start = state.has_start,
		has_end = state.has_end,
		name = ui.clip_name,
		revision = ui.clip_draft_revision,
	}, true
}

CLIP_DRAFT_PERSIST_DEBOUNCE_MS :: i64(250)

flush_active_clip_draft :: proc() -> bool {
	if !ui.clip_draft_dirty {return true}
	draft, active := active_clip_draft()
	if !active {
		set_error_status("The active clip draft is unavailable")
		return false
	}
	if database_clip_draft_save(library_database, draft) {
		ui.clip_draft_dirty = false
		ui.clip_draft_persist_due_ms = 0
		return true
	}
	ui.clip_draft_persist_due_ms = 0
	set_error_status("The clip draft could not be saved")
	return false
}

persist_active_clip_draft :: proc(debounce := false) -> bool {
	_, active := active_clip_draft()
	if !active {return false}
	ui.clip_draft_revision = max(
		i64(1),
		ui.clip_draft_revision + 1,
	)
	ui.clip_draft_dirty = true
	if debounce {
		ui.clip_draft_persist_due_ms =
			numbered_action_time_ms() +
			CLIP_DRAFT_PERSIST_DEBOUNCE_MS
		return true
	}
	return flush_active_clip_draft()
}

load_clip_draft_for_source :: proc(source_index: int) {
	state.range_start = 0
	state.range_end = 0
	state.has_start = false
	state.has_end = false
	ui.clip_draft_revision = 0
	ui.clip_draft_dirty = false
	ui.clip_draft_persist_due_ms = 0
	ui_set_string(&ui.clip_name, "")
	if source_index >= 0 && source_index < len(state.sources) {
		source_id := state.sources[source_index].id
		if draft, found := database_clip_draft_load(
			library_database,
			source_id,
		); found {
			state.range_start = draft.start_seconds
			state.range_end = draft.end_seconds
			state.has_start = draft.has_start
			state.has_end = draft.has_end
			ui.clip_draft_revision = draft.revision
			ui_set_string(&ui.clip_name, draft.name)
			clip_draft_destroy(&draft)
		}
	}
	if ui.focus == .Clip_Name {
		clear_marked_text()
		collapse_text_selection(len(ui.clip_name))
		ui.scroll_x = 0
	}
	ui.needs_redraw = true
}

apply_cleared_clip_draft :: proc(source_id: string, revision: i64) {
	if state.active_source >= 0 &&
	   state.active_source < len(state.sources) &&
	   state.sources[state.active_source].id == source_id &&
	   ui.clip_draft_revision == revision {
		reset_clip_output()
		ui.clip_draft_dirty = false
		ui.clip_draft_persist_due_ms = 0
	}
}

clear_clip_draft_after_export :: proc(source_id: string, revision: i64) -> bool {
	cleared, ok := database_clip_draft_clear_if_revision(
		library_database,
		source_id,
		revision,
	)
	if !ok {
		set_error_status("The saved clip draft could not be cleared")
		return false
	}
	if !cleared {return false}
	apply_cleared_clip_draft(source_id, revision)
	return true
}

load_source_player :: proc(index: int) -> bool {
	if index < 0 || index >= len(state.sources) { return false }
	if state.sources[index].workflow != ui.workflow {return false}
	if !flush_active_clip_draft() {return false}
	ui.source_hint_menu_open = false
	source := &state.sources[index]
	state.active_source = index
	remember_list_selection(.Create, source.id)
	load_clip_draft_for_source(index)
	source.media_available = os.exists(source.media_path)
	if !source.media_available || !media_file_validate_tracks(source.media_path, source.has_audio) {
		metal_player_clear()
		refresh_transcript()
		return false
	}
	path := source.media_path
	ui.playback_rate =
		source.workflow == .Vocal ? ui.vocal_playback_rate : 1
	if !metal_player_load(path, source.has_audio) {metal_player_clear(); return false}
	ui.player_duration = source.duration
	set_source_playback_active(true)
	if state.has_pending_hint {
		seek_seconds(state.pending_hint)
		state.has_pending_hint = false
	} else {
		seek_seconds(source_initial_seconds(index))
	}
	refresh_transcript()
	return true
}

refresh_transcript :: proc() {
	invalidate_transcript_matches()
	ui.needs_redraw = true
}

refresh_sources :: proc() {
	ui.needs_redraw = true
}

refresh_clips :: proc() {
	ui.needs_redraw = true
}

on_transcribe :: proc "c" (self: Id, command: Sel, sender: Id) {
	context = runtime.default_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	if state.active_source < 0 { set_text(state.status, "Import or select a source first"); return }
	source := &state.sources[state.active_source]
	count := load_youtube_transcript(source)
	refresh_transcript()
	if count > 0 { set_text(state.status, fmt.tprintf("Loaded %d YouTube caption segment(s)", count)) }
	else { set_text(state.status, "No YouTube caption track was downloaded for this video") }
}

on_seek_transcript :: proc "c" (self: Id, command: Sel, sender: Id) {
	context = runtime.default_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	tag := msg_uint(sender, sel_registerName("tag"))
	seek_seconds(f64(tag)/1000)
}

export_clip :: proc(
	clip: ^Clip,
	source_path: string,
	allocator := context.allocator,
	log_path := "",
	has_audio := true,
) -> bool {
	dir := workflow_clip_directory(clip.workflow)
	os.make_directory(dir)
	clip.clip_path = fmt.aprintf("%s/%s.mp4", dir, clip.id, allocator=allocator)
	command := clip_export_command(
		source_path,
		clip.clip_path,
		clip.start_seconds,
		clip.end_seconds,
		log_path = log_path,
		has_audio = has_audio,
	)
	c_command := strings.clone_to_cstring(command)
	defer delete(c_command)
	run := transmute(proc "c" (cstring) -> int)system_address
	return run(c_command) == 0
}

export_job_cancel :: proc(job: ^Export_Job) {
	if job == nil {
		return
	}
	sync.mutex_lock(&job.process_mutex)
	job.cancelled = true
	if job.has_process {
		_ = kill(i32(job.process.pid), 15)
	}
	sync.mutex_unlock(&job.process_mutex)
}

export_job_execute :: proc(job: ^Export_Job) -> bool {
	allocator := mem_virtual.arena_allocator(job.arena)
	dir := workflow_clip_directory(job.clip.workflow)
	os.make_directory(dir)
	job.clip.clip_path = fmt.aprintf(
		"%s/%s.mp4",
		dir,
		job.clip.id,
		allocator = allocator,
	)
	command := clip_export_command(
		job.source_path,
		job.clip.clip_path,
		job.clip.start_seconds,
		job.clip.end_seconds,
		log_path = job.log_path,
		has_audio = job.has_audio,
	)
	arguments := []string{"/bin/sh", "-c", command}
	process, start_error := os2.process_start({command = arguments})
	if start_error != nil {
		return false
	}
	sync.mutex_lock(&job.process_mutex)
	job.process = process
	job.has_process = true
	cancelled := job.cancelled
	if cancelled {
		_ = kill(i32(process.pid), 15)
	}
	sync.mutex_unlock(&job.process_mutex)
	process_state, wait_error := os2.process_wait(process)
	sync.mutex_lock(&job.process_mutex)
	job.has_process = false
	cancelled = job.cancelled
	sync.mutex_unlock(&job.process_mutex)
	return !cancelled && wait_error == nil && process_state.success
}

clip_normalize_failure_add :: proc(
	job: ^Clip_Normalize_Job,
	clip_id,
	reason: string,
) {
	if job == nil {return}
	append(&job.failures, CLI_Clip_Normalize_Failure{
		clip_id = strings.clone(clip_id),
		reason = strings.clone(reason),
		diagnostic_log = strings.clone(job.log_path),
	})
}

clip_normalize_job_cancel :: proc(job: ^Clip_Normalize_Job) {
	if job == nil {return}
	sync.mutex_lock(&job.process_mutex)
	job.cancelled = true
	if job.has_process {_ = kill(i32(job.process.pid), 15)}
	sync.mutex_unlock(&job.process_mutex)
}

clip_normalize_job_is_cancelled :: proc(job: ^Clip_Normalize_Job) -> bool {
	if job == nil {return true}
	sync.mutex_lock(&job.process_mutex)
	cancelled := job.cancelled
	sync.mutex_unlock(&job.process_mutex)
	return cancelled
}

clip_normalize_process_run :: proc(
	job: ^Clip_Normalize_Job,
	command: string,
) -> bool {
	arguments := []string{"/bin/sh", "-c", command}
	process, start_error := os2.process_start({command = arguments})
	if start_error != nil {return false}
	sync.mutex_lock(&job.process_mutex)
	job.process = process
	job.has_process = true
	cancelled := job.cancelled
	if cancelled {_ = kill(i32(process.pid), 15)}
	sync.mutex_unlock(&job.process_mutex)
	process_state, wait_error := os2.process_wait(process)
	sync.mutex_lock(&job.process_mutex)
	job.has_process = false
	cancelled = job.cancelled
	sync.mutex_unlock(&job.process_mutex)
	return !cancelled && wait_error == nil && process_state.success
}

clip_normalize_job_execute :: proc(job: ^Clip_Normalize_Job) {
	if job == nil {return}
	job.total = len(job.library.clips)
	for clip in job.library.clips {
		if clip_normalize_job_is_cancelled(job) {break}
		source_index := source_index_for_id(
			job.library.sources[:],
			clip.source_id,
		)
		if source_index < 0 {
			clip_normalize_failure_add(job, clip.id, "The source record is missing")
			continue
		}
		source := &job.library.sources[source_index]
		clean_source_path, _ := filepath.clean(source.media_path, context.temp_allocator)
		clean_clip_path, _ := filepath.clean(clip.clip_path, context.temp_allocator)
		if clean_source_path == clean_clip_path {
			clip_normalize_failure_add(job, clip.id, "The clip path matches its source path")
			continue
		}
		if !os.exists(source.media_path) {
			clip_normalize_failure_add(job, clip.id, "The source media file is missing")
			continue
		}
		if !valid_clip_range(clip.start_seconds, clip.end_seconds, source.duration) {
			clip_normalize_failure_add(job, clip.id, "The saved clip range is invalid")
			continue
		}
		staging_path := fmt.tprintf(
			"%s.normalize-%020d.tmp.mp4",
			clip.clip_path,
			job.operation_id,
		)
		_ = os.remove(staging_path)
		command := clip_export_command(
			source.media_path,
			staging_path,
			clip.start_seconds,
			clip.end_seconds,
			log_path = job.log_path,
			has_audio = source.has_audio,
		)
		if !clip_normalize_process_run(job, command) {
			_ = os.remove(staging_path)
			if !clip_normalize_job_is_cancelled(job) {
				clip_normalize_failure_add(job, clip.id, "FFmpeg failed")
			}
			continue
		}
		if !media_file_validate_tracks(staging_path, source.has_audio) {
			_ = os.remove(staging_path)
			clip_normalize_failure_add(job, clip.id, "The staged clip failed media validation")
			continue
		}
		if !os.rename(staging_path, clip.clip_path) {
			_ = os.remove(staging_path)
			clip_normalize_failure_add(job, clip.id, "The staged clip could not replace the current file")
			continue
		}
		job.rebuilt += 1
	}
}

clip_normalize_job_destroy :: proc(job: ^Clip_Normalize_Job) {
	if job == nil {return}
	app_state_collections_destroy(&job.library)
	for failure in job.failures {
		delete(failure.clip_id)
		delete(failure.reason)
		delete(failure.diagnostic_log)
	}
	delete(job.failures)
	delete(job.log_path)
	free(job)
}

clip_normalize_result :: proc(job: ^Clip_Normalize_Job) -> CLI_Result {
	failed := len(job.failures)
	ok := !job.cancelled && failed == 0
	exit_code := CLI_Exit.Success
	error: CLI_Error_Data
	if job.cancelled {
		exit_code = .Busy
		error = {code = "cancelled", message = "Clip normalization was cancelled", diagnostic_log = job.log_path}
	} else if failed > 0 {
		exit_code = .Media
		error = {code = "clip_normalization_failed", message = "One or more clips could not be normalized", diagnostic_log = job.log_path}
	}
	data := CLI_Clip_Normalize_Data{
		total = job.total,
		rebuilt = job.rebuilt,
		failed = failed,
		cancelled = job.cancelled,
		failures = job.failures[:],
	}
	if ok {
		response := CLI_Clip_Normalize_Success_Response{
			ok = true,
			command = cli_command_name(.Clip_Normalize_Timestamps),
			data = data,
		}
		return {output = cli_encode(response), exit_code = exit_code}
	}
	response := CLI_Clip_Normalize_Failure_Response{
		ok = ok,
		command = cli_command_name(.Clip_Normalize_Timestamps),
		data = data,
		error = error,
	}
	return {output = cli_encode(response), exit_code = exit_code}
}

clip_normalize_finish :: proc(job: ^Clip_Normalize_Job) {
	if job == nil {return}
	result := clip_normalize_result(job)
	if job.cancelled {
		_ = notification_finish(job.notification_id, .Interrupted, "Clip normalization stopped")
	} else if len(job.failures) > 0 {
		_ = notification_finish(
			job.notification_id,
			.Error,
			fmt.tprintf(
				"Normalized %d of %d clips",
				job.rebuilt,
				job.total,
			),
			fmt.tprintf("Inspect the diagnostic log at %s", job.log_path),
		)
	} else {
		_ = notification_finish(
			job.notification_id,
			.Success,
			fmt.tprintf("Normalized %d clips", job.rebuilt),
		)
	}
	cli_ipc_work_finish(job.cli_work, result)
}

on_clip_normalize_finished :: proc "c" (self: Id, command: Sel, sender: Id) {
	context = runtime.default_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	job := clip_normalize_job
	clip_normalize_job = nil
	clip_normalize_finish(job)
	if job != nil {media_task_completion_finish(&job.completion)}
}

import_job_destroy :: proc(job: ^Import_Job) {
	if job == nil { return }
	transcript_generation_destroy(&job.snapshot_transcripts)
	transcript_generation_destroy(&job.transcripts)
	growing_arena_destroy(job.arena)
	free(job)
}

import_job_create :: proc(
	input: string,
	replace_video_id := "",
	workflow := ui.workflow,
) -> ^Import_Job {
	arena, ok := growing_arena_create()
	if !ok { return nil }
	job := new(Import_Job)
	job.arena = arena
	job.completion_target = state.delegate_target
	allocator := mem_virtual.arena_allocator(arena)
	job.operation_id = next_media_operation_id()
	job.progress_path = strings.clone(
		import_progress_path(job.operation_id),
		allocator,
	)
	job.log_path = strings.clone(
		import_log_path(job.operation_id),
		allocator,
	)
	job.applied_source_index = -1
	job.input = strings.clone(input, allocator)
	job.workflow = workflow
	job.replace_video_id = strings.clone(replace_video_id, allocator)
	job.sources = make([dynamic]Source_Video, 0, len(state.sources), allocator)
	job.hints = make([dynamic]Import_Hint, 0, len(state.hints), allocator)
	job.clips = make([dynamic]Clip, 0, len(state.clips), allocator)
	job.new_sources = make([dynamic]Source_Video, allocator)
	job.new_hints = make([dynamic]Import_Hint, allocator)
	job.qualities = make([dynamic]Import_Quality, allocator)
	if len(replace_video_id) == 0 {
		for result in source_probe_results {
			if result.selected_height > 0 {
				append(
					&job.qualities,
					Import_Quality {
						video_id = strings.clone(result.video_id, allocator),
						height = result.selected_height,
						auth_browser = result.auth_browser,
					},
				)
			}
		}
	}
	for source in state.sources {
		copy, copied := clone_source_video(source, allocator)
		if !copied { import_job_destroy(job); return nil }
		append(&job.sources, copy)
	}
	for hint in state.hints {
		copy, copied := clone_import_hint(hint, allocator)
		if !copied { import_job_destroy(job); return nil }
		append(&job.hints, copy)
	}
	for clip in state.clips {
		copy, copied := clone_clip(clip, allocator)
		if !copied { import_job_destroy(job); return nil }
		append(&job.clips, copy)
	}
	job.snapshot_transcripts, ok = transcript_generation_copy(state.transcripts.segments[:])
	if !ok { import_job_destroy(job); return nil }
	return job
}

import_job_create_local :: proc(
	path: string,
	title := "",
	workflow := ui.workflow,
) -> ^Import_Job {
	job := import_job_create("", workflow=workflow)
	if job == nil {return nil}
	allocator := mem_virtual.arena_allocator(job.arena)
	job.local_path = strings.clone(path, allocator)
	job.local_title = strings.clone(title, allocator)
	return job
}

import_job_find_source :: proc(job: ^Import_Job, video_id: string) -> ^Source_Video {
	for &source in job.sources {
		if source.workflow == job.workflow && source.video_id == video_id {
			return &source
		}
	}
	for &source in job.new_sources {
		if source.workflow == job.workflow && source.video_id == video_id {
			return &source
		}
	}
	return nil
}

import_job_has_hint :: proc(job: ^Import_Job, source_id: string, seconds: f64) -> bool {
	for hint in job.hints { if hint.source_id == source_id && hint.seconds == seconds { return true } }
	for hint in job.new_hints { if hint.source_id == source_id && hint.seconds == seconds { return true } }
	return false
}

import_job_add_hint :: proc(job: ^Import_Job, source_id: string, seconds: f64) -> bool {
	if import_job_has_hint(job, source_id, seconds) { return false }
	allocator := mem_virtual.arena_allocator(job.arena)
	append(&job.new_hints, Import_Hint{source_id=strings.clone(source_id, allocator), seconds=seconds})
	job.pending_hint, job.has_pending_hint = seconds, true
	return true
}

import_job_cancel :: proc(job: ^Import_Job) {
	if job == nil {return}
	sync.mutex_lock(&job.process_mutex)
	job.cancelled = true
	if job.has_process {_ = kill(i32(job.process.pid), 15)}
	sync.mutex_unlock(&job.process_mutex)
}

import_job_is_cancelled :: proc(job: ^Import_Job) -> bool {
	sync.mutex_lock(&job.process_mutex)
	cancelled := job.cancelled
	sync.mutex_unlock(&job.process_mutex)
	return cancelled
}

download_format_selector :: proc(maximum_height: int, exact := false) -> string {
	if maximum_height <= 0 {return "bv*[ext=mp4][vcodec^=avc1]+ba[ext=m4a]/b[ext=mp4][vcodec^=avc1]"}
	if exact {
		return fmt.tprintf(
			"bv*[height=%d][ext=mp4][vcodec^=avc1]+ba[ext=m4a]/b[height=%d][ext=mp4][vcodec^=avc1]",
			maximum_height,
			maximum_height,
		)
	}
	return fmt.tprintf("bv*[height<=%d][ext=mp4][vcodec^=avc1]+ba[ext=m4a]/b[height<=%d][ext=mp4][vcodec^=avc1]", maximum_height, maximum_height)
}

import_job_selected_quality :: proc(
	job: ^Import_Job,
	video_id: string,
) -> (
	height: int,
	exact: bool,
	auth_browser: Source_Auth_Browser,
) {
	for quality in job.qualities {
		if quality.video_id == video_id {
			return quality.height, quality.exact, quality.auth_browser
		}
	}
	return 0, false, .None
}

import_job_auth_browser :: proc(job: ^Import_Job) -> Source_Auth_Browser {
	for quality in job.qualities {
		if quality.auth_browser != .None {return quality.auth_browser}
	}
	return .None
}

staged_source_cleanup :: proc(directory, staging_name: string) {
	handle, open_error := os.open(directory)
	if open_error != nil {return}
	defer os.close(handle)
	entries, read_error := os.read_dir(handle, -1, context.temp_allocator)
	if read_error != nil {return}
	prefix := fmt.tprintf("%s.", staging_name)
	for entry in entries {
		if strings.has_prefix(entry.name, prefix) {_ = os.remove(fmt.tprintf("%s/%s", directory, entry.name))}
	}
}

staged_source_validate :: proc(directory, staging_name: string) -> bool {
	media_path := fmt.tprintf("%s/%s.mp4", directory, staging_name)
	info_path := fmt.tprintf("%s/%s.info.json", directory, staging_name)
	bytes, read_ok := os.read_entire_file(info_path, context.temp_allocator)
	if !read_ok {return false}
	metadata: YTDLP_Metadata
	if parse_error := json.unmarshal(bytes, &metadata, .JSON, context.temp_allocator); parse_error != nil {return false}
	video_ok := strings.has_prefix(metadata.vcodec, "avc1") || strings.has_prefix(metadata.vcodec, "h264")
	audio_ok := strings.has_prefix(metadata.acodec, "mp4a") || strings.has_prefix(metadata.acodec, "aac")
	if metadata.width <= 0 || metadata.height <= 0 || !video_ok || !audio_ok {return false}
	return media_file_validate(media_path)
}

staged_source_encode_hevc :: proc(job: ^Import_Job, directory, staging_name: string) -> bool {
	media_path := fmt.tprintf("%s/%s.mp4", directory, staging_name)
	encoded_path := fmt.tprintf("%s/%s.hevc.mp4", directory, staging_name)
	_ = os.remove(encoded_path)
	defer _ = os.remove(encoded_path)
	command := make([dynamic]string, context.temp_allocator)
	append(
		&command,
		helper_command("ffmpeg"), "-y", "-v", "error", "-i", media_path,
		"-map", "0:v:0", "-map", "0:a:0",
		"-c:v", "hevc_videotoolbox",
		"-profile:v", "main",
		"-pix_fmt", "yuv420p",
		"-q:v", fmt.tprintf("%d", MANAGED_HEVC_QUALITY),
		"-tag:v", MANAGED_HEVC_TAG,
		"-c:a", "copy",
		"-movflags", "+faststart",
		encoded_path,
	)
	import_job_set_phase(job, .Encoding_Downloaded_Media)
	if !local_source_run_ffmpeg(job, command[:]) ||
	   !managed_hevc_file_validate(encoded_path, true) {
		return false
	}
	return os.rename(encoded_path, media_path)
}

media_file_validate :: proc(media_path: string) -> bool {
	return media_file_validate_tracks(media_path, true)
}

media_file_validate_tracks :: proc(media_path: string, expect_audio: bool) -> bool {
	if !expect_audio {
		command := [12]string{helper_command("ffmpeg"), "-v", "error", "-i", media_path, "-map", "0:v:0", "-t", "1", "-f", "null", "-"}
		process_state, _, _, process_error := os2.process_exec({command=command[:]}, context.temp_allocator)
		return process_error == nil && process_state.success
	}
	command := [14]string{helper_command("ffmpeg"), "-v", "info", "-i", media_path, "-map", "0:v:0", "-map", "0:a:0", "-t", "1", "-f", "null", "-"}
	process_state, stdout, stderr, process_error := os2.process_exec({command=command[:]}, context.temp_allocator)
	_ = stdout
	video_ok := strings.contains(string(stderr), "Video: h264") ||
	            strings.contains(string(stderr), "Video: hevc")
	streams_ok := video_ok && strings.contains(string(stderr), "Audio: aac")
	return process_error == nil && process_state.success && streams_ok
}

staged_source_commit :: proc(
	directory,
	staging_name,
	video_id: string,
) -> bool {
	handle, open_error := os.open(directory)
	if open_error != nil {return false}
	defer os.close(handle)
	entries, read_error := os.read_dir(handle, -1, context.temp_allocator)
	if read_error != nil {return false}
	prefix := fmt.tprintf("%s.", staging_name)
	media_name := fmt.tprintf("%s.mp4", staging_name)
	for entry in entries {
		if !strings.has_prefix(entry.name, prefix) || entry.name == media_name {continue}
		suffix := entry.name[len(prefix):]
		if !os.rename(fmt.tprintf("%s/%s", directory, entry.name), fmt.tprintf("%s/%s.%s", directory, video_id, suffix)) {return false}
	}
	return os.rename(fmt.tprintf("%s/%s", directory, media_name), fmt.tprintf("%s/%s.mp4", directory, video_id))
}

import_job_run_download :: proc(
	job: ^Import_Job,
	url, output: string,
	maximum_height := 0,
	exact_height := false,
	auth_browser := Source_Auth_Browser.None,
) -> bool {
	progress_file, progress_error := os2.open(job.progress_path, {.Write, .Create, .Trunc, .Inheritable})
	if progress_error != nil {return false}
	log_file, log_error := os2.open(job.log_path, {.Write, .Create, .Append, .Inheritable})
	if log_error != nil {return false}
	defer os2.close(log_file)
	import_job_set_phase(job, .Downloading)
	command := import_download_command(
		url,
		output,
		maximum_height,
		exact_height,
		auth_browser,
		context.temp_allocator,
	)
	process, start_error := os2.process_start({command=command[:], stdout=progress_file, stderr=log_file})
	if start_error != nil {return false}
	sync.mutex_lock(&job.process_mutex)
	job.process, job.has_process = process, true
	cancelled := job.cancelled
	if cancelled {_ = kill(i32(process.pid), 15)}
	sync.mutex_unlock(&job.process_mutex)
	process_state, wait_error := os2.process_wait(process)
	sync.mutex_lock(&job.process_mutex)
	job.has_process = false
	cancelled = job.cancelled
	sync.mutex_unlock(&job.process_mutex)
	return !cancelled && wait_error == nil && process_state.success
}

import_download_command :: proc(
	url, output: string,
	maximum_height := 0,
	exact_height := false,
	auth_browser := Source_Auth_Browser.None,
	allocator := context.allocator,
) -> [dynamic]string {
	format_selector := download_format_selector(maximum_height, exact_height)
	command := make([dynamic]string, allocator)
	append(&command, helper_command("yt-dlp"))
	if auth_browser != .None {
		append(
			&command,
			"--cookies-from-browser",
			source_auth_browser_argument(auth_browser),
		)
	}
	append(
		&command,
		"--no-playlist",
		"--force-overwrites",
		"--write-info-json",
		"--write-subs",
		"--write-auto-subs",
		"--sub-langs",
		"en,.*-orig",
		"--sub-format",
		"json3",
		"--ffmpeg-location",
		helper_command("ffmpeg"),
		"-f",
		format_selector,
		"-S",
		"res,vcodec:h264",
		"--merge-output-format",
		"mp4",
		"--newline",
		"--progress-template",
		"download:HW_VIDEO_CLIPS_PROGRESS|%(progress._percent_str)s|%(progress._total_bytes_str)s|%(progress._speed_str)s|%(progress._eta_str)s",
		"-o",
		output,
		url,
	)
	return command
}

import_job_rebuild_clips :: proc(job: ^Import_Job, source: ^Source_Video) {
	import_job_set_phase(job, .Rebuilding_Clips)
	run := transmute(proc "c" (cstring) -> int)system_address
	os.make_directory(workflow_clip_directory(source.workflow))
	for clip in job.clips {
		if clip.source_id != source.id || len(clip.clip_path) == 0 {continue}
		command := clip_export_command(
			source.media_path,
			clip.clip_path,
			clip.start_seconds,
			clip.end_seconds,
			log_path = job.log_path,
		)
		c_command := strings.clone_to_cstring(command)
		result := run(c_command)
		delete(c_command)
		if result == 0 {
			job.refreshed_clips += 1
		} else {
			job.failed_clip_refreshes += 1
		}
	}
}

import_job_process_url :: proc(job: ^Import_Job, url: string) -> bool {
	video_id, valid := parse_video_id(url)
	if !valid { return false }
	allocator := mem_virtual.arena_allocator(job.arena)
	job.last_video_id = strings.clone(video_id, allocator)
	if source := import_job_find_source(job, video_id); source != nil {
		if video_id != job.replace_video_id {
			job.existing_sources += 1
			if seconds, has_time := parse_timestamp(url); has_time {
				if import_job_add_hint(job, source.id, seconds) {
					job.updated_hints += 1
					job.latest_updated_hint = seconds
				}
			}
			return true
		}
		if job.reuse_existing_media && os.exists(source.media_path) {
			import_job_set_phase(job, .Validating_Existing_Media)
			if media_file_validate(source.media_path) {
				import_job_rebuild_clips(job, source)
				return true
			}
		}
		if job.library_recovery_source && source.metadata.height <= 0 {
			return false
		}
	}

	source_directory := workflow_source_directory(job.workflow)
	os.make_directory(source_directory)
	staging_name := fmt.tprintf(
		"%s.download-%020d",
		video_id,
		job.operation_id,
	)
	staged_source_cleanup(source_directory, staging_name)
	output := fmt.tprintf("%s/%s.%%(ext)s", source_directory, staging_name)
	selected_height, exact_height, auth_browser :=
		import_job_selected_quality(job, video_id)
	if !import_job_run_download(
		job,
		url,
		output,
		selected_height,
		exact_height,
		auth_browser,
	) {
		staged_source_cleanup(source_directory, staging_name)
		return false
	}
	import_job_set_phase(job, .Validating_Downloaded_Media)
	if !staged_source_validate(source_directory, staging_name) ||
	   !staged_source_encode_hevc(job, source_directory, staging_name) {
		job.invalid_merged_media += 1
		staged_source_cleanup(source_directory, staging_name)
		return false
	}
	import_job_set_phase(job, .Validating_Downloaded_Media)
	if !managed_hevc_file_validate(
		fmt.tprintf("%s/%s.mp4", source_directory, staging_name),
		true,
	) || !staged_source_commit(source_directory, staging_name, video_id) {
		job.invalid_merged_media += 1
		staged_source_cleanup(source_directory, staging_name)
		return false
	}
	media_path := fmt.tprintf("%s/%s.mp4", source_directory, video_id)
	if !os.exists(media_path) {
		job.missing_merged_media += 1
		return false
	}

	existing := import_job_find_source(job, video_id)
	source_id := source_id_for_workflow(job.workflow, video_id)
	if existing != nil { source_id = existing.id }
	source := Source_Video{
		id=strings.clone(source_id, allocator),
		workflow=job.workflow,
		kind=.YouTube,
		video_id=strings.clone(video_id, allocator),
		title=strings.clone(video_id, allocator),
		url=strings.clone(url, allocator),
		media_path=strings.clone(media_path, allocator),
		media_available=true,
		has_audio=true,
	}
	if metadata, loaded := load_download_metadata(
		video_id,
		job.workflow,
		allocator,
	); loaded {
		delete(source.title, allocator)
		source.title = metadata.title
		source.duration = metadata.duration
		delete(metadata.vcodec, allocator)
		delete(metadata.acodec, allocator)
		delete(metadata.ext, allocator)
		source.metadata = Source_Context_Metadata {
			width = metadata.width,
			height = metadata.height,
			fps = metadata.fps,
			vcodec = strings.clone(MANAGED_HEVC_CODEC, allocator),
			acodec = strings.clone("aac", allocator),
			ext = strings.clone("mp4", allocator),
			format_id = metadata.format_id,
			filesize_approx = metadata.filesize_approx,
		}
		source.metadata_status = .Available
		if file_info, stat_error := os.stat(source.media_path, context.temp_allocator); stat_error == nil {
			source.metadata.filesize_approx = file_info.size
		}
	}
	if existing != nil {
		job.updated_source = source
		job.has_source_update = true
	} else {
		append(&job.new_sources, source)
	}
	if seconds, has_time := parse_timestamp(url); has_time {_ = import_job_add_hint(job, source.id, seconds)}

	previous := job.snapshot_transcripts.segments[:]
	if job.has_transcript_update { previous = job.transcripts.segments[:] }
	if next, _, loaded := build_transcript_generation(&source, previous); loaded {
		transcript_generation_destroy(&job.transcripts)
		job.transcripts = next
		job.has_transcript_update = true
	}
	if existing != nil {
		import_job_rebuild_clips(job, &source)
	}
	return true
}

import_job_execute :: proc(job: ^Import_Job) {
	context = runtime.default_context()
	if len(job.local_path) > 0 {
		if import_job_process_local(job) {job.accepted += 1} else {job.failed += 1}
		return
	}
	for raw in strings.split_lines(job.input) {
		if import_job_is_cancelled(job) {break}
		url := strings.trim_space(raw)
		if len(url) == 0 { continue }
		if import_job_process_url(job, url) { job.accepted += 1 } else { job.failed += 1 }
	}
}

import_job_apply :: proc(job: ^Import_Job) -> bool {
	if job == nil || job.accepted <= 0 {return false}
	candidate, candidate_copied := app_state_collections_clone(&state)
	if !candidate_copied {return false}
	defer app_state_collections_destroy(&candidate)

	if job.has_source_update {
		updated := false
		for &source in candidate.sources {
			if source.workflow != job.updated_source.workflow ||
			   source.video_id != job.updated_source.video_id {
				continue
			}
			copy, copied := clone_source_video(job.updated_source)
			if !copied {return false}
			delete_source_video(&source)
			source = copy
			updated = true
			break
		}
		if !updated {return false}
	}
	for source in job.new_sources {
		copy, copied := clone_source_video(source)
		if !copied {return false}
		existing_index := source_index_for_video_id(
			candidate.sources[:],
			source.video_id,
			source.workflow,
		)
		if existing_index >= 0 {
			delete_source_video(&candidate.sources[existing_index])
			candidate.sources[existing_index] = copy
		} else {
			append(&candidate.sources, copy)
		}
	}
	for hint in job.new_hints {
		duplicate := false
		for current_hint in candidate.hints {
			if current_hint.source_id == hint.source_id &&
			   current_hint.seconds == hint.seconds {
				duplicate = true
				break
			}
		}
		if duplicate {
			continue
		}
		copy, copied := clone_import_hint(hint)
		if !copied {return false}
		append(&candidate.hints, copy)
	}
	if job.has_transcript_update {
		source_id := ""
		if job.has_source_update &&
		   job.updated_source.video_id == job.last_video_id {
			source_id = job.updated_source.id
		}
		if len(source_id) == 0 {
			for source in job.new_sources {
				if source.video_id == job.last_video_id &&
				   source.workflow == job.workflow {
					source_id = source.id
					break
				}
			}
		}
		if len(source_id) == 0 {
			source_id = source_id_for_workflow(
				job.workflow,
				job.last_video_id,
			)
		}
		transcripts, transcripts_copied := transcript_generation_replace_source(
			&candidate.transcripts,
			&job.transcripts,
			source_id,
		)
		if !transcripts_copied {return false}
		transcript_generation_destroy(&candidate.transcripts)
		candidate.transcripts = transcripts
	}
	if !commit_library_state(
		&candidate,
		.Source_Import,
		job.allow_without_backup,
	) {
		return false
	}
	for source, index in state.sources {
		if source.workflow == job.workflow &&
		   source.video_id == job.last_video_id {
			job.applied_source_index = index
			break
		}
	}
	if job.has_pending_hint {state.pending_hint, state.has_pending_hint = job.pending_hint, true}
	return true
}

finish_import_job :: proc(job: ^Import_Job) {
	if job == nil {
		return
	}
	defer {
		_ = import_jobs_remove(job)
		media_task_completion_finish(&job.completion)
	}
	if job.cli_work != nil {
		cli_source_add_finish(job)
		return
	}
	if job.library_recovery_source {
		success := false
		if !job.cancelled && job.accepted > 0 {
			success = import_job_apply(job) &&
			          job.failed == 0 &&
			          job.failed_clip_refreshes == 0
			refresh_sources()
			refresh_clips()
		}
		cancelled := job.cancelled
		if library_recovery == nil {
			return
		}
		if cancelled {
			library_recovery.cancelled = true
			library_recovery_finish()
			return
		}
		if success {
			library_recovery.recovered += 1
		} else {
			library_recovery.failed += 1
			if job.accepted == 0 {
				if source_index := source_index_for_video_id(
					state.sources[:],
					job.replace_video_id,
					job.workflow,
				); source_index >= 0 {
					state.sources[source_index].media_available = false
				}
			}
		}
		library_recovery_start_next()
		return
	}
	if job.cancelled {
		_ = notification_finish(
			job.notification_id,
			.Interrupted,
			"Download stopped",
			"The user stopped the active media operation.",
		)
		return
	}
	if job.accepted > 0 {
		if import_job_apply(job) {
			if should_load_completed_source(
				job.has_source_update,
				state.active_source,
				job.applied_source_index,
			) {
				load_source_player(job.applied_source_index)
			}
			refresh_sources()
		} else {
			_ = notification_finish(
				job.notification_id,
				.Error,
				"The import completed, but the library update failed",
				"The downloaded files were preserved, but SQLite did not accept the updated library records.",
			)
			return
		}
	}
	if job.failed > 0 {
		if len(job.replace_video_id) > 0 &&
		   should_load_completed_source(
				true,
				state.active_source,
				job.applied_source_index,
		   ) {
			load_source_player(job.applied_source_index)
		}
		if job.invalid_merged_media > 0 {
			_ = notification_finish(
				job.notification_id,
				.Error,
				"Download failed media validation",
				"The staged MP4 could not be converted to validated HEVC video with AAC audio. The previous source file was preserved.",
			)
		} else if job.missing_merged_media > 0 {
			_ = notification_finish(
				job.notification_id,
				.Error,
				"Import failed: yt-dlp did not create the merged MP4",
				fmt.tprintf("Inspect the diagnostic log at %s", job.log_path),
			)
		} else if len(job.replace_video_id) > 0 &&
		          job.applied_source_index >= 0 {
			_ = notification_finish(
				job.notification_id,
				.Error,
				"Refetch failed",
				fmt.tprintf("Inspect the diagnostic log at %s", job.log_path),
			)
		} else {
			_ = notification_finish(
				job.notification_id,
				.Error,
				fmt.tprintf("Imported %d source(s); %d failed", job.accepted, job.failed),
				fmt.tprintf("Inspect the diagnostic log at %s", job.log_path),
			)
		}
	} else if job.has_source_update {
		if job.failed_clip_refreshes > 0 {
			_ = notification_finish(
				job.notification_id,
				.Error,
				fmt.tprintf(
					"Refetched source; %d clip rebuild(s) failed",
					job.failed_clip_refreshes,
				),
				fmt.tprintf("Inspect the diagnostic log at %s", job.log_path),
			)
		} else {
			_ = notification_finish(
				job.notification_id,
				.Success,
				fmt.tprintf("Refetched source and rebuilt %d clip(s)", job.refreshed_clips),
			)
		}
	} else if len(job.new_sources) > 0 {
		_ = notification_finish(
			job.notification_id,
			.Success,
			import_success_status(
				len(job.new_sources),
				job.existing_sources,
				job.updated_hints,
				job.latest_updated_hint,
			),
		)
	} else if job.existing_sources > 0 {
		_ = notification_finish(
			job.notification_id,
			.Success,
			import_success_status(
				0,
				job.existing_sources,
				job.updated_hints,
				job.latest_updated_hint,
			),
		)
	}
	if job.has_source_update {
		set_status_source(job.updated_source.video_id)
	} else if job.failed > 0 && len(job.replace_video_id) > 0 {
		set_status_source(job.replace_video_id)
	}
}

on_import_finished :: proc "c" (self: Id, command: Sel, sender: Id) {
	context = runtime.default_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	for {
		sync.mutex_lock(&import_completion_mutex)
		if len(import_completed_jobs) == 0 {
			sync.mutex_unlock(&import_completion_mutex)
			break
		}
		job := pop(&import_completed_jobs)
		sync.mutex_unlock(&import_completion_mutex)
		finish_import_job(job)
	}
}

source_metadata_job_destroy :: proc(job: ^Source_Metadata_Job) {
	if job == nil {return}
	delete(job.video_id)
	delete(job.media_path)
	delete_source_context_metadata(&job.metadata)
	free(job)
}

source_metadata_worker :: proc(t: ^thread.Thread) {
	context = runtime.default_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	job := cast(^Source_Metadata_Job)t.data
	job.metadata, job.metadata_loaded = load_source_context_metadata(
		job.video_id,
		job.workflow,
	)
	if actual, probed := local_source_probe(job.media_path); probed {
		if job.metadata_loaded {
			delete(actual.metadata.format_id)
			actual.metadata.format_id = job.metadata.format_id
			job.metadata.format_id = ""
		}
		delete_source_context_metadata(&job.metadata)
		job.metadata = actual.metadata
		actual.metadata = {}
		job.metadata_loaded = true
	}
	if file_info, stat_error := os.stat(job.media_path, context.temp_allocator); stat_error == nil {
		job.metadata.filesize_approx = file_info.size
	}
	msg_void_sel_id_b(job.completion_target, sel_registerName("performSelectorOnMainThread:withObject:waitUntilDone:"), sel_registerName("sourceMetadataFinished:"), nil, false)
}

request_source_metadata :: proc(
	video_id,
	media_path: string,
	workflow: Workflow_Kind,
) {
	if source_metadata_job != nil {return}
	for source in state.sources {
		if source.workflow == workflow &&
		   source.video_id == video_id &&
		   source.metadata_status != .Missing {
			return
		}
	}
	job := new(Source_Metadata_Job)
	job.completion_target = state.delegate_target
	job.video_id = strings.clone(video_id)
	job.workflow = workflow
	job.media_path = strings.clone(media_path)
	worker := thread.create(source_metadata_worker)
	if worker == nil {
		source_metadata_job_destroy(job)
		return
	}
	job.thread = worker
	worker.data = job
	source_metadata_job = job
	thread.start(worker)
}

request_next_missing_source_metadata :: proc() {
	if source_metadata_job != nil {return}
	if ui.source_details_open && ui.source_details_index >= 0 && ui.source_details_index < len(state.sources) {
		source := &state.sources[ui.source_details_index]
		if source.metadata_status == .Missing {
			request_source_metadata(
				source.video_id,
				source.media_path,
				source.workflow,
			)
			return
		}
	}
	for source in state.sources {
		if source.metadata_status == .Missing {
			request_source_metadata(
				source.video_id,
				source.media_path,
				source.workflow,
			)
			return
		}
	}
}

on_source_metadata_finished :: proc "c" (self: Id, command: Sel, sender: Id) {
	context = runtime.default_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	job := source_metadata_job
	if job == nil {return}
	thread.join(job.thread)
	thread.destroy(job.thread)
	job.thread = nil
	source_metadata_job = nil
	for &source in state.sources {
		if source.workflow != job.workflow ||
		   source.video_id != job.video_id ||
		   source.metadata_status != .Missing {
			continue
		}
		delete_source_context_metadata(&source.metadata)
		source.metadata = job.metadata
		source.metadata_status = job.metadata_loaded ? .Available : .Unavailable
		job.metadata = {}
		break
	}
	source_metadata_job_destroy(job)
	_ = save_library()
	source_details_metadata_changed()
	request_next_missing_source_metadata()
}

library_recovery_destroy :: proc() {
	if library_recovery == nil {return}
	for &entry in library_recovery.entries {delete(entry.video_id)}
	delete(library_recovery.entries)
	free(library_recovery)
	library_recovery = nil
}

library_recovery_finish :: proc() {
	if library_recovery == nil {return}
	recovered := library_recovery.recovered
	failed := library_recovery.failed
	cancelled := library_recovery.cancelled
	notification_id := library_recovery.notification_id
	library_recovery_destroy()
	if cancelled {
		_ = notification_finish(
			notification_id,
			.Interrupted,
			fmt.tprintf(
				"Library imported; recovery stopped after %d source(s), with %d failure(s)",
				recovered,
				failed,
			),
		)
		return
	}
	if failed > 0 {
		_ = notification_finish(
			notification_id,
			.Error,
			fmt.tprintf(
				"Library imported; recovered %d source(s), %d require manual refetch",
				recovered,
				failed,
			),
		)
	} else {
		_ = notification_finish(
			notification_id,
			.Success,
			fmt.tprintf("Library imported and recovered %d source(s)", recovered),
		)
	}
}

source_index_for_video_id :: proc(
	sources: []Source_Video,
	video_id: string,
	workflow := Workflow_Kind.Vocal,
) -> int {
	for source, index in sources {
		if source.workflow == workflow && source.video_id == video_id {
			return index
		}
	}
	return -1
}

library_recovery_start_next :: proc() {
	if library_recovery == nil {return}
	for library_recovery.next < len(library_recovery.entries) {
		entry_index := library_recovery.next
		entry := library_recovery.entries[entry_index]
		library_recovery.next += 1
		source_index := source_index_for_video_id(
			state.sources[:],
			entry.video_id,
			entry.workflow,
		)
		if source_index < 0 {
			library_recovery.failed += 1
			continue
		}
		source := &state.sources[source_index]
		reuse_existing := os.exists(source.media_path)
		if !reuse_existing && entry.height <= 0 {
			library_recovery.failed += 1
			continue
		}
		job := import_job_create(source.url, source.video_id, source.workflow)
		if job == nil {
			library_recovery.failed += 1
			continue
		}
		job.library_recovery_source = true
		job.notification_id = library_recovery.notification_id
		job.recovery_index = entry_index + 1
		job.recovery_total = len(library_recovery.entries)
		job.reuse_existing_media = reuse_existing
		allocator := mem_virtual.arena_allocator(job.arena)
		if entry.height > 0 {
			append(
				&job.qualities,
				Import_Quality{
					video_id = strings.clone(source.video_id, allocator),
					height = entry.height,
					exact = true,
				},
			)
		}
		if !media_queue_schedule_import(job, barrier = true) {
			import_job_destroy(job)
			library_recovery.failed += 1
			continue
		}
		os.make_directory(app_support_dir())
		_ = os.write_entire_file(job.log_path, nil)
		fields := [3]Notification_Field{
			{label="Operation", value="Library recovery"},
			{label="Source", value=fmt.tprintf("%d of %d", entry_index + 1, len(library_recovery.entries))},
			{label="Requested resolution", value=fmt.tprintf("%dp", entry.height)},
		}
		_ = notification_update(
			library_recovery.notification_id,
			fmt.tprintf(
				"Recovering source %d of %d at %dp...",
				entry_index + 1,
				len(library_recovery.entries),
				entry.height,
			),
			"The application reuses valid local media and downloads only sources that are missing or invalid.",
			fields[:],
			persist_now = true,
		)
		return
	}
	library_recovery_finish()
}

library_recovery_start :: proc() -> bool {
	if library_recovery != nil {return false}
	if len(state.sources) == 0 {
		set_success_status("Library imported")
		return true
	}
	recovery := new(Library_Recovery)
	recovery.notification_id = notification_begin(
		"Library imported; preparing source recovery",
		"The imported library records are installed. Media validation and clip recovery will now run sequentially.",
	)
	recovery.entries = make(
		[dynamic]Library_Recovery_Entry,
		0,
		len(state.sources),
	)
	for source in state.sources {
		if source.kind == .Local {continue}
		append(
			&recovery.entries,
			Library_Recovery_Entry {
				video_id = strings.clone(source.video_id),
				height = source.metadata.height,
				workflow = source.workflow,
			},
		)
	}
	if len(recovery.entries) > 0 &&
	   (!require_helper("yt-dlp") || !require_helper("ffmpeg")) {
		delete(recovery.entries)
		free(recovery)
		return false
	}
	library_recovery = recovery
	library_recovery_start_next()
	return true
}

major_change_backup_preflight :: proc(
	kind: Major_Change_Pending_Kind,
	source_index := -1,
	maximum_height := 0,
	auth_browser := Source_Auth_Browser.None,
) -> bool {
	if major_change_pending.allow_once {
		major_change_pending.allow_once = false
		major_change_backup_override = true
		return true
	}
	backup := library_backup_create(library_database)
	defer library_backup_result_destroy(&backup)
	if backup.status != .Failed {return true}
	delete(major_change_pending.detail)
	major_change_pending = {
		open = true,
		kind = kind,
		source_index = source_index,
		maximum_height = maximum_height,
		auth_browser = auth_browser,
		detail = strings.clone(backup.detail),
	}
	ui.needs_redraw = true
	return false
}

major_change_backup_cancel :: proc() {
	delete(major_change_pending.detail)
	delete(pending_local_relink_path)
	pending_local_relink_path = ""
	delete(pending_source_delete_id)
	pending_source_delete_id = ""
	major_change_pending = {}
	ui.needs_redraw = true
}

major_change_backup_continue :: proc() {
	kind := major_change_pending.kind
	source_index := major_change_pending.source_index
	maximum_height := major_change_pending.maximum_height
	auth_browser := major_change_pending.auth_browser
	delete(major_change_pending.detail)
	major_change_pending = {allow_once=true}
	switch kind {
	case .Source_Import:
		on_import(nil, nil, nil)
	case .Source_Refetch:
		refetch_source(source_index, maximum_height, auth_browser)
	case .Source_Delete:
		delete_source_by_id(pending_source_delete_id)
	case .Local_Source_Relink:
		relink_local_source_path(source_index, pending_local_relink_path)
	case .Library_Replacement:
		confirm_library_import()
	case .None:
		major_change_pending.allow_once = false
	}
	ui.needs_redraw = true
}

source_managed_files_remove :: proc(
	workflow: Workflow_Kind,
	video_id: string,
	media_path: string,
	clip_paths: []string,
) -> int {
	failed := 0
	if os.exists(media_path) && os.remove(media_path) != nil {failed += 1}
	directory := workflow_source_directory(workflow)
	handle, open_error := os.open(directory)
	if open_error == nil {
		entries, read_error := os.read_dir(handle, -1, context.temp_allocator)
		os.close(handle)
		if read_error == nil {
			prefix := fmt.tprintf("%s.", video_id)
			for entry in entries {
				if !strings.has_prefix(entry.name, prefix) {continue}
				path := fmt.tprintf("%s/%s", directory, entry.name)
				if os.remove(path) != nil && os.exists(path) {failed += 1}
			}
		}
	}
	for path in clip_paths {
		if os.exists(path) && os.remove(path) != nil {failed += 1}
	}
	return failed
}

delete_source_by_id :: proc(source_id: string) -> bool {
	if len(source_id) == 0 || library_transfer_busy() ||
	   len(import_jobs) > 0 || len(export_jobs) > 0 {return false}
	index := source_index_for_id(state.sources[:], source_id)
	if index < 0 {return false}
	if !major_change_backup_preflight(.Source_Delete, source_index=index) {return false}
	allow_without_backup := major_change_backup_override
	major_change_backup_override = false
	source := &state.sources[index]
	workflow := source.workflow
	video_id := strings.clone(source.video_id, context.temp_allocator)
	media_path := strings.clone(source.media_path, context.temp_allocator)
	clip_paths := make([dynamic]string, context.temp_allocator)
	for clip in state.clips {
		if clip.source_id == source_id {append(&clip_paths, strings.clone(clip.clip_path, context.temp_allocator))}
	}
	active_source_id := ""
	if state.active_source >= 0 && state.active_source < len(state.sources) {
		active_source_id = strings.clone(state.sources[state.active_source].id, context.temp_allocator)
	}
	active_clip_id := ""
	if ui.active_clip >= 0 && ui.active_clip < len(state.clips) {
		active_clip_id = strings.clone(state.clips[ui.active_clip].id, context.temp_allocator)
	}
	active_source_deleted := state.active_source >= 0 &&
		state.active_source < len(state.sources) &&
		state.sources[state.active_source].id == source_id
	active_clip_deleted := ui.active_clip >= 0 && ui.active_clip < len(state.clips) &&
		state.clips[ui.active_clip].source_id == source_id

	candidate, copied := app_state_collections_clone(&state)
	if !copied {return false}
	defer app_state_collections_destroy(&candidate)
	delete_source_video(&candidate.sources[index])
	ordered_remove(&candidate.sources, index)
	for hint_index := len(candidate.hints)-1; hint_index >= 0; hint_index -= 1 {
		if candidate.hints[hint_index].source_id != source_id {continue}
		delete_import_hint(&candidate.hints[hint_index])
		ordered_remove(&candidate.hints, hint_index)
	}
	for clip_index := len(candidate.clips)-1; clip_index >= 0; clip_index -= 1 {
		if candidate.clips[clip_index].source_id != source_id {continue}
		delete_clip(&candidate.clips[clip_index])
		ordered_remove(&candidate.clips, clip_index)
	}
	remaining_segments := make([dynamic]Transcript_Segment, context.temp_allocator)
	for segment in candidate.transcripts.segments {
		if segment.source_id != source_id {append(&remaining_segments, segment)}
	}
	replacement, replacement_ok := transcript_generation_copy(remaining_segments[:])
	if !replacement_ok {return false}
	transcript_generation_destroy(&candidate.transcripts)
	candidate.transcripts = replacement
	if !commit_library_state(&candidate, allow_without_backup=allow_without_backup) {
		set_error_status("Unable to delete the source from the library")
		return false
	}
	_ = database_clip_drafts_prune(library_database)
	state.active_source = source_index_for_id(state.sources[:], active_source_id)
	ui.active_clip = clip_index_for_id(state.clips[:], active_clip_id)
	if active_source_deleted || active_clip_deleted {
		metal_player_clear()
		state.active_source = -1
		ui.active_clip = -1
		ui.source_playback_active = false
		reset_clip_output()
	}
	close_source_details()
	ui.source_delete_confirm_open = false
	failed_files := source_managed_files_remove(workflow, video_id, media_path, clip_paths[:])
	delete(pending_source_delete_id)
	pending_source_delete_id = ""
	refresh_sources()
	refresh_transcript()
	refresh_clips()
	if failed_files > 0 {
		set_error_status(fmt.tprintf("Source deleted; %d managed file(s) could not be removed", failed_files))
	} else {
		set_success_status("Source and managed media deleted")
	}
	return true
}

delete_clip_by_id :: proc(clip_id: string) -> bool {
	if len(clip_id) == 0 || library_transfer_busy() ||
	   len(import_jobs) > 0 || len(export_jobs) > 0 {return false}
	index := clip_index_for_id(state.clips[:], clip_id)
	if index < 0 {return false}
	clip_path := strings.clone(state.clips[index].clip_path, context.temp_allocator)
	active_clip_deleted := ui.active_clip == index
	candidate, copied := app_state_collections_clone(&state)
	if !copied {return false}
	defer app_state_collections_destroy(&candidate)
	delete_clip(&candidate.clips[index])
	ordered_remove(&candidate.clips, index)
	if !commit_library_state(&candidate) {
		set_error_status("Unable to delete the clip from the library")
		return false
	}
	if active_clip_deleted {
		metal_player_clear()
		ui.active_clip = -1
		ui.source_playback_active = false
	} else if ui.active_clip > index {
		ui.active_clip -= 1
	}
	close_clip_metadata()
	ui.clip_delete_confirm_open = false
	delete(pending_clip_delete_id)
	pending_clip_delete_id = ""
	refresh_clips()
	if os.exists(clip_path) && os.remove(clip_path) != nil {
		set_error_status("Clip deleted; its managed file could not be removed")
	} else {
		set_success_status("Clip and managed media deleted")
	}
	return true
}

refetch_source :: proc(
	source_index: int,
	maximum_height := 0,
	auth_browser := Source_Auth_Browser.None,
) {
	if library_replacement_job != nil {
		set_text(state.status, "Wait for the queued library replacement")
		return
	}
	if source_index < 0 || source_index >= len(state.sources) { set_text(state.status, "Select a source to refetch"); return }
	if !require_helper("yt-dlp") || !require_helper("ffmpeg") { return }
	if !major_change_backup_preflight(
		.Source_Refetch,
		source_index,
		maximum_height,
		auth_browser,
	) {
		return
	}
	source := &state.sources[source_index]
	allow_without_backup := major_change_backup_override
	major_change_backup_override = false
	job := import_job_create(source.url, source.video_id, source.workflow)
	if job == nil { set_text(state.status, "Unable to allocate import job"); return }
	job.allow_without_backup = allow_without_backup
	job.applied_source_index = source_index
	if maximum_height > 0 {
		allocator := mem_virtual.arena_allocator(job.arena)
		append(
			&job.qualities,
			Import_Quality {
				video_id = strings.clone(source.video_id, allocator),
				height = maximum_height,
				auth_browser = auth_browser,
			},
		)
	}
	fields := [2]Notification_Field{
		{label="Operation", value="Source refetch"},
		{label="Source", value=source.title},
	}
	summary := "Refetching source at the best available quality..."
	if maximum_height > 0 {
		summary = fmt.tprintf(
			"Refetching source at up to %dp...",
			maximum_height,
		)
	}
	if auth_browser != .None {
		browser_name := source_auth_browser_name(auth_browser)
		summary = fmt.tprintf(
			"Refetching source with %s session...",
			browser_name,
		)
	}
	detail := "The source will be downloaded into staging files, validated, and then committed."
	if auth_browser != .None {
		detail = fmt.tprintf(
			"You selected %s. yt-dlp reads its YouTube session for this download. The application does not store or export browser cookies.",
			source_auth_browser_name(auth_browser),
		)
	}
	job.notification_id = notification_begin(
		summary,
		detail,
		fields[:],
	)
	os.make_directory(app_support_dir())
	os.write_entire_file(job.log_path, nil)
	if !media_queue_schedule_import(job, barrier = true) {
		import_job_destroy(job)
		set_text(state.status, "Unable to queue the source refetch")
		return
	}
	set_text(state.status, "Source refetch queued")
}

on_refetch_source :: proc "c" (self: Id, command: Sel, sender: Id) {
	context = runtime.default_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	refetch_source(state.active_source)
}

on_import :: proc "c" (self: Id, command: Sel, sender: Id) {
	context = runtime.default_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	if library_replacement_job != nil {
		set_text(state.status, "Wait for the queued library replacement")
		return
	}
	local_mode := ui.source_modal_refetch_index < 0 && ui.source_add_mode == .Local_Files
	has_local := local_mode && len(source_local_paths) > 0
	if !require_helper("ffmpeg") {return}
	if has_local && !require_helper("ffprobe") {return}
	input := ""
	if !local_mode {input = strings.trim_space(field_text(state.url_input))}
	if local_mode && !has_local {set_text(state.status, "Choose or drop at least one local video file"); return}
	if !local_mode && len(input) == 0 {set_text(state.status, "Paste at least one YouTube URL"); return}
	if len(input) > 0 && !require_helper("yt-dlp") {return}
	if len(input) > 0 && source_probe_job != nil {set_text(state.status, "Wait for the metadata check to finish"); return}
	if len(input) > 0 && !source_probe_ready(input) {
		set_text(state.status, "Check the URL metadata and select an available quality first")
		source_probe_request()
		return
	}
	if ui.source_modal_refetch_index >= 0 {
		source_index := ui.source_modal_refetch_index
		if source_index >= 0 && source_index < len(state.sources) {
			height := source_probe_selected_height(state.sources[source_index].video_id)
			auth_browser := source_probe_selected_browser(
				state.sources[source_index].video_id,
			)
			close_source_modal()
			refetch_source(source_index, height, auth_browser)
		}
		return
	}
	if !major_change_backup_preflight(.Source_Import) {return}
	allow_without_backup := major_change_backup_override
	major_change_backup_override = false
	os.make_directory(app_support_dir())
	queued := 0
	for raw in strings.split_lines(input) {
		url := strings.trim_space(raw)
		if len(url) == 0 {
			continue
		}
		job := import_job_create(url)
		if job == nil {
			continue
		}
		job.allow_without_backup = allow_without_backup
		summary := "Source download queued"
		detail := "The queue runs up to two source downloads and validates each result before updating the library."
		if auth_browser := import_job_auth_browser(job);
		   auth_browser != .None {
			browser_name := source_auth_browser_name(auth_browser)
			summary = fmt.tprintf(
				"Source download queued with %s session",
				browser_name,
			)
			detail = fmt.tprintf(
				"You selected %s. yt-dlp reads its YouTube session for this download. The application does not store or export browser cookies.",
				browser_name,
			)
		}
		fields := [1]Notification_Field{
			{label = "URL", value = url},
		}
		job.notification_id = notification_begin(
			summary,
			detail,
			fields[:],
		)
		os.write_entire_file(job.log_path, nil)
		if !media_queue_schedule_import(job) {
			_ = notification_finish(
				job.notification_id,
				.Error,
				"Unable to queue source download",
			)
			import_job_destroy(job)
			continue
		}
		queued += 1
	}
	if local_mode {
	for path, index in source_local_paths {
		title := index < len(source_local_titles) ? source_local_titles[index] : ""
		job := import_job_create_local(path, title)
		if job == nil {continue}
		job.allow_without_backup = allow_without_backup
		fields := [1]Notification_Field{{label="File", value=path}}
		job.notification_id = notification_begin(
			"Local source import queued",
			"The file will be hashed, inspected, normalized when necessary, validated, and copied into the managed library.",
			fields[:],
		)
		os.write_entire_file(job.log_path, nil)
		if !media_queue_schedule_import(job, barrier=true) {
			_ = notification_finish(job.notification_id, .Error, "Unable to queue local source import")
			import_job_destroy(job)
			continue
		}
		queued += 1
	}
	}
	if queued == 0 {
		set_text(state.status, "Unable to queue the source download")
		return
	}
	close_source_modal()
	status := "Queued 1 source operation"
	if queued > 1 {
		status = fmt.tprintf("Queued %d source operations", queued)
	}
	set_text(state.status, status)
}

on_set_start :: proc "c" (self: Id, command: Sel, sender: Id) {
	context = runtime.default_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	if seconds, ok := current_seconds(); ok {
		state.range_start, state.has_start = seconds, true
		if persist_active_clip_draft() {
			set_text(
				state.status,
				fmt.tprintf("Start: %s", format_timestamp(seconds)),
			)
		}
	} else { set_text(state.status, "No active source player") }
}

on_set_end :: proc "c" (self: Id, command: Sel, sender: Id) {
	context = runtime.default_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	if seconds, ok := current_seconds(); ok {
		state.range_end, state.has_end = seconds, true
		if persist_active_clip_draft() {
			set_text(
				state.status,
				fmt.tprintf(
					"Range: %s - %s",
					format_timestamp(state.range_start),
					format_timestamp(seconds),
				),
			)
		}
	} else { set_text(state.status, "No active source player") }
}

reset_clip_output :: proc() {
	state.range_start = 0
	state.range_end = 0
	state.has_start = false
	state.has_end = false
	ui_set_string(&ui.clip_name, "")
	if ui.focus == .Clip_Name {
		clear_marked_text()
		collapse_text_selection(0)
		ui.scroll_x = 0
	}
	ui.needs_redraw = true
}

export_jobs_any :: proc() -> bool {
	return len(export_jobs) > 0
}

export_jobs_have_exclusive_operation :: proc() -> bool {
	for job in export_jobs {
		if job != nil && job.operation != .Save {return true}
	}
	return false
}

source_import_media_job_blocks :: proc() -> bool {
	return library_replacement_job != nil
}

import_job_has_exclusive_operation :: proc() -> bool {
	for job in import_jobs {
		if job.library_recovery_source ||
		   len(job.replace_video_id) > 0 {
			return true
		}
	}
	return false
}

clip_save_media_job_blocks :: proc() -> bool {
	return library_replacement_job != nil
}

export_jobs_add :: proc(job: ^Export_Job) {
	if job == nil {return}
	append(&export_jobs, job)
}

export_jobs_remove :: proc(job: ^Export_Job) -> bool {
	for candidate, index in export_jobs {
		if candidate != job {continue}
		last := pop(&export_jobs)
		if index < len(export_jobs) {export_jobs[index] = last}
		return true
	}
	return false
}

clip_id_reserved :: proc(id: string) -> bool {
	for clip in state.clips {
		if clip.id == id {return true}
	}
	for job in export_jobs {
		if job != nil && job.operation == .Save && job.clip.id == id {
			return true
		}
	}
	return false
}

next_clip_number_for_export :: proc(source: ^Source_Video) -> int {
	if source == nil {return 0}
	for number := 1; ; number += 1 {
		id := fmt.tprintf("%s-%d", source.id, number)
		if !clip_id_reserved(id) {return number}
	}
	return 0
}

on_save :: proc "c" (self: Id, command: Sel, sender: Id) {
	context = runtime.default_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	if library_replacement_job != nil {
		set_text(state.status, "Wait for the queued library replacement")
		return
	}
	if !flush_active_clip_draft() {return}
	if !require_helper("ffmpeg") { return }
	if state.active_source < 0 || !state.has_start || !state.has_end || !valid_clip_range(state.range_start, state.range_end, state.sources[state.active_source].duration) {
		set_text(state.status, "Select a source and mark a valid start/end range")
		return
	}
	source := &state.sources[state.active_source]
	number := next_clip_number_for_export(source)
	if number <= 0 {
		set_text(state.status, "Unable to reserve a clip identifier")
		return
	}
	id := fmt.tprintf("%s-%d", source.id, number)
	name := fmt.tprintf("%s Clip %d", source.title, number)
	entered := strings.trim_space(field_text(state.clip_name_input))
	if len(entered) > 0 { name = entered }
	job := export_job_create(
		Clip{
			id=id,
			source_id=source.id,
			workflow=source.workflow,
			name=name,
			start_seconds=state.range_start,
			end_seconds=state.range_end,
			dance_count_in_bpm=120,
			dance_playback_rate=1,
		},
		source.media_path,
		.Save,
		ui.clip_draft_revision,
	)
	if job == nil { set_text(state.status, "Unable to allocate export job"); return }
	fields := [3]Notification_Field{
		{label="Operation", value="Save clip"},
		{label="Source", value=source.title},
		{label="Range", value=fmt.tprintf("%s – %s", format_timestamp(state.range_start), format_timestamp(state.range_end))},
	}
	job.notification_id = notification_begin(
		"Exporting clip...",
		"FFmpeg is encoding the selected source range as a standalone clip.",
		fields[:],
	)
	os.write_entire_file(job.log_path, nil)
	if !media_queue_schedule_export(job) {
		export_job_destroy(job)
		set_text(state.status, "Unable to queue the clip export")
		return
	}
}

on_play :: proc "c" (self: Id, command: Sel, sender: Id) {
	context = runtime.default_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	if state.player != nil {
		request_transcript_follow()
		if !resume_player_playback() {
			set_error_status("Unable to start audio playback")
		}
	}
}

on_pause :: proc "c" (self: Id, command: Sel, sender: Id) {
	context = runtime.default_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	pause_player_playback()
}

on_toggle_playback :: proc "c" (self: Id, command: Sel, event: Id) {
	context = runtime.default_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	if state.player == nil { return }
	if playback_actively_playing() {
		pause_player_playback()
	} else {
		request_transcript_follow()
		if !resume_player_playback() {
			set_error_status("Unable to start audio playback")
		}
	}
}

on_preview :: proc "c" (self: Id, command: Sel, sender: Id) {
	context = runtime.default_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	if library_replacement_job != nil {
		set_text(state.status, "Wait for the queued library replacement")
		return
	}
	if !require_helper("ffmpeg") { return }
	if state.active_source < 0 || !state.has_start || !state.has_end || !valid_clip_range(state.range_start, state.range_end, state.sources[state.active_source].duration) {
		set_text(state.status, "Mark a valid start and end before previewing")
		return
	}
	source := &state.sources[state.active_source]
	job := export_job_create(
		Clip{
			id="preview",
			source_id=source.id,
			workflow=source.workflow,
			name="Range Preview",
			start_seconds=state.range_start,
			end_seconds=state.range_end,
			dance_count_in_bpm=120,
			dance_playback_rate=1,
		},
		source.media_path,
		.Preview,
	)
	if job == nil { set_text(state.status, "Unable to allocate preview job"); return }
	fields := [3]Notification_Field{
		{label="Operation", value="Preview range"},
		{label="Source", value=source.title},
		{label="Duration", value=format_timestamp(state.range_end - state.range_start)},
	}
	job.notification_id = notification_begin(
		"Preparing range preview...",
		"FFmpeg is encoding a temporary preview for the selected range.",
		fields[:],
	)
	os.write_entire_file(job.log_path, nil)
	if !media_queue_schedule_export(job, barrier = true) {
		export_job_destroy(job)
		set_text(state.status, "Unable to queue the range preview")
		return
	}
}

export_job_destroy :: proc(job: ^Export_Job) {
	if job == nil { return }
	growing_arena_destroy(job.arena)
	free(job)
}

export_job_create :: proc(
	clip: Clip,
	source_path: string,
	operation: Export_Operation,
	draft_revision: i64 = 0,
) -> ^Export_Job {
	arena, ok := growing_arena_create()
	if !ok { return nil }
	job := new(Export_Job)
	job.arena = arena
	job.completion_target = state.delegate_target
	allocator := mem_virtual.arena_allocator(arena)
	job.operation_id = next_media_operation_id()
	copy, copied := clone_clip(clip, allocator)
	if !copied { export_job_destroy(job); return nil }
	job.clip = copy
	job.source_path = strings.clone(source_path, allocator)
	if source_index := source_index_for_id(state.sources[:], clip.source_id);
	   source_index >= 0 {
		job.has_audio = state.sources[source_index].has_audio
	} else {
		job.has_audio = true
	}
	job.log_path = strings.clone(
		clip_export_log_path(job.clip.id, job.operation_id),
		allocator,
	)
	job.operation = operation
	job.draft_revision = draft_revision
	return job
}

repair_clip_apply :: proc(value: Clip) -> (int, bool) {
	index := clip_index_for_id(state.clips[:], value.id)
	if index < 0 {return -1, false}
	candidate, candidate_copied := app_state_collections_clone(&state)
	if !candidate_copied {return -1, false}
	defer app_state_collections_destroy(&candidate)
	repaired, repaired_copied := clone_clip(value)
	if !repaired_copied {return -1, false}
	delete_clip(&candidate.clips[index])
	candidate.clips[index] = repaired
	if !commit_library_state(&candidate) {return -1, false}
	return index, true
}

save_export_apply :: proc(job: ^Export_Job) -> bool {
	if job == nil || job.operation != .Save || !job.success {return false}
	clip, copied := clone_clip(job.clip)
	if !copied {return false}
	append(&state.clips, clip)
	draft_clear: Clip_Draft_Clear_Request
	draft_clear_pointer: ^Clip_Draft_Clear_Request
	if job.draft_revision > 0 {
		draft_clear = {
			source_id = job.clip.source_id,
			revision = job.draft_revision,
		}
		draft_clear_pointer = &draft_clear
	}
	if !save_library(draft_clear_pointer) {
		stored := pop(&state.clips)
		delete_clip(&stored)
		_ = os.remove(job.clip.clip_path)
		return false
	}
	if draft_clear_pointer != nil && draft_clear.cleared {
		apply_cleared_clip_draft(
			draft_clear.source_id,
			draft_clear.revision,
		)
	}
	refresh_clips()
	return true
}

finish_export_job :: proc(job: ^Export_Job) {
	if job == nil {return}
	if job.cli_work != nil {
		cli_clip_create_finish(job)
		return
	}
	if job.cancelled {
		_ = notification_finish(
			job.notification_id,
			.Interrupted,
			"Media export stopped",
			"The user stopped the queued media operation.",
		)
		return
	}
	if !job.success {
		_ = notification_finish(
			job.notification_id,
			.Error,
			"FFmpeg failed",
			fmt.tprintf("Inspect the diagnostic log at %s", job.log_path),
		)
		return
	}
	if job.operation == .Preview {
		if !metal_player_load(job.clip.clip_path, job.has_audio) {
			_ = notification_finish(
				job.notification_id,
				.Error,
				"Unable to load the exported preview",
			)
			return
		}
		ui.player_duration = job.clip.end_seconds - job.clip.start_seconds
		set_source_playback_active(false)
		start_loaded_playback_at(0)
		_ = notification_finish(
			job.notification_id,
			.Success,
			fmt.tprintf(
				"Previewing %s",
				format_timestamp(job.clip.end_seconds-job.clip.start_seconds),
			),
		)
		return
	}
	if job.operation == .Repair {
		if clip_index_for_id(state.clips[:], job.clip.id) < 0 {
			_ = notification_finish(
				job.notification_id,
				.Error,
				"The rebuilt clip is no longer in the library",
			)
			return
		}
		index, repaired := repair_clip_apply(job.clip)
		if !repaired {
			_ = notification_finish(
				job.notification_id,
				.Error,
				"The clip was rebuilt, but the library update failed",
			)
			return
		}
		clip := &state.clips[index]
		refresh_clips()
		if !metal_player_load(clip.clip_path, job.has_audio) {
			_ = notification_finish(
				job.notification_id,
				.Error,
				"The clip was rebuilt, but it could not be loaded",
			)
			return
		}
		ui.player_duration = clip.end_seconds - clip.start_seconds
		set_source_playback_active(false)
		ui.active_clip = index
		remember_list_selection(.Play, clip.id)
		start_active_clip_from_beginning(false)
		_ = notification_finish(
			job.notification_id,
			.Success,
			fmt.tprintf("Rebuilt and playing %s", clip.name),
		)
		return
	}
	if !save_export_apply(job) {
		_ = notification_finish(
			job.notification_id,
			.Error,
			"The clip was created, but the library update failed",
		)
		return
	}
	_ = notification_finish(
		job.notification_id,
		.Success,
		fmt.tprintf(
			"Saved %s (%s)",
			job.clip.name,
			format_timestamp(job.clip.end_seconds-job.clip.start_seconds),
		),
	)
}

on_export_finished :: proc "c" (self: Id, command: Sel, sender: Id) {
	context = runtime.default_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	for {
		sync.mutex_lock(&export_completion_mutex)
		if len(export_completed_jobs) == 0 {
			sync.mutex_unlock(&export_completion_mutex)
			break
		}
		job := pop(&export_completed_jobs)
		sync.mutex_unlock(&export_completion_mutex)
		if !export_jobs_remove(job) {continue}
		finish_export_job(job)
		media_task_completion_finish(&job.completion)
	}
}

on_select_source :: proc "c" (self: Id, command: Sel, sender: Id) {
	context = runtime.default_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	index := ui_event_tag
	if sender != nil { index = int(msg_uint(sender, sel_registerName("tag"))) }
	if index < 0 || index >= len(state.sources) { return }
	if state.sources[index].workflow != ui.workflow {return}
	if !flush_active_clip_draft() {return}
	if load_source_player(index) {
		ui.active_clip = -1
		set_text(state.status, fmt.tprintf("Loaded %s", state.sources[index].title))
	} else {
		source := &state.sources[index]
		if !source.media_available {
			if source.kind == .Local {
				set_text(state.status, "MEDIA MISSING / Open Source Details and locate the original local video.")
			} else {
				set_text(state.status, "MEDIA MISSING / The merged MP4 was not created. Right-click this source and refetch it.")
			}
		} else {
			set_text(state.status, "VIDEO INVALID / The managed MP4 does not contain decodable H.264 or HEVC video with its expected audio state.")
		}
	}
}

play_clip :: proc(index: int) -> bool {
	if index < 0 || index >= len(state.clips) {return false}
	clip := &state.clips[index]
	if clip.workflow != ui.workflow {return false}
	if clip.workflow == .Vocal {
		ui.playback_rate = ui.vocal_playback_rate
	} else {
		ui.playback_rate = clamp_playback_rate(clip.dance_playback_rate)
	}
	if !os.exists(clip.clip_path) {
		if library_replacement_job != nil {
			set_text(state.status, "Wait for the queued library replacement")
			return false
		}
		source_index := source_index_for_id(state.sources[:], clip.source_id)
		if source_index < 0 {
			set_text(state.status, "The original source is no longer in the library")
			return false
		}
		source := &state.sources[source_index]
		if !source.media_available || !os.exists(source.media_path) {
			set_text(state.status, source.kind == .Local ? "The managed source is missing. Locate the original local video before rebuilding this clip." : "The original source file is missing. Refetch the source before rebuilding this clip.")
			return false
		}
		if !valid_clip_range(clip.start_seconds, clip.end_seconds, source.duration) {
			set_text(state.status, "The saved clip range is not valid for its source")
			return false
		}
		if !require_helper("ffmpeg") {return false}
		job := export_job_create(clip^, source.media_path, .Repair)
		if job == nil {
			set_text(state.status, "Unable to allocate the clip rebuild job")
			return false
		}
		fields := [2]Notification_Field{
			{label="Operation", value="Rebuild clip"},
			{label="Clip", value=clip.name},
		}
		job.notification_id = notification_begin(
			fmt.tprintf("Rebuilding missing clip for %s...", clip.name),
			"FFmpeg is recreating the saved clip from its original source range.",
			fields[:],
		)
		os.write_entire_file(job.log_path, nil)
		if !media_queue_schedule_export(job, barrier = true) {
			export_job_destroy(job)
			set_text(state.status, "Unable to queue the clip rebuild")
			return false
		}
		return true
	}
	source_index := source_index_for_id(state.sources[:], clip.source_id)
	has_audio := source_index < 0 || state.sources[source_index].has_audio
	if !metal_player_load(clip.clip_path, has_audio) {
		set_text(state.status, "Unable to load the selected clip")
		return false
	}
	ui.player_duration = clip.end_seconds - clip.start_seconds
	set_source_playback_active(false)
	ui.active_clip = index
	remember_list_selection(.Play, clip.id)
	start_active_clip_from_beginning(false)
	set_text(state.status, fmt.tprintf("Playing %s", clip.name))
	return true
}

on_play_clip :: proc "c" (self: Id, command: Sel, sender: Id) {
	context = runtime.default_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	index := ui_event_tag
	if sender != nil {index = int(msg_uint(sender, sel_registerName("tag")))}
	_ = play_clip(index)
}

RANDOM_CLIP_BASE_WEIGHT :: 2
RANDOM_CLIP_SKIPPED_CAP :: i64(4)
RANDOM_CLIP_HELP_LIMIT  :: 10

Random_Clip_Candidate :: struct {
	clip_index: int,
	weight:         int,
}

random_clip_latest_sequence :: proc(clips: []Clip) -> i64 {
	latest: i64
	for clip in clips {
		if clip.workflow != ui.workflow {continue}
		latest = max(latest, clip.last_randomized_sequence)
	}
	return latest
}

random_clip_weight :: proc(last_sequence, latest_sequence: i64) -> int {
	if last_sequence <= 0 {return 6}
	skipped := min(
		max(i64(0), latest_sequence - last_sequence),
		RANDOM_CLIP_SKIPPED_CAP,
	)
	return RANDOM_CLIP_BASE_WEIGHT + int(skipped)
}

random_clip_total_weight :: proc(
	clips: []Clip,
	active_clip: int,
) -> int {
	latest := random_clip_latest_sequence(clips)
	exclude_active :=
		filtered_clip_count_for(clips, "") > 1 &&
		active_clip >= 0 &&
		active_clip < len(clips) &&
		clips[active_clip].workflow == ui.workflow
	total := 0
	for clip, index in clips {
		if clip.workflow != ui.workflow {continue}
		if exclude_active && index == active_clip {continue}
		total += random_clip_weight(
			clip.last_randomized_sequence,
			latest,
		)
	}
	return total
}

random_clip_ranked_candidates :: proc(
	clips: []Clip,
	active_clip: int,
	output: []Random_Clip_Candidate,
) -> (count, total_weight: int) {
	total_weight = random_clip_total_weight(clips, active_clip)
	if len(output) == 0 || total_weight <= 0 {return}
	latest := random_clip_latest_sequence(clips)
	exclude_active :=
		filtered_clip_count_for(clips, "") > 1 &&
		active_clip >= 0 &&
		active_clip < len(clips) &&
		clips[active_clip].workflow == ui.workflow
	for clip, clip_index in clips {
		if clip.workflow != ui.workflow {continue}
		if exclude_active && clip_index == active_clip {continue}
		candidate := Random_Clip_Candidate{
			clip_index = clip_index,
			weight = random_clip_weight(
				clip.last_randomized_sequence,
				latest,
			),
		}
		insert_at := count
		for ranked, ranked_index in output[:count] {
			if candidate.weight > ranked.weight {
				insert_at = ranked_index
				break
			}
		}
		if insert_at >= len(output) {continue}
		move_end := min(count, len(output) - 1)
		for destination := move_end; destination > insert_at; destination -= 1 {
			output[destination] = output[destination - 1]
		}
		output[insert_at] = candidate
		count = min(count + 1, len(output))
	}
	return
}

random_clip_index_for_weighted_roll :: proc(
	clips: []Clip,
	active_clip, roll: int,
) -> int {
	total := random_clip_total_weight(clips, active_clip)
	if total <= 0 {return -1}
	remaining := roll % total
	latest := random_clip_latest_sequence(clips)
	exclude_active :=
		filtered_clip_count_for(clips, "") > 1 &&
		active_clip >= 0 &&
		active_clip < len(clips) &&
		clips[active_clip].workflow == ui.workflow
	for clip, index in clips {
		if clip.workflow != ui.workflow {continue}
		if exclude_active && index == active_clip {continue}
		weight := random_clip_weight(
			clip.last_randomized_sequence,
			latest,
		)
		if remaining < weight {return index}
		remaining -= weight
	}
	return -1
}

record_randomized_clip :: proc(index: int) -> bool {
	if index < 0 || index >= len(state.clips) {return false}
	next_sequence := random_clip_latest_sequence(state.clips[:]) + 1
	if library_legacy_fallback {
		state.clips[index].last_randomized_sequence = next_sequence
		return true
	}
	if !database_clip_randomization_save(
		library_database,
		state.clips[index].id,
		next_sequence,
	) {
		return false
	}
	state.clips[index].last_randomized_sequence = next_sequence
	return true
}

randomize_clip :: proc() -> bool {
	total_weight := random_clip_total_weight(
		state.clips[:],
		ui.active_clip,
	)
	if total_weight <= 0 {
		set_text(state.status, "No clips are available")
		return false
	}
	index := random_clip_index_for_weighted_roll(
		state.clips[:],
		ui.active_clip,
		rand.int_max(total_weight),
	)
	if !play_clip(index) {return false}
	if !record_randomized_clip(index) {
		set_error_status(
			"Clip playback started, but Randomize history could not be saved",
		)
	}
	return true
}

clip_matches_filter :: proc(clip: Clip, filter: string) -> bool {
	return clip.workflow == ui.workflow &&
	       (len(filter) == 0 || strings.contains(clip.name, filter))
}

filtered_clip_count_for :: proc(
	clips: []Clip,
	filter: string,
) -> int {
	count := 0
	for clip in clips {
		if clip_matches_filter(clip, filter) {count += 1}
	}
	return count
}

next_filtered_clip_index :: proc(
	clips: []Clip,
	active_clip: int,
	filter: string,
) -> int {
	if len(clips) == 0 {return -1}
	start := -1
	if active_clip >= 0 &&
	   active_clip < len(clips) &&
	   clip_matches_filter(clips[active_clip], filter) {
		start = active_clip
	}
	for offset in 1 ..= len(clips) {
		index := (start + offset) % len(clips)
		if clip_matches_filter(clips[index], filter) {
			return index
		}
	}
	return -1
}

filtered_random_clip_total_weight :: proc(
	clips: []Clip,
	active_clip: int,
	filter: string,
) -> int {
	eligible_count := filtered_clip_count_for(clips, filter)
	if eligible_count == 0 {return 0}
	latest := random_clip_latest_sequence(clips)
	exclude_active :=
		eligible_count > 1 &&
		active_clip >= 0 &&
		active_clip < len(clips) &&
		clip_matches_filter(clips[active_clip], filter)
	total := 0
	for clip, index in clips {
		if !clip_matches_filter(clip, filter) {continue}
		if exclude_active && index == active_clip {continue}
		total += random_clip_weight(
			clip.last_randomized_sequence,
			latest,
		)
	}
	return total
}

filtered_random_clip_index_for_weighted_roll :: proc(
	clips: []Clip,
	active_clip: int,
	filter: string,
	roll: int,
) -> int {
	total := filtered_random_clip_total_weight(
		clips,
		active_clip,
		filter,
	)
	if total <= 0 {return -1}
	remaining := roll % total
	latest := random_clip_latest_sequence(clips)
	eligible_count := filtered_clip_count_for(clips, filter)
	exclude_active :=
		eligible_count > 1 &&
		active_clip >= 0 &&
		active_clip < len(clips) &&
		clip_matches_filter(clips[active_clip], filter)
	for clip, index in clips {
		if !clip_matches_filter(clip, filter) {continue}
		if exclude_active && index == active_clip {continue}
		weight := random_clip_weight(
			clip.last_randomized_sequence,
			latest,
		)
		if remaining < weight {return index}
		remaining -= weight
	}
	return -1
}

play_next_clip :: proc() -> bool {
	index := -1
	if ui.clip_shuffle {
		total_weight := filtered_random_clip_total_weight(
			state.clips[:],
			ui.active_clip,
			ui.clip_search,
		)
		if total_weight > 0 {
			index = filtered_random_clip_index_for_weighted_roll(
				state.clips[:],
				ui.active_clip,
				ui.clip_search,
				rand.int_max(total_weight),
			)
		}
	} else {
		index = next_filtered_clip_index(
			state.clips[:],
			ui.active_clip,
			ui.clip_search,
		)
	}
	if index < 0 {
		set_text(state.status, "No clips match the current filter")
		return false
	}
	if !play_clip(index) {return false}
	if ui.clip_shuffle && !record_randomized_clip(index) {
		set_error_status(
			"Clip playback started, but Shuffle history could not be saved",
		)
	}
	return true
}

on_filter_lists :: proc "c" (self: Id, command: Sel, sender: Id) {
	context = runtime.default_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	refresh_sources()
	refresh_clips()
}

should_terminate_after_window_close :: proc "c" (self: Id, command: Sel, sender: Id) -> bool {
	return true
}

on_open_data_folder :: proc "c" (self: Id, command: Sel, sender: Id) {
	context = runtime.default_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	os.make_directory(app_support_dir())
	url := msg_id_id(objc_getClass("NSURL"), sel_registerName("fileURLWithPath:"), nsstring(app_support_dir()))
	workspace := msg_id(objc_getClass("NSWorkspace"), sel_registerName("sharedWorkspace"))
	msg_void_id(workspace, sel_registerName("openURL:"), url)
}

library_transfer_busy :: proc() -> bool {
	return library_replacement_job != nil
}

library_panel_path :: proc(
	save: bool,
	scope := Portable_Library_Scope.All,
) -> (string, bool) {
	panel_class := save ? objc_getClass("NSSavePanel") : objc_getClass("NSOpenPanel")
	panel_selector := save ? sel_registerName("savePanel") : sel_registerName("openPanel")
	panel := msg_id(panel_class, panel_selector)
	if panel == nil {return "", false}
	extensions := msg_id_id(
		objc_getClass("NSArray"),
		sel_registerName("arrayWithObject:"),
		nsstring("json"),
	)
	msg_void_id(panel, sel_registerName("setAllowedFileTypes:"), extensions)
	msg_void_bool(panel, sel_registerName("setCanCreateDirectories:"), true)
	if save {
		name := "hw_videoClips Library.hwvideoclips.json"
		if scope == .Vocal {
			name = "hw_videoClips Vocal Library.hwvideoclips.json"
		} else if scope == .Dancing {
			name = "hw_videoClips Dancing Library.hwvideoclips.json"
		}
		msg_void_id(
			panel,
			sel_registerName("setNameFieldStringValue:"),
			nsstring(name),
		)
	} else {
		msg_void_bool(panel, sel_registerName("setCanChooseFiles:"), true)
		msg_void_bool(panel, sel_registerName("setCanChooseDirectories:"), false)
		msg_void_bool(panel, sel_registerName("setAllowsMultipleSelection:"), false)
	}
	if msg_i64(panel, sel_registerName("runModal")) != 1 {return "", false}
	url := msg_id(panel, sel_registerName("URL"))
	path_value := msg_id(url, sel_registerName("path"))
	utf8 := msg_id(path_value, sel_registerName("UTF8String"))
	if utf8 == nil {return "", false}
	path, clone_error := strings.clone(string(cstring(utf8)))
	return path, clone_error == nil
}

source_local_paths_clear :: proc() {
	for path in source_local_paths {delete(path)}
	for title in source_local_titles {delete(title)}
	delete(source_local_paths)
	delete(source_local_titles)
	source_local_paths = make([dynamic]string)
	source_local_titles = make([dynamic]string)
}

source_local_path_append :: proc(path: string) -> bool {
	if len(strings.trim_space(path)) == 0 || !os.exists(path) {return false}
	for existing in source_local_paths {
		if existing == path {return false}
	}
	append(&source_local_paths, strings.clone(path))
	append(&source_local_titles, local_source_title(path))
	return true
}

source_local_path_remove :: proc(index: int) -> bool {
	if index < 0 || index >= len(source_local_paths) ||
	   index >= len(source_local_titles) {return false}
	delete(source_local_paths[index])
	delete(source_local_titles[index])
	ordered_remove(&source_local_paths, index)
	ordered_remove(&source_local_titles, index)
	if ui.local_source_title_index == index {
		ui.focus = .None
		ui.local_source_title_index = -1
	} else if ui.local_source_title_index > index {
		ui.local_source_title_index -= 1
	}
	ui.needs_redraw = true
	return true
}

source_local_files_with_panel :: proc() -> bool {
	panel := msg_id(objc_getClass("NSOpenPanel"), sel_registerName("openPanel"))
	if panel == nil {return false}
	msg_void_bool(panel, sel_registerName("setCanChooseFiles:"), true)
	msg_void_bool(panel, sel_registerName("setCanChooseDirectories:"), false)
	msg_void_bool(panel, sel_registerName("setAllowsMultipleSelection:"), true)
	if msg_i64(panel, sel_registerName("runModal")) != 1 {return false}
	urls := msg_id(panel, sel_registerName("URLs"))
	count := int(msg_uint(urls, sel_registerName("count")))
	added := false
	for index in 0 ..< count {
		url := msg_id_uint(urls, sel_registerName("objectAtIndex:"), uint(index))
		path_value := msg_id(url, sel_registerName("path"))
		utf8 := msg_id(path_value, sel_registerName("UTF8String"))
		if utf8 == nil {continue}
		path := string(cstring(utf8))
		if source_local_path_append(path) {added = true}
	}
	if added {
		ui.needs_redraw = true
		set_text(state.status, fmt.tprintf("Added %d local file(s) to the source batch", count))
	}
	return added
}

on_browse_source_files :: proc "c" (self: Id, command: Sel, sender: Id) {
	context = runtime.default_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	_ = source_local_files_with_panel()
}

source_local_file_with_panel :: proc() -> (string, bool) {
	panel := msg_id(objc_getClass("NSOpenPanel"), sel_registerName("openPanel"))
	if panel == nil {return "", false}
	msg_void_bool(panel, sel_registerName("setCanChooseFiles:"), true)
	msg_void_bool(panel, sel_registerName("setCanChooseDirectories:"), false)
	msg_void_bool(panel, sel_registerName("setAllowsMultipleSelection:"), false)
	if msg_i64(panel, sel_registerName("runModal")) != 1 {return "", false}
	url := msg_id(panel, sel_registerName("URL"))
	path_value := msg_id(url, sel_registerName("path"))
	utf8 := msg_id(path_value, sel_registerName("UTF8String"))
	if utf8 == nil {return "", false}
	path, clone_error := strings.clone(string(cstring(utf8)))
	return path, clone_error == nil
}

relink_local_source :: proc(source_index: int) {
	if source_index < 0 || source_index >= len(state.sources) {return}
	source := &state.sources[source_index]
	if source.kind != .Local {return}
	path, selected := source_local_file_with_panel()
	if !selected {return}
	defer delete(path)
	delete(pending_local_relink_path)
	pending_local_relink_path = strings.clone(path)
	relink_local_source_path(source_index, path)
}

relink_local_source_path :: proc(source_index: int, path: string) {
	if source_index < 0 || source_index >= len(state.sources) {return}
	source := &state.sources[source_index]
	if source.kind != .Local || len(path) == 0 {return}
	if !require_helper("ffmpeg") || !require_helper("ffprobe") {return}
	if !major_change_backup_preflight(.Local_Source_Relink, source_index=source_index) {return}
	job := import_job_create_local(path, source.title, source.workflow)
	if job == nil {set_error_status("Unable to allocate the local source recovery"); return}
	allocator := mem_virtual.arena_allocator(job.arena)
	job.replace_video_id = strings.clone(source.video_id, allocator)
	job.allow_without_backup = major_change_backup_override
	major_change_backup_override = false
	fields := [2]Notification_Field{
		{label="Source", value=source.title},
		{label="Selected file", value=path},
	}
	job.notification_id = notification_begin(
		"Local source recovery queued",
		"The selected file must match the original SHA-256 before the managed media and clips are rebuilt.",
		fields[:],
	)
	os.write_entire_file(job.log_path, nil)
	if !media_queue_schedule_import(job, barrier=true) {
		import_job_destroy(job)
		set_error_status("Unable to queue the local source recovery")
		return
	}
	delete(pending_local_relink_path)
	pending_local_relink_path = ""
	set_text(state.status, "Local source recovery queued")
}

export_library_with_panel :: proc(
	scope := Portable_Library_Scope.All,
) {
	path, selected := library_panel_path(true, scope)
	if !selected {return}
	defer delete(path)
	if export_error := portable_library_export(path, scope);
	   export_error != .None {
		set_error_status(portable_library_error_text(export_error))
		return
	}
	set_success_status(fmt.tprintf("Exported library metadata to %s", filepath.base(path)))
	close_data_modal()
}

prepare_library_import_with_panel :: proc() {
	path, selected := library_panel_path(false)
	if !selected {return}
	defer delete(path)
	imported, scope, import_error := portable_library_read_scoped(path)
	if import_error != .None {
		set_error_status(portable_library_error_text(import_error))
		return
	}
	app_state_collections_destroy(&pending_library_import)
	pending_library_import = imported
	pending_library_import_scope = scope
	ui.library_import_confirm_open = true
	ui.library_import_pending = true
	ui.needs_redraw = true
}

confirm_library_import :: proc() {
	if library_transfer_busy() {
		set_error_status("A library replacement is already queued")
		return
	}
	if !flush_active_clip_draft() {return}
	if !major_change_backup_preflight(.Library_Replacement) {return}
	allow_without_backup := major_change_backup_override
	major_change_backup_override = false
	job := new(Library_Replacement_Job)
	copy, copied := app_state_collections_clone(&pending_library_import)
	if !copied {
		free(job)
		set_error_status("Unable to allocate the queued library replacement")
		return
	}
	job.library = copy
	job.scope = pending_library_import_scope
	job.allow_without_backup = allow_without_backup
	job.notification_id = notification_begin(
		"Library replacement queued",
		"The media queue will finish earlier tasks before it installs and recovers this library.",
	)
	library_replacement_job = job
	ui.library_import_confirm_open = false
	if !media_queue_schedule_library_replacement(job) {
		library_replacement_job = nil
		app_state_collections_destroy(&job.library)
		_ = notification_finish(
			job.notification_id,
			.Error,
			"Unable to queue the library replacement",
		)
		free(job)
		set_error_status("Unable to queue the library replacement")
		return
	}
	set_text(state.status, "Library replacement queued")
}

finish_library_replacement_job :: proc(job: ^Library_Replacement_Job) {
	if job == nil {
		return
	}
	if job.cancelled {
		_ = notification_finish(
			job.notification_id,
			.Interrupted,
			"Library replacement cancelled",
		)
		return
	}
	metal_player_clear()
	if install_error := portable_library_install(
		&job.library,
		job.scope,
		job.allow_without_backup,
	);
	   install_error != .None {
		_ = notification_finish(
			job.notification_id,
			.Error,
			"Library replacement failed",
			portable_library_error_text(install_error),
		)
		set_error_status(portable_library_error_text(install_error))
		return
	}
	state.active_source = -1
	state.has_start = false
	state.has_end = false
	ui.clip_draft_revision = 0
	ui_set_string(&ui.clip_name, "")
	ui.active_clip = -1
	ui.source_scroll = 0
	ui.transcript_scroll = 0
	ui.clip_scroll = 0
	ui.data_modal_open = false
	ui.library_import_confirm_open = false
	ui.library_import_pending = false
	ui.source_playback_active = false
	refresh_sources()
	refresh_clips()
	_ = database_clip_drafts_prune(library_database)
	_ = notification_finish(
		job.notification_id,
		.Success,
		"Library replacement installed",
	)
	_ = library_recovery_start()
}

library_replacement_job_destroy :: proc(job: ^Library_Replacement_Job) {
	if job == nil {
		return
	}
	app_state_collections_destroy(&job.library)
	free(job)
}

on_library_replacement_ready :: proc "c" (
	self: Id,
	command: Sel,
	sender: Id,
) {
	context = runtime.default_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	job := library_replacement_job
	library_replacement_job = nil
	finish_library_replacement_job(job)
	if job != nil {
		media_task_completion_finish(&job.completion)
	}
}

jobs_shutdown :: proc() {
	if source_metadata_job != nil {
		if source_metadata_job.thread != nil {
			thread.join(source_metadata_job.thread)
			thread.destroy(source_metadata_job.thread)
			source_metadata_job.thread = nil
		}
		source_metadata_job_destroy(source_metadata_job)
		source_metadata_job = nil
	}
	library_recovery_destroy()
	if media_queue_initialized {
		if clip_normalize_job != nil && clip_normalize_job.cli_work != nil {
			cli_ipc_work_finish(
				clip_normalize_job.cli_work,
				cli_error(
					.Clip_Normalize_Timestamps,
					.Busy,
					"app_stopping",
					"The application stopped before clip normalization completed",
				),
			)
			clip_normalize_job.cli_work = nil
		}
		media_queue_begin_shutdown()
		task_queue.queue_destroy(&media_queue, .Cancel_All)
		media_queue_initialized = false
	}
	if clip_normalize_job != nil {
		job := clip_normalize_job
		clip_normalize_job = nil
		clip_normalize_job_destroy(job)
	}
	if bpm_job != nil {
		job := bpm_job
		bpm_job = nil
		bpm_job_destroy(job)
	}
	bpm_runtime_result_clear()
	if waveform_job != nil {
		job := waveform_job
		waveform_job = nil
		waveform_job_destroy(job)
	}
	waveform_cache_destroy()
	delete(waveform_runtime.path)
	waveform_runtime = {}
	if source_probe_job != nil {
		source_probe_job_destroy(source_probe_job)
		source_probe_job = nil
	}
	if library_replacement_job != nil {
		job := library_replacement_job
		library_replacement_job = nil
		job.cancelled = true
		finish_library_replacement_job(job)
		library_replacement_job_destroy(job)
	}
	for job in import_jobs {
		if job.cli_work != nil {
			cli_ipc_work_finish(
				job.cli_work,
				cli_error(
					.Source_Add,
					.Busy,
					"app_stopping",
					"The application stopped before the queued source import completed",
				),
			)
		}
		import_job_destroy(job)
	}
	delete(import_jobs)
	import_jobs = nil
	sync.mutex_lock(&import_completion_mutex)
	delete(import_completed_jobs)
	import_completed_jobs = nil
	sync.mutex_unlock(&import_completion_mutex)
	for job in export_jobs {
		if job.cli_work != nil {
			cli_ipc_work_finish(
				job.cli_work,
				cli_error(
					.Clip_Create,
					.Busy,
					"app_stopping",
					"The application stopped before the queued clip export completed",
				),
			)
		}
		export_job_destroy(job)
	}
	delete(export_jobs)
	export_jobs = nil
	sync.mutex_lock(&export_completion_mutex)
	delete(export_completed_jobs)
	export_completed_jobs = nil
	sync.mutex_unlock(&export_completion_mutex)
}

video_clips_process_main :: proc(args := os.args) {
	if !memory_init() { fmt.eprintln("Unable to initialize memory arenas"); return }
	defer memory_destroy()
	defer helper_statuses_destroy()
	defer cli_library_release()
	if error := match_sorter.search_context_init(
		&transcript_search_context,
		SEARCH_RESERVE_SIZE,
		SEARCH_COMMIT_SIZE,
	); error != nil {
		fmt.eprintln("Unable to initialize transcript search")
		return
	}
	defer match_sorter.search_context_destroy(&transcript_search_context)
	defer app_state_memory_destroy()
	defer library_recovery_state_destroy()
	defer delete(major_change_pending.detail)
	defer delete(pending_local_relink_path)
	defer delete(pending_source_delete_id)
	defer delete(pending_clip_delete_id)
	defer source_local_paths_clear()
	defer source_probe_results_clear()
	defer source_probe_cache_clear()
	defer database_close()
	defer cli_ipc_server_stop()
	defer jobs_shutdown()
	if !migrate_legacy_app_support_dir() {return}
	configure_helper_path()
	objc_handle := os.dlopen("/usr/lib/libobjc.A.dylib", os.RTLD_NOW)
	send_address = os.dlsym(objc_handle, "objc_msgSend")
	if send_address == nil { fmt.eprintln("Unable to resolve objc_msgSend"); return }
	defer ui_memory_destroy()
	libsystem_handle := os.dlopen("/usr/lib/libSystem.B.dylib", os.RTLD_NOW)
	system_address = os.dlsym(libsystem_handle, "system")
	if system_address == nil { fmt.eprintln("Unable to resolve system"); return }
	state.active_source = -1
	if len(args) > 1 {
		request, parse_result, parsed := cli_parse_request(args[1:])
		result := parse_result
		if parsed {
			if routed_result, routed := cli_ipc_try_request(request); routed {
				result = routed_result
			} else if cli_command_requires_gui(request.command) {
				result = cli_error(request.command, .Busy, "gui_not_running", "The UI command requires a running application")
				} else if !cli_library_try_acquire() {
					result = cli_error(request.command, .Busy, "busy", "The app owns the library, but its CLI control socket is not ready")
				} else {
					load_result := load_library()
					if load_result.mode != .Ready {
						error_code := "library_recovery_required"
						if load_result.stage == .Schema &&
						   load_result.schema_version > LIBRARY_SCHEMA_VERSION {
							error_code = "library_schema_newer"
						}
						result = cli_error(
							request.command,
							.Storage,
							error_code,
							load_result.detail,
						)
					} else {
						result = cli_execute(request)
					}
					library_load_result_destroy(&load_result)
				}
		}
		fmt.println(result.output)
		delete(result.output)
		os.exit(int(result.exit_code))
	}
	if !media_queue_init() {
		fmt.eprintln("Unable to initialize the media task queue")
		return
	}
	if !cli_library_try_acquire() {
		fmt.eprintln("hw_videoClips is already running or the library is busy")
		return
	}
	load_result := load_library()
	ui.theme = database_interface_theme_load(library_database)
	ui.metronome_volume = database_metronome_volume_load(library_database)
	ui.vocal_playback_rate = database_vocal_playback_rate_load(
		library_database,
	)
	active_view := database_active_view_load(library_database)
	ui.workflow = active_view.workflow
	ui.mode = active_view.mode
	for workflow in Workflow_Kind {
		workflow_index := int(workflow)
		ui.source_selection_ids[workflow_index],
		ui.source_selection_saved[workflow_index] =
			database_list_selection_load(library_database, workflow, .Create)
		ui.clip_selection_ids[workflow_index],
		ui.clip_selection_saved[workflow_index] =
			database_list_selection_load(library_database, workflow, .Play)
	}
	ui.playback_rate =
		ui.workflow == .Vocal ? ui.vocal_playback_rate : 1
	if !ui_automation_seed_fixture() {
		fmt.eprintln("Unable to seed the isolated UI test fixture")
		return
	}
	notification_history_initialize()
	if app_support_migration_conflict {
		_ = notification_post(
			.Info,
			"Legacy VocalTraining library retained",
			"Both Application Support directories contain libraries. hw_videoClips opened its own library and did not merge or remove the legacy data.",
		)
	}
	if load_result.mode != .Ready {
		_ = notification_post(
			.Error,
			"Library recovery is required",
			load_result.detail,
			persist = false,
		)
		if library_recovery_state.recovery_allowed {
			_ = library_recovery_analyze()
		}
	}
	library_load_result_destroy(&load_result)
	defer notification_history_destroy()
	pool := msg_id(objc_getClass("NSAutoreleasePool"), sel_registerName("new"))
	build_metal_window()
	metal_player_clear()
	msg_void(pool, sel_registerName("drain"))
}

main :: proc() {
	video_clips_process_main()
}
