#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$ROOT/scripts/ui-test-common.sh"
ui_test_require_jq
VOCAL_SCENARIO="$ROOT/tests/ui/vocal-transport-wrap.json"
FULLSCREEN_SCENARIO="$ROOT/tests/ui/fullscreen-playback.json"

vocal_result=$("$ROOT/scripts/ui-test.sh" run "$VOCAL_SCENARIO")
vocal_artifact=$(printf '%s\n' "$vocal_result" | jq -r '.data.artifact')

test -s "$vocal_artifact/frame.png"
test -s "$vocal_artifact/overlay.png"
test -s "$vocal_artifact/render-trace.json"
test -s "$vocal_artifact/ui-snapshot.json"

jq -e '
  .schema_version == 2 and
  .viewport_width == 1280 and
  .viewport_height == 800 and
  .encoder_created == true and
  .command_buffer_status == "completed" and
  (.command_buffer_error // "") == "" and
  .fullscreen == false and
  any(.commands[]; .texture == "video")
' "$vocal_artifact/render-trace.json" >/dev/null

jq -e '
  . as $snapshot |
  def control($name):
    first($snapshot.controls[] | select(.functional_name == $name)).rect;
  (control("scrub clip timeline")) as $timeline |
  ([
    "play pause clip",
    "stop clip",
    "reset clip",
    "slower",
    "faster",
    "quieter",
    "louder",
    "player full screen toggle"
  ] | map(control(.))) as $controls |
  .surface.workflow == "vocal" and
  .surface.mode == "play" and
  .surface.media_loaded == true and
  all($controls[];
    .x >= $timeline.x and .x + .w <= $timeline.x + $timeline.w
  ) and
  control("play pause clip").y > control("slower").y and
  control("slower").y > control("player full screen toggle").y
' "$vocal_artifact/ui-snapshot.json" >/dev/null

result=$("$ROOT/scripts/ui-test.sh" run "$FULLSCREEN_SCENARIO")
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

printf 'visual=ok viewport=1280x800 vocal_wrap=ok gpu_trace=ok artifact=%s\n' \
  "$artifact"
