package main

import "base:runtime"
import mem_virtual "core:mem/virtual"
import framework_metal "ui_framework:metal"

foreign import metal "system:Metal.framework"
foreign metal {
	MTLCreateSystemDefaultDevice :: proc "c" () -> Id ---
}


foreign import core_video "system:CoreVideo.framework"
foreign core_video {
	CVMetalTextureCacheCreate :: proc "c" (allocator, cache_attributes: rawptr, device: Id, texture_attributes: rawptr, cache: ^rawptr) -> i32 ---
	CVMetalTextureCacheCreateTextureFromImage :: proc "c" (allocator: rawptr, cache: rawptr, image, attributes: rawptr, pixel_format: uint, width, height, plane_index: uint, texture: ^rawptr) -> i32 ---
	CVMetalTextureGetTexture :: proc "c" (texture: rawptr) -> Id ---
	CVPixelBufferGetWidth :: proc "c" (buffer: rawptr) -> uint ---
	CVPixelBufferGetHeight :: proc "c" (buffer: rawptr) -> uint ---
}


Solid_Vertex :: struct {
	x, y:       f32,
	r, g, b, a: f32,
}
MTL_Clear_Color :: struct {
	red, green, blue, alpha: f64,
}
MTL_Origin :: struct {
	x, y, z: uint,
}
MTL_Size :: struct {
	width, height, depth: uint,
}
MTL_Region :: struct {
	origin: MTL_Origin,
	size:   MTL_Size,
}

msg_void_clear_color :: proc(receiver: Id, selector: Sel, color: MTL_Clear_Color) {
	p := transmute(proc "c" (_: Id, _: Sel, _: MTL_Clear_Color))send_address
	p(receiver, selector, color)
}

msg_id_u_u_u_b :: proc(
	receiver: Id,
	selector: Sel,
	pixel_format, width, height: uint,
	mipmapped: bool,
) -> Id {
	p := transmute(proc "c" (_: Id, _: Sel, _: uint, _: uint, _: uint, _: bool) -> Id)send_address
	return p(receiver, selector, pixel_format, width, height, mipmapped)
}

msg_void_region_u_ptr_u :: proc(
	receiver: Id,
	selector: Sel,
	region: MTL_Region,
	level: uint,
	bytes: rawptr,
	bytes_per_row: uint,
) {
	p := transmute(proc "c" (
		_: Id,
		_: Sel,
		_: MTL_Region,
		_: uint,
		_: rawptr,
		_: uint,
	))send_address
	p(receiver, selector, region, level, bytes, bytes_per_row)
}

msg_void_ptr_u_region_u :: proc(
	receiver: Id,
	selector: Sel,
	bytes: rawptr,
	bytes_per_row: uint,
	region: MTL_Region,
	level: uint,
) {
	p := transmute(proc "c" (
		_: Id,
		_: Sel,
		_: rawptr,
		_: uint,
		_: MTL_Region,
		_: uint,
	))send_address
	p(receiver, selector, bytes, bytes_per_row, region, level)
}


current_video_texture :: proc() -> (Id, uint, uint, bool) {
	if ui.video_output == nil || ui.texture_cache == nil {return nil, 0, 0, false}
	seconds, ok := current_seconds()
	if !ok {return nil, 0, 0, false}
	time := CMTime {
		value     = i64(seconds * 600),
		timescale = 600,
		flags     = 1,
	}
	if !msg_bool_time(ui.video_output, sel_registerName("hasNewPixelBufferForItemTime:"), time) {
		return ui.last_video_texture, ui.last_video_width, ui.last_video_height, false
	}
	display_time: CMTime
	buffer := msg_id_time_time(
		ui.video_output,
		sel_registerName("copyPixelBufferForItemTime:itemTimeForDisplay:"),
		time,
		&display_time,
	)
	if buffer == nil {
		return ui.last_video_texture, ui.last_video_width, ui.last_video_height, false
	}
	trace_foreign_lifetime("create", "CVPixelBuffer", buffer, "current_video_texture")
	defer foreign_release(buffer, "CVPixelBuffer", "current_video_texture")
	width := CVPixelBufferGetWidth(buffer)
	height := CVPixelBufferGetHeight(buffer)
	when ODIN_DEBUG {
		assert(width > 0 && height > 0, "CVPixelBuffer has invalid dimensions")
	}
	cv_texture: rawptr
	if CVMetalTextureCacheCreateTextureFromImage(
		   nil,
		   ui.texture_cache,
		   buffer,
		   nil,
		   80,
		   width,
		   height,
		   0,
		   &cv_texture,
	   ) !=
	   0 {
		return ui.last_video_texture, ui.last_video_width, ui.last_video_height, false
	}
	if cv_texture == nil {
		return ui.last_video_texture, ui.last_video_width, ui.last_video_height, false
	}
	trace_foreign_lifetime("create", "CVMetalTexture", cv_texture, "current_video_texture")
	defer foreign_release(cv_texture, "CVMetalTexture", "current_video_texture")
	texture := CVMetalTextureGetTexture(cv_texture)
	if texture == nil {
		return ui.last_video_texture, ui.last_video_width, ui.last_video_height, false
	}
	retained := msg_id(texture, sel_registerName("retain"))
	if ui.last_video_texture != nil {msg_void(ui.last_video_texture, sel_registerName("release"))}
	ui.last_video_texture = retained
	ui.last_video_width, ui.last_video_height = width, height
	return retained, width, height, true
}

Frame_Encode_Result :: struct {
	ordered_frame_ready: bool,
	encoder_created:  bool,
}

encode_ordered_stream_to_texture :: proc(
	command_buffer: Id,
	pixel_width, pixel_height: uint,
) -> Id {
	if command_buffer == nil || !ordered_ui_ready || pixel_width == 0 || pixel_height == 0 {
		return nil
	}
	descriptor := msg_id_u_u_u_b(
		objc_getClass("MTLTextureDescriptor"),
		sel_registerName("texture2DDescriptorWithPixelFormat:width:height:mipmapped:"),
		80,
		pixel_width,
		pixel_height,
		false,
	)
	msg_void_i(descriptor, sel_registerName("setUsage:"), 5)
	target := msg_id_id(ui.device, sel_registerName("newTextureWithDescriptor:"), descriptor)
	if target == nil {return nil}
	pass := msg_id(
		objc_getClass("MTLRenderPassDescriptor"),
		sel_registerName("renderPassDescriptor"),
	)
	attachments := msg_id(pass, sel_registerName("colorAttachments"))
	attachment := msg_id_uint(attachments, sel_registerName("objectAtIndexedSubscript:"), 0)
	msg_void_id(attachment, sel_registerName("setTexture:"), target)
	msg_void_i(attachment, sel_registerName("setLoadAction:"), 2)
	msg_void_i(attachment, sel_registerName("setStoreAction:"), 1)
	msg_void_clear_color(attachment, sel_registerName("setClearColor:"), {0, 0, 0, 0})
	encoder := msg_id_id(
		command_buffer,
		sel_registerName("renderCommandEncoderWithDescriptor:"),
		pass,
	)
	if encoder == nil {
		msg_void(target, sel_registerName("release"))
		return nil
	}
	encoded := framework_metal.encode(
		&ordered_renderer,
		rawptr(encoder),
		&ordered_draw,
		[2]f32{f32(ui.width), f32(ui.height)},
		f32(ui.scale),
	)
	msg_void(encoder, sel_registerName("endEncoding"))
	if !encoded {
		msg_void(target, sel_registerName("release"))
		return nil
	}
	return target
}

encode_frame_to_target :: proc(
	command_buffer, target: Id,
	frame_allocator: runtime.Allocator,
	force_redraw: bool,
) -> Frame_Encode_Result {
	if command_buffer == nil || target == nil {return {}}
	pass := msg_id(
		objc_getClass("MTLRenderPassDescriptor"),
		sel_registerName("renderPassDescriptor"),
	)
	attachments := msg_id(pass, sel_registerName("colorAttachments"))
	attachment := msg_id_uint(attachments, sel_registerName("objectAtIndexedSubscript:"), 0)
	msg_void_id(attachment, sel_registerName("setTexture:"), target)
	msg_void_i(attachment, sel_registerName("setLoadAction:"), 2)
	msg_void_i(attachment, sel_registerName("setStoreAction:"), 1)
	clear_color := ui_theme_colors().chassis
	if ui.playback_fullscreen_active {clear_color = {0, 0, 0, 1}}
	ui_render_trace_set_clear(clear_color)
	msg_void_clear_color(
		attachment,
		sel_registerName("setClearColor:"),
		MTL_Clear_Color{
			clear_color[0],
			clear_color[1],
			clear_color[2],
			1,
		},
	)

	redraw_requested := force_redraw || ui.needs_redraw || ui.overlay_revision == 0
	build_ui_controls(redraw_requested, frame_allocator)
	vertices, vertices_error := make([dynamic]Solid_Vertex, 0, 1024, frame_allocator)
	if vertices_error != nil {arena_note_failure(&memory.frame_stats)}
	fullscreen_timeline_vertices, timeline_vertices_error :=
		make([dynamic]Solid_Vertex, 0, 12, frame_allocator)
	if timeline_vertices_error != nil {
		arena_note_failure(&memory.frame_stats)
	}
	ordered_frame_ready := false
	if vertices_error == nil && timeline_vertices_error == nil {
		build_geometry(&vertices)
		build_playback_fullscreen_timeline_geometry(
			&fullscreen_timeline_vertices,
		)
		ordered_frame_ready = build_ordered_frame(
			vertices[:],
			fullscreen_timeline_vertices[:],
		)
	}

	encoder := msg_id_id(
		command_buffer,
		sel_registerName("renderCommandEncoderWithDescriptor:"),
		pass,
	)
	if encoder == nil {
		return {ordered_frame_ready=ordered_frame_ready}
	}

	ui_render_trace_record(
		"draw",
		{0, 0, ui.width, ui.height},
		pipeline = "ordered-ui",
		vertex_count = len(ordered_draw.trace)*6,
	)
	if ordered_frame_ready && !framework_metal.encode(
		&ordered_renderer,
		rawptr(encoder),
		&ordered_draw,
		[2]f32{f32(ui.width), f32(ui.height)},
		f32(ui.scale),
	) {
		ordered_frame_ready = false
	}

	msg_void(encoder, sel_registerName("endEncoding"))
	return {
		ordered_frame_ready = ordered_frame_ready,
		encoder_created = true,
	}
}

render_frame :: proc() {
	if ui.layer == nil || ui.width <= 0 || ui.height <= 0 {return}
	drawable := msg_id(ui.layer, sel_registerName("nextDrawable"))
	if drawable == nil {return}
	arena_reset(&memory.frame, &memory.frame_stats)
	frame_allocator := mem_virtual.arena_allocator(&memory.frame)
	texture := msg_id(drawable, sel_registerName("texture"))
	command_buffer := msg_id(ui.queue, sel_registerName("commandBuffer"))
	encoded := encode_frame_to_target(
		command_buffer,
		texture,
		frame_allocator,
		false,
	)
	if !encoded.encoder_created {
		ui.needs_redraw = true
		return
	}
	msg_void_id(command_buffer, sel_registerName("presentDrawable:"), drawable)
	msg_void(command_buffer, sel_registerName("commit"))
	ui.render_count += 1
	memory.frame_stats.high_water = max(memory.frame_stats.high_water, memory.frame.total_used)
	ui.needs_redraw = !encoded.ordered_frame_ready
}
