#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
LOCK_FILE=${VT_DEPENDENCY_LOCK:-"$ROOT/dependencies.lock"}

repository_path() {
  printf '%s/../%s\n' "$ROOT" "$1"
}

check_dependencies() {
  if [ ! -f "$LOCK_FILE" ]; then
    echo "[vocal-training] missing dependency lock: $LOCK_FILE" >&2
    return 1
  fi

  seen_match_sorter=0
  seen_ui_flash=0
  seen_command_palette=0
  while read -r name expected_url expected_revision extra; do
    case "$name" in
      ""|\#*) continue ;;
    esac
    if [ -n "${extra:-}" ] || [ -z "${expected_url:-}" ] || [ -z "${expected_revision:-}" ]; then
      echo "[vocal-training] invalid dependency lock entry: $name" >&2
      return 1
    fi
    case "$name" in
      hw_odin_matchSorter)
        [ "$seen_match_sorter" -eq 0 ] || {
          echo "[vocal-training] duplicate dependency lock entry: $name" >&2
          return 1
        }
        seen_match_sorter=1
        ;;
      hw_odin_ui_flash)
        [ "$seen_ui_flash" -eq 0 ] || {
          echo "[vocal-training] duplicate dependency lock entry: $name" >&2
          return 1
        }
        seen_ui_flash=1
        ;;
      hw_odin_ui_commandPalette)
        [ "$seen_command_palette" -eq 0 ] || {
          echo "[vocal-training] duplicate dependency lock entry: $name" >&2
          return 1
        }
        seen_command_palette=1
        ;;
      *)
        echo "[vocal-training] unknown dependency lock entry: $name" >&2
        return 1
        ;;
    esac

    repository=$(repository_path "$name")
    if ! git -C "$repository" rev-parse --git-dir >/dev/null 2>&1; then
      echo "[vocal-training] missing dependency checkout: $repository" >&2
      return 1
    fi

    actual_url=$(git -C "$repository" remote get-url origin 2>/dev/null || true)
    if [ "$actual_url" != "$expected_url" ]; then
      echo "[vocal-training] dependency origin mismatch: $name" >&2
      echo "  expected: $expected_url" >&2
      echo "  actual:   ${actual_url:-<missing>}" >&2
      return 1
    fi

    actual_revision=$(git -C "$repository" rev-parse HEAD)
    if [ "$actual_revision" != "$expected_revision" ]; then
      echo "[vocal-training] dependency revision mismatch: $name" >&2
      echo "  expected: $expected_revision" >&2
      echo "  actual:   $actual_revision" >&2
      echo "  update the checkout or run './scripts/dependencies.sh update' after validation" >&2
      return 1
    fi

    if [ -n "$(git -C "$repository" status --porcelain)" ]; then
      echo "[vocal-training] dependency checkout has uncommitted changes: $name" >&2
      return 1
    fi
  done < "$LOCK_FILE"

  if [ "$seen_match_sorter" -ne 1 ] ||
     [ "$seen_ui_flash" -ne 1 ] ||
     [ "$seen_command_palette" -ne 1 ]; then
    echo "[vocal-training] dependency lock does not contain all required repositories" >&2
    return 1
  fi
}

update_dependencies() {
  temporary=$(mktemp "${TMPDIR:-/tmp}/vocal-training-dependencies.XXXXXX")
  trap 'rm -f "$temporary"' EXIT HUP INT TERM
  printf '# Sibling repository, origin URL, and tested commit.\n' > "$temporary"
  for name in hw_odin_matchSorter hw_odin_ui_flash hw_odin_ui_commandPalette; do
    repository=$(repository_path "$name")
    if ! git -C "$repository" rev-parse --git-dir >/dev/null 2>&1; then
      echo "[vocal-training] missing dependency checkout: $repository" >&2
      return 1
    fi
    url=$(git -C "$repository" remote get-url origin)
    revision=$(git -C "$repository" rev-parse HEAD)
    printf '%s %s %s\n' "$name" "$url" "$revision" >> "$temporary"
  done
  mv "$temporary" "$LOCK_FILE"
  trap - EXIT HUP INT TERM
  echo "[vocal-training] updated dependencies.lock"
}

case "${1:-check}" in
  check) check_dependencies ;;
  update) update_dependencies ;;
  *)
    echo "usage: ./scripts/dependencies.sh [check|update]" >&2
    exit 2
    ;;
esac
