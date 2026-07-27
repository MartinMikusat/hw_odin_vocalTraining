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
	redraw: mem_virtual.Arena,
	frame_stats: Arena_Stats,
	redraw_stats: Arena_Stats,
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
	if err := mem_virtual.arena_init_static(&memory.redraw, 512*mem.Megabyte, mem.Megabyte); err != nil {
		mem_virtual.arena_destroy(&memory.frame)
		return false
	}
	memory.redraw.default_commit_size = mem.Megabyte
	memory.frame_stats.name = "frame"
	memory.redraw_stats.name = "redraw"
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
	memory.redraw_stats.high_water = max(memory.redraw_stats.high_water, memory.redraw.total_used)
	when ODIN_DEBUG {
		fmt.eprintf("[arena] %s high-water=%d resets=%d failures=%d\n", memory.frame_stats.name, memory.frame_stats.high_water, memory.frame_stats.reset_count, memory.frame_stats.allocation_failures)
		fmt.eprintf("[arena] %s high-water=%d resets=%d failures=%d\n", memory.redraw_stats.name, memory.redraw_stats.high_water, memory.redraw_stats.reset_count, memory.redraw_stats.allocation_failures)
	}
	mem_virtual.arena_destroy(&memory.redraw)
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

clone_source_video :: proc(source: Source_Video, allocator := context.allocator) -> (Source_Video, bool) {
	result := Source_Video{duration=source.duration, metadata_status=source.metadata_status, media_available=source.media_available}
	copied := false
	defer if !copied { delete_source_video(&result, allocator) }
	value, err := strings.clone(source.id, allocator); if err != nil { return {}, false }; result.id = value
	value, err = strings.clone(source.video_id, allocator); if err != nil { return {}, false }; result.video_id = value
	value, err = strings.clone(source.title, allocator); if err != nil { return {}, false }; result.title = value
	value, err = strings.clone(source.url, allocator); if err != nil { return {}, false }; result.url = value
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

clone_exercise :: proc(exercise: Exercise, allocator := context.allocator) -> (Exercise, bool) {
	result := Exercise{
		start_seconds = exercise.start_seconds,
		end_seconds = exercise.end_seconds,
		last_randomized_sequence = exercise.last_randomized_sequence,
	}
	copied := false
	defer if !copied { delete_exercise(&result, allocator) }
	value, err := strings.clone(exercise.id, allocator); if err != nil { return {}, false }; result.id = value
	value, err = strings.clone(exercise.source_id, allocator); if err != nil { return {}, false }; result.source_id = value
	value, err = strings.clone(exercise.name, allocator); if err != nil { return {}, false }; result.name = value
	value, err = strings.clone(exercise.clip_path, allocator); if err != nil { return {}, false }; result.clip_path = value
	copied = true
	return result, true
}

delete_source_video :: proc(source: ^Source_Video, allocator := context.allocator) {
	if source == nil { return }
	delete(source.id, allocator); delete(source.video_id, allocator); delete(source.title, allocator); delete(source.url, allocator); delete(source.media_path, allocator)
	delete_source_context_metadata(&source.metadata, allocator)
	source^ = {}
}

delete_import_hint :: proc(hint: ^Import_Hint, allocator := context.allocator) {
	if hint == nil { return }
	delete(hint.source_id, allocator)
	hint^ = {}
}

delete_exercise :: proc(exercise: ^Exercise, allocator := context.allocator) {
	if exercise == nil { return }
	delete(exercise.id, allocator); delete(exercise.source_id, allocator); delete(exercise.name, allocator); delete(exercise.clip_path, allocator)
	exercise^ = {}
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
	exercises, exercises_error := make([dynamic]Exercise, 0, len(source.exercises))
	if exercises_error != nil {return {}, false}
	result.exercises = exercises

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
	for value in source.exercises {
		copy, ok := clone_exercise(value)
		if !ok {return {}, false}
		append(&result.exercises, copy)
	}
	transcripts, transcripts_ok := transcript_generation_copy(source.transcripts.segments[:])
	if !transcripts_ok {return {}, false}
	result.transcripts = transcripts
	copied = true
	return result, true
}

app_state_collections_replace :: proc(destination, replacement: ^App_State) {
	if destination == nil || replacement == nil {return}
	previous: App_State
	previous.sources = destination.sources
	previous.transcripts = destination.transcripts
	previous.hints = destination.hints
	previous.exercises = destination.exercises
	destination.sources = replacement.sources
	destination.transcripts = replacement.transcripts
	destination.hints = replacement.hints
	destination.exercises = replacement.exercises
	replacement.sources = nil
	replacement.transcripts = {}
	replacement.hints = nil
	replacement.exercises = nil
	app_state_collections_destroy(&previous)
}

app_state_collections_destroy :: proc(value: ^App_State) {
	if value == nil {return}
	for &source in value.sources {delete_source_video(&source)}
	for &hint in value.hints {delete_import_hint(&hint)}
	for &exercise in value.exercises {delete_exercise(&exercise)}
	delete(value.sources)
	delete(value.hints)
	delete(value.exercises)
	transcript_generation_destroy(&value.transcripts)
	value.sources = nil
	value.hints = nil
	value.exercises = nil
}

app_state_memory_destroy :: proc() {
	app_state_collections_destroy(&state)
}
