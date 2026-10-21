// The editor: application state, and every command that changes it.
//
// Nothing here draws. Each command is a plain procedure over `State`, which is
// what makes the key table in keys.odin a table rather than a maze, and what
// lets the self-test drive the same commands the keyboard does.
package main

import "core:fmt"
import "core:os"
import "core:strings"
import kit "kit:."
import p "palmy:."

Mode :: enum u8 {
	Doc,
	Find,
	Prompt,
}

Prompt_Kind :: enum u8 {
	None,
	Open,
	Save_As,
	Export_Md,
	Import_Md,
	Export_Html,
	Export_Png,
	Export_Pdf,
	Export_Docx,
	Export_Odt,
	Export_Rtf,
	Import_Docx,
	Insert_Image,
	Insert_Table,
	Import_Odt,
	Import_Rtf,
	// collaboration
	Comment,
	Reply,
	Share,
	Name_Version,
}

ZOOMS := [?]f32{0.5, 0.75, 0.9, 1.0, 1.25, 1.5, 2.0}

SIZES := [?]f32{10, 12, 13, 15, 18, 24, 30, 42}

PALETTE := [?]u32 {
	0x000000,
	0xe7000b,
	0xd97706,
	0x16a34a,
	0x2563eb,
	0x7c3aed,
	0x737373,
}

State :: struct {
	fonts:      ^p.Fonts,
	doc:        Doc,
	lay:        Layout,
	hist:       History,

	// Caret and selection. `anchor` is the fixed end; `caret` is the moving
	// end, so a selection can be grown in either direction.
	caret:      Pos,
	anchor:     Pos,
	goal_x:     f32, // remembered column for Up/Down
	goal_ok:    bool,
	mark:       bool, // sticky anchor, for a keyboard without modifiers

	pending:    Char_Style, // style the next typed character takes
	pending_on: bool,

	zoom:       f32,
	zoom_i:     int,
	scroll:     f32,
	hscroll:    f32,
	view:       p.Rect, // the workspace, in window coordinates
	dirty:      bool,

	mode:       Mode,
	find:       [dynamic]u8,
	repl:       [dynamic]u8,
	find_field: int, // 0 find, 1 replace
	find_hits:  int,
	// Find depth. Both default off, which is the behaviour the find box had
	// before they existed.
	find_case:  bool, // match case
	find_word:  bool, // whole words only
	// Regular expressions. `rx` is the compiled form of `find`, rebuilt
	// whenever the term or the case flag changes; `rx_err` is what the find
	// bar shows when the pattern will not compile, because a search box that
	// silently matches nothing is a search box nobody can debug.
	find_regex: bool,
	rx:         ^Rx,
	rx_err:     string,

	prompt:     Prompt_Kind,
	prompt_buf: [dynamic]u8,

	path:       string,
	modified:   bool,
	toast:      string,
	toast_at:   f32,

	focus_doc:  bool,
	caret_on:   bool,
	last_input: f32,
	help:       bool,
	swallow:    bool,
	dragging:   bool,

	// Styled clipboard. The system selection only carries text, so a copy
	// keeps the runs here and a paste uses them when the text still matches.
	clip_doc:   Doc,
	clip_text:  string,

	// The prose checker: alerts mapped back into this model, the panel, and
	// the rules switched off for this document. See prose.odin.
	prose:      Prose,

	// Collaborative editing, when the document is shared (collab.odin).
	collab:     Collab,
}

state_init :: proc(st: ^State, fonts: ^p.Fonts) {
	st.fonts = fonts
	layout_fonts = fonts
	doc_init(&st.doc)
	history_init(&st.hist)
	st.find = make([dynamic]u8, 0, 32)
	st.repl = make([dynamic]u8, 0, 32)
	st.prompt_buf = make([dynamic]u8, 0, 128)
	st.zoom_i = 3
	st.zoom = ZOOMS[st.zoom_i]
	st.focus_doc = true
	st.caret_on = true
	st.dirty = true
	prose_init(&st.prose)
}

note :: proc(st: ^State, msg: string) {
	delete(st.toast)
	st.toast = strings.clone(msg)
	st.toast_at = 0
}

// ---------------------------------------------------------------------------
// Selection
// ---------------------------------------------------------------------------

selection :: proc(st: ^State) -> (lo, hi: Pos, has: bool) {
	lo, hi = pos_order(st.anchor, st.caret)
	return lo, hi, pos_less(lo, hi)
}

has_selection :: proc(st: ^State) -> bool {
	return pos_less(st.anchor, st.caret) || pos_less(st.caret, st.anchor)
}

selection_text :: proc(st: ^State, alloc := context.allocator) -> string {
	lo, hi, has := selection(st)
	if !has {
		return strings.clone("", alloc)
	}
	// A selection can touch a block at a single point — the caret's own block
	// when the range begins at its end — and such a block contributes nothing
	// but would contribute a stray newline, so the empty ends are trimmed.
	Piece :: struct {
		blk:  Blk,
		a, z: int,
	}
	pieces := make([dynamic]Piece, 0, 8, context.temp_allocator)
	for blk in blocks_between(&st.doc, lo, hi) {
		pa := blk_para(&st.doc, blk)
		if pa == nil || !text_kind(pa.kind) {
			continue
		}
		a, z := blk_range(&st.doc, blk, lo, hi)
		append(&pieces, Piece{blk, a, z})
	}
	for len(pieces) > 1 && pieces[0].z <= pieces[0].a {
		ordered_remove(&pieces, 0)
	}
	for len(pieces) > 1 && pieces[len(pieces) - 1].z <= pieces[len(pieces) - 1].a {
		pop(&pieces)
	}

	b := strings.builder_make(alloc)
	for pc, i in pieces {
		if i > 0 {
			strings.write_byte(&b, '\n')
		}
		pa := blk_para(&st.doc, pc.blk)
		t := para_text(pa, context.temp_allocator)
		strings.write_string(&b, t[clamp(pc.a, 0, len(t)):clamp(pc.z, 0, len(t))])
	}
	return strings.to_string(b)
}

// selection_doc copies the selection out as a little document of its own,
// which is how styled copy/paste works without a rich clipboard.
selection_doc :: proc(st: ^State) -> Doc {
	lo, hi, has := selection(st)
	out := Doc {
		paras = make([dynamic]Paragraph, 0, 4),
	}
	if !has {
		append(&out.paras, para_make())
		return out
	}

	// clip trims a cloned paragraph down to [a, z).
	clip :: proc(cp: ^Paragraph, a, z, n: int) {
		if z < n {
			k := split_at(cp, z)
			for i in k ..< len(cp.runs) {
				delete(cp.runs[i].text)
			}
			resize(&cp.runs, k)
		}
		if a > 0 {
			k := split_at(cp, a)
			for i in 0 ..< k {
				delete(cp.runs[i].text)
			}
			remove_range(&cp.runs, 0, k)
		}
		normalise(cp)
	}

	// Inside one scope the copy keeps the paragraph structure, and a table or a
	// picture wholly inside the range is cloned whole — so copying a table and
	// pasting it elsewhere gives back a table.
	if same_scope(&st.doc, lo, hi) {
		arr, i0 := pos_scope(&st.doc, lo)
		_, i1 := pos_scope(&st.doc, hi)
		for i in i0 ..= i1 {
			src := &arr[i]
			if !text_kind(src.kind) {
				append(&out.paras, para_clone(src))
				continue
			}
			n := para_len(src)
			a := i == i0 ? lo.off : 0
			z := i == i1 ? hi.off : n
			cp := para_clone(src)
			clip(&cp, a, z, n)
			append(&out.paras, cp)
		}
		if len(out.paras) == 0 {
			append(&out.paras, para_make())
		}
		return out
	}

	// Crossing a table boundary: every touched paragraph becomes a paragraph of
	// its own, which is the only shape a flat clipboard has for a grid.
	for blk in blocks_between(&st.doc, lo, hi) {
		src := blk_para(&st.doc, blk)
		if src == nil || !text_kind(src.kind) {
			continue
		}
		n := para_len(src)
		a, z := blk_range(&st.doc, blk, lo, hi)
		if z <= a {
			continue
		}
		cp := para_clone(src)
		clip(&cp, a, z, n)
		append(&out.paras, cp)
	}
	if len(out.paras) == 0 {
		append(&out.paras, para_make())
	}
	return out
}

insert_doc :: proc(d: ^Doc, at: Pos, src: ^Doc) -> Pos {
	q := at
	nested := in_cell(d, at)
	for pi in 0 ..< len(src.paras) {
		sp := &src.paras[pi]
		if pi > 0 {
			q = break_para(d, q)
		}
		if !text_kind(sp.kind) {
			// A table inside a table cell is not representable, so a paste of
			// one into a cell drops it rather than producing a grid nothing
			// will ever lay out.
			if nested {
				continue
			}
			arr, idx := pos_scope(d, q)
			cl := para_clone(sp)
			if text_kind(arr[idx].kind) && para_len(&arr[idx]) == 0 {
				// Land on the empty paragraph the caret is sitting in rather
				// than leaving a blank line above the picture.
				para_destroy(&arr[idx])
				arr[idx] = cl
			} else {
				inject_at(arr, idx + 1, cl)
				q = pos_move_index(d, q, idx + 1, 0)
			}
			continue
		}
		if tp := pos_para(d, q); pi > 0 && tp != nil && text_kind(tp.kind) {
			tp.kind, tp.align, tp.list, tp.depth = sp.kind, sp.align, sp.list, sp.depth
		}
		for &r in sp.runs {
			q = insert_plain(d, q, string(r.text[:]), r.style)
		}
	}
	return q
}

// ---------------------------------------------------------------------------
// Edits
// ---------------------------------------------------------------------------

edit_begin :: proc(st: ^State, kind: Edit_Kind) {
	if st.collab.on {
		// The same grouping rule as the local history, decided before
		// history_begin moves it on: a new kind of edit is a new undo step.
		if kind == .Structural || kind != st.hist.open {
			collab_break(st)
		}
		collab_note_edit(st, kind)
	}
	history_begin(&st.hist, &st.doc, st.caret, st.anchor, kind)
	st.modified = true
	st.dirty = true
	// The single hook the prose checker needs: every edit in the program goes
	// through here, and all it does is note that the alerts are now about an
	// older document. Nothing runs until the typing stops -- see prose_tick.
	prose_mark_stale(st)
}

drop_selection :: proc(st: ^State) -> bool {
	lo, hi, has := selection(st)
	if !has {
		return false
	}
	st.caret = delete_range(&st.doc, lo, hi)
	st.anchor = st.caret
	st.mark = false
	return true
}

caret_style :: proc(st: ^State) -> Char_Style {
	if st.pending_on {
		return st.pending
	}
	return style_at(&st.doc, st.caret)
}

type_text :: proc(st: ^State, s: string) {
	if len(s) == 0 {
		return
	}
	cs := caret_style(st)
	if has_selection(st) {
		edit_begin(st, .Structural)
		// The style at the start of what is being replaced is what the new
		// text should take, not whatever happens to be left behind.
		lo, _, _ := selection(st)
		cs = st.pending_on ? st.pending : style_at(&st.doc, lo)
		drop_selection(st)
	} else {
		edit_begin(st, .Typing)
	}
	// Typing against a table or a picture opens a body paragraph after it,
	// rather than silently going nowhere.
	if pa := pos_para(&st.doc, st.caret); pa != nil && !text_kind(pa.kind) {
		st.caret = break_para(&st.doc, st.caret)
		st.anchor = st.caret
		cs = {}
	}
	st.caret = insert_text(&st.doc, st.caret, s, cs)
	st.anchor = st.caret
	st.goal_ok = false
	// A space ends the undo group, so one undo takes back a word.
	if s[len(s) - 1] == ' ' {
		history_break(&st.hist)
	}
	scroll_to_caret(st)
}

split_line :: proc(st: ^State) {
	edit_begin(st, .Structural)
	drop_selection(st)
	st.caret = break_para(&st.doc, st.caret)
	st.anchor = st.caret
	st.pending_on = false
	st.goal_ok = false
	scroll_to_caret(st)
}

// insert_page_break starts the next paragraph on a new sheet.
insert_page_break :: proc(st: ^State) {
	edit_begin(st, .Structural)
	drop_selection(st)
	st.caret = break_para(&st.doc, st.caret)
	st.doc.paras[st.caret.para].break_before = true
	st.anchor = st.caret
	history_break(&st.hist)
	note(st, "Page break")
	scroll_to_caret(st)
}

backspace :: proc(st: ^State) {
	if has_selection(st) {
		edit_begin(st, .Structural)
		drop_selection(st)
		scroll_to_caret(st)
		return
	}
	if st.caret.off > 0 {
		edit_begin(st, .Deleting)
		t := pos_text(&st.doc, st.caret)
		prev := rune_before(t, st.caret.off)
		from := st.caret
		from.off = prev
		st.caret = delete_range(&st.doc, from, st.caret)
		st.anchor = st.caret
	} else {
		// At the head of a paragraph, Backspace peels off its formatting
		// before it joins the paragraph above — the same order Word uses.
		arr, idx := pos_scope(&st.doc, st.caret)
		pa := &arr[idx]
		if pa.break_before {
			edit_begin(st, .Structural)
			pos_para(&st.doc, st.caret).break_before = false
		} else if pa.list != .None || pa.depth > 0 {
			edit_begin(st, .Structural)
			pa = pos_para(&st.doc, st.caret)
			if pa.depth > 0 {
				pa.depth -= 1
			} else {
				pa.list = .None
			}
		} else if pa.kind != .Body && text_kind(pa.kind) {
			edit_begin(st, .Structural)
			pos_para(&st.doc, st.caret).kind = .Body
		} else if idx > 0 {
			// Inside a cell this merges within the cell; at the top level it
			// merges paragraphs, and against a table or a picture it removes
			// the block.
			edit_begin(st, .Structural)
			st.caret = merge_para(&st.doc, st.caret, idx - 1)
			st.anchor = st.caret
		}
	}
	st.goal_ok = false
	scroll_to_caret(st)
}

delete_forward :: proc(st: ^State) {
	if has_selection(st) {
		edit_begin(st, .Structural)
		drop_selection(st)
		scroll_to_caret(st)
		return
	}
	arr, idx := pos_scope(&st.doc, st.caret)
	n := para_len(&arr[idx])
	if st.caret.off < n {
		edit_begin(st, .Deleting)
		t := pos_text(&st.doc, st.caret)
		to := st.caret
		to.off = rune_after(t, st.caret.off)
		st.caret = delete_range(&st.doc, st.caret, to)
		st.anchor = st.caret
	} else if idx + 1 < len(arr^) {
		edit_begin(st, .Structural)
		st.caret = merge_para(&st.doc, st.caret, idx)
		st.anchor = st.caret
	}
	st.goal_ok = false
	scroll_to_caret(st)
}

// ---------------------------------------------------------------------------
// Movement
// ---------------------------------------------------------------------------

place_caret :: proc(st: ^State, q: Pos, extend: bool) {
	st.caret = pos_clamp(&st.doc, q)
	if !extend && !st.mark {
		st.anchor = st.caret
	}
	st.pending_on = false
	history_break(&st.hist)
	scroll_to_caret(st)
}

// pos_neighbour steps to the next or previous *block* in reading order, which
// is how Left at the head of a paragraph and Right at its tail get out — and
// the only thing that has to know a table cell is a place a caret can be.
pos_neighbour :: proc(d: ^Doc, q: Pos, dir: int) -> (Pos, bool) {
	bs := doc_blocks(d, context.temp_allocator)
	at := -1
	for b, i in bs {
		if b == (Blk{q.para, q.row, q.col, q.cpara}) {
			at = i
			break
		}
	}
	if at < 0 {
		return q, false
	}
	k := at + dir
	if k < 0 || k >= len(bs) {
		return q, false
	}
	n := dir < 0 ? blk_len(d, bs[k]) : 0
	return blk_pos(bs[k], n), true
}

move_h :: proc(st: ^State, dir: int, extend: bool, by_word := false) {
	q := st.caret
	// A plain left/right with a selection collapses to its edge.
	if !extend && !st.mark && has_selection(st) && !by_word {
		lo, hi, _ := selection(st)
		place_caret(st, dir < 0 ? lo : hi, false)
		st.goal_ok = false
		return
	}
	t := pos_text(&st.doc, q)
	if dir < 0 {
		if q.off > 0 {
			if by_word {
				k := q.off
				for k > 0 && !is_word_byte(t[rune_before(t, k)]) {
					k = rune_before(t, k)
				}
				for k > 0 && is_word_byte(t[rune_before(t, k)]) {
					k = rune_before(t, k)
				}
				q.off = k
			} else {
				q.off = rune_before(t, q.off)
			}
		} else if nq, got := pos_neighbour(&st.doc, q, -1); got {
			q = nq
		}
	} else {
		if q.off < len(t) {
			if by_word {
				k := q.off
				for k < len(t) && is_word_byte(t[k]) {
					k = rune_after(t, k)
				}
				for k < len(t) && !is_word_byte(t[k]) {
					k = rune_after(t, k)
				}
				q.off = k
			} else {
				q.off = rune_after(t, q.off)
			}
		} else if nq, got := pos_neighbour(&st.doc, q, 1); got {
			q = nq
		}
	}
	place_caret(st, q, extend)
	st.goal_ok = false
}

// move_v moves by *visual* line and remembers the column, so walking down
// through a wrapped paragraph and back up again returns to the same place.
move_v :: proc(st: ^State, delta: int, extend: bool) {
	if len(st.lay.lines) == 0 {
		return
	}
	li := line_of(&st.lay, st.caret)
	if li < 0 {
		return
	}
	if !st.goal_ok {
		st.goal_x = caret_x(&st.lay, li, st.caret.off)
		st.goal_ok = true
	}
	t := line_step(&st.lay, li, delta)
	if t == li {
		// Already at the top or bottom: go to the very start or end.
		q := delta < 0 ? Pos{} : doc_end(&st.doc)
		place_caret(st, q, extend)
		st.goal_ok = false
		return
	}
	l := st.lay.lines[t]
	q := line_pos(l, off_at_x(&st.lay, t, st.goal_x))
	goal := st.goal_x
	place_caret(st, q, extend)
	st.goal_x = goal
	st.goal_ok = true
}

move_line_edge :: proc(st: ^State, to_end: bool, extend: bool) {
	li := line_of(&st.lay, st.caret)
	if li < 0 {
		return
	}
	l := st.lay.lines[li]
	q := line_pos(l, to_end ? (l.last ? l.end : l.vis_end) : l.start)
	place_caret(st, q, extend)
	st.goal_ok = false
}

select_all :: proc(st: ^State) {
	st.anchor = Pos{}
	st.caret = doc_end(&st.doc)
	st.mark = false
	history_break(&st.hist)
}

select_word :: proc(st: ^State) {
	t := pos_text(&st.doc, st.caret)
	lo, hi := word_bounds(t, st.caret.off)
	a, b := st.caret, st.caret
	a.off, b.off = lo, hi
	st.anchor, st.caret = a, b
	history_break(&st.hist)
}

toggle_mark :: proc(st: ^State) {
	if st.mark {
		st.mark = false
		st.anchor = st.caret
		note(st, "Selection cleared")
	} else {
		st.mark = true
		st.anchor = st.caret
		note(st, "Mark set — arrows extend the selection")
	}
}

// ---------------------------------------------------------------------------
// Character formatting
// ---------------------------------------------------------------------------

// patch_selection applies a style patch to the selection, or, with no
// selection, arms it for the next character typed. That second case is what
// makes pressing bold and then typing behave the way everyone expects.
patch_selection :: proc(st: ^State, patch: Style_Patch) {
	if has_selection(st) {
		lo, hi, _ := selection(st)
		edit_begin(st, .Structural)
		apply_patch(&st.doc, lo, hi, patch)
		history_break(&st.hist)
		return
	}
	cs := caret_style(st)
	patch_apply(&cs, patch)
	st.pending = cs
	st.pending_on = true
}

toggle_bold :: proc(st: ^State) {
	cs := effective_style(st)
	patch_selection(st, {{.Bold}, Char_Style{bold = !cs.bold}})
}

toggle_italic :: proc(st: ^State) {
	cs := effective_style(st)
	patch_selection(st, {{.Italic}, Char_Style{italic = !cs.italic}})
}

toggle_underline :: proc(st: ^State) {
	cs := effective_style(st)
	patch_selection(st, {{.Underline}, Char_Style{underline = !cs.underline}})
}

toggle_mono :: proc(st: ^State) {
	cs := effective_style(st)
	patch_selection(st, {{.Mono}, Char_Style{mono = !cs.mono}})
}

set_size :: proc(st: ^State, size: f32) {
	patch_selection(st, {{.Size}, Char_Style{size = size}})
}

set_color :: proc(st: ^State, rgb: u32) {
	v := rgb == 0 ? u32(0) : 0xff000000 | (rgb & 0xffffff)
	patch_selection(st, {{.Color}, Char_Style{color = v}})
}

clear_formatting :: proc(st: ^State) {
	patch_selection(st, {{.Bold, .Italic, .Underline, .Mono, .Size, .Color}, Char_Style{}})
}

// effective_style is what the toolbar shows: the armed style if there is one,
// the style of the whole selection if it agrees, otherwise the style at its
// start. "Agrees" is what decides whether pressing bold turns bold on or off.
effective_style :: proc(st: ^State) -> Char_Style {
	if st.pending_on {
		return st.pending
	}
	lo, hi, has := selection(st)
	if !has {
		return style_at(&st.doc, st.caret)
	}
	cs := style_at(&st.doc, lo)
	cs.bold = range_all_bold(&st.doc, lo, hi)
	// The remaining flags use the same rule, read off the first run.
	all_i, all_u, all_m := true, true, true
	same_size, same_color := true, true
	first := true
	ref := cs
	for pi in lo.para ..= hi.para {
		pa := &st.doc.paras[pi]
		n := para_len(pa)
		a := pi == lo.para ? lo.off : 0
		z := pi == hi.para ? hi.off : n
		acc := 0
		for &r in pa.runs {
			l := len(r.text)
			if l > 0 && acc < z && acc + l > a {
				if first {
					ref = r.style
					first = false
				}
				if !r.style.italic {all_i = false}
				if !r.style.underline {all_u = false}
				if !r.style.mono {all_m = false}
				if r.style.size != ref.size {same_size = false}
				if r.style.color != ref.color {same_color = false}
			}
			acc += l
		}
	}
	cs.italic, cs.underline, cs.mono = all_i, all_u, all_m
	cs.size = same_size ? ref.size : 0
	cs.color = same_color ? ref.color : 0
	return cs
}

// ---------------------------------------------------------------------------
// Paragraph formatting
// ---------------------------------------------------------------------------

// sel_blocks is every paragraph the selection touches — the caret's own when
// there is no selection. Every paragraph-level command loops over it, so a
// command applies inside a table cell exactly as it does in the body.
sel_blocks :: proc(st: ^State) -> []Blk {
	lo, hi, _ := selection(st)
	return blocks_between(&st.doc, lo, hi)
}

TEXT_KINDS :: 6 // Body, H1, H2, H3, Quote, Code — the kinds the cycle visits

set_kind :: proc(st: ^State, k: Para_Kind) {
	if !text_kind(k) {
		return
	}
	edit_begin(st, .Structural)
	for blk in sel_blocks(st) {
		pa := blk_para(&st.doc, blk)
		if pa == nil || !text_kind(pa.kind) {
			continue
		}
		pa.kind = k
		if k == .Code {
			pa.list = .None
		}
	}
	history_break(&st.hist)
}

cycle_kind :: proc(st: ^State) {
	pa := pos_para(&st.doc, st.caret)
	if pa == nil || !text_kind(pa.kind) {
		return
	}
	next := Para_Kind((int(pa.kind) + 1) % TEXT_KINDS)
	set_kind(st, next)
	note(st, fmt.tprintf("Style: %s", kind_label(next)))
}

set_align :: proc(st: ^State, a: Align) {
	edit_begin(st, .Structural)
	for blk in sel_blocks(st) {
		if pa := blk_para(&st.doc, blk); pa != nil {
			pa.align = a
		}
	}
	// An image paragraph's alignment is the picture's own placement, and the
	// caret sits *in* the image paragraph rather than in a cell of it, so it is
	// reached through the block list like everything else.
	history_break(&st.hist)
}

cycle_align :: proc(st: ^State) {
	pa := pos_para(&st.doc, st.caret)
	cur := pa == nil ? Align.Left : pa.align
	next := Align((int(cur) + 1) % len(Align))
	set_align(st, next)
	note(st, fmt.tprintf("Align: %v", next))
}

set_list :: proc(st: ^State, l: List_Kind) {
	edit_begin(st, .Structural)
	cur := pos_para(&st.doc, st.caret)
	on := cur != nil && cur.list == l
	for blk in sel_blocks(st) {
		pa := blk_para(&st.doc, blk)
		if pa == nil || !text_kind(pa.kind) {
			continue
		}
		pa.list = on ? .None : l
		if !on && pa.kind == .Code {
			pa.kind = .Body
		}
	}
	history_break(&st.hist)
}

indent_paras :: proc(st: ^State, delta: int) {
	edit_begin(st, .Structural)
	for blk in sel_blocks(st) {
		if pa := blk_para(&st.doc, blk); pa != nil {
			pa.depth = clamp(pa.depth + delta, 0, 6)
		}
	}
	history_break(&st.hist)
}

// ---------------------------------------------------------------------------
// Tables
// ---------------------------------------------------------------------------

// table_at is the table the caret is inside, or nil. Every table command goes
// through it, so none of them can act on a document that has no table.
table_at :: proc(st: ^State) -> ^Table {
	if st.caret.para < 0 || st.caret.para >= len(st.doc.paras) {
		return nil
	}
	pa := &st.doc.paras[st.caret.para]
	return pa.kind == .Table ? pa.table : nil
}

in_table :: proc(st: ^State) -> bool {
	return table_at(st) != nil
}

// insert_table drops a table in at the caret and parks the caret in its first
// cell. An empty paragraph is replaced rather than left above the grid, and a
// caret in the middle of a paragraph splits it first — a table is a block and
// cannot sit inside a line.
insert_table :: proc(st: ^State, rows, cols: int) {
	if in_cell(&st.doc, st.caret) {
		note(st, "A table cannot nest inside a cell")
		return
	}
	edit_begin(st, .Structural)
	drop_selection(st)

	arr, idx := pos_scope(&st.doc, st.caret)
	at := idx
	if para_len(&arr[idx]) == 0 && text_kind(arr[idx].kind) {
		para_destroy(&arr[idx])
		arr[idx] = table_para_make(rows, cols)
	} else {
		if st.caret.off > 0 && st.caret.off < para_len(&arr[idx]) {
			st.caret = break_para(&st.doc, st.caret)
			arr, idx = pos_scope(&st.doc, st.caret)
			at = idx
			inject_at(arr, at, table_para_make(rows, cols))
		} else if st.caret.off == 0 {
			inject_at(arr, at, table_para_make(rows, cols))
		} else {
			at = idx + 1
			inject_at(arr, at, table_para_make(rows, cols))
		}
	}
	// A table needs a paragraph on each side of it, or the caret has nowhere
	// to go when it leaves — a table at the very top of a document with
	// nothing above it is a dead end, and Word keeps a paragraph there for
	// exactly this reason.
	if at == len(arr^) - 1 {
		append(arr, para_make())
	}
	if at == 0 {
		inject_at(arr, 0, para_make())
		at = 1
	}
	st.caret = Pos {
		para = at,
	}
	st.anchor = st.caret
	st.pending_on = false
	st.goal_ok = false
	history_break(&st.hist)
	note(st, fmt.tprintf("Inserted a %dx%d table", rows, cols))
	st.dirty = true
}

// table_move_cell is Tab and Shift+Tab. Tab at the last cell grows the table
// by a row, the way every word processor does; Shift+Tab out of the first cell
// leaves the table.
table_move_cell :: proc(st: ^State, dir: int) -> bool {
	t := table_at(st)
	if t == nil {
		return false
	}
	nr, nc, ok := table_step_cell(t, st.caret.row, st.caret.col, dir)
	if !ok {
		if dir > 0 {
			edit_begin(st, .Structural)
			t = table_at(st)
			table_insert_row(t, len(t.rows))
			st.caret = Pos {
				para = st.caret.para,
				row  = len(t.rows) - 1,
			}
			st.anchor = st.caret
			st.dirty = true
			history_break(&st.hist)
			scroll_to_caret(st)
			return true
		}
		// Out of the top-left cell: step to the block before the table.
		if q, got := pos_neighbour(&st.doc, Pos{para = st.caret.para}, -1); got {
			place_caret(st, q, false)
			return true
		}
		return false
	}
	q := Pos {
		para = st.caret.para,
		row  = nr,
		col  = nc,
	}
	// Tab selects the cell's text, which is what makes "Tab, type" replace a
	// cell rather than append to it.
	cl := table_cell(t, nr, nc)
	if cl != nil && len(cl.paras) > 0 {
		st.anchor = q
		st.caret = blk_pos(Blk{st.caret.para, nr, nc, len(cl.paras) - 1}, para_len(&cl.paras[len(cl.paras) - 1]))
		st.mark = false
		st.pending_on = false
		st.goal_ok = false
		history_break(&st.hist)
		scroll_to_caret(st)
		return true
	}
	place_caret(st, q, false)
	return true
}

table_row_cmd :: proc(st: ^State, below: bool) {
	t := table_at(st)
	if t == nil {
		note(st, "The caret is not in a table")
		return
	}
	edit_begin(st, .Structural)
	t = table_at(st)
	at := table_insert_row(t, st.caret.row + (below ? 1 : 0))
	st.caret = Pos {
		para = st.caret.para,
		row  = at,
		col  = st.caret.col,
	}
	st.anchor = st.caret
	st.dirty = true
	history_break(&st.hist)
	note(st, fmt.tprintf("Row inserted (%d rows)", len(t.rows)))
}

table_col_cmd :: proc(st: ^State, after: bool) {
	t := table_at(st)
	if t == nil {
		note(st, "The caret is not in a table")
		return
	}
	edit_begin(st, .Structural)
	t = table_at(st)
	at := table_insert_col(t, st.caret.col + (after ? 1 : 0))
	st.caret = Pos {
		para = st.caret.para,
		row  = st.caret.row,
		col  = at,
	}
	st.anchor = st.caret
	st.dirty = true
	history_break(&st.hist)
	note(st, fmt.tprintf("Column inserted (%d columns)", table_cols(t)))
}

table_delete_row_cmd :: proc(st: ^State) {
	t := table_at(st)
	if t == nil {
		return
	}
	if len(t.rows) <= 1 {
		note(st, "A table keeps at least one row")
		return
	}
	edit_begin(st, .Structural)
	t = table_at(st)
	table_delete_row(t, st.caret.row)
	st.caret = pos_clamp(&st.doc, st.caret)
	st.anchor = st.caret
	st.dirty = true
	history_break(&st.hist)
	note(st, fmt.tprintf("Row deleted (%d rows)", len(t.rows)))
}

table_delete_col_cmd :: proc(st: ^State) {
	t := table_at(st)
	if t == nil {
		return
	}
	if table_cols(t) <= 1 {
		note(st, "A table keeps at least one column")
		return
	}
	edit_begin(st, .Structural)
	t = table_at(st)
	table_delete_col(t, st.caret.col)
	st.caret = pos_clamp(&st.doc, st.caret)
	st.anchor = st.caret
	st.dirty = true
	history_break(&st.hist)
	note(st, fmt.tprintf("Column deleted (%d columns)", table_cols(t)))
}

table_toggle_header :: proc(st: ^State) {
	if table_at(st) == nil {
		return
	}
	edit_begin(st, .Structural)
	t := table_at(st)
	t.header = !t.header
	st.dirty = true
	history_break(&st.hist)
	note(st, t.header ? "Header row on" : "Header row off")
}

table_toggle_borders :: proc(st: ^State) {
	if table_at(st) == nil {
		return
	}
	edit_begin(st, .Structural)
	t := table_at(st)
	t.borders = !t.borders
	st.dirty = true
	history_break(&st.hist)
	note(st, t.borders ? "Cell borders on" : "Cell borders off")
}

// table_nudge_width widens or narrows the caret's column by a fixed step, the
// keyboard equivalent of dragging a column rule.
table_nudge_width :: proc(st: ^State, delta: f32) {
	if table_at(st) == nil {
		return
	}
	edit_begin(st, .Structural)
	t := table_at(st)
	table_set_width(t, st.caret.col, table_width(t, st.caret.col) + delta)
	st.dirty = true
	history_break(&st.hist)
	note(st, fmt.tprintf("Column %d: %.0f px", st.caret.col + 1, table_width(t, st.caret.col)))
}

// delete_block removes the table or picture the caret is in.
//
// It deliberately does *not* go through `pos_scope`: a caret inside a table
// resolves to the cell's paragraph array, and this command is about the
// top-level block that owns the cell, which is the paragraph `caret.para`
// names.
delete_block :: proc(st: ^State) {
	if len(st.doc.paras) == 0 {
		return
	}
	idx := clamp(st.caret.para, 0, len(st.doc.paras) - 1)
	if text_kind(st.doc.paras[idx].kind) {
		note(st, "The caret is not on a table or a picture")
		return
	}
	edit_begin(st, .Structural)
	label := st.doc.paras[idx].kind == .Table ? "Table deleted" : "Picture deleted"
	para_destroy(&st.doc.paras[idx])
	ordered_remove(&st.doc.paras, idx)
	if len(st.doc.paras) == 0 {
		append(&st.doc.paras, para_make())
	}
	st.caret = Pos {
		para = clamp(idx, 0, len(st.doc.paras) - 1),
	}
	st.anchor = st.caret
	st.dirty = true
	history_break(&st.hist)
	note(st, label)
}

// ---------------------------------------------------------------------------
// Images
// ---------------------------------------------------------------------------

do_insert_image :: proc(st: ^State, path: string) {
	full := expand_home(path, context.temp_allocator)
	im, got := image_load(full)
	if !got {
		note(st, fmt.tprintf("Could not read %s", base_name(full)))
		return
	}
	// A picture in a cell used to be refused: it needs the cell's measure
	// rather than the page's, and nothing knew how to give it one. The layout
	// now sizes and places it against the column it is in, every exporter
	// walks the cells for pictures as well as the body, and the caret steps
	// over it the way it steps over a picture anywhere else.
	edit_begin(st, .Structural)
	drop_selection(st)
	arr, idx := pos_scope(&st.doc, st.caret)
	at := idx
	if para_len(&arr[idx]) == 0 && text_kind(arr[idx].kind) {
		para_destroy(&arr[idx])
		arr[idx] = image_para_make(im)
	} else {
		at = idx + 1
		inject_at(arr, at, image_para_make(im))
	}
	if at == len(arr^) - 1 {
		append(arr, para_make())
	}
	// In a cell the caret keeps the cell it is in and moves to the picture's
	// paragraph *within* it; at the top level `row`, `col` and `cpara` are
	// zero and this is the same `Pos` it always was.
	cell := in_cell(&st.doc, st.caret)
	st.caret = Pos {
		para  = cell ? st.caret.para : at,
		row   = cell ? st.caret.row : 0,
		col   = cell ? st.caret.col : 0,
		cpara = cell ? at : 0,
	}
	st.anchor = st.caret
	st.dirty = true
	history_break(&st.hist)
	// The measure a picture is drawn against: the column's text width in a
	// cell, the page's everywhere else.
	measure := f32(CONTENT_W)
	if cell {
		t := st.doc.paras[st.caret.para].table
		measure = max(20, table_width(t, st.caret.col) - 2 * CELL_PAD)
	}
	w, h := image_para_size(&arr[at], measure, CONTENT_H)
	note(st, fmt.tprintf("%s — %dx%d, drawn %.0fx%.0f", base_name(full), arr[at].img.w, arr[at].img.h, w, h))
}

image_at :: proc(st: ^State) -> ^Doc_Image {
	pa := pos_para(&st.doc, st.caret)
	if pa == nil || pa.kind != .Image {
		return nil
	}
	return pa.img
}

image_nudge_scale :: proc(st: ^State, factor: f32) {
	if image_at(st) == nil {
		note(st, "The caret is not on a picture")
		return
	}
	edit_begin(st, .Structural)
	im := image_at(st)
	image_set_scale(im, im.scale * factor)
	st.dirty = true
	history_break(&st.hist)
	w, h := image_draw_size(im)
	note(st, fmt.tprintf("Picture %d%% — %.0fx%.0f px", int(im.scale * 100 + 0.5), w, h))
}

// ---------------------------------------------------------------------------
// Clipboard
// ---------------------------------------------------------------------------
// Clipboard
// ---------------------------------------------------------------------------

do_copy :: proc(st: ^State) {
	if !has_selection(st) {
		select_word(st)
	}
	if !has_selection(st) {
		return
	}
	text := selection_text(st, context.temp_allocator)
	doc_destroy(&st.clip_doc)
	st.clip_doc = selection_doc(st)
	delete(st.clip_text)
	st.clip_text = strings.clone(text)
	kit.clipboard_set(text)
	note(st, fmt.tprintf("Copied %d characters", len(text)))
}

do_cut :: proc(st: ^State) {
	if !has_selection(st) {
		return
	}
	do_copy(st)
	edit_begin(st, .Structural)
	drop_selection(st)
	note(st, "Cut")
	scroll_to_caret(st)
}

do_paste :: proc(st: ^State) {
	text, ok := kit.clipboard_get(context.temp_allocator)
	if !ok {
		// No wl-paste: fall back to whatever this app last copied.
		text = st.clip_text
		if len(text) == 0 {
			note(st, "Clipboard is empty")
			return
		}
	}
	edit_begin(st, .Structural)
	drop_selection(st)
	if text == st.clip_text && len(st.clip_doc.paras) > 0 {
		// Same text we put there, so the runs are still good: paste styled.
		st.caret = insert_doc(&st.doc, st.caret, &st.clip_doc)
	} else {
		st.caret = insert_text(&st.doc, st.caret, text, caret_style(st))
	}
	st.anchor = st.caret
	history_break(&st.hist)
	note(st, "Pasted")
	scroll_to_caret(st)
}

// ---------------------------------------------------------------------------
// Undo / redo
// ---------------------------------------------------------------------------

do_undo :: proc(st: ^State) {
	if st.collab.on {
		// Shared: undo this window's own last step, never a collaborator's.
		note(st, collab_undo(st) ? "Undo" : "Nothing to undo")
		st.goal_ok = false
		return
	}
	if history_undo(&st.hist, &st.doc, &st.caret, &st.anchor) {
		st.dirty = true
		st.modified = true
		st.goal_ok = false
		st.caret = pos_clamp(&st.doc, st.caret)
		st.anchor = pos_clamp(&st.doc, st.anchor)
		note(st, "Undo")
	} else {
		note(st, "Nothing to undo")
	}
}

do_redo :: proc(st: ^State) {
	if st.collab.on {
		note(st, collab_undo(st, true) ? "Redo" : "Nothing to redo")
		st.goal_ok = false
		return
	}
	if history_redo(&st.hist, &st.doc, &st.caret, &st.anchor) {
		st.dirty = true
		st.modified = true
		st.goal_ok = false
		st.caret = pos_clamp(&st.doc, st.caret)
		st.anchor = pos_clamp(&st.doc, st.anchor)
		note(st, "Redo")
	} else {
		note(st, "Nothing to redo")
	}
}

// ---------------------------------------------------------------------------
// Find and replace
// ---------------------------------------------------------------------------

lower :: proc(c: u8) -> u8 {
	return c >= 'A' && c <= 'Z' ? c + 32 : c
}

// find_index is the one search primitive in the program. It is a plain
// forward scan — the documents are kilobytes and the needle is a word, so
// Boyer-Moore would be slower to write than to run — with the two options the
// find box offers:
//
//   `fold`  compare case-insensitively (ASCII; a case-folded search outside
//           ASCII needs a full case table, which is a real gap and is noted)
//   `word`  the match must not be flanked by word characters, so "art" does
//           not hit "start"
//
// Boundaries are tested against `hay` rather than against a slice of it, which
// is why every caller passes the whole paragraph and a starting offset instead
// of slicing.
find_index :: proc(hay, needle: string, from: int, fold := true, word := false) -> int {
	lo, _, ok := search_plain(hay, needle, from, fold, word)
	return ok ? lo : -1
}

// find_span is what the find box actually calls. A match is a *span*, not an
// offset and a length: case folding can expand (ß folds to `ss`, so `Straße`
// matches `STRASSE` and the two are not the same number of bytes) and a
// regular expression matches whatever it matches. Everything downstream —
// the selection, the replace, the hit count — takes both ends from here.
find_span :: proc(st: ^State, hay: string, from: int) -> (lo, hi: int, ok: bool) {
	needle := string(st.find[:])
	if len(needle) == 0 {
		return 0, 0, false
	}
	if st.find_regex {
		if st.rx == nil {
			return 0, 0, false
		}
		l, h, _, hit := rx_search(st.rx, hay, from)
		if !hit {
			return 0, 0, false
		}
		if st.find_word &&
		   (is_word_rune(rune_ending_at(hay, l)) || is_word_rune(rune_at_off(hay, h))) {
			// Push past this one and try again, rather than reporting a hit
			// the user asked not to see.
			if h <= l {
				return 0, 0, false
			}
			return find_span(st, hay, h)
		}
		return l, h, true
	}
	return search_plain(hay, needle, from, !st.find_case, st.find_word)
}

// rx_recompile rebuilds the compiled pattern after the term or the flags
// change. A pattern that does not compile is kept as the error it is: the
// find bar says so, and nothing matches until it is fixed.
rx_recompile :: proc(st: ^State) {
	if st.rx != nil {
		rx_destroy(st.rx)
		free(st.rx)
		st.rx = nil
	}
	delete(st.rx_err)
	st.rx_err = ""
	if !st.find_regex || len(st.find) == 0 {
		return
	}
	rx, err := rx_compile(string(st.find[:]), !st.find_case)
	if err != "" {
		st.rx_err = strings.clone(err)
		return
	}
	st.rx = rx
}

// index_fold is the old name, kept because a case-insensitive substring search
// with no word constraint is still the default.
index_fold :: proc(hay, needle: string) -> int {
	return find_index(hay, needle, 0, true, false)
}

// find_hit applies the find box's own options, and reports where a match
// starts. Callers that need its end use `find_span`.
find_hit :: proc(st: ^State, hay: string, from: int) -> int {
	lo, _, ok := find_span(st, hay, from)
	return ok ? lo : -1
}

find_mode_label :: proc(st: ^State) -> string {
	b := strings.builder_make(context.temp_allocator)
	if st.find_regex {
		strings.write_string(&b, ".* ")
	}
	if st.find_case {
		strings.write_string(&b, "Aa ")
	}
	if st.find_word {
		strings.write_string(&b, "W ")
	}
	out := strings.trim_space(strings.to_string(b))
	return out == "" ? "—" : out
}

toggle_find_case :: proc(st: ^State) {
	st.find_case = !st.find_case
	rx_recompile(st)
	st.find_hits = count_hits(st)
	note(st, st.find_case ? "Match case on" : "Match case off")
}

toggle_find_word :: proc(st: ^State) {
	st.find_word = !st.find_word
	st.find_hits = count_hits(st)
	note(st, st.find_word ? "Whole words only" : "Whole words off")
}

toggle_find_regex :: proc(st: ^State) {
	st.find_regex = !st.find_regex
	rx_recompile(st)
	st.find_hits = count_hits(st)
	if st.find_regex && st.rx_err != "" {
		note(st, tfmt("Regular expression: %s", st.rx_err))
		return
	}
	note(st, st.find_regex ? "Regular expression on" : "Regular expression off")
}

// blk_index_of locates a position's block in a block list.
blk_index_of :: proc(bs: []Blk, q: Pos) -> int {
	want := Blk{q.para, q.row, q.col, q.cpara}
	for b, i in bs {
		if b == want {
			return i
		}
	}
	return -1
}

// find_from searches forward from `from`, wrapping once. The walk is over
// blocks, so a term inside a table cell is found like any other.
find_from :: proc(st: ^State, from: Pos) -> (lo, hi: Pos, ok: bool) {
	needle := string(st.find[:])
	if len(needle) == 0 {
		return {}, {}, false
	}
	bs := doc_blocks(&st.doc, context.temp_allocator)
	n := len(bs)
	if n == 0 {
		return {}, {}, false
	}
	start_i := max(0, blk_index_of(bs, from))
	for step in 0 ..= n {
		bi := (start_i + step) % n
		pa := blk_para(&st.doc, bs[bi])
		if pa == nil || !text_kind(pa.kind) {
			continue
		}
		t := para_text(pa, context.temp_allocator)
		start := step == 0 ? clamp(from.off, 0, len(t)) : 0
		lo, hi, hit := find_span(st, t, start)
		if hit {
			return blk_pos(bs[bi], lo), blk_pos(bs[bi], hi), true
		}
	}
	return {}, {}, false
}

// Find_Hit is one match: the block it is in and its byte span there.
Find_Hit :: struct {
	blk:    Blk,
	lo, hi: int,
}

// find_all walks every text block with the find box's own options. The hit
// count in the find bar and `docs find` are both this walk, so the number the
// window shows and the list an agent gets cannot disagree.
find_all :: proc(st: ^State, limit := 0, alloc := context.temp_allocator) -> []Find_Hit {
	out := make([dynamic]Find_Hit, alloc)
	needle := string(st.find[:])
	if len(needle) == 0 {
		return out[:]
	}
	for blk in doc_blocks(&st.doc) {
		pa := blk_para(&st.doc, blk)
		if pa == nil || !text_kind(pa.kind) {
			continue
		}
		t := para_text(pa, context.temp_allocator)
		at := 0
		for at <= len(t) {
			lo, hi, hit := find_span(st, t, at)
			if !hit {
				break
			}
			append(&out, Find_Hit{blk, lo, hi})
			if limit > 0 && len(out) >= limit {
				return out[:]
			}
			// An empty match — `a*` against "bbb" — must still make progress,
			// or counting them never finishes.
			at = hi > lo ? hi : lo + 1
		}
	}
	return out[:]
}

count_hits :: proc(st: ^State) -> int {
	return len(find_all(st))
}

// find_set puts a term, a replacement and the three options into the find
// box, exactly as typing them and pressing the toggles would, and reports a
// pattern that does not compile.
find_set :: proc(st: ^State, term, repl: string, match_case, whole_word, regex: bool) -> (rx_err: string) {
	clear(&st.find)
	append(&st.find, term)
	clear(&st.repl)
	append(&st.repl, repl)
	st.find_case = match_case
	st.find_word = whole_word
	st.find_regex = regex
	rx_recompile(st)
	st.find_hits = count_hits(st)
	return st.rx_err
}

find_next :: proc(st: ^State) -> bool {
	from := st.caret
	if has_selection(st) {
		_, hi, _ := selection(st)
		from = hi
	}
	lo, hi, ok := find_from(st, from)
	if !ok {
		note(st, fmt.tprintf("Not found: %s", string(st.find[:])))
		return false
	}
	st.anchor = lo
	st.caret = hi
	st.mark = false
	st.goal_ok = false
	scroll_to_caret(st)
	return true
}

selection_is_match :: proc(st: ^State) -> bool {
	lo, hi, has := selection(st)
	if !has || !pos_same_block(lo, hi) || len(st.find) == 0 {
		return false
	}
	t := pos_text(&st.doc, lo)
	if hi.off > len(t) {
		return false
	}
	mlo, mhi, ok := find_span(st, t, lo.off)
	return ok && mlo == lo.off && mhi == hi.off
}

replace_one :: proc(st: ^State) {
	if len(st.find) == 0 {
		return
	}
	if !selection_is_match(st) {
		if !find_next(st) {
			return
		}
	}
	lo, _, _ := selection(st)
	cs := style_after(&st.doc, lo)
	text := replacement_at(st, pos_text(&st.doc, lo), lo.off, context.temp_allocator)
	edit_begin(st, .Structural)
	drop_selection(st)
	st.caret = insert_text(&st.doc, st.caret, text, cs)
	st.anchor = st.caret
	history_break(&st.hist)
	find_next(st)
	note(st, "Replaced")
}

// replacement_at is the text to put in place of the match at `at`. In plain
// mode that is the replacement field verbatim; under a regular expression
// `\1`…`\9` stand for what the groups captured, which is the whole reason to
// have groups.
replacement_at :: proc(st: ^State, hay: string, at: int, alloc := context.allocator) -> string {
	repl := string(st.repl[:])
	if !st.find_regex || st.rx == nil {
		return strings.clone(repl, alloc)
	}
	lo, _, caps, ok := rx_search(st.rx, hay, at)
	if !ok || lo != at {
		return strings.clone(repl, alloc)
	}
	return rx_expand(repl, hay, caps, alloc)
}

// replace_all is one undo step for the whole document, whatever it touches.
//
// That is the "undo-safe" part, and it is not free: `edit_begin` is called
// exactly once, *before* the first mutation, and `history_break` once after
// the last, so the entire sweep collapses into a single snapshot. Calling
// `edit_begin` per replacement would make undo take the document back one word
// at a time, which is both slower and wrong.
replace_all :: proc(st: ^State) -> (count: int) {
	if len(st.find) == 0 {
		return 0
	}
	edit_begin(st, .Structural)
	// The block list is taken once: a replacement changes bytes, never the
	// shape of the document, so the list stays valid for the whole sweep.
	for blk in doc_blocks(&st.doc, context.temp_allocator) {
		pa := blk_para(&st.doc, blk)
		if pa == nil || !text_kind(pa.kind) {
			continue
		}
		// Search forward from just past each replacement, so a replacement
		// that contains the search term cannot be matched again.
		at := 0
		for at <= blk_len(&st.doc, blk) {
			t := para_text(blk_para(&st.doc, blk), context.temp_allocator)
			lo, hi, hit := find_span(st, t, at)
			if !hit {
				break
			}
			with := replacement_at(st, t, lo, context.temp_allocator)
			cs := style_after(&st.doc, blk_pos(blk, lo))
			if hi > lo {
				delete_range(&st.doc, blk_pos(blk, lo), blk_pos(blk, hi))
			}
			insert_plain(&st.doc, blk_pos(blk, lo), with, cs)
			// Past the text just written, and always forward: an empty match
			// would otherwise be replaced for ever.
			at = lo + max(1, len(with))
			count += 1
		}
	}
	st.caret = pos_clamp(&st.doc, st.caret)
	st.anchor = st.caret
	history_break(&st.hist)
	st.dirty = true
	note(st, fmt.tprintf("Replaced %d occurrence%s", count, count == 1 ? "" : "s"))
	return count
}

// ---------------------------------------------------------------------------
// Scrolling and zoom
// ---------------------------------------------------------------------------

clamp_scroll :: proc(st: ^State) {
	st.scroll = clamp(st.scroll, 0, max(0, doc_view_height(st) - st.view.h))
	st.hscroll = clamp(st.hscroll, 0, max(0, doc_view_width(st) - st.view.w))
}

scroll_to_caret :: proc(st: ^State) {
	x, y, h, ok := caret_view_point(st)
	if !ok {
		return
	}
	pad := f32(40)
	if y < pad {
		st.scroll += y - pad
	}
	if y + h > st.view.h - pad {
		st.scroll += (y + h) - (st.view.h - pad)
	}
	if x < 30 {
		st.hscroll += x - 30
	}
	if x > st.view.w - 30 {
		st.hscroll += x - (st.view.w - 30)
	}
	clamp_scroll(st)
}

set_zoom :: proc(st: ^State, i: int) {
	st.zoom_i = clamp(i, 0, len(ZOOMS) - 1)
	st.zoom = ZOOMS[st.zoom_i]
	clamp_scroll(st)
	note(st, fmt.tprintf("Zoom %d%%", int(st.zoom * 100 + 0.5)))
}

current_page :: proc(st: ^State) -> int {
	li := line_of(&st.lay, st.caret)
	if li >= 0 {
		return st.lay.lines[li].page + 1
	}
	return 1
}

// ---------------------------------------------------------------------------
// Files
// ---------------------------------------------------------------------------

set_path :: proc(st: ^State, path: string) {
	delete(st.path)
	st.path = strings.clone(path)
}

doc_title :: proc(st: ^State) -> string {
	if st.collab.on && st.collab.sess != nil && st.collab.sess.doc_title != "" {
		return st.collab.sess.doc_title
	}
	if st.path == "" {
		return "Untitled"
	}
	i := strings.last_index_byte(st.path, '/')
	return st.path[i + 1:]
}

replace_document :: proc(st: ^State, nd: Doc) {
	if st.collab.on {
		collab_note_edit(st, .Structural)
	}
	doc_destroy(&st.doc)
	st.doc = nd
	history_clear(&st.hist)
	st.caret = {}
	st.anchor = {}
	st.mark = false
	st.pending_on = false
	st.scroll = 0
	st.hscroll = 0
	st.dirty = true
	st.modified = false
	// The alerts belonged to the document that is gone. Keeping them would
	// draw squiggles over whatever text now happens to sit at those offsets.
	prose_clear_alerts(&st.prose)
	st.prose.ran = false
	st.prose.stale = true
}

do_save :: proc(st: ^State, path: string) {
	full := expand_home(path, context.temp_allocator)
	if doc_export(st, full, .Json, doc_title(st)) {
		set_path(st, full)
		st.modified = false
		note(st, fmt.tprintf("Saved %s", doc_title(st)))
	} else {
		note(st, fmt.tprintf("Could not write %s", full))
	}
}

do_open :: proc(st: ^State, path: string) {
	full := expand_home(path, context.temp_allocator)
	// The two formats that are read but not written in place: opening one
	// imports it and leaves the document pointing at a .json of the same
	// name, so a later Ctrl+S does not quietly overwrite the original.
	for imported in ([?]struct {
		ext:   string,
		label: string,
	}{
		{".md", "Markdown"},
		{".markdown", "Markdown"},
		{".docx", "Word document"},
		{".odt", "OpenDocument text"},
		{".rtf", "RTF document"},
	}) {
		if !strings.has_suffix(full, imported.ext) {
			continue
		}
		// The same reader `docs convert` and every other command uses.
		nd, ok := doc_read(full)
		if !ok {
			note(st, fmt.tprintf("Could not read %s", full))
			return
		}
		replace_document(st, nd)
		set_path(st, swap_ext(full, ".json", context.temp_allocator))
		st.modified = true
		note(st, fmt.tprintf("Imported %s", imported.label))
		return
	}
	nd, ok := doc_import(full, .Json)
	if !ok {
		note(st, fmt.tprintf("Could not read %s", full))
		return
	}
	replace_document(st, nd)
	set_path(st, full)
	note(st, fmt.tprintf("Opened %s", doc_title(st)))
}

default_path :: proc(st: ^State, ext: string) -> string {
	if st.path != "" {
		return swap_ext(st.path, ext, context.temp_allocator)
	}
	home := kit_home()
	return fmt.tprintf("%s/untitled%s", home, ext)
}

kit_home :: proc() -> string {
	h := os.get_env("HOME", context.temp_allocator)
	return h == "" ? "/tmp" : h
}
