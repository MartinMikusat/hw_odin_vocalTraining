package main

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:time"

NOTIFICATION_HISTORY_LIMIT :: 10_000
NOTIFICATION_PERSIST_INTERVAL_MS :: i64(1_000)

Notification_Kind :: enum i32 {
	Info,
	Activity,
	Success,
	Error,
	Interrupted,
}

Notification_Action_Kind :: enum i32 {
	None,
	View_Source,
}

Notification_Field :: struct {
	label: string,
	value: string,
}

Notification :: struct {
	id:                   i64,
	created_at_ms:        i64,
	updated_at_ms:        i64,
	last_persisted_at_ms: i64,
	kind:                 Notification_Kind,
	summary:              string,
	detail:               string,
	fields:               [dynamic]Notification_Field,
	action_kind:          Notification_Action_Kind,
	action_target:        string,
	simulated:            bool,
	automation_transient: bool,
}

Notification_History :: struct {
	entries:               [dynamic]Notification,
	footer_task_ids:        [dynamic]i64,
	current_id:            i64,
	selected_id:           i64,
	next_memory_id:        i64,
	initialized:           bool,
	persistence_available: bool,
}

notification_history: Notification_History

notification_now_ms :: proc() -> i64 {
	return time.to_unix_nanoseconds(time.now()) / 1_000_000
}

notification_field_destroy :: proc(field: ^Notification_Field) {
	delete(field.label)
	delete(field.value)
	field^ = {}
}

notification_destroy :: proc(notification: ^Notification) {
	delete(notification.summary)
	delete(notification.detail)
	for &field in notification.fields {notification_field_destroy(&field)}
	delete(notification.fields)
	delete(notification.action_target)
	notification^ = {}
}

notification_fields_clone :: proc(
	fields: []Notification_Field,
	allocator := context.allocator,
) -> ([dynamic]Notification_Field, bool) {
	result := make([dynamic]Notification_Field, 0, len(fields), allocator)
	for field in fields {
		label, label_error := strings.clone(field.label, allocator)
		if label_error != nil {
			for &stored in result {
				delete(stored.label, allocator)
				delete(stored.value, allocator)
			}
			delete(result)
			return nil, false
		}
		value, value_error := strings.clone(field.value, allocator)
		if value_error != nil {
			delete(label, allocator)
			for &stored in result {
				delete(stored.label, allocator)
				delete(stored.value, allocator)
			}
			delete(result)
			return nil, false
		}
		append(&result, Notification_Field{label=label, value=value})
	}
	return result, true
}

notification_fields_replace :: proc(
	destination: ^[dynamic]Notification_Field,
	fields: []Notification_Field,
) -> bool {
	copy, copied := notification_fields_clone(fields)
	if !copied {return false}
	for &field in destination^ {notification_field_destroy(&field)}
	delete(destination^)
	destination^ = copy
	return true
}

notification_find :: proc(id: i64) -> ^Notification {
	if id == 0 {return nil}
	for &notification in notification_history.entries {
		if notification.id == id {return &notification}
	}
	return nil
}

notification_latest :: proc() -> ^Notification {
	if len(notification_history.entries) == 0 {return nil}
	return &notification_history.entries[len(notification_history.entries) - 1]
}

notification_footer_has_task :: proc(id: i64) -> bool {
	for task_id in notification_history.footer_task_ids {
		if task_id == id {return true}
	}
	return false
}

notification_footer_add_task :: proc(id: i64) {
	if id == 0 || notification_footer_has_task(id) {return}
	append(&notification_history.footer_task_ids, id)
}

notification_footer_remove_task :: proc(id: i64) {
	for index := len(notification_history.footer_task_ids) - 1; index >= 0; index -= 1 {
		if notification_history.footer_task_ids[index] != id {continue}
		copy(
			notification_history.footer_task_ids[index:],
			notification_history.footer_task_ids[index+1:],
		)
		resize(
			&notification_history.footer_task_ids,
			len(notification_history.footer_task_ids)-1,
		)
		return
	}
}

notification_footer_group_active :: proc() -> bool {
	for id in notification_history.footer_task_ids {
		notification := notification_find(id)
		if notification != nil && notification.kind == .Activity {return true}
	}
	return false
}

notification_footer_finish_task :: proc(id: i64) {
	notification_footer_remove_task(id)
}

notification_present :: proc(notification: ^Notification) {
	if notification == nil {return}
	notification_history.current_id = notification.id
	ui_set_string(&ui.status, notification.summary)
	ui.status_success = notification.kind == .Success
	ui.status_error = notification.kind == .Error || notification.kind == .Interrupted
	if notification.action_kind == .View_Source {
		ui_set_string(&ui.status_source_video_id, notification.action_target)
	} else {
		ui_set_string(&ui.status_source_video_id, "")
	}
	ui.needs_redraw = true
}

notification_context_encode :: proc(
	fields: []Notification_Field,
	allocator := context.allocator,
) -> (string, bool) {
	encoded, encode_error := json.marshal(fields, {}, allocator)
	if encode_error != nil {return "", false}
	return string(encoded), true
}

notification_context_decode :: proc(
	value: string,
	allocator := context.allocator,
) -> ([dynamic]Notification_Field, bool) {
	trimmed := strings.trim_space(value)
	if len(trimmed) == 0 || trimmed == "[]" {
		return make([dynamic]Notification_Field, 0, 0, allocator), true
	}
	decoded: [dynamic]Notification_Field
	if decode_error := json.unmarshal(
		transmute([]byte)trimmed,
		&decoded,
		.JSON,
		context.temp_allocator,
	); decode_error != nil {
		return nil, false
	}
	return notification_fields_clone(decoded[:], allocator)
}

notification_database_insert :: proc(notification: ^Notification) -> bool {
	if library_database == nil || library_legacy_fallback {return false}
	context_json, encoded := notification_context_encode(
		notification.fields[:],
		context.temp_allocator,
	)
	if !encoded {return false}
	statement, prepared := sqlite_prepare(
		library_database,
		`INSERT INTO notifications (
			created_at_ms, updated_at_ms, kind, summary, detail,
			context_json, action_kind, action_target
		) VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
	)
	if !prepared {return false}
	defer sqlite3_finalize(statement)
	bound :=
		sqlite3_bind_int64(statement, 1, notification.created_at_ms) == SQLITE_OK &&
		sqlite3_bind_int64(statement, 2, notification.updated_at_ms) == SQLITE_OK &&
		sqlite3_bind_int(statement, 3, i32(notification.kind)) == SQLITE_OK &&
		sqlite_bind_text_value(statement, 4, notification.summary) &&
		sqlite_bind_text_value(statement, 5, notification.detail) &&
		sqlite_bind_text_value(statement, 6, context_json) &&
		sqlite3_bind_int(statement, 7, i32(notification.action_kind)) == SQLITE_OK &&
		sqlite_bind_text_value(statement, 8, notification.action_target)
	if !bound || sqlite3_step(statement) != SQLITE_DONE {return false}
	notification.id = sqlite3_last_insert_rowid(library_database)
	notification.last_persisted_at_ms = notification.updated_at_ms
	return true
}

notification_database_update :: proc(notification: ^Notification) -> bool {
	if library_database == nil || library_legacy_fallback || notification.id <= 0 {
		return false
	}
	context_json, encoded := notification_context_encode(
		notification.fields[:],
		context.temp_allocator,
	)
	if !encoded {return false}
	statement, prepared := sqlite_prepare(
		library_database,
		`UPDATE notifications SET
			updated_at_ms = ?, kind = ?, summary = ?, detail = ?,
			context_json = ?, action_kind = ?, action_target = ?
		  WHERE id = ?`,
	)
	if !prepared {return false}
	defer sqlite3_finalize(statement)
	bound :=
		sqlite3_bind_int64(statement, 1, notification.updated_at_ms) == SQLITE_OK &&
		sqlite3_bind_int(statement, 2, i32(notification.kind)) == SQLITE_OK &&
		sqlite_bind_text_value(statement, 3, notification.summary) &&
		sqlite_bind_text_value(statement, 4, notification.detail) &&
		sqlite_bind_text_value(statement, 5, context_json) &&
		sqlite3_bind_int(statement, 6, i32(notification.action_kind)) == SQLITE_OK &&
		sqlite_bind_text_value(statement, 7, notification.action_target) &&
		sqlite3_bind_int64(statement, 8, notification.id) == SQLITE_OK
	if !bound || sqlite3_step(statement) != SQLITE_DONE {return false}
	notification.last_persisted_at_ms = notification.updated_at_ms
	return true
}

notification_database_prune :: proc() -> bool {
	if library_database == nil || library_legacy_fallback {return false}
	return sqlite_execute(
		library_database,
		fmt.tprintf(
			`DELETE FROM notifications
			  WHERE id < COALESCE(
				(SELECT id FROM notifications ORDER BY id DESC LIMIT 1 OFFSET %d),
				-1
			  )`,
			NOTIFICATION_HISTORY_LIMIT - 1,
		),
	)
}

notification_database_mark_interrupted :: proc(now_ms: i64) -> bool {
	if library_database == nil || library_legacy_fallback {return false}
	return sqlite_execute(
		library_database,
		fmt.tprintf(
			`UPDATE notifications
			 SET kind = %d, updated_at_ms = %d
			 WHERE kind = %d`,
			i32(Notification_Kind.Interrupted),
			now_ms,
			i32(Notification_Kind.Activity),
		),
	)
}

notification_database_load :: proc() -> bool {
	if library_database == nil || library_legacy_fallback {return false}
	statement, prepared := sqlite_prepare(
		library_database,
		fmt.tprintf(
			`SELECT id, created_at_ms, updated_at_ms, kind, summary, detail,
			        context_json, action_kind, action_target
			 FROM (
				SELECT id, created_at_ms, updated_at_ms, kind, summary, detail,
				       context_json, action_kind, action_target
				FROM notifications
				ORDER BY id DESC
				LIMIT %d
			 )
			 ORDER BY id`,
			NOTIFICATION_HISTORY_LIMIT,
		),
	)
	if !prepared {return false}
	defer sqlite3_finalize(statement)
	for sqlite3_step(statement) == SQLITE_ROW {
		notification := Notification {
			id = sqlite3_column_int64(statement, 0),
			created_at_ms = sqlite3_column_int64(statement, 1),
			updated_at_ms = sqlite3_column_int64(statement, 2),
			last_persisted_at_ms = sqlite3_column_int64(statement, 2),
			kind = Notification_Kind(sqlite3_column_int(statement, 3)),
			action_kind = Notification_Action_Kind(sqlite3_column_int(statement, 7)),
		}
		copied: bool
		notification.summary, copied = sqlite_column_string(statement, 4)
		if !copied {notification_destroy(&notification); return false}
		notification.detail, copied = sqlite_column_string(statement, 5)
		if !copied {notification_destroy(&notification); return false}
		context_json, context_copied := sqlite_column_string(
			statement,
			6,
			context.temp_allocator,
		)
		if !context_copied {notification_destroy(&notification); return false}
		notification.fields, copied = notification_context_decode(context_json)
		if !copied {notification_destroy(&notification); return false}
		notification.action_target, copied = sqlite_column_string(statement, 8)
		if !copied {notification_destroy(&notification); return false}
		append(&notification_history.entries, notification)
	}
	return true
}

notification_history_remove_at :: proc(index: int) {
	if index < 0 || index >= len(notification_history.entries) {return}
	removed_id := notification_history.entries[index].id
	if notification_history.selected_id == removed_id {
		notification_history.selected_id = 0
	}
	if notification_history.current_id == removed_id {
		notification_history.current_id = 0
	}
	notification_footer_remove_task(removed_id)
	notification_destroy(&notification_history.entries[index])
	copy(
		notification_history.entries[index:],
		notification_history.entries[index+1:],
	)
	resize(&notification_history.entries, len(notification_history.entries)-1)
}

notification_history_remove_oldest :: proc() {
	if len(notification_history.entries) == 0 {return}
	was_selected := notification_history.selected_id ==
	                notification_history.entries[0].id
	replacement_id: i64
	if len(notification_history.entries) > 1 {
		replacement_id = notification_history.entries[1].id
	}
	notification_history_remove_at(0)
	if was_selected {notification_history.selected_id = replacement_id}
}

notification_history_initialize :: proc() {
	if notification_history.initialized {return}
	notification_history.entries = make(
		[dynamic]Notification,
		0,
		NOTIFICATION_HISTORY_LIMIT,
	)
	notification_history.footer_task_ids = make([dynamic]i64)
	notification_history.next_memory_id = -1
	notification_history.initialized = true
	if library_database == nil || library_legacy_fallback {return}
	now_ms := notification_now_ms()
	_ = notification_database_mark_interrupted(now_ms)
	notification_history.persistence_available = notification_database_load()
}

notification_history_rebind_database :: proc() -> bool {
	if !notification_history.initialized ||
	   library_database == nil ||
	   library_legacy_fallback {
		return false
	}
	for &notification in notification_history.entries {
		notification_destroy(&notification)
	}
	resize(&notification_history.entries, 0)
	resize(&notification_history.footer_task_ids, 0)
	notification_history.current_id = 0
	notification_history.selected_id = 0
	notification_history.next_memory_id = -1
	now_ms := notification_now_ms()
	if !notification_database_mark_interrupted(now_ms) ||
	   !notification_database_load() {
		for &notification in notification_history.entries {
			notification_destroy(&notification)
		}
		resize(&notification_history.entries, 0)
		notification_history.persistence_available = false
		return false
	}
	notification_history.persistence_available = true
	if latest := notification_latest(); latest != nil {
		notification_present(latest)
	}
	return true
}

notification_history_destroy :: proc() {
	for &notification in notification_history.entries {
		notification_destroy(&notification)
	}
	delete(notification_history.entries)
	delete(notification_history.footer_task_ids)
	notification_history = {}
}

notification_simulation_clear :: proc() {
	if !notification_history.initialized {return}
	for index := len(notification_history.entries) - 1; index >= 0; index -= 1 {
		if notification_history.entries[index].simulated {
			notification_history_remove_at(index)
		}
	}
	notification_present_latest()
}

notification_present_latest :: proc() {
	latest := notification_latest()
	if latest != nil {
		notification_present(latest)
	} else {
		ui_set_string(&ui.status, "")
		ui_set_string(&ui.status_source_video_id, "")
		ui.status_success = false
		ui.status_error = false
		ui.needs_redraw = true
	}
}

notification_automation_transient_clear :: proc() {
	if !notification_history.initialized {return}
	for index := len(notification_history.entries) - 1; index >= 0; index -= 1 {
		if notification_history.entries[index].automation_transient {
			notification_history_remove_at(index)
		}
	}
	notification_present_latest()
}

notification_simulation_active :: proc() -> bool {
	for notification in notification_history.entries {
		if notification.simulated {return true}
	}
	return false
}

notification_real_activity_active :: proc() -> bool {
	for notification in notification_history.entries {
		if !notification.simulated && notification.kind == .Activity {return true}
	}
	return false
}

notification_simulation_apply :: proc(scenario: string) -> (
	tasks: int,
	active: int,
	applied: bool,
) {
	when !DEV_TASK_SIMULATION {return 0, 0, false}
	if scenario == "clear" {
		notification_simulation_clear()
		return 0, 0, true
	}
	if notification_real_activity_active() {return 0, 0, false}
	notification_simulation_clear()
	switch scenario {
	case "parallel":
		_ = notification_begin_simulated(
			"Exporting clip...",
			"Simulated FFmpeg clip export.",
		)
		_ = notification_begin_simulated(
			"Downloading source 42%...",
			"Simulated source download.",
		)
		return 2, 2, true
	case "completed":
		_ = notification_begin_simulated(
			"Exporting clip...",
			"Simulated FFmpeg clip export.",
		)
		import_id := notification_begin_simulated(
			"Downloading source 100%...",
			"Simulated source download.",
		)
		_ = notification_finish(
			import_id,
			.Success,
			"Imported 1 source",
			"Simulated completed source import.",
		)
		return 1, 1, true
	case "overflow":
		summaries := [7]string{
			"Exporting clip...",
			"Downloading source 42%...",
			"Checking YouTube metadata...",
			"Rebuilding missing clip...",
			"Validating downloaded media...",
			"Recovering imported source...",
			"Preparing range preview...",
		}
		for summary in summaries {
			_ = notification_begin_simulated(summary, "Simulated background task.")
		}
		return 7, 7, true
	}
	return 0, 0, false
}

notification_post :: proc(
	kind: Notification_Kind,
	summary: string,
	detail := "",
	fields: []Notification_Field = nil,
	action_kind := Notification_Action_Kind.None,
	action_target := "",
	persist := true,
	simulated := false,
) -> i64 {
	if !notification_history.initialized {notification_history_initialize()}
	automation_transient :=
		!simulated &&
		ui_automation_runner.active &&
		ui_automation_runner.scenario.mutation != "persistent"
	effective_persist := persist && !automation_transient
	now_ms := notification_now_ms()
	stored_detail := detail
	if len(stored_detail) == 0 {stored_detail = summary}
	notification := Notification {
		created_at_ms = now_ms,
		updated_at_ms = now_ms,
		kind = kind,
		summary = strings.clone(summary),
		detail = strings.clone(stored_detail),
		action_kind = action_kind,
		action_target = strings.clone(action_target),
		simulated = simulated,
		automation_transient = automation_transient,
	}
	notification.fields, _ = notification_fields_clone(fields)
	if !effective_persist || !notification_database_insert(&notification) {
		notification.id = notification_history.next_memory_id
		notification_history.next_memory_id -= 1
		if effective_persist {notification_history.persistence_available = false}
	}
	append(&notification_history.entries, notification)
	for len(notification_history.entries) > NOTIFICATION_HISTORY_LIMIT {
		notification_history_remove_oldest()
	}
	if effective_persist && notification.id > 0 {_ = notification_database_prune()}
	stored := &notification_history.entries[len(notification_history.entries) - 1]
	notification_present(stored)
	return stored.id
}

notification_begin :: proc(
	summary: string,
	detail := "",
	fields: []Notification_Field = nil,
) -> i64 {
	if notification_simulation_active() {notification_simulation_clear()}
	id := notification_post(.Activity, summary, detail, fields)
	notification_footer_add_task(id)
	return id
}

notification_begin_simulated :: proc(
	summary: string,
	detail := "",
	fields: []Notification_Field = nil,
) -> i64 {
	id := notification_post(
		.Activity,
		summary,
		detail,
		fields,
		persist=false,
		simulated=true,
	)
	notification_footer_add_task(id)
	return id
}

notification_update :: proc(
	id: i64,
	summary: string,
	detail := "",
	fields: []Notification_Field = nil,
	persist_now := false,
) -> bool {
	notification := notification_find(id)
	if notification == nil {return false}
	next_summary, summary_error := strings.clone(summary)
	if summary_error != nil {return false}
	delete(notification.summary)
	notification.summary = next_summary
	if len(detail) > 0 {
		next_detail, detail_error := strings.clone(detail)
		if detail_error != nil {return false}
		delete(notification.detail)
		notification.detail = next_detail
	}
	if fields != nil && !notification_fields_replace(&notification.fields, fields) {
		return false
	}
	notification.updated_at_ms = notification_now_ms()
	if notification.id > 0 &&
	   (persist_now ||
	    notification.updated_at_ms - notification.last_persisted_at_ms >=
	    NOTIFICATION_PERSIST_INTERVAL_MS) {
		if !notification_database_update(notification) {
			notification_history.persistence_available = false
		}
	}
	notification_present(notification)
	return true
}

notification_finish :: proc(
	id: i64,
	kind: Notification_Kind,
	summary: string,
	detail := "",
	fields: []Notification_Field = nil,
	action_kind := Notification_Action_Kind.None,
	action_target := "",
) -> bool {
	notification := notification_find(id)
	if notification == nil {
		_ = notification_post(
			kind,
			summary,
			detail,
			fields,
			action_kind,
			action_target,
		)
		return true
	}
	notification.kind = kind
	notification.action_kind = action_kind
	next_target, target_error := strings.clone(action_target)
	if target_error != nil {return false}
	delete(notification.action_target)
	notification.action_target = next_target
	updated := notification_update(
		id,
		summary,
		detail,
		fields,
		persist_now = true,
	)
	if updated {notification_footer_finish_task(id)}
	return updated
}

notification_set_action :: proc(
	id: i64,
	kind: Notification_Action_Kind,
	target: string,
) -> bool {
	notification := notification_find(id)
	if notification == nil {return false}
	next_target, target_error := strings.clone(target)
	if target_error != nil {return false}
	delete(notification.action_target)
	notification.action_target = next_target
	notification.action_kind = kind
	notification.updated_at_ms = notification_now_ms()
	if notification.id > 0 && !notification_database_update(notification) {
		notification_history.persistence_available = false
	}
	notification_present(notification)
	return true
}

notification_post_info :: proc(text: string, persist := true) -> i64 {
	return notification_post(.Info, text, persist=persist)
}

notification_post_success :: proc(text: string, persist := true) -> i64 {
	return notification_post(.Success, text, persist=persist)
}

notification_post_error :: proc(text: string, persist := true) -> i64 {
	return notification_post(.Error, text, persist=persist)
}
