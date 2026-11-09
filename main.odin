package main

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:os"
import "core:slice"
import "core:path/filepath"
import "core:strings"

import im "deps/odin-imgui"
import "deps/odin-imgui/imgui_impl_glfw"
import "deps/odin-imgui/imgui_impl_opengl3"
import gl "vendor:OpenGL"
import "vendor:glfw"

PROJECT_EXT :: ".vproj"
MEDIA_FILTER :: "Media|*.mp4;*.mov;*.mkv;*.avi;*.webm;*.m4v;*.mp3;*.wav;*.flac;*.m4a;*.ogg|All files|*.*"

project: Project
project_path: string // "" = never saved
playhead: f64
checkpoint: f64 // where playback returns to on a double-tapped play: the last ruler / timeline click (0 at start)
last_play_press: f64 = -1
DOUBLE_TAP :: 0.3 // seconds
playing: bool
status: string
window: glfw.WindowHandle

set_status :: proc(format: string, args: ..any) {
	status = fmt.aprintf(format, ..args)
}

import_path :: proc(path: string) {
	if s, ok := probe(path); ok {
		add_source(&project, s)
		media_start(s, int(clamp(project.settings.fps, 1, 30))) // always, so proxies/audio stay parallel to sources
		set_status("imported %s", path)
	} else {
		set_status("could not read %s", path)
	}
}

on_drop :: proc "c" (_: glfw.WindowHandle, count: i32, paths: [^]cstring) {
	context = runtime.default_context()
	for i in 0 ..< int(count) {
		import_path(string(paths[i]))
	}
}

with_ext :: proc(path, ext: string) -> string {
	if filepath.ext(path) == "" {
		return strings.concatenate({path, ext})
	}
	return path
}

do_new :: proc() {
	preview_reset()
	project_reset(&project)
	project_path = ""
	playhead = 0
	history_reset()
	set_status("new project")
}

do_open :: proc() {
	paths := file_dialog(false, "Open project", "Project|*" + PROJECT_EXT + "|All files|*.*")
	if len(paths) == 0 {
		return
	}
	preview_reset()
	if err := load_project(&project, paths[0]); err != "" {
		set_status("%s", err)
		return
	}
	project_path = strings.clone(paths[0])
	playhead = 0
	history_reset()
	set_status("opened %s", paths[0])
}

do_save :: proc() {
	if project_path == "" {
		name := fmt.tprintf("%s%s", settings_name(&project.settings), PROJECT_EXT)
		paths := file_dialog(true, "Save project", "Project|*" + PROJECT_EXT + "|All files|*.*", name)
		if len(paths) == 0 {
			return
		}
		project_path = strings.clone(with_ext(paths[0], PROJECT_EXT))
	}
	set_status(save_project(project, project_path) ? "saved %s" : "could not save %s", project_path)
}

do_export :: proc() {
	ext := FORMAT_EXT[project.settings.format]
	name := fmt.tprintf("%s.%s", settings_name(&project.settings), ext)
	paths := file_dialog(true, "Export", fmt.tprintf("%s|*.%s|All files|*.*", ext, ext), name)
	if len(paths) == 0 {
		return
	}
	path := with_ext(paths[0], strings.concatenate({".", ext}, context.temp_allocator))
	set_status("exporting %s ...", path)
	set_status(export(project, path) ? "exported %s" : "export failed (see console): %s", path)
}

do_action :: proc(a: Action) {
	switch a {
	case .New_Project:  do_new()
	case .Open_Project: do_open()
	case .Save_Project: do_save()
	case .Import:
		for path in file_dialog(false, "Import media", MEDIA_FILTER, multi = true) {
			import_path(path)
		}
	case .Export: do_export()
	case .Quit:   glfw.SetWindowShouldClose(window, true)

	case .Undo:
		if drag == .None {undo()}
	case .Redo:
		if drag == .None {redo()}
	case .Duplicate:
		if any_selected() {duplicate_selected(&project)} else {duplicate_selected_tracks(&project)}
	case .Delete: // a part, a program cut, else clips, else layers
		switch {
		case sel_part >= 0 && sel_part < len(project.parts):
			ordered_remove(&project.parts, sel_part)
			sel_part = -1
		case sel_cut >= 0: // the selected program segments: their cuts go, so they merge into the one before
			for i := min(sel_cut2, len(project.program) - 1); i >= sel_cut; i -= 1 {
				cut_remove(&project, i)
			}
			clear_cut_sel()
		case any_selected(): remove_selected(&project)
		case:                remove_selected_tracks(&project)
		}
	case .Remove_Audio:
		n := remove_audio(&project)
		set_status("removed %d audio clip%s", n, n == 1 ? "" : "s")
	case .Remove_Video:
		n := remove_clips(&project, .Video)
		set_status("removed %d video clip%s", n, n == 1 ? "" : "s")
	case .Remove_Audio_Layers, .Remove_Video_Layers:
		n := remove_layers_of_kind(&project, a == .Remove_Video_Layers ? .Video : .Audio)
		set_status("removed %d %s layer%s", n, a == .Remove_Video_Layers ? "video" : "audio", n == 1 ? "" : "s")
	case .Select_All:
		clear_track_selection(&project)
		for &c in project.clips {
			c.selected = !track_has(project, c.track, .Locked)
		}
	case .Link:   link_selected(&project)
	case .Unlink: unlink_selected(&project)

	case .Split:        split_at(&project, playhead)
	case .Add_Layer:    add_track(&project)
	case .Remove_Layer: remove_selected_tracks(&project)
	case .Play:
		now := glfw.GetTime()
		if now - last_play_press < DOUBLE_TAP {
			do_action(.To_Checkpoint) // second press of a double-tap
			last_play_press = -1
		} else {
			playing = !playing
			last_play_press = now
		}
	case .To_Checkpoint:
		playing = false
		playhead = checkpoint
	case .Go_Start:
		playing = false
		playhead = 0
	case .Go_End:
		playing = false
		playhead = project_length(project)
	case .Step_Back, .Step_Forward:
		playing = false
		fps := f64(max(project.settings.fps, 1))
		playhead = max(math.round(playhead * fps) + (a == .Step_Forward ? 1 : -1), 0) / fps
	case .Toggle_Grid: project.settings.grid_on = !project.settings.grid_on
	case .Stretch, .No_Snap: // hold-only, see held()

	case .Tool_Select: tool = .Select
	case .Tool_Razor:  tool = .Razor
	case .Tool_Hand:   tool = .Hand
	case .Tool_Zoom:   tool = .Zoom

	case .Mark:
		i := cut_insert(&project, snap(playhead))
		select_cuts(i, i)
	case .Beat_Split: beat_split()
	case .Randomize:  run_randomize()
	case .Randomize_Options: show_randomize = true
	case .Apply_Pattern:  apply_pattern()
	case .Pattern_Editor: show_patterns = true
	case .Slice_At_Cuts:
		n := slice_at_cuts(&project)
		set_status("sliced: %d clips added", n)
	case .Clear_Cuts: // the selected range, else all
		if t0, t1, ok := program_range(); ok {
			#reverse for c, i in project.program {
				if c.time >= t0 - CUT_EPS && c.time < t1 - CUT_EPS {cut_remove(&project, i)}
			}
		} else {
			clear(&project.program)
		}
		clear_cut_sel()
	case .Copy_Cuts:
		if t0, t1, ok := program_range(); ok {
			copy_cuts(project, t0, t1)
			set_status("copied %d cuts (%.2fs)", len(cut_clip.cuts), t1 - t0)
		} else {
			set_status("select a range in the program row first")
		}
	case .Paste_Cuts:
		dest := snap(playhead)
		if end, ok := paste_cuts(&project, dest); ok {
			select_cuts(segment_at(project, dest), segment_at(project, end - CUT_EPS))
			set_status("pasted %d cuts at %.2fs", len(cut_clip.cuts), dest)
		} else {
			set_status("nothing copied: select a range and copy it first")
		}
	case .Repeat_Range:
		if t0, t1, ok := program_range(); ok {
			copy_cuts(project, t0, t1)
			n := repeat_cuts(&project, t1, project_length(project))
			select_cuts(segment_at(project, t0), segment_at(project, t1 - CUT_EPS))
			set_status("repeated the range %d times", n)
		} else {
			set_status("select a range in the program row first")
		}
	case .Loop_Playback:
		loop_playback = !loop_playback
		set_status(loop_playback ? "looping the selected range while playing" : "loop off")
	case .Detect_Bpm: detect_project_bpm()
	case .Tap_Tempo:  tap_tempo()
	case .Grid_Here:
		s := &project.settings
		s.grid_offset = playhead
		s.grid_on = true
		set_status("beat grid starts at %.3fs", playhead)
	case .Layer_1 ..= .Layer_9: show_layer(int(a) - int(Action.Layer_1))

	case .Command_Palette: open_palette()
	case .Reload_Keys:
		status = strings.clone(load_keys())
		if status == "" {status = "keybindings reloaded"}
	}
}

// Randomize: fill the slots of a rhythm with slices of footage on a new layer (see
// rearrange.odin). The slicing comes from Rand_Options.slice: the program's cuts, the
// pattern (each part's own pattern if the project has parts), or the grid. A selected
// program range limits it to that range.
run_randomize :: proc() {
	s := project.settings
	step, _ := grid_step(s)
	spacing, origin := step * f64(max(s.cut_every, 1)), grid_origin(s)
	cands := rearrange_candidates(project)
	if len(cands) == 0 {
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

	res := rearrange(&project, s.rand, cands, times[:], pins[:], lo, hi)
	if res.cells == 0 {
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
	clear_cut_sel()
	set_status("randomized: %d slices in %d clips on a new layer%s", res.cells, res.clips, res.empty > 0 ? fmt.tprintf(" (%d empty slots)", res.empty) : "")
}

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

// Cut on the grid inside the selected segment, or the whole project.
beat_split :: proc() {
	s := project.settings
	step, _ := grid_step(s)
	from, to := 0.0, project_length(project)
	if t0, t1, ok := program_range(); ok {
		from, to = t0, t1
	}
	program_split_grid(&project, from, to, step * f64(max(s.cut_every, 1)), grid_origin(s))
	clear_cut_sel()
}

// Show the n-th (0-based) video layer. While playing: from the playhead on (a cut
// is made there, snapped to the grid). Otherwise: on the selected segment, or the
// one under the playhead.
show_layer :: proc(n: int) {
	layers := video_layers(project)
	if n >= len(layers) {
		set_status("there is no video layer %d", n + 1)
		return
	}
	if !playing && sel_cut >= 0 { // the whole selected range
		for k in sel_cut ..= min(sel_cut2, len(project.program) - 1) {
			project.program[k].layer, project.program[k].fixed = layers[n], true
		}
		return
	}
	i: int
	if playing {
		i = cut_insert(&project, snap(playhead))
	} else {
		i = segment_at(project, playhead)
		if i < 0 {
			i = cut_insert(&project, snap(playhead))
		}
	}
	project.program[i].layer, project.program[i].fixed = layers[n], true // a layer picked by hand is kept by Randomize
	select_cuts(i, i)
}

any_selected :: proc() -> bool {
	for c in project.clips {
		if c.selected {return true}
	}
	return false
}

main :: proc() {
	assert(bool(glfw.Init()))
	defer glfw.Terminate()

	glfw.WindowHint(glfw.CONTEXT_VERSION_MAJOR, 3)
	glfw.WindowHint(glfw.CONTEXT_VERSION_MINOR, 2)
	glfw.WindowHint(glfw.OPENGL_PROFILE, glfw.OPENGL_CORE_PROFILE)
	glfw.WindowHint(glfw.OPENGL_FORWARD_COMPAT, 1)

	window = glfw.CreateWindow(1280, 720, "video editor", nil, nil)
	assert(window != nil)
	defer glfw.DestroyWindow(window)
	glfw.MakeContextCurrent(window)
	glfw.SwapInterval(1)
	glfw.SetDropCallback(window, on_drop)
	gl.load_up_to(3, 2, proc(p: rawptr, name: cstring) {
		(cast(^rawptr)p)^ = glfw.GetProcAddress(name)
	})

	im.CHECKVERSION()
	im.CreateContext()
	defer im.DestroyContext()
	im.GetIO().ConfigFlags += {.NavEnableKeyboard, .DockingEnable}
	im.StyleColorsDark()

	imgui_impl_glfw.InitForOpenGL(window, true)
	defer imgui_impl_glfw.Shutdown()
	imgui_impl_opengl3.Init("#version 150")
	defer imgui_impl_opengl3.Shutdown()

	project_reset(&project)
	history_reset()
	status = strings.clone(load_keys())
	audio_init()
	defer audio_shutdown()
	preview_init()
	defer preview_reset()
	if len(os.args) > 1 { // editor.exe project.vproj
		if err := load_project(&project, os.args[1]); err == "" {
			project_path = strings.clone(os.args[1])
			history_reset()
		} else {
			status = strings.clone(err)
		}
	}

	for !glfw.WindowShouldClose(window) {
		glfw.PollEvents()
		imgui_impl_opengl3.NewFrame()
		imgui_impl_glfw.NewFrame()
		im.NewFrame()

		frame()
		free_all(context.temp_allocator)

		im.Render()
		w, h := glfw.GetFramebufferSize(window)
		gl.Viewport(0, 0, w, h)
		gl.ClearColor(0.08, 0.08, 0.08, 1)
		gl.Clear(gl.COLOR_BUFFER_BIT)
		imgui_impl_opengl3.RenderDrawData(im.GetDrawData())
		glfw.SwapBuffers(window)
	}
}