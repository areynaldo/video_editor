package main

import "core:fmt"
import "core:os"
import "core:sync"
import "core:thread"

import gl "vendor:OpenGL"
import stbi "vendor:stb/image"

// Preview works from a proxy: when a source is loaded, one ffmpeg process decodes
// the whole file once into small JPEG frames held in memory. Showing a frame is
// then just a JPEG decode + texture upload, so scrubbing is instant for
// everything already decoded (decoding runs far faster than realtime).
// Frames keep the source's aspect ratio; the preview panel does the fitting.

PROXY_MAX_W :: 640
PROXY_MAX_H :: 360

Proxy :: struct {
	mu:      sync.Mutex,
	frames:  [dynamic][]u8, // jpeg frames (slices into blocks), guarded by mu
	blocks:  [dynamic][]u8, // big bump-allocated blocks the frames live in; reader thread only, freed on reset
	used:    int, // bytes used in the last block
	fps:     int,
	process: os.Process,
	thread:  ^thread.Thread,
}

proxies: [dynamic]^Proxy // parallel to Project.sources

pv_texture: u32
pv_w, pv_h: i32 // size of the texture's current contents
pv_shown_src := -1
pv_shown_idx := -1

preview_init :: proc() {
	gl.GenTextures(1, &pv_texture)
	gl.BindTexture(gl.TEXTURE_2D, pv_texture)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR)
}

// Stops every decoder and forgets all proxies (used on shutdown and project reset).
preview_reset :: proc() {
	audio_reset() // audio buffers are tied to the same source list
	for p in proxies {
		if p.thread != nil {
			_ = os.process_kill(p.process)
		}
	}
	for p in proxies {
		if p.thread != nil {
			thread.join(p.thread)
		}
		for b in p.blocks { // one free per block instead of one per frame
			delete(b)
		}
		delete(p.blocks)
		delete(p.frames)
		free(p)
	}
	clear(&proxies)
	pv_shown_src, pv_shown_idx = -1, -1
}

proxy_start :: proc(path: string, fps: int) {
	p := new(Proxy)
	p.fps = fps
	append(&proxies, p)

	r, w, _ := os.pipe()
	desc := os.Process_Desc {
		command = {
			"ffmpeg", "-v", "error", "-i", path, "-an",
			"-vf", fmt.tprintf("fps=%d,scale=%d:%d:force_original_aspect_ratio=decrease:force_divisible_by=2", fps, PROXY_MAX_W, PROXY_MAX_H),
			"-pix_fmt", "yuvj420p", "-c:v", "mjpeg", "-q:v", "4", "-f", "image2pipe", "pipe:1",
		},
		stdout = w,
	}
	proc_, err := os.process_start(desc)
	os.close(w)
	if err != nil {
		os.close(r)
		return
	}
	p.process = proc_
	p.thread = thread.create_and_start_with_poly_data2(p, r, proxy_reader)
}

FRAME_BLOCK :: 8 << 20

// Frames are copied into big blocks (a bump allocator): thousands of small
// allocations become a handful, and everything is freed together on reset.
store_frame :: proc(p: ^Proxy, jpeg: []u8) -> []u8 {
	n := len(jpeg)
	if len(p.blocks) == 0 || p.used + n > len(p.blocks[len(p.blocks) - 1]) {
		append(&p.blocks, make([]u8, max(FRAME_BLOCK, n)))
		p.used = 0
	}
	block := p.blocks[len(p.blocks) - 1]
	out := block[p.used:p.used + n]
	copy(out, jpeg)
	p.used += n
	return out
}

// Reads the pipe and splits the stream into jpeg frames (SOI ... EOI).
proxy_reader :: proc(p: ^Proxy, r: ^os.File) {
	defer os.close(r)
	chunk := make([]u8, 1 << 20)
	defer delete(chunk)
	pending: [dynamic]u8
	defer delete(pending)
	scan := 0
	for {
		n, err := os.read(r, chunk)
		if n <= 0 || err != nil {
			return
		}
		append(&pending, ..chunk[:n])
		i := scan
		for i + 1 < len(pending) {
			if pending[i] == 0xFF && pending[i + 1] == 0xD9 {
				frame := store_frame(p, pending[:i + 2])
				sync.mutex_lock(&p.mu)
				append(&p.frames, frame)
				sync.mutex_unlock(&p.mu)
				remove_range(&pending, 0, i + 2)
				i = 0
			} else {
				i += 1
			}
		}
		scan = max(0, i)
	}
}

// Call every frame with the source (or -1) and the time inside it. Cheap when unchanged.
preview_show :: proc(src: int, t: f64) {
	if src < 0 || src >= len(proxies) {
		return
	}
	p := proxies[src]
	sync.mutex_lock(&p.mu)
	idx := min(int(t * f64(p.fps)), len(p.frames) - 1)
	jpeg: []u8
	if idx >= 0 {
		jpeg = p.frames[idx]
	}
	sync.mutex_unlock(&p.mu)

	if idx < 0 || (src == pv_shown_src && idx == pv_shown_idx) {
		return
	}
	w, h, ch: i32
	pixels := stbi.load_from_memory(raw_data(jpeg), i32(len(jpeg)), &w, &h, &ch, 4)
	if pixels == nil {
		return
	}
	defer stbi.image_free(pixels)
	gl.BindTexture(gl.TEXTURE_2D, pv_texture)
	if w != pv_w || h != pv_h {
		gl.TexImage2D(gl.TEXTURE_2D, 0, gl.RGBA, w, h, 0, gl.RGBA, gl.UNSIGNED_BYTE, pixels)
		pv_w, pv_h = w, h
	} else {
		gl.TexSubImage2D(gl.TEXTURE_2D, 0, 0, 0, w, h, gl.RGBA, gl.UNSIGNED_BYTE, pixels)
	}
	pv_shown_src, pv_shown_idx = src, idx
}

// Video clip shown at time t, or -1. Normally the topmost one; if the program
// picks a layer, only that layer's clip.
video_clip_at :: proc(p: Project, t: f64) -> int {
	best := -1
	layer := program_layer_at(p, t)
	for c, i in p.clips {
		if c.kind == .Video && t >= c.start && t < clip_end(c) && (layer < 0 || c.track == layer) && !track_has(p, c.track, .Hidden) {
			if best < 0 || c.track > p.clips[best].track {
				best = i
			}
		}
	}
	return best
}
