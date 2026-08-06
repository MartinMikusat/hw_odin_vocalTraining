package main

import "core:encoding/json"
import "core:math"
import "core:strings"
import "core:testing"
import "base:runtime"

bpm_test_open_memory_database :: proc(t: ^testing.T) -> (^SQLite_DB, bool) {
	database: ^SQLite_DB
	path := strings.clone_to_cstring(":memory:")
	defer delete(path)
	opened := sqlite3_open_v2(
		path,
		&database,
		SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE,
		nil,
	) == SQLITE_OK
	testing.expect(t, opened)
	return database, opened
}

@(test)
bpm_schema_v10_migrates_beat_grid_and_invalidates_old_detector_test :: proc(
	t: ^testing.T,
) {
	database, opened := bpm_test_open_memory_database(t)
	if !opened {return}
	defer sqlite3_close(database)
	testing.expect(t, sqlite_execute(database, `
		CREATE TABLE clips (
			id TEXT PRIMARY KEY,
			workflow INTEGER NOT NULL,
			dance_count_in_bpm INTEGER NOT NULL,
			dance_detected_bpm REAL NOT NULL,
			dance_bpm_confidence REAL NOT NULL,
			dance_bpm_detector_revision INTEGER NOT NULL
		);
		INSERT INTO clips VALUES ('clip-1', 1, 120, 120, 0.8, 1);
		PRAGMA user_version = 10;
	`))
	testing.expect(t, database_migrate_v10_to_v11(database))
	version, read := library_database_user_version(database)
	testing.expect(t, read)
	testing.expect_value(t, version, 11)
	statement, prepared := sqlite_prepare(database, `
		SELECT dance_beat_period_seconds, dance_bpm_detector_revision,
		       dance_metronome_enabled FROM clips
	`)
	testing.expect(t, prepared)
	if !prepared {return}
	defer sqlite3_finalize(statement)
	testing.expect_value(t, sqlite3_step(statement), i32(SQLITE_ROW))
	testing.expect_value(t, sqlite3_column_double(statement, 0), 0.5)
	testing.expect_value(t, sqlite3_column_int(statement, 1), i32(0))
	testing.expect_value(t, sqlite3_column_int(statement, 2), i32(0))
}

@(test)
bpm_schema_v9_migrates_to_v10_and_preserves_legacy_bpm_test :: proc(t: ^testing.T) {
	database, opened := bpm_test_open_memory_database(t)
	if !opened {return}
	defer sqlite3_close(database)
	testing.expect(t, sqlite_execute(database, `
		CREATE TABLE clips (
			id TEXT PRIMARY KEY,
			workflow INTEGER NOT NULL,
			dance_count_in_bpm INTEGER NOT NULL
		);
		INSERT INTO clips (id, workflow, dance_count_in_bpm)
		VALUES ('clip-1', 1, 120), ('clip-2', 1, 128), ('clip-3', 0, 120);
		PRAGMA user_version = 9;
	`))
	testing.expect(t, database_migrate_v9_to_v10(database))
	version, read := library_database_user_version(database)
	testing.expect(t, read)
	testing.expect_value(t, version, 10)
	statement, prepared := sqlite_prepare(database, `
		SELECT dance_detected_bpm, dance_bpm_confidence,
		       dance_bpm_detector_revision, dance_bpm_user_set
		FROM clips ORDER BY id
	`)
	testing.expect(t, prepared)
	if !prepared {return}
	defer sqlite3_finalize(statement)
	testing.expect_value(t, sqlite3_step(statement), i32(SQLITE_ROW))
	testing.expect_value(t, sqlite3_column_double(statement, 0), 0.0)
	testing.expect_value(t, sqlite3_column_double(statement, 1), 0.0)
	testing.expect_value(t, sqlite3_column_int(statement, 2), i32(0))
	testing.expect_value(t, sqlite3_column_int(statement, 3), i32(1))
	testing.expect_value(t, sqlite3_step(statement), i32(SQLITE_ROW))
	testing.expect_value(t, sqlite3_column_int(statement, 3), i32(1))
	testing.expect_value(t, sqlite3_step(statement), i32(SQLITE_ROW))
	testing.expect_value(t, sqlite3_column_int(statement, 3), i32(0))
}

@(test)
bpm_schema_v9_migration_rolls_back_partial_column_additions_test :: proc(
	t: ^testing.T,
) {
	database, opened := bpm_test_open_memory_database(t)
	if !opened {return}
	defer sqlite3_close(database)
	testing.expect(t, sqlite_execute(database, `
		CREATE TABLE clips (
			id TEXT PRIMARY KEY,
			workflow INTEGER NOT NULL,
			dance_bpm_confidence REAL NOT NULL DEFAULT 0
		);
		PRAGMA user_version = 9;
	`))
	testing.expect(t, !database_migrate_v9_to_v10(database))
	version, read := library_database_user_version(database)
	testing.expect(t, read)
	testing.expect_value(t, version, 9)
	statement, prepared := sqlite_prepare(
		database,
		"SELECT dance_detected_bpm FROM clips",
	)
	if prepared {sqlite3_finalize(statement)}
	testing.expect(t, !prepared)
}

@(test)
bpm_detection_and_manual_override_round_trip_through_sqlite_test :: proc(t: ^testing.T) {
	database, opened := bpm_test_open_memory_database(t)
	if !opened {return}
	defer sqlite3_close(database)
	testing.expect(t, database_create_schema(database))
	sources := [1]Source_Video{{
		id = "source-1",
		workflow = .Dancing,
		kind = .YouTube,
		video_id = "video-1",
		title = "Dance source",
		url = "https://example.com/video-1",
		has_audio = true,
		media_path = "/tmp/source-1.mp4",
		duration = 20,
	}}
	clips := [1]Clip{{
		id = "clip-1",
		source_id = "source-1",
		workflow = .Dancing,
		name = "Dance clip",
		start_seconds = 0,
		end_seconds = 10,
		clip_path = "/tmp/clip-1.mp4",
		dance_count_in_bpm = 128,
		dance_detected_bpm = 128.25,
		dance_bpm_confidence = 0.77,
		dance_bpm_detector_revision = BPM_DETECTOR_REVISION,
		dance_bpm_user_set = false,
		dance_beat_period_seconds = 60.0/128.25,
		dance_beat_grid_offset_seconds = 0.18,
		dance_beat_phase_confidence = 0.66,
		dance_metronome_enabled = true,
		dance_playback_rate = 1,
	}}
	testing.expect(t, database_save_collections(database, sources[:], nil, nil, clips[:]))
	loaded: App_State
	testing.expect(t, database_load_state(database, &loaded))
	defer app_state_collections_destroy(&loaded)
	testing.expect_value(t, len(loaded.clips), 1)
	if len(loaded.clips) != 1 {return}
	testing.expect_value(t, loaded.clips[0].dance_detected_bpm, 128.25)
	testing.expect_value(t, loaded.clips[0].dance_bpm_confidence, f32(0.77))
	testing.expect_value(t, loaded.clips[0].dance_bpm_detector_revision, BPM_DETECTOR_REVISION)
	testing.expect(t, !loaded.clips[0].dance_bpm_user_set)
	testing.expect_value(t, loaded.clips[0].dance_beat_grid_offset_seconds, 0.18)
	testing.expect(t, loaded.clips[0].dance_metronome_enabled)

	clips[0].dance_bpm_user_set = true
	testing.expect(t, database_save_collections(database, sources[:], nil, nil, clips[:]))
	manual: App_State
	testing.expect(t, database_load_state(database, &manual))
	defer app_state_collections_destroy(&manual)
	testing.expect_value(t, len(manual.clips), 1)
	if len(manual.clips) == 1 {
		testing.expect(t, manual.clips[0].dance_bpm_user_set)
		testing.expect_value(t, manual.clips[0].dance_count_in_bpm, 128)
		testing.expect_value(t, manual.clips[0].dance_detected_bpm, 128.25)
	}
}

@(test)
bpm_portable_fields_round_trip_and_older_input_defaults_safely_test :: proc(t: ^testing.T) {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	clip := Portable_Clip{
		id = "clip-1",
		source_id = "source-1",
		workflow = .Dancing,
		name = "Dance clip",
		start_seconds = 0,
		end_seconds = 10,
		dance_count_in_bpm = 128,
		dance_detected_bpm = 127.9,
		dance_bpm_confidence = 0.8,
		dance_bpm_detector_revision = BPM_DETECTOR_REVISION,
		dance_bpm_user_set = true,
		dance_beat_period_seconds = 60.0/127.9,
		dance_beat_grid_offset_seconds = 0.2,
		dance_beat_phase_confidence = 0.7,
		dance_beat_phase_user_set = true,
		dance_metronome_enabled = true,
		dance_playback_rate = 1,
	}
	encoded, encode_error := json.marshal(clip, {}, context.temp_allocator)
	testing.expect(t, encode_error == nil)
	if encode_error != nil {return}
	decoded: Portable_Clip
	decode_error := json.unmarshal(encoded, &decoded, .JSON, context.temp_allocator)
	testing.expect(t, decode_error == nil)
	if decode_error == nil {
		testing.expect_value(t, decoded.dance_detected_bpm, 127.9)
		testing.expect_value(t, decoded.dance_bpm_confidence, f32(0.8))
		testing.expect_value(t, decoded.dance_bpm_detector_revision, BPM_DETECTOR_REVISION)
		testing.expect(t, decoded.dance_bpm_user_set)
		testing.expect(t, decoded.dance_beat_phase_user_set)
		testing.expect(t, decoded.dance_metronome_enabled)
	}

	older_clips := [2]Portable_Clip{
		{workflow=.Dancing, dance_count_in_bpm=120},
		{workflow=.Vocal, dance_count_in_bpm=120},
	}
	older := Portable_Library{version=2, clips=older_clips[:]}
	portable_library_apply_compatibility(&older)
	testing.expect(t, older.clips[0].dance_bpm_user_set)
	testing.expect_value(t, older.clips[0].dance_beat_period_seconds, 0.5)
	testing.expect(t, !older.clips[1].dance_bpm_user_set)

	current_clips := [1]Portable_Clip{{
		workflow=.Dancing,
		dance_count_in_bpm=120,
	}}
	current := Portable_Library{version=PORTABLE_LIBRARY_VERSION, clips=current_clips[:]}
	portable_library_apply_compatibility(&current)
	testing.expect(t, !current.clips[0].dance_bpm_user_set)
}

@(test)
bpm_persisted_detection_rejects_non_finite_and_inconsistent_values_test :: proc(t: ^testing.T) {
	testing.expect(t, bpm_persisted_detection_valid(0, 0, 0))
	testing.expect(t, bpm_persisted_detection_valid(128.25, 0.8, 1))
	testing.expect(t, !bpm_persisted_detection_valid(128.25, 0.8, 0))
	testing.expect(t, !bpm_persisted_detection_valid(0, 0.8, 1))
	testing.expect(t, !bpm_persisted_detection_valid(39, 0.8, 1))
	testing.expect(t, !bpm_persisted_detection_valid(241, 0.8, 1))
	testing.expect(t, !bpm_persisted_detection_valid(128, 1.1, 1))
	testing.expect(t, !bpm_persisted_detection_valid(math.nan_f64(), 0.8, 1))
}
