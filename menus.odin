package main

import "core:fmt"
import "core:strings"

import im "deps/odin-imgui"

// Everything that lists commands: the menu bar, the F1 command palette and the
// right-click context menu are all generated from ACTION_INFO, so a command
// shows up everywhere it should after one table row.

show_randomize: bool

menu_action :: proc(a: Action, enabled := true) {
	if im.MenuItem(cstr(ACTION_INFO[a].name), shortcut_text(a), false, enabled) {
		do_action(a)
	}
}

action_enabled :: proc(a: Action) -> bool {
	#partial switch a {
	case .Undo: return len(undo_stack) > 0
	case .Redo: return len(redo_stack) > 0
	}
	return true
}

main_menu :: proc() {
	if !im.BeginMainMenuBar() {
		return
	}
	defer im.EndMainMenuBar()
	for group in MENU_GROUPS {
		if group == "Help" {
			view_menu()
		}
		if !im.BeginMenu(cstr(group)) {continue}
		for a in Action {
			info := ACTION_INFO[a]
			if info.group != group {continue}
			if info.sep {im.Separator()}
			menu_action(a, action_enabled(a))
		}
		im.EndMenu()
	}
	im.Separator()
	im.TextDisabled(cstr(status))
}

view_menu :: proc() {
	if !im.BeginMenu("View") {
		return
	}
	im.MenuItemBoolPtr("Media", nil, &show_media)
	im.MenuItemBoolPtr("Program", nil, &show_preview)
	im.MenuItemBoolPtr("Inspector", nil, &show_inspector)
	im.MenuItemBoolPtr("Levels", nil, &show_levels)
	im.MenuItemBoolPtr("Sequence", nil, &show_project)
	im.MenuItemBoolPtr("Timeline", nil, &show_timeline)
	im.MenuItemBoolPtr("Randomize", nil, &show_randomize)
	im.MenuItemBoolPtr("Patterns", nil, &show_patterns)
	im.MenuItemBoolPtr("Lyrics", nil, &show_lyrics)
	im.Separator()
	if im.MenuItem("Reset layout") {
		show_media, show_preview, show_timeline, show_inspector, show_project, show_levels = true, true, true, true, true, true
		reset_layout = true
	}
	im.EndMenu()
}

// ---------------------------------------------------------------- command palette (F1)

palette_open: bool
palette_query: [64]u8
palette_sel: int
palette_focus: bool

// One row of the palette: a command, or "loop pattern N" (pattern >= 0).
Palette_Item :: struct {
	action:  Action,
	pattern: int,
	name:    string,
}

open_palette :: proc() {
	palette_open = true
	palette_query = {}
	palette_sel = 0
	palette_focus = true
}

panel_palette :: proc() {
	if !palette_open {
		return
	}
	vp := im.GetMainViewport()
	im.SetNextWindowPos({vp.Pos.x + vp.Size.x / 2, vp.Pos.y + vp.Size.y * 0.18}, .Always, {0.5, 0})
	im.SetNextWindowSize({560, 0})
	flags := im.WindowFlags{.NoTitleBar, .NoResize, .NoMove, .NoSavedSettings, .NoDocking}
	if im.Begin("##palette", nil, flags) {
		if palette_focus {
			im.SetKeyboardFocusHere()
		}
		im.SetNextItemWidth(-1)
		typed := im.InputText("##query", cstring(&palette_query[0]), len(palette_query))
		query := strings.to_lower(string(cstring(&palette_query[0])), context.temp_allocator)

		// every command, plus one "loop pattern X" per cutting pattern
		matches := make([dynamic]Palette_Item, context.temp_allocator)
		for a in Action {
			info := ACTION_INFO[a]
			if info.hidden {continue}
			hay := strings.to_lower(strings.concatenate({info.name, " ", info.section}, context.temp_allocator), context.temp_allocator)
			if strings.contains(hay, query) {
				append(&matches, Palette_Item{a, -1, info.name})
			}
		}
		for &pat, i in project.patterns {
			name := fmt.tprintf("Loop pattern: %s", get_fixed(pat.name[:]))
			if strings.contains(strings.to_lower(name, context.temp_allocator), query) {
				append(&matches, Palette_Item{.Apply_Pattern, i, name})
			}
		}
		if typed {palette_sel = 0}
		moved := false
		if im.IsKeyPressed(.DownArrow) {palette_sel += 1; moved = true}
		if im.IsKeyPressed(.UpArrow) {palette_sel -= 1; moved = true}
		palette_sel = clamp(palette_sel, 0, max(len(matches) - 1, 0))
		enter := im.IsKeyPressed(.Enter) || im.IsKeyPressed(.KeypadEnter)

		run: Maybe(Palette_Item)
		im.BeginChild("##results", {0, 320})
		for item, k in matches {
			a, info := item.action, ACTION_INFO[item.action]
			label := cstr(fmt.tprintf("%s###cmd%d_%d", item.name, int(a), item.pattern))
			if im.Selectable(label, k == palette_sel) || (enter && k == palette_sel) {
				run = item
			}
			if k == palette_sel && moved {
				im.SetScrollHereY()
			}
			im.SameLine(400)
			im.TextDisabled(cstr(item.pattern < 0 ? bindings[a][0].text : ""))
			im.SameLine(480)
			im.TextDisabled(cstr(info.section))
		}
		if len(matches) == 0 {
			im.TextDisabled("no command matches")
		}
		im.EndChild()

		if im.IsKeyPressed(.Escape) || (!palette_focus && !im.IsWindowFocused({.RootWindow, .ChildWindows})) {
			palette_open = false
		}
		palette_focus = false
		if item, ok := run.?; ok {
			palette_open = false
			if item.pattern >= 0 {
				apply_pattern(item.pattern)
			} else {
				do_action(item.action)
			}
		}
	}
	im.End()
}

// ---------------------------------------------------------------- randomize options

panel_randomize :: proc() {
	if !show_randomize {
		return
	}
	defer im.End()
	if !im.Begin("Randomize", &show_randomize, {.AlwaysAutoResize}) {
		return
	}
	o := &project.settings.rand

	// 1. where the slots are
	slice_i := i32(o.slice)
	im.SetNextItemWidth(230)
	if im.Combo("slice at", &slice_i, "the program's cuts\x00the pattern\x00the beat grid\x00\x00") {
		o.slice = Rand_Slice(slice_i)
	}
	switch o.slice {
	case .Grid: im.TextDisabled("every slice-every lines of the grid")
	case .Cuts: im.TextDisabled(cstr(len(project.program) > 0 ? fmt.tprintf("the %d cuts it has", len(project.program)) : "no cuts yet: the grid is used"))
	case .Pattern:
		if len(project.parts) > 0 {
			dim_f("the pattern of each of the %d parts", len(project.parts))
		} else {
			label := "current pattern"
			if i := int(o.pattern); i >= 0 && i < len(project.patterns) {
				label = get_fixed(project.patterns[i].name[:])
			}
			im.SetNextItemWidth(230)
			if im.BeginCombo("pattern", cstr(label)) {
				if im.Selectable("current pattern", o.pattern < 0) {o.pattern = -1}
				for &q, i in project.patterns {
					if im.Selectable(cstr(fmt.tprintf("%s###rp%d", get_fixed(q.name[:]), i)), int(o.pattern) == i) {o.pattern = i32(i)}
				}
				im.EndCombo()
			}
		}
	}

	// 2. what goes into them
	footage := i32(o.footage)
	im.SetNextItemWidth(230)
	if im.Combo("footage", &footage, "same time\x00in order\x00any piece\x00\x00") {
		o.footage = Rand_Footage(footage)
	}
	switch o.footage {
	case .Same_Time: im.TextDisabled("what plays at that time: cuts between the clips")
	case .In_Order:  im.TextDisabled("each clip plays forward, a piece at a time")
	case .Any_Piece: im.TextDisabled("a random piece of the clip")
	}
	if o.footage != .Same_Time {
		im.Checkbox("use all clips", &o.use_all)
		im.SameLine()
		im.TextDisabled("the rhythm loops until every piece is used")
		im.Checkbox("spread clips evenly", &o.spread)
		im.SameLine()
		im.TextDisabled("every clip over the whole video, not the short ones used up first")
	}
	im.SetNextItemWidth(90)
	im.InputInt("max in a row (0 = any)", &o.max_run)
	o.max_run = max(o.max_run, 0)

	im.Separator()
	names := make([dynamic]string, context.temp_allocator)
	for t in selected_tracks(project) {
		if ord := layer_ordinal(tracks_video, t); ord >= 0 {
			append(&names, fmt.tprintf("V%d", ord + 1))
		}
	}
	_, _, ranged := program_range()
	im.TextDisabled(cstr(fmt.tprintf("%d video clips%s%s", len(rearrange_candidates(project)),
		len(names) > 0 ? fmt.tprintf(" on %s", strings.join(names[:], ", ", context.temp_allocator)) : "", ranged ? ", in the selected range" : "")))
	if im.Button("Randomize") {
		do_action(.Randomize)
	}
	im.SameLine()
	if im.Button("Undo") {
		do_action(.Undo)
	}
}

// ---------------------------------------------------------------- layer selection

// Plain click selects one layer, ctrl toggles it, shift selects the range from the
// last clicked one. Selecting layers deselects clips and vice versa.
select_track :: proc(track: int, ctrl, shift: bool) {
	sync_tracks(&project)
	if track < 0 || track >= len(project.track_flags) {
		return
	}
	clear_selection(&project)
	switch {
	case shift && sel_anchor >= 0:
		if !ctrl {clear_track_selection(&project)}
		for t in min(sel_anchor, track) ..= max(sel_anchor, track) {
			project.track_flags[t] += {.Selected}
		}
	case ctrl:
		project.track_flags[track] ~= {.Selected}
		sel_anchor = track
	case:
		clear_track_selection(&project)
		project.track_flags[track] += {.Selected}
		sel_anchor = track
	}
	clear_cut_sel()
}

// ---------------------------------------------------------------- context menu

Context :: enum {
	None,
	Clip,
	Lane,
	Header,
	Segment,
	Part,
	Lyric,
}

ctx_kind: Context
ctx_time: f64 // timeline time that was right-clicked

open_context :: proc(kind: Context, time: f64, track: int) {
	ctx_kind, ctx_time = kind, time
	im.OpenPopup("##ctx")
}

// Must be called from the window that called open_context (the timeline canvas).
context_menu :: proc() {
	if !im.BeginPopup("##ctx") {
		return
	}
	defer im.EndPopup()
	switch ctx_kind {
	case .None:
	case .Clip:
		menu_action(.Duplicate)
		menu_action(.Delete)
		menu_action(.Lock)
		menu_action(.Smooth_Slowmo)
		menu_action(.Enhance_Clips)
		menu_action(.Slowmo_Enhance)
		if im.MenuItem("Split here") {
			split_at(&project, snap(ctx_time)) // the selected clips (and what they are linked to)
		}
		im.Separator()
		menu_action(.Link)
		menu_action(.Unlink)
	case .Lane, .Header:
		menu_action(.Add_Layer)
		if im.MenuItem("Duplicate layers") {duplicate_selected_tracks(&project)}
		menu_action(.Remove_Layer)
		im.Separator()
		menu_action(.Lock)
		menu_action(.Smooth_Slowmo)
		menu_action(.Enhance_Clips)
		menu_action(.Slowmo_Enhance)
		if im.MenuItem("Hide video") {toggle_flag_on_selected(&project, .Hidden)}
		if im.MenuItem("Mute audio") {toggle_flag_on_selected(&project, .Muted)}
		if im.MenuItem("Solo audio") {toggle_flag_on_selected(&project, .Solo)}
		im.Separator()
		menu_action(.Randomize)
		menu_action(.Randomize_Options)
	case .Lyric:
		if sel_lyric >= 0 && sel_lyric < len(project.lyrics) {
			if im.MenuItem("Edit text...") {show_lyrics = true}
			if im.MenuItem("Split at playhead") {lyric_split(&project, sel_lyric, playhead)}
			if lyrics_selected() > 1 {
				dim_f("%d lines selected: drag one to move them all", lyrics_selected())
			}
			if im.MenuItem("Merge with next") {lyric_merge(&project, sel_lyric)}
			if im.MenuItem(lyrics_selected() > 1 ? "Delete selected lines" : "Delete") {do_action(.Delete)}
			im.Separator()
		}
		if im.MenuItem("Add line here") {lyric_add(&project, snap(ctx_time))}
		menu_action(.Lyrics_Open)
		menu_action(.Lyrics_Export)
	case .Part:
		if sel_part >= 0 && sel_part < len(project.parts) {
			for &q, i in project.patterns {
				if im.MenuItem(cstr(fmt.tprintf("Pattern: %s###pp%d", get_fixed(q.name[:]), i)), nil, project.parts[sel_part].pattern == i32(i)) {
					project.parts[sel_part].pattern = i32(i)
				}
			}
			if im.MenuItem("No pattern") {project.parts[sel_part].pattern = -1}
			im.Separator()
			if im.MenuItem("Duplicate") {duplicate_part(sel_part)}
			if im.MenuItem("Split here") {_ = split_part(sel_part, snap(ctx_time))}
			if im.MenuItem("Remove part") {
				ordered_remove(&project.parts, sel_part)
				sel_part = -1
			}
		}
	case .Segment: // acts on the selected range
		for l, n in tracks_video {
			if n >= 9 {break}
			if im.MenuItem(cstr(fmt.tprintf("Show V%d", n + 1))) && sel_cut >= 0 {
				for k in sel_cut ..= min(sel_cut2, len(project.program) - 1) {
					project.program[k].layer, project.program[k].fixed = l, true
				}
			}
		}
		if im.MenuItem("Show all layers") && sel_cut >= 0 {
			for k in sel_cut ..= min(sel_cut2, len(project.program) - 1) {
				project.program[k].layer, project.program[k].fixed = -1, true
			}
		}
		im.Separator()
		menu_action(.Copy_Cuts)
		menu_action(.Paste_Cuts)
		menu_action(.Repeat_Range)
		menu_action(.Loop_Playback)
		im.Separator()
		menu_action(.Apply_Pattern)
		menu_action(.Beat_Split)
		menu_action(.Randomize)
		menu_action(.Delete)
	}
}
