package main

import "core:math"

// Data model. Plain arrays of plain structs, no pointers, no ownership.
// A Clip is a window into a Source placed on the timeline.

Clip_Kind :: enum u8 {
	Video,
	Audio,
}

Source :: struct {
	path:      string,
	duration:  f64, // seconds
	has_video: bool,
	has_audio: bool,
}

Clip :: struct {
	source:   int, // index into Project.sources
	kind:     Clip_Kind,
	track:    int, // layer. higher = on top
	start:    f64, // position on timeline, seconds
	in_point: f64, // offset into source, seconds
	duration: f64, // seconds on the timeline
	speed:    f64, // source seconds per timeline second (1 = normal). source span = duration * speed
	group:    int, // 0 = not linked. clips sharing a group move/split/delete together
	selected: bool,
	// transform (video clips). applied after fitting the source into the canvas
	pos:      [2]f32, // offset from canvas center, in canvas pixels
	scale:    f32,    // 1 = fit
	rotation: f32,    // degrees, clockwise
	gain_db:  f32,    // audio clips: volume in dB (0 = unchanged, <= -60 = silent)
}

Export_Format :: enum i32 {
	MP4,
	MKV,
	WebM,
	MOV,
}

FORMAT_EXT := [Export_Format]string {
	.MP4  = "mp4",
	.MKV  = "mkv",
	.WebM = "webm",
	.MOV  = "mov",
}

Settings :: struct {
	name:          [64]u8, // project name, also the default export file name
	fps:           i32,
	width, height: i32, // export canvas
	format:        Export_Format,
	// timeline grid: lines + snapping while dragging / scrubbing
	grid_on:       bool,
	grid_type:     Grid_Type,
	bpm:           f32,
	grid_div:      i32, // beats grid: lines per beat (1, 2, 4, 8, 16)
	cut_every:     i32, // "split on grid" puts a cut every this many grid lines
	master_db:     f32, // master volume
	grid_offset:   f64, // seconds: where the grid starts (the first beat of the music)
	rand:          Rand_Options, // the Randomize command
	bg:            [3]f32, // background colour of the picture (r, g, b: 0..1)
	pattern_sel:   i32, // current cutting pattern
	bpm_lo:        f32, // tempo detection only looks for tempos in this range
	bpm_hi:        f32,
}

Grid_Type :: enum i32 {
	Seconds,
	Frames,
	Beats,
}

// Distance between grid lines in seconds, and how many lines make a "major" line.
grid_step :: proc(s: Settings) -> (step: f64, major: int) {
	switch s.grid_type {
	case .Seconds: return 1, 5
	case .Frames:  return 1 / f64(max(s.fps, 1)), int(max(s.fps, 1))
	case .Beats:   return 60 / f64(max(s.bpm, 1)) / f64(max(s.grid_div, 1)), int(max(s.grid_div, 1))
	}
	return 1, 5
}

snap_time :: proc(s: Settings, t: f64) -> f64 {
	step, _ := grid_step(s)
	origin := grid_origin(s)
	r := origin + math.round((t - origin) / step) * step
	return r < 0 ? r + step : r
}

// Time of the grid line that all grid lines (and the major lines) are counted
// from, normalized into [0, one major period). For beats: the first beat.
grid_origin :: proc(s: Settings) -> f64 {
	step, major := grid_step(s)
	period := step * f64(major)
	return math.mod(max(s.grid_offset, 0), period)
}

Project :: struct {
	sources:     [dynamic]Source,
	clips:       [dynamic]Clip,
	track_count: int,
	next_group:  int, // last group id handed out
	settings:    Settings,
	program:     [dynamic]Cut, // which layer is shown when, sorted by time. see program.odin
	track_flags: [dynamic]Track_Flags, // per track; kept as long as track_count (sync_tracks)
	patterns:    [dynamic]Pattern, // cutting patterns, see patterns.odin
	parts:       [dynamic]Part, // time ranges with their own pattern
}

Track_Flag :: enum u8 {
	Hidden, // video on this track is not shown / exported
	Muted,  // audio on this track is silent
	Locked, // clips on this track can't be picked or cut
	Solo,   // if any track is soloed, only soloed tracks are heard
	Selected, // selected in the timeline (multi-select); not part of undo
}
Track_Flags :: bit_set[Track_Flag;u8]

// Makes track_flags match track_count (call before using flags).
sync_tracks :: proc(p: ^Project) {
	for len(p.track_flags) < p.track_count {
		append(&p.track_flags, Track_Flags{})
	}
	for len(p.track_flags) > p.track_count {
		pop(&p.track_flags)
	}
}

track_has :: proc(p: Project, track: int, f: Track_Flag) -> bool {
	return track >= 0 && track < len(p.track_flags) && f in p.track_flags[track]
}

any_solo :: proc(p: Project) -> bool {
	for f in p.track_flags {
		if .Solo in f {return true}
	}
	return false
}

// Is audio on this track heard (not muted, and soloed if anything is soloed)?
track_audible :: proc(p: Project, track: int) -> bool {
	return !track_has(p, track, .Muted) && (!any_solo(p) || track_has(p, track, .Solo))
}

// From `time` until the next cut, show only video `layer` (-1 = no override: all
// video layers are composited as usual). Before the first cut nothing is overridden.
Cut :: struct {
	time:  f64,
	layer: int,
	fixed: bool, // the layer was set by a pattern lane: Randomize leaves it alone
}

project_reset :: proc(p: ^Project) {
	delete(p.sources)
	delete(p.clips)
	delete(p.program)
	delete(p.track_flags)
	delete(p.patterns)
	delete(p.parts)
	p^ = {}
	p.settings = {
		fps    = 30,
		width  = 1920,
		height = 1080,
		format = .MP4,
		grid_on = true,
		grid_type = .Seconds,
		bpm = 120,
		grid_div = 4,
		cut_every = 1,
		bg = {0, 0, 0},
		bpm_lo = 80,
		bpm_hi = 180,
		rand = {footage = .Same_Time, slice = .Cuts, pattern = -1, max_run = 1},
	}
	set_name(&p.settings, "untitled")
}

set_name :: proc(s: ^Settings, name: string) {
	s.name = {}
	copy(s.name[:len(s.name) - 1], name)
}

settings_name :: proc(s: ^Settings) -> string {
	return string(cstring(&s.name[0]))
}

MIN_DURATION :: 0.05

clip_end :: proc(c: Clip) -> f64 {
	return c.start + c.duration
}

project_length :: proc(p: Project) -> f64 {
	end: f64
	for c in p.clips {
		end = max(end, clip_end(c))
	}
	return end
}

new_group :: proc(p: ^Project) -> int {
	p.next_group += 1
	return p.next_group
}

// Adds the source and places it at t=0 on new tracks (see place_source).
add_source :: proc(p: ^Project, s: Source) {
	append(&p.sources, s)
	place_source(p, len(p.sources) - 1, 0, -1)
}

// Puts one clip per stream of source `idx` on the timeline at `start`. Video and
// audio of one file are linked and go on new tracks (audio under video). A source
// with a single stream dropped onto an existing track `lane` goes there instead.
place_source :: proc(p: ^Project, idx: int, start: f64, lane: int) {
	s := p.sources[idx]
	mk :: proc(idx: int, kind: Clip_Kind, track: int, start, dur: f64, group: int) -> Clip {
		return Clip{source = idx, kind = kind, track = track, start = start, duration = dur, speed = 1, scale = 1, group = group}
	}
	if s.has_video != s.has_audio && lane >= 0 && lane < p.track_count {
		append(&p.clips, mk(idx, s.has_video ? .Video : .Audio, lane, start, s.duration, 0))
		return
	}
	group := (s.has_video && s.has_audio) ? new_group(p) : 0
	if s.has_audio {
		append(&p.clips, mk(idx, .Audio, p.track_count, start, s.duration, group))
		p.track_count += 1
	}
	if s.has_video {
		append(&p.clips, mk(idx, .Video, p.track_count, start, s.duration, group))
		p.track_count += 1
	}
}

// ---- cutting ----

// Cuts clip i at timeline time t. Returns the new right-hand clip's index, or -1
// if t is not strictly inside the clip. The right half keeps the group (caller remaps).
split_clip :: proc(p: ^Project, i: int, t: f64) -> int {
	c := p.clips[i]
	if t <= c.start || t >= clip_end(c) {
		return -1
	}
	p.clips[i].duration = t - c.start
	right := c
	right.start = t
	right.in_point = c.in_point + (t - c.start) * c.speed
	right.duration = c.duration - (t - c.start)
	append(&p.clips, right)
	return len(p.clips) - 1
}

// Splits every selected clip under t (or every clip under t if none is selected).
// Left halves stay in their group, right halves form a new group per old group.
split_at :: proc(p: ^Project, t: f64) {
	any_selected := false
	for c in p.clips {
		any_selected ||= c.selected
	}
	remap := make(map[int]int, context.temp_allocator)
	n := len(p.clips) // new clips are appended; don't re-split them
	for i in 0 ..< n {
		if track_has(p^, p.clips[i].track, .Locked) {
			continue
		}
		if any_selected && !p.clips[i].selected {
			continue
		}
		r := split_clip(p, i, t)
		if r >= 0 {
			p.clips[r].group = remap_group(p, &remap, p.clips[r].group)
		}
	}
}

// Moves the left edge by d seconds (clamped). Positive d shortens the clip.
trim_left :: proc(p: ^Project, i: int, d: f64) {
	c := &p.clips[i]
	d := d
	d = max(d, -c.in_point / c.speed, -c.start)
	d = min(d, c.duration - MIN_DURATION)
	c.start += d
	c.in_point += d * c.speed
	c.duration -= d
}

// Moves the right edge by d seconds (clamped). Positive d lengthens the clip.
trim_right :: proc(p: ^Project, i: int, d: f64) {
	c := &p.clips[i]
	d := d
	d = max(d, MIN_DURATION - c.duration)
	d = min(d, (p.sources[c.source].duration - c.in_point) / c.speed - c.duration)
	c.duration += d
}

MIN_SPEED :: 0.1
MAX_SPEED :: 10.0

// Like trim_left/right but the same part of the source is kept and played faster
// or slower to fill the new length.
stretch_left :: proc(p: ^Project, i: int, d: f64) {
	c := &p.clips[i]
	span := c.duration * c.speed
	new_dur := clamp(c.duration - d, span / MAX_SPEED, span / MIN_SPEED)
	new_dur = max(new_dur, MIN_DURATION)
	new_dur = min(new_dur, c.duration + c.start) // can't start before 0
	c.start += c.duration - new_dur
	c.duration = new_dur
	c.speed = span / new_dur
}

stretch_right :: proc(p: ^Project, i: int, d: f64) {
	c := &p.clips[i]
	span := c.duration * c.speed
	new_dur := clamp(c.duration + d, span / MAX_SPEED, span / MIN_SPEED)
	c.duration = max(new_dur, MIN_DURATION)
	c.speed = span / c.duration
}

// ---- selection / groups ----

clear_selection :: proc(p: ^Project) {
	for &c in p.clips {
		c.selected = false
	}
}

// Sets selection of clip i and everything linked to it.
set_selected :: proc(p: ^Project, i: int, on: bool) {
	g := p.clips[i].group
	for &c, j in p.clips {
		if j == i || (g != 0 && c.group == g) {
			c.selected = on
		}
	}
}

link_selected :: proc(p: ^Project) {
	g := new_group(p)
	count := 0
	for c in p.clips {
		count += c.selected ? 1 : 0
	}
	if count < 2 {
		return
	}
	for &c in p.clips {
		if c.selected {
			c.group = g
		}
	}
}

unlink_selected :: proc(p: ^Project) {
	for &c in p.clips {
		if c.selected {
			c.group = 0
		}
	}
}

remove_selected :: proc(p: ^Project) {
	#reverse for c, i in p.clips {
		if c.selected {
			ordered_remove(&p.clips, i)
		}
	}
}

// ---- duplicating ----

// Copies selected clips right after the selection (same tracks). Copies become
// the selection. Linked clips stay linked to their own copies.
duplicate_selected :: proc(p: ^Project) {
	lo, hi := max(f64), min(f64)
	for c in p.clips {
		if c.selected {
			lo, hi = min(lo, c.start), max(hi, clip_end(c))
		}
	}
	if lo > hi {
		return
	}
	remap := make(map[int]int, context.temp_allocator)
	n := len(p.clips)
	for i in 0 ..< n {
		if !p.clips[i].selected {
			continue
		}
		copy_ := p.clips[i]
		copy_.start += hi - lo
		copy_.group = remap_group(p, &remap, copy_.group)
		p.clips[i].selected = false
		append(&p.clips, copy_)
	}
}

// Copies a whole track (with its clips) into a new track just above it.
duplicate_track :: proc(p: ^Project, t: int) -> int {
	if t < 0 || t >= p.track_count {
		return -1
	}
	for &c in p.clips {
		if c.track > t {
			c.track += 1
		}
	}
	remap := make(map[int]int, context.temp_allocator)
	n := len(p.clips)
	for i in 0 ..< n {
		if p.clips[i].track == t {
			copy_ := p.clips[i]
			copy_.track = t + 1
			copy_.group = remap_group(p, &remap, copy_.group)
			append(&p.clips, copy_)
		}
	}
	sync_tracks(p)
	inject_at(&p.track_flags, t + 1, p.track_flags[t] - {.Selected}) // the copy inherits hidden/muted/locked, but is not selected
	p.track_count += 1
	return t + 1
}

remap_group :: proc(p: ^Project, remap: ^map[int]int, g: int) -> int {
	if g == 0 {
		return 0
	}
	if g not_in remap {
		remap[g] = new_group(p)
	}
	return remap[g]
}

// ---- layers ----

add_track :: proc(p: ^Project) {
	p.track_count += 1
}

// Deletes the track and its clips; tracks above shift down.
remove_track :: proc(p: ^Project, t: int) {
	if t < 0 || t >= p.track_count {
		return
	}
	#reverse for c, i in p.clips {
		if c.track == t {
			ordered_remove(&p.clips, i)
		}
	}
	for &c in p.clips {
		if c.track > t {
			c.track -= 1
		}
	}
	sync_tracks(p)
	ordered_remove(&p.track_flags, t)
	p.track_count -= 1
}

// ---- multi-selected layers ----

selected_tracks :: proc(p: Project) -> []int {
	out := make([dynamic]int, context.temp_allocator)
	for f, i in p.track_flags {
		if .Selected in f {append(&out, i)}
	}
	return out[:]
}

clear_track_selection :: proc(p: ^Project) {
	for &f in p.track_flags {
		f -= {.Selected}
	}
}

remove_selected_tracks :: proc(p: ^Project) {
	sel := selected_tracks(p^)
	#reverse for t in sel { // from the top, so the indices still to do don't shift
		remove_track(p, t)
	}
}

duplicate_selected_tracks :: proc(p: ^Project) {
	sel := selected_tracks(p^)
	#reverse for t in sel {
		duplicate_track(p, t)
	}
}

// Sets `flag` on every selected layer, or clears it if they all have it already.
toggle_flag_on_selected :: proc(p: ^Project, flag: Track_Flag) {
	sel := selected_tracks(p^)
	all_set := len(sel) > 0
	for t in sel {
		all_set &&= flag in p.track_flags[t]
	}
	for t in sel {
		if all_set {
			p.track_flags[t] -= {flag}
		} else {
			p.track_flags[t] += {flag}
		}
		if flag == .Locked && !all_set { // locking drops the layer's clips from the selection
			for &c in p.clips {
				if c.track == t {c.selected = false}
			}
		}
	}
}

// ---- randomize options ----

// Randomize fills every slot of a rhythm with a slice of footage on a new layer. The
// slicing says where the slots are; these say what goes into them.
Rand_Footage :: enum u8 {
	Same_Time, // the footage that plays at the slot's own time (a cut-away between the clips)
	In_Order,  // each clip plays forward: its next piece
	Any_Piece, // a random piece of the clip
}

// Where Randomize slices (the slots).
Rand_Slice :: enum u8 {
	Cuts,    // the cuts the program already has (e.g. from an applied pattern); the grid if there are none
	Pattern, // the hits of the pattern (of each part, if the project has parts)
	Grid,    // the beat grid (cut every N lines)
}

Rand_Options :: struct {
	footage: Rand_Footage,
	slice:   Rand_Slice,
	pattern: i32,  // for slice = Pattern without parts: index of the pattern, -1 = the current one
	use_all: bool, // go on (the rhythm loops) until every piece of footage is used; In_Order and Any_Piece only
	max_run: i32,  // most consecutive slots filled from the same clip; 0 = no limit
}

// A time range of the project that has its own pattern.
Part :: struct {
	t0, t1:  f64,
	pattern: i32, // index into Project.patterns, -1 = none
}
