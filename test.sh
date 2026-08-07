#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
TEST_SUPPORT=$(mktemp -d "${TMPDIR:-/tmp}/hw_videoClips-tests.XXXXXX")
trap 'rm -rf "$TEST_SUPPORT"' EXIT

"$ROOT/scripts/dev-launch-policy-test.sh"
"$ROOT/scripts/fetch-bpm-test-corpus-test.sh"
"$ROOT/scripts/library-fixture.sh" validate "$ROOT/testdata/library.sqlite3"
sqlite3 "$ROOT/testdata/library.sqlite3" ".backup '$TEST_SUPPORT/library.sqlite3'"
PITCH_CAPTURE_OBJECT="$TEST_SUPPORT/pitch_capture.o"
BPM_ANALYSIS_OBJECT="$TEST_SUPPORT/bpm_analysis.o"
METRONOME_OBJECT="$TEST_SUPPORT/metronome.o"
PERFORMANCE_OBJECT="$TEST_SUPPORT/performance.o"
xcrun clang \
  -fobjc-arc \
  -fblocks \
  -mmacosx-version-min=13.0 \
  -c "$ROOT/src/pitch_capture.m" \
  -o "$PITCH_CAPTURE_OBJECT"
xcrun clang \
  -fobjc-arc \
  -fblocks \
  -mmacosx-version-min=13.0 \
  -Wall \
  -Wextra \
  -Werror \
  -Wpedantic \
  -Wconversion \
  -Wsign-conversion \
  -Wshorten-64-to-32 \
  -Wcast-align \
  -c "$ROOT/src/bpm_analysis.m" \
  -o "$BPM_ANALYSIS_OBJECT"
xcrun clang \
  -fobjc-arc \
  -fblocks \
  -mmacosx-version-min=13.0 \
  -Wall -Wextra -Werror -Wpedantic \
  -c "$ROOT/src/metronome.m" \
  -o "$METRONOME_OBJECT"
xcrun clang \
  -fobjc-arc \
  -fblocks \
  -mmacosx-version-min=13.0 \
  -Wall -Wextra -Werror -Wpedantic \
  -c "$ROOT/src/performance.m" \
  -o "$PERFORMANCE_OBJECT"

BPM_NO_AUDIO_FIXTURE="$TEST_SUPPORT/bpm-no-audio.mp4"
ffmpeg \
  -y \
  -loglevel error \
  -i "$ROOT/testdata/ui/playback-fixture.mp4" \
  -map 0:v:0 \
  -c copy \
  -an \
  "$BPM_NO_AUDIO_FIXTURE"

HW_VIDEO_CLIPS_APP_SUPPORT_DIR="$TEST_SUPPORT" \
HW_VIDEO_CLIPS_TEST_LIBRARY="$TEST_SUPPORT/library.sqlite3" \
HW_VIDEO_CLIPS_HEADLESS_TEST=1 \
HW_VIDEO_CLIPS_BPM_NO_AUDIO_FIXTURE="$BPM_NO_AUDIO_FIXTURE" \
HW_VIDEO_CLIPS_BPM_CORPUS_MANIFEST="$ROOT/src/testdata/bpm/manifest.json" \
odin test "$ROOT/src" \
  -define:ODIN_TEST_THREADS=1 \
  -define:HW_VIDEO_CLIPS_DEV_TASK_SIMULATION=true \
  -collection:match_sorter="$ROOT/../hw_odin_matchSorter" \
  -collection:flash="$ROOT/../hw_odin_ui_flash" \
  -collection:command_palette="$ROOT/../hw_odin_ui_commandPalette" \
  -collection:components="$ROOT/../hw_odin_ui_components" \
  -collection:task_queue="$ROOT/../hw_odin_concurrency_taskQueue" \
  -collection:ui_framework="$ROOT/../hw_odin_ui_framework" \
  -extra-linker-flags:"$PITCH_CAPTURE_OBJECT $BPM_ANALYSIS_OBJECT $METRONOME_OBJECT $PERFORMANCE_OBJECT -framework AppKit -framework Foundation -framework AVFoundation -framework AVFAudio -framework AudioToolbox -framework CoreAudio -framework CoreMedia -framework Metal -framework QuartzCore -framework CoreVideo -framework CoreText -framework CoreGraphics -framework ImageIO -framework Accelerate"

NORMALIZED_CLIP="$TEST_SUPPORT/normalized-clip.mp4"
ffmpeg \
  -y \
  -loglevel error \
  -i "$ROOT/testdata/ui/playback-fixture.mp4" \
  -t 0.5 \
  -vf 'setpts=PTS-STARTPTS' \
  -af 'asetpts=PTS-STARTPTS' \
  -c:v hevc_videotoolbox \
  -profile:v main \
  -pix_fmt yuv420p \
  -q:v 60 \
  -tag:v hvc1 \
  -c:a aac \
  -movflags +faststart \
  "$NORMALIZED_CLIP"
VIDEO_START=$(ffprobe -v error -select_streams v:0 -show_entries stream=start_time -of default=noprint_wrappers=1:nokey=1 "$NORMALIZED_CLIP")
AUDIO_START=$(ffprobe -v error -select_streams a:0 -show_entries stream=start_time -of default=noprint_wrappers=1:nokey=1 "$NORMALIZED_CLIP")
FIRST_VIDEO_PTS=$(ffprobe -v error -select_streams v:0 -read_intervals '%+#1' -show_entries frame=pts_time -of default=noprint_wrappers=1:nokey=1 "$NORMALIZED_CLIP")
VIDEO_CODEC=$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of default=noprint_wrappers=1:nokey=1 "$NORMALIZED_CLIP")
VIDEO_TAG=$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_tag_string -of default=noprint_wrappers=1:nokey=1 "$NORMALIZED_CLIP")
[ "$VIDEO_CODEC" = "hevc" ]
[ "$VIDEO_TAG" = "hvc1" ]
[ "$VIDEO_START" = "0.000000" ]
[ "$AUDIO_START" = "0.000000" ]
[ "$FIRST_VIDEO_PTS" = "0.000000" ]
