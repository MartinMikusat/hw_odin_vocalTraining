#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$ROOT/scripts/ui-test-common.sh"
ui_test_require_jq
STATE_ROOT=${1:?state root is required}
APP_EXECUTABLE=${2:?app executable is required}
CLI_EXECUTABLE=${3:?CLI executable is required}
SUPPORT="$STATE_ROOT/app-support"
HELPER="$STATE_ROOT/ui_bridge"
SOURCE="$ROOT/scripts/ui_bridge.m"

if [ ! -x "$HELPER" ] || [ "$SOURCE" -nt "$HELPER" ]; then
  xcrun clang \
    -fobjc-arc \
    -mmacosx-version-min=13.0 \
    "$SOURCE" \
    -framework ApplicationServices \
    -framework Foundation \
    -o "$HELPER"
fi

"$ROOT/scripts/ui-test.sh" reset >/dev/null
pid=$(sed -n '1p' "$STATE_ROOT/app.pid")

run_cli() {
  HW_VIDEO_CLIPS_APP_SUPPORT_DIR="$SUPPORT" "$CLI_EXECUTABLE" "$@"
}

snapshot_state() {
  run_cli ui snapshot | jq -r '.data.state'
}

wait_fullscreen() {
  expected=$1
  attempts=0
  while [ "$attempts" -lt 50 ]; do
    state=$(snapshot_state)
    active=0
    case "$state" in
      *.fullscreen.*) active=1 ;;
    esac
    if [ "$active" -eq "$expected" ]; then
      return 0
    fi
    sleep 0.02
    attempts=$((attempts + 1))
  done
  printf '[hw_videoClips] fullscreen state did not become %s\n' "$expected" >&2
  return 1
}

key() {
  key_code=$1
  key_text=${2:-}
  key_modifiers=${3:-}
  set -- ui bridge-key --key-code "$key_code"
  if [ -n "$key_text" ]; then
    set -- "$@" --text "$key_text"
  fi
  if [ -n "$key_modifiers" ]; then
    set -- "$@" --modifiers "$key_modifiers"
  fi
  run_cli "$@" >/dev/null
}

run_cli ui run --file "$ROOT/tests/ui/bridge-prepare.json" >/dev/null

printf 'pointer... '
run_cli ui bridge-pointer --control "player full screen toggle" >/dev/null
wait_fullscreen 1
printf 'ok\nkeyboard... '
key 3 f
wait_fullscreen 0
printf 'ok\nnumbered... '

key 19 2
key 23 5
wait_fullscreen 1
printf 'ok\ncli... '
run_cli playback fullscreen --state off >/dev/null
wait_fullscreen 0
printf 'ok\naccessibility... '

accessibility_result=ok
if [ "${HW_VIDEO_CLIPS_UI_TEST_HIDDEN:-0}" -eq 1 ]; then
  accessibility_result=skipped-hidden
  printf 'skipped (hidden window)\n'
else
  "$HELPER" ax-press "$pid" "Enter full screen playback"
  wait_fullscreen 1
  printf 'ok\n'
  run_cli playback fullscreen --state off >/dev/null
  wait_fullscreen 0
fi

printf 'flash... '
key 44 /
key 3 f
key 32 u
key 36
wait_fullscreen 1
printf 'ok\n'
run_cli playback fullscreen --state off >/dev/null
wait_fullscreen 0

printf 'command_menu... '
key 40 k control
run_cli ui bridge-key --text "Enter full screen playback" >/dev/null
key 36
wait_fullscreen 1
printf 'ok\n'
run_cli playback fullscreen --state off >/dev/null
wait_fullscreen 0

printf 'pointer=ok keyboard=ok numbered=ok accessibility=%s flash=ok command_menu=ok cli=ok\n' \
  "$accessibility_result"
