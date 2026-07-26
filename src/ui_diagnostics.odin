package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:sys/posix"
import "core:time"
import mem_virtual "core:mem/virtual"
import command_palette "command_palette:."

UI_DIAGNOSTIC_SCHEMA_VERSION :: 1
UI_DIAGNOSTIC_ARTIFACT_RETENTION :: 20

UI_Diagnostic_Surface :: struct {
	mode:       string,
	overlay:    string,
	background: string,
}

UI_Diagnostic_Rect :: struct {
	x: f64,
	y: f64,
	w: f64,
	h: f64,
}

UI_Diagnostic_Control :: struct {
	id:                  u64,
	functional_name:     string,
	action_kind:         string,
	action_index:        int,
	action_value:        int,
	action_seconds:      f64,
	rect:                UI_Diagnostic_Rect,
	flags:               u64,
	flash_label:         string,
	accessibility_label: string,
	accessibility_role:  string,
}

UI_Diagnostic_Snapshot :: struct {
	schema_version: int,
	process_id:     int,
	frame:          int,
	surface:        UI_Diagnostic_Surface,
	controls:       []UI_Diagnostic_Control,
}

UI_Diagnostic_Change :: struct {
	functional_name: string,
	reason:          string,
}

UI_Diagnostic_Diff :: struct {
	ok:              bool,
	retained_count:  int,
	added:           [dynamic]string,
	disabled:        [dynamic]string,
	removed:         [dynamic]string,
	changed:         [dynamic]UI_Diagnostic_Change,
	unexpected:      [dynamic]string,
	contract_issues: [dynamic]string,
}

UI_Diagnostic_Check_Artifact :: struct {
	schema_version: int,
	contract:       string,
	baseline:       UI_Diagnostic_Snapshot,
	current:        UI_Diagnostic_Snapshot,
	diff:           UI_Diagnostic_Diff,
}

UI_Diagnostic_Artifact_File :: struct {
	path:          string,
	name:          string,
	modified_nano: i64,
}

ui_diagnostic_artifact_serial: int

ui_diagnostic_surface :: proc(allocator := context.allocator) -> UI_Diagnostic_Surface {
	mode := "create"
	if ui.mode == .Play {mode = "play"}
	overlay := "none"
	switch {
	case command_palette.is_open(&command_palette_state): overlay = "command-palette"
	case ui.notification_modal_open: overlay = "notification-history"
	case ui.exercise_metadata_open: overlay = "exercise-metadata"
	case ui.exercise_rename_open: overlay = "exercise-rename"
	case ui.source_modal_open: overlay = "source-modal"
	case ui.source_details_open: overlay = "source-details"
	}
	background := "none"
	switch {
	case import_job != nil: background = "import"
	case export_job != nil: background = "export"
	case source_probe_job != nil: background = "source-probe"
	}
	return UI_Diagnostic_Surface{
		mode = strings.clone(mode, allocator),
		overlay = strings.clone(overlay, allocator),
		background = strings.clone(background, allocator),
	}
}

ui_diagnostic_snapshot :: proc(
	controls: []UI_Control,
	surface: UI_Diagnostic_Surface,
	frame: int,
	allocator := context.allocator,
) -> UI_Diagnostic_Snapshot {
	outputs := make([]UI_Diagnostic_Control, len(controls), allocator)
	for control, index in controls {
		outputs[index] = UI_Diagnostic_Control{
			id = u64(control.id),
			functional_name = strings.clone(control.functional_name, allocator),
			action_kind = fmt.aprintf("%v", control.action.kind, allocator=allocator),
			action_index = control.action.index,
			action_value = control.action.value,
			action_seconds = control.action.seconds,
			rect = UI_Diagnostic_Rect{
				x = control.rect.x,
				y = control.rect.y,
				w = control.rect.w,
				h = control.rect.h,
			},
			flags = ui_diagnostic_flags(control.flags),
			flash_label = strings.clone(control.flash_label, allocator),
			accessibility_label = strings.clone(control.accessibility_label, allocator),
			accessibility_role = strings.clone(control.accessibility_role, allocator),
		}
	}
	return UI_Diagnostic_Snapshot{
		schema_version = UI_DIAGNOSTIC_SCHEMA_VERSION,
		process_id = int(posix.getpid()),
		frame = frame,
		surface = UI_Diagnostic_Surface{
			mode = strings.clone(surface.mode, allocator),
			overlay = strings.clone(surface.overlay, allocator),
			background = strings.clone(surface.background, allocator),
		},
		controls = outputs,
	}
}

ui_diagnostic_capture_current :: proc(
	allocator := context.allocator,
) -> (UI_Diagnostic_Snapshot, bool) {
	arena, arena_ok := growing_arena_create()
	if !arena_ok {return {}, false}
	previous_build := ui_build
	build_ui_controls(false, mem_virtual.arena_allocator(arena))
	if len(ui_build.controls) == 0 || !ui_controls_valid(ui_build.controls[:]) {
		ui_build = previous_build
		growing_arena_destroy(arena)
		return {}, false
	}
	snapshot := ui_diagnostic_snapshot(
		ui_build.controls[:],
		ui_build.diagnostic_surface,
		ui_build.frame,
		allocator,
	)
	ui_build = previous_build
	growing_arena_destroy(arena)
	return snapshot, true
}

ui_diagnostic_flags :: proc(flags: UI_Control_Flags) -> u64 {
	value: u64
	for flag in flags {
		value |= u64(1) << u64(flag)
	}
	return value
}

ui_diagnostic_find_control :: proc(
	controls: []UI_Diagnostic_Control,
	functional_name: string,
) -> ^UI_Diagnostic_Control {
	for &control in controls {
		if control.functional_name == functional_name {return &control}
	}
	return nil
}

ui_diagnostic_control_enabled :: proc(control: ^UI_Diagnostic_Control) -> bool {
	return u64(1) << u64(UI_Control_Flag.Enabled) & control.flags != 0
}

ui_diagnostic_stable_flags :: proc(control: ^UI_Diagnostic_Control) -> u64 {
	transient := u64(1) << u64(UI_Control_Flag.Enabled) |
	             u64(1) << u64(UI_Control_Flag.Flash) |
	             u64(1) << u64(UI_Control_Flag.Primary_Press)
	return control.flags & ~transient
}

ui_diagnostic_control_change :: proc(
	baseline, current: ^UI_Diagnostic_Control,
) -> string {
	if baseline.id != current.id {return "identifier"}
	if baseline.action_kind != current.action_kind ||
	   baseline.action_index != current.action_index ||
	   baseline.action_value != current.action_value ||
	   baseline.action_seconds != current.action_seconds {
		return "action"
	}
	if baseline.rect != current.rect {return "rectangle"}
	if baseline.accessibility_role != current.accessibility_role {return "accessibility-role"}
	baseline_enabled := ui_diagnostic_control_enabled(baseline)
	current_enabled := ui_diagnostic_control_enabled(current)
	if !baseline_enabled && current_enabled {return "unexpected-enable"}
	if baseline_enabled && current_enabled && baseline.flags != current.flags {return "capabilities"}
	if baseline_enabled != current_enabled &&
	   ui_diagnostic_stable_flags(baseline) != ui_diagnostic_stable_flags(current) {
		return "capabilities"
	}
	if !baseline_enabled && !current_enabled && baseline.flags != current.flags {return "capabilities"}
	return ""
}

ui_diagnostic_added_control_allowed :: proc(
	control: ^UI_Diagnostic_Control,
	current_background: string,
) -> bool {
	return current_background == "import" && control.action_kind == "Stop_Download"
}

ui_diagnostic_compare_background :: proc(
	baseline, current: UI_Diagnostic_Snapshot,
	allocator := context.allocator,
) -> UI_Diagnostic_Diff {
	diff := UI_Diagnostic_Diff{
		added = make([dynamic]string, 0, len(current.controls), allocator),
		disabled = make([dynamic]string, 0, len(baseline.controls), allocator),
		removed = make([dynamic]string, 0, len(baseline.controls), allocator),
		changed = make([dynamic]UI_Diagnostic_Change, 0, len(baseline.controls), allocator),
		unexpected = make([dynamic]string, 0, len(current.controls), allocator),
		contract_issues = make([dynamic]string, 0, 4, allocator),
	}
	if baseline.schema_version != UI_DIAGNOSTIC_SCHEMA_VERSION ||
	   current.schema_version != UI_DIAGNOSTIC_SCHEMA_VERSION {
		append(&diff.contract_issues, strings.clone("schema-version", allocator))
	}
	if baseline.process_id != current.process_id {
		append(&diff.contract_issues, strings.clone("process-changed", allocator))
	}
	if current.frame <= baseline.frame {
		append(&diff.contract_issues, strings.clone("frame-did-not-advance", allocator))
	}
	if baseline.surface.mode != current.surface.mode ||
	   baseline.surface.overlay != current.surface.overlay {
		append(&diff.contract_issues, strings.clone("surface-changed", allocator))
	}
	if baseline.surface.background != "none" {
		append(&diff.contract_issues, strings.clone("baseline-not-idle", allocator))
	}
	if current.surface.background == "none" {
		append(&diff.contract_issues, strings.clone("current-not-busy", allocator))
	}
	for &baseline_control in baseline.controls {
		current_control := ui_diagnostic_find_control(
			current.controls,
			baseline_control.functional_name,
		)
		if current_control == nil {
			append(&diff.removed, strings.clone(baseline_control.functional_name, allocator))
			continue
		}
		diff.retained_count += 1
		if ui_diagnostic_control_enabled(&baseline_control) &&
		   !ui_diagnostic_control_enabled(current_control) {
			append(&diff.disabled, strings.clone(baseline_control.functional_name, allocator))
		}
		if reason := ui_diagnostic_control_change(&baseline_control, current_control);
		   len(reason) > 0 {
			if current.surface.background == "import" &&
			   current_control.action_kind == "Open_Notification_History" &&
			   reason == "rectangle" {
				continue
			}
			append(&diff.changed, UI_Diagnostic_Change{
				functional_name = strings.clone(baseline_control.functional_name, allocator),
				reason = strings.clone(reason, allocator),
			})
		}
	}
	for &current_control in current.controls {
		if ui_diagnostic_find_control(baseline.controls, current_control.functional_name) != nil {
			continue
		}
		append(&diff.added, strings.clone(current_control.functional_name, allocator))
		if !ui_diagnostic_added_control_allowed(
			&current_control,
			current.surface.background,
		) {
			append(&diff.unexpected, strings.clone(current_control.functional_name, allocator))
		}
	}
	diff.ok = len(diff.contract_issues) == 0 &&
	          len(diff.removed) == 0 &&
	          len(diff.changed) == 0 &&
	          len(diff.unexpected) == 0
	return diff
}

ui_diagnostic_enabled_count :: proc(snapshot: ^UI_Diagnostic_Snapshot) -> int {
	count := 0
	for &control in snapshot.controls {
		if ui_diagnostic_control_enabled(&control) {count += 1}
	}
	return count
}

ui_diagnostic_state_name :: proc(
	surface: UI_Diagnostic_Surface,
	allocator := context.allocator,
) -> string {
	activity := surface.background
	switch activity {
	case "none": activity = "idle"
	case "import": activity = "importing"
	case "export": activity = "exporting"
	case "source-probe": activity = "probing"
	}
	if surface.overlay != "none" {
		if surface.background == "none" {
			return fmt.aprintf(
				"%s.%s",
				surface.mode,
				surface.overlay,
				allocator = allocator,
			)
		}
		return fmt.aprintf(
			"%s.%s.%s",
			surface.mode,
			surface.overlay,
			activity,
			allocator = allocator,
		)
	}
	return fmt.aprintf(
		"%s.%s",
		surface.mode,
		activity,
		allocator = allocator,
	)
}

ui_diagnostic_artifact_path :: proc(
	kind: string,
	frame: int,
	allocator := context.allocator,
) -> string {
	ui_diagnostic_artifact_serial += 1
	directory := fmt.aprintf("%s/ui-checks", app_support_dir(), allocator=allocator)
	os.make_directory(app_support_dir())
	os.make_directory(directory)
	return fmt.aprintf(
		"%s/%s-%d-%d-%d.json",
		directory,
		kind,
		int(posix.getpid()),
		frame,
		ui_diagnostic_artifact_serial,
		allocator = allocator,
	)
}

ui_diagnostic_write_artifact :: proc(
	path: string,
	value: $T,
	allocator := context.allocator,
) -> bool {
	encoded, encode_error := json.marshal(
		value,
		{pretty=true, use_spaces=true, spaces=2},
		allocator,
	)
	if encode_error != nil {return false}
	if !os.write_entire_file(path, encoded) {return false}
	directory := filepath.dir(path, allocator)
	_ = ui_diagnostic_prune_artifacts(
		directory,
		UI_DIAGNOSTIC_ARTIFACT_RETENTION,
		allocator,
	)
	return true
}

ui_diagnostic_prune_artifacts :: proc(
	directory: string,
	keep: int,
	allocator := context.allocator,
) -> int {
	handle, open_error := os.open(directory)
	if open_error != nil {return 0}
	entries, read_error := os.read_dir(handle, -1, allocator)
	os.close(handle)
	if read_error != nil {return 0}
	files := make([dynamic]UI_Diagnostic_Artifact_File, 0, len(entries), allocator)
	for entry in entries {
		if entry.is_dir || !strings.has_suffix(entry.name, ".json") {continue}
		if !strings.has_prefix(entry.name, "snapshot-") &&
		   !strings.has_prefix(entry.name, "check-") {
			continue
		}
		append(&files, UI_Diagnostic_Artifact_File{
			path = entry.fullpath,
			name = entry.name,
			modified_nano = time.time_to_unix_nano(entry.modification_time),
		})
	}
	if len(files) <= keep {return 0}
	slice.sort_by(files[:], proc(a, b: UI_Diagnostic_Artifact_File) -> bool {
		if a.modified_nano == b.modified_nano {return a.name < b.name}
		return a.modified_nano < b.modified_nano
	})
	remove_count := len(files) - max(0, keep)
	removed := 0
	for index in 0..<remove_count {
		if os.remove(files[index].path) == nil {removed += 1}
	}
	return removed
}

ui_diagnostic_read_snapshot :: proc(
	path: string,
	allocator := context.allocator,
) -> (UI_Diagnostic_Snapshot, bool) {
	bytes, read_ok := os.read_entire_file(path, allocator)
	if !read_ok {return {}, false}
	snapshot: UI_Diagnostic_Snapshot
	if decode_error := json.unmarshal(bytes, &snapshot, .JSON, allocator);
	   decode_error != nil {
		return {}, false
	}
	if snapshot.schema_version != UI_DIAGNOSTIC_SCHEMA_VERSION ||
	   len(snapshot.controls) == 0 {
		return {}, false
	}
	return snapshot, true
}
