package main

import "core:fmt"
import "core:os"
import os2 "core:os/os2"
import "core:path/filepath"
import "core:strings"
import "core:thread"
import "base:runtime"
import mem_virtual "core:mem/virtual"

Id  :: rawptr
Sel :: rawptr

foreign import objc "system:objc"
foreign objc {
	objc_getClass           :: proc "c" (name: cstring) -> Id ---
	sel_registerName        :: proc "c" (name: cstring) -> Sel ---
	objc_allocateClassPair  :: proc "c" (superclass: Id, name: cstring, extra: uint) -> Id ---
	objc_registerClassPair  :: proc "c" (cls: Id) ---
	class_addMethod         :: proc "c" (cls: Id, name: Sel, imp: rawptr, types: cstring) -> bool ---
}

foreign import libc "system:System.framework"
foreign libc {
	getenv :: proc "c" (name: cstring) -> cstring ---
}

Point :: struct { x, y: f64 }
Size  :: struct { width, height: f64 }
Rect  :: struct { origin: Point, size: Size }
CMTime :: struct { value: i64, timescale: i32, flags: u32, epoch: i64 }

Source_Video :: struct {
	id: string,
	video_id: string,
	title: string,
	url: string,
	media_path: string,
	duration: f64,
}

Transcript_Segment :: struct {
	id: string,
	source_id: string,
	start_seconds: f64,
	duration_seconds: f64,
	text: string,
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
	refreshed_exercises: int,
	failed_exercise_refreshes: int,
}

Export_Job :: struct {
	thread: ^thread.Thread,
	completion_target: Id,
	arena: ^mem_virtual.Arena,
	exercise: Exercise,
	source_path: string,
	preview: bool,
	success: bool,
}

import_job: ^Import_Job
export_job: ^Export_Job

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
		ui_set_string(&ui.status, text)
		ui.needs_redraw = true
		return
	}
	if control == state.exercise_name_input {
		ui_set_string(&ui.exercise_name, text)
		ui.needs_redraw = true
		return
	}
	msg_void_id(control, sel_registerName("setStringValue:"), nsstring(text))
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
	home := getenv("HOME")
	return fmt.tprintf("%s/Library/Application Support/VocalTraining", string(home))
}

diagnostic_log_path :: proc(name: string) -> string {
	return fmt.tprintf("%s/%s.log", app_support_dir(), name)
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
	id_copy := strings.clone(video_id)
	url_copy := strings.clone(url)
	append(&state.sources, Source_Video{id=id_copy, video_id=strings.clone(video_id), title=strings.clone(video_id), url=url_copy, media_path=fmt.aprintf("%s/sources/%s.mp4", dir, video_id)})
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

require_helper :: proc(name: string) -> bool {
	available, reason := helper_available(name)
	if available { return true }
	set_text(state.status, reason)
	return false
}

validate_startup_helpers :: proc() {
	yt_dlp_available, yt_dlp_reason := helper_available("yt-dlp")
	ffmpeg_available, ffmpeg_reason := helper_available("ffmpeg")
	if yt_dlp_available && ffmpeg_available { return }

	message := "Vocal Training checked its media helpers before starting."
	if !yt_dlp_available {
		message = fmt.tprintf("%s\n\n%s. YouTube import and refetch are unavailable.", message, yt_dlp_reason)
	}
	if !ffmpeg_available {
		message = fmt.tprintf("%s\n\n%s. Import, refetch, preview, and exercise export are unavailable.", message, ffmpeg_reason)
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
	return start >= 0 && end > start && (source_duration <= 0 || end <= source_duration)
}

seek_seconds :: proc(seconds: f64) {
	if state.player == nil { return }
	t := CMTime{value=i64(seconds*600), timescale=600, flags=1}
	msg_void_time(state.player, sel_registerName("seekToTime:"), t)
}

load_source_player :: proc(index: int) -> bool {
	if index < 0 || index >= len(state.sources) { return false }
	path := state.sources[index].media_path
	if !metal_player_load(path) { return false }
	state.active_source = index
	state.has_start, state.has_end = false, false
	set_text(state.exercise_name_input, "")
	if state.has_pending_hint {
		seek_seconds(state.pending_hint)
		state.has_pending_hint = false
	} else {
		for i := len(state.hints)-1; i >= 0; i -= 1 {
			if state.hints[i].source_id == state.sources[index].id { seek_seconds(state.hints[i].seconds); break }
		}
	}
	refresh_transcript()
	return true
}

refresh_transcript :: proc() {
	ui.transcript_scroll = 0
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

import_job_add_hint :: proc(job: ^Import_Job, source_id: string, seconds: f64) {
	if import_job_has_hint(job, source_id, seconds) { return }
	allocator := mem_virtual.arena_allocator(job.arena)
	append(&job.new_hints, Import_Hint{source_id=strings.clone(source_id, allocator), seconds=seconds})
	job.pending_hint, job.has_pending_hint = seconds, true
}

import_job_process_url :: proc(job: ^Import_Job, url: string) -> bool {
	video_id, valid := parse_video_id(url)
	if !valid { return false }
	allocator := mem_virtual.arena_allocator(job.arena)
	job.last_video_id = strings.clone(video_id, allocator)
	if source := import_job_find_source(job, video_id); source != nil {
		if video_id != job.replace_video_id {
			if seconds, has_time := parse_timestamp(url); has_time { import_job_add_hint(job, source.id, seconds) }
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
	if run(c_command) != 0 { return false }

	existing := import_job_find_source(job, video_id)
	source_id := video_id
	if existing != nil { source_id = existing.id }
	source := Source_Video{
		id=strings.clone(source_id, allocator),
		video_id=strings.clone(video_id, allocator),
		title=strings.clone(video_id, allocator),
		url=strings.clone(url, allocator),
		media_path=fmt.aprintf("%s/sources/%s.mp4", dir, video_id, allocator=allocator),
	}
	if metadata, loaded := load_download_metadata(video_id, allocator); loaded {
		source.title = metadata.title
		source.duration = metadata.duration
	}
	if existing != nil {
		job.updated_source = source
		job.has_source_update = true
	} else {
		append(&job.new_sources, source)
	}
	if seconds, has_time := parse_timestamp(url); has_time { import_job_add_hint(job, source.id, seconds) }

	previous := job.snapshot_transcripts.segments[:]
	if job.has_transcript_update { previous = job.transcripts.segments[:] }
	if next, _, loaded := build_transcript_generation(&source, previous); loaded {
		transcript_generation_destroy(&job.transcripts)
		job.transcripts = next
		job.has_transcript_update = true
	}
	if existing != nil {
		for exercise in job.exercises {
			if exercise.source_id != source.id || len(exercise.clip_path) == 0 { continue }
			command := clip_export_command(source.media_path, exercise.clip_path, exercise.start_seconds, exercise.end_seconds)
			c_command := strings.clone_to_cstring(command)
			result := run(c_command)
			delete(c_command)
			if result == 0 { job.refreshed_exercises += 1 } else { job.failed_exercise_refreshes += 1 }
		}
	}
	return true
}

import_worker :: proc(t: ^thread.Thread) {
	context = runtime.default_context()
	job := cast(^Import_Job)t.data
	for raw in strings.split_lines(job.input) {
		url := strings.trim_space(raw)
		if len(url) == 0 { continue }
		if import_job_process_url(job, url) { job.accepted += 1 } else { job.failed += 1 }
	}
	msg_void_sel_id_b(job.completion_target, sel_registerName("performSelectorOnMainThread:withObject:waitUntilDone:"), sel_registerName("importFinished:"), nil, false)
}

on_import_finished :: proc "c" (self: Id, command: Sel, sender: Id) {
	context = runtime.default_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	job := import_job
	if job == nil { return }
	thread.join(job.thread)
	thread.destroy(job.thread)
	job.thread = nil
	defer {
		import_job = nil
		import_job_destroy(job)
	}
	if job.accepted > 0 {
		if job.has_source_update {
			for &source, index in state.sources {
				if source.video_id != job.updated_source.video_id { continue }
				copy, copied := clone_source_video(job.updated_source)
				if copied {
					delete_source_video(&source)
					source = copy
					last_imported_source = index
				}
				break
			}
		}
		for source in job.new_sources {
			copy, copied := clone_source_video(source)
			if copied { append(&state.sources, copy) }
		}
		for hint in job.new_hints {
			copy, copied := clone_import_hint(hint)
			if copied { append(&state.hints, copy) }
		}
		if job.has_transcript_update {
			install_transcript_generation(job.transcripts)
			job.transcripts = {}
		}
		for source, index in state.sources {
			if source.video_id == job.last_video_id { last_imported_source = index; break }
		}
		if job.has_pending_hint {
			state.pending_hint, state.has_pending_hint = job.pending_hint, true
		}
		if last_imported_source >= 0 { load_source_player(last_imported_source) }
		save_library()
		refresh_sources()
	}
	if job.failed > 0 {
		if len(job.replace_video_id) > 0 && last_imported_source >= 0 {
			load_source_player(last_imported_source)
			set_text(state.status, fmt.tprintf("Refetch failed. Log: %s", diagnostic_log_path("yt-dlp")))
		} else {
			set_text(state.status, fmt.tprintf("Imported %d; %d failed. Log: %s", job.accepted, job.failed, diagnostic_log_path("yt-dlp")))
		}
	} else if job.has_source_update {
		if job.failed_exercise_refreshes > 0 {
			set_text(state.status, fmt.tprintf("Refetched source; %d exercise rebuild(s) failed. Log: %s", job.failed_exercise_refreshes, diagnostic_log_path("ffmpeg")))
		} else {
			set_text(state.status, fmt.tprintf("Refetched source and rebuilt %d exercise(s) at the best available quality", job.refreshed_exercises))
		}
	} else {
		set_text(state.status, fmt.tprintf("Imported %d source(s)", job.accepted))
	}
}

on_refetch_source :: proc "c" (self: Id, command: Sel, sender: Id) {
	context = runtime.default_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	if import_job != nil { set_text(state.status, "An import is already running"); return }
	if state.active_source < 0 || state.active_source >= len(state.sources) { set_text(state.status, "Select a source to refetch"); return }
	if !require_helper("yt-dlp") || !require_helper("ffmpeg") { return }
	source := &state.sources[state.active_source]
	job := import_job_create(source.url, source.video_id)
	if job == nil { set_text(state.status, "Unable to allocate import job"); return }
	worker := thread.create(import_worker)
	if worker == nil { import_job_destroy(job); set_text(state.status, "Unable to start import worker"); return }
	job.thread = worker
	worker.data = job
	import_job = job
	last_imported_source = state.active_source
	metal_player_clear()
	os.make_directory(app_support_dir())
	os.write_entire_file(diagnostic_log_path("yt-dlp"), nil)
	os.write_entire_file(diagnostic_log_path("ffmpeg"), nil)
	set_text(state.status, "Refetching the selected source at the best available quality...")
	thread.start(worker)
}

on_import :: proc "c" (self: Id, command: Sel, sender: Id) {
	context = runtime.default_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	if import_job != nil { set_text(state.status, "An import is already running"); return }
	if !require_helper("yt-dlp") || !require_helper("ffmpeg") { return }
	input := strings.trim_space(field_text(state.url_input))
	if len(input) == 0 { set_text(state.status, "Paste at least one YouTube URL"); return }
	job := import_job_create(input)
	if job == nil { set_text(state.status, "Unable to allocate import job"); return }
	worker := thread.create(import_worker)
	if worker == nil { import_job_destroy(job); set_text(state.status, "Unable to start import worker"); return }
	job.thread = worker
	worker.data = job
	import_job = job
	os.make_directory(app_support_dir())
	os.write_entire_file(diagnostic_log_path("yt-dlp"), nil)
	set_text(state.status, "Downloading video and YouTube captions...")
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
	job := export_job_create(Exercise{id=id, source_id=source.id, name=name, start_seconds=state.range_start, end_seconds=state.range_end}, source.media_path, false)
	if job == nil { set_text(state.status, "Unable to allocate export job"); return }
	export_job = job
	os.write_entire_file(diagnostic_log_path("ffmpeg"), nil)
	set_text(state.status, "Exporting exercise clip...")
	thread.start(job.thread)
}

on_play :: proc "c" (self: Id, command: Sel, sender: Id) {
	context = runtime.default_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	if state.player != nil { msg_void(state.player, sel_registerName("play")) }
}

on_pause :: proc "c" (self: Id, command: Sel, sender: Id) {
	context = runtime.default_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	if state.player != nil { msg_void(state.player, sel_registerName("pause")) }
}

on_toggle_playback :: proc "c" (self: Id, command: Sel, event: Id) {
	context = runtime.default_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	if state.player == nil { return }
	if msg_f32(state.player, sel_registerName("rate")) > 0 {
		msg_void(state.player, sel_registerName("pause"))
	} else {
		msg_void(state.player, sel_registerName("play"))
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
	job := export_job_create(Exercise{id="preview", source_id=source.id, name="Range Preview", start_seconds=state.range_start, end_seconds=state.range_end}, source.media_path, true)
	if job == nil { set_text(state.status, "Unable to allocate preview job"); return }
	export_job = job
	os.write_entire_file(diagnostic_log_path("ffmpeg"), nil)
	set_text(state.status, "Preparing range preview...")
	thread.start(job.thread)
}

export_job_destroy :: proc(job: ^Export_Job) {
	if job == nil { return }
	growing_arena_destroy(job.arena)
	free(job)
}

export_job_create :: proc(exercise: Exercise, source_path: string, preview: bool) -> ^Export_Job {
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
	job.preview = preview
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
	if !job.success { set_text(state.status, fmt.tprintf("ffmpeg failed; details: %s", diagnostic_log_path("ffmpeg"))); return }
	if job.preview {
		if !metal_player_load(job.exercise.clip_path) {
			set_text(state.status, "Unable to load the exported preview")
			return
		}
		msg_void(state.player, sel_registerName("play"))
		set_text(state.status, fmt.tprintf("Previewing %s", format_timestamp(job.exercise.end_seconds-job.exercise.start_seconds)))
		return
	}
	exercise, copied := clone_exercise(job.exercise)
	if !copied { set_text(state.status, "Unable to store exported exercise"); return }
	append(&state.exercises, exercise)
	save_library()
	refresh_exercises()
	set_text(state.status, fmt.tprintf("Saved %s (%s)", job.exercise.name, format_timestamp(job.exercise.end_seconds-job.exercise.start_seconds)))
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
		set_text(state.status, "Unable to load the selected source")
	}
}

on_play_exercise :: proc "c" (self: Id, command: Sel, sender: Id) {
	context = runtime.default_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	index := ui_event_tag
	if sender != nil { index = int(msg_uint(sender, sel_registerName("tag"))) }
	if index < 0 || index >= len(state.exercises) { return }
	exercise := &state.exercises[index]
	if !os.exists(exercise.clip_path) { set_text(state.status, "The exported clip file is missing"); return }
	if !metal_player_load(exercise.clip_path) {
		set_text(state.status, "Unable to load the selected exercise")
		return
	}
	msg_void(state.player, sel_registerName("play"))
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

jobs_shutdown :: proc() {
	if import_job != nil {
		if import_job.thread != nil {
			thread.join(import_job.thread)
			thread.destroy(import_job.thread)
			import_job.thread = nil
		}
		import_job_destroy(import_job)
		import_job = nil
	}
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
	defer app_state_memory_destroy()
	defer jobs_shutdown()
	configure_helper_path()
	objc_handle := os.dlopen("/usr/lib/libobjc.A.dylib", os.RTLD_NOW)
	send_address = os.dlsym(objc_handle, "objc_msgSend")
	if send_address == nil { fmt.eprintln("Unable to resolve objc_msgSend"); return }
	defer ui_memory_destroy()
	libsystem_handle := os.dlopen("/usr/lib/libSystem.B.dylib", os.RTLD_NOW)
	system_address = os.dlsym(libsystem_handle, "system")
	if system_address == nil { fmt.eprintln("Unable to resolve system"); return }
	state.active_source = -1
	load_library()
	if len(os.args) == 3 && os.args[1] == "--import" {
		yt_dlp_available, yt_dlp_reason := helper_available("yt-dlp")
		if !yt_dlp_available { fmt.eprintln(yt_dlp_reason); return }
		ffmpeg_available, ffmpeg_reason := helper_available("ffmpeg")
		if !ffmpeg_available { fmt.eprintln(ffmpeg_reason); return }
		if import_url(os.args[2]) && save_library() {
			fmt.println("Imported source, YouTube captions, and timestamp hint")
			return
		}
		fmt.eprintln("Import failed; inspect", diagnostic_log_path("yt-dlp"))
		return
	}
	pool := msg_id(objc_getClass("NSAutoreleasePool"), sel_registerName("new"))
	build_metal_window()
	metal_player_clear()
	msg_void(pool, sel_registerName("drain"))
}
