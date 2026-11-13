package main

import "core:fmt"
import "core:math"
import "core:os"
import "core:strconv"
import "core:slice"
import "core:strings"

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

// Renders the whole timeline. Video: black canvas, each clip fitted into it, then
// scaled / rotated / offset by its transform and overlaid in track order.
// Audio: every audio clip delayed to its start and mixed. One -i per clip.
// The container comes from out_path's extension.
export :: proc(p: Project, out_path: string) -> (ok: bool, err: string) {
	length := project_length(p)
	if length <= 0 {
		return false, "nothing to export"
	}
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
	for c in p.clips {
		// -ss / -t before -i: ffmpeg jumps to the piece instead of decoding the file from its start for every
		// clip (with hundreds of slices of one long video that was the whole export time)
		append(&args, "-ss", fmt.tprintf("%.3f", c.in_point), "-t", fmt.tprintf("%.3f", c.duration * c.speed), "-i", p.sources[c.source].path)
	}

	g: strings.Builder
	strings.builder_init(&g, context.temp_allocator)
	bg := p.settings.bg
	fmt.sbprintf(&g, "color=c=0x%02x%02x%02x:s=%dx%d:r=%d:d=%.3f[v0];", int(bg.r * 255 + 0.5), int(bg.g * 255 + 0.5), int(bg.b * 255 + 0.5), W, H, FPS, length)

	vcount, acount: int
	for ci in order {
		c := p.clips[ci]
		switch c.kind {
		case .Video:
			if track_has(p, c.track, .Hidden) {
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
			fmt.sbprintf(
				&g,
				"[%d:v]setpts=(PTS-STARTPTS)/%.6f+%.3f/TB,fps=%d," +
					"scale=%d:%d%s,scale=iw*%.4f:ih*%.4f,setsar=1,format=rgba,",
					ci, c.speed, c.start, FPS, MW, MH, fit_filter[c.fit], c.scale, c.scale,
				)
			if c.rotation != 0 {
				fmt.sbprintf(&g, "rotate=a=%.6f:ow='hypot(iw,ih)':oh='hypot(iw,ih)':c=none,", f64(c.rotation) * math.PI / 180)
			}
			fmt.sbprintf(
				&g,
				"null[c%d];[v%d][c%d]overlay=x=(W-w)/2+%.1f:y=(H-h)/2+%.1f:eof_action=pass%s[v%d];",
				vcount, vcount - 1, vcount, c.pos.x, c.pos.y, strings.to_string(enable), vcount,
				)
		case .Audio:
			if !track_audible(p, c.track) {
				continue
			}
			acount += 1
			ms := int(c.start * 1000)
			fmt.sbprintf(
				&g,
				"[%d:a]asetpts=PTS-STARTPTS,%s%sadelay=%d|%d[a%d];",
				ci, atempo_chain(c.speed), gain_filter(c.gain_db), ms, ms, acount,
				)
		}
	}
	// lyrics: one drawtext for each line, burned into the finished picture
	final := fmt.tprintf("[v%d]", vcount)
	if MW < W || MH < H { // the bars of the mask, over whatever spills out of the area
		bc := p.settings.mask_color
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
	if s := p.settings; s.lyric_burn && len(p.lyrics) > 0 {
		if font := lyric_font_path(s); font != "" {
			size := max(int(f64(H) * f64(s.lyric_size) / 100), 8)
			lh := int(f64(size) * LYRIC_LINE_H)
			border := int(f64(size) * f64(s.lyric_border_w) / 100)
			strings.write_string(&g, final)
			shows := make([dynamic]Show, context.temp_allocator)
			build_shows(p, &shows)
			for show, i in shows {
				file := fmt.tprintf("%s.lyric%d.txt", out_path, i)
				_ = os.write_entire_file(file, transmute([]byte)show_text(p, show))
				append(&lyric_files, file)
				top := H - int(f64(H) * LYRIC_BOTTOM) - (show.rows - show.row) * lh
				fmt.sbprintf(
					&g,
					"%sdrawtext=fontfile='%s':textfile='%s':expansion=none:fontsize=%d:fontcolor=0x%06x:borderw=%d:bordercolor=0x%06x:line_spacing=%d:x=(w-text_w)/2:y=%d:enable='between(t,%.3f,%.3f)'",
					i > 0 ? "," : "", filter_path(font), filter_path(file), size, rgb_hex(s.lyric_color), border, rgb_hex(s.lyric_border), lh - size, top, show.t0, show.t1,
					)
			}
			strings.write_string(&g, "[vtext];")
			final = "[vtext]"
		} else {
			fmt.eprintln("lyrics not burned: no font found")
		}
	}
	if acount > 0 {
		for i in 1 ..= acount {
			fmt.sbprintf(&g, "[a%d]", i)
		}
		fmt.sbprintf(&g, "amix=inputs=%d:normalize=0:duration=longest,%s[aout]", acount, gain_filter(p.settings.master_db, true))
	}
	graph := strings.trim_right(strings.to_string(g), ";")

	// long graphs (many cuts) would exceed the Windows command-line limit: pass them as a file
	script := strings.concatenate({out_path, ".filter.txt"}, context.temp_allocator)
	if len(graph) > 16000 {
		_ = os.write_entire_file(script, transmute([]byte)graph)
		append(&args, "-filter_complex_script", script)
	} else {
		append(&args, "-filter_complex", graph)
	}
	defer os.remove(script)
	append(&args, "-map", final)
	if acount > 0 {
		append(&args, "-map", "[aout]")
	}
	append(&args, "-t", fmt.tprintf("%.3f", length), "-pix_fmt", "yuv420p")
	append(&args, ..quality_args(p.settings.format, p.settings.quality))
	append(&args, out_path)

	// runs as a background job: the bar follows ffmpeg's own progress report
	if msg := ffmpeg_tracked(args[2:], length, 0, 1); msg != "" {
		os.remove(out_path) // a half written file is no export
		return false, msg
	}
	return true, ""
}

Export_Job :: struct {
	p:    Project, // a shallow copy: the loading window keeps the project from being edited while it runs
	path: string, // heap
	err:  string, // heap; "" = fine
}

export_work :: proc(data: rawptr) {
	d := (^Export_Job)(data)
	job_step("encoding the video ...")
	_, err := export(d.p, d.path)
	d.err = strings.clone(err)
}

export_finish :: proc(data: rawptr) {
	d := (^Export_Job)(data)
	defer {
		delete(d.path)
		delete(d.err)
		free(d)
	}
	switch d.err {
	case "":        set_status("exported %s", d.path)
	case "stopped": set_status("export stopped")
	case:
		set_status("export failed: %s", d.path)
		job_report("The export did not finish", d.err)
	}
}

// Codec settings for the export. Without them ffmpeg uses its defaults (x264 crf 23, aac 128k), which
// is what makes an export look compressed. x264: constant quality (crf: lower = better), slow preset.
// WebM cannot hold x264: VP9 + Opus.
quality_args :: proc(format: Export_Format, q: Export_Quality) -> []string {
	crf := [Export_Quality]string{.Typical = "19", .High = "16", .Max = "12"}
	vp9 := [Export_Quality]string{.Typical = "32", .High = "24", .Max = "17"}
	audio := [Export_Quality]string{.Typical = "192k", .High = "256k", .Max = "320k"}
	out := make([dynamic]string, context.temp_allocator)
	if format == .WebM {
		append(&out, "-c:v", "libvpx-vp9", "-crf", vp9[q], "-b:v", "0", "-row-mt", "1", "-c:a", "libopus", "-b:a", audio[q])
		return out[:]
	}
	append(&out, "-c:v", "libx264", "-crf", crf[q], "-preset", q == .Typical ? "medium" : "slow", "-c:a", "aac", "-b:a", audio[q])
	if format == .MP4 || format == .MOV {append(&out, "-movflags", "+faststart")}
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
