package main

import "core:encoding/json"
import "core:fmt"
import os "core:os/old"
import os2 "core:os"

import "core:strings"
import "core:sync"
import "core:sys/posix"
import mem_virtual "core:mem/virtual"
import "base:runtime"
import task_queue "task_queue:."

Source_Auth_Browser :: enum {
	None,
	Brave,
	Chrome,
	Firefox,
	Safari,
	Edge,
	Chromium,
	Vivaldi,
}

SOURCE_AUTH_BROWSERS :: [7]Source_Auth_Browser{
	.Brave,
	.Chrome,
	.Firefox,
	.Safari,
	.Edge,
	.Chromium,
	.Vivaldi,
}

source_auth_browser_name :: proc(browser: Source_Auth_Browser) -> string {
	switch browser {
	case .Brave: return "Brave"
	case .Chrome: return "Google Chrome"
	case .Firefox: return "Firefox"
	case .Safari: return "Safari"
	case .Edge: return "Microsoft Edge"
	case .Chromium: return "Chromium"
	case .Vivaldi: return "Vivaldi"
	case .None: return ""
	}
	return ""
}

source_auth_browser_argument :: proc(browser: Source_Auth_Browser) -> string {
	switch browser {
	case .Brave: return "brave"
	case .Chrome: return "chrome"
	case .Firefox: return "firefox"
	case .Safari: return "safari"
	case .Edge: return "edge"
	case .Chromium: return "chromium"
	case .Vivaldi: return "vivaldi"
	case .None: return ""
	}
	return ""
}

source_auth_browser_from_argument :: proc(value: string) -> Source_Auth_Browser {
	for browser in SOURCE_AUTH_BROWSERS {
		if source_auth_browser_argument(browser) == value {return browser}
	}
	return .None
}

source_auth_browser_installed :: proc(browser: Source_Auth_Browser) -> bool {
	switch browser {
	case .Brave: return os.exists("/Applications/Brave Browser.app")
	case .Chrome: return os.exists("/Applications/Google Chrome.app")
	case .Firefox: return os.exists("/Applications/Firefox.app")
	case .Safari:
		return os.exists("/System/Applications/Safari.app") ||
		       os.exists("/Applications/Safari.app")
	case .Edge: return os.exists("/Applications/Microsoft Edge.app")
	case .Chromium: return os.exists("/Applications/Chromium.app")
	case .Vivaldi: return os.exists("/Applications/Vivaldi.app")
	case .None: return false
	}
	return false
}

source_auth_browser_installed_count :: proc() -> int {
	count := 0
	for browser in SOURCE_AUTH_BROWSERS {
		if source_auth_browser_installed(browser) {count += 1}
	}
	return count
}

source_probe_auth_required :: proc(stderr: string) -> bool {
	return strings.contains(stderr, "Sign in to confirm you’re not a bot") ||
	       strings.contains(stderr, "Sign in to confirm you're not a bot")
}

source_probe_browser_retry_available :: proc(result: Source_Probe_Result) -> bool {
	return result.auth_required ||
	       (result.auth_browser != .None &&
	        strings.has_suffix(result.error, "SESSION UNAVAILABLE"))
}

source_probe_command :: proc(
	url: string,
	auth_browser := Source_Auth_Browser.None,
	allocator := context.allocator,
) -> [dynamic]string {
	command := make([dynamic]string, allocator)
	append(&command, helper_command("yt-dlp"))
	if auth_browser != .None {
		append(
			&command,
			"--cookies-from-browser",
			source_auth_browser_argument(auth_browser),
		)
	}
	append(&command, "--dump-single-json", "--skip-download", url)
	return command
}

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
	auth_required: bool,
	auth_browser: Source_Auth_Browser,
}

Source_Probe_Job :: struct {
	task_id: task_queue.Task_ID,
	completion_target: Id,
	operation_id: u64,
	output_path: string,
	log_path: string,
	input: string,
	cached_results: [dynamic]Source_Probe_Result,
	results: [dynamic]Source_Probe_Result,
	notification_id: i64,
	auth_browser: Source_Auth_Browser,
	used_saved_browser: bool,
	save_browser_on_success: bool,
	process_mutex: sync.Mutex,
	process: os2.Process,
	has_process: bool,
	cancelled: bool,
	completion: Media_Task_Completion,
}

source_probe_job: ^Source_Probe_Job
source_probe_results: [dynamic]Source_Probe_Result
source_probe_cache: [dynamic]Source_Probe_Result
source_auth_saved_browser: Source_Auth_Browser

source_auth_preference_save :: proc(browser: Source_Auth_Browser) -> bool {
	if library_legacy_fallback ||
	   !database_source_auth_browser_save(library_database, browser) {
		return false
	}
	source_auth_saved_browser = browser
	return true
}

source_auth_preference_clear :: proc() -> bool {
	source_auth_saved_browser = .None
	return !library_legacy_fallback &&
	       database_source_auth_browser_clear(library_database)
}

source_probe_saved_retry_browser :: proc(
	auth_required: bool,
	requested_browser: Source_Auth_Browser,
	saved_browser: Source_Auth_Browser,
	saved_browser_installed: bool,
) -> Source_Auth_Browser {
	if !auth_required ||
	   requested_browser != .None ||
	   saved_browser == .None ||
	   !saved_browser_installed {
		return .None
	}
	return saved_browser
}

source_probe_result_clone :: proc(result: Source_Probe_Result) -> Source_Probe_Result {
	copy := Source_Probe_Result{
		url = strings.clone(result.url),
		video_id = strings.clone(result.video_id),
		title = strings.clone(result.title),
		duration = result.duration,
		selected_height = result.selected_height,
		error = strings.clone(result.error),
		auth_required = result.auth_required,
		auth_browser = result.auth_browser,
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
	if len(job.output_path) > 0 {
		_ = os.remove(job.output_path)
	}
	delete(job.output_path)
	delete(job.log_path)
	delete(job.input)
	for &result in job.cached_results {source_probe_result_destroy(&result)}
	delete(job.cached_results)
	for &result in job.results {source_probe_result_destroy(&result)}
	delete(job.results)
	free(job)
}

source_probe_job_cancel :: proc(job: ^Source_Probe_Job) {
	if job == nil {return}
	sync.mutex_lock(&job.process_mutex)
	job.cancelled = true
	if job.has_process {
		_ = kill(i32(job.process.pid), 15)
	}
	sync.mutex_unlock(&job.process_mutex)
}

source_probe_job_is_cancelled :: proc(job: ^Source_Probe_Job) -> bool {
	sync.mutex_lock(&job.process_mutex)
	cancelled := job.cancelled
	sync.mutex_unlock(&job.process_mutex)
	return cancelled
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

source_probe_one :: proc(
	job: ^Source_Probe_Job,
	url: string,
	auth_browser := Source_Auth_Browser.None,
) -> Source_Probe_Result {
	result := Source_Probe_Result{url=strings.clone(url)}
	video_id, valid := parse_video_id(url)
	if !valid {result.error = strings.clone("INVALID YOUTUBE URL"); return result}
	result.video_id = strings.clone(video_id)
	command := source_probe_command(
		url,
		auth_browser,
		context.temp_allocator,
	)
	output_file, output_error := os2.open(
		job.output_path,
		{.Write, .Create, .Trunc, .Inheritable},
	)
	if output_error != nil {
		result.error = strings.clone("METADATA UNAVAILABLE")
		return result
	}
	log_start := 0
	if log_info, stat_error := os.stat(
		job.log_path,
		context.temp_allocator,
	); stat_error == nil {
		log_start = int(log_info.size)
	}
	log_file, log_error := os2.open(
		job.log_path,
		{.Write, .Create, .Append, .Inheritable},
	)
	if log_error != nil {
		_ = os2.close(output_file)
		result.error = strings.clone("METADATA UNAVAILABLE")
		return result
	}
	process, start_error := os2.process_start(
		{command = command[:], stdout = output_file, stderr = log_file},
	)
	if start_error != nil {
		_ = os2.close(output_file)
		_ = os2.close(log_file)
		result.error = strings.clone("METADATA UNAVAILABLE")
		return result
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
	_ = os2.close(output_file)
	_ = os2.close(log_file)
	sync.mutex_lock(&job.process_mutex)
	job.has_process = false
	cancelled = job.cancelled
	sync.mutex_unlock(&job.process_mutex)
	stdout, stdout_ok := os.read_entire_file(
		job.output_path,
		context.temp_allocator,
	)
	stderr, _ := os.read_entire_file(
		job.log_path,
		context.temp_allocator,
	)
	if log_start >= 0 && log_start <= len(stderr) {
		stderr = stderr[log_start:]
	}
	if cancelled {
		result.error = strings.clone("METADATA CHECK STOPPED")
		return result
	}
	if wait_error != nil || !process_state.success || !stdout_ok {
		result.auth_required = source_probe_auth_required(string(stderr))
		result.auth_browser = auth_browser
		if result.auth_required {
			result.error = strings.clone("YOUTUBE SIGN-IN REQUIRED")
		} else if auth_browser != .None {
			result.error = strings.clone(fmt.tprintf(
				"%s SESSION UNAVAILABLE",
				source_auth_browser_name(auth_browser),
			))
		} else {
			result.error = strings.clone("METADATA UNAVAILABLE")
		}
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
	result.auth_browser = auth_browser
	if len(result.heights) == 0 {result.error = strings.clone("NO VIDEO FORMATS")}
	return result
}

source_probe_execute :: proc(job: ^Source_Probe_Job) {
	context = runtime.default_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	remaining := job.input
	for raw in strings.split_lines_iterator(&remaining) {
		if source_probe_job_is_cancelled(job) {break}
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
				cache_matches_browser :=
					result.auth_browser == .None ||
					result.auth_browser == job.auth_browser
				if result.video_id == video_id && cache_matches_browser {
					append(&job.results, source_probe_result_clone(result))
					cached = true
					break
				}
			}
			if cached {continue}
		}
		result := source_probe_one(job, url, job.auth_browser)
		if source_probe_job_is_cancelled(job) {
			source_probe_result_destroy(&result)
			break
		}
		append(&job.results, result)
	}
}

source_probe_request :: proc(
	auth_browser := Source_Auth_Browser.None,
	save_browser_on_success := false,
	used_saved_browser := false,
	existing_notification_id: i64 = 0,
) {
	if source_probe_job != nil {return}
	input := strings.trim_space(ui.url_input)
	if len(input) == 0 {source_probe_results_clear(); ui.needs_redraw = true; return}
	os.make_directory(app_support_dir())
	job := new(Source_Probe_Job)
	job.operation_id = next_media_operation_id()
	job.output_path = strings.clone(fmt.tprintf(
		"%s/yt-dlp-probe-%020d.json",
		app_support_dir(),
		job.operation_id,
	))
	job.log_path = strings.clone(import_log_path(job.operation_id))
	job.input = strings.clone(input)
	job.completion_target = state.delegate_target
	job.cached_results = make([dynamic]Source_Probe_Result)
	for result in source_probe_cache {append(&job.cached_results, source_probe_result_clone(result))}
	job.results = make([dynamic]Source_Probe_Result)
	job.auth_browser = auth_browser
	job.used_saved_browser = used_saved_browser
	job.save_browser_on_success = save_browser_on_success
	summary := "Checking YouTube metadata and formats..."
	detail := "The application reads source metadata without downloading media."
	if job.auth_browser != .None {
		browser_name := source_auth_browser_name(job.auth_browser)
		summary = fmt.tprintf("Checking metadata with %s session...", browser_name)
		if job.used_saved_browser {
			detail = fmt.tprintf(
				"YouTube requested sign-in. The application is retrying with the saved %s choice. It does not store or export browser cookies.",
				browser_name,
			)
		} else {
			detail = fmt.tprintf(
				"You selected %s. yt-dlp reads its YouTube session for this request. The application does not store or export browser cookies.",
				browser_name,
			)
		}
	}
	if existing_notification_id > 0 {
		job.notification_id = existing_notification_id
		_ = notification_update(
			existing_notification_id,
			summary,
			detail,
			persist_now=true,
		)
	} else {
		job.notification_id = notification_begin(summary, detail)
	}
	source_probe_job = job
	_ = os.write_entire_file(job.log_path, nil)
	if !media_queue_schedule_probe(job) {
		source_probe_job = nil
		_ = notification_finish(
			job.notification_id,
			.Error,
			"Unable to queue the metadata check",
		)
		source_probe_job_destroy(job)
	}
}

on_source_probe_finished :: proc "c" (self: Id, command: Sel, sender: Id) {
	context = runtime.default_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	job := source_probe_job
	if job == nil {return}
	defer {
		media_task_completion_finish(&job.completion)
	}
	if job.cancelled {
		_ = notification_finish(
			job.notification_id,
			.Interrupted,
			"Metadata check stopped",
		)
		source_probe_job = nil
		ui.needs_redraw = true
		return
	}
	for result in job.results {source_probe_cache_store(result)}
	source_probe_results_clear()
	source_probe_results = job.results
	job.results = nil
	notification_id := job.notification_id
	used_saved_browser := job.used_saved_browser
	save_browser_on_success := job.save_browser_on_success
	requested_browser := job.auth_browser
	probed_input := job.input
	job.input = ""
	source_probe_job = nil
	current := strings.trim_space(ui.url_input)
	if current != probed_input {
		_ = notification_finish(
			notification_id,
			.Interrupted,
			"Metadata check superseded by edited URLs",
		"The previous result was discarded because the source input changed.",
		)
		delete(probed_input)
		source_probe_request()
		return
	}
	delete(probed_input)
	auth_required := 0
	failed := 0
	failed_browser := Source_Auth_Browser.None
	for result in source_probe_results {
		if result.auth_required {auth_required += 1}
		if len(result.error) > 0 {failed += 1}
		if source_probe_browser_retry_available(result) &&
		   result.auth_browser != .None {
			failed_browser = result.auth_browser
		}
	}
	saved_browser_installed :=
		source_auth_browser_installed(source_auth_saved_browser)
	saved_retry_browser := source_probe_saved_retry_browser(
		auth_required > 0,
		requested_browser,
		source_auth_saved_browser,
		saved_browser_installed,
	)
	if saved_retry_browser != .None {
		source_probe_results_clear()
		source_probe_request(
			auth_browser=saved_retry_browser,
			used_saved_browser=true,
			existing_notification_id=notification_id,
		)
		return
	}
	if auth_required > 0 &&
	   requested_browser == .None &&
	   source_auth_saved_browser != .None &&
	   !saved_browser_installed {
		_ = source_auth_preference_clear()
		ui.save_source_browser_choice = false
	}
	saved_browser_failed :=
		used_saved_browser &&
		(auth_required > 0 || failed_browser != .None)
	if saved_browser_failed {
		_ = source_auth_preference_clear()
		ui.save_source_browser_choice = false
	}
	if auth_required > 0 {
		detail := "Choose an installed browser in the source dialog. The application uses that browser session only for this request and does not store or export cookies."
		if saved_browser_failed {
			detail = "The saved browser session no longer satisfies YouTube. Choose another browser. Enable Save choice for later to replace the saved choice."
		}
		_ = notification_finish(
			notification_id,
			.Error,
			"YouTube requires a signed-in browser session",
			detail,
		)
	} else if failed_browser != .None {
		browser_name := source_auth_browser_name(failed_browser)
		detail := fmt.tprintf(
			"Confirm that YouTube is signed in within %s, or choose another installed browser. The application did not store or export browser cookies.",
			browser_name,
		)
		if saved_browser_failed {
			detail = fmt.tprintf(
				"The saved %s session could not be used, so the saved choice was removed. Choose another signed-in browser.",
				browser_name,
			)
		}
		_ = notification_finish(
			notification_id,
			.Error,
			fmt.tprintf("Could not use %s session", browser_name),
			detail,
		)
	} else if failed > 0 {
		_ = notification_finish(
			notification_id,
			.Error,
			fmt.tprintf("Metadata unavailable for %d video(s)", failed),
		)
	} else {
		summary := fmt.tprintf(
			"Found metadata for %d video(s)",
			len(source_probe_results),
		)
		save_failed := false
		if save_browser_on_success {
			save_failed = !source_auth_preference_save(
				requested_browser,
			)
		}
		for result in source_probe_results {
			if result.auth_browser == .None {continue}
			summary = fmt.tprintf(
				"Found metadata using %s session",
				source_auth_browser_name(result.auth_browser),
			)
			if save_browser_on_success && !save_failed {
				summary = fmt.tprintf(
					"Saved %s for future YouTube requests",
					source_auth_browser_name(result.auth_browser),
				)
			}
			break
		}
		if save_failed {
			_ = notification_finish(
				notification_id,
				.Error,
				"Metadata found, but the browser choice was not saved",
				"Select the browser again with Save choice for later enabled.",
			)
		} else {
			_ = notification_finish(
				notification_id,
				.Success,
				summary,
			)
		}
	}
	ui.needs_redraw = true
}

source_probe_retry_with_browser :: proc(
	result_index: int,
	browser: Source_Auth_Browser,
) -> bool {
	if source_probe_job != nil ||
	   result_index < 0 ||
	   result_index >= len(source_probe_results) ||
	   !source_probe_browser_retry_available(source_probe_results[result_index]) ||
	   browser == .None ||
	   !source_auth_browser_installed(browser) {
		return false
	}
	save_browser_on_success := ui.save_source_browser_choice
	source_probe_results_clear()
	source_probe_request(
		auth_browser=browser,
		save_browser_on_success=save_browser_on_success,
	)
	return true
}

source_probe_selected_height :: proc(video_id: string) -> int {
	for result in source_probe_results {if result.video_id == video_id {return result.selected_height}}
	return 0
}

source_probe_selected_browser :: proc(video_id: string) -> Source_Auth_Browser {
	for result in source_probe_results {
		if result.video_id == video_id {return result.auth_browser}
	}
	return .None
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
