package main

import "core:testing"
import "core:encoding/json"
import "core:os"
import "core:strings"
import mem_virtual "core:mem/virtual"

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
exercise_range_validation_test :: proc(t: ^testing.T) {
	testing.expect(t, valid_exercise_range(10, 20, 60))
	testing.expect(t, !valid_exercise_range(-1, 20, 60))
	testing.expect(t, !valid_exercise_range(20, 20, 60))
	testing.expect(t, !valid_exercise_range(20, 61, 60))
	testing.expect(t, valid_exercise_range(20, 61, 0))
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
	objc_handle := os.dlopen("/usr/lib/libobjc.A.dylib", os.RTLD_NOW)
	testing.expect(t, objc_handle != nil)
	testing.expect(t, os.dlopen("/System/Library/Frameworks/AppKit.framework/AppKit", os.RTLD_NOW) != nil)
	testing.expect(t, os.dlopen("/System/Library/Frameworks/AVFoundation.framework/AVFoundation", os.RTLD_NOW) != nil)
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
	testing.expect(t, metal_player_load("/tmp/vocal-training-player-lifetime-one.mp4"))
	first_player := state.player
	msg_void(first_pool, sel_registerName("drain"))
	testing.expect(t, first_player != nil)
	testing.expect(t, msg_f32(first_player, sel_registerName("rate")) >= 0)

	second_pool := msg_id(objc_getClass("NSAutoreleasePool"), sel_registerName("new"))
	testing.expect(t, metal_player_load("/tmp/vocal-training-player-lifetime-two.mp4"))
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
	testing.expect_value(t, generation.segments[0].text, "Warm up")
	testing.expect(t, generation.arena.total_used > 0)
	transcript_generation_destroy(&generation)
	testing.expect(t, generation.arena == nil)
	testing.expect_value(t, len(generation.segments), 0)
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
	testing.expect_value(t, control_action_for_slot(.Play, 2), 7)
	testing.expect_value(t, control_action_for_slot(.Play, 3), -1)
	testing.expect_value(t, control_slot_for_action(.Play, 3), 0)
	testing.expect_value(t, control_slot_for_action(.Play, 4), 1)
	testing.expect_value(t, control_slot_for_action(.Play, 7), 2)
	testing.expect_value(t, control_slot_for_action(.Play, 0), -1)
}

@(test)
command_v_routes_to_paste_test :: proc(t: ^testing.T) {
	NSEventModifierFlagCommand :: uint(1 << 20)
	testing.expect(t, is_paste_shortcut(9, NSEventModifierFlagCommand))
	testing.expect(t, !is_paste_shortcut(9, 0))
	testing.expect(t, !is_paste_shortcut(8, NSEventModifierFlagCommand))
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
mode_button_stays_inside_the_header_test :: proc(t: ^testing.T) {
	rect := mode_button_rect_for_size(1100, 720)
	header := app_header_rect_for_size(1100, 720)
	testing.expect(t, rect.x >= 18)
	testing.expect(t, rect.x+rect.w <= 1100-18)
	testing.expect(t, rect.y >= header.y)
	testing.expect(t, rect.y+rect.h <= 720)
	testing.expect(t, contains(header, Point{rect.x,rect.y}))
	testing.expect(t, contains(header, Point{rect.x+rect.w,rect.y+rect.h}))
}

@(test)
source_header_actions_do_not_overlap_test :: proc(t: ^testing.T) {
	panel := UI_Rect{12, 80, 350, 560}
	add := source_add_button_rect(panel)
	refetch := source_refetch_button_rect(panel)
	testing.expect(t, refetch.x+refetch.w < add.x)
	testing.expect_value(t, refetch.y, add.y)
	testing.expect_value(t, refetch.h, add.h)
	testing.expect(t, refetch.x >= panel.x)
	testing.expect(t, add.x+add.w <= panel.x+panel.w)
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
