#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
VT_APP_SUPPORT_DIR=${VT_APP_SUPPORT_DIR:-"$ROOT/build/dev-support"}
export VT_APP_SUPPORT_DIR

exec "$ROOT/build/vocal-training" "$@"
