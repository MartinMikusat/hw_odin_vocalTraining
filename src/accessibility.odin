package main

import "base:runtime"
import command_palette "command_palette:."
import framework_ui "ui_framework:core"

AX_Action :: struct {
	element:    Id,
	control_id: UI_Control_ID,
}

ax_actions: [dynamic]AX_Action

ax_screen_rect :: proc(rect: UI_Rect) -> Rect {
	view_rect := Rect{Point{rect.x, rect.y}, Size{rect.w, rect.h}}
	window_rect := msg_rect_rect_id(
		ui.view,
		sel_registerName("convertRect:toView:"),
		view_rect,
		nil,
	)
	return msg_rect_rect(state.window, sel_registerName("convertRectToScreen:"), window_rect)
}


append_ax_element_for_control :: proc(
	array, element_class: Id,
	control: ^UI_Control,
) {
	if array == nil || control == nil || .Accessibility not_in control.flags {return}
	kind := control.action.kind
	index := control.action.index
	selected_value := control.action.value
	element := msg_id(element_class, sel_registerName("new"))
	msg_void_id(element, sel_registerName("setAccessibilityParent:"), ui.view)
	msg_void_id(
		element,
		sel_registerName("setAccessibilityRole:"),
		nsstring(control.accessibility_role),
	)
	msg_void_id(
		element,
		sel_registerName("setAccessibilityLabel:"),
		nsstring(control.accessibility_label),
	)
	if kind == .Toggle_Save_Source_Browser ||
	   kind == .Pitch_Highlight ||
	   kind == .Pitch_Range ||
	   kind == .Pitch_Labels ||
	   kind == .Pitch_Transpose ||
	   kind == .Shuffle_Toggle ||
	   kind == .Autoplay_Toggle {
		checked := uint(0)
		#partial switch kind {
		case .Toggle_Save_Source_Browser:
			if ui.save_source_browser_choice {checked = 1}
		case .Pitch_Highlight:
			if ui.pitch.settings.highlight {checked = 1}
		case .Pitch_Range:
			if selected_value == int(ui.pitch.settings.range) {checked = 1}
		case .Pitch_Labels:
			if selected_value == int(ui.pitch.settings.labels) {checked = 1}
		case .Pitch_Transpose:
			if selected_value == int(ui.pitch.settings.transpose) {checked = 1}
		case .Shuffle_Toggle:
			if ui.clip_shuffle {checked = 1}
		case .Autoplay_Toggle:
			if ui.clip_autoplay {checked = 1}
		case:
		}
		value := msg_id_uint(
			objc_getClass("NSNumber"),
			sel_registerName("numberWithUnsignedInt:"),
			checked,
		)
		msg_void_id(element, sel_registerName("setAccessibilityValue:"), value)
	}
	if kind == .Set_Theme {
		value := msg_id_uint(
			objc_getClass("NSNumber"),
			sel_registerName("numberWithUnsignedInt:"),
			uint(UI_Theme(selected_value) == ui.theme),
		)
		msg_void_id(element, sel_registerName("setAccessibilityValue:"), value)
	} else if kind == .Settings_Category {
		value := msg_id_uint(
			objc_getClass("NSNumber"),
			sel_registerName("numberWithUnsignedInt:"),
			uint(index == int(ui.settings_category)),
		)
		msg_void_id(element, sel_registerName("setAccessibilityValue:"), value)
	} else if kind == .Settings_Search {
		msg_void_id(
			element,
			sel_registerName("setAccessibilityValue:"),
			nsstring(ui.settings_query),
		)
	} else if kind == .Configure_Flash {
		msg_void_id(
			element,
			sel_registerName("setAccessibilityValue:"),
			nsstring(video_clips_shortcut_display(ui.flash_leader)),
		)
	}
	msg_void_bool(
		element,
		sel_registerName("setAccessibilityEnabled:"),
		.Enabled in control.flags,
	)
	msg_void_rect(
		element,
		sel_registerName("setAccessibilityFrame:"),
		ax_screen_rect(control.rect),
	)
	msg_void_id(array, sel_registerName("addObject:"), element)
	append(&ax_actions, AX_Action{element = element, control_id = control.id})
	msg_void(element, sel_registerName("release"))
}


find_ax_control :: proc(element: Id) -> ^UI_Control {
	for &binding in ax_actions {
		if binding.element == element {return find_ui_control(binding.control_id)}
	}
	return nil
}


on_ax_press :: proc "c" (self: Id, command: Sel) -> bool {
	context = runtime.default_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	control := find_ax_control(self)
	if control == nil {return false}
	_, activated := framework_ui.activate_control_in_view(
		shared_registry,
		framework_ui.Key(control.id),
		.Accessibility,
	)
	if !activated {return false}
	return activate_ui_action(control.action)
}

on_ax_value :: proc "c" (self: Id, command: Sel) -> Id {
	context = runtime.default_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	control := find_ax_control(self)
	if control == nil {return nil}
	#partial switch control.action.kind {
	case .Toggle_Save_Source_Browser:
		checked := uint(0)
		if ui.save_source_browser_choice {checked = 1}
		return msg_id_uint(
			objc_getClass("NSNumber"),
			sel_registerName("numberWithUnsignedInt:"),
			checked,
		)
	case .Shuffle_Toggle, .Autoplay_Toggle:
		checked := uint(0)
		if (control.action.kind == .Shuffle_Toggle &&
		    ui.clip_shuffle) ||
		   (control.action.kind == .Autoplay_Toggle &&
		    ui.clip_autoplay) {
			checked = 1
		}
		return msg_id_uint(
			objc_getClass("NSNumber"),
			sel_registerName("numberWithUnsignedInt:"),
			checked,
		)
	case .Command_Palette_Search:
		return nsstring(ui.command_palette_query)
	case .Settings_Search:
		return nsstring(ui.settings_query)
	case .Set_Theme:
		checked := uint(0)
		if UI_Theme(control.action.value) == ui.theme {checked = 1}
		return msg_id_uint(
			objc_getClass("NSNumber"),
			sel_registerName("numberWithUnsignedInt:"),
			checked,
		)
	case .Settings_Category:
		checked := uint(0)
		if control.action.index == int(ui.settings_category) {checked = 1}
		return msg_id_uint(
			objc_getClass("NSNumber"),
			sel_registerName("numberWithUnsignedInt:"),
			checked,
		)
	case .Configure_Flash:
		return nsstring(video_clips_shortcut_display(ui.flash_leader))
	case .URL:
		return nsstring(ui.url_input)
	case .Source_Search:
		return nsstring(ui.source_search)
	case .Transcript_Search:
		return nsstring(ui.transcript_search)
	case .Clip_Search:
		return nsstring(ui.clip_search)
	case .Clip_Name:
		return nsstring(ui.clip_name)
	case .Clip_Rename:
		return nsstring(ui.clip_rename)
	}
	return nil
}

set_ui_control_value :: proc(action: UI_Action, text: string) -> bool {
	#partial switch action.kind {
	case .Command_Palette_Search:
		ui_set_string(&ui.command_palette_query, text)
		search_error := command_palette.set_query(
			&command_palette_state,
			ui.command_palette_query,
		)
		if search_error != .None {
			ui_set_string(
				&ui.command_palette_query,
				command_palette.query(&command_palette_state),
			)
			_ = notification_post_error(
				"Command palette search contains invalid UTF-8.",
			)
		}
		ui.command_palette_scroll = 0
		ensure_command_palette_selection_visible()
	case .Settings_Search:
		ui_set_string(&ui.settings_query, text)
		focused_text_changed(&ui.settings_query)
		focus_text_input(.Settings_Search)
	case .URL:
		ui_set_string(&ui.url_input, text)
	case .Source_Search:
		ui_set_string(&ui.source_search, text)
	case .Transcript_Search:
		ui_set_string(&ui.transcript_search, text)
		invalidate_transcript_matches()
	case .Clip_Search:
		ui_set_string(&ui.clip_search, text)
	case .Clip_Name:
		ui_set_string(&ui.clip_name, text)
		focused_text_changed(&ui.clip_name)
	case .Clip_Rename:
		ui_set_string(&ui.clip_rename, text)
	case:
		return false
	}
	ui.needs_redraw = true
	return true
}

on_ax_set_value :: proc "c" (self: Id, command: Sel, value: Id) {
	context = runtime.default_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	control := find_ax_control(self)
	if control == nil || .Editable not_in control.flags {return}
	utf8 := msg_id(value, sel_registerName("UTF8String"))
	if utf8 == nil {return}
	_ = set_ui_control_value(control.action, string(cstring(utf8)))
}

on_metal_ax_children :: proc "c" (self: Id, command: Sel) -> Id {
	return ui.ax_children
}

on_metal_is_ax_element :: proc "c" (self: Id, command: Sel) -> bool {return false}


register_accessibility_class :: proc() {
	class := objc_allocateClassPair(
		objc_getClass("NSAccessibilityElement"),
		"VocalAccessibilityElement",
		0,
	)
	class_addMethod(
		class,
		sel_registerName("accessibilityPerformPress"),
		rawptr(on_ax_press),
		"B@:",
	)
	class_addMethod(class, sel_registerName("accessibilityValue"), rawptr(on_ax_value), "@@:")
	class_addMethod(
		class,
		sel_registerName("setAccessibilityValue:"),
		rawptr(on_ax_set_value),
		"v@:@",
	)
	objc_registerClassPair(class)
}

