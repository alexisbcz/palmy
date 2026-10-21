package main

// Styled runs: bold, italic, colour and size for part of one text box.
//
// THE MODEL. A text box keeps its words as one plain string, exactly as it did
// before runs existed, and `runs` lays styling over byte ranges of it:
//
//     text = "Ship it fast, then fix it"
//     runs = [{start = 8, end = 12, bold = true, color = SLOT_ACCENT}]
//
// Anything outside every run takes the box's own style — its type-scale style,
// its `bold`, `color` and `size` — so a box with no runs is the box it always
// was, renders byte for byte as before, and is saved the same way bar an empty
// `"runs": []`. The alternative, a list of (text, style) pieces, would have
// made every reader of `e.text` — wrapping, the caret, the outline, the
// command line's `text`, slide titles, search — learn to concatenate, and
// would have made "no styling" a special case instead of the empty list.
//
// The rules a run list keeps (`runs_clean` restores them after any change):
//
//   * ranges are byte offsets into `text`, half-open, inside it, non-empty;
//   * sorted, non-overlapping, and two neighbours with the same style are one;
//   * a run that changes nothing (not bold, not italic, colour 0, size 0) is
//     dropped.
//
// What a run means, field by field, against the box underneath it:
//
//   * `bold` and `italic` add: a run cannot un-bold a box whose `bold` is set
//     or whose style (Title, Metric) is bold. That is the same rule HTML's
//     <b> inside a bold heading follows, and it keeps one meaning per flag.
//   * `color` is a paint like every other (a theme slot 1..6 or a literal
//     0xAARRGGBB); 0 means the box's colour.
//   * `size` is in slide units like `Element.size`; 0 means the box's size.
//
// A run list is never mutated in place. Every change builds a new slice, the
// same way a committed string is never edited: undo snapshots copy elements
// by value (`clone_deck`), so a shared slice changed in place would rewrite
// history.

import "core:slice"

Run :: struct {
	start:  int,
	end:    int,
	bold:   bool,
	italic: bool,
	color:  u32,
	size:   f32,
}

// Run_Style is a run without its range: what a stretch of text looks like.
Run_Style :: struct {
	bold:   bool,
	italic: bool,
	color:  u32,
	size:   f32,
}

run_style :: proc(r: Run) -> Run_Style {
	return {bold = r.bold, italic = r.italic, color = r.color, size = r.size}
}

style_plain :: proc(s: Run_Style) -> bool {
	return !s.bold && !s.italic && s.color == 0 && s.size <= 0
}

// Seg is one stretch of a box's text with one style: a run, or a gap between
// runs (which has the plain style).
Seg :: struct {
	start, end: int,
	s:          Run_Style,
}

// text_segments splits [from, to) of a box's text at its run boundaries. A box
// without runs is one plain segment, which is how the renderer's fast path
// stays identical to what it was before runs existed.
text_segments :: proc(e: ^Element, from, to: int, allocator := context.temp_allocator) -> []Seg {
	out := make([dynamic]Seg, allocator)
	if from >= to {
		return out[:]
	}
	at := from
	for r in e.runs {
		if r.end <= at {
			continue
		}
		if r.start >= to {
			break
		}
		if r.start > at {
			append(&out, Seg{start = at, end = r.start})
			at = r.start
		}
		end := min(r.end, to)
		append(&out, Seg{start = at, end = end, s = run_style(r)})
		at = end
		if at >= to {
			break
		}
	}
	if at < to {
		append(&out, Seg{start = at, end = to})
	}
	return out[:]
}

// style_at is the style of the byte at `i`.
style_at :: proc(e: ^Element, i: int) -> Run_Style {
	for r in e.runs {
		if i >= r.start && i < r.end {
			return run_style(r)
		}
	}
	return {}
}

// runs_clean restores the invariants above and returns a new slice.
runs_clean :: proc(runs: []Run, text_len: int, allocator := context.allocator) -> []Run {
	tmp := make([dynamic]Run, context.temp_allocator)
	for r in runs {
		rr := r
		rr.start = clamp(rr.start, 0, text_len)
		rr.end = clamp(rr.end, 0, text_len)
		if rr.end <= rr.start || style_plain(run_style(rr)) {
			continue
		}
		append(&tmp, rr)
	}
	slice.sort_by(tmp[:], proc(a, b: Run) -> bool {return a.start < b.start})
	out := make([dynamic]Run, allocator)
	for r in tmp {
		rr := r
		if n := len(out); n > 0 {
			last := &out[n - 1]
			// An overlap is resolved in favour of the later run, which is
			// what an importer that met overlapping ranges meant last.
			if rr.start < last.end {
				last.end = rr.start
				if last.end <= last.start {
					pop(&out)
				}
			}
		}
		if n := len(out); n > 0 {
			last := &out[n - 1]
			if last.end == rr.start && run_style(last^) == run_style(rr) {
				last.end = rr.end
				continue
			}
		}
		append(&out, rr)
	}
	if len(out) == 0 {
		delete(out)
		return nil
	}
	return out[:]
}

// runs_splice moves the runs through one edit: `removed` bytes at `at` were
// replaced by `inserted` bytes. Text typed at the end of a run joins it, the
// way a word processor continues a bold word; text typed at a run's start
// does not, so typing in front of a bold word stays plain.
runs_splice :: proc(runs: []Run, at, removed, inserted: int, text_len: int, allocator := context.allocator) -> []Run {
	out := make([dynamic]Run, context.temp_allocator)
	cut_end := at + removed
	for r in runs {
		// The run that the inserted text joins: the one holding the byte
		// before the caret when this is plain typing, or the one holding the
		// first replaced byte when typing over a selection.
		inherits := removed == 0 ? (r.start < at && r.end >= at) : (r.start <= at && r.end > at)
		mp :: proc(x, at, cut_end: int) -> int {
			if x <= at {
				return x
			}
			if x >= cut_end {
				return x - (cut_end - at)
			}
			return at
		}
		rr := r
		rr.start = mp(r.start, at, cut_end)
		rr.end = mp(r.end, at, cut_end)
		if inserted > 0 {
			if inherits {
				rr.end += inserted
			} else {
				if rr.start >= at {
					rr.start += inserted
				}
				if rr.end > at {
					rr.end += inserted
				}
			}
		}
		append(&out, rr)
	}
	return runs_clean(out[:], text_len, allocator)
}

// runs_after_edit carries runs across a change from `old` to `new` by finding
// what the two have in common at each end: the one edit that explains the
// difference. It is how both the window (which edits a buffer) and the command
// line (which replaces the whole text) keep styling on the words that stayed.
runs_after_edit :: proc(runs: []Run, old, new: string, allocator := context.allocator) -> []Run {
	if len(runs) == 0 {
		return nil
	}
	pre := 0
	for pre < len(old) && pre < len(new) && old[pre] == new[pre] {
		pre += 1
	}
	suf := 0
	for suf < len(old) - pre && suf < len(new) - pre && old[len(old) - 1 - suf] == new[len(new) - 1 - suf] {
		suf += 1
	}
	removed := len(old) - pre - suf
	inserted := len(new) - pre - suf
	if removed == 0 && inserted == 0 {
		return runs_clean(runs, len(new), allocator)
	}
	return runs_splice(runs, pre, removed, inserted, len(new), allocator)
}

// Style_Op is one change a person can make to a range.
Style_Op :: enum u8 {
	Bold, // set to `on`
	Italic, // set to `on`
	Color, // set to `color`
	Size, // set to `size`
	Plain, // clear everything
}

// runs_apply changes the style of [from, to) and returns the new run list.
runs_apply :: proc(
	runs: []Run,
	text_len: int,
	from, to: int,
	op: Style_Op,
	on := true,
	color: u32 = 0,
	size: f32 = 0,
	allocator := context.allocator,
) -> []Run {
	a := clamp(min(from, to), 0, text_len)
	b := clamp(max(from, to), 0, text_len)
	if a >= b {
		return runs_clean(runs, text_len, allocator)
	}
	// Partition the whole text into segments, change the ones inside the
	// range, and let runs_clean fold the result back into runs.
	e := Element {
		runs = runs,
	}
	bounds := make([dynamic]Run, context.temp_allocator)
	for sg in text_segments(&e, 0, text_len) {
		pieces := [3][2]int{{sg.start, min(sg.end, a)}, {max(sg.start, a), min(sg.end, b)}, {max(sg.start, b), sg.end}}
		for pc, k in pieces {
			if pc[1] <= pc[0] {
				continue
			}
			st := sg.s
			if k == 1 {
				switch op {
				case .Bold:
					st.bold = on
				case .Italic:
					st.italic = on
				case .Color:
					st.color = color
				case .Size:
					st.size = size
				case .Plain:
					st = {}
				}
			}
			append(&bounds, Run{start = pc[0], end = pc[1], bold = st.bold, italic = st.italic, color = st.color, size = st.size})
		}
	}
	return runs_clean(bounds[:], text_len, allocator)
}

// range_all reports whether every byte of [from, to) has a flag set, which is
// what decides whether Ctrl+B turns bold on or off for a selection.
range_all :: proc(e: ^Element, from, to: int, italic: bool) -> bool {
	if from >= to {
		return false
	}
	for sg in text_segments(e, from, to) {
		v := italic ? sg.s.italic : sg.s.bold
		if !v {
			return false
		}
	}
	return true
}
