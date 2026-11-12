"""Forced alignment, step 1: what the voice model hears, frame by frame.

usage: ctc_emissions.py audio.wav out_base [model]`n`n`nAny CTC model works. Spanish speech: jonatasgrosman/wav2vec2-large-xlsr-53-spanish (its own alphabet:`nletters with accents and ñ; the editor puts "|" between words for such a model).`n

Writes two files:
  out_base.bin   float32, frames x tokens: the log probability of every token in every frame
  out_base.json  frames, tokens, frame_seconds, blank, vocab (token -> number)

The editor does step 2 itself (it lines up YOUR words with these frames: a CTC forced
alignment), so no speech recognition is involved: the words you wrote are placed where the
voice says them, and silences stay empty.

The model is MahmoudAshraf/mms-300m-1130-forced-aligner (Wav2Vec2 / MMS, 1100+ languages).
Its license is CC-BY-NC 4.0 (fine for personal videos). The first run downloads it.
The audio is cut in 30 s windows with 2 s of context on both sides, as the
ctc-forced-aligner project does (https://github.com/MahmoudAshraf97/ctc-forced-aligner).
"""

import json
import subprocess
import sys

import numpy as np
import torch
from transformers import AutoModelForCTC, AutoTokenizer

DEFAULT_MODEL = "MahmoudAshraf/mms-300m-1130-forced-aligner"
RATE = 16000
WINDOW = 30 * RATE
CONTEXT = 2 * RATE


def load_audio(path):
    cmd = ["ffmpeg", "-nostdin", "-v", "error", "-i", path, "-f", "s16le", "-ac", "1", "-ar", str(RATE), "-"]
    raw = subprocess.run(cmd, capture_output=True, check=True).stdout
    return np.frombuffer(raw, dtype=np.int16).astype(np.float32) / 32768.0


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    audio_path, out_base = sys.argv[1], sys.argv[2]
    model_name = sys.argv[3] if len(sys.argv) > 3 else DEFAULT_MODEL
    device = "cuda" if torch.cuda.is_available() else "cpu"
    print("device:", device, file=sys.stderr, flush=True)

    tokenizer = AutoTokenizer.from_pretrained(model_name, word_delimiter_token=None)  # as ctc-forced-aligner loads it
    model = AutoModelForCTC.from_pretrained(model_name).to(device).eval()
    ratio = int(model.config.inputs_to_logits_ratio)  # samples per frame: 320 (20 ms)
    audio = load_audio(audio_path)
    n = len(audio)
    # wav2vec2 models are trained on audio with zero mean and unit variance; their config says so
    try:
        from transformers import AutoFeatureExtractor

        if getattr(AutoFeatureExtractor.from_pretrained(model_name), "do_normalize", False):
            audio = ((audio - audio.mean()) / np.sqrt(audio.var() + 1e-7)).astype(np.float32)
            print("audio normalised", file=sys.stderr, flush=True)
    except Exception as e:  # the model has no feature extractor config: the audio stays as it is
        print("no normalisation:", e, file=sys.stderr, flush=True)

    if n < WINDOW:
        pieces = [audio]
        context = 0
        extension = 0
    else:
        extension = -(-n // WINDOW) * WINDOW - n  # ceil to a whole window
        padded = np.pad(audio, (CONTEXT, CONTEXT + extension))
        pieces = [padded[i : i + WINDOW + 2 * CONTEXT] for i in range(0, len(padded) - 2 * CONTEXT, WINDOW)]
        context = CONTEXT

    frames = []
    with torch.inference_mode():
        for k, piece in enumerate(pieces):
            x = torch.from_numpy(piece).to(device)[None]
            logits = model(x).logits[0]
            logp = torch.log_softmax(logits.float(), dim=-1).cpu().numpy()
            if context:
                c = context // ratio
                logp = logp[c : c + WINDOW // ratio]
            frames.append(logp)
            print(f"window {k + 1} of {len(pieces)}", file=sys.stderr, flush=True)

    emissions = np.concatenate(frames, axis=0).astype(np.float32)
    if extension:
        emissions = emissions[: emissions.shape[0] - extension // ratio]

    emissions.tofile(out_base + ".bin")
    info = {
        "frames": int(emissions.shape[0]),
        "tokens": int(emissions.shape[1]),
        "frame_seconds": ratio / RATE,
        "blank": tokenizer.pad_token_id,
        "vocab": tokenizer.get_vocab(),
    }
    with open(out_base + ".json", "w", encoding="utf-8") as f:
        json.dump(info, f)


if __name__ == "__main__":
    main()
