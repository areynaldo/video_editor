package main

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:thread"
import "core:time"

// Project file: ini-like, one [source] section per source, one [clip] per clip.
// Sources are re-probed on load, so only their path is stored.

save_project :: proc(p: Project, path: string) -> bool {
	p := p
	b: strings.Builder
	strings.builder_init(&b, context.temp_allocator)
	s := p.settings
	fmt.sbprintf(&b, "[project]\nname = %s\nfps = %d\nwidth = %d\nheight = %d\nformat = %s\nquality = %d\n", settings_name(&p.settings), s.fps, s.width, s.height, FORMAT_EXT[s.format], int(s.quality))
	fmt.sbprintf(&b, "grid = %d\ngrid_type = %d\nbpm = %.9g\ngrid_div = %d\n", s.grid_on ? 1 : 0, int(s.grid_type), s.bpm, s.grid_div)
	fmt.sbprintf(&b, "cut_every = %d\nmaster = %.2f\ngrid_offset = %.9g\nrand_footage = %d\nrand_use_all = %d\nrand_spread = %d\nrand_slice = %d\nrand_pattern = %d\nrand_max_run = %d\nbg = %02x%02x%02x\nmask_w = %d\nmask_h = %d\nmask_color = %02x%02x%02x\nexport_mask = %d\nskip_normal = %d\nnative_res = %d\ngpu_encode = %d\n",s.cut_every, s.master_db, s.grid_offset, int(s.rand.footage), s.rand.use_all ? 1 : 0, s.rand.spread ? 1 : 0, int(s.rand.slice), s.rand.pattern, s.rand.max_run, int(s.bg.r * 255 + 0.5), int(s.bg.g * 255 + 0.5), int(s.bg.b * 255 + 0.5), s.mask_w, s.mask_h, int(s.mask_color.r * 255 + 0.5), int(s.mask_color.g * 255 + 0.5), int(s.mask_color.b * 255 + 0.5), s.export_mask ? 1 : 0, s.skip_normal ? 1 : 0, s.native_res ? 1 : 0, s.gpu_encode ? 1 : 0)
	fmt.sbprintf(&b, "pattern_sel = %d\nbpm_lo = %.0f\nbpm_hi = %.0f\n", s.pattern_sel, s.bpm_lo, s.bpm_hi)
	for pat in p.patterns {
		write_pattern(&b, pat)
	}
	write_lyric_style(&b, "lyrics", s.lyric)
	for layer in p.lyric_layers {write_lyric_style(&b, "lyric_layer", layer)}
	for l in p.lyrics {
		text, _ := strings.replace_all(text_of(l), "\n", "\\n", context.temp_allocator)
		fmt.sbprintf(&b, "\n[lyric]\nt0 = %.4f\nt1 = %.4f\nlayer = %d\nlink = %d\ntext = %s\n", l.t0, l.t1, int(l.layer), int(l.link), text)
	}
	for part in p.parts {
		fmt.sbprintf(&b, "\n[part]\nt0 = %.6f\nt1 = %.6f\npattern = %d\nanchor = %.6f\n", part.t0, part.t1, part.pattern, part.anchor)
	}
	for cut in p.program {
		fmt.sbprintf(&b, "\n[cut]\ntime = %.6f\nlayer = %d\nfixed = %d\n", cut.time, cut.layer, cut.fixed ? 1 : 0)
	}
	for flags_, i in p.track_flags {
		flags := flags_ - {.Selected}
		if flags != {} {
			fmt.sbprintf(&b, "\n[track]\nindex = %d\nflags = %d\n", i, transmute(u8)flags)
		}
	}
	for src in p.sources {
		size, mtime, _ := file_stamp(src.path)
		fmt.sbprintf(&b, "\n[source]\npath = %s\nsize = %d\nmtime = %d\nduration = %.6f\nvideo = %d\naudio = %d\nwidth = %d\nheight = %d\n", src.path, size, mtime, src.duration, src.has_video ? 1 : 0, src.has_audio ? 1 : 0, src.width, src.height)
	}
	for c in p.clips {
		fmt.sbprintf(
			&b,
			"\n[clip]\nsource = %d\nkind = %s\ntrack = %d\nstart = %.6f\nin = %.6f\nduration = %.6f\nspeed = %.6f\ngroup = %d\nx = %.3f\ny = %.3f\nscale = %.4f\nrotation = %.3f\ngain = %.2f\n",
			c.source, c.kind == .Video ? "video" : "audio", c.track, c.start, c.in_point, c.duration, c.speed, c.group, c.pos.x, c.pos.y, c.scale, c.rotation, c.gain_db,
			)
		if c.fit != .Fit {fmt.sbprintf(&b, "fit = %d\n", int(c.fit))}
		if c.odds > 0 {fmt.sbprintf(&b, "odds = %.4f\n", c.odds)}
		if c.slice {fmt.sbprintf(&b, "slice = 1\nlocked = %d\n", c.locked ? 1 : 0)}
		if c.freeze {strings.write_string(&b, "freeze = 1\n")}
		if c.black {strings.write_string(&b, "black = 1\n")}
	}
	return os.write_entire_file(path, transmute([]byte)strings.to_string(b)) == nil
}

// One [pattern] section: name, timing, one line per lane.
write_pattern :: proc(b: ^strings.Builder, pat: Pattern) {
	pat := pat
	fmt.sbprintf(b, "\n[pattern]\nname = %s\nlength = %d\ndiv = %d\nswing = %d\n", get_fixed(pat.name[:]), pat.length, pat.div, pat.swing)
	for li in 0 ..< int(pat.lane_count) { // lane = name;target;mute;steps
		lane := pat.lanes[li]
		fmt.sbprintf(b, "lane = %s;%d;%d;%d;", get_fixed(lane.name[:]), lane.target, lane.mute ? 1 : 0, int(lane.mode))
		for i in 0 ..< int(clamp(pat.length, 1, MAX_STEPS)) {
			fmt.sbprintf(b, "%s%d", i > 0 ? "," : "", lane.steps[i])
		}
		strings.write_string(b, "\n")
	}
}

// One `key = val` line of a [pattern] section (n: val as a number).
parse_pattern_key :: proc(pat: ^Pattern, key, val: string, n: int) {
	switch key {
	case "name":   set_fixed(pat.name[:], val)
	case "length": pat.length = clamp(i32(n), 1, MAX_STEPS)
	case "div":    pat.div = max(i32(n), 1)
	case "swing":  pat.swing = clamp(i32(n), 0, 75)
	case "lane": // name;target;mute;steps
		parts := strings.split(val, ";", context.temp_allocator)
		if len(parts) >= 4 {
			if lane := add_lane(pat, parts[0], i8(strconv.parse_int(parts[1]) or_else 0)); lane != nil {
				lane.mute = parts[2] == "1"
				steps := parts[3]
				if len(parts) >= 5 { // name;target;mute;mode;steps (older files: name;target;mute;steps)
					lane.mode = Lane_Mode(clamp(strconv.parse_int(parts[3]) or_else 0, 0, int(max(Lane_Mode))))
					steps = parts[4]
				}
				for part, i in strings.split(steps, ",", context.temp_allocator) {
					if i < MAX_STEPS {lane.steps[i] = u8(strconv.parse_int(strings.trim_space(part)) or_else 0) != 0 ? 1 : 0}
				}
			}
		}
	case "steps": // older projects: one value per step = the layer to show (0 = hold)
		vals := strings.split(val, ",", context.temp_allocator)
		seen := make([dynamic]int, context.temp_allocator)
		for part in vals {
			v := strconv.parse_int(strings.trim_space(part)) or_else 0
			if v != 0 && !slice.contains(seen[:], v) {append(&seen, v)}
		}
		for v in seen {
			lane := add_lane(pat, v > 0 ? fmt.tprintf("V%d", v) : "all", i8(v))
			if lane == nil {break}
			for part, i in vals {
				if i < MAX_STEPS && (strconv.parse_int(strings.trim_space(part)) or_else 0) == v {lane.steps[i] = 1}
			}
		}
	}
}

PATTERN_EXT :: ".pattern"
PATTERN_FILTER :: "Patterns|*.pattern|All files|*.*"

// Writes patterns to a file of their own (the same [pattern] sections a project has), to share or keep.
export_patterns :: proc(pats: []Pattern, path: string) -> bool {
	b: strings.Builder
	strings.builder_init(&b, context.temp_allocator)
	strings.write_string(&b, "# patterns\n")
	for pat in pats {write_pattern(&b, pat)}
	return os.write_entire_file(path, transmute([]byte)strings.to_string(b)) == nil
}

// Reads the patterns of such a file (a project file works too: only its patterns are taken).
import_patterns :: proc(path: string) -> (out: [dynamic]Pattern, ok: bool) {
	data, rerr := os.read_entire_file(path, context.temp_allocator)
	if rerr != nil {return}
	in_pattern := false
	rest := string(data)
	for line in strings.split_lines_iterator(&rest) {
		line := strings.trim_space(line)
		if line == "" || line[0] == '#' {continue}
		if line[0] == '[' {
			in_pattern = strings.trim(line, "[]") == "pattern"
			if in_pattern {append(&out, Pattern{length = 16, div = 4})}
			continue
		}
		eq := strings.index_byte(line, '=')
		if !in_pattern || eq < 0 {continue}
		key, val := strings.trim_space(line[:eq]), strings.trim_space(line[eq + 1:])
		parse_pattern_key(&out[len(out) - 1], key, val, int(strconv.parse_f64(val) or_else 0))
	}
	return out, len(out) > 0
}

// One lyric style as a section: "lyrics" is the first layer, "lyric_layer" the others.
write_lyric_style :: proc(b: ^strings.Builder, section: string, st: Lyric_Style) {
	st := st
	fmt.sbprintf(b, "\n[%s]\nname = %s\nsize = %.2f\nburn = %d\nmode = %d\ncolor = %06x\nborder = %06x\nborder_w = %.1f\nfont = %s\n", section, get_fixed(st.name[:]), st.size, st.burn ? 1 : 0, int(st.mode), rgb_hex(st.color), rgb_hex(st.border), st.border_w, get_fixed(st.font[:]))
	fmt.sbprintf(b, "frame = %.3f,%.3f,%.3f,%.3f\noffset = %.3f,%.3f\nsafe = %d\nvalign = %d\nhalign = %d\nfit = %d\nlink_to = %d\n", st.frame[0], st.frame[1], st.frame[2], st.frame[3], st.offset[0], st.offset[1], int(st.safe), int(st.valign), int(st.halign), st.fit ? 1 : 0, int(st.link_to))
}

parse_lyric_style_key :: proc(st: ^Lyric_Style, key, val: string, f: f64, n: int) {
	nums :: proc(val: string, out: []f32) {
		for part, i in strings.split(val, ",", context.temp_allocator) {
			if i < len(out) {out[i] = f32(strconv.parse_f64(strings.trim_space(part)) or_else 0)}
		}
	}
	switch key {
	case "name":     set_fixed(st.name[:], val)
	case "size":     st.size = f32(clamp(f, 1, 30))
	case "burn":     st.burn = n != 0
	case "mode":     st.mode = Lyric_Mode(clamp(n, 0, 2))
	case "color":    if v, ok := strconv.parse_int(val, 16); ok {st.color = hex_rgb(v)}
	case "border":   if v, ok := strconv.parse_int(val, 16); ok {st.border = hex_rgb(v)}
	case "border_w": st.border_w = f32(clamp(f, 0, 30))
	case "font":     set_fixed(st.font[:], val)
	case "frame":    nums(val, st.frame[:])
	case "offset":   nums(val, st.offset[:])
	case "safe":     st.safe = Safe_Zone(clamp(n, 0, int(max(Safe_Zone))))
	case "valign":   st.valign = Lyric_VAlign(clamp(n, 0, int(max(Lyric_VAlign))))
	case "link_to":  st.link_to = i32(max(n, 0))
	case "halign":   st.halign = Lyric_HAlign(clamp(n, 0, int(max(Lyric_HAlign))))
	case "fit":      st.fit = n != 0
	}
}

// The size and modified time of a file (how a changed file is noticed).
file_stamp :: proc(path: string) -> (size, mtime: i64, ok: bool) {
	fi, err := os.stat(path, context.temp_allocator)
	if err != nil {return}
	return fi.size, time.to_unix_nanoseconds(fi.modification_time), true
}

Probe_Job :: struct {
	path:   string,
	source: int,
	res:    Source,
	ok:     bool,
}

// Probes the files a few at a time on threads.
probe_all :: proc(jobs: []Probe_Job) {
	BATCH :: 8
	for base := 0; base < len(jobs); base += BATCH {
		n := min(BATCH, len(jobs) - base)
		threads: [BATCH]^thread.Thread
		for i in 0 ..< n {
			threads[i] = thread.create_and_start_with_poly_data(&jobs[base + i], proc(j: ^Probe_Job) {j.res, j.ok = probe(j.path)})
		}
		for i in 0 ..< n {
			thread.join(threads[i])
			thread.destroy(threads[i])
		}
	}
}

// Replaces the project. The caller resets the preview proxies first.
load_project :: proc(p: ^Project, path: string) -> (err: string) {
	data, rerr := os.read_entire_file(path, context.temp_allocator)
	if rerr != nil {
		return "could not read project file"
	}
	project_reset(p)

	section := ""
	track_index := -1
	rest := string(data)
	for line in strings.split_lines_iterator(&rest) {
		line := strings.trim_space(line)
		if line == "" || line[0] == '#' {
			continue
		}
		if line[0] == '[' {
			section = strings.clone(strings.trim(line, "[]"), context.temp_allocator)
			switch section {
			case "source": append(&p.sources, Source{})
			case "clip":   append(&p.clips, Clip{speed = 1, scale = 1})
			case "cut":    append(&p.program, Cut{layer = -1})
			case "pattern": append(&p.patterns, Pattern{length = 16, div = 4})
			case "part":    append(&p.parts, Part{pattern = -1, anchor = -1})
			case "lyric":   append(&p.lyrics, Lyric{})
			case "lyric_layer": append(&p.lyric_layers, default_lyric_style())
			}
			continue
		}
		eq := strings.index_byte(line, '=')
		if eq < 0 {
			continue
		}
		key, val := strings.trim_space(line[:eq]), strings.trim_space(line[eq + 1:])
		f := strconv.parse_f64(val) or_else 0
		n := int(f)
		switch section {
		case "project":
			switch key {
			case "name":   set_name(&p.settings, val)
			case "fps":    p.settings.fps = i32(n)
			case "width":  p.settings.width = i32(n)
			case "height": p.settings.height = i32(n)
			case "grid":      p.settings.grid_on = n != 0
			case "grid_type": p.settings.grid_type = Grid_Type(clamp(n, 0, 2))
			case "bpm":       p.settings.bpm = f32(f)
			case "grid_div":  p.settings.grid_div = i32(n)
			case "cut_every": p.settings.cut_every = max(i32(n), 1)
			case "master":    p.settings.master_db = f32(f)
			case "grid_offset": p.settings.grid_offset = f
			case "bpm_lo":       p.settings.bpm_lo = f32(clamp(f, 40, 220))
			case "bpm_hi":       p.settings.bpm_hi = f32(clamp(f, 60, 260))
			case "pattern_sel":  p.settings.pattern_sel = i32(max(n, 0))
			case "rand_footage": p.settings.rand.footage = Rand_Footage(clamp(n, 0, 2))
			case "rand_use_all": p.settings.rand.use_all = n != 0
			case "rand_spread": p.settings.rand.spread = n != 0
			case "bg":
				if v, ok := strconv.parse_int(val, 16); ok {
					p.settings.bg = {f32((v >> 16) & 255) / 255, f32((v >> 8) & 255) / 255, f32(v & 255) / 255}
				}
			case "mask_w": p.settings.mask_w = i32(max(n, 0))
			case "mask_h": p.settings.mask_h = i32(max(n, 0))
			case "export_mask": p.settings.export_mask = n != 0
			case "skip_normal": p.settings.skip_normal = n != 0
			case "native_res":  p.settings.native_res = n != 0
			case "gpu_encode":  p.settings.gpu_encode = n != 0
			case "mask_color":
				if v, ok := strconv.parse_int(val, 16); ok {
					p.settings.mask_color = {f32((v >> 16) & 255) / 255, f32((v >> 8) & 255) / 255, f32(v & 255) / 255}
				}
			case "rand_slice":   p.settings.rand.slice = Rand_Slice(clamp(n, 0, 2))
			case "rand_pattern": p.settings.rand.pattern = i32(n)
			case "rand_max_run": p.settings.rand.max_run = i32(max(n, 0))
			case "quality": p.settings.quality = Export_Quality(clamp(n, 0, 2))
			case "format":
				for ext, fmt_ in FORMAT_EXT {
					if ext == val {p.settings.format = fmt_}
				}
			}
		case "lyrics": parse_lyric_style_key(&p.settings.lyric, key, val, f, n)
		case "lyric_layer": parse_lyric_style_key(&p.lyric_layers[len(p.lyric_layers) - 1], key, val, f, n)
		case "lyric":
			l := &p.lyrics[len(p.lyrics) - 1]
			switch key {
			case "t0":   l.t0 = f
			case "t1":   l.t1 = f
			case "layer": l.layer = i32(max(n, 0))
			case "link":  l.link = i32(max(n, 0))
			case "text":
				text, _ := strings.replace_all(val, "\\n", "\n", context.temp_allocator)
				set_fixed(l.text[:], text)
			}
		case "track":
			switch key {
			case "index":
				track_index = n
				for len(p.track_flags) <= n {append(&p.track_flags, Track_Flags{})}
			case "flags":
				if track_index >= 0 && track_index < len(p.track_flags) {
					p.track_flags[track_index] = transmute(Track_Flags)u8(n)
				}
			}
		case "pattern": parse_pattern_key(&p.patterns[len(p.patterns) - 1], key, val, n)
		case "part":
			part := &p.parts[len(p.parts) - 1]
			switch key {
			case "t0":      part.t0 = f
			case "t1":      part.t1 = f
			case "anchor":  part.anchor = f
			case "pattern": part.pattern = i32(n)
			}
		case "cut":
			c := &p.program[len(p.program) - 1]
			switch key {
			case "time":  c.time = f
			case "layer": c.layer = n
			case "fixed": c.fixed = n != 0
			}
		case "source":
			s := &p.sources[len(p.sources) - 1]
			switch key {
			case "path":     s.path = strings.clone(val)
			case "size":     s.size = strconv.parse_i64(val) or_else 0
			case "mtime":    s.mtime = strconv.parse_i64(val) or_else 0
			case "duration": s.duration = f
			case "video":    s.has_video = n != 0
			case "audio":    s.has_audio = n != 0
			case "width":    s.width = n
			case "height":   s.height = n
			}
		case "clip":
			c := &p.clips[len(p.clips) - 1]
			switch key {
			case "source":   c.source = n
			case "kind":     c.kind = val == "audio" ? .Audio : .Video
			case "track":    c.track = n
			case "start":    c.start = f
			case "odds":     c.odds = f32(max(f, 0))
			case "in":       c.in_point = f
			case "duration": c.duration = f
			case "speed":    c.speed = f
			case "group":    c.group = n
			case "slice":    c.slice = n != 0
			case "freeze":   c.freeze = n != 0
			case "black":    c.black = n != 0
			case "fit":      c.fit = Fit_Mode(clamp(n, 0, 2))
			case "locked":   c.locked = n != 0
			case "x":        c.pos.x = f32(f)
			case "y":        c.pos.y = f32(f)
			case "scale":    c.scale = f32(f)
			case "rotation": c.rotation = f32(f)
			case "gain":     c.gain_db = f32(f)
			}
		}
	}

	// re-probe sources, derive counters, validate references
	// A source whose file has the size and time it had when saved keeps what was saved; the others are
	// probed, several at a time (each probe is a process start: one after the other they add up).
	jobs := make([dynamic]Probe_Job, context.temp_allocator)
	for &s, i in p.sources {
		size, mtime, found := file_stamp(s.path)
		if found && s.duration > 0 && s.size == size && s.mtime == mtime {continue}
		s.size, s.mtime = size, mtime
		append(&jobs, Probe_Job{path = s.path, source = i})
	}
	probe_all(jobs[:])
	for j in jobs {
		if j.ok {
			s := &p.sources[j.source]
			s.duration, s.has_video, s.has_audio = j.res.duration, j.res.has_video, j.res.has_audio
			s.width, s.height = j.res.width, j.res.height
		}
	}
	for s in p.sources {
		media_start(s, int(clamp(p.settings.fps, 1, 30)))
	}
	#reverse for c, i in p.clips {
		if c.source < 0 || c.source >= len(p.sources) || c.speed <= 0 || c.duration <= 0 {
			ordered_remove(&p.clips, i)
		}
	}
	slice.sort_by(p.program[:], proc(a, b: Cut) -> bool {return a.time < b.time})
	defer sync_tracks(p)
	for c in p.clips {
		p.track_count = max(p.track_count, c.track + 1)
		p.next_group = max(p.next_group, c.group)
	}
	return ""
}
