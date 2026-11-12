"""Align your lyrics to the audio with whisper (stable-ts).

usage: whisper_align.py audio.wav lyrics.txt out.json [language] [model]

lyrics.txt holds the text, one lyric line each. out.json gets every word of it with its time:
  {"words": [{"word": " hola", "start": 1.2, "end": 1.6}, ...]}
language is a whisper code (es, en, ...) or "auto" (found from the audio). model is a whisper
model name: tiny, base, small (default), medium, large-v3. A bigger model is slower and better.

Whisper (not a small alignment model) decides where the words are, so it copes with music and
with fast sung or rapped words. stable-ts (https://github.com/jianfch/stable-ts) is the usual
tool for putting known lyrics on a recording. The first run downloads the model.
"""

import json
import sys

import stable_whisper


def main():
    if len(sys.argv) < 4:
        sys.exit(__doc__)
    audio_path, text_path, out_path = sys.argv[1], sys.argv[2], sys.argv[3]
    lang = sys.argv[4] if len(sys.argv) > 4 else "auto"
    model_name = sys.argv[5] if len(sys.argv) > 5 else "small"

    model = stable_whisper.load_model(model_name)
    with open(text_path, encoding="utf-8") as f:
        text = f.read()

    language = None if lang in ("", "auto") else lang
    if language is None:  # ask whisper what language it hears (from the middle of the song)
        import whisper

        audio = whisper.load_audio(audio_path)
        middle = audio[len(audio) // 3 : len(audio) // 3 + 30 * 16000]
        mel = whisper.log_mel_spectrogram(whisper.pad_or_trim(middle), model.dims.n_mels).to(model.device)
        _, probs = model.detect_language(mel)
        language = max(probs, key=probs.get)
        print("language:", language, file=sys.stderr, flush=True)

    result = model.align(audio_path, text, language=language, original_split=True)
    if result is None:
        sys.exit("stable-ts could not align this text with this audio (is the language right?)")
    words = [
        {"word": w.word, "start": float(w.start), "end": float(w.end)}
        for segment in result.segments
        for w in segment.words
    ]
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump({"words": words}, f, ensure_ascii=False)
    print(f"aligned {len(words)} words", file=sys.stderr, flush=True)


if __name__ == "__main__":
    main()
