package main

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"

// Project file: ini-like, one [source] section per source, one [clip] per clip.
// Sources are re-probed on load, so only their path is stored.

save_project :: proc(p: Project, path: string) -> bool {
	p := p
	b: strings.Builder
	strings.builder_init(&b, context.temp_allocator)
	s := p.settings
	fmt.sbprintf(&b, "[project]\nname = %s\nfps = %d\nwidth = %d\nheight = %d\nformat = %s\n", settings_name(&p.settings), s.fps, s.width, s.height, FORMAT_EXT[s.format])
	fmt.sbprintf(&b, "grid = %d\ngrid_type = %d\nbpm = %.3f\ngrid_div = %d\n", s.grid_on ? 1 : 0, int(s.grid_type), s.bpm, s.grid_div)
	fmt.sbprintf(&b, "cut_every = %d\nmaster = %.2f\ngrid_offset = %.4f\nrand_footage = %d\nrand_use_all = %d\nrand_slice = %d\nrand_pattern = %d\nrand_max_run = %d\nbg = %02x%02x%02x\n", s.cut_every, s.master_db, s.grid_offset, int(s.rand.footage), s.rand.use_all ? 1 : 0, int(s.rand.slice), s.rand.pattern, s.rand.max_run, int(s.bg.r * 255 + 0.5), int(s.bg.g * 255 + 0.5), int(s.bg.b * 255 + 0.5))
	fmt.sbprintf(&b, "pattern_sel = %d\nbpm_lo = %.0f\nbpm_hi = %.0f\n", s.pattern_sel, s.bpm_lo, s.bpm_hi)
	for pat in p.patterns {
		pat := pat
		fmt.sbprintf(&b, "\n[pattern]\nname = %s\nlength = %d\ndiv = %d\nswing = %d\n", get_fixed(pat.name[:]), pat.length, pat.div, pat.swing)
		for li in 0 ..< int(pat.lane_count) { // lane = name;target;mute;steps
			lane := pat.lanes[li]
			fmt.sbprintf(&b, "lane = %s;%d;%d;", get_fixed(lane.name[:]), lane.target, lane.mute ? 1 : 0)
			for i in 0 ..< int(clamp(pat.length, 1, MAX_STEPS)) {
				fmt.sbprintf(&b, "%s%d", i > 0 ? "," : "", lane.steps[i])
			}
			strings.write_string(&b, "\n")
		}
	}
	for part in p.parts {
		fmt.sbprintf(&b, "\n[part]\nt0 = %.6f\nt1 = %.6f\npattern = %d\n", part.t0, part.t1, part.pattern)
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
		fmt.sbprintf(&b, "\n[source]\npath = %s\n", src.path)
	}
	for c in p.clips {
		fmt.sbprintf(
			&b,
			"\n[clip]\nsource = %d\nkind = %s\ntrack = %d\nstart = %.6f\nin = %.6f\nduration = %.6f\nspeed = %.6f\ngroup = %d\nx = %.3f\ny = %.3f\nscale = %.4f\nrotation = %.3f\ngain = %.2f\n",
			c.source, c.kind == .Video ? "video" : "audio", c.track, c.start, c.in_point, c.duration, c.speed, c.group, c.pos.x, c.pos.y, c.scale, c.rotation, c.gain_db,
		)
	}
	return os.write_entire_file(path, transmute([]byte)strings.to_string(b)) == nil
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
			case "part":    append(&p.parts, Part{pattern = -1})
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
			case "bg":
				if v, ok := strconv.parse_int(val, 16); ok {
					p.settings.bg = {f32((v >> 16) & 255) / 255, f32((v >> 8) & 255) / 255, f32(v & 255) / 255}
				}
			case "rand_slice":   p.settings.rand.slice = Rand_Slice(clamp(n, 0, 2))
			case "rand_pattern": p.settings.rand.pattern = i32(n)
			case "rand_max_run": p.settings.rand.max_run = i32(max(n, 0))
			case "format":
				for ext, fmt_ in FORMAT_EXT {
					if ext == val {p.settings.format = fmt_}
				}
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
		case "pattern":
			pat := &p.patterns[len(p.patterns) - 1]
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
						for part, i in strings.split(parts[3], ",", context.temp_allocator) {
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
		case "part":
			part := &p.parts[len(p.parts) - 1]
			switch key {
			case "t0":      part.t0 = f
			case "t1":      part.t1 = f
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
			if key == "path" {
				p.sources[len(p.sources) - 1].path = strings.clone(val)
			}
		case "clip":
			c := &p.clips[len(p.clips) - 1]
			switch key {
			case "source":   c.source = n
			case "kind":     c.kind = val == "audio" ? .Audio : .Video
			case "track":    c.track = n
			case "start":    c.start = f
			case "in":       c.in_point = f
			case "duration": c.duration = f
			case "speed":    c.speed = f
			case "group":    c.group = n
			case "x":        c.pos.x = f32(f)
			case "y":        c.pos.y = f32(f)
			case "scale":    c.scale = f32(f)
			case "rotation": c.rotation = f32(f)
			case "gain":     c.gain_db = f32(f)
			}
		}
	}

	// re-probe sources, derive counters, validate references
	for &s in p.sources {
		if probed, ok := probe(s.path); ok {
			s.duration, s.has_video, s.has_audio = probed.duration, probed.has_video, probed.has_audio
		}
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
