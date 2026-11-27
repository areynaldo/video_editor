package main

import "core:fmt"
import "core:math"
import "core:os"
import "core:strconv"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:thread"

// All ffmpeg interaction goes through the CLI. ffmpeg/ffprobe must be on PATH.

probe :: proc(path: string) -> (s: Source, ok: bool) {
	state, out, _, err := os.process_exec(
		{
			command = {
				"ffprobe", "-v", "error",
				"-show_entries", "stream=codec_type,width,height",
				"-show_entries", "format=duration",
				"-of", "default=nw=1",
				path,
			},
		},
		context.temp_allocator,
		)
	if err != nil || !exited_ok(state) {
		return
	}
	s.path = strings.clone(path)
	rest := string(out)
	for line in strings.split_lines_iterator(&rest) {
		line := strings.trim_space(line)
		switch {
		case line == "codec_type=video": s.has_video = true
		case line == "codec_type=audio": s.has_audio = true
		case strings.has_prefix(line, "width="):  s.width, _ = strconv.parse_int(line[len("width="):])
		case strings.has_prefix(line, "height="): s.height, _ = strconv.parse_int(line[len("height="):])
		case strings.has_prefix(line, "duration="):
			s.duration, _ = strconv.parse_f64(line[len("duration="):])
		}
	}
	ok = s.duration > 0 && (s.has_video || s.has_audio)
	return
}

// The ffmpeg scale options of each fit mode (after the first two numbers, the canvas size).
fit_filter := [Fit_Mode]string{.Fit = ":force_original_aspect_ratio=decrease", .Fill = ":force_original_aspect_ratio=increase", .Stretch = ""}

// atempo only accepts 0.5..2 per instance, so chain them. Returns "" for speed 1.
atempo_chain :: proc(speed: f64) -> string {
	b: strings.Builder
	strings.builder_init(&b, context.temp_allocator)
	s := speed
	for s < 0.5 {
		strings.write_string(&b, "atempo=0.5,")
		s /= 0.5
	}
	for s > 2 {
		strings.write_string(&b, "atempo=2.0,")
		s /= 2
	}
	if abs(s - 1) > 1e-6 {
		fmt.sbprintf(&b, "atempo=%.6f,", s)
	}
	return strings.to_string(b)
}

// Renders one pass of the timeline into out_path: `length` seconds of it. Video: the background, each clip
// fitted into the mask area, then scaled / rotated / offset by its transform and overlaid in track order.
// Audio: every audio clip delayed to its start and mixed. Only the clips this pass uses are opened.
// want_video / want_audio pick the streams (the long way renders the video in parts, the audio once).
// lo..hi is the share of the progress bar. The container comes from out_path's extension.
export_pass :: proc(p: Project, out_path: string, length: f64, want_video, want_audio: bool, lo, hi: f32) -> (ok: bool, err: string) {
	W, H, FPS := int(p.settings.width) &~ 1, int(p.settings.height) &~ 1, int(p.settings.fps)
	mx, my, MW, MH := mask_rect(p.settings)

	// Clip indices sorted by track so higher tracks are overlaid last.
	order := make([dynamic]int, context.temp_allocator)
	for _, i in p.clips {
		append(&order, i)
	}
	for i in 1 ..< len(order) {
		for j := i; j > 0 && p.clips[order[j]].track < p.clips[order[j - 1]].track; j -= 1 {
			order[j], order[j - 1] = order[j - 1], order[j]
		}
	}

	args := make([dynamic]string, context.temp_allocator)
	append(&args, "ffmpeg", "-y")
	// -ss / -t before -i: ffmpeg jumps to the piece instead of decoding the file from its start for every
	// clip (with hundreds of slices of one long video that was the whole export time). But every input adds
	// to the command line, and Windows takes only 32767 characters (more: "could not start ffmpeg"). So
	// the clips that fit get the jump; the others are cut by a trim filter (slower, but short).
	// which clips this pass really uses (an input that is never used must not be opened)
	used := make([]bool, len(p.clips), context.temp_allocator)
	for c, i in p.clips {
		switch c.kind {
		case .Video:
			if want_video && !track_has(p, c.track, .Hidden) {
				iv, always := visible_intervals(p, c.track, length)
				used[i] = always || len(iv) > 0
			}
		case .Audio:
			used[i] = want_audio && track_audible(p, c.track)
		}
	}
	seek := make([]bool, len(p.clips), context.temp_allocator)
	budget := 24000 // the filter graph is in a file, so it is not counted
	for c, i in p.clips {
		if used[i] && !c.black {budget -= len(p.sources[c.source].path) + 8}
	}
	for i in 0 ..< len(p.clips) {
		if used[i] && !p.clips[i].black && budget >= 34 {
			seek[i] = true
			budget -= 34 // "-ss 000.000 -t 000.000", with room for quotes
		}
	}
	input_of := make([]int, len(p.clips), context.temp_allocator)
	inputs := 0
	for c, i in p.clips {
		if !used[i] || c.black {continue} // a black placeholder is not read from a file
		if seek[i] {
			append(&args, "-ss", fmt.tprintf("%.3f", c.in_point), "-t", fmt.tprintf("%.3f", c.duration * c.speed))
		}
		append(&args, "-i", p.sources[c.source].path)
		input_of[i] = inputs
		inputs += 1
	}

	g: strings.Builder
	strings.builder_init(&g, context.temp_allocator)
	bg := p.settings.bg
	if want_video {
		bgc := fmt.tprintf("0x%02x%02x%02x", int(bg.r * 255 + 0.5), int(bg.g * 255 + 0.5), int(bg.b * 255 + 0.5))
		if MW < W || MH < H { // a mask: the background around, the area (black) inside it
			ac := p.settings.mask_color
			area := fmt.tprintf("0x%02x%02x%02x", int(ac.r * 255 + 0.5), int(ac.g * 255 + 0.5), int(ac.b * 255 + 0.5))
			fmt.sbprintf(&g, "color=c=%s:s=%dx%d:r=%d:d=%.3f,format=yuv420p[vbase];color=c=%s:s=%dx%d:r=%d:d=%.3f,format=yuv420p[varea];[vbase][varea]overlay=x=%d:y=%d:format=yuv420[v0];", bgc, W, H, FPS, length, area, MW, MH, FPS, length, mx, my)
		} else {
			fmt.sbprintf(&g, "color=c=%s:s=%dx%d:r=%d:d=%.3f,format=yuv420p[v0];", bgc, W, H, FPS, length)
		}
	}

	vcount, acount: int
	for ci in order {
		c := p.clips[ci]
		switch c.kind {
		case .Video:
			if !used[ci] {
				continue
			}
			iv, always := visible_intervals(p, c.track, length)
			if !always && len(iv) == 0 {
				continue // the program never shows this layer
			}
			enable: strings.Builder
			strings.builder_init(&enable, context.temp_allocator)
			if !always {
				strings.write_string(&enable, ":enable='")
				for x, k in iv {
					fmt.sbprintf(&enable, "%sbetween(t,%.4f,%.4f)", k > 0 ? "+" : "", x.a, x.b)
				}
				strings.write_string(&enable, "'")
			}
			vcount += 1
			vtrim := seek[ci] ? "" : fmt.tprintf("trim=start=%.3f:duration=%.3f,", c.in_point, c.duration * c.speed)
			timing := fmt.tprintf("setpts=(PTS-STARTPTS)/%.6f+%.3f/TB", c.speed, c.start)
			if c.freeze { // one frame (the one at in_point), held for the clip's length
				timing = fmt.tprintf("trim=end_frame=1,setpts=PTS-STARTPTS+%.3f/TB,tpad=stop_mode=clone:stop_duration=%.4f", c.start, c.duration)
			}
			if c.black { // "no clip": black in the shape the clip it follows has, the background stays around it
				src := p.sources[c.source]
				fw, fh := f64(MW), f64(MH)
				if src.width > 0 && src.height > 0 && c.fit != .Stretch {
					rw, rh := f64(MW) / f64(src.width), f64(MH) / f64(src.height)
					k := c.fit == .Fill ? max(rw, rh) : min(rw, rh)
					fw, fh = f64(src.width) * k, f64(src.height) * k
				}
				fmt.sbprintf(
					&g,
					"color=c=black:s=%dx%d:r=%d:d=%.4f,setpts=PTS-STARTPTS+%.3f/TB,setsar=1,format=yuva420p,",
					max(int(fw * f64(c.scale)) &~ 1, 2), max(int(fh * f64(c.scale)) &~ 1, 2), FPS, c.duration, c.start,
				)
			} else {
				fmt.sbprintf(
					&g,
					"[%d:v]%s%s,fps=%d," +
						"scale=%d:%d%s:out_range=tv,scale=iw*%.4f:ih*%.4f,setsar=1,format=yuva420p,",
						input_of[ci], vtrim, timing, FPS, MW, MH, fit_filter[c.fit], c.scale, c.scale,
					)
			}
			if c.rotation != 0 {
				fmt.sbprintf(&g, "rotate=a=%.6f:ow='hypot(iw,ih)':oh='hypot(iw,ih)':c=none,", f64(c.rotation) * math.PI / 180)
			}
			fmt.sbprintf(
				&g,
				"null[c%d];[v%d][c%d]overlay=x=(W-w)/2+%.1f:y=(H-h)/2+%.1f:eof_action=pass:format=yuv420%s[v%d];",
				vcount, vcount - 1, vcount, c.pos.x, c.pos.y, strings.to_string(enable), vcount,
				)
		case .Audio:
			if !used[ci] {
				continue
			}
			acount += 1
			ms := int(c.start * 1000)
			atrim := seek[ci] ? "" : fmt.tprintf("atrim=start=%.3f:duration=%.3f,", c.in_point, c.duration * c.speed)
			fmt.sbprintf(
				&g,
				"[%d:a]%sasetpts=PTS-STARTPTS,%s%sadelay=%d|%d[a%d];",
				input_of[ci], atrim, atempo_chain(c.speed), gain_filter(c.gain_db), ms, ms, acount,
				)
		}
	}
	// lyrics: one drawtext for each line, burned into the finished picture
	final := fmt.tprintf("[v%d]", vcount)
	if want_video && (MW < W || MH < H) { // the bars of the mask, over whatever spills out of the area
		bc := p.settings.bg // around the area: the background colour (this also hides what spills out of the area)
		col := fmt.tprintf("0x%02x%02x%02x", int(bc.r * 255 + 0.5), int(bc.g * 255 + 0.5), int(bc.b * 255 + 0.5))
		box :: proc(g: ^strings.Builder, x, y, w, h: int, col: string, first: bool) {
			if w > 0 && h > 0 {fmt.sbprintf(g, "%sdrawbox=x=%d:y=%d:w=%d:h=%d:color=%s:t=fill", first ? "" : ",", x, y, w, h, col)}
		}
		fmt.sbprintf(&g, "%s", final)
		box(&g, 0, 0, mx, H, col, true)
		box(&g, mx + MW, 0, W - mx - MW, H, col, false)
		box(&g, 0, 0, W, my, col, false)
		box(&g, 0, my + MH, W, H - my - MH, col, false)
		strings.write_string(&g, "[vmask];")
		final = "[vmask]"
	}
	lyric_files := make([dynamic]string, context.temp_allocator)
	defer for f in lyric_files {os.remove(f)}
	if want_video && len(p.lyrics) > 0 {
		// every lyric layer on top of the last: a drawtext for each line of each text on screen, laid out in the
		// layer's frame (the same layout as the preview: wrapped to the frame, shrunk to fit it)
		for layer in 0 ..< lyric_layer_count(p) {
			st := lyric_style_of(p, layer)
			if !st.burn {continue}
			font := lyric_style_font(st)
			if font == "" {
				fmt.eprintln("lyrics not burned: no font found")
				break
			}
			fm := font_metrics(font)
			shows := make([dynamic]Show, context.temp_allocator)
			build_shows(p, &shows, st, layer)
			strings.write_string(&g, final)
			n := 0
			for show, i in shows {
				lay := lyric_layout(p.settings, st, fm, show_text(p, show), show.scale, show.row, show.rows)
				size := max(int(lay.size), 8)
				border := int(f64(size) * f64(st.border_w) / 100)
				for line, k in lay.lines {
					if strings.trim_space(line) == "" {continue}
					file := fmt.tprintf("%s.lyric%d_%d_%d.txt", out_path, layer, i, k)
					_ = os.write_entire_file(file, transmute([]byte)line)
					append(&lyric_files, file)
					fmt.sbprintf(
						&g,
						"%sdrawtext=fontfile='%s':textfile='%s':expansion=none:fontsize=%d:fontcolor=0x%06x:borderw=%d:bordercolor=0x%06x:x=%.1f-text_w*%.2f:y=%.1f:enable='between(t,%.3f,%.3f)'",
						n > 0 ? "," : "", filter_path(font), filter_path(file), size, rgb_hex(st.color), border, rgb_hex(st.border), lay.ax, lay.af, lay.top + f32(k) * lay.lh, show.t0, show.t1,
						)
					n += 1
				}
			}
			if n == 0 { // nothing to draw: pass the picture through
				strings.write_string(&g, "null")
			}
			label := fmt.tprintf("[vtext%d]", layer)
			strings.write_string(&g, label)
			strings.write_string(&g, ";")
			final = label
		}
	}
	if acount > 0 {
		for i in 1 ..= acount {
			fmt.sbprintf(&g, "[a%d]", i)
		}
		fmt.sbprintf(&g, "amix=inputs=%d:normalize=0:duration=longest,%s[aout]", acount, gain_filter(p.settings.master_db, true))
	}
	graph := strings.trim_right(strings.to_string(g), ";")

	// the graph goes in a file: on the command line it would eat the Windows limit of 32767 characters
	script := strings.concatenate({out_path, ".filter.txt"}, context.temp_allocator)
	_ = os.write_entire_file(script, transmute([]byte)graph)
	append(&args, "-filter_complex_script", script)
	defer os.remove(script)
	if want_video {append(&args, "-map", final)}
	if acount > 0 {
		append(&args, "-map", "[aout]")
	}
	append(&args, "-t", fmt.tprintf("%.3f", length))
	if want_video {append(&args, "-pix_fmt", "yuv420p")}
	append(&args, ..quality_args(p.settings.format, p.settings.quality, want_video, acount > 0, W * H, use_gpu_encode(p.settings, W, H)))
	append(&args, out_path)

	// runs as a background job: the bar follows ffmpeg's own progress report
	if msg := ffmpeg_tracked(args[2:], length, lo, hi); msg != "" {
		os.remove(out_path) // a half written file is no export
		return false, msg
	}
	return true, ""
}

VIDEO_WINDOW_CLIPS :: 24 // most video clips open at once: every open clip is a decoder, and hundreds of 4K decoders do not fit in memory

// Splits the timeline into parts that each need few clips: whole seconds, as long as the clips that touch a part
// stay within VIDEO_WINDOW_CLIPS (and a part is at most 30 s). One part when the project is small.
export_windows :: proc(p: Project, length: f64) -> [][2]f64 {
	out := make([dynamic][2]f64, context.temp_allocator)
	touching :: proc(p: Project, a, b: f64) -> (n: int) {
		for c in p.clips {
			if c.kind == .Video && clip_end(c) > a && c.start < b {n += 1}
		}
		return
	}
	if touching(p, 0, length) <= VIDEO_WINDOW_CLIPS {
		append(&out, [2]f64{0, length})
		return out[:]
	}
	t := 0.0
	for t < length - 1e-6 {
		end := min(t + 1, length)
		for end < length - 1e-6 && end - t < 30 {
			next := min(end + 1, length)
			if touching(p, t, next) > VIDEO_WINDOW_CLIPS {break}
			end = next
		}
		append(&out, [2]f64{t, end})
		t = end
	}
	return out[:]
}

// The project as it is between t0 and t1, moved to start at 0: only the video clips that touch the part (cut
// to it), the program cuts and the lyrics shifted.
window_project :: proc(p: Project, t0, t1: f64) -> Project {
	pc := p
	pc.clips = make([dynamic]Clip, context.temp_allocator)
	for c in p.clips {
		if c.kind != .Video || clip_end(c) <= t0 || c.start >= t1 {continue}
		a, b := max(c.start, t0), min(clip_end(c), t1)
		n := c
		n.in_point, n.duration, n.start = c.freeze ? c.in_point : c.in_point + (a - c.start) * c.speed, b - a, a - t0
		append(&pc.clips, n)
	}
	pc.program = make([dynamic]Cut, context.temp_allocator)
	if len(p.program) > 0 {
		i := segment_at(p, t0)
		append(&pc.program, Cut{time = 0, layer = i >= 0 ? p.program[i].layer : -1})
		for c in p.program {
			if c.time > t0 + CUT_EPS && c.time < t1 {append(&pc.program, Cut{time = c.time - t0, layer = c.layer, fixed = c.fixed})}
		}
	}
	pc.lyrics = make([dynamic]Lyric, context.temp_allocator)
	for l in p.lyrics {
		n := l
		n.t0, n.t1 = l.t0 - t0, l.t1 - t0
		append(&pc.lyrics, n)
	}
	return pc
}

// Renders the whole timeline. A small project is one ffmpeg run. A big one (many clips) is rendered in parts of
// a few clips each, so that ffmpeg never has hundreds of decoders open at once ("Cannot allocate memory"). The
// parts, and the audio mixed on its own, are then joined without another encode.
export :: proc(p: Project, out_path: string, from := f32(0), to := f32(1)) -> (ok: bool, err: string) {
	at :: proc(from, to, x: f32) -> f32 {return from + (to - from) * x} // x of this export's share of the progress bar
	length := project_length(p)
	if length <= 0 {
		return false, "nothing to export"
	}
	windows := export_windows(p, length)
	if len(windows) <= 1 {
		return export_pass(p, out_path, length, true, true, from, to)
	}
	ext := FORMAT_EXT[p.settings.format]
	temps := make([dynamic]string, context.temp_allocator)
	defer for f in temps {os.remove(f)}
	list: strings.Builder
	strings.builder_init(&list, context.temp_allocator)
	for w, k in windows {
		part := fmt.tprintf("%s.part%03d.%s", out_path, k, ext)
		append(&temps, part)
		job_step("video part %d of %d ...", k + 1, len(windows))
		pc := window_project(p, w[0], w[1])
		if ok, err = export_pass(pc, part, w[1] - w[0], true, false, at(from, to, f32(w[0] / length) * 0.9), at(from, to, f32(w[1] / length) * 0.9)); !ok {
			return
		}
		slashed, _ := strings.replace_all(part, "\\", "/", context.temp_allocator)
		quoted, _ := strings.replace_all(slashed, "'", "'\\''", context.temp_allocator)
		fmt.sbprintf(&list, "file '%s'\n", quoted)
	}
	has_audio := false
	for c in p.clips {
		has_audio ||= c.kind == .Audio && track_audible(p, c.track)
	}
	audio := fmt.tprintf("%s.audio.%s", out_path, p.settings.format == .WebM ? "webm" : "m4a")
	if has_audio {
		append(&temps, audio)
		job_step("mixing the audio ...")
		if ok, err = export_pass(p, audio, length, false, true, at(from, to, 0.9), at(from, to, 0.95)); !ok {
			return
		}
	}
	listfile := strings.concatenate({out_path, ".parts.txt"}, context.temp_allocator)
	append(&temps, listfile)
	_ = os.write_entire_file(listfile, transmute([]byte)strings.to_string(list))
	job_step("joining the parts ...")
	join := make([dynamic]string, context.temp_allocator)
	append(&join, "-f", "concat", "-safe", "0", "-i", listfile)
	if has_audio {append(&join, "-i", audio)}
	append(&join, "-map", "0:v")
	if has_audio {append(&join, "-map", "1:a")}
	append(&join, "-c", "copy")
	if p.settings.format == .MP4 || p.settings.format == .MOV {append(&join, "-movflags", "+faststart")}
	append(&join, out_path)
	if msg := ffmpeg_tracked(join[:], length, at(from, to, 0.95), to); msg != "" {
		os.remove(out_path)
		return false, msg
	}
	return true, ""
}

MAX_NATIVE_SCALE :: 4.0
MAX_CANVAS :: 7680
MAX_NATIVE_PIXELS :: 4_200_000 // "full source resolution" does not grow the canvas past this (x264 needs about 1.5 GB for every 1.4 Mpx at the default settings)
BIG_CANVAS_PIXELS :: 3_500_000 // from here x264 gets lighter settings (less memory, the same speed)

// How much bigger the canvas must be for every video clip to play at its source's size or more: a clip is fitted
// into the mask area (or the canvas), then scaled by its own scale, so a 1080x1920 clip in a 608x1080 mask area
// needs the canvas 1.78 times as big. 1 when nothing is scaled down. Capped at MAX_NATIVE_SCALE and MAX_CANVAS.
native_scale :: proc(p: Project) -> f64 {
	_, _, mw, mh := mask_rect(p.settings)
	k := 1.0
	for c in p.clips {
		src := p.sources[c.source]
		if c.kind != .Video || c.black || track_has(p, c.track, .Hidden) || src.width <= 0 || src.height <= 0 {continue}
		rw, rh := f64(src.width) / f64(mw), f64(src.height) / f64(mh) // the source against the area it is fitted into
		fit := c.fit == .Fill ? min(rw, rh) : (c.fit == .Stretch ? max(rw, rh) : max(rw, rh)) // size at which it fills the area as far as its mode goes
		k = max(k, fit * f64(max(c.scale, 1)))
	}
	k = min(k, MAX_NATIVE_SCALE, f64(MAX_CANVAS) / f64(max(p.settings.width, p.settings.height)))
	k = min(k, math.sqrt(f64(MAX_NATIVE_PIXELS) / f64(max(p.settings.width, 1) * max(p.settings.height, 1)))) // a canvas already bigger than the budget does not grow
	return max(k, 1)
}

// The same picture on a canvas k times as big (clip offsets scale with it).
scaled_project :: proc(p: Project, k: f64) -> Project {
	if k <= 1.0001 {return p}
	out := p
	out.settings.width = i32(f64(p.settings.width) * k) &~ 1
	out.settings.height = i32(f64(p.settings.height) * k) &~ 1
	out.clips = make([dynamic]Clip, context.temp_allocator)
	for c in p.clips {
		n := c
		n.pos *= f32(k)
		append(&out.clips, n)
	}
	return out
}

// The mask area as a project of its own: a canvas of the mask's ratio (long side as long as the project's
// long side, so a 9:16 mask in 1920x1080 gives 1080x1920, not the 608x1080 that cropping would), no mask, and
// the clips' offsets scaled to it. A wide mask in a vertical project gives a widescreen video the same way.
mask_export_project :: proc(p: Project) -> (out: Project, ok: bool) {
	s := p.settings
	if s.mask_w <= 0 || s.mask_h <= 0 {return}
	_, _, _, mh := mask_rect(s)
	long := max(int(s.width), int(s.height)) &~ 1
	aspect := f64(s.mask_w) / f64(s.mask_h)
	vw, vh := long, int(f64(long) / aspect)
	if aspect < 1 {vw, vh = int(f64(long) * aspect), long}
	vw, vh = max(vw &~ 1, 2), max(vh &~ 1, 2)
	k := f32(vh) / f32(mh) // the mask area, made as big as the new canvas
	out = p
	out.settings.width, out.settings.height = i32(vw), i32(vh)
	out.settings.mask_w, out.settings.mask_h = 0, 0
	out.settings.bg = s.mask_color // this canvas is the mask area: its colour is the base
	out.clips = make([dynamic]Clip, context.temp_allocator)
	for c in p.clips {
		n := c
		n.pos *= k
		append(&out.clips, n)
	}
	return out, true
}

// "name.mp4" -> "name_vertical.mp4" (_wide for a wide mask, _square)
mask_path :: proc(path: string, s: Settings) -> string {
	tag := s.mask_w < s.mask_h ? "_vertical" : (s.mask_w > s.mask_h ? "_wide" : "_square")
	dot := strings.last_index_byte(path, '.')
	if dot <= strings.last_index_any(path, "/\\") {return strings.concatenate({path, tag}, context.temp_allocator)}
	return strings.concatenate({path[:dot], tag, path[dot:]}, context.temp_allocator)
}

// What the export makes: the normal video (the whole canvas, bars and all) and/or the mask area as a video of
// its own. Returns the files written.
export_all :: proc(p_in: Project, path: string) -> (made: []string, ok: bool, err: string) {
	p := p_in
	if p.settings.native_res {p = scaled_project(p, native_scale(p))}
	mp, has_mask := mask_export_project(p)
	do_mask := p.settings.export_mask && has_mask
	do_normal := !do_mask || !p.settings.skip_normal
	n := f32((do_normal ? 1 : 0) + (do_mask ? 1 : 0))
	out := make([dynamic]string, context.temp_allocator)
	done := f32(0)
	if do_normal {
		job_step("encoding the video ...")
		if ok, err = export(p, path, 0, 1 / n); !ok {return out[:], false, err}
		append(&out, path)
		done += 1
	}
	if do_mask {
		file := mask_path(path, p.settings)
		job_step("encoding the %dx%d version ...", mp.settings.width, mp.settings.height)
		if ok, err = export(mp, file, done / n, 1); !ok {return out[:], false, err}
		append(&out, file)
	}
	return out[:], true, ""
}

Export_Job :: struct {
	p:    Project, // a shallow copy: the loading window keeps the project from being edited while it runs
	path: string, // heap
	err:  string, // heap; "" = fine
	made: string, // heap; the files written
}

export_work :: proc(data: rawptr) {
	d := (^Export_Job)(data)
	made, _, err := export_all(d.p, d.path)
	d.err = strings.clone(err)
	d.made = strings.join(made, ", ")
}

export_finish :: proc(data: rawptr) {
	d := (^Export_Job)(data)
	defer {
		delete(d.path)
		delete(d.err)
		delete(d.made)
		free(d)
	}
	switch d.err {
	case "":        set_status("exported %s", d.made)
	case "stopped": set_status("export stopped")
	case:
		set_status("export failed: %s", d.path)
		hint := ""
		if strings.contains(d.err, "malloc") || strings.contains(d.err, "memory") {
			hint = "\n\nThe computer ran out of memory. Close other programs, and turn off 'full source resolution' (it makes the picture bigger than the project size) or use a lower quality."
		}
		job_report("The export did not finish", strings.concatenate({d.err, hint}, context.temp_allocator))
	}
}

// Codec settings for the export. Without them ffmpeg uses its defaults (x264 crf 23, aac 128k), which
// is what makes an export look compressed. x264: constant quality (crf: lower = better), slow preset.
// WebM cannot hold x264: VP9 + Opus.
// Is the graphics card's H.264 encoder (NVENC) there? Asked once, on a thread (starting it takes a second).
// 0 = not asked, 1 = asking, 2 = yes, 3 = no.
nvenc_state: i32

nvenc_ready :: proc() -> bool {
	if sync.atomic_load(&nvenc_state) == 0 {
		sync.atomic_store(&nvenc_state, 1)
		thread.run(proc() {
			state, _, _, err := os.process_exec(
				{command = {"ffmpeg", "-nostdin", "-v", "error", "-f", "lavfi", "-i", "color=black:s=256x256:d=0.2", "-frames:v", "1", "-c:v", "h264_nvenc", "-f", "null", "-"}},
				context.allocator,
				)
			sync.atomic_store(&nvenc_state, err == nil && state.exit_code == 0 ? 2 : 3)
		})
	}
	return sync.atomic_load(&nvenc_state) == 2
}

// Can this export use the graphics card? NVENC makes H.264 (mp4, mkv, mov) up to 4096 px.
use_gpu_encode :: proc(s: Settings, w, h: int) -> bool {
	return s.gpu_encode && s.format != .WebM && w <= 4096 && h <= 4096 && nvenc_ready()
}

quality_args :: proc(format: Export_Format, q: Export_Quality, video := true, audio := true, pixels := 0, gpu := false) -> []string {
	crf := [Export_Quality]string{.Typical = "19", .High = "16", .Max = "12"}
	vp9 := [Export_Quality]string{.Typical = "32", .High = "24", .Max = "17"}
	rate := [Export_Quality]string{.Typical = "192k", .High = "256k", .Max = "320k"}
	out := make([dynamic]string, context.temp_allocator)
	if format == .WebM {
		if video {append(&out, "-c:v", "libvpx-vp9", "-crf", vp9[q], "-b:v", "0", "-row-mt", "1")}
		if audio {append(&out, "-c:a", "libopus", "-b:a", rate[q])}
		return out[:]
	}
	if video && gpu {
		cq := [Export_Quality]string{.Typical = "27", .High = "24", .Max = "20"} // constant quality: lower = better. About crf + 8 matches x264 in quality (measured), at roughly 20 % more size
		append(&out, "-c:v", "h264_nvenc", "-preset", "p5", "-tune", "hq", "-rc", "vbr", "-cq", cq[q], "-b:v", "0", "-spatial-aq", "1", "-temporal-aq", "1")
	} else if video {append(&out, "-c:v", "libx264", "-crf", crf[q], "-preset", q == .Max ? "slow" : "medium")}
	if video && !gpu && pixels >= BIG_CANVAS_PIXELS { // big pictures: x264 keeps every thread's frames and the look-ahead in memory (3.2 GB for 1920x3412)
		append(&out, "-threads", "12", "-x264-params", "rc-lookahead=20")
	}
	if audio {append(&out, "-c:a", "aac", "-b:a", rate[q])}
	if video && (format == .MP4 || format == .MOV) {append(&out, "-movflags", "+faststart")}
	return out[:]
}

// ffmpeg volume filter for a dB gain with a trailing comma ("" when unchanged).
// `last` = no trailing comma, and a pass-through filter when unchanged.
gain_filter :: proc(db: f32, last := false) -> string {
	filter: string
	switch {
	case db <= -60: filter = "volume=0"
	case db != 0:   filter = fmt.tprintf("volume=%.2fdB", db)
	case last:      filter = "anull"
	case:           return ""
	}
	return last ? filter : strings.concatenate({filter, ","}, context.temp_allocator)
}

// A file path inside a filter option: forward slashes, the drive colon escaped.
filter_path :: proc(path: string) -> string {
	slashed, _ := strings.replace_all(path, "\\", "/", context.temp_allocator)
	escaped, _ := strings.replace_all(slashed, ":", "\\:", context.temp_allocator)
	return escaped
}

find_font :: proc() -> string {
	for f in ([?]string{"C:/Windows/Fonts/arial.ttf", "C:/Windows/Fonts/segoeui.ttf", "C:/Windows/Fonts/tahoma.ttf"}) {
		if os.exists(f) {return f}
	}
	return ""
}

// uvx (the short form of `uv tool run`) fails when started from this program ("The handle is
// invalid"); `uv tool run` is the same thing and works.
fix_uvx :: proc(args: []string) -> []string {
	if len(args) == 0 {return args}
	out := make([dynamic]string, context.temp_allocator)
	if strings.equal_fold(args[0], "uvx") {
		append(&out, "uv", "tool", "run")
		append(&out, ..args[1:])
	} else {
		append(&out, ..args)
	}
	// Python 3.12: the newest Python has no ready-made packages for some libraries (audio-separator
	// needs diffq, which would have to be compiled), so uv would try to build them and fail.
	if strings.equal_fold(out[0], "uv") && !slice.contains(out[:], "--python") {
		for a, i in out {
			if a == "run" {
				inject_at(&out, i + 1, "--python", UV_PYTHON)
				break
			}
		}
	}
	return out[:]
}

UV_PYTHON :: "3.12"
// Splits a command line into arguments; \"double quotes\" group words.
split_command :: proc(s: string) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	b: strings.Builder
	strings.builder_init(&b, context.temp_allocator)
	quoted, has := false, false
	for r in s {
		switch {
		case r == '"':
			quoted, has = !quoted, true
		case (r == ' ' || r == '\t') && !quoted:
			if has {append(&out, strings.clone(strings.to_string(b), context.temp_allocator)); strings.builder_reset(&b); has = false}
		case:
			strings.write_rune(&b, r)
			has = true
		}
	}
	if has {append(&out, strings.clone(strings.to_string(b), context.temp_allocator))}
	return out[:]
}
