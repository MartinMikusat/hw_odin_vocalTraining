package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import mem_virtual "core:mem/virtual"
import "base:runtime"

YTDLP_Metadata :: struct {
	title: string,
	duration: f64,
	width: int,
	height: int,
	fps: f64,
	vcodec: string,
	acodec: string,
	ext: string,
	format_id: string,
	filesize_approx: i64,
}

Source_Context_Metadata :: struct {
	width:           int,
	height:          int,
	fps:             f64,
	vcodec:          string,
	acodec:          string,
	ext:             string,
	format_id:       string,
	filesize_approx: i64,
}

delete_source_context_metadata :: proc(metadata: ^Source_Context_Metadata, allocator := context.allocator) {
	delete(metadata.vcodec, allocator)
	delete(metadata.acodec, allocator)
	delete(metadata.ext, allocator)
	delete(metadata.format_id, allocator)
	metadata^ = {}
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

load_source_context_metadata :: proc(video_id: string, allocator := context.allocator) -> (Source_Context_Metadata, bool) {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD(ignore=context.temp_allocator == allocator)
	path := fmt.tprintf("%s/sources/%s.info.json", app_support_dir(), video_id)
	bytes, ok := os.read_entire_file(path, context.temp_allocator)
	if !ok { return {}, false }
	metadata: Source_Context_Metadata
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
	invalidate_transcript_matches()
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

save_legacy_library :: proc() -> bool {
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

load_legacy_library :: proc() {
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
		copy.media_available = os.exists(copy.media_path)
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

library_database: ^SQLite_DB
library_legacy_fallback: bool

database_path :: proc() -> string {
	return fmt.tprintf("%s/library.sqlite3", app_support_dir())
}

database_file_path_for_storage :: proc(path: string) -> string {
	root := app_support_dir()
	prefix := fmt.tprintf("%s/", root)
	if strings.has_prefix(path, prefix) {return path[len(prefix):]}
	return path
}

database_file_path_for_runtime :: proc(path: string, allocator := context.allocator) -> (string, bool) {
	if filepath.is_abs(path) {
		copy, err := strings.clone(path, allocator)
		return copy, err == nil
	}
	resolved, err := filepath.join([]string{app_support_dir(), path}, allocator)
	return resolved, err == nil
}

database_create_schema :: proc(database: ^SQLite_DB) -> bool {
	return sqlite_execute(database, `
		PRAGMA foreign_keys = ON;
		CREATE TABLE IF NOT EXISTS sources (
			id TEXT PRIMARY KEY,
			video_id TEXT NOT NULL UNIQUE,
			title TEXT NOT NULL,
			url TEXT NOT NULL,
			media_path TEXT NOT NULL,
			duration REAL NOT NULL,
			position INTEGER NOT NULL,
			metadata_status INTEGER NOT NULL DEFAULT 0,
			width INTEGER NOT NULL DEFAULT 0,
			height INTEGER NOT NULL DEFAULT 0,
			fps REAL NOT NULL DEFAULT 0,
			video_codec TEXT NOT NULL DEFAULT '',
			audio_codec TEXT NOT NULL DEFAULT '',
			container TEXT NOT NULL DEFAULT '',
			format_id TEXT NOT NULL DEFAULT '',
			file_size INTEGER NOT NULL DEFAULT 0
		);
		CREATE TABLE IF NOT EXISTS transcript_segments (
			id TEXT PRIMARY KEY,
			source_id TEXT NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
			start_seconds REAL NOT NULL,
			duration_seconds REAL NOT NULL,
			text TEXT NOT NULL,
			position INTEGER NOT NULL
		);
		CREATE TABLE IF NOT EXISTS import_hints (
			source_id TEXT NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
			seconds REAL NOT NULL,
			position INTEGER NOT NULL,
			PRIMARY KEY(source_id, seconds)
		);
		CREATE TABLE IF NOT EXISTS exercises (
			id TEXT PRIMARY KEY,
			source_id TEXT NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
			name TEXT NOT NULL,
			start_seconds REAL NOT NULL,
			end_seconds REAL NOT NULL,
			clip_path TEXT NOT NULL,
			position INTEGER NOT NULL
		);
		PRAGMA user_version = 1;
	`)
}

database_insert_source :: proc(database: ^SQLite_DB, source: Source_Video, position: int) -> bool {
	statement, ok := sqlite_prepare(database, "INSERT INTO sources VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)")
	if !ok {return false}
	defer sqlite3_finalize(statement)
	return sqlite_bind_text_value(statement, 1, source.id) &&
		sqlite_bind_text_value(statement, 2, source.video_id) &&
		sqlite_bind_text_value(statement, 3, source.title) &&
		sqlite_bind_text_value(statement, 4, source.url) &&
		sqlite_bind_text_value(statement, 5, database_file_path_for_storage(source.media_path)) &&
		sqlite3_bind_double(statement, 6, source.duration) == SQLITE_OK &&
		sqlite3_bind_int(statement, 7, i32(position)) == SQLITE_OK &&
		sqlite3_bind_int(statement, 8, i32(source.metadata_status)) == SQLITE_OK &&
		sqlite3_bind_int(statement, 9, i32(source.metadata.width)) == SQLITE_OK &&
		sqlite3_bind_int(statement, 10, i32(source.metadata.height)) == SQLITE_OK &&
		sqlite3_bind_double(statement, 11, source.metadata.fps) == SQLITE_OK &&
		sqlite_bind_text_value(statement, 12, source.metadata.vcodec) &&
		sqlite_bind_text_value(statement, 13, source.metadata.acodec) &&
		sqlite_bind_text_value(statement, 14, source.metadata.ext) &&
		sqlite_bind_text_value(statement, 15, source.metadata.format_id) &&
		sqlite3_bind_int64(statement, 16, source.metadata.filesize_approx) == SQLITE_OK &&
		sqlite3_step(statement) == SQLITE_DONE
}

database_save_collections :: proc(
	database: ^SQLite_DB,
	sources: []Source_Video,
	segments: []Transcript_Segment,
	hints: []Import_Hint,
	exercises: []Exercise,
) -> bool {
	if database == nil {return false}
	if !sqlite_execute(database, "BEGIN IMMEDIATE") {return false}
	committed := false
	defer if !committed {sqlite_execute(database, "ROLLBACK")}
	if !sqlite_execute(database, "DELETE FROM transcript_segments; DELETE FROM import_hints; DELETE FROM exercises; DELETE FROM sources;") {return false}
	for source, position in sources {
		if !database_insert_source(database, source, position) {return false}
	}
	for segment, position in segments {
		statement, ok := sqlite_prepare(database, "INSERT INTO transcript_segments VALUES (?, ?, ?, ?, ?, ?)")
		if !ok {return false}
		bound := sqlite_bind_text_value(statement, 1, segment.id) && sqlite_bind_text_value(statement, 2, segment.source_id) &&
			sqlite3_bind_double(statement, 3, segment.start_seconds) == SQLITE_OK && sqlite3_bind_double(statement, 4, segment.duration_seconds) == SQLITE_OK &&
			sqlite_bind_text_value(statement, 5, segment.text) && sqlite3_bind_int(statement, 6, i32(position)) == SQLITE_OK
		stepped := bound && sqlite3_step(statement) == SQLITE_DONE
		sqlite3_finalize(statement)
		if !stepped {return false}
	}
	for hint, position in hints {
		statement, ok := sqlite_prepare(database, "INSERT INTO import_hints VALUES (?, ?, ?)")
		if !ok {return false}
		bound := sqlite_bind_text_value(statement, 1, hint.source_id) && sqlite3_bind_double(statement, 2, hint.seconds) == SQLITE_OK && sqlite3_bind_int(statement, 3, i32(position)) == SQLITE_OK
		stepped := bound && sqlite3_step(statement) == SQLITE_DONE
		sqlite3_finalize(statement)
		if !stepped {return false}
	}
	for exercise, position in exercises {
		statement, ok := sqlite_prepare(database, "INSERT INTO exercises VALUES (?, ?, ?, ?, ?, ?, ?)")
		if !ok {return false}
		bound := sqlite_bind_text_value(statement, 1, exercise.id) && sqlite_bind_text_value(statement, 2, exercise.source_id) && sqlite_bind_text_value(statement, 3, exercise.name) &&
			sqlite3_bind_double(statement, 4, exercise.start_seconds) == SQLITE_OK && sqlite3_bind_double(statement, 5, exercise.end_seconds) == SQLITE_OK &&
			sqlite_bind_text_value(statement, 6, database_file_path_for_storage(exercise.clip_path)) && sqlite3_bind_int(statement, 7, i32(position)) == SQLITE_OK
		stepped := bound && sqlite3_step(statement) == SQLITE_DONE
		sqlite3_finalize(statement)
		if !stepped {return false}
	}
	if !sqlite_execute(database, "COMMIT") {return false}
	committed = true
	return true
}

database_save_state :: proc(database: ^SQLite_DB) -> bool {
	return database_save_collections(database, state.sources[:], state.transcripts.segments[:], state.hints[:], state.exercises[:])
}

database_integrity_ok :: proc(database: ^SQLite_DB) -> bool {
	statement, ok := sqlite_prepare(database, "PRAGMA integrity_check")
	if !ok {return false}
	defer sqlite3_finalize(statement)
	if sqlite3_step(statement) != SQLITE_ROW {return false}
	value := sqlite3_column_text(statement, 0)
	return value != nil && string(value) == "ok"
}

database_count :: proc(database: ^SQLite_DB, table: string) -> (int, bool) {
	statement, ok := sqlite_prepare(database, fmt.tprintf("SELECT COUNT(*) FROM %s", table))
	if !ok {return 0, false}
	defer sqlite3_finalize(statement)
	if sqlite3_step(statement) != SQLITE_ROW {return 0, false}
	return int(sqlite3_column_int64(statement, 0)), true
}

database_state_counts_match :: proc(database: ^SQLite_DB) -> bool {
	source_count, ok := database_count(database, "sources"); if !ok || source_count != len(state.sources) {return false}
	segment_count, segment_ok := database_count(database, "transcript_segments"); if !segment_ok || segment_count != len(state.transcripts.segments) {return false}
	hint_count, hint_ok := database_count(database, "import_hints"); if !hint_ok || hint_count != len(state.hints) {return false}
	exercise_count, exercise_ok := database_count(database, "exercises"); if !exercise_ok || exercise_count != len(state.exercises) {return false}
	return true
}

database_load_state :: proc(database: ^SQLite_DB, destination: ^App_State) -> bool {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	sources := make([dynamic]Source_Video)
	hints := make([dynamic]Import_Hint)
	exercises := make([dynamic]Exercise)
	transcripts, transcript_ok := transcript_generation_create(256)
	if !transcript_ok {return false}
	loaded := false
	defer if !loaded {
		for &source in sources {delete_source_video(&source)}
		for &hint in hints {delete_import_hint(&hint)}
		for &exercise in exercises {delete_exercise(&exercise)}
		delete(sources); delete(hints); delete(exercises)
		transcript_generation_destroy(&transcripts)
	}

	statement, ok := sqlite_prepare(database, "SELECT id, video_id, title, url, media_path, duration, metadata_status, width, height, fps, video_codec, audio_codec, container, format_id, file_size FROM sources ORDER BY position")
	if !ok {return false}
	for sqlite3_step(statement) == SQLITE_ROW {
		source := Source_Video{}
		copied: bool
		source.id, copied = sqlite_column_string(statement, 0); if !copied {sqlite3_finalize(statement); return false}
		source.video_id, copied = sqlite_column_string(statement, 1); if !copied {delete_source_video(&source); sqlite3_finalize(statement); return false}
		source.title, copied = sqlite_column_string(statement, 2); if !copied {delete_source_video(&source); sqlite3_finalize(statement); return false}
		source.url, copied = sqlite_column_string(statement, 3); if !copied {delete_source_video(&source); sqlite3_finalize(statement); return false}
		stored_media_path, stored_media_path_copied := sqlite_column_string(statement, 4, context.temp_allocator)
		if !stored_media_path_copied {delete_source_video(&source); sqlite3_finalize(statement); return false}
		source.media_path, copied = database_file_path_for_runtime(stored_media_path)
		if !copied {delete_source_video(&source); sqlite3_finalize(statement); return false}
		source.duration = sqlite3_column_double(statement, 5)
		source.metadata_status = Source_Metadata_Status(sqlite3_column_int(statement, 6))
		source.metadata.width = int(sqlite3_column_int(statement, 7)); source.metadata.height = int(sqlite3_column_int(statement, 8)); source.metadata.fps = sqlite3_column_double(statement, 9)
		source.metadata.vcodec, copied = sqlite_column_string(statement, 10); if !copied {delete_source_video(&source); sqlite3_finalize(statement); return false}
		source.metadata.acodec, copied = sqlite_column_string(statement, 11); if !copied {delete_source_video(&source); sqlite3_finalize(statement); return false}
		source.metadata.ext, copied = sqlite_column_string(statement, 12); if !copied {delete_source_video(&source); sqlite3_finalize(statement); return false}
		source.metadata.format_id, copied = sqlite_column_string(statement, 13); if !copied {delete_source_video(&source); sqlite3_finalize(statement); return false}
		source.metadata.filesize_approx = sqlite3_column_int64(statement, 14)
		source.media_available = os.exists(source.media_path)
		append(&sources, source)
	}
	sqlite3_finalize(statement)

	statement, ok = sqlite_prepare(database, `
		SELECT transcript.id, transcript.source_id, transcript.start_seconds,
		       transcript.duration_seconds, transcript.text
		FROM transcript_segments AS transcript
		JOIN sources AS source ON source.id = transcript.source_id
		ORDER BY source.position, transcript.position
	`)
	if !ok {return false}
	for sqlite3_step(statement) == SQLITE_ROW {
		segment := Transcript_Segment{start_seconds=sqlite3_column_double(statement, 2), duration_seconds=sqlite3_column_double(statement, 3)}
		segment.id, _ = sqlite_column_string(statement, 0, context.temp_allocator)
		segment.source_id, _ = sqlite_column_string(statement, 1, context.temp_allocator)
		segment.text, _ = sqlite_column_string(statement, 4, context.temp_allocator)
		if !transcript_append_copy(&transcripts, segment) {sqlite3_finalize(statement); return false}
	}
	sqlite3_finalize(statement)

	statement, ok = sqlite_prepare(database, "SELECT source_id, seconds FROM import_hints ORDER BY position")
	if !ok {return false}
	for sqlite3_step(statement) == SQLITE_ROW {
		source_id, copied := sqlite_column_string(statement, 0); if !copied {sqlite3_finalize(statement); return false}
		append(&hints, Import_Hint{source_id=source_id, seconds=sqlite3_column_double(statement, 1)})
	}
	sqlite3_finalize(statement)

	statement, ok = sqlite_prepare(database, "SELECT id, source_id, name, start_seconds, end_seconds, clip_path FROM exercises ORDER BY position")
	if !ok {return false}
	for sqlite3_step(statement) == SQLITE_ROW {
		exercise := Exercise{start_seconds=sqlite3_column_double(statement, 3), end_seconds=sqlite3_column_double(statement, 4)}
		copied: bool
		exercise.id, copied = sqlite_column_string(statement, 0); if !copied {sqlite3_finalize(statement); return false}
		exercise.source_id, copied = sqlite_column_string(statement, 1); if !copied {delete_exercise(&exercise); sqlite3_finalize(statement); return false}
		exercise.name, copied = sqlite_column_string(statement, 2); if !copied {delete_exercise(&exercise); sqlite3_finalize(statement); return false}
		stored_clip_path, stored_clip_path_copied := sqlite_column_string(statement, 5, context.temp_allocator)
		if !stored_clip_path_copied {delete_exercise(&exercise); sqlite3_finalize(statement); return false}
		exercise.clip_path, copied = database_file_path_for_runtime(stored_clip_path)
		if !copied {delete_exercise(&exercise); sqlite3_finalize(statement); return false}
		append(&exercises, exercise)
	}
	sqlite3_finalize(statement)

	destination.sources = sources; destination.hints = hints; destination.exercises = exercises; destination.transcripts = transcripts
	loaded = true
	return true
}

save_library :: proc() -> bool {
	if library_legacy_fallback {return save_legacy_library()}
	return database_save_state(library_database)
}

load_library :: proc() {
	os.make_directory(app_support_dir())
	database: ^SQLite_DB
	path := database_path()
	c_path := strings.clone_to_cstring(path)
	defer delete(c_path)
	if sqlite3_open_v2(c_path, &database, SQLITE_OPEN_READWRITE|SQLITE_OPEN_CREATE, nil) != SQLITE_OK {
		if database != nil {sqlite3_close(database)}
		library_legacy_fallback = true
		load_legacy_library()
		return
	}
	library_database = database
	if !database_create_schema(database) {
		library_legacy_fallback = true
		load_legacy_library()
		return
	}
	legacy_exists := os.exists(manifest_path())
	if legacy_exists {
		load_legacy_library()
		if !database_save_state(database) || !database_state_counts_match(database) || !database_integrity_ok(database) {
			library_legacy_fallback = true
			return
		}
		_ = os.remove(manifest_path())
		return
	}
	_ = database_load_state(database, &state)
}

database_close :: proc() {
	if library_database != nil {sqlite3_close(library_database)}
	library_database = nil
}
