package main

import "core:fmt"
import "core:math"
import "core:math/rand"
import "core:slice"

// Randomize. The slicing (the program's cuts, a pattern's hits, the grid) gives SLOTS:
// the intervals between slicing times, at their real positions on a NEW layer on top.
// Every slot is filled with a slice of footage from one of the video clips, so the
// rhythm is kept and only the footage is distributed. Which clip: random, and the
// clips take equal turns (a pattern lane or a cut that has a layer pins its slots to
// that layer). Which footage (Rand_Footage):
//   same time  what plays at the slot's own time: a cut-away between the clips
//   in order   the clip's next piece, so every clip plays forward
//   any piece  a random piece of the clip
// With in order / any piece a piece is used once. use all clips: the slicing goes on
// (the rhythm loops) until every piece is used; without it only the original span is
// filled and the rest of the footage is not seen. Neighbouring slots filled with
// consecutive footage of the same clip are merged into one clip.

PIN_NONE :: -1 // a slot any clip may fill
PIN_SKIP :: -2 // a slot to leave empty (the gap between parts)

Rearrange_Result :: struct {
	clips:  int, // clips created on the new layer
	cells:  int, // slots filled
	unused: int, // pieces left out (in order / any piece)
	empty:  int, // slots no clip could fill
	track:  int, // the new layer
	bounds: []f64, // where each filled slot starts (what the program should mark)
}

// Video clips to rearrange: the selected clips, else the clips on the selected
// layers, else every video clip (hidden and locked layers are left out).
rearrange_candidates :: proc(p: Project) -> []int {
	out := make([dynamic]int, context.temp_allocator)
	clips_selected := false
	for c in p.clips {
		clips_selected ||= c.selected && c.kind == .Video
	}
	layers := selected_tracks(p)
	for c, i in p.clips {
		if c.kind != .Video || track_has(p, c.track, .Hidden) || track_has(p, c.track, .Locked) {
			continue
		}
		switch {
		case clips_selected:     if c.selected {append(&out, i)}
		case len(layers) > 0:    if slice.contains(layers, c.track) {append(&out, i)}
		case:                    append(&out, i)
		}
	}
	return out[:]
}

// Time span covered by the candidate clips.
candidate_span :: proc(p: Project, cands: []int) -> (lo, hi: f64) {
	lo, hi = max(f64), 0
	for ci in cands {
		lo, hi = min(lo, p.clips[ci].start), max(hi, clip_end(p.clips[ci]))
	}
	return
}

// times: sorted slicing times (slot boundaries), long enough for what is asked: past
// `hi` only when use_all is on. pins[i]: what slot i (times[i]..times[i+1]) is limited
// to: a track number, PIN_NONE or PIN_SKIP. lo..hi is the span to fill.
rearrange :: proc(p: ^Project, o: Rand_Options, cands: []int, times: []f64, pins: []int, lo, hi: f64) -> (res: Rearrange_Result) {
	if len(cands) == 0 || len(times) < 2 {
		return
	}
	Piece :: struct {
		src_in, dur: f64,
	}
	Bag :: struct { // the pieces of one clip with one length, in time order
		items: [dynamic]Piece,
		head:  int, // pieces before head are used
	}
	class_of :: proc(dur: f64) -> i64 {return i64(math.round(dur * 10000))}
	same_time := o.footage == .Same_Time

	// in order / any piece: the pieces of every clip, sorted into bags by length
	classes := make([dynamic]i64, context.temp_allocator)
	bags: [][]Bag
	total := 0
	if !same_time {
		for i in 0 ..< len(times) - 1 {
			if k := class_of(times[i + 1] - times[i]); !slice.contains(classes[:], k) {append(&classes, k)}
		}
		bags = make([][]Bag, len(cands), context.temp_allocator)
		for &row in bags {
			row = make([]Bag, len(classes), context.temp_allocator)
			for &b in row {b.items = make([dynamic]Piece, context.temp_allocator)}
		}
		for ci, k in cands {
			c := p.clips[ci]
			for i in 0 ..< len(times) - 1 {
				a, b := times[i], times[i + 1]
				if a >= c.start - 1e-6 && b <= clip_end(c) + 1e-6 && b - a > 1e-6 {
					idx, _ := slice.linear_search(classes[:], class_of(b - a))
					append(&bags[k][idx].items, Piece{c.in_point + (a - c.start) * c.speed, b - a})
					total += 1
				}
			}
		}
		if total == 0 {
			return
		}
	}

	// fill the slots in time order
	Entry :: struct {
		start, dur, src_in: f64,
		clip:               int,
	}
	entries := make([dynamic]Entry, context.temp_allocator)
	used, prev, run := 0, -1, 0
	for i in 0 ..< len(times) - 1 {
		a, b := times[i], times[i + 1]
		if a < lo - 1e-6 {continue}
		if (same_time || !o.use_all) && b > hi + 1e-6 {break}
		pin := i < len(pins) ? pins[i] : PIN_NONE
		if pin == PIN_SKIP {continue}
		if !same_time && used == total {break}
		cls := -1
		if !same_time {
			cls, _ = slice.linear_search(classes[:], class_of(b - a))
		}

		pool := make([dynamic]int, context.temp_allocator) // clips that can fill this slot
		for k in 0 ..< len(cands) {
			c := p.clips[cands[k]]
			if pin >= 0 && c.track != pin {continue}
			if same_time {
				if a >= c.start - 1e-6 && b <= clip_end(c) + 1e-6 {append(&pool, k)}
			} else if bags[k][cls].head < len(bags[k][cls].items) {
				append(&pool, k)
			}
		}
		if len(pool) == 0 {
			res.empty += 1
			continue
		}
		if o.max_run > 0 && run >= int(o.max_run) && len(pool) > 1 {
			if j, ok := slice.linear_search(pool[:], prev); ok {unordered_remove(&pool, j)}
		}
		k := pool[rand.int_max(len(pool))] // equal turns

		src_in: f64
		if same_time {
			c := p.clips[cands[k]]
			src_in = c.in_point + (a - c.start) * c.speed
		} else {
			bag := &bags[k][cls]
			if o.footage == .Any_Piece {
				j := bag.head + rand.int_max(len(bag.items) - bag.head)
				bag.items[j], bag.items[bag.head] = bag.items[bag.head], bag.items[j]
			}
			src_in = bag.items[bag.head].src_in
			bag.head += 1
		}
		used += 1
		append(&entries, Entry{a, b - a, src_in, k})
		run = k == prev ? run + 1 : 1
		prev = k
	}
	if len(entries) == 0 {
		return
	}

	// write the clips on a new layer; consecutive footage in neighbouring slots becomes one clip
	track := p.track_count
	p.track_count += 1
	sync_tracks(p)
	bounds := make([dynamic]f64, context.temp_allocator)
	for i := 0; i < len(entries); {
		src := p.clips[cands[entries[i].clip]]
		dur := entries[i].dur
		j := i + 1
		for j < len(entries) && entries[j].clip == entries[i].clip && abs(entries[j].start - (entries[i].start + dur)) < 1e-6 &&
		abs(entries[j].src_in - (entries[i].src_in + dur * src.speed)) < 1e-6 {
			dur += entries[j].dur
			j += 1
		}
		for q in i ..< j {append(&bounds, entries[q].start)}
		out := src
		out.track = track
		out.start = entries[i].start
		out.in_point = entries[i].src_in
		out.duration = dur
		out.group, out.slice, out.locked = 0, true, false
		out.selected = false
		append(&p.clips, out)
		res.clips += 1
		i = j
	}
	res.cells, res.unused, res.track, res.bounds = len(entries), same_time ? 0 : total - len(entries), track, bounds[:]
	return
}

// Takes the locked slices out of the project so Randomize can keep them, and drops the
// rest of the layers they were on (the old result). Layers left empty are removed.
take_locked :: proc(p: ^Project) -> []Clip {
	kept := make([dynamic]Clip, context.temp_allocator)
	layers := make([dynamic]int, context.temp_allocator)
	for c in p.clips {
		if c.slice && c.locked && c.kind == .Video && !slice.contains(layers[:], c.track) {append(&layers, c.track)}
	}
	#reverse for c, i in p.clips {
		if c.slice && c.kind == .Video && slice.contains(layers[:], c.track) {
			if c.locked {inject_at(&kept, 0, c)}
			ordered_remove(&p.clips, i)
		}
	}
	slice.sort(layers[:])
	#reverse for t in layers {
		used := false
		for c in p.clips {used ||= c.track == t}
		if !used {remove_track(p, t)}
	}
	return kept[:]
}

// Switches the footage of one slice by one step (dir = +1 next, -1 previous, 0 = reroll:
// a random one). Which
// footage comes next depends on the Randomize mode:
//   same time  the next clip that covers the slice's time
//   in order   the next piece of the same clip
//   any piece  a random piece of a random clip
// The slice is locked afterwards: you picked it. Returns false when nothing could change.
slice_nudge :: proc(p: ^Project, ci: int, dir: int, mode: Rand_Footage) -> bool {
	c := &p.clips[ci]
	if c.kind != .Video || !c.slice {return false}
	switch mode {
	case .Same_Time:
		list := make([dynamic]int, context.temp_allocator)
		cur := -1
		for o, i in p.clips {
			if o.kind != .Video || o.slice || c.start < o.start - 1e-6 || clip_end(c^) > clip_end(o) + 1e-6 {continue}
			append(&list, i)
			if o.source == c.source && abs(o.in_point + (c.start - o.start) * o.speed - c.in_point) < 1e-3 {cur = len(list) - 1}
		}
		n := len(list)
		if n == 0 || (n == 1 && cur == 0) {return false}
		next := cur < 0 ? (dir > 0 ? 0 : n - 1) : (cur + dir + n) % n
		if dir == 0 { // reroll: any clip but this one
			next = rand.int_max(n)
			if n > 1 && next == cur {next = (next + 1) % n}
		}
		o := p.clips[list[next]]
		c.source, c.speed, c.pos, c.scale, c.rotation = o.source, o.speed, o.pos, o.scale, o.rotation
		c.in_point = o.in_point + (c.start - o.start) * o.speed
	case .In_Order:
		span := c.duration * c.speed
		room := max(p.sources[c.source].duration - span, 0)
		in_point := clamp(c.in_point + f64(dir) * span, 0, room)
		if dir == 0 { // reroll: any piece of this clip's file
			in_point = f64(rand.int_max(max(int(math.floor(room / span)), 0) + 1)) * span
		}
		if abs(in_point - c.in_point) < 1e-6 {return false}
		c.in_point = in_point
	case .Any_Piece:
		list := make([dynamic]int, context.temp_allocator)
		for o, i in p.clips {
			if o.kind == .Video && !o.slice && o.duration >= c.duration - 1e-6 {append(&list, i)}
		}
		if len(list) == 0 {return false}
		o := p.clips[list[rand.int_max(len(list))]]
		pieces := max(int(math.floor(o.duration / c.duration + 1e-6)), 1)
		c.source, c.speed, c.pos, c.scale, c.rotation = o.source, o.speed, o.pos, o.scale, o.rotation
		c.in_point = o.in_point + f64(rand.int_max(pieces)) * c.duration * o.speed
	}
	c.locked = true
	return true
}

// Removes clips of one kind. Scope: the selected clips, else the clips on the selected
// layers, else everything of that kind; except that audio with nothing selected is
// only the audio that belongs to videos (linked to a video clip), which leaves
// standalone music alone. Locked layers are untouched. Returns how many.
remove_clips :: proc(p: ^Project, kind: Clip_Kind) -> (removed: int) {
	any_clip := false
	for c in p.clips {
		any_clip ||= c.selected
	}
	layers := selected_tracks(p^)
	with_video := make(map[int]bool, context.temp_allocator) // groups that have a video clip
	for c in p.clips {
		if c.kind == .Video && c.group != 0 {with_video[c.group] = true}
	}
	#reverse for c, i in p.clips {
		if c.kind != kind || track_has(p^, c.track, .Locked) {continue}
		hit: bool
		switch {
		case any_clip:           hit = c.selected
		case len(layers) > 0:    hit = slice.contains(layers, c.track)
		case kind == .Audio:     hit = c.group != 0 && with_video[c.group]
		case:                    hit = true
		}
		if hit {
			ordered_remove(&p.clips, i)
			removed += 1
		}
	}
	return
}

remove_audio :: proc(p: ^Project) -> int {
	return remove_clips(p, .Audio)
}

// Removes whole layers (with their clips): the video layers (any layer with video)
// or the audio layers (layers with only audio). Of the selected layers if any are
// selected, else all of them. Locked layers stay. Returns how many.
remove_layers_of_kind :: proc(p: ^Project, kind: Clip_Kind) -> (removed: int) {
	has_v := make([]bool, p.track_count, context.temp_allocator)
	has_a := make([]bool, p.track_count, context.temp_allocator)
	for c in p.clips {
		if c.track < 0 || c.track >= p.track_count {continue}
		if c.kind == .Video {has_v[c.track] = true} else {has_a[c.track] = true}
	}
	layers := selected_tracks(p^)
	targets := make([dynamic]int, context.temp_allocator)
	for t in 0 ..< p.track_count {
		is_kind := kind == .Video ? has_v[t] : (has_a[t] && !has_v[t])
		if is_kind && !track_has(p^, t, .Locked) && (len(layers) == 0 || slice.contains(layers, t)) {
			append(&targets, t)
		}
	}
	#reverse for t in targets { // from the top, so the indices still to do do not shift
		remove_track(p, t)
		removed += 1
	}
	return
}

// Randomize: fill the slots of a rhythm with slices of footage on a new layer (see
// rearrange.odin). The slicing comes from Rand_Options.slice: the program's cuts, the
// pattern (each part's own pattern if the project has parts), or the grid. A selected
// program range limits it to that range.
run_randomize :: proc() {
	s := project.settings
	step, _ := grid_step(s)
	spacing, origin := step * f64(max(s.cut_every, 1)), grid_origin(s)
	kept := take_locked(&project) // locked slices stay; the rest of their layer is the old result
	cands := rearrange_candidates(project)
	if len(cands) == 0 {
		if len(kept) > 0 {put_locked(kept, -1)}
		set_status("no video clips to randomize")
		return
	}
	lo, hi := candidate_span(project, cands)
	t0, t1, ranged := program_range()
	if ranged {lo, hi = t0, t1}
	total := 0.0
	for ci in cands {total += project.clips[ci].duration}
	use_all := s.rand.use_all && s.rand.footage != .Same_Time
	// the slicing times; with "use all" they run on (the rhythm loops) until the footage would be used up
	horizon := use_all ? lo + (hi - lo) + total : hi

	times := make([dynamic]f64, context.temp_allocator)
	pins := make([dynamic]int, context.temp_allocator)
	switch s.rand.slice {
	case .Pattern:
		if len(project.parts) > 0 {
			parts_slots(project, lo, horizon, &times, &pins)
		} else {
			pat: ^Pattern
			if i := int(s.rand.pattern); i >= 0 && i < len(project.patterns) {
				pat = &project.patterns[i]
			} else {
				pat = cur_pattern()
			}
			if pat != nil {pattern_slots(project, pat^, lo, horizon, &times, &pins)}
		}
	case .Cuts:
		for c in project.program {
			if c.time >= lo - CUT_EPS && c.time <= hi + CUT_EPS {
				append(&times, c.time)
				append(&pins, c.fixed && c.layer >= 0 ? c.layer : PIN_NONE) // a layer a pattern lane or you set stays
			}
		}
		if n := len(times); n >= 2 && use_all {
			period := times[n - 1] - times[0]
			for k := 1; times[0] + f64(k) * period < horizon; k += 1 { // loop the cuts
				for i in 1 ..< n {
					append(&times, times[i] + f64(k) * period)
					append(&pins, pins[i])
				}
			}
		}
	case .Grid:
	}
	if len(times) < 2 { // no rhythm to use: the grid
		clear(&times)
		clear(&pins)
		for k := int(math.ceil((lo - origin) / spacing - 1e-6)); origin + f64(k) * spacing <= horizon + spacing; k += 1 {
			append(&times, origin + f64(k) * spacing)
		}
	}

	// slots under a locked slice are not filled
	for len(pins) < len(times) - 1 {append(&pins, PIN_NONE)}
	for i in 0 ..< len(times) - 1 {
		for k in kept {
			if times[i] < clip_end(k) - 1e-6 && times[i + 1] > k.start + 1e-6 {pins[i] = PIN_SKIP}
		}
	}

	res := rearrange(&project, s.rand, cands, times[:], pins[:], lo, hi)
	put_locked(kept, res.cells > 0 ? res.track : -1)
	if res.cells == 0 && len(kept) == 0 {
		set_status("nothing to randomize: the clips do not cover a slot")
		return
	}
	// the old cuts described the source clips, not this layer: mark its slots instead
	end := hi
	if n := len(res.bounds); n > 0 {end = max(end, res.bounds[n - 1] + 2 * CUT_EPS)}
	if ranged {
		#reverse for c, i in project.program {
			if c.time >= lo - CUT_EPS && c.time < end {cut_remove(&project, i)}
		}
	} else {
		clear(&project.program)
	}
	for t in res.bounds {
		i := cut_insert(&project, t)
		project.program[i].layer, project.program[i].fixed = -1, false // -1: the top layer shows, and that is the new one
	}
	for k in kept { // a cut where each locked slice starts and ends
		for t in ([2]f64{k.start, clip_end(k)}) {
			i := cut_insert(&project, t)
			project.program[i].layer, project.program[i].fixed = -1, false
		}
	}
	clear_cut_sel()
	set_status("randomized: %d slices in %d clips on a new layer%s%s", res.cells, res.clips, len(kept) > 0 ? fmt.tprintf(", %d locked kept", len(kept)) : "", res.empty > 0 ? fmt.tprintf(" (%d empty slots)", res.empty) : "")
}

// Puts locked slices back on layer `track` (a new layer when track < 0). Returns the layer.
put_locked :: proc(kept: []Clip, track: int) -> int {
	track := track
	if len(kept) == 0 {return track}
	if track < 0 {
		track = project.track_count
		project.track_count += 1
		sync_tracks(&project)
	}
	for c in kept {
		c := c
		c.track = track
		append(&project.clips, c)
	}
	return track
}
