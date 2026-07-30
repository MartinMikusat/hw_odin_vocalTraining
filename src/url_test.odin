package main

import "core:testing"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import os2 "core:os/os2"
import "core:path/filepath"
import "core:strings"
import "core:time"
import "core:sys/posix"
import "base:runtime"
import mem_virtual "core:mem/virtual"
import command_palette "command_palette:."
import flash "flash:."
import match_sorter "match_sorter:."

@(test)
launch_activation_respects_background_policy_test :: proc(t: ^testing.T) {
	testing.expect(t, launch_should_activate(nil))
	testing.expect(t, !launch_should_activate(nil, true))
	testing.expect(t, launch_should_activate(cstring("1")))
	testing.expect(t, launch_should_activate(cstring("1"), true))
	testing.expect(t, !launch_should_activate(cstring("0")))
	testing.expect(t, !launch_should_activate(cstring("0"), true))
}

window_icon_points_use_iconoir_viewbox_test :: proc(
	t: ^testing.T,
	points: []Window_Icon_Point,
	path_length: int,
) {
	for point, index in points {
		testing.expect(t, point.point.x >= 0 && point.point.x <= 24)
		testing.expect(t, point.point.y >= 0 && point.point.y <= 24)
		testing.expect_value(t, point.move, index%path_length == 0)
	}
}

@(test)
window_icons_match_iconoir_paths_test :: proc(t: ^testing.T) {
	xmark := window_icon_xmark_points()
	testing.expect_value(t, len(xmark), 8)
	window_icon_points_use_iconoir_viewbox_test(t, xmark[:], 2)

	minus := window_icon_minus_points()
	testing.expect_value(t, len(minus), 2)
	window_icon_points_use_iconoir_viewbox_test(t, minus[:], 2)

	maximize := window_icon_maximize_points()
	testing.expect_value(t, len(maximize), 12)
	window_icon_points_use_iconoir_viewbox_test(t, maximize[:], 3)
}

@(test)
window_header_geometry_separates_controls_title_and_mode_test :: proc(
	t: ^testing.T,
) {
	height := 720.0
	close := window_control_rect_for_size(0, height)
	minimize := window_control_rect_for_size(1, height)
	zoom := window_control_rect_for_size(2, height)
	title := app_title_rect_for_size(1100, height)
	mode := mode_button_rect_for_size(1100, height)
	testing.expect_value(t, close, UI_Rect{0, 690, 30, 30})
	testing.expect_value(t, minimize, UI_Rect{38, 690, 30, 30})
	testing.expect_value(t, zoom, UI_Rect{76, 690, 30, 30})
	testing.expect_value(t, close.y+close.h, height)
	testing.expect(t, zoom.x+zoom.w < title.x)
	testing.expect(t, title.x+title.w < mode.x)
}

@(test)
window_header_identity_reports_each_active_view_test :: proc(t: ^testing.T) {
	testing.expect_value(
		t,
		active_view_label(.Vocal, .Create),
		"VOCAL SOURCES",
	)
	testing.expect_value(t, active_view_label(.Vocal, .Play), "VOCAL CLIPS")
	testing.expect_value(
		t,
		active_view_label(.Dancing, .Create),
		"DANCING SOURCES",
	)
	testing.expect_value(
		t,
		active_view_label(.Dancing, .Play),
		"DANCING CLIPS",
	)
	settings := settings_button_rect_for_size(720)
	title := app_title_rect_for_size(1100, 720)
	workflow := workflow_button_rect_for_size(1100, 720)
	testing.expect_value(t, title.x-(settings.x+settings.w), 16.0)
	testing.expect_value(t, workflow.x-(title.x+title.w), 12.0)
}

@(test)
window_header_mode_controls_describe_their_actions_test :: proc(t: ^testing.T) {
	testing.expect_value(
		t,
		workflow_switch_label(.Vocal),
		"SWITCH TO DANCING",
	)
	testing.expect_value(
		t,
		workflow_switch_label(.Dancing),
		"SWITCH TO VOCAL",
	)
	testing.expect_value(
		t,
		workspace_switch_label(.Create),
		"SWITCH TO CLIPS",
	)
	testing.expect_value(
		t,
		workspace_switch_label(.Play),
		"SWITCH TO SOURCES",
	)
}

@(test)
window_resize_geometry_detects_edges_and_enforces_minimum_test :: proc(
	t: ^testing.T,
) {
	testing.expect_value(
		t,
		window_resize_edges_for_size({550, 360}, 1100, 720),
		u8(0),
	)
	testing.expect_value(
		t,
		window_resize_edges_for_size({0, 360}, 1100, 720),
		u8(1),
	)
	testing.expect_value(
		t,
		window_resize_edges_for_size({1100, 360}, 1100, 720),
		u8(2),
	)
	testing.expect_value(
		t,
		window_resize_edges_for_size({550, 0}, 1100, 720),
		u8(4),
	)
	testing.expect_value(
		t,
		window_resize_edges_for_size({0, 720}, 1100, 720),
		u8(9),
	)

	start := Rect{{100, 200}, {1200, 800}}
	grown := window_frame_after_drag(start, u8(2|8), {100, 50})
	testing.expect_value(t, grown, Rect{{100, 200}, {1300, 850}})
	clamped := window_frame_after_drag(start, u8(1|4), {200, 200})
	testing.expect_value(t, clamped, Rect{{200, 280}, {1100, 720}})
}

@(test)
window_zoom_geometry_fills_and_restores_test :: proc(t: ^testing.T) {
	current := Rect{Point{200, 140}, Size{1200, 800}}
	visible := Rect{Point{0, 31}, Size{1920, 1049}}
	next, restore, has_restore := window_zoom_next_frame(
		current,
		visible,
		{},
		false,
	)
	testing.expect_value(t, next, visible)
	testing.expect_value(t, restore, current)
	testing.expect(t, has_restore)

	next, restore, has_restore = window_zoom_next_frame(
		next,
		visible,
		restore,
		has_restore,
	)
	testing.expect_value(t, next, current)
	testing.expect_value(t, restore, Rect{})
	testing.expect(t, !has_restore)
}

@(test)
window_controls_remain_registered_over_modal_content_test :: proc(
	t: ^testing.T,
) {
	previous_state := state
	previous_ui := ui
	previous_ui_build := ui_build
	previous_recovery := library_recovery_state
	previous_pending := major_change_pending
	defer {
		state = previous_state
		ui = previous_ui
		ui_build = previous_ui_build
		library_recovery_state = previous_recovery
		major_change_pending = previous_pending
	}
	state = App_State{active_source=-1}
	ui = UI_State{
		width = 1100,
		height = 720,
		mode = .Play,
		randomize_help_open = true,
		active_clip = -1,
		source_details_index = -1,
		source_modal_refetch_index = -1,
		clip_rename_index = -1,
		clip_metadata_index = -1,
		transcript_active_match = -1,
	}
	library_recovery_state = {}
	major_change_pending = {}

	frame_arena: mem_virtual.Arena
	frame_error := mem_virtual.arena_init_static(
		&frame_arena,
		1024*1024,
		4096,
	)
	testing.expect(t, frame_error == nil)
	if frame_error != nil {return}
	defer mem_virtual.arena_destroy(&frame_arena)
	build_ui_controls(false, mem_virtual.arena_allocator(&frame_arena))
	testing.expect(t, ui_controls_valid(ui_build.controls[:]))

	actions := [3]UI_Action_Kind{
		.Window_Close,
		.Window_Minimize,
		.Window_Zoom,
	}
	for action in actions {
		control := find_ui_control_by_action(action)
		testing.expect(t, control != nil)
		if control == nil {continue}
		testing.expect(t, .Primary_Press in control.flags)
		testing.expect(t, .Accessibility in control.flags)
		testing.expect(t, .Flash in control.flags)
		testing.expect(t, .Enabled in control.flags)
		testing.expect_value(t, control.accessibility_role, "AXButton")
	}
	testing.expect(t, find_ui_control_by_action(.Close_Randomize_Help) != nil)
}

@(test)
successful_clip_commit_resets_clip_output_test :: proc(t: ^testing.T) {
	previous_state := state
	previous_ui := ui
	defer {
		delete(ui.clip_name)
		state = previous_state
		ui = previous_ui
	}
	state = App_State{}
	ui = UI_State{}
	state.range_start = 12
	state.range_end = 18
	state.has_start = true
	state.has_end = true
	ui.focus = .None
	ui_set_string(&ui.clip_name, "Scale")
	reset_clip_output()
	testing.expect_value(t, state.range_start, 0)
	testing.expect_value(t, state.range_end, 0)
	testing.expect(t, !state.has_start)
	testing.expect(t, !state.has_end)
	testing.expect_value(t, ui.clip_name, "")
}

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
new_caption_generation_indexes_the_imported_source_test :: proc(t: ^testing.T) {
	support, found := os.lookup_env("HW_VIDEO_CLIPS_APP_SUPPORT_DIR")
	defer delete(support)
	testing.expect(t, found)
	if !found {return}
	source_directory := fmt.tprintf("%s/sources", support)
	os.make_directory(source_directory)
	caption_file := fmt.tprintf("%s/new-video.en.json3", source_directory)
	fixture := `{"events":[{"tStartMs":1250,"dDurationMs":750,"segs":[{"utf8":"Warm up"}]}]}`
	testing.expect(t, os.write_entire_file(caption_file, transmute([]byte)fixture))
	defer os.remove(caption_file)

	previous := [1]Transcript_Segment{{
		id="old-0",
		source_id="old",
		start_seconds=0,
		duration_seconds=1,
		text="Old",
	}}
	source := Source_Video{id="new", video_id="new-video"}
	generation, count, ok := build_transcript_generation(&source, previous[:])
	testing.expect(t, ok)
	if !ok {return}
	defer transcript_generation_destroy(&generation)
	testing.expect_value(t, count, 1)

	segments, base_index, found_source := transcript_source_segments(&generation, "new")
	testing.expect(t, found_source)
	testing.expect_value(t, base_index, 1)
	testing.expect_value(t, len(segments), 1)
	testing.expect_value(t, segments[0].text, "Warm up")
}

@(test)
media_helper_status_is_reused_after_the_first_check_test :: proc(t: ^testing.T) {
	previous := ffmpeg_helper_status
	defer {ffmpeg_helper_status = previous}
	ffmpeg_helper_status = Helper_Status{
		checked=true,
		available=true,
		reason="cached",
	}
	status := check_helper_once("ffmpeg")
	testing.expect(t, status == &ffmpeg_helper_status)
	testing.expect(t, status.available)
	testing.expect_value(t, status.reason, "cached")
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
	path, found := os.lookup_env("HW_VIDEO_CLIPS_TEST_LIBRARY")
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
	schema_version, schema_version_read :=
		library_database_user_version(database)
	testing.expect(t, schema_version_read)
	testing.expect_value(t, schema_version, LIBRARY_SCHEMA_VERSION)
	source_count, sources_counted := database_count(database, "sources")
	segment_count, segments_counted := database_count(database, "transcript_segments")
	hint_count, hints_counted := database_count(database, "import_hints")
	clip_count, clips_counted := database_count(database, "clips")
	testing.expect(t, sources_counted && segments_counted && hints_counted && clips_counted)
	testing.expect_value(t, source_count, 7)
	testing.expect_value(t, segment_count, 1532)
	testing.expect_value(t, hint_count, 12)
	testing.expect_value(t, clip_count, 1)

	loaded: App_State
	testing.expect(t, database_load_state(database, &loaded))
	defer {
		for &source in loaded.sources {delete_source_video(&source)}
		for &hint in loaded.hints {delete_import_hint(&hint)}
		for &clip in loaded.clips {delete_clip(&clip)}
		delete(loaded.sources)
		delete(loaded.hints)
		delete(loaded.clips)
		transcript_generation_destroy(&loaded.transcripts)
	}
	testing.expect_value(t, len(loaded.sources), source_count)
	testing.expect_value(t, len(loaded.transcripts.segments), segment_count)
	testing.expect_value(t, len(loaded.transcripts.source_spans), source_count)
	testing.expect_value(t, len(loaded.hints), hint_count)
	testing.expect_value(t, len(loaded.clips), clip_count)
	for source in loaded.sources {
		testing.expect_value(t, source.workflow, Workflow_Kind.Vocal)
	}
	for clip in loaded.clips {
		testing.expect_value(t, clip.workflow, Workflow_Kind.Vocal)
		testing.expect_value(t, clip.dance_count_in_bpm, 120)
		testing.expect_value(t, clip.dance_playback_rate, f32(1))
	}
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
	for clip in loaded.clips {
		source_found := false
		for source in loaded.sources {
			if source.id == clip.source_id {
				source_found = true
				break
			}
		}
		testing.expect(t, source_found)
		testing.expect(t, filepath.is_abs(clip.clip_path))
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
		for &clip in state.clips {delete_clip(&clip)}
		delete(state.sources)
		delete(state.hints)
		delete(state.clips)
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
	randomize := find_ui_control_by_action(.Randomize)
	randomize_help := find_ui_control_by_action(.Open_Randomize_Help)
	play_next := find_ui_control_by_action(.Play_Next)
	shuffle := find_ui_control_by_action(.Shuffle_Toggle)
	autoplay := find_ui_control_by_action(.Autoplay_Toggle)
	testing.expect(t, randomize != nil)
	testing.expect(t, randomize_help != nil)
	testing.expect(t, play_next != nil)
	testing.expect(t, shuffle != nil)
	testing.expect(t, autoplay != nil)
	if randomize != nil {
		testing.expect(t, .Enabled in randomize.flags)
		testing.expect_value(
			t,
			randomize.accessibility_label,
			"Play a random clip",
		)
		testing.expect_value(t, randomize.flash_label, "randomize clip")
	}
	if randomize != nil && randomize_help != nil {
		testing.expect(t, .Enabled in randomize_help.flags)
		testing.expect_value(
			t,
			randomize_help.accessibility_label,
			"Explain Randomize selection",
		)
		testing.expect_value(
			t,
			randomize_help.flash_label,
			"randomize help",
		)
		testing.expect_value(
			t,
			randomize.rect.x + randomize.rect.w,
			randomize_help.rect.x,
		)
		testing.expect_value(t, randomize.rect.y, randomize_help.rect.y)
		testing.expect_value(t, randomize.rect.h, randomize_help.rect.h)
		testing.expect_value(t, randomize_help.rect.w, randomize_help.rect.h)
	}
	if play_next != nil {
		testing.expect(t, .Enabled in play_next.flags)
		testing.expect_value(
			t,
			play_next.accessibility_label,
			"Play the next filtered clip",
		)
		testing.expect_value(t, play_next.flash_label, "play next clip")
	}
	if shuffle != nil {
		testing.expect(t, .Enabled in shuffle.flags)
		testing.expect_value(t, shuffle.accessibility_role, "AXCheckBox")
		testing.expect_value(t, shuffle.accessibility_label, "Shuffle off")
		testing.expect_value(t, shuffle.flash_label, "toggle shuffle")
	}
	if autoplay != nil {
		testing.expect(t, .Enabled in autoplay.flags)
		testing.expect_value(t, autoplay.accessibility_role, "AXCheckBox")
		testing.expect_value(t, autoplay.accessibility_label, "Autoplay off")
		testing.expect_value(t, autoplay.flash_label, "toggle autoplay")
	}
	randomize_registry_index, run_registry_index := -1, -1
	for control, index in ui_build.controls {
		if control.action.kind == .Randomize {
			randomize_registry_index = index
		}
		if control.action.kind == .Play {
			run_registry_index = index
		}
	}
	testing.expect(t, randomize_registry_index >= 0)
	testing.expect(t, run_registry_index >= 0)
	testing.expect(t, randomize_registry_index < run_registry_index)
	ui_build.controls = nil
	mem_virtual.arena_free_all(&frame_arena)

	ui.randomize_help_open = true
	build_ui_controls(false, frame_allocator)
	testing.expect(t, ui_controls_valid(ui_build.controls[:]))
	testing.expect_value(
		t,
		ui_build.diagnostic_surface.overlay,
		"randomize-help",
	)
	testing.expect(t, find_ui_control_by_action(.Close_Randomize_Help) != nil)
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
		for &clip in loaded.clips {delete_clip(&clip)}
		delete(loaded.sources); delete(loaded.hints); delete(loaded.clips)
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
notification_lifecycle_updates_one_persistent_record_test :: proc(t: ^testing.T) {
	database: ^SQLite_DB
	path := strings.clone_to_cstring(":memory:")
	defer delete(path)
	opened := sqlite3_open_v2(
		path,
		&database,
		SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE,
		nil,
	) == SQLITE_OK
	testing.expect(t, opened)
	if !opened {return}
	defer sqlite3_close(database)
	testing.expect(t, database_create_schema(database))

	notification_history_destroy()
	previous_database := library_database
	previous_fallback := library_legacy_fallback
	library_database = database
	library_legacy_fallback = false
	defer {
		notification_history_destroy()
		ui_set_string(&ui.status, "")
		ui_set_string(&ui.status_source_video_id, "")
		library_database = previous_database
		library_legacy_fallback = previous_fallback
	}
	notification_history_initialize()
	fields := [2]Notification_Field{
		{label="Operation", value="Test import"},
		{label="Phase", value="Preparing"},
	}
	id := notification_begin("Preparing import", "Test detail", fields[:])
	fields[1].value = "Downloading"
	testing.expect(t, notification_update(
		id,
		"Downloading 50%",
		fields=fields[:],
		persist_now=true,
	))
	testing.expect(t, notification_finish(
		id,
		.Success,
		"Import complete",
		action_kind=.View_Source,
		action_target="video-1",
	))
	count, counted := database_count(database, "notifications")
	testing.expect(t, counted)
	testing.expect_value(t, count, 1)
	statement, prepared := sqlite_prepare(
		database,
		"SELECT kind, summary, action_kind, action_target FROM notifications",
	)
	testing.expect(t, prepared)
	if !prepared {return}
	defer sqlite3_finalize(statement)
	testing.expect_value(t, sqlite3_step(statement), SQLITE_ROW)
	testing.expect_value(
		t,
		Notification_Kind(sqlite3_column_int(statement, 0)),
		Notification_Kind.Success,
	)
	summary := sqlite3_column_text(statement, 1)
	testing.expect(t, summary != nil)
	if summary != nil {testing.expect_value(t, string(summary), "Import complete")}
	testing.expect_value(
		t,
		Notification_Action_Kind(sqlite3_column_int(statement, 2)),
		Notification_Action_Kind.View_Source,
	)
	target := sqlite3_column_text(statement, 3)
	testing.expect(t, target != nil)
	if target != nil {testing.expect_value(t, string(target), "video-1")}
	testing.expect_value(t, len(notification_history.entries), 1)
	testing.expect_value(t, len(notification_history.entries[0].fields), 2)

	notification_history_destroy()
	notification_history_initialize()
	testing.expect_value(t, len(notification_history.entries), 1)
	if len(notification_history.entries) == 1 {
		reloaded := &notification_history.entries[0]
		testing.expect_value(t, reloaded.summary, "Import complete")
		testing.expect_value(t, reloaded.action_kind, Notification_Action_Kind.View_Source)
		testing.expect_value(t, reloaded.action_target, "video-1")
		testing.expect_value(t, len(reloaded.fields), 2)
		if len(reloaded.fields) == 2 {
			testing.expect_value(t, reloaded.fields[1].label, "Phase")
			testing.expect_value(t, reloaded.fields[1].value, "Downloading")
		}
	}
}

@(test)
concurrent_notifications_remove_completed_tasks_without_hiding_siblings_test :: proc(
	t: ^testing.T,
) {
	notification_history_destroy()
	previous_database := library_database
	previous_fallback := library_legacy_fallback
	library_database = nil
	library_legacy_fallback = true
	defer {
		notification_history_destroy()
		ui_set_string(&ui.status, "")
		ui_set_string(&ui.status_source_video_id, "")
		library_database = previous_database
		library_legacy_fallback = previous_fallback
	}
	notification_history_initialize()
	export_id := notification_begin("Exporting clip")
	import_id := notification_begin("Downloading source")
	testing.expect_value(t, len(notification_history.footer_task_ids), 2)

	testing.expect(t, notification_finish(
		import_id,
		.Success,
		"Imported 1 source",
	))
	testing.expect_value(t, len(notification_history.footer_task_ids), 1)
	testing.expect_value(t, notification_history.footer_task_ids[0], export_id)
	testing.expect_value(t, notification_find(export_id).kind, Notification_Kind.Activity)
	testing.expect_value(t, notification_find(import_id).kind, Notification_Kind.Success)

	testing.expect(t, notification_update(export_id, "Exporting clip 80%"))
	testing.expect_value(t, len(notification_history.footer_task_ids), 1)
	testing.expect_value(t, notification_find(import_id).summary, "Imported 1 source")

	testing.expect(t, notification_finish(
		export_id,
		.Success,
		"Saved clip",
	))
	testing.expect_value(t, len(notification_history.footer_task_ids), 0)
	testing.expect_value(t, ui.status, "Saved clip")
}

@(test)
notification_history_scroll_follows_macos_scroll_direction_test :: proc(
	t: ^testing.T,
) {
	testing.expect_value(
		t,
		notification_scroll_after_delta(5, NOTIFICATION_ROW_HEIGHT, 10),
		4,
	)
	testing.expect_value(
		t,
		notification_scroll_after_delta(5, -NOTIFICATION_ROW_HEIGHT, 10),
		6,
	)
	testing.expect_value(
		t,
		notification_scroll_after_delta(0, NOTIFICATION_ROW_HEIGHT, 10),
		0,
	)
	testing.expect_value(
		t,
		notification_scroll_after_delta(10, -NOTIFICATION_ROW_HEIGHT, 10),
		10,
	)
}

@(test)
footer_task_layout_caps_cards_and_reports_overflow_test :: proc(t: ^testing.T) {
	full := footer_task_layout(2048, 7)
	testing.expect_value(t, full.visible_count, 4)
	testing.expect_value(t, full.hidden_count, 3)
	testing.expect(t, full.overflow_rect.w > 0)
	for index in 0 ..< full.visible_count {
		testing.expect(t, full.task_rects[index].w >= FOOTER_TASK_MIN_WIDTH)
	}

	narrow := footer_task_layout(900, 7)
	testing.expect_value(t, narrow.visible_count, 2)
	testing.expect_value(t, narrow.hidden_count, 5)
	testing.expect(t, narrow.overflow_rect.x > narrow.task_rects[1].x)
}

@(test)
simulated_tasks_use_the_real_footer_registry_without_database_writes_test :: proc(
	t: ^testing.T,
) {
	database: ^SQLite_DB
	path := strings.clone_to_cstring(":memory:")
	defer delete(path)
	opened := sqlite3_open_v2(
		path,
		&database,
		SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE,
		nil,
	) == SQLITE_OK
	testing.expect(t, opened)
	if !opened {return}
	defer sqlite3_close(database)
	testing.expect(t, database_create_schema(database))

	notification_history_destroy()
	previous_database := library_database
	previous_fallback := library_legacy_fallback
	previous_state := state
	previous_ui := ui
	previous_ui_build := ui_build
	library_database = database
	library_legacy_fallback = false
	state = App_State{active_source=-1}
	ui = UI_State{
		width=2048,
		height=1120,
		player_volume=1,
		playback_rate=1,
		source_details_index=-1,
		source_modal_refetch_index=-1,
		clip_rename_index=-1,
		clip_metadata_index=-1,
		transcript_active_match=-1,
	}
	defer {
		notification_history_destroy()
		delete(ui.status)
		delete(ui.status_source_video_id)
		state = previous_state
		ui = previous_ui
		ui_build = previous_ui_build
		library_database = previous_database
		library_legacy_fallback = previous_fallback
	}
	notification_history_initialize()
	tasks, active, applied := notification_simulation_apply("overflow")
	testing.expect(t, applied)
	testing.expect_value(t, tasks, 7)
	testing.expect_value(t, active, 7)
	testing.expect_value(t, len(notification_history.footer_task_ids), 7)
	if !applied {return}
	count, counted := database_count(database, "notifications")
	testing.expect(t, counted)
	testing.expect_value(t, count, 0)

	frame_arena: mem_virtual.Arena
	frame_error := mem_virtual.arena_init_static(&frame_arena, 1024*1024, 4096)
	testing.expect(t, frame_error == nil)
	if frame_error != nil {return}
	defer mem_virtual.arena_destroy(&frame_arena)
	build_ui_controls(false, mem_virtual.arena_allocator(&frame_arena))
	testing.expect(t, ui_controls_valid(ui_build.controls[:]))
	for index in 0 ..< 4 {
		id := notification_history.footer_task_ids[index]
		testing.expect(t, find_ui_control_by_action_and_index(
			.Open_Notification_History,
			int(id),
		) != nil)
	}
	overflow_id := notification_history.footer_task_ids[6]
	overflow := find_ui_control_by_action_and_index(
		.Open_Notification_History,
		int(overflow_id),
	)
	testing.expect(t, overflow != nil)
	if overflow != nil {
		testing.expect_value(
			t,
			overflow.functional_name,
			"footer notification task overflow",
		)
	}

	_, _, cleared := notification_simulation_apply("clear")
	testing.expect(t, cleared)
	testing.expect_value(t, len(notification_history.footer_task_ids), 0)
	testing.expect_value(t, len(notification_history.entries), 0)
}

@(test)
notification_retention_keeps_the_newest_ten_thousand_records_test :: proc(
	t: ^testing.T,
) {
	database: ^SQLite_DB
	path := strings.clone_to_cstring(":memory:")
	defer delete(path)
	opened := sqlite3_open_v2(
		path,
		&database,
		SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE,
		nil,
	) == SQLITE_OK
	testing.expect(t, opened)
	if !opened {return}
	defer sqlite3_close(database)
	testing.expect(t, database_create_schema(database))
	testing.expect(t, sqlite_execute(
		database,
		`WITH RECURSIVE sequence(value) AS (
			SELECT 1
			UNION ALL
			SELECT value + 1 FROM sequence WHERE value < 10001
		)
		INSERT INTO notifications (
			created_at_ms, updated_at_ms, kind, summary, detail,
			context_json, action_kind, action_target
		)
		SELECT value, value, 0, 'status', 'detail', '[]', 0, ''
		FROM sequence`,
	))
	previous_database := library_database
	previous_fallback := library_legacy_fallback
	library_database = database
	library_legacy_fallback = false
	defer {
		library_database = previous_database
		library_legacy_fallback = previous_fallback
	}
	testing.expect(t, notification_database_prune())
	count, counted := database_count(database, "notifications")
	testing.expect(t, counted)
	testing.expect_value(t, count, NOTIFICATION_HISTORY_LIMIT)
	statement, prepared := sqlite_prepare(
		database,
		"SELECT MIN(id), MAX(id) FROM notifications",
	)
	testing.expect(t, prepared)
	if !prepared {return}
	defer sqlite3_finalize(statement)
	testing.expect_value(t, sqlite3_step(statement), SQLITE_ROW)
	testing.expect_value(t, sqlite3_column_int64(statement, 0), i64(2))
	testing.expect_value(t, sqlite3_column_int64(statement, 1), i64(10001))
}

@(test)
notification_startup_marks_unfinished_activity_as_interrupted_test :: proc(
	t: ^testing.T,
) {
	database: ^SQLite_DB
	path := strings.clone_to_cstring(":memory:")
	defer delete(path)
	opened := sqlite3_open_v2(
		path,
		&database,
		SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE,
		nil,
	) == SQLITE_OK
	testing.expect(t, opened)
	if !opened {return}
	defer sqlite3_close(database)
	testing.expect(t, database_create_schema(database))
	testing.expect(t, sqlite_execute(
		database,
		`INSERT INTO notifications (
			created_at_ms, updated_at_ms, kind, summary, detail,
			context_json, action_kind, action_target
		) VALUES (1, 1, 1, 'Running', 'Detail', '[]', 0, '')`,
	))
	notification_history_destroy()
	previous_database := library_database
	previous_fallback := library_legacy_fallback
	library_database = database
	library_legacy_fallback = false
	defer {
		notification_history_destroy()
		library_database = previous_database
		library_legacy_fallback = previous_fallback
	}
	notification_history_initialize()
	testing.expect_value(t, len(notification_history.entries), 1)
	testing.expect_value(
		t,
		notification_history.entries[0].kind,
		Notification_Kind.Interrupted,
	)
}

@(test)
clip_range_validation_test :: proc(t: ^testing.T) {
	testing.expect(t, valid_clip_range(10, 20, 60))
	testing.expect(t, !valid_clip_range(-1, 20, 60))
	testing.expect(t, !valid_clip_range(20, 20, 60))
	testing.expect(t, !valid_clip_range(20, 20.999, 60))
	testing.expect(t, valid_clip_range(20, 21, 60))
	testing.expect(t, !valid_clip_range(20, 61, 60))
	testing.expect(t, valid_clip_range(20, 61, 0))
}

@(test)
cli_source_add_parses_json_tool_arguments_test :: proc(t: ^testing.T) {
	request, result, ok := cli_parse_request([]string{"source", "add", "--url", "https://youtu.be/dQw4w9WgXcQ", "--max-height", "720"})
	defer delete(result.output)
	testing.expect(t, ok)
	testing.expect_value(t, request.command, CLI_Command.Source_Add)
	testing.expect_value(t, request.url, "https://youtu.be/dQw4w9WgXcQ")
	testing.expect_value(t, request.max_height, 720)
	testing.expect_value(t, request.workflow, Workflow_Kind.Vocal)
}

@(test)
cli_workflow_option_selects_the_independent_dancing_library_test :: proc(
	t: ^testing.T,
) {
	request, result, ok := cli_parse_request(
		[]string{"source", "list", "--workflow", "dancing"},
	)
	defer delete(result.output)
	testing.expect(t, ok)
	testing.expect_value(t, request.command, CLI_Command.Source_List)
	testing.expect_value(t, request.workflow, Workflow_Kind.Dancing)

	_, invalid_result, invalid_ok := cli_parse_request(
		[]string{"clip", "list", "--workflow", "other"},
	)
	defer delete(invalid_result.output)
	testing.expect(t, !invalid_ok)
	testing.expect_value(t, invalid_result.exit_code, CLI_Exit.Usage)
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

cli_ipc_test_socket_pair :: proc(t: ^testing.T) -> ([2]posix.FD, bool) {
	sockets: [2]posix.FD
	result := posix.socketpair(.UNIX, .STREAM, .IP, &sockets)
	testing.expect_value(t, result, posix.result(.OK))
	return sockets, result == .OK
}

cli_ipc_test_response :: proc(
	t: ^testing.T,
	fd: posix.FD,
) -> (CLI_IPC_Response, bool) {
	bytes, read_ok := cli_socket_receive_response(fd)
	testing.expect(t, read_ok)
	if !read_ok {return {}, false}
	defer delete(bytes)
	response: CLI_IPC_Response
	decode_error := json.unmarshal(bytes, &response)
	testing.expect_value(t, decode_error, nil)
	return response, decode_error == nil
}

@(test)
cli_ipc_rejects_oversized_request_before_body_allocation_test :: proc(
	t: ^testing.T,
) {
	sockets, sockets_ok := cli_ipc_test_socket_pair(t)
	if !sockets_ok {return}
	defer posix.close(sockets[0])
	defer posix.close(sockets[1])

	length := u32(CLI_IPC_MAX_REQUEST_BYTES+1)
	header := [CLI_IPC_REQUEST_HEADER_SIZE]u8{
		u8(length >> 24),
		u8(length >> 16),
		u8(length >> 8),
		u8(length),
	}
	testing.expect(t, cli_socket_send_all(sockets[1], header[:]))
	cli_ipc_serve_connection(sockets[0], 20*time.Millisecond)
	_ = posix.shutdown(sockets[0], .WR)

	response, response_ok := cli_ipc_test_response(t, sockets[1])
	if !response_ok {return}
	defer delete(response.output)
	testing.expect_value(t, response.exit_code, CLI_Exit.Invalid)
	testing.expect(
		t,
		strings.contains(response.output, `"code":"ipc_request_too_large"`),
	)
}

@(test)
cli_ipc_times_out_incomplete_request_with_structured_error_test :: proc(
	t: ^testing.T,
) {
	sockets, sockets_ok := cli_ipc_test_socket_pair(t)
	if !sockets_ok {return}
	defer posix.close(sockets[0])
	defer posix.close(sockets[1])

	testing.expect(
		t,
		cli_socket_send_all(sockets[1], []u8{0}),
	)
	started := time.tick_now()
	cli_ipc_serve_connection(sockets[0], 20*time.Millisecond)
	elapsed := time.tick_since(started)
	_ = posix.shutdown(sockets[0], .WR)

	response, response_ok := cli_ipc_test_response(t, sockets[1])
	if !response_ok {return}
	defer delete(response.output)
	testing.expect(t, elapsed < 250*time.Millisecond)
	testing.expect_value(t, response.exit_code, CLI_Exit.Storage)
	testing.expect(
		t,
		strings.contains(response.output, `"code":"ipc_request_timeout"`),
	)
}

@(test)
cli_ipc_reads_valid_length_prefixed_request_test :: proc(t: ^testing.T) {
	sockets, sockets_ok := cli_ipc_test_socket_pair(t)
	if !sockets_ok {return}
	defer posix.close(sockets[0])
	defer posix.close(sockets[1])

	request := CLI_Request{command=.Source_List}
	bytes, encode_error := json.marshal(request)
	testing.expect_value(t, encode_error, nil)
	if encode_error != nil {return}
	defer delete(bytes)
	testing.expect(t, cli_socket_send_request(sockets[1], bytes))

	received, read_status := cli_socket_receive_request(
		sockets[0],
		20*time.Millisecond,
	)
	testing.expect_value(t, read_status, CLI_IPC_Read_Status.Success)
	if read_status != .Success {return}
	defer delete(received)
	decoded: CLI_Request
	decode_error := json.unmarshal(received, &decoded)
	testing.expect_value(t, decode_error, nil)
	testing.expect_value(t, decoded.command, CLI_Command.Source_List)
}

@(test)
cli_ipc_server_stop_interrupts_incomplete_active_client_test :: proc(
	t: ^testing.T,
) {
	cli_ipc_server_stop()
	testing.expect(t, cli_ipc_server_start())
	if !cli_ipc_server_is_running() {return}
	defer cli_ipc_server_stop()

	path := cli_socket_path()
	address, address_ok := cli_socket_address(path)
	testing.expect(t, address_ok)
	if !address_ok {return}
	client := posix.socket(.UNIX, .STREAM)
	testing.expect(t, client >= 0)
	if client < 0 {return}
	defer posix.close(client)
	connected := posix.connect(
		client,
		cast(^posix.sockaddr)&address,
		posix.socklen_t(size_of(address)),
	) == .OK
	testing.expect(t, connected)
	if !connected {return}
	testing.expect(t, cli_socket_send_all(client, []u8{0}))

	active := false
	for _ in 0..<100 {
		if cli_ipc_server_has_active_client() {
			active = true
			break
		}
		time.sleep(time.Millisecond)
	}
	testing.expect(t, active)
	if !active {return}

	started := time.tick_now()
	cli_ipc_server_stop()
	elapsed := time.tick_since(started)
	testing.expect(t, elapsed < 250*time.Millisecond)
	testing.expect(t, !cli_ipc_server_is_running())
	testing.expect(t, !cli_ipc_server_has_active_client())
	testing.expect(t, !os.exists(path))
}

@(test)
cli_ipc_server_stop_handles_client_completion_race_test :: proc(
	t: ^testing.T,
) {
	cli_ipc_server_stop()
	testing.expect(t, cli_ipc_server_start())
	if !cli_ipc_server_is_running() {return}
	defer cli_ipc_server_stop()

	path := cli_socket_path()
	address, address_ok := cli_socket_address(path)
	testing.expect(t, address_ok)
	if !address_ok {return}
	client := posix.socket(.UNIX, .STREAM)
	testing.expect(t, client >= 0)
	if client < 0 {return}
	defer posix.close(client)
	connected := posix.connect(
		client,
		cast(^posix.sockaddr)&address,
		posix.socklen_t(size_of(address)),
	) == .OK
	testing.expect(t, connected)
	if !connected {return}

	testing.expect(t, cli_socket_send_all(client, []u8{0}))
	active := false
	for _ in 0..<100 {
		if cli_ipc_server_has_active_client() {
			active = true
			break
		}
		time.sleep(time.Millisecond)
	}
	testing.expect(t, active)
	if !active {return}

	testing.expect(t, cli_socket_send_all(client, []u8{1, 0, 1}))
	started := time.tick_now()
	cli_ipc_server_stop()
	elapsed := time.tick_since(started)
	testing.expect(t, elapsed < 250*time.Millisecond)
	testing.expect(t, !cli_ipc_server_is_running())
	testing.expect(t, !cli_ipc_server_has_active_client())
	testing.expect(t, !os.exists(path))
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

	simulation, simulation_result, simulation_ok := cli_parse_request(
		[]string{"ui", "simulate-tasks", "--scenario", "overflow"},
	)
	defer delete(simulation_result.output)
	testing.expect(t, simulation_ok)
	testing.expect_value(t, simulation.command, CLI_Command.UI_Simulate_Tasks)
	testing.expect_value(t, simulation.scenario, "overflow")
	testing.expect(t, cli_command_requires_gui(simulation.command))
	testing.expect(t, !cli_command_mutates_library(simulation.command))

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
	support, found := os.lookup_env("HW_VIDEO_CLIPS_APP_SUPPORT_DIR")
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
	append(&original.sources, Source_Video{
		id="source-1",
		video_id="abc",
		title="Warmup",
		url="https://youtu.be/abc",
		media_path="/tmp/source.mp4",
		duration=90,
	})
	append(&original.clips, Clip{
		id="clip-1",
		source_id="source-1",
		name="Scale",
		start_seconds=12,
		end_seconds=24,
		clip_path="/tmp/clip.mp4",
	})
	encoded, marshal_error := json.marshal(original)
	defer delete(encoded)
	defer delete(original.sources)
	defer delete(original.clips)
	testing.expect(t, marshal_error == nil)
	restored: Persisted_State
	unmarshal_error := json.unmarshal(encoded, &restored, .JSON)
	defer {
		for source in restored.sources {
			delete(source.id)
			delete(source.video_id)
			delete(source.title)
			delete(source.url)
			delete(source.media_path)
		}
		for clip in restored.clips {
			delete(clip.id)
			delete(clip.source_id)
			delete(clip.name)
			delete(clip.clip_path)
		}
		delete(restored.sources)
		delete(restored.clips)
	}
	testing.expect(t, unmarshal_error == nil)
	testing.expect_value(t, restored.sources[0].title, "Warmup")
	testing.expect_value(t, restored.clips[0].end_seconds, 24)
	database: ^SQLite_DB
	path := strings.clone_to_cstring(":memory:")
	defer delete(path)
	opened := sqlite3_open_v2(path, &database, SQLITE_OPEN_READWRITE|SQLITE_OPEN_CREATE, nil) == SQLITE_OK
	testing.expect(t, opened)
	if opened {
		defer sqlite3_close(database)
		testing.expect(t, database_create_schema(database))
		testing.expect(t, database_save_collections(database, restored.sources[:], restored.segments[:], restored.hints[:], restored.clips[:]))
		source_count, source_count_ok := database_count(database, "sources")
		clip_count, clip_count_ok := database_count(database, "clips")
		testing.expect(t, source_count_ok && clip_count_ok)
		testing.expect_value(t, source_count, 1)
		testing.expect_value(t, clip_count, 1)
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
		"/Applications/hw_videoClips.app/Contents/MacOS/hw_videoClips",
		"ffmpeg",
	)
	testing.expect_value(
		t,
		path,
		"/Applications/hw_videoClips.app/Contents/Resources/helpers/ffmpeg",
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
		"/Applications/hw_videoClips.app/Contents/Resources/helpers/yt-dlp",
		"/Applications/hw_videoClips.app/Contents/Resources/helpers/ffmpeg",
	)
	testing.expect(t, strings.has_prefix(command, "'/Applications/hw_videoClips.app/Contents/Resources/helpers/yt-dlp'"))
	testing.expect(t, strings.contains(command, "--ffmpeg-location '/Applications/hw_videoClips.app/Contents/Resources/helpers/ffmpeg'"))
}

@(test)
clip_command_uses_range_duration_test :: proc(t: ^testing.T) {
	command := clip_export_command(
		"/tmp/source video.mp4",
		"/tmp/clip.mp4",
		12.5,
		20.25,
		"/Applications/hw_videoClips.app/Contents/Resources/helpers/ffmpeg",
	)
	testing.expect(t, strings.has_prefix(command, "'/Applications/hw_videoClips.app/Contents/Resources/helpers/ffmpeg'"))
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
	value := strings.clone("hw_videoClips.app/clips")
	defer delete(value)
	remove_last_word(&value)
	testing.expect_value(t, value, "hw_videoClips.app/")
	remove_last_word(&value)
	testing.expect_value(t, value, "hw_videoClips.")
	remove_last_word(&value)
	testing.expect_value(t, value, "")
}

@(test)
metal_ui_word_backspace_keeps_underscore_inside_word_test :: proc(t: ^testing.T) {
	value := strings.clone("hw_videoClips")
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
	import_field, import_button, _, source_panel, player, transcript, _, clip_panel, _, _, controls := layout_rects()
	testing.expect(t, import_field.w == 0 && import_button.w == 0)
	testing.expect(t, source_panel.x+source_panel.w < player.x)
	testing.expect(t, player.x+player.w < clip_panel.x)
	testing.expect(t, transcript.y+transcript.h < player.y)
	testing.expect(t, controls.x >= 0 && controls.x+controls.w <= ui.width)
}

@(test)
terminal_control_rail_fills_width_without_overlap_test :: proc(t: ^testing.T) {
	old_mode := ui.mode
	defer ui.mode = old_mode
	ui.mode = .Create
	controls := UI_Rect{18,42,1064,28}
	previous := control_rect(controls, control_action_for_slot(.Create, 0))
	for slot in 1..<8 {
		action := control_action_for_slot(.Create, slot)
		current := control_rect(controls, action)
		testing.expect(t, previous.x+previous.w < current.x)
		previous = current
	}
	testing.expect(t, previous.x+previous.w <= controls.x+controls.w)

	ui.mode = .Play
	previous = control_rect(controls, control_action_for_slot(.Play, 0))
	for slot in 1..<10 {
		action := control_action_for_slot(.Play, slot)
		current := control_rect(controls, action)
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

	clip_panel := UI_Rect{798, 116, 284, 500}
	clip_search := UI_Rect{806, 544, 268, 28}
	clip_name := UI_Rect{806, 124, 268, 30}
	clip_content := clip_content_rect(clip_search, clip_panel, clip_name)
	testing.expect(t, clip_content.y > clip_name.y+clip_name.h)
	testing.expect(t, clip_content.y+clip_content.h < clip_search.y)
}

@(test)
metal_ui_titlebar_uses_compact_height_test :: proc(t: ^testing.T) {
	testing.expect_value(t, APP_HEADER_HEIGHT, 38.0)
}

@(test)
metal_ui_settings_control_precedes_title_test :: proc(t: ^testing.T) {
	settings := settings_button_rect_for_size(720)
	mode := mode_button_rect_for_size(1100, 720)
	title := app_title_rect_for_size(1100, 720)
	testing.expect_value(t, settings, UI_Rect{114, 690, 30, 30})
	testing.expect_value(t, title.x, 160.0)
	testing.expect_value(t, mode, UI_Rect{886, 689, 196, 24})
	testing.expect(t, title.x > settings.x+settings.w)
	testing.expect(t, title.x+title.w < mode.x)
}

@(test)
metal_ui_selection_and_progress_accents_use_thick_edges_test :: proc(
	t: ^testing.T,
) {
	row := UI_Rect{20, 40, 200, 25}
	testing.expect_value(
		t,
		left_accent_edge_rect(row),
		UI_Rect{20, 40, ACCENT_EDGE_WIDTH, 25},
	)
	testing.expect_value(
		t,
		bottom_progress_edge_rect(row, 0.25),
		UI_Rect{20, 40, 50, ACCENT_EDGE_WIDTH},
	)
	testing.expect_value(
		t,
		bottom_progress_edge_rect(row, 2),
		UI_Rect{20, 40, 200, ACCENT_EDGE_WIDTH},
	)
}

@(test)
metal_ui_header_controls_take_precedence_over_window_gestures_test :: proc(
	t: ^testing.T,
) {
	header := app_header_rect_for_size(1100, 720)
	settings := settings_button_rect_for_size(720)
	settings_center := Point{
		settings.x+settings.w/2,
		settings.y+settings.h/2,
	}
	controls := []UI_Control{{
		id = ui_control_id("settings"),
		functional_name = "settings",
		rect = settings,
		flags = {.Primary_Press, .Enabled},
		action = {kind = .Open_Settings},
	}}
	testing.expect(
		t,
		!header_window_gesture_allowed(header, controls, settings_center),
	)
	testing.expect(t, header_window_gesture_allowed(header, controls, Point{500, 710}))
}

@(test)
metal_ui_themes_use_canonical_canvas_colors_test :: proc(t: ^testing.T) {
	light := ui_theme_colors(false)
	dark := ui_theme_colors(true)
	testing.expect_value(t, light.chassis, [4]f64{0.80, 0.78, 0.72, 1})
	testing.expect_value(t, dark.chassis, [4]f64{0.040, 0.043, 0.041, 1})
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
		if entry.title == "Open library data" {
			found_data = true
			testing.expect(t, command_palette.context_matches(active, entry.contexts))
		}
	}
	testing.expect(t, found_mark_in)
	testing.expect(t, found_data)
}

@(test)
command_palette_uses_current_action_availability_test :: proc(t: ^testing.T) {
	previous_mode := ui.mode
	previous_pitch := ui.pitch
	previous_search := ui.clip_search
	previous_state := state
	previous_recovery := library_recovery_state
	previous_pending := major_change_pending
	previous_actions := command_palette_actions
	defer {
		delete(state.clips)
		delete(command_palette_actions)
		command_palette_actions = previous_actions
		ui.mode = previous_mode
		ui.pitch = previous_pitch
		ui.clip_search = previous_search
		state = previous_state
		library_recovery_state = previous_recovery
		major_change_pending = previous_pending
	}
	command_palette_actions = nil
	state = App_State{active_source = -1}
	state.clips = make([dynamic]Clip)
	append(&state.clips, Clip{name = "Warm up"})
	ui.mode = .Play
	ui.clip_search = "Missing"
	ui.pitch.permission = .Denied
	ui.pitch.permission_pending = false
	library_recovery_state = Library_Recovery_State{required = true}
	major_change_pending = {}

	entries := build_command_palette_entries(context.temp_allocator)
	active := palette_active_context()
	found_settings := false
	found_flash := false
	found_pitch := false
	found_next := false
	for entry in entries {
		matches := command_palette.context_matches(active, entry.contexts)
		switch entry.title {
		case "Open Settings":
			found_settings = true
			testing.expect(t, !matches)
		case "Configure leader key for Flash":
			found_flash = true
			testing.expect(t, !matches)
		case "Start pitch tracking":
			found_pitch = true
			testing.expect(t, !matches)
		case "Play next clip":
			found_next = true
			testing.expect(t, !matches)
		}
	}
	testing.expect(t, found_settings)
	testing.expect(t, found_flash)
	testing.expect(t, found_pitch)
	testing.expect(t, found_next)

	library_recovery_state = {}
	ui.clip_search = ""
	ui.pitch.permission = .Authorized
	active = palette_active_context()
	for entry in entries {
		if entry.title == "Start pitch tracking" ||
		   entry.title == "Play next clip" {
			testing.expect(
				t,
				command_palette.context_matches(active, entry.contexts),
			)
		}
	}
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
	headless, skip := os.lookup_env("HW_VIDEO_CLIPS_HEADLESS_TEST")
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
portable_library_round_trip_omits_machine_paths_test :: proc(t: ^testing.T) {
	support, found := os.lookup_env("HW_VIDEO_CLIPS_APP_SUPPORT_DIR")
	defer delete(support)
	testing.expect(t, found)
	if !found {return}
	previous_state := state
	state = {}
	defer {
		app_state_collections_destroy(&state)
		state = previous_state
	}
	state.sources = make([dynamic]Source_Video)
	state.hints = make([dynamic]Import_Hint)
	state.clips = make([dynamic]Clip)
	transcripts, transcripts_ok := transcript_generation_create(1)
	testing.expect(t, transcripts_ok)
	if !transcripts_ok {return}
	state.transcripts = transcripts
	source, source_ok := clone_source_video(Source_Video{
		id = "source-1",
		video_id = "video-1",
		title = "Živý hlas",
		url = "https://youtu.be/video-1",
		media_path = fmt.tprintf("%s/sources/video-1.mp4", support),
		duration = 120,
		metadata = {
			width = 1920,
			height = 1080,
			vcodec = "avc1",
			acodec = "mp4a",
			format_id = "137+140",
		},
		metadata_status = .Available,
	})
	testing.expect(t, source_ok)
	if !source_ok {return}
	append(&state.sources, source)
	hint, hint_ok := clone_import_hint(Import_Hint{
		source_id = "source-1",
		seconds = 30,
	})
	testing.expect(t, hint_ok)
	if !hint_ok {return}
	append(&state.hints, hint)
	clip, clip_ok := clone_clip(Clip{
		id = "clip-1",
		source_id = "source-1",
		name = "Warm up",
		start_seconds = 40,
		end_seconds = 55,
		clip_path = fmt.tprintf("%s/clips/clip-1.mp4", support),
		last_randomized_sequence = 12,
	})
	testing.expect(t, clip_ok)
	if !clip_ok {return}
	append(&state.clips, clip)
	testing.expect(t, transcript_append_copy(&state.transcripts, Transcript_Segment{
		id = "segment-1",
		source_id = "source-1",
		start_seconds = 10,
		duration_seconds = 2,
		text = "Sing now",
	}))

	path := fmt.tprintf("%s/portable-library-test.hwvideoclips.json", support)
	defer os.remove(path)
	testing.expect_value(t, portable_library_export(path), Portable_Library_Error.None)
	bytes, read_ok := os.read_entire_file(path, context.temp_allocator)
	testing.expect(t, read_ok)
	if read_ok {
		testing.expect(t, !strings.contains(string(bytes), support))
		testing.expect(t, !strings.contains(string(bytes), `"media_path"`))
		testing.expect(t, !strings.contains(string(bytes), `"clip_path"`))
		testing.expect(t, !strings.contains(
			string(bytes),
			`"last_randomized_sequence"`,
		))
	}
	imported, import_error := portable_library_read(path)
	testing.expect_value(t, import_error, Portable_Library_Error.None)
	defer app_state_collections_destroy(&imported)
	testing.expect_value(t, len(imported.sources), 1)
	testing.expect_value(t, len(imported.clips), 1)
	testing.expect_value(t, len(imported.transcripts.segments), 1)
	testing.expect_value(t, imported.sources[0].title, "Živý hlas")
	testing.expect_value(
		t,
		imported.sources[0].media_path,
		fmt.tprintf("%s/sources/video-1.mp4", support),
	)
	testing.expect_value(
		t,
		imported.clips[0].clip_path,
		fmt.tprintf("%s/clips/clip-1.mp4", support),
	)
}

@(test)
portable_library_current_workflow_export_is_scoped_test :: proc(t: ^testing.T) {
	previous_state := state
	state = {}
	defer {
		app_state_collections_destroy(&state)
		state = previous_state
	}
	state.sources = make([dynamic]Source_Video)
	state.hints = make([dynamic]Import_Hint)
	state.clips = make([dynamic]Clip)
	transcripts, transcripts_ok := transcript_generation_create(0)
	testing.expect(t, transcripts_ok)
	if !transcripts_ok {return}
	state.transcripts = transcripts
	vocal_source, vocal_ok := clone_source_video(Source_Video{
		id="vocal-source",
		workflow=.Vocal,
		video_id="shared-video",
		duration=30,
	})
	dance_source, dance_ok := clone_source_video(Source_Video{
		id="dancing-shared-video",
		workflow=.Dancing,
		video_id="shared-video",
		duration=30,
	})
	testing.expect(t, vocal_ok && dance_ok)
	if !vocal_ok || !dance_ok {return}
	append(&state.sources, vocal_source, dance_source)
	vocal_clip, vocal_clip_ok := clone_clip(Clip{
		id="vocal-clip",
		source_id="vocal-source",
		workflow=.Vocal,
		start_seconds=1,
		end_seconds=2,
	})
	dance_clip, dance_clip_ok := clone_clip(Clip{
		id="dance-clip",
		source_id="dancing-shared-video",
		workflow=.Dancing,
		start_seconds=1,
		end_seconds=2,
		dance_count_in_beats=8,
		dance_count_in_bpm=120,
		dance_playback_rate=0.8,
	})
	testing.expect(t, vocal_clip_ok && dance_clip_ok)
	if !vocal_clip_ok || !dance_clip_ok {return}
	append(&state.clips, vocal_clip, dance_clip)

	vocal, vocal_created :=
		portable_library_from_state(.Vocal, context.temp_allocator)
	testing.expect(t, vocal_created)
	testing.expect_value(t, vocal.scope, "vocal")
	testing.expect_value(t, len(vocal.sources), 1)
	testing.expect_value(t, len(vocal.clips), 1)
	testing.expect_value(t, vocal.sources[0].workflow, Workflow_Kind.Vocal)

	dancing, dancing_created :=
		portable_library_from_state(.Dancing, context.temp_allocator)
	testing.expect(t, dancing_created)
	testing.expect_value(t, dancing.scope, "dancing")
	testing.expect_value(t, len(dancing.sources), 1)
	testing.expect_value(t, len(dancing.clips), 1)
	testing.expect_value(t, dancing.clips[0].dance_count_in_beats, 8)
	testing.expect_value(t, dancing.clips[0].dance_playback_rate, f32(0.8))

	all, all_created :=
		portable_library_from_state(.All, context.temp_allocator)
	testing.expect(t, all_created)
	testing.expect_value(t, len(all.sources), 2)
	testing.expect_value(t, len(all.clips), 2)
}

@(test)
portable_library_validation_rejects_versions_and_broken_references_test :: proc(
	t: ^testing.T,
) {
	source := Portable_Source{
		id = "source-1",
		video_id = "video-1",
		duration = 60,
	}
	data := Portable_Library{
		format = PORTABLE_LIBRARY_FORMAT,
		version = PORTABLE_LIBRARY_VERSION + 1,
		scope = "all",
		sources = []Portable_Source{source},
	}
	testing.expect_value(
		t,
		portable_library_validate(&data),
		Portable_Library_Error.Version,
	)
	data.version = PORTABLE_LIBRARY_VERSION
	data.clips = []Portable_Clip{{
		id = "clip-1",
		source_id = "missing",
		start_seconds = 1,
		end_seconds = 2,
	}}
	testing.expect_value(
		t,
		portable_library_validate(&data),
		Portable_Library_Error.Reference,
	)
}

@(test)
portable_library_install_replaces_database_and_memory_together_test :: proc(
	t: ^testing.T,
) {
	database: ^SQLite_DB
	path := strings.clone_to_cstring(":memory:")
	defer delete(path)
	opened := sqlite3_open_v2(
		path,
		&database,
		SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE,
		nil,
	) == SQLITE_OK
	testing.expect(t, opened)
	if !opened {return}
	defer sqlite3_close(database)
	testing.expect(t, database_create_schema(database))
	testing.expect(t, sqlite_execute(
		database,
		`INSERT INTO notifications (
			created_at_ms, updated_at_ms, kind, summary, detail,
			context_json, action_kind, action_target
		) VALUES (1, 1, 0, 'Keep me', 'Local history', '[]', 0, '')`,
	))

	previous_state := state
	previous_database := library_database
	previous_fallback := library_legacy_fallback
	state = {}
	imported: App_State
	defer {
		app_state_collections_destroy(&state)
		app_state_collections_destroy(&imported)
		state = previous_state
		library_database = previous_database
		library_legacy_fallback = previous_fallback
	}
	state.sources = make([dynamic]Source_Video)
	state.hints = make([dynamic]Import_Hint)
	state.clips = make([dynamic]Clip)
	state.transcripts, _ = transcript_generation_create(0)
	old_source, old_ok := clone_source_video(Source_Video{
		id = "old-source",
		video_id = "old-video",
		title = "Old",
		url = "https://youtu.be/old-video",
		media_path = "/tmp/old.mp4",
		duration = 30,
	})
	testing.expect(t, old_ok)
	if !old_ok {return}
	append(&state.sources, old_source)

	imported.sources = make([dynamic]Source_Video)
	imported.hints = make([dynamic]Import_Hint)
	imported.clips = make([dynamic]Clip)
	imported.transcripts, _ = transcript_generation_create(0)
	new_source, new_ok := clone_source_video(Source_Video{
		id = "new-source",
		video_id = "new-video",
		title = "New",
		url = "https://youtu.be/new-video",
		media_path = fmt.tprintf("%s/sources/new-video.mp4", app_support_dir()),
		duration = 60,
	})
	testing.expect(t, new_ok)
	if !new_ok {return}
	append(&imported.sources, new_source)
	library_database = database
	library_legacy_fallback = false

	testing.expect_value(
		t,
		portable_library_install(&imported),
		Portable_Library_Error.None,
	)
	testing.expect_value(t, len(state.sources), 1)
	testing.expect_value(t, state.sources[0].title, "New")
	testing.expect_value(t, len(imported.sources), 0)
	statement, prepared := sqlite_prepare(
		database,
		"SELECT title FROM sources ORDER BY position",
	)
	testing.expect(t, prepared)
	if !prepared {return}
	defer sqlite3_finalize(statement)
	testing.expect_value(t, sqlite3_step(statement), SQLITE_ROW)
	title := sqlite3_column_text(statement, 0)
	testing.expect(t, title != nil)
	if title != nil {testing.expect_value(t, string(title), "New")}
	notification_count, notifications_counted := database_count(
		database,
		"notifications",
	)
	testing.expect(t, notifications_counted)
	testing.expect_value(t, notification_count, 1)
}

Library_Transaction_Test_Context :: struct {
	database: ^SQLite_DB,
	previous_state: App_State,
	previous_database: ^SQLite_DB,
	previous_fallback: bool,
	previous_last_imported_source: int,
}

library_transaction_test_begin :: proc(
	database_path := ":memory:",
) -> (Library_Transaction_Test_Context, bool) {
	fixture := Library_Transaction_Test_Context{
		previous_state = state,
		previous_database = library_database,
		previous_fallback = library_legacy_fallback,
		previous_last_imported_source = last_imported_source,
	}
	path := strings.clone_to_cstring(database_path)
	defer delete(path)
	if sqlite3_open_v2(
		path,
		&fixture.database,
		SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE,
		nil,
	) != SQLITE_OK {
		return {}, false
	}
	if !database_create_schema(fixture.database) {
		sqlite3_close(fixture.database)
		return {}, false
	}
	state = {}
	state.sources = make([dynamic]Source_Video)
	state.hints = make([dynamic]Import_Hint)
	state.clips = make([dynamic]Clip)
	transcripts, transcripts_created := transcript_generation_create(0)
	if !transcripts_created {
		app_state_collections_destroy(&state)
		state = fixture.previous_state
		sqlite3_close(fixture.database)
		return {}, false
	}
	state.transcripts = transcripts
	library_database = fixture.database
	library_legacy_fallback = false
	return fixture, true
}

library_transaction_test_end :: proc(fixture: ^Library_Transaction_Test_Context) {
	app_state_collections_destroy(&state)
	state = fixture.previous_state
	library_database = fixture.previous_database
	library_legacy_fallback = fixture.previous_fallback
	last_imported_source = fixture.previous_last_imported_source
	sqlite3_close(fixture.database)
	fixture^ = {}
}

@(test)
failed_import_commit_keeps_live_library_state_test :: proc(t: ^testing.T) {
	fixture, fixture_ready := library_transaction_test_begin()
	testing.expect(t, fixture_ready)
	if !fixture_ready {return}
	defer library_transaction_test_end(&fixture)
	state.pending_hint = 7
	state.has_pending_hint = true
	source, source_copied := clone_source_video(Source_Video{
		id = "old-source",
		video_id = "old-video",
		title = "Old",
		url = "https://youtu.be/old-video",
		media_path = "/tmp/old.mp4",
		duration = 30,
	})
	testing.expect(t, source_copied)
	if !source_copied {return}
	append(&state.sources, source)

	testing.expect(t, database_save_state(fixture.database))
	testing.expect(t, sqlite_execute(
		fixture.database,
		`CREATE TRIGGER fail_source_insert
		 BEFORE INSERT ON sources
		 BEGIN
		   SELECT RAISE(ABORT, 'forced source insert failure');
		 END`,
	))

	job := Import_Job{
		accepted = 1,
		last_video_id = "new-video",
		pending_hint = 12,
		has_pending_hint = true,
		has_source_update = true,
		updated_source = {
			id = "old-source",
			video_id = "old-video",
			title = "Refetched",
			url = "https://youtu.be/old-video",
			media_path = "/tmp/old.mp4",
			duration = 45,
		},
	}
	job.new_sources = make([dynamic]Source_Video)
	job.new_hints = make([dynamic]Import_Hint)
	defer {
		delete(job.new_sources)
		delete(job.new_hints)
	}
	append(&job.new_sources, Source_Video{
		id = "new-source",
		video_id = "new-video",
		title = "New",
		url = "https://youtu.be/new-video",
		media_path = "/tmp/new.mp4",
		duration = 60,
	})
	append(&job.new_hints, Import_Hint{source_id = "new-source", seconds = 12})

	last_imported_source = 0
	testing.expect(t, !import_job_apply(&job))
	testing.expect_value(t, len(state.sources), 1)
	testing.expect_value(t, state.sources[0].id, "old-source")
	testing.expect_value(t, state.sources[0].title, "Old")
	testing.expect_value(t, len(state.hints), 0)
	testing.expect_value(t, state.pending_hint, 7)
	testing.expect(t, state.has_pending_hint)
	testing.expect_value(t, last_imported_source, 0)

	source_count, source_counted := database_count(fixture.database, "sources")
	testing.expect(t, source_counted)
	testing.expect_value(t, source_count, 1)
}

@(test)
successful_import_commit_survives_database_reload_test :: proc(t: ^testing.T) {
	temporary_file, temporary_error := os2.create_temp_file(
		"",
		"hw_videoClips-library-transaction-*.sqlite3",
	)
	testing.expect(t, temporary_error == nil)
	if temporary_error != nil {return}
	database_path, path_error := strings.clone(os2.name(temporary_file))
	_ = os2.close(temporary_file)
	testing.expect(t, path_error == nil)
	if path_error != nil {return}
	defer {
		_ = os.remove(database_path)
		delete(database_path)
	}

	fixture, fixture_ready := library_transaction_test_begin(database_path)
	testing.expect(t, fixture_ready)
	if !fixture_ready {return}
	defer library_transaction_test_end(&fixture)

	job := Import_Job{
		accepted = 1,
		last_video_id = "new-video",
		pending_hint = 12,
		has_pending_hint = true,
		has_transcript_update = true,
	}
	job.new_sources = make([dynamic]Source_Video)
	job.new_hints = make([dynamic]Import_Hint)
	job.transcripts, _ = transcript_generation_create(1)
	defer {
		delete(job.new_sources)
		delete(job.new_hints)
		transcript_generation_destroy(&job.transcripts)
	}
	append(&job.new_sources, Source_Video{
		id = "new-source",
		video_id = "new-video",
		title = "New",
		url = "https://youtu.be/new-video",
		media_path = "/tmp/new.mp4",
		duration = 60,
	})
	append(&job.new_hints, Import_Hint{source_id = "new-source", seconds = 12})
	testing.expect(t, transcript_append_copy(&job.transcripts, Transcript_Segment{
		id = "new-source-0",
		source_id = "new-source",
		start_seconds = 1,
		duration_seconds = 2,
		text = "Warm up",
	}))

	testing.expect(t, import_job_apply(&job))
	testing.expect_value(t, len(state.sources), 1)
	testing.expect_value(t, state.sources[0].title, "New")
	testing.expect_value(t, len(state.hints), 1)
	testing.expect_value(t, len(state.transcripts.segments), 1)
	testing.expect_value(t, state.pending_hint, 12)
	testing.expect_value(t, last_imported_source, 0)

	app_state_collections_destroy(&state)
	state = {}
	sqlite3_close(fixture.database)
	fixture.database = nil
	library_database = nil

	c_path := strings.clone_to_cstring(database_path)
	defer delete(c_path)
	reopened := sqlite3_open_v2(
		c_path,
		&fixture.database,
		SQLITE_OPEN_READWRITE,
		nil,
	) == SQLITE_OK
	testing.expect(t, reopened)
	if !reopened {return}
	library_database = fixture.database
	testing.expect(t, database_create_schema(fixture.database))
	testing.expect(t, database_load_state(fixture.database, &state))
	testing.expect_value(t, len(state.sources), 1)
	testing.expect_value(t, state.sources[0].title, "New")
	testing.expect_value(t, len(state.hints), 1)
	testing.expect_value(t, state.hints[0].seconds, 12)
	testing.expect_value(t, len(state.transcripts.segments), 1)
	testing.expect_value(t, state.transcripts.segments[0].text, "Warm up")
}

@(test)
repair_commit_publishes_only_after_database_success_test :: proc(t: ^testing.T) {
	fixture, fixture_ready := library_transaction_test_begin()
	testing.expect(t, fixture_ready)
	if !fixture_ready {return}
	defer library_transaction_test_end(&fixture)
	source, source_copied := clone_source_video(Source_Video{
		id = "source-1",
		video_id = "video-1",
		title = "Source",
		url = "https://youtu.be/video-1",
		media_path = "/tmp/source.mp4",
		duration = 30,
	})
	testing.expect(t, source_copied)
	if !source_copied {return}
	append(&state.sources, source)
	clip, clip_copied := clone_clip(Clip{
		id = "clip-1",
		source_id = "source-1",
		name = "Original",
		start_seconds = 2,
		end_seconds = 8,
		clip_path = "/tmp/original.mp4",
	})
	testing.expect(t, clip_copied)
	if !clip_copied {return}
	append(&state.clips, clip)

	testing.expect(t, database_save_state(fixture.database))
	testing.expect(t, sqlite_execute(
		fixture.database,
		`CREATE TRIGGER fail_clip_insert
		 BEFORE INSERT ON clips
		 BEGIN
		   SELECT RAISE(ABORT, 'forced clip insert failure');
		 END`,
	))

	index, repaired := repair_clip_apply(Clip{
		id = "clip-1",
		source_id = "source-1",
		name = "Repaired",
		start_seconds = 2,
		end_seconds = 8,
		clip_path = "/tmp/repaired.mp4",
	})
	testing.expect(t, !repaired)
	testing.expect_value(t, index, -1)
	testing.expect_value(t, state.clips[0].name, "Original")
	testing.expect_value(t, state.clips[0].clip_path, "/tmp/original.mp4")

	statement, prepared := sqlite_prepare(
		fixture.database,
		"SELECT name, clip_path FROM clips WHERE id = 'clip-1'",
	)
	testing.expect(t, prepared)
	if !prepared {return}
	testing.expect_value(t, sqlite3_step(statement), SQLITE_ROW)
	name := sqlite3_column_text(statement, 0)
	clip_path := sqlite3_column_text(statement, 1)
	testing.expect(t, name != nil && clip_path != nil)
	if name != nil {testing.expect_value(t, string(name), "Original")}
	if clip_path != nil {
		testing.expect_value(t, string(clip_path), "/tmp/original.mp4")
	}
	sqlite3_finalize(statement)

	testing.expect(t, sqlite_execute(fixture.database, "DROP TRIGGER fail_clip_insert"))
	index, repaired = repair_clip_apply(Clip{
		id = "clip-1",
		source_id = "source-1",
		name = "Repaired",
		start_seconds = 2,
		end_seconds = 8,
		clip_path = "/tmp/repaired.mp4",
	})
	testing.expect(t, repaired)
	testing.expect_value(t, index, 0)
	testing.expect_value(t, state.clips[0].name, "Repaired")

	loaded: App_State
	testing.expect(t, database_load_state(fixture.database, &loaded))
	defer app_state_collections_destroy(&loaded)
	testing.expect_value(t, len(loaded.clips), 1)
	testing.expect_value(t, loaded.clips[0].name, "Repaired")
	testing.expect_value(t, loaded.clips[0].clip_path, "/tmp/repaired.mp4")
}

@(test)
library_recovery_quality_requires_the_saved_height_test :: proc(t: ^testing.T) {
	selector := download_format_selector(720, true)
	testing.expect(t, strings.contains(selector, "height=720"))
	testing.expect(t, !strings.contains(selector, "height<=720"))
}

@(test)
mode_control_slots_expose_only_relevant_actions_test :: proc(t: ^testing.T) {
	previous_workflow := ui.workflow
	defer ui.workflow = previous_workflow
	ui.workflow = .Vocal
	create_actions := [8]int{5, 7, 3, 4, 6, 0, 1, 2}
	for action, slot in create_actions {
		testing.expect_value(t, control_action_for_slot(.Create, slot), action)
		testing.expect_value(t, control_slot_for_action(.Create, action), slot)
	}
	play_actions := [10]int{12, 10, 8, 9, 7, 3, 4, 13, 14, 11}
	for action, slot in play_actions {
		testing.expect_value(t, control_action_for_slot(.Play, slot), action)
		testing.expect_value(t, control_slot_for_action(.Play, action), slot)
	}
	testing.expect_value(t, control_slot_for_action(.Play, 0), -1)
}

@(test)
dancing_control_slots_replace_pitch_with_dance_tools_test :: proc(t: ^testing.T) {
	previous_workflow := ui.workflow
	defer ui.workflow = previous_workflow
	ui.workflow = .Dancing
	actions := [13]int{
		12, 10, 8, 9, 7,
		3, 4, 13, 14,
		DANCE_MIRROR_ACTION_INDEX,
		DANCE_LOOP_ACTION_INDEX,
		DANCE_COUNT_IN_ACTION_INDEX,
		DANCE_COUNT_EACH_LOOP_ACTION_INDEX,
	}
	testing.expect_value(t, control_slot_count(.Play), len(actions))
	for action, slot in actions {
		testing.expect_value(t, control_action_for_slot(.Play, slot), action)
		testing.expect_value(t, control_slot_for_action(.Play, action), slot)
	}
	testing.expect_value(t, numbered_action_for_code(.Play, 3, 1), DANCE_MIRROR_ACTION_INDEX)
	testing.expect_value(t, numbered_action_for_code(.Play, 3, 4), DANCE_COUNT_EACH_LOOP_ACTION_INDEX)
}

@(test)
numbered_action_codes_match_interface_sections_test :: proc(t: ^testing.T) {
	previous_workflow := ui.workflow
	defer ui.workflow = previous_workflow
	ui.workflow = .Vocal
	create_codes := [8]Numbered_Action_Code{
		{1, 1}, {1, 2}, {2, 1}, {2, 2},
		{2, 3}, {3, 1}, {3, 2}, {3, 3},
	}
	for code, slot in create_codes {
		action := control_action_for_slot(.Create, slot)
		actual, found := numbered_action_code_for_action(.Create, action)
		testing.expect(t, found)
		testing.expect_value(t, actual, code)
		testing.expect_value(
			t,
			numbered_action_for_code(.Create, code.section, code.action),
			action,
		)
	}
	play_codes := [10]Numbered_Action_Code{
		{1, 1}, {1, 2}, {1, 3}, {1, 4}, {1, 5},
		{2, 1}, {2, 2}, {2, 3}, {2, 4}, {3, 1},
	}
	for code, slot in play_codes {
		action := control_action_for_slot(.Play, slot)
		actual, found := numbered_action_code_for_action(.Play, action)
		testing.expect(t, found)
		testing.expect_value(t, actual, code)
		testing.expect_value(
			t,
			numbered_action_for_code(.Play, code.section, code.action),
			action,
		)
	}
	testing.expect_value(t, pitch_numbered_action_text(), "31")
}

@(test)
dancing_clip_navigation_stays_inside_the_active_workflow_test :: proc(t: ^testing.T) {
	previous_workflow := ui.workflow
	defer ui.workflow = previous_workflow
	clips := [4]Clip{
		{workflow=.Vocal, name="Warm up"},
		{workflow=.Dancing, name="Warm up"},
		{workflow=.Vocal, name="Warm down"},
		{workflow=.Dancing, name="Warm down"},
	}
	ui.workflow = .Vocal
	testing.expect_value(t, next_filtered_clip_index(clips[:], -1, "Warm"), 0)
	testing.expect_value(t, next_filtered_clip_index(clips[:], 0, "Warm"), 2)
	ui.workflow = .Dancing
	testing.expect_value(t, next_filtered_clip_index(clips[:], -1, "Warm"), 1)
	testing.expect_value(t, next_filtered_clip_index(clips[:], 1, "Warm"), 3)
}

@(test)
dancing_mirror_swaps_only_horizontal_texture_coordinates_test :: proc(t: ^testing.T) {
	previous_width, previous_height := ui.width, ui.height
	defer ui.width, ui.height = previous_width, previous_height
	ui.width, ui.height = 100, 100
	normal := texture_rect_vertices({0, 0, 100, 100}, {1, 1, 1, 1})
	mirrored := texture_rect_vertices({0, 0, 100, 100}, {1, 1, 1, 1}, true)
	for index in 0 ..< len(normal) {
		testing.expect_value(t, mirrored[index].u, 1 - normal[index].u)
		testing.expect_value(t, mirrored[index].v, normal[index].v)
		testing.expect_value(t, mirrored[index].x, normal[index].x)
		testing.expect_value(t, mirrored[index].y, normal[index].y)
	}
}

@(test)
dancing_count_in_interval_uses_saved_bpm_test :: proc(t: ^testing.T) {
	testing.expect_value(t, dance_count_in_interval_ms(40), i64(1500))
	testing.expect_value(t, dance_count_in_interval_ms(120), i64(500))
	testing.expect_value(t, dance_count_in_interval_ms(240), i64(250))
}

@(test)
numbered_action_keys_use_digits_one_through_nine_test :: proc(t: ^testing.T) {
	key_codes := [9]uint{18, 19, 20, 21, 23, 22, 26, 28, 25}
	for key_code, index in key_codes {
		digit, found := number_digit_for_key_code(key_code)
		testing.expect(t, found)
		testing.expect_value(t, digit, index+1)
	}
	_, found := number_digit_for_key_code(29)
	testing.expect(t, !found)
}

@(test)
shortcut_recorder_reserves_only_its_numbered_actions_test :: proc(
	t: ^testing.T,
) {
	testing.expect_value(t, shortcut_digit_route(1), Shortcut_Digit_Route.Save)
	testing.expect_value(t, shortcut_digit_route(2), Shortcut_Digit_Route.Reset)
	testing.expect_value(t, shortcut_digit_route(3), Shortcut_Digit_Route.Cancel)
	for digit in 4 ..= 9 {
		testing.expect_value(
			t,
			shortcut_digit_route(digit),
			Shortcut_Digit_Route.Capture,
		)
	}
}

@(test)
numbered_action_prefix_waits_expires_and_clears_test :: proc(t: ^testing.T) {
	old_prefix := ui.number_prefix
	old_deadline := ui.number_prefix_deadline_ms
	old_redraw := ui.needs_redraw
	defer {
		ui.number_prefix = old_prefix
		ui.number_prefix_deadline_ms = old_deadline
		ui.needs_redraw = old_redraw
	}
	clear_number_prefix()
	action, handled := consume_numbered_action_digit_at(.Play, 2, 10_000)
	testing.expect(t, handled)
	testing.expect_value(t, action, -1)
	testing.expect_value(t, ui.number_prefix, 2)

	action, handled = consume_numbered_action_digit_at(.Play, 3, 10_500)
	testing.expect(t, handled)
	testing.expect_value(t, action, 13)
	testing.expect_value(t, ui.number_prefix, 0)

	action, handled = consume_numbered_action_digit_at(.Play, 2, 20_000)
	testing.expect(t, handled)
	action, handled = consume_numbered_action_digit_at(.Play, 3, 21_000)
	testing.expect(t, handled)
	testing.expect_value(t, action, -1)
	testing.expect_value(t, ui.number_prefix, 3)

	action, handled = consume_numbered_action_digit_at(.Play, 9, 21_100)
	testing.expect(t, handled)
	testing.expect_value(t, action, -1)
	testing.expect_value(t, ui.number_prefix, 0)
}

@(test)
pitch_monitor_registers_controls_and_help_overlay_test :: proc(
	t: ^testing.T,
) {
	previous_state := state
	previous_ui := ui
	previous_ui_build := ui_build
	previous_recovery := library_recovery_state
	previous_pending := major_change_pending
	defer {
		state = previous_state
		ui = previous_ui
		ui_build = previous_ui_build
		library_recovery_state = previous_recovery
		major_change_pending = previous_pending
	}
	state = App_State{active_source = -1}
	ui = UI_State{
		width = 1100,
		height = 720,
		mode = .Play,
		active_clip = -1,
		source_details_index = -1,
		source_modal_refetch_index = -1,
		clip_rename_index = -1,
		clip_metadata_index = -1,
		transcript_active_match = -1,
	}
	ui.pitch.settings = pitch_default_settings()
	ui.pitch.permission = .Unknown
	library_recovery_state = {}
	major_change_pending = {}

	frame_arena: mem_virtual.Arena
	frame_error := mem_virtual.arena_init_static(
		&frame_arena,
		1024 * 1024,
		4096,
	)
	testing.expect(t, frame_error == nil)
	if frame_error != nil {return}
	defer mem_virtual.arena_destroy(&frame_arena)
	build_ui_controls(false, mem_virtual.arena_allocator(&frame_arena))
	testing.expect(t, ui_controls_valid(ui_build.controls[:]))
	testing.expect(t, find_ui_control_by_action(.Pitch_Toggle) != nil)
	testing.expect(t, find_ui_control_by_action(.Pitch_Reference_Down) != nil)
	testing.expect(t, find_ui_control_by_action(.Pitch_Reference_Up) != nil)
	for index in 0 ..< 3 {
		testing.expect(t, find_ui_control_by_action_and_index(.Pitch_Range, index) != nil)
		testing.expect(t, find_ui_control_by_action_and_index(.Pitch_Labels, index) != nil)
	}
	for index in 0 ..< 12 {
		testing.expect(t, find_ui_control_by_action_and_index(.Pitch_Transpose, index) != nil)
	}
	chart := find_ui_control_by_action(.Pitch_Chart)
	testing.expect(t, chart != nil)
	if chart != nil {
		testing.expect(t, .Accessibility in chart.flags)
		testing.expect(t, .Flash not_in chart.flags)
		testing.expect(t, .Primary_Press not_in chart.flags)
	}

	ui.pitch.help_open = true
	build_ui_controls(false, mem_virtual.arena_allocator(&frame_arena))
	testing.expect_value(t, ui_build.diagnostic_surface.overlay, "pitch-help")
	testing.expect(t, find_ui_control_by_action(.Close_Pitch_Help) != nil)
	testing.expect(t, find_ui_control_by_action(.Pitch_Toggle) == nil)
}

@(test)
dancing_tools_register_controls_without_pitch_controls_test :: proc(
	t: ^testing.T,
) {
	previous_state := state
	previous_ui := ui
	previous_ui_build := ui_build
	previous_recovery := library_recovery_state
	previous_pending := major_change_pending
	state = {}
	defer {
		app_state_collections_destroy(&state)
		state = previous_state
		ui = previous_ui
		ui_build = previous_ui_build
		library_recovery_state = previous_recovery
		major_change_pending = previous_pending
	}
	state.sources = make([dynamic]Source_Video)
	state.hints = make([dynamic]Import_Hint)
	state.clips = make([dynamic]Clip)
	transcripts, transcripts_ok := transcript_generation_create(0)
	testing.expect(t, transcripts_ok)
	if !transcripts_ok {return}
	state.transcripts = transcripts
	clip, clip_ok := clone_clip(Clip{
		id="dance-clip",
		source_id="dance-source",
		workflow=.Dancing,
		dance_count_in_bpm=120,
		dance_playback_rate=1,
	})
	testing.expect(t, clip_ok)
	if !clip_ok {return}
	append(&state.clips, clip)
	ui = UI_State{
		width=1100,
		height=720,
		mode=.Play,
		workflow=.Dancing,
		active_clip=0,
		source_details_index=-1,
		source_modal_refetch_index=-1,
		clip_rename_index=-1,
		clip_metadata_index=-1,
		transcript_active_match=-1,
	}
	library_recovery_state = {}
	major_change_pending = {}
	frame_arena: mem_virtual.Arena
	frame_error := mem_virtual.arena_init_static(
		&frame_arena,
		1024 * 1024,
		4096,
	)
	testing.expect(t, frame_error == nil)
	if frame_error != nil {return}
	defer mem_virtual.arena_destroy(&frame_arena)
	build_ui_controls(false, mem_virtual.arena_allocator(&frame_arena))
	testing.expect(t, ui_controls_valid(ui_build.controls[:]))
	dance_kinds := [6]UI_Action_Kind{
		.Dance_Mirror_Toggle,
		.Dance_Loop_Toggle,
		.Dance_Count_In,
		.Dance_Count_Each_Loop_Toggle,
		.Dance_BPM_Down,
		.Dance_BPM_Up,
	}
	for kind in dance_kinds {
		testing.expect(t, find_ui_control_by_action(kind) != nil)
	}
	testing.expect(t, find_ui_control_by_action(.Pitch_Toggle) == nil)
	testing.expect(t, find_ui_control_by_action(.Pitch_Reference_Down) == nil)
}

@(test)
pitch_action_availability_matches_microphone_permission_test :: proc(
	t: ^testing.T,
) {
	previous_ui := ui
	defer ui = previous_ui
	ui = UI_State{mode = .Play}
	ui.pitch.permission = .Unknown
	testing.expect(t, ui_action_enabled_for_current_job(.Pitch_Toggle))
	ui.pitch.permission = .Authorized
	testing.expect(t, ui_action_enabled_for_current_job(.Pitch_Toggle))
	ui.pitch.permission = .Denied
	testing.expect(t, !ui_action_enabled_for_current_job(.Pitch_Toggle))
	ui.pitch.permission = .Restricted
	testing.expect(t, !ui_action_enabled_for_current_job(.Pitch_Toggle))
	ui.pitch.permission = .Authorized
	ui.pitch.permission_pending = true
	testing.expect(t, !ui_action_enabled_for_current_job(.Pitch_Toggle))
	ui.mode = .Create
	ui.pitch.permission_pending = false
	testing.expect(t, !ui_action_enabled_for_current_job(.Pitch_Toggle))
}

@(test)
random_clip_weight_increases_with_skipped_draws_test :: proc(t: ^testing.T) {
	testing.expect_value(t, random_clip_weight(10, 10), 2)
	testing.expect_value(t, random_clip_weight(9, 10), 3)
	testing.expect_value(t, random_clip_weight(8, 10), 4)
	testing.expect_value(t, random_clip_weight(7, 10), 5)
	testing.expect_value(t, random_clip_weight(6, 10), 6)
	testing.expect_value(t, random_clip_weight(1, 10), 6)
	testing.expect_value(t, random_clip_weight(0, 10), 6)
}

@(test)
play_next_clip_index_respects_filter_and_wraps_test :: proc(
	t: ^testing.T,
) {
	clips := [4]Clip{
		{name = "Warm up"},
		{name = "Breathing"},
		{name = "Warm down"},
		{name = "Resonance"},
	}
	testing.expect_value(
		t,
		next_filtered_clip_index(clips[:], -1, "Warm"),
		0,
	)
	testing.expect_value(
		t,
		next_filtered_clip_index(clips[:], 0, "Warm"),
		2,
	)
	testing.expect_value(
		t,
		next_filtered_clip_index(clips[:], 2, "Warm"),
		0,
	)
	testing.expect_value(
		t,
		next_filtered_clip_index(clips[:], 1, "Warm"),
		0,
	)
	testing.expect_value(
		t,
		next_filtered_clip_index(clips[:], 0, "Missing"),
		-1,
	)
}

@(test)
shuffled_play_next_uses_randomize_weights_within_filter_test :: proc(
	t: ^testing.T,
) {
	clips := [3]Clip{
		{name = "Warm up", last_randomized_sequence = 10},
		{name = "Breathing", last_randomized_sequence = 9},
		{name = "Warm down", last_randomized_sequence = 0},
	}
	testing.expect_value(
		t,
		filtered_random_clip_total_weight(clips[:], -1, "Warm"),
		8,
	)
	for roll in 0 ..< 8 {
		expected := 2
		if roll < 2 {expected = 0}
		testing.expect_value(
			t,
			filtered_random_clip_index_for_weighted_roll(
				clips[:],
				-1,
				"Warm",
				roll,
			),
			expected,
		)
	}
	testing.expect_value(
		t,
		filtered_random_clip_total_weight(clips[:], 0, "Warm"),
		6,
	)
	testing.expect_value(
		t,
		filtered_random_clip_index_for_weighted_roll(
			clips[:],
			0,
			"Warm",
			0,
		),
		2,
	)
}

@(test)
clip_autoplay_advances_only_after_clip_completion_test :: proc(
	t: ^testing.T,
) {
	testing.expect(t, playback_position_finished(10, 10))
	testing.expect(t, playback_position_finished(9.96, 10))
	testing.expect(t, !playback_position_finished(9.9, 10))
	testing.expect(
		t,
		clip_autoplay_should_advance(
			true,
			true,
			false,
			.Play,
			0,
			1,
		),
	)
	testing.expect(
		t,
		!clip_autoplay_should_advance(
			true,
			false,
			false,
			.Play,
			0,
			1,
		),
	)
	testing.expect(
		t,
		!clip_autoplay_should_advance(
			true,
			true,
			true,
			.Play,
			0,
			1,
		),
	)
	testing.expect(
		t,
		!clip_autoplay_should_advance(
			false,
			true,
			false,
			.Play,
			0,
			1,
		),
	)
	testing.expect(
		t,
		!clip_autoplay_should_advance(
			true,
			true,
			false,
			.Create,
			0,
			1,
		),
	)
	testing.expect(
		t,
		!clip_autoplay_should_advance(
			true,
			true,
			false,
			.Play,
			-1,
			1,
		),
	)
}

@(test)
random_clip_weighted_roll_uses_exact_weight_ranges_test :: proc(
	t: ^testing.T,
) {
	clips := [3]Clip{
		{last_randomized_sequence = 10},
		{last_randomized_sequence = 9},
		{last_randomized_sequence = 0},
	}
	testing.expect_value(t, random_clip_total_weight(clips[:], -1), 11)
	for roll in 0..<11 {
		expected := 2
		if roll < 2 {
			expected = 0
		} else if roll < 5 {
			expected = 1
		}
		testing.expect_value(
			t,
			random_clip_index_for_weighted_roll(clips[:], -1, roll),
			expected,
		)
	}
	testing.expect_value(t, random_clip_total_weight(clips[:], 1), 8)
	for roll in 0..<8 {
		expected := 2
		if roll < 2 {expected = 0}
		selected := random_clip_index_for_weighted_roll(
			clips[:],
			1,
			roll,
		)
		testing.expect_value(t, selected, expected)
		testing.expect(t, selected != 1)
	}
}

@(test)
random_clip_weighted_roll_handles_empty_and_single_libraries_test :: proc(
	t: ^testing.T,
) {
	empty: [0]Clip
	testing.expect_value(t, random_clip_total_weight(empty[:], -1), 0)
	testing.expect_value(
		t,
		random_clip_index_for_weighted_roll(empty[:], -1, 0),
		-1,
	)
	single := [1]Clip{{last_randomized_sequence = 4}}
	testing.expect_value(t, random_clip_total_weight(single[:], 0), 2)
	testing.expect_value(
		t,
		random_clip_index_for_weighted_roll(single[:], 0, 0),
		0,
	)
}

@(test)
random_clip_help_ranks_the_next_draw_candidates_test :: proc(
	t: ^testing.T,
) {
	clips := [4]Clip{
		{last_randomized_sequence = 10},
		{last_randomized_sequence = 9},
		{last_randomized_sequence = 0},
		{last_randomized_sequence = 8},
	}
	candidates: [RANDOM_CLIP_HELP_LIMIT]Random_Clip_Candidate
	count, total := random_clip_ranked_candidates(
		clips[:],
		1,
		candidates[:],
	)
	testing.expect_value(t, count, 3)
	testing.expect_value(t, total, 12)
	testing.expect_value(t, candidates[0].clip_index, 2)
	testing.expect_value(t, candidates[0].weight, 6)
	testing.expect_value(t, candidates[1].clip_index, 3)
	testing.expect_value(t, candidates[1].weight, 4)
	testing.expect_value(t, candidates[2].clip_index, 0)
	testing.expect_value(t, candidates[2].weight, 2)
}

@(test)
random_clip_help_limits_results_and_keeps_library_order_for_ties_test :: proc(
	t: ^testing.T,
) {
	clips: [12]Clip
	candidates: [RANDOM_CLIP_HELP_LIMIT]Random_Clip_Candidate
	count, total := random_clip_ranked_candidates(
		clips[:],
		-1,
		candidates[:],
	)
	testing.expect_value(t, count, RANDOM_CLIP_HELP_LIMIT)
	testing.expect_value(t, total, 72)
	for candidate, index in candidates {
		testing.expect_value(t, candidate.clip_index, index)
		testing.expect_value(t, candidate.weight, 6)
	}

	single := [1]Clip{{last_randomized_sequence = 4}}
	count, total = random_clip_ranked_candidates(
		single[:],
		0,
		candidates[:],
	)
	testing.expect_value(t, count, 1)
	testing.expect_value(t, total, 2)
	testing.expect_value(t, candidates[0].clip_index, 0)
}

@(test)
random_clip_history_survives_collection_replacement_and_prunes_removed_ids_test :: proc(
	t: ^testing.T,
) {
	database: ^SQLite_DB
	path := strings.clone_to_cstring(":memory:")
	defer delete(path)
	opened := sqlite3_open_v2(
		path,
		&database,
		SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE,
		nil,
	) == SQLITE_OK
	testing.expect(t, opened)
	if !opened {return}
	defer sqlite3_close(database)
	testing.expect(t, database_create_schema(database))

	sources := [1]Source_Video{{
		id = "source-1",
		video_id = "video-1",
		title = "Source",
		url = "https://youtu.be/video-1",
		media_path = "/tmp/source.mp4",
		duration = 60,
	}}
	clips := [2]Clip{
		{
			id = "clip-1",
			source_id = "source-1",
			name = "One",
			start_seconds = 1,
			end_seconds = 2,
			clip_path = "/tmp/one.mp4",
		},
		{
			id = "clip-2",
			source_id = "source-1",
			name = "Two",
			start_seconds = 3,
			end_seconds = 4,
			clip_path = "/tmp/two.mp4",
		},
	}
	testing.expect(t, database_save_collections(
		database,
		sources[:],
		nil,
		nil,
		clips[:],
	))
	testing.expect(t, database_clip_randomization_save(
		database,
		"clip-1",
		7,
	))
	testing.expect(t, database_clip_randomization_save(
		database,
		"clip-2",
		4,
	))
	loaded: App_State
	testing.expect(t, database_load_state(database, &loaded))
	defer app_state_collections_destroy(&loaded)
	testing.expect_value(t, loaded.clips[0].last_randomized_sequence, i64(7))
	testing.expect_value(t, loaded.clips[1].last_randomized_sequence, i64(4))

	imported := [2]Clip{
		{
			id = "clip-1",
			source_id = "source-1",
			name = "One imported",
			start_seconds = 1,
			end_seconds = 2,
			clip_path = "/tmp/one.mp4",
		},
		{
			id = "clip-2",
			source_id = "source-1",
			name = "Two imported",
			start_seconds = 3,
			end_seconds = 4,
			clip_path = "/tmp/two.mp4",
		},
	}
	testing.expect(t, database_save_collections(
		database,
		sources[:],
		nil,
		nil,
		imported[:],
	))
	testing.expect_value(t, imported[0].last_randomized_sequence, i64(7))
	testing.expect_value(t, imported[1].last_randomized_sequence, i64(4))

	remaining := [1]Clip{imported[0]}
	testing.expect(t, database_save_collections(
		database,
		sources[:],
		nil,
		nil,
		remaining[:],
	))
	count, counted := database_count(database, "clip_randomization")
	testing.expect(t, counted)
	testing.expect_value(t, count, 1)
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
clip_rename_modal_keeps_original_name_above_input_test :: proc(t: ^testing.T) {
	modal := clip_rename_modal_rect_for_size(1100, 720)
	input := clip_rename_input_rect(modal)
	cancel := clip_rename_cancel_rect(modal)
	confirm := clip_rename_confirm_rect(modal)
	original_name_bottom := modal.y + modal.h - 130
	testing.expect(t, original_name_bottom > input.y + input.h)
	testing.expect(t, input.y > cancel.y + cancel.h)
	testing.expect(t, input.y > confirm.y + confirm.h)
	testing.expect(t, cancel.x >= modal.x && cancel.x + cancel.w <= modal.x + modal.w)
	testing.expect(t, confirm.x >= modal.x && confirm.x + confirm.w <= modal.x + modal.w)
}

@(test)
clip_metadata_modal_contains_rows_and_actions_test :: proc(t: ^testing.T) {
	modal := clip_metadata_modal_rect_for_size(1100, 720)
	last_row := clip_metadata_row_rect(modal, 9)
	close_button := clip_metadata_close_rect(modal)
	source_button := clip_metadata_source_rect(modal)
	testing.expect_value(t, modal.x + modal.w / 2, 550.0)
	testing.expect(t, last_row.y > close_button.y + close_button.h)
	testing.expect(t, last_row.y > source_button.y + source_button.h)
	testing.expect(t, close_button.x >= modal.x && close_button.x + close_button.w <= modal.x + modal.w)
	testing.expect(t, source_button.x >= modal.x && source_button.x + source_button.w <= modal.x + modal.w)
}

@(test)
data_modal_registers_scoped_export_and_numbered_actions_test :: proc(t: ^testing.T) {
	previous_width := ui.width
	previous_height := ui.height
	previous_open := ui.data_modal_open
	previous_confirm := ui.library_import_confirm_open
	previous_workflow := ui.workflow
	previous_ui_build := ui_build
	defer {
		ui.width = previous_width
		ui.height = previous_height
		ui.data_modal_open = previous_open
		ui.library_import_confirm_open = previous_confirm
		ui.workflow = previous_workflow
		ui_build = previous_ui_build
	}
	ui.width = 1100
	ui.height = 720
	ui.data_modal_open = true
	ui.library_import_confirm_open = false
	ui.workflow = .Dancing

	frame_arena: mem_virtual.Arena
	frame_error := mem_virtual.arena_init_static(&frame_arena, 1024*1024, 4096)
	testing.expect(t, frame_error == nil)
	if frame_error != nil {return}
	defer mem_virtual.arena_destroy(&frame_arena)
	build_ui_controls(false, mem_virtual.arena_allocator(&frame_arena))

	actions := [5]UI_Action_Kind{
		.Export_Library,
		.Export_Current_Workflow,
		.Import_Library,
		.Open_Data_Folder,
		.Close_Data_Modal,
	}
	modal := data_modal_rect()
	for action, index in actions {
		control := find_ui_control_by_action(action)
		testing.expect(t, control != nil)
		if control == nil {continue}
		expected := data_modal_action_rect(modal, index)
		testing.expect_value(t, control.rect, expected)
		testing.expect(t, control.rect.x >= modal.x)
		testing.expect(t, control.rect.y >= modal.y)
		testing.expect(t, control.rect.x + control.rect.w <= modal.x + modal.w)
		testing.expect(t, control.rect.y + control.rect.h <= modal.y + modal.h)
	}
	testing.expect(t, ui_controls_valid(ui_build.controls[:]))
	ui_build.controls = nil
}

@(test)
notification_history_modal_contains_list_detail_and_registered_rows_test :: proc(
	t: ^testing.T,
) {
	modal := notification_modal_rect_for_size(1100, 720)
	list := notification_list_rect(modal)
	detail := notification_detail_rect(modal)
	close_button := notification_history_close_rect(modal)
	action := notification_history_action_rect(modal)
	testing.expect(t, list.x >= modal.x && list.x + list.w <= modal.x + modal.w)
	testing.expect(t, detail.x > list.x + list.w)
	testing.expect(t, detail.x + detail.w <= modal.x + modal.w)
	testing.expect(t, close_button.y >= modal.y)
	testing.expect(t, action.x + action.w <= modal.x + modal.w)

	notification_history_destroy()
	notification_history.entries = make([dynamic]Notification)
	notification_history.initialized = true
	append(&notification_history.entries, Notification{
		id = 41,
		created_at_ms = 1,
		updated_at_ms = 1,
		kind = .Info,
		summary = strings.clone("First"),
		detail = strings.clone("First detail"),
		action_target = strings.clone(""),
	})
	append(&notification_history.entries, Notification{
		id = 42,
		created_at_ms = 2,
		updated_at_ms = 2,
		kind = .Success,
		summary = strings.clone("Second"),
		detail = strings.clone("Second detail"),
		action_target = strings.clone(""),
	})
	notification_history.selected_id = 42
	previous_width := ui.width
	previous_height := ui.height
	previous_open := ui.notification_modal_open
	previous_ui_build := ui_build
	defer {
		ui.width = previous_width
		ui.height = previous_height
		ui.notification_modal_open = previous_open
		ui_build = previous_ui_build
		notification_history_destroy()
	}
	ui.width = 1100
	ui.height = 720
	ui.notification_modal_open = true
	frame_arena: mem_virtual.Arena
	frame_error := mem_virtual.arena_init_static(&frame_arena, 1024*1024, 4096)
	testing.expect(t, frame_error == nil)
	if frame_error != nil {return}
	defer mem_virtual.arena_destroy(&frame_arena)
	build_ui_controls(false, mem_virtual.arena_allocator(&frame_arena))
	testing.expect(t, ui_controls_valid(ui_build.controls[:]))
	testing.expect(t, find_ui_control_by_action(.Close_Notification_History) != nil)
	testing.expect(t, find_ui_control_by_action_and_index(.Select_Notification, 42) != nil)
	testing.expect(t, find_ui_control_by_action(.Open_Notification_History) == nil)
	ui_build.controls = nil
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
	status, ok := download_progress_status("noise\nHW_VIDEO_CLIPS_PROGRESS| 12.5%|80.0MiB|4.0MiB/s|00:18\nHW_VIDEO_CLIPS_PROGRESS| 25.0%|80.0MiB|5.0MiB/s|00:12\n")
	testing.expect(t, ok)
	testing.expect_value(t, status, "Downloading 25.0% / 80.0MiB / 5.0MiB/s / ETA 00:12")
	_, ok = download_progress_status("noise only")
	testing.expect(t, !ok)
}

@(test)
import_progress_ignores_stale_download_during_existing_media_validation_test :: proc(
	t: ^testing.T,
) {
	job := Import_Job{
		phase = .Validating_Existing_Media,
		library_recovery_source = true,
		recovery_index = 3,
		recovery_total = 7,
	}
	status := import_progress_status(
		&job,
		"HW_VIDEO_CLIPS_PROGRESS|100.0%|7.18MiB|8.27MiB/s|NA\n",
	)
	testing.expect_value(
		t,
		status,
		"Recovering source 3 of 7: validating existing media",
	)
}

@(test)
import_progress_reports_download_finalization_and_clip_rebuild_phases_test :: proc(
	t: ^testing.T,
) {
	job := Import_Job{
		phase = .Downloading,
		library_recovery_source = true,
		recovery_index = 7,
		recovery_total = 7,
	}
	status := import_progress_status(
		&job,
		"HW_VIDEO_CLIPS_PROGRESS|100.0%|7.18MiB|8.27MiB/s|NA\n",
	)
	testing.expect_value(
		t,
		status,
		"Recovering source 7 of 7: finalizing downloaded media",
	)
	job.phase = .Rebuilding_Clips
	status = import_progress_status(
		&job,
		"HW_VIDEO_CLIPS_PROGRESS|100.0%|7.18MiB|8.27MiB/s|NA\n",
	)
	testing.expect_value(
		t,
		status,
		"Recovering source 7 of 7: rebuilding clips",
	)
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
		title = "Clip",
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
source_probe_classifies_youtube_browser_challenges_test :: proc(t: ^testing.T) {
	testing.expect(t, source_probe_auth_required(
		"ERROR: Sign in to confirm you’re not a bot. Use --cookies-from-browser",
	))
	testing.expect(t, source_probe_auth_required(
		"ERROR: Sign in to confirm you're not a bot.",
	))
	testing.expect(t, !source_probe_auth_required("ERROR: Video unavailable"))
	testing.expect(t, source_probe_browser_retry_available(Source_Probe_Result{
		error = "YOUTUBE SIGN-IN REQUIRED",
		auth_required = true,
	}))
	testing.expect(t, source_probe_browser_retry_available(Source_Probe_Result{
		error = "BRAVE SESSION UNAVAILABLE",
		auth_browser = .Brave,
	}))
	testing.expect(t, !source_probe_browser_retry_available(Source_Probe_Result{
		error = "NO VIDEO FORMATS",
		auth_browser = .Brave,
	}))
}

@(test)
source_probe_adds_only_the_explicitly_selected_browser_session_test :: proc(
	t: ^testing.T,
) {
	plain := source_probe_command(
		"https://youtu.be/video",
		allocator=context.temp_allocator,
	)
	plain_has_browser := false
	for argument in plain {
		if argument == "--cookies-from-browser" {plain_has_browser = true}
	}
	testing.expect(t, !plain_has_browser)

	brave := source_probe_command(
		"https://youtu.be/video",
		.Brave,
		context.temp_allocator,
	)
	testing.expect_value(t, brave[1], "--cookies-from-browser")
	testing.expect_value(t, brave[2], "brave")
	testing.expect_value(t, source_auth_browser_name(.Brave), "Brave")
	testing.expect_value(t, source_auth_browser_argument(.Firefox), "firefox")
	testing.expect_value(
		t,
		source_auth_browser_from_argument("safari"),
		Source_Auth_Browser.Safari,
	)
	testing.expect_value(
		t,
		source_auth_browser_from_argument("unsupported"),
		Source_Auth_Browser.None,
	)
}

@(test)
source_browser_choice_round_trips_through_application_preferences_test :: proc(
	t: ^testing.T,
) {
	database: ^SQLite_DB
	path := strings.clone_to_cstring(":memory:")
	defer delete(path)
	opened :=
		sqlite3_open_v2(
			path,
			&database,
			SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE,
			nil,
		) == SQLITE_OK
	testing.expect(t, opened)
	if !opened {return}
	defer sqlite3_close(database)
	testing.expect(t, database_create_schema(database))
	testing.expect_value(
		t,
		database_source_auth_browser_load(database),
		Source_Auth_Browser.None,
	)
	testing.expect(t, database_source_auth_browser_save(database, .Brave))
	testing.expect_value(
		t,
		database_source_auth_browser_load(database),
		Source_Auth_Browser.Brave,
	)
	testing.expect(t, database_save_collections(
		database,
		nil,
		nil,
		nil,
		nil,
	))
	testing.expect_value(
		t,
		database_source_auth_browser_load(database),
		Source_Auth_Browser.Brave,
	)
	testing.expect(t, database_source_auth_browser_clear(database))
	testing.expect_value(
		t,
		database_source_auth_browser_load(database),
		Source_Auth_Browser.None,
	)
}

@(test)
interface_theme_round_trips_through_application_preferences_test :: proc(
	t: ^testing.T,
) {
	database: ^SQLite_DB
	path := strings.clone_to_cstring(":memory:")
	defer delete(path)
	opened := sqlite3_open_v2(
		path,
		&database,
		SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE,
		nil,
	) == SQLITE_OK
	testing.expect(t, opened)
	if !opened {return}
	defer sqlite3_close(database)
	testing.expect(t, database_create_schema(database))
	testing.expect(t, database_interface_theme_load(database))
	testing.expect(t, database_interface_theme_save(database, false))
	testing.expect(t, !database_interface_theme_load(database))
	testing.expect(t, database_interface_theme_save(database, true))
	testing.expect(t, database_interface_theme_load(database))
}

@(test)
active_view_round_trips_through_application_preferences_test :: proc(
	t: ^testing.T,
) {
	database: ^SQLite_DB
	path := strings.clone_to_cstring(":memory:")
	defer delete(path)
	opened := sqlite3_open_v2(
		path,
		&database,
		SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE,
		nil,
	) == SQLITE_OK
	testing.expect(t, opened)
	if !opened {return}
	defer sqlite3_close(database)
	testing.expect(t, database_create_schema(database))

	defaults := Active_View_Preference{workflow = .Vocal, mode = .Create}
	testing.expect_value(t, database_active_view_load(database), defaults)
	preferences := [4]Active_View_Preference{
		{workflow = .Vocal, mode = .Create},
		{workflow = .Vocal, mode = .Play},
		{workflow = .Dancing, mode = .Create},
		{workflow = .Dancing, mode = .Play},
	}
	for preference in preferences {
		testing.expect(t, database_active_view_save(database, preference))
		testing.expect_value(
			t,
			database_active_view_load(database),
			preference,
		)
	}
	testing.expect(
		t,
		sqlite_execute(
			database,
			"UPDATE app_preferences SET value = 'invalid' WHERE key = 'active_view'",
		),
	)
	testing.expect_value(t, database_active_view_load(database), defaults)
	testing.expect(
		t,
		!database_active_view_save(
			database,
			{workflow = Workflow_Kind(99), mode = .Create},
		),
	)
}

@(test)
active_view_persistence_uses_current_workflow_and_workspace_test :: proc(
	t: ^testing.T,
) {
	database: ^SQLite_DB
	path := strings.clone_to_cstring(":memory:")
	defer delete(path)
	opened := sqlite3_open_v2(
		path,
		&database,
		SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE,
		nil,
	) == SQLITE_OK
	testing.expect(t, opened)
	if !opened {return}
	defer sqlite3_close(database)
	testing.expect(t, database_create_schema(database))

	previous_database := library_database
	previous_workflow := ui.workflow
	previous_mode := ui.mode
	defer {
		library_database = previous_database
		ui.workflow = previous_workflow
		ui.mode = previous_mode
	}
	library_database = database
	ui.workflow = .Dancing
	ui.mode = .Play
	persist_active_view_preference()
	testing.expect_value(
		t,
		database_active_view_load(database),
		Active_View_Preference{workflow = .Dancing, mode = .Play},
	)
}

@(test)
flash_leader_round_trips_through_application_preferences_test :: proc(
	t: ^testing.T,
) {
	database: ^SQLite_DB
	path := strings.clone_to_cstring(":memory:")
	defer delete(path)
	opened := sqlite3_open_v2(
		path,
		&database,
		SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE,
		nil,
	) == SQLITE_OK
	testing.expect(t, opened)
	if !opened {return}
	defer sqlite3_close(database)
	testing.expect(t, database_create_schema(database))
	_, found := database_flash_leader_load(database)
	testing.expect(t, !found)
	shortcut := video_clips_shortcut_character("g", {.Control, .Shift})
	encoded, valid := video_clips_shortcut_serialize(
		shortcut,
		context.temp_allocator,
	)
	testing.expect(t, valid)
	testing.expect(t, database_flash_leader_save(database, encoded))
	stored: string
	stored, found = database_flash_leader_load(database)
	testing.expect(t, found)
	defer delete(stored)
	decoded: Video_Clips_Shortcut
	decoded, valid = video_clips_shortcut_deserialize(stored)
	testing.expect(t, valid)
	defer video_clips_shortcut_destroy(&decoded)
	testing.expect(t, video_clips_shortcut_equal(shortcut, decoded))
}

@(test)
source_probe_uses_a_saved_browser_only_after_an_authentication_challenge_test :: proc(
	t: ^testing.T,
) {
	browser := source_probe_saved_retry_browser(
		true,
		.None,
		.Brave,
		true,
	)
	testing.expect_value(t, browser, Source_Auth_Browser.Brave)

	browser = source_probe_saved_retry_browser(
		false,
		.None,
		.Brave,
		true,
	)
	testing.expect_value(t, browser, Source_Auth_Browser.None)

	browser = source_probe_saved_retry_browser(
		true,
		.Firefox,
		.Brave,
		true,
	)
	testing.expect_value(t, browser, Source_Auth_Browser.None)

	browser = source_probe_saved_retry_browser(
		true,
		.None,
		.Brave,
		false,
	)
	testing.expect_value(t, browser, Source_Auth_Browser.None)
}

@(test)
import_quality_retains_browser_choice_for_the_download_test :: proc(t: ^testing.T) {
	qualities := make([dynamic]Import_Quality, context.temp_allocator)
	append(&qualities, Import_Quality{
		video_id="video",
		height=1080,
		exact=true,
		auth_browser=.Brave,
	})
	job := Import_Job{qualities=qualities}
	height, exact, browser := import_job_selected_quality(&job, "video")
	testing.expect_value(t, height, 1080)
	testing.expect(t, exact)
	testing.expect_value(t, browser, Source_Auth_Browser.Brave)
}

@(test)
import_download_adds_only_the_explicitly_selected_browser_session_test :: proc(
	t: ^testing.T,
) {
	plain := import_download_command(
		"https://youtu.be/video",
		"/tmp/video.%(ext)s",
		allocator=context.temp_allocator,
	)
	plain_has_browser := false
	for argument in plain {
		if argument == "--cookies-from-browser" {plain_has_browser = true}
	}
	testing.expect(t, !plain_has_browser)

	brave := import_download_command(
		"https://youtu.be/video",
		"/tmp/video.%(ext)s",
		auth_browser=.Brave,
		allocator=context.temp_allocator,
	)
	testing.expect_value(t, brave[1], "--cookies-from-browser")
	testing.expect_value(t, brave[2], "brave")
}

@(test)
source_browser_choices_fit_inside_the_authentication_row_test :: proc(t: ^testing.T) {
	row := UI_Rect{100, 100, 932, 120}
	count := 3
	previous: UI_Rect
	save_choice := source_probe_save_browser_rect(row)
	testing.expect(t, save_choice.x >= row.x)
	testing.expect(t, save_choice.x+save_choice.w <= row.x+row.w)
	for index in 0 ..< count {
		button := source_probe_browser_rect(row, index, count)
		testing.expect(t, button.x >= row.x)
		testing.expect(t, button.x+button.w <= row.x+row.w)
		testing.expect(t, button.y+button.h < row.y+34)
		if index > 0 {testing.expect(t, button.x > previous.x+previous.w)}
		previous = button
	}
}

@(test)
source_browser_choices_use_the_shared_control_registry_test :: proc(t: ^testing.T) {
	previous_ui := ui
	previous_ui_build := ui_build
	previous_results := source_probe_results
	defer {
		for &result in source_probe_results {source_probe_result_destroy(&result)}
		delete(source_probe_results)
		source_probe_results = previous_results
		ui = previous_ui
		ui_build = previous_ui_build
	}
	ui = UI_State{
		width = 1100,
		height = 720,
		mode = .Create,
		source_modal_open = true,
		source_modal_refetch_index = -1,
		player_volume = 1,
		playback_rate = 1,
		transcript_active_match = -1,
	}
	source_probe_results = make([dynamic]Source_Probe_Result)
	append(&source_probe_results, Source_Probe_Result{
		video_id = strings.clone("video"),
		error = strings.clone("YOUTUBE SIGN-IN REQUIRED"),
		auth_required = true,
	})
	frame_arena: mem_virtual.Arena
	frame_error := mem_virtual.arena_init_static(&frame_arena, 1024*1024, 4096)
	testing.expect(t, frame_error == nil)
	if frame_error != nil {return}
	defer mem_virtual.arena_destroy(&frame_arena)
	build_ui_controls(false, mem_virtual.arena_allocator(&frame_arena))
	testing.expect(t, ui_controls_valid(ui_build.controls[:]))
	save_choice := find_ui_control_by_action(.Toggle_Save_Source_Browser)
	testing.expect(t, save_choice != nil)
	if save_choice != nil {
		testing.expect_value(t, save_choice.accessibility_role, "AXCheckBox")
		testing.expect(t, strings.contains(
			save_choice.accessibility_label,
			"for later, off",
		))
		testing.expect(t, activate_ui_action(save_choice.action))
		testing.expect(t, ui.save_source_browser_choice)
	}
	browser_control_count := 0
	for control in ui_build.controls {
		if control.action.kind != .Retry_Source_With_Browser {continue}
		browser_control_count += 1
		testing.expect(t, strings.contains(
			control.accessibility_label,
			"cookies are not stored or exported",
		))
	}
	testing.expect_value(
		t,
		browser_control_count,
		source_auth_browser_installed_count(),
	)
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
source_and_clip_id_lookups_return_stable_indices_test :: proc(t: ^testing.T) {
	sources := []Source_Video{{id="source-a"}, {id="source-b"}}
	clips := []Clip{{id="clip-a"}, {id="clip-b"}}
	testing.expect_value(t, source_index_for_id(sources, "source-b"), 1)
	testing.expect_value(t, source_index_for_id(sources, "missing"), -1)
	testing.expect_value(t, clip_index_for_id(clips, "clip-a"), 0)
	testing.expect_value(t, clip_index_for_id(clips, "missing"), -1)
	linked_clips := []Clip{{source_id="source-b"}, {source_id="missing"}}
	testing.expect_value(t, source_index_for_clip(sources, linked_clips, 0), 1)
	testing.expect_value(t, source_index_for_clip(sources, linked_clips, 1), -1)
	testing.expect_value(t, source_index_for_clip(sources, linked_clips, 2), -1)
}

@(test)
rename_clip_updates_memory_and_database_test :: proc(t: ^testing.T) {
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
	state.clips = make([dynamic]Clip)
	defer {
		for &source in state.sources {delete_source_video(&source)}
		for &hint in state.hints {delete_import_hint(&hint)}
		for &clip in state.clips {delete_clip(&clip)}
		delete(state.sources)
		delete(state.hints)
		delete(state.clips)
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
	clip, clip_copied := clone_clip(Clip{
		id="clip-1",
		source_id="source-1",
		name="Original",
		start_seconds=2,
		end_seconds=8,
		clip_path="/tmp/clip.mp4",
	})
	testing.expect(t, clip_copied)
	if !clip_copied {return}
	append(&state.clips, clip)
	library_database = database
	library_legacy_fallback = false

	testing.expect(t, rename_clip(0, "  Renamed  "))
	testing.expect_value(t, state.clips[0].name, "Renamed")
	statement, prepared := sqlite_prepare(database, "SELECT name FROM clips WHERE id = 'clip-1'")
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
	indices, search_error := transcript_ranked_indices(
		&search,
		segments,
		4,
		"warmup",
	)
	defer delete(indices)
	testing.expect_value(t, search_error, match_sorter.Search_Error.None)
	testing.expect_value(t, len(indices), 2)
	testing.expect_value(t, indices[0], 5)
	testing.expect_value(t, indices[1], 4)
	missing, missing_error := transcript_ranked_indices(
		&search,
		segments,
		4,
		"zzzz",
	)
	defer delete(missing)
	testing.expect_value(t, missing_error, match_sorter.Search_Error.None)
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
	indices, search_error := transcript_ranked_indices(
		&search,
		segments,
		8,
		"",
	)
	defer delete(indices)
	testing.expect_value(t, search_error, match_sorter.Search_Error.None)
	testing.expect_value(t, len(indices), 2)
	testing.expect_value(t, indices[0], 8)
	testing.expect_value(t, indices[1], 9)
}

@(test)
transcript_search_rejects_invalid_utf8_without_results_test :: proc(
	t: ^testing.T,
) {
	search: match_sorter.Search_Context
	testing.expect(t, match_sorter.search_context_init(&search) == nil)
	defer match_sorter.search_context_destroy(&search)
	invalid_bytes := []byte{0xe2, 0x82}
	segments := []Transcript_Segment{
		{source_id = "a", text = transmute(string)invalid_bytes},
	}
	indices, search_error := transcript_ranked_indices(
		&search,
		segments,
		0,
		"voice",
	)
	testing.expect_value(
		t,
		search_error,
		match_sorter.Search_Error.Invalid_UTF8,
	)
	testing.expect(t, indices == nil)
	indices, search_error = transcript_ranked_indices(
		&search,
		segments,
		0,
		"",
	)
	testing.expect_value(
		t,
		search_error,
		match_sorter.Search_Error.Invalid_UTF8,
	)
	testing.expect(t, indices == nil)
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
	testing.expect(t, is_copy_shortcut(8, NSEventModifierFlagCommand))
	testing.expect(t, is_cut_shortcut(7, NSEventModifierFlagCommand))
	testing.expect(t, is_select_all_shortcut(0, NSEventModifierFlagCommand))
	testing.expect(t, is_delete_word_shortcut(51, NSEventModifierFlagControl))
	testing.expect(t, is_delete_word_shortcut(51, NSEventModifierFlagOption))
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
text_word_selection_uses_utf8_and_character_classes_test :: proc(t: ^testing.T) {
	text := "hello,  café!"
	start, end := text_word_bounds(text, 2)
	testing.expect_value(t, text[start:end], "hello")
	start, end = text_word_bounds(text, 5)
	testing.expect_value(t, text[start:end], ",")
	start, end = text_word_bounds(text, 6)
	testing.expect_value(t, text[start:end], "  ")
	start, end = text_word_bounds(text, strings.index(text, "fé"))
	testing.expect_value(t, text[start:end], "café")
}

@(test)
text_selection_replacement_and_deletion_use_one_range_test :: proc(t: ^testing.T) {
	value := strings.clone("A😀BC")
	defer delete(value)
	previous_caret := ui.caret_byte_offset
	previous_anchor := ui.selection_anchor_byte
	previous_redraw := ui.needs_redraw
	defer {
		ui.caret_byte_offset = previous_caret
		ui.selection_anchor_byte = previous_anchor
		ui.needs_redraw = previous_redraw
	}
	set_text_selection(1, len("A😀B"), value)
	replace_text_selection(&value, "x")
	testing.expect_value(t, value, "AxC")
	testing.expect_value(t, ui.caret_byte_offset, 2)
	testing.expect_value(t, ui.selection_anchor_byte, 2)
	set_text_selection(1, 2, value)
	testing.expect(t, remove_text_selection(&value))
	testing.expect_value(t, value, "AC")
	testing.expect_value(t, ui.caret_byte_offset, 1)
}

@(test)
text_click_counts_select_caret_word_and_all_test :: proc(t: ^testing.T) {
	value := strings.clone("one two")
	defer delete(value)
	previous_caret := ui.caret_byte_offset
	previous_anchor := ui.selection_anchor_byte
	previous_focus := ui.drag_field
	previous_granularity := ui.drag_granularity
	previous_drag := ui.drag_active
	previous_start := ui.drag_origin_start
	previous_end := ui.drag_origin_end
	defer {
		ui.caret_byte_offset = previous_caret
		ui.selection_anchor_byte = previous_anchor
		ui.drag_field = previous_focus
		ui.drag_granularity = previous_granularity
		ui.drag_active = previous_drag
		ui.drag_origin_start = previous_start
		ui.drag_origin_end = previous_end
	}
	begin_text_selection_at_offset(&value, .Clip_Name, 1, 1)
	testing.expect_value(t, ui.selection_anchor_byte, 1)
	testing.expect_value(t, ui.caret_byte_offset, 1)
	begin_text_selection_at_offset(&value, .Clip_Name, 5, 2)
	start, end := text_selection_bounds(value)
	testing.expect_value(t, value[start:end], "two")
	begin_text_selection_at_offset(&value, .Clip_Name, 3, 3)
	start, end = text_selection_bounds(value)
	testing.expect_value(t, start, 0)
	testing.expect_value(t, end, len(value))
	testing.expect(t, !ui.drag_active)
}

@(test)
text_selection_navigation_extends_and_collapses_test :: proc(t: ^testing.T) {
	value := strings.clone("ab\ncafé")
	defer delete(value)
	previous_caret := ui.caret_byte_offset
	previous_anchor := ui.selection_anchor_byte
	previous_redraw := ui.needs_redraw
	defer {
		ui.caret_byte_offset = previous_caret
		ui.selection_anchor_byte = previous_anchor
		ui.needs_redraw = previous_redraw
	}
	collapse_text_selection(1)
	move_text_right(&value, true)
	testing.expect_value(t, ui.selection_anchor_byte, 1)
	testing.expect_value(t, ui.caret_byte_offset, 2)
	move_text_left(&value, false)
	testing.expect_value(t, ui.caret_byte_offset, 1)
	move_text_selection(
		&value,
		vertical_text_offset(value, 1, 1),
		true,
	)
	testing.expect_value(t, ui.selection_anchor_byte, 1)
	testing.expect_value(t, ui.caret_byte_offset, len("ab\nc"))
}

@(test)
text_word_movement_skips_utf8_words_and_delimiters_test :: proc(t: ^testing.T) {
	text := "one,  café_two! end"
	first_end := len("one")
	second_start := len("one,  ")
	second_end := len("one,  café_two")
	third_start := len("one,  café_two! ")
	testing.expect_value(t, next_word_offset(text, 0), first_end)
	testing.expect_value(t, next_word_offset(text, first_end), second_end)
	testing.expect_value(
		t,
		next_word_offset(text, second_start + len("ca")),
		second_end,
	)
	testing.expect_value(t, previous_word_offset(text, len(text)), third_start)
	testing.expect_value(
		t,
		previous_word_offset(text, third_start),
		second_end,
	)
	testing.expect_value(
		t,
		previous_word_offset(text, second_end),
		second_start,
	)
	testing.expect_value(t, previous_word_offset(text, 0), 0)
	testing.expect_value(t, next_word_offset(text, len(text)), len(text))
}

@(test)
text_word_movement_extends_and_collapses_selection_test :: proc(t: ^testing.T) {
	value := strings.clone("one two three")
	defer delete(value)
	previous_caret := ui.caret_byte_offset
	previous_anchor := ui.selection_anchor_byte
	previous_redraw := ui.needs_redraw
	defer {
		ui.caret_byte_offset = previous_caret
		ui.selection_anchor_byte = previous_anchor
		ui.needs_redraw = previous_redraw
	}
	collapse_text_selection(0)
	move_text_word_right(&value, true)
	testing.expect_value(t, ui.selection_anchor_byte, 0)
	testing.expect_value(t, ui.caret_byte_offset, len("one"))
	move_text_word_right(&value, true)
	testing.expect_value(t, ui.caret_byte_offset, len("one two"))
	move_text_word_left(&value, true)
	testing.expect_value(t, ui.caret_byte_offset, len("one "))
	move_text_word_left(&value, false)
	testing.expect_value(t, ui.caret_byte_offset, 0)
	testing.expect_value(t, ui.selection_anchor_byte, 0)
}

@(test)
text_word_movement_preserves_word_end_between_delimiters_test :: proc(t: ^testing.T) {
	text := "Larynx control - GYUUG"
	after_control := len("Larynx control")
	before_control := len("Larynx ")
	before_gyuug := len("Larynx control - ")
	testing.expect_value(t, previous_word_offset(text, len(text)), before_gyuug)
	testing.expect_value(t, previous_word_offset(text, before_gyuug), after_control)
	testing.expect_value(t, previous_word_offset(text, after_control), before_control)
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
	ui.flash_leader = video_clips_shortcut_clone(video_clips_shortcut_default())
	defer video_clips_shortcut_destroy(&ui.flash_leader)
	testing.expect(t, flash_leader_allowed(.None, 44, 0, "/"))
	testing.expect(t, !flash_leader_allowed(.Source_Search, 44, 0, "/"))
	testing.expect(
		t,
		!flash_leader_allowed(
			.None,
			44,
			NSEventModifierFlagCommand,
			"/",
		),
	)
	testing.expect(
		t,
		!flash_leader_allowed(
			.None,
			44,
			NSEventModifierFlagOption,
			"/",
		),
	)
	testing.expect(t, !flash_leader_allowed(.None, 0, 0, "a"))
}

@(test)
escape_unfocuses_each_text_input_kind_test :: proc(t: ^testing.T) {
	testing.expect(t, !escape_should_unfocus(.None))
	testing.expect(t, escape_should_unfocus(.URL))
	testing.expect(t, escape_should_unfocus(.Source_Search))
	testing.expect(t, escape_should_unfocus(.Transcript_Search))
	testing.expect(t, escape_should_unfocus(.Clip_Search))
	testing.expect(t, escape_should_unfocus(.Clip_Name))
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
			functional_name = "save clip",
			action_kind = "Save",
			rect = {x=10, y=20, w=30, h=40},
			flags = enabled_flags,
			accessibility_role = "AXButton",
		},
	}
	current_controls := []UI_Diagnostic_Control{
		{
			id = 1,
			functional_name = "save clip",
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

@(test)
metal_frame_only_renders_for_invalidated_ui_or_active_playback_test :: proc(
	t: ^testing.T,
) {
	testing.expect(t, !metal_frame_should_render(false, false))
	testing.expect(t, metal_frame_should_render(true, false))
	testing.expect(t, metal_frame_should_render(false, true))
	testing.expect(t, metal_frame_should_render(true, true))
}
