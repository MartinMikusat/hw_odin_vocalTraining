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
MODULE="$ROOT/build/hot-reload/$MODE/vocal-training.dylib"
APP_PID=""
STOPPING_APP=0
MEMORY_PROFILE=${VT_MEMORY_PROFILE:-none}
MEMORY_WARN_KB=${VT_MEMORY_WARN_KB:-1048576}
MEMORY_CHECK_TICK=0
MEMORY_OVER_LIMIT_COUNT=0
MEMORY_CAPTURED_PID=""
VT_APP_SUPPORT_DIR=${VT_APP_SUPPORT_DIR:-"$ROOT/build/dev-support"}
export VT_APP_SUPPORT_DIR

case "$MEMORY_WARN_KB" in
  ''|*[!0-9]*|0)
    echo "VT_MEMORY_WARN_KB must be a positive integer" >&2
    exit 2
    ;;
esac

"$ROOT/scripts/library-fixture.sh" init

legacy_fingerprint() {
  stat -f '%m:%z:%N' src/*.odin ./*.sh scripts/*.sh Info.plist resources/fonts/* resources/icons/iconoir/* 2>/dev/null | shasum | cut -d' ' -f1
}

module_fingerprint() {
  stat -f '%m:%z:%N' src/*.odin dependencies.lock 2>/dev/null |
    shasum | cut -d' ' -f1
}

host_fingerprint() {
  find dev -type f -name '*.odin' -exec stat -f '%m:%z:%N' {} + 2>/dev/null
  stat -f '%m:%z:%N' \
    Info.plist scripts/hot-reload-build.sh \
    resources/fonts/* resources/icons/iconoir/* \
    2>/dev/null
}

hot_reload_fingerprint() {
  host_fingerprint | shasum | cut -d' ' -f1
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
    if [ "$status" -eq 75 ] && { [ "$MODE" = "debug" ] || [ "$MODE" = "asan" ]; }; then
      launch_app
    else
      archive_crash "$status"
    fi
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
  printf '[vocal-training] pid %s exceeded %s KB RSS twice; capturing memory diagnostics\n' \
    "$APP_PID" "$MEMORY_WARN_KB"
  "$ROOT/scripts/capture-memory.sh" "$MODE" "$APP_PID" "$APP" "$rss_kb" &
}

launch_app() {
  VT_ACTIVATE_ON_LAUNCH=0
  export VT_ACTIVATE_ON_LAUNCH
  if [ "$MODE" = "debug" ] || [ "$MODE" = "asan" ]; then
    export VT_HOT_RELOAD_MODULE="$MODULE"
  else
    unset VT_HOT_RELOAD_MODULE
  fi
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
  MEMORY_CHECK_TICK=0
  MEMORY_OVER_LIMIT_COUNT=0
  MEMORY_CAPTURED_PID=""
}

legacy_rebuild_and_launch() {
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

hot_rebuild_and_launch() {
  printf '\n[vocal-training] rebuilding hot-reload %s host and module...\n' "$MODE"
  if ! "$ROOT/scripts/hot-reload-build.sh" "$MODE" all; then
    printf '[vocal-training] build failed; keeping the current app running\n'
    return
  fi

  stop_app
  if launch_app; then
    printf '[vocal-training] relaunched pid %s (%s, memory profile: %s)\n' "$APP_PID" "$MODE" "$MEMORY_PROFILE"
  fi
}

hot_rebuild_module() {
  printf '\n[vocal-training] rebuilding hot-reload %s module...\n' "$MODE"
  if ! "$ROOT/scripts/hot-reload-build.sh" "$MODE" module; then
    printf '[vocal-training] module build failed; the current module remains active\n'
  fi
}

trap 'stop_app; exit 0' INT TERM EXIT

if [ "$MODE" = "debug" ] || [ "$MODE" = "asan" ]; then
  hot_rebuild_and_launch
  LAST_MODULE_FINGERPRINT=$(module_fingerprint)
  LAST_HOST_FINGERPRINT=$(hot_reload_fingerprint)
else
  legacy_rebuild_and_launch
  LAST_FINGERPRINT=$(legacy_fingerprint)
fi

while :; do
  sleep 0.5
  check_app
  check_memory
  if [ "$MODE" != "debug" ] && [ "$MODE" != "asan" ]; then
    CURRENT_FINGERPRINT=$(legacy_fingerprint)
    if [ "$CURRENT_FINGERPRINT" != "$LAST_FINGERPRINT" ]; then
      LAST_FINGERPRINT=$CURRENT_FINGERPRINT
      legacy_rebuild_and_launch
    fi
    continue
  fi

  CURRENT_HOST_FINGERPRINT=$(hot_reload_fingerprint)
  CURRENT_MODULE_FINGERPRINT=$(module_fingerprint)
  if [ "$CURRENT_HOST_FINGERPRINT" != "$LAST_HOST_FINGERPRINT" ]; then
    LAST_HOST_FINGERPRINT=$CURRENT_HOST_FINGERPRINT
    LAST_MODULE_FINGERPRINT=$CURRENT_MODULE_FINGERPRINT
    hot_rebuild_and_launch
  elif [ "$CURRENT_MODULE_FINGERPRINT" != "$LAST_MODULE_FINGERPRINT" ]; then
    LAST_MODULE_FINGERPRINT=$CURRENT_MODULE_FINGERPRINT
    hot_rebuild_module
  fi
done
