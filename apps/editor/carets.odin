// Multiple cursors.
//
// This is the feature that is easiest to half-finish, because it touches every
// edit path: anything that was "do it at the caret" has to become "do it at
// each caret", and anything that assumed one selection has to stop assuming
// that. Two things are what make the difference between a real implementation
// and a demo:
//
//   **Edits are applied from the bottom up.** An edit at line 40 cannot move
//   anything at line 10, so walking the carets in descending order means every
//   caret's recorded position is still valid when its turn comes. Walking them
//   the other way would need every later caret rewritten after every edit, and
//   that is where off-by-ones live.
//
//   **One keystroke is one undo step.** Five carets typing a character is five
//   replacements in five places; if undo took them back one at a time, five
//   Ctrl-Z to unto one character, multiple cursors would be a liability. So
//   the edits share a group id and `buf_undo` pops the whole group (see
//   buffer.odin).
//
// The primary caret is `ed.cur` / `ed.anchor`; `ed.extra` holds the rest. They
// are gathered into one sorted list for anything that acts on all of them and
// written back afterwards, with overlapping carets merged — two carets that
// have walked into the same place are one caret, and letting them both survive
// means every subsequent keystroke is applied twice.
package main

import "core:slice"
import "core:strings"

Caret :: struct {
	cur:     Pos,
	anchor:  Pos,
	has_sel: bool,
	goal:    int,
}

MAX_CARETS :: 2000

// ---------------------------------------------------------------------------
// Gathering and scattering
// ---------------------------------------------------------------------------

caret_primary :: proc(ed: ^Editor) -> Caret {
	return {ed.cur, ed.anchor, ed.has_sel && !pos_eq(ed.anchor, ed.cur), ed.goal}
}

carets_multi :: proc(ed: ^Editor) -> bool {
	return len(ed.extra) > 0
}

carets_count :: proc(ed: ^Editor) -> int {
	return 1 + len(ed.extra)
}

// carets_gather returns every caret in document order.
carets_gather :: proc(ed: ^Editor, allocator := context.temp_allocator) -> []Caret {
	out := make([dynamic]Caret, 0, carets_count(ed), allocator)
	append(&out, caret_primary(ed))
	for c in ed.extra {
		append(&out, c)
	}
	slice.sort_by(out[:], proc(a, b: Caret) -> bool {
		return pos_less(a.cur, b.cur)
	})
	return out[:]
}

// carets_store writes a list back, dropping duplicates. Two carets in one
// place are one caret: if both survived, the next keystroke would be applied
// twice there and the text would quietly be wrong.
carets_store :: proc(ed: ^Editor, list: []Caret) {
	if len(list) == 0 {
		return
	}
	// Sort first, then drop adjacent duplicates. Comparing every caret with
	// every other one is fine for three and quadratic for two thousand, which
	// `Add Cursor at Every Match` can genuinely produce.
	sorted := make([dynamic]Caret, 0, len(list), context.temp_allocator)
	append(&sorted, ..list)
	slice.sort_by(sorted[:], proc(a, b: Caret) -> bool {
		return pos_less(a.cur, b.cur)
	})
	kept := make([dynamic]Caret, 0, len(sorted), context.temp_allocator)
	for c in sorted {
		if len(kept) > 0 && pos_eq(kept[len(kept) - 1].cur, c.cur) {
			continue
		}
		append(&kept, c)
	}

	first := kept[0]
	ed.cur = pos_clamp(&ed.buf, first.cur)
	ed.anchor = pos_clamp(&ed.buf, first.anchor)
	ed.has_sel = first.has_sel && !pos_eq(ed.anchor, ed.cur)
	ed.goal = first.goal

	clear(&ed.extra)
	for i in 1 ..< min(len(kept), MAX_CARETS) {
		c := kept[i]
		c.cur = pos_clamp(&ed.buf, c.cur)
		c.anchor = pos_clamp(&ed.buf, c.anchor)
		c.has_sel = c.has_sel && !pos_eq(c.anchor, c.cur)
		append(&ed.extra, c)
	}
}

// carets_collapse drops every caret but the primary. Escape does this, and so
// does anything that cannot sensibly be done many times at once.
carets_collapse :: proc(ed: ^Editor) {
	ed.type_run = 0
	if len(ed.extra) == 0 {
		return
	}
	clear(&ed.extra)
	note(ed, "One cursor")
}

// ---------------------------------------------------------------------------
// Adding carets
// ---------------------------------------------------------------------------

// caret_add_vert puts a new caret one visual row above the topmost caret or
// below the bottommost, at the same goal column — the column gesture.
caret_add_vert :: proc(ed: ^Editor, d: int) {
	ed.type_run = 0
	list := carets_gather(ed)
	edge := d > 0 ? list[len(list) - 1] : list[0]
	sub, _ := caret_vis(ed, edge.cur)
	nl, ns, ok := vis_step(ed, edge.cur.line, sub, d)
	if !ok {
		note(ed, d > 0 ? "No line below" : "No line above")
		return
	}
	at := col_at(ed, nl, ns, edge.goal)
	add := make([dynamic]Caret, 0, len(list) + 1, context.temp_allocator)
	for c in list {
		append(&add, c)
	}
	append(&add, Caret{at, at, false, edge.goal})
	carets_store(ed, add[:])
	ensure_caret_visible(ed, at)
	note(ed, tfmt("%d cursors", carets_count(ed)))
}

// caret_word_under is the selection, or the word the caret is sitting in when
// there is no selection — what "the next one of these" means.
// `whole` says the text came from a word under the caret rather than from an
// explicit selection, and therefore that only whole words should match: asking
// to rename `ctx` must not put a caret inside `context`.
caret_word_under :: proc(
	ed: ^Editor,
) -> (
	text: string,
	from, to: Pos,
	whole: bool,
	ok: bool,
) {
	if lo, hi, has := sel_range(ed); has {
		if lo.line != hi.line {
			return "", {}, {}, false, false // a multi-line selection is not a word
		}
		sel := buf_text(&ed.buf, lo, hi, context.temp_allocator)
		// A selection that is itself exactly a word keeps the word rule; one
		// that is a fragment is matched literally, because a fragment is what
		// was asked for.
		return sel, lo, hi, is_word_run(sel) && word_bounded(&ed.buf, lo, hi), true
	}
	l := buf_line(&ed.buf, ed.cur.line)
	if len(l) == 0 {
		return "", {}, {}, false, false
	}
	i := min(ed.cur.col, len(l) - 1)
	if class_of(l[i]) != .Word && i > 0 && class_of(l[i - 1]) == .Word {
		i -= 1
	}
	if class_of(l[i]) != .Word {
		return "", {}, {}, false, false
	}
	a := i
	for a > 0 && class_of(l[a - 1]) == .Word {
		a -= 1
	}
	b := i
	for b < len(l) && class_of(l[b]) == .Word {
		b += 1
	}
	return l[a:b], {ed.cur.line, a}, {ed.cur.line, b}, true, true
}

is_word_run :: proc(s: string) -> bool {
	if s == "" {
		return false
	}
	for i in 0 ..< len(s) {
		if class_of(s[i]) != .Word {
			return false
		}
	}
	return true
}

// word_bounded reports whether a range has a non-word character (or nothing)
// on both sides, which is what "a whole word" means.
word_bounded :: proc(b: ^Buffer, lo, hi: Pos) -> bool {
	l := buf_line(b, lo.line)
	if lo.col > 0 && class_of(l[lo.col - 1]) == .Word {
		return false
	}
	r := buf_line(b, hi.line)
	if hi.col < len(r) && class_of(r[hi.col]) == .Word {
		return false
	}
	return true
}

// search_word is buf_search with the whole-word rule applied, walking on past
// any match that turns out to be part of a longer word.
search_word :: proc(
	b: ^Buffer,
	needle: string,
	from: Pos,
	whole: bool,
) -> (
	at: Pos,
	ok: bool,
) {
	start := from
	for _ in 0 ..< 10000 {
		found, good := buf_search(b, needle, start, false)
		if !good {
			return {}, false
		}
		end := Pos{found.line, found.col + len(needle)}
		if !whole || word_bounded(b, found, end) {
			return found, true
		}
		if !pos_less(start, end) {
			return {}, false
		}
		start = end
	}
	return {}, false
}

// caret_add_next selects the word under the caret the first time, and each
// following occurrence of it after that. This is the gesture multiple cursors
// are actually used for: rename this, three times, without a regex.
caret_add_next :: proc(ed: ^Editor) {
	ed.type_run = 0
	word, from, to, whole, ok := caret_word_under(ed)
	if !ok || word == "" {
		note(ed, "Nothing under the cursor to match")
		return
	}
	// First press only selects what is under the caret.
	if _, _, has := sel_range(ed); !has {
		ed.anchor = from
		ed.cur = to
		ed.has_sel = true
		goal_set(ed)
		ensure_visible(ed)
		note(ed, tfmt("Selected \"%s\"", word))
		return
	}

	list := carets_gather(ed)
	last := list[len(list) - 1]
	search_from := last.cur
	// Case-sensitive: adding a caret at `Foo` when you asked for `foo` would
	// rename the wrong thing.
	at, found := search_word(&ed.buf, word, search_from, whole)
	if !found {
		note(ed, tfmt("No more \"%s\"", word))
		return
	}
	end := Pos{at.line, at.col + len(word)}
	for c in list {
		if pos_eq(c.cur, end) {
			note(ed, tfmt("Every \"%s\" is selected", word))
			return
		}
	}
	add := make([dynamic]Caret, 0, len(list) + 1, context.temp_allocator)
	for c in list {
		append(&add, c)
	}
	append(&add, Caret{end, at, true, disp_of(buf_line(&ed.buf, end.line), end.col)})
	carets_store(ed, add[:])
	ensure_caret_visible(ed, end)
	note(ed, tfmt("%d cursors on \"%s\"", carets_count(ed), word))
}

// caret_add_all puts a caret on every occurrence in the file at once.
caret_add_all :: proc(ed: ^Editor) {
	ed.type_run = 0
	word, from, to, whole, ok := caret_word_under(ed)
	if !ok || word == "" {
		note(ed, "Nothing under the cursor to match")
		return
	}
	_ = from
	_ = to
	list := make([dynamic]Caret, 0, 32, context.temp_allocator)
	at := Pos{0, 0}
	for {
		found, good := search_word(&ed.buf, word, at, whole)
		if !good || (len(list) > 0 && !pos_less(list[len(list) - 1].cur, found)) {
			break
		}
		end := Pos{found.line, found.col + len(word)}
		append(
			&list,
			Caret{end, found, true, disp_of(buf_line(&ed.buf, end.line), end.col)},
		)
		at = end
		if len(list) >= MAX_CARETS {
			break
		}
	}
	if len(list) == 0 {
		note(ed, tfmt("No \"%s\" anywhere", word))
		return
	}
	carets_store(ed, list[:])
	ensure_visible(ed)
	note(ed, tfmt("%d cursors on \"%s\"", carets_count(ed), word))
}

// ensure_caret_visible scrolls to a particular caret without moving the
// primary one, which is what adding a caret off the bottom of the window needs.
ensure_caret_visible :: proc(ed: ^Editor, at: Pos) {
	save := ed.cur
	ed.cur = at
	ensure_visible(ed)
	ed.cur = pos_clamp(&ed.buf, save)
}

// ---------------------------------------------------------------------------
// Moving them all
// ---------------------------------------------------------------------------

Caret_Motion :: enum {
	Left,
	Right,
	Up,
	Down,
	Home,
	End,
	Word_Left,
	Word_Right,
}

carets_move :: proc(ed: ^Editor, m: Caret_Motion, shift: bool) {
	ed.type_run = 0 // moving ends the run of typing
	list := carets_gather(ed)
	out := make([dynamic]Caret, 0, len(list), context.temp_allocator)
	for c in list {
		n := c
		if shift && !n.has_sel {
			n.anchor = n.cur
			n.has_sel = true
		}
		if !shift {
			n.has_sel = false
		}
		vertical := false
		switch m {
		case .Left:
			l := buf_line(&ed.buf, n.cur.line)
			if n.cur.col > 0 {
				n.cur.col = rune_left(l, n.cur.col)
			} else if n.cur.line > 0 {
				n.cur = {n.cur.line - 1, len(buf_line(&ed.buf, n.cur.line - 1))}
			}
		case .Right:
			l := buf_line(&ed.buf, n.cur.line)
			if n.cur.col < len(l) {
				n.cur.col = rune_right(l, n.cur.col)
			} else if n.cur.line + 1 < buf_lines(&ed.buf) {
				n.cur = {n.cur.line + 1, 0}
			}
		case .Word_Left:
			n.cur = word_left(&ed.buf, n.cur)
		case .Word_Right:
			n.cur = word_right(&ed.buf, n.cur)
		case .Up, .Down:
			vertical = true
			sub, _ := caret_vis(ed, n.cur)
			nl, ns := vis_advance(ed, n.cur.line, sub, m == .Down ? 1 : -1)
			n.cur = col_at(ed, nl, ns, n.goal)
		case .Home:
			sub, _ := caret_vis(ed, n.cur)
			if ed.wrap && sub > 0 {
				n.cur = col_at(ed, n.cur.line, sub, 0)
			} else {
				l := buf_line(&ed.buf, n.cur.line)
				i := 0
				for i < len(l) && (l[i] == ' ' || l[i] == '\t') {
					i += 1
				}
				n.cur.col = n.cur.col == i ? 0 : i
			}
		case .End:
			sub, _ := caret_vis(ed, n.cur)
			if ed.wrap {
				n.cur = col_at(ed, n.cur.line, sub, max(int))
			} else {
				n.cur.col = len(buf_line(&ed.buf, n.cur.line))
			}
		}
		n.cur = pos_clamp(&ed.buf, n.cur)
		if !vertical {
			_, dx := caret_vis(ed, n.cur)
			n.goal = dx
		}
		if !shift {
			n.anchor = n.cur
		}
		append(&out, n)
	}
	carets_store(ed, out[:])
	ensure_visible(ed)
}

// ---------------------------------------------------------------------------
// Editing at all of them
// ---------------------------------------------------------------------------

Multi_Op :: enum {
	Insert,
	Backspace,
	Delete,
	Newline,
	Tab,
}

// carets_edit does one keystroke at every caret, as one undo step.
//
// Two things have to be right at once, and they pull in opposite directions:
//
//   - An edit must be *applied* with the positions the caret had before
//     anything moved, which means working from the bottom up: an edit at line
//     40 cannot disturb a caret at line 10, so by the time line 10's turn
//     comes its recorded position is still valid.
//
//   - But a caret's *resulting* position is recorded in the buffer as it was
//     when its own edit ran, and every edit applied afterwards is before it.
//     So after each edit, the carets further down are shifted by what it
//     changed. Three carets on one line typing one character each is where
//     this is visible: without the shift they end up one, two and three
//     characters short.
carets_edit :: proc(ed: ^Editor, op: Multi_Op, text := "") {
	list := carets_gather(ed)
	// A run of typing is one undo step, the same way it is with one caret.
	// Without this, renaming twelve occurrences and pressing Ctrl-Z takes back
	// one letter in twelve places, which looks like a bug and is one.
	// `type_run` is dropped by anything that is not more typing.
	g := ed.type_run
	// A group id belongs to a buffer, and a buffer that has been reloaded
	// hands out the same ids again. An id from before that would silently
	// merge this keystroke into somebody else's undo step, so an id the
	// current buffer has not issued is not a group.
	if g > ed.buf.group_seq {
		g = 0
	}
	if op != .Insert || g == 0 {
		g = buf_group(&ed.buf)
	}
	ed.type_run = op == .Insert ? g : 0
	for i := len(list) - 1; i >= 0; i -= 1 {
		old_end, new_end := caret_do(ed, &list[i], op, text, g)
		if pos_eq(old_end, new_end) {
			continue
		}
		for j in i + 1 ..< len(list) {
			list[j].cur = pos_shift(list[j].cur, old_end, new_end)
			list[j].anchor = pos_shift(list[j].anchor, old_end, new_end)
		}
	}
	carets_store(ed, list[:])
	ensure_visible(ed)
}

// pos_shift moves a position that sits after a replacement by what the
// replacement changed. Everything on the line the replacement ended on slides
// along it; everything below slides by the change in line count.
pos_shift :: proc(q, old_end, new_end: Pos) -> Pos {
	if pos_less(q, old_end) {
		return q
	}
	if q.line == old_end.line {
		return {new_end.line, new_end.col + (q.col - old_end.col)}
	}
	return {q.line + (new_end.line - old_end.line), q.col}
}

// caret_do performs one caret's share of a keystroke as a single replacement,
// and returns where the replaced region ended before and after, which is what
// the carets below it need to be shifted by.
@(private = "file")
caret_do :: proc(
	ed: ^Editor,
	c: ^Caret,
	op: Multi_Op,
	text: string,
	g: int,
) -> (
	old_end, new_end: Pos,
) {
	b := &ed.buf
	lo, hi := c.cur, c.cur
	if c.has_sel && !pos_eq(c.anchor, c.cur) {
		lo, hi = pos_order(c.anchor, c.cur)
	}
	had_sel := !pos_eq(lo, hi)
	ins := ""
	coalesce := Coalesce.No

	switch op {
	case .Insert:
		ins = text
		if !had_sel {
			coalesce = .Type
		}
	case .Tab:
		ins = "\t"
		if !had_sel {
			coalesce = .Type
		}
	case .Newline:
		// The indent comes from the head of the line the replacement starts
		// on, which survives the replacement whatever it removed.
		l := buf_line(b, lo.line)
		i := 0
		for i < min(len(l), lo.col) && (l[i] == ' ' || l[i] == '\t') {
			i += 1
		}
		ins = tfmt("\n%s", l[:i])
	case .Backspace:
		if !had_sel {
			if lo.col > 0 {
				lo.col = rune_left(buf_line(b, lo.line), lo.col)
			} else if lo.line > 0 {
				lo = {lo.line - 1, len(buf_line(b, lo.line - 1))}
			}
			coalesce = .Back
		}
	case .Delete:
		if !had_sel {
			l := buf_line(b, hi.line)
			if hi.col < len(l) {
				hi.col = rune_right(l, hi.col)
			} else if hi.line + 1 < buf_lines(b) {
				hi = {hi.line + 1, 0}
			}
		}
	}

	lo, hi = pos_clamp(b, lo), pos_clamp(b, hi)
	end := buf_apply(b, lo, hi, ins, c.cur, coalesce, g)
	c.cur = pos_clamp(b, end)
	c.anchor = c.cur
	c.has_sel = false
	if ed.wrap {
		_, dx := caret_vis(ed, c.cur)
		c.goal = dx
	} else {
		c.goal = disp_of(buf_line(b, c.cur.line), c.cur.col)
	}
	return hi, end
}

// carets_text is what the clipboard gets when several carets are selecting:
// one line per caret, in document order, which is what pasting it back into
// the same carets would need.
carets_text :: proc(ed: ^Editor, allocator := context.temp_allocator) -> string {
	sb := strings.builder_make(allocator)
	for c, i in carets_gather(ed) {
		if i > 0 {
			strings.write_byte(&sb, '\n')
		}
		if c.has_sel {
			lo, hi := pos_order(c.anchor, c.cur)
			strings.write_string(&sb, buf_text(&ed.buf, lo, hi, context.temp_allocator))
		} else {
			strings.write_string(&sb, buf_line(&ed.buf, c.cur.line))
		}
	}
	return strings.to_string(sb)
}
