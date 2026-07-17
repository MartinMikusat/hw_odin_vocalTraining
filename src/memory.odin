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
	return Transcript_Generation{arena=arena, segments=segments}, true
}

transcript_generation_destroy :: proc(generation: ^Transcript_Generation) {
	if generation == nil { return }
	growing_arena_destroy(generation.arena)
	generation^ = {}
}

transcript_append_copy :: proc(generation: ^Transcript_Generation, segment: Transcript_Segment) -> bool {
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
	return true
}

transcript_generation_copy :: proc(segments: []Transcript_Segment) -> (Transcript_Generation, bool) {
	generation, ok := transcript_generation_create(len(segments))
	if !ok { return {}, false }
	for segment in segments {
		if !transcript_append_copy(&generation, segment) {
			transcript_generation_destroy(&generation)
			return {}, false
		}
	}
	return generation, true
}

clone_source_video :: proc(source: Source_Video, allocator := context.allocator) -> (Source_Video, bool) {
	result := Source_Video{duration=source.duration}
	copied := false
	defer if !copied { delete_source_video(&result, allocator) }
	value, err := strings.clone(source.id, allocator); if err != nil { return {}, false }; result.id = value
	value, err = strings.clone(source.video_id, allocator); if err != nil { return {}, false }; result.video_id = value
	value, err = strings.clone(source.title, allocator); if err != nil { return {}, false }; result.title = value
	value, err = strings.clone(source.url, allocator); if err != nil { return {}, false }; result.url = value
	value, err = strings.clone(source.media_path, allocator); if err != nil { return {}, false }; result.media_path = value
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
	result := Exercise{start_seconds=exercise.start_seconds, end_seconds=exercise.end_seconds}
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

app_state_memory_destroy :: proc() {
	for &source in state.sources { delete_source_video(&source) }
	for &hint in state.hints { delete_import_hint(&hint) }
	for &exercise in state.exercises { delete_exercise(&exercise) }
	delete(state.sources)
	delete(state.hints)
	delete(state.exercises)
	transcript_generation_destroy(&state.transcripts)
}
