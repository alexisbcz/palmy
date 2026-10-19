// Palmy: one account, several identities, each its own mailbox.
//
// This binary still opens no socket. Signing in and syncing are done by
// `mailcore palm login` and `mailcore palm sync`, run as child processes, and
// what they leave behind is what this file reads:
//
//	<data>/palmy.conf     the identities the session can reach
//	<data>/<address>/         one Maildir per identity
//
// Each identity becomes an account here, marked `palm`, carrying its kind
// (personal, work...) and colour so it is labelled the same way everywhere.
//
// THE VIEWS.
//
//   Per identity (the default when signed in): `1`..`9` pick an identity and
//   the sidebar shows only that identity's folders. `0` shows every identity.
//   Mail from two identities is never in one list in this view — the
//   separation the server enforces is the separation the UI shows.
//
//   Unified inbox (a prototype, off by default): Shift+I turns on an "All
//   inboxes" view that lists every identity's inbox together, each
//   conversation carrying a chip that says which identity it came to. It is
//   behind a toggle because whether it should exist at all is a product
//   question — it is exactly the cross-identity view the rest of the design
//   avoids — and the toggle makes it something to try rather than a default.
//
// The Outbox of a Palmy identity holds mail the server would not deliver:
// anything addressed outside the local domain. It is shown with a banner that
// says so, because "queued" and "will never be sent" are different things.
package main

import "core:fmt"
import "core:os"
import "core:strings"
import kit "kit:."
import p "palmy:."
import sc "shadcn:."

PALM_COLORS :: [?]string{"indigo", "emerald", "amber", "rose", "sky", "violet", "teal", "orange", "fuchsia", "lime", "cyan", "pink", "slate"}

palm_color :: proc(c: string) -> string {
	for ok in PALM_COLORS {
		if c == ok {
			return c
		}
	}
	return "slate"
}

palm_conf_path :: proc(dir: string, allocator := context.allocator) -> string {
	return fmt.aprintf("%s/palmy.conf", dir, allocator = allocator)
}

// load_palmy appends one account per identity in palmy.conf.
load_palmy :: proc(st: ^State) {
	raw, ok := read_file(palm_conf_path(st.data_dir, context.temp_allocator), context.temp_allocator)
	if !ok {
		return
	}
	section := ""
	cur := -1
	text := string(raw)
	for line in strings.split_lines_iterator(&text) {
		l := strings.trim_space(line)
		if l == "" || l[0] == '#' {
			continue
		}
		if l[0] == '[' {
			section = strings.trim(l, "[]")
			if section == "identity" {
				append(&st.accounts, Account{protocol = .JMAP, host = strings.clone("127.0.0.1"), loopback = true, palm = true})
				cur = len(st.accounts) - 1
			}
			continue
		}
		eq := strings.index_byte(l, '=')
		if eq < 0 {
			continue
		}
		k, v := strings.trim_space(l[:eq]), strings.trim_space(l[eq + 1:])
		if section == "session" {
			if k == "email" {
				delete(st.palm_email)
				st.palm_email = strings.clone(v)
			}
			continue
		}
		if section != "identity" || cur < 0 {
			continue
		}
		a := &st.accounts[cur]
		switch k {
		case "id":
			a.identity_id = strings.clone(v)
		case "handle":
			a.handle = strings.clone(v)
		case "name":
			a.name = strings.clone(v)
		case "kind":
			a.kind = strings.clone(v)
		case "color":
			a.color = strings.clone(palm_color(v))
		case "address":
			a.address = strings.clone(v)
		case "path":
			// Only a single path component inside the data directory.
			if v != "" && strings.index_byte(v, '/') < 0 && !strings.contains(v, "..") {
				a.root = fmt.aprintf("%s/%s", st.data_dir, v)
			}
		}
	}
	// An identity without a usable path is dropped rather than pointed
	// somewhere it should not read.
	for i := len(st.accounts) - 1; i >= 0; i -= 1 {
		a := st.accounts[i]
		if a.palm && (a.root == "" || a.address == "") {
			ordered_remove(&st.accounts, i)
		}
	}
	for &a in st.accounts {
		if a.palm && a.name == "" {
			a.name = strings.clone(a.address)
		}
	}
}

palm_identities :: proc(st: ^State) -> int {
	n := 0
	for a in st.accounts {
		if a.palm {
			n += 1
		}
	}
	return n
}

// palm_nth returns the account index of the n-th identity (0-based), or -1.
palm_nth :: proc(st: ^State, n: int) -> int {
	k := 0
	for a, i in st.accounts {
		if a.palm {
			if k == n {
				return i
			}
			k += 1
		}
	}
	return -1
}

// account_visible: in a per-identity view only that identity's account is
// in the sidebar.
account_visible :: proc(st: ^State, ai: int) -> bool {
	return st.id_view == 0 || st.id_view - 1 == ai
}

// set_identity_view switches to one identity (an account index) or, with -1,
// to all of them, and opens that view's inbox.
set_identity_view :: proc(st: ^State, ai: int) {
	st.id_view = ai < 0 ? 0 : ai + 1
	st.unified = false
	rebuild_sidebar(st)
	for f, fi in st.folders {
		if f.role == .Inbox && (ai < 0 || f.account == ai) {
			select_folder(st, fi)
			break
		}
	}
	if ai >= 0 {
		a := st.accounts[ai]
		note(st, tfmt("Viewing %s · %s", a.name, a.address))
	} else {
		note(st, "Viewing every identity")
	}
}

// set_unified turns the prototype "All inboxes" view on or off.
set_unified :: proc(st: ^State, on: bool) {
	st.unified_on = on
	if on {
		st.id_view = 0
		st.unified = true
		rebuild_sidebar(st)
		st.row_sel = 0
		st.list_scroll_home = true
		rebuild_list(st)
		for r, i in st.side_rows {
			if r.kind == .Unified {
				st.side_sel = i
			}
		}
		note(st, "Unified inbox (prototype): every identity's inbox in one list")
	} else {
		st.unified = false
		rebuild_sidebar(st)
		set_identity_view(st, -1)
	}
}

// unified_set lists the messages the "All inboxes" view shows.
unified_set :: proc(st: ^State, set: ^[dynamic]int) {
	for m, i in st.messages {
		if m.folder < 0 || m.folder >= len(st.folders) || msg_hidden(st, m) {
			continue
		}
		f := st.folders[m.folder]
		if f.role == .Inbox && f.depth == 0 && st.accounts[f.account].palm {
			append(set, i)
		}
	}
}

// palm_outbox: the selected folder is a Palmy identity's Outbox.
palm_outbox :: proc(st: ^State) -> bool {
	if st.unified || st.searching || st.folder_sel < 0 || st.folder_sel >= len(st.folders) {
		return false
	}
	f := st.folders[st.folder_sel]
	return f.role == .Outbox && st.accounts[f.account].palm
}

// ---------------------------------------------------------------------------
// Running mailcore
// ---------------------------------------------------------------------------

// mailcore_path finds the engine: $PALMY_MAILCORE, then beside this binary,
// then the repository's build outputs.
mailcore_path :: proc() -> string {
	if v := os.get_env("PALMY_MAILCORE", context.temp_allocator); v != "" && os.exists(v) {
		return v
	}
	self := os.args[0]
	dir := "."
	if i := strings.last_index_byte(self, '/'); i >= 0 {
		dir = self[:i]
	}
	for cand in ([]string {
			tfmt("%s/mailcore", dir),
			tfmt("%s/mailcore.bin", dir),
			tfmt("%s/../mailcore/mailcore.bin", dir),
			"bin/mailcore",
			"apps/mailcore/mailcore.bin",
		}) {
		if os.exists(cand) {
			return strings.clone(cand, context.temp_allocator)
		}
	}
	return ""
}

// mailcore_argv prefixes the command so mailcore writes into this app's data
// directory: it derives its root from XDG_DATA_HOME, so when this app runs
// against anything but the default directory, the child is told where.
mailcore_argv :: proc(st: ^State, args: ..string) -> []string {
	out := make([dynamic]string, 0, len(args) + 3, context.temp_allocator)
	if strings.has_suffix(st.data_dir, "/palmy-mail") {
		append(&out, "env", tfmt("XDG_DATA_HOME=%s", st.data_dir[:len(st.data_dir) - len("/palmy-mail")]))
	}
	append(&out, mailcore_path())
	append(&out, ..args)
	return out[:]
}

// reload_accounts re-reads the configuration after a sign-in or a sync.
reload_accounts :: proc(st: ^State) {
	clear(&st.accounts)
	load_config(st)
	discover_accounts(st)
	st.id_view = 0
	st.unified = false
	reload_all(st)
}

palm_sync :: proc(st: ^State) -> bool {
	if mailcore_path() == "" {
		st.signin.error = strings.clone("mailcore was not found (set PALMY_MAILCORE)")
		return false
	}
	out, ok := kit.run(mailcore_argv(st, "palm", "sync"), context.temp_allocator)
	if !ok {
		st.signin.error = strings.clone("sync failed: is palm-maild running? (cloud/mail/dev)")
		return false
	}
	_ = out
	reload_accounts(st)
	// Open on the first identity, which is the per-identity view.
	if first := palm_nth(st, 0); first >= 0 {
		set_identity_view(st, first)
	}
	note(st, tfmt("Synced %d identit%s from Palmy", palm_identities(st), palm_identities(st) == 1 ? "y" : "ies"))
	return true
}

palm_signin :: proc(st: ^State) {
	si := &st.signin
	delete(si.error)
	si.error = ""
	email := strings.trim_space(le_text(&si.email))
	password := le_text(&si.password)
	if email == "" || password == "" {
		si.error = strings.clone("Enter the account's email and password.")
		return
	}
	if mailcore_path() == "" {
		si.error = strings.clone("mailcore was not found (set PALMY_MAILCORE)")
		return
	}
	// The password reaches mailcore through a 0600 file that is removed as
	// soon as it has been read, never through argv, which any process on the
	// machine can list.
	dir := tfmt("%s/.palmy", st.data_dir)
	os.make_directory_all(dir)
	pw := tfmt("%s/.pw-%d", dir, os.get_pid())
	f, err := os.open(pw, {.Write, .Create, .Trunc}, {.Read_User, .Write_User})
	if err != nil {
		si.error = strings.clone("could not hand the password to mailcore")
		return
	}
	os.write_string(f, password)
	os.close(f)
	_, ok := kit.run(mailcore_argv(st, "palm", "login", "--email", email, "--password-file", pw), context.temp_allocator)
	os.remove(pw)
	le_clear(&si.password)
	if !ok {
		si.error = strings.clone("Sign-in refused. Check the email and password.")
		return
	}
	if palm_sync(st) {
		si.open = false
	}
}

// ---------------------------------------------------------------------------
// Keys
// ---------------------------------------------------------------------------

Signin :: struct {
	open:     bool,
	field:    int, // 0 email, 1 password, 2 the button
	email:    Line_Edit,
	password: Line_Edit,
	error:    string,
	swallow:  bool,
}

// palm_keys handles the identity keys from the list and the sidebar. Returns
// true when it consumed the frame's keys.
palm_keys :: proc(ui: ^p.Ctx, st: ^State) -> bool {
	if plain(ui, 'p') {
		st.signin.open = true
		st.signin.field = palm_identities(st) > 0 ? 2 : 0
		st.signin.swallow = true
		return true
	}
	if palm_identities(st) == 0 {
		return false
	}
	if shifted(ui, 'i') {
		set_unified(st, !st.unified_on)
		return true
	}
	if plain(ui, '0') {
		set_identity_view(st, -1)
		return true
	}
	for d in 1 ..= 9 {
		if plain(ui, u32('0' + d)) {
			if ai := palm_nth(st, d - 1); ai >= 0 {
				set_identity_view(st, ai)
			}
			return true
		}
	}
	return false
}

signin_keys :: proc(ui: ^p.Ctx, st: ^State) {
	si := &st.signin
	signed_in := palm_identities(st) > 0
	if plain(ui, p.KEY_ESCAPE) {
		si.open = false
		return
	}
	if signed_in {
		// Signed in: the sheet is the account card. S syncs, O signs out.
		if plain(ui, 's') || plain(ui, p.KEY_RETURN) {
			if palm_sync(st) {
				si.open = false
			}
		}
		if plain(ui, 'o') {
			kit.run(mailcore_argv(st, "palm", "logout"), context.temp_allocator)
			os.remove(palm_conf_path(st.data_dir, context.temp_allocator))
			reload_accounts(st)
			note(st, "Signed out. The synced mail stays on this machine.")
			si.open = false
		}
		return
	}
	if plain(ui, p.KEY_TAB) || plain(ui, p.KEY_DOWN) {
		si.field = (si.field + 1) % 3
		return
	}
	if plain(ui, p.KEY_UP) {
		si.field = (si.field + 2) % 3
		return
	}
	if plain(ui, p.KEY_RETURN) {
		if si.field < 2 {
			si.field += 1
		} else {
			palm_signin(st)
		}
		return
	}
	if si.field == 2 {
		return
	}
	e := si.field == 0 ? &si.email : &si.password
	typed := si.swallow ? "" : p.typed_text(ui)
	si.swallow = false
	for b in transmute([]u8)typed {
		if b >= 0x20 {
			le_insert(e, string([]u8{b}))
		}
	}
	if plain(ui, p.KEY_BACKSPACE) {
		le_backspace(e)
	}
	if key_times(ui, p.KEY_LEFT) > 0 {
		le_left(e)
	}
	if key_times(ui, p.KEY_RIGHT) > 0 {
		le_right(e)
	}
}

// ---------------------------------------------------------------------------
// Drawing
// ---------------------------------------------------------------------------

kind_label :: proc(k: string) -> string {
	switch k {
	case "personal":
		return "PERSONAL"
	case "work":
		return "WORK"
	case "public":
		return "PUBLIC"
	case "project":
		return "PROJECT"
	}
	return "IDENTITY"
}

// identity_chip: a coloured dot and the handle — the label a conversation
// carries in the unified view, and the one the reader shows.
identity_chip :: proc(ui: ^p.Ctx, a: Account, hl: bool) {
	c := palm_color(a.color)
	p.div(ui, hl ? "flex-row h-[15] shrink-0 items-center gap-1 px-1.5 rounded-full bg-white/20" : tfmt("flex-row h-[15] shrink-0 items-center gap-1 px-1.5 rounded-full bg-%s-100", c))
	p.div(ui, tfmt("size-1.5 shrink-0 rounded-full %s", hl ? "bg-white" : tfmt("bg-%s-500", c)))
	p.end(ui)
	p.text(ui, a.handle != "" ? a.handle : a.address, hl ? "text-[9.5] font-semibold text-white whitespace-nowrap" : tfmt("text-[9.5] font-semibold text-%s-700 whitespace-nowrap", c))
	p.style(ui).shrink = 0
	p.end(ui)
}

// identity_strip is the switcher at the top of the sidebar: every identity of
// the signed-in account, and "All".
identity_strip :: proc(ui: ^p.Ctx, st: ^State) {
	if palm_identities(st) == 0 {
		return
	}
	p.col(ui, "w-full shrink-0 px-2 pt-2 pb-1.5 gap-1 border-b border-border")
	defer p.end(ui)
	p.row(ui, "items-center gap-1.5 px-1 pb-0.5")
	p.icon(ui, ICON_USERS, "size-3 shrink-0 text-muted-foreground")
	p.text(ui, st.palm_email != "" ? st.palm_email : "Palmy", "flex-1 min-w-0 truncate text-[10.5] font-medium text-muted-foreground")
	sc.kbd(ui, "P")
	p.end(ui)

	n := 0
	for a, ai in st.accounts {
		if !a.palm {
			continue
		}
		n += 1
		on := st.id_view - 1 == ai
		c := palm_color(a.color)
		p.key(ui, tfmt("ident:%d", ai))
		idx := p.row(ui, "h-[30] shrink-0 items-center gap-2 px-2 rounded-md transition cursor-pointer")
		p.apply(ui, on ? tfmt("bg-%s-100 ring-1 ring-%s-300", c, c) : "hover:bg-accent/70", idx)
		if p.clickable(ui, idx) {
			set_identity_view(st, ai)
		}
		p.div(ui, tfmt("flex-row size-5 shrink-0 items-center justify-center rounded-full bg-%s-500", c))
		p.text(ui, strings.to_upper(a.handle[:min(1, len(a.handle))], context.temp_allocator), "text-[10] font-bold text-white")
		p.style(ui).shrink = 0
		p.end(ui)
		p.col(ui, "flex-1 min-w-0 gap-0")
		p.text(ui, a.address, on ? tfmt("truncate text-[11.5] font-semibold text-%s-900", c) : "truncate text-[11.5] font-medium text-foreground")
		p.end(ui)
		p.text(ui, kind_label(a.kind), on ? tfmt("text-[8.5] font-bold text-%s-700", c) : "text-[8.5] font-semibold text-muted-foreground")
		p.style(ui).shrink = 0
		if n <= 9 {
			sc.kbd(ui, tfmt("%d", n))
		}
		p.end(ui)
	}
	all_on := st.id_view == 0
	idx := p.row(ui, "h-[26] shrink-0 items-center gap-2 px-2 rounded-md transition cursor-pointer")
	p.apply(ui, all_on ? "bg-accent" : "hover:bg-accent/70", idx)
	if p.clickable(ui, idx) {
		set_identity_view(st, -1)
	}
	p.icon(ui, ICON_MAILS, "size-3.5 shrink-0 text-muted-foreground")
	p.text(ui, "All identities", all_on ? "flex-1 min-w-0 text-[11.5] font-semibold text-foreground" : "flex-1 min-w-0 text-[11.5] text-foreground")
	sc.kbd(ui, "0")
	p.end(ui)
}

// unified_row is the sidebar entry of the prototype view.
unified_row :: proc(ui: ^p.Ctx, st: ^State, cursor: bool, srow: int) {
	on := st.unified && !st.searching
	unread := 0
	for f in st.folders {
		if f.role == .Inbox && f.depth == 0 && st.accounts[f.account].palm {
			unread += f.unread
		}
	}
	p.key(ui, "unified")
	idx := p.row(ui, "h-[30] shrink-0 items-center gap-2 px-2 mt-1 rounded-md transition cursor-pointer border border-dashed border-violet-300")
	switch {
	case on:
		p.apply(ui, "bg-violet-600", idx)
	case cursor:
		p.apply(ui, "bg-accent ring-2 ring-selection/40", idx)
	case:
		p.apply(ui, "hover:bg-accent/70", idx)
	}
	if p.clickable(ui, idx) {
		st.unified = true
		st.side_sel = srow
		st.row_sel = 0
		rebuild_list(st)
	}
	if cursor {
		st.side_row_id = p.node_id(ui, idx)
	}
	defer p.end(ui)
	p.icon(ui, ICON_INBOX, on ? "size-3.5 shrink-0 text-white" : "size-3.5 shrink-0 text-violet-600")
	p.text(ui, "All inboxes", on ? "flex-1 min-w-0 text-[12.5] font-semibold text-white" : "flex-1 min-w-0 text-[12.5] font-semibold text-foreground")
	p.text(ui, "PROTOTYPE", on ? "text-[8.5] font-bold text-white/80" : "text-[8.5] font-bold text-violet-600")
	p.style(ui).shrink = 0
	if unread > 0 {
		p.div(ui, on ? "flex-row h-4 min-w-4 shrink-0 items-center justify-center rounded-full bg-white/25 px-1" : "flex-row h-4 min-w-4 shrink-0 items-center justify-center rounded-full bg-violet-600 px-1")
		p.text(ui, tfmt("%d", unread), "text-[10] font-semibold text-white")
		p.style(ui).shrink = 0
		p.end(ui)
	}
}

// palm_account_header replaces the protocol badge with the identity's kind
// and colour for a Palmy identity.
palm_account_header :: proc(ui: ^p.Ctx, st: ^State, ai: int, cursor: bool, srow: int) {
	a := st.accounts[ai]
	c := palm_color(a.color)
	p.key(ui, tfmt("acct:%d", ai))
	idx := p.row(ui, "h-[38] shrink-0 items-center gap-2 px-2 mt-1.5 rounded-md transition cursor-pointer")
	p.apply(ui, cursor ? "bg-accent ring-2 ring-selection/40" : "hover:bg-accent/60", idx)
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
	p.icon(ui, a.collapsed ? ICON_CHEVRON_RIGHT : ICON_CHEVRON_DOWN, "size-3 shrink-0 text-muted-foreground")
	p.div(ui, tfmt("w-[3] h-[26] shrink-0 rounded-full bg-%s-500", c))
	p.end(ui)
	p.col(ui, "flex-1 min-w-0 gap-0")
	p.row(ui, "items-center gap-1.5 min-w-0")
	p.text(ui, a.name, "truncate text-[12.5] font-semibold text-foreground")
	p.div(ui, tfmt("flex-row h-4 shrink-0 items-center px-1 rounded-sm bg-%s-100", c))
	p.text(ui, kind_label(a.kind), tfmt("text-[9] font-bold text-%s-700", c))
	p.style(ui).shrink = 0
	p.end(ui)
	p.end(ui)
	p.text(ui, a.address, "truncate text-[10.5] text-muted-foreground")
	p.end(ui)
}

// outbox_banner says what a Palmy Outbox is: not a queue.
outbox_banner :: proc(ui: ^p.Ctx, st: ^State) {
	p.row(ui, "shrink-0 w-full items-start gap-2 px-3 py-2 bg-amber-50 border-b border-amber-200")
	defer p.end(ui)
	p.icon(ui, ICON_TRIANGLE_ALERT, "size-3.5 shrink-0 text-amber-600 mt-0.5")
	p.col(ui, "flex-1 min-w-0 gap-0.5")
	p.text(ui, "Not sent: outbound delivery is not enabled", "text-[12] font-semibold text-amber-900")
	p.text(
		ui,
		"Mail to identities on this server is delivered. Mail to any other domain waits here and is not transmitted — sending to the internet is planned (through Resend), not built.",
		"w-full text-[11] text-amber-800 leading-[15]",
	)
	p.end(ui)
}

// signin_sheet is the sign-in form, or, when signed in, the account card.
signin_sheet :: proc(ui: ^p.Ctx, st: ^State) {
	si := &st.signin
	scrim := p.div(ui, "absolute inset-0 z-50 bg-black/40")
	if p.clickable(ui, scrim) {
		si.open = false
	}
	p.end(ui)
	p.row(ui, "absolute z-50 left-[24] right-[24] top-[96] justify-center")
	defer p.end(ui)
	p.col(ui, "w-full max-w-[420] rounded-xl bg-popover border border-border shadow-2xl p-5 gap-3 overflow-hidden")
	defer p.end(ui)

	p.row(ui, "items-center gap-2 shrink-0")
	p.div(ui, "flex-row size-7 shrink-0 items-center justify-center rounded-lg bg-indigo-600")
	p.icon(ui, ICON_USERS, "size-4 text-white")
	p.end(ui)
	p.col(ui, "flex-1 min-w-0 gap-0")
	p.text(ui, palm_identities(st) > 0 ? "Palmy account" : "Sign in to Palmy", "text-[14] font-semibold text-foreground")
	p.text(ui, "One account, several identities, each its own mailbox.", "text-[11] text-muted-foreground")
	p.end(ui)
	p.end(ui)

	if palm_identities(st) > 0 {
		p.text(ui, st.palm_email, "text-[12] font-medium text-foreground")
		for a in st.accounts {
			if !a.palm {
				continue
			}
			c := palm_color(a.color)
			p.row(ui, "items-center gap-2 h-7 px-2 rounded-md bg-muted/50")
			p.div(ui, tfmt("size-2 shrink-0 rounded-full bg-%s-500", c))
			p.end(ui)
			p.text(ui, a.address, "flex-1 min-w-0 truncate text-[12] text-foreground")
			p.text(ui, kind_label(a.kind), tfmt("text-[9] font-bold text-%s-700", c))
			p.style(ui).shrink = 0
			p.end(ui)
		}
		if si.error != "" {
			p.text(ui, si.error, "w-full text-[11.5] text-destructive")
		}
		p.row(ui, "items-center gap-2 shrink-0 pt-1")
		hint(ui, "S", "sync now")
		hint(ui, "O", "sign out")
		hint(ui, "Esc", "close")
		p.end(ui)
		return
	}

	field :: proc(ui: ^p.Ctx, label: string, text: string, cur: int, focus: bool) {
		p.col(ui, "w-full gap-1 shrink-0")
		p.text(ui, label, "text-[11] font-medium text-muted-foreground")
		p.row(ui, focus ? "h-8 w-full items-center px-2.5 rounded-md border border-selection ring-2 ring-selection/30 bg-background" : "h-8 w-full items-center px-2.5 rounded-md border border-input bg-background")
		caret_text(ui, text, cur, focus, 12.5, "text-[12.5] text-foreground")
		p.end(ui)
		p.end(ui)
	}
	field(ui, "Email", le_text(&si.email), si.email.cur, si.field == 0)
	dots := strings.repeat("•", len(le_text(&si.password)), context.temp_allocator)
	field(ui, "Password", dots, len(dots), si.field == 1)

	btn := p.row(ui, "h-8 w-full shrink-0 items-center justify-center rounded-md cursor-pointer transition")
	p.apply(ui, si.field == 2 ? "bg-indigo-600 ring-2 ring-indigo-300" : "bg-indigo-500 hover:bg-indigo-600", btn)
	if p.clickable(ui, btn) {
		palm_signin(st)
	}
	p.text(ui, "Sign in", "text-[12.5] font-semibold text-white")
	p.end(ui)

	if si.error != "" {
		p.text(ui, si.error, "w-full text-[11.5] text-destructive")
	}
	p.text(ui, "The password goes to the account's own sign-in service on this machine, through mailcore. It is not stored.", "w-full text-[10.5] text-muted-foreground leading-[14]")
	p.row(ui, "items-center gap-2 shrink-0")
	hint(ui, "Tab", "next field")
	hint(ui, "Enter", "sign in")
	hint(ui, "Esc", "close")
	p.end(ui)
}
