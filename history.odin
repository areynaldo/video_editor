package main

import "core:slice"

// Undo/redo by snapshots. The model is plain data, so a snapshot is just a copy
// of the clips (+ counters). Nothing has to announce its edits: once per frame
// history_commit() compares the project with the last snapshot and, if the
// content changed and no drag/widget is in progress, records one undo step.
// Dragging therefore becomes a single step. Selection is not part of history.
// Sources are append-only, so undoing an import removes its clips only.

Snapshot :: struct {
	clips:       []Clip,
	track_count: int,
	next_group:  int,
	cuts:        []Cut,
	flags:       []Track_Flags,
}

MAX_HISTORY :: 200

undo_stack, redo_stack: [dynamic]Snapshot
last_state: Snapshot

snapshot_of :: proc(p: Project) -> Snapshot {
	return {slice.clone(p.clips[:]), p.track_count, p.next_group, slice.clone(p.program[:]), slice.clone(p.track_flags[:])}
}

snapshot_free :: proc(s: Snapshot) {
	delete(s.clips)
	delete(s.cuts)
	delete(s.flags)
}

same_content :: proc(a, b: Snapshot) -> bool {
	if len(a.flags) != len(b.flags) || len(a.cuts) != len(b.cuts) || len(a.clips) != len(b.clips) || a.track_count != b.track_count || a.next_group != b.next_group {
		return false
	}
	for i in 0 ..< len(a.flags) {
		if a.flags[i] - {.Selected} != b.flags[i] - {.Selected} {return false} // selection is not history
	}
	for i in 0 ..< len(a.cuts) {
		if a.cuts[i] != b.cuts[i] {return false}
	}
	for i in 0 ..< len(a.clips) {
		x, y := a.clips[i], b.clips[i]
		x.selected, y.selected = false, false
		if x != y {
			return false
		}
	}
	return true
}

history_reset :: proc() {
	for s in undo_stack {snapshot_free(s)}
	for s in redo_stack {snapshot_free(s)}
	clear(&undo_stack)
	clear(&redo_stack)
	snapshot_free(last_state)
	last_state = snapshot_of(project)
}

// Call at the end of every frame. busy = a drag or widget edit is in progress.
history_commit :: proc(busy: bool) {
	if busy || same_content(last_state, snapshot_of_temp()) {
		return
	}
	append(&undo_stack, last_state)
	if len(undo_stack) > MAX_HISTORY {
		snapshot_free(undo_stack[0])
		ordered_remove(&undo_stack, 0)
	}
	for s in redo_stack {snapshot_free(s)}
	clear(&redo_stack)
	last_state = snapshot_of(project)
}

snapshot_of_temp :: proc() -> Snapshot {
	return {project.clips[:], project.track_count, project.next_group, project.program[:], project.track_flags[:]}
}

apply_snapshot :: proc(s: Snapshot) {
	clear(&project.clips)
	append(&project.clips, ..s.clips)
	clear(&project.program)
	append(&project.program, ..s.cuts)
	clear(&project.track_flags)
	append(&project.track_flags, ..s.flags)
	clear_track_selection(&project)
	clear_cut_sel()
	for &c in project.clips {
		c.selected = false
	}
	project.track_count, project.next_group = s.track_count, s.next_group
}

undo :: proc() {
	if len(undo_stack) == 0 {
		return
	}
	append(&redo_stack, last_state)
	last_state = pop(&undo_stack)
	apply_snapshot(last_state)
}

redo :: proc() {
	if len(redo_stack) == 0 {
		return
	}
	append(&undo_stack, last_state)
	last_state = pop(&redo_stack)
	apply_snapshot(last_state)
}
