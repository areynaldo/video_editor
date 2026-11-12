package main

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

import im "deps/odin-imgui"

// One background job at a time (auto-align, slow-mo render). The work runs on its own
// thread and must not touch the project: it reads a copy of what it needs and leaves its
// result in `data`. While it runs a modal window with a spinner covers the editor (so
// nothing changes under the job). When the thread is done the main thread calls
// `finish`, which applies the result to the project.

Job :: struct {
	active:    bool,
	shown:     bool, // the modal was opened
	title:     string,
	step:      [200]u8, // what the worker is doing now
	mu:        sync.Mutex, // guards step
	done:      bool, // atomic: the worker returned
	cancelled: bool, // atomic: the user asked to stop (the worker checks between steps)
	frac:      f32, // 0..1 of the whole job; < 0 = unknown (guarded by mu)
	base, scale: f32, // the step the worker is in: whole = base + scale * inner
	started:   time.Tick,
	thread:    ^thread.Thread,
	work:      proc(data: rawptr), // runs on the thread
	finish:    proc(data: rawptr), // runs on the main thread when work returned
	data:      rawptr,
}

job: Job

job_start :: proc(title: string, work, finish: proc(data: rawptr), data: rawptr) -> bool {
	if job.active {
		return false
	}
	job = {}
	job.active, job.title, job.work, job.finish, job.data = true, title, work, finish, data
	job.frac, job.scale = -1, 1
	job.started = time.tick_now()
	job_step("starting ...")
	job.thread = thread.create(proc(_: ^thread.Thread) {
		context = runtime.default_context() // its own temp allocator: the main thread's is not thread safe
		job.work(job.data)
		free_all(context.temp_allocator)
		sync.atomic_store(&job.done, true)
		})
	thread.start(job.thread)
	return true
}

// Worker: tell the user what is happening.
job_step :: proc(format: string, args: ..any) {
	text := fmt.tprintf(format, ..args)
	sync.mutex_lock(&job.mu)
	set_fixed(job.step[:], text)
	sync.mutex_unlock(&job.mu)
}

// Worker: the next steps fill base .. base + scale of the bar (job_progress takes 0..1 inside).
job_range :: proc(base, scale: f32) {
	sync.mutex_lock(&job.mu)
	job.base, job.scale = base, scale
	sync.mutex_unlock(&job.mu)
}

// Worker: how far the current range is (0..1).
job_progress :: proc(inner: f32) {
	sync.mutex_lock(&job.mu)
	job.frac = job.base + job.scale * clamp(inner, 0, 1)
	sync.mutex_unlock(&job.mu)
}

// What tells how far a program is:
//   Frames   files appearing in a folder (path), `total` expected
//   Ffmpeg   ffmpeg's -progress file (path); `total` = seconds of output
//   Whisper  whisper-cli's progress lines in its stderr file
Watch_Kind :: enum {
	None,
	Frames,
	Ffmpeg,
	Whisper,
	Percent, // a progress bar written to stderr (tqdm: " 45%|####"): the last number before "%|"
}

Watch :: struct {
	kind:  Watch_Kind,
	path:  string,
	total: f64,
}

// Did the program finish and report success? (Process_State.success only says the wait worked:
// a program that exits with code 3 still has success = true.)
exited_ok :: proc(s: os.Process_State) -> bool {
	return s.exited && s.exit_code == 0
}

JOB_PROGRESS_FILE :: "job_progress.txt"

// ---------------------------------------------------------------- what a tool prints

// Everything a tool prints (output and errors together), collected by a thread. A tool whose
// output nobody reads stops when the pipe is full, so something must always be reading. (A
// file handed to the tool stayed empty on Windows, and uvx fails with "handle is invalid"
// unless it has real pipes, so a pipe it is.)
Log :: struct {
	buf:  [dynamic]byte,
	mu:   sync.Mutex,
	r:    ^os.File,
	th:   ^thread.Thread,
	done: bool, // atomic: the reader reached the end
}

LOG_MAX :: 1 << 20

// The log whose text the progress watchers read (the one of the running tool).
cur_log: ^Log

// Starts the pipe for a tool: returns the end the tool writes to (pass it as stdout and
// stderr, and close it here once the tool has started).
log_pipe :: proc(l: ^Log) -> (w: ^os.File, ok: bool) {
	r, wr, err := os.pipe()
	if err != nil {return nil, false}
	l.r = r
	return wr, true
}

log_start_reader :: proc(l: ^Log) {
	l.th = thread.create(proc(t: ^thread.Thread) {
		l := (^Log)(t.data)
		chunk: [4096]byte
		for {
			n, err := os.read(l.r, chunk[:])
			if n > 0 {
				sync.mutex_lock(&l.mu)
				append(&l.buf, ..chunk[:n])
				if len(l.buf) > LOG_MAX { // keep the end
					copy(l.buf[:], l.buf[len(l.buf) / 2:])
					resize(&l.buf, len(l.buf) - len(l.buf) / 2)
				}
				sync.mutex_unlock(&l.mu)
			}
			if err != nil || n == 0 {break}
		}
		sync.atomic_store(&l.done, true)
	})
	l.th.data = l
	thread.start(l.th)
}

log_text :: proc(l: ^Log) -> string {
	if l == nil {return ""}
	sync.mutex_lock(&l.mu)
	defer sync.mutex_unlock(&l.mu)
	return strings.clone(string(l.buf[:]), context.temp_allocator)
}

// After the tool ended: waits a moment for the reader, then closes everything.
log_finish :: proc(l: ^Log) -> string {
	for _ in 0 ..< 20 { // a tool that left a child behind could keep the pipe open
		if sync.atomic_load(&l.done) {break}
		time.sleep(25 * time.Millisecond)
	}
	text := strings.clone(string(l.buf[:]), context.temp_allocator)
	if l.r != nil {os.close(l.r)}
	if l.th != nil {thread.join(l.th); thread.destroy(l.th)}
	delete(l.buf)
	return text
}

// The last number before "marker", as 0..1 (e.g. "45%|" or "progress = 5%").
percent_in :: proc(text, marker: string, before: bool) -> f32 {
	i := strings.last_index(text, marker)
	if i < 0 {return 0}
	if before { // digits before the marker: tqdm prints " 45%|####"
		a := i
		for a > 0 && text[a - 1] >= '0' && text[a - 1] <= '9' {a -= 1}
		if v, ok := strconv.parse_int(text[a:i]); ok {return f32(v) / 100}
		return 0
	}
	rest := strings.trim_left_space(text[i + len(marker):]) // digits after it: "progress = 5%"
	n := 0
	for n < len(rest) && rest[n] >= '0' && rest[n] <= '9' {n += 1}
	if v, ok := strconv.parse_int(rest[:n]); ok {return f32(v) / 100}
	return 0
}

// 0..1, or -1 when unknown.
watch_fraction :: proc(w: Watch) -> f32 {
	switch w.kind {
	case .None:
	case .Frames:
		infos, err := os.read_directory_by_path(w.path, -1, context.temp_allocator)
		if err == nil && w.total > 0 {return f32(f64(len(infos)) / w.total)}
	case .Ffmpeg:
		data, err := os.read_entire_file(w.path, context.temp_allocator)
		if err != nil || w.total <= 0 {return -1}
		text := string(data)
		if i := strings.last_index(text, "out_time_us="); i >= 0 {
			rest := text[i + len("out_time_us="):]
			if end := strings.index_byte(rest, '\n'); end >= 0 {rest = rest[:end]}
			us, ok := strconv.parse_i64(strings.trim_space(rest))
			if ok {return f32(f64(us) / 1e6 / w.total)}
		}
		return 0
	case .Percent: return percent_in(log_text(cur_log), "%|", true)
	case .Whisper: return percent_in(log_text(cur_log), "progress = ", false)
	}
	return -1
}

// Runs a program and waits for it, keeping the bar up to date and stopping it when the
// user cancels. The bar goes from `lo` to `hi` (0..1 of the current range) while it runs.
// Returns "" on success, "stopped" when cancelled, else what the tool printed.
run_tracked :: proc(cmd: []string, w: Watch, lo, hi: f32) -> string {
	if job_cancelled() {return "stopped"}
	job_progress(lo)
	log: Log
	pipe_w, ok := log_pipe(&log)
	if !ok {return "could not make a pipe for the tool's output"}
	// stdin stays nil: a NUL file as stdin makes uv's launchers fail with "The handle is invalid"
	proc_, err := os.process_start({command = cmd, stdout = pipe_w, stderr = pipe_w})
	os.close(pipe_w)
	if err != nil {
		os.close(log.r)
		return fmt.tprintf("could not start %s", cmd[0])
	}
	log_start_reader(&log)
	cur_log = &log
	defer cur_log = nil
	state: os.Process_State
	stopped := false
	for {
		st, werr := os.process_wait(proc_, 250 * time.Millisecond)
		if werr == nil {state = st; break}
		if werr != os.General_Error.Timeout {break}
		if f := watch_fraction(w); f >= 0 {job_progress(lo + (hi - lo) * clamp(f, 0, 1))}
		if job_cancelled() {
			_ = os.process_kill(proc_)
			_, _ = os.process_wait(proc_)
			stopped = true
			break
		}
	}
	cur_log = nil
	text := log_finish(&log)
	os.remove(JOB_PROGRESS_FILE)
	switch {
	case stopped:           return "stopped"
	case !exited_ok(state): return len(text) > 0 ? text : fmt.tprintf("%s failed (exit code %d)", cmd[0], state.exit_code)
	}
	job_progress(hi)
	return ""
}

// Runs several programs at the same time (one ffmpeg for each piece of a clip, so every
// core works) and waits for all. Each ffmpeg writes its own -progress file (`files[i]`)
// and makes `seconds[i]` of output; the bar is their mean. Returns "" on success, "stopped"
// when cancelled, else the first error.
run_parallel :: proc(cmds: [][]string, files: []string, seconds: []f64, lo, hi: f32) -> string {
	n := len(cmds)
	procs := make([]os.Process, n, context.temp_allocator)
	logs := make([]Log, n, context.temp_allocator)
	running := make([]bool, n, context.temp_allocator)
	failed := make([]bool, n, context.temp_allocator)
	for i in 0 ..< n {
		pipe_w, ok := log_pipe(&logs[i])
		if !ok {failed[i] = true; continue}
		p, err := os.process_start({command = cmds[i], stdout = pipe_w, stderr = pipe_w})
		os.close(pipe_w)
		if err != nil {
			failed[i] = true
			os.close(logs[i].r)
			logs[i].r = nil
			continue
		}
		procs[i], running[i] = p, true
		log_start_reader(&logs[i])
	}
	stopped := false
	for {
		alive, total := 0, f32(0)
		for i in 0 ..< n {
			if running[i] {
				st, werr := os.process_wait(procs[i], 5 * time.Millisecond) // short wait: 0 may report a running process as done
				switch {
				case werr == nil && st.exited:                        running[i] = false; failed[i] = !exited_ok(st)
				case werr != nil && werr != os.General_Error.Timeout: running[i] = false; failed[i] = true
				}
			}
			if running[i] {
				alive += 1
				total += clamp(watch_fraction({.Ffmpeg, files[i], seconds[i]}), 0, 1)
			} else {
				total += 1
			}
		}
		job_progress(lo + (hi - lo) * total / f32(max(n, 1)))
		if job_cancelled() {
			for i in 0 ..< n {
				if running[i] {_ = os.process_kill(procs[i]); _, _ = os.process_wait(procs[i])}
			}
			stopped = true
			break
		}
		if alive == 0 {break}
		time.sleep(250 * time.Millisecond)
	}
	msg := ""
	for i in 0 ..< n {
		if logs[i].th != nil {
			text := log_finish(&logs[i])
			if failed[i] && msg == "" {msg = len(text) > 0 ? text : "ffmpeg failed"}
		} else if failed[i] && msg == "" {
			msg = "could not start ffmpeg"
		}
		os.remove(files[i])
	}
	if stopped {return "stopped"}
	if msg == "" {job_progress(hi)}
	return msg
}
// ffmpeg with a progress bar: `args` come after "ffmpeg"; `seconds` = length of its output.
ffmpeg_tracked :: proc(args: []string, seconds: f64, lo, hi: f32) -> string {
	cmd := make([dynamic]string, context.temp_allocator)
	append(&cmd, "ffmpeg", "-y", "-v", "error", "-nostdin", "-progress", JOB_PROGRESS_FILE)
	append(&cmd, ..args)
	return run_tracked(cmd[:], {.Ffmpeg, JOB_PROGRESS_FILE, seconds}, lo, hi)
}

// Worker: did the user press Cancel?
job_cancelled :: proc() -> bool {
	return sync.atomic_load(&job.cancelled)
}

// The loading screen and the hand-over of the result. Call once a frame.
job_ui :: proc() {
	if !job.active {
		return
	}
	if !job.shown {
		im.OpenPopup("Working##job")
		job.shown = true
	}
	vp := im.GetMainViewport()
	im.SetNextWindowPos({vp.Pos.x + vp.Size.x / 2, vp.Pos.y + vp.Size.y / 2}, .Always, {0.5, 0.5})
	im.SetNextWindowSize({380, 0}, .Always)
	if !im.BeginPopupModal("Working##job", nil, {.NoMove, .NoResize, .NoTitleBar}) {
		return
	}
	defer im.EndPopup()

	im.TextUnformatted(cstr(job.title))
	im.Spacing()
	// spinner: eight dots, the bright one runs round
	dl := im.GetWindowDrawList()
	c := im.GetCursorScreenPos()
	center := im.Vec2{c.x + 190, c.y + 26}
	phase := int(time.duration_seconds(time.tick_since(job.started)) * 10) % 8
	for i in 0 ..< 8 {
		a := f32(i) / 8 * 2 * math.PI
		alpha := u32(60 + 195 * f32((i - phase + 8) % 8) / 7)
		im.DrawList_AddCircleFilled(dl, {center.x + math.cos(a) * 18, center.y + math.sin(a) * 18}, 4, 0x00F0C070 | alpha << 24)
	}
	im.Dummy({0, 56})
	sync.mutex_lock(&job.mu)
	frac := job.frac
	sync.mutex_unlock(&job.mu)
	if frac >= 0 {
		im.ProgressBar(frac, {-1, 0}, cstr(fmt.tprintf("%.0f %%", frac * 100)))
	}
	sync.mutex_lock(&job.mu)
	step := cstr(get_fixed(job.step[:]))
	sync.mutex_unlock(&job.mu)
	im.TextWrapped("%s", step)
	dim_f("%.0f s", time.duration_seconds(time.tick_since(job.started)))
	im.SameLine(im.GetWindowWidth() - 150)
	if sync.atomic_load(&job.cancelled) {
		im.TextDisabled("stopping ...")
	} else if im.Button("Cancel") {
		sync.atomic_store(&job.cancelled, true)
	}

	if sync.atomic_load(&job.done) {
		thread.join(job.thread)
		thread.destroy(job.thread)
		im.CloseCurrentPopup()
		finish, data := job.finish, job.data
		job.active = false
		finish(data)
	}
}

// ---------------------------------------------------------------- problems

// When a job fails, the status line is too small and too short-lived for what a tool said (a
// Python traceback, ffmpeg's text). This window keeps the whole text until you close it, and
// you can copy it. The text is also written to last_job_error.txt.
report: struct {
	open, shown: bool,
	title:       string,
	text:        [4000]u8,
}

job_report :: proc(title, text: string) {
	tail := len(text) > len(report.text) - 8 ? text[len(text) - (len(report.text) - 8):] : text // the end says what went wrong
	report.open, report.shown, report.title = true, false, title
	set_fixed(report.text[:], tail)
	_ = os.write_entire_file("last_job_error.txt", transmute([]byte)text)
}

report_ui :: proc() {
	if !report.open {
		return
	}
	if !report.shown {
		im.OpenPopup("Problem##report")
		report.shown = true
	}
	vp := im.GetMainViewport()
	im.SetNextWindowPos({vp.Pos.x + vp.Size.x / 2, vp.Pos.y + vp.Size.y / 2}, .Always, {0.5, 0.5})
	if !im.BeginPopupModal("Problem##report", nil, {.AlwaysAutoResize}) {
		return
	}
	defer im.EndPopup()
	im.TextUnformatted(cstr(report.title))
	im.InputTextMultiline("##report_text", cstring(&report.text[0]), len(report.text), {640, 240}, {.ReadOnly})
	if im.Button("Copy") {im.SetClipboardText(cstring(&report.text[0]))}
	im.SameLine()
	if im.Button("Close") {
		im.CloseCurrentPopup()
		report.open = false
	}
}
