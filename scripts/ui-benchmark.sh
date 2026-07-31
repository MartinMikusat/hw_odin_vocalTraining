#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$ROOT/scripts/ui-test-common.sh"
ui_test_require_jq
SCENARIO="$ROOT/tests/ui/fast.json"
SAMPLES=$(mktemp "${TMPDIR:-/tmp}/hw-video-clips-ui-benchmark.XXXXXX")
trap 'rm -f "$SAMPLES"' EXIT

"$ROOT/scripts/ui-test.sh" run "$SCENARIO" >/dev/null

run=1
while [ "$run" -le 20 ]; do
  result=$("$ROOT/scripts/ui-test.sh" run "$SCENARIO")
  elapsed=$(printf '%s\n' "$result" | jq -r '.data.elapsed_ms')
  case "$elapsed" in
    ''|*[!0-9]*)
      printf '[hw_videoClips] invalid benchmark result: %s\n' "$result" >&2
      exit 1
      ;;
  esac
  printf '%s\n' "$elapsed" >>"$SAMPLES"
  run=$((run + 1))
done

p95=$(sort -n "$SAMPLES" | sed -n '19p')
maximum=$(sort -n "$SAMPLES" | tail -1)
printf 'runs=20 steps=10 p95_ms=%s max_ms=%s target_ms=100\n' \
  "$p95" "$maximum"
[ "$p95" -lt 100 ] || {
  printf '[hw_videoClips] warm UI scenario p95 exceeds 100 ms\n' >&2
  exit 1
}
