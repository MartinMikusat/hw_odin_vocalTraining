package main

import "core:c"
import "core:strings"

SQLite_DB :: struct {}
SQLite_Statement :: struct {}
SQLite_Backup :: struct {}

foreign import sqlite "system:sqlite3"
foreign sqlite {
	sqlite3_open_v2 :: proc "c" (filename: cstring, database: ^^SQLite_DB, flags: c.int, vfs: cstring) -> c.int ---
	sqlite3_close :: proc "c" (database: ^SQLite_DB) -> c.int ---
	sqlite3_errmsg :: proc "c" (database: ^SQLite_DB) -> cstring ---
	sqlite3_errcode :: proc "c" (database: ^SQLite_DB) -> c.int ---
	sqlite3_extended_errcode :: proc "c" (database: ^SQLite_DB) -> c.int ---
	sqlite3_exec :: proc "c" (database: ^SQLite_DB, sql: cstring, callback, ctx: rawptr, error_message: ^cstring) -> c.int ---
	sqlite3_free :: proc "c" (value: rawptr) ---
	sqlite3_prepare_v2 :: proc "c" (database: ^SQLite_DB, sql: cstring, bytes: c.int, statement: ^^SQLite_Statement, tail: ^cstring) -> c.int ---
	sqlite3_finalize :: proc "c" (statement: ^SQLite_Statement) -> c.int ---
	sqlite3_reset :: proc "c" (statement: ^SQLite_Statement) -> c.int ---
	sqlite3_step :: proc "c" (statement: ^SQLite_Statement) -> c.int ---
	sqlite3_bind_text :: proc "c" (statement: ^SQLite_Statement, index: c.int, value: cstring, bytes: c.int, destroy: rawptr) -> c.int ---
	sqlite3_bind_int :: proc "c" (statement: ^SQLite_Statement, index, value: c.int) -> c.int ---
	sqlite3_bind_int64 :: proc "c" (statement: ^SQLite_Statement, index: c.int, value: i64) -> c.int ---
	sqlite3_bind_double :: proc "c" (statement: ^SQLite_Statement, index: c.int, value: f64) -> c.int ---
	sqlite3_column_text :: proc "c" (statement: ^SQLite_Statement, index: c.int) -> cstring ---
	sqlite3_column_type :: proc "c" (statement: ^SQLite_Statement, index: c.int) -> c.int ---
	sqlite3_column_int :: proc "c" (statement: ^SQLite_Statement, index: c.int) -> c.int ---
	sqlite3_column_int64 :: proc "c" (statement: ^SQLite_Statement, index: c.int) -> i64 ---
	sqlite3_column_double :: proc "c" (statement: ^SQLite_Statement, index: c.int) -> f64 ---
	sqlite3_last_insert_rowid :: proc "c" (database: ^SQLite_DB) -> i64 ---
	sqlite3_total_changes :: proc "c" (database: ^SQLite_DB) -> c.int ---
	sqlite3_backup_init :: proc "c" (destination: ^SQLite_DB, destination_name: cstring, source: ^SQLite_DB, source_name: cstring) -> ^SQLite_Backup ---
	sqlite3_backup_step :: proc "c" (backup: ^SQLite_Backup, pages: c.int) -> c.int ---
	sqlite3_backup_finish :: proc "c" (backup: ^SQLite_Backup) -> c.int ---
}

SQLITE_OK :: 0
SQLITE_ROW :: 100
SQLITE_DONE :: 101
SQLITE_NULL :: 5
SQLITE_OPEN_READONLY :: 0x00000001
SQLITE_OPEN_READWRITE :: 0x00000002
SQLITE_OPEN_CREATE :: 0x00000004

sqlite_error :: proc(database: ^SQLite_DB) -> string {
	if database == nil {return "SQLite database is not open"}
	message := sqlite3_errmsg(database)
	if message == nil {return "Unknown SQLite error"}
	return string(message)
}

sqlite_execute :: proc(database: ^SQLite_DB, sql: string) -> bool {
	query := strings.clone_to_cstring(sql)
	defer delete(query)
	error_message: cstring
	result := sqlite3_exec(database, query, nil, nil, &error_message)
	if error_message != nil {sqlite3_free(rawptr(error_message))}
	return result == SQLITE_OK
}

sqlite_prepare :: proc(database: ^SQLite_DB, sql: string) -> (^SQLite_Statement, bool) {
	query := strings.clone_to_cstring(sql)
	defer delete(query)
	statement: ^SQLite_Statement
	prepared := sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK
	return statement, prepared
}

sqlite_bind_text_value :: proc(statement: ^SQLite_Statement, index: int, value: string) -> bool {
	text := strings.clone_to_cstring(value, context.temp_allocator)
	return sqlite3_bind_text(statement, c.int(index), text, c.int(len(value)), nil) == SQLITE_OK
}

sqlite_column_string :: proc(statement: ^SQLite_Statement, index: int, allocator := context.allocator) -> (string, bool) {
	value := sqlite3_column_text(statement, c.int(index))
	if value == nil {return "", true}
	copy, error := strings.clone(string(value), allocator)
	return copy, error == nil
}
