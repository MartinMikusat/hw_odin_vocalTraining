package main

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:hash"
import "core:math"
import mem_virtual "core:mem/virtual"
import os "core:os/old"
import "core:path/filepath"
import "core:strings"
import "core:time"
import posix "core:sys/posix"
import CF "core:sys/darwin/CoreFoundation"
import command_palette "command_palette:."
import text_input "components:text_input"
import flash "flash:."
import match_sorter "match_sorter:."
import framework_coretext "ui_framework:coretext"
import framework_ui "ui_framework:core"
import framework_draw "ui_framework:draw"
import framework_macos "ui_framework:macos"
import framework_metal "ui_framework:metal"

foreign import avfaudio "system:AVFAudio.framework"
foreign avfaudio {
	AVAudioEngineConfigurationChangeNotification: Id
}

foreign import avfoundation "system:AVFoundation.framework"
foreign avfoundation {
	AVPlayerItemDidPlayToEndTimeNotification: Id
}

foreign import core_graphics "system:CoreGraphics.framework"
foreign core_graphics {
	CGColorSpaceCreateDeviceRGB :: proc "c" () -> rawptr ---
	CGColorSpaceRelease :: proc "c" (space: rawptr) ---
	CGBitmapContextCreate :: proc "c" (data: rawptr, width, height, bits_per_component, bytes_per_row: uint, space: rawptr, bitmap_info: u32) -> rawptr ---
	CGContextRelease :: proc "c" (ctx: rawptr) ---
	CGContextFillRect :: proc "c" (ctx: rawptr, rect: Rect) ---
	CGContextSetRGBFillColor :: proc "c" (ctx: rawptr, red, green, blue, alpha: f64) ---
	CGContextSetRGBStrokeColor :: proc "c" (ctx: rawptr, red, green, blue, alpha: f64) ---
	CGContextSetLineWidth :: proc "c" (ctx: rawptr, width: f64) ---
	CGContextSetLineCap :: proc "c" (ctx: rawptr, cap: i32) ---
	CGContextSetLineJoin :: proc "c" (ctx: rawptr, join: i32) ---
	CGContextBeginPath :: proc "c" (ctx: rawptr) ---
	CGContextMoveToPoint :: proc "c" (ctx: rawptr, x, y: f64) ---
	CGContextAddLineToPoint :: proc "c" (ctx: rawptr, x, y: f64) ---
	CGContextAddCurveToPoint :: proc "c" (
		ctx: rawptr,
		cp1_x, cp1_y, cp2_x, cp2_y, x, y: f64,
	) ---
	CGContextClosePath :: proc "c" (ctx: rawptr) ---
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
	kCTKernAttributeName: rawptr
}

foreign import core_foundation "system:CoreFoundation.framework"
foreign core_foundation {
	CFStringCreateWithCString :: proc "c" (allocator: rawptr, text: cstring, encoding: u32) -> rawptr ---
	CFStringCreateWithBytes :: proc "c" (allocator: CF.TypeRef, bytes: [^]u8, count: CF.Index, encoding: CF.StringEncoding, external: b8) -> CF.String ---
	CFStringGetLength :: proc "c" (string: rawptr) -> int ---
	CFAttributedStringCreateMutable :: proc "c" (allocator: rawptr, max_length: int) -> rawptr ---
	CFAttributedStringReplaceString :: proc "c" (string: rawptr, range: CF.Range, replacement: rawptr) ---
	CFAttributedStringSetAttribute :: proc "c" (string: rawptr, range: CF.Range, name, value: rawptr) ---
	CFArrayGetCount :: proc "c" (array: rawptr) -> int ---
	CFArrayGetValueAtIndex :: proc "c" (array: rawptr, index: int) -> rawptr ---
	CFNumberCreate :: proc "c" (allocator: rawptr, number_type: int, value: rawptr) -> rawptr ---
	CFRetain :: proc "c" (value: rawptr) -> rawptr ---
	CFRelease :: proc "c" (value: rawptr) ---
	kCFBooleanTrue: rawptr
}

UI_Focus :: enum {
	None,
	Command_Palette,
	Settings_Search,
	URL,
	Local_Source_Title,
	Source_Search,
	Transcript_Search,
	Clip_Search,
	Clip_Name,
	Clip_Rename,
}

UI_Mode :: enum {
	Create,
	Play,
}

UI_Theme :: enum {
	HW_Light,
	HW_Dark,
}

ui_theme_is_dark :: proc(theme: UI_Theme) -> bool {
	#partial switch theme {
	case .HW_Dark:
		return true
	}
	return false
}

ui_theme_name :: proc(theme: UI_Theme) -> string {
	switch theme {
	case .HW_Light: return "HW Light"
	case .HW_Dark: return "HW Dark"
	}
	return "HW Dark"
}

Source_Paste_Result :: enum {
	Not_YouTube,
	Blocked,
	Opened,
}

Source_Add_Mode :: enum {
	URL,
	Local_Files,
}

WORKFLOW_COUNT :: 2
VIDEO_FRAME_RETRY_TICKS :: uint(120)

Numbered_Action_Code :: struct {
	section, action: int,
}

PITCH_ACTION_INDEX :: 11
DANCE_MIRROR_ACTION_INDEX :: 15
DANCE_LOOP_ACTION_INDEX :: 16
DANCE_COUNT_IN_ACTION_INDEX :: 17
DANCE_COUNT_EACH_LOOP_ACTION_INDEX :: 18
PLAYBACK_FULLSCREEN_ACTION_INDEX :: 19

PLAYBACK_FULLSCREEN_CONTROL_TIMEOUT_MS :: i64(2_000)
PLAYER_SURFACE_DOUBLE_CLICK_INTERVAL_MS :: i64(180)
NSApplicationPresentationAutoHideDock :: uint(1 << 0)
NSApplicationPresentationHideDock :: uint(1 << 1)
NSApplicationPresentationAutoHideMenuBar :: uint(1 << 2)
NSApplicationPresentationHideMenuBar :: uint(1 << 3)
NSApplicationPresentationDisplayMask :: uint(
	NSApplicationPresentationAutoHideDock |
	NSApplicationPresentationHideDock |
	NSApplicationPresentationAutoHideMenuBar |
	NSApplicationPresentationHideMenuBar,
)

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
	frame_timer:        framework_macos.Frame_Timer,
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
	video_frame_pending: bool,
	video_frame_deadline: uint,
	video_frame_warmup_pending: bool,
	video_frame_warmup_active: bool,
	video_frame_warmup_due_tick: uint,
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
	workflow:           Workflow_Kind,
	number_prefix:      int,
	number_prefix_deadline_ms: i64,
	theme:              UI_Theme,
	flash_leader:       Video_Clips_Shortcut,
	settings_search:    command_palette.State,
	settings_open:      bool,
	settings_category:  Video_Clips_Settings_Category,
	settings_query:     string,
	settings_query_focused: bool,
	settings_error:     string,
	shortcut_open:      bool,
	shortcut_listening: bool,
	shortcut_candidate: Video_Clips_Shortcut,
	shortcut_candidate_valid: bool,
	shortcut_collision: string,
	shortcut_error:     string,
	shortcut_live_modifiers: Video_Clips_Shortcut_Modifiers,
	discard_confirm_open: bool,
	discard_target: Modal_Discard_Target,
	source_modal_initial_hash: u64,
	clip_rename_initial_hash: u64,
	source_modal_open:  bool,
	source_modal_refetch_index: int,
	source_add_mode: Source_Add_Mode,
	local_source_title_index: int,
	source_details_open: bool,
	source_details_index: int,
	clip_rename_open: bool,
	clip_rename_index: int,
	clip_metadata_open: bool,
	clip_metadata_index: int,
	randomize_help_open: bool,
	data_modal_open: bool,
	notification_modal_open: bool,
	library_import_confirm_open: bool,
	library_import_pending: bool,
	url_input:          string,
	source_search:      string,
	transcript_search:  string,
	clip_search:    string,
	clip_name:      string,
	clip_draft_revision: i64,
	clip_draft_dirty: bool,
	clip_draft_persist_due_ms: i64,
	clip_rename:    string,
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
	clip_scroll:    f64,
	active_clip:    int,
	source_selection_ids: [WORKFLOW_COUNT]string,
	clip_selection_ids: [WORKFLOW_COUNT]string,
	source_selection_saved: [WORKFLOW_COUNT]bool,
	clip_selection_saved: [WORKFLOW_COUNT]bool,
	clip_shuffle:   bool,
	clip_autoplay:  bool,
	player_item:        Id,
	playback_completion_pending: bool,
	player_volume:      f32,
	playback_rate:      f32,
	vocal_playback_rate: f32,
	count_in_active:    bool,
	count_in_value:     int,
	count_in_remaining: int,
	count_in_deadline_ms: i64,
	count_in_for_loop:  bool,
	player_duration:    f64,
	source_playback_active: bool,
	source_scrubbing:   bool,
	source_hint_menu_open: bool,
	pitch:              Pitch_Monitor_State,
	activity_tick:      uint,
	frame_tick:         uint,
	render_count:         uint,
	overlay_revision:     uint,
	pointer_event_count:  uint,
	url_probe_due_tick: uint,
	url_probe_pending:  bool,
	save_source_browser_choice: bool,
	resize_edges:        u8,
	resize_start_mouse:  Point,
	resize_start_frame:  Rect,
	window_zoom_restore_frame: Rect,
	window_has_zoom_restore: bool,
	playback_fullscreen_active: bool,
	playback_fullscreen_controls_visible: bool,
	playback_fullscreen_controls_deadline_ms: i64,
	playback_fullscreen_timestamp_second: i64,
	playback_fullscreen_restore_frame: Rect,
	playback_fullscreen_restore_presentation: uint,
	player_surface_click_pending: bool,
	player_surface_click_deadline_ms: i64,
	needs_redraw:       bool,
}

UI_Rect :: struct {
	x, y, w, h: f64,
}

Player_Transport_Layout :: struct {
	play_pause:   UI_Rect,
	stop:         UI_Rect,
	reset:        UI_Rect,
	speed_down:   UI_Rect,
	speed_value:  UI_Rect,
	speed_up:     UI_Rect,
	volume_down:  UI_Rect,
	volume_value: UI_Rect,
	volume_up:    UI_Rect,
	timestamp:    UI_Rect,
	ready_status: UI_Rect,
	fullscreen:   UI_Rect,
	timeline:     UI_Rect,
	row_count:    int,
	footer_height: f64,
}
NS_Range :: struct {
	location, length: uint,
}
CF_Range :: struct {
	location, length: int,
}

SMALL_FONT_SIZE :: 10.5

Text_Weight :: enum {
	Normal,
	Bold,
}

Text_Style :: struct {
	scale: f64,
	weight: Text_Weight,
	tracking: f64,
}

TEXT_STYLE_BODY :: Text_Style{1.0, .Normal, -0.45}
TEXT_STYLE_LABEL :: Text_Style{0.7, .Normal, 0}
TEXT_STYLE_HEADING :: Text_Style{2.0, .Bold, -0.7}

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
UI_COLOR_DANCING_LIGHT_64 :: [4]f64{0.211765, 0.317647, 0.435294, 1}
UI_COLOR_DANCING_DARK_64 :: [4]f64{0.470588, 0.588235, 0.701961, 1}

system_monospaced_font :: proc(size: f64, weight := Text_Weight.Normal) -> rawptr {
	native_weight := 0.0
	if weight == .Bold {native_weight = 0.4}
	font := msg_id_f64_f64(
		objc_getClass("NSFont"),
		sel_registerName("monospacedSystemFontOfSize:weight:"),
		size,
		native_weight,
	)
	if font == nil {return nil}
	return CFRetain(font)
}

UI_Theme_Colors :: struct {
	chassis, header, panel, panel_alt, field: [4]f64,
	border, rule, row, row_hover: [4]f64,
	backdrop, modal: [4]f64,
	ink, bright, muted, dim: [4]f64,
}

ui_theme_neutrals :: proc(
	canvas, header, surface, raised, field, text, muted: [4]f64,
	overlay: [4]f64,
) -> UI_Theme_Colors {
	row := surface
	row[3] = 0.96
	return {
		chassis = canvas,
		header = header,
		panel = surface,
		panel_alt = raised,
		field = field,
		border = muted,
		rule = raised,
		row = row,
		row_hover = canvas,
		backdrop = overlay,
		modal = header,
		ink = text,
		bright = text,
		muted = muted,
		dim = muted,
	}
}

ui_theme_colors :: proc(theme := ui.theme) -> UI_Theme_Colors {
	switch theme {
	case .HW_Light:
		return ui_theme_neutrals(
			{0.800000, 0.780392, 0.721569, 1}, {0.909804, 0.890196, 0.819608, 1},
			{0.878431, 0.858824, 0.788235, 1}, {0.850980, 0.831373, 0.760784, 1},
			{0.831373, 0.811765, 0.741176, 1}, {0.149020, 0.145098, 0.156863, 1},
			{0.478431, 0.458824, 0.419608, 1}, {0.019608, 0.023529, 0.019608, 0.80},
		)
	case .HW_Dark:
		return ui_theme_neutrals(
			{0.039216, 0.043137, 0.039216, 1}, {0.031373, 0.035294, 0.031373, 1},
			{0.054902, 0.058824, 0.054902, 1}, {0.066667, 0.070588, 0.066667, 1},
			{0.066667, 0.070588, 0.066667, 1}, {0.968627, 0.949020, 0.878431, 1},
			{0.470588, 0.490196, 0.458824, 1}, {0.019608, 0.023529, 0.019608, 0.80},
		)
	}
	return ui_theme_colors(.HW_Dark)
}

workflow_accent_color :: proc(
	workflow: Workflow_Kind,
	dark_theme: bool,
) -> [4]f64 {
	if workflow == .Dancing {
		return dark_theme ? UI_COLOR_DANCING_DARK_64 : UI_COLOR_DANCING_LIGHT_64
	}
	return dark_theme ? UI_COLOR_COFFEE_64 : UI_COLOR_OCHRE_64
}

ui_color_32 :: proc(color: [4]f64) -> [4]f32 {
	return {f32(color[0]), f32(color[1]), f32(color[2]), f32(color[3])}
}

WINDOW_STYLE :: uint(14)
WINDOW_MINIMIZE_STYLE :: uint(15)
WINDOW_RESIZE_INSET :: 6.0
WINDOW_MIN_WIDTH :: 1100.0
WINDOW_MIN_HEIGHT :: 720.0
ACCENT_EDGE_WIDTH :: 4.0
TRACE_FOREIGN_LIFETIMES :: #config(HW_VIDEO_CLIPS_TRACE_FOREIGN_LIFETIMES, false)

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
	Open_Settings,
	Settings_Close,
	Settings_Category,
	Settings_Search,
	Set_Theme,
	Configure_Flash,
	Shortcut_Record,
	Shortcut_Save,
	Shortcut_Reset,
	Shortcut_Cancel,
	Workflow_Toggle,
	Mode_Toggle,
	Open_Source_Modal,
	Source_Mode_URL,
	Source_Mode_Local_Files,
	Browse_Source_Files,
	Cancel_Source_Modal,
	Close_Source_Details,
	Refetch_Source_Details,
	Open_Source_Details,
	URL,
	Local_Source_Title,
	Remove_Local_Source,
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
	Clip_Search,
	Clip,
	Randomize,
	Open_Randomize_Help,
	Close_Randomize_Help,
	Play_Next,
	Shuffle_Toggle,
	Autoplay_Toggle,
	Pitch_Toggle,
	Pitch_Reference_Down,
	Pitch_Reference_Up,
	Pitch_Octaves_Down,
	Pitch_Octaves_Up,
	Pitch_Labels,
	Pitch_Transpose,
	Pitch_Highlight,
	Pitch_Chart,
	Open_Pitch_Help,
	Close_Pitch_Help,
	Dance_Mirror_Toggle,
	Dance_Loop_Toggle,
	Dance_Count_In,
	Dance_Count_Each_Loop_Toggle,
	Dance_BPM_Down,
	Dance_BPM_Up,
	Clip_Name,
	Cancel_Clip_Rename,
	Confirm_Clip_Rename,
	Clip_Rename,
	Close_Clip_Metadata,
	View_Clip_Source,
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
	Playback_Fullscreen_Toggle,
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
	Export_Current_Workflow,
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
	Discard_Keep_Editing,
	Discard_Changes,
}

Modal_Discard_Target :: enum {
	None,
	Shortcut,
	Source,
	Clip_Rename,
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
	layer:               framework_ui.Layer,
}

UI_Build_Output :: struct {
	controls:           [dynamic]UI_Control,
	base_controls:      [dynamic]UI_Control,
	diagnostic_surface: UI_Diagnostic_Surface,
	frame:              int,
}

UI_Control_Build_Scope :: enum {
	Active,
	Base_Visual,
}

ui := UI_State{
	player_volume = 1,
	playback_rate = 1,
	vocal_playback_rate = 1,
	source_details_index = -1,
	source_modal_refetch_index = -1,
	local_source_title_index = -1,
	clip_rename_index = -1,
	clip_metadata_index = -1,
	transcript_active_match = -1,
}
ui_event_tag: int
allow_hidden_window_reveal: bool
ui_build: UI_Build_Output
ui_control_build_scope: UI_Control_Build_Scope
ui_base_control_lookup: bool
flash_state: flash.State
command_palette_state: command_palette.State
command_palette_actions: [dynamic]UI_Action
command_palette_config := command_palette.Config{}
ordered_renderer: framework_metal.Renderer
ordered_text: framework_coretext.Context
ordered_draw: framework_draw.List
ordered_ui_ready: bool
ordered_overlay_active: bool
ordered_rect :: proc(rect: UI_Rect) -> framework_draw.Rect {
	return {f32(rect.x), f32(rect.y), f32(rect.w), f32(rect.h)}
}

ordered_color :: proc(color: [4]f64) -> framework_draw.Color {
	return {f32(color[0]), f32(color[1]), f32(color[2]), f32(color[3])}
}

ordered_ui_initialize :: proc() -> bool {
	framework_draw.list_init(&ordered_draw)
	framework_coretext.context_init(&ordered_text)
	allow_runtime_fallback := false
	when ODIN_DEBUG {allow_runtime_fallback = true}
	resource_path := ""
	bundle := msg_id(objc_getClass("NSBundle"), sel_registerName("mainBundle"))
	if bundle != nil {
		resources := msg_id(bundle, sel_registerName("resourcePath"))
		if resources != nil {
			utf8 := msg_id(resources, sel_registerName("UTF8String"))
			if utf8 != nil {resource_path = fmt.tprintf("%s/ui.metallib", string(cstring(utf8)))}
		}
	}
	if !framework_metal.renderer_init(
		&ordered_renderer,
		rawptr(ui.device),
		resource_path,
		allow_runtime_fallback = allow_runtime_fallback,
	) {
		framework_coretext.context_destroy(&ordered_text)
		framework_draw.list_destroy(&ordered_draw)
		return false
	}
	ordered_ui_ready = true
	return true
}

ordered_ui_destroy :: proc() {
	if !ordered_ui_ready {return}
	framework_coretext.context_destroy(&ordered_text)
	framework_draw.list_destroy(&ordered_draw)
	framework_metal.renderer_destroy(&ordered_renderer)
	ordered_ui_ready = false
}

PALETTE_CONTEXT_CREATE       :: command_palette.Context_Mask(1 << 0)
PALETTE_CONTEXT_PLAY         :: command_palette.Context_Mask(1 << 1)
PALETTE_CONTEXT_PLAYER       :: command_palette.Context_Mask(1 << 2)
PALETTE_CONTEXT_SOURCE       :: command_palette.Context_Mask(1 << 3)
PALETTE_CONTEXT_RANGE        :: command_palette.Context_Mask(1 << 4)
PALETTE_CONTEXT_TIMESTAMPS   :: command_palette.Context_Mask(1 << 5)
PALETTE_CONTEXT_IMPORT_BUSY  :: command_palette.Context_Mask(1 << 6)
PALETTE_CONTEXT_EXPORT_BUSY  :: command_palette.Context_Mask(1 << 7)
PALETTE_CONTEXT_SETTINGS     :: command_palette.Context_Mask(1 << 8)
PALETTE_CONTEXT_LIGHT_THEME  :: command_palette.Context_Mask(1 << 9)
PALETTE_CONTEXT_DARK_THEME   :: command_palette.Context_Mask(1 << 10)
PALETTE_CONTEXT_GLOBAL_MODAL :: command_palette.Context_Mask(1 << 11)
PALETTE_CONTEXT_PLAY_NEXT    :: command_palette.Context_Mask(1 << 12)
PALETTE_CONTEXT_PITCH        :: command_palette.Context_Mask(1 << 13)
PALETTE_CONTEXT_EXPORT_EXCLUSIVE_BUSY :: command_palette.Context_Mask(1 << 14)
PALETTE_CONTEXT_CLIP_SAVE_BUSY :: command_palette.Context_Mask(1 << 15)

CONTROL_URL :: Id(rawptr(uintptr(1)))
CONTROL_STATUS :: Id(rawptr(uintptr(2)))
CONTROL_SOURCE :: Id(rawptr(uintptr(3)))
CONTROL_CLIP :: Id(rawptr(uintptr(4)))
CONTROL_CLIP_NAME :: Id(rawptr(uintptr(5)))

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

msg_bool_uint :: proc(receiver: Id, selector: Sel, value: uint) -> bool {
	p := transmute(proc "c" (_: Id, _: Sel, _: uint) -> bool)send_address
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

msg_id_mouse_event :: proc(
	receiver: Id,
	selector: Sel,
	event_type: uint,
	location: Point,
	modifiers: uint,
	timestamp: f64,
	window_number: int,
	ctx: Id,
	event_number, click_count: int,
	pressure: f32,
) -> Id {
	p := transmute(proc "c" (
		_: Id,
		_: Sel,
		_: uint,
		_: Point,
		_: uint,
		_: f64,
		_: int,
		_: Id,
		_: int,
		_: int,
		_: f32,
	) -> Id)send_address
	return p(
		receiver,
		selector,
		event_type,
		location,
		modifiers,
		timestamp,
		window_number,
		ctx,
		event_number,
		click_count,
		pressure,
	)
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

msg_id_id_error_2 :: proc(receiver: Id, selector: Sel, value: Id, error: ^Id) -> Id {
	p := transmute(proc "c" (_: Id, _: Sel, _: Id, _: ^Id) -> Id)send_address
	return p(receiver, selector, value, error)
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
	case .Settings_Search:
		return &ui.settings_query
	case .URL:
		return &ui.url_input
	case .Local_Source_Title:
		if ui.local_source_title_index >= 0 &&
		   ui.local_source_title_index < len(source_local_titles) {
			return &source_local_titles[ui.local_source_title_index]
		}
	case .Source_Search:
		return &ui.source_search
	case .Transcript_Search:
		return &ui.transcript_search
	case .Clip_Search:
		return &ui.clip_search
	case .Clip_Name:
		return &ui.clip_name
	case .Clip_Rename:
		return &ui.clip_rename
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
	if target == &ui.settings_query {
		if error := command_palette.set_query(
			&ui.settings_search,
			ui.settings_query,
		); error != .None {
			ui_set_string(
				&ui.settings_query,
				command_palette.query(&ui.settings_search),
			)
		}
	}
	if target == &ui.url_input {schedule_source_probe(30)}
	if target == &ui.transcript_search {invalidate_transcript_matches()}
	if target == &ui.clip_name {
		_ = persist_active_clip_draft(debounce = true)
	}
}

text_field_id :: proc(focus: UI_Focus) -> text_input.Field_ID {
	return text_input.Field_ID(focus)
}

focus_text_input :: proc(focus: UI_Focus) {
	if ui.focus == .Clip_Name &&
	   focus != .Clip_Name &&
	   !flush_active_clip_draft() {
		return
	}
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
	if target == &ui.clip_name {_ = flush_active_clip_draft()}
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

workflow_button_rect_for_size :: proc(width, height: f64) -> UI_Rect {
	mode := mode_button_rect_for_size(width, height)
	return UI_Rect{max(18, mode.x - 166), height - 31, 156, 24}
}

workflow_button_rect :: proc() -> UI_Rect {
	return workflow_button_rect_for_size(ui.width, ui.height)
}

settings_button_rect_for_size :: proc(height: f64) -> UI_Rect {
	return window_control_rect_for_size(3, height)
}

settings_button_rect :: proc() -> UI_Rect {
	return settings_button_rect_for_size(ui.height)
}

settings_icon_rect :: proc() -> UI_Rect {
	control := settings_button_rect()
	return {control.x+5, control.y+5, 20, 20}
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
	workflow := workflow_button_rect_for_size(width, height)
	x := 160.0
	return UI_Rect{
		x,
		height-APP_HEADER_HEIGHT+2,
		max(0, workflow.x-x-12),
		APP_HEADER_HEIGHT-2,
	}
}

app_title_rect :: proc() -> UI_Rect {
	return app_title_rect_for_size(ui.width, ui.height)
}

active_view_label :: proc(
	workflow: Workflow_Kind,
	mode: UI_Mode,
) -> string {
	switch workflow {
	case .Vocal:
		switch mode {
		case .Create: return "VOCAL SOURCES"
		case .Play: return "VOCAL CLIPS"
		}
	case .Dancing:
		switch mode {
		case .Create: return "DANCING SOURCES"
		case .Play: return "DANCING CLIPS"
		}
	}
	return ""
}

workflow_switch_label :: proc(workflow: Workflow_Kind) -> string {
	return workflow == .Vocal ? "SWITCH TO DANCING" : "SWITCH TO VOCAL"
}

workspace_switch_label :: proc(mode: UI_Mode) -> string {
	return mode == .Create ? "SWITCH TO CLIPS" : "SWITCH TO SOURCES"
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

Playback_Fullscreen_Result :: enum {
	Unchanged,
	Changed,
	Player_Unavailable,
}

playback_fullscreen_presentation_options :: proc(current: uint) -> uint {
	return current &~ NSApplicationPresentationDisplayMask |
	       NSApplicationPresentationAutoHideDock |
	       NSApplicationPresentationAutoHideMenuBar
}

rects_intersect :: proc(a, b: Rect) -> bool {
	return a.origin.x < b.origin.x+b.size.width &&
	       a.origin.x+a.size.width > b.origin.x &&
	       a.origin.y < b.origin.y+b.size.height &&
	       a.origin.y+a.size.height > b.origin.y
}

playback_restore_frame_is_visible :: proc(frame: Rect) -> bool {
	screens := msg_id(objc_getClass("NSScreen"), sel_registerName("screens"))
	if screens == nil {return false}
	for index in 0..<int(msg_uint(screens, sel_registerName("count"))) {
		screen := msg_id_uint(
			screens,
			sel_registerName("objectAtIndex:"),
			uint(index),
		)
		if screen != nil &&
		   rects_intersect(frame, msg_rect(screen, sel_registerName("frame"))) {
			return true
		}
	}
	return false
}

playback_fullscreen_screen :: proc() -> Id {
	screen := msg_id(state.window, sel_registerName("screen"))
	if screen == nil {
		screen = msg_id(objc_getClass("NSScreen"), sel_registerName("mainScreen"))
	}
	return screen
}

playback_fullscreen_frame :: proc(screen: Id) -> Rect {
	if ui_automation_enabled() {
		return Rect{Point{80, 80}, Size{1280, 800}}
	}
	return msg_rect(screen, sel_registerName("frame"))
}

playback_fullscreen_set_cursor_hidden_until_move :: proc(hidden: bool) {
	msg_void_bool(
		objc_getClass("NSCursor"),
		sel_registerName("setHiddenUntilMouseMoves:"),
		hidden,
	)
}

playback_fullscreen_show_controls :: proc(
	now_ms: i64 = 0,
) {
	if !ui.playback_fullscreen_active {return}
	effective_now_ms := now_ms
	if effective_now_ms == 0 {
		effective_now_ms = numbered_action_time_ms()
	}
	changed := !ui.playback_fullscreen_controls_visible
	ui.playback_fullscreen_controls_visible = true
	ui.playback_fullscreen_controls_deadline_ms =
		effective_now_ms+PLAYBACK_FULLSCREEN_CONTROL_TIMEOUT_MS
	if changed {
		ui.playback_fullscreen_timestamp_second = -1
	}
	playback_fullscreen_set_cursor_hidden_until_move(false)
	ui.needs_redraw = ui.needs_redraw || changed
}

playback_fullscreen_hide_controls :: proc() {
	if !ui.playback_fullscreen_active ||
	   !ui.playback_fullscreen_controls_visible {
		return
	}
	ui.playback_fullscreen_controls_visible = false
	ui.playback_fullscreen_timestamp_second = -1
	playback_fullscreen_set_cursor_hidden_until_move(true)
	ui.needs_redraw = true
}

playback_fullscreen_input_scope_active :: proc() -> bool {
	return command_palette.is_open(&command_palette_state) ||
	       flash.is_active(&flash_state) ||
	       ui.settings_open ||
	       ui.shortcut_open ||
	       ui.source_modal_open ||
	       ui.source_details_open ||
	       ui.clip_rename_open ||
	       ui.clip_metadata_open ||
	       ui.randomize_help_open ||
	       ui.pitch.help_open ||
	       ui.data_modal_open ||
	       ui.notification_modal_open ||
	       global_modal_blocks_commands()
}

playback_fullscreen_controls_stay_visible :: proc(
	playing,
	scrubbing,
	pointer_over_controls,
	input_scope_active: bool,
) -> bool {
	return !playing ||
	       scrubbing ||
	       pointer_over_controls ||
	       input_scope_active
}

playback_fullscreen_transport_rect_for_size :: proc(
	width, height: f64,
) -> UI_Rect {
	return {18, 18, max(0, width-36), min(64, max(0, height-36))}
}

playback_fullscreen_transport_rect :: proc() -> UI_Rect {
	return playback_fullscreen_transport_rect_for_size(ui.width, ui.height)
}

player_fullscreen_toggle_rect :: proc(player: UI_Rect) -> UI_Rect {
	return player_transport_layout(player).fullscreen
}

player_fullscreen_toggle_control :: proc() -> ^UI_Control {
	return find_ui_control(ui_control_id("player full screen toggle"))
}

aspect_fit_rect :: proc(
	container: UI_Rect,
	source_width, source_height: f64,
) -> UI_Rect {
	if container.w <= 0 || container.h <= 0 ||
	   source_width <= 0 || source_height <= 0 {
		return {}
	}
	aspect := source_width/source_height
	result := container
	if result.w/result.h > aspect {
		result.w = result.h*aspect
		result.x += (container.w-result.w)/2
	} else {
		result.h = result.w/aspect
		result.y += (container.h-result.h)/2
	}
	return result
}

reapply_playback_fullscreen_frame :: proc() {
	if !ui.playback_fullscreen_active || state.window == nil {return}
	screen := playback_fullscreen_screen()
	if screen == nil {return}
	frame := playback_fullscreen_frame(screen)
	if msg_rect(state.window, sel_registerName("frame")) != frame {
		msg_void_rect_b(
			state.window,
			sel_registerName("setFrame:display:"),
			frame,
			true,
		)
	}
	ui.needs_redraw = true
}

set_playback_fullscreen :: proc(
	desired: bool,
) -> Playback_Fullscreen_Result {
	if desired == ui.playback_fullscreen_active {
		return .Unchanged
	}
	if desired && state.player == nil {
		return .Player_Unavailable
	}
	cancel_ui_flash()
	clear_number_prefix()
	ui.player_surface_click_pending = false
	ui.player_surface_click_deadline_ms = 0
	app := msg_id(objc_getClass("NSApplication"), sel_registerName("sharedApplication"))
	if desired {
		screen := playback_fullscreen_screen()
		if screen == nil || state.window == nil {return .Player_Unavailable}
		ui.playback_fullscreen_restore_frame =
			msg_rect(state.window, sel_registerName("frame"))
		ui.playback_fullscreen_restore_presentation =
			msg_uint(app, sel_registerName("presentationOptions"))
		ui.playback_fullscreen_active = true
		ui.playback_fullscreen_controls_visible = true
		ui.playback_fullscreen_controls_deadline_ms =
			numbered_action_time_ms()+PLAYBACK_FULLSCREEN_CONTROL_TIMEOUT_MS
		ui.playback_fullscreen_timestamp_second = -1
		ui.focus = .None
		text_input.end_pointer_selection(&ui.input_state)
		clear_marked_text()
		msg_void_i(
			app,
			sel_registerName("setPresentationOptions:"),
			int(playback_fullscreen_presentation_options(
				ui.playback_fullscreen_restore_presentation,
			)),
		)
		msg_void_rect_b(
			state.window,
			sel_registerName("setFrame:display:"),
			playback_fullscreen_frame(screen),
			true,
		)
		playback_fullscreen_set_cursor_hidden_until_move(false)
	} else {
		ui.playback_fullscreen_active = false
		ui.playback_fullscreen_controls_visible = false
		ui.playback_fullscreen_controls_deadline_ms = 0
		ui.playback_fullscreen_timestamp_second = -1
		restore := ui.playback_fullscreen_restore_frame
		if !playback_restore_frame_is_visible(restore) {
			screen := msg_id(
				objc_getClass("NSScreen"),
				sel_registerName("mainScreen"),
			)
			if screen != nil {
				restore = msg_rect_rect_id(
					state.window,
					sel_registerName("constrainFrameRect:toScreen:"),
					restore,
					screen,
				)
			}
		}
		if state.window != nil {
			msg_void_rect_b(
				state.window,
				sel_registerName("setFrame:display:"),
				restore,
				true,
			)
		}
		msg_void_i(
			app,
			sel_registerName("setPresentationOptions:"),
			int(ui.playback_fullscreen_restore_presentation),
		)
		ui.playback_fullscreen_restore_frame = {}
		ui.playback_fullscreen_restore_presentation = 0
		playback_fullscreen_set_cursor_hidden_until_move(false)
	}
	ui.needs_redraw = true
	return .Changed
}

toggle_playback_fullscreen :: proc() -> Playback_Fullscreen_Result {
	return set_playback_fullscreen(!ui.playback_fullscreen_active)
}

player_surface_double_click_interval_ms :: proc() -> i64 {
	return PLAYER_SURFACE_DOUBLE_CLICK_INTERVAL_MS
}

player_surface_click_is_double :: proc(
	click_count: uint,
	pending: bool,
	now_ms,
	deadline_ms: i64,
) -> bool {
	return click_count >= 2 && pending && now_ms < deadline_ms
}

cancel_player_surface_click :: proc() {
	ui.player_surface_click_pending = false
	ui.player_surface_click_deadline_ms = 0
}

schedule_player_surface_click :: proc(now_ms: i64 = 0) {
	effective_now_ms := now_ms
	if effective_now_ms == 0 {
		effective_now_ms = numbered_action_time_ms()
	}
	ui.player_surface_click_pending = true
	ui.player_surface_click_deadline_ms =
		effective_now_ms+player_surface_double_click_interval_ms()
}

advance_player_surface_click :: proc(now_ms: i64) -> bool {
	if !ui.player_surface_click_pending ||
	   now_ms < ui.player_surface_click_deadline_ms {
		return false
	}
	cancel_player_surface_click()
	on_toggle_playback(nil, nil, nil)
	return true
}

playback_fullscreen_tick :: proc(
	now_ms: i64,
	playing: bool,
) {
	if !ui.playback_fullscreen_active {return}
	stay_visible := playback_fullscreen_controls_stay_visible(
		playing,
		ui.source_scrubbing,
		contains(playback_fullscreen_transport_rect(), ui.mouse),
		playback_fullscreen_input_scope_active() ||
			ui.source_hint_menu_open,
	)
	if stay_visible {
		if !ui.playback_fullscreen_controls_visible {
			playback_fullscreen_show_controls(now_ms)
		}
		return
	}
	if ui.playback_fullscreen_controls_visible &&
	   now_ms >= ui.playback_fullscreen_controls_deadline_ms {
		playback_fullscreen_hide_controls()
	}
}

playback_fullscreen_timestamp_second_for_time :: proc(seconds: f64) -> i64 {
	return i64(max(0, seconds))
}

playback_fullscreen_timestamp_needs_redraw :: proc(
	active,
	controls_visible,
	has_seconds: bool,
	seconds: f64,
	current_second: i64,
) -> bool {
	return active &&
	       controls_visible &&
	       has_seconds &&
	       playback_fullscreen_timestamp_second_for_time(seconds) !=
	       current_second
}

playback_fullscreen_refresh_timestamp :: proc() {
	seconds, has_seconds := current_seconds()
	if !playback_fullscreen_timestamp_needs_redraw(
		ui.playback_fullscreen_active,
		ui.playback_fullscreen_controls_visible,
		has_seconds,
		seconds,
		ui.playback_fullscreen_timestamp_second,
	) {
		return
	}
	ui.playback_fullscreen_timestamp_second =
		playback_fullscreen_timestamp_second_for_time(seconds)
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
	return UI_Rect{modal.x + 24, modal.y + modal.h - 218 - height, modal.w - 48, height}
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
	top := input.y - 8 - f64(min(len(source_local_paths), 4))*32
	for previous_index in 0 ..< index {
		top -= source_probe_row_height(previous_index) + 6
	}
	height := source_probe_row_height(index)
	return UI_Rect{modal.x + 24, top - height, modal.w - 48, height}
}

source_local_row_rect :: proc(modal: UI_Rect, index: int) -> UI_Rect {
	drop := source_local_drop_rect(modal)
	return UI_Rect{drop.x, drop.y - 36 - f64(index)*36, drop.w, 32}
}

source_local_title_rect :: proc(modal: UI_Rect, index: int) -> UI_Rect {
	row := source_local_row_rect(modal, index)
	return UI_Rect{row.x + row.w*0.42, row.y, row.w*0.58-34, row.h}
}

source_local_remove_rect :: proc(modal: UI_Rect, index: int) -> UI_Rect {
	row := source_local_row_rect(modal, index)
	return UI_Rect{row.x + row.w - 30, row.y, 30, row.h}
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

source_modal_browse_rect :: proc(modal: UI_Rect) -> UI_Rect {
	drop := source_local_drop_rect(modal)
	return UI_Rect{drop.x + drop.w - 196, drop.y + 28, 172, 36}
}

source_local_drop_rect :: proc(modal: UI_Rect) -> UI_Rect {
	return UI_Rect{modal.x + 24, modal.y + modal.h - 310, modal.w - 48, 104}
}

source_modal_mode_rect :: proc(modal: UI_Rect, mode: Source_Add_Mode) -> UI_Rect {
	width := (modal.w - 54) / 2
	x := modal.x + 24
	if mode == .Local_Files {x += width + 6}
	return UI_Rect{x, modal.y + modal.h - 108, width, 30}
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

active_player_has_audio :: proc() -> bool {
	if ui.source_playback_active && state.active_source >= 0 &&
	   state.active_source < len(state.sources) {
		return state.sources[state.active_source].has_audio
	}
	if ui.active_clip >= 0 && ui.active_clip < len(state.clips) {
		source_index := source_index_for_id(
			state.sources[:],
			state.clips[ui.active_clip].source_id,
		)
		if source_index >= 0 {return state.sources[source_index].has_audio}
	}
	return true
}

source_details_row_rect :: proc(modal: UI_Rect, row: int) -> UI_Rect {
	return UI_Rect{modal.x + 24, modal.y + modal.h - 142 - f64(row) * 31, modal.w - 48, 30}
}

clip_rename_modal_rect_for_size :: proc(view_width, view_height: f64) -> UI_Rect {
	width := min(max(560, view_width * 0.52), 720)
	height := min(max(300, view_height * 0.42), 380)
	return UI_Rect{(view_width - width) / 2, (view_height - height) / 2, width, height}
}

clip_rename_modal_rect :: proc() -> UI_Rect {
	return clip_rename_modal_rect_for_size(ui.width, ui.height)
}

clip_rename_input_rect :: proc(modal: UI_Rect) -> UI_Rect {
	return UI_Rect{modal.x + 24, modal.y + 82, modal.w - 48, 36}
}

clip_rename_cancel_rect :: proc(modal: UI_Rect) -> UI_Rect {
	return UI_Rect{modal.x + 24, modal.y + 24, 124, 34}
}

clip_rename_confirm_rect :: proc(modal: UI_Rect) -> UI_Rect {
	return UI_Rect{modal.x + modal.w - 180, modal.y + 24, 156, 34}
}

clip_metadata_modal_rect_for_size :: proc(view_width, view_height: f64) -> UI_Rect {
	width := min(max(620, view_width * 0.58), 780)
	height := min(max(500, view_height * 0.68), 580)
	return UI_Rect{(view_width - width) / 2, (view_height - height) / 2, width, height}
}

clip_metadata_modal_rect :: proc() -> UI_Rect {
	return clip_metadata_modal_rect_for_size(ui.width, ui.height)
}

clip_metadata_row_rect :: proc(modal: UI_Rect, row: int) -> UI_Rect {
	return UI_Rect{modal.x + 24, modal.y + modal.h - 142 - f64(row) * 32, modal.w - 48, 30}
}

clip_metadata_close_rect :: proc(modal: UI_Rect) -> UI_Rect {
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
		modal.y + modal.h - 306 - f64(row) * 30,
		modal.w - 48,
		29,
	}
}

data_modal_rect :: proc() -> UI_Rect {
	width := min(max(560, ui.width * 0.5), 680)
	height := min(max(430, ui.height * 0.52), 500)
	return UI_Rect{(ui.width - width) / 2, (ui.height - height) / 2, width, height}
}

discard_confirm_rect :: proc() -> UI_Rect {
	width := min(460.0, ui.width-48)
	height := 164.0
	return {(ui.width-width)/2, (ui.height-height)/2, width, height}
}

discard_confirm_action_rect :: proc(index: int) -> UI_Rect {
	modal := discard_confirm_rect()
	width := (modal.w-56)/2
	return {modal.x+24+f64(index)*(width+8), modal.y+24, width, 34}
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
	if ui.clip_rename_open {close_clip_rename()}
	if ui.clip_metadata_open {close_clip_metadata()}
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
	return UI_Rect{modal.x + modal.w - 148, modal.y + 22, 124, 34}
}

library_import_confirm_rect :: proc(modal: UI_Rect) -> UI_Rect {
	return UI_Rect{modal.x + 24, modal.y + 22, 206, 34}
}

clip_metadata_source_rect :: proc(modal: UI_Rect) -> UI_Rect {
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
	request_source_metadata(source.video_id, source.media_path, source.workflow)
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
	request_source_metadata(source.video_id, source.media_path, source.workflow)
}

open_clip_rename :: proc() {
	cancel_ui_flash()
	if ui.active_clip < 0 || ui.active_clip >= len(state.clips) {return}
	ui.clip_rename_index = ui.active_clip
	ui.clip_rename_open = true
	ui_set_string(&ui.clip_rename, state.clips[ui.clip_rename_index].name)
	ui.clip_rename_initial_hash = hash.fnv64a(transmute([]byte)ui.clip_rename)
	focus_text_input(.Clip_Rename)
}

close_clip_rename :: proc() {
	cancel_ui_flash()
	ui.clip_rename_open = false
	ui.clip_rename_index = -1
	ui.focus = .None
	text_input.end_pointer_selection(&ui.input_state)
	clear_marked_text()
	ui_set_string(&ui.clip_rename, "")
	ui.clip_rename_initial_hash = 0
	ui.needs_redraw = true
}

confirm_clip_rename :: proc() {
	name := strings.trim_space(ui.clip_rename)
	if len(name) == 0 {
		set_error_status("Enter a name for the clip")
		return
	}
	index := ui.clip_rename_index
	if !rename_clip(index, name) {
		set_error_status("Unable to rename the clip")
		return
	}
	renamed := state.clips[index].name
	close_clip_rename()
	set_success_status(fmt.tprintf("Renamed clip to %s", renamed))
}

open_clip_metadata :: proc() {
	cancel_ui_flash()
	if ui.active_clip < 0 || ui.active_clip >= len(state.clips) {return}
	ui.clip_metadata_index = ui.active_clip
	ui.clip_metadata_open = true
	ui.focus = .None
	text_input.end_pointer_selection(&ui.input_state)
	ui.needs_redraw = true
}

close_clip_metadata :: proc() {
	cancel_ui_flash()
	ui.clip_metadata_open = false
	ui.clip_metadata_index = -1
	ui.needs_redraw = true
}

open_randomize_help :: proc() {
	cancel_ui_flash()
	if ui.clip_rename_open {close_clip_rename()}
	if ui.clip_metadata_open {close_clip_metadata()}
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
		fmt.eprintln("[hw_videoClips] could not persist pitch settings")
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

view_clip_source :: proc() {
	if ui.clip_metadata_index < 0 ||
	   ui.clip_metadata_index >= len(state.clips) {
		return
	}
	source_index := source_index_for_clip(
		state.sources[:],
		state.clips[:],
		ui.clip_metadata_index,
	)
	if source_index < 0 {
		set_error_status("The clip source is no longer in the source register")
		return
	}
	set_ui_mode(.Create)
	ui_event_tag = source_index
	on_select_source(nil, nil, nil)
}

open_source_modal :: proc() {
	if !flush_active_clip_draft() {return}
	cancel_ui_flash()
	if ui.source_details_open {close_source_details()}
	ui.source_modal_refetch_index = -1
	ui.source_add_mode = .URL
	ui.local_source_title_index = -1
	ui.source_modal_open = true
	ui.save_source_browser_choice = false
	ui.source_modal_initial_hash = hash.fnv64a(transmute([]byte)ui.url_input)
	focus_text_input(.URL)
	ui.needs_redraw = true
	if len(strings.trim_space(ui.url_input)) > 0 && len(source_probe_results) == 0 {schedule_source_probe(1)}
}

source_paste_url_lines :: proc(
	text: string,
	allocator := context.temp_allocator,
) -> ([dynamic]string, bool) {
	urls := make([dynamic]string, allocator)
	remaining := text
	for raw_line in strings.split_lines_iterator(&remaining) {
		line := strings.trim_space(raw_line)
		if len(line) == 0 {continue}
		if _, valid := parse_video_id(line); !valid {return urls, false}
		append(&urls, line)
	}
	return urls, len(urls) > 0
}

merge_source_paste_urls :: proc(
	current: string,
	incoming: []string,
	append_current: bool,
	allocator := context.temp_allocator,
) -> string {
	builder: strings.Builder
	strings.builder_init(&builder, allocator)
	seen := make([dynamic]string, allocator)
	has_output := false
	if append_current {
		existing := strings.trim_space(current)
		if len(existing) > 0 {
			strings.write_string(&builder, existing)
			has_output = true
			remaining := existing
			for raw_line in strings.split_lines_iterator(&remaining) {
				line := strings.trim_space(raw_line)
				if len(line) > 0 {append(&seen, line)}
			}
		}
	}
	for line in incoming {
		duplicate := false
		for existing in seen {
			if existing == line {
				duplicate = true
				break
			}
		}
		if duplicate {continue}
		if has_output {strings.write_string(&builder, "\n")}
		strings.write_string(&builder, line)
		append(&seen, line)
		has_output = true
	}
	return strings.to_string(builder)
}

source_paste_dismiss_transient_ui :: proc(preserve_add_modal: bool) {
	if ui.shortcut_open {video_clips_shortcut_recorder_close()}
	if ui.settings_open {video_clips_settings_close()}
	if command_palette.is_open(&command_palette_state) {
		close_command_palette(false)
	}
	cancel_ui_flash()
	clear_number_prefix()
	if ui.source_modal_open &&
	   (!preserve_add_modal || ui.source_modal_refetch_index >= 0) {
		close_source_modal()
	}
	if ui.source_details_open {close_source_details()}
	if ui.clip_rename_open {close_clip_rename()}
	if ui.clip_metadata_open {close_clip_metadata()}
	if ui.randomize_help_open {close_randomize_help()}
	if ui.pitch.help_open {close_pitch_help()}
	if ui.data_modal_open {close_data_modal()}
	if ui.notification_modal_open {close_notification_history()}
}

source_paste_media_job_blocks :: proc() -> bool {
	return source_import_media_job_blocks()
}

handle_global_source_paste :: proc(text: string) -> Source_Paste_Result {
	urls, recognized := source_paste_url_lines(text)
	if !recognized {return .Not_YouTube}
	if global_modal_blocks_commands() || ui.library_import_confirm_open {
		return .Blocked
	}
	if source_paste_media_job_blocks() {
		set_error_status(
			"Wait for the active import, preview, repair, or recovery to finish before adding another source",
		)
		return .Blocked
	}
	if !flush_active_clip_draft() {return .Blocked}
	append_current :=
		ui.mode == .Create &&
		ui.source_modal_open &&
		ui.source_modal_refetch_index < 0
	source_paste_dismiss_transient_ui(append_current)
	if ui.mode != .Create {
		set_ui_mode(.Create)
		if ui.mode != .Create {return .Blocked}
	}
	updated := merge_source_paste_urls(
		ui.url_input,
		urls[:],
		append_current,
	)
	if updated != ui.url_input {
		ui_set_string(&ui.url_input, updated)
		source_probe_results_clear()
		schedule_source_probe(1)
	}
	if !ui.source_modal_open {open_source_modal()} else {focus_text_input(.URL)}
	ui.source_add_mode = .URL
	collapse_text_selection(len(ui.url_input))
	ui.needs_redraw = true
	return .Opened
}

open_refetch_source_modal :: proc(source_index: int) {
	if !flush_active_clip_draft() {return}
	cancel_ui_flash()
	if source_index < 0 || source_index >= len(state.sources) {return}
	if ui.source_details_open {close_source_details()}
	ui.source_modal_refetch_index = source_index
	ui.source_add_mode = .URL
	ui.source_modal_open = true
	ui.save_source_browser_choice = false
	ui.focus = .None
	text_input.end_pointer_selection(&ui.input_state)
	ui_set_string(&ui.url_input, state.sources[source_index].url)
	ui.source_modal_initial_hash = hash.fnv64a(transmute([]byte)ui.url_input)
	source_probe_results_clear()
	schedule_source_probe(1)
	ui.needs_redraw = true
}

close_source_modal :: proc() {
	cancel_ui_flash()
	ui.source_modal_open = false
	ui.source_modal_refetch_index = -1
	ui.local_source_title_index = -1
	ui.save_source_browser_choice = false
	ui.focus = .None
	text_input.end_pointer_selection(&ui.input_state)
	clear_marked_text()
	ui.source_modal_initial_hash = 0
	source_local_paths_clear()
	ui.needs_redraw = true
}

modal_discard_target_dirty :: proc(target: Modal_Discard_Target) -> bool {
	switch target {
	case .Shortcut:
		return ui.shortcut_candidate_valid
	case .Source:
		return hash.fnv64a(transmute([]byte)ui.url_input) !=
		         ui.source_modal_initial_hash ||
		       ui.save_source_browser_choice ||
		       len(source_local_paths) > 0
	case .Clip_Rename:
		return hash.fnv64a(transmute([]byte)ui.clip_rename) !=
		       ui.clip_rename_initial_hash
	case .None:
	}
	return false
}

close_modal_discard_target :: proc(target: Modal_Discard_Target) {
	switch target {
	case .Shortcut: video_clips_shortcut_recorder_close()
	case .Source: close_source_modal()
	case .Clip_Rename: close_clip_rename()
	case .None:
	}
}

request_modal_discard :: proc(target: Modal_Discard_Target) {
	if modal_discard_target_dirty(target) {
		ui.discard_confirm_open = true
		ui.discard_target = target
		cancel_ui_flash()
		ui.needs_redraw = true
		return
	}
	close_modal_discard_target(target)
}

close_discard_confirmation :: proc() {
	ui.discard_confirm_open = false
	ui.discard_target = .None
	ui.needs_redraw = true
}

confirm_modal_discard :: proc() {
	target := ui.discard_target
	close_discard_confirmation()
	close_modal_discard_target(target)
}

schedule_source_probe :: proc(delay_frames: uint) {
	ui.url_probe_pending = true
	ui.url_probe_due_tick = ui.frame_tick + delay_frames
}

persist_active_view_preference :: proc() {
	if library_database == nil {return}
	if !database_active_view_save(
		library_database,
		{workflow = ui.workflow, mode = ui.mode},
	) {
		set_error_status("The current workflow and workspace could not be saved")
	}
}

remember_list_selection :: proc(mode: UI_Mode, record_id: string) {
	workflow_index := int(ui.workflow)
	if workflow_index < 0 || workflow_index >= WORKFLOW_COUNT {return}
	if mode == .Create {
		ui_set_string(&ui.source_selection_ids[workflow_index], record_id)
		ui.source_selection_saved[workflow_index] = true
	} else {
		ui_set_string(&ui.clip_selection_ids[workflow_index], record_id)
		ui.clip_selection_saved[workflow_index] = true
	}
	if library_database != nil &&
	   !database_list_selection_save(
		library_database,
		ui.workflow,
		mode,
		record_id,
	) {
		set_error_status("The list selection could not be saved")
	}
}

restore_source_selection :: proc() {
	workflow_index := int(ui.workflow)
	state.active_source = -1
	if workflow_index < 0 || workflow_index >= WORKFLOW_COUNT {return}
	id := ui.source_selection_ids[workflow_index]
	if ui.source_selection_saved[workflow_index] {
		if len(id) == 0 {load_clip_draft_for_source(-1); return}
		index := source_index_for_id(state.sources[:], id)
		if index < 0 || state.sources[index].workflow != ui.workflow {
			remember_list_selection(.Create, "")
			load_clip_draft_for_source(-1)
			return
		}
		_ = load_source_player(index)
		return
	}
	if index := last_source_index_for_workflow(ui.workflow); index >= 0 {
		_ = load_source_player(index)
	} else {
		load_clip_draft_for_source(-1)
	}
}

restore_clip_selection :: proc() {
	workflow_index := int(ui.workflow)
	ui.active_clip = -1
	if workflow_index < 0 || workflow_index >= WORKFLOW_COUNT {return}
	id := ui.clip_selection_ids[workflow_index]
	if !ui.clip_selection_saved[workflow_index] || len(id) == 0 {return}
	index := clip_index_for_id(state.clips[:], id)
	if index < 0 || state.clips[index].workflow != ui.workflow {
		remember_list_selection(.Play, "")
		return
	}
	clip := &state.clips[index]
	ui.playback_rate = (
		clip.workflow == .Vocal ?
		ui.vocal_playback_rate :
		clamp_playback_rate(clip.dance_playback_rate)
	)
	ui.active_clip = index
	source_index := source_index_for_id(state.sources[:], clip.source_id)
	has_audio := source_index < 0 || state.sources[source_index].has_audio
	if !os.exists(clip.clip_path) || !metal_player_load(clip.clip_path, has_audio) {return}
	ui.player_duration = clip.end_seconds - clip.start_seconds
	set_source_playback_active(false)
	stop_player_playback()
}

ensure_active_list_selection_visible :: proc() {
	_, _, source_search, source_panel, _, _, clip_search, clip_panel, clip_name, _, _ :=
		layout_rects()
	if ui.mode == .Create && state.active_source >= 0 {
		visible_index := 0
		for source, index in state.sources {
			if source.workflow != ui.workflow ||
			   !source_matches_search(source, ui.source_search) {
				continue
			}
			if index == state.active_source {
				content := source_content_rect(source_search, source_panel)
				ui.source_scroll = bounded_scroll(
					f64(visible_index)*30-content.h/2+14.5,
					0,
					filtered_source_count(),
					29,
					30,
					content.h,
				)
				return
			}
			visible_index += 1
		}
	} else if ui.mode == .Play && ui.active_clip >= 0 {
		visible_index := 0
		for clip, index in state.clips {
			if clip.workflow != ui.workflow ||
			   !clip_matches_filter(clip, ui.clip_search) {
				continue
			}
			if index == ui.active_clip {
				content := clip_content_rect(clip_search, clip_panel, clip_name)
				ui.clip_scroll = bounded_scroll(
					f64(visible_index)*30-content.h/2+14.5,
					0,
					filtered_clip_count(),
					29,
					30,
					content.h,
				)
				return
			}
			visible_index += 1
		}
	}
}

set_ui_mode :: proc(mode: UI_Mode, persist := true) {
	if ui.mode == mode {return}
	if !flush_active_clip_draft() {return}
	cancel_ui_flash()
	clear_number_prefix()
	if ui.source_modal_open {close_source_modal()}
	if ui.source_details_open {close_source_details()}
	if ui.clip_rename_open {close_clip_rename()}
	if ui.clip_metadata_open {close_clip_metadata()}
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
	}
	ui.mode = mode
	if mode == .Create {restore_source_selection()} else {restore_clip_selection()}
	ui.focus = .None
	text_input.end_pointer_selection(&ui.input_state)
	clear_marked_text()
	normalize_scroll_offsets()
	ensure_active_list_selection_visible()
	ui.needs_redraw = true
	if persist {persist_active_view_preference()}
}

last_source_index_for_workflow :: proc(workflow: Workflow_Kind) -> int {
	for index := len(state.sources)-1; index >= 0; index -= 1 {
		if state.sources[index].workflow == workflow {return index}
	}
	return -1
}

set_ui_workflow :: proc(workflow: Workflow_Kind, persist := true) {
	if ui.workflow == workflow {return}
	if !flush_active_clip_draft() {return}
	cancel_ui_flash()
	clear_number_prefix()
	if ui.source_modal_open {close_source_modal()}
	if ui.source_details_open {close_source_details()}
	if ui.clip_rename_open {close_clip_rename()}
	if ui.clip_metadata_open {close_clip_metadata()}
	if ui.randomize_help_open {close_randomize_help()}
	if ui.pitch.help_open {close_pitch_help()}
	if ui.data_modal_open {close_data_modal()}
	if ui.notification_modal_open {close_notification_history()}
	pitch_monitor_stop(&ui.pitch)
	metal_player_clear()
	ui.workflow = workflow
	ui.source_scroll = 0
	ui.transcript_scroll = 0
	ui.clip_scroll = 0
	ui_set_string(&ui.source_search, "")
	ui_set_string(&ui.transcript_search, "")
	ui_set_string(&ui.clip_search, "")
	ui.playback_rate = workflow == .Vocal ? ui.vocal_playback_rate : 1
	if ui.mode == .Create {restore_source_selection()} else {restore_clip_selection()}
	ui.focus = .None
	text_input.end_pointer_selection(&ui.input_state)
	clear_marked_text()
	normalize_scroll_offsets()
	ensure_active_list_selection_visible()
	ui.needs_redraw = true
	if persist {persist_active_view_preference()}
}

layout_rects :: proc(
) -> (
	import_field,
	import_button,
	source_search,
	source_panel,
	player,
	transcript,
	clip_search,
	clip_panel,
	clip_name,
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
		browse := ui_control_rect(.Browse_Source_Files)
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
		clip_name = UI_Rect{right_x + 8, body_top - 72, right_w - 16, 30}
		clip_panel = UI_Rect{right_x, body_y, right_w, body_h}
		player_h := max(180, body_h * 0.55)
		player = UI_Rect{center_x, body_top - player_h, center_w, player_h}
		transcript = UI_Rect{center_x, body_y, center_w, max(80, body_h - player_h - gap)}
	} else {
		available_w := w - margin * 2 - gap * 2
		if ui.workflow == .Vocal {
			left_w = available_w * 0.40
			pitch_w := available_w - left_w
			right_x := margin + left_w + gap
			list_h := (body_h - gap) / 2
			clip_panel = UI_Rect{margin, body_y, left_w, list_h}
			clip_search = UI_Rect{margin + 8, clip_panel.y + list_h - 71, left_w - 16, 28}
			player = UI_Rect{margin, body_y + list_h + gap, left_w, body_h - list_h - gap}
			pitch_panel = UI_Rect{right_x, body_y, pitch_w, body_h}
		} else {
			left_w = available_w * 0.20
			center_w = available_w * 0.60
			pitch_w := available_w - left_w - center_w
			center_x := margin + left_w + gap
			right_x := center_x + center_w + gap
			clip_search = UI_Rect{margin + 8, body_top - 72, left_w - 16, 28}
			clip_panel = UI_Rect{margin, body_y, left_w, body_h}
			player = UI_Rect{center_x, body_y, center_w, body_h}
			pitch_panel = UI_Rect{right_x, body_y, pitch_w, body_h}
		}
	}
	controls = UI_Rect{margin, 42, w - margin * 2, 28}
	return
}

control_slot_count :: proc(mode: UI_Mode) -> int {
	if mode == .Create {return 9}
	return ui.workflow == .Vocal ? 11 : 14
}

control_action_for_slot :: proc(mode: UI_Mode, slot: int) -> int {
	if mode == .Create {
		switch slot {
		case 0: return 5
		case 1: return 7
		case 2: return 3
		case 3: return 4
		case 4: return 6
		case 5: return PLAYBACK_FULLSCREEN_ACTION_INDEX
		case 6: return 0
		case 7: return 1
		case 8: return 2
		}
		return -1
	}
	switch slot {
	case 0: return 12
	case 1: return 10
	case 2: return 8
	case 3: return 9
	case 4: return 7
	case 5: return 3
	case 6: return 4
	case 7: return 13
	case 8: return 14
	case 9:
		return PLAYBACK_FULLSCREEN_ACTION_INDEX
	case 10:
		if ui.workflow == .Vocal {return PITCH_ACTION_INDEX}
		return DANCE_MIRROR_ACTION_INDEX
	case 11: return DANCE_LOOP_ACTION_INDEX
	case 12: return DANCE_COUNT_IN_ACTION_INDEX
	case 13: return DANCE_COUNT_EACH_LOOP_ACTION_INDEX
	}
	return -1
}

control_slot_for_action :: proc(mode: UI_Mode, action: int) -> int {
	for slot in 0 ..< control_slot_count(mode) {
		if control_action_for_slot(mode, slot) == action {return slot}
	}
	return -1
}

numbered_action_code_for_action :: proc(
	mode: UI_Mode,
	action: int,
) -> (Numbered_Action_Code, bool) {
	if mode == .Create {
		switch action {
		case 5: return {1, 1}, true
		case 7: return {1, 2}, true
		case 3: return {2, 1}, true
		case 4: return {2, 2}, true
		case 6: return {2, 3}, true
		case PLAYBACK_FULLSCREEN_ACTION_INDEX: return {2, 4}, true
		case 0: return {3, 1}, true
		case 1: return {3, 2}, true
		case 2: return {3, 3}, true
		}
		return {}, false
	}
	switch action {
	case 12: return {1, 1}, true
	case 10: return {1, 2}, true
	case 8:  return {1, 3}, true
	case 9:  return {1, 4}, true
	case 7:  return {1, 5}, true
	case 3:  return {2, 1}, true
	case 4:  return {2, 2}, true
	case 13: return {2, 3}, true
	case 14: return {2, 4}, true
	case PLAYBACK_FULLSCREEN_ACTION_INDEX: return {2, 5}, true
	case PITCH_ACTION_INDEX: return {3, 1}, true
	case DANCE_MIRROR_ACTION_INDEX: return {3, 1}, true
	case DANCE_LOOP_ACTION_INDEX: return {3, 2}, true
	case DANCE_COUNT_IN_ACTION_INDEX: return {3, 3}, true
	case DANCE_COUNT_EACH_LOOP_ACTION_INDEX: return {3, 4}, true
	}
	return {}, false
}

pitch_numbered_action_text :: proc() -> string {
	code, found := numbered_action_code_for_action(
		.Play,
		PITCH_ACTION_INDEX,
	)
	if !found {return ""}
	return fmt.tprintf("%d%d", code.section, code.action)
}

numbered_action_for_code :: proc(
	mode: UI_Mode,
	section, action_digit: int,
) -> int {
	for slot in 0 ..< control_slot_count(mode) {
		action := control_action_for_slot(mode, slot)
		code, found := numbered_action_code_for_action(mode, action)
		if found && code.section == section && code.action == action_digit {
			return action
		}
	}
	return -1
}

numbered_action_section_exists :: proc(mode: UI_Mode, section: int) -> bool {
	for slot in 0 ..< control_slot_count(mode) {
		action := control_action_for_slot(mode, slot)
		code, found := numbered_action_code_for_action(mode, action)
		if found && code.section == section {return true}
	}
	return false
}

numbered_action_time_ms :: proc() -> i64 {
	return time.to_unix_nanoseconds(time.now()) / 1_000_000
}

clear_number_prefix :: proc() {
	ui.number_prefix = 0
	ui.number_prefix_deadline_ms = 0
}

expire_number_prefix_at :: proc(now_ms: i64) -> bool {
	if ui.number_prefix == 0 || now_ms < ui.number_prefix_deadline_ms {
		return false
	}
	clear_number_prefix()
	ui.needs_redraw = true
	return true
}

consume_numbered_action_digit_at :: proc(
	mode: UI_Mode,
	digit: int,
	now_ms: i64,
) -> (action: int, handled: bool) {
	_ = expire_number_prefix_at(now_ms)
	if ui.number_prefix == 0 {
		if !numbered_action_section_exists(mode, digit) {return -1, false}
		ui.number_prefix = digit
		ui.number_prefix_deadline_ms = now_ms + 1_000
		ui.needs_redraw = true
		return -1, true
	}
	section := ui.number_prefix
	clear_number_prefix()
	ui.needs_redraw = true
	return numbered_action_for_code(mode, section, digit), true
}

number_digit_for_key_code :: proc(key_code: uint) -> (int, bool) {
	key_codes := [9]uint{18, 19, 20, 21, 23, 22, 26, 28, 25}
	for candidate, index in key_codes {
		if candidate == key_code {return index + 1, true}
	}
	return 0, false
}

Shortcut_Digit_Route :: enum {
	Capture,
	Save,
	Reset,
	Cancel,
}

shortcut_digit_route :: proc(digit: int) -> Shortcut_Digit_Route {
	switch digit {
	case 1: return .Save
	case 2: return .Reset
	case 3: return .Cancel
	case:   return .Capture
	}
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

playback_fullscreen_shortcut_matches :: proc(
	text: string,
	modifiers: uint,
) -> bool {
	relevant :=
		NSEventModifierFlagShift |
		NSEventModifierFlagControl |
		NSEventModifierFlagOption |
		NSEventModifierFlagCommand
	return modifiers&relevant == 0 &&
	       len(text) == 1 &&
	       (text[0] == 'f' || text[0] == 'F')
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

event_opens_settings :: proc(event: Id, modifiers: uint) -> bool {
	required := NSEventModifierFlagCommand
	relevant :=
		NSEventModifierFlagShift |
		NSEventModifierFlagControl |
		NSEventModifierFlagOption |
		NSEventModifierFlagCommand
	if modifiers & relevant != required {return false}
	characters := msg_id(
		event,
		sel_registerName("charactersIgnoringModifiers"),
	)
	text, ok := text_input_string(characters)
	return ok && text == ","
}

flash_leader_allowed :: proc(
	focus: UI_Focus,
	key_code: uint,
	modifiers: uint,
	text: string,
) -> bool {
	return focus == .None &&
	       video_clips_shortcut_matches_event(
			ui.flash_leader,
			key_code,
			text,
			modifiers,
	       )
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
	count := control_slot_count(ui.mode)
	inside_gap := 4.0
	section_gap := 12.0
	total_gap := 0.0
	for gap_index in 0 ..< count-1 {
		left := control_action_for_slot(ui.mode, gap_index)
		right := control_action_for_slot(ui.mode, gap_index+1)
		left_code, left_found := numbered_action_code_for_action(ui.mode, left)
		right_code, right_found := numbered_action_code_for_action(ui.mode, right)
		if left_found && right_found && left_code.section != right_code.section {
			total_gap += section_gap
		} else {
			total_gap += inside_gap
		}
	}
	cell_w := (controls.w-total_gap)/f64(count)
	x := controls.x
	for gap_index in 0 ..< slot {
		left := control_action_for_slot(ui.mode, gap_index)
		right := control_action_for_slot(ui.mode, gap_index+1)
		left_code, left_found := numbered_action_code_for_action(ui.mode, left)
		right_code, right_found := numbered_action_code_for_action(ui.mode, right)
		gap := inside_gap
		if left_found && right_found && left_code.section != right_code.section {
			gap = section_gap
		}
		x += cell_w+gap
	}
	if slot == count-1 {x = controls.x+controls.w-cell_w}
	return UI_Rect{x, controls.y, cell_w, controls.h}
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

dance_content_rect :: proc(panel: UI_Rect) -> UI_Rect {
	return UI_Rect{panel.x + 12, panel.y + 12, panel.w - 24, panel.h - 58}
}

dance_bpm_down_rect :: proc(panel: UI_Rect) -> UI_Rect {
	content := dance_content_rect(panel)
	return UI_Rect{
		content.x,
		content.y + content.h - 228,
		34,
		30,
	}
}

dance_bpm_value_rect :: proc(panel: UI_Rect) -> UI_Rect {
	down := dance_bpm_down_rect(panel)
	return UI_Rect{down.x + down.w + 4, down.y, 72, down.h}
}

dance_bpm_up_rect :: proc(panel: UI_Rect) -> UI_Rect {
	value := dance_bpm_value_rect(panel)
	return UI_Rect{value.x + value.w + 4, value.y, 34, value.h}
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

pitch_octaves_rect :: proc(panel: UI_Rect, part: int) -> UI_Rect {
	settings := pitch_settings_rect(panel)
	y := settings.y + settings.h - 104
	widths := [3]f64{32, settings.w - 64, 32}
	x := settings.x
	for index in 0 ..< part {x += widths[index]}
	return UI_Rect{x, y, widths[part], 26}
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
	bottom_metadata_height := player_transport_layout(player).footer_height
	header_height := 35.0
	return UI_Rect {
		player.x + 1,
		player.y + bottom_metadata_height,
		max(0, player.w - 2),
		max(0, player.h - bottom_metadata_height - header_height - 1),
	}
}

PLAYER_TRANSPORT_INSET_X :: 10.0
PLAYER_TRANSPORT_ROW_PITCH :: 32.0
PLAYER_TRANSPORT_ONE_ROW_WIDTH :: 776.0
PLAYER_TRANSPORT_TWO_ROW_WIDTH :: 484.0
PLAYER_TRANSPORT_MINIMUM_WIDTH :: 284.0

player_transport_layout :: proc(player: UI_Rect) -> (result: Player_Transport_Layout) {
	inner_x := player.x + PLAYER_TRANSPORT_INSET_X
	inner_w := max(0, player.w - PLAYER_TRANSPORT_INSET_X*2)
	result.row_count = 1
	if inner_w < PLAYER_TRANSPORT_ONE_ROW_WIDTH {
		result.row_count = 2
	}
	if inner_w < PLAYER_TRANSPORT_TWO_ROW_WIDTH {
		result.row_count = 3
	}

	when ODIN_DEBUG {
		assert(
			inner_w >= PLAYER_TRANSPORT_MINIMUM_WIDTH,
			"player transport cannot fit its narrowest semantic row",
		)
	}

	transport_x := inner_x
	speed_x := inner_x
	volume_x := inner_x
	status_x := inner_x
	transport_y := player.y
	speed_y := player.y
	volume_y := player.y
	status_y := player.y

	switch result.row_count {
	case 1:
		speed_x = inner_x + 226
		volume_x = inner_x + 366
		status_x = inner_x + 492
	case 2:
		transport_y = player.y + PLAYER_TRANSPORT_ROW_PITCH
		speed_y = transport_y
		volume_y = transport_y
		speed_x = inner_x + 226
		volume_x = inner_x + 366
	case 3:
		transport_y = player.y + PLAYER_TRANSPORT_ROW_PITCH*2
		speed_y = player.y + PLAYER_TRANSPORT_ROW_PITCH
		volume_y = speed_y
		volume_x = inner_x + 140
	}

	result.play_pause = {transport_x, transport_y+3, 62, 24}
	result.stop = {transport_x+68, transport_y+3, 48, 24}
	result.reset = {transport_x+122, transport_y+3, 92, 24}
	result.speed_down = {speed_x, speed_y+3, 24, 24}
	result.speed_value = {speed_x+28, speed_y, 76, 30}
	result.speed_up = {speed_x+108, speed_y+3, 24, 24}
	result.volume_down = {volume_x, volume_y+3, 24, 24}
	result.volume_value = {volume_x+28, volume_y, 62, 30}
	result.volume_up = {volume_x+94, volume_y+3, 24, 24}
	result.timestamp = {status_x, status_y, 140, 30}
	result.ready_status = {status_x+152, status_y, 100, 30}
	result.fullscreen = {inner_x+inner_w-24, status_y+3, 24, 24}
	result.timeline = {
		inner_x,
		player.y+f64(result.row_count)*PLAYER_TRANSPORT_ROW_PITCH+6,
		inner_w,
		18,
	}
	result.footer_height = f64(result.row_count+1)*PLAYER_TRANSPORT_ROW_PITCH
	return
}

source_timestamp_rect :: proc(player: UI_Rect) -> UI_Rect {
	return player_transport_layout(player).timestamp
}

source_volume_up_rect :: proc(player: UI_Rect) -> UI_Rect {
	return player_transport_layout(player).volume_up
}

source_volume_value_rect :: proc(player: UI_Rect) -> UI_Rect {
	return player_transport_layout(player).volume_value
}

source_volume_down_rect :: proc(player: UI_Rect) -> UI_Rect {
	return player_transport_layout(player).volume_down
}

source_play_pause_rect :: proc(player: UI_Rect) -> UI_Rect {
	return player_transport_layout(player).play_pause
}

source_stop_rect :: proc(player: UI_Rect) -> UI_Rect {
	return player_transport_layout(player).stop
}

source_reset_rect :: proc(player: UI_Rect) -> UI_Rect {
	return player_transport_layout(player).reset
}

source_hint_option_rect :: proc(player: UI_Rect, option_index, option_count: int) -> UI_Rect {
	button := player_transport_layout(player).reset
	return UI_Rect{button.x, button.y + button.h + 34 + f64(option_count - option_index - 1) * 28, button.w, 27}
}

source_speed_down_rect :: proc(player: UI_Rect) -> UI_Rect {
	return player_transport_layout(player).speed_down
}

source_speed_value_rect :: proc(player: UI_Rect) -> UI_Rect {
	return player_transport_layout(player).speed_value
}

source_speed_up_rect :: proc(player: UI_Rect) -> UI_Rect {
	return player_transport_layout(player).speed_up
}

source_timeline_rect :: proc(player: UI_Rect) -> UI_Rect {
	return player_transport_layout(player).timeline
}

player_timeline_seconds :: proc(point: Point, player: UI_Rect) -> f64 {
	timeline := player_transport_layout(player).timeline
	return timeline_seconds_at_point(point, timeline, ui.player_duration)
}

timeline_seconds_at_point :: proc(point: Point, timeline: UI_Rect, duration: f64) -> f64 {
	if timeline.w <= 0 {return 0}
	ratio := min(max((point.x - timeline.x) / timeline.w, 0), 1)
	return ratio * max(0, duration)
}

playback_timeline_progress :: proc(seconds, duration: f64) -> f64 {
	if duration <= 0 {return 0}
	return min(max(seconds/duration, 0), 1)
}

playback_timeline_geometry :: proc(
	timeline: UI_Rect,
	progress: f64,
) -> (completed, thumb: UI_Rect) {
	normalized := min(max(progress, 0), 1)
	track := UI_Rect{
		timeline.x,
		timeline.y+timeline.h/2-2,
		timeline.w,
		4,
	}
	completed = {
		track.x,
		track.y,
		track.w*normalized,
		track.h,
	}
	thumb_x := track.x+track.w*normalized
	thumb = {thumb_x-3, timeline.y+2, 6, timeline.h-4}
	return
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

player_volume_gain :: proc(value: f32) -> f32 {
	level := clamp_volume(value)
	return level * level
}

volume_percent :: proc(value: f32) -> int {
	return int(clamp_volume(value) * 100 + 0.5)
}

adjust_player_volume :: proc(delta: f32) {
	ui.player_volume = clamp_volume(ui.player_volume + delta)
	if ui.audio_player != nil {
		msg_void_f32(
			ui.audio_player,
			sel_registerName("setVolume:"),
			player_volume_gain(ui.player_volume),
		)
	}
	ui.needs_redraw = true
}

clamp_playback_rate :: proc(value: f32) -> f32 {
	return min(max(value, 0.1), 2)
}

active_dance_clip :: proc() -> ^Clip {
	if ui.workflow != .Dancing ||
	   ui.mode != .Play ||
	   ui.active_clip < 0 ||
	   ui.active_clip >= len(state.clips) ||
	   state.clips[ui.active_clip].workflow != .Dancing {
		return nil
	}
	return &state.clips[ui.active_clip]
}

active_dance_clip_mirrored :: proc() -> bool {
	clip := active_dance_clip()
	return clip != nil && clip.dance_mirrored
}

active_dance_clip_looping :: proc() -> bool {
	clip := active_dance_clip()
	return clip != nil && clip.dance_loop
}

active_dance_clip_counts_each_loop :: proc() -> bool {
	clip := active_dance_clip()
	return clip != nil && clip.dance_count_each_loop
}

dance_count_in_action_label :: proc() -> string {
	clip := active_dance_clip()
	if clip == nil || clip.dance_count_in_beats == 0 {
		return "COUNT-IN OFF"
	}
	return fmt.tprintf("COUNT-IN %d", clip.dance_count_in_beats)
}

save_active_dance_clip :: proc() -> bool {
	if active_dance_clip() == nil {return false}
	if save_library() {return true}
	set_error_status("Unable to save the Dancing clip settings")
	return false
}

adjust_playback_rate :: proc(delta: f32) {
	audio_seconds, has_audio_time := metal_audio_current_seconds()
	value := clamp_playback_rate(ui.playback_rate + delta)
	ui.playback_rate = f32(int(value * 10 + 0.5)) / 10
	if ui.workflow == .Vocal {
		ui.vocal_playback_rate = ui.playback_rate
		if !database_vocal_playback_rate_save(
			library_database,
			ui.vocal_playback_rate,
		) {
			set_error_status("Unable to save the Vocal playback speed")
		}
	} else if !ui.source_playback_active &&
	          ui.active_clip >= 0 &&
	          ui.active_clip < len(state.clips) &&
	          state.clips[ui.active_clip].workflow == .Dancing {
		state.clips[ui.active_clip].dance_playback_rate = ui.playback_rate
		if !save_library() {
			set_error_status("Unable to save the Dancing clip speed")
		}
	}
	if ui.audio_pitch != nil {
		msg_void_f32(ui.audio_pitch, sel_registerName("setRate:"), ui.playback_rate)
	}
	if state.player != nil && msg_f32(state.player, sel_registerName("rate")) > 0 {
		if has_audio_time {seek_video_seconds(audio_seconds)}
		msg_void_f32(state.player, sel_registerName("setRate:"), ui.playback_rate)
	}
	ui.needs_redraw = true
}

clip_content_rect :: proc(clip_search, clip_panel, clip_name: UI_Rect) -> UI_Rect {
	bottom := clip_panel.y + 8
	if clip_name.h > 0 {bottom = clip_name.y + clip_name.h + 8}
	top := clip_search.y - 8
	if clip_search.h <= 0 {top = clip_panel.y + clip_panel.h - 43}
	return UI_Rect{clip_panel.x + 6, bottom, clip_panel.w - 12, max(0, top - bottom)}
}

clip_output_commit_rect :: proc(clip_name: UI_Rect) -> UI_Rect {
	return UI_Rect{clip_name.x, clip_name.y - 36, clip_name.w, 28}
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
	if source.workflow != ui.workflow {return false}
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

filtered_clip_count :: proc() -> int {
	return filtered_clip_count_for(
		state.clips[:],
		ui.clip_search,
	)
}

normalize_scroll_offsets :: proc() {
	_, _, source_search, source_panel, _, transcript, clip_search, clip_panel, clip_name, _, _ :=
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
		clip_content := clip_content_rect(clip_search, clip_panel, clip_name)
		ui.clip_scroll = bounded_scroll(
			ui.clip_scroll,
			0,
			filtered_clip_count(),
			29,
			30,
			clip_content.h,
		)
	}
}

push_rect :: proc(
	vertices: ^[dynamic]Solid_Vertex,
	rect: UI_Rect,
	color: [4]f32,
	pipeline := "solid",
) {
	if rect.w <= 0 || rect.h <= 0 || ui.width <= 0 || ui.height <= 0 {return}
	ui_render_trace_record_solid_rect(rect, color, pipeline)
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

make_text_run :: proc(
	font: rawptr,
	text: string,
	tracking := TEXT_STYLE_BODY.tracking,
) -> Text_Run {
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
	CFAttributedStringReplaceString(attributed, CF.Range{0, 0}, string_ref)
	range := CF.Range{0, CF.Index(CFStringGetLength(string_ref))}
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
	if tracking != 0 {
		tracking_value := tracking * ui.scale
		tracking_number := CFNumberCreate(nil, 13, &tracking_value)
		if tracking_number != nil {
			CFAttributedStringSetAttribute(attributed, range, kCTKernAttributeName, tracking_number)
			CFRelease(tracking_number)
		}
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

truncated_text_run :: proc(
	run: Text_Run,
	font: rawptr,
	max_width: f64,
	tracking := TEXT_STYLE_BODY.tracking,
) -> Text_Run {
	if run.line == nil {return {}}
	if run.advance <= max_width {
		result := run
		result.line = foreign_retain(run.line, "CTLine", "truncated_text_run")
		return result
	}
	token := make_text_run(font, "…", tracking)
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
	if ordered_overlay_active {
		framework_coretext.emit_native_line(
			&ordered_text,
			&ordered_draw,
			run.line,
			{f32(origin.x/ui.scale), f32(origin.y/ui.scale)},
			ordered_color(color),
		)
		return
	}
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
	tracking := TEXT_STYLE_BODY.tracking,
) {
	if ctx == nil || rect.w <= 0 || rect.h <= 0 || len(text) == 0 {return}
	ui_render_trace_record_text(text, rect, color)
	run := make_text_run(font, text, tracking)
	defer delete_text_run(&run)
	available_width := max(0, (rect.w - inset * 2) * ui.scale)
	draw_run := run
	truncated: Text_Run
	if run.advance > available_width {
		truncated = truncated_text_run(run, font, available_width, tracking)
		if truncated.line == nil {return}
		draw_run = truncated
	}
	if ordered_overlay_active {
		if clip {framework_draw.push_clip(&ordered_draw, ordered_rect(rect))}
		draw_text_run(ctx, draw_run, text_origin(rect, draw_run, horizontal, vertical, inset), color)
		if clip {framework_draw.pop_clip(&ordered_draw)}
		delete_text_run(&truncated)
		return
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

draw_styled_text_in_rect :: proc(
	ctx: rawptr,
	style: Text_Style,
	text: string,
	rect: UI_Rect,
	horizontal, vertical: Text_Align,
	color: [4]f64,
	inset: f64 = 0,
) {
	font := system_monospaced_font(
		SMALL_FONT_SIZE * style.scale * ui.scale,
		style.weight,
	)
	if font == nil {return}
	defer foreign_release(font, "CTFont", "draw_styled_text_in_rect")
	draw_text_in_rect(
		ctx,
		font,
		text,
		rect,
		horizontal,
		vertical,
		color,
		inset,
		tracking = style.tracking,
	)
}

draw_header_identity :: proc(
	ctx, font: rawptr,
	rect: UI_Rect,
	name_color, mode_color: [4]f64,
) {
	if ctx == nil || font == nil || rect.w <= 0 || rect.h <= 0 {return}
	name_run := make_text_run(font, "hw_videoClips")
	defer delete_text_run(&name_run)
	if name_run.line == nil {return}
	mode_text := fmt.tprintf(" / %s", active_view_label(ui.workflow, ui.mode))
	mode_run := make_text_run(font, mode_text)
	defer delete_text_run(&mode_run)

	if ordered_overlay_active {
		framework_draw.push_clip(&ordered_draw, ordered_rect(rect))
		defer framework_draw.pop_clip(&ordered_draw)
	} else {
		CGContextSaveGState(ctx)
		defer CGContextRestoreGState(ctx)
		CGContextClipToRect(
			ctx,
			Rect{
				Point{rect.x * ui.scale, rect.y * ui.scale},
				Size{rect.w * ui.scale, rect.h * ui.scale},
			},
		)
	}
	draw_text_run(
		ctx,
		name_run,
		text_origin(rect, name_run, .Start, .Center),
		name_color,
	)
	available_width := rect.w * ui.scale - name_run.advance
	if mode_run.line == nil || available_width <= 0 {return}
	draw_mode := mode_run
	truncated: Text_Run
	if mode_run.advance > available_width {
		truncated = truncated_text_run(mode_run, font, available_width)
		if truncated.line == nil {return}
		draw_mode = truncated
	}
	defer delete_text_run(&truncated)
	mode_rect := UI_Rect{
		rect.x + name_run.advance / ui.scale,
		rect.y,
		available_width / ui.scale,
		rect.h,
	}
	draw_text_run(
		ctx,
		draw_mode,
		text_origin(mode_rect, draw_mode, .Start, .Center),
		mode_color,
	)
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
	if ordered_overlay_active {
		framework_draw.push_clip(&ordered_draw, ordered_rect(rect))
	} else {
		CGContextSaveGState(ctx)
		CGContextClipToRect(ctx, Rect{Point{rect.x * ui.scale, rect.y * ui.scale}, Size{rect.w * ui.scale, rect.h * ui.scale}})
	}
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
	if ordered_overlay_active {
		framework_draw.pop_clip(&ordered_draw)
	} else {
		CGContextRestoreGState(ctx)
	}
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
	font := system_monospaced_font(SMALL_FONT_SIZE * ui.scale)
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

	if ordered_overlay_active {
		framework_draw.push_clip(&ordered_draw, ordered_rect(rect))
		defer framework_draw.pop_clip(&ordered_draw)
	} else {
		CGContextSaveGState(ctx)
		defer CGContextRestoreGState(ctx)
		CGContextClipToRect(
			ctx,
			Rect{Point{rect.x * ui.scale, rect.y * ui.scale}, Size{rect.w * ui.scale, rect.h * ui.scale}},
		)
	}
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
			if ordered_overlay_active {
				framework_draw.push_clip(
					&ordered_draw,
					ordered_rect({
						start_x/ui.scale,
						(origin.y-draw_run.descent)/ui.scale,
						max(0, end_x-start_x)/ui.scale,
						(draw_run.ascent+draw_run.descent+draw_run.leading)/ui.scale,
					}),
				)
			} else {
				CGContextSaveGState(ctx)
				CGContextClipToRect(
					ctx,
					Rect{Point{start_x, origin.y - draw_run.descent}, Size{max(0, end_x - start_x), draw_run.ascent + draw_run.descent + draw_run.leading}},
				)
			}
			draw_text_run(ctx, draw_run, origin, color)
			if ordered_overlay_active {
				framework_draw.pop_clip(&ordered_draw)
			} else {
				CGContextRestoreGState(ctx)
			}
		}
		if range_index < ranges.count {
			normal_start = ranges.values[range_index].location + ranges.values[range_index].length
		}
	}
}

fill_overlay_rect :: proc(ctx: rawptr, rect: UI_Rect, color: [4]f64) {
	ui_render_trace_record_overlay_rect(rect, color)
	if ordered_overlay_active {
		framework_draw.solid(&ordered_draw, ordered_rect(rect), ordered_color(color))
		return
	}
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

ordered_overlay_line :: proc(from, to: Point, color: [4]f64, thickness: f64) {
	dx, dy := to.x-from.x, to.y-from.y
	length := math.sqrt(dx*dx+dy*dy)
	if length <= 0 {return}
	angle := math.atan2(dy, dx)
	framework_draw.push_transform(
		&ordered_draw,
		{
			f32(math.cos(angle)),
			f32(math.sin(angle)),
			-f32(math.sin(angle)),
			f32(math.cos(angle)),
			f32(from.x),
			f32(from.y),
		},
	)
	framework_draw.solid(
		&ordered_draw,
		{0, -f32(thickness/2), f32(length), f32(thickness)},
		ordered_color(color),
		f32(thickness/2),
	)
	framework_draw.pop_transform(&ordered_draw)
}

ordered_cubic_lines :: proc(
	start, control_1, control_2, end: Point,
	color: [4]f64,
	thickness: f64,
) {
	previous := start
	for step in 1..=8 {
		t := f64(step)/8
		u := 1-t
		next := Point{
			u*u*u*start.x+3*u*u*t*control_1.x+3*u*t*t*control_2.x+t*t*t*end.x,
			u*u*u*start.y+3*u*u*t*control_1.y+3*u*t*t*control_2.y+t*t*t*end.y,
		}
		ordered_overlay_line(previous, next, color, thickness)
		previous = next
	}
}

player_fullscreen_expand_points :: proc() -> [20]Window_Icon_Point {
	return {
		{{9, 9}, true},
		{{4, 4}, false},
		{{4, 8}, true},
		{{4, 4}, false},
		{{8, 4}, false},
		{{15, 9}, true},
		{{20, 4}, false},
		{{20, 8}, true},
		{{20, 4}, false},
		{{16, 4}, false},
		{{9, 15}, true},
		{{4, 20}, false},
		{{4, 16}, true},
		{{4, 20}, false},
		{{8, 20}, false},
		{{15, 15}, true},
		{{20, 20}, false},
		{{20, 16}, true},
		{{20, 20}, false},
		{{16, 20}, false},
	}
}

player_fullscreen_collapse_points :: proc() -> [20]Window_Icon_Point {
	return {
		{{20, 20}, true},
		{{15, 15}, false},
		{{15, 19}, true},
		{{15, 15}, false},
		{{19, 15}, false},
		{{4, 20}, true},
		{{9, 15}, false},
		{{9, 19}, true},
		{{9, 15}, false},
		{{5, 15}, false},
		{{20, 4}, true},
		{{15, 9}, false},
		{{15, 5}, true},
		{{15, 9}, false},
		{{19, 9}, false},
		{{4, 4}, true},
		{{9, 9}, false},
		{{9, 5}, true},
		{{9, 9}, false},
		{{5, 9}, false},
	}
}

draw_window_icon_path :: proc(
	ctx: rawptr,
	rect: UI_Rect,
	color: [4]f64,
	points: []Window_Icon_Point,
) {
	if ordered_overlay_active {
		framework_draw.push_clip(&ordered_draw, ordered_rect(rect))
		defer framework_draw.pop_clip(&ordered_draw)
		previous: Point
		has_previous := false
		thickness := 1.5*min(rect.w, rect.h)/24
		for command in points {
			point := Point{
				rect.x+command.point.x*rect.w/24,
				rect.y+(24-command.point.y)*rect.h/24,
			}
			if command.move {
				previous = point
				has_previous = true
				continue
			}
			if has_previous {ordered_overlay_line(previous, point, color, thickness)}
			previous = point
			has_previous = true
		}
		return
	}
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

draw_player_fullscreen_icon :: proc(
	ctx: rawptr,
	rect: UI_Rect,
	color: [4]f64,
	collapse: bool,
) {
	if collapse {
		points := player_fullscreen_collapse_points()
		draw_window_icon_path(ctx, rect, color, points[:])
		return
	}
	points := player_fullscreen_expand_points()
	draw_window_icon_path(ctx, rect, color, points[:])
}

settings_icon_point :: proc(rect: UI_Rect, x, y: f64) -> Point {
	return {
		(rect.x+x*rect.w/24)*ui.scale,
		(rect.y+(24-y)*rect.h/24)*ui.scale,
	}
}

settings_icon_logical_point :: proc(rect: UI_Rect, x, y: f64) -> Point {
	return {rect.x+x*rect.w/24, rect.y+(24-y)*rect.h/24}
}

draw_ordered_settings_icon :: proc(rect: UI_Rect, color: [4]f64) {
	framework_draw.push_clip(&ordered_draw, ordered_rect(rect))
	defer framework_draw.pop_clip(&ordered_draw)
	thickness := 1.5*min(rect.w, rect.h)/24
	start := settings_icon_logical_point(rect, 12, 15)
	c1 := settings_icon_logical_point(rect, 13.6569, 15)
	c2 := settings_icon_logical_point(rect, 15, 13.6569)
	end := settings_icon_logical_point(rect, 15, 12)
	ordered_cubic_lines(start, c1, c2, end, color, thickness)
	start = end
	c1 = settings_icon_logical_point(rect, 15, 10.3431)
	c2 = settings_icon_logical_point(rect, 13.6569, 9)
	end = settings_icon_logical_point(rect, 12, 9)
	ordered_cubic_lines(start, c1, c2, end, color, thickness)
	start = end
	c1 = settings_icon_logical_point(rect, 10.3431, 9)
	c2 = settings_icon_logical_point(rect, 9, 10.3431)
	end = settings_icon_logical_point(rect, 9, 12)
	ordered_cubic_lines(start, c1, c2, end, color, thickness)
	start = end
	c1 = settings_icon_logical_point(rect, 9, 13.6569)
	c2 = settings_icon_logical_point(rect, 10.3431, 15)
	end = settings_icon_logical_point(rect, 12, 15)
	ordered_cubic_lines(start, c1, c2, end, color, thickness)

	gear := [30]Point{
		{19.6224, 10.3954}, {18.5247, 7.7448}, {20, 6}, {18, 4},
		{16.2647, 5.48295}, {13.5578, 4.36974}, {12.9353, 2}, {10.981, 2},
		{10.3491, 4.40113}, {7.70441, 5.51596}, {6, 4}, {4, 6},
		{5.45337, 7.78885}, {4.3725, 10.4463}, {2, 11}, {2, 13},
		{4.40111, 13.6555}, {5.51575, 16.2997}, {4, 18}, {6, 20},
		{7.79116, 18.5403}, {10.397, 19.6123}, {11, 22}, {13, 22},
		{13.6045, 19.6132}, {16.2551, 18.5155}, {18.5159, 16.2494},
		{19.6139, 13.598}, {21.9999, 12.9772}, {22, 11},
	}
	previous := settings_icon_logical_point(rect, gear[0].x, gear[0].y)
	for index in 1..<26 {
		next := settings_icon_logical_point(rect, gear[index].x, gear[index].y)
		ordered_overlay_line(previous, next, color, thickness)
		previous = next
	}
	c1 = settings_icon_logical_point(rect, 16.6969, 18.8313)
	c2 = settings_icon_logical_point(rect, 18, 20)
	end = settings_icon_logical_point(rect, 18, 20)
	ordered_cubic_lines(previous, c1, c2, end, color, thickness)
	previous = end
	end = settings_icon_logical_point(rect, 20, 18)
	ordered_overlay_line(previous, end, color, thickness)
	previous = end
	for index in 26..<len(gear) {
		next := settings_icon_logical_point(rect, gear[index].x, gear[index].y)
		ordered_overlay_line(previous, next, color, thickness)
		previous = next
	}
	ordered_overlay_line(
		previous,
		settings_icon_logical_point(rect, gear[0].x, gear[0].y),
		color,
		thickness,
	)
}

draw_settings_icon :: proc(ctx: rawptr, rect: UI_Rect, color: [4]f64) {
	if ordered_overlay_active {
		draw_ordered_settings_icon(rect, color)
		return
	}
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
	p := settings_icon_point(rect, 12, 15)
	CGContextMoveToPoint(ctx, p.x, p.y)
	c1 := settings_icon_point(rect, 13.6569, 15)
	c2 := settings_icon_point(rect, 15, 13.6569)
	p = settings_icon_point(rect, 15, 12)
	CGContextAddCurveToPoint(ctx, c1.x, c1.y, c2.x, c2.y, p.x, p.y)
	c1 = settings_icon_point(rect, 15, 10.3431)
	c2 = settings_icon_point(rect, 13.6569, 9)
	p = settings_icon_point(rect, 12, 9)
	CGContextAddCurveToPoint(ctx, c1.x, c1.y, c2.x, c2.y, p.x, p.y)
	c1 = settings_icon_point(rect, 10.3431, 9)
	c2 = settings_icon_point(rect, 9, 10.3431)
	p = settings_icon_point(rect, 9, 12)
	CGContextAddCurveToPoint(ctx, c1.x, c1.y, c2.x, c2.y, p.x, p.y)
	c1 = settings_icon_point(rect, 9, 13.6569)
	c2 = settings_icon_point(rect, 10.3431, 15)
	p = settings_icon_point(rect, 12, 15)
	CGContextAddCurveToPoint(ctx, c1.x, c1.y, c2.x, c2.y, p.x, p.y)
	CGContextClosePath(ctx)

	gear := [30]Point{
		{19.6224, 10.3954},
		{18.5247, 7.7448},
		{20, 6},
		{18, 4},
		{16.2647, 5.48295},
		{13.5578, 4.36974},
		{12.9353, 2},
		{10.981, 2},
		{10.3491, 4.40113},
		{7.70441, 5.51596},
		{6, 4},
		{4, 6},
		{5.45337, 7.78885},
		{4.3725, 10.4463},
		{2, 11},
		{2, 13},
		{4.40111, 13.6555},
		{5.51575, 16.2997},
		{4, 18},
		{6, 20},
		{7.79116, 18.5403},
		{10.397, 19.6123},
		{11, 22},
		{13, 22},
		{13.6045, 19.6132},
		{16.2551, 18.5155},
		{18.5159, 16.2494},
		{19.6139, 13.598},
		{21.9999, 12.9772},
		{22, 11},
	}
	p = settings_icon_point(rect, gear[0].x, gear[0].y)
	CGContextMoveToPoint(ctx, p.x, p.y)
	for index in 1..<26 {
		p = settings_icon_point(rect, gear[index].x, gear[index].y)
		CGContextAddLineToPoint(ctx, p.x, p.y)
	}
	c1 = settings_icon_point(rect, 16.6969, 18.8313)
	c2 = settings_icon_point(rect, 18, 20)
	p = settings_icon_point(rect, 18, 20)
	CGContextAddCurveToPoint(ctx, c1.x, c1.y, c2.x, c2.y, p.x, p.y)
	p = settings_icon_point(rect, 20, 18)
	CGContextAddLineToPoint(ctx, p.x, p.y)
	for index in 26..<len(gear) {
		p = settings_icon_point(rect, gear[index].x, gear[index].y)
		CGContextAddLineToPoint(ctx, p.x, p.y)
	}
	p = settings_icon_point(rect, 19.6224, 10.3954)
	CGContextAddLineToPoint(ctx, p.x, p.y)
	CGContextClosePath(ctx)
	CGContextStrokePath(ctx)
}

draw_window_controls :: proc(ctx: rawptr) {
	theme := ui_theme_colors()
	colors := [3][4]f64{
		UI_COLOR_COFFEE_64,
		UI_COLOR_STONE_64,
		UI_COLOR_GUM_64,
	}
	if !ui_theme_is_dark(ui.theme) {
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
	settings_control := settings_button_rect()
	background := theme.panel_alt
	if contains(settings_control, ui.mouse) {background = theme.row_hover}
	fill_overlay_rect(ctx, settings_control, background)
	draw_settings_icon(ctx, settings_icon_rect(), theme.muted)
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

draw_command_palette :: proc(
	ctx, font: rawptr,
	bright, muted, dim, accent, cyan, danger: [4]f64,
) {
	if !command_palette.is_open(&command_palette_state) {return}
	theme := ui_theme_colors()
	modal := command_palette_rect()
	search := ui_control_rect(.Command_Palette_Search)
	content := command_palette_results_rect(modal)
	fill_overlay_rect(ctx, UI_Rect{0, 0, ui.width, ui.height}, theme.backdrop)
	fill_overlay_rect(ctx, modal, theme.modal)
	fill_overlay_rect(ctx, search, theme.field)
	fill_overlay_border(ctx, search, accent)
	draw_editable_text_field(
		ctx,
		font,
		ui.command_palette_query,
		"Search commands, sources, and clips",
		search,
		.Command_Palette,
		bright,
		dim,
		accent,
		12,
	)
	if ordered_overlay_active {
		framework_draw.push_clip(&ordered_draw, ordered_rect(content))
	} else {
		CGContextSaveGState(ctx)
		CGContextClipToRect(
			ctx,
			Rect{
				Point{content.x * ui.scale, content.y * ui.scale},
				Size{content.w * ui.scale, content.h * ui.scale},
			},
		)
	}
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
			fill_overlay_rect(ctx, UI_Rect{row.x, row.y, 3, row.h}, accent)
		} else if index % 2 == 0 {
			fill_overlay_rect(ctx, row, theme.row)
		}
		title_color := bright
		detail_color := muted
		if !result.available {
			title_color = dim
			detail_color = danger
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
	if ordered_overlay_active {
		framework_draw.pop_clip(&ordered_draw)
	} else {
		CGContextRestoreGState(ctx)
	}
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

draw_discard_confirmation :: proc(
	ctx, font: rawptr,
	bright, muted, warning: [4]f64,
) {
	if !ui.discard_confirm_open {return}
	theme := ui_theme_colors()
	modal := discard_confirm_rect()
	fill_overlay_rect(ctx, modal, theme.modal)
	draw_text_in_rect(
		ctx,
		font,
		"DISCARD CHANGES?",
		{modal.x+24, modal.y+modal.h-54, modal.w-48, 30},
		.Start,
		.Center,
		bright,
	)
	draw_text_in_rect(
		ctx,
		font,
		"YOUR UNSAVED CHANGES WILL BE LOST",
		{modal.x+24, modal.y+modal.h-88, modal.w-48, 24},
		.Start,
		.Center,
		muted,
	)
	keep := discard_confirm_action_rect(0)
	discard := discard_confirm_action_rect(1)
	fill_overlay_rect(ctx, keep, theme.panel_alt)
	fill_overlay_rect(ctx, discard, theme.panel_alt)
	fill_overlay_border(ctx, discard, warning)
	draw_text_in_rect(ctx, font, "1  KEEP EDITING", keep, .Center, .Center, bright)
	draw_text_in_rect(ctx, font, "2  DISCARD CHANGES", discard, .Center, .Center, warning)
}

draw_clip_rename :: proc(ctx, font: rawptr, bright, muted, dim, accent: [4]f64) {
	if !ui.clip_rename_open ||
	   ui.clip_rename_index < 0 ||
	   ui.clip_rename_index >= len(state.clips) {
		return
	}
	modal := clip_rename_modal_rect()
	input := ui_control_rect(.Clip_Rename)
	cancel := ui_control_rect(.Cancel_Clip_Rename)
	confirm := ui_control_rect(.Confirm_Clip_Rename)
	clip := &state.clips[ui.clip_rename_index]
	theme := ui_theme_colors()
	fill_overlay_rect(ctx, UI_Rect{0, 0, ui.width, ui.height}, theme.backdrop)
	fill_overlay_rect(ctx, modal, theme.modal)
	header := UI_Rect{modal.x, modal.y + modal.h - 54, modal.w, 54}
	fill_overlay_rect(ctx, header, theme.panel_alt)
	draw_styled_text_in_rect(ctx, TEXT_STYLE_HEADING, "RENAME CLIP", UI_Rect{header.x + 20, header.y, header.w - 40, header.h}, .Start, .Center, bright)
	draw_styled_text_in_rect(ctx, TEXT_STYLE_LABEL, "ORIGINAL NAME", UI_Rect{modal.x + 24, modal.y + modal.h - 96, modal.w - 48, 22}, .Start, .Center, muted)
	draw_text_in_rect(ctx, font, clip.name, UI_Rect{modal.x + 24, modal.y + modal.h - 130, modal.w - 48, 28}, .Start, .Center, bright)
	draw_styled_text_in_rect(ctx, TEXT_STYLE_LABEL, "NEW NAME", UI_Rect{input.x, input.y + input.h + 8, input.w, 22}, .Start, .Center, muted)
	fill_overlay_rect(ctx, input, theme.field)
	if ui.focus == .Clip_Rename {fill_overlay_border(ctx, input, accent)}
	draw_editable_text_field(ctx, font, ui.clip_rename, "Enter a new clip name", input, .Clip_Rename, bright, dim, accent, 10)
	cancel_color := theme.panel_alt
	if contains(cancel, ui.mouse) {cancel_color = theme.row_hover}
	fill_overlay_rect(ctx, cancel, cancel_color)
	draw_text_in_rect(ctx, font, "CANCEL", cancel, .Center, .Center, muted)
	confirm_control := find_ui_control_by_action(.Confirm_Clip_Rename)
	confirm_enabled := confirm_control != nil && .Enabled in confirm_control.flags
	confirm_color := theme.panel_alt
	if confirm_enabled && contains(confirm, ui.mouse) {confirm_color = theme.row_hover}
	fill_overlay_rect(ctx, confirm, confirm_color)
	if confirm_enabled {fill_overlay_border(ctx, confirm, accent)}
	draw_text_in_rect(
		ctx,
		font,
		"RENAME",
		confirm,
		.Center,
		.Center,
		confirm_enabled ? accent : dim,
	)
}

draw_clip_metadata :: proc(
	ctx, font: rawptr,
	bright, muted, dim, cyan, danger: [4]f64,
) {
	if !ui.clip_metadata_open ||
	   ui.clip_metadata_index < 0 ||
	   ui.clip_metadata_index >= len(state.clips) {
		return
	}
	modal := clip_metadata_modal_rect()
	close_button := ui_control_rect(.Close_Clip_Metadata)
	source_button := ui_control_rect(.View_Clip_Source)
	clip := &state.clips[ui.clip_metadata_index]
	source_index := source_index_for_clip(
		state.sources[:],
		state.clips[:],
		ui.clip_metadata_index,
	)
	source_title := "SOURCE RECORD MISSING"
	source_id := clip.source_id
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
	draw_styled_text_in_rect(ctx, TEXT_STYLE_HEADING, "CLIP METADATA", UI_Rect{header.x + 20, header.y, header.w - 40, header.h}, .Start, .Center, bright)
	draw_text_in_rect(ctx, font, clip.name, UI_Rect{modal.x + 24, modal.y + modal.h - 100, modal.w - 48, 28}, .Start, .Center, cyan)
	clip_available := os.exists(clip.clip_path)
	labels := [10]string{
		"CLIP ID",
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
		clip.id,
		source_title,
		source_id,
		video_id,
		format_timestamp(clip.start_seconds),
		format_timestamp(clip.end_seconds),
		format_timestamp(clip.end_seconds - clip.start_seconds),
		source_url,
		clip.clip_path,
		clip_available ? "AVAILABLE" : "MISSING",
	}
	for label, row_index in labels {
		row := clip_metadata_row_rect(modal, row_index)
		if row_index % 2 == 0 {fill_overlay_rect(ctx, row, theme.row)}
		draw_styled_text_in_rect(ctx, TEXT_STYLE_LABEL, label, UI_Rect{row.x + 10, row.y, 128, row.h}, .Start, .Center, muted)
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
	source_control := find_ui_control_by_action(.View_Clip_Source)
	source_enabled := source_control != nil && .Enabled in source_control.flags
	source_color := theme.panel_alt
	if source_enabled && contains(source_button, ui.mouse) {source_color = theme.row_hover}
	fill_overlay_rect(ctx, source_button, source_color)
	if source_enabled {fill_overlay_border(ctx, source_button, cyan)}
	draw_text_in_rect(ctx, font, "VIEW SOURCE", source_button, .Center, .Center, source_enabled ? cyan : dim)
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
		"HOW RANDOMIZE SELECTS A CLIP",
		UI_Rect{header.x + 20, header.y, header.w - 40, header.h},
		.Start,
		.Center,
		bright,
	)
	explanation := [8]string{
		"Randomize draws from the complete clip library. Search text does not limit the draw.",
		"The active clip is skipped when another clip is available.",
		"A selected clip returns to weight 2.",
		"Each skipped Randomize draw adds 1, up to weight 6.",
		"Never-selected clips start at weight 6. Manual playback does not change the history.",
		"Weight 6 has three times the chance of weight 2, but each draw remains random.",
		"Randomize history stays on this device and is not included in library exports.",
		"Shuffle applies the same weights to filtered Play Next selections and updates this history.",
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
		UI_Rect{modal.x + 24, modal.y + modal.h - 272, 276, 24},
		.Start,
		.Center,
		cyan,
	)
	if filtered_clip_count() > 1 &&
	   ui.active_clip >= 0 &&
	   ui.active_clip < len(state.clips) {
		draw_text_in_rect(
			ctx,
			font,
			fmt.tprintf(
				"ACTIVE EXCLUDED: %s",
				state.clips[ui.active_clip].name,
			),
			UI_Rect{modal.x + 310, modal.y + modal.h - 272, modal.w - 334, 24},
			.End,
			.Center,
			muted,
			10,
		)
	}
	draw_text_in_rect(
		ctx,
		font,
		"CLIP",
		UI_Rect{modal.x + 34, modal.y + modal.h - 296, modal.w - 250, 22},
		.Start,
		.Center,
		muted,
	)
	draw_text_in_rect(
		ctx,
		font,
		"WEIGHT",
		UI_Rect{modal.x + modal.w - 202, modal.y + modal.h - 296, 74, 22},
		.End,
		.Center,
		muted,
	)
	draw_text_in_rect(
		ctx,
		font,
		"CHANCE",
		UI_Rect{modal.x + modal.w - 112, modal.y + modal.h - 296, 78, 22},
		.End,
		.Center,
		muted,
	)
	candidates: [RANDOM_CLIP_HELP_LIMIT]Random_Clip_Candidate
	candidate_count, total_weight := random_clip_ranked_candidates(
		state.clips[:],
		ui.active_clip,
		candidates[:],
	)
	if candidate_count == 0 {
		draw_text_in_rect(
			ctx,
			font,
			"NO CLIPS ARE AVAILABLE",
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
		clip := &state.clips[candidate.clip_index]
		draw_text_in_rect(
			ctx,
			font,
			clip.name,
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
	minimum_midi, maximum_midi := pitch_plot_window_midi(&ui.pitch)
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
		"OCTAVES",
		UI_Rect{settings.x, top - 80, settings.w, 18},
		.Start,
		.Center,
		muted,
	)
	octave_value := clamp(ui.pitch.settings.octaves, 1, 6)
	draw_text_in_rect(ctx, font, "-", ui_control_rect(.Pitch_Octaves_Down), .Center, .Center, bright)
	draw_text_in_rect(
		ctx,
		font,
		fmt.tprintf("%d OCT", octave_value),
		pitch_octaves_rect(panel, 1),
		.Center,
		.Center,
		bright,
	)
	draw_text_in_rect(ctx, font, "+", ui_control_rect(.Pitch_Octaves_Up), .Center, .Center, bright)

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

draw_dance_tools :: proc(
	ctx, font: rawptr,
	panel: UI_Rect,
	bright, muted, dim, accent, cool: [4]f64,
) {
	if ui.mode != .Play || ui.workflow != .Dancing || panel.w <= 0 {return}
	header := UI_Rect{panel.x, panel.y + panel.h - 35, panel.w, 35}
	draw_text_in_rect(
		ctx,
		font,
		"03 / DANCE TOOLS",
		UI_Rect{header.x + 10, header.y, header.w - 20, header.h},
		.Start,
		.Center,
		muted,
	)
	content := dance_content_rect(panel)
	clip := active_dance_clip()
	if clip == nil {
		draw_text_in_rect(
			ctx,
			font,
			"SELECT A DANCING CLIP",
			UI_Rect{content.x, content.y + content.h / 2, content.w, 24},
			.Center,
			.Center,
			dim,
		)
		return
	}
	top := content.y + content.h
	rows := [5]string{
		fmt.tprintf("CLIP / %s", clip.name),
		clip.dance_mirrored ? "MIRROR / ON" : "MIRROR / OFF",
		clip.dance_loop ? "LOOP / ON" : "LOOP / OFF",
		fmt.tprintf("COUNT-IN / %d", clip.dance_count_in_beats),
		clip.dance_count_each_loop ? "COUNT EACH LOOP / ON" : "COUNT EACH LOOP / OFF",
	}
	for text, index in rows {
		color := muted
		if index > 0 {
			active :=
				(index == 1 && clip.dance_mirrored) ||
				(index == 2 && clip.dance_loop) ||
				(index == 3 && clip.dance_count_in_beats > 0) ||
				(index == 4 && clip.dance_count_each_loop)
			if active {color = cool}
		}
		draw_text_in_rect(
			ctx,
			font,
			text,
			UI_Rect{content.x, top - 32 - f64(index) * 32, content.w, 24},
			.Start,
			.Center,
			color,
		)
	}
	bpm_down := ui_control_rect(.Dance_BPM_Down)
	bpm_up := ui_control_rect(.Dance_BPM_Up)
	bpm_value := dance_bpm_value_rect(panel)
	draw_text_in_rect(
		ctx,
		font,
		"COUNT-IN BPM",
		UI_Rect{content.x, bpm_value.y + bpm_value.h + 8, content.w, 20},
		.Start,
		.Center,
		muted,
	)
	draw_text_in_rect(ctx, font, "-", bpm_down, .Center, .Center, clip.dance_count_in_bpm > 40 ? accent : dim)
	draw_text_in_rect(
		ctx,
		font,
		fmt.tprintf("%d", clip.dance_count_in_bpm),
		bpm_value,
		.Center,
		.Center,
		bright,
	)
	draw_text_in_rect(ctx, font, "+", bpm_up, .Center, .Center, clip.dance_count_in_bpm < 240 ? accent : dim)
	draw_text_in_rect(
		ctx,
		font,
		fmt.tprintf("SAVED SPEED / %.1fx", clip.dance_playback_rate),
		UI_Rect{content.x, bpm_value.y - 42, content.w, 24},
		.Start,
		.Center,
		muted,
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
	lines := [9]string{
		fmt.tprintf(
			"Press action %s to start or stop live microphone analysis.",
			pitch_numbered_action_text(),
		),
		"The first start asks macOS for microphone access. No audio is stored.",
		"Pitch Standard changes the A4 reference frequency from 400 to 480 Hz.",
		"Octaves sets the visible pitch window from 1 to 6 octaves.",
		"The chart follows the current pitch and holds position during silence.",
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
	bright, muted, dim, warning, cyan: [4]f64,
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
	title := ui.library_import_confirm_open ? "IMPORT LIBRARY DATA" : "LIBRARY DATA"
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
			fmt.tprintf(
				"The imported records will replace the %s library scope.",
				portable_library_scope_name(pending_library_import_scope),
			),
			UI_Rect{modal.x + 24, modal.y + modal.h - 112, modal.w - 48, 28},
			.Start,
			.Center,
			bright,
		)
		draw_text_in_rect(
			ctx,
			font,
			fmt.tprintf(
				"%03d SOURCES   %03d CLIPS   %04d TRANSCRIPT SEGMENTS",
				len(pending_library_import.sources),
				len(pending_library_import.clips),
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
		draw_text_in_rect(ctx, font, "02  CANCEL", cancel, .Center, .Center, muted)
		confirm_control := find_ui_control_by_action(.Confirm_Library_Import)
		confirm_enabled := confirm_control != nil && .Enabled in confirm_control.flags
		confirm_color := theme.panel_alt
		if confirm_enabled && contains(confirm, ui.mouse) {
			confirm_color = theme.row_hover
		}
		fill_overlay_rect(ctx, confirm, confirm_color)
		if confirm_enabled {fill_overlay_border(ctx, confirm, warning)}
		draw_text_in_rect(
			ctx,
			font,
			"01  REPLACE AND RECOVER",
			confirm,
			.Center,
			.Center,
			confirm_enabled ? warning : dim,
		)
		return
	}

	actions := [5]UI_Action_Kind{
		.Export_Library,
		.Export_Current_Workflow,
		.Import_Library,
		.Open_Data_Folder,
		.Close_Data_Modal,
	}
	labels := [5]string{
		"01  EXPORT ALL",
		fmt.tprintf("02  EXPORT %s", ui.workflow == .Vocal ? "VOCAL" : "DANCING"),
		"03  IMPORT",
		"04  OPEN DATA FOLDER",
		"05  CLOSE",
	}
	details := [5]string{
		"Save both workflows as portable metadata",
		"Save only the current workflow as portable metadata",
		"Replace the scope stored by a portable metadata file",
		"Show the active application-support directory in Finder",
		"Return to the application",
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
}

draw_library_recovery :: proc(
	ctx, font: rawptr,
	bright, muted, dim, warning, cyan, danger: [4]f64,
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
			"%03d SOURCES   %04d SEGMENTS   %03d HINTS   %03d CLIPS",
			report.recovered_sources,
			report.recovered_segments,
			report.recovered_hints,
			report.recovered_clips,
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
		fill_overlay_rect(ctx, confirm, theme.panel_alt)
		fill_overlay_border(ctx, confirm, warning)
		draw_text_in_rect(ctx, font, "CANCEL", cancel, .Center, .Center, muted)
		draw_text_in_rect(ctx, font, "ACTIVATE RECOVERY", confirm, .Center, .Center, warning)
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
	bright, muted, warning, danger: [4]f64,
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
	fill_overlay_rect(ctx, confirm, theme.panel_alt)
	fill_overlay_border(ctx, confirm, warning)
	draw_text_in_rect(ctx, font, "CANCEL", cancel, .Center, .Center, muted)
	draw_text_in_rect(ctx, font, "CONTINUE WITHOUT BACKUP", confirm, .Center, .Center, warning)
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
	bright, muted, dim, accent, cyan, danger, success: [4]f64,
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
		if notification.kind == .Activity {kind_color = accent}
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
		action_color := theme.panel_alt
		if enabled && contains(action, ui.mouse) {
			action_color = theme.row_hover
		}
		fill_overlay_rect(ctx, action, action_color)
		if enabled {fill_overlay_border(ctx, action, cyan)}
		draw_text_in_rect(
			ctx,
			font,
			"VIEW SOURCE",
			action,
			.Center,
			.Center,
			enabled ? cyan : dim,
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
	draw_styled_text_in_rect(ctx, TEXT_STYLE_HEADING, "SOURCE DETAILS / MANAGED MEDIA", UI_Rect{header.x + 20, header.y, header.w - 40, header.h}, .Start, .Center, bright)
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
	labels := [10]string{"SOURCE ID", "SOURCE TYPE", source.kind == .Local ? "ORIGINAL FILE" : "SOURCE URL", "DURATION", "RESOLUTION", "FRAME RATE", "VIDEO CODEC", "AUDIO CODEC", "CONTAINER", "FILE SIZE"}
	video_codec := metadata.vcodec
	if len(video_codec) == 0 {video_codec = pending_value}
	audio_codec := metadata.acodec
	if len(audio_codec) == 0 {audio_codec = pending_value}
	container := metadata.ext
	if len(container) == 0 {container = pending_value}
	origin := source.kind == .Local ? source.original_filename : source.url
	values := [10]string{source.video_id, source.kind == .Local ? "LOCAL FILE" : "YOUTUBE", origin, format_timestamp(source.duration), resolution, frame_rate, video_codec, source.has_audio ? audio_codec : "NO AUDIO TRACK", container, file_size}
	for label, row_index in labels {
		row := source_details_row_rect(modal, row_index)
		if row_index % 2 == 0 {fill_overlay_rect(ctx, row, theme.row)}
		draw_styled_text_in_rect(ctx, TEXT_STYLE_LABEL, label, UI_Rect{row.x + 10, row.y, 142, row.h}, .Start, .Center, muted)
		value := values[row_index]
		if len(value) == 0 {value = "UNAVAILABLE"}
		value_rect := UI_Rect{row.x + 160, row.y, row.w - 170, row.h}
		if row_index == 3 {
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
		refetch_text_color = UI_COLOR_COFFEE_64
		if contains(refetch_button, ui.mouse) {refetch_color = theme.row_hover}
	}
	fill_overlay_rect(ctx, refetch_button, refetch_color)
	if refetch_enabled {fill_overlay_border(ctx, refetch_button, UI_COLOR_COFFEE_64)}
	action_label := source.kind == .Local ? (source.media_available ? "MANAGED COPY AVAILABLE" : "LOCATE ORIGINAL…") : "REFETCH / SELECT QUALITY"
	draw_text_in_rect(ctx, font, action_label, refetch_button, .Center, .Center, refetch_text_color)
}

build_geometry :: proc(vertices: ^[dynamic]Solid_Vertex) {
	previous_lookup := ui_base_control_lookup
	ui_base_control_lookup = true
	defer ui_base_control_lookup = previous_lookup

	_, _, source_search, source_panel, player, transcript, clip_search, clip_panel, clip_name, pitch_panel, _ :=
		layout_rects()
	theme := ui_theme_colors()
	chassis := ui_color_32(theme.chassis)
	panel := ui_color_32(theme.panel)
	panel_alt := ui_color_32(theme.panel_alt)
	field := ui_color_32(theme.field)
	rule := ui_color_32(theme.rule)
	row_color := ui_color_32(theme.row)
	row_hover := ui_color_32(theme.row_hover)
	accent := ui_color_32(
		workflow_accent_color(ui.workflow, ui_theme_is_dark(ui.theme)),
	)
	if ui.playback_fullscreen_active {
		push_rect(vertices, UI_Rect{0, 0, ui.width, ui.height}, {0, 0, 0, 1})
		return
	}
	push_rect(vertices, UI_Rect{0, 0, ui.width, ui.height}, chassis)
	push_rect(vertices, app_header_rect(), ui_color_32(theme.header))
	workflow_rect := ui_control_rect(.Workflow_Toggle)
	workflow_color := panel_alt
	if contains(workflow_rect, ui.mouse) {workflow_color = row_hover}
	push_rect(vertices, workflow_rect, workflow_color)
	push_border(vertices, workflow_rect, accent)
	push_rect(vertices, left_accent_edge_rect(workflow_rect), accent)
	mode_rect := ui_control_rect(.Mode_Toggle)
	mode_color := panel_alt
	if contains(mode_rect, ui.mouse) {mode_color = row_hover}
	push_rect(vertices, mode_rect, mode_color)
	push_border(vertices, mode_rect, accent)
	push_rect(vertices, left_accent_edge_rect(mode_rect), accent)
	panels := [5]UI_Rect{source_panel, player, transcript, clip_panel, pitch_panel}
	for rect in panels {
		if rect.w <= 0 || rect.h <= 0 {continue}
		push_rect(vertices, rect, panel)
		push_rect(vertices, UI_Rect{rect.x, rect.y + rect.h - 34, rect.w, 34}, panel_alt)
	}
	if ui.mode == .Play && ui.workflow == .Vocal {
		chart := pitch_chart_rect(pitch_panel)
		settings := pitch_settings_rect(pitch_panel)
		plot := pitch_plot_rect(pitch_panel)
		push_rect(vertices, chart, row_color)
		push_rect(vertices, settings, field)
		minimum_midi, maximum_midi := pitch_plot_window_midi(&ui.pitch)
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
					accent,
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
		octaves_kinds := [2]UI_Action_Kind{
			.Pitch_Octaves_Down,
			.Pitch_Octaves_Up,
		}
		for kind in octaves_kinds {
			rect := ui_control_rect(kind)
			if rect.w <= 0 {continue}
			control := find_ui_control_by_action(kind)
			enabled := control != nil && .Enabled in control.flags
			color := enabled ? panel_alt : field
			if enabled && contains(rect, ui.mouse) {color = row_hover}
			push_rect(vertices, rect, color)
			if enabled {push_border(vertices, rect, UI_COLOR_GUM_32)}
		}
		for index in 0 ..< 3 {
			rect := ui_control_rect(.Pitch_Labels, index)
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
	} else if ui.mode == .Play && ui.workflow == .Dancing {
		bpm_kinds := [2]UI_Action_Kind{.Dance_BPM_Down, .Dance_BPM_Up}
		for kind in bpm_kinds {
			rect := ui_control_rect(kind)
			if rect.w <= 0 {continue}
			control := find_ui_control_by_action(kind)
			enabled := control != nil && .Enabled in control.flags
			color := enabled ? panel_alt : field
			if enabled && contains(rect, ui.mouse) {color = row_hover}
			push_rect(vertices, rect, color)
			if enabled {push_border(vertices, rect, accent)}
		}
		value := dance_bpm_value_rect(pitch_panel)
		push_rect(vertices, value, field)
	}
	field_kinds := [4]UI_Action_Kind{
		.Source_Search,
		.Transcript_Search,
		.Clip_Search,
		.Clip_Name,
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
		if ui.player_duration > 0 {
			seconds, has_seconds := current_seconds()
			progress := 0.0
			if has_seconds {
				progress = playback_timeline_progress(
					seconds,
					ui.player_duration,
				)
			}
			completed, thumb := playback_timeline_geometry(timeline, progress)
			push_rect(vertices, completed, accent)
			push_rect(vertices, thumb, accent)
		}
		if fullscreen_control := player_fullscreen_toggle_control();
		   fullscreen_control != nil {
			button_color := field
			if contains(fullscreen_control.rect, ui.mouse) {
				button_color = panel_alt
			}
			push_rect(vertices, fullscreen_control.rect, button_color)
		}
	}
	if ui.mode == .Create {
		add_rect := ui_control_rect(.Open_Source_Modal)
		add_control := find_ui_control_by_action(.Open_Source_Modal)
		add_enabled := add_control != nil && .Enabled in add_control.flags
		add_color := panel_alt
		if add_enabled && contains(add_rect, ui.mouse) {add_color = row_hover}
		push_rect(vertices, add_rect, add_color)
		if add_enabled {push_border(vertices, add_rect, accent)}

		commit_control := find_ui_control(ui_control_id("commit clip output"))
		if commit_control != nil {
			commit_color := field
			if .Enabled in commit_control.flags {
				if contains(commit_control.rect, ui.mouse) {
					commit_color = row_hover
				}
			}
			push_rect(vertices, commit_control.rect, commit_color)
			if .Enabled in commit_control.flags {
				push_border(vertices, commit_control.rect, accent)
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
				if index == state.active_source {
					push_rect(vertices, left_accent_edge_rect(row), accent)
				}
				if !source.media_available {
					push_rect(vertices, left_accent_edge_rect(row), UI_COLOR_COFFEE_32)
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
					push_rect(vertices, bottom_progress_edge_rect(row, progress), accent)
				}
			}
			row.y -= 26
		}
	}

	if ui.mode == .Play {
		clip_content := clip_content_rect(clip_search, clip_panel, clip_name)
		row := UI_Rect {
			clip_content.x,
			clip_content.y + clip_content.h - 29 + ui.clip_scroll,
			clip_content.w,
			29,
		}
		for clip, index in state.clips {
			if !clip_matches_filter(clip, ui.clip_search) {continue}
			control := find_ui_control_by_action_and_index(.Clip, index)
			if control != nil {
				row = control.rect
				color := row_color
				if contains(row, ui.mouse) {color = row_hover}
				push_rect(vertices, row, color)
				push_rect(vertices, UI_Rect{row.x, row.y, row.w, 1}, rule)
				if index == ui.active_clip {
					push_rect(vertices, left_accent_edge_rect(row), accent)
				}
			}
			row.y -= 30
		}
	}

	control_kinds := [20]UI_Action_Kind{.Start, .End, .Save, .Play, .Pause, .Captions, .Preview, .Data, .Rename, .Metadata, .Randomize, .Pitch_Toggle, .Play_Next, .Shuffle_Toggle, .Autoplay_Toggle, .Dance_Mirror_Toggle, .Dance_Loop_Toggle, .Dance_Count_In, .Dance_Count_Each_Loop_Toggle, .Playback_Fullscreen_Toggle}
	valid_range := active_clip_range_is_valid()
	number_prefix_active :=
		ui.number_prefix > 0 &&
		numbered_action_time_ms() < ui.number_prefix_deadline_ms
	for kind, action_index in control_kinds {
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
			push_border(vertices, rect, accent)
		}
		if enabled && kind == .Pitch_Toggle && ui.pitch.tracking {
			push_border(vertices, rect, UI_COLOR_GUM_32)
		}
		if enabled &&
		   ((kind == .Dance_Mirror_Toggle &&
		     active_dance_clip_mirrored()) ||
		    (kind == .Dance_Loop_Toggle &&
		     active_dance_clip_looping()) ||
		    (kind == .Dance_Count_Each_Loop_Toggle &&
		     active_dance_clip_counts_each_loop())) {
			push_border(vertices, rect, UI_COLOR_GUM_32)
		}
		toggle_active :=
			(kind == .Shuffle_Toggle && ui.clip_shuffle) ||
			(kind == .Autoplay_Toggle && ui.clip_autoplay)
		if enabled && toggle_active {
			push_border(vertices, rect, UI_COLOR_GUM_32)
			push_rect(vertices, left_accent_edge_rect(rect), UI_COLOR_GUM_32)
		}
		code, has_code := numbered_action_code_for_action(ui.mode, action_index)
		if number_prefix_active && has_code &&
		   code.section == ui.number_prefix {
			push_border(vertices, rect, accent)
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
	case .Local_Source_Title:
		if control := find_ui_control_by_action_and_index(
			.Local_Source_Title,
			ui.local_source_title_index,
		); control != nil {
			focus_rect = control.rect
		}
	case .Source_Search:
		focus_rect = ui_control_rect(.Source_Search)
	case .Transcript_Search:
		focus_rect = ui_control_rect(.Transcript_Search)
	case .Clip_Search:
		focus_rect = ui_control_rect(.Clip_Search)
	case .Clip_Name:
		focus_rect = ui_control_rect(.Clip_Name)
	}
	if focus_rect.w > 0 {
		push_border(vertices, focus_rect, accent)
		push_rect(vertices, UI_Rect{focus_rect.x, focus_rect.y, 3, focus_rect.h}, accent)
	}
}

draw_settings_overlays :: proc(
	ctx, font: rawptr,
	ink, bright, muted, dim, accent, cyan, danger: [4]f64,
) {
	if ui.settings_open {
		theme := ui_theme_colors()
		fill_overlay_rect(ctx, {0, 0, ui.width, ui.height}, theme.backdrop)
		modal := video_clips_settings_rect()
		fill_overlay_rect(ctx, modal, theme.modal)
		search := video_clips_settings_search_rect()
		fill_overlay_rect(ctx, search, theme.field)
		if ui.focus == .Settings_Search {
			fill_overlay_border(ctx, search, UI_COLOR_GUM_64)
		}
		close := video_clips_settings_close_rect()
		fill_overlay_rect(ctx, close, theme.panel_alt)
		categories := [2]Video_Clips_Settings_Category{.Styling, .Shortcuts}
		for category, index in categories {
			rect := video_clips_settings_category_rect(index)
			color := theme.panel_alt
			if contains(rect, ui.mouse) {color = theme.row_hover}
			fill_overlay_rect(ctx, rect, color)
			if !video_clips_settings_search_active() &&
			   category == ui.settings_category {
				fill_overlay_border(ctx, rect, UI_COLOR_GUM_64)
				fill_overlay_rect(ctx, left_accent_edge_rect(rect), UI_COLOR_GUM_64)
			}
		}
		for descriptor, index in video_clips_settings_result_descriptors() {
			rect := video_clips_settings_result_rect(index)
			color := theme.panel_alt
			if contains(rect, ui.mouse) {color = theme.row_hover}
			fill_overlay_rect(ctx, rect, color)
			if descriptor.action.kind == .Set_Theme &&
			   UI_Theme(descriptor.action.value) == ui.theme {
				fill_overlay_border(ctx, rect, UI_COLOR_GUM_64)
				fill_overlay_rect(ctx, left_accent_edge_rect(rect), UI_COLOR_GUM_64)
			}
		}
		draw_editable_text_field(
			ctx,
			font,
			ui.settings_query,
			"SEARCH SETTINGS",
			video_clips_settings_search_rect(),
			.Settings_Search,
			ink,
			muted,
			cyan,
		)
		xmark := window_icon_xmark_points()
		draw_window_icon_path(
			ctx,
			{close.x+5, close.y+8, 18, 18},
			muted,
			xmark[:],
		)
		for category, index in categories {
			color := muted
			if !video_clips_settings_search_active() &&
			   category == ui.settings_category {
				color = ink
			}
			draw_text_in_rect(
				ctx,
				font,
				fmt.tprintf(
					"%s  %02d",
					video_clips_settings_category_name(category),
					video_clips_settings_category_match_count(category),
				),
				video_clips_settings_category_rect(index),
				.Start,
				.Center,
				color,
				8,
			)
		}
		for descriptor, index in video_clips_settings_result_descriptors() {
			rect := video_clips_settings_result_rect(index)
			draw_text_in_rect(
				ctx,
				font,
				descriptor.title,
				{rect.x+8, rect.y, rect.w*0.58, rect.h},
				.Start,
				.Center,
				ink,
			)
			value := ""
			value_color := muted
			if descriptor.action.kind == .Set_Theme &&
			   UI_Theme(descriptor.action.value) == ui.theme {
				value = "CURRENT"
				value_color = cyan
			} else if descriptor.action.kind == .Configure_Flash {
				value = video_clips_shortcut_display(ui.flash_leader)
			}
			draw_text_in_rect(
				ctx,
				font,
				value,
				{rect.x+rect.w*0.60, rect.y, rect.w*0.38-8, rect.h},
				.End,
				.Center,
				value_color,
			)
		}
		if len(ui.settings_error) > 0 {
			content := video_clips_settings_content_rect()
			draw_text_in_rect(
				ctx,
				font,
				ui.settings_error,
				{content.x, content.y, content.w, 24},
				.Start,
				.Center,
				danger,
			)
		}
	}
	if ui.shortcut_open {
		theme := ui_theme_colors()
		fill_overlay_rect(ctx, {0, 0, ui.width, ui.height}, theme.backdrop)
		modal := video_clips_shortcut_modal_rect()
		fill_overlay_rect(ctx, modal, theme.modal)
		record := video_clips_shortcut_record_rect()
		fill_overlay_rect(ctx, record, theme.field)
		if ui.shortcut_listening {
			fill_overlay_border(ctx, record, UI_COLOR_GUM_64)
		}
		for index in 0..<3 {
			rect := video_clips_shortcut_action_rect(index)
			color := theme.panel_alt
			if contains(rect, ui.mouse) {color = theme.row_hover}
			fill_overlay_rect(ctx, rect, color)
		}
		if ui.shortcut_candidate_valid && len(ui.shortcut_collision) == 0 {
			fill_overlay_border(
				ctx,
				video_clips_shortcut_action_rect(0),
				accent,
			)
		}
		draw_text_in_rect(
			ctx,
			font,
			"CONFIGURE FLASH LEADER",
			{modal.x+24, modal.y+modal.h-50, modal.w-48, 30},
			.Start,
			.Center,
			bright,
		)
		draw_text_in_rect(
			ctx,
			font,
			"PRESS ONE KEY WITH ANY COMMAND, CONTROL, OPTION, OR SHIFT MODIFIERS",
			{modal.x+24, modal.y+modal.h-80, modal.w-48, 22},
			.Start,
			.Center,
			muted,
		)
		record_text := "PRESS A KEY…"
		if ui.shortcut_candidate_valid {
			record_text = video_clips_shortcut_display(ui.shortcut_candidate)
		} else if ui.shortcut_listening &&
		          ui.shortcut_live_modifiers != {} {
			record_text = video_clips_shortcut_display(Video_Clips_Shortcut{
				kind = .Character,
				key = "…",
				modifiers = ui.shortcut_live_modifiers,
			})
		}
		draw_text_in_rect(
			ctx,
			font,
			record_text,
			video_clips_shortcut_record_rect(),
			.Center,
			.Center,
			ui.shortcut_listening ? cyan : ink,
		)
		status := ui.shortcut_collision
		if len(status) == 0 {status = ui.shortcut_error}
		if len(status) > 0 {
			draw_text_in_rect(
				ctx,
				font,
				status,
				{modal.x+24, modal.y+64, modal.w-48, 18},
				.Start,
				.Center,
				danger,
			)
		}
		save_color := dim
		if ui.shortcut_candidate_valid &&
		   len(ui.shortcut_collision) == 0 {
			save_color = accent
		}
		draw_text_in_rect(
			ctx,
			font,
			"01  SAVE",
			video_clips_shortcut_action_rect(0),
			.Start,
			.Center,
			save_color,
			12,
		)
		draw_text_in_rect(
			ctx,
			font,
			"02  RESET DEFAULT",
			video_clips_shortcut_action_rect(1),
			.Start,
			.Center,
			ink,
			12,
		)
		draw_text_in_rect(
			ctx,
			font,
			"03  CANCEL",
			video_clips_shortcut_action_rect(2),
			.Start,
			.Center,
			muted,
			12,
		)
	}
}

build_playback_fullscreen_timeline_geometry :: proc(
	vertices: ^[dynamic]Solid_Vertex,
) {
	if !ui.playback_fullscreen_active ||
	   !ui.playback_fullscreen_controls_visible ||
	   state.player == nil ||
	   ui.player_duration <= 0 {
		return
	}
	timeline := ui_control_rect(.Source_Timeline)
	if timeline.w <= 0 || timeline.h <= 0 {return}
	seconds, has_seconds := current_seconds()
	if !has_seconds {return}
	completed, thumb := playback_timeline_geometry(
		timeline,
		playback_timeline_progress(seconds, ui.player_duration),
	)
	accent := ui_color_32(
		workflow_accent_color(ui.workflow, ui_theme_is_dark(ui.theme)),
	)
	push_rect(vertices, completed, accent, "fullscreen-timeline")
	push_rect(vertices, thumb, accent, "fullscreen-timeline")
}

draw_playback_fullscreen_transport :: proc(
	ctx, font: rawptr,
	bright, muted, dim, accent, cyan: [4]f64,
) {
	if !ui.playback_fullscreen_controls_visible || state.player == nil {return}
	theme := ui_theme_colors()
	player := playback_fullscreen_transport_rect()
	transport := player_transport_layout(player)
	background := theme.header
	background[3] = 0.92
	fill_overlay_rect(ctx, player, background)

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
		if kind == .Source_Reset && rect.w == 0 {
			rect = ui_control_rect(.Source_Hint_Menu)
		}
		if rect.w <= 0 {continue}
		color := theme.field
		color[3] = 0.94
		if contains(rect, ui.mouse) {color = theme.row_hover}
		fill_overlay_rect(ctx, rect, color)
	}
	playing := playback_actively_playing()
	draw_text_in_rect(
		ctx,
		font,
		playing ? "PAUSE" : "PLAY",
		ui_control_rect(.Source_Play_Pause),
		.Center,
		.Center,
		playing ? accent : cyan,
	)
	draw_text_in_rect(
		ctx,
		font,
		"STOP",
		ui_control_rect(.Source_Stop),
		.Center,
		.Center,
		muted,
	)
	hint_control := Source_Hint_Control.Reset
	if ui.source_playback_active {
		hint_control = source_hint_control(source_hint_count(state.active_source))
	}
	if hint_control == .Reset || !ui.source_playback_active {
		draw_text_in_rect(
			ctx,
			font,
			"RESET",
			ui_control_rect(.Source_Reset),
			.Center,
			.Center,
			muted,
		)
	} else if hint_control == .Menu {
		draw_timestamp_text_in_rect(
			ctx,
			font,
			format_timestamp(source_initial_seconds(state.active_source)),
			ui_control_rect(.Source_Hint_Menu),
			.Center,
			.Center,
			cyan,
		)
	}
	draw_text_in_rect(
		ctx,
		font,
		"-",
		ui_control_rect(.Speed_Down),
		.Center,
		.Center,
		ui.playback_rate <= 0.1 ? dim : cyan,
	)
	draw_text_in_rect(
		ctx,
		font,
		fmt.tprintf("SPEED %.1fx", ui.playback_rate),
		transport.speed_value,
		.Center,
		.Center,
		cyan,
	)
	draw_text_in_rect(
		ctx,
		font,
		"+",
		ui_control_rect(.Speed_Up),
		.Center,
		.Center,
		ui.playback_rate >= 2 ? dim : cyan,
	)
	draw_text_in_rect(
		ctx,
		font,
		"-",
		ui_control_rect(.Volume_Down),
		.Center,
		.Center,
		ui.player_volume <= 0 ? dim : cyan,
	)
	draw_text_in_rect(
		ctx,
		font,
		fmt.tprintf("VOL %d%%", volume_percent(ui.player_volume)),
		transport.volume_value,
		.Center,
		.Center,
		cyan,
	)
	draw_text_in_rect(
		ctx,
		font,
		"+",
		ui_control_rect(.Volume_Up),
		.Center,
		.Center,
		ui.player_volume >= 1 ? dim : cyan,
	)
	timestamp_rect := transport.timestamp
	if seconds, ok := current_seconds(); ok {
		draw_timestamp_text_in_rect(
			ctx,
			font,
			fmt.tprintf(
				"%s / %s",
				format_timestamp(seconds),
				format_timestamp(ui.player_duration),
			),
			timestamp_rect,
			.Start,
			.Center,
			cyan,
		)
	}
	if !active_player_has_audio() {
		warning := ui_theme_is_dark(ui.theme) ? UI_COLOR_COFFEE_64 : UI_COLOR_OCHRE_64
		draw_text_in_rect(
			ctx,
			font,
			"NO AUDIO TRACK",
			transport.ready_status,
			.Start,
			.Center,
			warning,
		)
	}
	icon_control := player_fullscreen_toggle_control()
	if icon_control != nil {
		if contains(icon_control.rect, ui.mouse) {
			fill_overlay_rect(ctx, icon_control.rect, theme.row_hover)
		}
		code, has_code := numbered_action_code_for_action(
			ui.mode,
			PLAYBACK_FULLSCREEN_ACTION_INDEX,
		)
		if has_code {
			draw_text_in_rect(
				ctx,
				font,
				fmt.tprintf("%d%d", code.section, code.action),
				{icon_control.rect.x-30, icon_control.rect.y, 26, icon_control.rect.h},
				.End,
				.Center,
				muted,
			)
		}
		draw_player_fullscreen_icon(
			ctx,
			icon_control.rect,
			bright,
			true,
		)
	}
}

build_overlay_commands :: proc(modal_only := false) {
	previous_lookup := ui_base_control_lookup
	ui_base_control_lookup = !modal_only
	defer ui_base_control_lookup = previous_lookup

	ctx := rawptr(uintptr(1))
	small_font := system_monospaced_font(SMALL_FONT_SIZE * ui.scale)
	assert_foreign(small_font, "Unable to create the small UI font")
	count_font := system_monospaced_font(96 * ui.scale)
	assert_foreign(count_font, "Unable to create the count-in font")
	defer foreign_release(small_font, "CTFont", "build_overlay_commands")
	defer foreign_release(count_font, "CTFont", "build_overlay_commands")
	s := ui.scale
	theme := ui_theme_colors()
	ink := theme.ink
	bright := theme.bright
	muted := theme.muted
	dim := theme.dim
	dark_theme := ui_theme_is_dark(ui.theme)
	accent := workflow_accent_color(ui.workflow, dark_theme)
	warning := dark_theme ? UI_COLOR_COFFEE_64 : UI_COLOR_OCHRE_64
	success := UI_COLOR_MOSS_64
	cyan := dark_theme ? UI_COLOR_GUM_64 : UI_COLOR_FOREST_64
	danger := warning

	_, _, source_search, source_panel, player, transcript, clip_search, clip_panel, clip_name, pitch_panel, _ :=
		layout_rects()

	if !modal_only && ui.playback_fullscreen_active {
		draw_playback_fullscreen_transport(
			ctx,
			small_font,
			bright,
			muted,
			dim,
			accent,
			cyan,
		)
		if ui.count_in_active && count_font != nil {
			draw_text_in_rect(
				ctx,
				count_font,
				fmt.tprintf("%d", ui.count_in_value),
				{0, 0, ui.width, ui.height},
				.Center,
				.Center,
				accent,
			)
		}
	} else if !modal_only {
	draw_header_identity(
		ctx,
		small_font,
		app_title_rect(),
		bright,
		accent,
	)
	mode_rect := ui_control_rect(.Mode_Toggle)
	workflow_rect := ui_control_rect(.Workflow_Toggle)
	draw_text_in_rect(
		ctx,
		small_font,
		workflow_switch_label(ui.workflow),
		workflow_rect,
		.Center,
		.Center,
		accent,
	)
	draw_text_in_rect(
		ctx,
		small_font,
		workspace_switch_label(ui.mode),
		mode_rect,
		.Center,
		.Center,
		accent,
	)
	source_header := UI_Rect {
		source_panel.x,
		source_panel.y + source_panel.h - 35,
		source_panel.w,
		35,
	}
	player_header := UI_Rect{player.x, player.y + player.h - 35, player.w, 35}
	transcript_header := UI_Rect{transcript.x, transcript.y + transcript.h - 35, transcript.w, 35}
	clip_header := UI_Rect {
		clip_panel.x,
		clip_panel.y + clip_panel.h - 35,
		clip_panel.w,
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
		draw_text_in_rect(ctx, small_font, "ADD", add_rect, .Center, .Center, add_enabled ? accent : dim)
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
			"04 / CLIP OUTPUT",
			UI_Rect{clip_header.x, clip_header.y, 158, clip_header.h},
			.Start,
			.Center,
			muted,
			10,
		)
	} else {
		draw_text_in_rect(
			ctx,
			small_font,
			"01 / CLIP LIBRARY",
			UI_Rect{clip_header.x, clip_header.y, 158, clip_header.h},
			.Start,
			.Center,
			muted,
			10,
		)
		draw_text_in_rect(
			ctx,
			small_font,
			fmt.tprintf("%03d SAVED", filtered_clip_count()),
			UI_Rect{clip_header.x + 164, clip_header.y, 92, clip_header.h},
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
		draw_editable_text_field(ctx, small_font, ui.source_search, "/ filter source register", ui_control_rect(.Source_Search), .Source_Search, ink, dim, accent)
		draw_editable_text_field(ctx, small_font, ui.transcript_search, "/ search timed transcript", ui_control_rect(.Transcript_Search), .Transcript_Search, ink, dim, accent)
		draw_editable_text_field(ctx, small_font, ui.clip_name, "NAME / optional designation", ui_control_rect(.Clip_Name), .Clip_Name, ink, dim, accent)
	} else {
		draw_editable_text_field(ctx, small_font, ui.clip_search, "/ filter clip library", ui_control_rect(.Clip_Search), .Clip_Search, ink, dim, accent)
		if ui.workflow == .Vocal {
			draw_pitch_monitor(
				ctx,
				small_font,
				pitch_panel,
				bright,
				muted,
				dim,
				accent,
				cyan,
			)
		} else {
			draw_dance_tools(
				ctx,
				small_font,
				pitch_panel,
				bright,
				muted,
				dim,
				accent,
				cyan,
			)
		}
	}

	if ui.mode == .Create {
		source_content := source_content_rect(source_search, source_panel)
		if ordered_overlay_active {
			framework_draw.push_clip(&ordered_draw, ordered_rect(source_content))
		} else {
			CGContextSaveGState(ctx)
			CGContextClipToRect(
				ctx,
				Rect {
					Point{source_content.x * s, source_content.y * s},
					Size{source_content.w * s, source_content.h * s},
				},
			)
		}
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
				if index == state.active_source {row_color = accent}
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
		if filtered_source_count() == 0 {
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
		if ordered_overlay_active {
			framework_draw.pop_clip(&ordered_draw)
		} else {
			CGContextRestoreGState(ctx)
		}
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
		transport := player_transport_layout(player)
		volume_down := ui_control_rect(.Volume_Down)
		playing := playback_actively_playing()
		draw_text_in_rect(ctx, small_font, playing ? "PAUSE" : "PLAY", ui_control_rect(.Source_Play_Pause), .Center, .Center, playing ? accent : cyan)
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
		draw_text_in_rect(ctx, small_font, fmt.tprintf("SPEED %.1fx", ui.playback_rate), transport.speed_value, .Center, .Center, cyan)
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
			transport.volume_value,
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
		timestamp_rect := transport.timestamp
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
			!active_player_has_audio() ? "NO AUDIO TRACK" : (ui.source_playback_active ? "MEDIA READY" : "CLIP READY"),
			transport.ready_status,
			.Start,
			.Center,
			!active_player_has_audio() ? warning : cyan,
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
		if fullscreen_control := player_fullscreen_toggle_control();
		   fullscreen_control != nil {
			icon_color := muted
			if contains(fullscreen_control.rect, ui.mouse) {icon_color = bright}
			draw_player_fullscreen_icon(
				ctx,
				fullscreen_control.rect,
				icon_color,
				false,
			)
		}
	} else if ui.active_clip >= 0 && ui.active_clip < len(state.clips) {
		clip := &state.clips[ui.active_clip]
		metadata := UI_Rect{player.x, player.y, player.w, 30}
		name_rect := UI_Rect{metadata.x, metadata.y, min(280, max(0, metadata.w - 160)), metadata.h}
		draw_text_in_rect(
			ctx,
			small_font,
			clip.name,
			name_rect,
			.Start,
			.Center,
			ink,
			10,
		)
		draw_timestamp_text_in_rect(
			ctx,
			small_font,
			format_timestamp(clip.end_seconds - clip.start_seconds),
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
			"NO CLIP SELECTED",
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
			"SELECT A CLIP FROM THE LIBRARY",
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
	if ui.count_in_active && count_font != nil {
		player_content := player_content_rect(player)
		draw_text_in_rect(
			ctx,
			count_font,
			fmt.tprintf("%d", ui.count_in_value),
			player_content,
			.Center,
			.Center,
			accent,
		)
	}

	if ui.mode == .Create {
		transcript_content := transcript_content_rect(transcript)
		if ordered_overlay_active {
			framework_draw.push_clip(&ordered_draw, ordered_rect(transcript_content))
		} else {
			CGContextSaveGState(ctx)
			CGContextClipToRect(
				ctx,
				Rect {
					Point{transcript_content.x * s, transcript_content.y * s},
					Size{transcript_content.w * s, transcript_content.h * s},
				},
			)
		}
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
						active ? accent : ink,
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
		if ordered_overlay_active {
			framework_draw.pop_clip(&ordered_draw)
		} else {
			CGContextRestoreGState(ctx)
		}

		output_commit := find_ui_control(ui_control_id("commit clip output"))
		output_top := clip_name.y - 8
		if output_commit != nil {
			output_top = output_commit.rect.y - 8
			commit_color := dim
			if .Enabled in output_commit.flags {commit_color = accent}
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
			clip_panel.x + 6,
			clip_panel.y + 8,
			clip_panel.w - 12,
			max(0, output_top - clip_panel.y - 8),
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
		clip_content := clip_content_rect(clip_search, clip_panel, clip_name)
		if ordered_overlay_active {
			framework_draw.push_clip(&ordered_draw, ordered_rect(clip_content))
		} else {
			CGContextSaveGState(ctx)
			CGContextClipToRect(
				ctx,
				Rect {
					Point{clip_content.x * s, clip_content.y * s},
					Size{clip_content.w * s, clip_content.h * s},
				},
			)
		}
		row := UI_Rect {
			clip_content.x,
			clip_content.y + clip_content.h - 29 + ui.clip_scroll,
			clip_content.w,
			29,
		}
		clip_index := 1
		for clip, index in state.clips {
			if !clip_matches_filter(clip, ui.clip_search) {continue}
			control := find_ui_control_by_action_and_index(.Clip, index)
			if control != nil {
				row = control.rect
				row_color := ink
				if index == ui.active_clip {row_color = accent}
				draw_text_in_rect(
					ctx,
					small_font,
					fmt.tprintf("E%02d", clip_index),
					UI_Rect{row.x + 8, row.y, 34, row.h},
					.Start,
					.Center,
					muted,
				)
				draw_text_in_rect(
					ctx,
					small_font,
					clip.name,
					UI_Rect{row.x + 46, row.y, row.w - 52, row.h},
					.Start,
					.Center,
					row_color,
				)
			}
			row.y -= 30
			clip_index += 1
		}
		if filtered_clip_count() == 0 {
			draw_text_in_rect(
				ctx,
				small_font,
				"E00  LIBRARY EMPTY",
				UI_Rect {
					clip_content.x,
					clip_content.y + clip_content.h - 29,
					clip_content.w,
					29,
				},
				.Start,
				.Center,
				dim,
				8,
			)
		}
		if ordered_overlay_active {
			framework_draw.pop_clip(&ordered_draw)
		} else {
			CGContextRestoreGState(ctx)
		}
	}

	labels := [20]string {
		"MARK IN",
		"MARK OUT",
		"COMMIT",
		"PLAY",
		"PAUSE",
		"CAPTIONS",
		"AUDITION",
		"DATA",
		"RENAME",
		"METADATA",
		"RANDOMIZE",
		"PITCH",
		"PLAY NEXT",
		"SHUFFLE",
		"AUTOPLAY",
		"MIRROR",
		"LOOP",
		"COUNT-IN",
		"COUNT EACH LOOP",
		"FULLSCREEN",
	}
	control_kinds := [20]UI_Action_Kind{.Start, .End, .Save, .Play, .Pause, .Captions, .Preview, .Data, .Rename, .Metadata, .Randomize, .Pitch_Toggle, .Play_Next, .Shuffle_Toggle, .Autoplay_Toggle, .Dance_Mirror_Toggle, .Dance_Loop_Toggle, .Dance_Count_In, .Dance_Count_Each_Loop_Toggle, .Playback_Fullscreen_Toggle}
	valid_range := active_clip_range_is_valid()
	for label, i in labels {
		button_label := label
		if control_kinds[i] == .Pitch_Toggle {
			button_label = ui.pitch.tracking ? "STOP PITCH" : "START PITCH"
		} else if control_kinds[i] == .Shuffle_Toggle {
			button_label = ui.clip_shuffle ? "SHUFFLE ON" : "SHUFFLE OFF"
		} else if control_kinds[i] == .Autoplay_Toggle {
			button_label = ui.clip_autoplay ? "AUTOPLAY ON" : "AUTOPLAY OFF"
		} else if control_kinds[i] == .Dance_Mirror_Toggle {
			button_label = active_dance_clip_mirrored() ? "MIRROR ON" : "MIRROR OFF"
		} else if control_kinds[i] == .Dance_Loop_Toggle {
			button_label = active_dance_clip_looping() ? "LOOP ON" : "LOOP OFF"
		} else if control_kinds[i] == .Dance_Count_In {
			button_label = dance_count_in_action_label()
		} else if control_kinds[i] == .Dance_Count_Each_Loop_Toggle {
			button_label = active_dance_clip_counts_each_loop() ? "LOOP COUNT ON" : "LOOP COUNT OFF"
		} else if control_kinds[i] == .Playback_Fullscreen_Toggle {
			button_label = ui.playback_fullscreen_active ? "EXIT FULLSCREEN" : "FULLSCREEN"
		}
		rect := ui_control_rect(control_kinds[i])
		code, has_code := numbered_action_code_for_action(ui.mode, i)
		if !has_code {continue}
		draw_text_in_rect(
			ctx,
			small_font,
			fmt.tprintf("%d%d", code.section, code.action),
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
			button_color = accent
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
	   .Play {range_text = fmt.tprintf("LIBRARY / %03d CLIPS", filtered_clip_count())}
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
	if !ui.playback_fullscreen_active &&
	   len(notification_history.footer_task_ids) > 0 {
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
			card_accent := muted
			text_color := muted
			switch notification.kind {
			case .Activity:
				fill = [4]f64{0.120, 0.045, 0.018, 0.88}
				if ui.workflow == .Dancing {
					fill = [4]f64{0.025, 0.070, 0.120, 0.88}
				}
				card_accent = accent
				text_color = bright
			case .Success:
				fill = [4]f64{0.025, 0.095, 0.065, 0.88}
				card_accent = success
				text_color = success
			case .Error, .Interrupted:
				fill = [4]f64{0.14, 0.025, 0.025, 0.88}
				card_accent = danger
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
			fill_overlay_rect(ctx, UI_Rect{card.x, card.y, 3, card.h}, card_accent)
			has_stop :=
				import_job_for_notification(notification_id) != nil ||
				export_job_for_notification(notification_id) != nil ||
				(source_probe_job != nil &&
				 source_probe_job.notification_id == notification_id) ||
				(library_replacement_job != nil &&
				 library_replacement_job.notification_id == notification_id)
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
				action_color := theme.field
				action_accent := cyan
				action_text := "VIEW SOURCE"
				if has_stop {
					action_accent = warning
					action_text = "STOP"
				}
				if contains(action, ui.mouse) {action_color = theme.row_hover}
				fill_overlay_rect(ctx, action, action_color)
				fill_overlay_border(ctx, action, action_accent)
				draw_text_in_rect(
					ctx,
					small_font,
					action_text,
					action,
					.Center,
					.Center,
					action_accent,
				)
			}
		}
		if task_layout.hidden_count > 0 {
			overflow := task_layout.overflow_rect
			overflow_fill := theme.field
			if contains(overflow, ui.mouse) {overflow_fill = theme.row_hover}
			fill_overlay_rect(ctx, overflow, overflow_fill)
			fill_overlay_rect(ctx, UI_Rect{overflow.x, overflow.y, 3, overflow.h}, accent)
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
	} else if !ui.playback_fullscreen_active {
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
			button_color := theme.field
			if contains(view_source, ui.mouse) {button_color = theme.row_hover}
			fill_overlay_rect(ctx, view_source, button_color)
			fill_overlay_border(ctx, view_source, cyan)
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
	}
	draw_source_details(ctx, small_font, bright, muted, cyan)
	draw_clip_rename(ctx, small_font, bright, muted, dim, accent)
	draw_clip_metadata(ctx, small_font, bright, muted, dim, cyan, danger)
	draw_randomize_help(ctx, small_font, bright, muted, dim, cyan)
	draw_pitch_help(ctx, small_font, bright, muted, cyan)
	draw_data_modal(ctx, small_font, bright, muted, dim, warning, cyan)
	draw_notification_history(
		ctx,
		small_font,
		bright,
		muted,
		dim,
		accent,
		cyan,
		danger,
		success,
	)

	if ui.source_modal_open {
		modal := source_modal_rect()
		refetching := ui.source_modal_refetch_index >= 0
		show_url := refetching || ui.source_add_mode == .URL
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
			refetching ? "REFETCH SOURCE / SELECT QUALITY" : (show_url ? "ADD SOURCE / YOUTUBE URL" : "ADD SOURCE / LOCAL FILES"),
			UI_Rect{modal.x + 20, modal.y + modal.h - 50, modal.w - 40, 50},
			.Start,
			.Center,
			bright,
		)
		if !refetching {
			modes := [2]Source_Add_Mode{.URL, .Local_Files}
			for mode in modes {
				tab := source_modal_mode_rect(modal, mode)
				selected := mode == ui.source_add_mode
				fill_overlay_rect(ctx, tab, selected ? theme.row_hover : theme.field)
				if selected {fill_overlay_border(ctx, tab, accent)}
			draw_text_in_rect(ctx, small_font, mode == .URL ? "YOUTUBE URL" : "LOCAL FILES", tab, .Center, .Center, selected ? accent : muted)
			}
		}
		draw_text_in_rect(
			ctx,
			small_font,
			show_url ? "Paste one or more YouTube URLs, with one URL per line." : "Choose local videos or drop video files into the app.",
			UI_Rect{modal.x + 24, modal.y + modal.h - 150, modal.w - 48, 22},
			.Start,
			.Center,
			muted,
		)
		draw_text_in_rect(
			ctx,
			small_font,
			show_url ? "Examples: ?t=1m30s  /  ?start=90  /  youtu.be/VIDEO?t=45" : "Files are copied into the managed library and normalized only when required.",
			UI_Rect{modal.x + 24, modal.y + modal.h - 174, modal.w - 48, 22},
			.Start,
			.Center,
			cyan,
		)
		if show_url {
		fill_overlay_rect(ctx, input, theme.field)
		if ui.focus == .URL && ui.source_modal_refetch_index < 0 {
			fill_overlay_border(ctx, input, accent)
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
						accent,
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
							save_color = cyan
						} else if contains(save_control, ui.mouse) {
							save_fill = theme.row_hover
						}
						fill_overlay_rect(ctx, save_control, save_fill)
						if ui.save_source_browser_choice {
							fill_overlay_border(ctx, save_control, cyan)
						}
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
							fill := theme.field
							if contains(control, ui.mouse) {fill = theme.row_hover}
							fill_overlay_rect(ctx, control, fill)
							fill_overlay_border(ctx, control, cyan)
							draw_text_in_rect(
								ctx,
								small_font,
								source_auth_browser_name(browser),
								control,
								.Center,
								.Center,
								cyan,
							)
						}
					} else {
						draw_text_in_rect(ctx, small_font, fmt.tprintf("%s / %s", result.video_id, result.error), UI_Rect{row.x + 10, row.y, row.w - 20, row.h}, .Start, .Center, danger, 10)
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
					fill_overlay_rect(ctx, quality, theme.field)
					if selected {fill_overlay_border(ctx, quality, cyan)}
					draw_text_in_rect(ctx, small_font, fmt.tprintf("%dp", height), quality, .Center, .Center, selected ? cyan : muted)
				}
			}
		}
		} else {
			drop := source_local_drop_rect(modal)
			browse := ui_control_rect(.Browse_Source_Files)
			fill_overlay_rect(ctx, drop, theme.field)
			fill_overlay_border(ctx, drop, contains(drop, ui.mouse) ? accent : theme.row_hover)
			draw_text_in_rect(ctx, small_font, "DROP VIDEO FILES", UI_Rect{drop.x+24, drop.y+48, drop.w-244, 28}, .Start, .Center, bright)
			draw_text_in_rect(ctx, small_font, "MP4, MOV, M4V, and other FFmpeg-readable video", UI_Rect{drop.x+24, drop.y+22, drop.w-244, 24}, .Start, .Center, muted)
			fill_overlay_rect(ctx, browse, contains(browse, ui.mouse) ? theme.row_hover : theme.field)
			fill_overlay_border(ctx, browse, accent)
			draw_text_in_rect(ctx, small_font, "BROWSE FILES…", browse, .Center, .Center, accent)
		if len(source_local_paths) > 0 {
			for path, index in source_local_paths {
				if index >= 4 {break}
				row := source_local_row_rect(modal, index)
				title_rect := source_local_title_rect(modal, index)
				fill_overlay_rect(ctx, row, theme.row)
				draw_text_in_rect(
					ctx,
					small_font,
					fmt.tprintf("LOCAL / %s", filepath.base(path)),
					UI_Rect{row.x + 8, row.y, row.w*0.40, row.h},
					.Start,
					.Center,
					muted,
				)
				fill_overlay_rect(ctx, title_rect, theme.field)
				if ui.focus == .Local_Source_Title && ui.local_source_title_index == index {
					draw_editable_text_field(ctx, small_font, source_local_titles[index], "", title_rect, .Local_Source_Title, ink, dim, accent)
				} else {
					draw_text_in_rect(ctx, small_font, source_local_titles[index], UI_Rect{title_rect.x+8, title_rect.y, title_rect.w-16, title_rect.h}, .Start, .Center, ink)
				}
				remove := ui_control_rect_by_value(.Remove_Local_Source, index, 0)
				fill_overlay_rect(ctx, remove, contains(remove, ui.mouse) ? theme.row_hover : theme.field)
				draw_text_in_rect(ctx, small_font, "×", remove, .Center, .Center, muted)
			}
		}
		}
		cancel_color := theme.panel_alt
		if contains(cancel, ui.mouse) {cancel_color = theme.row_hover}
		fill_overlay_rect(ctx, cancel, cancel_color)
		draw_text_in_rect(ctx, small_font, "CANCEL", cancel, .Center, .Center, muted)
		refetch := refetching
		confirm_color := theme.panel_alt
		confirm_border := refetch ? UI_COLOR_COFFEE_64 : accent
		confirm_text := confirm_border
		if contains(confirm, ui.mouse) {confirm_color = theme.row_hover}
		fill_overlay_rect(ctx, confirm, confirm_color)
		fill_overlay_border(ctx, confirm, confirm_border)
		draw_text_in_rect(
			ctx,
			small_font,
			refetching ? "REFETCH" : (show_url ? "ADD URL" : "ADD FILES"),
			confirm,
			.Center,
			.Center,
			confirm_text,
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
	if modal_only {
		draw_settings_overlays(
			ctx,
			small_font,
			ink,
			bright,
			muted,
			dim,
			accent,
			cyan,
			danger,
		)
		draw_command_palette(ctx, small_font, bright, muted, dim, accent, cyan, danger)
		draw_discard_confirmation(ctx, small_font, bright, muted, warning)
		draw_library_recovery(
			ctx,
			small_font,
			bright,
			muted,
			dim,
			warning,
			cyan,
			danger,
		)
		draw_backup_warning(ctx, small_font, bright, muted, warning, danger)
	}
	if !modal_only && !ui.playback_fullscreen_active {draw_window_controls(ctx)}
	if modal_only {draw_flash_hints(ctx, small_font)}
}

append_solid_vertices_to_ordered :: proc(vertices: []Solid_Vertex) {
	when ODIN_DEBUG {
		assert(len(vertices)%6 == 0, "solid geometry must contain complete quads")
	}
	for start := 0; start+5 < len(vertices); start += 6 {
		first := vertices[start]
		second := vertices[start+1]
		fourth := vertices[start+5]
		point := proc(vertex: Solid_Vertex) -> Point {
			return {
				(f64(vertex.x)+1)*ui.width/2,
				(f64(vertex.y)+1)*ui.height/2,
			}
		}
		p0, p1, p3 := point(first), point(second), point(fourth)
		x_dx, x_dy := p1.x-p0.x, p1.y-p0.y
		y_dx, y_dy := p3.x-p0.x, p3.y-p0.y
		width := math.sqrt(x_dx*x_dx+x_dy*x_dy)
		height := math.sqrt(y_dx*y_dx+y_dy*y_dy)
		if width <= 0 || height <= 0 {continue}
		framework_draw.push_transform(
			&ordered_draw,
			{
				f32(x_dx/width),
				f32(x_dy/width),
				f32(y_dx/height),
				f32(y_dy/height),
				f32(p0.x),
				f32(p0.y),
			},
		)
		framework_draw.solid(
			&ordered_draw,
			{0, 0, f32(width), f32(height)},
			{first.r, first.g, first.b, first.a},
		)
		framework_draw.pop_transform(&ordered_draw)
	}
}

append_video_to_ordered :: proc() {
	_, _, _, _, player, _, _, _, _, _, _ := layout_rects()
	player_rect := player_content_rect(player)
	if ui.playback_fullscreen_active {
		player_rect = {0, 0, ui.width, ui.height}
	}
	video_texture, video_width, video_height, fresh_video_frame :=
		current_video_texture()
	if fresh_video_frame {complete_video_frame_refresh()}
	if video_texture == nil {return}
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
		pipeline = "ordered-ui",
		texture = "video",
		mirrored = mirrored,
		timestamp_seconds = seconds,
	)
	handle := framework_metal.register_texture(
		&ordered_renderer,
		rawptr(video_texture),
	)
	source := video_texture_source_rect(mirrored)
	framework_draw.image(
		&ordered_draw,
		handle,
		ordered_rect(draw_rect),
		source,
		label = "video",
	)
}

video_texture_source_rect :: proc(mirrored := false) -> framework_draw.Rect {
	if mirrored {return {1, 1, -1, -1}}
	return {0, 1, 1, -1}
}

build_ordered_frame :: proc(
	vertices: []Solid_Vertex,
	fullscreen_timeline: []Solid_Vertex,
) -> bool {
	if !ordered_ui_ready {return false}
	framework_metal.begin_texture_frame(&ordered_renderer)
	framework_coretext.begin_frame(
		&ordered_text,
		f32(ui.scale),
		framework_metal.atlas_io(&ordered_renderer),
	)
	framework_draw.list_reset(&ordered_draw)
	append_solid_vertices_to_ordered(vertices)
	append_video_to_ordered()
	ordered_overlay_active = true
	build_overlay_commands(false)
	build_overlay_commands(true)
	ordered_overlay_active = false
	append_solid_vertices_to_ordered(fullscreen_timeline)
	framework_coretext.flush(&ordered_text)
	ui.overlay_revision += 1
	return true
}

global_modal_blocks_commands :: proc() -> bool {
	return library_recovery_state.required || major_change_pending.open
}

ui_action_enabled_for_current_job :: proc(kind: UI_Action_Kind) -> bool {
	if kind == .Command_Palette_Disabled {return false}
	if kind == .Open_Settings ||
	   kind == .Configure_Flash ||
	   kind == .Shortcut_Record ||
	   kind == .Set_Theme {
		return video_clips_settings_commands_available()
	}
	if kind == .Shortcut_Save {
		return ui.shortcut_candidate_valid &&
		       len(ui.shortcut_collision) == 0
	}
	if kind == .Workflow_Toggle || kind == .Mode_Toggle {
		return true
	}
	if kind == .Playback_Fullscreen_Toggle {
		return state.player != nil || ui.playback_fullscreen_active
	}
	if kind == .Activate_Notification_Action {
		return notification_action_available(notification_selected())
	}
	if kind == .Export_Library ||
	   kind == .Export_Current_Workflow ||
	   kind == .Import_Library {
		return !library_transfer_busy()
	}
	if kind == .Confirm_Library_Import {
		return !library_transfer_busy() && ui.library_import_pending
	}
	if kind == .Import {
		return !source_import_media_job_blocks()
	}
	if kind == .Start || kind == .End {
		return state.player != nil &&
		       state.active_source >= 0 &&
		       state.active_source < len(state.sources)
	}
	if kind == .Save {
		return !clip_save_media_job_blocks() &&
		       active_clip_range_is_valid()
	}
	if kind == .Preview {
		return !library_transfer_busy() &&
		       active_clip_range_is_valid()
	}
	if kind == .Randomize {
		return ui.mode == .Play && filtered_clip_count() > 0
	}
	if kind == .Play_Next {
		return ui.mode == .Play && filtered_clip_count() > 0
	}
	if kind == .Shuffle_Toggle || kind == .Autoplay_Toggle {
		return ui.mode == .Play
	}
	if kind == .Open_Randomize_Help {
		return ui.mode == .Play
	}
	if kind == .Pitch_Toggle {
		if ui.mode != .Play ||
		   ui.workflow != .Vocal ||
		   ui.pitch.permission_pending {
			return false
		}
		if ui.pitch.tracking {return true}
		return ui.pitch.permission != .Denied &&
		       ui.pitch.permission != .Restricted
	}
	if kind == .Pitch_Reference_Down {
		return ui.mode == .Play &&
		       ui.workflow == .Vocal &&
		       ui.pitch.settings.reference_hz > 400
	}
	if kind == .Pitch_Reference_Up {
		return ui.mode == .Play &&
		       ui.workflow == .Vocal &&
		       ui.pitch.settings.reference_hz < 480
	}
	if kind == .Pitch_Octaves_Down {
		return ui.mode == .Play &&
		       ui.workflow == .Vocal &&
		       ui.pitch.settings.octaves > 1
	}
	if kind == .Pitch_Octaves_Up {
		return ui.mode == .Play &&
		       ui.workflow == .Vocal &&
		       ui.pitch.settings.octaves < 6
	}
	if kind == .Pitch_Labels ||
	   kind == .Pitch_Transpose ||
	   kind == .Pitch_Highlight ||
	   kind == .Open_Pitch_Help {
		return ui.mode == .Play && ui.workflow == .Vocal
	}
	if kind == .Dance_Mirror_Toggle ||
	   kind == .Dance_Loop_Toggle ||
	   kind == .Dance_Count_In ||
	   kind == .Dance_Count_Each_Loop_Toggle {
		return active_dance_clip() != nil
	}
	if kind == .Dance_BPM_Down {
		if clip := active_dance_clip(); clip != nil {
			return clip.dance_count_in_bpm > 40
		}
		return false
	}
	if kind == .Dance_BPM_Up {
		if clip := active_dance_clip(); clip != nil {
			return clip.dance_count_in_bpm < 240
		}
		return false
	}
	if kind == .Close_Pitch_Help {
		return ui.pitch.help_open
	}
	if kind == .Rename || kind == .Metadata {
		return ui.active_clip >= 0 &&
		       ui.active_clip < len(state.clips)
	}
	if kind == .View_Clip_Source {
		if ui.clip_metadata_index < 0 ||
		   ui.clip_metadata_index >= len(state.clips) {
			return false
		}
		return source_index_for_clip(
			state.sources[:],
			state.clips[:],
			ui.clip_metadata_index,
		) >= 0
	}
	if kind == .Confirm_Clip_Rename {
		return ui.clip_rename_index >= 0 &&
		       ui.clip_rename_index < len(state.clips) &&
		       len(strings.trim_space(ui.clip_rename)) > 0
	}
	return true
}

validate_ui_controls :: proc() {
	when ODIN_DEBUG {
		assert(ui_controls_valid(ui_build.controls[:]), "UI controls must have unique names, unique identifiers, and visible rectangles")
	}
}

ui_rect_is_actionable :: proc(rect: UI_Rect) -> bool {
	return rect.w >= 1 && rect.h >= 1
}

ui_control_layer_for_build :: proc(kind: UI_Action_Kind) -> framework_ui.Layer {
	if ui_control_build_scope == .Base_Visual || ui_action_is_window(kind) {
		return .Base
	}
	if framework_modal_active() {return .Modal}
	return .Base
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
	if !ui_rect_is_actionable(rect) {return}
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
	case .Command_Palette_Search, .Settings_Search, .URL, .Source_Search, .Transcript_Search, .Clip_Search, .Clip_Name, .Clip_Rename:
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
		layer = ui_control_layer_for_build(kind),
	}
	append(&ui_build.controls, control)
	append_ax_element_for_control(array, element_class, &control)
}

add_pointer_control :: proc(
	functional_name: string,
	rect: UI_Rect,
	kind: UI_Action_Kind,
	flags: UI_Control_Flags,
) {
	if !ui_rect_is_actionable(rect) {return}
	control_flags := flags
	if ui_action_enabled_for_current_job(kind) {control_flags += {.Enabled}}
	append(&ui_build.controls, UI_Control{
		id = ui_control_id(functional_name),
		functional_name = functional_name,
		rect = rect,
		flags = control_flags,
		action = UI_Action{kind = kind},
		layer = ui_control_layer_for_build(kind),
	})
}

add_player_controls :: proc(
	array, element_class: Id,
	surface, player: UI_Rect,
	controls_visible: bool,
) {
	if state.player == nil {return}
	transport := player_transport_layout(player)
	playing := playback_actively_playing()
	media_name := ui.source_playback_active ? "source" : "clip"
	add_pointer_control(
		fmt.tprintf("toggle %s playback from player surface", media_name),
		surface,
		.Player_Surface,
		{.Primary_Press},
	)
	if !controls_visible {return}
	add_pointer_control(
		fmt.tprintf("scrub %s timeline", media_name),
		transport.timeline,
		.Source_Timeline,
		{.Primary_Press, .Drag},
	)
	add_ax_element(
		array,
		element_class,
		fmt.tprintf("%s %s", playing ? "Pause" : "Play", media_name),
		"AXButton",
		transport.play_pause,
		.Source_Play_Pause,
		flash_label = fmt.tprintf("play pause %s", media_name),
	)
	add_ax_element(
		array,
		element_class,
		fmt.tprintf("Stop %s and return to zero", media_name),
		"AXButton",
		transport.stop,
		.Source_Stop,
		flash_label = fmt.tprintf("stop %s", media_name),
	)
	hint_control := Source_Hint_Control.Reset
	if ui.source_playback_active {
		hint_control = source_hint_control(source_hint_count(state.active_source))
	}
	if hint_control == .Menu {
		add_ax_element(
			array,
			element_class,
			fmt.tprintf(
				"Source timestamp %s",
				format_timestamp(source_initial_seconds(state.active_source)),
			),
			"AXButton",
			transport.reset,
			.Source_Hint_Menu,
			flash_label = "select source timestamp",
		)
		if ui.source_hint_menu_open {
			values := source_hint_values(
				state.active_source,
				context.temp_allocator,
			)
			for seconds, option_index in values {
				add_ax_element(
					array,
					element_class,
					format_timestamp(seconds),
					"AXButton",
					source_hint_option_rect(
						player,
						option_index,
						len(values),
					),
					.Source_Hint,
					option_index,
					seconds,
					flash_label = "timestamp",
					functional_name = fmt.tprintf(
						"timestamp %s",
						format_timestamp(seconds),
					),
				)
			}
		}
	}
	reset_label := "Return to the imported source timestamp"
	reset_flash_label := "reset source timestamp"
	if !ui.source_playback_active {
		reset_label = "Return to the start of the clip"
		reset_flash_label = "reset clip"
	}
	if hint_control == .Reset || !ui.source_playback_active {
		add_ax_element(
			array,
			element_class,
			reset_label,
			"AXButton",
			transport.reset,
			.Source_Reset,
			flash_label = reset_flash_label,
		)
	}
	add_ax_element(
		array,
		element_class,
		fmt.tprintf("Decrease %s playback speed", media_name),
		"AXButton",
		transport.speed_down,
		.Speed_Down,
		flash_label = "slower",
	)
	add_ax_element(
		array,
		element_class,
		fmt.tprintf("Increase %s playback speed", media_name),
		"AXButton",
		transport.speed_up,
		.Speed_Up,
		flash_label = "faster",
	)
	percent := volume_percent(ui.player_volume)
	add_ax_element(
		array,
		element_class,
		fmt.tprintf(
			"Decrease %s volume, %d percent",
			media_name,
			percent,
		),
		"AXButton",
		transport.volume_down,
		.Volume_Down,
		flash_label = "quieter",
	)
	add_ax_element(
		array,
		element_class,
		fmt.tprintf(
			"Increase %s volume, %d percent",
			media_name,
			percent,
		),
		"AXButton",
		transport.volume_up,
		.Volume_Up,
		flash_label = "louder",
	)
	fullscreen_label := "Enter full screen playback"
	if ui.playback_fullscreen_active {
		fullscreen_label = "Exit full screen playback"
	}
	add_ax_element(
		array,
		element_class,
		fullscreen_label,
		"AXButton",
		transport.fullscreen,
		.Playback_Fullscreen_Toggle,
		flash_label = "full screen playback",
		functional_name = "player full screen toggle",
	)
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
	if !ui.shortcut_open {
		add_ax_element(
			array,
			element_class,
			"Open Settings",
			"AXButton",
			settings_button_rect(),
			.Open_Settings,
			flash_label = "settings",
			functional_name = "settings",
		)
	}
}

finalize_ui_controls :: proc(
	allocator: runtime.Allocator,
	ax_array, element_class: Id,
) {
	validate_ui_controls()
	publish_shared_control_registry(allocator)
	if ax_array == nil {return}
	for index in 0 ..< len(ui_build.controls) {
		control := &ui_build.controls[index]
		shared_control := framework_ui.control_in_view(
			shared_registry,
			framework_ui.Key(control.id),
		)
		if shared_control == nil ||
		   .Accessibility not_in shared_control.capabilities {
			continue
		}
		append_ax_element_for_control(ax_array, element_class, control)
	}
}

finalize_ui_control_scope :: proc(
	scope: UI_Control_Build_Scope,
	allocator: runtime.Allocator,
	ax_array, element_class: Id,
) {
	if scope == .Active {
		finalize_ui_controls(allocator, ax_array, element_class)
	} else {
		validate_ui_controls()
	}
}

build_ui_controls_for_scope :: proc(
	rebuild_accessibility: bool,
	allocator: runtime.Allocator,
	scope: UI_Control_Build_Scope,
) {
	previous_temp := context.temp_allocator
	previous_scope := ui_control_build_scope
	context.temp_allocator = allocator
	ui_control_build_scope = scope
	ui_build.controls = make([dynamic]UI_Control, 0, 64, allocator)
	ui_build.base_controls = nil
	ui_build.diagnostic_surface = ui_diagnostic_surface(allocator)
	ui_build.frame = int(ui.frame_tick)
	array: Id
	ax_array: Id
	if rebuild_accessibility {
		clear(&ax_actions)
		if ui.ax_children != nil {msg_void(ui.ax_children, sel_registerName("release"))}
		temporary := msg_id(objc_getClass("NSMutableArray"), sel_registerName("array"))
		ui.ax_children = msg_id(temporary, sel_registerName("retain"))
		ax_array = temporary
	}
	element_class := objc_getClass("VocalAccessibilityElement")
	defer finalize_ui_control_scope(scope, allocator, ax_array, element_class)
	defer ui_control_build_scope = previous_scope
	defer context.temp_allocator = previous_temp
	import_field, import_button, source_search, source_panel, player, transcript, clip_search, clip_panel, clip_name, pitch_panel, controls :=
		layout_rects()
	if scope == .Active && !ui.playback_fullscreen_active {
		add_window_controls(array, element_class)
	}
	if scope == .Active && library_recovery_state.required {
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
	if scope == .Active && major_change_pending.open {
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
	if scope == .Active && ui.discard_confirm_open {
		add_ax_element(
			array,
			element_class,
			"Keep editing",
			"AXButton",
			discard_confirm_action_rect(0),
			.Discard_Keep_Editing,
			flash_label = "keep editing",
		)
		add_ax_element(
			array,
			element_class,
			"Discard unsaved changes",
			"AXButton",
			discard_confirm_action_rect(1),
			.Discard_Changes,
			flash_label = "discard changes",
		)
		validate_ui_controls()
		return
	}
	if scope == .Active && ui.shortcut_open {
		record := video_clips_shortcut_record_rect()
		if !ui.shortcut_listening {
			add_ax_element(
				array,
				element_class,
				"Record another Flash leader",
				"AXButton",
				record,
				.Shortcut_Record,
				flash_label = "record shortcut",
			)
		}
		save_enabled := ui.shortcut_candidate_valid &&
		                len(ui.shortcut_collision) == 0
		if save_enabled {
			add_ax_element(
				array,
				element_class,
				"01 Save Flash leader",
				"AXButton",
				video_clips_shortcut_action_rect(0),
				.Shortcut_Save,
				flash_label = "save shortcut",
			)
		} else {
			add_ax_element(
				array,
				element_class,
				"01 Save Flash leader, unavailable",
				"AXStaticText",
				video_clips_shortcut_action_rect(0),
				.Command_Palette_Disabled,
				flash_label = "save shortcut",
				functional_name = "shortcut save disabled",
			)
		}
		add_ax_element(
			array,
			element_class,
			"02 Reset Flash leader to slash",
			"AXButton",
			video_clips_shortcut_action_rect(1),
			.Shortcut_Reset,
			flash_label = "reset shortcut",
		)
		add_ax_element(
			array,
			element_class,
			"03 Cancel Flash leader configuration",
			"AXButton",
			video_clips_shortcut_action_rect(2),
			.Shortcut_Cancel,
			flash_label = "cancel shortcut",
		)
		validate_ui_controls()
		return
	}
	if scope == .Active && ui.settings_open {
		add_ax_element(
			array,
			element_class,
			"Search Settings",
			"AXTextField",
			video_clips_settings_search_rect(),
			.Settings_Search,
			flash_label = "search settings",
		)
		add_ax_element(
			array,
			element_class,
			"Close Settings",
			"AXButton",
			video_clips_settings_close_rect(),
			.Settings_Close,
			flash_label = "close settings",
		)
		categories := [2]Video_Clips_Settings_Category{.Styling, .Shortcuts}
		for category, index in categories {
			add_ax_element(
				array,
				element_class,
				fmt.tprintf(
					"Show %s settings",
					video_clips_settings_category_name(category),
				),
				"AXRadioButton",
				video_clips_settings_category_rect(index),
				.Settings_Category,
				index,
				flash_label = fmt.tprintf(
					"%s settings",
					video_clips_settings_category_name(category),
				),
				functional_name = fmt.tprintf(
					"settings category %s",
					video_clips_settings_category_name(category),
				),
			)
		}
		for descriptor, index in video_clips_settings_result_descriptors() {
			role := "AXButton"
			if descriptor.action.kind == .Set_Theme {role = "AXRadioButton"}
			add_ax_element(
				array,
				element_class,
				descriptor.title,
				role,
				video_clips_settings_result_rect(index),
				descriptor.action.kind,
				value = descriptor.action.value,
				flash_label = strings.to_lower(
					descriptor.title,
					context.temp_allocator,
				),
				functional_name = fmt.tprintf(
					"setting:%d",
					descriptor.id,
				),
			)
		}
		validate_ui_controls()
		return
	}
	if scope == .Active && ui.randomize_help_open {
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
	if scope == .Active && ui.pitch.help_open {
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
	if scope == .Active && ui.notification_modal_open {
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
	include_footer := scope == .Base_Visual ||
	                  !command_palette.is_open(&command_palette_state)
	if include_footer && !ui.playback_fullscreen_active &&
	   len(notification_history.footer_task_ids) > 0 {
		task_layout := footer_task_layout(
			ui.width,
			len(notification_history.footer_task_ids),
		)
		for task_index in 0 ..< task_layout.visible_count {
			notification_id := notification_history.footer_task_ids[task_index]
			notification := notification_find(notification_id)
			if notification == nil {continue}
			card := task_layout.task_rects[task_index]
			has_stop :=
				import_job_for_notification(notification_id) != nil ||
				export_job_for_notification(notification_id) != nil ||
				(source_probe_job != nil &&
				 source_probe_job.notification_id == notification_id) ||
				(library_replacement_job != nil &&
				 library_replacement_job.notification_id == notification_id)
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
					"Stop media task",
					"AXButton",
					footer_task_action_rect(card),
					.Stop_Download,
					int(notification_id),
					flash_label = "stop media task",
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
	} else if include_footer && !ui.playback_fullscreen_active {
		status_rect := footer_status_rect()
		if status_rect.w >= 1 {
			add_ax_element(
				array,
				element_class,
				"Open notification history",
				"AXButton",
				status_rect,
				.Open_Notification_History,
				flash_label = "notifications",
			)
		}
		if len(import_jobs) > 0 ||
		   len(export_jobs) > 0 ||
		   source_probe_job != nil ||
		   library_replacement_job != nil {
			notification_id: i64
			if len(import_jobs) > 0 {
				notification_id = import_jobs[0].notification_id
			} else if len(export_jobs) > 0 {
				notification_id = export_jobs[0].notification_id
			} else if source_probe_job != nil {
				notification_id = source_probe_job.notification_id
			} else {
				notification_id =
					library_replacement_job.notification_id
			}
			add_ax_element(
				array,
				element_class,
				"Stop media task",
				"AXButton",
				import_cancel_rect(),
				.Stop_Download,
				int(notification_id),
				flash_label = "stop media task",
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
	if scope == .Active && command_palette.is_open(&command_palette_state) {
		modal := command_palette_rect()
		add_ax_element(
			array,
			element_class,
			"Search commands, sources, and clips",
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
	if scope == .Active && ui.data_modal_open {
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
				"Export all library metadata",
				"AXButton",
				data_modal_action_rect(modal, 0),
				.Export_Library,
				flash_label = "export all",
			)
			add_ax_element(
				array,
				element_class,
				fmt.tprintf(
					"Export %s workflow metadata",
					ui.workflow == .Vocal ? "Vocal" : "Dancing",
				),
				"AXButton",
				data_modal_action_rect(modal, 1),
				.Export_Current_Workflow,
				flash_label = "export current workflow",
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
				"Open data folder",
				"AXButton",
				data_modal_action_rect(modal, 3),
				.Open_Data_Folder,
				flash_label = "open data folder",
			)
			add_ax_element(
				array,
				element_class,
				"Close library data",
				"AXButton",
				data_modal_action_rect(modal, 4),
				.Close_Data_Modal,
				flash_label = "close data",
			)
		}
		validate_ui_controls()
		return
	}
	if scope == .Active && ui.clip_metadata_open {
		modal := clip_metadata_modal_rect()
		add_ax_element(
			array,
			element_class,
			"Close clip metadata",
			"AXButton",
			clip_metadata_close_rect(modal),
			.Close_Clip_Metadata,
			flash_label = "close metadata",
		)
		add_ax_element(
			array,
			element_class,
			"View clip source",
			"AXButton",
			clip_metadata_source_rect(modal),
			.View_Clip_Source,
			flash_label = "view clip source",
		)
		validate_ui_controls()
		return
	}
	if scope == .Active && ui.clip_rename_open {
		modal := clip_rename_modal_rect()
		add_ax_element(
			array,
			element_class,
			"New clip name",
			"AXTextField",
			clip_rename_input_rect(modal),
			.Clip_Rename,
			flash_label = "new clip name",
		)
		add_ax_element(
			array,
			element_class,
			"Cancel clip rename",
			"AXButton",
			clip_rename_cancel_rect(modal),
			.Cancel_Clip_Rename,
			flash_label = "cancel rename",
		)
		add_ax_element(
			array,
			element_class,
			"Rename clip",
			"AXButton",
			clip_rename_confirm_rect(modal),
			.Confirm_Clip_Rename,
			flash_label = "confirm rename",
		)
		validate_ui_controls()
		return
	}
	if scope == .Active && ui.source_modal_open {
		refetching := ui.source_modal_refetch_index >= 0
		local_mode := !refetching && ui.source_add_mode == .Local_Files
		if !refetching {
			add_ax_element(array, element_class, "Use YouTube URL source input", "AXButton", source_modal_mode_rect(source_modal_rect(), .URL), .Source_Mode_URL, flash_label="youtube source mode")
			add_ax_element(array, element_class, "Use local file source input", "AXButton", source_modal_mode_rect(source_modal_rect(), .Local_Files), .Source_Mode_Local_Files, flash_label="local file source mode")
		}
		if !local_mode {
			add_ax_element(array, element_class, "YouTube URLs", "AXTextField", import_field, .URL, flash_label = "youtube urls")
		}
		modal := source_modal_rect()
		if local_mode {
			add_ax_element(
				array,
				element_class,
				"Browse for local video files",
				"AXButton",
				source_modal_browse_rect(modal),
				.Browse_Source_Files,
				flash_label = "browse source files",
			)
			for _, index in source_local_paths {
				if index >= 4 {break}
				add_ax_element(
					array,
					element_class,
					fmt.tprintf("Title for local source %d", index+1),
					"AXTextField",
					source_local_title_rect(modal, index),
					.Local_Source_Title,
					index,
					flash_label = "local source title",
				)
			}
		}
		if !local_mode {
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
	if scope == .Active && ui.source_details_open {
		modal := source_details_rect()
		source := &state.sources[ui.source_details_index]
		add_ax_element(array, element_class, "Close source details", "AXButton", source_details_close_rect(modal), .Close_Source_Details, flash_label = "close source details")
		if source.kind == .YouTube || !source.media_available {
			add_ax_element(array, element_class, source.kind == .Local ? "Locate original local video" : "Refetch and select quality", "AXButton", source_details_refetch_rect(modal), .Refetch_Source_Details, flash_label = source.kind == .Local ? "locate original" : "refetch quality")
		}
		validate_ui_controls()
		return
	}
	if ui.playback_fullscreen_active {
		add_player_controls(
			array,
			element_class,
			{0, 0, ui.width, ui.height},
			playback_fullscreen_transport_rect(),
			ui.playback_fullscreen_controls_visible,
		)
		validate_ui_controls()
		return
	}
	workflow_label := "Switch to Dancing workflow"
	if ui.workflow == .Dancing {workflow_label = "Switch to Vocal workflow"}
	add_ax_element(
		array,
		element_class,
		workflow_label,
		"AXButton",
		workflow_button_rect(),
		.Workflow_Toggle,
		flash_label = "switch workflow",
	)
	toggle_label := "Switch to Clips workspace"
	if ui.mode == .Play {toggle_label = "Switch to Sources workspace"}
	add_ax_element(
		array,
		element_class,
		toggle_label,
		"AXButton",
		mode_button_rect(),
		.Mode_Toggle,
		flash_label = "switch workspace",
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
			"Clip name",
			"AXTextField",
			clip_name,
			.Clip_Name,
			flash_label = "clip name",
		)
	} else {
		add_ax_element(
			array,
			element_class,
			"Filter clips",
			"AXTextField",
			clip_search,
			.Clip_Search,
			flash_label = "filter clips",
		)
		clip_content := clip_content_rect(clip_search, clip_panel, clip_name)
		row := UI_Rect {
			clip_content.x,
			clip_content.y + clip_content.h - 29 + ui.clip_scroll,
			clip_content.w,
			29,
		}
		for clip, index in state.clips {
			if !clip_matches_filter(clip, ui.clip_search) {continue}
			if row.y >= clip_content.y &&
			   row.y + row.h <= clip_content.y + clip_content.h {
				add_ax_element(
					array,
					element_class,
					clip.name,
					"AXButton",
					row,
					.Clip,
					index,
					flash_label = "select clip",
					functional_name = fmt.tprintf("select clip %s", clip.id),
				)
			}
			row.y -= 30
		}
		if ui.workflow == .Vocal {
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
		add_ax_element(
			array,
			element_class,
			"Decrease visible pitch octaves",
			"AXButton",
			pitch_octaves_rect(pitch_panel, 0),
			.Pitch_Octaves_Down,
			flash_label = "fewer pitch octaves",
		)
		add_ax_element(
			array,
			element_class,
			"Increase visible pitch octaves",
			"AXButton",
			pitch_octaves_rect(pitch_panel, 2),
			.Pitch_Octaves_Up,
			flash_label = "more pitch octaves",
		)
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
		} else {
			add_ax_element(
				array,
				element_class,
				"Decrease count-in BPM",
				"AXButton",
				dance_bpm_down_rect(pitch_panel),
				.Dance_BPM_Down,
				flash_label = "lower count in bpm",
			)
			add_ax_element(
				array,
				element_class,
				"Increase count-in BPM",
				"AXButton",
				dance_bpm_up_rect(pitch_panel),
				.Dance_BPM_Up,
				flash_label = "raise count in bpm",
			)
		}
	}
	kinds := [20]UI_Action_Kind{.Start, .End, .Save, .Play, .Pause, .Captions, .Preview, .Data, .Rename, .Metadata, .Randomize, .Pitch_Toggle, .Play_Next, .Shuffle_Toggle, .Autoplay_Toggle, .Dance_Mirror_Toggle, .Dance_Loop_Toggle, .Dance_Count_In, .Dance_Count_Each_Loop_Toggle, .Playback_Fullscreen_Toggle}
	labels := [20]string {
		"Set start",
		"Set end",
		"Save clip",
		"Play",
		"Pause",
		"Load captions",
		"Preview range",
		"Open library data",
		"Rename clip",
		"Show clip metadata",
		"Play a random clip",
		"Toggle pitch tracking",
		"Play the next filtered clip",
		"Toggle shuffled Play Next",
		"Toggle automatic Play Next",
		"Toggle horizontal mirror",
		"Toggle clip loop",
		"Cycle visual count in",
		"Toggle count in before each loop",
		"Enter full screen playback",
	}
	flash_labels := [20]string{"mark in", "mark out", "commit", "play", "pause", "captions", "audition", "data", "rename clip", "clip metadata", "randomize clip", "toggle pitch tracking", "play next clip", "toggle shuffle", "toggle autoplay", "toggle mirror", "toggle loop", "cycle count in", "toggle count each loop", "full screen playback"}
	slot_count := control_slot_count(ui.mode)
	for slot in 0 ..< slot_count {
		action_index := control_action_for_slot(ui.mode, slot)
		if action_index < 0 {continue}
		kind := kinds[action_index]
		rect := control_rect(controls, action_index)
		if kind == .Randomize {rect = randomize_primary_rect(controls)}
		if rect.w > 0 {
			accessibility_label := labels[action_index]
			role := "AXButton"
			if kind == .Shuffle_Toggle {
				role = "AXCheckBox"
				accessibility_label =
					ui.clip_shuffle ? "Shuffle on" : "Shuffle off"
			} else if kind == .Autoplay_Toggle {
				role = "AXCheckBox"
				accessibility_label =
					ui.clip_autoplay ? "Autoplay on" : "Autoplay off"
			} else if kind == .Dance_Mirror_Toggle {
				role = "AXCheckBox"
				accessibility_label = active_dance_clip_mirrored() ? "Mirror on" : "Mirror off"
			} else if kind == .Dance_Loop_Toggle {
				role = "AXCheckBox"
				accessibility_label = active_dance_clip_looping() ? "Loop on" : "Loop off"
			} else if kind == .Dance_Count_Each_Loop_Toggle {
				role = "AXCheckBox"
				accessibility_label = active_dance_clip_counts_each_loop() ? "Count before each loop on" : "Count before each loop off"
			}
			add_ax_element(
				array,
				element_class,
				accessibility_label,
				role,
				rect,
				kind,
				flash_label = flash_labels[action_index],
			)
		}
	}
	add_player_controls(array, element_class, player, player, true)
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
			"Save clip",
			"AXButton",
			clip_output_commit_rect(clip_name),
			.Save,
			flash_label = "commit",
			functional_name = "commit clip output",
		)
	}
}

build_ui_controls :: proc(
	rebuild_accessibility: bool,
	allocator := context.allocator,
) {
	previous_lookup := ui_base_control_lookup
	ui_base_control_lookup = false
	defer ui_base_control_lookup = previous_lookup

	build_ui_controls_for_scope(
		rebuild_accessibility,
		allocator,
		.Active,
	)
	if !framework_modal_active() {
		ui_build.base_controls = ui_build.controls
		return
	}

	active_build := ui_build
	active_registry := shared_registry
	build_ui_controls_for_scope(false, allocator, .Base_Visual)
	base_controls := ui_build.controls
	ui_build = active_build
	ui_build.base_controls = base_controls
	shared_registry = active_registry
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
	if ui.playback_fullscreen_active &&
	   !ui.playback_fullscreen_controls_visible {
		playback_fullscreen_show_controls()
		if ui.layer != nil && ui.width > 0 && ui.height > 0 {
			render_frame()
		}
	}
	targets := make(
		[dynamic]flash.Target,
		0,
		len(shared_registry.controls),
		context.temp_allocator,
	)
	for &control in shared_registry.controls {
		if .Flash not_in control.capabilities || !control.enabled {continue}
		append(&targets, flash.Target{
			id = flash.Target_ID(control.id),
			label = control.flash_label,
			rect = flash.Rect{
				f64(control.rect.x),
				f64(control.rect.y),
				f64(control.rect.w),
				f64(control.rect.h),
			},
			anchor = flash_anchor_from_framework(control.flash_anchor),
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
	activation, activated := framework_ui.activate_control_in_view(
		shared_registry,
		framework_ui.Key(id),
		.Flash,
	)
	if !activated {return false}
	control := find_ui_control(UI_Control_ID(activation.control))
	if control == nil {return false}
	return activate_ui_action(control.action)
}

activate_ui_action :: proc(action: UI_Action) -> bool {
	if !ui_action_enabled_for_current_job(action.kind) {return false}
	#partial switch action.kind {
	case .Volume_Down, .Volume_Up, .Speed_Down, .Speed_Up,
	     .Source_Play_Pause, .Source_Stop, .Source_Timeline,
	     .Source_Reset, .Source_Hint_Menu, .Source_Hint:
		playback_fullscreen_show_controls()
	case:
	}
	clear_number_prefix()
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
	case .Open_Settings:
		if command_palette.is_open(&command_palette_state) {
			close_command_palette(false)
		}
		return video_clips_settings_open()
	case .Settings_Close:
		video_clips_settings_close()
	case .Settings_Category:
		if action.index >= 0 &&
		   action.index <= int(Video_Clips_Settings_Category.Shortcuts) {
			ui.settings_category = Video_Clips_Settings_Category(action.index)
			ui.settings_query_focused = false
			if ui.focus == .Settings_Search {_ = unfocus_text_input()}
		}
	case .Settings_Search:
		ui.settings_query_focused = true
		focus_text_input(.Settings_Search)
	case .Set_Theme:
		if action.value < 0 || action.value > int(UI_Theme.HW_Dark) {
			return false
		}
		return video_clips_settings_apply_theme(UI_Theme(action.value))
	case .Configure_Flash:
		return video_clips_shortcut_recorder_open()
	case .Shortcut_Record:
		return video_clips_shortcut_recorder_open()
	case .Shortcut_Save:
		return video_clips_shortcut_recorder_save()
	case .Shortcut_Reset:
		return video_clips_shortcut_recorder_reset()
	case .Shortcut_Cancel:
		request_modal_discard(.Shortcut)
	case .Workflow_Toggle:
		set_ui_workflow(
			ui.workflow == .Vocal ? .Dancing : .Vocal,
		)
	case .Mode_Toggle:
		set_ui_mode(ui.mode == .Create ? .Play : .Create)
	case .Open_Source_Modal:
		open_source_modal()
	case .Source_Mode_URL:
		ui.source_add_mode = .URL
		ui.local_source_title_index = -1
		focus_text_input(.URL)
		ui.needs_redraw = true
	case .Source_Mode_Local_Files:
		ui.source_add_mode = .Local_Files
		ui.focus = .None
		text_input.end_pointer_selection(&ui.input_state)
		ui.needs_redraw = true
	case .Browse_Source_Files:
		on_browse_source_files(nil, nil, nil)
	case .Cancel_Source_Modal:
		request_modal_discard(.Source)
	case .Close_Source_Details:
		close_source_details()
	case .Refetch_Source_Details:
		if ui.source_details_index >= 0 &&
		   ui.source_details_index < len(state.sources) &&
		   state.sources[ui.source_details_index].kind == .Local {
			relink_local_source(ui.source_details_index)
		} else {
			open_refetch_source_modal(ui.source_details_index)
		}
	case .Open_Source_Details:
		open_source_details(action.index)
	case .URL:
		focus_text_input(.URL)
	case .Local_Source_Title:
		ui.local_source_title_index = action.index
		focus_text_input(.Local_Source_Title)
	case .Remove_Local_Source:
		return source_local_path_remove(action.index)
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
		if job := import_job_for_notification(i64(action.index));
		   job != nil {
			if job.library_recovery_source && library_recovery != nil {
				library_recovery.cancelled = true
			}
			_ = media_queue_cancel_import(job)
			set_text(state.status, "Stopping media task...")
		} else if job := export_job_for_notification(i64(action.index));
		          job != nil {
			_ = media_queue_cancel_export(job)
			set_text(state.status, "Stopping media task...")
		} else if source_probe_job != nil &&
		          source_probe_job.notification_id ==
		          i64(action.index) {
			_ = media_queue_cancel_probe(source_probe_job)
			set_text(state.status, "Stopping media task...")
		} else if library_replacement_job != nil &&
		          library_replacement_job.notification_id ==
		          i64(action.index) {
			_ = media_queue_cancel_library_replacement(
				library_replacement_job,
			)
			set_text(state.status, "Stopping media task...")
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
	case .Clip_Search:
		focus_text_input(.Clip_Search)
	case .Clip:
		ui_event_tag = action.index
		on_play_clip(nil, nil, nil)
	case .Randomize:
		return randomize_clip()
	case .Open_Randomize_Help:
		open_randomize_help()
	case .Close_Randomize_Help:
		close_randomize_help()
	case .Play_Next:
		return play_next_clip()
	case .Shuffle_Toggle:
		ui.clip_shuffle = !ui.clip_shuffle
		set_success_status(
			ui.clip_shuffle ? "Shuffle enabled" : "Shuffle disabled",
		)
	case .Autoplay_Toggle:
		ui.clip_autoplay = !ui.clip_autoplay
		set_success_status(
			ui.clip_autoplay ? "Autoplay enabled" : "Autoplay disabled",
		)
	case .Pitch_Toggle:
		if !pitch_monitor_toggle(&ui.pitch) {
			ui.pitch.permission = Pitch_Permission(hw_video_clips_pitch_permission_status())
		}
	case .Dance_Mirror_Toggle:
		if clip := active_dance_clip(); clip != nil {
			clip.dance_mirrored = !clip.dance_mirrored
			ui.needs_redraw = true
			return save_active_dance_clip()
		}
		return false
	case .Dance_Loop_Toggle:
		if clip := active_dance_clip(); clip != nil {
			clip.dance_loop = !clip.dance_loop
			ui.needs_redraw = true
			return save_active_dance_clip()
		}
		return false
	case .Dance_Count_In:
		if clip := active_dance_clip(); clip != nil {
			switch clip.dance_count_in_beats {
			case 0: clip.dance_count_in_beats = 4
			case 4: clip.dance_count_in_beats = 8
			case: clip.dance_count_in_beats = 0
			}
			ui.needs_redraw = true
			return save_active_dance_clip()
		}
		return false
	case .Dance_Count_Each_Loop_Toggle:
		if clip := active_dance_clip(); clip != nil {
			clip.dance_count_each_loop = !clip.dance_count_each_loop
			ui.needs_redraw = true
			return save_active_dance_clip()
		}
		return false
	case .Dance_BPM_Down:
		if clip := active_dance_clip(); clip != nil {
			clip.dance_count_in_bpm =
				max(40, clip.dance_count_in_bpm - 1)
			ui.needs_redraw = true
			return save_active_dance_clip()
		}
		return false
	case .Dance_BPM_Up:
		if clip := active_dance_clip(); clip != nil {
			clip.dance_count_in_bpm =
				min(240, clip.dance_count_in_bpm + 1)
			ui.needs_redraw = true
			return save_active_dance_clip()
		}
		return false
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
	case .Pitch_Octaves_Down:
		ui.pitch.settings.octaves =
			max(1, ui.pitch.settings.octaves - 1)
		save_pitch_settings()
	case .Pitch_Octaves_Up:
		ui.pitch.settings.octaves =
			min(6, ui.pitch.settings.octaves + 1)
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
	case .Clip_Name:
		focus_text_input(.Clip_Name)
	case .Cancel_Clip_Rename:
		request_modal_discard(.Clip_Rename)
	case .Confirm_Clip_Rename:
		confirm_clip_rename()
	case .Clip_Rename:
		focus_text_input(.Clip_Rename)
	case .Close_Clip_Metadata:
		close_clip_metadata()
	case .View_Clip_Source:
		view_clip_source()
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
	case .Playback_Fullscreen_Toggle:
		_ = toggle_playback_fullscreen()
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
	case .Export_Current_Workflow:
		export_library_with_panel(
			ui.workflow == .Vocal ? .Vocal : .Dancing,
		)
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
	case .Discard_Keep_Editing:
		close_discard_confirmation()
	case .Discard_Changes:
		confirm_modal_discard()
	case .Rename:
		open_clip_rename()
	case .Metadata:
		open_clip_metadata()
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
		   valid_clip_range(state.range_start, state.range_end, state.sources[state.active_source].duration) {
			bits |= u64(PALETTE_CONTEXT_RANGE)
		}
	}
	if import_jobs_any() {bits |= u64(PALETTE_CONTEXT_IMPORT_BUSY)}
	if export_jobs_any() {bits |= u64(PALETTE_CONTEXT_EXPORT_BUSY)}
	if export_jobs_have_exclusive_operation() {
		bits |= u64(PALETTE_CONTEXT_EXPORT_EXCLUSIVE_BUSY)
	}
	if clip_save_media_job_blocks() {
		bits |= u64(PALETTE_CONTEXT_CLIP_SAVE_BUSY)
	}
	if ui.settings_open {bits |= u64(PALETTE_CONTEXT_SETTINGS)}
	if ui_theme_is_dark(ui.theme) {
		bits |= u64(PALETTE_CONTEXT_DARK_THEME)
	} else {
		bits |= u64(PALETTE_CONTEXT_LIGHT_THEME)
	}
	if global_modal_blocks_commands() {
		bits |= u64(PALETTE_CONTEXT_GLOBAL_MODAL)
	}
	if ui_action_enabled_for_current_job(.Play_Next) {
		bits |= u64(PALETTE_CONTEXT_PLAY_NEXT)
	}
	if ui_action_enabled_for_current_job(.Pitch_Toggle) {
		bits |= u64(PALETTE_CONTEXT_PITCH)
	}
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

palette_edit_busy_mask :: proc() -> command_palette.Context_Mask {
	return command_palette.Context_Mask(
		u64(PALETTE_CONTEXT_IMPORT_BUSY) |
			u64(PALETTE_CONTEXT_EXPORT_EXCLUSIVE_BUSY),
	)
}

build_command_palette_entries :: proc(allocator := context.temp_allocator) -> [dynamic]command_palette.Entry {
	entries := make([dynamic]command_palette.Entry, allocator)
	clear(&command_palette_actions)
	busy := palette_busy_mask()
	edit_busy := palette_edit_busy_mask()
	append_command_palette_entry(
		&entries,
		UI_Action{kind = .Open_Settings},
		"Open Settings",
		"Search and configure application settings",
		"Command",
		[]string{"preferences", "configuration", "gear"},
		palette_condition(
			none = command_palette.Context_Mask(
				u64(PALETTE_CONTEXT_SETTINGS) |
				u64(PALETTE_CONTEXT_GLOBAL_MODAL),
			),
		),
		"Unavailable while another modal owns application input",
	)
	append_command_palette_entry(
		&entries,
		UI_Action{kind = .Configure_Flash},
		"Configure leader key for Flash",
		fmt.tprintf(
			"Current shortcut: %s",
			video_clips_shortcut_display(ui.flash_leader),
		),
		"Shortcut",
		[]string{"keyboard", "shortcut", "leader", "jump", "navigation"},
		palette_condition(none = PALETTE_CONTEXT_GLOBAL_MODAL),
		"Unavailable while another modal owns application input",
	)
	for theme in UI_Theme {
		name := ui_theme_name(theme)
		current_theme_context := PALETTE_CONTEXT_LIGHT_THEME
		if ui_theme_is_dark(theme) {
			current_theme_context = PALETTE_CONTEXT_DARK_THEME
		}
		append_command_palette_entry(
			&entries,
			UI_Action{kind = .Set_Theme, value = int(theme)},
			fmt.tprintf("Use %s theme", name),
			fmt.tprintf("Apply the %s interface theme", name),
			"Theme",
			[]string{
				"appearance",
				"style",
				ui_theme_is_dark(theme) ? "dark" : "light",
				name,
			},
			palette_condition(
				none = command_palette.Context_Mask(
					u64(current_theme_context) |
						u64(PALETTE_CONTEXT_GLOBAL_MODAL),
				),
			),
			"Unavailable for the current theme or modal state",
		)
	}
	mode_context := PALETTE_CONTEXT_CREATE
	mode_title := "Switch to Clips"
	mode_subtitle := "Open the saved clip library"
	if ui.mode == .Play {
		mode_context = PALETTE_CONTEXT_PLAY
		mode_title = "Switch to Sources"
		mode_subtitle = "Open source editing and clip creation"
	}
	append_command_palette_entry(
		&entries,
		UI_Action{kind = .Workflow_Toggle},
		fmt.tprintf(
			"Switch to %s workflow",
			ui.workflow == .Vocal ? "Dancing" : "Vocal",
		),
		"Open the independent source and clip library for that workflow",
		"Command",
		[]string{"workflow", "vocal", "dancing"},
		palette_condition(none = edit_busy),
		"Wait for the active media operation to finish",
	)
	append_command_palette_entry(
		&entries,
		UI_Action{kind = .Mode_Toggle},
		mode_title,
		mode_subtitle,
		"Command",
		[]string{"mode", "workspace"},
		palette_condition(mode_context, edit_busy),
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
		"Set the clip start at the current playhead",
		"Command",
		[]string{"start", "range"},
		palette_condition(create_player),
		"Available with a loaded source in Create mode",
	)
	append_command_palette_entry(
		&entries,
		UI_Action{kind = .End},
		"Mark Out",
		"Set the clip end at the current playhead",
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
		"Commit clip",
		"Export the marked range as a saved clip",
		"Command",
		[]string{"save", "clip", "range"},
		palette_condition(create_range, PALETTE_CONTEXT_CLIP_SAVE_BUSY),
		"Mark a valid range and wait for any source refetch, recovery, preview, or repair",
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
		"Start the loaded source or clip",
		"Command",
		[]string{"run", "resume"},
		palette_condition(PALETTE_CONTEXT_PLAYER),
		"Available after loading a source or clip",
	)
	append_command_palette_entry(
		&entries,
		UI_Action{kind = .Pause},
		"Pause",
		"Pause the loaded source or clip",
		"Command",
		[]string{"hold"},
		palette_condition(PALETTE_CONTEXT_PLAYER),
		"Available after loading a source or clip",
	)
	append_command_palette_entry(
		&entries,
		UI_Action{kind = .Source_Stop},
		"Stop playback",
		"Stop the loaded source or clip and seek to zero",
		"Command",
		[]string{"transport", "zero"},
		palette_condition(PALETTE_CONTEXT_PLAYER),
		"Available after loading a source or clip",
	)
	fullscreen_title := "Enter full screen playback"
	fullscreen_subtitle :=
		"Fill the current display without entering a macOS full-screen Space"
	if ui.playback_fullscreen_active {
		fullscreen_title = "Exit full screen playback"
		fullscreen_subtitle = "Restore the previous application window frame"
	}
	append_command_palette_entry(
		&entries,
		UI_Action{kind = .Playback_Fullscreen_Toggle},
		fullscreen_title,
		fullscreen_subtitle,
		"Command",
		[]string{"video", "player", "display", "expand", "collapse"},
		palette_condition(PALETTE_CONTEXT_PLAYER),
		"Available after loading a source or clip",
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
		"Reset clip",
		"Seek to the start of the loaded clip",
		"Command",
		[]string{"transport", "zero"},
		palette_condition(play_player),
		"Available after loading a clip in Clips",
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
			"Available after loading a source or clip",
		)
	}
	append_command_palette_entry(
		&entries,
		UI_Action{kind = .Pitch_Toggle},
		ui.pitch.tracking ? "Stop pitch tracking" : "Start pitch tracking",
		"Start or stop live microphone pitch analysis",
		"Command",
		[]string{"microphone", "sing", "tuner", "pitch"},
		palette_condition(
			command_palette.Context_Mask(
				u64(PALETTE_CONTEXT_PLAY) |
					u64(PALETTE_CONTEXT_PITCH),
			),
		),
		"Available in Play mode with microphone access available",
	)
	append_command_palette_entry(
		&entries,
		UI_Action{kind = .Play_Next},
		"Play next clip",
		"Play the next filtered clip or a weighted shuffled clip",
		"Command",
		[]string{"clip", "next", "shuffle"},
		palette_condition(
			command_palette.Context_Mask(
				u64(PALETTE_CONTEXT_PLAY) |
					u64(PALETTE_CONTEXT_PLAY_NEXT),
			),
		),
		"Available when the current clip filter has a result",
	)
	append_command_palette_entry(
		&entries,
		UI_Action{kind = .Shuffle_Toggle},
		ui.clip_shuffle ? "Disable shuffle" : "Enable shuffle",
		"Make Play Next use the weighted Randomize selection",
		"Command",
		[]string{"clip", "next", "random"},
		palette_condition(PALETTE_CONTEXT_PLAY),
		"Available in Play mode",
	)
	append_command_palette_entry(
		&entries,
		UI_Action{kind = .Autoplay_Toggle},
		ui.clip_autoplay ? "Disable autoplay" : "Enable autoplay",
		"Play the next filtered clip when the current clip finishes",
		"Command",
		[]string{"clip", "next", "continuous"},
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
		if source.workflow != ui.workflow {continue}
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
	for clip, index in state.clips {
		if clip.workflow != ui.workflow {continue}
		source_title := clip.source_id
		for source in state.sources {
			if source.id == clip.source_id {source_title = source.title; break}
		}
		subtitle := fmt.tprintf(
			"%s · %s–%s",
			source_title,
			format_timestamp(clip.start_seconds),
			format_timestamp(clip.end_seconds),
		)
		keywords := []string{
			clip.id,
			clip.source_id,
			source_title,
			clip.clip_path,
			format_timestamp(clip.start_seconds),
			format_timestamp(clip.end_seconds),
		}
		append_command_palette_entry(
			&entries,
			UI_Action{kind = .Clip, index = index},
			clip.name,
			subtitle,
			"Clip",
			keywords,
			palette_condition(none = busy),
			"Wait for the active media operation to finish",
		)
	}
	return entries
}

begin_command_palette :: proc() -> bool {
	if command_palette.is_open(&command_palette_state) {return true}
	if global_modal_blocks_commands() {return false}
	if ui.settings_open {video_clips_settings_close()}
	cancel_ui_flash()
	if ui.clip_rename_open {close_clip_rename()}
	if ui.clip_metadata_open {close_clip_metadata()}
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
	if ui.clip_rename_open {close_clip_rename()}
	if ui.clip_metadata_open {close_clip_metadata()}
	if ui.randomize_help_open {close_randomize_help()}
	if ui.pitch.help_open {close_pitch_help()}
	if ui.data_modal_open {close_data_modal()}
	if ui.notification_modal_open {close_notification_history()}
	if action.kind == .Source {set_ui_mode(.Create)}
	if action.kind == .Clip {set_ui_mode(.Play)}
	return activate_ui_action(action)
}

activate_selected_command_palette_result :: proc() -> bool {
	return activate_command_palette_result(command_palette.selected_index(&command_palette_state))
}

ui_memory_destroy :: proc() {
	framework_macos.frame_timer_stop(&ui.frame_timer)
	_ = flush_active_clip_draft()
	pitch_monitor_stop(&ui.pitch)
	metal_player_clear()
	ordered_ui_destroy()
	app_state_collections_destroy(&pending_library_import)
	if ui.ax_children != nil {msg_void(ui.ax_children, sel_registerName("release"))}
	if ui.queue != nil {msg_void(ui.queue, sel_registerName("release"))}
	if ui.texture_cache !=
	   nil {foreign_release(ui.texture_cache, "CVMetalTextureCache", "ui_memory_destroy")}
	delete(ui.url_input)
	delete(ui.source_search)
	delete(ui.transcript_search)
	delete(ui.clip_search)
	delete(ui.clip_name)
	delete(ui.clip_rename)
	delete(ui.command_palette_query)
	delete(ui.settings_query)
	delete(ui.settings_error)
	delete(ui.shortcut_collision)
	delete(ui.shortcut_error)
	video_clips_shortcut_destroy(&ui.flash_leader)
	video_clips_shortcut_destroy(&ui.shortcut_candidate)
	delete(ui.status)
	delete(ui.status_source_video_id)
	for index in 0..<WORKFLOW_COUNT {
		delete(ui.source_selection_ids[index])
		delete(ui.clip_selection_ids[index])
	}
	text_input.destroy(&ui.input_state)
	delete(ui.transcript_matches)
	delete(ax_actions)
	delete(command_palette_actions)
	flash.state_destroy(&flash_state)
	command_palette.state_destroy(&command_palette_state)
	command_palette.state_destroy(&ui.settings_search)
	ui = {}
	ax_actions = nil
	ui_build = {}
	command_palette_actions = nil
}

activate_control :: proc(index: int) {
	kinds := [20]UI_Action_Kind{.Start, .End, .Save, .Play, .Pause, .Captions, .Preview, .Data, .Rename, .Metadata, .Randomize, .Pitch_Toggle, .Play_Next, .Shuffle_Toggle, .Autoplay_Toggle, .Dance_Mirror_Toggle, .Dance_Loop_Toggle, .Dance_Count_In, .Dance_Count_Each_Loop_Toggle, .Playback_Fullscreen_Toggle}
	if index < 0 || index >= len(kinds) {return}
	if index == PLAYBACK_FULLSCREEN_ACTION_INDEX {
		if ui_action_enabled_for_current_job(.Playback_Fullscreen_Toggle) {
			_ = activate_ui_action({kind = .Playback_Fullscreen_Toggle})
		}
		return
	}
	control := find_ui_control_by_action(kinds[index])
	if control != nil && .Enabled in control.flags {_ = activate_ui_action(control.action)}
}

editable_action_for_focus :: proc(
	focus: UI_Focus,
) -> (UI_Action_Kind, bool) {
	#partial switch focus {
	case .Command_Palette: return .Command_Palette_Search, true
	case .Settings_Search: return .Settings_Search, true
	case .URL:              return .URL, true
	case .Local_Source_Title:return .Local_Source_Title, true
	case .Source_Search:    return .Source_Search, true
	case .Transcript_Search:return .Transcript_Search, true
	case .Clip_Search:  return .Clip_Search, true
	case .Clip_Name:    return .Clip_Name, true
	case .Clip_Rename:  return .Clip_Rename, true
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
	if focus == .Local_Source_Title {
		control = find_ui_control_by_action_and_index(
			.Local_Source_Title,
			ui.local_source_title_index,
		)
	}
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
	control := find_shared_ui_control_at_point(point, .Primary_Press)
	if control == nil {return false}
	#partial switch control.action.kind {
	case .Command_Palette_Search:
		begin_text_pointer_selection(control, .Command_Palette, point, click_count)
	case .Settings_Search:
		begin_text_pointer_selection(control, .Settings_Search, point, click_count)
	case .URL:
		if ui.source_modal_refetch_index >= 0 {return true}
		begin_text_pointer_selection(control, .URL, point, click_count)
	case .Local_Source_Title:
		ui.local_source_title_index = control.action.index
		begin_text_pointer_selection(control, .Local_Source_Title, point, click_count)
	case .Source_Search:
		begin_text_pointer_selection(control, .Source_Search, point, click_count)
	case .Transcript_Search:
		begin_text_pointer_selection(control, .Transcript_Search, point, click_count)
	case .Clip_Search:
		begin_text_pointer_selection(control, .Clip_Search, point, click_count)
	case .Clip_Name:
		begin_text_pointer_selection(control, .Clip_Name, point, click_count)
	case .Clip_Rename:
		begin_text_pointer_selection(control, .Clip_Rename, point, click_count)
	case .Source_Timeline:
		cancel_player_surface_click()
		ui.source_scrubbing = true
		seek_player_timeline_rect(point, control.rect)
	case .Player_Surface:
		now_ms := numbered_action_time_ms()
		if player_surface_click_is_double(
			click_count,
			ui.player_surface_click_pending,
			now_ms,
			ui.player_surface_click_deadline_ms,
		) {
			cancel_player_surface_click()
			_ = toggle_playback_fullscreen()
		} else {
			_ = advance_player_surface_click(now_ms)
			schedule_player_surface_click(now_ms)
			playback_fullscreen_show_controls()
		}
	case:
		cancel_player_surface_click()
		return activate_ui_action(control.action)
	}
	return true
}

dispatch_click :: proc(point: Point, click_count: uint = 1) {
	cancel_ui_flash()
	text_input.end_pointer_selection(&ui.input_state)
	if ui.discard_confirm_open {
		modal := discard_confirm_rect()
		if !contains(modal, point) {close_discard_confirmation(); return}
		_ = activate_registered_target_at_point(point, click_count)
		return
	}
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
	if ui.shortcut_open {
		modal := video_clips_shortcut_modal_rect()
		if !contains(modal, point) {request_modal_discard(.Shortcut); return}
		_ = activate_registered_target_at_point(point, click_count)
		return
	}
	if ui.settings_open {
		modal := video_clips_settings_rect()
		if !contains(modal, point) {video_clips_settings_close(); return}
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
	if ui.clip_metadata_open {
		modal := clip_metadata_modal_rect()
		if !contains(modal, point) {close_clip_metadata(); return}
		_ = activate_registered_target_at_point(point, click_count)
		return
	}
	if ui.clip_rename_open {
		modal := clip_rename_modal_rect()
		if !contains(modal, point) {request_modal_discard(.Clip_Rename); return}
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
		if !contains(modal, point) {request_modal_discard(.Source); return}
		_ = activate_registered_target_at_point(point, click_count)
		return
	}
	clicked_control := find_shared_ui_control_at_point(point, .Primary_Press)
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
	if ui.playback_fullscreen_active {return false}
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
	ui.pointer_event_count += 1
	window_point := msg_point(event, sel_registerName("locationInWindow"))
	ui.mouse = msg_point_point_id(
		self,
		sel_registerName("convertPoint:fromView:"),
		window_point,
		nil,
	)
	playback_fullscreen_show_controls()
	if begin_window_resize(ui.mouse) {return}
	window_control := find_shared_ui_control_at_point(ui.mouse, .Primary_Press)
	if window_control != nil &&
	   ui_action_is_window(window_control.action.kind) {
		cancel_ui_flash()
		_ = activate_ui_action(window_control.action)
		return
	}
	click_count := msg_uint(event, sel_registerName("clickCount"))
	if !command_palette.is_open(&command_palette_state) &&
	   !ui.playback_fullscreen_active &&
	   !ui.source_modal_open && !ui.source_details_open &&
	   !ui.clip_rename_open && !ui.clip_metadata_open &&
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
	   ui.clip_rename_open || ui.clip_metadata_open ||
	   ui.randomize_help_open || ui.pitch.help_open ||
	   ui.data_modal_open || ui.notification_modal_open ||
	   ui.mode != .Create {
		return
	}
	window_point := msg_point(event, sel_registerName("locationInWindow"))
	point := msg_point_point_id(self, sel_registerName("convertPoint:fromView:"), window_point, nil)
	ui.mouse = point
	control := find_shared_ui_control_at_point(point, .Secondary_Press)
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
		playback_fullscreen_show_controls()
		if command_palette.is_open(&command_palette_state) {
			control := find_shared_ui_control_at_point(next, .Primary_Press)
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
	playback_fullscreen_show_controls()
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

modal_consumes_content_scroll :: proc() -> bool {
	return library_recovery_state.required ||
	       major_change_pending.open ||
	       ui.discard_confirm_open ||
	       ui.settings_open ||
	       ui.shortcut_open ||
	       ui.source_modal_open ||
	       ui.source_details_open ||
	       ui.clip_rename_open ||
	       ui.clip_metadata_open ||
	       ui.randomize_help_open ||
	       ui.pitch.help_open ||
	       ui.data_modal_open
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
	if modal_consumes_content_scroll() {return}
	delta := msg_f64(event, sel_registerName("scrollingDeltaY"))
	window_point := msg_point(event, sel_registerName("locationInWindow"))
	point := msg_point_point_id(
		self,
		sel_registerName("convertPoint:fromView:"),
		window_point,
		nil,
	)
	_, _, source_search, source_panel, _, transcript, clip_search, clip_panel, clip_name, _, _ :=
		layout_rects()
	source_content := source_content_rect(source_search, source_panel)
	transcript_content := transcript_content_rect(transcript)
	clip_content := clip_content_rect(clip_search, clip_panel, clip_name)
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
	} else if ui.mode == .Play && contains(clip_content, point) {
		ui.clip_scroll = bounded_scroll(
			ui.clip_scroll,
			delta,
			filtered_clip_count(),
			29,
			30,
			clip_content.h,
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

general_pasteboard_text :: proc() -> (string, bool) {
	pasteboard := msg_id(
		objc_getClass("NSPasteboard"),
		sel_registerName("generalPasteboard"),
	)
	if pasteboard == nil {return "", false}
	value := msg_id_id(
		pasteboard,
		sel_registerName("stringForType:"),
		nsstring("public.utf8-plain-text"),
	)
	if value == nil {return "", false}
	utf8 := msg_id(value, sel_registerName("UTF8String"))
	if utf8 == nil {return "", false}
	return string(cstring(utf8)), true
}

handle_global_source_pasteboard :: proc() -> bool {
	text, available := general_pasteboard_text()
	if !available {return false}
	return handle_global_source_paste(text) != .Not_YouTube
}

on_metal_paste :: proc "c" (self: Id, command: Sel, sender: Id) {
	context = runtime.default_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	text, available := general_pasteboard_text()
	if !available {return}
	if handle_global_source_paste(text) != .Not_YouTube {return}
	target := focused_text()
	if target == nil {return}
	remove_marked_text(target)
	insert_text_at_caret(target, text)
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
		} else if ui.focus == .Clip_Rename {
			confirm_clip_rename()
		} else if ui.focus == .Source_Search ||
		          ui.focus == .Transcript_Search ||
		          ui.focus == .Clip_Search ||
		          ui.focus == .Clip_Name {
			ui.focus = .None
			text_input.end_pointer_selection(&ui.input_state)
		}
	} else if selector == sel_registerName("insertTab:") {
		if ui.clip_rename_open {
			focus_text_input(.Clip_Rename)
		} else if ui.source_modal_open {
			focus_text_input(.URL)
		} else if ui.mode == .Play {
			focus_text_input(.Clip_Search)
		} else {
			#partial switch ui.focus {
			case .None:
				focus_text_input(.Source_Search)
			case .Source_Search:
				focus_text_input(.Transcript_Search)
			case .Transcript_Search:
				focus_text_input(.Clip_Name)
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
	shortcut_characters := msg_id(
		event,
		sel_registerName("charactersIgnoringModifiers"),
	)
	shortcut_text, has_shortcut_text :=
		text_input_string(shortcut_characters)
	cancel_player_surface_click()
	if global_modal_blocks_commands() {
		if ui.shortcut_open {video_clips_shortcut_recorder_close()}
		if ui.settings_open {video_clips_settings_close()}
		if command_palette.is_open(&command_palette_state) {
			close_command_palette(false)
		}
		cancel_ui_flash()
	}
	if is_paste_shortcut(key, modifiers) &&
	   handle_global_source_pasteboard() {
		return
	}
	if ui.discard_confirm_open {
		if key == 53 || key == 18 || key == 36 || key == 76 {
			close_discard_confirmation()
		} else if key == 19 {
			confirm_modal_discard()
		}
		return
	}
	if ui.shortcut_open {
		if key == 53 {
			if ui.shortcut_listening {
				ui.shortcut_listening = false
				ui.needs_redraw = true
			} else {
				request_modal_discard(.Shortcut)
			}
			return
		}
		relevant :=
			NSEventModifierFlagShift |
			NSEventModifierFlagControl |
			NSEventModifierFlagOption |
			NSEventModifierFlagCommand
		if modifiers & relevant == 0 {
			if digit, found := number_digit_for_key_code(key); found {
				route := shortcut_digit_route(digit)
				switch route {
				case .Save:
					_ = video_clips_shortcut_recorder_save()
				case .Reset:
					_ = video_clips_shortcut_recorder_reset()
				case .Cancel:
					request_modal_discard(.Shortcut)
				case .Capture:
				}
				if route != .Capture {return}
			}
		}
		if has_shortcut_text {
			_ = video_clips_shortcut_recorder_capture(
				key,
				shortcut_text,
				modifiers,
			)
		} else {
			_ = video_clips_shortcut_recorder_capture(key, "", modifiers)
		}
		return
	}
	if event_opens_settings(event, modifiers) {
		if command_palette.is_open(&command_palette_state) {
			close_command_palette(false)
		}
		_ = video_clips_settings_open()
		return
	}
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
	if ui.settings_open {
		if ui.focus == .Settings_Search {
			if key == 53 {
				video_clips_settings_close()
				return
			}
		} else {
			if key == 53 {
				video_clips_settings_close()
			} else if key == 48 {
				ui.settings_query_focused = true
				focus_text_input(.Settings_Search)
			} else if key == 125 {
				ui.settings_category = .Shortcuts
				ui.needs_redraw = true
			} else if key == 126 {
				ui.settings_category = .Styling
				ui.needs_redraw = true
			} else if has_shortcut_text &&
			          flash_leader_allowed(
						.None,
						key,
						modifiers,
						shortcut_text,
			          ) {
				_ = begin_ui_flash()
			}
			return
		}
	}
	if has_shortcut_text &&
	   flash_leader_allowed(
			ui.focus,
			key,
			modifiers,
			shortcut_text,
	   ) {
		_ = begin_ui_flash()
		return
	}
	if ui.clip_metadata_open && key == 53 {close_clip_metadata(); return}
	if ui.clip_rename_open && key == 53 {request_modal_discard(.Clip_Rename); return}
	if ui.randomize_help_open {
		if key == 53 {close_randomize_help()}
		return
	}
	if ui.pitch.help_open {
		if key == 53 {close_pitch_help()}
		if key == 18 {close_pitch_help()}
		return
	}
	if ui.data_modal_open {
		if key == 53 {close_data_modal(); return}
		modal_modifiers :=
			NSEventModifierFlagShift |
			NSEventModifierFlagControl |
			NSEventModifierFlagOption |
			NSEventModifierFlagCommand
		if modifiers & modal_modifiers == 0 {
			if digit, found := number_digit_for_key_code(key); found {
				if ui.library_import_confirm_open {
					if digit == 1 {
						_ = activate_ui_action(
							UI_Action{kind=.Confirm_Library_Import},
						)
						return
					}
					if digit == 2 {
						_ = activate_ui_action(
							UI_Action{kind=.Cancel_Library_Import},
						)
						return
					}
				} else {
					actions := [5]UI_Action_Kind{
						.Export_Library,
						.Export_Current_Workflow,
						.Import_Library,
						.Open_Data_Folder,
						.Close_Data_Modal,
					}
					if digit >= 1 && digit <= len(actions) {
						_ = activate_ui_action(
							UI_Action{kind=actions[digit - 1]},
						)
						return
					}
				}
			}
		}
		return
	}
	if ui.notification_modal_open {
		if key == 53 {close_notification_history(); return}
		if key == 125 {_ = select_relative_notification(-1); return}
		if key == 126 {_ = select_relative_notification(1); return}
		return
	}
	if ui.source_modal_open && key == 53 {request_modal_discard(.Source); return}
	if key == 53 && unfocus_text_input() {return}
	if ui.source_details_open && key == 53 {close_source_details(); return}
	if key == 53 && ui.number_prefix != 0 {
		clear_number_prefix()
		ui.needs_redraw = true
		return
	}
	if key == 53 && ui.playback_fullscreen_active {
		_ = set_playback_fullscreen(false)
		return
	}
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
		numbered_actions_available :=
		   !ui.source_modal_open &&
		   !ui.source_details_open &&
		   !ui.clip_rename_open &&
		   !ui.clip_metadata_open &&
		   !ui.randomize_help_open &&
		   !ui.pitch.help_open &&
		   !ui.data_modal_open &&
		   !ui.notification_modal_open
		if numbered_actions_available &&
		   has_shortcut_text &&
		   playback_fullscreen_shortcut_matches(
				shortcut_text,
				modifiers,
		   ) &&
		   (state.player != nil || ui.playback_fullscreen_active) {
			_ = toggle_playback_fullscreen()
			return
		}
		if numbered_actions_available && state.player != nil {
			if delta, scrub := timeline_scrub_delta(key, modifiers); scrub {
				playback_fullscreen_show_controls()
				scrub_player_by(delta)
				return
			}
		}
		if numbered_actions_available && key == 49 {
			playback_fullscreen_show_controls()
			on_toggle_playback(nil, nil, nil)
			return
		}
		number_modifiers :=
			NSEventModifierFlagShift |
			NSEventModifierFlagControl |
			NSEventModifierFlagOption |
			NSEventModifierFlagCommand
		if numbered_actions_available && modifiers & number_modifiers == 0 {
			if digit, found := number_digit_for_key_code(key); found {
				control_id, activated, handled := consume_shared_numbered_digit(
					digit,
					numbered_action_time_ms(),
				)
				if activated {
					control := find_ui_control(control_id)
					if control != nil {_ = activate_ui_action(control.action)}
				}
				if handled {return}
			}
		}
	}
	array := msg_id_id(objc_getClass("NSArray"), sel_registerName("arrayWithObject:"), event)
	msg_void_id(self, sel_registerName("interpretKeyEvents:"), array)
}

on_metal_flags_changed :: proc "c" (self: Id, command: Sel, event: Id) {
	context = runtime.default_context()
	if !ui.shortcut_open || !ui.shortcut_listening {return}
	modifiers := msg_uint(event, sel_registerName("modifierFlags"))
	ui.shortcut_live_modifiers =
		video_clips_shortcut_modifiers_from_event(modifiers)
	ui.needs_redraw = true
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

metal_frame_should_render :: proc(
	needs_redraw,
	playback_active,
	video_frame_pending: bool,
) -> bool {
	return needs_redraw || playback_active || video_frame_pending
}

on_metal_frame :: proc "c" (self: Id, command: Sel, timer: Id) {
	context = runtime.default_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	ui.frame_tick += 1
	advance_paused_video_frame_warmup()
	if ui.video_frame_pending &&
	   !video_frame_retry_active(
			ui.video_frame_pending,
			ui.frame_tick,
			ui.video_frame_deadline,
	   ) {
		clear_video_frame_refresh()
	}
	now_ms := numbered_action_time_ms()
	_ = expire_number_prefix_at(now_ms)
	_ = advance_player_surface_click(now_ms)
	if ui.clip_draft_dirty &&
	   ui.clip_draft_persist_due_ms > 0 &&
	   now_ms >= ui.clip_draft_persist_due_ms {
		_ = flush_active_clip_draft()
	}
	_ = advance_dance_count_in(now_ms)
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
			if import_jobs_any() {refresh_import_progress()}
			ui.needs_redraw = true
		}
	} else {
		ui.activity_tick = 0
	}
	playback_active := state.player != nil &&
	                   msg_f32(state.player, sel_registerName("rate")) > 0
	completion_pending := ui.playback_completion_pending
	ui.playback_completion_pending = false
	dance_looped := false
	if completion_pending &&
	   !ui.source_playback_active &&
	   ui.mode == .Play {
		if clip := active_dance_clip();
		   clip != nil && clip.dance_loop {
			start_active_clip_from_beginning(true)
			dance_looped = true
		}
	}
	if !dance_looped && clip_autoplay_should_advance(
		ui.clip_autoplay,
		completion_pending,
		ui.source_playback_active,
		ui.mode,
		ui.active_clip,
		len(state.clips),
	) {
		_ = play_next_clip()
		playback_active = state.player != nil &&
		                  msg_f32(
							state.player,
							sel_registerName("rate"),
		                  ) > 0
	}
	playback_active = playback_active || ui.count_in_active
	playback_fullscreen_tick(now_ms, playback_active)
	playback_fullscreen_refresh_timestamp()
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
	if metal_frame_should_render(
		ui.needs_redraw,
		playback_active,
		ui.video_frame_pending,
	) {
		msg_void_size(
			ui.layer,
			sel_registerName("setDrawableSize:"),
			Size{ui.width * ui.scale, ui.height * ui.scale},
		)
		render_frame()
	}
	ui_automation_advance()
}

register_delegate :: proc(app: Id) {
	delegate_class := objc_allocateClassPair(objc_getClass("NSObject"), "HWVideoClipsMetalDelegate", 0)
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
		sel_registerName("clipNormalizeFinished:"),
		rawptr(on_clip_normalize_finished),
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
		sel_registerName("libraryReplacementReady:"),
		rawptr(on_library_replacement_ready),
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
		sel_registerName("playerItemDidReachEnd:"),
		rawptr(on_player_item_did_reach_end),
		"v@:@",
	)
	class_addMethod(
		delegate_class,
		sel_registerName("applicationDidBecomeActive:"),
		rawptr(on_application_did_become_active),
		"v@:@",
	)
	class_addMethod(
		delegate_class,
		sel_registerName("applicationShouldHandleReopen:hasVisibleWindows:"),
		rawptr(on_application_should_handle_reopen),
		"B@:@B",
	)
	class_addMethod(
		delegate_class,
		sel_registerName("applicationDidChangeScreenParameters:"),
		rawptr(on_application_did_change_screen_parameters),
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

NS_DRAG_OPERATION_NONE :: uint(0)
NS_DRAG_OPERATION_COPY :: uint(1)

source_file_drop_allowed :: proc() -> bool {
	if ui.source_modal_open {return ui.source_modal_refetch_index < 0}
	return !global_modal_blocks_commands() && !ui.library_import_confirm_open
}

on_metal_dragging_entered :: proc "c" (self: Id, command: Sel, sender: Id) -> uint {
	context = runtime.default_context()
	return source_file_drop_allowed() ? NS_DRAG_OPERATION_COPY : NS_DRAG_OPERATION_NONE
}

on_metal_perform_drag :: proc "c" (self: Id, command: Sel, sender: Id) -> bool {
	context = runtime.default_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	if !source_file_drop_allowed() {
		set_error_status("Close the active dialog before adding local source files")
		return false
	}
	pasteboard := msg_id(sender, sel_registerName("draggingPasteboard"))
	paths := msg_id_id(
		pasteboard,
		sel_registerName("propertyListForType:"),
		nsstring("NSFilenamesPboardType"),
	)
	count := int(msg_uint(paths, sel_registerName("count")))
	added := 0
	for index in 0 ..< count {
		path_value := msg_id_uint(paths, sel_registerName("objectAtIndex:"), uint(index))
		utf8 := msg_id(path_value, sel_registerName("UTF8String"))
		if utf8 != nil && source_local_path_append(string(cstring(utf8))) {added += 1}
	}
	if added == 0 {return false}
	if !ui.source_modal_open {
		if ui.mode != .Create {set_ui_mode(.Create)}
		open_source_modal()
	}
	ui.source_add_mode = .Local_Files
	ui.focus = .None
	set_text(state.status, fmt.tprintf("Added %d dropped local source file(s)", added))
	ui.needs_redraw = true
	return true
}

register_metal_view_class :: proc() -> Id {
	class := objc_allocateClassPair(objc_getClass("NSView"), "HWVideoClipsMetalView", 0)
	if protocol := objc_getProtocol("NSTextInputClient"); protocol != nil {
		class_addProtocol(class, protocol)
	}
	if protocol := objc_getProtocol("NSDraggingDestination"); protocol != nil {
		class_addProtocol(class, protocol)
	}
	class_addMethod(class, sel_registerName("draggingEntered:"), rawptr(on_metal_dragging_entered), "Q@:@")
	class_addMethod(class, sel_registerName("performDragOperation:"), rawptr(on_metal_perform_drag), "B@:@")
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
	class_addMethod(
		class,
		sel_registerName("flagsChanged:"),
		rawptr(on_metal_flags_changed),
		"v@:@",
	)
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

window_can_become_key :: proc "c" (self: Id, command: Sel) -> bool {
	return true
}

register_window_class :: proc() -> Id {
	class := objc_allocateClassPair(
		objc_getClass("NSWindow"),
		"HWVideoClipsWindow",
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

launch_should_show :: proc(value: cstring) -> bool {
	return value == nil || string(value) != "0"
}

APPLICATION_ACTIVATION_POLICY_REGULAR :: 0
APPLICATION_ACTIVATION_POLICY_ACCESSORY :: 1

application_activation_policy :: proc(automation: bool) -> int {
	if automation {return APPLICATION_ACTIVATION_POLICY_ACCESSORY}
	return APPLICATION_ACTIVATION_POLICY_REGULAR
}

video_clips_gui_initialize :: proc() -> bool {
	app := msg_id(objc_getClass("NSApplication"), sel_registerName("sharedApplication"))
	msg_void_i(
		app,
		sel_registerName("setActivationPolicy:"),
		application_activation_policy(ui_automation_enabled()),
	)
	register_delegate(app)

	state.url_input = CONTROL_URL
	state.status = CONTROL_STATUS
	state.source_search_input = CONTROL_SOURCE
	state.clip_search_input = CONTROL_CLIP
	state.clip_name_input = CONTROL_CLIP_NAME
	ui_set_string(&ui.status, "Ready")
	ui.scale = 1
	ui.active_clip = -1
	ui.clip_rename_index = -1
	ui.clip_metadata_index = -1
	ui.transcript_matches_dirty = true
	ui.needs_redraw = true
	pitch_monitor_initialize(
		&ui.pitch,
		database_pitch_settings_load(library_database),
	)
	ui.flash_leader = video_clips_shortcut_clone(video_clips_shortcut_default())
	if encoded, found := database_flash_leader_load(
		library_database,
		context.temp_allocator,
	); found {
		if decoded, valid := video_clips_shortcut_deserialize(encoded); valid {
			video_clips_shortcut_destroy(&ui.flash_leader)
			ui.flash_leader = decoded
		}
	}
	flash.state_init(&flash_state)
	palette_error := command_palette.state_init(
		&command_palette_state,
		search_reserve_size = SEARCH_RESERVE_SIZE,
		search_commit_size = SEARCH_COMMIT_SIZE,
	)
	assert(palette_error == nil, "Unable to initialize the command palette")
	settings_error := command_palette.state_init(
		&ui.settings_search,
		search_reserve_size = 4*1024*1024,
		search_commit_size = 64*1024,
	)
	assert(settings_error == nil, "Unable to initialize Settings search")

	frame := Rect{Point{120, 100}, Size{1100, 720}}
	window_class := register_window_class()
	state.window = msg_id_rect_u_u_b(
		msg_id(window_class, sel_registerName("alloc")),
		sel_registerName("initWithContentRect:styleMask:backing:defer:"),
		frame,
		WINDOW_STYLE,
		2,
		false,
	)
	msg_void_id(state.window, sel_registerName("setTitle:"), nsstring("hw_videoClips"))
	msg_void_bool(state.window, sel_registerName("setOpaque:"), true)
	msg_void_bool(state.window, sel_registerName("setHasShadow:"), false)
	msg_void_size(
		state.window,
		sel_registerName("setMinSize:"),
		Size{WINDOW_MIN_WIDTH, WINDOW_MIN_HEIGHT},
	)
	msg_void_bool(state.window, sel_registerName("setAcceptsMouseMovedEvents:"), true)
	register_accessibility_class()
	view_class := register_metal_view_class()
	ui.view = msg_id_rect(
		msg_id(view_class, sel_registerName("alloc")),
		sel_registerName("initWithFrame:"),
		Rect{Point{0, 0}, frame.size},
	)
	drag_types := msg_id_id(
		objc_getClass("NSArray"),
		sel_registerName("arrayWithObject:"),
		nsstring("NSFilenamesPboardType"),
	)
	msg_void_id(ui.view, sel_registerName("registerForDraggedTypes:"), drag_types)
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
	if !ordered_ui_initialize() {
		fmt.eprintln("Unable to initialize the ordered UI renderer")
		return false
	}

	if ui.mode == .Create {restore_source_selection()} else {restore_clip_selection()}
	if !framework_macos.frame_timer_start(
		&ui.frame_timer,
		state.delegate_target,
		"metalFrame:",
	) {
		fmt.eprintln("Unable to start the interface frame timer")
		return false
	}

	screen := msg_id(objc_getClass("NSScreen"), sel_registerName("mainScreen"))
	window_frame := msg_rect(screen, sel_registerName("visibleFrame"))
	if ui_automation_enabled() {
		window_frame = playback_fullscreen_frame(screen)
	}
	msg_void_rect_b(
		state.window,
		sel_registerName("setFrame:display:"),
		window_frame,
		true,
	)
	msg_void_id(state.window, sel_registerName("makeFirstResponder:"), ui.view)
	should_activate := launch_should_activate(
		getenv("HW_VIDEO_CLIPS_ACTIVATE_ON_LAUNCH"),
	)
	if should_activate {
		msg_void_id(state.window, sel_registerName("makeKeyAndOrderFront:"), nil)
		msg_void_i(app, sel_registerName("activateIgnoringOtherApps:"), 1)
	} else if launch_should_show(
		getenv("HW_VIDEO_CLIPS_VISIBLE_ON_LAUNCH"),
	) {
		msg_void_id(state.window, sel_registerName("orderBack:"), nil)
	}
	if !should_activate {
		msg_void(app, sel_registerName("deactivate"))
	}
	allow_hidden_window_reveal = true
	if !cli_ipc_server_start() {set_text(state.status, "CLI control socket is unavailable")}
	validate_startup_helpers()
	if !ui_automation_enabled() {request_next_missing_source_metadata()}
	return true
}

build_metal_window :: proc() {
	if !video_clips_gui_initialize() {return}
	app := msg_id(objc_getClass("NSApplication"), sel_registerName("sharedApplication"))
	msg_void(app, sel_registerName("run"))
}
