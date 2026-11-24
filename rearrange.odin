package main

import "core:fmt"
import "core:math"
import "core:math/rand"
import "core:slice"
import "core:strings"

import im "deps/odin-imgui"

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
PIN_LOCKED_BASE :: -3 // a slot under a locked slice: PIN_LOCKED_BASE - (index in `kept`). Left empty, but its footage is what the next slot must not repeat

Rearrange_Result :: struct {
	clips:  int, // clips created on the new layer
	cells:  int, // slots filled
	unused: int, // pieces left out (in order / any piece)
	empty:  int, // slots no clip could fill
	jumped: int, // same-time slots that took footage of another time, so the same source did not repeat
	pinned: int, // slots limited to a layer by a pattern lane or a cut
	pin_overridden: int, // pinned slots that gave way to the max-in-a-row limit
	track:  int, // the new layer
	end:    f64, // where the last filled slot ends
	last:   int, // the candidate clip (index in the project) the last slot came from
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

// How often each clip Randomize can use is picked: one slider per candidate clip (1 = normal, 0.2 = five times
// less often than a clip at 1). The candidates are the selected clips, else the selected layers' clips, else all.
odds_list :: proc() {
	cands := rearrange_candidates(project)
	if len(cands) == 0 {return}
	if !im.TreeNode("Clip odds") {return}
	defer im.TreePop()
	if im.IsItemHovered() {im.SetTooltip("how often Randomize picks each clip next to the others (every source also gets equal turns)")}
	for ci, n in cands {
		if n >= 16 {
			im.TextDisabled(cstr(fmt.tprintf("and %d more", len(cands) - n)))
			break
		}
		c := &project.clips[ci]
		name := project.sources[c.source].path
		if i := strings.last_index_any(name, "/\\"); i >= 0 {name = name[i + 1:]}
		odds := f32(clip_odds(c^))
		im.SetNextItemWidth(120)
		if im.SliderFloat(cstr(fmt.tprintf("%s  L%d %.1fs###odds%d", name, c.track + 1, c.start, ci)), &odds, 0.05, 5, "%.2fx", {.Logarithmic}) {
			c.odds = abs(odds - 1) < 0.005 ? 0 : odds
		}
	}
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
rearrange :: proc(p: ^Project, o: Rand_Options, cands: []int, times: []f64, pins: []int, modes: []Lane_Mode, kept: []Clip, lo, hi: f64) -> (res: Rearrange_Result) {
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
		freeze:             bool,
		black:              bool,
	}
	entries := make([dynamic]Entry, context.temp_allocator)
	// What the last slot played, so the next one does not repeat it (see Prev).
	Prev :: struct {
		p:           ^Project,
		cands:       []int,
		source:      int, // -1 = nothing yet
		clip:        int, // candidate index; -1 = a locked slice or nothing
		known:       bool, // in_, end are the footage the last slot played (source seconds)
		in_, end:    f64,
		next_locked: int, // source of a locked slice right after this slot (to avoid), else -1
		limit:       bool, // the max-in-a-row limit is reached
	}
	// would candidate k, starting at source time x, repeat what the last slot played?
	continues :: proc(c: ^Prev, x: f64) -> bool {
		return c.known && (abs(x - c.in_) < 1e-3 || abs(x - c.end) < 1e-3) // the same footage again, or on from where it ended
	}
	repeats :: proc(c: ^Prev, k: int, x: f64) -> bool {
		return c.limit && c.p.clips[c.cands[k]].source == c.source && (k == c.clip || continues(c, x))
	}
	// the preferences, strongest first: not the source of the locked slice that follows, not the last source,
	// not footage that carries on from the last slot, not the last clip. A preference is skipped when it would leave nothing.
	avoid :: proc(c: ^Prev, tier, k: int, x: f64) -> bool {
		src := c.p.clips[c.cands[k]].source
		switch tier {
		case 0: return c.next_locked >= 0 && src == c.next_locked
		case 1: return c.limit && src == c.source
		case 2: return c.limit && src == c.source && continues(c, x)
		case 3: return c.limit && k == c.clip
		}
		return false
	}
	NO_FOOTAGE :: -1e18 // "any piece": which piece comes is not known yet

	used, run := 0, 0
	pv := Prev{p = p, cands = cands, source = -1, clip = -1}
	for i in 0 ..< len(times) - 1 {
		a, b := times[i], times[i + 1]
		if a < lo - 1e-6 {continue}
		if (same_time || !o.use_all) && b > hi + 1e-6 {break}
		pin := i < len(pins) ? pins[i] : PIN_NONE
		if pin == PIN_SKIP {continue}
		if pin <= PIN_LOCKED_BASE { // under a locked slice: nothing to fill, but it is the neighbour of the slots around it
			if ki := PIN_LOCKED_BASE - pin; ki < len(kept) {
				kc := kept[ki]
				if kc.source != pv.source {run = 1} else if pv.clip >= 0 {run += 1}
				pv.source, pv.clip, pv.known = kc.source, -1, true
				pv.in_, pv.end = kc.in_point, kc.in_point + kc.duration * kc.speed
			}
			continue
		}
		mode := i < len(modes) ? modes[i] : Lane_Mode.Normal
		if mode == .Repeat && len(entries) > 0 { // plays the footage of the slot before it again; nothing new is used
			last := entries[len(entries) - 1]
			append(&entries, Entry{a, b - a, last.src_in, last.clip, last.freeze, last.black})
			continue
		}
		if mode == .Black { // no clip: a black placeholder. Nothing is used, and the next slot has no neighbour to avoid
			append(&entries, Entry{a, b - a, 0, len(entries) > 0 ? entries[len(entries) - 1].clip : 0, false, true}) // shaped like the clip before it
			pv.source, pv.clip, pv.known = -1, -1, false
			run = 0
			continue
		}
		if !same_time && used == total {break}
		cls := -1
		if !same_time {
			cls, _ = slice.linear_search(classes[:], class_of(b - a))
		}

		pv.limit = o.max_run > 0 && run >= int(o.max_run)
		pv.next_locked = -1
		if i + 1 < len(pins) && pins[i + 1] <= PIN_LOCKED_BASE && o.max_run == 1 {
			if ki := PIN_LOCKED_BASE - pins[i + 1]; ki < len(kept) {pv.next_locked = kept[ki].source}
		}
		pool := make([dynamic]int, context.temp_allocator) // clips that can fill this slot
		weight := make([dynamic]f64, context.temp_allocator) // how likely each is: equal turns, or by how much footage the clip has left (spread)
		starts := make([dynamic]f64, context.temp_allocator) // where in its source each would start
		// A pinned slot (a lane with a layer) is limited to that layer; if that would put the same footage twice
		// in a row beyond the limit, the pin gives way (attempt 1) so the limit holds.
		for attempt in 0 ..< 2 {
			use_pin := attempt == 0 ? pin : PIN_NONE
			clear(&pool)
			clear(&weight)
			clear(&starts)
			for k in 0 ..< len(cands) {
				c := p.clips[cands[k]]
				if use_pin >= 0 && c.track != use_pin {continue}
				if same_time {
					if a >= c.start - 1e-6 && b <= clip_end(c) + 1e-6 {
						append(&pool, k)
						append(&weight, clip_odds(c))
						append(&starts, c.in_point + (a - c.start) * c.speed)
					}
				} else if bag := bags[k][cls]; bag.head < len(bag.items) {
					append(&pool, k)
					append(&weight, clip_odds(c) * (o.spread ? f64(len(bag.items) - bag.head) : 1))
					append(&starts, o.footage == .Any_Piece ? NO_FOOTAGE : bag.items[bag.head].src_in)
				}
			}
			for tier in 0 ..< 4 {
				others := 0
				for k, q in pool {
					if !avoid(&pv, tier, k, starts[q]) {others += 1}
				}
				if others == 0 || others == len(pool) {continue}
				for q := 0; q < len(pool); {
					if avoid(&pv, tier, pool[q], starts[q]) {
						unordered_remove(&pool, q)
						unordered_remove(&weight, q)
						unordered_remove(&starts, q)
					} else {
						q += 1
					}
				}
			}
			stuck := pv.limit && len(pool) > 0
			for k, q in pool {
				stuck &&= repeats(&pv, k, starts[q])
			}
			if !stuck || pin < 0 || attempt == 1 {
				if attempt == 1 && !stuck {res.pin_overridden += 1}
				break
			}
		}
		// Same time can only use what plays at that moment: with the clips side by side, or stacked copies of one
		// source, every choice repeats the last slot (one shot with no cut). The limit wins: take footage of
		// another time instead, from another source if there is one.
		jump := false
		if same_time && len(pool) > 0 {
			all_repeat := pv.limit
			for k, q in pool {
				all_repeat &&= repeats(&pv, k, starts[q])
			}
			if all_repeat {
				fb := make([dynamic]int, context.temp_allocator)
				for pass in 0 ..< 2 {
					for k in 0 ..< len(cands) {
						c := p.clips[cands[k]]
						if c.duration < b - a - 1e-6 {continue}
						if pass == 0 && (c.source == pv.source || (pv.next_locked >= 0 && c.source == pv.next_locked)) {continue}
						append(&fb, k)
					}
					if len(fb) > 0 {break}
				}
				if len(fb) > 0 {
					clear(&pool)
					clear(&weight)
					clear(&starts)
					for k in fb {
						append(&pool, k)
						append(&weight, clip_odds(p.clips[cands[k]]))
						append(&starts, NO_FOOTAGE)
					}
					jump = true
					res.jumped += 1
				}
			}
		}
		if len(pool) == 0 {
			res.empty += 1
			continue
		}
		if pin >= 0 {res.pinned += 1}
		// Every source takes equal turns, however many clips it has been split into (else the source with the most
		// pieces would fill most of the slots); a clip's odds then say how often it is picked within that.
		for q in 0 ..< len(pool) {
			same_src := 0
			for k2 in pool {
				if p.clips[cands[k2]].source == p.clips[cands[pool[q]]].source {same_src += 1}
			}
			weight[q] /= f64(same_src)
		}
		// Equal turns make the short clips run out early, so the later slots only have the long ones. Picking by
		// how much footage a clip has left makes every clip play at the same rate over the whole length (spread).
		sum := 0.0
		for w in weight {sum += w}
		pick := rand.float64() * sum
		pi := len(pool) - 1
		for w, q in weight {
			pick -= w
			if pick < 0 {
				pi = q
				break
			}
		}
		k := pool[pi]

		src_in: f64
		if same_time {
			c := p.clips[cands[k]]
			src_in = c.in_point + (a - c.start) * c.speed
			if jump { // somewhere in the clip where the slot fits, not where the last slot left off
				for _ in 0 ..< 8 {
					src_in = c.in_point + rand.float64() * (c.duration - (b - a)) * c.speed
					if !(c.source == pv.source && continues(&pv, src_in)) {break}
				}
			}
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
		append(&entries, Entry{a, b - a, src_in, k, mode == .Freeze, false})
		src_id := p.clips[cands[k]].source
		run = src_id == pv.source ? run + 1 : 1
		pv.source, pv.clip, pv.known = src_id, k, true
		pv.in_, pv.end = src_in, src_in + (b - a) * p.clips[cands[k]].speed
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
		for j < len(entries) && !entries[i].freeze && !entries[j].freeze && !entries[i].black && !entries[j].black && entries[j].clip == entries[i].clip && abs(entries[j].start - (entries[i].start + dur)) < 1e-6 &&
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
		out.group, out.slice, out.locked, out.odds = 0, true, false, 0
		out.freeze = entries[i].freeze
		out.black = entries[i].black // black, in the shape (fit, scale, offset) of the clip it was copied from
		if out.black {out.in_point = 0}
		out.selected = false
		append(&p.clips, out)
		res.clips += 1
		i = j
	}
	last := entries[len(entries) - 1]
	res.end, res.last = last.start + last.dur, cands[last.clip]
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
// The slice is not locked: lock it (k) to keep it through Randomize. Returns false when nothing could change.
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
	modes := make([dynamic]Lane_Mode, context.temp_allocator) // what each slot's hit does (a lane's mode); parallel to pins
	switch s.rand.slice {
	case .Pattern:
		if len(project.parts) > 0 {
			parts_slots(project, lo, horizon, &times, &pins, &modes)
		} else {
			pat: ^Pattern
			if i := int(s.rand.pattern); i >= 0 && i < len(project.patterns) {
				pat = &project.patterns[i]
			} else {
				pat = cur_pattern()
			}
			if pat != nil {pattern_slots(project, pat^, lo, horizon, &times, &pins, &modes)}
		}
	case .Cuts:
		for c in project.program {
			if c.time >= lo - CUT_EPS && c.time <= hi + CUT_EPS {
				append(&times, c.time)
				append(&pins, c.fixed && c.layer >= 0 ? c.layer : PIN_NONE) // a layer a pattern lane or you set stays
				append(&modes, Lane_Mode.Normal)
			}
		}
		if n := len(times); n >= 2 && use_all {
			period := times[n - 1] - times[0]
			for k := 1; times[0] + f64(k) * period < horizon; k += 1 { // loop the cuts
				for i in 1 ..< n {
					append(&times, times[i] + f64(k) * period)
					append(&pins, pins[i])
					append(&modes, modes[i])
				}
			}
		}
	case .Grid:
	}
	if len(times) < 2 { // no rhythm to use: the grid
		clear(&times)
		clear(&pins)
		clear(&modes)
		for k := int(math.ceil((lo - origin) / spacing - 1e-6)); origin + f64(k) * spacing <= horizon + spacing; k += 1 {
			append(&times, origin + f64(k) * spacing)
		}
	}

	// slots under a locked slice are not filled
	for len(pins) < len(times) - 1 {append(&pins, PIN_NONE)}
	for len(modes) < len(times) - 1 {append(&modes, Lane_Mode.Normal)}
	for i in 0 ..< len(times) - 1 {
		for k, ki in kept {
			if times[i] < clip_end(k) - 1e-6 && times[i + 1] > k.start + 1e-6 {pins[i] = PIN_LOCKED_BASE - ki}
		}
	}

	res := rearrange(&project, s.rand, cands, times[:], pins[:], modes[:], kept, lo, hi)
	put_locked(kept, res.cells > 0 ? res.track : -1)
	// the slots end before the music does: a black placeholder clip keeps the layer going to the end of the project
	if res.cells > 0 && !ranged {
		from := res.end
		for k in kept {from = max(from, clip_end(k))} // after the locked slices, so none is hidden
		if tail := project_length(project) - from; tail > 0.05 {
			black := project.clips[res.last] // shaped like the last clip: same fit, scale and offset
			black.track, black.start, black.in_point, black.duration, black.speed = res.track, from, 0, tail, 1
			black.group, black.slice, black.locked, black.odds, black.freeze, black.black, black.selected = 0, true, false, 0, false, true, false
			append(&project.clips, black)
			res.clips += 1
		}
	}
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
	if res.pinned > 0 {
		set_status("%s; %d slots pinned to a layer by a lane or cut%s", status, res.pinned, res.pin_overridden > 0 ? fmt.tprintf(", %d gave way to the max-in-a-row limit", res.pin_overridden) : "")
	}
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
