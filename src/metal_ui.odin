package main

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:hash"
import "core:math"
import mem_virtual "core:mem/virtual"
import "core:os"
import "core:strings"
import posix "core:sys/posix"
import CF "core:sys/darwin/CoreFoundation"
import command_palette "command_palette:."
import text_input "components:text_input"
import flash "flash:."
import match_sorter "match_sorter:."
import hot_reload "../dev/hot_reload_contract"

foreign import metal "system:Metal.framework"
foreign metal {
	MTLCreateSystemDefaultDevice :: proc "c" () -> Id ---
}

foreign import avfaudio "system:AVFAudio.framework"
foreign avfaudio {
	AVAudioEngineConfigurationChangeNotification: Id
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
	CGContextSetRGBStrokeColor :: proc "c" (ctx: rawptr, red, green, blue, alpha: f64) ---
	CGContextSetLineWidth :: proc "c" (ctx: rawptr, width: f64) ---
	CGContextSetLineCap :: proc "c" (ctx: rawptr, cap: i32) ---
	CGContextSetLineJoin :: proc "c" (ctx: rawptr, join: i32) ---
	CGContextBeginPath :: proc "c" (ctx: rawptr) ---
	CGContextMoveToPoint :: proc "c" (ctx: rawptr, x, y: f64) ---
	CGContextAddLineToPoint :: proc "c" (ctx: rawptr, x, y: f64) ---
	CGContextStrokePath :: proc "c" (ctx: rawptr) ---
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
	Exercise_Rename,
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
	using input_state:  text_input.State,
	palette_previous_input: text_input.Focus_Snapshot,
	mode:               UI_Mode,
	dark_theme:         bool,
	source_modal_open:  bool,
	source_modal_refetch_index: int,
	source_details_open: bool,
	source_details_index: int,
	exercise_rename_open: bool,
	exercise_rename_index: int,
	exercise_metadata_open: bool,
	exercise_metadata_index: int,
	randomize_help_open: bool,
	data_modal_open: bool,
	notification_modal_open: bool,
	library_import_confirm_open: bool,
	library_import_pending: bool,
	url_input:          string,
	source_search:      string,
	transcript_search:  string,
	exercise_search:    string,
	exercise_name:      string,
	exercise_rename:    string,
	command_palette_query: string,
	command_palette_scroll: f64,
	notification_scroll: f64,
	status:             string,
	status_source_video_id: string,
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
	player_volume:      f32,
	playback_rate:      f32,
	player_duration:    f64,
	source_playback_active: bool,
	source_scrubbing:   bool,
	source_hint_menu_open: bool,
	pitch:              Pitch_Monitor_State,
	activity_tick:      uint,
	frame_tick:         uint,
	render_count:         uint,
	url_probe_due_tick: uint,
	url_probe_pending:  bool,
	save_source_browser_choice: bool,
	resize_edges:        u8,
	resize_start_mouse:  Point,
	resize_start_frame:  Rect,
	window_zoom_restore_frame: Rect,
	window_has_zoom_restore: bool,
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

UI_FONT_NAME :: "Iosevka"
SMALL_FONT_SIZE :: 10.5
APP_HEADER_HEIGHT :: 38.0
UI_COLOR_SAND_32 :: [4]f32{0.882353, 0.850980, 0.788235, 1}
UI_COLOR_STONE_32 :: [4]f32{0.682353, 0.576471, 0.447059, 1}
UI_COLOR_COFFEE_32 :: [4]f32{0.698039, 0.490196, 0.341176, 1}
UI_COLOR_OCHRE_32 :: [4]f32{0.498039, 0.294118, 0.188235, 1}
UI_COLOR_GUM_32 :: [4]f32{0.490196, 0.529412, 0.411765, 1}
UI_COLOR_MOSS_32 :: [4]f32{0.258824, 0.298039, 0.129412, 1}
UI_COLOR_FOREST_32 :: [4]f32{0.090196, 0.192157, 0.145098, 1}
UI_COLOR_BASALT_32 :: [4]f32{0.129412, 0.180392, 0.250980, 1}
UI_COLOR_SAND_64 :: [4]f64{0.882353, 0.850980, 0.788235, 1}
UI_COLOR_STONE_64 :: [4]f64{0.682353, 0.576471, 0.447059, 1}
UI_COLOR_COFFEE_64 :: [4]f64{0.698039, 0.490196, 0.341176, 1}
UI_COLOR_OCHRE_64 :: [4]f64{0.498039, 0.294118, 0.188235, 1}
UI_COLOR_GUM_64 :: [4]f64{0.490196, 0.529412, 0.411765, 1}
UI_COLOR_MOSS_64 :: [4]f64{0.258824, 0.298039, 0.129412, 1}
UI_COLOR_FOREST_64 :: [4]f64{0.090196, 0.192157, 0.145098, 1}
UI_COLOR_BASALT_64 :: [4]f64{0.129412, 0.180392, 0.250980, 1}

UI_Theme_Colors :: struct {
	chassis, header, panel, panel_alt, field: [4]f64,
	border, rule, row, row_hover: [4]f64,
	backdrop, modal: [4]f64,
	ink, bright, muted, dim: [4]f64,
}

ui_theme_colors :: proc(dark_theme := ui.dark_theme) -> UI_Theme_Colors {
	if dark_theme {
		return {
			chassis = {0.040, 0.043, 0.041, 1},
			header = {0.032, 0.034, 0.033, 1},
			panel = {0.055, 0.059, 0.056, 1},
			panel_alt = {0.067, 0.071, 0.067, 1},
			field = {0.067, 0.072, 0.068, 1},
			border = {0.218, 0.225, 0.210, 1},
			rule = {0.125, 0.132, 0.123, 1},
			row = {0.060, 0.064, 0.061, 0.96},
			row_hover = {0.085, 0.091, 0.086, 1},
			backdrop = {0.008, 0.009, 0.009, 0.88},
			modal = {0.055, 0.059, 0.056, 1},
			ink = {0.89, 0.88, 0.82, 1},
			bright = {0.97, 0.95, 0.88, 1},
			muted = {0.47, 0.49, 0.46, 1},
			dim = {0.31, 0.33, 0.31, 1},
		}
	}
	return {
		chassis = {0.80, 0.78, 0.72, 1},
		header = {0.91, 0.89, 0.82, 1},
		panel = {0.88, 0.86, 0.79, 1},
		panel_alt = {0.85, 0.83, 0.76, 1},
		field = {0.83, 0.81, 0.74, 1},
		border = {0.27, 0.26, 0.28, 1},
		rule = {0.76, 0.73, 0.66, 1},
		row = {0.88, 0.86, 0.79, 0.96},
		row_hover = {0.80, 0.78, 0.72, 1},
		backdrop = {0.15, 0.145, 0.16, 0.78},
		modal = {0.91, 0.89, 0.82, 1},
		ink = {0.15, 0.145, 0.16, 1},
		bright = {0.15, 0.145, 0.16, 1},
		muted = {0.48, 0.46, 0.42, 1},
		dim = {0.62, 0.60, 0.55, 1},
	}
}

ui_color_32 :: proc(color: [4]f64) -> [4]f32 {
	return {f32(color[0]), f32(color[1]), f32(color[2]), f32(color[3])}
}

ui_theme_toggle_label :: proc(dark_theme: bool) -> string {
	return dark_theme ? "LIGHT" : "DARK"
}

WINDOW_STYLE :: uint(14)
WINDOW_MINIMIZE_STYLE :: uint(15)
WINDOW_RESIZE_INSET :: 6.0
WINDOW_MIN_WIDTH :: 1100.0
WINDOW_MIN_HEIGHT :: 720.0
ACCENT_EDGE_WIDTH :: 4.0
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
	Window_Close,
	Window_Minimize,
	Window_Zoom,
	Theme_Toggle,
	Mode_Toggle,
	Open_Source_Modal,
	Cancel_Source_Modal,
	Close_Source_Details,
	Refetch_Source_Details,
	Open_Source_Details,
	URL,
	Import,
	Source_Quality,
	Retry_Source_With_Browser,
	Toggle_Save_Source_Browser,
	Stop_Download,
	View_Status_Source,
	Open_Notification_History,
	Close_Notification_History,
	Select_Notification,
	Activate_Notification_Action,
	Source_Search,
	Transcript_Search,
	Source,
	Transcript,
	Exercise_Search,
	Exercise,
	Randomize,
	Open_Randomize_Help,
	Close_Randomize_Help,
	Pitch_Toggle,
	Pitch_Reference_Down,
	Pitch_Reference_Up,
	Pitch_Range,
	Pitch_Labels,
	Pitch_Transpose,
	Pitch_Highlight,
	Pitch_Chart,
	Open_Pitch_Help,
	Close_Pitch_Help,
	Exercise_Name,
	Cancel_Exercise_Rename,
	Confirm_Exercise_Rename,
	Exercise_Rename,
	Close_Exercise_Metadata,
	View_Exercise_Source,
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
	Rename,
	Metadata,
	Close_Data_Modal,
	Open_Data_Folder,
	Export_Library,
	Import_Library,
	Cancel_Library_Import,
	Confirm_Library_Import,
	Recovery_Backup_Only,
	Recovery_Backup_With_Salvage,
	Recovery_Salvage_Only,
	Recovery_Cancel,
	Recovery_Confirm,
	Backup_Warning_Cancel,
	Backup_Warning_Continue,
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
	controls:           [dynamic]UI_Control,
	diagnostic_surface: UI_Diagnostic_Surface,
	frame:              int,
}

ui := UI_State{player_volume = 1, playback_rate = 1, source_details_index = -1, source_modal_refetch_index = -1, exercise_rename_index = -1, exercise_metadata_index = -1, transcript_active_match = -1}
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

msg_bool_id_id :: proc(receiver: Id, selector: Sel, a, b: Id) -> bool {
	p := transmute(proc "c" (_: Id, _: Sel, _: Id, _: Id) -> bool)send_address
	return p(receiver, selector, a, b)
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

msg_void_id_sel_id_id :: proc(receiver: Id, selector: Sel, observer: Id, action: Sel, name, object: Id) {
	p := transmute(proc "c" (_: Id, _: Sel, _: Id, _: Sel, _: Id, _: Id))send_address
	p(receiver, selector, observer, action, name, object)
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
	return text_input.previous_character_offset(text, offset)
}

next_character_offset :: proc(text: string, offset: int) -> int {
	return text_input.next_character_offset(text, offset)
}

text_selection_bounds :: proc(text: string) -> (start, end: int) {
	return text_input.selection_bounds(&ui.input_state, text)
}

text_has_selection :: proc(text: string) -> bool {
	return text_input.has_selection(&ui.input_state, text)
}

collapse_text_selection :: proc(offset: int) {
	target := focused_text()
	if target != nil {
		text_input.collapse_selection(&ui.input_state, target^, offset)
	} else {
		ui.caret_byte_offset = max(0, offset)
		ui.selection_anchor_byte = ui.caret_byte_offset
	}
	ui.needs_redraw = true
}

set_text_selection :: proc(anchor, active: int, text: string) {
	text_input.set_selection(&ui.input_state, text, anchor, active)
	ui.needs_redraw = true
}

remove_text_selection :: proc(target: ^string) -> bool {
	changed := text_input.remove_selection(&ui.input_state, target)
	ui.needs_redraw = ui.needs_redraw || changed
	return changed
}

replace_text_selection :: proc(target: ^string, value: string) {
	if text_input.replace_selection(&ui.input_state, target, value) {
		ui.needs_redraw = true
	}
}

text_word_bounds :: proc(text: string, offset: int) -> (start, end: int) {
	return text_input.word_bounds(text, offset)
}

byte_offset_for_utf16_index :: proc(text: string, target_index: int) -> int {
	return text_input.byte_offset_for_utf16_index(text, target_index)
}

insert_text_at_caret :: proc(target: ^string, value: string) {
	if text_input.insert_text(&ui.input_state, target, value) {
		ui.needs_redraw = true
	}
}

remove_character_before_caret :: proc(target: ^string) {
	if text_input.delete_backward(&ui.input_state, target) {
		ui.needs_redraw = true
	}
}

remove_character_after_caret :: proc(target: ^string) {
	if text_input.delete_forward(&ui.input_state, target) {
		ui.needs_redraw = true
	}
}

remove_word_before_caret :: proc(target: ^string) {
	if text_input.delete_word_backward(&ui.input_state, target) {
		ui.needs_redraw = true
	}
}

line_start_for_offset :: proc(text: string, offset: int) -> int {
	return text_input.line_start_for_offset(text, offset)
}

line_end_for_offset :: proc(text: string, offset: int) -> int {
	return text_input.line_end_for_offset(text, offset)
}

character_column_for_offset :: proc(text: string, line_start, offset: int) -> int {
	return text_input.character_column_for_offset(text, line_start, offset)
}

offset_for_character_column :: proc(
	text: string,
	line_start, line_end, column: int,
) -> int {
	return text_input.offset_for_character_column(
		text,
		line_start,
		line_end,
		column,
	)
}

vertical_text_offset :: proc(text: string, offset, direction: int) -> int {
	return text_input.vertical_offset(text, offset, direction)
}

move_text_selection :: proc(target: ^string, destination: int, extend: bool) {
	text_input.move_selection(
		&ui.input_state,
		target^,
		destination,
		extend,
	)
	ui.needs_redraw = true
}

move_text_left :: proc(target: ^string, extend: bool) {
	text_input.move_left(&ui.input_state, target^, extend)
	ui.needs_redraw = true
}

move_text_right :: proc(target: ^string, extend: bool) {
	text_input.move_right(&ui.input_state, target^, extend)
	ui.needs_redraw = true
}

previous_word_offset :: proc(text: string, offset: int) -> int {
	return text_input.previous_word_offset(text, offset)
}

next_word_offset :: proc(text: string, offset: int) -> int {
	return text_input.next_word_offset(text, offset)
}

move_text_word_left :: proc(target: ^string, extend: bool) {
	text_input.move_word_left(&ui.input_state, target^, extend)
	ui.needs_redraw = true
}

move_text_word_right :: proc(target: ^string, extend: bool) {
	text_input.move_word_right(&ui.input_state, target^, extend)
	ui.needs_redraw = true
}

clear_marked_text :: proc() {
	text_input.clear_marked_text(&ui.input_state)
}

remove_marked_text :: proc(target: ^string) {
	if text_input.remove_marked_text(&ui.input_state, target) {
		ui.needs_redraw = true
	}
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
	case .Exercise_Rename:
		return &ui.exercise_rename
	}
	return nil
}

focused_text_changed :: proc(target: ^string) {
	if target == &ui.command_palette_query {
		search_error := command_palette.set_query(
			&command_palette_state,
			ui.command_palette_query,
		)
		if search_error != .None {
			ui_set_string(
				&ui.command_palette_query,
				command_palette.query(&command_palette_state),
			)
			_ = notification_post_error(
				"Command palette search contains invalid UTF-8.",
			)
		}
		ui.command_palette_scroll = 0
		ensure_command_palette_selection_visible()
	}
	if target == &ui.url_input {schedule_source_probe(30)}
	if target == &ui.transcript_search {invalidate_transcript_matches()}
}

text_field_id :: proc(focus: UI_Focus) -> text_input.Field_ID {
	return text_input.Field_ID(focus)
}

focus_text_input :: proc(focus: UI_Focus) {
	changed := ui.focus != focus
	ui.focus = focus
	if target := focused_text(); target != nil {
		if changed {
			ui.input_state.active_field = text_input.NO_FIELD
		}
		_ = text_input.focus(
			&ui.input_state,
			text_field_id(focus),
			target^,
		)
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
	_ = text_input.blur(&ui.input_state, target)
	if had_marked_text && target != nil {focused_text_changed(target)}
	ui.focus = .None
	text_input.end_pointer_selection(&ui.input_state)
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

left_accent_edge_rect :: proc(rect: UI_Rect) -> UI_Rect {
	return UI_Rect{rect.x, rect.y, ACCENT_EDGE_WIDTH, rect.h}
}

bottom_progress_edge_rect :: proc(rect: UI_Rect, progress: f64) -> UI_Rect {
	return UI_Rect{
		rect.x,
		rect.y,
		rect.w*clamp(progress, 0, 1),
		ACCENT_EDGE_WIDTH,
	}
}

mode_button_rect_for_size :: proc(width, height: f64) -> UI_Rect {
	return UI_Rect{max(18, width - 214), height - 31, 196, 24}
}

theme_button_rect_for_size :: proc(width, height: f64) -> UI_Rect {
	mode := mode_button_rect_for_size(width, height)
	return UI_Rect{mode.x-70, height-31, 62, 24}
}

theme_button_rect :: proc() -> UI_Rect {
	return theme_button_rect_for_size(ui.width, ui.height)
}

app_header_rect_for_size :: proc(width, height: f64) -> UI_Rect {
	return UI_Rect{0, height - APP_HEADER_HEIGHT, width, APP_HEADER_HEIGHT}
}

app_header_rect :: proc() -> UI_Rect {
	return app_header_rect_for_size(ui.width, ui.height)
}

window_control_rect_for_size :: proc(index: int, height: f64) -> UI_Rect {
	return UI_Rect{
		38*f64(index),
		height-30,
		30,
		30,
	}
}

window_control_rect :: proc(index: int) -> UI_Rect {
	return window_control_rect_for_size(index, ui.height)
}

window_icon_rect :: proc(index: int) -> UI_Rect {
	control := window_control_rect(index)
	return UI_Rect{control.x+5, control.y+5, 20, 20}
}

app_title_rect_for_size :: proc(width, height: f64) -> UI_Rect {
	theme := theme_button_rect_for_size(width, height)
	x := 122.0
	return UI_Rect{
		x,
		height-APP_HEADER_HEIGHT+2,
		max(0, theme.x-x-12),
		APP_HEADER_HEIGHT-2,
	}
}

app_title_rect :: proc() -> UI_Rect {
	return app_title_rect_for_size(ui.width, ui.height)
}

window_resize_edges_for_size :: proc(
	point: Point,
	width, height: f64,
) -> u8 {
	edges := u8(0)
	if point.x <= WINDOW_RESIZE_INSET {edges |= 1}
	if point.x >= width-WINDOW_RESIZE_INSET {edges |= 2}
	if point.y <= WINDOW_RESIZE_INSET {edges |= 4}
	if point.y >= height-WINDOW_RESIZE_INSET {edges |= 8}
	return edges
}

window_frame_after_drag :: proc(
	start: Rect,
	edges: u8,
	delta: Point,
) -> Rect {
	frame := start
	if edges&1 != 0 {
		frame.size.width = max(WINDOW_MIN_WIDTH, start.size.width-delta.x)
		frame.origin.x = start.origin.x+start.size.width-frame.size.width
	} else if edges&2 != 0 {
		frame.size.width = max(WINDOW_MIN_WIDTH, start.size.width+delta.x)
	}
	if edges&4 != 0 {
		frame.size.height = max(WINDOW_MIN_HEIGHT, start.size.height-delta.y)
		frame.origin.y = start.origin.y+start.size.height-frame.size.height
	} else if edges&8 != 0 {
		frame.size.height = max(WINDOW_MIN_HEIGHT, start.size.height+delta.y)
	}
	return frame
}

window_zoom_next_frame :: proc(
	current, visible, restore: Rect,
	has_restore: bool,
) -> (next, next_restore: Rect, next_has_restore: bool) {
	if has_restore && current == visible {
		return restore, {}, false
	}
	return visible, current, true
}

toggle_window_zoom :: proc() {
	screen := msg_id(state.window, sel_registerName("screen"))
	if screen == nil {
		screen = msg_id(objc_getClass("NSScreen"), sel_registerName("mainScreen"))
	}
	if screen == nil {return}
	current := msg_rect(state.window, sel_registerName("frame"))
	visible := msg_rect(screen, sel_registerName("visibleFrame"))
	next, restore, has_restore := window_zoom_next_frame(
		current,
		visible,
		ui.window_zoom_restore_frame,
		ui.window_has_zoom_restore,
	)
	ui.window_zoom_restore_frame = restore
	ui.window_has_zoom_restore = has_restore
	msg_void_rect_b(
		state.window,
		sel_registerName("setFrame:display:"),
		next,
		true,
	)
	ui.needs_redraw = true
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

source_probe_row_height :: proc(index: int) -> f64 {
	if index >= 0 &&
	   index < len(source_probe_results) &&
	   source_probe_browser_retry_available(source_probe_results[index]) {
		return 120
	}
	return 62
}

source_probe_row_rect :: proc(modal: UI_Rect, index: int) -> UI_Rect {
	input := source_modal_input_rect(modal)
	top := input.y - 8
	for previous_index in 0 ..< index {
		top -= source_probe_row_height(previous_index) + 6
	}
	height := source_probe_row_height(index)
	return UI_Rect{modal.x + 24, top - height, modal.w - 48, height}
}

source_probe_quality_rect :: proc(row: UI_Rect, option_index: int) -> UI_Rect {
	return UI_Rect{row.x + 390 + f64(option_index) * 66, row.y + 8, 60, 24}
}

source_probe_browser_rect :: proc(
	row: UI_Rect,
	option_index, option_count: int,
) -> UI_Rect {
	left := row.x + 10
	right := row.x + row.w - 10
	gap := 6.0
	width := (
		right - left - f64(max(0, option_count-1))*gap
	) / f64(max(1, option_count))
	return UI_Rect{
		left + f64(option_index)*(width+gap),
		row.y + 6,
		width,
		24,
	}
}

source_probe_save_browser_rect :: proc(row: UI_Rect) -> UI_Rect {
	return UI_Rect{row.x + 10, row.y + 36, 220, 24}
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

exercise_rename_modal_rect_for_size :: proc(view_width, view_height: f64) -> UI_Rect {
	width := min(max(560, view_width * 0.52), 720)
	height := min(max(300, view_height * 0.42), 380)
	return UI_Rect{(view_width - width) / 2, (view_height - height) / 2, width, height}
}

exercise_rename_modal_rect :: proc() -> UI_Rect {
	return exercise_rename_modal_rect_for_size(ui.width, ui.height)
}

exercise_rename_input_rect :: proc(modal: UI_Rect) -> UI_Rect {
	return UI_Rect{modal.x + 24, modal.y + 82, modal.w - 48, 36}
}

exercise_rename_cancel_rect :: proc(modal: UI_Rect) -> UI_Rect {
	return UI_Rect{modal.x + 24, modal.y + 24, 124, 34}
}

exercise_rename_confirm_rect :: proc(modal: UI_Rect) -> UI_Rect {
	return UI_Rect{modal.x + modal.w - 180, modal.y + 24, 156, 34}
}

exercise_metadata_modal_rect_for_size :: proc(view_width, view_height: f64) -> UI_Rect {
	width := min(max(620, view_width * 0.58), 780)
	height := min(max(500, view_height * 0.68), 580)
	return UI_Rect{(view_width - width) / 2, (view_height - height) / 2, width, height}
}

exercise_metadata_modal_rect :: proc() -> UI_Rect {
	return exercise_metadata_modal_rect_for_size(ui.width, ui.height)
}

exercise_metadata_row_rect :: proc(modal: UI_Rect, row: int) -> UI_Rect {
	return UI_Rect{modal.x + 24, modal.y + modal.h - 142 - f64(row) * 32, modal.w - 48, 30}
}

exercise_metadata_close_rect :: proc(modal: UI_Rect) -> UI_Rect {
	return UI_Rect{modal.x + 24, modal.y + 22, 112, 34}
}

randomize_help_modal_rect :: proc() -> UI_Rect {
	width := min(max(720, ui.width * 0.6), 920)
	height := min(max(640, ui.height * 0.72), 700)
	return UI_Rect{(ui.width - width) / 2, (ui.height - height) / 2, width, height}
}

randomize_help_close_rect :: proc(modal: UI_Rect) -> UI_Rect {
	return UI_Rect{modal.x + 24, modal.y + 22, 112, 34}
}

pitch_help_modal_rect :: proc() -> UI_Rect {
	width := min(max(620, ui.width * 0.54), 760)
	height := min(max(390, ui.height * 0.5), 470)
	return UI_Rect{(ui.width - width) / 2, (ui.height - height) / 2, width, height}
}

pitch_help_close_rect :: proc(modal: UI_Rect) -> UI_Rect {
	return UI_Rect{modal.x + 24, modal.y + 22, 112, 34}
}

randomize_help_row_rect :: proc(modal: UI_Rect, row: int) -> UI_Rect {
	return UI_Rect{
		modal.x + 24,
		modal.y + modal.h - 284 - f64(row) * 30,
		modal.w - 48,
		29,
	}
}

data_modal_rect :: proc() -> UI_Rect {
	width := min(max(560, ui.width * 0.5), 680)
	height := min(max(330, ui.height * 0.42), 390)
	return UI_Rect{(ui.width - width) / 2, (ui.height - height) / 2, width, height}
}

data_modal_action_rect :: proc(modal: UI_Rect, row: int) -> UI_Rect {
	return UI_Rect{
		modal.x + 24,
		modal.y + modal.h - 116 - f64(row) * 52,
		modal.w - 48,
		40,
	}
}

data_modal_close_rect :: proc(modal: UI_Rect) -> UI_Rect {
	return UI_Rect{modal.x + 24, modal.y + 22, 112, 34}
}

recovery_modal_rect :: proc() -> UI_Rect {
	width := min(max(680, ui.width * 0.68), 860)
	height := min(max(500, ui.height * 0.72), 620)
	return UI_Rect{(ui.width-width)/2, (ui.height-height)/2, width, height}
}

recovery_action_rect :: proc(modal: UI_Rect, row: int) -> UI_Rect {
	return UI_Rect{
		modal.x + 24,
		modal.y + modal.h - 268 - f64(row)*58,
		modal.w - 48,
		44,
	}
}

recovery_cancel_rect :: proc(modal: UI_Rect) -> UI_Rect {
	return UI_Rect{modal.x + 24, modal.y + 24, 124, 38}
}

recovery_confirm_rect :: proc(modal: UI_Rect) -> UI_Rect {
	return UI_Rect{modal.x + modal.w - 224, modal.y + 24, 200, 38}
}

backup_warning_modal_rect :: proc() -> UI_Rect {
	width := min(max(600, ui.width*0.58), 760)
	height := 330.0
	return UI_Rect{(ui.width-width)/2, (ui.height-height)/2, width, height}
}

notification_modal_rect_for_size :: proc(
	view_width, view_height: f64,
) -> UI_Rect {
	width := min(max(720, view_width * 0.76), 1040)
	height := min(max(480, view_height * 0.72), 700)
	return UI_Rect{
		(view_width - width) / 2,
		(view_height - height) / 2,
		width,
		height,
	}
}

notification_modal_rect :: proc() -> UI_Rect {
	return notification_modal_rect_for_size(ui.width, ui.height)
}

notification_list_rect :: proc(modal: UI_Rect) -> UI_Rect {
	return UI_Rect{
		modal.x + 24,
		modal.y + 72,
		max(260, modal.w * 0.38),
		modal.h - 144,
	}
}

notification_detail_rect :: proc(modal: UI_Rect) -> UI_Rect {
	list := notification_list_rect(modal)
	x := list.x + list.w + 18
	return UI_Rect{x, list.y, modal.x + modal.w - 24 - x, list.h}
}

notification_history_close_rect :: proc(modal: UI_Rect) -> UI_Rect {
	return UI_Rect{modal.x + 24, modal.y + 22, 112, 34}
}

notification_history_action_rect :: proc(modal: UI_Rect) -> UI_Rect {
	detail := notification_detail_rect(modal)
	return UI_Rect{detail.x + detail.w - 164, modal.y + 22, 164, 34}
}

NOTIFICATION_ROW_HEIGHT :: 58.0

notification_visible_row_count :: proc(modal: UI_Rect) -> int {
	return max(1, int(notification_list_rect(modal).h / NOTIFICATION_ROW_HEIGHT))
}

notification_max_scroll :: proc(modal: UI_Rect) -> f64 {
	return f64(max(
		0,
		len(notification_history.entries) - notification_visible_row_count(modal),
	))
}

notification_scroll_after_delta :: proc(
	current, delta, maximum: f64,
) -> f64 {
	return min(
		max(0, current - delta / NOTIFICATION_ROW_HEIGHT),
		maximum,
	)
}

notification_first_visible :: proc(modal: UI_Rect) -> int {
	return min(
		max(0, int(ui.notification_scroll)),
		int(notification_max_scroll(modal)),
	)
}

notification_row_rect :: proc(modal: UI_Rect, visible_index: int) -> UI_Rect {
	list := notification_list_rect(modal)
	return UI_Rect{
		list.x,
		list.y + list.h - NOTIFICATION_ROW_HEIGHT * f64(visible_index + 1),
		list.w,
		NOTIFICATION_ROW_HEIGHT,
	}
}

notification_for_visible_row :: proc(
	modal: UI_Rect,
	visible_index: int,
) -> ^Notification {
	newest_offset := notification_first_visible(modal) + visible_index
	history_index := len(notification_history.entries) - 1 - newest_offset
	if history_index < 0 || history_index >= len(notification_history.entries) {
		return nil
	}
	return &notification_history.entries[history_index]
}

notification_selected :: proc() -> ^Notification {
	return notification_find(notification_history.selected_id)
}

notification_action_available :: proc(notification: ^Notification) -> bool {
	if notification == nil {return false}
	switch notification.action_kind {
	case .View_Source:
		return source_index_for_video_id(
			state.sources[:],
			notification.action_target,
		) >= 0
	case .None:
		return false
	}
	return false
}

open_notification_history :: proc(notification_id: i64 = 0) {
	cancel_ui_flash()
	if ui.data_modal_open {close_data_modal()}
	if ui.exercise_rename_open {close_exercise_rename()}
	if ui.exercise_metadata_open {close_exercise_metadata()}
	if ui.randomize_help_open {close_randomize_help()}
	if ui.pitch.help_open {close_pitch_help()}
	if ui.source_details_open {close_source_details()}
	if ui.source_modal_open {close_source_modal()}
	ui.notification_modal_open = true
	ui.focus = .None
	text_input.end_pointer_selection(&ui.input_state)
	ui.notification_scroll = 0
	selected := notification_find(notification_id)
	if selected == nil {selected = notification_find(notification_history.current_id)}
	if selected == nil {selected = notification_latest()}
	notification_history.selected_id = selected != nil ? selected.id : 0
	ui.needs_redraw = true
}

close_notification_history :: proc() {
	cancel_ui_flash()
	ui.notification_modal_open = false
	ui.notification_scroll = 0
	notification_history.selected_id = 0
	ui.needs_redraw = true
}

select_notification :: proc(id: i64) -> bool {
	if notification_find(id) == nil {return false}
	notification_history.selected_id = id
	ui.needs_redraw = true
	return true
}

select_relative_notification :: proc(direction: int) -> bool {
	if len(notification_history.entries) == 0 {return false}
	index := len(notification_history.entries) - 1
	for notification, candidate in notification_history.entries {
		if notification.id == notification_history.selected_id {
			index = candidate
			break
		}
	}
	index = min(max(0, index + direction), len(notification_history.entries) - 1)
	notification_history.selected_id = notification_history.entries[index].id
	newest_offset := len(notification_history.entries) - 1 - index
	visible := notification_visible_row_count(notification_modal_rect())
	if newest_offset < int(ui.notification_scroll) {
		ui.notification_scroll = f64(newest_offset)
	} else if newest_offset >= int(ui.notification_scroll) + visible {
		ui.notification_scroll = f64(newest_offset - visible + 1)
	}
	ui.needs_redraw = true
	return true
}

activate_notification_action :: proc() -> bool {
	notification := notification_selected()
	if !notification_action_available(notification) {return false}
	switch notification.action_kind {
	case .View_Source:
		source_index := source_index_for_video_id(
			state.sources[:],
			notification.action_target,
		)
		if source_index < 0 {return false}
		close_notification_history()
		set_ui_mode(.Create)
		ui_event_tag = source_index
		on_select_source(nil, nil, nil)
		return true
	case .None:
		return false
	}
	return false
}

library_import_cancel_rect :: proc(modal: UI_Rect) -> UI_Rect {
	return UI_Rect{modal.x + 24, modal.y + 22, 124, 34}
}

library_import_confirm_rect :: proc(modal: UI_Rect) -> UI_Rect {
	return UI_Rect{modal.x + modal.w - 230, modal.y + 22, 206, 34}
}

exercise_metadata_source_rect :: proc(modal: UI_Rect) -> UI_Rect {
	return UI_Rect{modal.x + modal.w - 204, modal.y + 22, 180, 34}
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
	text_input.end_pointer_selection(&ui.input_state)
	clear_marked_text()
	ui.needs_redraw = true
	source := &state.sources[source_index]
	request_source_metadata(source.video_id, source.media_path)
}

open_exercise_rename :: proc() {
	cancel_ui_flash()
	if ui.active_exercise < 0 || ui.active_exercise >= len(state.exercises) {return}
	ui.exercise_rename_index = ui.active_exercise
	ui.exercise_rename_open = true
	ui_set_string(&ui.exercise_rename, state.exercises[ui.exercise_rename_index].name)
	focus_text_input(.Exercise_Rename)
}

close_exercise_rename :: proc() {
	cancel_ui_flash()
	ui.exercise_rename_open = false
	ui.exercise_rename_index = -1
	ui.focus = .None
	text_input.end_pointer_selection(&ui.input_state)
	clear_marked_text()
	ui_set_string(&ui.exercise_rename, "")
	ui.needs_redraw = true
}

confirm_exercise_rename :: proc() {
	name := strings.trim_space(ui.exercise_rename)
	if len(name) == 0 {
		set_error_status("Enter a name for the exercise")
		return
	}
	index := ui.exercise_rename_index
	if !rename_exercise(index, name) {
		set_error_status("Unable to rename the exercise")
		return
	}
	renamed := state.exercises[index].name
	close_exercise_rename()
	set_success_status(fmt.tprintf("Renamed exercise to %s", renamed))
}

open_exercise_metadata :: proc() {
	cancel_ui_flash()
	if ui.active_exercise < 0 || ui.active_exercise >= len(state.exercises) {return}
	ui.exercise_metadata_index = ui.active_exercise
	ui.exercise_metadata_open = true
	ui.focus = .None
	text_input.end_pointer_selection(&ui.input_state)
	ui.needs_redraw = true
}

close_exercise_metadata :: proc() {
	cancel_ui_flash()
	ui.exercise_metadata_open = false
	ui.exercise_metadata_index = -1
	ui.needs_redraw = true
}

open_randomize_help :: proc() {
	cancel_ui_flash()
	if ui.exercise_rename_open {close_exercise_rename()}
	if ui.exercise_metadata_open {close_exercise_metadata()}
	if ui.data_modal_open {close_data_modal()}
	if ui.notification_modal_open {close_notification_history()}
	if ui.source_details_open {close_source_details()}
	if ui.source_modal_open {close_source_modal()}
	ui.randomize_help_open = true
	ui.focus = .None
	text_input.end_pointer_selection(&ui.input_state)
	ui.needs_redraw = true
}

close_randomize_help :: proc() {
	cancel_ui_flash()
	ui.randomize_help_open = false
	ui.needs_redraw = true
}

open_pitch_help :: proc() {
	cancel_ui_flash()
	if ui.randomize_help_open {close_randomize_help()}
	ui.pitch.help_open = true
	ui.focus = .None
	text_input.end_pointer_selection(&ui.input_state)
	ui.needs_redraw = true
}

close_pitch_help :: proc() {
	cancel_ui_flash()
	ui.pitch.help_open = false
	ui.needs_redraw = true
}

save_pitch_settings :: proc() {
	if !database_pitch_settings_save(library_database, ui.pitch.settings) {
		fmt.eprintln("[vocal-training] could not persist pitch settings")
	}
	ui.needs_redraw = true
}

open_data_modal :: proc() {
	cancel_ui_flash()
	app_state_collections_destroy(&pending_library_import)
	ui.data_modal_open = true
	ui.library_import_confirm_open = false
	ui.library_import_pending = false
	ui.focus = .None
	text_input.end_pointer_selection(&ui.input_state)
	ui.needs_redraw = true
}

close_data_modal :: proc() {
	cancel_ui_flash()
	ui.data_modal_open = false
	ui.library_import_confirm_open = false
	ui.library_import_pending = false
	app_state_collections_destroy(&pending_library_import)
	ui.needs_redraw = true
}

view_exercise_source :: proc() {
	if ui.exercise_metadata_index < 0 ||
	   ui.exercise_metadata_index >= len(state.exercises) {
		return
	}
	source_index := source_index_for_exercise(
		state.sources[:],
		state.exercises[:],
		ui.exercise_metadata_index,
	)
	if source_index < 0 {
		set_error_status("The exercise source is no longer in the source register")
		return
	}
	set_ui_mode(.Create)
	ui_event_tag = source_index
	on_select_source(nil, nil, nil)
}

open_source_modal :: proc() {
	cancel_ui_flash()
	if ui.source_details_open {close_source_details()}
	ui.source_modal_refetch_index = -1
	ui.source_modal_open = true
	ui.save_source_browser_choice = false
	focus_text_input(.URL)
	ui.needs_redraw = true
	if len(strings.trim_space(ui.url_input)) > 0 && len(source_probe_results) == 0 {schedule_source_probe(1)}
}

open_refetch_source_modal :: proc(source_index: int) {
	cancel_ui_flash()
	if source_index < 0 || source_index >= len(state.sources) {return}
	if ui.source_details_open {close_source_details()}
	ui.source_modal_refetch_index = source_index
	ui.source_modal_open = true
	ui.save_source_browser_choice = false
	ui.focus = .None
	text_input.end_pointer_selection(&ui.input_state)
	ui_set_string(&ui.url_input, state.sources[source_index].url)
	source_probe_results_clear()
	schedule_source_probe(1)
	ui.needs_redraw = true
}

close_source_modal :: proc() {
	cancel_ui_flash()
	ui.source_modal_open = false
	ui.source_modal_refetch_index = -1
	ui.save_source_browser_choice = false
	ui.focus = .None
	text_input.end_pointer_selection(&ui.input_state)
	clear_marked_text()
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
	if ui.exercise_rename_open {close_exercise_rename()}
	if ui.exercise_metadata_open {close_exercise_metadata()}
	if ui.randomize_help_open {close_randomize_help()}
	if ui.pitch.help_open {close_pitch_help()}
	if ui.data_modal_open {close_data_modal()}
	if ui.notification_modal_open {close_notification_history()}
	ui.source_scrubbing = false
	ui.source_hint_menu_open = false
	if mode == .Play {
		metal_player_clear()
	} else {
		pitch_monitor_stop(&ui.pitch)
		ui.active_exercise = -1
		if state.active_source >= 0 && state.active_source < len(state.sources) {
			_ = load_source_player(state.active_source)
		}
	}
	ui.mode = mode
	ui.focus = .None
	text_input.end_pointer_selection(&ui.input_state)
	clear_marked_text()
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
	pitch_panel,
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
	center_x := margin + left_w + gap
	center_w := max(280, w - margin * 2 - left_w - right_w - gap * 2)
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
		available_w := w - margin * 2 - gap * 2
		left_w = available_w * 0.20
		center_w = available_w * 0.30
		pitch_w := available_w - left_w - center_w
		center_x = margin + left_w + gap
		right_x = center_x + center_w + gap
		exercise_search = UI_Rect{margin + 8, body_top - 72, left_w - 16, 28}
		exercise_panel = UI_Rect{margin, body_y, left_w, body_h}
		player = UI_Rect{center_x, body_y, center_w, body_h}
		pitch_panel = UI_Rect{right_x, body_y, pitch_w, body_h}
	}
	controls = UI_Rect{margin, 42, w - margin * 2, 28}
	return
}

control_action_for_slot :: proc(mode: UI_Mode, slot: int) -> int {
	if mode == .Create {return slot if slot >= 0 && slot < 8 else -1}
	switch slot {
	case 0:
		return 10
	case 1:
		return 3
	case 2:
		return 4
	case 3:
		return 8
	case 4:
		return 7
	case 5:
		return 9
	case 6:
		return 11
	}
	return -1
}

control_slot_for_action :: proc(mode: UI_Mode, action: int) -> int {
	if mode == .Create {return action if action >= 0 && action < 8 else -1}
	switch action {
	case 10:
		return 0
	case 3:
		return 1
	case 4:
		return 2
	case 7:
		return 4
	case 8:
		return 3
	case 9:
		return 5
	case 11:
		return 6
	}
	return -1
}

create_action_is_emphasized :: proc(
	kind: UI_Action_Kind,
	has_start, has_end, valid_range: bool,
) -> bool {
	if valid_range {return kind == .Save}
	if has_start && has_end {return kind == .Start || kind == .End}
	if kind == .Start {return !has_start}
	if kind == .End {return !has_end}
	return false
}

is_paste_shortcut :: proc(key, modifiers: uint) -> bool {
	return key == 9 && modifiers & NSEventModifierFlagCommand != 0
}

is_copy_shortcut :: proc(key, modifiers: uint) -> bool {
	return key == 8 && modifiers & NSEventModifierFlagCommand != 0
}

is_cut_shortcut :: proc(key, modifiers: uint) -> bool {
	return key == 7 && modifiers & NSEventModifierFlagCommand != 0
}

is_select_all_shortcut :: proc(key, modifiers: uint) -> bool {
	return key == 0 && modifiers & NSEventModifierFlagCommand != 0
}

is_delete_word_shortcut :: proc(key, modifiers: uint) -> bool {
	return key == 51 &&
	       modifiers &
	       (NSEventModifierFlagControl | NSEventModifierFlagOption) != 0
}

NSEventModifierFlagControl :: uint(1 << 18)
NSEventModifierFlagOption  :: uint(1 << 19)
NSEventModifierFlagCommand :: uint(1 << 20)
NSEventModifierFlagShift   :: uint(1 << 17)

timeline_scrub_delta :: proc(key, modifiers: uint) -> (f64, bool) {
	if key != 123 && key != 124 {return 0, false}
	if modifiers & (NSEventModifierFlagOption | NSEventModifierFlagControl) != 0 {
		return 0, false
	}
	step := 1.0
	if modifiers & NSEventModifierFlagCommand != 0 {
		step = 10
	} else if modifiers & NSEventModifierFlagShift != 0 {
		step = 0.1
	}
	if key == 123 {step = -step}
	return step, true
}

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

FOOTER_TASK_LIMIT :: 4
FOOTER_TASK_GAP :: 6.0
FOOTER_TASK_MIN_WIDTH :: 160.0
FOOTER_TASK_MAX_WIDTH :: 500.0
FOOTER_TASK_OVERFLOW_WIDTH :: 124.0

Footer_Task_Layout :: struct {
	task_rects: [FOOTER_TASK_LIMIT]UI_Rect,
	visible_count: int,
	hidden_count: int,
	overflow_rect: UI_Rect,
}

status_source_rect :: proc() -> UI_Rect {
	return UI_Rect{332, 3, 112, 24}
}

footer_task_layout :: proc(width: f64, task_count: int) -> Footer_Task_Layout {
	result: Footer_Task_Layout
	if task_count <= 0 {return result}
	footer_right := max(18, width - 18)
	x := 332.0
	available := max(0, footer_right - x)
	visible := min(task_count, FOOTER_TASK_LIMIT)
	for visible > 0 {
		hidden := task_count - visible
		overflow_width := hidden > 0 ? FOOTER_TASK_OVERFLOW_WIDTH : 0
		gap_count := visible - 1
		if hidden > 0 {gap_count += 1}
		card_width := (
			available - overflow_width - f64(gap_count)*FOOTER_TASK_GAP
		) / f64(visible)
		if card_width >= FOOTER_TASK_MIN_WIDTH || visible == 1 {
			card_width = min(FOOTER_TASK_MAX_WIDTH, max(0, card_width))
			for index in 0 ..< visible {
				result.task_rects[index] = UI_Rect{
					x + f64(index)*(card_width+FOOTER_TASK_GAP),
					0,
					card_width,
					30,
				}
			}
			result.visible_count = visible
			result.hidden_count = hidden
			if hidden > 0 {
				result.overflow_rect = UI_Rect{
					x + f64(visible)*(card_width+FOOTER_TASK_GAP),
					0,
					overflow_width,
					30,
				}
			}
			return result
		}
		visible -= 1
	}
	return result
}

footer_status_rect :: proc() -> UI_Rect {
	footer := UI_Rect{18, 0, ui.width - 36, 30}
	x := footer.x + 314
	if len(notification_history.footer_task_ids) == 0 &&
	   len(ui.status_source_video_id) > 0 {
		action := status_source_rect()
		x = action.x + action.w + 6
	}
	return UI_Rect{x, footer.y, min(500, max(0, footer.x + footer.w - x)), footer.h}
}

footer_task_action_rect :: proc(card: UI_Rect) -> UI_Rect {
	return UI_Rect{card.x + card.w - 94, card.y + 3, 88, card.h - 6}
}

footer_task_summary_rect :: proc(card: UI_Rect, has_action: bool) -> UI_Rect {
	right_inset := has_action ? 100.0 : 10.0
	return UI_Rect{card.x + 10, card.y, max(0, card.w - right_inset - 10), card.h}
}

control_rect :: proc(controls: UI_Rect, action: int) -> UI_Rect {
	slot := control_slot_for_action(ui.mode, action)
	if slot < 0 {return {}}
	count := 8
	if ui.mode == .Play {count = 7}
	gap := 6.0
	cell_w := (controls.w - gap * f64(count - 1)) / f64(count)
	return UI_Rect{controls.x + f64(slot) * (cell_w + gap), controls.y, cell_w, controls.h}
}

randomize_primary_rect :: proc(controls: UI_Rect) -> UI_Rect {
	rect := control_rect(controls, 10)
	help_width := min(rect.h, rect.w)
	rect.w -= help_width
	return rect
}

randomize_help_rect :: proc(controls: UI_Rect) -> UI_Rect {
	rect := control_rect(controls, 10)
	help_width := min(rect.h, rect.w)
	return UI_Rect{rect.x + rect.w - help_width, rect.y, help_width, rect.h}
}

pitch_help_rect :: proc(panel: UI_Rect) -> UI_Rect {
	return UI_Rect{panel.x + panel.w - 34, panel.y + panel.h - 34, 34, 34}
}

pitch_content_rect :: proc(panel: UI_Rect) -> UI_Rect {
	return UI_Rect{panel.x + 8, panel.y + 8, panel.w - 16, panel.h - 50}
}

pitch_settings_rect :: proc(panel: UI_Rect) -> UI_Rect {
	content := pitch_content_rect(panel)
	width := min(max(content.w * 0.34, 160), 190)
	return UI_Rect{content.x + content.w - width, content.y, width, content.h}
}

pitch_chart_rect :: proc(panel: UI_Rect) -> UI_Rect {
	content := pitch_content_rect(panel)
	settings := pitch_settings_rect(panel)
	return UI_Rect{content.x, content.y, max(80, settings.x - content.x - 10), content.h}
}

pitch_plot_rect :: proc(panel: UI_Rect) -> UI_Rect {
	chart := pitch_chart_rect(panel)
	return UI_Rect{chart.x + 38, chart.y + 10, max(20, chart.w - 76), max(40, chart.h - 52)}
}

pitch_plot_y :: proc(plot: UI_Rect, midi: f64, minimum, maximum: int) -> f64 {
	span := max(1, maximum - minimum)
	return plot.y + (midi - f64(minimum)) / f64(span) * plot.h
}

pitch_reference_rect :: proc(panel: UI_Rect, part: int) -> UI_Rect {
	settings := pitch_settings_rect(panel)
	y := settings.y + settings.h - 48
	widths := [3]f64{32, settings.w - 64, 32}
	x := settings.x
	for index in 0 ..< part {x += widths[index]}
	return UI_Rect{x, y, widths[part], 26}
}

pitch_range_option_rect :: proc(panel: UI_Rect, index: int) -> UI_Rect {
	settings := pitch_settings_rect(panel)
	return UI_Rect{
		settings.x,
		settings.y + settings.h - 104 - f64(index) * 25,
		settings.w,
		23,
	}
}

pitch_label_option_rect :: proc(panel: UI_Rect, index: int) -> UI_Rect {
	settings := pitch_settings_rect(panel)
	return UI_Rect{
		settings.x,
		settings.y + settings.h - 214 - f64(index) * 25,
		settings.w,
		23,
	}
}

pitch_transpose_option_rect :: proc(panel: UI_Rect, index: int) -> UI_Rect {
	settings := pitch_settings_rect(panel)
	gap := 4.0
	width := (settings.w - gap) / 2
	column := index % 2
	row := index / 2
	return UI_Rect{
		settings.x + f64(column) * (width + gap),
		settings.y + settings.h - 324 - f64(row) * 25,
		width,
		23,
	}
}

pitch_highlight_rect :: proc(panel: UI_Rect) -> UI_Rect {
	settings := pitch_settings_rect(panel)
	return UI_Rect{settings.x, settings.y + settings.h - 484, settings.w, 26}
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
	bottom_metadata_height := 64.0
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

player_timeline_seconds :: proc(point: Point, player: UI_Rect) -> f64 {
	timeline := source_timeline_rect(player)
	return timeline_seconds_at_point(point, timeline, ui.player_duration)
}

timeline_seconds_at_point :: proc(point: Point, timeline: UI_Rect, duration: f64) -> f64 {
	if timeline.w <= 0 {return 0}
	ratio := min(max((point.x - timeline.x) / timeline.w, 0), 1)
	return ratio * max(0, duration)
}

seek_player_timeline :: proc(point: Point, player: UI_Rect) {
	if state.player == nil {return}
	seek_seconds(player_timeline_seconds(point, player))
	ui.needs_redraw = true
}

seek_player_timeline_rect :: proc(point: Point, timeline: UI_Rect) {
	if state.player == nil {return}
	seek_seconds(timeline_seconds_at_point(point, timeline, ui.player_duration))
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

exercise_output_commit_rect :: proc(exercise_name: UI_Rect) -> UI_Rect {
	return UI_Rect{exercise_name.x, exercise_name.y - 36, exercise_name.w, 28}
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
	base_index: int,
	query: string,
	allocator := context.allocator,
) -> ([]int, match_sorter.Search_Error) {
	if len(query) == 0 {
		for segment in segments {
			if !match_sorter.valid_utf8(segment.text) {
				return nil, .Invalid_UTF8
			}
		}
		result := make([]int, len(segments), allocator)
		for &index, local_index in result {
			index = base_index+local_index
		}
		return result, .None
	}
	previous_temp := context.temp_allocator
	defer context.temp_allocator = previous_temp
	keys := []match_sorter.Key(Transcript_Segment){{getter=transcript_text_value}}
	ranked, search_error := match_sorter.match_indices(
		search,
		segments,
		query,
		match_sorter.Options(Transcript_Segment){keys=keys},
		context.temp_allocator,
	)
	if search_error != .None {return nil, search_error}
	result := make([]int, len(ranked), allocator)
	for local_index, result_index in ranked {
		result[result_index] = base_index+local_index
	}
	return result, .None
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
		segments, base_index, found := transcript_source_segments(
			&state.transcripts,
			state.sources[state.active_source].id,
		)
		if found {
			indices, search_error := transcript_ranked_indices(
				&transcript_search_context,
				segments,
				base_index,
				ui.transcript_search,
				context.temp_allocator,
			)
			if search_error == .None {
				append(&ui.transcript_matches, ..indices)
			} else {
				_ = notification_post_error(
					"Transcript search stopped because text contains invalid UTF-8.",
				)
			}
		}
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
		_, _, _, _, _, transcript, _, _, _, _, _ := layout_rects()
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
	_, _, source_search, source_panel, _, transcript, exercise_search, exercise_panel, exercise_name, _, _ :=
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

push_line_segment :: proc(
	vertices: ^[dynamic]Solid_Vertex,
	start, end: Point,
	thickness: f64,
	color: [4]f32,
) {
	dx, dy := end.x - start.x, end.y - start.y
	length := math.sqrt(dx * dx + dy * dy)
	if length <= 0 || ui.width <= 0 || ui.height <= 0 {return}
	nx := -dy / length * thickness / 2
	ny := dx / length * thickness / 2
	points := [4]Point{
		{start.x + nx, start.y + ny},
		{end.x + nx, end.y + ny},
		{end.x - nx, end.y - ny},
		{start.x - nx, start.y - ny},
	}
	output: [4]Solid_Vertex
	for point, index in points {
		output[index] = {
			f32(point.x / ui.width * 2 - 1),
			f32(point.y / ui.height * 2 - 1),
			color[0],
			color[1],
			color[2],
			color[3],
		}
	}
	append(
		vertices,
		output[0],
		output[1],
		output[2],
		output[0],
		output[2],
		output[3],
	)
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
	base_byte_offset := 0,
	prefix_bytes := 0,
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
	logical_bytes := max(0, len(text) - prefix_bytes)
	logical_end := base_byte_offset + logical_bytes
	caret_in_line := ui.caret_byte_offset >= base_byte_offset &&
	                 ui.caret_byte_offset <= logical_end
	local_caret := min(
		max(prefix_bytes + ui.caret_byte_offset - base_byte_offset, prefix_bytes),
		len(text),
	)
	caret_utf16 := utf16_index_for_byte_offset(text, local_caret)
	caret_advance := CTLineGetOffsetForStringIndex(run.line, caret_utf16, nil) / ui.scale
	available := max(0, rect.w - inset * 2)
	if caret_in_line {
		_ = text_input.update_horizontal_scroll(
			&ui.input_state,
			caret_advance,
			available,
		)
	}
	origin := text_origin(rect, run, .Start, .Center, inset)
	origin.x -= ui.scroll_x * ui.scale
	CGContextSaveGState(ctx)
	CGContextClipToRect(ctx, Rect{Point{rect.x * ui.scale, rect.y * ui.scale}, Size{rect.w * ui.scale, rect.h * ui.scale}})
	selection_start := min(ui.selection_anchor_byte, ui.caret_byte_offset)
	selection_end := max(ui.selection_anchor_byte, ui.caret_byte_offset)
	line_selection_start := min(max(selection_start, base_byte_offset), logical_end)
	line_selection_end := min(max(selection_end, base_byte_offset), logical_end)
	if line_selection_start < line_selection_end {
		local_start := prefix_bytes + line_selection_start - base_byte_offset
		local_end := prefix_bytes + line_selection_end - base_byte_offset
		start_advance := CTLineGetOffsetForStringIndex(
			run.line,
			utf16_index_for_byte_offset(text, local_start),
			nil,
		) / ui.scale
		end_advance := CTLineGetOffsetForStringIndex(
			run.line,
			utf16_index_for_byte_offset(text, local_end),
			nil,
		) / ui.scale
		selection_color := caret_color
		selection_color[3] = 0.32
		fill_overlay_rect(
			ctx,
			UI_Rect{
				rect.x + inset + start_advance - ui.scroll_x,
				rect.y + 4,
				max(1 / ui.scale, end_advance - start_advance),
				max(1, rect.h - 8),
			},
			selection_color,
		)
	}
	if len(text) > 0 {draw_text_run(ctx, run, origin, text_color)}
	if caret_in_line && ui.selection_anchor_byte == ui.caret_byte_offset {
		caret_x := rect.x + inset + caret_advance - ui.scroll_x
		fill_overlay_rect(
			ctx,
			UI_Rect{
				caret_x,
				rect.y + 5,
				max(1 / ui.scale, 0.5),
				max(1, rect.h - 10),
			},
			caret_color,
		)
	}
	CGContextRestoreGState(ctx)
}

text_offset_at_point :: proc(
	text: string,
	rect: UI_Rect,
	point: Point,
	inset := 8.0,
	base_byte_offset := 0,
	prefix_bytes := 0,
) -> int {
	if len(text) == 0 {return base_byte_offset}
	font_name := CFStringCreateWithCString(nil, UI_FONT_NAME, 0x08000100)
	if font_name == nil {return base_byte_offset}
	font := CTFontCreateWithName(font_name, SMALL_FONT_SIZE * ui.scale, nil)
	CFRelease(font_name)
	if font == nil {return base_byte_offset}
	defer CFRelease(font)
	run := make_text_run(font, text)
	defer delete_text_run(&run)
	if run.line == nil {return base_byte_offset}
	x := max(0, (point.x - rect.x - inset + ui.scroll_x) * ui.scale)
	utf16_index := CTLineGetStringIndexForPosition(run.line, Point{x, 0})
	if utf16_index < 0 {utf16_index = utf16_index_for_byte_offset(text, len(text))}
	byte_offset := byte_offset_for_utf16_index(text, utf16_index)
	return base_byte_offset + max(0, byte_offset - prefix_bytes)
}

utf16_index_for_byte_offset :: proc(text: string, byte_offset: int) -> int {
	return text_input.utf16_index_for_byte_offset(text, byte_offset)
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

Window_Icon_Point :: struct {
	point: Point,
	move:  bool,
}

window_icon_xmark_points :: proc() -> [8]Window_Icon_Point {
	return {
		{{6.75827, 17.2426}, true},
		{{12.0009, 12}, false},
		{{17.2435, 6.75736}, true},
		{{12.0009, 12}, false},
		{{12.0009, 12}, true},
		{{6.75827, 6.75736}, false},
		{{12.0009, 12}, true},
		{{17.2435, 17.2426}, false},
	}
}

window_icon_minus_points :: proc() -> [2]Window_Icon_Point {
	return {
		{{6, 12}, true},
		{{18, 12}, false},
	}
}

window_icon_maximize_points :: proc() -> [12]Window_Icon_Point {
	return {
		{{7, 4}, true},
		{{4, 4}, false},
		{{4, 7}, false},
		{{17, 4}, true},
		{{20, 4}, false},
		{{20, 7}, false},
		{{7, 20}, true},
		{{4, 20}, false},
		{{4, 17}, false},
		{{17, 20}, true},
		{{20, 20}, false},
		{{20, 17}, false},
	}
}

draw_window_icon_path :: proc(
	ctx: rawptr,
	rect: UI_Rect,
	color: [4]f64,
	points: []Window_Icon_Point,
) {
	CGContextSaveGState(ctx)
	defer CGContextRestoreGState(ctx)
	CGContextClipToRect(
		ctx,
		Rect{
			Point{rect.x*ui.scale, rect.y*ui.scale},
			Size{rect.w*ui.scale, rect.h*ui.scale},
		},
	)
	CGContextSetRGBStrokeColor(
		ctx,
		color[0],
		color[1],
		color[2],
		color[3],
	)
	CGContextSetLineWidth(
		ctx,
		1.5*ui.scale*min(rect.w, rect.h)/24,
	)
	CGContextSetLineCap(ctx, 1)
	CGContextSetLineJoin(ctx, 1)
	CGContextBeginPath(ctx)
	for command in points {
		x := (rect.x+command.point.x*rect.w/24)*ui.scale
		y := (rect.y+(24-command.point.y)*rect.h/24)*ui.scale
		if command.move {
			CGContextMoveToPoint(ctx, x, y)
		} else {
			CGContextAddLineToPoint(ctx, x, y)
		}
	}
	CGContextStrokePath(ctx)
}

draw_window_controls :: proc(ctx: rawptr) {
	theme := ui_theme_colors()
	colors := [3][4]f64{
		UI_COLOR_COFFEE_64,
		UI_COLOR_STONE_64,
		UI_COLOR_GUM_64,
	}
	if !ui.dark_theme {
		colors = {
			UI_COLOR_OCHRE_64,
			UI_COLOR_GUM_64,
			UI_COLOR_FOREST_64,
		}
	}
	for index in 0..<3 {
		control := window_control_rect(index)
		background := theme.panel_alt
		if contains(control, ui.mouse) {
			background = theme.row_hover
		}
		fill_overlay_rect(ctx, control, background)
	}
	xmark := window_icon_xmark_points()
	draw_window_icon_path(
		ctx,
		window_icon_rect(0),
		colors[0],
		xmark[:],
	)
	minus := window_icon_minus_points()
	draw_window_icon_path(
		ctx,
		window_icon_rect(1),
		colors[1],
		minus[:],
	)
	maximize := window_icon_maximize_points()
	draw_window_icon_path(
		ctx,
		window_icon_rect(2),
		colors[2],
		maximize[:],
	)
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
	theme := ui_theme_colors()
	modal := command_palette_rect()
	search := ui_control_rect(.Command_Palette_Search)
	content := command_palette_results_rect(modal)
	fill_overlay_rect(ctx, UI_Rect{0, 0, ui.width, ui.height}, theme.backdrop)
	fill_overlay_rect(ctx, modal, theme.modal)
	fill_overlay_rect(ctx, search, theme.field)
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
			fill_overlay_rect(ctx, row, theme.row_hover)
			fill_overlay_rect(ctx, UI_Rect{row.x, row.y, 3, row.h}, orange)
		} else if index % 2 == 0 {
			fill_overlay_rect(ctx, row, theme.row)
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

draw_exercise_rename :: proc(ctx, font: rawptr, bright, muted, dim, orange: [4]f64) {
	if !ui.exercise_rename_open ||
	   ui.exercise_rename_index < 0 ||
	   ui.exercise_rename_index >= len(state.exercises) {
		return
	}
	modal := exercise_rename_modal_rect()
	input := ui_control_rect(.Exercise_Rename)
	cancel := ui_control_rect(.Cancel_Exercise_Rename)
	confirm := ui_control_rect(.Confirm_Exercise_Rename)
	exercise := &state.exercises[ui.exercise_rename_index]
	theme := ui_theme_colors()
	fill_overlay_rect(ctx, UI_Rect{0, 0, ui.width, ui.height}, theme.backdrop)
	fill_overlay_rect(ctx, modal, theme.modal)
	header := UI_Rect{modal.x, modal.y + modal.h - 54, modal.w, 54}
	fill_overlay_rect(ctx, header, theme.panel_alt)
	draw_text_in_rect(ctx, font, "RENAME EXERCISE", UI_Rect{header.x + 20, header.y, header.w - 40, header.h}, .Start, .Center, bright)
	draw_text_in_rect(ctx, font, "ORIGINAL NAME", UI_Rect{modal.x + 24, modal.y + modal.h - 96, modal.w - 48, 22}, .Start, .Center, muted)
	draw_text_in_rect(ctx, font, exercise.name, UI_Rect{modal.x + 24, modal.y + modal.h - 130, modal.w - 48, 28}, .Start, .Center, bright)
	draw_text_in_rect(ctx, font, "NEW NAME", UI_Rect{input.x, input.y + input.h + 8, input.w, 22}, .Start, .Center, muted)
	fill_overlay_rect(ctx, input, theme.field)
	if ui.focus == .Exercise_Rename {fill_overlay_border(ctx, input, orange)}
	draw_editable_text_field(ctx, font, ui.exercise_rename, "Enter a new exercise name", input, .Exercise_Rename, bright, dim, orange, 10)
	cancel_color := theme.panel_alt
	if contains(cancel, ui.mouse) {cancel_color = theme.row_hover}
	fill_overlay_rect(ctx, cancel, cancel_color)
	draw_text_in_rect(ctx, font, "CANCEL", cancel, .Center, .Center, muted)
	confirm_control := find_ui_control_by_action(.Confirm_Exercise_Rename)
	confirm_enabled := confirm_control != nil && .Enabled in confirm_control.flags
	confirm_color := confirm_enabled ? UI_COLOR_OCHRE_64 : theme.panel_alt
	if confirm_enabled && contains(confirm, ui.mouse) {confirm_color = [4]f64{1.0, 0.42, 0.10, 1}}
	fill_overlay_rect(ctx, confirm, confirm_color)
	draw_text_in_rect(ctx, font, "RENAME", confirm, .Center, .Center, confirm_enabled ? UI_COLOR_SAND_64 : dim)
}

draw_exercise_metadata :: proc(
	ctx, font: rawptr,
	bright, muted, dim, orange, cyan, danger: [4]f64,
) {
	if !ui.exercise_metadata_open ||
	   ui.exercise_metadata_index < 0 ||
	   ui.exercise_metadata_index >= len(state.exercises) {
		return
	}
	modal := exercise_metadata_modal_rect()
	close_button := ui_control_rect(.Close_Exercise_Metadata)
	source_button := ui_control_rect(.View_Exercise_Source)
	exercise := &state.exercises[ui.exercise_metadata_index]
	source_index := source_index_for_exercise(
		state.sources[:],
		state.exercises[:],
		ui.exercise_metadata_index,
	)
	source_title := "SOURCE RECORD MISSING"
	source_id := exercise.source_id
	video_id := "UNAVAILABLE"
	source_url := "UNAVAILABLE"
	if source_index >= 0 {
		source := &state.sources[source_index]
		source_title = source.title
		source_id = source.id
		video_id = source.video_id
		source_url = source.url
	}
	theme := ui_theme_colors()
	fill_overlay_rect(ctx, UI_Rect{0, 0, ui.width, ui.height}, theme.backdrop)
	fill_overlay_rect(ctx, modal, theme.modal)
	header := UI_Rect{modal.x, modal.y + modal.h - 54, modal.w, 54}
	fill_overlay_rect(ctx, header, theme.panel_alt)
	draw_text_in_rect(ctx, font, "EXERCISE METADATA", UI_Rect{header.x + 20, header.y, header.w - 40, header.h}, .Start, .Center, bright)
	draw_text_in_rect(ctx, font, exercise.name, UI_Rect{modal.x + 24, modal.y + modal.h - 100, modal.w - 48, 28}, .Start, .Center, cyan)
	clip_available := os.exists(exercise.clip_path)
	labels := [10]string{
		"EXERCISE ID",
		"SOURCE TITLE",
		"SOURCE ID",
		"VIDEO ID",
		"RANGE IN",
		"RANGE OUT",
		"DURATION",
		"SOURCE URL",
		"CLIP FILE",
		"CLIP STATUS",
	}
	values := [10]string{
		exercise.id,
		source_title,
		source_id,
		video_id,
		format_timestamp(exercise.start_seconds),
		format_timestamp(exercise.end_seconds),
		format_timestamp(exercise.end_seconds - exercise.start_seconds),
		source_url,
		exercise.clip_path,
		clip_available ? "AVAILABLE" : "MISSING",
	}
	for label, row_index in labels {
		row := exercise_metadata_row_rect(modal, row_index)
		if row_index % 2 == 0 {fill_overlay_rect(ctx, row, theme.row)}
		draw_text_in_rect(ctx, font, label, UI_Rect{row.x + 10, row.y, 128, row.h}, .Start, .Center, muted)
		value_color := bright
		if (row_index == 1 && source_index < 0) ||
		   (row_index == 9 && !clip_available) {
			value_color = danger
		}
		value_rect := UI_Rect{row.x + 146, row.y, row.w - 156, row.h}
		if row_index >= 4 && row_index <= 6 {
			draw_timestamp_text_in_rect(ctx, font, values[row_index], value_rect, .Start, .Center, value_color)
		} else {
			draw_text_in_rect(ctx, font, values[row_index], value_rect, .Start, .Center, value_color)
		}
	}
	close_color := theme.panel_alt
	if contains(close_button, ui.mouse) {close_color = theme.row_hover}
	fill_overlay_rect(ctx, close_button, close_color)
	draw_text_in_rect(ctx, font, "CLOSE", close_button, .Center, .Center, muted)
	source_control := find_ui_control_by_action(.View_Exercise_Source)
	source_enabled := source_control != nil && .Enabled in source_control.flags
	source_color := source_enabled ? UI_COLOR_FOREST_64 : theme.panel_alt
	if source_enabled && contains(source_button, ui.mouse) {source_color = [4]f64{0.06, 0.24, 0.24, 1}}
	fill_overlay_rect(ctx, source_button, source_color)
	draw_text_in_rect(ctx, font, "VIEW SOURCE", source_button, .Center, .Center, source_enabled ? UI_COLOR_SAND_64 : dim)
}

draw_randomize_help :: proc(
	ctx, font: rawptr,
	bright, muted, dim, cyan: [4]f64,
) {
	if !ui.randomize_help_open {return}
	theme := ui_theme_colors()
	modal := randomize_help_modal_rect()
	close_button := ui_control_rect(.Close_Randomize_Help)
	fill_overlay_rect(
		ctx,
		UI_Rect{0, 0, ui.width, ui.height},
		theme.backdrop,
	)
	fill_overlay_rect(ctx, modal, theme.modal)
	header := UI_Rect{modal.x, modal.y + modal.h - 54, modal.w, 54}
	fill_overlay_rect(ctx, header, theme.panel_alt)
	draw_text_in_rect(
		ctx,
		font,
		"HOW RANDOMIZE SELECTS AN EXERCISE",
		UI_Rect{header.x + 20, header.y, header.w - 40, header.h},
		.Start,
		.Center,
		bright,
	)
	explanation := [7]string{
		"Randomize draws from the complete exercise library. Search text does not limit the draw.",
		"The active exercise is skipped when another exercise is available.",
		"A selected exercise returns to weight 2.",
		"Each skipped Randomize draw adds 1, up to weight 6.",
		"Never-selected exercises start at weight 6. Manual playback does not change the history.",
		"Weight 6 has three times the chance of weight 2, but each draw remains random.",
		"Randomize history stays on this device and is not included in library exports.",
	}
	for line, line_index in explanation {
		draw_text_in_rect(
			ctx,
			font,
			line,
			UI_Rect{
				modal.x + 24,
				modal.y + modal.h - 88 - f64(line_index) * 22,
				modal.w - 48,
				21,
			},
			.Start,
			.Center,
			line_index == 0 ? bright : muted,
			10,
		)
	}
	draw_text_in_rect(
		ctx,
		font,
		"HIGHEST CHANCE ON THE NEXT DRAW",
		UI_Rect{modal.x + 24, modal.y + modal.h - 250, 276, 24},
		.Start,
		.Center,
		cyan,
	)
	if len(state.exercises) > 1 &&
	   ui.active_exercise >= 0 &&
	   ui.active_exercise < len(state.exercises) {
		draw_text_in_rect(
			ctx,
			font,
			fmt.tprintf(
				"ACTIVE EXCLUDED: %s",
				state.exercises[ui.active_exercise].name,
			),
			UI_Rect{modal.x + 310, modal.y + modal.h - 250, modal.w - 334, 24},
			.End,
			.Center,
			muted,
			10,
		)
	}
	draw_text_in_rect(
		ctx,
		font,
		"EXERCISE",
		UI_Rect{modal.x + 34, modal.y + modal.h - 274, modal.w - 250, 22},
		.Start,
		.Center,
		muted,
	)
	draw_text_in_rect(
		ctx,
		font,
		"WEIGHT",
		UI_Rect{modal.x + modal.w - 202, modal.y + modal.h - 274, 74, 22},
		.End,
		.Center,
		muted,
	)
	draw_text_in_rect(
		ctx,
		font,
		"CHANCE",
		UI_Rect{modal.x + modal.w - 112, modal.y + modal.h - 274, 78, 22},
		.End,
		.Center,
		muted,
	)
	candidates: [RANDOM_EXERCISE_HELP_LIMIT]Random_Exercise_Candidate
	candidate_count, total_weight := random_exercise_ranked_candidates(
		state.exercises[:],
		ui.active_exercise,
		candidates[:],
	)
	if candidate_count == 0 {
		draw_text_in_rect(
			ctx,
			font,
			"NO EXERCISES ARE AVAILABLE",
			randomize_help_row_rect(modal, 0),
			.Center,
			.Center,
			dim,
		)
	}
	for candidate, row_index in candidates[:candidate_count] {
		row := randomize_help_row_rect(modal, row_index)
		if row_index % 2 == 0 {
			fill_overlay_rect(ctx, row, theme.row)
		}
		exercise := &state.exercises[candidate.exercise_index]
		draw_text_in_rect(
			ctx,
			font,
			exercise.name,
			UI_Rect{row.x + 10, row.y, row.w - 230, row.h},
			.Start,
			.Center,
			bright,
			10,
		)
		draw_text_in_rect(
			ctx,
			font,
			fmt.tprintf("%d", candidate.weight),
			UI_Rect{row.x + row.w - 192, row.y, 74, row.h},
			.End,
			.Center,
			cyan,
		)
		draw_text_in_rect(
			ctx,
			font,
			fmt.tprintf(
				"%.1f%%",
				f64(candidate.weight) / f64(total_weight) * 100,
			),
			UI_Rect{row.x + row.w - 102, row.y, 78, row.h},
			.End,
			.Center,
			cyan,
		)
	}
	close_color := theme.panel_alt
	if contains(close_button, ui.mouse) {
		close_color = theme.row_hover
	}
	fill_overlay_rect(ctx, close_button, close_color)
	draw_text_in_rect(ctx, font, "CLOSE", close_button, .Center, .Center, muted)
}

draw_pitch_monitor :: proc(
	ctx, font: rawptr,
	panel: UI_Rect,
	bright, muted, dim, accent, cool: [4]f64,
) {
	if ui.mode != .Play || panel.w <= 0 {return}
	header := UI_Rect{panel.x, panel.y + panel.h - 35, panel.w, 35}
	draw_text_in_rect(
		ctx,
		font,
		"03 / PITCH MONITOR",
		UI_Rect{header.x + 10, header.y, header.w - 50, header.h},
		.Start,
		.Center,
		muted,
	)
	draw_text_in_rect(
		ctx,
		font,
		"?",
		ui_control_rect(.Open_Pitch_Help),
		.Center,
		.Center,
		bright,
	)

	chart := pitch_chart_rect(panel)
	plot := pitch_plot_rect(panel)
	status := pitch_monitor_status_text(&ui.pitch)
	readout := "PITCH / --"
	readout_color := dim
	if ui.pitch.voiced {
		readout = fmt.tprintf(
			"%s / %.1f HZ / %+.0f CENTS",
			pitch_note_name(
				int(math.round(ui.pitch.current_midi)),
				ui.pitch.settings,
			),
			ui.pitch.current_hz,
			ui.pitch.current_cents,
		)
		readout_color = accent
	} else if ui.pitch.tracking {
		readout = "PITCH / LISTENING"
		readout_color = cool
	}
	draw_text_in_rect(
		ctx,
		font,
		readout,
		UI_Rect{chart.x + 8, chart.y + chart.h - 28, chart.w - 16, 18},
		.Start,
		.Center,
		readout_color,
	)
	draw_text_in_rect(
		ctx,
		font,
		status,
		UI_Rect{chart.x + 8, chart.y + chart.h - 47, chart.w - 16, 16},
		.Start,
		.Center,
		muted,
		8,
	)
	minimum_midi, maximum_midi := pitch_range_midi(ui.pitch.settings.range)
	natural := [12]bool{true, false, true, false, true, true, false, true, false, true, false, true}
	for midi in minimum_midi ..= maximum_midi {
		pitch_class := midi % 12
		if !natural[pitch_class] {continue}
		y := pitch_plot_y(plot, f64(midi), minimum_midi, maximum_midi)
		label := pitch_note_name(midi, ui.pitch.settings)
		color := muted
		if pitch_class == 0 {color = bright}
		draw_text_in_rect(
			ctx,
			font,
			label,
			UI_Rect{chart.x, y - 7, 34, 14},
			.End,
			.Center,
			color,
			2,
		)
		draw_text_in_rect(
			ctx,
			font,
			label,
			UI_Rect{plot.x + plot.w + 4, y - 7, 34, 14},
			.Start,
			.Center,
			color,
			2,
		)
	}

	settings := pitch_settings_rect(panel)
	top := settings.y + settings.h
	draw_text_in_rect(
		ctx,
		font,
		"PITCH STANDARD",
		UI_Rect{settings.x, top - 20, settings.w, 18},
		.Start,
		.Center,
		muted,
	)
	draw_text_in_rect(ctx, font, "-", ui_control_rect(.Pitch_Reference_Down), .Center, .Center, bright)
	draw_text_in_rect(
		ctx,
		font,
		fmt.tprintf("%d HZ", ui.pitch.settings.reference_hz),
		pitch_reference_rect(panel, 1),
		.Center,
		.Center,
		bright,
	)
	draw_text_in_rect(ctx, font, "+", ui_control_rect(.Pitch_Reference_Up), .Center, .Center, bright)

	draw_text_in_rect(
		ctx,
		font,
		"RANGE",
		UI_Rect{settings.x, top - 80, settings.w, 18},
		.Start,
		.Center,
		muted,
	)
	range_labels := [3]string{"C3 TO C8", "C2 TO C7", "C1 TO C6"}
	for label, index in range_labels {
		color := muted
		if index == int(ui.pitch.settings.range) {color = cool}
		draw_text_in_rect(
			ctx,
			font,
			label,
			ui_control_rect(.Pitch_Range, index),
			.Center,
			.Center,
			color,
		)
	}

	draw_text_in_rect(
		ctx,
		font,
		"NOTE LABELS",
		UI_Rect{settings.x, top - 190, settings.w, 18},
		.Start,
		.Center,
		muted,
	)
	label_options := [3]string{"ABCDEFG", "DO RE MI", "1 2 3 4 5 6 7"}
	for label, index in label_options {
		color := muted
		if index == int(ui.pitch.settings.labels) {color = cool}
		draw_text_in_rect(
			ctx,
			font,
			label,
			ui_control_rect(.Pitch_Labels, index),
			.Center,
			.Center,
			color,
		)
	}

	draw_text_in_rect(
		ctx,
		font,
		"TRANSPOSE",
		UI_Rect{settings.x, top - 300, settings.w, 18},
		.Start,
		.Center,
		muted,
	)
	for index in 0 ..< 12 {
		color := muted
		if index == int(ui.pitch.settings.transpose) {color = cool}
		draw_text_in_rect(
			ctx,
			font,
			pitch_transpose_label(index),
			ui_control_rect(.Pitch_Transpose, index),
			.Center,
			.Center,
			color,
			4,
		)
	}
	draw_text_in_rect(
		ctx,
		font,
		ui.pitch.settings.highlight ? "HIGHLIGHT / ON" : "HIGHLIGHT / OFF",
		ui_control_rect(.Pitch_Highlight),
		.Center,
		.Center,
		ui.pitch.settings.highlight ? cool : muted,
	)
}

draw_pitch_help :: proc(
	ctx, font: rawptr,
	bright, muted, cool: [4]f64,
) {
	if !ui.pitch.help_open {return}
	theme := ui_theme_colors()
	modal := pitch_help_modal_rect()
	fill_overlay_rect(ctx, UI_Rect{0, 0, ui.width, ui.height}, theme.backdrop)
	fill_overlay_rect(ctx, modal, theme.modal)
	header := UI_Rect{modal.x, modal.y + modal.h - 54, modal.w, 54}
	fill_overlay_rect(ctx, header, theme.panel_alt)
	draw_text_in_rect(
		ctx,
		font,
		"LIVE PITCH MONITOR",
		UI_Rect{header.x + 20, header.y, header.w - 40, header.h},
		.Start,
		.Center,
		bright,
	)
	lines := [8]string{
		"Press action 07 to start or stop live microphone analysis.",
		"The first start asks macOS for microphone access. No audio is stored.",
		"Pitch Standard changes the A4 reference frequency from 400 to 480 Hz.",
		"Range selects the frequencies shown by the chart and detector.",
		"Note Labels and Transpose change displayed names. They do not change measured pitch.",
		"Highlight marks the nearest stable note while a voiced pitch is detected.",
		"The trace keeps the most recent 12 seconds and clears on the next start.",
		"A Bluetooth default input uses the Mac microphone to preserve headphone playback quality.",
	}
	for line, index in lines {
		draw_text_in_rect(
			ctx,
			font,
			line,
			UI_Rect{
				modal.x + 24,
				modal.y + modal.h - 94 - f64(index) * 31,
				modal.w - 48,
				26,
			},
			.Start,
			.Center,
			index == 0 ? cool : muted,
		)
	}
	close_button := ui_control_rect(.Close_Pitch_Help)
	fill_overlay_rect(ctx, close_button, theme.panel_alt)
	if contains(close_button, ui.mouse) {
		fill_overlay_rect(ctx, close_button, theme.row_hover)
	}
	draw_text_in_rect(ctx, font, "01  CLOSE", close_button, .Center, .Center, muted)
}

draw_data_modal :: proc(
	ctx, font: rawptr,
	bright, muted, dim, orange, cyan: [4]f64,
) {
	if !ui.data_modal_open {return}
	theme := ui_theme_colors()
	modal := data_modal_rect()
	fill_overlay_rect(
		ctx,
		UI_Rect{0, 0, ui.width, ui.height},
		theme.backdrop,
	)
	fill_overlay_rect(ctx, modal, theme.modal)
	header := UI_Rect{modal.x, modal.y + modal.h - 54, modal.w, 54}
	fill_overlay_rect(ctx, header, theme.panel_alt)
	title := ui.library_import_confirm_open ? "REPLACE LIBRARY" : "LIBRARY DATA"
	draw_text_in_rect(
		ctx,
		font,
		title,
		UI_Rect{header.x + 20, header.y, header.w - 40, header.h},
		.Start,
		.Center,
		bright,
	)
	if ui.library_import_confirm_open {
		draw_text_in_rect(
			ctx,
			font,
			"The imported records will replace the current source and exercise library.",
			UI_Rect{modal.x + 24, modal.y + modal.h - 112, modal.w - 48, 28},
			.Start,
			.Center,
			bright,
		)
		draw_text_in_rect(
			ctx,
			font,
			fmt.tprintf(
				"%03d SOURCES   %03d EXERCISES   %04d TRANSCRIPT SEGMENTS",
				len(pending_library_import.sources),
				len(pending_library_import.exercises),
				len(pending_library_import.transcripts.segments),
			),
			UI_Rect{modal.x + 24, modal.y + modal.h - 158, modal.w - 48, 30},
			.Start,
			.Center,
			cyan,
		)
		draw_text_in_rect(
			ctx,
			font,
			"Local media files remain in place. Recovery starts after replacement.",
			UI_Rect{modal.x + 24, modal.y + modal.h - 198, modal.w - 48, 26},
			.Start,
			.Center,
			muted,
		)
		cancel := ui_control_rect(.Cancel_Library_Import)
		confirm := ui_control_rect(.Confirm_Library_Import)
		cancel_color := theme.panel_alt
		if contains(cancel, ui.mouse) {cancel_color = theme.row_hover}
		fill_overlay_rect(ctx, cancel, cancel_color)
		draw_text_in_rect(ctx, font, "CANCEL", cancel, .Center, .Center, muted)
		confirm_control := find_ui_control_by_action(.Confirm_Library_Import)
		confirm_enabled := confirm_control != nil && .Enabled in confirm_control.flags
		confirm_color := confirm_enabled ? UI_COLOR_OCHRE_64 : theme.panel_alt
		if confirm_enabled && contains(confirm, ui.mouse) {
			confirm_color = [4]f64{0.23, 0.083, 0.035, 1}
		}
		fill_overlay_rect(ctx, confirm, confirm_color)
		if confirm_enabled {fill_overlay_border(ctx, confirm, orange)}
		draw_text_in_rect(
			ctx,
			font,
			"REPLACE AND RECOVER",
			confirm,
			.Center,
			.Center,
			confirm_enabled ? UI_COLOR_SAND_64 : dim,
		)
		return
	}

	actions := [3]UI_Action_Kind{.Open_Data_Folder, .Export_Library, .Import_Library}
	labels := [3]string{"OPEN DATA FOLDER", "EXPORT LIBRARY METADATA", "IMPORT LIBRARY METADATA"}
	details := [3]string{
		"Show the active application-support directory in Finder",
		"Save portable source, transcript, quality, and exercise records",
		"Replace this library and recover media at each saved resolution",
	}
	for kind, index in actions {
		rect := ui_control_rect(kind)
		control := find_ui_control_by_action(kind)
		enabled := control != nil && .Enabled in control.flags
		color := theme.panel_alt
		if enabled && contains(rect, ui.mouse) {color = theme.row_hover}
		fill_overlay_rect(ctx, rect, color)
		draw_text_in_rect(
			ctx,
			font,
			labels[index],
			UI_Rect{rect.x + 12, rect.y + 14, rect.w - 24, 22},
			.Start,
			.Center,
			enabled ? bright : dim,
		)
		draw_text_in_rect(
			ctx,
			font,
			details[index],
			UI_Rect{rect.x + 12, rect.y - 3, rect.w - 24, 20},
			.Start,
			.Center,
			enabled ? muted : dim,
		)
	}
	close_button := ui_control_rect(.Close_Data_Modal)
	close_color := theme.panel_alt
	if contains(close_button, ui.mouse) {close_color = theme.row_hover}
	fill_overlay_rect(ctx, close_button, close_color)
	draw_text_in_rect(ctx, font, "CLOSE", close_button, .Center, .Center, muted)
}

draw_library_recovery :: proc(
	ctx, font: rawptr,
	bright, muted, dim, orange, cyan, danger: [4]f64,
) {
	if !library_recovery_state.required {return}
	theme := ui_theme_colors()
	modal := recovery_modal_rect()
	fill_overlay_rect(
		ctx,
		UI_Rect{0, 0, ui.width, ui.height},
		theme.backdrop,
	)
	fill_overlay_rect(ctx, modal, theme.modal)
	header := UI_Rect{modal.x, modal.y + modal.h - 58, modal.w, 58}
	fill_overlay_rect(ctx, header, [4]f64{0.12, 0.035, 0.028, 1})
	title := "LIBRARY RECOVERY REQUIRED"
	if !library_recovery_state.recovery_allowed {
		title = "LIBRARY VERSION NOT SUPPORTED"
	}
	draw_text_in_rect(
		ctx,
		font,
		title,
		UI_Rect{header.x + 20, header.y, header.w - 40, header.h},
		.Start,
		.Center,
		UI_COLOR_SAND_64,
	)
	failure := library_recovery_state.failure
	draw_text_in_rect(
		ctx,
		font,
		fmt.tprintf("STORAGE READ FAILED / %s", failure.stage),
		UI_Rect{modal.x + 24, modal.y + modal.h - 106, modal.w - 48, 24},
		.Start,
		.Center,
		danger,
	)
	draw_text_in_rect(
		ctx,
		font,
		failure.detail,
		UI_Rect{modal.x + 24, modal.y + modal.h - 140, modal.w - 48, 28},
		.Start,
		.Center,
		bright,
	)
	report := &library_recovery_state.report
	if !library_recovery_state.recovery_allowed {
		draw_text_in_rect(
			ctx,
			font,
			"This database cannot be changed by this application version. No files were modified.",
			UI_Rect{modal.x + 24, modal.y + modal.h - 196, modal.w - 48, 28},
			.Start,
			.Center,
			danger,
		)
		return
	}
	if !library_recovery_state.analysis_complete {
		draw_text_in_rect(
			ctx,
			font,
			"Recovery analysis did not produce a valid replacement library.",
			UI_Rect{modal.x + 24, modal.y + modal.h - 196, modal.w - 48, 28},
			.Start,
			.Center,
			danger,
		)
		return
	}
	draw_text_in_rect(
		ctx,
		font,
		fmt.tprintf(
			"%03d SOURCES   %04d SEGMENTS   %03d HINTS   %03d EXERCISES",
			report.recovered_sources,
			report.recovered_segments,
			report.recovered_hints,
			report.recovered_exercises,
		),
		UI_Rect{modal.x + 24, modal.y + modal.h - 184, modal.w - 48, 26},
		.Start,
		.Center,
		cyan,
	)
	draw_text_in_rect(
		ctx,
		font,
		fmt.tprintf(
			"%d REJECTED RECORDS   %d INCOMPLETE TABLES   %d REPLAYED DELETIONS",
			report.rejected_records,
			report.incomplete_tables,
			report.replayed_deletions,
		),
		UI_Rect{modal.x + 24, modal.y + modal.h - 214, modal.w - 48, 24},
		.Start,
		.Center,
		muted,
	)
	if library_recovery_state.backup_ready &&
	   !library_recovery_state.merge_ready {
		draw_text_in_rect(
			ctx,
			font,
			"Validated newer records could not be combined. The verified backup remains available.",
			UI_Rect{modal.x + 24, modal.y + modal.h - 244, modal.w - 48, 22},
			.Start,
			.Center,
			danger,
		)
	}

	if library_recovery_state.confirm_open {
		draw_text_in_rect(
			ctx,
			font,
			"The failed database will move to the Recovery folder. The application will activate a verified replacement.",
			UI_Rect{modal.x + 24, modal.y + modal.h - 286, modal.w - 48, 44},
			.Start,
			.Center,
			bright,
		)
		cancel := ui_control_rect(.Recovery_Cancel)
		confirm := ui_control_rect(.Recovery_Confirm)
		fill_overlay_rect(ctx, cancel, theme.panel_alt)
		fill_overlay_rect(ctx, confirm, UI_COLOR_OCHRE_64)
		fill_overlay_border(ctx, confirm, orange)
		draw_text_in_rect(ctx, font, "CANCEL", cancel, .Center, .Center, muted)
		draw_text_in_rect(ctx, font, "ACTIVATE RECOVERY", confirm, .Center, .Center, UI_COLOR_SAND_64)
		return
	}

	kinds := [3]UI_Action_Kind{
		.Recovery_Backup_Only,
		.Recovery_Backup_With_Salvage,
		.Recovery_Salvage_Only,
	}
	labels := [3]string{
		"RESTORE VERIFIED BACKUP",
		"RESTORE BACKUP AND VALID NEWER RECORDS",
		"RECOVER VALID RECORDS WITHOUT A BACKUP",
	}
	details := [3]string{
		"Discard all changes after the selected backup revision",
		"Apply validated newer rows and logged deletions to the backup",
		"Build a new library from the readable rows in the failed database",
	}
	for kind, index in kinds {
		control := find_ui_control_by_action(kind)
		if control == nil {continue}
		rect := control.rect
		color := theme.panel_alt
		if contains(rect, ui.mouse) {color = theme.row_hover}
		fill_overlay_rect(ctx, rect, color)
		draw_text_in_rect(
			ctx,
			font,
			labels[index],
			UI_Rect{rect.x + 12, rect.y + 11, rect.w - 24, 20},
			.Start,
			.Center,
			bright,
		)
		draw_text_in_rect(
			ctx,
			font,
			details[index],
			UI_Rect{rect.x + 12, rect.y - 7, rect.w - 24, 18},
			.Start,
			.Center,
			muted,
		)
	}
}

draw_backup_warning :: proc(
	ctx, font: rawptr,
	bright, muted, orange, danger: [4]f64,
) {
	if !major_change_pending.open {return}
	theme := ui_theme_colors()
	modal := backup_warning_modal_rect()
	fill_overlay_rect(
		ctx,
		UI_Rect{0, 0, ui.width, ui.height},
		theme.backdrop,
	)
	fill_overlay_rect(ctx, modal, theme.modal)
	header := UI_Rect{modal.x, modal.y + modal.h - 56, modal.w, 56}
	fill_overlay_rect(ctx, header, [4]f64{0.12, 0.035, 0.028, 1})
	draw_text_in_rect(
		ctx,
		font,
		"VERIFIED BACKUP FAILED",
		UI_Rect{header.x + 20, header.y, header.w - 40, header.h},
		.Start,
		.Center,
		UI_COLOR_SAND_64,
	)
	draw_text_in_rect(
		ctx,
		font,
		major_change_pending.detail,
		UI_Rect{modal.x + 24, modal.y + modal.h - 118, modal.w - 48, 28},
		.Start,
		.Center,
		danger,
	)
	draw_text_in_rect(
		ctx,
		font,
		"Continuing will change the library without a new verified restore point.",
		UI_Rect{modal.x + 24, modal.y + modal.h - 170, modal.w - 48, 32},
		.Start,
		.Center,
		bright,
	)
	draw_text_in_rect(
		ctx,
		font,
		"Cancel the operation unless the existing backups are sufficient.",
		UI_Rect{modal.x + 24, modal.y + modal.h - 206, modal.w - 48, 28},
		.Start,
		.Center,
		muted,
	)
	cancel := ui_control_rect(.Backup_Warning_Cancel)
	confirm := ui_control_rect(.Backup_Warning_Continue)
	fill_overlay_rect(ctx, cancel, theme.panel_alt)
	fill_overlay_rect(ctx, confirm, UI_COLOR_OCHRE_64)
	fill_overlay_border(ctx, confirm, orange)
	draw_text_in_rect(ctx, font, "CANCEL", cancel, .Center, .Center, muted)
	draw_text_in_rect(ctx, font, "CONTINUE WITHOUT BACKUP", confirm, .Center, .Center, UI_COLOR_SAND_64)
}

notification_kind_text :: proc(kind: Notification_Kind) -> string {
	switch kind {
	case .Info:        return "INFO"
	case .Activity:    return "IN PROGRESS"
	case .Success:     return "SUCCESS"
	case .Error:       return "ERROR"
	case .Interrupted: return "INTERRUPTED"
	}
	return "INFO"
}

notification_time_text :: proc(timestamp_ms: i64) -> string {
	seconds := posix.time_t(timestamp_ms / 1_000)
	local: posix.tm
	if posix.localtime_r(&seconds, &local) == nil {return "UNKNOWN TIME"}
	buffer: [32]c.char
	count := posix.strftime(
		&buffer[0],
		len(buffer),
		"%Y-%m-%d %H:%M:%S",
		&local,
	)
	if count == 0 {return "UNKNOWN TIME"}
	result, _ := strings.clone(
		string(buffer[:count]),
		context.temp_allocator,
	)
	return result
}

draw_notification_history :: proc(
	ctx, font: rawptr,
	bright, muted, dim, orange, cyan, danger, success: [4]f64,
) {
	if !ui.notification_modal_open {return}
	theme := ui_theme_colors()
	modal := notification_modal_rect()
	list := notification_list_rect(modal)
	detail := notification_detail_rect(modal)
	fill_overlay_rect(
		ctx,
		UI_Rect{0, 0, ui.width, ui.height},
		theme.backdrop,
	)
	fill_overlay_rect(ctx, modal, theme.modal)
	header := UI_Rect{modal.x, modal.y + modal.h - 54, modal.w, 54}
	fill_overlay_rect(ctx, header, theme.panel_alt)
	draw_text_in_rect(
		ctx,
		font,
		"NOTIFICATION HISTORY",
		UI_Rect{header.x + 20, header.y, header.w - 40, header.h},
		.Start,
		.Center,
		bright,
	)
	fill_overlay_rect(ctx, list, theme.field)
	fill_overlay_rect(ctx, detail, theme.panel)

	visible_count := notification_visible_row_count(modal)
	for visible_index in 0 ..< visible_count {
		notification := notification_for_visible_row(modal, visible_index)
		if notification == nil {break}
		row := notification_row_rect(modal, visible_index)
		selected := notification.id == notification_history.selected_id
		if selected {
			fill_overlay_rect(ctx, row, [4]f64{0.035, 0.12, 0.12, 1})
		} else if contains(row, ui.mouse) {
			fill_overlay_rect(ctx, row, theme.row_hover)
		}
		kind_color := muted
		if notification.kind == .Success {kind_color = success}
		if notification.kind == .Error || notification.kind == .Interrupted {
			kind_color = danger
		}
		if notification.kind == .Activity {kind_color = orange}
		draw_text_in_rect(
			ctx,
			font,
			notification.summary,
			UI_Rect{row.x + 12, row.y + 25, row.w - 24, 26},
			.Start,
			.Center,
			selected ? bright : muted,
		)
		draw_text_in_rect(
			ctx,
			font,
			fmt.tprintf(
				"%s  /  %s",
				notification_time_text(notification.updated_at_ms),
				notification_kind_text(notification.kind),
			),
			UI_Rect{row.x + 12, row.y + 5, row.w - 24, 20},
			.Start,
			.Center,
			kind_color,
			10,
		)
		fill_overlay_rect(
			ctx,
			UI_Rect{row.x + 10, row.y, row.w - 20, 1},
			theme.rule,
		)
	}

	selected := notification_selected()
	if selected == nil {
		draw_text_in_rect(
			ctx,
			font,
			"NO NOTIFICATIONS",
			detail,
			.Center,
			.Center,
			dim,
		)
	} else {
		y := detail.y + detail.h - 34
		draw_text_in_rect(
			ctx,
			font,
			selected.summary,
			UI_Rect{detail.x + 16, y, detail.w - 32, 28},
			.Start,
			.Center,
			bright,
		)
		y -= 32
		draw_text_in_rect(
			ctx,
			font,
			fmt.tprintf(
				"%s  /  CREATED %s",
				notification_kind_text(selected.kind),
				notification_time_text(selected.created_at_ms),
			),
			UI_Rect{detail.x + 16, y, detail.w - 32, 22},
			.Start,
			.Center,
			selected.kind == .Error || selected.kind == .Interrupted ? danger : cyan,
			10,
		)
		y -= 42
		draw_text_in_rect(
			ctx,
			font,
			"DETAIL",
			UI_Rect{detail.x + 16, y, detail.w - 32, 18},
			.Start,
			.Center,
			dim,
			10,
		)
		y -= 25
		draw_text_in_rect(
			ctx,
			font,
			selected.detail,
			UI_Rect{detail.x + 16, y, detail.w - 32, 24},
			.Start,
			.Center,
			muted,
		)
		y -= 42
		for field in selected.fields {
			if y < detail.y + 16 {break}
			draw_text_in_rect(
				ctx,
				font,
				field.label,
				UI_Rect{detail.x + 16, y, detail.w * 0.34, 22},
				.Start,
				.Center,
				dim,
				10,
			)
			draw_text_in_rect(
				ctx,
				font,
				field.value,
				UI_Rect{
					detail.x + 16 + detail.w * 0.34,
					y,
					detail.w * 0.66 - 32,
					22,
				},
				.Start,
				.Center,
				muted,
			)
			y -= 28
		}
	}

	close_button := ui_control_rect(.Close_Notification_History)
	close_color := theme.panel_alt
	if contains(close_button, ui.mouse) {
		close_color = theme.row_hover
	}
	fill_overlay_rect(ctx, close_button, close_color)
	draw_text_in_rect(ctx, font, "CLOSE", close_button, .Center, .Center, muted)
	action := ui_control_rect(.Activate_Notification_Action)
	if action.w > 0 {
		enabled := notification_action_available(selected)
		action_color := enabled ? UI_COLOR_FOREST_64 : theme.panel_alt
		if enabled && contains(action, ui.mouse) {
			action_color = [4]f64{0.045, 0.18, 0.18, 1}
		}
		fill_overlay_rect(ctx, action, action_color)
		draw_text_in_rect(
			ctx,
			font,
			"VIEW SOURCE",
			action,
			.Center,
			.Center,
			enabled ? UI_COLOR_SAND_64 : dim,
		)
	}
}

draw_source_details :: proc(ctx, font: rawptr, bright, muted, cyan: [4]f64) {
	if !ui.source_details_open || ui.source_details_index < 0 || ui.source_details_index >= len(state.sources) {return}
	modal := source_details_rect()
	close_button := ui_control_rect(.Close_Source_Details)
	refetch_button := ui_control_rect(.Refetch_Source_Details)
	source := &state.sources[ui.source_details_index]
	metadata := source.metadata
	metadata_ready := source.metadata_status != .Missing
	theme := ui_theme_colors()
	fill_overlay_rect(ctx, UI_Rect{0, 0, ui.width, ui.height}, theme.backdrop)
	fill_overlay_rect(ctx, modal, theme.modal)
	header := UI_Rect{modal.x, modal.y + modal.h - 54, modal.w, 54}
	fill_overlay_rect(ctx, header, theme.panel_alt)
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
		if row_index % 2 == 0 {fill_overlay_rect(ctx, row, theme.row)}
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

	close_color := theme.panel_alt
	if contains(close_button, ui.mouse) {close_color = theme.row_hover}
	fill_overlay_rect(ctx, close_button, close_color)
	draw_text_in_rect(ctx, font, "CLOSE", close_button, .Center, .Center, muted)
	refetch_control := find_ui_control_by_action(.Refetch_Source_Details)
	refetch_enabled := refetch_control != nil && .Enabled in refetch_control.flags
	refetch_color := theme.panel_alt
	refetch_text_color := muted
	if refetch_enabled {
		refetch_color = [4]f64{0.91, 0.31, 0.075, 1}
		refetch_text_color = [4]f64{0.08, 0.025, 0.01, 1}
		if contains(refetch_button, ui.mouse) {refetch_color = [4]f64{1.0, 0.42, 0.10, 1}}
	}
	fill_overlay_rect(ctx, refetch_button, refetch_color)
	if refetch_enabled {fill_overlay_border(ctx, refetch_button, [4]f64{1.0, 0.45, 0.12, 1})}
	draw_text_in_rect(ctx, font, "REFETCH / SELECT QUALITY", refetch_button, .Center, .Center, refetch_text_color)
}

build_geometry :: proc(vertices: ^[dynamic]Solid_Vertex) {
	_, _, source_search, source_panel, player, transcript, exercise_search, exercise_panel, exercise_name, pitch_panel, _ :=
		layout_rects()
	theme := ui_theme_colors()
	chassis := ui_color_32(theme.chassis)
	panel := ui_color_32(theme.panel)
	panel_alt := ui_color_32(theme.panel_alt)
	field := ui_color_32(theme.field)
	rule := ui_color_32(theme.rule)
	row_color := ui_color_32(theme.row)
	row_hover := ui_color_32(theme.row_hover)
	orange := UI_COLOR_COFFEE_32
	push_rect(vertices, UI_Rect{0, 0, ui.width, ui.height}, chassis)
	push_rect(vertices, app_header_rect(), ui_color_32(theme.header))
	theme_rect := ui_control_rect(.Theme_Toggle)
	push_rect(vertices, theme_rect, panel_alt)
	mode_rect := ui_control_rect(.Mode_Toggle)
	mode_color := panel_alt
	if contains(mode_rect, ui.mouse) {mode_color = row_hover}
	push_rect(vertices, mode_rect, mode_color)
	push_border(vertices, mode_rect, orange)
	push_rect(vertices, left_accent_edge_rect(mode_rect), orange)
	panels := [5]UI_Rect{source_panel, player, transcript, exercise_panel, pitch_panel}
	for rect in panels {
		if rect.w <= 0 || rect.h <= 0 {continue}
		push_rect(vertices, rect, panel)
		push_rect(vertices, UI_Rect{rect.x, rect.y + rect.h - 34, rect.w, 34}, panel_alt)
	}
	if ui.mode == .Play {
		chart := pitch_chart_rect(pitch_panel)
		settings := pitch_settings_rect(pitch_panel)
		plot := pitch_plot_rect(pitch_panel)
		push_rect(vertices, chart, row_color)
		push_rect(vertices, settings, field)
		minimum_midi, maximum_midi := pitch_range_midi(ui.pitch.settings.range)
		for midi in minimum_midi ..= maximum_midi {
			y := pitch_plot_y(plot, f64(midi), minimum_midi, maximum_midi)
			line_color := rule
			thickness := 1.0
			if midi % 12 == 0 {
				line_color = ui_color_32(theme.border)
				thickness = 2
			}
			push_rect(vertices, UI_Rect{plot.x, y, plot.w, thickness}, line_color)
		}
		if ui.pitch.settings.highlight && ui.pitch.voiced {
			nearest := math.round(ui.pitch.current_midi)
			if nearest >= f64(minimum_midi) && nearest <= f64(maximum_midi) {
				lane_height := plot.h / f64(maximum_midi - minimum_midi)
				y := pitch_plot_y(plot, nearest, minimum_midi, maximum_midi)
				highlight := UI_COLOR_GUM_32
				highlight[3] = 0.22
				push_rect(
					vertices,
					UI_Rect{plot.x, y - lane_height / 2, plot.w, lane_height},
					highlight,
				)
			}
		}
		if ui.pitch.trace_count > 1 {
			for point_index in 1 ..< ui.pitch.trace_count {
				previous_index :=
					(ui.pitch.trace_start + point_index - 1) % len(ui.pitch.trace)
				current_index :=
					(ui.pitch.trace_start + point_index) % len(ui.pitch.trace)
				previous := ui.pitch.trace[previous_index]
				current := ui.pitch.trace[current_index]
				if !previous.voiced || !current.voiced {continue}
				if previous.midi < f64(minimum_midi) ||
				   previous.midi > f64(maximum_midi) ||
				   current.midi < f64(minimum_midi) ||
				   current.midi > f64(maximum_midi) {
					continue
				}
				start_x := plot.x +
					f64(point_index - 1) / f64(PITCH_TRACE_POINTS - 1) * plot.w
				end_x := plot.x +
					f64(point_index) / f64(PITCH_TRACE_POINTS - 1) * plot.w
				push_line_segment(
					vertices,
					Point{
						start_x,
						pitch_plot_y(
							plot,
							previous.midi,
							minimum_midi,
							maximum_midi,
						),
					},
					Point{
						end_x,
						pitch_plot_y(
							plot,
							current.midi,
							minimum_midi,
							maximum_midi,
						),
					},
					2,
					UI_COLOR_COFFEE_32,
				)
			}
		}
		pitch_control_kinds := [2]UI_Action_Kind{
			.Pitch_Reference_Down,
			.Pitch_Reference_Up,
		}
		for kind in pitch_control_kinds {
			rect := ui_control_rect(kind)
			color := panel_alt
			if contains(rect, ui.mouse) {color = row_hover}
			push_rect(vertices, rect, color)
		}
		for index in 0 ..< 3 {
			rect := ui_control_rect(.Pitch_Range, index)
			push_rect(vertices, rect, panel_alt)
			if index == int(ui.pitch.settings.range) {
				push_border(vertices, rect, UI_COLOR_GUM_32)
				push_rect(vertices, left_accent_edge_rect(rect), UI_COLOR_GUM_32)
			} else if contains(rect, ui.mouse) {
				push_rect(vertices, rect, row_hover)
			}
			rect = ui_control_rect(.Pitch_Labels, index)
			push_rect(vertices, rect, panel_alt)
			if index == int(ui.pitch.settings.labels) {
				push_border(vertices, rect, UI_COLOR_GUM_32)
				push_rect(vertices, left_accent_edge_rect(rect), UI_COLOR_GUM_32)
			} else if contains(rect, ui.mouse) {
				push_rect(vertices, rect, row_hover)
			}
		}
		for index in 0 ..< 12 {
			rect := ui_control_rect(.Pitch_Transpose, index)
			push_rect(vertices, rect, panel_alt)
			if index == int(ui.pitch.settings.transpose) {
				push_border(vertices, rect, UI_COLOR_GUM_32)
				push_rect(vertices, left_accent_edge_rect(rect), UI_COLOR_GUM_32)
			} else if contains(rect, ui.mouse) {
				push_rect(vertices, rect, row_hover)
			}
		}
		highlight_rect := ui_control_rect(.Pitch_Highlight)
		push_rect(vertices, highlight_rect, panel_alt)
		if ui.pitch.settings.highlight {
			push_border(vertices, highlight_rect, UI_COLOR_GUM_32)
			push_rect(
				vertices,
				left_accent_edge_rect(highlight_rect),
				UI_COLOR_GUM_32,
			)
		} else if contains(highlight_rect, ui.mouse) {
			push_rect(vertices, highlight_rect, row_hover)
		}
		help_rect := ui_control_rect(.Open_Pitch_Help)
		push_rect(vertices, help_rect, panel_alt)
		if contains(help_rect, ui.mouse) {
			push_rect(vertices, help_rect, row_hover)
		}
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
	if state.player != nil {
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
		if ui.player_duration > 0 {
			duration := ui.player_duration
			seconds, has_seconds := current_seconds()
			progress := 0.0
			if has_seconds && duration > 0 {progress = min(max(seconds / duration, 0), 1)}
			push_rect(vertices, UI_Rect{track.x, track.y, track.w * progress, track.h}, UI_COLOR_COFFEE_32)
			thumb_x := track.x + track.w * progress
			push_rect(vertices, UI_Rect{thumb_x - 3, timeline.y + 2, 6, timeline.h - 4}, UI_COLOR_COFFEE_32)
		}
	}
	if ui.mode == .Create {
		add_rect := ui_control_rect(.Open_Source_Modal)
		add_control := find_ui_control_by_action(.Open_Source_Modal)
		add_enabled := add_control != nil && .Enabled in add_control.flags
		add_color := panel_alt
		if add_enabled && contains(add_rect, ui.mouse) {add_color = row_hover}
		push_rect(vertices, add_rect, add_color)
		if add_enabled {push_border(vertices, add_rect, orange)}

		commit_control := find_ui_control(ui_control_id("commit exercise output"))
		if commit_control != nil {
			commit_color := field
			if .Enabled in commit_control.flags {
				if contains(commit_control.rect, ui.mouse) {
					commit_color = row_hover
				}
			}
			push_rect(vertices, commit_control.rect, commit_color)
			if .Enabled in commit_control.flags {
				push_border(vertices, commit_control.rect, orange)
			}
		}
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
				color := row_color
				if contains(row, ui.mouse) {color = row_hover}
				push_rect(vertices, row, color)
				push_rect(vertices, UI_Rect{row.x, row.y, row.w, 1}, rule)
				if !source.media_available {
					push_rect(vertices, left_accent_edge_rect(row), UI_COLOR_COFFEE_32)
				}
				if index == state.active_source {
					push_rect(vertices, left_accent_edge_rect(row), orange)
				}
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
				color := row_color
				active := result_index == ui.transcript_active_match
				if contains(row, ui.mouse) {color = row_hover}
				push_rect(vertices, row, color)
				push_rect(vertices, UI_Rect{row.x, row.y, row.w, 1}, rule)
				if active {
					progress := clamp(ui.transcript_active_progress, 0, 1)
					push_rect(vertices, bottom_progress_edge_rect(row, progress), UI_COLOR_COFFEE_32)
				}
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
				color := row_color
				if contains(row, ui.mouse) {color = row_hover}
				push_rect(vertices, row, color)
				push_rect(vertices, UI_Rect{row.x, row.y, row.w, 1}, rule)
				if index == ui.active_exercise {
					push_rect(vertices, left_accent_edge_rect(row), orange)
				}
			}
			row.y -= 30
		}
	}

	control_kinds := [12]UI_Action_Kind{.Start, .End, .Save, .Play, .Pause, .Captions, .Preview, .Data, .Rename, .Metadata, .Randomize, .Pitch_Toggle}
	valid_range := active_exercise_range_is_valid()
	for kind in control_kinds {
		rect := ui_control_rect(kind)
		if rect.w <= 0 {continue}
		color := panel_alt
		control := find_ui_control_by_action(kind)
		enabled := control != nil && .Enabled in control.flags
		if !enabled {color = field}
		if enabled && contains(rect, ui.mouse) {color = row_hover}
		push_rect(vertices, rect, color)
		if enabled && ui.mode == .Create &&
		   create_action_is_emphasized(
				kind,
				state.has_start,
				state.has_end,
				valid_range,
		   ) {
			push_border(vertices, rect, orange)
		}
		if enabled && kind == .Pitch_Toggle && ui.pitch.tracking {
			push_border(vertices, rect, UI_COLOR_GUM_32)
		}
	}
	if ui.mode == .Play {
		help := ui_control_rect(.Open_Randomize_Help)
		if help.w > 0 {
			color := panel_alt
			if contains(help, ui.mouse) {
				color = row_hover
			}
			push_rect(vertices, help, color)
		}
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
	theme := ui_theme_colors()
	ink := theme.ink
	bright := theme.bright
	muted := theme.muted
	dim := theme.dim
	orange := ui.dark_theme ? UI_COLOR_COFFEE_64 : UI_COLOR_OCHRE_64
	success := UI_COLOR_MOSS_64
	cyan := ui.dark_theme ? UI_COLOR_GUM_64 : UI_COLOR_FOREST_64
	danger := ui.dark_theme ? UI_COLOR_COFFEE_64 : UI_COLOR_OCHRE_64

	_, _, source_search, source_panel, player, transcript, exercise_search, exercise_panel, exercise_name, pitch_panel, _ :=
		layout_rects()

	draw_text_in_rect(
		ctx,
		small_font,
		"VOCAL TRAINING",
		app_title_rect(),
		.Start,
		.Center,
		bright,
		86,
	)
	theme_rect := ui_control_rect(.Theme_Toggle)
	draw_text_in_rect(
		ctx,
		small_font,
		ui_theme_toggle_label(ui.dark_theme),
		theme_rect,
		.Center,
		.Center,
		ui.dark_theme ? UI_COLOR_SAND_64 : UI_COLOR_BASALT_64,
	)
	mode_rect := ui_control_rect(.Mode_Toggle)
	mode_text := "MODE / BUILD EXERCISES"
	if ui.mode == .Play {mode_text = "MODE / PRACTICE LIBRARY"}
	draw_text_in_rect(ctx, small_font, mode_text, mode_rect, .Center, .Center, orange)
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
		add_control := find_ui_control_by_action(.Open_Source_Modal)
		add_enabled := add_control != nil && .Enabled in add_control.flags
		draw_text_in_rect(ctx, small_font, "ADD", add_rect, .Center, .Center, add_enabled ? orange : dim)
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
		draw_pitch_monitor(
			ctx,
			small_font,
			pitch_panel,
			bright,
			muted,
			dim,
			orange,
			cyan,
		)
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
				if index == state.active_source || !source.media_available {
					row_color = orange
				}
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
	} else if state.player != nil {
		volume_down := ui_control_rect(.Volume_Down)
		playing := msg_f32(state.player, sel_registerName("rate")) > 0
		draw_text_in_rect(ctx, small_font, playing ? "PAUSE" : "PLAY", ui_control_rect(.Source_Play_Pause), .Center, .Center, playing ? orange : cyan)
		draw_text_in_rect(ctx, small_font, "STOP", ui_control_rect(.Source_Stop), .Center, .Center, muted)
		hint_control := Source_Hint_Control.Reset
		if ui.source_playback_active {
			hint_control = source_hint_control(source_hint_count(state.active_source))
		}
		if hint_control == .Reset || !ui.source_playback_active {
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
			timestamp := fmt.tprintf("%s / %s", format_timestamp(seconds), format_timestamp(ui.player_duration))
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
			ui.source_playback_active ? "MEDIA READY" : "EXERCISE READY",
			UI_Rect{timestamp_rect.x + timestamp_rect.w + 12, player.y, 100, 30},
			.Start,
			.Center,
			cyan,
		)
		if ui.source_playback_active && ui.source_hint_menu_open && hint_control == .Menu {
			values := source_hint_values(state.active_source, context.temp_allocator)
			selected := source_initial_seconds(state.active_source)
			for seconds, option_index in values {
				option := ui_control_rect(.Source_Hint, option_index)
				fill_overlay_rect(ctx, option, theme.row)
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
					active := result_index == ui.transcript_active_match
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
						active ? orange : ink,
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

		output_commit := find_ui_control(ui_control_id("commit exercise output"))
		output_top := exercise_name.y - 8
		if output_commit != nil {
			output_top = output_commit.rect.y - 8
			commit_color := dim
			if .Enabled in output_commit.flags {commit_color = orange}
			draw_text_in_rect(
				ctx,
				small_font,
				"COMMIT",
				output_commit.rect,
				.Center,
				.Center,
				commit_color,
			)
		}
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

	labels := [12]string {
		"MARK IN",
		"MARK OUT",
		"COMMIT",
		"RUN",
		"HOLD",
		"CAPTIONS",
		"AUDITION",
		"DATA",
		"RENAME",
		"METADATA",
		"RANDOMIZE",
		"PITCH",
	}
	control_kinds := [12]UI_Action_Kind{.Start, .End, .Save, .Play, .Pause, .Captions, .Preview, .Data, .Rename, .Metadata, .Randomize, .Pitch_Toggle}
	valid_range := active_exercise_range_is_valid()
	for label, i in labels {
		button_label := label
		if control_kinds[i] == .Pitch_Toggle {
			button_label = ui.pitch.tracking ? "STOP PITCH" : "START PITCH"
		}
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
		if ui.mode == .Create &&
		   create_action_is_emphasized(
				control_kinds[i],
				state.has_start,
				state.has_end,
				valid_range,
			) {
			button_color = orange
		}
		control := find_ui_control_by_action(control_kinds[i])
		if control == nil || .Enabled not_in control.flags {button_color = dim}
		draw_text_in_rect(
			ctx,
			small_font,
			button_label,
			UI_Rect{rect.x + 34, rect.y, rect.w - 40, rect.h},
			.Start,
			.Center,
			button_color,
		)
	}
	if ui.mode == .Play {
		help := ui_control_rect(.Open_Randomize_Help)
		draw_text_in_rect(
			ctx,
			small_font,
			"?",
			help,
			.Center,
			.Center,
			ink,
		)
	}

	range_text := "RANGE --:--:-- → --:--:-- / CLIP --:--:--"
	if state.has_start || state.has_end {
		start_text := state.has_start ? format_timestamp(state.range_start) : "--:--:--"
		end_text := state.has_end ? format_timestamp(state.range_end) : "--:--:--"
		duration_text := "--:--:--"
		if state.has_start && state.has_end {
			duration_text = format_timestamp(max(0, state.range_end - state.range_start))
		}
		range_text = fmt.tprintf(
			"RANGE %s → %s / CLIP %s",
			start_text,
			end_text,
			duration_text,
		)
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
	if len(notification_history.footer_task_ids) > 0 {
		task_layout := footer_task_layout(
			ui.width,
			len(notification_history.footer_task_ids),
		)
		for task_index in 0 ..< task_layout.visible_count {
			notification_id := notification_history.footer_task_ids[task_index]
			notification := notification_find(notification_id)
			if notification == nil {continue}
			card := task_layout.task_rects[task_index]
			card_control := find_ui_control_by_action_and_index(
				.Open_Notification_History,
				int(notification_id),
			)
			fill := theme.field
			accent := muted
			text_color := muted
			switch notification.kind {
			case .Activity:
				fill = [4]f64{0.12, 0.045, 0.018, 0.88}
				accent = orange
				text_color = bright
			case .Success:
				fill = [4]f64{0.025, 0.095, 0.065, 0.88}
				accent = success
				text_color = success
			case .Error, .Interrupted:
				fill = [4]f64{0.14, 0.025, 0.025, 0.88}
				accent = danger
				text_color = danger
			case .Info:
			text_color = muted
			}
			if card_control != nil && contains(card_control.rect, ui.mouse) {
				fill[0] += 0.025
				fill[1] += 0.025
				fill[2] += 0.025
			}
			fill_overlay_rect(ctx, card, fill)
			fill_overlay_rect(ctx, UI_Rect{card.x, card.y, 3, card.h}, accent)
			has_stop := import_job != nil &&
			            import_job.notification_id == notification_id
			has_source_action := notification.action_kind == .View_Source &&
			                     notification_action_available(notification)
			has_action := has_stop || has_source_action
			prefix := "SYS / "
			if notification.kind == .Activity {
				prefix = fmt.tprintf(
					"SYS / [%s] ",
					activity_spinner(ui.activity_tick),
				)
			}
			draw_timestamp_text_in_rect(
				ctx,
				small_font,
				fmt.tprintf("%s%s", prefix, notification.summary),
				footer_task_summary_rect(card, has_action),
				.Start,
				.Center,
				text_color,
				10,
			)
			if has_action {
				action := footer_task_action_rect(card)
				action_color := [4]f64{0.035, 0.12, 0.12, 1}
				action_text := "VIEW SOURCE"
				if has_stop {
					action_color = [4]f64{0.15, 0.035, 0.025, 1}
					action_text = "STOP"
				}
				if contains(action, ui.mouse) {
					action_color[0] += 0.035
					action_color[1] += 0.035
					action_color[2] += 0.035
				}
				fill_overlay_rect(ctx, action, action_color)
				draw_text_in_rect(
					ctx,
					small_font,
					action_text,
					action,
					.Center,
					.Center,
					UI_COLOR_SAND_64,
				)
			}
		}
		if task_layout.hidden_count > 0 {
			overflow := task_layout.overflow_rect
			fill_overlay_rect(ctx, overflow, [4]f64{0.10, 0.065, 0.018, 0.95})
			fill_overlay_rect(ctx, UI_Rect{overflow.x, overflow.y, 3, overflow.h}, orange)
			draw_text_in_rect(
				ctx,
				small_font,
				fmt.tprintf("%d MORE TASKS", task_layout.hidden_count),
				overflow,
				.Center,
				.Center,
				bright,
			)
		}
	} else {
		status_rect := footer_status_rect()
		status_control := find_ui_control_by_action(.Open_Notification_History)
		if status_control != nil && contains(status_rect, ui.mouse) {
			fill_overlay_rect(ctx, status_rect, theme.row_hover)
		}
		status_color := ui.status_error ? danger : (ui.status_success ? success : muted)
		draw_timestamp_text_in_rect(
			ctx,
			small_font,
			fmt.tprintf("SYS / %s", ui.status),
			status_rect,
			.Start,
			.Center,
			status_color,
			10,
		)
		if len(ui.status_source_video_id) > 0 {
			view_source := ui_control_rect(.View_Status_Source)
			button_color := [4]f64{0.035, 0.12, 0.12, 1}
			if contains(view_source, ui.mouse) {
				button_color = [4]f64{0.045, 0.18, 0.18, 1}
			}
			fill_overlay_rect(ctx, view_source, button_color)
			draw_text_in_rect(
				ctx,
				small_font,
				"VIEW SOURCE",
				view_source,
				.Center,
				.Center,
				cyan,
			)
		}
	}
	draw_source_details(ctx, small_font, bright, muted, cyan)
	draw_exercise_rename(ctx, small_font, bright, muted, dim, orange)
	draw_exercise_metadata(ctx, small_font, bright, muted, dim, orange, cyan, danger)
	draw_randomize_help(ctx, small_font, bright, muted, dim, cyan)
	draw_pitch_help(ctx, small_font, bright, muted, cyan)
	draw_data_modal(ctx, small_font, bright, muted, dim, orange, cyan)
	draw_notification_history(
		ctx,
		small_font,
		bright,
		muted,
		dim,
		orange,
		cyan,
		danger,
		success,
	)

	if ui.source_modal_open {
		modal := source_modal_rect()
		input := ui_control_rect(.URL)
		if input.w == 0 {input = source_modal_input_rect(modal)}
		cancel := ui_control_rect(.Cancel_Source_Modal)
		confirm := ui_control_rect(.Import)
		fill_overlay_rect(
			ctx,
			UI_Rect{0, 0, ui.width, ui.height},
			theme.backdrop,
		)
		fill_overlay_rect(ctx, modal, theme.modal)
		fill_overlay_rect(
			ctx,
			UI_Rect{modal.x, modal.y + modal.h - 50, modal.w, 50},
			theme.panel_alt,
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
		fill_overlay_rect(ctx, input, theme.field)
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
			caret_line := 0
			for index in 0 ..< min(ui.caret_byte_offset, len(ui.url_input)) {
				if ui.url_input[index] == '\n' {caret_line += 1}
			}
			first_line := min(max(0, caret_line - 9), max(0, len(lines) - 10))
			visible_line_start := 0
			for index in 0 ..< first_line {visible_line_start += len(lines[index]) + 1}
			for line, visible_index in lines[first_line:] {
				field := UI_Rect{input.x + 12, line_y, input.w - 24, 22}
				if ui.focus == .URL {
					draw_editable_text_field(
						ctx,
						small_font,
						fmt.tprintf("$ %s", line),
						"",
						field,
						.URL,
						ink,
						dim,
						orange,
						0,
						visible_line_start,
						2,
					)
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
				fill_overlay_rect(ctx, row, theme.row)
				if len(result.error) > 0 {
					if source_probe_browser_retry_available(result) {
						draw_text_in_rect(
							ctx,
							small_font,
							fmt.tprintf("%s / %s", result.video_id, result.error),
							UI_Rect{row.x + 10, row.y + 91, row.w - 20, 24},
							.Start,
							.Center,
							danger,
							10,
						)
						explanation := "Choose a signed-in browser. Its YouTube session is used for this request only; cookies are never stored or exported."
						if source_auth_browser_installed_count() == 0 {
							explanation = "No supported browser was found. Install or sign in to Brave, Chrome, Firefox, Safari, Edge, Chromium, or Vivaldi, then retry."
						}
						if result.auth_browser != .None {
							explanation = fmt.tprintf(
								"%s did not satisfy YouTube. Try another signed-in browser. Cookies are never stored or exported.",
								source_auth_browser_name(result.auth_browser),
							)
						}
						draw_text_in_rect(
							ctx,
							small_font,
							explanation,
							UI_Rect{row.x + 10, row.y + 64, row.w - 20, 24},
							.Start,
							.Center,
							muted,
							10,
						)
						save_control := ui_control_rect(
							.Toggle_Save_Source_Browser,
						)
						save_fill := theme.field
						save_color := muted
						if ui.save_source_browser_choice {
							save_fill = [4]f64{0.035, 0.12, 0.12, 1}
							save_color = UI_COLOR_SAND_64
						} else if contains(save_control, ui.mouse) {
							save_fill = theme.row_hover
						}
						fill_overlay_rect(ctx, save_control, save_fill)
						save_label := "[ ] SAVE CHOICE FOR LATER"
						if ui.save_source_browser_choice {
							save_label = "[X] SAVE CHOICE FOR LATER"
						}
						draw_text_in_rect(
							ctx,
							small_font,
							save_label,
							save_control,
							.Center,
							.Center,
							save_color,
						)
						for browser in SOURCE_AUTH_BROWSERS {
							control := ui_control_rect_by_value(
								.Retry_Source_With_Browser,
								result_index,
								int(browser),
							)
							if control.w == 0 {continue}
							fill := [4]f64{0.035, 0.12, 0.12, 1}
							if contains(control, ui.mouse) {
								fill = [4]f64{0.045, 0.18, 0.18, 1}
							}
							fill_overlay_rect(ctx, control, fill)
							draw_text_in_rect(
								ctx,
								small_font,
								source_auth_browser_name(browser),
								control,
								.Center,
								.Center,
								UI_COLOR_SAND_64,
							)
						}
					} else {
						draw_text_in_rect(ctx, small_font, fmt.tprintf("%s / %s", result.video_id, result.error), UI_Rect{row.x + 10, row.y, row.w - 20, row.h}, .Start, .Center, orange, 10)
					}
					continue
				}
				draw_text_in_rect(ctx, small_font, result.title, UI_Rect{row.x + 10, row.y + 30, 370, 24}, .Start, .Center, bright, 10)
				metadata_text := fmt.tprintf(
					"%s / %s",
					result.video_id,
					format_timestamp(result.duration),
				)
				if result.auth_browser != .None {
					metadata_text = fmt.tprintf(
						"%s SESSION / %s",
						source_auth_browser_name(result.auth_browser),
						metadata_text,
					)
				}
				draw_text_in_rect(ctx, small_font, metadata_text, UI_Rect{row.x + 10, row.y + 6, 370, 22}, .Start, .Center, muted, 10)
				for height, option_index in result.heights {
					quality := ui_control_rect_by_value(.Source_Quality, result_index, height)
					if quality.w == 0 {break}
					selected := height == result.selected_height
					fill_overlay_rect(ctx, quality, selected ? UI_COLOR_FOREST_64 : theme.field)
					if selected {fill_overlay_border(ctx, quality, cyan)}
					draw_text_in_rect(ctx, small_font, fmt.tprintf("%dp", height), quality, .Center, .Center, selected ? UI_COLOR_SAND_64 : muted)
				}
			}
		}
		cancel_color := theme.panel_alt
		if contains(cancel, ui.mouse) {cancel_color = theme.row_hover}
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
	draw_library_recovery(
		ctx,
		small_font,
		bright,
		muted,
		dim,
		orange,
		cyan,
		danger,
	)
	draw_backup_warning(ctx, small_font, bright, muted, orange, danger)
	draw_window_controls(ctx)
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

header_window_gesture_allowed :: proc(
	header: UI_Rect,
	controls: []UI_Control,
	point: Point,
) -> bool {
	return contains(header, point) &&
	       find_ui_control_at_point(controls, point, .Primary_Press) == nil
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

ui_action_enabled_for_current_job :: proc(kind: UI_Action_Kind) -> bool {
	if kind == .Command_Palette_Disabled {return false}
	if kind == .Activate_Notification_Action {
		return notification_action_available(notification_selected())
	}
	if kind == .Export_Library || kind == .Import_Library {
		return !library_transfer_busy()
	}
	if kind == .Confirm_Library_Import {
		return !library_transfer_busy() && ui.library_import_pending
	}
	if kind == .Start || kind == .End {
		return state.player != nil &&
		       state.active_source >= 0 &&
		       state.active_source < len(state.sources)
	}
	if kind == .Save {
		return import_job == nil &&
		       export_job == nil &&
		       active_exercise_range_is_valid()
	}
	if kind == .Randomize {
		return ui.mode == .Play && len(state.exercises) > 0
	}
	if kind == .Open_Randomize_Help {
		return ui.mode == .Play
	}
	if kind == .Pitch_Toggle {
		if ui.mode != .Play || ui.pitch.permission_pending {return false}
		if ui.pitch.tracking {return true}
		return ui.pitch.permission != .Denied &&
		       ui.pitch.permission != .Restricted
	}
	if kind == .Pitch_Reference_Down {
		return ui.mode == .Play && ui.pitch.settings.reference_hz > 400
	}
	if kind == .Pitch_Reference_Up {
		return ui.mode == .Play && ui.pitch.settings.reference_hz < 480
	}
	if kind == .Pitch_Range ||
	   kind == .Pitch_Labels ||
	   kind == .Pitch_Transpose ||
	   kind == .Pitch_Highlight ||
	   kind == .Open_Pitch_Help {
		return ui.mode == .Play
	}
	if kind == .Close_Pitch_Help {
		return ui.pitch.help_open
	}
	if kind == .Rename || kind == .Metadata {
		return import_job == nil &&
		       ui.active_exercise >= 0 &&
		       ui.active_exercise < len(state.exercises)
	}
	if kind == .View_Exercise_Source {
		if ui.exercise_metadata_index < 0 ||
		   ui.exercise_metadata_index >= len(state.exercises) {
			return false
		}
		return source_index_for_exercise(
			state.sources[:],
			state.exercises[:],
			ui.exercise_metadata_index,
		) >= 0
	}
	if kind == .Confirm_Exercise_Rename {
		return ui.exercise_rename_index >= 0 &&
		       ui.exercise_rename_index < len(state.exercises) &&
		       len(strings.trim_space(ui.exercise_rename)) > 0
	}
	if import_job == nil {return true}
	#partial switch kind {
	case .Open_Source_Modal,
	     .Refetch_Source_Details,
	     .Import,
	     .Source_Quality,
	     .Retry_Source_With_Browser,
	     .Toggle_Save_Source_Browser,
	     .Source_Hint_Menu,
	     .Source_Hint,
	     .Save,
	     .Captions,
	     .Preview:
		return false
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
	enabled := ui_action_enabled_for_current_job(kind)
	if enabled {
		flags += {.Enabled, .Flash, .Primary_Press}
	}
	if kind == .Pitch_Chart {
		flags = {.Accessibility, .Enabled}
	}
	if kind == .Open_Source_Details {
		flags -= {.Primary_Press}
		flags += {.Secondary_Press}
	}
	#partial switch kind {
	case .Command_Palette_Search, .URL, .Source_Search, .Transcript_Search, .Exercise_Search, .Exercise_Name, .Exercise_Rename:
		flags += {.Editable, .Drag}
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
	if kind == .Toggle_Save_Source_Browser ||
	   kind == .Pitch_Highlight ||
	   kind == .Pitch_Range ||
	   kind == .Pitch_Labels ||
	   kind == .Pitch_Transpose {
		checked := uint(0)
		#partial switch kind {
		case .Toggle_Save_Source_Browser:
			if ui.save_source_browser_choice {checked = 1}
		case .Pitch_Highlight:
			if ui.pitch.settings.highlight {checked = 1}
		case .Pitch_Range:
			if value == int(ui.pitch.settings.range) {checked = 1}
		case .Pitch_Labels:
			if value == int(ui.pitch.settings.labels) {checked = 1}
		case .Pitch_Transpose:
			if value == int(ui.pitch.settings.transpose) {checked = 1}
		case:
		}
		value := msg_id_uint(
			objc_getClass("NSNumber"),
			sel_registerName("numberWithUnsignedInt:"),
			checked,
		)
		msg_void_id(element, sel_registerName("setAccessibilityValue:"), value)
	}
	msg_void_bool(element, sel_registerName("setAccessibilityEnabled:"), enabled)
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
	control_flags := flags
	if ui_action_enabled_for_current_job(kind) {control_flags += {.Enabled}}
	append(&ui_build.controls, UI_Control{
		id = ui_control_id(functional_name),
		functional_name = functional_name,
		rect = rect,
		flags = control_flags,
		action = UI_Action{kind = kind},
	})
}

add_window_controls :: proc(array, element_class: Id) {
	actions := [3]UI_Action_Kind{
		.Window_Close,
		.Window_Minimize,
		.Window_Zoom,
	}
	names := [3]string{
		"window close",
		"window minimize",
		"window zoom",
	}
	labels := [3]string{
		"Close window",
		"Minimize window",
		"Zoom window",
	}
	flash_labels := [3]string{
		"close window",
		"minimize window",
		"zoom window",
	}
	for action, index in actions {
		add_ax_element(
			array,
			element_class,
			labels[index],
			"AXButton",
			window_control_rect(index),
			action,
			flash_label = flash_labels[index],
			functional_name = names[index],
		)
	}
}

build_ui_controls :: proc(rebuild_accessibility: bool, allocator := context.allocator) {
	previous_temp := context.temp_allocator
	defer context.temp_allocator = previous_temp
	context.temp_allocator = allocator
	ui_build.controls = make([dynamic]UI_Control, 0, 64, allocator)
	ui_build.diagnostic_surface = ui_diagnostic_surface(allocator)
	ui_build.frame = int(ui.frame_tick)
	array: Id
	if rebuild_accessibility {
		clear(&ax_actions)
		if ui.ax_children != nil {msg_void(ui.ax_children, sel_registerName("release"))}
		temporary := msg_id(objc_getClass("NSMutableArray"), sel_registerName("array"))
		ui.ax_children = msg_id(temporary, sel_registerName("retain"))
		array = temporary
	}
	element_class := objc_getClass("VocalAccessibilityElement")
	import_field, import_button, source_search, source_panel, player, transcript, exercise_search, exercise_panel, exercise_name, pitch_panel, controls :=
		layout_rects()
	add_window_controls(array, element_class)
	if library_recovery_state.required {
		modal := recovery_modal_rect()
		if library_recovery_state.analysis_complete {
			if library_recovery_state.confirm_open {
				add_ax_element(
					array,
					element_class,
					"Cancel library recovery",
					"AXButton",
					recovery_cancel_rect(modal),
					.Recovery_Cancel,
					flash_label = "cancel recovery",
				)
				add_ax_element(
					array,
					element_class,
					"Activate recovered library",
					"AXButton",
					recovery_confirm_rect(modal),
					.Recovery_Confirm,
					flash_label = "activate recovery",
				)
			} else if library_recovery_state.backup_ready {
				add_ax_element(
					array,
					element_class,
					"Restore verified backup",
					"AXButton",
					recovery_action_rect(modal, 0),
					.Recovery_Backup_Only,
					flash_label = "restore backup",
				)
				if library_recovery_state.merge_ready {
					add_ax_element(
						array,
						element_class,
						"Restore backup and valid newer records",
						"AXButton",
						recovery_action_rect(modal, 1),
						.Recovery_Backup_With_Salvage,
						flash_label = "restore newer records",
					)
				}
			} else if library_recovery_state.salvage_ready {
				add_ax_element(
					array,
					element_class,
					"Recover valid records without a backup",
					"AXButton",
					recovery_action_rect(modal, 0),
					.Recovery_Salvage_Only,
					flash_label = "recover valid records",
				)
			}
		}
		validate_ui_controls()
		return
	}
	if major_change_pending.open {
		modal := backup_warning_modal_rect()
		add_ax_element(
			array,
			element_class,
			"Cancel operation without a verified backup",
			"AXButton",
			recovery_cancel_rect(modal),
			.Backup_Warning_Cancel,
			flash_label = "cancel operation",
		)
		add_ax_element(
			array,
			element_class,
			"Continue operation without a verified backup",
			"AXButton",
			recovery_confirm_rect(modal),
			.Backup_Warning_Continue,
			flash_label = "continue without backup",
		)
		validate_ui_controls()
		return
	}
	if ui.randomize_help_open {
		modal := randomize_help_modal_rect()
		add_ax_element(
			array,
			element_class,
			"Close Randomize help",
			"AXButton",
			randomize_help_close_rect(modal),
			.Close_Randomize_Help,
			flash_label = "close randomize help",
		)
		validate_ui_controls()
		return
	}
	if ui.pitch.help_open {
		modal := pitch_help_modal_rect()
		add_ax_element(
			array,
			element_class,
			"01 Close pitch monitor help",
			"AXButton",
			pitch_help_close_rect(modal),
			.Close_Pitch_Help,
			flash_label = "close pitch monitor help",
		)
		validate_ui_controls()
		return
	}
	if ui.notification_modal_open {
		modal := notification_modal_rect()
		add_ax_element(
			array,
			element_class,
			"Close notification history",
			"AXButton",
			notification_history_close_rect(modal),
			.Close_Notification_History,
			flash_label = "close notifications",
		)
		visible_count := notification_visible_row_count(modal)
		for visible_index in 0 ..< visible_count {
			notification := notification_for_visible_row(modal, visible_index)
			if notification == nil {break}
			add_ax_element(
				array,
				element_class,
				fmt.tprintf(
					"%s, %s, %s",
					notification_kind_text(notification.kind),
					notification_time_text(notification.updated_at_ms),
					notification.summary,
				),
				"AXButton",
				notification_row_rect(modal, visible_index),
				.Select_Notification,
				int(notification.id),
				flash_label = "notification",
				functional_name = fmt.tprintf(
					"notification history entry %d",
					notification.id,
				),
			)
		}
		selected := notification_selected()
		if selected != nil && selected.action_kind != .None {
			add_ax_element(
				array,
				element_class,
				"View notification source",
				"AXButton",
				notification_history_action_rect(modal),
				.Activate_Notification_Action,
				flash_label = "view notification source",
			)
		}
		validate_ui_controls()
		return
	}
	if len(notification_history.footer_task_ids) > 0 {
		task_layout := footer_task_layout(
			ui.width,
			len(notification_history.footer_task_ids),
		)
		for task_index in 0 ..< task_layout.visible_count {
			notification_id := notification_history.footer_task_ids[task_index]
			notification := notification_find(notification_id)
			if notification == nil {continue}
			card := task_layout.task_rects[task_index]
			has_stop := import_job != nil &&
			            import_job.notification_id == notification_id
			source_index := -1
			if notification.action_kind == .View_Source {
				source_index = source_index_for_video_id(
					state.sources[:],
					notification.action_target,
				)
			}
			has_action := has_stop || source_index >= 0
			card_control_rect := card
			if has_action {card_control_rect.w -= 100}
			add_ax_element(
				array,
				element_class,
				fmt.tprintf("%s, %s", notification_kind_text(notification.kind), notification.summary),
				"AXButton",
				card_control_rect,
				.Open_Notification_History,
				int(notification_id),
				flash_label = "notification",
				functional_name = fmt.tprintf("footer notification task %d", notification_id),
			)
			if has_stop {
				add_ax_element(
					array,
					element_class,
					"Stop download",
					"AXButton",
					footer_task_action_rect(card),
					.Stop_Download,
					flash_label = "stop download",
					functional_name = fmt.tprintf(
						"stop notification task %d",
						notification_id,
					),
				)
			} else if source_index >= 0 {
				source := &state.sources[source_index]
				add_ax_element(
					array,
					element_class,
					fmt.tprintf("View refetched source, %s", source.title),
					"AXButton",
					footer_task_action_rect(card),
					.View_Status_Source,
					source_index,
					flash_label = "view source",
					functional_name = fmt.tprintf(
						"view source from notification %d",
						notification_id,
					),
				)
			}
		}
		if task_layout.hidden_count > 0 {
			hidden_notification_id :=
				notification_history.footer_task_ids[
					len(notification_history.footer_task_ids)-1
				]
			add_ax_element(
				array,
				element_class,
				fmt.tprintf("%d more tasks", task_layout.hidden_count),
				"AXButton",
				task_layout.overflow_rect,
				.Open_Notification_History,
				int(hidden_notification_id),
				flash_label = "more tasks",
				functional_name = "footer notification task overflow",
			)
		}
	} else {
		add_ax_element(
			array,
			element_class,
			"Open notification history",
			"AXButton",
			footer_status_rect(),
			.Open_Notification_History,
			flash_label = "notifications",
		)
		if import_job != nil {
			add_ax_element(
				array,
				element_class,
				"Stop download",
				"AXButton",
				import_cancel_rect(),
				.Stop_Download,
				flash_label = "stop download",
			)
		}
		if len(ui.status_source_video_id) > 0 {
			for source, index in state.sources {
				if source.video_id != ui.status_source_video_id {continue}
				add_ax_element(
					array,
					element_class,
					fmt.tprintf("View refetched source, %s", source.title),
					"AXButton",
					status_source_rect(),
					.View_Status_Source,
					index,
					flash_label = "view source",
					functional_name = fmt.tprintf("view refetched source %s", source.id),
				)
				break
			}
		}
	}
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
	if ui.data_modal_open {
		modal := data_modal_rect()
		if ui.library_import_confirm_open {
			add_ax_element(
				array,
				element_class,
				"Cancel library import",
				"AXButton",
				library_import_cancel_rect(modal),
				.Cancel_Library_Import,
				flash_label = "cancel import",
			)
			add_ax_element(
				array,
				element_class,
				"Replace library and recover media",
				"AXButton",
				library_import_confirm_rect(modal),
				.Confirm_Library_Import,
				flash_label = "replace library",
			)
		} else {
			add_ax_element(
				array,
				element_class,
				"Open data folder",
				"AXButton",
				data_modal_action_rect(modal, 0),
				.Open_Data_Folder,
				flash_label = "open data folder",
			)
			add_ax_element(
				array,
				element_class,
				"Export library metadata",
				"AXButton",
				data_modal_action_rect(modal, 1),
				.Export_Library,
				flash_label = "export library",
			)
			add_ax_element(
				array,
				element_class,
				"Import library metadata",
				"AXButton",
				data_modal_action_rect(modal, 2),
				.Import_Library,
				flash_label = "import library",
			)
			add_ax_element(
				array,
				element_class,
				"Close library data",
				"AXButton",
				data_modal_close_rect(modal),
				.Close_Data_Modal,
				flash_label = "close data",
			)
		}
		validate_ui_controls()
		return
	}
	if ui.exercise_metadata_open {
		modal := exercise_metadata_modal_rect()
		add_ax_element(
			array,
			element_class,
			"Close exercise metadata",
			"AXButton",
			exercise_metadata_close_rect(modal),
			.Close_Exercise_Metadata,
			flash_label = "close metadata",
		)
		add_ax_element(
			array,
			element_class,
			"View exercise source",
			"AXButton",
			exercise_metadata_source_rect(modal),
			.View_Exercise_Source,
			flash_label = "view exercise source",
		)
		validate_ui_controls()
		return
	}
	if ui.exercise_rename_open {
		modal := exercise_rename_modal_rect()
		add_ax_element(
			array,
			element_class,
			"New exercise name",
			"AXTextField",
			exercise_rename_input_rect(modal),
			.Exercise_Rename,
			flash_label = "new exercise name",
		)
		add_ax_element(
			array,
			element_class,
			"Cancel exercise rename",
			"AXButton",
			exercise_rename_cancel_rect(modal),
			.Cancel_Exercise_Rename,
			flash_label = "cancel rename",
		)
		add_ax_element(
			array,
			element_class,
			"Rename exercise",
			"AXButton",
			exercise_rename_confirm_rect(modal),
			.Confirm_Exercise_Rename,
			flash_label = "confirm rename",
		)
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
			if source_probe_browser_retry_available(result) {
				save_label := "Save browser choice for later, off"
				if ui.save_source_browser_choice {
					save_label = "Save browser choice for later, on"
				}
				add_ax_element(
					array,
					element_class,
					save_label,
					"AXCheckBox",
					source_probe_save_browser_rect(row),
					.Toggle_Save_Source_Browser,
					flash_label = "save browser choice",
				)
				installed_count := source_auth_browser_installed_count()
				installed_index := 0
				for browser in SOURCE_AUTH_BROWSERS {
					if !source_auth_browser_installed(browser) {continue}
					add_ax_element(
						array,
						element_class,
						fmt.tprintf(
							"Retry using signed-in %s session. Browser cookies are not stored or exported.",
							source_auth_browser_name(browser),
						),
						"AXButton",
						source_probe_browser_rect(
							row,
							installed_index,
							installed_count,
						),
						.Retry_Source_With_Browser,
						result_index,
						value = int(browser),
						flash_label = "use browser session",
						functional_name = fmt.tprintf(
							"retry source %s with %s session",
							result.video_id,
							source_auth_browser_argument(browser),
						),
					)
					installed_index += 1
				}
				continue
			}
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
	theme_label := "Switch to dark theme"
	if ui.dark_theme {theme_label = "Switch to light theme"}
	add_ax_element(
		array,
		element_class,
		theme_label,
		"AXButton",
		theme_button_rect(),
		.Theme_Toggle,
		flash_label = "toggle theme",
		functional_name = "theme toggle",
	)
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
		add_ax_element(
			array,
			element_class,
			"Decrease pitch reference frequency",
			"AXButton",
			pitch_reference_rect(pitch_panel, 0),
			.Pitch_Reference_Down,
			flash_label = "lower pitch reference",
		)
		add_ax_element(
			array,
			element_class,
			"Increase pitch reference frequency",
			"AXButton",
			pitch_reference_rect(pitch_panel, 2),
			.Pitch_Reference_Up,
			flash_label = "raise pitch reference",
		)
		range_labels := [3]string{"C3 to C8", "C2 to C7", "C1 to C6"}
		for label, index in range_labels {
			add_ax_element(
				array,
				element_class,
				label,
				"AXRadioButton",
				pitch_range_option_rect(pitch_panel, index),
				.Pitch_Range,
				index,
				value = index,
				flash_label = "pitch range",
				functional_name = fmt.tprintf("pitch range %d", index),
			)
		}
		label_labels := [3]string{"Note labels ABCDEFG", "Note labels Do Re Mi", "Note labels 1 to 7"}
		for label, index in label_labels {
			add_ax_element(
				array,
				element_class,
				label,
				"AXRadioButton",
				pitch_label_option_rect(pitch_panel, index),
				.Pitch_Labels,
				index,
				value = index,
				flash_label = "pitch note labels",
				functional_name = fmt.tprintf("pitch note labels %d", index),
			)
		}
		for index in 0 ..< 12 {
			add_ax_element(
				array,
				element_class,
				fmt.tprintf("Transpose %s", pitch_transpose_label(index)),
				"AXRadioButton",
				pitch_transpose_option_rect(pitch_panel, index),
				.Pitch_Transpose,
				index,
				value = index,
				flash_label = "pitch transposition",
				functional_name = fmt.tprintf("pitch transposition %d", index),
			)
		}
		highlight_label := "Pitch highlight off"
		if ui.pitch.settings.highlight {highlight_label = "Pitch highlight on"}
		add_ax_element(
			array,
			element_class,
			highlight_label,
			"AXCheckBox",
			pitch_highlight_rect(pitch_panel),
			.Pitch_Highlight,
			flash_label = "toggle pitch highlight",
		)
		chart_label := pitch_monitor_status_text(&ui.pitch)
		if ui.pitch.voiced {
			chart_label = fmt.tprintf(
				"%s, %s, %.1f hertz, %+.0f cents",
				chart_label,
				pitch_note_name(int(math.round(ui.pitch.current_midi)), ui.pitch.settings),
				ui.pitch.current_hz,
				ui.pitch.current_cents,
			)
		}
		add_ax_element(
			array,
			element_class,
			chart_label,
			"AXGroup",
			pitch_chart_rect(pitch_panel),
			.Pitch_Chart,
			flash_label = "pitch chart",
			functional_name = "pitch chart",
		)
		add_ax_element(
			array,
			element_class,
			"Explain pitch monitor",
			"AXButton",
			pitch_help_rect(pitch_panel),
			.Open_Pitch_Help,
			flash_label = "pitch monitor help",
		)
	}
	if state.player != nil {
		playing := msg_f32(state.player, sel_registerName("rate")) > 0
		media_name := ui.source_playback_active ? "source" : "exercise"
		add_pointer_control(fmt.tprintf("toggle %s playback from player surface", media_name), player, .Player_Surface, {.Primary_Press})
		add_pointer_control(fmt.tprintf("scrub %s timeline", media_name), source_timeline_rect(player), .Source_Timeline, {.Primary_Press, .Drag})
		add_ax_element(array, element_class, fmt.tprintf("%s %s", playing ? "Pause" : "Play", media_name), "AXButton", source_play_pause_rect(player), .Source_Play_Pause, flash_label = fmt.tprintf("play pause %s", media_name))
		add_ax_element(array, element_class, fmt.tprintf("Stop %s and return to zero", media_name), "AXButton", source_stop_rect(player), .Source_Stop, flash_label = fmt.tprintf("stop %s", media_name))
		hint_control := Source_Hint_Control.Reset
		if ui.source_playback_active {
			hint_control = source_hint_control(source_hint_count(state.active_source))
		}
		if hint_control == .Menu {
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
		reset_label := "Return to the imported source timestamp"
		reset_flash_label := "reset source timestamp"
		if !ui.source_playback_active {
			reset_label = "Return to the start of the exercise"
			reset_flash_label = "reset exercise"
		}
		if hint_control == .Reset || !ui.source_playback_active {
			add_ax_element(array, element_class, reset_label, "AXButton", source_reset_rect(player), .Source_Reset, flash_label = reset_flash_label)
		}
		add_ax_element(array, element_class, fmt.tprintf("Decrease %s playback speed", media_name), "AXButton", source_speed_down_rect(player), .Speed_Down, flash_label = "slower")
		add_ax_element(array, element_class, fmt.tprintf("Increase %s playback speed", media_name), "AXButton", source_speed_up_rect(player), .Speed_Up, flash_label = "faster")
		percent := volume_percent(ui.player_volume)
		add_ax_element(
			array,
			element_class,
			fmt.tprintf("Decrease %s volume, %d percent", media_name, percent),
			"AXButton",
			source_volume_down_rect(player),
			.Volume_Down,
			flash_label = "quieter",
		)
		add_ax_element(
			array,
			element_class,
			fmt.tprintf("Increase %s volume, %d percent", media_name, percent),
			"AXButton",
			source_volume_up_rect(player),
			.Volume_Up,
			flash_label = "louder",
		)
	}
	kinds := [12]UI_Action_Kind{.Start, .End, .Save, .Play, .Pause, .Captions, .Preview, .Data, .Rename, .Metadata, .Randomize, .Pitch_Toggle}
	labels := [12]string {
		"Set start",
		"Set end",
		"Save exercise",
		"Play",
		"Pause",
		"Load captions",
		"Preview range",
		"Open library data",
		"Rename exercise",
		"Show exercise metadata",
		"Play a random exercise",
		"Toggle pitch tracking",
	}
	flash_labels := [12]string{"mark in", "mark out", "commit", "run", "hold", "captions", "audition", "data", "rename exercise", "exercise metadata", "randomize exercise", "toggle pitch tracking"}
	slot_count := 8
	if ui.mode == .Play {slot_count = 7}
	for slot in 0 ..< slot_count {
		action_index := control_action_for_slot(ui.mode, slot)
		if action_index < 0 {continue}
		kind := kinds[action_index]
		rect := control_rect(controls, action_index)
		if kind == .Randomize {rect = randomize_primary_rect(controls)}
		if rect.w > 0 {
			add_ax_element(
				array,
				element_class,
				labels[action_index],
				"AXButton",
				rect,
				kind,
				flash_label = flash_labels[action_index],
			)
		}
	}
	if ui.mode == .Play {
		add_ax_element(
			array,
			element_class,
			"Explain Randomize selection",
			"AXButton",
			randomize_help_rect(controls),
			.Open_Randomize_Help,
			flash_label = "randomize help",
		)
	}
	if ui.mode == .Create {
		add_ax_element(
			array,
			element_class,
			"Save exercise",
			"AXButton",
			exercise_output_commit_rect(exercise_name),
			.Save,
			flash_label = "commit",
			functional_name = "commit exercise output",
		)
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
	case .Window_Close:
		msg_void(state.window, sel_registerName("close"))
	case .Window_Minimize:
		msg_void_i(
			state.window,
			sel_registerName("setStyleMask:"),
			int(WINDOW_MINIMIZE_STYLE),
		)
		msg_void_id(state.window, sel_registerName("miniaturize:"), nil)
		msg_void_i(
			state.window,
			sel_registerName("setStyleMask:"),
			int(WINDOW_STYLE),
		)
	case .Window_Zoom:
		toggle_window_zoom()
	case .Theme_Toggle:
		ui.dark_theme = !ui.dark_theme
		if !database_interface_theme_save(library_database, ui.dark_theme) {
			fmt.eprintln("[vocal-training] could not persist the interface theme")
		}
		ui.needs_redraw = true
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
	case .Retry_Source_With_Browser:
		return source_probe_retry_with_browser(
			action.index,
			Source_Auth_Browser(action.value),
		)
	case .Toggle_Save_Source_Browser:
		ui.save_source_browser_choice = !ui.save_source_browser_choice
		ui.needs_redraw = true
		return true
	case .Stop_Download:
		if import_job != nil {
			if library_recovery != nil {library_recovery.cancelled = true}
			import_job_cancel(import_job)
			set_text(state.status, "Stopping download...")
		}
	case .View_Status_Source:
		set_ui_mode(.Create)
		ui_event_tag = action.index
		on_select_source(nil, nil, nil)
	case .Open_Notification_History:
		open_notification_history(i64(action.index))
	case .Close_Notification_History:
		close_notification_history()
	case .Select_Notification:
		return select_notification(i64(action.index))
	case .Activate_Notification_Action:
		return activate_notification_action()
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
	case .Randomize:
		return randomize_exercise()
	case .Open_Randomize_Help:
		open_randomize_help()
	case .Close_Randomize_Help:
		close_randomize_help()
	case .Pitch_Toggle:
		if !pitch_monitor_toggle(&ui.pitch) {
			ui.pitch.permission = Pitch_Permission(vt_pitch_permission_status())
		}
	case .Pitch_Reference_Down:
		ui.pitch.settings.reference_hz =
			max(400, ui.pitch.settings.reference_hz - 1)
		pitch_trace_clear(&ui.pitch)
		save_pitch_settings()
	case .Pitch_Reference_Up:
		ui.pitch.settings.reference_hz =
			min(480, ui.pitch.settings.reference_hz + 1)
		pitch_trace_clear(&ui.pitch)
		save_pitch_settings()
	case .Pitch_Range:
		ui.pitch.settings.range = Pitch_Range(action.value)
		save_pitch_settings()
	case .Pitch_Labels:
		ui.pitch.settings.labels = Pitch_Label_Mode(action.value)
		save_pitch_settings()
	case .Pitch_Transpose:
		ui.pitch.settings.transpose = i32(action.value)
		save_pitch_settings()
	case .Pitch_Highlight:
		ui.pitch.settings.highlight = !ui.pitch.settings.highlight
		save_pitch_settings()
	case .Pitch_Chart:
		return false
	case .Open_Pitch_Help:
		open_pitch_help()
	case .Close_Pitch_Help:
		close_pitch_help()
	case .Exercise_Name:
		focus_text_input(.Exercise_Name)
	case .Cancel_Exercise_Rename:
		close_exercise_rename()
	case .Confirm_Exercise_Rename:
		confirm_exercise_rename()
	case .Exercise_Rename:
		focus_text_input(.Exercise_Rename)
	case .Close_Exercise_Metadata:
		close_exercise_metadata()
	case .View_Exercise_Source:
		view_exercise_source()
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
		stop_player_playback()
	case .Source_Timeline:
		return false
	case .Source_Reset:
		reset_player_playback()
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
		open_data_modal()
	case .Close_Data_Modal:
		close_data_modal()
	case .Open_Data_Folder:
		on_open_data_folder(nil, nil, nil)
	case .Export_Library:
		export_library_with_panel()
	case .Import_Library:
		prepare_library_import_with_panel()
	case .Cancel_Library_Import:
		close_data_modal()
	case .Confirm_Library_Import:
		confirm_library_import()
	case .Recovery_Backup_Only:
		library_recovery_state.option = .Backup_Only
		library_recovery_state.confirm_open = true
	case .Recovery_Backup_With_Salvage:
		library_recovery_state.option = .Backup_With_Salvage
		library_recovery_state.confirm_open = true
	case .Recovery_Salvage_Only:
		library_recovery_state.option = .Salvage_Only
		library_recovery_state.confirm_open = true
	case .Recovery_Cancel:
		library_recovery_state.confirm_open = false
	case .Recovery_Confirm:
		option := library_recovery_state.option
		library_recovery_state.working = true
		if !library_recovery_activate(option) {
			library_recovery_state.working = false
			set_text(state.status, "Library recovery activation failed")
			ui.status_error = true
		} else {
			_ = notification_post(
				.Success,
				"Library recovery activated",
				"The verified replacement library is active. The failed database remains in the Recovery folder.",
			)
		}
	case .Backup_Warning_Cancel:
		major_change_backup_cancel()
	case .Backup_Warning_Continue:
		major_change_backup_continue()
	case .Rename:
		open_exercise_rename()
	case .Metadata:
		open_exercise_metadata()
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
		"Stop playback",
		"Stop the loaded source or exercise and seek to zero",
		"Command",
		[]string{"transport", "zero"},
		palette_condition(PALETTE_CONTEXT_PLAYER),
		"Available after loading a source or exercise",
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
	play_player := command_palette.Context_Mask(
		u64(PALETTE_CONTEXT_PLAY) | u64(PALETTE_CONTEXT_PLAYER),
	)
	append_command_palette_entry(
		&entries,
		UI_Action{kind = .Source_Reset},
		"Reset exercise",
		"Seek to the start of the loaded exercise",
		"Command",
		[]string{"transport", "zero"},
		palette_condition(play_player),
		"Available after loading an exercise in Play mode",
	)
	transport_actions := [4]UI_Action{
		{kind = .Speed_Down},
		{kind = .Speed_Up},
		{kind = .Volume_Down},
		{kind = .Volume_Up},
	}
	transport_titles := [4]string{"Decrease speed", "Increase speed", "Decrease volume", "Increase volume"}
	transport_subtitles := [4]string{
		"Reduce playback speed by 0.1x",
		"Increase playback speed by 0.1x",
		"Reduce volume by 10 percent",
		"Increase volume by 10 percent",
	}
	for action, index in transport_actions {
		append_command_palette_entry(
			&entries,
			action,
			transport_titles[index],
			transport_subtitles[index],
			"Command",
			nil,
			palette_condition(PALETTE_CONTEXT_PLAYER),
			"Available after loading a source or exercise",
		)
	}
	append_command_palette_entry(
		&entries,
		UI_Action{kind = .Pitch_Toggle},
		ui.pitch.tracking ? "Stop pitch tracking" : "Start pitch tracking",
		"Start or stop live microphone pitch analysis",
		"Command",
		[]string{"microphone", "sing", "tuner", "pitch"},
		palette_condition(PALETTE_CONTEXT_PLAY),
		"Available in Play mode",
	)
	append_command_palette_entry(
		&entries,
		UI_Action{kind = .Data},
		"Open library data",
		"Export, import, or inspect the active library directory",
		"Command",
		[]string{"finder", "logs", "storage", "export", "import", "migration"},
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
	if ui.exercise_rename_open {close_exercise_rename()}
	if ui.exercise_metadata_open {close_exercise_metadata()}
	if ui.randomize_help_open {close_randomize_help()}
	if ui.pitch.help_open {close_pitch_help()}
	if ui.data_modal_open {close_data_modal()}
	if ui.notification_modal_open {close_notification_history()}
	ui.palette_previous_focus = ui.focus
	ui.palette_previous_input = text_input.snapshot_focus(&ui.input_state)
	clear_marked_text()
	ui_set_string(&ui.command_palette_query, "")
	ui.command_palette_scroll = 0
	entries := build_command_palette_entries()
	search_error := command_palette.open(
		&command_palette_state,
		entries[:],
		palette_active_context(),
	)
	if search_error != .None {
		clear(&command_palette_actions)
		ui.focus = ui.palette_previous_focus
		target := focused_text()
		previous_text := ""
		if target != nil {previous_text = target^}
		text_input.restore_focus(
			&ui.input_state,
			ui.palette_previous_input,
			previous_text,
		)
		_ = notification_post_error(
			"Command palette entries contain invalid UTF-8.",
		)
		ui.needs_redraw = true
		return false
	}
	focus_text_input(.Command_Palette)
	ui.needs_redraw = true
	return true
}

close_command_palette :: proc(restore_focus: bool) {
	if !command_palette.is_open(&command_palette_state) {return}
	command_palette.close(&command_palette_state)
	clear(&command_palette_actions)
	clear_marked_text()
	ui_set_string(&ui.command_palette_query, "")
	ui.command_palette_scroll = 0
	if restore_focus {
		ui.focus = ui.palette_previous_focus
		target := focused_text()
		previous_text := ""
		if target != nil {previous_text = target^}
		text_input.restore_focus(
			&ui.input_state,
			ui.palette_previous_input,
			previous_text,
		)
	} else {
		ui.focus = .None
		_ = text_input.blur(&ui.input_state)
	}
	text_input.end_pointer_selection(&ui.input_state)
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
	clear_marked_text()
	ui_set_string(&ui.command_palette_query, "")
	ui.command_palette_scroll = 0
	ui.focus = .None
	_ = text_input.blur(&ui.input_state)
	text_input.end_pointer_selection(&ui.input_state)
	if ui.source_modal_open {close_source_modal()}
	if ui.source_details_open {close_source_details()}
	if ui.exercise_rename_open {close_exercise_rename()}
	if ui.exercise_metadata_open {close_exercise_metadata()}
	if ui.randomize_help_open {close_randomize_help()}
	if ui.pitch.help_open {close_pitch_help()}
	if ui.data_modal_open {close_data_modal()}
	if ui.notification_modal_open {close_notification_history()}
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
	case .Toggle_Save_Source_Browser:
		checked := uint(0)
		if ui.save_source_browser_choice {checked = 1}
		return msg_id_uint(
			objc_getClass("NSNumber"),
			sel_registerName("numberWithUnsignedInt:"),
			checked,
		)
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
	case .Exercise_Rename:
		return nsstring(ui.exercise_rename)
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
		search_error := command_palette.set_query(
			&command_palette_state,
			ui.command_palette_query,
		)
		if search_error != .None {
			ui_set_string(
				&ui.command_palette_query,
				command_palette.query(&command_palette_state),
			)
			_ = notification_post_error(
				"Command palette search contains invalid UTF-8.",
			)
		}
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
	case .Exercise_Rename:
		ui_set_string(&ui.exercise_rename, text)
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
		MTL_Clear_Color{
			ui_theme_colors().chassis[0],
			ui_theme_colors().chassis[1],
			ui_theme_colors().chassis[2],
			1,
		},
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

	_, _, _, _, player, _, _, _, _, _, _ := layout_rects()
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
	ui.render_count += 1
	memory.frame_stats.high_water = max(memory.frame_stats.high_water, memory.frame.total_used)
	memory.redraw_stats.high_water = max(memory.redraw_stats.high_water, memory.redraw.total_used)
	ui.needs_redraw = !overlay_uploaded
}

ui_memory_destroy :: proc() {
	pitch_monitor_stop(&ui.pitch)
	metal_player_clear()
	app_state_collections_destroy(&pending_library_import)
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
	delete(ui.exercise_rename)
	delete(ui.command_palette_query)
	delete(ui.status)
	delete(ui.status_source_video_id)
	text_input.destroy(&ui.input_state)
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

metal_player_clear_texture :: proc() {
	if ui.last_video_texture != nil {
		msg_void(ui.last_video_texture, sel_registerName("release"))
		ui.last_video_texture = nil
		ui.last_video_width, ui.last_video_height = 0, 0
	}
}

metal_audio_pause :: proc() {
	if ui.audio_player != nil {msg_void(ui.audio_player, sel_registerName("stop"))}
	if ui.audio_engine != nil {msg_void(ui.audio_engine, sel_registerName("stop"))}
}

metal_audio_engine_running :: proc() -> bool {
	return ui.audio_engine != nil &&
	       msg_bool(ui.audio_engine, sel_registerName("isRunning"))
}

metal_audio_play :: proc() -> bool {
	if ui.audio_engine == nil || ui.audio_player == nil {return false}
	if !metal_audio_engine_running() {
		error: Id
		msg_void(ui.audio_engine, sel_registerName("prepare"))
		if !msg_bool_error(
			   ui.audio_engine,
			   sel_registerName("startAndReturnError:"),
			   &error,
		   ) {
			return false
		}
	}
	msg_void(ui.audio_player, sel_registerName("play"))
	return true
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
	if resume {_ = metal_audio_play()}
}

metal_audio_observe_configuration :: proc(engine: Id) {
	if engine == nil || state.delegate_target == nil {return}
	center := msg_id(objc_getClass("NSNotificationCenter"), sel_registerName("defaultCenter"))
	msg_void_id_sel_id_id(
		center,
		sel_registerName("addObserver:selector:name:object:"),
		state.delegate_target,
		sel_registerName("audioEngineConfigurationChanged:"),
		AVAudioEngineConfigurationChangeNotification,
		engine,
	)
}

metal_audio_stop_observing_configuration :: proc(engine: Id) {
	if engine == nil || state.delegate_target == nil {return}
	center := msg_id(objc_getClass("NSNotificationCenter"), sel_registerName("defaultCenter"))
	msg_void_id_id_id(
		center,
		sel_registerName("removeObserver:name:object:"),
		state.delegate_target,
		AVAudioEngineConfigurationChangeNotification,
		engine,
	)
}

metal_audio_release :: proc(engine, player, pitch, file: Id) {
	metal_audio_stop_observing_configuration(engine)
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
	metal_audio_observe_configuration(engine)
	return engine, player, pitch, file, true
}

metal_audio_recover_configuration :: proc(engine: Id) -> bool {
	if engine == nil || engine != ui.audio_engine || state.player == nil {return false}
	resume := msg_f32(state.player, sel_registerName("rate")) > 0
	msg_void(state.player, sel_registerName("pause"))
	seconds, has_seconds := current_seconds()
	if !has_seconds {return false}
	seek_video_seconds(seconds)
	metal_audio_seek(seconds, false)
	if resume {
		if !metal_audio_play() {return false}
		msg_void_f32(state.player, sel_registerName("setRate:"), ui.playback_rate)
	}
	ui.needs_redraw = true
	return true
}

on_audio_engine_configuration_changed :: proc "c" (self: Id, command: Sel, notification: Id) {
	context = runtime.default_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	engine := msg_id(notification, sel_registerName("object"))
	if engine == nil {return}
	msg_void_sel_id_b(
		self,
		sel_registerName("performSelectorOnMainThread:withObject:waitUntilDone:"),
		sel_registerName("recoverAudioEngineConfiguration:"),
		engine,
		false,
	)
}

on_audio_engine_recover_configuration :: proc "c" (self: Id, command: Sel, engine: Id) {
	context = runtime.default_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	if engine != ui.audio_engine {return}
	if metal_audio_recover_configuration(engine) {return}
	if state.player != nil {msg_void(state.player, sel_registerName("pause"))}
	set_error_status("Audio output changed, but playback could not reconnect")
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
	ui.player_duration = 0
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
	kinds := [12]UI_Action_Kind{.Start, .End, .Save, .Play, .Pause, .Captions, .Preview, .Data, .Rename, .Metadata, .Randomize, .Pitch_Toggle}
	if index < 0 || index >= len(kinds) {return}
	control := find_ui_control_by_action(kinds[index])
	if control != nil && .Enabled in control.flags {_ = activate_ui_action(control.action)}
}

editable_action_for_focus :: proc(
	focus: UI_Focus,
) -> (UI_Action_Kind, bool) {
	#partial switch focus {
	case .Command_Palette: return .Command_Palette_Search, true
	case .URL:              return .URL, true
	case .Source_Search:    return .Source_Search, true
	case .Transcript_Search:return .Transcript_Search, true
	case .Exercise_Search:  return .Exercise_Search, true
	case .Exercise_Name:    return .Exercise_Name, true
	case .Exercise_Rename:  return .Exercise_Rename, true
	}
	return .Command_Palette_Search, false
}

text_line_for_offset :: proc(text: string, offset: int) -> int {
	line := 0
	for index in 0 ..< min(max(offset, 0), len(text)) {
		if text[index] == '\n' {line += 1}
	}
	return line
}

editable_offset_at_point :: proc(
	control: ^UI_Control,
	focus: UI_Focus,
	point: Point,
) -> int {
	target := focused_text()
	if target == nil {return 0}
	if focus == .Command_Palette {
		return text_offset_at_point(target^, control.rect, point, 12)
	}
	if focus != .URL {
		return text_offset_at_point(target^, control.rect, point)
	}
	lines := strings.split_lines(target^)
	if len(lines) == 0 {return 0}
	caret_line := text_line_for_offset(target^, ui.caret_byte_offset)
	first_line := min(max(0, caret_line - 9), max(0, len(lines) - 10))
	relative_line := int(max(
		0,
		min(
			f64(min(9, len(lines) - first_line - 1)),
			(control.rect.y + control.rect.h - 19 - point.y) / 23,
		),
	))
	clicked_line := first_line + relative_line
	line_start := 0
	for index in 0 ..< clicked_line {line_start += len(lines[index]) + 1}
	return text_offset_at_point(
		fmt.tprintf("$ %s", lines[clicked_line]),
		UI_Rect{
			control.rect.x + 12,
			control.rect.y,
			control.rect.w - 24,
			control.rect.h,
		},
		point,
		0,
		line_start,
		2,
	)
}

begin_text_selection_at_offset :: proc(
	target: ^string,
	focus: UI_Focus,
	offset: int,
	click_count: uint,
) {
	text_input.begin_pointer_selection(
		&ui.input_state,
		text_field_id(focus),
		target^,
		offset,
		click_count,
	)
	ui.needs_redraw = true
}

begin_text_pointer_selection :: proc(
	control: ^UI_Control,
	focus: UI_Focus,
	point: Point,
	click_count: uint,
) {
	clear_marked_text()
	focus_text_input(focus)
	target := focused_text()
	if target == nil {return}
	offset := editable_offset_at_point(control, focus, point)
	begin_text_selection_at_offset(target, focus, offset, click_count)
}

update_text_pointer_selection :: proc(point: Point) -> bool {
	if !ui.drag_active {return false}
	focus := UI_Focus(ui.drag_field)
	if ui.focus != focus {return false}
	kind, valid_kind := editable_action_for_focus(focus)
	if !valid_kind {return false}
	control := find_ui_control_by_action(kind)
	target := focused_text()
	if control == nil || target == nil {return false}
	offset := editable_offset_at_point(control, focus, point)
	changed := text_input.update_pointer_selection(
		&ui.input_state,
		text_field_id(focus),
		target^,
		offset,
	)
	ui.needs_redraw = ui.needs_redraw || changed
	return changed
}

activate_registered_target_at_point :: proc(
	point: Point,
	click_count: uint = 1,
) -> bool {
	control := find_ui_control_at_point(ui_build.controls[:], point, .Primary_Press)
	if control == nil {return false}
	#partial switch control.action.kind {
	case .Command_Palette_Search:
		begin_text_pointer_selection(control, .Command_Palette, point, click_count)
	case .URL:
		if ui.source_modal_refetch_index >= 0 {return true}
		begin_text_pointer_selection(control, .URL, point, click_count)
	case .Source_Search:
		begin_text_pointer_selection(control, .Source_Search, point, click_count)
	case .Transcript_Search:
		begin_text_pointer_selection(control, .Transcript_Search, point, click_count)
	case .Exercise_Search:
		begin_text_pointer_selection(control, .Exercise_Search, point, click_count)
	case .Exercise_Name:
		begin_text_pointer_selection(control, .Exercise_Name, point, click_count)
	case .Exercise_Rename:
		begin_text_pointer_selection(control, .Exercise_Rename, point, click_count)
	case .Source_Timeline:
		ui.source_scrubbing = true
		seek_player_timeline_rect(point, control.rect)
	case:
		return activate_ui_action(control.action)
	}
	return true
}

dispatch_click :: proc(point: Point, click_count: uint = 1) {
	cancel_ui_flash()
	text_input.end_pointer_selection(&ui.input_state)
	if command_palette.is_open(&command_palette_state) {
		modal := command_palette_rect()
		if !contains(modal, point) {close_command_palette(true); return}
		_ = activate_registered_target_at_point(point, click_count)
		return
	}
	clear_marked_text()
	if ui.randomize_help_open {
		modal := randomize_help_modal_rect()
		if !contains(modal, point) {close_randomize_help(); return}
		_ = activate_registered_target_at_point(point, click_count)
		return
	}
	if ui.pitch.help_open {
		modal := pitch_help_modal_rect()
		if !contains(modal, point) {close_pitch_help(); return}
		_ = activate_registered_target_at_point(point, click_count)
		return
	}
	if ui.notification_modal_open {
		modal := notification_modal_rect()
		if !contains(modal, point) {close_notification_history(); return}
		_ = activate_registered_target_at_point(point, click_count)
		return
	}
	if ui.data_modal_open {
		modal := data_modal_rect()
		if !contains(modal, point) {close_data_modal(); return}
		_ = activate_registered_target_at_point(point, click_count)
		return
	}
	if ui.exercise_metadata_open {
		modal := exercise_metadata_modal_rect()
		if !contains(modal, point) {close_exercise_metadata(); return}
		_ = activate_registered_target_at_point(point, click_count)
		return
	}
	if ui.exercise_rename_open {
		modal := exercise_rename_modal_rect()
		if !contains(modal, point) {close_exercise_rename(); return}
		_ = activate_registered_target_at_point(point, click_count)
		return
	}
	if ui.source_details_open {
		modal := source_details_rect()
		if !contains(modal, point) {close_source_details(); return}
		_ = activate_registered_target_at_point(point, click_count)
		return
	}
	if ui.source_modal_open {
		modal := source_modal_rect()
		if !contains(modal, point) {close_source_modal(); return}
		_ = activate_registered_target_at_point(point, click_count)
		return
	}
	clicked_control := find_ui_control_at_point(
		ui_build.controls[:],
		point,
		.Primary_Press,
	)
	if clicked_control != nil && .Editable in clicked_control.flags {
		_ = activate_registered_target_at_point(point, click_count)
		return
	}
	ui.focus = .None
	text_input.end_pointer_selection(&ui.input_state)
	if ui.source_hint_menu_open {
		if clicked_control == nil ||
		   (clicked_control.action.kind != .Source_Hint_Menu &&
		    clicked_control.action.kind != .Source_Hint) {
			ui.source_hint_menu_open = false
		}
	}
	if activate_registered_target_at_point(point, click_count) {return}
}

ui_action_is_window :: proc(kind: UI_Action_Kind) -> bool {
	return kind == .Window_Close ||
	       kind == .Window_Minimize ||
	       kind == .Window_Zoom
}

begin_window_resize :: proc(point: Point) -> bool {
	edges := window_resize_edges_for_size(point, ui.width, ui.height)
	if edges == 0 {return false}
	cancel_ui_flash()
	ui.resize_edges = edges
	text_input.end_pointer_selection(&ui.input_state)
	ui.source_scrubbing = false
	ui.resize_start_mouse = msg_point(
		objc_getClass("NSEvent"),
		sel_registerName("mouseLocation"),
	)
	ui.resize_start_frame = msg_rect(state.window, sel_registerName("frame"))
	return true
}

resize_window_from_current_mouse :: proc() {
	mouse := msg_point(
		objc_getClass("NSEvent"),
		sel_registerName("mouseLocation"),
	)
	delta := Point{
		mouse.x-ui.resize_start_mouse.x,
		mouse.y-ui.resize_start_mouse.y,
	}
	frame := window_frame_after_drag(
		ui.resize_start_frame,
		ui.resize_edges,
		delta,
	)
	msg_void_rect_b(
		state.window,
		sel_registerName("setFrame:display:"),
		frame,
		true,
	)
	ui.needs_redraw = true
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
	if begin_window_resize(ui.mouse) {return}
	window_control := find_ui_control_at_point(
		ui_build.controls[:],
		ui.mouse,
		.Primary_Press,
	)
	if window_control != nil &&
	   ui_action_is_window(window_control.action.kind) {
		cancel_ui_flash()
		_ = activate_ui_action(window_control.action)
		return
	}
	click_count := msg_uint(event, sel_registerName("clickCount"))
	if !command_palette.is_open(&command_palette_state) &&
	   !ui.source_modal_open && !ui.source_details_open &&
	   !ui.exercise_rename_open && !ui.exercise_metadata_open &&
	   !ui.randomize_help_open && !ui.pitch.help_open &&
	   !ui.data_modal_open && !ui.notification_modal_open &&
	   header_window_gesture_allowed(
			app_header_rect(),
			ui_build.controls[:],
			ui.mouse,
	   ) {
		cancel_ui_flash()
		if click_count >= 2 {
			toggle_window_zoom()
		} else {
			msg_void_id(state.window, sel_registerName("performWindowDragWithEvent:"), event)
		}
		return
	}
	dispatch_click(ui.mouse, click_count)
	ui.needs_redraw = true
}

on_metal_right_mouse_down :: proc "c" (self: Id, command: Sel, event: Id) {
	context = runtime.default_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	cancel_ui_flash()
	if command_palette.is_open(&command_palette_state) {return}
	if ui.source_modal_open || ui.source_details_open ||
	   ui.exercise_rename_open || ui.exercise_metadata_open ||
	   ui.randomize_help_open || ui.pitch.help_open ||
	   ui.data_modal_open || ui.notification_modal_open ||
	   ui.mode != .Create {
		return
	}
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
	if ui.resize_edges != 0 {
		resize_window_from_current_mouse()
		return
	}
	window_point := msg_point(event, sel_registerName("locationInWindow"))
	ui.mouse = msg_point_point_id(self, sel_registerName("convertPoint:fromView:"), window_point, nil)
	if update_text_pointer_selection(ui.mouse) {
		ui.needs_redraw = true
		return
	}
	if ui.source_scrubbing {
		control := find_ui_control_by_action(.Source_Timeline)
		if control != nil && .Drag in control.flags {seek_player_timeline_rect(ui.mouse, control.rect)}
	}
	ui.needs_redraw = true
}

on_metal_mouse_up :: proc "c" (self: Id, command: Sel, event: Id) {
	context = runtime.default_context()
	text_input.end_pointer_selection(&ui.input_state)
	if ui.resize_edges != 0 {
		ui.resize_edges = 0
		ui.needs_redraw = true
	}
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
	if ui.notification_modal_open {
		delta := msg_f64(event, sel_registerName("scrollingDeltaY"))
		ui.notification_scroll = notification_scroll_after_delta(
			ui.notification_scroll,
			delta,
			notification_max_scroll(notification_modal_rect()),
		)
		ui.needs_redraw = true
		return
	}
	if ui.source_modal_open || ui.source_details_open ||
	   ui.exercise_rename_open || ui.exercise_metadata_open ||
	   ui.randomize_help_open || ui.pitch.help_open || ui.data_modal_open {
		return
	}
	delta := msg_f64(event, sel_registerName("scrollingDeltaY"))
	window_point := msg_point(event, sel_registerName("locationInWindow"))
	point := msg_point_point_id(
		self,
		sel_registerName("convertPoint:fromView:"),
		window_point,
		nil,
	)
	_, _, source_search, source_panel, _, transcript, exercise_search, exercise_panel, exercise_name, _, _ :=
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

copy_focused_text_selection :: proc() -> bool {
	target := focused_text()
	if target == nil {return false}
	start, end := text_selection_bounds(target^)
	if start == end {return false}
	pasteboard := msg_id(
		objc_getClass("NSPasteboard"),
		sel_registerName("generalPasteboard"),
	)
	if pasteboard == nil {return false}
	_ = msg_i64(pasteboard, sel_registerName("clearContents"))
	return msg_bool_id_id(
		pasteboard,
		sel_registerName("setString:forType:"),
		nsstring(target^[start:end]),
		nsstring("public.utf8-plain-text"),
	)
}

on_metal_copy :: proc "c" (self: Id, command: Sel, sender: Id) {
	context = runtime.default_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	_ = copy_focused_text_selection()
}

on_metal_cut :: proc "c" (self: Id, command: Sel, sender: Id) {
	context = runtime.default_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	target := focused_text()
	if target == nil || !copy_focused_text_selection() {return}
	if remove_text_selection(target) {focused_text_changed(target)}
	ui.needs_redraw = true
}

on_metal_select_all :: proc "c" (self: Id, command: Sel, sender: Id) {
	context = runtime.default_context()
	target := focused_text()
	if target == nil {return}
	set_text_selection(0, len(target^), target^)
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
		if target != nil {clear_marked_text(); move_text_left(target, false)}
	} else if selector == sel_registerName("moveRight:") {
		if target != nil {clear_marked_text(); move_text_right(target, false)}
	} else if selector == sel_registerName("moveLeftAndModifySelection:") {
		if target != nil {clear_marked_text(); move_text_left(target, true)}
	} else if selector == sel_registerName("moveRightAndModifySelection:") {
		if target != nil {clear_marked_text(); move_text_right(target, true)}
	} else if selector == sel_registerName("moveWordLeft:") ||
	          selector == sel_registerName("moveWordBackward:") {
		if target != nil {clear_marked_text(); move_text_word_left(target, false)}
	} else if selector == sel_registerName("moveWordRight:") ||
	          selector == sel_registerName("moveWordForward:") {
		if target != nil {clear_marked_text(); move_text_word_right(target, false)}
	} else if selector == sel_registerName("moveWordLeftAndModifySelection:") ||
	          selector == sel_registerName("moveWordBackwardAndModifySelection:") {
		if target != nil {clear_marked_text(); move_text_word_left(target, true)}
	} else if selector == sel_registerName("moveWordRightAndModifySelection:") ||
	          selector == sel_registerName("moveWordForwardAndModifySelection:") {
		if target != nil {clear_marked_text(); move_text_word_right(target, true)}
	} else if selector == sel_registerName("moveUp:") {
		if target != nil {
			clear_marked_text()
			move_text_selection(
				target,
				vertical_text_offset(target^, ui.caret_byte_offset, -1),
				false,
			)
		}
	} else if selector == sel_registerName("moveDown:") {
		if target != nil {
			clear_marked_text()
			move_text_selection(
				target,
				vertical_text_offset(target^, ui.caret_byte_offset, 1),
				false,
			)
		}
	} else if selector == sel_registerName("moveUpAndModifySelection:") {
		if target != nil {
			clear_marked_text()
			move_text_selection(
				target,
				vertical_text_offset(target^, ui.caret_byte_offset, -1),
				true,
			)
		}
	} else if selector == sel_registerName("moveDownAndModifySelection:") {
		if target != nil {
			clear_marked_text()
			move_text_selection(
				target,
				vertical_text_offset(target^, ui.caret_byte_offset, 1),
				true,
			)
		}
	} else if selector == sel_registerName("moveToBeginningOfLine:") ||
	          selector == sel_registerName("moveToLeftEndOfLine:") {
		if target != nil {
			clear_marked_text()
			move_text_selection(
				target,
				line_start_for_offset(target^, ui.caret_byte_offset),
				false,
			)
		}
	} else if selector == sel_registerName("moveToEndOfLine:") ||
	          selector == sel_registerName("moveToRightEndOfLine:") {
		if target != nil {
			clear_marked_text()
			move_text_selection(
				target,
				line_end_for_offset(target^, ui.caret_byte_offset),
				false,
			)
		}
	} else if selector == sel_registerName("moveToBeginningOfLineAndModifySelection:") ||
	          selector == sel_registerName("moveToLeftEndOfLineAndModifySelection:") {
		if target != nil {
			clear_marked_text()
			move_text_selection(
				target,
				line_start_for_offset(target^, ui.caret_byte_offset),
				true,
			)
		}
	} else if selector == sel_registerName("moveToEndOfLineAndModifySelection:") ||
	          selector == sel_registerName("moveToRightEndOfLineAndModifySelection:") {
		if target != nil {
			clear_marked_text()
			move_text_selection(
				target,
				line_end_for_offset(target^, ui.caret_byte_offset),
				true,
			)
		}
	} else if selector == sel_registerName("selectAll:") {
		on_metal_select_all(self, selector, nil)
	} else if selector == sel_registerName("copy:") {
		on_metal_copy(self, selector, nil)
	} else if selector == sel_registerName("cut:") {
		on_metal_cut(self, selector, nil)
	} else if selector == sel_registerName("paste:") {
		on_metal_paste(self, selector, nil)
	} else if selector == sel_registerName("insertNewline:") {
		if ui.focus == .URL {
			insert_text_at_caret(&ui.url_input, "\n")
			schedule_source_probe(1)
		} else if ui.focus == .Exercise_Rename {
			confirm_exercise_rename()
		} else if ui.focus == .Source_Search ||
		          ui.focus == .Transcript_Search ||
		          ui.focus == .Exercise_Search ||
		          ui.focus == .Exercise_Name {
			ui.focus = .None
			text_input.end_pointer_selection(&ui.input_state)
		}
	} else if selector == sel_registerName("insertTab:") {
		if ui.exercise_rename_open {
			focus_text_input(.Exercise_Rename)
		} else if ui.source_modal_open {
			focus_text_input(.URL)
		} else if ui.mode == .Play {
			focus_text_input(.Exercise_Search)
		} else {
			#partial switch ui.focus {
			case .None:
				focus_text_input(.Source_Search)
			case .Source_Search:
				focus_text_input(.Transcript_Search)
			case .Transcript_Search:
				focus_text_input(.Exercise_Name)
			case:
				ui.focus = .None
				text_input.end_pointer_selection(&ui.input_state)
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
	if ui.exercise_metadata_open && key == 53 {close_exercise_metadata(); return}
	if ui.exercise_rename_open && key == 53 {close_exercise_rename(); return}
	if ui.randomize_help_open {
		if key == 53 {close_randomize_help()}
		return
	}
	if ui.pitch.help_open {
		if key == 53 {close_pitch_help()}
		if key == 18 {close_pitch_help()}
		return
	}
	if ui.data_modal_open && key == 53 {close_data_modal(); return}
	if ui.notification_modal_open {
		if key == 53 {close_notification_history(); return}
		if key == 125 {_ = select_relative_notification(-1); return}
		if key == 126 {_ = select_relative_notification(1); return}
		return
	}
	if key == 53 && unfocus_text_input() {return}
	if ui.source_modal_open && key == 53 {close_source_modal(); return}
	if ui.source_details_open && key == 53 {close_source_details(); return}
	if focused_text() != nil && is_copy_shortcut(key, modifiers) {
		on_metal_copy(self, sel_registerName("copy:"), nil)
		return
	}
	if focused_text() != nil && is_cut_shortcut(key, modifiers) {
		on_metal_cut(self, sel_registerName("cut:"), nil)
		return
	}
	if focused_text() != nil && is_select_all_shortcut(key, modifiers) {
		on_metal_select_all(self, sel_registerName("selectAll:"), nil)
		return
	}
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
		if !ui.source_modal_open &&
		   !ui.source_details_open &&
		   !ui.exercise_rename_open &&
		   !ui.exercise_metadata_open &&
		   !ui.randomize_help_open &&
		   !ui.pitch.help_open &&
		   !ui.data_modal_open &&
		   !ui.notification_modal_open &&
		   state.player != nil {
			if delta, scrub := timeline_scrub_delta(key, modifiers); scrub {
				scrub_player_by(delta)
				return
			}
		}
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
	text, ok := text_input_string(value)
	if !ok {return}
	if text_input.set_marked_text(
		&ui.input_state,
		target,
		text,
		int(selected.location),
		int(selected.length),
	) {
		focused_text_changed(target)
		ui.needs_redraw = true
	}
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
		range := text_input.marked_utf16_range(&ui.input_state, target^)
		if !range.valid {return NS_Range{~uint(0), 0}}
		return NS_Range{uint(range.location), uint(range.length)}
	}
	range := text_input.selected_utf16_range(&ui.input_state, target^)
	if !range.valid {return NS_Range{~uint(0), 0}}
	return NS_Range{uint(range.location), uint(range.length)}
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

metal_frame_should_render :: proc(needs_redraw, playback_active: bool) -> bool {
	return needs_redraw || playback_active
}

on_metal_frame :: proc "c" (self: Id, command: Sel, timer: Id) {
	context = runtime.default_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	ui.frame_tick += 1
	if pitch_monitor_poll(&ui.pitch, ui.frame_tick) {
		ui.needs_redraw = true
	}
	if ui.url_probe_pending && ui.frame_tick >= ui.url_probe_due_tick {
		ui.url_probe_pending = false
		source_probe_request()
	}
	if notification_footer_group_active() {
		ui.activity_tick += 1
		if ui.activity_tick % 8 == 0 {
			if import_job != nil {refresh_import_progress()}
			ui.needs_redraw = true
		}
	} else {
		ui.activity_tick = 0
	}
	playback_active := state.player != nil &&
	                   msg_f32(state.player, sel_registerName("rate")) > 0
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
	if metal_frame_should_render(ui.needs_redraw, playback_active) {
		msg_void_size(
			ui.layer,
			sel_registerName("setDrawableSize:"),
			Size{ui.width * ui.scale, ui.height * ui.scale},
		)
		render_frame()
	}
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
		sel_registerName("audioEngineConfigurationChanged:"),
		rawptr(on_audio_engine_configuration_changed),
		"v@:@",
	)
	class_addMethod(
		delegate_class,
		sel_registerName("recoverAudioEngineConfiguration:"),
		rawptr(on_audio_engine_recover_configuration),
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
	class_addMethod(class, sel_registerName("copy:"), rawptr(on_metal_copy), "v@:@")
	class_addMethod(class, sel_registerName("cut:"), rawptr(on_metal_cut), "v@:@")
	class_addMethod(class, sel_registerName("paste:"), rawptr(on_metal_paste), "v@:@")
	class_addMethod(
		class,
		sel_registerName("selectAll:"),
		rawptr(on_metal_select_all),
		"v@:@",
	)
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

window_can_become_key :: proc "c" (self: Id, command: Sel) -> bool {
	return true
}

register_window_class :: proc() -> Id {
	class := objc_allocateClassPair(
		objc_getClass("NSWindow"),
		"VocalTrainingWindow",
		0,
	)
	class_addMethod(
		class,
		sel_registerName("canBecomeKeyWindow"),
		rawptr(window_can_become_key),
		"B@:",
	)
	class_addMethod(
		class,
		sel_registerName("canBecomeMainWindow"),
		rawptr(window_can_become_key),
		"B@:",
	)
	objc_registerClassPair(class)
	return class
}

launch_should_activate :: proc(
	value: cstring,
	launch_in_background := false,
) -> bool {
	if value != nil {return string(value) != "0"}
	return !launch_in_background
}

vocal_gui_initialize :: proc(
	services: ^hot_reload.Host_Services = nil,
) -> bool {
	app := msg_id(objc_getClass("NSApplication"), sel_registerName("sharedApplication"))
	if services != nil {app = Id(services.app)}
	msg_void_i(app, sel_registerName("setActivationPolicy:"), 0)
	if services == nil {
		register_delegate(app)
	} else {
		state.delegate_target = Id(services.delegate)
		msg_void_id(app, sel_registerName("setDelegate:"), state.delegate_target)
	}

	state.url_input = CONTROL_URL
	state.status = CONTROL_STATUS
	state.source_search_input = CONTROL_SOURCE
	state.exercise_search_input = CONTROL_EXERCISE
	state.exercise_name_input = CONTROL_EXERCISE_NAME
	ui_set_string(&ui.status, "Ready")
	ui.scale = 1
	ui.active_exercise = -1
	ui.exercise_rename_index = -1
	ui.exercise_metadata_index = -1
	ui.transcript_matches_dirty = true
	ui.needs_redraw = true
	pitch_monitor_initialize(
		&ui.pitch,
		database_pitch_settings_load(library_database),
	)
	flash.state_init(&flash_state)
	palette_error := command_palette.state_init(
		&command_palette_state,
		search_reserve_size = SEARCH_RESERVE_SIZE,
		search_commit_size = SEARCH_COMMIT_SIZE,
	)
	assert(palette_error == nil, "Unable to initialize the command palette")

	frame := Rect{Point{120, 100}, Size{1100, 720}}
	window_class := Id(services.window_class) if services != nil else register_window_class()
	state.window = msg_id_rect_u_u_b(
		msg_id(window_class, sel_registerName("alloc")),
		sel_registerName("initWithContentRect:styleMask:backing:defer:"),
		frame,
		WINDOW_STYLE,
		2,
		false,
	)
	msg_void_id(state.window, sel_registerName("setTitle:"), nsstring("Vocal Training"))
	msg_void_bool(state.window, sel_registerName("setOpaque:"), true)
	msg_void_bool(state.window, sel_registerName("setHasShadow:"), false)
	msg_void_size(
		state.window,
		sel_registerName("setMinSize:"),
		Size{WINDOW_MIN_WIDTH, WINDOW_MIN_HEIGHT},
	)
	msg_void_bool(state.window, sel_registerName("setAcceptsMouseMovedEvents:"), true)
	if services == nil {register_accessibility_class()}
	view_class := Id(services.view_class) if services != nil else register_metal_view_class()
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
		return false
	}

	if len(state.sources) > 0 {load_source_player(len(state.sources) - 1)}
	// The Objective-C runtime requires the exact floating-point signature, so
	// construct the repeating timer through a typed send.
	if services == nil {
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
	}

	screen := msg_id(objc_getClass("NSScreen"), sel_registerName("mainScreen"))
	msg_void_rect_b(
		state.window,
		sel_registerName("setFrame:display:"),
		msg_rect(screen, sel_registerName("visibleFrame")),
		true,
	)
	msg_void_id(state.window, sel_registerName("makeFirstResponder:"), ui.view)
	launch_in_background := services != nil && services.launch_in_background
	if launch_should_activate(
		getenv("VT_ACTIVATE_ON_LAUNCH"),
		launch_in_background,
	) {
		msg_void_id(state.window, sel_registerName("makeKeyAndOrderFront:"), nil)
		msg_void_i(app, sel_registerName("activateIgnoringOtherApps:"), 1)
	} else {
		msg_void_id(state.window, sel_registerName("orderBack:"), nil)
	}
	if !cli_ipc_server_start() {set_text(state.status, "CLI control socket is unavailable")}
	validate_startup_helpers()
	request_next_missing_source_metadata()
	return true
}

build_metal_window :: proc() {
	if !vocal_gui_initialize() {return}
	app := msg_id(objc_getClass("NSApplication"), sel_registerName("sharedApplication"))
	msg_void(app, sel_registerName("run"))
}
