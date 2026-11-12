package main

import "core:encoding/json"
import "core:os"
import "core:strings"
import "core:unicode"
import "core:unicode/utf8"

// Forced alignment: the words YOU wrote are placed where the voice says them. No speech
// recognition, so nothing is misheard, and silences stay empty (a CTC alignment lets the
// blank symbol take every frame where nothing is sung).
//   1. scripts/ctc_emissions.py runs a voice model (wav2vec2 / MMS) over the audio and writes
//      what it hears in every 20 ms frame: a probability for each letter
//   2. here: the letters of your words are lined up with those frames by the CTC Viterbi
//      path (the best monotone way to say exactly these letters, with blanks in between)
//   3. a word starts at the frame of its first letter and ends at the frame of its last

ALIGN_PRIOR :: f32(2) // see ctc_viterbi

Emissions :: struct {
	data:    []f32, // frames x tokens, log probabilities
	frames:  int,
	tokens:  int,
	frame_s: f64, // seconds per frame
	blank:   int,
	vocab:   map[string]int,
}

Emissions_Json :: struct {
	frames:        int,
	tokens:        int,
	frame_seconds: f64,
	blank:         int,
	vocab:         map[string]int,
}

// Reads out_base.bin / out_base.json written by ctc_emissions.py.
load_emissions :: proc(base: string) -> (em: Emissions, err: string) {
	text, rerr := os.read_entire_file(strings.concatenate({base, ".json"}, context.temp_allocator), context.temp_allocator)
	if rerr != nil {
		return {}, "the aligner wrote no emissions file"
	}
	info: Emissions_Json
	if jerr := json.unmarshal(text, &info, allocator = context.temp_allocator); jerr != nil {
		return {}, "could not read the aligner's vocabulary"
	}
	raw, berr := os.read_entire_file(strings.concatenate({base, ".bin"}, context.temp_allocator), context.temp_allocator)
	if berr != nil || len(raw) != info.frames * info.tokens * 4 || info.frames <= 0 {
		return {}, "the aligner's emissions file is incomplete"
	}
	em.frames, em.tokens, em.frame_s, em.blank = info.frames, info.tokens, info.frame_seconds, info.blank
	em.data = make([]f32, info.frames * info.tokens, context.temp_allocator)
	copy(transmute([]byte)em.data, raw)
	em.vocab = make(map[string]int, context.temp_allocator)
	for k, v in info.vocab {
		em.vocab[strings.to_lower(k, context.temp_allocator)] = v
		if k == "<blank>" {em.blank = v}
	}
	return
}

LETTERS := "abcdefghijklmnopqrstuvwxyz"

// The ASCII letter (or apostrophe) a character is sung as, "" for what is not sung (signs,
// digits). The voice model has the letters a-z and ': accents are taken off.
roman_rune :: proc(r: rune) -> string {
	switch {
	case r >= 'a' && r <= 'z': return LETTERS[int(r - 'a'):int(r - 'a') + 1]
	case r >= 'A' && r <= 'Z': return LETTERS[int(r - 'A'):int(r - 'A') + 1]
	case r == '\'' || r == '’' || r == '`' || r == '´': return "'"
	}
	GROUPS :: [?]struct {
		letters: string,
		to:      string,
	} {
		{"áàâäãåāąæ", "a"}, {"ÁÀÂÄÃÅĀĄÆ", "a"}, {"éèêëēęė", "e"}, {"ÉÈÊËĒĘĖ", "e"}, {"íìîïīį", "i"}, {"ÍÌÎÏĪĮ", "i"},
		{"óòôöõøōœ", "o"}, {"ÓÒÔÖÕØŌŒ", "o"}, {"úùûüūů", "u"}, {"ÚÙÛÜŪŮ", "u"}, {"ñńň", "n"}, {"ÑŃŇ", "n"},
		{"çćč", "c"}, {"ÇĆČ", "c"}, {"śšș", "s"}, {"ŚŠȘ", "s"}, {"ß", "ss"}, {"ýÿ", "y"}, {"ÝŸ", "y"},
		{"źżž", "z"}, {"ŹŻŽ", "z"}, {"łĺľ", "l"}, {"ŁĹĽ", "l"}, {"ďđ", "d"}, {"ĎĐ", "d"}, {"řŕ", "r"}, {"ŘŔ", "r"}, {"ťț", "t"}, {"ŤȚ", "t"}, {"ğ", "g"}, {"Ğ", "g"},
	}
	for g in GROUPS {
		if strings.contains_rune(g.letters, r) {return g.to}
	}
	return ""
}

// The letters of one word, as token numbers of the voice model. A model with its own alphabet (a Spanish
// wav2vec2: letters with accents, ñ) is given the letter itself; a romanized model (the default: a-z and ')
// the ASCII letter. Letters the model does not know are left out. Returns how many.
word_tokens :: proc(word: string, vocab: map[string]int, out: ^[dynamic]int) -> (count: int) {
	for r in word {
		if id, ok := vocab[utf8_string(unicode.to_lower(r))]; ok {
			append(out, id)
			count += 1
			continue
		}
		s := roman_rune(r)
		for i in 0 ..< len(s) {
			if id, ok := vocab[s[i:i + 1]]; ok {
				append(out, id)
				count += 1
			}
		}
	}
	return
}

// A rune as a string (the voice model's vocabulary is keyed by one-letter strings).
utf8_string :: proc(r: rune) -> string {
	b, n := utf8.encode_rune(r)
	return strings.clone(string(b[:n]), context.temp_allocator)
}
// prior > 0 adds a small pull towards an even pace: every frame costs prior * d^2, where d is how far
// the position in the text (0..1) is from the position in the audio (0..1). Where the voice model hears
// the words that changes nothing (the evidence is thousands of times larger). Where it hears nothing (a loud
// beat, a bad vocal track) the words are spread over that audio instead of being raced through at one
// letter per frame, which is what a plain Viterbi does with text it cannot find.
//
// The CTC Viterbi path of `targets` through the emissions: for every target, the first and the
// last frame it holds. ok = false when the audio is too short for that many letters.
ctc_viterbi :: proc(em: []f32, frames, tokens, blank: int, targets: []int, prior := f32(0)) -> (first, last: []int, ok: bool) {
	L := len(targets)
	S := 2 * L + 1 // blank, label, blank, label, ... blank
	if L == 0 || frames < L {
		return
	}
	NEG :: f32(-1e30)
	label_at :: proc(targets: []int, blank, s: int) -> int {return s % 2 == 0 ? blank : targets[(s - 1) / 2]}

	back := make([]u8, frames * S, context.temp_allocator) // 0 stay, 1 from s-1, 2 from s-2
	prev := make([]f32, S, context.temp_allocator)
	cur := make([]f32, S, context.temp_allocator)
	for s in 0 ..< S {prev[s] = NEG}
	prev[0] = em[blank]
	if S > 1 {prev[1] = em[label_at(targets, blank, 1)]}
	for t in 1 ..< frames {
		row := em[t * tokens:(t + 1) * tokens]
		at := f32(t) / f32(frames)
		for s in 0 ..< S {
			best, how := prev[s], u8(0)
			if s >= 1 && prev[s - 1] > best {best, how = prev[s - 1], 1}
			if s >= 2 {
				lab := label_at(targets, blank, s)
				if lab != blank && lab != label_at(targets, blank, s - 2) && prev[s - 2] > best {best, how = prev[s - 2], 2}
			}
			d := at - f32(s) / f32(S - 1)
			cur[s] = best <= NEG / 2 ? NEG : best + row[label_at(targets, blank, s)] - prior * d * d
			back[t * S + s] = how
		}
		prev, cur = cur, prev
	}
	// the path must end on the last label or the blank after it
	s := S - 1
	if S >= 2 && prev[S - 2] > prev[S - 1] {s = S - 2}
	if prev[s] <= NEG / 2 {
		return
	}
	first = make([]int, L, context.temp_allocator)
	last = make([]int, L, context.temp_allocator)
	for i in 0 ..< L {first[i], last[i] = -1, -1}
	for t := frames - 1; t >= 0; t -= 1 {
		if s % 2 == 1 {
			k := (s - 1) / 2
			first[k] = t
			if last[k] < 0 {last[k] = t}
		}
		switch back[t * S + s] {
		case 1: s -= 1
		case 2: s -= 2
		}
		if t > 0 && s < 0 {return}
	}
	ok = true
	return
}

// Start and end time (seconds) of every word of `words`, or -1, -1 for a word without sung
// letters. Returns an error text when the alignment is impossible.
align_words :: proc(em: Emissions, words: []string) -> (starts, ends: []f64, err: string) {
	targets := make([dynamic]int, context.temp_allocator)
	w_first := make([]int, len(words), context.temp_allocator)
	w_last := make([]int, len(words), context.temp_allocator)
	delim, has_delim := em.vocab["|"] // models with their own alphabet put "|" between words
	for w, i in words {
		if has_delim && len(targets) > 0 {append(&targets, delim)}
		w_first[i] = len(targets)
		n := word_tokens(w, em.vocab, &targets)
		w_last[i] = n > 0 ? len(targets) - 1 : -1
		if n == 0 {w_first[i] = -1}
	}
	if len(targets) == 0 {
		return nil, nil, "none of the letters of your text is in the voice model's alphabet"
	}
	first, last, ok := ctc_viterbi(em.data, em.frames, em.tokens, em.blank, targets[:], ALIGN_PRIOR)
	if !ok {
		return nil, nil, "the text is too long for this audio (or the audio is silent): is it the right song and text?"
	}
	starts = make([]f64, len(words), context.temp_allocator)
	ends = make([]f64, len(words), context.temp_allocator)
	for i in 0 ..< len(words) {
		if w_first[i] < 0 {
			starts[i], ends[i] = -1, -1
			continue
		}
		starts[i] = f64(first[w_first[i]]) * em.frame_s
		ends[i] = f64(last[w_last[i]] + 1) * em.frame_s
	}
	return
}

