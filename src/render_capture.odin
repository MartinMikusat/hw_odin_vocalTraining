package main

import "base:runtime"
import "core:fmt"
import "core:hash"
import "core:os"
import "core:path/filepath"
import "core:strings"
import mem_virtual "core:mem/virtual"

foreign import image_io "system:ImageIO.framework"
foreign image_io {
	CGImageDestinationCreateWithURL :: proc "c" (
		url, image_type: rawptr,
		count: uint,
		options: rawptr,
	) -> rawptr ---
	CGImageDestinationAddImage :: proc "c" (
		destination, image, properties: rawptr,
	) ---
	CGImageDestinationFinalize :: proc "c" (
		destination: rawptr,
	) -> bool ---
}

foreign import render_capture_core_graphics "system:CoreGraphics.framework"
foreign render_capture_core_graphics {
	CGDataProviderCreateWithData :: proc "c" (
		info, data: rawptr,
		size: uint,
		release_data: rawptr,
	) -> rawptr ---
	CGImageCreate :: proc "c" (
		width, height, bits_per_component, bits_per_pixel,
		bytes_per_row: uint,
		space: rawptr,
		bitmap_info: u32,
		provider, decode: rawptr,
		interpolate: bool,
		intent: i32,
	) -> rawptr ---
}

foreign import render_capture_core_foundation "system:CoreFoundation.framework"
foreign render_capture_core_foundation {
	CFURLCreateFromFileSystemRepresentation :: proc "c" (
		allocator: rawptr,
		bytes: [^]u8,
		count: int,
		is_directory: bool,
	) -> rawptr ---
}

UI_Render_Trace_Command :: struct {
	order: int,
	kind: string,
	pipeline: string `json:"pipeline,omitempty"`,
	rect: UI_Diagnostic_Rect,
	color: [4]f64,
	text: string `json:"text,omitempty"`,
	vertex_count: int `json:"vertex_count,omitempty"`,
	texture: string `json:"texture,omitempty"`,
	mirrored: bool `json:"mirrored,omitempty"`,
	timestamp_seconds: f64 `json:"timestamp_seconds,omitempty"`,
}

UI_Render_Trace :: struct {
	schema_version: int,
	viewport_width: f64,
	viewport_height: f64,
	scale: f64,
	pixel_width: int,
	pixel_height: int,
	clear_color: [4]f64,
	workflow: string,
	mode: string,
	fullscreen: bool,
	overlay_revision: uint,
	overlay_hash: string,
	encoder_created: bool,
	command_buffer_status: string,
	command_buffer_error: string `json:"command_buffer_error,omitempty"`,
	timeline_progress: f64,
	commands: [dynamic]UI_Render_Trace_Command,
}

UI_Render_Trace_State :: struct {
	active: bool,
	allocator: runtime.Allocator,
	trace: UI_Render_Trace,
}

UI_Render_Capture_Request :: struct {
	schema_version: int,
	command: string,
	gpu_trace: bool,
}

UI_Render_Capture_Result :: struct {
	ok: bool,
	frame: string,
	overlay: string,
	trace: string,
	snapshot: string,
	gpu_trace: string `json:"gpu_trace,omitempty"`,
	error: string `json:"error,omitempty"`,
}

ui_render_trace_state: UI_Render_Trace_State

ui_render_trace_begin :: proc(
	allocator: runtime.Allocator,
	pixel_width, pixel_height: int,
) {
	commands := make([dynamic]UI_Render_Trace_Command, 0, 1024, allocator)
	ui_render_trace_state = {
		active = true,
		allocator = allocator,
		trace = {
			schema_version = 2,
			viewport_width = ui.width,
			viewport_height = ui.height,
			scale = ui.scale,
			pixel_width = pixel_width,
			pixel_height = pixel_height,
			workflow = strings.clone(
				cli_workflow_name(ui.workflow),
				allocator,
			),
			mode = strings.clone(
				ui.mode == .Play ? "play" : "create",
				allocator,
			),
			fullscreen = ui.playback_fullscreen_active,
			commands = commands,
		},
	}
}

ui_render_trace_end :: proc() {
	ui_render_trace_state = {}
}

ui_render_trace_record :: proc(
	kind: string,
	rect := UI_Rect{},
	color := [4]f64{},
	text := "",
	pipeline := "",
	vertex_count := 0,
	texture := "",
	mirrored := false,
	timestamp_seconds := 0.0,
) {
	if !ui_render_trace_state.active {return}
	trace := &ui_render_trace_state.trace
	append(&trace.commands, UI_Render_Trace_Command{
		order = len(trace.commands),
		kind = strings.clone(kind, ui_render_trace_state.allocator),
		pipeline = strings.clone(pipeline, ui_render_trace_state.allocator),
		rect = {x=rect.x, y=rect.y, w=rect.w, h=rect.h},
		color = color,
		text = strings.clone(text, ui_render_trace_state.allocator),
		vertex_count = vertex_count,
		texture = strings.clone(texture, ui_render_trace_state.allocator),
		mirrored = mirrored,
		timestamp_seconds = timestamp_seconds,
	})
}

ui_render_trace_set_clear :: proc(color: [4]f64) {
	if !ui_render_trace_state.active {return}
	ui_render_trace_state.trace.clear_color = color
	ui_render_trace_record(
		"clear",
		{0, 0, ui.width, ui.height},
		color,
		pipeline = "render-pass",
	)
}

ui_render_trace_record_solid_rect :: proc(
	rect: UI_Rect,
	color: [4]f32,
) {
	if !ui_render_trace_state.active {return}
	ui_render_trace_record(
		"solid-rect",
		rect,
		{f64(color[0]), f64(color[1]), f64(color[2]), f64(color[3])},
		pipeline = "solid",
		vertex_count = 6,
	)
}

ui_render_trace_record_overlay_rect :: proc(
	rect: UI_Rect,
	color: [4]f64,
) {
	if !ui_render_trace_state.active {return}
	ui_render_trace_record(
		"overlay-rect",
		rect,
		color,
		pipeline = "core-graphics",
	)
}

ui_render_trace_record_text :: proc(
	text: string,
	rect: UI_Rect,
	color: [4]f64,
) {
	if !ui_render_trace_state.active {return}
	ui_render_trace_record(
		"text",
		rect,
		color,
		text = text,
		pipeline = "core-text",
	)
}

ui_render_capture_read_texture :: proc(
	texture: Id,
	width, height: uint,
	allocator := context.allocator,
) -> ([]u8, bool) {
	if texture == nil || width == 0 || height == 0 {return nil, false}
	bytes_per_row := width*4
	bytes := make([]u8, int(bytes_per_row*height), allocator)
	msg_void_ptr_u_region_u(
		texture,
		sel_registerName("getBytes:bytesPerRow:fromRegion:mipmapLevel:"),
		raw_data(bytes),
		bytes_per_row,
		MTL_Region{{0, 0, 0}, {width, height, 1}},
		0,
	)
	return bytes, true
}

ui_render_capture_write_png :: proc(
	path: string,
	pixels: []u8,
	width, height: uint,
) -> bool {
	if len(pixels) != int(width*height*4) {return false}
	provider := CGDataProviderCreateWithData(
		nil,
		raw_data(pixels),
		uint(len(pixels)),
		nil,
	)
	if provider == nil {return false}
	defer CFRelease(provider)
	space := CGColorSpaceCreateDeviceRGB()
	if space == nil {return false}
	defer CGColorSpaceRelease(space)
	image := CGImageCreate(
		width,
		height,
		8,
		32,
		width*4,
		space,
		u32(0x2000|2),
		provider,
		nil,
		false,
		0,
	)
	if image == nil {return false}
	defer CFRelease(image)
	path_bytes := transmute([]u8)path
	url := CFURLCreateFromFileSystemRepresentation(
		nil,
		raw_data(path_bytes),
		len(path_bytes),
		false,
	)
	if url == nil {return false}
	defer CFRelease(url)
	png_type := CFStringCreateWithCString(nil, "public.png", 0x08000100)
	if png_type == nil {return false}
	defer CFRelease(png_type)
	destination := CGImageDestinationCreateWithURL(url, png_type, 1, nil)
	if destination == nil {return false}
	defer CFRelease(destination)
	CGImageDestinationAddImage(destination, image, nil)
	return CGImageDestinationFinalize(destination)
}

ui_render_capture_start_gpu_trace :: proc(
	path: string,
	required: bool,
) -> (Id, bool, string) {
	manager := msg_id(
		objc_getClass("MTLCaptureManager"),
		sel_registerName("sharedCaptureManager"),
	)
	if manager == nil ||
	   !msg_bool_uint(
			manager,
			sel_registerName("supportsDestination:"),
			2,
	   ) {
		if required {
			return nil, false, "Metal GPU trace documents are not supported"
		}
		return nil, false, ""
	}
	descriptor := msg_id(
		objc_getClass("MTLCaptureDescriptor"),
		sel_registerName("new"),
	)
	if descriptor == nil {
		if required {return nil, false, "Unable to allocate a Metal capture descriptor"}
		return nil, false, ""
	}
	defer msg_void(descriptor, sel_registerName("release"))
	msg_void_id(
		descriptor,
		sel_registerName("setCaptureObject:"),
		ui.queue,
	)
	msg_void_i(descriptor, sel_registerName("setDestination:"), 2)
	url := msg_id_id(
		objc_getClass("NSURL"),
		sel_registerName("fileURLWithPath:"),
		nsstring(path),
	)
	msg_void_id(descriptor, sel_registerName("setOutputURL:"), url)
	error: Id
	if !msg_bool_id_id(
		manager,
		sel_registerName("startCaptureWithDescriptor:error:"),
		descriptor,
		Id(&error),
	) {
		if required {return nil, false, "Metal could not start the GPU trace"}
		return nil, false, ""
	}
	return manager, true, ""
}

ui_render_capture_command_status_name :: proc(status: uint) -> string {
	switch status {
	case 0: return "not-enqueued"
	case 1: return "enqueued"
	case 2: return "committed"
	case 3: return "scheduled"
	case 4: return "completed"
	case 5: return "error"
	}
	return "unknown"
}

ui_render_capture_command_error :: proc(
	command_buffer: Id,
	allocator := context.allocator,
) -> string {
	error_object := msg_id(command_buffer, sel_registerName("error"))
	if error_object == nil {return ""}
	description := msg_id(
		error_object,
		sel_registerName("localizedDescription"),
	)
	text, ok := text_input_string(description)
	if !ok {return ""}
	return strings.clone(text, allocator)
}

ui_render_capture_into :: proc(
	path: string,
	gpu_trace: bool,
	require_gpu_trace: bool,
) -> string {
	if ui.device == nil || ui.queue == nil ||
	   ui.width <= 0 || ui.height <= 0 || ui.scale <= 0 {
		return "The Metal UI is not ready for capture"
	}
	os.make_directory(app_support_dir())
	os.make_directory(filepath.dir(path))
	os.make_directory(path)
	pixel_width := uint(max(1, ui.width*ui.scale))
	pixel_height := uint(max(1, ui.height*ui.scale))
	desc := msg_id_u_u_u_b(
		objc_getClass("MTLTextureDescriptor"),
		sel_registerName(
			"texture2DDescriptorWithPixelFormat:width:height:mipmapped:",
		),
		80,
		pixel_width,
		pixel_height,
		false,
	)
	msg_void_i(desc, sel_registerName("setStorageMode:"), 0)
	msg_void_i(desc, sel_registerName("setUsage:"), 5)
	target := msg_id_id(
		ui.device,
		sel_registerName("newTextureWithDescriptor:"),
		desc,
	)
	if target == nil {return "Unable to allocate the offscreen Metal target"}
	defer msg_void(target, sel_registerName("release"))

	trace_arena, arena_ok := growing_arena_create(2*1024*1024, 256*1024)
	if !arena_ok {return "Unable to allocate the render trace"}
	defer growing_arena_destroy(trace_arena)
	trace_allocator := mem_virtual.arena_allocator(trace_arena)
	ui_render_trace_begin(
		trace_allocator,
		int(pixel_width),
		int(pixel_height),
	)
	defer ui_render_trace_end()

	gpu_path := fmt.tprintf("%s/frame.gputrace", path)
	capture_manager: Id
	capture_started := false
	if gpu_trace {
		capture_error: string
		capture_manager, capture_started, capture_error =
			ui_render_capture_start_gpu_trace(gpu_path, require_gpu_trace)
		if len(capture_error) > 0 {return capture_error}
	}

	arena_reset(&memory.frame, &memory.frame_stats)
	frame_allocator := mem_virtual.arena_allocator(&memory.frame)
	command_buffer := msg_id(ui.queue, sel_registerName("commandBuffer"))
	if command_buffer == nil {
		if capture_started {
			msg_void(capture_manager, sel_registerName("stopCapture"))
		}
		return "Unable to allocate the Metal capture command buffer"
	}
	encoded := encode_frame_to_target(
		command_buffer,
		target,
		frame_allocator,
		true,
	)
	trace := &ui_render_trace_state.trace
	trace.encoder_created = encoded.encoder_created
	capture_failure := ""
	if encoded.encoder_created {
		msg_void(command_buffer, sel_registerName("commit"))
		msg_void(command_buffer, sel_registerName("waitUntilCompleted"))
		status := msg_uint(command_buffer, sel_registerName("status"))
		trace.command_buffer_status = strings.clone(
			ui_render_capture_command_status_name(status),
			trace_allocator,
		)
		if status != 4 {
			trace.command_buffer_error =
				ui_render_capture_command_error(
					command_buffer,
					trace_allocator,
				)
			if len(trace.command_buffer_error) > 0 {
				capture_failure = fmt.tprintf(
					"The Metal command buffer failed: %s",
					trace.command_buffer_error,
				)
			} else {
				capture_failure = fmt.tprintf(
					"The Metal command buffer ended with status %s",
					trace.command_buffer_status,
				)
			}
		}
	} else {
		trace.command_buffer_status = strings.clone(
			"not-committed",
			trace_allocator,
		)
		capture_failure =
			"The Metal render command encoder could not be created"
	}
	if capture_started {
		msg_void(capture_manager, sel_registerName("stopCapture"))
	}
	if !encoded.overlay_uploaded && len(capture_failure) == 0 {
		capture_failure = "The text overlay could not be uploaded"
	}

	frame_pixels, frame_read := ui_render_capture_read_texture(
		target,
		pixel_width,
		pixel_height,
		context.temp_allocator,
	)
	if !frame_read ||
	   !ui_render_capture_write_png(
			fmt.tprintf("%s/frame.png", path),
			frame_pixels,
			pixel_width,
			pixel_height,
	   ) {
		if len(capture_failure) == 0 {
			capture_failure = "Unable to write the offscreen frame PNG"
		}
	}
	overlay_pixels, overlay_read := ui_render_capture_read_texture(
		ui.text_texture,
		pixel_width,
		pixel_height,
		context.temp_allocator,
	)
	if !overlay_read ||
	   !ui_render_capture_write_png(
			fmt.tprintf("%s/overlay.png", path),
			overlay_pixels,
			pixel_width,
			pixel_height,
	   ) {
		if len(capture_failure) == 0 {
			capture_failure = "Unable to write the text overlay PNG"
		}
	}
	trace.overlay_revision = ui.overlay_revision
	if overlay_read {
		trace.overlay_hash = fmt.aprintf(
			"%016x",
			hash.fnv64a(overlay_pixels),
			allocator=trace_allocator,
		)
	}
	seconds, _ := current_seconds()
	if ui.player_duration > 0 {
		trace.timeline_progress =
			playback_timeline_progress(seconds, ui.player_duration)
	}
	if !ui_diagnostic_write_artifact(
		fmt.tprintf("%s/render-trace.json", path),
		trace^,
		context.temp_allocator,
	) {
		if len(capture_failure) == 0 {
			capture_failure = "Unable to write the render trace"
		}
	}
	snapshot, captured := ui_diagnostic_capture_current(
		context.temp_allocator,
	)
	if !captured ||
	   !ui_diagnostic_write_artifact(
			fmt.tprintf("%s/ui-snapshot.json", path),
			snapshot,
			context.temp_allocator,
	   ) {
		if len(capture_failure) == 0 {
			capture_failure = "Unable to write the UI snapshot"
		}
	}
	return capture_failure
}

ui_render_capture_bundle :: proc(gpu_trace: bool) -> (string, string) {
	path := ui_automation_bundle_path("capture")
	os.make_directory(filepath.dir(path))
	os.make_directory(path)
	capture_error := ui_render_capture_into(path, gpu_trace, gpu_trace)
	request := UI_Render_Capture_Request{
		schema_version = 1,
		command = "ui.capture",
		gpu_trace = gpu_trace,
	}
	result := UI_Render_Capture_Result{
		ok = len(capture_error) == 0,
		error = capture_error,
	}
	if os.exists(fmt.tprintf("%s/frame.png", path)) {
		result.frame = "frame.png"
	}
	if os.exists(fmt.tprintf("%s/overlay.png", path)) {
		result.overlay = "overlay.png"
	}
	if os.exists(fmt.tprintf("%s/render-trace.json", path)) {
		result.trace = "render-trace.json"
	}
	if os.exists(fmt.tprintf("%s/ui-snapshot.json", path)) {
		result.snapshot = "ui-snapshot.json"
	}
	if gpu_trace && os.exists(fmt.tprintf("%s/frame.gputrace", path)) {
		result.gpu_trace = "frame.gputrace"
	}
	_ = ui_diagnostic_write_artifact(
		fmt.tprintf("%s/scenario.json", path),
		request,
	)
	_ = ui_diagnostic_write_artifact(
		fmt.tprintf("%s/result.json", path),
		result,
	)
	ui_automation_prune_bundles()
	return path, capture_error
}
