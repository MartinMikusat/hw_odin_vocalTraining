#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
MATCH_SORTER_ROOT="$ROOT/../hw_odin_matchSorter"
UI_FLASH_ROOT="$ROOT/../hw_odin_ui_flash"
COMMAND_PALETTE_ROOT="$ROOT/../hw_odin_ui_commandPalette"
COMPONENTS_ROOT="$ROOT/../hw_odin_ui_components"
FONT_ROOT="$ROOT/resources/fonts"
ICON_ROOT="$ROOT/resources/icons/iconoir"
if [ ! -f "$MATCH_SORTER_ROOT/match_sorter.odin" ]; then
  echo "[vocal-training] missing Odin match-sorter checkout: $MATCH_SORTER_ROOT" >&2
  exit 1
fi
if [ ! -f "$UI_FLASH_ROOT/flash.odin" ]; then
  echo "[vocal-training] missing Odin UI Flash checkout: $UI_FLASH_ROOT" >&2
  exit 1
fi
if [ ! -f "$COMMAND_PALETTE_ROOT/command_palette.odin" ]; then
  echo "[vocal-training] missing Odin UI command palette checkout: $COMMAND_PALETTE_ROOT" >&2
  exit 1
fi
if [ ! -f "$COMPONENTS_ROOT/text_input/text_input.odin" ]; then
  echo "[vocal-training] missing Odin UI components checkout: $COMPONENTS_ROOT" >&2
  exit 1
fi
if [ ! -f "$FONT_ROOT/Iosevka-Regular.ttf" ]; then
  echo "[vocal-training] missing bundled Iosevka font: $FONT_ROOT/Iosevka-Regular.ttf" >&2
  exit 1
fi
"$ROOT/scripts/dependencies.sh" check
cd "$ROOT"

MODE=${1:-debug}
case "$MODE" in
  debug)
    APP="$ROOT/build/VocalTraining.app"
    set -- -debug -o:none -keep-temp-files
    ;;
  trace)
    APP="$ROOT/build/trace/VocalTraining.app"
    set -- -debug -o:none -keep-temp-files -define:VT_TRACE_FOREIGN_LIFETIMES=true
    ;;
  asan)
    APP="$ROOT/build/asan/VocalTraining.app"
    set -- -debug -o:none -keep-temp-files -sanitize:address
    ;;
  release)
    APP="$ROOT/build/release/VocalTraining.app"
    set -- -o:speed
    ;;
  *)
    echo "usage: ./build.sh [debug|trace|asan|release]" >&2
    exit 2
    ;;
esac

mkdir -p "$APP/Contents/MacOS"
EXECUTABLE="$APP/Contents/MacOS/VocalTraining"
TEMP="$ROOT/build/temp/$MODE"
mkdir -p "$TEMP"
PITCH_CAPTURE_OBJECT="$TEMP/pitch_capture.o"
xcrun clang \
  -fobjc-arc \
  -fblocks \
  -mmacosx-version-min=13.0 \
  -c "$ROOT/src/pitch_capture.m" \
  -o "$PITCH_CAPTURE_OBJECT"
cd "$TEMP"
odin build "$ROOT/src" -out:"$EXECUTABLE" "$@" \
  -collection:match_sorter="$MATCH_SORTER_ROOT" \
  -collection:flash="$UI_FLASH_ROOT" \
  -collection:command_palette="$COMMAND_PALETTE_ROOT" \
  -collection:components="$COMPONENTS_ROOT" \
  -extra-linker-flags:"$PITCH_CAPTURE_OBJECT -framework AppKit -framework Foundation -framework AVFoundation -framework AVFAudio -framework CoreMedia -framework Metal -framework QuartzCore -framework CoreVideo -framework CoreText -framework CoreGraphics"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
mkdir -p "$APP/Contents/Resources/Fonts"
cp "$FONT_ROOT/Iosevka-Regular.ttf" "$APP/Contents/Resources/Fonts/Iosevka-Regular.ttf"
cp "$FONT_ROOT/IOSEVKA-LICENSE.md" "$APP/Contents/Resources/Fonts/IOSEVKA-LICENSE.md"
mkdir -p "$APP/Contents/Resources/Icons/Iconoir"
cp "$ICON_ROOT/xmark.svg" "$APP/Contents/Resources/Icons/Iconoir/xmark.svg"
cp "$ICON_ROOT/minus.svg" "$APP/Contents/Resources/Icons/Iconoir/minus.svg"
cp "$ICON_ROOT/maximize.svg" "$APP/Contents/Resources/Icons/Iconoir/maximize.svg"
cp "$ICON_ROOT/LICENSE" "$APP/Contents/Resources/Icons/Iconoir/LICENSE"
CLI_EXECUTABLE="$ROOT/build/vocal-training"
CLI_STAGING="$ROOT/build/.vocal-training-$MODE.tmp"
cp "$EXECUTABLE" "$CLI_STAGING"
mv -f "$CLI_STAGING" "$CLI_EXECUTABLE"

if [ "$MODE" != "release" ]; then
  xcrun dsymutil "$EXECUTABLE" -o "$APP.dSYM"
fi

printf '[vocal-training] built %s: %s\n' "$MODE" "${APP#"$ROOT/"}"
