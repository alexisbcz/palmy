package main

// Undo.
//
// The representation is the whole document as a string
// -----------------------------------------------------
// An undo entry is exactly what `project_serialise` writes to a .vep file.
// Nothing is diffed, nothing is inverted, and there is no per-operation undo
// code at all — which means undoing a ripple delete that moved nine clips is
// precisely as correct as undoing a one-pixel nudge, and a new edit added to
// input.odin cannot forget to be undoable in some corner.
//
// It is cheap because a Project is three flat arrays. The spreadsheet in this
// repo reached the same conclusion for the same reason and the word processor
// measured a 400-paragraph clone at ~0.05 ms; the measured cost here is
// printed by `--undobench` and is of that order for a real timeline. If a
// timeline ever grows big enough for that to hurt, the number to look at is in
// the status bar, not in a guess.
//
// It cannot drift, which is the real argument. `track.clips` is re-sorted after
// every mutation and clip ids are handed out from a counter, so a hand-written
// inverse of "move" would have to reason about an ordering that the model is
// free to change underneath it. A snapshot has no opinion about ordering.
//
// Three things the serialisation does not carry, and this file does
// ------------------------------------------------------------------
//  1. **The selection**, stored as (track, index) rather than a clip id,
//     because `project_parse` hands out fresh ids. The index is unambiguous:
//     the file lists a track's clips in sorted order and the parse re-sorts to
//     the same order, so index *n* is the same clip it was.
//  2. **The playhead and the scroll.** An undo that leaves you looking
//     somewhere else in the timeline is disorienting, so the view goes back
//     too. The playhead and zoom ride along inside the serialisation's `view`
//     line; the scroll is kept here.
//  3. **The media bin.** `project_parse` is told to keep rows the snapshot
//     does not mention — an import is a resource arriving, not an edit, and
//     undoing a split must not empty the bin.
//
// Coalescing
// ----------
// A drag fires `move_clip` on every mouse-move frame, which would be sixty
// undo steps for one gesture. `undo_mark` therefore folds a mark into the
// previous one when the kind, the clip it touches and a short time window all
// match, and `undo_break` ends the run — the mouse release calls it, so a
// second drag of the same clip is a second undo step however quickly it
// follows.

import "core:fmt"
import "core:time"

// Undo_Kind is only ever compared for equality, to decide whether two marks
// belong to the same gesture. It is not a description of how to undo anything.
Undo_Kind :: enum u8 {
	None,
	Place,
	Split,
	Ripple,
	Lift,
	Trim_In,
	Trim_Out,
	Move,
	Retrack,
	Dissolve,
	Gain,
	Title_Add,
	Title_Text,
	Title_Style,
	Track_Flags,
	Captions,
	Caption_Nudge,
	Load,
}

UNDO_MAX :: 200
UNDO_COALESCE :: 0.7 // seconds a gesture may pause and still be one step

Snapshot :: struct {
	text:      string, // the whole document, owned
	label:     string, // what the edit was; always a literal, never owned
	kind:      Undo_Kind,
	tag:       int, // the clip or track the edit touched, for coalescing
	sel_track: int,
	sel_idx:   int,
	cur_track: int,
	scroll:    f64,
}

History :: struct {
	undo:      [dynamic]Snapshot,
	redo:      [dynamic]Snapshot,

	// The open gesture, for coalescing.
	last_kind: Undo_Kind,
	last_tag:  int,
	last_at:   time.Time,
	open:      bool,

	// Instrumentation, printed in the status bar so the cost of the cheap
	// correct choice is on screen rather than asserted in a comment.
	marks:     int,
	mark_ms:   f64, // total time spent taking snapshots
	last_ms:   f64,
	bytes:     int, // snapshot bytes currently held
	peak_bytes: int,
}

history_destroy :: proc(h: ^History) {
	for s in h.undo {
		delete(s.text)
	}
	for s in h.redo {
		delete(s.text)
	}
	delete(h.undo)
	delete(h.redo)
	h^ = {}
}

// ---------------------------------------------------------------------------
// Taking and restoring
// ---------------------------------------------------------------------------

@(private = "file")
snapshot_take :: proc(ed: ^Editor, kind: Undo_Kind, label: string, tag: int) -> Snapshot {
	st, si := -1, -1
	if ed.sel >= 0 {
		st, si = find_clip(&ed.pr, ed.sel)
	}
	t0 := time.now()
	text := project_serialise(&ed.pr, ed.playhead, ed.zoom)
	ms := time.duration_milliseconds(time.since(t0))
	ed.hist.marks += 1
	ed.hist.mark_ms += ms
	ed.hist.last_ms = ms
	ed.hist.bytes += len(text)
	ed.hist.peak_bytes = max(ed.hist.peak_bytes, ed.hist.bytes)
	return Snapshot {
		text = text,
		label = label,
		kind = kind,
		tag = tag,
		sel_track = st,
		sel_idx = si,
		cur_track = ed.cur_track,
		scroll = ed.scroll,
	}
}

@(private = "file")
snapshot_free :: proc(ed: ^Editor, s: Snapshot) {
	ed.hist.bytes -= len(s.text)
	delete(s.text)
}

@(private = "file")
snapshot_restore :: proc(ed: ^Editor, s: Snapshot) {
	res := project_parse(&ed.pr, s.text, true)
	if res.ok {
		ed.playhead = res.playhead
		ed.zoom = res.zoom
	}
	ed.scroll = s.scroll
	ed.cur_track = clamp(s.cur_track, 0, max(0, len(ed.pr.tracks) - 1))

	// The ids are new, so the selection comes back by position.
	ed.sel = -1
	if s.sel_track >= 0 && s.sel_track < len(ed.pr.tracks) {
		t := &ed.pr.tracks[s.sel_track]
		if s.sel_idx >= 0 && s.sel_idx < len(t.clips) {
			ed.sel = t.clips[s.sel_idx].id
		}
	}

	// A drag in flight holds a clip id that no longer exists, and the title
	// buffer may now belong to a different clip.
	ed.drag = .None
	ed.drag_id = 0
	ed.snap_show = false
	ed.title_buf_for = -1
	// Every cached preview frame may be at the wrong timeline position now,
	// and the audio mix has changed under the playhead.
	ed.last_edit += 1
	ed.mix_dirty = true
	ed.seek_req = true
}

// ---------------------------------------------------------------------------
// The public operations
// ---------------------------------------------------------------------------

// undo_mark records the state *before* an edit. Every mutating path calls it
// first; that ordering is the whole contract, and it is what the self-test
// walks over a random sequence of edits.
//
// `label` must be a string literal: it is stored, never freed, and read back
// to tell the user what will be undone.
//
// It returns whether a *new* step went on the stack, which is the only safe
// licence to call `undo_drop`. An edit that marks and then discovers it had
// nothing to do — a trim already against the end of its source, a split with
// no clip under the playhead — must not leave a step that undoes to the state
// it was already in; but if the mark was folded into a gesture already in
// progress, the step on top belongs to that gesture and dropping it would
// throw away the drag.
undo_mark :: proc(ed: ^Editor, kind: Undo_Kind, label: string, tag := -1) -> (fresh: bool) {
	h := &ed.hist
	if h.open &&
	   h.last_kind == kind &&
	   h.last_tag == tag &&
	   time.duration_seconds(time.since(h.last_at)) < UNDO_COALESCE {
		// Same gesture, still running: the entry already on the stack holds
		// the state this gesture started from, which is where undo must land.
		h.last_at = time.now()
		return false
	}
	undo_clear_redo(ed)
	append(&h.undo, snapshot_take(ed, kind, label, tag))
	if len(h.undo) > UNDO_MAX {
		snapshot_free(ed, h.undo[0])
		ordered_remove(&h.undo, 0)
	}
	h.last_kind, h.last_tag, h.last_at, h.open = kind, tag, time.now(), true
	return true
}

// undo_drop throws away the step just marked. It is for the edits that ask
// first and find there is nothing to do — a split with no clip under the
// playhead, a caption file that would not parse — because a step that undoes
// to the state it was already in is worse than no step at all: the user presses
// Ctrl-Z, nothing visibly happens, and they press it again.
undo_drop :: proc(ed: ^Editor) {
	h := &ed.hist
	if len(h.undo) == 0 {
		return
	}
	snapshot_free(ed, h.undo[len(h.undo) - 1])
	pop(&h.undo)
	undo_break(ed)
}

// undo_break ends the open gesture, so the next mark starts a new step. The
// mouse release calls it, and so does anything that changes what is being
// edited.
undo_break :: proc(ed: ^Editor) {
	ed.hist.open = false
	ed.hist.last_kind = .None
}

undo_clear_redo :: proc(ed: ^Editor) {
	for s in ed.hist.redo {
		snapshot_free(ed, s)
	}
	clear(&ed.hist.redo)
}

// undo_reset throws the history away, which is right after a project load or
// the first-run auto layout: neither is an edit the user made, and there is
// nothing sensible to go back to behind them.
undo_reset :: proc(ed: ^Editor) {
	for s in ed.hist.undo {
		snapshot_free(ed, s)
	}
	clear(&ed.hist.undo)
	undo_clear_redo(ed)
	undo_break(ed)
}

// undo_apply steps back one edit and returns what it undid.
//
// The symmetry is what makes redo free: the entry popped off `undo` is the
// state to go back to, and the state being left behind is pushed onto `redo`
// carrying the same label — so "Undo: move clip" becomes "Redo: move clip"
// and both name the edit rather than the state.
undo_apply :: proc(ed: ^Editor) -> (label: string, ok: bool) {
	h := &ed.hist
	if len(h.undo) == 0 {
		return "", false
	}
	e := pop(&h.undo)
	append(&h.redo, snapshot_take(ed, e.kind, e.label, e.tag))
	snapshot_restore(ed, e)
	label = e.label // a literal, so it outlives the text
	snapshot_free(ed, e)
	undo_break(ed)
	return label, true
}

redo_apply :: proc(ed: ^Editor) -> (label: string, ok: bool) {
	h := &ed.hist
	if len(h.redo) == 0 {
		return "", false
	}
	e := pop(&h.redo)
	append(&h.undo, snapshot_take(ed, e.kind, e.label, e.tag))
	snapshot_restore(ed, e)
	label = e.label
	snapshot_free(ed, e)
	undo_break(ed)
	return label, true
}

// undo_label and redo_label are what the toolbar shows. An editor that offers
// a greyed-out "Undo" without saying what it would undo is asking the user to
// remember; these make the next step visible.
undo_label :: proc(ed: ^Editor) -> string {
	if len(ed.hist.undo) == 0 {
		return ""
	}
	return ed.hist.undo[len(ed.hist.undo) - 1].label
}

redo_label :: proc(ed: ^Editor) -> string {
	if len(ed.hist.redo) == 0 {
		return ""
	}
	return ed.hist.redo[len(ed.hist.redo) - 1].label
}

undo_depth :: proc(ed: ^Editor) -> (undo: int, redo: int) {
	return len(ed.hist.undo), len(ed.hist.redo)
}

// undo_summary is the line the status bar shows. It leads with *what* would be
// undone, because an editor that offers Ctrl-Z without saying what it would
// take back is asking the user to remember; the depth and the cost follow,
// because the cost of the cheap-and-correct representation should be on screen
// rather than asserted in a comment.
undo_summary :: proc(ed: ^Editor, alloc := context.temp_allocator) -> string {
	h := &ed.hist
	avg := h.marks > 0 ? h.mark_ms / f64(h.marks) : 0
	ul := undo_label(ed)
	rl := redo_label(ed)
	return fmt.aprintf(
		"undo: %s (%d)  ·  redo: %s (%d)  ·  %.0f KB @ %.2f ms",
		ul == "" ? "—" : ul,
		len(h.undo),
		rl == "" ? "—" : rl,
		len(h.redo),
		f64(h.bytes) / 1024,
		avg,
		allocator = alloc,
	)
}

// ---------------------------------------------------------------------------
// The check that matters
// ---------------------------------------------------------------------------

// undo_roundtrip_check is the assertion the self-test runs over a long random
// sequence of edits: after an undo and a redo, the project must serialise to
// the *same bytes* it did before. Not the same fields, the same bytes — that
// catches a restore that quietly dropped a caption's nudge or re-ordered a
// track as well as one that lost a clip.
//
// It lives here rather than in selftest.odin because it is the definition of
// what this file promises.
undo_roundtrip_check :: proc(ed: ^Editor) -> (ok: bool, detail: string) {
	before := project_serialise(&ed.pr, ed.playhead, ed.zoom, context.temp_allocator)
	// The selection is compared by position, not by id: `project_parse` hands
	// out fresh ids, so the number is expected to change while the clip it
	// points at is not.
	st0, si0 := -1, -1
	if ed.sel >= 0 {
		st0, si0 = find_clip(&ed.pr, ed.sel)
	}
	if _, uok := undo_apply(ed); !uok {
		return true, "" // nothing to undo is not a failure
	}
	undone := project_serialise(&ed.pr, ed.playhead, ed.zoom, context.temp_allocator)
	if _, rok := redo_apply(ed); !rok {
		return false, "redo was not available after an undo"
	}
	after := project_serialise(&ed.pr, ed.playhead, ed.zoom, context.temp_allocator)
	if after != before {
		return false, fmt.tprintf(
			"undo+redo changed the project: %d bytes became %d",
			len(before),
			len(after),
		)
	}
	if undone == before {
		// The undo was a no-op, which means an edit went unrecorded.
		return false, "undo did not change anything"
	}
	// The selection has to come back too, or an undo-redo pair moves the user.
	st1, si1 := -1, -1
	if ed.sel >= 0 {
		st1, si1 = find_clip(&ed.pr, ed.sel)
	}
	if st1 != st0 || si1 != si0 {
		return false, fmt.tprintf(
			"the selection moved: track %d clip %d became track %d clip %d",
			st0,
			si0,
			st1,
			si1,
		)
	}
	return true, ""
}
