package main

import "core:fmt"
import "core:math"
import "core:path/filepath"

import im "deps/odin-imgui"

// Small shared UI pieces: drawn icons (no icon font needed), timecode, the
// transport bar under the program monitor and the media bin.

Icon :: enum {
	Select,
	Razor,
	Hand,
	Zoom,
	Play,
	Pause,
	To_Start,
	To_End,
	Step_Back,
	Step_Forward,
	Eye,
	Lock,
	Plus,
	Minus,
	Magnet,
}

// Draws `kind` centred at c inside a box of `size` pixels.
draw_icon :: proc(dl: ^im.DrawList, kind: Icon, c: im.Vec2, size: f32, col: u32) {
	s := size
	v :: proc(c: im.Vec2, s, x, y: f32) -> im.Vec2 {return {c.x + x * s, c.y + y * s}} // offset in units of size
	tri :: proc(dl: ^im.DrawList, a, b, c: im.Vec2, col: u32) {im.DrawList_AddTriangleFilled(dl, a, b, c, col)}
	bar :: proc(dl: ^im.DrawList, c: im.Vec2, s, x0, y0, x1, y1: f32, col: u32) {
		im.DrawList_AddRectFilled(dl, v(c, s, x0, y0), v(c, s, x1, y1), col)
	}
	switch kind {
	case .Select: // pointer arrow
		tri(dl, v(c, s, -0.18, -0.30), v(c, s, -0.18, 0.22), v(c, s, -0.04, 0.10), col)
		tri(dl, v(c, s, -0.18, -0.30), v(c, s, -0.04, 0.10), v(c, s, 0.22, 0.08), col)
		im.DrawList_AddLine(dl, v(c, s, -0.02, 0.10), v(c, s, 0.10, 0.32), col, 2.5)
	case .Razor: // "split here": a line with two arrows pointing at it
		bar(dl, c, s, -0.03, -0.32, 0.03, 0.32, col)
		tri(dl, v(c, s, -0.10, 0), v(c, s, -0.30, -0.16), v(c, s, -0.30, 0.16), col)
		tri(dl, v(c, s, 0.10, 0), v(c, s, 0.30, -0.16), v(c, s, 0.30, 0.16), col)
	case .Hand: // palm + fingers
		im.DrawList_AddCircleFilled(dl, v(c, s, 0, 0.12), 0.20 * s, col)
		for i in 0 ..< 4 {
			x := -0.15 + f32(i) * 0.10
			bar(dl, c, s, x - 0.035, -0.28 + (i == 0 || i == 3 ? 0.08 : 0), x + 0.035, 0.12, col)
		}
	case .Zoom: // magnifier
		im.DrawList_AddCircle(dl, v(c, s, -0.06, -0.06), 0.20 * s, col, 0, 2.2)
		im.DrawList_AddLine(dl, v(c, s, 0.08, 0.08), v(c, s, 0.28, 0.28), col, 3)
	case .Play:
		tri(dl, v(c, s, -0.16, -0.26), v(c, s, -0.16, 0.26), v(c, s, 0.28, 0), col)
	case .Pause:
		bar(dl, c, s, -0.20, -0.24, -0.06, 0.24, col)
		bar(dl, c, s, 0.06, -0.24, 0.20, 0.24, col)
	case .To_Start:
		bar(dl, c, s, -0.28, -0.24, -0.22, 0.24, col)
		tri(dl, v(c, s, 0.02, -0.22), v(c, s, 0.02, 0.22), v(c, s, -0.20, 0), col)
		tri(dl, v(c, s, 0.26, -0.22), v(c, s, 0.26, 0.22), v(c, s, 0.04, 0), col)
	case .To_End:
		bar(dl, c, s, 0.22, -0.24, 0.28, 0.24, col)
		tri(dl, v(c, s, -0.02, -0.22), v(c, s, -0.02, 0.22), v(c, s, 0.20, 0), col)
		tri(dl, v(c, s, -0.26, -0.22), v(c, s, -0.26, 0.22), v(c, s, -0.04, 0), col)
	case .Step_Back:
		bar(dl, c, s, 0.14, -0.24, 0.20, 0.24, col)
		tri(dl, v(c, s, 0.10, -0.22), v(c, s, 0.10, 0.22), v(c, s, -0.18, 0), col)
	case .Step_Forward:
		bar(dl, c, s, -0.20, -0.24, -0.14, 0.24, col)
		tri(dl, v(c, s, -0.10, -0.22), v(c, s, -0.10, 0.22), v(c, s, 0.18, 0), col)
	case .Eye:
		im.DrawList_AddRect(dl, v(c, s, -0.30, -0.15), v(c, s, 0.30, 0.15), col, 0.15 * s, thickness = 1.6)
		im.DrawList_AddCircleFilled(dl, c, 0.09 * s, col)
	case .Lock:
		bar(dl, c, s, -0.20, -0.02, 0.20, 0.28, col)
		im.DrawList_AddRect(dl, v(c, s, -0.12, -0.28), v(c, s, 0.12, 0.02), col, thickness = 1.8)
	case .Plus:
		bar(dl, c, s, -0.26, -0.04, 0.26, 0.04, col)
		bar(dl, c, s, -0.04, -0.26, 0.04, 0.26, col)
	case .Minus:
		bar(dl, c, s, -0.26, -0.04, 0.26, 0.04, col)
	case .Magnet: // snapping
		bar(dl, c, s, -0.24, -0.26, -0.10, 0.10, col)
		bar(dl, c, s, 0.10, -0.26, 0.24, 0.10, col)
		bar(dl, c, s, -0.24, -0.26, 0.24, -0.14, col)
		bar(dl, c, s, -0.24, 0.10, -0.10, 0.26, 0xFF4040E0)
		bar(dl, c, s, 0.10, 0.10, 0.24, 0.26, 0xFF4040E0)
	}
}

// A square button showing an icon; `active` highlights it (e.g. the current tool).
icon_button :: proc(id: cstring, kind: Icon, size: f32, active := false, tip: cstring = nil) -> bool {
	clicked := im.InvisibleButton(id, {size, size})
	a, b := im.GetItemRectMin(), im.GetItemRectMax()
	hov := im.IsItemHovered()
	dl := im.GetWindowDrawList()
	bg: u32 = active ? 0xFF8A5A2A : (hov ? 0xFF404040 : 0xFF2C2C2C)
	im.DrawList_AddRectFilled(dl, a, b, bg, 4)
	draw_icon(dl, kind, {(a.x + b.x) / 2, (a.y + b.y) / 2}, size, active ? 0xFFFFFFFF : 0xFFD0D0D0)
	if hov && tip != nil {
		im.SetTooltip("%s", tip)
	}
	return clicked
}

// HH:MM:SS:FF
timecode :: proc(t: f64, fps: i32) -> string {
	f := int(max(fps, 1))
	total := int(math.round(max(t, 0) * f64(f)))
	secs := total / f
	return fmt.tprintf("%02d:%02d:%02d:%02d", secs / 3600, secs / 60 % 60, secs % 60, total % f)
}

// ---------------------------------------------------------------- transport

TRANSPORT_H :: 40

// Timecode on the left, transport buttons centred, under the program monitor.
transport_bar :: proc() {
	width := im.GetContentRegionAvail().x
	im.TextUnformatted(cstr(timecode(playhead, project.settings.fps)))
	b := f32(30)
	im.SameLine(max((width - 5 * b - 4 * 6) / 2, 110))
	if icon_button("##tostart", .To_Start, b, false, cstr(fmt.tprintf("Go to start (%s)", bindings[.Go_Start][0].text))) {do_action(.Go_Start)}
	im.SameLine()
	if icon_button("##stepback", .Step_Back, b, false, "Back one frame") {do_action(.Step_Back)}
	im.SameLine()
	if icon_button("##play", playing ? .Pause : .Play, b, playing, cstr(fmt.tprintf("Play / pause (%s), twice = back to checkpoint", bindings[.Play][0].text))) {do_action(.Play)}
	im.SameLine()
	if icon_button("##stepfwd", .Step_Forward, b, false, "Forward one frame") {do_action(.Step_Forward)}
	im.SameLine()
	if icon_button("##toend", .To_End, b, false, cstr(fmt.tprintf("Go to end (%s)", bindings[.Go_End][0].text))) {do_action(.Go_End)}
}

// ---------------------------------------------------------------- media bin

panel_media :: proc() {
	defer im.End()
	if !im.Begin("Media", &show_media) {
		return
	}
	if im.Button("Import...") {
		do_action(.Import)
	}
	im.SameLine()
	im.TextDisabled("drag onto the timeline, or double-click")
	im.Separator()
	for s, i in project.sources {
		name := filepath.base(s.path)
		kinds := fmt.tprintf("%s%s", s.has_video ? "V" : "-", s.has_audio ? "A" : "-")
		d := int(s.duration)
		label := cstr(fmt.tprintf("%s  %s  %d:%02d###src%d", kinds, name, d / 60, d % 60, i))
		im.Selectable(label, false, {.AllowDoubleClick})
		if im.IsItemHovered() && im.IsMouseDoubleClicked(.Left) {
			place_source(&project, i, playhead, -1)
		}
		if im.BeginDragDropSource() {
			idx := i
			im.SetDragDropPayload("SOURCE", &idx, size_of(int))
			im.Text("%s", cstr(name))
			im.EndDragDropSource()
		}
	}
	if len(project.sources) == 0 {
		im.TextDisabled("no media yet: File > Import, or drop files here")
	}
}

// ---------------------------------------------------------------- tempo detection controls

// In the Sequence panel under the bpm: what detection found (the best is applied,
// click another), and the rarely needed options folded away.
bpm_controls :: proc(s: ^Settings) {
	if bpm_cand_n > 1 {
		for i in 0 ..< bpm_cand_n {
			c := bpm_cands[i]
			if i > 0 {im.SameLine()}
			if im.Button(cstr(fmt.tprintf("%s%.1f###cand%d", i == bpm_cand_active ? "> " : "", c.bpm, i))) {
				use_bpm_candidate(i)
			}
		}
	}
	if im.TreeNode("detection options") {
		src := bpm_source_clip()
		name := "no audio clip"
		if src >= 0 {
			name = fmt.tprintf("%s%s", audio_clip_ok(bpm_src_clip) ? "" : "(auto) ", filepath.base(project.sources[project.clips[src].source].path))
		}
		im.SetNextItemWidth(-90)
		if im.BeginCombo("analyse", cstr(name)) {
			if im.Selectable("auto", !audio_clip_ok(bpm_src_clip)) {
				bpm_src_clip = -1
			}
			for c, i in project.clips {
				if !audio_clip_ok(i) {continue}
				label := fmt.tprintf("%s   layer %d###bpmsrc%d", filepath.base(project.sources[c.source].path), c.track + 1, i)
				if im.Selectable(cstr(label), i == bpm_src_clip) {
					bpm_src_clip = i
				}
			}
			im.EndCombo()
		}
		im.SetNextItemWidth(70)
		im.DragFloat("##bpmlo", &s.bpm_lo, 1, 40, 220, "%.0f")
		im.SameLine()
		im.SetNextItemWidth(70)
		im.DragFloat("bpm range", &s.bpm_hi, 1, 60, 260, "%.0f")
		im.TreePop()
	}
}
