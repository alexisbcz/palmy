// The keyboard. Pointer clicks work too, but nothing requires them.
package main

import p "palmy:."

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

with_shift :: proc(ui: ^p.Ctx, sym: u32) -> bool {
	for k in ui.input.keys {
		if k.sym == sym && .Shift in k.mods {
			return true
		}
	}
	return false
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

keys :: proc(ui: ^p.Ctx, c: ^Cal, app: ^p.App) {
	swallow := c.swallow
	c.swallow = false

	if p.shortcut(ui, 'q', {.Ctrl}) {
		c.want_quit = true
		return
	}

	switch c.mode {
	case .Help:
		if plain(ui, p.KEY_ESCAPE) || plain(ui, p.KEY_RETURN) || plain(ui, p.KEY_F1) {
			c.mode = .Normal
		}
		return

	case .Confirm_Delete:
		if plain(ui, p.KEY_ESCAPE) {
			c.mode = .Normal
			return
		}
		if plain(ui, p.KEY_LEFT) || plain(ui, p.KEY_RIGHT) || plain(ui, p.KEY_TAB) {
			c.confirm = !c.confirm
		}
		if plain(ui, p.KEY_RETURN) || plain(ui, p.KEY_SPACE) {
			if c.confirm {
				delete_selected(c)
			}
			c.mode = .Normal
		}
		return

	case .Form:
		form_keys(ui, c, swallow)
		return

	case .Normal:
	}

	if plain(ui, p.KEY_F1) || plain(ui, '?') {
		c.mode = .Help
		c.swallow = true
		return
	}
	if plain(ui, p.KEY_TAB) {
		c.pane = c.pane == .Grid ? .Day : .Grid
		return
	}
	if plain(ui, 'y') || plain(ui, p.KEY_F2) {
		c.view = c.view == .Month ? .Year : .Month
		c.year_sel = c.sel.m
		return
	}
	if plain(ui, 't') || plain(ui, p.KEY_F5) {
		c.today, c.now_min = today(c.tz)
		c.sel = c.today
		c.year_sel = c.sel.m
		c.ev_sel = 0
		note(c, "Today")
		return
	}
	if plain(ui, 'a') || plain(ui, 'n') || plain(ui, p.KEY_F3) {
		open_form(c, -1)
		return
	}
	if plain(ui, 'e') || plain(ui, p.KEY_F4) {
		if i, ok := selected_event(c); ok {
			open_form(c, i)
		} else {
			note(c, "No event selected")
		}
		return
	}
	if plain(ui, p.KEY_DELETE) || plain(ui, 'd') {
		if _, ok := selected_event(c); ok {
			c.mode = .Confirm_Delete
			c.confirm = false
		}
		return
	}

	if c.view == .Year {
		year_keys(ui, c)
		return
	}
	month_keys(ui, c)
}

month_keys :: proc(ui: ^p.Ctx, c: ^Cal) {
	// The wheel pages through months, which is what a month grid should do.
	if w := p.wheel(ui).y; w != 0 {
		c.sel = month_add(c.sel, w > 0 ? -1 : 1)
		c.ev_sel = 0
	}

	if c.pane == .Day {
		list := day_events(c, c.sel)
		if n := times(ui, p.KEY_DOWN); n > 0 {
			c.ev_sel = min(c.ev_sel + n, max(0, len(list) - 1))
		}
		if n := times(ui, p.KEY_UP); n > 0 {
			c.ev_sel = max(c.ev_sel - n, 0)
		}
		if plain(ui, p.KEY_RETURN) {
			if i, ok := selected_event(c); ok {
				open_form(c, i)
			} else {
				open_form(c, -1)
			}
		}
		if plain(ui, p.KEY_ESCAPE) || plain(ui, p.KEY_LEFT) {
			c.pane = .Grid
		}
		return
	}

	moved := false
	if n := times(ui, p.KEY_RIGHT); n > 0 {
		c.sel = date_add(c.sel, n)
		moved = true
	}
	if n := times(ui, p.KEY_LEFT); n > 0 {
		c.sel = date_add(c.sel, -n)
		moved = true
	}
	if n := times(ui, p.KEY_DOWN); n > 0 {
		c.sel = date_add(c.sel, 7 * n)
		moved = true
	}
	if n := times(ui, p.KEY_UP); n > 0 {
		c.sel = date_add(c.sel, -7 * n)
		moved = true
	}
	if plain(ui, p.KEY_PAGE_DOWN) {
		c.sel = month_add(c.sel, 1)
		moved = true
	}
	if plain(ui, p.KEY_PAGE_UP) {
		c.sel = month_add(c.sel, -1)
		moved = true
	}
	if with_shift(ui, p.KEY_PAGE_DOWN) {
		c.sel = month_add(c.sel, 12)
		moved = true
	}
	if with_shift(ui, p.KEY_PAGE_UP) {
		c.sel = month_add(c.sel, -12)
		moved = true
	}
	if plain(ui, p.KEY_HOME) {
		c.sel = monday_of(c.sel)
		moved = true
	}
	if plain(ui, p.KEY_END) {
		c.sel = date_add(monday_of(c.sel), 6)
		moved = true
	}
	if plain(ui, p.KEY_RETURN) {
		c.pane = .Day
		c.ev_sel = 0
	}
	if moved {
		c.ev_sel = 0
	}
}

year_keys :: proc(ui: ^p.Ctx, c: ^Cal) {
	if w := p.wheel(ui).y; w != 0 {
		c.sel = Date{c.sel.y + (w > 0 ? -1 : 1), c.sel.m, 1}
	}
	if n := times(ui, p.KEY_RIGHT); n > 0 {
		c.year_sel = min(c.year_sel + n, 12)
	}
	if n := times(ui, p.KEY_LEFT); n > 0 {
		c.year_sel = max(c.year_sel - n, 1)
	}
	if n := times(ui, p.KEY_DOWN); n > 0 {
		c.year_sel = min(c.year_sel + 4 * n, 12)
	}
	if n := times(ui, p.KEY_UP); n > 0 {
		c.year_sel = max(c.year_sel - 4 * n, 1)
	}
	if plain(ui, p.KEY_PAGE_DOWN) {
		c.sel = Date{c.sel.y + 1, c.sel.m, 1}
	}
	if plain(ui, p.KEY_PAGE_UP) {
		c.sel = Date{c.sel.y - 1, c.sel.m, 1}
	}
	if plain(ui, p.KEY_RETURN) || plain(ui, p.KEY_ESCAPE) {
		c.sel = Date{c.sel.y, c.year_sel, min(c.sel.d, days_in_month(c.sel.y, c.year_sel))}
		c.view = .Month
		c.ev_sel = 0
	}
}

form_keys :: proc(ui: ^p.Ctx, c: ^Cal, swallow: bool) {
	if plain(ui, p.KEY_ESCAPE) {
		c.mode = .Normal
		return
	}
	if plain(ui, p.KEY_TAB) || plain(ui, p.KEY_DOWN) {
		c.form.field = Field((int(c.form.field) + 1) % len(Field))
		return
	}
	if with_shift(ui, p.KEY_TAB) || plain(ui, p.KEY_UP) {
		c.form.field = Field((int(c.form.field) + len(Field) - 1) % len(Field))
		return
	}
	if plain(ui, p.KEY_RETURN) {
		commit_form(c)
		return
	}
	if field_edit(ui, &c.form.bufs[c.form.field], swallow) {
		c.form.err = ""
	}
}
