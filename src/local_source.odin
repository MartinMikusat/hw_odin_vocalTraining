package main

import "core:crypto/sha2"
import hex "core:encoding/hex"
import "core:encoding/json"
import "core:fmt"
import os "core:os/old"
import os2 "core:os"

import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:sync"
import mem_virtual "core:mem/virtual"

FFProbe_Stream :: struct {
	codec_type: string,
	codec_name: string,
	width: int,
	height: int,
	avg_frame_rate: string,
}

FFProbe_Format :: struct {
	duration: string,
	format_name: string,
	size: string,
}

FFProbe_Result :: struct {
	streams: []FFProbe_Stream,
	format: FFProbe_Format,
}

Local_Source_Probe :: struct {
	metadata: Source_Context_Metadata,
	duration: f64,
	has_video: bool,
	has_audio: bool,
	compatible_video: bool,
	compatible_audio: bool,
}

local_source_sha256 :: proc(path: string, allocator := context.allocator) -> (string, bool) {
	file, open_error := os.open(path)
	if open_error != nil {return "", false}
	defer os.close(file)
	ctx: sha2.Context_256
	sha2.init_256(&ctx)
	buffer: [256 * 1024]byte
	for {
		count, read_error := os.read(file, buffer[:])
		if read_error != nil {return "", false}
		if count == 0 {break}
		sha2.update(&ctx, buffer[:count])
	}
	digest: [sha2.DIGEST_SIZE_256]byte
	sha2.final(&ctx, digest[:])
	encoded, encode_error := hex.encode(digest[:], allocator)
	if encode_error != nil {return "", false}
	return string(encoded), true
}

local_source_title :: proc(path: string, allocator := context.allocator) -> string {
	name := filepath.base(path)
	extension := filepath.ext(name)
	if len(extension) > 0 {name = name[:len(name)-len(extension)]}
	return strings.clone(name, allocator)
}

local_source_parse_rate :: proc(value: string) -> f64 {
	parts := strings.split(value, "/", context.temp_allocator)
	if len(parts) != 2 {return 0}
	numerator, numerator_ok := strconv.parse_f64(parts[0])
	denominator, denominator_ok := strconv.parse_f64(parts[1])
	if !numerator_ok || !denominator_ok || denominator == 0 {return 0}
	return numerator / denominator
}

local_source_probe :: proc(path: string, allocator := context.allocator) -> (Local_Source_Probe, bool) {
	command := [8]string{
		helper_command("ffprobe"), "-v", "error", "-show_streams",
		"-show_format", "-of", "json", path,
	}
	process_state, stdout, _, process_error := os2.process_exec(
		{command=command[:]},
		context.temp_allocator,
	)
	if process_error != nil || !process_state.success {return {}, false}
	data: FFProbe_Result
	if decode_error := json.unmarshal(stdout, &data, .JSON, context.temp_allocator);
	   decode_error != nil {
		return {}, false
	}
	result: Local_Source_Probe
	result.duration, _ = strconv.parse_f64(data.format.duration)
	result.metadata.ext = strings.clone(data.format.format_name, allocator)
	result.metadata.format_id = strings.clone("local", allocator)
	result.metadata.filesize_approx, _ = strconv.parse_i64(data.format.size)
	for stream in data.streams {
		switch stream.codec_type {
		case "video":
			if result.has_video {continue}
			result.has_video = true
			result.compatible_video = stream.codec_name == "h264"
			result.metadata.width = stream.width
			result.metadata.height = stream.height
			result.metadata.fps = local_source_parse_rate(stream.avg_frame_rate)
			result.metadata.vcodec = strings.clone(stream.codec_name, allocator)
		case "audio":
			if result.has_audio {continue}
			result.has_audio = true
			result.compatible_audio = stream.codec_name == "aac"
			result.metadata.acodec = strings.clone(stream.codec_name, allocator)
		}
	}
	return result, result.has_video && result.duration > 0
}

local_source_run_ffmpeg :: proc(job: ^Import_Job, command: []string) -> bool {
	log_file, log_error := os2.open(job.log_path, {.Write, .Create, .Append, .Inheritable})
	if log_error != nil {return false}
	defer os2.close(log_file)
	process, start_error := os2.process_start({command=command, stdout=log_file, stderr=log_file})
	if start_error != nil {return false}
	sync.mutex_lock(&job.process_mutex)
	job.process, job.has_process = process, true
	cancelled := job.cancelled
	if cancelled {_ = kill(i32(process.pid), 15)}
	sync.mutex_unlock(&job.process_mutex)
	process_state, wait_error := os2.process_wait(process)
	sync.mutex_lock(&job.process_mutex)
	job.has_process = false
	cancelled = job.cancelled
	sync.mutex_unlock(&job.process_mutex)
	return !cancelled && wait_error == nil && process_state.success
}

local_source_stage :: proc(job: ^Import_Job, path, staged_path: string, probe: Local_Source_Probe) -> bool {
	if probe.compatible_video && (!probe.has_audio || probe.compatible_audio) &&
	   strings.contains(probe.metadata.ext, "mov,mp4") {
		return os2.copy_file(staged_path, path) == nil
	}
	command := make([dynamic]string, context.temp_allocator)
	append(&command, helper_command("ffmpeg"), "-y", "-v", "error", "-i", path, "-map", "0:v:0")
	if probe.has_audio {append(&command, "-map", "0:a:0")}
	if probe.compatible_video {
		append(&command, "-c:v", "copy")
	} else {
		append(&command, "-c:v", "h264_videotoolbox")
	}
	if probe.has_audio {
		if probe.compatible_audio {append(&command, "-c:a", "copy")} else {append(&command, "-c:a", "aac")}
	} else {
		append(&command, "-an")
	}
	append(&command, "-movflags", "+faststart", staged_path)
	return local_source_run_ffmpeg(job, command[:])
}

import_job_process_local :: proc(job: ^Import_Job) -> bool {
	allocator := mem_virtual.arena_allocator(job.arena)
	hash, hashed := local_source_sha256(job.local_path, allocator)
	if !hashed {return false}
	job.last_video_id = fmt.aprintf("local-%s", hash, allocator=allocator)
	existing: ^Source_Video
	if len(job.replace_video_id) > 0 {
		for &source in job.sources {
			if source.workflow == job.workflow && source.kind == .Local &&
			   source.video_id == job.replace_video_id {
				existing = &source
				break
			}
		}
		if existing == nil || existing.content_sha256 != hash {return false}
	} else {
		for &source in job.sources {
			if source.workflow == job.workflow && source.kind == .Local &&
			   source.content_sha256 == hash {
				job.existing_sources += 1
				job.cli_existing_source = job.cli_work != nil
				return true
			}
		}
	}
	probe, probed := local_source_probe(job.local_path, allocator)
	if !probed {return false}
	directory := workflow_source_directory(job.workflow)
	os.make_directory(directory)
	staged_path := fmt.aprintf(
		"%s/%s.import-%020d.mp4",
		directory,
		job.last_video_id,
		job.operation_id,
		allocator=allocator,
	)
	_ = os.remove(staged_path)
	defer _ = os.remove(staged_path)
	import_job_set_phase(job, .Downloading)
	if !local_source_stage(job, job.local_path, staged_path, probe) {return false}
	import_job_set_phase(job, .Validating_Downloaded_Media)
	if !media_file_validate_tracks(staged_path, probe.has_audio) {return false}
	media_path := fmt.aprintf("%s/%s.mp4", directory, job.last_video_id, allocator=allocator)
	if !os.rename(staged_path, media_path) {return false}
	metadata_path := fmt.aprintf("%s/%s.info.json", directory, job.last_video_id, allocator=allocator)
	encoded, encode_error := json.marshal(probe.metadata, {}, allocator)
	if encode_error != nil || !os.write_entire_file(metadata_path, encoded) {
		_ = os.remove(media_path)
		return false
	}
	title := job.local_title
	if existing != nil && len(strings.trim_space(title)) == 0 {title = existing.title}
	if len(strings.trim_space(title)) == 0 {title = local_source_title(job.local_path, allocator)}
	source_id := source_id_for_workflow(job.workflow, job.last_video_id)
	if existing != nil {source_id = existing.id}
	source := Source_Video{
		id = strings.clone(source_id, allocator),
		workflow = job.workflow,
		kind = .Local,
		video_id = strings.clone(job.last_video_id, allocator),
		title = strings.clone(title, allocator),
		original_filename = strings.clone(filepath.base(job.local_path), allocator),
		content_sha256 = strings.clone(hash, allocator),
		has_audio = probe.has_audio,
		media_path = strings.clone(media_path, allocator),
		duration = probe.duration,
		metadata = probe.metadata,
		metadata_status = .Available,
		media_available = true,
	}
	probe.metadata = {}
	if existing != nil {
		job.updated_source = source
		job.has_source_update = true
		import_job_rebuild_clips(job, &source)
	} else {
		append(&job.new_sources, source)
	}
	return true
}
