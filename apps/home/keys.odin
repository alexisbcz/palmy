// The keyboard. Home has no single-letter shortcuts: typing anywhere is
// searching, so every command lives behind Ctrl or in the palette.
//
//	type            search everything (Esc clears)
//	Up / Down       move through Today, or through the results
//	Enter           open the selection where it lives
//	Ctrl+K          the command palette
//	Ctrl+N          new — mail, event, task, note, document
//	Ctrl+0          all identities
//	Ctrl+1 … 4      one identity
//	Ctrl+Shift+C    carry the selection to another identity
//	F1              keys
package main

import "core:strings"
import kit "kit:."
import p "palmy:."

plain :: proc(ui: ^p.Ctx, sym: u32) -> bool {
	for k in ui.input.keys {
		if k.sym == sym && k.mods & {.Ctrl, .Alt, .Super} == {} {
			return true
		}
	}
	return false
}

// edit applies typed text and Backspace to a buffer.
edit :: proc(ui: ^p.Ctx, buf: ^[dynamic]u8, swallow: bool) -> bool {
	changed := false
	if !swallow {
		for k in ui.input.keys {
			if k.mods & {.Ctrl, .Alt, .Super} != {} {
				return false // a shortcut frame types nothing
			}
		}
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

set_ident :: proc(h: ^Home, i: int) {
	h.ident = i
	h.sel = 0
	if i >= 0 {
		note(h, tfmt(tr("Now in %s. Search, new items and the assistant stay here."), h.store.identities[i].name))
	} else {
		note(h, tr("Showing all identities. Each item keeps its own label."))
	}
}

open_create :: proc(h: ^Home, kind: Create_Kind, ident: int) {
	h.mode = .Create
	h.new_kind = kind
	h.new_ident = ident
	h.new_err = ""
	clear(&h.new_title)
}

open_carry :: proc(h: ^Home) {
	if h.sel < 0 || h.sel >= len(h.rows) {
		note(h, tr("Select something to carry first."))
		return
	}
	h.carry_item = h.rows[h.sel]
	from := h.store.items[h.carry_item].ident
	if len(h.store.identities) < 2 {
		note(h, tr("Carry needs a second identity to carry to."))
		return
	}
	h.carry_to = (from + 1) % len(h.store.identities)
	h.mode = .Carry
}

open_item :: proc(h: ^Home, i: int) {
	if h.store.source == .Device {
		device_open_item(h, i)
		return
	}
	it := h.store.items[i]
	app := it.app != "" ? it.app : KIND_APP[it.kind]
	// A prototype: say where it would open, and as whom. The real hub hands
	// the item's id to the app with the identity's scope (docs: shell.md).
	note(h, tfmt(tr("Opens “%s” in %s as %s"), it.title, app, h.store.identities[it.ident].name))
}

keys :: proc(ui: ^p.Ctx, h: ^Home) {
	swallow := h.swallow
	h.swallow = false

	if p.shortcut(ui, 'q', {.Ctrl}) {
		h.want_quit = true
		return
	}

	switch h.mode {
	case .Help:
		if plain(ui, p.KEY_ESCAPE) || plain(ui, p.KEY_F1) || plain(ui, p.KEY_RETURN) {
			h.mode = .Normal
		}
		return
	case .Palette:
		palette_keys(ui, h, swallow)
		return
	case .Create:
		create_keys(ui, h, swallow)
		return
	case .Carry:
		carry_keys(ui, h)
		return
	case .Normal:
	}

	if plain(ui, p.KEY_F1) {
		h.mode = .Help
		return
	}
	if p.shortcut(ui, 'k', {.Ctrl}) {
		h.mode = .Palette
		h.pal_sel = 0
		clear(&h.pal_query)
		return
	}
	if p.shortcut(ui, 'n', {.Ctrl}) {
		open_create(h, .Mail, h.ident)
		return
	}
	if p.shortcut(ui, 'c', {.Ctrl, .Shift}) || p.shortcut(ui, 'C', {.Ctrl, .Shift}) {
		open_carry(h)
		return
	}
	if p.shortcut(ui, '0', {.Ctrl}) {
		set_ident(h, -1)
		return
	}
	for i in 0 ..< min(len(h.store.identities), 9) {
		if p.shortcut(ui, u32('1' + i), {.Ctrl}) {
			set_ident(h, i)
			return
		}
	}

	if plain(ui, p.KEY_ESCAPE) {
		if len(h.query) > 0 {
			clear(&h.query)
			h.sel = 0
		}
		return
	}
	if edit(ui, &h.query, swallow) {
		h.sel = 0
	}

	n := len(h.rows)
	for _ in 0 ..< p.key_count(ui, p.KEY_DOWN) {
		h.sel = min(h.sel + 1, n - 1)
	}
	for _ in 0 ..< p.key_count(ui, p.KEY_UP) {
		h.sel = max(h.sel - 1, 0)
	}
	if plain(ui, p.KEY_RETURN) && h.sel >= 0 && h.sel < n {
		open_item(h, h.rows[h.sel])
	}
}

// ---------------------------------------------------------------------------
// The command palette
// ---------------------------------------------------------------------------

Action :: enum {
	Switch,
	New,
	Ask,
	Quiet,
	Carry,
	Open_App,
	Theme,
	Help,
}

Command :: struct {
	group:  string,
	label:  string,
	keys:   string,
	action: Action,
	arg:    int, // identity, -1 for all
	kind:   Create_Kind,
	app:    string,
}

commands :: proc(h: ^Home) -> [dynamic]Command {
	out := make([dynamic]Command, context.temp_allocator)
	ids := h.store.identities[:]
	add :: proc(out: ^[dynamic]Command, c: Command) {append(out, c)}

	// The identity the window is in comes first wherever a command needs one,
	// so the obvious choice is the top row.
	order := make([dynamic]int, context.temp_allocator)
	if h.ident >= 0 {
		append(&order, h.ident)
	}
	for _, i in ids {
		if i != h.ident {
			append(&order, i)
		}
	}

	for i in order {
		add(&out, {group = tr("Identity"), label = tfmt(tr("Switch to %s"), ids[i].name), keys = tfmt("Ctrl %d", i + 1), action = .Switch, arg = i})
	}
	if h.ident >= 0 {
		add(&out, {group = tr("Identity"), label = tr("Show all identities"), keys = "Ctrl 0", action = .Switch, arg = -1})
	}
	for i in order {
		add(&out, {group = tr("Create"), label = tfmt(tr("New mail from %s"), ids[i].address), action = .New, kind = .Mail, arg = i})
	}
	add(&out, {group = tr("Create"), label = tr("New event"), keys = "Ctrl N", action = .New, kind = .Event, arg = h.ident})
	add(&out, {group = tr("Create"), label = tr("New task"), action = .New, kind = .Task, arg = h.ident})
	add(&out, {group = tr("Create"), label = tr("New document"), action = .New, kind = .Doc, arg = h.ident})
	for i in order {
		add(&out, {group = tr("Assistant"), label = tfmt(tr("Ask the %s assistant"), ids[i].name), action = .Ask, arg = i})
	}
	for i in order {
		add(&out, {group = tr("Quiet"), label = tfmt(tr("Hold %s notifications until tomorrow 08:00"), ids[i].name), action = .Quiet, arg = i})
	}
	add(&out, {group = tr("Move"), label = tr("Carry the selection to another identity…"), keys = "Ctrl Shift C", action = .Carry, arg = -1})
	for app in ([?]string{"Mail", "Calendar", "Files", "Docs", "Sheets", "Chat", "Notes"}) {
		add(&out, {group = tr("Go to"), label = tfmt(tr("Open %s"), app), action = .Open_App, arg = h.ident, app = app})
	}
	add(&out, {group = tr("Home"), label = tr("Keyboard shortcuts"), keys = "F1", action = .Help, arg = -1})
	return out
}

palette_filter :: proc(h: ^Home) -> [dynamic]Command {
	all := commands(h)
	q := strings.to_lower(string(h.pal_query[:]), context.temp_allocator)
	if q == "" {
		return all
	}
	words := strings.fields(q, context.temp_allocator)
	out := make([dynamic]Command, context.temp_allocator)
	for c in all {
		hay := strings.to_lower(tfmt("%s %s", c.group, c.label), context.temp_allocator)
		ok := true
		for w in words {
			if !strings.contains(hay, w) {
				ok = false
				break
			}
		}
		if ok {
			append(&out, c)
		}
	}
	return out
}

run_command :: proc(h: ^Home, c: Command) {
	h.mode = .Normal
	switch c.action {
	case .Switch:
		set_ident(h, c.arg)
	case .New:
		open_create(h, c.kind, c.arg)
	case .Ask:
		name := h.store.identities[c.arg].name
		if h.store.source == .Device {
			// The assistant runs inside the identity: PALM_IDENTITY scopes
			// its session, its memory and its tools (product.md §9).
			if device_launch("ai", c.arg) {
				note(h, tfmt(tr("The %s assistant is open. It sees %s and nothing else."), name, name))
			} else {
				note(h, tr("The assistant (ai) could not be started."))
			}
			return
		}
		note(h, tfmt(tr("The %s assistant sees %s and nothing else."), name, name))
	case .Quiet:
		name := h.store.identities[c.arg].name
		if h.store.source == .Device {
			// Quiet belongs to the notifications service; Home asks it.
			if _, ok := kit.run({"notify", "quiet", "--identity", device_handle(c.arg), "--until", "08:00"}, context.temp_allocator); ok {
				note(h, tfmt(tr("%s is quiet until 08:00. Today still collects it."), name))
			} else {
				note(h, tfmt(tr("Notifications (notify) did not answer: %s is not quieted."), name))
			}
			return
		}
		note(h, tfmt(tr("%s is quiet until 08:00. Today still collects it."), name))
	case .Carry:
		open_carry(h)
	case .Open_App:
		if h.store.source == .Device {
			if device_launch(strings.to_lower(c.app, context.temp_allocator), c.arg) {
				note(h, c.arg >= 0 ? tfmt(tr("Opening %s as %s"), c.app, h.store.identities[c.arg].name) : tfmt(tr("Opening %s"), c.app))
			} else {
				note(h, tfmt(tr("%s could not be started"), c.app))
			}
			return
		}
		note(h, c.arg >= 0 ? tfmt(tr("Opens %s as %s"), c.app, h.store.identities[c.arg].name) : tfmt(tr("Opens %s showing every identity"), c.app))
	case .Theme:
	case .Help:
		h.mode = .Help
	}
}

palette_keys :: proc(ui: ^p.Ctx, h: ^Home, swallow: bool) {
	if plain(ui, p.KEY_ESCAPE) || p.shortcut(ui, 'k', {.Ctrl}) {
		h.mode = .Normal
		return
	}
	if edit(ui, &h.pal_query, swallow) {
		h.pal_sel = 0
	}
	list := palette_filter(h)
	for _ in 0 ..< p.key_count(ui, p.KEY_DOWN) {
		h.pal_sel = min(h.pal_sel + 1, len(list) - 1)
	}
	for _ in 0 ..< p.key_count(ui, p.KEY_UP) {
		h.pal_sel = max(h.pal_sel - 1, 0)
	}
	if plain(ui, p.KEY_RETURN) && h.pal_sel < len(list) {
		run_command(h, list[h.pal_sel])
	}
}

// ---------------------------------------------------------------------------
// Quick-create
// ---------------------------------------------------------------------------

create_keys :: proc(ui: ^p.Ctx, h: ^Home, swallow: bool) {
	if plain(ui, p.KEY_ESCAPE) {
		h.mode = .Normal
		return
	}
	// Tab chooses who it is from, Left/Right what it is.
	n := len(h.store.identities)
	for k in ui.input.keys {
		if k.sym != p.KEY_TAB || k.mods & {.Ctrl, .Alt} != {} {
			continue
		}
		back := .Shift in k.mods
		if h.new_ident < 0 {
			h.new_ident = back ? n - 1 : 0
		} else {
			h.new_ident = (h.new_ident + (back ? n - 1 : 1)) % n
		}
		h.new_err = ""
	}
	for i in 0 ..< min(n, 9) {
		if p.shortcut(ui, u32('1' + i), {.Ctrl}) {
			h.new_ident = i
			h.new_err = ""
		}
	}
	if p.key_pressed(ui, p.KEY_LEFT) {
		h.new_kind = Create_Kind((int(h.new_kind) + len(Create_Kind) - 1) % len(Create_Kind))
	}
	if p.key_pressed(ui, p.KEY_RIGHT) {
		h.new_kind = Create_Kind((int(h.new_kind) + 1) % len(Create_Kind))
	}
	edit(ui, &h.new_title, swallow)
	if plain(ui, p.KEY_RETURN) {
		if h.new_ident < 0 {
			h.new_err = tr("Choose who this is from. Tab picks an identity.")
			return
		}
		id := h.store.identities[h.new_ident]
		title := string(h.new_title[:])
		h.mode = .Normal
		if h.store.source == .Device {
			note(h, device_create(h, h.new_kind, h.new_ident, title))
			return
		}
		note(h, tfmt(tr("%s “%s” created in %s"), CREATE_LABEL[h.new_kind], title == "" ? tr("Untitled") : title, id.name))
	}
}

// ---------------------------------------------------------------------------
// Carry: moving something between identities, on purpose
// ---------------------------------------------------------------------------

carry_keys :: proc(ui: ^p.Ctx, h: ^Home) {
	if plain(ui, p.KEY_ESCAPE) {
		h.mode = .Normal
		return
	}
	from := h.store.items[h.carry_item].ident
	n := len(h.store.identities)
	step :: proc(h: ^Home, from, n, by: int) {
		for {
			h.carry_to = (h.carry_to + by + n) % n
			if h.carry_to != from {
				return
			}
		}
	}
	if p.key_pressed(ui, p.KEY_TAB) || p.key_pressed(ui, p.KEY_DOWN) || p.key_pressed(ui, p.KEY_RIGHT) {
		step(h, from, n, 1)
	}
	if p.key_pressed(ui, p.KEY_UP) || p.key_pressed(ui, p.KEY_LEFT) {
		step(h, from, n, -1)
	}
	if plain(ui, p.KEY_RETURN) {
		it := h.store.items[h.carry_item]
		h.mode = .Normal
		if h.store.source == .Device {
			// Carry needs each application to write the copy and both logs;
			// none does yet on this branch (search.md, "Gaps").
			note(h, tfmt(tr("Carry is not wired to %s yet: nothing was copied to %s."), it.app, h.store.identities[h.carry_to].name))
			return
		}
		note(h, tfmt(tr("Copied “%s” to %s. Both carry logs record it."), it.title, h.store.identities[h.carry_to].name))
	}
}
