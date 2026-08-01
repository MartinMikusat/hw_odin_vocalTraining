#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
. "$ROOT/scripts/ui-test-common.sh"
STATE_ROOT="$ROOT/build/ui-test-support"
SUPPORT_ROOT=/tmp
CHECKOUT_ID=$(printf '%s' "$ROOT" | shasum -a 256 | cut -c1-12)
SUPPORT="${SUPPORT_ROOT%/}/hw-video-clips-ui-test-$(id -u)-$CHECKOUT_ID/app-support"
SUPPORT_LINK="$STATE_ROOT/app-support"
APP_EXECUTABLE="$ROOT/build/hw_videoClips.app/Contents/MacOS/hw_videoClips"
CLI_EXECUTABLE="$ROOT/build/hw_videoClips"
CANONICAL_DATABASE="$ROOT/testdata/library.sqlite3"
FIXTURE="$ROOT/testdata/ui/playback-fixture.mp4"
PID_FILE="$STATE_ROOT/app.pid"
BUILD_FINGERPRINT_FILE="$STATE_ROOT/build.fingerprint"
INSTANCE_FINGERPRINT_FILE="$STATE_ROOT/instance.fingerprint"
STARTUP_FILE="$STATE_ROOT/startup.ms"
SOCKET="$SUPPORT/control.sock"
LOG="$STATE_ROOT/app.stdout.log"
ERROR_LOG="$STATE_ROOT/app.stderr.log"
LAUNCH_LABEL="com.halwayland.hw-video-clips-ui-test.$CHECKOUT_ID"
LEGACY_LAUNCH_LABEL="com.halwayland.hw-video-clips-ui-test"
INSTANCE_STARTUP_MS=0
CURRENT_BUILD_FINGERPRINT=
CURRENT_INSTANCE_FINGERPRINT=

clock_ms() {
  /usr/bin/perl -MTime::HiRes=time -e \
    'printf "%.0f\n", time*1000'
}

prepare_support_location() {
  mkdir -p "$STATE_ROOT" "$SUPPORT"
  expected=$(readlink "$SUPPORT_LINK" 2>/dev/null || true)
  if [ "$expected" = "$SUPPORT" ]; then
    return
  fi
  if [ -e "$SUPPORT_LINK" ] || [ -L "$SUPPORT_LINK" ]; then
    rm -rf "$SUPPORT_LINK"
  fi
  ln -s "$SUPPORT" "$SUPPORT_LINK"
}

ensure_build() {
  "$ROOT/scripts/dependencies.sh" check
  input_fingerprint=$(
    {
      find "$ROOT/src" "$ROOT/resources" -type f -print
      printf '%s\n' \
        "$ROOT/Info.plist" \
        "$ROOT/build.sh" \
        "$ROOT/dependencies.lock" \
        "$ROOT/scripts/dependencies.sh"
    } |
      LC_ALL=C sort |
      while IFS= read -r input; do
        shasum -a 256 "$input"
      done |
      shasum -a 256 |
      awk '{print $1}'
  )
  stored_fingerprint=$(sed -n '1p' "$BUILD_FINGERPRINT_FILE" 2>/dev/null || true)
  rebuild=0
  if [ ! -x "$APP_EXECUTABLE" ] || [ ! -x "$CLI_EXECUTABLE" ]; then
    rebuild=1
  elif [ "$input_fingerprint" != "$stored_fingerprint" ]; then
    rebuild=1
  fi
  if [ "$rebuild" -eq 1 ]; then
    "$ROOT/build.sh" debug >&2
    mkdir -p "$STATE_ROOT"
    printf '%s\n' "$input_fingerprint" >"$BUILD_FINGERPRINT_FILE"
  fi
  CURRENT_BUILD_FINGERPRINT=$input_fingerprint
  executable_fingerprint=$(shasum -a 256 "$APP_EXECUTABLE" | awk '{print $1}')
  CURRENT_INSTANCE_FINGERPRINT=$(
    printf '%s\n%s\n' "$CURRENT_BUILD_FINGERPRINT" "$executable_fingerprint" |
      shasum -a 256 |
      awk '{print $1}'
  )
}

owned_process_is_running() {
  [ -f "$PID_FILE" ] || return 1
  pid=$(sed -n '1p' "$PID_FILE")
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  kill -0 "$pid" 2>/dev/null || return 1
  command=$(ps -p "$pid" -o command= 2>/dev/null || true)
  case "$command" in
    "$APP_EXECUTABLE"*) return 0 ;;
  esac
  return 1
}

launch_job_is_owned() {
  label=$1
  job=$(launchctl print "gui/$(id -u)/$label" 2>/dev/null) || return 1
  job_pid=$(printf '%s\n' "$job" |
    awk '/^[[:space:]]*pid = / {print $3; exit}')
  if [ -n "$job_pid" ]; then
    command=$(ps -p "$job_pid" -o command= 2>/dev/null || true)
    case "$command" in
      "$APP_EXECUTABLE"*) return 0 ;;
    esac
  fi
  printf '%s\n' "$job" | grep -F -- "$APP_EXECUTABLE" >/dev/null
}

cleanup_legacy_instance() {
  if ! launchctl print "gui/$(id -u)/$LEGACY_LAUNCH_LABEL" >/dev/null 2>&1; then
    return
  fi
  if launch_job_is_owned "$LEGACY_LAUNCH_LABEL"; then
    launchctl remove "$LEGACY_LAUNCH_LABEL"
  fi
}

stop_instance() {
  owned_pid=
  if owned_process_is_running; then
    owned_pid=$(sed -n '1p' "$PID_FILE")
  fi
  if launchctl print "gui/$(id -u)/$LAUNCH_LABEL" >/dev/null 2>&1; then
    if ! launch_job_is_owned "$LAUNCH_LABEL"; then
      printf '[hw_videoClips] refusing to remove an unowned UI test job: %s\n' \
        "$LAUNCH_LABEL" >&2
      return 1
    fi
    job_pid=$(launchctl print "gui/$(id -u)/$LAUNCH_LABEL" 2>/dev/null |
      awk '/^[[:space:]]*pid = / {print $3; exit}')
    if [ -n "$job_pid" ]; then
      command=$(ps -p "$job_pid" -o command= 2>/dev/null || true)
      case "$command" in
        "$APP_EXECUTABLE"*) owned_pid=$job_pid ;;
      esac
    fi
    launchctl remove "$LAUNCH_LABEL"
  fi
  if [ -n "$owned_pid" ] && kill -0 "$owned_pid" 2>/dev/null; then
    kill "$owned_pid" 2>/dev/null || true
    attempts=0
    while kill -0 "$owned_pid" 2>/dev/null && [ "$attempts" -lt 250 ]; do
      sleep 0.02
      attempts=$((attempts + 1))
    done
    if kill -0 "$owned_pid" 2>/dev/null; then
      printf '[hw_videoClips] isolated UI process did not stop: %s\n' \
        "$owned_pid" >&2
      return 1
    fi
  fi
  rm -f "$PID_FILE" "$SOCKET"
}

reset_state() {
  preserve_artifacts=${1:-0}
  stop_instance
  prepare_support_location
  mkdir -p "$SUPPORT" "$SUPPORT/fixtures"
  rm -f \
    "$SUPPORT/library.sqlite3" \
    "$SUPPORT/library.sqlite3-shm" \
    "$SUPPORT/library.sqlite3-wal" \
    "$SUPPORT/library.lock" \
    "$SUPPORT/control.sock"
  rm -rf \
    "$SUPPORT/sources" \
    "$SUPPORT/clips" \
    "$SUPPORT/Backups" \
    "$SUPPORT/Recovery" \
    "$SUPPORT/ui-checks"
  if [ "$preserve_artifacts" -eq 0 ]; then
    rm -rf "$SUPPORT/ui-runs"
  fi
  cp "$CANONICAL_DATABASE" "$SUPPORT/library.sqlite3"
  cp "$FIXTURE" "$SUPPORT/fixtures/playback-fixture.mp4"
}

start_instance() {
  startup_started_ms=$(clock_ms)
  mkdir -p "$STATE_ROOT"
  fixture_path="$SUPPORT/fixtures/playback-fixture.mp4"
  launchctl submit \
    -l "$LAUNCH_LABEL" \
    -o "$LOG" \
    -e "$ERROR_LOG" \
    -- /usr/bin/env \
    HW_VIDEO_CLIPS_APP_SUPPORT_DIR="$SUPPORT" \
    HW_VIDEO_CLIPS_AUTOMATION=1 \
    HW_VIDEO_CLIPS_AUTOMATION_MEDIA="$fixture_path" \
    HW_VIDEO_CLIPS_ACTIVATE_ON_LAUNCH=0 \
    HW_VIDEO_CLIPS_VISIBLE_ON_LAUNCH=0 \
    MTL_CAPTURE_ENABLED=1 \
    MTL_DEBUG_LAYER=1 \
    "$APP_EXECUTABLE"
  pid=
  attempts=0
  while [ -z "$pid" ] && [ "$attempts" -lt 100 ]; do
    pid=$(launchctl print "gui/$(id -u)/$LAUNCH_LABEL" 2>/dev/null |
      awk '/^[[:space:]]*pid = / {print $3; exit}')
    [ -n "$pid" ] || sleep 0.02
    attempts=$((attempts + 1))
  done
  [ -n "$pid" ] || {
    printf '[hw_videoClips] isolated UI launch job has no process\n' >&2
    return 1
  }
  printf '%s\n' "$pid" >"$PID_FILE"
  attempts=0
  while [ ! -S "$SOCKET" ] && [ "$attempts" -lt 200 ]; do
    if ! kill -0 "$pid" 2>/dev/null; then
      replacement_pid=$(launchctl print \
        "gui/$(id -u)/$LAUNCH_LABEL" 2>/dev/null |
        awk '/^[[:space:]]*pid = / {print $3; exit}')
      if [ -n "$replacement_pid" ]; then
        pid=$replacement_pid
        printf '%s\n' "$pid" >"$PID_FILE"
      fi
    fi
    sleep 0.02
    attempts=$((attempts + 1))
  done
  [ -S "$SOCKET" ] || {
    printf '[hw_videoClips] isolated UI control socket did not appear\n' >&2
    tail -40 "$LOG" >&2 || true
    tail -40 "$ERROR_LOG" >&2 || true
    return 1
  }
  INSTANCE_STARTUP_MS=$(( $(clock_ms) - startup_started_ms ))
  printf '%s\n' "$INSTANCE_STARTUP_MS" >"$STARTUP_FILE"
  sleep 0.1
}

ensure_instance() {
  ensure_build
  cleanup_legacy_instance
  current_support=$(readlink "$SUPPORT_LINK" 2>/dev/null || true)
  if [ "$current_support" != "$SUPPORT" ]; then
    stop_instance
  fi
  prepare_support_location
  stored_fingerprint=$(sed -n '1p' "$INSTANCE_FINGERPRINT_FILE" 2>/dev/null || true)
  if [ "$CURRENT_INSTANCE_FINGERPRINT" != "$stored_fingerprint" ]; then
    reset_state
    printf '%s\n' "$CURRENT_INSTANCE_FINGERPRINT" >"$INSTANCE_FINGERPRINT_FILE"
  fi
  if ! owned_process_is_running || [ ! -S "$SOCKET" ]; then
    stop_instance
    if [ ! -f "$SUPPORT/library.sqlite3" ]; then
      reset_state
    fi
    start_instance
  fi
}

run_cli() {
  HW_VIDEO_CLIPS_APP_SUPPORT_DIR="$SUPPORT" "$CLI_EXECUTABLE" "$@"
}

scenario_mutation() {
  scenario=$1
  jq -r '.mutation // "transient"' "$scenario"
}

run_scenario_once() {
  scenario=$1
  [ -f "$scenario" ] || {
    printf '[hw_videoClips] UI scenario does not exist: %s\n' "$scenario" >&2
    return 2
  }
  ensure_instance
  scenario_startup_ms=$INSTANCE_STARTUP_MS
  set +e
  result=$(run_cli ui run --file "$scenario")
  status=$?
  set -e
  printf '%s\n' "$result" |
    jq -c --argjson startup_ms "$scenario_startup_ms" \
      '.data.startup_ms = $startup_ms'
  return "$status"
}

run_scenario() {
  scenario=$1
  [ -f "$scenario" ] || {
    printf '[hw_videoClips] UI scenario does not exist: %s\n' "$scenario" >&2
    return 2
  }
  mutation=$(scenario_mutation "$scenario")
  [ -n "$mutation" ] || mutation=transient
  if [ "$mutation" = "persistent" ]; then
    ensure_build
    reset_state
    printf '%s\n' "$CURRENT_INSTANCE_FINGERPRINT" >"$INSTANCE_FINGERPRINT_FILE"
  fi
  set +e
  run_scenario_once "$scenario"
  status=$?
  set -e
  if [ "$mutation" = "persistent" ] || [ "$status" -ne 0 ]; then
    preserve_artifacts=1
    reset_state "$preserve_artifacts"
    ensure_instance
  fi
  return "$status"
}

run_persistence_pair() {
  mutation_scenario=$1
  verification_scenario=$2
  [ -f "$mutation_scenario" ] && [ -f "$verification_scenario" ] || {
    printf '%s\n' '[hw_videoClips] persistence scenarios must exist' >&2
    return 2
  }
  [ "$(scenario_mutation "$mutation_scenario")" = "persistent" ] || {
    printf '%s\n' '[hw_videoClips] persistence mutation scenario must use mutation=persistent' >&2
    return 2
  }
  [ "$(scenario_mutation "$verification_scenario")" = "transient" ] || {
    printf '%s\n' '[hw_videoClips] persistence verification scenario must use mutation=transient' >&2
    return 2
  }

  ensure_build
  reset_state
  printf '%s\n' "$CURRENT_INSTANCE_FINGERPRINT" >"$INSTANCE_FINGERPRINT_FILE"
  start_instance

  set +e
  mutation_result=$(run_scenario_once "$mutation_scenario")
  mutation_status=$?
  set -e
  verification_result=null
  verification_status=0
  restart_ms=0
  if [ "$mutation_status" -eq 0 ]; then
    stop_instance
    start_instance
    restart_ms=$INSTANCE_STARTUP_MS
    set +e
    verification_result=$(run_scenario_once "$verification_scenario")
    verification_status=$?
    set -e
  fi

  final_status=$mutation_status
  if [ "$final_status" -eq 0 ]; then
    final_status=$verification_status
  fi
  preserve_artifacts=0
  if [ "$final_status" -ne 0 ]; then
    preserve_artifacts=1
  fi
  reset_state "$preserve_artifacts"
  printf '%s\n' "$CURRENT_INSTANCE_FINGERPRINT" >"$INSTANCE_FINGERPRINT_FILE"
  start_instance

  jq -cn \
    --argjson mutation "$mutation_result" \
    --argjson verification "$verification_result" \
    --argjson restart_ms "$restart_ms" \
    '{
      ok: (($mutation.ok // false) and ($verification.ok // false)),
      command: "ui.persistence",
      data: {
        mutation: $mutation.data,
        verification: $verification.data,
        restart_ms: $restart_ms
      }
    } + (
      if (($mutation.ok // false) and ($verification.ok // false))
      then {}
      else {error: ($mutation.error // $verification.error)}
      end
    )'
  return "$final_status"
}

case "${1:-}" in
  run)
    ui_test_require_jq
    [ "$#" -eq 2 ] || {
      printf 'usage: %s run <scenario.json>\n' "$0" >&2
      exit 2
    }
    run_scenario "$2"
    ;;
  persistence)
    ui_test_require_jq
    [ "$#" -eq 3 ] || {
      printf 'usage: %s persistence <mutation.json> <verification.json>\n' \
        "$0" >&2
      exit 2
    }
    run_persistence_pair "$2" "$3"
    ;;
  capture)
    ensure_instance
    shift
    run_cli ui capture "$@"
    ;;
  bridge)
    ui_test_require_jq
    ensure_instance
    HW_VIDEO_CLIPS_UI_TEST_HIDDEN=1 \
      "$ROOT/scripts/ui-bridge.sh" "$STATE_ROOT" "$APP_EXECUTABLE" "$CLI_EXECUTABLE"
    ;;
  benchmark)
    ui_test_require_jq
    "$ROOT/scripts/ui-benchmark.sh"
    ;;
  visual)
    ui_test_require_jq
    "$ROOT/scripts/ui-visual-check.sh"
    ;;
  suite)
    ui_test_require_jq
    "$ROOT/test.sh"
    run_scenario "$ROOT/tests/ui/hidden-launch.json"
    run_scenario "$ROOT/tests/ui/fast.json"
    HW_VIDEO_CLIPS_UI_TEST_HIDDEN=1 \
      "$ROOT/scripts/ui-bridge.sh" \
      "$STATE_ROOT" \
      "$APP_EXECUTABLE" \
      "$CLI_EXECUTABLE"
    "$ROOT/scripts/ui-benchmark.sh"
    run_persistence_pair \
      "$ROOT/tests/ui/persistent-mirror.json" \
      "$ROOT/tests/ui/persistent-mirror-verify.json"
    run_cli ui simulate-tasks --scenario parallel >/dev/null
    set +e
    run_scenario "$ROOT/tests/ui/add-source-during-task.json"
    scenario_status=$?
    set -e
    run_cli ui simulate-tasks --scenario clear >/dev/null
    [ "$scenario_status" -eq 0 ] || exit "$scenario_status"
    "$ROOT/scripts/ui-visual-check.sh"
    run_scenario "$ROOT/tests/ui/fast.json" >/dev/null
    ;;
  reset)
    ensure_build
    cleanup_legacy_instance
    reset_state
    printf '%s\n' "$CURRENT_INSTANCE_FINGERPRINT" >"$INSTANCE_FINGERPRINT_FILE"
    start_instance
    printf 'startup_ms=%s\n' "$INSTANCE_STARTUP_MS"
    ;;
  status)
    ensure_instance
    printf 'pid=%s socket=%s support=%s startup_ms=%s\n' \
      "$(sed -n '1p' "$PID_FILE")" \
      "$SOCKET" \
      "$SUPPORT_LINK" \
      "$(sed -n '1p' "$STARTUP_FILE" 2>/dev/null || printf '0')"
    ;;
  stop)
    stop_instance
    ;;
  *)
    printf 'usage: %s run <scenario.json>|persistence <mutation.json> <verification.json>|capture [--gpu-trace]|bridge|benchmark|visual|suite|reset|status|stop\n' "$0" >&2
    exit 2
    ;;
esac
