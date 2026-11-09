package main

import "core:fmt"
import "core:math"
import "core:path/filepath"
import "core:slice"

import im "deps/odin-imgui"

TRACK_H :: 40
RULER_H :: 20
PART_H :: 16 // the parts row under the ruler
PROG_Y :: RULER_H + PART_H
PROG_H :: 26 // the program lane under the parts row
LANES_Y :: PROG_Y + PROG_H
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
	Pan, // hand tool
}

zoom: f32 = 50 // pixels per second
sel_anchor := -1 // last layer clicked, start of a shift-click range
sel_cut := -1 // first selected program segment (index of its cut), -1 = none
sel_cut2 := -1 // last selected program segment (>= sel_cut)
drag_seg: int // the segment a range selection started at
loop_playback: bool // loop the selected program range while playing

sel_part := -1 // selected part
part_drag_t: f64 // the free end of a part being dragged out

select_cuts :: proc(a, b: int) {
	sel_cut, sel_cut2 = min(a, b), max(a, b)
	sel_part = -1
}

clear_cut_sel :: proc() {
	sel_cut, sel_cut2 = -1, -1
	sel_part = -1
}

// The part that contains time t, or -1.
part_at :: proc(t: f64) -> int {
	for part, i in project.parts {
		if t >= part.t0 && t < part.t1 {return i}
	}
	return -1
}

// Adds a part over a..b with the current pattern; parts it overlaps are replaced.
make_part :: proc(a, b: f64) {
	if b - a < 1e-3 {return}
	#reverse for part, i in project.parts {
		if part.t0 < b && part.t1 > a {ordered_remove(&project.parts, i)}
	}
	pattern := len(project.patterns) > 0 ? project.settings.pattern_sel : -1
	append(&project.parts, Part{a, b, pattern})
	slice.sort_by(project.parts[:], proc(x, y: Part) -> bool {return x.t0 < y.t0})
	sel_part = part_at((a + b) / 2)
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
	return top + LANES_Y + f32(project.track_count - 1 - track) * TRACK_H
}

y_to_track :: proc(top, y: f32) -> int {
	row := int(max(0, y - top - LANES_Y) / TRACK_H)
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

toolbar_button :: proc(a: Action, name: string) {
	if im.Button(labeled(a, name)) {
		do_action(a)
	}
	im.SameLine()
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
	im.TextDisabled(loop_playback ? "F1: commands   [looping the selected range]" : "F1: commands")

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
	size := im.Vec2{f32(length) * zoom, LANES_Y + TRACK_H * f32(max(project.track_count, 4))}

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
	if canvas_hovered && mouse.y > p0.y + PROG_Y && mouse.y < p0.y + LANES_Y && cut_near(p0.x, mouse.x) >= 0 {
		im.SetMouseCursor(.ResizeEW)
	}

	// ctrl+wheel zooms, middle mouse pans (any tool)
	if im.IsWindowHovered() {
		if io.KeyCtrl && io.MouseWheel != 0 {
			zoom_at(p0.x, sx, mouse.x, io.MouseWheel > 0 ? 1.25 : 0.8)
		}
		if im.IsMouseDragging(.Middle) {
			im.SetScrollX(sx - io.MouseDelta.x)
			im.SetScrollY(im.GetScrollY() - io.MouseDelta.y)
		}
	}

	// Right-click: context menu for what is under the mouse
	if im.IsItemClicked(.Right) && !in_header {
		switch {
		case mouse.y < p0.y + RULER_H:
		case mouse.y < p0.y + PROG_Y: // parts row
			if hit := part_at(t_mouse); hit >= 0 {
				clear_selection(&project)
				clear_track_selection(&project)
				clear_cut_sel()
				sel_part = hit
				open_context(.Part, t_mouse, -1)
			}
		case mouse.y < p0.y + LANES_Y:
			if seg := segment_at(project, t_mouse); seg >= 0 {
				clear_selection(&project)
				clear_track_selection(&project)
				if sel_cut < 0 || seg < sel_cut || seg > sel_cut2 { // right-click inside the range keeps it
					select_cuts(seg, seg)
				}
				open_context(.Segment, t_mouse, -1)
			}
		case hover >= 0:
			if !project.clips[hover].selected {
				clear_selection(&project)
				set_selected(&project, hover, true)
			}
			clear_track_selection(&project)
			clear_cut_sel()
			open_context(.Clip, t_mouse, project.clips[hover].track)
		case mouse.y < p0.y + LANES_Y + f32(project.track_count) * TRACK_H:
			track := y_to_track(p0.y, mouse.y)
			if !track_has(project, track, .Selected) {
				select_track(track, false, false)
			}
			open_context(.Lane, t_mouse, track)
		}
	}

	// Press
	if im.IsItemClicked() && !in_header {
		track := y_to_track(p0.y, mouse.y)
		switch {
		case mouse.y < p0.y + RULER_H:
			drag = .Scrub
		case mouse.y < p0.y + PROG_Y:
			// parts row: click a part to select it, drag on empty space to make one
			clear_selection(&project)
			clear_track_selection(&project)
			clear_cut_sel()
			if hit := part_at(t_mouse); hit >= 0 {
				sel_part = hit
				drag = .None
			} else {
				drag, drag_ref, part_drag_t = .Part_Create, snap(max(0, t_mouse)), snap(max(0, t_mouse))
			}
		case mouse.y < p0.y + LANES_Y:
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
			drag = zone_at(p0.x, mouse.x, hover)
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
			// empty lane space: pick the layer (ctrl: toggle, shift: range), move the checkpoint
			if mouse.y < p0.y + LANES_Y + f32(project.track_count) * TRACK_H {
				select_track(track, io.KeyCtrl, io.KeyShift)
			} else {
				clear_selection(&project)
				clear_track_selection(&project)
			}
			checkpoint = snap(max(0, t_mouse))
			clear_cut_sel()
			drag = .None
		}
	}

	// Drag
	if drag != .None {
		if !im.IsMouseDown(.Left) {
			if drag == .Part_Create {
				make_part(min(drag_ref, part_drag_t), max(drag_ref, part_drag_t))
			}
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

	// Ruler: ticks every second, m:ss labels spaced so they never touch
	im.DrawList_AddRectFilled(dl, p0, {p0.x + size.x, p0.y + RULER_H}, 0xFF303030)
	cx := time_to_x(p0.x, checkpoint) // checkpoint marker: where a double-tapped play returns to
	im.DrawList_AddTriangleFilled(dl, {cx - 5, p0.y}, {cx + 5, p0.y}, {cx, p0.y + 9}, 0xFF40C0FF)
	label_step := 1
	for s in ([?]int{1, 2, 5, 10, 15, 30, 60, 120, 300, 600}) {
		label_step = s
		if f32(s) * zoom >= 64 {break}
	}
	for s in 0 ..< int(length) {
		x := time_to_x(p0.x, f64(s))
		big := s % label_step == 0
		im.DrawList_AddLine(dl, {x, p0.y + RULER_H - (big ? 9 : 5)}, {x, p0.y + RULER_H}, 0xFF909090)
		if big {
			im.DrawList_AddText(dl, {x + 3, p0.y + 2}, 0xFFC0C0C0, cstr(fmt.tprintf("%d:%02d", s / 60, s % 60)))
		}
	}

	// Lanes
	rows := max(project.track_count, 4)
	for r in 0 ..< rows { // rows from the top; the bottom ones may be empty filler below the last track
		y := p0.y + LANES_Y + f32(r) * TRACK_H
		track := project.track_count - 1 - r
		col: u32 = r % 2 == 0 ? 0xFF202020 : 0xFF262626
		if track_has(project, track, .Selected) {
			col = 0xFF4A3A20
		}
		im.DrawList_AddRectFilled(dl, {p0.x, y}, {p0.x + size.x, y + TRACK_H - 1}, col)
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
			r, g, bl: f32
			im.ColorConvertHSVtoRGB(part.pattern >= 0 ? math.mod(f32(part.pattern) * 0.27 + 0.1, 1) : 0, part.pattern >= 0 ? 0.5 : 0, 0.55, &r, &g, &bl)
			im.DrawList_AddRectFilled(dl, a, b, im.ColorConvertFloat4ToU32({r, g, bl, 1}))
			im.DrawList_AddRect(dl, a, b, i == sel_part ? 0xFFFFFFFF : 0xFF000000)
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

	// Clips
	for c in project.clips {
		y := track_to_y(p0.y, c.track)
		a := im.Vec2{time_to_x(p0.x, c.start), y + 2}
		b := im.Vec2{time_to_x(p0.x, clip_end(c)), y + TRACK_H - 3}
		im.DrawList_AddRectFilled(dl, a, b, clip_color(c))
		im.DrawList_AddRect(dl, a, b, c.selected ? 0xFFFFFFFF : 0xFF000000)
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

	// locked lanes are dimmed
	for track in 0 ..< project.track_count {
		if track_has(project, track, .Locked) {
			y := track_to_y(p0.y, track)
			im.DrawList_AddRectFilled(dl, {p0.x, y}, {p0.x + size.x, y + TRACK_H - 1}, 0x70000000)
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

	draw_track_headers(dl, p0, sx, size.y, rows, vl)
	context_menu() // opened by the right-clicks above, so it must live in this window
}

// ---------------------------------------------------------------- track headers

// The header column: layer name, eye (video), mute + solo (audio), lock.
// Drawn last and offset by the scroll, so it stays on top at the left edge.
draw_track_headers :: proc(dl: ^im.DrawList, p0: im.Vec2, sx, height: f32, rows: int, vl: []int) {
	hl := p0.x - HEADER_W + sx
	hr := hl + HEADER_W
	im.DrawList_AddRectFilled(dl, {hl, p0.y}, {hr, p0.y + height}, 0xFF1B1B1B)
	im.DrawList_AddText(dl, {hl + 8, p0.y + 3}, 0xFFFFFFFF, cstr(fmt.tprintf("%d fps", project.settings.fps)))
	im.DrawList_AddText(dl, {hl + 8, p0.y + RULER_H + 1}, 0xFFB0B0B0, "Parts")
	im.DrawList_AddText(dl, {hl + 8, p0.y + PROG_Y + 5}, 0xFFFFFFFF, "Program")

	mouse := im.GetMousePos()
	click := im.IsWindowHovered() && im.IsMouseClicked(.Left)
	for r in 0 ..< rows {
		y := p0.y + LANES_Y + f32(r) * TRACK_H
		track := project.track_count - 1 - r
		real := track >= 0
		col: u32 = r % 2 == 0 ? 0xFF222222 : 0xFF292929
		if real && track_has(project, track, .Selected) {
			col = 0xFF4A3A20
		}
		im.DrawList_AddRectFilled(dl, {hl, y}, {hr, y + TRACK_H - 1}, col)
		if !real {continue}

		im.DrawList_AddText(dl, {hl + 8, y + 12}, 0xFFE0E0E0, cstr(lane_label(vl, track)))
		has_video, has_audio := lane_kinds(track)
		bx, by := hl + 42, y + (TRACK_H - 20) / 2
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
		if click && !toggled && mouse.x >= hl && mouse.x < hr && mouse.y >= y && mouse.y < y + TRACK_H {
			select_track(track, im.GetIO().KeyCtrl, im.GetIO().KeyShift)
		}
		// right-click: keep a multi-selection if the layer is in it, then open the layer menu
		if im.IsWindowHovered() && im.IsMouseClicked(.Right) && mouse.x >= hl && mouse.x < hr && mouse.y >= y && mouse.y < y + TRACK_H {
			if !track_has(project, track, .Selected) {
				select_track(track, false, false)
			}
			open_context(.Header, 0, track)
		}
	}
	im.DrawList_AddLine(dl, {hr, p0.y}, {hr, p0.y + height}, 0xFF000000)
}
