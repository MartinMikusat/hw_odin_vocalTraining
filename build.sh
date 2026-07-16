#!/bin/sh
set -eu

APP="build/VocalTraining.app"
mkdir -p "$APP/Contents/MacOS"
odin build src -out:"$APP/Contents/MacOS/VocalTraining" -o:speed \
  -extra-linker-flags:"-framework AppKit -framework Foundation -framework AVFoundation -framework CoreMedia -framework Metal -framework QuartzCore -framework CoreVideo -framework CoreText -framework CoreGraphics"
cp Info.plist "$APP/Contents/Info.plist"
