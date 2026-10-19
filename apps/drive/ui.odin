package main

import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"
import dc "drive:core"
import kit "kit:."
import p "palmy:."
import sc "shadcn:."

// ---------------------------------------------------------------------------
// Metrics
// ---------------------------------------------------------------------------

TOOLBAR_H :: 56
STATUS_H :: 28
HEADER_H :: 32
ROW_H :: 36
SIDEBAR_W :: 252
INSPECTOR_W :: 292
TILE_W :: 168
TILE_H :: 176
GRID_PAD :: 16

COL_OWNER :: 150
COL_DATE :: 132
COL_SIZE :: 84

tfmt :: fmt.tprintf

// ---------------------------------------------------------------------------
// Keyboard
// ---------------------------------------------------------------------------

plain :: proc(ui: ^p.Ctx, sym: u32) -> bool {
	for k in ui.input.keys {
		if k.sym == sym && k.mods & {.Shift, .Ctrl, .Alt, .Super} == {} {
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

// edit_buf is a one-line text buffer driven from the keyboard: typed text is
// appended, Backspace removes a rune.
edit_buf :: proc(ui: ^p.Ctx, buf: ^[dynamic]u8) -> (changed: bool) {
	if t := p.typed_text(ui); t != "" {
		for i in 0 ..< len(t) {
			if t[i] >= 0x20 && t[i] != 0x7f {
				append(buf, t[i])
				changed = true
			}
		}
	}
	for _ in 0 ..< times(ui, p.KEY_BACKSPACE) {
		if len(buf) == 0 {
			break
		}
		i := len(buf) - 1
		for i > 0 && buf[i] & 0xc0 == 0x80 {
			i -= 1
		}
		resize(buf, i)
		changed = true
	}
	return
}

measure :: proc(ui: ^p.Ctx, st: ^State) {
	win := p.size(ui)
	// Below this the list would be squeezed to nothing; the inspector gives
	// way first, and comes back when the window is wide again.
	st.show_insp = st.inspector && win.x >= 1040
	st.pane_w = win.x - SIDEBAR_W - (st.show_insp ? INSPECTOR_W : 0)
	body := win.y - TOOLBAR_H - STATUS_H
	switch st.view {
	case .List:
		st.cols = 1
		st.vis_rows = max(1, int((body - HEADER_H - 8) / ROW_H))
	case .Grid:
		st.cols = max(1, int((st.pane_w - 2 * GRID_PAD) / TILE_W))
		st.vis_rows = max(1, int((body - 2 * GRID_PAD - 28) / TILE_H))
	}
}

handle_keys :: proc(ui: ^p.Ctx, st: ^State, app: ^p.App) {
	if p.shortcut(ui, 'q', {.Ctrl}) && app != nil {
		p.quit_app(app)
		return
	}
	if kit.pick_active(&st.pick) {
		return // the file picker owns the keyboard while it is up
	}

	switch st.dialog {
	case .Share:
		share_keys(ui, st)
		return
	case .Identity:
		if plain(ui, p.KEY_ESCAPE) {
			st.dialog = .None
		}
		n := len(st.cfg.identities)
		for _ in 0 ..< times(ui, p.KEY_DOWN) {st.ident_sel = (st.ident_sel + 1) % n}
		for _ in 0 ..< times(ui, p.KEY_UP) {st.ident_sel = (st.ident_sel + n - 1) % n}
		for k in 1 ..= min(9, n) {
			if plain(ui, u32('0' + k)) {
				st.ident_sel = k - 1
				select_identity(st, st.ident_sel)
				st.dialog = .None
				return
			}
		}
		if plain(ui, p.KEY_RETURN) {
			select_identity(st, st.ident_sel)
			st.dialog = .None
		}
		return
	case .New_Folder:
		if plain(ui, p.KEY_ESCAPE) {
			st.dialog = .None
			return
		}
		edit_buf(ui, &st.field)
		if plain(ui, p.KEY_RETURN) {
			new_folder(st, string(st.field[:]))
			st.dialog = .None
		}
		return
	case .Empty_Trash:
		if plain(ui, p.KEY_ESCAPE) || plain(ui, 'n') {
			st.dialog = .None
		}
		if plain(ui, p.KEY_RETURN) || plain(ui, 'y') {
			empty_trash(st)
			st.dialog = .None
		}
		return
	case .None:
	}

	// The wheel scrolls like any list.
	if sy := ui.input.scroll.y; sy != 0 {
		st.scroll_acc += sy / 10
		step := int(st.scroll_acc)
		if step != 0 {
			st.scroll_acc -= f32(step)
			per := st.view == .Grid ? max(1, st.cols) : 1
			lines := (len(st.rows) + per - 1) / per
			st.top = clamp(st.top + step, 0, max(0, lines - st.vis_rows))
		}
	}

	if st.typing {
		if plain(ui, p.KEY_ESCAPE) {
			st.typing = false
			if len(st.query) > 0 {
				clear(&st.query)
				go_section(st, .Drive)
			}
			return
		}
		if edit_buf(ui, &st.query) {
			if len(st.query) == 0 {
				go_section(st, .Drive)
				st.typing = true
			} else {
				st.section = .Search
				clear(&st.crumbs)
				reload(st)
			}
		}
		if plain(ui, p.KEY_RETURN) || plain(ui, p.KEY_DOWN) {
			st.typing = false
		}
		return
	}

	if plain(ui, '/') || p.shortcut(ui, 'f', {.Ctrl}) {
		st.typing = true
		return
	}
	for s, i in ([?]Section{.Drive, .Shared, .Recent, .Starred, .Trash}) {
		if plain(ui, u32('1' + i)) {
			go_section(st, s)
		}
	}
	if plain(ui, 'p') {
		st.dialog = .Identity
		st.ident_sel = st.ident
	}
	if plain(ui, 'v') {
		st.view = st.view == .List ? .Grid : .List
		ensure_visible(st)
	}
	if plain(ui, 'i') {
		st.inspector = !st.inspector
	}
	if plain(ui, 'r') {
		if st.section == .Trash {
			restore_row(st)
		} else {
			reload(st)
			note(st, "Refreshed")
		}
	}
	if plain(ui, 's') {
		if r, ok := selected(st); ok && r.item.identity_id == st.c.identity && st.section != .Trash {
			st.dialog = .Share
			st.share_role = "viewer"
			st.share_sel = -1
			clear(&st.field)
			delete(st.minted)
			st.minted = ""
			st.detail_id = ""
			load_detail(st)
		}
	}
	if plain(ui, 'f') || plain(ui, '*') {
		toggle_star(st)
	}
	if plain(ui, 'n') && st.section == .Drive && st.owner == "" {
		st.dialog = .New_Folder
		clear(&st.field)
		append(&st.field, "Untitled folder")
	}
	if plain(ui, 'u') {
		kit.pick_begin(&st.pick, .Open_Files, {title = "Upload to the drive", confirm = "Upload"})
	}
	if plain(ui, 'd') {
		download_row(st)
	}
	if plain(ui, p.KEY_DELETE) {
		trash_row(st)
	}
	if plain(ui, 'e') && st.section == .Trash && len(st.rows) > 0 {
		st.dialog = .Empty_Trash
	}
	if plain(ui, p.KEY_BACKSPACE) || p.shortcut(ui, p.KEY_UP, {.Alt}) {
		go_up(st)
	}
	if plain(ui, p.KEY_RETURN) {
		open_row(st)
	}

	n := len(st.rows)
	if n == 0 {
		return
	}
	step := st.view == .Grid ? max(1, st.cols) : 1
	moved := false
	for _ in 0 ..< times(ui, p.KEY_DOWN) {st.sel = min(n - 1, st.sel + step); moved = true}
	for _ in 0 ..< times(ui, p.KEY_UP) {st.sel = max(0, st.sel - step); moved = true}
	if st.view == .Grid {
		for _ in 0 ..< times(ui, p.KEY_RIGHT) {st.sel = min(n - 1, st.sel + 1); moved = true}
		for _ in 0 ..< times(ui, p.KEY_LEFT) {st.sel = max(0, st.sel - 1); moved = true}
	}
	if plain(ui, p.KEY_HOME) {st.sel = 0; moved = true}
	if plain(ui, p.KEY_END) {st.sel = n - 1; moved = true}
	if moved {
		ensure_visible(st)
	}
}

share_keys :: proc(ui: ^p.Ctx, st: ^State) {
	if plain(ui, p.KEY_ESCAPE) {
		st.dialog = .None
		delete(st.minted)
		st.minted = ""
		reload(st)
		return
	}
	if p.shortcut(ui, 'l', {.Ctrl}) {
		if len(st.links) == 0 {
			mint_link(st)
		} else if st.minted != "" {
			kit.clipboard_set(st.minted)
			note(st, "Link copied")
		}
		return
	}
	if p.shortcut(ui, 'x', {.Ctrl}) && len(st.links) > 0 {
		revoke_links(st)
		return
	}
	if plain(ui, p.KEY_TAB) {
		st.share_role = st.share_role == "viewer" ? "editor" : "viewer"
	}
	for _ in 0 ..< times(ui, p.KEY_DOWN) {st.share_sel = min(len(st.share_rows) - 1, st.share_sel + 1)}
	for _ in 0 ..< times(ui, p.KEY_UP) {st.share_sel = max(-1, st.share_sel - 1)}
	if st.share_sel >= 0 {
		if plain(ui, p.KEY_DELETE) || plain(ui, p.KEY_BACKSPACE) {
			unshare(st, st.share_sel)
			st.share_sel = min(st.share_sel, len(st.share_rows) - 1)
		}
		return
	}
	edit_buf(ui, &st.field)
	if plain(ui, p.KEY_RETURN) {
		share_with(st, string(st.field[:]))
	}
}

// ---------------------------------------------------------------------------
// The frame
// ---------------------------------------------------------------------------

frame :: proc(ui: ^p.Ctx, st: ^State) {
	load_detail(st)
	p.col(ui, "w-full h-full bg-background text-foreground relative overflow-hidden")
	defer p.end(ui)

	p.row(ui, "flex-1 min-h-0 w-full")
	sidebar(ui, st)
	p.col(ui, "flex-1 min-w-0 h-full")
	toolbar(ui, st)
	p.row(ui, "flex-1 min-h-0 w-full")
	p.col(ui, "flex-1 min-w-0 h-full relative overflow-hidden")
	body(ui, st)
	p.end(ui)
	if st.show_insp {
		inspector(ui, st)
	}
	p.end(ui)
	p.end(ui)
	p.end(ui)

	status_bar(ui, st)

	switch st.dialog {
	case .Share:
		share_dialog(ui, st)
	case .Identity:
		identity_menu(ui, st)
	case .New_Folder:
		folder_dialog(ui, st)
	case .Empty_Trash:
		confirm_dialog(ui, st)
	case .None:
	}
	toast(ui, st)
}

body :: proc(ui: ^p.Ctx, st: ^State) {
	title_bar(ui, st)
	switch {
	case st.offline != "":
		empty_state(ui, ICON_CLOUD_OFF, "Can't reach the drive", st.offline)
	case len(st.rows) == 0:
		switch st.section {
		case .Drive:
			empty_state(ui, ICON_CLOUD_UPLOAD, "Nothing here yet", "Press U to upload, N for a new folder, or drop files into your synced folder.")
		case .Shared:
			empty_state(ui, ICON_USERS, "Nothing shared with you", "When another identity shares a file or folder with this one, it shows up here.")
		case .Recent:
			empty_state(ui, ICON_CLOCK, "Nothing opened yet", "Files you open from the drive show up here.")
		case .Starred:
			empty_state(ui, ICON_STAR, "No starred files", "Press F on a file to star it.")
		case .Trash:
			empty_state(ui, ICON_TRASH, "The trash is empty", "Deleted files stay here until you empty it.")
		case .Search:
			empty_state(ui, ICON_SEARCH, "No matches", tfmt("Nothing in %s's drive matches \"%s\".", ident(st).handle, string(st.query[:])))
		}
	case st.view == .List:
		list_view(ui, st)
	case:
		grid_view(ui, st)
	}
}

// title_bar is the heading over the content: where you are, how much is here.
title_bar :: proc(ui: ^p.Ctx, st: ^State) {
	p.row(ui, "h-[52] shrink-0 w-full items-center gap-3 px-5")
	defer p.end(ui)
	p.row(ui, "flex-1 min-w-0 items-center gap-1")
	crumbs(ui, st)
	p.end(ui)
	if st.section == .Trash && len(st.rows) > 0 {
		p.text(ui, "Items in the trash are deleted for good when you empty it.", "text-[12] text-muted-foreground whitespace-nowrap")
		p.style(ui).shrink = 0
		if action_button(ui, "empty", ICON_TRASH, "Empty trash", false, 'e') {
			st.dialog = .Empty_Trash
		}
	}
}

crumbs :: proc(ui: ^p.Ctx, st: ^State) {
	root := SECTION_LABEL[st.section]
	if st.section == .Search {
		root = tfmt("Results for \"%s\"", string(st.query[:]))
	}
	big :: "text-[20] font-semibold text-foreground whitespace-nowrap tracking-tight"
	small :: "text-[20] font-semibold text-muted-foreground whitespace-nowrap tracking-tight"
	p.key(ui, "crumb-root")
	idx := p.row(ui, "items-center rounded-md px-1 cursor-pointer shrink-0")
	if p.clickable(ui, idx) {
		go_crumb(st, 0)
	}
	p.text(ui, root, len(st.crumbs) == 0 ? big : small)
	p.end(ui)
	if st.owner_handle != "" {
		p.row(ui, "items-center gap-1 px-2 h-6 rounded-full bg-muted shrink-0 ml-1")
		p.icon(ui, ICON_USERS, "size-3 text-muted-foreground")
		p.text(ui, tfmt("from %s", st.owner_handle), "text-[11.5] font-medium text-muted-foreground whitespace-nowrap")
		p.end(ui)
	}
	for c, i in st.crumbs {
		p.icon(ui, ICON_CHEVRON_RIGHT, "size-4 shrink-0 text-muted-foreground/60")
		last := i == len(st.crumbs) - 1
		p.key(ui, tfmt("crumb-%d", i))
		cidx := p.row(ui, "items-center rounded-md px-1 cursor-pointer min-w-0")
		if p.clickable(ui, cidx) {
			go_crumb(st, i + 1)
		}
		p.text(ui, c.name, last ? "truncate text-[20] font-semibold text-foreground tracking-tight" : "truncate text-[20] font-semibold text-muted-foreground tracking-tight")
		p.end(ui)
	}
}

// ---------------------------------------------------------------------------
// Toolbar
// ---------------------------------------------------------------------------

toolbar :: proc(ui: ^p.Ctx, st: ^State) {
	p.row(ui, tfmt("h-[%d] shrink-0 w-full items-center gap-2.5 px-4 border-b border-border", TOOLBAR_H))
	defer p.end(ui)
	search_field(ui, st)
	p.spacer(ui, "flex-1")
	view_switcher(ui, st)
	if icon_button(ui, "info", ICON_INFO, st.inspector, "i") {
		st.inspector = !st.inspector
	}
	sc.separator(ui, .Vertical, "h-6 mx-1 shrink-0")
	can_write := st.section == .Drive && st.owner == ""
	if action_button(ui, "newfolder", ICON_FOLDER_PLUS, "New folder", !can_write, 'n') {
		st.dialog = .New_Folder
		clear(&st.field)
		append(&st.field, "Untitled folder")
	}
	if primary_button(ui, "upload", ICON_UPLOAD, "Upload", !can_write) {
		kit.pick_begin(&st.pick, .Open_Files, {title = "Upload to the drive", confirm = "Upload"})
	}
}

search_field :: proc(ui: ^p.Ctx, st: ^State) {
	focus := st.typing
	p.key(ui, "search")
	idx := p.row(ui, "h-9 w-[420] min-w-[200] shrink items-center gap-2 px-3 rounded-full bg-muted cursor-text transition")
	if focus {
		p.apply(ui, "bg-background ring-2 ring-selection/40 border border-selection/60", idx)
	} else {
		p.apply(ui, "hover:bg-accent", idx)
	}
	if p.clickable(ui, idx) {
		st.typing = true
	}
	defer p.end(ui)
	p.icon(ui, ICON_SEARCH, "size-4 shrink-0 text-muted-foreground")
	text := string(st.query[:])
	p.row(ui, "flex-1 min-w-0 items-center overflow-hidden")
	if text == "" {
		p.text(ui, tfmt("Search %s's drive", ident(st).handle), "text-[13.5] text-muted-foreground whitespace-nowrap")
	} else {
		p.text(ui, text, "text-[13.5] text-foreground whitespace-nowrap")
	}
	p.style(ui).shrink = 0
	if focus {
		p.redraw(ui)
		if math.mod(f64(p.elapsed(ui)), 1.06) < 0.62 {
			p.div(ui, "w-px h-[16] ml-px bg-foreground shrink-0")
			p.end(ui)
		}
	}
	p.end(ui)
	if !focus {
		sc.kbd(ui, "/")
	}
}

view_switcher :: proc(ui: ^p.Ctx, st: ^State) {
	p.row(ui, "shrink-0 items-center gap-0.5 p-0.5 rounded-lg bg-muted")
	defer p.end(ui)
	seg :: proc(ui: ^p.Ctx, st: ^State, key: string, ic: p.Icon, v: View) {
		p.key(ui, key)
		on := st.view == v
		idx := p.div(ui, "flex-row h-7 w-9 items-center justify-center rounded-md transition cursor-pointer")
		p.apply(ui, on ? "bg-background text-foreground shadow-sm" : "text-muted-foreground hover:text-foreground", idx)
		if p.clickable(ui, idx) {
			st.view = v
		}
		p.icon(ui, ic, "size-4")
		p.end(ui)
	}
	seg(ui, st, "list", ICON_LIST, .List)
	seg(ui, st, "grid", ICON_LAYOUT_GRID, .Grid)
}

icon_button :: proc(ui: ^p.Ctx, key: string, ic: p.Icon, on: bool, _: string) -> bool {
	p.key(ui, key)
	idx := p.div(ui, "flex-row size-9 shrink-0 items-center justify-center rounded-lg transition cursor-pointer")
	p.apply(ui, on ? "bg-accent text-foreground" : "text-muted-foreground hover:bg-accent hover:text-foreground", idx)
	fired := p.clickable(ui, idx)
	p.icon(ui, ic, "size-4")
	p.end(ui)
	return fired
}

action_button :: proc(ui: ^p.Ctx, key: string, ic: p.Icon, label: string, disabled: bool, shortcut: rune) -> bool {
	p.key(ui, key)
	idx := p.row(ui, "h-9 shrink-0 items-center gap-2 pl-3 pr-2.5 rounded-lg border border-border bg-background transition")
	p.apply(ui, disabled ? "opacity-45" : "hover:bg-accent cursor-pointer", idx)
	fired := !disabled && p.clickable(ui, idx)
	p.icon(ui, ic, "size-4 text-foreground")
	p.text(ui, label, "text-[13] font-medium text-foreground whitespace-nowrap")
	p.style(ui).shrink = 0
	p.text(ui, tfmt("%c", shortcut - 32), "text-[10.5] font-medium text-muted-foreground/80 px-1 rounded bg-muted")
	p.end(ui)
	return fired
}

primary_button :: proc(ui: ^p.Ctx, key: string, ic: p.Icon, label: string, disabled: bool) -> bool {
	p.key(ui, key)
	idx := p.row(ui, "h-9 shrink-0 items-center gap-2 pl-3 pr-2.5 rounded-lg bg-selection transition shadow-sm")
	p.apply(ui, disabled ? "opacity-45" : "hover:opacity-90 cursor-pointer", idx)
	fired := !disabled && p.clickable(ui, idx)
	p.icon(ui, ic, "size-4 text-white")
	p.text(ui, label, "text-[13] font-semibold text-white whitespace-nowrap")
	p.style(ui).shrink = 0
	p.text(ui, "U", "text-[10.5] font-semibold text-white/80 px-1 rounded bg-white/15")
	p.end(ui)
	return fired
}

// ---------------------------------------------------------------------------
// Sidebar
// ---------------------------------------------------------------------------

avatar :: proc(ui: ^p.Ctx, name, color: string, size: int, text_size: f32) {
	idx := p.div(ui, tfmt("flex-row size-[%d] shrink-0 items-center justify-center rounded-full", size))
	p.style(ui, idx).bg = p.flat(p.hex(identity_hex(color)))
	p.text(ui, initials(name), tfmt("text-[%.1f] font-semibold text-white", text_size))
	p.end(ui)
}

sidebar :: proc(ui: ^p.Ctx, st: ^State) {
	p.col(ui, tfmt("w-[%d] shrink-0 h-full bg-sidebar border-r border-border px-3 pt-3 pb-3 gap-px overflow-hidden", SIDEBAR_W))
	defer p.end(ui)

	// The identity card: whose drive this is, and the way to another.
	id := ident(st)
	p.key(ui, "identity-card")
	card := p.row(ui, "shrink-0 items-center gap-2.5 p-2 rounded-xl border border-border bg-background shadow-sm cursor-pointer transition hover:bg-accent/60")
	if p.clickable(ui, card) {
		st.dialog = st.dialog == .Identity ? .None : .Identity
		st.ident_sel = st.ident
	}
	avatar(ui, id.name, id.color, 36, 13)
	p.col(ui, "flex-1 min-w-0 gap-0.5")
	p.text(ui, id.name, "w-full truncate text-[13.5] font-semibold text-foreground")
	p.row(ui, "items-center gap-1.5 min-w-0")
	p.icon(ui, id.kind == "work" ? ICON_BRIEFCASE : ICON_USER, "size-3 shrink-0 text-muted-foreground")
	p.text(ui, tfmt("%s · %s", kind_label(id.kind), id.handle), "truncate text-[11.5] text-muted-foreground")
	p.end(ui)
	p.end(ui)
	p.icon(ui, ICON_CHEVRONS_UP_DOWN, "size-4 shrink-0 text-muted-foreground")
	p.end(ui)

	p.div(ui, "h-4 shrink-0")
	p.end(ui)

	nav :: proc(ui: ^p.Ctx, st: ^State, s: Section, ic: p.Icon, key: string, count: int = -1) {
		on := st.section == s
		p.key(ui, tfmt("nav-%v", s))
		idx := p.row(ui, "h-9 shrink-0 items-center gap-3 px-3 rounded-lg transition cursor-pointer")
		p.apply(ui, on ? "bg-identity-soft" : "hover:bg-accent/70", idx)
		if p.clickable(ui, idx) {
			go_section(st, s)
		}
		p.icon(ui, ic, on ? "size-[18] shrink-0 text-selection" : "size-[18] shrink-0 text-muted-foreground")
		p.text(ui, SECTION_LABEL[s], on ? "flex-1 min-w-0 truncate text-[13.5] font-semibold text-selection" : "flex-1 min-w-0 truncate text-[13.5] font-medium text-foreground")
		p.text(ui, key, "text-[10.5] text-muted-foreground/60")
		p.end(ui)
	}
	nav(ui, st, .Drive, ICON_HARD_DRIVE, "1")
	nav(ui, st, .Shared, ICON_USERS, "2")
	nav(ui, st, .Recent, ICON_CLOCK, "3")
	nav(ui, st, .Starred, ICON_STAR, "4")
	nav(ui, st, .Trash, ICON_TRASH, "5")

	p.spacer(ui, "flex-1")

	// Sync: whether this device mirrors this drive, and where.
	text, synced := sync_status(st)
	p.col(ui, "shrink-0 gap-1 px-3 py-2.5 rounded-xl bg-background border border-border")
	p.row(ui, "items-center gap-2")
	p.icon(ui, synced ? ICON_CLOUD_CHECK : ICON_CLOUD_OFF, synced ? "size-4 shrink-0 text-emerald-600" : "size-4 shrink-0 text-muted-foreground")
	p.text(ui, text, "flex-1 min-w-0 truncate text-[12.5] font-medium text-foreground")
	p.end(ui)
	p.text(ui, synced ? tilde(id.root) : "Run palm-drive to mirror it here", "w-full truncate text-[11.5] text-muted-foreground font-mono")
	p.end(ui)

	p.div(ui, "h-3 shrink-0")
	p.end(ui)

	// Storage.
	p.col(ui, "shrink-0 gap-2 px-1")
	if st.usage_ok && st.usage.quota_bytes > 0 {
		frac := clamp(f32(st.usage.stored_bytes) / f32(st.usage.quota_bytes), 0, 1)
		p.row(ui, "items-baseline gap-1")
		p.text(ui, dc.human_size(st.usage.stored_bytes), "text-[13] font-semibold text-foreground whitespace-nowrap")
		p.style(ui).shrink = 0
		p.text(ui, tfmt("of %s used", dc.human_size(st.usage.quota_bytes)), "text-[12] text-muted-foreground whitespace-nowrap")
		p.end(ui)
		p.div(ui, "w-full h-1.5 rounded-full bg-muted overflow-hidden shrink-0")
		bar := p.div(ui, "h-full rounded-full bg-selection")
		p.style(ui, bar).w = p.pct(max(frac * 100, 1.5))
		p.end(ui)
		p.end(ui)
		dedup := st.usage.file_bytes + st.usage.version_bytes + st.usage.trash_bytes - st.usage.stored_bytes
		line := tfmt("%d files · %s in versions · %s in trash", st.usage.files, dc.human_size(st.usage.version_bytes), dc.human_size(st.usage.trash_bytes))
		p.text(ui, line, "w-full truncate text-[11] text-muted-foreground")
		if dedup > 0 {
			p.text(ui, tfmt("%s saved by deduplication", dc.human_size(dedup)), "w-full truncate text-[11] text-muted-foreground")
		}
	} else {
		p.text(ui, "Storage unavailable", "text-[12] text-muted-foreground")
	}
	p.end(ui)
}

identity_menu :: proc(ui: ^p.Ctx, st: ^State) {
	scrim := p.div(ui, "absolute inset-0 z-40")
	if p.clickable(ui, scrim) {
		st.dialog = .None
	}
	p.end(ui)
	wrap := p.col(ui, "absolute z-50 w-[300] p-1.5 rounded-xl bg-popover border border-border shadow-xl gap-0.5")
	s := p.style(ui, wrap)
	s.inset[p.LEFT] = p.px(12)
	s.inset[p.TOP] = p.px(64)
	defer p.end(ui)
	p.text(ui, "Switch identity", "px-2 pt-1.5 pb-1 text-[11] font-semibold text-muted-foreground tracking-wide")
	for &id, i in st.cfg.identities {
		on := i == st.ident_sel
		p.key(ui, tfmt("ident-%s", id.handle))
		idx := p.row(ui, "h-[52] items-center gap-2.5 px-2 rounded-lg cursor-pointer transition")
		p.apply(ui, on ? "bg-accent" : "hover:bg-accent/60", idx)
		if p.clickable(ui, idx) {
			select_identity(st, i)
			st.dialog = .None
		}
		avatar(ui, id.name, id.color, 32, 12)
		p.col(ui, "flex-1 min-w-0 gap-0.5")
		p.text(ui, id.name, "w-full truncate text-[13] font-semibold text-foreground")
		p.text(ui, tfmt("%s@palm.test · %s", id.handle, kind_label(id.kind)), "w-full truncate text-[11.5] text-muted-foreground")
		p.end(ui)
		if i == st.ident {
			p.icon(ui, ICON_CHECK, "size-4 shrink-0 text-selection")
		} else {
			sc.kbd(ui, tfmt("%d", i + 1))
		}
		p.end(ui)
	}
	sc.separator(ui, .Horizontal, "my-1")
	p.row(ui, "items-start gap-2 px-2 py-1.5")
	p.icon(ui, ICON_LOCK, "size-3.5 shrink-0 mt-0.5 text-muted-foreground")
	p.text(ui, "Each identity's drive is separate. Moving a file across is a share, made on purpose.", "flex-1 min-w-0 text-[11.5] text-muted-foreground")
	p.end(ui)
}

// ---------------------------------------------------------------------------
// List
// ---------------------------------------------------------------------------

owner_column :: proc(st: ^State) -> string {
	switch st.section {
	case .Shared:
		return "Shared by"
	case .Recent, .Starred, .Search:
		return "Location"
	case .Trash:
		return "Deleted from"
	case .Drive:
		return "Sharing"
	}
	return ""
}

list_view :: proc(ui: ^p.Ctx, st: ^State) {
	p.col(ui, "flex-1 min-h-0 w-full px-3")
	defer p.end(ui)
	wide := st.pane_w >= 600
	p.row(ui, tfmt("h-[%d] shrink-0 w-full items-center gap-3 px-3 border-b border-border", HEADER_H))
	head :: proc(ui: ^p.Ctx, label: string, w: int, right := false) {
		p.row(ui, w == 0 ? "flex-1 min-w-0 items-center" : tfmt("w-[%d] shrink-0 items-center %s", w, right ? "justify-end" : ""))
		p.text(ui, label, "text-[12] font-medium text-muted-foreground whitespace-nowrap")
		p.end(ui)
	}
	head(ui, "Name", 0)
	if wide {
		head(ui, owner_column(st), COL_OWNER)
	}
	head(ui, st.section == .Trash ? "Deleted" : st.section == .Shared && len(st.crumbs) == 0 ? "Shared" : "Modified", COL_DATE)
	head(ui, "Size", COL_SIZE, true)
	p.end(ui)

	p.col(ui, "flex-1 min-h-0 w-full pt-1 relative overflow-hidden")
	defer p.end(ui)
	last := min(st.top + st.vis_rows, len(st.rows))
	for i := st.top; i < last; i += 1 {
		r := &st.rows[i]
		on := i == st.sel
		p.key(ui, tfmt("row:%s", r.item.id))
		idx := p.row(ui, tfmt("h-[%d] shrink-0 w-full items-center gap-3 px-3 rounded-lg transition", ROW_H))
		p.apply(ui, on ? "bg-identity-soft" : "hover:bg-accent/60", idx)
		if on {
			p.apply(ui, "ring-1 ring-selection/30", idx)
		}
		if p.clickable(ui, idx) {
			if st.sel == i {
				open_row(st)
			} else {
				st.sel = i
			}
		}
		p.row(ui, "flex-1 min-w-0 items-center gap-3")
		p.icon(ui, r.icon, tfmt("size-[18] shrink-0 %s", r.tint))
		p.text(ui, r.item.name, on ? "min-w-0 truncate text-[13.5] font-medium text-foreground" : "min-w-0 truncate text-[13.5] text-foreground")
		if r.item.starred {
			p.icon(ui, ICON_STAR, "size-3.5 shrink-0 text-amber-500")
		}
		p.end(ui)
		if wide {
			p.row(ui, tfmt("w-[%d] shrink-0 items-center gap-1.5 overflow-hidden", COL_OWNER))
			owner_cell(ui, st, r)
			p.end(ui)
		}
		p.row(ui, tfmt("w-[%d] shrink-0 items-center overflow-hidden", COL_DATE))
		p.text(ui, r.date_text, "text-[12.5] text-muted-foreground whitespace-nowrap")
		p.end(ui)
		p.row(ui, tfmt("w-[%d] shrink-0 items-center justify-end overflow-hidden", COL_SIZE))
		p.text(ui, r.size_text, "text-[12.5] text-muted-foreground whitespace-nowrap tabular-nums")
		p.end(ui)
		p.end(ui)
	}
	scrollbar(ui, st, f32(st.vis_rows * ROW_H), 1)
}

owner_cell :: proc(ui: ^p.Ctx, st: ^State, r: ^Row) {
	switch st.section {
	case .Shared:
		if r.owner != "" {
			p.div(ui, "flex-row size-5 shrink-0 items-center justify-center rounded-full bg-muted")
			p.text(ui, initials(r.owner), "text-[9] font-semibold text-muted-foreground")
			p.end(ui)
			p.text(ui, r.owner, "truncate text-[12.5] text-foreground")
			if r.role == "editor" {
				p.icon(ui, ICON_PENCIL, "size-3 shrink-0 text-muted-foreground")
			}
		}
	case .Drive:
		if r.shared {
			p.icon(ui, ICON_USERS, "size-3.5 shrink-0 text-selection")
			p.text(ui, "Shared", "text-[12.5] text-selection font-medium")
		} else {
			p.icon(ui, ICON_LOCK, "size-3.5 shrink-0 text-muted-foreground/60")
			p.text(ui, "Only you", "text-[12.5] text-muted-foreground")
		}
	case .Recent, .Starred, .Search, .Trash:
		p.icon(ui, ICON_FOLDER, "size-3.5 shrink-0 text-muted-foreground/70")
		p.text(ui, r.item.parent_id == "" ? "My Drive" : folder_name(st, r.item.parent_id), "truncate text-[12.5] text-muted-foreground")
	}
}

// folder_name names a parent folder, cached for the frame's sake.
@(private = "file")
g_names: map[string]string

folder_name :: proc(st: ^State, id: string) -> string {
	if n, ok := g_names[id]; ok {
		return n
	}
	it, e := dc.get_item(&st.c, id)
	name := dc.failed(e) ? "…" : strings.clone(it.name)
	g_names[strings.clone(id)] = name
	return name
}

scrollbar :: proc(ui: ^p.Ctx, st: ^State, view_h: f32, per: int) {
	lines := (len(st.rows) + per - 1) / max(1, per)
	if lines <= st.vis_rows || view_h <= 0 {
		return
	}
	frac := f32(st.vis_rows) / f32(lines)
	h := max(28, view_h * frac)
	t := f32(st.top) / f32(max(1, lines - st.vis_rows))
	idx := p.div(ui, "absolute right-[2] w-[5] rounded-full bg-foreground/20")
	s := p.style(ui, idx)
	s.inset[p.TOP] = p.px((view_h - h) * t + 4)
	s.h = p.px(h - 4)
	p.end(ui)
}

// ---------------------------------------------------------------------------
// Grid
// ---------------------------------------------------------------------------

thumb :: proc(st: ^State, r: ^Row) -> (p.Image, bool) {
	if r.local == "" || !is_image(r.item.name) {
		return {}, false
	}
	if img, ok := st.thumbs[r.local]; ok {
		return img, true
	}
	if st.thumb_tried[r.local] {
		return {}, false
	}
	st.thumb_tried[strings.clone(r.local)] = true
	img, ok := p.load_image(r.local)
	if !ok {
		return {}, false
	}
	st.thumbs[strings.clone(r.local)] = img
	return img, true
}

grid_view :: proc(ui: ^p.Ctx, st: ^State) {
	p.col(ui, tfmt("flex-1 min-h-0 w-full px-[%d] pt-1 relative overflow-hidden", GRID_PAD - 4))
	defer p.end(ui)
	cols := max(1, st.cols)
	first := st.top * cols
	last := min(first + st.vis_rows * cols, len(st.rows))
	for i := first; i < last; i += cols {
		p.row(ui, tfmt("h-[%d] shrink-0 w-full items-start", TILE_H))
		for j := i; j < min(i + cols, last); j += 1 {
			r := &st.rows[j]
			on := j == st.sel
			p.key(ui, tfmt("tile:%s", r.item.id))
			outer := p.col(ui, tfmt("w-[%d] h-[%d] shrink-0 p-1.5", TILE_W, TILE_H - 8))
			_ = outer
			idx := p.col(ui, "w-full h-full rounded-xl border overflow-hidden transition cursor-pointer")
			p.apply(ui, on ? "border-selection ring-2 ring-selection/25 bg-identity-soft" : "border-border bg-background hover:bg-accent/50", idx)
			if p.clickable(ui, idx) {
				if st.sel == j {
					open_row(st)
				} else {
					st.sel = j
				}
			}
			// The preview area: an image's own pixels when this device has it,
			// otherwise the type's icon on a quiet tint.
			p.div(ui, "flex-row w-full h-[104] shrink-0 items-center justify-center bg-muted/60 overflow-hidden")
			if img, ok := thumb(st, r); ok {
				p.image(ui, img, "w-full h-full", .Cover)
			} else {
				p.icon(ui, r.icon, tfmt("size-10 %s", r.tint))
			}
			p.end(ui)
			p.col(ui, "w-full px-2.5 pt-2 gap-0.5")
			p.row(ui, "w-full items-center gap-1.5 min-w-0")
			p.icon(ui, r.icon, tfmt("size-3.5 shrink-0 %s", r.tint))
			p.text(ui, r.item.name, "flex-1 min-w-0 truncate text-[12.5] font-medium text-foreground")
			if r.shared {
				p.icon(ui, ICON_USERS, "size-3 shrink-0 text-selection")
			}
			if r.item.starred {
				p.icon(ui, ICON_STAR, "size-3 shrink-0 text-amber-500")
			}
			p.end(ui)
			meta := r.item.kind == "folder" ? r.date_text : tfmt("%s · %s", r.size_text, r.date_text)
			if st.section == .Shared && r.owner != "" {
				meta = tfmt("from %s", r.owner)
			}
			p.text(ui, meta, "w-full truncate text-[11] text-muted-foreground pl-5")
			p.end(ui)
			p.end(ui)
			p.end(ui)
		}
		p.end(ui)
	}
	scrollbar(ui, st, f32(st.vis_rows * TILE_H), cols)
}

// ---------------------------------------------------------------------------
// Inspector
// ---------------------------------------------------------------------------

inspector :: proc(ui: ^p.Ctx, st: ^State) {
	p.col(ui, tfmt("w-[%d] shrink-0 h-full border-l border-border px-5 py-5 gap-4 overflow-hidden", INSPECTOR_W))
	defer p.end(ui)
	r, ok := selected(st)
	if !ok {
		p.text(ui, "Nothing selected", "text-[13] text-muted-foreground")
		return
	}
	// Preview.
	p.div(ui, "flex-row w-full h-[150] shrink-0 items-center justify-center rounded-xl bg-muted/60 border border-border overflow-hidden")
	if img, iok := thumb(st, r); iok {
		p.image(ui, img, "w-full h-full", .Cover)
	} else {
		p.icon(ui, r.icon, tfmt("size-14 %s", r.tint))
	}
	p.end(ui)
	p.col(ui, "w-full gap-1 shrink-0")
	p.text(ui, r.item.name, "w-full text-[15] font-semibold text-foreground")
	p.text(ui, r.item.kind == "folder" ? "Folder" : tfmt("%s · %s", r.kind_text, r.size_text), "text-[12] text-muted-foreground")
	p.end(ui)

	if st.section == .Trash {
		p.key(ui, "insp-restore")
		b := p.row(ui, "h-9 w-full shrink-0 items-center justify-center gap-2 rounded-lg border border-border cursor-pointer hover:bg-accent transition")
		if p.clickable(ui, b) {
			restore_row(st)
		}
		p.icon(ui, ICON_ROTATE_CCW, "size-4 text-foreground")
		p.text(ui, "Restore", "text-[13] font-semibold text-foreground whitespace-nowrap")
		p.text(ui, "R", "text-[10.5] font-medium text-muted-foreground px-1 rounded bg-muted")
		p.end(ui)
		p.text(ui, tfmt("Trashed %s. It is kept until the trash is emptied.", rel_date(st, r.item.trashed_at)), "w-full text-[12] text-muted-foreground")
		return
	}
	if r.item.kind == "file" {
		app := dc.app_for(r.item.name)
		label := app != "" ? tfmt("Open in %s", app_title(app)) : "Open"
		p.key(ui, "insp-open")
		b := p.row(ui, "h-9 w-full shrink-0 items-center justify-center gap-2 rounded-lg bg-selection cursor-pointer hover:opacity-90 transition")
		if p.clickable(ui, b) {
			open_file(st, r)
		}
		p.icon(ui, ICON_EXTERNAL_LINK, "size-4 text-white")
		p.text(ui, label, "text-[13] font-semibold text-white whitespace-nowrap")
		p.text(ui, "↵", "text-[11] text-white/70")
		p.end(ui)
	}

	sc.separator(ui)

	// Who has access.
	if r.item.identity_id == st.c.identity {
		p.row(ui, "w-full items-center shrink-0")
		p.text(ui, "Who has access", "flex-1 text-[12] font-semibold text-foreground")
		p.text(ui, "S to share", "text-[11] text-muted-foreground")
		p.end(ui)
		p.col(ui, "w-full gap-2 shrink-0")
		id := ident(st)
		person(ui, id.name, id.handle, id.color, "Owner")
		for s in st.share_rows {
			person(ui, s.grantee_name, s.grantee_handle, "slate", s.role == "editor" ? "Can edit" : "Can view")
		}
		if len(st.links) > 0 {
			p.row(ui, "w-full items-center gap-2.5")
			p.div(ui, "flex-row size-7 shrink-0 items-center justify-center rounded-full bg-amber-100")
			p.icon(ui, ICON_GLOBE, "size-3.5 text-amber-700")
			p.end(ui)
			p.col(ui, "flex-1 min-w-0")
			p.text(ui, "Anyone with the link", "w-full truncate text-[12.5] font-medium text-foreground")
			p.text(ui, link_line(st, st.links[0]), "w-full truncate text-[11] text-muted-foreground")
			p.end(ui)
			p.text(ui, "Can view", "text-[11.5] text-muted-foreground whitespace-nowrap")
			p.end(ui)
		}
		p.end(ui)
	} else if st.owner_handle != "" || r.owner != "" {
		p.row(ui, "w-full items-start gap-2 shrink-0 p-2.5 rounded-lg bg-muted")
		p.icon(ui, ICON_USERS, "size-4 shrink-0 text-muted-foreground")
		owner := r.owner != "" ? r.owner : st.owner_handle
		p.text(ui, tfmt("Shared with you by %s. It stays in their drive; you %s.", owner, r.role == "editor" ? "can edit it" : "can view it"), "flex-1 min-w-0 text-[12] text-muted-foreground")
		p.end(ui)
	}

	sc.separator(ui)

	p.col(ui, "w-full gap-2.5 shrink-0")
	field(ui, "Modified", rel_date(st, r.item.modified_at))
	if r.item.device != "" {
		field(ui, "Last change from", r.item.device)
	}
	if r.item.kind == "file" && len(st.versions) > 0 {
		field(ui, "Versions", len(st.versions) == 1 ? "1 version" : tfmt("%d versions, the oldest %s", len(st.versions), rel_date(st, st.versions[len(st.versions) - 1].created_at)))
	}
	if r.local != "" {
		field(ui, "On this device", tilde(r.local))
	}
	p.end(ui)
}

link_line :: proc(st: ^State, l: dc.Link) -> string {
	exp := l.expires_at == "" ? "never expires" : tfmt("expires %s", rel_date(st, l.expires_at))
	return tfmt("%s · opened %d time%s", exp, l.opened, l.opened == 1 ? "" : "s")
}

person :: proc(ui: ^p.Ctx, name, handle, color, role: string) {
	p.row(ui, "w-full items-center gap-2.5")
	avatar(ui, name, color, 28, 10.5)
	p.col(ui, "flex-1 min-w-0")
	p.text(ui, name, "w-full truncate text-[12.5] font-medium text-foreground")
	p.text(ui, tfmt("%s@palm.test", handle), "w-full truncate text-[11] text-muted-foreground")
	p.end(ui)
	p.text(ui, role, "text-[11.5] text-muted-foreground whitespace-nowrap")
	p.end(ui)
}

field :: proc(ui: ^p.Ctx, label, value: string) {
	p.col(ui, "gap-0.5 w-full")
	p.text(ui, label, "text-[11] font-medium text-muted-foreground")
	p.text(ui, value, "w-full truncate text-[12.5] text-foreground")
	p.end(ui)
}

// ---------------------------------------------------------------------------
// Status bar
// ---------------------------------------------------------------------------

status_bar :: proc(ui: ^p.Ctx, st: ^State) {
	p.row(ui, tfmt("h-[%d] shrink-0 w-full items-center gap-4 px-4 bg-sidebar border-t border-border", STATUS_H))
	defer p.end(ui)
	p.text(ui, tfmt("%d item%s", len(st.rows), len(st.rows) == 1 ? "" : "s"), "text-[11.5] text-muted-foreground whitespace-nowrap")
	p.spacer(ui, "flex-1")
	hint :: proc(ui: ^p.Ctx, keys, what: string) {
		p.row(ui, "items-center gap-1.5 shrink-0")
		sc.kbd(ui, keys)
		p.text(ui, what, "text-[11] text-muted-foreground whitespace-nowrap")
		p.end(ui)
	}
	hint(ui, "↵", "open")
	hint(ui, "S", "share")
	hint(ui, "F", "star")
	hint(ui, "Del", "trash")
	hint(ui, "D", "download")
	hint(ui, "P", "identity")
}

// ---------------------------------------------------------------------------
// Dialogs
// ---------------------------------------------------------------------------

modal :: proc(ui: ^p.Ctx, st: ^State, w, h: f32) -> int {
	scrim := p.div(ui, "absolute inset-0 z-40 bg-black/25")
	if p.clickable(ui, scrim) {
		st.dialog = .None
	}
	p.end(ui)
	win := p.size(ui)
	card := p.col(ui, "absolute z-50 rounded-2xl bg-popover border border-border shadow-2xl overflow-hidden")
	s := p.style(ui, card)
	s.inset[p.LEFT] = p.px(max(16, (win.x - w) / 2))
	s.inset[p.TOP] = p.px(max(16, (win.y - h) / 2 - 20))
	s.w = p.px(w)
	return card
}

text_box :: proc(ui: ^p.Ctx, text, placeholder: string, focused: bool, class := "flex-1 min-w-0") {
	idx := p.row(ui, tfmt("h-10 %s items-center px-3 rounded-lg border bg-background", class))
	p.apply(ui, focused ? "border-selection ring-3 ring-selection/20" : "border-input", idx)
	if text == "" {
		p.text(ui, placeholder, "text-[13.5] text-muted-foreground whitespace-nowrap")
	} else {
		p.text(ui, text, "text-[13.5] text-foreground whitespace-nowrap")
	}
	p.style(ui).shrink = 0
	if focused {
		p.redraw(ui)
		if math.mod(f64(p.elapsed(ui)), 1.06) < 0.62 {
			p.div(ui, "w-px h-[17] ml-px bg-foreground shrink-0")
			p.end(ui)
		}
	}
	p.end(ui)
}

share_dialog :: proc(ui: ^p.Ctx, st: ^State) {
	r, ok := selected(st)
	if !ok {
		st.dialog = .None
		return
	}
	modal(ui, st, 560, 470)
	defer p.end(ui)
	id := ident(st)

	p.col(ui, "w-full px-6 pt-5 pb-4 gap-1")
	p.row(ui, "w-full items-center gap-2.5")
	p.icon(ui, r.icon, tfmt("size-5 shrink-0 %s", r.tint))
	p.text(ui, tfmt("Share “%s”", r.item.name), "flex-1 min-w-0 truncate text-[17] font-semibold text-foreground tracking-tight")
	p.end(ui)
	p.text(ui, tfmt("From %s's drive. Sharing crosses identities on purpose: only who is listed here can open it.", id.handle), "w-full text-[12.5] text-muted-foreground")
	p.end(ui)

	// Add someone.
	p.row(ui, "w-full px-6 gap-2 items-center")
	text_box(ui, string(st.field[:]), "Add an identity by handle — bob, or bob@palm.test", st.share_sel < 0)
	p.key(ui, "role")
	ridx := p.row(ui, "h-10 shrink-0 items-center gap-1.5 px-3 rounded-lg border border-input bg-background cursor-pointer hover:bg-accent")
	if p.clickable(ui, ridx) {
		st.share_role = st.share_role == "viewer" ? "editor" : "viewer"
	}
	p.icon(ui, st.share_role == "editor" ? ICON_PENCIL : ICON_EYE, "size-3.5 text-muted-foreground")
	p.text(ui, st.share_role == "editor" ? "Can edit" : "Can view", "text-[13] font-medium text-foreground whitespace-nowrap")
	sc.kbd(ui, "Tab")
	p.end(ui)
	p.key(ui, "share-go")
	gidx := p.row(ui, "h-10 shrink-0 items-center px-4 rounded-lg bg-selection cursor-pointer hover:opacity-90")
	if p.clickable(ui, gidx) {
		share_with(st, string(st.field[:]))
	}
	p.text(ui, "Share", "text-[13] font-semibold text-white")
	p.end(ui)
	p.end(ui)

	// People.
	p.col(ui, "w-full px-6 pt-5 gap-1")
	p.text(ui, "People with access", "text-[12] font-semibold text-foreground pb-1")
	p.row(ui, "w-full h-11 items-center gap-3 px-2")
	avatar(ui, id.name, id.color, 30, 11)
	p.col(ui, "flex-1 min-w-0")
	p.text(ui, tfmt("%s (you)", id.name), "w-full truncate text-[13] font-medium text-foreground")
	p.text(ui, tfmt("%s@palm.test", id.handle), "w-full truncate text-[11.5] text-muted-foreground")
	p.end(ui)
	p.text(ui, "Owner", "text-[12.5] text-muted-foreground")
	p.end(ui)
	for s, i in st.share_rows {
		on := i == st.share_sel
		p.key(ui, tfmt("share-%s", s.id))
		row := p.row(ui, "w-full h-11 items-center gap-3 px-2 rounded-lg transition")
		p.apply(ui, on ? "bg-accent ring-1 ring-selection/40" : "hover:bg-accent/50", row)
		if p.clickable(ui, row) {
			st.share_sel = i
		}
		avatar(ui, s.grantee_name, "slate", 30, 11)
		p.col(ui, "flex-1 min-w-0")
		p.text(ui, s.grantee_name, "w-full truncate text-[13] font-medium text-foreground")
		p.text(ui, tfmt("%s@palm.test", s.grantee_handle), "w-full truncate text-[11.5] text-muted-foreground")
		p.end(ui)
		p.text(ui, s.role == "editor" ? "Can edit" : "Can view", "text-[12.5] text-muted-foreground whitespace-nowrap")
		p.key(ui, tfmt("unshare-%s", s.id))
		x := p.div(ui, "flex-row size-7 shrink-0 items-center justify-center rounded-md cursor-pointer hover:bg-destructive/10")
		if p.clickable(ui, x) {
			unshare(st, i)
		}
		p.icon(ui, ICON_X, on ? "size-3.5 text-destructive" : "size-3.5 text-muted-foreground")
		p.end(ui)
		p.end(ui)
	}
	p.end(ui)

	// The link.
	p.col(ui, "w-full px-6 pt-4 pb-5 gap-2")
	sc.separator(ui, .Horizontal, "mb-2")
	p.row(ui, "w-full items-center gap-3")
	live := len(st.links) > 0
	p.div(ui, tfmt("flex-row size-9 shrink-0 items-center justify-center rounded-full %s", live ? "bg-amber-100" : "bg-muted"))
	p.icon(ui, live ? ICON_GLOBE : ICON_LOCK, live ? "size-4 text-amber-700" : "size-4 text-muted-foreground")
	p.end(ui)
	p.col(ui, "flex-1 min-w-0")
	p.text(ui, live ? "Anyone with the link can view" : "No link", "text-[13] font-semibold text-foreground")
	p.text(ui, live ? link_line(st, st.links[0]) : "A link is read-only, expires in 7 days, and can be turned off at any time.", "w-full text-[11.5] text-muted-foreground")
	p.end(ui)
	if live {
		p.key(ui, "link-off")
		off := p.row(ui, "h-9 shrink-0 items-center gap-1.5 px-3 rounded-lg border border-border cursor-pointer hover:bg-accent")
		if p.clickable(ui, off) {
			revoke_links(st)
		}
		p.text(ui, "Turn off", "text-[12.5] font-medium text-foreground")
		sc.kbd(ui, "Ctrl X")
		p.end(ui)
	} else {
		p.key(ui, "link-on")
		on := p.row(ui, "h-9 shrink-0 items-center gap-1.5 px-3 rounded-lg border border-border cursor-pointer hover:bg-accent")
		if p.clickable(ui, on) {
			mint_link(st)
		}
		p.icon(ui, ICON_LINK, "size-3.5 text-foreground")
		p.text(ui, "Create link", "text-[12.5] font-medium text-foreground")
		sc.kbd(ui, "Ctrl L")
		p.end(ui)
	}
	p.end(ui)
	if st.minted != "" {
		p.row(ui, "w-full items-center gap-2 mt-1 h-10 px-3 rounded-lg bg-muted border border-border")
		p.icon(ui, ICON_LINK_2, "size-4 shrink-0 text-muted-foreground")
		p.text(ui, st.minted, "flex-1 min-w-0 truncate text-[12] font-mono text-foreground")
		p.icon(ui, ICON_CHECK, "size-3.5 shrink-0 text-emerald-600")
		p.text(ui, "Copied", "text-[11.5] font-medium text-emerald-700 whitespace-nowrap")
		p.end(ui)
	}
	p.end(ui)
}

folder_dialog :: proc(ui: ^p.Ctx, st: ^State) {
	modal(ui, st, 420, 170)
	defer p.end(ui)
	p.col(ui, "w-full px-6 py-5 gap-3")
	p.text(ui, "New folder", "text-[16] font-semibold text-foreground")
	text_box(ui, string(st.field[:]), "Folder name", true, "w-full")
	p.row(ui, "w-full items-center gap-2 justify-end")
	p.text(ui, "Enter to create · Esc to cancel", "text-[11.5] text-muted-foreground")
	p.end(ui)
	p.end(ui)
}

confirm_dialog :: proc(ui: ^p.Ctx, st: ^State) {
	modal(ui, st, 440, 180)
	defer p.end(ui)
	p.col(ui, "w-full px-6 py-5 gap-2")
	p.row(ui, "items-center gap-2")
	p.icon(ui, ICON_TRIANGLE_ALERT, "size-5 text-destructive")
	p.text(ui, "Empty the trash?", "text-[16] font-semibold text-foreground")
	p.end(ui)
	p.text(ui, tfmt("%d item%s will be deleted for good, on every device. This cannot be undone.", len(st.rows), len(st.rows) == 1 ? "" : "s"), "w-full text-[13] text-muted-foreground")
	p.row(ui, "w-full items-center gap-2 justify-end pt-3")
	p.text(ui, "Y to delete · N to keep", "text-[11.5] text-muted-foreground")
	p.end(ui)
	p.end(ui)
}

empty_state :: proc(ui: ^p.Ctx, ic: p.Icon, title, text: string) {
	p.col(ui, "w-full flex-1 items-center justify-center gap-3 px-10 pb-16")
	defer p.end(ui)
	p.div(ui, "flex-row size-14 items-center justify-center rounded-2xl bg-identity-soft shrink-0")
	p.icon(ui, ic, "size-7 text-selection")
	p.end(ui)
	p.text(ui, title, "text-[15] font-semibold text-foreground")
	p.text(ui, text, "max-w-[380] text-center text-[13] text-muted-foreground")
}

toast :: proc(ui: ^p.Ctx, st: ^State) {
	if st.toast == "" {
		return
	}
	if st.toast_at == 0 {
		st.toast_at = f64(p.elapsed(ui))
	}
	if f64(p.elapsed(ui)) - st.toast_at > 3.2 {
		delete(st.toast)
		st.toast = ""
		st.toast_at = 0
		return
	}
	p.redraw(ui)
	idx := p.row(ui, "absolute z-30 right-[20] bottom-[44] items-center gap-2.5 px-4 py-2.5 rounded-xl bg-foreground shadow-xl")
	s := p.style(ui, idx)
	s.no_hit = true
	p.icon(ui, ICON_CIRCLE_CHECK, "size-4 shrink-0 text-emerald-400")
	p.text(ui, st.toast, "text-[12.5] font-medium text-background whitespace-nowrap")
	p.end(ui)
}

// tilde shortens a path under the home directory the way a shell prints it.
tilde :: proc(path: string) -> string {
	home := os.get_env("HOME", context.temp_allocator)
	if home != "" && strings.has_prefix(path, home) {
		return tfmt("~%s", path[len(home):])
	}
	return path
}
