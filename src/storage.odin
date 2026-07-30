package main

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"
import "core:unicode/utf8"
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

PORTABLE_LIBRARY_FORMAT  :: "hw-video-clips-library"
PORTABLE_LIBRARY_VERSION :: 1
LEGACY_PORTABLE_LIBRARY_FORMAT :: "vocal-training-library"

Portable_Library_Scope :: enum {
	All,
	Vocal,
	Dancing,
}

portable_library_scope_name :: proc(scope: Portable_Library_Scope) -> string {
	switch scope {
	case .All: return "all"
	case .Vocal: return "vocal"
	case .Dancing: return "dancing"
	}
	return ""
}

portable_library_scope_from_name :: proc(
	value: string,
) -> (Portable_Library_Scope, bool) {
	switch value {
	case "all": return .All, true
	case "vocal": return .Vocal, true
	case "dancing": return .Dancing, true
	}
	return .All, false
}

Portable_Source :: struct {
	id:              string,
	workflow:        Workflow_Kind,
	video_id:        string,
	title:           string,
	url:             string,
	duration:        f64,
	metadata:        Source_Context_Metadata,
	metadata_status: Source_Metadata_Status,
}

Portable_Transcript_Segment :: struct {
	id:               string,
	source_id:        string,
	start_seconds:    f64,
	duration_seconds: f64,
	text:             string,
}

Portable_Import_Hint :: struct {
	source_id: string,
	seconds:   f64,
}

Portable_Clip :: struct {
	id:            string,
	source_id:     string,
	workflow:      Workflow_Kind,
	name:          string,
	start_seconds: f64,
	end_seconds:   f64,
	dance_mirrored: bool,
	dance_loop: bool,
	dance_count_in_beats: int,
	dance_count_each_loop: bool,
	dance_count_in_bpm: int,
	dance_playback_rate: f32,
}

Portable_Library :: struct {
	format:           string,
	version:          int,
	scope:            string,
	exported_at_unix: i64,
	sources:          []Portable_Source,
	segments:         []Portable_Transcript_Segment,
	hints:            []Portable_Import_Hint,
	clips:            []Portable_Clip,
}

Legacy_Portable_Exercise :: struct {
	id:            string,
	source_id:     string,
	name:          string,
	start_seconds: f64,
	end_seconds:   f64,
}

Legacy_Portable_Library :: struct {
	format:           string,
	version:          int,
	exported_at_unix: i64,
	sources:          []Portable_Source,
	segments:         []Portable_Transcript_Segment,
	hints:            []Portable_Import_Hint,
	exercises:        []Legacy_Portable_Exercise,
}

Portable_Library_Error :: enum {
	None,
	Read,
	Decode,
	Format,
	Version,
	Identifier,
	Duplicate,
	Reference,
	Timestamp,
	Encode,
	Write,
	Database,
}

portable_library_error_text :: proc(value: Portable_Library_Error) -> string {
	switch value {
	case .None:       return ""
	case .Read:       return "Unable to read the library export"
	case .Decode:     return "The library export is not valid JSON"
	case .Format:     return "The selected file is not a hw_videoClips library export"
	case .Version:    return "This library export version is not supported"
	case .Identifier: return "The library export contains an unsafe identifier"
	case .Duplicate:  return "The library export contains duplicate records"
	case .Reference:  return "The library export contains a broken source reference"
	case .Timestamp:  return "The library export contains an invalid timestamp"
	case .Encode:     return "Unable to encode the library export"
	case .Write:      return "Unable to write the library export"
	case .Database:   return "Unable to replace the library database"
	}
	return "Unknown library export error"
}

portable_identifier_valid :: proc(value: string) -> bool {
	if len(value) == 0 {return false}
	for byte in value {
		if byte >= 'a' && byte <= 'z' ||
		   byte >= 'A' && byte <= 'Z' ||
		   byte >= '0' && byte <= '9' ||
		   byte == '-' || byte == '_' {
			continue
		}
		return false
	}
	return true
}

portable_seconds_valid :: proc(value: f64) -> bool {
	return !math.is_nan(value) && !math.is_inf(value) && value >= 0
}

portable_source_index :: proc(sources: []Portable_Source, id: string) -> int {
	for source, index in sources {
		if source.id == id {return index}
	}
	return -1
}

portable_library_validate :: proc(data: ^Portable_Library) -> Portable_Library_Error {
	if data.format != PORTABLE_LIBRARY_FORMAT {return .Format}
	if data.version != PORTABLE_LIBRARY_VERSION {return .Version}
	scope, scope_valid := portable_library_scope_from_name(data.scope)
	if !scope_valid {return .Format}
	for source, index in data.sources {
		if !portable_identifier_valid(source.id) ||
		   !portable_identifier_valid(source.video_id) {
			return .Identifier
		}
		if !portable_seconds_valid(source.duration) {return .Timestamp}
		switch source.workflow {
		case .Vocal, .Dancing:
		case: return .Format
		}
		if (scope == .Vocal && source.workflow != .Vocal) ||
		   (scope == .Dancing && source.workflow != .Dancing) {
			return .Format
		}
		for other in data.sources[index+1:] {
			if source.id == other.id ||
			   (source.workflow == other.workflow &&
			    source.video_id == other.video_id) {
				return .Duplicate
			}
		}
	}
	for segment, index in data.segments {
		if !portable_identifier_valid(segment.id) {return .Identifier}
		source_index := portable_source_index(data.sources, segment.source_id)
		if source_index < 0 {return .Reference}
		if !portable_seconds_valid(segment.start_seconds) ||
		   !portable_seconds_valid(segment.duration_seconds) ||
		   segment.start_seconds > data.sources[source_index].duration {
			return .Timestamp
		}
		for other in data.segments[index+1:] {
			if segment.id == other.id {return .Duplicate}
		}
	}
	for hint, index in data.hints {
		source_index := portable_source_index(data.sources, hint.source_id)
		if source_index < 0 {return .Reference}
		if !portable_seconds_valid(hint.seconds) ||
		   hint.seconds > data.sources[source_index].duration {
			return .Timestamp
		}
		for other in data.hints[index+1:] {
			if hint.source_id == other.source_id && hint.seconds == other.seconds {
				return .Duplicate
			}
		}
	}
	for clip, index in data.clips {
		if !portable_identifier_valid(clip.id) {return .Identifier}
		source_index := portable_source_index(data.sources, clip.source_id)
		if source_index < 0 {return .Reference}
		if clip.workflow != data.sources[source_index].workflow {
			return .Reference
		}
		if !portable_seconds_valid(clip.start_seconds) ||
		   !portable_seconds_valid(clip.end_seconds) ||
		   clip.end_seconds <= clip.start_seconds ||
		   clip.end_seconds > data.sources[source_index].duration {
			return .Timestamp
		}
		if clip.workflow == .Dancing &&
		   ((clip.dance_count_in_beats != 0 &&
		     clip.dance_count_in_beats != 4 &&
		     clip.dance_count_in_beats != 8) ||
		    clip.dance_count_in_bpm < 40 ||
		    clip.dance_count_in_bpm > 240 ||
		    clip.dance_playback_rate < 0.1 ||
		    clip.dance_playback_rate > 2) {
			return .Timestamp
		}
		for other in data.clips[index+1:] {
			if clip.id == other.id {return .Duplicate}
		}
	}
	return .None
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

load_download_metadata :: proc(
	video_id: string,
	workflow := Workflow_Kind.Vocal,
	allocator := context.allocator,
) -> (YTDLP_Metadata, bool) {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD(ignore=context.temp_allocator == allocator)
	path := fmt.tprintf("%s/%s.info.json", workflow_source_directory(workflow), video_id)
	bytes, ok := os.read_entire_file(path, context.temp_allocator)
	if !ok { return {}, false }
	metadata: YTDLP_Metadata
	if err := json.unmarshal(bytes, &metadata, .JSON, allocator); err != nil { return {}, false }
	return metadata, true
}

load_source_context_metadata :: proc(
	video_id: string,
	workflow := Workflow_Kind.Vocal,
	allocator := context.allocator,
) -> (Source_Context_Metadata, bool) {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD(ignore=context.temp_allocator == allocator)
	path := fmt.tprintf("%s/%s.info.json", workflow_source_directory(workflow), video_id)
	bytes, ok := os.read_entire_file(path, context.temp_allocator)
	if !ok { return {}, false }
	metadata: Source_Context_Metadata
	if err := json.unmarshal(bytes, &metadata, .JSON, allocator); err != nil { return {}, false }
	return metadata, true
}

caption_path :: proc(source: ^Source_Video, allocator := context.temp_allocator) -> (string, bool) {
	directory := strings.clone(workflow_source_directory(source.workflow), allocator)
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
	source_start := len(generation.segments)
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
	if count > 0 {
		append(&generation.source_spans, Transcript_Source_Span{
			source_id=generation.segments[source_start].source_id,
			start=source_start,
			count=count,
		})
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
	clips: [dynamic]Clip,
}

manifest_path :: proc() -> string {
	return fmt.tprintf("%s/library.json", app_support_dir())
}

save_legacy_library_state :: proc(value: ^App_State) -> bool {
	if value == nil {return false}
	scratch, ok := growing_arena_create()
	if !ok { return false }
	defer growing_arena_destroy(scratch)
	allocator := mem_virtual.arena_allocator(scratch)
	data := Persisted_State{
		version = 1,
		sources = value.sources,
		segments = value.transcripts.segments,
		hints = value.hints,
		clips = value.clips,
	}
	encoded, err := json.marshal(data, {pretty=true, use_spaces=true, spaces=2}, allocator)
	if err != nil { return false }
	os.make_directory(app_support_dir())
	return os.write_entire_file(manifest_path(), encoded)
}

save_legacy_library :: proc() -> bool {
	return save_legacy_library_state(&state)
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
	clips := make([dynamic]Clip, 0, len(data.clips))
	transcripts: Transcript_Generation
	copied: bool
	loaded := false
	defer {
		if !loaded {
			for &source in sources { delete_source_video(&source) }
			for &hint in hints { delete_import_hint(&hint) }
			for &clip in clips { delete_clip(&clip) }
			delete(sources)
			delete(hints)
			delete(clips)
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
	for clip in data.clips {
		copy, copied := clone_clip(clip)
		if !copied { return }
		append(&clips, copy)
	}
	transcripts, copied = transcript_generation_copy(data.segments[:])
	if !copied { return }

	state.sources = sources
	state.hints = hints
	state.clips = clips
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

database_create_schema_v6 :: proc(database: ^SQLite_DB) -> bool {
	return sqlite_execute(database, `
		PRAGMA foreign_keys = ON;
		CREATE TABLE IF NOT EXISTS sources (
			id TEXT PRIMARY KEY,
			workflow INTEGER NOT NULL,
			video_id TEXT NOT NULL,
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
			file_size INTEGER NOT NULL DEFAULT 0,
			UNIQUE(workflow, video_id)
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
		CREATE TABLE IF NOT EXISTS clips (
			id TEXT PRIMARY KEY,
			source_id TEXT NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
			workflow INTEGER NOT NULL,
			name TEXT NOT NULL,
			start_seconds REAL NOT NULL,
			end_seconds REAL NOT NULL,
			clip_path TEXT NOT NULL,
			position INTEGER NOT NULL,
			dance_mirrored INTEGER NOT NULL DEFAULT 0,
			dance_loop INTEGER NOT NULL DEFAULT 0,
			dance_count_in_beats INTEGER NOT NULL DEFAULT 0,
			dance_count_each_loop INTEGER NOT NULL DEFAULT 0,
			dance_count_in_bpm INTEGER NOT NULL DEFAULT 120,
			dance_playback_rate REAL NOT NULL DEFAULT 1.0
		);
		CREATE TABLE IF NOT EXISTS notifications (
			id INTEGER PRIMARY KEY AUTOINCREMENT,
			created_at_ms INTEGER NOT NULL,
			updated_at_ms INTEGER NOT NULL,
			kind INTEGER NOT NULL,
			summary TEXT NOT NULL,
			detail TEXT NOT NULL,
			context_json TEXT NOT NULL DEFAULT '[]',
			action_kind INTEGER NOT NULL DEFAULT 0,
			action_target TEXT NOT NULL DEFAULT ''
		);
		CREATE INDEX IF NOT EXISTS notifications_updated_at
			ON notifications(updated_at_ms);
		CREATE TABLE IF NOT EXISTS app_preferences (
			key TEXT PRIMARY KEY,
			value TEXT NOT NULL
		);
		CREATE TABLE IF NOT EXISTS clip_randomization (
			clip_id TEXT PRIMARY KEY,
			last_sequence INTEGER NOT NULL
		);
		CREATE TABLE IF NOT EXISTS library_meta (
			id INTEGER PRIMARY KEY CHECK (id = 1),
			current_revision INTEGER NOT NULL
		);
		CREATE TABLE IF NOT EXISTS library_revisions (
			revision INTEGER PRIMARY KEY,
			committed_at_ms INTEGER NOT NULL
		);
		CREATE TABLE IF NOT EXISTS library_changes (
			revision INTEGER NOT NULL REFERENCES library_revisions(revision)
				ON DELETE CASCADE,
			entity_kind INTEGER NOT NULL,
			entity_id TEXT NOT NULL,
			numeric_key INTEGER NOT NULL DEFAULT 0,
			operation INTEGER NOT NULL,
			PRIMARY KEY (
				revision, entity_kind, entity_id, numeric_key
			)
		);
		INSERT OR IGNORE INTO library_meta (id, current_revision) VALUES (1, 1);
		INSERT OR IGNORE INTO library_revisions (
			revision, committed_at_ms
		) VALUES (1, 0);
		PRAGMA user_version = 6;
	`)
}

database_migrate_v5_to_v6 :: proc(database: ^SQLite_DB) -> bool {
	if !sqlite_execute(database, "PRAGMA foreign_keys = OFF; BEGIN IMMEDIATE;") {
		return false
	}
	migrated := sqlite_execute(database, `
		CREATE TABLE sources_v6 (
			id TEXT PRIMARY KEY,
			workflow INTEGER NOT NULL,
			video_id TEXT NOT NULL,
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
			file_size INTEGER NOT NULL DEFAULT 0,
			UNIQUE(workflow, video_id)
		);
		INSERT INTO sources_v6 (
			id, workflow, video_id, title, url, media_path, duration, position,
			metadata_status, width, height, fps, video_codec, audio_codec,
			container, format_id, file_size
		)
		SELECT
			id, 0, video_id, title, url, media_path, duration, position,
			metadata_status, width, height, fps, video_codec, audio_codec,
			container, format_id, file_size
		FROM sources;

		CREATE TABLE transcript_segments_v6 (
			id TEXT PRIMARY KEY,
			source_id TEXT NOT NULL REFERENCES sources_v6(id) ON DELETE CASCADE,
			start_seconds REAL NOT NULL,
			duration_seconds REAL NOT NULL,
			text TEXT NOT NULL,
			position INTEGER NOT NULL
		);
		INSERT INTO transcript_segments_v6
		SELECT id, source_id, start_seconds, duration_seconds, text, position
		FROM transcript_segments;

		CREATE TABLE import_hints_v6 (
			source_id TEXT NOT NULL REFERENCES sources_v6(id) ON DELETE CASCADE,
			seconds REAL NOT NULL,
			position INTEGER NOT NULL,
			PRIMARY KEY(source_id, seconds)
		);
		INSERT INTO import_hints_v6
		SELECT source_id, seconds, position FROM import_hints;

		CREATE TABLE clips_v6 (
			id TEXT PRIMARY KEY,
			source_id TEXT NOT NULL REFERENCES sources_v6(id) ON DELETE CASCADE,
			workflow INTEGER NOT NULL,
			name TEXT NOT NULL,
			start_seconds REAL NOT NULL,
			end_seconds REAL NOT NULL,
			clip_path TEXT NOT NULL,
			position INTEGER NOT NULL,
			dance_mirrored INTEGER NOT NULL DEFAULT 0,
			dance_loop INTEGER NOT NULL DEFAULT 0,
			dance_count_in_beats INTEGER NOT NULL DEFAULT 0,
			dance_count_each_loop INTEGER NOT NULL DEFAULT 0,
			dance_count_in_bpm INTEGER NOT NULL DEFAULT 120,
			dance_playback_rate REAL NOT NULL DEFAULT 1.0
		);
		INSERT INTO clips_v6 (
			id, source_id, workflow, name, start_seconds, end_seconds,
			clip_path, position
		)
		SELECT
			id, source_id, 0, name, start_seconds, end_seconds, clip_path,
			position
		FROM exercises;

		CREATE TABLE clip_randomization_v6 (
			clip_id TEXT PRIMARY KEY,
			last_sequence INTEGER NOT NULL
		);
		INSERT INTO clip_randomization_v6
		SELECT exercise_id, last_sequence FROM exercise_randomization;

		DROP TABLE exercise_randomization;
		DROP TABLE exercises;
		DROP TABLE import_hints;
		DROP TABLE transcript_segments;
		DROP TABLE sources;

		ALTER TABLE sources_v6 RENAME TO sources;
		ALTER TABLE transcript_segments_v6 RENAME TO transcript_segments;
		ALTER TABLE import_hints_v6 RENAME TO import_hints;
		ALTER TABLE clips_v6 RENAME TO clips;
		ALTER TABLE clip_randomization_v6 RENAME TO clip_randomization;
		PRAGMA user_version = 6;
		COMMIT;
	`)
	if !migrated {
		_ = sqlite_execute(database, "ROLLBACK; PRAGMA foreign_keys = ON;")
		return false
	}
	return sqlite_execute(
		database,
		"PRAGMA foreign_keys = ON; PRAGMA foreign_key_check;",
	)
}

database_prepare_legacy_schema_for_v6 :: proc(database: ^SQLite_DB) -> bool {
	return sqlite_execute(database, `
		CREATE TABLE IF NOT EXISTS notifications (
			id INTEGER PRIMARY KEY AUTOINCREMENT,
			created_at_ms INTEGER NOT NULL,
			updated_at_ms INTEGER NOT NULL,
			kind INTEGER NOT NULL,
			summary TEXT NOT NULL,
			detail TEXT NOT NULL,
			context_json TEXT NOT NULL DEFAULT '[]',
			action_kind INTEGER NOT NULL DEFAULT 0,
			action_target TEXT NOT NULL DEFAULT ''
		);
		CREATE INDEX IF NOT EXISTS notifications_updated_at
			ON notifications(updated_at_ms);
		CREATE TABLE IF NOT EXISTS app_preferences (
			key TEXT PRIMARY KEY,
			value TEXT NOT NULL
		);
		CREATE TABLE IF NOT EXISTS exercise_randomization (
			exercise_id TEXT PRIMARY KEY,
			last_sequence INTEGER NOT NULL
		);
		CREATE TABLE IF NOT EXISTS library_meta (
			id INTEGER PRIMARY KEY CHECK (id = 1),
			current_revision INTEGER NOT NULL
		);
		CREATE TABLE IF NOT EXISTS library_revisions (
			revision INTEGER PRIMARY KEY,
			committed_at_ms INTEGER NOT NULL
		);
		CREATE TABLE IF NOT EXISTS library_changes (
			revision INTEGER NOT NULL REFERENCES library_revisions(revision)
				ON DELETE CASCADE,
			entity_kind INTEGER NOT NULL,
			entity_id TEXT NOT NULL,
			numeric_key INTEGER NOT NULL DEFAULT 0,
			operation INTEGER NOT NULL,
			PRIMARY KEY (
				revision, entity_kind, entity_id, numeric_key
			)
		);
		INSERT OR IGNORE INTO library_meta (id, current_revision) VALUES (1, 1);
		INSERT OR IGNORE INTO library_revisions (
			revision, committed_at_ms
		) VALUES (1, 0);
	`)
}

database_create_schema :: proc(database: ^SQLite_DB) -> bool {
	version, version_read := library_database_user_version(database)
	if !version_read {return false}
	if version > 0 && version < 6 {
		if !database_prepare_legacy_schema_for_v6(database) {return false}
		if !database_migrate_v5_to_v6(database) {return false}
		version = 6
	}
	if version != 0 && version != LIBRARY_SCHEMA_VERSION {return false}
	return database_create_schema_v6(database)
}

database_source_auth_browser_load :: proc(
	database: ^SQLite_DB,
) -> Source_Auth_Browser {
	if database == nil {return .None}
	statement, ok := sqlite_prepare(
		database,
		"SELECT value FROM app_preferences WHERE key = 'youtube_auth_browser'",
	)
	if !ok {return .None}
	defer sqlite3_finalize(statement)
	if sqlite3_step(statement) != SQLITE_ROW {return .None}
	value := sqlite3_column_text(statement, 0)
	if value == nil {return .None}
	return source_auth_browser_from_argument(string(value))
}

database_source_auth_browser_save :: proc(
	database: ^SQLite_DB,
	browser: Source_Auth_Browser,
) -> bool {
	if database == nil || browser == .None {return false}
	statement, ok := sqlite_prepare(
		database,
		`INSERT INTO app_preferences (key, value)
		 VALUES ('youtube_auth_browser', ?)
		 ON CONFLICT(key) DO UPDATE SET value = excluded.value`,
	)
	if !ok {return false}
	defer sqlite3_finalize(statement)
	return sqlite_bind_text_value(
		statement,
		1,
		source_auth_browser_argument(browser),
	) && sqlite3_step(statement) == SQLITE_DONE
}

database_source_auth_browser_clear :: proc(database: ^SQLite_DB) -> bool {
	if database == nil {return false}
	return sqlite_execute(
		database,
		"DELETE FROM app_preferences WHERE key = 'youtube_auth_browser'",
	)
}

database_interface_theme_load :: proc(database: ^SQLite_DB) -> bool {
	if database == nil {return true}
	statement, ok := sqlite_prepare(
		database,
		"SELECT value FROM app_preferences WHERE key = 'interface_theme'",
	)
	if !ok {return true}
	defer sqlite3_finalize(statement)
	if sqlite3_step(statement) != SQLITE_ROW {return true}
	value := sqlite3_column_text(statement, 0)
	return value == nil || string(value) == "dark"
}

database_interface_theme_save :: proc(
	database: ^SQLite_DB,
	dark_theme: bool,
) -> bool {
	if database == nil {return false}
	statement, ok := sqlite_prepare(
		database,
		`INSERT INTO app_preferences (key, value)
		 VALUES ('interface_theme', ?)
		 ON CONFLICT(key) DO UPDATE SET value = excluded.value`,
	)
	if !ok {return false}
	defer sqlite3_finalize(statement)
	value := dark_theme ? "dark" : "light"
	return sqlite_bind_text_value(statement, 1, value) &&
	       sqlite3_step(statement) == SQLITE_DONE
}

Active_View_Preference :: struct {
	workflow: Workflow_Kind,
	mode: UI_Mode,
}

active_view_preference_default :: proc() -> Active_View_Preference {
	return {workflow = .Vocal, mode = .Create}
}

active_view_preference_decode :: proc(
	value: string,
) -> (Active_View_Preference, bool) {
	switch value {
	case "vocal:sources":
		return {workflow = .Vocal, mode = .Create}, true
	case "vocal:clips":
		return {workflow = .Vocal, mode = .Play}, true
	case "dancing:sources":
		return {workflow = .Dancing, mode = .Create}, true
	case "dancing:clips":
		return {workflow = .Dancing, mode = .Play}, true
	}
	return active_view_preference_default(), false
}

active_view_preference_encode :: proc(
	preference: Active_View_Preference,
) -> (string, bool) {
	switch preference.workflow {
	case .Vocal:
		switch preference.mode {
		case .Create: return "vocal:sources", true
		case .Play: return "vocal:clips", true
		}
	case .Dancing:
		switch preference.mode {
		case .Create: return "dancing:sources", true
		case .Play: return "dancing:clips", true
		}
	}
	return "", false
}

database_active_view_load :: proc(
	database: ^SQLite_DB,
) -> Active_View_Preference {
	defaults := active_view_preference_default()
	if database == nil {return defaults}
	statement, ok := sqlite_prepare(
		database,
		"SELECT value FROM app_preferences WHERE key = 'active_view'",
	)
	if !ok {return defaults}
	defer sqlite3_finalize(statement)
	if sqlite3_step(statement) != SQLITE_ROW {return defaults}
	value := sqlite3_column_text(statement, 0)
	if value == nil {return defaults}
	preference, valid := active_view_preference_decode(string(value))
	if !valid {return defaults}
	return preference
}

database_active_view_save :: proc(
	database: ^SQLite_DB,
	preference: Active_View_Preference,
) -> bool {
	if database == nil {return false}
	value, valid := active_view_preference_encode(preference)
	if !valid {return false}
	statement, ok := sqlite_prepare(
		database,
		`INSERT INTO app_preferences (key, value)
		 VALUES ('active_view', ?)
		 ON CONFLICT(key) DO UPDATE SET value = excluded.value`,
	)
	if !ok {return false}
	defer sqlite3_finalize(statement)
	return sqlite_bind_text_value(statement, 1, value) &&
	       sqlite3_step(statement) == SQLITE_DONE
}

database_vocal_playback_rate_load :: proc(database: ^SQLite_DB) -> f32 {
	if database == nil {return 1}
	statement, ok := sqlite_prepare(
		database,
		"SELECT value FROM app_preferences WHERE key = 'vocal_playback_rate'",
	)
	if !ok {return 1}
	defer sqlite3_finalize(statement)
	if sqlite3_step(statement) != SQLITE_ROW {return 1}
	value := sqlite3_column_double(statement, 0)
	if value < 0.1 || value > 2 {return 1}
	return f32(value)
}

database_vocal_playback_rate_save :: proc(
	database: ^SQLite_DB,
	value: f32,
) -> bool {
	if database == nil || value < 0.1 || value > 2 {return false}
	statement, ok := sqlite_prepare(
		database,
		`INSERT INTO app_preferences (key, value)
		 VALUES ('vocal_playback_rate', ?)
		 ON CONFLICT(key) DO UPDATE SET value = excluded.value`,
	)
	if !ok {return false}
	defer sqlite3_finalize(statement)
	return sqlite3_bind_double(statement, 1, f64(value)) == SQLITE_OK &&
	       sqlite3_step(statement) == SQLITE_DONE
}

database_flash_leader_load :: proc(
	database: ^SQLite_DB,
	allocator := context.allocator,
) -> (string, bool) {
	if database == nil {return "", false}
	statement, ok := sqlite_prepare(
		database,
		"SELECT value FROM app_preferences WHERE key = 'flash_leader'",
	)
	if !ok {return "", false}
	defer sqlite3_finalize(statement)
	if sqlite3_step(statement) != SQLITE_ROW {return "", false}
	value := sqlite3_column_text(statement, 0)
	if value == nil {return "", false}
	return strings.clone(string(value), allocator), true
}

database_flash_leader_save :: proc(
	database: ^SQLite_DB,
	value: string,
) -> bool {
	if database == nil {return false}
	statement, ok := sqlite_prepare(
		database,
		`INSERT INTO app_preferences (key, value)
		 VALUES ('flash_leader', ?)
		 ON CONFLICT(key) DO UPDATE SET value = excluded.value`,
	)
	if !ok {return false}
	defer sqlite3_finalize(statement)
	return sqlite_bind_text_value(statement, 1, value) &&
	       sqlite3_step(statement) == SQLITE_DONE
}

database_pitch_settings_load :: proc(
	database: ^SQLite_DB,
) -> Pitch_Settings {
	defaults := pitch_default_settings()
	if database == nil {return defaults}
	statement, ok := sqlite_prepare(
		database,
		"SELECT value FROM app_preferences WHERE key = 'pitch_settings'",
	)
	if !ok {return defaults}
	defer sqlite3_finalize(statement)
	if sqlite3_step(statement) != SQLITE_ROW {return defaults}
	value := sqlite3_column_text(statement, 0)
	if value == nil {return defaults}
	settings, valid := pitch_settings_decode(string(value))
	if !valid {return defaults}
	return settings
}

database_pitch_settings_save :: proc(
	database: ^SQLite_DB,
	settings: Pitch_Settings,
) -> bool {
	if database == nil || !pitch_settings_valid(settings) {return false}
	statement, ok := sqlite_prepare(
		database,
		`INSERT INTO app_preferences (key, value)
		 VALUES ('pitch_settings', ?)
		 ON CONFLICT(key) DO UPDATE SET value = excluded.value`,
	)
	if !ok {return false}
	defer sqlite3_finalize(statement)
	value := pitch_settings_encode(settings)
	return sqlite_bind_text_value(statement, 1, value) &&
	       sqlite3_step(statement) == SQLITE_DONE
}

database_clip_randomization_save :: proc(
	database: ^SQLite_DB,
	clip_id: string,
	last_sequence: i64,
) -> bool {
	if database == nil || len(clip_id) == 0 || last_sequence <= 0 {
		return false
	}
	statement, ok := sqlite_prepare(
		database,
		`INSERT INTO clip_randomization (clip_id, last_sequence)
		 VALUES (?, ?)
		 ON CONFLICT(clip_id) DO UPDATE
		 SET last_sequence = excluded.last_sequence`,
	)
	if !ok {return false}
	defer sqlite3_finalize(statement)
	return sqlite_bind_text_value(statement, 1, clip_id) &&
	       sqlite3_bind_int64(statement, 2, last_sequence) == SQLITE_OK &&
	       sqlite3_step(statement) == SQLITE_DONE
}

database_clip_randomization_apply :: proc(
	database: ^SQLite_DB,
	clips: []Clip,
) -> bool {
	if database == nil {return false}
	statement, ok := sqlite_prepare(
		database,
		`SELECT last_sequence
		 FROM clip_randomization
		 WHERE clip_id = ?`,
	)
	if !ok {return false}
	defer sqlite3_finalize(statement)
	for &clip in clips {
		clip.last_randomized_sequence = 0
		if sqlite3_reset(statement) != SQLITE_OK {return false}
		if !sqlite_bind_text_value(statement, 1, clip.id) {return false}
		if sqlite3_step(statement) == SQLITE_ROW {
			clip.last_randomized_sequence =
				sqlite3_column_int64(statement, 0)
		}
	}
	return true
}

database_insert_source :: proc(database: ^SQLite_DB, source: Source_Video, position: int) -> bool {
	statement, ok := sqlite_prepare(
		database,
		`INSERT INTO sources (
			id, workflow, video_id, title, url, media_path, duration, position,
			metadata_status, width, height, fps, video_codec, audio_codec,
			container, format_id, file_size
		) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
	)
	if !ok {return false}
	defer sqlite3_finalize(statement)
	return sqlite_bind_text_value(statement, 1, source.id) &&
		sqlite3_bind_int(statement, 2, i32(source.workflow)) == SQLITE_OK &&
		sqlite_bind_text_value(statement, 3, source.video_id) &&
		sqlite_bind_text_value(statement, 4, source.title) &&
		sqlite_bind_text_value(statement, 5, source.url) &&
		sqlite_bind_text_value(statement, 6, database_file_path_for_storage(source.media_path)) &&
		sqlite3_bind_double(statement, 7, source.duration) == SQLITE_OK &&
		sqlite3_bind_int(statement, 8, i32(position)) == SQLITE_OK &&
		sqlite3_bind_int(statement, 9, i32(source.metadata_status)) == SQLITE_OK &&
		sqlite3_bind_int(statement, 10, i32(source.metadata.width)) == SQLITE_OK &&
		sqlite3_bind_int(statement, 11, i32(source.metadata.height)) == SQLITE_OK &&
		sqlite3_bind_double(statement, 12, source.metadata.fps) == SQLITE_OK &&
		sqlite_bind_text_value(statement, 13, source.metadata.vcodec) &&
		sqlite_bind_text_value(statement, 14, source.metadata.acodec) &&
		sqlite_bind_text_value(statement, 15, source.metadata.ext) &&
		sqlite_bind_text_value(statement, 16, source.metadata.format_id) &&
		sqlite3_bind_int64(statement, 17, source.metadata.filesize_approx) == SQLITE_OK &&
		sqlite3_step(statement) == SQLITE_DONE
}

database_save_collections :: proc(
	database: ^SQLite_DB,
	sources: []Source_Video,
	segments: []Transcript_Segment,
	hints: []Import_Hint,
	clips: []Clip,
) -> bool {
	if database == nil {return false}
	previous: App_State
	load_result := database_load_state_result(database, &previous)
	defer library_load_result_destroy(&load_result)
	if load_result.mode != .Ready {return false}
	defer app_state_collections_destroy(&previous)
	candidate, candidate_copied := app_state_collections_copy(
		sources,
		segments,
		hints,
		clips,
	)
	if !candidate_copied {return false}
	defer app_state_collections_destroy(&candidate)
	if !library_state_valid(&candidate) {return false}
	if !sqlite_execute(database, "BEGIN IMMEDIATE") {return false}
	committed := false
	defer if !committed {sqlite_execute(database, "ROLLBACK")}
	if _, revision_recorded := library_revision_record_changes(
		database,
		&previous,
		&candidate,
	); !revision_recorded {
		return false
	}
	if !sqlite_execute(database, "DELETE FROM transcript_segments; DELETE FROM import_hints; DELETE FROM clips; DELETE FROM sources;") {return false}
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
	for clip, position in clips {
		statement, ok := sqlite_prepare(
			database,
			`INSERT INTO clips (
				id, source_id, workflow, name, start_seconds, end_seconds,
				clip_path, position, dance_mirrored, dance_loop,
				dance_count_in_beats, dance_count_each_loop,
				dance_count_in_bpm, dance_playback_rate
			) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		)
		if !ok {return false}
		bound := sqlite_bind_text_value(statement, 1, clip.id) &&
			sqlite_bind_text_value(statement, 2, clip.source_id) &&
			sqlite3_bind_int(statement, 3, i32(clip.workflow)) == SQLITE_OK &&
			sqlite_bind_text_value(statement, 4, clip.name) &&
			sqlite3_bind_double(statement, 5, clip.start_seconds) == SQLITE_OK &&
			sqlite3_bind_double(statement, 6, clip.end_seconds) == SQLITE_OK &&
			sqlite_bind_text_value(statement, 7, database_file_path_for_storage(clip.clip_path)) &&
			sqlite3_bind_int(statement, 8, i32(position)) == SQLITE_OK &&
			sqlite3_bind_int(statement, 9, clip.dance_mirrored ? 1 : 0) == SQLITE_OK &&
			sqlite3_bind_int(statement, 10, clip.dance_loop ? 1 : 0) == SQLITE_OK &&
			sqlite3_bind_int(statement, 11, i32(clip.dance_count_in_beats)) == SQLITE_OK &&
			sqlite3_bind_int(statement, 12, clip.dance_count_each_loop ? 1 : 0) == SQLITE_OK &&
			sqlite3_bind_int(statement, 13, i32(clip.dance_count_in_bpm)) == SQLITE_OK &&
			sqlite3_bind_double(statement, 14, f64(clip.dance_playback_rate)) == SQLITE_OK
		stepped := bound && sqlite3_step(statement) == SQLITE_DONE
		sqlite3_finalize(statement)
		if !stepped {return false}
	}
	if !sqlite_execute(
		database,
		`DELETE FROM clip_randomization
		 WHERE clip_id NOT IN (SELECT id FROM clips)`,
	) {
		return false
	}
	if !database_clip_randomization_apply(database, clips) {
		return false
	}
	if !sqlite_execute(database, "COMMIT") {return false}
	committed = true
	return true
}

database_save_state :: proc(database: ^SQLite_DB) -> bool {
	return database_save_collections(database, state.sources[:], state.transcripts.segments[:], state.hints[:], state.clips[:])
}

portable_scope_includes_workflow :: proc(
	scope: Portable_Library_Scope,
	workflow: Workflow_Kind,
) -> bool {
	return scope == .All ||
	       (scope == .Vocal && workflow == .Vocal) ||
	       (scope == .Dancing && workflow == .Dancing)
}

source_workflow_for_id :: proc(
	sources: []Source_Video,
	source_id: string,
) -> (Workflow_Kind, bool) {
	for source in sources {
		if source.id == source_id {return source.workflow, true}
	}
	return .Vocal, false
}

portable_library_from_state :: proc(
	scope := Portable_Library_Scope.All,
	allocator := context.allocator,
) -> (Portable_Library, bool) {
	source_count, segment_count, hint_count, clip_count := 0, 0, 0, 0
	for source in state.sources {
		if portable_scope_includes_workflow(scope, source.workflow) {
			source_count += 1
		}
	}
	for segment in state.transcripts.segments {
		if workflow, found := source_workflow_for_id(
			state.sources[:],
			segment.source_id,
		); found && portable_scope_includes_workflow(scope, workflow) {
			segment_count += 1
		}
	}
	for hint in state.hints {
		if workflow, found := source_workflow_for_id(
			state.sources[:],
			hint.source_id,
		); found && portable_scope_includes_workflow(scope, workflow) {
			hint_count += 1
		}
	}
	for clip in state.clips {
		if portable_scope_includes_workflow(scope, clip.workflow) {
			clip_count += 1
		}
	}
	sources, sources_error := make([]Portable_Source, source_count, allocator)
	if sources_error != nil {return {}, false}
	segments, segments_error := make([]Portable_Transcript_Segment, segment_count, allocator)
	if segments_error != nil {return {}, false}
	hints, hints_error := make([]Portable_Import_Hint, hint_count, allocator)
	if hints_error != nil {return {}, false}
	clips, clips_error := make([]Portable_Clip, clip_count, allocator)
	if clips_error != nil {return {}, false}
	source_position, segment_position := 0, 0
	hint_position, clip_position := 0, 0
	for source in state.sources {
		if !portable_scope_includes_workflow(scope, source.workflow) {continue}
		sources[source_position] = Portable_Source {
			id = source.id,
			workflow = source.workflow,
			video_id = source.video_id,
			title = source.title,
			url = source.url,
			duration = source.duration,
			metadata = source.metadata,
			metadata_status = source.metadata_status,
		}
		source_position += 1
	}
	for segment in state.transcripts.segments {
		workflow, found := source_workflow_for_id(
			state.sources[:],
			segment.source_id,
		)
		if !found || !portable_scope_includes_workflow(scope, workflow) {continue}
		segments[segment_position] = Portable_Transcript_Segment {
			id = segment.id,
			source_id = segment.source_id,
			start_seconds = segment.start_seconds,
			duration_seconds = segment.duration_seconds,
			text = segment.text,
		}
		segment_position += 1
	}
	for hint in state.hints {
		workflow, found := source_workflow_for_id(
			state.sources[:],
			hint.source_id,
		)
		if !found || !portable_scope_includes_workflow(scope, workflow) {continue}
		hints[hint_position] = Portable_Import_Hint {
			source_id = hint.source_id,
			seconds = hint.seconds,
		}
		hint_position += 1
	}
	for clip in state.clips {
		if !portable_scope_includes_workflow(scope, clip.workflow) {continue}
		clips[clip_position] = Portable_Clip {
			id = clip.id,
			source_id = clip.source_id,
			workflow = clip.workflow,
			name = clip.name,
			start_seconds = clip.start_seconds,
			end_seconds = clip.end_seconds,
			dance_mirrored = clip.dance_mirrored,
			dance_loop = clip.dance_loop,
			dance_count_in_beats = clip.dance_count_in_beats,
			dance_count_each_loop = clip.dance_count_each_loop,
			dance_count_in_bpm = clip.dance_count_in_bpm,
			dance_playback_rate = clip.dance_playback_rate,
		}
		clip_position += 1
	}
	return Portable_Library {
		format = PORTABLE_LIBRARY_FORMAT,
		version = PORTABLE_LIBRARY_VERSION,
		scope = portable_library_scope_name(scope),
		exported_at_unix = time.to_unix_seconds(time.now()),
		sources = sources,
		segments = segments,
		hints = hints,
		clips = clips,
	}, true
}

portable_library_export :: proc(
	path: string,
	scope := Portable_Library_Scope.All,
) -> Portable_Library_Error {
	scratch, scratch_ok := growing_arena_create()
	if !scratch_ok {return .Encode}
	defer growing_arena_destroy(scratch)
	allocator := mem_virtual.arena_allocator(scratch)
	data, created := portable_library_from_state(scope, allocator)
	if !created {return .Encode}
	if validation_error := portable_library_validate(&data); validation_error != .None {
		return validation_error
	}
	encoded, encode_error := json.marshal(
		data,
		{pretty=true, use_spaces=true, spaces=2},
		allocator,
	)
	if encode_error != nil {return .Encode}
	temporary_path := fmt.aprintf("%s.tmp", path, allocator=allocator)
	_ = os.remove(temporary_path)
	if !os.write_entire_file(temporary_path, encoded) {return .Write}
	if !os.rename(temporary_path, path) {
		_ = os.remove(temporary_path)
		return .Write
	}
	return .None
}

Portable_Library_Header :: struct {
	format: string,
	version: int,
}

portable_library_read_scoped :: proc(
	path: string,
) -> (App_State, Portable_Library_Scope, Portable_Library_Error) {
	scratch, scratch_ok := growing_arena_create()
	if !scratch_ok {return {}, .All, .Decode}
	defer growing_arena_destroy(scratch)
	allocator := mem_virtual.arena_allocator(scratch)
	bytes, read_ok := os.read_entire_file(path, allocator)
	if !read_ok {return {}, .All, .Read}
	header: Portable_Library_Header
	if decode_error := json.unmarshal(bytes, &header, .JSON, allocator);
	   decode_error != nil {
		return {}, .All, .Decode
	}
	data: Portable_Library
	if header.format == LEGACY_PORTABLE_LIBRARY_FORMAT {
		legacy: Legacy_Portable_Library
		if decode_error := json.unmarshal(bytes, &legacy, .JSON, allocator);
		   decode_error != nil {
			return {}, .All, .Decode
		}
		if legacy.version != 1 {return {}, .All, .Version}
		clips, clips_error := make(
			[]Portable_Clip,
			len(legacy.exercises),
			allocator,
		)
		if clips_error != nil {return {}, .All, .Decode}
		for exercise, index in legacy.exercises {
			clips[index] = Portable_Clip{
				id=exercise.id,
				source_id=exercise.source_id,
				workflow=.Vocal,
				name=exercise.name,
				start_seconds=exercise.start_seconds,
				end_seconds=exercise.end_seconds,
				dance_count_in_bpm=120,
				dance_playback_rate=1,
			}
		}
		for &source in legacy.sources {source.workflow = .Vocal}
		data = Portable_Library{
			format=PORTABLE_LIBRARY_FORMAT,
			version=PORTABLE_LIBRARY_VERSION,
			scope=portable_library_scope_name(.Vocal),
			exported_at_unix=legacy.exported_at_unix,
			sources=legacy.sources,
			segments=legacy.segments,
			hints=legacy.hints,
			clips=clips,
		}
	} else {
		if decode_error := json.unmarshal(bytes, &data, .JSON, allocator);
		   decode_error != nil {
			return {}, .All, .Decode
		}
	}
	if validation_error := portable_library_validate(&data); validation_error != .None {
		return {}, .All, validation_error
	}
	scope, _ := portable_library_scope_from_name(data.scope)

	result: App_State
	result.sources = make([dynamic]Source_Video, 0, len(data.sources))
	result.hints = make([dynamic]Import_Hint, 0, len(data.hints))
	result.clips = make([dynamic]Clip, 0, len(data.clips))
	transcripts, transcripts_ok := transcript_generation_create(len(data.segments))
	if !transcripts_ok {
		app_state_collections_destroy(&result)
		return {}, .All, .Decode
	}
	result.transcripts = transcripts
	loaded := false
	defer if !loaded {app_state_collections_destroy(&result)}

	for source in data.sources {
		runtime_source := Source_Video {
			id = source.id,
			workflow = source.workflow,
			video_id = source.video_id,
			title = source.title,
			url = source.url,
			media_path = fmt.aprintf(
				"%s/%s.mp4",
				workflow_source_directory(source.workflow),
				source.video_id,
				allocator=allocator,
			),
			duration = source.duration,
			metadata = source.metadata,
			metadata_status = source.metadata_status,
		}
		copy, copied := clone_source_video(runtime_source)
		if !copied {return {}, .All, .Decode}
		copy.media_available = os.exists(copy.media_path)
		append(&result.sources, copy)
	}
	for hint in data.hints {
		copy, copied := clone_import_hint(Import_Hint{
			source_id = hint.source_id,
			seconds = hint.seconds,
		})
		if !copied {return {}, .All, .Decode}
		append(&result.hints, copy)
	}
	for clip in data.clips {
		runtime_clip := Clip {
			id = clip.id,
			source_id = clip.source_id,
			workflow = clip.workflow,
			name = clip.name,
			start_seconds = clip.start_seconds,
			end_seconds = clip.end_seconds,
			clip_path = fmt.aprintf(
				"%s/%s.mp4",
				workflow_clip_directory(clip.workflow),
				clip.id,
				allocator=allocator,
			),
			dance_mirrored = clip.dance_mirrored,
			dance_loop = clip.dance_loop,
			dance_count_in_beats = clip.dance_count_in_beats,
			dance_count_each_loop = clip.dance_count_each_loop,
			dance_count_in_bpm = clip.dance_count_in_bpm,
			dance_playback_rate = clip.dance_playback_rate,
		}
		copy, copied := clone_clip(runtime_clip)
		if !copied {return {}, .All, .Decode}
		append(&result.clips, copy)
	}
	for segment in data.segments {
		if !transcript_append_copy(&result.transcripts, Transcript_Segment{
			id = segment.id,
			source_id = segment.source_id,
			start_seconds = segment.start_seconds,
			duration_seconds = segment.duration_seconds,
			text = segment.text,
		}) {
			return {}, .All, .Decode
		}
	}
	loaded = true
	return result, scope, .None
}

portable_library_read :: proc(
	path: string,
) -> (App_State, Portable_Library_Error) {
	result, _, error := portable_library_read_scoped(path)
	return result, error
}

portable_library_install :: proc(
	imported: ^App_State,
	scope := Portable_Library_Scope.All,
	allow_without_backup := false,
) -> Portable_Library_Error {
	if library_database == nil || library_legacy_fallback {return .Database}
	candidate := imported
	merged: App_State
	if scope != .All {
		merged.sources = make([dynamic]Source_Video)
		merged.hints = make([dynamic]Import_Hint)
		merged.clips = make([dynamic]Clip)
		transcripts, transcript_ok := transcript_generation_create(
			len(state.transcripts.segments) +
			len(imported.transcripts.segments),
		)
		if !transcript_ok {
			app_state_collections_destroy(&merged)
			return .Database
		}
		merged.transcripts = transcripts
		merged_ready := false
		defer if !merged_ready {app_state_collections_destroy(&merged)}
		for source in state.sources {
			if portable_scope_includes_workflow(scope, source.workflow) {continue}
			copy, copied := clone_source_video(source)
			if !copied {return .Database}
			append(&merged.sources, copy)
		}
		for source in imported.sources {
			copy, copied := clone_source_video(source)
			if !copied {return .Database}
			append(&merged.sources, copy)
		}
		for segment in state.transcripts.segments {
			workflow, found := source_workflow_for_id(
				state.sources[:],
				segment.source_id,
			)
			if found && portable_scope_includes_workflow(scope, workflow) {
				continue
			}
			if !transcript_append_copy(&merged.transcripts, segment) {
				return .Database
			}
		}
		for segment in imported.transcripts.segments {
			if !transcript_append_copy(&merged.transcripts, segment) {
				return .Database
			}
		}
		for hint in state.hints {
			workflow, found := source_workflow_for_id(
				state.sources[:],
				hint.source_id,
			)
			if found && portable_scope_includes_workflow(scope, workflow) {
				continue
			}
			copy, copied := clone_import_hint(hint)
			if !copied {return .Database}
			append(&merged.hints, copy)
		}
		for hint in imported.hints {
			copy, copied := clone_import_hint(hint)
			if !copied {return .Database}
			append(&merged.hints, copy)
		}
		for clip in state.clips {
			if portable_scope_includes_workflow(scope, clip.workflow) {continue}
			copy, copied := clone_clip(clip)
			if !copied {return .Database}
			append(&merged.clips, copy)
		}
		for clip in imported.clips {
			copy, copied := clone_clip(clip)
			if !copied {return .Database}
			append(&merged.clips, copy)
		}
		candidate = &merged
		merged_ready = true
		defer app_state_collections_destroy(&merged)
	}
	if !commit_library_state(
		candidate,
		.Library_Replacement,
		allow_without_backup,
	) {
		return .Database
	}
	return .None
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
	clip_count, clip_ok := database_count(database, "clips"); if !clip_ok || clip_count != len(state.clips) {return false}
	return true
}

library_load_failure :: proc(
	database: ^SQLite_DB,
	stage: Library_Load_Stage,
	detail: string,
) -> Library_Load_Result {
	return {
		mode = .Recovery_Required,
		stage = stage,
		sqlite_code = database != nil ? int(sqlite3_extended_errcode(database)) : 0,
		detail = strings.clone(detail),
	}
}

library_load_result_destroy :: proc(result: ^Library_Load_Result) {
	if result == nil {return}
	delete(result.detail)
	result^ = {}
}

sqlite_column_required_string :: proc(
	statement: ^SQLite_Statement,
	index: int,
	allocator := context.allocator,
) -> (string, bool) {
	if sqlite3_column_type(statement, i32(index)) == SQLITE_NULL {return "", false}
	value := sqlite3_column_text(statement, i32(index))
	if value == nil {return "", false}
	text := string(value)
	if !utf8.valid_string(text) {return "", false}
	copy, error := strings.clone(text, allocator)
	return copy, error == nil
}

library_state_valid :: proc(value: ^App_State) -> bool {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	if value == nil {return false}
	index, indexed := library_state_index_build(value)
	if !indexed {return false}
	defer library_state_index_destroy(&index)
	for source in value.sources {
		if !portable_identifier_valid(source.id) ||
		   !portable_identifier_valid(source.video_id) ||
		   len(source.title) == 0 ||
		   len(source.url) == 0 ||
		   len(source.media_path) == 0 ||
		   !utf8.valid_string(source.title) ||
		   !utf8.valid_string(source.url) ||
		   !utf8.valid_string(source.media_path) ||
		   !utf8.valid_string(source.metadata.vcodec) ||
		   !utf8.valid_string(source.metadata.acodec) ||
		   !utf8.valid_string(source.metadata.ext) ||
		   !utf8.valid_string(source.metadata.format_id) ||
		   !portable_seconds_valid(source.duration) ||
		   !portable_seconds_valid(source.metadata.fps) ||
		   source.metadata.width < 0 ||
		   source.metadata.height < 0 ||
		   source.metadata.filesize_approx < 0 {
			return false
		}
		switch source.workflow {
		case .Vocal, .Dancing:
		case: return false
		}
		switch source.metadata_status {
		case .Missing, .Available, .Unavailable:
		case: return false
		}
	}
	for segment in value.transcripts.segments {
		if !portable_identifier_valid(segment.id) ||
		   !utf8.valid_string(segment.text) ||
		   !portable_seconds_valid(segment.start_seconds) ||
		   !portable_seconds_valid(segment.duration_seconds) {
			return false
		}
		source_index, source_found := index.sources[segment.source_id]
		if !source_found ||
		   segment.start_seconds > value.sources[source_index].duration {
			return false
		}
	}
	for hint in value.hints {
		source_index, source_found := index.sources[hint.source_id]
		if !source_found ||
		   !portable_seconds_valid(hint.seconds) ||
		   hint.seconds > value.sources[source_index].duration {
			return false
		}
	}
	for clip in value.clips {
		source_index, source_found := index.sources[clip.source_id]
		if !portable_identifier_valid(clip.id) ||
		   !source_found ||
		   clip.workflow != value.sources[source_index].workflow ||
		   len(clip.name) == 0 ||
		   !utf8.valid_string(clip.name) ||
		   !utf8.valid_string(clip.clip_path) ||
		   !valid_clip_range(
				clip.start_seconds,
				clip.end_seconds,
				value.sources[source_index].duration,
		   ) {
			return false
		}
		switch clip.workflow {
		case .Vocal:
		case .Dancing:
			if (clip.dance_count_in_beats != 0 &&
			    clip.dance_count_in_beats != 4 &&
			    clip.dance_count_in_beats != 8) ||
			   clip.dance_count_in_bpm < 40 ||
			   clip.dance_count_in_bpm > 240 ||
			   clip.dance_playback_rate < 0.1 ||
			   clip.dance_playback_rate > 2 {
				return false
			}
		case:
			return false
		}
	}
	return true
}

database_load_state_result :: proc(
	database: ^SQLite_DB,
	destination: ^App_State,
) -> Library_Load_Result {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	if database == nil || destination == nil {
		return library_load_failure(database, .Open, "The library database is not open")
	}
	sources := make([dynamic]Source_Video)
	hints := make([dynamic]Import_Hint)
	clips := make([dynamic]Clip)
	transcripts, transcript_ok := transcript_generation_create(256)
	if !transcript_ok {
		return library_load_failure(database, .Transcripts, "Unable to allocate transcript storage")
	}
	loaded := false
	defer if !loaded {
		for &source in sources {delete_source_video(&source)}
		for &hint in hints {delete_import_hint(&hint)}
		for &clip in clips {delete_clip(&clip)}
		delete(sources); delete(hints); delete(clips)
		transcript_generation_destroy(&transcripts)
	}

	statement, ok := sqlite_prepare(
		database,
		`SELECT id, workflow, video_id, title, url, media_path, duration,
		        metadata_status, width, height, fps, video_codec, audio_codec,
		        container, format_id, file_size
		 FROM sources
		 ORDER BY workflow, position`,
	)
	if !ok {return library_load_failure(database, .Sources, "Unable to read sources")}
	for {
		step := sqlite3_step(statement)
		if step == SQLITE_DONE {break}
		if step != SQLITE_ROW {
			sqlite3_finalize(statement)
			return library_load_failure(database, .Sources, "The source scan did not finish")
		}
		source := Source_Video{}
		copied: bool
		source.id, copied = sqlite_column_required_string(statement, 0); if !copied {sqlite3_finalize(statement); return library_load_failure(database, .Sources, "A source identifier is invalid")}
		source.workflow = Workflow_Kind(sqlite3_column_int(statement, 1))
		source.video_id, copied = sqlite_column_required_string(statement, 2); if !copied {delete_source_video(&source); sqlite3_finalize(statement); return library_load_failure(database, .Sources, "A source video identifier is invalid")}
		source.title, copied = sqlite_column_required_string(statement, 3); if !copied {delete_source_video(&source); sqlite3_finalize(statement); return library_load_failure(database, .Sources, "A source title is invalid")}
		source.url, copied = sqlite_column_required_string(statement, 4); if !copied {delete_source_video(&source); sqlite3_finalize(statement); return library_load_failure(database, .Sources, "A source URL is invalid")}
		stored_media_path, stored_media_path_copied := sqlite_column_required_string(statement, 5, context.temp_allocator)
		if !stored_media_path_copied {delete_source_video(&source); sqlite3_finalize(statement); return library_load_failure(database, .Sources, "A source media path is invalid")}
		source.media_path, copied = database_file_path_for_runtime(stored_media_path)
		if !copied {delete_source_video(&source); sqlite3_finalize(statement); return library_load_failure(database, .Sources, "Unable to resolve a source media path")}
		source.duration = sqlite3_column_double(statement, 6)
		source.metadata_status = Source_Metadata_Status(sqlite3_column_int(statement, 7))
		source.metadata.width = int(sqlite3_column_int(statement, 8)); source.metadata.height = int(sqlite3_column_int(statement, 9)); source.metadata.fps = sqlite3_column_double(statement, 10)
		source.metadata.vcodec, copied = sqlite_column_required_string(statement, 11); if !copied {delete_source_video(&source); sqlite3_finalize(statement); return library_load_failure(database, .Sources, "A source video codec is invalid")}
		source.metadata.acodec, copied = sqlite_column_required_string(statement, 12); if !copied {delete_source_video(&source); sqlite3_finalize(statement); return library_load_failure(database, .Sources, "A source audio codec is invalid")}
		source.metadata.ext, copied = sqlite_column_required_string(statement, 13); if !copied {delete_source_video(&source); sqlite3_finalize(statement); return library_load_failure(database, .Sources, "A source container is invalid")}
		source.metadata.format_id, copied = sqlite_column_required_string(statement, 14); if !copied {delete_source_video(&source); sqlite3_finalize(statement); return library_load_failure(database, .Sources, "A source format identifier is invalid")}
		source.metadata.filesize_approx = sqlite3_column_int64(statement, 15)
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
	if !ok {return library_load_failure(database, .Transcripts, "Unable to read transcripts")}
	for {
		step := sqlite3_step(statement)
		if step == SQLITE_DONE {break}
		if step != SQLITE_ROW {
			sqlite3_finalize(statement)
			return library_load_failure(database, .Transcripts, "The transcript scan did not finish")
		}
		segment := Transcript_Segment{start_seconds=sqlite3_column_double(statement, 2), duration_seconds=sqlite3_column_double(statement, 3)}
		valid: bool
		segment.id, valid = sqlite_column_required_string(statement, 0, context.temp_allocator)
		if !valid {sqlite3_finalize(statement); return library_load_failure(database, .Transcripts, "A transcript identifier is invalid")}
		segment.source_id, valid = sqlite_column_required_string(statement, 1, context.temp_allocator)
		if !valid {sqlite3_finalize(statement); return library_load_failure(database, .Transcripts, "A transcript source is invalid")}
		segment.text, valid = sqlite_column_required_string(statement, 4, context.temp_allocator)
		if !valid {sqlite3_finalize(statement); return library_load_failure(database, .Transcripts, "Transcript text is invalid")}
		if !transcript_append_copy(&transcripts, segment) {sqlite3_finalize(statement); return library_load_failure(database, .Transcripts, "Unable to allocate transcript text")}
	}
	sqlite3_finalize(statement)

	statement, ok = sqlite_prepare(database, "SELECT source_id, seconds FROM import_hints ORDER BY position")
	if !ok {return library_load_failure(database, .Hints, "Unable to read import hints")}
	for {
		step := sqlite3_step(statement)
		if step == SQLITE_DONE {break}
		if step != SQLITE_ROW {
			sqlite3_finalize(statement)
			return library_load_failure(database, .Hints, "The import-hint scan did not finish")
		}
		source_id, copied := sqlite_column_required_string(statement, 0); if !copied {sqlite3_finalize(statement); return library_load_failure(database, .Hints, "An import-hint source is invalid")}
		append(&hints, Import_Hint{source_id=source_id, seconds=sqlite3_column_double(statement, 1)})
	}
	sqlite3_finalize(statement)

	statement, ok = sqlite_prepare(
		database,
		`SELECT e.id, e.source_id, e.workflow, e.name, e.start_seconds,
		        e.end_seconds, e.clip_path, COALESCE(r.last_sequence, 0),
		        e.dance_mirrored, e.dance_loop, e.dance_count_in_beats,
		        e.dance_count_each_loop, e.dance_count_in_bpm,
		        e.dance_playback_rate
		 FROM clips e
		 LEFT JOIN clip_randomization r ON r.clip_id = e.id
		 ORDER BY e.workflow, e.position`,
	)
	if !ok {return library_load_failure(database, .Clips, "Unable to read clips")}
	for {
		step := sqlite3_step(statement)
		if step == SQLITE_DONE {break}
		if step != SQLITE_ROW {
			sqlite3_finalize(statement)
			return library_load_failure(database, .Clips, "The clip scan did not finish")
		}
		clip := Clip{
			workflow = Workflow_Kind(sqlite3_column_int(statement, 2)),
			start_seconds = sqlite3_column_double(statement, 4),
			end_seconds = sqlite3_column_double(statement, 5),
			last_randomized_sequence = sqlite3_column_int64(statement, 7),
			dance_mirrored = sqlite3_column_int(statement, 8) != 0,
			dance_loop = sqlite3_column_int(statement, 9) != 0,
			dance_count_in_beats = int(sqlite3_column_int(statement, 10)),
			dance_count_each_loop = sqlite3_column_int(statement, 11) != 0,
			dance_count_in_bpm = int(sqlite3_column_int(statement, 12)),
			dance_playback_rate = f32(sqlite3_column_double(statement, 13)),
		}
		copied: bool
		clip.id, copied = sqlite_column_required_string(statement, 0); if !copied {sqlite3_finalize(statement); return library_load_failure(database, .Clips, "A clip identifier is invalid")}
		clip.source_id, copied = sqlite_column_required_string(statement, 1); if !copied {delete_clip(&clip); sqlite3_finalize(statement); return library_load_failure(database, .Clips, "A clip source is invalid")}
		clip.name, copied = sqlite_column_required_string(statement, 3); if !copied {delete_clip(&clip); sqlite3_finalize(statement); return library_load_failure(database, .Clips, "A clip name is invalid")}
		stored_clip_path, stored_clip_path_copied := sqlite_column_required_string(statement, 6, context.temp_allocator)
		if !stored_clip_path_copied {delete_clip(&clip); sqlite3_finalize(statement); return library_load_failure(database, .Clips, "A clip path is invalid")}
		clip.clip_path, copied = database_file_path_for_runtime(stored_clip_path)
		if !copied {delete_clip(&clip); sqlite3_finalize(statement); return library_load_failure(database, .Clips, "Unable to resolve a clip path")}
		append(&clips, clip)
	}
	sqlite3_finalize(statement)

	candidate := App_State{
		sources = sources,
		hints = hints,
		clips = clips,
		transcripts = transcripts,
	}
	if !library_state_valid(&candidate) {
		return library_load_failure(database, .Validation, "The library contains invalid or inconsistent records")
	}
	destination.sources = sources
	destination.hints = hints
	destination.clips = clips
	destination.transcripts = transcripts
	loaded = true
	return {mode=.Ready}
}

database_load_state :: proc(database: ^SQLite_DB, destination: ^App_State) -> bool {
	result := database_load_state_result(database, destination)
	defer library_load_result_destroy(&result)
	return result.mode == .Ready
}

save_library :: proc() -> bool {
	return save_library_state(&state)
}

save_library_state :: proc(value: ^App_State) -> bool {
	if value == nil || !library_storage_writable() {return false}
	if library_legacy_fallback {return save_legacy_library_state(value)}
	return database_save_collections(
		library_database,
		value.sources[:],
		value.transcripts.segments[:],
		value.hints[:],
		value.clips[:],
	)
}

commit_library_state :: proc(
	candidate: ^App_State,
	change_kind := Library_Change_Kind.Routine,
	allow_without_backup := false,
) -> bool {
	if change_kind != .Routine {
		backup := library_backup_create(library_database)
		defer library_backup_result_destroy(&backup)
		if backup.status == .Failed && !allow_without_backup {return false}
		if backup.status == .Failed {
			_ = notification_post(
				.Error,
				"Continuing without a verified library backup",
				backup.detail,
			)
		}
	}
	if !save_library_state(candidate) {return false}
	app_state_collections_replace(&state, candidate)
	invalidate_transcript_matches()
	return true
}

load_library :: proc() -> Library_Load_Result {
	os.make_directory(app_support_dir())
	if !library_recovery_reconcile_activation() {
		failure := library_load_failure(
			nil,
			.Open,
			"Recovery activation is incomplete. The database files were preserved.",
		)
		library_recovery_block(failure)
		return failure
	}
	path := database_path()
	database_exists := os.exists(path)
	database_needs_migration := false
	candidate: App_State
	if database_exists {
		read_database, opened := library_database_open_path(path, SQLITE_OPEN_READONLY)
		if !opened {
			failure := library_load_failure(nil, .Open, "Unable to open the library database")
			library_recovery_require(failure)
			return failure
		}
		schema_version, version_read := library_database_user_version(
			read_database,
		)
		if !version_read {
			sqlite3_close(read_database)
			failure := library_load_failure(
				nil,
				.Schema,
				"Unable to read the library schema version",
			)
			library_recovery_block(failure)
			return failure
		}
		if schema_version > LIBRARY_SCHEMA_VERSION {
			sqlite3_close(read_database)
			failure := library_load_failure(
				nil,
				.Schema,
				fmt.tprintf(
					"The library uses schema version %d. This application supports version %d.",
					schema_version,
					LIBRARY_SCHEMA_VERSION,
				),
			)
			failure.schema_version = schema_version
			library_recovery_block(failure)
			return failure
		}
		if schema_version < LIBRARY_SCHEMA_VERSION {
			database_needs_migration = true
			backup := library_backup_create(read_database, false)
			backup_created := backup.status != .Failed
			library_backup_result_destroy(&backup)
			if !backup_created {
				sqlite3_close(read_database)
				failure := library_load_failure(
					nil,
					.Migration,
					"Unable to create a verified backup before migration",
				)
				library_recovery_require(failure)
				return failure
			}
		} else {
			load_result := database_load_state_result(read_database, &candidate)
			if load_result.mode != .Ready {
				sqlite3_close(read_database)
				library_recovery_require(load_result)
				return load_result
			}
		}
		sqlite3_close(read_database)
	}

	database, opened := library_database_open_path(
		path,
		SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE,
	)
	if !opened {
		app_state_collections_destroy(&candidate)
		failure := library_load_failure(nil, .Open, "Unable to open the library database for writing")
		library_recovery_require(failure)
		return failure
	}
	if !database_create_schema(database) {
		app_state_collections_destroy(&candidate)
		failure := library_load_failure(database, .Migration, "Unable to migrate the library database")
		sqlite3_close(database)
		library_recovery_require(failure)
		return failure
	}
	library_database = database
	library_legacy_fallback = false
	library_storage_mode = .Ready
	if database_exists {
		if database_needs_migration {
			load_result := database_load_state_result(database, &candidate)
			if load_result.mode != .Ready {
				sqlite3_close(database)
				library_database = nil
				library_recovery_require(load_result)
				return load_result
			}
			library_load_result_destroy(&load_result)
		}
		app_state_collections_replace(&state, &candidate)
	} else {
		load_result := database_load_state_result(database, &state)
		if load_result.mode != .Ready {
			sqlite3_close(database)
			library_database = nil
			library_recovery_require(load_result)
			return load_result
		}
		library_load_result_destroy(&load_result)
	}
	source_auth_saved_browser = database_source_auth_browser_load(database)
	legacy_exists := os.exists(manifest_path())
	if legacy_exists {
		app_state_collections_destroy(&state)
		load_legacy_library()
		if !database_save_state(database) || !database_state_counts_match(database) || !database_integrity_ok(database) {
			failure := library_load_failure(database, .Migration, "Unable to migrate the legacy library")
			sqlite3_close(database)
			library_database = nil
			library_recovery_require(failure)
			return failure
		}
		_ = os.remove(manifest_path())
	}
	if _, found := library_backup_latest(context.temp_allocator); !found {
		backup := library_backup_create(database)
		library_backup_result_destroy(&backup)
	}
	return {mode=.Ready}
}

database_close :: proc() {
	if library_database != nil {sqlite3_close(library_database)}
	library_database = nil
	if library_storage_mode != .Recovery_Required {
		library_storage_mode = .Closed
	}
}
