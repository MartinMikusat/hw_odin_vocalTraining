package main

import "base:runtime"
import mem_virtual "core:mem/virtual"

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
Texture_Vertex :: struct {
	x, y, u, v: f32,
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

msg_void_ptr_u_u :: proc(receiver: Id, selector: Sel, data: rawptr, length, index: uint) {
	p := transmute(proc "c" (_: Id, _: Sel, _: rawptr, _: uint, _: uint))send_address
	p(receiver, selector, data, length, index)
}

msg_void_id_u :: proc(receiver: Id, selector: Sel, value: Id, index: uint) {
	p := transmute(proc "c" (_: Id, _: Sel, _: Id, _: uint))send_address
	p(receiver, selector, value, index)
}

msg_void_u_u_u :: proc(receiver: Id, selector: Sel, a, b, c: uint) {
	p := transmute(proc "c" (_: Id, _: Sel, _: uint, _: uint, _: uint))send_address
	p(receiver, selector, a, b, c)
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


encode_texture :: proc(
	encoder,
	texture: Id,
	rect: UI_Rect,
	alpha: f32,
	mirror_x := false,
) {
	if texture == nil {return}
	vertices := texture_rect_vertices(
		rect,
		[4]f32{1, 1, 1, alpha},
		mirror_x,
	)
	msg_void_id(encoder, sel_registerName("setRenderPipelineState:"), ui.texture_pipeline)
	msg_void_ptr_u_u(
		encoder,
		sel_registerName("setVertexBytes:length:atIndex:"),
		raw_data(vertices[:]),
		uint(len(vertices)) * size_of(Texture_Vertex),
		0,
	)
	msg_void_id_u(encoder, sel_registerName("setFragmentTexture:atIndex:"), texture, 0)
	msg_void_u_u_u(
		encoder,
		sel_registerName("drawPrimitives:vertexStart:vertexCount:"),
		3,
		0,
		uint(len(vertices)),
	)
}

encode_solid_vertices :: proc(encoder: Id, vertices: []Solid_Vertex) {
	// Metal limits setVertexBytes payloads to 4 KiB. Keep each batch aligned
	// to complete rectangles (six vertices) so no triangle crosses uploads.
	max_vertices := 168
	for start := 0; start < len(vertices); start += max_vertices {
		count := min(max_vertices, len(vertices) - start)
		batch := vertices[start:start + count]
		msg_void_ptr_u_u(
			encoder,
			sel_registerName("setVertexBytes:length:atIndex:"),
			raw_data(batch),
			uint(count) * size_of(Solid_Vertex),
			0,
		)
		msg_void_u_u_u(
			encoder,
			sel_registerName("drawPrimitives:vertexStart:vertexCount:"),
			3,
			0,
			uint(count),
		)
	}
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
	overlay_uploaded: bool,
	encoder_created:  bool,
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

	pixel_width := uint(max(1, ui.width * ui.scale))
	pixel_height := uint(max(1, ui.height * ui.scale))
	texture_resized := ensure_text_texture(pixel_width, pixel_height)
	redraw_requested := force_redraw || ui.needs_redraw || texture_resized
	build_ui_controls(redraw_requested, frame_allocator)
	overlay_uploaded := !redraw_requested
	if redraw_requested {
		arena_reset(&memory.redraw, &memory.redraw_stats)
		pixels := build_text_overlay(pixel_width, pixel_height)
		if pixels != nil {
			msg_void_region_u_ptr_u(
				ui.text_texture,
				sel_registerName("replaceRegion:mipmapLevel:withBytes:bytesPerRow:"),
				MTL_Region{MTL_Origin{0, 0, 0}, MTL_Size{pixel_width, pixel_height, 1}},
				0,
				raw_data(pixels),
				pixel_width * 4,
			)
			overlay_uploaded = true
			ui.overlay_revision += 1
		}
	}

	encoder := msg_id_id(
		command_buffer,
		sel_registerName("renderCommandEncoderWithDescriptor:"),
		pass,
	)
	if encoder == nil {
		return {overlay_uploaded=overlay_uploaded}
	}

	vertices, vertices_error := make([dynamic]Solid_Vertex, 0, 1024, frame_allocator)
	if vertices_error != nil {arena_note_failure(&memory.frame_stats)}
	if vertices_error == nil {build_geometry(&vertices)}
	msg_void_id(encoder, sel_registerName("setRenderPipelineState:"), ui.solid_pipeline)
	if vertices_error == nil {
		ui_render_trace_record(
			"draw",
			pipeline = "solid",
			vertex_count = len(vertices),
		)
		encode_solid_vertices(encoder, vertices[:])
	}

	_, _, _, _, player, _, _, _, _, _, _ := layout_rects()
	player_rect := player_content_rect(player)
	if ui.playback_fullscreen_active {
		player_rect = {0, 0, ui.width, ui.height}
	}
	video_texture, video_width, video_height, fresh_video_frame :=
		current_video_texture()
	if fresh_video_frame {complete_video_frame_refresh()}
	if video_texture != nil {
		draw_rect := aspect_fit_rect(
			player_rect,
			f64(video_width),
			f64(video_height),
		)
		mirrored :=
			ui.workflow == .Dancing &&
			!ui.source_playback_active &&
			ui.active_clip >= 0 &&
			ui.active_clip < len(state.clips) &&
			state.clips[ui.active_clip].dance_mirrored
		seconds, _ := current_seconds()
		ui_render_trace_record(
			"texture",
			draw_rect,
			pipeline = "texture",
			texture = "video",
			mirrored = mirrored,
			timestamp_seconds = seconds,
		)
		encode_texture(encoder, video_texture, draw_rect, 1, mirrored)
	}

	ui_render_trace_record(
		"texture",
		{0, 0, ui.width, ui.height},
		pipeline = "texture",
		texture = "overlay",
	)
	encode_texture(encoder, ui.text_texture, UI_Rect{0, 0, ui.width, ui.height}, 1)

	fullscreen_timeline_vertices, timeline_vertices_error :=
		make([dynamic]Solid_Vertex, 0, 12, frame_allocator)
	if timeline_vertices_error != nil {
		arena_note_failure(&memory.frame_stats)
	} else {
		build_playback_fullscreen_timeline_geometry(
			&fullscreen_timeline_vertices,
		)
		if len(fullscreen_timeline_vertices) > 0 {
			ui_render_trace_record(
				"draw",
				pipeline = "fullscreen-timeline",
				vertex_count = len(fullscreen_timeline_vertices),
			)
			msg_void_id(
				encoder,
				sel_registerName("setRenderPipelineState:"),
				ui.solid_pipeline,
			)
			encode_solid_vertices(
				encoder,
				fullscreen_timeline_vertices[:],
			)
		}
	}

	msg_void(encoder, sel_registerName("endEncoding"))
	return {
		overlay_uploaded = overlay_uploaded,
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
	memory.redraw_stats.high_water = max(memory.redraw_stats.high_water, memory.redraw.total_used)
	ui.needs_redraw = !encoded.overlay_uploaded
}


compile_pipelines :: proc() -> bool {
	source := `
#include <metal_stdlib>
using namespace metal;
struct SolidVertex { float x; float y; float r; float g; float b; float a; };
struct TextureVertex { float x; float y; float u; float v; float r; float g; float b; float a; };
struct SolidOut { float4 position [[position]]; float4 color; };
struct TextureOut { float4 position [[position]]; float2 uv; float4 color; };
vertex SolidOut solid_vertex(const device SolidVertex *v [[buffer(0)]], uint i [[vertex_id]]) {
	SolidOut o; o.position=float4(v[i].x,v[i].y,0,1); o.color=float4(v[i].r,v[i].g,v[i].b,v[i].a); return o;
}
fragment float4 solid_fragment(SolidOut in [[stage_in]]) { return in.color; }
vertex TextureOut texture_vertex(const device TextureVertex *v [[buffer(0)]], uint i [[vertex_id]]) {
	TextureOut o; o.position=float4(v[i].x,v[i].y,0,1); o.uv=float2(v[i].u,v[i].v); o.color=float4(v[i].r,v[i].g,v[i].b,v[i].a); return o;
}
fragment float4 texture_fragment(TextureOut in [[stage_in]], texture2d<float> image [[texture(0)]]) {
	constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
	return image.sample(s, in.uv) * in.color;
}`
	error: Id
	library := msg_id_id_error(
		ui.device,
		sel_registerName("newLibraryWithSource:options:error:"),
		nsstring(source),
		nil,
		&error,
	)
	if library == nil {return false}
	defer msg_void(library, sel_registerName("release"))
	solid_vertex := msg_id_id(
		library,
		sel_registerName("newFunctionWithName:"),
		nsstring("solid_vertex"),
	)
	solid_fragment := msg_id_id(
		library,
		sel_registerName("newFunctionWithName:"),
		nsstring("solid_fragment"),
	)
	texture_vertex := msg_id_id(
		library,
		sel_registerName("newFunctionWithName:"),
		nsstring("texture_vertex"),
	)
	texture_fragment := msg_id_id(
		library,
		sel_registerName("newFunctionWithName:"),
		nsstring("texture_fragment"),
	)
	defer msg_void(solid_vertex, sel_registerName("release"))
	defer msg_void(solid_fragment, sel_registerName("release"))
	defer msg_void(texture_vertex, sel_registerName("release"))
	defer msg_void(texture_fragment, sel_registerName("release"))

	desc := msg_id(objc_getClass("MTLRenderPipelineDescriptor"), sel_registerName("new"))
	defer msg_void(desc, sel_registerName("release"))
	msg_void_id(desc, sel_registerName("setVertexFunction:"), solid_vertex)
	msg_void_id(desc, sel_registerName("setFragmentFunction:"), solid_fragment)
	attachment := msg_id_uint(
		msg_id(desc, sel_registerName("colorAttachments")),
		sel_registerName("objectAtIndexedSubscript:"),
		0,
	)
	msg_void_i(attachment, sel_registerName("setPixelFormat:"), 80)
	ui.solid_pipeline = msg_id_id_error_2(
		ui.device,
		sel_registerName("newRenderPipelineStateWithDescriptor:error:"),
		desc,
		&error,
	)

	texture_desc := msg_id(objc_getClass("MTLRenderPipelineDescriptor"), sel_registerName("new"))
	defer msg_void(texture_desc, sel_registerName("release"))
	msg_void_id(texture_desc, sel_registerName("setVertexFunction:"), texture_vertex)
	msg_void_id(texture_desc, sel_registerName("setFragmentFunction:"), texture_fragment)
	texture_attachment := msg_id_uint(
		msg_id(texture_desc, sel_registerName("colorAttachments")),
		sel_registerName("objectAtIndexedSubscript:"),
		0,
	)
	msg_void_i(texture_attachment, sel_registerName("setPixelFormat:"), 80)
	msg_void_bool(texture_attachment, sel_registerName("setBlendingEnabled:"), true)
	msg_void_i(texture_attachment, sel_registerName("setSourceRGBBlendFactor:"), 1)
	msg_void_i(texture_attachment, sel_registerName("setDestinationRGBBlendFactor:"), 5)
	msg_void_i(texture_attachment, sel_registerName("setSourceAlphaBlendFactor:"), 1)
	msg_void_i(texture_attachment, sel_registerName("setDestinationAlphaBlendFactor:"), 5)
	ui.texture_pipeline = msg_id_id_error_2(
		ui.device,
		sel_registerName("newRenderPipelineStateWithDescriptor:error:"),
		texture_desc,
		&error,
	)
	return ui.solid_pipeline != nil && ui.texture_pipeline != nil
}
