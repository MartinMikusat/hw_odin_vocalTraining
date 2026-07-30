#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
HW_VIDEO_CLIPS_APP_SUPPORT_DIR=${HW_VIDEO_CLIPS_APP_SUPPORT_DIR:-"$ROOT/build/dev-support"}
export HW_VIDEO_CLIPS_APP_SUPPORT_DIR

exec "$ROOT/build/hw_videoClips" "$@"
