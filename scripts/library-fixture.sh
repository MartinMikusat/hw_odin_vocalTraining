#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
CANONICAL="$ROOT/testdata/library.sqlite3"
DUMP="$ROOT/testdata/library.sql"
DEV_SUPPORT=${HW_VIDEO_CLIPS_APP_SUPPORT_DIR:-"$ROOT/build/dev-support"}
DEV_DATABASE="$DEV_SUPPORT/library.sqlite3"

validate_database() {
  database=$1
  [ -f "$database" ] || {
    echo "[hw_videoClips] database does not exist: $database" >&2
    return 1
  }
  [ "$(sqlite3 "$database" "PRAGMA integrity_check")" = "ok" ] || {
    echo "[hw_videoClips] database integrity check failed: $database" >&2
    return 1
  }
  [ -z "$(sqlite3 "$database" "PRAGMA foreign_key_check")" ] || {
    echo "[hw_videoClips] database foreign-key check failed: $database" >&2
    return 1
  }
  schema_version=$(sqlite3 "$database" "PRAGMA user_version")
  [ "$schema_version" = "2" ] ||
    [ "$schema_version" = "6" ] ||
    [ "$schema_version" = "7" ] || {
    echo "[hw_videoClips] unsupported database schema: $database" >&2
    return 1
  }
}

write_dump() {
  temporary_dump=$(mktemp "$ROOT/testdata/library.sql.XXXXXX")
  sqlite3 "$CANONICAL" .dump > "$temporary_dump"
  printf 'PRAGMA user_version = %s;\n' "$(sqlite3 "$CANONICAL" "PRAGMA user_version")" >> "$temporary_dump"
  mv "$temporary_dump" "$DUMP"
}

initialize_database() {
  mkdir -p "$DEV_SUPPORT"
  if [ ! -f "$DEV_DATABASE" ]; then
    sqlite3 "$CANONICAL" ".backup '$DEV_DATABASE'"
    printf '[hw_videoClips] initialized development library: %s\n' "$DEV_DATABASE"
  fi
}

case "${1:-}" in
  init)
    validate_database "$CANONICAL"
    initialize_database
    ;;
  reset)
    validate_database "$CANONICAL"
    mkdir -p "$DEV_SUPPORT"
    sqlite3 "$CANONICAL" ".backup '$DEV_DATABASE'"
    printf '[hw_videoClips] reset development library: %s\n' "$DEV_DATABASE"
    ;;
  validate)
    validate_database "${2:-$DEV_DATABASE}"
    ;;
  promote)
    validate_database "$DEV_DATABASE"
    temporary_database=$(mktemp "$ROOT/testdata/library.sqlite3.XXXXXX")
    trap 'rm -f "$temporary_database"' EXIT
    sqlite3 "$DEV_DATABASE" ".backup '$temporary_database'"
    validate_database "$temporary_database"
    mv "$temporary_database" "$CANONICAL"
    trap - EXIT
    write_dump
    printf '[hw_videoClips] promoted development library: %s\n' "$CANONICAL"
    ;;
  dump)
    validate_database "$CANONICAL"
    write_dump
    ;;
  *)
    echo "usage: scripts/library-fixture.sh [init|reset|validate [path]|promote|dump]" >&2
    exit 2
    ;;
esac
