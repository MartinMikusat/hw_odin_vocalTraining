#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$ROOT"

HW_VIDEO_CLIPS_APP_SUPPORT_DIR=${HW_VIDEO_CLIPS_APP_SUPPORT_DIR:-"$ROOT/build/dev-support"}
export HW_VIDEO_CLIPS_APP_SUPPORT_DIR
"$ROOT/scripts/library-fixture.sh" init

./build.sh debug
APP="$ROOT/build/hw_videoClips.app"
EXECUTABLE="$APP/Contents/MacOS/hw_videoClips"
TIMESTAMP=$(date '+%Y%m%d-%H%M%S')
SESSION="$ROOT/build/lldb-sessions/$TIMESTAMP"
mkdir -p "$SESSION"
cp "$EXECUTABLE" "$SESSION/hw_videoClips"
cp -R "$APP.dSYM" "$SESSION/hw_videoClips.app.dSYM"
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

printf '[hw_videoClips] LLDB session artifacts: %s\n' "$SESSION"
