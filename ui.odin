package main

import "core:fmt"
import "core:math"
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
		if !job.active && !slow_dialog.open && pressed(a) { // nothing happens by key while a job runs
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
	panel_lyrics()
	panel_palette()
	slowmo_dialog_ui()
	job_ui()
	report_ui()

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
	if (im.IsItemHovered() && im.IsMouseDoubleClicked(.Left)) || bg_popup_open { // double-click the picture, or the command
		im.OpenPopup("##bgcolor")
		bg_popup_open = false
	}
	background_popup()

	dl := im.GetWindowDrawList()
	defer draw_lyric_preview(dl, a, b) // over the picture, also when there is none
	im.DrawList_AddRectFilled(dl, a, b, im.ColorConvertFloat4ToU32({s.bg.r, s.bg.g, s.bg.b, 1})) // the background colour
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
	kx := min(cw / f32(pv_w), ch / f32(pv_h))
	ky := kx
	#partial switch c.fit {
	case .Fill:    kx = max(cw / f32(pv_w), ch / f32(pv_h)); ky = kx
	case .Stretch: kx, ky = cw / f32(pv_w), ch / f32(pv_h)
	}
	hw, hh := f32(pv_w) * kx * c.scale / 2, f32(pv_h) * ky * c.scale / 2
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

// Which clips an edit in the Inspector reaches.
Apply_Scope :: enum {
	Selected,    // the selected clips
	Same_Source, // every slice that comes from the same file as a selected clip
	All,         // every clip of that kind
}
inspector_scope: Apply_Scope

// Does an Inspector edit reach clip k (the edit is for clips of `kind`)? Locked layers are left alone.
inspector_hits :: proc(k: Clip, kind: Clip_Kind) -> bool {
	if k.kind != kind || track_has(project, k.track, .Locked) {
		return false
	}
	switch inspector_scope {
	case .Selected: return k.selected
	case .Same_Source:
		for c in project.clips {
			if c.selected && c.kind == kind && c.source == k.source {return true}
		}
		return false
	case .All: return true
	}
	return false
}

// Typical output sizes. Pick one, or type width and height.
Size_Preset :: struct {
	name:  cstring,
	w, h:  i32,
}

SIZE_PRESETS := [?]Size_Preset {
	{"1080p  1920x1080 (16:9)", 1920, 1080},
	{"4K  3840x2160 (16:9)", 3840, 2160},
	{"1440p  2560x1440 (16:9)", 2560, 1440},
	{"720p  1280x720 (16:9)", 1280, 720},
	{"Vertical  1080x1920 (9:16)", 1080, 1920},
	{"Vertical 4K  2160x3840 (9:16)", 2160, 3840},
	{"Vertical 720p  720x1280 (9:16)", 720, 1280},
	{"Portrait  1080x1350 (4:5)", 1080, 1350},
	{"Square  1080x1080 (1:1)", 1080, 1080},
	{"Cinema  1920x804 (2.39:1)", 1920, 804},
}

// The output size: a preset list and a button to turn it 90 degrees.
size_presets :: proc(s: ^Settings) {
	current: cstring = "custom size"
	for p in SIZE_PRESETS {
		if p.w == s.width && p.h == s.height {current = p.name}
	}
	im.SetNextItemWidth(-90)
	if im.BeginCombo("size", current) {
		for p in SIZE_PRESETS {
			if im.Selectable(p.name, p.w == s.width && p.h == s.height) {s.width, s.height = p.w, p.h}
		}
		im.EndCombo()
	}
	im.Text("%d x %d", s.width, s.height)
	im.SameLine()
	if im.Button("turn") {s.width, s.height = s.height, s.width}
	tip("Swap width and height (horizontal <-> vertical)")
}

bg_popup_open: bool // set by the Background color command: the Program panel opens the picker

// The color picker over the Program picture.
background_popup :: proc() {
	if !im.BeginPopup("##bgcolor") {return}
	defer im.EndPopup()
	im.TextDisabled("Background color")
	im.ColorPicker3("##bg", &project.settings.bg, {.NoSidePreview})
	if im.Button("Black") {project.settings.bg = {0, 0, 0}}
	im.SameLine()
	if im.Button("White") {project.settings.bg = {1, 1, 1}}
	im.SameLine()
	if im.Button("Grey") {project.settings.bg = {0.18, 0.18, 0.18}}
}

// Moves every selected slice to other footage (dir +1 next, -1 previous, 0 reroll). Returns how many changed.
nudge_selected_slices :: proc(dir: int) -> (n: int) {
	for i in 0 ..< len(project.clips) {
		if project.clips[i].selected && slice_nudge(&project, i, dir, project.settings.rand.footage) {n += 1}
	}
	return
}

// Randomize settings and the selected slices, in the Inspector: how the footage is chosen, lock, reroll.
inspector_slices :: proc() {
	o := &project.settings.rand
	slices, locked, sel, sel_locked := 0, 0, 0, 0
	for c in project.clips {
		if !c.slice {continue}
		slices += 1
		locked += c.locked ? 1 : 0
		if c.selected {
			sel += 1
			sel_locked += c.locked ? 1 : 0
		}
	}

	im.SeparatorText("Randomize")
	slice_i := i32(o.slice)
	im.SetNextItemWidth(-90)
	if im.Combo("slice at", &slice_i, "the program's cuts\x00the pattern\x00the beat grid\x00\x00") {o.slice = Rand_Slice(slice_i)}
	footage := i32(o.footage)
	im.SetNextItemWidth(-90)
	if im.Combo("footage", &footage, "same time\x00in order\x00any piece\x00\x00") {o.footage = Rand_Footage(footage)}
	if im.IsItemHovered() {
		im.SetTooltip("same time: what plays at that time (cuts between clips)\nin order: each clip plays forward, a piece at a time\nany piece: a random piece\n\nThis also decides what the wheel and Reroll give a slice.")
	}
	if o.footage != .Same_Time {im.Checkbox("use all clips", &o.use_all)}
	im.SetNextItemWidth(-90)
	im.InputInt("max in a row", &o.max_run)
	o.max_run = max(o.max_run, 0)
	if im.Button("Randomize") {do_action(.Randomize)}
	tip("Make new slices. Locked slices stay, the others change.")
	im.SameLine()
	if im.Button("Options...") {show_randomize = true}
	if slices > 0 {dim_f("%d slices, %d locked", slices, locked)}

	if sel > 0 {
		im.SeparatorText("Selected slices")
		text_f("%d selected, %d locked", sel, sel_locked)
		if im.Button(sel_locked == sel ? "Unlock" : "Lock") {do_action(.Lock)}
		tip(fmt.tprintf("A locked slice stays when you Randomize again (%s)", bindings[.Lock][0].text))
		im.SameLine()
		if im.Button("<") {set_status("%d slice(s): previous footage", nudge_selected_slices(-1))}
		im.SameLine()
		if im.Button(">") {set_status("%d slice(s): next footage", nudge_selected_slices(1))}
		im.SameLine()
		if im.Button("Reroll") {set_status("%d slice(s) rerolled", nudge_selected_slices(0))}
		tip("New random footage for the selected slices (they get locked)")
		im.TextDisabled("Mouse wheel over a slice: next / previous footage")
	}
}
panel_inspector :: proc() {
	defer im.End()
	if !im.Begin("Inspector", &show_inspector) {
		return
	}
	defer { // always here, also with nothing selected: the randomize settings and the picture
		inspector_slices()
		im.SeparatorText("Picture")
		size_presets(&project.settings)
		im.ColorEdit3("background", &project.settings.bg)
		im.TextDisabled("or double-click the picture")
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
	scope := i32(inspector_scope)
	im.SetNextItemWidth(-90)
	if im.Combo("apply to", &scope, "selected clips\x00all slices of the clip\x00all clips\x00\x00") {
		inspector_scope = Apply_Scope(scope)
	}
	im.TextUnformatted(cstr(project.sources[info.source].path))
	im.Text("start %.2fs   length %.2fs   speed %.2fx", info.start, info.duration, info.speed)

	// edits apply to every selected clip of that kind
	if vi >= 0 {
		im.Separator()
		// only what you change goes to the other clips (their other values stay)
		c := project.clips[vi]
		ch_pos := im.DragFloat2("position", &c.pos, 1, 0, 0, "%.0f px")
		ch_scale := im.DragFloat("scale", &c.scale, 0.01, 0.01, 10, "%.2f")
		ch_rot := im.DragFloat("rotation", &c.rotation, 0.5, -360, 360, "%.1f deg")
		ch_fit := false
		im.SetNextItemWidth(-90)
		if im.BeginCombo("fit", FIT_NAMES[c.fit]) {
			for m in Fit_Mode {
				if im.Selectable(FIT_NAMES[m], m == c.fit) {c.fit = m; ch_fit = true}
			}
			im.EndCombo()
		}
		if im.Button("Reset transform") {
			c.pos, c.scale, c.rotation, c.fit = {}, 1, 0, .Fit
			ch_pos, ch_scale, ch_rot, ch_fit = true, true, true, true
		}
		if ch_pos || ch_scale || ch_rot || ch_fit {
			for &k in project.clips {
				if !inspector_hits(k, .Video) {continue}
				if ch_pos {k.pos = c.pos}
				if ch_scale {k.scale = c.scale}
				if ch_rot {k.rotation = c.rotation}
				if ch_fit {k.fit = c.fit}
			}
		}
	}	if ai >= 0 {
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
				if inspector_hits(k, .Audio) {
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
		im.ColorEdit3("background", &s.bg, {.NoInputs})
		im.DragInt("frame rate", &s.fps, 0.2, 1, 120)
		size_presets(s)
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

