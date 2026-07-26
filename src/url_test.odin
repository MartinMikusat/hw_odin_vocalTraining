package main

import "core:testing"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "base:runtime"
import mem_virtual "core:mem/virtual"
import command_palette "command_palette:."
import flash "flash:."
import match_sorter "match_sorter:."

@(test)
parse_standard_youtube_url_test :: proc(t: ^testing.T) {
	id, ok := parse_video_id("https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=1m20s")
	testing.expect(t, ok)
	testing.expect_value(t, id, "dQw4w9WgXcQ")
	seconds, has_time := parse_timestamp("https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=1m20s")
	testing.expect(t, has_time)
	testing.expect_value(t, seconds, 80)
}

@(test)
parse_short_youtube_url_test :: proc(t: ^testing.T) {
	id, ok := parse_video_id("https://youtu.be/dQw4w9WgXcQ?start=42")
	testing.expect(t, ok)
	testing.expect_value(t, id, "dQw4w9WgXcQ")
	seconds, has_time := parse_timestamp("https://youtu.be/dQw4w9WgXcQ?start=42")
	testing.expect(t, has_time)
	testing.expect_value(t, seconds, 42)
}

@(test)
timestamp_format_uses_hours_minutes_and_seconds_test :: proc(t: ^testing.T) {
	testing.expect_value(t, format_timestamp(0), "00:00:00")
	testing.expect_value(t, format_timestamp(65.9), "00:01:05")
	testing.expect_value(t, format_timestamp(3661), "01:01:01")
}

@(test)
timestamp_fade_ranges_cover_only_leading_zero_fields_test :: proc(t: ^testing.T) {
	hours_and_minutes := timestamp_fade_ranges("00:00:03")
	testing.expect_value(t, hours_and_minutes.count, 1)
	testing.expect_value(t, hours_and_minutes.values[0], CF_Range{0, 6})

	hours := timestamp_fade_ranges("00:03:04")
	testing.expect_value(t, hours.count, 1)
	testing.expect_value(t, hours.values[0], CF_Range{0, 3})

	no_fade := timestamp_fade_ranges("03:00:04")
	testing.expect_value(t, no_fade.count, 0)
}

@(test)
timestamp_fade_ranges_use_utf16_offsets_for_embedded_timestamps_test :: proc(t: ^testing.T) {
	ranges := timestamp_fade_ranges("RANGE 00:00:03 → 00:04:05")
	testing.expect_value(t, ranges.count, 2)
	testing.expect_value(t, ranges.values[0], CF_Range{6, 6})
	testing.expect_value(t, ranges.values[1], CF_Range{17, 3})
}

@(test)
youtube_json3_caption_mapping_test :: proc(t: ^testing.T) {
	fixture := `{"events":[{"tStartMs":1250,"dDurationMs":750,"segs":[{"utf8":"Warm "},{"utf8":"up"}]}]}`
	captions: YouTube_Captions
	err := json.unmarshal_string(fixture, &captions, .JSON)
	defer {
		for event in captions.events {
			for segment in event.segments { delete(segment.text) }
			delete(event.segments)
		}
		delete(captions.events)
	}
	testing.expect(t, err == nil)
	testing.expect_value(t, len(captions.events), 1)
	testing.expect_value(t, captions.events[0].start_ms, 1250)
	testing.expect_value(t, captions.events[0].duration_ms, 750)
	testing.expect_value(t, captions.events[0].segments[0].text, "Warm ")
}

@(test)
source_context_metadata_maps_selected_download_format_test :: proc(t: ^testing.T) {
	fixture := `{"width":1920,"height":1080,"fps":30,"vcodec":"avc1.640028","acodec":"mp4a.40.2","ext":"mp4","format_id":"137+140","filesize_approx":76886301}`
	metadata: Source_Context_Metadata
	err := json.unmarshal_string(fixture, &metadata, .JSON)
	defer {
		delete(metadata.vcodec)
		delete(metadata.acodec)
		delete(metadata.ext)
		delete(metadata.format_id)
	}
	testing.expect(t, err == nil)
	testing.expect_value(t, metadata.width, 1920)
	testing.expect_value(t, metadata.height, 1080)
	testing.expect_value(t, metadata.fps, 30)
	testing.expect_value(t, metadata.vcodec, "avc1.640028")
	testing.expect_value(t, metadata.acodec, "mp4a.40.2")
	testing.expect_value(t, metadata.format_id, "137+140")
}

@(test)
source_context_file_size_uses_readable_units_test :: proc(t: ^testing.T) {
	testing.expect_value(t, format_file_size(999), "999 B")
	testing.expect_value(t, format_file_size(1_500), "1.5 KB")
	testing.expect_value(t, format_file_size(76_886_301), "76.9 MB")
	testing.expect_value(t, format_file_size(1_500_000_000), "1.50 GB")
	testing.expect_value(t, format_frame_rate(30), "30 fps")
	testing.expect_value(t, format_frame_rate(29.97), "29.97 fps")
}

@(test)
completed_refetch_preserves_the_current_source_test :: proc(t: ^testing.T) {
	testing.expect(t, should_load_completed_source(false, 2, 5))
	testing.expect(t, should_load_completed_source(true, 5, 5))
	testing.expect(t, !should_load_completed_source(true, 2, 5))
	testing.expect(t, !should_load_completed_source(false, 2, -1))
}

@(test)
canonical_library_loads_real_data_and_builds_unique_controls_test :: proc(t: ^testing.T) {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	path, found := os.lookup_env("VT_TEST_LIBRARY")
	defer delete(path)
	testing.expect(t, found)
	if !found {return}

	c_path := strings.clone_to_cstring(path)
	defer delete(c_path)
	database: ^SQLite_DB
	opened := sqlite3_open_v2(c_path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK
	testing.expect(t, opened)
	if !opened {return}
	defer sqlite3_close(database)

	testing.expect(t, database_create_schema(database))
	testing.expect(t, database_integrity_ok(database))
	source_count, sources_counted := database_count(database, "sources")
	segment_count, segments_counted := database_count(database, "transcript_segments")
	hint_count, hints_counted := database_count(database, "import_hints")
	exercise_count, exercises_counted := database_count(database, "exercises")
	testing.expect(t, sources_counted && segments_counted && hints_counted && exercises_counted)
	testing.expect_value(t, source_count, 7)
	testing.expect_value(t, segment_count, 1532)
	testing.expect_value(t, hint_count, 12)
	testing.expect_value(t, exercise_count, 1)

	loaded: App_State
	testing.expect(t, database_load_state(database, &loaded))
	defer {
		for &source in loaded.sources {delete_source_video(&source)}
		for &hint in loaded.hints {delete_import_hint(&hint)}
		for &exercise in loaded.exercises {delete_exercise(&exercise)}
		delete(loaded.sources)
		delete(loaded.hints)
		delete(loaded.exercises)
		transcript_generation_destroy(&loaded.transcripts)
	}
	testing.expect_value(t, len(loaded.sources), source_count)
	testing.expect_value(t, len(loaded.transcripts.segments), segment_count)
	testing.expect_value(t, len(loaded.transcripts.source_spans), source_count)
	testing.expect_value(t, len(loaded.hints), hint_count)
	testing.expect_value(t, len(loaded.exercises), exercise_count)
	next_segment := 0
	for span in loaded.transcripts.source_spans {
		testing.expect_value(t, span.start, next_segment)
		testing.expect(t, span.count > 0)
		for segment in loaded.transcripts.segments[span.start:span.start+span.count] {
			testing.expect_value(t, segment.source_id, span.source_id)
		}
		next_segment += span.count
	}
	testing.expect_value(t, next_segment, segment_count)
	for source in loaded.sources {
		testing.expect(t, filepath.is_abs(source.media_path))
		segments, base_index, found := transcript_source_segments(
			&loaded.transcripts,
			source.id,
		)
		testing.expect(t, found)
		testing.expect(t, base_index >= 0)
		for segment in segments {
			testing.expect_value(t, segment.source_id, source.id)
		}
	}
	for exercise in loaded.exercises {
		source_found := false
		for source in loaded.sources {
			if source.id == exercise.source_id {
				source_found = true
				break
			}
		}
		testing.expect(t, source_found)
		testing.expect(t, filepath.is_abs(exercise.clip_path))
	}

	previous_state := state
	previous_ui := ui
	previous_ui_build := ui_build
	frame_arena: mem_virtual.Arena
	frame_arena_error := mem_virtual.arena_init_static(&frame_arena, 1024*1024, 4096)
	testing.expect(t, frame_arena_error == nil)
	if frame_arena_error != nil {return}
	defer mem_virtual.arena_destroy(&frame_arena)
	frame_allocator := mem_virtual.arena_allocator(&frame_arena)
	state = loaded
	loaded = {}
	defer {
		for &source in state.sources {delete_source_video(&source)}
		for &hint in state.hints {delete_import_hint(&hint)}
		for &exercise in state.exercises {delete_exercise(&exercise)}
		delete(state.sources)
		delete(state.hints)
		delete(state.exercises)
		transcript_generation_destroy(&state.transcripts)
		delete(ui.transcript_matches)
		state = previous_state
		ui = previous_ui
		ui_build = previous_ui_build
	}
	ui = UI_State{
		width = 2048,
		height = 1120,
		player_volume = 1,
		playback_rate = 1,
		source_details_index = -1,
		source_modal_refetch_index = -1,
		transcript_active_match = -1,
		transcript_matches_dirty = true,
	}
	ui.mode = .Create
	build_ui_controls(false, frame_allocator)
	testing.expect(t, ui_controls_valid(ui_build.controls[:]))
	create_control_count := len(ui_build.controls)
	testing.expect(t, create_control_count > 20)
	idle_snapshot := ui_diagnostic_snapshot(
		ui_build.controls[:],
		ui_build.diagnostic_surface,
		ui_build.frame,
		context.temp_allocator,
	)
	ui_build.controls = nil
	mem_virtual.arena_free_all(&frame_arena)

	busy_job: Import_Job
	previous_import_job := import_job
	import_job = &busy_job
	defer import_job = previous_import_job
	ui.frame_tick += 1
	build_ui_controls(false, frame_allocator)
	testing.expect(t, ui_controls_valid(ui_build.controls[:]))
	testing.expect(t, len(ui_build.controls) > create_control_count)
	busy_snapshot := ui_diagnostic_snapshot(
		ui_build.controls[:],
		ui_build.diagnostic_surface,
		ui_build.frame,
		context.temp_allocator,
	)
	busy_diff := ui_diagnostic_compare_background(
		idle_snapshot,
		busy_snapshot,
		context.temp_allocator,
	)
	testing.expect(t, busy_diff.ok)
	testing.expect_value(t, busy_diff.retained_count, len(idle_snapshot.controls))
	testing.expect_value(t, len(busy_diff.added), 1)
	testing.expect(t, len(busy_diff.disabled) > 0)
	testing.expect_value(t, len(busy_diff.removed), 0)
	testing.expect_value(t, len(busy_diff.changed), 0)
	testing.expect_value(t, len(busy_diff.unexpected), 0)
	broken_controls := make(
		[dynamic]UI_Diagnostic_Control,
		0,
		len(busy_snapshot.controls),
		context.temp_allocator,
	)
	for control in busy_snapshot.controls {
		if strings.has_prefix(control.functional_name, "select source ") ||
		   strings.has_prefix(control.functional_name, "transcript segment ") {
			continue
		}
		append(&broken_controls, control)
	}
	broken_snapshot := busy_snapshot
	broken_snapshot.controls = broken_controls[:]
	broken_diff := ui_diagnostic_compare_background(
		idle_snapshot,
		broken_snapshot,
		context.temp_allocator,
	)
	testing.expect(t, !broken_diff.ok)
	testing.expect(t, len(broken_diff.removed) > 0)
	stop := find_ui_control_by_action(.Stop_Download)
	mode := find_ui_control_by_action(.Mode_Toggle)
	source := find_ui_control_by_action(.Source)
	search := find_ui_control_by_action(.Source_Search)
	add := find_ui_control_by_action(.Open_Source_Modal)
	save := find_ui_control_by_action(.Save)
	captions := find_ui_control_by_action(.Captions)
	preview := find_ui_control_by_action(.Preview)
	testing.expect(t, stop != nil && .Enabled in stop.flags)
	testing.expect(t, mode != nil && .Enabled in mode.flags)
	testing.expect(t, source != nil && .Enabled in source.flags)
	testing.expect(t, search != nil && .Enabled in search.flags)
	testing.expect(t, add != nil && .Enabled not_in add.flags)
	testing.expect(t, save != nil && .Enabled not_in save.flags)
	testing.expect(t, captions != nil && .Enabled not_in captions.flags)
	testing.expect(t, preview != nil && .Enabled not_in preview.flags)
	testing.expect(t, ui_action_enabled_for_current_job(.Source_Play_Pause))
	testing.expect(t, ui_action_enabled_for_current_job(.Source_Timeline))
	testing.expect(t, ui_action_enabled_for_current_job(.Volume_Down))
	testing.expect(t, ui_action_enabled_for_current_job(.Speed_Up))
	testing.expect(t, !ui_action_enabled_for_current_job(.Source_Hint))
	ui_build.controls = nil
	mem_virtual.arena_free_all(&frame_arena)
	import_job = previous_import_job

	ui_set_string(&ui.status_source_video_id, state.sources[1].video_id)
	action_rect := status_source_rect()
	status_rect := footer_status_rect()
	testing.expect_value(t, status_rect.x, action_rect.x + action_rect.w + 6)
	build_ui_controls(false, frame_allocator)
	view_source := find_ui_control_by_action(.View_Status_Source)
	testing.expect(t, view_source != nil)
	if view_source != nil {
		testing.expect_value(t, view_source.action.index, 1)
		testing.expect(t, strings.contains(view_source.functional_name, state.sources[1].id))
	}
	ui_build.controls = nil
	mem_virtual.arena_free_all(&frame_arena)
	ui_set_string(&ui.status_source_video_id, "")

	ui.mode = .Play
	build_ui_controls(false, frame_allocator)
	testing.expect(t, ui_controls_valid(ui_build.controls[:]))
	testing.expect(t, len(ui_build.controls) > 4)
}

@(test)
sqlite_source_round_trip_preserves_metadata_and_unicode_test :: proc(t: ^testing.T) {
	database: ^SQLite_DB
	path := strings.clone_to_cstring(":memory:")
	defer delete(path)
	opened := sqlite3_open_v2(path, &database, SQLITE_OPEN_READWRITE|SQLITE_OPEN_CREATE, nil) == SQLITE_OK
	testing.expect(t, opened)
	if !opened {return}
	defer sqlite3_close(database)
	testing.expect(t, database_create_schema(database))
	source := Source_Video {
		id = "source-1",
		video_id = "abc",
		title = "Warm-up – Žltý hlas",
		url = "https://youtu.be/abc",
		media_path = "/tmp/voice.mp4",
		duration = 333,
		metadata_status = .Available,
		metadata = Source_Context_Metadata{width=1920, height=1080, fps=29.97, vcodec="avc1", acodec="mp4a", ext="mp4", format_id="137+140", filesize_approx=76_886_301},
	}
	testing.expect(t, database_insert_source(database, source, 0))
	statement, prepared := sqlite_prepare(database, "SELECT title, width, fps, file_size FROM sources WHERE id = 'source-1'")
	testing.expect(t, prepared)
	if !prepared {return}
	testing.expect_value(t, sqlite3_step(statement), i32(SQLITE_ROW))
	title, copied := sqlite_column_string(statement, 0)
	defer delete(title)
	testing.expect(t, copied)
	testing.expect_value(t, title, source.title)
	testing.expect_value(t, int(sqlite3_column_int(statement, 1)), 1920)
	testing.expect_value(t, sqlite3_column_double(statement, 2), 29.97)
	testing.expect_value(t, sqlite3_column_int64(statement, 3), i64(76_886_301))
	sqlite3_finalize(statement)
	statement = nil
	loaded: App_State
	testing.expect(t, database_load_state(database, &loaded))
	defer {
		for &loaded_source in loaded.sources {delete_source_video(&loaded_source)}
		for &hint in loaded.hints {delete_import_hint(&hint)}
		for &exercise in loaded.exercises {delete_exercise(&exercise)}
		delete(loaded.sources); delete(loaded.hints); delete(loaded.exercises)
		transcript_generation_destroy(&loaded.transcripts)
	}
	testing.expect_value(t, len(loaded.sources), 1)
	if len(loaded.sources) == 1 {
		testing.expect_value(t, loaded.sources[0].title, source.title)
		testing.expect_value(t, loaded.sources[0].metadata.width, 1920)
		testing.expect_value(t, loaded.sources[0].metadata_status, Source_Metadata_Status.Available)
	}
}

@(test)
exercise_range_validation_test :: proc(t: ^testing.T) {
	testing.expect(t, valid_exercise_range(10, 20, 60))
	testing.expect(t, !valid_exercise_range(-1, 20, 60))
	testing.expect(t, !valid_exercise_range(20, 20, 60))
	testing.expect(t, !valid_exercise_range(20, 20.999, 60))
	testing.expect(t, valid_exercise_range(20, 21, 60))
	testing.expect(t, !valid_exercise_range(20, 61, 60))
	testing.expect(t, valid_exercise_range(20, 61, 0))
}

@(test)
cli_source_add_parses_json_tool_arguments_test :: proc(t: ^testing.T) {
	request, result, ok := cli_parse_request([]string{"source", "add", "--url", "https://youtu.be/dQw4w9WgXcQ", "--max-height", "720"})
	defer delete(result.output)
	testing.expect(t, ok)
	testing.expect_value(t, request.command, CLI_Command.Source_Add)
	testing.expect_value(t, request.url, "https://youtu.be/dQw4w9WgXcQ")
	testing.expect_value(t, request.max_height, 720)
}

@(test)
cli_source_add_defaults_to_1080p_test :: proc(t: ^testing.T) {
	request, result, ok := cli_parse_request([]string{"--import", "https://youtu.be/dQw4w9WgXcQ"})
	defer delete(result.output)
	testing.expect(t, ok)
	testing.expect_value(t, request.command, CLI_Command.Source_Add)
	testing.expect_value(t, request.max_height, 1080)
}

@(test)
cli_rejects_incomplete_clip_request_with_json_error_test :: proc(t: ^testing.T) {
	_, result, ok := cli_parse_request([]string{"clip", "create", "--source", "source-1"})
	defer delete(result.output)
	testing.expect(t, !ok)
	testing.expect_value(t, result.exit_code, CLI_Exit.Usage)
	testing.expect(t, strings.contains(result.output, `"ok":false`))
	testing.expect(t, strings.contains(result.output, `"code":"usage"`))
}

@(test)
cli_ui_commands_parse_and_require_the_running_gui_test :: proc(t: ^testing.T) {
	snapshot, snapshot_result, snapshot_ok := cli_parse_request(
		[]string{"ui", "snapshot"},
	)
	defer delete(snapshot_result.output)
	testing.expect(t, snapshot_ok)
	testing.expect_value(t, snapshot.command, CLI_Command.UI_Snapshot)
	testing.expect(t, cli_command_requires_gui(snapshot.command))
	testing.expect(t, !cli_command_mutates_library(snapshot.command))

	check, check_result, check_ok := cli_parse_request(
		[]string{"ui", "check", "--baseline", "/tmp/ui-baseline.json"},
	)
	defer delete(check_result.output)
	testing.expect(t, check_ok)
	testing.expect_value(t, check.command, CLI_Command.UI_Check)
	testing.expect_value(t, check.baseline_path, "/tmp/ui-baseline.json")
	testing.expect(t, cli_command_requires_gui(check.command))

	_, missing_result, missing_ok := cli_parse_request([]string{"ui", "check"})
	defer delete(missing_result.output)
	testing.expect(t, !missing_ok)
	testing.expect_value(t, missing_result.exit_code, CLI_Exit.Usage)
}

@(test)
cli_ui_check_failure_encodes_compact_json_test :: proc(t: ^testing.T) {
	response := CLI_UI_Check_Failure_Response{
		ok = false,
		command = "ui.check",
		data = {
			state = "create.importing",
			controls = 55,
			retained = 54,
			removed = 1,
			artifact = "/tmp/check.json",
		},
		error = {
			code = "ui_contract_failed",
			message = "UI continuity failed",
			diagnostic_log = "/tmp/check.json",
		},
	}
	encoded := cli_encode(response)
	defer delete(encoded)
	testing.expect(t, strings.contains(encoded, `"command":"ui.check"`))
	testing.expect(t, strings.contains(encoded, `"code":"ui_contract_failed"`))
	testing.expect(t, !strings.contains(encoded, `"internal_error"`))
}

@(test)
ui_diagnostic_artifacts_keep_only_the_newest_twenty_files_test :: proc(
	t: ^testing.T,
) {
	support, found := os.lookup_env("VT_APP_SUPPORT_DIR")
	defer delete(support)
	testing.expect(t, found)
	if !found {return}
	directory := fmt.tprintf("%s/ui-prune-test", support)
	os.make_directory(directory)
	json_contents := []byte{'{', '}'}
	for index in 0..<23 {
		path := fmt.tprintf("%s/snapshot-%02d.json", directory, index)
		testing.expect(t, os.write_entire_file(path, json_contents))
	}
	unrelated := fmt.tprintf("%s/keep.txt", directory)
	testing.expect(t, os.write_entire_file(unrelated, []byte{'k', 'e', 'e', 'p'}))
	removed := ui_diagnostic_prune_artifacts(
		directory,
		UI_DIAGNOSTIC_ARTIFACT_RETENTION,
		context.temp_allocator,
	)
	testing.expect_value(t, removed, 3)
	handle, open_error := os.open(directory)
	testing.expect(t, open_error == nil)
	if open_error != nil {return}
	entries, read_error := os.read_dir(handle, -1, context.temp_allocator)
	os.close(handle)
	testing.expect(t, read_error == nil)
	count := 0
	for entry in entries {
		if strings.has_prefix(entry.name, "snapshot-") &&
		   strings.has_suffix(entry.name, ".json") {
			count += 1
		}
	}
	testing.expect_value(t, count, UI_DIAGNOSTIC_ARTIFACT_RETENTION)
	testing.expect(t, os.exists(unrelated))
	testing.expect(t, os.exists(fmt.tprintf("%s/snapshot-22.json", directory)))
}

@(test)
cli_segment_ids_map_to_exact_caption_bounds_test :: proc(t: ^testing.T) {
	segments := []Transcript_Segment{
		{id="source-1-1", source_id="source-1", start_seconds=12.5, duration_seconds=1.25},
		{id="source-1-2", source_id="source-1", start_seconds=13.75, duration_seconds=2.5},
	}
	start, end, range_error := cli_segment_range("source-1", "source-1-1", "source-1-2", segments)
	testing.expect_value(t, range_error, "")
	testing.expect_value(t, start, 12.5)
	testing.expect_value(t, end, 16.25)
}

@(test)
cli_segment_range_rejects_wrong_source_and_reverse_order_test :: proc(t: ^testing.T) {
	segments := []Transcript_Segment{
		{id="source-1-1", source_id="source-1", start_seconds=12.5, duration_seconds=1.25},
		{id="source-2-1", source_id="source-2", start_seconds=13.75, duration_seconds=2.5},
		{id="source-1-2", source_id="source-1", start_seconds=16.25, duration_seconds=1.5},
	}
	_, _, source_error := cli_segment_range("source-1", "source-1-1", "source-2-1", segments)
	testing.expect_value(t, source_error, "segment_source_mismatch")
	_, _, order_error := cli_segment_range("source-1", "source-1-2", "source-1-1", segments)
	testing.expect_value(t, order_error, "segment_order_invalid")
	_, _, missing_error := cli_segment_range("source-1", "source-1-1", "missing", segments)
	testing.expect_value(t, missing_error, "segment_not_found")
}

@(test)
persisted_state_json_round_trip_test :: proc(t: ^testing.T) {
	original := Persisted_State{version=1}
	append(&original.sources, Source_Video{id="source-1", video_id="abc", title="Warmup", duration=90})
	append(&original.exercises, Exercise{id="exercise-1", source_id="source-1", name="Scale", start_seconds=12, end_seconds=24})
	encoded, marshal_error := json.marshal(original)
	defer delete(encoded)
	defer delete(original.sources)
	defer delete(original.exercises)
	testing.expect(t, marshal_error == nil)
	restored: Persisted_State
	unmarshal_error := json.unmarshal(encoded, &restored, .JSON)
	defer {
		for source in restored.sources {
			delete(source.id); delete(source.video_id); delete(source.title)
		}
		for exercise in restored.exercises {
			delete(exercise.id); delete(exercise.source_id); delete(exercise.name)
		}
		delete(restored.sources); delete(restored.exercises)
	}
	testing.expect(t, unmarshal_error == nil)
	testing.expect_value(t, restored.sources[0].title, "Warmup")
	testing.expect_value(t, restored.exercises[0].end_seconds, 24)
	database: ^SQLite_DB
	path := strings.clone_to_cstring(":memory:")
	defer delete(path)
	opened := sqlite3_open_v2(path, &database, SQLITE_OPEN_READWRITE|SQLITE_OPEN_CREATE, nil) == SQLITE_OK
	testing.expect(t, opened)
	if opened {
		defer sqlite3_close(database)
		testing.expect(t, database_create_schema(database))
		testing.expect(t, database_save_collections(database, restored.sources[:], restored.segments[:], restored.hints[:], restored.exercises[:]))
		source_count, source_count_ok := database_count(database, "sources")
		exercise_count, exercise_count_ok := database_count(database, "exercises")
		testing.expect(t, source_count_ok && exercise_count_ok)
		testing.expect_value(t, source_count, 1)
		testing.expect_value(t, exercise_count, 1)
	}
}

@(test)
youtube_command_requests_timed_captions_test :: proc(t: ^testing.T) {
	command := youtube_download_command("https://youtu.be/abc?t=10", "/tmp/source.%(ext)s", "/tmp/download.log")
	testing.expect(t, strings.contains(command, "--write-subs"))
	testing.expect(t, strings.contains(command, "--write-auto-subs"))
	testing.expect(t, strings.contains(command, "--sub-format json3"))
	testing.expect(t, strings.contains(command, "bv*[ext=mp4]+ba[ext=m4a]"))
	testing.expect(t, strings.contains(command, "-S 'res,vcodec:h264'"))
	testing.expect(t, strings.contains(command, "--merge-output-format mp4"))
	testing.expect(t, strings.contains(command, "--force-overwrites"))
	testing.expect(t, !strings.contains(command, "--recode-video"))
	testing.expect(t, strings.contains(command, "'/tmp/source.%(ext)s'"))
}

@(test)
embedded_helper_path_uses_app_resources_test :: proc(t: ^testing.T) {
	path := embedded_helper_path(
		"/Applications/VocalTraining.app/Contents/MacOS/VocalTraining",
		"ffmpeg",
	)
	testing.expect_value(
		t,
		path,
		"/Applications/VocalTraining.app/Contents/Resources/helpers/ffmpeg",
	)
}

@(test)
helper_path_search_returns_an_absolute_executable_path_test :: proc(t: ^testing.T) {
	testing.expect_value(t, helper_path_from_search("sh", "/missing:/bin"), "/bin/sh")
	testing.expect_value(t, helper_path_from_search("not-a-helper", "/missing:/bin"), "not-a-helper")
}

@(test)
youtube_command_uses_resolved_helpers_test :: proc(t: ^testing.T) {
	command := youtube_download_command(
		"https://youtu.be/abc",
		"/tmp/source.%(ext)s",
		"/tmp/download.log",
		"/Applications/VocalTraining.app/Contents/Resources/helpers/yt-dlp",
		"/Applications/VocalTraining.app/Contents/Resources/helpers/ffmpeg",
	)
	testing.expect(t, strings.has_prefix(command, "'/Applications/VocalTraining.app/Contents/Resources/helpers/yt-dlp'"))
	testing.expect(t, strings.contains(command, "--ffmpeg-location '/Applications/VocalTraining.app/Contents/Resources/helpers/ffmpeg'"))
}

@(test)
clip_command_uses_range_duration_test :: proc(t: ^testing.T) {
	command := clip_export_command(
		"/tmp/source video.mp4",
		"/tmp/clip.mp4",
		12.5,
		20.25,
		"/Applications/VocalTraining.app/Contents/Resources/helpers/ffmpeg",
	)
	testing.expect(t, strings.has_prefix(command, "'/Applications/VocalTraining.app/Contents/Resources/helpers/ffmpeg'"))
	testing.expect(t, strings.contains(command, "-ss 12.500"))
	testing.expect(t, strings.contains(command, "-t 7.750"))
	testing.expect(t, strings.contains(command, "'/tmp/source video.mp4'"))
}

@(test)
metal_ui_hit_testing_uses_logical_points_test :: proc(t: ^testing.T) {
	rect := UI_Rect{10, 20, 100, 40}
	testing.expect(t, contains(rect, Point{10, 20}))
	testing.expect(t, contains(rect, Point{110, 60}))
	testing.expect(t, !contains(rect, Point{9, 20}))
	testing.expect(t, !contains(rect, Point{50, 61}))
}

@(test)
metal_ui_backspace_removes_complete_utf8_character_test :: proc(t: ^testing.T) {
	value := strings.clone("Warmup 🎵")
	defer delete(value)
	remove_last_character(&value)
	testing.expect_value(t, value, "Warmup ")
	remove_last_character(&value)
	testing.expect_value(t, value, "Warmup")
}

@(test)
metal_ui_word_backspace_removes_trailing_space_and_word_test :: proc(t: ^testing.T) {
	value := strings.clone("Vocal warmup   ")
	defer delete(value)
	remove_last_word(&value)
	testing.expect_value(t, value, "Vocal ")
	remove_last_word(&value)
	testing.expect_value(t, value, "")
	remove_last_word(&value)
	testing.expect_value(t, value, "")
}

@(test)
metal_ui_word_backspace_preserves_utf8_boundaries_test :: proc(t: ^testing.T) {
	value := strings.clone("Vocal cvičenie")
	defer delete(value)
	remove_last_word(&value)
	testing.expect_value(t, value, "Vocal ")
}

@(test)
metal_ui_word_backspace_uses_punctuation_boundaries_test :: proc(t: ^testing.T) {
	value := strings.clone("vocal-training.app/exercises")
	defer delete(value)
	remove_last_word(&value)
	testing.expect_value(t, value, "vocal-training.app/")
	remove_last_word(&value)
	testing.expect_value(t, value, "vocal-training.")
	remove_last_word(&value)
	testing.expect_value(t, value, "vocal-")
}

@(test)
metal_ui_word_backspace_keeps_underscore_inside_word_test :: proc(t: ^testing.T) {
	value := strings.clone("vocal_training")
	defer delete(value)
	remove_last_word(&value)
	testing.expect_value(t, value, "")
}

@(test)
terminal_layout_stays_partitioned_at_minimum_size_test :: proc(t: ^testing.T) {
	old_width, old_height := ui.width, ui.height
	old_mode, old_modal := ui.mode, ui.source_modal_open
	defer { ui.width, ui.height = old_width, old_height; ui.mode, ui.source_modal_open = old_mode, old_modal }
	ui.width, ui.height = 1100, 720
	ui.mode, ui.source_modal_open = .Create, false
	import_field, import_button, _, source_panel, player, transcript, _, exercise_panel, _, controls := layout_rects()
	testing.expect(t, import_field.w == 0 && import_button.w == 0)
	testing.expect(t, source_panel.x+source_panel.w < player.x)
	testing.expect(t, player.x+player.w < exercise_panel.x)
	testing.expect(t, transcript.y+transcript.h < player.y)
	testing.expect(t, controls.x >= 0 && controls.x+controls.w <= ui.width)
}

@(test)
terminal_control_rail_fills_width_without_overlap_test :: proc(t: ^testing.T) {
	old_mode := ui.mode
	defer ui.mode = old_mode
	ui.mode = .Create
	controls := UI_Rect{18,42,1064,28}
	previous := control_rect(controls, 0)
	for index in 1..<8 {
		current := control_rect(controls, index)
		testing.expect(t, previous.x+previous.w < current.x)
		previous = current
	}
	testing.expect(t, previous.x+previous.w <= controls.x+controls.w)
}

@(test)
metal_ui_scroll_moves_toward_later_rows_and_stays_bounded_test :: proc(t: ^testing.T) {
	offset := bounded_scroll(0, -24, 20, 25, 26, 100)
	testing.expect_value(t, offset, 24)
	testing.expect_value(t, bounded_scroll(offset, 100, 20, 25, 26, 100), 0)
	testing.expect_value(t, bounded_scroll(0, -1000, 5, 25, 26, 100), 29)
	testing.expect_value(t, bounded_scroll(20, -20, 2, 25, 26, 100), 0)
}

@(test)
metal_ui_content_regions_exclude_headers_and_fields_test :: proc(t: ^testing.T) {
	source_panel := UI_Rect{18, 116, 280, 500}
	source_search := UI_Rect{26, 544, 264, 28}
	source_content := source_content_rect(source_search, source_panel)
	testing.expect(t, source_content.y > source_panel.y)
	testing.expect(t, source_content.y+source_content.h < source_search.y)

	transcript := UI_Rect{308, 116, 480, 180}
	transcript_content := transcript_content_rect(transcript)
	testing.expect(t, transcript_content.y > transcript.y)
	testing.expect(t, transcript_content.y+transcript_content.h < transcript.y+transcript.h)

	player := UI_Rect{308, 306, 480, 310}
	player_content := player_content_rect(player)
	testing.expect(t, player_content.y > player.y)
	testing.expect(t, player_content.y+player_content.h < player.y+player.h)

	exercise_panel := UI_Rect{798, 116, 284, 500}
	exercise_search := UI_Rect{806, 544, 268, 28}
	exercise_name := UI_Rect{806, 124, 268, 30}
	exercise_content := exercise_content_rect(exercise_search, exercise_panel, exercise_name)
	testing.expect(t, exercise_content.y > exercise_name.y+exercise_name.h)
	testing.expect(t, exercise_content.y+exercise_content.h < exercise_search.y)
}

@(test)
metal_ui_titlebar_uses_compact_height_test :: proc(t: ^testing.T) {
	testing.expect_value(t, APP_HEADER_HEIGHT, 38.0)
}

@(test)
source_monitor_volume_controls_sit_left_of_timestamp_test :: proc(t: ^testing.T) {
	player := UI_Rect{308, 306, 760, 310}
	reset := source_reset_rect(player)
	speed_down := source_speed_down_rect(player)
	speed_up := source_speed_up_rect(player)
	down := source_volume_down_rect(player)
	value := source_volume_value_rect(player)
	up := source_volume_up_rect(player)
	timestamp := source_timestamp_rect(player)
	testing.expect(t, reset.x + reset.w <= speed_down.x)
	testing.expect(t, speed_up.x + speed_up.w <= down.x)
	testing.expect(t, down.x + down.w <= value.x)
	testing.expect(t, value.x + value.w <= up.x)
	testing.expect(t, up.x + up.w <= timestamp.x)
	testing.expect(t, timestamp.x + timestamp.w <= player.x + player.w)
	testing.expect_value(t, source_play_pause_rect(player).y, speed_down.y)
	testing.expect_value(t, speed_down.y, down.y)
	testing.expect_value(t, down.y, timestamp.y + 3)
}

@(test)
source_monitor_volume_clamps_and_rounds_percent_test :: proc(t: ^testing.T) {
	testing.expect_value(t, clamp_volume(-0.1), f32(0))
	testing.expect_value(t, clamp_volume(0.55), f32(0.55))
	testing.expect_value(t, clamp_volume(1.1), f32(1))
	testing.expect_value(t, volume_percent(0.549), 55)
	testing.expect_value(t, volume_percent(1.1), 100)
}

@(test)
source_monitor_playback_rate_clamps_test :: proc(t: ^testing.T) {
	testing.expect_value(t, clamp_playback_rate(0), f32(0.1))
	testing.expect_value(t, clamp_playback_rate(1.1), f32(1.1))
	testing.expect_value(t, clamp_playback_rate(2.1), f32(2))
}

@(test)
command_palette_modal_stays_centered_and_contains_its_search_and_results_test :: proc(t: ^testing.T) {
	modal := command_palette_rect_for_size(1100, 720)
	search := command_palette_search_rect(modal)
	results := command_palette_results_rect(modal)
	testing.expect_value(t, modal.x, (1100-modal.w)/2)
	testing.expect_value(t, modal.y, (720-modal.h)/2)
	testing.expect(t, contains(modal, Point{search.x, search.y}))
	testing.expect(t, contains(modal, Point{results.x, results.y}))
	testing.expect(t, results.y + results.h <= search.y)
}

@(test)
command_palette_catalog_disables_create_commands_in_play_mode_test :: proc(t: ^testing.T) {
	previous_mode := ui.mode
	previous_player := state.player
	previous_source := state.active_source
	previous_import := import_job
	previous_export := export_job
	previous_actions := command_palette_actions
	defer {
		delete(command_palette_actions)
		command_palette_actions = previous_actions
		ui.mode = previous_mode
		state.player = previous_player
		state.active_source = previous_source
		import_job = previous_import
		export_job = previous_export
	}
	command_palette_actions = nil
	ui.mode = .Play
	state.player = nil
	state.active_source = -1
	import_job = nil
	export_job = nil
	entries := build_command_palette_entries(context.temp_allocator)
	active := palette_active_context()
	found_mark_in := false
	found_data := false
	for entry in entries {
		if entry.title == "Mark In" {
			found_mark_in = true
			testing.expect(t, !command_palette.context_matches(active, entry.contexts))
			testing.expect(t, len(entry.unavailable_reason) > 0)
		}
		if entry.title == "Open data folder" {
			found_data = true
			testing.expect(t, command_palette.context_matches(active, entry.contexts))
		}
	}
	testing.expect(t, found_mark_in)
	testing.expect(t, found_data)
}

@(test)
audio_frame_range_maps_and_clamps_source_time_test :: proc(t: ^testing.T) {
	start, count := audio_frame_range(1.5, 48_000, 480_000)
	testing.expect_value(t, start, i64(72_000))
	testing.expect_value(t, count, u32(408_000))
	start, count = audio_frame_range(-1, 48_000, 480_000)
	testing.expect_value(t, start, i64(0))
	testing.expect_value(t, count, u32(480_000))
	start, count = audio_frame_range(20, 48_000, 480_000)
	testing.expect_value(t, start, i64(480_000))
	testing.expect_value(t, count, u32(0))
}

@(test)
audio_source_seconds_combines_schedule_offset_and_rendered_frames_test :: proc(t: ^testing.T) {
	seconds, ok := audio_source_seconds(48_000, 24_000, 48_000)
	testing.expect(t, ok)
	testing.expect_value(t, seconds, 1.5)
	_, ok = audio_source_seconds(0, -1, 48_000)
	testing.expect(t, !ok)
}

@(test)
metal_ui_text_origin_uses_run_metrics_and_container_rect_test :: proc(t: ^testing.T) {
	old_scale := ui.scale
	defer { ui.scale = old_scale }
	ui.scale = 1
	run := Text_Run{advance=40,ascent=8,descent=2}
	rect := UI_Rect{10,20,100,30}
	center := text_origin(rect, run, .Center, .Center)
	testing.expect_value(t, center.x, 40)
	testing.expect_value(t, center.y, 32)
	end := text_origin(rect, run, .End, .End, 5)
	testing.expect_value(t, end.x, 65)
	testing.expect_value(t, end.y, 37)
}

@(test)
core_text_shapes_and_measures_complete_lines_test :: proc(t: ^testing.T) {
	font_name := CFStringCreateWithCString(nil, "HoeflerText-Regular", 0x08000100)
	testing.expect(t, font_name != nil)
	defer CFRelease(font_name)
	font := CTFontCreateWithName(font_name, 32, nil)
	testing.expect(t, font != nil)
	defer CFRelease(font)

	pair := make_text_run(font, "AV")
	a := make_text_run(font, "A")
	v := make_text_run(font, "V")
	ligature := make_text_run(font, "fi")
	arabic := make_text_run(font, "سلام")
	defer delete_text_run(&pair)
	defer delete_text_run(&a)
	defer delete_text_run(&v)
	defer delete_text_run(&ligature)
	defer delete_text_run(&arabic)

	testing.expect(t, pair.line != nil && arabic.line != nil)
	testing.expect(t, pair.advance < a.advance+v.advance)
	testing.expect(t, text_run_glyph_count(ligature) < 2)
	testing.expect(t, text_run_glyph_count(arabic) > 0)
}

@(test)
core_text_truncation_uses_a_shaped_ellipsis_line_test :: proc(t: ^testing.T) {
	font_name := CFStringCreateWithCString(nil, "Helvetica", 0x08000100)
	defer CFRelease(font_name)
	font := CTFontCreateWithName(font_name, 18, nil)
	defer CFRelease(font)
	full := make_text_run(font, "A deliberately long proportional-font label")
	defer delete_text_run(&full)
	truncated := truncated_text_run(full, font, full.advance/2)
	defer delete_text_run(&truncated)
	testing.expect(t, truncated.line != nil)
	testing.expect(t, truncated.advance <= full.advance/2)
	testing.expect(t, text_run_glyph_count(truncated) > 0)
}

@(test)
core_text_draws_the_measured_line_into_the_overlay_context_test :: proc(t: ^testing.T) {
	pixels := make([]u8, 256*64*4)
	defer delete(pixels)
	space := CGColorSpaceCreateDeviceRGB()
	defer CGColorSpaceRelease(space)
	ctx := CGBitmapContextCreate(raw_data(pixels), 256, 64, 8, 256*4, space, 0x2002)
	testing.expect(t, ctx != nil)
	defer CGContextRelease(ctx)
	font_name := CFStringCreateWithCString(nil, "Helvetica", 0x08000100)
	defer CFRelease(font_name)
	font := CTFontCreateWithName(font_name, 24, nil)
	defer CFRelease(font)
	run := make_text_run(font, "Voice fi سلام")
	defer delete_text_run(&run)
	draw_text_run(ctx, run, Point{4,24}, [4]f64{1,1,1,1})
	has_ink := false
	for pixel in pixels {
		if pixel != 0 {
			has_ink = true
			break
		}
	}
	testing.expect(t, has_ink)
}

@(test)
core_text_draws_a_truncated_line_before_releasing_it_test :: proc(t: ^testing.T) {
	pixels := make([]u8, 96*32*4)
	defer delete(pixels)
	space := CGColorSpaceCreateDeviceRGB()
	defer CGColorSpaceRelease(space)
	ctx := CGBitmapContextCreate(raw_data(pixels), 96, 32, 8, 96*4, space, 0x2002)
	testing.expect(t, ctx != nil)
	defer CGContextRelease(ctx)
	font_name := CFStringCreateWithCString(nil, "Helvetica", 0x08000100)
	defer CFRelease(font_name)
	font := CTFontCreateWithName(font_name, 18, nil)
	defer CFRelease(font)
	previous_scale := ui.scale
	ui.scale = 1
	defer ui.scale = previous_scale

	draw_text_in_rect(
		ctx,
		font,
		"A deliberately long proportional-font label",
		UI_Rect{0,0,96,32},
		.Start,
		.Center,
		[4]f64{1,1,1,1},
	)

	has_ink := false
	for pixel in pixels {
		if pixel != 0 {
			has_ink = true
			break
		}
	}
	testing.expect(t, has_ink)
}

@(test)
metal_player_survives_autorelease_pool_drain_and_replacement_test :: proc(t: ^testing.T) {
	headless, skip := os.lookup_env("VT_HEADLESS_TEST")
	delete(headless)
	if skip {return}
	objc_handle := os.dlopen("/usr/lib/libobjc.A.dylib", os.RTLD_NOW)
	testing.expect(t, objc_handle != nil)
	testing.expect(t, os.dlopen("/System/Library/Frameworks/AppKit.framework/AppKit", os.RTLD_NOW) != nil)
	testing.expect(t, os.dlopen("/System/Library/Frameworks/AVFoundation.framework/AVFoundation", os.RTLD_NOW) != nil)
	testing.expect(t, os.dlopen("/System/Library/Frameworks/AVFAudio.framework/AVFAudio", os.RTLD_NOW) != nil)
	previous_send := send_address
	send_address = os.dlsym(objc_handle, "objc_msgSend")
	testing.expect(t, send_address != nil)
	defer {
		metal_player_clear()
		send_address = previous_send
	}
	app := msg_id(objc_getClass("NSApplication"), sel_registerName("sharedApplication"))
	testing.expect(t, app != nil)

	first_pool := msg_id(objc_getClass("NSAutoreleasePool"), sel_registerName("new"))
	testing.expect(t, metal_player_load("/System/Library/Sounds/Glass.aiff"))
	metal_audio_seek(0, false)
	first_player := state.player
	msg_void(first_pool, sel_registerName("drain"))
	testing.expect(t, first_player != nil)
	testing.expect(t, msg_f32(first_player, sel_registerName("rate")) >= 0)

	second_pool := msg_id(objc_getClass("NSAutoreleasePool"), sel_registerName("new"))
	testing.expect(t, metal_player_load("/System/Library/Sounds/Ping.aiff"))
	metal_audio_seek(0, false)
	second_player := state.player
	msg_void(second_pool, sel_registerName("drain"))
	testing.expect(t, second_player != nil)
	testing.expect(t, msg_f32(second_player, sel_registerName("rate")) >= 0)
}

@(test)
virtual_arena_reset_reclaims_the_complete_frame_test :: proc(t: ^testing.T) {
	arena: mem_virtual.Arena
	init_error := mem_virtual.arena_init_static(&arena, 1024*1024, 4096)
	testing.expect(t, init_error == nil)
	defer mem_virtual.arena_destroy(&arena)
	allocator := mem_virtual.arena_allocator(&arena)
	vertices := make([dynamic]Solid_Vertex, 0, 64, allocator)
	append(&vertices, Solid_Vertex{x=1,y=2})
	testing.expect(t, arena.total_used > 0)
	stats := Arena_Stats{name="test"}
	arena_reset(&arena, &stats)
	testing.expect_value(t, arena.total_used, uint(0))
	testing.expect_value(t, stats.reset_count, u64(1))
	testing.expect(t, stats.high_water > 0)
}

@(test)
transcript_generation_owns_all_reachable_strings_test :: proc(t: ^testing.T) {
	input := [2]Transcript_Segment{
		{id="one",source_id="source-a",start_seconds=1,text="Warm up"},
		{id="two",source_id="source-b",start_seconds=2,text="Scale"},
	}
	generation, ok := transcript_generation_copy(input[:])
	testing.expect(t, ok)
	testing.expect_value(t, len(generation.segments), 2)
	testing.expect_value(t, len(generation.source_spans), 2)
	testing.expect_value(t, generation.segments[0].text, "Warm up")
	testing.expect(t, generation.arena.total_used > 0)
	transcript_generation_destroy(&generation)
	testing.expect(t, generation.arena == nil)
	testing.expect_value(t, len(generation.segments), 0)
	testing.expect_value(t, len(generation.source_spans), 0)
}

@(test)
transcript_generation_groups_interleaved_sources_into_stable_spans_test :: proc(t: ^testing.T) {
	input := [4]Transcript_Segment{
		{id="a-1", source_id="a", start_seconds=1, text="First A"},
		{id="b-1", source_id="b", start_seconds=2, text="First B"},
		{id="a-2", source_id="a", start_seconds=3, text="Second A"},
		{id="b-2", source_id="b", start_seconds=4, text="Second B"},
	}
	generation, ok := transcript_generation_copy(input[:])
	testing.expect(t, ok)
	if !ok { return }
	defer transcript_generation_destroy(&generation)

	testing.expect_value(t, len(generation.source_spans), 2)
	testing.expect_value(t, generation.source_spans[0], Transcript_Source_Span{
		source_id="a",
		start=0,
		count=2,
	})
	testing.expect_value(t, generation.source_spans[1], Transcript_Source_Span{
		source_id="b",
		start=2,
		count=2,
	})
	testing.expect_value(t, generation.segments[0].id, "a-1")
	testing.expect_value(t, generation.segments[1].id, "a-2")
	testing.expect_value(t, generation.segments[2].id, "b-1")
	testing.expect_value(t, generation.segments[3].id, "b-2")

	a_segments, a_base, a_found := transcript_source_segments(&generation, "a")
	testing.expect(t, a_found)
	testing.expect_value(t, a_base, 0)
	testing.expect_value(t, len(a_segments), 2)
	missing, missing_base, missing_found := transcript_source_segments(
		&generation,
		"missing",
	)
	testing.expect(t, !missing_found)
	testing.expect_value(t, len(missing), 0)
	testing.expect_value(t, missing_base, -1)

	direct, direct_ok := transcript_generation_create(3)
	testing.expect(t, direct_ok)
	if !direct_ok { return }
	defer transcript_generation_destroy(&direct)
	testing.expect(t, transcript_append_copy(&direct, input[0]))
	testing.expect(t, transcript_append_copy(&direct, input[1]))
	testing.expect(t, !transcript_append_copy(&direct, input[2]))
	testing.expect_value(t, len(direct.segments), 2)
}

@(test)
durable_model_clone_survives_source_arena_destruction_test :: proc(t: ^testing.T) {
	scratch, ok := growing_arena_create(64*1024, 4096)
	testing.expect(t, ok)
	allocator := mem_virtual.arena_allocator(scratch)
	source := Source_Video{
		id=strings.clone("source", allocator),
		video_id=strings.clone("video", allocator),
		title=strings.clone("Warmup", allocator),
		url=strings.clone("https://example.test", allocator),
		media_path=strings.clone("/tmp/source.mp4", allocator),
	}
	copy, copied := clone_source_video(source)
	testing.expect(t, copied)
	growing_arena_destroy(scratch)
	defer delete_source_video(&copy)
	testing.expect_value(t, copy.title, "Warmup")
	testing.expect_value(t, copy.media_path, "/tmp/source.mp4")
}

@(test)
mode_control_slots_expose_only_relevant_actions_test :: proc(t: ^testing.T) {
	for slot in 0..<8 {
		testing.expect_value(t, control_action_for_slot(.Create, slot), slot)
		testing.expect_value(t, control_slot_for_action(.Create, slot), slot)
	}
	testing.expect_value(t, control_action_for_slot(.Play, 0), 3)
	testing.expect_value(t, control_action_for_slot(.Play, 1), 4)
	testing.expect_value(t, control_action_for_slot(.Play, 2), 8)
	testing.expect_value(t, control_action_for_slot(.Play, 3), 7)
	testing.expect_value(t, control_action_for_slot(.Play, 4), 9)
	testing.expect_value(t, control_action_for_slot(.Play, 5), -1)
	testing.expect_value(t, control_slot_for_action(.Play, 3), 0)
	testing.expect_value(t, control_slot_for_action(.Play, 4), 1)
	testing.expect_value(t, control_slot_for_action(.Play, 7), 3)
	testing.expect_value(t, control_slot_for_action(.Play, 8), 2)
	testing.expect_value(t, control_slot_for_action(.Play, 9), 4)
	testing.expect_value(t, control_slot_for_action(.Play, 0), -1)
}

@(test)
create_action_emphasis_follows_range_workflow_test :: proc(t: ^testing.T) {
	testing.expect(t, create_action_is_emphasized(.Start, false, false, false))
	testing.expect(t, create_action_is_emphasized(.End, false, false, false))
	testing.expect(t, !create_action_is_emphasized(.Save, false, false, false))

	testing.expect(t, !create_action_is_emphasized(.Start, true, false, false))
	testing.expect(t, create_action_is_emphasized(.End, true, false, false))

	testing.expect(t, create_action_is_emphasized(.Start, true, true, false))
	testing.expect(t, create_action_is_emphasized(.End, true, true, false))
	testing.expect(t, !create_action_is_emphasized(.Save, true, true, false))

	testing.expect(t, !create_action_is_emphasized(.Start, true, true, true))
	testing.expect(t, !create_action_is_emphasized(.End, true, true, true))
	testing.expect(t, create_action_is_emphasized(.Save, true, true, true))
}

@(test)
exercise_rename_modal_keeps_original_name_above_input_test :: proc(t: ^testing.T) {
	modal := exercise_rename_modal_rect_for_size(1100, 720)
	input := exercise_rename_input_rect(modal)
	cancel := exercise_rename_cancel_rect(modal)
	confirm := exercise_rename_confirm_rect(modal)
	original_name_bottom := modal.y + modal.h - 130
	testing.expect(t, original_name_bottom > input.y + input.h)
	testing.expect(t, input.y > cancel.y + cancel.h)
	testing.expect(t, input.y > confirm.y + confirm.h)
	testing.expect(t, cancel.x >= modal.x && cancel.x + cancel.w <= modal.x + modal.w)
	testing.expect(t, confirm.x >= modal.x && confirm.x + confirm.w <= modal.x + modal.w)
}

@(test)
exercise_metadata_modal_contains_rows_and_actions_test :: proc(t: ^testing.T) {
	modal := exercise_metadata_modal_rect_for_size(1100, 720)
	last_row := exercise_metadata_row_rect(modal, 9)
	close_button := exercise_metadata_close_rect(modal)
	source_button := exercise_metadata_source_rect(modal)
	testing.expect_value(t, modal.x + modal.w / 2, 550.0)
	testing.expect(t, last_row.y > close_button.y + close_button.h)
	testing.expect(t, last_row.y > source_button.y + source_button.h)
	testing.expect(t, close_button.x >= modal.x && close_button.x + close_button.w <= modal.x + modal.w)
	testing.expect(t, source_button.x >= modal.x && source_button.x + source_button.w <= modal.x + modal.w)
}

@(test)
command_v_routes_to_paste_test :: proc(t: ^testing.T) {
	NSEventModifierFlagCommand :: uint(1 << 20)
	testing.expect(t, is_paste_shortcut(9, NSEventModifierFlagCommand))
	testing.expect(t, !is_paste_shortcut(9, 0))
	testing.expect(t, !is_paste_shortcut(8, NSEventModifierFlagCommand))
}

@(test)
timeline_arrow_shortcuts_map_direction_and_modifier_step_test :: proc(t: ^testing.T) {
	delta, ok := timeline_scrub_delta(123, 0)
	testing.expect(t, ok)
	testing.expect_value(t, delta, -1.0)
	delta, ok = timeline_scrub_delta(124, 0)
	testing.expect(t, ok)
	testing.expect_value(t, delta, 1.0)
	delta, ok = timeline_scrub_delta(124, NSEventModifierFlagShift)
	testing.expect(t, ok)
	testing.expect_value(t, delta, 0.1)
	delta, ok = timeline_scrub_delta(123, NSEventModifierFlagCommand)
	testing.expect(t, ok)
	testing.expect_value(t, delta, -10.0)
	delta, ok = timeline_scrub_delta(
		124,
		NSEventModifierFlagCommand | NSEventModifierFlagShift,
	)
	testing.expect(t, ok)
	testing.expect_value(t, delta, 10.0)
	_, ok = timeline_scrub_delta(124, NSEventModifierFlagOption)
	testing.expect(t, !ok)
	_, ok = timeline_scrub_delta(124, NSEventModifierFlagControl)
	testing.expect(t, !ok)
	_, ok = timeline_scrub_delta(125, 0)
	testing.expect(t, !ok)
}

@(test)
control_backspace_routes_to_word_deletion_test :: proc(t: ^testing.T) {
	NSEventModifierFlagControl :: uint(1 << 18)
	testing.expect(t, is_delete_word_shortcut(51, NSEventModifierFlagControl))
	testing.expect(t, !is_delete_word_shortcut(51, 0))
	testing.expect(t, !is_delete_word_shortcut(117, NSEventModifierFlagControl))
}

@(test)
activity_spinner_advances_and_wraps_test :: proc(t: ^testing.T) {
	testing.expect_value(t, activity_spinner(0), "|")
	testing.expect_value(t, activity_spinner(8), "/")
	testing.expect_value(t, activity_spinner(16), "-")
	testing.expect_value(t, activity_spinner(24), "\\")
	testing.expect_value(t, activity_spinner(32), "|")
}

@(test)
download_progress_uses_latest_complete_progress_line_test :: proc(t: ^testing.T) {
	status, ok := download_progress_status("noise\nVT_PROGRESS| 12.5%|80.0MiB|4.0MiB/s|00:18\nVT_PROGRESS| 25.0%|80.0MiB|5.0MiB/s|00:12\n")
	testing.expect(t, ok)
	testing.expect_value(t, status, "Downloading 25.0% / 80.0MiB / 5.0MiB/s / ETA 00:12")
	_, ok = download_progress_status("noise only")
	testing.expect(t, !ok)
}

@(test)
source_probe_lists_unique_available_heights_and_defaults_to_1080p_test :: proc(t: ^testing.T) {
	formats := []Source_Probe_Format_JSON{{height=2160, vcodec="avc1", ext="mp4"}, {height=1080, vcodec="avc1", ext="mp4"}, {height=1080, vcodec="vp9", ext="webm"}, {height=720, vcodec="avc1", ext="mp4"}, {height=0, vcodec="none", ext="m4a"}}
	heights := source_probe_heights(formats)
	defer delete(heights)
	testing.expect_value(t, len(heights), 3)
	testing.expect_value(t, heights[0], 720)
	testing.expect_value(t, heights[1], 1080)
	testing.expect_value(t, heights[2], 2160)
	testing.expect_value(t, source_probe_default_height(heights[:]), 1080)
}

@(test)
source_probe_ready_accepts_duplicate_video_urls_with_distinct_timestamps_test :: proc(t: ^testing.T) {
	old_results := source_probe_results
	defer {source_probe_results = old_results}
	source_probe_results = make([dynamic]Source_Probe_Result)
	defer source_probe_results_clear()
	append(&source_probe_results, Source_Probe_Result{video_id=strings.clone("KfnxccMdi-A")})
	input := "https://youtu.be/KfnxccMdi-A?t=321\nhttps://youtu.be/KfnxccMdi-A?t=449"
	testing.expect(t, source_probe_ready(input))
}

@(test)
source_probe_cache_uses_video_id_across_timestamp_urls_test :: proc(t: ^testing.T) {
	old_cache := source_probe_cache
	defer {source_probe_cache = old_cache}
	source_probe_cache = make([dynamic]Source_Probe_Result)
	defer source_probe_cache_clear()
	result := Source_Probe_Result{
		url = "https://youtu.be/KfnxccMdi-A?t=321",
		video_id = "KfnxccMdi-A",
		title = "Exercise",
		selected_height = 1080,
	}
	result.heights = make([dynamic]int)
	defer delete(result.heights)
	append(&result.heights, 720, 1080)
	source_probe_cache_store(result)
	testing.expect_value(t, len(source_probe_cache), 1)
	copy := source_probe_result_clone(source_probe_cache[0])
	defer source_probe_result_destroy(&copy)
	testing.expect_value(t, copy.video_id, "KfnxccMdi-A")
	testing.expect_value(t, copy.selected_height, 1080)
	testing.expect_value(t, len(copy.heights), 2)
}

@(test)
source_modal_input_expands_for_three_lines_test :: proc(t: ^testing.T) {
	modal := UI_Rect{100, 100, 980, 680}
	input := source_modal_input_rect_for_text(modal, "one\ntwo\nthree")
	row := UI_Rect{modal.x + 24, input.y - 70, modal.w - 48, 62}
	testing.expect_value(t, input.h, 78.0)
	testing.expect(t, row.y + row.h < input.y)
}

@(test)
source_modal_input_expands_when_enter_creates_an_empty_line_test :: proc(t: ^testing.T) {
	modal := UI_Rect{100, 100, 980, 680}
	testing.expect_value(t, source_modal_input_rect_for_text(modal, "one\n").h, 55.0)
}

@(test)
source_modal_input_shows_ten_lines_before_scrolling_test :: proc(t: ^testing.T) {
	modal := UI_Rect{100, 100, 980, 680}
	ten_lines_height := source_modal_input_rect_for_text(modal, "1\n2\n3\n4\n5\n6\n7\n8\n9\n10").h
	testing.expect_value(t, ten_lines_height, 239.0)
	testing.expect_value(t, source_modal_input_rect_for_text(modal, "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11").h, ten_lines_height)
}

@(test)
download_format_selector_applies_the_selected_height_to_every_fallback_test :: proc(t: ^testing.T) {
	selector := download_format_selector(1440)
	testing.expect_value(t, strings.count(selector, "height<=1440"), 2)
	testing.expect_value(t, strings.count(selector, "vcodec^=avc1"), 2)
	testing.expect(t, strings.contains(selector, "ba[ext=m4a]"))
}

@(test)
existing_source_timestamp_reports_a_position_update_test :: proc(t: ^testing.T) {
	testing.expect_value(t, import_success_status(0, 1, 1, 321), "Added timestamp 00:05:21 to the existing source")
	testing.expect_value(t, import_success_status(0, 1, 0), "1 source already in the register")
	testing.expect_value(t, import_success_status(2, 1, 1, 90), "Imported 2 sources; added timestamp 00:01:30 to an existing source")
}

@(test)
source_hint_values_sort_and_selection_promotes_the_chosen_value_test :: proc(t: ^testing.T) {
	hints := []Import_Hint{{source_id="a", seconds=90}, {source_id="b", seconds=20}, {source_id="a", seconds=15}, {source_id="a", seconds=45}}
	values := sorted_hint_values(hints, "a")
	defer delete(values)
	testing.expect_value(t, len(values), 3)
	testing.expect_value(t, values[0], 15.0)
	testing.expect_value(t, values[1], 45.0)
	testing.expect_value(t, values[2], 90.0)
	testing.expect(t, promote_source_hint(hints, "a", 45))
	testing.expect_value(t, hints[len(hints) - 1].source_id, "a")
	testing.expect_value(t, hints[len(hints) - 1].seconds, 45.0)
	testing.expect(t, !promote_source_hint(hints, "a", 999))
}

@(test)
source_hint_menu_places_every_timestamp_in_a_distinct_row_above_the_control_test :: proc(t: ^testing.T) {
	player := UI_Rect{308, 306, 480, 310}
	button := source_reset_rect(player)
	count := 5
	previous := source_hint_option_rect(player, 0, count)
	testing.expect(t, previous.y > button.y + button.h)
	for index in 1 ..< count {
		current := source_hint_option_rect(player, index, count)
		testing.expect(t, current.y + current.h < previous.y)
		previous = current
	}
}

@(test)
source_hint_control_changes_from_none_to_reset_to_menu_test :: proc(t: ^testing.T) {
	testing.expect_value(t, source_hint_control(0), Source_Hint_Control.None)
	testing.expect_value(t, source_hint_control(1), Source_Hint_Control.Reset)
	testing.expect_value(t, source_hint_control(2), Source_Hint_Control.Menu)
}

@(test)
mode_button_stays_inside_the_header_test :: proc(t: ^testing.T) {
	rect := mode_button_rect_for_size(1100, 720)
	header := app_header_rect_for_size(1100, 720)
	testing.expect(t, rect.x >= 18)
	testing.expect(t, rect.x+rect.w <= 1100-18)
	testing.expect(t, rect.y >= header.y)
	testing.expect(t, rect.y+rect.h <= 720)
	testing.expect(t, contains(header, Point{rect.x,rect.y}))
	testing.expect(t, contains(header, Point{rect.x+rect.w,rect.y+rect.h}))
	testing.expect(t, rect.x > 1100/2)
}

@(test)
source_header_add_action_stays_inside_panel_test :: proc(t: ^testing.T) {
	panel := UI_Rect{12, 80, 350, 560}
	add := source_add_button_rect(panel)
	testing.expect(t, add.x >= panel.x)
	testing.expect(t, add.y >= panel.y)
	testing.expect(t, add.x+add.w <= panel.x+panel.w)
	testing.expect(t, add.y+add.h <= panel.y+panel.h)
	testing.expect(t, add.x > panel.x+panel.w/2)
}

@(test)
source_modal_is_centered_and_contains_its_controls_test :: proc(t: ^testing.T) {
	modal := source_modal_rect_for_size(1100, 720)
	input := source_modal_input_rect(modal)
	cancel := source_modal_cancel_rect(modal)
	confirm := source_modal_confirm_rect(modal)
	testing.expect_value(t, modal.x+modal.w/2, 550.0)
	testing.expect_value(t, modal.y+modal.h/2, 360.0)
	testing.expect(t, input.x >= modal.x && input.x+input.w <= modal.x+modal.w)
	testing.expect(t, cancel.y >= modal.y && cancel.y+cancel.h <= modal.y+modal.h)
	testing.expect(t, confirm.x >= modal.x && confirm.x+confirm.w <= modal.x+modal.w)
}

@(test)
source_details_is_centered_and_contains_its_controls_test :: proc(t: ^testing.T) {
	modal := source_details_rect_for_size(1100, 720)
	close_button := source_details_close_rect(modal)
	refetch_button := source_details_refetch_rect(modal)
	last_row := source_details_row_rect(modal, 8)
	testing.expect_value(t, modal.x+modal.w/2, 550.0)
	testing.expect_value(t, modal.y+modal.h/2, 360.0)
	testing.expect(t, close_button.x >= modal.x && close_button.x+close_button.w <= modal.x+modal.w)
	testing.expect(t, refetch_button.x >= modal.x && refetch_button.x+refetch_button.w <= modal.x+modal.w)
	testing.expect(t, last_row.y >= modal.y && last_row.y+last_row.h <= modal.y+modal.h)
}

@(test)
source_timeline_maps_and_clamps_pointer_position_test :: proc(t: ^testing.T) {
	timeline := UI_Rect{100, 20, 400, 18}
	testing.expect_value(t, timeline_seconds_at_point(Point{100, 25}, timeline, 200), 0.0)
	testing.expect_value(t, timeline_seconds_at_point(Point{300, 25}, timeline, 200), 100.0)
	testing.expect_value(t, timeline_seconds_at_point(Point{600, 25}, timeline, 200), 200.0)
}

@(test)
source_and_exercise_id_lookups_return_stable_indices_test :: proc(t: ^testing.T) {
	sources := []Source_Video{{id="source-a"}, {id="source-b"}}
	exercises := []Exercise{{id="exercise-a"}, {id="exercise-b"}}
	testing.expect_value(t, source_index_for_id(sources, "source-b"), 1)
	testing.expect_value(t, source_index_for_id(sources, "missing"), -1)
	testing.expect_value(t, exercise_index_for_id(exercises, "exercise-a"), 0)
	testing.expect_value(t, exercise_index_for_id(exercises, "missing"), -1)
	linked_exercises := []Exercise{{source_id="source-b"}, {source_id="missing"}}
	testing.expect_value(t, source_index_for_exercise(sources, linked_exercises, 0), 1)
	testing.expect_value(t, source_index_for_exercise(sources, linked_exercises, 1), -1)
	testing.expect_value(t, source_index_for_exercise(sources, linked_exercises, 2), -1)
}

@(test)
rename_exercise_updates_memory_and_database_test :: proc(t: ^testing.T) {
	database: ^SQLite_DB
	path := strings.clone_to_cstring(":memory:")
	defer delete(path)
	opened := sqlite3_open_v2(path, &database, SQLITE_OPEN_READWRITE|SQLITE_OPEN_CREATE, nil) == SQLITE_OK
	testing.expect(t, opened)
	if !opened {return}
	defer sqlite3_close(database)
	testing.expect(t, database_create_schema(database))

	previous_state := state
	previous_ui := ui
	previous_database := library_database
	previous_fallback := library_legacy_fallback
	state = {}
	state.sources = make([dynamic]Source_Video)
	state.hints = make([dynamic]Import_Hint)
	state.exercises = make([dynamic]Exercise)
	defer {
		for &source in state.sources {delete_source_video(&source)}
		for &hint in state.hints {delete_import_hint(&hint)}
		for &exercise in state.exercises {delete_exercise(&exercise)}
		delete(state.sources)
		delete(state.hints)
		delete(state.exercises)
		transcript_generation_destroy(&state.transcripts)
		state = previous_state
		ui = previous_ui
		library_database = previous_database
		library_legacy_fallback = previous_fallback
	}
	source, source_copied := clone_source_video(Source_Video{
		id="source-1",
		video_id="video-1",
		title="Source",
		url="https://example.test/source",
		media_path="/tmp/source.mp4",
		duration=30,
	})
	testing.expect(t, source_copied)
	if !source_copied {return}
	append(&state.sources, source)
	exercise, exercise_copied := clone_exercise(Exercise{
		id="exercise-1",
		source_id="source-1",
		name="Original",
		start_seconds=2,
		end_seconds=8,
		clip_path="/tmp/exercise.mp4",
	})
	testing.expect(t, exercise_copied)
	if !exercise_copied {return}
	append(&state.exercises, exercise)
	library_database = database
	library_legacy_fallback = false

	testing.expect(t, rename_exercise(0, "  Renamed  "))
	testing.expect_value(t, state.exercises[0].name, "Renamed")
	statement, prepared := sqlite_prepare(database, "SELECT name FROM exercises WHERE id = 'exercise-1'")
	testing.expect(t, prepared)
	if !prepared {return}
	defer sqlite3_finalize(statement)
	testing.expect_value(t, sqlite3_step(statement), SQLITE_ROW)
	stored_name := sqlite3_column_text(statement, 0)
	testing.expect(t, stored_name != nil)
	if stored_name != nil {testing.expect_value(t, string(stored_name), "Renamed")}
}

@(test)
player_transport_and_timeline_stay_inside_player_test :: proc(t: ^testing.T) {
	player := UI_Rect{300, 100, 1000, 360}
	controls := [11]UI_Rect {
		source_play_pause_rect(player),
		source_stop_rect(player),
		source_reset_rect(player),
		source_speed_down_rect(player),
		source_speed_value_rect(player),
		source_speed_up_rect(player),
		source_volume_down_rect(player),
		source_volume_value_rect(player),
		source_volume_up_rect(player),
		source_timestamp_rect(player),
		source_timeline_rect(player),
	}
	for rect in controls {
		testing.expect(t, rect.x >= player.x && rect.x+rect.w <= player.x+player.w)
		testing.expect(t, rect.y >= player.y && rect.y+rect.h <= player.y+player.h)
	}
}

@(test)
transcript_search_ranks_matches_and_returns_original_indices_test :: proc(t: ^testing.T) {
	search: match_sorter.Search_Context
	testing.expect(t, match_sorter.search_context_init(&search) == nil)
	defer match_sorter.search_context_destroy(&search)
	segments := []Transcript_Segment{
		{source_id="a", text="voice warmup routine"},
		{source_id="a", text="warmup"},
	}
	indices := transcript_ranked_indices(&search, segments, 4, "warmup")
	defer delete(indices)
	testing.expect_value(t, len(indices), 2)
	testing.expect_value(t, indices[0], 5)
	testing.expect_value(t, indices[1], 4)
	missing := transcript_ranked_indices(&search, segments, 4, "zzzz")
	defer delete(missing)
	testing.expect_value(t, len(missing), 0)
}

@(test)
empty_transcript_search_keeps_active_source_in_chronological_order_test :: proc(t: ^testing.T) {
	search: match_sorter.Search_Context
	testing.expect(t, match_sorter.search_context_init(&search) == nil)
	defer match_sorter.search_context_destroy(&search)
	segments := []Transcript_Segment{
		{source_id="a", text="first"},
		{source_id="a", text="second"},
	}
	indices := transcript_ranked_indices(&search, segments, 8, "")
	defer delete(indices)
	testing.expect_value(t, len(indices), 2)
	testing.expect_value(t, indices[0], 8)
	testing.expect_value(t, indices[1], 9)
}

@(test)
transcript_playback_uses_latest_starting_overlapping_segment_test :: proc(t: ^testing.T) {
	segments := []Transcript_Segment{
		{id="a-1", source_id="a", start_seconds=1, duration_seconds=6},
		{id="a-2", source_id="a", start_seconds=4, duration_seconds=5},
		{id="b-1", source_id="b", start_seconds=5, duration_seconds=5},
	}
	match_index, progress, found := transcript_playback_match([]int{0, 1, 2}, segments, "a", 5)
	testing.expect(t, found)
	testing.expect_value(t, match_index, 1)
	testing.expect_value(t, progress, 0.2)
}

@(test)
transcript_playback_uses_half_open_ranges_and_skips_gaps_test :: proc(t: ^testing.T) {
	segments := []Transcript_Segment{
		{id="a-1", source_id="a", start_seconds=1, duration_seconds=2},
		{id="a-2", source_id="a", start_seconds=4, duration_seconds=0},
	}
	match_index, progress, found := transcript_playback_match([]int{0, 1}, segments, "a", 1)
	testing.expect(t, found)
	testing.expect_value(t, match_index, 0)
	testing.expect_value(t, progress, 0.0)
	_, _, found = transcript_playback_match([]int{0, 1}, segments, "a", 3)
	testing.expect(t, !found)
	_, _, found = transcript_playback_match([]int{0, 1}, segments, "a", 4)
	testing.expect(t, !found)
}

@(test)
transcript_centered_scroll_clamps_first_and_last_rows_test :: proc(t: ^testing.T) {
	testing.expect_value(t, transcript_centered_scroll(0, 20, 100), 0.0)
	testing.expect_value(t, transcript_centered_scroll(10, 20, 100), 222.5)
	testing.expect_value(t, transcript_centered_scroll(19, 20, 100), 419.0)
}

@(test)
transcript_follow_respects_search_and_manual_suspension_test :: proc(t: ^testing.T) {
	testing.expect(t, transcript_follow_should_center(true, false, false, false, true))
	testing.expect(t, transcript_follow_should_center(false, true, false, false, true))
	testing.expect(t, !transcript_follow_should_center(false, true, true, false, true))
	testing.expect(t, !transcript_follow_should_center(true, true, false, true, true))
	testing.expect(t, !transcript_follow_should_center(true, true, false, false, false))
}

@(test)
transcript_search_field_sits_between_header_and_results_test :: proc(t: ^testing.T) {
	transcript := UI_Rect{308, 116, 480, 220}
	search := transcript_search_rect(transcript)
	content := transcript_content_rect(transcript)
	testing.expect(t, search.y > content.y + content.h)
	testing.expect(t, search.y + search.h < transcript.y + transcript.h)
}

@(test)
text_input_key_classification_test :: proc(t: ^testing.T) {
	testing.expect(t, text_event_is_insertable("adele"))
	testing.expect(t, text_event_is_insertable("café"))
	testing.expect(t, text_event_is_insertable("Α"))
	testing.expect(t, !text_event_is_insertable(""))
	testing.expect(t, !text_event_is_insertable("\t"))
	testing.expect(t, !text_event_is_insertable("\n"))
	// NSLeftArrowFunctionKey = U+F702
	testing.expect(t, !text_event_is_insertable("\uF702"))
	testing.expect(t, !text_event_is_insertable("\uF700"))

	testing.expect(t, is_paste_shortcut(9, NSEventModifierFlagCommand))
	testing.expect(t, !is_paste_shortcut(0, NSEventModifierFlagCommand))
	testing.expect(t, is_delete_word_shortcut(51, NSEventModifierFlagControl))
	testing.expect(t, !is_delete_word_shortcut(51, 0))

	// Ordinary letter, Return, Tab, and arrows all defer to AppKit.
	testing.expect_value(t, dispose_focused_text_key(0, 0), Text_Input_Key_Disposition.Interpret)
	testing.expect_value(t, dispose_focused_text_key(36, 0), Text_Input_Key_Disposition.Interpret)
	testing.expect_value(t, dispose_focused_text_key(48, 0), Text_Input_Key_Disposition.Interpret)
	testing.expect_value(t, dispose_focused_text_key(123, 0), Text_Input_Key_Disposition.Interpret)
	testing.expect_value(t, dispose_focused_text_key(126, 0), Text_Input_Key_Disposition.Interpret)
	testing.expect_value(t, dispose_focused_text_key(117, 0), Text_Input_Key_Disposition.Interpret)
	testing.expect_value(
		t,
		dispose_focused_text_key(0, NSEventModifierFlagCommand),
		Text_Input_Key_Disposition.Interpret,
	)
	testing.expect_value(
		t,
		dispose_focused_text_key(51, NSEventModifierFlagControl),
		Text_Input_Key_Disposition.Delete_Word,
	)
}

@(test)
text_input_ranges_count_utf16_code_units_test :: proc(t: ^testing.T) {
	testing.expect_value(t, utf16_index_for_byte_offset("abc", len("abc")), 3)
	testing.expect_value(t, utf16_index_for_byte_offset("café", len("café")), 4)
	testing.expect_value(t, utf16_index_for_byte_offset("A😀B", len("A😀B")), 4)
	testing.expect_value(t, byte_offset_for_utf16_index("A😀B", 3), len("A😀"))
}

@(test)
text_caret_offsets_follow_utf8_character_boundaries_test :: proc(t: ^testing.T) {
	text := "A😀B"
	testing.expect_value(t, next_character_offset(text, 1), len("A😀"))
	testing.expect_value(t, previous_character_offset(text, len("A😀")), 1)
	testing.expect_value(t, next_character_offset(text, len(text)), len(text))
	testing.expect_value(t, previous_character_offset(text, 0), 0)
}

@(test)
text_caret_line_boundaries_test :: proc(t: ^testing.T) {
	text := "first\nsecond\nthird"
	offset := strings.index(text, "cond")
	testing.expect_value(t, line_start_for_offset(text, offset), len("first\n"))
	testing.expect_value(t, line_end_for_offset(text, offset), len("first\nsecond"))
}

@(test)
source_search_matches_title_and_video_id_without_case_test :: proc(t: ^testing.T) {
	source := Source_Video{title="Appoggio Breathing", video_id="AbC123XyZ"}
	testing.expect(t, source_matches_search(source, "APPOGGIO"))
	testing.expect(t, source_matches_search(source, "abc123"))
	testing.expect(t, !source_matches_search(source, "falsetto"))
}

@(test)
flash_leader_starts_only_without_text_focus_test :: proc(t: ^testing.T) {
	testing.expect(t, flash_leader_allowed(.None, 0, "/"))
	testing.expect(t, !flash_leader_allowed(.Source_Search, 0, "/"))
	testing.expect(t, !flash_leader_allowed(.None, NSEventModifierFlagCommand, "/"))
	testing.expect(t, !flash_leader_allowed(.None, NSEventModifierFlagOption, "/"))
	testing.expect(t, !flash_leader_allowed(.None, 0, "a"))
}

@(test)
escape_unfocuses_each_text_input_kind_test :: proc(t: ^testing.T) {
	testing.expect(t, !escape_should_unfocus(.None))
	testing.expect(t, escape_should_unfocus(.URL))
	testing.expect(t, escape_should_unfocus(.Source_Search))
	testing.expect(t, escape_should_unfocus(.Transcript_Search))
	testing.expect(t, escape_should_unfocus(.Exercise_Search))
	testing.expect(t, escape_should_unfocus(.Exercise_Name))
}

@(test)
flash_badges_use_opposite_anchors_for_shared_targets_test :: proc(t: ^testing.T) {
	target_rect := flash.Rect{10, 20, 100, 30}
	left := flash_badge_rect(
		flash.Target{label = "play", rect = target_rect, anchor = .Top_Left},
		2,
		200,
		100,
	)
	right := flash_badge_rect(
		flash.Target{label = "play", rect = target_rect, anchor = .Top_Right},
		2,
		200,
		100,
	)
	testing.expect(t, left.x < right.x)
	testing.expect_value(t, left.y, right.y)
	testing.expect_value(t, left.w, 24.0)
}

@(test)
flash_badges_clamp_to_the_view_test :: proc(t: ^testing.T) {
	badge := flash_badge_rect(
		flash.Target{label = "play", rect = {-20, -10, 8, 8}, anchor = .Bottom_Left},
		1,
		100,
		100,
	)
	testing.expect_value(t, badge.x, 0.0)
	testing.expect_value(t, badge.y, 0.0)
	testing.expect_value(t, badge.w, 16.0)
}

@(test)
flash_functional_labels_produce_compact_control_mnemonics_test :: proc(t: ^testing.T) {
	jump: flash.State
	flash.state_init(&jump)
	defer flash.state_destroy(&jump)
	targets := []flash.Target{
		{id = 1, label = "play pause source", rect = {0, 0, 10, 10}},
		{id = 2, label = "search timed transcript", rect = {0, 0, 10, 10}},
		{id = 3, label = "set start", rect = {0, 0, 10, 10}},
		{id = 4, label = "set end", rect = {0, 0, 10, 10}},
		{id = 5, label = "run", rect = {0, 0, 10, 10}},
	}
	testing.expect_value(t, flash.begin(&jump, targets), flash.Begin_Error.None)
	hints := flash.visible_hints(&jump)
	testing.expect_value(t, hints[0].label, "pl")
	testing.expect_value(t, hints[1].label, "sa")
	testing.expect_value(t, hints[2].label, "sts")
	testing.expect_value(t, hints[3].label, "ste")
	testing.expect_value(t, hints[4].label, "ru")
}

@(test)
flash_target_label_replaces_a_name_without_input_characters_test :: proc(t: ^testing.T) {
	control := UI_Control{
		functional_name = "♪",
		action = {
			kind = .Transcript,
			index = 7,
		},
	}
	label := flash_target_label(&control)
	testing.expect(t, flash.label_is_valid(label))
	testing.expect(t, strings.contains(label, "Transcript"))

	jump: flash.State
	flash.state_init(&jump)
	defer flash.state_destroy(&jump)
	targets := []flash.Target{{id = 1, label = label, rect = {0, 0, 10, 10}}}
	testing.expect_value(t, flash.begin(&jump, targets), flash.Begin_Error.None)
	testing.expect(t, flash.is_active(&jump))
}

@(test)
ui_control_identifiers_are_stable_and_name_derived_test :: proc(t: ^testing.T) {
	first := ui_control_id("select source source-42")
	second := ui_control_id("select source source-42")
	other := ui_control_id("source details source-42")
	testing.expect_value(t, first, second)
	testing.expect(t, first != other)
	testing.expect(t, first != 0)
}

@(test)
ui_control_validation_rejects_duplicate_names_and_identifiers_test :: proc(t: ^testing.T) {
	valid := []UI_Control{
		{
			id = ui_control_id("first control"),
			functional_name = "first control",
			rect = {0, 0, 20, 20},
		},
		{
			id = ui_control_id("second control"),
			functional_name = "second control",
			rect = {20, 0, 20, 20},
		},
	}
	testing.expect(t, ui_controls_valid(valid))

	duplicate := make([]UI_Control, len(valid))
	defer delete(duplicate)
	copy(duplicate, valid)
	duplicate[1].id = duplicate[0].id
	testing.expect(t, !ui_controls_valid(duplicate))
	duplicate[1].id = ui_control_id(duplicate[1].functional_name)
	duplicate[1].functional_name = duplicate[0].functional_name
	testing.expect(t, !ui_controls_valid(duplicate))
}

@(test)
ui_background_comparison_accepts_disabling_and_rejects_structural_changes_test :: proc(
	t: ^testing.T,
) {
	enabled_flags := ui_diagnostic_flags(
		UI_Control_Flags{.Accessibility, .Enabled, .Flash, .Primary_Press},
	)
	disabled_flags := ui_diagnostic_flags(UI_Control_Flags{.Accessibility})
	baseline_controls := []UI_Diagnostic_Control{
		{
			id = 1,
			functional_name = "save exercise",
			action_kind = "Save",
			rect = {x=10, y=20, w=30, h=40},
			flags = enabled_flags,
			accessibility_role = "AXButton",
		},
	}
	current_controls := []UI_Diagnostic_Control{
		{
			id = 1,
			functional_name = "save exercise",
			action_kind = "Save",
			rect = {x=10, y=20, w=30, h=40},
			flags = disabled_flags,
			accessibility_role = "AXButton",
		},
		{
			id = 2,
			functional_name = "stop download",
			action_kind = "Stop_Download",
			rect = {x=50, y=20, w=30, h=40},
			flags = enabled_flags,
			accessibility_role = "AXButton",
		},
	}
	baseline := UI_Diagnostic_Snapshot{
		schema_version = UI_DIAGNOSTIC_SCHEMA_VERSION,
		process_id = 10,
		frame = 1,
		surface = {mode="create", overlay="none", background="none"},
		controls = baseline_controls,
	}
	current := UI_Diagnostic_Snapshot{
		schema_version = UI_DIAGNOSTIC_SCHEMA_VERSION,
		process_id = 10,
		frame = 2,
		surface = {mode="create", overlay="none", background="import"},
		controls = current_controls,
	}
	diff := ui_diagnostic_compare_background(baseline, current, context.temp_allocator)
	testing.expect(t, diff.ok)
	testing.expect_value(t, diff.retained_count, 1)
	testing.expect_value(t, len(diff.added), 1)
	testing.expect_value(t, len(diff.disabled), 1)

	moved_controls := make([]UI_Diagnostic_Control, len(current_controls), context.temp_allocator)
	copy(moved_controls, current_controls)
	moved_controls[0].rect.x += 1
	moved := current
	moved.controls = moved_controls
	moved_diff := ui_diagnostic_compare_background(
		baseline,
		moved,
		context.temp_allocator,
	)
	testing.expect(t, !moved_diff.ok)
	testing.expect_value(t, len(moved_diff.changed), 1)
	testing.expect_value(t, moved_diff.changed[0].reason, "rectangle")

	unexpected_controls := make(
		[]UI_Diagnostic_Control,
		len(current_controls) + 1,
		context.temp_allocator,
	)
	copy(unexpected_controls, current_controls)
	unexpected_controls[len(current_controls)] = UI_Diagnostic_Control{
		id = 3,
		functional_name = "surprise control",
		action_kind = "Save",
		rect = {x=90, y=20, w=30, h=40},
		flags = enabled_flags,
		accessibility_role = "AXButton",
	}
	unexpected := current
	unexpected.controls = unexpected_controls
	unexpected_diff := ui_diagnostic_compare_background(
		baseline,
		unexpected,
		context.temp_allocator,
	)
	testing.expect(t, !unexpected_diff.ok)
	testing.expect_value(t, len(unexpected_diff.unexpected), 1)
}

@(test)
ui_control_hit_test_uses_visual_stack_and_capabilities_test :: proc(t: ^testing.T) {
	controls := []UI_Control{
		{
			id = ui_control_id("player surface"),
			functional_name = "player surface",
			rect = {0, 0, 100, 100},
			flags = {.Primary_Press, .Enabled},
			action = {kind = .Player_Surface},
		},
		{
			id = ui_control_id("timeline"),
			functional_name = "timeline",
			rect = {0, 0, 100, 20},
			flags = {.Primary_Press, .Drag, .Enabled},
			action = {kind = .Source_Timeline},
		},
	}
	hit := find_ui_control_at_point(controls, Point{50, 10}, .Primary_Press)
	testing.expect(t, hit != nil)
	if hit != nil {testing.expect_value(t, hit.action.kind, UI_Action_Kind.Source_Timeline)}
	testing.expect(t, find_ui_control_at_point(controls, Point{50, 50}, .Drag) == nil)
}

@(test)
ui_flash_dynamic_identifiers_do_not_expose_synthetic_suffixes_test :: proc(t: ^testing.T) {
	controls := []UI_Control{
		{
			id = ui_control_id("transcript segment source-1"),
			functional_name = "transcript segment source-1",
			flash_label = "transcript segment",
			rect = {0, 0, 20, 20},
		},
		{
			id = ui_control_id("transcript segment source-10"),
			functional_name = "transcript segment source-10",
			flash_label = "transcript segment",
			rect = {20, 0, 20, 20},
		},
	}
	targets := []flash.Target{
		{id = 1, label = flash_target_label(&controls[0]), rect = {0, 0, 20, 20}},
		{id = 2, label = flash_target_label(&controls[1]), rect = {20, 0, 20, 20}},
	}
	jump: flash.State
	flash.state_init(&jump)
	defer flash.state_destroy(&jump)
	testing.expect_value(t, flash.begin(&jump, targets), flash.Begin_Error.None)
	testing.expect(t, flash.is_active(&jump))
	for hint in flash.visible_hints(&jump) {
		testing.expect(t, len(hint.label) <= 3)
		testing.expect(t, !strings.contains(hint.label, "target"))
	}
	testing.expect_value(t, flash.consume(&jump, 't').kind, flash.Input_Result_Kind.Pending)
	testing.expect_value(t, flash.consume(&jump, 'r').kind, flash.Input_Result_Kind.Group_Selected)
}
