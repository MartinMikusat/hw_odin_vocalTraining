package main

import "core:fmt"
import "core:math"
import "core:strconv"
import "core:strings"

foreign import pitch_bridge "system:System.framework"
foreign pitch_bridge {
	vt_pitch_permission_status        :: proc "c" () -> i32 ---
	vt_pitch_request_permission       :: proc "c" () -> bool ---
	vt_pitch_permission_request_active:: proc "c" () -> bool ---
	vt_pitch_capture_create           :: proc "c" () -> rawptr ---
	vt_pitch_capture_start            :: proc "c" (capture: rawptr) -> bool ---
	vt_pitch_capture_stop             :: proc "c" (capture: rawptr) ---
	vt_pitch_capture_destroy          :: proc "c" (capture: rawptr) ---
	vt_pitch_capture_read             :: proc "c" (
		capture: rawptr,
		destination: [^]f32,
		capacity: u32,
		sample_rate: ^f64,
	) -> u32 ---
	vt_pitch_capture_status           :: proc "c" (capture: rawptr) -> i32 ---
}

PITCH_ANALYSIS_RATE       :: 12000.0
PITCH_ANALYSIS_SAMPLES    :: 1024
PITCH_INPUT_SAMPLES       :: 8192
PITCH_CAPTURE_CHUNK       :: 4096
PITCH_TRACE_POINTS        :: 360
PITCH_ANALYSIS_FRAME_STEP :: uint(2)
PITCH_YIN_THRESHOLD       :: 0.15
PITCH_RMS_THRESHOLD       :: 0.008

Pitch_Permission :: enum i32 {
	Unknown,
	Denied,
	Restricted,
	Authorized,
}

Pitch_Capture_Status :: enum i32 {
	Stopped,
	Running,
	No_Input,
	Start_Failed,
}

Pitch_Range :: enum i32 {
	C3_C8,
	C2_C7,
	C1_C6,
}

Pitch_Label_Mode :: enum i32 {
	Letters,
	Solfege,
	Numbers,
}

Pitch_Settings :: struct {
	reference_hz: i32,
	range:        Pitch_Range,
	labels:       Pitch_Label_Mode,
	transpose:    i32,
	highlight:    bool,
}

Pitch_Point :: struct {
	midi:       f64,
	confidence: f64,
	voiced:     bool,
}

Pitch_Monitor_State :: struct {
	settings:           Pitch_Settings,
	permission:         Pitch_Permission,
	permission_pending: bool,
	start_after_permission: bool,
	capture:            rawptr,
	capture_status:     Pitch_Capture_Status,
	tracking:           bool,
	sample_rate:        f64,
	input:              [PITCH_INPUT_SAMPLES]f32,
	input_count:        int,
	capture_chunk:      [PITCH_CAPTURE_CHUNK]f32,
	analysis:           [PITCH_ANALYSIS_SAMPLES]f32,
	yin:                [PITCH_ANALYSIS_SAMPLES / 2]f64,
	trace:              [PITCH_TRACE_POINTS]Pitch_Point,
	trace_start:        int,
	trace_count:        int,
	current_hz:         f64,
	current_midi:       f64,
	current_cents:      f64,
	current_confidence: f64,
	voiced:             bool,
	help_open:          bool,
}

pitch_default_settings :: proc() -> Pitch_Settings {
	return {
		reference_hz = 440,
		range = .C2_C7,
		labels = .Letters,
		transpose = 0,
		highlight = true,
	}
}

pitch_settings_valid :: proc(settings: Pitch_Settings) -> bool {
	return settings.reference_hz >= 400 &&
	       settings.reference_hz <= 480 &&
	       int(settings.range) >= int(Pitch_Range.C3_C8) &&
	       int(settings.range) <= int(Pitch_Range.C1_C6) &&
	       int(settings.labels) >= int(Pitch_Label_Mode.Letters) &&
	       int(settings.labels) <= int(Pitch_Label_Mode.Numbers) &&
	       settings.transpose >= 0 &&
	       settings.transpose < 12
}

pitch_settings_encode :: proc(settings: Pitch_Settings) -> string {
	return fmt.tprintf(
		"%d|%d|%d|%d|%d",
		settings.reference_hz,
		int(settings.range),
		int(settings.labels),
		settings.transpose,
		settings.highlight ? 1 : 0,
	)
}

pitch_settings_decode :: proc(value: string) -> (Pitch_Settings, bool) {
	parts := strings.split(value, "|")
	defer delete(parts)
	if len(parts) != 5 {return {}, false}
	values: [5]int
	for part, index in parts {
		parsed, ok := strconv.parse_int(part)
		if !ok {return {}, false}
		values[index] = parsed
	}
	settings := Pitch_Settings{
		reference_hz = i32(values[0]),
		range = Pitch_Range(values[1]),
		labels = Pitch_Label_Mode(values[2]),
		transpose = i32(values[3]),
		highlight = values[4] != 0,
	}
	return settings, pitch_settings_valid(settings)
}

pitch_range_midi :: proc(value: Pitch_Range) -> (minimum, maximum: int) {
	switch value {
	case .C3_C8:
		return 48, 108
	case .C1_C6:
		return 24, 84
	case .C2_C7:
		return 36, 96
	}
	return 36, 96
}

pitch_midi_frequency :: proc(midi: f64, reference_hz: f64) -> f64 {
	return reference_hz * math.pow(2.0, (midi - 69.0) / 12.0)
}

pitch_frequency_midi :: proc(frequency, reference_hz: f64) -> f64 {
	if frequency <= 0 || reference_hz <= 0 {return 0}
	return 69.0 + 12.0 * math.log2(frequency / reference_hz)
}

pitch_note_name :: proc(
	midi: int,
	settings: Pitch_Settings,
	allocator := context.temp_allocator,
) -> string {
	display_midi := midi + int(settings.transpose)
	pitch_class := display_midi % 12
	if pitch_class < 0 {pitch_class += 12}
	octave := display_midi / 12 - 1
	if display_midi < 0 && display_midi % 12 != 0 {octave -= 1}
	letters := [12]string{"C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"}
	solfege := [12]string{"DO", "DO#", "RE", "RE#", "MI", "FA", "FA#", "SOL", "SOL#", "LA", "LA#", "TI"}
	numbers := [12]string{"1", "1#", "2", "2#", "3", "4", "4#", "5", "5#", "6", "6#", "7"}
	name := letters[pitch_class]
	switch settings.labels {
	case .Solfege:
		name = solfege[pitch_class]
	case .Numbers:
		name = numbers[pitch_class]
	case .Letters:
	}
	return fmt.aprintf("%s%d", name, octave, allocator=allocator)
}

pitch_transpose_label :: proc(index: int) -> string {
	labels := [12]string{
		"C = C",
		"C = B",
		"C = B♭ A#",
		"C = A",
		"C = A♭ G#",
		"C = G",
		"C = G♭ F#",
		"C = F",
		"C = E",
		"C = E♭ D#",
		"C = D",
		"C = D♭ C#",
	}
	if index < 0 || index >= len(labels) {return ""}
	return labels[index]
}

pitch_detect_yin :: proc(
	samples: []f32,
	sample_rate, minimum_hz, maximum_hz: f64,
	scratch: []f64,
) -> (frequency, confidence: f64, voiced: bool) {
	if len(samples) < 8 ||
	   len(scratch) < len(samples) / 2 ||
	   sample_rate <= 0 ||
	   minimum_hz <= 0 ||
	   maximum_hz <= minimum_hz {
		return
	}
	sum_square := 0.0
	for sample in samples {sum_square += f64(sample) * f64(sample)}
	rms := math.sqrt(sum_square / f64(len(samples)))
	if rms < PITCH_RMS_THRESHOLD {return}

	minimum_tau := max(2, int(math.floor(sample_rate / maximum_hz)))
	maximum_tau := min(
		len(samples) / 2 - 1,
		int(math.ceil(sample_rate / minimum_hz)),
	)
	if minimum_tau >= maximum_tau {return}

	scratch[0] = 1
	running_sum := 0.0
	for tau in 1 ..= maximum_tau {
		difference := 0.0
		for index in 0 ..< len(samples) - tau {
			delta := f64(samples[index]) - f64(samples[index + tau])
			difference += delta * delta
		}
		running_sum += difference
		scratch[tau] = running_sum > 0 ? difference * f64(tau) / running_sum : 1
	}

	best_tau := 0
	for tau in minimum_tau ..= maximum_tau {
		if scratch[tau] >= PITCH_YIN_THRESHOLD {continue}
		best_tau = tau
		for best_tau + 1 <= maximum_tau &&
		    scratch[best_tau + 1] < scratch[best_tau] {
			best_tau += 1
		}
		break
	}
	if best_tau == 0 {
		best_value := 1.0
		for tau in minimum_tau ..= maximum_tau {
			if scratch[tau] < best_value {
				best_value = scratch[tau]
				best_tau = tau
			}
		}
		if best_tau == 0 || best_value > 0.30 {return}
	}

	tau_value := f64(best_tau)
	if best_tau > 1 && best_tau < maximum_tau {
		left, center, right :=
			scratch[best_tau - 1],
			scratch[best_tau],
			scratch[best_tau + 1]
		denominator := 2.0 * (2.0 * center - right - left)
		if math.abs(denominator) > 0.000001 {
			tau_value += (right - left) / denominator
		}
	}
	frequency = sample_rate / tau_value
	confidence = clamp(1.0 - scratch[best_tau], 0.0, 1.0)
	voiced = frequency >= minimum_hz &&
	         frequency <= maximum_hz &&
	         confidence >= 0.70
	return
}

pitch_trace_clear :: proc(state: ^Pitch_Monitor_State) {
	state.trace_start = 0
	state.trace_count = 0
	state.voiced = false
	state.current_hz = 0
	state.current_midi = 0
	state.current_cents = 0
	state.current_confidence = 0
}

pitch_trace_append :: proc(state: ^Pitch_Monitor_State, point: Pitch_Point) {
	index := (state.trace_start + state.trace_count) % len(state.trace)
	if state.trace_count == len(state.trace) {
		state.trace_start = (state.trace_start + 1) % len(state.trace)
		index = (state.trace_start + state.trace_count - 1) % len(state.trace)
	} else {
		state.trace_count += 1
	}
	state.trace[index] = point
}

pitch_input_append :: proc(state: ^Pitch_Monitor_State, samples: []f32) {
	if len(samples) >= len(state.input) {
		copy(state.input[:], samples[len(samples) - len(state.input):])
		state.input_count = len(state.input)
		return
	}
	overflow := max(0, state.input_count + len(samples) - len(state.input))
	if overflow > 0 {
		copy(state.input[:state.input_count - overflow], state.input[overflow:state.input_count])
		state.input_count -= overflow
	}
	copy(state.input[state.input_count:], samples)
	state.input_count += len(samples)
}

pitch_resample_latest :: proc(state: ^Pitch_Monitor_State) -> bool {
	if state.sample_rate <= 0 {return false}
	step := state.sample_rate / PITCH_ANALYSIS_RATE
	required := int(math.ceil(step * f64(PITCH_ANALYSIS_SAMPLES - 1))) + 2
	if required > state.input_count {return false}
	start := f64(state.input_count - required)
	for index in 0 ..< PITCH_ANALYSIS_SAMPLES {
		position := start + f64(index) * step
		left := min(int(math.floor(position)), state.input_count - 2)
		fraction := position - f64(left)
		state.analysis[index] = f32(
			f64(state.input[left]) * (1 - fraction) +
			f64(state.input[left + 1]) * fraction,
		)
	}
	return true
}

pitch_analyze :: proc(state: ^Pitch_Monitor_State) {
	if !pitch_resample_latest(state) {
		state.voiced = false
		pitch_trace_append(state, Pitch_Point{})
		return
	}
	minimum_midi, maximum_midi := pitch_range_midi(state.settings.range)
	reference := f64(state.settings.reference_hz)
	minimum_hz := pitch_midi_frequency(f64(minimum_midi), reference)
	maximum_hz := pitch_midi_frequency(f64(maximum_midi), reference)
	frequency, confidence, voiced := pitch_detect_yin(
		state.analysis[:],
		PITCH_ANALYSIS_RATE,
		minimum_hz,
		maximum_hz,
		state.yin[:],
	)
	state.voiced = voiced
	state.current_confidence = confidence
	if voiced {
		state.current_hz = frequency
		state.current_midi = pitch_frequency_midi(frequency, reference)
		state.current_cents =
			(state.current_midi - math.round(state.current_midi)) * 100
	}
	pitch_trace_append(state, Pitch_Point{
		midi = state.current_midi,
		confidence = confidence,
		voiced = voiced,
	})
}

pitch_monitor_initialize :: proc(
	state: ^Pitch_Monitor_State,
	settings: Pitch_Settings,
) {
	state^ = {}
	state.settings = settings
	if !pitch_settings_valid(settings) {
		state.settings = pitch_default_settings()
	}
	state.permission = Pitch_Permission(vt_pitch_permission_status())
	state.capture_status = .Stopped
}

pitch_monitor_refresh_permission :: proc(
	state: ^Pitch_Monitor_State,
) -> bool {
	if state == nil || state.permission_pending {return false}
	permission := Pitch_Permission(vt_pitch_permission_status())
	if permission == state.permission {return false}
	state.permission = permission
	if state.tracking && permission != .Authorized {
		pitch_monitor_stop(state)
	}
	return true
}

pitch_monitor_start_capture :: proc(state: ^Pitch_Monitor_State) -> bool {
	if state.tracking {return true}
	capture := vt_pitch_capture_create()
	if capture == nil {
		state.capture_status = .Start_Failed
		return false
	}
	if !vt_pitch_capture_start(capture) {
		state.capture_status = Pitch_Capture_Status(vt_pitch_capture_status(capture))
		vt_pitch_capture_destroy(capture)
		return false
	}
	state.capture = capture
	state.capture_status = .Running
	state.tracking = true
	state.input_count = 0
	state.sample_rate = 0
	state.start_after_permission = false
	pitch_trace_clear(state)
	return true
}

pitch_monitor_stop :: proc(state: ^Pitch_Monitor_State) {
	if state.capture != nil {
		vt_pitch_capture_stop(state.capture)
		vt_pitch_capture_destroy(state.capture)
	}
	state.capture = nil
	state.tracking = false
	state.capture_status = .Stopped
	state.start_after_permission = false
	state.input_count = 0
	state.voiced = false
}

pitch_monitor_toggle :: proc(state: ^Pitch_Monitor_State) -> bool {
	if state.tracking {
		pitch_monitor_stop(state)
		return true
	}
	state.permission = Pitch_Permission(vt_pitch_permission_status())
	#partial switch state.permission {
	case .Authorized:
		return pitch_monitor_start_capture(state)
	case .Unknown:
		if vt_pitch_request_permission() {
			state.permission_pending = true
			state.start_after_permission = true
			return true
		}
		return false
	case .Denied, .Restricted:
		return false
	}
	return false
}

pitch_monitor_poll :: proc(
	state: ^Pitch_Monitor_State,
	frame_tick: uint,
) -> bool {
	changed := false
	if state.permission_pending {
		pending := vt_pitch_permission_request_active()
		if !pending {
			state.permission_pending = false
			state.permission = Pitch_Permission(vt_pitch_permission_status())
			changed = true
			if state.start_after_permission && state.permission == .Authorized {
				_ = pitch_monitor_start_capture(state)
			}
			state.start_after_permission = false
		}
	}
	if !state.tracking || state.capture == nil {return changed}
	for {
		count := int(vt_pitch_capture_read(
			state.capture,
			raw_data(state.capture_chunk[:]),
			u32(len(state.capture_chunk)),
			&state.sample_rate,
		))
		if count <= 0 {break}
		pitch_input_append(state, state.capture_chunk[:count])
		changed = true
		if count < len(state.capture_chunk) {break}
	}
	if frame_tick % PITCH_ANALYSIS_FRAME_STEP == 0 {
		pitch_analyze(state)
		changed = true
	}
	return changed
}

pitch_monitor_status_text :: proc(state: ^Pitch_Monitor_State) -> string {
	if state.permission_pending {return "REQUESTING MICROPHONE ACCESS"}
	#partial switch state.permission {
	case .Denied:
		return "MICROPHONE ACCESS DENIED"
	case .Restricted:
		return "MICROPHONE ACCESS RESTRICTED"
	case:
	}
	#partial switch state.capture_status {
	case .No_Input:
		return "NO MICROPHONE INPUT"
	case .Start_Failed:
		return "MICROPHONE START FAILED"
	case:
	}
	if !state.tracking {
		return fmt.tprintf(
			"READY / PRESS %s TO START",
			pitch_numbered_action_text(),
		)
	}
	if !state.voiced {return "LISTENING / NO STABLE PITCH"}
	return "TRACKING"
}
