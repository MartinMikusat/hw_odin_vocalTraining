package main

import "core:encoding/json"
import "core:fmt"
import os "core:os/old"
import "core:strings"
import "core:testing"

@(test)
ui_automation_schema_accepts_batched_transient_steps :: proc(
	t: ^testing.T,
) {
	scenario := UI_Automation_Scenario{
		schema_version = 1,
		name = "unit",
		mutation = "transient",
		setup = {viewport={width=1280, height=800}},
		steps = []UI_Automation_Step{
			{
				op = "assert",
				condition = {
					kind = "surface",
					field = "mode",
					operator = "eq",
					value = json.String("play"),
				},
			},
			{
				op = "wait",
				timeout_ms = 100,
				condition = {
					kind = "surface",
					field = "render.count",
					operator = "changed",
				},
			},
		},
	}
	testing.expect_value(t, ui_automation_validate(&scenario), "")
}

@(test)
ui_automation_schema_rejects_fixed_waits_and_invalid_mutation :: proc(
	t: ^testing.T,
) {
	scenario := UI_Automation_Scenario{
		schema_version = 1,
		name = "unit",
		mutation = "external",
		setup = {viewport={width=1280, height=800}},
		steps = []UI_Automation_Step{{op="wait", timeout_ms=0}},
	}
	testing.expect(
		t,
		len(ui_automation_validate(&scenario)) > 0,
	)
	scenario.mutation = "transient"
	testing.expect(
		t,
		len(ui_automation_validate(&scenario)) > 0,
	)
}

@(test)
ui_automation_schema_accepts_performance_steps :: proc(t: ^testing.T) {
	scenario := UI_Automation_Scenario{
		schema_version = 1,
		name = "performance",
		mutation = "persistent",
		setup = {viewport={width=1280, height=800}},
		steps = []UI_Automation_Step{
			{op="scrub", seconds=0.5},
			{op="hold", timeout_ms=1000},
			{op="performance_capture"},
		},
	}
	testing.expect_value(t, ui_automation_validate(&scenario), "")
	scenario.steps[0].seconds = -0.1
	testing.expect(t, len(ui_automation_validate(&scenario)) > 0)
}

@(test)
ui_automation_schema_rejects_unsafe_artifact_names :: proc(t: ^testing.T) {
	scenario := UI_Automation_Scenario{
		schema_version = 1,
		name = "../outside",
		mutation = "transient",
		setup = {viewport={width=1280, height=800}},
		steps = []UI_Automation_Step{{
			op = "assert",
			condition = {
				kind = "surface",
				field = "mode",
				operator = "eq",
				value = json.String("play"),
			},
		}},
	}
	testing.expect(
		t,
		len(ui_automation_validate(&scenario)) > 0,
	)
}

@(test)
ui_automation_classifies_action_side_effects :: proc(t: ^testing.T) {
	testing.expect_value(
		t,
		ui_automation_action_effect({
			kind = .Playback_Fullscreen_Toggle,
		}),
		UI_Automation_Action_Effect.Transient,
	)
	testing.expect_value(
		t,
		ui_automation_action_effect({kind=.Set_Theme}),
		UI_Automation_Action_Effect.Persistent,
	)
	testing.expect_value(
		t,
		ui_automation_action_effect({kind=.Speed_Up}),
		UI_Automation_Action_Effect.Persistent,
	)
	testing.expect_value(
		t,
		ui_automation_action_effect({kind=.Import}),
		UI_Automation_Action_Effect.External,
	)
	testing.expect_value(
		t,
		ui_automation_action_effect({kind=.Pitch_Toggle}),
		UI_Automation_Action_Effect.External,
	)
	testing.expect_value(
		t,
		ui_automation_action_effect({kind=.Source, index=-1}),
		UI_Automation_Action_Effect.External,
	)
	testing.expect_value(
		t,
		ui_automation_set_value_effect(.Clip_Name),
		UI_Automation_Action_Effect.Persistent,
	)
	testing.expect_value(
		t,
		ui_automation_set_value_effect(.URL),
		UI_Automation_Action_Effect.External,
	)
}

@(test)
ui_automation_validates_viewport_dimensions :: proc(t: ^testing.T) {
	viewport := UI_Automation_Viewport{width=1280, height=800}
	testing.expect(
		t,
		ui_automation_viewport_matches(viewport, 1280, 800),
	)
	testing.expect(
		t,
		!ui_automation_viewport_matches(viewport, 1279, 800),
	)
}

@(test)
ui_automation_tracks_media_setup_time :: proc(t: ^testing.T) {
	previous_runner := ui_automation_runner
	previous_total := ui_automation_media_setup_total_ms
	defer {
		ui_automation_runner = previous_runner
		ui_automation_media_setup_total_ms = previous_total
	}
	ui_automation_runner.active = false
	testing.expect_value(t, ui_automation_media_setup_begin(), i64(-1))
	ui_automation_runner.active = true
	started_ms := numbered_action_time_ms()-7
	ui_automation_media_setup_finish(started_ms)
	testing.expect(
		t,
		ui_automation_media_setup_total_ms >= previous_total+7,
	)
}

@(test)
ui_automation_clears_transient_notifications :: proc(t: ^testing.T) {
	previous_history := notification_history
	previous_runner := ui_automation_runner
	previous_status := strings.clone(ui.status)
	previous_status_target := strings.clone(ui.status_source_video_id)
	previous_success := ui.status_success
	previous_error := ui.status_error
	defer {
		notification_history_destroy()
		notification_history = previous_history
		ui_automation_runner = previous_runner
		ui_set_string(&ui.status, previous_status)
		ui_set_string(&ui.status_source_video_id, previous_status_target)
		delete(previous_status)
		delete(previous_status_target)
		ui.status_success = previous_success
		ui.status_error = previous_error
	}
	notification_history = {}
	ui_automation_runner = {}
	_ = notification_post(.Info, "persistent", persist=false)
	ui_automation_runner = {
		active = true,
		scenario = {mutation="transient"},
	}
	_ = notification_post(.Info, "automation", persist=false)
	testing.expect_value(t, len(notification_history.entries), 2)
	testing.expect(
		t,
		notification_history.entries[1].automation_transient,
	)
	notification_automation_transient_clear()
	testing.expect_value(t, len(notification_history.entries), 1)
	testing.expect_value(
		t,
		notification_history.entries[0].summary,
		"persistent",
	)
}

@(test)
ui_automation_evaluates_scalar_values :: proc(t: ^testing.T) {
	testing.expect(
		t,
		ui_automation_json_equal(
			{kind=.Boolean, boolean=true},
			json.Boolean(true),
		),
	)
	testing.expect(
		t,
		ui_automation_json_equal(
			{kind=.Number, number=12},
			json.Integer(12),
		),
	)
	testing.expect(
		t,
		ui_automation_json_equal(
			{kind=.String, string="dancing"},
			json.String("dancing"),
		),
	)
	testing.expect(
		t,
		!ui_automation_values_equal(
			{kind=.Number, number=1},
			{kind=.Number, number=2},
		),
	)
}

@(test)
ui_automation_parses_bridge_key_modifiers :: proc(t: ^testing.T) {
	modifiers, parse_error := ui_automation_key_modifiers(
		"control,shift",
	)
	testing.expect_value(t, parse_error, "")
	testing.expect(
		t,
		modifiers&NSEventModifierFlagControl != 0 &&
		modifiers&NSEventModifierFlagShift != 0,
	)
	_, parse_error = ui_automation_key_modifiers("caps-lock")
	testing.expect(t, len(parse_error) > 0)
}

@(test)
ui_automation_prunes_old_capture_bundles :: proc(t: ^testing.T) {
	root := fmt.tprintf("%s/ui-runs", app_support_dir())
	os.make_directory(root)
	for index in 0..<22 {
		os.make_directory(fmt.tprintf("%s/unit-%02d", root, index))
	}
	ui_automation_prune_bundles(20)
	handle, open_error := os.open(root)
	testing.expect(t, open_error == nil)
	if open_error != nil {return}
	defer os.close(handle)
	entries, read_error := os.read_dir(handle, -1, context.temp_allocator)
	testing.expect(t, read_error == nil)
	count := 0
	for entry in entries {
		if entry.is_dir {count += 1}
	}
	testing.expect_value(t, count, 20)
}

@(test)
ui_render_capture_writes_png_dimensions :: proc(t: ^testing.T) {
	path := fmt.tprintf("%s/unit-capture.png", app_support_dir())
	pixels := [16]u8{
		0, 0, 255, 255,
		0, 255, 0, 255,
		255, 0, 0, 255,
		255, 255, 255, 255,
	}
	testing.expect(
		t,
		ui_render_capture_write_png(path, pixels[:], 2, 2),
	)
	bytes, read_ok := os.read_entire_file(path)
	testing.expect(t, read_ok)
	if !read_ok {return}
	defer delete(bytes)
	testing.expect(t, len(bytes) >= 24)
	if len(bytes) < 24 {return}
	signature := [8]u8{137, 80, 78, 71, 13, 10, 26, 10}
	signature_matches := true
	for byte, index in signature {
		if bytes[index] != byte {signature_matches = false}
	}
	testing.expect(t, signature_matches)
	width := u32(bytes[16]) << 24 |
	         u32(bytes[17]) << 16 |
	         u32(bytes[18]) << 8 |
	         u32(bytes[19])
	height := u32(bytes[20]) << 24 |
	          u32(bytes[21]) << 16 |
	          u32(bytes[22]) << 8 |
	          u32(bytes[23])
	testing.expect_value(t, width, u32(2))
	testing.expect_value(t, height, u32(2))
}
