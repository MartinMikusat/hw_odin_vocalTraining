package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import mem_virtual "core:mem/virtual"

CLI_Exit :: enum i32 {
	Success = 0,
	Usage = 2,
	Invalid = 3,
	Busy = 4,
	Media = 5,
	Storage = 6,
	Check = 7,
}

CLI_Command :: enum {
	None,
	Source_Add,
	Source_List,
	Transcript_Get,
	Clip_Create,
	Clip_List,
	UI_Snapshot,
	UI_Check,
}

CLI_Request :: struct {
	command: CLI_Command,
	url: string,
	source_id: string,
	from_segment: string,
	to_segment: string,
	name: string,
	max_height: int,
	baseline_path: string,
}

CLI_Result :: struct {
	output: string,
	exit_code: CLI_Exit,
}

CLI_Error_Data :: struct {
	code: string,
	message: string,
	diagnostic_log: string `json:"diagnostic_log,omitempty"`,
}

CLI_Error_Response :: struct {
	ok: bool,
	command: string,
	error: CLI_Error_Data,
}

CLI_Source_Output :: struct {
	id: string,
	video_id: string,
	title: string,
	url: string,
	duration_seconds: f64,
	media_path: string,
	media_available: bool,
	width: int,
	height: int,
	fps: f64,
	video_codec: string,
	audio_codec: string,
	container: string,
	format_id: string,
	file_size: i64,
}

CLI_Source_Add_Data :: struct {
	status: string,
	source: CLI_Source_Output,
}

CLI_Source_Add_Response :: struct {
	ok: bool,
	command: string,
	data: CLI_Source_Add_Data,
}

CLI_Source_List_Data :: struct {
	sources: []CLI_Source_Output,
}

CLI_Source_List_Response :: struct {
	ok: bool,
	command: string,
	data: CLI_Source_List_Data,
}

CLI_Transcript_Segment_Output :: struct {
	id: string,
	start_seconds: f64,
	duration_seconds: f64,
	text: string,
}

CLI_Transcript_Data :: struct {
	source_id: string,
	segments: []CLI_Transcript_Segment_Output,
}

CLI_Transcript_Response :: struct {
	ok: bool,
	command: string,
	data: CLI_Transcript_Data,
}

CLI_Clip_Output :: struct {
	id: string,
	source_id: string,
	name: string,
	start_seconds: f64,
	end_seconds: f64,
	clip_path: string,
	file_available: bool,
}

CLI_Clip_Create_Data :: struct {
	clip: CLI_Clip_Output,
}

CLI_Clip_Create_Response :: struct {
	ok: bool,
	command: string,
	data: CLI_Clip_Create_Data,
}

CLI_Clip_List_Data :: struct {
	clips: []CLI_Clip_Output,
}

CLI_Clip_List_Response :: struct {
	ok: bool,
	command: string,
	data: CLI_Clip_List_Data,
}

CLI_UI_Snapshot_Data :: struct {
	state: string,
	controls: int,
	enabled: int,
	frame: int,
	artifact: string,
}

CLI_UI_Snapshot_Response :: struct {
	ok: bool,
	command: string,
	data: CLI_UI_Snapshot_Data,
}

CLI_UI_Check_Data :: struct {
	state: string,
	controls: int,
	retained: int,
	added: int,
	disabled: int,
	removed: int,
	changed: int,
	unexpected: int,
	artifact: string,
}

CLI_UI_Check_Response :: struct {
	ok: bool,
	command: string,
	data: CLI_UI_Check_Data,
}

CLI_UI_Check_Failure_Response :: struct {
	ok: bool,
	command: string,
	data: CLI_UI_Check_Data,
	error: CLI_Error_Data,
}

cli_command_name :: proc(command: CLI_Command) -> string {
	switch command {
	case .Source_Add: return "source.add"
	case .Source_List: return "source.list"
	case .Transcript_Get: return "transcript.get"
	case .Clip_Create: return "clip.create"
	case .Clip_List: return "clip.list"
	case .UI_Snapshot: return "ui.snapshot"
	case .UI_Check: return "ui.check"
	case .None: return "unknown"
	}
	return "unknown"
}

cli_command_requires_gui :: proc(command: CLI_Command) -> bool {
	return command == .UI_Snapshot || command == .UI_Check
}

cli_command_mutates_library :: proc(command: CLI_Command) -> bool {
	return command == .Source_Add || command == .Clip_Create
}

cli_encode :: proc(value: $T) -> string {
	bytes, encode_error := json.marshal(value)
	if encode_error != nil {return strings.clone(`{"ok":false,"command":"unknown","error":{"code":"internal_error","message":"Unable to encode the command result"}}`)}
	defer delete(bytes)
	return strings.clone(string(bytes))
}

cli_error :: proc(command: CLI_Command, exit_code: CLI_Exit, code, message: string, diagnostic_log := "") -> CLI_Result {
	response := CLI_Error_Response{
		ok = false,
		command = cli_command_name(command),
		error = CLI_Error_Data{code=code, message=message, diagnostic_log=diagnostic_log},
	}
	return CLI_Result{output=cli_encode(response), exit_code=exit_code}
}

cli_parse_positive_int :: proc(value: string) -> (int, bool) {
	parsed, parsed_ok := strconv.parse_int(value)
	return parsed, parsed_ok && parsed > 0
}

cli_parse_flags :: proc(request: ^CLI_Request, args: []string, allowed: []string) -> (string, bool) {
	for index := 0; index < len(args); index += 2 {
		if index+1 >= len(args) {return fmt.tprintf("Missing value for %s", args[index]), false}
		flag := args[index]
		valid := false
		for candidate in allowed {if flag == candidate {valid = true; break}}
		if !valid {return fmt.tprintf("Unknown option: %s", flag), false}
		value := args[index+1]
		switch flag {
		case "--url": request.url = value
		case "--source": request.source_id = value
		case "--from-segment": request.from_segment = value
		case "--to-segment": request.to_segment = value
		case "--name": request.name = value
		case "--baseline": request.baseline_path = value
		case "--max-height":
			height, ok := cli_parse_positive_int(value)
			if !ok {return "--max-height must be a positive integer", false}
			request.max_height = height
		}
	}
	return "", true
}

cli_parse_request :: proc(args: []string) -> (CLI_Request, CLI_Result, bool) {
	request := CLI_Request{max_height=1080}
	if len(args) == 2 && args[0] == "--import" {
		request.command = .Source_Add
		request.url = args[1]
		return request, {}, true
	}
	if len(args) < 2 {
		return {}, cli_error(.None, .Usage, "usage", "Expected: source add|list, transcript get, clip create|list, or ui snapshot|check"), false
	}
	group, action := args[0], args[1]
	remaining := args[2:]
	allowed: []string
	switch {
	case group == "source" && action == "add":
		request.command = .Source_Add
		allowed = []string{"--url", "--max-height"}
	case group == "source" && action == "list":
		request.command = .Source_List
		if len(remaining) != 0 {return {}, cli_error(request.command, .Usage, "usage", "source list does not accept options"), false}
		return request, {}, true
	case group == "transcript" && action == "get":
		request.command = .Transcript_Get
		allowed = []string{"--source"}
	case group == "clip" && action == "create":
		request.command = .Clip_Create
		allowed = []string{"--source", "--from-segment", "--to-segment", "--name"}
	case group == "clip" && action == "list":
		request.command = .Clip_List
		allowed = []string{"--source"}
	case group == "ui" && action == "snapshot":
		request.command = .UI_Snapshot
		if len(remaining) != 0 {return {}, cli_error(request.command, .Usage, "usage", "ui snapshot does not accept options"), false}
		return request, {}, true
	case group == "ui" && action == "check":
		request.command = .UI_Check
		allowed = []string{"--baseline"}
	case:
		return {}, cli_error(.None, .Usage, "usage", "Expected: source add|list, transcript get, clip create|list, or ui snapshot|check"), false
	}
	if message, ok := cli_parse_flags(&request, remaining, allowed); !ok {
		return {}, cli_error(request.command, .Usage, "usage", message), false
	}
	switch request.command {
	case .Source_Add:
		if len(strings.trim_space(request.url)) == 0 {return {}, cli_error(request.command, .Usage, "usage", "source add requires --url"), false}
	case .Transcript_Get:
		if len(strings.trim_space(request.source_id)) == 0 {return {}, cli_error(request.command, .Usage, "usage", "transcript get requires --source"), false}
	case .Clip_Create:
		if len(strings.trim_space(request.source_id)) == 0 || len(strings.trim_space(request.from_segment)) == 0 || len(strings.trim_space(request.to_segment)) == 0 || len(strings.trim_space(request.name)) == 0 {
			return {}, cli_error(request.command, .Usage, "usage", "clip create requires --source, --from-segment, --to-segment, and --name"), false
		}
	case .UI_Check:
		if len(strings.trim_space(request.baseline_path)) == 0 {return {}, cli_error(request.command, .Usage, "usage", "ui check requires --baseline"), false}
	case .None, .Source_List, .Clip_List, .UI_Snapshot:
	}
	return request, {}, true
}

cli_find_source :: proc(source_id: string) -> ^Source_Video {
	for &source in state.sources {
		if source.id == source_id || source.video_id == source_id {return &source}
	}
	return nil
}

cli_source_output :: proc(source: ^Source_Video) -> CLI_Source_Output {
	return CLI_Source_Output{
		id=source.id,
		video_id=source.video_id,
		title=source.title,
		url=source.url,
		duration_seconds=source.duration,
		media_path=source.media_path,
		media_available=os.exists(source.media_path),
		width=source.metadata.width,
		height=source.metadata.height,
		fps=source.metadata.fps,
		video_codec=source.metadata.vcodec,
		audio_codec=source.metadata.acodec,
		container=source.metadata.ext,
		format_id=source.metadata.format_id,
		file_size=source.metadata.filesize_approx,
	}
}

cli_clip_output :: proc(exercise: ^Exercise) -> CLI_Clip_Output {
	return CLI_Clip_Output{
		id=exercise.id,
		source_id=exercise.source_id,
		name=exercise.name,
		start_seconds=exercise.start_seconds,
		end_seconds=exercise.end_seconds,
		clip_path=exercise.clip_path,
		file_available=os.exists(exercise.clip_path),
	}
}

cli_source_list :: proc(request: CLI_Request) -> CLI_Result {
	outputs := make([]CLI_Source_Output, len(state.sources), context.temp_allocator)
	for &source, index in state.sources {outputs[index] = cli_source_output(&source)}
	response := CLI_Source_List_Response{ok=true, command=cli_command_name(request.command), data=CLI_Source_List_Data{sources=outputs}}
	return CLI_Result{output=cli_encode(response), exit_code=.Success}
}

cli_source_add :: proc(request: CLI_Request) -> CLI_Result {
	if import_job != nil || export_job != nil {return cli_error(request.command, .Busy, "busy", "Another media operation is active")}
	video_id, valid_url := parse_video_id(request.url)
	if !valid_url {return cli_error(request.command, .Invalid, "invalid_url", "The URL is not a supported YouTube video URL")}

	existing := cli_find_source(video_id)
	if existing == nil {
		if available, reason := helper_available("yt-dlp"); !available {return cli_error(request.command, .Media, "helper_unavailable", reason, diagnostic_log_path("yt-dlp"))}
		if available, reason := helper_available("ffmpeg"); !available {return cli_error(request.command, .Media, "helper_unavailable", reason, diagnostic_log_path("ffmpeg"))}
	}
	existing_hint_count := len(state.hints)
	job := import_job_create(request.url)
	if job == nil {return cli_error(request.command, .Storage, "allocation_failed", "Unable to allocate the import job")}
	defer import_job_destroy(job)
	allocator := mem_virtual.arena_allocator(job.arena)
	append(&job.qualities, Import_Quality{video_id=strings.clone(video_id, allocator), height=request.max_height})
	if import_job_process_url(job, request.url) {job.accepted = 1} else {job.failed = 1}
	if job.failed > 0 {
		code := "download_failed"
		message := "The YouTube download failed"
		if job.invalid_merged_media > 0 {code, message = "media_validation_failed", "The staged MP4 did not contain compatible H.264 video and AAC audio"}
		return cli_error(request.command, .Media, code, message, diagnostic_log_path("yt-dlp"))
	}
	if !import_job_apply(job) {return cli_error(request.command, .Storage, "storage_failed", "The source was downloaded but the library update failed")}
	source := cli_find_source(video_id)
	if source == nil {return cli_error(request.command, .Storage, "storage_failed", "The source is missing after the library update")}
	status := "imported"
	if existing != nil {
		status = len(state.hints) > existing_hint_count ? "timestamp_added" : "existing"
	}
	response := CLI_Source_Add_Response{ok=true, command=cli_command_name(request.command), data=CLI_Source_Add_Data{status=status, source=cli_source_output(source)}}
	return CLI_Result{output=cli_encode(response), exit_code=.Success}
}

cli_transcript_get :: proc(request: CLI_Request) -> CLI_Result {
	source := cli_find_source(request.source_id)
	if source == nil {return cli_error(request.command, .Invalid, "source_not_found", "The source does not exist")}
	count := 0
	for segment in state.transcripts.segments {if segment.source_id == source.id {count += 1}}
	if count == 0 {
		count = load_youtube_transcript(source)
		if count == 0 {return cli_error(request.command, .Invalid, "captions_unavailable", "No usable YouTube caption track is available for this source")}
	}
	outputs := make([]CLI_Transcript_Segment_Output, count, context.temp_allocator)
	index := 0
	for segment in state.transcripts.segments {
		if segment.source_id != source.id {continue}
		outputs[index] = CLI_Transcript_Segment_Output{id=segment.id, start_seconds=segment.start_seconds, duration_seconds=segment.duration_seconds, text=segment.text}
		index += 1
	}
	response := CLI_Transcript_Response{ok=true, command=cli_command_name(request.command), data=CLI_Transcript_Data{source_id=source.id, segments=outputs}}
	return CLI_Result{output=cli_encode(response), exit_code=.Success}
}

cli_next_exercise_id :: proc(source: ^Source_Video) -> string {
	for number := 1; ; number += 1 {
		candidate := fmt.tprintf("%s-%d", source.video_id, number)
		found := false
		for exercise in state.exercises {if exercise.id == candidate {found = true; break}}
		if !found {return candidate}
	}
}

cli_segment_range :: proc(source_id, from_segment, to_segment: string, segments: []Transcript_Segment) -> (f64, f64, string) {
	first: ^Transcript_Segment
	last: ^Transcript_Segment
	first_index, last_index := -1, -1
	for &segment, index in segments {
		if segment.id == from_segment {first, first_index = &segment, index}
		if segment.id == to_segment {last, last_index = &segment, index}
	}
	if first == nil || last == nil {return 0, 0, "segment_not_found"}
	if first.source_id != source_id || last.source_id != source_id {return 0, 0, "segment_source_mismatch"}
	if first_index > last_index {return 0, 0, "segment_order_invalid"}
	return first.start_seconds, last.start_seconds+last.duration_seconds, ""
}

cli_clip_create :: proc(request: CLI_Request) -> CLI_Result {
	if import_job != nil || export_job != nil {return cli_error(request.command, .Busy, "busy", "Another media operation is active")}
	source := cli_find_source(request.source_id)
	if source == nil {return cli_error(request.command, .Invalid, "source_not_found", "The source does not exist")}
	if !os.exists(source.media_path) {return cli_error(request.command, .Invalid, "media_missing", "The source media file is missing")}
	start_seconds, end_seconds, range_error := cli_segment_range(source.id, request.from_segment, request.to_segment, state.transcripts.segments[:])
	switch range_error {
	case "segment_not_found": return cli_error(request.command, .Invalid, range_error, "One or both transcript segments do not exist")
	case "segment_source_mismatch": return cli_error(request.command, .Invalid, range_error, "Both transcript segments must belong to the selected source")
	case "segment_order_invalid": return cli_error(request.command, .Invalid, range_error, "The first transcript segment occurs after the last segment")
	case:
	}
	if !valid_exercise_range(start_seconds, end_seconds, source.duration) {return cli_error(request.command, .Invalid, "range_invalid", "The transcript segments produce an invalid clip range")}
	if available, reason := helper_available("ffmpeg"); !available {return cli_error(request.command, .Media, "helper_unavailable", reason, diagnostic_log_path("ffmpeg"))}
	id := cli_next_exercise_id(source)
	exercise := Exercise{id=id, source_id=source.id, name=request.name, start_seconds=start_seconds, end_seconds=end_seconds}
	if !export_exercise(&exercise, source.media_path) {return cli_error(request.command, .Media, "clip_export_failed", "FFmpeg could not create the clip", diagnostic_log_path("ffmpeg"))}
	defer delete(exercise.clip_path)
	copy, copied := clone_exercise(exercise)
	if !copied {
		_ = os.remove(exercise.clip_path)
		return cli_error(request.command, .Storage, "allocation_failed", "Unable to store the exported exercise")
	}
	append(&state.exercises, copy)
	if !save_library() {
		stored := pop(&state.exercises)
		delete_exercise(&stored)
		_ = os.remove(exercise.clip_path)
		return cli_error(request.command, .Storage, "storage_failed", "The clip was created but the library update failed")
	}
	stored := &state.exercises[len(state.exercises)-1]
	response := CLI_Clip_Create_Response{ok=true, command=cli_command_name(request.command), data=CLI_Clip_Create_Data{clip=cli_clip_output(stored)}}
	return CLI_Result{output=cli_encode(response), exit_code=.Success}
}

cli_clip_list :: proc(request: CLI_Request) -> CLI_Result {
	filter := ""
	if len(request.source_id) > 0 {
		source := cli_find_source(request.source_id)
		if source == nil {return cli_error(request.command, .Invalid, "source_not_found", "The source does not exist")}
		filter = source.id
	}
	count := 0
	for exercise in state.exercises {if len(filter) == 0 || exercise.source_id == filter {count += 1}}
	outputs := make([]CLI_Clip_Output, count, context.temp_allocator)
	index := 0
	for &exercise in state.exercises {
		if len(filter) > 0 && exercise.source_id != filter {continue}
		outputs[index] = cli_clip_output(&exercise)
		index += 1
	}
	response := CLI_Clip_List_Response{ok=true, command=cli_command_name(request.command), data=CLI_Clip_List_Data{clips=outputs}}
	return CLI_Result{output=cli_encode(response), exit_code=.Success}
}

cli_ui_snapshot :: proc(request: CLI_Request) -> CLI_Result {
	snapshot, snapshot_ok := ui_diagnostic_capture_current(context.temp_allocator)
	if !snapshot_ok {
		return cli_error(request.command, .Busy, "ui_not_ready", "The running app has not completed a valid UI frame")
	}
	path := ui_diagnostic_artifact_path(
		"snapshot",
		snapshot.frame,
		context.temp_allocator,
	)
	if !ui_diagnostic_write_artifact(path, snapshot, context.temp_allocator) {
		return cli_error(request.command, .Storage, "snapshot_write_failed", "Unable to write the UI snapshot")
	}
	response := CLI_UI_Snapshot_Response{
		ok = true,
		command = cli_command_name(request.command),
		data = CLI_UI_Snapshot_Data{
			state = ui_diagnostic_state_name(snapshot.surface, context.temp_allocator),
			controls = len(snapshot.controls),
			enabled = ui_diagnostic_enabled_count(&snapshot),
			frame = snapshot.frame,
			artifact = path,
		},
	}
	return CLI_Result{output=cli_encode(response), exit_code=.Success}
}

cli_ui_check :: proc(request: CLI_Request) -> CLI_Result {
	baseline, baseline_ok := ui_diagnostic_read_snapshot(
		request.baseline_path,
		context.temp_allocator,
	)
	if !baseline_ok {
		return cli_error(request.command, .Invalid, "invalid_baseline", "The baseline is not a valid UI snapshot")
	}
	current, current_ok := ui_diagnostic_capture_current(context.temp_allocator)
	if !current_ok {
		return cli_error(request.command, .Busy, "ui_not_ready", "The running app has not completed a valid UI frame")
	}
	diff := ui_diagnostic_compare_background(
		baseline,
		current,
		context.temp_allocator,
	)
	artifact := UI_Diagnostic_Check_Artifact{
		schema_version = UI_DIAGNOSTIC_SCHEMA_VERSION,
		contract = "background-operation-continuity",
		baseline = baseline,
		current = current,
		diff = diff,
	}
	path := ui_diagnostic_artifact_path(
		"check",
		current.frame,
		context.temp_allocator,
	)
	if !ui_diagnostic_write_artifact(path, artifact, context.temp_allocator) {
		return cli_error(request.command, .Storage, "snapshot_write_failed", "Unable to write the UI check artifact")
	}
	data := CLI_UI_Check_Data{
		state = ui_diagnostic_state_name(current.surface, context.temp_allocator),
		controls = len(current.controls),
		retained = diff.retained_count,
		added = len(diff.added),
		disabled = len(diff.disabled),
		removed = len(diff.removed),
		changed = len(diff.changed),
		unexpected = len(diff.unexpected),
		artifact = path,
	}
	response := CLI_UI_Check_Response{
		ok = diff.ok,
		command = cli_command_name(request.command),
		data = data,
	}
	exit_code := CLI_Exit.Success
	if !diff.ok {
		error_data := CLI_Error_Data{
			code = "ui_contract_failed",
			message = fmt.tprintf(
				"UI continuity failed: removed=%d changed=%d unexpected=%d contract=%d",
				len(diff.removed),
				len(diff.changed),
				len(diff.unexpected),
				len(diff.contract_issues),
			),
			diagnostic_log = path,
		}
		exit_code = .Check
		failure := CLI_UI_Check_Failure_Response{
			ok = false,
			command = cli_command_name(request.command),
			data = data,
			error = error_data,
		}
		return CLI_Result{output=cli_encode(failure), exit_code=exit_code}
	}
	return CLI_Result{output=cli_encode(response), exit_code=exit_code}
}

cli_execute :: proc(request: CLI_Request) -> CLI_Result {
	switch request.command {
	case .Source_Add: return cli_source_add(request)
	case .Source_List: return cli_source_list(request)
	case .Transcript_Get: return cli_transcript_get(request)
	case .Clip_Create: return cli_clip_create(request)
	case .Clip_List: return cli_clip_list(request)
	case .UI_Snapshot: return cli_ui_snapshot(request)
	case .UI_Check: return cli_ui_check(request)
	case .None: return cli_error(request.command, .Usage, "usage", "Unknown command")
	}
	return cli_error(request.command, .Usage, "usage", "Unknown command")
}
