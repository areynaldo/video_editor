package main

import "core:path/filepath"
import "core:strings"
import win "core:sys/windows"

// Native Windows (Explorer) open/save dialogs.
// filter: pairs separated by '|', e.g. "Video|*.mp4;*.mkv|All files|*.*"
// Returns the chosen paths (empty if cancelled). Blocks until the dialog closes.
file_dialog :: proc(save: bool, title, filter: string, default_name := "", multi := false) -> []string {
	buf := make([]u16, 32768, context.temp_allocator)
	if default_name != "" {
		copy(buf, win.utf8_to_utf16(default_name, context.temp_allocator))
	}

	wfilter := make([dynamic]u16, context.temp_allocator)
	for ch in transmute([]u8)filter {
		append(&wfilter, ch == '|' ? 0 : u16(ch))
	}
	append(&wfilter, 0, 0)

	flags: u32 = win.OFN_EXPLORER | win.OFN_NOCHANGEDIR | win.OFN_PATHMUSTEXIST
	if save {
		flags |= win.OFN_OVERWRITEPROMPT
	} else {
		flags |= win.OFN_FILEMUSTEXIST
		if multi {flags |= win.OFN_ALLOWMULTISELECT}
	}
	ofn := win.OPENFILENAMEW {
		lStructSize = size_of(win.OPENFILENAMEW),
		lpstrFile   = win.wstring(&buf[0]),
		nMaxFile    = u32(len(buf)),
		lpstrTitle  = win.utf8_to_wstring(title, context.temp_allocator),
		lpstrFilter = win.wstring(&wfilter[0]),
		Flags       = flags,
	}
	ok := save ? bool(win.GetSaveFileNameW(&ofn)) : bool(win.GetOpenFileNameW(&ofn))
	if !ok {
		return nil
	}

	// result: "path\0" or (multi) "dir\0file1\0file2\0\0"
	parts := make([dynamic]string, context.temp_allocator)
	start := 0
	for i in 0 ..< len(buf) {
		if buf[i] != 0 {
			continue
		}
		if i == start {
			break
		}
		s, _ := win.utf16_to_utf8(buf[start:i], context.temp_allocator)
		append(&parts, s)
		start = i + 1
	}
	if len(parts) <= 1 {
		return parts[:]
	}
	paths := make([dynamic]string, context.temp_allocator)
	for name in parts[1:] {
		append(&paths, strings.concatenate({parts[0], "\\", name}, context.temp_allocator))
	}
	return paths[:]
}

// One file: the chosen path, or ok = false when cancelled. xt (with the dot) is added to a name that has none.
pick_file :: proc(save: bool, title, filter: string, name := "", ext := "") -> (path: string, ok: bool) {
	paths := file_dialog(save, title, filter, name)
	if len(paths) == 0 {return}
	path = paths[0]
	if ext != "" && filepath.ext(path) == "" {path = strings.concatenate({path, ext}, context.temp_allocator)}
	return path, true
}
