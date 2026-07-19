package main

import "core:encoding/json"
import "core:fmt"
import "core:os/os2"
import "core:strings"
import "core:thread"
import mem_virtual "core:mem/virtual"
import "base:runtime"

Source_Probe_Format_JSON :: struct {
	height: int,
	vcodec: string,
	ext: string,
}

Source_Probe_JSON :: struct {
	id: string,
	title: string,
	duration: f64,
	formats: []Source_Probe_Format_JSON,
}

Source_Probe_Result :: struct {
	url: string,
	video_id: string,
	title: string,
	duration: f64,
	heights: [dynamic]int,
	selected_height: int,
	error: string,
}

Source_Probe_Job :: struct {
	thread: ^thread.Thread,
	completion_target: Id,
	input: string,
	cached_results: [dynamic]Source_Probe_Result,
	results: [dynamic]Source_Probe_Result,
}

source_probe_job: ^Source_Probe_Job
source_probe_results: [dynamic]Source_Probe_Result
source_probe_cache: [dynamic]Source_Probe_Result

source_probe_result_clone :: proc(result: Source_Probe_Result) -> Source_Probe_Result {
	copy := Source_Probe_Result{
		url = strings.clone(result.url),
		video_id = strings.clone(result.video_id),
		title = strings.clone(result.title),
		duration = result.duration,
		selected_height = result.selected_height,
		error = strings.clone(result.error),
	}
	copy.heights = make([dynamic]int, 0, len(result.heights))
	append(&copy.heights, ..result.heights[:])
	return copy
}

source_probe_result_destroy :: proc(result: ^Source_Probe_Result) {
	delete(result.url)
	delete(result.video_id)
	delete(result.title)
	delete(result.heights)
	delete(result.error)
	result^ = {}
}

source_probe_results_clear :: proc() {
	for &result in source_probe_results {source_probe_result_destroy(&result)}
	delete(source_probe_results)
	source_probe_results = nil
}

source_probe_cache_clear :: proc() {
	for &result in source_probe_cache {source_probe_result_destroy(&result)}
	delete(source_probe_cache)
	source_probe_cache = nil
}

source_probe_cache_store :: proc(result: Source_Probe_Result) {
	if len(result.error) > 0 {return}
	for cached in source_probe_cache {if cached.video_id == result.video_id {return}}
	append(&source_probe_cache, source_probe_result_clone(result))
}

source_probe_job_destroy :: proc(job: ^Source_Probe_Job) {
	if job == nil {return}
	delete(job.input)
	for &result in job.cached_results {source_probe_result_destroy(&result)}
	delete(job.cached_results)
	for &result in job.results {source_probe_result_destroy(&result)}
	delete(job.results)
	free(job)
}

source_probe_default_height :: proc(heights: []int) -> int {
	if len(heights) == 0 {return 0}
	selected := heights[0]
	for height in heights {
		if height <= 1080 {selected = height}
	}
	return selected
}

source_probe_heights :: proc(formats: []Source_Probe_Format_JSON, allocator := context.allocator) -> [dynamic]int {
	heights := make([dynamic]int, allocator)
	for format in formats {
		codec_ok := strings.has_prefix(format.vcodec, "avc1") || strings.has_prefix(format.vcodec, "h264")
		if format.height <= 0 || format.ext != "mp4" || !codec_ok {continue}
		found := false
		for height in heights {if height == format.height {found = true; break}}
		if !found {append(&heights, format.height)}
	}
	for i in 1 ..< len(heights) {
		value := heights[i]
		j := i
		for j > 0 && heights[j - 1] > value {heights[j] = heights[j - 1]; j -= 1}
		heights[j] = value
	}
	return heights
}

source_probe_one :: proc(url: string) -> Source_Probe_Result {
	result := Source_Probe_Result{url=strings.clone(url)}
	video_id, valid := parse_video_id(url)
	if !valid {result.error = strings.clone("INVALID YOUTUBE URL"); return result}
	result.video_id = strings.clone(video_id)
	command := [4]string{helper_command("yt-dlp"), "--dump-single-json", "--skip-download", url}
	process_state, stdout, _, process_error := os2.process_exec({command=command[:]}, context.temp_allocator)
	if process_error != nil || !process_state.success {
		result.error = strings.clone("METADATA UNAVAILABLE")
		return result
	}
	data: Source_Probe_JSON
	if unmarshal_error := json.unmarshal(stdout, &data, .JSON, context.temp_allocator); unmarshal_error != nil {
		result.error = strings.clone("INVALID METADATA")
		return result
	}
	result.title = strings.clone(data.title)
	result.duration = data.duration
	result.heights = source_probe_heights(data.formats)
	result.selected_height = source_probe_default_height(result.heights[:])
	if len(result.heights) == 0 {result.error = strings.clone("NO VIDEO FORMATS")}
	return result
}

source_probe_worker :: proc(t: ^thread.Thread) {
	context = runtime.default_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	job := cast(^Source_Probe_Job)t.data
	remaining := job.input
	for raw in strings.split_lines_iterator(&remaining) {
		url := strings.trim_space(raw)
		if len(url) == 0 {continue}
		video_id, valid := parse_video_id(url)
		if valid {
			duplicate := false
			for result in job.results {
				if result.video_id == video_id {duplicate = true; break}
			}
			if duplicate {continue}
			cached := false
			for result in job.cached_results {
				if result.video_id == video_id {
					append(&job.results, source_probe_result_clone(result))
					cached = true
					break
				}
			}
			if cached {continue}
		}
		append(&job.results, source_probe_one(url))
	}
	msg_void_sel_id_b(job.completion_target, sel_registerName("performSelectorOnMainThread:withObject:waitUntilDone:"), sel_registerName("sourceProbeFinished:"), nil, false)
}

source_probe_request :: proc() {
	if source_probe_job != nil {return}
	input := strings.trim_space(ui.url_input)
	if len(input) == 0 {source_probe_results_clear(); ui.needs_redraw = true; return}
	job := new(Source_Probe_Job)
	job.input = strings.clone(input)
	job.completion_target = state.delegate_target
	job.cached_results = make([dynamic]Source_Probe_Result)
	for result in source_probe_cache {append(&job.cached_results, source_probe_result_clone(result))}
	job.results = make([dynamic]Source_Probe_Result)
	worker := thread.create(source_probe_worker)
	if worker == nil {source_probe_job_destroy(job); return}
	job.thread = worker
	worker.data = job
	source_probe_job = job
	set_text(state.status, "Checking YouTube metadata and formats...")
	thread.start(worker)
}

on_source_probe_finished :: proc "c" (self: Id, command: Sel, sender: Id) {
	context = runtime.default_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	job := source_probe_job
	if job == nil {return}
	thread.join(job.thread)
	thread.destroy(job.thread)
	for result in job.results {source_probe_cache_store(result)}
	source_probe_results_clear()
	source_probe_results = job.results
	job.results = nil
	probed_input := job.input
	job.input = ""
	free(job)
	source_probe_job = nil
	current := strings.trim_space(ui.url_input)
	if current != probed_input {
		delete(probed_input)
		source_probe_request()
		return
	}
	delete(probed_input)
	set_text(state.status, fmt.tprintf("Found metadata for %d video(s)", len(source_probe_results)))
	ui.needs_redraw = true
}

source_probe_selected_height :: proc(video_id: string) -> int {
	for result in source_probe_results {if result.video_id == video_id {return result.selected_height}}
	return 0
}

source_probe_ready :: proc(input: string) -> bool {
	video_ids: [dynamic]string
	defer delete(video_ids)
	remaining := input
	for raw in strings.split_lines_iterator(&remaining) {
		url := strings.trim_space(raw)
		if len(url) == 0 {continue}
		video_id, valid := parse_video_id(url)
		if !valid {return false}
		matched := false
		for result in source_probe_results {
			if result.video_id == video_id && len(result.error) == 0 {matched = true; break}
		}
		if !matched {return false}
		known := false
		for known_id in video_ids {if known_id == video_id {known = true; break}}
		if !known {append(&video_ids, video_id)}
	}
	return len(video_ids) > 0 && len(video_ids) == len(source_probe_results)
}
