package main

import "base:runtime"

video_frame_retry_active :: proc(
	pending: bool,
	frame_tick,
	deadline: uint,
) -> bool {
	return pending && frame_tick < deadline
}

clear_video_frame_refresh :: proc() {
	if ui.video_frame_warmup_active && state.player != nil {
		msg_void(state.player, sel_registerName("pause"))
	}
	ui.video_frame_pending = false
	ui.video_frame_deadline = 0
	ui.video_frame_warmup_pending = false
	ui.video_frame_warmup_active = false
	ui.video_frame_warmup_due_tick = 0
}

request_video_frame_refresh :: proc() {
	if ui.video_output == nil {
		clear_video_frame_refresh()
		return
	}
	ui.video_frame_pending = true
	ui.video_frame_deadline = ui.frame_tick + VIDEO_FRAME_RETRY_TICKS
	ui.needs_redraw = true
}

request_paused_video_frame_warmup :: proc() {
	if state.player == nil {return}
	ui.video_frame_warmup_pending = true
	ui.video_frame_warmup_due_tick = ui.frame_tick + 1
}

advance_paused_video_frame_warmup :: proc() {
	if !ui.video_frame_warmup_pending ||
	   ui.video_frame_warmup_active ||
	   ui.frame_tick < ui.video_frame_warmup_due_tick ||
	   state.player == nil {
		return
	}
	if msg_f32(state.player, sel_registerName("rate")) != 0 {
		ui.video_frame_warmup_pending = false
		return
	}
	ui.video_frame_warmup_active = true
	msg_void_f32(state.player, sel_registerName("setRate:"), 1)
}

cancel_paused_video_frame_warmup :: proc() {
	ui.video_frame_warmup_pending = false
	ui.video_frame_warmup_active = false
	ui.video_frame_warmup_due_tick = 0
}

playback_state_active :: proc(rate: f32, warmup_active: bool) -> bool {
	return rate > 0 && !warmup_active
}

playback_actively_playing :: proc() -> bool {
	if state.player == nil {return false}
	return playback_state_active(
		msg_f32(state.player, sel_registerName("rate")),
		ui.video_frame_warmup_active,
	)
}

complete_video_frame_refresh :: proc() {
	clear_video_frame_refresh()
}

metal_player_clear_texture :: proc() {
	clear_video_frame_refresh()
	if ui.last_video_texture != nil {
		msg_void(ui.last_video_texture, sel_registerName("release"))
		ui.last_video_texture = nil
		ui.last_video_width, ui.last_video_height = 0, 0
	}
}

metal_audio_pause :: proc() {
	if ui.audio_player != nil {msg_void(ui.audio_player, sel_registerName("stop"))}
	if ui.audio_engine != nil {msg_void(ui.audio_engine, sel_registerName("stop"))}
}

metal_audio_engine_running :: proc() -> bool {
	return ui.audio_engine != nil &&
	       msg_bool(ui.audio_engine, sel_registerName("isRunning"))
}

metal_audio_play :: proc() -> bool {
	if ui.audio_engine == nil && ui.audio_player == nil && ui.audio_file == nil {
		return true
	}
	if ui.audio_engine == nil || ui.audio_player == nil {return false}
	if !metal_audio_engine_running() {
		error: Id
		msg_void(ui.audio_engine, sel_registerName("prepare"))
		if !msg_bool_error(
			   ui.audio_engine,
			   sel_registerName("startAndReturnError:"),
			   &error,
		   ) {
			return false
		}
	}
	msg_void(ui.audio_player, sel_registerName("play"))
	return true
}

audio_source_seconds :: proc(start_frame, rendered_frames: i64, sample_rate: f64) -> (f64, bool) {
	if start_frame < 0 || rendered_frames < 0 || sample_rate <= 0 {return 0, false}
	return f64(start_frame + rendered_frames) / sample_rate, true
}

metal_audio_current_seconds :: proc() -> (f64, bool) {
	if ui.audio_player == nil || ui.audio_file == nil {return 0, false}
	render_time := msg_id(ui.audio_player, sel_registerName("lastRenderTime"))
	if render_time == nil {return 0, false}
	player_time := msg_id_id(ui.audio_player, sel_registerName("playerTimeForNodeTime:"), render_time)
	if player_time == nil {return 0, false}
	format := msg_id(ui.audio_file, sel_registerName("processingFormat"))
	return audio_source_seconds(
		ui.audio_start_frame,
		msg_i64(player_time, sel_registerName("sampleTime")),
		msg_f64(format, sel_registerName("sampleRate")),
	)
}

audio_frame_range :: proc(seconds, sample_rate: f64, length: i64) -> (start: i64, count: u32) {
	if sample_rate <= 0 || length <= 0 {return 0, 0}
	start = min(max(i64(seconds * sample_rate), 0), length)
	remaining := length - start
	if remaining <= 0 {return start, 0}
	return start, u32(min(remaining, i64(0xffffffff)))
}

metal_audio_seek :: proc(seconds: f64, resume: bool) {
	if ui.audio_player == nil || ui.audio_file == nil {return}
	msg_void(ui.audio_player, sel_registerName("stop"))
	format := msg_id(ui.audio_file, sel_registerName("processingFormat"))
	sample_rate := msg_f64(format, sel_registerName("sampleRate"))
	length := msg_i64(ui.audio_file, sel_registerName("length"))
	start, frame_count := audio_frame_range(seconds, sample_rate, length)
	if frame_count == 0 {return}
	ui.audio_start_frame = start
	msg_void_id_i64_u32_id_id(
		ui.audio_player,
		sel_registerName("scheduleSegment:startingFrame:frameCount:atTime:completionHandler:"),
		ui.audio_file,
		start,
		frame_count,
		nil,
		nil,
	)
	if resume {_ = metal_audio_play()}
}

metal_audio_observe_configuration :: proc(engine: Id) {
	if engine == nil || state.delegate_target == nil {return}
	center := msg_id(objc_getClass("NSNotificationCenter"), sel_registerName("defaultCenter"))
	msg_void_id_sel_id_id(
		center,
		sel_registerName("addObserver:selector:name:object:"),
		state.delegate_target,
		sel_registerName("audioEngineConfigurationChanged:"),
		AVAudioEngineConfigurationChangeNotification,
		engine,
	)
}

metal_audio_stop_observing_configuration :: proc(engine: Id) {
	if engine == nil || state.delegate_target == nil {return}
	center := msg_id(objc_getClass("NSNotificationCenter"), sel_registerName("defaultCenter"))
	msg_void_id_id_id(
		center,
		sel_registerName("removeObserver:name:object:"),
		state.delegate_target,
		AVAudioEngineConfigurationChangeNotification,
		engine,
	)
}

metal_audio_release :: proc(engine, player, pitch, file: Id) {
	metal_audio_stop_observing_configuration(engine)
	if player != nil {msg_void(player, sel_registerName("stop"))}
	if engine != nil {msg_void(engine, sel_registerName("stop"))}
	if file != nil {msg_void(file, sel_registerName("release"))}
	if pitch != nil {msg_void(pitch, sel_registerName("release"))}
	if player != nil {msg_void(player, sel_registerName("release"))}
	if engine != nil {msg_void(engine, sel_registerName("release"))}
}

metal_audio_load :: proc(url: Id) -> (engine, player, pitch, file: Id, ok: bool) {
	error: Id
	file = msg_id_id_error_2(
		msg_id(objc_getClass("AVAudioFile"), sel_registerName("alloc")),
		sel_registerName("initForReading:error:"),
		url,
		&error,
	)
	if file == nil {return nil, nil, nil, nil, false}
	engine = msg_id(objc_getClass("AVAudioEngine"), sel_registerName("new"))
	player = msg_id(objc_getClass("AVAudioPlayerNode"), sel_registerName("new"))
	pitch = msg_id(objc_getClass("AVAudioUnitTimePitch"), sel_registerName("new"))
	if engine == nil || player == nil || pitch == nil {
		metal_audio_release(engine, player, pitch, file)
		return nil, nil, nil, nil, false
	}
	msg_void_id(engine, sel_registerName("attachNode:"), player)
	msg_void_id(engine, sel_registerName("attachNode:"), pitch)
	format := msg_id(file, sel_registerName("processingFormat"))
	mixer := msg_id(engine, sel_registerName("mainMixerNode"))
	msg_void_id_id_id(engine, sel_registerName("connect:to:format:"), player, pitch, format)
	msg_void_id_id_id(engine, sel_registerName("connect:to:format:"), pitch, mixer, format)
	msg_void_f32(player, sel_registerName("setVolume:"), player_volume_gain(ui.player_volume))
	msg_void_f32(pitch, sel_registerName("setRate:"), ui.playback_rate)
	metal_audio_observe_configuration(engine)
	return engine, player, pitch, file, true
}

metal_audio_recover_configuration :: proc(engine: Id) -> bool {
	if engine == nil || engine != ui.audio_engine || state.player == nil {return false}
	resume := msg_f32(state.player, sel_registerName("rate")) > 0
	msg_void(state.player, sel_registerName("pause"))
	seconds, has_seconds := current_seconds()
	if !has_seconds {return false}
	seek_video_seconds(seconds)
	metal_audio_seek(seconds, false)
	if resume {
		if !metal_audio_play() {return false}
		msg_void_f32(state.player, sel_registerName("setRate:"), ui.playback_rate)
	}
	ui.needs_redraw = true
	return true
}

on_audio_engine_configuration_changed :: proc "c" (self: Id, command: Sel, notification: Id) {
	context = runtime.default_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	engine := msg_id(notification, sel_registerName("object"))
	if engine == nil {return}
	msg_void_sel_id_b(
		self,
		sel_registerName("performSelectorOnMainThread:withObject:waitUntilDone:"),
		sel_registerName("recoverAudioEngineConfiguration:"),
		engine,
		false,
	)
}

on_audio_engine_recover_configuration :: proc "c" (self: Id, command: Sel, engine: Id) {
	context = runtime.default_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	if engine != ui.audio_engine {return}
	if metal_audio_recover_configuration(engine) {return}
	if state.player != nil {msg_void(state.player, sel_registerName("pause"))}
	set_error_status("Audio output changed, but playback could not reconnect")
}

metal_player_observe_completion :: proc(item: Id) {
	if item == nil || state.delegate_target == nil {return}
	center := msg_id(objc_getClass("NSNotificationCenter"), sel_registerName("defaultCenter"))
	msg_void_id_sel_id_id(
		center,
		sel_registerName("addObserver:selector:name:object:"),
		state.delegate_target,
		sel_registerName("playerItemDidReachEnd:"),
		AVPlayerItemDidPlayToEndTimeNotification,
		item,
	)
}

metal_player_stop_observing_completion :: proc(item: Id) {
	if item == nil || state.delegate_target == nil {return}
	center := msg_id(objc_getClass("NSNotificationCenter"), sel_registerName("defaultCenter"))
	msg_void_id_id_id(
		center,
		sel_registerName("removeObserver:name:object:"),
		state.delegate_target,
		AVPlayerItemDidPlayToEndTimeNotification,
		item,
	)
}

on_player_item_did_reach_end :: proc "c" (
	self: Id,
	command: Sel,
	notification: Id,
) {
	context = runtime.default_context()
	item := msg_id(notification, sel_registerName("object"))
	if item == nil || item != ui.player_item || state.player == nil {return}
	ui.playback_completion_pending = true
	ui.needs_redraw = true
}

on_application_did_become_active :: proc "c" (
	self: Id,
	command: Sel,
	notification: Id,
) {
	context = runtime.default_context()
	if allow_hidden_window_reveal &&
	   !ui_automation_enabled() &&
	   state.window != nil &&
	   !msg_bool(state.window, sel_registerName("isVisible")) {
		msg_void_id(
			state.window,
			sel_registerName("makeKeyAndOrderFront:"),
			nil,
		)
	}
	if pitch_monitor_refresh_permission(&ui.pitch) {
		ui.needs_redraw = true
	}
}

on_application_should_handle_reopen :: proc "c" (
	self: Id,
	command: Sel,
	app: Id,
	has_visible_windows: bool,
) -> bool {
	context = runtime.default_context()
	if ui_automation_enabled() {return false}
	if !has_visible_windows && state.window != nil {
		msg_void_id(
			state.window,
			sel_registerName("makeKeyAndOrderFront:"),
			nil,
		)
	}
	return true
}

on_application_did_change_screen_parameters :: proc "c" (
	self: Id,
	command: Sel,
	notification: Id,
) {
	context = runtime.default_context()
	reapply_playback_fullscreen_frame()
}

metal_player_clear :: proc() {
	if ui.playback_fullscreen_active {
		_ = set_playback_fullscreen(false)
	}
	set_source_playback_active(false)
	cancel_dance_count_in()
	ui.source_scrubbing = false
	ui.source_hint_menu_open = false
	metal_player_clear_texture()
	player := state.player
	item := ui.player_item
	output := ui.video_output
	audio_engine, audio_player := ui.audio_engine, ui.audio_player
	audio_pitch, audio_file := ui.audio_pitch, ui.audio_file
	state.player = nil
	ui.player_item = nil
	ui.playback_completion_pending = false
	ui.video_output = nil
	ui.audio_engine, ui.audio_player = nil, nil
	ui.audio_pitch, ui.audio_file = nil, nil
	ui.audio_start_frame = 0
	ui.player_duration = 0
	metal_player_stop_observing_completion(item)
	if player != nil {
		msg_void(player, sel_registerName("pause"))
		msg_void(player, sel_registerName("release"))
	}
	if output != nil {
		msg_void(output, sel_registerName("release"))
	}
	metal_audio_release(audio_engine, audio_player, audio_pitch, audio_file)
}

metal_player_load :: proc(path: string, has_audio := true) -> bool {
	media_setup_started_ms := ui_automation_media_setup_begin()
	defer ui_automation_media_setup_finish(media_setup_started_ms)
	url := msg_id_id(objc_getClass("NSURL"), sel_registerName("fileURLWithPath:"), nsstring(path))
	if url == nil {return false}
	item := msg_id_id(objc_getClass("AVPlayerItem"), sel_registerName("playerItemWithURL:"), url)
	if item == nil {return false}
	pixel_type := msg_id_uint(
		objc_getClass("NSNumber"),
		sel_registerName("numberWithUnsignedInt:"),
		0x42475241,
	)
	settings := msg_id_id_id(
		objc_getClass("NSDictionary"),
		sel_registerName("dictionaryWithObject:forKey:"),
		pixel_type,
		nsstring("PixelFormatType"),
	)
	output := msg_id_id(
		msg_id(objc_getClass("AVPlayerItemVideoOutput"), sel_registerName("alloc")),
		sel_registerName("initWithPixelBufferAttributes:"),
		settings,
	)
	if output == nil {return false}
	msg_void_id(item, sel_registerName("addOutput:"), output)
	player := msg_id_id(
		msg_id(objc_getClass("AVPlayer"), sel_registerName("alloc")),
		sel_registerName("initWithPlayerItem:"),
		item,
	)
	if player == nil {
		msg_void(output, sel_registerName("release"))
		return false
	}
	msg_void_bool(player, sel_registerName("setMuted:"), true)
	audio_engine, audio_player, audio_pitch, audio_file: Id
	if has_audio {
		audio_ok: bool
		audio_engine, audio_player, audio_pitch, audio_file, audio_ok = metal_audio_load(url)
		if !audio_ok {
			msg_void(player, sel_registerName("release"))
			msg_void(output, sel_registerName("release"))
			return false
		}
	}

	old_player := state.player
	old_item := ui.player_item
	old_output := ui.video_output
	old_audio_engine, old_audio_player := ui.audio_engine, ui.audio_player
	old_audio_pitch, old_audio_file := ui.audio_pitch, ui.audio_file
	state.player = player
	ui.player_item = item
	ui.playback_completion_pending = false
	ui.video_output = output
	ui.audio_engine, ui.audio_player = audio_engine, audio_player
	ui.audio_pitch, ui.audio_file = audio_pitch, audio_file
	metal_player_clear_texture()
	metal_player_stop_observing_completion(old_item)
	metal_player_observe_completion(item)
	if old_player != nil {
		msg_void(old_player, sel_registerName("pause"))
		msg_void(old_player, sel_registerName("release"))
	}
	if old_output != nil {
		msg_void(old_output, sel_registerName("release"))
	}
	metal_audio_release(old_audio_engine, old_audio_player, old_audio_pitch, old_audio_file)
	request_video_frame_refresh()
	return true
}
