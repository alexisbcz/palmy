// A single-line editor with a selection, for the omnibox and every other
// field in the chrome.
//
// palmy's text_field has a caret but no selection, and an address bar is the
// one field where select-all-on-focus is the expected behaviour: Ctrl+L, type,
// and what was there is gone. So the browser owns this small model -- buffer,
// caret, anchor -- and draws it with palmy primitives.
package browser

import "core:strings"
import "core:unicode/utf8"
import kit "kit:."
import p "palmy:."

Line_Edit :: struct {
	buf:    [dynamic]u8,
	caret:  int,
	anchor: int, // == caret when nothing is selected
	scroll: f32,
}

edit_text :: proc(e: ^Line_Edit) -> string {
	return string(e.buf[:])
}

edit_set :: proc(e: ^Line_Edit, s: string, select_all := false) {
	clear(&e.buf)
	append(&e.buf, ..transmute([]u8)s)
	e.caret = len(e.buf)
	e.anchor = select_all ? 0 : e.caret
	e.scroll = 0
}

edit_has_selection :: proc(e: ^Line_Edit) -> bool {
	return e.caret != e.anchor
}

edit_range :: proc(e: ^Line_Edit) -> (lo, hi: int) {
	return min(e.caret, e.anchor), max(e.caret, e.anchor)
}

edit_selected :: proc(e: ^Line_Edit) -> string {
	lo, hi := edit_range(e)
	return string(e.buf[lo:hi])
}

@(private = "file")
delete_selection :: proc(e: ^Line_Edit) -> bool {
	lo, hi := edit_range(e)
	if lo == hi {
		return false
	}
	remove_range(&e.buf, lo, hi)
	e.caret = lo
	e.anchor = lo
	return true
}

edit_insert :: proc(e: ^Line_Edit, s: string) {
	delete_selection(e)
	clean := s
	if strings.contains_any(s, "\n\r\t") {
		r, _ := strings.replace_all(s, "\n", " ", context.temp_allocator)
		r, _ = strings.replace_all(r, "\r", "", context.temp_allocator)
		r, _ = strings.replace_all(r, "\t", " ", context.temp_allocator)
		clean = r
	}
	inject_at_elems(&e.buf, e.caret, ..transmute([]u8)clean)
	e.caret += len(clean)
	e.anchor = e.caret
}

@(private = "file")
prev_rune :: proc(b: []u8, at: int) -> int {
	i := at - 1
	for i > 0 && (b[i] & 0xc0) == 0x80 {
		i -= 1
	}
	return max(i, 0)
}

@(private = "file")
next_rune :: proc(b: []u8, at: int) -> int {
	if at >= len(b) {
		return len(b)
	}
	_, n := utf8.decode_rune(b[at:])
	return at + max(n, 1)
}

@(private = "file")
is_word :: proc(c: u8) -> bool {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c >= 0x80
}

@(private = "file")
word_left :: proc(b: []u8, at: int) -> int {
	i := at
	for i > 0 && !is_word(b[i - 1]) {
		i -= 1
	}
	for i > 0 && is_word(b[i - 1]) {
		i -= 1
	}
	return i
}

@(private = "file")
word_right :: proc(b: []u8, at: int) -> int {
	i := at
	for i < len(b) && !is_word(b[i]) {
		i += 1
	}
	for i < len(b) && is_word(b[i]) {
		i += 1
	}
	return i
}

Edit_Result :: struct {
	changed:   bool,
	submitted: bool, // Enter
	alt_enter: bool, // Alt+Enter: open in a new tab
	escaped:   bool,
	up, down:  int, // arrow presses, for a suggestion list
	tab:       bool,
}

// edit_keys applies this frame's typing to the editor. Call it only while the
// field has focus.
edit_keys :: proc(ui: ^p.Ctx, e: ^Line_Edit) -> (r: Edit_Result) {
	for k in ui.input.keys {
		shift := .Shift in k.mods
		ctrl := .Ctrl in k.mods
		switch k.sym {
		case p.KEY_LEFT:
			if !shift && edit_has_selection(e) {
				lo, _ := edit_range(e)
				e.caret = lo
			} else {
				e.caret = ctrl ? word_left(e.buf[:], e.caret) : prev_rune(e.buf[:], e.caret)
			}
			if !shift {e.anchor = e.caret}
		case p.KEY_RIGHT:
			if !shift && edit_has_selection(e) {
				_, hi := edit_range(e)
				e.caret = hi
			} else {
				e.caret = ctrl ? word_right(e.buf[:], e.caret) : next_rune(e.buf[:], e.caret)
			}
			if !shift {e.anchor = e.caret}
		case p.KEY_HOME:
			e.caret = 0
			if !shift {e.anchor = 0}
		case p.KEY_END:
			e.caret = len(e.buf)
			if !shift {e.anchor = e.caret}
		case p.KEY_BACKSPACE:
			if !delete_selection(e) && e.caret > 0 {
				from := ctrl ? word_left(e.buf[:], e.caret) : prev_rune(e.buf[:], e.caret)
				remove_range(&e.buf, from, e.caret)
				e.caret = from
				e.anchor = from
			}
			r.changed = true
		case p.KEY_DELETE:
			if !delete_selection(e) && e.caret < len(e.buf) {
				to := ctrl ? word_right(e.buf[:], e.caret) : next_rune(e.buf[:], e.caret)
				remove_range(&e.buf, e.caret, to)
			}
			r.changed = true
		case p.KEY_RETURN, p.KEY_KP_ENTER:
			if .Alt in k.mods {
				r.alt_enter = true
			} else {
				r.submitted = true
			}
		case p.KEY_ESCAPE:
			r.escaped = true
		case p.KEY_UP:
			r.up += 1
		case p.KEY_DOWN:
			r.down += 1
		case p.KEY_TAB:
			r.tab = true
		case 'a', 'A':
			if ctrl {
				e.anchor = 0
				e.caret = len(e.buf)
			}
		case 'c', 'C':
			if ctrl && edit_has_selection(e) {
				kit.clipboard_set(edit_selected(e))
			}
		case 'x', 'X':
			if ctrl && edit_has_selection(e) {
				kit.clipboard_set(edit_selected(e))
				delete_selection(e)
				r.changed = true
			}
		case 'v', 'V':
			if ctrl {
				if text, ok := kit.clipboard_get(context.temp_allocator); ok {
					edit_insert(e, text)
					r.changed = true
				}
			}
		case 'u', 'U':
			if ctrl {
				edit_set(e, "")
				r.changed = true
			}
		}
	}
	if .Ctrl not_in ui.input.mods && .Alt not_in ui.input.mods {
		if typed := p.typed_text(ui); typed != "" {
			edit_insert(e, typed)
			r.changed = true
		}
	}
	return
}

// edit_draw draws the field's text, selection and caret into the current
// element, which should be a row with `overflow-hidden`. `size` is the text
// size the class uses.
edit_draw :: proc(ui: ^p.Ctx, e: ^Line_Edit, focused: bool, placeholder: string, class: string, size: f32, width: f32) {
	text := edit_text(e)
	if text == "" {
		if focused {
			caret(ui, size)
		}
		if placeholder != "" {
			p.text(ui, placeholder, p.concat(ui, class, " text-muted-foreground whitespace-nowrap"))
			p.style(ui).shrink = 0
		}
		return
	}
	// keep the caret in view: scroll so it sits inside the box
	cx := p.text_width_upto(ui.fonts, text, e.caret, size)
	if width > 24 {
		if cx - e.scroll > width - 12 {
			e.scroll = cx - width + 12
		}
		if cx - e.scroll < 0 {
			e.scroll = max(cx - 24, 0)
		}
		total := p.text_width(ui.fonts, text, size)
		if total - e.scroll < width - 12 {
			e.scroll = max(total - width + 12, 0)
		}
	}
	inner := p.row(ui, "items-center shrink-0")
	p.style(ui, inner).margin[p.LEFT] = -e.scroll
	defer p.end(ui)
	lo, hi := edit_range(e)
	run :: proc(ui: ^p.Ctx, s, class: string) {
		if s != "" {
			p.text(ui, s, p.concat(ui, class, " whitespace-nowrap"))
			p.style(ui).shrink = 0
		}
	}
	if !focused || lo == hi {
		if focused {
			run(ui, text[:e.caret], class)
			caret(ui, size)
			run(ui, text[e.caret:], class)
		} else {
			run(ui, text, class)
		}
		return
	}
	run(ui, text[:lo], class)
	if e.caret == lo {caret(ui, size)}
	sel := p.row(ui, "items-center rounded-[2] bg-primary/20 shrink-0")
	_ = sel
	run(ui, text[lo:hi], class)
	p.end(ui)
	if e.caret == hi {caret(ui, size)}
	run(ui, text[hi:], class)
}

@(private = "file")
caret :: proc(ui: ^p.Ctx, size: f32) {
	if p.caret_on(ui) {
		idx := p.div(ui, "w-px bg-foreground shrink-0")
		p.style(ui, idx).h = p.px(size + 3)
		p.end(ui)
	} else {
		idx := p.div(ui, "w-px shrink-0")
		p.style(ui, idx).h = p.px(size + 3)
		p.end(ui)
	}
}
