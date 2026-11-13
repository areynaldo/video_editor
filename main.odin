package main

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"

import im "deps/odin-imgui"
import "deps/odin-imgui/imgui_impl_glfw"
import "deps/odin-imgui/imgui_impl_opengl3"
import gl "vendor:OpenGL"
import "vendor:glfw"

PROJECT_EXT :: ".vproj"
PROJECT_FILTER :: "Project|*" + PROJECT_EXT + "|All files|*.*"
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

do_new :: proc() {
	preview_reset()
	project_reset(&project)
	project_path = ""
	playhead = 0
	history_reset()
	set_status("new project")
}

do_open :: proc() {
	path, ok := pick_file(false, "Open project", PROJECT_FILTER)
	if !ok {return}
	preview_reset()
	if err := load_project(&project, path); err != "" {
		set_status("%s", err)
		return
	}
	project_path = strings.clone(path)
	playhead = 0
	history_reset()
	set_status("opened %s", path)
}

do_save :: proc() {
	if project_path == "" {
		path, ok := pick_file(true, "Save project", PROJECT_FILTER, fmt.tprintf("%s%s", settings_name(&project.settings), PROJECT_EXT), PROJECT_EXT)
		if !ok {return}
		project_path = strings.clone(path)
	}
	set_status(save_project(project, project_path) ? "saved %s" : "could not save %s", project_path)
}

do_export :: proc() {
	ext := FORMAT_EXT[project.settings.format]
	path, ok := pick_file(true, "Export", fmt.tprintf("%s|*.%s|All files|*.*", ext, ext), fmt.tprintf("%s.%s", settings_name(&project.settings), ext), strings.concatenate({".", ext}, context.temp_allocator))
	if !ok {return}
	d := new(Export_Job)
	d.p, d.path = project, strings.clone(path)
	if !job_start("Exporting the video", export_work, export_finish, d) {
		delete(d.path)
		free(d)
	}
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
		if sel_part >= 0 && sel_part < len(project.parts) {duplicate_part(sel_part)} else if any_selected() {duplicate_selected(&project)} else {duplicate_selected_tracks(&project)}
	case .Delete: // a part, a program cut, else clips, else layers
		switch {
		case lyrics_selected() > 0: // the selected lyric lines
			#reverse for l, i in project.lyrics {
				if l.selected {ordered_remove(&project.lyrics, i)}
			}
			sel_lyric = -1
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
	case .Background_Color: bg_popup_open = true
	case .Select_All:
		clear_track_selection(&project)
		for &c in project.clips {
			c.selected = !track_has(project, c.track, .Locked)
		}
	case .Link:   link_selected(&project)
	case .Unlink: unlink_selected(&project)

	case .Split:        if !(sel_part >= 0 && split_part(sel_part, playhead)) {split_at(&project, playhead)}
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
	case .Smooth_Slowmo:
		open_slowmo_dialog(false)
	case .Enhance_Clips: prerender(&project, .Enhance)
	case .Slowmo_Enhance: open_slowmo_dialog(true)
	case .Lyrics_Panel: show_lyrics = true
	case .Lyric_Add:    lyric_add(&project, playhead)
	case .Lyric_Tap:    lyric_tap()
	case .Lyrics_Open:
		if path, ok := pick_file(false, "Open lyrics", "Lyrics|*.srt;*.lrc;*.txt|All files|*.*"); ok {
			show_lyrics = true
			set_status(lyrics_import(&project, path) ? "%d lyric lines" : "no lyrics found in %s", len(project.lyrics), path)
		}
	case .Lyrics_Transcribe:
		show_lyrics = true
		lyrics_align(true)
	case .Lyrics_Align:
		show_lyrics = true
		lyrics_align()
	case .Lyrics_Export:
		if len(project.lyrics) == 0 {
			set_status("no lyrics to export")
		} else if path, ok := pick_file(true, "Export lyrics", "SubRip|*.srt|LRC|*.lrc|ASS|*.ass|Text|*.txt", fmt.tprintf("%s.srt", settings_name(&project.settings))); ok {
			set_status(lyrics_export(project, path) ? "exported %s" : "could not write %s", path)
		}
	case .Lock:
		// the selected clips, else the selected layers; all locked already -> unlock
		all, n := true, 0
		for c in project.clips {
			if c.selected {
				n += 1
				all &&= c.locked
			}
		}
		if n > 0 {
			for &c in project.clips {
				if c.selected {c.locked = !all}
			}
			set_status("%d clip%s %s", n, n == 1 ? "" : "s", all ? "unlocked" : "locked")
		} else if len(selected_tracks(project)) > 0 {
			toggle_flag_on_selected(&project, .Locked)
			set_status("layers locked / unlocked")
		} else {
			set_status("select clips or layers to lock")
		}
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
