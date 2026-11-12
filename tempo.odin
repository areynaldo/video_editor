package main

import "core:path/filepath"
import "core:slice"

import "vendor:glfw"

// Tempo commands of the project: the candidates the detection found, the audio clip it listens to,
// tap tempo. (The analysis itself is in bpm.odin.)

// What the tempo detection found, in timeline terms (see detect_project_bpm).
Bpm_Candidate :: struct {
	bpm:        f64,
	first_beat: f64, // timeline seconds
	confidence: f32,
}

bpm_cands: [BPM_CANDS]Bpm_Candidate
bpm_cand_n: int
bpm_cand_active := -1
bpm_src_clip := -1 // audio clip chosen in the Sequence panel; -1 = automatic
tap_times: [dynamic]f64

audio_clip_ok :: proc(i: int) -> bool {
	if i < 0 || i >= len(project.clips) {return false}
	c := project.clips[i]
	return c.kind == .Audio && c.source < len(audios) && audios[c.source] != nil
}

// Which audio clip to analyse: the one picked in the panel, else the selected one,
// else one on a selected layer, else the first.
bpm_source_clip :: proc() -> int {
	if audio_clip_ok(bpm_src_clip) {
		return bpm_src_clip
	}
	sel_clip, on_layer, first_clip := -1, -1, -1
	layers := selected_tracks(project)
	for c, i in project.clips {
		if !audio_clip_ok(i) {continue}
		if c.selected && sel_clip < 0 {sel_clip = i}
		if on_layer < 0 && slice.contains(layers, c.track) {on_layer = i}
		if first_clip < 0 {first_clip = i}
	}
	return sel_clip >= 0 ? sel_clip : (on_layer >= 0 ? on_layer : first_clip)
}

use_bpm_candidate :: proc(i: int) {
	if i < 0 || i >= bpm_cand_n {return}
	c := bpm_cands[i]
	s := &project.settings
	s.bpm, s.grid_offset = f32(c.bpm), c.first_beat
	s.grid_type, s.grid_on = .Beats, true
	bpm_cand_active = i
}

// Detects the tempo of the audio clip (see bpm_source_clip) and sets the beat grid
// from the best candidate. The other candidates stay in the Sequence panel to pick.
detect_project_bpm :: proc() {
	pick := bpm_source_clip()
	if pick < 0 {
		set_status("no audio clip to analyse")
		return
	}
	c := project.clips[pick]
	s := &project.settings
	cands, n, win0, ok := detect_bpm(audios[c.source], c.in_point, c.in_point + c.duration * c.speed, f64(s.bpm_lo), f64(s.bpm_hi))
	if !ok {
		set_status("need at least %.0f s of decoded audio in that clip (still decoding?)", BPM_MIN_SECONDS)
		return
	}
	for i in 0 ..< n {
		bpm_cands[i] = {cands[i].bpm / c.speed, c.start + ((win0 + cands[i].offset) - c.in_point) / c.speed, cands[i].confidence}
	}
	bpm_cand_n = n
	use_bpm_candidate(0)
	set_status("%s: %.1f bpm%s", filepath.base(project.sources[c.source].path), s.bpm, n > 1 ? " (other candidates in Sequence)" : "")
}

// Tap along with the music: the bpm is the average gap between your last taps.
tap_tempo :: proc() {
	now := glfw.GetTime()
	if len(tap_times) > 0 && now - tap_times[len(tap_times) - 1] > 2 {
		clear(&tap_times)
	}
	append(&tap_times, now)
	if len(tap_times) > 8 {
		ordered_remove(&tap_times, 0)
	}
	if len(tap_times) < 2 {
		set_status("tap tempo: keep tapping")
		return
	}
	bpm := 60 * f64(len(tap_times) - 1) / (tap_times[len(tap_times) - 1] - tap_times[0])
	s := &project.settings
	s.bpm = f32(clamp(bpm, 40, 260))
	s.grid_type, s.grid_on = .Beats, true
	set_status("tap tempo: %.1f bpm (%d taps)", s.bpm, len(tap_times))
}
