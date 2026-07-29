package main

import "core:testing"
import mem_virtual "core:mem/virtual"
import command_palette "command_palette:."
import match_sorter "match_sorter:."

@(test)
vocal_settings_layout_contains_two_columns_at_minimum_size_test :: proc(
	t: ^testing.T,
) {
	modal := vocal_settings_rect_for_size(1100, 720)
	testing.expect_value(t, modal, UI_Rect{100, 60, 900, 600})
	testing.expect(t, modal.w > 168+32+240)
	testing.expect(t, modal.h > 300)
}

@(test)
vocal_settings_catalog_contains_hw_themes_and_flash_test :: proc(
	t: ^testing.T,
) {
	descriptors := vocal_settings_descriptors()
	testing.expect_value(t, len(descriptors), 3)
	theme_count := 0
	flash_count := 0
	for descriptor in descriptors {
		if descriptor.action.kind == .Set_Theme {theme_count += 1}
		if descriptor.action.kind == .Configure_Flash {flash_count += 1}
	}
	testing.expect_value(t, theme_count, 2)
	testing.expect_value(t, flash_count, 1)
}

@(test)
vocal_settings_search_ranks_theme_and_flash_test :: proc(t: ^testing.T) {
	search: command_palette.State
	testing.expect(t, command_palette.state_init(
		&search,
		search_reserve_size = 4*1024*1024,
		search_commit_size = 64*1024,
	) == nil)
	defer command_palette.state_destroy(&search)
	entries := vocal_settings_entries()
	testing.expect_value(
		t,
		command_palette.open(&search, entries[:], 0),
		match_sorter.Search_Error.None,
	)
	testing.expect_value(
		t,
		command_palette.set_query(&search, "dark"),
		match_sorter.Search_Error.None,
	)
	results := command_palette.visible_results(&search)
	testing.expect_value(t, len(results), 1)
	testing.expect_value(t, results[0].entry.id, VOCAL_SETTING_DARK_ID)
	testing.expect_value(
		t,
		command_palette.set_query(&search, "leader"),
		match_sorter.Search_Error.None,
	)
	results = command_palette.visible_results(&search)
	testing.expect_value(t, len(results), 1)
	testing.expect_value(t, results[0].entry.id, VOCAL_SETTING_FLASH_ID)
}

@(test)
vocal_settings_controls_accept_pointer_actions_test :: proc(t: ^testing.T) {
	previous_state := state
	previous_ui := ui
	previous_ui_build := ui_build
	previous_recovery := library_recovery_state
	previous_pending := major_change_pending
	defer {
		command_palette.state_destroy(&ui.settings_search)
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
		mode = .Create,
		settings_open = true,
		settings_category = .Styling,
		active_exercise = -1,
		source_details_index = -1,
		source_modal_refetch_index = -1,
		exercise_rename_index = -1,
		exercise_metadata_index = -1,
		transcript_active_match = -1,
	}
	library_recovery_state = {}
	major_change_pending = {}
	testing.expect(t, command_palette.state_init(
		&ui.settings_search,
		search_reserve_size = 4*1024*1024,
		search_commit_size = 64*1024,
	) == nil)
	entries := vocal_settings_entries()
	testing.expect_value(
		t,
		command_palette.open(&ui.settings_search, entries[:], 0),
		match_sorter.Search_Error.None,
	)
	frame_arena: mem_virtual.Arena
	testing.expect(t, mem_virtual.arena_init_static(
		&frame_arena,
		1024*1024,
		4096,
	) == nil)
	defer mem_virtual.arena_destroy(&frame_arena)
	build_ui_controls(false, mem_virtual.arena_allocator(&frame_arena))
	testing.expect(t, ui_controls_valid(ui_build.controls[:]))
	testing.expect(t, find_ui_control_by_action(.Open_Settings) != nil)
	testing.expect(t, find_ui_control_by_action(.Settings_Search) != nil)
	testing.expect(t, find_ui_control_by_action(.Set_Theme) != nil)
	for control in ui_build.controls {
		testing.expect(t, control.functional_name != "theme toggle")
	}

	shortcuts_category := find_ui_control_by_action_and_index(
		.Settings_Category,
		1,
	)
	testing.expect(t, shortcuts_category != nil)
	if shortcuts_category != nil {
		dispatch_click({
			shortcuts_category.rect.x+shortcuts_category.rect.w/2,
			shortcuts_category.rect.y+shortcuts_category.rect.h/2,
		})
	}
	testing.expect_value(
		t,
		ui.settings_category,
		Vocal_Settings_Category.Shortcuts,
	)

	build_ui_controls(false, mem_virtual.arena_allocator(&frame_arena))
	configure_flash := find_ui_control_by_action(.Configure_Flash)
	testing.expect(t, configure_flash != nil)
	if configure_flash != nil {
		dispatch_click({
			configure_flash.rect.x+configure_flash.rect.w/2,
			configure_flash.rect.y+configure_flash.rect.h/2,
		})
	}
	testing.expect(t, ui.shortcut_open)

	build_ui_controls(false, mem_virtual.arena_allocator(&frame_arena))
	cancel_shortcut := find_ui_control_by_action(.Shortcut_Cancel)
	testing.expect(t, cancel_shortcut != nil)
	if cancel_shortcut != nil {
		dispatch_click({
			cancel_shortcut.rect.x+cancel_shortcut.rect.w/2,
			cancel_shortcut.rect.y+cancel_shortcut.rect.h/2,
		})
	}
	testing.expect(t, !ui.shortcut_open)
}

@(test)
vocal_shortcut_round_trips_and_rejects_collisions_test :: proc(t: ^testing.T) {
	shortcut := vocal_shortcut_character("g", {.Control, .Shift})
	encoded, valid := vocal_shortcut_serialize(
		shortcut,
		context.temp_allocator,
	)
	testing.expect(t, valid)
	decoded: Vocal_Shortcut
	decoded, valid = vocal_shortcut_deserialize(encoded)
	testing.expect(t, valid)
	defer vocal_shortcut_destroy(&decoded)
	testing.expect(t, vocal_shortcut_equal(shortcut, decoded))

	owner, collides := vocal_shortcut_collision(
		vocal_shortcut_character("2"),
	)
	testing.expect(t, collides)
	testing.expect_value(t, owner, "Numbered action section 2")
}

@(test)
vocal_shortcut_invalid_storage_falls_back_to_default_test :: proc(t: ^testing.T) {
	_, valid := vocal_shortcut_deserialize(`{"version":1,"kind":"named","key":"return","modifiers":[]}`)
	testing.expect(t, !valid)
	default_value := vocal_shortcut_default()
	testing.expect_value(t, default_value.key, "/")
	testing.expect_value(t, default_value.kind, Vocal_Shortcut_Key_Kind.Character)
}
