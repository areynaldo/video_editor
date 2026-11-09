package main

import "core:fmt"
import "core:math"
import "core:os"
import "core:strconv"
import "core:strings"

// All ffmpeg interaction goes through the CLI. ffmpeg/ffprobe must be on PATH.

probe :: proc(path: string) -> (s: Source, ok: bool) {
	state, out, _, err := os.process_exec(
		{
			command = {
				"ffprobe", "-v", "error",
				"-show_entries", "stream=codec_type",
				"-show_entries", "format=duration",
				"-of", "default=nw=1",
				path,
			},
		},
		context.temp_allocator,
	)
	if err != nil || !state.success {
		return
	}
	s.path = strings.clone(path)
	rest := string(out)
	for line in strings.split_lines_iterator(&rest) {
		line := strings.trim_space(line)
		switch {
		case line == "codec_type=video": s.has_video = true
		case line == "codec_type=audio": s.has_audio = true
		case strings.has_prefix(line, "duration="):
			s.duration, _ = strconv.parse_f64(line[len("duration="):])
		}
	}
	ok = s.duration > 0 && (s.has_video || s.has_audio)
	return
}

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
export :: proc(p: Project, out_path: string) -> bool {
	length := project_length(p)
	if length <= 0 {
		return false
	}
	W, H, FPS := int(p.settings.width) &~ 1, int(p.settings.height) &~ 1, int(p.settings.fps)

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
		append(&args, "-i", p.sources[c.source].path)
	}

	g: strings.Builder
	strings.builder_init(&g, context.temp_allocator)
	fmt.sbprintf(&g, "color=c=black:s=%dx%d:r=%d:d=%.3f[v0];", W, H, FPS, length)

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
				"[%d:v]trim=start=%.3f:duration=%.3f,setpts=(PTS-STARTPTS)/%.6f+%.3f/TB,fps=%d," +
					"scale=%d:%d:force_original_aspect_ratio=decrease,scale=iw*%.4f:ih*%.4f,setsar=1,format=rgba,",
					ci, c.in_point, c.duration * c.speed, c.speed, c.start, FPS, W, H, c.scale, c.scale,
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
				"[%d:a]atrim=start=%.3f:duration=%.3f,asetpts=PTS-STARTPTS,%s%sadelay=%d|%d[a%d];",
				ci, c.in_point, c.duration * c.speed, atempo_chain(c.speed), gain_filter(c.gain_db), ms, ms, acount,
			)
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
	append(&args, "-map", fmt.tprintf("[v%d]", vcount))
	if acount > 0 {
		append(&args, "-map", "[aout]")
	}
	append(&args, "-t", fmt.tprintf("%.3f", length), "-pix_fmt", "yuv420p", out_path)

	state, _, errout, err := os.process_exec({command = args[:]}, context.temp_allocator)
	if err != nil || !state.success {
		fmt.eprintln(string(errout))
		return false
	}
	return true
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
