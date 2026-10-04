// Undo and redo.
//
// The unit of history is a whole-document snapshot. A document of a few
// hundred paragraphs is a few tens of kilobytes, so cloning one costs less
// than a frame of layout — and a snapshot cannot drift out of sync with the
// model the way an inverse-operation log can when runs split and coalesce
// underneath it.
//
// What matters for feel is *coalescing*: a burst of typing is one undo step,
// not one step per character. `history_begin` is handed the kind of edit about
// to happen and only pushes a new snapshot when the kind changes, so the group
// stays open across a word. Moving the caret, applying a style, or typing a
// space closes the group.
package main

Edit_Kind :: enum u8 {
	None,
	Typing,
	Deleting,
	Structural, // never coalesces: paste, style change, paragraph change
}

Snapshot :: struct {
	doc:    Doc,
	caret:  Pos,
	anchor: Pos,
}

History :: struct {
	undo:  [dynamic]Snapshot,
	redo:  [dynamic]Snapshot,
	open:  Edit_Kind, // the kind the newest undo entry is still absorbing
	limit: int,
}

history_init :: proc(h: ^History, limit := 200) {
	h.undo = make([dynamic]Snapshot, 0, 32)
	h.redo = make([dynamic]Snapshot, 0, 32)
	h.limit = limit
	h.open = .None
}

snapshot_destroy :: proc(s: ^Snapshot) {
	doc_destroy(&s.doc)
}

history_clear :: proc(h: ^History) {
	for &s in h.undo {
		snapshot_destroy(&s)
	}
	for &s in h.redo {
		snapshot_destroy(&s)
	}
	clear(&h.undo)
	clear(&h.redo)
	h.open = .None
}

history_destroy :: proc(h: ^History) {
	history_clear(h)
	delete(h.undo)
	delete(h.redo)
	h^ = {}
}

// history_begin is called immediately *before* an edit, with the state the
// edit is about to change.
history_begin :: proc(h: ^History, d: ^Doc, caret, anchor: Pos, kind: Edit_Kind) {
	if kind != .Structural && kind == h.open && len(h.undo) > 0 {
		// Same kind as the open group: fold into it.
		return
	}
	for &s in h.redo {
		snapshot_destroy(&s)
	}
	clear(&h.redo)

	append(&h.undo, Snapshot{doc = doc_clone(d), caret = caret, anchor = anchor})
	h.open = kind

	if len(h.undo) > h.limit {
		snapshot_destroy(&h.undo[0])
		ordered_remove(&h.undo, 0)
	}
}

// history_break closes the open group, so the next edit starts a new one.
history_break :: proc(h: ^History) {
	h.open = .None
}

history_can_undo :: proc(h: ^History) -> bool {return len(h.undo) > 0}
history_can_redo :: proc(h: ^History) -> bool {return len(h.redo) > 0}

// history_undo swaps the live document for the newest snapshot and files the
// live one under redo. Ownership moves; nothing is cloned.
history_undo :: proc(h: ^History, d: ^Doc, caret, anchor: ^Pos) -> bool {
	if len(h.undo) == 0 {
		return false
	}
	append(&h.redo, Snapshot{doc = d^, caret = caret^, anchor = anchor^})
	s := pop(&h.undo)
	d^ = s.doc
	caret^ = s.caret
	anchor^ = s.anchor
	h.open = .None
	return true
}

history_redo :: proc(h: ^History, d: ^Doc, caret, anchor: ^Pos) -> bool {
	if len(h.redo) == 0 {
		return false
	}
	append(&h.undo, Snapshot{doc = d^, caret = caret^, anchor = anchor^})
	s := pop(&h.redo)
	d^ = s.doc
	caret^ = s.caret
	anchor^ = s.anchor
	h.open = .None
	return true
}
