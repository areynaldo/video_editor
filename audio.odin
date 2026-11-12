package main

import "base:intrinsics"
import "base:runtime"
import "core:math"
import "core:mem"
import "core:os"
import "core:sync"
import "core:thread"

import ma "vendor:miniaudio"

// Audio: every source with an audio stream is decoded once by ffmpeg into memory
// (16-bit stereo, AUDIO_RATE), like the video proxy. A miniaudio device pulls
// from those buffers: its callback mixes all audio clips at the timeline
// position it owns, so while playing the audio clock drives the playhead.
// Playback speed != 1 changes pitch here (export keeps the pitch).

AUDIO_RATE :: 44100
CHUNK_FRAMES :: 1 << 16 // decoded audio is stored in fixed chunks so it never reallocates
PEAK_BLOCK :: 512 // frames per waveform peak
MAX_MIX_CLIPS :: 512

Audio_Source :: struct {
	chunks:     []([]i16), // preallocated slots, filled by the reader as audio arrives
	frames:     int, // frames decoded so far (atomic)
	peaks:      []u8, // waveform: max |sample| per PEAK_BLOCK frames, 0..255
	peak_count: int, // atomic
	process:    os.Process,
	thread:     ^thread.Thread,
}

audios: [dynamic]^Audio_Source // parallel to Project.sources; nil = no audio stream

Mix_Clip :: struct {
	src:      ^Audio_Source,
	start:    f64,
	in_point: f64,
	duration: f64,
	speed:    f64,
	gain:     f32, // linear
}

Mixer :: struct {
	mu:      sync.Mutex, // guards clips/count/master (held by the callback while mixing)
	clips:   [MAX_MIX_CLIPS]Mix_Clip,
	count:   int,
	master:  f32,
	pos:     i64, // timeline position in frames (atomic)
	playing: bool, // atomic
	peak_l:  u32, // f32 bits, max since last read (atomic)
	peak_r:  u32,
}

mixer: Mixer
audio_device: ma.device
audio_ok: bool
audio_was_playing: bool

db_to_gain :: proc(db: f32) -> f32 {
	return db <= -60 ? 0 : math.pow(10, db / 20)
}

audio_init :: proc() {
	cfg := ma.device_config_init(.playback)
	cfg.playback.format = .f32
	cfg.playback.channels = 2
	cfg.sampleRate = AUDIO_RATE
	cfg.dataCallback = audio_callback
	if ma.device_init(nil, &cfg, &audio_device) != .SUCCESS {
		return
	}
	if ma.device_start(&audio_device) != .SUCCESS {
		ma.device_uninit(&audio_device)
		return
	}
	audio_ok = true
}

audio_shutdown :: proc() {
	if audio_ok {
		ma.device_uninit(&audio_device)
		audio_ok = false
	}
}

// ---------------------------------------------------------------- decoding

media_start :: proc(s: Source, fps: int) {
	proxy_start(s.path, fps)
	if !s.has_audio {
		append(&audios, nil)
		return
	}
	a := new(Audio_Source)
	cap_frames := int(s.duration * AUDIO_RATE) + 2 * CHUNK_FRAMES
	a.chunks = make([][]i16, cap_frames / CHUNK_FRAMES + 1)
	a.peaks = make([]u8, cap_frames / PEAK_BLOCK + 2)
	append(&audios, a)

	r, w, _ := os.pipe()
	proc_, err := os.process_start(
		{
			command = {"ffmpeg", "-v", "error", "-i", s.path, "-vn", "-f", "s16le", "-ac", "2", "-ar", "44100", "pipe:1"},
			stdout = w,
		},
		)
	os.close(w)
	if err != nil {
		os.close(r)
		return
	}
	a.process = proc_
	a.thread = thread.create_and_start_with_poly_data2(a, r, audio_reader)
}

audio_reader :: proc(a: ^Audio_Source, r: ^os.File) {
	defer os.close(r)
	buf := make([]u8, 1 << 18)
	defer delete(buf)
	carry := 0
	frames := 0
	block_peak: i32
	block_n := 0
	for {
		n, err := os.read(r, buf[carry:])
		if n <= 0 || err != nil {
			break
		}
		total := carry + n
		whole := total / 4
		samples := ([^]i16)(raw_data(buf))
		for f in 0 ..< whole {
			ci := frames / CHUNK_FRAMES
			if ci >= len(a.chunks) {
				return
			}
			if a.chunks[ci] == nil {
				a.chunks[ci] = make([]i16, CHUNK_FRAMES * 2)
			}
			off := (frames % CHUNK_FRAMES) * 2
			l, rr := samples[f * 2], samples[f * 2 + 1]
			a.chunks[ci][off], a.chunks[ci][off + 1] = l, rr
			frames += 1
			block_peak = max(block_peak, abs(i32(l)), abs(i32(rr)))
			block_n += 1
			if block_n == PEAK_BLOCK {
				pi := frames / PEAK_BLOCK - 1
				if pi < len(a.peaks) {
					a.peaks[pi] = u8(min(block_peak / 128, 255))
					intrinsics.atomic_store_explicit(&a.peak_count, pi + 1, .Release)
				}
				block_peak, block_n = 0, 0
			}
		}
		intrinsics.atomic_store_explicit(&a.frames, frames, .Release)
		carry = total - whole * 4
		mem.copy(raw_data(buf), raw_data(buf[whole * 4:]), carry)
	}
}

// Stops decoding and the mixer, then frees all audio. Called with the preview reset.
audio_reset :: proc() {
	sync.mutex_lock(&mixer.mu)
	mixer.count = 0
	sync.mutex_unlock(&mixer.mu)
	intrinsics.atomic_store_explicit(&mixer.playing, false, .Release)
	audio_was_playing = false
	for a in audios {
		if a != nil && a.thread != nil {
			_ = os.process_kill(a.process)
		}
	}
	for a in audios {
		if a == nil {continue}
		if a.thread != nil {
			thread.join(a.thread)
		}
		for c in a.chunks {
			delete(c)
		}
		delete(a.chunks)
		delete(a.peaks)
		free(a)
	}
	clear(&audios)
}

// ---------------------------------------------------------------- mixing

// Call every frame: hands the current clips to the audio thread.
audio_publish :: proc(p: Project) {
	sync.mutex_lock(&mixer.mu)
	defer sync.mutex_unlock(&mixer.mu)
	mixer.count = 0
	mixer.master = db_to_gain(p.settings.master_db)
	for c in p.clips {
		if c.kind != .Audio || c.source >= len(audios) || audios[c.source] == nil || mixer.count >= MAX_MIX_CLIPS || !track_audible(p, c.track) {
			continue
		}
		mixer.clips[mixer.count] = {audios[c.source], c.start, c.in_point, c.duration, c.speed, db_to_gain(c.gain_db)}
		mixer.count += 1
	}
}

// Starts/stops playback from `playhead` when `playing` changes.
audio_transport :: proc(playing: bool, playhead: f64) {
	if playing && !audio_was_playing {
		intrinsics.atomic_store_explicit(&mixer.pos, i64(playhead * AUDIO_RATE), .Release)
		intrinsics.atomic_store_explicit(&mixer.playing, true, .Release)
	} else if !playing && audio_was_playing {
		intrinsics.atomic_store_explicit(&mixer.playing, false, .Release)
	}
	audio_was_playing = playing
}

// Jumps the audio clock (loop playback).
audio_seek :: proc(t: f64) {
	intrinsics.atomic_store_explicit(&mixer.pos, i64(t * AUDIO_RATE), .Release)
}

// Timeline time according to the audio clock.
audio_time :: proc() -> f64 {
	return f64(intrinsics.atomic_load_explicit(&mixer.pos, .Acquire)) / AUDIO_RATE
}

// Peak levels (linear, 0..) since the last call.
audio_levels :: proc() -> (l, r: f32) {
	l = transmute(f32)intrinsics.atomic_exchange_explicit(&mixer.peak_l, 0, .Acq_Rel)
	r = transmute(f32)intrinsics.atomic_exchange_explicit(&mixer.peak_r, 0, .Acq_Rel)
	return
}

audio_callback :: proc "c" (device: ^ma.device, output, input: rawptr, frame_count: u32) {
	context = runtime.default_context()
	n := int(frame_count)
	out := ([^]f32)(output)[:n * 2]
	for &s in out {s = 0}
	if !intrinsics.atomic_load_explicit(&mixer.playing, .Acquire) {
		return
	}

	sync.mutex_lock(&mixer.mu)
	pos := int(intrinsics.atomic_load_explicit(&mixer.pos, .Acquire))
	for k in 0 ..< mixer.count {
		mix_clip(mixer.clips[k], pos, out, n)
	}
	master := mixer.master
	sync.mutex_unlock(&mixer.mu)

	pl, pr: f32
	for i in 0 ..< n {
		out[i * 2] *= master
		out[i * 2 + 1] *= master
		pl = max(pl, abs(out[i * 2]))
		pr = max(pr, abs(out[i * 2 + 1]))
	}
	atomic_max_f32(&mixer.peak_l, pl)
	atomic_max_f32(&mixer.peak_r, pr)
	intrinsics.atomic_store_explicit(&mixer.pos, i64(pos + n), .Release)
}

atomic_max_f32 :: proc "contextless" (p: ^u32, v: f32) {
	for {
		old := intrinsics.atomic_load_explicit(p, .Acquire)
		if v <= transmute(f32)old {
			return
		}
		if _, ok := intrinsics.atomic_compare_exchange_strong(p, old, transmute(u32)v); ok {
			return
		}
	}
}

mix_clip :: proc(c: Mix_Clip, pos: int, out: []f32, n: int) {
	if c.gain == 0 {
		return
	}
	cs := int(c.start * AUDIO_RATE)
	ce := int((c.start + c.duration) * AUDIO_RATE)
	lo, hi := max(pos, cs), min(pos + n, ce)
	avail := intrinsics.atomic_load_explicit(&c.src.frames, .Acquire)
	for fi in lo ..< hi {
		sf := (c.in_point + f64(fi - cs) / AUDIO_RATE * c.speed) * AUDIO_RATE // source frame (fractional)
		i0 := int(sf)
		if i0 < 0 || i0 + 1 >= avail {
			continue // not decoded yet
		}
		frac := f32(sf - f64(i0))
		l0, r0 := frame_at(c.src, i0)
		l1, r1 := frame_at(c.src, i0 + 1)
		o := (fi - pos) * 2
		out[o] += (l0 + (l1 - l0) * frac) * c.gain
		out[o + 1] += (r0 + (r1 - r0) * frac) * c.gain
	}
}

frame_at :: #force_inline proc(a: ^Audio_Source, i: int) -> (l, r: f32) {
	chunk := a.chunks[i / CHUNK_FRAMES]
	k := (i % CHUNK_FRAMES) * 2
	return f32(chunk[k]) * (1.0 / 32768), f32(chunk[k + 1]) * (1.0 / 32768)
}

// Waveform: largest peak (0..1) of source `src` between two source times.
peak_between :: proc(src: int, t0, t1: f64) -> f32 {
	if src >= len(audios) || audios[src] == nil {
		return 0
	}
	a := audios[src]
	count := intrinsics.atomic_load_explicit(&a.peak_count, .Acquire)
	i0 := max(int(t0 * AUDIO_RATE / PEAK_BLOCK), 0)
	i1 := max(int(t1 * AUDIO_RATE / PEAK_BLOCK), i0)
	best: u8
	for i in i0 ..= min(i1, count - 1) {
		best = max(best, a.peaks[i])
	}
	return f32(best) / 255
}
