package main

import "core:fmt"
import "core:math"
import "core:path/filepath"
import "core:slice"
import "core:strings"

import im "deps/odin-imgui"

track_h: f32 = 40 // lane height; alt+wheel changes it
RULER_H :: 20
PART_H :: 24 // the parts row under the ruler
PROG_Y :: RULER_H + PART_H
PROG_H :: 26 // the program lane under the parts row
LYR_Y :: PROG_Y + PROG_H // the lyrics row under the program lane
LYR_H :: 16
LANES_Y :: LYR_Y + LYR_H
EDGE_PX :: 6 // grab zone for trimming
HEADER_W :: 124 // track header column, stays at the left while scrolling

Tool :: enum {
	Select,
	Razor,
	Hand,
	Zoom,
}

tool: Tool

Drag :: enum {
	None,
	Scrub,
	Move,
	Trim_Left,
	Trim_Right,
	Cut_Move, // dragging a program cut
	Prog_Range, // dragging over program segments to select a range
	Part_Create, // dragging out a part in the parts row
	Part_Move, // dragging a part, or one of its edges
	Part_Trim_L,
	Part_Trim_R,
	Lyric_Move, // dragging a lyric line, or one of its edges
	Lyric_Trim_L,
	Lyric_Trim_R,
	Lyric_Box, // dragging a box over lyric lines to select them
	Box, // dragging a box over the lanes to select clips
	Pan, // hand tool
}

zoom: f32 = 50 // pixels per second
sel_anchor := -1 // last layer clicked, start of a shift-click range
sel_cut := -1 // first selected program segment (index of its cut), -1 = none
sel_cut2 := -1 // last selected program segment (>= sel_cut)
drag_seg: int // the segment a range selection started at
loop_playback: bool // loop the selected program range while playing

sel_part := -1 // selected part
box_y0: f32 // screen y where a box selection started
box_base: [dynamic]bool // what was selected before a ctrl box (clips or lyric lines)
prev_scroll_y: f32 // the timeline's vertical scroll before the wheel acted on a slice
part_drag_t: f64 // the free end of a part being dragged out
part_len: f64 // length of the part being moved
part_anchor_off: f64 // where its pattern starts, counted from its start

select_cuts :: proc(a, b: int) {
	sel_cut, sel_cut2 = min(a, b), max(a, b)
	sel_part = -1
}

// Clears every selection kind that is not a clip or a layer: program range, part, lyric line.
clear_cut_sel :: proc() {
	sel_cut, sel_cut2 = -1, -1
	sel_part = -1
	lyrics_deselect()
}

// Nothing selected anywhere: clips, layers, program range, part, lyric line.
select_none :: proc() {
	clear_selection(&project)
	clear_track_selection(&project)
	clear_cut_sel()
}

// The color of a pattern in the parts row and in the brush strip (grey = none).
pattern_color :: proc(pattern: i32) -> u32 {
	r, g, b: f32
	im.ColorConvertHSVtoRGB(pattern >= 0 ? math.mod(f32(pattern) * 0.27 + 0.1, 1) : 0, pattern >= 0 ? 0.5 : 0, 0.55, &r, &g, &b)
	return im.ColorConvertFloat4ToU32({r, g, b, 1})
}

// One chip for each pattern: the current one is the brush for the parts row.
brush_strip :: proc() {
	im.TextDisabled("brush")
	for i in 0 ..< len(project.patterns) {
		im.SameLine()
		im.PushStyleColor(.Button, pattern_color(i32(i)))
		im.PushStyleColor(.ButtonHovered, pattern_color(i32(i)) | 0x00303030)
		picked := i == int(project.settings.pattern_sel)
		if picked {im.PushStyleColor(.Border, 0xFFFFFFFF)}
		im.PushStyleVar(.FrameBorderSize, picked ? 2 : 0)
		if im.Button(cstr(fmt.tprintf("%s###brush%d", get_fixed(project.patterns[i].name[:]), i))) {
			project.settings.pattern_sel = i32(i)
		}
		im.PopStyleVar()
		if picked {im.PopStyleColor()}
		im.PopStyleColor(2)
		tip("Brush: drag in the parts row to paint a part. Painting over other parts overwrites them and splits them (the rest stays). To move a part drag its top strip (where the name is). Drag an edge to cut or extend it (the pattern stays in place). The pattern of a part changes with right-click.")
	}
}

// The part that contains time t, or -1.
part_at :: proc(t: f64) -> int {
	for part, i in project.parts {
		if t >= part.t0 && t < part.t1 {return i}
	}
	return -1
}

// A copy of part i right after it (painted over what is there), selected. Repeat it to repeat the pattern.
duplicate_part :: proc(i: int) {
	if i < 0 || i >= len(project.parts) {return}
	pt := project.parts[i]
	make_part(pt.t1, pt.t1 + (pt.t1 - pt.t0), pt.pattern, pt.t1 + (part_anchor(pt) - pt.t0)) // same phase as the original
	sel_part = part_at(pt.t1 + 1e-3)
}

// Cuts part i in two at time t.
split_part :: proc(i: int, t: f64) -> bool {
	if i < 0 || i >= len(project.parts) {return false}
	pt := project.parts[i]
	if t <= pt.t0 + MIN_DURATION || t >= pt.t1 - MIN_DURATION {return false}
	project.parts[i].t1 = t
	inject_at(&project.parts, i + 1, Part{t0 = t, t1 = pt.t1, pattern = pt.pattern, anchor = part_anchor(pt)})
	return true
}

// The room around part i: it may grow or move between the end of the part before and the start of the next.
part_room :: proc(i: int) -> (lo, hi: f64) {
	lo, hi = 0, max(f64)
	if i > 0 {lo = project.parts[i - 1].t1}
	if i + 1 < len(project.parts) {hi = project.parts[i + 1].t0}
	return
}

// Adds a part over a..b with the current pattern, painted over what is there: parts it overlaps
// are cut back (or split in two), not thrown away.
make_part :: proc(a, b: f64, with: i32 = -2, anchor := f64(-1)) {
	if b - a < 1e-3 {return}
	#reverse for part, i in project.parts {
		if part.t0 >= b || part.t1 <= a {continue}
		if part.t0 < a && part.t1 > b { // painted in the middle: two pieces are left
			project.parts[i].t1 = a
			append(&project.parts, Part{t0 = b, t1 = part.t1, pattern = part.pattern, anchor = part_anchor(part)})
		} else if part.t0 < a {
			project.parts[i].t1 = a
		} else if part.t1 > b {
			project.parts[i].anchor = part_anchor(part) // the start is cut: what is left stays where it was
			project.parts[i].t0 = b
		} else {
			ordered_remove(&project.parts, i)
		}
	}
	pattern := with >= -1 ? with : (len(project.patterns) > 0 ? project.settings.pattern_sel : -1)
	append(&project.parts, Part{t0 = a, t1 = b, pattern = pattern, anchor = anchor >= 0 ? anchor : a})
	slice.sort_by(project.parts[:], proc(x, y: Part) -> bool {return x.t0 < y.t0})
	sel_part = part_at((a + b) / 2)
}

// Double click on a part: its pattern, start, end and length in numbers (for small timing changes).
part_edit_popup :: proc() {
	if !im.BeginPopup("##partedit") {return}
	defer im.EndPopup()
	if sel_part < 0 || sel_part >= len(project.parts) {
		im.CloseCurrentPopup()
		return
	}
	lo, hi := part_room(sel_part)
	pt := &project.parts[sel_part]
	im.TextDisabled("part")
	beat := 60 / f64(max(project.settings.bpm, 1))
	start, end, length := pt.t0, pt.t1, pt.t1 - pt.t0
	im.SetNextItemWidth(160)
	if im.InputDouble("start (s)", &start, 0.05, 0.5, "%.3f") {pt.t0 = clamp(start, lo, pt.t1 - MIN_DURATION)}
	im.SetNextItemWidth(160)
	if im.InputDouble("end (s)", &end, 0.05, 0.5, "%.3f") {pt.t1 = clamp(end, pt.t0 + MIN_DURATION, hi)}
	im.SetNextItemWidth(160)
	if im.InputDouble("length (s)", &length, 0.05, 0.5, "%.3f") {pt.t1 = clamp(pt.t0 + length, pt.t0 + MIN_DURATION, hi)}
	dim_f("%.2f beats", (pt.t1 - pt.t0) / beat)
	if im.Button("Duplicate") {duplicate_part(sel_part)}
	im.SameLine()
	if im.Button("Remove") {
		ordered_remove(&project.parts, sel_part)
		sel_part = -1
		im.CloseCurrentPopup()
	}
}

// The selected program range: from the first selected segment's start to the last one's end.
program_range :: proc() -> (t0, t1: f64, ok: bool) {
	if sel_cut < 0 || sel_cut >= len(project.program) {
		return
	}
	last := clamp(sel_cut2, sel_cut, len(project.program) - 1)
	return project.program[sel_cut].time, segment_end(project, last, project_length(project)), true
}
drag_cut: int
drag: Drag
drag_row: int // track under the mouse when a Move started / last applied
drag_clip: int // clip that was grabbed
drag_ref: f64 // timeline time of the grabbed clip's start (Move) or edge (Trim) at press
drag_press_t: f64 // mouse time at press

snapping :: proc() -> bool {
	return project.settings.grid_on && !held(.No_Snap)
}

snap :: proc(t: f64) -> f64 {
	return snapping() ? snap_time(project.settings, t) : t
}

GRID_DIVS := [5]i32{1, 2, 4, 8, 16}

time_to_x :: proc(origin: f32, t: f64) -> f32 {
	return origin + f32(t) * zoom
}

x_to_time :: proc(origin, x: f32) -> f64 {
	return f64((x - origin) / zoom)
}

// Higher tracks are drawn higher up.
track_to_y :: proc(top: f32, track: int) -> f32 {
	return top + LANES_Y + f32(project.track_count - 1 - track) * track_h
}

y_to_track :: proc(top, y: f32) -> int {
	row := int(max(0, y - top - LANES_Y) / track_h)
	return clamp(project.track_count - 1 - row, 0, max(project.track_count - 1, 0))
}

clip_color :: proc(c: Clip) -> u32 {
	col: u32 = c.kind == .Video ? 0xFFB5702E : 0xFF4E9A3F
	col = c.selected ? col + 0x00404040 : col
	// clips that don't contribute (hidden video, muted audio) are drawn faded
	off := c.kind == .Video ? track_has(project, c.track, .Hidden) : !track_audible(project, c.track)
	return off ? (col & 0x00FFFFFF) | 0x50000000 : col
}

// Topmost clip under (t, track), or -1. Clips on locked tracks can't be picked.
clip_at :: proc(t: f64, track: int) -> int {
	if track_has(project, track, .Locked) {
		return -1
	}
	hit := -1
	for c, i in project.clips {
		if c.track == track && t >= c.start && t < clip_end(c) {
			hit = i
		}
	}
	return hit
}

// What part of clip i is at pixel x.
zone_at :: proc(origin, x: f32, i: int) -> Drag {
	c := project.clips[i]
	a, b := time_to_x(origin, c.start), time_to_x(origin, clip_end(c))
	if b - a > 3 * EDGE_PX {
		if x < a + EDGE_PX {return .Trim_Left}
		if x > b - EDGE_PX {return .Trim_Right}
	}
	return .Move
}

lane_label :: proc(vl: []int, track: int) -> string {
	if ord := layer_ordinal(vl, track); ord >= 0 {
		return fmt.tprintf("V%d", ord + 1)
	}
	return fmt.tprintf("L%d", track + 1)
}

// Which kinds of clips live on a track.
lane_kinds :: proc(track: int) -> (has_video, has_audio: bool) {
	i := track_info(track)
	return i.has_video, i.has_audio
}

// Index of the program cut within grab distance of pixel x, or -1.
cut_near :: proc(origin, x: f32) -> int {
	best, best_d := -1, f32(EDGE_PX + 1)
	for cut, i in project.program {
		if d := abs(time_to_x(origin, cut.time) - x); d < best_d {
			best, best_d = i, d
		}
	}
	return best
}

// Zoom by `factor`, keeping the time under the mouse where it is.
zoom_at :: proc(origin, scroll_x, mouse_x: f32, factor: f32) {
	t := x_to_time(origin, mouse_x)
	zoom = clamp(zoom * factor, 5, 400)
	im.SetScrollX(max(origin + scroll_x - mouse_x + f32(t) * zoom, 0))
}

// ---------------------------------------------------------------- panel

panel_timeline :: proc() {
	defer im.End()
	if !im.Begin("Timeline", &show_timeline) {
		return
	}

	// header: timecode, snap, zoom, layers
	im.TextUnformatted(cstr(timecode(playhead, project.settings.fps)))
	im.SameLine()
	if icon_button("##snap", .Magnet, 24, project.settings.grid_on, cstr(fmt.tprintf("Grid + snapping (%s)", bindings[.Toggle_Grid][0].text))) {
		do_action(.Toggle_Grid)
	}
	im.SameLine()
	im.SetNextItemWidth(110)
	im.SliderFloat("##zoom", &zoom, 5, 400, "zoom %.0f")
	im.SameLine()
	im.TextDisabled("layers")
	im.SameLine()
	if icon_button("##addlayer", .Plus, 24, false, "Add layer") {do_action(.Add_Layer)}
	im.SameLine()
	if icon_button("##remlayer", .Minus, 24, false, "Remove the selected layer (click its header)") {do_action(.Remove_Layer)}
	im.SameLine()
	im.TextDisabled(loop_playback ? "F1: commands  [looping]" : "F1: commands")
	if len(project.patterns) > 0 {
		im.SameLine()
		brush_strip()
	}

	// tools on the left, timeline canvas fills the rest
	im.BeginChild("tools", {44, 0}, {}, {.NoScrollbar})
	tools_column()
	im.EndChild()
	im.SameLine()
	timeline()
}

tools_column :: proc() {
	Entry :: struct {
		tool: Tool,
		icon: Icon,
		name: string,
		act:  Action,
	}
	entries := [?]Entry {
		{.Select, .Select, "Selection", .Tool_Select},
		{.Razor, .Razor, "Razor: click a clip to cut it (shift: all tracks)", .Tool_Razor},
		{.Hand, .Hand, "Hand: drag to pan", .Tool_Hand},
		{.Zoom, .Zoom, "Zoom: click in, alt+click out", .Tool_Zoom},
	}
	for e, i in entries {
		tip := cstr(fmt.tprintf("%s (%s)", e.name, bindings[e.act][0].text))
		if icon_button(cstr(fmt.tprintf("##tool%d", i)), e.icon, 34, tool == e.tool, tip) {
			tool = e.tool
		}
	}
}

// ---------------------------------------------------------------- canvas

timeline :: proc() {
	length := max(project_length(project) + 10, 30)
	size := im.Vec2{f32(length) * zoom, LANES_Y + track_h * f32(max(project.track_count, 4))}

	im.BeginChild("timeline", {0, 0}, {.Borders}, {.HorizontalScrollbar, .NoNavInputs, .NoNavFocus}) // no keyboard nav: it would scroll the big canvas item into view
	defer im.EndChild()

	dl := im.GetWindowDrawList()
	io := im.GetIO()
	vl := tracks_video
	win_pos, win_size := im.GetWindowPos(), im.GetWindowSize()
	im.SetCursorPosX(im.GetCursorPosX() + HEADER_W) // room for the sticky track headers
	p0 := im.GetCursorScreenPos()
	im.InvisibleButton("area", size)
	sx := im.GetScrollX()
	sy := im.GetScrollY() // the ruler is drawn at the top of the window, not of the lanes

	// drop media from the Media panel
	mouse := im.GetMousePos()
	t_mouse := x_to_time(p0.x, mouse.x)
	if im.BeginDragDropTarget() {
		if pl := im.AcceptDragDropPayload("SOURCE"); pl != nil {
			src := (^int)(pl.Data)^
			lane := mouse.y > p0.y + LANES_Y ? y_to_track(p0.y, mouse.y) : -1
			place_source(&project, src, snap(max(0, t_mouse)), lane)
		}
		im.EndDragDropTarget()
	}

	in_header := mouse.x < p0.x + sx // over the sticky header column, not the canvas
	canvas_hovered := im.IsItemHovered() && !in_header
	hover := -1
	if canvas_hovered && mouse.y > p0.y + LANES_Y {
		hover = clip_at(t_mouse, y_to_track(p0.y, mouse.y))
		switch tool {
		case .Select:
			if hover >= 0 && zone_at(p0.x, mouse.x, hover) != .Move {
				im.SetMouseCursor(.ResizeEW)
			}
		case .Razor: im.SetMouseCursor(.ResizeEW)
		case .Hand:  im.SetMouseCursor(.Hand)
		case .Zoom:  im.SetMouseCursor(.ResizeAll)
		}
	}
	if canvas_hovered && mouse.y > p0.y + PROG_Y && mouse.y < p0.y + LYR_Y && cut_near(p0.x, mouse.x) >= 0 {
		im.SetMouseCursor(.ResizeEW)
	}

	// ctrl+wheel zooms, middle mouse pans (any tool)
	if im.IsWindowHovered() {
		if io.KeyCtrl && io.MouseWheel != 0 {
			zoom_at(p0.x, sx, mouse.x, io.MouseWheel > 0 ? 1.25 : 0.8)
		}
		// the wheel on a slice rerolls its footage (the selected slices if the pointer is over one of them)
		if io.KeyAlt && !io.KeyCtrl && io.MouseWheel != 0 {
				track_h = clamp(track_h * (io.MouseWheel > 0 ? 1.15 : 1 / 1.15), 18, 160) // alt+wheel: taller / shorter lanes
				im.SetScrollY(prev_scroll_y)
			} else if hover >= 0 && !io.KeyCtrl && io.MouseWheel != 0 && project.clips[hover].slice {
			dir := 0 // reroll: a different piece each notch
			// every selected slice changes together when the wheel is over a selected one
			n := 0
			if project.clips[hover].selected {
				for i in 0 ..< len(project.clips) {
					if project.clips[i].selected && slice_nudge(&project, i, dir, project.settings.rand.footage) {n += 1}
				}
			} else if slice_nudge(&project, hover, dir, project.settings.rand.footage) {
				n = 1
			}
			if n > 0 {
				set_status("%d slice%s rerolled", n, n == 1 ? "" : "s")
			} else {
				set_status("no other footage for this slice")
			}
			im.SetScrollY(prev_scroll_y) // the wheel is not a scroll here
		} else {
			prev_scroll_y = im.GetScrollY()
		}
		if im.IsMouseDragging(.Middle) {
			im.SetScrollX(sx - io.MouseDelta.x)
			im.SetScrollY(im.GetScrollY() - io.MouseDelta.y)
		}
	}

	// Right-click: context menu for what is under the mouse
	if im.IsItemClicked(.Right) && !in_header {
		switch {
		case mouse.y < p0.y + sy + RULER_H:
		case mouse.y < p0.y + PROG_Y: // parts row
			if hit := part_at(t_mouse); hit >= 0 {
				select_none()
				sel_part = hit
				open_context(.Part, t_mouse, -1)
			}
		case mouse.y < p0.y + LYR_Y:
			if seg := segment_at(project, t_mouse); seg >= 0 {
				clear_selection(&project)
				clear_track_selection(&project)
				if sel_cut < 0 || seg < sel_cut || seg > sel_cut2 { // right-click inside the range keeps it
					select_cuts(seg, seg)
				}
				open_context(.Segment, t_mouse, -1)
			}
		case mouse.y < p0.y + LANES_Y: // lyrics row
			clear_selection(&project)
			clear_track_selection(&project)
			if h := lyric_hit(project, t_mouse); h >= 0 {
				if !project.lyrics[h].selected {lyrics_deselect(); lyric_select(h, false, false)}
				sel_lyric = h
			}
			open_context(.Lyric, t_mouse, -1)
		case hover >= 0:
			if !project.clips[hover].selected {
				clear_selection(&project)
				set_selected(&project, hover, true)
			}
			clear_track_selection(&project)
			clear_cut_sel()
			open_context(.Clip, t_mouse, project.clips[hover].track)
		case mouse.y < p0.y + LANES_Y + f32(project.track_count) * track_h:
			track := y_to_track(p0.y, mouse.y)
			if !track_has(project, track, .Selected) {
				select_track(track, false, false)
			}
			open_context(.Lane, t_mouse, track)
		}
	}

	// the pointer shows what a part's edge or body does
	if canvas_hovered && !in_header && (drag == .None || drag == .Part_Trim_L || drag == .Part_Trim_R) && mouse.y >= p0.y + sy + RULER_H && mouse.y >= p0.y + RULER_H && mouse.y < p0.y + PROG_Y {
		if hit := part_at(t_mouse); hit >= 0 {
			pt := project.parts[hit]
			near := mouse.x < time_to_x(p0.x, pt.t0) + EDGE_PX || mouse.x > time_to_x(p0.x, pt.t1) - EDGE_PX
			im.SetMouseCursor(near ? .ResizeEW : .ResizeAll)
		}
	}

	// Press
	if im.IsItemClicked() && !in_header {
		track := y_to_track(p0.y, mouse.y)
		switch {
		case mouse.y < p0.y + sy + RULER_H:
			drag = .Scrub
		case mouse.y < p0.y + PROG_Y:
			// parts row: click a part to select it, drag on empty space to make one
			select_none()
			if hit := part_at(t_mouse); hit >= 0 {
				sel_part = hit
				project.parts[hit].anchor = part_anchor(project.parts[hit]) // from here the place of the pattern is fixed
				pt := project.parts[hit]
				drag_cut, drag_press_t, drag_ref, part_len = hit, t_mouse, pt.t0, pt.t1 - pt.t0
				part_anchor_off = pt.anchor - pt.t0
				if im.IsMouseDoubleClicked(.Left) {
					drag = .None
					im.OpenPopup("##partedit") // double click: edit the part
				} else if mouse.x < time_to_x(p0.x, pt.t0) + EDGE_PX {
					drag = .Part_Trim_L
				} else if mouse.x > time_to_x(p0.x, pt.t1) - EDGE_PX {
					drag, drag_ref = .Part_Trim_R, pt.t1
				} else if mouse.y < p0.y + RULER_H + 12 {
					drag = .Part_Move // the top strip moves the part
				} else { // the rest paints over it with the brush (a click only selects)
					drag, drag_ref, part_drag_t = .Part_Create, snap(max(0, t_mouse)), snap(max(0, t_mouse))
				}
			} else if im.IsMouseDoubleClicked(.Left) { // double click on free space: fill the gap with the brush
				lo, hi := 0.0, max(project_length(project), t_mouse)
				for part in project.parts {
					if part.t1 <= t_mouse {lo = max(lo, part.t1)} else if part.t0 > t_mouse {hi = min(hi, part.t0)}
				}
				make_part(lo, hi)
				drag = .None
			} else {
				drag, drag_ref, part_drag_t = .Part_Create, snap(max(0, t_mouse)), snap(max(0, t_mouse))
			}
		case mouse.y < p0.y + LYR_Y:
			// program lane: grab a cut to resize its segments, or select a segment
			clear_selection(&project)
			clear_track_selection(&project)
			if tool == .Razor { // split on click: a cut at the clicked time
				i := cut_insert(&project, snap(t_mouse))
				select_cuts(i, i)
				drag = .None
			} else if i := cut_near(p0.x, mouse.x); i >= 0 {
				drag, drag_cut = .Cut_Move, i
				select_cuts(i, i)
				drag_ref, drag_press_t = project.program[i].time, t_mouse
			} else if seg := segment_at(project, t_mouse); seg >= 0 {
				// click selects a segment, shift-click extends the range, dragging sweeps one
				anchor := io.KeyShift && sel_cut >= 0 ? sel_cut : seg
				select_cuts(anchor, seg)
				drag, drag_seg = .Prog_Range, anchor
			} else {
				clear_cut_sel()
				drag = .None
			}
		case mouse.y < p0.y + LANES_Y:
			// lyrics row: click selects a line, drag moves it, drag an edge trims it
			clear_selection(&project)
			clear_track_selection(&project)
			sel_cut, sel_cut2, sel_part = -1, -1, -1
			if i := lyric_hit(project, t_mouse); i >= 0 {
				lyric_select(i, io.KeyCtrl, io.KeyShift)
				lyr_tap = i + 1
				l := project.lyrics[i]
				drag, drag_cut, drag_press_t, drag_ref = .Lyric_Move, i, t_mouse, l.t0
				if io.KeyCtrl || io.KeyShift {
					drag = .None // a click that changes the selection does not move anything
				} else if mouse.x < time_to_x(p0.x, l.t0) + EDGE_PX {
					drag = .Lyric_Trim_L
				} else if mouse.x > time_to_x(p0.x, l.t1) - EDGE_PX {
					drag, drag_ref = .Lyric_Trim_R, l.t1
				}
			} else { // empty space: drag a box to select lines
				clear(&box_base)
				for l in project.lyrics {append(&box_base, io.KeyCtrl && l.selected)}
				if !io.KeyCtrl {lyrics_deselect()}
				drag, drag_ref, part_drag_t = .Lyric_Box, t_mouse, t_mouse
			}
		case tool == .Hand:
			drag = .Pan
		case tool == .Zoom:
			zoom_at(p0.x, sx, mouse.x, io.KeyAlt ? 0.67 : 1.5)
		case tool == .Razor:
			if hover >= 0 {
				t := snap(t_mouse)
				if io.KeyShift { // all tracks
					clear_selection(&project)
				} else { // the clicked clip and whatever it is linked to
					clear_selection(&project)
					set_selected(&project, hover, true)
				}
				split_at(&project, t)
				clear_selection(&project)
			}
		case hover >= 0:
			drag = project.clips[hover].locked ? .None : zone_at(p0.x, mouse.x, hover) // a locked clip can be selected, not changed
			if io.KeyCtrl {
				set_selected(&project, hover, !project.clips[hover].selected)
			} else if !project.clips[hover].selected || drag != .Move {
				clear_selection(&project)
				set_selected(&project, hover, true) // edge drags act on the clip's whole group
			}
			drag_row = track
			drag_clip = hover
			drag_press_t = t_mouse
			c := project.clips[hover]
			drag_ref = drag == .Trim_Right ? clip_end(c) : c.start
			clear_cut_sel()
			if !io.KeyCtrl {clear_track_selection(&project)}
		case:
			// empty lane space: pick the layer (ctrl: toggle, shift: range), move the checkpoint; dragging makes a box
			clear(&box_base)
			for c in project.clips {append(&box_base, io.KeyCtrl && c.selected)}
			if mouse.y < p0.y + LANES_Y + f32(project.track_count) * track_h {
				select_track(track, io.KeyCtrl, io.KeyShift)
			} else {
				clear_selection(&project)
				clear_track_selection(&project)
			}
			checkpoint = snap(max(0, t_mouse))
			clear_cut_sel()
			drag, drag_ref, part_drag_t, box_y0 = .Box, t_mouse, t_mouse, mouse.y
		}
	}

	// Drag
	if drag != .None {
		if !im.IsMouseDown(.Left) {
			if drag == .Part_Create {
				make_part(min(drag_ref, part_drag_t), max(drag_ref, part_drag_t))
			}
			if drag == .Lyric_Move || drag == .Lyric_Trim_L || drag == .Lyric_Trim_R {lyrics_sort(&project)}
			drag = .None
		} else {
			// where the grabbed edge / clip start wants to be (grid-snapped unless alt is held)
			target := snap(drag_ref + (t_mouse - drag_press_t))
			dx: f64
			switch drag {
			case .None:
			case .Pan:
				im.SetScrollX(sx - io.MouseDelta.x)
				im.SetScrollY(im.GetScrollY() - io.MouseDelta.y)
			case .Scrub:
				EDGE :: 30 // holding near an edge keeps scrolling
				if mouse.x < win_pos.x + HEADER_W + EDGE {
					im.SetScrollX(sx - 10)
				} else if mouse.x > win_pos.x + win_size.x - EDGE {
					im.SetScrollX(sx + 10)
				}
				playhead = snap(max(0, t_mouse))
				checkpoint = playhead
				playing = false
			case .Part_Create:
				part_drag_t = snap(max(0, t_mouse))
			case .Part_Move, .Part_Trim_L, .Part_Trim_R:
				if drag_cut < len(project.parts) {
					lo, hi := part_room(drag_cut)
					pt := &project.parts[drag_cut]
					#partial switch drag {
					case .Part_Move:
						pt.t0 = clamp(target, lo, max(hi - part_len, lo))
						pt.t1 = pt.t0 + part_len
						pt.anchor = pt.t0 + part_anchor_off // the pattern moves with it
					case .Part_Trim_L: pt.t0 = clamp(target, lo, pt.t1 - MIN_DURATION)
					case .Part_Trim_R: pt.t1 = clamp(target, pt.t0 + MIN_DURATION, hi)
					}
				}
			case .Lyric_Move: // the whole selection moves with the line you hold
				if drag_cut < len(project.lyrics) {lyrics_shift(target - project.lyrics[drag_cut].t0)}
			case .Lyric_Trim_L, .Lyric_Trim_R:
				if drag_cut < len(project.lyrics) {
					l := &project.lyrics[drag_cut]
					if drag == .Lyric_Trim_L {l.t0 = clamp(target, 0, l.t1 - MIN_DURATION)} else {l.t1 = max(target, l.t0 + MIN_DURATION)}
				}
			case .Lyric_Box:
				part_drag_t = t_mouse
				lo, hi := min(drag_ref, part_drag_t), max(drag_ref, part_drag_t)
				for &l, i in project.lyrics {l.selected = (i < len(box_base) && box_base[i]) || (l.t0 < hi && l.t1 > lo)}
			case .Box: // a box over the lanes selects the clips it touches
				part_drag_t = t_mouse
				lo, hi := min(drag_ref, part_drag_t), max(drag_ref, part_drag_t)
				ta, tb := y_to_track(p0.y, box_y0), y_to_track(p0.y, mouse.y)
				for &c, i in project.clips {
					hit := c.track >= min(ta, tb) && c.track <= max(ta, tb) && c.start < hi && clip_end(c) > lo && !track_has(project, c.track, .Locked)
					c.selected = (i < len(box_base) && box_base[i]) || hit
				}
			case .Prog_Range:
				select_cuts(drag_seg, max(segment_at(project, t_mouse), 0))
			case .Cut_Move:
				if drag_cut < len(project.program) {
					cut_move(&project, drag_cut, target)
				}
			case .Trim_Left, .Trim_Right:
				live := project.clips[drag_clip]
				dx = target - (drag == .Trim_Left ? live.start : clip_end(live))
				for c, i in project.clips {
					if !c.selected {continue}
					switch {
					case drag == .Trim_Left && held(.Stretch):  stretch_left(&project, i, dx)
					case drag == .Trim_Left:                    trim_left(&project, i, dx)
					case held(.Stretch):                        stretch_right(&project, i, dx)
					case:                                       trim_right(&project, i, dx)
					}
				}
			case .Move:
				// horizontal: clamp so nothing goes before 0
				min_start := max(f64)
				lo, hi := max(int), min(int)
				for c in project.clips {
					if c.selected {
						min_start = min(min_start, c.start)
						lo, hi = min(lo, c.track), max(hi, c.track)
					}
				}
				dx = max(target - project.clips[drag_clip].start, -min_start)
				// vertical: follow the mouse by whole tracks, clamped to existing tracks
				dt := y_to_track(p0.y, mouse.y) - drag_row
				dt = clamp(dt, -lo, project.track_count - 1 - hi)
				drag_row += dt
				for &c in project.clips {
					if c.selected {
						c.start += dx
						c.track += dt
					}
				}
			}
		}
	}

	// Lanes
	rows := max(project.track_count, 4)
	for r in 0 ..< rows { // rows from the top; the bottom ones may be empty filler below the last track
		y := p0.y + LANES_Y + f32(r) * track_h
		track := project.track_count - 1 - r
		col: u32 = r % 2 == 0 ? 0xFF202020 : 0xFF262626
		if track_has(project, track, .Selected) {
			col = 0xFF4A3A20
		}
		im.DrawList_AddRectFilled(dl, {p0.x, y}, {p0.x + size.x, y + track_h - 1}, col)
	}

	// Grid
	if s := project.settings; s.grid_on {
		step, major := grid_step(s)
		stride := 1 // draw every n-th line when they would be too dense
		for step * f64(stride) * f64(zoom) < 8 {
			stride *= 2
		}
		bottom := p0.y + size.y
		origin := grid_origin(s)
		for i := -int(math.floor(origin / step)); origin + f64(i) * step < f64(length); i += stride {
			x := time_to_x(p0.x, origin + f64(i) * step)
			is_major := ((i % major) + major) % major == 0
			im.DrawList_AddLine(dl, {x, p0.y + LANES_Y}, {x, bottom}, is_major ? 0x50FFFFFF : 0x22FFFFFF)
		}
	}

	// Program lane: which video layer is shown when
	{
		// parts row: ranges with their own pattern
		py := p0.y + RULER_H
		im.DrawList_AddRectFilled(dl, {p0.x, py}, {p0.x + size.x, py + PART_H - 1}, 0xFF1B1B1B)
		for part, i in project.parts {
			a := im.Vec2{time_to_x(p0.x, part.t0), py + 1}
			b := im.Vec2{time_to_x(p0.x, part.t1), py + PART_H - 2}
			im.DrawList_AddRectFilled(dl, a, b, pattern_color(part.pattern))
			im.DrawList_AddRect(dl, a, b, i == sel_part ? 0xFFFFFFFF : 0xFF000000)
			if part.pattern >= 0 && int(part.pattern) < len(project.patterns) && b.x > win_pos.x && a.x < win_pos.x + win_size.x { // the pattern's hits, one tick each, colored by lane
				im.DrawList_PushClipRect(dl, a, b, true)
				for h in pattern_hits(project, project.patterns[part.pattern], part.t0, part.t1, part_anchor(part)) {
					x := time_to_x(p0.x, h.time)
					if x < win_pos.x - 4 || x > win_pos.x + win_size.x {continue}
					r, g, bl: f32
					im.ColorConvertHSVtoRGB(math.mod(f32(h.lane) * 0.13 + 0.05, 1), 0.5, 1, &r, &g, &bl)
					im.DrawList_AddRectFilled(dl, {x, a.y + 12}, {x + 2, b.y - 1}, im.ColorConvertFloat4ToU32({r, g, bl, 1}))
				}
				im.DrawList_PopClipRect(dl)
			}
			name := part.pattern >= 0 && int(part.pattern) < len(project.patterns) ? get_fixed(project.patterns[part.pattern].name[:]) : "no pattern"
			im.DrawList_PushClipRect(dl, a, b, true)
			im.DrawList_AddText(dl, {a.x + 4, a.y}, 0xFFFFFFFF, cstr(name))
			im.DrawList_PopClipRect(dl)
		}
		if drag == .Part_Create { // the part being dragged out
			x0, x1 := time_to_x(p0.x, min(drag_ref, part_drag_t)), time_to_x(p0.x, max(drag_ref, part_drag_t))
			im.DrawList_AddRect(dl, {x0, py + 1}, {x1, py + PART_H - 2}, 0xFFFFFFFF)
		}

		y0 := p0.y + PROG_Y
		im.DrawList_AddRectFilled(dl, {p0.x, y0}, {p0.x + size.x, y0 + PROG_H - 1}, 0xFF161616)
		end := project_length(project)
		for cut, i in project.program {
			a := im.Vec2{time_to_x(p0.x, cut.time), y0 + 2}
			b := im.Vec2{time_to_x(p0.x, segment_end(project, i, end)), y0 + PROG_H - 3}
			if b.x <= a.x {continue}
			col: u32 = 0xFF303030
			label: cstring
			if ord := layer_ordinal(vl, cut.layer); ord >= 0 {
				r, g, bl: f32
				im.ColorConvertHSVtoRGB(math.mod(f32(ord) * 0.618, 1), 0.55, 0.75, &r, &g, &bl)
				col = im.ColorConvertFloat4ToU32({r, g, bl, 1})
				label = cstr(fmt.tprintf("V%d", ord + 1))
			}
			im.DrawList_AddRectFilled(dl, a, b, col)
			in_range := sel_cut >= 0 && i >= sel_cut && i <= sel_cut2
			if in_range {im.DrawList_AddRectFilled(dl, a, b, 0x40FFFFFF)}
			im.DrawList_AddRect(dl, a, b, in_range ? 0xFFFFFFFF : 0xFF000000)
			if label != nil {
				im.DrawList_PushClipRect(dl, a, b, true)
				im.DrawList_AddText(dl, {a.x + 4, a.y + 3}, 0xFFFFFFFF, label)
				im.DrawList_PopClipRect(dl)
			}
		}
	}

	// Lyrics row: subtitle lines. Drag to move, drag an edge to trim.
	{
		y0 := p0.y + LYR_Y
		im.DrawList_AddRectFilled(dl, {p0.x, y0}, {p0.x + size.x, y0 + LYR_H - 1}, 0xFF1B1B1B)
		for i in 0 ..< len(project.lyrics) {
			l := project.lyrics[i]
			a := im.Vec2{time_to_x(p0.x, l.t0), y0 + 1}
			b := im.Vec2{time_to_x(p0.x, l.t1), y0 + LYR_H - 2}
			if b.x < win_pos.x || a.x > win_pos.x + win_size.x {continue}
			im.DrawList_AddRectFilled(dl, a, b, 0xFF7A5A2A)
			im.DrawList_AddRect(dl, a, b, l.selected || i == sel_lyric ? 0xFFFFFFFF : 0xFF000000, 0, l.selected ? 2 : 1)
			text, _ := strings.replace_all(text_of(l), "\n", " / ", context.temp_allocator)
			im.DrawList_PushClipRect(dl, a, b, true)
			im.DrawList_AddText(dl, {a.x + 4, a.y}, 0xFFFFFFFF, cstr(text))
			im.DrawList_PopClipRect(dl)
		}
	}

	// Clips
	for c in project.clips {
		y := track_to_y(p0.y, c.track)
		a := im.Vec2{time_to_x(p0.x, c.start), y + 2}
		b := im.Vec2{time_to_x(p0.x, clip_end(c)), y + track_h - 3}
		if b.x < win_pos.x || a.x > win_pos.x + win_size.x {continue} // off screen
		im.DrawList_AddRectFilled(dl, a, b, clip_color(c))
		im.DrawList_AddRect(dl, a, b, c.selected ? 0xFFFFFFFF : (c.locked ? 0xFF30D0FF : 0xFF000000), 0, c.locked ? 2 : 1)
		if c.locked && b.x - a.x > 20 { // padlock
			im.DrawList_AddRect(dl, {b.x - 13, a.y + 4}, {b.x - 7, a.y + 10}, 0xFF30D0FF)
			im.DrawList_AddRectFilled(dl, {b.x - 15, a.y + 8}, {b.x - 5, a.y + 16}, 0xFF30D0FF)
		}
		if c.kind == .Audio { 	// waveform, scaled by the clip's volume
			mid, half := (a.y + b.y) / 2, (b.y - a.y) / 2 - 3
			gain := db_to_gain(c.gain_db)
			for x := max(a.x, win_pos.x + HEADER_W); x < min(b.x, win_pos.x + win_size.x); x += 1 {
				t0 := c.in_point + x_to_time(a.x, x) * c.speed
				t1 := c.in_point + x_to_time(a.x, x + 1) * c.speed
				h := min(peak_between(c.source, t0, t1) * gain, 1) * half
				im.DrawList_AddLine(dl, {x, mid - h}, {x, mid + h}, 0xA0FFFFFF)
			}
		}
		if c.group != 0 { 	// linked clips get a colored stripe, same color per group
			r, g, bl: f32
			im.ColorConvertHSVtoRGB(f32(c.group * 37 % 100) / 100, 0.7, 0.95, &r, &g, &bl)
			im.DrawList_AddRectFilled(dl, {a.x, b.y - 4}, {b.x, b.y}, im.ColorConvertFloat4ToU32({r, g, bl, 1}))
		}
		im.DrawList_PushClipRect(dl, a, b, true)
		im.DrawList_AddText(dl, {a.x + 4, a.y + 4}, 0xFFFFFFFF, cstr(filepath.base(project.sources[c.source].path)))
		im.DrawList_PopClipRect(dl)
	}

	// a box being dragged: lines or clips it selects
	if drag == .Lyric_Box || drag == .Box {
		x0, x1 := time_to_x(p0.x, min(drag_ref, part_drag_t)), time_to_x(p0.x, max(drag_ref, part_drag_t))
		y0, y1 := p0.y + LYR_Y, p0.y + LANES_Y
		if drag == .Box {y0, y1 = min(box_y0, mouse.y), max(box_y0, mouse.y)}
		im.DrawList_AddRectFilled(dl, {x0, y0}, {x1, y1}, 0x30FFFFFF)
		im.DrawList_AddRect(dl, {x0, y0}, {x1, y1}, 0xC0FFFFFF)
	}

	// locked lanes are dimmed
	for track in 0 ..< project.track_count {
		if track_has(project, track, .Locked) {
			y := track_to_y(p0.y, track)
			im.DrawList_AddRectFilled(dl, {p0.x, y}, {p0.x + size.x, y + track_h - 1}, 0x70000000)
		}
	}

	// Playhead
	px := time_to_x(p0.x, playhead)
	im.DrawList_AddLine(dl, {px, p0.y}, {px, p0.y + size.y}, 0xFF3030FF, 2)

	// razor: show where the cut would land
	if tool == .Razor && canvas_hovered && mouse.y > p0.y + LANES_Y {
		rx := time_to_x(p0.x, snap(max(0, t_mouse)))
		im.DrawList_AddLine(dl, {rx, p0.y + LANES_Y}, {rx, p0.y + size.y}, 0xFF40A0FF, 1)
	}

	// Ruler: ticks every second, m:ss labels spaced so they never touch. It stays at the top while the lanes scroll.
	ry := p0.y + sy
	im.DrawList_AddRectFilled(dl, p0, {p0.x + size.x, ry + RULER_H}, 0xFF303030)
	cx := time_to_x(p0.x, checkpoint) // checkpoint marker: where a double-tapped play returns to
	im.DrawList_AddTriangleFilled(dl, {cx - 5, ry}, {cx + 5, ry}, {cx, ry + 9}, 0xFF40C0FF)
	label_step := 1
	for s in ([?]int{1, 2, 5, 10, 15, 30, 60, 120, 300, 600}) {
		label_step = s
		if f32(s) * zoom >= 64 {break}
	}
	for s in 0 ..< int(length) {
		x := time_to_x(p0.x, f64(s))
		big := s % label_step == 0
		im.DrawList_AddLine(dl, {x, ry + RULER_H - (big ? 9 : 5)}, {x, ry + RULER_H}, 0xFF909090)
		if big {
			im.DrawList_AddText(dl, {x + 3, ry + 2}, 0xFFC0C0C0, cstr(fmt.tprintf("%d:%02d", s / 60, s % 60)))
		}
	}

	px_top := time_to_x(p0.x, playhead)
	im.DrawList_AddLine(dl, {px_top, ry}, {px_top, ry + RULER_H}, 0xFF3030FF, 2)
	im.DrawList_AddTriangleFilled(dl, {px_top - 6, ry}, {px_top + 6, ry}, {px_top, ry + 10}, 0xFF3030FF)

	draw_track_headers(dl, p0, sx, size.y, rows, vl)
	context_menu() // opened by the right-clicks above, so it must live in this window
	part_edit_popup()
}

// ---------------------------------------------------------------- track headers

// The header column: layer name, eye (video), mute + solo (audio), lock.
// Drawn last and offset by the scroll, so it stays on top at the left edge.
draw_track_headers :: proc(dl: ^im.DrawList, p0: im.Vec2, sx, height: f32, rows: int, vl: []int) {
	hl := p0.x - HEADER_W + sx
	hr := hl + HEADER_W
	im.DrawList_AddRectFilled(dl, {hl, p0.y}, {hr, p0.y + height}, 0xFF1B1B1B)
	sy := im.GetScrollY()
	im.DrawList_AddRectFilled(dl, {hl, p0.y + sy}, {hr, p0.y + sy + RULER_H}, 0xFF303030)
	im.DrawList_AddText(dl, {hl + 8, p0.y + sy + 3}, 0xFFFFFFFF, cstr(fmt.tprintf("%d fps", project.settings.fps)))
	im.DrawList_AddText(dl, {hl + 8, p0.y + RULER_H + 1}, 0xFFB0B0B0, "Parts")
	im.DrawList_AddText(dl, {hl + 8, p0.y + PROG_Y + 5}, 0xFFFFFFFF, "Program")
	im.DrawList_AddText(dl, {hl + 8, p0.y + LYR_Y + 1}, 0xFFB0B0B0, "Lyrics")

	mouse := im.GetMousePos()
	click := im.IsWindowHovered() && im.IsMouseClicked(.Left)
	for r in 0 ..< rows {
		y := p0.y + LANES_Y + f32(r) * track_h
		track := project.track_count - 1 - r
		real := track >= 0
		col: u32 = r % 2 == 0 ? 0xFF222222 : 0xFF292929
		if real && track_has(project, track, .Selected) {
			col = 0xFF4A3A20
		}
		im.DrawList_AddRectFilled(dl, {hl, y}, {hr, y + track_h - 1}, col)
		if !real {continue}

		im.DrawList_AddText(dl, {hl + 8, y + 12}, 0xFFE0E0E0, cstr(lane_label(vl, track)))
		has_video, has_audio := lane_kinds(track)
		bx, by := hl + 42, y + (track_h - 20) / 2
		toggled := false
		toggle :: proc(track: int, flag: Track_Flag) {
			flags := &project.track_flags[track]
			if flag in flags {flags^ -= {flag}} else {flags^ += {flag}}
			if flag == .Locked && .Locked in flags^ { // locking drops the clips from the selection
				for &c in project.clips {
					if c.track == track {c.selected = false}
				}
			}
		}
		button :: proc(dl: ^im.DrawList, pos: im.Vec2, icon: Icon, text: cstring, on: bool, on_col: u32, click: bool, mouse: im.Vec2) -> bool {
			a, b := pos, im.Vec2{pos.x + 20, pos.y + 20}
			hov := mouse.x >= a.x && mouse.x < b.x && mouse.y >= a.y && mouse.y < b.y
			im.DrawList_AddRectFilled(dl, a, b, on ? on_col : (hov ? 0xFF404040 : 0xFF303030), 3)
			if text != nil {
				im.DrawList_AddText(dl, {a.x + 6, a.y + 3}, on ? 0xFF101010 : 0xFFB0B0B0, text)
			} else {
				draw_icon(dl, icon, {(a.x + b.x) / 2, (a.y + b.y) / 2}, 20, on ? 0xFF101010 : 0xFFB0B0B0)
			}
			return hov && click
		}
		if has_video {
			if button(dl, {bx, by}, .Eye, nil, !track_has(project, track, .Hidden), 0xFFE0C080, click, mouse) {
				toggle(track, .Hidden)
				toggled = true
			}
			bx += 22
		}
		if has_audio {
			if button(dl, {bx, by}, .Select, "M", track_has(project, track, .Muted), 0xFF3090E0, click, mouse) {
				toggle(track, .Muted)
				toggled = true
			}
			bx += 22
			if button(dl, {bx, by}, .Select, "S", track_has(project, track, .Solo), 0xFF40D0E0, click, mouse) {
				toggle(track, .Solo)
				toggled = true
			}
			bx += 22
		}
		if button(dl, {hr - 26, by}, .Lock, nil, track_has(project, track, .Locked), 0xFF6060E0, click, mouse) {
			toggle(track, .Locked)
			toggled = true
		}
		// clicking elsewhere on the header selects the layer
		if click && !toggled && mouse.x >= hl && mouse.x < hr && mouse.y >= y && mouse.y < y + track_h {
			select_track(track, im.GetIO().KeyCtrl, im.GetIO().KeyShift)
		}
		// right-click: keep a multi-selection if the layer is in it, then open the layer menu
		if im.IsWindowHovered() && im.IsMouseClicked(.Right) && mouse.x >= hl && mouse.x < hr && mouse.y >= y && mouse.y < y + track_h {
			if !track_has(project, track, .Selected) {
				select_track(track, false, false)
			}
			open_context(.Header, 0, track)
		}
	}
	im.DrawList_AddLine(dl, {hr, p0.y}, {hr, p0.y + height}, 0xFF000000)
}
