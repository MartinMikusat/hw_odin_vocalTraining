#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$ROOT/scripts/ui-test-common.sh"
ui_test_require_jq
SCENARIO="$ROOT/tests/ui/fullscreen-playback.json"

result=$("$ROOT/scripts/ui-test.sh" run "$SCENARIO")
artifact=$(printf '%s\n' "$result" | jq -r '.data.artifact')

test -s "$artifact/frame.png"
test -s "$artifact/overlay.png"
test -s "$artifact/render-trace.json"
test -s "$artifact/ui-snapshot.json"
test -d "$artifact/frame.gputrace"

jq -e '
  .schema_version == 2 and
  .viewport_width == 1280 and
  .viewport_height == 800 and
  .pixel_width == (.viewport_width * .scale) and
  .pixel_height == (.viewport_height * .scale) and
  .encoder_created == true and
  .command_buffer_status == "completed" and
  (.command_buffer_error // "") == "" and
  .fullscreen == true and
  .timeline_progress > 0 and
  .commands[0].kind == "clear" and
  any(.commands[]; .texture == "video") and
  any(.commands[]; .kind == "draw" and .pipeline == "ordered-ui") and
  any(.commands[]; .pipeline == "fullscreen-timeline")
' "$artifact/render-trace.json" >/dev/null

jq -e '
  .surface.playback_fullscreen == true and
  .surface.media_loaded == true and
  .surface.overlay_revision > 0 and
  .surface.playback_timeline_progress > 0
' "$artifact/ui-snapshot.json" >/dev/null

printf 'visual=ok viewport=1280x800 gpu_trace=ok artifact=%s\n' "$artifact"
