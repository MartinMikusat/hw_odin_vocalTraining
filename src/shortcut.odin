package main

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:unicode/utf8"

Video_Clips_Shortcut_Modifier :: enum {
	Control,
	Option,
	Shift,
	Command,
}

Video_Clips_Shortcut_Modifiers :: bit_set[Video_Clips_Shortcut_Modifier]

Video_Clips_Shortcut_Key_Kind :: enum {
	Character,
	Named,
}

Video_Clips_Shortcut :: struct {
	kind: Video_Clips_Shortcut_Key_Kind,
	key: string,
	modifiers: Video_Clips_Shortcut_Modifiers,
}

Video_Clips_Shortcut_Wire :: struct {
	version: int,
	kind: string,
	key: string,
	modifiers: []string,
}

video_clips_shortcut_default :: proc() -> Video_Clips_Shortcut {
	return {kind = .Character, key = "/"}
}

video_clips_shortcut_clone :: proc(
	value: Video_Clips_Shortcut,
	allocator := context.allocator,
) -> Video_Clips_Shortcut {
	return {
		kind = value.kind,
		key = strings.clone(value.key, allocator),
		modifiers = value.modifiers,
	}
}

video_clips_shortcut_destroy :: proc(value: ^Video_Clips_Shortcut) {
	if value == nil {return}
	delete(value.key)
	value^ = {}
}

video_clips_shortcut_equal :: proc(a, b: Video_Clips_Shortcut) -> bool {
	return a.kind == b.kind && a.key == b.key && a.modifiers == b.modifiers
}

video_clips_shortcut_modifiers_from_event :: proc(flags: uint) -> Video_Clips_Shortcut_Modifiers {
	result: Video_Clips_Shortcut_Modifiers
	if flags & NSEventModifierFlagControl != 0 {result += {.Control}}
	if flags & NSEventModifierFlagOption != 0 {result += {.Option}}
	if flags & NSEventModifierFlagShift != 0 {result += {.Shift}}
	if flags & NSEventModifierFlagCommand != 0 {result += {.Command}}
	return result
}

video_clips_shortcut_named_key :: proc(key_code: uint) -> (string, bool) {
	switch key_code {
	case 123: return "left", true
	case 124: return "right", true
	case 125: return "down", true
	case 126: return "up", true
	case 115: return "home", true
	case 119: return "end", true
	case 116: return "page-up", true
	case 121: return "page-down", true
	case 122: return "f1", true
	case 120: return "f2", true
	case 99: return "f3", true
	case 118: return "f4", true
	case 96: return "f5", true
	case 97: return "f6", true
	case 98: return "f7", true
	case 100: return "f8", true
	case 101: return "f9", true
	case 109: return "f10", true
	case 103: return "f11", true
	case 111: return "f12", true
	case 105: return "f13", true
	case 107: return "f14", true
	case 113: return "f15", true
	case 106: return "f16", true
	case 64: return "f17", true
	case 79: return "f18", true
	case 80: return "f19", true
	case 90: return "f20", true
	}
	return "", false
}

video_clips_shortcut_control_key :: proc(key_code: uint) -> bool {
	return key_code == 53 || key_code == 36 || key_code == 76 ||
	       key_code == 48 || key_code == 51 || key_code == 117
}

video_clips_shortcut_from_event :: proc(
	key_code: uint,
	text: string,
	flags: uint,
	allocator := context.allocator,
) -> (Video_Clips_Shortcut, bool) {
	if video_clips_shortcut_control_key(key_code) {return {}, false}
	modifiers := video_clips_shortcut_modifiers_from_event(flags)
	if named, found := video_clips_shortcut_named_key(key_code); found {
		return {
			kind = .Named,
			key = strings.clone(named, allocator),
			modifiers = modifiers,
		}, true
	}
	if len(text) == 0 {return {}, false}
	key := text
	if len(key) == 1 && key[0] >= 'A' && key[0] <= 'Z' {
		lower := [1]u8{key[0]+'a'-'A'}
		return {
			kind = .Character,
			key = strings.clone(string(lower[:]), allocator),
			modifiers = modifiers,
		}, true
	}
	rune_value, _ := utf8.decode_rune(key)
	if utf8.rune_count(key) != 1 || rune_value < 0x20 {return {}, false}
	return {
		kind = .Character,
		key = strings.clone(key, allocator),
		modifiers = modifiers,
	}, true
}

video_clips_shortcut_matches_event :: proc(
	shortcut: Video_Clips_Shortcut,
	key_code: uint,
	text: string,
	flags: uint,
) -> bool {
	candidate, valid := video_clips_shortcut_from_event(
		key_code,
		text,
		flags,
		context.temp_allocator,
	)
	return valid && video_clips_shortcut_equal(shortcut, candidate)
}

video_clips_shortcut_display_key :: proc(
	value: Video_Clips_Shortcut,
	allocator := context.temp_allocator,
) -> string {
	if value.kind == .Character {
		if value.key == " " {return "SPACE"}
		return strings.to_upper(value.key, allocator)
	}
	switch value.key {
	case "left": return "←"
	case "right": return "→"
	case "down": return "↓"
	case "up": return "↑"
	case "home": return "HOME"
	case "end": return "END"
	case "page-up": return "PAGE UP"
	case "page-down": return "PAGE DOWN"
	case:
		return strings.to_upper(value.key, allocator)
	}
}

video_clips_shortcut_display :: proc(
	value: Video_Clips_Shortcut,
	allocator := context.temp_allocator,
) -> string {
	builder: strings.Builder
	strings.builder_init(&builder, allocator)
	if .Control in value.modifiers {strings.write_string(&builder, "⌃")}
	if .Option in value.modifiers {strings.write_string(&builder, "⌥")}
	if .Shift in value.modifiers {strings.write_string(&builder, "⇧")}
	if .Command in value.modifiers {strings.write_string(&builder, "⌘")}
	strings.write_string(&builder, video_clips_shortcut_display_key(value))
	return strings.to_string(builder)
}

video_clips_shortcut_character :: proc(
	key: string,
	modifiers: Video_Clips_Shortcut_Modifiers = {},
) -> Video_Clips_Shortcut {
	return {kind = .Character, key = key, modifiers = modifiers}
}

video_clips_shortcut_named :: proc(
	key: string,
	modifiers: Video_Clips_Shortcut_Modifiers = {},
) -> Video_Clips_Shortcut {
	return {kind = .Named, key = key, modifiers = modifiers}
}

video_clips_shortcut_collision :: proc(value: Video_Clips_Shortcut) -> (string, bool) {
	collisions := []struct {
		shortcut: Video_Clips_Shortcut,
		owner: string,
	}{
		{video_clips_shortcut_character("k", {.Control}), "Command palette"},
		{video_clips_shortcut_character(",", {.Command}), "Open Settings"},
		{video_clips_shortcut_character(" "), "Play or pause"},
		{video_clips_shortcut_named("left"), "Scrub backward"},
		{video_clips_shortcut_named("right"), "Scrub forward"},
		{video_clips_shortcut_named("left", {.Shift}), "Fine scrub backward"},
		{video_clips_shortcut_named("right", {.Shift}), "Fine scrub forward"},
		{video_clips_shortcut_named("left", {.Command}), "Scrub backward ten seconds"},
		{video_clips_shortcut_named("right", {.Command}), "Scrub forward ten seconds"},
		{video_clips_shortcut_character("q", {.Command}), "Quit application"},
		{video_clips_shortcut_character("w", {.Command}), "Close window"},
		{video_clips_shortcut_character("m", {.Command}), "Minimize window"},
		{video_clips_shortcut_character("h", {.Command}), "Hide application"},
		{video_clips_shortcut_character("h", {.Option, .Command}), "Hide other applications"},
		{video_clips_shortcut_character(" ", {.Command}), "Spotlight"},
		{video_clips_shortcut_character(" ", {.Option, .Command}), "Finder search"},
		{video_clips_shortcut_character("3", {.Shift, .Command}), "Screenshot"},
		{video_clips_shortcut_character("4", {.Shift, .Command}), "Screenshot selection"},
		{video_clips_shortcut_character("5", {.Shift, .Command}), "Screenshot controls"},
		{video_clips_shortcut_character("q", {.Shift, .Command}), "Log out"},
		{video_clips_shortcut_character("q", {.Control, .Command}), "Lock screen"},
		{video_clips_shortcut_character("d", {.Option, .Command}), "Show or hide the Dock"},
		{video_clips_shortcut_named("up", {.Control}), "Mission Control"},
		{video_clips_shortcut_named("down", {.Control}), "Application windows"},
		{video_clips_shortcut_named("left", {.Control}), "Previous desktop"},
		{video_clips_shortcut_named("right", {.Control}), "Next desktop"},
	}
	for index in 0..<3 {
		key := [1]u8{u8('1'+index)}
		candidate := video_clips_shortcut_character(string(key[:]))
		if video_clips_shortcut_equal(value, candidate) {
			return fmt.aprintf(
				"Numbered action section %s",
				string(key[:]),
				allocator = context.temp_allocator,
			), true
		}
	}
	for collision in collisions {
		if video_clips_shortcut_equal(value, collision.shortcut) {
			return collision.owner, true
		}
	}
	return "", false
}

video_clips_shortcut_serialize :: proc(
	value: Video_Clips_Shortcut,
	allocator := context.allocator,
) -> (string, bool) {
	modifiers := make([dynamic]string, context.temp_allocator)
	if .Control in value.modifiers {append(&modifiers, "control")}
	if .Option in value.modifiers {append(&modifiers, "option")}
	if .Shift in value.modifiers {append(&modifiers, "shift")}
	if .Command in value.modifiers {append(&modifiers, "command")}
	kind := "character"
	if value.kind == .Named {kind = "named"}
	bytes, marshal_error := json.marshal(
		Video_Clips_Shortcut_Wire{
			version = 1,
			kind = kind,
			key = value.key,
			modifiers = modifiers[:],
		},
		allocator = allocator,
	)
	if marshal_error != nil {return "", false}
	return string(bytes), true
}

video_clips_shortcut_deserialize :: proc(
	value: string,
	allocator := context.allocator,
) -> (Video_Clips_Shortcut, bool) {
	wire: Video_Clips_Shortcut_Wire
	if error := json.unmarshal(transmute([]u8)value, &wire); error != nil {
		return {}, false
	}
	defer delete(wire.kind)
	defer delete(wire.key)
	defer {
		for modifier in wire.modifiers {delete(modifier)}
		delete(wire.modifiers)
	}
	if wire.version != 1 || len(wire.key) == 0 {return {}, false}
	kind: Video_Clips_Shortcut_Key_Kind
	switch wire.kind {
	case "character":
		kind = .Character
		if utf8.rune_count(wire.key) != 1 {return {}, false}
	case "named":
		kind = .Named
		valid := false
		for code := uint(0); code <= 126; code += 1 {
			if named, found := video_clips_shortcut_named_key(code);
			   found && named == wire.key {
				valid = true
				break
			}
		}
		if !valid {return {}, false}
	case:
		return {}, false
	}
	modifiers: Video_Clips_Shortcut_Modifiers
	for modifier in wire.modifiers {
		switch modifier {
		case "control": modifiers += {.Control}
		case "option": modifiers += {.Option}
		case "shift": modifiers += {.Shift}
		case "command": modifiers += {.Command}
		case: return {}, false
		}
	}
	result := Video_Clips_Shortcut{
		kind = kind,
		key = strings.clone(wire.key, allocator),
		modifiers = modifiers,
	}
	if owner, collides := video_clips_shortcut_collision(result); collides {
		_ = owner
		video_clips_shortcut_destroy(&result)
		return {}, false
	}
	return result, true
}
