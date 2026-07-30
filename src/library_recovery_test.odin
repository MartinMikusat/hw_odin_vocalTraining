package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import os2 "core:os/os2"
import "core:strings"
import "core:testing"
import "base:runtime"
import mem_virtual "core:mem/virtual"

recovery_test_temp_path :: proc() -> (string, bool) {
	file, create_error := os2.create_temp_file(
		"",
		"hw_videoClips-recovery-*.sqlite3",
	)
	if create_error != nil {return "", false}
	path, clone_error := strings.clone(os2.name(file))
	_ = os2.close(file)
	if clone_error != nil {return "", false}
	_ = os.remove(path)
	return path, true
}

legacy_workflow_test_database_create :: proc(path: string) -> bool {
	database, opened := library_database_open_path(
		path,
		SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE,
	)
	if !opened {return false}
	defer sqlite3_close(database)
	return sqlite_execute(database, `
		PRAGMA foreign_keys = ON;
		CREATE TABLE sources (
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
		CREATE TABLE transcript_segments (
			id TEXT PRIMARY KEY,
			source_id TEXT NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
			start_seconds REAL NOT NULL,
			duration_seconds REAL NOT NULL,
			text TEXT NOT NULL,
			position INTEGER NOT NULL
		);
		CREATE TABLE import_hints (
			source_id TEXT NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
			seconds REAL NOT NULL,
			position INTEGER NOT NULL,
			PRIMARY KEY(source_id, seconds)
		);
		CREATE TABLE exercises (
			id TEXT PRIMARY KEY,
			source_id TEXT NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
			name TEXT NOT NULL,
			start_seconds REAL NOT NULL,
			end_seconds REAL NOT NULL,
			clip_path TEXT NOT NULL,
			position INTEGER NOT NULL
		);
		CREATE TABLE exercise_randomization (
			exercise_id TEXT PRIMARY KEY,
			last_sequence INTEGER NOT NULL
		);
		CREATE TABLE library_meta (
			id INTEGER PRIMARY KEY CHECK (id = 1),
			current_revision INTEGER NOT NULL
		);
		CREATE TABLE library_revisions (
			revision INTEGER PRIMARY KEY,
			committed_at_ms INTEGER NOT NULL
		);
		CREATE TABLE library_changes (
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
		INSERT INTO library_meta VALUES (1, 1);
		INSERT INTO library_revisions VALUES (1, 0);
		INSERT INTO sources VALUES (
			'source-vocal', 'video-vocal', 'Legacy source',
			'https://youtu.be/video-vocal', 'sources/video-vocal.mp4',
			120, 0, 1, 1920, 1080, 30, 'h264', 'aac', 'mp4',
			'legacy', 1000
		);
		INSERT INTO transcript_segments VALUES (
			'segment-1', 'source-vocal', 1, 2, 'Legacy text', 0
		);
		INSERT INTO import_hints VALUES ('source-vocal', 5, 0);
		INSERT INTO exercises VALUES (
			'clip-keep', 'source-vocal', 'Legacy keep',
			10, 20, 'clips/clip-keep.mp4', 0
		);
		INSERT INTO exercises VALUES (
			'clip-delete', 'source-vocal', 'Legacy delete',
			30, 40, 'clips/clip-delete.mp4', 1
		);
		INSERT INTO exercises VALUES (
			'clip-restore', 'source-vocal', 'Legacy restore',
			50, 60, 'clips/clip-restore.mp4', 2
		);
		INSERT INTO exercise_randomization VALUES ('clip-restore', 11);
		PRAGMA user_version = 5;
	`)
}

@(test)
schema_v7_repairs_missing_vocal_clips_without_resurrecting_deletions_test :: proc(
	t: ^testing.T,
) {
	previous_support, support_found := os.lookup_env(
		"HW_VIDEO_CLIPS_APP_SUPPORT_DIR",
	)
	defer {
		recovery_activation_test_restore_environment(
			previous_support,
			support_found,
		)
		delete(previous_support)
	}
	root, created := recovery_test_temp_path()
	testing.expect(t, created)
	if !created {return}
	testing.expect(t, os.make_directory(root) == nil)
	defer {
		_ = os2.remove_all(root)
		delete(root)
	}
	testing.expect(t, os.set_env(
		"HW_VIDEO_CLIPS_APP_SUPPORT_DIR",
		root,
	) == nil)
	testing.expect(t, os.make_directory(library_backups_dir()) == nil)
	backup_path := fmt.tprintf(
		"%s/library-r00000000000000000001-legacy.sqlite3",
		library_backups_dir(),
	)
	testing.expect(t, legacy_workflow_test_database_create(backup_path))
	_, backup_valid := library_backup_verify(
		backup_path,
		1,
		5,
	)
	testing.expect(t, backup_valid)

	database, opened := library_database_open_path(
		database_path(),
		SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE,
	)
	testing.expect(t, opened)
	if !opened {return}
	defer sqlite3_close(database)
	testing.expect(t, database_create_schema_v7(database))
	source := Source_Video{
		id = "source-vocal",
		workflow = .Vocal,
		video_id = "video-vocal",
		title = "Current source",
		url = "https://youtu.be/video-vocal",
		media_path = fmt.tprintf("%s/sources/video-vocal.mp4", root),
		duration = 120,
	}
	keep := Clip{
		id = "clip-keep",
		source_id = "source-vocal",
		workflow = .Vocal,
		name = "Current keep",
		start_seconds = 10,
		end_seconds = 20,
		clip_path = fmt.tprintf("%s/clips/clip-keep.mp4", root),
		dance_count_in_bpm = 120,
		dance_playback_rate = 1,
	}
	deleted := Clip{
		id = "clip-delete",
		source_id = "source-vocal",
		workflow = .Vocal,
		name = "Current delete",
		start_seconds = 30,
		end_seconds = 40,
		clip_path = fmt.tprintf("%s/clips/clip-delete.mp4", root),
		dance_count_in_bpm = 120,
		dance_playback_rate = 1,
	}
	testing.expect(t, database_save_collections(
		database,
		[]Source_Video{source},
		nil,
		nil,
		[]Clip{keep, deleted},
	))
	testing.expect(t, database_save_collections(
		database,
		[]Source_Video{source},
		nil,
		nil,
		[]Clip{keep},
	))
	testing.expect(t, database_clip_delete_logged(database, "clip-delete"))
	testing.expect(t, sqlite_execute(database, "PRAGMA user_version = 6"))

	testing.expect(t, database_create_schema(database))
	version, version_read := library_database_user_version(database)
	testing.expect(t, version_read)
	testing.expect_value(t, version, LIBRARY_SCHEMA_VERSION)
	loaded: App_State
	testing.expect(t, database_load_state(database, &loaded))
	defer app_state_collections_destroy(&loaded)
	testing.expect_value(t, len(loaded.clips), 2)
	keep_index := library_clip_index(loaded.clips[:], "clip-keep")
	restore_index := library_clip_index(loaded.clips[:], "clip-restore")
	testing.expect(t, keep_index >= 0 && restore_index >= 0)
	testing.expect_value(t, loaded.clips[keep_index].name, "Current keep")
	testing.expect_value(
		t,
		loaded.clips[restore_index].workflow,
		Workflow_Kind.Vocal,
	)
	testing.expect_value(
		t,
		loaded.clips[restore_index].dance_count_in_bpm,
		120,
	)
	testing.expect_value(
		t,
		loaded.clips[restore_index].dance_playback_rate,
		f32(1),
	)
	testing.expect_value(
		t,
		loaded.clips[restore_index].last_randomized_sequence,
		i64(11),
	)
	testing.expect_value(
		t,
		library_clip_index(loaded.clips[:], "clip-delete"),
		-1,
	)
	notification_count, notifications_counted := database_count(
		database,
		"notifications",
	)
	testing.expect(t, notifications_counted)
	testing.expect_value(t, notification_count, 1)
	revision := library_revision_current(database)
	testing.expect(t, database_create_schema(database))
	testing.expect_value(t, library_revision_current(database), revision)
}

legacy_manifest_test_write :: proc(root: string) -> bool {
	data := Persisted_State{version=1}
	data.sources = make([dynamic]Source_Video, context.temp_allocator)
	data.exercises = make([dynamic]Legacy_Exercise, context.temp_allocator)
	append(&data.sources, Source_Video{
		id = "json-source",
		video_id = "json-video",
		title = "JSON source",
		url = "https://youtu.be/json-video",
		media_path = fmt.tprintf("%s/sources/json-video.mp4", root),
		duration = 60,
	})
	append(&data.exercises, Legacy_Exercise{
		id = "json-clip",
		source_id = "json-source",
		name = "JSON exercise",
		start_seconds = 10,
		end_seconds = 20,
		clip_path = fmt.tprintf("%s/clips/json-clip.mp4", root),
	})
	encoded, encode_error := json.marshal(
		data,
		{pretty=true, use_spaces=true, spaces=2},
		context.temp_allocator,
	)
	if encode_error != nil {return false}
	return os.write_entire_file(
		fmt.tprintf("%s/library.json", root),
		encoded,
	)
}

@(test)
json_only_legacy_exercises_import_as_vocal_clips_test :: proc(
	t: ^testing.T,
) {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	previous_support, support_found := os.lookup_env(
		"HW_VIDEO_CLIPS_APP_SUPPORT_DIR",
	)
	defer {
		recovery_activation_test_restore_environment(
			previous_support,
			support_found,
		)
		delete(previous_support)
	}
	root, created := recovery_test_temp_path()
	testing.expect(t, created)
	if !created {return}
	testing.expect(t, os.make_directory(root) == nil)
	defer {
		_ = os2.remove_all(root)
		delete(root)
	}
	testing.expect(t, os.set_env(
		"HW_VIDEO_CLIPS_APP_SUPPORT_DIR",
		root,
	) == nil)
	testing.expect(t, legacy_manifest_test_write(root))

	previous_state := state
	previous_recovery := library_recovery_state
	previous_mode := library_storage_mode
	previous_fallback := library_legacy_fallback
	state = {}
	library_recovery_state = {}
	library_storage_mode = .Closed
	library_legacy_fallback = false
	defer {
		database_close()
		app_state_collections_destroy(&state)
		library_recovery_state_destroy()
		state = previous_state
		library_recovery_state = previous_recovery
		library_storage_mode = previous_mode
		library_legacy_fallback = previous_fallback
	}
	result := load_library()
	defer library_load_result_destroy(&result)
	testing.expect_value(t, result.mode, Library_Storage_Mode.Ready)
	testing.expect_value(t, len(state.sources), 1)
	testing.expect_value(t, len(state.clips), 1)
	testing.expect_value(t, state.clips[0].id, "json-clip")
	testing.expect_value(t, state.clips[0].workflow, Workflow_Kind.Vocal)
	testing.expect_value(t, state.clips[0].dance_count_in_bpm, 120)
	testing.expect_value(t, state.clips[0].dance_playback_rate, f32(1))
	testing.expect(t, !os.exists(fmt.tprintf("%s/library.json", root)))
	testing.expect(t, os.exists(fmt.tprintf("%s/Legacy", root)))
}

@(test)
stale_legacy_manifest_does_not_replace_migrated_database_test :: proc(
	t: ^testing.T,
) {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	previous_support, support_found := os.lookup_env(
		"HW_VIDEO_CLIPS_APP_SUPPORT_DIR",
	)
	defer {
		recovery_activation_test_restore_environment(
			previous_support,
			support_found,
		)
		delete(previous_support)
	}
	root, created := recovery_test_temp_path()
	testing.expect(t, created)
	if !created {return}
	testing.expect(t, os.make_directory(root) == nil)
	defer {
		_ = os2.remove_all(root)
		delete(root)
	}
	testing.expect(t, os.set_env(
		"HW_VIDEO_CLIPS_APP_SUPPORT_DIR",
		root,
	) == nil)
	testing.expect(t, legacy_workflow_test_database_create(database_path()))
	empty_manifest := `{
		"version": 1,
		"sources": [],
		"segments": [],
		"hints": [],
		"exercises": []
	}`
	testing.expect(t, os.write_entire_file(
		manifest_path(),
		transmute([]byte)empty_manifest,
	))

	previous_state := state
	previous_recovery := library_recovery_state
	previous_mode := library_storage_mode
	previous_fallback := library_legacy_fallback
	state = {}
	library_recovery_state = {}
	library_storage_mode = .Closed
	library_legacy_fallback = false
	defer {
		database_close()
		app_state_collections_destroy(&state)
		library_recovery_state_destroy()
		state = previous_state
		library_recovery_state = previous_recovery
		library_storage_mode = previous_mode
		library_legacy_fallback = previous_fallback
	}
	result := load_library()
	defer library_load_result_destroy(&result)
	testing.expect_value(t, result.mode, Library_Storage_Mode.Ready)
	testing.expect_value(t, len(state.sources), 1)
	testing.expect_value(t, len(state.clips), 3)
	testing.expect(t, database_foreign_keys_ok(library_database))
	for clip in state.clips {
		testing.expect_value(t, clip.workflow, Workflow_Kind.Vocal)
	}
	testing.expect(t, !os.exists(manifest_path()))
	testing.expect(t, os.exists(fmt.tprintf("%s/Legacy", root)))
}

@(test)
legacy_application_support_directory_moves_without_copying_test :: proc(
	t: ^testing.T,
) {
	root, created := recovery_test_temp_path()
	testing.expect(t, created)
	if !created {return}
	testing.expect(t, os.make_directory(root) == nil)
	defer {
		_ = os2.remove_all(root)
		delete(root)
	}
	legacy := fmt.tprintf("%s/VocalTraining", root)
	current := fmt.tprintf("%s/hw_videoClips", root)
	testing.expect(t, os.make_directory(legacy) == nil)
	legacy_database := fmt.tprintf("%s/library.sqlite3", legacy)
	contents := string("legacy")
	testing.expect(
		t,
		os.write_entire_file(
			legacy_database,
			transmute([]byte)contents,
		),
	)
	testing.expect(t, migrate_legacy_app_support_paths(current, legacy))
	testing.expect(t, !os.exists(legacy))
	testing.expect(t, os.exists(fmt.tprintf("%s/library.sqlite3", current)))
}

@(test)
malformed_required_text_fails_without_replacing_destination_test :: proc(
	t: ^testing.T,
) {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	fixture_path, found := os.lookup_env("HW_VIDEO_CLIPS_TEST_LIBRARY")
	defer delete(fixture_path)
	testing.expect(t, found)
	if !found {return}
	path, created := recovery_test_temp_path()
	testing.expect(t, created)
	if !created {return}
	defer {
		_ = os.remove(path)
		delete(path)
	}
	testing.expect(t, library_database_copy(fixture_path, path))
	database, opened := library_database_open_path(
		path,
		SQLITE_OPEN_READWRITE,
	)
	testing.expect(t, opened)
	if !opened {return}
	defer if database != nil {sqlite3_close(database)}
	testing.expect(t, sqlite_execute(
		database,
		`UPDATE sources
		 SET title = CAST(X'80' AS TEXT)
		 WHERE id = (SELECT id FROM sources ORDER BY position LIMIT 1)`,
	))

	destination: App_State
	destination.sources = make([dynamic]Source_Video)
	destination.hints = make([dynamic]Import_Hint)
	destination.clips = make([dynamic]Clip)
	destination.transcripts, _ = transcript_generation_create()
	defer app_state_collections_destroy(&destination)
	existing, copied := clone_source_video(Source_Video{
		id = "existing-source",
		video_id = "existing-video",
		title = "Existing",
		url = "https://youtu.be/existing-video",
		media_path = "/tmp/existing.mp4",
		duration = 10,
	})
	testing.expect(t, copied)
	if !copied {return}
	append(&destination.sources, existing)

	result := database_load_state_result(database, &destination)
	defer library_load_result_destroy(&result)
	testing.expect(t, result.mode == .Recovery_Required)
	testing.expect(t, result.stage == .Sources)
	testing.expect_value(t, len(destination.sources), 1)
	testing.expect_value(t, destination.sources[0].id, "existing-source")

	testing.expect(t, sqlite_execute(
		database,
		`UPDATE sources
		 SET title = 'Repaired source'
		 WHERE id = (SELECT id FROM sources ORDER BY position LIMIT 1)`,
	))
	sqlite3_close(database)
	database = nil
	database, opened = library_database_open_path(path, SQLITE_OPEN_READONLY)
	testing.expect(t, opened)
	if !opened {return}
	restored: App_State
	restore_result := database_load_state_result(database, &restored)
	defer library_load_result_destroy(&restore_result)
	defer app_state_collections_destroy(&restored)
	testing.expect(t, restore_result.mode == .Ready)
	testing.expect_value(t, len(restored.sources), 7)
	testing.expect_value(t, len(restored.transcripts.segments), 1532)
	testing.expect_value(t, len(restored.hints), 12)
	testing.expect_value(t, len(restored.clips), 1)
}

@(test)
salvage_keeps_valid_rows_and_rejects_corrupt_dependencies_test :: proc(
	t: ^testing.T,
) {
	database, opened := library_database_open_path(
		":memory:",
		SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE,
	)
	testing.expect(t, opened)
	if !opened {return}
	defer sqlite3_close(database)
	testing.expect(t, database_create_schema(database))
	sources := [2]Source_Video{
		{
			id = "source-good",
			video_id = "video-good",
			title = "Good",
			url = "https://youtu.be/video-good",
			media_path = "/tmp/good.mp4",
			duration = 60,
		},
		{
			id = "source-bad",
			video_id = "video-bad",
			title = "Bad",
			url = "https://youtu.be/video-bad",
			media_path = "/tmp/bad.mp4",
			duration = 60,
		},
	}
	clips := [2]Clip{
		{
			id = "clip-good",
			source_id = "source-good",
			name = "Good",
			start_seconds = 1,
			end_seconds = 2,
			clip_path = "/tmp/good-clip.mp4",
		},
		{
			id = "clip-bad",
			source_id = "source-bad",
			name = "Bad",
			start_seconds = 1,
			end_seconds = 2,
			clip_path = "/tmp/bad-clip.mp4",
		},
	}
	testing.expect(t, database_save_collections(
		database,
		sources[:],
		nil,
		nil,
		clips[:],
	))
	testing.expect(t, sqlite_execute(
		database,
		"PRAGMA foreign_keys = OFF",
	))
	testing.expect(t, sqlite_execute(
		database,
		`UPDATE sources
		 SET title = CAST(X'80' AS TEXT)
		 WHERE id = 'source-bad'`,
	))
	report: Library_Recovery_Report
	salvage, _ := database_salvage_state(database, &report)
	defer app_state_collections_destroy(&salvage)
	testing.expect_value(t, len(salvage.sources), 1)
	testing.expect_value(t, salvage.sources[0].id, "source-good")
	testing.expect_value(t, len(salvage.clips), 1)
	testing.expect_value(t, salvage.clips[0].id, "clip-good")
	testing.expect(t, report.rejected_records >= 2)
}

@(test)
revision_log_commits_and_rolls_back_with_library_rows_test :: proc(
	t: ^testing.T,
) {
	database, opened := library_database_open_path(
		":memory:",
		SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE,
	)
	testing.expect(t, opened)
	if !opened {return}
	defer sqlite3_close(database)
	testing.expect(t, database_create_schema(database))
	initial_revision := library_revision_current(database)
	source := Source_Video{
		id = "source-1",
		video_id = "video-1",
		title = "Source",
		url = "https://youtu.be/video-1",
		media_path = "/tmp/source.mp4",
		duration = 60,
	}
	testing.expect(t, database_save_collections(
		database,
		[]Source_Video{source},
		nil,
		nil,
		nil,
	))
	committed_revision := library_revision_current(database)
	testing.expect_value(t, committed_revision, initial_revision+1)
	change_count, counted := database_count(database, "library_changes")
	testing.expect(t, counted)
	testing.expect_value(t, change_count, 1)

	testing.expect(t, sqlite_execute(
		database,
		`CREATE TRIGGER fail_source_insert
		 BEFORE INSERT ON sources
		 BEGIN
		   SELECT RAISE(ABORT, 'forced failure');
		 END`,
	))
	source.title = "Changed"
	testing.expect(t, !database_save_collections(
		database,
		[]Source_Video{source},
		nil,
		nil,
		nil,
	))
	testing.expect_value(t, library_revision_current(database), committed_revision)
	change_count, counted = database_count(database, "library_changes")
	testing.expect(t, counted)
	testing.expect_value(t, change_count, 1)
}

@(test)
verified_backup_is_reused_for_the_same_revision_test :: proc(t: ^testing.T) {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	fixture_path, found := os.lookup_env("HW_VIDEO_CLIPS_TEST_LIBRARY")
	defer delete(fixture_path)
	testing.expect(t, found)
	if !found {return}
	database, opened := library_database_open_path(
		fixture_path,
		SQLITE_OPEN_READONLY,
	)
	testing.expect(t, opened)
	if !opened {return}
	defer sqlite3_close(database)
	first := library_backup_create(database)
	defer library_backup_result_destroy(&first)
	testing.expect(t, first.status != .Failed)
	_, verified := library_backup_verify(first.path, first.revision)
	testing.expect(t, verified)
	second := library_backup_create(database)
	defer library_backup_result_destroy(&second)
	testing.expect(t, second.status == .Reused)
	testing.expect_value(t, second.path, first.path)
}

@(test)
recovery_merge_applies_valid_upserts_and_logged_deletions_test :: proc(
	t: ^testing.T,
) {
	backup: App_State
	backup.sources = make([dynamic]Source_Video)
	salvage: App_State
	salvage.sources = make([dynamic]Source_Video)
	defer {
		delete(backup.sources)
		delete(salvage.sources)
	}
	append(&backup.sources, Source_Video{
		id = "source-update",
		video_id = "video-update",
		title = "Before",
		url = "https://youtu.be/video-update",
		media_path = "/tmp/update.mp4",
		duration = 60,
	})
	append(&backup.sources, Source_Video{
		id = "source-delete",
		video_id = "video-delete",
		title = "Delete",
		url = "https://youtu.be/video-delete",
		media_path = "/tmp/delete.mp4",
		duration = 60,
	})
	append(&salvage.sources, Source_Video{
		id = "source-update",
		video_id = "video-update",
		title = "After",
		url = "https://youtu.be/video-update",
		media_path = "/tmp/update.mp4",
		duration = 60,
	})
	append(&salvage.sources, Source_Video{
		id = "source-new",
		video_id = "video-new",
		title = "New",
		url = "https://youtu.be/video-new",
		media_path = "/tmp/new.mp4",
		duration = 60,
	})
	changes := [3]Library_Change_Record{
		{
			revision = 2,
			entity = .Source,
			id = "source-update",
			operation = .Upsert,
		},
		{
			revision = 2,
			entity = .Source,
			id = "source-new",
			operation = .Upsert,
		},
		{
			revision = 2,
			entity = .Source,
			id = "source-delete",
			operation = .Delete,
		},
	}
	report: Library_Recovery_Report
	candidate, built := library_recovery_build_candidate(
		&backup,
		&salvage,
		changes[:],
		true,
		&report,
	)
	testing.expect(t, built)
	if !built {return}
	defer app_state_collections_destroy(&candidate)
	testing.expect_value(t, len(candidate.sources), 2)
	testing.expect_value(t, candidate.sources[0].id, "source-update")
	testing.expect_value(t, candidate.sources[0].title, "After")
	testing.expect_value(t, candidate.sources[1].id, "source-new")
	testing.expect_value(t, report.replayed_deletions, 1)
}

@(test)
valid_backup_remains_ready_when_salvage_merge_is_invalid_test :: proc(
	t: ^testing.T,
) {
	backup: App_State
	backup.sources = make([dynamic]Source_Video)
	salvage: App_State
	salvage.sources = make([dynamic]Source_Video)
	defer {
		delete(backup.sources)
		delete(salvage.sources)
	}
	append(&backup.sources, Source_Video{
		id = "source-backup",
		video_id = "shared-video",
		title = "Backup",
		url = "https://youtu.be/shared-video",
		media_path = "/tmp/backup.mp4",
		duration = 60,
	})
	append(&salvage.sources, Source_Video{
		id = "source-salvage",
		video_id = "shared-video",
		title = "Salvage",
		url = "https://youtu.be/shared-video",
		media_path = "/tmp/salvage.mp4",
		duration = 60,
	})
	report: Library_Recovery_Report
	candidate, built := library_recovery_build_candidate(
		&backup,
		&salvage,
		nil,
		false,
		&report,
	)
	testing.expect(t, !built)
	app_state_collections_destroy(&candidate)

	previous := library_recovery_state
	previous_ui := ui
	previous_ui_build := ui_build
	library_recovery_state = {
		required = true,
		recovery_allowed = true,
		report = {backup_available=true},
	}
	defer {
		library_recovery_state_destroy()
		library_recovery_state = previous
		ui = previous_ui
		ui_build = previous_ui_build
	}
	testing.expect(t, library_recovery_finish_analysis(false, nil))
	testing.expect(t, library_recovery_state.analysis_complete)
	testing.expect(t, library_recovery_state.backup_ready)
	testing.expect(t, !library_recovery_state.merge_ready)
	testing.expect(t, !library_recovery_state.salvage_ready)
	testing.expect(t, library_recovery_state.option == .Backup_Only)
	ui = UI_State{width=1100, height=720}
	frame_arena: mem_virtual.Arena
	arena_error := mem_virtual.arena_init_static(
		&frame_arena,
		1024*1024,
		4096,
	)
	testing.expect(t, arena_error == nil)
	if arena_error != nil {return}
	defer mem_virtual.arena_destroy(&frame_arena)
	build_ui_controls(false, mem_virtual.arena_allocator(&frame_arena))
	testing.expect(
		t,
		find_ui_control_by_action(.Recovery_Backup_Only) != nil,
	)
	testing.expect(
		t,
		find_ui_control_by_action(.Recovery_Backup_With_Salvage) == nil,
	)
}

recovery_activation_test_restore_environment :: proc(
	previous: string,
	found: bool,
) {
	if found {
		_ = os.set_env("HW_VIDEO_CLIPS_APP_SUPPORT_DIR", previous)
	} else {
		_ = os.unset_env("HW_VIDEO_CLIPS_APP_SUPPORT_DIR")
	}
}

@(test)
activation_reconciliation_preserves_archive_at_each_boundary_test :: proc(
	t: ^testing.T,
) {
	previous_support, support_found := os.lookup_env("HW_VIDEO_CLIPS_APP_SUPPORT_DIR")
	defer {
		recovery_activation_test_restore_environment(
			previous_support,
			support_found,
		)
		delete(previous_support)
	}
	boundaries := [5]Library_Recovery_Activation_Boundary{
		.Marker_Written,
		.Archive_Main_Copied,
		.Archive_Complete,
		.Candidate_Renamed,
		.Sidecars_Removed,
	}
	for boundary, boundary_index in boundaries {
		root, created := recovery_test_temp_path()
		testing.expect(t, created)
		if !created {return}
		testing.expect(t, os.make_directory(root) == nil)
		defer {
			_ = os2.remove_all(root)
			delete(root)
		}
		testing.expect(t, os.set_env("HW_VIDEO_CLIPS_APP_SUPPORT_DIR", root) == nil)
		testing.expect(
			t,
			os.make_directory(library_failed_recovery_dir()) == nil,
		)
		active_path := database_path()
		candidate_path := fmt.tprintf(
			"%s/candidate-%d.sqlite3",
			root,
			boundary_index,
		)
		archive_path := fmt.tprintf(
			"%s/archive-%d.sqlite3",
			library_failed_recovery_dir(),
			boundary_index,
		)
		failed_main := "failed-main"
		failed_wal := "failed-wal"
		failed_shm := "failed-shm"
		candidate_main := "candidate-main"
		testing.expect(t, os.write_entire_file(
			active_path,
			transmute([]byte)failed_main,
		))
		testing.expect(t, os.write_entire_file(
			fmt.tprintf("%s-wal", active_path),
			transmute([]byte)failed_wal,
		))
		testing.expect(t, os.write_entire_file(
			fmt.tprintf("%s-shm", active_path),
			transmute([]byte)failed_shm,
		))
		testing.expect(t, os.write_entire_file(
			candidate_path,
			transmute([]byte)candidate_main,
		))
		candidate, candidate_ok :=
			library_recovery_file_fingerprint(candidate_path)
		active, active_ok := library_recovery_file_fingerprint(active_path)
		wal, wal_ok := library_recovery_file_fingerprint(
			fmt.tprintf("%s-wal", active_path),
		)
		shm, shm_ok := library_recovery_file_fingerprint(
			fmt.tprintf("%s-shm", active_path),
		)
		testing.expect(t, candidate_ok && active_ok && wal_ok && shm_ok)
		record := Library_Recovery_Activation_Record{
			version = 1,
			phase = .Prepared,
			candidate_path = strings.clone(candidate_path),
			archive_path = strings.clone(archive_path),
			candidate = candidate,
			active_main = active,
			active_wal = wal,
			active_shm = shm,
		}
		defer library_recovery_activation_record_destroy(&record)
		testing.expect(t, library_recovery_record_write(&record))
		if boundary != .Marker_Written {
			testing.expect(
				t,
				library_recovery_activation_finish(&record, boundary) ==
					.Interrupted,
			)
		}
		testing.expect(t, library_recovery_reconcile_activation())
		active_bytes, active_read := os.read_entire_file(
			active_path,
			context.temp_allocator,
		)
		archive_bytes, archive_read := os.read_entire_file(
			archive_path,
			context.temp_allocator,
		)
		wal_bytes, archive_wal_read := os.read_entire_file(
			fmt.tprintf("%s-wal", archive_path),
			context.temp_allocator,
		)
		shm_bytes, archive_shm_read := os.read_entire_file(
			fmt.tprintf("%s-shm", archive_path),
			context.temp_allocator,
		)
		testing.expect(t, active_read && archive_read)
		testing.expect(t, archive_wal_read && archive_shm_read)
		testing.expect_value(t, string(active_bytes), "candidate-main")
		testing.expect_value(t, string(archive_bytes), "failed-main")
		testing.expect_value(t, string(wal_bytes), "failed-wal")
		testing.expect_value(t, string(shm_bytes), "failed-shm")
		testing.expect(t, !os.exists(fmt.tprintf("%s-wal", active_path)))
		testing.expect(t, !os.exists(fmt.tprintf("%s-shm", active_path)))
		testing.expect(t, !os.exists(library_recovery_marker_path()))
	}
}

@(test)
malformed_activation_record_preserves_all_database_files_test :: proc(
	t: ^testing.T,
) {
	previous_support, support_found := os.lookup_env("HW_VIDEO_CLIPS_APP_SUPPORT_DIR")
	defer {
		recovery_activation_test_restore_environment(
			previous_support,
			support_found,
		)
		delete(previous_support)
	}
	root, created := recovery_test_temp_path()
	testing.expect(t, created)
	if !created {return}
	testing.expect(t, os.make_directory(root) == nil)
	defer {
		_ = os2.remove_all(root)
		delete(root)
	}
	testing.expect(t, os.set_env("HW_VIDEO_CLIPS_APP_SUPPORT_DIR", root) == nil)
	active_path := database_path()
	candidate_path := fmt.tprintf("%s/candidate.sqlite3", root)
	active_text := "failed-main"
	candidate_text := "candidate-main"
	marker_text := "{invalid"
	testing.expect(t, os.write_entire_file(
		active_path,
		transmute([]byte)active_text,
	))
	testing.expect(t, os.write_entire_file(
		candidate_path,
		transmute([]byte)candidate_text,
	))
	testing.expect(t, os.write_entire_file(
		library_recovery_marker_path(),
		transmute([]byte)marker_text,
	))
	testing.expect(t, !library_recovery_reconcile_activation())
	active_bytes, active_read := os.read_entire_file(
		active_path,
		context.temp_allocator,
	)
	candidate_bytes, candidate_read := os.read_entire_file(
		candidate_path,
		context.temp_allocator,
	)
	testing.expect(t, active_read && candidate_read)
	testing.expect_value(t, string(active_bytes), active_text)
	testing.expect_value(t, string(candidate_bytes), candidate_text)
	testing.expect(t, os.exists(library_recovery_marker_path()))
}

@(test)
newer_schema_is_rejected_without_modifying_the_database_test :: proc(
	t: ^testing.T,
) {
	fixture_path, fixture_found := os.lookup_env("HW_VIDEO_CLIPS_TEST_LIBRARY")
	defer delete(fixture_path)
	testing.expect(t, fixture_found)
	if !fixture_found {return}
	previous_support, support_found := os.lookup_env("HW_VIDEO_CLIPS_APP_SUPPORT_DIR")
	defer {
		recovery_activation_test_restore_environment(
			previous_support,
			support_found,
		)
		delete(previous_support)
	}
	root, created := recovery_test_temp_path()
	testing.expect(t, created)
	if !created {return}
	testing.expect(t, os.make_directory(root) == nil)
	defer {
		_ = os2.remove_all(root)
		delete(root)
	}
	testing.expect(t, os.set_env("HW_VIDEO_CLIPS_APP_SUPPORT_DIR", root) == nil)
	path := database_path()
	testing.expect(t, library_database_copy(fixture_path, path))
	database, opened := library_database_open_path(
		path,
		SQLITE_OPEN_READWRITE,
	)
	testing.expect(t, opened)
	if !opened {return}
	newer_schema := LIBRARY_SCHEMA_VERSION+1
	testing.expect(t, sqlite_execute(
		database,
		fmt.tprintf("PRAGMA user_version = %d", newer_schema),
	))
	sqlite3_close(database)
	before, before_hashed := library_recovery_file_fingerprint(path)
	testing.expect(t, before_hashed)

	previous_recovery := library_recovery_state
	previous_mode := library_storage_mode
	library_recovery_state = {}
	library_storage_mode = .Closed
	defer {
		database_close()
		library_recovery_state_destroy()
		library_recovery_state = previous_recovery
		library_storage_mode = previous_mode
	}
	result := load_library()
	defer library_load_result_destroy(&result)
	testing.expect(t, result.mode == .Recovery_Required)
	testing.expect(t, result.stage == .Schema)
	testing.expect_value(t, result.schema_version, newer_schema)
	testing.expect(t, library_database == nil)
	testing.expect(t, !library_recovery_state.recovery_allowed)
	after, after_hashed := library_recovery_file_fingerprint(path)
	testing.expect(t, after_hashed)
	testing.expect_value(t, after, before)
	database, opened = library_database_open_path(path, SQLITE_OPEN_READONLY)
	testing.expect(t, opened)
	if !opened {return}
	version, version_read := library_database_user_version(database)
	sqlite3_close(database)
	testing.expect(t, version_read)
	testing.expect_value(t, version, newer_schema)
}

@(test)
notification_history_rebinds_after_recovery_activation_test :: proc(
	t: ^testing.T,
) {
	database, opened := library_database_open_path(
		":memory:",
		SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE,
	)
	testing.expect(t, opened)
	if !opened {return}
	defer sqlite3_close(database)
	testing.expect(t, database_create_schema(database))

	previous_database := library_database
	previous_fallback := library_legacy_fallback
	previous_history := notification_history
	previous_ui := ui
	library_database = database
	library_legacy_fallback = false
	notification_history = {}
	ui = {}
	defer {
		notification_history_destroy()
		delete(ui.status)
		delete(ui.status_source_video_id)
		library_database = previous_database
		library_legacy_fallback = previous_fallback
		notification_history = previous_history
		ui = previous_ui
	}
	notification_history_initialize()
	activity_id := notification_begin(
		"Importing source",
		"An unfinished operation",
	)
	testing.expect(t, activity_id > 0)

	notification_history_destroy()
	library_database = nil
	notification_history_initialize()
	_ = notification_post(
		.Error,
		"Library recovery is required",
		persist = false,
	)
	testing.expect_value(t, len(notification_history.entries), 1)
	library_database = database
	testing.expect(t, notification_history_rebind_database())
	testing.expect_value(t, len(notification_history.entries), 1)
	testing.expect(
		t,
		notification_history.entries[0].kind == .Interrupted,
	)
	_ = notification_post(
		.Success,
		"Library recovery activated",
		"The replacement library is active.",
	)

	notification_history_destroy()
	notification_history_initialize()
	testing.expect_value(t, len(notification_history.entries), 2)
	testing.expect(
		t,
		notification_history.entries[0].kind == .Interrupted,
	)
	testing.expect(
		t,
		notification_history.entries[1].kind == .Success,
	)
}

@(test)
recovery_surface_blocks_normal_application_controls_test :: proc(t: ^testing.T) {
	previous_recovery := library_recovery_state
	previous_ui := ui
	previous_ui_build := ui_build
	defer {
		library_recovery_state = previous_recovery
		ui = previous_ui
		ui_build = previous_ui_build
	}
	library_recovery_state = {
		required = true,
		recovery_allowed = true,
		analysis_complete = true,
		backup_ready = true,
		merge_ready = true,
		report = {backup_available=true},
	}
	ui = UI_State{width=1100, height=720}
	frame_arena: mem_virtual.Arena
	arena_error := mem_virtual.arena_init_static(&frame_arena, 1024*1024, 4096)
	testing.expect(t, arena_error == nil)
	if arena_error != nil {return}
	defer mem_virtual.arena_destroy(&frame_arena)
	build_ui_controls(false, mem_virtual.arena_allocator(&frame_arena))
	testing.expect(t, ui_controls_valid(ui_build.controls[:]))
	testing.expect_value(t, len(ui_build.controls), 6)
	testing.expect_value(
		t,
		ui_build.diagnostic_surface.overlay,
		"library-recovery",
	)
	testing.expect(t, find_ui_control_by_action(.Window_Close) != nil)
	testing.expect(t, find_ui_control_by_action(.Window_Minimize) != nil)
	testing.expect(t, find_ui_control_by_action(.Window_Zoom) != nil)
	settings := find_ui_control_by_action(.Open_Settings)
	testing.expect(t, settings != nil)
	if settings != nil {testing.expect(t, .Enabled not_in settings.flags)}
	testing.expect(t, find_ui_control_by_action(.Recovery_Backup_Only) != nil)
	testing.expect(t, find_ui_control_by_action(.Recovery_Backup_With_Salvage) != nil)
}
