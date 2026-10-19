package main

// Everything on screen.
//
// Three rules run through this file. A secret is masked until you ask for
// it, in the list, the detail and the editor. Anything with a deadline on it
// -- the clipboard, the TOTP step, the idle lock -- shows that deadline,
// because a security property you cannot see is one you cannot rely on. And
// every item says whose it is: which identity, which vault, shared by whom,
// read-only or not, in that identity's colour, because the whole point of
// identities is that you can tell them apart at a glance.

import "core:fmt"
import "core:math"
import "core:strings"
import "core:time"
import p "palmy:."
import sc "shadcn:."

MASK :: '•'

register_theme :: proc(dark := false) {
	sc.register_shadcn_theme(dark)
	p.set_text_gamma(1.8)
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

// varea is vfield's multi-line twin: palmy's text area, with the node id
// handed back so the self-test and a keyboard shortcut can put focus in it.
varea :: proc(ui: ^p.Ctx, name: string, buf: ^[dynamic]u8, class: string) -> u64 {
	p.key(ui, name)
	at := p.node_count(ui)
	p.text_area(ui, buf, "", class)
	return p.node_id(ui, at)
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
// Identity colours
// ---------------------------------------------------------------------------

// src_color is the Tailwind palette name an entry is drawn in: its vault's
// colour, else its identity's; slate for the local file.
src_color :: proc(st: ^St, src: int) -> string {
	if st.mode != .Account || st.acct == nil || src < 0 || src >= len(st.acct.sources) {
		return "slate"
	}
	s := &st.acct.sources[src]
	if s.kind == .Shared_Items || s.kind == .Shared_Vault {
		// Shares are drawn in the colour of the identity that sees them, so
		// a work tab's shared items still look like work.
		if i := ident_by_id(st.acct, s.viewer); i != nil && i.color != "" {
			return i.color
		}
	}
	if s.color != "" {
		return s.color
	}
	return "slate"
}

KIND_ICON := [Item_Kind]p.Icon {
	.Login    = IC_GLOBE,
	.Passkey  = IC_KEY_ROUND,
	.Card     = IC_CREDIT_CARD,
	.Note     = IC_FILE_TEXT,
	.Document = IC_ID_CARD,
	.Totp     = IC_TIMER,
}

KIND_PLURAL := [Item_Kind]string {
	.Login    = "Logins",
	.Passkey  = "Passkeys",
	.Card     = "Cards",
	.Note     = "Secure notes",
	.Document = "Documents",
	.Totp     = "Authenticator",
}

// tile draws an item's icon on a tinted square in its identity's colour.
tile :: proc(ui: ^p.Ctx, ic: p.Icon, color: string, size := "size-9", icon_size := "size-4") {
	p.div(ui, fmt.tprintf("flex-col shrink-0 items-center justify-center %s rounded-lg bg-%s-500/15", size, color))
	p.icon(ui, ic, fmt.tprintf("%s shrink-0 text-%s-500", icon_size, color))
	p.end(ui)
}

avatar :: proc(ui: ^p.Ctx, name: string, color: string, size := "size-5", text := "text-[10]") {
	p.div(ui, fmt.tprintf("flex-col shrink-0 items-center justify-center %s rounded-full bg-%s-500", size, color))
	initial := name == "" ? "?" : strings.to_upper(name[:1], context.temp_allocator)
	p.text(ui, initial, fmt.tprintf("%s font-semibold text-white whitespace-nowrap", text))
	p.end(ui)
}

// ---------------------------------------------------------------------------
// The lock screen
// ---------------------------------------------------------------------------

lock_screen :: proc(ui: ^p.Ctx, st: ^St) {
	creating := st.screen == .Create
	account := st.mode == .Account

	p.col(ui, "w-full h-full items-center justify-center gap-0 px-6 bg-muted/40")
	defer p.end(ui)

	p.col(ui, "w-[452] shrink-0 gap-5 p-7 rounded-2xl border border-border bg-card shadow-sm")
	defer p.end(ui)

	p.row(ui, "shrink-0 items-center gap-3")
	p.div(ui, "flex-col shrink-0 items-center justify-center size-10 rounded-xl bg-primary")
	p.icon(ui, creating ? IC_KEY : IC_LOCK, "size-5 shrink-0 text-primary-foreground")
	p.end(ui)
	p.col(ui, "flex-1 min-w-0 gap-0.5")
	p.text(ui, creating ? "Create a vault" : "Vault locked", "text-lg font-semibold whitespace-nowrap")
	sub := account ? st.acct.cache.email : short_path(st.path)
	p.text(ui, sub, "text-xs text-muted-foreground truncate")
	p.end(ui)
	p.end(ui)

	if account && len(st.acct.cache.idents) > 0 {
		p.row(ui, "w-full shrink-0 items-center gap-2 flex-wrap")
		for id in st.acct.cache.idents {
			if st.scope != "" && st.scope != id.handle {
				continue
			}
			p.key(ui, id.id)
			p.row(ui, "shrink-0 items-center gap-1.5 h-7 pl-1 pr-2.5 rounded-full border border-border bg-background")
			avatar(ui, id.name, id.color)
			p.text(ui, id.name, "text-xs font-medium whitespace-nowrap")
			p.style(ui).shrink = 0
			p.end(ui)
		}
		p.end(ui)
	}

	p.divider(ui, "w-full h-px shrink-0 bg-border")

	if st.lock_note != "" {
		p.row(ui, "w-full shrink-0 items-center gap-2 px-3 py-2 rounded-lg bg-muted")
		p.icon(ui, IC_SHIELD_CHECK, "size-4 shrink-0 text-emerald-500")
		p.text(ui, st.lock_note, "text-xs text-muted-foreground")
		p.end(ui)
	}

	if creating {
		p.text(
			ui,
			"This password is the only thing standing between the vault file and whoever has it. There is no recovery, no reset and no copy of it anywhere: lose it and the items are gone.",
			"w-full text-xs text-muted-foreground whitespace-normal",
		)
	}

	// Master password
	p.col(ui, "w-full shrink-0 gap-1.5")
	p.text(ui, "Master password", "text-xs font-medium text-muted-foreground whitespace-nowrap")
	_, sub_pw, id := vfield(ui, "master", &st.pw, "", "w-full h-10 text-base font-mono", MASK)
	st.pw_id = id
	p.end(ui)
	if sub_pw {
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

	// What this costs, and what it does and does not do.
	p.col(ui, "w-full shrink-0 gap-1.5 pt-1")
	foot :: proc(ui: ^p.Ctx, ic: p.Icon, text: string) {
		p.row(ui, "shrink-0 items-center gap-2")
		p.icon(ui, ic, "size-3.5 shrink-0 text-muted-foreground")
		p.text(ui, text, "text-[11] text-muted-foreground whitespace-nowrap")
		p.style(ui).shrink = 0
		p.end(ui)
	}
	foot(
		ui,
		IC_TIMER,
		st.derive_ms > 0 ? fmt.tprintf("Argon2id, %d MiB · %d passes · %d lanes · %.0f ms here", KDF_DEFAULT.m / 1024, KDF_DEFAULT.t, KDF_DEFAULT.par, st.derive_ms) : fmt.tprintf("Argon2id, %d MiB · %d passes · %d lanes", KDF_DEFAULT.m / 1024, KDF_DEFAULT.t, KDF_DEFAULT.par),
	)
	if account {
		foot(ui, IC_SHIELD, "End-to-end encrypted. The server holds ciphertext it cannot open.")
		foot(ui, IC_SMARTPHONE, "Unlocks with your master password and this device's Secret Key.")
	} else {
		foot(ui, IC_SHIELD, "A file on this device: no sync, no breach check, no telemetry.")
		foot(ui, IC_KEYBOARD, "Ctrl O opens a different vault file")
	}
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
	if st.nav.kind == .Health && !st.editing {
		health_pane(ui, st)
	} else {
		detail_pane(ui, st)
	}
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
	if st.share_open {
		share_overlay(ui, st)
	}
	if st.imp_open {
		import_overlay(ui, st)
	}
	if st.af.prompt.kind != .None {
		autofill_overlay(ui, st)
	}
}

header :: proc(ui: ^p.Ctx, st: ^St) {
	p.row(ui, "w-full h-[56] shrink-0 items-center gap-3 px-4 border-b border-border bg-background")
	defer p.end(ui)

	p.row(ui, "w-[228] shrink-0 items-center gap-2.5")
	p.div(ui, "flex-col shrink-0 items-center justify-center size-8 rounded-lg bg-primary")
	p.icon(ui, IC_SHIELD_CHECK, "size-4 shrink-0 text-primary-foreground")
	p.end(ui)
	p.col(ui, "flex-1 min-w-0 gap-0")
	p.text(ui, "Vault", "text-sm font-semibold whitespace-nowrap")
	scope := "This device"
	if st.mode == .Account {
		scope = "All identities"
		if st.scope != "" {
			if i := ident_by_handle(st.acct, st.scope); i != nil {
				scope = i.name
			}
		}
	}
	p.text(ui, scope, "text-[11] text-muted-foreground truncate")
	p.end(ui)
	p.end(ui)

	// Search
	p.row(ui, "flex-1 min-w-[180] max-w-[520] h-9 items-center gap-2 px-3 rounded-lg border border-input bg-background")
	p.icon(ui, IC_SEARCH, "size-4 shrink-0 text-muted-foreground")
	changed, _, id := vfield(ui, "search", &st.query, "Search titles, usernames, sites and tags", "flex-1 h-8 text-sm border-0 bg-transparent px-0")
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
		p.row(ui, "shrink-0 items-center gap-2 h-8 px-3 rounded-lg bg-amber-500/15")
		p.icon(ui, IC_CLIPBOARD_CHECK, "size-4 shrink-0 text-amber-600")
		p.textf(
			ui,
			"text-xs font-medium text-amber-600 whitespace-nowrap tabular-nums",
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

	if st.mode == .Account {
		label := st.sync_msg != "" ? st.sync_msg : "not synced yet"
		if n := len(st.acct.cache.pending); n > 0 && st.sync_msg == "" {
			label = fmt.tprintf("%d waiting to sync", n)
		}
		if st.busy == .Syncing {
			label = "syncing…"
		}
		hbtn(ui, st, IC_CLOUD, label, proc(st: ^St, ui: ^p.Ctx) {st.busy = .Syncing})
	}
	hbtn(ui, st, IC_DOWNLOAD, "Import", proc(st: ^St, ui: ^p.Ctx) {begin_pick(st, .Import)})
	hbtn(ui, st, IC_WAND, "Generate", proc(st: ^St, ui: ^p.Ctx) {open_generator(ui, st)})
	pbtn(ui, IC_PLUS, "New item", "new", proc(st: ^St, ui: ^p.Ctx) {begin_edit(st, true)}, st)
	hbtn(ui, st, IC_LOCK, "Lock", proc(st: ^St, ui: ^p.Ctx) {lock(st, "Locked", ui.now)})
}

hbtn :: proc(ui: ^p.Ctx, st: ^St, ic: p.Icon, label: string, act: proc(st: ^St, ui: ^p.Ctx), disabled := false) {
	p.key(ui, label)
	idx := p.div(
		ui,
		"flex-row shrink-0 items-center gap-1.5 h-8 px-3 rounded-md border border-border bg-background transition",
	)
	p.apply(ui, disabled ? "opacity-50" : "hover:bg-accent", idx)
	p.focusable(ui)
	if p.activated(ui, idx) && !disabled {
		act(st, ui)
	}
	p.icon(ui, ic, "size-3.5 shrink-0 text-muted-foreground")
	p.text(ui, label, "text-xs font-medium whitespace-nowrap")
	p.style(ui).shrink = 0
	p.end(ui)
}

// pbtn is the primary button: one per screen, the thing you came to do.
pbtn :: proc(ui: ^p.Ctx, ic: p.Icon, label, key: string, act: proc(st: ^St, ui: ^p.Ctx), st: ^St) {
	p.key(ui, key)
	idx := p.div(ui, "flex-row shrink-0 items-center gap-1.5 h-8 px-3 rounded-md bg-primary text-primary-foreground transition hover:bg-primary/90")
	p.focusable(ui)
	if p.activated(ui, idx) {
		act(st, ui)
	}
	p.icon(ui, ic, "size-3.5 shrink-0")
	p.text(ui, label, "text-xs font-medium whitespace-nowrap")
	p.style(ui).shrink = 0
	p.end(ui)
}

// ---------------------------------------------------------------------------
// The sidebar: categories, identities and their vaults, tags, health
// ---------------------------------------------------------------------------

sidebar :: proc(ui: ^p.Ctx, st: ^St) {
	p.col(ui, "w-[244] shrink-0 h-full border-r border-border bg-muted/30 overflow-hidden")
	defer p.end(ui)
	p.col(ui, "w-full flex-1 min-h-0 gap-0.5 p-3 overflow-auto")

	n_fav := 0
	kinds: [Item_Kind]int
	for &e in st.v.entries {
		if e.favorite {
			n_fav += 1
		}
		kinds[e.kind] += 1
	}
	nav_row(ui, st, {kind = .All}, IC_LIST, "All items", len(st.v.entries), "")
	nav_row(ui, st, {kind = .Favorites}, IC_STAR, "Favorites", n_fav, "")

	section_label(ui, "Categories")
	for k in Item_Kind {
		if kinds[k] == 0 && k != .Login {
			continue
		}
		nav_row(ui, st, {kind = .Kind, ikind = k}, KIND_ICON[k], KIND_PLURAL[k], kinds[k], "")
	}

	if st.mode == .Account {
		for &id in st.acct.cache.idents {
			if st.scope != "" && st.scope != id.handle {
				continue
			}
			p.key(ui, id.id)
			p.row(ui, "w-full shrink-0 items-center gap-2 pt-4 pb-1 px-2")
			avatar(ui, id.name, id.color)
			p.text(ui, id.name, "flex-1 text-xs font-semibold truncate")
			p.text(ui, id.kind, "text-[10] text-muted-foreground whitespace-nowrap")
			p.style(ui).shrink = 0
			p.end(ui)
			for s, i in st.acct.sources {
				if s.viewer != id.id {
					continue
				}
				n := 0
				for &e in st.v.entries {
					if e.src == i {
						n += 1
					}
				}
				label := s.name
				ic := IC_LOCK
				switch s.kind {
				case .Own:
				case .Shared_Vault:
					label = fmt.tprintf("%s · %s", s.name, s.owner_handle)
					ic = IC_USERS
				case .Shared_Items:
					label = "Shared with me"
					ic = IC_SHARE
				}
				nav_row(ui, st, {kind = .Source, src = i}, ic, label, n, src_color(st, i))
			}
		}
	} else {
		section_label(ui, "This device")
		p.row(ui, "w-full shrink-0 items-center gap-2 h-8 px-2")
		p.icon(ui, IC_LAPTOP, "size-3.5 shrink-0 text-muted-foreground")
		p.text(ui, short_path(st.path), "flex-1 text-xs text-muted-foreground truncate")
		p.end(ui)
	}

	tags := vault_all_tags(&st.v, context.temp_allocator)
	if len(tags) > 0 {
		section_label(ui, "Tags")
		for t, i in tags {
			if i >= 8 {
				break
			}
			n := 0
			for &e in st.v.entries {
				for have in e.tags {
					if have == t {
						n += 1
						break
					}
				}
			}
			p.key(ui, fmt.tprintf("tag-%s", t))
			on := st.nav.kind == .Tag && st.tag == t
			idx := p.div(ui, "flex-row w-full shrink-0 items-center gap-2 h-8 px-2 rounded-md transition")
			p.apply(ui, on ? "bg-accent text-foreground" : "text-muted-foreground hover:bg-accent/60", idx)
			p.focusable(ui)
			if p.activated(ui, idx) {
				if st.tag != "" {
					delete(st.tag)
				}
				st.tag = strings.clone(t)
				st.nav = {kind = .Tag}
				st.sel = 0
			}
			p.icon(ui, IC_HASH, "size-3.5 shrink-0")
			p.text(ui, t, "flex-1 text-xs truncate")
			p.textf(ui, "text-[10] text-muted-foreground whitespace-nowrap tabular-nums", "%d", n)
			p.style(ui).shrink = 0
			p.end(ui)
		}
	}
	p.end(ui)

	// Health, always reachable, with the number of things to fix.
	if !st.health_ok {
		health_refresh(st)
	}
	issues := st.health.weak + st.health.reused + st.health.exposed + st.health.breached
	p.col(ui, "w-full shrink-0 gap-1 p-3 border-t border-border")
	p.key(ui, "nav-health")
	on := st.nav.kind == .Health
	idx := p.div(ui, "flex-row w-full shrink-0 items-center gap-2 h-9 px-2 rounded-md transition")
	p.apply(ui, on ? "bg-accent text-foreground" : "hover:bg-accent/60", idx)
	p.focusable(ui)
	if p.activated(ui, idx) {
		st.nav = {kind = .Health}
		st.sel = 0
		st.health_ok = false
	}
	p.icon(ui, IC_ACTIVITY, "size-4 shrink-0 text-muted-foreground")
	p.text(ui, "Password health", "flex-1 text-xs font-medium truncate")
	if issues > 0 {
		p.div(ui, "flex-col shrink-0 items-center justify-center h-5 min-w-5 px-1.5 rounded-full bg-amber-500/20")
		p.textf(ui, "text-[10] font-semibold text-amber-600 whitespace-nowrap tabular-nums", "%d", issues)
		p.end(ui)
	} else {
		p.icon(ui, IC_CIRCLE_CHECK, "size-3.5 shrink-0 text-emerald-500")
	}
	p.end(ui)

	p.row(ui, "w-full shrink-0 items-start gap-2 px-2 pt-1")
	p.icon(ui, IC_SHIELD, "size-3 shrink-0 text-muted-foreground")
	p.col(ui, "flex-1 min-w-0 gap-0.5")
	if st.mode == .Account {
		p.text(ui, "End-to-end encrypted", "text-[10] font-medium text-muted-foreground whitespace-nowrap")
		p.text(ui, "X25519 + ML-KEM-768 · XChaCha20", "text-[10] text-muted-foreground truncate")
	} else {
		p.text(ui, AEAD_NAME[st.sess.algo], "text-[10] font-medium text-muted-foreground whitespace-nowrap")
		p.textf(ui, "text-[10] text-muted-foreground truncate", "Argon2id %d MiB · offline", st.sess.kdf.m / 1024)
	}
	p.end(ui)
	p.end(ui)
	p.end(ui)
}

section_label :: proc(ui: ^p.Ctx, text: string) {
	p.text(ui, strings.to_upper(text, context.temp_allocator), "w-full shrink-0 pt-4 pb-1 px-2 text-[10] font-semibold text-muted-foreground tracking-wider whitespace-nowrap")
}

nav_row :: proc(ui: ^p.Ctx, st: ^St, nav: Nav, ic: p.Icon, label: string, n: int, color: string) {
	on := st.nav == nav
	p.key(ui, fmt.tprintf("nav-%v-%v-%d", nav.kind, nav.ikind, nav.src))
	idx := p.div(ui, "flex-row w-full shrink-0 items-center gap-2 h-8 px-2 rounded-md transition")
	p.apply(ui, on ? "bg-accent text-foreground" : "text-foreground/80 hover:bg-accent/60", idx)
	p.focusable(ui)
	if p.activated(ui, idx) {
		st.nav = nav
		st.sel = 0
		if nav.kind == .Source && st.mode == .Account && st.acct.sources[nav.src].role != "read" {
			st.ed_target = nav.src
		}
	}
	if color != "" {
		p.div(ui, fmt.tprintf("shrink-0 size-2.5 rounded-sm bg-%s-500", color))
		p.end(ui)
	}
	p.icon(ui, ic, "size-3.5 shrink-0 text-muted-foreground")
	p.text(ui, label, "flex-1 text-xs truncate")
	p.textf(ui, "text-[10] text-muted-foreground whitespace-nowrap tabular-nums", "%d", n)
	p.style(ui).shrink = 0
	p.end(ui)
}

nav_title :: proc(st: ^St) -> string {
	switch st.nav.kind {
	case .All:
		return "All items"
	case .Favorites:
		return "Favorites"
	case .Kind:
		return KIND_PLURAL[st.nav.ikind]
	case .Tag:
		return fmt.tprintf("#%s", st.tag)
	case .Source:
		if st.mode == .Account && st.nav.src < len(st.acct.sources) {
			s := &st.acct.sources[st.nav.src]
			if s.kind == .Shared_Items {
				return "Shared with me"
			}
			return s.name
		}
	case .Health:
		return "Needs attention"
	}
	return ""
}

// ---------------------------------------------------------------------------
// The list
// ---------------------------------------------------------------------------

subtitle_of :: proc(e: ^Entry) -> string {
	switch e.kind {
	case .Card:
		n := field_get(e, "Number")
		if len(n) >= 4 {
			return fmt.tprintf("•••• %s", n[len(n) - 4:])
		}
		return field_get(e, "Cardholder")
	case .Document:
		d := field_get(e, "Document")
		return d != "" ? d : "Identity document"
	case .Note:
		return "Secure note"
	case .Passkey:
		if e.passkey.rp_id != "" {
			return fmt.tprintf("%s · %s", e.passkey.user_name, e.passkey.rp_id)
		}
	case .Login, .Totp:
	}
	if e.username != "" {
		return e.username
	}
	if e.url != "" {
		return host_of(e.url)
	}
	return KIND_LABEL[e.kind]
}

list_pane :: proc(ui: ^p.Ctx, st: ^St) {
	p.col(ui, "w-[340] shrink-0 h-full border-r border-border overflow-hidden")
	defer p.end(ui)

	p.row(ui, "w-full h-11 shrink-0 items-center gap-2 px-4 border-b border-border")
	p.text(ui, nav_title(st), "flex-1 text-sm font-semibold truncate")
	p.textf(ui, "text-[11] text-muted-foreground whitespace-nowrap tabular-nums", "%d", len(st.rows))
	p.style(ui).shrink = 0
	p.end(ui)

	p.col(ui, "w-full flex-1 min-h-0 gap-0.5 p-2 overflow-auto")
	defer p.end(ui)

	if len(st.rows) == 0 {
		p.col(ui, "w-full flex-1 items-center justify-center gap-2 px-6")
		p.icon(ui, st.nav.kind == .Health ? IC_CIRCLE_CHECK : IC_SEARCH, "size-6 shrink-0 text-muted-foreground")
		msg := "Nothing matches that search."
		switch {
		case len(st.v.entries) == 0:
			msg = "The vault is empty. Ctrl N adds an item; Ctrl I imports from another password manager."
		case st.nav.kind == .Health:
			msg = "Nothing needs attention."
		}
		p.text(ui, msg, "text-xs text-muted-foreground text-center whitespace-normal")
		p.end(ui)
		return
	}

	for row, i in st.rows {
		e := &st.v.entries[row]
		sel := i == st.sel
		p.key(ui, fmt.tprintf("row-%s", e.id))
		idx := p.div(ui, "flex-row w-full shrink-0 items-center gap-3 px-2.5 py-2 rounded-lg transition")
		p.apply(ui, sel ? "bg-accent" : "hover:bg-accent/50", idx)
		if p.clickable(ui, idx) {
			st.sel = i
		}
		tile(ui, KIND_ICON[e.kind], src_color(st, e.src))

		p.col(ui, "flex-1 min-w-0 gap-0.5")
		p.row(ui, "w-full items-center gap-1.5")
		p.text(ui, e.title, "flex-1 text-sm font-medium truncate")
		if e.favorite {
			p.icon(ui, IC_STAR, "size-3 shrink-0 text-amber-500")
		}
		if e.flags & ENTRY_EXPOSED != 0 {
			p.icon(ui, IC_TRIANGLE_ALERT, "size-3 shrink-0 text-amber-500")
		}
		if e.totp != "" {
			p.icon(ui, IC_TIMER, "size-3 shrink-0 text-muted-foreground")
		}
		if st.mode == .Account && e.src >= 0 && e.src < len(st.acct.sources) && st.acct.sources[e.src].kind != .Own {
			p.icon(ui, IC_USERS, "size-3 shrink-0 text-muted-foreground")
		}
		p.end(ui)
		p.text(ui, subtitle_of(e), "w-full text-[11] text-muted-foreground truncate")
		p.end(ui)
		p.end(ui)
	}
}

// ---------------------------------------------------------------------------
// The detail pane
// ---------------------------------------------------------------------------

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
		p.text(ui, "Select an item", "text-sm text-muted-foreground whitespace-nowrap")
		p.end(ui)
		return
	}
	writable := book_writable(&st.bk, e)
	color := src_color(st, e.src)

	p.col(ui, "w-full gap-5 px-8 py-6")
	defer p.end(ui)

	// Title row
	p.row(ui, "w-full shrink-0 items-start gap-4")
	tile(ui, KIND_ICON[e.kind], color, "size-12", "size-6")
	p.col(ui, "flex-1 min-w-0 gap-1.5")
	p.text(ui, e.title, "text-xl font-semibold truncate")
	p.row(ui, "w-full items-center gap-2 flex-wrap")
	sc.badge(ui, KIND_LABEL[e.kind], .Secondary)
	if st.mode == .Account && e.src >= 0 && e.src < len(st.acct.sources) {
		s := &st.acct.sources[e.src]
		p.row(ui, "shrink-0 items-center gap-1.5 h-5 px-2 rounded-full border border-border")
		p.div(ui, fmt.tprintf("shrink-0 size-2 rounded-full bg-%s-500", color))
		p.end(ui)
		label := fmt.tprintf("%s · %s", handle_of(st.acct, s.viewer), s.name)
		if s.kind != .Own {
			label = fmt.tprintf("shared by %s · %s", s.owner_name, s.role == "write" ? "can edit" : "read-only")
		}
		p.text(ui, label, "text-[11] text-muted-foreground whitespace-nowrap")
		p.style(ui).shrink = 0
		p.end(ui)
	}
	for t in e.tags {
		p.key(ui, t)
		sc.badge(ui, t, .Outline)
	}
	p.end(ui)
	p.end(ui)
	p.key(ui, "fav")
	fidx := p.div(ui, "flex-row shrink-0 items-center justify-center size-8 rounded-md border border-border transition hover:bg-accent")
	p.focusable(ui)
	if p.activated(ui, fidx) {
		toggle_favorite(st, ui)
	}
	p.icon(ui, IC_STAR, p.concat(ui, "size-3.5 shrink-0 ", e.favorite ? "text-amber-500" : "text-muted-foreground"))
	p.end(ui)
	if !writable {
		// Nothing to press that would only say no.
		p.row(ui, "shrink-0 items-center gap-1.5 h-8 px-3 rounded-md bg-muted")
		p.icon(ui, IC_LOCK, "size-3.5 shrink-0 text-muted-foreground")
		p.text(ui, "Read-only", "text-xs text-muted-foreground whitespace-nowrap")
		p.style(ui).shrink = 0
		p.end(ui)
	} else {
		hbtn(ui, st, IC_PENCIL, "Edit", proc(st: ^St, ui: ^p.Ctx) {begin_edit(st, false)})
		if st.mode == .Account && e.src >= 0 && e.src < len(st.acct.sources) && st.acct.sources[e.src].kind == .Own {
			hbtn(ui, st, IC_SHARE, "Share", proc(st: ^St, ui: ^p.Ctx) {
				st.share_open = true
				st.share_err = ""
				wipe_buf(&st.share_with)
				p.set_focus(ui, 0)
			})
		}
		hbtn(ui, st, IC_TRASH, "Delete", proc(st: ^St, ui: ^p.Ctx) {
			st.confirm_del = true
			p.set_focus(ui, 0)
		})
	}
	p.end(ui)

	if e.flags & ENTRY_EXPOSED != 0 {
		p.row(ui, "w-full shrink-0 items-start gap-3 px-4 py-3 rounded-xl border border-amber-500/40 bg-amber-500/10")
		p.icon(ui, IC_TRIANGLE_ALERT, "size-4 shrink-0 text-amber-600")
		p.col(ui, "flex-1 min-w-0 gap-0.5")
		p.text(ui, "Change this password at the site", "text-sm font-medium text-amber-700")
		p.text(ui, "It was shared with someone whose access you since revoked. The vault re-encrypted it under a new key, but what they already read, they may have kept.", "w-full text-xs text-amber-700/90 whitespace-normal")
		p.end(ui)
		p.end(ui)
	}

	// TOTP first: it is the thing with a clock on it.
	if e.totp != "" {
		totp_card(ui, st, e)
	}

	is_login := e.kind == .Login || e.kind == .Totp || e.kind == .Passkey
	has_rows := len(e.fields) > 0 || (is_login && (e.kind == .Login || e.username != "" || e.password != "" || e.url != ""))
	if has_rows {
		p.col(ui, "w-full shrink-0 gap-0 rounded-xl border border-border overflow-hidden")
	}
	rows := 0
	switch e.kind {
	case .Login, .Totp, .Passkey:
		if e.username != "" || e.kind == .Login {
			row_value(ui, st, IC_USER, "Username", e.username, false, "username", rows > 0)
			rows += 1
		}
		if e.password != "" || e.kind == .Login {
			row_value(ui, st, IC_ASTERISK, "Password", e.password, true, "password", rows > 0)
			rows += 1
		}
		if e.url != "" {
			row_value(ui, st, IC_GLOBE, "Website", e.url, false, "", rows > 0)
			rows += 1
		}
		for u, i in e.urls {
			p.key(ui, fmt.tprintf("url%d", i))
			row_value(ui, st, IC_LINK, "Also on", u, false, "", rows > 0)
			rows += 1
		}
	case .Card, .Document, .Note:
	}
	for f, i in e.fields {
		p.key(ui, fmt.tprintf("kv%d", i))
		ic := f.secret ? IC_ASTERISK : IC_HASH
		row_value(ui, st, ic, f.label, f.value, f.secret, f.secret ? strings.to_lower(f.label, context.temp_allocator) : "", rows > 0)
		rows += 1
	}
	if has_rows {
		p.end(ui)
	}

	if e.passkey.credential_id != "" {
		passkey_card(ui, e)
	}

	if e.notes != "" {
		p.col(ui, "w-full shrink-0 gap-1.5")
		p.row(ui, "shrink-0 items-center gap-2")
		p.icon(ui, IC_FILE_TEXT, "size-3.5 shrink-0 text-muted-foreground")
		p.text(ui, "Notes", "text-[11] font-medium text-muted-foreground whitespace-nowrap")
		p.style(ui).shrink = 0
		p.end(ui)
		p.col(ui, "w-full shrink-0 px-4 py-3 rounded-xl bg-muted/50")
		p.text(ui, e.notes, "w-full text-sm text-foreground whitespace-normal")
		p.end(ui)
		p.end(ui)
	}

	if st.mode == .Account {
		sharing_card(ui, st, e)
	}

	// Timestamps
	p.row(ui, "w-full shrink-0 items-center gap-4 pt-1")
	stamp(ui, IC_CALENDAR, "Created", e.created)
	stamp(ui, IC_PENCIL, "Modified", e.modified)
	p.end(ui)

	// History
	if e.kind == .Login || len(e.history) > 0 {
		p.col(ui, "w-full shrink-0 gap-2 pt-2 border-t border-border")
		p.key(ui, "histhead")
		hidx := p.div(ui, "flex-row w-full shrink-0 items-center gap-2 h-8 px-2 -mx-2 rounded-md transition hover:bg-accent")
		p.focusable(ui)
		if p.activated(ui, hidx) {
			st.history = !st.history
		}
		p.icon(ui, st.history ? IC_CHEVRON_DOWN : IC_CHEVRON_RIGHT, "size-3.5 shrink-0 text-muted-foreground")
		p.icon(ui, IC_ROTATE_CCW, "size-3.5 shrink-0 text-muted-foreground")
		p.textf(ui, "flex-1 text-xs font-medium text-muted-foreground whitespace-nowrap", "Password history (%d)", len(e.history))
		p.end(ui)

		if st.history {
			if len(e.history) == 0 {
				p.text(ui, "This password has never been changed here.", "text-xs text-muted-foreground whitespace-nowrap")
			}
			for h, i in e.history {
				p.key(ui, fmt.tprintf("h%d", i))
				p.row(ui, "w-full shrink-0 items-center gap-3 h-8 px-2.5 rounded-md bg-muted")
				p.text(ui, when_text(h.when_), "w-[150] shrink-0 text-[11] text-muted-foreground whitespace-nowrap tabular-nums")
				p.text(ui, st.reveal ? h.password : masked(len(h.password)), "flex-1 text-xs font-mono truncate")
				copy_btn(ui, st, fmt.tprintf("hc%d", i), "previous password", h.password)
				p.end(ui)
			}
		}
		p.end(ui)
	}
}

passkey_card :: proc(ui: ^p.Ctx, e: ^Entry) {
	pk := &e.passkey
	p.col(ui, "w-full shrink-0 gap-3 p-4 rounded-xl border border-border")
	p.row(ui, "w-full shrink-0 items-center gap-2")
	p.icon(ui, IC_KEY_ROUND, "size-4 shrink-0 text-foreground")
	p.text(ui, "Passkey", "text-sm font-medium whitespace-nowrap")
	p.style(ui).shrink = 0
	p.spacer(ui)
	sc.badge(ui, pk.discoverable ? "discoverable" : "server-side", .Outline)
	p.end(ui)
	kv :: proc(ui: ^p.Ctx, k, v: string) {
		p.row(ui, "w-full shrink-0 items-center gap-3")
		p.text(ui, k, "w-[110] shrink-0 text-xs text-muted-foreground whitespace-nowrap")
		p.text(ui, v, "flex-1 text-xs font-mono truncate")
		p.end(ui)
	}
	kv(ui, "Site", pk.rp_name != "" ? fmt.tprintf("%s (%s)", pk.rp_name, pk.rp_id) : pk.rp_id)
	kv(ui, "Account", pk.user_name)
	kv(ui, "Credential", pk.credential_id)
	kv(ui, "Signatures", fmt.tprintf("%d", pk.counter))
	p.text(ui, "Stored end-to-end encrypted with the rest of the item. Signing in with it needs the browser integration, which is designed but not built: Linux has no platform passkey API, so the browser will ask the vault over the autofill socket.", "w-full text-[11] text-muted-foreground whitespace-normal")
	p.end(ui)
}

sharing_card :: proc(ui: ^p.Ctx, st: ^St, e: ^Entry) {
	a := st.acct
	if e.src < 0 || e.src >= len(a.sources) {
		return
	}
	src := &a.sources[e.src]
	vault_id := src.vault_id
	if o := origin_of(a, e.id); o != nil {
		vault_id = o.vault_id
	}
	shares := make([dynamic]^S_Row, context.temp_allocator)
	for &s in a.cache.shares {
		if s.revoked || s.vault_id != vault_id {
			continue
		}
		if s.item_id == e.id || s.item_id == "" {
			append(&shares, &s)
		}
	}
	if src.kind != .Own && len(shares) == 0 {
		return
	}
	p.col(ui, "w-full shrink-0 gap-2")
	p.row(ui, "shrink-0 items-center gap-2")
	p.icon(ui, IC_USERS, "size-3.5 shrink-0 text-muted-foreground")
	p.text(ui, "Who can open this", "text-[11] font-medium text-muted-foreground whitespace-nowrap")
	p.style(ui).shrink = 0
	p.end(ui)
	p.col(ui, "w-full shrink-0 gap-0 rounded-xl border border-border overflow-hidden")
	owner := src.owner
	p.row(ui, "w-full shrink-0 items-center gap-3 h-11 px-4")
	oi := ident_by_id(a, owner)
	avatar(ui, name_of(a, owner), oi != nil ? oi.color : "slate", "size-6", "text-[11]")
	p.text(ui, name_of(a, owner), "flex-1 text-sm truncate")
	p.text(ui, "owner", "text-xs text-muted-foreground whitespace-nowrap")
	p.style(ui).shrink = 0
	p.end(ui)
	for s, i in shares {
		p.key(ui, fmt.tprintf("share-%s", s.id))
		p.row(ui, "w-full shrink-0 items-center gap-3 h-11 px-4 border-t border-border")
		gi := ident_by_id(a, s.grantee)
		avatar(ui, name_of(a, s.grantee), gi != nil ? gi.color : "slate", "size-6", "text-[11]")
		p.col(ui, "flex-1 min-w-0 gap-0")
		p.text(ui, name_of(a, s.grantee), "text-sm truncate")
		how := s.item_id == "" ? "through the whole vault" : "this item only"
		verified := share_verify(a, s)
		p.textf(ui, "text-[11] text-muted-foreground truncate", "%s · %s · %s", how, s.role == "write" ? "can edit" : "read-only", verified ? "signature verified" : "UNVERIFIED")
		p.end(ui)
		if src.kind == .Own && s.item_id == e.id {
			p.key(ui, fmt.tprintf("revoke-%d", i))
			ridx := p.div(ui, "flex-row shrink-0 items-center gap-1.5 h-7 px-2.5 rounded-md border border-border transition hover:bg-destructive/10")
			p.focusable(ui)
			if p.activated(ui, ridx) {
				do_revoke(st, ui, s.id)
			}
			p.text(ui, "Revoke", "text-xs text-destructive whitespace-nowrap")
			p.style(ui).shrink = 0
			p.end(ui)
		}
		p.end(ui)
	}
	p.end(ui)
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

row_value :: proc(ui: ^p.Ctx, st: ^St, ic: p.Icon, label, value: string, secret: bool, copy_label: string, divider := false) {
	p.row(ui, p.concat(ui, "w-full shrink-0 items-center gap-3 min-h-[52] px-4 py-2", divider ? " border-t border-border" : ""))
	defer p.end(ui)

	p.icon(ui, ic, "size-4 shrink-0 text-muted-foreground")
	p.col(ui, "flex-1 min-w-0 gap-0.5")
	p.row(ui, "shrink-0 items-center gap-2")
	p.text(ui, label, "text-[11] text-muted-foreground whitespace-nowrap")
	p.style(ui).shrink = 0
	if secret && label == "Password" && value != "" {
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
	shown := value
	if value == "" {
		shown = "—"
	} else if secret && !st.reveal {
		shown = masked(len(value))
	}
	p.text(ui, shown, p.concat(ui, "w-full truncate ", secret ? "text-sm font-mono" : "text-sm"))
	p.end(ui)
	if secret && value != "" {
		p.key(ui, fmt.tprintf("reveal-%s", label))
		ridx := p.div(ui, "flex-row shrink-0 items-center justify-center size-8 rounded-md transition hover:bg-accent")
		p.focusable(ui)
		if p.activated(ui, ridx) {
			st.reveal = !st.reveal
		}
		p.icon(ui, st.reveal ? IC_EYE_OFF : IC_EYE, "size-3.5 shrink-0 text-muted-foreground")
		p.end(ui)
	}
	if copy_label != "" && value != "" {
		copy_btn(ui, st, fmt.tprintf("copy-%s", label), copy_label, value)
	}
}

copy_btn :: proc(ui: ^p.Ctx, st: ^St, key, label, value: string) {
	p.key(ui, key)
	idx := p.div(ui, "flex-row shrink-0 items-center justify-center size-8 rounded-md transition hover:bg-accent")
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

	p.row(ui, "w-full shrink-0 items-center gap-4 px-4 py-3 rounded-xl border border-border bg-card")
	defer p.end(ui)

	p.col(ui, "flex-1 min-w-0 gap-1")
	p.row(ui, "w-full shrink-0 items-center gap-2")
	p.icon(ui, IC_TIMER, "size-3.5 shrink-0 text-muted-foreground")
	p.text(ui, "One-time code", "text-[11] font-medium text-muted-foreground whitespace-nowrap")
	p.style(ui).shrink = 0
	p.textf(
		ui,
		"text-[10] text-muted-foreground whitespace-nowrap",
		"· TOTP %s, %d digits, %ds",
		TOTP_ALGO_NAME[e.totp_algo],
		e.totp_digits,
		e.totp_period,
	)
	p.style(ui).shrink = 0
	p.end(ui)
	if ok {
		// Grouped in the middle, the way every authenticator shows it.
		half := len(code) / 2
		p.text(ui, fmt.tprintf("%s %s", code[:half], code[half:]), "text-2xl font-mono font-semibold tracking-wide whitespace-nowrap")
	} else {
		p.text(ui, "invalid secret", "text-sm text-destructive whitespace-nowrap")
	}
	p.end(ui)
	p.col(ui, "shrink-0 items-end gap-1.5")
	p.textf(ui, p.concat(ui, "text-xs whitespace-nowrap tabular-nums ", left <= 5 ? "text-destructive" : "text-muted-foreground"), "%ds", left)
	p.progress(ui, frac, "w-[96] h-1.5 rounded-full")
	p.end(ui)
	if ok {
		copy_btn(ui, st, "totpcopy", "TOTP code", code)
	}
}

// ---------------------------------------------------------------------------
// Password health
// ---------------------------------------------------------------------------

health_pane :: proc(ui: ^p.Ctx, st: ^St) {
	p.col(ui, "flex-1 min-w-0 h-full overflow-auto")
	defer p.end(ui)
	p.col(ui, "w-full gap-5 px-8 py-6")
	defer p.end(ui)
	if !st.health_ok {
		health_refresh(st)
	}
	h := &st.health

	p.col(ui, "w-full shrink-0 gap-1")
	p.text(ui, "Password health", "text-xl font-semibold whitespace-nowrap")
	p.textf(ui, "text-xs text-muted-foreground whitespace-normal", "%d items checked on this device. Nothing here leaves it.", len(st.v.entries))
	p.end(ui)

	p.row(ui, "w-full shrink-0 items-stretch gap-3")
	stat :: proc(ui: ^p.Ctx, label: string, n: int, help: string, color: string) {
		p.col(ui, "flex-1 min-w-0 gap-1 p-4 rounded-xl border border-border")
		p.text(ui, label, "text-xs text-muted-foreground whitespace-nowrap")
		p.textf(ui, p.concat(ui, "text-2xl font-semibold tabular-nums whitespace-nowrap ", n > 0 ? color : "text-foreground"), "%d", n)
		p.text(ui, help, "w-full text-[11] text-muted-foreground whitespace-normal")
		p.end(ui)
	}
	stat(ui, "Weak", h.weak, "short, common, or word-plus-digits", "text-destructive")
	stat(ui, "Reused", h.reused, "the same password on more than one site", "text-amber-600")
	stat(ui, "Exposed", h.exposed, "readable by someone you revoked", "text-amber-600")
	if h.checked {
		stat(ui, "Breached", h.breached, "found in known breaches", "text-destructive")
	} else {
		p.col(ui, "flex-1 min-w-0 gap-1 p-4 rounded-xl border border-dashed border-border")
		p.text(ui, "Breached", "text-xs text-muted-foreground whitespace-nowrap")
		p.text(ui, "—", "text-2xl font-semibold text-muted-foreground whitespace-nowrap")
		p.text(ui, "not checked: see below", "w-full text-[11] text-muted-foreground whitespace-normal")
		p.end(ui)
	}
	p.end(ui)

	// The breach check: off until the person turns it on, and said plainly.
	p.col(ui, "w-full shrink-0 gap-3 p-4 rounded-xl border border-border bg-muted/30")
	p.row(ui, "w-full shrink-0 items-center gap-2")
	p.icon(ui, IC_GLOBE, "size-4 shrink-0 text-foreground")
	p.text(ui, "Check against known breaches", "flex-1 text-sm font-medium truncate")
	p.key(ui, "breach-toggle")
	tidx := p.div(ui, "flex-row shrink-0 items-center h-5 w-9 px-0.5 rounded-full transition")
	p.apply(ui, st.breach_on ? "bg-primary justify-end" : "bg-input justify-start", tidx)
	p.focusable(ui)
	if p.activated(ui, tidx) {
		st.breach_on = !st.breach_on
	}
	p.div(ui, "shrink-0 size-4 rounded-full bg-background shadow-sm")
	p.end(ui)
	p.end(ui)
	p.end(ui)
	p.text(ui, "Off by default. When you check, the vault sends Have I Been Pwned the first 5 hex digits of each password's SHA-1 -- a prefix hundreds of thousands of passwords share -- and compares the answers here. Your passwords, their full hashes and which site they belong to never leave this device. The service does learn that this address asked about those prefixes.", "w-full text-[11] text-muted-foreground whitespace-normal")
	p.row(ui, "w-full shrink-0 items-center gap-2")
	hbtn(ui, st, IC_SEARCH, "Check now", proc(st: ^St, ui: ^p.Ctx) {
		if st.breach_msg != "" {
			delete(st.breach_msg)
		}
		err := health_breach(&st.health, &st.v, hibp_fetch_curl)
		st.breach_msg = strings.clone(err != "" ? err : fmt.tprintf("Checked at %s", clock_text(now_unix())))
	}, !st.breach_on)
	if st.breach_msg != "" {
		p.text(ui, st.breach_msg, "text-xs text-muted-foreground truncate")
	}
	p.end(ui)
	p.end(ui)

	if len(h.findings) == 0 {
		p.row(ui, "w-full shrink-0 items-center gap-2 px-4 py-3 rounded-xl bg-emerald-500/10")
		p.icon(ui, IC_CIRCLE_CHECK, "size-4 shrink-0 text-emerald-600")
		p.text(ui, "Nothing to fix.", "text-sm text-emerald-700")
		p.end(ui)
		return
	}
	// One row per item, every issue it has, worst first.
	order := make([dynamic]int, context.temp_allocator)
	for f in h.findings {
		seen := false
		for o in order {
			if o == f.entry {
				seen = true
			}
		}
		if !seen {
			append(&order, f.entry)
		}
	}
	p.col(ui, "w-full shrink-0 gap-0 rounded-xl border border-border overflow-hidden")
	for ent, i in order {
		e := &st.v.entries[ent]
		p.key(ui, fmt.tprintf("finding-%s", e.id))
		idx := p.div(ui, p.concat(ui, "flex-row w-full shrink-0 items-start gap-3 px-4 py-3 transition hover:bg-accent/50", i > 0 ? " border-t border-border" : ""))
		if p.clickable(ui, idx) {
			id := strings.clone(e.id, context.temp_allocator)
			st.nav = {}
			refilter(st)
			select_id(st, id)
		}
		tile(ui, KIND_ICON[e.kind], src_color(st, e.src), "size-8", "size-4")
		p.col(ui, "flex-1 min-w-0 gap-1")
		p.row(ui, "w-full items-center gap-2")
		p.text(ui, e.title, "flex-1 text-sm font-medium truncate")
		for f, j in h.findings {
			if f.entry != ent {
				continue
			}
			cls := "bg-amber-500/15 text-amber-600"
			if f.issue == .Weak || f.issue == .Breached {
				cls = "bg-destructive/10 text-destructive"
			}
			if f.issue == .Old {
				cls = "bg-muted text-muted-foreground"
			}
			p.key(ui, fmt.tprintf("b%d", j))
			p.div(ui, p.concat(ui, "flex-col shrink-0 items-center justify-center h-5 px-2 rounded-full ", cls))
			p.text(ui, HEALTH_ISSUE[f.issue], "text-[10] font-semibold whitespace-nowrap")
			p.end(ui)
		}
		p.end(ui)
		for f, j in h.findings {
			if f.entry != ent {
				continue
			}
			p.key(ui, fmt.tprintf("d%d", j))
			p.text(ui, f.detail, "w-full text-[11] text-muted-foreground truncate")
		}
		p.end(ui)
		p.end(ui)
	}
	p.end(ui)
}

// ---------------------------------------------------------------------------
// Editor
// ---------------------------------------------------------------------------

editor :: proc(ui: ^p.Ctx, st: ^St) {
	p.col(ui, "w-full gap-4 px-8 py-6")
	defer p.end(ui)

	p.row(ui, "w-full shrink-0 items-center gap-3")
	tile(ui, KIND_ICON[st.ed_kind], st.ed_new ? src_color(st, st.ed_target) : src_color(st, current(st) != nil ? current(st).src : -1))
	p.text(ui, st.ed_new ? fmt.tprintf("New %s", strings.to_lower(KIND_LABEL[st.ed_kind], context.temp_allocator)) : "Edit item", "flex-1 text-lg font-semibold truncate")
	hbtn(ui, st, IC_X, "Cancel", proc(st: ^St, ui: ^p.Ctx) {cancel_edit(st)})
	pbtn(ui, IC_SAVE, "Save", "save", proc(st: ^St, ui: ^p.Ctx) {commit_edit(st, ui)}, st)
	p.end(ui)

	if st.ed_new {
		// The kind, as a segmented control.
		p.row(ui, "shrink-0 items-center gap-1 p-1 rounded-lg bg-muted")
		for k in Item_Kind {
			if k == .Passkey {
				continue // passkeys arrive by import or, later, from the browser
			}
			on := st.ed_kind == k
			p.key(ui, fmt.tprintf("kind-%v", k))
			idx := p.div(ui, "flex-row shrink-0 items-center gap-1.5 h-7 px-2.5 rounded-md transition")
			p.apply(ui, on ? "bg-background shadow-sm text-foreground" : "text-muted-foreground hover:text-foreground", idx)
			p.focusable(ui)
			if p.activated(ui, idx) && !on {
				st.ed_kind = k
				kv_bufs_for(st, k, nil)
			}
			p.icon(ui, KIND_ICON[k], "size-3.5 shrink-0")
			p.text(ui, KIND_LABEL[k], "text-xs whitespace-nowrap")
			p.style(ui).shrink = 0
			p.end(ui)
		}
		p.end(ui)
		if st.mode == .Account && st.ed_target >= 0 && st.ed_target < len(st.acct.sources) {
			s := &st.acct.sources[st.ed_target]
			p.row(ui, "w-full shrink-0 items-center gap-2")
			p.text(ui, "Saved in", "text-xs text-muted-foreground whitespace-nowrap")
			p.style(ui).shrink = 0
			p.key(ui, "target")
			tidx := p.div(ui, "flex-row shrink-0 items-center gap-2 h-8 px-3 rounded-md border border-border transition hover:bg-accent")
			p.focusable(ui)
			if p.activated(ui, tidx) {
				// Cycle through the vaults this device may write to.
				n := len(st.acct.sources)
				for step in 1 ..= n {
					c := (st.ed_target + step) % n
					if st.acct.sources[c].role != "read" && st.acct.sources[c].kind != .Shared_Items {
						st.ed_target = c
						break
					}
				}
			}
			p.div(ui, fmt.tprintf("shrink-0 size-2.5 rounded-sm bg-%s-500", src_color(st, st.ed_target)))
			p.end(ui)
			p.textf(ui, "text-xs font-medium whitespace-nowrap", "%s · %s", handle_of(st.acct, s.viewer), s.name)
			p.style(ui).shrink = 0
			p.icon(ui, IC_CHEVRON_DOWN, "size-3.5 shrink-0 text-muted-foreground")
			p.end(ui)
			p.end(ui)
		}
	}

	show :: proc(k: Item_Kind, f: Field) -> bool {
		switch f {
		case .Title, .Tags, .Notes:
			return true
		case .Username, .Password, .Url:
			return k == .Login || k == .Passkey || k == .Totp && f == .Username
		case .Totp:
			return k == .Login || k == .Totp
		}
		return false
	}

	for f in Field {
		if !show(st.ed_kind, f) {
			continue
		}
		if f == .Tags {
			// The kind's own fields go before the tags and notes.
			for &k, i in st.ed_kv {
				p.key(ui, fmt.tprintf("kvf%d", i))
				p.col(ui, "w-full shrink-0 gap-1.5")
				p.text(ui, k.label, "text-[11] font-medium text-muted-foreground whitespace-nowrap")
				p.row(ui, "w-full shrink-0 items-center gap-2")
				mask: rune = (k.secret && !st.reveal) ? MASK : 0
				_, sub, _ := vfield(ui, fmt.tprintf("kv-%s", k.label), &k.buf, "", k.secret ? "flex-1 h-9 text-sm font-mono" : "flex-1 h-9 text-sm", mask)
				if sub {
					commit_edit(st, ui)
				}
				p.end(ui)
				p.end(ui)
			}
		}
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
				p.concat(ui, "text-[10] whitespace-nowrap ", good ? "text-emerald-500" : "text-destructive"),
			)
			p.style(ui).shrink = 0
		}
		p.end(ui)

		p.row(ui, "w-full shrink-0 items-center gap-2")
		mask: rune = (secret && !st.reveal) ? MASK : 0
		if f == .Notes {
			// Notes is the one field that is prose, so it is palmy's
			// multi-line area rather than a tall single-line field. Enter puts
			// a newline in it; Ctrl S is still what saves, which is why the
			// area has no `submitted` to return.
			st.notes_id = varea(ui, "Notes", &st.ed[f], "flex-1 h-24 text-sm")
			p.end(ui)
			p.end(ui)
			continue
		}
		class := "flex-1 h-9 text-sm"
		if secret {
			class = "flex-1 h-9 text-sm font-mono"
		}
		_, sub, _ := vfield(ui, FIELD_LABEL[f], &st.ed[f], "", class, mask)
		if sub {
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
	idx := p.div(ui, "absolute inset-0 z-40 flex-col items-center justify-center bg-black/50")
	return idx
}

dialog :: proc(ui: ^p.Ctx, w: string) {
	p.col(ui, p.concat(ui, w, " shrink-0 gap-4 p-6 rounded-2xl border border-border bg-popover shadow-lg"))
}

generator_overlay :: proc(ui: ^p.Ctx, st: ^St) {
	scrim(ui)
	defer p.end(ui)

	dialog(ui, "w-[560]")
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

	dialog(ui, "w-[520]")
	defer p.end(ui)

	p.row(ui, "w-full shrink-0 items-center gap-2")
	p.icon(ui, IC_KEY, "size-4 shrink-0 text-foreground")
	p.text(ui, "Change the master password", "flex-1 text-base font-semibold truncate")
	p.end(ui)

	p.text(
		ui,
		st.mode == .Account \
		? "The account key is re-wrapped under the new password on every identity's keyset; your items are not re-encrypted, and the Secret Key stays the same. Other devices will need the new password at their next unlock." \
		: "The vault is re-encrypted under a new key from a new salt, written to a new file, and moved into place with one rename. If this is interrupted at any point, the vault you have now is still there and still opens with the password you have now.",
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
	pbtn(ui, IC_KEY, "Re-encrypt", "reencrypt", proc(st: ^St, ui: ^p.Ctx) {st.busy = .Rekeying}, st)
	p.end(ui)

	if st.busy == .Rekeying {
		p.text(ui, "Deriving the new key…", "text-xs text-muted-foreground whitespace-nowrap")
	}
}

delete_overlay :: proc(ui: ^p.Ctx, st: ^St) {
	scrim(ui)
	defer p.end(ui)

	e := current(st)
	dialog(ui, "w-[440]")
	defer p.end(ui)

	p.row(ui, "w-full shrink-0 items-center gap-2")
	p.icon(ui, IC_TRIANGLE_ALERT, "size-4 shrink-0 text-destructive")
	p.text(ui, "Delete this item?", "flex-1 text-base font-semibold truncate")
	p.end(ui)
	p.textf(
		ui,
		"w-full text-xs text-muted-foreground whitespace-normal",
		st.mode == .Account ? "%s, and its password history, will be removed from every device that syncs this vault, and from anyone it is shared with." : "%s, and its password history, will be removed from the vault. This cannot be undone.",
		e != nil ? e.title : "The item",
	)
	p.row(ui, "w-full shrink-0 items-center gap-2")
	p.spacer(ui)
	hbtn(ui, st, IC_X, "Keep (n)", proc(st: ^St, ui: ^p.Ctx) {st.confirm_del = false})
	p.key(ui, "really-delete")
	didx := p.div(ui, "flex-row shrink-0 items-center gap-1.5 h-8 px-3 rounded-md bg-destructive text-white transition hover:bg-destructive/90")
	p.focusable(ui)
	if p.activated(ui, didx) {
		delete_current(st, ui)
	}
	p.icon(ui, IC_TRASH, "size-3.5 shrink-0")
	p.text(ui, "Delete (y)", "text-xs font-medium whitespace-nowrap")
	p.style(ui).shrink = 0
	p.end(ui)
	p.end(ui)
}

share_overlay :: proc(ui: ^p.Ctx, st: ^St) {
	scrim(ui)
	defer p.end(ui)
	e := current(st)
	dialog(ui, "w-[500]")
	defer p.end(ui)

	p.row(ui, "w-full shrink-0 items-center gap-2")
	p.icon(ui, IC_SHARE, "size-4 shrink-0 text-foreground")
	p.textf(ui, "flex-1 text-base font-semibold truncate", "Share %s", e != nil ? e.title : "")
	p.end(ui)
	p.text(ui, "Another identity -- yours, or someone else's -- receives this one item, read-only. Its key is sealed to their public keys (X25519 and ML-KEM-768) and signed by this identity; the server carries it and cannot open it. You can revoke it later; what they have read by then, they may keep.", "w-full text-[11] text-muted-foreground whitespace-normal")
	p.col(ui, "w-full shrink-0 gap-1.5")
	p.text(ui, "Identity handle", "text-[11] font-medium text-muted-foreground whitespace-nowrap")
	_, sub, id := vfield(ui, "sharewith", &st.share_with, "bob, or alice-work", "w-full h-9 text-sm")
	if st.share_id == 0 {
		p.set_focus(ui, id)
	}
	st.share_id = id
	p.end(ui)
	if sub {
		do_share(st, ui)
	}
	// Your own identities, one click each.
	if st.mode == .Account {
		p.row(ui, "w-full shrink-0 items-center gap-2 flex-wrap")
		for &i in st.acct.cache.idents {
			if e != nil && e.src >= 0 && st.acct.sources[e.src].viewer == i.id {
				continue
			}
			p.key(ui, fmt.tprintf("pick-%s", i.handle))
			idx := p.div(ui, "flex-row shrink-0 items-center gap-1.5 h-7 pl-1 pr-2.5 rounded-full border border-border transition hover:bg-accent")
			p.focusable(ui)
			if p.activated(ui, idx) {
				set_buf(&st.share_with, i.handle)
			}
			avatar(ui, i.name, i.color)
			p.text(ui, i.handle, "text-xs whitespace-nowrap")
			p.style(ui).shrink = 0
			p.end(ui)
		}
		p.end(ui)
	}
	if st.share_err != "" {
		p.text(ui, st.share_err, "w-full text-xs text-destructive whitespace-normal")
	}
	p.row(ui, "w-full shrink-0 items-center gap-2")
	p.spacer(ui)
	hbtn(ui, st, IC_X, "Cancel", proc(st: ^St, ui: ^p.Ctx) {st.share_open = false})
	pbtn(ui, IC_SHARE, "Share read-only", "doshare", proc(st: ^St, ui: ^p.Ctx) {do_share(st, ui)}, st)
	p.end(ui)
}

import_overlay :: proc(ui: ^p.Ctx, st: ^St) {
	scrim(ui)
	defer p.end(ui)
	dialog(ui, "w-[540]")
	defer p.end(ui)
	r := &st.imp
	p.row(ui, "w-full shrink-0 items-center gap-2")
	p.icon(ui, IC_DOWNLOAD, "size-4 shrink-0 text-foreground")
	p.text(ui, "Import passwords", "flex-1 text-base font-semibold truncate")
	p.end(ui)
	p.row(ui, "w-full shrink-0 items-center gap-3 px-3 py-2.5 rounded-lg bg-muted")
	p.icon(ui, IC_FILE_TEXT, "size-4 shrink-0 text-muted-foreground")
	p.col(ui, "flex-1 min-w-0 gap-0")
	p.text(ui, short_path(st.imp_path), "text-sm truncate")
	fname := format_name(r.format)
	p.textf(ui, "text-[11] text-muted-foreground truncate", "%s", fname)
	p.end(ui)
	p.end(ui)
	if r.err != "" {
		p.row(ui, "w-full shrink-0 items-start gap-2 px-3 py-2 rounded-lg bg-destructive/10")
		p.icon(ui, IC_SHIELD_ALERT, "size-4 shrink-0 text-destructive")
		p.text(ui, r.err, "flex-1 text-xs text-destructive whitespace-normal")
		p.end(ui)
		if r.format == "kdbx" || r.format == "pvz" {
			p.text(ui, "A KeePass database or another vault needs its own password: import it with `vault import <file> --source-password-file <file>`.", "w-full text-[11] text-muted-foreground whitespace-normal")
		}
	} else {
		kinds: [Item_Kind]int
		for &e in r.entries {
			kinds[e.kind] += 1
		}
		p.row(ui, "w-full shrink-0 items-center gap-2 flex-wrap")
		for k in Item_Kind {
			if kinds[k] > 0 {
				p.key(ui, fmt.tprintf("ik-%v", k))
				name := kinds[k] == 1 ? KIND_LABEL[k] : KIND_PLURAL[k]
				sc.badge(ui, fmt.tprintf("%d %s", kinds[k], strings.to_lower(name, context.temp_allocator)), .Secondary)
			}
		}
		if r.skipped > 0 {
			sc.badge(ui, fmt.tprintf("%d skipped", r.skipped), .Outline)
		}
		p.end(ui)
		for w, i in r.warnings {
			if i >= 4 {
				break
			}
			p.key(ui, fmt.tprintf("w%d", i))
			p.text(ui, w, "w-full text-[11] text-muted-foreground truncate")
		}
		if st.mode == .Account && st.imp_target >= 0 && st.imp_target < len(st.acct.sources) {
			s := &st.acct.sources[st.imp_target]
			p.row(ui, "w-full shrink-0 items-center gap-2")
			p.text(ui, "Into", "text-xs text-muted-foreground whitespace-nowrap")
			p.style(ui).shrink = 0
			p.key(ui, "imptarget")
			tidx := p.div(ui, "flex-row shrink-0 items-center gap-2 h-8 px-3 rounded-md border border-border transition hover:bg-accent")
			p.focusable(ui)
			if p.activated(ui, tidx) {
				n := len(st.acct.sources)
				for step in 1 ..= n {
					c := (st.imp_target + step) % n
					if st.acct.sources[c].role != "read" && st.acct.sources[c].kind != .Shared_Items {
						st.imp_target = c
						break
					}
				}
			}
			p.div(ui, fmt.tprintf("shrink-0 size-2.5 rounded-sm bg-%s-500", src_color(st, st.imp_target)))
			p.end(ui)
			p.textf(ui, "text-xs font-medium whitespace-nowrap", "%s · %s", handle_of(st.acct, s.viewer), s.name)
			p.style(ui).shrink = 0
			p.end(ui)
			p.end(ui)
		}
		p.text(ui, "Each becomes a new item, encrypted on this device before anything is saved. The file you chose is not changed; delete it once you are done, because it holds every password in the clear.", "w-full text-[11] text-muted-foreground whitespace-normal")
	}
	p.row(ui, "w-full shrink-0 items-center gap-2")
	p.spacer(ui)
	hbtn(ui, st, IC_X, "Cancel", proc(st: ^St, ui: ^p.Ctx) {
		import_result_free(&st.imp)
		st.imp_open = false
	})
	if r.err == "" {
		pbtn(ui, IC_DOWNLOAD, fmt.tprintf("Import %d items", len(r.entries)), "doimport", proc(st: ^St, ui: ^p.Ctx) {finish_import(st, ui)}, st)
	}
	p.end(ui)
}

format_name :: proc(f: string) -> string {
	switch f {
	case "bitwarden-json":
		return "Bitwarden (JSON)"
	case "bitwarden-csv":
		return "Bitwarden (CSV)"
	case "1pux":
		return "1Password (1PUX)"
	case "kdbx":
		return "KeePass (KDBX 4)"
	case "chrome":
		return "Chrome / Chromium (CSV)"
	case "firefox":
		return "Firefox (CSV)"
	case "pvz":
		return "palmy vault"
	}
	return "unrecognised"
}

// autofill_overlay is where the browser's requests reach a person: pairing
// (compare the code), filling (this login, on this site, for this identity),
// and saving a login the browser saw.
autofill_overlay :: proc(ui: ^p.Ctx, st: ^St) {
	pr := &st.af.prompt
	scrim(ui)
	defer p.end(ui)
	dialog(ui, "w-[500]")
	defer p.end(ui)

	p.row(ui, "w-full shrink-0 items-center gap-3")
	tile(ui, pr.kind == .Pair ? IC_LINK : IC_GLOBE, "blue", "size-10", "size-5")
	p.col(ui, "flex-1 min-w-0 gap-0.5")
	switch pr.kind {
	case .None:
	case .Pair:
		p.textf(ui, "text-base font-semibold truncate", "Let “%s” use autofill?", pr.client != "" ? pr.client : "a program")
	case .Fill:
		p.textf(ui, "text-base font-semibold truncate", "Fill %s?", pr.title)
	case .Save:
		p.text(ui, "Save this login?", "text-base font-semibold truncate")
	case .Update:
		p.textf(ui, "text-base font-semibold truncate", "Update the password of %s?", pr.title)
	}
	p.textf(ui, "text-[11] text-muted-foreground truncate", "%s · pid %d", pr.exe, pr.pid)
	p.end(ui)
	p.end(ui)

	switch pr.kind {
	case .None:
	case .Pair:
		p.text(ui, "A program running as you wants to ask this vault for logins. Pair only if it shows the same code:", "w-full text-xs text-muted-foreground whitespace-normal")
		p.row(ui, "w-full shrink-0 items-center justify-center h-16 rounded-xl bg-muted")
		p.text(ui, pr.code, "text-3xl font-mono font-semibold tracking-widest whitespace-nowrap")
		p.end(ui)
		p.text(ui, "Paired programs still ask before every fill, and see only titles and usernames until you allow one.", "w-full text-[11] text-muted-foreground whitespace-normal")
	case .Fill, .Save, .Update:
		p.col(ui, "w-full shrink-0 gap-0 rounded-xl border border-border overflow-hidden")
		kv :: proc(ui: ^p.Ctx, k, v: string, first: bool) {
			p.row(ui, p.concat(ui, "w-full shrink-0 items-center gap-3 h-10 px-4", first ? "" : " border-t border-border"))
			p.text(ui, k, "w-[90] shrink-0 text-xs text-muted-foreground whitespace-nowrap")
			p.text(ui, v, "flex-1 text-sm truncate")
			p.end(ui)
		}
		kv(ui, "Site", pr.origin, true)
		kv(ui, "Username", pr.username != "" ? pr.username : "—", false)
		if st.mode == .Account {
			kv(ui, "Identity", pr.identity, false)
		}
		p.end(ui)
		if pr.kind == .Update {
			p.text(ui, "The browser saw a new password submitted on this site for this login. The old one stays in the item's history.", "w-full text-[11] text-muted-foreground whitespace-normal")
		}
		if pr.kind == .Fill {
			p.text(ui, "The browser will type the username and password into this page's focused form. It has named the page's top-level origin; the vault only offers logins saved for it.", "w-full text-[11] text-muted-foreground whitespace-normal")
		}
	}

	p.row(ui, "w-full shrink-0 items-center gap-2")
	p.spacer(ui)
	hbtn(ui, st, IC_X, pr.kind == .Save || pr.kind == .Update ? "Not now" : "Deny", proc(st: ^St, ui: ^p.Ctx) {af_decide(&st.af, &st.bk, .Deny)})
	if pr.kind == .Fill {
		hbtn(ui, st, IC_CHECK, "Always on this site", proc(st: ^St, ui: ^p.Ctx) {af_decide(&st.af, &st.bk, .Always)})
	}
	label := "Allow once"
	if pr.kind == .Pair {
		label = "Pair"
	} else if pr.kind == .Save {
		label = "Save"
	} else if pr.kind == .Update {
		label = "Update"
	}
	pbtn(ui, IC_CHECK, label, "afallow", proc(st: ^St, ui: ^p.Ctx) {
		saving := st.af.prompt.kind == .Save || st.af.prompt.kind == .Update
		af_decide(&st.af, &st.bk, .Once)
		// a login saved or updated from the browser goes to the other devices now
		if saving && st.mode == .Account {st.busy = .Syncing}
	}, st)
	p.end(ui)
}

// ---------------------------------------------------------------------------
// Footer and toast
// ---------------------------------------------------------------------------

footer :: proc(ui: ^p.Ctx, st: ^St) {
	p.row(ui, "w-full h-[34] shrink-0 items-center gap-3 px-4 border-t border-border bg-background")
	defer p.end(ui)

	hint(ui, "Ctrl C", "copy password")
	hint(ui, "Ctrl T", "copy code")
	hint(ui, "Ctrl R", "reveal")
	hint(ui, "Ctrl N", "new")
	hint(ui, "Ctrl I", "import")
	hint(ui, "Ctrl L", "lock")
	p.spacer(ui)
	p.textf(
		ui,
		"text-[10] text-muted-foreground whitespace-nowrap",
		"copied secrets clear after %.0fs · locks after %.0fs idle%s",
		st.clip_limit,
		st.idle_limit,
		st.af.running ? " · autofill on" : "",
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
	idx := p.div(ui, "absolute z-50 flex-row items-center gap-2 h-9 px-3.5 rounded-lg border border-border bg-popover shadow-md")
	s := p.style(ui, idx)
	s.inset[p.LEFT] = p.px(16)
	s.inset[p.BOTTOM] = p.px(48)
	p.icon(ui, IC_CIRCLE_CHECK, "size-3.5 shrink-0 text-emerald-500")
	p.text(ui, st.toast, "text-xs whitespace-nowrap")
	p.style(ui).shrink = 0
	p.end(ui)
}
