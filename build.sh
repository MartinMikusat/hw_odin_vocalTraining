#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
MATCH_SORTER_ROOT="$ROOT/../hw_odin_matchSorter"
UI_FLASH_ROOT="$ROOT/../hw_odin_ui_flash"
COMMAND_PALETTE_ROOT="$ROOT/../hw_odin_ui_commandPalette"
COMPONENTS_ROOT="$ROOT/../hw_odin_ui_components"
TASK_QUEUE_ROOT="$ROOT/../hw_odin_concurrency_taskQueue"
UI_FRAMEWORK_ROOT="$ROOT/../hw_odin_ui_framework"
ICON_ROOT="$ROOT/resources/icons/iconoir"
if [ ! -f "$MATCH_SORTER_ROOT/match_sorter.odin" ]; then
  echo "[hw_videoClips] missing Odin match-sorter checkout: $MATCH_SORTER_ROOT" >&2
  exit 1
fi
if [ ! -f "$UI_FLASH_ROOT/flash.odin" ]; then
  echo "[hw_videoClips] missing Odin UI Flash checkout: $UI_FLASH_ROOT" >&2
  exit 1
fi
if [ ! -f "$COMMAND_PALETTE_ROOT/command_palette.odin" ]; then
  echo "[hw_videoClips] missing Odin UI command palette checkout: $COMMAND_PALETTE_ROOT" >&2
  exit 1
fi
if [ ! -f "$COMPONENTS_ROOT/text_input/text_input.odin" ]; then
  echo "[hw_videoClips] missing Odin UI components checkout: $COMPONENTS_ROOT" >&2
  exit 1
fi
if [ ! -f "$TASK_QUEUE_ROOT/task_queue.odin" ]; then
  echo "[hw_videoClips] missing Odin task queue checkout: $TASK_QUEUE_ROOT" >&2
  exit 1
fi
if [ ! -f "$UI_FRAMEWORK_ROOT/core/core.odin" ]; then
  echo "[hw_videoClips] missing Odin UI framework checkout: $UI_FRAMEWORK_ROOT" >&2
  exit 1
fi
"$ROOT/scripts/dependencies.sh" check
cd "$ROOT"

MODE=${1:-debug}
case "$MODE" in
  debug)
    APP="$ROOT/build/hw_videoClips.app"
    set -- -debug -o:none -keep-temp-files
    ;;
  trace)
    APP="$ROOT/build/trace/hw_videoClips.app"
    set -- -debug -o:none -keep-temp-files -define:HW_VIDEO_CLIPS_TRACE_FOREIGN_LIFETIMES=true
    ;;
  asan)
    APP="$ROOT/build/asan/hw_videoClips.app"
    set -- -debug -o:none -keep-temp-files -sanitize:address
    ;;
  release)
    APP="$ROOT/build/release/hw_videoClips.app"
    set -- -o:speed
    ;;
  *)
    echo "usage: ./build.sh [debug|trace|asan|release]" >&2
    exit 2
    ;;
esac

rm -rf "$APP/Contents/Resources/Fonts"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"
if xcrun metal -help >/dev/null 2>&1; then
  "$UI_FRAMEWORK_ROOT/scripts/build-metallib.sh" "$APP/Contents/Resources/ui.metallib"
elif [ "$MODE" = "release" ]; then
  echo "[hw_videoClips] release builds require the optional Metal shader toolchain" >&2
  echo "[hw_videoClips] install it with: xcodebuild -downloadComponent MetalToolchain" >&2
  exit 1
else
  rm -f "$APP/Contents/Resources/ui.metallib"
fi
EXECUTABLE="$APP/Contents/MacOS/hw_videoClips"
TEMP="$ROOT/build/temp/$MODE"
mkdir -p "$TEMP"
PITCH_CAPTURE_OBJECT="$TEMP/pitch_capture.o"
BPM_ANALYSIS_OBJECT="$TEMP/bpm_analysis.o"
METRONOME_OBJECT="$TEMP/metronome.o"
PERFORMANCE_LINK=""
xcrun clang \
  -fobjc-arc \
  -fblocks \
  -mmacosx-version-min=13.0 \
  -c "$ROOT/src/pitch_capture.m" \
  -o "$PITCH_CAPTURE_OBJECT"
xcrun clang \
  -fobjc-arc \
  -fblocks \
  -mmacosx-version-min=13.0 \
  -Wall \
  -Wextra \
  -Werror \
  -Wpedantic \
  -Wconversion \
  -Wsign-conversion \
  -Wshorten-64-to-32 \
  -Wcast-align \
  -c "$ROOT/src/bpm_analysis.m" \
  -o "$BPM_ANALYSIS_OBJECT"
xcrun clang \
  -fobjc-arc \
  -fblocks \
  -mmacosx-version-min=13.0 \
  -Wall -Wextra -Werror -Wpedantic \
  -c "$ROOT/src/metronome.m" \
  -o "$METRONOME_OBJECT"
if [ "$MODE" != "release" ]; then
  PERFORMANCE_OBJECT="$TEMP/performance.o"
  xcrun clang \
    -fobjc-arc \
    -fblocks \
    -mmacosx-version-min=13.0 \
    -Wall -Wextra -Werror -Wpedantic \
    -c "$ROOT/src/performance.m" \
    -o "$PERFORMANCE_OBJECT"
  PERFORMANCE_LINK=" $PERFORMANCE_OBJECT"
fi
cd "$TEMP"
odin build "$ROOT/src" -out:"$EXECUTABLE" "$@" \
  -collection:match_sorter="$MATCH_SORTER_ROOT" \
  -collection:flash="$UI_FLASH_ROOT" \
  -collection:command_palette="$COMMAND_PALETTE_ROOT" \
  -collection:components="$COMPONENTS_ROOT" \
  -collection:task_queue="$TASK_QUEUE_ROOT" \
  -collection:ui_framework="$UI_FRAMEWORK_ROOT" \
  -extra-linker-flags:"$PITCH_CAPTURE_OBJECT $BPM_ANALYSIS_OBJECT $METRONOME_OBJECT$PERFORMANCE_LINK -framework AppKit -framework Foundation -framework AVFoundation -framework AVFAudio -framework AudioToolbox -framework CoreAudio -framework CoreMedia -framework Metal -framework QuartzCore -framework CoreVideo -framework CoreText -framework CoreGraphics -framework ImageIO -framework Accelerate"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
mkdir -p "$APP/Contents/Resources/Icons/Iconoir"
cp "$ICON_ROOT/xmark.svg" "$APP/Contents/Resources/Icons/Iconoir/xmark.svg"
cp "$ICON_ROOT/minus.svg" "$APP/Contents/Resources/Icons/Iconoir/minus.svg"
cp "$ICON_ROOT/maximize.svg" "$APP/Contents/Resources/Icons/Iconoir/maximize.svg"
cp "$ICON_ROOT/settings.svg" "$APP/Contents/Resources/Icons/Iconoir/settings.svg"
cp "$ICON_ROOT/expand.svg" "$APP/Contents/Resources/Icons/Iconoir/expand.svg"
cp "$ICON_ROOT/collapse.svg" "$APP/Contents/Resources/Icons/Iconoir/collapse.svg"
cp "$ICON_ROOT/LICENSE" "$APP/Contents/Resources/Icons/Iconoir/LICENSE"
CLI_EXECUTABLE="$ROOT/build/hw_videoClips"
CLI_STAGING="$ROOT/build/.hw_videoClips-$MODE.tmp"
cp "$EXECUTABLE" "$CLI_STAGING"
mv -f "$CLI_STAGING" "$CLI_EXECUTABLE"

if [ "$MODE" != "release" ]; then
  xcrun dsymutil "$EXECUTABLE" -o "$APP.dSYM"
fi

printf '[hw_videoClips] built %s: %s\n' "$MODE" "${APP#"$ROOT/"}"
