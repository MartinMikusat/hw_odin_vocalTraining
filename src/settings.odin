package main

import "core:fmt"
import command_palette "command_palette:."

Video_Clips_Settings_Category :: enum {
	Styling,
	Shortcuts,
}

Video_Clips_Setting_Descriptor :: struct {
	id: command_palette.Entry_ID,
	category: Video_Clips_Settings_Category,
	title: string,
	subtitle: string,
	keywords: []string,
	action: UI_Action,
}

VIDEO_CLIPS_SETTING_LIGHT_ID :: command_palette.Entry_ID(1)
VIDEO_CLIPS_SETTING_DARK_ID :: command_palette.Entry_ID(2)
VIDEO_CLIPS_SETTING_FLASH_ID :: command_palette.Entry_ID(100)
VIDEO_CLIPS_SETTINGS_ROW_HEIGHT :: 36.0

video_clips_settings_category_name :: proc(category: Video_Clips_Settings_Category) -> string {
	switch category {
	case .Styling: return "STYLING"
	case .Shortcuts: return "SHORTCUTS"
	}
	return "SETTINGS"
}

video_clips_settings_descriptors :: proc(
	allocator := context.temp_allocator,
) -> [dynamic]Video_Clips_Setting_Descriptor {
	result := make([dynamic]Video_Clips_Setting_Descriptor, allocator)
	light_keywords := make([]string, 5, allocator)
	copy(
		light_keywords,
		[]string{"theme", "appearance", "style", "light", "hw-light"},
	)
	append(&result, Video_Clips_Setting_Descriptor{
		id = VIDEO_CLIPS_SETTING_LIGHT_ID,
		category = .Styling,
		title = "HW Light",
		subtitle = "Light interface theme",
		keywords = light_keywords,
		action = {kind = .Set_Theme, value = 0},
	})
	dark_keywords := make([]string, 5, allocator)
	copy(
		dark_keywords,
		[]string{"theme", "appearance", "style", "dark", "hw-dark"},
	)
	append(&result, Video_Clips_Setting_Descriptor{
		id = VIDEO_CLIPS_SETTING_DARK_ID,
		category = .Styling,
		title = "HW Dark",
		subtitle = "Dark interface theme",
		keywords = dark_keywords,
		action = {kind = .Set_Theme, value = 1},
	})
	flash_keywords := make([]string, 5, allocator)
	copy(
		flash_keywords,
		[]string{"keyboard", "shortcut", "leader", "navigation", "jump"},
	)
	append(&result, Video_Clips_Setting_Descriptor{
		id = VIDEO_CLIPS_SETTING_FLASH_ID,
		category = .Shortcuts,
		title = "Flash leader",
		subtitle = "Configure the key chord that opens Flash targets",
		keywords = flash_keywords,
		action = {kind = .Configure_Flash},
	})
	return result
}

video_clips_setting_descriptor_for_id :: proc(
	id: command_palette.Entry_ID,
) -> (Video_Clips_Setting_Descriptor, bool) {
	for descriptor in video_clips_settings_descriptors() {
		if descriptor.id == id {return descriptor, true}
	}
	return {}, false
}

video_clips_settings_entries :: proc(
	allocator := context.temp_allocator,
) -> [dynamic]command_palette.Entry {
	entries := make([dynamic]command_palette.Entry, allocator)
	for descriptor in video_clips_settings_descriptors(allocator) {
		append(&entries, command_palette.Entry{
			id = descriptor.id,
			title = descriptor.title,
			subtitle = descriptor.subtitle,
			category = video_clips_settings_category_name(descriptor.category),
			keywords = descriptor.keywords,
		})
	}
	return entries
}

video_clips_settings_rect_for_size :: proc(width, height: f64) -> UI_Rect {
	modal_width := min(900.0, width-48)
	modal_height := min(600.0, height-72)
	return {
		(width-modal_width)/2,
		(height-modal_height)/2,
		modal_width,
		modal_height,
	}
}

video_clips_settings_rect :: proc() -> UI_Rect {
	return video_clips_settings_rect_for_size(ui.width, ui.height)
}

video_clips_settings_search_rect :: proc() -> UI_Rect {
	modal := video_clips_settings_rect()
	return {modal.x+20, modal.y+modal.h-62, modal.w-76, 34}
}

video_clips_settings_close_rect :: proc() -> UI_Rect {
	modal := video_clips_settings_rect()
	return {modal.x+modal.w-48, modal.y+modal.h-62, 28, 34}
}

video_clips_settings_sidebar_rect :: proc() -> UI_Rect {
	modal := video_clips_settings_rect()
	return {modal.x+20, modal.y+20, 168, modal.h-94}
}

video_clips_settings_content_rect :: proc() -> UI_Rect {
	modal := video_clips_settings_rect()
	return {modal.x+200, modal.y+20, modal.w-220, modal.h-94}
}

video_clips_settings_category_rect :: proc(index: int) -> UI_Rect {
	sidebar := video_clips_settings_sidebar_rect()
	return {
		sidebar.x,
		sidebar.y+sidebar.h-VIDEO_CLIPS_SETTINGS_ROW_HEIGHT-f64(index)*VIDEO_CLIPS_SETTINGS_ROW_HEIGHT,
		sidebar.w,
		VIDEO_CLIPS_SETTINGS_ROW_HEIGHT-2,
	}
}

video_clips_settings_result_rect :: proc(index: int) -> UI_Rect {
	content := video_clips_settings_content_rect()
	return {
		content.x,
		content.y+content.h-VIDEO_CLIPS_SETTINGS_ROW_HEIGHT-f64(index)*VIDEO_CLIPS_SETTINGS_ROW_HEIGHT,
		content.w,
		VIDEO_CLIPS_SETTINGS_ROW_HEIGHT-2,
	}
}

video_clips_settings_search_active :: proc() -> bool {
	return len(ui.settings_query) > 0
}

video_clips_settings_result_descriptors :: proc(
	allocator := context.temp_allocator,
) -> [dynamic]Video_Clips_Setting_Descriptor {
	result := make([dynamic]Video_Clips_Setting_Descriptor, allocator)
	if video_clips_settings_search_active() {
		for ranked in command_palette.visible_results(&ui.settings_search) {
			if descriptor, found := video_clips_setting_descriptor_for_id(ranked.entry.id);
			   found {
				append(&result, descriptor)
			}
		}
		return result
	}
	for descriptor in video_clips_settings_descriptors() {
		if descriptor.category == ui.settings_category {
			append(&result, descriptor)
		}
	}
	return result
}

video_clips_settings_category_match_count :: proc(
	category: Video_Clips_Settings_Category,
) -> int {
	if !video_clips_settings_search_active() {
		count := 0
		for descriptor in video_clips_settings_descriptors() {
			if descriptor.category == category {count += 1}
		}
		return count
	}
	count := 0
	for ranked in command_palette.visible_results(&ui.settings_search) {
		if descriptor, found := video_clips_setting_descriptor_for_id(ranked.entry.id);
		   found && descriptor.category == category {
			count += 1
		}
	}
	return count
}

video_clips_settings_commands_available :: proc() -> bool {
	return !library_recovery_state.required && !major_change_pending.open
}

video_clips_settings_open :: proc() -> bool {
	if !video_clips_settings_commands_available() {return false}
	if ui.settings_open {
		focus_text_input(.Settings_Search)
		return true
	}
	entries := video_clips_settings_entries()
	if error := command_palette.open(&ui.settings_search, entries[:], 0);
	   error != .None {
		return false
	}
	if ui.source_modal_open {close_source_modal()}
	if ui.source_details_open {close_source_details()}
	if ui.clip_rename_open {close_clip_rename()}
	if ui.clip_metadata_open {close_clip_metadata()}
	if ui.randomize_help_open {close_randomize_help()}
	if ui.pitch.help_open {close_pitch_help()}
	if ui.data_modal_open {close_data_modal()}
	if ui.notification_modal_open {close_notification_history()}
	ui.settings_open = true
	ui.settings_category = .Styling
	ui.settings_query_focused = true
	ui_set_string(&ui.settings_query, "")
	ui_set_string(&ui.settings_error, "")
	cancel_ui_flash()
	focus_text_input(.Settings_Search)
	ui.needs_redraw = true
	return true
}

video_clips_settings_close :: proc() {
	if !ui.settings_open {return}
	if ui.shortcut_open {video_clips_shortcut_recorder_close()}
	command_palette.close(&ui.settings_search)
	ui.settings_open = false
	if ui.focus == .Settings_Search {_ = unfocus_text_input()}
	ui.settings_query_focused = false
	ui_set_string(&ui.settings_query, "")
	ui_set_string(&ui.settings_error, "")
	cancel_ui_flash()
	ui.needs_redraw = true
}

video_clips_settings_apply_theme :: proc(dark: bool) -> bool {
	if !video_clips_settings_commands_available() {return false}
	if dark == ui.dark_theme {return true}
	if !database_interface_theme_save(library_database, dark) {
		ui_set_string(&ui.settings_error, "THE THEME COULD NOT BE SAVED")
		ui.needs_redraw = true
		return false
	}
	ui.dark_theme = dark
	ui_set_string(&ui.settings_error, "")
	ui.needs_redraw = true
	return true
}

video_clips_shortcut_recorder_open :: proc() -> bool {
	if !video_clips_settings_commands_available() {return false}
	video_clips_shortcut_destroy(&ui.shortcut_candidate)
	ui.shortcut_candidate_valid = false
	ui_set_string(&ui.shortcut_collision, "")
	ui_set_string(&ui.shortcut_error, "")
	ui.shortcut_live_modifiers = {}
	ui.shortcut_open = true
	ui.shortcut_listening = true
	ui.settings_query_focused = false
	if ui.focus == .Settings_Search {_ = unfocus_text_input()}
	cancel_ui_flash()
	ui.needs_redraw = true
	return true
}

video_clips_shortcut_recorder_close :: proc() {
	video_clips_shortcut_destroy(&ui.shortcut_candidate)
	ui.shortcut_candidate_valid = false
	ui_set_string(&ui.shortcut_collision, "")
	ui_set_string(&ui.shortcut_error, "")
	ui.shortcut_live_modifiers = {}
	ui.shortcut_open = false
	ui.shortcut_listening = false
	ui.needs_redraw = true
}

video_clips_shortcut_recorder_capture :: proc(
	key_code: uint,
	text: string,
	flags: uint,
) -> bool {
	candidate, valid := video_clips_shortcut_from_event(key_code, text, flags)
	if !valid {return false}
	video_clips_shortcut_destroy(&ui.shortcut_candidate)
	ui.shortcut_candidate = candidate
	ui.shortcut_candidate_valid = true
	ui_set_string(&ui.shortcut_collision, "")
	if owner, collides := video_clips_shortcut_collision(candidate); collides {
		ui_set_string(
			&ui.shortcut_collision,
			fmt.tprintf("CONFLICTS WITH %s", owner),
		)
	}
	ui.shortcut_listening = false
	ui.shortcut_live_modifiers = candidate.modifiers
	ui_set_string(&ui.shortcut_error, "")
	ui.needs_redraw = true
	return true
}

video_clips_shortcut_recorder_save :: proc() -> bool {
	if !ui.shortcut_candidate_valid || len(ui.shortcut_collision) > 0 {
		return false
	}
	encoded, valid := video_clips_shortcut_serialize(
		ui.shortcut_candidate,
		context.temp_allocator,
	)
	if !valid || !database_flash_leader_save(library_database, encoded) {
		ui_set_string(&ui.shortcut_error, "THE SHORTCUT COULD NOT BE SAVED")
		ui.needs_redraw = true
		return false
	}
	video_clips_shortcut_destroy(&ui.flash_leader)
	ui.flash_leader = video_clips_shortcut_clone(ui.shortcut_candidate)
	video_clips_shortcut_recorder_close()
	return true
}

video_clips_shortcut_recorder_reset :: proc() -> bool {
	default_value := video_clips_shortcut_default()
	encoded, valid := video_clips_shortcut_serialize(
		default_value,
		context.temp_allocator,
	)
	if !valid || !database_flash_leader_save(library_database, encoded) {
		ui_set_string(
			&ui.shortcut_error,
			"THE DEFAULT SHORTCUT COULD NOT BE SAVED",
		)
		ui.needs_redraw = true
		return false
	}
	video_clips_shortcut_destroy(&ui.flash_leader)
	ui.flash_leader = video_clips_shortcut_clone(default_value)
	video_clips_shortcut_recorder_close()
	return true
}

video_clips_shortcut_modal_rect :: proc() -> UI_Rect {
	width := min(560.0, ui.width-48)
	height := 260.0
	return {(ui.width-width)/2, (ui.height-height)/2, width, height}
}

video_clips_shortcut_record_rect :: proc() -> UI_Rect {
	modal := video_clips_shortcut_modal_rect()
	return {modal.x+24, modal.y+86, modal.w-48, 54}
}

video_clips_shortcut_action_rect :: proc(index: int) -> UI_Rect {
	modal := video_clips_shortcut_modal_rect()
	gap := 8.0
	width := (modal.w-48-gap*2)/3
	return {
		modal.x+24+f64(index)*(width+gap),
		modal.y+24,
		width,
		34,
	}
}
