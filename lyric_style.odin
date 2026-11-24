package main

import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:unicode/utf8"

import stbtt "vendor:stb/truetype"

// How the lyrics look and where they go. A style is one layer of lyrics: the lines are the same for every
// layer (they are timed once), each layer shows them its own way (font, size, colours, frame, mode, offset),
// so a second layer is a shadow, a glow or a plain outline under the first.
//
// The text goes into a FRAME: a box inside the safe zone of the picture (or of the mask area, for a vertical
// part in a horizontal project). Long lines are broken into more lines to fit the frame's width (measured
// with the font file the export uses), and when the block is still too tall the text shrinks until it fits.

Lyric_VAlign :: enum u8 {
	Bottom,
	Middle,
	Top,
}

VALIGN_NAMES := [Lyric_VAlign]cstring{.Bottom = "bottom", .Middle = "middle", .Top = "top"}

Lyric_HAlign :: enum u8 {
	Center,
	Left,
	Right,
}

HALIGN_NAMES := [Lyric_HAlign]cstring{.Center = "center", .Left = "left", .Right = "right"}

// Parts of the picture the apps put their own buttons and captions over.
Safe_Zone :: enum u8 {
	None,
	Vertical, // 9:16 (Shorts, Reels, TikTok): clear of the top bar, the bottom caption and the side buttons
	Square,   // a margin all around
	Wide,     // 16:9 title safe (90 %)
}

SAFE_NAMES := [Safe_Zone]cstring{.None = "none", .Vertical = "vertical 9:16 (Shorts / Reels / TikTok)", .Square = "margin 5 %", .Wide = "wide: title safe 90 %"}

// The share of the area (left, top, right, bottom) a zone keeps free.
safe_insets :: proc(z: Safe_Zone) -> [4]f32 {
	switch z {
	case .None:     return {0, 0, 0, 0}
	case .Vertical: return {0.10, 0.12, 0.10, 0.22} // the same on both sides, so the frame is centred in the picture
	case .Square:   return {0.05, 0.05, 0.05, 0.05}
	case .Wide:     return {0.05, 0.05, 0.05, 0.05}
	}
	return {}
}

Lyric_Style :: struct {
	name:     [24]u8,
	font:     [64]u8, // font file name in C:\Windows\Fonts
	size:     f32, // font height in % of the area height
	border_w: f32, // border width in % of the font size
	color:    [3]f32,
	border:   [3]f32,
	frame:    [4]f32, // x, y, width, height in % of the safe area: the text has to fit in it
	offset:   [2]f32, // shift of the whole text in % of the area height (a shadow)
	mode:     Lyric_Mode, // what is shown at a time
	valign:   Lyric_VAlign, // where the block sits in the frame, up and down
	halign:   Lyric_HAlign, // where each line sits in the frame, left and right
	safe:     Safe_Zone,
	link_to:  i32, // 0 = alone; else the layer (number + 1) this one is linked with: their lines are paired and edited together
	burn:     bool, // shown in the preview and burned into the export
	fit:      bool, // shrink the text when it does not fit the frame's height
}

// Yellow text with a black border, in a plain font: the look of home video subtitles.
default_lyric_style :: proc() -> Lyric_Style {
	st := Lyric_Style {
		size     = 6,
		border_w = 5,
		color    = {1, 1, 0},
		border   = {0, 0, 0},
		frame    = {5, 58, 90, 34}, // the lower part: text sits 8 % above the bottom edge
		mode     = .Line,
		valign   = .Bottom,
		halign   = .Center,
		safe     = .Vertical, // clear of what the apps cover on a vertical video
		burn     = true,
		fit      = false, // every line the same size: what does not fit goes out of the frame
	}
	set_fixed(st.font[:], "arial.ttf")
	set_fixed(st.name[:], "lyrics")
	return st
}

// Layer 0 is the settings' style, then the extra layers.
lyric_layer_count :: proc(p: Project) -> int {return 1 + len(p.lyric_layers)}

lyric_style_of :: proc(p: Project, layer: int) -> Lyric_Style {
	if layer <= 0 || layer > len(p.lyric_layers) {return p.settings.lyric}
	return p.lyric_layers[layer - 1]
}

lyric_style_ref :: proc(p: ^Project, layer: int) -> ^Lyric_Style {
	if layer <= 0 || layer > len(p.lyric_layers) {return &p.settings.lyric}
	return &p.lyric_layers[layer - 1]
}

// A change of anything that moves or reshapes text (the shows are rebuilt when this changes).
lyric_style_key :: proc(st: Lyric_Style) -> u64 {
	st := st
	h := u64(14695981039346656037)
	mix :: proc(h: u64, v: u64) -> u64 {return (h ~ v) * 1099511628211}
	for b in st.font {
		if b == 0 {break}
		h = mix(h, u64(b))
	}
	h = mix(h, u64(transmute(u32)st.size))
	for v in st.frame {h = mix(h, u64(transmute(u32)v))}
	h = mix(h, u64(st.mode))
	h = mix(h, u64(st.safe))
	h = mix(h, st.fit ? 1 : 0)
	return h
}

// ---------------------------------------------------------------- the frame

// The area the text lives in, in picture pixels: the mask area (the whole picture without a mask).
lyric_area :: proc(s: Settings) -> (x, y, w, h: f32) {
	ax, ay, aw, ah := mask_rect(s)
	return f32(ax), f32(ay), f32(aw), f32(ah)
}

// The safe part of the area.
lyric_safe_rect :: proc(s: Settings, st: Lyric_Style) -> (x, y, w, h: f32) {
	ax, ay, aw, ah := lyric_area(s)
	if st.safe == .Vertical && aw > ah * 9 / 16 { // a horizontal picture: the safe zone is that of the 9:16 strip in its middle
		w := ah * 9 / 16
		ax += (aw - w) / 2
		aw = w
	}
	ins := safe_insets(st.safe)
	return ax + aw * ins[0], ay + ah * ins[1], aw * (1 - ins[0] - ins[2]), ah * (1 - ins[1] - ins[3])
}

// Puts the frame in the middle of the picture (of the mask area), left to right or top to bottom: the safe
// zone is not the same width on both sides, so this is not the middle of the safe area.
lyric_center_frame :: proc(s: Settings, st: ^Lyric_Style, horizontal: bool) {
	ax, ay, aw, ah := lyric_area(s)
	sx, sy, sw, sh := lyric_safe_rect(s, st^)
	if horizontal {
		st.frame[0] = (ax + aw / 2 - sx) / max(sw, 1) * 100 - st.frame[2] / 2
	} else {
		st.frame[1] = (ay + ah / 2 - sy) / max(sh, 1) * 100 - st.frame[3] / 2
	}
}

// The frame in picture pixels (with the layer's offset).
lyric_frame_rect :: proc(s: Settings, st: Lyric_Style) -> (x, y, w, h: f32) {
	sx, sy, sw, sh := lyric_safe_rect(s, st)
	_, _, _, ah := lyric_area(s)
	return sx + sw * st.frame[0] / 100 + ah * st.offset[0] / 100, sy + sh * st.frame[1] / 100 + ah * st.offset[1] / 100, sw * st.frame[2] / 100, sh * st.frame[3] / 100
}

// ---------------------------------------------------------------- measuring

Font_Metrics :: struct {
	data:     []u8,
	info:     stbtt.fontinfo,
	ok:       bool,
	ph_ratio: f32, // ImGui sizes a font so that ascent + descent is the size; ffmpeg so that the em is. The ImGui size for the same letters is size * this
}

font_cache: map[string]^Font_Metrics
font_cache_mu: sync.Mutex // the export runs on a job thread and measures text too

font_metrics :: proc(path: string) -> ^Font_Metrics {
	sync.mutex_lock(&font_cache_mu)
	defer sync.mutex_unlock(&font_cache_mu)
	if fm, ok := font_cache[path]; ok {return fm}
	fm := new(Font_Metrics)
	if data, err := os.read_entire_file(path, context.allocator); err == nil {
		fm.data = data
		fm.ok = bool(stbtt.InitFont(&fm.info, raw_data(fm.data), stbtt.GetFontOffsetForIndex(raw_data(fm.data), 0)))
		if fm.ok {fm.ph_ratio = stbtt.ScaleForMappingEmToPixels(&fm.info, 1) / stbtt.ScaleForPixelHeight(&fm.info, 1)}
	}
	font_cache[strings.clone(path)] = fm
	return fm
}

// Width in pixels of a line of text at a font size in pixels (the font's advances and kerning).
text_width :: proc(fm: ^Font_Metrics, text: string, size: f32) -> f32 {
	if !fm.ok {return f32(utf8.rune_count_in_string(text)) * size * 0.55}
	scale := stbtt.ScaleForMappingEmToPixels(&fm.info, size)
	w, prev := f32(0), rune(0)
	for r in text {
		adv, lsb: c.int
		stbtt.GetCodepointHMetrics(&fm.info, r, &adv, &lsb)
		w += f32(adv) * scale
		if prev != 0 {w += f32(stbtt.GetCodepointKernAdvance(&fm.info, prev, r)) * scale}
		prev = r
	}
	return w
}

// Width in pixels of a line as ImGui draws it in the preview (the advances, no kerning).
text_width_plain :: proc(fm: ^Font_Metrics, text: string, size: f32) -> f32 {
	if !fm.ok {return f32(utf8.rune_count_in_string(text)) * size * 0.55}
	scale := stbtt.ScaleForMappingEmToPixels(&fm.info, size)
	w := f32(0)
	for r in text {
		adv, lsb: c.int
		stbtt.GetCodepointHMetrics(&fm.info, r, &adv, &lsb)
		w += f32(adv) * scale
	}
	return w
}

// Breaks text into lines no wider than max_w: the lines it already has stay, long ones break at spaces (a
// word wider than the frame breaks inside the word). A little room is kept: the export lays text out with
// its own renderer and this measure can be a hair off.
wrap_text :: proc(fm: ^Font_Metrics, text: string, size, max_w: f32) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	limit := max_w * 0.97
	for raw in strings.split(text, "\n", context.temp_allocator) {
		raw := clean_line(raw)
		if raw == "" || text_width(fm, raw, size) <= limit {
			append(&out, raw)
			continue
		}
		line := ""
		for word in strings.fields(raw, context.temp_allocator) {
			trial := line == "" ? word : strings.concatenate({line, " ", word}, context.temp_allocator)
			if text_width(fm, trial, size) <= limit {
				line = trial
				continue
			}
			if line != "" {append(&out, line)}
			line = word
			for text_width(fm, line, size) > limit && utf8.rune_count_in_string(line) > 1 { // a word wider than the frame
				n := utf8.rune_count_in_string(line)
				cut := n - 1
				for cut > 1 && text_width(fm, string_runes(line, cut), size) > limit {cut -= 1}
				head := string_runes(line, cut)
				append(&out, head)
				line = line[len(head):]
			}
		}
		if line != "" {append(&out, line)}
	}
	return out[:]
}

// A line of text as it is drawn: tabs and carriage returns are spaces, and no space at either end (a space
// in front would move a centred line sideways, one at the back would move a right-aligned one).
clean_line :: proc(raw: string) -> string {
	line := raw
	if strings.contains_any(line, "\t\r\u00a0") {
		line, _ = strings.replace_all(line, "\t", " ", context.temp_allocator)
		line, _ = strings.replace_all(line, "\r", "", context.temp_allocator)
		line, _ = strings.replace_all(line, "\u00a0", " ", context.temp_allocator)
	}
	return strings.trim_space(line)
}

// The first n runes of a string.
string_runes :: proc(s: string, n: int) -> string {
	i := 0
	for _ in 0 ..< n {
		if i >= len(s) {break}
		_, w := utf8.decode_rune_in_string(s[i:])
		i += w
	}
	return s[:i]
}

// The font file of a style (the export's font: your pick, else a common one).
lyric_style_font :: proc(st: Lyric_Style) -> string {
	st := st
	path := fmt.tprintf("C:/Windows/Fonts/%s", get_fixed(st.font[:]))
	return os.exists(path) ? path : find_font()
}

// The font size in pixels of a style, before it is shrunk to fit.
lyric_base_size :: proc(s: Settings, st: Lyric_Style) -> f32 {
	_, _, _, ah := lyric_area(s)
	return max(ah * st.size / 100, 6)
}

LYRIC_MIN_FIT :: 0.35 // the text never shrinks below this share of its size

// How much the texts of a block have to shrink to fit the frame (1 = not at all). texts: every line of
// text that is on screen together (one line, or a verse).
lyric_fit_scale :: proc(s: Settings, st: Lyric_Style, fm: ^Font_Metrics, texts: []string) -> f32 {
	if !st.fit {return 1}
	_, _, fw, fh := lyric_frame_rect(s, st)
	base := lyric_base_size(s, st)
	scale := f32(1)
	for _ in 0 ..< 40 {
		rows := 0
		for t in texts {rows += len(wrap_text(fm, t, base * scale, fw))}
		if f32(rows) * base * scale * LYRIC_LINE_H <= fh || scale <= LYRIC_MIN_FIT {break}
		scale *= 0.94
	}
	return max(scale, LYRIC_MIN_FIT)
}

// Where a show's lines go, in picture pixels.
Show_Layout :: struct {
	lines: []string,
	size:  f32, // font size
	lh:    f32, // line height
	ax:    f32, // where the lines are anchored: the frame's left edge, middle or right edge (halign)
	af:    f32, // how much of its own width a line sits left of the anchor: 0 for left, 0.5 centred, 1 right
	top:   f32, // the first line of this show
}

lyric_layout :: proc(s: Settings, st: Lyric_Style, fm: ^Font_Metrics, text: string, scale: f32, row, rows: int) -> (l: Show_Layout) {
	fx, fy, fw, fh := lyric_frame_rect(s, st)
	l.size = lyric_base_size(s, st) * scale
	l.lh = l.size * LYRIC_LINE_H
	l.lines = wrap_text(fm, text, l.size, fw)
	switch st.halign {
	case .Left:   l.ax, l.af = fx, 0
	case .Center: l.ax, l.af = fx + fw / 2, 0.5
	case .Right:  l.ax, l.af = fx + fw, 1
	}
	block := f32(rows) * l.lh
	block_top: f32
	switch st.valign {
	case .Bottom: block_top = fy + fh - block
	case .Middle: block_top = fy + (fh - block) / 2
	case .Top:    block_top = fy
	}
	l.top = block_top + f32(row) * l.lh
	return
}
