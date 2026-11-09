# Video Editor

A small video editor for personal music videos. It cuts video clips to the beat of a song.

![Video Editor](docs/screenshot.png)

## Main features

- Import video and audio files. Use **Import** or drop files on the window.
- Remove the sound of video files. The song stays.
- Detect the bpm of a song. If the result is wrong, pick another candidate or tap the tempo.
- Show a beat grid. Cuts and clips snap to the grid.
- Make patterns. A pattern is a loop of hits on the beat grid, like a drum machine. Each hit makes a cut.
- Show one video layer at a time. The program row shows which layer is visible.
- Select a range in the program row. Copy it, paste it, repeat it, or loop it.
- Randomize the layers. Or rearrange the clips with clip shuffle and time shuffle.
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
8. Press **Apply pattern** (`p`).
9. Select a range in the program row. Press `ctrl+c` to copy, `ctrl+v` to paste, or `ctrl+r` to repeat it. Press `ctrl+l` to loop the playback.
10. Open **Randomize options** (`shift+r`). Set the options. Press **Randomize** (`r`).
    - A `mark` gets a random layer.
    - A lane with a layer keeps its layer.
11. Press `space` to play. Press `ctrl+z` to undo a change.
12. Press **Export** (`ctrl+e`).

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

## Files

| File | Use |
|---|---|
| `*.vproj` | Project file. It is plain text. |
| `keybindings.ini` | All keys. The editor makes it at first start. Press `F5` to reload it. |
| `imgui.ini` | Window layout. Use **View > Reset layout** to restore it. |

## Notes

- Export opens one ffmpeg input for each clip. Many small clips make the export slow. Use slices of one beat or more.
- `deps/odin-imgui` is a Git submodule. It holds the Dear ImGui bindings from `gitlab.com/L-4/odin-imgui`.
- The bindings have one error in `imgui_impl_opengl3/imgui_impl_opengl3.odin`. The file `patches/odin-imgui-opengl3.patch` corrects it. `setup.ps1` applies it.
