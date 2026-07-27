package main

import "base:runtime"
import "core:dynlib"
import "core:fmt"
import "core:mem"
import "core:os"
import os2 "core:os/os2"
import "core:strings"
import hot_reload "../hot_reload_contract"

Id :: rawptr
Sel :: rawptr

foreign import objc "system:objc"
foreign objc {
	objc_getClass :: proc "c" (name: cstring) -> Id ---
	objc_getProtocol :: proc "c" (name: cstring) -> Id ---
	sel_registerName :: proc "c" (name: cstring) -> Sel ---
	objc_allocateClassPair :: proc "c" (superclass: Id, name: cstring, extra: uint) -> Id ---
	objc_registerClassPair :: proc "c" (cls: Id) ---
	class_addMethod :: proc "c" (cls: Id, name: Sel, imp: rawptr, types: cstring) -> bool ---
	class_addProtocol :: proc "c" (cls: Id, protocol: Id) -> bool ---
}

Loaded_Module :: struct {
	api:         ^hot_reload.Module_API,
	library:     dynlib.Library,
	shadow_path: string,
	write_time:  os.File_Time,
	generation:  int,
}

objc_send_address: rawptr
module_path: string
current_module: Loaded_Module
loaded_modules: [dynamic]Loaded_Module
services: hot_reload.Host_Services
snapshot: rawptr
last_failed_write: os.File_Time
has_failed_write: bool
restart_requested: bool

objc_initialize :: proc() -> bool {
	handle := os.dlopen("/usr/lib/libobjc.A.dylib", os.RTLD_NOW)
	if handle == nil {return false}
	objc_send_address = os.dlsym(handle, "objc_msgSend")
	return objc_send_address != nil
}

msg_id :: proc(receiver: Id, selector: Sel) -> Id {
	p := transmute(proc "c" (Id, Sel) -> Id)objc_send_address
	return p(receiver, selector)
}

msg_void :: proc(receiver: Id, selector: Sel) {
	p := transmute(proc "c" (Id, Sel))objc_send_address
	p(receiver, selector)
}

msg_void_id :: proc(receiver: Id, selector: Sel, value: Id) {
	p := transmute(proc "c" (Id, Sel, Id))objc_send_address
	p(receiver, selector, value)
}

callback :: proc "contextless" (kind: hot_reload.Callback) -> rawptr {
	if current_module.api == nil {return nil}
	return current_module.api.callbacks[int(kind)]
}

callback_for_void3 :: proc "contextless" (command: Sel) -> rawptr {
	kind: hot_reload.Callback
	switch command {
	case sel_registerName("importFinished:"): kind = .Import_Finished
	case sel_registerName("exportFinished:"): kind = .Export_Finished
	case sel_registerName("sourceMetadataFinished:"): kind = .Source_Metadata_Finished
	case sel_registerName("sourceProbeFinished:"): kind = .Source_Probe_Finished
	case sel_registerName("cliRequest:"): kind = .CLI_Request
	case sel_registerName("audioEngineConfigurationChanged:"): kind = .Audio_Configuration_Changed
	case sel_registerName("recoverAudioEngineConfiguration:"): kind = .Audio_Configuration_Recover
	case sel_registerName("mouseDown:"): kind = .Mouse_Down
	case sel_registerName("rightMouseDown:"): kind = .Right_Mouse_Down
	case sel_registerName("mouseMoved:"): kind = .Mouse_Moved
	case sel_registerName("mouseDragged:"): kind = .Mouse_Dragged
	case sel_registerName("mouseUp:"): kind = .Mouse_Up
	case sel_registerName("scrollWheel:"): kind = .Scroll
	case sel_registerName("keyDown:"): kind = .Key_Down
	case sel_registerName("copy:"): kind = .Copy
	case sel_registerName("cut:"): kind = .Cut
	case sel_registerName("paste:"): kind = .Paste
	case sel_registerName("selectAll:"): kind = .Select_All
	case sel_registerName("insertText:"): kind = .Insert_Text_Simple
	case sel_registerName("doCommandBySelector:"): kind = .Command
	case:
		return nil
	}
	return callback(kind)
}

host_void3 :: proc "c" (self: Id, command: Sel, value: Id) {
	if p := callback_for_void3(command); p != nil {
		(transmute(proc "c" (Id, Sel, Id))p)(self, command, value)
	}
}

host_frame :: proc "c" (self: Id, command: Sel, timer: Id) {
	context = runtime.default_context()
	host_try_reload()
	if restart_requested {return}
	if p := callback(.Frame); p != nil {
		(transmute(proc "c" (Id, Sel, Id))p)(self, command, timer)
	}
}

host_should_terminate :: proc "c" (self: Id, command: Sel, app: Id) -> bool {
	if p := callback(.Should_Terminate); p != nil {
		return (transmute(proc "c" (Id, Sel, Id) -> bool)p)(self, command, app)
	}
	return true
}

host_bool2 :: proc "c" (self: Id, command: Sel) -> bool {
	kind := hot_reload.Callback.Accepts_First
	switch command {
	case sel_registerName("accessibilityPerformPress"): kind = .AX_Press
	case sel_registerName("isAccessibilityElement"): kind = .AX_Is_Element
	case sel_registerName("hasMarkedText"): kind = .Has_Marked
	case sel_registerName("canBecomeKeyWindow"), sel_registerName("canBecomeMainWindow"):
		kind = .Window_Can_Become_Key
	}
	if p := callback(kind); p != nil {
		return (transmute(proc "c" (Id, Sel) -> bool)p)(self, command)
	}
	return kind == .Accepts_First || kind == .Window_Can_Become_Key
}

host_id2 :: proc "c" (self: Id, command: Sel) -> Id {
	kind := hot_reload.Callback.AX_Value
	switch command {
	case sel_registerName("accessibilityChildren"): kind = .AX_Children
	case sel_registerName("validAttributesForMarkedText"): kind = .Valid_Attributes
	}
	if p := callback(kind); p != nil {
		return (transmute(proc "c" (Id, Sel) -> Id)p)(self, command)
	}
	return nil
}

host_ax_set_value :: proc "c" (self: Id, command: Sel, value: Id) {
	if p := callback(.AX_Set_Value); p != nil {
		(transmute(proc "c" (Id, Sel, Id))p)(self, command, value)
	}
}

host_insert_text :: proc "c" (
	self: Id,
	command: Sel,
	value: Id,
	replacement: hot_reload.NS_Range,
) {
	if p := callback(.Insert_Text); p != nil {
		(transmute(proc "c" (Id, Sel, Id, hot_reload.NS_Range))p)(
			self,
			command,
			value,
			replacement,
		)
	}
}

host_set_marked :: proc "c" (
	self: Id,
	command: Sel,
	value: Id,
	selected, replacement: hot_reload.NS_Range,
) {
	if p := callback(.Set_Marked); p != nil {
		(transmute(proc "c" (
			Id,
			Sel,
			Id,
			hot_reload.NS_Range,
			hot_reload.NS_Range,
		))p)(self, command, value, selected, replacement)
	}
}

host_unmark :: proc "c" (self: Id, command: Sel) {
	if p := callback(.Unmark); p != nil {
		(transmute(proc "c" (Id, Sel))p)(self, command)
	}
}

host_range :: proc "c" (self: Id, command: Sel) -> hot_reload.NS_Range {
	kind := hot_reload.Callback.Marked_Range
	if command == sel_registerName("selectedRange") {kind = .Selected_Range}
	if p := callback(kind); p != nil {
		return (transmute(proc "c" (Id, Sel) -> hot_reload.NS_Range)p)(self, command)
	}
	return {}
}

host_attributed_substring :: proc "c" (
	self: Id,
	command: Sel,
range: hot_reload.NS_Range,
	actual: ^hot_reload.NS_Range,
) -> Id {
	if p := callback(.Attributed_Substring); p != nil {
		return (transmute(proc "c" (
			Id,
			Sel,
			hot_reload.NS_Range,
			^hot_reload.NS_Range,
		) -> Id)p)(self, command, range, actual)
	}
	return nil
}

host_character_index :: proc "c" (
	self: Id,
	command: Sel,
	point: hot_reload.Point,
) -> uint {
	if p := callback(.Character_Index); p != nil {
		return (transmute(proc "c" (Id, Sel, hot_reload.Point) -> uint)p)(
			self,
			command,
			point,
		)
	}
	return 0
}

host_first_rect :: proc "c" (
	self: Id,
	command: Sel,
	range: hot_reload.NS_Range,
	actual: ^hot_reload.NS_Range,
) -> hot_reload.Rect {
	if p := callback(.First_Rect); p != nil {
		return (transmute(proc "c" (
			Id,
			Sel,
			hot_reload.NS_Range,
			^hot_reload.NS_Range,
		) -> hot_reload.Rect)p)(self, command, range, actual)
	}
	return {}
}

add_void3 :: proc(class: Id, selector: cstring) {
	class_addMethod(class, sel_registerName(selector), rawptr(host_void3), "v@:@")
}

register_classes :: proc() -> bool {
	delegate_class := objc_allocateClassPair(
		objc_getClass("NSObject"),
		"VocalMetalDelegate",
		0,
	)
	if delegate_class == nil {return false}
	delegate_selectors := [8]cstring{
		"importFinished:",
		"exportFinished:",
		"sourceMetadataFinished:",
		"sourceProbeFinished:",
		"cliRequest:",
		"audioEngineConfigurationChanged:",
		"recoverAudioEngineConfiguration:",
		"metalFrame:",
	}
	for selector in delegate_selectors {
		if selector == "metalFrame:" {
			class_addMethod(delegate_class, sel_registerName(selector), rawptr(host_frame), "v@:@")
		} else {
			add_void3(delegate_class, selector)
		}
	}
	class_addMethod(
		delegate_class,
		sel_registerName("applicationShouldTerminateAfterLastWindowClosed:"),
		rawptr(host_should_terminate),
		"B@:@",
	)
	objc_registerClassPair(delegate_class)
	services.delegate = msg_id(delegate_class, sel_registerName("new"))

	view_class := objc_allocateClassPair(
		objc_getClass("NSView"),
		"VocalMetalView",
		0,
	)
	if view_class == nil {return false}
	if protocol := objc_getProtocol("NSTextInputClient"); protocol != nil {
		class_addProtocol(view_class, protocol)
	}
	class_addMethod(view_class, sel_registerName("acceptsFirstResponder"), rawptr(host_bool2), "B@:")
	view_selectors := [13]cstring{
		"mouseDown:",
		"rightMouseDown:",
		"mouseMoved:",
		"mouseDragged:",
		"mouseUp:",
		"scrollWheel:",
		"keyDown:",
		"copy:",
		"cut:",
		"paste:",
		"selectAll:",
		"insertText:",
		"doCommandBySelector:",
	}
	for selector in view_selectors {
		add_void3(view_class, selector)
	}
	class_addMethod(
		view_class,
		sel_registerName("insertText:replacementRange:"),
		rawptr(host_insert_text),
		"v@:@{_NSRange=QQ}",
	)
	class_addMethod(
		view_class,
		sel_registerName("setMarkedText:selectedRange:replacementRange:"),
		rawptr(host_set_marked),
		"v@:@{_NSRange=QQ}{_NSRange=QQ}",
	)
	class_addMethod(view_class, sel_registerName("unmarkText"), rawptr(host_unmark), "v@:")
	class_addMethod(view_class, sel_registerName("hasMarkedText"), rawptr(host_bool2), "B@:")
	class_addMethod(view_class, sel_registerName("markedRange"), rawptr(host_range), "{_NSRange=QQ}@:")
	class_addMethod(view_class, sel_registerName("selectedRange"), rawptr(host_range), "{_NSRange=QQ}@:")
	class_addMethod(
		view_class,
		sel_registerName("validAttributesForMarkedText"),
		rawptr(host_id2),
		"@@:",
	)
	class_addMethod(
		view_class,
		sel_registerName("attributedSubstringForProposedRange:actualRange:"),
		rawptr(host_attributed_substring),
		"@@:{_NSRange=QQ}^{_NSRange=QQ}",
	)
	class_addMethod(
		view_class,
		sel_registerName("characterIndexForPoint:"),
		rawptr(host_character_index),
		"Q@:{CGPoint=dd}",
	)
	class_addMethod(
		view_class,
		sel_registerName("firstRectForCharacterRange:actualRange:"),
		rawptr(host_first_rect),
		"{CGRect={CGPoint=dd}{CGSize=dd}}@:{_NSRange=QQ}^{_NSRange=QQ}",
	)
	class_addMethod(view_class, sel_registerName("isAccessibilityElement"), rawptr(host_bool2), "B@:")
	class_addMethod(view_class, sel_registerName("accessibilityChildren"), rawptr(host_id2), "@@:")
	objc_registerClassPair(view_class)
	services.view_class = view_class

	ax_class := objc_allocateClassPair(
		objc_getClass("NSAccessibilityElement"),
		"VocalAccessibilityElement",
		0,
	)
	if ax_class == nil {return false}
	class_addMethod(ax_class, sel_registerName("accessibilityPerformPress"), rawptr(host_bool2), "B@:")
	class_addMethod(ax_class, sel_registerName("accessibilityValue"), rawptr(host_id2), "@@:")
	class_addMethod(ax_class, sel_registerName("setAccessibilityValue:"), rawptr(host_ax_set_value), "v@:@")
	objc_registerClassPair(ax_class)
	services.accessibility_class = ax_class

	window_class := objc_allocateClassPair(
		objc_getClass("NSWindow"),
		"VocalTrainingWindow",
		0,
	)
	if window_class == nil {return false}
	class_addMethod(window_class, sel_registerName("canBecomeKeyWindow"), rawptr(host_bool2), "B@:")
	class_addMethod(window_class, sel_registerName("canBecomeMainWindow"), rawptr(host_bool2), "B@:")
	objc_registerClassPair(window_class)
	services.window_class = window_class
	return true
}

load_module :: proc(generation: int) -> (Loaded_Module, bool) {
	write_time, write_error := os.last_write_time_by_name(module_path)
	if write_error != os.ERROR_NONE {return {}, false}
	shadow_path := strings.clone(fmt.tprintf("%s.generation-%d", module_path, generation))
	if copy_error := os2.copy_file(shadow_path, module_path); copy_error != nil {
		delete(shadow_path)
		return {}, false
	}
	library, loaded := dynlib.load_library(shadow_path)
	if !loaded {
		_ = os.remove(shadow_path)
		delete(shadow_path)
		return {}, false
	}
	getter_address, found := dynlib.symbol_address(
		library,
		"vocal_hot_reload_get_api",
	)
	if !found {
		_ = dynlib.unload_library(library)
		_ = os.remove(shadow_path)
		delete(shadow_path)
		return {}, false
	}
	getter := transmute(proc "c" () -> ^hot_reload.Module_API)getter_address
	api := getter()
	if api == nil {
		_ = dynlib.unload_library(library)
		_ = os.remove(shadow_path)
		delete(shadow_path)
		return {}, false
	}
	return {
		api = api,
		library = library,
		shadow_path = shadow_path,
		write_time = write_time,
		generation = generation,
	}, true
}

discard_module :: proc(module: ^Loaded_Module) {
	if module.library != nil {_ = dynlib.unload_library(module.library)}
	if len(module.shadow_path) > 0 {
		_ = os.remove(module.shadow_path)
		delete(module.shadow_path)
	}
	module^ = {}
}

request_restart :: proc(reason: string) {
	fmt.printf("[vocal-training] %s; restarting the hot-reload host\n", reason)
	restart_requested = true
	msg_void_id(Id(services.app), sel_registerName("stop:"), nil)
}

host_try_reload :: proc() {
	write_time, write_error := os.last_write_time_by_name(module_path)
	if write_error != os.ERROR_NONE || write_time == current_module.write_time {return}
	if has_failed_write && write_time == last_failed_write {return}
	can_reload := transmute(proc "c" () -> bool)current_module.api.can_reload
	if can_reload == nil || !can_reload() {return}

	candidate, loaded := load_module(current_module.generation + 1)
	if !loaded {
		last_failed_write = write_time
		has_failed_write = true
		fmt.eprintln("[vocal-training] reload module could not be loaded; keeping the current generation")
		return
	}
	if candidate.api.api_version != hot_reload.API_VERSION {
		discard_module(&candidate)
		request_restart("hot-reload API changed")
		return
	}
	if candidate.api.state_version != current_module.api.state_version ||
	   candidate.api.snapshot_size != current_module.api.snapshot_size ||
	   candidate.api.snapshot_align != current_module.api.snapshot_align {
		discard_module(&candidate)
		request_restart("hot-reload state layout changed")
		return
	}

	before_swap := transmute(proc "c" ())current_module.api.before_swap
	capture := transmute(proc "c" (rawptr))current_module.api.capture
	stage := transmute(proc "c" (rawptr, ^hot_reload.Host_Services) -> bool)candidate.api.stage
	commit_current := transmute(proc "c" ())current_module.api.commit
	if before_swap == nil || capture == nil || stage == nil {
		discard_module(&candidate)
		last_failed_write = write_time
		has_failed_write = true
		return
	}
	before_swap()
	capture(snapshot)
	if !stage(snapshot, &services) {
		if commit_current != nil {commit_current()}
		discard_module(&candidate)
		last_failed_write = write_time
		has_failed_write = true
		fmt.eprintln("[vocal-training] reload staging failed; keeping the current generation")
		return
	}

	append(&loaded_modules, candidate)
	current_module = candidate
	commit := transmute(proc "c" ())current_module.api.commit
	if commit != nil {commit()}
	has_failed_write = false
	fmt.printf("[vocal-training] hot reloaded generation %d\n", current_module.generation)
}

run_cli :: proc(host_args: []string) -> int {
	module, loaded := load_module(0)
	if !loaded || module.api.api_version != hot_reload.API_VERSION {
		if loaded {discard_module(&module)}
		fmt.eprintln("[vocal-training] could not load the development CLI module")
		return 1
	}
	defer discard_module(&module)
	cli_main := transmute(proc "c" ([^]cstring, int) -> i32)module.api.cli_main
	if cli_main == nil {return 1}
	args := make([]cstring, len(host_args), context.temp_allocator)
	for value, index in host_args {
		args[index] = strings.clone_to_cstring(value, context.temp_allocator)
	}
	return int(cli_main(raw_data(args), len(args)))
}

run_gui :: proc() -> int {
	first, loaded := load_module(1)
	if !loaded || first.api.api_version != hot_reload.API_VERSION {
		if loaded {discard_module(&first)}
		fmt.eprintln("[vocal-training] could not load the initial hot-reload module")
		return 1
	}
	current_module = first
	loaded_modules = make([dynamic]Loaded_Module)
	append(&loaded_modules, first)

	if !objc_initialize() || !register_classes() {
		fmt.eprintln("[vocal-training] could not initialize the hot-reload AppKit host")
		return 1
	}
	services.app = msg_id(objc_getClass("NSApplication"), sel_registerName("sharedApplication"))
	services.launch_in_background = true
	initialize := transmute(proc "c" (^hot_reload.Host_Services) -> bool)current_module.api.initialize
	if initialize == nil || !initialize(&services) {
		fmt.eprintln("[vocal-training] could not initialize the application module")
		return 1
	}
	snapshot = mem.alloc(
		current_module.api.snapshot_size,
		current_module.api.snapshot_align,
	) or_else nil
	if snapshot == nil {return 1}
	defer mem.free(snapshot)

	timer_send := transmute(proc "c" (
		Id,
		Sel,
		f64,
		Id,
		Sel,
		Id,
		bool,
	) -> Id)objc_send_address
	frame_timer := timer_send(
		objc_getClass("NSTimer"),
		sel_registerName("scheduledTimerWithTimeInterval:target:selector:userInfo:repeats:"),
		1.0/60.0,
		Id(services.delegate),
		sel_registerName("metalFrame:"),
		nil,
		true,
	)
	main_run_loop := msg_id(objc_getClass("NSRunLoop"), sel_registerName("mainRunLoop"))
	add_timer := transmute(proc "c" (Id, Sel, Id, Id))objc_send_address
	mode := msg_id_cstring(
		objc_getClass("NSString"),
		sel_registerName("stringWithUTF8String:"),
		"NSEventTrackingRunLoopMode",
	)
	add_timer(main_run_loop, sel_registerName("addTimer:forMode:"), frame_timer, mode)
	msg_void(Id(services.app), sel_registerName("run"))

	shutdown := transmute(proc "c" ())current_module.api.shutdown
	if shutdown != nil {shutdown()}
	for &module in loaded_modules {
		discard_module(&module)
	}
	delete(loaded_modules)
	if restart_requested {return hot_reload.RESTART_EXIT_CODE}
	return 0
}

msg_id_cstring :: proc(receiver: Id, selector: Sel, value: cstring) -> Id {
	p := transmute(proc "c" (Id, Sel, cstring) -> Id)objc_send_address
	return p(receiver, selector, value)
}

main :: proc() {
	host_args := make([]string, len(os.args))
	for value, index in os.args {
		host_args[index] = strings.clone(value)
	}
	module_path = os.get_env("VT_HOT_RELOAD_MODULE")
	if len(module_path) == 0 {
		fmt.eprintln("[vocal-training] VT_HOT_RELOAD_MODULE is not set")
		os.exit(2)
	}
	exit_code := 0
	if len(host_args) > 1 {
		exit_code = run_cli(host_args)
	} else {
		exit_code = run_gui()
	}
	os.exit(exit_code)
}
