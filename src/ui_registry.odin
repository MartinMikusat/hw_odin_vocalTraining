package main

import "core:hash"
import "core:mem"
import command_palette "command_palette:."
import flash "flash:."
import framework_ui "ui_framework:core"
import framework_macos "ui_framework:macos"

shared_registry: framework_ui.Registry_View

ui_control_id :: proc(functional_name: string) -> UI_Control_ID {
	value := hash.fnv64a(transmute([]byte)functional_name)
	if value == 0 {value = 1}
	return UI_Control_ID(value)
}

find_ui_control :: proc(id: UI_Control_ID) -> ^UI_Control {
	if id == 0 {return nil}
	for &control in ui_build.controls {
		if control.id == id {return &control}
	}
	return nil
}

find_ui_control_by_action :: proc(kind: UI_Action_Kind) -> ^UI_Control {
	for &control in ui_build.controls {
		if control.action.kind == kind {return &control}
	}
	return nil
}

find_ui_control_by_action_and_index :: proc(kind: UI_Action_Kind, index: int) -> ^UI_Control {
	for &control in ui_build.controls {
		if control.action.kind == kind && control.action.index == index {return &control}
	}
	return nil
}

find_ui_control_by_functional_name :: proc(
	controls: []UI_Control,
	functional_name: string,
) -> ^UI_Control {
	for &control in controls {
		if control.functional_name == functional_name {return &control}
	}
	return nil
}

ui_control_rect :: proc(kind: UI_Action_Kind, index: int = -1) -> UI_Rect {
	control: ^UI_Control
	if index < 0 {
		control = find_ui_control_by_action(kind)
	} else {
		control = find_ui_control_by_action_and_index(kind, index)
	}
	if control == nil {return {}}
	return control.rect
}

ui_control_rect_by_value :: proc(
	kind: UI_Action_Kind,
	index, value: int,
) -> UI_Rect {
	for &control in ui_build.controls {
		if control.action.kind == kind &&
		   control.action.index == index &&
		   control.action.value == value {
			return control.rect
		}
	}
	return {}
}

find_ui_control_at_point :: proc(
	controls: []UI_Control,
	point: Point,
	required_flag: UI_Control_Flag,
) -> ^UI_Control {
	for index := len(controls)-1; index >= 0; index -= 1 {
		control := &controls[index]
		if required_flag not_in control.flags || .Enabled not_in control.flags {continue}
		if contains(control.rect, point) {return control}
	}
	return nil
}

find_shared_ui_control_at_point :: proc(
	point: Point,
	required_flag: UI_Control_Flag,
) -> ^UI_Control {
	kind := framework_macos.Pointer_Event_Kind.Primary_Press
	switch required_flag {
	case .Secondary_Press: kind = .Secondary_Press
	case .Drag: kind = .Drag
	case .Primary_Press, .Flash, .Accessibility, .Editable, .Enabled:
	}
	activation, activated := framework_macos.pointer_activation_view(
		shared_registry,
		kind,
		{f32(point.x), f32(point.y)},
	)
	if !activated {return nil}
	return find_ui_control(UI_Control_ID(activation.control))
}

header_window_gesture_allowed :: proc(
	header: UI_Rect,
	controls: []UI_Control,
	point: Point,
) -> bool {
	return contains(header, point) &&
	       find_ui_control_at_point(controls, point, .Primary_Press) == nil
}

ui_controls_valid :: proc(controls: []UI_Control) -> bool {
	for &control, index in controls {
		if control.id == 0 || len(control.functional_name) == 0 {return false}
		if control.rect.w <= 0 || control.rect.h <= 0 {return false}
		for other_index in index+1..<len(controls) {
			other := &controls[other_index]
			if control.id == other.id {return false}
			if control.functional_name == other.functional_name {return false}
		}
	}
	return true
}

framework_accessibility_role :: proc(role: string) -> framework_ui.Accessibility_Role {
	switch role {
	case "AXButton": return .Button
	case "AXTextField": return .Text_Field
	case "AXCheckBox": return .Check_Box
	case "AXRadioButton": return .Radio_Button
	case "AXSlider": return .Slider
	case "AXList": return .List
	case "AXRow": return .List_Item
	case "AXGroup": return .Group
	}
	return .None
}

framework_flash_anchor :: proc(anchor: flash.Anchor) -> framework_ui.Flash_Anchor {
	switch anchor {
	case .Top_Left: return .Top_Left
	case .Top_Right: return .Top_Right
	case .Bottom_Left: return .Bottom_Left
	case .Bottom_Right: return .Bottom_Right
	case .Center: return .Center
	}
	return .Top_Left
}

flash_anchor_from_framework :: proc(anchor: framework_ui.Flash_Anchor) -> flash.Anchor {
	switch anchor {
	case .Top_Left: return .Top_Left
	case .Top_Right: return .Top_Right
	case .Bottom_Left: return .Bottom_Left
	case .Bottom_Right: return .Bottom_Right
	case .Center: return .Center
	}
	return .Top_Left
}

framework_numbered_action_index :: proc(kind: UI_Action_Kind) -> (int, bool) {
	#partial switch kind {
	case .Start: return 0, true
	case .End: return 1, true
	case .Save: return 2, true
	case .Play: return 3, true
	case .Pause: return 4, true
	case .Captions: return 5, true
	case .Preview: return 6, true
	case .Data: return 7, true
	case .Rename: return 8, true
	case .Metadata: return 9, true
	case .Randomize: return 10, true
	case .Pitch_Toggle: return 11, true
	case .Play_Next: return 12, true
	case .Shuffle_Toggle: return 13, true
	case .Autoplay_Toggle: return 14, true
	case .Dance_Mirror_Toggle: return 15, true
	case .Dance_Loop_Toggle: return 16, true
	case .Dance_Count_In: return 17, true
	case .Dance_Count_Each_Loop_Toggle: return 18, true
	case .Playback_Fullscreen_Toggle: return 19, true
	}
	return -1, false
}

framework_control_capabilities :: proc(control: ^UI_Control) -> framework_ui.Control_Capabilities {
	result := framework_ui.Control_Capabilities{.CLI}
	if .Primary_Press in control.flags {result += {.Hover, .Primary_Press}}
	if .Secondary_Press in control.flags {result += {.Secondary_Press}}
	if .Drag in control.flags {result += {.Hover, .Drag}}
	if .Editable in control.flags {result += {.Editable}}
	if .Accessibility in control.flags {result += {.Accessibility}}
	if .Flash in control.flags {result += {.Flash}}
	if index, found := framework_numbered_action_index(control.action.kind); found {
		if _, has_code := numbered_action_code_for_action(ui.mode, index); has_code {
			result += {.Numbered, .Direct_Keyboard}
		}
	}
	if !ui_action_is_window(control.action.kind) &&
	   .Editable not_in control.flags && .Drag not_in control.flags {
		result += {.Command_Menu}
	}
	return result
}

framework_modal_active :: proc() -> bool {
	return library_recovery_state.required || major_change_pending.open ||
	       ui.discard_confirm_open || command_palette.is_open(&command_palette_state) ||
	       ui.randomize_help_open || ui.pitch.help_open || ui.shortcut_open ||
	       ui.settings_open || ui.notification_modal_open || ui.data_modal_open ||
	       ui.clip_metadata_open || ui.clip_rename_open || ui.source_details_open ||
	       ui.source_modal_open
}

publish_shared_control_registry :: proc(allocator: mem.Allocator) {
	actions := make(
		[dynamic]framework_ui.Action_Record,
		0,
		len(ui_build.controls),
		allocator,
	)
	controls := make(
		[dynamic]framework_ui.Control_Record,
		0,
		len(ui_build.controls),
		allocator,
	)
	modal_active := framework_modal_active()
	for &control in ui_build.controls {
		action_id := framework_ui.Action_ID(u64(control.id))
		number_code: framework_ui.Number_Code
		if index, found := framework_numbered_action_index(control.action.kind); found {
			if code, has_code := numbered_action_code_for_action(ui.mode, index); has_code {
				number_code = {i8(code.section), i8(code.action), 2}
			}
		}
		append(&actions, framework_ui.Action_Record{
			id = action_id,
			functional_name = control.functional_name,
			label = control.accessibility_label,
			enabled = .Enabled in control.flags,
			number_code = number_code,
		})
		layer := framework_ui.Layer.Base
		if modal_active && !ui_action_is_window(control.action.kind) {layer = .Modal}
		append(&controls, framework_ui.Control_Record{
			id = framework_ui.Key(u64(control.id)),
			functional_name = control.functional_name,
			accessibility_label = control.accessibility_label,
			accessibility_role = framework_accessibility_role(control.accessibility_role),
			flash_label = flash_target_label(&control),
			flash_anchor = framework_flash_anchor(control.anchor),
			capabilities = framework_control_capabilities(&control),
			action = action_id,
			rect = {
				f32(control.rect.x),
				f32(control.rect.y),
				f32(control.rect.w),
				f32(control.rect.h),
			},
			layer = layer,
			focusable = .Editable in control.flags,
			enabled = .Enabled in control.flags,
		})
	}
	shared_registry = framework_ui.registry_view_from_records(
		actions[:],
		controls[:],
		u64(ui_build.frame),
	)
	framework_ui.registry_assert_valid(shared_registry, allocator)
}

consume_shared_numbered_digit :: proc(
	digit: int,
	now_ms: i64,
) -> (UI_Control_ID, bool, bool) {
	state := framework_macos.Numbered_State{
		first = i8(ui.number_prefix),
		deadline_ms = ui.number_prefix_deadline_ms,
	}
	activation, activated, handled := framework_macos.consume_numbered_digit_view(
		&state,
		shared_registry,
		i8(digit),
		now_ms,
	)
	changed := ui.number_prefix != int(state.first) ||
	           ui.number_prefix_deadline_ms != state.deadline_ms
	ui.number_prefix = int(state.first)
	ui.number_prefix_deadline_ms = state.deadline_ms
	if changed || handled {ui.needs_redraw = true}
	if !activated {return UI_Control_ID(0), false, handled}
	return UI_Control_ID(activation.action), true, handled
}
