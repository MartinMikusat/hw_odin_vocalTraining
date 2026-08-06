package main

import "core:fmt"
import "core:mem"
import "core:strings"
import mem_virtual "core:mem/virtual"

Arena_Stats :: struct {
	name: string,
	high_water: uint,
	reset_count: u64,
	allocation_failures: u64,
}

Memory_State :: struct {
	frame: mem_virtual.Arena,
	frame_stats: Arena_Stats,
	initialized: bool,
}

Transcript_Generation :: struct {
	arena: ^mem_virtual.Arena,
	segments: [dynamic]Transcript_Segment,
	source_spans: [dynamic]Transcript_Source_Span,
}

memory: Memory_State

memory_init :: proc() -> bool {
	if err := mem_virtual.arena_init_static(&memory.frame, 64*mem.Megabyte, 64*mem.Kilobyte); err != nil {
		return false
	}
	memory.frame.default_commit_size = 64*mem.Kilobyte
	memory.frame_stats.name = "frame"
	memory.initialized = true
	return true
}

arena_reset :: proc(arena: ^mem_virtual.Arena, stats: ^Arena_Stats) {
	stats.high_water = max(stats.high_water, arena.total_used)
	stats.reset_count += 1
	mem_virtual.arena_free_all(arena)
}

arena_note_failure :: proc(stats: ^Arena_Stats) {
	stats.allocation_failures += 1
}

memory_destroy :: proc() {
	if !memory.initialized { return }
	memory.frame_stats.high_water = max(memory.frame_stats.high_water, memory.frame.total_used)
	when ODIN_DEBUG {
		fmt.eprintf("[arena] %s high-water=%d resets=%d failures=%d\n", memory.frame_stats.name, memory.frame_stats.high_water, memory.frame_stats.reset_count, memory.frame_stats.allocation_failures)
	}
	mem_virtual.arena_destroy(&memory.frame)
	memory = {}
}

growing_arena_create :: proc(minimum_block_size := 4*mem.Megabyte, commit_size := mem.Megabyte) -> (^mem_virtual.Arena, bool) {
	arena := new(mem_virtual.Arena)
	arena.minimum_block_size = uint(minimum_block_size)
	arena.default_commit_size = uint(commit_size)
	if err := mem_virtual.arena_init_growing(arena, uint(minimum_block_size)); err != nil {
		free(arena)
		return nil, false
	}
	return arena, true
}

growing_arena_destroy :: proc(arena: ^mem_virtual.Arena) {
	if arena == nil { return }
	mem_virtual.arena_destroy(arena)
	free(arena)
}

transcript_generation_create :: proc(capacity: int = 0) -> (Transcript_Generation, bool) {
	arena, ok := growing_arena_create()
	if !ok { return {}, false }
	allocator := mem_virtual.arena_allocator(arena)
	segments, err := make([dynamic]Transcript_Segment, 0, capacity, allocator)
	if err != nil {
		growing_arena_destroy(arena)
		return {}, false
	}
	source_spans, span_error := make([dynamic]Transcript_Source_Span, 0, 0, allocator)
	if span_error != nil {
		growing_arena_destroy(arena)
		return {}, false
	}
	return Transcript_Generation{
		arena=arena,
		segments=segments,
		source_spans=source_spans,
	}, true
}

transcript_generation_destroy :: proc(generation: ^Transcript_Generation) {
	if generation == nil { return }
	growing_arena_destroy(generation.arena)
	generation^ = {}
}

transcript_source_span_index :: proc(
	generation: ^Transcript_Generation,
	source_id: string,
) -> int {
	if generation == nil { return -1 }
	for span, index in generation.source_spans {
		if span.source_id == source_id { return index }
	}
	return -1
}

transcript_source_segments :: proc(
	generation: ^Transcript_Generation,
	source_id: string,
) -> (
	segments: []Transcript_Segment,
	base_index: int,
	found: bool,
) {
	span_index := transcript_source_span_index(generation, source_id)
	if span_index < 0 { return nil, -1, false }
	span := generation.source_spans[span_index]
	return generation.segments[span.start:span.start+span.count], span.start, true
}

transcript_append_copy :: proc(generation: ^Transcript_Generation, segment: Transcript_Segment) -> bool {
	if len(generation.source_spans) > 0 {
		last_span := generation.source_spans[len(generation.source_spans)-1]
		if last_span.source_id != segment.source_id &&
		   transcript_source_span_index(generation, segment.source_id) >= 0 {
			return false
		}
	}
	allocator := mem_virtual.arena_allocator(generation.arena)
	id, id_error := strings.clone(segment.id, allocator)
	if id_error != nil { return false }
	source_id, source_error := strings.clone(segment.source_id, allocator)
	if source_error != nil { return false }
	text, text_error := strings.clone(segment.text, allocator)
	if text_error != nil { return false }
	append(&generation.segments, Transcript_Segment{
		id=id,
		source_id=source_id,
		start_seconds=segment.start_seconds,
		duration_seconds=segment.duration_seconds,
		text=text,
	})
	if len(generation.source_spans) > 0 &&
	   generation.source_spans[len(generation.source_spans)-1].source_id == source_id {
		generation.source_spans[len(generation.source_spans)-1].count += 1
	} else {
		append(&generation.source_spans, Transcript_Source_Span{
			source_id=source_id,
			start=len(generation.segments)-1,
			count=1,
		})
	}
	return true
}

transcript_generation_copy :: proc(segments: []Transcript_Segment) -> (Transcript_Generation, bool) {
	generation, ok := transcript_generation_create(len(segments))
	if !ok { return {}, false }
	for segment in segments {
		if transcript_source_span_index(&generation, segment.source_id) >= 0 { continue }
		for candidate in segments {
			if candidate.source_id != segment.source_id { continue }
			if !transcript_append_copy(&generation, candidate) {
				transcript_generation_destroy(&generation)
				return {}, false
			}
		}
	}
	return generation, true
}

transcript_generation_replace_source :: proc(
	current: ^Transcript_Generation,
	replacement: ^Transcript_Generation,
	source_id: string,
) -> (Transcript_Generation, bool) {
	replacement_segments, _, replacement_found := transcript_source_segments(
		replacement,
		source_id,
	)
	if !replacement_found {
		return {}, false
	}
	capacity := len(current.segments) + len(replacement_segments)
	if current_segments, _, found := transcript_source_segments(
		current,
		source_id,
	); found {
		capacity -= len(current_segments)
	}
	generation, created := transcript_generation_create(capacity)
	if !created {
		return {}, false
	}
	inserted := false
	for span in current.source_spans {
		segments := current.segments[span.start:span.start + span.count]
		if span.source_id == source_id {
			segments = replacement_segments
			inserted = true
		}
		for segment in segments {
			if !transcript_append_copy(&generation, segment) {
				transcript_generation_destroy(&generation)
				return {}, false
			}
		}
	}
	if !inserted {
		for segment in replacement_segments {
			if !transcript_append_copy(&generation, segment) {
				transcript_generation_destroy(&generation)
				return {}, false
			}
		}
	}
	return generation, true
}

clone_source_video :: proc(source: Source_Video, allocator := context.allocator) -> (Source_Video, bool) {
	result := Source_Video{
		workflow=source.workflow,
		kind=source.kind,
		duration=source.duration,
		metadata_status=source.metadata_status,
		media_available=source.media_available,
		has_audio=source.has_audio,
	}
	copied := false
	defer if !copied { delete_source_video(&result, allocator) }
	value, err := strings.clone(source.id, allocator); if err != nil { return {}, false }; result.id = value
	value, err = strings.clone(source.video_id, allocator); if err != nil { return {}, false }; result.video_id = value
	value, err = strings.clone(source.title, allocator); if err != nil { return {}, false }; result.title = value
	value, err = strings.clone(source.url, allocator); if err != nil { return {}, false }; result.url = value
	value, err = strings.clone(source.original_filename, allocator); if err != nil { return {}, false }; result.original_filename = value
	value, err = strings.clone(source.content_sha256, allocator); if err != nil { return {}, false }; result.content_sha256 = value
	value, err = strings.clone(source.media_path, allocator); if err != nil { return {}, false }; result.media_path = value
	result.metadata = Source_Context_Metadata{width=source.metadata.width, height=source.metadata.height, fps=source.metadata.fps, filesize_approx=source.metadata.filesize_approx}
	value, err = strings.clone(source.metadata.vcodec, allocator); if err != nil { return {}, false }; result.metadata.vcodec = value
	value, err = strings.clone(source.metadata.acodec, allocator); if err != nil { return {}, false }; result.metadata.acodec = value
	value, err = strings.clone(source.metadata.ext, allocator); if err != nil { return {}, false }; result.metadata.ext = value
	value, err = strings.clone(source.metadata.format_id, allocator); if err != nil { return {}, false }; result.metadata.format_id = value
	copied = true
	return result, true
}

clone_import_hint :: proc(hint: Import_Hint, allocator := context.allocator) -> (Import_Hint, bool) {
	result := Import_Hint{seconds=hint.seconds}
	copied := false
	defer if !copied { delete_import_hint(&result, allocator) }
	value, err := strings.clone(hint.source_id, allocator); if err != nil { return {}, false }; result.source_id = value
	copied = true
	return result, true
}

clone_clip :: proc(clip: Clip, allocator := context.allocator) -> (Clip, bool) {
	result := Clip{
		workflow = clip.workflow,
		start_seconds = clip.start_seconds,
		end_seconds = clip.end_seconds,
		last_randomized_sequence = clip.last_randomized_sequence,
		dance_mirrored = clip.dance_mirrored,
		dance_loop = clip.dance_loop,
		dance_count_in_beats = clip.dance_count_in_beats,
		dance_count_each_loop = clip.dance_count_each_loop,
		dance_count_in_bpm = clip.dance_count_in_bpm,
		dance_detected_bpm = clip.dance_detected_bpm,
		dance_bpm_confidence = clip.dance_bpm_confidence,
		dance_bpm_detector_revision = clip.dance_bpm_detector_revision,
		dance_bpm_user_set = clip.dance_bpm_user_set,
		dance_beat_period_seconds = clip.dance_beat_period_seconds,
		dance_beat_grid_offset_seconds = clip.dance_beat_grid_offset_seconds,
		dance_beat_phase_confidence = clip.dance_beat_phase_confidence,
		dance_beat_phase_user_set = clip.dance_beat_phase_user_set,
		dance_metronome_enabled = clip.dance_metronome_enabled,
		dance_playback_rate = clip.dance_playback_rate,
	}
	copied := false
	defer if !copied { delete_clip(&result, allocator) }
	value, err := strings.clone(clip.id, allocator); if err != nil { return {}, false }; result.id = value
	value, err = strings.clone(clip.source_id, allocator); if err != nil { return {}, false }; result.source_id = value
	value, err = strings.clone(clip.name, allocator); if err != nil { return {}, false }; result.name = value
	value, err = strings.clone(clip.clip_path, allocator); if err != nil { return {}, false }; result.clip_path = value
	copied = true
	return result, true
}

delete_source_video :: proc(source: ^Source_Video, allocator := context.allocator) {
	if source == nil { return }
	delete(source.id, allocator); delete(source.video_id, allocator); delete(source.title, allocator); delete(source.url, allocator); delete(source.original_filename, allocator); delete(source.content_sha256, allocator); delete(source.media_path, allocator)
	delete_source_context_metadata(&source.metadata, allocator)
	source^ = {}
}

delete_import_hint :: proc(hint: ^Import_Hint, allocator := context.allocator) {
	if hint == nil { return }
	delete(hint.source_id, allocator)
	hint^ = {}
}

delete_clip :: proc(clip: ^Clip, allocator := context.allocator) {
	if clip == nil { return }
	delete(clip.id, allocator); delete(clip.source_id, allocator); delete(clip.name, allocator); delete(clip.clip_path, allocator)
	clip^ = {}
}

app_state_collections_clone :: proc(source: ^App_State) -> (App_State, bool) {
	if source == nil {return {}, false}
	result: App_State
	copied := false
	defer if !copied {app_state_collections_destroy(&result)}

	sources, sources_error := make([dynamic]Source_Video, 0, len(source.sources))
	if sources_error != nil {return {}, false}
	result.sources = sources
	hints, hints_error := make([dynamic]Import_Hint, 0, len(source.hints))
	if hints_error != nil {return {}, false}
	result.hints = hints
	clips, clips_error := make([dynamic]Clip, 0, len(source.clips))
	if clips_error != nil {return {}, false}
	result.clips = clips

	for value in source.sources {
		copy, ok := clone_source_video(value)
		if !ok {return {}, false}
		append(&result.sources, copy)
	}
	for value in source.hints {
		copy, ok := clone_import_hint(value)
		if !ok {return {}, false}
		append(&result.hints, copy)
	}
	for value in source.clips {
		copy, ok := clone_clip(value)
		if !ok {return {}, false}
		append(&result.clips, copy)
	}
	transcripts, transcripts_ok := transcript_generation_copy(source.transcripts.segments[:])
	if !transcripts_ok {return {}, false}
	result.transcripts = transcripts
	copied = true
	return result, true
}

app_state_collections_copy :: proc(
	sources: []Source_Video,
	segments: []Transcript_Segment,
	hints: []Import_Hint,
	clips: []Clip,
) -> (App_State, bool) {
	result: App_State
	result.sources = make([dynamic]Source_Video, 0, len(sources))
	result.hints = make([dynamic]Import_Hint, 0, len(hints))
	result.clips = make([dynamic]Clip, 0, len(clips))
	loaded := false
	defer if !loaded {app_state_collections_destroy(&result)}
	for source in sources {
		copy, copied := clone_source_video(source)
		if !copied {return {}, false}
		append(&result.sources, copy)
	}
	for hint in hints {
		copy, copied := clone_import_hint(hint)
		if !copied {return {}, false}
		append(&result.hints, copy)
	}
	for clip in clips {
		copy, copied := clone_clip(clip)
		if !copied {return {}, false}
		append(&result.clips, copy)
	}
	transcripts, copied := transcript_generation_copy(segments)
	if !copied {return {}, false}
	result.transcripts = transcripts
	loaded = true
	return result, true
}

app_state_collections_replace :: proc(destination, replacement: ^App_State) {
	if destination == nil || replacement == nil {return}
	previous: App_State
	previous.sources = destination.sources
	previous.transcripts = destination.transcripts
	previous.hints = destination.hints
	previous.clips = destination.clips
	destination.sources = replacement.sources
	destination.transcripts = replacement.transcripts
	destination.hints = replacement.hints
	destination.clips = replacement.clips
	replacement.sources = nil
	replacement.transcripts = {}
	replacement.hints = nil
	replacement.clips = nil
	app_state_collections_destroy(&previous)
}

app_state_collections_destroy :: proc(value: ^App_State) {
	if value == nil {return}
	for &source in value.sources {delete_source_video(&source)}
	for &hint in value.hints {delete_import_hint(&hint)}
	for &clip in value.clips {delete_clip(&clip)}
	delete(value.sources)
	delete(value.hints)
	delete(value.clips)
	transcript_generation_destroy(&value.transcripts)
	value.sources = nil
	value.hints = nil
	value.clips = nil
}

app_state_memory_destroy :: proc() {
	app_state_collections_destroy(&state)
}
