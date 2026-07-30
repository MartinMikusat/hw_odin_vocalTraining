package main

import "core:fmt"
import crypto_hash "core:crypto/hash"
import "core:encoding/json"
import "core:os"
import os2 "core:os/os2"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:time"
import "base:runtime"

LIBRARY_SCHEMA_VERSION :: 7
LIBRARY_BACKUP_RETENTION :: 10

Library_Storage_Mode :: enum {
	Closed,
	Ready,
	Legacy,
	Recovery_Required,
}

Library_Load_Stage :: enum {
	None,
	Open,
	Schema,
	Sources,
	Transcripts,
	Hints,
	Clips,
	Validation,
	Migration,
}

Library_Load_Result :: struct {
	mode: Library_Storage_Mode,
	stage: Library_Load_Stage,
	sqlite_code: int,
	schema_version: int,
	detail: string,
}

Library_Change_Kind :: enum {
	Routine,
	Source_Import,
	Library_Replacement,
}

Library_Entity_Kind :: enum i32 {
	Source,
	Transcript,
	Hint,
	Clip,
}

Library_Change_Operation :: enum i32 {
	Upsert,
	Delete,
}

Library_Backup_Status :: enum {
	Created,
	Reused,
	Failed,
}

Library_Backup_Result :: struct {
	status: Library_Backup_Status,
	path: string,
	revision: i64,
	detail: string,
}

Library_Recovery_Option :: enum {
	Backup_Only,
	Backup_With_Salvage,
	Salvage_Only,
}

Library_Recovery_Report :: struct {
	backup_available: bool,
	backup_path: string,
	backup_revision: i64,
	failed_revision: i64,
	recovered_sources: int,
	recovered_segments: int,
	recovered_hints: int,
	recovered_clips: int,
	replayed_deletions: int,
	rejected_records: int,
	incomplete_tables: int,
}

Library_Recovery_State :: struct {
	required: bool,
	recovery_allowed: bool,
	analysis_complete: bool,
	backup_ready: bool,
	merge_ready: bool,
	salvage_ready: bool,
	confirm_open: bool,
	working: bool,
	option: Library_Recovery_Option,
	failure: Library_Load_Result,
	report: Library_Recovery_Report,
	candidate: App_State,
}

Library_Recovery_Activation_Phase :: enum i32 {
	Prepared,
	Archived,
	Published,
}

Library_Recovery_Activation_Boundary :: enum {
	None,
	Marker_Written,
	Archive_Main_Copied,
	Archive_Complete,
	Candidate_Renamed,
	Sidecars_Removed,
}

Library_Recovery_Activation_Result :: enum {
	Failed,
	Complete,
	Interrupted,
}

Library_Recovery_File_Fingerprint :: struct {
	present: bool,
	size: i64,
	sha256: [32]byte,
}

Library_Recovery_Activation_Record :: struct {
	version: int,
	phase: Library_Recovery_Activation_Phase,
	candidate_path: string,
	archive_path: string,
	candidate: Library_Recovery_File_Fingerprint,
	active_main: Library_Recovery_File_Fingerprint,
	active_wal: Library_Recovery_File_Fingerprint,
	active_shm: Library_Recovery_File_Fingerprint,
}

Library_Change_Record :: struct {
	revision: i64,
	entity: Library_Entity_Kind,
	id: string,
	numeric_key: i64,
	operation: Library_Change_Operation,
}

library_storage_mode: Library_Storage_Mode
library_recovery_state: Library_Recovery_State

library_storage_writable :: proc() -> bool {
	if library_storage_mode == .Recovery_Required {return false}
	return library_storage_mode == .Ready ||
	       library_storage_mode == .Legacy ||
	       (library_database != nil && !library_legacy_fallback)
}

library_backups_dir :: proc() -> string {
	return fmt.tprintf("%s/Backups", app_support_dir())
}

library_failed_recovery_dir :: proc() -> string {
	return fmt.tprintf("%s/Recovery", app_support_dir())
}

library_revision_current :: proc(database: ^SQLite_DB) -> i64 {
	if database == nil {return 0}
	statement, prepared := sqlite_prepare(
		database,
		"SELECT current_revision FROM library_meta WHERE id = 1",
	)
	if !prepared {return 0}
	defer sqlite3_finalize(statement)
	if sqlite3_step(statement) != SQLITE_ROW {return 0}
	return sqlite3_column_int64(statement, 0)
}

library_database_user_version :: proc(database: ^SQLite_DB) -> (int, bool) {
	if database == nil {return 0, false}
	statement, prepared := sqlite_prepare(database, "PRAGMA user_version")
	if !prepared {return 0, false}
	defer sqlite3_finalize(statement)
	if sqlite3_step(statement) != SQLITE_ROW {return 0, false}
	return int(sqlite3_column_int(statement, 0)), true
}

source_storage_equal :: proc(a, b: Source_Video) -> bool {
	return a.id == b.id &&
	       a.workflow == b.workflow &&
	       a.video_id == b.video_id &&
	       a.title == b.title &&
	       a.url == b.url &&
	       a.media_path == b.media_path &&
	       a.duration == b.duration &&
	       a.metadata_status == b.metadata_status &&
	       a.metadata.width == b.metadata.width &&
	       a.metadata.height == b.metadata.height &&
	       a.metadata.fps == b.metadata.fps &&
	       a.metadata.vcodec == b.metadata.vcodec &&
	       a.metadata.acodec == b.metadata.acodec &&
	       a.metadata.ext == b.metadata.ext &&
	       a.metadata.format_id == b.metadata.format_id &&
	       a.metadata.filesize_approx == b.metadata.filesize_approx
}

segment_storage_equal :: proc(a, b: Transcript_Segment) -> bool {
	return a.id == b.id &&
	       a.source_id == b.source_id &&
	       a.start_seconds == b.start_seconds &&
	       a.duration_seconds == b.duration_seconds &&
	       a.text == b.text
}

hint_storage_equal :: proc(a, b: Import_Hint) -> bool {
	return a.source_id == b.source_id && a.seconds == b.seconds
}

clip_storage_equal :: proc(a, b: Clip) -> bool {
	return a.id == b.id &&
	       a.source_id == b.source_id &&
	       a.workflow == b.workflow &&
	       a.name == b.name &&
	       a.start_seconds == b.start_seconds &&
	       a.end_seconds == b.end_seconds &&
	       a.clip_path == b.clip_path &&
	       a.dance_mirrored == b.dance_mirrored &&
	       a.dance_loop == b.dance_loop &&
	       a.dance_count_in_beats == b.dance_count_in_beats &&
	       a.dance_count_each_loop == b.dance_count_each_loop &&
	       a.dance_count_in_bpm == b.dance_count_in_bpm &&
	       a.dance_playback_rate == b.dance_playback_rate
}

library_source_index :: proc(values: []Source_Video, id: string) -> int {
	for value, index in values {if value.id == id {return index}}
	return -1
}

library_segment_index :: proc(values: []Transcript_Segment, id: string) -> int {
	for value, index in values {if value.id == id {return index}}
	return -1
}

library_hint_index :: proc(values: []Import_Hint, source_id: string, seconds: f64) -> int {
	for value, index in values {
		if value.source_id == source_id && value.seconds == seconds {return index}
	}
	return -1
}

library_clip_index :: proc(values: []Clip, id: string) -> int {
	for value, index in values {if value.id == id {return index}}
	return -1
}

Library_Hint_Key :: struct {
	source_id: string,
	seconds_bits: i64,
}

library_hint_key :: proc(source_id: string, seconds: f64) -> Library_Hint_Key {
	seconds_bits := transmute(i64)seconds
	if seconds == 0 {seconds_bits = 0}
	return {source_id=source_id, seconds_bits=seconds_bits}
}

Library_Source_Video_Key :: struct {
	workflow: Workflow_Kind,
	video_id: string,
}

Library_State_Index :: struct {
	sources: map[string]int,
	source_videos: map[Library_Source_Video_Key]int,
	segments: map[string]int,
	hints: map[Library_Hint_Key]int,
	clips: map[string]int,
}

library_state_index_destroy :: proc(index: ^Library_State_Index) {
	if index == nil {return}
	delete(index.sources)
	delete(index.source_videos)
	delete(index.segments)
	delete(index.hints)
	delete(index.clips)
	index^ = {}
}

library_state_index_build :: proc(
	value: ^App_State,
) -> (Library_State_Index, bool) {
	if value == nil {return {}, false}
	result := Library_State_Index{
		sources = make(map[string]int, context.temp_allocator),
		source_videos = make(map[Library_Source_Video_Key]int, context.temp_allocator),
		segments = make(map[string]int, context.temp_allocator),
		hints = make(map[Library_Hint_Key]int, context.temp_allocator),
		clips = make(map[string]int, context.temp_allocator),
	}
	valid := false
	defer if !valid {library_state_index_destroy(&result)}
	for source, position in value.sources {
		if _, found := result.sources[source.id]; found {return {}, false}
		video_key := Library_Source_Video_Key{
			workflow = source.workflow,
			video_id = source.video_id,
		}
		if _, found := result.source_videos[video_key]; found {
			return {}, false
		}
		result.sources[source.id] = position
		result.source_videos[video_key] = position
	}
	for segment, position in value.transcripts.segments {
		if _, found := result.segments[segment.id]; found {return {}, false}
		result.segments[segment.id] = position
	}
	for hint, position in value.hints {
		key := library_hint_key(hint.source_id, hint.seconds)
		if _, found := result.hints[key]; found {return {}, false}
		result.hints[key] = position
	}
	for clip, position in value.clips {
		if _, found := result.clips[clip.id]; found {return {}, false}
		result.clips[clip.id] = position
	}
	valid = true
	return result, true
}

library_change_insert :: proc(
	database: ^SQLite_DB,
	revision: i64,
	kind: Library_Entity_Kind,
	id: string,
	number_key: i64,
	operation: Library_Change_Operation,
) -> bool {
	statement, prepared := sqlite_prepare(
		database,
		`INSERT INTO library_changes (
			revision, entity_kind, entity_id, numeric_key, operation
		) VALUES (?, ?, ?, ?, ?)`,
	)
	if !prepared {return false}
	defer sqlite3_finalize(statement)
	return sqlite3_bind_int64(statement, 1, revision) == SQLITE_OK &&
	       sqlite3_bind_int(statement, 2, i32(kind)) == SQLITE_OK &&
	       sqlite_bind_text_value(statement, 3, id) &&
	       sqlite3_bind_int64(statement, 4, number_key) == SQLITE_OK &&
	       sqlite3_bind_int(statement, 5, i32(operation)) == SQLITE_OK &&
	       sqlite3_step(statement) == SQLITE_DONE
}

library_change_count :: proc(
	previous, candidate: ^App_State,
	previous_index, candidate_index: ^Library_State_Index,
) -> int {
	if previous == nil || candidate == nil ||
	   previous_index == nil || candidate_index == nil {
		return 0
	}
	count := 0
	for value, position in candidate.sources {
		index, found := previous_index.sources[value.id]
		if !found || index != position ||
		   !source_storage_equal(previous.sources[index], value) {
			count += 1
		}
	}
	for value in previous.sources {
		if _, found := candidate_index.sources[value.id]; !found {count += 1}
	}
	for value, position in candidate.transcripts.segments {
		index, found := previous_index.segments[value.id]
		if !found || index != position ||
		   !segment_storage_equal(previous.transcripts.segments[index], value) {
			count += 1
		}
	}
	for value in previous.transcripts.segments {
		if _, found := candidate_index.segments[value.id]; !found {
			count += 1
		}
	}
	for value, position in candidate.hints {
		key := library_hint_key(value.source_id, value.seconds)
		index, found := previous_index.hints[key]
		if !found || index != position {count += 1}
	}
	for value in previous.hints {
		key := library_hint_key(value.source_id, value.seconds)
		if _, found := candidate_index.hints[key]; !found {
			count += 1
		}
	}
	for value, position in candidate.clips {
		index, found := previous_index.clips[value.id]
		if !found || index != position ||
		   !clip_storage_equal(previous.clips[index], value) {
			count += 1
		}
	}
	for value in previous.clips {
		if _, found := candidate_index.clips[value.id]; !found {count += 1}
	}
	return count
}

library_revision_record_changes :: proc(
	database: ^SQLite_DB,
	previous, candidate: ^App_State,
) -> (i64, bool) {
	previous_index, previous_indexed := library_state_index_build(previous)
	if !previous_indexed {return 0, false}
	defer library_state_index_destroy(&previous_index)
	candidate_index, candidate_indexed := library_state_index_build(candidate)
	if !candidate_indexed {return 0, false}
	defer library_state_index_destroy(&candidate_index)
	change_count := library_change_count(
		previous,
		candidate,
		&previous_index,
		&candidate_index,
	)
	if change_count == 0 {return library_revision_current(database), true}
	revision := library_revision_current(database) + 1
	statement, prepared := sqlite_prepare(
		database,
		"INSERT INTO library_revisions (revision, committed_at_ms) VALUES (?, ?)",
	)
	if !prepared {return 0, false}
	now_ms := time.to_unix_nanoseconds(time.now()) / 1_000_000
	inserted := sqlite3_bind_int64(statement, 1, revision) == SQLITE_OK &&
	            sqlite3_bind_int64(statement, 2, now_ms) == SQLITE_OK &&
	            sqlite3_step(statement) == SQLITE_DONE
	sqlite3_finalize(statement)
	if !inserted {return 0, false}

	for value, position in candidate.sources {
		index, found := previous_index.sources[value.id]
		if found && index == position &&
		   source_storage_equal(previous.sources[index], value) {
			continue
		}
		if !library_change_insert(database, revision, .Source, value.id, 0, .Upsert) {
			return 0, false
		}
	}
	for value in previous.sources {
		if _, found := candidate_index.sources[value.id]; !found &&
		   !library_change_insert(database, revision, .Source, value.id, 0, .Delete) {
			return 0, false
		}
	}
	for value, position in candidate.transcripts.segments {
		index, found := previous_index.segments[value.id]
		if found && index == position &&
		   segment_storage_equal(previous.transcripts.segments[index], value) {
			continue
		}
		if !library_change_insert(database, revision, .Transcript, value.id, 0, .Upsert) {
			return 0, false
		}
	}
	for value in previous.transcripts.segments {
		if _, found := candidate_index.segments[value.id]; !found &&
		   !library_change_insert(database, revision, .Transcript, value.id, 0, .Delete) {
			return 0, false
		}
	}
	for value, position in candidate.hints {
		key := library_hint_key(value.source_id, value.seconds)
		number_key := key.seconds_bits
		index, found := previous_index.hints[key]
		if found && index == position {continue}
		if !library_change_insert(database, revision, .Hint, value.source_id, number_key, .Upsert) {
			return 0, false
		}
	}
	for value in previous.hints {
		key := library_hint_key(value.source_id, value.seconds)
		number_key := key.seconds_bits
		if _, found := candidate_index.hints[key]; !found {
			if !library_change_insert(database, revision, .Hint, value.source_id, number_key, .Delete) {
				return 0, false
			}
		}
	}
	for value, position in candidate.clips {
		index, found := previous_index.clips[value.id]
		if found && index == position &&
		   clip_storage_equal(previous.clips[index], value) {
			continue
		}
		if !library_change_insert(database, revision, .Clip, value.id, 0, .Upsert) {
			return 0, false
		}
	}
	for value in previous.clips {
		if _, found := candidate_index.clips[value.id]; !found &&
		   !library_change_insert(database, revision, .Clip, value.id, 0, .Delete) {
			return 0, false
		}
	}

	statement, prepared = sqlite_prepare(
		database,
		"UPDATE library_meta SET current_revision = ? WHERE id = 1",
	)
	if !prepared {return 0, false}
	defer sqlite3_finalize(statement)
	updated := sqlite3_bind_int64(statement, 1, revision) == SQLITE_OK &&
	           sqlite3_step(statement) == SQLITE_DONE
	return revision, updated
}

database_foreign_keys_ok :: proc(database: ^SQLite_DB) -> bool {
	statement, prepared := sqlite_prepare(database, "PRAGMA foreign_key_check")
	if !prepared {return false}
	defer sqlite3_finalize(statement)
	return sqlite3_step(statement) == SQLITE_DONE
}

library_database_open_path :: proc(
	path: string,
	flags: i32,
) -> (^SQLite_DB, bool) {
	c_path := strings.clone_to_cstring(path)
	defer delete(c_path)
	database: ^SQLite_DB
	opened := sqlite3_open_v2(c_path, &database, flags, nil) == SQLITE_OK
	if !opened {
		if database != nil {sqlite3_close(database)}
		return nil, false
	}
	return database, true
}

library_backup_verify :: proc(
	path: string,
	expected_revision: i64 = -1,
	expected_schema := LIBRARY_SCHEMA_VERSION,
) -> (i64, bool) {
	database, opened := library_database_open_path(path, SQLITE_OPEN_READONLY)
	if !opened {return 0, false}
	defer sqlite3_close(database)
	if !database_integrity_ok(database) || !database_foreign_keys_ok(database) {
		return 0, false
	}
	schema, schema_read := library_database_user_version(database)
	if !schema_read || schema != expected_schema {return 0, false}
	revision := library_revision_current(database)
	if expected_revision >= 0 && revision != expected_revision {return 0, false}
	loaded: App_State
	loaded_ok := false
	if schema < 6 {
		loaded_ok = database_load_legacy_state(database, &loaded)
	} else {
		loaded_ok = database_load_state(database, &loaded)
	}
	if !loaded_ok {return 0, false}
	app_state_collections_destroy(&loaded)
	return revision, true
}

Library_Backup_File :: struct {
	path: string,
	name: string,
	modified_nano: i64,
	revision: i64,
}

library_backup_files :: proc(
	allocator := context.allocator,
) -> [dynamic]Library_Backup_File {
	result := make([dynamic]Library_Backup_File, allocator)
	handle, open_error := os.open(library_backups_dir())
	if open_error != nil {return result}
	entries, read_error := os.read_dir(handle, -1, allocator)
	os.close(handle)
	if read_error != nil {return result}
	for entry in entries {
		if entry.is_dir ||
		   !strings.has_prefix(entry.name, "library-r") ||
		   !strings.has_suffix(entry.name, ".sqlite3") {
			continue
		}
		revision, valid := library_backup_verify(entry.fullpath)
		if !valid {continue}
		append(&result, Library_Backup_File{
			path = entry.fullpath,
			name = entry.name,
			modified_nano = time.time_to_unix_nano(entry.modification_time),
			revision = revision,
		})
	}
	slice.sort_by(result[:], proc(a, b: Library_Backup_File) -> bool {
		if a.modified_nano == b.modified_nano {return a.name < b.name}
		return a.modified_nano < b.modified_nano
	})
	return result
}

library_backup_latest :: proc(
	allocator := context.allocator,
) -> (Library_Backup_File, bool) {
	files := library_backup_files(allocator)
	if len(files) == 0 {return {}, false}
	return files[len(files)-1], true
}

library_legacy_backup_latest :: proc(
	allocator := context.allocator,
) -> (Library_Backup_File, bool) {
	files := make([dynamic]Library_Backup_File, allocator)
	handle, open_error := os.open(library_backups_dir())
	if open_error != nil {return {}, false}
	entries, read_error := os.read_dir(handle, -1, allocator)
	os.close(handle)
	if read_error != nil {return {}, false}
	for entry in entries {
		if entry.is_dir ||
		   !strings.has_prefix(entry.name, "library-r") ||
		   !strings.has_suffix(entry.name, ".sqlite3") {
			continue
		}
		database, opened := library_database_open_path(
			entry.fullpath,
			SQLITE_OPEN_READONLY,
		)
		if !opened {continue}
		schema, schema_read := library_database_user_version(database)
		sqlite3_close(database)
		if !schema_read || schema <= 0 || schema >= 6 {continue}
		revision, valid := library_backup_verify(
			entry.fullpath,
			expected_schema = schema,
		)
		if !valid {continue}
		append(&files, Library_Backup_File{
			path = entry.fullpath,
			name = entry.name,
			modified_nano = time.time_to_unix_nano(entry.modification_time),
			revision = revision,
		})
	}
	if len(files) == 0 {return {}, false}
	slice.sort_by(files[:], proc(a, b: Library_Backup_File) -> bool {
		if a.modified_nano == b.modified_nano {return a.name < b.name}
		return a.modified_nano < b.modified_nano
	})
	return files[len(files)-1], true
}

library_backup_prune :: proc() {
	files := library_backup_files(context.temp_allocator)
	if len(files) <= LIBRARY_BACKUP_RETENTION {return}
	remove_count := len(files) - LIBRARY_BACKUP_RETENTION
	for index in 0..<remove_count {
		_ = os.remove(files[index].path)
	}
}

library_backup_create :: proc(
	database: ^SQLite_DB,
	reuse_same_revision := true,
	schema_version := LIBRARY_SCHEMA_VERSION,
) -> Library_Backup_Result {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	if database == nil {
		return {status=.Failed, detail=strings.clone("The library database is not open")}
	}
	revision := library_revision_current(database)
	if latest, found := library_backup_latest(context.temp_allocator);
	   schema_version == LIBRARY_SCHEMA_VERSION &&
	   reuse_same_revision &&
	   found && latest.revision == revision {
		return {
			status = .Reused,
			path = strings.clone(latest.path),
			revision = revision,
		}
	}
	os.make_directory(app_support_dir())
	os.make_directory(library_backups_dir())
	now_ms := time.to_unix_nanoseconds(time.now()) / 1_000_000
	name := fmt.tprintf("library-r%020d-%020d.sqlite3", revision, now_ms)
	final_path := fmt.tprintf("%s/%s", library_backups_dir(), name)
	temporary_path := fmt.tprintf("%s.tmp", final_path)
	_ = os.remove(temporary_path)
	destination, opened := library_database_open_path(
		temporary_path,
		SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE,
	)
	if !opened {
		return {
			status = .Failed,
			revision = revision,
			detail = strings.clone("Unable to create the backup database"),
		}
	}
	backup := sqlite3_backup_init(destination, cstring("main"), database, cstring("main"))
	copied := backup != nil && sqlite3_backup_step(backup, -1) == SQLITE_DONE
	if backup != nil {copied = sqlite3_backup_finish(backup) == SQLITE_OK && copied}
	sqlite3_close(destination)
	if !copied {
		_ = os.remove(temporary_path)
		return {
			status = .Failed,
			revision = revision,
			detail = strings.clone("SQLite could not copy the library"),
		}
	}
	if _, valid := library_backup_verify(
		temporary_path,
		revision,
		schema_version,
	); !valid {
		_ = os.remove(temporary_path)
		return {
			status = .Failed,
			revision = revision,
			detail = strings.clone("The copied backup did not pass verification"),
		}
	}
	if !os.rename(temporary_path, final_path) {
		_ = os.remove(temporary_path)
		return {
			status = .Failed,
			revision = revision,
			detail = strings.clone("Unable to publish the verified backup"),
		}
	}
	library_backup_prune()
	return {
		status = .Created,
		path = strings.clone(final_path),
		revision = revision,
	}
}

library_backup_result_destroy :: proc(result: ^Library_Backup_Result) {
	if result == nil {return}
	delete(result.path)
	delete(result.detail)
	result^ = {}
}

library_salvage_source_valid :: proc(value: ^Source_Video) -> bool {
	if value == nil {return false}
	if !portable_identifier_valid(value.id) ||
	   !portable_identifier_valid(value.video_id) ||
	   len(value.title) == 0 ||
	   len(value.url) == 0 ||
	   len(value.media_path) == 0 ||
	   !portable_seconds_valid(value.duration) ||
	   !portable_seconds_valid(value.metadata.fps) ||
	   value.metadata.width < 0 ||
	   value.metadata.height < 0 ||
	   value.metadata.filesize_approx < 0 {
		return false
	}
	switch value.metadata_status {
	case .Missing, .Available, .Unavailable: return true
	case: return false
	}
}

database_salvage_state :: proc(
	database: ^SQLite_DB,
	report: ^Library_Recovery_Report,
) -> (App_State, bool) {
	if database == nil || report == nil {return {}, false}
	result: App_State
	result.sources = make([dynamic]Source_Video)
	result.hints = make([dynamic]Import_Hint)
	result.clips = make([dynamic]Clip)
	transcripts, transcripts_created := transcript_generation_create(256)
	if !transcripts_created {
		app_state_collections_destroy(&result)
		return {}, false
	}
	result.transcripts = transcripts
	complete := true

	statement, prepared := sqlite_prepare(
		database,
		`SELECT id, video_id, title, url, media_path, duration,
		        metadata_status, width, height, fps, video_codec,
		        audio_codec, container, format_id, file_size
		 FROM sources ORDER BY position`,
	)
	if !prepared {
		report.incomplete_tables += 1
		complete = false
	} else {
		for {
			step := sqlite3_step(statement)
			if step == SQLITE_DONE {break}
			if step != SQLITE_ROW {
				report.incomplete_tables += 1
				complete = false
				break
			}
			source := Source_Video{}
			valid := true
			source.id, valid = sqlite_column_required_string(statement, 0)
			if valid {source.video_id, valid = sqlite_column_required_string(statement, 1)}
			if valid {source.title, valid = sqlite_column_required_string(statement, 2)}
			if valid {source.url, valid = sqlite_column_required_string(statement, 3)}
			stored_path := ""
			if valid {stored_path, valid = sqlite_column_required_string(statement, 4, context.temp_allocator)}
			if valid {source.media_path, valid = database_file_path_for_runtime(stored_path)}
			source.duration = sqlite3_column_double(statement, 5)
			source.metadata_status = Source_Metadata_Status(sqlite3_column_int(statement, 6))
			source.metadata.width = int(sqlite3_column_int(statement, 7))
			source.metadata.height = int(sqlite3_column_int(statement, 8))
			source.metadata.fps = sqlite3_column_double(statement, 9)
			if valid {source.metadata.vcodec, valid = sqlite_column_required_string(statement, 10)}
			if valid {source.metadata.acodec, valid = sqlite_column_required_string(statement, 11)}
			if valid {source.metadata.ext, valid = sqlite_column_required_string(statement, 12)}
			if valid {source.metadata.format_id, valid = sqlite_column_required_string(statement, 13)}
			source.metadata.filesize_approx = sqlite3_column_int64(statement, 14)
			valid = valid &&
			        library_salvage_source_valid(&source) &&
			        library_source_index(result.sources[:], source.id) < 0
			if !valid {
				delete_source_video(&source)
				report.rejected_records += 1
				continue
			}
			source.media_available = os.exists(source.media_path)
			append(&result.sources, source)
		}
		sqlite3_finalize(statement)
	}

	statement, prepared = sqlite_prepare(
		database,
		`SELECT transcript.id, transcript.source_id,
		        transcript.start_seconds, transcript.duration_seconds,
		        transcript.text
		 FROM transcript_segments AS transcript
		 LEFT JOIN sources AS source ON source.id = transcript.source_id
		 ORDER BY source.position, transcript.position`,
	)
	if !prepared {
		report.incomplete_tables += 1
		complete = false
	} else {
		for {
			step := sqlite3_step(statement)
			if step == SQLITE_DONE {break}
			if step != SQLITE_ROW {
				report.incomplete_tables += 1
				complete = false
				break
			}
			segment := Transcript_Segment{
				start_seconds = sqlite3_column_double(statement, 2),
				duration_seconds = sqlite3_column_double(statement, 3),
			}
			valid := true
			segment.id, valid = sqlite_column_required_string(statement, 0, context.temp_allocator)
			if valid {segment.source_id, valid = sqlite_column_required_string(statement, 1, context.temp_allocator)}
			if valid {segment.text, valid = sqlite_column_required_string(statement, 4, context.temp_allocator)}
			source_index := source_index_for_id(result.sources[:], segment.source_id)
			valid = valid &&
			        portable_identifier_valid(segment.id) &&
			        source_index >= 0 &&
			        portable_seconds_valid(segment.start_seconds) &&
			        portable_seconds_valid(segment.duration_seconds) &&
			        segment.start_seconds <= result.sources[source_index].duration &&
			        library_segment_index(result.transcripts.segments[:], segment.id) < 0
			if !valid || !transcript_append_copy(&result.transcripts, segment) {
				report.rejected_records += 1
			}
		}
		sqlite3_finalize(statement)
	}

	statement, prepared = sqlite_prepare(
		database,
		"SELECT source_id, seconds FROM import_hints ORDER BY position",
	)
	if !prepared {
		report.incomplete_tables += 1
		complete = false
	} else {
		for {
			step := sqlite3_step(statement)
			if step == SQLITE_DONE {break}
			if step != SQLITE_ROW {
				report.incomplete_tables += 1
				complete = false
				break
			}
			source_id, valid := sqlite_column_required_string(statement, 0)
			seconds := sqlite3_column_double(statement, 1)
			source_index := source_index_for_id(result.sources[:], source_id)
			valid = valid &&
			        source_index >= 0 &&
			        portable_seconds_valid(seconds) &&
			        seconds <= result.sources[source_index].duration &&
			        library_hint_index(result.hints[:], source_id, seconds) < 0
			if !valid {
				delete(source_id)
				report.rejected_records += 1
				continue
			}
			append(&result.hints, Import_Hint{source_id=source_id, seconds=seconds})
		}
		sqlite3_finalize(statement)
	}

	statement, prepared = sqlite_prepare(
		database,
		`SELECT e.id, e.source_id, e.name, e.start_seconds,
		        e.end_seconds, e.clip_path,
		        COALESCE(r.last_sequence, 0)
		 FROM clips e
		 LEFT JOIN clip_randomization r ON r.clip_id = e.id
		 ORDER BY e.position`,
	)
	if !prepared {
		report.incomplete_tables += 1
		complete = false
	} else {
		for {
			step := sqlite3_step(statement)
			if step == SQLITE_DONE {break}
			if step != SQLITE_ROW {
				report.incomplete_tables += 1
				complete = false
				break
			}
			clip := Clip{
				start_seconds = sqlite3_column_double(statement, 3),
				end_seconds = sqlite3_column_double(statement, 4),
				last_randomized_sequence = sqlite3_column_int64(statement, 6),
			}
			valid := true
			clip.id, valid = sqlite_column_required_string(statement, 0)
			if valid {clip.source_id, valid = sqlite_column_required_string(statement, 1)}
			if valid {clip.name, valid = sqlite_column_required_string(statement, 2)}
			stored_path := ""
			if valid {stored_path, valid = sqlite_column_required_string(statement, 5, context.temp_allocator)}
			if valid {clip.clip_path, valid = database_file_path_for_runtime(stored_path)}
			source_index := source_index_for_id(result.sources[:], clip.source_id)
			valid = valid &&
			        portable_identifier_valid(clip.id) &&
			        source_index >= 0 &&
			        len(clip.name) > 0 &&
			        valid_clip_range(
						clip.start_seconds,
						clip.end_seconds,
						result.sources[source_index].duration,
			        ) &&
			        library_clip_index(result.clips[:], clip.id) < 0
			if !valid {
				delete_clip(&clip)
				report.rejected_records += 1
				continue
			}
			append(&result.clips, clip)
		}
		sqlite3_finalize(statement)
	}

	report.recovered_sources = len(result.sources)
	report.recovered_segments = len(result.transcripts.segments)
	report.recovered_hints = len(result.hints)
	report.recovered_clips = len(result.clips)
	return result, complete
}

library_change_records_destroy :: proc(records: ^[dynamic]Library_Change_Record) {
	if records == nil {return}
	for &record in records {delete(record.id)}
	delete(records^)
	records^ = nil
}

library_change_records_after :: proc(
	database: ^SQLite_DB,
	revision: i64,
) -> ([dynamic]Library_Change_Record, bool) {
	records := make([dynamic]Library_Change_Record)
	statement, prepared := sqlite_prepare(
		database,
		`SELECT revision, entity_kind, entity_id, numeric_key, operation
		 FROM library_changes
		 WHERE revision > ?
		 ORDER BY revision, id`,
	)
	if !prepared {return records, false}
	defer sqlite3_finalize(statement)
	if sqlite3_bind_int64(statement, 1, revision) != SQLITE_OK {return records, false}
	for {
		step := sqlite3_step(statement)
		if step == SQLITE_DONE {return records, true}
		if step != SQLITE_ROW {return records, false}
		record := Library_Change_Record{
			revision = sqlite3_column_int64(statement, 0),
			entity = Library_Entity_Kind(sqlite3_column_int(statement, 1)),
			numeric_key = sqlite3_column_int64(statement, 3),
			operation = Library_Change_Operation(sqlite3_column_int(statement, 4)),
		}
		valid := true
		record.id, valid = sqlite_column_required_string(statement, 2)
		if !valid {
			library_change_records_destroy(&records)
			return nil, false
		}
		append(&records, record)
	}
}

library_change_latest :: proc(
	records: []Library_Change_Record,
	entity: Library_Entity_Kind,
	id: string,
	numeric_key: i64 = 0,
) -> (Library_Change_Operation, bool) {
	for index := len(records)-1; index >= 0; index -= 1 {
		record := records[index]
		if record.entity == entity &&
		   record.id == id &&
		   record.numeric_key == numeric_key {
			return record.operation, true
		}
	}
	return {}, false
}

library_change_log_complete :: proc(
	database: ^SQLite_DB,
	backup_revision: i64,
	failed_revision: i64,
) -> bool {
	if failed_revision <= backup_revision {return true}
	statement, prepared := sqlite_prepare(
		database,
		`SELECT COUNT(*)
		 FROM library_revisions
		 WHERE revision > ? AND revision <= ?`,
	)
	if !prepared {return false}
	defer sqlite3_finalize(statement)
	if sqlite3_bind_int64(statement, 1, backup_revision) != SQLITE_OK ||
	   sqlite3_bind_int64(statement, 2, failed_revision) != SQLITE_OK ||
	   sqlite3_step(statement) != SQLITE_ROW {
		return false
	}
	return sqlite3_column_int64(statement, 0) == failed_revision-backup_revision
}

library_recovery_build_candidate :: proc(
	backup: ^App_State,
	salvage: ^App_State,
	changes: []Library_Change_Record,
	exact_changes: bool,
	report: ^Library_Recovery_Report,
) -> (App_State, bool) {
	if salvage == nil || report == nil {return {}, false}
	sources := make([dynamic]Source_Video, 0)
	segments := make([dynamic]Transcript_Segment, 0)
	hints := make([dynamic]Import_Hint, 0)
	clips := make([dynamic]Clip, 0)
	defer delete(sources)
	defer delete(segments)
	defer delete(hints)
	defer delete(clips)

	if backup != nil {
		for value in backup.sources {
			operation, changed := library_change_latest(changes, .Source, value.id)
			if exact_changes && changed && operation == .Delete {
				report.replayed_deletions += 1
				continue
			}
			index := library_source_index(salvage.sources[:], value.id)
			if index >= 0 && (!exact_changes || changed) {
				append(&sources, salvage.sources[index])
			} else {
				append(&sources, value)
			}
		}
		for value in salvage.sources {
			if library_source_index(sources[:], value.id) >= 0 {continue}
			_, changed := library_change_latest(changes, .Source, value.id)
			if !exact_changes || changed {append(&sources, value)}
		}
	} else {
		append(&sources, ..salvage.sources[:])
	}

	if backup != nil {
		for value in backup.transcripts.segments {
			operation, changed := library_change_latest(changes, .Transcript, value.id)
			if exact_changes && changed && operation == .Delete {
				report.replayed_deletions += 1
				continue
			}
			index := library_segment_index(salvage.transcripts.segments[:], value.id)
			if index >= 0 && (!exact_changes || changed) {
				append(&segments, salvage.transcripts.segments[index])
			} else {
				append(&segments, value)
			}
		}
		for value in salvage.transcripts.segments {
			if library_segment_index(segments[:], value.id) >= 0 {continue}
			_, changed := library_change_latest(changes, .Transcript, value.id)
			if !exact_changes || changed {append(&segments, value)}
		}
	} else {
		append(&segments, ..salvage.transcripts.segments[:])
	}

	if backup != nil {
		for value in backup.hints {
			key := library_hint_key(value.source_id, value.seconds).seconds_bits
			operation, changed := library_change_latest(changes, .Hint, value.source_id, key)
			if exact_changes && changed && operation == .Delete {
				report.replayed_deletions += 1
				continue
			}
			index := library_hint_index(salvage.hints[:], value.source_id, value.seconds)
			if index >= 0 && (!exact_changes || changed) {
				append(&hints, salvage.hints[index])
			} else {
				append(&hints, value)
			}
		}
		for value in salvage.hints {
			if library_hint_index(hints[:], value.source_id, value.seconds) >= 0 {continue}
			_, changed := library_change_latest(
				changes,
				.Hint,
				value.source_id,
				library_hint_key(value.source_id, value.seconds).seconds_bits,
			)
			if !exact_changes || changed {append(&hints, value)}
		}
	} else {
		append(&hints, ..salvage.hints[:])
	}

	if backup != nil {
		for value in backup.clips {
			operation, changed := library_change_latest(changes, .Clip, value.id)
			if exact_changes && changed && operation == .Delete {
				report.replayed_deletions += 1
				continue
			}
			index := library_clip_index(salvage.clips[:], value.id)
			if index >= 0 && (!exact_changes || changed) {
				append(&clips, salvage.clips[index])
			} else {
				append(&clips, value)
			}
		}
		for value in salvage.clips {
			if library_clip_index(clips[:], value.id) >= 0 {continue}
			_, changed := library_change_latest(changes, .Clip, value.id)
			if !exact_changes || changed {append(&clips, value)}
		}
	} else {
		append(&clips, ..salvage.clips[:])
	}

	candidate, copied := app_state_collections_copy(
		sources[:],
		segments[:],
		hints[:],
		clips[:],
	)
	if !copied || !library_state_valid(&candidate) {
		app_state_collections_destroy(&candidate)
		return {}, false
	}
	return candidate, true
}

library_recovery_finish_analysis :: proc(
	built: bool,
	candidate: ^App_State,
) -> bool {
	report := &library_recovery_state.report
	library_recovery_state.backup_ready = report.backup_available
	library_recovery_state.merge_ready = report.backup_available && built
	library_recovery_state.salvage_ready = !report.backup_available && built
	if built && candidate != nil {
		library_recovery_state.candidate = candidate^
		candidate^ = {}
	}
	library_recovery_state.option = .Salvage_Only
	if library_recovery_state.merge_ready {
		library_recovery_state.option = .Backup_With_Salvage
	} else if library_recovery_state.backup_ready {
		library_recovery_state.option = .Backup_Only
	}
	library_recovery_state.analysis_complete = true
	return library_recovery_state.backup_ready ||
	       library_recovery_state.merge_ready ||
	       library_recovery_state.salvage_ready
}

library_recovery_analyze :: proc() -> bool {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	if !library_recovery_state.required {return false}
	app_state_collections_destroy(&library_recovery_state.candidate)
	delete(library_recovery_state.report.backup_path)
	library_recovery_state.report = {}

	failed_database, opened := library_database_open_path(database_path(), SQLITE_OPEN_READONLY)
	if !opened {return false}
	defer sqlite3_close(failed_database)
	report := &library_recovery_state.report
	report.failed_revision = library_revision_current(failed_database)
	salvage, _ := database_salvage_state(failed_database, report)
	defer app_state_collections_destroy(&salvage)

	backup_state: App_State
	backup_database: ^SQLite_DB
	if backup_file, found := library_backup_latest(context.temp_allocator); found {
		backup_database, opened = library_database_open_path(backup_file.path, SQLITE_OPEN_READONLY)
		if opened {
			defer sqlite3_close(backup_database)
			load_result := database_load_state_result(backup_database, &backup_state)
			if load_result.mode == .Ready {
				report.backup_available = true
				report.backup_path = strings.clone(backup_file.path)
				report.backup_revision = backup_file.revision
			}
			library_load_result_destroy(&load_result)
		}
	}
	defer app_state_collections_destroy(&backup_state)

	changes, read_changes := library_change_records_after(
		failed_database,
		report.backup_revision,
	)
	defer library_change_records_destroy(&changes)
	exact_changes := report.backup_available &&
	                 read_changes &&
	                 library_change_log_complete(
						failed_database,
						report.backup_revision,
						report.failed_revision,
	                 )
	backup_pointer: ^App_State
	if report.backup_available {backup_pointer = &backup_state}
	candidate, built := library_recovery_build_candidate(
		backup_pointer,
		&salvage,
		changes[:],
		exact_changes,
		report,
	)
	return library_recovery_finish_analysis(built, &candidate)
}

library_database_copy :: proc(source_path, destination_path: string) -> bool {
	_ = os.remove(destination_path)
	source, source_opened := library_database_open_path(source_path, SQLITE_OPEN_READONLY)
	if !source_opened {return false}
	defer sqlite3_close(source)
	destination, destination_opened := library_database_open_path(
		destination_path,
		SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE,
	)
	if !destination_opened {return false}
	defer sqlite3_close(destination)
	backup := sqlite3_backup_init(
		destination,
		cstring("main"),
		source,
		cstring("main"),
	)
	copied := backup != nil && sqlite3_backup_step(backup, -1) == SQLITE_DONE
	if backup != nil {
		copied = sqlite3_backup_finish(backup) == SQLITE_OK && copied
	}
	return copied
}

library_recovery_marker_path :: proc() -> string {
	return fmt.tprintf("%s/recovery-activation.pending", app_support_dir())
}

library_recovery_activation_record_destroy :: proc(
	record: ^Library_Recovery_Activation_Record,
) {
	if record == nil {return}
	delete(record.candidate_path)
	delete(record.archive_path)
	record^ = {}
}

library_recovery_file_fingerprint :: proc(
	path: string,
) -> (Library_Recovery_File_Fingerprint, bool) {
	if !os.exists(path) {return {}, true}
	file, open_error := os2.open(path)
	if open_error != nil {return {}, false}
	defer os2.close(file)
	info, stat_error := os2.fstat(file, context.temp_allocator)
	if stat_error != nil {return {}, false}
	digest, hash_error := crypto_hash.hash_stream(
		.SHA256,
		os2.to_reader(file),
		context.temp_allocator,
	)
	if hash_error != nil || len(digest) != 32 {return {}, false}
	result := Library_Recovery_File_Fingerprint{
		present = true,
		size = info.size,
	}
	copy(result.sha256[:], digest)
	return result, true
}

library_recovery_fingerprint_matches :: proc(
	path: string,
	expected: Library_Recovery_File_Fingerprint,
) -> bool {
	actual, read := library_recovery_file_fingerprint(path)
	return read &&
	       actual.present == expected.present &&
	       (!expected.present ||
	        (actual.size == expected.size && actual.sha256 == expected.sha256))
}

library_recovery_sync_path :: proc(path: string) -> bool {
	file, open_error := os2.open(path, {.Read, .Write})
	if open_error != nil {return false}
	sync_error := os2.sync(file)
	close_error := os2.close(file)
	return sync_error == nil && close_error == nil
}

library_recovery_sync_directory :: proc(path: string) -> bool {
	directory, open_error := os2.open(path)
	if open_error != nil {return false}
	sync_error := os2.sync(directory)
	close_error := os2.close(directory)
	return sync_error == nil && close_error == nil
}

library_recovery_sync_parent :: proc(path: string) -> bool {
	parent := filepath.dir(path)
	defer delete(parent)
	return library_recovery_sync_directory(parent)
}

library_recovery_record_write :: proc(
	record: ^Library_Recovery_Activation_Record,
) -> bool {
	if record == nil {return false}
	encoded, encode_error := json.marshal(record^)
	if encode_error != nil {return false}
	defer delete(encoded)
	path := library_recovery_marker_path()
	temporary_path := fmt.tprintf("%s.tmp", path)
	_ = os.remove(temporary_path)
	if os2.write_entire_file(temporary_path, encoded) != nil ||
	   !library_recovery_sync_path(temporary_path) ||
	   os2.rename(temporary_path, path) != nil ||
	   !library_recovery_sync_parent(path) {
		_ = os.remove(temporary_path)
		return false
	}
	return true
}

library_recovery_record_read :: proc() -> (
	Library_Recovery_Activation_Record,
	bool,
) {
	bytes, read_ok := os.read_entire_file(
		library_recovery_marker_path(),
		context.temp_allocator,
	)
	if !read_ok {return {}, false}
	record: Library_Recovery_Activation_Record
	if decode_error := json.unmarshal(
		bytes,
		&record,
		.JSON,
	); decode_error != nil {
		library_recovery_activation_record_destroy(&record)
		return {}, false
	}
	candidate_prefix := fmt.tprintf("%s/", app_support_dir())
	archive_prefix := fmt.tprintf("%s/", library_failed_recovery_dir())
	valid := record.version == 1 &&
	         strings.has_prefix(record.candidate_path, candidate_prefix) &&
	         strings.has_prefix(record.archive_path, archive_prefix) &&
	         record.candidate.present &&
	         record.active_main.present
	if !valid {
		library_recovery_activation_record_destroy(&record)
		return {}, false
	}
	return record, true
}

library_recovery_copy_component :: proc(
	source_path, destination_path: string,
	expected: Library_Recovery_File_Fingerprint,
) -> bool {
	if !expected.present {
		removed := os.exists(destination_path) ||
		           os.exists(fmt.tprintf("%s.tmp", destination_path))
		_ = os.remove(destination_path)
		_ = os.remove(fmt.tprintf("%s.tmp", destination_path))
		if os.exists(destination_path) ||
		   os.exists(fmt.tprintf("%s.tmp", destination_path)) {
			return false
		}
		if removed && !library_recovery_sync_parent(destination_path) {
			return false
		}
		return true
	}
	if !library_recovery_fingerprint_matches(source_path, expected) {return false}
	temporary_path := fmt.tprintf("%s.tmp", destination_path)
	_ = os.remove(temporary_path)
	if os2.copy_file(temporary_path, source_path) != nil ||
	   !library_recovery_sync_path(temporary_path) ||
	   !library_recovery_fingerprint_matches(temporary_path, expected) ||
	   os2.rename(temporary_path, destination_path) != nil ||
	   !library_recovery_sync_parent(destination_path) ||
	   !library_recovery_fingerprint_matches(destination_path, expected) {
		return false
	}
	return true
}

library_recovery_archive_complete :: proc(
	record: ^Library_Recovery_Activation_Record,
) -> bool {
	if record == nil {return false}
	return library_recovery_fingerprint_matches(
			record.archive_path,
			record.active_main,
		) &&
	       library_recovery_fingerprint_matches(
			fmt.tprintf("%s-wal", record.archive_path),
			record.active_wal,
	       ) &&
	       library_recovery_fingerprint_matches(
			fmt.tprintf("%s-shm", record.archive_path),
			record.active_shm,
	       )
}

library_recovery_archive_failed_database :: proc(
	record: ^Library_Recovery_Activation_Record,
	stop_after: Library_Recovery_Activation_Boundary,
) -> Library_Recovery_Activation_Result {
	if record == nil {return .Failed}
	active_path := database_path()
	if !library_recovery_copy_component(
		active_path,
		record.archive_path,
		record.active_main,
	) {
		return .Failed
	}
	if stop_after == .Archive_Main_Copied {return .Interrupted}
	if !library_recovery_copy_component(
		fmt.tprintf("%s-wal", active_path),
		fmt.tprintf("%s-wal", record.archive_path),
		record.active_wal,
	) ||
	   !library_recovery_copy_component(
		fmt.tprintf("%s-shm", active_path),
		fmt.tprintf("%s-shm", record.archive_path),
		record.active_shm,
	   ) ||
	   !library_recovery_archive_complete(record) {
		return .Failed
	}
	return .Complete
}

library_recovery_activation_finish :: proc(
	record: ^Library_Recovery_Activation_Record,
	stop_after := Library_Recovery_Activation_Boundary.None,
) -> Library_Recovery_Activation_Result {
	if record == nil {return .Failed}
	active_path := database_path()
	if record.phase == .Prepared {
		if !library_recovery_fingerprint_matches(
			record.candidate_path,
			record.candidate,
		) ||
		   !library_recovery_fingerprint_matches(
			active_path,
			record.active_main,
		   ) ||
		   !library_recovery_fingerprint_matches(
			fmt.tprintf("%s-wal", active_path),
			record.active_wal,
		   ) ||
		   !library_recovery_fingerprint_matches(
			fmt.tprintf("%s-shm", active_path),
			record.active_shm,
		   ) {
			return .Failed
		}
		archive_result := library_recovery_archive_failed_database(
			record,
			stop_after,
		)
		if archive_result != .Complete {return archive_result}
		record.phase = .Archived
		if !library_recovery_record_write(record) {return .Failed}
		if stop_after == .Archive_Complete {return .Interrupted}
	}
	if record.phase == .Archived {
		if !library_recovery_archive_complete(record) {return .Failed}
		if os.exists(record.candidate_path) {
			if !library_recovery_fingerprint_matches(
				record.candidate_path,
				record.candidate,
			) ||
			   os2.rename(record.candidate_path, active_path) != nil ||
			   !library_recovery_sync_parent(active_path) {
				return .Failed
			}
			if stop_after == .Candidate_Renamed {return .Interrupted}
		} else if !library_recovery_fingerprint_matches(
			active_path,
			record.candidate,
		) {
			return .Failed
		}
		record.phase = .Published
		if !library_recovery_record_write(record) {return .Failed}
	}
	if record.phase != .Published ||
	   !library_recovery_archive_complete(record) ||
	   !library_recovery_fingerprint_matches(active_path, record.candidate) {
		return .Failed
	}
	active_wal_path := fmt.tprintf("%s-wal", active_path)
	active_shm_path := fmt.tprintf("%s-shm", active_path)
	_ = os.remove(active_wal_path)
	_ = os.remove(active_shm_path)
	if os.exists(active_wal_path) || os.exists(active_shm_path) {
		return .Failed
	}
	if !library_recovery_sync_parent(active_path) {
		return .Failed
	}
	if stop_after == .Sidecars_Removed {return .Interrupted}
	_ = os.remove(library_recovery_marker_path())
	if os.exists(library_recovery_marker_path()) {return .Failed}
	if !library_recovery_sync_parent(active_path) {
		return .Failed
	}
	return .Complete
}

library_recovery_reconcile_activation :: proc() -> bool {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	marker_path := library_recovery_marker_path()
	if !os.exists(marker_path) {return true}
	record, read := library_recovery_record_read()
	if !read {return false}
	defer library_recovery_activation_record_destroy(&record)
	return library_recovery_activation_finish(&record) == .Complete
}

library_recovery_activate :: proc(
	option: Library_Recovery_Option,
	stop_after := Library_Recovery_Activation_Boundary.None,
) -> bool {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	if !library_recovery_state.required {return false}
	if !library_recovery_state.recovery_allowed {return false}
	if !library_recovery_state.analysis_complete &&
	   !library_recovery_analyze() {
		return false
	}
	report := &library_recovery_state.report
	switch option {
	case .Backup_Only:
		if !library_recovery_state.backup_ready {return false}
	case .Backup_With_Salvage:
		if !library_recovery_state.merge_ready {return false}
	case .Salvage_Only:
		if !library_recovery_state.salvage_ready {return false}
	}

	replacement: App_State
	replacement_ready := false
	if option == .Backup_Only {
		backup_database, opened := library_database_open_path(
			report.backup_path,
			SQLITE_OPEN_READONLY,
		)
		if !opened {return false}
		load_result := database_load_state_result(backup_database, &replacement)
		sqlite3_close(backup_database)
		replacement_ready = load_result.mode == .Ready
		library_load_result_destroy(&load_result)
	} else {
		replacement, replacement_ready = app_state_collections_clone(
			&library_recovery_state.candidate,
		)
	}
	if !replacement_ready {return false}
	defer app_state_collections_destroy(&replacement)

	now_ms := time.to_unix_nanoseconds(time.now()) / 1_000_000
	candidate_path := fmt.tprintf(
		"%s/library-recovery-%020d.sqlite3.tmp",
		app_support_dir(),
		now_ms,
	)
	_ = os.remove(candidate_path)
	if report.backup_available {
		if !library_database_copy(report.backup_path, candidate_path) {return false}
	}
	candidate_database, opened := library_database_open_path(
		candidate_path,
		SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE,
	)
	if !opened {
		_ = os.remove(candidate_path)
		return false
	}
	prepared := database_create_schema(candidate_database) &&
	            database_save_collections(
					candidate_database,
					replacement.sources[:],
					replacement.transcripts.segments[:],
					replacement.hints[:],
					replacement.clips[:],
	            )
	sqlite3_close(candidate_database)
	if !prepared {
		_ = os.remove(candidate_path)
		return false
	}
	if _, verified := library_backup_verify(candidate_path); !verified {
		_ = os.remove(candidate_path)
		return false
	}
	if !library_recovery_sync_path(candidate_path) ||
	   !library_recovery_sync_parent(candidate_path) {
		_ = os.remove(candidate_path)
		return false
	}

	os.make_directory(library_failed_recovery_dir())
	archive_path := fmt.tprintf(
		"%s/failed-library-%020d.sqlite3",
		library_failed_recovery_dir(),
		now_ms,
	)
	candidate_fingerprint, candidate_hashed :=
		library_recovery_file_fingerprint(candidate_path)
	active_path := database_path()
	active_main, active_hashed := library_recovery_file_fingerprint(active_path)
	active_wal, wal_hashed := library_recovery_file_fingerprint(
		fmt.tprintf("%s-wal", active_path),
	)
	active_shm, shm_hashed := library_recovery_file_fingerprint(
		fmt.tprintf("%s-shm", active_path),
	)
	if !candidate_hashed || !candidate_fingerprint.present ||
	   !active_hashed || !active_main.present ||
	   !wal_hashed || !shm_hashed {
		_ = os.remove(candidate_path)
		return false
	}
	record := Library_Recovery_Activation_Record{
		version = 1,
		phase = .Prepared,
		candidate_path = strings.clone(candidate_path),
		archive_path = strings.clone(archive_path),
		candidate = candidate_fingerprint,
		active_main = active_main,
		active_wal = active_wal,
		active_shm = active_shm,
	}
	defer library_recovery_activation_record_destroy(&record)
	if !library_recovery_record_write(&record) {
		_ = os.remove(candidate_path)
		return false
	}
	if stop_after == .Marker_Written {return false}
	if library_recovery_activation_finish(&record, stop_after) != .Complete {
		return false
	}

	load_result := load_library()
	activated := load_result.mode == .Ready
	library_load_result_destroy(&load_result)
	if activated {
		if notification_history.initialized &&
		   !notification_history_rebind_database() {
			_ = notification_post(
				.Error,
				"Notification history reload failed",
				"The recovered library is active, but its operational history could not be loaded.",
				persist = false,
			)
		}
		library_recovery_state_destroy()
	}
	return activated
}

library_recovery_state_destroy :: proc() {
	delete(library_recovery_state.failure.detail)
	delete(library_recovery_state.report.backup_path)
	app_state_collections_destroy(&library_recovery_state.candidate)
	library_recovery_state = {}
}

library_recovery_require :: proc(failure: Library_Load_Result) {
	library_recovery_state_destroy()
	library_storage_mode = .Recovery_Required
	library_recovery_state.required = true
	library_recovery_state.recovery_allowed = true
	library_recovery_state.failure = failure
	library_recovery_state.failure.detail = strings.clone(failure.detail)
}

library_recovery_block :: proc(failure: Library_Load_Result) {
	library_recovery_require(failure)
	library_recovery_state.recovery_allowed = false
}
