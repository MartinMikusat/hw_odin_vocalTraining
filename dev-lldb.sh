#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$ROOT"

./build.sh debug
APP="$ROOT/build/VocalTraining.app"
EXECUTABLE="$APP/Contents/MacOS/VocalTraining"
TIMESTAMP=$(date '+%Y%m%d-%H%M%S')
SESSION="$ROOT/build/lldb-sessions/$TIMESTAMP"
mkdir -p "$SESSION"
cp "$EXECUTABLE" "$SESSION/VocalTraining"
cp -R "$APP.dSYM" "$SESSION/VocalTraining.app.dSYM"
{
  printf 'git_revision=%s\n' "$(git rev-parse HEAD 2>/dev/null || echo unknown)"
  xcrun dwarfdump --uuid "$EXECUTABLE"
} > "$SESSION/metadata.txt"

script -q -F "$SESSION/lldb.log" env MTL_DEBUG_LAYER=1 lldb --batch \
  -o run \
  -k 'thread backtrace all' \
  -k 'register read' \
  -k 'frame select 1' \
  -k 'disassemble --frame --bytes' \
  -- "$EXECUTABLE" "$@"

printf '[vocal-training] LLDB session artifacts: %s\n' "$SESSION"
