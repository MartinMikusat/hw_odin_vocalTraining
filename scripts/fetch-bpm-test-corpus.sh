#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
exec python3 - "$ROOT" "$@" <<'PY'
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
from urllib.parse import urlsplit

ROOT = Path(sys.argv[1])
args = sys.argv[2:]
if args not in ([], ["--record-checksums"]):
    print("usage: scripts/fetch-bpm-test-corpus.sh [--record-checksums]", file=sys.stderr)
    raise SystemExit(2)
record = args == ["--record-checksums"]
manifest_path = ROOT / "src/testdata/bpm/manifest.json"
corpus_dir = manifest_path.parent
audio_dir = corpus_dir / "audio"
user_agent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 BPM-Corpus-Fetch/1.0"
accepted_types = {"audio/mpeg", "audio/mp3", "application/octet-stream", "binary/octet-stream"}
MAX_MP3_SIZE_BYTES = 100 * 1024 * 1024
media_fields = {
    "format_name": str,
    "codec_name": str,
    "sample_rate_hz": int,
    "channels": int,
    "duration_seconds": str,
    "bit_rate": int,
    "size_bytes": int,
}


class AcquisitionError(Exception):
    pass


def fail(message):
    raise AcquisitionError(message)


def sha256(path):
    digest = hashlib.sha256()
    try:
        with path.open("rb") as handle:
            for block in iter(lambda: handle.read(1024 * 1024), b""):
                digest.update(block)
    except OSError as error:
        fail(f"cannot read media file {path}: {error}")
    return digest.hexdigest()


def require_https(value, context):
    if not isinstance(value, str) or not value:
        fail(f"{context} must be a non-empty HTTPS URL")
    parsed = urlsplit(value)
    if parsed.scheme != "https" or not parsed.netloc or parsed.username or parsed.password:
        fail(f"{context} must be an HTTPS URL without credentials")


def validate_media(media, context):
    if not isinstance(media, dict):
        fail(f"{context} must be an object")
    for field, expected_type in media_fields.items():
        value = media.get(field)
        if type(value) is not expected_type or (expected_type is str and not value):
            fail(f"{context}.{field} must be a non-empty {expected_type.__name__}")
    if media["format_name"] != "mp3" or media["codec_name"] != "mp3":
        fail(f"{context} must describe MP3 media")
    for field in ("sample_rate_hz", "channels", "bit_rate", "size_bytes"):
        if media[field] <= 0:
            fail(f"{context}.{field} must be positive")
    if media["size_bytes"] > MAX_MP3_SIZE_BYTES:
        fail(f"{context}.size_bytes exceeds the {MAX_MP3_SIZE_BYTES}-byte safety limit")


def load_and_preflight_manifest():
    try:
        with manifest_path.open(encoding="utf-8") as handle:
            manifest = json.load(handle)
    except json.JSONDecodeError as error:
        fail(f"invalid JSON in {manifest_path}: line {error.lineno}, column {error.colno}: {error.msg}")
    except OSError as error:
        fail(f"cannot read manifest {manifest_path}: {error}")

    if not isinstance(manifest, dict):
        fail(f"manifest {manifest_path} must contain a JSON object")
    clips = manifest.get("clips")
    if not isinstance(clips, list) or not clips:
        fail(f"manifest {manifest_path} field 'clips' must be a non-empty list")

    seen_ids = set()
    seen_paths = set()
    for index, clip in enumerate(clips):
        context = f"manifest clip {index}"
        if not isinstance(clip, dict):
            fail(f"{context} must be an object")
        clip_id = clip.get("id")
        if not isinstance(clip_id, str) or not re.fullmatch(r"[a-z0-9]+(?:-[a-z0-9]+)*", clip_id):
            fail(f"{context}.id must contain lowercase letters, digits, and single hyphens only")
        context = f"manifest clip {index} [{clip_id}]"
        if clip_id in seen_ids:
            fail(f"{context} has duplicate id: {clip_id}")
        seen_ids.add(clip_id)

        relative_path = clip.get("path")
        if not isinstance(relative_path, str) or not re.fullmatch(r"audio/[a-z0-9]+(?:-[a-z0-9]+)*\.mp3", relative_path):
            fail(f"{context}.path is unsafe or invalid: {relative_path!r}")
        if relative_path in seen_paths:
            fail(f"{context} has duplicate path: {relative_path}")
        seen_paths.add(relative_path)

        require_https(clip.get("track_page_url"), f"{context}.track_page_url")
        require_https(clip.get("download_url"), f"{context}.download_url")

        expected = clip.get("sha256")
        if not isinstance(expected, str):
            fail(f"{context}.sha256 must be a string")
        if expected and not re.fullmatch(r"[0-9a-f]{64}", expected):
            fail(f"{context}.sha256 must be empty or 64 lowercase hexadecimal characters")
        if not expected and not record:
            fail(f"{context}.sha256 is empty; use --record-checksums only for reviewed acquisition")
        if not record:
            validate_media(clip.get("media"), f"{context}.media")
        elif "media" in clip and clip["media"] is not None:
            validate_media(clip["media"], f"{context}.media")

    return manifest, clips


def ensure_safe_storage():
    try:
        corpus_real = corpus_dir.resolve(strict=True)
    except OSError as error:
        fail(f"cannot resolve corpus directory {corpus_dir}: {error}")
    if corpus_dir.is_symlink():
        fail(f"corpus directory must not be a symlink: {corpus_dir}")
    if audio_dir.is_symlink():
        fail(f"audio directory must not be a symlink: {audio_dir}")
    try:
        audio_dir.mkdir(mode=0o755, parents=False, exist_ok=True)
    except OSError as error:
        fail(f"cannot create audio directory {audio_dir}: {error}")
    try:
        if audio_dir.resolve(strict=True).parent != corpus_real:
            fail(f"audio directory escapes corpus directory: {audio_dir}")
    except OSError as error:
        fail(f"cannot resolve audio directory {audio_dir}: {error}")


def run_command(command, context):
    try:
        return subprocess.run(command, check=False, capture_output=True, text=True)
    except OSError as error:
        fail(f"{context}: cannot run {command[0]}: {error}")


def inspect_mp3(path, clip_id):
    result = run_command(
        [
            "ffprobe", "-v", "error", "-show_entries",
            "stream=codec_name,codec_type,sample_rate,channels:format=format_name,duration,bit_rate,size",
            "-of", "json", str(path),
        ],
        f"[{clip_id}] ffprobe failed",
    )
    if result.returncode != 0:
        detail = result.stderr.strip() or f"exit status {result.returncode}"
        fail(f"[{clip_id}] ffprobe rejected media: {detail}")
    try:
        probe = json.loads(result.stdout)
    except json.JSONDecodeError as error:
        fail(f"[{clip_id}] ffprobe returned invalid JSON: line {error.lineno}, column {error.colno}")
    if not isinstance(probe, dict):
        fail(f"[{clip_id}] ffprobe JSON root must be an object")
    raw_streams = probe.get("streams")
    if not isinstance(raw_streams, list):
        fail(f"[{clip_id}] ffprobe JSON is missing a streams list")
    streams = [stream for stream in raw_streams if isinstance(stream, dict) and stream.get("codec_type") == "audio"]
    if not streams or streams[0].get("codec_name") != "mp3":
        fail(f"[{clip_id}] media does not contain an MP3 audio stream")
    fmt = probe.get("format")
    if not isinstance(fmt, dict):
        fail(f"[{clip_id}] ffprobe JSON is missing a format object")
    format_name = fmt.get("format_name")
    if not isinstance(format_name, str) or "mp3" not in format_name.split(","):
        fail(f"[{clip_id}] unexpected media format: {format_name or '<missing>'}")
    stream = streams[0]
    try:
        properties = {
            "format_name": format_name,
            "codec_name": stream["codec_name"],
            "sample_rate_hz": int(stream["sample_rate"]),
            "channels": int(stream["channels"]),
            "duration_seconds": fmt["duration"],
            "bit_rate": int(fmt["bit_rate"]),
            "size_bytes": int(fmt["size"]),
        }
    except (KeyError, TypeError, ValueError) as error:
        fail(f"[{clip_id}] incomplete ffprobe media properties: {error}")
    try:
        validate_media(properties, f"[{clip_id}] ffprobe media")
    except AcquisitionError as error:
        fail(str(error))
    return properties


def download_clip(clip, destination):
    clip_id = clip["id"]
    max_filesize = MAX_MP3_SIZE_BYTES if record else clip["media"]["size_bytes"]
    try:
        fd, temporary_name = tempfile.mkstemp(prefix=f".{clip_id}.", suffix=".part", dir=audio_dir)
        os.close(fd)
    except OSError as error:
        fail(f"[{clip_id}] cannot create temporary download in {audio_dir}: {error}")
    temporary = Path(temporary_name)
    try:
        result = run_command(
            [
                "curl", "--fail", "--location", "--silent", "--show-error",
                "--retry", "2", "--retry-all-errors", "--connect-timeout", "30",
                "--max-time", "300", "--speed-time", "30", "--speed-limit", "1024",
                "--max-filesize", str(max_filesize),
                "--user-agent", user_agent,
                "--referer", clip["track_page_url"],
                "--output", str(temporary),
                "--write-out", "%{content_type}",
                clip["download_url"],
            ],
            f"[{clip_id}] download failed",
        )
        if result.returncode != 0:
            detail = result.stderr.strip() or f"curl exit status {result.returncode}"
            fail(f"[{clip_id}] download failed: {detail}")
        content_type = result.stdout.strip().lower().split(";", 1)[0]
        if content_type not in accepted_types:
            fail(f"[{clip_id}] unexpected HTTP media type: {content_type or '<missing>'}")
        properties = inspect_mp3(temporary, clip_id)
        actual = sha256(temporary)
        expected = clip["sha256"]
        if expected and actual != expected:
            fail(f"[{clip_id}] checksum mismatch: expected {expected}, got {actual}")
        try:
            os.replace(temporary, destination)
        except OSError as error:
            fail(f"[{clip_id}] cannot install verified media at {destination}: {error}")
        print(f"[{clip_id}] downloaded and verified {actual}")
        return actual, properties
    finally:
        try:
            temporary.unlink(missing_ok=True)
        except OSError:
            pass


def record_manifest(manifest):
    try:
        fd, temporary_name = tempfile.mkstemp(prefix=".manifest.", suffix=".json", dir=corpus_dir)
    except OSError as error:
        fail(f"cannot create temporary manifest in {corpus_dir}: {error}")
    temporary = Path(temporary_name)
    try:
        os.fchmod(fd, 0o644)
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(manifest, handle, indent=2, ensure_ascii=False)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, manifest_path)
        os.chmod(manifest_path, 0o644)
    except (OSError, TypeError, ValueError) as error:
        fail(f"cannot atomically record manifest {manifest_path}: {error}")
    finally:
        try:
            temporary.unlink(missing_ok=True)
        except OSError:
            pass


def main():
    manifest, clips = load_and_preflight_manifest()
    for command in ("curl", "ffprobe"):
        if shutil.which(command) is None:
            fail(f"required command is not available: {command}")
    ensure_safe_storage()

    for clip in clips:
        clip_id = clip["id"]
        destination = corpus_dir / clip["path"]
        if destination.is_symlink():
            fail(f"[{clip_id}] destination must not be a symlink: {destination}")
        if destination.exists():
            if not destination.is_file():
                fail(f"[{clip_id}] destination is not a regular file: {destination}")
            actual = sha256(destination)
            expected = clip["sha256"]
            if expected and actual != expected:
                fail(f"[{clip_id}] checksum mismatch for existing file: expected {expected}, got {actual}")
            properties = inspect_mp3(destination, clip_id)
            print(f"[{clip_id}] verified existing {actual}")
        else:
            actual, properties = download_clip(clip, destination)

        if record:
            clip["sha256"] = actual
            clip["media"] = properties
        elif clip["media"] != properties:
            fail(f"[{clip_id}] media properties differ from manifest; expected {clip['media']!r}, got {properties!r}")

    if record:
        record_manifest(manifest)
        print(f"recorded checksums and ffprobe media properties in {manifest_path}")
    print(f"verified {len(clips)} corpus files")


try:
    main()
except AcquisitionError as error:
    print(f"error: {error}", file=sys.stderr)
    raise SystemExit(1)
except Exception as error:
    print(f"error: acquisition failed unexpectedly: {type(error).__name__}: {error}", file=sys.stderr)
    raise SystemExit(1)
PY
