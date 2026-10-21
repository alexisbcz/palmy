package main

// Undo and redo for the caption list.
//
// Snapshots, and detected rather than declared
// --------------------------------------------
// There are a dozen ways to change the captions — keys in two focus modes,
// the side panel's buttons, three kinds of waveform drag, a transcription, a
// file read in — and an undo that relied on every one of them remembering to
// record itself would be wrong the first time someone added a thirteenth.
// So nothing records itself. Once a frame, before the frame is built,
// `history_track` hashes the caption list; if it differs from the state last
// committed, the committed state becomes an undo step and the current one is
// committed. Every path is covered, including ones that do not exist yet.
//
// A snapshot is the whole list (times, text, confidence, speaker turns), the
// selection and the caret: a caption file is kilobytes, so copying it is
// cheaper than being clever, and restoring a snapshot is exactly as correct
// for a merge as for a typo. Word timings are kept by reference to an archive
// that only grows when a transcription brings new ones, so undoing past a
// transcription brings its words back too.
//
// Steps a person thinks of as one
// -------------------------------
// Typing a sentence into a caption is one step, not forty; so is holding `]`
// to walk an in point along, or dragging an edge. A change coalesces with the
// previous step when both carry the same label, the label is one of those
// continuous kinds, the same caption is selected, and it came within
// HIST_COALESCE seconds. Anything else — a split, a delete, a different
// caption — starts a new step.
//
// Labels come from `m.act_label`, which the editing paths set when they know
// what they did ("split", "nudge"), and otherwise from what changed: the
// count, the text or only the times.
//
// Restoring replaces the caption array, so undo and redo go through the same
// deferred queue as a split (see `Act`): `p.pixels` may still hold a slice of
// the old array until the frame is painted.

import "core:hash"
import "core:strings"
import "core:time"

HIST_MAX :: 200
HIST_COALESCE :: 1.5 // seconds

Snap_Seg :: struct {
	start, end: f64,
	conf:       f32,
	turn:       bool,
	text:       string, // owned
}

Snapshot :: struct {
	segs:  []Snap_Seg,
	sel:   int,
	caret: int,
	words: int, // index into History.word_sets
	label: string, // what the step *after* this state did; static or owned by `labels`
}

History :: struct {
	undo:      [dynamic]Snapshot,
	redo:      [dynamic]Snapshot,
	cur:       Snapshot,
	cur_hash:  u64,
	have:      bool,
	word_sets: [dynamic][]Word, // every distinct word list seen; owned
	word_hash: [dynamic]u64,
	last_label: string,
	last_sel:  int,
	last_at:   time.Tick,
}

@(private = "file")
segs_hash :: proc(segs: []Seg) -> u64 {
	h := u64(0xcbf29ce484222325)
	mix :: proc(h: ^u64, b: []u8) {
		h^ = hash.fnv64a(b, h^)
	}
	for s in segs {
		st, en := s.start, s.end
		mix(&h, transmute([]u8)string(seg_text(s)))
		mix(&h, (transmute([^]u8)&st)[:8])
		mix(&h, (transmute([^]u8)&en)[:8])
		t := u8(s.turn ? 1 : 0)
		mix(&h, (transmute([^]u8)&t)[:1])
		sep := u8(0x1e)
		mix(&h, (transmute([^]u8)&sep)[:1])
	}
	return h
}

@(private = "file")
words_hash :: proc(words: []Word) -> u64 {
	h := u64(len(words)) * 0x9E3779B97F4A7C15
	for w in words {
		st := w.start
		h = hash.fnv64a((transmute([^]u8)&st)[:8], h)
		h = hash.fnv64a(transmute([]u8)w.text, h)
	}
	return h
}

// words_ref finds (or archives) the current word list.
@(private = "file")
words_ref :: proc(h: ^History, words: []Word) -> int {
	wh := words_hash(words)
	for x, i in h.word_hash {
		if x == wh {
			return i
		}
	}
	copy_ := make([]Word, len(words))
	for w, i in words {
		copy_[i] = Word{start = w.start, end = w.end, text = strings.clone(w.text)}
	}
	append(&h.word_sets, copy_)
	append(&h.word_hash, wh)
	return len(h.word_sets) - 1
}

@(private = "file")
snap_take :: proc(m: ^App_State) -> Snapshot {
	out := make([]Snap_Seg, len(m.segs))
	for s, i in m.segs {
		out[i] = Snap_Seg {
			start = s.start,
			end   = s.end,
			conf  = s.conf,
			turn  = s.turn,
			text  = strings.clone(seg_text(s)),
		}
	}
	return Snapshot{segs = out, sel = m.sel, caret = m.caret, words = words_ref(&m.hist, m.words[:])}
}

@(private = "file")
snap_free :: proc(s: ^Snapshot) {
	for x in s.segs {
		delete(x.text)
	}
	delete(s.segs)
	s.segs = nil
}

// snap_restore puts a snapshot back into the model. It replaces the caption
// array, so it runs from the deferred queue only.
@(private = "file")
snap_restore :: proc(m: ^App_State, s: Snapshot) {
	for &x in m.segs {
		seg_destroy(&x)
	}
	clear(&m.segs)
	for x in s.segs {
		sg := seg_make(x.start, x.end, x.text)
		sg.conf = x.conf
		sg.turn = x.turn
		append(&m.segs, sg)
	}
	if s.words >= 0 && s.words < len(m.hist.word_sets) && words_hash(m.words[:]) != m.hist.word_hash[s.words] {
		clear(&m.words)
		for w in m.hist.word_sets[s.words] {
			append(&m.words, w) // borrowed from the archive, which outlives them
		}
	}
	m.sel = clamp(s.sel, -1, len(m.segs) - 1)
	m.caret = m.sel >= 0 ? clamp(s.caret, 0, len(m.segs[m.sel].text)) : 0
	m.dirty = true
}

// infer_label names a change nobody named, from what it did.
@(private = "file")
infer_label :: proc(before: Snapshot, after: []Seg) -> string {
	switch {
	case len(after) > len(before.segs):
		return "add a caption"
	case len(after) < len(before.segs):
		return "remove a caption"
	}
	for s, i in after {
		if seg_text(s) != before.segs[i].text {
			return "type"
		}
	}
	return "retime"
}

@(private = "file")
continuous :: proc(label: string) -> bool {
	switch label {
	case "type", "nudge", "drag", "retime", "slide":
		return true
	}
	return false
}

// history_track commits whatever changed since the last frame. Called at the
// top of every frame, after the deferred queue and before anything is drawn.
history_track :: proc(m: ^App_State) {
	h := &m.hist
	label := m.act_label
	m.act_label = ""
	now := segs_hash(m.segs[:])
	if !h.have {
		h.cur = snap_take(m)
		h.cur_hash = now
		h.have = true
		return
	}
	if now == h.cur_hash {
		// Nothing to commit; keep the committed selection current, so an
		// undo puts the caret back where it was when the step began.
		h.cur.sel, h.cur.caret = m.sel, m.caret
		return
	}
	if label == "" {
		label = infer_label(h.cur, m.segs[:])
	}
	if m.drag != .None {
		label = "drag"
	}
	since := time.duration_seconds(time.tick_since(h.last_at))
	merge := continuous(label) && label == h.last_label && m.sel == h.last_sel && since < HIST_COALESCE && len(h.undo) > 0

	next := snap_take(m)
	if merge {
		// The step already on the stack holds the state from before the
		// gesture began; this change only moves where the gesture ended.
		snap_free(&h.cur)
	} else {
		h.cur.label = label
		append(&h.undo, h.cur)
		if len(h.undo) > HIST_MAX {
			snap_free(&h.undo[0])
			ordered_remove(&h.undo, 0)
		}
		for &r in h.redo {
			snap_free(&r)
		}
		clear(&h.redo)
	}
	h.cur = next
	h.cur_hash = now
	h.last_label = label
	h.last_sel = m.sel
	h.last_at = time.tick_now()
}

// history_break ends any gesture in progress, so the next change is its own
// step however quickly it follows.
history_break :: proc(m: ^App_State) {
	m.hist.last_label = ""
}

undo_label :: proc(m: ^App_State) -> string {
	n := len(m.hist.undo)
	return n > 0 ? m.hist.undo[n - 1].label : ""
}

redo_label :: proc(m: ^App_State) -> string {
	n := len(m.hist.redo)
	return n > 0 ? m.hist.redo[n - 1].label : ""
}

// history_undo and history_redo run from the deferred queue. Each first
// commits anything not yet tracked — a word typed this frame is a step of its
// own, and undoing must take *it* back rather than the one before.
history_undo :: proc(m: ^App_State) -> (label: string, ok: bool) {
	history_track(m)
	h := &m.hist
	if len(h.undo) == 0 {
		return "", false
	}
	prev := pop(&h.undo)
	label = prev.label
	h.cur.label = label
	append(&h.redo, h.cur)
	snap_restore(m, prev)
	h.cur = prev
	h.cur_hash = segs_hash(m.segs[:])
	history_break(m)
	return label, true
}

history_redo :: proc(m: ^App_State) -> (label: string, ok: bool) {
	history_track(m)
	h := &m.hist
	if len(h.redo) == 0 {
		return "", false
	}
	next := pop(&h.redo)
	label = next.label
	h.cur.label = label
	append(&h.undo, h.cur)
	snap_restore(m, next)
	h.cur = next
	h.cur_hash = segs_hash(m.segs[:])
	history_break(m)
	return label, true
}

history_destroy :: proc(m: ^App_State) {
	h := &m.hist
	for &s in h.undo {
		snap_free(&s)
	}
	for &s in h.redo {
		snap_free(&s)
	}
	delete(h.undo)
	delete(h.redo)
	if h.have {
		snap_free(&h.cur)
	}
	for ws in h.word_sets {
		for w in ws {
			delete(w.text)
		}
		delete(ws)
	}
	delete(h.word_sets)
	delete(h.word_hash)
	h^ = {}
}
