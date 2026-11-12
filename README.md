# Video Editor

A small video editor for personal music videos. It cuts video clips to the beat of a song.

![Video Editor](docs/screenshot.png)

## Main features

- Import video and audio files. Use **Import** or drop files on the window.
- Remove the sound of video files. The song stays.
- Detect the bpm of a song. If the result is wrong, pick another candidate or tap the tempo.
- Show a beat grid. Cuts and clips snap to the grid.
- Make patterns. A pattern is a loop of hits on the beat grid, like a drum machine. Each hit makes a cut.
- Make parts. A part is a time range with its own pattern.
- Show one video layer at a time. The program row shows which layer is visible.
- Select a range in the program row. Copy it, paste it, repeat it, or loop it.
- Randomize. It fills each slice of the rhythm with footage from your clips, on a new layer. The footage is the same time, in order, or any piece.
- Lock clips and slices (`k`). A locked clip does not change. Randomize again: locked slices stay, the other slices change. Roll the mouse wheel on a slice to switch its footage.
- Add lyrics. Type the text, one line each, with times. Edit the lines in the Lyrics row of the timeline. Press **Auto-align** to time the lines from the song (needs whisper.cpp), or tap the start of each line while the song plays. The lines show in the preview and in the export. Pick what is shown (one word, a sentence, or a verse that builds up), the font, the text color, and the border color. Open and save SRT, LRC, ASS, and TXT.
- Make smooth slow motion. Select clips. Press **Smooth slow-mo**. A window sets the speed in percent or the new length (the two follow each other), then renders. You can also slow a clip by hand (`shift` + drag its edge). Commands act on all selected clips. It renders the new frames one time and keeps the file in the `cache` folder.
- Enhance clips. **Enhance + upscale** renders a clip at twice the size, cleaner, sharper, with fixed levels.
- Long jobs (auto-align, slow-mo, enhance) run in the background. A loading window shows the progress in percent, and the editor does not freeze. **Cancel** stops the job.
- Set the output size from a list (1080p, 4K, vertical 9:16, square, 4:5, ...) in the Inspector or the Sequence panel. Turn it with one button. Pick how a clip fills the picture: **fit** (background around), **fill** (crop the edges), or **stretch**.
- Set the background color: double-click the Program picture, use **Edit > Background color...** (or `F1`), or use the Inspector. Set the transform of one slice or of all slices of a clip.
- Edit on many layers. Lock, hide, mute, or solo a layer.
- Play with sound. See the waveform and the level meters.
- Export with ffmpeg to mp4, mkv, webm, or mov.
- Use undo and redo. Press **F1** to search all commands.

## Ideal workflow

1. Import your video files and your song (`ctrl+i`).
2. Press **Remove audio** (`shift+delete`). This removes the sound of the video files.
3. Select the song. Press **Detect bpm** (`t`).
4. If the bpm is wrong, click another candidate in the **Sequence** panel. Or press **Tap** (`shift+t`) with the music.
5. If the grid is not on the beat, move the playhead to a beat. Press **Beat at playhead** (`shift+h`).
6. Open **Patterns** (`shift+p`). Press **New**. Click the steps to make hits.
7. Set each lane to a layer (V1, V2, ...) or to `mark`. A `mark` only makes a cut.
8. Press **Apply pattern** (`p`). To use other patterns in other places, pick a pattern in the **brush** strip of the Timeline. Drag in the **Parts** row to paint it. `ctrl`+click a part to repaint it. Right-click a part for more.
9. Select a range in the program row. Press `ctrl+c` to copy, `ctrl+v` to paste, or `ctrl+r` to repeat it. Press `ctrl+l` to loop the playback.
10. Open **Randomize options** (`shift+r`). Set the options. Press **Randomize** (`r`).
    - It slices at the cuts, the pattern, or the grid. It fills each slice with footage on a new layer.
    - A lane with a layer keeps its layer.
    - The **Randomize** section of the Inspector shows and sets how the footage is chosen (slice at, footage, use all clips, max in a row).
    - Select slices you like. Press **Lock** (`k`) or the Inspector button. **Reroll** gives selected slices new random footage. Press `r` again: locked slices stay, the others change.
    - Roll the mouse wheel on a slice to switch its footage. The footage mode decides which footage comes next. The slice is locked after that.
11. For lyrics, press **Lyrics** (`shift+y`). Paste the text. Press `space` to play the song. Or press **Auto-align**. Or press **Tap** (`y`) at the start of each line. Drag lines in the Lyrics row to correct them: click or ctrl+click to select, drag a box to select many, drag one to move them all. The **move** buttons in the Lyrics window shift all lines or the selected ones. Use **Lyrics > Export lyrics** to save a subtitle file.
12. Press `space` to play. Press `ctrl+z` to undo a change.
13. Press **Export** (`ctrl+e`).

## Build

You need:

- Windows 10 or 11
- The [Odin compiler](https://odin-lang.org)
- `ffmpeg` and `ffprobe` in your `PATH`

Get the source and the submodule, then build:

```
git clone --recurse-submodules https://github.com/areynaldo/video_editor.git
cd video_editor
.\setup.ps1
odin build . -out:editor.exe
```

Run:

```
editor.exe
editor.exe project.vproj
```

`setup.ps1` runs one time. It applies a small fix to the Dear ImGui bindings (see **Notes**).

## Auto-align lyrics (optional)

Auto-align uses [whisper.cpp](https://github.com/ggml-org/whisper.cpp). It does not need Python.

1. Get `whisper-cli.exe` (with its DLL files) from the whisper.cpp releases. Put it in the `tools` folder or in your `PATH`.
2. Get a ggml model, for example `ggml-base.bin`. For a language other than English, use a model without `.en`.
3. Open **Lyrics > Lyrics...**. Open **auto-align setup**. Pick the model file and set the language (`auto` or `en`, `es`, ...).
4. Select the song. Press **Auto-align**. A loading window shows while it listens. By default it listens to the voice range only (a simple filter). For better results, set a vocal separator command (**separator** field): any tool that writes the vocals as a wav file. Use `{in}` for the song, and `{out}` or `{dir}` for the result.

It places the lines on a clock that counts only the seconds when the voice is on, so the gaps between phrases stay empty. The words that it heard right are anchors; between them the lines are spread by length. After each run it writes `lyrics_align_debug.txt` (the voiced parts, the heard words and the line times) for checking.

The lines also follow the silences of the audio: a line that starts or stops inside a quiet part is moved to where the voice really starts or stops. This works best on separated vocals. Example separator command with [uv](https://docs.astral.sh/uv/): `uv tool run --python 3.12 --from "audio-separator[cpu]" --with audioread audio-separator {in} --output_dir {dir} --single_stem Vocals --model_filename UVR-MDX-NET-Voc_FT.onnx --output_format WAV`. The first run downloads the model. `--with audioread` adds a package that audio-separator 0.48 needs but does not list. Python 3.12 is used (uv fetches it): the newest Python has no ready-made packages for some of the libraries, and building them fails.

**Whisper align** (the default when you have lyrics in the window) lets whisper itself place your text on the audio, with [stable-ts](https://github.com/jianfch/stable-ts). It is the usual tool for lyrics, and whisper copes with music and fast words better than the small alignment models. It needs [uv](https://docs.astral.sh/uv/): the first run fetches Python, torch, stable-ts, and a whisper model. Set the language (for example `es`) in the auto-align setup; `auto` finds it from the audio. A model name at the end of the command picks the size (small is the default, medium or large-v3 are better and slower). Pick the engine in the setup: **whisper aligns your words** (default), **voice model lines up your words (CTC)**, or **whisper listens** (the old way, and the only one that works without lyrics).

**Forced alignment with a voice model (CTC)** is the most exact way. It does not recognise what is sung. A voice model (wav2vec2 / MMS, 1100+ languages) says how likely each letter is in every 20 ms of the audio. Then your words are lined up with those frames by the best monotone path, so every word of your text is placed where the voice says it, and silences stay empty. It needs [uv](https://docs.astral.sh/uv/): the first run fetches Python, torch, transformers and the model (about 2 GB, once). The script is `scripts/ctc_emissions.py`. The model `MahmoudAshraf/mms-300m-1130-forced-aligner` has a non-commercial license (CC-BY-NC 4.0). For Spanish (or any language) you can pick a model made for it: add its name at the end of the aligner command, for example `... scripts\ctc_emissions.py {wav} {out} jonatasgrosman/wav2vec2-large-xlsr-53-spanish`. Such a model has its own alphabet (accents, ñ); the editor uses it. Where the voice model hears nothing (a loud beat, a bad vocal track) the words are spread evenly over that audio instead of being squeezed. If lines still get far too little time, a message says so and shows what the model heard for every 10 s. Letters a-z (with accents removed) are aligned; other alphabets are not. It is much better with **vocals only** and a real separator.

With lyrics in the window, it matches your words to the words it hears and times each line. With no lyrics, it writes the lines from what it hears. Check the result in the Lyrics row. Singing over loud music gives weaker results than speech. Then use **Tap** or drag lines to correct them.

## Smooth slow-mo (optional)

A slowed clip repeats frames. **Smooth slow-mo** makes new frames between them.

- With `rife-ncnn-vulkan.exe` (in `tools\` or in your `PATH`, with a `rife-v4.6` model folder) it uses the RIFE ML model on the GPU. This gives the best result. RIFE gets the source's own frames (not resampled to the project fps), which keeps the motion smooth. The cache file name includes the tools used, so a render made with ffmpeg is never mistaken for a RIFE one. `tools\gpu.txt` with a number picks the GPU.
- Without it, it uses the ffmpeg `minterpolate` filter. This needs no extra tool, but it is slower and shows more errors on fast motion.

The sound is not changed. A loading window shows while it renders.

**Slow-mo + enhance** does both in one pass: denoise, then interpolate, then upscale. With RIFE and Real-ESRGAN both in `tools\` it runs on the GPU. Without them it uses ffmpeg on all CPU cores.

Upscaling is skipped when the source is already as big as the project (a 1080p clip in a 1080p project): it would only be shrunk again at export. The status line shows how long each step took (cut, RIFE, Real-ESRGAN, encode), so you can see what is slow.

The ML tools use the Vulkan GPU that they find first. A computer with two GPUs (for example a laptop with an integrated GPU) may need a choice: write the device number (`0`, `1`, ...) in `tools\gpu.txt`.

## Enhance and upscale (optional)

**Enhance + upscale** (Timeline menu) renders the selected video clips at twice the size.

- With `realesrgan-ncnn-vulkan.exe` (in `tools\` or in your `PATH`, with its `models` folder) it uses Real-ESRGAN on the GPU. It uses `realesr-general-x4v3` if you have it, else `realesr-animevideov3` (small and fast, made for anime).
- Without it, it uses ffmpeg: Lanczos upscale, denoise, sharpen, and automatic levels.

It is not an AI color corrector. The levels fix is a simple filter.

## Only whisper: write the lyrics from the song

Press **Transcribe** in the Lyrics window (or **Lyrics > Transcribe lyrics**). Whisper listens to the song and the lines it hears become the lyrics, with their times. This replaces the lines that are there. Then fix the wrong words in the text box: the times stay. Whisper breaks lines at its commas and at pauses, and sung words that it stretches over a silence are cut back to where the voice returns.

## Test the alignment outside the editor

`scripts\diagnose.py` runs the stages one by one and prints what each finds: how loud the audio is (10 s at a time), the words whisper hears with their times (and how many in each 10 s), and how your lyrics line up with them. Run it on the song and on the separated vocals (`lyrics_align_heard.wav`) to see which one whisper hears:

```n uv run --python 3.12 --no-project --with faster-whisper --with numpy scripts\diagnose.py song.mp3 lyrics.txt --stem lyrics_align_heard.wav --lang es
```n
Add `--crisper` to also try [CrisperWhisper](https://github.com/nyrahealth/CrisperWhisper) (needs its transformers fork: add `--with "transformers @ git+https://github.com/nyrahealth/transformers.git@crisper_whisper" --with torch`).

## When a job fails

Auto-align, slow-mo, and enhance show a **Problem** window with the full text of what the tool said. Use **Copy** to take it. The text is also in `last_job_error.txt`. Auto-align writes `lyrics_align_debug.txt` after a good run.

## Files

| File | Use |
|---|---|
| `*.vproj` | Project file. It is plain text. |
| `keybindings.ini` | All keys. The editor makes it at first start. Press `F5` to reload it. |
| `cache\` | Rendered slow-mo files. You can delete it. |
| `imgui.ini` | Window layout. Use **View > Reset layout** to restore it. |

## Notes

- Export opens one ffmpeg input for each clip. Many small clips make the export slow. Use slices of one beat or more.
- `deps/odin-imgui` is a Git submodule. It holds the Dear ImGui bindings from `gitlab.com/L-4/odin-imgui`.
- The bindings have one error in `imgui_impl_opengl3/imgui_impl_opengl3.odin`. The file `patches/odin-imgui-opengl3.patch` corrects it. `setup.ps1` applies it.
