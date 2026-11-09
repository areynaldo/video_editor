package main

// Per-frame summary of the tracks, computed once in one pass over the clips so the
// UI doesn't rescan them for every lane / clip / label it draws.

Track_Info :: struct {
	has_video: bool,
	has_audio: bool,
	video_ord: int, // index in tracks_video, or -1: what layer key / "V3" refers to
}

tracks_info: []Track_Info
tracks_video: []int // tracks that contain video, ascending

build_tracks :: proc(p: Project) {
	info := make([]Track_Info, p.track_count, context.temp_allocator)
	for &t in info {
		t.video_ord = -1
	}
	for c in p.clips {
		if c.track < 0 || c.track >= len(info) {continue}
		if c.kind == .Video {info[c.track].has_video = true} else {info[c.track].has_audio = true}
	}
	video := make([dynamic]int, context.temp_allocator)
	for &t, i in info {
		if t.has_video {
			t.video_ord = len(video)
			append(&video, i)
		}
	}
	tracks_info, tracks_video = info, video[:]
}

// Safe lookup (the summary can be one edit behind within a frame).
track_info :: proc(track: int) -> Track_Info {
	if track >= 0 && track < len(tracks_info) {
		return tracks_info[track]
	}
	return {video_ord = -1}
}

// Index in the video layer list (what the layer keys 1..9 refer to), or -1.
layer_ordinal :: proc(video: []int, track: int) -> int {
	return track_info(track).video_ord
}
