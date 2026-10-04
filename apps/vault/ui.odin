package main

// Everything on screen.
//
// Two rules run through this file. A secret is masked until you ask for it,
// including in the list and including in the editor. And anything with a
// deadline on it -- the clipboard, the TOTP step, the idle lock -- shows that
// deadline, because a security property you cannot see is one you cannot rely
// on.

import "core:fmt"
import "core:math"
import "core:strings"
import "core:time"
import p "palmy:."
import sc "shadcn:."

MASK :: '•'

register_theme :: proc() {
	c :: p.hex
	p.register_color("background", c(0x0b0b0e))
	p.register_color("foreground", c(0xf4f4f5))
	p.register_color("card", c(0x14141a))
	p.register_color("card-foreground", c(0xf4f4f5))
	p.register_color("popover", c(0x1b1b22))
	p.register_color("popover-foreground", c(0xf4f4f5))
	p.register_color("primary", c(0xf4f4f5))
	p.register_color("primary-foreground", c(0x15151a))
	p.register_color("secondary", c(0x262630))
	p.register_color("secondary-foreground", c(0xf4f4f5))
	p.register_color("muted", c(0x1d1d24))
	p.register_color("muted-foreground", c(0x9a9aa6))
	p.register_color("accent", c(0x2d2d38))
	p.register_color("accent-foreground", c(0xf4f4f5))
	p.register_color("destructive", c(0xf87171))
	p.register_color("destructive-foreground", c(0xf4f4f5))
	p.register_color("border", c(0x2a2a33))
	p.register_color("input", c(0x2a2a33))
	p.register_color("ring", c(0x8b8b9c))
}

// vfield wraps palmy's text field so the caller gets the node id back, which
// is the only way to move focus into it from a keyboard shortcut.
vfield :: proc(
	ui: ^p.Ctx,
	name: string,
	buf: ^[dynamic]u8,
	placeholder: string,
	class: string,
	mask: rune = 0,
) -> (
	changed: bool,
	submitted: bool,
	id: u64,
) {
	p.key(ui, name)
	at := p.node_count(ui)
	changed, submitted = p.text_field(ui, buf, placeholder, class, mask)
	id = p.node_id(ui, at)
	return
}

build :: proc(ui: ^p.Ctx, st: ^St) {
	switch st.screen {
	case .Unlock, .Create:
		lock_screen(ui, st)
	case .Open:
		open_screen(ui, st)
	}
	pick_overlay(ui, st)
	toast_view(ui, st)
}

// ---------------------------------------------------------------------------
// The lock screen
// ---------------------------------------------------------------------------

lock_screen :: proc(ui: ^p.Ctx, st: ^St) {
	creating := st.screen == .Create

	p.col(ui, "w-full h-full items-center justify-center gap-0 px-6")
	defer p.end(ui)

	p.col(ui, "w-[460] shrink-0 gap-5 p-7 rounded-2xl border border-border bg-card")
	defer p.end(ui)

	p.row(ui, "shrink-0 items-center gap-3")
	p.icon(ui, creating ? IC_KEY : IC_LOCK, "size-6 shrink-0 text-foreground")
	p.col(ui, "flex-1 gap-0.5")
	p.text(ui, creating ? "Create a vault" : "Vault locked", "text-lg font-semibold whitespace-nowrap")
	p.text(ui, short_path(st.path), "text-xs text-muted-foreground truncate")
	p.end(ui)
	p.end(ui)

	p.divider(ui, "w-full h-px shrink-0 bg-border")

	if st.lock_note != "" {
		p.row(ui, "w-full shrink-0 items-center gap-2 px-3 py-2 rounded-lg bg-muted")
		p.icon(ui, IC_SHIELD_CHECK, "size-4 shrink-0 text-emerald-400")
		p.text(ui, st.lock_note, "text-xs text-muted-foreground")
		p.end(ui)
	}

	if creating {
		p.text(
			ui,
			"This password is the only thing standing between the vault file and whoever has it. There is no recovery, no reset and no copy of it anywhere: lose it and the entries are gone.",
			"w-full text-xs text-muted-foreground whitespace-normal",
		)
	}

	// Master password
	p.col(ui, "w-full shrink-0 gap-1.5")
	p.text(ui, "Master password", "text-xs font-medium text-muted-foreground whitespace-nowrap")
	_, sub, id := vfield(ui, "master", &st.pw, "", "w-full h-10 text-base font-mono", MASK)
	st.pw_id = id
	p.end(ui)
	if sub {
		begin_lock_action(st)
	}

	if creating {
		p.col(ui, "w-full shrink-0 gap-1.5")
		p.text(ui, "Again", "text-xs font-medium text-muted-foreground whitespace-nowrap")
		_, sub2, id2 := vfield(ui, "master2", &st.pw2, "", "w-full h-10 text-base font-mono", MASK)
		st.pw2_id = id2
		p.end(ui)
		if sub2 {
			begin_lock_action(st)
		}

		bits := password_bits(string(st.pw[:]))
		s := strength_of(bits)
		p.row(ui, "w-full shrink-0 items-center gap-2")
		p.progress(ui, f32(clamp(bits / 128.0, 0, 1)), "flex-1 h-1.5 rounded-full")
		p.textf(
			ui,
			p.concat(ui, "text-xs font-medium whitespace-nowrap tabular-nums ", STRENGTH_CLASS[s]),
			"%.0f bits, %s",
			bits,
			STRENGTH_LABEL[s],
		)
		p.style(ui).shrink = 0
		p.end(ui)
	}

	if st.lock_err != "" {
		p.row(ui, "w-full shrink-0 items-start gap-2 px-3 py-2 rounded-lg bg-destructive/10")
		p.icon(ui, IC_SHIELD_ALERT, "size-4 shrink-0 text-destructive")
		p.text(ui, st.lock_err, "flex-1 text-xs text-destructive whitespace-normal")
		p.end(ui)
	}

	// The button
	busy := st.busy != .None
	p.row(ui, "w-full shrink-0 items-center gap-2")
	idx := p.div(
		ui,
		p.concat(
			ui,
			"flex-1 flex-row h-10 items-center justify-center gap-2 rounded-lg transition ",
			busy ? "bg-muted text-muted-foreground" : "bg-primary text-primary-foreground hover:bg-primary/90",
		),
	)
	p.focusable(ui)
	if p.activated(ui, idx) && !busy {
		begin_lock_action(st)
	}
	p.icon(ui, busy ? IC_REFRESH_CW : (creating ? IC_KEY : IC_LOCK_OPEN), "size-4 shrink-0")
	p.text(
		ui,
		busy ? "Deriving the key…" : (creating ? "Create vault" : "Unlock"),
		"text-sm font-medium whitespace-nowrap",
	)
	p.end(ui)
	p.end(ui)

	// What this costs, and what it does not do.
	p.col(ui, "w-full shrink-0 gap-1.5 pt-1")
	p.row(ui, "shrink-0 items-center gap-2")
	p.icon(ui, IC_TIMER, "size-3.5 shrink-0 text-muted-foreground")
	p.textf(
		ui,
		"text-[11] text-muted-foreground whitespace-nowrap",
		"Argon2id, %d MiB · %d passes · %d lanes",
		KDF_DEFAULT.m / 1024,
		KDF_DEFAULT.t,
		KDF_DEFAULT.par,
	)
	p.style(ui).shrink = 0
	if st.derive_ms > 0 {
		p.textf(ui, "text-[11] text-muted-foreground whitespace-nowrap tabular-nums", "· %.0f ms here", st.derive_ms)
		p.style(ui).shrink = 0
	}
	p.end(ui)
	p.row(ui, "shrink-0 items-center gap-2")
	p.icon(ui, IC_SHIELD, "size-3.5 shrink-0 text-muted-foreground")
	p.text(
		ui,
		"No network access of any kind: no sync, no breach check, no telemetry.",
		"text-[11] text-muted-foreground whitespace-nowrap",
	)
	p.style(ui).shrink = 0
	p.end(ui)
	p.row(ui, "shrink-0 items-center gap-2")
	p.icon(ui, IC_KEYBOARD, "size-3.5 shrink-0 text-muted-foreground")
	p.text(ui, "Ctrl O opens a different vault file", "text-[11] text-muted-foreground whitespace-nowrap")
	p.style(ui).shrink = 0
	p.end(ui)
	p.end(ui)

	// Put the keyboard in the password field without making the user click
	// first. This has to be a flag rather than "is focus zero": after a lock,
	// focus is still sitting on whatever widget of the open vault had it, and
	// the first thing typed at a lock screen must be the password.
	if st.focus_pw || p.focus_id(ui) == 0 {
		p.set_focus(ui, st.pw_id)
		st.focus_pw = false
	}
}

// ---------------------------------------------------------------------------
// The open vault
// ---------------------------------------------------------------------------

open_screen :: proc(ui: ^p.Ctx, st: ^St) {
	refilter(st)

	header(ui, st)

	p.row(ui, "w-full flex-1 min-h-0")
	sidebar(ui, st)
	list_pane(ui, st)
	detail_pane(ui, st)
	p.end(ui)

	footer(ui, st)

	if st.gen_open {
		generator_overlay(ui, st)
	}
	if st.mp_open {
		master_overlay(ui, st)
	}
	if st.confirm_del {
		delete_overlay(ui, st)
	}
}

header :: proc(ui: ^p.Ctx, st: ^St) {
	p.row(ui, "w-full h-[58] shrink-0 items-center gap-3 px-4 border-b border-border")
	defer p.end(ui)

	p.row(ui, "shrink-0 items-center gap-2")
	p.icon(ui, IC_SHIELD_CHECK, "size-[18] shrink-0 text-emerald-400")
	p.text(ui, "Vault", "text-base font-semibold whitespace-nowrap")
	p.end(ui)

	// Search
	p.row(ui, "flex-1 min-w-[180] items-center gap-2 max-w-[520]")
	p.icon(ui, IC_SEARCH, "size-4 shrink-0 text-muted-foreground")
	changed, _, id := vfield(ui, "search", &st.query, "Search titles, usernames, URLs and tags…", "flex-1 h-9 text-sm")
	st.query_id = id
	if changed {
		st.sel = 0
	}
	p.end(ui)

	p.spacer(ui)

	// The clipboard countdown. This is the only place the app admits to having
	// put a secret somewhere it does not control, so it says so loudly.
	if st.clip_until > 0 {
		left := math.max(f32(st.clip_until - f64(ui.now)), 0)
		p.row(ui, "shrink-0 items-center gap-2 h-8 px-3 rounded-lg bg-amber-500/12")
		p.icon(ui, IC_CLIPBOARD_CHECK, "size-4 shrink-0 text-amber-400")
		p.textf(
			ui,
			"text-xs font-medium text-amber-400 whitespace-nowrap tabular-nums",
			"%s on the clipboard · clears in %.0fs",
			st.clip_label,
			math.ceil(left),
		)
		p.style(ui).shrink = 0
		p.end(ui)
	}

	// Idle countdown, once it is close enough to matter.
	if st.idle_limit > 0 {
		left := st.idle_limit - (f64(ui.now) - st.last_input)
		if left <= math.min(30.0, st.idle_limit) {
			p.row(ui, "shrink-0 items-center gap-1.5 h-8 px-3 rounded-lg bg-muted")
			p.icon(ui, IC_TIMER, "size-3.5 shrink-0 text-muted-foreground")
			p.textf(
				ui,
				"text-xs text-muted-foreground whitespace-nowrap tabular-nums",
				"locks in %.0fs",
				math.max(math.ceil(left), 0),
			)
			p.style(ui).shrink = 0
			p.end(ui)
		}
	}

	hbtn(ui, st, IC_PLUS, "New", proc(st: ^St, ui: ^p.Ctx) {begin_edit(st, true)})
	hbtn(ui, st, IC_WAND, "Generate", proc(st: ^St, ui: ^p.Ctx) {open_generator(ui, st)})
	hbtn(ui, st, IC_LOCK, "Lock", proc(st: ^St, ui: ^p.Ctx) {lock(st, "Locked", ui.now)})
}

hbtn :: proc(ui: ^p.Ctx, st: ^St, ic: p.Icon, label: string, act: proc(st: ^St, ui: ^p.Ctx)) {
	p.key(ui, label)
	idx := p.div(
		ui,
		"flex-row shrink-0 items-center gap-1.5 h-8 px-2.5 rounded-lg border border-border transition hover:bg-accent",
	)
	p.focusable(ui)
	if p.activated(ui, idx) {
		act(st, ui)
	}
	p.icon(ui, ic, "size-3.5 shrink-0 text-muted-foreground")
	p.text(ui, label, "text-xs font-medium whitespace-nowrap")
	p.style(ui).shrink = 0
	p.end(ui)
}

sidebar :: proc(ui: ^p.Ctx, st: ^St) {
	p.col(ui, "w-[188] shrink-0 h-full gap-1 p-3 border-r border-border overflow-hidden")
	defer p.end(ui)

	p.text(ui, "TAGS", "text-[10] font-semibold text-muted-foreground tracking-wider whitespace-nowrap")

	tag_row(ui, st, "", "All entries", len(st.v.entries))
	for t in vault_all_tags(&st.v, context.temp_allocator) {
		n := 0
		for &e in st.v.entries {
			for have in e.tags {
				if have == t {
					n += 1
					break
				}
			}
		}
		tag_row(ui, st, t, t, n)
	}

	p.spacer(ui)

	p.col(ui, "w-full shrink-0 gap-1 pt-2 border-t border-border")
	p.row(ui, "shrink-0 items-center gap-1.5")
	p.icon(ui, IC_LOCK, "size-3 shrink-0 text-muted-foreground")
	p.text(ui, AEAD_NAME[st.sess.algo], "text-[10] text-muted-foreground whitespace-nowrap")
	p.style(ui).shrink = 0
	p.end(ui)
	p.textf(
		ui,
		"text-[10] text-muted-foreground whitespace-nowrap",
		"Argon2id %d MiB t%d p%d",
		st.sess.kdf.m / 1024,
		st.sess.kdf.t,
		st.sess.kdf.par,
	)
	p.text(ui, "Offline. No network.", "text-[10] text-muted-foreground whitespace-nowrap")
	p.end(ui)
}

tag_row :: proc(ui: ^p.Ctx, st: ^St, value, label: string, n: int) {
	on := st.tag == value
	p.key(ui, label)
	idx := p.div(ui, "flex-row w-full shrink-0 items-center gap-2 h-7 px-2 rounded-md transition")
	p.apply(ui, on ? "bg-accent text-foreground" : "text-muted-foreground hover:bg-muted", idx)
	p.focusable(ui)
	if p.activated(ui, idx) {
		if st.tag != "" {
			delete(st.tag)
		}
		st.tag = strings.clone(value)
		st.sel = 0
	}
	p.icon(ui, value == "" ? IC_LIST : IC_TAG, "size-3.5 shrink-0")
	p.text(ui, label, "flex-1 text-xs truncate")
	p.textf(ui, "text-[10] text-muted-foreground whitespace-nowrap tabular-nums", "%d", n)
	p.style(ui).shrink = 0
	p.end(ui)
}

list_pane :: proc(ui: ^p.Ctx, st: ^St) {
	p.col(ui, "w-[320] shrink-0 h-full border-r border-border overflow-hidden")
	defer p.end(ui)

	p.row(ui, "w-full h-8 shrink-0 items-center px-3")
	p.textf(ui, "text-[11] text-muted-foreground whitespace-nowrap", "%d of %d", len(st.rows), len(st.v.entries))
	p.end(ui)

	p.col(ui, "w-full flex-1 min-h-0 overflow-auto")
	defer p.end(ui)

	if len(st.rows) == 0 {
		p.col(ui, "w-full flex-1 items-center justify-center gap-2 px-6")
		p.icon(ui, IC_SEARCH, "size-6 shrink-0 text-muted-foreground")
		p.text(
			ui,
			len(st.v.entries) == 0 ? "The vault is empty. Ctrl N adds an entry." : "Nothing matches that search.",
			"text-xs text-muted-foreground text-center whitespace-normal",
		)
		p.end(ui)
		return
	}

	for row, i in st.rows {
		e := &st.v.entries[row]
		sel := i == st.sel
		p.key(ui, fmt.tprintf("row%d", row))
		idx := p.div(ui, "flex-col w-full shrink-0 gap-0.5 px-3 py-2 border-b border-border/60 transition")
		p.apply(ui, sel ? "bg-accent" : "hover:bg-muted", idx)
		if p.clickable(ui, idx) {
			st.sel = i
		}

		p.row(ui, "w-full items-center gap-2")
		p.text(ui, e.title, "flex-1 text-sm font-medium truncate")
		if e.totp != "" {
			p.icon(ui, IC_TIMER, "size-3 shrink-0 text-muted-foreground")
		}
		p.end(ui)

		p.row(ui, "w-full items-center gap-2")
		p.text(
			ui,
			e.username == "" ? "no username" : e.username,
			"flex-1 text-[11] text-muted-foreground truncate",
		)
		b := password_bits(e.password)
		p.textf(
			ui,
			p.concat(ui, "text-[10] whitespace-nowrap tabular-nums ", STRENGTH_CLASS[strength_of(b)]),
			"%.0f bits",
			b,
		)
		p.style(ui).shrink = 0
		p.end(ui)
		p.end(ui)
	}
}

detail_pane :: proc(ui: ^p.Ctx, st: ^St) {
	p.col(ui, "flex-1 min-w-0 h-full overflow-auto")
	defer p.end(ui)

	if st.editing {
		editor(ui, st)
		return
	}

	e := current(st)
	if e == nil {
		p.col(ui, "w-full flex-1 items-center justify-center gap-3 px-8")
		p.icon(ui, IC_SHIELD, "size-8 shrink-0 text-muted-foreground")
		p.text(ui, "Select an entry", "text-sm text-muted-foreground whitespace-nowrap")
		p.end(ui)
		return
	}

	p.col(ui, "w-full gap-5 p-6")
	defer p.end(ui)

	// Title row
	p.row(ui, "w-full shrink-0 items-start gap-3")
	p.col(ui, "flex-1 min-w-0 gap-1")
	p.text(ui, e.title, "text-xl font-semibold truncate")
	p.row(ui, "w-full items-center gap-2")
	for t in e.tags {
		p.key(ui, t)
		sc.badge(ui, t, .Secondary)
	}
	p.end(ui)
	p.end(ui)
	hbtn(ui, st, IC_PENCIL, "Edit", proc(st: ^St, ui: ^p.Ctx) {begin_edit(st, false)})
	hbtn(ui, st, IC_TRASH, "Delete", proc(st: ^St, ui: ^p.Ctx) {
		st.confirm_del = true
		p.set_focus(ui, 0)
	})
	p.end(ui)

	// TOTP first: it is the thing with a clock on it.
	if e.totp != "" {
		totp_card(ui, st, e)
	}

	row_value(ui, st, IC_USER, "Username", e.username, false, "username")
	row_value(ui, st, IC_ASTERISK, "Password", e.password, true, "password")
	row_value(ui, st, IC_GLOBE, "URL", e.url, false, "")

	if e.notes != "" {
		p.col(ui, "w-full shrink-0 gap-1.5")
		p.row(ui, "shrink-0 items-center gap-2")
		p.icon(ui, IC_FILE_TEXT, "size-3.5 shrink-0 text-muted-foreground")
		p.text(ui, "Notes", "text-[11] font-medium text-muted-foreground whitespace-nowrap")
		p.style(ui).shrink = 0
		p.end(ui)
		p.text(ui, e.notes, "w-full text-sm text-foreground whitespace-normal")
		p.end(ui)
	}

	// Timestamps
	p.row(ui, "w-full shrink-0 items-center gap-4 pt-1")
	stamp(ui, IC_CALENDAR, "Created", e.created)
	stamp(ui, IC_PENCIL, "Modified", e.modified)
	p.end(ui)

	// History
	p.col(ui, "w-full shrink-0 gap-2 pt-2 border-t border-border")
	p.key(ui, "histhead")
	hidx := p.div(ui, "flex-row w-full shrink-0 items-center gap-2 h-8 px-2 -mx-2 rounded-md transition hover:bg-muted")
	p.focusable(ui)
	if p.activated(ui, hidx) {
		st.history = !st.history
	}
	p.icon(ui, st.history ? IC_CHEVRON_DOWN : IC_CHEVRON_RIGHT, "size-3.5 shrink-0 text-muted-foreground")
	p.icon(ui, IC_ROTATE_CCW, "size-3.5 shrink-0 text-muted-foreground")
	p.textf(
		ui,
		"flex-1 text-xs font-medium text-muted-foreground whitespace-nowrap",
		"Password history (%d)",
		len(e.history),
	)
	p.end(ui)

	if st.history {
		if len(e.history) == 0 {
			p.text(ui, "This password has never been changed here.", "text-xs text-muted-foreground whitespace-nowrap")
		}
		for h, i in e.history {
			p.key(ui, fmt.tprintf("h%d", i))
			p.row(ui, "w-full shrink-0 items-center gap-3 h-8 px-2.5 rounded-md bg-muted")
			p.text(ui, when_text(h.when_), "w-[150] shrink-0 text-[11] text-muted-foreground whitespace-nowrap tabular-nums")
			p.text(
				ui,
				st.reveal ? h.password : masked(len(h.password)),
				"flex-1 text-xs font-mono truncate",
			)
			copy_btn(ui, st, fmt.tprintf("hc%d", i), "previous password", h.password)
			p.end(ui)
		}
	}
	p.end(ui)
}

stamp :: proc(ui: ^p.Ctx, ic: p.Icon, label: string, t: i64) {
	p.row(ui, "shrink-0 items-center gap-1.5")
	p.icon(ui, ic, "size-3 shrink-0 text-muted-foreground")
	p.textf(ui, "text-[11] text-muted-foreground whitespace-nowrap", "%s %s", label, when_text(t))
	p.style(ui).shrink = 0
	p.end(ui)
}

when_text :: proc(t: i64) -> string {
	if t <= 0 {
		return "unknown"
	}
	y, m, d := time.date(time.unix(t, 0))
	h, mi, _ := time.clock_from_time(time.unix(t, 0))
	return fmt.tprintf("%04d-%02d-%02d %02d:%02d", y, int(m), d, h, mi)
}

masked :: proc(n: int) -> string {
	k := clamp(n, 0, 32)
	sb := strings.builder_make(context.temp_allocator)
	for _ in 0 ..< k {
		strings.write_rune(&sb, MASK)
	}
	return strings.to_string(sb)
}

row_value :: proc(ui: ^p.Ctx, st: ^St, ic: p.Icon, label, value: string, secret: bool, copy_label: string) {
	p.col(ui, "w-full shrink-0 gap-1.5")
	defer p.end(ui)

	p.row(ui, "shrink-0 items-center gap-2")
	p.icon(ui, ic, "size-3.5 shrink-0 text-muted-foreground")
	p.text(ui, label, "text-[11] font-medium text-muted-foreground whitespace-nowrap")
	p.style(ui).shrink = 0
	if secret {
		b := password_bits(value)
		p.textf(
			ui,
			p.concat(ui, "text-[10] whitespace-nowrap tabular-nums ", STRENGTH_CLASS[strength_of(b)]),
			"· %.0f bits, %s",
			b,
			STRENGTH_LABEL[strength_of(b)],
		)
		p.style(ui).shrink = 0
	}
	p.end(ui)

	p.row(ui, "w-full shrink-0 items-center gap-2 h-10 px-3 rounded-lg bg-muted")
	shown := value
	if value == "" {
		shown = "—"
	} else if secret && !st.reveal {
		shown = masked(len(value))
	}
	p.text(ui, shown, p.concat(ui, "flex-1 truncate ", secret ? "text-sm font-mono" : "text-sm"))
	if secret {
		p.key(ui, "reveal")
		ridx := p.div(ui, "flex-row shrink-0 items-center justify-center size-7 rounded-md transition hover:bg-accent")
		p.focusable(ui)
		if p.activated(ui, ridx) {
			st.reveal = !st.reveal
		}
		p.icon(ui, st.reveal ? IC_EYE_OFF : IC_EYE, "size-3.5 shrink-0 text-muted-foreground")
		p.end(ui)
	}
	if copy_label != "" {
		copy_btn(ui, st, copy_label, copy_label, value)
	}
	p.end(ui)
}

copy_btn :: proc(ui: ^p.Ctx, st: ^St, key, label, value: string) {
	p.key(ui, key)
	idx := p.div(ui, "flex-row shrink-0 items-center justify-center size-7 rounded-md transition hover:bg-accent")
	p.focusable(ui)
	if p.activated(ui, idx) {
		e := current(st)
		what := e != nil ? fmt.tprintf("%s for %s", label, e.title) : label
		copy_secret(st, ui, what, value)
	}
	p.icon(ui, IC_COPY, "size-3.5 shrink-0 text-muted-foreground")
	p.end(ui)
}

totp_card :: proc(ui: ^p.Ctx, st: ^St, e: ^Entry) {
	now := now_unix()
	code, ok := totp_code(e.totp, now, e.totp_period, int(e.totp_digits), e.totp_algo)
	left := totp_remaining(now, e.totp_period)
	frac := f32(left) / f32(e.totp_period == 0 ? 30 : e.totp_period)

	p.col(ui, "w-full shrink-0 gap-2 p-4 rounded-xl border border-border bg-card")
	defer p.end(ui)

	p.row(ui, "w-full shrink-0 items-center gap-2")
	p.icon(ui, IC_TIMER, "size-3.5 shrink-0 text-muted-foreground")
	p.text(ui, "One-time code", "text-[11] font-medium text-muted-foreground whitespace-nowrap")
	p.style(ui).shrink = 0
	p.textf(
		ui,
		"text-[10] text-muted-foreground whitespace-nowrap",
		"· TOTP %s, %d digits, %ds step",
		TOTP_ALGO_NAME[e.totp_algo],
		e.totp_digits,
		e.totp_period,
	)
	p.style(ui).shrink = 0
	p.end(ui)

	p.row(ui, "w-full shrink-0 items-center gap-3")
	if ok {
		// Grouped in the middle, the way every authenticator shows it.
		half := len(code) / 2
		p.text(ui, fmt.tprintf("%s %s", code[:half], code[half:]), "text-3xl font-mono font-semibold tracking-wide whitespace-nowrap")
	} else {
		p.text(ui, "invalid secret", "text-sm text-destructive whitespace-nowrap")
	}
	p.style(ui).shrink = 0
	p.spacer(ui)
	p.col(ui, "shrink-0 items-end gap-1")
	p.textf(
		ui,
		p.concat(
			ui,
			"text-xs whitespace-nowrap tabular-nums ",
			left <= 5 ? "text-destructive" : "text-muted-foreground",
		),
		"%ds",
		left,
	)
	p.progress(ui, frac, "w-[110] h-1.5 rounded-full")
	p.end(ui)
	if ok {
		copy_btn(ui, st, "totpcopy", "TOTP code", code)
	}
	p.end(ui)
}

// ---------------------------------------------------------------------------
// Editor
// ---------------------------------------------------------------------------

editor :: proc(ui: ^p.Ctx, st: ^St) {
	p.col(ui, "w-full gap-4 p-6")
	defer p.end(ui)

	p.row(ui, "w-full shrink-0 items-center gap-3")
	p.icon(ui, IC_PENCIL, "size-4 shrink-0 text-muted-foreground")
	p.text(ui, st.ed_new ? "New entry" : "Edit entry", "flex-1 text-lg font-semibold truncate")
	hbtn(ui, st, IC_X, "Cancel", proc(st: ^St, ui: ^p.Ctx) {cancel_edit(st)})
	hbtn(ui, st, IC_SAVE, "Save", proc(st: ^St, ui: ^p.Ctx) {commit_edit(st, ui)})
	p.end(ui)

	for f in Field {
		secret := f == .Password || f == .Totp
		p.col(ui, "w-full shrink-0 gap-1.5")
		p.row(ui, "shrink-0 items-center gap-2")
		p.text(ui, FIELD_LABEL[f], "text-[11] font-medium text-muted-foreground whitespace-nowrap")
		p.style(ui).shrink = 0
		if f == .Password {
			b := password_bits(string(st.ed[.Password][:]))
			p.textf(
				ui,
				p.concat(ui, "text-[10] whitespace-nowrap tabular-nums ", STRENGTH_CLASS[strength_of(b)]),
				"· %.0f bits, %s",
				b,
				STRENGTH_LABEL[strength_of(b)],
			)
			p.style(ui).shrink = 0
		}
		if f == .Totp && strings.trim_space(string(st.ed[.Totp][:])) != "" {
			good := totp_secret_ok(string(st.ed[.Totp][:]))
			p.text(
				ui,
				good ? "· valid base32" : "· not valid base32",
				p.concat(ui, "text-[10] whitespace-nowrap ", good ? "text-emerald-400" : "text-destructive"),
			)
			p.style(ui).shrink = 0
		}
		p.end(ui)

		p.row(ui, "w-full shrink-0 items-center gap-2")
		mask: rune = (secret && !st.reveal) ? MASK : 0
		class := f == .Notes ? "flex-1 h-20 text-sm" : "flex-1 h-9 text-sm"
		if secret {
			class = "flex-1 h-9 text-sm font-mono"
		}
		_, sub, _ := vfield(ui, FIELD_LABEL[f], &st.ed[f], "", class, mask)
		if sub && f != .Notes {
			commit_edit(st, ui)
		}
		if secret {
			p.key(ui, fmt.tprintf("rev%v", f))
			ridx := p.div(ui, "flex-row shrink-0 items-center justify-center size-9 rounded-md border border-border transition hover:bg-accent")
			p.focusable(ui)
			if p.activated(ui, ridx) {
				st.reveal = !st.reveal
			}
			p.icon(ui, st.reveal ? IC_EYE_OFF : IC_EYE, "size-3.5 shrink-0 text-muted-foreground")
			p.end(ui)
		}
		if f == .Password {
			p.key(ui, "edgen")
			gidx := p.div(ui, "flex-row shrink-0 items-center gap-1.5 h-9 px-2.5 rounded-md border border-border transition hover:bg-accent")
			p.focusable(ui)
			if p.activated(ui, gidx) {
				open_generator(ui, st)
			}
			p.icon(ui, IC_WAND, "size-3.5 shrink-0 text-muted-foreground")
			p.text(ui, "Generate", "text-xs whitespace-nowrap")
			p.style(ui).shrink = 0
			p.end(ui)
		}
		p.end(ui)
		p.end(ui)
	}

	p.text(
		ui,
		"Tab moves between fields. Ctrl S saves, Escape discards, Ctrl G generates, Ctrl R reveals.",
		"w-full text-[11] text-muted-foreground whitespace-normal",
	)
}

// ---------------------------------------------------------------------------
// Overlays
// ---------------------------------------------------------------------------

scrim :: proc(ui: ^p.Ctx) -> int {
	idx := p.div(ui, "absolute inset-0 z-40 flex-col items-center justify-center bg-black/55")
	return idx
}

generator_overlay :: proc(ui: ^p.Ctx, st: ^St) {
	scrim(ui)
	defer p.end(ui)

	p.col(ui, "w-[560] shrink-0 gap-4 p-6 rounded-2xl border border-border bg-popover")
	defer p.end(ui)

	p.row(ui, "w-full shrink-0 items-center gap-2")
	p.icon(ui, IC_WAND, "size-4 shrink-0 text-foreground")
	p.text(ui, "Generate a password", "flex-1 text-base font-semibold truncate")
	p.text(ui, "Esc to close", "text-[11] text-muted-foreground whitespace-nowrap")
	p.style(ui).shrink = 0
	p.end(ui)

	// The password itself
	p.row(ui, "w-full shrink-0 items-center gap-2 h-12 px-3 rounded-lg bg-muted")
	p.text(ui, st.gen_pw == "" ? "—" : st.gen_pw, "flex-1 text-lg font-mono truncate")
	p.key(ui, "genagain")
	ridx := p.div(ui, "flex-row shrink-0 items-center justify-center size-8 rounded-md transition hover:bg-accent")
	p.focusable(ui)
	if p.activated(ui, ridx) {
		regenerate(st)
	}
	p.icon(ui, IC_REFRESH_CW, "size-4 shrink-0 text-muted-foreground")
	p.end(ui)
	copy_btn(ui, st, "gencopy", "generated password", st.gen_pw)
	p.end(ui)

	// Length
	p.col(ui, "w-full shrink-0 gap-2")
	p.row(ui, "w-full shrink-0 items-center gap-2")
	p.text(ui, "Length", "text-xs font-medium text-muted-foreground whitespace-nowrap")
	p.style(ui).shrink = 0
	p.spacer(ui)
	p.textf(ui, "text-xs font-mono whitespace-nowrap tabular-nums", "%d", st.gen.length)
	p.style(ui).shrink = 0
	p.end(ui)
	len_f := f32(st.gen.length)
	if p.slider(ui, &len_f, f32(GEN_MIN_LEN), f32(GEN_MAX_LEN), "w-full h-5") {
		st.gen.length = int(len_f + 0.5)
		regenerate(st)
	}
	p.end(ui)

	// Classes
	p.row(ui, "w-full shrink-0 items-center gap-2")
	for c, i in Class {
		on := c in st.gen.classes
		p.key(ui, CLASS_LABEL[c])
		idx := p.div(ui, "flex-row shrink-0 items-center gap-1.5 h-8 px-3 rounded-lg border transition")
		p.apply(ui, on ? "bg-accent border-foreground/20" : "border-border text-muted-foreground hover:bg-muted", idx)
		p.focusable(ui)
		if p.activated(ui, idx) {
			if on {
				if card(st.gen.classes) > 1 {
					st.gen.classes -= {c}
				}
			} else {
				st.gen.classes += {c}
			}
			regenerate(st)
		}
		p.icon(ui, on ? IC_CHECK : IC_MINUS, "size-3 shrink-0")
		p.textf(ui, "text-xs font-mono whitespace-nowrap", "%s", CLASS_LABEL[c])
		p.style(ui).shrink = 0
		p.textf(ui, "text-[10] text-muted-foreground whitespace-nowrap", "%d", i + 1)
		p.style(ui).shrink = 0
		p.end(ui)
	}
	p.spacer(ui)
	p.key(ui, "ambig")
	aidx := p.div(ui, "flex-row shrink-0 items-center gap-1.5 h-8 px-3 rounded-lg border transition")
	p.apply(
		ui,
		st.gen.no_ambiguous ? "bg-accent border-foreground/20" : "border-border text-muted-foreground hover:bg-muted",
		aidx,
	)
	p.focusable(ui)
	if p.activated(ui, aidx) {
		st.gen.no_ambiguous = !st.gen.no_ambiguous
		regenerate(st)
	}
	p.icon(ui, st.gen.no_ambiguous ? IC_CHECK : IC_MINUS, "size-3 shrink-0")
	p.text(ui, "no Il1O0o", "text-xs whitespace-nowrap")
	p.style(ui).shrink = 0
	p.end(ui)
	p.end(ui)

	// Entropy, with the honest caveat attached.
	alpha := gen_alphabet(st.gen, context.temp_allocator)
	bits := gen_opts_bits(st.gen)
	s := strength_of(bits)
	p.col(ui, "w-full shrink-0 gap-1.5 p-3 rounded-lg bg-muted")
	p.row(ui, "w-full shrink-0 items-center gap-2")
	p.icon(ui, IC_SHIELD_CHECK, "size-3.5 shrink-0 text-muted-foreground")
	p.textf(
		ui,
		p.concat(ui, "text-sm font-medium whitespace-nowrap tabular-nums ", STRENGTH_CLASS[s]),
		"%.0f bits of entropy, %s",
		bits,
		STRENGTH_LABEL[s],
	)
	p.style(ui).shrink = 0
	p.end(ui)
	p.textf(
		ui,
		"w-full text-[11] text-muted-foreground whitespace-normal",
		"%d characters drawn uniformly from an alphabet of %d, by rejection sampling over the OS random generator. That is %d x log2(%d) bits exactly, because the draw really is uniform -- the figure beside a password you typed yourself is only an upper bound.",
		clamp(st.gen.length, GEN_MIN_LEN, GEN_MAX_LEN),
		len(alpha),
		clamp(st.gen.length, GEN_MIN_LEN, GEN_MAX_LEN),
		len(alpha),
	)
	p.end(ui)

	p.text(
		ui,
		st.editing \
		? "Enter puts it in the editor · Ctrl C copies · Space redraws · 1-4 toggle classes · arrows change the length" \
		: "Enter copies it · Space redraws · 1-4 toggle classes · arrows change the length",
		"w-full text-[11] text-muted-foreground whitespace-normal",
	)
}

master_overlay :: proc(ui: ^p.Ctx, st: ^St) {
	scrim(ui)
	defer p.end(ui)

	p.col(ui, "w-[520] shrink-0 gap-4 p-6 rounded-2xl border border-border bg-popover")
	defer p.end(ui)

	p.row(ui, "w-full shrink-0 items-center gap-2")
	p.icon(ui, IC_KEY, "size-4 shrink-0 text-foreground")
	p.text(ui, "Change the master password", "flex-1 text-base font-semibold truncate")
	p.end(ui)

	p.text(
		ui,
		"The vault is re-encrypted under a new key from a new salt, written to a new file, and moved into place with one rename. If this is interrupted at any point, the vault you have now is still there and still opens with the password you have now.",
		"w-full text-[11] text-muted-foreground whitespace-normal",
	)

	p.col(ui, "w-full shrink-0 gap-1.5")
	p.text(ui, "New master password", "text-[11] font-medium text-muted-foreground whitespace-nowrap")
	_, _, id := vfield(ui, "mpnew", &st.mp_new, "", "w-full h-9 text-sm font-mono", MASK)
	st.mp_id = id
	p.end(ui)
	if st.focus_mp {
		p.set_focus(ui, st.mp_id)
		st.focus_mp = false
	}

	p.col(ui, "w-full shrink-0 gap-1.5")
	p.text(ui, "Again", "text-[11] font-medium text-muted-foreground whitespace-nowrap")
	vfield(ui, "mpagain", &st.mp_again, "", "w-full h-9 text-sm font-mono", MASK)
	p.end(ui)

	bits := password_bits(string(st.mp_new[:]))
	s := strength_of(bits)
	p.row(ui, "w-full shrink-0 items-center gap-2")
	p.progress(ui, f32(clamp(bits / 128.0, 0, 1)), "flex-1 h-1.5 rounded-full")
	p.textf(
		ui,
		p.concat(ui, "text-[11] whitespace-nowrap tabular-nums ", STRENGTH_CLASS[s]),
		"%.0f bits, %s",
		bits,
		STRENGTH_LABEL[s],
	)
	p.style(ui).shrink = 0
	p.end(ui)

	if st.mp_err != "" {
		p.text(ui, st.mp_err, "w-full text-xs text-destructive whitespace-normal")
	}

	p.row(ui, "w-full shrink-0 items-center gap-2")
	p.spacer(ui)
	hbtn(ui, st, IC_X, "Cancel", proc(st: ^St, ui: ^p.Ctx) {
		wipe_buf(&st.mp_new)
		wipe_buf(&st.mp_again)
		st.mp_open = false
		st.mp_err = ""
	})
	hbtn(ui, st, IC_KEY, "Re-encrypt", proc(st: ^St, ui: ^p.Ctx) {st.busy = .Rekeying})
	p.end(ui)

	if st.busy == .Rekeying {
		p.text(ui, "Deriving the new key…", "text-xs text-muted-foreground whitespace-nowrap")
	}
}

delete_overlay :: proc(ui: ^p.Ctx, st: ^St) {
	scrim(ui)
	defer p.end(ui)

	e := current(st)
	p.col(ui, "w-[420] shrink-0 gap-4 p-6 rounded-2xl border border-border bg-popover")
	defer p.end(ui)

	p.row(ui, "w-full shrink-0 items-center gap-2")
	p.icon(ui, IC_TRIANGLE_ALERT, "size-4 shrink-0 text-destructive")
	p.text(ui, "Delete this entry?", "flex-1 text-base font-semibold truncate")
	p.end(ui)
	p.textf(
		ui,
		"w-full text-xs text-muted-foreground whitespace-normal",
		"%s, and its password history, will be removed from the vault. This cannot be undone.",
		e != nil ? e.title : "The entry",
	)
	p.row(ui, "w-full shrink-0 items-center gap-2")
	p.spacer(ui)
	hbtn(ui, st, IC_X, "Keep (n)", proc(st: ^St, ui: ^p.Ctx) {st.confirm_del = false})
	hbtn(ui, st, IC_TRASH, "Delete (y)", proc(st: ^St, ui: ^p.Ctx) {delete_current(st, ui)})
	p.end(ui)
}

// ---------------------------------------------------------------------------
// Footer and toast
// ---------------------------------------------------------------------------

footer :: proc(ui: ^p.Ctx, st: ^St) {
	p.row(ui, "w-full h-[34] shrink-0 items-center gap-3 px-4 border-t border-border")
	defer p.end(ui)

	hint(ui, "Ctrl C", "copy password")
	hint(ui, "Ctrl T", "copy code")
	hint(ui, "Ctrl R", "reveal")
	hint(ui, "Ctrl N", "new")
	hint(ui, "Ctrl G", "generate")
	hint(ui, "Ctrl M", "master password")
	hint(ui, "Ctrl L", "lock")
	p.spacer(ui)
	p.textf(
		ui,
		"text-[10] text-muted-foreground whitespace-nowrap",
		"a copied secret clears itself after %.0fs · the vault locks itself after %.0fs idle",
		st.clip_limit,
		st.idle_limit,
	)
	p.style(ui).shrink = 0
}

hint :: proc(ui: ^p.Ctx, keys, what: string) {
	p.row(ui, "shrink-0 items-center gap-1.5")
	sc.kbd(ui, keys)
	p.text(ui, what, "text-[10] text-muted-foreground whitespace-nowrap")
	p.style(ui).shrink = 0
	p.end(ui)
}

toast_view :: proc(ui: ^p.Ctx, st: ^St) {
	if st.toast == "" {
		return
	}
	if st.toast_t > 1e17 {
		st.toast_t = f64(ui.now) + 3.0
	}
	idx := p.div(ui, "absolute z-50 flex-row items-center gap-2 h-9 px-3.5 rounded-lg border border-border bg-popover")
	s := p.style(ui, idx)
	s.inset[p.LEFT] = p.px(16)
	s.inset[p.BOTTOM] = p.px(48)
	p.icon(ui, IC_CIRCLE_CHECK, "size-3.5 shrink-0 text-emerald-400")
	p.text(ui, st.toast, "text-xs whitespace-nowrap")
	p.style(ui).shrink = 0
	p.end(ui)
}
