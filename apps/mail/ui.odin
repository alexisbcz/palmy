// The frame: toolbar, sidebar, threaded list, reader, composer, search.
//
// Three panes, like every mail client since NeXTMail, and the composer as an
// in-window overlay because Wayland's xdg_popup is not available here. Nothing
// in this file loads a remote resource; there is no code path that could.
package main

import "core:strings"
import p "palmy:."
import sc "shadcn:."

TOOLBAR_H :: 52
STATUS_H :: 28
SIDEBAR_W :: 244
THREAD_ROW_H :: 70
MSG_ROW_H :: 50

// The one accent: selection, in the sidebar, the list and the focus ring.
SELECTION :: 0x2563eb

// AVATAR_TINTS are the backgrounds an initials avatar can take, chosen by a
// hash of the address so a given sender is always the same colour.
AVATAR_TINTS :: [?]string {
	"bg-rose-500",
	"bg-orange-500",
	"bg-amber-500",
	"bg-lime-600",
	"bg-emerald-600",
	"bg-teal-600",
	"bg-cyan-600",
	"bg-sky-600",
	"bg-indigo-500",
	"bg-violet-500",
	"bg-fuchsia-500",
	"bg-pink-500",
}

// account_kind is what the account is, said the same way everywhere: the
// protocol when it was configured, and "Maildir" when it was found on disk and
// the protocol is genuinely not knowable from the files.
account_kind :: proc(a: Account) -> string {
	return a.discovered ? "Maildir" : protocol_name(a.protocol)
}

plural :: proc(n: int) -> string {
	return n == 1 ? "" : "s"
}

tint_for :: proc(key: string) -> string {
	h: u32 = 2166136261
	for i in 0 ..< len(key) {
		h = (h ~ u32(key[i])) * 16777619
	}
	tints := AVATAR_TINTS
	return tints[int(h % u32(len(tints)))]
}

// initials takes the first letter of up to two words, and falls back to the
// address. It is rune-aware so a CJK or Cyrillic name gets its own glyph
// rather than a mangled byte.
initials :: proc(a: Address) -> string {
	src := a.name != "" ? a.name : a.email
	src = strings.trim_space(src)
	if src == "" {
		return "?"
	}
	// palmy has one face per family and no fallback chain, so a CJK or other
	// non-Latin initial renders as a .notdef box. The name itself still has to
	// be shown as it was written — mangling it would be worse — but an avatar
	// is decoration, and a letter from the address reads better than a box.
	if !is_ascii(src) && a.email != "" {
		for i in 0 ..< len(a.email) {
			c := a.email[i]
			if (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') {
				return strings.to_upper(a.email[i:i + 1], context.temp_allocator)
			}
		}
	}
	out := strings.builder_make(context.temp_allocator)
	want := 2
	for word in strings.fields(src, context.temp_allocator) {
		if want == 0 {
			break
		}
		n := 1
		for n < len(word) && word[n] & 0xc0 == 0x80 {
			n += 1
		}
		strings.write_string(&out, strings.to_upper(word[:n], context.temp_allocator))
		want -= 1
	}
	s := strings.to_string(out)
	return s == "" ? "?" : s
}

// mark_badge stands in for the avatar on a marked row. Replacing the face
// rather than squeezing a checkbox in beside it is what every list with a
// multi-select does, and it reads at a glance across a scrolled page.
mark_badge :: proc(ui: ^p.Ctx, size: string, icon_size: string, hl: bool) {
	p.div(
		ui,
		tfmt(
			"flex-row %s shrink-0 items-center justify-center rounded-full %s",
			size,
			hl ? "bg-white" : "bg-selection",
		),
	)
	p.icon(ui, ICON_CHECK, tfmt("%s %s", icon_size, hl ? "text-selection" : "text-white"))
	p.end(ui)
}

avatar :: proc(ui: ^p.Ctx, a: Address, size: string = "size-8", text_class := "text-[12]") {
	p.div(
		ui,
		tfmt(
			"flex-row %s shrink-0 items-center justify-center rounded-full %s",
			size,
			tint_for(a.email),
		),
	)
	p.text(ui, initials(a), tfmt("%s font-semibold text-white", text_class))
	p.style(ui).shrink = 0
	p.end(ui)
}

// ---------------------------------------------------------------------------
// The frame
// ---------------------------------------------------------------------------

frame :: proc(ui: ^p.Ctx, st: ^State) {
	// The ids of the cursor rows are captured while the tree is built, so they
	// have to be cleared first: a stale id from a row that is no longer on
	// screen would scroll the list to the wrong place.
	st.sel_row_id = 0
	st.side_row_id = 0

	// Three fixed panes need about 1200 pixels to breathe. Below that the
	// folder list becomes a drawer over the window — the same information, one
	// keystroke away, instead of a reader squeezed into two hundred pixels.
	win := p.size(ui)
	st.narrow = win.x < NARROW_W
	switch {
	case win.x >= 1240:
		st.list_w = 420
	case win.x >= 1080:
		st.list_w = 380
	case win.x >= 900:
		st.list_w = 352
	case:
		st.list_w = max(260, win.x * 0.42)
	}

	p.col(ui, "w-full h-full bg-background text-foreground relative overflow-hidden")
	defer p.end(ui)

	toolbar(ui, st)

	p.row(ui, "flex-1 min-h-0 w-full")
	if !st.narrow {
		sidebar(ui, st, false)
	}
	list_pane(ui, st)
	reader_pane(ui, st)
	p.end(ui)

	status_bar(ui, st)

	if st.narrow && st.pane == .Sidebar {
		sidebar_drawer(ui, st)
	}
	if st.comp.open {
		composer(ui, st)
	}
	if st.move_open {
		move_sheet(ui, st)
	}
	if st.confirm_purge {
		purge_confirm(ui, st)
	}
	if st.signin.open {
		signin_sheet(ui, st)
	}
	toast(ui, st)
	// The file dialog is drawn last, over everything, because while it is up
	// it owns the keyboard and nothing behind it is live.
	save_overlay(ui, st)
}

// ---------------------------------------------------------------------------
// Filing: the move sheet and the one irreversible confirmation
// ---------------------------------------------------------------------------

// move_sheet is "file this where?": the account's own folders, with the roles
// in their familiar order, drawn in-window because there is no xdg_popup.
move_sheet :: proc(ui: ^p.Ctx, st: ^State) {
	msgs := selection_messages(st, context.temp_allocator)
	if len(msgs) == 0 {
		st.move_open = false
		return
	}
	targets := move_targets(st, msgs[0])
	if len(targets) == 0 {
		st.move_open = false
		return
	}
	st.move_sel = clamp(st.move_sel, 0, len(targets) - 1)

	scrim := p.div(ui, "absolute inset-0 z-50 bg-black/40")
	if p.clickable(ui, scrim) {
		st.move_open = false
	}
	p.end(ui)

	p.row(ui, "absolute z-50 left-[24] right-[24] top-[72] justify-center")
	defer p.end(ui)
	p.col(ui, "w-full max-w-[440] rounded-xl bg-popover border border-border shadow-2xl p-4 gap-2 overflow-hidden")
	defer p.end(ui)

	p.row(ui, "items-center gap-2 shrink-0")
	p.icon(ui, ICON_FOLDER_OPEN, "size-4 shrink-0 text-selection")
	p.text(
		ui,
		tfmt("Move %d message%s to", len(msgs), plural(len(msgs))),
		"text-[14] font-semibold text-foreground",
	)
	p.style(ui).shrink = 0
	p.end(ui)

	a := st.accounts[st.messages[msgs[0]].account]
	p.text(
		ui,
		tfmt(
			"A rename inside %s. The :2, flag suffix travels with the file, so what you have read stays read.",
			a.name,
		),
		"w-full text-[11.5] text-muted-foreground leading-[16]",
	)

	list := p.col(ui, "w-full max-h-[320] gap-px overflow-scroll")
	for fi, i in targets {
		f := st.folders[fi]
		on := i == st.move_sel
		p.key(ui, tfmt("mv:%d", fi))
		idx := p.row(ui, "h-8 shrink-0 items-center gap-2 px-2 rounded-md transition cursor-pointer")
		p.apply(ui, on ? "bg-selection" : "hover:bg-accent", idx)
		if p.clickable(ui, idx) {
			do_move(st, fi)
		}
		p.icon(
			ui,
			f.depth > 0 ? ICON_FOLDER : role_icon(f.role),
			on ? "size-3.5 shrink-0 text-white" : "size-3.5 shrink-0 text-muted-foreground",
		)
		p.text(
			ui,
			f.name,
			on \
			? "flex-1 min-w-0 truncate text-[12.5] font-medium text-white" \
			: "flex-1 min-w-0 truncate text-[12.5] text-foreground",
		)
		p.text(
			ui,
			tfmt("%d", f.total),
			on ? "text-[10.5] text-white/70" : "text-[10.5] text-muted-foreground/70",
		)
		p.style(ui).shrink = 0
		p.end(ui)
	}
	p.end(ui)
	_ = list

	p.row(ui, "items-center gap-2 shrink-0 pt-1")
	hint(ui, "J K", "choose")
	hint(ui, "Enter", "move")
	hint(ui, "Esc", "cancel")
	p.end(ui)
}

// purge_confirm is the only irreversible thing this client can do, so it names
// the file it is about to unlink and starts on Cancel. Enter cancels: the
// keystroke that confirms everything else in this app must not be the one that
// destroys mail.
purge_confirm :: proc(ui: ^p.Ctx, st: ^State) {
	n, path := purge_label(st)
	if n == 0 {
		st.confirm_purge = false
		return
	}

	scrim := p.div(ui, "absolute inset-0 z-50 bg-black/50")
	if p.clickable(ui, scrim) {
		st.confirm_purge = false
	}
	p.end(ui)

	p.row(ui, "absolute z-50 left-[24] right-[24] top-[88] justify-center")
	defer p.end(ui)
	p.col(ui, "w-full max-w-[520] rounded-xl bg-popover border border-destructive/50 shadow-2xl p-5 gap-3")
	defer p.end(ui)

	p.row(ui, "items-center gap-2 shrink-0")
	p.icon(ui, ICON_TRIANGLE_ALERT, "size-4 shrink-0 text-destructive")
	p.text(
		ui,
		tfmt("Delete %d message%s from disk?", n, plural(n)),
		"text-[14] font-semibold text-foreground whitespace-nowrap",
	)
	p.style(ui).shrink = 0
	p.end(ui)

	p.text(
		ui,
		"The file is unlinked. There is no Trash to recover it from and no undo.",
		"w-full text-[12] text-muted-foreground leading-[18]",
	)

	// Name the file. The basename is what identifies it, so it goes on its own
	// line and is not allowed to be the part that gets truncated.
	p.col(ui, "w-full shrink-0 gap-0.5 px-3 py-2 rounded-lg bg-muted/60 border border-border")
	p.text(ui, basename_of(path), "w-full truncate font-mono text-[12] font-medium text-foreground")
	p.text(
		ui,
		tfmt("in %s", dirname_of(path)),
		"w-full truncate font-mono text-[10.5] text-muted-foreground",
	)
	if n > 1 {
		p.text(
			ui,
			tfmt("and %d more file%s in this conversation", n - 1, plural(n - 1)),
			"w-full text-[11] text-muted-foreground",
		)
	}
	p.end(ui)

	p.row(ui, "items-center gap-2 shrink-0 pt-1")
	{
		// Cancel is first, is focused, and is what Enter and Escape both do.
		idx := p.row(ui, "h-8 shrink-0 items-center px-3 rounded-lg border border-border bg-background ring-3 ring-ring/50 hover:bg-muted cursor-pointer transition")
		if p.clickable(ui, idx) {
			st.confirm_purge = false
		}
		p.text(ui, "Cancel", "text-[13] font-medium whitespace-nowrap")
		p.style(ui).shrink = 0
		p.end(ui)
	}
	{
		idx := p.row(ui, "h-8 shrink-0 items-center gap-1.5 px-3 rounded-lg bg-destructive text-white cursor-pointer transition hover:bg-destructive/80")
		if p.clickable(ui, idx) {
			st.confirm_purge = false
			purge_selection(st)
		}
		p.icon(ui, ICON_TRASH, "size-3.5 shrink-0")
		p.text(ui, "Delete from disk", "text-[13] font-medium whitespace-nowrap")
		p.style(ui).shrink = 0
		p.end(ui)
	}
	p.spacer(ui, "flex-1")
	p.row(ui, "shrink-0 items-center gap-1")
	sc.kbd(ui, "Enter", "h-4 text-[9.5]")
	p.text(ui, "cancel", "text-[10] text-muted-foreground/70 whitespace-nowrap")
	p.style(ui).shrink = 0
	sc.kbd(ui, "Shift D", "h-4 text-[9.5]")
	p.text(ui, "delete", "text-[10] text-muted-foreground/70 whitespace-nowrap")
	p.style(ui).shrink = 0
	p.end(ui)
	p.end(ui)
}

// NARROW_W is where the sidebar stops being a column and becomes a drawer.
NARROW_W :: 1000

// sidebar_drawer is the folder list over the window, with a scrim. There is no
// xdg_popup here, so every overlay is drawn inside the one surface.
sidebar_drawer :: proc(ui: ^p.Ctx, st: ^State) {
	scrim := p.div(ui, tfmt("absolute z-30 left-0 right-0 top-[%d] bottom-[%d] bg-black/35", TOOLBAR_H, STATUS_H))
	if p.clickable(ui, scrim) {
		st.pane = .List
	}
	p.end(ui)

	p.col(ui, tfmt("absolute z-40 left-0 top-[%d] bottom-[%d] w-[%d] shadow-2xl", TOOLBAR_H, STATUS_H, SIDEBAR_W))
	defer p.end(ui)
	sidebar(ui, st, true)
}

// ---------------------------------------------------------------------------
// Toolbar
// ---------------------------------------------------------------------------

toolbar :: proc(ui: ^p.Ctx, st: ^State) {
	p.row(
		ui,
		tfmt(
			"h-[%d] shrink-0 w-full items-center gap-2 px-3 bg-sidebar border-b border-border",
			TOOLBAR_H,
		),
	)
	defer p.end(ui)

	p.row(ui, st.narrow ? "shrink-0 items-center gap-1.5" : "shrink-0 items-center gap-2 w-[228]")
	if st.narrow {
		// The drawer's handle. Without it the folder list would be reachable
		// only from the keyboard once the sidebar is hidden.
		if tool_button(ui, "drawer", ICON_PANEL_RIGHT, true, st.pane == .Sidebar, "Folders") {
			st.pane = st.pane == .Sidebar ? .List : .Sidebar
		}
	}
	p.div(ui, "flex-row size-7 shrink-0 items-center justify-center rounded-lg bg-selection")
	p.icon(ui, ICON_MAILS, "size-4 text-white")
	p.end(ui)
	if !st.narrow {
		p.text(ui, "Mail", "text-[14] font-semibold text-foreground")
		p.style(ui).shrink = 0
		p.spacer(ui, "flex-1")
	}
	p.end(ui)

	// Compose. The accent action, and the only one with a label.
	{
		idx := p.row(
			ui,
			"h-8 shrink-0 items-center gap-1.5 pl-2 pr-2.5 rounded-lg bg-primary text-primary-foreground cursor-pointer transition hover:bg-primary/80",
		)
		if p.clickable(ui, idx) {
			compose_new(st)
		}
		p.icon(ui, ICON_SQUARE_PEN, "size-3.5 shrink-0")
		p.text(ui, "Compose", "text-[13] font-medium whitespace-nowrap")
		p.style(ui).shrink = 0
		p.div(ui, "flex-row h-4 min-w-4 items-center justify-center rounded-sm bg-white/20 px-1 shrink-0")
		p.text(ui, "C", "text-[10] font-semibold text-white")
		p.end(ui)
		p.end(ui)
	}

	search_field(ui, st)

	// Actions on the selection. Disabled rather than hidden, so the toolbar
	// does not reflow as the cursor moves.
	mi := st.reader_msg
	has := mi >= 0 && mi < len(st.messages)
	ti := current_thread(st)
	flagged := ti >= 0 && ti < len(st.threads) && st.threads[ti].flagged

	p.row(ui, "shrink-0 items-center gap-0.5")
	if tool_button(ui, "reply", ICON_REPLY, has, false, "Reply") {
		compose_reply(st, mi, false)
	}
	if tool_button(ui, "replyall", ICON_REPLY_ALL, has, false, "Reply all") {
		compose_reply(st, mi, true)
	}
	if tool_button(ui, "fwd", ICON_FORWARD, has, false, "Forward") {
		compose_forward(st, mi)
	}
	sc.separator(ui, .Vertical, "h-5 mx-1 shrink-0")
	// Filing. Enabled whenever something is under the cursor; what each
	// protocol can honestly do with it is decided in filing.odin, and a POP3
	// account is told so in words rather than shown a dead button.
	if tool_button(ui, "archive", ICON_ARCHIVE, ti >= 0, false, "Archive (E)") {
		archive_selection(st)
	}
	if tool_button(ui, "move", ICON_FOLDER_OPEN, ti >= 0, st.move_open, "Move to folder (M)") {
		open_move_sheet(st)
	}
	if tool_button(ui, "trash", ICON_TRASH, ti >= 0, false, "Delete (D)") {
		delete_selection(st)
	}
	if tool_button(ui, "undo", ICON_CORNER_UP_LEFT, st.undo.valid, false, "Undo the last move (Z)") {
		do_undo(st)
	}
	sc.separator(ui, .Vertical, "h-5 mx-1 shrink-0")
	if tool_button(ui, "flag", ICON_STAR, ti >= 0, flagged, "Flag") {
		toggle_flagged(st)
	}
	if tool_button(ui, "unread", has && msg_unread(st.messages[max(mi, 0)]) ? ICON_MAIL : ICON_MAIL_OPEN, ti >= 0, false, "Read") {
		mark_read_toggle(st)
	}
	if tool_button(ui, "raw", ICON_HASH, has, st.show_raw, "Headers") {
		st.show_raw = !st.show_raw
	}
	sc.separator(ui, .Vertical, "h-5 mx-1 shrink-0")
	if tool_button(ui, "reload", ICON_REFRESH_CW, true, false, "Reload") {
		reload_all(st)
	}
	p.end(ui)
}

tool_button :: proc(
	ui: ^p.Ctx,
	key: string,
	ic: p.Icon,
	enabled: bool,
	on := false,
	tip := "",
) -> (
	fired: bool,
) {
	p.key(ui, key)
	idx := p.div(
		ui,
		"flex-row size-7 shrink-0 items-center justify-center rounded-md transition cursor-pointer",
	)
	if enabled {
		p.apply(ui, on ? "bg-selection text-white" : "hover:bg-accent text-foreground", idx)
		fired = p.clickable(ui, idx)
	} else {
		p.apply(ui, "text-muted-foreground/35", idx)
	}
	p.icon(ui, ic, "size-4")
	p.end(ui)
	return fired && enabled
}

search_field :: proc(ui: ^p.Ctx, st: ^State) {
	focus := st.pane == .Search
	idx := p.row(
		ui,
		"h-8 flex-1 min-w-[160] max-w-[520] items-center gap-2 px-2.5 rounded-lg border border-input bg-background cursor-text transition",
	)
	if focus {
		p.apply(ui, "border-ring ring-3 ring-ring/40", idx)
	}
	if p.clickable(ui, idx) {
		st.pane = .Search
		st.swallow = true
	}
	defer p.end(ui)

	p.icon(ui, ICON_SEARCH, "size-3.5 shrink-0 text-muted-foreground")

	text := le_text(&st.query)
	p.row(ui, "flex-1 min-w-0 items-center overflow-hidden")
	if text == "" && !focus {
		p.text(
			ui,
			st.narrow \
			? "Search" \
			: "Search sender, subject, body  ·  from: subject: is:unread has:attachment",
			"text-[12.5] text-muted-foreground whitespace-nowrap",
		)
		p.style(ui).shrink = 0
	} else {
		caret_text(ui, text, st.query.cur, focus, 13, "text-[13] text-foreground")
	}
	p.end(ui)

	if st.searching {
		p.div(ui, "flex-row h-5 shrink-0 items-center px-1.5 rounded-sm bg-muted")
		p.text(ui, tfmt("%d", search_hit_count(st)), "text-[11] font-medium text-muted-foreground")
		p.end(ui)
	}
	if text != "" {
		x := p.div(
			ui,
			"flex-row size-4 shrink-0 items-center justify-center rounded-full bg-muted-foreground/25 hover:bg-muted-foreground/50 cursor-pointer transition",
		)
		if p.clickable(ui, x) {
			le_clear(&st.query)
			run_search(st)
		}
		p.icon(ui, ICON_X, "size-2.5 text-background")
		p.end(ui)
	}
}

// caret_text draws a string with a blinking caret at a byte index. palmy's own
// text_field owns its focus through the Tab order, which the pane model and
// the recorder both need to override, so the caret is placed here from
// `text_width_upto` — the measurement palmy exposes for exactly this.
caret_text :: proc(ui: ^p.Ctx, text: string, cur: int, focus: bool, size: f32, class: string) {
	p.row(ui, "relative flex-1 min-w-0 items-center overflow-hidden")
	defer p.end(ui)

	p.text(ui, text, tfmt("%s whitespace-nowrap", class))
	p.style(ui).shrink = 0

	if !focus {
		return
	}
	p.redraw(ui)
	// A caret that is always on reads as a bug in a screenshot; blink it.
	phase := f64(p.elapsed(ui))
	on := phase - f64(int(phase / 1.06)) * 1.06 < 0.64
	if !on {
		return
	}
	x := p.text_width_upto(ui.fonts, text, clamp(cur, 0, len(text)), size)
	idx := p.div(ui, "absolute w-px bg-foreground")
	s := p.style(ui, idx)
	s.inset[p.LEFT] = p.px(x)
	s.h = p.px(size + 3)
	p.style(ui, idx).no_hit = true
	p.end(ui)
}

// ---------------------------------------------------------------------------
// Sidebar: accounts and folders
// ---------------------------------------------------------------------------

sidebar :: proc(ui: ^p.Ctx, st: ^State, drawer: bool) {
	p.col(
		ui,
		tfmt(
			"%s shrink-0 h-full bg-sidebar border-r border-border overflow-hidden",
			drawer ? "w-full" : tfmt("w-[%d]", SIDEBAR_W),
		),
	)
	defer p.end(ui)

	identity_strip(ui, st)

	list := p.col(ui, "flex-1 min-h-0 w-full px-2 py-2 gap-px overflow-scroll")
	st.side_id = p.node_id(ui, list)
	for row, i in st.side_rows {
		cursor := st.pane == .Sidebar && i == st.side_sel
		switch row.kind {
		case .Unified:
			unified_row(ui, st, cursor, i)
		case .Account:
			if st.accounts[row.account].palm {
				palm_account_header(ui, st, row.account, cursor, i)
			} else {
				account_header(ui, st, row.account, cursor, i)
			}
		case .Folder:
			folder_row(ui, st, row.folder, cursor, i)
			if !has_server_folders(st.accounts[row.account].protocol) {
				pop3_note(ui)
			}
		}
	}
	p.end(ui)

	sc.separator(ui)
	p.col(ui, "px-3 py-2.5 gap-1 shrink-0")
	hint(ui, "J K", "move")
	hint(ui, "Enter", "open thread")
	hint(ui, "C", "compose")
	hint(ui, "R", "reply")
	hint(ui, "V W", "choose · save file")
	hint(ui, "T", "select · acts on all")
	hint(ui, "E M D", "archive · move · trash")
	hint(ui, "Z", "undo a move")
	hint(ui, "/", "search")
	if palm_identities(st) > 0 {
		hint(ui, "1-9 0", "identity · all")
		hint(ui, "⇧I", "unified inbox (prototype)")
	} else {
		hint(ui, "P", "sign in to Palmframe")
	}
	p.end(ui)
}

account_header :: proc(ui: ^p.Ctx, st: ^State, ai: int, cursor: bool, srow: int) {
	a := st.accounts[ai]
	p.key(ui, tfmt("acct:%d", ai))
	idx := p.row(ui, "h-[38] shrink-0 items-center gap-2 px-2 mt-1.5 rounded-md transition cursor-pointer")
	if cursor {
		p.apply(ui, "bg-accent ring-2 ring-selection/40", idx)
	} else {
		p.apply(ui, "hover:bg-accent/60", idx)
	}
	if p.clickable(ui, idx) {
		st.accounts[ai].collapsed = !st.accounts[ai].collapsed
		rebuild_sidebar(st)
		st.side_sel = srow
		st.pane = .Sidebar
	}
	if cursor {
		st.side_row_id = p.node_id(ui, idx)
	}
	defer p.end(ui)

	p.icon(
		ui,
		a.collapsed ? ICON_CHEVRON_RIGHT : ICON_CHEVRON_DOWN,
		"size-3 shrink-0 text-muted-foreground",
	)

	p.col(ui, "flex-1 min-w-0 gap-0")
	p.row(ui, "items-center gap-1.5 min-w-0")
	p.text(ui, a.name, "truncate text-[12.5] font-semibold text-foreground")
	// The protocol, said out loud. It changes what the client can do, so it is
	// not hidden behind a settings pane.
	p.div(ui, "flex-row h-4 shrink-0 items-center gap-0.5 px-1 rounded-sm bg-muted")
	p.icon(
		ui,
		a.discovered ? ICON_FOLDER : protocol_icon(a.protocol),
		a.discovered \
		? "size-2.5 shrink-0 text-muted-foreground" \
		: tfmt("size-2.5 shrink-0 %s", protocol_tint(a.protocol)),
	)
	p.text(
		ui,
		a.discovered ? "MAILDIR" : protocol_name(a.protocol),
		"text-[9.5] font-semibold text-muted-foreground",
	)
	p.style(ui).shrink = 0
	p.end(ui)
	if !a.loopback {
		// A config that names a host we refuse to dial. Shown, never used.
		p.icon(ui, ICON_SHIELD_OFF, "size-3 shrink-0 text-destructive")
	}
	p.end(ui)
	p.text(
		ui,
		a.discovered ? "found on disk · protocol unknown" : a.address,
		"truncate text-[10.5] text-muted-foreground",
	)
	p.end(ui)
}

// pop3_note says plainly what the protocol cannot do, where the folders a user
// expects to see would otherwise look like a bug in this client.
pop3_note :: proc(ui: ^p.Ctx) {
	p.row(ui, "shrink-0 items-start gap-1.5 pl-[14] pr-2 pt-0.5 pb-1")
	defer p.end(ui)
	p.icon(ui, ICON_INFO, "size-2.5 shrink-0 text-muted-foreground/60")
	p.text(
		ui,
		"POP3: one inbox. Read, flagged and deleted are kept on this machine — the protocol has no folders and no server-side flags, so nothing you file here is filed anywhere else.",
		"flex-1 min-w-0 text-[10] text-muted-foreground/70 leading-[13]",
	)
}

folder_row :: proc(ui: ^p.Ctx, st: ^State, fi: int, cursor: bool, srow: int) {
	f := st.folders[fi]
	on := !st.searching && fi == st.folder_sel

	p.key(ui, tfmt("fold:%d", fi))
	idx := p.row(ui, "h-[28] shrink-0 items-center gap-2 rounded-md transition cursor-pointer")
	p.apply(ui, tfmt("pl-[%d] pr-2", 14 + f.depth * 14), idx)
	switch {
	case on:
		p.apply(ui, "bg-selection", idx)
	case cursor:
		p.apply(ui, "bg-accent ring-2 ring-selection/40", idx)
	case:
		p.apply(ui, "hover:bg-accent/70", idx)
	}
	if p.clickable(ui, idx) {
		select_folder(st, fi)
		st.side_sel = srow
		st.pane = .List
	}
	if cursor {
		st.side_row_id = p.node_id(ui, idx)
	}
	defer p.end(ui)

	p.icon(
		ui,
		f.depth > 0 ? ICON_FOLDER : role_icon(f.role),
		on ? "size-3.5 shrink-0 text-white" : "size-3.5 shrink-0 text-muted-foreground",
	)
	p.text(
		ui,
		f.display,
		on \
		? "flex-1 min-w-0 truncate text-[12.5] font-medium text-white" \
		: f.unread > 0 \
			? "flex-1 min-w-0 truncate text-[12.5] font-semibold text-foreground" \
			: "flex-1 min-w-0 truncate text-[12.5] text-foreground",
	)
	if f.unread > 0 {
		p.div(
			ui,
			on \
			? "flex-row h-4 min-w-4 shrink-0 items-center justify-center rounded-full bg-white/25 px-1" \
			: "flex-row h-4 min-w-4 shrink-0 items-center justify-center rounded-full bg-selection px-1",
		)
		p.text(ui, tfmt("%d", f.unread), "text-[10] font-semibold text-white")
		p.style(ui).shrink = 0
		p.end(ui)
	} else if f.total > 0 {
		p.text(
			ui,
			tfmt("%d", f.total),
			on ? "text-[10.5] text-white/70" : "text-[10.5] text-muted-foreground/70",
		)
		p.style(ui).shrink = 0
	}
}

hint :: proc(ui: ^p.Ctx, keys, what: string) {
	p.row(ui, "items-center gap-1.5")
	sc.kbd(ui, keys)
	p.text(ui, what, "text-[11] text-muted-foreground/70 whitespace-nowrap")
	p.style(ui).shrink = 0
	p.end(ui)
}

// ---------------------------------------------------------------------------
// The threaded message list
// ---------------------------------------------------------------------------

list_pane :: proc(ui: ^p.Ctx, st: ^State) {
	p.col(ui, tfmt("w-[%d] shrink-0 h-full bg-background border-r border-border overflow-hidden", int(st.list_w)))
	defer p.end(ui)

	list_header(ui, st)
	if palm_outbox(st) {
		outbox_banner(ui, st)
	}

	if len(st.rows) == 0 {
		if st.searching {
			empty_state(
				ui,
				ICON_SEARCH,
				"No matches",
				tfmt("Nothing matches \"%s\".", le_text(&st.query)),
			)
		} else {
			empty_state(ui, ICON_INBOX, "Nothing here", "This folder is empty.")
		}
		return
	}

	// A real palmy scroll container — it keeps its offset across frames and the
	// wheel drives it — but only the rows inside the viewport are built.
	//
	// Several hundred conversations is a few thousand elements, measured and
	// laid out every frame for the sake of rows nobody can see. Two spacers
	// stand in for what is above and below, so the container's content height
	// and therefore its scrollbar and its wheel behaviour are exactly what
	// they would be if every row were there.
	container := p.col(ui, "flex-1 min-h-0 w-full overflow-scroll")
	st.list_id = p.node_id(ui, container)
	defer p.end(ui)

	view_h := p.rect_of(ui, st.list_id).h
	if view_h <= 0 {
		// The first frame has no geometry yet; guess high rather than low, so
		// nothing is missing from the frame the user actually sees first.
		view_h = p.size(ui).y
	}
	off := p.scroll_of(ui, st.list_id).y

	OVERSCAN :: f32(360)
	first, last := 0, len(st.rows)
	for i in 0 ..< len(st.rows) {
		if st.row_y[i] + row_height(st.rows[i].kind) >= off - OVERSCAN {
			first = i
			break
		}
	}
	for i in first ..< len(st.rows) {
		if st.row_y[i] > off + view_h + OVERSCAN {
			last = i
			break
		}
	}

	if first > 0 {
		pad := p.div(ui, "w-full shrink-0")
		p.style(ui, pad).h = p.px(st.row_y[first])
		p.style(ui, pad).no_hit = true
		p.end(ui)
	}

	focused := st.pane == .List || st.pane == .Reader
	for i in first ..< last {
		row := st.rows[i]
		sel := i == st.row_sel
		switch row.kind {
		case .Thread:
			thread_row(ui, st, row, i, sel, focused)
		case .Message:
			message_row(ui, st, row, i, sel, focused)
		}
	}

	if last < len(st.rows) {
		rest := st.list_h - st.row_y[last]
		if rest > 0 {
			pad := p.div(ui, "w-full shrink-0")
			p.style(ui, pad).h = p.px(rest)
			p.style(ui, pad).no_hit = true
			p.end(ui)
		}
	}
}

list_header :: proc(ui: ^p.Ctx, st: ^State) {
	p.row(ui, "h-[34] shrink-0 w-full items-center gap-2 px-3 border-b border-border bg-background")
	defer p.end(ui)

	title := st.searching ? "Search results" : "Mail"
	sub := ""
	if st.searching {
		sub = tfmt(
			"%d message%s in %d conversation%s",
			search_hit_count(st),
			plural(search_hit_count(st)),
			len(st.threads),
			plural(len(st.threads)),
		)
	} else if st.unified {
		title = "All inboxes"
		sub = tfmt("%d conversation%s · %d identities", len(st.threads), plural(len(st.threads)), palm_identities(st))
	} else if st.folder_sel >= 0 && st.folder_sel < len(st.folders) {
		f := st.folders[st.folder_sel]
		title = f.name
		if f.unread > 0 {
			sub = tfmt("%d conversation%s · %d unread", len(st.threads), plural(len(st.threads)), f.unread)
		} else {
			sub = tfmt("%d conversation%s", len(st.threads), plural(len(st.threads)))
		}
	}
	p.icon(ui, st.searching ? ICON_SEARCH : ICON_MAILS, "size-3.5 shrink-0 text-muted-foreground")
	p.text(ui, title, "truncate text-[12.5] font-semibold text-foreground max-w-[200]")
	if n := marked_count(st); n > 0 {
		// What the next verb will act on, said in numbers, because "E" over a
		// selection of eleven is not a keystroke to guess at.
		p.div(ui, "flex-row h-[18] shrink-0 items-center gap-1 px-1.5 rounded-full bg-selection")
		p.icon(ui, ICON_CHECK, "size-2.5 shrink-0 text-white")
		p.text(ui, tfmt("%d selected", n), "text-[10] font-semibold text-white whitespace-nowrap")
		p.style(ui).shrink = 0
		p.end(ui)
	}
	p.spacer(ui, "flex-1")
	p.text(ui, sub, "text-[11] text-muted-foreground whitespace-nowrap")
	p.style(ui).shrink = 0
}

thread_row :: proc(ui: ^p.Ctx, st: ^State, row: Row, i: int, sel, focused: bool) {
	t := st.threads[row.thread]
	newest := t.msgs[0]
	for mi in t.msgs {
		if st.messages[mi].date._nsec > st.messages[newest].date._nsec {
			newest = mi
		}
	}
	m := st.messages[newest]
	unread := t.unread > 0
	hl := sel && focused
	marked := row_marked(st, i)

	p.key(ui, tfmt("t:%d:%s", row.thread, t.subject))
	idx := p.row(
		ui,
		tfmt(
			"h-[%d] shrink-0 w-full items-start gap-2.5 px-3 py-2 border-b border-border/50 transition cursor-pointer",
			THREAD_ROW_H,
		),
	)
	switch {
	case hl:
		p.apply(ui, "bg-selection", idx)
	case sel:
		p.apply(ui, "bg-foreground/10", idx)
	case marked:
		p.apply(ui, "bg-selection/15 hover:bg-selection/25", idx)
	case unread:
		p.apply(ui, "bg-background hover:bg-accent", idx)
	case:
		p.apply(ui, "hover:bg-accent", idx)
	}
	if p.clickable(ui, idx) {
		if st.row_sel == i {
			open_row(st)
		} else {
			st.row_sel = i
			st.pane = .List
			sync_reader(st)
		}
	}
	if sel {
		st.sel_row_id = p.node_id(ui, idx)
	}
	defer p.end(ui)

	// The unread rail: a dot you can find without reading anything.
	p.col(ui, "w-[8] shrink-0 items-center pt-2")
	if unread {
		p.div(ui, hl ? "size-2 rounded-full bg-white shrink-0" : "size-2 rounded-full bg-selection shrink-0")
		p.end(ui)
	}
	p.end(ui)

	if marked {
		mark_badge(ui, "size-8", "size-4", hl)
	} else {
		avatar(ui, m.from, "size-8", "text-[11.5]")
	}

	p.col(ui, "flex-1 min-w-0 gap-0.5")

	// Line one: participants, the thread count, and the date.
	p.row(ui, "items-center gap-1.5 w-full min-w-0")
	p.text(
		ui,
		t.senders,
		hl \
		? "flex-1 min-w-0 truncate text-[12.5] font-semibold text-white" \
		: unread \
			? "flex-1 min-w-0 truncate text-[12.5] font-semibold text-foreground" \
			: "flex-1 min-w-0 truncate text-[12.5] text-foreground",
	)
	if len(t.msgs) > 1 {
		p.div(
			ui,
			hl \
			? "flex-row h-[15] min-w-[15] shrink-0 items-center justify-center rounded-full bg-white/25 px-1" \
			: "flex-row h-[15] min-w-[15] shrink-0 items-center justify-center rounded-full bg-muted px-1",
		)
		p.text(
			ui,
			tfmt("%d", len(t.msgs)),
			hl ? "text-[9.5] font-semibold text-white" : "text-[9.5] font-semibold text-muted-foreground",
		)
		p.style(ui).shrink = 0
		p.end(ui)
		p.icon(
			ui,
			t.expanded ? ICON_CHEVRON_DOWN : ICON_CHEVRON_RIGHT,
			hl ? "size-3 shrink-0 text-white/70" : "size-3 shrink-0 text-muted-foreground",
		)
	}
	if t.has_attach {
		p.icon(ui, ICON_PAPERCLIP, hl ? "size-3 shrink-0 text-white/80" : "size-3 shrink-0 text-muted-foreground")
	}
	if t.flagged {
		p.icon(ui, ICON_STAR, hl ? "size-3 shrink-0 text-white" : "size-3 shrink-0 text-amber-500")
	}
	p.text(
		ui,
		relative_date(t.newest, st.now, st.tz_offset, context.temp_allocator),
		hl ? "text-[11] text-white/80 whitespace-nowrap" : "text-[11] text-muted-foreground whitespace-nowrap",
	)
	p.style(ui).shrink = 0
	p.end(ui)

	// Line two: the subject.
	p.text(
		ui,
		t.subject,
		hl \
		? "w-full truncate text-[12.5] text-white" \
		: unread \
			? "w-full truncate text-[12.5] font-medium text-foreground" \
			: "w-full truncate text-[12.5] text-foreground/85",
	)

	// Line three: the snippet, and where it came from when searching across
	// folders, because a hit with no context is a hit you cannot act on.
	p.row(ui, "items-center gap-1.5 w-full min-w-0")
	if st.unified && !st.searching && m.account >= 0 && m.account < len(st.accounts) {
		// Which identity this came to. In a merged list it is the one fact
		// that must never be in doubt.
		identity_chip(ui, st.accounts[m.account], hl)
	}
	if st.searching && m.folder >= 0 && m.folder < len(st.folders) {
		f := st.folders[m.folder]
		a := st.accounts[f.account]
		p.div(ui, hl ? "flex-row h-[14] shrink-0 items-center px-1 rounded-sm bg-white/20" : "flex-row h-[14] shrink-0 items-center px-1 rounded-sm bg-muted")
		p.text(
			ui,
			tfmt("%s/%s", a.name, f.display),
			hl ? "text-[9.5] text-white whitespace-nowrap" : "text-[9.5] text-muted-foreground whitespace-nowrap",
		)
		p.style(ui).shrink = 0
		p.end(ui)
	}
	p.text(
		ui,
		m.snippet,
		hl ? "flex-1 min-w-0 truncate text-[11.5] text-white/75" : "flex-1 min-w-0 truncate text-[11.5] text-muted-foreground",
	)
	p.end(ui)

	p.end(ui)
}

message_row :: proc(ui: ^p.Ctx, st: ^State, row: Row, i: int, sel, focused: bool) {
	m := st.messages[row.msg]
	unread := msg_unread(m)
	hl := sel && focused
	marked := st.marked[m.path]

	p.key(ui, tfmt("m:%d", row.msg))
	idx := p.row(ui, tfmt("h-[%d] shrink-0 w-full items-center gap-2 border-b border-border/40 transition cursor-pointer", MSG_ROW_H))
	p.apply(ui, tfmt("pl-[%d] pr-3", 18 + row.depth * 14), idx)
	switch {
	case hl:
		p.apply(ui, "bg-selection", idx)
	case sel:
		p.apply(ui, "bg-foreground/10", idx)
	case marked:
		p.apply(ui, "bg-selection/15 hover:bg-selection/25", idx)
	case:
		p.apply(ui, "bg-muted/35 hover:bg-accent", idx)
	}
	if p.clickable(ui, idx) {
		if st.row_sel == i {
			open_row(st)
		} else {
			st.row_sel = i
			st.pane = .List
			sync_reader(st)
		}
	}
	if sel {
		st.sel_row_id = p.node_id(ui, idx)
	}
	defer p.end(ui)

	p.icon(
		ui,
		ICON_CORNER_UP_LEFT,
		hl ? "size-3 shrink-0 text-white/60" : "size-3 shrink-0 text-muted-foreground/50",
	)
	if marked {
		mark_badge(ui, "size-6", "size-3", hl)
	} else {
		avatar(ui, m.from, "size-6", "text-[10]")
	}

	p.col(ui, "flex-1 min-w-0 gap-0")
	p.row(ui, "items-center gap-1.5 w-full min-w-0")
	p.text(
		ui,
		addr_label(m.from),
		hl \
		? "flex-1 min-w-0 truncate text-[12] font-medium text-white" \
		: unread \
			? "flex-1 min-w-0 truncate text-[12] font-semibold text-foreground" \
			: "flex-1 min-w-0 truncate text-[12] text-foreground",
	)
	if unread {
		p.div(ui, hl ? "size-1.5 rounded-full bg-white shrink-0" : "size-1.5 rounded-full bg-selection shrink-0")
		p.end(ui)
	}
	if len(m.attachments) > 0 {
		p.icon(ui, ICON_PAPERCLIP, hl ? "size-2.5 shrink-0 text-white/80" : "size-2.5 shrink-0 text-muted-foreground")
	}
	if .Flagged in m.flags {
		p.icon(ui, ICON_STAR, hl ? "size-2.5 shrink-0 text-white" : "size-2.5 shrink-0 text-amber-500")
	}
	if .Answered in m.flags {
		p.icon(ui, ICON_REPLY, hl ? "size-2.5 shrink-0 text-white/70" : "size-2.5 shrink-0 text-muted-foreground")
	}
	p.text(
		ui,
		relative_date(m.date, st.now, st.tz_offset, context.temp_allocator),
		hl ? "text-[10.5] text-white/80 whitespace-nowrap" : "text-[10.5] text-muted-foreground whitespace-nowrap",
	)
	p.style(ui).shrink = 0
	p.end(ui)
	p.text(
		ui,
		m.snippet,
		hl ? "w-full truncate text-[11] text-white/70" : "w-full truncate text-[11] text-muted-foreground",
	)
	p.end(ui)
}

// ---------------------------------------------------------------------------
// Reader
// ---------------------------------------------------------------------------

reader_pane :: proc(ui: ^p.Ctx, st: ^State) {
	p.col(ui, "flex-1 min-w-0 h-full bg-background overflow-hidden")
	defer p.end(ui)

	mi := st.reader_msg
	if mi < 0 || mi >= len(st.messages) {
		empty_state(ui, ICON_MAIL_OPEN, "No message selected", "Pick a conversation on the left, or press C to write one.")
		return
	}
	m := st.messages[mi]

	container := p.col(ui, "flex-1 min-h-0 w-full px-6 py-5 gap-4 overflow-scroll")
	st.read_id = p.node_id(ui, container)
	defer p.end(ui)

	// Subject and the thread position.
	p.col(ui, "gap-1.5 w-full shrink-0")
	p.text(ui, m.subject, "w-full text-[18] font-semibold text-foreground leading-[24]")
	p.row(ui, "items-center gap-1.5 flex-wrap")
	if st.show_raw {
		badge_pill(ui, tfmt("%s", m.id == "" ? "no Message-ID" : m.id), ICON_HASH, "bg-muted text-muted-foreground")
	}
	if ti := m.thread; ti >= 0 && ti < len(st.threads) && len(st.threads[ti].msgs) > 1 {
		badge_pill(
			ui,
			tfmt("%d in conversation", len(st.threads[ti].msgs)),
			ICON_MAILS,
			"bg-muted text-muted-foreground",
		)
	}
	if m.folder >= 0 && m.folder < len(st.folders) {
		f := st.folders[m.folder]
		a := st.accounts[f.account]
		badge_pill(
			ui,
			tfmt("%s · %s · %s", a.name, account_kind(a), f.name),
			a.discovered ? ICON_FOLDER : protocol_icon(a.protocol),
			"bg-muted text-muted-foreground",
		)
	}
	if .Flagged in m.flags {
		badge_pill(ui, "Flagged", ICON_STAR, "bg-amber-500/15 text-amber-600")
	}
	if .Answered in m.flags {
		badge_pill(ui, "Answered", ICON_REPLY, "bg-emerald-500/15 text-emerald-700")
	}
	if .Draft in m.flags {
		badge_pill(ui, "Draft", ICON_PENCIL, "bg-muted text-muted-foreground")
	}
	if msg_unread(m) {
		badge_pill(ui, "Unread", ICON_DOT, "bg-selection/15 text-selection")
	}
	p.end(ui)
	p.end(ui)

	sc.separator(ui)

	// Sender block.
	p.row(ui, "items-start gap-3 w-full shrink-0")
	avatar(ui, m.from, "size-10", "text-[14]")
	p.col(ui, "flex-1 min-w-0 gap-0.5")
	p.row(ui, "items-center gap-2 min-w-0")
	p.text(ui, addr_label(m.from), "truncate text-[13.5] font-semibold text-foreground")
	p.text(ui, tfmt("<%s>", m.from.email), "truncate text-[11.5] text-muted-foreground")
	p.end(ui)
	addr_line(ui, "To", m.to)
	addr_line(ui, "Cc", m.cc)
	p.end(ui)
	p.col(ui, "items-end gap-0.5 shrink-0")
	p.text(
		ui,
		full_date(m.date, st.tz_offset, context.temp_allocator),
		"text-[11] text-muted-foreground whitespace-nowrap",
	)
	p.style(ui).shrink = 0
	p.text(ui, human_bytes(m.size, context.temp_allocator), "text-[10.5] text-muted-foreground/70 whitespace-nowrap")
	p.style(ui).shrink = 0
	p.end(ui)
	p.end(ui)

	if len(m.attachments) > 0 {
		attachments_block(ui, st, m)
	}

	// The HTML fallback has to announce itself. Calling a text reduction
	// "rendering" would be a lie, and a reader that silently drops layout,
	// tables and images without saying so is worse than one that admits it.
	if m.from_html {
		p.row(ui, "items-center gap-2 w-full shrink-0 px-3 py-2 rounded-lg bg-amber-500/10 border border-amber-500/30")
		p.icon(ui, ICON_TRIANGLE_ALERT, "size-3.5 shrink-0 text-amber-600")
		p.col(ui, "flex-1 min-w-0 gap-0")
		p.text(ui, "HTML message, shown as text", "text-[11.5] font-semibold text-amber-700")
		p.text(
			ui,
			m.had_plain \
			? "This part had no plain text, so the HTML was reduced to readable text." \
			: "There is no plain-text part. Block tags became breaks and entities were decoded; styles, scripts and images were dropped. No remote resource is ever loaded.",
			"w-full text-[11] text-amber-700/80",
		)
		p.end(ui)
		p.end(ui)
	}

	if st.show_raw {
		raw_headers(ui, m)
	}

	body_block(ui, m)

	// Quick actions at the foot of the message, where a reader's hand lands.
	p.row(ui, "items-center gap-2 w-full shrink-0 pt-1")
	action_button(ui, "r-reply", ICON_REPLY, "Reply", "R")
	action_button(ui, "r-all", ICON_REPLY_ALL, "Reply all", "A")
	action_button(ui, "r-fwd", ICON_FORWARD, "Forward", "F")
	p.end(ui)
}

action_button :: proc(ui: ^p.Ctx, key: string, ic: p.Icon, label, kb: string) {
	p.key(ui, key)
	p.row(ui, "h-7 shrink-0 items-center gap-1.5 px-2.5 rounded-lg border border-border bg-background text-foreground hover:bg-muted transition cursor-pointer")
	defer p.end(ui)
	p.icon(ui, ic, "size-3.5 shrink-0")
	p.text(ui, label, "text-[12] font-medium whitespace-nowrap")
	p.style(ui).shrink = 0
	sc.kbd(ui, kb, "h-4 min-w-4 text-[9.5]")
}

addr_line :: proc(ui: ^p.Ctx, label: string, as_: []Address) {
	if len(as_) == 0 {
		return
	}
	p.row(ui, "items-baseline gap-1.5 w-full min-w-0")
	p.text(ui, label, "w-[18] shrink-0 text-[10.5] font-medium text-muted-foreground/70")
	p.text(
		ui,
		join_addresses(as_, context.temp_allocator),
		"flex-1 min-w-0 truncate text-[11.5] text-muted-foreground",
	)
	p.end(ui)
}

badge_pill :: proc(ui: ^p.Ctx, label: string, ic: p.Icon, class: string) {
	p.row(ui, tfmt("h-5 shrink-0 items-center gap-1 px-1.5 rounded-full %s", class))
	defer p.end(ui)
	p.icon(ui, ic, "size-2.5 shrink-0")
	p.text(ui, label, "text-[10] font-medium whitespace-nowrap")
	p.style(ui).shrink = 0
}

MAX_ATTACHMENT_CHIPS :: 24

// attachments_block is the reader's list of files. Each chip is clickable —
// click selects, the download button saves — and the keyboard walks the same
// list with V and saves with W.
//
// Inline images the message's own HTML points at with a `cid:` URL are counted
// on a separate line rather than listed here. They are part of how the message
// reads; offering "save logo.png" for a signature image is noise.
attachments_block :: proc(ui: ^p.Ctx, st: ^State, m: Message) {
	saveable := saveable_attachments(m)
	inline_n := inline_attachment_count(m)

	p.col(ui, "w-full shrink-0 gap-1.5")
	defer p.end(ui)

	p.row(ui, "items-center gap-1.5")
	p.icon(ui, ICON_PAPERCLIP, "size-3 shrink-0 text-muted-foreground")
	p.text(
		ui,
		tfmt("%d attachment%s", len(saveable), plural(len(saveable))),
		"text-[11] font-medium text-muted-foreground",
	)
	p.style(ui).shrink = 0
	if inline_n > 0 {
		p.text(
			ui,
			tfmt("·  %d inline image%s the message refers to, not listed", inline_n, plural(inline_n)),
			"text-[10.5] text-muted-foreground/70 whitespace-nowrap",
		)
		p.style(ui).shrink = 0
	}
	p.spacer(ui, "flex-1")
	if len(saveable) > 0 {
		p.row(ui, "shrink-0 items-center gap-1")
		sc.kbd(ui, "V", "h-4 text-[9.5]")
		p.text(ui, "choose", "text-[10] text-muted-foreground/70 whitespace-nowrap")
		p.style(ui).shrink = 0
		sc.kbd(ui, "W", "h-4 text-[9.5]")
		p.text(ui, "save", "text-[10] text-muted-foreground/70 whitespace-nowrap")
		p.style(ui).shrink = 0
		p.end(ui)
	}
	p.end(ui)

	if len(saveable) == 0 {
		return
	}

	// A wrapping row of chips.
	//
	// This was a column of full-width rows for a while, and the comment there
	// said why: each chip carries a Save button, five of them are wider than
	// the reading pane, and palmy's `flex-wrap` used to lay a second line out
	// without growing the row's height — so the overflow drew straight over
	// the message body. The toolkit now measures a wrapping box against the
	// width it really got rather than the width it was offered, and asks for
	// one more frame when that width changes. This pane is the awkward case:
	// `flex-1 min-w-0` beside two fixed siblings, so it is offered the whole
	// window while measuring and gets the remainder while arranging. It is
	// therefore right from the *second* frame, not the first.
	//
	// The ids are kept for the same reason the list's are — the geometry only
	// exists once the tree has been laid out — and `--uitest` asserts the row
	// is as tall as the lines it laid out rather than trusting a screenshot.
	box := p.row(ui, "w-full flex-wrap gap-2")
	st.att_box_id = p.node_id(ui, box)
	st.att_chip_n = 0
	for ai, k in saveable {
		if k >= MAX_ATTACHMENT_CHIPS {
			p.text(
				ui,
				tfmt("+%d more", len(saveable) - MAX_ATTACHMENT_CHIPS),
				"text-[11] text-muted-foreground",
			)
			break
		}
		at := m.attachments[ai]
		on := st.att_sel == k

		p.key(ui, tfmt("att:%d", ai))
		row := p.row(ui, "h-9 shrink-0 items-center gap-2 pl-2 pr-1.5 rounded-lg border bg-muted/40 transition cursor-pointer")
		p.apply(ui, on ? "border-selection ring-2 ring-selection/35" : "border-border hover:bg-muted", row)
		if p.clickable(ui, row) {
			st.att_sel = k
		}
		if st.att_chip_n < len(st.att_chip_ids) {
			st.att_chip_ids[st.att_chip_n] = p.node_id(ui, row)
			st.att_chip_n += 1
		}
		p.icon(ui, attachment_icon(at.mime), "size-4 shrink-0 text-muted-foreground")
		p.col(ui, "gap-0 max-w-[190] shrink")
		p.text(ui, at.name, "truncate text-[11.5] font-medium text-foreground")
		p.text(
			ui,
			tfmt("%s · %s", at.mime, human_bytes(at.size, context.temp_allocator)),
			"truncate text-[10] text-muted-foreground",
		)
		p.end(ui)

		// The save button. A list without one would be a list of things you
		// can look at and not open, which is what this was before.
		p.key(ui, tfmt("att-save:%d", ai))
		btn := p.row(ui, "h-6 shrink-0 items-center gap-1 px-1.5 rounded-md transition cursor-pointer hover:bg-selection hover:text-white text-muted-foreground")
		if p.clickable(ui, btn) {
			st.att_sel = k
			begin_save_attachment(st)
		}
		p.icon(ui, ICON_DOWNLOAD, "size-3.5 shrink-0")
		p.text(ui, "Save", "text-[10.5] font-medium whitespace-nowrap")
		p.style(ui).shrink = 0
		p.end(ui)
		p.end(ui)
	}
	p.end(ui)
}

attachment_icon :: proc(mime: string) -> p.Icon {
	switch {
	case strings.has_prefix(mime, "image/"):
		return ICON_IMAGE
	case strings.has_prefix(mime, "text/"):
		return ICON_FILE_TEXT
	}
	return ICON_PAPERCLIP
}

raw_headers :: proc(ui: ^p.Ctx, m: Message) {
	p.col(ui, "w-full shrink-0 gap-0.5 px-3 py-2 rounded-lg bg-muted/50 border border-border")
	defer p.end(ui)
	raw_line(ui, "Message-ID", m.id == "" ? "(none)" : m.id)
	raw_line(ui, "In-Reply-To", m.in_reply_to == "" ? "(none)" : m.in_reply_to)
	raw_line(ui, "References", tfmt("%d", len(m.refs)))
	raw_line(ui, "Maildir file", m.file)
	raw_line(ui, "Parts", m.had_plain && m.had_html ? "text/plain + text/html" : m.had_html ? "text/html only" : "text/plain")
}

raw_line :: proc(ui: ^p.Ctx, k, v: string) {
	p.row(ui, "items-baseline gap-2 w-full min-w-0")
	p.text(ui, k, "w-[92] shrink-0 text-[10] font-medium text-muted-foreground/70")
	p.text(ui, v, "flex-1 min-w-0 truncate font-mono text-[10.5] text-muted-foreground")
	p.end(ui)
}

// body_block renders the plain text. Quoted runs are grouped and set apart
// with a rule, which is the whole difference between a readable reply and a
// wall of angle brackets.
// READER_MAX_LINES and READER_MAX_BYTES bound what the reader will lay out.
//
// A body is whatever arrived, and "whatever arrived" can be a two-megabyte log
// file someone pasted into a mail. Every line is an element, so an unbounded
// body is an unbounded frame: measured at a second per frame on a 160,000-line
// message before this cap existed. Clipping is what every mail client does,
// and it says so rather than silently losing the rest.
READER_MAX_LINES :: 1500
READER_MAX_BYTES :: 192 * 1024

body_block :: proc(ui: ^p.Ctx, m: Message) {
	p.col(ui, "w-full shrink-0 gap-2.5 pb-2")
	defer p.end(ui)

	if strings.trim_space(m.body) == "" {
		p.text(ui, "(This message has no readable text.)", "text-[12.5] text-muted-foreground")
		return
	}

	body, clipped_lines, clipped := clip_body(m.body)
	rest := body
	run := strings.builder_make(context.temp_allocator)
	run_quoted := false
	have := false

	flush :: proc(ui: ^p.Ctx, run: ^strings.Builder, quoted: bool) {
		text := strings.trim_right(strings.to_string(run^), "\n")
		if strings.trim_space(text) == "" {
			strings.builder_reset(run)
			return
		}
		if quoted {
			p.row(ui, "w-full shrink-0 gap-2.5")
			p.div(ui, "w-[2] shrink-0 self-stretch rounded-full bg-border")
			p.end(ui)
			p.text(ui, text, "flex-1 min-w-0 text-[12.5] text-muted-foreground leading-[19]")
			p.end(ui)
		} else {
			p.text(ui, text, "w-full text-[13] text-foreground leading-[20]")
		}
		strings.builder_reset(run)
	}

	for line in strings.split_lines_iterator(&rest) {
		l := strings.trim_right(line, "\r")
		quoted := len(l) > 0 && l[0] == '>'
		stripped := l
		if quoted {
			stripped = strings.trim_left(l, "> ")
			if stripped == "" {
				stripped = " "
			}
		}
		if have && quoted != run_quoted {
			flush(ui, &run, run_quoted)
		}
		run_quoted = quoted
		have = true
		strings.write_string(&run, quoted ? stripped : l)
		strings.write_byte(&run, '\n')
	}
	flush(ui, &run, run_quoted)

	if clipped {
		p.row(ui, "items-center gap-2 w-full shrink-0 px-3 py-2 rounded-lg bg-muted/60 border border-border")
		p.icon(ui, ICON_INFO, "size-3.5 shrink-0 text-muted-foreground")
		p.text(
			ui,
			tfmt(
				"Message clipped — %d more line%s are in the file on disk but are not shown here.",
				clipped_lines,
				plural(clipped_lines),
			),
			"flex-1 min-w-0 text-[11.5] text-muted-foreground",
		)
		p.end(ui)
	}
}

// clip_body cuts a body to what the reader will lay out, on a line boundary,
// and reports how many lines were left behind.
clip_body :: proc(body: string) -> (shown: string, dropped: int, clipped: bool) {
	lines, at, cut := 0, 0, -1
	for i in 0 ..< len(body) {
		if body[i] != '\n' {
			continue
		}
		lines += 1
		at = i + 1
		if cut < 0 && (lines >= READER_MAX_LINES || at >= READER_MAX_BYTES) {
			cut = at
		}
	}
	if len(body) > at {
		lines += 1
	}
	if cut < 0 {
		return body, 0, false
	}
	seen := 0
	for i in 0 ..< cut {
		if body[i] == '\n' {
			seen += 1
		}
	}
	return body[:cut], max(0, lines - seen), true
}

// ---------------------------------------------------------------------------
// Composer
// ---------------------------------------------------------------------------

composer :: proc(ui: ^p.Ctx, st: ^State) {
	c := &st.comp

	// A scrim over the panes. There is no xdg_popup here, so the sheet is an
	// absolutely positioned overlay inside the one window.
	scrim := p.div(ui, "absolute inset-0 z-40 bg-black/35")
	if p.clickable(ui, scrim) {
		close_composer(st)
	}
	p.end(ui)

	wrap := p.col(ui, "absolute z-50 left-[64] right-[64] top-[64] bottom-[48] rounded-xl bg-popover border border-border shadow-2xl overflow-hidden")
	_ = wrap
	defer p.end(ui)

	// Header.
	p.row(ui, "h-[46] shrink-0 w-full items-center gap-2 px-4 border-b border-border bg-sidebar")
	title := "New message"
	switch c.mode {
	case .New:
		title = "New message"
	case .Reply:
		title = "Reply"
	case .Reply_All:
		title = "Reply to all"
	case .Forward:
		title = "Forward"
	}
	p.icon(ui, ICON_SQUARE_PEN, "size-4 shrink-0 text-selection")
	p.text(ui, title, "text-[13.5] font-semibold text-foreground")
	p.style(ui).shrink = 0

	a := st.accounts[clamp(c.account, 0, max(0, len(st.accounts) - 1))]
	p.div(ui, "flex-row h-5 shrink-0 items-center gap-1 px-1.5 rounded-full bg-muted")
	p.icon(
		ui,
		a.discovered ? ICON_FOLDER : protocol_icon(a.protocol),
		a.discovered \
		? "size-2.5 shrink-0 text-muted-foreground" \
		: tfmt("size-2.5 shrink-0 %s", protocol_tint(a.protocol)),
	)
	p.text(
		ui,
		a.address == "" ? tfmt("%s · %s", a.name, account_kind(a)) : tfmt("%s · %s", a.name, a.address),
		"text-[10] text-muted-foreground whitespace-nowrap",
	)
	p.style(ui).shrink = 0
	p.end(ui)

	p.spacer(ui, "flex-1")

	x := p.div(ui, "flex-row size-6 shrink-0 items-center justify-center rounded-md hover:bg-accent cursor-pointer transition")
	if p.clickable(ui, x) {
		close_composer(st)
	}
	p.icon(ui, ICON_X, "size-3.5 text-muted-foreground")
	p.end(ui)
	p.end(ui)

	// Fields.
	p.col(ui, "flex-1 min-h-0 w-full")

	compose_field(ui, st, .To, "To", &c.to)
	ac_popup(ui, st, .To)
	compose_field(ui, st, .Cc, "Cc", &c.cc)
	ac_popup(ui, st, .Cc)
	compose_field(ui, st, .Subject, "Subject", &c.subject)

	// The body, with a real cursor.
	body_focus := c.field == .Body
	edit := p.col(ui, "flex-1 min-h-0 w-full px-4 py-3 gap-0 overflow-scroll")
	if body_focus {
		p.apply(ui, "bg-background", edit)
	}
	if p.clickable(ui, edit) {
		c.field = .Body
	}
	for i in 0 ..< buf_line_count(&c.body) {
		line := buf_line(&c.body, i)
		p.key(ui, tfmt("bl:%d", i))
		p.row(ui, "w-full shrink-0 min-h-[20] items-center")
		if body_focus && i == c.body.cur.line {
			caret_text(ui, line, c.body.cur.col, true, 13, "text-[13] text-foreground")
		} else {
			p.text(ui, line, "flex-1 min-w-0 text-[13] text-foreground leading-[20] whitespace-nowrap")
			p.style(ui).shrink = 0
		}
		p.end(ui)
	}
	p.end(ui)
	p.end(ui)

	// Footer: Send, and a plain statement of what Send does.
	p.row(ui, "h-[52] shrink-0 w-full items-center gap-2 px-4 border-t border-border bg-sidebar")

	send_focus := c.field == .Send
	{
		idx := p.row(ui, "h-8 shrink-0 items-center gap-1.5 pl-2 pr-2.5 rounded-lg bg-primary text-primary-foreground cursor-pointer transition hover:bg-primary/80")
		if send_focus {
			p.apply(ui, "ring-3 ring-ring/50 border-ring", idx)
		}
		if p.clickable(ui, idx) {
			c.confirm = true
		}
		p.icon(ui, ICON_SEND, "size-3.5 shrink-0")
		p.text(ui, "Send", "text-[13] font-medium whitespace-nowrap")
		p.style(ui).shrink = 0
		p.end(ui)
	}
	{
		idx := p.row(ui, "h-8 shrink-0 items-center gap-1.5 px-2.5 rounded-lg border border-border bg-background hover:bg-muted cursor-pointer transition")
		if p.clickable(ui, idx) {
			discard_composer(st)
		}
		p.text(ui, "Discard", "text-[13] text-foreground whitespace-nowrap")
		p.style(ui).shrink = 0
		p.end(ui)
	}

	p.row(ui, "flex-1 min-w-0 items-center gap-1.5 justify-end")
	if c.saved_any {
		// Saying when it was last kept is the whole point of keeping it: a
		// promise with no evidence is not one anybody can rely on.
		p.row(ui, "shrink-0 items-center gap-1 px-1.5 h-[18] rounded-full bg-muted")
		p.icon(ui, ICON_CHECK, "size-2.5 shrink-0 text-emerald-600")
		p.text(
			ui,
			tfmt("Draft saved %s", clock_of(c.saved_at, st.tz_offset, context.temp_allocator)),
			"text-[10] text-muted-foreground whitespace-nowrap",
		)
		p.style(ui).shrink = 0
		p.end(ui)
	}
	p.icon(ui, ICON_LOCK, "size-3 shrink-0 text-emerald-600")
	p.text(
		ui,
		tfmt("Queues to %s/.Outbox — never transmitted", a.name),
		"truncate text-[10.5] text-muted-foreground",
	)
	p.end(ui)

	p.row(ui, "shrink-0 items-center gap-1")
	sc.kbd(ui, "Tab", "h-4 text-[9.5]")
	p.text(ui, "field", "text-[10] text-muted-foreground/70 whitespace-nowrap")
	p.style(ui).shrink = 0
	p.end(ui)
	p.end(ui)

	if c.confirm {
		send_confirm(ui, st)
	}
}

// ac_popup is the suggestion list under an address field.
//
// It is drawn in the flow, directly beneath the field it belongs to, rather
// than floating over the body. Wayland gives this toolkit no xdg_popup — every
// other overlay here is drawn in-window for the same reason — and a list that
// pushes the body down a few rows is honest about the space it is taking.
ac_popup :: proc(ui: ^p.Ctx, st: ^State, which: Compose_Field) {
	c := &st.comp
	if !c.ac_open || c.field != which || len(c.ac_hits) == 0 {
		return
	}
	p.col(ui, "w-full shrink-0 border-b border-border bg-popover py-1")
	defer p.end(ui)

	for h, k in c.ac_hits {
		if h < 0 || h >= len(st.book) {
			continue
		}
		ct := st.book[h]
		on := k == c.ac_sel
		p.key(ui, tfmt("ac:%d", h))
		idx := p.row(ui, "h-[30] shrink-0 w-full items-center gap-2 pl-[64] pr-4 cursor-pointer transition")
		if on {
			p.apply(ui, "bg-selection", idx)
		} else {
			p.apply(ui, "hover:bg-accent", idx)
		}
		if p.clickable(ui, idx) {
			c.ac_sel = k
			ac_accept(st)
		}
		p.icon(ui, ICON_AT_SIGN, on ? "size-3 shrink-0 text-white/80" : "size-3 shrink-0 text-muted-foreground")
		if ct.name != "" {
			p.text(
				ui,
				ct.name,
				on 				? "shrink-0 max-w-[180] truncate text-[12.5] font-medium text-white" 				: "shrink-0 max-w-[180] truncate text-[12.5] font-medium text-foreground",
			)
		}
		p.text(
			ui,
			ct.email,
			on 			? "flex-1 min-w-0 truncate text-[11.5] text-white/75" 			: "flex-1 min-w-0 truncate text-[11.5] text-muted-foreground",
		)
		p.text(
			ui,
			tfmt("%d", ct.count),
			on ? "text-[10] text-white/60 whitespace-nowrap" : "text-[10] text-muted-foreground/70 whitespace-nowrap",
		)
		p.style(ui).shrink = 0
		p.end(ui)
	}

	p.row(ui, "h-[20] shrink-0 w-full items-center gap-1.5 pl-[64] pr-4")
	sc.kbd(ui, "Up", "h-4 text-[9]")
	sc.kbd(ui, "Down", "h-4 text-[9]")
	p.text(ui, "choose", "text-[9.5] text-muted-foreground/70 whitespace-nowrap")
	p.style(ui).shrink = 0
	sc.kbd(ui, "Tab", "h-4 text-[9]")
	p.text(ui, "complete  ·  from the addresses already in this mailbox", "text-[9.5] text-muted-foreground/70 whitespace-nowrap")
	p.style(ui).shrink = 0
	p.end(ui)
}

compose_field :: proc(ui: ^p.Ctx, st: ^State, which: Compose_Field, label: string, e: ^Line_Edit) {
	c := &st.comp
	focus := c.field == which
	idx := p.row(ui, "h-[38] shrink-0 w-full items-center gap-2 px-4 border-b border-border cursor-text transition")
	if focus {
		p.apply(ui, "bg-background", idx)
	}
	if p.clickable(ui, idx) {
		c.field = which
	}
	defer p.end(ui)

	p.text(
		ui,
		label,
		focus \
		? "w-[56] shrink-0 text-[11.5] font-semibold text-foreground" \
		: "w-[56] shrink-0 text-[11.5] font-medium text-muted-foreground",
	)

	text := le_text(e)
	if text == "" && !focus {
		p.text(
			ui,
			which == .Subject ? "Subject" : "name@host.test",
			"flex-1 min-w-0 text-[13] text-muted-foreground/60 whitespace-nowrap",
		)
		p.style(ui).shrink = 0
	} else {
		caret_text(ui, text, e.cur, focus, 13, "text-[13] text-foreground")
	}

	if focus {
		p.div(ui, "w-[3] h-5 shrink-0 rounded-full bg-selection")
		p.end(ui)
	}
}

// send_confirm is the one gate in front of Send. Sending is irreversible in a
// real client, so the button says exactly where the message is going before it
// goes — and here that is a file on this machine.
send_confirm :: proc(ui: ^p.Ctx, st: ^State) {
	c := &st.comp
	a := st.accounts[clamp(c.account, 0, max(0, len(st.accounts) - 1))]

	scrim := p.div(ui, "absolute inset-0 z-50 bg-black/40")
	if p.clickable(ui, scrim) {
		c.confirm = false
	}
	p.end(ui)

	// Centred without `left-1/2`: a full-width band with an auto-margined card
	// inside it, which is the layout palmy's flexbox actually supports.
	p.row(ui, "absolute z-50 left-[24] right-[24] top-[88] justify-center")
	defer p.end(ui)
	p.col(ui, "w-full max-w-[480] rounded-xl bg-popover border border-border shadow-2xl p-5 gap-3")
	defer p.end(ui)

	p.row(ui, "items-center gap-2 shrink-0")
	p.icon(ui, ICON_SEND, "size-4 shrink-0 text-selection")
	p.text(ui, "Queue this message?", "text-[14] font-semibold text-foreground")
	p.style(ui).shrink = 0
	p.end(ui)

	p.text(
		ui,
		tfmt(
			"It will be written to %s/.Outbox as a Maildir file. This client has no network code: nothing is transmitted, to anyone.",
			a.root,
		),
		"w-full text-[12] text-muted-foreground leading-[18]",
	)

	p.col(ui, "w-full shrink-0 gap-1 px-3 py-2 rounded-lg bg-muted/60 border border-border")
	raw_line(ui, "To", le_text(&c.to))
	if strings.trim_space(le_text(&c.cc)) != "" {
		raw_line(ui, "Cc", le_text(&c.cc))
	}
	raw_line(ui, "Subject", le_text(&c.subject))
	raw_line(ui, "Body", tfmt("%d bytes, %d lines", buf_byte_len(&c.body), buf_line_count(&c.body)))
	if c.in_reply_to != "" {
		raw_line(ui, "In-Reply-To", c.in_reply_to)
	}
	p.end(ui)

	p.row(ui, "items-center gap-2 shrink-0 pt-1")
	{
		idx := p.row(ui, "h-8 shrink-0 items-center gap-1.5 px-3 rounded-lg bg-primary text-primary-foreground ring-3 ring-ring/50 cursor-pointer transition hover:bg-primary/80")
		if p.clickable(ui, idx) {
			do_send(st)
		}
		p.icon(ui, ICON_CHECK, "size-3.5 shrink-0")
		p.text(ui, "Queue it", "text-[13] font-medium whitespace-nowrap")
		p.style(ui).shrink = 0
		p.end(ui)
	}
	{
		idx := p.row(ui, "h-8 shrink-0 items-center px-3 rounded-lg border border-border bg-background hover:bg-muted cursor-pointer transition")
		if p.clickable(ui, idx) {
			c.confirm = false
		}
		p.text(ui, "Cancel", "text-[13] whitespace-nowrap")
		p.style(ui).shrink = 0
		p.end(ui)
	}
	p.spacer(ui, "flex-1")
	p.row(ui, "shrink-0 items-center gap-1")
	sc.kbd(ui, "Enter", "h-4 text-[9.5]")
	p.text(ui, "confirm", "text-[10] text-muted-foreground/70 whitespace-nowrap")
	p.style(ui).shrink = 0
	p.end(ui)
	p.end(ui)
}

// ---------------------------------------------------------------------------
// Status bar, empty state, toast
// ---------------------------------------------------------------------------

status_bar :: proc(ui: ^p.Ctx, st: ^State) {
	p.row(
		ui,
		tfmt("h-[%d] shrink-0 w-full items-center gap-2 px-3 bg-sidebar border-t border-border", STATUS_H),
	)
	defer p.end(ui)

	total, unread := 0, 0
	for m in st.messages {
		total += 1
		if msg_unread(m) {
			unread += 1
		}
	}
	p.text(
		ui,
		tfmt("%d messages · %d unread · %d folders · %d accounts", total, unread, len(st.folders), len(st.accounts)),
		"text-[11] text-muted-foreground whitespace-nowrap",
	)
	p.style(ui).shrink = 0

	if st.warn != "" {
		p.text(ui, "·", "text-[11] text-muted-foreground/50")
		p.row(ui, "items-center gap-1 min-w-0")
		p.icon(ui, ICON_SHIELD_OFF, "size-3 shrink-0 text-destructive")
		p.text(ui, st.warn, "truncate text-[11] text-destructive")
		p.end(ui)
	}

	if st.draft_waiting || (!st.comp.open && st.comp.saved_any) {
		// A draft from a previous run. It is not opened for you; it is said
		// out loud, with the key that picks it up.
		p.text(ui, "·", "text-[11] text-muted-foreground/50")
		p.row(ui, "items-center gap-1 min-w-0 shrink")
		p.icon(ui, ICON_PENCIL, "size-3 shrink-0 text-selection")
		label := st.draft_label
		if !st.draft_waiting {
			// Saved in this session rather than found at startup: say what it
			// is from the composer, which still holds it.
			label = strings.trim_space(le_text(&st.comp.subject))
			if label == "" {
				label = strings.trim_space(le_text(&st.comp.to))
			}
			if label == "" {
				label = "an unsent message"
			}
		}
		p.text(ui, tfmt("Unsent draft: %s", label), "truncate text-[11] text-foreground")
		sc.kbd(ui, "C", "h-4 text-[9.5]")
		p.end(ui)
	}

	p.spacer(ui, "flex-1")

	// Which pane has the keyboard, because every key means something different
	// depending on the answer.
	names := [?]string{"Folders", "List", "Reader", "Search", "Compose"}
	p.row(ui, "shrink-0 items-center gap-1.5")
	p.icon(ui, ICON_PANEL_RIGHT, "size-3 shrink-0 text-muted-foreground/70")
	p.text(ui, names[int(st.pane)], "text-[11] font-medium text-muted-foreground whitespace-nowrap")
	p.style(ui).shrink = 0
	sc.kbd(ui, "Tab", "h-4 text-[9.5]")
	p.end(ui)

	// The standing promise, on screen, at all times.
	sc.separator(ui, .Vertical, "h-4 mx-1 shrink-0")
	p.row(ui, "shrink-0 items-center gap-1")
	p.icon(ui, ICON_LOCK, "size-3 shrink-0 text-emerald-600")
	p.text(ui, "Offline · reads a local Maildir", "text-[11] text-muted-foreground whitespace-nowrap")
	p.style(ui).shrink = 0
	p.end(ui)
}

empty_state :: proc(ui: ^p.Ctx, ic: p.Icon, title, body: string) {
	p.col(ui, "flex-1 min-h-0 w-full items-center justify-center gap-3 px-10")
	defer p.end(ui)

	p.div(ui, "flex-row size-12 items-center justify-center rounded-2xl bg-muted shrink-0")
	p.icon(ui, ic, "size-6 text-muted-foreground")
	p.end(ui)
	p.text(ui, title, "text-[14] font-semibold text-foreground")
	p.text(ui, body, "max-w-[360] text-center text-[12.5] text-muted-foreground")
}

toast :: proc(ui: ^p.Ctx, st: ^State) {
	if st.toast == "" {
		return
	}
	if st.toast_at == 0 {
		st.toast_at = f64(p.elapsed(ui))
	}
	age := f64(p.elapsed(ui)) - st.toast_at
	if age > 3.4 {
		delete(st.toast)
		st.toast = ""
		st.toast_at = 0
		return
	}
	p.redraw(ui)

	idx := p.row(
		ui,
		"absolute z-50 right-[16] bottom-[40] max-w-[520] items-center gap-2 px-3 py-2 rounded-lg bg-popover border border-border shadow-lg",
	)
	p.style(ui, idx).no_hit = true
	p.icon(ui, ICON_INFO, "size-3.5 shrink-0 text-selection")
	p.text(ui, st.toast, "truncate text-[12] text-foreground")
	p.end(ui)
}

// retitle keeps the window title in step with the folder, the way a mail
// client puts the unread count where the taskbar can see it.
@(private = "file")
last_title: string

retitle :: proc(app: ^p.App, st: ^State) {
	t := "Mail"
	if st.folder_sel >= 0 && st.folder_sel < len(st.folders) {
		f := st.folders[st.folder_sel]
		a := st.accounts[f.account]
		t = f.unread > 0 \
			? tfmt("%s — %s (%d) — Mail", a.name, f.name, f.unread) \
			: tfmt("%s — %s — Mail", a.name, f.name)
	}
	if t != last_title {
		delete(last_title)
		last_title = strings.clone(t)
		p.set_title(app, last_title)
	}
}
