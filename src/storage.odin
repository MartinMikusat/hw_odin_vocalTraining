package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"

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

load_download_metadata :: proc(video_id: string) -> (YTDLP_Metadata, bool) {
	path := fmt.tprintf("%s/sources/%s.info.json", app_support_dir(), video_id)
	bytes, ok := os.read_entire_file(path)
	if !ok { return {}, false }
	defer delete(bytes)
	metadata: YTDLP_Metadata
	if err := json.unmarshal(bytes, &metadata, .JSON); err != nil { return {}, false }
	return metadata, true
}

load_youtube_transcript :: proc(source: ^Source_Video) -> int {
	directory := fmt.tprintf("%s/sources", app_support_dir())
	handle, open_error := os.open(directory)
	if open_error != nil { return 0 }
	entries, read_error := os.read_dir(handle, -1)
	os.close(handle)
	if read_error != nil { return 0 }
	defer os.file_info_slice_delete(entries)
	path := ""
	prefix := fmt.tprintf("%s.", source.video_id)
	for entry in entries {
		if strings.has_prefix(entry.name, prefix) && strings.has_suffix(entry.name, ".json3") {
			path = fmt.tprintf("%s/%s", directory, entry.name)
			if strings.has_suffix(entry.name, ".en.json3") { break }
		}
	}
	if len(path) == 0 { return 0 }
	bytes, ok := os.read_entire_file(path)
	if !ok { return 0 }
	defer delete(bytes)
	captions: YouTube_Captions
	if err := json.unmarshal(bytes, &captions, .JSON); err != nil { return 0 }
	for i := len(state.segments)-1; i >= 0; i -= 1 {
		if state.segments[i].source_id == source.id { unordered_remove(&state.segments, i) }
	}
	count := 0
	for event, index in captions.events {
		text := ""
		for segment in event.segments { text = fmt.tprintf("%s%s", text, segment.text) }
		if len(text) == 0 || text == "\n" { continue }
		append(&state.segments, Transcript_Segment{
			id=fmt.tprintf("%s-%d", source.id, index),
			source_id=fmt.tprintf("%s", source.id),
			start_seconds=event.start_ms/1000,
			duration_seconds=event.duration_ms/1000,
			text=text,
		})
		count += 1
	}
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
	data := Persisted_State{
		version = 1,
		sources = state.sources,
		segments = state.segments,
		hints = state.hints,
		exercises = state.exercises,
	}
	encoded, err := json.marshal(data, {pretty=true, use_spaces=true, spaces=2})
	if err != nil { return false }
	defer delete(encoded)
	os.make_directory(app_support_dir())
	return os.write_entire_file(manifest_path(), encoded)
}

load_library :: proc() {
	bytes, ok := os.read_entire_file(manifest_path())
	if !ok { return }
	defer delete(bytes)
	data: Persisted_State
	if err := json.unmarshal(bytes, &data, .JSON); err != nil { return }
	state.sources = data.sources
	state.segments = data.segments
	state.hints = data.hints
	state.exercises = data.exercises
}
