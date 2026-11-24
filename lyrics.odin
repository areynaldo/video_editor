package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:strconv"
import "core:unicode/utf8"

import im "deps/odin-imgui"

// Lyrics: timed text lines (subtitles). A line is plain data: start, end, text (the
// text may hold newlines: a two-line subtitle). Lines are shown in the Program
// preview, burned into the export, and edited in three ways:
//   the Lyrics panel   one text, a line each:  [00:12.30-00:15.00] text   (\n = new line in a line)
//   the timeline       the Lyrics row: drag a line, drag its edges
//   Tap / Spread       time the lines while the song plays, or spread them over a range
// Import and export: SRT, LRC, ASS (export), TXT.

LYRIC_CHARS :: 240
LYRIC_DEFAULT :: 2.5 // seconds a line lasts when nothing else says so

Lyric :: struct {
	t0, t1: f64, // seconds on the timeline
	text:   [LYRIC_CHARS]u8,
	layer:  i32, // which lyric layer (a language, a style): 0 is the first
	link:   i32, // 0 = alone; lines with the same number are linked: they are selected, moved, trimmed, split and deleted together
	selected: bool, // part of the selection (not part of undo)
}

show_lyrics: bool
sel_lyric := -1 // selected line (timeline row or panel)
lyr_tap: int // the line the next Tap times
lyr_buf: [32768]u8 // the text of the Lyrics panel
lyr_active: bool // the text box had focus last frame: do not rewrite it
lyr_base: [dynamic][2]f64 // start and end of every line when a drag began (stretching works from them)

// The text of a line (a copy: safe to keep).
text_of :: proc(l: Lyric) -> string {
	l := l
	return strings.clone(get_fixed(l.text[:]), context.temp_allocator)
}

// ---------------------------------------------------------------- layers
// Every layer has its own lines (a language, a translation, a second look) and its own style (lyric_style.odin).
// The lines of all layers are in one list sorted by time. The text tools (text box, tap, spread, align, import,
// export) were written for one list of lines: lyrics_park leaves only the lines of one layer in the list, the
// others wait in `lyrics_parked`; lyrics_unpark puts them back.

lyrics_parked: [dynamic]Lyric

lyrics_park :: proc(layer: int) {
	clear(&lyrics_parked)
	keep := make([dynamic]Lyric, context.temp_allocator)
	for l in project.lyrics {
		if int(l.layer) == layer {append(&keep, l)} else {append(&lyrics_parked, l)}
	}
	clear(&project.lyrics)
	append(&project.lyrics, ..keep[:])
	sel_lyric = -1
}

lyrics_unpark :: proc(layer: int) {
	for &l in project.lyrics {l.layer = i32(layer)} // lines made meanwhile belong to the layer
	append(&project.lyrics, ..lyrics_parked[:])
	clear(&lyrics_parked)
	sel_lyric = -1
	lyrics_sort(&project)
}

// How many lines of a layer come before line i in that layer's own order.
lyric_rank :: proc(p: Project, i: int) -> (n: int) {
	for k in 0 ..< i {
		if p.lyrics[k].layer == p.lyrics[i].layer {n += 1}
	}
	return
}

lyric_layer_lines :: proc(p: Project, layer: int) -> (n: int) {
	for l in p.lyrics {n += int(l.layer) == layer ? 1 : 0}
	return
}

// A link number no line uses.
lyric_new_link :: proc(p: Project) -> i32 {
	n := i32(0)
	for l in p.lyrics {n = max(n, l.link)}
	return n + 1
}

// Every line linked to a selected line is selected too.
lyrics_select_linked :: proc() {
	for i in 0 ..< len(project.lyrics) {
		g := project.lyrics[i].link
		if g == 0 || !project.lyrics[i].selected {continue}
		for &l in project.lyrics {
			if l.link == g {l.selected = true}
		}
	}
}

// The selected lines become one linked group (a Spanish line and its German line: cut or move one, the other follows).
lyrics_link_selected :: proc() -> (n: int) {
	g := lyric_new_link(project)
	for &l in project.lyrics {
		if l.selected {l.link = g; n += 1}
	}
	if n < 2 { // a group of one is no group
		for &l in project.lyrics {
			if l.link == g {l.link = 0}
		}
		return 0
	}
	return
}

lyrics_unlink_selected :: proc() -> (n: int) {
	for &l in project.lyrics {
		if l.selected && l.link != 0 {l.link = 0; n += 1}
	}
	return
}

// Layers can be linked in pairs (a Spanish layer and its German one). Linking pairs their lines in order (line 1 with
// line 1, ...): paired lines carry the same `link` number, so selecting, moving, trimming, cutting with the razor,
// deleting and duplicating a line does the same to its partner. Typing in either layer's text box pairs them again.

// Pairs the lines of layers a and b by their order. Returns how many pairs.
lyrics_pair_layers :: proc(a, b: int) -> (n: int) {
	ia, ib := make([dynamic]int, context.temp_allocator), make([dynamic]int, context.temp_allocator)
	for l, i in project.lyrics {
		if int(l.layer) == a {append(&ia, i)} else if int(l.layer) == b {append(&ib, i)}
	}
	for k in 0 ..< min(len(ia), len(ib)) {
		g := project.lyrics[ia[k]].link
		if g == 0 {g = lyric_new_link(project)}
		project.lyrics[ia[k]].link, project.lyrics[ib[k]].link = g, g
		n += 1
	}
	return
}

// Links layer a with layer b (each has one partner).
lyric_layers_link :: proc(a, b: int) -> int {
	count := lyric_layer_count(project)
	if a == b || a < 0 || b < 0 || a >= count || b >= count {return 0}
	lyric_layer_unlink(a)
	lyric_layer_unlink(b)
	lyric_style_ref(&project, a).link_to = i32(b + 1)
	lyric_style_ref(&project, b).link_to = i32(a + 1)
	return lyrics_pair_layers(a, b)
}

// Unlinks a layer from its partner: the pairs between them are undone, the lines stay.
lyric_layer_unlink :: proc(a: int) {
	st := lyric_style_ref(&project, a)
	b := int(st.link_to) - 1
	st.link_to = 0
	if b < 0 || b >= lyric_layer_count(project) {return}
	pb := lyric_style_ref(&project, b)
	if int(pb.link_to) - 1 == a {pb.link_to = 0}
	shared := make(map[i32]bool, context.temp_allocator) // the groups that have a line in both layers
	groups := make(map[i32]int, context.temp_allocator)
	for l in project.lyrics {
		if l.link == 0 {continue}
		if int(l.layer) == a {groups[l.link] |= 1} else if int(l.layer) == b {groups[l.link] |= 2}
	}
	for g, bits in groups {
		if bits == 3 {shared[g] = true}
	}
	for &l in project.lyrics {
		if (int(l.layer) == a || int(l.layer) == b) && l.link != 0 && l.link in shared {l.link = 0}
	}
}

// ---------------------------------------------------------------- text format

stamp_str :: proc(t: f64) -> string {
	cs := int(max(t, 0) * 100 + 0.5)
	return fmt.tprintf("%02d:%02d.%02d", cs / 6000, cs / 100 % 60, cs % 100)
}

// "mm:ss.cc", "h:mm:ss,mmm", "mm:ss"
parse_stamp :: proc(s: string) -> (t: f64, ok: bool) {
	parts := strings.split(strings.trim_space(s), ":", context.temp_allocator)
	if len(parts) < 2 || len(parts) > 3 {
		return
	}
	mult := 1.0
	for i := len(parts) - 1; i >= 0; i -= 1 {
		p, _ := strings.replace_all(parts[i], ",", ".", context.temp_allocator)
		v, vok := strconv.parse_f64(p)
		if !vok || v < 0 {
			return 0, false
		}
		t += v * mult
		mult *= 60
	}
	return t, true
}

// One line of the Lyrics panel text.
lyric_line :: proc(l: Lyric) -> string {
	text, _ := strings.replace_all(text_of(l), "\n", "\\n", context.temp_allocator)
	return fmt.tprintf("[%s-%s] %s", stamp_str(l.t0), stamp_str(l.t1), text)
}

lyrics_to_text :: proc(p: Project, layer: int) -> string {
	b: strings.Builder
	strings.builder_init(&b, context.temp_allocator)
	for l in p.lyrics {
		if int(l.layer) != layer {continue}
		strings.write_string(&b, lyric_line(l))
		strings.write_byte(&b, '\n')
	}
	return strings.to_string(b)
}

Parsed :: struct {
	t0, t1:     f64,
	has0, has1: bool,
	text, raw:  string,
}

// skip: an empty line, or an LRC tag like [ar:Artist]
parse_line :: proc(raw: string) -> (r: Parsed, skip: bool) {
	line := strings.trim_space(raw)
	r.raw, r.text = line, line
	if line == "" {
		return r, true
	}
	if line[0] == '[' {
		if end := strings.index_byte(line, ']'); end > 0 {
			inner, rest := line[1:end], strings.trim_space(line[end + 1:])
			if dash := strings.index_byte(inner, '-'); dash > 0 {
				a, aok := parse_stamp(inner[:dash])
				b, bok := parse_stamp(inner[dash + 1:])
				if aok && bok {
					r.t0, r.t1, r.has0, r.has1, r.text = a, b, true, true, rest
					return
				}
			}
			if a, ok := parse_stamp(inner); ok {
				r.t0, r.has0, r.text = a, true, rest
				return
			}
			if (inner[0] | 32) >= 'a' && (inner[0] | 32) <= 'z' && strings.contains_rune(inner, ':') {
				return r, true
			}
		}
	}
	return
}

// Replaces the lines by the text. A line that is unchanged keeps its exact times.
// No start: the line starts where the one before ends. No end: it ends where the
// next one starts, else after LYRIC_DEFAULT seconds.
lyrics_from_text :: proc(p: ^Project, text: string) {
	rows := make([dynamic]Parsed, context.temp_allocator)
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		if r, skip := parse_line(line); !skip {
			append(&rows, r)
		}
	}
	old := slice.clone(p.lyrics[:], context.temp_allocator)
	clear(&p.lyrics)
	prev_end := 0.0
	for r, i in rows {
		l: Lyric
		if i < len(old) && lyric_line(old[i]) == r.raw {
			l = old[i]
		} else {
			l.t0 = r.has0 ? r.t0 : prev_end
			switch {
			case r.has1:                                                         l.t1 = r.t1
			case i + 1 < len(rows) && rows[i + 1].has0 && rows[i + 1].t0 > l.t0: l.t1 = rows[i + 1].t0
			case:                                                                l.t1 = l.t0 + LYRIC_DEFAULT
			}
			l.t1 = max(l.t1, l.t0 + MIN_DURATION)
			text, _ := strings.replace_all(r.text, "\\n", "\n", context.temp_allocator)
			set_fixed(l.text[:], text)
		}
		prev_end = l.t1
		append(&p.lyrics, l)
	}
	sel_lyric = min(sel_lyric, len(p.lyrics) - 1)
}

lyrics_from_srt :: proc(p: ^Project, data: string) {
	clear(&p.lyrics)
	text, _ := strings.replace_all(data, "\r\n", "\n", context.temp_allocator)
	for block in strings.split(text, "\n\n", context.temp_allocator) {
		lines := strings.split(strings.trim_space(block), "\n", context.temp_allocator)
		k := 0
		for k < len(lines) && !strings.contains(lines[k], "-->") {k += 1}
		if k >= len(lines) {continue}
		arrow := strings.index(lines[k], "-->")
		t0, ok0 := parse_stamp(lines[k][:arrow])
		t1, ok1 := parse_stamp(lines[k][arrow + 3:])
		if !ok0 || !ok1 {continue}
		l := Lyric{t0 = t0, t1 = max(t1, t0 + MIN_DURATION)}
		set_fixed(l.text[:], strings.trim_space(strings.join(lines[k + 1:], "\n", context.temp_allocator)))
		append(&p.lyrics, l)
	}
}

lyrics_import :: proc(p: ^Project, path: string) -> bool {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		return false
	}
	text := string(data)
	if strings.has_prefix(text, "\xEF\xBB\xBF") {text = text[3:]} // BOM
	if strings.contains(text, "-->") {
		lyrics_from_srt(p, text)
	} else {
		lyrics_from_text(p, text)
	}
	lyrics_sort(p)
	lyr_tap = 0
	return len(p.lyrics) > 0
}

lyrics_export :: proc(p: Project, path: string) -> bool {
	b: strings.Builder
	strings.builder_init(&b, context.temp_allocator)
	ext := strings.to_lower(filepath.ext(path), context.temp_allocator)
	time_str :: proc(t: f64, sep: string, digits: int) -> string { // h:mm:ss<sep>fraction
		ms := int(max(t, 0) * 1000 + 0.5)
		if digits == 2 {
			return fmt.tprintf("%d:%02d:%02d%s%02d", ms / 3600000, ms / 60000 % 60, ms / 1000 % 60, sep, ms % 1000 / 10)
		}
		return fmt.tprintf("%02d:%02d:%02d%s%03d", ms / 3600000, ms / 60000 % 60, ms / 1000 % 60, sep, ms % 1000)
	}
	switch ext {
	case ".srt":
		for l, i in p.lyrics {
			fmt.sbprintf(&b, "%d\n%s --> %s\n%s\n\n", i + 1, time_str(l.t0, ",", 3), time_str(l.t1, ",", 3), text_of(l))
		}
	case ".lrc":
		for l in p.lyrics {
			text, _ := strings.replace_all(text_of(l), "\n", " ", context.temp_allocator)
			fmt.sbprintf(&b, "[%s]%s\n", stamp_str(l.t0), text)
		}
	case ".ass":
		s := p.settings
		size := int(f64(s.height) * f64(s.lyric.size) / 100)
		fmt.sbprintf(
			&b,
			"[Script Info]\nScriptType: v4.00+\nPlayResX: %d\nPlayResY: %d\n\n[V4+ Styles]\n" +
			"Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding\n" +
			"Style: Default,Arial,%d,%s,%s,%s,&H80000000,0,0,0,0,100,100,0,0,1,%d,0,2,40,40,%d,1\n\n" +
			"[Events]\nFormat: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\n",
			s.width, s.height, size, ass_color(s.lyric.color), ass_color(s.lyric.color), ass_color(s.lyric.border), max(int(f64(size) * f64(s.lyric.border_w) / 100), 0), int(s.height) * 8 / 100,
			)
		for l in p.lyrics {
			text, _ := strings.replace_all(text_of(l), "\n", "\\N", context.temp_allocator)
			fmt.sbprintf(&b, "Dialogue: 0,%s,%s,Default,,0,0,0,,%s\n", time_str(l.t0, ".", 2), time_str(l.t1, ".", 2), text)
		}
	case:
		for l in p.lyrics {
			fmt.sbprintf(&b, "%s\n", text_of(l))
		}
	}
	return os.write_entire_file(path, transmute([]byte)strings.to_string(b)) == nil
}

// ---------------------------------------------------------------- editing

lyrics_sort :: proc(p: ^Project) {
	keep := sel_lyric >= 0 && sel_lyric < len(p.lyrics) ? p.lyrics[sel_lyric].t0 : -1
	slice.stable_sort_by(p.lyrics[:], proc(a, b: Lyric) -> bool {return a.t0 < b.t0})
	if keep >= 0 {
		for l, i in p.lyrics {
			if l.t0 == keep {sel_lyric = i}
		}
	}
}

// ---- selection: click, ctrl+click toggles, shift+click a range, drag a box on the row

lyrics_deselect :: proc() {
	for &l in project.lyrics {l.selected = false}
	sel_lyric = -1
}

lyrics_selected :: proc() -> (n: int) {
	for l in project.lyrics {n += l.selected ? 1 : 0}
	return
}

// Selects line i the way a click with those keys does.
lyric_select :: proc(i: int, ctrl, shift: bool) {
	n := len(project.lyrics)
	if i < 0 || i >= n {return}
	switch {
	case shift && sel_lyric >= 0 && sel_lyric < n: // the range from the last clicked line
		for k in min(i, sel_lyric) ..= max(i, sel_lyric) {project.lyrics[k].selected = true}
	case ctrl:
		project.lyrics[i].selected = !project.lyrics[i].selected
		sel_lyric = i
	case:
		if !project.lyrics[i].selected {lyrics_deselect()}
		project.lyrics[i].selected = true
		sel_lyric = i
	}
	lyrics_select_linked()
}

// A copy of every selected line right after it (the same length, the same layer); the copies are selected.
lyrics_duplicate_selected :: proc() -> (n: int) {
	copies := make([dynamic]Lyric, context.temp_allocator)
	next := lyric_new_link(project)
	new_of := make(map[i32]i32, context.temp_allocator) // a group of lines is copied as a group
	for &l in project.lyrics {
		if !l.selected {continue}
		c := l
		if l.link != 0 {
			if l.link not_in new_of {new_of[l.link] = next; next += 1}
			c.link = new_of[l.link]
		}
		c.t0, c.t1 = l.t1, l.t1 + (l.t1 - l.t0)
		append(&copies, c)
		l.selected = false
	}
	append(&project.lyrics, ..copies[:])
	lyrics_sort(&project)
	return len(copies)
}

// Which lines the length tools work on: the selected ones, else the lines of the current layer.
lyric_in_scope :: proc(l: Lyric, any_sel: bool) -> bool {
	return any_sel ? l.selected : int(l.layer) == lyr_layer
}

// The step of the current pattern (what its hits are apart), else of the grid.
lyric_step :: proc() -> f64 {
	if pat := cur_pattern(); pat != nil {return 60 / f64(max(project.settings.bpm, 1)) / f64(max(pat.div, 1))}
	step, _ := grid_step(project.settings)
	return step
}

// Moves the start and the end of the lines in scope: a shorter line is a later start or an earlier end.
lyrics_resize :: proc(d_start, d_end: f64) {
	any_sel := lyrics_selected() > 0
	for &l in project.lyrics {
		if !lyric_in_scope(l, any_sel) {continue}
		l.t0 = clamp(l.t0 + d_start, 0, l.t1 - MIN_DURATION)
		l.t1 = max(l.t1 + d_end, l.t0 + MIN_DURATION)
	}
}

// Makes the lines in scope longer or shorter by a factor; each keeps its start.
lyrics_scale :: proc(f: f64) {
	any_sel := lyrics_selected() > 0
	for &l in project.lyrics {
		if lyric_in_scope(l, any_sel) {l.t1 = l.t0 + max((l.t1 - l.t0) * f, MIN_DURATION)}
	}
}

// Puts the lines in scope on the cuts (the hits of a pattern): the start on the nearest cut, the end on the next
// cut after it (if there is one). Returns how many lines moved.
lyrics_snap_to_cuts :: proc() -> (n: int) {
	if len(project.program) == 0 {return}
	any_sel := lyrics_selected() > 0
	reach := max(lyric_step(), 0.1) * 2
	for &l in project.lyrics {
		if !lyric_in_scope(l, any_sel) {continue}
		near, best := -1.0, max(f64)
		for c in project.program {
			if d := abs(c.time - l.t0); d < best {near, best = c.time, d}
		}
		if best > reach {continue}
		len_ := l.t1 - l.t0
		l.t0 = near
		l.t1 = l.t0 + len_
		for c in project.program {
			if c.time > l.t0 + MIN_DURATION - 1e-6 && c.time >= l.t0 + len_ - reach { // the first cut near where the line ended
				l.t1 = c.time
				break
			}
		}
		n += 1
	}
	return
}

// Moves the selected lines (all of them, or line only) by dt seconds; none goes before 0.
lyrics_shift :: proc(dt: f64, only := -1) {
	any_sel := lyrics_selected() > 0
	lowest := max(f64)
	moves :: proc(l: Lyric, i, only: int, any_sel: bool) -> bool {
		return only >= 0 ? i == only : (any_sel ? l.selected : int(l.layer) == lyr_layer)
	}
	for l, i in project.lyrics {
		if moves(l, i, only, any_sel) {lowest = min(lowest, l.t0)}
	}
	dt := max(dt, -lowest)
	for &l, i in project.lyrics {
		if moves(l, i, only, any_sel) {l.t0 += dt; l.t1 += dt}
	}
}

// The line shown at time t (the last one that covers it), or -1.
lyric_hit :: proc(p: Project, t: f64, layer: int) -> int {
	hit := -1
	for l, i in p.lyrics {
		if int(l.layer) == layer && t >= l.t0 && t < l.t1 {hit = i}
	}
	return hit
}

lyric_add :: proc(p: ^Project, t: f64) {
	l := Lyric{t0 = t, t1 = t + LYRIC_DEFAULT, layer = i32(lyr_layer)}
	set_fixed(l.text[:], "new line")
	append(&p.lyrics, l)
	lyrics_sort(p)
	for x, i in p.lyrics {
		if x.t0 == t {sel_lyric = i}
	}
	show_lyrics = true
}

// Splits line i at time t into two lines (the text stays in both: edit them after). Lines linked to it are cut at the
// same time; the new right halves are linked to each other.
lyric_split :: proc(p: ^Project, i: int, t: f64) {
	if i < 0 || i >= len(p.lyrics) {return}
	g := p.lyrics[i].link
	members := make([dynamic]int, context.temp_allocator)
	for l, k in p.lyrics {
		if k == i || (g != 0 && l.link == g) {append(&members, k)}
	}
	right := g != 0 ? lyric_new_link(p^) : 0
	cut := 0
	#reverse for k in members { // from the back: the indices before stay right
		l := p.lyrics[k]
		if t <= l.t0 + MIN_DURATION || t >= l.t1 - MIN_DURATION {continue}
		p.lyrics[k].t1 = t
		r := l
		r.t0, r.link = t, right
		inject_at(&p.lyrics, k + 1, r)
		cut += 1
	}
	if cut > 0 {lyrics_sort(p)}
}

// Joins line i and the next one (the text of both, on two lines).
lyric_merge :: proc(p: ^Project, i: int) {
	if i < 0 || i >= len(p.lyrics) {return}
	j := i + 1
	for j < len(p.lyrics) && p.lyrics[j].layer != p.lyrics[i].layer {j += 1}
	if j >= len(p.lyrics) {return}
	a, b := p.lyrics[i], p.lyrics[j]
	set_fixed(p.lyrics[i].text[:], fmt.tprintf("%s\n%s", text_of(a), text_of(b)))
	p.lyrics[i].t1 = max(a.t1, b.t1)
	ordered_remove(&p.lyrics, j)
}

// Times the next line at the playhead; the line before it ends there. Press at the
// start of each line while the song plays.
lyric_tap :: proc() {
	lyrics_park(lyr_layer)
	defer lyrics_unpark(lyr_layer)
	if len(project.lyrics) == 0 {
		set_status("no lyrics: open the Lyrics panel and paste the text")
		return
	}
	if lyr_tap >= len(project.lyrics) {
		set_status("all lines are timed (set 'next line' to start again)")
		return
	}
	i := lyr_tap
	if i > 0 {project.lyrics[i - 1].t1 = max(playhead, project.lyrics[i - 1].t0 + MIN_DURATION)}
	project.lyrics[i].t0 = playhead
	project.lyrics[i].t1 = playhead + LYRIC_DEFAULT
	sel_lyric = i
	lyr_tap += 1
	set_status("line %d timed", i + 1)
}

// Spreads all lines over a range (the selected program range, else the song), by text length.
lyrics_spread :: proc(p: ^Project) {
	lyrics_park(lyr_layer)
	defer lyrics_unpark(lyr_layer)
	if len(p.lyrics) == 0 {return}
	t0, t1, ok := program_range()
	if !ok {t0, t1 = 0, project_length(p^)}
	if t1 - t0 < MIN_DURATION * f64(len(p.lyrics)) {return}
	total := 0
	for l in p.lyrics {total += max(len(text_of(l)), 4)}
	at := t0
	for &l in p.lyrics {
		share := (t1 - t0) * f64(max(len(text_of(l)), 4)) / f64(total)
		l.t0, l.t1 = at, at + share
		at += share
	}
}

// ---------------------------------------------------------------- preview

// What is shown at a time (Lyric_Mode):
//   line   a whole line while it lasts
//   word   one word at a time: the line's time is shared by its words by their length
//   verse  the lines of a verse build up and stay until the verse ends (lines closer
//          than VERSE_GAP seconds belong to one verse)
Lyric_Mode :: enum i32 {
	Line,
	Word,
	Verse,
}

LYRIC_MODE_NAMES := [Lyric_Mode]cstring {
	.Line  = "sentence (a line)",
	.Word  = "one word",
	.Verse = "verse (lines build up)",
}

VERSE_GAP :: 1.2
LYRIC_LINE_H :: 1.2 // line height in font sizes

// One piece of text on screen for a time. Plain data (no strings): `text` is the byte range
// from..to of line `lyric`, so the list is cheap to keep. Several lines of a verse share a
// block: `rows` is the block's height in rows and `row` where this text starts in it, so the
// block is stacked upwards from the bottom.
Show :: struct {
	t0, t1:     f64,
	lyric:      int,
	from, to:   int,
	row, rows:  int, // rows: the block's height in lines AFTER the lines were wrapped to the frame
	scale:      f32, // what the text shrank to to fit the frame (1 = not at all)
}

rows_of :: proc(s: string) -> int {
	return strings.count(s, "\n") + 1
}

// The text of a show (a copy that stays valid). Draw loops read the bytes in place instead.
show_text :: proc(p: Project, s: Show) -> string {
	l := p.lyrics[s.lyric]
	return strings.clone(get_fixed(l.text[:])[s.from:s.to], context.temp_allocator)
}

// Fills `out` with everything shown for the lyrics in the style's Lyric_Mode (see above). Text is wrapped to the
// style's frame and shrunk to fit it (a block = what is on screen together: a line, a word, a verse).
build_shows :: proc(p: Project, out: ^[dynamic]Show, st: Lyric_Style, layer: int) {
	clear(out)
	idx := make([dynamic]int, context.temp_allocator) // the lines of this layer
	for l, i in p.lyrics {
		if int(l.layer) == layer {append(&idx, i)}
	}
	s := p.settings
	fm := font_metrics(lyric_style_font(st))
	_, _, fw, _ := lyric_frame_rect(s, st)
	base := lyric_base_size(s, st)
	rows_at :: proc(fm: ^Font_Metrics, text: string, size, fw: f32) -> int {return len(wrap_text(fm, text, size, fw))}
	switch st.mode {
	case .Line:
		for i in idx {
			l := p.lyrics[i]
			text := get_fixed(l.text[:])
			scale := lyric_fit_scale(s, st, fm, {text})
			append(out, Show{t0 = l.t0, t1 = l.t1, lyric = i, from = 0, to = len(text), rows = rows_at(fm, text, base * scale, fw), scale = scale})
		}
	case .Word:
		for i in idx {
			l := p.lyrics[i]
			text := get_fixed(l.text[:])
			total := 0
			for k := 0; k < len(text); { // the letters of all words
				for k < len(text) && text[k] <= ' ' {k += 1}
				a := k
				for k < len(text) && text[k] > ' ' {k += 1}
				if k > a {total += max(utf8.rune_count_in_string(text[a:k]), 1)}
			}
			at := l.t0
			for k := 0; k < len(text); {
				for k < len(text) && text[k] <= ' ' {k += 1}
				a := k
				for k < len(text) && text[k] > ' ' {k += 1}
				if k == a {break}
				share := (l.t1 - l.t0) * f64(max(utf8.rune_count_in_string(text[a:k]), 1)) / f64(max(total, 1))
				scale := lyric_fit_scale(s, st, fm, {text[a:k]})
				append(out, Show{t0 = at, t1 = at + share, lyric = i, from = a, to = k, rows = rows_at(fm, text[a:k], base * scale, fw), scale = scale})
				at += share
			}
		}
	case .Verse:
		for n := 0; n < len(idx); {
			m, end := n + 1, p.lyrics[idx[n]].t1
			for m < len(idx) && p.lyrics[idx[m]].t0 - end <= VERSE_GAP {
				end = max(end, p.lyrics[idx[m]].t1)
				m += 1
			}
			texts := make([dynamic]string, context.temp_allocator)
			for k in n ..< m {append(&texts, text_of(p.lyrics[idx[k]]))}
			scale := lyric_fit_scale(s, st, fm, texts[:])
			rows := 0
			for t in texts {rows += rows_at(fm, t, base * scale, fw)}
			row := 0
			for k in n ..< m {
				append(out, Show{t0 = p.lyrics[idx[k]].t0, t1 = end, lyric = idx[k], from = 0, to = len(texts[k - n]), row = row, rows = rows, scale = scale})
				row += rows_at(fm, texts[k - n], base * scale, fw)
			}
			n = m
		}
	}
}

// The shows, rebuilt only when the lyrics or the mode changed (a hash of them, a few
// hundred bytes to read, tells): the preview asks every frame.
Shows_Cache :: struct {
	key:   u64,
	valid: bool,
	shows: [dynamic]Show,
}

shows_caches: [dynamic]Shows_Cache // one per lyric layer

lyrics_key :: proc(p: Project) -> u64 {
	h := u64(14695981039346656037) // FNV-1a
	mix :: proc(h: u64, v: u64) -> u64 {return (h ~ v) * 1099511628211}
	h = mix(h, u64(len(p.lyrics)))
	for l in p.lyrics {
		l := l
		h = mix(h, transmute(u64)l.t0)
		h = mix(h, transmute(u64)l.t1)
		h = mix(h, u64(l.layer))
		for b in l.text {
			if b == 0 {break}
			h = mix(h, u64(b))
		}
	}
	s := p.settings // the picture the frame is in
	for v in ([?]i32{s.width, s.height, s.mask_w, s.mask_h}) {h = mix(h, u64(v))}
	return h
}

// The shows of a layer, rebuilt only when the lines, the picture or the layer's text style changed.
cached_shows :: proc(layer: int) -> []Show {
	for len(shows_caches) <= layer {append(&shows_caches, Shows_Cache{})}
	st := lyric_style_of(project, layer)
	key := lyrics_key(project) ~ (lyric_style_key(st) * 1099511628211)
	c := &shows_caches[layer]
	if !c.valid || key != c.key {
		build_shows(project, &c.shows, st, layer)
		c.key, c.valid = key, true
	}
	return c.shows[:]
}
rgb_hex :: proc(c: [3]f32) -> int {
	return int(c.r * 255 + 0.5) << 16 | int(c.g * 255 + 0.5) << 8 | int(c.b * 255 + 0.5)
}

hex_rgb :: proc(v: int) -> [3]f32 {
	return {f32((v >> 16) & 255) / 255, f32((v >> 8) & 255) / 255, f32(v & 255) / 255}
}

// ASS colors are &HAABBGGRR.
ass_color :: proc(c: [3]f32) -> string {
	return fmt.tprintf("&H00%02X%02X%02X", int(c.b * 255 + 0.5), int(c.g * 255 + 0.5), int(c.r * 255 + 0.5))
}

rgb_u32 :: proc(c: [3]f32) -> u32 {
	return 0xFF000000 | u32(c.b * 255 + 0.5) << 16 | u32(c.g * 255 + 0.5) << 8 | u32(c.r * 255 + 0.5)
}

preview_fonts: map[string]^im.Font // the font files shown in the preview, loaded into ImGui the first time they are used

// The ImGui font of a font file (loaded when first asked for; the built-in font if the file cannot be loaded).
preview_font :: proc(path: string) -> ^im.Font {
	if f, ok := preview_fonts[path]; ok {return f != nil ? f : im.GetFont()}
	f: ^im.Font
	if path != "" && os.exists(path) {
		f = im.FontAtlas_AddFontFromFileTTF(im.GetIO().Fonts, cstr(path), 0)
	}
	preview_fonts[strings.clone(path)] = f
	return f != nil ? f : im.GetFont()
}

// Draws the text at the playhead over the picture a..b, every layer, as the export will show it: in the font you
// picked, wrapped and centred with that font's letter widths.
draw_lyric_preview :: proc(dl: ^im.DrawList, a, b: im.Vec2) {
	s := project.settings
	if len(project.lyrics) == 0 {
		lyric_frame_overlay(dl, a, b)
		return
	}
	px := (b.x - a.x) / f32(max(s.width, 1)) // picture pixels -> screen pixels
	im.DrawList_PushClipRect(dl, a, b, true)
	for layer in 0 ..< lyric_layer_count(project) {
		st := lyric_style_of(project, layer)
		if !st.burn {continue}
		font_path := lyric_style_font(st)
		fm := font_metrics(font_path)
		font := preview_font(font_path)
		text_col, border_col := rgb_u32(st.color), rgb_u32(st.border)
		for show in cached_shows(layer) {
			if playhead < show.t0 || playhead >= show.t1 {continue}
			lay := lyric_layout(s, st, fm, show_text(project, show), show.scale, show.row, show.rows)
			ratio := fm.ph_ratio > 0 ? fm.ph_ratio : 1
			size := lay.size * px * ratio // ImGui's size for letters as big as the export's
			border := max(lay.size * px * st.border_w / 100, 0)
			for line, k in lay.lines {
				text := cstr(line)
				pos := im.Vec2{a.x + lay.ax * px - text_width_plain(fm, line, lay.size) * px * lay.af, a.y + (lay.top + f32(k) * lay.lh) * px}
				if border > 0.4 {
					for d in ([?]im.Vec2{{-1, 0}, {1, 0}, {0, -1}, {0, 1}, {-0.7, -0.7}, {0.7, 0.7}, {-0.7, 0.7}, {0.7, -0.7}}) {
						im.DrawList_AddTextImFontPtr(dl, font, size, {pos.x + d.x * border, pos.y + d.y * border}, border_col, text)
					}
				}
				im.DrawList_AddTextImFontPtr(dl, font, size, pos, text_col, text)
			}
		}
	}
	im.DrawList_PopClipRect(dl)
	lyric_frame_overlay(dl, a, b)
}

// The fonts in C:\Windows\Fonts (.ttf), found once.
font_names: [dynamic]string

load_fonts :: proc() {
	if len(font_names) > 0 {return}
	_, out, _, err := os.process_exec({command = {"cmd", "/c", "dir", "/b", "C:\\Windows\\Fonts\\*.ttf"}}, context.temp_allocator)
	if err == nil {
		for line in strings.split_lines(string(out), context.temp_allocator) {
			if name := strings.trim_space(line); name != "" {append(&font_names, strings.clone(name))}
		}
	}
	if len(font_names) == 0 {append(&font_names, strings.clone("arial.ttf"))}
}

// ---------------------------------------------------------------- panel

panel_lyrics :: proc() {
	if !show_lyrics {
		return
	}
	defer im.End()
	im.SetNextWindowSize({520, 460}, .FirstUseEver)
	if !im.Begin("Lyrics", &show_lyrics) {
		return
	}
	lyr_layer = clamp(lyr_layer, 0, lyric_layer_count(project) - 1)
	im.SetNextItemWidth(160)
	if im.BeginCombo("layer", cstr(lyric_layer_name(project, lyr_layer))) {
		for layer in 0 ..< lyric_layer_count(project) {
			if im.Selectable(cstr(fmt.tprintf("%s###layer%d", lyric_layer_name(project, layer), layer)), layer == lyr_layer) {lyr_layer = layer; sel_lyric = -1; lyr_tap = 0}
		}
		im.EndCombo()
	}
	tip("The lyrics of which layer the text below and the buttons work on. A layer has its own lines (another language, say) and its own style. Add layers under 'style'.")
	if im.Button("Open...") {do_action(.Lyrics_Open)}
	im.SameLine()
	if im.Button("Export...") {do_action(.Lyrics_Export)}
	im.SameLine()
	if im.Button("Add line") {lyric_add(&project, playhead)}
	im.SameLine()
	if im.Button("Clear") {
		#reverse for l, i in project.lyrics {
			if int(l.layer) == lyr_layer {ordered_remove(&project.lyrics, i)}
		}
		sel_lyric, lyr_tap = -1, 0
	}
	tip("Remove all lines of this layer")

	// time the lines
	if im.Button("Tap") {lyric_tap()}
	tip(fmt.tprintf("Times the next line at the playhead (%s). Press it at the start of each line while the song plays.", bindings[.Lyric_Tap][0].text))
	im.SameLine()
	im.SetNextItemWidth(80)
	next := i32(lyr_tap + 1)
	if im.InputInt("next line", &next, 1) {lyr_tap = clamp(int(next) - 1, 0, lyric_layer_lines(project, lyr_layer))}
	im.SameLine()
	if im.Button("Spread") {lyrics_spread(&project)}
	im.SameLine()
	if im.Button("Auto-align") {do_action(.Lyrics_Align)}
	im.SameLine()
	if im.Button("Transcribe") {do_action(.Lyrics_Transcribe)}
	tip("Write the lyrics from what whisper hears in the song (this replaces the lines there). Then fix the words you need in the text box below: the times stay.")
	tip("Time the lines from the song (needs whisper.cpp, see the setup below). With no lyrics it writes them from what it hears. The window freezes while it listens.")
	tip("Spread all lines over the selected program range, else over the song. Longer text gets more time.")

	// the text: a line each, "[start-end] text"
	want := lyrics_to_text(project, lyr_layer)
	if !lyr_active && want != string(cstring(&lyr_buf[0])) {
		for &c in lyr_buf {c = 0}
		copy(lyr_buf[:len(lyr_buf) - 1], want)
	}
	h := max(im.GetContentRegionAvail().y - 120, 80)
	if im.InputTextMultiline("##lyrics_text", cstring(&lyr_buf[0]), len(lyr_buf), {-1, h}, {.AllowTabInput}) {
		lyrics_park(lyr_layer)
		lyrics_from_text(&project, string(cstring(&lyr_buf[0])))
		lyrics_unpark(lyr_layer)
		if partner := int(lyric_style_of(project, lyr_layer).link_to) - 1; partner >= 0 {lyrics_pair_layers(lyr_layer, partner)}
	}
	lyr_active = im.IsItemActive()
	im.TextDisabled("One line each: [mm:ss.cc-mm:ss.cc] text. Start only is fine. No time: it follows the line before.")

	// move lines: the selected ones, else all of them (to fix a whole offset)
	im.TextDisabled(lyrics_selected() > 0 ? "move the selected lines" : "move all lines")
	im.SameLine()
	for step in ([?]f64{-1, -0.1, 0.1, 1}) {
		if im.Button(cstr(fmt.tprintf("%+.1f s##shift%.1f", step, step))) {lyrics_shift(step)}
		im.SameLine()
	}
	im.NewLine()

	// shorten / enlarge: by a step of the pattern (else of the grid), or by a factor
	im.TextDisabled(lyrics_selected() > 0 ? "length of the selected lines" : "length of all lines")
	step := lyric_step()
	im.TextDisabled("end")
	im.SameLine()
	if im.Button("- step##end") {lyrics_resize(0, -step)}
	im.SameLine()
	if im.Button("+ step##end") {lyrics_resize(0, step)}
	im.SameLine()
	im.TextDisabled("start")
	im.SameLine()
	if im.Button("- step##start") {lyrics_resize(-step, 0)}
	im.SameLine()
	if im.Button("+ step##start") {lyrics_resize(step, 0)}
	im.SameLine()
	if im.Button("x 0.9") {lyrics_scale(0.9)}
	im.SameLine()
	if im.Button("x 1.1") {lyrics_scale(1.1)}
	im.SameLine()
	if im.Button("Snap to cuts") {set_status("%d lines put on the cuts", lyrics_snap_to_cuts())}
	tip("The start goes to the nearest cut (the hits of the pattern, once applied), the end to the next cut. A step is the current pattern's step, else the grid's.")

	// the selected line: text with real newlines, and its times
	if sel_lyric >= 0 && sel_lyric < len(project.lyrics) {
		l := &project.lyrics[sel_lyric]
		im.SeparatorText(cstr(fmt.tprintf("Line %d", sel_lyric + 1)))
		im.InputTextMultiline("##line_text", cstring(&l.text[0]), len(l.text), {-1, 46})
		im.SetNextItemWidth(110)
		im.InputDouble("start", &l.t0, 0.1, 1, "%.2f")
		im.SameLine()
		im.SetNextItemWidth(110)
		im.InputDouble("end", &l.t1, 0.1, 1, "%.2f")
		l.t0 = max(l.t0, 0)
		l.t1 = max(l.t1, l.t0 + MIN_DURATION)
	}

	whisper_load()
	if im.CollapsingHeader("auto-align setup") {
		im.InputText("model (.bin)", cstring(&whisper_model[0]), len(whisper_model))
		if im.IsItemDeactivatedAfterEdit() {whisper_save()}
		im.SameLine()
		if im.Button("...") {
			if path, ok := pick_file(false, "whisper model", "ggml model|*.bin|All files|*.*"); ok {set_fixed(whisper_model[:], path); whisper_save()}
		}
		im.SetNextItemWidth(80)
		im.InputText("language", cstring(&whisper_lang[0]), len(whisper_lang))
		if im.IsItemDeactivatedAfterEdit() {whisper_save()}
		im.SetNextItemWidth(300)
		if im.BeginCombo("engine", ENGINE_NAMES[align_engine]) {
			for e in Align_Engine {
				if im.Selectable(ENGINE_NAMES[e], e == align_engine) {align_engine = e; whisper_save()}
			}
			im.EndCombo()
		}
		tip("What times your lyrics.\nwhisper aligns your words: whisper (stable-ts) places YOUR text on the audio. Copes with music best.\nvoice model: a wav2vec2 model lines the letters up. Exact on clean voices, blind to some rap/sung vocals.\nwhisper listens: whisper-cli writes what it hears and your words are matched to it. Without lyrics it is always this one.")
		if align_engine == .Whisper_Align {
			im.InputText("align cmd", cstring(&align_cmd[0]), len(align_cmd))
			if im.IsItemDeactivatedAfterEdit() {whisper_save()}
			tip("Runs scripts/whisper_align.py with uv (Python, torch and stable-ts are fetched on the first run). {wav} = the audio, {text} = your lyrics, {out} = the result file, {lang} = the language above. Add a model name at the end (small, medium, large-v3).")
		} else if align_engine == .Ctc {
			im.InputText("aligner", cstring(&forced_cmd[0]), len(forced_cmd))
			if im.IsItemDeactivatedAfterEdit() {whisper_save()}
			tip("Runs scripts/ctc_emissions.py with uv (Python, torch and transformers are fetched on the first run, about 2 GB with the model). {wav} = the audio, {out} = the file name to write.")
		}		if im.Checkbox("vocals only", &vocal_on) {whisper_save()}
		tip("Listen to the voice, not the music. Without a separator command, a simple filter keeps the range of the voice. With one, a real separator is used.")
		im.InputText("separator", cstring(&vocal_cmd[0]), len(vocal_cmd))
		if im.IsItemDeactivatedAfterEdit() {whisper_save()}
		tip("Optional. A vocal separator command. {in} = the song (wav), {out} = the vocals file to write, {dir} = a folder it may write to (a file with 'vocals' in its name is used). Example: demucs --two-stems=vocals -o {dir} {in}")
		im.TextDisabled("whisper-cli.exe in PATH (or in tools\\), and a model like ggml-base.bin. 'auto' needs a multilingual model.")
	}
	if im.CollapsingHeader("style", {.DefaultOpen}) {lyric_style_ui()}
}

// ---------------------------------------------------------------- style panel: layers, text, frame

lyric_layer_name :: proc(p: Project, layer: int) -> string {
	st := lyric_style_of(p, layer)
	if name := get_fixed(st.name[:]); name != "" {return strings.clone(name, context.temp_allocator)} // st is a copy: the name must not point into it
	return fmt.tprintf("layer %d", layer + 1)
}

// Puts a new layer's frame just above another layer's, so two languages are on screen at once and not printed over
// each other (when there is no room above, it goes on top of the other one: move it).
lyric_stack_above :: proc(st: ^Lyric_Style, below: Lyric_Style) {
	st.frame[0], st.frame[2] = below.frame[0], below.frame[2]
	st.frame[3] = min(below.frame[3], 20)
	st.frame[1] = max(below.frame[1] - st.frame[3] - 1, 0)
	st.safe, st.valign, st.halign = below.safe, .Bottom, below.halign
}

lyr_layer := 0 // the layer the style controls and the frame in the preview edit
lyr_show_frame := true // draw the frame and the safe zone over the preview while the Lyrics panel is open

// A new, empty layer on top (white text, its frame above the layer below it); it becomes the current layer.
lyric_layer_new :: proc() {
	st := default_lyric_style()
	set_fixed(st.name[:], fmt.tprintf("layer %d", lyric_layer_count(project) + 1))
	st.color = {1, 1, 1} // another colour than the first, to tell them apart
	lyric_stack_above(&st, lyric_style_of(project, lyric_layer_count(project) - 1))
	append(&project.lyric_layers, st)
	lyr_layer = lyric_layer_count(project) - 1
	sel_lyric, lyr_tap = -1, 0
}

// A new layer on top with the style and the lines of `layer` (the same times: change the text for another
// language); its frame sits above the layer it copies. It becomes the current layer.
lyric_layer_duplicate :: proc(layer: int) {
	copy_ := lyric_style_of(project, layer)
	set_fixed(copy_.name[:], fmt.tprintf("%s copy", lyric_layer_name(project, layer)))
	lyric_stack_above(&copy_, lyric_style_of(project, layer))
	append(&project.lyric_layers, copy_)
	to := lyric_layer_count(project) - 1
	for i in 0 ..< len(project.lyrics) { // its lines too, linked to the originals: cut or move one, the other follows
		if int(project.lyrics[i].layer) == layer {
			if project.lyrics[i].link == 0 {project.lyrics[i].link = lyric_new_link(project)}
			l := project.lyrics[i]
			l.layer, l.selected = i32(to), false
			append(&project.lyrics, l)
		}
	}
	lyrics_sort(&project)
	if lyric_style_of(project, layer).link_to == 0 { // linked with the original: cut or move one, the other follows
		lyric_style_ref(&project, layer).link_to = i32(to + 1)
		lyric_style_ref(&project, to).link_to = i32(layer + 1)
	} else {
		lyric_style_ref(&project, to).link_to = 0 // the original already has a partner
	}
	lyr_layer = to
	sel_lyric, lyr_tap = -1, 0
	set_status("layer duplicated: now edit the text of '%s'", get_fixed(project.lyric_layers[to - 1].name[:]))
}

// Removes a layer and its lines (the first layer stays); the layers above move down.
lyric_layer_delete :: proc(layer: int) {
	if layer <= 0 || layer >= lyric_layer_count(project) {return}
	lyric_layer_unlink(layer)
	#reverse for l, i in project.lyrics {
		if int(l.layer) == layer {ordered_remove(&project.lyrics, i)} else if int(l.layer) > layer {project.lyrics[i].layer -= 1}
	}
	ordered_remove(&project.lyric_layers, layer - 1)
	for k in 0 ..< lyric_layer_count(project) { // partners above the deleted layer have a new number
		if o := lyric_style_ref(&project, k); int(o.link_to) - 1 > layer {o.link_to -= 1}
	}
	lyr_layer = min(lyr_layer, lyric_layer_count(project) - 1)
	if lyr_layer >= layer {lyr_layer -= 1}
	sel_lyric = -1
}

lyric_style_ui :: proc() {
	count := lyric_layer_count(project)
	lyr_layer = clamp(lyr_layer, 0, count - 1)

	// the layers: every one shows the same lines its own way, the last is on top
	im.TextDisabled("layers (each has its own lines and style; the last is on top)")
	for layer in 0 ..< count {
		st := lyric_style_ref(&project, layer)
		im.PushIDInt(i32(layer))
		im.Checkbox("##show", &st.burn)
		if im.IsItemHovered() {im.SetTooltip("show this layer (preview and export)")}
		im.SameLine()
		if im.Selectable(cstr(fmt.tprintf("%s  (%d lines)###sel%d", lyric_layer_name(project, layer), lyric_layer_lines(project, layer), layer)), layer == lyr_layer) {lyr_layer = layer; sel_lyric = -1; lyr_tap = 0}
		im.PopID()
	}
	if im.Button("New layer") {lyric_layer_new()}
	tip("An empty layer: type its lines in the text box (a translation, say). Copy timing from the first layer lines them up.")
	im.SameLine()
	if im.Button("Duplicate layer") {lyric_layer_duplicate(lyr_layer)}
	tip("A new layer with this layer's style and a copy of its lines, on top. Change the text for another language, or the colour, border and offset for a shadow.")
	if lyr_layer > 0 {
		im.SameLine()
		if im.Button("Delete layer") {lyric_layer_delete(lyr_layer)}
		im.SameLine()
		if im.Button("Copy timing from layer 1") {
			base := make([dynamic]int, context.temp_allocator)
			mine := make([dynamic]int, context.temp_allocator)
			for l, i in project.lyrics {
				if l.layer == 0 {append(&base, i)} else if int(l.layer) == lyr_layer {append(&mine, i)}
			}
			for k in 0 ..< min(len(base), len(mine)) {
				project.lyrics[mine[k]].t0, project.lyrics[mine[k]].t1 = project.lyrics[base[k]].t0, project.lyrics[base[k]].t1
			}
			lyrics_sort(&project)
			set_status("timed %d lines like layer 1", min(len(base), len(mine)))
		}
		tip("Line 1 of this layer gets the times of line 1 of the first layer, line 2 of line 2, and so on: type the translation, then press this.")
	}
	if count > 1 { // link two layers: a Spanish one and its German one are cut, moved and trimmed together
		partner := int(lyric_style_of(project, lyr_layer).link_to) - 1
		im.SetNextItemWidth(200)
		if im.BeginCombo("linked with", cstr(partner >= 0 ? lyric_layer_name(project, partner) : "nothing")) {
			if im.Selectable("nothing", partner < 0) {lyric_layer_unlink(lyr_layer)}
			for other in 0 ..< count {
				if other == lyr_layer {continue}
				if im.Selectable(cstr(fmt.tprintf("%s###lk%d", lyric_layer_name(project, other), other)), other == partner) {
					set_status("layers linked: %d lines paired", lyric_layers_link(lyr_layer, other))
				}
			}
			im.EndCombo()
		}
		tip("Link this layer with another: their lines are paired in order (line 1 with line 1, ...) and from then on selecting, moving, trimming, cutting with the razor, deleting and duplicating a line does the same to its partner. The paired lines have a coloured bar in the timeline. Typing in either text box pairs them again.")
	}
	im.Separator()

	st := lyric_style_ref(&project, lyr_layer)
	im.SetNextItemWidth(160)
	im.InputText("name", cstring(&st.name[0]), len(st.name))
	im.SetNextItemWidth(220)
	if im.BeginCombo("show", LYRIC_MODE_NAMES[st.mode]) {
		for m in Lyric_Mode {
			if im.Selectable(LYRIC_MODE_NAMES[m], m == st.mode) {st.mode = m}
		}
		im.EndCombo()
	}
	load_fonts()
	im.SetNextItemWidth(220)
	if im.BeginCombo("font", cstr(get_fixed(st.font[:]))) {
		for name in font_names {
			if im.Selectable(cstr(name), name == get_fixed(st.font[:])) {set_fixed(st.font[:], name)}
		}
		im.EndCombo()
	}
	tip("The preview and the export use this font, and the text is wrapped with its letter widths.")
	im.SliderFloat("size", &st.size, 2, 15, "%.1f %% of the height")
	im.ColorEdit3("text color", &st.color, {.NoInputs})
	im.SameLine()
	im.ColorEdit3("border color", &st.border, {.NoInputs})
	im.SameLine()
	im.SetNextItemWidth(120)
	im.SliderFloat("border", &st.border_w, 0, 20, "%.0f %%")
	if im.Button("Yellow, black border") {
		st.color, st.border, st.border_w = {1, 1, 0}, {0, 0, 0}, 5
		set_fixed(st.font[:], "arial.ttf")
	}
	tip("The look of home video subtitles")

	// the frame: where the text has to fit
	im.SeparatorText("Frame")
	im.SetNextItemWidth(260)
	if im.BeginCombo("safe zone", SAFE_NAMES[st.safe]) {
		for z in Safe_Zone {
			if im.Selectable(SAFE_NAMES[z], z == st.safe) {st.safe = z}
		}
		im.EndCombo()
	}
	tip("The frame is placed inside this part of the picture (or of the mask area), clear of what the apps cover with their own buttons and captions.")
	im.SetNextItemWidth(260)
	im.SliderFloat4("x y w h", &st.frame, 0, 100, "%.0f")
	tip("The frame's left, top, width and height in % of the safe area. Or drag it in the preview.")
	st.frame[2], st.frame[3] = max(st.frame[2], 5), max(st.frame[3], 5)
	im.SetNextItemWidth(100)
	if im.BeginCombo("vertical", VALIGN_NAMES[st.valign]) {
		for v in Lyric_VAlign {
			if im.Selectable(VALIGN_NAMES[v], v == st.valign) {st.valign = v}
		}
		im.EndCombo()
	}
	tip("Where the text sits in the frame, up and down (when it does not fill it).")
	im.SameLine()
	im.SetNextItemWidth(100)
	if im.BeginCombo("horizontal", HALIGN_NAMES[st.halign]) {
		for h in Lyric_HAlign {
			if im.Selectable(HALIGN_NAMES[h], h == st.halign) {st.halign = h}
		}
		im.EndCombo()
	}
	tip("Where each line sits in the frame: against the left edge, centred, or against the right edge.")
	im.Checkbox("shrink to fit", &st.fit)
	tip("Long lines always break into more lines to fit the frame's width. With this on, text that is still too tall for the frame gets smaller until it fits (lines end up in different sizes). Off: every line is the same size and what is too tall goes out of the frame.")
	im.SetNextItemWidth(260)
	im.SliderFloat2("offset", &st.offset, -10, 10, "%.1f %%")
	tip("Moves the whole text by this much (% of the height): the second layer as a shadow.")
	if im.Button("Same size for all lines and layers") {
		for layer in 0 ..< lyric_layer_count(project) {
			o := lyric_style_ref(&project, layer)
			o.size, o.fit = st.size, false
		}
		set_status("size %.1f %% on every layer, nothing shrinks: what does not fit goes out of the frame", st.size)
	}
	tip("This layer's size on every layer, and no shrinking: every line is the same size, and a line that is too long or too tall goes out of the frame.")
	if im.Button("Safe zone to all layers") {
		for layer in 0 ..< lyric_layer_count(project) {lyric_style_ref(&project, layer).safe = st.safe}
	}
	tip("This layer's safe zone on every layer.")
	im.SameLine()
	if im.Button("Font and border to all layers") {
		for layer in 0 ..< lyric_layer_count(project) {
			o := lyric_style_ref(&project, layer)
			o.font, o.border, o.border_w = st.font, st.border, st.border_w
		}
	}
	tip("This layer's font, border colour and border width on every layer (the text colour and the frame stay).")
	if im.Button("Center frame horizontally") {lyric_center_frame(project.settings, st, true)}
	tip("Puts the frame in the middle of the picture, left to right (the safe zone leaves more room on one side, so this is not the middle of the safe area).")
	im.SameLine()
	if im.Button("Center frame vertically") {lyric_center_frame(project.settings, st, false)}
	tip("Puts the frame in the middle of the picture, top to bottom.")
	im.Checkbox("show the frame in the preview", &lyr_show_frame)
	im.SameLine()
	if im.Button("Reset frame") {
		def := default_lyric_style()
		st.frame, st.offset, st.valign, st.halign, st.safe = def.frame, {}, def.valign, def.halign, def.safe
	}
}

// ---------------------------------------------------------------- the frame in the preview

Frame_Drag :: enum u8 {
	None,
	Move,
	Edge, // an edge or corner: `edges`
}

frame_drag: Frame_Drag
frame_edges: u8 // 1 left, 2 right, 4 top, 8 bottom
frame_drag_from: im.Vec2 // the mouse when the drag began
frame_drag_start: [4]f32 // the frame when the drag began

// The safe zone and the frame of the layer being edited, drawn over the picture a..b while the Lyrics panel is
// open; drag inside the frame to move it, drag an edge or corner to resize it.
lyric_frame_overlay :: proc(dl: ^im.DrawList, a, b: im.Vec2) {
	if !show_lyrics || !lyr_show_frame {return}
	s := project.settings
	st := lyric_style_ref(&project, clamp(lyr_layer, 0, lyric_layer_count(project) - 1))
	px := (b.x - a.x) / f32(max(s.width, 1))
	sx, sy, sw, sh := lyric_safe_rect(s, st^)
	fx, fy, fw, fh := lyric_frame_rect(s, st^)
	to_screen :: proc(a: im.Vec2, px, x, y: f32) -> im.Vec2 {return {a.x + x * px, a.y + y * px}}
	im.DrawList_PushClipRect(dl, a, b, true)
	defer im.DrawList_PopClipRect(dl)
	if st.safe != .None { // what the safe zone keeps clear, dimmed
		ax, ay, aw, ah := lyric_area(s)
		shade := u32(0x50000000)
		im.DrawList_AddRectFilled(dl, to_screen(a, px, ax, ay), to_screen(a, px, ax + aw, sy), shade)
		im.DrawList_AddRectFilled(dl, to_screen(a, px, ax, sy + sh), to_screen(a, px, ax + aw, ay + ah), shade)
		im.DrawList_AddRectFilled(dl, to_screen(a, px, ax, sy), to_screen(a, px, sx, sy + sh), shade)
		im.DrawList_AddRectFilled(dl, to_screen(a, px, sx + sw, sy), to_screen(a, px, ax + aw, sy + sh), shade)
		im.DrawList_AddRect(dl, to_screen(a, px, sx, sy), to_screen(a, px, sx + sw, sy + sh), 0x80FFFFFF, thickness = 1)
	}
	p0, p1 := to_screen(a, px, fx, fy), to_screen(a, px, fx + fw, fy + fh)
	im.DrawList_AddRect(dl, p0, p1, 0xFF00D8FF, thickness = 2)
	for c in ([4]im.Vec2{{p0.x, p0.y}, {p1.x, p0.y}, {p0.x, p1.y}, {p1.x, p1.y}}) {
		im.DrawList_AddRectFilled(dl, {c.x - 4, c.y - 4}, {c.x + 4, c.y + 4}, 0xFF00D8FF)
	}

	// dragging
	mouse := im.GetMousePos()
	if frame_drag == .None {
		if im.IsWindowHovered() && im.IsMouseClicked(.Left) && mouse.x >= a.x && mouse.x < b.x && mouse.y >= a.y && mouse.y < b.y {
			m := f32(8)
			inside_x, inside_y := mouse.x >= p0.x - m && mouse.x <= p1.x + m, mouse.y >= p0.y - m && mouse.y <= p1.y + m
			edges: u8
			if inside_y && abs(mouse.x - p0.x) < m {edges |= 1}
			if inside_y && abs(mouse.x - p1.x) < m {edges |= 2}
			if inside_x && abs(mouse.y - p0.y) < m {edges |= 4}
			if inside_x && abs(mouse.y - p1.y) < m {edges |= 8}
			switch {
			case edges != 0:
				frame_drag, frame_edges = .Edge, edges
			case mouse.x > p0.x && mouse.x < p1.x && mouse.y > p0.y && mouse.y < p1.y:
				frame_drag = .Move
			}
			frame_drag_from, frame_drag_start = mouse, st.frame
		}
	} else if !im.IsMouseDown(.Left) {
		frame_drag = .None
	} else {
		dx := (mouse.x - frame_drag_from.x) / px / max(sw, 1) * 100 // % of the safe area
		dy := (mouse.y - frame_drag_from.y) / px / max(sh, 1) * 100
		f := frame_drag_start
		switch frame_drag {
		case .None:
		case .Move:
			f[0] += dx
			f[1] += dy
		case .Edge:
			if frame_edges & 1 != 0 {f[0] += dx; f[2] -= dx}
			if frame_edges & 2 != 0 {f[2] += dx}
			if frame_edges & 4 != 0 {f[1] += dy; f[3] -= dy}
			if frame_edges & 8 != 0 {f[3] += dy}
		}
		if f[2] < 5 { // the opposite edge stays where it is
			if frame_edges & 1 != 0 {f[0] -= 5 - f[2]}
			f[2] = 5
		}
		if f[3] < 5 {
			if frame_edges & 4 != 0 {f[1] -= 5 - f[3]}
			f[3] = 5
		}
		st.frame = f
	}
}
