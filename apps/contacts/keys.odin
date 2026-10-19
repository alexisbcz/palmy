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

// field_edit types into a buffer: printable text, Backspace, Ctrl+U.
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

keys :: proc(ui: ^p.Ctx, s: ^App_State) {
	swallow := s.swallow
	s.swallow = false
	if p.shortcut(ui, 'q', {.Ctrl}) {
		s.want_quit = true
		return
	}
	build_side(s)

	switch s.mode {
	case .Help:
		if plain(ui, p.KEY_ESCAPE) || plain(ui, p.KEY_RETURN) || plain(ui, p.KEY_F1) {
			s.mode = .Normal
		}
		return
	case .Confirm_Delete:
		if plain(ui, p.KEY_ESCAPE) {
			s.mode = .Normal
			return
		}
		if plain(ui, p.KEY_LEFT) || plain(ui, p.KEY_RIGHT) || plain(ui, p.KEY_TAB) {
			s.confirm = !s.confirm
		}
		if plain(ui, p.KEY_RETURN) || plain(ui, ' ') {
			if s.confirm {
				delete_selected(s)
			}
			s.mode = .Normal
		}
		return
	case .Search:
		if plain(ui, p.KEY_ESCAPE) {
			clear(&s.query)
			s.mode = .Normal
			return
		}
		if plain(ui, p.KEY_RETURN) || plain(ui, p.KEY_DOWN) {
			s.mode = .Normal
			s.pane = .List
			return
		}
		if field_edit(ui, &s.query, swallow) {
			s.list_sel = 0
		}
		return
	case .Edit:
		form_keys(ui, s, swallow)
		return
	case .Groups:
		groups_keys(ui, s)
		return
	case .Group_Name:
		if plain(ui, p.KEY_ESCAPE) {
			s.mode = s.name_group >= 0 ? .Normal : .Groups
			return
		}
		if plain(ui, p.KEY_RETURN) {
			commit_group_name(s)
			return
		}
		field_edit(ui, &s.name_buf, swallow)
		return
	case .Merge:
		merge_keys(ui, s)
		return
	case .Sign_In:
		signin_keys(ui, s, swallow)
		return
	case .Import, .Export:
		if plain(ui, p.KEY_ESCAPE) {
			s.mode = .Normal
			return
		}
		if s.mode == .Export && plain(ui, p.KEY_TAB) {
			s.version3 = !s.version3
			return
		}
		if plain(ui, p.KEY_RETURN) {
			if s.mode == .Import {
				do_import(s)
			} else {
				do_export(s)
			}
			return
		}
		field_edit(ui, &s.path, swallow)
		return
	case .Normal:
	}

	if plain(ui, p.KEY_F1) || plain(ui, '?') {
		s.mode = .Help
		return
	}
	if plain(ui, '/') || p.shortcut(ui, 'f', {.Ctrl}) {
		s.mode = .Search
		s.swallow = true
		return
	}
	if plain(ui, p.KEY_TAB) || with_shift(ui, p.KEY_TAB) {
		s.pane = s.pane == .List ? .Sidebar : .List
		return
	}
	if plain(ui, 's') || plain(ui, p.KEY_F5) {
		do_sync(s)
		if s.st.err == "" || s.st.online {
			note(s, s.toast != "" ? s.toast : "Up to date")
		}
		return
	}
	if plain(ui, 'n') || plain(ui, 'a') {
		open_form(s, -1)
		return
	}
	if plain(ui, 'm') {
		s.mode = .Merge
		s.merge_sel = 0
		s.merge_swap = false
		return
	}
	if plain(ui, 'i') {
		s.mode = .Import
		set_buf(&s.path, "~/contacts.vcf")
		s.swallow = true
		return
	}
	if plain(ui, 'x') {
		s.mode = .Export
		set_buf(&s.path, "~/contacts-export.vcf")
		s.swallow = true
		return
	}
	if s.pane == .Sidebar {
		sidebar_keys(ui, s)
		return
	}
	list_keys(ui, s)
}

sidebar_keys :: proc(ui: ^p.Ctx, s: ^App_State) {
	moved := false
	if n := times(ui, p.KEY_DOWN); n > 0 {
		s.side_sel = min(s.side_sel + n, len(s.side) - 1)
		moved = true
	}
	if n := times(ui, p.KEY_UP); n > 0 {
		s.side_sel = max(s.side_sel - n, 0)
		moved = true
	}
	if moved {
		s.list_sel = 0
	}
	if plain(ui, p.KEY_RETURN) || plain(ui, p.KEY_RIGHT) {
		s.pane = .List
	}
	if s.side_sel < len(s.side) && s.side[s.side_sel].kind == .Group {
		g := s.side[s.side_sel].group
		if plain(ui, 'r') {
			s.mode = .Group_Name
			s.name_group = g
			set_buf(&s.name_buf, display(s.st.contacts[g]))
			s.swallow = true
		}
		if plain(ui, p.KEY_DELETE) || plain(ui, 'd') {
			name := display(s.st.contacts[g])
			msg := tfmt("Deleted the group \"%s\"", name)
			if err := remove(s.st, g); err != "" {
				note(s, err)
			} else {
				s.side_sel = max(0, s.side_sel - 1)
				after_write(s, msg)
			}
		}
	}
	if plain(ui, '+') || plain(ui, 'g') {
		s.mode = .Group_Name
		s.name_group = -1
		clear(&s.name_buf)
		s.swallow = true
	}
}

list_keys :: proc(ui: ^p.Ctx, s: ^App_State) {
	list := current_list(s)
	if w := p.wheel(ui).y; w != 0 {
		// The list scrolls by itself; the wheel does not move the selection.
	}
	if n := times(ui, p.KEY_DOWN); n > 0 {
		s.list_sel = min(s.list_sel + n, max(0, len(list) - 1))
	}
	if n := times(ui, p.KEY_UP); n > 0 {
		s.list_sel = max(s.list_sel - n, 0)
	}
	if n := times(ui, p.KEY_PAGE_DOWN); n > 0 {
		s.list_sel = min(s.list_sel + 10 * n, max(0, len(list) - 1))
	}
	if n := times(ui, p.KEY_PAGE_UP); n > 0 {
		s.list_sel = max(s.list_sel - 10 * n, 0)
	}
	if plain(ui, p.KEY_HOME) {
		s.list_sel = 0
	}
	if plain(ui, p.KEY_END) {
		s.list_sel = max(0, len(list) - 1)
	}
	if plain(ui, p.KEY_LEFT) || plain(ui, p.KEY_ESCAPE) {
		if len(s.query) > 0 && plain(ui, p.KEY_ESCAPE) {
			clear(&s.query)
		} else {
			s.pane = .Sidebar
		}
	}
	i, ok := selected(s)
	if ok {
		s.sel_uid = s.st.contacts[i].card.uid
	}
	if !ok {
		return
	}
	ro := s.st.books[s.st.contacts[i].book].readonly
	if plain(ui, 'e') || plain(ui, p.KEY_RETURN) {
		if ro {
			note(s, "This address book is shared with you read-only")
		} else {
			open_form(s, i)
		}
	}
	if plain(ui, p.KEY_DELETE) || plain(ui, 'd') {
		if ro {
			note(s, "This address book is shared with you read-only")
		} else {
			s.mode = .Confirm_Delete
			s.confirm = false
		}
	}
	if plain(ui, 'g') {
		if ro {
			note(s, "This address book is shared with you read-only")
		} else {
			s.mode = .Groups
			s.groups_sel = 0
		}
	}
}

form_keys :: proc(ui: ^p.Ctx, s: ^App_State, swallow: bool) {
	f := &s.form
	if plain(ui, p.KEY_ESCAPE) {
		s.mode = .Normal
		return
	}
	if plain(ui, p.KEY_TAB) || plain(ui, p.KEY_DOWN) {
		f.field = (f.field + 1) % len(f.rows)
		return
	}
	if with_shift(ui, p.KEY_TAB) || plain(ui, p.KEY_UP) {
		f.field = (f.field + len(f.rows) - 1) % len(f.rows)
		return
	}
	if plain(ui, p.KEY_RETURN) || p.shortcut(ui, 's', {.Ctrl}) {
		commit_form(s)
		return
	}
	if p.shortcut(ui, 'e', {.Ctrl}) {
		add_row(f, .Email, "", "home")
		return
	}
	if p.shortcut(ui, 'p', {.Ctrl}) {
		add_row(f, .Phone, "", "cell")
		return
	}
	row := &f.rows[f.field]
	if p.shortcut(ui, 't', {.Ctrl}) && (row.kind == .Email || row.kind == .Phone) {
		next := 0
		for t, k in TYPES {
			if t == row.type {
				next = (k + 1) % len(TYPES)
			}
		}
		row.type = TYPES[next]
		return
	}
	if p.shortcut(ui, 'd', {.Ctrl}) && (row.kind == .Email || row.kind == .Phone) {
		same := 0
		for r in f.rows {
			if r.kind == row.kind {
				same += 1
			}
		}
		if same > 1 {
			delete(row.buf)
			ordered_remove(&f.rows, f.field)
			f.field = min(f.field, len(f.rows) - 1)
		} else {
			clear(&row.buf)
		}
		return
	}
	if field_edit(ui, &row.buf, swallow) {
		f.err = ""
	}
}

groups_keys :: proc(ui: ^p.Ctx, s: ^App_State) {
	gs := groups_here(s)
	if plain(ui, p.KEY_ESCAPE) {
		s.mode = .Normal
		return
	}
	if n := times(ui, p.KEY_DOWN); n > 0 {
		s.groups_sel = min(s.groups_sel + n, max(0, len(gs) - 1))
	}
	if n := times(ui, p.KEY_UP); n > 0 {
		s.groups_sel = max(s.groups_sel - n, 0)
	}
	if (plain(ui, ' ') || plain(ui, p.KEY_RETURN)) && len(gs) > 0 {
		toggle_group(s, gs[clamp(s.groups_sel, 0, len(gs) - 1)])
	}
	if plain(ui, 'n') || plain(ui, '+') {
		s.mode = .Group_Name
		s.name_group = -1
		clear(&s.name_buf)
		s.swallow = true
	}
}

merge_keys :: proc(ui: ^p.Ctx, s: ^App_State) {
	pairs := duplicates(s.st, Filter{handle = current_filter(s).handle, book = -1, group = -1})
	if plain(ui, p.KEY_ESCAPE) {
		s.mode = .Normal
		return
	}
	if n := times(ui, p.KEY_DOWN); n > 0 {
		s.merge_sel = min(s.merge_sel + n, max(0, len(pairs) - 1))
		s.merge_swap = false
	}
	if n := times(ui, p.KEY_UP); n > 0 {
		s.merge_sel = max(s.merge_sel - n, 0)
		s.merge_swap = false
	}
	if plain(ui, p.KEY_LEFT) || plain(ui, p.KEY_RIGHT) || plain(ui, p.KEY_TAB) {
		s.merge_swap = !s.merge_swap
	}
	if plain(ui, p.KEY_RETURN) && len(pairs) > 0 {
		merge_selected(s)
	}
}

signin_keys :: proc(ui: ^p.Ctx, s: ^App_State, swallow: bool) {
	if plain(ui, p.KEY_TAB) || with_shift(ui, p.KEY_TAB) || plain(ui, p.KEY_DOWN) || plain(ui, p.KEY_UP) {
		s.signin_fld = 1 - s.signin_fld
		return
	}
	if plain(ui, p.KEY_RETURN) {
		if s.signin_fld == 0 {
			s.signin_fld = 1
		} else {
			do_sign_in(s)
		}
		return
	}
	if plain(ui, p.KEY_ESCAPE) && s.st.acct != nil && dc_signed(s) {
		s.mode = .Normal
		return
	}
	buf := s.signin_fld == 0 ? &s.email : &s.password
	if field_edit(ui, buf, swallow) {
		s.signin_err = ""
	}
}
