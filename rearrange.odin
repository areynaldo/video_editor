package main

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
		out.group = 0
		out.selected = false
		append(&p.clips, out)
		res.clips += 1
		i = j
	}
	res.cells, res.unused, res.track, res.bounds = len(entries), same_time ? 0 : total - len(entries), track, bounds[:]
	return
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
