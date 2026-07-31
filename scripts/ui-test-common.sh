#!/bin/sh

ui_test_require_jq() {
  if command -v jq >/dev/null 2>&1; then
    return
  fi
  printf '%s\n' \
    '[hw_videoClips] jq is required for UI test JSON processing. Install it with: brew install jq' \
    >&2
  return 127
}
