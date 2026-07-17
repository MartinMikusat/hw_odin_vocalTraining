package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import mem_virtual "core:mem/virtual"
import "base:runtime"

YTDLP_Metadata :: struct {
	title: string,
	duration: f64,
}

YouTube_Caption_Segment :: struct {
	text: string `json:"utf8"`,
}

YouTube_Caption_Event :: struct {
	start_ms: f64 `json:"tStartMs"`,
	duration_ms: f64 `json:"dDurationMs"`,
	segments: []YouTube_Caption_Segment `json:"segs"`,
}

YouTube_Captions :: struct {
	events: []YouTube_Caption_Event,
}

load_download_metadata :: proc(video_id: string, allocator := context.allocator) -> (YTDLP_Metadata, bool) {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD(ignore=context.temp_allocator == allocator)
	path := fmt.tprintf("%s/sources/%s.info.json", app_support_dir(), video_id)
	bytes, ok := os.read_entire_file(path, context.temp_allocator)
	if !ok { return {}, false }
	metadata: YTDLP_Metadata
	if err := json.unmarshal(bytes, &metadata, .JSON, allocator); err != nil { return {}, false }
	return metadata, true
}

caption_path :: proc(source: ^Source_Video, allocator := context.temp_allocator) -> (string, bool) {
	directory := fmt.aprintf("%s/sources", app_support_dir(), allocator=allocator)
	handle, open_error := os.open(directory)
	if open_error != nil { return "", false }
	entries, read_error := os.read_dir(handle, -1, allocator)
	os.close(handle)
	if read_error != nil { return "", false }
	prefix := fmt.aprintf("%s.", source.video_id, allocator=allocator)
	path := ""
	for entry in entries {
		if strings.has_prefix(entry.name, prefix) && strings.has_suffix(entry.name, ".json3") {
			path = fmt.aprintf("%s/%s", directory, entry.name, allocator=allocator)
			if strings.has_suffix(entry.name, ".en.json3") { break }
		}
	}
	return path, len(path) > 0
}

build_transcript_generation :: proc(source: ^Source_Video, previous: []Transcript_Segment) -> (Transcript_Generation, int, bool) {
	scratch, scratch_ok := growing_arena_create()
	if !scratch_ok { return {}, 0, false }
	defer growing_arena_destroy(scratch)
	scratch_allocator := mem_virtual.arena_allocator(scratch)

	path, found := caption_path(source, scratch_allocator)
	if !found { return {}, 0, false }
	bytes, read_ok := os.read_entire_file(path, scratch_allocator)
	if !read_ok { return {}, 0, false }
	captions: YouTube_Captions
	if err := json.unmarshal(bytes, &captions, .JSON, scratch_allocator); err != nil { return {}, 0, false }

	generation, generation_ok := transcript_generation_create(len(previous)+len(captions.events))
	if !generation_ok { return {}, 0, false }
	for segment in previous {
		if segment.source_id == source.id { continue }
		if !transcript_append_copy(&generation, segment) {
			transcript_generation_destroy(&generation)
			return {}, 0, false
		}
	}

	destination := mem_virtual.arena_allocator(generation.arena)
	count := 0
	for event, index in captions.events {
		parts, parts_error := make([]string, len(event.segments), scratch_allocator)
		if parts_error != nil {
			transcript_generation_destroy(&generation)
			return {}, 0, false
		}
		for segment, part_index in event.segments { parts[part_index] = segment.text }
		text, text_error := strings.concatenate(parts, destination)
		if text_error != nil {
			transcript_generation_destroy(&generation)
			return {}, 0, false
		}
		if len(text) == 0 || text == "\n" { continue }
		id := fmt.aprintf("%s-%d", source.id, index, allocator=destination)
		source_id, source_error := strings.clone(source.id, destination)
		if source_error != nil {
			transcript_generation_destroy(&generation)
			return {}, 0, false
		}
		append(&generation.segments, Transcript_Segment{
			id=id,
			source_id=source_id,
			start_seconds=event.start_ms/1000,
			duration_seconds=event.duration_ms/1000,
			text=text,
		})
		count += 1
	}
	return generation, count, true
}

install_transcript_generation :: proc(next: Transcript_Generation) {
	previous := state.transcripts
	state.transcripts = next
	transcript_generation_destroy(&previous)
}

load_youtube_transcript :: proc(source: ^Source_Video) -> int {
	next, count, ok := build_transcript_generation(source, state.transcripts.segments[:])
	if !ok { return 0 }
	install_transcript_generation(next)
	save_library()
	return count
}

Persisted_State :: struct {
	version: int,
	sources: [dynamic]Source_Video,
	segments: [dynamic]Transcript_Segment,
	hints: [dynamic]Import_Hint,
	exercises: [dynamic]Exercise,
}

manifest_path :: proc() -> string {
	return fmt.tprintf("%s/library.json", app_support_dir())
}

save_library :: proc() -> bool {
	scratch, ok := growing_arena_create()
	if !ok { return false }
	defer growing_arena_destroy(scratch)
	allocator := mem_virtual.arena_allocator(scratch)
	data := Persisted_State{
		version = 1,
		sources = state.sources,
		segments = state.transcripts.segments,
		hints = state.hints,
		exercises = state.exercises,
	}
	encoded, err := json.marshal(data, {pretty=true, use_spaces=true, spaces=2}, allocator)
	if err != nil { return false }
	os.make_directory(app_support_dir())
	return os.write_entire_file(manifest_path(), encoded)
}

load_library :: proc() {
	scratch, ok := growing_arena_create()
	if !ok { return }
	defer growing_arena_destroy(scratch)
	allocator := mem_virtual.arena_allocator(scratch)
	bytes, read_ok := os.read_entire_file(manifest_path(), allocator)
	if !read_ok { return }
	data: Persisted_State
	if err := json.unmarshal(bytes, &data, .JSON, allocator); err != nil { return }

	sources := make([dynamic]Source_Video, 0, len(data.sources))
	hints := make([dynamic]Import_Hint, 0, len(data.hints))
	exercises := make([dynamic]Exercise, 0, len(data.exercises))
	transcripts: Transcript_Generation
	copied: bool
	loaded := false
	defer {
		if !loaded {
			for &source in sources { delete_source_video(&source) }
			for &hint in hints { delete_import_hint(&hint) }
			for &exercise in exercises { delete_exercise(&exercise) }
			delete(sources)
			delete(hints)
			delete(exercises)
			transcript_generation_destroy(&transcripts)
		}
	}
	for source in data.sources {
		copy, copied := clone_source_video(source)
		if !copied { return }
		append(&sources, copy)
	}
	for hint in data.hints {
		copy, copied := clone_import_hint(hint)
		if !copied { return }
		append(&hints, copy)
	}
	for exercise in data.exercises {
		copy, copied := clone_exercise(exercise)
		if !copied { return }
		append(&exercises, copy)
	}
	transcripts, copied = transcript_generation_copy(data.segments[:])
	if !copied { return }

	state.sources = sources
	state.hints = hints
	state.exercises = exercises
	state.transcripts = transcripts
	loaded = true
}
