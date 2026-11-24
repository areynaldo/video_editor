package main

import "base:intrinsics"
import "core:math"

import im "deps/odin-imgui"

// The audio under the pattern editor: the loop of the pattern that is at the playhead is drawn
// above the steps, one cell of waveform per step, so the hits can be drawn to match the music.
// Gray is the whole signal, orange its low end (under LOW_HZ: where a kick lives). The per-lane
// "kick" button sets the lane's steps where the low end starts a new bump.

LOW_HZ :: 150.0
WAVE_SUB :: 6 // bars per step
WAVE_H :: f32(34)

wave_show := true
wave_sens := f32(0.45) // how loud (of the loudest low bump in the loop) a bump must be to count as a hit

Pattern_Wave :: struct {
	ok:    bool,
	steps: int,
	full:  []f32, // steps * WAVE_SUB, 0..1
	low:   []f32,
	bump:  []f32, // per step: the low end at the hit, 0..1 of the loudest in the loop
	rise:  []bool, // per step: the low end rises there (a new bump, not the tail of the last one)
}

// The first step whose (swung) time is at/after t: odd steps are delayed, so counting plain steps would skip
// or double a step when t is a swung hit and the pattern would start one step off.
pattern_step_from :: proc(t, origin, step, swing: f64) -> int {
	k := int(math.ceil((t - origin) / step - swing)) - 1
	for origin + (f64(k) + (k % 2 != 0 ? swing : 0)) * step < t - 1e-6 {k += 1}
	return k
}

// Time of step k (swing delays the odd ones).
pattern_step_time :: proc(k: int, origin, step, swing: f64) -> f64 {
	return origin + (f64(k) + (k % 2 != 0 ? swing : 0)) * step
}

// The step index where the loop of `pat` that the playhead is in starts: the part under the playhead
// that uses this pattern sets where it starts over, else the selected range (or the start), as Apply does.
pattern_loop_base :: proc(pat: Pattern) -> (kb: int, step, origin, swing: f64) {
	s := project.settings
	step = 60 / f64(max(s.bpm, 1)) / f64(max(pat.div, 1))
	origin = beat_origin(s)
	swing = f64(clamp(pat.swing, 0, 75)) / 100
	length := int(clamp(pat.length, 1, MAX_STEPS))
	anchor := 0.0
	if a, _, ok := program_range(); ok {anchor = a}
	for part in project.parts {
		if part.pattern == project.settings.pattern_sel && playhead >= part.t0 && playhead < part.t1 {
			anchor = part_anchor(part)
			break
		}
	}
	k0 := pattern_step_from(anchor, origin, step, swing)
	kplay := pattern_step_from(max(playhead, 0), origin, step, swing)
	idx := ((kplay - k0) % length + length) % length
	return kplay - idx, step, origin, swing
}

// The timeline's audio between t0 and t1 (project seconds) as n bars: the loudest sample, and the loudest
// of its low end. Both 0..1. Only what is decoded so far.
audio_env :: proc(t0, t1: f64, full, low: []f32) {
	n := len(full)
	for i in 0 ..< n {full[i], low[i] = 0, 0}
	if t1 <= t0 || n == 0 {return}
	STRIDE :: 2
	alpha := f32(1 - math.exp(-2 * math.PI * LOW_HZ / (f64(AUDIO_RATE) / STRIDE)))
	for c in project.clips {
		if c.kind != .Audio || !track_audible(project, c.track) || c.source >= len(audios) || audios[c.source] == nil {continue}
		if t1 <= c.start || t0 >= clip_end(c) {continue}
		gain := db_to_gain(c.gain_db)
		if gain == 0 {continue}
		a := audios[c.source]
		avail := intrinsics.atomic_load_explicit(&a.frames, .Acquire)
		lo, hi := max(t0, c.start), min(t1, clip_end(c))
		lp := f32(0)
		for fi := int(max(lo - 0.03, c.start) * AUDIO_RATE); fi < int(hi * AUDIO_RATE); fi += STRIDE { // 30 ms before: the filter warms up
			t := f64(fi) / AUDIO_RATE
			sf := int((c.in_point + (t - c.start) * c.speed) * AUDIO_RATE)
			if sf < 0 || sf >= avail {continue}
			l, r := frame_at(a, sf)
			x := (l + r) * 0.5 * gain
			lp += alpha * (x - lp)
			if t < lo {continue}
			b := clamp(int((t - t0) / (t1 - t0) * f64(n)), 0, n - 1)
			full[b] = min(max(full[b], abs(x)), 1)
			low[b] = min(max(low[b], abs(lp)), 1)
		}
	}
}

// The checkbox and sensitivity, then the audio of the loop at the playhead (nothing when hidden).
pattern_wave_compute :: proc(pat: Pattern) -> (w: Pattern_Wave) {
	im.Checkbox("audio", &wave_show)
	if im.IsItemHovered() {im.SetTooltip("show the audio of this loop above the steps (move the playhead to look at another place)")}
	if !wave_show {return}
	im.SameLine()
	im.SetNextItemWidth(120)
	im.SliderFloat("kick sensitivity", &wave_sens, 0.1, 0.9, "%.2f")
	if im.IsItemHovered() {im.SetTooltip("lower = more hits found by the per-lane 'kick' button")}

	length := int(clamp(pat.length, 1, MAX_STEPS))
	kb, step, origin, swing := pattern_loop_base(pat)
	w.steps = length
	w.full = make([]f32, length * WAVE_SUB, context.temp_allocator)
	w.low = make([]f32, length * WAVE_SUB, context.temp_allocator)
	w.bump = make([]f32, length, context.temp_allocator)
	w.rise = make([]bool, length, context.temp_allocator)
	for j in 0 ..< length {
		t := pattern_step_time(kb + j, origin, step, swing)
		// from a little before the hit to just before the next step
		audio_env(t - 0.1 * step, t + 0.9 * step, w.full[j * WAVE_SUB:][:WAVE_SUB], w.low[j * WAVE_SUB:][:WAVE_SUB])
	}
	loudest := f32(0)
	for j in 0 ..< length {
		for s in 0 ..< 4 { // the hit is 10% in: look from before it to the middle of the step
			w.bump[j] = max(w.bump[j], w.low[j * WAVE_SUB + s])
		}
		loudest = max(loudest, w.bump[j])
	}
	for j in 0 ..< length {
		prev_tail := j > 0 ? w.low[(j - 1) * WAVE_SUB + WAVE_SUB - 1] : f32(0)
		w.rise[j] = w.bump[j] > prev_tail * 1.3 + 0.02
		if loudest > 0 {w.bump[j] /= loudest}
	}
	w.ok = loudest > 0.01
	if !w.ok {im.TextDisabled("no audio here: put the playhead on a song, or wait until it is decoded")}
	return
}

// Sets a lane's steps to the kicks found in the audio.
pattern_wave_detect :: proc(w: Pattern_Wave, lane: ^Lane) -> int {
	n := 0
	for j in 0 ..< w.steps {
		hit := w.bump[j] >= wave_sens && w.rise[j]
		lane.steps[j] = hit ? 1 : 0
		if hit {n += 1}
	}
	return n
}

// One row of the editor: the waveform cells of steps bar..bar+16, aligned with the lane cells below.
pattern_wave_row :: proc(w: Pattern_Wave, pat: Pattern, bar: int, cell: f32) {
	if !w.ok {return}
	dl := im.GetWindowDrawList()
	im.TextDisabled("audio")
	im.SameLine(80)
	for j in bar ..< min(bar + 16, w.steps) {
		if j > bar {im.SameLine(0, j % int(pat.div) == 0 ? 8 : 2)}
		p := im.GetCursorScreenPos()
		im.Dummy({cell, WAVE_H})
		im.DrawList_AddRectFilled(dl, p, {p.x + cell, p.y + WAVE_H}, 0xFF202020, 3)
		bw := cell / WAVE_SUB
		for s in 0 ..< WAVE_SUB {
			x := p.x + f32(s) * bw
			hf := w.full[j * WAVE_SUB + s] * WAVE_H
			hl := w.low[j * WAVE_SUB + s] * WAVE_H
			im.DrawList_AddRectFilled(dl, {x, p.y + WAVE_H - hf}, {x + bw - 1, p.y + WAVE_H}, 0xFF707070)
			im.DrawList_AddRectFilled(dl, {x, p.y + WAVE_H - hl}, {x + bw - 1, p.y + WAVE_H}, 0xFF2080F0)
		}
		hit_x := p.x + cell * 0.1 // the step's hit: the cell starts 10% of a step before it
		im.DrawList_AddLine(dl, {hit_x, p.y}, {hit_x, p.y + WAVE_H}, w.rise[j] && w.bump[j] >= wave_sens ? 0xFF40E0FF : 0x40FFFFFF)
	}
}
