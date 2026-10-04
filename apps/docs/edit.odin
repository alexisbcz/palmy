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
	b := strings.builder_make(alloc)
	for pi in lo.para ..= hi.para {
		pa := &st.doc.paras[pi]
		t := para_text(pa, context.temp_allocator)
		a := pi == lo.para ? lo.off : 0
		z := pi == hi.para ? hi.off : len(t)
		if pi > lo.para {
			strings.write_byte(&b, '\n')
		}
		strings.write_string(&b, t[clamp(a, 0, len(t)):clamp(z, 0, len(t))])
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
	for pi in lo.para ..= hi.para {
		src := &st.doc.paras[pi]
		n := para_len(src)
		a := pi == lo.para ? lo.off : 0
		z := pi == hi.para ? hi.off : n
		cp := para_clone(src)
		// Trim the clone down to the selected span.
		if z < n {
			k := split_at(&cp, z)
			for i in k ..< len(cp.runs) {
				delete(cp.runs[i].text)
			}
			resize(&cp.runs, k)
		}
		if a > 0 {
			k := split_at(&cp, a)
			for i in 0 ..< k {
				delete(cp.runs[i].text)
			}
			remove_range(&cp.runs, 0, k)
		}
		normalise(&cp)
		append(&out.paras, cp)
	}
	return out
}

insert_doc :: proc(d: ^Doc, at: Pos, src: ^Doc) -> Pos {
	q := at
	for pi in 0 ..< len(src.paras) {
		sp := &src.paras[pi]
		if pi > 0 {
			q = break_para(d, q)
			tp := &d.paras[q.para]
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
	history_begin(&st.hist, &st.doc, st.caret, st.anchor, kind)
	st.modified = true
	st.dirty = true
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
		t := para_text(&st.doc.paras[st.caret.para], context.temp_allocator)
		prev := rune_before(t, st.caret.off)
		st.caret = delete_range(&st.doc, Pos{st.caret.para, prev}, st.caret)
		st.anchor = st.caret
	} else {
		// At the head of a paragraph, Backspace peels off its formatting
		// before it joins the paragraph above — the same order Word uses.
		pa := &st.doc.paras[st.caret.para]
		if pa.break_before {
			edit_begin(st, .Structural)
			st.doc.paras[st.caret.para].break_before = false
		} else if pa.list != .None || pa.depth > 0 {
			edit_begin(st, .Structural)
			pa = &st.doc.paras[st.caret.para]
			if pa.depth > 0 {
				pa.depth -= 1
			} else {
				pa.list = .None
			}
		} else if pa.kind != .Body {
			edit_begin(st, .Structural)
			st.doc.paras[st.caret.para].kind = .Body
		} else if st.caret.para > 0 {
			edit_begin(st, .Structural)
			st.caret = merge_para(&st.doc, st.caret.para - 1)
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
	pa := &st.doc.paras[st.caret.para]
	n := para_len(pa)
	if st.caret.off < n {
		edit_begin(st, .Deleting)
		t := para_text(&st.doc.paras[st.caret.para], context.temp_allocator)
		next := rune_after(t, st.caret.off)
		st.caret = delete_range(&st.doc, st.caret, Pos{st.caret.para, next})
		st.anchor = st.caret
	} else if st.caret.para + 1 < len(st.doc.paras) {
		edit_begin(st, .Structural)
		st.caret = merge_para(&st.doc, st.caret.para)
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

move_h :: proc(st: ^State, dir: int, extend: bool, by_word := false) {
	q := st.caret
	// A plain left/right with a selection collapses to its edge.
	if !extend && !st.mark && has_selection(st) && !by_word {
		lo, hi, _ := selection(st)
		place_caret(st, dir < 0 ? lo : hi, false)
		st.goal_ok = false
		return
	}
	t := para_text(&st.doc.paras[q.para], context.temp_allocator)
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
		} else if q.para > 0 {
			q.para -= 1
			q.off = para_len(&st.doc.paras[q.para])
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
		} else if q.para + 1 < len(st.doc.paras) {
			q.para += 1
			q.off = 0
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
	t := clamp(li + delta, 0, len(st.lay.lines) - 1)
	if t == li {
		// Already at the top or bottom: go to the very start or end.
		q := delta < 0 ? Pos{0, 0} : doc_end(&st.doc)
		place_caret(st, q, extend)
		st.goal_ok = false
		return
	}
	l := st.lay.lines[t]
	q := Pos{l.para, off_at_x(&st.lay, t, st.goal_x)}
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
	q := Pos{l.para, to_end ? (l.last ? l.end : l.vis_end) : l.start}
	place_caret(st, q, extend)
	st.goal_ok = false
}

select_all :: proc(st: ^State) {
	st.anchor = Pos{0, 0}
	st.caret = doc_end(&st.doc)
	st.mark = false
	history_break(&st.hist)
}

select_word :: proc(st: ^State) {
	t := para_text(&st.doc.paras[st.caret.para], context.temp_allocator)
	lo, hi := word_bounds(t, st.caret.off)
	st.anchor = Pos{st.caret.para, lo}
	st.caret = Pos{st.caret.para, hi}
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

sel_paras :: proc(st: ^State) -> (lo, hi: int) {
	a, b, _ := selection(st)
	return a.para, b.para
}

set_kind :: proc(st: ^State, k: Para_Kind) {
	lo, hi := sel_paras(st)
	edit_begin(st, .Structural)
	for i in lo ..= hi {
		st.doc.paras[i].kind = k
		if k == .Code {
			st.doc.paras[i].list = .None
		}
	}
	history_break(&st.hist)
}

cycle_kind :: proc(st: ^State) {
	cur := st.doc.paras[st.caret.para].kind
	next := Para_Kind((int(cur) + 1) % len(Para_Kind))
	set_kind(st, next)
	note(st, fmt.tprintf("Style: %s", kind_label(next)))
}

set_align :: proc(st: ^State, a: Align) {
	lo, hi := sel_paras(st)
	edit_begin(st, .Structural)
	for i in lo ..= hi {
		st.doc.paras[i].align = a
	}
	history_break(&st.hist)
}

cycle_align :: proc(st: ^State) {
	cur := st.doc.paras[st.caret.para].align
	next := Align((int(cur) + 1) % len(Align))
	set_align(st, next)
	note(st, fmt.tprintf("Align: %v", next))
}

set_list :: proc(st: ^State, l: List_Kind) {
	lo, hi := sel_paras(st)
	edit_begin(st, .Structural)
	on := st.doc.paras[st.caret.para].list == l
	for i in lo ..= hi {
		st.doc.paras[i].list = on ? .None : l
		if !on && st.doc.paras[i].kind == .Code {
			st.doc.paras[i].kind = .Body
		}
	}
	history_break(&st.hist)
}

indent_paras :: proc(st: ^State, delta: int) {
	lo, hi := sel_paras(st)
	edit_begin(st, .Structural)
	for i in lo ..= hi {
		st.doc.paras[i].depth = clamp(st.doc.paras[i].depth + delta, 0, 6)
	}
	history_break(&st.hist)
}

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

// index_fold is a case-insensitive substring search over ASCII, which is what
// a find box wants by default.
index_fold :: proc(hay, needle: string) -> int {
	if len(needle) == 0 || len(needle) > len(hay) {
		return -1
	}
	for i in 0 ..= len(hay) - len(needle) {
		ok := true
		for j in 0 ..< len(needle) {
			if lower(hay[i + j]) != lower(needle[j]) {
				ok = false
				break
			}
		}
		if ok {
			return i
		}
	}
	return -1
}

find_from :: proc(st: ^State, from: Pos) -> (lo, hi: Pos, ok: bool) {
	needle := string(st.find[:])
	if len(needle) == 0 {
		return {}, {}, false
	}
	n := len(st.doc.paras)
	for step in 0 ..= n {
		pi := (from.para + step) % n
		t := para_text(&st.doc.paras[pi], context.temp_allocator)
		start := step == 0 ? clamp(from.off, 0, len(t)) : 0
		i := index_fold(t[start:], needle)
		if i >= 0 {
			a := start + i
			return Pos{pi, a}, Pos{pi, a + len(needle)}, true
		}
	}
	return {}, {}, false
}

count_hits :: proc(st: ^State) -> int {
	needle := string(st.find[:])
	if len(needle) == 0 {
		return 0
	}
	n := 0
	for &pa in st.doc.paras {
		t := para_text(&pa, context.temp_allocator)
		at := 0
		for {
			i := index_fold(t[at:], needle)
			if i < 0 {
				break
			}
			n += 1
			at += i + len(needle)
			if at > len(t) {
				break
			}
		}
	}
	return n
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
	if !has || lo.para != hi.para || len(st.find) == 0 {
		return false
	}
	t := para_text(&st.doc.paras[lo.para], context.temp_allocator)
	if hi.off > len(t) || hi.off - lo.off != len(st.find) {
		return false
	}
	return index_fold(t[lo.off:hi.off], string(st.find[:])) == 0
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
	edit_begin(st, .Structural)
	drop_selection(st)
	st.caret = insert_text(&st.doc, st.caret, string(st.repl[:]), cs)
	st.anchor = st.caret
	history_break(&st.hist)
	find_next(st)
	note(st, "Replaced")
}

replace_all :: proc(st: ^State) {
	if len(st.find) == 0 {
		return
	}
	needle := string(st.find[:])
	repl := strings.clone(string(st.repl[:]), context.temp_allocator)
	edit_begin(st, .Structural)
	count := 0
	for pi in 0 ..< len(st.doc.paras) {
		// Search forward from just past each replacement, so a replacement
		// that contains the search term cannot be matched again.
		at := 0
		for {
			t := para_text(&st.doc.paras[pi], context.temp_allocator)
			if at > len(t) {
				break
			}
			i := index_fold(t[at:], needle)
			if i < 0 {
				break
			}
			abs := at + i
			cs := style_after(&st.doc, Pos{pi, abs})
			delete_range(&st.doc, Pos{pi, abs}, Pos{pi, abs + len(needle)})
			insert_plain(&st.doc, Pos{pi, abs}, repl, cs)
			at = abs + len(repl)
			count += 1
		}
	}
	st.caret = pos_clamp(&st.doc, st.caret)
	st.anchor = st.caret
	history_break(&st.hist)
	st.dirty = true
	note(st, fmt.tprintf("Replaced %d occurrence%s", count, count == 1 ? "" : "s"))
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
	if st.path == "" {
		return "Untitled"
	}
	i := strings.last_index_byte(st.path, '/')
	return st.path[i + 1:]
}

replace_document :: proc(st: ^State, nd: Doc) {
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
}

do_save :: proc(st: ^State, path: string) {
	full := expand_home(path, context.temp_allocator)
	if save_doc(&st.doc, full) {
		set_path(st, full)
		st.modified = false
		note(st, fmt.tprintf("Saved %s", doc_title(st)))
	} else {
		note(st, fmt.tprintf("Could not write %s", full))
	}
}

do_open :: proc(st: ^State, path: string) {
	full := expand_home(path, context.temp_allocator)
	if strings.has_suffix(full, ".md") || strings.has_suffix(full, ".markdown") {
		nd, ok := import_markdown(full)
		if !ok {
			note(st, fmt.tprintf("Could not read %s", full))
			return
		}
		replace_document(st, nd)
		set_path(st, swap_ext(full, ".json", context.temp_allocator))
		st.modified = true
		note(st, "Imported Markdown")
		return
	}
	nd, ok := load_doc(full)
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
