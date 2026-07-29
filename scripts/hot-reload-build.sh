#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
MATCH_SORTER_ROOT="$ROOT/../hw_odin_matchSorter"
UI_FLASH_ROOT="$ROOT/../hw_odin_ui_flash"
COMMAND_PALETTE_ROOT="$ROOT/../hw_odin_ui_commandPalette"
COMPONENTS_ROOT="$ROOT/../hw_odin_ui_components"
FONT_ROOT="$ROOT/resources/fonts"
ICON_ROOT="$ROOT/resources/icons/iconoir"

MODE=${1:-debug}
PART=${2:-all}
case "$MODE" in
  debug)
    APP="$ROOT/build/VocalTraining.app"
    SANITIZER_FLAGS=""
    ;;
  asan)
    APP="$ROOT/build/asan/VocalTraining.app"
    SANITIZER_FLAGS="-sanitize:address"
    ;;
  *)
    echo "usage: scripts/hot-reload-build.sh [debug|asan] [all|host|module]" >&2
    exit 2
    ;;
esac
case "$PART" in
  all|host|module) ;;
  *)
    echo "usage: scripts/hot-reload-build.sh [debug|asan] [all|host|module]" >&2
    exit 2
    ;;
esac

"$ROOT/scripts/dependencies.sh" check

HOT_DIR="$ROOT/build/hot-reload/$MODE"
MODULE="$HOT_DIR/vocal-training.dylib"
MODULE_NEXT="$HOT_DIR/vocal-training.next.dylib"
HOST="$APP/Contents/MacOS/VocalTraining"
CLI="$ROOT/build/vocal-training"
mkdir -p \
  "$HOT_DIR" \
  "$APP/Contents/MacOS" \
  "$APP/Contents/Resources/Fonts" \
  "$APP/Contents/Resources/Icons/Iconoir"

COMMON_COLLECTIONS="-collection:match_sorter=$MATCH_SORTER_ROOT -collection:flash=$UI_FLASH_ROOT -collection:command_palette=$COMMAND_PALETTE_ROOT -collection:components=$COMPONENTS_ROOT"
APP_FRAMEWORKS="-framework AppKit -framework Foundation -framework AVFoundation -framework AVFAudio -framework CoreMedia -framework Metal -framework QuartzCore -framework CoreVideo -framework CoreText -framework CoreGraphics"
HOST_FRAMEWORKS="-framework AppKit -framework Foundation"

build_host() {
  (
    cd "$HOT_DIR"
    # shellcheck disable=SC2086
    odin build "$ROOT/dev/hot_reload_host" \
      -debug -o:none -keep-temp-files $SANITIZER_FLAGS \
      -out:"$HOST" \
      -extra-linker-flags:"$HOST_FRAMEWORKS"
  )
  cp "$HOST" "$CLI"
  cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
  cp "$FONT_ROOT/Iosevka-Regular.ttf" "$APP/Contents/Resources/Fonts/Iosevka-Regular.ttf"
  cp "$FONT_ROOT/IOSEVKA-LICENSE.md" "$APP/Contents/Resources/Fonts/IOSEVKA-LICENSE.md"
  cp "$ICON_ROOT/xmark.svg" "$APP/Contents/Resources/Icons/Iconoir/xmark.svg"
  cp "$ICON_ROOT/minus.svg" "$APP/Contents/Resources/Icons/Iconoir/minus.svg"
  cp "$ICON_ROOT/maximize.svg" "$APP/Contents/Resources/Icons/Iconoir/maximize.svg"
  cp "$ICON_ROOT/LICENSE" "$APP/Contents/Resources/Icons/Iconoir/LICENSE"
  xcrun dsymutil "$HOST" -o "$APP.dSYM"
  codesign --force --deep --sign - "$APP"
}

build_module() {
  asan_runtime=""
  if [ "$MODE" = "asan" ]; then
    if [ ! -x "$HOST" ]; then
      echo "[vocal-training] build the ASan host before its module" >&2
      return 1
    fi
    asan_runtime=$(otool -L "$HOST" | awk '/libclang_rt\.asan_osx_dynamic\.dylib/ {print $1; exit}')
    if [ -z "$asan_runtime" ] || [ ! -f "$asan_runtime" ]; then
      echo "[vocal-training] could not resolve the host ASan runtime" >&2
      return 1
    fi
  fi
  module_link_flags="$APP_FRAMEWORKS"
  if [ -n "$asan_runtime" ]; then
    module_link_flags="$module_link_flags $asan_runtime"
  fi
  (
    cd "$HOT_DIR"
    # shellcheck disable=SC2086
    odin build "$ROOT/src" \
      -build-mode:dll \
      -define:HOT_RELOAD_MODULE=true \
      -debug -o:none -keep-temp-files $SANITIZER_FLAGS \
      -out:"$MODULE_NEXT" \
      $COMMON_COLLECTIONS \
      -extra-linker-flags:"$module_link_flags"
  )
  xcrun dsymutil "$MODULE_NEXT" -o "$MODULE_NEXT.dSYM"
  mv -f "$MODULE_NEXT" "$MODULE"
  rm -rf "$MODULE.dSYM"
  mv "$MODULE_NEXT.dSYM" "$MODULE.dSYM"
}

case "$PART" in
  all)
    build_host
    build_module
    ;;
  host)
    build_host
    ;;
  module)
    build_module
    ;;
esac

printf '[vocal-training] built hot-reload %s %s\n' "$MODE" "$PART"
