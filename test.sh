#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
TEST_SUPPORT=$(mktemp -d "${TMPDIR:-/tmp}/hw_videoClips-tests.XXXXXX")
trap 'rm -rf "$TEST_SUPPORT"' EXIT

"$ROOT/scripts/library-fixture.sh" validate "$ROOT/testdata/library.sqlite3"
sqlite3 "$ROOT/testdata/library.sqlite3" ".backup '$TEST_SUPPORT/library.sqlite3'"
PITCH_CAPTURE_OBJECT="$TEST_SUPPORT/pitch_capture.o"
xcrun clang \
  -fobjc-arc \
  -fblocks \
  -mmacosx-version-min=13.0 \
  -c "$ROOT/src/pitch_capture.m" \
  -o "$PITCH_CAPTURE_OBJECT"

HW_VIDEO_CLIPS_APP_SUPPORT_DIR="$TEST_SUPPORT" \
HW_VIDEO_CLIPS_TEST_LIBRARY="$TEST_SUPPORT/library.sqlite3" \
HW_VIDEO_CLIPS_HEADLESS_TEST=1 \
odin test "$ROOT/src" \
  -define:ODIN_TEST_THREADS=1 \
  -define:HW_VIDEO_CLIPS_DEV_TASK_SIMULATION=true \
  -collection:match_sorter="$ROOT/../hw_odin_matchSorter" \
  -collection:flash="$ROOT/../hw_odin_ui_flash" \
  -collection:command_palette="$ROOT/../hw_odin_ui_commandPalette" \
  -collection:components="$ROOT/../hw_odin_ui_components" \
  -extra-linker-flags:"$PITCH_CAPTURE_OBJECT -framework AppKit -framework Foundation -framework AVFoundation -framework AVFAudio -framework AudioToolbox -framework CoreAudio -framework CoreMedia -framework Metal -framework QuartzCore -framework CoreVideo -framework CoreText -framework CoreGraphics"
