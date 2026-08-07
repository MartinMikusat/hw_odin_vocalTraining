package main

import "core:encoding/json"
import "core:fmt"
import os "core:os/old"
import os2 "core:os"

import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:sys/posix"
import "core:time"
import mem_virtual "core:mem/virtual"
import command_palette "command_palette:."
import text_input "components:text_input"
import framework_ui "ui_framework:core"

UI_AUTOMATION_SCHEMA_VERSION :: 1
UI_AUTOMATION_MAX_STEPS :: 512
UI_AUTOMATION_MAX_IMMEDIATE_STEPS :: 1024

UI_Automation_Viewport :: struct {
	width: int,
	height: int,
}

UI_Automation_Setup :: struct {
	workflow: string,
	mode: string,
	viewport: UI_Automation_Viewport,
}

UI_Automation_Condition :: struct {
	kind: string,
	field: string,
	operator: string,
	value: json.Value,
}

UI_Automation_Step :: struct {
	op: string,
	control: string,
	value: string,
	condition: UI_Automation_Condition,
	timeout_ms: int,
	gpu_trace: bool,
	seconds: f64,
}

UI_Automation_Scenario :: struct {
	schema_version: int,
	name: string,
	mutation: string,
	setup: UI_Automation_Setup,
	steps: []UI_Automation_Step,
}

UI_Automation_Value_Kind :: enum {
	Invalid,
	Boolean,
	Number,
	String,
}

UI_Automation_Value :: struct {
	kind: UI_Automation_Value_Kind,
	boolean: bool,
	number: f64,
	string: string,
}

UI_Automation_Action_Effect :: enum {
	Transient,
	Persistent,
	External,
}

UI_Automation_Result_Data :: struct {
	scenario: string,
	steps: int,
	elapsed_ms: int,
	immediate_ms: int,
	media_ms: int,
	wait_ms: int,
	capture_ms: int,
	frames: int,
	captures: int,
	artifact: string `json:"artifact,omitempty"`,
}

UI_Automation_Success_Response :: struct {
	ok: bool,
	command: string,
	data: UI_Automation_Result_Data,
}

UI_Automation_Pointer_Data :: struct {
	control: string,
}

UI_Automation_Pointer_Response :: struct {
	ok: bool,
	command: string,
	data: UI_Automation_Pointer_Data,
}

UI_Automation_Key_Data :: struct {
	key_code: int,
	text: string,
}

UI_Automation_Key_Response :: struct {
	ok: bool,
	command: string,
	data: UI_Automation_Key_Data,
}

UI_Automation_Failure_Response :: struct {
	ok: bool,
	command: string,
	data: UI_Automation_Result_Data,
	error: CLI_Error_Data,
}

UI_Automation_Runner :: struct {
	active: bool,
	work: ^CLI_IPC_Work,
	arena: ^mem_virtual.Arena,
	scenario: UI_Automation_Scenario,
	scenario_json: string,
	step_index: int,
	wait_started: bool,
	wait_started_ms: i64,
	wait_baseline: UI_Automation_Value,
	started_ms: i64,
	started_frame: uint,
	database_changes: int,
	media_ms: i64,
	wait_ms: i64,
	capture_ms: i64,
	capture_count: int,
	last_artifact: string,
}

ui_automation_runner: UI_Automation_Runner
ui_automation_artifact_serial: int
ui_automation_media_setup_total_ms: i64

ui_automation_enabled :: proc() -> bool {
	value := getenv("HW_VIDEO_CLIPS_AUTOMATION")
	return value != nil && string(value) == "1"
}

ui_automation_persistent_side_effects_allowed :: proc() -> bool {
	return !ui_automation_runner.active ||
	       ui_automation_runner.scenario.mutation == "persistent"
}

ui_automation_path_is_isolated :: proc(path: string) -> bool {
	if len(path) == 0 || !filepath.is_abs(path) {return false}
	relative, relative_error := filepath.rel(
		app_support_dir(),
		path,
		context.temp_allocator,
	)
	if relative_error != .None || filepath.is_abs(relative) {return false}
	return relative != ".." &&
	       !strings.has_prefix(relative, "../")
}

ui_automation_source_media_ready :: proc(index: int) -> bool {
	if index < 0 || index >= len(state.sources) {return false}
	source := &state.sources[index]
	return source.media_available &&
	       ui_automation_path_is_isolated(source.media_path) &&
	       os.exists(source.media_path)
}

ui_automation_clip_media_ready :: proc(index: int) -> bool {
	if index < 0 || index >= len(state.clips) {return false}
	clip := &state.clips[index]
	return ui_automation_path_is_isolated(clip.clip_path) &&
	       os.exists(clip.clip_path)
}

ui_automation_candidate_clips_ready :: proc(
	filtered: bool,
) -> bool {
	found := false
	for clip, index in state.clips {
		if clip.workflow != ui.workflow {continue}
		if filtered && !clip_matches_filter(clip, ui.clip_search) {continue}
		found = true
		if !ui_automation_clip_media_ready(index) {return false}
	}
	return found
}

ui_automation_action_effect :: proc(
	action: UI_Action,
) -> UI_Automation_Action_Effect {
	kind := action.kind
	if kind == .Source {
		if ui_automation_source_media_ready(action.index) {
			return .Transient
		}
		return .External
	}
	if kind == .Clip {
		if ui_automation_clip_media_ready(action.index) {
			return .Transient
		}
		return .External
	}
	if kind == .View_Clip_Source {
		source_index := source_index_for_clip(
			state.sources[:],
			state.clips[:],
			ui.clip_metadata_index,
		)
		if ui_automation_source_media_ready(source_index) {
			return .Persistent
		}
		return .External
	}
	if kind == .Randomize {
		if ui_automation_candidate_clips_ready(false) {
			return .Persistent
		}
		return .External
	}
	if kind == .Play_Next {
		if ui_automation_candidate_clips_ready(true) {
			return .Persistent
		}
		return .External
	}
	#partial switch kind {
	case .Command_Palette_Search, .Command_Palette_Result,
	     .Command_Palette_Disabled, .Open_Settings, .Settings_Close,
	     .Settings_Category, .Settings_Search, .Configure_Flash,
	     .Shortcut_Record, .Shortcut_Cancel, .Open_Source_Modal,
	     .Cancel_Source_Modal, .Close_Source_Details,
	     .Open_Source_Details, .URL, .Source_Quality,
	     .Toggle_Save_Source_Browser, .Open_Notification_History,
	     .Close_Notification_History, .Select_Notification,
	     .Source_Search, .Transcript_Search, .Transcript,
	     .Clip_Search, .Open_Randomize_Help,
		     .Close_Randomize_Help,
		     .Pitch_Chart, .Open_Pitch_Help, .Close_Pitch_Help,
		     .Dance_BPM_Status, .Dance_Grid_Status,
	     .Clip_Name, .Cancel_Clip_Rename, .Clip_Rename,
	     .Close_Clip_Metadata, .Rename, .Metadata,
	     .Volume_Down, .Volume_Up, .Source_Play_Pause,
	     .Player_Surface, .Source_Stop, .Source_Timeline,
	     .Source_Reset, .Source_Hint_Menu,
	     .Playback_Fullscreen_Toggle, .Play, .Pause,
	     .Data, .Close_Data_Modal, .Shuffle_Toggle, .Autoplay_Toggle:
		return .Transient
	case .Set_Theme, .Shortcut_Save, .Shortcut_Reset,
	     .Workflow_Toggle, .Mode_Toggle,
	     .Metronome_Volume_Down, .Metronome_Volume_Up,
	     .Dance_Mirror_Toggle,
		     .Dance_Loop_Toggle, .Dance_Count_In,
		     .Dance_Count_Each_Loop_Toggle, .Dance_BPM_Down,
		     .Dance_BPM_Up, .Dance_BPM_Use_Auto,
		     .Dance_Grid_Earlier, .Dance_Grid_Later,
		     .Dance_Grid_Set_One, .Dance_Grid_Reset_Auto,
		     .Dance_Metronome_Toggle,
		     .Pitch_Reference_Down, .Pitch_Reference_Up,
	     .Pitch_Octaves_Down, .Pitch_Octaves_Up, .Pitch_Labels, .Pitch_Transpose,
	     .Pitch_Highlight, .Speed_Down, .Speed_Up, .Source_Hint,
	     .Waveform_All, .Waveform_Low, .Waveform_Mid, .Waveform_High,
	     .Start, .End, .Captions, .Confirm_Clip_Rename:
		return .Persistent
	case .Window_Close, .Window_Minimize, .Window_Zoom, .Import,
	     .Refetch_Source_Details, .Retry_Source_With_Browser,
	     .Stop_Download, .View_Status_Source,
	     .Activate_Notification_Action, .Open_Data_Folder,
		     .Export_Library, .Export_Current_Workflow, .Import_Library,
		     .Pitch_Toggle, .Preview, .Save, .Dance_BPM_Analyze_Again,
	     .Cancel_Library_Import, .Confirm_Library_Import,
	     .Recovery_Backup_Only, .Recovery_Backup_With_Salvage,
	     .Recovery_Salvage_Only, .Recovery_Cancel,
	     .Recovery_Confirm, .Backup_Warning_Cancel,
	     .Backup_Warning_Continue:
		return .External
	}
	return .External
}

ui_automation_media_setup_begin :: proc() -> i64 {
	if !ui_automation_runner.active {return -1}
	return numbered_action_time_ms()
}

ui_automation_media_setup_finish :: proc(started_ms: i64) {
	if started_ms < 0 {return}
	ui_automation_media_setup_total_ms +=
		max(i64(0), numbered_action_time_ms()-started_ms)
}

ui_automation_set_value_effect :: proc(
	kind: UI_Action_Kind,
) -> UI_Automation_Action_Effect {
	#partial switch kind {
	case .URL:
		return .External
	case .Clip_Name:
		return .Persistent
	case .Command_Palette_Search, .Settings_Search, .Source_Search,
	     .Transcript_Search, .Clip_Search, .Clip_Rename:
		return .Transient
	}
	return .External
}

ui_automation_find_control :: proc(
	functional_name: string,
) -> (UI_Control, bool) {
	arena, arena_ok := growing_arena_create(256*1024, 64*1024)
	if !arena_ok {return {}, false}
	defer growing_arena_destroy(arena)
	previous_build := ui_build
	previous_registry := shared_registry
	defer {
		ui_build = previous_build
		shared_registry = previous_registry
	}
	build_ui_controls(false, mem_virtual.arena_allocator(arena))
	shared_control := framework_ui.control_by_name_in_view(
		shared_registry,
		functional_name,
	)
	if shared_control == nil || .CLI not_in shared_control.capabilities {
		return {}, false
	}
	control := find_ui_control(UI_Control_ID(shared_control.id))
	if control == nil {return {}, false}
	return control^, true
}

ui_automation_surface_value :: proc(field: string) -> UI_Automation_Value {
	switch field {
	case "workflow":
		return {kind=.String, string=cli_workflow_name(ui.workflow)}
	case "mode":
		return {kind=.String, string=ui.mode == .Play ? "play" : "create"}
	case "overlay":
		surface := ui_diagnostic_surface(context.temp_allocator)
		return {kind=.String, string=surface.overlay}
	case "background":
		surface := ui_diagnostic_surface(context.temp_allocator)
		return {kind=.String, string=surface.background}
	case "window.visible":
		return {
			kind = .Boolean,
			boolean = ui_window_is_visible(),
		}
	case "application.active":
		return {
			kind = .Boolean,
			boolean = ui_application_is_active(),
		}
	case "media.loaded":
		return {kind=.Boolean, boolean=state.player != nil}
	case "video.frame_ready":
		return {kind=.Boolean, boolean=ui.last_video_texture != nil}
	case "selection.id":
		if ui.mode == .Create &&
		   state.active_source >= 0 &&
		   state.active_source < len(state.sources) {
			return {kind=.String, string=state.sources[state.active_source].id}
		}
		if ui.mode == .Play &&
		   ui.active_clip >= 0 &&
		   ui.active_clip < len(state.clips) {
			return {kind=.String, string=state.clips[ui.active_clip].id}
		}
		return {kind=.String, string=""}
	case "selection.source.saved":
		return {
			kind = .String,
			string = ui.source_selection_ids[int(ui.workflow)],
		}
	case "selection.clip.saved":
		return {
			kind = .String,
			string = ui.clip_selection_ids[int(ui.workflow)],
		}
	case "playback.active":
		return {kind=.Boolean, boolean=playback_actively_playing()}
	case "playback.seconds":
		seconds, _ := current_seconds()
		return {kind=.Number, number=seconds}
	case "playback.duration":
		return {kind=.Number, number=ui.player_duration}
	case "playback.fullscreen":
		return {kind=.Boolean, boolean=ui.playback_fullscreen_active}
	case "playback.transport_visible":
		return {
			kind = .Boolean,
			boolean = ui.playback_fullscreen_controls_visible,
		}
	case "playback.timeline_progress":
		seconds, _ := current_seconds()
		progress := 0.0
		if ui.player_duration > 0 {
			progress = playback_timeline_progress(seconds, ui.player_duration)
		}
		return {kind=.Number, number=progress}
	case "viewport.width":
		return {kind=.Number, number=ui.width}
	case "viewport.height":
		return {kind=.Number, number=ui.height}
	case "dance.mirrored":
		return {kind=.Boolean, boolean=active_dance_clip_mirrored()}
	case "render.count":
		return {kind=.Number, number=f64(ui.render_count)}
	case "overlay.revision":
		return {kind=.Number, number=f64(ui.overlay_revision)}
	}
	return {}
}

ui_automation_control_value :: proc(
	condition: UI_Automation_Condition,
) -> UI_Automation_Value {
	control, found := ui_automation_find_control(condition.field)
	switch condition.operator {
	case "present", "absent":
		return {kind=.Boolean, boolean=found}
	case "enabled", "disabled":
		return {
			kind = .Boolean,
			boolean = found && .Enabled in control.flags,
		}
	}
	return {}
}

ui_automation_condition_value :: proc(
	condition: UI_Automation_Condition,
) -> UI_Automation_Value {
	if condition.kind == "control" {
		return ui_automation_control_value(condition)
	}
	return ui_automation_surface_value(condition.field)
}

ui_automation_json_equal :: proc(
	actual: UI_Automation_Value,
	expected: json.Value,
) -> bool {
	#partial switch value in expected {
	case json.Boolean:
		return actual.kind == .Boolean && actual.boolean == bool(value)
	case json.Integer:
		return actual.kind == .Number && actual.number == f64(value)
	case json.Float:
		return actual.kind == .Number && actual.number == f64(value)
	case json.String:
		return actual.kind == .String && actual.string == string(value)
	}
	return false
}

ui_automation_json_number :: proc(value: json.Value) -> (f64, bool) {
	#partial switch number in value {
	case json.Integer: return f64(number), true
	case json.Float: return f64(number), true
	}
	return 0, false
}

ui_automation_values_equal :: proc(
	left, right: UI_Automation_Value,
) -> bool {
	if left.kind != right.kind {return false}
	switch left.kind {
	case .Boolean: return left.boolean == right.boolean
	case .Number: return left.number == right.number
	case .String: return left.string == right.string
	case .Invalid: return false
	}
	return false
}

ui_automation_condition_matches :: proc(
	condition: UI_Automation_Condition,
	baseline: UI_Automation_Value,
) -> (bool, string) {
	actual := ui_automation_condition_value(condition)
	if actual.kind == .Invalid {
		return false, fmt.tprintf(
			"Unknown UI condition: %s/%s",
			condition.kind,
			condition.field,
		)
	}
	switch condition.operator {
	case "eq":
		return ui_automation_json_equal(actual, condition.value), ""
	case "ne":
		return !ui_automation_json_equal(actual, condition.value), ""
	case "gte", "lte":
		expected, ok := ui_automation_json_number(condition.value)
		if !ok || actual.kind != .Number {
			return false, "The comparison requires a numeric field and value"
		}
		if condition.operator == "gte" {return actual.number >= expected, ""}
		return actual.number <= expected, ""
	case "changed":
		return !ui_automation_values_equal(actual, baseline), ""
	case "increase_by":
		increase, ok := ui_automation_json_number(condition.value)
		if !ok || actual.kind != .Number || baseline.kind != .Number {
			return false, "increase_by requires a numeric field and value"
		}
		return actual.number >= baseline.number+increase, ""
	case "present":
		return actual.kind == .Boolean && actual.boolean, ""
	case "absent":
		return actual.kind == .Boolean && !actual.boolean, ""
	case "enabled":
		return actual.kind == .Boolean && actual.boolean, ""
	case "disabled":
		return actual.kind == .Boolean && !actual.boolean, ""
	}
	return false, fmt.tprintf(
		"Unknown UI condition operator: %s",
		condition.operator,
	)
}

ui_automation_validate :: proc(
	scenario: ^UI_Automation_Scenario,
) -> string {
	if scenario.schema_version != UI_AUTOMATION_SCHEMA_VERSION {
		return fmt.tprintf(
			"Expected UI scenario schema version %d",
			UI_AUTOMATION_SCHEMA_VERSION,
		)
	}
	if len(strings.trim_space(scenario.name)) == 0 {
		return "The UI scenario requires a name"
	}
	if len(scenario.name) > 80 {
		return "The UI scenario name exceeds 80 bytes"
	}
	for byte in scenario.name {
		if (byte < 'a' || byte > 'z') &&
		   (byte < 'A' || byte > 'Z') &&
		   (byte < '0' || byte > '9') &&
		   byte != '-' && byte != '_' {
			return "The UI scenario name can contain only letters, digits, hyphens, and underscores"
		}
	}
	if scenario.mutation != "" &&
	   scenario.mutation != "transient" &&
	   scenario.mutation != "persistent" {
		return "scenario.mutation must be transient or persistent"
	}
	if scenario.setup.viewport.width != 1280 ||
	   scenario.setup.viewport.height != 800 {
		return "setup.viewport must be 1280 by 800"
	}
	if len(scenario.steps) == 0 {
		return "The UI scenario requires at least one step"
	}
	if len(scenario.steps) > UI_AUTOMATION_MAX_STEPS {
		return fmt.tprintf(
			"The UI scenario exceeds the %d-step limit",
			UI_AUTOMATION_MAX_STEPS,
		)
	}
	for step, index in scenario.steps {
		switch step.op {
		case "activate", "set_value":
			if len(strings.trim_space(step.control)) == 0 {
				return fmt.tprintf(
					"Step %d requires an exact control name",
					index+1,
				)
			}
		case "assert":
			if len(step.condition.field) == 0 ||
			   len(step.condition.operator) == 0 {
				return fmt.tprintf(
					"Step %d requires a complete condition",
					index+1,
				)
			}
		case "wait":
			if len(step.condition.field) == 0 ||
			   len(step.condition.operator) == 0 ||
			   step.timeout_ms <= 0 {
				return fmt.tprintf(
					"Step %d requires a condition and positive timeout_ms",
					index+1,
				)
			}
		case "hold":
			if step.timeout_ms <= 0 {
				return fmt.tprintf("Step %d requires a positive timeout_ms", index+1)
			}
		case "scrub":
			if step.seconds < 0 {
				return fmt.tprintf("Step %d requires non-negative seconds", index+1)
			}
		case "capture", "performance_capture":
		case:
			return fmt.tprintf(
				"Step %d has an unknown operation: %s",
				index+1,
				step.op,
			)
		}
	}
	return ""
}

ui_automation_seed_fixture :: proc() -> bool {
	if !ui_automation_enabled() {return true}
	path_value := getenv("HW_VIDEO_CLIPS_AUTOMATION_MEDIA")
	if path_value == nil || len(string(path_value)) == 0 {return true}
	media_path := string(path_value)
	if !os.exists(media_path) {return false}
	fixture_directory := filepath.dir(media_path)
	source_media_path := fmt.tprintf("%s/ui-test-source.mp4", fixture_directory)
	clip_media_path := fmt.tprintf("%s/ui-test-clip.mp4", fixture_directory)
	vocal_source_media_path := fmt.tprintf(
		"%s/ui-test-vocal-source.mp4",
		fixture_directory,
	)
	vocal_clip_media_path := fmt.tprintf(
		"%s/ui-test-vocal-clip.mp4",
		fixture_directory,
	)
	if !os.exists(source_media_path) &&
	   os2.copy_file(source_media_path, media_path) != nil {
		return false
	}
	if !os.exists(clip_media_path) &&
	   os2.copy_file(clip_media_path, media_path) != nil {
		return false
	}
	if !os.exists(vocal_source_media_path) &&
	   os2.copy_file(vocal_source_media_path, media_path) != nil {
		return false
	}
	if !os.exists(vocal_clip_media_path) &&
	   os2.copy_file(vocal_clip_media_path, media_path) != nil {
		return false
	}
	source_id := "ui-test-source"
	clip_id := "ui-test-clip"
	vocal_source_id := "ui-test-vocal-source"
	vocal_clip_id := "ui-test-vocal-clip"
	source_exists := source_index_for_id(state.sources[:], source_id) >= 0
	clip_exists := clip_index_for_id(state.clips[:], clip_id) >= 0
	vocal_source_exists :=
		source_index_for_id(state.sources[:], vocal_source_id) >= 0
	vocal_clip_exists := clip_index_for_id(state.clips[:], vocal_clip_id) >= 0
	if source_exists && clip_exists &&
	   vocal_source_exists && vocal_clip_exists {
		return true
	}
	if !source_exists {
		source, copied := clone_source_video(Source_Video{
			id = source_id,
			workflow = .Dancing,
			video_id = "ui-test-video",
			title = "UI Test Source",
			url = "https://www.youtube.com/watch?v=ui-test-video",
			media_path = source_media_path,
			duration = 1,
			metadata = {
				width = 320,
				height = 180,
				fps = 30,
				vcodec = "h264",
				acodec = "aac",
				ext = "mp4",
				format_id = "ui-test",
			},
			metadata_status = .Available,
			media_available = true,
		})
		if !copied {return false}
		append(&state.sources, source)
	}
	if !clip_exists {
		clip, copied := clone_clip(Clip{
			id = clip_id,
			source_id = source_id,
			workflow = .Dancing,
			name = "UI Test Clip",
			start_seconds = 0,
			end_seconds = 1,
			clip_path = clip_media_path,
			dance_count_in_bpm = 120,
			dance_playback_rate = 1,
		})
		if !copied {return false}
		append(&state.clips, clip)
	}
	if !vocal_source_exists {
		source, copied := clone_source_video(Source_Video{
			id = vocal_source_id,
			workflow = .Vocal,
			video_id = "ui-test-vocal-video",
			title = "UI Test Vocal Source",
			url = "https://www.youtube.com/watch?v=ui-test-vocal-video",
			media_path = vocal_source_media_path,
			duration = 1,
			metadata = {
				width = 320,
				height = 180,
				fps = 30,
				vcodec = "h264",
				acodec = "aac",
				ext = "mp4",
				format_id = "ui-test",
			},
			metadata_status = .Available,
			media_available = true,
		})
		if !copied {return false}
		append(&state.sources, source)
	}
	if !vocal_clip_exists {
		clip, copied := clone_clip(Clip{
			id = vocal_clip_id,
			source_id = vocal_source_id,
			workflow = .Vocal,
			name = "UI Test Vocal Clip",
			start_seconds = 0,
			end_seconds = 1,
			clip_path = vocal_clip_media_path,
		})
		if !copied {return false}
		append(&state.clips, clip)
	}
	return save_library_state(&state)
}

ui_automation_reset_transient :: proc(
	setup: UI_Automation_Setup,
) -> string {
	if global_modal_blocks_commands() {
		return "A library recovery or replacement decision is active"
	}
	if import_jobs_any() || export_jobs_any() ||
	   source_probe_job != nil || source_metadata_job != nil {
		return "A media task is active in the isolated UI test instance"
	}
	if ui.clip_draft_dirty {
		return "The isolated UI test instance has a dirty clip draft"
	}
	notification_automation_transient_clear()
	cancel_ui_flash()
	clear_number_prefix()
	if command_palette.is_open(&command_palette_state) {
		close_command_palette(false)
	}
	if ui.shortcut_open {video_clips_shortcut_recorder_close()}
	if ui.settings_open {video_clips_settings_close()}
	if ui.source_modal_open {close_source_modal()}
	if ui.source_details_open {close_source_details()}
	if ui.clip_rename_open {close_clip_rename()}
	if ui.clip_metadata_open {close_clip_metadata()}
	if ui.randomize_help_open {close_randomize_help()}
	if ui.pitch.help_open {close_pitch_help()}
	if ui.data_modal_open {close_data_modal()}
	if ui.notification_modal_open {close_notification_history()}
	if ui.playback_fullscreen_active {set_playback_fullscreen(false)}
	pitch_monitor_stop(&ui.pitch)
	metal_player_clear()
	ui.active_clip = -1
	state.active_source = -1
	ui_set_string(&ui.url_input, "")
	ui_set_string(&ui.source_search, "")
	ui_set_string(&ui.transcript_search, "")
	ui_set_string(&ui.clip_search, "")
	ui_set_string(&ui.clip_name, "")
	ui_set_string(&ui.clip_rename, "")
	state.range_start = 0
	state.range_end = 0
	state.has_start = false
	state.has_end = false
	ui.focus = .None
	text_input.end_pointer_selection(&ui.input_state)
	clear_marked_text()
	ui.source_scroll = 0
	ui.transcript_scroll = 0
	ui.clip_scroll = 0
	ui.clip_shuffle = false
	ui.clip_autoplay = false
	ui.player_volume = 1
	ui.metronome_volume = 1
	ui.source_hint_menu_open = false
	invalidate_transcript_matches()
	workflow := ui.workflow
	switch setup.workflow {
	case "", "vocal": workflow = .Vocal
	case "dancing": workflow = .Dancing
	case: return "setup.workflow must be vocal or dancing"
	}
	mode := ui.mode
	switch setup.mode {
	case "", "create": mode = .Create
	case "play": mode = .Play
	case: return "setup.mode must be create or play"
	}
	set_ui_workflow(workflow, false)
	set_ui_mode(mode, false)
	if ui.mode == .Create {restore_source_selection()} else {restore_clip_selection()}
	if state.window == nil || ui.view == nil {
		return "The isolated UI test window is unavailable"
	}
	window_frame := msg_rect(state.window, sel_registerName("frame"))
	window_frame.size = {
		f64(setup.viewport.width),
		f64(setup.viewport.height),
	}
	msg_void_rect_b(
		state.window,
		sel_registerName("setFrame:display:"),
		window_frame,
		true,
	)
	bounds := msg_rect(ui.view, sel_registerName("bounds"))
	ui.width = bounds.size.width
	ui.height = bounds.size.height
	if !ui_automation_viewport_matches(
		setup.viewport,
		ui.width,
		ui.height,
	   ) {
		return "The isolated UI test viewport could not be applied"
	}
	ui.needs_redraw = true
	return ""
}

ui_automation_viewport_matches :: proc(
	viewport: UI_Automation_Viewport,
	width, height: f64,
) -> bool {
	return width == f64(viewport.width) &&
	       height == f64(viewport.height)
}

ui_automation_result_data :: proc(
	runner: ^UI_Automation_Runner,
) -> UI_Automation_Result_Data {
	elapsed_ms := int(numbered_action_time_ms()-runner.started_ms)
	media_ms := int(runner.media_ms)
	wait_ms := int(runner.wait_ms)
	capture_ms := int(runner.capture_ms)
	return {
		scenario = runner.scenario.name,
		steps = runner.step_index,
		elapsed_ms = elapsed_ms,
		immediate_ms =
			max(0, elapsed_ms-media_ms-wait_ms-capture_ms),
		media_ms = media_ms,
		wait_ms = wait_ms,
		capture_ms = capture_ms,
		frames = int(ui.frame_tick-runner.started_frame),
		captures = runner.capture_count,
		artifact = runner.last_artifact,
	}
}

ui_automation_bundle_path :: proc(
	name: string,
	allocator := context.allocator,
) -> string {
	ui_automation_artifact_serial += 1
	return fmt.aprintf(
		"%s/ui-runs/%s-%d-%d",
		app_support_dir(),
		name,
		int(posix.getpid()),
		ui_automation_artifact_serial,
		allocator=allocator,
	)
}

ui_automation_prune_bundles :: proc(keep := 20) {
	root := fmt.tprintf("%s/ui-runs", app_support_dir())
	handle, open_error := os.open(root)
	if open_error != nil {return}
	entries, read_error := os.read_dir(handle, -1, context.temp_allocator)
	os.close(handle)
	if read_error != nil {return}
	directories := make(
		[dynamic]UI_Diagnostic_Artifact_File,
		0,
		len(entries),
		context.temp_allocator,
	)
	for entry in entries {
		if !entry.is_dir {continue}
		append(&directories, UI_Diagnostic_Artifact_File{
			path = entry.fullpath,
			name = entry.name,
			modified_nano =
				time.time_to_unix_nano(entry.modification_time),
		})
	}
	if len(directories) <= keep {return}
	slice.sort_by(
		directories[:],
		proc(a, b: UI_Diagnostic_Artifact_File) -> bool {
			if a.modified_nano == b.modified_nano {
				return a.name < b.name
			}
			return a.modified_nano < b.modified_nano
		},
	)
	for index in 0..<len(directories)-max(0, keep) {
		_ = os2.remove_all(directories[index].path)
	}
}

ui_automation_write_failure_bundle :: proc(
	runner: ^UI_Automation_Runner,
) -> (string, i64) {
	path := ui_automation_bundle_path(runner.scenario.name)
	os.make_directory(app_support_dir())
	os.make_directory(filepath.dir(path))
	os.make_directory(path)
	_ = os.write_entire_file(
		fmt.tprintf("%s/scenario.json", path),
		transmute([]u8)runner.scenario_json,
	)
	if snapshot, captured := ui_diagnostic_capture_current(
		context.temp_allocator,
	); captured {
		_ = ui_diagnostic_write_artifact(
			fmt.tprintf("%s/ui-snapshot.json", path),
			snapshot,
		)
	}
	capture_started_ms := numbered_action_time_ms()
	_ = ui_render_capture_into(path, true, false)
	capture_ms := numbered_action_time_ms()-capture_started_ms
	ui_automation_prune_bundles()
	return strings.clone(path), capture_ms
}

ui_automation_destroy_runner :: proc() {
	arena := ui_automation_runner.arena
	ui_automation_runner = {}
	growing_arena_destroy(arena)
}

ui_automation_finish_success :: proc() {
	runner := &ui_automation_runner
	data := ui_automation_result_data(runner)
	response := UI_Automation_Success_Response{
		ok = true,
		command = cli_command_name(.UI_Run),
		data = data,
	}
	work := runner.work
	result := CLI_Result{
		output = cli_encode(response),
		exit_code = .Success,
	}
	notification_automation_transient_clear()
	ui_automation_destroy_runner()
	cli_ipc_work_finish(work, result)
}

ui_automation_finish_failure :: proc(code, message: string) {
	runner := &ui_automation_runner
	data := ui_automation_result_data(runner)
	response := UI_Automation_Failure_Response{
		ok = false,
		command = cli_command_name(.UI_Run),
		data = data,
		error = {code=code, message=message},
	}
	artifact, capture_ms := ui_automation_write_failure_bundle(runner)
	runner.capture_ms += capture_ms
	runner.last_artifact = artifact
	response.data = ui_automation_result_data(runner)
	response.data.artifact = artifact
	_ = ui_diagnostic_write_artifact(
		fmt.tprintf("%s/result.json", artifact),
		response,
	)
	work := runner.work
	result := CLI_Result{
		output = cli_encode(response),
		exit_code = .Check,
	}
	delete(artifact)
	notification_automation_transient_clear()
	ui_automation_destroy_runner()
	cli_ipc_work_finish(work, result)
}

ui_automation_capture :: proc(gpu_trace: bool) -> (string, string) {
	return ui_render_capture_bundle(gpu_trace)
}

ui_automation_advance :: proc() {
	if !ui_automation_runner.active {return}
	if ui.width <= 0 || ui.height <= 0 {return}
	runner := &ui_automation_runner
	if !ui_automation_viewport_matches(
		runner.scenario.setup.viewport,
		ui.width,
		ui.height,
	   ) {
		ui_automation_finish_failure(
			"viewport_mismatch",
			"The running view does not match the scenario viewport",
		)
		return
	}
	immediate_steps := 0
	for runner.step_index < len(runner.scenario.steps) {
		immediate_steps += 1
		if immediate_steps > UI_AUTOMATION_MAX_IMMEDIATE_STEPS {
			ui_automation_finish_failure(
				"scenario_step_limit",
				"The UI runner exceeded its immediate-step limit",
			)
			return
		}
		step := &runner.scenario.steps[runner.step_index]
		switch step.op {
		case "activate":
			control, found := ui_automation_find_control(step.control)
			if !found {
				ui_automation_finish_failure(
					"control_not_found",
					fmt.tprintf(
						"Step %d did not find control %s",
						runner.step_index+1,
						step.control,
					),
				)
				return
			}
			if .Enabled not_in control.flags {
				ui_automation_finish_failure(
					"control_disabled",
					fmt.tprintf(
						"Step %d found disabled control %s",
						runner.step_index+1,
						step.control,
					),
				)
				return
			}
			effect := ui_automation_action_effect(control.action)
			if effect == .External ||
			   (effect == .Persistent &&
			    runner.scenario.mutation != "persistent") {
				ui_automation_finish_failure(
					"mutation_not_transient",
					fmt.tprintf(
						"Step %d routes to a %v action",
						runner.step_index+1,
						effect,
					),
				)
				return
			}
			media_before_ms := ui_automation_media_setup_total_ms
			activated := activate_ui_action(control.action)
			runner.media_ms +=
				ui_automation_media_setup_total_ms-media_before_ms
			if !activated {
				ui_automation_finish_failure(
					"activation_failed",
					fmt.tprintf(
						"Step %d could not activate control %s",
						runner.step_index+1,
						step.control,
					),
				)
				return
			}
			runner.step_index += 1
		case "set_value":
			control, found := ui_automation_find_control(step.control)
			if !found || .Editable not_in control.flags {
				ui_automation_finish_failure(
					"control_not_editable",
					fmt.tprintf(
						"Step %d did not find editable control %s",
						runner.step_index+1,
						step.control,
					),
				)
				return
			}
			effect := ui_automation_set_value_effect(control.action.kind)
			if effect == .External ||
			   (effect == .Persistent &&
			    runner.scenario.mutation != "persistent") {
				ui_automation_finish_failure(
					"mutation_not_transient",
					fmt.tprintf(
						"Step %d routes to a %v value change",
						runner.step_index+1,
						effect,
					),
				)
				return
			}
			if !set_ui_control_value(control.action, step.value) {
				ui_automation_finish_failure(
					"value_rejected",
					fmt.tprintf(
						"Step %d could not set control %s",
						runner.step_index+1,
						step.control,
					),
				)
				return
			}
			runner.step_index += 1
		case "assert":
			actual := ui_automation_condition_value(step.condition)
			matches, condition_error := ui_automation_condition_matches(
				step.condition,
				actual,
			)
			if len(condition_error) > 0 {
				ui_automation_finish_failure(
					"condition_invalid",
					condition_error,
				)
				return
			}
			if !matches {
				ui_automation_finish_failure(
					"assertion_failed",
					fmt.tprintf(
						"Step %d assertion failed: %s %s",
						runner.step_index+1,
						step.condition.field,
						step.condition.operator,
					),
				)
				return
			}
			runner.step_index += 1
		case "wait":
			if !runner.wait_started {
				runner.wait_started = true
				runner.wait_started_ms = numbered_action_time_ms()
				runner.wait_baseline =
					ui_automation_condition_value(step.condition)
			}
			matches, condition_error := ui_automation_condition_matches(
				step.condition,
				runner.wait_baseline,
			)
			if len(condition_error) > 0 {
				ui_automation_finish_failure(
					"condition_invalid",
					condition_error,
				)
				return
			}
			if matches {
				runner.wait_ms +=
					numbered_action_time_ms()-runner.wait_started_ms
				runner.wait_started = false
				runner.step_index += 1
				continue
			}
			if numbered_action_time_ms()-runner.wait_started_ms >=
			   i64(step.timeout_ms) {
				runner.wait_ms +=
					numbered_action_time_ms()-runner.wait_started_ms
				ui_automation_finish_failure(
					"wait_timeout",
					fmt.tprintf(
						"Step %d timed out after %d ms: %s %s",
						runner.step_index+1,
						step.timeout_ms,
						step.condition.field,
						step.condition.operator,
					),
				)
			}
			return
		case "hold":
			if !runner.wait_started {
				runner.wait_started = true
				runner.wait_started_ms = numbered_action_time_ms()
			}
			if numbered_action_time_ms()-runner.wait_started_ms < i64(step.timeout_ms) {
				return
			}
			runner.wait_ms += numbered_action_time_ms()-runner.wait_started_ms
			runner.wait_started = false
			runner.step_index += 1
		case "scrub":
			if state.player == nil || step.seconds > ui.player_duration {
				ui_automation_finish_failure(
					"scrub_unavailable",
					fmt.tprintf("Step %d cannot seek to %.3f seconds", runner.step_index+1, step.seconds),
				)
				return
			}
			seek_seconds(step.seconds)
			ui.needs_redraw = true
			runner.step_index += 1
		case "capture":
			capture_started_ms := numbered_action_time_ms()
			artifact, capture_error :=
				ui_automation_capture(step.gpu_trace)
			runner.capture_ms +=
				numbered_action_time_ms()-capture_started_ms
			if len(capture_error) > 0 {
				delete(artifact)
				ui_automation_finish_failure(
					"capture_failed",
					capture_error,
				)
				return
			}
			delete(runner.last_artifact)
			runner.last_artifact = strings.clone(
				artifact,
				mem_virtual.arena_allocator(runner.arena),
			)
			delete(artifact)
			runner.capture_count += 1
			runner.step_index += 1
		case "performance_capture":
			when ODIN_DEBUG {
				capture_started_ms := numbered_action_time_ms()
				artifact, captured := perf_save_recent()
				runner.capture_ms += numbered_action_time_ms()-capture_started_ms
				if !captured {
					ui_automation_finish_failure(
						"performance_capture_failed",
						"The recent performance history could not be written",
					)
					return
				}
				delete(runner.last_artifact)
				runner.last_artifact = strings.clone(
					artifact,
					mem_virtual.arena_allocator(runner.arena),
				)
				delete(artifact)
				runner.capture_count += 1
				runner.step_index += 1
			} else {
				ui_automation_finish_failure(
					"performance_capture_unavailable",
					"Performance capture requires a debug build",
				)
				return
			}
		}
	}
	if runner.scenario.mutation != "persistent" &&
	   library_database != nil &&
	   int(sqlite3_total_changes(library_database)) !=
	   runner.database_changes {
		ui_automation_finish_failure(
			"persistent_mutation_detected",
			"The transient scenario changed the library database",
		)
		return
	}
	ui_automation_finish_success()
}

ui_automation_start :: proc(
	request: CLI_Request,
	work: ^CLI_IPC_Work,
) -> bool {
	if !ui_automation_enabled() {
		cli_ipc_work_finish(
			work,
			cli_error(
				request.command,
				.Busy,
				"automation_instance_required",
				"Run UI scenarios through scripts/ui-test.sh",
			),
		)
		return true
	}
	if ui_automation_runner.active {
		cli_ipc_work_finish(
			work,
			cli_error(
				request.command,
				.Busy,
				"scenario_active",
				"A UI scenario is already active",
			),
		)
		return true
	}
	arena, arena_ok := growing_arena_create(512*1024, 64*1024)
	if !arena_ok {
		cli_ipc_work_finish(
			work,
			cli_error(
				request.command,
				.Storage,
				"allocation_failed",
				"Unable to allocate the UI scenario",
			),
		)
		return true
	}
	allocator := mem_virtual.arena_allocator(arena)
	scenario: UI_Automation_Scenario
	if decode_error := json.unmarshal(
		transmute([]u8)request.scenario_json,
		&scenario,
		.JSON,
		allocator,
	); decode_error != nil {
		growing_arena_destroy(arena)
		cli_ipc_work_finish(
			work,
			cli_error(
				request.command,
				.Invalid,
				"scenario_invalid_json",
				"The UI scenario is not valid JSON",
			),
		)
		return true
	}
	if validation_error := ui_automation_validate(&scenario);
	   len(validation_error) > 0 {
		growing_arena_destroy(arena)
		cli_ipc_work_finish(
			work,
			cli_error(
				request.command,
				.Invalid,
				"scenario_invalid",
				validation_error,
			),
		)
		return true
	}
	if setup_error := ui_automation_reset_transient(scenario.setup);
	   len(setup_error) > 0 {
		growing_arena_destroy(arena)
		cli_ipc_work_finish(
			work,
			cli_error(
				request.command,
				.Busy,
				"scenario_setup_failed",
				setup_error,
			),
		)
		return true
	}
	ui_automation_runner = {
		active = true,
		work = work,
		arena = arena,
		scenario = scenario,
		scenario_json = strings.clone(request.scenario_json, allocator),
		started_ms = numbered_action_time_ms(),
		started_frame = ui.frame_tick,
	}
	if library_database != nil {
		ui_automation_runner.database_changes =
			int(sqlite3_total_changes(library_database))
	}
	ui_automation_advance()
	return true
}

cli_ui_capture :: proc(request: CLI_Request) -> CLI_Result {
	if !ui_automation_enabled() {
		return cli_error(
			request.command,
			.Busy,
			"automation_instance_required",
			"Run UI captures through scripts/ui-test.sh",
		)
	}
	started_ms := numbered_action_time_ms()
	artifact, capture_error := ui_automation_capture(request.gpu_trace)
	defer delete(artifact)
	capture_ms := int(numbered_action_time_ms()-started_ms)
	if len(capture_error) > 0 {
		response := UI_Automation_Failure_Response{
			ok = false,
			command = cli_command_name(request.command),
			data = {
				scenario = "capture",
				elapsed_ms = capture_ms,
				capture_ms = capture_ms,
				captures = 1,
				artifact = artifact,
			},
			error = {
				code = "capture_failed",
				message = capture_error,
			},
		}
		return {
			output = cli_encode(response),
			exit_code = .Media,
		}
	}
	response := UI_Automation_Success_Response{
		ok = true,
		command = cli_command_name(request.command),
		data = {
			scenario = "capture",
			elapsed_ms = capture_ms,
			capture_ms = capture_ms,
			captures = 1,
			artifact = artifact,
		},
	}
	return {
		output = cli_encode(response),
		exit_code = .Success,
	}
}

ui_automation_post_pointer_click :: proc(
	functional_name: string,
) -> string {
	arena, arena_ok := growing_arena_create(256*1024, 64*1024)
	if !arena_ok {return "The pointer registry could not allocate memory"}
	defer growing_arena_destroy(arena)
	previous_build := ui_build
	previous_registry := shared_registry
	defer {
		ui_build = previous_build
		shared_registry = previous_registry
	}
	build_ui_controls(true, mem_virtual.arena_allocator(arena))
	shared_control := framework_ui.control_by_name_in_view(
		shared_registry,
		functional_name,
	)
	if shared_control == nil {return "The pointer target does not exist"}
	if !shared_control.enabled ||
	   .Primary_Press not_in shared_control.capabilities {
		return "The pointer target is not enabled for primary input"
	}
	control := find_ui_control(UI_Control_ID(shared_control.id))
	if control == nil {return "The pointer target is not in the application registry"}
	window_point := Point{
		control.rect.x+control.rect.w/2,
		control.rect.y+control.rect.h/2,
	}
	window_number := int(msg_i64(
		state.window,
		sel_registerName("windowNumber"),
	))
	event_class := objc_getClass("NSEvent")
	selector := sel_registerName(
		"mouseEventWithType:location:modifierFlags:timestamp:windowNumber:context:eventNumber:clickCount:pressure:",
	)
	down := msg_id_mouse_event(
		event_class,
		selector,
		1,
		window_point,
		0,
		0,
		window_number,
		nil,
		0,
		1,
		1,
	)
	up := msg_id_mouse_event(
		event_class,
		selector,
		2,
		window_point,
		0,
		0,
		window_number,
		nil,
		0,
		1,
		0,
	)
	if down == nil || up == nil {
		return "AppKit could not create the pointer events"
	}
	msg_void_id(ui.view, sel_registerName("mouseDown:"), down)
	msg_void_id(ui.view, sel_registerName("mouseUp:"), up)
	return ""
}

cli_ui_bridge_pointer :: proc(request: CLI_Request) -> CLI_Result {
	if !ui_automation_enabled() {
		return cli_error(
			request.command,
			.Busy,
			"automation_instance_required",
			"Pointer bridge events require the isolated UI test instance",
		)
	}
	if pointer_error := ui_automation_post_pointer_click(
		request.target_control,
	); len(pointer_error) > 0 {
		return cli_error(
			request.command,
			.Invalid,
			"pointer_failed",
			pointer_error,
		)
	}
	response := UI_Automation_Pointer_Response{
		ok = true,
		command = cli_command_name(request.command),
		data = {control=request.target_control},
	}
	return {
		output = cli_encode(response),
		exit_code = .Success,
	}
}

ui_automation_key_modifiers :: proc(encoded: string) -> (uint, string) {
	modifiers := uint(0)
	for part in strings.split(encoded, ",", context.temp_allocator) {
		name := strings.trim_space(part)
		switch name {
		case "": 
		case "shift": modifiers |= NSEventModifierFlagShift
		case "control": modifiers |= NSEventModifierFlagControl
		case "option": modifiers |= NSEventModifierFlagOption
		case "command": modifiers |= NSEventModifierFlagCommand
		case: return 0, fmt.tprintf("Unknown key modifier: %s", name)
		}
	}
	return modifiers, ""
}

ui_automation_key_event :: proc(
	key_code: int,
	text: string,
	modifiers: uint,
) -> Id {
	send := transmute(proc "c" (
		_: Id,
		_: Sel,
		_: uint,
		_: Point,
		_: uint,
		_: f64,
		_: int,
		_: Id,
		_: Id,
		_: Id,
		_: bool,
		_: u16,
	) -> Id)send_address
	characters := nsstring(text)
	return send(
		objc_getClass("NSEvent"),
		sel_registerName(
			"keyEventWithType:location:modifierFlags:timestamp:windowNumber:context:characters:charactersIgnoringModifiers:isARepeat:keyCode:",
		),
		10,
		{},
		modifiers,
		0,
		int(msg_i64(state.window, sel_registerName("windowNumber"))),
		nil,
		characters,
		characters,
		false,
		u16(key_code),
	)
}

cli_ui_bridge_key :: proc(request: CLI_Request) -> CLI_Result {
	if !ui_automation_enabled() {
		return cli_error(
			request.command,
			.Busy,
			"automation_instance_required",
			"Keyboard bridge events require the isolated UI test instance",
		)
	}
	modifiers, modifier_error := ui_automation_key_modifiers(
		request.key_modifiers,
	)
	if len(modifier_error) > 0 {
		return cli_error(
			request.command,
			.Invalid,
			"invalid_modifiers",
			modifier_error,
		)
	}
	arena, arena_ok := growing_arena_create(256*1024, 64*1024)
	if !arena_ok {
		return cli_error(
			request.command,
			.Storage,
			"allocation_failed",
			"Unable to allocate the keyboard control registry",
		)
	}
	defer growing_arena_destroy(arena)
	previous_build := ui_build
	previous_registry := shared_registry
	defer {
		ui_build = previous_build
		shared_registry = previous_registry
	}
	build_ui_controls(false, mem_virtual.arena_allocator(arena))
	if request.key_code < 0 {
		on_metal_insert_text(
			ui.view,
			sel_registerName("insertText:replacementRange:"),
			nsstring(request.key_text),
			NS_Range{~uint(0), 0},
		)
	} else {
		event := ui_automation_key_event(
			request.key_code,
			request.key_text,
			modifiers,
		)
		if event == nil {
			return cli_error(
				request.command,
				.Invalid,
				"key_event_failed",
				"AppKit could not create the keyboard event",
			)
		}
		on_metal_key_down(
			ui.view,
			sel_registerName("keyDown:"),
			event,
		)
	}
	response := UI_Automation_Key_Response{
		ok = true,
		command = cli_command_name(request.command),
		data = {
			key_code = request.key_code,
			text = request.key_text,
		},
	}
	return {
		output = cli_encode(response),
		exit_code = .Success,
	}
}
