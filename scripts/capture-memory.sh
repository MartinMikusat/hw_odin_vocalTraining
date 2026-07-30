#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

MODE=$1
PID=$2
APP=$3
RSS_KB=$4
EXECUTABLE="$APP/Contents/MacOS/hw_videoClips"
TIMESTAMP=$(date '+%Y%m%d-%H%M%S')
DEST="$ROOT/build/memory-diagnostics/$TIMESTAMP-$MODE-pid-$PID"

case "$PID" in
  ''|*[!0-9]*) exit 2 ;;
esac
if ! kill -0 "$PID" 2>/dev/null; then
  exit 0
fi

mkdir -p "$DEST"
{
  printf 'mode=%s\n' "$MODE"
  printf 'process_id=%s\n' "$PID"
  printf 'trigger_rss_kb=%s\n' "$RSS_KB"
  printf 'git_revision=%s\n' "$(git rev-parse HEAD 2>/dev/null || echo unknown)"
  printf 'built_binary=%s\n' "$EXECUTABLE"
  if [ -f "$EXECUTABLE" ]; then
    xcrun dwarfdump --uuid "$EXECUTABLE" 2>/dev/null || true
  fi
} > "$DEST/metadata.txt"

ps -p "$PID" -o pid=,ppid=,rss=,vsz=,etime=,state=,command= \
  > "$DEST/process.txt" 2>&1 || true
vmmap -summary "$PID" > "$DEST/vmmap-summary.txt" 2>&1 || true
footprint --pid "$PID" > "$DEST/footprint.txt" 2>&1 || true
heap -s -H "$PID" > "$DEST/heap-summary.txt" 2>&1 || true
sample "$PID" 5 10 -file "$DEST/sample.txt" >/dev/null 2>&1 || true

ls -1dt "$ROOT"/build/memory-diagnostics/* 2>/dev/null |
  sed -n '21,$p' |
  while IFS= read -r old; do
    case "$old" in
      "$ROOT"/build/memory-diagnostics/*) rm -rf -- "$old" ;;
    esac
  done

printf '[hw_videoClips] memory diagnostics: %s\n' "$DEST"
