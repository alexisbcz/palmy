// The keyboard. Everything this app can do has a key, and nothing needs a
// pointer — which is also what makes it drivable by the recording harness.
package main

import "core:strings"
import kit "kit:."
import p "palmy:."

// palmy names F1..F5 and F11; the rest are perfectly ordinary keysyms that
// libxkbcommon hands over, so they are named here rather than in the toolkit.
// Each one also has a Ctrl-letter twin, because when libxkbcommon is missing
// palmy falls back to a scancode table that stops at F5 — and because the
// offscreen harness drives text, not function keys.
KEY_F6 :: 0xffc3
KEY_F7 :: 0xffc4
KEY_F8 :: 0xffc5

plain :: proc(ui: ^p.Ctx, sym: u32) -> bool {
	for k in ui.input.keys {
		if k.sym == sym && !k.repeat && k.mods & {.Shift, .Ctrl, .Alt, .Super} == {} {
			return true
		}
	}
	return false
}

times :: proc(ui: ^p.Ctx, sym: u32) -> int {
	n := 0
	for k in ui.input.keys {
		if k.sym == sym && k.mods & {.Ctrl, .Alt, .Super} == {} {
			n += 1
		}
	}
	return n
}

field_edit :: proc(ui: ^p.Ctx, buf: ^[dynamic]u8, swallow: bool) -> bool {
	changed := false
	if !swallow {
		for b in transmute([]u8)p.typed_text(ui) {
			if b >= 0x20 && b != 0x7f {
				append(buf, b)
				changed = true
			}
		}
	}
	for _ in 0 ..< p.key_count(ui, p.KEY_BACKSPACE) {
		if len(buf) > 0 {
			n := 1
			for n < len(buf) && buf[len(buf) - n] & 0xc0 == 0x80 {
				n += 1
			}
			resize(buf, len(buf) - n)
			changed = true
		}
	}
	if p.shortcut(ui, 'u', {.Ctrl}) && len(buf) > 0 {
		clear(buf)
		changed = true
	}
	return changed
}

keys :: proc(ui: ^p.Ctx, nt: ^Notes, app: ^p.App) {
	// The file dialog owns the keyboard while it is up; it reads its own input
	// in `pick_overlay`, during the draw pass.
	if kit.pick_active(&nt.pick) {
		return
	}

	swallow := nt.swallow
	nt.swallow = false

	if p.shortcut(ui, 'q', {.Ctrl}) {
		nt.want_quit = true
		return
	}

	switch nt.mode {
	case .Help:
		if plain(ui, p.KEY_ESCAPE) || plain(ui, p.KEY_RETURN) || plain(ui, p.KEY_F1) {
			nt.mode = .Normal
		}
		return

	case .Rename:
		if plain(ui, p.KEY_ESCAPE) {
			nt.mode = .Normal
			return
		}
		if plain(ui, p.KEY_RETURN) {
			apply_rename(nt)
			nt.mode = .Normal
			return
		}
		field_edit(ui, &nt.rename, swallow)
		return

	case .Confirm_Delete:
		if plain(ui, p.KEY_ESCAPE) {
			nt.mode = .Normal
			return
		}
		if plain(ui, p.KEY_LEFT) || plain(ui, p.KEY_RIGHT) || plain(ui, p.KEY_TAB) {
			nt.sel_confirm = !nt.sel_confirm
		}
		if plain(ui, p.KEY_RETURN) || plain(ui, p.KEY_SPACE) {
			if nt.sel_confirm {
				destroy_selected(nt)
			}
			nt.mode = .Normal
		}
		return

	case .Styles:
		if plain(ui, p.KEY_ESCAPE) || plain(ui, KEY_F7) || p.shortcut(ui, 'p', {.Ctrl}) {
			nt.mode = .Normal
			return
		}
		if n := times(ui, p.KEY_DOWN); n > 0 {
			nt.pr.pick_sel = min(nt.pr.pick_sel + n, max(0, len(nt.pr.eng.packs) - 1))
		}
		if n := times(ui, p.KEY_UP); n > 0 {
			nt.pr.pick_sel = max(nt.pr.pick_sel - n, 0)
		}
		if plain(ui, p.KEY_RETURN) {
			prose_set_style(ui, nt, nt.pr.pick_sel, false)
			nt.mode = .Normal
			return
		}
		// A style can belong to one note: a letter to the bank is not a diary
		// entry, and neither wants the other's rules.
		if plain(ui, 'n') || plain(ui, 'N') {
			prose_set_style(ui, nt, nt.pr.pick_sel, true)
			nt.mode = .Normal
			return
		}
		if plain(ui, 'r') || plain(ui, 'R') {
			prose_undismiss_all(ui, nt)
			return
		}
		if plain(ui, '0') {
			nt.pr.on = false
			prose_clear(nt)
			nt.pr.show_report = false
			prose_conf_save(nt)
			nt.mode = .Normal
			note(nt, "Writing checks off")
			return
		}
		return

	case .Search:
		if plain(ui, p.KEY_ESCAPE) {
			if len(nt.query) > 0 {
				clear(&nt.query)
				refilter(nt)
			}
			nt.mode = .Normal
			nt.pane = .List
			return
		}
		if field_edit(ui, &nt.query, swallow) {
			nt.sel = 0
			refilter(nt)
		}
		if n := times(ui, p.KEY_DOWN); n > 0 {
			nt.sel = min(nt.sel + n, max(0, len(nt.vis) - 1))
			open_sel(nt)
		}
		if n := times(ui, p.KEY_UP); n > 0 {
			nt.sel = max(nt.sel - n, 0)
			open_sel(nt)
		}
		if plain(ui, p.KEY_RETURN) {
			open_sel(nt)
			nt.mode = .Normal
			nt.pane = .Editor
		}
		return

	case .Normal:
	}

	// ---- Global commands, all on keys the editor pane does not need ------
	if plain(ui, p.KEY_F1) {
		nt.mode = .Help
		nt.swallow = true
		return
	}
	if plain(ui, p.KEY_F2) {
		if _, ok := selected(nt); ok {
			clear(&nt.rename)
			append(&nt.rename, ..transmute([]u8)title_of(buf_line(&nt.buf, 0), context.temp_allocator))
			nt.mode = .Rename
			nt.swallow = true
		}
		return
	}
	if plain(ui, p.KEY_F3) {
		nt.preview = !nt.preview
		note(nt, nt.preview ? "Reading" : "Writing")
		return
	}
	if plain(ui, p.KEY_F4) {
		create(nt)
		return
	}
	if plain(ui, p.KEY_F5) {
		flush(nt)
		reload(nt)
		note(nt, tfmt("%d notes", len(nt.all)))
		return
	}
	// ---- The writing coach ----------------------------------------------
	if plain(ui, KEY_F6) || p.shortcut(ui, 'e', {.Ctrl}) {
		prose_show_report(nt, !nt.pr.show_report)
		return
	}
	if plain(ui, KEY_F7) || p.shortcut(ui, 'p', {.Ctrl}) {
		nt.mode = .Styles
		nt.pr.pick_sel = nt.pr.style
		nt.swallow = true
		return
	}
	if p.shortcut(ui, KEY_F8, {.Shift}) || p.shortcut(ui, 'g', {.Ctrl, .Shift}) ||
	   p.shortcut(ui, 'G', {.Ctrl, .Shift}) {
		prose_goto(ui, nt, false)
		return
	}
	if plain(ui, KEY_F8) || p.shortcut(ui, 'g', {.Ctrl}) {
		prose_goto(ui, nt, true)
		return
	}
	if p.shortcut(ui, '.', {.Ctrl}) || p.shortcut(ui, '>', {.Ctrl, .Shift}) {
		prose_apply(ui, nt)
		return
	}
	if p.shortcut(ui, 'd', {.Ctrl, .Shift}) || p.shortcut(ui, 'D', {.Ctrl, .Shift}) {
		prose_dismiss(ui, nt, true)
		return
	}
	if p.shortcut(ui, 'd', {.Ctrl}) {
		prose_dismiss(ui, nt, false)
		return
	}

	if p.shortcut(ui, 'o', {.Ctrl}) {
		begin_pick(nt, .Import)
		return
	}
	if p.shortcut(ui, 's', {.Ctrl, .Shift}) || p.shortcut(ui, 'S', {.Ctrl, .Shift}) {
		flush(nt)
		begin_pick(nt, .Export)
		return
	}
	if p.shortcut(ui, 's', {.Ctrl}) {
		flush(nt)
		note(nt, "Saved")
	}
	if p.shortcut(ui, 'f', {.Ctrl}) {
		nt.mode = .Search
		nt.pane = .List
		nt.swallow = true
		return
	}
	if plain(ui, p.KEY_TAB) {
		nt.pane = nt.pane == .List ? .Editor : .List
		nt.swallow = true
		return
	}
	if p.shortcut(ui, p.KEY_TAB, {.Shift}) {
		nt.pane = nt.pane == .List ? .Editor : .List
		nt.swallow = true
		return
	}

	if nt.pane == .List {
		list_keys(ui, nt)
		return
	}
	editor_keys(ui, nt, swallow)
}

list_keys :: proc(ui: ^p.Ctx, nt: ^Notes) {
	if n := times(ui, p.KEY_DOWN); n > 0 {
		nt.sel = min(nt.sel + n, max(0, len(nt.vis) - 1))
		open_sel(nt)
	}
	if n := times(ui, p.KEY_UP); n > 0 {
		nt.sel = max(nt.sel - n, 0)
		open_sel(nt)
	}
	if plain(ui, p.KEY_HOME) {
		nt.sel = 0
		open_sel(nt)
	}
	if plain(ui, p.KEY_END) {
		nt.sel = max(0, len(nt.vis) - 1)
		open_sel(nt)
	}
	if plain(ui, p.KEY_RETURN) || plain(ui, p.KEY_RIGHT) {
		open_sel(nt)
		nt.pane = .Editor
	}
	if plain(ui, p.KEY_DELETE) {
		if _, ok := selected(nt); ok {
			nt.mode = .Confirm_Delete
			nt.sel_confirm = false
		}
	}
	if plain(ui, '/') {
		nt.mode = .Search
		nt.swallow = true
	}
	if plain(ui, 'n') {
		create(nt)
	}
	if plain(ui, 'r') {
		if _, ok := selected(nt); ok {
			clear(&nt.rename)
			append(&nt.rename, ..transmute([]u8)title_of(buf_line(&nt.buf, 0), context.temp_allocator))
			nt.mode = .Rename
			nt.swallow = true
		}
	}
	if plain(ui, 'p') {
		nt.preview = !nt.preview
	}
	if plain(ui, p.KEY_ESCAPE) && len(nt.query) > 0 {
		clear(&nt.query)
		refilter(nt)
	}
}

// ---------------------------------------------------------------------------
// The editor pane
// ---------------------------------------------------------------------------

ed_sel :: proc(nt: ^Notes) -> (lo, hi: Pos, ok: bool) {
	if !nt.has_sel || pos_eq(nt.anchor, nt.cur) {
		return nt.cur, nt.cur, false
	}
	lo, hi = pos_order(nt.anchor, nt.cur)
	return lo, hi, true
}

ed_clear_sel :: proc(nt: ^Notes) {
	nt.has_sel = false
	nt.anchor = nt.cur
}

ed_begin_sel :: proc(nt: ^Notes, shift: bool) {
	if shift {
		if !nt.has_sel {
			nt.anchor = nt.cur
			nt.has_sel = true
		}
	} else {
		ed_clear_sel(nt)
	}
}

ed_delete_sel :: proc(ui: ^p.Ctx, nt: ^Notes) -> bool {
	lo, hi, ok := ed_sel(nt)
	if !ok {
		return false
	}
	nt.cur = buf_apply(&nt.buf, lo, hi, "", nt.cur, .No)
	ed_clear_sel(nt)
	touch(ui, nt)
	return true
}

ed_insert :: proc(ui: ^p.Ctx, nt: ^Notes, text: string, co := Coalesce.No) {
	lo, hi, ok := ed_sel(nt)
	if ok {
		nt.cur = buf_apply(&nt.buf, lo, hi, text, nt.cur, .No)
	} else {
		nt.cur = buf_apply(&nt.buf, nt.cur, nt.cur, text, nt.cur, co)
	}
	ed_clear_sel(nt)
	touch(ui, nt)
}

ed_visible :: proc(ui: ^p.Ctx, nt: ^Notes) {
	wrap_rebuild(&nt.wrap, ui, &nt.buf, nt.body_w, nt.rev)
	r := row_of(&nt.wrap, nt.cur)
	if r < nt.top {
		nt.top = r
	}
	if r >= nt.top + nt.rows {
		nt.top = r - nt.rows + 1
	}
	nt.top = clamp(nt.top, 0, max(0, len(nt.wrap.rows) - 1))
}

editor_keys :: proc(ui: ^p.Ctx, nt: ^Notes, swallow: bool) {
	wrap_rebuild(&nt.wrap, ui, &nt.buf, nt.body_w, nt.rev)

	if plain(ui, p.KEY_ESCAPE) {
		nt.pane = .List
		return
	}
	if w := p.wheel(ui).y; w != 0 {
		nt.top = clamp(nt.top - int(w * 3), 0, max(0, len(nt.wrap.rows) - 1))
	}

	if p.shortcut(ui, 'z', {.Ctrl}) {
		if cur, ok := buf_undo(&nt.buf); ok {
			nt.cur = cur
			ed_clear_sel(nt)
			touch(ui, nt)
		}
	}
	if p.shortcut(ui, 'y', {.Ctrl}) || p.shortcut(ui, 'z', {.Ctrl, .Shift}) {
		if cur, ok := buf_redo(&nt.buf); ok {
			nt.cur = cur
			ed_clear_sel(nt)
			touch(ui, nt)
		}
	}
	if p.shortcut(ui, 'a', {.Ctrl}) {
		nt.anchor = {0, 0}
		nt.cur = buf_end(&nt.buf)
		nt.has_sel = true
	}
	if p.shortcut(ui, 'c', {.Ctrl}) || p.shortcut(ui, 'x', {.Ctrl}) {
		lo, hi, ok := ed_sel(nt)
		if !ok {
			lo = Pos{nt.cur.line, 0}
			hi = Pos{nt.cur.line, len(buf_line(&nt.buf, nt.cur.line))}
		}
		text := buf_text(&nt.buf, lo, hi, context.temp_allocator)
		if kit.clipboard_set(text) {
			note(nt, tfmt("Copied %d bytes", len(text)))
		}
		if p.shortcut(ui, 'x', {.Ctrl}) {
			nt.cur = buf_apply(&nt.buf, lo, hi, "", nt.cur, .No)
			ed_clear_sel(nt)
			touch(ui, nt)
		}
	}
	if p.shortcut(ui, 'v', {.Ctrl}) {
		if text, ok := kit.clipboard_get(context.temp_allocator); ok && text != "" {
			ed_insert(ui, nt, text)
		}
	}

	// ---- Motion ---------------------------------------------------------
	moved_h, moved_v := false, false
	for k in ui.input.keys {
		if .Alt in k.mods || .Super in k.mods || .Ctrl in k.mods {
			continue
		}
		shift := .Shift in k.mods
		switch k.sym {
		case p.KEY_LEFT:
			ed_begin_sel(nt, shift)
			if nt.cur.col > 0 {
				nt.cur.col = rune_left(buf_line(&nt.buf, nt.cur.line), nt.cur.col)
			} else if nt.cur.line > 0 {
				nt.cur = {nt.cur.line - 1, len(buf_line(&nt.buf, nt.cur.line - 1))}
			}
			moved_h = true
		case p.KEY_RIGHT:
			ed_begin_sel(nt, shift)
			l := buf_line(&nt.buf, nt.cur.line)
			if nt.cur.col < len(l) {
				nt.cur.col = rune_right(l, nt.cur.col)
			} else if nt.cur.line + 1 < buf_lines(&nt.buf) {
				nt.cur = {nt.cur.line + 1, 0}
			}
			moved_h = true
		case p.KEY_UP:
			ed_begin_sel(nt, shift)
			r := row_of(&nt.wrap, nt.cur)
			if r > 0 {
				nt.cur = col_at(&nt.wrap, ui, &nt.buf, r - 1, nt.goal_x)
			}
			moved_v = true
		case p.KEY_DOWN:
			ed_begin_sel(nt, shift)
			r := row_of(&nt.wrap, nt.cur)
			if r + 1 < len(nt.wrap.rows) {
				nt.cur = col_at(&nt.wrap, ui, &nt.buf, r + 1, nt.goal_x)
			}
			moved_v = true
		case p.KEY_PAGE_UP:
			ed_begin_sel(nt, shift)
			r := max(0, row_of(&nt.wrap, nt.cur) - nt.rows)
			nt.cur = col_at(&nt.wrap, ui, &nt.buf, r, nt.goal_x)
			nt.top = max(0, nt.top - nt.rows)
			moved_v = true
		case p.KEY_PAGE_DOWN:
			ed_begin_sel(nt, shift)
			r := min(len(nt.wrap.rows) - 1, row_of(&nt.wrap, nt.cur) + nt.rows)
			nt.cur = col_at(&nt.wrap, ui, &nt.buf, r, nt.goal_x)
			nt.top = min(max(0, len(nt.wrap.rows) - 1), nt.top + nt.rows)
			moved_v = true
		case p.KEY_HOME:
			ed_begin_sel(nt, shift)
			row := nt.wrap.rows[row_of(&nt.wrap, nt.cur)]
			nt.cur = {row.line, row.from}
			moved_h = true
		case p.KEY_END:
			ed_begin_sel(nt, shift)
			row := nt.wrap.rows[row_of(&nt.wrap, nt.cur)]
			nt.cur = {row.line, row.to}
			moved_h = true
		}
	}
	if moved_h || moved_v {
		nt.cur = pos_clamp(&nt.buf, nt.cur)
		if moved_h {
			nt.goal_x = caret_x(&nt.wrap, ui, &nt.buf, nt.cur)
		}
		ed_visible(ui, nt)
		// Moving the caret onto a mark selects it, which is what makes the
		// explanation reachable from the keyboard alone.
		prose_select_at(nt)
	}

	// ---- Editing --------------------------------------------------------
	edited := false
	for _ in 0 ..< times(ui, p.KEY_BACKSPACE) {
		if ed_delete_sel(ui, nt) {
			edited = true
			continue
		}
		if nt.cur.col > 0 {
			l := buf_line(&nt.buf, nt.cur.line)
			from := Pos{nt.cur.line, rune_left(l, nt.cur.col)}
			nt.cur = buf_apply(&nt.buf, from, nt.cur, "", nt.cur, .Back)
		} else if nt.cur.line > 0 {
			prev := len(buf_line(&nt.buf, nt.cur.line - 1))
			nt.cur = buf_apply(&nt.buf, {nt.cur.line - 1, prev}, nt.cur, "", nt.cur, .Back)
		}
		touch(ui, nt)
		edited = true
	}
	for _ in 0 ..< times(ui, p.KEY_DELETE) {
		if ed_delete_sel(ui, nt) {
			edited = true
			continue
		}
		l := buf_line(&nt.buf, nt.cur.line)
		if nt.cur.col < len(l) {
			nt.cur = buf_apply(&nt.buf, nt.cur, {nt.cur.line, rune_right(l, nt.cur.col)}, "", nt.cur, .No)
		} else if nt.cur.line + 1 < buf_lines(&nt.buf) {
			nt.cur = buf_apply(&nt.buf, nt.cur, {nt.cur.line + 1, 0}, "", nt.cur, .No)
		}
		touch(ui, nt)
		edited = true
	}
	for _ in 0 ..< times(ui, p.KEY_RETURN) {
		// A list carries on by itself, and an empty item ends it.
		l := buf_line(&nt.buf, nt.cur.line)
		pre, empty_item := list_continue(l, nt.cur.col)
		if empty_item {
			// The item had no text: end the list instead of adding to it.
			nt.cur = buf_apply(&nt.buf, {nt.cur.line, 0}, {nt.cur.line, len(l)}, "", nt.cur, .No)
			touch(ui, nt)
			edited = true
			continue
		}
		ed_insert(ui, nt, tfmt("\n%s", pre))
		edited = true
	}
	if typed := p.typed_text(ui); len(typed) > 0 && !swallow {
		keep := make([dynamic]u8, 0, len(typed), context.temp_allocator)
		for b in transmute([]u8)typed {
			if b >= 0x20 && b != 0x7f {
				append(&keep, b)
			}
		}
		if len(keep) > 0 {
			ed_insert(ui, nt, string(keep[:]), .Type)
			edited = true
		}
	}
	if edited {
		nt.cur = pos_clamp(&nt.buf, nt.cur)
		wrap_rebuild(&nt.wrap, ui, &nt.buf, nt.body_w, nt.rev)
		nt.goal_x = caret_x(&nt.wrap, ui, &nt.buf, nt.cur)
		ed_visible(ui, nt)
	}
}
