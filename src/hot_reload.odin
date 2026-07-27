package main

import "base:runtime"
import "core:fmt"
import "core:os"
import command_palette "command_palette:."
import flash "flash:."
import match_sorter "match_sorter:."
import hot_reload "../dev/hot_reload_contract"

vocal_hot_previous_solid_pipeline: Id
vocal_hot_previous_texture_pipeline: Id

Vocal_Hot_Reload_Snapshot :: struct {
	state:                        App_State,
	major_change_pending:         Major_Change_Pending,
	major_change_backup_override: bool,
	last_imported_source:         int,
	yt_dlp_helper_status:         Helper_Status,
	ffmpeg_helper_status:         Helper_Status,
	library_recovery:             ^Library_Recovery,
	pending_library_import:       App_State,
	source_probe_results:         [dynamic]Source_Probe_Result,
	source_probe_cache:           [dynamic]Source_Probe_Result,
	source_auth_saved_browser:    Source_Auth_Browser,
	library_storage_mode:         Library_Storage_Mode,
	library_recovery_state:       Library_Recovery_State,
	library_database:             ^SQLite_DB,
	library_legacy_fallback:      bool,
	memory:                       Memory_State,
	ui:                           UI_State,
	ui_event_tag:                 int,
	ax_actions:                   [dynamic]AX_Action,
	ui_build:                     UI_Build_Output,
	flash_state:                  flash.State,
	command_palette_state:        command_palette.State,
	command_palette_actions:      [dynamic]UI_Action,
	command_palette_config:       command_palette.Config,
	transcript_search_context:    match_sorter.Search_Context,
	notification_history:         Notification_History,
	cli_library_owner:            CLI_Library_Owner,
	ui_diagnostic_artifact_serial: int,
}

vocal_hot_resolve_runtime :: proc() -> bool {
	objc_handle := os.dlopen("/usr/lib/libobjc.A.dylib", os.RTLD_NOW)
	if objc_handle == nil {return false}
	send_address = os.dlsym(objc_handle, "objc_msgSend")
	libsystem_handle := os.dlopen("/usr/lib/libSystem.B.dylib", os.RTLD_NOW)
	if libsystem_handle == nil {return false}
	system_address = os.dlsym(libsystem_handle, "system")
	return send_address != nil && system_address != nil
}

vocal_hot_initialize :: proc "c" (
	services: ^hot_reload.Host_Services,
) -> bool {
	context = runtime.default_context()
	if services == nil || !memory_init() {return false}
	if error := match_sorter.search_context_init(
		&transcript_search_context,
		SEARCH_RESERVE_SIZE,
		SEARCH_COMMIT_SIZE,
	); error != nil {
		memory_destroy()
		return false
	}
	configure_helper_path()
	if !vocal_hot_resolve_runtime() {
		match_sorter.search_context_destroy(&transcript_search_context)
		memory_destroy()
		return false
	}
	state.active_source = -1
	if !cli_library_try_acquire() {
		fmt.eprintln("Vocal Training is already running or the library is busy")
		return false
	}
	load_result := load_library()
	notification_history_initialize()
	if load_result.mode != .Ready {
		_ = notification_post(
			.Error,
			"Library recovery is required",
			load_result.detail,
			persist = false,
		)
		if library_recovery_state.recovery_allowed {
			_ = library_recovery_analyze()
		}
	}
	library_load_result_destroy(&load_result)
	if !vocal_gui_initialize(services) {return false}
	return true
}

vocal_hot_can_reload :: proc "c" () -> bool {
	return import_job == nil &&
	       export_job == nil &&
	       source_metadata_job == nil &&
	       source_probe_job == nil &&
	       library_recovery == nil &&
	       cli_ipc_work == nil
}

vocal_hot_capture :: proc "c" (destination: rawptr) {
	snapshot := (^Vocal_Hot_Reload_Snapshot)(destination)
	snapshot^ = {
		state = state,
		major_change_pending = major_change_pending,
		major_change_backup_override = major_change_backup_override,
		last_imported_source = last_imported_source,
		yt_dlp_helper_status = yt_dlp_helper_status,
		ffmpeg_helper_status = ffmpeg_helper_status,
		library_recovery = library_recovery,
		pending_library_import = pending_library_import,
		source_probe_results = source_probe_results,
		source_probe_cache = source_probe_cache,
		source_auth_saved_browser = source_auth_saved_browser,
		library_storage_mode = library_storage_mode,
		library_recovery_state = library_recovery_state,
		library_database = library_database,
		library_legacy_fallback = library_legacy_fallback,
		memory = memory,
		ui = ui,
		ui_event_tag = ui_event_tag,
		ax_actions = ax_actions,
		ui_build = ui_build,
		flash_state = flash_state,
		command_palette_state = command_palette_state,
		command_palette_actions = command_palette_actions,
		command_palette_config = command_palette_config,
		transcript_search_context = transcript_search_context,
		notification_history = notification_history,
		cli_library_owner = cli_library_owner,
		ui_diagnostic_artifact_serial = ui_diagnostic_artifact_serial,
	}
}

vocal_hot_stage :: proc "c" (
	source: rawptr,
	services: ^hot_reload.Host_Services,
) -> bool {
	context = runtime.default_context()
	if source == nil || services == nil || !vocal_hot_resolve_runtime() {
		return false
	}
	snapshot := (^Vocal_Hot_Reload_Snapshot)(source)
	state = snapshot.state
	state.delegate_target = Id(services.delegate)
	major_change_pending = snapshot.major_change_pending
	major_change_backup_override = snapshot.major_change_backup_override
	last_imported_source = snapshot.last_imported_source
	yt_dlp_helper_status = snapshot.yt_dlp_helper_status
	ffmpeg_helper_status = snapshot.ffmpeg_helper_status
	library_recovery = snapshot.library_recovery
	pending_library_import = snapshot.pending_library_import
	source_probe_results = snapshot.source_probe_results
	source_probe_cache = snapshot.source_probe_cache
	source_auth_saved_browser = snapshot.source_auth_saved_browser
	library_storage_mode = snapshot.library_storage_mode
	library_recovery_state = snapshot.library_recovery_state
	library_database = snapshot.library_database
	library_legacy_fallback = snapshot.library_legacy_fallback
	memory = snapshot.memory
	ui = snapshot.ui
	ui_event_tag = snapshot.ui_event_tag
	ax_actions = snapshot.ax_actions
	ui_build = snapshot.ui_build
	flash_state = snapshot.flash_state
	command_palette_state = snapshot.command_palette_state
	command_palette_actions = snapshot.command_palette_actions
	command_palette_config = snapshot.command_palette_config
	transcript_search_context = snapshot.transcript_search_context
	notification_history = snapshot.notification_history
	cli_library_owner = snapshot.cli_library_owner
	ui_diagnostic_artifact_serial = snapshot.ui_diagnostic_artifact_serial
	previous_solid := ui.solid_pipeline
	previous_texture := ui.texture_pipeline
	ui.solid_pipeline = nil
	ui.texture_pipeline = nil
	if !compile_pipelines() {
		if ui.solid_pipeline != nil {
			msg_void(ui.solid_pipeline, sel_registerName("release"))
		}
		if ui.texture_pipeline != nil {
			msg_void(ui.texture_pipeline, sel_registerName("release"))
		}
		ui.solid_pipeline = previous_solid
		ui.texture_pipeline = previous_texture
		return false
	}
	vocal_hot_previous_solid_pipeline = previous_solid
	vocal_hot_previous_texture_pipeline = previous_texture
	import_job = nil
	export_job = nil
	source_metadata_job = nil
	source_probe_job = nil
	cli_ipc_state = CLI_IPC_State{listen_fd = -1, active_client_fd = -1}
	cli_ipc_work = nil
	ui.needs_redraw = true
	return true
}

vocal_hot_before_swap :: proc "c" () {
	context = runtime.default_context()
	cli_ipc_server_stop()
}

vocal_hot_commit :: proc "c" () {
	context = runtime.default_context()
	if vocal_hot_previous_solid_pipeline != nil {
		msg_void(vocal_hot_previous_solid_pipeline, sel_registerName("release"))
		vocal_hot_previous_solid_pipeline = nil
	}
	if vocal_hot_previous_texture_pipeline != nil {
		msg_void(vocal_hot_previous_texture_pipeline, sel_registerName("release"))
		vocal_hot_previous_texture_pipeline = nil
	}
	if !cli_ipc_server_start() {
		set_text(state.status, "CLI control socket is unavailable")
	}
	ui.needs_redraw = true
}

vocal_hot_shutdown :: proc "c" () {
	context = runtime.default_context()
	cli_ipc_server_stop()
	jobs_shutdown()
	ui_memory_destroy()
	notification_history_destroy()
	source_probe_results_clear()
	source_probe_cache_clear()
	delete(major_change_pending.detail)
	library_recovery_state_destroy()
	app_state_memory_destroy()
	match_sorter.search_context_destroy(&transcript_search_context)
	helper_statuses_destroy()
	database_close()
	cli_library_release()
	memory_destroy()
}

vocal_hot_cli_main :: proc "c" (args: [^]cstring, count: int) -> i32 {
	context = runtime.default_context()
	values := make([]string, count, context.temp_allocator)
	for index in 0..<count {
		values[index] = string(args[index])
	}
	vocal_process_main(values)
	return 0
}

vocal_hot_api := hot_reload.Module_API{
	api_version = hot_reload.API_VERSION,
	state_version = hot_reload.STATE_VERSION,
	snapshot_size = size_of(Vocal_Hot_Reload_Snapshot),
	snapshot_align = align_of(Vocal_Hot_Reload_Snapshot),
	initialize = rawptr(vocal_hot_initialize),
	can_reload = rawptr(vocal_hot_can_reload),
	capture = rawptr(vocal_hot_capture),
	stage = rawptr(vocal_hot_stage),
	before_swap = rawptr(vocal_hot_before_swap),
	commit = rawptr(vocal_hot_commit),
	shutdown = rawptr(vocal_hot_shutdown),
	cli_main = rawptr(vocal_hot_cli_main),
	callbacks = {
		rawptr(on_import_finished),
		rawptr(on_export_finished),
		rawptr(on_source_metadata_finished),
		rawptr(on_source_probe_finished),
		rawptr(on_metal_frame),
		rawptr(on_cli_ipc_request),
		rawptr(on_audio_engine_configuration_changed),
		rawptr(on_audio_engine_recover_configuration),
		rawptr(should_terminate_after_window_close),
		rawptr(on_ax_press),
		rawptr(on_ax_value),
		rawptr(on_ax_set_value),
		rawptr(on_metal_ax_children),
		rawptr(on_metal_is_ax_element),
		rawptr(on_metal_accepts_first),
		rawptr(on_metal_mouse_down),
		rawptr(on_metal_right_mouse_down),
		rawptr(on_metal_mouse_moved),
		rawptr(on_metal_mouse_dragged),
		rawptr(on_metal_mouse_up),
		rawptr(on_metal_scroll),
		rawptr(on_metal_key_down),
		rawptr(on_metal_copy),
		rawptr(on_metal_cut),
		rawptr(on_metal_paste),
		rawptr(on_metal_select_all),
		rawptr(on_metal_insert_text_simple),
		rawptr(on_metal_insert_text),
		rawptr(on_metal_command),
		rawptr(on_metal_set_marked),
		rawptr(on_metal_unmark),
		rawptr(on_metal_has_marked),
		rawptr(on_metal_range),
		rawptr(on_metal_range),
		rawptr(on_metal_valid_attributes),
		rawptr(on_metal_attributed_substring),
		rawptr(on_metal_character_index),
		rawptr(on_metal_first_rect),
		rawptr(window_can_become_key),
	},
}

@(export)
vocal_hot_reload_get_api :: proc "c" () -> ^hot_reload.Module_API {
	return &vocal_hot_api
}
