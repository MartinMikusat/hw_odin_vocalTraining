package main

import "core:math"
import os "core:os/old"
import "core:strings"
import "base:runtime"
import task_queue "task_queue:."

WAVEFORM_CACHE_LIMIT :: 8
WAVEFORM_MIN_VIEW_SECONDS :: 2.0

Waveform_State :: enum {
	Idle,
	Loading,
	Ready,
	No_Audio,
	Unavailable,
}

Waveform_Peak :: struct {
	minimum: f32,
	maximum: f32,
}

Waveform_Band :: enum {
	Low,
	Mid,
	High,
}

Waveform_Band_View :: enum {
	All,
	Low,
	Mid,
	High,
}

Waveform_Band_Peak :: struct {
	low: Waveform_Peak,
	mid: Waveform_Peak,
	high: Waveform_Peak,
}

#assert(size_of(Waveform_Band_Peak) == size_of(f32)*6)
#assert(align_of(Waveform_Band_Peak) == align_of(f32))

Waveform_Cache_Entry :: struct {
	path: string,
	peaks: []Waveform_Band_Peak,
	rate_hz: f64,
	last_used: u64,
}

Waveform_Runtime :: struct {
	path: string,
	state: Waveform_State,
	view_start_seconds: f64,
	view_end_seconds: f64,
	view_initialized: bool,
	use_counter: u64,
	band_view: Waveform_Band_View,
}

Waveform_Job :: struct {
	task_id: task_queue.Task_ID,
	completion_target: Id,
	path: string,
	cancellation: BPM_Cancellation_Token,
	status: BPM_Analysis_Status,
	peaks: [^]Waveform_Band_Peak,
	count: uint,
	rate_hz: f64,
	completion: Media_Task_Completion,
}

waveform_runtime: Waveform_Runtime
waveform_cache: [dynamic]Waveform_Cache_Entry
waveform_job: ^Waveform_Job

waveform_cache_entry_destroy :: proc(entry: ^Waveform_Cache_Entry) {
	if entry == nil {return}
	delete(entry.path)
	delete(entry.peaks)
	entry^ = {}
}

waveform_cache_destroy :: proc() {
	for &entry in waveform_cache {waveform_cache_entry_destroy(&entry)}
	delete(waveform_cache)
	waveform_cache = nil
}

waveform_cache_index :: proc(path: string) -> int {
	for entry, index in waveform_cache {
		if entry.path == path {return index}
	}
	return -1
}

waveform_cache_touch :: proc(index: int) {
	if index < 0 || index >= len(waveform_cache) {return}
	waveform_runtime.use_counter += 1
	waveform_cache[index].last_used = waveform_runtime.use_counter
}

waveform_cache_active :: proc() -> ^Waveform_Cache_Entry {
	if waveform_runtime.state != .Ready {return nil}
	index := waveform_cache_index(waveform_runtime.path)
	if index < 0 {return nil}
	return &waveform_cache[index]
}

waveform_cache_store :: proc(
	path: string,
	values: [^]Waveform_Band_Peak,
	count: uint,
	rate_hz: f64,
) -> bool {
	if len(path) == 0 || values == nil || count == 0 || rate_hz <= 0 {
		return false
	}
	peaks, allocation_error := make([]Waveform_Band_Peak, int(count))
	if allocation_error != nil {return false}
	for index in 0 ..< int(count) {
		peaks[index] = values[index]
	}
	path_copy, path_error := strings.clone(path)
	if path_error != nil {delete(peaks); return false}
	if existing := waveform_cache_index(path); existing >= 0 {
		waveform_cache_entry_destroy(&waveform_cache[existing])
		ordered_remove(&waveform_cache, existing)
	}
	if len(waveform_cache) >= WAVEFORM_CACHE_LIMIT {
		evict := 0
		for entry, index in waveform_cache {
			if entry.last_used < waveform_cache[evict].last_used {evict = index}
		}
		waveform_cache_entry_destroy(&waveform_cache[evict])
		ordered_remove(&waveform_cache, evict)
	}
	waveform_runtime.use_counter += 1
	append(&waveform_cache, Waveform_Cache_Entry{
		path = path_copy,
		peaks = peaks,
		rate_hz = rate_hz,
		last_used = waveform_runtime.use_counter,
	})
	return true
}

waveform_job_destroy :: proc(job: ^Waveform_Job) {
	if job == nil {return}
	delete(job.path)
	if job.peaks != nil {hw_waveform_free_peaks(job.peaks)}
	free(job)
}

waveform_job_create :: proc(path: string, target: Id) -> (^Waveform_Job, bool) {
	job := new(Waveform_Job)
	job.completion_target = target
	hw_bpm_cancellation_token_init(&job.cancellation)
	value, error := strings.clone(path)
	if error != nil {free(job); return nil, false}
	job.path = value
	return job, true
}

waveform_job_cancel :: proc(job: ^Waveform_Job) {
	if job != nil {hw_bpm_cancellation_token_cancel(&job.cancellation)}
}

waveform_job_execute :: proc(job: ^Waveform_Job) {
	if job == nil {return}
	path := strings.clone_to_cstring(job.path)
	defer delete(path)
	job.status = hw_waveform_copy_peaks(
		path,
		&job.cancellation,
		&job.peaks,
		&job.count,
		&job.rate_hz,
	)
}

waveform_view_reset :: proc(duration: f64) {
	waveform_runtime.view_start_seconds = 0
	waveform_runtime.view_end_seconds = max(0, duration)
	waveform_runtime.view_initialized = duration > 0
}

waveform_view_range :: proc(duration: f64) -> (f64, f64) {
	if duration <= 0 {return 0, 0}
	if !waveform_runtime.view_initialized ||
	   waveform_runtime.view_end_seconds <= waveform_runtime.view_start_seconds {
		return 0, duration
	}
	span := clamp(
		waveform_runtime.view_end_seconds-waveform_runtime.view_start_seconds,
		min(WAVEFORM_MIN_VIEW_SECONDS, duration),
		duration,
	)
	start := clamp(waveform_runtime.view_start_seconds, 0, duration-span)
	return start, start+span
}

waveform_view_zoom :: proc(pointer_ratio, scale, duration: f64) {
	if duration <= 0 || scale <= 0 {return}
	start, end := waveform_view_range(duration)
	span := end-start
	minimum := min(WAVEFORM_MIN_VIEW_SECONDS, duration)
	next_span := clamp(span*scale, minimum, duration)
	ratio := clamp(pointer_ratio, 0, 1)
	anchor := start+span*ratio
	next_start := clamp(anchor-next_span*ratio, 0, duration-next_span)
	waveform_runtime.view_start_seconds = next_start
	waveform_runtime.view_end_seconds = next_start+next_span
	waveform_runtime.view_initialized = true
}

waveform_view_pan :: proc(delta_ratio, duration: f64) {
	if duration <= 0 {return}
	start, end := waveform_view_range(duration)
	span := end-start
	next_start := clamp(start+delta_ratio*span, 0, duration-span)
	waveform_runtime.view_start_seconds = next_start
	waveform_runtime.view_end_seconds = next_start+span
	waveform_runtime.view_initialized = true
}

waveform_seconds_at_point :: proc(
	point: Point,
	rect: UI_Rect,
	duration: f64,
) -> f64 {
	if rect.w <= 0 || duration <= 0 {return 0}
	start, end := waveform_view_range(duration)
	ratio := clamp((point.x-rect.x)/rect.w, 0, 1)
	return start+(end-start)*ratio
}

waveform_first_beat_index :: proc(
	view_start, offset, period: f64,
) -> int {
	if period <= 0 {return 0}
	return int(math.ceil((view_start-offset)/period))
}

waveform_beat_is_downbeat :: proc(index: int) -> bool {
	return ((index % 4) + 4) % 4 == 0
}

waveform_peak_for_band :: proc(
	peak: Waveform_Band_Peak,
	band: Waveform_Band,
) -> Waveform_Peak {
	switch band {
	case .Low: return peak.low
	case .Mid: return peak.mid
	case .High: return peak.high
	}
	return {}
}

waveform_shared_peak_magnitude :: proc(peaks: []Waveform_Band_Peak) -> f64 {
	largest := f64(0.05)
	for band_peak in peaks {
		for band in Waveform_Band {
			peak := waveform_peak_for_band(band_peak, band)
			largest = max(
				largest,
				abs(f64(peak.minimum)),
				abs(f64(peak.maximum)),
			)
		}
	}
	return largest
}

waveform_band_visible :: proc(
	view: Waveform_Band_View,
	band: Waveform_Band,
) -> bool {
	if view == .All {return true}
	return (view == .Low && band == .Low) ||
	       (view == .Mid && band == .Mid) ||
	       (view == .High && band == .High)
}

waveform_set_band_view :: proc(view: Waveform_Band_View) -> bool {
	if waveform_runtime.band_view == view {return true}
	if !database_waveform_band_view_save(library_database, view) {
		set_error_status("Unable to save the waveform frequency view")
		return false
	}
	waveform_runtime.band_view = view
	ui.needs_redraw = true
	return true
}

waveform_runtime_set_path :: proc(path: string, state_value: Waveform_State) -> bool {
	copy, error := strings.clone(path)
	if error != nil {return false}
	delete(waveform_runtime.path)
	waveform_runtime.path = copy
	waveform_runtime.state = state_value
	waveform_runtime.view_initialized = false
	waveform_runtime.view_start_seconds = 0
	waveform_runtime.view_end_seconds = 0
	return true
}

waveform_request :: proc(path: string, has_audio: bool) {
	if waveform_job != nil && waveform_job.path != path {
		_ = media_queue_cancel_waveform(waveform_job)
	}
	if !has_audio {
		_ = waveform_runtime_set_path(path, .No_Audio)
		return
	}
	if index := waveform_cache_index(path); index >= 0 {
		_ = waveform_runtime_set_path(path, .Ready)
		waveform_cache_touch(index)
		return
	}
	_ = waveform_runtime_set_path(path, .Loading)
	if len(path) == 0 || !os.exists(path) {
		waveform_runtime.state = .Unavailable
		return
	}
	if waveform_job != nil {return}
	job, created := waveform_job_create(path, state.delegate_target)
	if !created {waveform_runtime.state = .Unavailable; return}
	waveform_job = job
	if !media_queue_schedule_waveform(job) {
		waveform_job = nil
		waveform_runtime.state = .Unavailable
		waveform_job_destroy(job)
	}
}

waveform_clear_active :: proc() {
	if waveform_job != nil {_ = media_queue_cancel_waveform(waveform_job)}
	delete(waveform_runtime.path)
	waveform_runtime.path = ""
	waveform_runtime.state = .Idle
	waveform_runtime.view_initialized = false
}

on_waveform_finished :: proc "c" (self: Id, command: Sel, sender: Id) {
	context = runtime.default_context()
	job := waveform_job
	if job == nil {return}
	defer media_task_completion_finish(&job.completion)
	waveform_job = nil
	matches := waveform_runtime.path == job.path
	if matches {
		switch job.status {
		case .OK:
			if waveform_cache_store(job.path, job.peaks, job.count, job.rate_hz) {
				waveform_runtime.state = .Ready
			} else {
				waveform_runtime.state = .Unavailable
			}
		case .No_Audio: waveform_runtime.state = .No_Audio
		case .Unreadable: waveform_runtime.state = .Unavailable
		case .Cancelled: waveform_runtime.state = .Loading
		}
		ui.needs_redraw = true
	}
	if waveform_runtime.state == .Loading && len(waveform_runtime.path) > 0 {
		waveform_request(waveform_runtime.path, true)
	}
}
