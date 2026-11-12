"""Stage-by-stage test of lyrics alignment, outside the editor. Run it, read what each stage prints.

usage: diagnose.py song.wav lyrics.txt [--stem vocals.wav] [--model large-v3-turbo] [--lang es] [--crisper]

  song.wav     the song (any audio file ffmpeg reads)
  lyrics.txt   your lyrics, one line each
  --stem       the separated vocals (the editor keeps them as lyrics_align_heard.wav)
  --model      a faster-whisper model: small, medium, large-v3, large-v3-turbo (default)
  --lang       language code (es, en, ...); default: whisper finds it
  --crisper    also run CrisperWhisper (a whisper made for exact word times)

Stages, for every input (the song, and the stem when given):
  1 AUDIO    how loud it is, 10 s at a time (is the voice there?)
  2 HEARD    the words whisper hears, with times, and how many per 10 s
  3 MATCH    your lyrics lined up with those words: the time of every line, and what did not match
The first line of each stage says what it is; a stage that finds nothing shows it plainly.
Files written: diag_<input>_words.json (what was heard), diag_<input>_lines.json (the line times).
"""

import difflib
import json
import os
import re
import subprocess
import sys
import unicodedata

import numpy as np

RATE = 16000


def load(path):
    cmd = ["ffmpeg", "-nostdin", "-v", "error", "-i", path, "-f", "s16le", "-ac", "1", "-ar", str(RATE), "-"]
    raw = subprocess.run(cmd, capture_output=True, check=True).stdout
    return np.frombuffer(raw, dtype=np.int16).astype(np.float32) / 32768.0


def key(word):
    s = unicodedata.normalize("NFKD", word.lower())
    return re.sub(r"[^a-z0-9]", "", "".join(c for c in s if not unicodedata.combining(c)))


def stage_audio(audio, name):
    print(f"\n=== 1 AUDIO ({name}): {len(audio) / RATE:.1f} s")
    line = []
    for a in range(0, len(audio), 10 * RATE):
        seg = audio[a : a + 10 * RATE]
        rms = 20 * np.log10(np.sqrt(np.mean(seg**2)) + 1e-9)
        line.append(f"{a // RATE:>3}s {rms:6.1f} dB")
    print("   ".join(line))


def per_ten(words, length, what):
    counts = [0] * (int(length // 10) + 1)
    for w in words:
        counts[min(int(w["start"] // 10), len(counts) - 1)] += 1
    print(f"   {what} per 10 s: " + " ".join(f"{i * 10}:{c}" for i, c in enumerate(counts)))


def heard_whisper(audio, model_name, lang):
    from faster_whisper import WhisperModel

    model = WhisperModel(model_name)  # cuda if it can, else cpu
    segments, info = model.transcribe(
        audio, language=lang, word_timestamps=True, beam_size=5, condition_on_previous_text=False
    )
    words = [{"word": w.word, "start": w.start, "end": w.end} for s in segments for w in (s.words or [])]
    return words, info.language


def heard_crisper(audio):
    import torch
    from transformers import pipeline

    pipe = pipeline(
        "automatic-speech-recognition",
        model="nyrahealth/CrisperWhisper",
        torch_dtype=torch.float32,
        device="cuda" if torch.cuda.is_available() else "cpu",
        chunk_length_s=30,
        return_timestamps="word",
    )
    out = pipe({"raw": audio, "sampling_rate": RATE})
    return [{"word": c["text"], "start": c["timestamp"][0], "end": c["timestamp"][1]} for c in out["chunks"] if c["timestamp"][0] is not None]


def stage_match(lines, words, length, name):
    mine = [(i, w) for i, line in enumerate(lines) for w in line.split() if key(w)]
    a = [key(w) for _, w in mine]
    b = [key(w["word"]) for w in words]
    sm = difflib.SequenceMatcher(None, a, b, autojunk=False)
    where = {}
    for tag, i1, i2, j1, j2 in sm.get_opcodes():
        if tag == "equal":
            for k in range(i2 - i1):
                where[i1 + k] = words[j1 + k]
    print(f"\n=== 3 MATCH ({name}): {len(where)} of {len(mine)} of your words found in what was heard")
    times = {}
    for idx, (li, _) in enumerate(mine):
        if idx in where:
            t = times.setdefault(li, [where[idx]["start"], where[idx]["end"]])
            t[0], t[1] = min(t[0], where[idx]["start"]), max(t[1], where[idx]["end"])
    result = []
    for i, line in enumerate(lines):
        if i in times:
            print(f"   line {i + 1:>3}  {times[i][0]:7.2f} - {times[i][1]:7.2f}  {line}")
            result.append({"line": i + 1, "start": times[i][0], "end": times[i][1], "text": line})
        else:
            print(f"   line {i + 1:>3}  (not found)                {line}")
    covered = [t[0] for t in times.values()]
    if covered:
        print(f"   lines found: {len(times)} of {len(lines)}; the last one starts at {max(covered):.1f} s of {length:.1f} s")
    return result


def main():
    args = sys.argv[1:]
    if len(args) < 2:
        sys.exit(__doc__)
    song, lyrics = args[0], args[1]

    def opt(name, default=None):
        return args[args.index(name) + 1] if name in args else default

    stem, model_name, lang, crisper = opt("--stem"), opt("--model", "large-v3-turbo"), opt("--lang"), "--crisper" in args
    with open(lyrics, encoding="utf-8") as f:
        lines = [l.strip() for l in f if l.strip()]
    inputs = [("song", song)] + ([("stem", stem)] if stem else [])
    for name, path in inputs:
        audio = load(path)
        stage_audio(audio, name)
        engines = [("whisper", lambda a=audio: heard_whisper(a, model_name, lang))]
        if crisper:
            engines.append(("crisper", lambda a=audio: (heard_crisper(a), "?")))
        for engine, run in engines:
            label = f"{name}+{engine}"
            print(f"\n=== 2 HEARD ({label}) ...", flush=True)
            words, found = run()
            print(f"   {len(words)} words heard (language {found})")
            per_ten(words, len(audio) / RATE, "words")
            print("   first words: " + " ".join(f"{w['word'].strip()}@{w['start']:.1f}" for w in words[:20]))
            base = f"diag_{os.path.splitext(os.path.basename(path))[0]}_{engine}"
            with open(base + "_words.json", "w", encoding="utf-8") as f:
                json.dump(words, f, ensure_ascii=False, indent=1)
            result = stage_match(lines, words, len(audio) / RATE, label)
            with open(base + "_lines.json", "w", encoding="utf-8") as f:
                json.dump(result, f, ensure_ascii=False, indent=1)


if __name__ == "__main__":
    main()
