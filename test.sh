#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
TEST_SUPPORT=$(mktemp -d "${TMPDIR:-/tmp}/vocal-training-tests.XXXXXX")
trap 'rm -rf "$TEST_SUPPORT"' EXIT

"$ROOT/scripts/library-fixture.sh" validate "$ROOT/testdata/library.sqlite3"
sqlite3 "$ROOT/testdata/library.sqlite3" ".backup '$TEST_SUPPORT/library.sqlite3'"

VT_APP_SUPPORT_DIR="$TEST_SUPPORT" \
VT_TEST_LIBRARY="$TEST_SUPPORT/library.sqlite3" \
VT_HEADLESS_TEST=1 \
odin test "$ROOT/src" \
  -define:ODIN_TEST_THREADS=1 \
  -collection:match_sorter="$ROOT/../hw_odin_matchSorter" \
  -collection:flash="$ROOT/../hw_odin_ui_flash" \
  -collection:command_palette="$ROOT/../hw_odin_ui_commandPalette" \
  -extra-linker-flags:"-framework AppKit -framework Foundation -framework AVFoundation -framework AVFAudio -framework CoreMedia -framework Metal -framework QuartzCore -framework CoreVideo -framework CoreText -framework CoreGraphics"
