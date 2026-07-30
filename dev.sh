#!/bin/sh
set -u

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$ROOT"

MODE=${1:-debug}
case "$MODE" in
  debug) APP="$ROOT/build/hw_videoClips.app" ;;
  trace|asan) APP="$ROOT/build/$MODE/hw_videoClips.app" ;;
  release)
    "$ROOT/build.sh" release
    exec "$ROOT/build/release/hw_videoClips.app/Contents/MacOS/hw_videoClips"
    ;;
  *)
    echo "usage: ./dev.sh [debug|trace|asan|release]" >&2
    exit 2
    ;;
esac

EXECUTABLE="$APP/Contents/MacOS/hw_videoClips"
LOCK="$ROOT/build/dev-watcher.lock"
APP_PID=""
STOPPING_APP=0
MEMORY_PROFILE=${HW_VIDEO_CLIPS_MEMORY_PROFILE:-none}
MEMORY_WARN_KB=${HW_VIDEO_CLIPS_MEMORY_WARN_KB:-1048576}
MEMORY_CHECK_TICK=0
MEMORY_OVER_LIMIT_COUNT=0
MEMORY_CAPTURED_PID=""
HW_VIDEO_CLIPS_APP_SUPPORT_DIR=${HW_VIDEO_CLIPS_APP_SUPPORT_DIR:-"$ROOT/build/dev-support"}
export HW_VIDEO_CLIPS_APP_SUPPORT_DIR

case "$MEMORY_WARN_KB" in
  ''|*[!0-9]*|0)
    echo "HW_VIDEO_CLIPS_MEMORY_WARN_KB must be a positive integer" >&2
    exit 2
    ;;
esac

fingerprint() {
  {
    stat -f '%m:%z:%N' \
      "$ROOT"/src/*.odin \
      "$ROOT"/src/*.m \
      "$ROOT"/*.sh \
      "$ROOT"/scripts/*.sh \
      "$ROOT"/dependencies.lock \
      "$ROOT"/Info.plist \
      "$ROOT"/resources/fonts/* \
      "$ROOT"/resources/icons/iconoir/* \
      2>/dev/null
  } | shasum | cut -d' ' -f1
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

cleanup() {
  exit_status=$?
  trap - INT TERM EXIT
  stop_app
  rm -f "$LOCK/pid"
  rmdir "$LOCK" 2>/dev/null || true
  exit "$exit_status"
}

archive_crash() {
  exit_status=$1
  "$ROOT/scripts/archive-crash.sh" "$MODE" "$APP" "$exit_status" || true
}

check_app() {
  if [ -z "$APP_PID" ] || kill -0 "$APP_PID" 2>/dev/null; then
    return
  fi
  if wait "$APP_PID"; then
    exit_status=0
  else
    exit_status=$?
  fi
  exited_pid=$APP_PID
  APP_PID=""
  if [ "$STOPPING_APP" -eq 0 ] && [ "$exit_status" -ne 0 ]; then
    printf '[hw_videoClips] app pid %s exited with status %s\n' \
      "$exited_pid" "$exit_status"
    archive_crash "$exit_status"
  fi
}

check_memory() {
  if [ -z "$APP_PID" ] || ! kill -0 "$APP_PID" 2>/dev/null; then
    return
  fi
  MEMORY_CHECK_TICK=$((MEMORY_CHECK_TICK + 1))
  if [ "$MEMORY_CHECK_TICK" -lt 20 ]; then
    return
  fi
  MEMORY_CHECK_TICK=0
  rss_kb=$(ps -o rss= -p "$APP_PID" 2>/dev/null | tr -d ' ') || return
  case "$rss_kb" in
    ''|*[!0-9]*) return ;;
  esac
  if [ "$rss_kb" -lt "$MEMORY_WARN_KB" ]; then
    MEMORY_OVER_LIMIT_COUNT=0
    return
  fi
  MEMORY_OVER_LIMIT_COUNT=$((MEMORY_OVER_LIMIT_COUNT + 1))
  if [ "$MEMORY_OVER_LIMIT_COUNT" -lt 2 ] ||
     [ "$MEMORY_CAPTURED_PID" = "$APP_PID" ]; then
    return
  fi
  MEMORY_CAPTURED_PID=$APP_PID
  printf '[hw_videoClips] pid %s exceeded %s KB RSS twice; capturing memory diagnostics\n' \
    "$APP_PID" "$MEMORY_WARN_KB"
  "$ROOT/scripts/capture-memory.sh" "$MODE" "$APP_PID" "$APP" "$rss_kb" &
}

launch_app() {
  HW_VIDEO_CLIPS_ACTIVATE_ON_LAUNCH=0
  export HW_VIDEO_CLIPS_ACTIVATE_ON_LAUNCH
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
      env MTL_DEBUG_LAYER=1 \
        DYLD_INSERT_LIBRARIES=/usr/lib/libgmalloc.dylib \
        "$EXECUTABLE" &
      ;;
    *)
      echo "unknown HW_VIDEO_CLIPS_MEMORY_PROFILE: $MEMORY_PROFILE" >&2
      return 2
      ;;
  esac
  APP_PID=$!
  MEMORY_CHECK_TICK=0
  MEMORY_OVER_LIMIT_COUNT=0
  MEMORY_CAPTURED_PID=""
}

rebuild_and_launch() {
  printf '\n[hw_videoClips] rebuilding %s...\n' "$MODE"
  if ! "$ROOT/build.sh" "$MODE"; then
    printf '[hw_videoClips] build failed; keeping the current app running\n'
    return
  fi
  stop_app
  if launch_app; then
    printf '[hw_videoClips] relaunched pid %s (%s, memory profile: %s)\n' \
      "$APP_PID" "$MODE" "$MEMORY_PROFILE"
  fi
}

mkdir -p "$ROOT/build"
if ! mkdir "$LOCK" 2>/dev/null; then
  existing=$(sed -n '1p' "$LOCK/pid" 2>/dev/null || true)
  if [ -n "$existing" ] && kill -0 "$existing" 2>/dev/null; then
    printf '[hw_videoClips] dev watcher already running as pid %s\n' "$existing"
    exit 0
  fi
  rm -f "$LOCK/pid"
  rmdir "$LOCK" 2>/dev/null || true
  mkdir "$LOCK"
fi
printf '%s\n' "$$" > "$LOCK/pid"
trap cleanup INT TERM EXIT

"$ROOT/scripts/library-fixture.sh" init
rebuild_and_launch
LAST_FINGERPRINT=$(fingerprint)

while :; do
  sleep 0.5
  check_app
  check_memory
  CURRENT_FINGERPRINT=$(fingerprint)
  if [ "$CURRENT_FINGERPRINT" != "$LAST_FINGERPRINT" ]; then
    LAST_FINGERPRINT=$CURRENT_FINGERPRINT
    rebuild_and_launch
  fi
done
