package hot_reload_contract

API_VERSION :: u32(1)
// Increment this value when a preserved state type changes without changing
// the snapshot size or alignment.
STATE_VERSION :: u32(1)
RESTART_EXIT_CODE :: 75

Point :: struct {x, y: f64}
Size :: struct {width, height: f64}
Rect :: struct {origin: Point, size: Size}
NS_Range :: struct {location, length: uint}

Host_Services :: struct {
	app:                 rawptr,
	delegate:            rawptr,
	view_class:          rawptr,
	accessibility_class: rawptr,
	window_class:        rawptr,
}

Module_API :: struct {
	api_version:    u32,
	state_version:  u32,
	snapshot_size:  int,
	snapshot_align: int,
	initialize:     rawptr,
	can_reload:     rawptr,
	capture:        rawptr,
	stage:          rawptr,
	before_swap:    rawptr,
	commit:         rawptr,
	shutdown:       rawptr,
	cli_main:       rawptr,
	callbacks:      [Callback_Count]rawptr,
}

Callback :: enum int {
	Import_Finished,
	Export_Finished,
	Source_Metadata_Finished,
	Source_Probe_Finished,
	Frame,
	CLI_Request,
	Audio_Configuration_Changed,
	Audio_Configuration_Recover,
	Should_Terminate,
	AX_Press,
	AX_Value,
	AX_Set_Value,
	AX_Children,
	AX_Is_Element,
	Accepts_First,
	Mouse_Down,
	Right_Mouse_Down,
	Mouse_Moved,
	Mouse_Dragged,
	Mouse_Up,
	Scroll,
	Key_Down,
	Copy,
	Cut,
	Paste,
	Select_All,
	Insert_Text_Simple,
	Insert_Text,
	Command,
	Set_Marked,
	Unmark,
	Has_Marked,
	Marked_Range,
	Selected_Range,
	Valid_Attributes,
	Attributed_Substring,
	Character_Index,
	First_Rect,
	Window_Can_Become_Key,
}

Callback_Count :: int(Callback.Window_Can_Become_Key) + 1
