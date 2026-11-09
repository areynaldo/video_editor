package main

import "base:intrinsics"
import "core:math"
import "core:slice"

// Tempo detection on the decoded audio, for steady-tempo music:
//  1. onset strength: log-magnitude spectral flux (FFT) in three bands (bass,
//     mids, highs), each normalised, so kicks, snares and hats all count
//  2. autocorrelation of that over the allowed BPM range, with a mild preference
//     for ~120 BPM and credit for multiples of the period, gives tempo peaks
//  3. every distinct strong peak becomes a CANDIDATE; a comb search around each
//     (fine BPM steps x every phase) refines the tempo and finds the first beat
// No detector is right every time (octave and 5:4 mistakes happen), so the
// caller gets several candidates, sorted best first, to choose from.

BPM_HOP :: 220 // frames between envelope steps (~5 ms)
BPM_FFT :: 512
BPM_CANDS :: 4
BPM_WINDOW_MAX :: 60.0 // seconds analysed
BPM_MIN_SECONDS :: 8.0

Bpm_Result :: struct {
	bpm:        f64,
	offset:     f64, // seconds from the start of the analysed window to a beat (0 <= offset < one beat)
	confidence: f32, // 0..1 relative to the best candidate
}

// ---------------------------------------------------------------- FFT (radix-2, 512 points)

fft_tw_c, fft_tw_s: [BPM_FFT / 2]f32
fft_rev: [BPM_FFT]int
fft_win: [BPM_FFT]f32
fft_ready: bool

fft_init :: proc() {
	if fft_ready {return}
	bits := 9 // log2(BPM_FFT)
	for i in 0 ..< BPM_FFT / 2 {
		a := -2 * math.PI * f64(i) / BPM_FFT
		fft_tw_c[i], fft_tw_s[i] = f32(math.cos(a)), f32(math.sin(a))
	}
	for i in 0 ..< BPM_FFT {
		r := 0
		for b in 0 ..< bits {
			if i & (1 << uint(b)) != 0 {r |= 1 << uint(bits - 1 - b)}
		}
		fft_rev[i] = r
		fft_win[i] = f32(0.5 - 0.5 * math.cos(2 * math.PI * f64(i) / (BPM_FFT - 1)))
	}
	fft_ready = true
}

fft :: proc(re, im: ^[BPM_FFT]f32) {
	for i in 0 ..< BPM_FFT {
		if j := fft_rev[i]; j > i {
			re[i], re[j] = re[j], re[i]
			im[i], im[j] = im[j], im[i]
		}
	}
	for size := 2; size <= BPM_FFT; size *= 2 {
		half, step := size / 2, BPM_FFT / size
		for start := 0; start < BPM_FFT; start += size {
			for k in 0 ..< half {
				wr, wi := fft_tw_c[k * step], fft_tw_s[k * step]
				a, b := start + k, start + k + half
				tr := re[b] * wr - im[b] * wi
				ti := re[b] * wi + im[b] * wr
				re[b], im[b] = re[a] - tr, im[a] - ti
				re[a] += tr
				im[a] += ti
			}
		}
	}
}

// ---------------------------------------------------------------- detection

// Analyses (a window of) source time t0..t1. Returns candidates best first and the
// source time the window started at (offsets are relative to it).
detect_bpm :: proc(a: ^Audio_Source, t0, t1, lo_bpm, hi_bpm: f64) -> (cands: [BPM_CANDS]Bpm_Result, n: int, win_start: f64, ok: bool) {
	fft_init()
	avail := intrinsics.atomic_load_explicit(&a.frames, .Acquire)
	t1 := min(t1, f64(avail) / AUDIO_RATE)
	if t1 - t0 < BPM_MIN_SECONDS {
		return
	}
	// skip a little of the start (intros), but never so much that there is too little left
	w0 := t0 + min((t1 - t0) * 0.1, 15)
	if t1 - w0 < BPM_MIN_SECONDS {w0 = t0}
	w1 := min(w0 + BPM_WINDOW_MAX, t1)
	f0, f1 := int(w0 * AUDIO_RATE), int(w1 * AUDIO_RATE)
	win_start = w0

	mono := make([]f32, f1 - f0, context.temp_allocator)
	for i in 0 ..< len(mono) {
		l, r := frame_at(a, f0 + i)
		mono[i] = (l + r) * 0.5
	}
	n_env := (len(mono) - BPM_FFT) / BPM_HOP
	if n_env < 200 {
		return
	}
	hop_s := f64(BPM_HOP) / AUDIO_RATE

	// 1. onset strength: spectral flux in three bands
	bands := [4]int{1, 3, 24, 110} // bin edges: bass, mids, highs
	flux: [3][]f32
	for &f in flux {f = make([]f32, n_env, context.temp_allocator)}
	re, im: [BPM_FFT]f32
	prev: [BPM_FFT / 2 + 1]f32
	for k in 0 ..< n_env {
		base := k * BPM_HOP
		for i in 0 ..< BPM_FFT {
			re[i], im[i] = mono[base + i] * fft_win[i], 0
		}
		fft(&re, &im)
		for band in 0 ..< 3 {
			sum: f32
			for bin in bands[band] ..< bands[band + 1] {
				m := math.sqrt(re[bin] * re[bin] + im[bin] * im[bin]) * (4.0 / BPM_FFT)
				lm := f32(math.ln(1 + 100 * f64(m)))
				if d := lm - prev[bin]; d > 0 {sum += d}
				prev[bin] = lm
			}
			flux[band][k] = sum
		}
	}
	onset := make([]f32, n_env, context.temp_allocator)
	weights := [3]f32{1.0, 0.8, 0.6}
	for band in 0 ..< 3 {
		mean: f32
		for v in flux[band] {mean += v}
		mean = max(mean / f32(n_env), 1e-9)
		for k in 0 ..< n_env {onset[k] += weights[band] * flux[band][k] / mean}
	}
	flat := flatten(onset)
	smooth := smooth3(flat)
	low_env: []f32 // the bass band alone: where the kick (the beat) is, used to place the beats
	{
		low := make([]f32, n_env, context.temp_allocator)
		mean: f32
		for v in flux[0] {mean += v}
		mean = max(mean / f32(n_env), 1e-9)
		for k in 0 ..< n_env {low[k] = flux[0][k] / mean}
		low_env = smooth3(flatten(low))
	}

	// 2. tempo peaks from the autocorrelation
	lo_bpm, hi_bpm := clamp(lo_bpm, 40, 220), clamp(hi_bpm, 60, 260)
	if hi_bpm <= lo_bpm + 5 {hi_bpm = lo_bpm + 5}
	lag_min := max(int(60 / hi_bpm / hop_s), 2)
	lag_max := int(60 / lo_bpm / hop_s)
	r := make([]f64, 3 * lag_max + 3, context.temp_allocator)
	for lag in lag_min ..< len(r) {
		if lag >= n_env / 2 {break}
		s: f64
		for k in 0 ..< n_env - lag {s += f64(flat[k] * flat[k + lag])}
		r[lag] = s / f64(n_env - lag)
	}
	score := make([]f64, lag_max + 2, context.temp_allocator)
	for lag in lag_min ..= lag_max {
		bpm := 60 / (f64(lag) * hop_s)
		prior := math.exp(-0.5 * math.pow(math.log2(bpm / 120), 2)) // gentle pull towards 120
		score[lag] = (r[lag] + 0.5 * r[2 * lag] + 0.25 * r[3 * lag]) * prior
	}
	Peak :: struct {
		lag:   int,
		score: f64,
	}
	peaks := make([dynamic]Peak, context.temp_allocator)
	for lag in lag_min + 1 ..< lag_max {
		if score[lag] > score[lag - 1] && score[lag] >= score[lag + 1] && score[lag] > 0 {
			append(&peaks, Peak{lag, score[lag]})
		}
	}
	slice.sort_by(peaks[:], proc(x, y: Peak) -> bool {return x.score > y.score})

	// 3. the best distinct peaks, each refined
	best_score := f64(0)
	for pk in peaks {
		bpm0 := 60 / (f64(pk.lag) * hop_s)
		is_new := true
		for i in 0 ..< n {
			is_new &&= abs(bpm0 - cands[i].bpm) / cands[i].bpm > 0.04
		}
		if !is_new {continue}
		best := comb_search(smooth, hop_s, bpm0)
		phase := comb_phase(low_env, hop_s, best.bpm) // beats sit on the kick, not on off-beat hats
		cands[n] = Bpm_Result{best.bpm, f64(phase) * hop_s, 0}
		if n == 0 {best_score = pk.score}
		cands[n].confidence = f32(pk.score / max(best_score, 1e-12))
		n += 1
		if n == BPM_CANDS {break}
	}
	return cands, n, win_start, n > 0
}

Comb :: struct {
	bpm:   f64,
	phase: int, // envelope steps
	score: f64, // mean onset strength at the beat positions
}

// Tries tempos within 3% of bpm0 (0.05 BPM steps) and every phase; the best has the
// strongest onsets on the beats. Positions between steps are interpolated.
comb_search :: proc(smooth: []f32, hop_s, bpm0: f64) -> (best: Comb) {
	best.score = -1
	for bpm := bpm0 * 0.97; bpm <= bpm0 * 1.03; bpm += 0.05 {
		period := 60 / bpm / hop_s // in envelope steps
		for phase in 0 ..< int(period) {
			if s := comb_score(smooth, f64(phase), period); s > best.score {
				best.bpm, best.phase, best.score = bpm, phase, s
			}
		}
	}
	return
}

// Subtracts a ~1 s moving average and keeps the positive part.
flatten :: proc(onset: []f32) -> []f32 {
	n := len(onset)
	W :: 200
	prefix := make([]f64, n + 1, context.temp_allocator)
	for k in 0 ..< n {prefix[k + 1] = prefix[k] + f64(onset[k])}
	out := make([]f32, n, context.temp_allocator)
	for k in 0 ..< n {
		lo, hi := max(k - W / 2, 0), min(k + W / 2, n)
		out[k] = max(onset[k] - f32((prefix[hi] - prefix[lo]) / f64(hi - lo)), 0)
	}
	return out
}

smooth3 :: proc(x: []f32) -> []f32 {
	out := make([]f32, len(x), context.temp_allocator)
	for k in 0 ..< len(x) {
		out[k] = 0.25 * x[max(k - 1, 0)] + 0.5 * x[k] + 0.25 * x[min(k + 1, len(x) - 1)]
	}
	return out
}

// Where the beats fall for a given tempo: the phase (envelope steps) whose beats have
// the most onsets and whose off-beats the fewest.
comb_phase :: proc(env: []f32, hop_s, bpm: f64) -> int {
	period := 60 / bpm / hop_s
	best, best_score := 0, f64(-1e30)
	for phase in 0 ..< int(period) {
		if s := comb_score(env, f64(phase), period); s > best_score {
			best, best_score = phase, s
		}
	}
	return best
}

// Onsets on the beats minus half of those halfway between: a phase that sits on the
// off-beat hats scores badly because the kicks then fall "between the beats".
comb_score :: proc(env: []f32, phase, period: f64) -> f64 {
	at :: proc(env: []f32, pos: f64) -> f64 {
		i := int(pos)
		if i < 0 || i + 1 >= len(env) {return 0}
		frac := f32(pos - f64(i))
		return f64(env[i] * (1 - frac) + env[i + 1] * frac)
	}
	on, off: f64
	beats := 0
	for pos := phase; int(pos) + 1 < len(env); pos += period {
		on += at(env, pos)
		off += at(env, pos + period / 2)
		beats += 1
	}
	return (on - 0.5 * off) / f64(max(beats, 1))
}
