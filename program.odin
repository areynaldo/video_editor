package main

import "core:math"
import "core:math/rand"
import "core:slice"

// The program is a switcher over the video layers: a sorted list of cuts, each
// saying which layer is visible from its time until the next cut. Audio is not
// affected. Cuts are made on the grid (beats), by hand, or live while playing.

CUT_EPS :: 1e-4
MIN_SEGMENT :: 0.01

// Tracks that contain video, ascending. Layer keys 1..9 pick from this list.
video_layers :: proc(p: Project) -> []int {
	out := make([dynamic]int, context.temp_allocator)
	for c in p.clips {
		if c.kind == .Video && !slice.contains(out[:], c.track) {
			append(&out, c.track)
		}
	}
	slice.sort(out[:])
	return out[:]
}

// Index of the segment (cut) containing t, or -1 before the first cut. The cuts are
// sorted, so this is a binary search.
segment_at :: proc(p: Project, t: f64) -> int {
	lo, hi := 0, len(p.program) // first cut that starts after t
	for lo < hi {
		mid := (lo + hi) / 2
		if p.program[mid].time <= t + CUT_EPS {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	return lo - 1
}

// Layer shown at t: a track number, or -1 for "no override".
program_layer_at :: proc(p: Project, t: f64) -> int {
	i := segment_at(p, t)
	return i < 0 ? -1 : p.program[i].layer
}

// End time of segment i (start of the next cut), or `fallback` for the last one.
segment_end :: proc(p: Project, i: int, fallback: f64) -> f64 {
	return i + 1 < len(p.program) ? p.program[i + 1].time : max(fallback, p.program[i].time)
}

// Makes sure a cut exists at t (the new segment inherits the current layer).
// Returns its index.
cut_insert :: proc(p: ^Project, t: f64) -> int {
	t := max(t, 0)
	prev := segment_at(p^, t)
	if prev >= 0 && abs(p.program[prev].time - t) <= CUT_EPS {
		return prev
	}
	layer := prev >= 0 ? p.program[prev].layer : -1
	inject_at(&p.program, prev + 1, Cut{time = t, layer = layer})
	return prev + 1
}

cut_remove :: proc(p: ^Project, i: int) {
	if i >= 0 && i < len(p.program) {
		ordered_remove(&p.program, i)
	}
}

// Moves cut i, keeping it between its neighbours.
cut_move :: proc(p: ^Project, i: int, t: f64) {
	lo := i > 0 ? p.program[i - 1].time + MIN_SEGMENT : 0
	hi := i + 1 < len(p.program) ? p.program[i + 1].time - MIN_SEGMENT : max(f64)
	p.program[i].time = clamp(t, lo, max(lo, hi))
}

// Cuts every `spacing` seconds (counted from `origin`) inside [from, to).
// Layers are inherited, so on its own this changes nothing visible.
program_split_grid :: proc(p: ^Project, from, to, spacing, origin: f64) {
	if spacing <= 0 || to <= from {
		return
	}
	cut_insert(p, from)
	for k := int(math.floor((from - origin) / spacing + 1e-6)) + 1; origin + f64(k) * spacing < to - CUT_EPS; k += 1 {
		cut_insert(p, origin + f64(k) * spacing)
	}
}

// ---------------------------------------------------------------- randomize

// Everything the randomizer needs, so the command and the context menu share one path.
Rand_Job :: struct {
	opts:    Rand_Options,
	layers:  []int, // the layers to choose from (video layers only); empty = all of them
	t0, t1:  f64,   // the range to randomize
	end:     f64,   // project length
	spacing: f64,   // grid spacing for Grid mode / when there are no cuts yet
	origin:  f64,
}

// Program randomizer. The slicing comes from Rand_Options.slice:
//   Grid     the range is re-cut on the grid (replacing its cuts)
//   Pattern  ... at the hits of a pattern (job.cuts)
//   Cuts     the cuts the program already has stay as they are (cut on the grid if none)
// then, with Random ticked, every segment picks a random layer.
//   Random  every segment picks a random layer (never more than max_run in a row)
// (reordering footage = the rearrange stage, see rearrange.odin)
program_randomize :: proc(p: ^Project, job: Rand_Job) {
	modes := job.opts.modes
	all := video_layers(p^)
	cand := make([dynamic]int, context.temp_allocator)
	for l in all {
		if len(job.layers) == 0 || slice.contains(job.layers, l) {
			append(&cand, l)
		}
	}
	if len(cand) == 0 {
		return
	}
	switch job.opts.slice {
	case .Grid: // the grid replaces whatever cuts were inside the range
		#reverse for c, i in p.program {
			if c.time >= job.t0 - CUT_EPS && c.time < job.t1 - CUT_EPS {
				ordered_remove(&p.program, i)
			}
		}
		program_split_grid(p, job.t0, job.t1, job.spacing, job.origin)
	case .Cuts, .Pattern: // keep the cuts that are there (a pattern was applied first); the grid if none
		if len(p.program) == 0 {
			program_split_grid(p, job.t0, job.t1, job.spacing, job.origin)
		}
	}

	// segments whose start is inside [t0, t1)
	first := max(segment_at(p^, job.t0), 0)
	last := first
	for c, i in p.program {
		if c.time < job.t1 - CUT_EPS {last = i}
	}
	if last < first || len(p.program) == 0 {
		return
	}
	if .Random in modes {
		assign_random(p, cand[:], job, first, last)
	}
}

// A random layer for the segment starting at `t`: only layers that have video
// there, never more than `max_run` in a row of the same one (if there is a choice).
pick_layer :: proc(p: Project, cand: []int, t, t_end: f64, prev, run, max_run: int) -> int {
	mid := (t + t_end) / 2
	pool := make([dynamic]int, context.temp_allocator)
	for l in cand {
		for c in p.clips {
			if c.kind == .Video && c.track == l && mid >= c.start && mid < clip_end(c) {
				append(&pool, l)
				break
			}
		}
	}
	if len(pool) == 0 {
		pool = slice.to_dynamic(cand, context.temp_allocator)
	}
	if max_run > 0 && run >= max_run && len(pool) > 1 {
		if k, found := slice.linear_search(pool[:], prev); found {
			unordered_remove(&pool, k)
		}
	}
	return pool[rand.int_max(len(pool))]
}

assign_random :: proc(p: ^Project, cand: []int, job: Rand_Job, first, last: int) {
	prev, run := first > 0 ? p.program[first - 1].layer : -1, 0
	if first > 0 && prev >= 0 { // count the run that is already there
		run = 1
		for k := first - 2; k >= 0 && p.program[k].layer == prev; k -= 1 {run += 1}
	}
	for i in first ..= last {
		layer := p.program[i].layer
		if !p.program[i].fixed { // a layer a pattern lane set stays; everything else is dealt out
			layer = pick_layer(p^, cand, p.program[i].time, segment_end(p^, i, job.end), prev, run, int(job.opts.max_run))
			p.program[i].layer = layer
		}
		run = layer == prev ? run + 1 : 1
		prev = layer
	}
}


// ---------------------------------------------------------------- copy / paste / repeat

// The copied cuts: times relative to the start of the copied range.
Cut_Clip :: struct {
	cuts:   [dynamic]Cut,
	length: f64,
}
cut_clip: Cut_Clip

copy_cuts :: proc(p: Project, t0, t1: f64) {
	clear(&cut_clip.cuts)
	for c in p.program {
		if c.time >= t0 - CUT_EPS && c.time < t1 - CUT_EPS {
			append(&cut_clip.cuts, Cut{time = c.time - t0, layer = c.layer, fixed = c.fixed})
		}
	}
	cut_clip.length = t1 - t0
}

// Pastes the copied cuts so that they start at `dest`, replacing the cuts there. What
// showed after the pasted range keeps showing. Returns where the pasted range ends.
paste_cuts :: proc(p: ^Project, dest: f64) -> (end: f64, ok: bool) {
	if len(cut_clip.cuts) == 0 || cut_clip.length <= 0 {
		return
	}
	end = dest + cut_clip.length
	after_i := segment_at(p^, end)
	after := after_i >= 0 ? p.program[after_i] : Cut{layer = -1}
	had_cut := after_i >= 0 && abs(p.program[after_i].time - end) <= CUT_EPS
	#reverse for c, i in p.program {
		if c.time >= dest - CUT_EPS && c.time < end - CUT_EPS {
			ordered_remove(&p.program, i)
		}
	}
	for c in cut_clip.cuts {
		i := cut_insert(p, dest + c.time)
		p.program[i].layer, p.program[i].fixed = c.layer, c.fixed
	}
	if !had_cut {
		i := cut_insert(p, end)
		p.program[i].layer, p.program[i].fixed = after.layer, after.fixed
	}
	return end, true
}

// Pastes the copied cuts again and again from `start` until `end`. Returns how many times.
repeat_cuts :: proc(p: ^Project, start, end: f64) -> (n: int) {
	if cut_clip.length <= 0 {return}
	for k := 0; start + f64(k) * cut_clip.length < end - CUT_EPS; k += 1 {
		paste_cuts(p, start + f64(k) * cut_clip.length)
		n += 1
	}
	return
}

// ---------------------------------------------------------------- export helper

Interval :: struct {
	a, b: f64,
}

// When is `track` visible, as merged intervals within [0, end]? always = no
// restriction (no program, or visible the whole time).
visible_intervals :: proc(p: Project, track: int, end: f64) -> (iv: []Interval, always: bool) {
	if len(p.program) == 0 {
		return nil, true
	}
	out := make([dynamic]Interval, context.temp_allocator)
	add :: proc(out: ^[dynamic]Interval, a, b: f64) {
		if b <= a {return}
		if n := len(out); n > 0 && abs(out[n - 1].b - a) < 1e-9 {
			out[n - 1].b = b
		} else {
			append(out, Interval{a, b})
		}
	}
	add(&out, 0, min(p.program[0].time, end)) // before the first cut: no override
	for c, i in p.program {
		if c.layer == -1 || c.layer == track {
			add(&out, c.time, min(segment_end(p, i, end), end))
		}
	}
	if len(out) == 1 && out[0].a <= 0 && out[0].b >= end {
		return nil, true
	}
	return out[:], false
}
