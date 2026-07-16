#!/bin/sh
set -u

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$ROOT"

MODE=${1:-debug}
case "$MODE" in
  debug) APP="$ROOT/build/VocalTraining.app" ;;
  trace|asan|release) APP="$ROOT/build/$MODE/VocalTraining.app" ;;
  *)
    echo "usage: ./dev.sh [debug|trace|asan|release]" >&2
    exit 2
    ;;
esac
EXECUTABLE="$APP/Contents/MacOS/VocalTraining"
APP_PID=""
STOPPING_APP=0
MEMORY_PROFILE=${VT_MEMORY_PROFILE:-none}

fingerprint() {
  stat -f '%m:%z:%N' src/*.odin ./*.sh scripts/*.sh Info.plist 2>/dev/null | shasum | cut -d' ' -f1
}

stop_app() {
  if [ -n "$APP_PID" ] && kill -0 "$APP_PID" 2>/dev/null; then
    STOPPING_APP=1
    kill "$APP_PID" 2>/dev/null || true
    wait "$APP_PID" 2>/dev/null || true
    STOPPING_APP=0
  fi
  APP_PID=""
}

archive_crash() {
  status=$1
  "$ROOT/scripts/archive-crash.sh" "$MODE" "$APP" "$status" || true
}

check_app() {
  if [ -z "$APP_PID" ] || kill -0 "$APP_PID" 2>/dev/null; then
    return
  fi
  if wait "$APP_PID"; then
    status=0
  else
    status=$?
  fi
  crashed_pid=$APP_PID
  APP_PID=""
  if [ "$STOPPING_APP" -eq 0 ] && [ "$status" -ne 0 ]; then
    printf '[vocal-training] app pid %s exited with status %s\n' "$crashed_pid" "$status"
    archive_crash "$status"
  fi
}

launch_app() {
  case "$MEMORY_PROFILE" in
    none)
      env MTL_DEBUG_LAYER=1 "$EXECUTABLE" &
      ;;
    scribble)
      env MTL_DEBUG_LAYER=1 MallocScribble=1 MallocStackLogging=1 "$EXECUTABLE" &
      ;;
    guard-edges)
      env MTL_DEBUG_LAYER=1 MallocGuardEdges=1 MallocScribble=1 "$EXECUTABLE" &
      ;;
    zombies)
      env MTL_DEBUG_LAYER=1 NSZombieEnabled=YES MallocStackLogging=1 "$EXECUTABLE" &
      ;;
    guard-malloc)
      env MTL_DEBUG_LAYER=1 DYLD_INSERT_LIBRARIES=/usr/lib/libgmalloc.dylib "$EXECUTABLE" &
      ;;
    *)
      echo "unknown VT_MEMORY_PROFILE: $MEMORY_PROFILE" >&2
      return 2
      ;;
  esac
  APP_PID=$!
}

rebuild_and_launch() {
  printf '\n[vocal-training] rebuilding %s...\n' "$MODE"
  if ! ./build.sh "$MODE"; then
    printf '[vocal-training] build failed; keeping the current app running\n'
    return
  fi

  stop_app
  if launch_app; then
    printf '[vocal-training] relaunched pid %s (%s, memory profile: %s)\n' "$APP_PID" "$MODE" "$MEMORY_PROFILE"
  fi
}

trap 'stop_app; exit 0' INT TERM EXIT

rebuild_and_launch
LAST_FINGERPRINT=$(fingerprint)

while :; do
  sleep 0.5
  check_app
  CURRENT_FINGERPRINT=$(fingerprint)
  if [ "$CURRENT_FINGERPRINT" != "$LAST_FINGERPRINT" ]; then
    LAST_FINGERPRINT=$CURRENT_FINGERPRINT
    rebuild_and_launch
  fi
done
