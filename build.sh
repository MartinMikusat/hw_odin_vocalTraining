#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
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
cd "$TEMP"
odin build "$ROOT/src" -out:"$EXECUTABLE" "$@" \
  -extra-linker-flags:"-framework AppKit -framework Foundation -framework AVFoundation -framework AVFAudio -framework CoreMedia -framework Metal -framework QuartzCore -framework CoreVideo -framework CoreText -framework CoreGraphics"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"

if [ "$MODE" != "release" ]; then
  xcrun dsymutil "$EXECUTABLE" -o "$APP.dSYM"
fi

printf '[vocal-training] built %s: %s\n' "$MODE" "${APP#"$ROOT/"}"
