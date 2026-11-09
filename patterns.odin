package main

import "core:fmt"
import "core:math"

import im "deps/odin-imgui"

// MIDI-like patterns: a small drum machine whose hits are the slicing points.
// Each lane (kick, snare, hat, ...) is a row of steps on the beat grid (project bpm,
// steps per beat set by the pattern). Every hit makes a cut at its time; what the
// cut does depends on the lane's target:
//   mark      only a slice mark: Randomize hands it a layer (the others are kept)
//   V1..V9    show that video layer from there
//   all       show all layers again
// Patterns are composed by hand here and used through commands: Apply loops one over
// the selected segment (else the whole project); Randomize can slice at one. Swing
// delays every second step. Marks can slice the real clips (Slice clips at cuts).

MAX_STEPS :: 64
MAX_LANES :: 8

Lane :: struct {
	name:   [12]u8,
	target: i8, // 0 = mark only, n > 0 = show video layer n, -1 = show all layers
	mute:   bool,
	steps:  [MAX_STEPS]u8, // 0 = off, 1 = hit
}

Pattern :: struct {
	name:       [24]u8,
	length:     i32, // steps before it loops
	div:        i32, // steps per beat (1, 2, 4, 8, 16)
	swing:      i32, // percent: every second step is delayed by this much of a step
	lane_count: i32,
	lanes:      [MAX_LANES]Lane,
}

// Fixed-size name buffers (no allocation, so a Pattern is plain data).
set_fixed :: proc(buf: []u8, s: string) {
	for &b in buf {b = 0}
	copy(buf[:len(buf) - 1], s)
}

get_fixed :: proc(buf: []u8) -> string {
	return string(cstring(raw_data(buf)))
}

// Blank: one empty lane to click steps into.
new_pattern :: proc(name: string) -> Pattern {
	pat := Pattern{length = 16, div = 4}
	set_fixed(pat.name[:], name)
	add_lane(&pat, "lane 1", 0)
	return pat
}

add_lane :: proc(pat: ^Pattern, name: string, target: i8) -> ^Lane {
	if pat.lane_count >= MAX_LANES {
		return nil
	}
	lane := &pat.lanes[pat.lane_count]
	lane^ = {}
	set_fixed(lane.name[:], name)
	lane.target = target
	pat.lane_count += 1
	return lane
}

remove_lane :: proc(pat: ^Pattern, i: int) {
	if i < 0 || i >= int(pat.lane_count) {return}
	for k in i ..< int(pat.lane_count) - 1 {
		pat.lanes[k] = pat.lanes[k + 1]
	}
	pat.lane_count -= 1
}

// ---------------------------------------------------------------- using a pattern

beat_origin :: proc(s: Settings) -> f64 {
	return math.mod(max(s.grid_offset, 0), 60 / f64(max(s.bpm, 1)))
}

Hit :: struct {
	time: f64,
	lane: int, // the lane that wins at this step (the first one that hits)
}

// When the pattern hits inside [t0, t1): looped from the first step at/after t0, with
// swing applied and muted lanes left out. The one source of slicing points: applying
// a pattern and the randomizer both use it.
pattern_hits :: proc(p: Project, pat: Pattern, t0, t1: f64) -> []Hit {
	s := p.settings
	step := 60 / f64(max(s.bpm, 1)) / f64(max(pat.div, 1))
	origin := beat_origin(s)
	length := int(clamp(pat.length, 1, MAX_STEPS))
	swing := f64(clamp(pat.swing, 0, 75)) / 100
	out := make([dynamic]Hit, context.temp_allocator)
	first := int(math.ceil((t0 - origin) / step - 1e-6))
	for n := 0; ; n += 1 {
		k := first + n
		t := origin + (f64(k) + (k % 2 != 0 ? swing : 0)) * step // swing delays the odd steps
		if t >= t1 - CUT_EPS {break}
		if t < t0 - CUT_EPS {continue}
		idx := n % length
		for li in 0 ..< int(pat.lane_count) {
			lane := pat.lanes[li]
			if !lane.mute && lane.steps[idx] != 0 {
				append(&out, Hit{t, li})
				break
			}
		}
	}
	return out[:]
}

// Slicing times for Randomize from a pattern's hits in [t0, t1): the hit times, and per
// slot the layer (track) of the hit's lane if it has one, else PIN_NONE.
pattern_slots :: proc(p: Project, pat: Pattern, t0, t1: f64, times: ^[dynamic]f64, pins: ^[dynamic]int) {
	layers := video_layers(p)
	for h in pattern_hits(p, pat, t0, t1) {
		target := pat.lanes[h.lane].target
		append(times, h.time)
		append(pins, target > 0 && int(target) <= len(layers) ? layers[target - 1] : PIN_NONE)
	}
}

// The same for every part (each with its own pattern) inside [t0, t1). The gaps
// between parts become PIN_SKIP slots.
parts_slots :: proc(p: Project, t0, t1: f64, times: ^[dynamic]f64, pins: ^[dynamic]int) {
	for part in p.parts {
		if part.pattern < 0 || int(part.pattern) >= len(p.patterns) || part.t1 <= t0 || part.t0 >= t1 {continue}
		a, b := max(part.t0, t0), min(part.t1, t1)
		n := len(times)
		pattern_slots(p, p.patterns[part.pattern], a, b, times, pins)
		if len(times) > n {
			append(times, b)
			append(pins, PIN_SKIP)
		}
	}
}

// Applies the pattern of every part inside its own range. Returns how many parts.
apply_parts :: proc() -> (n: int) {
	for part in project.parts {
		if part.pattern >= 0 && int(part.pattern) < len(project.patterns) {
			program_apply_pattern(&project, project.patterns[part.pattern], part.t0, part.t1, true)
			n += 1
		}
	}
	return
}

// Cuts the program at every hit of the pattern inside [t0, t1) and sets the layers
// the lanes target. replace: the cuts already in the range are removed first.
program_apply_pattern :: proc(p: ^Project, pat: Pattern, t0, t1: f64, replace: bool) {
	layers := video_layers(p^)
	if replace {
		#reverse for c, i in p.program {
			if c.time >= t0 - CUT_EPS && c.time < t1 - CUT_EPS {
				ordered_remove(&p.program, i)
			}
		}
	}
	for h in pattern_hits(p^, pat, t0, t1) {
		t, target := h.time, pat.lanes[h.lane].target
		if target > 0 && int(target) <= len(layers) {
			layer := layers[target - 1]
			i := cut_insert(p, t) // (indexing with the call inline would use the array before it grew)
			p.program[i].layer, p.program[i].fixed = layer, true
		} else if target == -1 {
			i := cut_insert(p, t)
			p.program[i].layer, p.program[i].fixed = -1, true
		} else { // a mark: only slices, so Randomize may give it a layer
			i := cut_insert(p, t)
			p.program[i].fixed = false
		}
	}
}

// Slices the real clips at every program cut (the selected clips if any are
// selected, else all). Returns how many clips were added.
slice_at_cuts :: proc(p: ^Project) -> int {
	before := len(p.clips)
	for cut in p.program {
		split_at(p, cut.time)
	}
	return len(p.clips) - before
}

cur_pattern :: proc() -> ^Pattern {
	n := len(project.patterns)
	if n == 0 {
		return nil
	}
	project.settings.pattern_sel = clamp(project.settings.pattern_sel, 0, i32(n - 1))
	return &project.patterns[project.settings.pattern_sel]
}

// Applies pattern `idx` (default: the current one) to the selected segment, else the whole project.
apply_pattern :: proc(idx := -1) {
	if idx >= 0 && idx < len(project.patterns) {
		project.settings.pattern_sel = i32(idx)
	}
	_, _, ranged := program_range()
	if idx < 0 && !ranged && len(project.parts) > 0 { // parts: each gets its own pattern
		n := apply_parts()
		clear_cut_sel()
		set_status("applied the patterns of %d parts", n)
		return
	}
	pat := cur_pattern()
	if pat == nil {
		set_status("no pattern: open the Patterns panel and add one")
		return
	}
	t0, t1 := 0.0, project_length(project)
	if a, b, ok := program_range(); ok {
		t0, t1 = a, b
	}
	program_apply_pattern(&project, pat^, t0, t1, true)
	clear_cut_sel()
	set_status("applied pattern %s", get_fixed(pat.name[:]))
}

step_pattern_sel :: proc(delta: int) {
	if n := len(project.patterns); n > 0 {
		project.settings.pattern_sel = i32((int(project.settings.pattern_sel) + delta + n) % n)
		set_status("pattern: %s", get_fixed(cur_pattern().name[:]))
	}
}

// ---------------------------------------------------------------- panel (composing)

show_patterns: bool

target_label :: proc(target: i8) -> string {
	switch {
	case target == 0:  return "mark"
	case target == -1: return "all"
	}
	return fmt.tprintf("V%d", target)
}

panel_patterns :: proc() {
	if !show_patterns {
		return
	}
	defer im.End()
	if !im.Begin("Patterns", &show_patterns) {
		return
	}
	if im.Button("New") {
		append(&project.patterns, new_pattern(fmt.tprintf("pattern %d", len(project.patterns) + 1)))
		project.settings.pattern_sel = i32(len(project.patterns) - 1)
	}
	pat := cur_pattern()
	if pat != nil {
		im.SameLine()
		if im.Button("Duplicate") {
			copy_ := pat^
			append(&project.patterns, copy_)
			project.settings.pattern_sel = i32(len(project.patterns) - 1)
			pat = cur_pattern()
		}
		im.SameLine()
		if im.Button("Delete") {
			gone := project.settings.pattern_sel
			ordered_remove(&project.patterns, int(gone))
			for &part in project.parts { // parts keep pointing at the right pattern
				if part.pattern == gone {part.pattern = -1} else if part.pattern > gone {part.pattern -= 1}
			}
			pat = cur_pattern()
		}
	}
	if pat == nil {
		im.TextDisabled("a pattern = hits on the beat grid that become cuts. New to start")
		return
	}

	// which pattern, its name
	im.SetNextItemWidth(160)
	if im.BeginCombo("##pattern", cstr(get_fixed(pat.name[:]))) {
		for &q, i in project.patterns {
			if im.Selectable(cstr(fmt.tprintf("%s###pat%d", get_fixed(q.name[:]), i)), i == int(project.settings.pattern_sel)) {
				project.settings.pattern_sel = i32(i)
			}
		}
		im.EndCombo()
	}
	im.SameLine()
	im.SetNextItemWidth(160)
	im.InputText("name", cstring(&pat.name[0]), len(pat.name))

	// timing
	im.SetNextItemWidth(80)
	im.InputInt("steps", &pat.length)
	pat.length = clamp(pat.length, 1, MAX_STEPS)
	im.SameLine()
	div := i32(0)
	for d, i in GRID_DIVS {
		if d == pat.div {div = i32(i)}
	}
	im.SetNextItemWidth(60)
	if im.Combo("per beat", &div, "1\x002\x004\x008\x0016\x00\x00") {
		pat.div = GRID_DIVS[div]
	}
	im.SameLine()
	im.SetNextItemWidth(120)
	im.SliderInt("swing", &pat.swing, 0, 75, "%d %%")

	// lanes: name, what a hit does, mute
	im.Separator()
	remove := -1
	for li in 0 ..< int(pat.lane_count) {
		lane := &pat.lanes[li]
		id := fmt.tprintf("##l%d", li)
		im.SetNextItemWidth(80)
		im.InputText(cstr(strings_cat(id, "n")), cstring(&lane.name[0]), len(lane.name))
		im.SameLine()
		im.SetNextItemWidth(70)
		if im.BeginCombo(cstr(strings_cat(id, "t")), cstr(target_label(lane.target))) {
			if im.Selectable("mark") {lane.target = 0}
			if im.Selectable("all") {lane.target = -1}
			for n in 1 ..= len(tracks_video) {
				if n > 9 {break}
				if im.Selectable(cstr(fmt.tprintf("V%d", n))) {lane.target = i8(n)}
			}
			im.EndCombo()
		}
		im.SameLine()
		im.Checkbox(cstr(strings_cat(id, "m")), &lane.mute)
		im.SameLine()
		if im.SmallButton(cstr(strings_cat("clear", id))) {lane.steps = {}}
		im.SameLine()
		if im.SmallButton(cstr(strings_cat("x", id))) {remove = li}
	}
	if remove >= 0 {
		remove_lane(pat, remove)
	}
	if pat.lane_count < MAX_LANES && im.SmallButton("+ lane") {
		add_lane(pat, fmt.tprintf("lane %d", pat.lane_count + 1), 0)
	}

	// the steps: one row per lane, one block of rows per 16 steps
	im.Separator()
	CELL :: f32(22)
	step_s := 60 / f64(max(project.settings.bpm, 1)) / f64(max(pat.div, 1))
	cur_step := -1
	if playing {
		cur_step = int(math.floor((playhead - beat_origin(project.settings)) / step_s)) % int(pat.length)
		if cur_step < 0 {cur_step += int(pat.length)}
	}
	dl := im.GetWindowDrawList()
	for bar := 0; bar < int(pat.length); bar += 16 {
		for li in 0 ..< int(pat.lane_count) {
			lane := &pat.lanes[li]
			im.TextUnformatted(cstr(get_fixed(lane.name[:])))
			im.SameLine(80)
			for j in bar ..< min(bar + 16, int(pat.length)) {
				if j > bar {im.SameLine(0, j % int(pat.div) == 0 ? 8 : 2)}
				p := im.GetCursorScreenPos()
				if im.InvisibleButton(cstr(fmt.tprintf("##s%d_%d", li, j)), {CELL, CELL}) {
					lane.steps[j] = lane.steps[j] != 0 ? 0 : 1
				}
				on := lane.steps[j] != 0
				r, g, b: f32
				im.ColorConvertHSVtoRGB(math.mod(f32(li) * 0.13 + 0.05, 1), 0.65, lane.mute ? 0.4 : 0.9, &r, &g, &b)
				col: u32 = on ? im.ColorConvertFloat4ToU32({r, g, b, 1}) : (j / int(pat.div) % 2 == 0 ? 0xFF3A3A3A : 0xFF303030)
				im.DrawList_AddRectFilled(dl, p, {p.x + CELL, p.y + CELL}, col, 3)
				if j == cur_step {
					im.DrawList_AddRect(dl, p, {p.x + CELL, p.y + CELL}, 0xFFFFFFFF, 3)
				}
			}
		}
		im.Spacing()
	}

	im.Separator()
	if im.Button(labeled(.Apply_Pattern, "Apply")) {
		do_action(.Apply_Pattern)
	}
	im.SameLine()
	if im.Button("Slice clips at cuts") {
		do_action(.Slice_At_Cuts)
	}
	im.SameLine()
	im.TextDisabled(cstr(sel_cut >= 0 ? "to the selected range" : "to everything"))
	im.TextDisabled(cstr(fmt.tprintf("%.1f bpm.  mark = slice only, V1.. = also show that layer", project.settings.bpm)))
}

strings_cat :: proc(a, b: string) -> string {
	return fmt.tprintf("%s%s", a, b)
}
