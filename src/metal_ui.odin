package main

import "core:fmt"
import "core:strings"
import "base:runtime"

foreign import metal "system:Metal.framework"
foreign metal {
	MTLCreateSystemDefaultDevice :: proc "c" () -> Id ---
}

foreign import core_graphics "system:CoreGraphics.framework"
foreign core_graphics {
	CGColorSpaceCreateDeviceRGB :: proc "c" () -> rawptr ---
	CGColorSpaceRelease         :: proc "c" (space: rawptr) ---
	CGBitmapContextCreate       :: proc "c" (data: rawptr, width, height, bits_per_component, bytes_per_row: uint, space: rawptr, bitmap_info: u32) -> rawptr ---
	CGContextRelease            :: proc "c" (ctx: rawptr) ---
	CGContextClearRect          :: proc "c" (ctx: rawptr, rect: Rect) ---
	CGContextSetRGBFillColor    :: proc "c" (ctx: rawptr, red, green, blue, alpha: f64) ---
	CGContextSaveGState         :: proc "c" (ctx: rawptr) ---
	CGContextRestoreGState      :: proc "c" (ctx: rawptr) ---
	CGContextClipToRect         :: proc "c" (ctx: rawptr, rect: Rect) ---
	CGContextSetTextPosition    :: proc "c" (ctx: rawptr, x, y: f64) ---
}

foreign import core_text "system:CoreText.framework"
foreign core_text {
	CTFontCreateWithName              :: proc "c" (name: rawptr, size: f64, transform: rawptr) -> rawptr ---
	CTLineCreateWithAttributedString  :: proc "c" (string: rawptr) -> rawptr ---
	CTLineCreateTruncatedLine         :: proc "c" (line: rawptr, width: f64, truncation_type: u32, token: rawptr) -> rawptr ---
	CTLineGetTypographicBounds        :: proc "c" (line: rawptr, ascent, descent, leading: ^f64) -> f64 ---
	CTLineGetGlyphRuns                :: proc "c" (line: rawptr) -> rawptr ---
	CTLineDraw                        :: proc "c" (line, ctx: rawptr) ---
	CTRunGetGlyphCount                :: proc "c" (run: rawptr) -> int ---
	kCTFontAttributeName: rawptr
	kCTForegroundColorFromContextAttributeName: rawptr
	kCTLigatureAttributeName: rawptr
}

foreign import core_foundation "system:CoreFoundation.framework"
foreign core_foundation {
	CFStringCreateWithCString           :: proc "c" (allocator: rawptr, text: cstring, encoding: u32) -> rawptr ---
	CFStringCreateWithBytes             :: proc "c" (allocator: rawptr, bytes: [^]u8, count: int, encoding: u32, external: bool) -> rawptr ---
	CFStringGetLength                   :: proc "c" (string: rawptr) -> int ---
	CFAttributedStringCreateMutable     :: proc "c" (allocator: rawptr, max_length: int) -> rawptr ---
	CFAttributedStringReplaceString     :: proc "c" (string: rawptr, range: CF_Range, replacement: rawptr) ---
	CFAttributedStringSetAttribute      :: proc "c" (string: rawptr, range: CF_Range, name, value: rawptr) ---
	CFArrayGetCount                     :: proc "c" (array: rawptr) -> int ---
	CFArrayGetValueAtIndex              :: proc "c" (array: rawptr, index: int) -> rawptr ---
	CFNumberCreate                      :: proc "c" (allocator: rawptr, number_type: int, value: rawptr) -> rawptr ---
	CFRetain                            :: proc "c" (value: rawptr) -> rawptr ---
	CFRelease                           :: proc "c" (value: rawptr) ---
	kCFBooleanTrue: rawptr
}

foreign import core_video "system:CoreVideo.framework"
foreign core_video {
	CVMetalTextureCacheCreate                 :: proc "c" (allocator, cache_attributes: rawptr, device: Id, texture_attributes: rawptr, cache: ^rawptr) -> i32 ---
	CVMetalTextureCacheCreateTextureFromImage :: proc "c" (allocator: rawptr, cache: rawptr, image, attributes: rawptr, pixel_format: uint, width, height, plane_index: uint, texture: ^rawptr) -> i32 ---
	CVMetalTextureGetTexture                  :: proc "c" (texture: rawptr) -> Id ---
	CVPixelBufferGetWidth                     :: proc "c" (buffer: rawptr) -> uint ---
	CVPixelBufferGetHeight                    :: proc "c" (buffer: rawptr) -> uint ---
}

UI_Focus :: enum {
	None,
	URL,
	Source_Search,
	Exercise_Search,
	Exercise_Name,
}

UI_State :: struct {
	view: Id,
	layer: Id,
	device: Id,
	queue: Id,
	solid_pipeline: Id,
	texture_pipeline: Id,
	text_texture: Id,
	text_width: uint,
	text_height: uint,
	texture_cache: rawptr,
	video_output: Id,
	last_video_texture: Id,
	last_video_width: uint,
	last_video_height: uint,
	ax_children: Id,
	width: f64,
	height: f64,
	scale: f64,
	mouse: Point,
	focus: UI_Focus,
	url_input: string,
	source_search: string,
	exercise_search: string,
	exercise_name: string,
	status: string,
	source_scroll: f64,
	transcript_scroll: f64,
	exercise_scroll: f64,
	marked_text: string,
	has_marked_text: bool,
	needs_redraw: bool,
}

UI_Rect :: struct { x, y, w, h: f64 }
Solid_Vertex :: struct { x, y: f32, r, g, b, a: f32 }
Texture_Vertex :: struct { x, y, u, v: f32, r, g, b, a: f32 }
MTL_Clear_Color :: struct { red, green, blue, alpha: f64 }
MTL_Origin :: struct { x, y, z: uint }
MTL_Size :: struct { width, height, depth: uint }
MTL_Region :: struct { origin: MTL_Origin, size: MTL_Size }
NS_Range :: struct { location, length: uint }
CF_Range :: struct { location, length: int }

SMALL_FONT_SIZE :: 10.5
TITLE_FONT_SIZE :: SMALL_FONT_SIZE*2

Text_Align :: enum {
	Start,
	Center,
	End,
}

Text_Run :: struct {
	line: rawptr,
	advance: f64,
	ascent: f64,
	descent: f64,
	leading: f64,
}

AX_Kind :: enum {
	URL,
	Import,
	Source_Search,
	Source,
	Transcript,
	Exercise_Search,
	Exercise,
	Exercise_Name,
	Start,
	End,
	Save,
	Play,
	Pause,
	Captions,
	Preview,
	Data,
}

AX_Action :: struct {
	element: Id,
	kind: AX_Kind,
	index: int,
	seconds: f64,
}

ui: UI_State
ui_event_tag: int
ax_actions: [dynamic]AX_Action

CONTROL_URL          :: Id(rawptr(uintptr(1)))
CONTROL_STATUS       :: Id(rawptr(uintptr(2)))
CONTROL_SOURCE       :: Id(rawptr(uintptr(3)))
CONTROL_EXERCISE     :: Id(rawptr(uintptr(4)))
CONTROL_EXERCISE_NAME:: Id(rawptr(uintptr(5)))

msg_bool :: proc(receiver: Id, selector: Sel) -> bool {
	p := transmute(proc "c" (Id, Sel) -> bool)send_address
	return p(receiver, selector)
}

msg_void_bool :: proc(receiver: Id, selector: Sel, value: bool) {
	p := transmute(proc "c" (Id, Sel, bool))send_address
	p(receiver, selector, value)
}

msg_void_f64 :: proc(receiver: Id, selector: Sel, value: f64) {
	p := transmute(proc "c" (Id, Sel, f64))send_address
	p(receiver, selector, value)
}

msg_point :: proc(receiver: Id, selector: Sel) -> Point {
	p := transmute(proc "c" (Id, Sel) -> Point)send_address
	return p(receiver, selector)
}

msg_point_point_id :: proc(receiver: Id, selector: Sel, point: Point, view: Id) -> Point {
	p := transmute(proc "c" (Id, Sel, Point, Id) -> Point)send_address
	return p(receiver, selector, point, view)
}

msg_size :: proc(receiver: Id, selector: Sel) -> Size {
	p := transmute(proc "c" (Id, Sel) -> Size)send_address
	return p(receiver, selector)
}

msg_void_size :: proc(receiver: Id, selector: Sel, value: Size) {
	p := transmute(proc "c" (Id, Sel, Size))send_address
	p(receiver, selector, value)
}

msg_id_id_error :: proc(receiver: Id, selector: Sel, value, options: Id, error: ^Id) -> Id {
	p := transmute(proc "c" (Id, Sel, Id, Id, ^Id) -> Id)send_address
	return p(receiver, selector, value, options, error)
}

msg_id_id_error_2 :: proc(receiver: Id, selector: Sel, value: Id, error: ^Id) -> Id {
	p := transmute(proc "c" (Id, Sel, Id, ^Id) -> Id)send_address
	return p(receiver, selector, value, error)
}

msg_void_ptr_u_u :: proc(receiver: Id, selector: Sel, data: rawptr, length, index: uint) {
	p := transmute(proc "c" (Id, Sel, rawptr, uint, uint))send_address
	p(receiver, selector, data, length, index)
}

msg_void_id_u :: proc(receiver: Id, selector: Sel, value: Id, index: uint) {
	p := transmute(proc "c" (Id, Sel, Id, uint))send_address
	p(receiver, selector, value, index)
}

msg_void_u_u_u :: proc(receiver: Id, selector: Sel, a, b, c: uint) {
	p := transmute(proc "c" (Id, Sel, uint, uint, uint))send_address
	p(receiver, selector, a, b, c)
}

msg_void_clear_color :: proc(receiver: Id, selector: Sel, color: MTL_Clear_Color) {
	p := transmute(proc "c" (Id, Sel, MTL_Clear_Color))send_address
	p(receiver, selector, color)
}

msg_id_u_u_u_b :: proc(receiver: Id, selector: Sel, pixel_format, width, height: uint, mipmapped: bool) -> Id {
	p := transmute(proc "c" (Id, Sel, uint, uint, uint, bool) -> Id)send_address
	return p(receiver, selector, pixel_format, width, height, mipmapped)
}

msg_void_region_u_ptr_u :: proc(receiver: Id, selector: Sel, region: MTL_Region, level: uint, bytes: rawptr, bytes_per_row: uint) {
	p := transmute(proc "c" (Id, Sel, MTL_Region, uint, rawptr, uint))send_address
	p(receiver, selector, region, level, bytes, bytes_per_row)
}

msg_id_rect_id :: proc(receiver: Id, selector: Sel, rect: Rect, view: Id) -> Id {
	p := transmute(proc "c" (Id, Sel, Rect, Id) -> Id)send_address
	return p(receiver, selector, rect, view)
}

msg_rect_rect :: proc(receiver: Id, selector: Sel, rect: Rect) -> Rect {
	p := transmute(proc "c" (Id, Sel, Rect) -> Rect)send_address
	return p(receiver, selector, rect)
}

msg_rect_rect_id :: proc(receiver: Id, selector: Sel, rect: Rect, view: Id) -> Rect {
	p := transmute(proc "c" (Id, Sel, Rect, Id) -> Rect)send_address
	return p(receiver, selector, rect, view)
}

msg_time_f64 :: proc(receiver: Id, selector: Sel, value: f64) -> CMTime {
	p := transmute(proc "c" (Id, Sel, f64) -> CMTime)send_address
	return p(receiver, selector, value)
}

msg_bool_time :: proc(receiver: Id, selector: Sel, value: CMTime) -> bool {
	p := transmute(proc "c" (Id, Sel, CMTime) -> bool)send_address
	return p(receiver, selector, value)
}

msg_id_time_time :: proc(receiver: Id, selector: Sel, value: CMTime, display_time: ^CMTime) -> Id {
	p := transmute(proc "c" (Id, Sel, CMTime, ^CMTime) -> Id)send_address
	return p(receiver, selector, value, display_time)
}

ui_set_string :: proc(target: ^string, value: string) {
	replacement := strings.clone(value)
	if len(target^) > 0 { delete(target^) }
	target^ = replacement
}

append_text :: proc(target: ^string, value: string) {
	updated := fmt.tprintf("%s%s", target^, value)
	ui_set_string(target, updated)
}

remove_last_character :: proc(target: ^string) {
	if len(target^) == 0 { return }
	index := len(target^)-1
	for index > 0 && (target^[index] & 0xc0) == 0x80 { index -= 1 }
	ui_set_string(target, target^[:index])
}

focused_text :: proc() -> ^string {
	#partial switch ui.focus {
	case .URL:             return &ui.url_input
	case .Source_Search:   return &ui.source_search
	case .Exercise_Search: return &ui.exercise_search
	case .Exercise_Name:   return &ui.exercise_name
	}
	return nil
}

contains :: proc(rect: UI_Rect, point: Point) -> bool {
	return point.x >= rect.x && point.x <= rect.x+rect.w && point.y >= rect.y && point.y <= rect.y+rect.h
}

layout_rects :: proc() -> (
	import_field, import_button, source_search, source_panel, player, transcript, exercise_search, exercise_panel, exercise_name, controls: UI_Rect,
) {
	w, h := ui.width, ui.height
	margin := 18.0
	gap := 10.0
	header_h := 46.0
	command_h := 42.0
	footer_h := 74.0
	import_button_w := 142.0
	import_field = UI_Rect{margin, h-margin-header_h-command_h-8, w-margin*2-import_button_w-8, command_h}
	import_button = UI_Rect{import_field.x+import_field.w+8, import_field.y, import_button_w, command_h}

	body_y := margin+footer_h
	body_top := import_field.y-12
	body_h := max(120, body_top-body_y)
	left_w := min(max(w*0.218, 250), 328)
	right_w := min(max(w*0.205, 238), 304)
	center_x := margin+left_w+gap
	center_w := max(280, w-margin*2-left_w-right_w-gap*2)
	right_x := center_x+center_w+gap

	source_search = UI_Rect{margin+8, body_top-72, left_w-16, 28}
	source_panel = UI_Rect{margin, body_y, left_w, body_h}
	exercise_search = UI_Rect{right_x+8, body_top-72, right_w-16, 28}
	exercise_name = UI_Rect{right_x+8, body_y+8, right_w-16, 30}
	exercise_panel = UI_Rect{right_x, body_y, right_w, body_h}

	player_h := max(180, body_h*0.55)
	player = UI_Rect{center_x, body_top-player_h, center_w, player_h}
	transcript = UI_Rect{center_x, body_y, center_w, max(80, body_h-player_h-gap)}
	controls = UI_Rect{margin, 42, w-margin*2, 28}
	return
}

control_rect :: proc(controls: UI_Rect, index: int) -> UI_Rect {
	gap := 6.0
	cell_w := (controls.w-gap*7)/8
	return UI_Rect{controls.x+f64(index)*(cell_w+gap), controls.y, cell_w, controls.h}
}

source_content_rect :: proc(source_search, source_panel: UI_Rect) -> UI_Rect {
	top := source_search.y-8
	return UI_Rect{source_panel.x+6, source_panel.y+8, source_panel.w-12, max(0, top-source_panel.y-8)}
}

transcript_content_rect :: proc(transcript: UI_Rect) -> UI_Rect {
	return UI_Rect{transcript.x+6, transcript.y+8, transcript.w-12, max(0, transcript.h-50)}
}

player_content_rect :: proc(player: UI_Rect) -> UI_Rect {
	bottom_metadata_height := 30.0
	header_height := 35.0
	return UI_Rect{
		player.x+1,
		player.y+bottom_metadata_height,
		max(0, player.w-2),
		max(0, player.h-bottom_metadata_height-header_height-1),
	}
}

exercise_content_rect :: proc(exercise_search, exercise_panel, exercise_name: UI_Rect) -> UI_Rect {
	bottom := exercise_name.y+exercise_name.h+8
	top := exercise_search.y-8
	return UI_Rect{exercise_panel.x+6, bottom, exercise_panel.w-12, max(0, top-bottom)}
}

bounded_scroll :: proc(current, delta: f64, item_count: int, row_height, row_step, viewport_height: f64) -> f64 {
	content_height := 0.0
	if item_count > 0 {
		content_height = row_height+f64(item_count-1)*row_step
	}
	maximum := max(0, content_height-viewport_height)
	return min(max(current-delta, 0), maximum)
}

filtered_source_count :: proc() -> int {
	count := 0
	for source in state.sources {
		if len(ui.source_search) > 0 && !strings.contains(source.title, ui.source_search) && !strings.contains(source.video_id, ui.source_search) { continue }
		count += 1
	}
	return count
}

active_segment_count :: proc() -> int {
	if state.active_source < 0 { return 0 }
	count := 0
	source_id := state.sources[state.active_source].id
	for segment in state.segments {
		if segment.source_id == source_id { count += 1 }
	}
	return count
}

filtered_exercise_count :: proc() -> int {
	count := 0
	for exercise in state.exercises {
		if len(ui.exercise_search) > 0 && !strings.contains(exercise.name, ui.exercise_search) { continue }
		count += 1
	}
	return count
}

normalize_scroll_offsets :: proc() {
	_, _, source_search, source_panel, _, transcript, exercise_search, exercise_panel, exercise_name, _ := layout_rects()
	source_content := source_content_rect(source_search, source_panel)
	transcript_content := transcript_content_rect(transcript)
	exercise_content := exercise_content_rect(exercise_search, exercise_panel, exercise_name)
	ui.source_scroll = bounded_scroll(ui.source_scroll, 0, filtered_source_count(), 29, 30, source_content.h)
	ui.transcript_scroll = bounded_scroll(ui.transcript_scroll, 0, active_segment_count(), 25, 26, transcript_content.h)
	ui.exercise_scroll = bounded_scroll(ui.exercise_scroll, 0, filtered_exercise_count(), 29, 30, exercise_content.h)
}

push_rect :: proc(vertices: ^[dynamic]Solid_Vertex, rect: UI_Rect, color: [4]f32) {
	if rect.w <= 0 || rect.h <= 0 || ui.width <= 0 || ui.height <= 0 { return }
	x0 := f32(rect.x/ui.width*2-1)
	x1 := f32((rect.x+rect.w)/ui.width*2-1)
	y0 := f32(rect.y/ui.height*2-1)
	y1 := f32((rect.y+rect.h)/ui.height*2-1)
	v0 := Solid_Vertex{x0,y0,color[0],color[1],color[2],color[3]}
	v1 := Solid_Vertex{x1,y0,color[0],color[1],color[2],color[3]}
	v2 := Solid_Vertex{x1,y1,color[0],color[1],color[2],color[3]}
	v3 := Solid_Vertex{x0,y1,color[0],color[1],color[2],color[3]}
	append(vertices, v0, v1, v2, v0, v2, v3)
}

push_border :: proc(vertices: ^[dynamic]Solid_Vertex, rect: UI_Rect, color: [4]f32) {
	push_rect(vertices, UI_Rect{rect.x, rect.y, rect.w, 1}, color)
	push_rect(vertices, UI_Rect{rect.x, rect.y+rect.h-1, rect.w, 1}, color)
	push_rect(vertices, UI_Rect{rect.x, rect.y, 1, rect.h}, color)
	push_rect(vertices, UI_Rect{rect.x+rect.w-1, rect.y, 1, rect.h}, color)
}

// Draws a box whose heading occupies a gap in the top border. Keep the text
// origin and the border gap paired through heading_x and heading_width.
push_border_with_heading_gap :: proc(vertices: ^[dynamic]Solid_Vertex, rect: UI_Rect, heading_x, heading_width: f64, color: [4]f32) {
	top := rect.y+rect.h-1
	left_width := max(0, heading_x-rect.x-8)
	right_x := heading_x+heading_width+8
	push_rect(vertices, UI_Rect{rect.x, rect.y, rect.w, 1}, color)
	push_rect(vertices, UI_Rect{rect.x, rect.y, 1, rect.h}, color)
	push_rect(vertices, UI_Rect{rect.x+rect.w-1, rect.y, 1, rect.h}, color)
	push_rect(vertices, UI_Rect{rect.x, top, left_width, 1}, color)
	push_rect(vertices, UI_Rect{right_x, top, max(0, rect.x+rect.w-right_x), 1}, color)
}

push_texture_rect :: proc(vertices: ^[dynamic]Texture_Vertex, rect: UI_Rect, color: [4]f32) {
	x0 := f32(rect.x/ui.width*2-1)
	x1 := f32((rect.x+rect.w)/ui.width*2-1)
	y0 := f32(rect.y/ui.height*2-1)
	y1 := f32((rect.y+rect.h)/ui.height*2-1)
	v0 := Texture_Vertex{x0,y0,0,1,color[0],color[1],color[2],color[3]}
	v1 := Texture_Vertex{x1,y0,1,1,color[0],color[1],color[2],color[3]}
	v2 := Texture_Vertex{x1,y1,1,0,color[0],color[1],color[2],color[3]}
	v3 := Texture_Vertex{x0,y1,0,0,color[0],color[1],color[2],color[3]}
	append(vertices, v0, v1, v2, v0, v2, v3)
}

make_text_run :: proc(font: rawptr, text: string) -> Text_Run {
	run: Text_Run
	if len(text) == 0 { return run }
	bytes := transmute([]u8)text
	string_ref := CFStringCreateWithBytes(nil, raw_data(bytes), len(bytes), 0x08000100, false)
	if string_ref == nil { return run }
	defer CFRelease(string_ref)
	attributed := CFAttributedStringCreateMutable(nil, 0)
	if attributed == nil { return run }
	defer CFRelease(attributed)
	CFAttributedStringReplaceString(attributed, CF_Range{0,0}, string_ref)
	range := CF_Range{0,CFStringGetLength(string_ref)}
	CFAttributedStringSetAttribute(attributed, range, kCTFontAttributeName, font)
	CFAttributedStringSetAttribute(attributed, range, kCTForegroundColorFromContextAttributeName, kCFBooleanTrue)
	standard_ligatures := i32(1)
	ligature_value := CFNumberCreate(nil, 9, &standard_ligatures)
	if ligature_value != nil {
		CFAttributedStringSetAttribute(attributed, range, kCTLigatureAttributeName, ligature_value)
		CFRelease(ligature_value)
	}
	run.line = CTLineCreateWithAttributedString(attributed)
	if run.line != nil {
		run.advance = CTLineGetTypographicBounds(run.line, &run.ascent, &run.descent, &run.leading)
	}
	return run
}

delete_text_run :: proc(run: ^Text_Run) {
	if run.line != nil { CFRelease(run.line) }
	run^ = {}
}

truncated_text_run :: proc(run: Text_Run, font: rawptr, max_width: f64) -> Text_Run {
	if run.line == nil { return {} }
	if run.advance <= max_width {
		result := run
		result.line = CFRetain(run.line)
		return result
	}
	token := make_text_run(font, "…")
	defer delete_text_run(&token)
	if token.line == nil || token.advance > max_width { return {} }
	truncated: Text_Run
	truncated.line = CTLineCreateTruncatedLine(run.line, max_width, 1, token.line)
	if truncated.line != nil {
		truncated.advance = CTLineGetTypographicBounds(truncated.line, &truncated.ascent, &truncated.descent, &truncated.leading)
	}
	return truncated
}

text_run_glyph_count :: proc(run: Text_Run) -> int {
	if run.line == nil { return 0 }
	runs := CTLineGetGlyphRuns(run.line)
	if runs == nil { return 0 }
	count := 0
	for index in 0..<CFArrayGetCount(runs) {
		count += CTRunGetGlyphCount(CFArrayGetValueAtIndex(runs, index))
	}
	return count
}

text_origin :: proc(rect: UI_Rect, run: Text_Run, horizontal, vertical: Text_Align, inset: f64 = 0) -> Point {
	scaled := UI_Rect{rect.x*ui.scale, rect.y*ui.scale, rect.w*ui.scale, rect.h*ui.scale}
	padding := inset*ui.scale
	x := scaled.x+padding
	#partial switch horizontal {
	case .Center: x = scaled.x+(scaled.w-run.advance)/2
	case .End:    x = scaled.x+scaled.w-padding-run.advance
	}
	baseline := scaled.y+padding+run.descent
	#partial switch vertical {
	case .Center: baseline = scaled.y+(scaled.h-(run.ascent+run.descent))/2+run.descent
	case .End:    baseline = scaled.y+scaled.h-padding-run.ascent
	}
	return Point{x, baseline}
}

draw_text_run :: proc(ctx: rawptr, run: Text_Run, origin: Point, color: [4]f64) {
	if ctx == nil || run.line == nil { return }
	CGContextSetRGBFillColor(ctx, color[0], color[1], color[2], color[3])
	CGContextSetTextPosition(ctx, origin.x, origin.y)
	CTLineDraw(run.line, ctx)
}

draw_text_in_rect :: proc(
	ctx, font: rawptr,
	text: string,
	rect: UI_Rect,
	horizontal, vertical: Text_Align,
	color: [4]f64,
	inset: f64 = 0,
	clip := true,
) {
	if ctx == nil || rect.w <= 0 || rect.h <= 0 || len(text) == 0 { return }
	run := make_text_run(font, text)
	defer delete_text_run(&run)
	available_width := max(0, (rect.w-inset*2)*ui.scale)
	draw_run := run
	truncated: Text_Run
	if run.advance > available_width {
		truncated = truncated_text_run(run, font, available_width)
		if truncated.line == nil { return }
		draw_run = truncated
	}
	if clip {
		CGContextSaveGState(ctx)
		CGContextClipToRect(ctx, Rect{Point{rect.x*ui.scale,rect.y*ui.scale},Size{rect.w*ui.scale,rect.h*ui.scale}})
	}
	draw_text_run(ctx, draw_run, text_origin(rect, draw_run, horizontal, vertical, inset), color)
	if clip { CGContextRestoreGState(ctx) }
	delete_text_run(&truncated)
}

build_geometry :: proc(vertices: ^[dynamic]Solid_Vertex) {
	import_field, import_button, source_search, source_panel, player, transcript, exercise_search, exercise_panel, exercise_name, controls := layout_rects()
	chassis := [4]f32{0.026,0.028,0.027,1}
	panel := [4]f32{0.041,0.044,0.042,1}
	panel_alt := [4]f32{0.052,0.055,0.052,1}
	field := [4]f32{0.020,0.022,0.021,1}
	border := [4]f32{0.218,0.225,0.210,1}
	rule := [4]f32{0.125,0.132,0.123,1}
	orange := [4]f32{0.91,0.31,0.075,1}
	push_rect(vertices, UI_Rect{0,0,ui.width,ui.height}, chassis)
	push_rect(vertices, UI_Rect{0,ui.height-64,ui.width,64}, [4]f32{0.018,0.020,0.019,1})
	push_rect(vertices, UI_Rect{0,ui.height-65,ui.width,1}, border)
	panels := [4]UI_Rect{source_panel, player, transcript, exercise_panel}
	for rect in panels {
		push_rect(vertices, rect, panel)
		push_border(vertices, rect, border)
		push_rect(vertices, UI_Rect{rect.x,rect.y+rect.h-34,rect.w,34}, panel_alt)
		push_rect(vertices, UI_Rect{rect.x,rect.y+rect.h-35,rect.w,1}, border)
	}
	fields := [3]UI_Rect{source_search, exercise_search, exercise_name}
	for rect in fields {
		push_rect(vertices, rect, field)
		push_border(vertices, rect, border)
	}
	push_rect(vertices, import_field, field)
	push_border_with_heading_gap(vertices, import_field, import_field.x+20, 138, border)
	import_color := orange
	if contains(import_button, ui.mouse) { import_color = [4]f32{1.0,0.42,0.10,1} }
	push_rect(vertices, import_button, import_color)
	push_border(vertices, import_button, [4]f32{1.0,0.45,0.12,1})

	source_content := source_content_rect(source_search, source_panel)
	row := UI_Rect{source_content.x, source_content.y+source_content.h-29+ui.source_scroll, source_content.w, 29}
	for source, index in state.sources {
		if len(ui.source_search) > 0 && !strings.contains(source.title, ui.source_search) && !strings.contains(source.video_id, ui.source_search) { continue }
		if row.y >= source_content.y && row.y+row.h <= source_content.y+source_content.h {
			color := [4]f32{0.046,0.050,0.048,0.96}
			if contains(row, ui.mouse) { color = [4]f32{0.075,0.081,0.076,1} }
			if index == state.active_source {
				color = [4]f32{0.17,0.070,0.035,1}
				push_rect(vertices, UI_Rect{row.x,row.y,3,row.h}, orange)
			}
			push_rect(vertices, row, color)
			push_rect(vertices, UI_Rect{row.x,row.y,row.w,1}, rule)
		}
		row.y -= 30
	}

	transcript_content := transcript_content_rect(transcript)
	row = UI_Rect{transcript_content.x, transcript_content.y+transcript_content.h-25+ui.transcript_scroll, transcript_content.w, 25}
	if state.active_source >= 0 {
		source_id := state.sources[state.active_source].id
		for segment in state.segments {
			if segment.source_id != source_id { continue }
			if row.y >= transcript_content.y && row.y+row.h <= transcript_content.y+transcript_content.h {
				color := [4]f32{0.043,0.047,0.045,0.96}
				if contains(row, ui.mouse) { color = [4]f32{0.071,0.078,0.073,1} }
				push_rect(vertices, row, color)
				push_rect(vertices, UI_Rect{row.x,row.y,row.w,1}, rule)
			}
			row.y -= 26
		}
	}

	exercise_content := exercise_content_rect(exercise_search, exercise_panel, exercise_name)
	row = UI_Rect{exercise_content.x, exercise_content.y+exercise_content.h-29+ui.exercise_scroll, exercise_content.w, 29}
	for exercise in state.exercises {
		if len(ui.exercise_search) > 0 && !strings.contains(exercise.name, ui.exercise_search) { continue }
		if row.y >= exercise_content.y && row.y+row.h <= exercise_content.y+exercise_content.h {
			color := [4]f32{0.046,0.050,0.048,0.96}
			if contains(row, ui.mouse) { color = [4]f32{0.075,0.081,0.076,1} }
			push_rect(vertices, row, color)
			push_rect(vertices, UI_Rect{row.x,row.y,row.w,1}, rule)
		}
		row.y -= 30
	}

	for index in 0..<8 {
		rect := control_rect(controls, index)
		color := panel_alt
		if index == 0 && state.has_start { color = [4]f32{0.035,0.16,0.17,1} }
		if index == 1 && state.has_end { color = [4]f32{0.035,0.16,0.17,1} }
		if index == 2 { color = [4]f32{0.15,0.061,0.032,1} }
		if contains(rect, ui.mouse) { color = [4]f32{0.105,0.112,0.104,1} }
		if index == 2 && contains(rect, ui.mouse) { color = [4]f32{0.23,0.083,0.035,1} }
		push_rect(vertices, rect, color)
		push_border(vertices, rect, border)
	}
	push_rect(vertices, UI_Rect{18,30,ui.width-36,1}, border)
	focus_rect := UI_Rect{}
	#partial switch ui.focus {
	case .URL:             focus_rect = import_field
	case .Source_Search:   focus_rect = source_search
	case .Exercise_Search: focus_rect = exercise_search
	case .Exercise_Name:   focus_rect = exercise_name
	}
	if ui.focus != .None {
		push_border(vertices, focus_rect, orange)
		push_rect(vertices, UI_Rect{focus_rect.x,focus_rect.y,3,focus_rect.h}, orange)
	}
}

build_text_overlay :: proc(width, height: uint) -> []u8 {
	pixels := make([]u8, int(width*height*4))
	space := CGColorSpaceCreateDeviceRGB()
	ctx := CGBitmapContextCreate(raw_data(pixels), width, height, 8, width*4, space, 0x2002)
	CGColorSpaceRelease(space)
	if ctx == nil { return pixels }
	defer CGContextRelease(ctx)
	CGContextClearRect(ctx, Rect{Point{0,0}, Size{f64(width),f64(height)}})
	font_name := CFStringCreateWithCString(nil, "BerkeleyMonoVariable-Regular", 0x08000100)
	small_font := CTFontCreateWithName(font_name, SMALL_FONT_SIZE*ui.scale, nil)
	title_font := CTFontCreateWithName(font_name, TITLE_FONT_SIZE*ui.scale, nil)
	CFRelease(font_name)
	defer CFRelease(small_font)
	defer CFRelease(title_font)
	s := ui.scale
	ink := [4]f64{0.89,0.88,0.82,1}
	bright := [4]f64{0.97,0.95,0.88,1}
	muted := [4]f64{0.47,0.49,0.46,1}
	dim := [4]f64{0.31,0.33,0.31,1}
	orange := [4]f64{0.98,0.35,0.09,1}
	cyan := [4]f64{0.27,0.72,0.73,1}

	import_field, import_button, source_search, source_panel, player, transcript, exercise_search, exercise_panel, exercise_name, controls := layout_rects()

	header := UI_Rect{18, ui.height-64, ui.width-36, 64}
	draw_text_in_rect(ctx, title_font, "VOCAL TRAINING / SIGNAL WORKBENCH", header, .Start, .Center, bright, 16)
	draw_text_in_rect(ctx, small_font, "VT–01", UI_Rect{ui.width-176,header.y,140,header.h}, .End, .Center, orange)
	draw_text_in_rect(ctx, small_font, "LOCAL  //  ARM64  //  METAL", UI_Rect{ui.width-390,header.y,200,header.h}, .End, .Center, muted)
	command_heading := UI_Rect{import_field.x+20, import_field.y+import_field.h-7, 138, 14}
	draw_text_in_rect(ctx, small_font, "COMMAND / INGEST", command_heading, .Start, .Center, muted)
	draw_text_in_rect(ctx, title_font, "EXECUTE", import_button, .Center, .Center, [4]f64{0.08,0.025,0.01,1})
	url_text := ui.url_input
	if len(url_text) == 0 {
		draw_text_in_rect(ctx, small_font, "$ paste youtube url(s) here", import_field, .Start, .Center, dim, 12)
	} else {
		draw_text_in_rect(ctx, small_font, fmt.tprintf("$ %s", url_text), import_field, .Start, .Center, ink, 12)
	}

	source_header := UI_Rect{source_panel.x,source_panel.y+source_panel.h-35,source_panel.w,35}
	player_header := UI_Rect{player.x,player.y+player.h-35,player.w,35}
	transcript_header := UI_Rect{transcript.x,transcript.y+transcript.h-35,transcript.w,35}
	exercise_header := UI_Rect{exercise_panel.x,exercise_panel.y+exercise_panel.h-35,exercise_panel.w,35}
	draw_text_in_rect(ctx, small_font, "01 / SOURCE REGISTER", source_header, .Start, .Center, muted, 10)
	draw_text_in_rect(ctx, small_font, fmt.tprintf("%03d ITEMS", len(state.sources)), source_header, .End, .Center, cyan, 10)
	draw_text_in_rect(ctx, small_font, "02 / MONITOR", player_header, .Start, .Center, muted, 10)
	draw_text_in_rect(ctx, small_font, state.active_source >= 0 ? "SIGNAL LOCK" : "NO SIGNAL", player_header, .End, .Center, state.active_source >= 0 ? cyan : dim, 10)
	draw_text_in_rect(ctx, small_font, "03 / TIMED TRANSCRIPT", transcript_header, .Start, .Center, muted, 10)
	draw_text_in_rect(ctx, small_font, fmt.tprintf("%04d SEGMENTS", len(state.segments)), transcript_header, .End, .Center, cyan, 10)
	draw_text_in_rect(ctx, small_font, "04 / EXERCISE BANK", exercise_header, .Start, .Center, muted, 10)
	draw_text_in_rect(ctx, small_font, fmt.tprintf("%03d SAVED", len(state.exercises)), exercise_header, .End, .Center, cyan, 10)

	source_text := ui.source_search
	if len(source_text) == 0 { source_text = "/ filter source register" }
	draw_text_in_rect(ctx, small_font, source_text, source_search, .Start, .Center, dim, 8)
	exercise_search_text := ui.exercise_search
	if len(exercise_search_text) == 0 { exercise_search_text = "/ filter exercise bank" }
	draw_text_in_rect(ctx, small_font, exercise_search_text, exercise_search, .Start, .Center, dim, 8)
	exercise_name_text := ui.exercise_name
	if len(exercise_name_text) == 0 { exercise_name_text = "NAME / optional designation" }
	draw_text_in_rect(ctx, small_font, exercise_name_text, exercise_name, .Start, .Center, len(ui.exercise_name) > 0 ? ink : dim, 8)

	source_content := source_content_rect(source_search, source_panel)
	CGContextSaveGState(ctx)
	CGContextClipToRect(ctx, Rect{Point{source_content.x*s,source_content.y*s},Size{source_content.w*s,source_content.h*s}})
	row := UI_Rect{source_content.x, source_content.y+source_content.h-29+ui.source_scroll, source_content.w, 29}
	visible_source_index := 1
	for source, index in state.sources {
		if len(ui.source_search) > 0 && !strings.contains(source.title, ui.source_search) && !strings.contains(source.video_id, ui.source_search) { continue }
		if row.y >= source_content.y && row.y+row.h <= source_content.y+source_content.h {
			row_color := ink
			if index == state.active_source { row_color = orange }
			draw_text_in_rect(ctx, small_font, fmt.tprintf("%02d", visible_source_index), UI_Rect{row.x+8,row.y,28,row.h}, .Start, .Center, muted)
			draw_text_in_rect(ctx, small_font, source.title, UI_Rect{row.x+42,row.y,row.w-48,row.h}, .Start, .Center, row_color)
		}
		row.y -= 30
		visible_source_index += 1
	}
	if len(state.sources) == 0 {
		draw_text_in_rect(ctx, small_font, "0000  REGISTER EMPTY", UI_Rect{source_content.x,source_content.y+source_content.h-29,source_content.w,29}, .Start, .Center, dim, 8)
	}
	CGContextRestoreGState(ctx)

	if state.active_source < 0 {
		player_content := player_content_rect(player)
		draw_text_in_rect(ctx, small_font, "NO INPUT SIGNAL", UI_Rect{player_content.x,player_content.y+player_content.h/2,player_content.w,24}, .Center, .Center, dim)
		draw_text_in_rect(ctx, small_font, "INGEST A SOURCE TO INITIALIZE MONITOR", UI_Rect{player_content.x,player_content.y+player_content.h/2-24,player_content.w,24}, .Center, .Center, muted)
	} else {
		source := &state.sources[state.active_source]
		metadata := UI_Rect{player.x,player.y,player.w,30}
		draw_text_in_rect(ctx, small_font, source.title, UI_Rect{metadata.x,metadata.y,metadata.w-150,metadata.h}, .Start, .Center, ink, 10)
		if seconds, ok := current_seconds(); ok {
			draw_text_in_rect(ctx, small_font, fmt.tprintf("T+%07.2f", seconds), metadata, .End, .Center, cyan, 10)
		}
	}

	transcript_content := transcript_content_rect(transcript)
	CGContextSaveGState(ctx)
	CGContextClipToRect(ctx, Rect{Point{transcript_content.x*s,transcript_content.y*s},Size{transcript_content.w*s,transcript_content.h*s}})
	row = UI_Rect{transcript_content.x, transcript_content.y+transcript_content.h-25+ui.transcript_scroll, transcript_content.w, 25}
	if state.active_source >= 0 {
		source_id := state.sources[state.active_source].id
		segment_index := 1
		for segment in state.segments {
			if segment.source_id != source_id { continue }
			if row.y >= transcript_content.y && row.y+row.h <= transcript_content.y+transcript_content.h {
				draw_text_in_rect(ctx, small_font, fmt.tprintf("%03d", segment_index), UI_Rect{row.x+8,row.y,36,row.h}, .Start, .Center, muted)
				draw_text_in_rect(ctx, small_font, fmt.tprintf("%07.2f", segment.start_seconds), UI_Rect{row.x+52,row.y,68,row.h}, .Start, .Center, cyan)
				draw_text_in_rect(ctx, small_font, segment.text, UI_Rect{row.x+126,row.y,row.w-134,row.h}, .Start, .Center, ink)
			}
			row.y -= 26
			segment_index += 1
		}
	}
	if len(state.segments) == 0 {
		draw_text_in_rect(ctx, small_font, "0000  NO TIMECODE DATA / LOAD CAPTIONS", UI_Rect{transcript_content.x,transcript_content.y+transcript_content.h-25,transcript_content.w,25}, .Start, .Center, dim, 8)
	}
	CGContextRestoreGState(ctx)

	exercise_content := exercise_content_rect(exercise_search, exercise_panel, exercise_name)
	CGContextSaveGState(ctx)
	CGContextClipToRect(ctx, Rect{Point{exercise_content.x*s,exercise_content.y*s},Size{exercise_content.w*s,exercise_content.h*s}})
	row = UI_Rect{exercise_content.x, exercise_content.y+exercise_content.h-29+ui.exercise_scroll, exercise_content.w, 29}
	exercise_index := 1
	for exercise in state.exercises {
		if len(ui.exercise_search) > 0 && !strings.contains(exercise.name, ui.exercise_search) { continue }
		if row.y >= exercise_content.y && row.y+row.h <= exercise_content.y+exercise_content.h {
			draw_text_in_rect(ctx, small_font, fmt.tprintf("E%02d", exercise_index), UI_Rect{row.x+8,row.y,34,row.h}, .Start, .Center, muted)
			draw_text_in_rect(ctx, small_font, exercise.name, UI_Rect{row.x+46,row.y,row.w-52,row.h}, .Start, .Center, ink)
		}
		row.y -= 30
		exercise_index += 1
	}
	if len(state.exercises) == 0 {
		draw_text_in_rect(ctx, small_font, "E00  BANK EMPTY", UI_Rect{exercise_content.x,exercise_content.y+exercise_content.h-29,exercise_content.w,29}, .Start, .Center, dim, 8)
	}
	CGContextRestoreGState(ctx)

	labels := [8]string{"MARK IN","MARK OUT","COMMIT","RUN","HOLD","CAPTIONS","AUDITION","DATA"}
	for label, i in labels {
		rect := control_rect(controls, i)
		draw_text_in_rect(ctx, small_font, fmt.tprintf("%02d", i+1), UI_Rect{rect.x+8,rect.y,24,rect.h}, .Start, .Center, muted)
		button_color := ink
		if i == 2 { button_color = orange }
		draw_text_in_rect(ctx, small_font, label, UI_Rect{rect.x+34,rect.y,rect.w-40,rect.h}, .Start, .Center, button_color)
	}

	range_text := "RANGE --:--:-- → --:--:--"
	if state.has_start || state.has_end {
		range_text = fmt.tprintf("RANGE %07.2f → %07.2f", state.range_start, state.range_end)
	}
	footer := UI_Rect{18,0,ui.width-36,30}
	draw_text_in_rect(ctx, small_font, range_text, UI_Rect{footer.x,footer.y,300,footer.h}, .Start, .Center, state.has_start && state.has_end ? cyan : muted)
	draw_text_in_rect(ctx, small_font, fmt.tprintf("SYS / %s", ui.status), UI_Rect{footer.x+314,footer.y,max(0,footer.w-500),footer.h}, .Start, .Center, muted)
	draw_text_in_rect(ctx, small_font, "60 HZ / ONLINE", footer, .End, .Center, cyan)
	return pixels
}

ensure_text_texture :: proc(width, height: uint) -> bool {
	if ui.text_texture != nil && ui.text_width == width && ui.text_height == height { return false }
	desc := msg_id_u_u_u_b(objc_getClass("MTLTextureDescriptor"), sel_registerName("texture2DDescriptorWithPixelFormat:width:height:mipmapped:"), 80, width, height, false)
	ui.text_texture = msg_id_id(ui.device, sel_registerName("newTextureWithDescriptor:"), desc)
	ui.text_width, ui.text_height = width, height
	return true
}

encode_texture :: proc(encoder, texture: Id, rect: UI_Rect, alpha: f32) {
	if texture == nil { return }
	vertices: [dynamic]Texture_Vertex
	defer delete(vertices)
	push_texture_rect(&vertices, rect, [4]f32{1,1,1,alpha})
	msg_void_id(encoder, sel_registerName("setRenderPipelineState:"), ui.texture_pipeline)
	msg_void_ptr_u_u(encoder, sel_registerName("setVertexBytes:length:atIndex:"), raw_data(vertices[:]), uint(len(vertices))*size_of(Texture_Vertex), 0)
	msg_void_id_u(encoder, sel_registerName("setFragmentTexture:atIndex:"), texture, 0)
	msg_void_u_u_u(encoder, sel_registerName("drawPrimitives:vertexStart:vertexCount:"), 3, 0, uint(len(vertices)))
}

encode_solid_vertices :: proc(encoder: Id, vertices: []Solid_Vertex) {
	// Metal limits setVertexBytes payloads to 4 KiB. Keep each batch aligned
	// to complete rectangles (six vertices) so no triangle crosses uploads.
	max_vertices := 168
	for start := 0; start < len(vertices); start += max_vertices {
		count := min(max_vertices, len(vertices)-start)
		batch := vertices[start:start+count]
		msg_void_ptr_u_u(encoder, sel_registerName("setVertexBytes:length:atIndex:"), raw_data(batch), uint(count)*size_of(Solid_Vertex), 0)
		msg_void_u_u_u(encoder, sel_registerName("drawPrimitives:vertexStart:vertexCount:"), 3, 0, uint(count))
	}
}

ax_screen_rect :: proc(rect: UI_Rect) -> Rect {
	view_rect := Rect{Point{rect.x,rect.y},Size{rect.w,rect.h}}
	window_rect := msg_rect_rect_id(ui.view, sel_registerName("convertRect:toView:"), view_rect, nil)
	return msg_rect_rect(state.window, sel_registerName("convertRectToScreen:"), window_rect)
}

add_ax_element :: proc(array, element_class: Id, label, role: string, rect: UI_Rect, kind: AX_Kind, index: int = 0, seconds: f64 = 0) {
	element := msg_id(element_class, sel_registerName("new"))
	msg_void_id(element, sel_registerName("setAccessibilityParent:"), ui.view)
	msg_void_id(element, sel_registerName("setAccessibilityRole:"), nsstring(role))
	msg_void_id(element, sel_registerName("setAccessibilityLabel:"), nsstring(label))
	msg_void_rect(element, sel_registerName("setAccessibilityFrame:"), ax_screen_rect(rect))
	msg_void_id(array, sel_registerName("addObject:"), element)
	append(&ax_actions, AX_Action{element=element,kind=kind,index=index,seconds=seconds})
	msg_void(element, sel_registerName("release"))
}

rebuild_accessibility :: proc() {
	clear(&ax_actions)
	if ui.ax_children != nil { msg_void(ui.ax_children, sel_registerName("release")) }
	array := msg_id(objc_getClass("NSMutableArray"), sel_registerName("array"))
	ui.ax_children = msg_id(array, sel_registerName("retain"))
	element_class := objc_getClass("VocalAccessibilityElement")
	import_field, import_button, source_search, source_panel, _, transcript, exercise_search, exercise_panel, exercise_name, controls := layout_rects()
	add_ax_element(array, element_class, "YouTube URLs", "AXTextField", import_field, .URL)
	add_ax_element(array, element_class, "Import", "AXButton", import_button, .Import)
	add_ax_element(array, element_class, "Filter sources", "AXTextField", source_search, .Source_Search)
	source_content := source_content_rect(source_search, source_panel)
	row := UI_Rect{source_content.x, source_content.y+source_content.h-29+ui.source_scroll, source_content.w, 29}
	for source, index in state.sources {
		if len(ui.source_search) > 0 && !strings.contains(source.title, ui.source_search) && !strings.contains(source.video_id, ui.source_search) { continue }
		if row.y >= source_content.y && row.y+row.h <= source_content.y+source_content.h {
			add_ax_element(array, element_class, source.title, "AXButton", row, .Source, index)
		}
		row.y -= 30
	}
	transcript_content := transcript_content_rect(transcript)
	row = UI_Rect{transcript_content.x, transcript_content.y+transcript_content.h-25+ui.transcript_scroll, transcript_content.w, 25}
	if state.active_source >= 0 {
		source_id := state.sources[state.active_source].id
		for segment in state.segments {
			if segment.source_id != source_id { continue }
			if row.y >= transcript_content.y && row.y+row.h <= transcript_content.y+transcript_content.h {
				label := fmt.tprintf("%.1f seconds, %s", segment.start_seconds, segment.text)
				add_ax_element(array, element_class, label, "AXButton", row, .Transcript, seconds=segment.start_seconds)
			}
			row.y -= 26
		}
	}
	add_ax_element(array, element_class, "Filter exercises", "AXTextField", exercise_search, .Exercise_Search)
	exercise_content := exercise_content_rect(exercise_search, exercise_panel, exercise_name)
	row = UI_Rect{exercise_content.x, exercise_content.y+exercise_content.h-29+ui.exercise_scroll, exercise_content.w, 29}
	for exercise, index in state.exercises {
		if len(ui.exercise_search) > 0 && !strings.contains(exercise.name, ui.exercise_search) { continue }
		if row.y >= exercise_content.y && row.y+row.h <= exercise_content.y+exercise_content.h {
			add_ax_element(array, element_class, exercise.name, "AXButton", row, .Exercise, index)
		}
		row.y -= 30
	}
	add_ax_element(array, element_class, "Exercise name", "AXTextField", exercise_name, .Exercise_Name)
	kinds := [8]AX_Kind{.Start,.End,.Save,.Play,.Pause,.Captions,.Preview,.Data}
	labels := [8]string{"Set start","Set end","Save exercise","Play","Pause","Load captions","Preview range","Open data folder"}
	for kind, index in kinds {
		add_ax_element(array, element_class, labels[index], "AXButton", control_rect(controls, index), kind)
	}
}

find_ax_action :: proc(element: Id) -> ^AX_Action {
	for &action in ax_actions {
		if action.element == element { return &action }
	}
	return nil
}

on_ax_press :: proc "c" (self: Id, command: Sel) -> bool {
	context = runtime.default_context()
	action := find_ax_action(self)
	if action == nil { return false }
	#partial switch action.kind {
	case .URL:             ui.focus = .URL
	case .Import:          on_import(nil,nil,nil)
	case .Source_Search:   ui.focus = .Source_Search
	case .Source:
		ui_event_tag = action.index
		on_select_source(nil,nil,nil)
	case .Transcript:      seek_seconds(action.seconds)
	case .Exercise_Search: ui.focus = .Exercise_Search
	case .Exercise:
		ui_event_tag = action.index
		on_play_exercise(nil,nil,nil)
	case .Exercise_Name: ui.focus = .Exercise_Name
	case .Start:         on_set_start(nil,nil,nil)
	case .End:           on_set_end(nil,nil,nil)
	case .Save:          on_save(nil,nil,nil)
	case .Play:          on_play(nil,nil,nil)
	case .Pause:         on_pause(nil,nil,nil)
	case .Captions:      on_transcribe(nil,nil,nil)
	case .Preview:       on_preview(nil,nil,nil)
	case .Data:          on_open_data_folder(nil,nil,nil)
	}
	ui.needs_redraw = true
	return true
}

on_ax_value :: proc "c" (self: Id, command: Sel) -> Id {
	context = runtime.default_context()
	action := find_ax_action(self)
	if action == nil { return nil }
	#partial switch action.kind {
	case .URL:             return nsstring(ui.url_input)
	case .Source_Search:   return nsstring(ui.source_search)
	case .Exercise_Search: return nsstring(ui.exercise_search)
	case .Exercise_Name:   return nsstring(ui.exercise_name)
	}
	return nil
}

on_ax_set_value :: proc "c" (self: Id, command: Sel, value: Id) {
	context = runtime.default_context()
	action := find_ax_action(self)
	if action == nil { return }
	utf8 := msg_id(value, sel_registerName("UTF8String"))
	if utf8 == nil { return }
	text := string(cstring(utf8))
	#partial switch action.kind {
	case .URL:             ui_set_string(&ui.url_input, text)
	case .Source_Search:   ui_set_string(&ui.source_search, text)
	case .Exercise_Search: ui_set_string(&ui.exercise_search, text)
	case .Exercise_Name:   ui_set_string(&ui.exercise_name, text)
	case: return
	}
	ui.needs_redraw = true
}

on_metal_ax_children :: proc "c" (self: Id, command: Sel) -> Id {
	return ui.ax_children
}

on_metal_is_ax_element :: proc "c" (self: Id, command: Sel) -> bool { return false }

current_video_texture :: proc() -> (Id, uint, uint) {
	if ui.video_output == nil || ui.texture_cache == nil { return nil, 0, 0 }
	seconds, ok := current_seconds()
	if !ok { return nil, 0, 0 }
	time := CMTime{value=i64(seconds*600), timescale=600, flags=1}
	if !msg_bool_time(ui.video_output, sel_registerName("hasNewPixelBufferForItemTime:"), time) {
		return ui.last_video_texture, ui.last_video_width, ui.last_video_height
	}
	display_time: CMTime
	buffer := msg_id_time_time(ui.video_output, sel_registerName("copyPixelBufferForItemTime:itemTimeForDisplay:"), time, &display_time)
	if buffer == nil { return ui.last_video_texture, ui.last_video_width, ui.last_video_height }
	defer CFRelease(buffer)
	width := CVPixelBufferGetWidth(buffer)
	height := CVPixelBufferGetHeight(buffer)
	cv_texture: rawptr
	if CVMetalTextureCacheCreateTextureFromImage(nil, ui.texture_cache, buffer, nil, 80, width, height, 0, &cv_texture) != 0 {
		return ui.last_video_texture, ui.last_video_width, ui.last_video_height
	}
	if cv_texture == nil { return ui.last_video_texture, ui.last_video_width, ui.last_video_height }
	defer CFRelease(cv_texture)
	texture := CVMetalTextureGetTexture(cv_texture)
	if texture == nil { return ui.last_video_texture, ui.last_video_width, ui.last_video_height }
	retained := msg_id(texture, sel_registerName("retain"))
	if ui.last_video_texture != nil { msg_void(ui.last_video_texture, sel_registerName("release")) }
	ui.last_video_texture = retained
	ui.last_video_width, ui.last_video_height = width, height
	return retained, width, height
}

render_frame :: proc() {
	if ui.layer == nil || ui.width <= 0 || ui.height <= 0 { return }
	drawable := msg_id(ui.layer, sel_registerName("nextDrawable"))
	if drawable == nil { return }
	texture := msg_id(drawable, sel_registerName("texture"))
	command_buffer := msg_id(ui.queue, sel_registerName("commandBuffer"))
	pass := msg_id(objc_getClass("MTLRenderPassDescriptor"), sel_registerName("renderPassDescriptor"))
	attachments := msg_id(pass, sel_registerName("colorAttachments"))
	attachment := msg_id_uint(attachments, sel_registerName("objectAtIndexedSubscript:"), 0)
	msg_void_id(attachment, sel_registerName("setTexture:"), texture)
	msg_void_i(attachment, sel_registerName("setLoadAction:"), 2)
	msg_void_i(attachment, sel_registerName("setStoreAction:"), 1)
	msg_void_clear_color(attachment, sel_registerName("setClearColor:"), MTL_Clear_Color{0.026,0.028,0.027,1})
	encoder := msg_id_id(command_buffer, sel_registerName("renderCommandEncoderWithDescriptor:"), pass)

	vertices: [dynamic]Solid_Vertex
	build_geometry(&vertices)
	msg_void_id(encoder, sel_registerName("setRenderPipelineState:"), ui.solid_pipeline)
	encode_solid_vertices(encoder, vertices[:])
	delete(vertices)

	_, _, _, _, player, _, _, _, _, _ := layout_rects()
	player_rect := player_content_rect(player)
	if video_texture, video_width, video_height := current_video_texture(); video_texture != nil {
		aspect := f64(video_width)/f64(video_height)
		draw_rect := player_rect
		if draw_rect.w/draw_rect.h > aspect {
			draw_rect.w = draw_rect.h*aspect
			draw_rect.x += (player_rect.w-draw_rect.w)/2
		} else {
			draw_rect.h = draw_rect.w/aspect
			draw_rect.y += (player_rect.h-draw_rect.h)/2
		}
		encode_texture(encoder, video_texture, draw_rect, 1)
	}

	pixel_width := uint(max(1, ui.width*ui.scale))
	pixel_height := uint(max(1, ui.height*ui.scale))
	texture_resized := ensure_text_texture(pixel_width, pixel_height)
	if ui.needs_redraw || texture_resized {
		pixels := build_text_overlay(pixel_width, pixel_height)
		msg_void_region_u_ptr_u(ui.text_texture, sel_registerName("replaceRegion:mipmapLevel:withBytes:bytesPerRow:"), MTL_Region{MTL_Origin{0,0,0},MTL_Size{pixel_width,pixel_height,1}}, 0, raw_data(pixels), pixel_width*4)
		delete(pixels)
	}
	encode_texture(encoder, ui.text_texture, UI_Rect{0,0,ui.width,ui.height}, 1)

	msg_void(encoder, sel_registerName("endEncoding"))
	msg_void_id(command_buffer, sel_registerName("presentDrawable:"), drawable)
	msg_void(command_buffer, sel_registerName("commit"))
	if ui.needs_redraw { rebuild_accessibility() }
	ui.needs_redraw = false
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
	library := msg_id_id_error(ui.device, sel_registerName("newLibraryWithSource:options:error:"), nsstring(source), nil, &error)
	if library == nil { return false }
	solid_vertex := msg_id_id(library, sel_registerName("newFunctionWithName:"), nsstring("solid_vertex"))
	solid_fragment := msg_id_id(library, sel_registerName("newFunctionWithName:"), nsstring("solid_fragment"))
	texture_vertex := msg_id_id(library, sel_registerName("newFunctionWithName:"), nsstring("texture_vertex"))
	texture_fragment := msg_id_id(library, sel_registerName("newFunctionWithName:"), nsstring("texture_fragment"))

	desc := msg_id(objc_getClass("MTLRenderPipelineDescriptor"), sel_registerName("new"))
	msg_void_id(desc, sel_registerName("setVertexFunction:"), solid_vertex)
	msg_void_id(desc, sel_registerName("setFragmentFunction:"), solid_fragment)
	attachment := msg_id_uint(msg_id(desc, sel_registerName("colorAttachments")), sel_registerName("objectAtIndexedSubscript:"), 0)
	msg_void_i(attachment, sel_registerName("setPixelFormat:"), 80)
	ui.solid_pipeline = msg_id_id_error_2(ui.device, sel_registerName("newRenderPipelineStateWithDescriptor:error:"), desc, &error)

	texture_desc := msg_id(objc_getClass("MTLRenderPipelineDescriptor"), sel_registerName("new"))
	msg_void_id(texture_desc, sel_registerName("setVertexFunction:"), texture_vertex)
	msg_void_id(texture_desc, sel_registerName("setFragmentFunction:"), texture_fragment)
	texture_attachment := msg_id_uint(msg_id(texture_desc, sel_registerName("colorAttachments")), sel_registerName("objectAtIndexedSubscript:"), 0)
	msg_void_i(texture_attachment, sel_registerName("setPixelFormat:"), 80)
	msg_void_bool(texture_attachment, sel_registerName("setBlendingEnabled:"), true)
	msg_void_i(texture_attachment, sel_registerName("setSourceRGBBlendFactor:"), 1)
	msg_void_i(texture_attachment, sel_registerName("setDestinationRGBBlendFactor:"), 5)
	msg_void_i(texture_attachment, sel_registerName("setSourceAlphaBlendFactor:"), 1)
	msg_void_i(texture_attachment, sel_registerName("setDestinationAlphaBlendFactor:"), 5)
	ui.texture_pipeline = msg_id_id_error_2(ui.device, sel_registerName("newRenderPipelineStateWithDescriptor:error:"), texture_desc, &error)
	return ui.solid_pipeline != nil && ui.texture_pipeline != nil
}

metal_player_load :: proc(path: string) {
	if ui.last_video_texture != nil {
		msg_void(ui.last_video_texture, sel_registerName("release"))
		ui.last_video_texture = nil
		ui.last_video_width, ui.last_video_height = 0, 0
	}
	url := msg_id_id(objc_getClass("NSURL"), sel_registerName("fileURLWithPath:"), nsstring(path))
	item := msg_id_id(objc_getClass("AVPlayerItem"), sel_registerName("playerItemWithURL:"), url)
	pixel_type := msg_id_uint(objc_getClass("NSNumber"), sel_registerName("numberWithUnsignedInt:"), 0x42475241)
	settings := msg_id_id_id(objc_getClass("NSDictionary"), sel_registerName("dictionaryWithObject:forKey:"), pixel_type, nsstring("PixelFormatType"))
	output := msg_id_id(msg_id(objc_getClass("AVPlayerItemVideoOutput"), sel_registerName("alloc")), sel_registerName("initWithPixelBufferAttributes:"), settings)
	msg_void_id(item, sel_registerName("addOutput:"), output)
	state.player = msg_id_id(objc_getClass("AVPlayer"), sel_registerName("playerWithPlayerItem:"), item)
	ui.video_output = output
	ui.needs_redraw = true
}

activate_control :: proc(index: int) {
	switch index {
	case 0: on_set_start(nil,nil,nil)
	case 1: on_set_end(nil,nil,nil)
	case 2: on_save(nil,nil,nil)
	case 3: on_play(nil,nil,nil)
	case 4: on_pause(nil,nil,nil)
	case 5: on_transcribe(nil,nil,nil)
	case 6: on_preview(nil,nil,nil)
	case 7: on_open_data_folder(nil,nil,nil)
	case: return
	}
}

dispatch_click :: proc(point: Point) {
	import_field, import_button, source_search, source_panel, player, transcript, exercise_search, exercise_panel, exercise_name, controls := layout_rects()
	if ui.has_marked_text {
		ui_set_string(&ui.marked_text, "")
		ui.has_marked_text = false
	}
	if contains(import_field, point) { ui.focus = .URL; return }
	if contains(source_search, point) { ui.focus = .Source_Search; return }
	if contains(exercise_search, point) { ui.focus = .Exercise_Search; return }
	if contains(exercise_name, point) { ui.focus = .Exercise_Name; return }
	ui.focus = .None
	if contains(import_button, point) { on_import(nil,nil,nil); return }
	if contains(player, point) { on_toggle_playback(nil,nil,nil); return }

	source_content := source_content_rect(source_search, source_panel)
	row := UI_Rect{source_content.x, source_content.y+source_content.h-29+ui.source_scroll, source_content.w, 29}
	for source, index in state.sources {
		if len(ui.source_search) > 0 && !strings.contains(source.title, ui.source_search) && !strings.contains(source.video_id, ui.source_search) { continue }
		if row.y >= source_content.y && row.y+row.h <= source_content.y+source_content.h && contains(row, point) {
			ui_event_tag = index
			on_select_source(nil,nil,nil)
			return
		}
		row.y -= 30
	}
	transcript_content := transcript_content_rect(transcript)
	row = UI_Rect{transcript_content.x, transcript_content.y+transcript_content.h-25+ui.transcript_scroll, transcript_content.w, 25}
	if state.active_source >= 0 {
		source_id := state.sources[state.active_source].id
		for segment in state.segments {
			if segment.source_id != source_id { continue }
			if row.y >= transcript_content.y && row.y+row.h <= transcript_content.y+transcript_content.h && contains(row, point) {
				seek_seconds(segment.start_seconds)
				return
			}
			row.y -= 26
		}
	}
	exercise_content := exercise_content_rect(exercise_search, exercise_panel, exercise_name)
	row = UI_Rect{exercise_content.x, exercise_content.y+exercise_content.h-29+ui.exercise_scroll, exercise_content.w, 29}
	for exercise, index in state.exercises {
		if len(ui.exercise_search) > 0 && !strings.contains(exercise.name, ui.exercise_search) { continue }
		if row.y >= exercise_content.y && row.y+row.h <= exercise_content.y+exercise_content.h && contains(row, point) {
			ui_event_tag = index
			on_play_exercise(nil,nil,nil)
			return
		}
		row.y -= 30
	}
	for index in 0..<8 {
		if contains(control_rect(controls, index), point) {
			activate_control(index)
			return
		}
	}
}

on_metal_mouse_down :: proc "c" (self: Id, command: Sel, event: Id) {
	context = runtime.default_context()
	window_point := msg_point(event, sel_registerName("locationInWindow"))
	ui.mouse = msg_point_point_id(self, sel_registerName("convertPoint:fromView:"), window_point, nil)
	dispatch_click(ui.mouse)
	ui.needs_redraw = true
}

on_metal_mouse_moved :: proc "c" (self: Id, command: Sel, event: Id) {
	context = runtime.default_context()
	window_point := msg_point(event, sel_registerName("locationInWindow"))
	next := msg_point_point_id(self, sel_registerName("convertPoint:fromView:"), window_point, nil)
	if next != ui.mouse {
		ui.mouse = next
		ui.needs_redraw = true
	}
}

on_metal_scroll :: proc "c" (self: Id, command: Sel, event: Id) {
	context = runtime.default_context()
	delta := msg_f64(event, sel_registerName("scrollingDeltaY"))
	window_point := msg_point(event, sel_registerName("locationInWindow"))
	point := msg_point_point_id(self, sel_registerName("convertPoint:fromView:"), window_point, nil)
	_, _, source_search, source_panel, _, transcript, exercise_search, exercise_panel, exercise_name, _ := layout_rects()
	source_content := source_content_rect(source_search, source_panel)
	transcript_content := transcript_content_rect(transcript)
	exercise_content := exercise_content_rect(exercise_search, exercise_panel, exercise_name)
	if contains(source_content, point) {
		ui.source_scroll = bounded_scroll(ui.source_scroll, delta, filtered_source_count(), 29, 30, source_content.h)
	} else if contains(transcript_content, point) {
		ui.transcript_scroll = bounded_scroll(ui.transcript_scroll, delta, active_segment_count(), 25, 26, transcript_content.h)
	} else if contains(exercise_content, point) {
		ui.exercise_scroll = bounded_scroll(ui.exercise_scroll, delta, filtered_exercise_count(), 29, 30, exercise_content.h)
	}
	ui.needs_redraw = true
}

on_metal_insert_text :: proc "c" (self: Id, command: Sel, value: Id, replacement: NS_Range) {
	context = runtime.default_context()
	target := focused_text()
	if target == nil { return }
	if ui.has_marked_text && len(ui.marked_text) <= len(target^) {
		ui_set_string(target, target^[:len(target^)-len(ui.marked_text)])
	}
	utf8 := msg_id(value, sel_registerName("UTF8String"))
	if utf8 != nil { append_text(target, string(cstring(utf8))) }
	ui_set_string(&ui.marked_text, "")
	ui.has_marked_text = false
	ui.needs_redraw = true
}

on_metal_command :: proc "c" (self: Id, command: Sel, selector: Sel) {
	context = runtime.default_context()
	target := focused_text()
	if selector == sel_registerName("deleteBackward:") {
		if target != nil { remove_last_character(target) }
	} else if selector == sel_registerName("insertNewline:") {
		if ui.focus == .URL { append_text(&ui.url_input, "\n") }
		else if ui.focus == .Source_Search || ui.focus == .Exercise_Search { ui.focus = .None }
		else if ui.focus == .Exercise_Name { ui.focus = .None }
	} else if selector == sel_registerName("insertTab:") {
		ui.focus = UI_Focus((int(ui.focus)+1)%5)
	}
	ui.needs_redraw = true
}

on_metal_key_down :: proc "c" (self: Id, command: Sel, event: Id) {
	context = runtime.default_context()
	if ui.focus == .None {
		key := msg_uint(event, sel_registerName("keyCode"))
		if key == 49 { on_toggle_playback(nil,nil,nil); return }
		key_codes := [8]uint{18,19,20,21,23,22,26,28}
		for control_key, index in key_codes {
			if key == control_key {
				activate_control(index)
				ui.needs_redraw = true
				return
			}
		}
	}
	array := msg_id_id(objc_getClass("NSArray"), sel_registerName("arrayWithObject:"), event)
	msg_void_id(self, sel_registerName("interpretKeyEvents:"), array)
}

on_metal_set_marked :: proc "c" (self: Id, command: Sel, value: Id, selected, replacement: NS_Range) {
	context = runtime.default_context()
	target := focused_text()
	if target == nil { return }
	if ui.has_marked_text && len(ui.marked_text) <= len(target^) {
		ui_set_string(target, target^[:len(target^)-len(ui.marked_text)])
	}
	utf8 := msg_id(value, sel_registerName("UTF8String"))
	if utf8 == nil { return }
	ui_set_string(&ui.marked_text, string(cstring(utf8)))
	append_text(target, ui.marked_text)
	ui.has_marked_text = true
	ui.needs_redraw = true
}

on_metal_unmark :: proc "c" (self: Id, command: Sel) {
	context = runtime.default_context()
	ui_set_string(&ui.marked_text, "")
	ui.has_marked_text = false
}
on_metal_has_marked :: proc "c" (self: Id, command: Sel) -> bool { return ui.has_marked_text }
on_metal_range :: proc "c" (self: Id, command: Sel) -> NS_Range {
	context = runtime.default_context()
	target := focused_text()
	if target == nil { return NS_Range{~uint(0),0} }
	if command == sel_registerName("markedRange") {
		if !ui.has_marked_text { return NS_Range{~uint(0),0} }
		return NS_Range{uint(len(target^)-len(ui.marked_text)), uint(len(ui.marked_text))}
	}
	return NS_Range{uint(len(target^)),0}
}
on_metal_valid_attributes :: proc "c" (self: Id, command: Sel) -> Id {
	context = runtime.default_context()
	return msg_id(objc_getClass("NSArray"), sel_registerName("array"))
}
on_metal_attributed_substring :: proc "c" (self: Id, command: Sel, range: NS_Range, actual: ^NS_Range) -> Id { return nil }
on_metal_character_index :: proc "c" (self: Id, command: Sel, point: Point) -> uint { return 0 }
on_metal_first_rect :: proc "c" (self: Id, command: Sel, range: NS_Range, actual: ^NS_Range) -> Rect {
	context = runtime.default_context()
	frame := msg_rect(state.window, sel_registerName("frame"))
	return Rect{Point{frame.origin.x+ui.mouse.x,frame.origin.y+ui.mouse.y},Size{1,18}}
}

on_metal_accepts_first :: proc "c" (self: Id, command: Sel) -> bool { return true }

on_metal_frame :: proc "c" (self: Id, command: Sel, timer: Id) {
	context = runtime.default_context()
	if state.player != nil && msg_f32(state.player, sel_registerName("rate")) > 0 { ui.needs_redraw = true }
	frame := msg_rect(ui.view, sel_registerName("bounds"))
	if ui.width != frame.size.width || ui.height != frame.size.height {
		ui.width, ui.height = frame.size.width, frame.size.height
		ui.needs_redraw = true
	}
	window := msg_id(ui.view, sel_registerName("window"))
	if window != nil {
		scale := msg_f64(window, sel_registerName("backingScaleFactor"))
		if scale != ui.scale {
			ui.scale = scale
			ui.needs_redraw = true
		}
	}
	if ui.scale <= 0 { ui.scale = 1 }
	normalize_scroll_offsets()
	msg_void_size(ui.layer, sel_registerName("setDrawableSize:"), Size{ui.width*ui.scale,ui.height*ui.scale})
	render_frame()
}

register_delegate :: proc(app: Id) {
	delegate_class := objc_allocateClassPair(objc_getClass("NSObject"), "VocalMetalDelegate", 0)
	class_addMethod(delegate_class, sel_registerName("importFinished:"), rawptr(on_import_finished), "v@:@")
	class_addMethod(delegate_class, sel_registerName("exportFinished:"), rawptr(on_export_finished), "v@:@")
	class_addMethod(delegate_class, sel_registerName("metalFrame:"), rawptr(on_metal_frame), "v@:@")
	class_addMethod(delegate_class, sel_registerName("applicationShouldTerminateAfterLastWindowClosed:"), rawptr(should_terminate_after_window_close), "B@:@")
	objc_registerClassPair(delegate_class)
	state.delegate_target = msg_id(delegate_class, sel_registerName("new"))
	msg_void_id(app, sel_registerName("setDelegate:"), state.delegate_target)
}

register_metal_view_class :: proc() -> Id {
	class := objc_allocateClassPair(objc_getClass("NSView"), "VocalMetalView", 0)
	class_addMethod(class, sel_registerName("acceptsFirstResponder"), rawptr(on_metal_accepts_first), "B@:")
	class_addMethod(class, sel_registerName("mouseDown:"), rawptr(on_metal_mouse_down), "v@:@")
	class_addMethod(class, sel_registerName("mouseMoved:"), rawptr(on_metal_mouse_moved), "v@:@")
	class_addMethod(class, sel_registerName("mouseDragged:"), rawptr(on_metal_mouse_moved), "v@:@")
	class_addMethod(class, sel_registerName("scrollWheel:"), rawptr(on_metal_scroll), "v@:@")
	class_addMethod(class, sel_registerName("keyDown:"), rawptr(on_metal_key_down), "v@:@")
	class_addMethod(class, sel_registerName("insertText:replacementRange:"), rawptr(on_metal_insert_text), "v@:@{_NSRange=QQ}")
	class_addMethod(class, sel_registerName("doCommandBySelector:"), rawptr(on_metal_command), "v@::")
	class_addMethod(class, sel_registerName("setMarkedText:selectedRange:replacementRange:"), rawptr(on_metal_set_marked), "v@:@{_NSRange=QQ}{_NSRange=QQ}")
	class_addMethod(class, sel_registerName("unmarkText"), rawptr(on_metal_unmark), "v@:")
	class_addMethod(class, sel_registerName("hasMarkedText"), rawptr(on_metal_has_marked), "B@:")
	class_addMethod(class, sel_registerName("markedRange"), rawptr(on_metal_range), "{_NSRange=QQ}@:")
	class_addMethod(class, sel_registerName("selectedRange"), rawptr(on_metal_range), "{_NSRange=QQ}@:")
	class_addMethod(class, sel_registerName("validAttributesForMarkedText"), rawptr(on_metal_valid_attributes), "@@:")
	class_addMethod(class, sel_registerName("attributedSubstringForProposedRange:actualRange:"), rawptr(on_metal_attributed_substring), "@@:{_NSRange=QQ}^{_NSRange=QQ}")
	class_addMethod(class, sel_registerName("characterIndexForPoint:"), rawptr(on_metal_character_index), "Q@:{CGPoint=dd}")
	class_addMethod(class, sel_registerName("firstRectForCharacterRange:actualRange:"), rawptr(on_metal_first_rect), "{CGRect={CGPoint=dd}{CGSize=dd}}@:{_NSRange=QQ}^{_NSRange=QQ}")
	class_addMethod(class, sel_registerName("isAccessibilityElement"), rawptr(on_metal_is_ax_element), "B@:")
	class_addMethod(class, sel_registerName("accessibilityChildren"), rawptr(on_metal_ax_children), "@@:")
	objc_registerClassPair(class)
	return class
}

register_accessibility_class :: proc() {
	class := objc_allocateClassPair(objc_getClass("NSAccessibilityElement"), "VocalAccessibilityElement", 0)
	class_addMethod(class, sel_registerName("accessibilityPerformPress"), rawptr(on_ax_press), "B@:")
	class_addMethod(class, sel_registerName("accessibilityValue"), rawptr(on_ax_value), "@@:")
	class_addMethod(class, sel_registerName("setAccessibilityValue:"), rawptr(on_ax_set_value), "v@:@")
	objc_registerClassPair(class)
}

build_metal_window :: proc() {
	app := msg_id(objc_getClass("NSApplication"), sel_registerName("sharedApplication"))
	msg_void_i(app, sel_registerName("setActivationPolicy:"), 0)
	register_delegate(app)

	state.url_input = CONTROL_URL
	state.status = CONTROL_STATUS
	state.source_search_input = CONTROL_SOURCE
	state.exercise_search_input = CONTROL_EXERCISE
	state.exercise_name_input = CONTROL_EXERCISE_NAME
	ui_set_string(&ui.status, "Ready")
	ui.scale = 1
	ui.needs_redraw = true

	frame := Rect{Point{120,100},Size{1100,720}}
	state.window = msg_id_rect_u_u_b(msg_id(objc_getClass("NSWindow"), sel_registerName("alloc")), sel_registerName("initWithContentRect:styleMask:backing:defer:"), frame, 15, 2, false)
	msg_void_id(state.window, sel_registerName("setTitle:"), nsstring("Vocal Training"))
	msg_void_bool(state.window, sel_registerName("setAcceptsMouseMovedEvents:"), true)
	register_accessibility_class()
	view_class := register_metal_view_class()
	ui.view = msg_id_rect(msg_id(view_class, sel_registerName("alloc")), sel_registerName("initWithFrame:"), Rect{Point{0,0},frame.size})
	msg_void_id(state.window, sel_registerName("setContentView:"), ui.view)

	ui.device = MTLCreateSystemDefaultDevice()
	ui.queue = msg_id(ui.device, sel_registerName("newCommandQueue"))
	ui.layer = msg_id(objc_getClass("CAMetalLayer"), sel_registerName("layer"))
	msg_void_id(ui.layer, sel_registerName("setDevice:"), ui.device)
	msg_void_i(ui.layer, sel_registerName("setPixelFormat:"), 80)
	msg_void_bool(ui.layer, sel_registerName("setFramebufferOnly:"), true)
	msg_void_bool(ui.view, sel_registerName("setWantsLayer:"), true)
	msg_void_id(ui.view, sel_registerName("setLayer:"), ui.layer)
	CVMetalTextureCacheCreate(nil,nil,ui.device,nil,&ui.texture_cache)
	if !compile_pipelines() {
		fmt.eprintln("Unable to compile Metal UI pipelines")
		return
	}

	if len(state.sources) > 0 { load_source_player(len(state.sources)-1) }
	// The Objective-C runtime requires the exact floating-point signature, so
	// construct the repeating timer through a typed send.
	timer_send := transmute(proc "c" (Id, Sel, f64, Id, Sel, Id, bool) -> Id)send_address
	_ = timer_send(objc_getClass("NSTimer"), sel_registerName("scheduledTimerWithTimeInterval:target:selector:userInfo:repeats:"), 1.0/60.0, state.delegate_target, sel_registerName("metalFrame:"), nil, true)

	screen := msg_id(objc_getClass("NSScreen"), sel_registerName("mainScreen"))
	msg_void_rect_b(state.window, sel_registerName("setFrame:display:"), msg_rect(screen, sel_registerName("visibleFrame")), true)
	msg_void_id(state.window, sel_registerName("makeFirstResponder:"), ui.view)
	msg_void_id(state.window, sel_registerName("makeKeyAndOrderFront:"), nil)
	msg_void_i(app, sel_registerName("activateIgnoringOtherApps:"), 1)
	msg_void(app, sel_registerName("run"))
}
