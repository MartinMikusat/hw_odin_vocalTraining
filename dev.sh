#!/bin/sh
set -u

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$ROOT"

APP="$ROOT/build/VocalTraining.app"
EXECUTABLE="$APP/Contents/MacOS/VocalTraining"
APP_PID=""

fingerprint() {
  stat -f '%m:%z:%N' src/*.odin build.sh Info.plist 2>/dev/null | shasum | cut -d' ' -f1
}

stop_app() {
  if [ -n "$APP_PID" ] && kill -0 "$APP_PID" 2>/dev/null; then
    kill "$APP_PID" 2>/dev/null || true
    wait "$APP_PID" 2>/dev/null || true
  fi
  APP_PID=""
}

rebuild_and_launch() {
  printf '\n[vocal-training] rebuilding...\n'
  if ! ./build.sh; then
    printf '[vocal-training] build failed; keeping the current app running\n'
    return
  fi

  stop_app
  "$EXECUTABLE" &
  APP_PID=$!
  printf '[vocal-training] relaunched pid %s\n' "$APP_PID"
}

trap 'stop_app; exit 0' INT TERM EXIT

rebuild_and_launch
LAST_FINGERPRINT=$(fingerprint)

while :; do
  sleep 0.5
  CURRENT_FINGERPRINT=$(fingerprint)
  if [ "$CURRENT_FINGERPRINT" != "$LAST_FINGERPRINT" ]; then
    LAST_FINGERPRINT=$CURRENT_FINGERPRINT
    rebuild_and_launch
  fi
done
