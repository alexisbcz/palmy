// The keyboard. Everything this app can do has a key, and nothing needs a
// pointer — which is also what makes it drivable by the recording harness.
package main

import "core:strings"
import kit "kit:."
import p "palmy:."
import ck "../cloudkit"

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

// digit_pressed returns 1..9 for a plain digit key, or 0.
digit_pressed :: proc(ui: ^p.Ctx) -> int {
	for d in 1 ..= 9 {
		if plain(ui, u32('0' + d)) {
			return d
		}
	}
	return 0
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
			apply_rename(ui, nt)
			nt.mode = .Normal
			return
		}
		field_edit(ui, &nt.rename, swallow)
		return

	case .Move:
		if plain(ui, p.KEY_ESCAPE) {
			nt.mode = .Normal
			return
		}
		if plain(ui, p.KEY_RETURN) {
			nt.mode = .Normal
			apply_move(nt)
			return
		}
		field_edit(ui, &nt.move_to, swallow)
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

	case .Share:
		share_keys(ui, nt, swallow)
		return

	case .Carry:
		if plain(ui, p.KEY_ESCAPE) {
			nt.mode = .Normal
			return
		}
		if d := digit_pressed(ui); d > 0 {
			k := 0
			for _, i in nt.ids {
				if i == nt.open_ident {continue}
				k += 1
				if k == d {nt.carry_to = i}
			}
		}
		if plain(ui, p.KEY_LEFT) || plain(ui, p.KEY_RIGHT) || plain(ui, p.KEY_TAB) {
			step := plain(ui, p.KEY_LEFT) ? len(nt.ids) - 1 : 1
			for _ in 0 ..< len(nt.ids) {
				nt.carry_to = (nt.carry_to + step) % len(nt.ids)
				if nt.carry_to != nt.open_ident {break}
			}
		}
		if plain(ui, p.KEY_RETURN) {
			do_carry(nt)
		}
		return

	case .Choose_Identity:
		if plain(ui, p.KEY_ESCAPE) {
			nt.mode = .Normal
			return
		}
		if d := digit_pressed(ui); d > 0 && d <= len(nt.ids) {
			nt.choose_sel = d - 1
		}
		if n := times(ui, p.KEY_DOWN); n > 0 {
			nt.choose_sel = min(nt.choose_sel + n, len(nt.ids) - 1)
		}
		if n := times(ui, p.KEY_UP); n > 0 {
			nt.choose_sel = max(nt.choose_sel - n, 0)
		}
		// Enter does nothing until an identity is chosen (product.md P3).
		if plain(ui, p.KEY_RETURN) && nt.choose_sel >= 0 {
			nt.mode = .Normal
			create_in(nt, nt.choose_sel)
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
			open_sel(nt)
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
		if p.shortcut(ui, '0', {.Ctrl}) {
			set_view(nt, View{ident = -1, section = .All})
			build_side(nt)
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
		if _, ok := open_note(nt); ok && !read_only(nt) {
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
	if plain(ui, p.KEY_F4) || p.shortcut(ui, 'n', {.Ctrl}) {
		create(nt)
		return
	}
	if plain(ui, p.KEY_F5) || p.shortcut(ui, 'r', {.Ctrl}) {
		flush(nt)
		reload(nt)
		sync_start(nt)
		note(nt, sync_bound(nt) ? "Syncing" : tfmt("%d notes on this device", len(nt.all)))
		return
	}
	// Ctrl+0 is every identity; Ctrl+1..9 is one.
	if p.shortcut(ui, '0', {.Ctrl}) && len(nt.ids) > 1 {
		flush(nt)
		set_view(nt, View{ident = -1, section = .All})
		build_side(nt)
		set_view(nt, View{ident = -1, section = .All})
		open_sel(nt)
		return
	}
	for d in 1 ..= 9 {
		if p.shortcut(ui, u32('0' + d), {.Ctrl}) && d <= len(nt.ids) {
			flush(nt)
			set_view(nt, View{ident = d - 1, section = .All})
			build_side(nt)
			set_view(nt, View{ident = d - 1, section = .All})
			open_sel(nt)
			return
		}
	}
	if p.shortcut(ui, '\\', {.Ctrl}) {
		toggle_sidebar(nt)
		return
	}
	ca := p.Modifiers{.Ctrl, .Alt}
	if p.shortcut(ui, 'k', ca) {
		open_share(nt)
		return
	}
	if p.shortcut(ui, 'c', {.Ctrl, .Shift}) || p.shortcut(ui, 'C', {.Ctrl, .Shift}) {
		open_carry(nt)
		return
	}
	if p.shortcut(ui, 'b', ca) {
		nt.backlinks = !nt.backlinks
		return
	}
	if p.shortcut(ui, 'o', ca) {
		live_toggle_offline(nt)
		return
	}
	if p.shortcut(ui, 'p', ca) {
		toggle_pin(nt)
		return
	}
	if p.shortcut(ui, 'm', ca) {
		if n, ok := open_note(nt); ok && !n.shared {
			clear(&nt.move_to)
			append(&nt.move_to, ..transmute([]u8)n.notebook)
			nt.mode = .Move
			nt.swallow = true
		}
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
	if p.shortcut(ui, 'f', {.Ctrl}) || (plain(ui, '/') && nt.pane != .Editor) {
		nt.mode = .Search
		nt.pane = .List
		nt.swallow = true
		return
	}
	if plain(ui, p.KEY_TAB) {
		switch nt.pane {
		case .Sidebar:
			nt.pane = .List
			nt.drawer = false
		case .List:
			if nt.open_path != "" {nt.pane = .Editor}
		case .Editor:
			nt.pane = .List
		}
		nt.swallow = true
		return
	}
	if p.shortcut(ui, p.KEY_TAB, {.Shift}) {
		switch nt.pane {
		case .Editor:
			nt.pane = .List
		case .List:
			if nt.layout == .Three && nt.hide_sidebar {
				nt.hide_sidebar = false
			} else if nt.layout != .Three {
				nt.drawer = true
			}
			nt.pane = .Sidebar
		case .Sidebar:
			nt.pane = .List
			nt.drawer = false
		}
		nt.swallow = true
		return
	}

	switch nt.pane {
	case .Sidebar:
		sidebar_keys(ui, nt)
	case .List:
		list_keys(ui, nt)
	case .Editor:
		editor_keys(ui, nt, swallow)
	}
}

sidebar_keys :: proc(ui: ^p.Ctx, nt: ^Notes) {
	if len(nt.side) == 0 {
		return
	}
	moved := false
	if n := times(ui, p.KEY_DOWN); n > 0 {
		nt.side_sel = min(nt.side_sel + n, len(nt.side) - 1)
		moved = true
	}
	if n := times(ui, p.KEY_UP); n > 0 {
		nt.side_sel = max(nt.side_sel - n, 0)
		moved = true
	}
	if moved || plain(ui, p.KEY_RETURN) || plain(ui, p.KEY_RIGHT) {
		it := nt.side[nt.side_sel]
		v := it.view
		v.name = strings.clone(it.view.name, context.temp_allocator)
		label := strings.clone(it.label, context.temp_allocator)
		flush(nt)
		set_view(nt, v)
		build_side(nt)
		set_view(nt, v)
		// Keep the highlight on the same row after the sidebar was rebuilt.
		for x, i in nt.side {
			if x.view.ident == v.ident && x.view.section == v.section && x.view.name == v.name && x.label == label {
				nt.side_sel = i
			}
		}
		open_sel(nt)
		if plain(ui, p.KEY_RETURN) || plain(ui, p.KEY_RIGHT) {
			nt.pane = .List
			nt.drawer = false
		}
	}
	if plain(ui, p.KEY_ESCAPE) {
		nt.pane = .List
		nt.drawer = false
	}
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
	if plain(ui, p.KEY_LEFT) {
		nt.pane = .Sidebar
		if nt.layout == .Three {
			nt.hide_sidebar = false
		} else {
			nt.drawer = true
		}
		return
	}
	if plain(ui, p.KEY_RETURN) || plain(ui, p.KEY_RIGHT) {
		if nt.view.section == .Trash && plain(ui, p.KEY_RETURN) {
			trash_selected(nt)
			return
		}
		open_sel(nt)
		if nt.open_path != "" {
			nt.pane = .Editor
		}
	}
	if p.shortcut(ui, p.KEY_DELETE, {.Shift}) {
		if _, ok := selected(nt); ok {
			nt.mode = .Confirm_Delete
			nt.sel_confirm = false
		}
		return
	}
	if plain(ui, p.KEY_DELETE) {
		if nt.view.section == .Trash {
			if _, ok := selected(nt); ok {
				nt.mode = .Confirm_Delete
				nt.sel_confirm = false
			}
		} else {
			trash_selected(nt)
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
		if _, ok := open_note(nt); ok && !read_only(nt) {
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
// Share and carry
// ---------------------------------------------------------------------------

open_share :: proc(nt: ^Notes) {
	n, ok := open_note(nt)
	if !ok {
		return
	}
	if n.shared {
		note(nt, tfmt("Shared with you by %s: only its owner can share it", n.meta.shared_from))
		return
	}
	if !ident_bound(nt.ids[n.ident]) {
		note(nt, tfmt("%s is not synced to an account on this device, so it cannot share", nt.ids[n.ident].name))
		return
	}
	flush(nt)
	clear(&nt.share_handle)
	nt.share_edit = false
	delete(nt.share_msg)
	nt.share_msg = ""
	nt.mode = .Share
	nt.swallow = true
	load_people(nt)
}

load_people :: proc(nt: ^Notes) {
	for pe in nt.people {
		delete(pe.handle)
		delete(pe.name)
		delete(pe.color)
		delete(pe.access)
	}
	clear(&nt.people)
	if !live_account(nt) {
		delete(nt.share_msg)
		nt.share_msg = strings.clone("The account is not reachable: sharing needs the network.")
		return
	}
	v, e := ck.rpc(nt.live.acct.c, "notes_people", tfmt(`{{"p_note":"%s"}}`, nt.open_id), context.temp_allocator)
	if !ck.ok(e) {
		return
	}
	for row in ck.array(v) {
		append(&nt.people, Person {
			handle = strings.clone(ck.get_str(row, "handle")),
			name = strings.clone(ck.get_str(row, "display_name")),
			color = strings.clone(ck.get_str(row, "color")),
			access = strings.clone(ck.get_str(row, "access")),
		})
	}
	nt.share_sel = clamp(nt.share_sel, 0, max(0, len(nt.people) - 1))
}

share_keys :: proc(ui: ^p.Ctx, nt: ^Notes, swallow: bool) {
	if plain(ui, p.KEY_ESCAPE) {
		nt.mode = .Normal
		return
	}
	if plain(ui, p.KEY_TAB) {
		nt.share_edit = !nt.share_edit
		return
	}
	if n := times(ui, p.KEY_DOWN); n > 0 {
		nt.share_sel = min(nt.share_sel + n, max(0, len(nt.people) - 1))
	}
	if n := times(ui, p.KEY_UP); n > 0 {
		nt.share_sel = max(nt.share_sel - n, 0)
	}
	if plain(ui, p.KEY_DELETE) && nt.share_sel < len(nt.people) && nt.people[nt.share_sel].access != "owner" {
		who := strings.clone(nt.people[nt.share_sel].handle, context.temp_allocator)
		if live_account(nt) {
			_, e := ck.rpc(nt.live.acct.c, "notes_unshare", tfmt(`{{"p_note":"%s","p_handle":"%s"}}`, nt.open_id, who), context.temp_allocator)
			delete(nt.share_msg)
			nt.share_msg = ck.ok(e) ? strings.clone(tfmt("Revoked. %s's devices drop their copy at their next sync.", who)) : strings.clone(tfmt("Could not revoke: %s", e.message))
			load_people(nt)
		}
		return
	}
	field_edit(ui, &nt.share_handle, swallow)
	if plain(ui, p.KEY_RETURN) {
		who := strings.trim_space(string(nt.share_handle[:]))
		if who == "" {
			return
		}
		access := nt.share_edit ? "edit" : "read"
		if !live_account(nt) {
			return
		}
		_, e := ck.rpc(nt.live.acct.c, "notes_share", tfmt(`{{"p_note":"%s","p_handle":"%s","p_access":"%s"}}`, nt.open_id, who, access), context.temp_allocator)
		delete(nt.share_msg)
		if ck.ok(e) {
			nt.share_msg = strings.clone(tfmt("Shared with %s to %s.", who, access))
			clear(&nt.share_handle)
		} else {
			nt.share_msg = strings.clone(tfmt("Could not share: %s", e.message))
		}
		load_people(nt)
	}
}

open_carry :: proc(nt: ^Notes) {
	n, ok := open_note(nt)
	if !ok || len(nt.ids) < 2 {
		return
	}
	if n.shared {
		note(nt, "A note shared with you is its owner's to carry")
		return
	}
	flush(nt)
	nt.carry_to = -1
	for _, i in nt.ids {
		if i != n.ident {
			nt.carry_to = i
			break
		}
	}
	nt.mode = .Carry
	nt.swallow = true
}

do_carry :: proc(nt: ^Notes) {
	n, ok := open_note(nt)
	if !ok || nt.carry_to < 0 || nt.carry_to == n.ident {
		return
	}
	b := Book{ids = nt.ids, notes = nt.all}
	copy_path, _, _, recorded, err := carry_note(&b, n^, nt.carry_to, "")
	nt.mode = .Normal
	if copy_path == "" {
		note(nt, tfmt("Could not carry: %s", err))
		return
	}
	to := strings.clone(nt.ids[nt.carry_to].name, context.temp_allocator)
	from := strings.clone(nt.ids[n.ident].name, context.temp_allocator)
	reload(nt)
	_ = from
	note(nt, recorded ? tfmt("Carried to %s · logged in both identities", to) : tfmt("Carried to %s · logged at the next sync", to))
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
	if !ok || read_only(nt) {
		return false
	}
	nt.cur = buf_apply(&nt.buf, lo, hi, "", nt.cur, .No)
	ed_clear_sel(nt)
	touch(ui, nt)
	return true
}

ed_insert :: proc(ui: ^p.Ctx, nt: ^Notes, text: string, co := Coalesce.No) {
	if read_only(nt) {
		note(nt, tfmt("Shared with you by %s to read", nt.open_owner))
		return
	}
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
	// Rows differ in height (a heading is taller), so "fits" is measured.
	for nt.top < r && row_y(&nt.wrap, nt.top, r) + nt.wrap.rows[r].h > nt.view_h {
		nt.top += 1
	}
	nt.top = clamp(nt.top, 0, max(0, len(nt.wrap.rows) - 1))
	nt.rows = rows_fitting(&nt.wrap, nt.top, nt.view_h)
}

// wrap_selection puts `mark` on both sides of the selection (or of the word
// under the caret), or takes it off again: Ctrl+B and Ctrl+I.
wrap_selection :: proc(ui: ^p.Ctx, nt: ^Notes, mark: string) {
	if read_only(nt) {
		return
	}
	lo, hi, ok := ed_sel(nt)
	if !ok || lo.line != hi.line {
		ed_insert(ui, nt, tfmt("%s%s", mark, mark))
		nt.cur.col -= len(mark)
		return
	}
	src := buf_line(&nt.buf, lo.line)
	m := len(mark)
	if lo.col >= m && hi.col + m <= len(src) && src[lo.col - m:lo.col] == mark && src[hi.col:hi.col + m] == mark {
		inner := strings.clone(src[lo.col:hi.col], context.temp_allocator)
		nt.cur = buf_apply(&nt.buf, {lo.line, lo.col - m}, {hi.line, hi.col + m}, inner, nt.cur, .No)
		nt.anchor = {lo.line, lo.col - m}
		nt.cur = {lo.line, lo.col - m + len(inner)}
	} else {
		inner := strings.clone(src[lo.col:hi.col], context.temp_allocator)
		buf_apply(&nt.buf, lo, hi, tfmt("%s%s%s", mark, inner, mark), nt.cur, .No)
		nt.anchor = {lo.line, lo.col + m}
		nt.cur = {lo.line, lo.col + m + len(inner)}
	}
	nt.has_sel = true
	touch(ui, nt)
}

// link_at is the [[link]] under the caret, if there is one.
link_at :: proc(nt: ^Notes) -> (Link, bool) {
	off := doc_offset(nt, nt.cur)
	for l in links_in(buffer_text(nt)) {
		if off >= l.from && off <= l.to {
			return l, true
		}
	}
	return {}, false
}

// follow_link opens the note a [[link]] names. Inside this identity that is
// the note; for a link out to another of your identities it is the note in
// *that* identity's view, with a line saying so (P1) — never its content
// drawn here. With nothing of that name it offers to create it here.
follow_link :: proc(ui: ^p.Ctx, nt: ^Notes) {
	l, ok := link_at(nt)
	if !ok {
		return
	}
	flush(nt)
	own := nt.ids[nt.open_ident].handle
	kind, at := link_resolve(nt.all[:], nt.open_ident, own, l)
	switch kind {
	case .Resolved:
		goto_note(nt, at)
	case .Elsewhere:
		ti := ident_find(nt.ids[:], l.handle)
		if ti < 0 {
			note(nt, tfmt("%s is not one of the identities on this device", l.handle))
			return
		}
		k2, at2 := link_resolve(nt.all[:], ti, nt.ids[ti].handle, Link{target = l.target})
		if k2 != .Resolved {
			note(nt, tfmt("No note called \"%s\" in %s", l.target, nt.ids[ti].name))
			return
		}
		goto_note(nt, at2)
		note(nt, tfmt("Opened in %s: a link across identities. Nothing was copied.", nt.ids[ti].name))
	case .Unresolved:
		ti := nt.open_ident
		path, made := store_create_in(nt.ids[ti].root, "", tfmt("# %s\n\n", l.target))
		if made {
			reload(nt)
			for n, i in nt.all {
				if n.path == path {
					goto_note(nt, i)
				}
			}
			delete(path)
			note(nt, tfmt("Created \"%s\" in %s", l.target, nt.ids[ti].name))
		}
	}
}

editor_keys :: proc(ui: ^p.Ctx, nt: ^Notes, swallow: bool) {
	wrap_rebuild(&nt.wrap, ui, &nt.buf, nt.body_w, nt.rev)

	if plain(ui, p.KEY_ESCAPE) {
		flush(nt)
		nt.pane = .List
		return
	}
	if w := p.wheel(ui).y; w != 0 {
		nt.top = clamp(nt.top - int(w * 3), 0, max(0, len(nt.wrap.rows) - 1))
	}
	if p.shortcut(ui, p.KEY_RETURN, {.Ctrl}) && !read_only(nt) {
		toggle_task_at(nt, nt.cur.line)
		touch(ui, nt)
		return
	}
	if p.shortcut(ui, p.KEY_RETURN, {.Alt}) {
		follow_link(ui, nt)
		return
	}
	if p.shortcut(ui, 'b', {.Ctrl}) {
		wrap_selection(ui, nt, "**")
		return
	}
	if p.shortcut(ui, 'i', {.Ctrl}) {
		wrap_selection(ui, nt, "*")
		return
	}

	// In a synced note undo is the CRDT's: your last change, never a
	// collaborator's.
	if p.shortcut(ui, 'z', {.Ctrl}) && nt.live.s != nil {
		live_undo(ui, nt, false)
		touch_saved(ui, nt)
	} else if p.shortcut(ui, 'z', {.Ctrl}) {
		if cur, ok := buf_undo(&nt.buf); ok {
			nt.cur = cur
			ed_clear_sel(nt)
			touch(ui, nt)
		}
	}
	if (p.shortcut(ui, 'y', {.Ctrl}) || p.shortcut(ui, 'z', {.Ctrl, .Shift})) && nt.live.s != nil {
		live_undo(ui, nt, true)
		touch_saved(ui, nt)
	} else if p.shortcut(ui, 'y', {.Ctrl}) || p.shortcut(ui, 'z', {.Ctrl, .Shift}) {
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
		if p.shortcut(ui, 'x', {.Ctrl}) && !read_only(nt) {
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
	if read_only(nt) {
		if len(p.typed_text(ui)) > 0 || times(ui, p.KEY_BACKSPACE) + times(ui, p.KEY_DELETE) + times(ui, p.KEY_RETURN) > 0 {
			note(nt, tfmt("Shared with you by %s to read", nt.open_owner))
		}
		return
	}
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
			if keep[len(keep) - 1] == ' ' {
				live_word_break(nt)
			}
		}
	}
	if edited {
		nt.cur = pos_clamp(&nt.buf, nt.cur)
		wrap_rebuild(&nt.wrap, ui, &nt.buf, nt.body_w, nt.rev)
		nt.goal_x = caret_x(&nt.wrap, ui, &nt.buf, nt.cur)
		ed_visible(ui, nt)
	}
}

// touch_saved marks the note as changed after an undo that went through the
// CRDT, without feeding the change back into it.
touch_saved :: proc(ui: ^p.Ctx, nt: ^Notes) {
	nt.pending = true
	nt.dirty_since = f64(p.elapsed(ui))
	nt.rev += 1
	ed_clear_sel(nt)
	prose_touch(ui, nt, nt.cur.line)
}
