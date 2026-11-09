package main

import "core:fmt"
import "core:math"
import "core:slice"
import "core:strings"

import im "deps/odin-imgui"

show_preview := true
show_timeline := true
show_inspector := true
show_project := true // sequence settings
show_levels := true
show_media := true
reset_layout: bool

cstr :: proc(s: string) -> cstring {
	return strings.clone_to_cstring(s, context.temp_allocator)
}

// ---------------------------------------------------------------- frame

frame :: proc() {
	for a in Action {
		if pressed(a) {
			do_action(a)
		}
	}
	sync_tracks(&project)
	build_tracks(project)
	if playing {
		if audio_ok && audio_was_playing {
			playhead = audio_time() // the audio clock drives playback
		} else {
			playhead += f64(im.GetIO().DeltaTime)
		}
		if loop_playback { // loop over the selected program range
			if t0, t1, ok := program_range(); ok && playhead >= t1 - 1e-3 {
				playhead = t0
				audio_seek(t0)
			}
		}
		if playhead >= project_length(project) {
			playing = false
		}
	}

	audio_transport(playing, playhead)
	audio_publish(project)

	main_menu()

	vp := im.GetMainViewport()
	dock := im.GetID("layout_v2") // new name = old saved layouts are ignored
	if reset_layout || im.DockBuilderGetNode(dock) == nil {
		build_layout(dock, vp.WorkSize)
		reset_layout = false
	}
	im.DockSpaceOverViewport(dock, vp)

	if show_media {panel_media()}
	if show_preview {panel_preview()}
	if show_inspector {panel_inspector()}
	if show_levels {panel_levels()}
	if show_project {panel_project()}
	if show_timeline {panel_timeline()}
	panel_randomize()
	panel_patterns()
	panel_palette()

	history_commit(drag != .None || im.IsAnyItemActive())
}

// Premiere-style: media + sequence settings on the left, program monitor in the
// middle, inspector + levels on the right, timeline along the bottom.
build_layout :: proc(dock: im.ID, size: im.Vec2) {
	im.DockBuilderRemoveNode(dock)
	im.DockBuilderAddNode(dock, transmute(im.DockNodeFlags)u32(1 << 10)) // ImGuiDockNodeFlags_DockSpace
	im.DockBuilderSetNodeSize(dock, size)
	top, bottom: im.ID
	im.DockBuilderSplitNode(dock, .Down, 0.40, &bottom, &top)
	left, rest: im.ID
	im.DockBuilderSplitNode(top, .Left, 0.22, &left, &rest)
	right, center: im.ID
	im.DockBuilderSplitNode(rest, .Right, 0.27, &right, &center)
	im.DockBuilderDockWindow("Media", left)
	im.DockBuilderDockWindow("Sequence", left)
	im.DockBuilderDockWindow("Program", center)
	im.DockBuilderDockWindow("Inspector", right)
	im.DockBuilderDockWindow("Levels", right)
	im.DockBuilderDockWindow("Timeline", bottom)
	im.DockBuilderDockWindow("Patterns", bottom)
	im.DockBuilderFinish(dock)
}

// ---------------------------------------------------------------- preview

panel_preview :: proc() {
	defer im.End()
	if !im.Begin("Program", &show_preview) {
		return
	}
	defer transport_bar() // runs before End, also on the early returns below
	s := project.settings
	avail := im.GetContentRegionAvail()
	avail.y = max(avail.y - TRANSPORT_H, 10)
	aspect := f32(s.width) / f32(max(s.height, 1))
	cw := min(avail.x, avail.y * aspect)
	ch := cw / aspect
	if cw < 2 || ch < 2 {
		return
	}
	cur := im.GetCursorScreenPos()
	a := im.Vec2{cur.x + (avail.x - cw) / 2, cur.y + (avail.y - ch) / 2}
	b := im.Vec2{a.x + cw, a.y + ch}
	im.Dummy(avail)

	dl := im.GetWindowDrawList()
	im.DrawList_AddRectFilled(dl, a, b, 0xFF000000)
	ci := video_clip_at(project, playhead)
	if ci < 0 {
		return
	}
	c := project.clips[ci]
	preview_show(c.source, c.in_point + (playhead - c.start) * c.speed)
	if pv_w <= 0 {
		return
	}
	// fit the frame into the canvas, then apply the clip transform (same math as export)
	k := min(cw / f32(pv_w), ch / f32(pv_h)) * c.scale
	hw, hh := f32(pv_w) * k / 2, f32(pv_h) * k / 2
	px := cw / f32(s.width) // canvas pixels -> screen pixels
	center := im.Vec2{a.x + cw / 2 + c.pos.x * px, a.y + ch / 2 + c.pos.y * px}
	sin_r, cos_r := math.sincos(c.rotation * math.PI / 180)
	corner :: proc(center: im.Vec2, x, y, s, c: f32) -> im.Vec2 {
		return {center.x + x * c - y * s, center.y + x * s + y * c}
	}
	im.DrawList_PushClipRect(dl, a, b, true)
	im.DrawList_AddImageQuad(
		dl,
		{_TexID = im.TextureID(pv_texture)},
		corner(center, -hw, -hh, sin_r, cos_r),
		corner(center, hw, -hh, sin_r, cos_r),
		corner(center, hw, hh, sin_r, cos_r),
		corner(center, -hw, hh, sin_r, cos_r),
	)
	im.DrawList_PopClipRect(dl)
}

// ---------------------------------------------------------------- inspector / project

panel_inspector :: proc() {
	defer im.End()
	if !im.Begin("Inspector", &show_inspector) {
		return
	}
	vi, ai := -1, -1
	for c, i in project.clips {
		if !c.selected {continue}
		if c.kind == .Video && vi < 0 {vi = i}
		if c.kind == .Audio && ai < 0 {ai = i}
	}
	if vi < 0 && ai < 0 {
		im.TextDisabled("Select a clip")
		return
	}
	info := project.clips[vi >= 0 ? vi : ai]
	im.TextUnformatted(cstr(project.sources[info.source].path))
	im.Text("start %.2fs   length %.2fs   speed %.2fx", info.start, info.duration, info.speed)

	// edits apply to every selected clip of that kind
	if vi >= 0 {
		im.Separator()
		c := project.clips[vi]
		changed := false
		changed |= im.DragFloat2("position", &c.pos, 1, 0, 0, "%.0f px")
		changed |= im.DragFloat("scale", &c.scale, 0.01, 0.01, 10, "%.2f")
		changed |= im.DragFloat("rotation", &c.rotation, 0.5, -360, 360, "%.1f deg")
		if im.Button("Reset transform") {
			c.pos, c.scale, c.rotation = {}, 1, 0
			changed = true
		}
		if changed {
			for &k in project.clips {
				if k.selected && k.kind == .Video {
					k.pos, k.scale, k.rotation = c.pos, c.scale, c.rotation
				}
			}
		}
	}
	if ai >= 0 {
		im.Separator()
		g := project.clips[ai].gain_db
		changed := im.DragFloat("volume", &g, 0.1, -60, 12, g <= -60 ? "muted" : "%.1f dB")
		im.SameLine()
		if im.Button("Reset##volume") {
			g = 0
			changed = true
		}
		if changed {
			for &k in project.clips {
				if k.selected && k.kind == .Audio {
					k.gain_db = g
				}
			}
		}
	}
}

// Master volume and stereo peak meters (dB, with a falling peak hold).
meter_l, meter_r: f32 = -90, -90

panel_levels :: proc() {
	defer im.End()
	if !im.Begin("Levels", &show_levels) {
		return
	}
	dt := im.GetIO().DeltaTime
	l, r := audio_levels()
	to_db :: proc(v: f32) -> f32 {return v < 1e-5 ? -100 : 20 * math.log10(v)}
	meter_l = max(to_db(l), meter_l - 45 * dt)
	meter_r = max(to_db(r), meter_r - 45 * dt)

	im.SetNextItemWidth(-60)
	im.DragFloat("master", &project.settings.master_db, 0.1, -60, 12, project.settings.master_db <= -60 ? "muted" : "%.1f dB")
	if !audio_ok {
		im.TextDisabled("no audio device")
	}
	level_bar("L", meter_l)
	level_bar("R", meter_r)
}

// One horizontal meter, -60..+6 dB: green, yellow above -12, red above -3.
level_bar :: proc(name: cstring, db: f32) {
	avail := im.GetContentRegionAvail()
	p := im.GetCursorScreenPos()
	h := f32(14)
	w := max(avail.x - 56, 20)
	dl := im.GetWindowDrawList()
	x_of :: proc(db, x0, w: f32) -> f32 {return x0 + w * clamp((db + 60) / 66, 0, 1)}
	x0 := p.x + 14
	im.DrawList_AddText(dl, {p.x, p.y}, 0xFFC0C0C0, name)
	im.DrawList_AddRectFilled(dl, {x0, p.y}, {x0 + w, p.y + h}, 0xFF202020)
	zones := [3]struct {
		from, to: f32,
		col:      u32,
	}{{-60, -12, 0xFF3FA84E}, {-12, -3, 0xFF30C0D0}, {-3, 6, 0xFF3030E0}}
	for z in zones {
		hi := min(db, z.to)
		if hi > z.from {
			im.DrawList_AddRectFilled(dl, {x_of(z.from, x0, w), p.y}, {x_of(hi, x0, w), p.y + h}, z.col)
		}
	}
	im.DrawList_AddLine(dl, {x_of(0, x0, w), p.y}, {x_of(0, x0, w), p.y + h}, 0xFF808080) // 0 dB
	im.DrawList_AddText(dl, {x0 + w + 6, p.y}, 0xFFC0C0C0, cstr(db < -90 ? "-inf" : fmt.tprintf("%.0f dB", db)))
	im.Dummy({1, h + 4})
}

panel_project :: proc() {
	defer im.End()
	if !im.Begin("Sequence", &show_project) {
		return
	}
	s := &project.settings
	s.grid_type = .Beats // the grid is always the bpm grid

	// 1. media
	if im.Button("Import...") {do_action(.Import)}
	im.SameLine()
	if im.Button("Remove audio") {do_action(.Remove_Audio)}
	im.SameLine()
	if im.Button("Export...") {do_action(.Export)}

	// 2. tempo
	im.SeparatorText("Tempo")
	if im.Button("Detect bpm") {do_action(.Detect_Bpm)}
	im.SameLine()
	if im.Button("Tap") {do_action(.Tap_Tempo)}
	im.SameLine()
	if im.Button("x2") {s.bpm = min(s.bpm * 2, 400)}
	im.SameLine()
	if im.Button("/2") {s.bpm = max(s.bpm / 2, 20)}
	im.SetNextItemWidth(-90)
	im.DragFloat("bpm", &s.bpm, 0.1, 20, 400, "%.2f")
	bpm_controls(s)
	im.SetNextItemWidth(-90)
	im.DragScalar("first beat", .Double, &s.grid_offset, 0.001, nil, nil, "%.3f s")
	if im.Button("Beat at playhead") {do_action(.Grid_Here)}

	// 3. grid
	im.SeparatorText("Grid")
	im.Checkbox("snap to grid", &s.grid_on)
	div := i32(0)
	for d, i in GRID_DIVS {
		if d == s.grid_div {div = i32(i)}
	}
	im.SetNextItemWidth(-90)
	if im.Combo("lines / beat", &div, "1\x002\x004\x008\x0016\x00\x00") {
		s.grid_div = GRID_DIVS[div]
	}
	im.SetNextItemWidth(-90)
	im.DragInt("slice every", &s.cut_every, 0.2, 1, 64, "%d lines")

	// 4. project
	if im.CollapsingHeader("Project settings") {
		im.InputText("name", cstring(&s.name[0]), len(s.name))
		im.DragInt("frame rate", &s.fps, 0.2, 1, 120)
		im.InputInt("width", &s.width, 2, 100)
		im.InputInt("height", &s.height, 2, 100)
		s.fps = clamp(s.fps, 1, 120)
		s.width = clamp(s.width, 16, 7680)
		s.height = clamp(s.height, 16, 4320)
		fmt_i := i32(s.format)
		if im.Combo("format", &fmt_i, "mp4\x00mkv\x00webm\x00mov\x00\x00") {
			s.format = Export_Format(fmt_i)
		}
		im.TextDisabled(cstr(project_path == "" ? "(unsaved project)" : project_path))
	}
}

