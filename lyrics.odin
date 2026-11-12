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
	selected: bool, // part of the selection (not part of undo)
}

show_lyrics: bool
sel_lyric := -1 // selected line (timeline row or panel)
lyr_tap: int // the line the next Tap times
lyr_buf: [32768]u8 // the text of the Lyrics panel
lyr_active: bool // the text box had focus last frame: do not rewrite it

// The text of a line (a copy: safe to keep).
text_of :: proc(l: Lyric) -> string {
	l := l
	return strings.clone(get_fixed(l.text[:]), context.temp_allocator)
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

lyrics_to_text :: proc(p: Project) -> string {
	b: strings.Builder
	strings.builder_init(&b, context.temp_allocator)
	for l in p.lyrics {
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
		size := int(f64(s.height) * f64(s.lyric_size) / 100)
		fmt.sbprintf(
			&b,
			"[Script Info]\nScriptType: v4.00+\nPlayResX: %d\nPlayResY: %d\n\n[V4+ Styles]\n" +
			"Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding\n" +
			"Style: Default,Arial,%d,%s,%s,%s,&H80000000,0,0,0,0,100,100,0,0,1,%d,0,2,40,40,%d,1\n\n" +
			"[Events]\nFormat: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\n",
			s.width, s.height, size, ass_color(s.lyric_color), ass_color(s.lyric_color), ass_color(s.lyric_border), max(int(f64(size) * f64(s.lyric_border_w) / 100), 0), int(s.height) * 8 / 100,
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
}

// Moves the selected lines (all of them, or line only) by dt seconds; none goes before 0.
lyrics_shift :: proc(dt: f64, only := -1) {
	any_sel := lyrics_selected() > 0
	lowest := max(f64)
	for l, i in project.lyrics {
		if only >= 0 ? i == only : (!any_sel || l.selected) {lowest = min(lowest, l.t0)}
	}
	dt := max(dt, -lowest)
	for &l, i in project.lyrics {
		if only >= 0 ? i == only : (!any_sel || l.selected) {l.t0 += dt; l.t1 += dt}
	}
}

// The line shown at time t (the last one that covers it), or -1.
lyric_hit :: proc(p: Project, t: f64) -> int {
	hit := -1
	for l, i in p.lyrics {
		if t >= l.t0 && t < l.t1 {hit = i}
	}
	return hit
}

lyric_add :: proc(p: ^Project, t: f64) {
	l := Lyric{t0 = t, t1 = t + LYRIC_DEFAULT}
	set_fixed(l.text[:], "new line")
	append(&p.lyrics, l)
	lyrics_sort(p)
	for x, i in p.lyrics {
		if x.t0 == t {sel_lyric = i}
	}
	show_lyrics = true
}

// Splits line i at time t into two lines (the text stays in both: edit them after).
lyric_split :: proc(p: ^Project, i: int, t: f64) {
	if i < 0 || i >= len(p.lyrics) {return}
	l := p.lyrics[i]
	if t <= l.t0 + MIN_DURATION || t >= l.t1 - MIN_DURATION {return}
	p.lyrics[i].t1 = t
	r := l
	r.t0 = t
	inject_at(&p.lyrics, i + 1, r)
}

// Joins line i and the next one (the text of both, on two lines).
lyric_merge :: proc(p: ^Project, i: int) {
	if i < 0 || i + 1 >= len(p.lyrics) {return}
	a, b := p.lyrics[i], p.lyrics[i + 1]
	set_fixed(p.lyrics[i].text[:], fmt.tprintf("%s\n%s", text_of(a), text_of(b)))
	p.lyrics[i].t1 = max(a.t1, b.t1)
	ordered_remove(&p.lyrics, i + 1)
}

// Times the next line at the playhead; the line before it ends there. Press at the
// start of each line while the song plays.
lyric_tap :: proc() {
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
LYRIC_BOTTOM :: 0.08 // distance of the text from the bottom edge, in picture heights
LYRIC_LINE_H :: 1.2 // line height in font sizes

// One piece of text on screen for a time. Plain data (no strings): `text` is the byte range
// from..to of line `lyric`, so the list is cheap to keep. Several lines of a verse share a
// block: `rows` is the block's height in rows and `row` where this text starts in it, so the
// block is stacked upwards from the bottom.
Show :: struct {
	t0, t1:     f64,
	lyric:      int,
	from, to:   int,
	row, rows:  int,
}

rows_of :: proc(s: string) -> int {
	return strings.count(s, "\n") + 1
}

// The text of a show (a copy that stays valid). Draw loops read the bytes in place instead.
show_text :: proc(p: Project, s: Show) -> string {
	l := p.lyrics[s.lyric]
	return strings.clone(get_fixed(l.text[:])[s.from:s.to], context.temp_allocator)
}

// Fills `out` with everything shown for the lyrics and the Lyric_Mode (see above).
build_shows :: proc(p: Project, out: ^[dynamic]Show) {
	clear(out)
	switch p.settings.lyric_mode {
	case .Line:
		for l, i in p.lyrics {
			l := l
			text := get_fixed(l.text[:])
			append(out, Show{t0 = l.t0, t1 = l.t1, lyric = i, from = 0, to = len(text), rows = rows_of(text)})
		}
	case .Word:
		for l, i in p.lyrics {
			l := l
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
				append(out, Show{t0 = at, t1 = at + share, lyric = i, from = a, to = k, rows = 1})
				at += share
			}
		}
	case .Verse:
		row_count :: proc(p: Project, i: int) -> int {
			l := p.lyrics[i]
			return rows_of(get_fixed(l.text[:]))
		}
		for i := 0; i < len(p.lyrics); {
			j, end := i + 1, p.lyrics[i].t1
			for j < len(p.lyrics) && p.lyrics[j].t0 - end <= VERSE_GAP {
				end = max(end, p.lyrics[j].t1)
				j += 1
			}
			rows := 0
			for k in i ..< j {rows += row_count(p, k)}
			row := 0
			for k in i ..< j {
				l := p.lyrics[k]
				append(out, Show{t0 = l.t0, t1 = end, lyric = k, from = 0, to = len(get_fixed(l.text[:])), row = row, rows = rows})
				row += row_count(p, k)
			}
			i = j
		}
	}
}

// The shows, rebuilt only when the lyrics or the mode changed (a hash of them, a few
// hundred bytes to read, tells): the preview asks every frame.
shows_cache: struct {
	key:   u64,
	valid: bool,
	shows: [dynamic]Show,
}

lyrics_key :: proc(p: Project) -> u64 {
	h := u64(14695981039346656037) // FNV-1a
	mix :: proc(h: u64, v: u64) -> u64 {return (h ~ v) * 1099511628211}
	h = mix(h, u64(p.settings.lyric_mode))
	h = mix(h, u64(len(p.lyrics)))
	for l in p.lyrics {
		l := l
		h = mix(h, transmute(u64)l.t0)
		h = mix(h, transmute(u64)l.t1)
		for b in l.text {
			if b == 0 {break}
			h = mix(h, u64(b))
		}
	}
	return h
}

cached_shows :: proc() -> []Show {
	key := lyrics_key(project)
	if !shows_cache.valid || key != shows_cache.key {
		build_shows(project, &shows_cache.shows)
		shows_cache.key, shows_cache.valid = key, true
	}
	return shows_cache.shows[:]
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

// Draws the text at the playhead over the picture a..b, as the export will show it
// (the preview has one plain font; the export uses the font you picked).
draw_lyric_preview :: proc(dl: ^im.DrawList, a, b: im.Vec2) {
	s := project.settings
	if len(project.lyrics) == 0 || !s.lyric_burn {return}
	h := b.y - a.y
	size := h * s.lyric_size / 100
	lh := size * LYRIC_LINE_H
	scale := size / im.GetFontSize()
	font := im.GetFont()
	border := max(size * s.lyric_border_w / 100, 0)
	text_col, border_col := rgb_u32(s.lyric_color), rgb_u32(s.lyric_border)
	im.DrawList_PushClipRect(dl, a, b, true)
	for show in cached_shows() {
		if playhead < show.t0 || playhead >= show.t1 {continue}
		top := b.y - h * LYRIC_BOTTOM - f32(show.rows - show.row) * lh
		for line, k in strings.split(show_text(project, show), "\n", context.temp_allocator) {
			text := cstr(line)
			pos := im.Vec2{(a.x + b.x - im.CalcTextSize(text).x * scale) / 2, top + f32(k) * lh}
			if border > 0.4 {
				for d in ([?]im.Vec2{{-1, 0}, {1, 0}, {0, -1}, {0, 1}, {-0.7, -0.7}, {0.7, 0.7}, {-0.7, 0.7}, {0.7, -0.7}}) {
					im.DrawList_AddTextImFontPtr(dl, font, size, {pos.x + d.x * border, pos.y + d.y * border}, border_col, text)
				}
			}
			im.DrawList_AddTextImFontPtr(dl, font, size, pos, text_col, text)
		}
	}
	im.DrawList_PopClipRect(dl)
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

// The font file to use in the export: your pick, else a common one.
lyric_font_path :: proc(s: Settings) -> string {
	s := s
	path := fmt.tprintf("C:/Windows/Fonts/%s", get_fixed(s.lyric_font[:]))
	return os.exists(path) ? path : find_font()
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
	if im.Button("Open...") {do_action(.Lyrics_Open)}
	im.SameLine()
	if im.Button("Export...") {do_action(.Lyrics_Export)}
	im.SameLine()
	if im.Button("Add line") {lyric_add(&project, playhead)}
	im.SameLine()
	if im.Button("Clear") {clear(&project.lyrics); sel_lyric = -1; lyr_tap = 0}
	tip("Remove all lines")

	// time the lines
	if im.Button("Tap") {lyric_tap()}
	tip(fmt.tprintf("Times the next line at the playhead (%s). Press it at the start of each line while the song plays.", bindings[.Lyric_Tap][0].text))
	im.SameLine()
	im.SetNextItemWidth(80)
	next := i32(lyr_tap + 1)
	if im.InputInt("next line", &next, 1) {lyr_tap = clamp(int(next) - 1, 0, len(project.lyrics))}
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
	want := lyrics_to_text(project)
	if !lyr_active && want != string(cstring(&lyr_buf[0])) {
		for &c in lyr_buf {c = 0}
		copy(lyr_buf[:len(lyr_buf) - 1], want)
	}
	h := max(im.GetContentRegionAvail().y - 120, 80)
	if im.InputTextMultiline("##lyrics_text", cstring(&lyr_buf[0]), len(lyr_buf), {-1, h}, {.AllowTabInput}) {
		lyrics_from_text(&project, string(cstring(&lyr_buf[0])))
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
	if im.CollapsingHeader("style", {.DefaultOpen}) {
		s := &project.settings
		im.Checkbox("show and export", &s.lyric_burn)
		im.SetNextItemWidth(220)
		if im.BeginCombo("show", LYRIC_MODE_NAMES[s.lyric_mode]) {
			for m in Lyric_Mode {
				if im.Selectable(LYRIC_MODE_NAMES[m], m == s.lyric_mode) {s.lyric_mode = m}
			}
			im.EndCombo()
		}
		load_fonts()
		im.SetNextItemWidth(220)
		if im.BeginCombo("font", cstr(get_fixed(s.lyric_font[:]))) {
			for name in font_names {
				if im.Selectable(cstr(name), name == get_fixed(s.lyric_font[:])) {set_fixed(s.lyric_font[:], name)}
			}
			im.EndCombo()
		}
		tip("The export uses this font. The preview shows a plain font.")
		im.SliderFloat("size", &s.lyric_size, 2, 15, "%.1f %% of the height")
		im.ColorEdit3("text color", &s.lyric_color, {.NoInputs})
		im.SameLine()
		im.ColorEdit3("border color", &s.lyric_border, {.NoInputs})
		im.SameLine()
		im.SetNextItemWidth(120)
		im.SliderFloat("border", &s.lyric_border_w, 0, 20, "%.0f %%")
}}
