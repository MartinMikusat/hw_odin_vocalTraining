package main

import "base:runtime"
import "core:fmt"
import "core:hash"
import mem_virtual "core:mem/virtual"
import "core:strings"
import CF "core:sys/darwin/CoreFoundation"
import command_palette "command_palette:."
import flash "flash:."
import match_sorter "match_sorter:."

foreign import metal "system:Metal.framework"
foreign metal {
	MTLCreateSystemDefaultDevice :: proc "c" () -> Id ---
}

foreign import core_graphics "system:CoreGraphics.framework"
foreign core_graphics {
	CGColorSpaceCreateDeviceRGB :: proc "c" () -> rawptr ---
	CGColorSpaceRelease :: proc "c" (space: rawptr) ---
	CGBitmapContextCreate :: proc "c" (data: rawptr, width, height, bits_per_component, bytes_per_row: uint, space: rawptr, bitmap_info: u32) -> rawptr ---
	CGContextRelease :: proc "c" (ctx: rawptr) ---
	CGContextClearRect :: proc "c" (ctx: rawptr, rect: Rect) ---
	CGContextFillRect :: proc "c" (ctx: rawptr, rect: Rect) ---
	CGContextSetRGBFillColor :: proc "c" (ctx: rawptr, red, green, blue, alpha: f64) ---
	CGContextSaveGState :: proc "c" (ctx: rawptr) ---
	CGContextRestoreGState :: proc "c" (ctx: rawptr) ---
	CGContextClipToRect :: proc "c" (ctx: rawptr, rect: Rect) ---
	CGContextSetTextPosition :: proc "c" (ctx: rawptr, x, y: f64) ---
}

foreign import core_text "system:CoreText.framework"
foreign core_text {
	CTFontCreateWithName :: proc "c" (name: rawptr, size: f64, transform: rawptr) -> rawptr ---
	CTLineCreateWithAttributedString :: proc "c" (string: rawptr) -> rawptr ---
	CTLineCreateTruncatedLine :: proc "c" (line: rawptr, width: f64, truncation_type: u32, token: rawptr) -> rawptr ---
	CTLineGetTypographicBounds :: proc "c" (line: rawptr, ascent, descent, leading: ^f64) -> f64 ---
	CTLineGetOffsetForStringIndex :: proc "c" (line: rawptr, index: int, secondary_offset: ^f64) -> f64 ---
	CTLineGetStringIndexForPosition :: proc "c" (line: rawptr, position: Point) -> int ---
	CTLineGetGlyphRuns :: proc "c" (line: rawptr) -> rawptr ---
	CTLineDraw :: proc "c" (line, ctx: rawptr) ---
	CTRunGetGlyphCount :: proc "c" (run: rawptr) -> int ---
	kCTFontAttributeName: rawptr
	kCTForegroundColorFromContextAttributeName: rawptr
	kCTLigatureAttributeName: rawptr
}

foreign import core_foundation "system:CoreFoundation.framework"
foreign core_foundation {
	CFStringCreateWithCString :: proc "c" (allocator: rawptr, text: cstring, encoding: u32) -> rawptr ---
	CFStringCreateWithBytes :: proc "c" (allocator: CF.TypeRef, bytes: [^]u8, count: CF.Index, encoding: CF.StringEncoding, external: b8) -> CF.String ---
	CFStringGetLength :: proc "c" (string: rawptr) -> int ---
	CFAttributedStringCreateMutable :: proc "c" (allocator: rawptr, max_length: int) -> rawptr ---
	CFAttributedStringReplaceString :: proc "c" (string: rawptr, range: CF_Range, replacement: rawptr) ---
	CFAttributedStringSetAttribute :: proc "c" (string: rawptr, range: CF_Range, name, value: rawptr) ---
	CFArrayGetCount :: proc "c" (array: rawptr) -> int ---
	CFArrayGetValueAtIndex :: proc "c" (array: rawptr, index: int) -> rawptr ---
	CFNumberCreate :: proc "c" (allocator: rawptr, number_type: int, value: rawptr) -> rawptr ---
	CFRetain :: proc "c" (value: rawptr) -> rawptr ---
	CFRelease :: proc "c" (value: rawptr) ---
	kCFBooleanTrue: rawptr
}

foreign import core_video "system:CoreVideo.framework"
foreign core_video {
	CVMetalTextureCacheCreate :: proc "c" (allocator, cache_attributes: rawptr, device: Id, texture_attributes: rawptr, cache: ^rawptr) -> i32 ---
	CVMetalTextureCacheCreateTextureFromImage :: proc "c" (allocator: rawptr, cache: rawptr, image, attributes: rawptr, pixel_format: uint, width, height, plane_index: uint, texture: ^rawptr) -> i32 ---
	CVMetalTextureGetTexture :: proc "c" (texture: rawptr) -> Id ---
	CVPixelBufferGetWidth :: proc "c" (buffer: rawptr) -> uint ---
	CVPixelBufferGetHeight :: proc "c" (buffer: rawptr) -> uint ---
}

UI_Focus :: enum {
	None,
	Command_Palette,
	URL,
	Source_Search,
	Transcript_Search,
	Exercise_Search,
	Exercise_Name,
}

UI_Mode :: enum {
	Create,
	Play,
}

Source_Hint_Control :: enum {
	None,
	Reset,
	Menu,
}

source_hint_control :: proc(hint_count: int) -> Source_Hint_Control {
	if hint_count <= 0 {return .None}
	if hint_count == 1 {return .Reset}
	return .Menu
}

UI_State :: struct {
	view:               Id,
	layer:              Id,
	device:             Id,
	queue:              Id,
	solid_pipeline:     Id,
	texture_pipeline:   Id,
	text_texture:       Id,
	text_width:         uint,
	text_height:        uint,
	texture_cache:      rawptr,
	video_output:       Id,
	audio_engine:       Id,
	audio_player:       Id,
	audio_pitch:        Id,
	audio_file:         Id,
	audio_start_frame:  i64,
	last_video_texture: Id,
	last_video_width:   uint,
	last_video_height:  uint,
	ax_children:        Id,
	width:              f64,
	height:             f64,
	scale:              f64,
	mouse:              Point,
	focus:              UI_Focus,
	palette_previous_focus: UI_Focus,
	caret_byte_offset:  int,
	palette_previous_caret: int,
	marked_start_byte:  int,
	text_scroll_x:      f64,
	palette_previous_text_scroll: f64,
	mode:               UI_Mode,
	source_modal_open:  bool,
	source_modal_refetch_index: int,
	source_details_open: bool,
	source_details_index: int,
	url_input:          string,
	source_search:      string,
	transcript_search:  string,
	exercise_search:    string,
	exercise_name:      string,
	command_palette_query: string,
	command_palette_scroll: f64,
	status:             string,
	status_success:     bool,
	status_error:       bool,
	source_scroll:      f64,
	transcript_scroll:  f64,
	transcript_matches: [dynamic]int,
	transcript_matches_dirty: bool,
	transcript_active_match: int,
	transcript_active_progress: f64,
	transcript_follow_pending: bool,
	transcript_follow_suspended: bool,
	transcript_follow_target_seconds: f64,
	transcript_follow_target_deadline: uint,
	transcript_has_follow_target: bool,
	exercise_scroll:    f64,
	active_exercise:    int,
	marked_text:        string,
	has_marked_text:    bool,
	player_volume:      f32,
	playback_rate:      f32,
	source_playback_active: bool,
	source_scrubbing:   bool,
	source_hint_menu_open: bool,
	activity_tick:      uint,
	frame_tick:         uint,
	url_probe_due_tick: uint,
	url_probe_pending:  bool,
	needs_redraw:       bool,
}

UI_Rect :: struct {
	x, y, w, h: f64,
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
NS_Range :: struct {
	location, length: uint,
}
CF_Range :: struct {
	location, length: int,
}

UI_FONT_NAME :: "Iosevka Aile"
SMALL_FONT_SIZE :: 10.5
APP_HEADER_HEIGHT :: 38.0
TRACE_FOREIGN_LIFETIMES :: #config(VT_TRACE_FOREIGN_LIFETIMES, false)

Text_Align :: enum {
	Start,
	Center,
	End,
}

Text_Run :: struct {
	line:    rawptr,
	advance: f64,
	ascent:  f64,
	descent: f64,
	leading: f64,
}

Timestamp_Fade_Ranges :: struct {
	values: [8]CF_Range,
	count:  int,
}

UI_Action_Kind :: enum {
	Command_Palette_Search,
	Command_Palette_Result,
	Command_Palette_Disabled,
	Mode_Toggle,
	Open_Source_Modal,
	Cancel_Source_Modal,
	Close_Source_Details,
	Refetch_Source_Details,
	Open_Source_Details,
	URL,
	Import,
	Source_Quality,
	Stop_Download,
	Source_Search,
	Transcript_Search,
	Source,
	Transcript,
	Exercise_Search,
	Exercise,
	Exercise_Name,
	Volume_Down,
	Volume_Up,
	Speed_Down,
	Speed_Up,
	Source_Play_Pause,
	Player_Surface,
	Source_Stop,
	Source_Timeline,
	Source_Reset,
	Source_Hint_Menu,
	Source_Hint,
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
	element:    Id,
	control_id: UI_Control_ID,
}

UI_Action :: struct {
	kind:    UI_Action_Kind,
	index:   int,
	value:   int,
	seconds: f64,
}

UI_Control_ID :: distinct u64

UI_Control_Flag :: enum {
	Primary_Press,
	Secondary_Press,
	Drag,
	Flash,
	Accessibility,
	Editable,
	Enabled,
}

UI_Control_Flags :: bit_set[UI_Control_Flag]

UI_Control :: struct {
	id:                  UI_Control_ID,
	functional_name:     string,
	flash_label:         string,
	accessibility_label: string,
	accessibility_role:  string,
	rect:                UI_Rect,
	anchor:              flash.Anchor,
	flags:               UI_Control_Flags,
	action:              UI_Action,
}

UI_Build_Output :: struct {
	controls: [dynamic]UI_Control,
}

ui := UI_State{player_volume = 1, playback_rate = 1, source_details_index = -1, source_modal_refetch_index = -1, transcript_active_match = -1}
ui_event_tag: int
ax_actions: [dynamic]AX_Action
ui_build: UI_Build_Output
flash_state: flash.State
command_palette_state: command_palette.State
command_palette_actions: [dynamic]UI_Action
command_palette_config := command_palette.Config{}

PALETTE_CONTEXT_CREATE       :: command_palette.Context_Mask(1 << 0)
PALETTE_CONTEXT_PLAY         :: command_palette.Context_Mask(1 << 1)
PALETTE_CONTEXT_PLAYER       :: command_palette.Context_Mask(1 << 2)
PALETTE_CONTEXT_SOURCE       :: command_palette.Context_Mask(1 << 3)
PALETTE_CONTEXT_RANGE        :: command_palette.Context_Mask(1 << 4)
PALETTE_CONTEXT_TIMESTAMPS   :: command_palette.Context_Mask(1 << 5)
PALETTE_CONTEXT_IMPORT_BUSY  :: command_palette.Context_Mask(1 << 6)
PALETTE_CONTEXT_EXPORT_BUSY  :: command_palette.Context_Mask(1 << 7)

CONTROL_URL :: Id(rawptr(uintptr(1)))
CONTROL_STATUS :: Id(rawptr(uintptr(2)))
CONTROL_SOURCE :: Id(rawptr(uintptr(3)))
CONTROL_EXERCISE :: Id(rawptr(uintptr(4)))
CONTROL_EXERCISE_NAME :: Id(rawptr(uintptr(5)))

trace_foreign_lifetime :: proc(action, kind: string, value: rawptr, owner: string) {
	when TRACE_FOREIGN_LIFETIMES {
		fmt.eprintf("[foreign] %-7s %-16s %v  %s\n", action, kind, value, owner)
	}
}

foreign_created :: proc(value: rawptr, kind, owner: string) -> rawptr {
	trace_foreign_lifetime("create", kind, value, owner)
	return value
}

foreign_retain :: proc(value: rawptr, kind, owner: string) -> rawptr {
	if value == nil {return nil}
	retained := CFRetain(value)
	trace_foreign_lifetime("retain", kind, retained, owner)
	return retained
}

foreign_release :: proc(value: rawptr, kind, owner: string) {
	if value == nil {return}
	trace_foreign_lifetime("release", kind, value, owner)
	CFRelease(value)
}

assert_foreign :: proc(value: rawptr, message: string) {
	when ODIN_DEBUG {
		assert(value != nil, message)
	}
}

msg_bool :: proc(receiver: Id, selector: Sel) -> bool {
	p := transmute(proc "c" (_: Id, _: Sel) -> bool)send_address
	return p(receiver, selector)
}

msg_bool_sel :: proc(receiver: Id, selector, value: Sel) -> bool {
	p := transmute(proc "c" (_: Id, _: Sel, _: Sel) -> bool)send_address
	return p(receiver, selector, value)
}

msg_void_bool :: proc(receiver: Id, selector: Sel, value: bool) {
	p := transmute(proc "c" (_: Id, _: Sel, _: bool))send_address
	p(receiver, selector, value)
}

msg_void_f64 :: proc(receiver: Id, selector: Sel, value: f64) {
	p := transmute(proc "c" (_: Id, _: Sel, _: f64))send_address
	p(receiver, selector, value)
}

msg_void_f32 :: proc(receiver: Id, selector: Sel, value: f32) {
	p := transmute(proc "c" (_: Id, _: Sel, _: f32))send_address
	p(receiver, selector, value)
}

msg_bool_error :: proc(receiver: Id, selector: Sel, error: ^Id) -> bool {
	p := transmute(proc "c" (_: Id, _: Sel, _: ^Id) -> bool)send_address
	return p(receiver, selector, error)
}

msg_i64 :: proc(receiver: Id, selector: Sel) -> i64 {
	p := transmute(proc "c" (_: Id, _: Sel) -> i64)send_address
	return p(receiver, selector)
}

msg_void_id_id_id :: proc(receiver: Id, selector: Sel, a, b, c: Id) {
	p := transmute(proc "c" (_: Id, _: Sel, _: Id, _: Id, _: Id))send_address
	p(receiver, selector, a, b, c)
}

msg_void_id_i64_u32_id_id :: proc(receiver: Id, selector: Sel, file: Id, frame: i64, count: u32, time, completion: Id) {
	p := transmute(proc "c" (_: Id, _: Sel, _: Id, _: i64, _: u32, _: Id, _: Id))send_address
	p(receiver, selector, file, frame, count, time, completion)
}

msg_point :: proc(receiver: Id, selector: Sel) -> Point {
	p := transmute(proc "c" (_: Id, _: Sel) -> Point)send_address
	return p(receiver, selector)
}

msg_point_point_id :: proc(receiver: Id, selector: Sel, point: Point, view: Id) -> Point {
	p := transmute(proc "c" (_: Id, _: Sel, _: Point, _: Id) -> Point)send_address
	return p(receiver, selector, point, view)
}

msg_size :: proc(receiver: Id, selector: Sel) -> Size {
	p := transmute(proc "c" (_: Id, _: Sel) -> Size)send_address
	return p(receiver, selector)
}

msg_void_size :: proc(receiver: Id, selector: Sel, value: Size) {
	p := transmute(proc "c" (_: Id, _: Sel, _: Size))send_address
	p(receiver, selector, value)
}

msg_id_id_error :: proc(receiver: Id, selector: Sel, value, options: Id, error: ^Id) -> Id {
	p := transmute(proc "c" (_: Id, _: Sel, _: Id, _: Id, _: ^Id) -> Id)send_address
	return p(receiver, selector, value, options, error)
}

msg_id_id_error_2 :: proc(receiver: Id, selector: Sel, value: Id, error: ^Id) -> Id {
	p := transmute(proc "c" (_: Id, _: Sel, _: Id, _: ^Id) -> Id)send_address
	return p(receiver, selector, value, error)
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

msg_id_rect_id :: proc(receiver: Id, selector: Sel, rect: Rect, view: Id) -> Id {
	p := transmute(proc "c" (_: Id, _: Sel, _: Rect, _: Id) -> Id)send_address
	return p(receiver, selector, rect, view)
}

msg_rect_rect :: proc(receiver: Id, selector: Sel, rect: Rect) -> Rect {
	p := transmute(proc "c" (_: Id, _: Sel, _: Rect) -> Rect)send_address
	return p(receiver, selector, rect)
}

msg_rect_rect_id :: proc(receiver: Id, selector: Sel, rect: Rect, view: Id) -> Rect {
	p := transmute(proc "c" (_: Id, _: Sel, _: Rect, _: Id) -> Rect)send_address
	return p(receiver, selector, rect, view)
}

msg_time_f64 :: proc(receiver: Id, selector: Sel, value: f64) -> CMTime {
	p := transmute(proc "c" (_: Id, _: Sel, _: f64) -> CMTime)send_address
	return p(receiver, selector, value)
}

msg_bool_time :: proc(receiver: Id, selector: Sel, value: CMTime) -> bool {
	p := transmute(proc "c" (_: Id, _: Sel, _: CMTime) -> bool)send_address
	return p(receiver, selector, value)
}

msg_id_time_time :: proc(receiver: Id, selector: Sel, value: CMTime, display_time: ^CMTime) -> Id {
	p := transmute(proc "c" (_: Id, _: Sel, _: CMTime, _: ^CMTime) -> Id)send_address
	return p(receiver, selector, value, display_time)
}

ui_set_string :: proc(target: ^string, value: string) {
	replacement := strings.clone(value)
	if len(target^) > 0 {delete(target^)}
	target^ = replacement
}

append_text :: proc(target: ^string, value: string) {
	updated := fmt.tprintf("%s%s", target^, value)
	ui_set_string(target, updated)
}

previous_character_offset :: proc(text: string, offset: int) -> int {
	if offset <= 0 {return 0}
	index := min(offset, len(text)) - 1
	for index > 0 && (text[index] & 0xc0) == 0x80 {index -= 1}
	return index
}

next_character_offset :: proc(text: string, offset: int) -> int {
	if offset >= len(text) {return len(text)}
	index := max(0, offset) + 1
	for index < len(text) && (text[index] & 0xc0) == 0x80 {index += 1}
	return index
}

byte_offset_for_utf16_index :: proc(text: string, target_index: int) -> int {
	byte_index, utf16_index := 0, 0
	for byte_index < len(text) && utf16_index < target_index {
		first := text[byte_index]
		byte_count, utf16_count := 1, 1
		if first & 0xf8 == 0xf0 {byte_count, utf16_count = 4, 2}
		else if first & 0xf0 == 0xe0 {byte_count = 3}
		else if first & 0xe0 == 0xc0 {byte_count = 2}
		if utf16_index + utf16_count > target_index {break}
		byte_index += byte_count
		utf16_index += utf16_count
	}
	return byte_index
}

insert_text_at_caret :: proc(target: ^string, value: string) {
	caret := min(max(ui.caret_byte_offset, 0), len(target^))
	updated := fmt.tprintf("%s%s%s", target^[:caret], value, target^[caret:])
	ui_set_string(target, updated)
	ui.caret_byte_offset = caret + len(value)
}

remove_character_before_caret :: proc(target: ^string) {
	caret := min(max(ui.caret_byte_offset, 0), len(target^))
	start := previous_character_offset(target^, caret)
	if start == caret {return}
	updated := fmt.tprintf("%s%s", target^[:start], target^[caret:])
	ui_set_string(target, updated)
	ui.caret_byte_offset = start
}

remove_character_after_caret :: proc(target: ^string) {
	caret := min(max(ui.caret_byte_offset, 0), len(target^))
	end := next_character_offset(target^, caret)
	if end == caret {return}
	updated := fmt.tprintf("%s%s", target^[:caret], target^[end:])
	ui_set_string(target, updated)
}

remove_word_before_caret :: proc(target: ^string) {
	caret := min(max(ui.caret_byte_offset, 0), len(target^))
	start := caret
	for start > 0 {
		previous := previous_character_offset(target^, start)
		if !is_word_delimiter(target^[previous]) {break}
		start = previous
	}
	for start > 0 {
		previous := previous_character_offset(target^, start)
		if is_word_delimiter(target^[previous]) {break}
		start = previous
	}
	updated := fmt.tprintf("%s%s", target^[:start], target^[caret:])
	ui_set_string(target, updated)
	ui.caret_byte_offset = start
}

line_start_for_offset :: proc(text: string, offset: int) -> int {
	index := min(max(offset, 0), len(text))
	for index > 0 && text[index - 1] != '\n' {index -= 1}
	return index
}

line_end_for_offset :: proc(text: string, offset: int) -> int {
	index := min(max(offset, 0), len(text))
	for index < len(text) && text[index] != '\n' {index += 1}
	return index
}

clear_marked_text :: proc() {
	ui_set_string(&ui.marked_text, "")
	ui.has_marked_text = false
}

remove_marked_text :: proc(target: ^string) {
	if !ui.has_marked_text {return}
	start := min(max(ui.marked_start_byte, 0), len(target^))
	end := min(start + len(ui.marked_text), len(target^))
	updated := fmt.tprintf("%s%s", target^[:start], target^[end:])
	ui_set_string(target, updated)
	ui.caret_byte_offset = start
	clear_marked_text()
}

remove_last_character :: proc(target: ^string) {
	if len(target^) == 0 {return}
	index := len(target^) - 1
	for index > 0 && (target^[index] & 0xc0) == 0x80 {index -= 1}
	ui_set_string(target, target^[:index])
}

is_word_delimiter :: proc(value: u8) -> bool {
	if value >= 0x80 {return false}
	return !(
		value >= 'a' && value <= 'z' ||
		value >= 'A' && value <= 'Z' ||
		value >= '0' && value <= '9' ||
		value == '_'
	)
}

remove_last_word :: proc(target: ^string) {
	index := len(target^)
	for index > 0 && is_word_delimiter(target^[index - 1]) {index -= 1}
	for index > 0 && !is_word_delimiter(target^[index - 1]) {index -= 1}
	ui_set_string(target, target^[:index])
}

focused_text :: proc() -> ^string {
	#partial switch ui.focus {
	case .Command_Palette:
		return &ui.command_palette_query
	case .URL:
		return &ui.url_input
	case .Source_Search:
		return &ui.source_search
	case .Transcript_Search:
		return &ui.transcript_search
	case .Exercise_Search:
		return &ui.exercise_search
	case .Exercise_Name:
		return &ui.exercise_name
	}
	return nil
}

focused_text_changed :: proc(target: ^string) {
	if target == &ui.command_palette_query {
		command_palette.set_query(&command_palette_state, ui.command_palette_query)
		ui.command_palette_scroll = 0
		ensure_command_palette_selection_visible()
	}
	if target == &ui.url_input {schedule_source_probe(30)}
	if target == &ui.transcript_search {invalidate_transcript_matches()}
}

focus_text_input :: proc(focus: UI_Focus) {
	changed := ui.focus != focus
	ui.focus = focus
	if changed {
		if target := focused_text(); target != nil {ui.caret_byte_offset = len(target^)}
		ui.text_scroll_x = 0
	}
	if state.window != nil && ui.view != nil {
		msg_void_id(state.window, sel_registerName("makeFirstResponder:"), ui.view)
	}
	ui.needs_redraw = true
}

escape_should_unfocus :: proc(focus: UI_Focus) -> bool {
	return focus != .None
}

unfocus_text_input :: proc() -> bool {
	if !escape_should_unfocus(ui.focus) {return false}
	target := focused_text()
	had_marked_text := ui.has_marked_text
	if target != nil {remove_marked_text(target)} else {clear_marked_text()}
	if had_marked_text && target != nil {focused_text_changed(target)}
	ui.focus = .None
	ui.text_scroll_x = 0
	ui.needs_redraw = true
	return true
}

contains :: proc(rect: UI_Rect, point: Point) -> bool {
	return(
		point.x >= rect.x &&
		point.x <= rect.x + rect.w &&
		point.y >= rect.y &&
		point.y <= rect.y + rect.h \
	)
}

mode_button_rect_for_size :: proc(width, height: f64) -> UI_Rect {
	return UI_Rect{max(18, width - 214), height - 31, 196, 24}
}

app_header_rect_for_size :: proc(width, height: f64) -> UI_Rect {
	return UI_Rect{0, height - APP_HEADER_HEIGHT, width, APP_HEADER_HEIGHT}
}

app_header_rect :: proc() -> UI_Rect {
	return app_header_rect_for_size(ui.width, ui.height)
}

mode_button_rect :: proc() -> UI_Rect {
	return mode_button_rect_for_size(ui.width, ui.height)
}

source_add_button_rect :: proc(source_panel: UI_Rect) -> UI_Rect {
	return UI_Rect {
		source_panel.x + source_panel.w - 68,
		source_panel.y + source_panel.h - 29,
		58,
		23,
	}
}

source_modal_rect_for_size :: proc(view_width, view_height: f64) -> UI_Rect {
	width := min(max(720, view_width * 0.72), 980)
	height := min(max(520, view_height * 0.72), 680)
	return UI_Rect{(view_width - width) / 2, (view_height - height) / 2, width, height}
}

source_modal_rect :: proc() -> UI_Rect {
	return source_modal_rect_for_size(ui.width, ui.height)
}

COMMAND_PALETTE_ROW_HEIGHT :: 50.0

command_palette_rect_for_size :: proc(view_width, view_height: f64) -> UI_Rect {
	width := min(max(620, view_width * 0.62), 820)
	height := min(max(400, view_height * 0.68), 600)
	return UI_Rect{(view_width - width) / 2, (view_height - height) / 2, width, height}
}

command_palette_rect :: proc() -> UI_Rect {
	return command_palette_rect_for_size(ui.width, ui.height)
}

command_palette_search_rect :: proc(modal: UI_Rect) -> UI_Rect {
	return UI_Rect{modal.x + 20, modal.y + modal.h - 66, modal.w - 40, 42}
}

command_palette_results_rect :: proc(modal: UI_Rect) -> UI_Rect {
	return UI_Rect{modal.x + 20, modal.y + 42, modal.w - 40, modal.h - 120}
}

command_palette_result_rect :: proc(index: int, modal: UI_Rect) -> UI_Rect {
	content := command_palette_results_rect(modal)
	return UI_Rect{
		content.x,
		content.y + content.h - COMMAND_PALETTE_ROW_HEIGHT - f64(index) * COMMAND_PALETTE_ROW_HEIGHT + ui.command_palette_scroll,
		content.w,
		COMMAND_PALETTE_ROW_HEIGHT,
	}
}

command_palette_visible_count :: proc() -> int {
	return max(1, int(command_palette_results_rect(command_palette_rect()).h / COMMAND_PALETTE_ROW_HEIGHT))
}

command_palette_max_scroll :: proc() -> f64 {
	count := len(command_palette.visible_results(&command_palette_state))
	return max(0, f64(count - command_palette_visible_count()) * COMMAND_PALETTE_ROW_HEIGHT)
}

ensure_command_palette_selection_visible :: proc() {
	selected := command_palette.selected_index(&command_palette_state)
	if selected < 0 {ui.command_palette_scroll = 0; return}
	first := int(ui.command_palette_scroll / COMMAND_PALETTE_ROW_HEIGHT)
	visible := command_palette_visible_count()
	if selected < first {
		ui.command_palette_scroll = f64(selected) * COMMAND_PALETTE_ROW_HEIGHT
	} else if selected >= first + visible {
		ui.command_palette_scroll = f64(selected - visible + 1) * COMMAND_PALETTE_ROW_HEIGHT
	}
	ui.command_palette_scroll = min(max(0, ui.command_palette_scroll), command_palette_max_scroll())
}

source_modal_input_line_count :: proc(input: string) -> int {
	if len(input) == 0 {return 1}
	count := 1
	for character in input {
		if character == '\n' {
			count += 1
			if count == 10 {break}
		}
	}
	return count
}

source_modal_input_rect_for_text :: proc(modal: UI_Rect, input: string) -> UI_Rect {
	height := 32.0 + f64(source_modal_input_line_count(input) - 1) * 23
	return UI_Rect{modal.x + 24, modal.y + modal.h - 180 - height, modal.w - 48, height}
}

source_modal_input_rect :: proc(modal: UI_Rect) -> UI_Rect {
	return source_modal_input_rect_for_text(modal, ui.url_input)
}

source_probe_row_rect :: proc(modal: UI_Rect, index: int) -> UI_Rect {
	input := source_modal_input_rect(modal)
	return UI_Rect{modal.x + 24, input.y - 70 - f64(index) * 68, modal.w - 48, 62}
}

source_probe_quality_rect :: proc(row: UI_Rect, option_index: int) -> UI_Rect {
	return UI_Rect{row.x + 390 + f64(option_index) * 66, row.y + 8, 60, 24}
}

source_modal_cancel_rect :: proc(modal: UI_Rect) -> UI_Rect {
	return UI_Rect{modal.x + 24, modal.y + 24, 124, 34}
}

source_modal_confirm_rect :: proc(modal: UI_Rect) -> UI_Rect {
	return UI_Rect{modal.x + modal.w - 180, modal.y + 24, 156, 34}
}

source_details_rect_for_size :: proc(view_width, view_height: f64) -> UI_Rect {
	width := min(max(560, view_width * 0.52), 720)
	height := min(max(470, view_height * 0.68), 550)
	return UI_Rect{(view_width - width) / 2, (view_height - height) / 2, width, height}
}

source_details_rect :: proc() -> UI_Rect {
	return source_details_rect_for_size(ui.width, ui.height)
}

source_details_close_rect :: proc(modal: UI_Rect) -> UI_Rect {
	return UI_Rect{modal.x + 24, modal.y + 22, 112, 34}
}

source_details_refetch_rect :: proc(modal: UI_Rect) -> UI_Rect {
	return UI_Rect{modal.x + modal.w - 286, modal.y + 22, 262, 34}
}

source_details_row_rect :: proc(modal: UI_Rect, row: int) -> UI_Rect {
	return UI_Rect{modal.x + 24, modal.y + modal.h - 142 - f64(row) * 31, modal.w - 48, 30}
}

close_source_details :: proc() {
	cancel_ui_flash()
	ui.source_details_open = false
	ui.source_details_index = -1
	ui.needs_redraw = true
}

source_details_metadata_changed :: proc() {
	ui.needs_redraw = true
	if !ui.source_details_open || ui.source_details_index < 0 || ui.source_details_index >= len(state.sources) {return}
	source := &state.sources[ui.source_details_index]
	request_source_metadata(source.video_id, source.media_path)
}

open_source_details :: proc(source_index: int) {
	cancel_ui_flash()
	if source_index < 0 || source_index >= len(state.sources) {return}
	if ui.source_details_open {close_source_details()}
	ui.source_details_index = source_index
	ui.source_details_open = true
	ui.focus = .None
	ui.has_marked_text = false
	ui_set_string(&ui.marked_text, "")
	ui.needs_redraw = true
	source := &state.sources[source_index]
	request_source_metadata(source.video_id, source.media_path)
}

open_source_modal :: proc() {
	cancel_ui_flash()
	if ui.source_details_open {close_source_details()}
	ui.source_modal_refetch_index = -1
	ui.source_modal_open = true
	ui.focus = .URL
	if state.window != nil && ui.view != nil {
		msg_void_id(state.window, sel_registerName("makeFirstResponder:"), ui.view)
	}
	ui.needs_redraw = true
	if len(strings.trim_space(ui.url_input)) > 0 && len(source_probe_results) == 0 {schedule_source_probe(1)}
}

open_refetch_source_modal :: proc(source_index: int) {
	cancel_ui_flash()
	if source_index < 0 || source_index >= len(state.sources) {return}
	if ui.source_details_open {close_source_details()}
	ui.source_modal_refetch_index = source_index
	ui.source_modal_open = true
	ui.focus = .None
	ui_set_string(&ui.url_input, state.sources[source_index].url)
	source_probe_results_clear()
	schedule_source_probe(1)
	ui.needs_redraw = true
}

close_source_modal :: proc() {
	cancel_ui_flash()
	ui.source_modal_open = false
	ui.source_modal_refetch_index = -1
	ui.focus = .None
	ui.has_marked_text = false
	ui_set_string(&ui.marked_text, "")
	ui.needs_redraw = true
}

schedule_source_probe :: proc(delay_frames: uint) {
	ui.url_probe_pending = true
	ui.url_probe_due_tick = ui.frame_tick + delay_frames
}

set_ui_mode :: proc(mode: UI_Mode) {
	if ui.mode == mode {return}
	cancel_ui_flash()
	if ui.source_modal_open {close_source_modal()}
	if ui.source_details_open {close_source_details()}
	ui.source_scrubbing = false
	ui.source_hint_menu_open = false
	if mode == .Play {
		metal_player_clear()
	} else {
		ui.active_exercise = -1
		if state.active_source >= 0 && state.active_source < len(state.sources) {
			if metal_player_load(state.sources[state.active_source].media_path) {
				set_source_playback_active(true)
				request_transcript_follow()
			}
		}
	}
	ui.mode = mode
	ui.focus = .None
	ui.has_marked_text = false
	ui_set_string(&ui.marked_text, "")
	normalize_scroll_offsets()
	ui.needs_redraw = true
}

layout_rects :: proc(
) -> (
	import_field,
	import_button,
	source_search,
	source_panel,
	player,
	transcript,
	exercise_search,
	exercise_panel,
	exercise_name,
	controls: UI_Rect,
) {
	w, h := ui.width, ui.height
	margin := 18.0
	gap := 10.0
	footer_h := 74.0

	body_y := margin + footer_h
	body_top := h - APP_HEADER_HEIGHT - 12
	if ui.source_modal_open {
		modal := source_modal_rect()
		import_field = source_modal_input_rect(modal)
		import_button = source_modal_confirm_rect(modal)
	}
	body_h := max(120, body_top - body_y)
	left_w := min(max(w * 0.218, 250), 328)
	right_w := min(max(w * 0.205, 238), 304)
	if ui.mode == .Play {
		left_w = min(max(w * 0.31, 300), 430)
		right_w = left_w
	}
	center_x := margin + left_w + gap
	center_w := max(280, w - margin * 2 - left_w - right_w - gap * 2)
	if ui.mode == .Play {center_w = max(280, w - margin * 2 - left_w - gap)}
	right_x := center_x + center_w + gap

	if ui.mode == .Create {
		source_search = UI_Rect{margin + 8, body_top - 72, left_w - 16, 28}
		source_panel = UI_Rect{margin, body_y, left_w, body_h}
		exercise_name = UI_Rect{right_x + 8, body_top - 72, right_w - 16, 30}
		exercise_panel = UI_Rect{right_x, body_y, right_w, body_h}
		player_h := max(180, body_h * 0.55)
		player = UI_Rect{center_x, body_top - player_h, center_w, player_h}
		transcript = UI_Rect{center_x, body_y, center_w, max(80, body_h - player_h - gap)}
	} else {
		exercise_search = UI_Rect{margin + 8, body_top - 72, left_w - 16, 28}
		exercise_panel = UI_Rect{margin, body_y, left_w, body_h}
		player = UI_Rect{center_x, body_y, center_w, body_h}
	}
	controls = UI_Rect{margin, 42, w - margin * 2, 28}
	return
}

control_action_for_slot :: proc(mode: UI_Mode, slot: int) -> int {
	if mode == .Create {return slot if slot >= 0 && slot < 8 else -1}
	switch slot {
	case 0:
		return 3
	case 1:
		return 4
	case 2:
		return 7
	}
	return -1
}

control_slot_for_action :: proc(mode: UI_Mode, action: int) -> int {
	if mode == .Create {return action if action >= 0 && action < 8 else -1}
	switch action {
	case 3:
		return 0
	case 4:
		return 1
	case 7:
		return 2
	}
	return -1
}

is_paste_shortcut :: proc(key, modifiers: uint) -> bool {
	return key == 9 && modifiers & NSEventModifierFlagCommand != 0
}

is_delete_word_shortcut :: proc(key, modifiers: uint) -> bool {
	return key == 51 && modifiers & NSEventModifierFlagControl != 0
}

NSEventModifierFlagControl :: uint(1 << 18)
NSEventModifierFlagOption  :: uint(1 << 19)
NSEventModifierFlagCommand :: uint(1 << 20)
NSEventModifierFlagShift   :: uint(1 << 17)

command_palette_modifiers :: proc(modifiers: uint) -> command_palette.Modifier_Set {
	result: command_palette.Modifier_Set
	if modifiers & NSEventModifierFlagShift != 0 {result += {.Shift}}
	if modifiers & NSEventModifierFlagControl != 0 {result += {.Control}}
	if modifiers & NSEventModifierFlagOption != 0 {result += {.Option}}
	if modifiers & NSEventModifierFlagCommand != 0 {result += {.Command}}
	return result
}

event_opens_command_palette :: proc(event: Id, modifiers: uint) -> bool {
	characters := msg_id(event, sel_registerName("charactersIgnoringModifiers"))
	text, ok := text_input_string(characters)
	if !ok || len(text) != 1 || text[0] > 127 {return false}
	return command_palette.shortcut_matches(
		command_palette_config,
		text[0],
		command_palette_modifiers(modifiers),
	)
}

flash_leader_allowed :: proc(focus: UI_Focus, modifiers: uint, text: string) -> bool {
	blocked := NSEventModifierFlagControl | NSEventModifierFlagOption | NSEventModifierFlagCommand
	return focus == .None && modifiers & blocked == 0 && text == "/"
}

Text_Input_Key_Disposition :: enum {
	Delete_Word,
	Interpret,
}

/**
 * dispose_focused_text_key chooses how a focused field handles a key event.
 * Motivation: keep Command shortcuts and IME inside AppKit's interpretKeyEvents
 * path instead of reading NSEvent.characters in keyDown.
 */
dispose_focused_text_key :: proc(key, modifiers: uint) -> Text_Input_Key_Disposition {
	if is_delete_word_shortcut(key, modifiers) {return .Delete_Word}
	return .Interpret
}

/**
 * text_event_is_insertable accepts only ordinary printable characters.
 * Motivation: function keys arrive as U+F700..U+F8FF through insertText and
 * must not become replacement glyphs in the focused field.
 */
text_event_is_insertable :: proc(text: string) -> bool {
	if len(text) == 0 {return false}
	for ch in text {
		if ch < 32 || ch == 127 {return false}
		if ch >= 0xF700 && ch <= 0xF8FF {return false}
	}
	return true
}

activity_spinner :: proc(tick: uint) -> string {
	frames := [4]string{"|", "/", "-", "\\"}
	return frames[(tick / 8) % len(frames)]
}

import_cancel_rect :: proc() -> UI_Rect {
	return UI_Rect{max(18, ui.width - 304), 3, 88, 24}
}

control_rect :: proc(controls: UI_Rect, action: int) -> UI_Rect {
	slot := control_slot_for_action(ui.mode, action)
	if slot < 0 {return {}}
	count := 8
	if ui.mode == .Play {count = 3}
	gap := 6.0
	cell_w := (controls.w - gap * f64(count - 1)) / f64(count)
	return UI_Rect{controls.x + f64(slot) * (cell_w + gap), controls.y, cell_w, controls.h}
}

source_content_rect :: proc(source_search, source_panel: UI_Rect) -> UI_Rect {
	top := source_search.y - 8
	return UI_Rect {
		source_panel.x + 6,
		source_panel.y + 8,
		source_panel.w - 12,
		max(0, top - source_panel.y - 8),
	}
}

transcript_content_rect :: proc(transcript: UI_Rect) -> UI_Rect {
	search := transcript_search_rect(transcript)
	return UI_Rect {
		transcript.x + 6,
		transcript.y + 8,
		transcript.w - 12,
		max(0, search.y - transcript.y - 16),
	}
}

transcript_search_rect :: proc(transcript: UI_Rect) -> UI_Rect {
	return UI_Rect{transcript.x + 8, transcript.y + transcript.h - 70, transcript.w - 16, 28}
}

player_content_rect :: proc(player: UI_Rect) -> UI_Rect {
	bottom_metadata_height := 30.0
	if ui.mode == .Create {bottom_metadata_height = 64}
	header_height := 35.0
	return UI_Rect {
		player.x + 1,
		player.y + bottom_metadata_height,
		max(0, player.w - 2),
		max(0, player.h - bottom_metadata_height - header_height - 1),
	}
}

source_timestamp_rect :: proc(player: UI_Rect) -> UI_Rect {
	up := source_volume_up_rect(player)
	return UI_Rect{up.x + up.w + 8, player.y, 140, 30}
}

source_volume_up_rect :: proc(player: UI_Rect) -> UI_Rect {
	value := source_volume_value_rect(player)
	return UI_Rect{value.x + value.w + 4, player.y + 3, 24, 24}
}

source_volume_value_rect :: proc(player: UI_Rect) -> UI_Rect {
	down := source_volume_down_rect(player)
	return UI_Rect{down.x + down.w + 4, player.y, 62, 30}
}

source_volume_down_rect :: proc(player: UI_Rect) -> UI_Rect {
	up := source_speed_up_rect(player)
	return UI_Rect{up.x + up.w + 8, player.y + 3, 24, 24}
}

source_play_pause_rect :: proc(player: UI_Rect) -> UI_Rect {
	return UI_Rect{player.x + 10, player.y + 3, 62, 24}
}

source_stop_rect :: proc(player: UI_Rect) -> UI_Rect {
	play := source_play_pause_rect(player)
	return UI_Rect{play.x + play.w + 6, play.y, 48, play.h}
}

source_reset_rect :: proc(player: UI_Rect) -> UI_Rect {
	stop := source_stop_rect(player)
	return UI_Rect{stop.x + stop.w + 6, stop.y, 92, stop.h}
}

source_hint_option_rect :: proc(player: UI_Rect, option_index, option_count: int) -> UI_Rect {
	button := source_reset_rect(player)
	return UI_Rect{button.x, button.y + button.h + 34 + f64(option_count - option_index - 1) * 28, button.w, 27}
}

source_speed_down_rect :: proc(player: UI_Rect) -> UI_Rect {
	reset := source_reset_rect(player)
	return UI_Rect{reset.x + reset.w + 12, player.y + 3, 24, 24}
}

source_speed_value_rect :: proc(player: UI_Rect) -> UI_Rect {
	down := source_speed_down_rect(player)
	return UI_Rect{down.x + down.w + 4, player.y, 76, 30}
}

source_speed_up_rect :: proc(player: UI_Rect) -> UI_Rect {
	value := source_speed_value_rect(player)
	return UI_Rect{value.x + value.w + 4, player.y + 3, 24, 24}
}

source_timeline_rect :: proc(player: UI_Rect) -> UI_Rect {
	return UI_Rect{player.x + 10, player.y + 38, max(0, player.w - 20), 18}
}

source_timeline_seconds :: proc(point: Point, player: UI_Rect) -> f64 {
	if state.active_source < 0 || state.active_source >= len(state.sources) {return 0}
	timeline := source_timeline_rect(player)
	return timeline_seconds_at_point(point, timeline, state.sources[state.active_source].duration)
}

timeline_seconds_at_point :: proc(point: Point, timeline: UI_Rect, duration: f64) -> f64 {
	if timeline.w <= 0 {return 0}
	ratio := min(max((point.x - timeline.x) / timeline.w, 0), 1)
	return ratio * max(0, duration)
}

seek_source_timeline :: proc(point: Point, player: UI_Rect) {
	if state.player == nil {return}
	seek_seconds(source_timeline_seconds(point, player))
	ui.needs_redraw = true
}

seek_source_timeline_rect :: proc(point: Point, timeline: UI_Rect) {
	if state.player == nil || state.active_source < 0 || state.active_source >= len(state.sources) {return}
	seek_seconds(timeline_seconds_at_point(point, timeline, state.sources[state.active_source].duration))
	ui.needs_redraw = true
}

clamp_volume :: proc(value: f32) -> f32 {
	return min(max(value, 0), 1)
}

volume_percent :: proc(value: f32) -> int {
	return int(clamp_volume(value) * 100 + 0.5)
}

adjust_player_volume :: proc(delta: f32) {
	ui.player_volume = clamp_volume(ui.player_volume + delta)
	if ui.audio_player != nil {
		msg_void_f32(ui.audio_player, sel_registerName("setVolume:"), ui.player_volume)
	}
	ui.needs_redraw = true
}

clamp_playback_rate :: proc(value: f32) -> f32 {
	return min(max(value, 0.1), 2)
}

adjust_playback_rate :: proc(delta: f32) {
	audio_seconds, has_audio_time := metal_audio_current_seconds()
	value := clamp_playback_rate(ui.playback_rate + delta)
	ui.playback_rate = f32(int(value * 10 + 0.5)) / 10
	if ui.audio_pitch != nil {
		msg_void_f32(ui.audio_pitch, sel_registerName("setRate:"), ui.playback_rate)
	}
	if state.player != nil && msg_f32(state.player, sel_registerName("rate")) > 0 {
		if has_audio_time {seek_video_seconds(audio_seconds)}
		msg_void_f32(state.player, sel_registerName("setRate:"), ui.playback_rate)
	}
	ui.needs_redraw = true
}

exercise_content_rect :: proc(exercise_search, exercise_panel, exercise_name: UI_Rect) -> UI_Rect {
	bottom := exercise_panel.y + 8
	if exercise_name.h > 0 {bottom = exercise_name.y + exercise_name.h + 8}
	top := exercise_search.y - 8
	if exercise_search.h <= 0 {top = exercise_panel.y + exercise_panel.h - 43}
	return UI_Rect{exercise_panel.x + 6, bottom, exercise_panel.w - 12, max(0, top - bottom)}
}

bounded_scroll :: proc(
	current, delta: f64,
	item_count: int,
	row_height, row_step, viewport_height: f64,
) -> f64 {
	content_height := 0.0
	if item_count > 0 {
		content_height = row_height + f64(item_count - 1) * row_step
	}
	maximum := max(0, content_height - viewport_height)
	return min(max(current - delta, 0), maximum)
}

filtered_source_count :: proc() -> int {
	count := 0
	for source in state.sources {
		if !source_matches_search(source, ui.source_search) {continue}
		count += 1
	}
	return count
}

source_matches_search :: proc(source: Source_Video, query: string) -> bool {
	if len(query) == 0 {return true}
	lower_query := strings.to_lower(query, context.temp_allocator)
	lower_title := strings.to_lower(source.title, context.temp_allocator)
	if strings.contains(lower_title, lower_query) {return true}
	lower_video_id := strings.to_lower(source.video_id, context.temp_allocator)
	return strings.contains(lower_video_id, lower_query)
}

format_file_size :: proc(bytes: i64) -> string {
	if bytes < 1000 { return fmt.tprintf("%d B", bytes) }
	if bytes < 1_000_000 { return fmt.tprintf("%.1f KB", f64(bytes) / 1000) }
	if bytes < 1_000_000_000 { return fmt.tprintf("%.1f MB", f64(bytes) / 1_000_000) }
	return fmt.tprintf("%.2f GB", f64(bytes) / 1_000_000_000)
}

format_frame_rate :: proc(fps: f64) -> string {
	whole_fps := int(fps)
	if fps == f64(whole_fps) { return fmt.tprintf("%d fps", whole_fps) }
	return fmt.tprintf("%.2f fps", fps)
}

transcript_search_context: match_sorter.Search_Context

transcript_text_value :: proc(segment: ^Transcript_Segment) -> match_sorter.Extracted_Values {
	return match_sorter.single_value(segment.text)
}

transcript_ranked_indices :: proc(
	search: ^match_sorter.Search_Context,
	segments: []Transcript_Segment,
	source_id, query: string,
	allocator := context.allocator,
) -> []int {
	active := make([dynamic]Transcript_Segment, context.temp_allocator)
	global_indices := make([dynamic]int, context.temp_allocator)
	for segment, index in segments {
		if segment.source_id != source_id {continue}
		append(&active, segment)
		append(&global_indices, index)
	}
	if len(query) == 0 {
		result := make([]int, len(global_indices), allocator)
		copy(result, global_indices[:])
		return result
	}
	previous_temp := context.temp_allocator
	defer context.temp_allocator = previous_temp
	keys := []match_sorter.Typed_Key(Transcript_Segment){{getter=transcript_text_value}}
	ranked := match_sorter.match_indices(
		search,
		active[:],
		query,
		match_sorter.Typed_Options(Transcript_Segment){keys=keys},
		context.temp_allocator,
	)
	result := make([]int, len(ranked), allocator)
	for active_index, result_index in ranked {result[result_index] = global_indices[active_index]}
	return result
}

invalidate_transcript_matches :: proc(reset_scroll := true) {
	ui.transcript_matches_dirty = true
	if reset_scroll {ui.transcript_scroll = 0}
	ui.transcript_active_match = -1
	ui.transcript_active_progress = 0
	ui.transcript_follow_pending = true
}

ensure_transcript_matches :: proc() {
	if !ui.transcript_matches_dirty {return}
	clear(&ui.transcript_matches)
	if state.active_source >= 0 && state.active_source < len(state.sources) {
		indices := transcript_ranked_indices(
			&transcript_search_context,
			state.transcripts.segments[:],
			state.sources[state.active_source].id,
			ui.transcript_search,
			context.temp_allocator,
		)
		append(&ui.transcript_matches, ..indices)
	}
	ui.transcript_matches_dirty = false
}

active_segment_count :: proc() -> int {
	ensure_transcript_matches()
	return len(ui.transcript_matches)
}

transcript_playback_match :: proc(
	matches: []int,
	segments: []Transcript_Segment,
	source_id: string,
	seconds: f64,
) -> (match_index: int, progress: f64, found: bool) {
	latest_start := 0.0
	match_index = -1
	for segment_index, result_index in matches {
		if segment_index < 0 || segment_index >= len(segments) {continue}
		segment := segments[segment_index]
		if segment.source_id != source_id || segment.duration_seconds <= 0 {continue}
		end_seconds := segment.start_seconds + segment.duration_seconds
		if seconds < segment.start_seconds || seconds >= end_seconds {continue}
		if found && segment.start_seconds < latest_start {continue}
		found = true
		latest_start = segment.start_seconds
		match_index = result_index
		progress = clamp((seconds-segment.start_seconds)/segment.duration_seconds, 0, 1)
	}
	return
}

transcript_centered_scroll :: proc(match_index, item_count: int, viewport_height: f64) -> f64 {
	if match_index < 0 || match_index >= item_count {return 0}
	desired := f64(match_index)*26 - viewport_height/2 + 12.5
	return bounded_scroll(desired, 0, item_count, 25, 26, viewport_height)
}

transcript_follow_should_center :: proc(
	pending, playing, suspended, search_active, source_playback_active: bool,
) -> bool {
	if search_active || !source_playback_active {return false}
	return pending || playing && !suspended
}

request_transcript_follow :: proc() {
	ui.transcript_follow_suspended = false
	ui.transcript_follow_pending = true
	ui.transcript_has_follow_target = false
	ui.needs_redraw = true
}

request_transcript_follow_to :: proc(seconds: f64) {
	request_transcript_follow()
	ui.transcript_follow_target_seconds = seconds
	ui.transcript_follow_target_deadline = ui.frame_tick + 120
	ui.transcript_has_follow_target = true
}

set_source_playback_active :: proc(active: bool) {
	ui.source_playback_active = active
	ui.transcript_active_match = -1
	ui.transcript_active_progress = 0
	ui.transcript_follow_suspended = false
	ui.transcript_follow_pending = active
	ui.transcript_has_follow_target = false
	ui.needs_redraw = true
}

sync_transcript_playback :: proc() {
	previous_match := ui.transcript_active_match
	ui.transcript_active_match = -1
	ui.transcript_active_progress = 0
	if ui.transcript_has_follow_target && ui.frame_tick >= ui.transcript_follow_target_deadline {
		ui.transcript_has_follow_target = false
	}
	search_active := len(ui.transcript_search) > 0
	if ui.mode != .Create || !ui.source_playback_active || state.player == nil || search_active ||
	   state.active_source < 0 || state.active_source >= len(state.sources) {
		return
	}
	ensure_transcript_matches()
	seconds, has_seconds := current_seconds()
	if !has_seconds {return}
	if ui.transcript_has_follow_target {
		if abs(seconds-ui.transcript_follow_target_seconds) <= 0.05 {
			ui.transcript_has_follow_target = false
		} else {
			seconds = ui.transcript_follow_target_seconds
		}
	}
	source_id := state.sources[state.active_source].id
	match_index, progress, found := transcript_playback_match(
		ui.transcript_matches[:],
		state.transcripts.segments[:],
		source_id,
		seconds,
	)
	if found {
		ui.transcript_active_match = match_index
		ui.transcript_active_progress = progress
	}
	playing := msg_f32(state.player, sel_registerName("rate")) > 0
	if found && transcript_follow_should_center(
		ui.transcript_follow_pending,
		playing,
		ui.transcript_follow_suspended,
		search_active,
		ui.source_playback_active,
	) {
		_, _, _, _, _, transcript, _, _, _, _ := layout_rects()
		content := transcript_content_rect(transcript)
		next_scroll := transcript_centered_scroll(match_index, len(ui.transcript_matches), content.h)
		if next_scroll != ui.transcript_scroll {
			ui.transcript_scroll = next_scroll
			ui.needs_redraw = true
		}
	}
	if ui.transcript_follow_pending {ui.transcript_follow_pending = false}
	if previous_match != ui.transcript_active_match {ui.needs_redraw = true}
}

filtered_exercise_count :: proc() -> int {
	count := 0
	for exercise in state.exercises {
		if len(ui.exercise_search) > 0 &&
		   !strings.contains(exercise.name, ui.exercise_search) {continue}
		count += 1
	}
	return count
}

normalize_scroll_offsets :: proc() {
	_, _, source_search, source_panel, _, transcript, exercise_search, exercise_panel, exercise_name, _ :=
		layout_rects()
	if ui.mode == .Create {
		source_content := source_content_rect(source_search, source_panel)
		transcript_content := transcript_content_rect(transcript)
		ui.source_scroll = bounded_scroll(
			ui.source_scroll,
			0,
			filtered_source_count(),
			29,
			30,
			source_content.h,
		)
		ui.transcript_scroll = bounded_scroll(
			ui.transcript_scroll,
			0,
			active_segment_count(),
			25,
			26,
			transcript_content.h,
		)
	} else {
		exercise_content := exercise_content_rect(exercise_search, exercise_panel, exercise_name)
		ui.exercise_scroll = bounded_scroll(
			ui.exercise_scroll,
			0,
			filtered_exercise_count(),
			29,
			30,
			exercise_content.h,
		)
	}
}

push_rect :: proc(vertices: ^[dynamic]Solid_Vertex, rect: UI_Rect, color: [4]f32) {
	if rect.w <= 0 || rect.h <= 0 || ui.width <= 0 || ui.height <= 0 {return}
	x0 := f32(rect.x / ui.width * 2 - 1)
	x1 := f32((rect.x + rect.w) / ui.width * 2 - 1)
	y0 := f32(rect.y / ui.height * 2 - 1)
	y1 := f32((rect.y + rect.h) / ui.height * 2 - 1)
	v0 := Solid_Vertex{x0, y0, color[0], color[1], color[2], color[3]}
	v1 := Solid_Vertex{x1, y0, color[0], color[1], color[2], color[3]}
	v2 := Solid_Vertex{x1, y1, color[0], color[1], color[2], color[3]}
	v3 := Solid_Vertex{x0, y1, color[0], color[1], color[2], color[3]}
	append(vertices, v0, v1, v2, v0, v2, v3)
}

push_border :: proc(vertices: ^[dynamic]Solid_Vertex, rect: UI_Rect, color: [4]f32) {
	push_rect(vertices, UI_Rect{rect.x, rect.y, rect.w, 1}, color)
	push_rect(vertices, UI_Rect{rect.x, rect.y + rect.h - 1, rect.w, 1}, color)
	push_rect(vertices, UI_Rect{rect.x, rect.y, 1, rect.h}, color)
	push_rect(vertices, UI_Rect{rect.x + rect.w - 1, rect.y, 1, rect.h}, color)
}

texture_rect_vertices :: proc(rect: UI_Rect, color: [4]f32) -> [6]Texture_Vertex {
	x0 := f32(rect.x / ui.width * 2 - 1)
	x1 := f32((rect.x + rect.w) / ui.width * 2 - 1)
	y0 := f32(rect.y / ui.height * 2 - 1)
	y1 := f32((rect.y + rect.h) / ui.height * 2 - 1)
	v0 := Texture_Vertex{x0, y0, 0, 1, color[0], color[1], color[2], color[3]}
	v1 := Texture_Vertex{x1, y0, 1, 1, color[0], color[1], color[2], color[3]}
	v2 := Texture_Vertex{x1, y1, 1, 0, color[0], color[1], color[2], color[3]}
	v3 := Texture_Vertex{x0, y1, 0, 0, color[0], color[1], color[2], color[3]}
	return [6]Texture_Vertex{v0, v1, v2, v0, v2, v3}
}

make_text_run :: proc(font: rawptr, text: string) -> Text_Run {
	run: Text_Run
	if len(text) == 0 {return run}
	assert_foreign(font, "make_text_run requires a valid CTFont")
	bytes := transmute([]u8)text
	string_ref := rawptr(CFStringCreateWithBytes(CF.TypeRef(nil), raw_data(bytes), CF.Index(len(bytes)), CF.StringEncoding(0x08000100), false))
	if string_ref == nil {return run}
	defer CFRelease(string_ref)
	attributed := CFAttributedStringCreateMutable(nil, 0)
	if attributed == nil {return run}
	defer CFRelease(attributed)
	CFAttributedStringReplaceString(attributed, CF_Range{0, 0}, string_ref)
	range := CF_Range{0, CFStringGetLength(string_ref)}
	CFAttributedStringSetAttribute(attributed, range, kCTFontAttributeName, font)
	CFAttributedStringSetAttribute(
		attributed,
		range,
		kCTForegroundColorFromContextAttributeName,
		kCFBooleanTrue,
	)
	standard_ligatures := i32(1)
	ligature_value := CFNumberCreate(nil, 9, &standard_ligatures)
	if ligature_value != nil {
		CFAttributedStringSetAttribute(attributed, range, kCTLigatureAttributeName, ligature_value)
		CFRelease(ligature_value)
	}
	run.line = foreign_created(
		CTLineCreateWithAttributedString(attributed),
		"CTLine",
		"make_text_run",
	)
	if run.line != nil {
		run.advance = CTLineGetTypographicBounds(run.line, &run.ascent, &run.descent, &run.leading)
	}
	return run
}

delete_text_run :: proc(run: ^Text_Run) {
	foreign_release(run.line, "CTLine", "delete_text_run")
	run^ = {}
}

truncated_text_run :: proc(run: Text_Run, font: rawptr, max_width: f64) -> Text_Run {
	if run.line == nil {return {}}
	if run.advance <= max_width {
		result := run
		result.line = foreign_retain(run.line, "CTLine", "truncated_text_run")
		return result
	}
	token := make_text_run(font, "…")
	defer delete_text_run(&token)
	if token.line == nil || token.advance > max_width {return {}}
	truncated: Text_Run
	truncated.line = foreign_created(
		CTLineCreateTruncatedLine(run.line, max_width, 1, token.line),
		"CTLine",
		"truncated_text_run",
	)
	if truncated.line != nil {
		truncated.advance = CTLineGetTypographicBounds(
			truncated.line,
			&truncated.ascent,
			&truncated.descent,
			&truncated.leading,
		)
	}
	return truncated
}

text_run_glyph_count :: proc(run: Text_Run) -> int {
	if run.line == nil {return 0}
	runs := CTLineGetGlyphRuns(run.line)
	if runs == nil {return 0}
	count := 0
	for index in 0 ..< CFArrayGetCount(runs) {
		count += CTRunGetGlyphCount(CFArrayGetValueAtIndex(runs, index))
	}
	return count
}

text_origin :: proc(
	rect: UI_Rect,
	run: Text_Run,
	horizontal, vertical: Text_Align,
	inset: f64 = 0,
) -> Point {
	scaled := UI_Rect{rect.x * ui.scale, rect.y * ui.scale, rect.w * ui.scale, rect.h * ui.scale}
	padding := inset * ui.scale
	x := scaled.x + padding
	#partial switch horizontal {
	case .Center:
		x = scaled.x + (scaled.w - run.advance) / 2
	case .End:
		x = scaled.x + scaled.w - padding - run.advance
	}
	baseline := scaled.y + padding + run.descent
	#partial switch vertical {
	case .Center:
		baseline = scaled.y + (scaled.h - (run.ascent + run.descent)) / 2 + run.descent
	case .End:
		baseline = scaled.y + scaled.h - padding - run.ascent
	}
	return Point{x, baseline}
}

draw_text_run :: proc(ctx: rawptr, run: Text_Run, origin: Point, color: [4]f64) {
	if ctx == nil || run.line == nil {return}
	assert_foreign(ctx, "draw_text_run requires a valid CGContext")
	assert_foreign(run.line, "draw_text_run requires a valid CTLine")
	trace_foreign_lifetime("draw", "CTLine", run.line, "draw_text_run")
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
	if ctx == nil || rect.w <= 0 || rect.h <= 0 || len(text) == 0 {return}
	run := make_text_run(font, text)
	defer delete_text_run(&run)
	available_width := max(0, (rect.w - inset * 2) * ui.scale)
	draw_run := run
	truncated: Text_Run
	if run.advance > available_width {
		truncated = truncated_text_run(run, font, available_width)
		if truncated.line == nil {return}
		draw_run = truncated
	}
	if clip {
		CGContextSaveGState(ctx)
		CGContextClipToRect(
			ctx,
			Rect {
				Point{rect.x * ui.scale, rect.y * ui.scale},
				Size{rect.w * ui.scale, rect.h * ui.scale},
			},
		)
	}
	draw_text_run(ctx, draw_run, text_origin(rect, draw_run, horizontal, vertical, inset), color)
	if clip {CGContextRestoreGState(ctx)}
	delete_text_run(&truncated)
}

draw_editable_text_field :: proc(
	ctx, font: rawptr,
	text, placeholder: string,
	rect: UI_Rect,
	focus: UI_Focus,
	text_color, placeholder_color, caret_color: [4]f64,
	inset := 8.0,
) {
	if ui.focus != focus {
		value := text
		color := text_color
		if len(value) == 0 {value, color = placeholder, placeholder_color}
		draw_text_in_rect(ctx, font, value, rect, .Start, .Center, color, inset)
		return
	}
	run_text := text
	if len(run_text) == 0 {run_text = " "}
	run := make_text_run(font, run_text)
	defer delete_text_run(&run)
	if run.line == nil {return}
	caret := min(max(ui.caret_byte_offset, 0), len(text))
	caret_utf16 := utf16_index_for_byte_offset(text, caret)
	caret_advance := CTLineGetOffsetForStringIndex(run.line, caret_utf16, nil) / ui.scale
	available := max(0, rect.w - inset * 2)
	if caret_advance - ui.text_scroll_x > available {ui.text_scroll_x = caret_advance - available}
	if caret_advance - ui.text_scroll_x < 0 {ui.text_scroll_x = caret_advance}
	origin := text_origin(rect, run, .Start, .Center, inset)
	origin.x -= ui.text_scroll_x * ui.scale
	CGContextSaveGState(ctx)
	CGContextClipToRect(ctx, Rect{Point{rect.x * ui.scale, rect.y * ui.scale}, Size{rect.w * ui.scale, rect.h * ui.scale}})
	if len(text) > 0 {draw_text_run(ctx, run, origin, text_color)}
	caret_x := rect.x + inset + caret_advance - ui.text_scroll_x
	fill_overlay_rect(ctx, UI_Rect{caret_x, rect.y + 5, max(1 / ui.scale, 0.5), max(1, rect.h - 10)}, caret_color)
	CGContextRestoreGState(ctx)
}

place_caret_in_text_field :: proc(text: string, rect: UI_Rect, point: Point, inset := 8.0, base_byte_offset := 0, prefix_bytes := 0) {
	if len(text) == 0 {ui.caret_byte_offset = base_byte_offset; return}
	font_name := CFStringCreateWithCString(nil, UI_FONT_NAME, 0x08000100)
	if font_name == nil {return}
	font := CTFontCreateWithName(font_name, SMALL_FONT_SIZE * ui.scale, nil)
	CFRelease(font_name)
	if font == nil {return}
	defer CFRelease(font)
	run := make_text_run(font, text)
	defer delete_text_run(&run)
	if run.line == nil {return}
	x := max(0, (point.x - rect.x - inset + ui.text_scroll_x) * ui.scale)
	utf16_index := CTLineGetStringIndexForPosition(run.line, Point{x, 0})
	if utf16_index < 0 {utf16_index = utf16_index_for_byte_offset(text, len(text))}
	byte_offset := byte_offset_for_utf16_index(text, utf16_index)
	ui.caret_byte_offset = base_byte_offset + max(0, byte_offset - prefix_bytes)
	ui.needs_redraw = true
}

utf16_index_for_byte_offset :: proc(text: string, byte_offset: int) -> int {
	byte_index, utf16_index := 0, 0
	for byte_index < byte_offset {
		first := text[byte_index]
		byte_count, utf16_count := 1, 1
		if first & 0xf8 == 0xf0 {
			byte_count, utf16_count = 4, 2
		} else if first & 0xf0 == 0xe0 {
			byte_count = 3
		} else if first & 0xe0 == 0xc0 {
			byte_count = 2
		}
		byte_index += byte_count
		utf16_index += utf16_count
	}
	return utf16_index
}

timestamp_fade_ranges :: proc(text: string) -> Timestamp_Fade_Ranges {
	ranges: Timestamp_Fade_Ranges
	index := 0
	for index + 8 <= len(text) && ranges.count < len(ranges.values) {
		is_timestamp :=
			text[index] >= '0' && text[index] <= '9' &&
			text[index + 1] >= '0' && text[index + 1] <= '9' &&
			text[index + 2] == ':' &&
			text[index + 3] >= '0' && text[index + 3] <= '9' &&
			text[index + 4] >= '0' && text[index + 4] <= '9' &&
			text[index + 5] == ':' &&
			text[index + 6] >= '0' && text[index + 6] <= '9' &&
			text[index + 7] >= '0' && text[index + 7] <= '9'
		if !is_timestamp { index += 1; continue }

		fade_bytes := 0
		if text[index:index + 2] == "00" {
			fade_bytes = 3
			if text[index + 3:index + 5] == "00" { fade_bytes = 6 }
		}
		if fade_bytes > 0 {
			start := utf16_index_for_byte_offset(text, index)
			end := utf16_index_for_byte_offset(text, index + fade_bytes)
			ranges.values[ranges.count] = CF_Range{start, end - start}
			ranges.count += 1
		}
		index += 8
	}
	return ranges
}

draw_timestamp_text_in_rect :: proc(
	ctx, font: rawptr,
	text: string,
	rect: UI_Rect,
	horizontal, vertical: Text_Align,
	color: [4]f64,
	inset: f64 = 0,
) {
	if ctx == nil || rect.w <= 0 || rect.h <= 0 || len(text) == 0 { return }
	run := make_text_run(font, text)
	defer delete_text_run(&run)
	available_width := max(0, (rect.w - inset * 2) * ui.scale)
	draw_run := run
	truncated: Text_Run
	if run.advance > available_width {
		truncated = truncated_text_run(run, font, available_width)
		if truncated.line == nil { return }
		draw_run = truncated
	}
	defer delete_text_run(&truncated)

	CGContextSaveGState(ctx)
	defer CGContextRestoreGState(ctx)
	CGContextClipToRect(
		ctx,
		Rect{Point{rect.x * ui.scale, rect.y * ui.scale}, Size{rect.w * ui.scale, rect.h * ui.scale}},
	)
	origin := text_origin(rect, draw_run, horizontal, vertical, inset)
	ranges := timestamp_fade_ranges(text)
	if ranges.count == 0 {
		draw_text_run(ctx, draw_run, origin, color)
		return
	}

	faded_color := color
	faded_color[3] *= 0.5
	draw_text_run(ctx, draw_run, origin, faded_color)
	normal_start := 0
	text_length := utf16_index_for_byte_offset(text, len(text))
	for range_index in 0 ..< ranges.count + 1 {
		normal_end := text_length
		if range_index < ranges.count { normal_end = ranges.values[range_index].location }
		if normal_end > normal_start {
			start_x := origin.x + CTLineGetOffsetForStringIndex(draw_run.line, normal_start, nil)
			end_x := origin.x + CTLineGetOffsetForStringIndex(draw_run.line, normal_end, nil)
			CGContextSaveGState(ctx)
			CGContextClipToRect(
				ctx,
				Rect{Point{start_x, origin.y - draw_run.descent}, Size{max(0, end_x - start_x), draw_run.ascent + draw_run.descent + draw_run.leading}},
			)
			draw_text_run(ctx, draw_run, origin, color)
			CGContextRestoreGState(ctx)
		}
		if range_index < ranges.count {
			normal_start = ranges.values[range_index].location + ranges.values[range_index].length
		}
	}
}

fill_overlay_rect :: proc(ctx: rawptr, rect: UI_Rect, color: [4]f64) {
	CGContextSetRGBFillColor(ctx, color[0], color[1], color[2], color[3])
	CGContextFillRect(
		ctx,
		Rect {
			Point{rect.x * ui.scale, rect.y * ui.scale},
			Size{rect.w * ui.scale, rect.h * ui.scale},
		},
	)
}

fill_overlay_border :: proc(ctx: rawptr, rect: UI_Rect, color: [4]f64) {
	fill_overlay_rect(ctx, UI_Rect{rect.x, rect.y, rect.w, 1}, color)
	fill_overlay_rect(ctx, UI_Rect{rect.x, rect.y + rect.h - 1, rect.w, 1}, color)
	fill_overlay_rect(ctx, UI_Rect{rect.x, rect.y, 1, rect.h}, color)
	fill_overlay_rect(ctx, UI_Rect{rect.x + rect.w - 1, rect.y, 1, rect.h}, color)
}

flash_badge_rect :: proc(target: flash.Target, label_length: int, view_width, view_height: f64) -> UI_Rect {
	width := max(16, 8 + f64(label_length) * 8)
	height := 18.0
	rect := target.rect
	x, y := rect.x + 2, rect.y + rect.h - height - 2
	#partial switch target.anchor {
	case .Top_Right:
		x = rect.x + rect.w - width - 2
	case .Bottom_Left:
		y = rect.y + 2
	case .Bottom_Right:
		x, y = rect.x + rect.w - width - 2, rect.y + 2
	case .Center:
		x, y = rect.x + (rect.w - width) / 2, rect.y + (rect.h - height) / 2
	}
	x = min(max(x, 0), max(0, view_width - width))
	y = min(max(y, 0), max(0, view_height - height))
	return UI_Rect{x, y, width, height}
}

draw_flash_hints :: proc(ctx, font: rawptr) {
	if !flash.is_active(&flash_state) {return}
	background := [4]f64{0.96, 0.94, 0.85, 1}
	foreground := [4]f64{0.025, 0.027, 0.026, 1}
	border := [4]f64{0.02, 0.02, 0.02, 1}
	selected_background := [4]f64{0.98, 0.35, 0.09, 1}
	selected_border := [4]f64{1.0, 0.55, 0.18, 1}
	for &hint in flash.visible_hints(&flash_state) {
		badge := flash_badge_rect(hint.target, len(hint.label), ui.width, ui.height)
		badge_background := hint.selected ? selected_background : background
		badge_border := hint.selected ? selected_border : border
		if hint.selected {
			target := hint.target.rect
			fill_overlay_border(
				ctx,
				UI_Rect{target.x, target.y, target.w, target.h},
				selected_border,
			)
		}
		fill_overlay_rect(ctx, badge, badge_background)
		fill_overlay_border(ctx, badge, badge_border)
		draw_text_in_rect(ctx, font, hint.label, badge, .Center, .Center, foreground)
	}
}

draw_command_palette :: proc(ctx, font: rawptr, bright, muted, dim, orange, cyan: [4]f64) {
	if !command_palette.is_open(&command_palette_state) {return}
	modal := command_palette_rect()
	search := ui_control_rect(.Command_Palette_Search)
	content := command_palette_results_rect(modal)
	fill_overlay_rect(ctx, UI_Rect{0, 0, ui.width, ui.height}, [4]f64{0.008, 0.009, 0.009, 0.88})
	fill_overlay_rect(ctx, modal, [4]f64{0.031, 0.034, 0.032, 1})
	fill_overlay_rect(ctx, search, [4]f64{0.020, 0.022, 0.021, 1})
	fill_overlay_border(ctx, search, orange)
	draw_editable_text_field(
		ctx,
		font,
		ui.command_palette_query,
		"Search commands, sources, and exercises",
		search,
		.Command_Palette,
		bright,
		dim,
		orange,
		12,
	)
	CGContextSaveGState(ctx)
	CGContextClipToRect(
		ctx,
		Rect{
			Point{content.x * ui.scale, content.y * ui.scale},
			Size{content.w * ui.scale, content.h * ui.scale},
		},
	)
	results := command_palette.visible_results(&command_palette_state)
	selected := command_palette.selected_index(&command_palette_state)
	for result, index in results {
		row := ui_control_rect(
			result.available ? .Command_Palette_Result : .Command_Palette_Disabled,
			index,
		)
		if row.y + row.h < content.y || row.y > content.y + content.h {continue}
		if result.available && index == selected {
			fill_overlay_rect(ctx, row, [4]f64{0.095, 0.125, 0.115, 1})
			fill_overlay_rect(ctx, UI_Rect{row.x, row.y, 3, row.h}, orange)
		} else if index % 2 == 0 {
			fill_overlay_rect(ctx, row, [4]f64{0.038, 0.041, 0.039, 1})
		}
		title_color := bright
		detail_color := muted
		if !result.available {
			title_color = dim
			detail_color = orange
		}
		draw_text_in_rect(
			ctx,
			font,
			result.entry.title,
			UI_Rect{row.x + 12, row.y + 22, row.w - 140, 24},
			.Start,
			.Center,
			title_color,
		)
		detail := result.entry.subtitle
		if !result.available {detail = result.entry.unavailable_reason}
		draw_text_in_rect(
			ctx,
			font,
			detail,
			UI_Rect{row.x + 12, row.y + 3, row.w - 24, 20},
			.Start,
			.Center,
			detail_color,
		)
		draw_text_in_rect(
			ctx,
			font,
			result.entry.category,
			UI_Rect{row.x + row.w - 124, row.y + 22, 112, 24},
			.End,
			.Center,
			result.available ? cyan : dim,
		)
	}
	CGContextRestoreGState(ctx)
	if len(results) == 0 {
		draw_text_in_rect(ctx, font, "NO MATCHING COMMANDS OR DATA", content, .Center, .Center, muted)
	}
	draw_text_in_rect(
		ctx,
		font,
		"↑↓ NAVIGATE   RETURN SELECT   ESC CLOSE",
		UI_Rect{modal.x + 20, modal.y + 8, modal.w - 40, 26},
		.End,
		.Center,
		muted,
	)
}

draw_source_details :: proc(ctx, font: rawptr, bright, muted, cyan: [4]f64) {
	if !ui.source_details_open || ui.source_details_index < 0 || ui.source_details_index >= len(state.sources) {return}
	modal := source_details_rect()
	close_button := ui_control_rect(.Close_Source_Details)
	refetch_button := ui_control_rect(.Refetch_Source_Details)
	source := &state.sources[ui.source_details_index]
	metadata := source.metadata
	metadata_ready := source.metadata_status != .Missing
	fill_overlay_rect(ctx, UI_Rect{0, 0, ui.width, ui.height}, [4]f64{0.008, 0.009, 0.009, 0.88})
	fill_overlay_rect(ctx, modal, [4]f64{0.031, 0.034, 0.032, 1})
	header := UI_Rect{modal.x, modal.y + modal.h - 54, modal.w, 54}
	fill_overlay_rect(ctx, header, [4]f64{0.052, 0.055, 0.052, 1})
	draw_text_in_rect(ctx, font, "SOURCE DETAILS / DOWNLOADED MEDIA", UI_Rect{header.x + 20, header.y, header.w - 40, header.h}, .Start, .Center, bright)
	title_color := cyan
	if !source.media_available {title_color = [4]f64{0.95, 0.16, 0.10, 1}}
	draw_text_in_rect(ctx, font, source.title, UI_Rect{modal.x + 24, modal.y + modal.h - 100, modal.w - (source.media_available ? 48 : 164), 28}, .Start, .Center, title_color)
	if !source.media_available {
		draw_text_in_rect(ctx, font, "MEDIA MISSING", UI_Rect{modal.x + modal.w - 146, modal.y + modal.h - 100, 122, 28}, .End, .Center, title_color)
	}

	pending_value := metadata_ready ? "UNAVAILABLE" : "LOADING..."
	resolution := pending_value
	if metadata.width > 0 && metadata.height > 0 {resolution = fmt.tprintf("%d × %d", metadata.width, metadata.height)}
	frame_rate := pending_value
	if metadata.fps > 0 {frame_rate = format_frame_rate(metadata.fps)}
	file_size := pending_value
	if metadata.filesize_approx > 0 {file_size = format_file_size(metadata.filesize_approx)}
	labels := [9]string{"VIDEO ID", "DURATION", "RESOLUTION", "FRAME RATE", "VIDEO CODEC", "AUDIO CODEC", "CONTAINER", "FORMAT ID", "FILE SIZE"}
	video_codec := metadata.vcodec
	if len(video_codec) == 0 {video_codec = pending_value}
	audio_codec := metadata.acodec
	if len(audio_codec) == 0 {audio_codec = pending_value}
	container := metadata.ext
	if len(container) == 0 {container = pending_value}
	format_id := metadata.format_id
	if len(format_id) == 0 {format_id = pending_value}
	values := [9]string{source.video_id, format_timestamp(source.duration), resolution, frame_rate, video_codec, audio_codec, container, format_id, file_size}
	for label, row_index in labels {
		row := source_details_row_rect(modal, row_index)
		if row_index % 2 == 0 {fill_overlay_rect(ctx, row, [4]f64{0.043, 0.046, 0.043, 1})}
		draw_text_in_rect(ctx, font, label, UI_Rect{row.x + 10, row.y, 142, row.h}, .Start, .Center, muted)
		value := values[row_index]
		if len(value) == 0 {value = "UNAVAILABLE"}
		value_rect := UI_Rect{row.x + 160, row.y, row.w - 170, row.h}
		if row_index == 1 {
			draw_timestamp_text_in_rect(ctx, font, value, value_rect, .Start, .Center, bright)
		} else {
			draw_text_in_rect(ctx, font, value, value_rect, .Start, .Center, bright)
		}
	}

	close_color := [4]f64{0.052, 0.055, 0.052, 1}
	if contains(close_button, ui.mouse) {close_color = [4]f64{0.09, 0.095, 0.09, 1}}
	fill_overlay_rect(ctx, close_button, close_color)
	draw_text_in_rect(ctx, font, "CLOSE", close_button, .Center, .Center, muted)
	refetch_color := [4]f64{0.91, 0.31, 0.075, 1}
	if contains(refetch_button, ui.mouse) {refetch_color = [4]f64{1.0, 0.42, 0.10, 1}}
	fill_overlay_rect(ctx, refetch_button, refetch_color)
	fill_overlay_border(ctx, refetch_button, [4]f64{1.0, 0.45, 0.12, 1})
	draw_text_in_rect(ctx, font, "REFETCH / SELECT QUALITY", refetch_button, .Center, .Center, [4]f64{0.08, 0.025, 0.01, 1})
}

build_geometry :: proc(vertices: ^[dynamic]Solid_Vertex) {
	_, _, source_search, source_panel, player, transcript, exercise_search, exercise_panel, exercise_name, _ :=
		layout_rects()
	chassis := [4]f32{0.026, 0.028, 0.027, 1}
	panel := [4]f32{0.041, 0.044, 0.042, 1}
	panel_alt := [4]f32{0.052, 0.055, 0.052, 1}
	field := [4]f32{0.020, 0.022, 0.021, 1}
	border := [4]f32{0.218, 0.225, 0.210, 1}
	rule := [4]f32{0.125, 0.132, 0.123, 1}
	orange := [4]f32{0.91, 0.31, 0.075, 1}
	cyan := [4]f32{0.27, 0.72, 0.73, 1}
	push_rect(vertices, UI_Rect{0, 0, ui.width, ui.height}, chassis)
	push_rect(vertices, app_header_rect(), [4]f32{0.018, 0.020, 0.019, 1})
	mode_rect := ui_control_rect(.Mode_Toggle)
	mode_color := [4]f32{0.15, 0.061, 0.032, 1}
	if contains(mode_rect, ui.mouse) {mode_color = [4]f32{0.23, 0.083, 0.035, 1}}
	push_rect(vertices, mode_rect, mode_color)
	push_border(vertices, mode_rect, orange)
	push_rect(vertices, UI_Rect{mode_rect.x, mode_rect.y, 4, mode_rect.h}, orange)
	panels := [4]UI_Rect{source_panel, player, transcript, exercise_panel}
	for rect in panels {
		if rect.w <= 0 || rect.h <= 0 {continue}
		push_rect(vertices, rect, panel)
		push_rect(vertices, UI_Rect{rect.x, rect.y + rect.h - 34, rect.w, 34}, panel_alt)
	}
	field_kinds := [4]UI_Action_Kind{
		.Source_Search,
		.Transcript_Search,
		.Exercise_Search,
		.Exercise_Name,
	}
	for kind in field_kinds {
		rect := ui_control_rect(kind)
		if rect.w <= 0 || rect.h <= 0 {continue}
		push_rect(vertices, rect, field)
	}
	if ui.mode == .Create && state.player != nil {
		button_kinds := [7]UI_Action_Kind{
			.Volume_Down,
			.Volume_Up,
			.Speed_Down,
			.Speed_Up,
			.Source_Play_Pause,
			.Source_Stop,
			.Source_Reset,
		}
		for kind in button_kinds {
			rect := ui_control_rect(kind)
			if kind == .Source_Reset && rect.w == 0 {rect = ui_control_rect(.Source_Hint_Menu)}
			if rect.w == 0 {continue}
			button_color := field
			if contains(rect, ui.mouse) {button_color = panel_alt}
			push_rect(vertices, rect, button_color)
		}
		timeline := ui_control_rect(.Source_Timeline)
		track := UI_Rect{timeline.x, timeline.y + timeline.h / 2 - 2, timeline.w, 4}
		push_rect(vertices, track, rule)
		if state.active_source >= 0 && state.active_source < len(state.sources) {
			duration := state.sources[state.active_source].duration
			seconds, has_seconds := current_seconds()
			progress := 0.0
			if has_seconds && duration > 0 {progress = min(max(seconds / duration, 0), 1)}
			push_rect(vertices, UI_Rect{track.x, track.y, track.w * progress, track.h}, border)
			thumb_x := track.x + track.w * progress
			push_rect(vertices, UI_Rect{thumb_x - 3, timeline.y + 2, 6, timeline.h - 4}, [4]f32{0.72, 0.72, 0.68, 1})
		}
	}
	if ui.mode == .Create {
		add_rect := ui_control_rect(.Open_Source_Modal)
		add_color := [4]f32{0.15, 0.061, 0.032, 1}
		if contains(add_rect, ui.mouse) {add_color = [4]f32{0.23, 0.083, 0.035, 1}}
		push_rect(vertices, add_rect, add_color)
		push_border(vertices, add_rect, orange)
	}

	if ui.mode == .Create {
		source_content := source_content_rect(source_search, source_panel)
		row := UI_Rect {
			source_content.x,
			source_content.y + source_content.h - 29 + ui.source_scroll,
			source_content.w,
			29,
		}
		for source, index in state.sources {
			if !source_matches_search(source, ui.source_search) {continue}
			control := find_ui_control_by_action_and_index(.Source, index)
			if control != nil {
				row = control.rect
				color := [4]f32{0.046, 0.050, 0.048, 0.96}
				if contains(row, ui.mouse) {color = [4]f32{0.075, 0.081, 0.076, 1}}
				if !source.media_available {
					color = [4]f32{0.16, 0.035, 0.025, 1}
					push_rect(vertices, UI_Rect{row.x, row.y, 3, row.h}, [4]f32{0.95, 0.12, 0.08, 1})
				}
				if index == state.active_source {
					color = [4]f32{0.17, 0.070, 0.035, 1}
					push_rect(vertices, UI_Rect{row.x, row.y, 3, row.h}, orange)
				}
				push_rect(vertices, row, color)
				push_rect(vertices, UI_Rect{row.x, row.y, row.w, 1}, rule)
			}
			row.y -= 30
		}

		transcript_content := transcript_content_rect(transcript)
		row = UI_Rect {
			transcript_content.x,
			transcript_content.y + transcript_content.h - 25 + ui.transcript_scroll,
			transcript_content.w,
			25,
		}
		ensure_transcript_matches()
		for segment_index, result_index in ui.transcript_matches {
			segment := state.transcripts.segments[segment_index]
			control := find_ui_control_by_action_and_index(.Transcript, segment_index)
			if control != nil {
				row = control.rect
				color := [4]f32{0.043, 0.047, 0.045, 0.96}
				active := result_index == ui.transcript_active_match
				if active {color = [4]f32{0.082, 0.046, 0.031, 1}}
				if contains(row, ui.mouse) {color = [4]f32{0.071, 0.078, 0.073, 1}}
				push_rect(vertices, row, color)
				if active {
					progress := clamp(ui.transcript_active_progress, 0, 1)
					push_rect(vertices, UI_Rect{row.x, row.y, row.w*progress, row.h}, [4]f32{0.24, 0.082, 0.026, 1})
					push_rect(vertices, UI_Rect{row.x, row.y, 3, row.h}, orange)
				}
				push_rect(vertices, UI_Rect{row.x, row.y, row.w, 1}, rule)
			}
			row.y -= 26
		}
	}

	if ui.mode == .Play {
		exercise_content := exercise_content_rect(exercise_search, exercise_panel, exercise_name)
		row := UI_Rect {
			exercise_content.x,
			exercise_content.y + exercise_content.h - 29 + ui.exercise_scroll,
			exercise_content.w,
			29,
		}
		for exercise, index in state.exercises {
			if len(ui.exercise_search) > 0 &&
			   !strings.contains(exercise.name, ui.exercise_search) {continue}
			control := find_ui_control_by_action_and_index(.Exercise, index)
			if control != nil {
				row = control.rect
				color := [4]f32{0.046, 0.050, 0.048, 0.96}
				if contains(row, ui.mouse) {color = [4]f32{0.075, 0.081, 0.076, 1}}
				if index == ui.active_exercise {
					color = [4]f32{0.17, 0.070, 0.035, 1}
					push_rect(vertices, UI_Rect{row.x, row.y, 3, row.h}, orange)
				}
				push_rect(vertices, row, color)
				push_rect(vertices, UI_Rect{row.x, row.y, row.w, 1}, rule)
			}
			row.y -= 30
		}
	}

	control_kinds := [8]UI_Action_Kind{.Start, .End, .Save, .Play, .Pause, .Captions, .Preview, .Data}
	for kind, index in control_kinds {
		rect := ui_control_rect(kind)
		if rect.w <= 0 {continue}
		color := panel_alt
		if index == 0 && state.has_start {color = [4]f32{0.035, 0.16, 0.17, 1}}
		if index == 1 && state.has_end {color = [4]f32{0.035, 0.16, 0.17, 1}}
		if index == 2 {color = [4]f32{0.15, 0.061, 0.032, 1}}
		if contains(rect, ui.mouse) {color = [4]f32{0.105, 0.112, 0.104, 1}}
		if index == 2 && contains(rect, ui.mouse) {color = [4]f32{0.23, 0.083, 0.035, 1}}
		push_rect(vertices, rect, color)
	}
	focus_rect := UI_Rect{}
	#partial switch ui.focus {
	case .URL:
		focus_rect = ui_control_rect(.URL)
	case .Source_Search:
		focus_rect = ui_control_rect(.Source_Search)
	case .Transcript_Search:
		focus_rect = ui_control_rect(.Transcript_Search)
	case .Exercise_Search:
		focus_rect = ui_control_rect(.Exercise_Search)
	case .Exercise_Name:
		focus_rect = ui_control_rect(.Exercise_Name)
	}
	if focus_rect.w > 0 {
		push_border(vertices, focus_rect, orange)
		push_rect(vertices, UI_Rect{focus_rect.x, focus_rect.y, 3, focus_rect.h}, orange)
	}
}

build_text_overlay :: proc(width, height: uint) -> []u8 {
	if height == 0 || width > max(uint) / height || width * height > max(uint) / 4 {
		arena_note_failure(&memory.redraw_stats)
		return nil
	}
	pixels, allocation_error := mem_virtual.make(&memory.redraw, []u8, int(width * height * 4))
	if allocation_error != nil {
		arena_note_failure(&memory.redraw_stats)
		return nil
	}
	space := CGColorSpaceCreateDeviceRGB()
	assert_foreign(space, "CGColorSpaceCreateDeviceRGB failed")
	ctx := CGBitmapContextCreate(raw_data(pixels), width, height, 8, width * 4, space, 0x2002)
	CGColorSpaceRelease(space)
	assert_foreign(ctx, "CGBitmapContextCreate failed")
	if ctx == nil {return pixels}
	defer CGContextRelease(ctx)
	CGContextClearRect(ctx, Rect{Point{0, 0}, Size{f64(width), f64(height)}})
	font_name := CFStringCreateWithCString(nil, UI_FONT_NAME, 0x08000100)
	assert_foreign(font_name, "Unable to create the UI font name")
	if font_name == nil {return pixels}
	small_font := CTFontCreateWithName(font_name, SMALL_FONT_SIZE * ui.scale, nil)
	assert_foreign(small_font, "Unable to create the small UI font")
	CFRelease(font_name)
	defer foreign_release(small_font, "CTFont", "build_text_overlay")
	s := ui.scale
	ink := [4]f64{0.89, 0.88, 0.82, 1}
	bright := [4]f64{0.97, 0.95, 0.88, 1}
	muted := [4]f64{0.47, 0.49, 0.46, 1}
	dim := [4]f64{0.31, 0.33, 0.31, 1}
	orange := [4]f64{0.98, 0.35, 0.09, 1}
	success := [4]f64{0.37, 0.78, 0.43, 1}
	cyan := [4]f64{0.27, 0.72, 0.73, 1}
	danger := [4]f64{0.95, 0.16, 0.10, 1}

	_, _, source_search, source_panel, player, transcript, exercise_search, exercise_panel, exercise_name, _ :=
		layout_rects()

	header := app_header_rect()
	title_rect := header
	title_rect.y += 2
	draw_text_in_rect(
		ctx,
		small_font,
		"VOCAL TRAINING",
		title_rect,
		.Start,
		.Center,
		bright,
		86,
	)
	mode_rect := ui_control_rect(.Mode_Toggle)
	mode_text := "MODE / BUILD EXERCISES"
	if ui.mode == .Play {mode_text = "MODE / PRACTICE LIBRARY"}
	draw_text_in_rect(ctx, small_font, mode_text, mode_rect, .Center, .Center, bright)
	source_header := UI_Rect {
		source_panel.x,
		source_panel.y + source_panel.h - 35,
		source_panel.w,
		35,
	}
	player_header := UI_Rect{player.x, player.y + player.h - 35, player.w, 35}
	transcript_header := UI_Rect{transcript.x, transcript.y + transcript.h - 35, transcript.w, 35}
	exercise_header := UI_Rect {
		exercise_panel.x,
		exercise_panel.y + exercise_panel.h - 35,
		exercise_panel.w,
		35,
	}
	if ui.mode == .Create {
		ensure_transcript_matches()
		draw_text_in_rect(
			ctx,
			small_font,
			"01 / SOURCE REGISTER",
			UI_Rect{source_header.x, source_header.y, 142, source_header.h},
			.Start,
			.Center,
			muted,
			10,
		)
		add_rect := ui_control_rect(.Open_Source_Modal)
		draw_text_in_rect(ctx, small_font, "ADD", add_rect, .Center, .Center, bright)
		draw_text_in_rect(
			ctx,
			small_font,
			"02 / SOURCE MONITOR",
			UI_Rect{player_header.x, player_header.y, 146, player_header.h},
			.Start,
			.Center,
			muted,
			10,
		)
		draw_text_in_rect(
			ctx,
			small_font,
			"03 / TIMED TRANSCRIPT",
			UI_Rect{transcript_header.x, transcript_header.y, 164, transcript_header.h},
			.Start,
			.Center,
			muted,
			10,
		)
		draw_text_in_rect(
			ctx,
			small_font,
			"04 / EXERCISE OUTPUT",
			UI_Rect{exercise_header.x, exercise_header.y, 158, exercise_header.h},
			.Start,
			.Center,
			muted,
			10,
		)
	} else {
		draw_text_in_rect(
			ctx,
			small_font,
			"01 / EXERCISE LIBRARY",
			UI_Rect{exercise_header.x, exercise_header.y, 158, exercise_header.h},
			.Start,
			.Center,
			muted,
			10,
		)
		draw_text_in_rect(
			ctx,
			small_font,
			fmt.tprintf("%03d SAVED", len(state.exercises)),
			UI_Rect{exercise_header.x + 164, exercise_header.y, 92, exercise_header.h},
			.Start,
			.Center,
			cyan,
			10,
		)
		draw_text_in_rect(
			ctx,
			small_font,
			"02 / PRACTICE MONITOR",
			UI_Rect{player_header.x, player_header.y, 154, player_header.h},
			.Start,
			.Center,
			muted,
			10,
		)
	}
	if ui.mode == .Create {
		draw_editable_text_field(ctx, small_font, ui.source_search, "/ filter source register", ui_control_rect(.Source_Search), .Source_Search, ink, dim, orange)
		draw_editable_text_field(ctx, small_font, ui.transcript_search, "/ search timed transcript", ui_control_rect(.Transcript_Search), .Transcript_Search, ink, dim, orange)
		draw_editable_text_field(ctx, small_font, ui.exercise_name, "NAME / optional designation", ui_control_rect(.Exercise_Name), .Exercise_Name, ink, dim, orange)
	} else {
		draw_editable_text_field(ctx, small_font, ui.exercise_search, "/ filter exercise library", ui_control_rect(.Exercise_Search), .Exercise_Search, ink, dim, orange)
	}

	if ui.mode == .Create {
		source_content := source_content_rect(source_search, source_panel)
		CGContextSaveGState(ctx)
		CGContextClipToRect(
			ctx,
			Rect {
				Point{source_content.x * s, source_content.y * s},
				Size{source_content.w * s, source_content.h * s},
			},
		)
		row := UI_Rect {
			source_content.x,
			source_content.y + source_content.h - 29 + ui.source_scroll,
			source_content.w,
			29,
		}
		visible_source_index := 1
		for source, index in state.sources {
			if !source_matches_search(source, ui.source_search) {continue}
			control := find_ui_control_by_action_and_index(.Source, index)
			if control != nil {
				row = control.rect
				row_color := ink
				if index == state.active_source {row_color = orange}
				if !source.media_available {row_color = danger}
				draw_text_in_rect(
					ctx,
					small_font,
					fmt.tprintf("%02d", visible_source_index),
					UI_Rect{row.x + 8, row.y, 28, row.h},
					.Start,
					.Center,
					muted,
				)
				draw_text_in_rect(
					ctx,
					small_font,
					source.title,
					UI_Rect{row.x + 42, row.y, row.w - (source.media_available ? 48 : 112), row.h},
					.Start,
					.Center,
					row_color,
				)
				if !source.media_available {
					draw_text_in_rect(ctx, small_font, "MISSING", UI_Rect{row.x + row.w - 70, row.y, 62, row.h}, .End, .Center, danger)
				}
			}
			row.y -= 30
			visible_source_index += 1
		}
		if len(state.sources) == 0 {
			draw_text_in_rect(
				ctx,
				small_font,
				"0000  REGISTER EMPTY",
				UI_Rect {
					source_content.x,
					source_content.y + source_content.h - 29,
					source_content.w,
					29,
				},
				.Start,
				.Center,
				dim,
				8,
			)
		}
		CGContextRestoreGState(ctx)
	}

	if ui.mode == .Create && state.active_source < 0 {
		player_content := player_content_rect(player)
		draw_text_in_rect(
			ctx,
			small_font,
			"NO INPUT SIGNAL",
			UI_Rect {
				player_content.x,
				player_content.y + player_content.h / 2,
				player_content.w,
				24,
			},
			.Center,
			.Center,
			dim,
		)
		draw_text_in_rect(
			ctx,
			small_font,
			"INGEST A SOURCE TO INITIALIZE MONITOR",
			UI_Rect {
				player_content.x,
				player_content.y + player_content.h / 2 - 24,
				player_content.w,
				24,
			},
			.Center,
			.Center,
			muted,
		)
	} else if ui.mode == .Create {
		source := &state.sources[state.active_source]
		volume_down := ui_control_rect(.Volume_Down)
		playing := msg_f32(state.player, sel_registerName("rate")) > 0
		draw_text_in_rect(ctx, small_font, playing ? "PAUSE" : "PLAY", ui_control_rect(.Source_Play_Pause), .Center, .Center, playing ? orange : cyan)
		draw_text_in_rect(ctx, small_font, "STOP", ui_control_rect(.Source_Stop), .Center, .Center, muted)
		hint_count := source_hint_count(state.active_source)
		hint_control := source_hint_control(hint_count)
		if hint_control == .Reset {
			draw_text_in_rect(ctx, small_font, "RESET", ui_control_rect(.Source_Reset), .Center, .Center, muted)
		} else if hint_control == .Menu {
			draw_timestamp_text_in_rect(ctx, small_font, format_timestamp(source_initial_seconds(state.active_source)), ui_control_rect(.Source_Hint_Menu), .Center, .Center, cyan)
		}
		speed_down_color := cyan
		if ui.playback_rate <= 0.1 {speed_down_color = dim}
		draw_text_in_rect(ctx, small_font, "-", ui_control_rect(.Speed_Down), .Center, .Center, speed_down_color)
		draw_text_in_rect(ctx, small_font, fmt.tprintf("SPEED %.1fx", ui.playback_rate), source_speed_value_rect(player), .Center, .Center, cyan)
		speed_up_color := cyan
		if ui.playback_rate >= 2 {speed_up_color = dim}
		draw_text_in_rect(ctx, small_font, "+", ui_control_rect(.Speed_Up), .Center, .Center, speed_up_color)
		volume_color := cyan
		if ui.player_volume <= 0 {volume_color = dim}
		draw_text_in_rect(ctx, small_font, "-", volume_down, .Center, .Center, volume_color)
		draw_text_in_rect(
			ctx,
			small_font,
			fmt.tprintf("VOL %d%%", volume_percent(ui.player_volume)),
			source_volume_value_rect(player),
			.Center,
			.Center,
			cyan,
		)
		volume_up_color := cyan
		if ui.player_volume >= 1 {volume_up_color = dim}
		draw_text_in_rect(
			ctx,
			small_font,
			"+",
			ui_control_rect(.Volume_Up),
			.Center,
			.Center,
			volume_up_color,
		)
		timestamp_rect := source_timestamp_rect(player)
		if seconds, ok := current_seconds(); ok {
			timestamp := fmt.tprintf("%s / %s", format_timestamp(seconds), format_timestamp(source.duration))
			draw_timestamp_text_in_rect(
				ctx,
				small_font,
				timestamp,
				timestamp_rect,
				.Start,
				.Center,
				cyan,
			)
		}
		draw_text_in_rect(
			ctx,
			small_font,
			"MEDIA READY",
			UI_Rect{timestamp_rect.x + timestamp_rect.w + 12, player.y, 100, 30},
			.Start,
			.Center,
			cyan,
		)
		if ui.source_hint_menu_open && hint_control == .Menu {
			values := source_hint_values(state.active_source, context.temp_allocator)
			selected := source_initial_seconds(state.active_source)
			for seconds, option_index in values {
				option := ui_control_rect(.Source_Hint, option_index)
				fill_overlay_rect(ctx, option, [4]f64{0.028, 0.030, 0.029, 1})
				if seconds == selected {fill_overlay_border(ctx, option, cyan)}
				draw_timestamp_text_in_rect(ctx, small_font, format_timestamp(seconds), option, .Center, .Center, seconds == selected ? cyan : bright)
			}
		}
	} else if ui.active_exercise >= 0 && ui.active_exercise < len(state.exercises) {
		exercise := &state.exercises[ui.active_exercise]
		metadata := UI_Rect{player.x, player.y, player.w, 30}
		name_rect := UI_Rect{metadata.x, metadata.y, min(280, max(0, metadata.w - 160)), metadata.h}
		draw_text_in_rect(
			ctx,
			small_font,
			exercise.name,
			name_rect,
			.Start,
			.Center,
			ink,
			10,
		)
		draw_timestamp_text_in_rect(
			ctx,
			small_font,
			format_timestamp(exercise.end_seconds - exercise.start_seconds),
			UI_Rect{name_rect.x + name_rect.w + 12, metadata.y, 120, metadata.h},
			.Start,
			.Center,
			cyan,
			10,
		)
	} else {
		player_content := player_content_rect(player)
		draw_text_in_rect(
			ctx,
			small_font,
			"NO EXERCISE SELECTED",
			UI_Rect {
				player_content.x,
				player_content.y + player_content.h / 2,
				player_content.w,
				24,
			},
			.Center,
			.Center,
			dim,
		)
		draw_text_in_rect(
			ctx,
			small_font,
			"SELECT AN EXERCISE FROM THE LIBRARY",
			UI_Rect {
				player_content.x,
				player_content.y + player_content.h / 2 - 24,
				player_content.w,
				24,
			},
			.Center,
			.Center,
			muted,
		)
	}

	if ui.mode == .Create {
		transcript_content := transcript_content_rect(transcript)
		CGContextSaveGState(ctx)
		CGContextClipToRect(
			ctx,
			Rect {
				Point{transcript_content.x * s, transcript_content.y * s},
				Size{transcript_content.w * s, transcript_content.h * s},
			},
		)
		row := UI_Rect {
			transcript_content.x,
			transcript_content.y + transcript_content.h - 25 + ui.transcript_scroll,
			transcript_content.w,
			25,
		}
		ensure_transcript_matches()
		for transcript_index, result_index in ui.transcript_matches {
			segment := state.transcripts.segments[transcript_index]
			control := find_ui_control_by_action_and_index(.Transcript, transcript_index)
			if control != nil {
					row = control.rect
					draw_text_in_rect(
						ctx,
						small_font,
						fmt.tprintf("%03d", result_index + 1),
						UI_Rect{row.x + 8, row.y, 36, row.h},
						.Start,
						.Center,
						muted,
					)
					draw_timestamp_text_in_rect(
						ctx,
						small_font,
						format_timestamp(segment.start_seconds),
						UI_Rect{row.x + 52, row.y, 68, row.h},
						.Start,
						.Center,
						cyan,
					)
					draw_text_in_rect(
						ctx,
						small_font,
						segment.text,
						UI_Rect{row.x + 126, row.y, row.w - 134, row.h},
						.Start,
						.Center,
						ink,
					)
				}
			row.y -= 26
		}
		if len(ui.transcript_matches) == 0 {
			draw_timestamp_text_in_rect(
				ctx,
				small_font,
				len(ui.transcript_search) > 0 ? "00:00:00  NO TRANSCRIPT MATCHES" : "00:00:00  NO TIMECODE DATA / LOAD CAPTIONS",
				UI_Rect {
					transcript_content.x,
					transcript_content.y + transcript_content.h - 25,
					transcript_content.w,
					25,
				},
				.Start,
				.Center,
				dim,
				8,
			)
		}
		CGContextRestoreGState(ctx)

		output_top := exercise_name.y - 8
		output_content := UI_Rect {
			exercise_panel.x + 6,
			exercise_panel.y + 8,
			exercise_panel.w - 12,
			max(0, output_top - exercise_panel.y - 8),
		}
		draw_text_in_rect(
			ctx,
			small_font,
			"MARK A RANGE, NAME IT, THEN COMMIT",
			UI_Rect {
				output_content.x + 8,
				output_content.y + output_content.h - 42,
				output_content.w - 16,
				24,
			},
			.Start,
			.Center,
			muted,
		)
		draw_timestamp_text_in_rect(
			ctx,
			small_font,
			state.has_start ? fmt.tprintf("IN    %s", format_timestamp(state.range_start)) : "IN    --:--:--",
			UI_Rect {
				output_content.x + 8,
				output_content.y + output_content.h - 78,
				output_content.w - 16,
				24,
			},
			.Start,
			.Center,
			state.has_start ? cyan : dim,
		)
		draw_timestamp_text_in_rect(
			ctx,
			small_font,
			state.has_end ? fmt.tprintf("OUT   %s", format_timestamp(state.range_end)) : "OUT   --:--:--",
			UI_Rect {
				output_content.x + 8,
				output_content.y + output_content.h - 106,
				output_content.w - 16,
				24,
			},
			.Start,
			.Center,
			state.has_end ? cyan : dim,
		)
	}

	if ui.mode == .Play {
		exercise_content := exercise_content_rect(exercise_search, exercise_panel, exercise_name)
		CGContextSaveGState(ctx)
		CGContextClipToRect(
			ctx,
			Rect {
				Point{exercise_content.x * s, exercise_content.y * s},
				Size{exercise_content.w * s, exercise_content.h * s},
			},
		)
		row := UI_Rect {
			exercise_content.x,
			exercise_content.y + exercise_content.h - 29 + ui.exercise_scroll,
			exercise_content.w,
			29,
		}
		exercise_index := 1
		for exercise, index in state.exercises {
			if len(ui.exercise_search) > 0 &&
			   !strings.contains(exercise.name, ui.exercise_search) {continue}
			control := find_ui_control_by_action_and_index(.Exercise, index)
			if control != nil {
				row = control.rect
				row_color := ink
				if index == ui.active_exercise {row_color = orange}
				draw_text_in_rect(
					ctx,
					small_font,
					fmt.tprintf("E%02d", exercise_index),
					UI_Rect{row.x + 8, row.y, 34, row.h},
					.Start,
					.Center,
					muted,
				)
				draw_text_in_rect(
					ctx,
					small_font,
					exercise.name,
					UI_Rect{row.x + 46, row.y, row.w - 52, row.h},
					.Start,
					.Center,
					row_color,
				)
			}
			row.y -= 30
			exercise_index += 1
		}
		if len(state.exercises) == 0 {
			draw_text_in_rect(
				ctx,
				small_font,
				"E00  LIBRARY EMPTY",
				UI_Rect {
					exercise_content.x,
					exercise_content.y + exercise_content.h - 29,
					exercise_content.w,
					29,
				},
				.Start,
				.Center,
				dim,
				8,
			)
		}
		CGContextRestoreGState(ctx)
	}

	labels := [8]string {
		"MARK IN",
		"MARK OUT",
		"COMMIT",
		"RUN",
		"HOLD",
		"CAPTIONS",
		"AUDITION",
		"DATA",
	}
	control_kinds := [8]UI_Action_Kind{.Start, .End, .Save, .Play, .Pause, .Captions, .Preview, .Data}
	for label, i in labels {
		rect := ui_control_rect(control_kinds[i])
		slot := control_slot_for_action(ui.mode, i)
		if slot < 0 {continue}
		draw_text_in_rect(
			ctx,
			small_font,
			fmt.tprintf("%02d", slot + 1),
			UI_Rect{rect.x + 8, rect.y, 24, rect.h},
			.Start,
			.Center,
			muted,
		)
		button_color := ink
		if i == 2 {button_color = orange}
		draw_text_in_rect(
			ctx,
			small_font,
			label,
			UI_Rect{rect.x + 34, rect.y, rect.w - 40, rect.h},
			.Start,
			.Center,
			button_color,
		)
	}

	range_text := "RANGE --:--:-- → --:--:--"
	if state.has_start || state.has_end {
		start_text := state.has_start ? format_timestamp(state.range_start) : "--:--:--"
		end_text := state.has_end ? format_timestamp(state.range_end) : "--:--:--"
		range_text = fmt.tprintf("RANGE %s → %s", start_text, end_text)
	}
	if ui.mode ==
	   .Play {range_text = fmt.tprintf("LIBRARY / %03d EXERCISES", len(state.exercises))}
	footer := UI_Rect{18, 0, ui.width - 36, 30}
	draw_timestamp_text_in_rect(
		ctx,
		small_font,
		range_text,
		UI_Rect{footer.x, footer.y, 300, footer.h},
		.Start,
		.Center,
		state.has_start && state.has_end ? cyan : muted,
	)
	status_rect := UI_Rect{footer.x + 314, footer.y, min(500, max(0, footer.w - 500)), footer.h}
	if import_job != nil {status_rect.w = max(0, import_cancel_rect().x - status_rect.x - 6)}
	status_text := fmt.tprintf("SYS / %s", ui.status)
	status_color := ui.status_error ? danger : (ui.status_success ? success : muted)
	if import_job != nil || export_job != nil {
		fill_overlay_rect(ctx, status_rect, [4]f64{0.12, 0.045, 0.018, 0.88})
		fill_overlay_rect(ctx, UI_Rect{status_rect.x, status_rect.y, 3, status_rect.h}, orange)
		status_text = fmt.tprintf("SYS / [%s] %s", activity_spinner(ui.activity_tick), ui.status)
		status_color = bright
	}
	draw_timestamp_text_in_rect(
		ctx,
		small_font,
		status_text,
		status_rect,
		.Start,
		.Center,
		status_color,
		10,
	)
	if import_job != nil {
		cancel := ui_control_rect(.Stop_Download)
		fill_overlay_rect(ctx, cancel, [4]f64{0.15, 0.035, 0.025, 1})
		fill_overlay_border(ctx, cancel, orange)
		draw_text_in_rect(ctx, small_font, "STOP", cancel, .Center, .Center, bright)
	}
	draw_source_details(ctx, small_font, bright, muted, cyan)

	if ui.source_modal_open {
		modal := source_modal_rect()
		input := ui_control_rect(.URL)
		if input.w == 0 {input = source_modal_input_rect(modal)}
		cancel := ui_control_rect(.Cancel_Source_Modal)
		confirm := ui_control_rect(.Import)
		fill_overlay_rect(
			ctx,
			UI_Rect{0, 0, ui.width, ui.height},
			[4]f64{0.008, 0.009, 0.009, 0.88},
		)
		fill_overlay_rect(ctx, modal, [4]f64{0.041, 0.044, 0.042, 1})
		fill_overlay_rect(
			ctx,
			UI_Rect{modal.x, modal.y + modal.h - 50, modal.w, 50},
			[4]f64{0.052, 0.055, 0.052, 1},
		)
		draw_text_in_rect(
			ctx,
			small_font,
			ui.source_modal_refetch_index >= 0 ? "REFETCH SOURCE / SELECT QUALITY" : "ADD SOURCE / YOUTUBE INGEST",
			UI_Rect{modal.x + 20, modal.y + modal.h - 50, modal.w - 40, 50},
			.Start,
			.Center,
			bright,
		)
		draw_text_in_rect(
			ctx,
			small_font,
			"Paste one YouTube URL per line. Standard youtube.com and youtu.be links are accepted.",
			UI_Rect{modal.x + 24, modal.y + modal.h - 92, modal.w - 48, 22},
			.Start,
			.Center,
			ink,
		)
		draw_text_in_rect(
			ctx,
			small_font,
			"Timestamps in t or start are parsed as the initial playhead position after import.",
			UI_Rect{modal.x + 24, modal.y + modal.h - 116, modal.w - 48, 22},
			.Start,
			.Center,
			muted,
		)
		draw_text_in_rect(
			ctx,
			small_font,
			"Examples: ?t=1m30s  /  ?start=90  /  youtu.be/VIDEO?t=45",
			UI_Rect{modal.x + 24, modal.y + modal.h - 140, modal.w - 48, 22},
			.Start,
			.Center,
			cyan,
		)
		fill_overlay_rect(ctx, input, [4]f64{0.020, 0.022, 0.021, 1})
		if ui.focus == .URL && ui.source_modal_refetch_index < 0 {
			fill_overlay_border(ctx, input, orange)
		}
		if len(ui.url_input) == 0 {
			draw_text_in_rect(
				ctx,
				small_font,
				"$ paste URL(s) here",
				UI_Rect{input.x + 12, input.y + input.h - 30, input.w - 24, 22},
				.Start,
				.Center,
				dim,
			)
		} else {
			line_y := input.y + input.h - 30
			lines := strings.split_lines(ui.url_input)
			caret_line, line_start := 0, 0
			for index in 0 ..< min(ui.caret_byte_offset, len(ui.url_input)) {
				if ui.url_input[index] == '\n' {caret_line += 1; line_start = index + 1}
			}
			first_line := min(max(0, caret_line - 9), max(0, len(lines) - 10))
			visible_line_start := 0
			for index in 0 ..< first_line {visible_line_start += len(lines[index]) + 1}
			for line, visible_index in lines[first_line:] {
				field := UI_Rect{input.x + 12, line_y, input.w - 24, 22}
				line_index := first_line + visible_index
				if ui.focus == .URL && line_index == caret_line {
					saved_caret := ui.caret_byte_offset
					ui.caret_byte_offset = 2 + saved_caret - line_start
					draw_editable_text_field(ctx, small_font, fmt.tprintf("$ %s", line), "", field, .URL, ink, dim, orange, 0)
					ui.caret_byte_offset = saved_caret
				} else {
					draw_text_in_rect(ctx, small_font, fmt.tprintf("$ %s", line), field, .Start, .Center, ink)
				}
				visible_line_start += len(line) + 1
				line_y -= 23
			}
		}
		if source_probe_job != nil && len(source_probe_results) == 0 {
			draw_text_in_rect(ctx, small_font, fmt.tprintf("[%s] CHECKING METADATA AND FORMATS", activity_spinner(ui.activity_tick)), source_probe_row_rect(modal, 0), .Start, .Center, muted, 10)
		} else {
			for result, result_index in source_probe_results {
				if result_index >= 5 {break}
				row := source_probe_row_rect(modal, result_index)
				fill_overlay_rect(ctx, row, [4]f64{0.028, 0.030, 0.029, 1})
				if len(result.error) > 0 {
					draw_text_in_rect(ctx, small_font, fmt.tprintf("%s / %s", result.video_id, result.error), UI_Rect{row.x + 10, row.y, row.w - 20, row.h}, .Start, .Center, orange, 10)
					continue
				}
				draw_text_in_rect(ctx, small_font, result.title, UI_Rect{row.x + 10, row.y + 30, 370, 24}, .Start, .Center, bright, 10)
				draw_text_in_rect(ctx, small_font, fmt.tprintf("%s / %s", result.video_id, format_timestamp(result.duration)), UI_Rect{row.x + 10, row.y + 6, 370, 22}, .Start, .Center, muted, 10)
				for height, option_index in result.heights {
					quality := ui_control_rect_by_value(.Source_Quality, result_index, height)
					if quality.w == 0 {break}
					selected := height == result.selected_height
					fill_overlay_rect(ctx, quality, selected ? [4]f64{0.08, 0.18, 0.18, 1} : [4]f64{0.035, 0.038, 0.036, 1})
					if selected {fill_overlay_border(ctx, quality, cyan)}
					draw_text_in_rect(ctx, small_font, fmt.tprintf("%dp", height), quality, .Center, .Center, selected ? cyan : muted)
				}
			}
		}
		cancel_color := [4]f64{0.052, 0.055, 0.052, 1}
		if contains(cancel, ui.mouse) {cancel_color = [4]f64{0.09, 0.095, 0.09, 1}}
		fill_overlay_rect(ctx, cancel, cancel_color)
		draw_text_in_rect(ctx, small_font, "CANCEL", cancel, .Center, .Center, muted)
		confirm_color := [4]f64{0.91, 0.31, 0.075, 1}
		if contains(confirm, ui.mouse) {confirm_color = [4]f64{1.0, 0.42, 0.10, 1}}
		fill_overlay_rect(ctx, confirm, confirm_color)
		fill_overlay_border(ctx, confirm, [4]f64{1.0, 0.45, 0.12, 1})
		draw_text_in_rect(
			ctx,
			small_font,
			ui.source_modal_refetch_index >= 0 ? "REFETCH" : "ADD SOURCE",
			confirm,
			.Center,
			.Center,
			[4]f64{0.08, 0.025, 0.01, 1},
		)
		draw_text_in_rect(
			ctx,
			small_font,
			fmt.tprintf("SYS / %s", ui.status),
			UI_Rect {
				cancel.x + cancel.w + 16,
				cancel.y,
				confirm.x - cancel.x - cancel.w - 32,
				cancel.h,
			},
			.Start,
			.Center,
			ui.status_error ? danger : (ui.status_success ? success : muted),
		)
	}
	draw_command_palette(ctx, small_font, bright, muted, dim, orange, cyan)
	draw_flash_hints(ctx, small_font)
	return pixels
}

ensure_text_texture :: proc(width, height: uint) -> bool {
	if ui.text_texture != nil && ui.text_width == width && ui.text_height == height {return false}
	desc := msg_id_u_u_u_b(
		objc_getClass("MTLTextureDescriptor"),
		sel_registerName("texture2DDescriptorWithPixelFormat:width:height:mipmapped:"),
		80,
		width,
		height,
		false,
	)
	texture := msg_id_id(ui.device, sel_registerName("newTextureWithDescriptor:"), desc)
	if texture == nil {
		ui.needs_redraw = true
		return false
	}
	if ui.text_texture != nil {msg_void(ui.text_texture, sel_registerName("release"))}
	ui.text_texture = texture
	ui.text_width, ui.text_height = width, height
	return true
}

encode_texture :: proc(encoder, texture: Id, rect: UI_Rect, alpha: f32) {
	if texture == nil {return}
	vertices := texture_rect_vertices(rect, [4]f32{1, 1, 1, alpha})
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

ax_screen_rect :: proc(rect: UI_Rect) -> Rect {
	view_rect := Rect{Point{rect.x, rect.y}, Size{rect.w, rect.h}}
	window_rect := msg_rect_rect_id(
		ui.view,
		sel_registerName("convertRect:toView:"),
		view_rect,
		nil,
	)
	return msg_rect_rect(state.window, sel_registerName("convertRectToScreen:"), window_rect)
}

ui_control_id :: proc(functional_name: string) -> UI_Control_ID {
	value := hash.fnv64a(transmute([]byte)functional_name)
	if value == 0 {value = 1}
	return UI_Control_ID(value)
}

find_ui_control :: proc(id: UI_Control_ID) -> ^UI_Control {
	if id == 0 {return nil}
	for &control in ui_build.controls {
		if control.id == id {return &control}
	}
	return nil
}

find_ui_control_by_action :: proc(kind: UI_Action_Kind) -> ^UI_Control {
	for &control in ui_build.controls {
		if control.action.kind == kind {return &control}
	}
	return nil
}

find_ui_control_by_action_and_index :: proc(kind: UI_Action_Kind, index: int) -> ^UI_Control {
	for &control in ui_build.controls {
		if control.action.kind == kind && control.action.index == index {return &control}
	}
	return nil
}

ui_control_rect :: proc(kind: UI_Action_Kind, index: int = -1) -> UI_Rect {
	control: ^UI_Control
	if index < 0 {
		control = find_ui_control_by_action(kind)
	} else {
		control = find_ui_control_by_action_and_index(kind, index)
	}
	if control == nil {return {}}
	return control.rect
}

ui_control_rect_by_value :: proc(
	kind: UI_Action_Kind,
	index, value: int,
) -> UI_Rect {
	for &control in ui_build.controls {
		if control.action.kind == kind &&
		   control.action.index == index &&
		   control.action.value == value {
			return control.rect
		}
	}
	return {}
}

find_ui_control_at_point :: proc(
	controls: []UI_Control,
	point: Point,
	required_flag: UI_Control_Flag,
) -> ^UI_Control {
	for index := len(controls) - 1; index >= 0; index -= 1 {
		control := &controls[index]
		if required_flag not_in control.flags || .Enabled not_in control.flags {continue}
		if contains(control.rect, point) {return control}
	}
	return nil
}

ui_controls_valid :: proc(controls: []UI_Control) -> bool {
	for &control, index in controls {
		if control.id == 0 || len(control.functional_name) == 0 {return false}
		if control.rect.w <= 0 || control.rect.h <= 0 {return false}
		for other_index in index + 1 ..< len(controls) {
			other := &controls[other_index]
			if control.id == other.id {return false}
			if control.functional_name == other.functional_name {return false}
		}
	}
	return true
}

validate_ui_controls :: proc() {
	when ODIN_DEBUG {
		assert(ui_controls_valid(ui_build.controls[:]), "UI controls must have unique names, unique identifiers, and visible rectangles")
	}
}

add_ax_element :: proc(
	array, element_class: Id,
	label, role: string,
	rect: UI_Rect,
	kind: UI_Action_Kind,
	index: int = 0,
	seconds: f64 = 0,
	value: int = 0,
	anchor: flash.Anchor = .Top_Left,
	flash_label: string = "",
	functional_name: string = "",
) {
	keyboard_label := flash_label
	if len(keyboard_label) == 0 {keyboard_label = label}
	stable_name := functional_name
	if len(stable_name) == 0 {stable_name = keyboard_label}
	flags: UI_Control_Flags = {.Accessibility}
	if kind != .Command_Palette_Disabled {
		flags += {.Enabled, .Flash, .Primary_Press}
	}
	if kind == .Open_Source_Details {
		flags -= {.Primary_Press}
		flags += {.Secondary_Press}
	}
	#partial switch kind {
	case .Command_Palette_Search, .URL, .Source_Search, .Transcript_Search, .Exercise_Search, .Exercise_Name:
		flags += {.Editable}
	}
	control := UI_Control {
		id = ui_control_id(stable_name),
		functional_name = stable_name,
		flash_label = keyboard_label,
		accessibility_label = label,
		accessibility_role = role,
		rect = rect,
		anchor = anchor,
		flags = flags,
		action = UI_Action{kind = kind, index = index, value = value, seconds = seconds},
	}
	append(&ui_build.controls, control)
	if array == nil {return}
	element := msg_id(element_class, sel_registerName("new"))
	msg_void_id(element, sel_registerName("setAccessibilityParent:"), ui.view)
	msg_void_id(element, sel_registerName("setAccessibilityRole:"), nsstring(role))
	msg_void_id(element, sel_registerName("setAccessibilityLabel:"), nsstring(label))
	msg_void_rect(element, sel_registerName("setAccessibilityFrame:"), ax_screen_rect(rect))
	msg_void_id(array, sel_registerName("addObject:"), element)
	append(
		&ax_actions,
		AX_Action{element = element, control_id = control.id},
	)
	msg_void(element, sel_registerName("release"))
}

add_pointer_control :: proc(
	functional_name: string,
	rect: UI_Rect,
	kind: UI_Action_Kind,
	flags: UI_Control_Flags,
) {
	append(&ui_build.controls, UI_Control{
		id = ui_control_id(functional_name),
		functional_name = functional_name,
		rect = rect,
		flags = flags + {.Enabled},
		action = UI_Action{kind = kind},
	})
}

build_ui_controls :: proc(rebuild_accessibility: bool, allocator := context.allocator) {
	previous_temp := context.temp_allocator
	defer context.temp_allocator = previous_temp
	context.temp_allocator = allocator
	ui_build.controls = make([dynamic]UI_Control, 0, 64, allocator)
	array: Id
	if rebuild_accessibility {
		clear(&ax_actions)
		if ui.ax_children != nil {msg_void(ui.ax_children, sel_registerName("release"))}
		temporary := msg_id(objc_getClass("NSMutableArray"), sel_registerName("array"))
		ui.ax_children = msg_id(temporary, sel_registerName("retain"))
		array = temporary
	}
	element_class := objc_getClass("VocalAccessibilityElement")
	import_field, import_button, source_search, source_panel, player, transcript, exercise_search, exercise_panel, exercise_name, controls :=
		layout_rects()
	if command_palette.is_open(&command_palette_state) {
		modal := command_palette_rect()
		add_ax_element(
			array,
			element_class,
			"Search commands, sources, and exercises",
			"AXTextField",
			command_palette_search_rect(modal),
			.Command_Palette_Search,
			flash_label = "command palette search",
		)
		content := command_palette_results_rect(modal)
		for result, index in command_palette.visible_results(&command_palette_state) {
			row := command_palette_result_rect(index, modal)
			if row.y + row.h < content.y || row.y > content.y + content.h {continue}
			label := fmt.tprintf("%s, %s", result.entry.category, result.entry.title)
			if !result.available {
				label = fmt.tprintf("%s, unavailable, %s", label, result.entry.unavailable_reason)
			}
			add_ax_element(
				array,
				element_class,
				label,
				result.available ? "AXButton" : "AXStaticText",
				row,
				result.available ? .Command_Palette_Result : .Command_Palette_Disabled,
				index,
				flash_label = "palette result",
				functional_name = fmt.tprintf("palette result %d", result.entry.id),
			)
		}
		validate_ui_controls()
		return
	}
	if import_job != nil {
		add_ax_element(array, element_class, "Stop download", "AXButton", import_cancel_rect(), .Stop_Download, flash_label = "stop download")
		validate_ui_controls()
		return
	}
	if ui.source_modal_open {
		refetching := ui.source_modal_refetch_index >= 0
		if ui.source_modal_refetch_index < 0 {
			add_ax_element(array, element_class, "YouTube URLs", "AXTextField", import_field, .URL, flash_label = "youtube urls")
		}
		modal := source_modal_rect()
		for result, result_index in source_probe_results {
			if result_index >= 5 {break}
			row := source_probe_row_rect(modal, result_index)
			for height, option_index in result.heights {
				quality := source_probe_quality_rect(row, option_index)
				if quality.x + quality.w > row.x + row.w - 8 {break}
				add_ax_element(
					array,
					element_class,
					fmt.tprintf("Download %s at %dp", result.title, height),
					"AXButton",
					quality,
					.Source_Quality,
					result_index,
					value = height,
					flash_label = "quality",
					functional_name = fmt.tprintf("quality %dp %s", height, result.video_id),
				)
			}
		}
		add_ax_element(
			array,
			element_class,
			refetching ? "Cancel refetch" : "Cancel adding source",
			"AXButton",
			source_modal_cancel_rect(modal),
			.Cancel_Source_Modal,
			flash_label = refetching ? "cancel refetch" : "cancel source ingest",
		)
		add_ax_element(array, element_class, refetching ? "Refetch source" : "Add source", "AXButton", import_button, .Import, flash_label = refetching ? "refetch source" : "import source")
		validate_ui_controls()
		return
	}
	if ui.source_details_open {
		modal := source_details_rect()
		add_ax_element(array, element_class, "Close source details", "AXButton", source_details_close_rect(modal), .Close_Source_Details, flash_label = "close source details")
		add_ax_element(array, element_class, "Refetch and select quality", "AXButton", source_details_refetch_rect(modal), .Refetch_Source_Details, flash_label = "refetch quality")
		validate_ui_controls()
		return
	}
	toggle_label := "Switch to Play mode"
	if ui.mode == .Play {toggle_label = "Switch to Create mode"}
	add_ax_element(
		array,
		element_class,
		toggle_label,
		"AXButton",
		mode_button_rect(),
		.Mode_Toggle,
		flash_label = "switch application mode",
	)
	if ui.mode == .Create {
		add_ax_element(
			array,
			element_class,
			"Add source",
			"AXButton",
			source_add_button_rect(source_panel),
			.Open_Source_Modal,
			flash_label = "add source",
		)
		add_ax_element(
			array,
			element_class,
			"Filter sources",
			"AXTextField",
			source_search,
			.Source_Search,
			flash_label = "filter source register",
		)
		add_ax_element(array, element_class, "Search timed transcript", "AXTextField", transcript_search_rect(transcript), .Transcript_Search, flash_label = "search timed transcript")
		source_content := source_content_rect(source_search, source_panel)
		row := UI_Rect {
			source_content.x,
			source_content.y + source_content.h - 29 + ui.source_scroll,
			source_content.w,
			29,
		}
		for source, index in state.sources {
			if !source_matches_search(source, ui.source_search) {continue}
			if row.y >= source_content.y && row.y + row.h <= source_content.y + source_content.h {
				add_ax_element(
					array,
					element_class,
					source.title,
					"AXButton",
					row,
					.Source,
					index,
					flash_label = "select source",
					functional_name = fmt.tprintf("select source %s", source.id),
				)
				add_ax_element(
					array,
					element_class,
					fmt.tprintf("Open details for %s", source.title),
					"AXButton",
					row,
					.Open_Source_Details,
					index,
					anchor = .Top_Right,
					flash_label = "source details",
					functional_name = fmt.tprintf("source details %s", source.id),
				)
			}
			row.y -= 30
		}
		transcript_content := transcript_content_rect(transcript)
		row = UI_Rect {
			transcript_content.x,
			transcript_content.y + transcript_content.h - 25 + ui.transcript_scroll,
			transcript_content.w,
			25,
		}
		ensure_transcript_matches()
		for segment_index in ui.transcript_matches {
			segment := state.transcripts.segments[segment_index]
			if row.y >= transcript_content.y &&
				   row.y + row.h <= transcript_content.y + transcript_content.h {
					label := fmt.tprintf("%s, %s", format_timestamp(segment.start_seconds), segment.text)
					add_ax_element(
						array,
						element_class,
						label,
						"AXButton",
						row,
						.Transcript,
						segment_index,
						seconds = segment.start_seconds,
						flash_label = "transcript segment",
						functional_name = fmt.tprintf("transcript segment %s", segment.id),
					)
				}
			row.y -= 26
		}
		add_ax_element(
			array,
			element_class,
			"Exercise name",
			"AXTextField",
			exercise_name,
			.Exercise_Name,
			flash_label = "exercise name",
		)
	} else {
		add_ax_element(
			array,
			element_class,
			"Filter exercises",
			"AXTextField",
			exercise_search,
			.Exercise_Search,
			flash_label = "filter exercises",
		)
		exercise_content := exercise_content_rect(exercise_search, exercise_panel, exercise_name)
		row := UI_Rect {
			exercise_content.x,
			exercise_content.y + exercise_content.h - 29 + ui.exercise_scroll,
			exercise_content.w,
			29,
		}
		for exercise, index in state.exercises {
			if len(ui.exercise_search) > 0 &&
			   !strings.contains(exercise.name, ui.exercise_search) {continue}
			if row.y >= exercise_content.y &&
			   row.y + row.h <= exercise_content.y + exercise_content.h {
				add_ax_element(
					array,
					element_class,
					exercise.name,
					"AXButton",
					row,
					.Exercise,
					index,
					flash_label = "select exercise",
					functional_name = fmt.tprintf("select exercise %s", exercise.id),
				)
			}
			row.y -= 30
		}
	}
	if ui.mode == .Create && state.player != nil {
		playing := msg_f32(state.player, sel_registerName("rate")) > 0
		add_pointer_control("toggle playback from player surface", player, .Player_Surface, {.Primary_Press})
		add_pointer_control("scrub source timeline", source_timeline_rect(player), .Source_Timeline, {.Primary_Press, .Drag})
		add_ax_element(array, element_class, playing ? "Pause source" : "Play source", "AXButton", source_play_pause_rect(player), .Source_Play_Pause, flash_label = "play pause source")
		add_ax_element(array, element_class, "Stop source and return to zero", "AXButton", source_stop_rect(player), .Source_Stop, flash_label = "stop source")
		hint_count := source_hint_count(state.active_source)
		hint_control := source_hint_control(hint_count)
		if hint_control == .Reset {
			add_ax_element(array, element_class, "Return to the imported source timestamp", "AXButton", source_reset_rect(player), .Source_Reset, flash_label = "reset source timestamp")
		} else if hint_control == .Menu {
			add_ax_element(array, element_class, fmt.tprintf("Source timestamp %s", format_timestamp(source_initial_seconds(state.active_source))), "AXButton", source_reset_rect(player), .Source_Hint_Menu, flash_label = "select source timestamp")
			if ui.source_hint_menu_open {
				values := source_hint_values(state.active_source, context.temp_allocator)
				for seconds, option_index in values {
					add_ax_element(
						array,
						element_class,
						format_timestamp(seconds),
						"AXButton",
						source_hint_option_rect(player, option_index, len(values)),
						.Source_Hint,
						option_index,
						seconds,
						flash_label = "timestamp",
						functional_name = fmt.tprintf("timestamp %s", format_timestamp(seconds)),
					)
				}
			}
		}
		add_ax_element(array, element_class, "Decrease source playback speed", "AXButton", source_speed_down_rect(player), .Speed_Down, flash_label = "slower")
		add_ax_element(array, element_class, "Increase source playback speed", "AXButton", source_speed_up_rect(player), .Speed_Up, flash_label = "faster")
		percent := volume_percent(ui.player_volume)
		add_ax_element(
			array,
			element_class,
			fmt.tprintf("Decrease source volume, %d percent", percent),
			"AXButton",
			source_volume_down_rect(player),
			.Volume_Down,
			flash_label = "quieter",
		)
		add_ax_element(
			array,
			element_class,
			fmt.tprintf("Increase source volume, %d percent", percent),
			"AXButton",
			source_volume_up_rect(player),
			.Volume_Up,
			flash_label = "louder",
		)
	}
	kinds := [8]UI_Action_Kind{.Start, .End, .Save, .Play, .Pause, .Captions, .Preview, .Data}
	labels := [8]string {
		"Set start",
		"Set end",
		"Save exercise",
		"Play",
		"Pause",
		"Load captions",
		"Preview range",
		"Open data folder",
	}
	flash_labels := [8]string{"mark in", "mark out", "commit", "run", "hold", "captions", "audition", "data"}
	for kind, index in kinds {
		rect := control_rect(controls, index)
		if rect.w > 0 {add_ax_element(array, element_class, labels[index], "AXButton", rect, kind, flash_label = flash_labels[index])}
	}
	validate_ui_controls()
}

cancel_ui_flash :: proc() {
	if !flash.is_active(&flash_state) {return}
	flash.cancel(&flash_state)
	ui.needs_redraw = true
}

flash_target_label :: proc(control: ^UI_Control) -> string {
	label := control.flash_label
	if len(label) == 0 {label = control.functional_name}
	if flash.label_is_valid(label) {return label}
	return fmt.tprintf(
		"control %v %d %d",
		control.action.kind,
		control.action.index,
		control.action.value,
	)
}

begin_ui_flash :: proc() -> bool {
	targets := make([dynamic]flash.Target, 0, len(ui_build.controls), context.temp_allocator)
	for &control in ui_build.controls {
		if .Flash not_in control.flags || .Enabled not_in control.flags {continue}
		append(&targets, flash.Target{
			id = flash.Target_ID(control.id),
			label = flash_target_label(&control),
			rect = flash.Rect{control.rect.x, control.rect.y, control.rect.w, control.rect.h},
			anchor = control.anchor,
		})
	}
	error := flash.begin(&flash_state, targets[:])
	if error != .None {
		#partial switch error {
		case .Invalid_Target_Label:
			set_error_status("Flash target has no letters or digits")
		}
	}
	ui.needs_redraw = true
	return error == .None && flash.is_active(&flash_state)
}

activate_flash_target :: proc(id: flash.Target_ID) -> bool {
	control := find_ui_control(UI_Control_ID(id))
	if control == nil || .Enabled not_in control.flags {return false}
	return activate_ui_action(control.action)
}

find_ax_control :: proc(element: Id) -> ^UI_Control {
	for &binding in ax_actions {
		if binding.element == element {return find_ui_control(binding.control_id)}
	}
	return nil
}

activate_ui_action :: proc(action: UI_Action) -> bool {
	#partial switch action.kind {
	case .Command_Palette_Search:
		focus_text_input(.Command_Palette)
	case .Command_Palette_Result:
		return activate_command_palette_result(action.index)
	case .Command_Palette_Disabled:
		return false
	case .Mode_Toggle:
		set_ui_mode(ui.mode == .Create ? .Play : .Create)
	case .Open_Source_Modal:
		open_source_modal()
	case .Cancel_Source_Modal:
		close_source_modal()
	case .Close_Source_Details:
		close_source_details()
	case .Refetch_Source_Details:
		open_refetch_source_modal(ui.source_details_index)
	case .Open_Source_Details:
		open_source_details(action.index)
	case .URL:
		focus_text_input(.URL)
	case .Import:
		on_import(nil, nil, nil)
	case .Source_Quality:
		if action.index >= 0 && action.index < len(source_probe_results) {
			source_probe_results[action.index].selected_height = action.value
		}
	case .Stop_Download:
		if import_job != nil {
			import_job_cancel(import_job)
			set_text(state.status, "Stopping download...")
		}
	case .Source_Search:
		focus_text_input(.Source_Search)
	case .Transcript_Search:
		focus_text_input(.Transcript_Search)
	case .Source:
		ui_event_tag = action.index
		on_select_source(nil, nil, nil)
	case .Transcript:
		seek_seconds(action.seconds)
	case .Exercise_Search:
		focus_text_input(.Exercise_Search)
	case .Exercise:
		ui_event_tag = action.index
		on_play_exercise(nil, nil, nil)
	case .Exercise_Name:
		focus_text_input(.Exercise_Name)
	case .Volume_Down:
		adjust_player_volume(-0.1)
	case .Volume_Up:
		adjust_player_volume(0.1)
	case .Speed_Down:
		adjust_playback_rate(-0.1)
	case .Speed_Up:
		adjust_playback_rate(0.1)
	case .Source_Play_Pause:
		on_toggle_playback(nil, nil, nil)
	case .Player_Surface:
		on_toggle_playback(nil, nil, nil)
	case .Source_Stop:
		stop_source_playback()
	case .Source_Timeline:
		return false
	case .Source_Reset:
		reset_source_playback()
	case .Source_Hint_Menu:
		ui.source_hint_menu_open = !ui.source_hint_menu_open
	case .Source_Hint:
		ui.source_hint_menu_open = false
		_ = select_source_hint(state.active_source, action.seconds)
	case .Start:
		on_set_start(nil, nil, nil)
	case .End:
		on_set_end(nil, nil, nil)
	case .Save:
		on_save(nil, nil, nil)
	case .Play:
		on_play(nil, nil, nil)
	case .Pause:
		on_pause(nil, nil, nil)
	case .Captions:
		on_transcribe(nil, nil, nil)
	case .Preview:
		on_preview(nil, nil, nil)
	case .Data:
		on_open_data_folder(nil, nil, nil)
	}
	ui.needs_redraw = true
	return true
}

palette_active_context :: proc() -> command_palette.Context_Mask {
	bits := u64(0)
	if ui.mode == .Create {bits |= u64(PALETTE_CONTEXT_CREATE)} else {bits |= u64(PALETTE_CONTEXT_PLAY)}
	if state.player != nil {bits |= u64(PALETTE_CONTEXT_PLAYER)}
	if state.active_source >= 0 && state.active_source < len(state.sources) {
		bits |= u64(PALETTE_CONTEXT_SOURCE)
		if source_hint_count(state.active_source) > 0 {bits |= u64(PALETTE_CONTEXT_TIMESTAMPS)}
		if state.has_start && state.has_end &&
		   valid_exercise_range(state.range_start, state.range_end, state.sources[state.active_source].duration) {
			bits |= u64(PALETTE_CONTEXT_RANGE)
		}
	}
	if import_job != nil {bits |= u64(PALETTE_CONTEXT_IMPORT_BUSY)}
	if export_job != nil {bits |= u64(PALETTE_CONTEXT_EXPORT_BUSY)}
	return command_palette.Context_Mask(bits)
}

palette_condition :: proc(
	all := command_palette.Context_Mask(0),
	none := command_palette.Context_Mask(0),
) -> command_palette.Context_Condition {
	return {all = all, none = none}
}

append_command_palette_entry :: proc(
	entries: ^[dynamic]command_palette.Entry,
	action: UI_Action,
	title, subtitle, category: string,
	keywords: []string,
	contexts := command_palette.Context_Condition{},
	unavailable_reason := "",
) {
	keyword_copy := make([]string, len(keywords), context.temp_allocator)
	copy(keyword_copy, keywords)
	append(&command_palette_actions, action)
	append(entries, command_palette.Entry{
		id = command_palette.Entry_ID(len(command_palette_actions)),
		title = title,
		subtitle = subtitle,
		category = category,
		keywords = keyword_copy,
		contexts = contexts,
		unavailable_reason = unavailable_reason,
	})
}

palette_busy_mask :: proc() -> command_palette.Context_Mask {
	return command_palette.Context_Mask(
		u64(PALETTE_CONTEXT_IMPORT_BUSY) | u64(PALETTE_CONTEXT_EXPORT_BUSY),
	)
}

build_command_palette_entries :: proc(allocator := context.temp_allocator) -> [dynamic]command_palette.Entry {
	entries := make([dynamic]command_palette.Entry, allocator)
	clear(&command_palette_actions)
	busy := palette_busy_mask()
	mode_context := PALETTE_CONTEXT_CREATE
	mode_title := "Switch to Play mode"
	mode_subtitle := "Open the saved exercise library"
	if ui.mode == .Play {
		mode_context = PALETTE_CONTEXT_PLAY
		mode_title = "Switch to Create mode"
		mode_subtitle = "Open source editing and clip creation"
	}
	append_command_palette_entry(
		&entries,
		UI_Action{kind = .Mode_Toggle},
		mode_title,
		mode_subtitle,
		"Command",
		[]string{"mode", "workspace"},
		palette_condition(mode_context, busy),
		"Wait for the active media operation to finish",
	)
	append_command_palette_entry(
		&entries,
		UI_Action{kind = .Open_Source_Modal},
		"Add source",
		"Import a YouTube video and timed captions",
		"Command",
		[]string{"youtube", "ingest", "download"},
		palette_condition(PALETTE_CONTEXT_CREATE, PALETTE_CONTEXT_IMPORT_BUSY),
		"Available in Create mode when no download is running",
	)
	create_player := command_palette.Context_Mask(
		u64(PALETTE_CONTEXT_CREATE) | u64(PALETTE_CONTEXT_PLAYER),
	)
	append_command_palette_entry(
		&entries,
		UI_Action{kind = .Start},
		"Mark In",
		"Set the exercise start at the current playhead",
		"Command",
		[]string{"start", "range"},
		palette_condition(create_player),
		"Available with a loaded source in Create mode",
	)
	append_command_palette_entry(
		&entries,
		UI_Action{kind = .End},
		"Mark Out",
		"Set the exercise end at the current playhead",
		"Command",
		[]string{"end", "range"},
		palette_condition(create_player),
		"Available with a loaded source in Create mode",
	)
	create_range := command_palette.Context_Mask(
		u64(PALETTE_CONTEXT_CREATE) | u64(PALETTE_CONTEXT_SOURCE) | u64(PALETTE_CONTEXT_RANGE),
	)
	append_command_palette_entry(
		&entries,
		UI_Action{kind = .Save},
		"Commit exercise",
		"Export the marked range as a saved exercise",
		"Command",
		[]string{"save", "clip", "range"},
		palette_condition(create_range, busy),
		"Mark a valid range in Create mode and wait for active media operations",
	)
	append_command_palette_entry(
		&entries,
		UI_Action{kind = .Preview},
		"Preview range",
		"Export and play the marked range without saving it",
		"Command",
		[]string{"audition", "clip"},
		palette_condition(create_range, busy),
		"Mark a valid range in Create mode and wait for active media operations",
	)
	create_source := command_palette.Context_Mask(
		u64(PALETTE_CONTEXT_CREATE) | u64(PALETTE_CONTEXT_SOURCE),
	)
	append_command_palette_entry(
		&entries,
		UI_Action{kind = .Captions},
		"Load captions",
		"Load or refresh the active source transcript",
		"Command",
		[]string{"transcript", "subtitles"},
		palette_condition(create_source, PALETTE_CONTEXT_IMPORT_BUSY),
		"Available after selecting a source in Create mode",
	)
	append_command_palette_entry(
		&entries,
		UI_Action{kind = .Play},
		"Play",
		"Start the loaded source or exercise",
		"Command",
		[]string{"run", "resume"},
		palette_condition(PALETTE_CONTEXT_PLAYER),
		"Available after loading a source or exercise",
	)
	append_command_palette_entry(
		&entries,
		UI_Action{kind = .Pause},
		"Pause",
		"Pause the loaded source or exercise",
		"Command",
		[]string{"hold"},
		palette_condition(PALETTE_CONTEXT_PLAYER),
		"Available after loading a source or exercise",
	)
	append_command_palette_entry(
		&entries,
		UI_Action{kind = .Source_Stop},
		"Stop source",
		"Stop source playback and seek to zero",
		"Command",
		[]string{"transport", "zero"},
		palette_condition(create_player),
		"Available with a loaded source in Create mode",
	)
	create_timestamps := command_palette.Context_Mask(
		u64(create_player) | u64(PALETTE_CONTEXT_TIMESTAMPS),
	)
	append_command_palette_entry(
		&entries,
		UI_Action{kind = .Source_Reset},
		"Reset source timestamp",
		"Seek to the selected imported timestamp",
		"Command",
		[]string{"transport", "hint"},
		palette_condition(create_timestamps),
		"Available when the loaded source has an imported timestamp",
	)
	transport_actions := [4]UI_Action{
		{kind = .Speed_Down},
		{kind = .Speed_Up},
		{kind = .Volume_Down},
		{kind = .Volume_Up},
	}
	transport_titles := [4]string{"Decrease speed", "Increase speed", "Decrease volume", "Increase volume"}
	transport_subtitles := [4]string{
		"Reduce source playback speed by 0.1x",
		"Increase source playback speed by 0.1x",
		"Reduce source volume by 10 percent",
		"Increase source volume by 10 percent",
	}
	for action, index in transport_actions {
		append_command_palette_entry(
			&entries,
			action,
			transport_titles[index],
			transport_subtitles[index],
			"Command",
			nil,
			palette_condition(create_player),
			"Available with a loaded source in Create mode",
		)
	}
	append_command_palette_entry(
		&entries,
		UI_Action{kind = .Data},
		"Open data folder",
		"Show downloaded media, clips, and diagnostics in Finder",
		"Command",
		[]string{"finder", "logs", "storage"},
	)
	for source, index in state.sources {
		resolution := ""
		if source.metadata.width > 0 && source.metadata.height > 0 {
			resolution = fmt.tprintf("%dx%d", source.metadata.width, source.metadata.height)
		}
		subtitle := fmt.tprintf("%s · %s", source.video_id, format_timestamp(source.duration))
		keywords := []string{
			source.id,
			source.video_id,
			source.url,
			source.media_path,
			format_timestamp(source.duration),
			resolution,
			source.metadata.vcodec,
			source.metadata.acodec,
			source.metadata.ext,
			source.metadata.format_id,
		}
		append_command_palette_entry(
			&entries,
			UI_Action{kind = .Source, index = index},
			source.title,
			subtitle,
			"Source",
			keywords,
			palette_condition(none = busy),
			"Wait for the active media operation to finish",
		)
	}
	for exercise, index in state.exercises {
		source_title := exercise.source_id
		for source in state.sources {
			if source.id == exercise.source_id {source_title = source.title; break}
		}
		subtitle := fmt.tprintf(
			"%s · %s–%s",
			source_title,
			format_timestamp(exercise.start_seconds),
			format_timestamp(exercise.end_seconds),
		)
		keywords := []string{
			exercise.id,
			exercise.source_id,
			source_title,
			exercise.clip_path,
			format_timestamp(exercise.start_seconds),
			format_timestamp(exercise.end_seconds),
		}
		append_command_palette_entry(
			&entries,
			UI_Action{kind = .Exercise, index = index},
			exercise.name,
			subtitle,
			"Exercise",
			keywords,
			palette_condition(none = busy),
			"Wait for the active media operation to finish",
		)
	}
	return entries
}

begin_command_palette :: proc() -> bool {
	if command_palette.is_open(&command_palette_state) {return true}
	cancel_ui_flash()
	ui.palette_previous_focus = ui.focus
	ui.palette_previous_caret = ui.caret_byte_offset
	ui.palette_previous_text_scroll = ui.text_scroll_x
	if ui.has_marked_text {
		ui.has_marked_text = false
		ui_set_string(&ui.marked_text, "")
	}
	ui_set_string(&ui.command_palette_query, "")
	ui.command_palette_scroll = 0
	entries := build_command_palette_entries()
	command_palette.open(&command_palette_state, entries[:], palette_active_context())
	ui.focus = .Command_Palette
	ui.caret_byte_offset = 0
	ui.text_scroll_x = 0
	ui.needs_redraw = true
	return true
}

close_command_palette :: proc(restore_focus: bool) {
	if !command_palette.is_open(&command_palette_state) {return}
	command_palette.close(&command_palette_state)
	clear(&command_palette_actions)
	ui.has_marked_text = false
	ui_set_string(&ui.marked_text, "")
	ui_set_string(&ui.command_palette_query, "")
	ui.command_palette_scroll = 0
	if restore_focus {
		ui.focus = ui.palette_previous_focus
		ui.caret_byte_offset = ui.palette_previous_caret
		ui.text_scroll_x = ui.palette_previous_text_scroll
	} else {
		ui.focus = .None
		ui.caret_byte_offset = 0
		ui.text_scroll_x = 0
	}
	ui.needs_redraw = true
}

activate_command_palette_result :: proc(result_index: int) -> bool {
	id, activated := command_palette.activate_result(&command_palette_state, result_index)
	if !activated {return false}
	action_index := int(id) - 1
	if action_index < 0 || action_index >= len(command_palette_actions) {
		clear(&command_palette_actions)
		return false
	}
	action := command_palette_actions[action_index]
	clear(&command_palette_actions)
	ui.has_marked_text = false
	ui_set_string(&ui.marked_text, "")
	ui_set_string(&ui.command_palette_query, "")
	ui.command_palette_scroll = 0
	ui.focus = .None
	if ui.source_modal_open {close_source_modal()}
	if ui.source_details_open {close_source_details()}
	if action.kind == .Source {set_ui_mode(.Create)}
	if action.kind == .Exercise {set_ui_mode(.Play)}
	return activate_ui_action(action)
}

activate_selected_command_palette_result :: proc() -> bool {
	return activate_command_palette_result(command_palette.selected_index(&command_palette_state))
}

on_ax_press :: proc "c" (self: Id, command: Sel) -> bool {
	context = runtime.default_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	control := find_ax_control(self)
	if control == nil || .Enabled not_in control.flags {return false}
	return activate_ui_action(control.action)
}

on_ax_value :: proc "c" (self: Id, command: Sel) -> Id {
	context = runtime.default_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	control := find_ax_control(self)
	if control == nil {return nil}
	#partial switch control.action.kind {
	case .Command_Palette_Search:
		return nsstring(ui.command_palette_query)
	case .URL:
		return nsstring(ui.url_input)
	case .Source_Search:
		return nsstring(ui.source_search)
	case .Transcript_Search:
		return nsstring(ui.transcript_search)
	case .Exercise_Search:
		return nsstring(ui.exercise_search)
	case .Exercise_Name:
		return nsstring(ui.exercise_name)
	}
	return nil
}

on_ax_set_value :: proc "c" (self: Id, command: Sel, value: Id) {
	context = runtime.default_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	control := find_ax_control(self)
	if control == nil || .Editable not_in control.flags {return}
	utf8 := msg_id(value, sel_registerName("UTF8String"))
	if utf8 == nil {return}
	text := string(cstring(utf8))
	#partial switch control.action.kind {
	case .Command_Palette_Search:
		ui_set_string(&ui.command_palette_query, string(cstring(utf8)))
		command_palette.set_query(&command_palette_state, ui.command_palette_query)
		ui.command_palette_scroll = 0
		ensure_command_palette_selection_visible()
	case .URL:
		ui_set_string(&ui.url_input, text)
	case .Source_Search:
		ui_set_string(&ui.source_search, text)
	case .Transcript_Search:
		ui_set_string(&ui.transcript_search, text)
		invalidate_transcript_matches()
	case .Exercise_Search:
		ui_set_string(&ui.exercise_search, text)
	case .Exercise_Name:
		ui_set_string(&ui.exercise_name, text)
	case:
		return
	}
	ui.needs_redraw = true
}

on_metal_ax_children :: proc "c" (self: Id, command: Sel) -> Id {
	return ui.ax_children
}

on_metal_is_ax_element :: proc "c" (self: Id, command: Sel) -> bool {return false}

current_video_texture :: proc() -> (Id, uint, uint) {
	if ui.video_output == nil || ui.texture_cache == nil {return nil, 0, 0}
	seconds, ok := current_seconds()
	if !ok {return nil, 0, 0}
	time := CMTime {
		value     = i64(seconds * 600),
		timescale = 600,
		flags     = 1,
	}
	if !msg_bool_time(ui.video_output, sel_registerName("hasNewPixelBufferForItemTime:"), time) {
		return ui.last_video_texture, ui.last_video_width, ui.last_video_height
	}
	display_time: CMTime
	buffer := msg_id_time_time(
		ui.video_output,
		sel_registerName("copyPixelBufferForItemTime:itemTimeForDisplay:"),
		time,
		&display_time,
	)
	if buffer == nil {return ui.last_video_texture, ui.last_video_width, ui.last_video_height}
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
		return ui.last_video_texture, ui.last_video_width, ui.last_video_height
	}
	if cv_texture == nil {return ui.last_video_texture, ui.last_video_width, ui.last_video_height}
	trace_foreign_lifetime("create", "CVMetalTexture", cv_texture, "current_video_texture")
	defer foreign_release(cv_texture, "CVMetalTexture", "current_video_texture")
	texture := CVMetalTextureGetTexture(cv_texture)
	if texture == nil {return ui.last_video_texture, ui.last_video_width, ui.last_video_height}
	retained := msg_id(texture, sel_registerName("retain"))
	if ui.last_video_texture != nil {msg_void(ui.last_video_texture, sel_registerName("release"))}
	ui.last_video_texture = retained
	ui.last_video_width, ui.last_video_height = width, height
	return retained, width, height
}

render_frame :: proc() {
	if ui.layer == nil || ui.width <= 0 || ui.height <= 0 {return}
	drawable := msg_id(ui.layer, sel_registerName("nextDrawable"))
	if drawable == nil {return}
	arena_reset(&memory.frame, &memory.frame_stats)
	frame_allocator := mem_virtual.arena_allocator(&memory.frame)
	texture := msg_id(drawable, sel_registerName("texture"))
	command_buffer := msg_id(ui.queue, sel_registerName("commandBuffer"))
	pass := msg_id(
		objc_getClass("MTLRenderPassDescriptor"),
		sel_registerName("renderPassDescriptor"),
	)
	attachments := msg_id(pass, sel_registerName("colorAttachments"))
	attachment := msg_id_uint(attachments, sel_registerName("objectAtIndexedSubscript:"), 0)
	msg_void_id(attachment, sel_registerName("setTexture:"), texture)
	msg_void_i(attachment, sel_registerName("setLoadAction:"), 2)
	msg_void_i(attachment, sel_registerName("setStoreAction:"), 1)
	msg_void_clear_color(
		attachment,
		sel_registerName("setClearColor:"),
		MTL_Clear_Color{0.026, 0.028, 0.027, 1},
	)

	pixel_width := uint(max(1, ui.width * ui.scale))
	pixel_height := uint(max(1, ui.height * ui.scale))
	texture_resized := ensure_text_texture(pixel_width, pixel_height)
	redraw_requested := ui.needs_redraw || texture_resized
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
		}
	}

	encoder := msg_id_id(
		command_buffer,
		sel_registerName("renderCommandEncoderWithDescriptor:"),
		pass,
	)

	vertices, vertices_error := make([dynamic]Solid_Vertex, 0, 1024, frame_allocator)
	if vertices_error != nil {arena_note_failure(&memory.frame_stats)}
	if vertices_error == nil {build_geometry(&vertices)}
	msg_void_id(encoder, sel_registerName("setRenderPipelineState:"), ui.solid_pipeline)
	if vertices_error == nil {encode_solid_vertices(encoder, vertices[:])}

	_, _, _, _, player, _, _, _, _, _ := layout_rects()
	player_rect := player_content_rect(player)
	if video_texture, video_width, video_height := current_video_texture(); video_texture != nil {
		aspect := f64(video_width) / f64(video_height)
		draw_rect := player_rect
		if draw_rect.w / draw_rect.h > aspect {
			draw_rect.w = draw_rect.h * aspect
			draw_rect.x += (player_rect.w - draw_rect.w) / 2
		} else {
			draw_rect.h = draw_rect.w / aspect
			draw_rect.y += (player_rect.h - draw_rect.h) / 2
		}
		encode_texture(encoder, video_texture, draw_rect, 1)
	}

	encode_texture(encoder, ui.text_texture, UI_Rect{0, 0, ui.width, ui.height}, 1)

	msg_void(encoder, sel_registerName("endEncoding"))
	msg_void_id(command_buffer, sel_registerName("presentDrawable:"), drawable)
	msg_void(command_buffer, sel_registerName("commit"))
	memory.frame_stats.high_water = max(memory.frame_stats.high_water, memory.frame.total_used)
	memory.redraw_stats.high_water = max(memory.redraw_stats.high_water, memory.redraw.total_used)
	ui.needs_redraw = !overlay_uploaded
}

ui_memory_destroy :: proc() {
	metal_player_clear()
	if ui.ax_children != nil {msg_void(ui.ax_children, sel_registerName("release"))}
	if ui.text_texture != nil {msg_void(ui.text_texture, sel_registerName("release"))}
	if ui.solid_pipeline != nil {msg_void(ui.solid_pipeline, sel_registerName("release"))}
	if ui.texture_pipeline != nil {msg_void(ui.texture_pipeline, sel_registerName("release"))}
	if ui.queue != nil {msg_void(ui.queue, sel_registerName("release"))}
	if ui.texture_cache !=
	   nil {foreign_release(ui.texture_cache, "CVMetalTextureCache", "ui_memory_destroy")}
	delete(ui.url_input)
	delete(ui.source_search)
	delete(ui.transcript_search)
	delete(ui.exercise_search)
	delete(ui.exercise_name)
	delete(ui.command_palette_query)
	delete(ui.status)
	delete(ui.marked_text)
	delete(ui.transcript_matches)
	delete(ax_actions)
	delete(command_palette_actions)
	flash.state_destroy(&flash_state)
	command_palette.state_destroy(&command_palette_state)
	ui = {}
	ax_actions = nil
	ui_build = {}
	command_palette_actions = nil
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

	desc := msg_id(objc_getClass("MTLRenderPipelineDescriptor"), sel_registerName("new"))
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

metal_player_clear_texture :: proc() {
	if ui.last_video_texture != nil {
		msg_void(ui.last_video_texture, sel_registerName("release"))
		ui.last_video_texture = nil
		ui.last_video_width, ui.last_video_height = 0, 0
	}
}

metal_audio_pause :: proc() {
	if ui.audio_player != nil {msg_void(ui.audio_player, sel_registerName("pause"))}
}

metal_audio_play :: proc() {
	if ui.audio_player != nil {msg_void(ui.audio_player, sel_registerName("play"))}
}

audio_source_seconds :: proc(start_frame, rendered_frames: i64, sample_rate: f64) -> (f64, bool) {
	if start_frame < 0 || rendered_frames < 0 || sample_rate <= 0 {return 0, false}
	return f64(start_frame + rendered_frames) / sample_rate, true
}

metal_audio_current_seconds :: proc() -> (f64, bool) {
	if ui.audio_player == nil || ui.audio_file == nil {return 0, false}
	render_time := msg_id(ui.audio_player, sel_registerName("lastRenderTime"))
	if render_time == nil {return 0, false}
	player_time := msg_id_id(ui.audio_player, sel_registerName("playerTimeForNodeTime:"), render_time)
	if player_time == nil {return 0, false}
	format := msg_id(ui.audio_file, sel_registerName("processingFormat"))
	return audio_source_seconds(
		ui.audio_start_frame,
		msg_i64(player_time, sel_registerName("sampleTime")),
		msg_f64(format, sel_registerName("sampleRate")),
	)
}

audio_frame_range :: proc(seconds, sample_rate: f64, length: i64) -> (start: i64, count: u32) {
	if sample_rate <= 0 || length <= 0 {return 0, 0}
	start = min(max(i64(seconds * sample_rate), 0), length)
	remaining := length - start
	if remaining <= 0 {return start, 0}
	return start, u32(min(remaining, i64(0xffffffff)))
}

metal_audio_seek :: proc(seconds: f64, resume: bool) {
	if ui.audio_player == nil || ui.audio_file == nil {return}
	msg_void(ui.audio_player, sel_registerName("stop"))
	format := msg_id(ui.audio_file, sel_registerName("processingFormat"))
	sample_rate := msg_f64(format, sel_registerName("sampleRate"))
	length := msg_i64(ui.audio_file, sel_registerName("length"))
	start, frame_count := audio_frame_range(seconds, sample_rate, length)
	if frame_count == 0 {return}
	ui.audio_start_frame = start
	msg_void_id_i64_u32_id_id(
		ui.audio_player,
		sel_registerName("scheduleSegment:startingFrame:frameCount:atTime:completionHandler:"),
		ui.audio_file,
		start,
		frame_count,
		nil,
		nil,
	)
	if resume {metal_audio_play()}
}

metal_audio_release :: proc(engine, player, pitch, file: Id) {
	if player != nil {msg_void(player, sel_registerName("stop"))}
	if engine != nil {msg_void(engine, sel_registerName("stop"))}
	if file != nil {msg_void(file, sel_registerName("release"))}
	if pitch != nil {msg_void(pitch, sel_registerName("release"))}
	if player != nil {msg_void(player, sel_registerName("release"))}
	if engine != nil {msg_void(engine, sel_registerName("release"))}
}

metal_audio_load :: proc(url: Id) -> (engine, player, pitch, file: Id, ok: bool) {
	error: Id
	file = msg_id_id_error_2(
		msg_id(objc_getClass("AVAudioFile"), sel_registerName("alloc")),
		sel_registerName("initForReading:error:"),
		url,
		&error,
	)
	if file == nil {return nil, nil, nil, nil, false}
	engine = msg_id(objc_getClass("AVAudioEngine"), sel_registerName("new"))
	player = msg_id(objc_getClass("AVAudioPlayerNode"), sel_registerName("new"))
	pitch = msg_id(objc_getClass("AVAudioUnitTimePitch"), sel_registerName("new"))
	if engine == nil || player == nil || pitch == nil {
		metal_audio_release(engine, player, pitch, file)
		return nil, nil, nil, nil, false
	}
	msg_void_id(engine, sel_registerName("attachNode:"), player)
	msg_void_id(engine, sel_registerName("attachNode:"), pitch)
	format := msg_id(file, sel_registerName("processingFormat"))
	mixer := msg_id(engine, sel_registerName("mainMixerNode"))
	msg_void_id_id_id(engine, sel_registerName("connect:to:format:"), player, pitch, format)
	msg_void_id_id_id(engine, sel_registerName("connect:to:format:"), pitch, mixer, format)
	msg_void_f32(player, sel_registerName("setVolume:"), ui.player_volume)
	msg_void_f32(pitch, sel_registerName("setRate:"), ui.playback_rate)
	msg_void(engine, sel_registerName("prepare"))
	if !msg_bool_error(engine, sel_registerName("startAndReturnError:"), &error) {
		metal_audio_release(engine, player, pitch, file)
		return nil, nil, nil, nil, false
	}
	return engine, player, pitch, file, true
}

metal_player_clear :: proc() {
	set_source_playback_active(false)
	ui.source_scrubbing = false
	ui.source_hint_menu_open = false
	metal_player_clear_texture()
	player := state.player
	output := ui.video_output
	audio_engine, audio_player := ui.audio_engine, ui.audio_player
	audio_pitch, audio_file := ui.audio_pitch, ui.audio_file
	state.player = nil
	ui.video_output = nil
	ui.audio_engine, ui.audio_player = nil, nil
	ui.audio_pitch, ui.audio_file = nil, nil
	ui.audio_start_frame = 0
	if player != nil {
		msg_void(player, sel_registerName("pause"))
		msg_void(player, sel_registerName("release"))
	}
	if output != nil {
		msg_void(output, sel_registerName("release"))
	}
	metal_audio_release(audio_engine, audio_player, audio_pitch, audio_file)
}

metal_player_load :: proc(path: string) -> bool {
	url := msg_id_id(objc_getClass("NSURL"), sel_registerName("fileURLWithPath:"), nsstring(path))
	if url == nil {return false}
	item := msg_id_id(objc_getClass("AVPlayerItem"), sel_registerName("playerItemWithURL:"), url)
	if item == nil {return false}
	pixel_type := msg_id_uint(
		objc_getClass("NSNumber"),
		sel_registerName("numberWithUnsignedInt:"),
		0x42475241,
	)
	settings := msg_id_id_id(
		objc_getClass("NSDictionary"),
		sel_registerName("dictionaryWithObject:forKey:"),
		pixel_type,
		nsstring("PixelFormatType"),
	)
	output := msg_id_id(
		msg_id(objc_getClass("AVPlayerItemVideoOutput"), sel_registerName("alloc")),
		sel_registerName("initWithPixelBufferAttributes:"),
		settings,
	)
	if output == nil {return false}
	msg_void_id(item, sel_registerName("addOutput:"), output)
	player := msg_id_id(
		msg_id(objc_getClass("AVPlayer"), sel_registerName("alloc")),
		sel_registerName("initWithPlayerItem:"),
		item,
	)
	if player == nil {
		msg_void(output, sel_registerName("release"))
		return false
	}
	msg_void_bool(player, sel_registerName("setMuted:"), true)
	audio_engine, audio_player, audio_pitch, audio_file, audio_ok := metal_audio_load(url)
	if !audio_ok {
		msg_void(player, sel_registerName("release"))
		msg_void(output, sel_registerName("release"))
		return false
	}

	old_player := state.player
	old_output := ui.video_output
	old_audio_engine, old_audio_player := ui.audio_engine, ui.audio_player
	old_audio_pitch, old_audio_file := ui.audio_pitch, ui.audio_file
	state.player = player
	ui.video_output = output
	ui.audio_engine, ui.audio_player = audio_engine, audio_player
	ui.audio_pitch, ui.audio_file = audio_pitch, audio_file
	metal_player_clear_texture()
	if old_player != nil {
		msg_void(old_player, sel_registerName("pause"))
		msg_void(old_player, sel_registerName("release"))
	}
	if old_output != nil {
		msg_void(old_output, sel_registerName("release"))
	}
	metal_audio_release(old_audio_engine, old_audio_player, old_audio_pitch, old_audio_file)
	ui.needs_redraw = true
	return true
}

activate_control :: proc(index: int) {
	kinds := [8]UI_Action_Kind{.Start, .End, .Save, .Play, .Pause, .Captions, .Preview, .Data}
	if index < 0 || index >= len(kinds) {return}
	control := find_ui_control_by_action(kinds[index])
	if control != nil && .Enabled in control.flags {_ = activate_ui_action(control.action)}
}

activate_registered_target_at_point :: proc(point: Point) -> bool {
	control := find_ui_control_at_point(ui_build.controls[:], point, .Primary_Press)
	if control == nil {return false}
	#partial switch control.action.kind {
	case .Command_Palette_Search:
		clear_marked_text()
		focus_text_input(.Command_Palette)
		place_caret_in_text_field(ui.command_palette_query, control.rect, point, 12)
	case .URL:
		if ui.source_modal_refetch_index >= 0 {return true}
		focus_text_input(.URL)
		lines := strings.split_lines(ui.url_input)
		caret_line := 0
		for index in 0 ..< min(ui.caret_byte_offset, len(ui.url_input)) {
			if ui.url_input[index] == '\n' {caret_line += 1}
		}
		first_line := min(max(0, caret_line - 9), max(0, len(lines) - 10))
		clicked_line := first_line + int(max(
			0,
			min(
				f64(len(lines) - first_line - 1),
				(control.rect.y + control.rect.h - 19 - point.y) / 23,
			),
		))
		line_start := 0
		for index in 0 ..< clicked_line {line_start += len(lines[index]) + 1}
		place_caret_in_text_field(
			fmt.tprintf("$ %s", lines[clicked_line]),
			UI_Rect{control.rect.x + 12, control.rect.y, control.rect.w - 24, control.rect.h},
			point,
			0,
			line_start,
			2,
		)
	case .Source_Search:
		focus_text_input(.Source_Search)
		place_caret_in_text_field(ui.source_search, control.rect, point)
	case .Transcript_Search:
		focus_text_input(.Transcript_Search)
		place_caret_in_text_field(ui.transcript_search, control.rect, point)
	case .Exercise_Search:
		focus_text_input(.Exercise_Search)
		place_caret_in_text_field(ui.exercise_search, control.rect, point)
	case .Exercise_Name:
		focus_text_input(.Exercise_Name)
		place_caret_in_text_field(ui.exercise_name, control.rect, point)
	case .Source_Timeline:
		ui.source_scrubbing = true
		seek_source_timeline_rect(point, control.rect)
	case:
		return activate_ui_action(control.action)
	}
	return true
}

dispatch_click :: proc(point: Point) {
	cancel_ui_flash()
	if command_palette.is_open(&command_palette_state) {
		modal := command_palette_rect()
		if !contains(modal, point) {close_command_palette(true); return}
		_ = activate_registered_target_at_point(point)
		return
	}
	clear_marked_text()
	if ui.source_details_open {
		modal := source_details_rect()
		if !contains(modal, point) {close_source_details(); return}
		_ = activate_registered_target_at_point(point)
		return
	}
	if ui.source_modal_open {
		modal := source_modal_rect()
		if !contains(modal, point) {close_source_modal(); return}
		_ = activate_registered_target_at_point(point)
		return
	}
	ui.focus = .None
	if ui.source_hint_menu_open {
		control := find_ui_control_at_point(ui_build.controls[:], point, .Primary_Press)
		if control == nil ||
		   (control.action.kind != .Source_Hint_Menu && control.action.kind != .Source_Hint) {
			ui.source_hint_menu_open = false
		}
	}
	if activate_registered_target_at_point(point) {return}
}

on_metal_mouse_down :: proc "c" (self: Id, command: Sel, event: Id) {
	context = runtime.default_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	window_point := msg_point(event, sel_registerName("locationInWindow"))
	ui.mouse = msg_point_point_id(
		self,
		sel_registerName("convertPoint:fromView:"),
		window_point,
		nil,
	)
	if !command_palette.is_open(&command_palette_state) &&
	   !ui.source_modal_open && !ui.source_details_open &&
	   contains(app_header_rect(), ui.mouse) &&
	   !contains(ui_control_rect(.Mode_Toggle), ui.mouse) {
		if msg_uint(event, sel_registerName("clickCount")) >= 2 {
			msg_void_id(state.window, sel_registerName("performZoom:"), nil)
		} else {
			msg_void_id(state.window, sel_registerName("performWindowDragWithEvent:"), event)
		}
		return
	}
	dispatch_click(ui.mouse)
	ui.needs_redraw = true
}

on_metal_right_mouse_down :: proc "c" (self: Id, command: Sel, event: Id) {
	context = runtime.default_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	cancel_ui_flash()
	if command_palette.is_open(&command_palette_state) {return}
	if ui.source_modal_open || ui.source_details_open || ui.mode != .Create { return }
	window_point := msg_point(event, sel_registerName("locationInWindow"))
	point := msg_point_point_id(self, sel_registerName("convertPoint:fromView:"), window_point, nil)
	ui.mouse = point
	control := find_ui_control_at_point(ui_build.controls[:], point, .Secondary_Press)
	if control != nil {_ = activate_ui_action(control.action)}
	ui.needs_redraw = true
}

on_metal_mouse_moved :: proc "c" (self: Id, command: Sel, event: Id) {
	context = runtime.default_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	window_point := msg_point(event, sel_registerName("locationInWindow"))
	next := msg_point_point_id(self, sel_registerName("convertPoint:fromView:"), window_point, nil)
	if next != ui.mouse {
		ui.mouse = next
		if command_palette.is_open(&command_palette_state) {
			control := find_ui_control_at_point(ui_build.controls[:], next, .Primary_Press)
			if control != nil && control.action.kind == .Command_Palette_Result {
				_ = command_palette.select_result(&command_palette_state, control.action.index)
			}
		}
		ui.needs_redraw = true
	}
}

on_metal_mouse_dragged :: proc "c" (self: Id, command: Sel, event: Id) {
	context = runtime.default_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	window_point := msg_point(event, sel_registerName("locationInWindow"))
	ui.mouse = msg_point_point_id(self, sel_registerName("convertPoint:fromView:"), window_point, nil)
	if ui.source_scrubbing && ui.mode == .Create {
		control := find_ui_control_by_action(.Source_Timeline)
		if control != nil && .Drag in control.flags {seek_source_timeline_rect(ui.mouse, control.rect)}
	}
	ui.needs_redraw = true
}

on_metal_mouse_up :: proc "c" (self: Id, command: Sel, event: Id) {
	context = runtime.default_context()
	if ui.source_scrubbing {
		ui.source_scrubbing = false
		ui.needs_redraw = true
	}
}

on_metal_scroll :: proc "c" (self: Id, command: Sel, event: Id) {
	context = runtime.default_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	cancel_ui_flash()
	if command_palette.is_open(&command_palette_state) {
		delta := msg_f64(event, sel_registerName("scrollingDeltaY"))
		ui.command_palette_scroll = min(
			max(0, ui.command_palette_scroll + delta),
			command_palette_max_scroll(),
		)
		ui.needs_redraw = true
		return
	}
	if ui.source_modal_open || ui.source_details_open {return}
	delta := msg_f64(event, sel_registerName("scrollingDeltaY"))
	window_point := msg_point(event, sel_registerName("locationInWindow"))
	point := msg_point_point_id(
		self,
		sel_registerName("convertPoint:fromView:"),
		window_point,
		nil,
	)
	_, _, source_search, source_panel, _, transcript, exercise_search, exercise_panel, exercise_name, _ :=
		layout_rects()
	source_content := source_content_rect(source_search, source_panel)
	transcript_content := transcript_content_rect(transcript)
	exercise_content := exercise_content_rect(exercise_search, exercise_panel, exercise_name)
	if ui.mode == .Create && contains(source_content, point) {
		ui.source_scroll = bounded_scroll(
			ui.source_scroll,
			delta,
			filtered_source_count(),
			29,
			30,
			source_content.h,
		)
	} else if ui.mode == .Create && contains(transcript_content, point) {
		ui.transcript_scroll = bounded_scroll(
			ui.transcript_scroll,
			delta,
			active_segment_count(),
			25,
			26,
			transcript_content.h,
		)
		if state.player != nil && msg_f32(state.player, sel_registerName("rate")) > 0 {
			ui.transcript_follow_suspended = true
			ui.transcript_follow_pending = false
			ui.transcript_has_follow_target = false
		}
	} else if ui.mode == .Play && contains(exercise_content, point) {
		ui.exercise_scroll = bounded_scroll(
			ui.exercise_scroll,
			delta,
			filtered_exercise_count(),
			29,
			30,
			exercise_content.h,
		)
	}
	ui.needs_redraw = true
}

on_metal_insert_text_simple :: proc "c" (self: Id, command: Sel, value: Id) {
	on_metal_insert_text(self, command, value, NS_Range{0, 0})
}

text_input_string :: proc(value: Id) -> (string, bool) {
	if value == nil {return "", false}
	utf8_selector := sel_registerName("UTF8String")
	text_object := value
	if !msg_bool_sel(text_object, sel_registerName("respondsToSelector:"), utf8_selector) {
		string_selector := sel_registerName("string")
		if !msg_bool_sel(text_object, sel_registerName("respondsToSelector:"), string_selector) {return "", false}
		text_object = msg_id(text_object, string_selector)
		if text_object == nil || !msg_bool_sel(text_object, sel_registerName("respondsToSelector:"), utf8_selector) {return "", false}
	}
	utf8 := msg_id(text_object, utf8_selector)
	if utf8 == nil {return "", false}
	return string(cstring(utf8)), true
}

on_metal_insert_text :: proc "c" (self: Id, command: Sel, value: Id, replacement: NS_Range) {
	context = runtime.default_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	target := focused_text()
	if target == nil {return}
	remove_marked_text(target)
	if text, ok := text_input_string(value); ok && text_event_is_insertable(text) {insert_text_at_caret(target, text)}
	focused_text_changed(target)
	clear_marked_text()
	ui.needs_redraw = true
}

on_metal_paste :: proc "c" (self: Id, command: Sel, sender: Id) {
	context = runtime.default_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	target := focused_text()
	if target == nil {return}
	pasteboard := msg_id(objc_getClass("NSPasteboard"), sel_registerName("generalPasteboard"))
	if pasteboard == nil {return}
	value := msg_id_id(
		pasteboard,
		sel_registerName("stringForType:"),
		nsstring("public.utf8-plain-text"),
	)
	if value == nil {return}
	utf8 := msg_id(value, sel_registerName("UTF8String"))
	if utf8 == nil {return}
	remove_marked_text(target)
	insert_text_at_caret(target, string(cstring(utf8)))
	if target == &ui.url_input {schedule_source_probe(1)} else {focused_text_changed(target)}
	ui.needs_redraw = true
}

on_metal_command :: proc "c" (self: Id, command: Sel, selector: Sel) {
	context = runtime.default_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	target := focused_text()
	if selector == sel_registerName("deleteBackward:") {
		if target != nil {remove_marked_text(target); remove_character_before_caret(target); focused_text_changed(target)}
	} else if selector == sel_registerName("deleteForward:") {
		if target != nil {remove_marked_text(target); remove_character_after_caret(target); focused_text_changed(target)}
	} else if selector == sel_registerName("deleteWordBackward:") {
		if target != nil {remove_marked_text(target); remove_word_before_caret(target); focused_text_changed(target)}
	} else if selector == sel_registerName("moveLeft:") {
		if target != nil {clear_marked_text(); ui.caret_byte_offset = previous_character_offset(target^, ui.caret_byte_offset)}
	} else if selector == sel_registerName("moveRight:") {
		if target != nil {clear_marked_text(); ui.caret_byte_offset = next_character_offset(target^, ui.caret_byte_offset)}
	} else if selector == sel_registerName("moveToBeginningOfLine:") {
		if target != nil {clear_marked_text(); ui.caret_byte_offset = line_start_for_offset(target^, ui.caret_byte_offset)}
	} else if selector == sel_registerName("moveToEndOfLine:") {
		if target != nil {clear_marked_text(); ui.caret_byte_offset = line_end_for_offset(target^, ui.caret_byte_offset)}
	} else if selector == sel_registerName("paste:") {
		on_metal_paste(self, selector, nil)
	} else if selector == sel_registerName("insertNewline:") {
		if ui.focus ==
		   .URL {insert_text_at_caret(&ui.url_input, "\n"); schedule_source_probe(1)} else if ui.focus == .Source_Search || ui.focus == .Transcript_Search || ui.focus == .Exercise_Search {ui.focus = .None} else if ui.focus == .Exercise_Name {ui.focus = .None}
	} else if selector == sel_registerName("insertTab:") {
		if ui.source_modal_open {
			ui.focus = .URL
		} else if ui.mode == .Play {
			ui.focus = .Exercise_Search
		} else {
			#partial switch ui.focus {
			case .None:
				ui.focus = .Source_Search
			case .Source_Search:
				ui.focus = .Transcript_Search
			case .Transcript_Search:
				ui.focus = .Exercise_Name
			case:
				ui.focus = .None
			}
		}
	}
	ui.needs_redraw = true
}

on_metal_key_down :: proc "c" (self: Id, command: Sel, event: Id) {
	context = runtime.default_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	key := msg_uint(event, sel_registerName("keyCode"))
	modifiers := msg_uint(event, sel_registerName("modifierFlags"))
	characters := msg_id(event, sel_registerName("characters"))
	event_text, has_event_text := text_input_string(characters)
	palette_shortcut := event_opens_command_palette(event, modifiers)
	if command_palette.is_open(&command_palette_state) {
		if palette_shortcut || key == 53 {
			close_command_palette(true)
			return
		}
		if key == 126 || key == 125 || key == 48 {
			direction := 1
			if key == 126 || key == 48 && modifiers & NSEventModifierFlagShift != 0 {direction = -1}
			_ = command_palette.move_selection(&command_palette_state, direction)
			ensure_command_palette_selection_visible()
			ui.needs_redraw = true
			return
		}
		if key == 36 || key == 76 {
			_ = activate_selected_command_palette_result()
			ui.needs_redraw = true
			return
		}
	} else if palette_shortcut {
		_ = begin_command_palette()
		return
	}
	if flash.is_active(&flash_state) {
		if key == 53 {
			cancel_ui_flash()
			return
		}
		if flash.has_group_selection(&flash_state) {
			if key == 48 {
				direction := flash.Selection_Direction.Next
				if modifiers & NSEventModifierFlagShift != 0 {
					direction = .Previous
				}
				_ = flash.cycle_selection(&flash_state, direction)
				ui.needs_redraw = true
				return
			}
			if key == 36 || key == 76 {
				result := flash.activate_selection(&flash_state)
				ui.needs_redraw = true
				if result.kind == .Activated {
					_ = activate_flash_target(result.target_id)
				}
				return
			}
			cancel_ui_flash()
			return
		}
		value := u8(0)
		if has_event_text && len(event_text) == 1 {value = event_text[0]}
		result := flash.consume(&flash_state, value)
		ui.needs_redraw = true
		if result.kind == .Activated {_ = activate_flash_target(result.target_id)}
		return
	}
	if has_event_text && flash_leader_allowed(ui.focus, modifiers, event_text) {
		_ = begin_ui_flash()
		return
	}
	if key == 53 && unfocus_text_input() {return}
	if ui.source_modal_open && key == 53 {close_source_modal(); return}
	if ui.source_details_open && key == 53 {close_source_details(); return}
	if is_paste_shortcut(key, modifiers) {
		on_metal_paste(self, sel_registerName("paste:"), nil)
		return
	}
	if focused_text() != nil {
		#partial switch dispose_focused_text_key(key, modifiers) {
		case .Delete_Word:
			if target := focused_text(); target != nil {
				remove_marked_text(target)
				remove_word_before_caret(target)
				focused_text_changed(target)
				ui.needs_redraw = true
			}
			return
		case .Interpret:
			// AppKit translates editing keys and IME input into NSTextInputClient commands.
		}
	}
	if ui.focus == .None {
		if key == 49 {on_toggle_playback(nil, nil, nil); return}
		key_codes := [8]uint{18, 19, 20, 21, 23, 22, 26, 28}
		for control_key, slot in key_codes {
			if key == control_key {
				action := control_action_for_slot(ui.mode, slot)
				if action >= 0 {activate_control(action)}
				ui.needs_redraw = true
				return
			}
		}
	}
	array := msg_id_id(objc_getClass("NSArray"), sel_registerName("arrayWithObject:"), event)
	msg_void_id(self, sel_registerName("interpretKeyEvents:"), array)
}

on_metal_set_marked :: proc "c" (
	self: Id,
	command: Sel,
	value: Id,
	selected, replacement: NS_Range,
) {
	context = runtime.default_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	target := focused_text()
	if target == nil {return}
	remove_marked_text(target)
	text, ok := text_input_string(value)
	if !ok {return}
	ui_set_string(&ui.marked_text, text)
	ui.marked_start_byte = ui.caret_byte_offset
	insert_text_at_caret(target, ui.marked_text)
	focused_text_changed(target)
	ui.has_marked_text = true
	ui.needs_redraw = true
}

on_metal_unmark :: proc "c" (self: Id, command: Sel) {
	context = runtime.default_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	clear_marked_text()
}
on_metal_has_marked :: proc "c" (self: Id, command: Sel) -> bool {return ui.has_marked_text}
on_metal_range :: proc "c" (self: Id, command: Sel) -> NS_Range {
	context = runtime.default_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	target := focused_text()
	if target == nil {return NS_Range{~uint(0), 0}}
	if command == sel_registerName("markedRange") {
		if !ui.has_marked_text {return NS_Range{~uint(0), 0}}
		total := utf16_index_for_byte_offset(target^, ui.marked_start_byte)
		marked := utf16_index_for_byte_offset(ui.marked_text, len(ui.marked_text))
		return NS_Range{uint(total), uint(marked)}
	}
	return NS_Range{uint(utf16_index_for_byte_offset(target^, ui.caret_byte_offset)), 0}
}
on_metal_valid_attributes :: proc "c" (self: Id, command: Sel) -> Id {
	context = runtime.default_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	return msg_id(objc_getClass("NSArray"), sel_registerName("array"))
}
on_metal_attributed_substring :: proc "c" (
	self: Id,
	command: Sel,
	range: NS_Range,
	actual: ^NS_Range,
) -> Id {return nil}
on_metal_character_index :: proc "c" (self: Id, command: Sel, point: Point) -> uint {return 0}
on_metal_first_rect :: proc "c" (
	self: Id,
	command: Sel,
	range: NS_Range,
	actual: ^NS_Range,
) -> Rect {
	context = runtime.default_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	frame := msg_rect(state.window, sel_registerName("frame"))
	return Rect{Point{frame.origin.x + ui.mouse.x, frame.origin.y + ui.mouse.y}, Size{1, 18}}
}

on_metal_accepts_first :: proc "c" (self: Id, command: Sel) -> bool {return true}

on_metal_frame :: proc "c" (self: Id, command: Sel, timer: Id) {
	context = runtime.default_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	ui.frame_tick += 1
	if ui.url_probe_pending && ui.frame_tick >= ui.url_probe_due_tick {
		ui.url_probe_pending = false
		source_probe_request()
	}
	if import_job != nil || export_job != nil || source_probe_job != nil {
		ui.activity_tick += 1
		if ui.activity_tick % 8 == 0 {
			if import_job != nil {refresh_import_progress()}
			ui.needs_redraw = true
		}
	} else {
		ui.activity_tick = 0
	}
	if state.player != nil &&
	   msg_f32(state.player, sel_registerName("rate")) > 0 {ui.needs_redraw = true}
	frame := msg_rect(ui.view, sel_registerName("bounds"))
	if ui.width != frame.size.width || ui.height != frame.size.height {
		cancel_ui_flash()
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
	if ui.scale <= 0 {ui.scale = 1}
	sync_transcript_playback()
	normalize_scroll_offsets()
	msg_void_size(
		ui.layer,
		sel_registerName("setDrawableSize:"),
		Size{ui.width * ui.scale, ui.height * ui.scale},
	)
	render_frame()
}

register_delegate :: proc(app: Id) {
	delegate_class := objc_allocateClassPair(objc_getClass("NSObject"), "VocalMetalDelegate", 0)
	class_addMethod(
		delegate_class,
		sel_registerName("importFinished:"),
		rawptr(on_import_finished),
		"v@:@",
	)
	class_addMethod(
		delegate_class,
		sel_registerName("exportFinished:"),
		rawptr(on_export_finished),
		"v@:@",
	)
	class_addMethod(
		delegate_class,
		sel_registerName("sourceMetadataFinished:"),
		rawptr(on_source_metadata_finished),
		"v@:@",
	)
	class_addMethod(
		delegate_class,
		sel_registerName("sourceProbeFinished:"),
		rawptr(on_source_probe_finished),
		"v@:@",
	)
	class_addMethod(
		delegate_class,
		sel_registerName("metalFrame:"),
		rawptr(on_metal_frame),
		"v@:@",
	)
	class_addMethod(
		delegate_class,
		sel_registerName("cliRequest:"),
		rawptr(on_cli_ipc_request),
		"v@:@",
	)
	class_addMethod(
		delegate_class,
		sel_registerName("applicationShouldTerminateAfterLastWindowClosed:"),
		rawptr(should_terminate_after_window_close),
		"B@:@",
	)
	objc_registerClassPair(delegate_class)
	state.delegate_target = msg_id(delegate_class, sel_registerName("new"))
	msg_void_id(app, sel_registerName("setDelegate:"), state.delegate_target)
}

register_metal_view_class :: proc() -> Id {
	class := objc_allocateClassPair(objc_getClass("NSView"), "VocalMetalView", 0)
	if protocol := objc_getProtocol("NSTextInputClient"); protocol != nil {
		class_addProtocol(class, protocol)
	}
	class_addMethod(
		class,
		sel_registerName("acceptsFirstResponder"),
		rawptr(on_metal_accepts_first),
		"B@:",
	)
	class_addMethod(class, sel_registerName("mouseDown:"), rawptr(on_metal_mouse_down), "v@:@")
	class_addMethod(class, sel_registerName("rightMouseDown:"), rawptr(on_metal_right_mouse_down), "v@:@")
	class_addMethod(class, sel_registerName("mouseMoved:"), rawptr(on_metal_mouse_moved), "v@:@")
	class_addMethod(class, sel_registerName("mouseDragged:"), rawptr(on_metal_mouse_dragged), "v@:@")
	class_addMethod(class, sel_registerName("mouseUp:"), rawptr(on_metal_mouse_up), "v@:@")
	class_addMethod(class, sel_registerName("scrollWheel:"), rawptr(on_metal_scroll), "v@:@")
	class_addMethod(class, sel_registerName("keyDown:"), rawptr(on_metal_key_down), "v@:@")
	class_addMethod(class, sel_registerName("paste:"), rawptr(on_metal_paste), "v@:@")
	class_addMethod(class, sel_registerName("insertText:"), rawptr(on_metal_insert_text_simple), "v@:@")
	class_addMethod(
		class,
		sel_registerName("insertText:replacementRange:"),
		rawptr(on_metal_insert_text),
		"v@:@{_NSRange=QQ}",
	)
	class_addMethod(
		class,
		sel_registerName("doCommandBySelector:"),
		rawptr(on_metal_command),
		"v@::",
	)
	class_addMethod(
		class,
		sel_registerName("setMarkedText:selectedRange:replacementRange:"),
		rawptr(on_metal_set_marked),
		"v@:@{_NSRange=QQ}{_NSRange=QQ}",
	)
	class_addMethod(class, sel_registerName("unmarkText"), rawptr(on_metal_unmark), "v@:")
	class_addMethod(class, sel_registerName("hasMarkedText"), rawptr(on_metal_has_marked), "B@:")
	class_addMethod(
		class,
		sel_registerName("markedRange"),
		rawptr(on_metal_range),
		"{_NSRange=QQ}@:",
	)
	class_addMethod(
		class,
		sel_registerName("selectedRange"),
		rawptr(on_metal_range),
		"{_NSRange=QQ}@:",
	)
	class_addMethod(
		class,
		sel_registerName("validAttributesForMarkedText"),
		rawptr(on_metal_valid_attributes),
		"@@:",
	)
	class_addMethod(
		class,
		sel_registerName("attributedSubstringForProposedRange:actualRange:"),
		rawptr(on_metal_attributed_substring),
		"@@:{_NSRange=QQ}^{_NSRange=QQ}",
	)
	class_addMethod(
		class,
		sel_registerName("characterIndexForPoint:"),
		rawptr(on_metal_character_index),
		"Q@:{CGPoint=dd}",
	)
	class_addMethod(
		class,
		sel_registerName("firstRectForCharacterRange:actualRange:"),
		rawptr(on_metal_first_rect),
		"{CGRect={CGPoint=dd}{CGSize=dd}}@:{_NSRange=QQ}^{_NSRange=QQ}",
	)
	class_addMethod(
		class,
		sel_registerName("isAccessibilityElement"),
		rawptr(on_metal_is_ax_element),
		"B@:",
	)
	class_addMethod(
		class,
		sel_registerName("accessibilityChildren"),
		rawptr(on_metal_ax_children),
		"@@:",
	)
	objc_registerClassPair(class)
	return class
}

register_accessibility_class :: proc() {
	class := objc_allocateClassPair(
		objc_getClass("NSAccessibilityElement"),
		"VocalAccessibilityElement",
		0,
	)
	class_addMethod(
		class,
		sel_registerName("accessibilityPerformPress"),
		rawptr(on_ax_press),
		"B@:",
	)
	class_addMethod(class, sel_registerName("accessibilityValue"), rawptr(on_ax_value), "@@:")
	class_addMethod(
		class,
		sel_registerName("setAccessibilityValue:"),
		rawptr(on_ax_set_value),
		"v@:@",
	)
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
	ui.active_exercise = -1
	ui.transcript_matches_dirty = true
	ui.needs_redraw = true
	flash.state_init(&flash_state)
	palette_error := command_palette.state_init(&command_palette_state)
	assert(palette_error == nil, "Unable to initialize the command palette")

	frame := Rect{Point{120, 100}, Size{1100, 720}}
	state.window = msg_id_rect_u_u_b(
		msg_id(objc_getClass("NSWindow"), sel_registerName("alloc")),
		sel_registerName("initWithContentRect:styleMask:backing:defer:"),
		frame,
		32783,
		2,
		false,
	)
	msg_void_id(state.window, sel_registerName("setTitle:"), nsstring("Vocal Training"))
	msg_void_i(state.window, sel_registerName("setTitleVisibility:"), 1)
	msg_void_bool(state.window, sel_registerName("setTitlebarAppearsTransparent:"), true)
	msg_void_i(state.window, sel_registerName("setTitlebarSeparatorStyle:"), 0)
	msg_void_bool(state.window, sel_registerName("setAcceptsMouseMovedEvents:"), true)
	register_accessibility_class()
	view_class := register_metal_view_class()
	ui.view = msg_id_rect(
		msg_id(view_class, sel_registerName("alloc")),
		sel_registerName("initWithFrame:"),
		Rect{Point{0, 0}, frame.size},
	)
	msg_void_id(state.window, sel_registerName("setContentView:"), ui.view)

	ui.device = MTLCreateSystemDefaultDevice()
	assert_foreign(rawptr(ui.device), "MTLCreateSystemDefaultDevice failed")
	ui.queue = msg_id(ui.device, sel_registerName("newCommandQueue"))
	assert_foreign(rawptr(ui.queue), "Unable to create the Metal command queue")
	ui.layer = msg_id(objc_getClass("CAMetalLayer"), sel_registerName("layer"))
	assert_foreign(rawptr(ui.layer), "Unable to create CAMetalLayer")
	msg_void_id(ui.layer, sel_registerName("setDevice:"), ui.device)
	msg_void_i(ui.layer, sel_registerName("setPixelFormat:"), 80)
	msg_void_bool(ui.layer, sel_registerName("setFramebufferOnly:"), true)
	msg_void_bool(ui.view, sel_registerName("setWantsLayer:"), true)
	msg_void_id(ui.view, sel_registerName("setLayer:"), ui.layer)
	cache_status := CVMetalTextureCacheCreate(nil, nil, ui.device, nil, &ui.texture_cache)
	when ODIN_DEBUG {
		assert(
			cache_status == 0 && ui.texture_cache != nil,
			"Unable to create CVMetalTextureCache",
		)
	}
	if !compile_pipelines() {
		fmt.eprintln("Unable to compile Metal UI pipelines")
		return
	}

	if len(state.sources) > 0 {load_source_player(len(state.sources) - 1)}
	// The Objective-C runtime requires the exact floating-point signature, so
	// construct the repeating timer through a typed send.
	timer_send := transmute(proc "c" (
		_: Id,
		_: Sel,
		_: f64,
		_: Id,
		_: Sel,
		_: Id,
		_: bool,
	) -> Id)send_address
	_ = timer_send(
		objc_getClass("NSTimer"),
		sel_registerName("scheduledTimerWithTimeInterval:target:selector:userInfo:repeats:"),
		1.0 / 60.0,
		state.delegate_target,
		sel_registerName("metalFrame:"),
		nil,
		true,
	)

	screen := msg_id(objc_getClass("NSScreen"), sel_registerName("mainScreen"))
	msg_void_rect_b(
		state.window,
		sel_registerName("setFrame:display:"),
		msg_rect(screen, sel_registerName("visibleFrame")),
		true,
	)
	msg_void_id(state.window, sel_registerName("makeFirstResponder:"), ui.view)
	msg_void_id(state.window, sel_registerName("makeKeyAndOrderFront:"), nil)
	msg_void_i(app, sel_registerName("activateIgnoringOtherApps:"), 1)
	if !cli_ipc_server_start() {set_text(state.status, "CLI control socket is unavailable")}
	validate_startup_helpers()
	request_next_missing_source_metadata()
	msg_void(app, sel_registerName("run"))
}
