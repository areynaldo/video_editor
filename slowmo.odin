package main

import "core:fmt"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"

import im "deps/odin-imgui"

// Prerender: a clip is rendered ONCE into a file in the cache folder, and the clip then
// plays that file at speed 1. The files are reused. Two kinds:
//   Smooth slow-mo  a slowed clip only repeats frames; this makes new in-between frames
//     RIFE (ML)         rife-ncnn-vulkan.exe in tools\ or PATH: the best result, on the GPU
//     ffmpeg            the minterpolate filter, no extra tool: slower, more artifacts
//   Enhance         upscale 2x, denoise, sharpen, fix the levels
//     Real-ESRGAN (ML)  realesrgan-ncnn-vulkan.exe in tools\ or PATH
//     ffmpeg            lanczos, hqdn3d, unsharp, normalize
// The video is rendered without sound (sound is a separate clip that keeps its atempo).
// The renders are background jobs with a progress bar: see jobs.odin.

CACHE_DIR :: "cache"

Prerender_Mode :: enum {
	Slowmo, // new in-between frames for a slowed clip
	Enhance, // upscale 2x, denoise, sharpen, fix the levels
	Both, // slow-mo and enhance in one pass: denoise, interpolate, upscale
}

find_in_tools :: proc(name: string) -> string {
	for f in ([?]string{fmt.tprintf("tools\\%s", name), name}) {
		if os.exists(f) {return f}
	}
	return ""
}

// Vulkan device for the ML tools: tools\gpu.txt holds its number (0, 1, ...). Without the file the tool picks its own (a discrete GPU first).
gpu_args :: proc() -> []string {
	data, err := os.read_entire_file("tools\\gpu.txt", context.temp_allocator)
	if err != nil {return {}}
	id := strings.trim_space(string(data))
	if id == "" {return {}}
	out := make([]string, 2, context.temp_allocator)
	out[0], out[1] = "-g", id
	return out
}

find_rife :: proc() -> string {return find_in_tools("rife-ncnn-vulkan.exe")}
find_esrgan :: proc() -> string {return find_in_tools("realesrgan-ncnn-vulkan.exe")}

PRERENDER_TAG := [Prerender_Mode]string{.Slowmo = "slow", .Enhance = "enh", .Both = "both"}
PRERENDER_TITLE := [Prerender_Mode]string{.Slowmo = "Rendering smooth slow-mo", .Enhance = "Enhancing and upscaling", .Both = "Rendering slow-mo and enhancing"}

DENOISE :: "hqdn3d=1.5:1.5:4:4"
SHARPEN :: "unsharp=5:5:0.7,eq=saturation=1.08"

count_files :: proc(dir: string) -> int {
	infos, err := os.read_directory_by_path(dir, -1, context.temp_allocator)
	return err == nil ? len(infos) : 0
}

// The frame-folder way (RIFE, Real-ESRGAN): ffmpeg cuts the clip into image files, each ML
// stage makes new files from the ones before, ffmpeg joins the last ones into `out`.
// `retime` is the ffmpeg filter that makes the first frames. `stages` are the ML commands
// with {in} and {out} where the folders go; `counts[i]` = how many files stage i makes (for
// the bar). The frames are png (no loss between the steps; jpg lost quality at every one). The cut uses the fastest png setting (every frame is
// encoded and decoded by the CPU, and a 4K png takes a good part of a second).
// Returns how long each step took (to see what is slow), and an error text.
frames_pipeline :: proc(c: Clip, src, out, tag: string, fps: int, retime: string, stages: [][]string, counts: []int) -> (timings, err: string) {
	id := fmt.tprintf("%s\\%s_%d", CACHE_DIR, tag, int(c.in_point * 1000))
	dirs := make([]string, len(stages) + 1, context.temp_allocator)
	for &dir, i in dirs {
		dir = fmt.tprintf("%s_%d", id, i)
		_ = os.make_directory(dir)
	}
	defer {for dir in dirs {os.remove_all(dir)}}
	tb: strings.Builder
	strings.builder_init(&tb, context.temp_allocator)
	lap := time.tick_now()
	note :: proc(tb: ^strings.Builder, lap: ^time.Tick, what: string) {
		fmt.sbprintf(tb, "%s%s %.0fs", strings.builder_len(tb^) > 0 ? ", " : "", what, time.duration_seconds(time.tick_lap_time(lap)))
	}

	job_step("cutting the clip into frames ...")
	if msg := ffmpeg_tracked({"-ss", fmt.tprintf("%.3f", c.in_point), "-t", fmt.tprintf("%.3f", c.duration * c.speed), "-i", src, "-an", "-fps_mode", "passthrough", "-vf", retime, "-pix_fmt", "rgb24", "-compression_level", "1", strings.concatenate({dirs[0], "\\%08d.png"}, context.temp_allocator)}, c.duration, 0, 0.08); msg != "" {
		return "", msg
	}
	note(&tb, &lap, "cut")
	share := 0.8 / f32(len(stages))
	for stage, i in stages {
		cmd := make([dynamic]string, context.temp_allocator)
		for a in stage {
			x, _ := strings.replace_all(a, "{in}", dirs[i], context.temp_allocator)
			x, _ = strings.replace_all(x, "{out}", dirs[i + 1], context.temp_allocator)
			append(&cmd, x)
		}
		name := filepath.stem(stage[0])
		job_step("%s (%d of %d) is making the new frames ...", name, i + 1, len(stages))
		lo := 0.08 + share * f32(i)
		if msg := run_tracked(cmd[:], {.Frames, dirs[i + 1], f64(counts[i])}, lo, lo + share); msg != "" {
			return "", msg
		}
		// the tools can end "fine" with frames missing (the GPU ran out of memory): once more with one frame at a time
		if made := count_files(dirs[i + 1]); made < counts[i] {
			for k in 0 ..< len(cmd) - 1 {
				if cmd[k] == "-j" {cmd[k + 1] = "1:1:1"}
			}
			job_step("%s ran short of memory: trying again, one frame at a time ...", name)
			os.remove_all(dirs[i + 1])
			_ = os.make_directory(dirs[i + 1])
			if msg := run_tracked(cmd[:], {.Frames, dirs[i + 1], f64(counts[i])}, lo, lo + share); msg != "" {
				return "", msg
			}
			if made = count_files(dirs[i + 1]); made < counts[i] {
				return "", fmt.tprintf("%s made %d of %d frames. The GPU has too little memory for frames this big: use a smaller project size, or close other programs that use the GPU.", name, made, counts[i])
			}
		}
		note(&tb, &lap, name)
		os.remove_all(dirs[i]) // the frames before this stage are not needed any more
	}
	job_step("encoding the video ...")
	if msg := ffmpeg_tracked({"-framerate", fmt.tprintf("%d", fps), "-i", strings.concatenate({dirs[len(stages)], "\\%08d.png"}, context.temp_allocator), "-c:v", "libx264", "-crf", "12", "-preset", "medium", "-pix_fmt", "yuv420p", out}, f64(counts[len(counts) - 1]) / f64(fps), 0.88, 1); msg != "" {
		return "", msg
	}
	note(&tb, &lap, "encode")
	return strings.clone(strings.to_string(tb), context.temp_allocator), ""
}
// ffmpeg's interpolation (minterpolate) uses one core. So the clip is cut into as many
// pieces as there are cores, every piece is rendered by its own ffmpeg at the same time
// (with a little extra footage around it, so the interpolation is right at the edges),
// and the pieces are joined. `pre` / `tail` are filters before / after the interpolation.
// Returns how many pieces, or an error text.
render_segments :: proc(c: Clip, src, out: string, fps: int, pre, tail: string) -> (pieces: int, err: string) {
	PAD :: 0.4 // seconds of source around each piece
	nf := max(int(math.round(c.duration * f64(fps))), 1)
	k := max(min(clamp(os.get_processor_core_count(), 1, 8), nf / 30), 1)
	cmds := make([][]string, k, context.temp_allocator)
	files := make([]string, k, context.temp_allocator)
	secs := make([]f64, k, context.temp_allocator)
	segs := make([]string, k, context.temp_allocator)
	defer {for s in segs {os.remove(s)}}
	f0 := 0
	for j in 0 ..< k {
		f1 := f0 + nf / k + (j < nf % k ? 1 : 0)
		a, b := f64(f0) / f64(fps), f64(f1) / f64(fps)
		piece_start := c.in_point + a * c.speed
		src_start := max(piece_start - PAD, 0)
		lead := piece_start - src_start // source seconds before the piece
		src_len := (b - a) * c.speed + lead + PAD
		segs[j] = fmt.tprintf("%s.seg%d.mp4", out, j)
		files[j] = fmt.tprintf("job_progress_%d.txt", j)
		secs[j] = b - a
		vf := fmt.tprintf(
			"tpad=stop_mode=clone:stop_duration=0.5,setpts=PTS/%.6f,%sminterpolate=fps=%d:mi_mode=mci:mc_mode=aobmc:me_mode=bidir:vsbmc=1,trim=start=%.6f:duration=%.6f,setpts=PTS-STARTPTS%s",
			c.speed, pre, fps, lead / c.speed, b - a, tail,
			)
		cmd := make([dynamic]string, context.temp_allocator)
		append(&cmd, "ffmpeg", "-y", "-v", "error", "-nostdin", "-progress", files[j], "-ss", fmt.tprintf("%.3f", src_start), "-t", fmt.tprintf("%.3f", src_len), "-i", src, "-an", "-vf", vf)
		append(&cmd, "-c:v", "libx264", "-crf", "12", "-preset", "medium", "-pix_fmt", "yuv420p", segs[j])
		cmds[j] = cmd[:]
		f0 = f1
	}
	job_step("interpolating with ffmpeg on %d cores (a GPU tool like RIFE is much faster) ...", k)
	if msg := run_parallel(cmds, files, secs, 0, 0.95); msg != "" {
		return 0, msg
	}
	list := fmt.tprintf("%s.list.txt", out)
	defer os.remove(list)
	b: strings.Builder
	strings.builder_init(&b, context.temp_allocator)
	for s in segs {
		slashed, _ := strings.replace_all(s, "\\", "/", context.temp_allocator)
		fmt.sbprintf(&b, "file '%s'\n", slashed)
	}
	_ = os.write_entire_file(list, transmute([]byte)strings.to_string(b))
	job_step("joining the pieces ...")
	if msg := run_tracked({"ffmpeg", "-y", "-v", "error", "-nostdin", "-f", "concat", "-safe", "0", "-i", list, "-c", "copy", out}, {}, 0.95, 1); msg != "" {
		return 0, msg
	}
	return k, ""
}

// How much bigger than the source the picture must be to fill the project's canvas: 1 (no
// upscaling: the source is big enough), 2, or 4. An upscale the export would shrink again
// is the most expensive step of all and gains nothing, so it is skipped.
upscale_factor :: proc(src_h, canvas_h: int) -> int {
	if src_h <= 0 {return 2}
	switch f := f64(canvas_h) / f64(src_h); {
	case f <= 1.05: return 1
	case f <= 2.1:  return 2
	}
	return 4
}

// Renders clip c (video) into `out` as the mode asks. `up` = upscale factor (see
// upscale_factor). The clip's speed is applied, so the file plays at speed 1.
// Returns what was used (with the time of each step), or an error text.
render_clip :: proc(mode: Prerender_Mode, c: Clip, src, out: string, fps, up: int, cap_w, cap_h: int) -> (engine, err: string) {
	rife, esr := find_rife(), find_esrgan()
	span := c.duration * c.speed
	frames_in := int(math.round(span * f64(fps))) // frames cut from the source
	target := max(int(math.round(f64(frames_in) / c.speed)), frames_in + 1) // frames after interpolation
	rife_cmd := make([dynamic]string, context.temp_allocator)
	append(&rife_cmd, rife, "-i", "{in}", "-o", "{out}", "-n", fmt.tprintf("%d", target), "-f", "%08d.png", "-j", "2:2:2") // -f is a file name pattern for rife (for Real-ESRGAN it is the format)
	for dir in ([?]string{"tools\\rife-v4.6", "rife-v4.6"}) {
		if os.exists(dir) {append(&rife_cmd, "-m", dir); break}
	}
	append(&rife_cmd, ..gpu_args())
	model := "realesr-animevideov3" // small and fast, made for anime
	for f in ([?]string{"tools\\models\\realesr-general-x4v3.param", "models\\realesr-general-x4v3.param"}) {
		if os.exists(f) {model = "realesr-general-x4v3"; break} // small, for general footage
	}
	esr_cmd := make([dynamic]string, context.temp_allocator)
	append(&esr_cmd, esr, "-i", "{in}", "-o", "{out}", "-n", model, "-s", fmt.tprintf("%d", up), "-f", "png", "-j", "3:2:3")
	append(&esr_cmd, ..gpu_args())
	// Frames bigger than the picture are shrunk first (smaller ones are left alone): the export would shrink
	// them anyway, and 4K frames do not fit in the GPU memory of RIFE and take four times as long.
	fit_down := fmt.tprintf("scale=w='min(iw,%d)':h='min(ih,%d)':force_original_aspect_ratio=decrease:force_divisible_by=2:flags=lanczos", cap_w, cap_h)
	scale := up > 1 ? fmt.tprintf("scale=iw*%d:ih*%d:flags=lanczos,", up, up) : ""

	switch mode {
	case .Slowmo:
		if rife != "" {
			t, msg := frames_pipeline(c, src, out, "rife", fps, fit_down, {rife_cmd[:]}, {target})
			return fmt.tprintf("RIFE (%s)", t), msg
		}
		n, msg := render_segments(c, src, out, fps, "", "")
		return fmt.tprintf("ffmpeg minterpolate (%d cores)", n), msg
	case .Enhance:
		retime := fmt.tprintf("setpts=PTS/%.6f,fps=%d,%s", c.speed, fps, DENOISE)
		frames := max(int(math.round(c.duration * f64(fps))), 1)
		if esr != "" && up > 1 {
			t, msg := frames_pipeline(c, src, out, "esrgan", fps, retime, {esr_cmd[:]}, {frames})
			return fmt.tprintf("Real-ESRGAN %dx (%s)", up, t), msg
		}
		// no upscaling needed (or no ML tool): denoise, sharpen and fix the levels in one ffmpeg pass
		vf := fmt.tprintf("%s,%s%s,normalize=smoothing=30", retime, scale, SHARPEN)
		job_step("cleaning with ffmpeg ...")
		if msg := ffmpeg_tracked({"-ss", fmt.tprintf("%.3f", c.in_point), "-t", fmt.tprintf("%.3f", span), "-i", src, "-an", "-vf", vf, "-c:v", "libx264", "-crf", "12", "-preset", "medium", "-pix_fmt", "yuv420p", out}, c.duration, 0, 1); msg != "" {
			return "", msg
		}
		return up > 1 ? fmt.tprintf("ffmpeg %dx (no Real-ESRGAN in tools)", up) : "ffmpeg (denoise, sharpen, levels; the source is big enough, no upscaling)", ""
	case .Both:
		// denoise first (cheap, and cleaner frames make better in-between frames), interpolate, upscale last (only if needed)
		retime := strings.concatenate({fit_down, ",", DENOISE}, context.temp_allocator) // the source's own frames go to RIFE: resampling them to the project fps would repeat frames and RIFE would "move" between copies (stutter)
		if rife != "" && (esr != "" || up == 1) {
			stages: [][]string = up > 1 ? {rife_cmd[:], esr_cmd[:]} : {rife_cmd[:]}
			counts: []int = up > 1 ? {target, target} : {target}
			t, msg := frames_pipeline(c, src, out, "both", fps, retime, stages, counts)
			return fmt.tprintf("%s (%s)", up > 1 ? "RIFE + Real-ESRGAN" : "RIFE + denoise", t), msg
		}
		n, msg := render_segments(c, src, out, fps, strings.concatenate({DENOISE, ","}, context.temp_allocator), strings.concatenate({",", scale, SHARPEN}, context.temp_allocator))
		return fmt.tprintf("ffmpeg (%d cores; RIFE and Real-ESRGAN are much faster)", n), msg
	}
	return "", "unknown mode"
}
Slow_Task :: struct {
	mode:   Prerender_Mode,
	clip:   int, // index of the clip
	c:      Clip, // a copy
	src:    string, // heap
	out:    string, // heap: the cache file (absolute)
	source: Source, // the rendered file, probed (heap strings)
	up:     int, // upscale factor the clip needs
	cap_w, cap_h: int, // frames bigger than this are shrunk before the ML tools: the picture size times the clip zoom
	ok:     bool,
}

Slow_Job :: struct {
	tasks:  [dynamic]Slow_Task,
	fps:    int,
	engine: string, // heap; what rendered last
	err:    string, // heap; "" = fine
}

// Prerenders the selected video clips (slow-mo: the slowed ones) and points them at the
// result. Starts the job (main thread).
prerender :: proc(p: ^Project, mode: Prerender_Mode) {
	_ = os.make_directory(CACHE_DIR)
	d := new(Slow_Job)
	d.fps = int(max(p.settings.fps, 1))
	for c, i in p.clips {
		if !c.selected || c.kind != .Video || (mode != .Enhance && c.speed >= 0.99) {continue}
		// the tools are part of the name: a file made by ffmpeg must not be taken for a RIFE render
		name := fmt.tprintf("%s\\%s%s%s_hq_%d_%d_%d_%d.mp4", CACHE_DIR, PRERENDER_TAG[mode], find_rife() != "" ? "_rife" : "", find_esrgan() != "" ? "_esr" : "", c.source, int(c.in_point * 1000), int(c.duration * c.speed * 1000), int(c.speed * 1000))
		full, _ := filepath.abs(name, context.temp_allocator)
		append(&d.tasks, Slow_Task{cap_w = int(f64(p.settings.width) * f64(max(c.scale, 1))), cap_h = int(f64(p.settings.height) * f64(max(c.scale, 1))), up = upscale_factor(p.sources[c.source].height, int(p.settings.height)), mode = mode, clip = i, c = c, src = strings.clone(p.sources[c.source].path), out = strings.clone(full)})
	}
	if len(d.tasks) == 0 {
		set_status(mode == .Enhance ? "enhance: select video clips" : "slow-mo: select video clips that are slowed down (shift+drag an edge stretches a clip)")
		free(d)
		return
	}
	job_start(PRERENDER_TITLE[mode], slow_work, slow_finish, d)
}

// Job thread: renders what is not in the cache yet. Each clip gets its share of the bar.
slow_work :: proc(data: rawptr) {
	d := (^Slow_Job)(data)
	n := len(d.tasks)
	for &t, i in d.tasks {
		job_range(f32(i) / f32(n), 1 / f32(n))
		if job_cancelled() {
			d.err = strings.clone("stopped")
			return
		}
		if !os.exists(t.out) {
			job_step("clip %d of %d ...", i + 1, n)
			engine, err := render_clip(t.mode, t.c, t.src, t.out, d.fps, t.up, t.cap_w, t.cap_h)
			if err != "" {
				os.remove(t.out) // a half written file must not stay in the cache
				d.err = strings.clone(err)
				return
			}
			delete(d.engine)
			d.engine = strings.clone(engine)
		}
		job_progress(1)
		if s, ok := probe(t.out); ok {
			t.source, t.ok = s, true
		}
	}
}

// Main thread: point the clips at the rendered files.
slow_finish :: proc(data: rawptr) {
	d := (^Slow_Job)(data)
	defer {
		for t in d.tasks {delete(t.src); delete(t.out)}
		delete(d.tasks)
		delete(d.engine); delete(d.err)
		free(d)
	}
	if d.err != "" {
		set_status("render: %s", d.err)
		if d.err != "stopped" {job_report("The render did not finish", d.err)}
		return
	}
	done := 0
	for t in d.tasks {
		if !t.ok || t.clip >= len(project.clips) {continue}
		idx := -1 // the same file may already be a source (another slice with the same footage)
		for s, k in project.sources {
			if s.path == t.source.path {idx = k}
		}
		if idx < 0 {
			append(&project.sources, t.source)
			media_start(t.source, int(clamp(project.settings.fps, 1, 30)))
			idx = len(project.sources) - 1
		}
		project.clips[t.clip].source = idx
		project.clips[t.clip].in_point = 0
		project.clips[t.clip].speed = 1
		done += 1
	}
	set_status("%d clip%s rendered%s", done, done == 1 ? "" : "s", len(d.engine) > 0 ? fmt.tprintf(" with %s", d.engine) : " (from the cache)")
}


// ---------------------------------------------------------------- the slow-mo window

// Speed in percent and the new length are two views of one number: change one and the
// other follows. The speed goes to every selected clip; the length shown is the first
// selected video clip's. Then the slowed clips are rendered (see prerender).
Slow_Dialog :: struct {
	open, shown: bool,
	enhance:     bool, // also denoise / upscale (Both)
	pct:         f32, // speed, 100 = normal
	span:        f64, // seconds of source the first selected video clip plays (its length at 100 %)
	clips:       int, // selected clips
	render:      bool, // render the in-between frames (else only set the speed)
}

slow_dialog: Slow_Dialog

open_slowmo_dialog :: proc(enhance: bool) {
	first, n := -1, 0
	for c, i in project.clips {
		if c.selected && c.kind == .Video {
			n += 1
			if first < 0 {first = i}
		}
	}
	if n == 0 {
		set_status("slow-mo: select video clips first")
		return
	}
	c := project.clips[first]
	slow_dialog = {open = true, enhance = enhance, pct = c.speed < 0.99 ? f32(c.speed * 100) : 50, span = c.duration * c.speed, clips = n, render = true}
}

// Sets the speed of every selected clip, keeping what part of its source it plays (so the
// clip gets longer when slower). Returns how many clips changed.
apply_speed :: proc(p: ^Project, speed: f64) -> int {
	n := 0
	for &c in p.clips {
		if !c.selected || track_has(p^, c.track, .Locked) {continue}
		span := c.duration * c.speed
		c.speed = clamp(speed, 0.01, 100)
		c.duration = span / c.speed
		n += 1
	}
	return n
}

slowmo_dialog_ui :: proc() {
	if !slow_dialog.open {
		return
	}
	d := &slow_dialog
	if !d.shown {
		im.OpenPopup("Slow motion##dlg")
		d.shown = true
	}
	vp := im.GetMainViewport()
	im.SetNextWindowPos({vp.Pos.x + vp.Size.x / 2, vp.Pos.y + vp.Size.y / 2}, .Always, {0.5, 0.5})
	if !im.BeginPopupModal("Slow motion##dlg", nil, {.AlwaysAutoResize}) {
		return
	}
	defer im.EndPopup()

	text_f("%d clip%s selected", d.clips, d.clips == 1 ? "" : "s")
	// the two views of the speed
	dur := f32(d.span / (f64(max(d.pct, 1)) / 100))
	im.SetNextItemWidth(160)
	im.DragFloat("speed", &d.pct, 0.5, 2, 400, "%.1f %%")
	im.SameLine()
	for p in ([?]f32{50, 25, 10, 100}) {
		if im.SmallButton(cstr(fmt.tprintf("%.0f%%", p))) {d.pct = p}
		im.SameLine()
	}
	im.NewLine()
	im.SetNextItemWidth(160)
	if im.InputFloat("new length", &dur, 0.1, 1, "%.2f s") {
		d.pct = f32(d.span / f64(max(dur, 0.05))) * 100
	}
	d.pct = clamp(d.pct, 2, 400)
	dim_f("speed %.0f percent: %.2fx %s, %.2f s long (was %.2f s)", d.pct, 100 / d.pct, d.pct < 100 ? "longer" : "shorter", d.span / (f64(d.pct) / 100), d.span)
	if d.clips > 1 {im.TextDisabled("The length shown is the first clip's. Every clip gets the same speed.")}
	im.Checkbox("render new in-between frames (smooth)", &d.render)
	if d.render {
		im.Checkbox("also denoise and upscale (when the source is smaller than the picture)", &d.enhance)
	}
	im.Separator()
	if im.Button(d.render ? "Apply and render" : "Apply") {
		n := apply_speed(&project, f64(d.pct) / 100)
		close := true
		if d.render && d.pct < 99 {
			im.CloseCurrentPopup()
			d.open = false
			prerender(&project, d.enhance ? .Both : .Slowmo)
			close = false
		} else {
			set_status("speed set to %.0f %% on %d clip%s", d.pct, n, n == 1 ? "" : "s")
		}
		if close {im.CloseCurrentPopup(); d.open = false}
	}
	im.SameLine()
	if im.Button("Cancel") {
		im.CloseCurrentPopup()
		d.open = false
	}
}