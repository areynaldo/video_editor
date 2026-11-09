package main

import "core:os"
import "core:reflect"
import "core:strings"

import im "deps/odin-imgui"

// Keybindings live in keybindings.ini (created with defaults if missing).
// Sections group the actions; everything is lower case:
//
//   [timeline]
//   split = s
//   add_layer = ctrl+n
//
// One key per action. Optional prefixes: ctrl+ shift+ alt+. A lone modifier
// ("shift") is a hold-only binding. Key names are the Dear ImGui key names
// (a, space, delete, f5, left, ...), case-insensitive. '#' starts a comment.

KEYS_FILE :: "keybindings.ini"


Binding :: struct {
	key:              im.Key,
	ctrl, shift, alt: bool,
	text:             string, // as written in the file, for menu/button labels
}

bindings: [Action][2]Binding // up to two keys per action

DEFAULT_KEYS :: `# keybindings: action = key
# optional ctrl+ shift+ alt+ prefix. a lone modifier means "hold".
# key names are dear imgui key names (a, space, delete, f5, left, ...).
# actions missing from your file keep these defaults; write "action =" to unbind.
# press the reload_keys key to apply changes.

[file]
new_project = ctrl+shift+n
open_project = ctrl+o
save_project = ctrl+s
import = ctrl+i
export = ctrl+e
quit = ctrl+q

[edit]
duplicate = d
delete = delete, backspace
remove_audio = shift+delete
link = l
unlink = u
undo = ctrl+z
redo = ctrl+shift+z, ctrl+y
select_all = ctrl+a

[timeline]
split = s
play = space      # press twice quickly to return to the checkpoint
to_checkpoint = ctrl+home
go_start = home
go_end = end
step_back = leftarrow  # one frame
step_forward = rightarrow
add_layer = n
remove_layer = minus
stretch = shift   # hold while dragging a clip edge
no_snap = alt     # hold while dragging or scrubbing to ignore the grid
toggle_grid = g

[tools]         # premiere style
tool_select = v
tool_razor = c       # click a clip to cut it (shift: all tracks)
tool_hand = h        # drag to pan; middle mouse always pans
tool_zoom = z        # click zoom in, alt+click out; ctrl+wheel zooms anywhere

[program]   # switch between video layers on the grid, or live while playing
mark = m
beat_split = b
randomize = r
randomize_options = shift+r
apply_pattern = p
pattern_editor = shift+p
clear_cuts = shift+x
copy_cuts = ctrl+c
paste_cuts = ctrl+v
repeat_range = ctrl+r
loop_playback = ctrl+l
detect_bpm = t
tap_tempo = shift+t
grid_here = shift+h
layer_1 = 1, keypad1
layer_2 = 2, keypad2
layer_3 = 3, keypad3
layer_4 = 4, keypad4
layer_5 = 5, keypad5
layer_6 = 6, keypad6
layer_7 = 7, keypad7
layer_8 = 8, keypad8
layer_9 = 9, keypad9

[app]
command_palette = f1
reload_keys = f5
`

load_keys :: proc() -> (err: string) {
	bindings = {}
	_ = parse_keys(DEFAULT_KEYS) // defaults first, so actions missing from the file stay bound
	data, rerr := os.read_entire_file(KEYS_FILE, context.temp_allocator)
	if rerr != nil {
		_ = os.write_entire_file(KEYS_FILE, transmute([]byte)string(DEFAULT_KEYS))
		return ""
	}
	return parse_keys(string(data))
}

parse_keys :: proc(text: string) -> (err: string) {
	section := ""
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		line := line
		if i := strings.index_byte(line, '#'); i >= 0 {
			line = line[:i]
		}
		line = strings.trim_space(line)
		if line == "" {
			continue
		}
		if line[0] == '[' {
			section = strings.trim_space(strings.trim(line, "[]"))
			known := false
			for info in ACTION_INFO {
				known ||= strings.equal_fold(info.section, section)
			}
			if !known {
				return strings.concatenate({"keybindings.ini: unknown section [", section, "]"}, context.temp_allocator)
			}
			continue
		}
		eq := strings.index_byte(line, '=')
		if eq < 0 {
			return "keybindings.ini: expected 'action = key'"
		}
		name, value := strings.trim_space(line[:eq]), strings.trim_space(line[eq + 1:])
		action, found := find_action(section, name)
		if !found {
			continue // a command that no longer exists: ignore the line
		}
		bindings[action] = {}
		if value == "" { // "action =" unbinds
			continue
		}
		n := 0
		for part in strings.split(value, ",", context.temp_allocator) {
			if n >= len(bindings[action]) {
				return "keybindings.ini: at most two keys per action (a, b)"
			}
			b, ok := parse_binding(strings.trim_space(part))
			if !ok {
				return strings.concatenate({"keybindings.ini: unknown key ", part}, context.temp_allocator)
			}
			bindings[action][n] = b
			n += 1
		}
	}
	return ""
}

find_action :: proc(section, name: string) -> (a: Action, ok: bool) {
	for act in Action {
		if strings.equal_fold(ACTION_INFO[act].section, section) && strings.equal_fold(reflect.enum_string(act), name) {
			return act, true
		}
	}
	return
}

parse_binding :: proc(s: string) -> (b: Binding, ok: bool) {
	b.text = strings.clone(s)
	rest := s
	for {
		plus := strings.index_byte(rest, '+')
		if plus <= 0 || plus == len(rest) - 1 {
			break
		}
		switch {
		case strings.equal_fold(rest[:plus], "ctrl"):  b.ctrl = true
		case strings.equal_fold(rest[:plus], "shift"): b.shift = true
		case strings.equal_fold(rest[:plus], "alt"):   b.alt = true
		case: return
		}
		rest = rest[plus + 1:]
	}
	// a lone modifier (e.g. "shift") is a hold-only binding
	switch {
	case strings.equal_fold(rest, "ctrl"):  b.ctrl = true;  b.key = .None; return b, true
	case strings.equal_fold(rest, "shift"): b.shift = true; b.key = .None; return b, true
	case strings.equal_fold(rest, "alt"):   b.alt = true;   b.key = .None; return b, true
	}
	b.key, ok = find_enum(im.Key, rest)
	if !ok { // left/right/up/down are LeftArrow, ...
		b.key, ok = find_enum(im.Key, strings.concatenate({rest, "Arrow"}, context.temp_allocator))
	}
	if !ok { // digits are named _0.._9
		b.key, ok = find_enum(im.Key, strings.concatenate({"_", rest}, context.temp_allocator))
	}
	return
}

find_enum :: proc($T: typeid, name: string) -> (v: T, ok: bool) {
	for n, i in reflect.enum_field_names(T) {
		if strings.equal_fold(n, name) {
			return T(reflect.enum_field_values(T)[i]), true
		}
	}
	return
}

// True on the frame the action's key combo goes down (any of its bindings).
pressed :: proc(a: Action) -> bool {
	io := im.GetIO()
	if io.WantTextInput {
		return false
	}
	for b in bindings[a] {
		if b.text != "" && b.key != .None && im.IsKeyPressed(b.key, false) && io.KeyCtrl == b.ctrl && io.KeyShift == b.shift && io.KeyAlt == b.alt {
			return true
		}
	}
	return false
}

// True while the action's key (or lone modifier) is held down.
held :: proc(a: Action) -> bool {
	io := im.GetIO()
	for b in bindings[a] {
		if b.text == "" {continue}
		mods := (!b.ctrl || io.KeyCtrl) && (!b.shift || io.KeyShift) && (!b.alt || io.KeyAlt)
		if mods && (b.key == .None || im.IsKeyDown(b.key)) {
			return true
		}
	}
	return false
}

// Label with the bound key appended: "Split (s)".
labeled :: proc(a: Action, name: string) -> cstring {
	if bindings[a][0].text == "" {
		return strings.clone_to_cstring(name, context.temp_allocator)
	}
	return strings.clone_to_cstring(strings.concatenate({name, " (", bindings[a][0].text, ")"}, context.temp_allocator), context.temp_allocator)
}

shortcut_text :: proc(a: Action) -> cstring {
	if bindings[a][0].text == "" {
		return nil
	}
	return strings.clone_to_cstring(bindings[a][0].text, context.temp_allocator)
}
