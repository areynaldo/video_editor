package main

import "core:slice"

// Placing lyric lines in a song without trusting a speech recogniser too much.
//
// Whisper's word times for singing are rough, and a recogniser misses or invents words. What
// is reliable: WHERE THE VOICE IS (the audio is quiet between phrases) and the few words it
// did hear right. So:
//   - the voiced clock counts only the seconds the voice is on (silences are skipped, so gaps
//     between phrases are kept and nothing can be squeezed into a silence)
//   - the words you wrote get a weight (their length, a stand-in for the time they take)
//   - the words that were heard right (exact, not a short word, in a consistent order) are
//     anchors: this word is at this voiced time
//   - between anchors the lines are spread by weight on the voiced clock; before the first and
//     after the last the speed of the whole song is used
// The result needs no anchors at all to give something sensible: with none, the lines fill the
// voiced time in proportion to their length.

Voice_Clock :: struct {
	ivs:   [][2]f64, // the voiced stretches (start, end), in order
	cum:   []f64, // cum[k] = voiced seconds before ivs[k]
	total: f64, // all voiced seconds
}

finish_clock :: proc(ivs: [][2]f64) -> (vc: Voice_Clock) {
	vc.ivs = ivs
	vc.cum = make([]f64, len(ivs), context.temp_allocator)
	for iv, k in ivs {
		vc.cum[k] = vc.total
		vc.total += iv[1] - iv[0]
	}
	return
}

// The voice is on wherever the audio is not silent. `silences` are (start, end) from the
// silence detector; `length` is the length of the audio.
make_voice_clock :: proc(silences: [][2]f64, length: f64) -> Voice_Clock {
	ivs := make([dynamic][2]f64, context.temp_allocator)
	at := 0.0
	for s in silences {
		if s[0] > at + 0.05 {append(&ivs, [2]f64{at, min(s[0], length)})}
		at = max(at, s[1])
	}
	if length > at + 0.05 {append(&ivs, [2]f64{at, length})}
	return finish_clock(ivs[:])
}

// When the audio has no silences to use (a full mix), the stretches where words were heard
// are the voiced ones: each word lasts a little, close words join.
make_voice_clock_from_words :: proc(starts, ends: []f64) -> Voice_Clock {
	ivs := make([dynamic][2]f64, context.temp_allocator)
	for s, i in starts {
		e := min(ends[i], s + 0.8)
		if len(ivs) > 0 && s - ivs[len(ivs) - 1][1] < 0.3 {
			ivs[len(ivs) - 1][1] = max(ivs[len(ivs) - 1][1], e)
		} else {
			append(&ivs, [2]f64{s, max(e, s + 0.1)})
		}
	}
	return finish_clock(ivs[:])
}

// Voiced seconds before time t.
clock_tau :: proc(vc: Voice_Clock, t: f64) -> f64 {
	for iv, k in vc.ivs {
		if t < iv[0] {return vc.cum[k]}
		if t <= iv[1] {return vc.cum[k] + (t - iv[0])}
	}
	return vc.total
}

// The time at which the voiced clock shows tau. A line's end takes the earlier of two times
// that share a boundary (the end of a stretch), a start the later one (the start of the next).
clock_time :: proc(vc: Voice_Clock, tau: f64, as_end: bool) -> f64 {
	if len(vc.ivs) == 0 {return tau}
	x := clamp(tau, 0, vc.total)
	for iv, k in vc.ivs {
		len_k := iv[1] - iv[0]
		if as_end ? x <= vc.cum[k] + len_k + 1e-9 : x < vc.cum[k] + len_k - 1e-9 {
			return iv[0] + clamp(x - vc.cum[k], 0, len_k)
		}
	}
	return vc.ivs[len(vc.ivs) - 1][1]
}

median :: proc(v: []f64) -> f64 {
	if len(v) == 0 {return 0}
	s := slice.clone(v, context.temp_allocator)
	slice.sort(s)
	return s[len(s) / 2]
}

// A robust line y = slope * x + icpt through the points: the median of the slopes between
// pairs, so a few wrong points do not matter.
theil_sen :: proc(x, y: []f64) -> (slope, icpt: f64) {
	slopes := make([dynamic]f64, context.temp_allocator)
	step := max(len(x) / 400, 1) // long songs: not every pair
	for i := 0; i < len(x); i += step {
		for j := i + 1; j < len(x); j += step {
			if x[j] > x[i] + 1e-9 {append(&slopes, (y[j] - y[i]) / (x[j] - x[i]))}
		}
	}
	slope = median(slopes[:])
	res := make([]f64, len(x), context.temp_allocator)
	for i in 0 ..< len(x) {res[i] = y[i] - slope * x[i]}
	return slope, median(res)
}

// tau for the weight w, through the anchors (aw -> at), and beyond them at `slope`.
interp_tau :: proc(aw, at: []f64, slope, w: f64) -> f64 {
	n := len(aw)
	if n == 0 {return w * slope}
	if w <= aw[0] {return at[0] - (aw[0] - w) * slope}
	if w >= aw[n - 1] {return at[n - 1] + (w - aw[n - 1]) * slope}
	for k in 1 ..< n {
		if w <= aw[k] {
			f := (w - aw[k - 1]) / max(aw[k] - aw[k - 1], 1e-9)
			return at[k - 1] + f * (at[k] - at[k - 1])
		}
	}
	return at[n - 1]
}

// Keeps the anchors that agree with the song as a whole and with their neighbours: a
// common word matched in the wrong place is far from where its neighbours put it.
filter_anchors :: proc(aw, at: []f64) -> (kw, kt: [dynamic]f64) {
	kw = make([dynamic]f64, context.temp_allocator)
	kt = make([dynamic]f64, context.temp_allocator)
	if len(aw) < 3 {
		append(&kw, ..aw)
		append(&kt, ..at)
		return
	}
	a, b := theil_sen(aw, at)
	span := at[len(at) - 1] - at[0]
	tol := max(5.0, 0.15 * span) // the song's speed changes, but not by this much
	for i in 0 ..< len(aw) {
		if abs(at[i] - (a * aw[i] + b)) <= tol {
			append(&kw, aw[i])
			append(&kt, at[i])
		}
	}
	for _ in 0 ..< 2 { // then: does it sit where its neighbours say?
		i := 1
		removed := false
		for i + 1 < len(kw) {
			f := (kw[i] - kw[i - 1]) / max(kw[i + 1] - kw[i - 1], 1e-9)
			pred := kt[i - 1] + f * (kt[i + 1] - kt[i - 1])
			if abs(kt[i] - pred) > 1.5 {
				ordered_remove(&kw, i)
				ordered_remove(&kt, i)
				removed = true
			} else {
				i += 1
			}
		}
		if !removed {break}
	}
	return
}
