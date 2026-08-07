package main

import "core:encoding/json"
import "core:fmt"
import "core:math"
import os "core:os/old"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:time"
import "base:runtime"
import framework_diagnostics "ui_framework:diagnostics"

foreign import perf_bridge "system:System.framework"

when ODIN_DEBUG {
	Perf_Zone :: enum u16 {
		Frame_Update,
		Playback_Sync,
		Transcript_Sync,
		Scroll_Normalize,
		Drawable_Wait,
		Build_Controls,
		Build_Geometry,
		Waveform_Geometry,
		Ordered_Frame,
		Text_Flush,
		Video_Texture,
		Metal_Encode,
		Command_Commit,
	}

	Perf_Counter :: enum u16 {
		Controls,
		Solid_Vertices,
		Draw_Commands,
		Waveform_Columns,
		Waveform_Peaks,
		Transcript_Rows,
		Frame_Arena_Bytes,
		Seek_Count,
		Seek_CPU_NS,
		Drag_CPU_NS,
		Render_Reasons,
	}

	Perf_Trace_Args :: struct {value: i64 `json:"value"`}
	Perf_Trace_Event :: struct {
		name: string,
		category: string `json:"cat"`,
		phase: string `json:"ph"`,
		timestamp_us: f64 `json:"ts"`,
		duration_us: f64 `json:"dur,omitempty"`,
		process: int `json:"pid"`,
		thread: int `json:"tid"`,
		args: Perf_Trace_Args `json:"args,omitempty"`,
	}
	Perf_Trace_File :: struct {
		schema_version: int,
		monotonic_base_ns: i64,
		trace_events: []Perf_Trace_Event `json:"traceEvents"`,
	}
	Perf_Percentiles :: struct {p50_ms, p95_ms, p99_ms, worst_ms: f64}
	Perf_Summary :: struct {
		schema_version: int,
		captured_at: string,
		started_monotonic_ns: i64,
		ended_monotonic_ns: i64,
		frame_count: int,
		frame_cpu: Perf_Percentiles,
		callback_gap: Perf_Percentiles,
		gpu: Perf_Percentiles,
		span_overflows: int,
		counter_overflows: int,
	}
	Perf_Graph_Sample :: struct {
		sequence: u64,
		gap_ms: f64,
		cpu_ms: f64,
		gpu_ms: f64,
	}

	perf_recorder: framework_diagnostics.Performance_Recorder
	perf_sequence: u64
	perf_pending_seek_count: i64
	perf_pending_seek_ns: i64
	perf_pending_drag_ns: i64
	perf_waveform_columns: i64
	perf_waveform_peaks: i64
	perf_transcript_rows: i64
	perf_last_capture_path: string
	perf_selected_sequence: u64

	perf_zone_name :: proc(zone: Perf_Zone) -> string {
		switch zone {
		case .Frame_Update: return "frame update"
		case .Playback_Sync: return "playback sync"
		case .Transcript_Sync: return "transcript sync"
		case .Scroll_Normalize: return "scroll normalize"
		case .Drawable_Wait: return "drawable wait"
		case .Build_Controls: return "build controls"
		case .Build_Geometry: return "build geometry"
		case .Waveform_Geometry: return "waveform geometry"
		case .Ordered_Frame: return "ordered frame"
		case .Text_Flush: return "text flush"
		case .Video_Texture: return "video texture"
		case .Metal_Encode: return "metal encode"
		case .Command_Commit: return "command commit"
		}
		return "unknown"
	}

	perf_counter_name :: proc(counter: Perf_Counter) -> string {
		switch counter {
		case .Controls: return "controls"
		case .Solid_Vertices: return "solid vertices"
		case .Draw_Commands: return "draw commands"
		case .Waveform_Columns: return "waveform columns"
		case .Waveform_Peaks: return "waveform peaks"
		case .Transcript_Rows: return "transcript rows"
		case .Frame_Arena_Bytes: return "frame arena bytes"
		case .Seek_Count: return "seek count"
		case .Seek_CPU_NS: return "seek cpu ns"
		case .Drag_CPU_NS: return "drag cpu ns"
		case .Render_Reasons: return "render reasons"
		}
		return "unknown"
	}

	perf_initialize :: proc() -> bool {
		return framework_diagnostics.performance_recorder_init(&perf_recorder)
	}

	perf_shutdown :: proc() {
		delete(perf_last_capture_path)
		framework_diagnostics.performance_recorder_destroy(&perf_recorder)
	}

	perf_frame_begin :: proc(render_reasons: i64) {
		perf_sequence = framework_diagnostics.performance_frame_begin(&perf_recorder)
		framework_diagnostics.performance_counter_set(
			&perf_recorder, perf_sequence,
			framework_diagnostics.Performance_Counter_ID(Perf_Counter.Render_Reasons),
			render_reasons,
		)
		perf_counter(.Seek_Count, perf_pending_seek_count)
		perf_counter(.Seek_CPU_NS, perf_pending_seek_ns)
		perf_counter(.Drag_CPU_NS, perf_pending_drag_ns)
		perf_pending_seek_count = 0
		perf_pending_seek_ns = 0
		perf_pending_drag_ns = 0
		perf_waveform_columns = 0
		perf_waveform_peaks = 0
		perf_transcript_rows = 0
	}

	perf_frame_end :: proc() {
		perf_counter(.Waveform_Columns, perf_waveform_columns)
		perf_counter(.Waveform_Peaks, perf_waveform_peaks)
		perf_counter(.Transcript_Rows, perf_transcript_rows)
		perf_counter(.Frame_Arena_Bytes, i64(memory.frame.total_used))
		framework_diagnostics.performance_frame_end(&perf_recorder, perf_sequence)
		perf_sequence = 0
	}

	perf_counter :: proc(counter: Perf_Counter, value: i64) {
		framework_diagnostics.performance_counter_set(
			&perf_recorder, perf_sequence,
			framework_diagnostics.Performance_Counter_ID(counter), value,
		)
	}

	perf_now :: proc() -> i64 {
		return framework_diagnostics.performance_now_ns()
	}

	perf_zone_started :: proc(zone: Perf_Zone) -> i64 {
		if perf_sequence != 0 {
			name := perf_zone_name(zone)
			hw_video_clips_perf_signpost_begin(
				(perf_sequence<<8)|u64(zone)+1,
				raw_data(name),
				len(name),
			)
		}
		return perf_now()
	}

	perf_zone_record :: proc(zone: Perf_Zone, start_ns: i64) {
		end_ns := framework_diagnostics.performance_now_ns()
		framework_diagnostics.performance_zone_record(
			&perf_recorder,
			perf_sequence,
			framework_diagnostics.Performance_Zone_ID(zone),
			start_ns,
			end_ns,
		)
		if perf_sequence != 0 {
			hw_video_clips_perf_signpost_end((perf_sequence<<8)|u64(zone)+1)
		}
	}

	perf_drag_end :: proc(start_ns: i64) {
		perf_pending_drag_ns += perf_now()-start_ns
	}

	perf_gpu_completed :: proc "c" (
		sequence: u64,
		scheduled_ns, completed_ns, gpu_duration_ns: i64,
	) {
		context = runtime.default_context()
		framework_diagnostics.performance_gpu_complete(
			&perf_recorder,
			{
				sequence = sequence,
				scheduled_ns = scheduled_ns,
				completed_ns = completed_ns,
				gpu_started_ns = max(scheduled_ns, completed_ns-gpu_duration_ns),
				gpu_ended_ns = completed_ns,
			},
		)
	}

	perf_track_command_buffer :: proc(command_buffer: Id) {
		if command_buffer == nil || perf_sequence == 0 {return}
		hw_video_clips_perf_track_command_buffer(
			command_buffer,
			perf_sequence,
			perf_gpu_completed,
		)
	}

	perf_percentiles :: proc(values: []f64) -> Perf_Percentiles {
		if len(values) == 0 {return {}}
		slice.sort(values)
		p50_index := clamp(int(math.ceil_f64(0.50*f64(len(values))))-1, 0, len(values)-1)
		p95_index := clamp(int(math.ceil_f64(0.95*f64(len(values))))-1, 0, len(values)-1)
		p99_index := clamp(int(math.ceil_f64(0.99*f64(len(values))))-1, 0, len(values)-1)
		return {
			p50_ms = values[p50_index],
			p95_ms = values[p95_index],
			p99_ms = values[p99_index],
			worst_ms = values[len(values)-1],
		}
	}

	perf_write_json :: proc(path: string, value: $T) -> bool {
		bytes, marshal_error := json.marshal(value, {pretty=true, use_spaces=true, spaces=2})
		if marshal_error != nil {return false}
		defer delete(bytes)
		return os.write_entire_file(path, bytes)
	}

	perf_save_recent :: proc() -> (string, bool) {
		frames := framework_diagnostics.performance_recent_frames(
			&perf_recorder,
			10_000_000_000,
		)
		defer delete(frames)
		if len(frames) == 0 {return "", false}
		root := fmt.tprintf("%s/performance-captures", app_support_dir())
		path := fmt.tprintf("%s/%d", root, time.time_to_unix_nano(time.now()))
		os.make_directory(app_support_dir())
		os.make_directory(root)
		os.make_directory(path)

		frame_values := make([dynamic]f64, 0, len(frames))
		gap_values := make([dynamic]f64, 0, len(frames))
		gpu_values := make([dynamic]f64, 0, len(frames))
		defer delete(frame_values)
		defer delete(gap_values)
		defer delete(gpu_values)
		events := make([dynamic]Perf_Trace_Event, 0, len(frames)*12)
		span_overflows, counter_overflows := 0, 0
		base_ns := frames[0].started_ns
		for &frame in frames {
			if frame.ended_ns > frame.started_ns {
				append(&frame_values, f64(frame.ended_ns-frame.started_ns)/1e6)
			}
			if frame.callback_gap_ns > 0 {append(&gap_values, f64(frame.callback_gap_ns)/1e6)}
			if frame.gpu_ended_ns > frame.gpu_started_ns {
				append(&gpu_values, f64(frame.gpu_ended_ns-frame.gpu_started_ns)/1e6)
				append(&events, Perf_Trace_Event{
					name = "GPU frame", category = "gpu", phase = "X",
					timestamp_us = f64(frame.gpu_started_ns-base_ns)/1e3,
					duration_us = f64(frame.gpu_ended_ns-frame.gpu_started_ns)/1e3,
					process = 1, thread = 2,
				})
			}
			if frame.span_overflow {span_overflows += 1}
			if frame.counter_overflow {counter_overflows += 1}
			for span in frame.spans[0:frame.span_count] {
				if span.end_ns <= span.start_ns {continue}
				append(&events, Perf_Trace_Event{
					name = perf_zone_name(Perf_Zone(span.zone)),
					category = "cpu", phase = "X",
					timestamp_us = f64(span.start_ns-base_ns)/1e3,
					duration_us = f64(span.end_ns-span.start_ns)/1e3,
					process = 1, thread = 1,
				})
			}
			for counter in frame.counters[0:frame.counter_count] {
				append(&events, Perf_Trace_Event{
					name = perf_counter_name(Perf_Counter(counter.id)),
					category = "counter", phase = "C",
					timestamp_us = f64(frame.started_ns-base_ns)/1e3,
					process = 1, thread = 1,
					args = {value = counter.value},
				})
			}
		}
		summary := Perf_Summary{
			schema_version = 1,
			captured_at = fmt.tprintf("%v", time.now()),
			started_monotonic_ns = frames[0].started_ns,
			ended_monotonic_ns = max(
				frames[len(frames)-1].ended_ns,
				framework_diagnostics.performance_now_ns(),
			),
			frame_count = len(frames),
			frame_cpu = perf_percentiles(frame_values[:]),
			callback_gap = perf_percentiles(gap_values[:]),
			gpu = perf_percentiles(gpu_values[:]),
			span_overflows = span_overflows,
			counter_overflows = counter_overflows,
		}
		ok := perf_write_json(fmt.tprintf("%s/summary.json", path), summary) &&
		      perf_write_json(
				fmt.tprintf("%s/trace.json", path),
				Perf_Trace_File{
					schema_version = 1,
					monotonic_base_ns = base_ns,
					trace_events = events[:],
				},
		      )
		delete(events)
		if !ok {return path, false}
		delete(perf_last_capture_path)
		perf_last_capture_path = strings.clone(path)
		return path, true
	}

	perf_graph_samples :: proc(samples: []Perf_Graph_Sample) -> f64 {
		if len(samples) == 0 {return 0}
		for &sample in samples {sample = {}}
		frames := framework_diagnostics.performance_recent_frames(
			&perf_recorder,
			10_000_000_000,
			context.temp_allocator,
		)
		if len(frames) == 0 {return 0}
		newest_ns := frames[len(frames)-1].started_ns
		worst := 0.0
		for &frame in frames {
			age_ns := newest_ns-frame.started_ns
			ratio := 1-clamp(f64(age_ns)/10_000_000_000.0, 0, 1)
			index := clamp(int(ratio*f64(len(samples))), 0, len(samples)-1)
			gap_ms := f64(frame.callback_gap_ns)/1e6
			cpu_ms := f64(max(i64(0), frame.ended_ns-frame.started_ns))/1e6
			gpu_ms := f64(max(i64(0), frame.gpu_ended_ns-frame.gpu_started_ns))/1e6
			if gap_ms >= samples[index].gap_ms {
				samples[index] = {
					sequence = frame.sequence,
					gap_ms = gap_ms,
					cpu_ms = cpu_ms,
					gpu_ms = gpu_ms,
				}
			}
			worst = max(worst, max(gap_ms, cpu_ms+gpu_ms))
		}
		return worst
	}

	perf_select_graph_sample :: proc(sample: Perf_Graph_Sample) {
		if sample.sequence != 0 {perf_selected_sequence = sample.sequence}
	}

	perf_select_graph_ratio :: proc(ratio: f64) {
		frames := framework_diagnostics.performance_recent_frames(
			&perf_recorder,
			10_000_000_000,
			context.temp_allocator,
		)
		if len(frames) == 0 {return}
		first_ns := frames[0].started_ns
		last_ns := frames[len(frames)-1].started_ns
		target_ns := first_ns+i64(clamp(ratio, 0, 1)*f64(last_ns-first_ns))
		selected := frames[0]
		selected_distance := abs(selected.started_ns-target_ns)
		for frame in frames[1:] {
			distance := abs(frame.started_ns-target_ns)
			if distance < selected_distance {
				selected = frame
				selected_distance = distance
			}
		}
		perf_selected_sequence = selected.sequence
	}

	perf_selected_detail :: proc() -> string {
		frame := framework_diagnostics.performance_find_frame(
			&perf_recorder,
			perf_selected_sequence,
		)
		if frame == nil && perf_recorder.frame_count > 0 {
			index := perf_recorder.next_frame-1
			if index < 0 {index += len(perf_recorder.frames)}
			frame = &perf_recorder.frames[index]
		}
		if frame == nil {return "NO FRAME SELECTED"}
		perf_selected_sequence = frame.sequence
		cpu_ms := f64(max(i64(0), frame.ended_ns-frame.started_ns))/1e6
		gap_ms := f64(max(i64(0), frame.callback_gap_ns))/1e6
		gpu_ms := f64(max(i64(0), frame.gpu_ended_ns-frame.gpu_started_ns))/1e6
		longest_name := "none"
		longest_ms := 0.0
		for span in frame.spans[0:frame.span_count] {
			duration_ms := f64(max(i64(0), span.end_ns-span.start_ns))/1e6
			if duration_ms > longest_ms {
				longest_ms = duration_ms
				longest_name = perf_zone_name(Perf_Zone(span.zone))
			}
		}
		return fmt.tprintf(
			"#%d  GAP %.1f  CPU %.1f  GPU %.1f MS  TOP %s %.1f MS",
			frame.sequence, gap_ms, cpu_ms, gpu_ms, longest_name, longest_ms,
		)
	}
}

foreign perf_bridge {
	hw_video_clips_perf_signpost_begin :: proc "c" (id: u64, name: ^u8, length: int) ---
	hw_video_clips_perf_signpost_end :: proc "c" (id: u64) ---
	hw_video_clips_perf_track_command_buffer :: proc "c" (
		command_buffer: Id,
		sequence: u64,
		callback: proc "c" (u64, i64, i64, i64),
	) ---
}
