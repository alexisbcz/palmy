// The keyboard, which is the whole interface for anyone who reads with one.
//
// Every action has a key, nothing needs the mouse, and the two kinds of book
// get the keys that make sense for them: a reflowable book has type size and
// line height, a fixed one has zoom and fit, and neither pretends to have the
// other's.
//
// `key_count` rather than `key_pressed` wherever one press must equal one
// step. Several presses arrive in one frame under synthetic input — a driver
// script types far faster than a person — and `key_pressed` collapses them to
// a single `true`, so a recorded demo would turn one page for two taps.
package main

import "core:strings"
import p "palmy:."

reader_keys :: proc(r: ^Reader, ui: ^p.Ctx) {
	// Always available.
	if p.shortcut(ui, 'q', {.Ctrl}) {
		p.quit_app(r.app)
		return
	}
	if p.shortcut(ui, 'o', {.Ctrl}) {
		reader_pick(r)
		return
	}

	// While the search field has focus, the only keys we take are the ones it
	// does not: Escape, Enter and the result stepping.
	if r.panel == .Search {
		if p.key_pressed(ui, p.KEY_ESCAPE, false) {
			r.panel = .None
			r.pd.hit_block = -1
			return
		}
		if p.key_pressed(ui, p.KEY_RETURN, false) {
			if len(r.search.hits) == 0 {
				reader_run_search(r)
			} else {
				reader_show_hit(r, (r.search.sel + 1) % len(r.search.hits))
			}
			return
		}
		if n := p.key_count(ui, p.KEY_DOWN); n > 0 && len(r.search.hits) > 0 {
			reader_show_hit(r, clamp(r.search.sel + n, 0, len(r.search.hits) - 1))
			return
		}
		if n := p.key_count(ui, p.KEY_UP); n > 0 && len(r.search.hits) > 0 {
			reader_show_hit(r, clamp(r.search.sel - n, 0, len(r.search.hits) - 1))
			return
		}
		// Anything else is typing into the field.
		return
	}

	switch r.view {
	case .Library:
		library_keys(r, ui)
	case .Reading:
		reading_keys(r, ui)
	}
}

// ---------------------------------------------------------------------------
// Library
// ---------------------------------------------------------------------------

library_keys :: proc(r: ^Reader, ui: ^p.Ctx) {
	n := len(r.lib.books)
	if n == 0 {
		if p.key_pressed(ui, p.KEY_RETURN, false) {
			reader_pick(r)
		}
		return
	}
	// The grid is a wrapped row, so a column count has to be guessed from the
	// window to make Up and Down mean what they look like.
	win := p.size(ui)
	cols := max(1, int((win.x - 40) / (LIB_CARD_W + 16)))

	if k := p.key_count(ui, p.KEY_RIGHT); k > 0 {
		r.lib_sel = clamp(r.lib_sel + k, 0, n - 1)
	}
	if k := p.key_count(ui, p.KEY_LEFT); k > 0 {
		r.lib_sel = clamp(r.lib_sel - k, 0, n - 1)
	}
	if k := p.key_count(ui, p.KEY_DOWN); k > 0 {
		r.lib_sel = clamp(r.lib_sel + k * cols, 0, n - 1)
	}
	if k := p.key_count(ui, p.KEY_UP); k > 0 {
		r.lib_sel = clamp(r.lib_sel - k * cols, 0, n - 1)
	}
	if p.key_pressed(ui, p.KEY_HOME, false) {
		r.lib_sel = 0
	}
	if p.key_pressed(ui, p.KEY_END, false) {
		r.lib_sel = n - 1
	}
	if p.key_pressed(ui, p.KEY_RETURN, false) || p.key_pressed(ui, p.KEY_SPACE, false) {
		e := r.lib.books[clamp(r.lib_sel, 0, n - 1)]
		if e.missing {
			reader_say(r, tfmt("%s is no longer at that path", path_base(e.path)))
		} else {
			r.open_next = strings.clone(e.path)
		}
	}
	if p.key_pressed(ui, p.KEY_DELETE, false) {
		// Removes it from the library; the file itself is never touched.
		if r.lib_sel >= 0 && r.lib_sel < n {
			name := strings.clone(r.lib.books[r.lib_sel].title, context.temp_allocator)
			if r.book.open && r.lib.books[r.lib_sel].path == r.book.path {
				book_close(&r.book)
				r.cur = -1
			}
			library_remove(&r.lib, r.lib_sel)
			r.lib_sel = clamp(r.lib_sel, 0, max(0, len(r.lib.books) - 1))
			_ = library_save(&r.lib)
			reader_say(r, tfmt("Removed %s from the library (the file is untouched)", name))
		}
	}
	if p.key_pressed(ui, p.KEY_ESCAPE, false) && r.book.open {
		r.view = .Reading
	}
}

// ---------------------------------------------------------------------------
// Reading
// ---------------------------------------------------------------------------

reading_keys :: proc(r: ^Reader, ui: ^p.Ctx) {
	if p.key_pressed(ui, p.KEY_ESCAPE, false) {
		if r.panel != .None {
			r.panel = .None
		} else if r.sel_block >= 0 {
			r.sel_block = -1
		} else {
			reader_close_book(r)
		}
		return
	}

	// Panels take the arrow keys when one is open, so the page does not move
	// under the list the reader is navigating.
	if r.panel == .Toc {
		toc := book_toc(&r.book)
		if len(toc) > 0 {
			if k := p.key_count(ui, p.KEY_DOWN); k > 0 {
				r.toc_sel = clamp(r.toc_sel + k, 0, len(toc) - 1)
			}
			if k := p.key_count(ui, p.KEY_UP); k > 0 {
				r.toc_sel = clamp(r.toc_sel - k, 0, len(toc) - 1)
			}
			if p.key_pressed(ui, p.KEY_RETURN, false) {
				e := toc[clamp(r.toc_sel, 0, len(toc) - 1)]
				if format_is_reflowable(r.book.format) {
					if e.block >= 0 {
						reader_goto_block(r, e.block)
						r.panel = .None
					}
				} else {
					reader_goto_page(r, e.block)
					r.panel = .None
				}
			}
		}
	} else if r.panel == .Marks && r.cur >= 0 {
		marks := r.lib.books[r.cur].marks[:]
		if len(marks) > 0 {
			if k := p.key_count(ui, p.KEY_DOWN); k > 0 {
				r.mark_sel = clamp(r.mark_sel + k, 0, len(marks) - 1)
			}
			if k := p.key_count(ui, p.KEY_UP); k > 0 {
				r.mark_sel = clamp(r.mark_sel - k, 0, len(marks) - 1)
			}
			if p.key_pressed(ui, p.KEY_RETURN, false) {
				m := marks[clamp(r.mark_sel, 0, len(marks) - 1)]
				if format_is_reflowable(r.book.format) {
					reader_goto_block(r, m.block)
				} else {
					reader_goto_page(r, m.page)
				}
				r.panel = .None
			}
		}
	} else {
		// Page turning.
		fwd := p.key_count(ui, p.KEY_RIGHT) + p.key_count(ui, p.KEY_PAGE_DOWN) +
			p.key_count(ui, p.KEY_SPACE) + p.key_count(ui, 'j')
		back := p.key_count(ui, p.KEY_LEFT) + p.key_count(ui, p.KEY_PAGE_UP) + p.key_count(ui, 'k')
		if fwd > 0 {
			reader_turn(r, fwd)
		}
		if back > 0 {
			reader_turn(r, -back)
		}
		if r.set.mode == .Continuous || !format_is_reflowable(r.book.format) {
			if d := p.key_count(ui, p.KEY_DOWN); d > 0 {
				reader_scroll(r, ui, f32(d) * 72)
			}
			if u := p.key_count(ui, p.KEY_UP); u > 0 {
				reader_scroll(r, ui, -f32(u) * 72)
			}
		} else {
			if d := p.key_count(ui, p.KEY_DOWN); d > 0 {
				reader_turn(r, d)
			}
			if u := p.key_count(ui, p.KEY_UP); u > 0 {
				reader_turn(r, -u)
			}
		}
		if p.key_pressed(ui, p.KEY_HOME, false) {
			if format_is_reflowable(r.book.format) {
				r.chapter = 0
				r.page = 0
				r.scroll_y = 0
				r.scroll_dirty = true
			} else {
				reader_goto_page(r, 1)
			}
		}
		if p.key_pressed(ui, p.KEY_END, false) {
			if format_is_reflowable(r.book.format) {
				r.chapter = max(0, len(r.book.doc.chapters) - 1)
				cl := reflow_chapter(&r.book.reflow, &r.book.doc, r.chapter)
				r.page = max(0, cl.pages - 1)
				r.scroll_y = max(0, cl.height - r.col_h)
				r.scroll_dirty = true
			} else {
				reader_goto_page(r, r.book.fixed.pages)
			}
		}
	}

	// Chapter or outline stepping, always available.
	if n := p.key_count(ui, ']'); n > 0 {
		reader_chapter_step(r, n)
	}
	if n := p.key_count(ui, '['); n > 0 {
		reader_chapter_step(r, -n)
	}

	// Panels.
	if p.key_pressed(ui, 't', false) || p.key_pressed(ui, 'c', false) {
		reader_toggle_panel(r, .Toc)
	}
	if p.key_pressed(ui, '/', false) || p.shortcut(ui, 'f', {.Ctrl}) {
		reader_toggle_panel(r, .Search)
	}
	if p.key_pressed(ui, 'b', false) {
		reader_toggle_bookmark(r)
	}
	if p.key_pressed(ui, 'h', false) {
		reader_highlight(r)
	}
	if p.key_pressed(ui, 'l', false) {
		reader_toggle_panel(r, .Marks)
	}
	if p.key_pressed(ui, 's', false) {
		reader_toggle_panel(r, .Settings)
	}
	if p.key_pressed(ui, 'g', false) {
		reader_close_book(r)
		return
	}

	// Theme.
	if p.key_pressed(ui, '1', false) {
		reader_set_theme(r, .Light)
	}
	if p.key_pressed(ui, '2', false) {
		reader_set_theme(r, .Sepia)
	}
	if p.key_pressed(ui, '3', false) {
		reader_set_theme(r, .Dark)
	}

	if format_is_reflowable(r.book.format) {
		// Type size: both the shifted and unshifted keys, because '+' needs
		// Shift on most layouts and nobody wants to care.
		if n := p.key_count(ui, '+') + p.key_count(ui, '='); n > 0 {
			reader_set_size(r, f32(n))
		}
		if n := p.key_count(ui, '-') + p.key_count(ui, '_'); n > 0 {
			reader_set_size(r, -f32(n))
		}
		if p.key_pressed(ui, 'm', false) {
			reader_set_mode(r, r.set.mode == .Paged ? .Continuous : .Paged)
		}
		if p.key_pressed(ui, 'i', false) {
			reader_set_para(r, r.set.para == .Indented ? .Spaced : .Indented)
		}
		if p.key_pressed(ui, 'u', false) {
			reader_set_justify(r, !r.set.justify)
		}
		if n := p.key_count(ui, '>') + p.key_count(ui, '.'); n > 0 {
			reader_set_line(r, 0.06 * f32(n))
		}
		if n := p.key_count(ui, '<') + p.key_count(ui, ','); n > 0 {
			reader_set_line(r, -0.06 * f32(n))
		}
	} else {
		if n := p.key_count(ui, '+') + p.key_count(ui, '='); n > 0 {
			reader_zoom(r, 1.25)
		}
		if n := p.key_count(ui, '-') + p.key_count(ui, '_'); n > 0 {
			reader_zoom(r, 1 / 1.25)
		}
		if p.key_pressed(ui, 'w', false) {
			reader_set_fit(r, .Width)
		}
		if p.key_pressed(ui, 'f', false) {
			reader_set_fit(r, .Page)
		}
	}

	// The wheel scrolls in continuous and fixed modes (palmy's own scroll
	// container handles it), and turns pages in paged mode.
	if r.set.mode == .Paged && format_is_reflowable(r.book.format) {
		w := p.wheel(ui)
		if w.y > 8 {
			reader_turn(r, 1)
		} else if w.y < -8 {
			reader_turn(r, -1)
		}
	}
}

reader_scroll :: proc(r: ^Reader, ui: ^p.Ctx, dy: f32) {
	if r.view_id != 0 {
		p.scroll_nudge(ui, r.view_id, {0, dy})
	}
	if format_is_reflowable(r.book.format) && r.set.mode == .Continuous {
		cl := reflow_chapter(&r.book.reflow, &r.book.doc, r.chapter)
		r.scroll_y = clamp(r.scroll_y + dy, 0, max(0, cl.height - r.col_h))
	}
}
