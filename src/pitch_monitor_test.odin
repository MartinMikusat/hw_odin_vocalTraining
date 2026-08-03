package main

import "core:math"
import "core:strings"
import "core:testing"

pitch_test_sine :: proc(
	output: []f32,
	frequency, sample_rate: f64,
	second_harmonic := 0.0,
) {
	for index in 0 ..< len(output) {
		phase := 2.0 * math.PI * frequency * f64(index) / sample_rate
		output[index] = f32(
			0.72 * math.sin(phase) +
			second_harmonic * math.sin(phase * 2),
		)
	}
}

pitch_test_expect_frequency :: proc(
	t: ^testing.T,
	expected_frequency: f64,
) {
	samples: [PITCH_ANALYSIS_SAMPLES]f32
	scratch: [PITCH_ANALYSIS_SAMPLES / 2]f64
	pitch_test_sine(
		samples[:],
		expected_frequency,
		PITCH_ANALYSIS_RATE,
		0.18,
	)
	frequency, confidence, voiced := pitch_detect_yin(
		samples[:],
		PITCH_ANALYSIS_RATE,
		30,
		4300,
		scratch[:],
	)
	testing.expect(t, voiced)
	testing.expect(t, confidence >= 0.70)
	cents := 1200.0 * math.log2(frequency / expected_frequency)
	testing.expect(t, math.abs(cents) <= 5)
}

@(test)
pitch_yin_detects_low_middle_and_high_notes_test :: proc(t: ^testing.T) {
	pitch_test_expect_frequency(t, 110.0)
	pitch_test_expect_frequency(t, 440.0)
	pitch_test_expect_frequency(t, 1046.502261)
}

@(test)
pitch_yin_rejects_silence_and_weak_input_test :: proc(t: ^testing.T) {
	samples: [PITCH_ANALYSIS_SAMPLES]f32
	scratch: [PITCH_ANALYSIS_SAMPLES / 2]f64
	_, _, voiced := pitch_detect_yin(
		samples[:],
		PITCH_ANALYSIS_RATE,
		30,
		4300,
		scratch[:],
	)
	testing.expect(t, !voiced)
	for index in 0 ..< len(samples) {
		samples[index] = f32(index % 2) * 0.0001
	}
	_, _, voiced = pitch_detect_yin(
		samples[:],
		PITCH_ANALYSIS_RATE,
		30,
		4300,
		scratch[:],
	)
	testing.expect(t, !voiced)
}

@(test)
pitch_settings_round_trip_and_reject_invalid_values_test :: proc(t: ^testing.T) {
	settings := Pitch_Settings{
		reference_hz = 442,
		octaves = 4,
		labels = .Solfege,
		transpose = 7,
		highlight = false,
	}
	encoded := pitch_settings_encode(settings)
	decoded, valid := pitch_settings_decode(encoded)
	testing.expect(t, valid)
	testing.expect_value(t, decoded, settings)
	_, valid = pitch_settings_decode("399|1|0|0|1")
	testing.expect(t, !valid)
	_, valid = pitch_settings_decode("440|7|0|0|1")
	testing.expect(t, !valid)
}

@(test)
pitch_labels_apply_transposition_without_changing_frequency_test :: proc(
	t: ^testing.T,
) {
	settings := pitch_default_settings()
	testing.expect_value(t, pitch_note_name(69, settings), "A4")
	settings.transpose = 1
	testing.expect_value(t, pitch_note_name(71, settings), "C5")
	settings.labels = .Solfege
	testing.expect_value(t, pitch_note_name(71, settings), "DO5")
	settings.labels = .Numbers
	testing.expect_value(t, pitch_note_name(71, settings), "15")
	testing.expect(
		t,
		math.abs(pitch_midi_frequency(69, 440) - 440) < 0.0001,
	)
}

@(test)
pitch_trace_keeps_only_the_newest_twelve_seconds_test :: proc(t: ^testing.T) {
	state: Pitch_Monitor_State
	for index in 0 ..< PITCH_TRACE_POINTS + 12 {
		pitch_trace_append(&state, Pitch_Point{midi = f64(index), voiced = true})
	}
	testing.expect_value(t, state.trace_count, PITCH_TRACE_POINTS)
	first := state.trace[state.trace_start]
	testing.expect_value(t, first.midi, 12.0)
}

@(test)
pitch_play_layout_uses_forty_sixty_partition_test :: proc(
	t: ^testing.T,
) {
	old_width, old_height, old_mode, old_workflow := ui.width, ui.height, ui.mode, ui.workflow
	defer {
		ui.width, ui.height, ui.mode, ui.workflow = old_width, old_height, old_mode, old_workflow
	}
	ui.width, ui.height, ui.mode, ui.workflow = 1100, 720, .Play, .Vocal
	_, _, _, _, player, _, _, clip, _, pitch, _ := layout_rects()
	available := ui.width - 36 - 20
	testing.expect(t, math.abs(clip.w - available * 0.40) < 0.001)
	testing.expect(t, math.abs(player.w - available * 0.40) < 0.001)
	testing.expect(t, math.abs(pitch.w - available * 0.60) < 0.001)
	testing.expect(t, clip.x == player.x)
	testing.expect(t, clip.y < player.y)
	testing.expect(t, clip.y + clip.h < player.y)
	testing.expect(t, clip.x + clip.w < pitch.x)
	testing.expect(t, pitch.x + pitch.w <= ui.width - 18)
}

@(test)
pitch_settings_round_trip_through_application_preferences_test :: proc(
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
	settings := Pitch_Settings{
		reference_hz = 432,
		octaves = 5,
		labels = .Numbers,
		transpose = 11,
		highlight = false,
	}
	testing.expect(t, database_pitch_settings_save(database, settings))
	testing.expect_value(t, database_pitch_settings_load(database), settings)
}

@(test)
pitch_plot_window_covers_the_configured_octave_span_test :: proc(
	t: ^testing.T,
) {
	state: Pitch_Monitor_State
	state.settings = pitch_default_settings()
	state.settings.octaves = 3
	state.window_center_midi = 60
	minimum, maximum := pitch_plot_window_midi(&state)
	testing.expect_value(t, maximum-minimum, 36)
	testing.expect(t, minimum <= 60 && maximum >= 60)
	state.settings.octaves = 6
	minimum, maximum = pitch_plot_window_midi(&state)
	testing.expect_value(t, maximum-minimum, 72)
	state.settings.octaves = 1
	minimum, maximum = pitch_plot_window_midi(&state)
	testing.expect_value(t, maximum-minimum, 12)
}

@(test)
pitch_plot_window_stays_inside_the_analysis_band_test :: proc(
	t: ^testing.T,
) {
	state: Pitch_Monitor_State
	state.settings = pitch_default_settings()
	state.settings.octaves = 6
	state.window_center_midi = PITCH_ANALYSIS_MIN_MIDI
	minimum, maximum := pitch_plot_window_midi(&state)
	testing.expect(t, minimum >= PITCH_ANALYSIS_MIN_MIDI)
	testing.expect(t, maximum <= PITCH_ANALYSIS_MAX_MIDI)
	state.window_center_midi = PITCH_ANALYSIS_MAX_MIDI
	minimum, maximum = pitch_plot_window_midi(&state)
	testing.expect(t, minimum >= PITCH_ANALYSIS_MIN_MIDI)
	testing.expect(t, maximum <= PITCH_ANALYSIS_MAX_MIDI)
}

@(test)
pitch_window_follow_recenters_on_voiced_pitch_and_holds_on_silence_test :: proc(
	t: ^testing.T,
) {
	state: Pitch_Monitor_State
	state.settings = pitch_default_settings()
	state.window_center_midi = PITCH_DEFAULT_WINDOW_CENTER_MIDI
	state.current_midi = 72
	state.voiced = true
	pitch_window_follow(&state)
	testing.expect(t, math.abs(state.window_center_midi - 72) < 0.001)
	state.voiced = false
	state.current_midi = 60
	pitch_window_follow(&state)
	testing.expect(t, math.abs(state.window_center_midi - 72) < 0.001)
}

@(test)
pitch_window_follow_clamps_the_center_into_the_analysis_band_test :: proc(
	t: ^testing.T,
) {
	state: Pitch_Monitor_State
	state.settings = pitch_default_settings()
	state.settings.octaves = 6
	state.current_midi = PITCH_ANALYSIS_MIN_MIDI
	state.voiced = true
	pitch_window_follow(&state)
	minimum, maximum := pitch_plot_window_midi(&state)
	testing.expect(t, minimum >= PITCH_ANALYSIS_MIN_MIDI)
	testing.expect(t, maximum <= PITCH_ANALYSIS_MAX_MIDI)
	state.current_midi = PITCH_ANALYSIS_MAX_MIDI
	state.voiced = true
	pitch_window_follow(&state)
	minimum, maximum = pitch_plot_window_midi(&state)
	testing.expect(t, minimum >= PITCH_ANALYSIS_MIN_MIDI)
	testing.expect(t, maximum <= PITCH_ANALYSIS_MAX_MIDI)
}
