#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$ROOT/scripts/ui-test-common.sh"
ui_test_require_jq

run_baseline() {
  scenario=$1
  result=$("$ROOT/scripts/ui-test.sh" run "$scenario")
  artifact=$(printf '%s\n' "$result" | jq -r '.data.artifact')
  [ -n "$artifact" ] && [ "$artifact" != "null" ] && [ -f "$artifact/summary.json" ] || {
    printf '[hw_videoClips] missing performance summary: %s\n' "$result" >&2
    return 1
  }
  jq -r '
    [.frame_count,
     .frame_cpu.p50_ms, .frame_cpu.p95_ms, .frame_cpu.worst_ms,
     .callback_gap.p50_ms, .callback_gap.p95_ms, .callback_gap.worst_ms,
     .gpu.p50_ms, .gpu.p95_ms, .gpu.worst_ms] |
    @tsv
  ' "$artifact/summary.json" | awk -v name="$(basename "$scenario" .json)" '
    {printf "%s frames=%s cpu_ms[p50=%s p95=%s worst=%s] gap_ms[p50=%s p95=%s worst=%s] gpu_ms[p50=%s p95=%s worst=%s]\n", name, $1, $2, $3, $4, $5, $6, $7, $8, $9, $10}
  '
  printf 'artifact=%s\n' "$artifact"
}

run_baseline "$ROOT/tests/ui/performance-playback.json"
run_baseline "$ROOT/tests/ui/performance-scrub.json"
