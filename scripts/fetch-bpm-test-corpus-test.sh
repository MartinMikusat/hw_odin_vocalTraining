#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SUBJECT="$ROOT/scripts/fetch-bpm-test-corpus.sh"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fetch-bpm-test-corpus-test.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT HUP INT TERM

unset FFPROBE_JSON CURL_FAIL CURL_CONTENT_TYPE FFPROBE_FAIL FFPROBE_MALFORMED CURL_SOURCE CALLS

pass_count=0
fail() {
    printf 'not ok - %s\n' "$1" >&2
    exit 1
}
pass() {
    pass_count=$((pass_count + 1))
    printf 'ok %d - %s\n' "$pass_count" "$1"
}

new_fixture() {
    unset FFPROBE_JSON CURL_FAIL CURL_CONTENT_TYPE FFPROBE_FAIL FFPROBE_MALFORMED CURL_SOURCE CALLS
    CASE_ROOT="$TEST_ROOT/case-$pass_count"
    rm -rf "$CASE_ROOT"
    mkdir -p "$CASE_ROOT/repo/scripts" "$CASE_ROOT/repo/src/testdata/bpm" "$CASE_ROOT/bin"
    cp "$SUBJECT" "$CASE_ROOT/repo/scripts/fetch-bpm-test-corpus.sh"
    chmod +x "$CASE_ROOT/repo/scripts/fetch-bpm-test-corpus.sh"
    : > "$CASE_ROOT/calls"
    printf fixture > "$CASE_ROOT/download.mp3"
    cat > "$CASE_ROOT/bin/curl" <<'STUB'
#!/bin/sh
: "${CALLS:?}"
printf '%s\n' '--- curl ---' "$@" >> "$CALLS"
output=
max_filesize=
while [ "$#" -gt 0 ]; do
    case "$1" in
        --output) output=$2; shift 2 ;;
        --max-filesize) max_filesize=$2; shift 2 ;;
        *) shift ;;
    esac
done
[ "${CURL_FAIL:-0}" = 0 ] || { printf 'simulated curl failure\n' >&2; exit 28; }
: "${max_filesize:?curl omitted --max-filesize}"
source_size=$(wc -c < "${CURL_SOURCE:?}" | tr -d ' ')
[ "$source_size" -le "$max_filesize" ] || { printf 'simulated maximum file size exceeded\n' >&2; exit 63; }
cp "${CURL_SOURCE:?}" "$output"
printf '%s' "${CURL_CONTENT_TYPE:-audio/mpeg}"
STUB
    cat > "$CASE_ROOT/bin/ffprobe" <<'STUB'
#!/bin/sh
: "${CALLS:?}"
printf '%s\n' '--- ffprobe ---' "$@" >> "$CALLS"
[ "${FFPROBE_FAIL:-0}" = 0 ] || { printf 'simulated ffprobe failure\n' >&2; exit 1; }
if [ "${FFPROBE_MALFORMED:-0}" = 1 ]; then
    printf 'not-json\n'
elif [ -n "${FFPROBE_JSON:-}" ]; then
    printf '%s\n' "$FFPROBE_JSON"
else
    printf '%s\n' '{"streams":[{"codec_type":"audio","codec_name":"mp3","sample_rate":"44100","channels":2}],"format":{"format_name":"mp3","duration":"1.000000","bit_rate":"56","size":"7"}}'
fi
STUB
    chmod +x "$CASE_ROOT/bin/curl" "$CASE_ROOT/bin/ffprobe"
}

write_manifest() {
    python3 - "$CASE_ROOT/repo/src/testdata/bpm/manifest.json" "$1" <<'PY'
import json, sys
path, mutation = sys.argv[1:]
clip = {
    "id": "fixture",
    "path": "audio/fixture.mp3",
    "track_page_url": "https://example.test/tracks/fixture",
    "download_url": "https://example.test/audio/fixture.mp3",
    "sha256": "f16d05ec6b29248d2c61adb1e9263f78e4f7bace1b955014a2d17872cfe4064d",
    "media": {
        "format_name": "mp3", "codec_name": "mp3", "sample_rate_hz": 44100,
        "channels": 2, "duration_seconds": "1.000000", "bit_rate": 56, "size_bytes": 7,
    },
}
manifest = {"clips": [clip]}
namespace = {"manifest": manifest, "clip": clip}
exec(mutation, namespace)
manifest = namespace["manifest"]
with open(path, "w", encoding="utf-8") as handle:
    json.dump(manifest, handle)
PY
}

run_subject() {
    set +e
    OUTPUT=$(PATH="$CASE_ROOT/bin:/usr/bin:/bin" CALLS="$CASE_ROOT/calls" \
        CURL_SOURCE="$CASE_ROOT/download.mp3" CURL_FAIL="${CURL_FAIL-0}" \
        CURL_CONTENT_TYPE="${CURL_CONTENT_TYPE-audio/mpeg}" \
        FFPROBE_JSON="${FFPROBE_JSON-}" FFPROBE_FAIL="${FFPROBE_FAIL-0}" \
        FFPROBE_MALFORMED="${FFPROBE_MALFORMED-0}" \
        "$CASE_ROOT/repo/scripts/fetch-bpm-test-corpus.sh" "$@" 2>&1)
    STATUS=$?
    set -e
}

assert_failed_cleanly() {
    [ "$STATUS" -ne 0 ] || fail "$1: unexpectedly succeeded"
    case "$OUTPUT" in *Traceback*) fail "$1: exposed a Python traceback" ;; esac
}

new_fixture
printf '{broken' > "$CASE_ROOT/repo/src/testdata/bpm/manifest.json"
run_subject
assert_failed_cleanly 'malformed JSON'
case "$OUTPUT" in *JSON*manifest.json*) : ;; *) fail 'malformed JSON lacks concise manifest context' ;; esac
[ ! -e "$CASE_ROOT/repo/src/testdata/bpm/audio" ] || fail 'malformed JSON created audio directory'
pass 'malformed JSON fails concisely before effects'

for spec in \
    'manifest = []' \
    'manifest = {}' \
    'manifest["clips"] = ["bad"]' \
    'del clip["id"]' \
    'del clip["path"]' \
    'del clip["track_page_url"]' \
    'del clip["download_url"]' \
    'del clip["sha256"]' \
    'clip["id"] = "../bad"' \
    'clip["track_page_url"] = "http://example.test/page"' \
    'clip["download_url"] = "file:///tmp/audio"' \
    'clip["sha256"] = "bad"' \
    'del clip["media"]' \
    'clip["media"] = {"format_name": "mp3"}' \
    'clip["media"]["size_bytes"] = 0' \
    'clip["media"]["size_bytes"] = 104857601'
do
    new_fixture
    write_manifest "$spec"
    run_subject
    assert_failed_cleanly "schema case: $spec"
    [ ! -e "$CASE_ROOT/repo/src/testdata/bpm/audio" ] || fail "schema case created audio directory: $spec"
done
pass 'manifest schema, required fields, safe IDs, HTTPS URLs, checksums, and media are preflighted'

new_fixture
write_manifest 'manifest["clips"].append(dict(clip, id="other"))'
run_subject
assert_failed_cleanly 'duplicate path'
case "$OUTPUT" in *duplicate*path*) : ;; *) fail 'duplicate path error lacks context' ;; esac
new_fixture
write_manifest 'manifest["clips"].append(dict(clip, path="audio/other.mp3"))'
run_subject
assert_failed_cleanly 'duplicate id'
case "$OUTPUT" in *duplicate*id*) : ;; *) fail 'duplicate id error lacks context' ;; esac
pass 'duplicate IDs and paths are rejected'

new_fixture
write_manifest 'clip["path"] = "audio/../escape.mp3"'
run_subject
assert_failed_cleanly 'unsafe path'
new_fixture
write_manifest 'None'
mkdir -p "$CASE_ROOT/outside"
ln -s "$CASE_ROOT/outside" "$CASE_ROOT/repo/src/testdata/bpm/audio"
run_subject
assert_failed_cleanly 'symlink audio directory'
[ ! -e "$CASE_ROOT/outside/fixture.mp3" ] || fail 'symlink path escaped corpus directory'
pass 'unsafe and symlink paths cannot escape the corpus directory'

new_fixture
write_manifest 'manifest["clips"].append({"id": "bad", "path": "audio/bad.mp3"})'
run_subject
assert_failed_cleanly 'late invalid clip'
[ ! -s "$CASE_ROOT/calls" ] || fail 'preflight invoked a subprocess before validating all clips'
[ ! -e "$CASE_ROOT/repo/src/testdata/bpm/audio" ] || fail 'preflight created audio before validating all clips'
pass 'complete preflight happens before directory and subprocess effects'

new_fixture
write_manifest 'clip["sha256"] = "0" * 64'
mkdir -p "$CASE_ROOT/repo/src/testdata/bpm/audio"
printf fixture > "$CASE_ROOT/repo/src/testdata/bpm/audio/fixture.mp3"
run_subject
assert_failed_cleanly 'checksum mismatch'
case "$OUTPUT" in *fixture*checksum*mismatch*) : ;; *) fail 'checksum mismatch lacks clip context' ;; esac
pass 'existing checksum mismatch is rejected'

new_fixture
write_manifest 'None'
CURL_FAIL=1 run_subject
assert_failed_cleanly 'curl failure'
case "$OUTPUT" in *fixture*download*failed*) : ;; *) fail 'curl failure lacks clip context' ;; esac
[ ! -e "$CASE_ROOT/repo/src/testdata/bpm/audio/fixture.mp3" ] || fail 'curl failure installed destination'
if find "$CASE_ROOT/repo/src/testdata/bpm/audio" -name '*.part' -print | grep . >/dev/null; then
    fail 'curl failure left temporary parts'
fi
for option in --max-time --speed-time --speed-limit; do
    grep -qx -- "$option" "$CASE_ROOT/calls" || fail "curl missing bounded-transfer argument $option"
done
pass 'curl failures clean up and use bounded stall protection'
unset CURL_FAIL

new_fixture
write_manifest 'clip["media"]["size_bytes"] = 6'
run_subject
assert_failed_cleanly 'normal-mode oversized download'
grep -A1 -x -- '--max-filesize' "$CASE_ROOT/calls" | grep -qx '6' || fail 'normal mode did not pass exact manifest size to curl'
[ ! -e "$CASE_ROOT/repo/src/testdata/bpm/audio/fixture.mp3" ] || fail 'oversized download installed destination'
if find "$CASE_ROOT/repo/src/testdata/bpm/audio" -name '*.part' -print | grep . >/dev/null; then
    fail 'oversized download left temporary parts'
fi
pass 'normal mode gives curl the exact manifest byte limit and cleans oversized downloads'

new_fixture
write_manifest 'clip["media"]["channels"] = 1'
mkdir -p "$CASE_ROOT/repo/src/testdata/bpm/audio"
printf fixture > "$CASE_ROOT/repo/src/testdata/bpm/audio/fixture.mp3"
run_subject
assert_failed_cleanly 'media mismatch'
case "$OUTPUT" in *fixture*media*properties*differ*) : ;; *) fail 'media mismatch lacks clip context' ;; esac
pass 'media property mismatch is rejected'

new_fixture
write_manifest 'clip["sha256"] = ""; clip.pop("media")'
run_subject --record-checksums
[ "$STATUS" -eq 0 ] || fail "record mode failed: $OUTPUT"
grep -A1 -x -- '--max-filesize' "$CASE_ROOT/calls" | grep -qx '104857600' || fail 'record mode did not pass the 100 MiB hard ceiling to curl'
python3 - "$CASE_ROOT/repo/src/testdata/bpm/manifest.json" <<'PY' || fail 'recorded manifest content is incomplete'
import json, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    clip = json.load(handle)["clips"][0]
assert clip["sha256"] == "f16d05ec6b29248d2c61adb1e9263f78e4f7bace1b955014a2d17872cfe4064d"
assert clip["media"]["codec_name"] == "mp3"
PY
mode=$(stat -f '%Lp' "$CASE_ROOT/repo/src/testdata/bpm/manifest.json")
[ "$mode" = 644 ] || fail "recorded manifest mode is $mode, expected 644"
if find "$CASE_ROOT/repo/src/testdata/bpm" -name '.manifest.*' -print | grep . >/dev/null; then
    fail 'record mode left temporary manifest files'
fi
pass 'record mode atomically writes complete readable manifest and cleans temporary files'

FFPROBE_JSON=hostile CURL_FAIL=1 CURL_CONTENT_TYPE=text/html FFPROBE_FAIL=1 FFPROBE_MALFORMED=1
new_fixture
write_manifest 'None'
run_subject
[ "$STATUS" -eq 0 ] || fail "fixture did not reset hostile stub values: $OUTPUT"
pass 'each fixture resets hostile stub-control values'

new_fixture
write_manifest 'None'
mkdir -p "$CASE_ROOT/repo/src/testdata/bpm/audio"
printf fixture > "$CASE_ROOT/repo/src/testdata/bpm/audio/fixture.mp3"
FFPROBE_MALFORMED=1 run_subject
assert_failed_cleanly 'malformed ffprobe JSON'
case "$OUTPUT" in *fixture*ffprobe*JSON*) : ;; *) fail 'malformed ffprobe output lacks context' ;; esac
pass 'malformed subprocess JSON fails with context and no traceback'
unset FFPROBE_MALFORMED

printf '1..%d\n' "$pass_count"
