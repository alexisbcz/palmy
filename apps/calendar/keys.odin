// The keyboard. Pointer clicks work too, but nothing requires them.
package main

import "core:strings"
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
	// The cursor may have left the year whose instances are expanded.
	defer ensure_view(c)

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
		n := delete_choices(c)
		if plain(ui, p.KEY_RIGHT) || plain(ui, p.KEY_TAB) {
			c.confirm = (c.confirm + 1) % n
		}
		if plain(ui, p.KEY_LEFT) {
			c.confirm = (c.confirm + n - 1) % n
		}
		if plain(ui, p.KEY_RETURN) || plain(ui, p.KEY_SPACE) {
			if c.confirm > 0 {
				delete_selected(c, delete_choice_is_one(c, c.confirm))
			}
			c.mode = .Normal
		}
		return

	case .Form:
		form_keys(ui, c, swallow)
		return

	case .Sign_In:
		sign_keys(ui, c, swallow)
		return

	case .Invites:
		invite_keys(ui, c)
		return

	case .Normal:
	}

	if plain(ui, 'r') || plain(ui, p.KEY_F6) {
		do_sync(c)
		return
	}
	if plain(ui, 'i') && !c.cloud.signed {
		c.mode = .Sign_In
		c.sign.err = ""
		c.swallow = true
		return
	}
	if plain(ui, 'v') {
		c.mode = .Invites
		c.inv_sel = 0
		return
	}
	if c.pane == .Sources && c.view == .Month {
		if sources_keys(ui, c) {
			return
		}
	}

	if plain(ui, p.KEY_F1) || plain(ui, '?') {
		c.mode = .Help
		c.swallow = true
		return
	}
	if plain(ui, p.KEY_TAB) {
		switch c.pane {
		case .Grid:
			c.pane = .Day
		case .Day:
			c.pane = len(c.cloud.sources) > 1 ? .Sources : .Grid
		case .Sources:
			c.pane = .Grid
		}
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
			if read_only_note(c, i) {
				return
			}
			open_form(c, i)
		} else {
			note(c, "No event selected")
		}
		return
	}
	if plain(ui, p.KEY_DELETE) || plain(ui, 'd') {
		if i, ok := selected_event(c); ok {
			if read_only_note(c, i) {
				return
			}
			c.mode = .Confirm_Delete
			c.confirm = 0
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
	// Counted, not a boolean: two page keys can land in one frame, and a
	// month grid that moved one month when it was asked for two is wrong in a
	// way that is very hard to see.
	if n := times(ui, p.KEY_PAGE_DOWN); n > 0 && !with_shift(ui, p.KEY_PAGE_DOWN) {
		c.sel = month_add(c.sel, n)
		moved = true
	}
	if n := times(ui, p.KEY_PAGE_UP); n > 0 && !with_shift(ui, p.KEY_PAGE_UP) {
		c.sel = month_add(c.sel, -n)
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
	step :: proc(c: ^Cal, by: int) {
		f := int(c.form.field)
		for _ in 0 ..< len(Field) {
			f = (f + by + len(Field)) % len(Field)
			if field_editable(c, Field(f)) {
				break
			}
		}
		c.form.field = Field(f)
	}
	if plain(ui, p.KEY_TAB) || plain(ui, p.KEY_DOWN) {
		step(c, 1)
		return
	}
	if with_shift(ui, p.KEY_TAB) || plain(ui, p.KEY_UP) {
		step(c, -1)
		return
	}
	if plain(ui, p.KEY_RETURN) {
		commit_form(c)
		return
	}
	// The two choice fields cycle with Left/Right or Space.
	switch c.form.field {
	case .Calendar:
		if plain(ui, p.KEY_RIGHT) || plain(ui, p.KEY_SPACE) {
			cycle_source(c, 1)
		}
		if plain(ui, p.KEY_LEFT) {
			cycle_source(c, -1)
		}
		return
	case .Repeat:
		n := len(Recur)
		if plain(ui, p.KEY_RIGHT) || plain(ui, p.KEY_SPACE) {
			c.form.recur = Recur((int(c.form.recur) + 1) % n)
		}
		if plain(ui, p.KEY_LEFT) {
			c.form.recur = Recur((int(c.form.recur) + n - 1) % n)
		}
		return
	case .Date, .Time, .Duration, .Title, .Place, .Attendees:
	}
	if field_edit(ui, &c.form.bufs[c.form.field], swallow) {
		c.form.err = ""
	}
}

// read_only_note refuses to edit an event in a read-only share.
read_only_note :: proc(c: ^Cal, i: int) -> bool {
	e := c.events[i]
	if e.src > 0 && !writable(&c.cloud.sources[e.src]) {
		s := c.cloud.sources[e.src]
		note(c, tfmt("\"%s\" is shared by %s read-only", s.name, s.owner))
		return true
	}
	return false
}

// The delete dialog offers Keep / Delete, or for one instance of a
// recurring cloud event Keep / This one / All of them.
delete_choices :: proc(c: ^Cal) -> int {
	if i, ok := selected_event(c); ok && c.events[i].recurring && c.events[i].src > 0 {
		return 3
	}
	return 2
}

delete_choice_is_one :: proc(c: ^Cal, k: int) -> bool {
	return delete_choices(c) == 3 && k == 1
}

sources_keys :: proc(ui: ^p.Ctx, c: ^Cal) -> bool {
	n := len(c.cloud.sources)
	if n == 0 {
		return false
	}
	if k := times(ui, p.KEY_DOWN); k > 0 {
		c.src_sel = min(c.src_sel + k, n - 1)
		return true
	}
	if k := times(ui, p.KEY_UP); k > 0 {
		c.src_sel = max(c.src_sel - k, 0)
		return true
	}
	if plain(ui, p.KEY_SPACE) || plain(ui, p.KEY_RETURN) {
		s := &c.cloud.sources[clamp(c.src_sel, 0, n - 1)]
		s.visible = !s.visible
		rebuild_view(c)
		note(c, tfmt("%s %s", s.visible ? "Showing" : "Hiding", s.name))
		return true
	}
	if plain(ui, p.KEY_ESCAPE) || plain(ui, p.KEY_LEFT) {
		c.pane = .Grid
		return true
	}
	return false
}

sign_keys :: proc(ui: ^p.Ctx, c: ^Cal, swallow: bool) {
	if plain(ui, p.KEY_ESCAPE) {
		c.mode = .Normal
		return
	}
	if plain(ui, p.KEY_TAB) || plain(ui, p.KEY_DOWN) || plain(ui, p.KEY_UP) || with_shift(ui, p.KEY_TAB) {
		c.sign.field = 1 - c.sign.field
		return
	}
	if plain(ui, p.KEY_RETURN) {
		if c.sign.field == 0 {
			c.sign.field = 1
			return
		}
		do_sign_in(c)
		return
	}
	buf := c.sign.field == 0 ? &c.sign.email : &c.sign.pass
	if field_edit(ui, buf, swallow) {
		c.sign.err = ""
	}
}

invite_keys :: proc(ui: ^p.Ctx, c: ^Cal) {
	list := pending_invitations(&c.cloud, context.temp_allocator)
	if plain(ui, p.KEY_ESCAPE) || plain(ui, 'v') {
		c.mode = .Normal
		return
	}
	if len(list) == 0 {
		return
	}
	if k := times(ui, p.KEY_DOWN); k > 0 {
		c.inv_sel = min(c.inv_sel + k, len(list) - 1)
	}
	if k := times(ui, p.KEY_UP); k > 0 {
		c.inv_sel = max(c.inv_sel - k, 0)
	}
	c.inv_sel = clamp(c.inv_sel, 0, len(list) - 1)
	inv := list[c.inv_sel]
	answer := ""
	if plain(ui, 'a') || plain(ui, p.KEY_RETURN) {
		answer = "ACCEPTED"
	} else if plain(ui, 'd') {
		answer = "DECLINED"
	} else if plain(ui, 't') {
		answer = "TENTATIVE"
	}
	if answer == "" {
		return
	}
	title := strings.clone(inv.title, context.temp_allocator)
	if msg := respond(&c.cloud, inv.src, inv.obj, answer); msg != "" {
		note(c, msg)
	} else {
		note(c, tfmt("%s \"%s\" — %s will be told", answer == "ACCEPTED" ? "Accepted" : (answer == "DECLINED" ? "Declined" : "Maybe for"), title, inv.organizer))
	}
	rebuild_view(c)
}
