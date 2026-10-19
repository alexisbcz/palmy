package main

// The window. Two states: signed out, a split screen that says what the
// account is for and asks for it; signed in, a sidebar with the identity
// switcher and four pages — Identities, Devices & sessions, This session and
// Security.
//
// Every row that does something is focusable and activates on Enter or Space
// as well as a click, so the whole window works from the keyboard:
// Ctrl+1..4 for the pages, Ctrl+N for a new identity, Up/Down and Enter in
// the switcher, Escape to close whatever is open.

import "core:fmt"
import "core:os"
import "core:strings"
import ck "../cloudkit"
import kit "kit:."
import p "palmy:."
import sc "shadcn:."

SIDEBAR_W :: 264

register_colors :: proc() {
	// shadcn's light theme is registered by kit.start; nothing to add yet.
}

// ---------------------------------------------------------------------------
// Keys
// ---------------------------------------------------------------------------

keys :: proc(st: ^St, ui: ^p.Ctx) {
	if p.key_pressed(ui, p.KEY_ESCAPE) {
		switch {
		case st.confirm != .None:
			st.confirm = .None
		case st.rename_id != "":
			st.rename_id = ""
		case st.new_open:
			st.new_open = false
		case st.del_open:
			st.del_open = false
		}
	}
	if !st.signed_in {
		return
	}
	if st.confirm != .None {
		if p.key_pressed(ui, p.KEY_RETURN) {
			run_confirm(st)
		}
		return
	}
	for v, i in View {
		if p.shortcut(ui, u32('1' + i), {.Ctrl}) {
			st.view = v
		}
	}
	if p.shortcut(ui, 'n', {.Ctrl}) && !is_scoped(st) {
		open_new_identity(st)
	}
	// The switcher: Alt+Up/Down walk the identities, Alt+Enter switches.
	live := live_ids(st)
	if len(live) > 0 {
		if p.shortcut(ui, p.KEY_DOWN, {.Alt}, true) {
			st.sel = (st.sel + 1) % len(live)
		}
		if p.shortcut(ui, p.KEY_UP, {.Alt}, true) {
			st.sel = (st.sel + len(live) - 1) % len(live)
		}
		if p.shortcut(ui, p.KEY_RETURN, {.Alt}) {
			do_switch(st, live[clamp(st.sel, 0, len(live) - 1)].handle)
		}
	}
}

live_ids :: proc(st: ^St) -> []ck.Identity {
	out := make([dynamic]ck.Identity, context.temp_allocator)
	for x in st.ids {
		if !x.archived {
			append(&out, x)
		}
	}
	return out[:]
}

// ---------------------------------------------------------------------------
// Building blocks
// ---------------------------------------------------------------------------

// btn is a shadcn button that joins the Tab order and reports activation.
btn :: proc(ui: ^p.Ctx, label: string, v := sc.Variant.Default, s := sc.Size.Default, icon: Maybe(p.Icon) = nil, disabled := false) -> bool {
	idx := sc.button_open(ui, v, s, {disabled = disabled})
	if !disabled {
		p.focusable(ui, idx)
		if p.focused(ui, idx) {
			p.apply(ui, "border-ring ring-3 ring-ring/50", idx)
		}
		if p.is_hovered(ui, idx) {
			p.apply(ui, sc.button_variant_class(v, {hover = true}), idx)
		}
	}
	if ic, ok := icon.?; ok {
		p.icon(ui, ic, "size-4 shrink-0")
	}
	if label != "" {
		p.text(ui, label, "whitespace-nowrap")
		p.style(ui).shrink = 0
	}
	sc.button_end(ui)
	return !disabled && p.activated(ui, idx)
}

// field is a labelled text input that can be given focus by key.
field :: proc(st: ^St, ui: ^p.Ctx, key: string, buf: ^[dynamic]u8, placeholder: string, mask: rune = 0) -> (changed, submitted: bool) {
	p.key(ui, key)
	idx := p.node_count(ui)
	changed, submitted = sc.input_buf(ui, buf, placeholder, {}, mask)
	if st.want_focus == key {
		p.set_focus(ui, p.node_id(ui, idx))
		st.want_focus = ""
	}
	return
}

label :: proc(ui: ^p.Ctx, s: string) {
	p.text(ui, s, "text-xs font-medium text-muted-foreground")
}

color_dot :: proc(ui: ^p.Ctx, color: string, size := "size-2.5") {
	p.div(ui, fmt.tprintf("%s rounded-full shrink-0 bg-%s-500", size, color))
	p.end(ui)
}

identity_avatar :: proc(ui: ^p.Ctx, x: ck.Identity, size := "size-11", text := "text-sm") {
	p.div(ui, fmt.tprintf("%s rounded-xl shrink-0 items-center justify-center bg-%s-500", size, x.color))
	p.text(ui, initials(x.display_name), fmt.tprintf("%s font-semibold text-white", text))
	p.end(ui)
}

kind_icon :: proc(kind: string) -> p.Icon {
	switch kind {
	case "work":
		return AI_BRIEFCASE
	case "public":
		return AI_GLOBE
	case "project":
		return AI_FOLDER
	}
	return AI_HOUSE
}

page_header :: proc(ui: ^p.Ctx, title, blurb: string) {
	p.col(ui, "gap-1 flex-1 min-w-0")
	p.text(ui, title, "text-2xl font-semibold tracking-tight text-foreground")
	p.text(ui, blurb, "text-sm text-muted-foreground leading-relaxed")
	p.end(ui)
}

// ---------------------------------------------------------------------------
// Frame
// ---------------------------------------------------------------------------

frame :: proc(st: ^St, ui: ^p.Ctx) {
	if !st.signed_in {
		auth_screen(st, ui)
	} else {
		p.row(ui, "w-full h-full bg-background")
		sidebar(st, ui)
		p.col(ui, "flex-1 h-full min-w-0 overflow-y-auto")
		p.col(ui, "w-full px-10 py-8 gap-6")
		switch st.view {
		case .Identities:
			identities_page(st, ui)
		case .Devices:
			devices_page(st, ui)
		case .Session:
			session_page(st, ui)
		case .Security:
			security_page(st, ui)
		}
		p.end(ui)
		p.end(ui)
		p.end(ui)
		confirm_dialog(st, ui)
	}
	toast(st, ui)
}

toast :: proc(st: ^St, ui: ^p.Ctx) {
	if st.toast == "" || st.now - st.toast_at > 5 {
		return
	}
	p.row(ui, "absolute bottom-6 right-6 z-50 max-w-[420] items-center gap-3 px-4 py-3 rounded-xl border border-border bg-card shadow-lg")
	p.icon(ui, st.toast_bad ? AI_CIRCLE_ALERT : AI_CIRCLE_CHECK, st.toast_bad ? "size-4 shrink-0 text-destructive" : "size-4 shrink-0 text-emerald-600")
	p.text(ui, st.toast, "text-sm text-foreground")
	p.end(ui)
}

// ---------------------------------------------------------------------------
// Signed out
// ---------------------------------------------------------------------------

auth_screen :: proc(st: ^St, ui: ^p.Ctx) {
	p.row(ui, "w-full h-full")
	defer p.end(ui)

	// The left half says what this is.
	p.col(ui, "w-[500] h-full shrink-0 px-12 py-12 gap-8 bg-gradient-to-b from-[#1e1b4b] to-[#0b1020]")
	{
		p.row(ui, "items-center gap-3")
		p.div(ui, "size-9 rounded-xl items-center justify-center bg-white/10 border border-white/20")
		p.icon(ui, AI_CLOUD, "size-5 text-white")
		p.end(ui)
		p.col(ui, "gap-0")
		p.text(ui, "Palmframe", "text-base font-semibold text-white")
		p.text(ui, kit.tr("Account"), "text-xs text-indigo-200")
		p.end(ui)
		p.end(ui)

		p.spacer(ui)

		p.text(ui, kit.tr("One account. Every identity you are."), "text-3xl font-semibold tracking-tight text-white leading-tight")
		p.text(
			ui,
			kit.tr("Work, personal, the public face, the side project: each with its own mail, files and assistant scope. Switching is one step, and nothing crosses between them unless you say so."),
			"text-sm text-indigo-100/80 leading-relaxed",
		)

		// Three identities, drawn as the product shows them.
		p.col(ui, "gap-2 mt-2")
		demo := [?]struct {
			name, handle, color, kind: string,
		}{
			{"Alex Rivera", "alex", "indigo", "personal"},
			{"Alex at Northwind", "alex.northwind", "sky", "work"},
			{"Rivera Studio", "riverastudio", "amber", "public"},
		}
		for d, i in demo {
			p.row(ui, i == 1 ? "items-center gap-3 px-3 py-2.5 rounded-xl bg-white/10 border border-white/20" : "items-center gap-3 px-3 py-2.5 rounded-xl border border-white/10")
			p.div(ui, fmt.tprintf("size-8 rounded-lg items-center justify-center bg-%s-500", d.color))
			p.text(ui, initials(d.name), "text-xs font-semibold text-white")
			p.end(ui)
			p.col(ui, "flex-1 gap-0")
			p.text(ui, d.name, "text-sm font-medium text-white")
			p.text(ui, fmt.tprintf("%s@%s", d.handle, MAIL_DOMAIN), "text-xs text-indigo-200/80")
			p.end(ui)
			p.icon(ui, kind_icon(d.kind), "size-4 text-indigo-200/70")
			p.end(ui)
		}
		p.end(ui)

		p.spacer(ui)

		p.row(ui, "items-start gap-3")
		p.icon(ui, AI_SHIELD_CHECK, "size-4 shrink-0 text-emerald-300 mt-0.5")
		p.text(ui, kit.tr("Separation is enforced by the database, row by row, not by which window is open. An assistant given one identity cannot read another's mail."), "text-xs text-indigo-100/70 leading-relaxed")
		p.end(ui)
	}
	p.end(ui)

	// The right half asks.
	p.col(ui, "flex-1 h-full items-center justify-center px-12 bg-background")
	p.col(ui, "w-[380] gap-6")
	{
		creating := st.auth_mode == .Create
		p.col(ui, "gap-1.5")
		p.text(ui, creating ? kit.tr("Create your account") : kit.tr("Sign in"), "text-2xl font-semibold tracking-tight")
		p.text(ui, creating ? kit.tr("Your first identity is created with it. You can add the others later.") : kit.tr("Use the email and password of your Palmframe account."), "text-sm text-muted-foreground leading-relaxed")
		p.end(ui)

		// The two modes, as a segmented control.
		p.row(ui, "p-1 rounded-lg bg-muted gap-1")
		for m in Auth_Mode {
			on := st.auth_mode == m
			idx := p.div(ui, on ? "flex-1 h-8 rounded-md items-center justify-center bg-background shadow-sm" : "flex-1 h-8 rounded-md items-center justify-center hover:bg-background/60")
			p.focusable(ui, idx)
			p.text(ui, m == .Sign_In ? kit.tr("Sign in") : kit.tr("Create account"), on ? "text-sm font-medium text-foreground whitespace-nowrap" : "text-sm text-muted-foreground whitespace-nowrap")
			p.end(ui)
			if p.activated(ui, idx) {
				st.auth_mode = m
				st.want_focus = "email"
			}
		}
		p.end(ui)

		submitted := false
		p.col(ui, "gap-4")
		if creating {
			p.col(ui, "gap-1.5")
			label(ui, kit.tr("Your name, as this identity"))
			if changed, sub := field(st, ui, "name", &st.name_buf, kit.tr("Alex Rivera")); changed || sub {
				if !st.handle_touched {
					clear(&st.handle_buf)
					append(&st.handle_buf, ..transmute([]u8)handle_from(string(st.name_buf[:])))
				}
				submitted ||= sub
			}
			p.end(ui)
		}
		p.col(ui, "gap-1.5")
		label(ui, kit.tr("Email"))
		_, s1 := field(st, ui, "email", &st.email_buf, "you@example.org")
		p.end(ui)
		p.col(ui, "gap-1.5")
		label(ui, kit.tr("Password"))
		_, s2 := field(st, ui, "password", &st.pw_buf, creating ? kit.tr("At least 8 characters") : "", '•')
		p.end(ui)
		if creating {
			p.col(ui, "gap-1.5")
			label(ui, kit.tr("Handle"))
			p.row(ui, "items-center gap-2")
			p.col(ui, "flex-1 min-w-0")
			if changed, _ := field(st, ui, "handle", &st.handle_buf, "alex"); changed {
				st.handle_touched = true
			}
			p.end(ui)
			p.text(ui, "@" + MAIL_DOMAIN, "text-sm text-muted-foreground whitespace-nowrap")
			p.end(ui)
			p.text(ui, kit.tr("Also your mail address. It is permanent; the name above is not."), "text-xs text-muted-foreground")
			p.end(ui)
		}
		p.end(ui)
		submitted ||= s1 || s2

		go := btn(ui, creating ? kit.tr("Create account") : kit.tr("Sign in"), .Default, .LG, creating ? AI_USER_PLUS : AI_LOG_IN)
		p.apply(ui, "w-full", p.node_count(ui) - 1)
		if go || submitted {
			submit_auth(st)
		}

		p.row(ui, "items-center gap-2 justify-center")
		p.icon(ui, AI_SERVER, "size-3.5 text-muted-foreground")
		url := st.c != nil ? st.c.url_text : ck.DEFAULT_URL
		p.text(ui, url, "text-xs text-muted-foreground font-mono")
		p.end(ui)

		// New on this computer: the welcome app does the rest of the setup
		// (identities, what syncs, the vault) in one pass.
		if has_welcome() && !st.fixture {
			p.row(ui, "items-center gap-1 justify-center")
			p.text(ui, kit.tr("New here?"), "text-xs text-muted-foreground")
			if btn(ui, kit.tr("Set up this computer step by step"), .Link, .SM) {
				kit.launch({"welcome", "run"})
			}
			p.end(ui)
		}
	}
	p.end(ui)
	p.end(ui)
}

// has_welcome asks once whether the welcome app is installed: the answer
// does not change while the window is open, and asking runs a process.
@(private = "file")
g_has_welcome := -1

has_welcome :: proc() -> bool {
	if g_has_welcome < 0 {
		g_has_welcome = kit.has_tool("welcome") ? 1 : 0
	}
	return g_has_welcome == 1
}

submit_auth :: proc(st: ^St) {
	if st.fixture {
		return
	}
	email := string(st.email_buf[:])
	pw := string(st.pw_buf[:])
	if strings.trim_space(email) == "" || pw == "" {
		say(st, kit.tr("Enter an email address and a password."), bad = true)
		return
	}
	e: ck.Error
	if st.auth_mode == .Create {
		name := strings.trim_space(string(st.name_buf[:]))
		handle := strings.trim_space(string(st.handle_buf[:]))
		if name == "" || !ck.handle_ok(handle) {
			say(st, kit.tr("Choose a name and a handle: lower-case letters, digits, dots."), bad = true)
			return
		}
		e = act_create_account(st, email, pw, name, handle)
	} else {
		e = act_sign_in(st, email, pw)
	}
	if !ck.ok(e) {
		say(st, err_text(e), bad = true)
		return
	}
	clear(&st.pw_buf)
	say(st, kit.trf("Signed in as %s", st.email))
}

// ---------------------------------------------------------------------------
// Sidebar
// ---------------------------------------------------------------------------

sidebar :: proc(st: ^St, ui: ^p.Ctx) {
	p.col(ui, fmt.tprintf("w-[%d] h-full shrink-0 border-r border-border bg-muted/40 px-3 py-4 gap-5", SIDEBAR_W))
	defer p.end(ui)

	// The account.
	p.row(ui, "items-center gap-3 px-2")
	p.div(ui, "size-9 rounded-full items-center justify-center bg-foreground")
	p.text(ui, initials(st.email), "text-sm font-semibold text-background")
	p.end(ui)
	p.col(ui, "flex-1 min-w-0 gap-0")
	p.text(ui, st.email, "text-sm font-medium text-foreground truncate")
	if st.scope.id != "" {
		p.row(ui, "items-center gap-1")
		p.icon(ui, AI_LOCK, "size-3 text-amber-600")
		p.text(ui, kit.trf("Scoped to %s", st.scope.handle), "text-xs text-amber-700 truncate")
		p.end(ui)
	} else {
		p.text(ui, kit.tr("Palmframe account"), "text-xs text-muted-foreground")
	}
	p.end(ui)
	p.end(ui)

	// The switcher.
	p.col(ui, "gap-1")
	p.row(ui, "items-center px-2 pb-1")
	p.text(ui, kit.tr("Identities"), "text-xs font-medium text-muted-foreground uppercase tracking-wide flex-1")
	if !is_scoped(st) {
		idx := p.div(ui, "size-6 rounded-md items-center justify-center hover:bg-accent")
		p.focusable(ui, idx)
		p.icon(ui, AI_PLUS, "size-3.5 text-muted-foreground")
		p.end(ui)
		if p.activated(ui, idx) {
			st.view = .Identities
			open_new_identity(st)
		}
	}
	p.end(ui)
	live := live_ids(st)
	for x, i in live {
		cur := x.handle == st.current
		cls := cur ? "items-center gap-2.5 px-2 py-1.5 rounded-lg bg-background border border-border shadow-sm" : "items-center gap-2.5 px-2 py-1.5 rounded-lg border border-transparent hover:bg-accent"
		idx := p.row(ui, cls)
		p.focusable(ui, idx)
		if i == st.sel && p.focused(ui, idx) {
			p.apply(ui, "ring-2 ring-ring/40", idx)
		}
		p.div(ui, fmt.tprintf("size-6 rounded-md items-center justify-center bg-%s-500 shrink-0", x.color))
		p.text(ui, initials(x.display_name), "text-[10] font-semibold text-white")
		p.end(ui)
		p.col(ui, "flex-1 min-w-0 gap-0")
		p.text(ui, x.display_name, cur ? "text-sm font-medium text-foreground truncate" : "text-sm text-foreground truncate")
		p.text(ui, x.handle, "text-[11] text-muted-foreground truncate")
		p.end(ui)
		if cur {
			p.icon(ui, AI_CHECK, "size-4 text-foreground shrink-0")
		}
		p.end(ui)
		if p.activated(ui, idx) {
			st.sel = i
			do_switch(st, x.handle)
		}
	}
	if len(live) == 0 {
		p.text(ui, kit.tr("No identities yet."), "text-xs text-muted-foreground px-2")
	}
	p.end(ui)

	sc.separator(ui)

	// The pages.
	p.col(ui, "gap-0.5")
	pages := [View]struct {
		icon:  p.Icon,
		label: string,
	} {
		.Identities = {AI_USERS, kit.tr("Identities")},
		.Devices    = {AI_LAPTOP, kit.tr("Devices & sessions")},
		.Session    = {AI_KEY_ROUND, kit.tr("This session")},
		.Security   = {AI_SHIELD_CHECK, kit.tr("Security")},
	}
	for pg, v in pages {
		on := st.view == v
		idx := p.row(ui, on ? "items-center gap-2.5 px-2 h-8 rounded-lg bg-accent" : "items-center gap-2.5 px-2 h-8 rounded-lg hover:bg-accent/60")
		p.focusable(ui, idx)
		p.icon(ui, pg.icon, on ? "size-4 text-foreground" : "size-4 text-muted-foreground")
		p.text(ui, pg.label, on ? "text-sm font-medium text-foreground flex-1" : "text-sm text-foreground flex-1")
		if v == .Devices {
			n := 0
			for s in st.sess {
				if s.identity_id != "" {
					n += 1
				}
			}
			if n > 0 {
				p.textf(ui, "text-xs text-muted-foreground", "%d", n)
			}
		}
		p.end(ui)
		if p.activated(ui, idx) {
			st.view = v
		}
	}
	p.end(ui)

	p.spacer(ui)

	p.row(ui, "items-center gap-2 px-2")
	p.icon(ui, AI_SERVER, "size-3.5 text-muted-foreground")
	p.text(ui, st.c != nil ? st.c.url_text : ck.DEFAULT_URL, "text-[11] text-muted-foreground font-mono truncate")
	p.end(ui)
	if btn(ui, kit.tr("Sign out"), .Ghost, .Default, AI_LOG_OUT) {
		st.confirm = .Sign_Out
		st.confirm_label = st.email
	}
}

// is_scoped: this window's session acts for one identity. A fixture says so
// by carrying a scope; a live window asks the session it holds.
// short_home writes $HOME as ~.
short_home :: proc(path: string) -> string {
	home := os.get_env("HOME", context.temp_allocator)
	if home != "" && strings.has_prefix(path, home) {
		return fmt.tprintf("~%s", path[len(home):])
	}
	return path
}

// ua_machine reads the machine out of a user agent: cloudkit sends
// "palm-<app>/<version> (<hostname>)", and GoTrue records it per session.
ua_machine :: proc(ua: string) -> string {
	open := strings.index_byte(ua, '(')
	close := strings.last_index_byte(ua, ')')
	if open >= 0 && close > open + 1 {
		return ua[open + 1:close]
	}
	return ua != "" ? ua : kit.tr("Unknown client")
}

is_scoped :: proc(st: ^St) -> bool {
	if st.fixture || st.c == nil {
		return st.scope.id != ""
	}
	return ck.scoped(st.c)
}

do_switch :: proc(st: ^St, handle: string) {
	if st.fixture {
		st.current = handle
		return
	}
	if e := act_switch(st, handle); !ck.ok(e) {
		say(st, err_text(e), bad = true)
		return
	}
	x, _ := ck.find_identity(st.ids, handle)
	say(st, kit.trf("Switched to %s. Apps opened now act as %s@%s.", x.display_name, x.handle, MAIL_DOMAIN))
}

open_new_identity :: proc(st: ^St) {
	st.new_open = true
	clear(&st.new_name)
	clear(&st.new_handle)
	st.new_handle_touched = false
	st.new_kind = 1
	st.new_color = 1
	st.want_focus = "new-name"
}

// ---------------------------------------------------------------------------
// Identities
// ---------------------------------------------------------------------------

identities_page :: proc(st: ^St, ui: ^p.Ctx) {
	scoped := is_scoped(st)
	p.row(ui, "items-start gap-4")
	page_header(ui, kit.tr("Identities"), kit.tr("Each identity has its own mail address, files and assistant scope. Nothing moves between them unless you move it."))
	if !scoped && !st.new_open {
		if btn(ui, kit.tr("New identity"), .Default, .Default, AI_PLUS) {
			open_new_identity(st)
		}
	}
	p.end(ui)

	if scoped {
		notice(ui, AI_LOCK, kit.tr("This session acts for one identity, so it sees only that one and cannot create, rename or archive. Open Accounts outside the scope to manage the account."))
	}
	if st.new_open {
		new_identity_card(st, ui)
	}

	p.row(ui, "flex-wrap gap-4")
	for x in st.ids {
		if !x.archived {
			identity_card(st, ui, x, scoped)
		}
	}
	p.end(ui)

	archived := 0
	for x in st.ids {
		if x.archived {
			archived += 1
		}
	}
	if archived > 0 {
		p.col(ui, "gap-2 mt-2")
		p.text(ui, kit.tr("Archived"), "text-xs font-medium text-muted-foreground uppercase tracking-wide")
		for x in st.ids {
			if !x.archived {
				continue
			}
			p.row(ui, "items-center gap-3 px-4 py-3 rounded-xl border border-dashed border-border")
			p.div(ui, "opacity-50")
			identity_avatar(ui, x, "size-8", "text-xs")
			p.end(ui)
			p.col(ui, "flex-1 gap-0")
			p.text(ui, x.display_name, "text-sm text-muted-foreground")
			p.text(ui, kit.tr("Archived. Its data is kept and unreachable until it is restored."), "text-xs text-muted-foreground")
			p.end(ui)
			if !scoped && btn(ui, kit.tr("Restore"), .Outline, .SM, AI_ARCHIVE_RESTORE) {
				if !st.fixture {
					_, e := ck.restore_identity(st.c, x.id, context.temp_allocator)
					reload(st)
					if !ck.ok(e) {
						say(st, err_text(e), bad = true)
					} else {
						say(st, kit.trf("%s is back.", x.display_name))
					}
				}
			}
			p.end(ui)
		}
		p.end(ui)
	}
}

notice :: proc(ui: ^p.Ctx, icon: p.Icon, text: string) {
	p.row(ui, "items-start gap-3 px-4 py-3 rounded-xl border border-amber-200 bg-amber-50")
	p.icon(ui, icon, "size-4 shrink-0 text-amber-700 mt-0.5")
	p.text(ui, text, "text-sm text-amber-900 leading-relaxed")
	p.end(ui)
}

CARD_W :: 372

identity_card :: proc(st: ^St, ui: ^p.Ctx, x: ck.Identity, scoped: bool) {
	cur := x.handle == st.current
	p.col(ui, fmt.tprintf("w-[%d] rounded-2xl border bg-card shadow-sm overflow-hidden", CARD_W))
	p.apply(ui, cur ? "border-foreground/30" : "border-border")
	defer p.end(ui)


	p.col(ui, "p-5 gap-4")
	defer p.end(ui)

	p.row(ui, "items-center gap-3.5")
	identity_avatar(ui, x)
	p.col(ui, "flex-1 min-w-0 gap-0.5")
	if st.rename_id == x.id {
		_, sub := field(st, ui, "rename", &st.rename_buf, x.display_name)
		if sub {
			commit_rename(st, x)
		}
	} else {
		p.text(ui, x.display_name, "text-base font-semibold text-foreground truncate")
	}
	p.row(ui, "items-center gap-1")
	p.icon(ui, AI_AT_SIGN, "size-3 text-muted-foreground")
	p.text(ui, fmt.tprintf("%s@%s", x.handle, MAIL_DOMAIN), "text-xs text-muted-foreground truncate")
	p.end(ui)
	p.end(ui)
	sc.badge_icon(ui, kind_label(x.kind), kind_icon(x.kind), .Secondary)
	p.end(ui)

	// Where it stands on this machine.
	p.row(ui, "items-center gap-2")
	if cur {
		p.div(ui, "size-2 rounded-full bg-emerald-500")
		p.end(ui)
		p.text(ui, kit.tr("Current identity"), "text-xs font-medium text-foreground whitespace-nowrap")
	} else {
		p.div(ui, "size-2 rounded-full bg-border")
		p.end(ui)
		p.text(ui, kit.tr("Not current"), "text-xs text-muted-foreground whitespace-nowrap")
	}
	p.text(ui, "·", "text-xs text-muted-foreground")
	if st.stored[x.handle] {
		p.icon(ui, AI_KEY_ROUND, "size-3 text-muted-foreground")
		p.text(ui, kit.tr("Session on this machine"), "text-xs text-muted-foreground whitespace-nowrap")
	} else {
		p.text(ui, kit.tr("No session on this machine"), "text-xs text-muted-foreground whitespace-nowrap")
	}
	p.end(ui)

	if scoped {
		return
	}
	sc.separator(ui)
	p.row(ui, "items-center gap-2")
	if st.rename_id == x.id {
		if btn(ui, kit.tr("Save"), .Default, .SM, AI_CHECK) {
			commit_rename(st, x)
		}
		if btn(ui, kit.tr("Cancel"), .Ghost, .SM) {
			st.rename_id = ""
		}
	} else {
		if !cur && btn(ui, kit.tr("Switch to"), .Default, .SM) {
			do_switch(st, x.handle)
		}
		if btn(ui, kit.tr("Rename"), .Outline, .SM, AI_PENCIL) {
			st.rename_id = x.id
			clear(&st.rename_buf)
			append(&st.rename_buf, ..transmute([]u8)x.display_name)
			st.want_focus = "rename"
		}
	}
	p.spacer(ui)
	// Colour: click the dot to step through the palette.
	cidx := p.div(ui, "size-7 rounded-md items-center justify-center hover:bg-accent")
	p.focusable(ui, cidx)
	color_dot(ui, x.color, "size-3.5")
	p.end(ui)
	if p.activated(ui, cidx) && !st.fixture {
		next := COLORS[0]
		for c, i in COLORS {
			if c == x.color {
				next = COLORS[(i + 1) % len(COLORS)]
			}
		}
		_, e := ck.set_identity_color(st.c, x.id, next, context.temp_allocator)
		reload(st)
		if !ck.ok(e) {
			say(st, err_text(e), bad = true)
		}
	}
	aidx := p.div(ui, "size-7 rounded-md items-center justify-center hover:bg-destructive/10")
	p.focusable(ui, aidx)
	p.icon(ui, AI_ARCHIVE, "size-4 text-muted-foreground")
	p.end(ui)
	if p.activated(ui, aidx) {
		st.confirm = .Archive
		st.confirm_id = x.id
		st.confirm_label = x.display_name
	}
	p.end(ui)
}

commit_rename :: proc(st: ^St, x: ck.Identity) {
	name := strings.trim_space(string(st.rename_buf[:]))
	st.rename_id = ""
	if name == "" || name == x.display_name || st.fixture {
		return
	}
	_, e := ck.rename_identity(st.c, x.id, name, context.temp_allocator)
	reload(st)
	if !ck.ok(e) {
		say(st, err_text(e), bad = true)
	} else {
		say(st, kit.trf("Renamed to %s.", name))
	}
}

new_identity_card :: proc(st: ^St, ui: ^p.Ctx) {
	p.col(ui, "w-full rounded-2xl border border-border bg-card shadow-sm p-6 gap-5")
	defer p.end(ui)

	p.row(ui, "items-center gap-3")
	preview := ck.Identity {
		display_name = len(st.new_name) > 0 ? string(st.new_name[:]) : kit.tr("New identity"),
		color        = COLORS[st.new_color],
	}
	identity_avatar(ui, preview)
	p.col(ui, "flex-1 gap-0.5")
	p.text(ui, kit.tr("New identity"), "text-base font-semibold")
	p.text(ui, kit.tr("It gets its own mail address and its own storage, and starts empty."), "text-sm text-muted-foreground")
	p.end(ui)
	p.end(ui)

	p.row(ui, "gap-4 items-start")
	p.col(ui, "flex-1 gap-1.5")
	label(ui, kit.tr("Name"))
	changed, sub1 := field(st, ui, "new-name", &st.new_name, kit.tr("Alex at Northwind"))
	if changed && !st.new_handle_touched {
		clear(&st.new_handle)
		append(&st.new_handle, ..transmute([]u8)handle_from(string(st.new_name[:])))
	}
	p.end(ui)
	p.col(ui, "flex-1 gap-1.5")
	label(ui, kit.tr("Handle and mail address"))
	p.row(ui, "items-center gap-2")
	p.col(ui, "flex-1 min-w-0")
	hchanged, sub2 := field(st, ui, "new-handle", &st.new_handle, "alex.northwind")
	if hchanged {
		st.new_handle_touched = true
	}
	p.end(ui)
	p.text(ui, "@" + MAIL_DOMAIN, "text-sm text-muted-foreground whitespace-nowrap")
	p.end(ui)
	p.end(ui)
	p.end(ui)

	p.row(ui, "gap-8 items-start")
	p.col(ui, "gap-1.5")
	label(ui, kit.tr("Kind"))
	p.row(ui, "p-1 rounded-lg bg-muted gap-1")
	for k, i in KINDS {
		on := st.new_kind == i
		idx := p.row(ui, on ? "h-7 px-2.5 gap-1.5 rounded-md items-center bg-background shadow-sm" : "h-7 px-2.5 gap-1.5 rounded-md items-center hover:bg-background/60")
		p.focusable(ui, idx)
		p.icon(ui, kind_icon(k), on ? "size-3.5 text-foreground" : "size-3.5 text-muted-foreground")
		p.text(ui, kind_label(k), on ? "text-xs font-medium text-foreground" : "text-xs text-muted-foreground")
		p.end(ui)
		if p.activated(ui, idx) {
			st.new_kind = i
		}
	}
	p.end(ui)
	p.end(ui)
	p.col(ui, "gap-1.5")
	label(ui, kit.tr("Colour"))
	p.row(ui, "gap-1.5 h-9 items-center")
	for c, i in COLORS {
		on := st.new_color == i
		idx := p.div(ui, on ? "size-7 rounded-full items-center justify-center ring-2 ring-foreground/70" : "size-7 rounded-full items-center justify-center hover:bg-accent")
		p.focusable(ui, idx)
		color_dot(ui, c, "size-5")
		p.end(ui)
		if p.activated(ui, idx) {
			st.new_color = i
		}
	}
	p.end(ui)
	p.end(ui)
	p.end(ui)

	p.row(ui, "items-center gap-2")
	p.icon(ui, AI_INFO, "size-3.5 text-muted-foreground")
	p.text(ui, kit.tr("The handle is permanent: it is the address people write to. The name and colour can change."), "text-xs text-muted-foreground flex-1")
	if btn(ui, kit.tr("Cancel"), .Ghost) {
		st.new_open = false
	}
	if btn(ui, kit.tr("Create identity"), .Default, .Default, AI_PLUS) || sub1 || sub2 {
		submit_new_identity(st)
	}
	p.end(ui)
}

submit_new_identity :: proc(st: ^St) {
	if st.fixture {
		return
	}
	name := strings.trim_space(string(st.new_name[:]))
	handle := strings.trim_space(string(st.new_handle[:]))
	if name == "" || !ck.handle_ok(handle) {
		say(st, kit.tr("Choose a name and a handle: lower-case letters, digits, dots."), bad = true)
		return
	}
	_, e := act_create_identity(st, handle, name, KINDS[st.new_kind], COLORS[st.new_color])
	if !ck.ok(e) {
		say(st, err_text(e), bad = true)
		return
	}
	st.new_open = false
	say(st, kit.trf("%s is ready: %s@%s", name, handle, MAIL_DOMAIN))
}

// ---------------------------------------------------------------------------
// Devices & sessions
// ---------------------------------------------------------------------------

devices_page :: proc(st: ^St, ui: ^p.Ctx) {
	scoped := is_scoped(st)
	p.row(ui, "items-start gap-4")
	page_header(ui, kit.tr("Devices & sessions"), kit.tr("Everything signed in to this account. A delegated session acts for one identity only, and revoking it stops it at once, not when its token runs out."))
	if !scoped && !st.del_open {
		if btn(ui, kit.tr("Delegate access"), .Default, .Default, AI_SPARKLES) {
			st.del_open = true
			clear(&st.del_name)
			append(&st.del_name, ..transmute([]u8)kit.tr("Assistant"))
			st.want_focus = "del-name"
			live := live_ids(st)
			for x, i in live {
				if x.handle == st.current {
					st.del_ident = i
				}
			}
		}
	}
	p.end(ui)

	if st.del_open {
		delegate_card(st, ui)
	}

	// Every session on the account.
	p.col(ui, "w-full rounded-2xl border border-border bg-card overflow-hidden")
	p.row(ui, "items-center h-10 px-5 gap-4 border-b border-border bg-muted/50")
	p.text(ui, kit.tr("Session"), "text-xs font-medium text-muted-foreground flex-1")
	p.text(ui, kit.tr("Acts for"), "text-xs font-medium text-muted-foreground w-[140]")
	p.text(ui, kit.tr("Signed in"), "text-xs font-medium text-muted-foreground w-[96]")
	p.text(ui, kit.tr("Last active"), "text-xs font-medium text-muted-foreground w-[96]")
	p.div(ui, "w-[112]")
	p.end(ui)
	p.end(ui)
	for s, i in st.sess {
		session_row(st, ui, s, i == len(st.sess) - 1, scoped)
	}
	if len(st.sess) == 0 {
		p.text(ui, kit.tr("No sessions."), "text-sm text-muted-foreground px-5 py-4")
	}
	p.end(ui)

	// Delegations that have ended, as history.
	ended := 0
	for d in st.devs {
		if !d.active {
			ended += 1
		}
	}
	if ended > 0 {
		p.col(ui, "gap-2")
		p.text(ui, kit.tr("Ended"), "text-xs font-medium text-muted-foreground uppercase tracking-wide")
		for d in st.devs {
			if d.active {
				continue
			}
			x, _ := identity_name(st, d.identity_id)
			p.row(ui, "items-center gap-3 px-4 py-2 rounded-lg border border-dashed border-border")
			p.icon(ui, d.kind == "assistant" ? AI_BOT : AI_SMARTPHONE, "size-4 text-muted-foreground")
			p.text(ui, d.name, "text-sm text-muted-foreground flex-1")
			color_dot(ui, x.color != "" ? x.color : "slate", "size-2")
			p.text(ui, x.handle, "text-xs text-muted-foreground")
			p.text(ui, kit.trf("since %s", short_time(d.created_at)), "text-xs text-muted-foreground")
			p.end(ui)
		}
		p.end(ui)
	}
}

session_row :: proc(st: ^St, ui: ^p.Ctx, s: ck.Account_Session, last: bool, scoped: bool) {
	p.row(ui, last ? "items-center min-h-[60] px-5 py-2 gap-4" : "items-center min-h-[60] px-5 py-2 gap-4 border-b border-border")
	defer p.end(ui)

	icon := AI_LAPTOP
	name := ua_machine(s.user_agent)
	if s.device_id != "" {
		icon = s.device_kind == "assistant" ? AI_BOT : AI_MONITOR
		name = s.device_name
	}
	p.row(ui, "flex-1 min-w-0 items-center gap-3")
	p.div(ui, "size-9 rounded-lg items-center justify-center bg-muted shrink-0")
	p.icon(ui, icon, "size-4 text-foreground")
	p.end(ui)
	p.col(ui, "flex-1 min-w-0 gap-0.5")
	p.row(ui, "items-center gap-2 min-w-0")
	p.text(ui, name, "text-sm font-medium text-foreground truncate shrink")
	if s.current {
		p.div(ui, "size-1.5 rounded-full bg-emerald-500 shrink-0")
		p.end(ui)
	}
	p.end(ui)
	sub := s.device_id != "" ? (s.device_kind == "assistant" ? kit.tr("Assistant, delegated") : kit.tr("Device, delegated")) : kit.tr("Password sign-in")
	if s.current {
		sub = kit.tr("This session")
	}
	if s.not_after != "" {
		sub = kit.trf("%s, until %s", sub, short_time(s.not_after))
	}
	p.text(ui, sub, "text-xs text-muted-foreground truncate")
	p.end(ui)
	p.end(ui)

	p.row(ui, "w-[140] items-center gap-2")
	if s.identity_id != "" {
		x, _ := identity_name(st, s.identity_id)
		p.row(ui, "items-center gap-1.5 h-6 px-2 rounded-md border border-border")
		color_dot(ui, x.color != "" ? x.color : "slate", "size-2")
		p.text(ui, x.handle != "" ? x.handle : kit.tr("one identity"), "text-xs font-medium text-foreground")
		p.end(ui)
	} else {
		p.row(ui, "items-center gap-1.5 h-6 px-2 rounded-md bg-foreground")
		p.icon(ui, AI_SHIELD_CHECK, "size-3 text-background")
		p.text(ui, kit.tr("Full account"), "text-xs font-medium text-background")
		p.end(ui)
	}
	p.end(ui)
	p.text(ui, short_time(s.created_at), "text-xs text-muted-foreground w-[96]")
	p.text(ui, short_time(s.refreshed_at), "text-xs text-muted-foreground w-[96]")

	p.row(ui, "w-[112] justify-end")
	if !scoped && !s.current {
		if s.device_id != "" {
			if btn(ui, kit.tr("Revoke"), .Destructive, .SM) {
				st.confirm = .Revoke
				st.confirm_id = s.device_id
				st.confirm_label = name
			}
		} else if btn(ui, kit.tr("Sign out"), .Outline, .SM) {
			st.confirm = .End_Session
			st.confirm_id = s.session_id
			st.confirm_label = name
		}
	}
	p.end(ui)
}

delegate_card :: proc(st: ^St, ui: ^p.Ctx) {
	live := live_ids(st)
	p.col(ui, "w-full rounded-2xl border border-border bg-card shadow-sm p-6 gap-5")
	defer p.end(ui)

	p.col(ui, "gap-1")
	p.text(ui, kit.tr("Delegate access to one identity"), "text-base font-semibold")
	p.text(ui, kit.tr("For an assistant or another machine. It can read and write that identity's data and nothing else: not the other identities, not the account's password, not other sessions."), "text-sm text-muted-foreground leading-relaxed")
	p.end(ui)

	p.col(ui, "gap-1.5")
	label(ui, kit.tr("Acts for"))
	p.row(ui, "flex-wrap gap-2")
	for x, i in live {
		on := st.del_ident == i
		idx := p.row(ui, on ? "items-center gap-2 h-9 px-3 rounded-lg border-2 border-foreground bg-background" : "items-center gap-2 h-9 px-3 rounded-lg border border-border hover:bg-accent")
		p.focusable(ui, idx)
		color_dot(ui, x.color)
		p.text(ui, x.display_name, "text-sm text-foreground whitespace-nowrap")
		p.text(ui, x.handle, "text-xs text-muted-foreground whitespace-nowrap")
		p.end(ui)
		if p.activated(ui, idx) {
			st.del_ident = i
		}
	}
	p.end(ui)
	p.end(ui)

	p.row(ui, "gap-6 items-start")
	p.col(ui, "gap-1.5")
	label(ui, kit.tr("For"))
	p.row(ui, "p-1 rounded-lg bg-muted gap-1")
	for k, i in ([?]string{kit.tr("An assistant"), kit.tr("A device")}) {
		on := st.del_kind == i
		idx := p.row(ui, on ? "h-7 px-3 gap-1.5 rounded-md items-center bg-background shadow-sm" : "h-7 px-3 gap-1.5 rounded-md items-center hover:bg-background/60")
		p.focusable(ui, idx)
		p.icon(ui, i == 0 ? AI_BOT : AI_SMARTPHONE, "size-3.5")
		p.text(ui, k, on ? "text-xs font-medium whitespace-nowrap" : "text-xs text-muted-foreground whitespace-nowrap")
		p.end(ui)
		if p.activated(ui, idx) {
			st.del_kind = i
		}
	}
	p.end(ui)
	p.end(ui)
	p.col(ui, "flex-1 gap-1.5")
	label(ui, kit.tr("Name it"))
	_, sub := field(st, ui, "del-name", &st.del_name, kit.tr("Mail assistant"))
	p.end(ui)
	p.col(ui, "gap-1.5")
	label(ui, kit.tr("Expires"))
	p.row(ui, "p-1 rounded-lg bg-muted gap-1")
	exp_labels := [?]string{kit.tr("Never"), kit.tr("1 hour"), kit.tr("1 day"), kit.tr("7 days")}
	for lbl, i in exp_labels {
		on := st.del_expiry == i
		idx := p.div(ui, on ? "h-7 px-2.5 rounded-md items-center justify-center bg-background shadow-sm" : "h-7 px-2.5 rounded-md items-center justify-center hover:bg-background/60")
		p.focusable(ui, idx)
		p.text(ui, lbl, on ? "text-xs font-medium whitespace-nowrap" : "text-xs text-muted-foreground whitespace-nowrap")
		p.end(ui)
		if p.activated(ui, idx) {
			st.del_expiry = i
		}
	}
	p.end(ui)
	p.end(ui)
	p.end(ui)

	if st.minted != "" {
		x, _ := ck.find_identity(st.ids, st.minted)
		p.row(ui, "items-start gap-3 px-4 py-3 rounded-xl bg-emerald-50 border border-emerald-200")
		p.icon(ui, AI_CIRCLE_CHECK, "size-4 shrink-0 text-emerald-700 mt-0.5")
		p.col(ui, "flex-1 gap-2")
		p.text(ui, kit.tr("Stored apart from this machine's own session. Hand it to the program that will hold it:"), "text-sm text-emerald-900")
		p.row(ui, "self-start rounded-md bg-emerald-900 px-3 py-1.5")
		p.text(ui, fmt.tprintf("PALM_CLOUD_SESSION=%s ai", st.minted_path), "text-xs font-mono text-emerald-50")
		p.end(ui)
		p.text(ui, kit.trf("It reaches the cloud as %s@%s. Revoke it below at any time.", x.handle != "" ? x.handle : st.minted, MAIL_DOMAIN), "text-xs text-emerald-800")
		p.end(ui)
		p.end(ui)
	}

	p.row(ui, "items-center gap-2 justify-end")
	if btn(ui, kit.tr("Close"), .Ghost) {
		st.del_open = false
		delete(st.minted)
		st.minted = ""
	}
	if btn(ui, kit.tr("Create scoped session"), .Default, .Default, AI_KEY_ROUND) || sub {
		submit_delegate(st)
	}
	p.end(ui)
}

submit_delegate :: proc(st: ^St) {
	live := live_ids(st)
	if st.fixture || len(live) == 0 {
		return
	}
	x := live[clamp(st.del_ident, 0, len(live) - 1)]
	name := strings.trim_space(string(st.del_name[:]))
	if name == "" {
		say(st, kit.tr("Give the session a name you will recognise."), bad = true)
		return
	}
	kind := st.del_kind == 0 ? "assistant" : "device"
	m, e := act_delegate(st, x, name, kind, EXPIRIES[st.del_expiry])
	if !ck.ok(e) {
		say(st, err_text(e), bad = true)
		return
	}
	delete(st.minted)
	st.minted = strings.clone(x.handle)
	delete(st.minted_path)
	st.minted_path = strings.clone(short_home(m.path))
	say(st, kit.trf("%s can now act for %s.", name, x.display_name))
}

// ---------------------------------------------------------------------------
// This session
// ---------------------------------------------------------------------------

session_page :: proc(st: ^St, ui: ^p.Ctx) {
	scoped := st.scope.id != ""
	page_header(ui, kit.tr("This session"), kit.tr("What this window is allowed to do, as the database sees it. The same rule applies to every app and every assistant."))

	p.col(ui, "w-full rounded-2xl border border-border bg-card p-6 gap-5")
	p.row(ui, "items-center gap-4")
	if scoped {
		identity_avatar(ui, st.scope, "size-12", "text-base")
		p.col(ui, "flex-1 gap-0.5")
		p.text(ui, kit.trf("Acts for %s only", st.scope.display_name), "text-lg font-semibold")
		p.text(ui, kit.trf("%s@%s · the token carries palm_identity", st.scope.handle, MAIL_DOMAIN), "text-sm text-muted-foreground")
		p.end(ui)
		sc.badge_icon(ui, kit.tr("Scoped"), AI_LOCK, .Outline)
	} else {
		p.div(ui, "size-12 rounded-xl items-center justify-center bg-foreground")
		p.icon(ui, AI_SHIELD_CHECK, "size-6 text-background")
		p.end(ui)
		p.col(ui, "flex-1 gap-0.5")
		p.text(ui, kit.tr("Full account"), "text-lg font-semibold")
		p.text(ui, kit.trf("%s · every identity, unscoped", st.email), "text-sm text-muted-foreground")
		p.end(ui)
		sc.badge(ui, kit.tr("Unscoped"), .Secondary)
	}
	p.end(ui)

	sc.separator(ui)

	can := [?]struct {
		ok:   bool,
		what: string,
	} {
		{true, scoped ? kit.tr("Read and write this identity's mail, files and profile") : kit.tr("Read and write every identity's data")},
		{!scoped, kit.tr("See the other identities")},
		{!scoped, kit.tr("Create, rename and archive identities")},
		{!scoped, kit.tr("Delegate a session to an assistant or device")},
		{!scoped, kit.tr("Change the password, list or end other sessions")},
	}
	p.col(ui, "gap-2.5")
	for c in can {
		p.row(ui, "items-center gap-3")
		p.div(ui, c.ok ? "size-5 rounded-full items-center justify-center bg-emerald-100" : "size-5 rounded-full items-center justify-center bg-muted")
		p.icon(ui, c.ok ? AI_CHECK : AI_X, c.ok ? "size-3 text-emerald-700" : "size-3 text-muted-foreground")
		p.end(ui)
		p.text(ui, c.what, c.ok ? "text-sm text-foreground flex-1" : "text-sm text-muted-foreground line-through flex-1")
		p.end(ui)
	}
	p.end(ui)
	p.end(ui)

	// The facts underneath, for whoever wants to check.
	p.col(ui, "w-full rounded-2xl border border-border bg-muted/40 p-5 gap-2")
	p.text(ui, kit.tr("Underneath"), "text-xs font-medium text-muted-foreground uppercase tracking-wide")
	kv :: proc(ui: ^p.Ctx, k, v: string) {
		p.row(ui, "items-center gap-4")
		p.text(ui, k, "text-xs text-muted-foreground font-mono w-[140]")
		p.text(ui, v, "text-xs text-foreground font-mono truncate flex-1")
		p.end(ui)
	}
	kv(ui, "palm_identity", scoped ? st.scope.id : kit.tr("(absent: unscoped)"))
	kv(ui, "sub", st.user_id)
	cur_session := ""
	for s in st.sess {
		if s.current {
			cur_session = s.session_id
		}
	}
	kv(ui, "session_id", cur_session)
	kv(ui, "api", st.c != nil ? st.c.url_text : ck.DEFAULT_URL)
	kv(ui, "token store", st.c != nil ? st.c.dir : "~/.local/share/palm/cloud")
	p.end(ui)

	p.col(ui, "w-full rounded-2xl border border-border p-5 gap-3")
	p.text(ui, kit.tr("Running an app as one identity"), "text-sm font-semibold")
	p.text(ui, kit.tr("Every Palmframe app reads PALM_IDENTITY. Set, it uses the session this machine holds for that identity and nothing else; there is no fallback to the full account."), "text-sm text-muted-foreground leading-relaxed")
	p.col(ui, "rounded-lg bg-foreground px-4 py-3 gap-1")
	handle := st.current != "" ? st.current : "work"
	p.text(ui, fmt.tprintf("$ PALM_IDENTITY=%s mail", handle), "text-xs font-mono text-background")
	p.text(ui, fmt.tprintf("$ PALM_IDENTITY=%s accounts whoami --json", handle), "text-xs font-mono text-background")
	p.end(ui)
	p.end(ui)
}

// ---------------------------------------------------------------------------
// Security
// ---------------------------------------------------------------------------

security_page :: proc(st: ^St, ui: ^p.Ctx) {
	page_header(ui, kit.tr("Security"), kit.tr("How this account is protected. The designs are in cloud/docs/accounts.md; what is not built yet says so."))
	items := [?]struct {
		icon:   p.Icon,
		title:  string,
		body:   string,
		status: string,
		live:   bool,
	} {
		{AI_LOCK, kit.tr("Password"), kit.tr("At least 8 characters. Scoped sessions cannot change it: the gateway refuses."), kit.tr("Active"), true},
		{AI_KEY_ROUND, kit.tr("Passkeys"), kit.tr("Sign in with the machine's own key instead of a password, including at the login screen."), kit.tr("Planned"), false},
		{AI_SHIELD_CHECK, kit.tr("Two-step verification"), kit.tr("A one-time code from an authenticator app, asked for when the full account is used."), kit.tr("Planned"), false},
		{AI_USERS, kit.tr("Recovery"), kit.tr("Recovery codes, and a recovery contact who can vouch for you, without email to an identity you may have lost."), kit.tr("Planned"), false},
	}
	p.col(ui, "w-full rounded-2xl border border-border bg-card overflow-hidden")
	for it, i in items {
		p.row(ui, i < len(items) - 1 ? "items-center gap-4 px-5 py-4 border-b border-border" : "items-center gap-4 px-5 py-4")
		p.div(ui, "size-9 rounded-lg items-center justify-center bg-muted shrink-0")
		p.icon(ui, it.icon, "size-4 text-foreground")
		p.end(ui)
		p.col(ui, "flex-1 min-w-0 gap-0.5")
		p.text(ui, it.title, "text-sm font-medium")
		p.text(ui, it.body, "text-xs text-muted-foreground leading-relaxed")
		p.end(ui)
		if it.live {
			sc.badge_icon(ui, it.status, AI_CHECK, .Secondary)
		} else {
			sc.badge(ui, it.status, .Outline)
		}
		p.end(ui)
	}
	p.end(ui)
}

// ---------------------------------------------------------------------------
// The confirmation dialog
// ---------------------------------------------------------------------------

confirm_dialog :: proc(st: ^St, ui: ^p.Ctx) {
	if st.confirm == .None {
		return
	}
	title, body, action: string
	switch st.confirm {
	case .Archive:
		title = kit.trf("Archive %s?", st.confirm_label)
		body = kit.tr("Its mail, files and profile are kept but become unreachable, and every session acting for it ends now. You can restore it later.")
		action = kit.tr("Archive")
	case .Revoke:
		title = kit.trf("Revoke %s?", st.confirm_label)
		body = kit.tr("It stops working immediately, including any request it is making right now. It cannot be undone; delegate again if you need to.")
		action = kit.tr("Revoke")
	case .End_Session:
		title = kit.trf("Sign out %s?", st.confirm_label)
		body = kit.tr("That machine will have to sign in again with the password.")
		action = kit.tr("Sign out")
	case .Sign_Out:
		title = kit.tr("Sign out of Palmframe?")
		body = kit.tr("This machine forgets the account's session. Sessions delegated to identities keep working until you revoke them.")
		action = kit.tr("Sign out")
	case .None:
	}
	p.div(ui, "absolute inset-0 z-50 bg-black/40 items-center justify-center")
	defer p.end(ui)
	p.col(ui, "w-[440] rounded-2xl border border-border bg-card shadow-2xl p-6 gap-4")
	defer p.end(ui)
	p.text(ui, title, "text-lg font-semibold")
	p.text(ui, body, "text-sm text-muted-foreground leading-relaxed")
	p.row(ui, "items-center gap-2 justify-end pt-2")
	if btn(ui, kit.tr("Cancel"), .Ghost) {
		st.confirm = .None
	}
	if btn(ui, action, st.confirm == .Sign_Out || st.confirm == .End_Session ? .Default : .Destructive) {
		run_confirm(st)
	}
	p.end(ui)
}

run_confirm :: proc(st: ^St) {
	k := st.confirm
	st.confirm = .None
	if st.fixture {
		return
	}
	e: ck.Error
	switch k {
	case .Archive:
		_, e = ck.archive_identity(st.c, st.confirm_id, context.temp_allocator)
		reload(st)
		if ck.ok(e) {
			say(st, kit.trf("%s is archived.", st.confirm_label))
		}
	case .Revoke:
		e = act_revoke(st, st.confirm_id)
		if ck.ok(e) {
			say(st, kit.trf("%s is revoked.", st.confirm_label))
		}
	case .End_Session:
		e = act_end_session(st, st.confirm_id)
		if ck.ok(e) {
			say(st, kit.trf("%s is signed out.", st.confirm_label))
		}
	case .Sign_Out:
		e = act_sign_out(st)
		st.want_focus = "email"
	case .None:
	}
	if !ck.ok(e) {
		say(st, err_text(e), bad = true)
	}
}
