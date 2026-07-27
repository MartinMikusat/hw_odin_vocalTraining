package main

import "core:fmt"
import "core:encoding/json"
import "core:mem"
import "core:os"
import os2 "core:os/os2"
import "core:path/filepath"
import "core:strings"
import "core:thread"
import "core:sync"
import "base:runtime"
import mem_virtual "core:mem/virtual"
import match_sorter "match_sorter:."

Id  :: rawptr
Sel :: rawptr

SEARCH_RESERVE_SIZE :: uint(64 * mem.Megabyte)
SEARCH_COMMIT_SIZE :: uint(64 * mem.Kilobyte)

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

Source_Video :: struct {
	id: string,
	video_id: string,
	title: string,
	url: string,
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

Exercise :: struct {
	id: string,
	source_id: string,
	name: string,
	start_seconds: f64,
	end_seconds: f64,
	clip_path: string,
}

App_State :: struct {
	window: Id,
	url_input: Id,
	status: Id,
	player: Id,
	exercise_name_input: Id,
	source_search_input: Id,
	exercise_search_input: Id,
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
	exercises: [dynamic]Exercise,
}

state: App_State
send_address: rawptr
system_address: rawptr
last_imported_source: int = -1

Helper_Status :: struct {
	checked: bool,
	available: bool,
	reason: string,
}

yt_dlp_helper_status: Helper_Status
ffmpeg_helper_status: Helper_Status

Import_Phase :: enum {
	Preparing,
	Validating_Existing_Media,
	Downloading,
	Validating_Downloaded_Media,
	Rebuilding_Exercises,
}

Import_Job :: struct {
	thread: ^thread.Thread,
	completion_target: Id,
	arena: ^mem_virtual.Arena,
	input: string,
	sources: [dynamic]Source_Video,
	hints: [dynamic]Import_Hint,
	exercises: [dynamic]Exercise,
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
	accepted: int,
	failed: int,
	existing_sources: int,
	updated_hints: int,
	latest_updated_hint: f64,
	refreshed_exercises: int,
	failed_exercise_refreshes: int,
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
	thread: ^thread.Thread,
	completion_target: Id,
	arena: ^mem_virtual.Arena,
	exercise: Exercise,
	source_path: string,
	operation: Export_Operation,
	notification_id: i64,
	success: bool,
}

Library_Recovery_Entry :: struct {
	video_id: string,
	height:   int,
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
pending_library_import: App_State

Source_Metadata_Job :: struct {
	thread: ^thread.Thread,
	completion_target: Id,
	video_id: string,
	media_path: string,
	metadata: Source_Context_Metadata,
	metadata_loaded: bool,
}

import_job: ^Import_Job
export_job: ^Export_Job
source_metadata_job: ^Source_Metadata_Job

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
		_ = notification_post_info(text)
		return
	}
	if control == state.exercise_name_input {
		ui_set_string(&ui.exercise_name, text)
		ui.needs_redraw = true
		return
	}
	msg_void_id(control, sel_registerName("setStringValue:"), nsstring(text))
}

set_success_status :: proc(text: string) {
	_ = notification_post_success(text)
}

set_error_status :: proc(text: string) {
	_ = notification_post_error(text)
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
	if control == state.exercise_search_input { return ui.exercise_search }
	if control == state.exercise_name_input { return ui.exercise_name }
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

parse_video_id :: proc(url: string) -> (string, bool) {
	if i := strings.index(url, "youtu.be/"); i >= 0 {
		v := url[i+len("youtu.be/"):]
		if e := strings.index_any(v, "?&#"); e >= 0 { v = v[:e] }
		return v, len(v) > 0
	}
	if i := strings.index(url, "v="); i >= 0 {
		v := url[i+2:]
		if e := strings.index_any(v, "&#"); e >= 0 { v = v[:e] }
		return v, len(v) > 0
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

app_support_dir :: proc() -> string {
	if override := getenv("VT_APP_SUPPORT_DIR"); override != nil && len(string(override)) > 0 {
		return string(override)
	}
	home := getenv("HOME")
	return fmt.tprintf("%s/Library/Application Support/VocalTraining", string(home))
}

diagnostic_log_path :: proc(name: string) -> string {
	return fmt.tprintf("%s/%s.log", app_support_dir(), name)
}

import_progress_path :: proc() -> string {
	return fmt.tprintf("%s/yt-dlp-progress.log", app_support_dir())
}

download_progress_status :: proc(contents: string) -> (string, bool) {
	latest := ""
	remaining_lines := contents
	for line in strings.split_lines_iterator(&remaining_lines) {
		if strings.has_prefix(line, "VT_PROGRESS|") {latest = line}
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
	case .Validating_Downloaded_Media:
		return fmt.tprintf("%svalidating downloaded media", prefix)
	case .Rebuilding_Exercises:
		return fmt.tprintf("%srebuilding exercises", prefix)
	}
	return fmt.tprintf("%spreparing media", prefix)
}

refresh_import_progress :: proc() {
	if import_job == nil {return}
	contents, _ := os.read_entire_file(import_progress_path(), context.temp_allocator)
	status := import_progress_status(import_job, string(contents))
	if import_job.notification_id != 0 {
		phase := import_job_phase(import_job)
		source_progress := ""
		if import_job.library_recovery_source {
			source_progress = fmt.tprintf(
				"%d of %d",
				import_job.recovery_index,
				import_job.recovery_total,
			)
		}
		fields := [3]Notification_Field{
			{label="Operation", value=import_job.library_recovery_source ? "Library recovery" : "Media import"},
			{label="Source", value=source_progress},
			{label="Phase", value=fmt.tprintf("%v", phase)},
		}
		phase_changed := !import_job.has_notification_phase ||
		                 import_job.last_notification_phase != phase
		import_job.last_notification_phase = phase
		import_job.has_notification_phase = true
		_ = notification_update(
			import_job.notification_id,
			status,
			"The application validates local media, downloads missing media, and rebuilds saved exercise clips.",
			fields[:],
			persist_now = phase_changed,
		)
	} else {
		set_text(state.status, status)
	}
}

embedded_helper_path :: proc(executable_path, name: string) -> string {
	executable_dir := filepath.dir(executable_path, context.temp_allocator)
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

clip_export_command :: proc(source_path, clip_path: string, start_seconds, end_seconds: f64, ffmpeg := "") -> string {
	ffmpeg_command := ffmpeg
	if len(ffmpeg_command) == 0 { ffmpeg_command = helper_command("ffmpeg") }
	return fmt.tprintf("%s -y -loglevel error -ss %.3f -i %s -t %.3f -c:v libx264 -c:a aac -movflags +faststart %s >> %s 2>&1", shell_quote(ffmpeg_command), start_seconds, shell_quote(source_path), end_seconds-start_seconds, shell_quote(clip_path), shell_quote(diagnostic_log_path("ffmpeg")))
}

import_url :: proc(url: string) -> bool {
	video_id, ok := parse_video_id(url)
	if !ok { return false }
	for source, index in state.sources {
		if source.video_id == video_id {
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
	dir := app_support_dir()
	os.make_directory(dir)
	os.make_directory(fmt.tprintf("%s/sources", dir))
	output := fmt.tprintf("%s/sources/%s.%%(ext)s", dir, video_id)
	command := youtube_download_command(url, output, diagnostic_log_path("yt-dlp"))
	c_command := strings.clone_to_cstring(command)
	defer delete(c_command)
	run := transmute(proc "c" (cstring) -> int)system_address
	result := run(c_command)
	if result != 0 { return false }
	media_path := fmt.tprintf("%s/sources/%s.mp4", dir, video_id)
	if !os.exists(media_path) {return false}
	id_copy := strings.clone(video_id)
	url_copy := strings.clone(url)
	append(&state.sources, Source_Video{id=id_copy, video_id=strings.clone(video_id), title=strings.clone(video_id), url=url_copy, media_path=strings.clone(media_path), media_available=true})
	last_imported_source = len(state.sources)-1
	if metadata, loaded := load_download_metadata(video_id); loaded {
		delete(state.sources[len(state.sources)-1].title)
		state.sources[len(state.sources)-1].title = strings.clone(metadata.title)
		state.sources[len(state.sources)-1].duration = metadata.duration
		delete(metadata.title)
	}
	if seconds, has_time := parse_timestamp(url); has_time {
		append(&state.hints, Import_Hint{source_id=strings.clone(video_id), seconds=seconds})
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
	if name == "ffmpeg" {
		version_flag = "-version"
		expected_output = "ffmpeg\\ version\\ *"
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
	yt_dlp_helper_status = {}
	ffmpeg_helper_status = {}
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
	if yt_dlp.available && ffmpeg.available { return }

	message := "Vocal Training checked its media helpers before starting."
	if !yt_dlp.available {
		message = fmt.tprintf("%s\n\n%s. YouTube import and refetch are unavailable.", message, yt_dlp.reason)
	}
	if !ffmpeg.available {
		message = fmt.tprintf("%s\n\n%s. Import, refetch, preview, and exercise export are unavailable.", message, ffmpeg.reason)
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

valid_exercise_range :: proc(start, end, source_duration: f64) -> bool {
	return start >= 0 &&
	       end - start >= 1 &&
	       (source_duration <= 0 || end <= source_duration)
}

active_exercise_range_is_valid :: proc() -> bool {
	if state.active_source < 0 || state.active_source >= len(state.sources) {return false}
	return state.has_start &&
	       state.has_end &&
	       valid_exercise_range(
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

exercise_index_for_id :: proc(exercises: []Exercise, exercise_id: string) -> int {
	for exercise, index in exercises {
		if exercise.id == exercise_id {return index}
	}
	return -1
}

source_index_for_exercise :: proc(
	sources: []Source_Video,
	exercises: []Exercise,
	exercise_index: int,
) -> int {
	if exercise_index < 0 || exercise_index >= len(exercises) {return -1}
	return source_index_for_id(sources, exercises[exercise_index].source_id)
}

rename_exercise :: proc(index: int, name: string) -> bool {
	if index < 0 || index >= len(state.exercises) {return false}
	trimmed := strings.trim_space(name)
	if len(trimmed) == 0 {return false}
	exercise := &state.exercises[index]
	if exercise.name == trimmed {return true}
	replacement, err := strings.clone(trimmed)
	if err != nil {return false}
	original := exercise.name
	exercise.name = replacement
	if !save_library() {
		exercise.name = original
		delete(replacement)
		return false
	}
	delete(original)
	refresh_exercises()
	return true
}

seek_video_seconds :: proc(seconds: f64) {
	if state.player == nil { return }
	t := CMTime{value=i64(seconds*600), timescale=600, flags=1}
	tolerance := CMTime{value=10, timescale=600, flags=1}
	msg_void_time_time_time(
		state.player,
		sel_registerName("seekToTime:toleranceBefore:toleranceAfter:"),
		t,
		tolerance,
		tolerance,
	)
}

seek_seconds :: proc(seconds: f64) {
	if state.player == nil { return }
	request_transcript_follow_to(seconds)
	resume := msg_f32(state.player, sel_registerName("rate")) > 0
	seek_video_seconds(seconds)
	metal_audio_seek(seconds, resume)
}

scrub_player_by :: proc(delta: f64) {
	if state.player == nil {return}
	seconds, ok := current_seconds()
	if !ok {return}
	seek_seconds(min(max(seconds + delta, 0), ui.player_duration))
	ui.needs_redraw = true
}

start_loaded_playback_at :: proc(seconds: f64) {
	if state.player == nil {return}
	seek_seconds(seconds)
	msg_void_f32(state.player, sel_registerName("setRate:"), ui.playback_rate)
	metal_audio_play()
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
	msg_void(state.player, sel_registerName("pause"))
	metal_audio_pause()
	seek_seconds(0)
	ui.needs_redraw = true
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

load_source_player :: proc(index: int) -> bool {
	if index < 0 || index >= len(state.sources) { return false }
	ui.source_hint_menu_open = false
	source := &state.sources[index]
	state.active_source = index
	source.media_available = os.exists(source.media_path)
	if !source.media_available || !media_file_validate(source.media_path) {
		metal_player_clear()
		refresh_transcript()
		return false
	}
	path := source.media_path
	if !metal_player_load(path) {metal_player_clear(); return false}
	ui.player_duration = source.duration
	set_source_playback_active(true)
	state.has_start, state.has_end = false, false
	set_text(state.exercise_name_input, "")
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

refresh_exercises :: proc() {
	ui.needs_redraw = true
}

on_transcribe :: proc "c" (self: Id, command: Sel, sender: Id) {
	context = runtime.default_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	if import_job != nil { set_text(state.status, "Wait for the active import to finish"); return }
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

export_exercise :: proc(exercise: ^Exercise, source_path: string, allocator := context.allocator) -> bool {
	dir := app_support_dir()
	os.make_directory(fmt.tprintf("%s/clips", dir))
	exercise.clip_path = fmt.aprintf("%s/clips/%s.mp4", dir, exercise.id, allocator=allocator)
	command := clip_export_command(source_path, exercise.clip_path, exercise.start_seconds, exercise.end_seconds)
	c_command := strings.clone_to_cstring(command)
	defer delete(c_command)
	run := transmute(proc "c" (cstring) -> int)system_address
	return run(c_command) == 0
}

import_job_destroy :: proc(job: ^Import_Job) {
	if job == nil { return }
	transcript_generation_destroy(&job.snapshot_transcripts)
	transcript_generation_destroy(&job.transcripts)
	growing_arena_destroy(job.arena)
	free(job)
}

import_job_create :: proc(input: string, replace_video_id := "") -> ^Import_Job {
	arena, ok := growing_arena_create()
	if !ok { return nil }
	job := new(Import_Job)
	job.arena = arena
	job.completion_target = state.delegate_target
	allocator := mem_virtual.arena_allocator(arena)
	job.input = strings.clone(input, allocator)
	job.replace_video_id = strings.clone(replace_video_id, allocator)
	job.sources = make([dynamic]Source_Video, 0, len(state.sources), allocator)
	job.hints = make([dynamic]Import_Hint, 0, len(state.hints), allocator)
	job.exercises = make([dynamic]Exercise, 0, len(state.exercises), allocator)
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
	for exercise in state.exercises {
		copy, copied := clone_exercise(exercise, allocator)
		if !copied { import_job_destroy(job); return nil }
		append(&job.exercises, copy)
	}
	job.snapshot_transcripts, ok = transcript_generation_copy(state.transcripts.segments[:])
	if !ok { import_job_destroy(job); return nil }
	return job
}

import_job_find_source :: proc(job: ^Import_Job, video_id: string) -> ^Source_Video {
	for &source in job.sources { if source.video_id == video_id { return &source } }
	for &source in job.new_sources { if source.video_id == video_id { return &source } }
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

staged_source_cleanup :: proc(directory, video_id: string) {
	handle, open_error := os.open(directory)
	if open_error != nil {return}
	defer os.close(handle)
	entries, read_error := os.read_dir(handle, -1, context.temp_allocator)
	if read_error != nil {return}
	prefix := fmt.tprintf("%s.download.", video_id)
	for entry in entries {
		if strings.has_prefix(entry.name, prefix) {_ = os.remove(fmt.tprintf("%s/%s", directory, entry.name))}
	}
}

staged_source_validate :: proc(directory, video_id: string) -> bool {
	media_path := fmt.tprintf("%s/%s.download.mp4", directory, video_id)
	info_path := fmt.tprintf("%s/%s.download.info.json", directory, video_id)
	bytes, read_ok := os.read_entire_file(info_path, context.temp_allocator)
	if !read_ok {return false}
	metadata: YTDLP_Metadata
	if parse_error := json.unmarshal(bytes, &metadata, .JSON, context.temp_allocator); parse_error != nil {return false}
	video_ok := strings.has_prefix(metadata.vcodec, "avc1") || strings.has_prefix(metadata.vcodec, "h264")
	audio_ok := strings.has_prefix(metadata.acodec, "mp4a") || strings.has_prefix(metadata.acodec, "aac")
	if metadata.width <= 0 || metadata.height <= 0 || !video_ok || !audio_ok {return false}
	return media_file_validate(media_path)
}

media_file_validate :: proc(media_path: string) -> bool {
	command := [14]string{helper_command("ffmpeg"), "-v", "info", "-i", media_path, "-map", "0:v:0", "-map", "0:a:0", "-t", "1", "-f", "null", "-"}
	process_state, stdout, stderr, process_error := os2.process_exec({command=command[:]}, context.temp_allocator)
	_ = stdout
	streams_ok := strings.contains(string(stderr), "Video: h264") && strings.contains(string(stderr), "Audio: aac")
	return process_error == nil && process_state.success && streams_ok
}

staged_source_commit :: proc(directory, video_id: string) -> bool {
	handle, open_error := os.open(directory)
	if open_error != nil {return false}
	defer os.close(handle)
	entries, read_error := os.read_dir(handle, -1, context.temp_allocator)
	if read_error != nil {return false}
	prefix := fmt.tprintf("%s.download.", video_id)
	media_name := fmt.tprintf("%s.download.mp4", video_id)
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
	progress_file, progress_error := os2.open(import_progress_path(), {.Write, .Create, .Trunc, .Inheritable})
	if progress_error != nil {return false}
	defer os2.close(progress_file)
	log_file, log_error := os2.open(diagnostic_log_path("yt-dlp"), {.Write, .Create, .Append, .Inheritable})
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
	_ = os2.process_close(process)
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
		"download:VT_PROGRESS|%(progress._percent_str)s|%(progress._total_bytes_str)s|%(progress._speed_str)s|%(progress._eta_str)s",
		"-o",
		output,
		url,
	)
	return command
}

import_job_rebuild_exercises :: proc(job: ^Import_Job, source: ^Source_Video) {
	import_job_set_phase(job, .Rebuilding_Exercises)
	run := transmute(proc "c" (cstring) -> int)system_address
	os.make_directory(fmt.tprintf("%s/clips", app_support_dir()))
	for exercise in job.exercises {
		if exercise.source_id != source.id || len(exercise.clip_path) == 0 {continue}
		command := clip_export_command(
			source.media_path,
			exercise.clip_path,
			exercise.start_seconds,
			exercise.end_seconds,
		)
		c_command := strings.clone_to_cstring(command)
		result := run(c_command)
		delete(c_command)
		if result == 0 {
			job.refreshed_exercises += 1
		} else {
			job.failed_exercise_refreshes += 1
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
				import_job_rebuild_exercises(job, source)
				return true
			}
		}
		if job.library_recovery_source && source.metadata.height <= 0 {
			return false
		}
	}

	dir := app_support_dir()
	os.make_directory(dir)
	os.make_directory(fmt.tprintf("%s/sources", dir))
	source_directory := fmt.tprintf("%s/sources", dir)
	staged_source_cleanup(source_directory, video_id)
	output := fmt.tprintf("%s/%s.download.%%(ext)s", source_directory, video_id)
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
		staged_source_cleanup(source_directory, video_id)
		return false
	}
	import_job_set_phase(job, .Validating_Downloaded_Media)
	if !staged_source_validate(source_directory, video_id) || !staged_source_commit(source_directory, video_id) {
		job.invalid_merged_media += 1
		staged_source_cleanup(source_directory, video_id)
		return false
	}
	media_path := fmt.tprintf("%s/sources/%s.mp4", dir, video_id)
	if !os.exists(media_path) {
		job.missing_merged_media += 1
		return false
	}

	existing := import_job_find_source(job, video_id)
	source_id := video_id
	if existing != nil { source_id = existing.id }
	source := Source_Video{
		id=strings.clone(source_id, allocator),
		video_id=strings.clone(video_id, allocator),
		title=strings.clone(video_id, allocator),
		url=strings.clone(url, allocator),
		media_path=strings.clone(media_path, allocator),
		media_available=true,
	}
	if metadata, loaded := load_download_metadata(video_id, allocator); loaded {
		delete(source.title, allocator)
		source.title = metadata.title
		source.duration = metadata.duration
		source.metadata = Source_Context_Metadata {
			width = metadata.width,
			height = metadata.height,
			fps = metadata.fps,
			vcodec = metadata.vcodec,
			acodec = metadata.acodec,
			ext = metadata.ext,
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
		import_job_rebuild_exercises(job, &source)
	}
	return true
}

import_worker :: proc(t: ^thread.Thread) {
	context = runtime.default_context()
	job := cast(^Import_Job)t.data
	for raw in strings.split_lines(job.input) {
		if import_job_is_cancelled(job) {break}
		url := strings.trim_space(raw)
		if len(url) == 0 { continue }
		if import_job_process_url(job, url) { job.accepted += 1 } else { job.failed += 1 }
	}
	msg_void_sel_id_b(job.completion_target, sel_registerName("performSelectorOnMainThread:withObject:waitUntilDone:"), sel_registerName("importFinished:"), nil, false)
}

import_job_apply :: proc(job: ^Import_Job) -> bool {
	if job == nil || job.accepted <= 0 {return false}
	if job.has_source_update {
		updated := false
		for &source, index in state.sources {
			if source.video_id != job.updated_source.video_id {continue}
			copy, copied := clone_source_video(job.updated_source)
			if !copied {return false}
			delete_source_video(&source)
			source = copy
			last_imported_source = index
			updated = true
			break
		}
		if !updated {return false}
	}
	for source in job.new_sources {
		copy, copied := clone_source_video(source)
		if !copied {return false}
		append(&state.sources, copy)
	}
	for hint in job.new_hints {
		copy, copied := clone_import_hint(hint)
		if !copied {return false}
		append(&state.hints, copy)
	}
	if job.has_transcript_update {
		install_transcript_generation(job.transcripts)
		job.transcripts = {}
	}
	for source, index in state.sources {
		if source.video_id == job.last_video_id {last_imported_source = index; break}
	}
	if job.has_pending_hint {state.pending_hint, state.has_pending_hint = job.pending_hint, true}
	return save_library()
}

on_import_finished :: proc "c" (self: Id, command: Sel, sender: Id) {
	context = runtime.default_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	job := import_job
	if job == nil { return }
	thread.join(job.thread)
	thread.destroy(job.thread)
	job.thread = nil
	if job.library_recovery_source {
		success := false
		if !job.cancelled && job.accepted > 0 {
			success = import_job_apply(job) &&
			          job.failed == 0 &&
			          job.failed_exercise_refreshes == 0
			refresh_sources()
			refresh_exercises()
		}
		cancelled := job.cancelled
		if library_recovery == nil {
			import_job = nil
			import_job_destroy(job)
			return
		}
		if cancelled {
			library_recovery.cancelled = true
			import_job = nil
			import_job_destroy(job)
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
				); source_index >= 0 {
					state.sources[source_index].media_available = false
				}
			}
		}
		import_job = nil
		import_job_destroy(job)
		library_recovery_start_next()
		return
	}
	defer {
		import_job = nil
		import_job_destroy(job)
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
				last_imported_source,
			) {
				load_source_player(last_imported_source)
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
		   should_load_completed_source(true, state.active_source, last_imported_source) {
			load_source_player(last_imported_source)
		}
		if job.invalid_merged_media > 0 {
			_ = notification_finish(
				job.notification_id,
				.Error,
				"Download failed media validation",
				"The staged MP4 did not contain decodable H.264 video and AAC audio. The previous source file was preserved.",
			)
		} else if job.missing_merged_media > 0 {
			_ = notification_finish(
				job.notification_id,
				.Error,
				"Import failed: yt-dlp did not create the merged MP4",
				fmt.tprintf("Inspect the diagnostic log at %s", diagnostic_log_path("yt-dlp")),
			)
		} else if len(job.replace_video_id) > 0 && last_imported_source >= 0 {
			_ = notification_finish(
				job.notification_id,
				.Error,
				"Refetch failed",
				fmt.tprintf("Inspect the diagnostic log at %s", diagnostic_log_path("yt-dlp")),
			)
		} else {
			_ = notification_finish(
				job.notification_id,
				.Error,
				fmt.tprintf("Imported %d source(s); %d failed", job.accepted, job.failed),
				fmt.tprintf("Inspect the diagnostic log at %s", diagnostic_log_path("yt-dlp")),
			)
		}
	} else if job.has_source_update {
		if job.failed_exercise_refreshes > 0 {
			_ = notification_finish(
				job.notification_id,
				.Error,
				fmt.tprintf(
					"Refetched source; %d exercise rebuild(s) failed",
					job.failed_exercise_refreshes,
				),
				fmt.tprintf("Inspect the diagnostic log at %s", diagnostic_log_path("ffmpeg")),
			)
		} else {
			_ = notification_finish(
				job.notification_id,
				.Success,
				fmt.tprintf("Refetched source and rebuilt %d exercise(s)", job.refreshed_exercises),
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
	job.metadata, job.metadata_loaded = load_source_context_metadata(job.video_id)
	if file_info, stat_error := os.stat(job.media_path, context.temp_allocator); stat_error == nil {
		job.metadata.filesize_approx = file_info.size
	}
	msg_void_sel_id_b(job.completion_target, sel_registerName("performSelectorOnMainThread:withObject:waitUntilDone:"), sel_registerName("sourceMetadataFinished:"), nil, false)
}

request_source_metadata :: proc(video_id, media_path: string) {
	if source_metadata_job != nil {return}
	for source in state.sources {
		if source.video_id == video_id && source.metadata_status != .Missing {return}
	}
	job := new(Source_Metadata_Job)
	job.completion_target = state.delegate_target
	job.video_id = strings.clone(video_id)
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
			request_source_metadata(source.video_id, source.media_path)
			return
		}
	}
	for source in state.sources {
		if source.metadata_status == .Missing {
			request_source_metadata(source.video_id, source.media_path)
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
		if source.video_id != job.video_id || source.metadata_status != .Missing {continue}
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

source_index_for_video_id :: proc(sources: []Source_Video, video_id: string) -> int {
	for source, index in sources {
		if source.video_id == video_id {return index}
	}
	return -1
}

library_recovery_start_next :: proc() {
	if library_recovery == nil || import_job != nil {return}
	for library_recovery.next < len(library_recovery.entries) {
		entry_index := library_recovery.next
		entry := library_recovery.entries[entry_index]
		library_recovery.next += 1
		source_index := source_index_for_video_id(state.sources[:], entry.video_id)
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
		job := import_job_create(source.url, source.video_id)
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
		worker := thread.create(import_worker)
		if worker == nil {
			import_job_destroy(job)
			library_recovery.failed += 1
			continue
		}
		job.thread = worker
		worker.data = job
		import_job = job
		os.make_directory(app_support_dir())
		_ = os.write_entire_file(diagnostic_log_path("yt-dlp"), nil)
		_ = os.write_entire_file(diagnostic_log_path("ffmpeg"), nil)
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
		thread.start(worker)
		return
	}
	library_recovery_finish()
}

library_recovery_start :: proc() -> bool {
	if library_recovery != nil || import_job != nil {return false}
	if len(state.sources) == 0 {
		set_success_status("Library imported")
		return true
	}
	if !require_helper("yt-dlp") || !require_helper("ffmpeg") {return false}
	recovery := new(Library_Recovery)
	recovery.notification_id = notification_begin(
		"Library imported; preparing source recovery",
		"The imported library records are installed. Media validation and exercise recovery will now run sequentially.",
	)
	recovery.entries = make(
		[dynamic]Library_Recovery_Entry,
		0,
		len(state.sources),
	)
	for source in state.sources {
		append(
			&recovery.entries,
			Library_Recovery_Entry {
				video_id = strings.clone(source.video_id),
				height = source.metadata.height,
			},
		)
	}
	library_recovery = recovery
	library_recovery_start_next()
	return true
}

refetch_source :: proc(
	source_index: int,
	maximum_height := 0,
	auth_browser := Source_Auth_Browser.None,
) {
	if import_job != nil { set_text(state.status, "An import is already running"); return }
	if source_index < 0 || source_index >= len(state.sources) { set_text(state.status, "Select a source to refetch"); return }
	if !require_helper("yt-dlp") || !require_helper("ffmpeg") { return }
	source := &state.sources[source_index]
	job := import_job_create(source.url, source.video_id)
	if job == nil { set_text(state.status, "Unable to allocate import job"); return }
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
	worker := thread.create(import_worker)
	if worker == nil { import_job_destroy(job); set_text(state.status, "Unable to start import worker"); return }
	job.thread = worker
	worker.data = job
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
	import_job = job
	last_imported_source = source_index
	if state.active_source == source_index {metal_player_clear()}
	os.make_directory(app_support_dir())
	os.write_entire_file(diagnostic_log_path("yt-dlp"), nil)
	os.write_entire_file(diagnostic_log_path("ffmpeg"), nil)
	thread.start(worker)
}

on_refetch_source :: proc "c" (self: Id, command: Sel, sender: Id) {
	context = runtime.default_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	refetch_source(state.active_source)
}

on_import :: proc "c" (self: Id, command: Sel, sender: Id) {
	context = runtime.default_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	if import_job != nil { set_text(state.status, "An import is already running"); return }
	if !require_helper("yt-dlp") || !require_helper("ffmpeg") { return }
	input := strings.trim_space(field_text(state.url_input))
	if len(input) == 0 { set_text(state.status, "Paste at least one YouTube URL"); return }
	if source_probe_job != nil {set_text(state.status, "Wait for the metadata check to finish"); return}
	if !source_probe_ready(input) {
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
	job := import_job_create(input)
	if job == nil { set_text(state.status, "Unable to allocate import job"); return }
	worker := thread.create(import_worker)
	if worker == nil { import_job_destroy(job); set_text(state.status, "Unable to start import worker"); return }
	job.thread = worker
	worker.data = job
	summary := "Downloading video and YouTube captions..."
	detail := "The application downloads each selected source sequentially and validates the merged media before updating the library."
	if auth_browser := import_job_auth_browser(job); auth_browser != .None {
		browser_name := source_auth_browser_name(auth_browser)
		summary = fmt.tprintf(
			"Downloading with %s session...",
			browser_name,
		)
		detail = fmt.tprintf(
			"You selected %s. yt-dlp reads its YouTube session for this download. The application does not store or export browser cookies.",
			browser_name,
		)
	}
	job.notification_id = notification_begin(summary, detail)
	import_job = job
	os.make_directory(app_support_dir())
	os.write_entire_file(diagnostic_log_path("yt-dlp"), nil)
	thread.start(worker)
	close_source_modal()
}

on_set_start :: proc "c" (self: Id, command: Sel, sender: Id) {
	context = runtime.default_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	if seconds, ok := current_seconds(); ok {
		state.range_start, state.has_start = seconds, true
		set_text(state.status, fmt.tprintf("Start: %s", format_timestamp(seconds)))
	} else { set_text(state.status, "No active source player") }
}

on_set_end :: proc "c" (self: Id, command: Sel, sender: Id) {
	context = runtime.default_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	if seconds, ok := current_seconds(); ok {
		state.range_end, state.has_end = seconds, true
		set_text(state.status, fmt.tprintf("Range: %s - %s", format_timestamp(state.range_start), format_timestamp(seconds)))
	} else { set_text(state.status, "No active source player") }
}

reset_exercise_output :: proc() {
	state.range_start = 0
	state.range_end = 0
	state.has_start = false
	state.has_end = false
	ui_set_string(&ui.exercise_name, "")
	if ui.focus == .Exercise_Name {
		clear_marked_text()
		collapse_text_selection(0)
		ui.text_scroll_x = 0
	}
	ui.needs_redraw = true
}

on_save :: proc "c" (self: Id, command: Sel, sender: Id) {
	context = runtime.default_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	if export_job != nil { set_text(state.status, "A clip export is already running"); return }
	if !require_helper("ffmpeg") { return }
	if state.active_source < 0 || !state.has_start || !state.has_end || !valid_exercise_range(state.range_start, state.range_end, state.sources[state.active_source].duration) {
		set_text(state.status, "Select a source and mark a valid start/end range")
		return
	}
	source := &state.sources[state.active_source]
	number := 1
	for exercise in state.exercises { if exercise.source_id == source.id { number += 1 } }
	id := fmt.tprintf("%s-%d", source.video_id, number)
	name := fmt.tprintf("%s Exercise %d", source.title, number)
	entered := strings.trim_space(field_text(state.exercise_name_input))
	if len(entered) > 0 { name = entered }
	job := export_job_create(
		Exercise{id=id, source_id=source.id, name=name, start_seconds=state.range_start, end_seconds=state.range_end},
		source.media_path,
		.Save,
	)
	if job == nil { set_text(state.status, "Unable to allocate export job"); return }
	fields := [3]Notification_Field{
		{label="Operation", value="Save exercise"},
		{label="Source", value=source.title},
		{label="Range", value=fmt.tprintf("%s – %s", format_timestamp(state.range_start), format_timestamp(state.range_end))},
	}
	job.notification_id = notification_begin(
		"Exporting exercise clip...",
		"FFmpeg is encoding the selected source range as a standalone exercise clip.",
		fields[:],
	)
	export_job = job
	os.write_entire_file(diagnostic_log_path("ffmpeg"), nil)
	thread.start(job.thread)
}

on_play :: proc "c" (self: Id, command: Sel, sender: Id) {
	context = runtime.default_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	if state.player != nil {
		request_transcript_follow()
		msg_void_f32(state.player, sel_registerName("setRate:"), ui.playback_rate)
		metal_audio_play()
	}
}

on_pause :: proc "c" (self: Id, command: Sel, sender: Id) {
	context = runtime.default_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	if state.player != nil {
		msg_void(state.player, sel_registerName("pause"))
		metal_audio_pause()
	}
}

on_toggle_playback :: proc "c" (self: Id, command: Sel, event: Id) {
	context = runtime.default_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	if state.player == nil { return }
	if msg_f32(state.player, sel_registerName("rate")) > 0 {
		msg_void(state.player, sel_registerName("pause"))
		metal_audio_pause()
	} else {
		request_transcript_follow()
		msg_void_f32(state.player, sel_registerName("setRate:"), ui.playback_rate)
		metal_audio_play()
	}
}

on_preview :: proc "c" (self: Id, command: Sel, sender: Id) {
	context = runtime.default_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	if export_job != nil { set_text(state.status, "A clip export is already running"); return }
	if !require_helper("ffmpeg") { return }
	if state.active_source < 0 || !state.has_start || !state.has_end || !valid_exercise_range(state.range_start, state.range_end, state.sources[state.active_source].duration) {
		set_text(state.status, "Mark a valid start and end before previewing")
		return
	}
	source := &state.sources[state.active_source]
	job := export_job_create(
		Exercise{id="preview", source_id=source.id, name="Range Preview", start_seconds=state.range_start, end_seconds=state.range_end},
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
	export_job = job
	os.write_entire_file(diagnostic_log_path("ffmpeg"), nil)
	thread.start(job.thread)
}

export_job_destroy :: proc(job: ^Export_Job) {
	if job == nil { return }
	growing_arena_destroy(job.arena)
	free(job)
}

export_job_create :: proc(
	exercise: Exercise,
	source_path: string,
	operation: Export_Operation,
) -> ^Export_Job {
	arena, ok := growing_arena_create()
	if !ok { return nil }
	job := new(Export_Job)
	job.arena = arena
	job.completion_target = state.delegate_target
	allocator := mem_virtual.arena_allocator(arena)
	copy, copied := clone_exercise(exercise, allocator)
	if !copied { export_job_destroy(job); return nil }
	job.exercise = copy
	job.source_path = strings.clone(source_path, allocator)
	job.operation = operation
	worker := thread.create(export_worker)
	if worker == nil { export_job_destroy(job); return nil }
	job.thread = worker
	worker.data = job
	return job
}

export_worker :: proc(t: ^thread.Thread) {
	context = runtime.default_context()
	job := cast(^Export_Job)t.data
	job.success = export_exercise(&job.exercise, job.source_path, mem_virtual.arena_allocator(job.arena))
	msg_void_sel_id_b(job.completion_target, sel_registerName("performSelectorOnMainThread:withObject:waitUntilDone:"), sel_registerName("exportFinished:"), nil, false)
}

on_export_finished :: proc "c" (self: Id, command: Sel, sender: Id) {
	context = runtime.default_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	job := export_job
	if job == nil { return }
	thread.join(job.thread)
	thread.destroy(job.thread)
	job.thread = nil
	defer {
		export_job = nil
		export_job_destroy(job)
	}
	if !job.success {
		_ = notification_finish(
			job.notification_id,
			.Error,
			"FFmpeg failed",
			fmt.tprintf("Inspect the diagnostic log at %s", diagnostic_log_path("ffmpeg")),
		)
		return
	}
	if job.operation == .Preview {
		if !metal_player_load(job.exercise.clip_path) {
			_ = notification_finish(
				job.notification_id,
				.Error,
				"Unable to load the exported preview",
			)
			return
		}
		ui.player_duration = job.exercise.end_seconds - job.exercise.start_seconds
		set_source_playback_active(false)
		start_loaded_playback_at(0)
		_ = notification_finish(
			job.notification_id,
			.Success,
			fmt.tprintf(
				"Previewing %s",
				format_timestamp(job.exercise.end_seconds-job.exercise.start_seconds),
			),
		)
		return
	}
	if job.operation == .Repair {
		index := exercise_index_for_id(state.exercises[:], job.exercise.id)
		if index < 0 {
			_ = notification_finish(
				job.notification_id,
				.Error,
				"The rebuilt exercise is no longer in the library",
			)
			return
		}
		repaired, copied := clone_exercise(job.exercise)
		if !copied {
			_ = notification_finish(
				job.notification_id,
				.Error,
				"Unable to store the rebuilt exercise",
			)
			return
		}
		delete_exercise(&state.exercises[index])
		state.exercises[index] = repaired
		if !save_library() {
			_ = notification_finish(
				job.notification_id,
				.Error,
				"The clip was rebuilt, but the library update failed",
			)
			return
		}
		refresh_exercises()
		if !metal_player_load(repaired.clip_path) {
			_ = notification_finish(
				job.notification_id,
				.Error,
				"The clip was rebuilt, but it could not be loaded",
			)
			return
		}
		ui.player_duration = repaired.end_seconds - repaired.start_seconds
		set_source_playback_active(false)
		start_loaded_playback_at(0)
		ui.active_exercise = index
		_ = notification_finish(
			job.notification_id,
			.Success,
			fmt.tprintf("Rebuilt and playing %s", repaired.name),
		)
		return
	}
	exercise, copied := clone_exercise(job.exercise)
	if !copied {
		_ = notification_finish(
			job.notification_id,
			.Error,
			"Unable to store exported exercise",
		)
		return
	}
	append(&state.exercises, exercise)
	if !save_library() {
		stored := pop(&state.exercises)
		delete_exercise(&stored)
		_ = os.remove(job.exercise.clip_path)
		_ = notification_finish(
			job.notification_id,
			.Error,
			"The clip was created, but the library update failed",
		)
		return
	}
	reset_exercise_output()
	refresh_exercises()
	_ = notification_finish(
		job.notification_id,
		.Success,
		fmt.tprintf(
			"Saved %s (%s)",
			job.exercise.name,
			format_timestamp(job.exercise.end_seconds-job.exercise.start_seconds),
		),
	)
}

on_select_source :: proc "c" (self: Id, command: Sel, sender: Id) {
	context = runtime.default_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	index := ui_event_tag
	if sender != nil { index = int(msg_uint(sender, sel_registerName("tag"))) }
	if index < 0 || index >= len(state.sources) { return }
	if load_source_player(index) {
		ui.active_exercise = -1
		set_text(state.status, fmt.tprintf("Loaded %s", state.sources[index].title))
	} else {
		source := &state.sources[index]
		if !source.media_available {
			set_text(state.status, "MEDIA MISSING / The merged MP4 was not created. Right-click this source and refetch it.")
		} else {
			set_text(state.status, "VIDEO INVALID / The MP4 does not contain decodable H.264 video and AAC audio. Right-click this source and refetch it.")
		}
	}
}

on_play_exercise :: proc "c" (self: Id, command: Sel, sender: Id) {
	context = runtime.default_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	index := ui_event_tag
	if sender != nil { index = int(msg_uint(sender, sel_registerName("tag"))) }
	if index < 0 || index >= len(state.exercises) { return }
	exercise := &state.exercises[index]
	if !os.exists(exercise.clip_path) {
		if export_job != nil {
			set_text(state.status, "Wait for the active clip export to finish")
			return
		}
		source_index := source_index_for_id(state.sources[:], exercise.source_id)
		if source_index < 0 {
			set_text(state.status, "The original source is no longer in the library")
			return
		}
		source := &state.sources[source_index]
		if !source.media_available || !os.exists(source.media_path) {
			set_text(state.status, "The original source file is missing. Refetch the source before rebuilding this exercise.")
			return
		}
		if !valid_exercise_range(exercise.start_seconds, exercise.end_seconds, source.duration) {
			set_text(state.status, "The saved exercise range is not valid for its source")
			return
		}
		if !require_helper("ffmpeg") {return}
		job := export_job_create(exercise^, source.media_path, .Repair)
		if job == nil {
			set_text(state.status, "Unable to allocate the exercise rebuild job")
			return
		}
		fields := [2]Notification_Field{
			{label="Operation", value="Rebuild exercise"},
			{label="Exercise", value=exercise.name},
		}
		job.notification_id = notification_begin(
			fmt.tprintf("Rebuilding missing clip for %s...", exercise.name),
			"FFmpeg is recreating the saved exercise from its original source range.",
			fields[:],
		)
		export_job = job
		os.write_entire_file(diagnostic_log_path("ffmpeg"), nil)
		thread.start(job.thread)
		return
	}
	if !metal_player_load(exercise.clip_path) {
		set_text(state.status, "Unable to load the selected exercise")
		return
	}
	ui.player_duration = exercise.end_seconds - exercise.start_seconds
	set_source_playback_active(false)
	start_loaded_playback_at(0)
	ui.active_exercise = index
	set_text(state.status, fmt.tprintf("Playing %s", exercise.name))
}

on_filter_lists :: proc "c" (self: Id, command: Sel, sender: Id) {
	context = runtime.default_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	refresh_sources()
	refresh_exercises()
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
	return import_job != nil ||
	       export_job != nil ||
	       source_probe_job != nil ||
	       source_metadata_job != nil ||
	       library_recovery != nil
}

library_panel_path :: proc(save: bool) -> (string, bool) {
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
		msg_void_id(
			panel,
			sel_registerName("setNameFieldStringValue:"),
			nsstring("Vocal Training Library.vocaltraining.json"),
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

export_library_with_panel :: proc() {
	if library_transfer_busy() {
		set_error_status("Wait for the active media or metadata operation")
		return
	}
	path, selected := library_panel_path(true)
	if !selected {return}
	defer delete(path)
	if export_error := portable_library_export(path); export_error != .None {
		set_error_status(portable_library_error_text(export_error))
		return
	}
	set_success_status(fmt.tprintf("Exported library metadata to %s", filepath.base(path)))
	close_data_modal()
}

prepare_library_import_with_panel :: proc() {
	if library_transfer_busy() {
		set_error_status("Wait for the active media or metadata operation")
		return
	}
	path, selected := library_panel_path(false)
	if !selected {return}
	defer delete(path)
	imported, import_error := portable_library_read(path)
	if import_error != .None {
		set_error_status(portable_library_error_text(import_error))
		return
	}
	app_state_collections_destroy(&pending_library_import)
	pending_library_import = imported
	ui.library_import_confirm_open = true
	ui.library_import_pending = true
	ui.needs_redraw = true
}

confirm_library_import :: proc() {
	if library_transfer_busy() {
		set_error_status("Wait for the active media or metadata operation")
		return
	}
	metal_player_clear()
	if install_error := portable_library_install(&pending_library_import);
	   install_error != .None {
		set_error_status(portable_library_error_text(install_error))
		return
	}
	state.active_source = -1
	state.has_start = false
	state.has_end = false
	ui.active_exercise = -1
	ui.source_scroll = 0
	ui.transcript_scroll = 0
	ui.exercise_scroll = 0
	ui.data_modal_open = false
	ui.library_import_confirm_open = false
	ui.library_import_pending = false
	ui.source_playback_active = false
	refresh_sources()
	refresh_exercises()
	_ = library_recovery_start()
}

jobs_shutdown :: proc() {
	if source_probe_job != nil {
		if source_probe_job.thread != nil {
			thread.join(source_probe_job.thread)
			thread.destroy(source_probe_job.thread)
			source_probe_job.thread = nil
		}
		source_probe_job_destroy(source_probe_job)
		source_probe_job = nil
	}
	if source_metadata_job != nil {
		if source_metadata_job.thread != nil {
			thread.join(source_metadata_job.thread)
			thread.destroy(source_metadata_job.thread)
			source_metadata_job.thread = nil
		}
		source_metadata_job_destroy(source_metadata_job)
		source_metadata_job = nil
	}
	if import_job != nil {
		import_job_cancel(import_job)
		if import_job.thread != nil {
			thread.join(import_job.thread)
			thread.destroy(import_job.thread)
			import_job.thread = nil
		}
		import_job_destroy(import_job)
		import_job = nil
	}
	library_recovery_destroy()
	if export_job != nil {
		if export_job.thread != nil {
			thread.join(export_job.thread)
			thread.destroy(export_job.thread)
			export_job.thread = nil
		}
		export_job_destroy(export_job)
		export_job = nil
	}
}

main :: proc() {
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
	defer source_probe_results_clear()
	defer source_probe_cache_clear()
	defer database_close()
	defer jobs_shutdown()
	defer cli_ipc_server_stop()
	configure_helper_path()
	objc_handle := os.dlopen("/usr/lib/libobjc.A.dylib", os.RTLD_NOW)
	send_address = os.dlsym(objc_handle, "objc_msgSend")
	if send_address == nil { fmt.eprintln("Unable to resolve objc_msgSend"); return }
	defer ui_memory_destroy()
	libsystem_handle := os.dlopen("/usr/lib/libSystem.B.dylib", os.RTLD_NOW)
	system_address = os.dlsym(libsystem_handle, "system")
	if system_address == nil { fmt.eprintln("Unable to resolve system"); return }
	state.active_source = -1
	if len(os.args) > 1 {
		request, parse_result, parsed := cli_parse_request(os.args[1:])
		result := parse_result
		if parsed {
			if routed_result, routed := cli_ipc_try_request(request); routed {
				result = routed_result
			} else if cli_command_requires_gui(request.command) {
				result = cli_error(request.command, .Busy, "gui_not_running", "The UI command requires a running application")
			} else if !cli_library_try_acquire() {
				result = cli_error(request.command, .Busy, "busy", "The app owns the library, but its CLI control socket is not ready")
			} else {
				load_library()
				result = cli_execute(request)
			}
		}
		fmt.println(result.output)
		delete(result.output)
		os.exit(int(result.exit_code))
	}
	if !cli_library_try_acquire() {
		fmt.eprintln("Vocal Training is already running or the library is busy")
		return
	}
	load_library()
	notification_history_initialize()
	defer notification_history_destroy()
	pool := msg_id(objc_getClass("NSAutoreleasePool"), sel_registerName("new"))
	build_metal_window()
	metal_player_clear()
	msg_void(pool, sel_registerName("drain"))
}
