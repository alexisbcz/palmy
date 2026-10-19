package main

import "core:fmt"
import "core:strings"
import ck "../cloudkit"
import p "palmy:."
import sc "shadcn:."

page_heading :: proc(st: ^St) -> string {
	switch st.step {
	case .Welcome:
		return tr("Welcome to Palmframe")
	case .Account:
		return tr("Use Palmframe with an account?")
	case .Sign_In:
		if st.signed_in {
			return tr("You are signed in")
		}
		return st.auth_tab == .Create ? tr("Create your Palmframe account") : tr("Sign in to your account")
	case .Identities:
		return tr("Your identities")
	case .Sync:
		return tr("What each identity keeps in sync")
	case .Passwords:
		if st.vault_done && st.secret != "" {
			return tr("Your Emergency Kit")
		}
		return tr("Your password vault")
	case .Setup:
		return tr("Setting up this computer")
	case .Import:
		return tr("Bring your things from elsewhere")
	case .Tour:
		return tr("Three things worth knowing")
	case .Done:
	}
	return ""
}

page_subtitle :: proc(st: ^St) -> string {
	switch st.step {
	case .Welcome:
		return tr("A few choices, each one skippable. Nothing is set up until you say so.")
	case .Account:
		return tr("Everything on this computer works without one. An account adds identities, and keeps each of them in sync across your devices.")
	case .Sign_In:
		if st.signed_in {
			return ""
		}
		return tr("Your email is how you sign in and how you get back in if you forget the password. Use an address outside Palmframe.")
	case .Identities:
		return tr("One account, several selves: personal, work, public, a project. Each has its own address, its own data and its own colour, and nothing passes between them unless you carry it.")
	case .Sync:
		return tr("Choose per identity. Each one syncs on its own session, so what one identity holds is never visible to another.")
	case .Passwords:
		if st.vault_done && st.secret != "" {
			return tr("This is the only copy of your Secret Key outside this computer. Without it and your master password, nobody can open your vault: not Palmframe, and not you on a new computer.")
		}
		return tr("Passwords are encrypted on this computer before they leave it. Two things unlock them: a master password you remember, and a Secret Key this computer keeps.")
	case .Setup:
		if st.setup_ran {
			return tr("Each service is set up by its own program, for one identity at a time.")
		}
		return tr("Here is everything that will happen. Nothing has been set up yet.")
	case .Import:
		return tr("Moving mail, contacts, calendars and files from Google or Microsoft is coming. When it does, everything will go into the one identity you choose.")
	case .Tour:
		return ""
	case .Done:
	}
	return ""
}

page :: proc(st: ^St, ui: ^p.Ctx) {
	switch st.step {
	case .Welcome:
		page_welcome(st, ui)
	case .Account:
		page_account(st, ui)
	case .Sign_In:
		page_sign_in(st, ui)
	case .Identities:
		page_identities(st, ui)
	case .Sync:
		page_sync(st, ui)
	case .Passwords:
		page_passwords(st, ui)
	case .Setup:
		page_setup(st, ui)
	case .Import:
		page_import(st, ui)
	case .Tour:
		page_tour(st, ui)
	case .Done:
		page_done(st, ui)
	}
}

// focus_first_focusable gives the page's first control the keyboard when a
// page opens, so Tab is never needed to start.
focus_here :: proc(st: ^St, ui: ^p.Ctx, idx: int) {
	if st.want_focus {
		p.set_focus(ui, p.node_id(ui, idx))
		st.want_focus = false
		p.redraw(ui)
	}
}

section_title :: proc(ui: ^p.Ctx, s: string) {
	txt(ui, s, "text-sm font-medium text-foreground")
}

// ---------------------------------------------------------------------------
// 1. Welcome: language and appearance
// ---------------------------------------------------------------------------

page_welcome :: proc(st: ^St, ui: ^p.Ctx) {
	p.row(ui, "w-full max-w-[960] items-start gap-10")
	defer p.end(ui)

	p.col(ui, "flex-1 gap-3 min-w-0")
	section_title(ui, tr("Language"))
	for l, i in LANGUAGES {
		p.key(ui, l.code)
		chosen := i == st.lang_i
		row := p.row(ui, "w-full items-center gap-3 px-4 py-2.5 rounded-lg border cursor-pointer")
		p.apply(ui, chosen ? "border-foreground/50 bg-accent/60" : "border-border bg-card/60 hover:bg-muted")
		p.focusable(ui, row)
		if chosen {
			focus_here(st, ui, row)
		}
		if p.focused(ui, row) {
			p.apply(ui, "ring-3 ring-ring/50")
		}
		if p.clickable(ui, row) || (p.focused(ui, row) && p.key_pressed(ui, p.KEY_SPACE, false)) {
			pick_language(st, i)
		}
		p.col(ui, "flex-1 min-w-0")
		txt(ui, l.native, "text-sm font-semibold text-foreground")
		txt(ui, language_english(i), "text-xs text-muted-foreground")
		p.end(ui)
		if chosen {
			p.icon(ui, WI_CHECK, "size-4 text-foreground")
		}
		p.end(ui)
	}
	p.end(ui)

	p.col(ui, "w-[360] gap-3 shrink-0")
	section_title(ui, tr("Appearance"))
	p.row(ui, "w-full gap-3")
	for dark in ([?]bool{false, true}) {
		p.key(ui, dark ? "dark" : "light")
		chosen := st.dark == dark
		card := p.col(ui, "flex-1 gap-3 p-3 rounded-xl border cursor-pointer")
		p.apply(ui, chosen ? "border-foreground/60 bg-accent/60" : "border-border bg-card/60 hover:bg-muted")
		p.focusable(ui, card)
		if p.focused(ui, card) {
			p.apply(ui, "ring-3 ring-ring/50")
		}
		if p.clickable(ui, card) || (p.focused(ui, card) && p.key_pressed(ui, p.KEY_SPACE, false)) {
			if st.dark != dark {
				st.dark = dark
				register_theme(dark)
			}
		}
		// A miniature window in that theme, drawn in fixed colours so it shows
		// the other theme truthfully whatever this one is.
		p.col(ui, dark ? "w-full h-[92] rounded-lg p-2 gap-1.5 bg-[#0a0a0a] border border-[#2e2e32]" : "w-full h-[92] rounded-lg p-2 gap-1.5 bg-white border border-[#e4e4e7]")
		p.row(ui, "w-full h-[3] gap-0")
		p.div(ui, "flex-1 h-full bg-[#2dd4bf]")
		p.end(ui)
		p.div(ui, "flex-1 h-full bg-[#60a5fa]")
		p.end(ui)
		p.end(ui)
		p.div(ui, dark ? "w-3/5 h-2 rounded-sm bg-[#3f3f46]" : "w-3/5 h-2 rounded-sm bg-[#d4d4d8]")
		p.end(ui)
		p.div(ui, dark ? "w-4/5 h-2 rounded-sm bg-[#27272a]" : "w-4/5 h-2 rounded-sm bg-[#e4e4e7]")
		p.end(ui)
		p.div(ui, dark ? "w-2/5 h-2 rounded-sm bg-[#27272a]" : "w-2/5 h-2 rounded-sm bg-[#e4e4e7]")
		p.end(ui)
		p.end(ui)
		p.row(ui, "items-center gap-2")
		p.icon(ui, dark ? WI_MOON : WI_SUN, "size-4 text-foreground")
		txt(ui, dark ? tr("Dark") : tr("Light"), "flex-1 text-sm font-medium text-foreground")
		if chosen {
			p.icon(ui, WI_CHECK, "size-4 text-foreground")
		}
		p.end(ui)
		p.end(ui)
	}
	p.end(ui)
	txt(ui, tr("Applies to this window now, and to every app from your next login."), "text-xs text-muted-foreground")
	p.end(ui)
}

language_english :: proc(i: int) -> string {
	switch LANGUAGES[i].code {
	case "en_US":
		return tr("English")
	case "fr_FR":
		return tr("French")
	case "de_DE":
		return tr("German")
	case "es_ES":
		return tr("Spanish")
	case "ar":
		return tr("Arabic")
	case "ja_JP":
		return tr("Japanese")
	}
	return LANGUAGES[i].english
}

// ---------------------------------------------------------------------------
// 2. Account or local
// ---------------------------------------------------------------------------

page_account :: proc(st: ^St, ui: ^p.Ctx) {
	p.col(ui, "w-full max-w-[720] gap-3")
	defer p.end(ui)
	n := p.node_count(ui)
	if choice_card(ui, st, WI_CLOUD, tr("Use an account"), tr("Create one or sign in. Choose identities, and what each keeps in sync: mail, files, calendars, notes, passwords, chat."), st.choice == .Account) {
		st.choice = .Account
	}
	if st.choice != .Local {
		focus_here(st, ui, n)
	}
	n2 := p.node_count(ui)
	if choice_card(ui, st, WI_LAPTOP, tr("Only on this computer"), tr("Nothing leaves this computer. Every app works, and you can add an account later from Settings."), st.choice == .Local) {
		st.choice = .Local
	}
	if st.choice == .Local {
		focus_here(st, ui, n2)
	}
	p.row(ui, "w-full items-start gap-2 pt-3")
	p.icon(ui, WI_INFO, "size-4 mt-px text-muted-foreground shrink-0")
	txt(ui, tr("Either way, your files, mail and notes live on this computer first and work offline. An account is where your devices meet, not where your things are kept instead."), "flex-1 text-xs text-muted-foreground")
	p.end(ui)
}

// ---------------------------------------------------------------------------
// 3. Create the account, or sign in
// ---------------------------------------------------------------------------

page_sign_in :: proc(st: ^St, ui: ^p.Ctx) {
	p.col(ui, "w-full max-w-[560] gap-5")
	defer p.end(ui)

	if st.signed_in {
		card := p.row(ui, "w-full items-center gap-4 p-5 rounded-xl border border-border bg-card/60")
		p.div(ui, "size-10 rounded-full bg-muted items-center justify-center shrink-0")
		p.icon(ui, WI_USER, "size-5 text-foreground")
		p.end(ui)
		p.col(ui, "flex-1 gap-0.5 min-w-0")
		txt(ui, st.email, "text-base font-semibold text-foreground")
		txt(ui, trf("On %s", server_label(st)), "text-xs text-muted-foreground")
		p.end(ui)
		if button(ui, st, tr("Use another account"), nil, .Outline, size = .SM) {
			if st.c != nil {
				ck.sign_out(st.c)
			}
			for len(st.plans) > 0 {
				pop(&st.plans)
			}
			refresh_account(st)
			st.want_focus = true
		}
		p.end(ui)
		_ = card
		return
	}

	// The two ways in, as tabs.
	p.row(ui, "w-full p-1 gap-1 rounded-lg bg-muted")
	for tab in Auth_Tab {
		p.key(ui, fmt.tprintf("tab-%v", tab))
		on := st.auth_tab == tab
		t := p.row(ui, "flex-1 items-center justify-center py-1.5 rounded-md cursor-pointer")
		p.apply(ui, on ? "bg-background shadow-sm" : "hover:bg-background/50")
		p.focusable(ui, t)
		if p.focused(ui, t) {
			p.apply(ui, "ring-3 ring-ring/50")
		}
		if p.clickable(ui, t) || (p.focused(ui, t) && p.key_pressed(ui, p.KEY_SPACE, false)) {
			if st.auth_tab != tab {
				st.auth_tab = tab
				st.tried = false
				clear_msg(st)
			}
		}
		text(ui, tab == .Create ? tr("Create account") : tr("Sign in"), on ? "text-sm font-medium text-foreground" : "text-sm text-muted-foreground")
		p.end(ui)
	}
	p.end(ui)

	prob := st.tried ? auth_problem(st) : ""
	disabled := busy(st)
	if st.auth_tab == .Create {
		field(ui, st, &st.name_buf, tr("Your name"), tr("Camille Roux"), prob == N("Enter your name.") ? tr(prob) : "", tr("Your first identity is named after you. You can change it on the next page."), focus_first = true, disabled = disabled)
	}
	email_hint := tr("Your recovery address. Mail at Palmframe addresses comes later, per identity.")
	if strings.has_suffix(strings.trim_space(string(st.email_buf[:])), fmt.tprintf("@%s", st.domain)) {
		email_hint = tr("This is a Palmframe address. If you lose that identity, you lose your way back in: an outside address is safer.")
	}
	field(ui, st, &st.email_buf, tr("Email"), "camille@example.org", prob == N("Enter a valid email address.") ? tr(prob) : "", email_hint, focus_first = st.auth_tab == .Sign_In, disabled = disabled)
	pw_prob := ""
	if prob == N("The password needs at least 8 characters.") {
		pw_prob = tr(prob)
	}
	field(ui, st, &st.pw_buf, tr("Password"), "", pw_prob, st.auth_tab == .Create ? tr("At least 8 characters.") : "", secret = true, disabled = disabled)
	if st.auth_tab == .Create {
		field(ui, st, &st.pw2_buf, tr("Confirm password"), "", prob == N("The passwords do not match.") ? tr(prob) : "", secret = true, disabled = disabled)
	}

	// Where the account lives.
	p.col(ui, "w-full gap-2 pt-2")
	p.row(ui, "w-full items-center gap-2")
	p.icon(ui, WI_SERVER, "size-4 text-muted-foreground shrink-0")
	text(ui, tr("Server"), "text-xs text-muted-foreground")
	text(ui, server_label(st), "flex-1 min-w-0 text-xs font-mono text-foreground truncate")
	if !st.url_open {
		if button(ui, st, tr("Change"), nil, .Ghost, size = .SM, disabled = disabled) {
			st.url_open = true
		}
	}
	p.end(ui)
	if st.url_open {
		p.row(ui, "w-full items-end gap-2")
		p.col(ui, "flex-1 min-w-0")
		field(ui, st, &st.url_buf, "", "https://cloud.example.org", hint = tr("The address of a Palmframe server. Ask whoever runs yours."), mono = true)
		p.end(ui)
		if button(ui, st, tr("Use this server"), nil, .Outline, size = .SM) {
			use_server(st)
		}
		p.end(ui)
	}
	p.end(ui)
}

server_label :: proc(st: ^St) -> string {
	if st.c != nil {
		return st.c.url_text
	}
	return string(st.url_buf[:])
}

use_server :: proc(st: ^St) {
	url := strings.trim_space(string(st.url_buf[:]))
	if st.opts.fixture {
		st.url_open = false
		return
	}
	if e := open_cloud(st, strings.clone(url, context.temp_allocator)); !ck.ok(e) {
		say(st, err_text(e), true)
		return
	}
	// Remembered for every app: cloudkit reads config.json in its store.
	write_text(fmt.tprintf("%s/config.json", st.c.dir), fmt.tprintf("{{\"url\":%s,\"anon_key\":%s}}\n", ck.quote(st.c.url_text), ck.quote(st.c.anon_key)), private = true)
	st.url_open = false
	say(st, trf("Using %s.", st.c.url_text))
}

// ---------------------------------------------------------------------------
// 4. Identities
// ---------------------------------------------------------------------------

kind_label :: proc(k: int) -> string {
	switch KINDS[k] {
	case "personal":
		return tr("Personal")
	case "work":
		return tr("Work")
	case "public":
		return tr("Public")
	case "project":
		return tr("Project")
	}
	return KINDS[k]
}

kind_hint :: proc(k: int) -> string {
	switch KINDS[k] {
	case "personal":
		return tr("Family, friends, your own things.")
	case "work":
		return tr("Your job. Quiet outside working hours.")
	case "public":
		return tr("Sign-ups, shopping, newsletters. A daily digest.")
	case "project":
		return tr("A side project or a company of your own.")
	}
	return ""
}

page_identities :: proc(st: ^St, ui: ^p.Ctx) {
	p.col(ui, "w-full max-w-[900] gap-3")
	defer p.end(ui)
	disabled := busy(st)
	remove := -1
	if !disabled {
		for k in ui.input.keys {
			if (k.sym == 'n' || k.sym == 'N') && .Ctrl in k.mods && len(st.plans) < 6 {
				add_identity_row(st)
			}
		}
	}
	if st.focus_plan < 0 || st.focus_plan >= len(st.plans) || st.plans[st.focus_plan].existing {
		st.focus_plan = -1
		for &q, j in st.plans {
			if !q.existing {
				st.focus_plan = j
				break
			}
		}
	}
	for &pl, i in st.plans {
		p.key(ui, fmt.tprintf("plan-%d", i))
		if pl.existing {
			existing_card(st, ui, &pl)
			continue
		}
		card := p.col(ui, "w-full gap-4 p-5 rounded-xl border bg-card/60")
		p.apply(ui, pl.err != "" ? "border-destructive/60" : "border-border")
		{
			// Name, handle, address.
			p.row(ui, "w-full items-start gap-4")
			monogram_box(ui, plan_mono(st, &pl), pl.color, "size-10 mt-7", "text-base")
			p.col(ui, "flex-1 min-w-0")
			name_prob := st.tried && plan_name(&pl) == "" ? tr("Every identity needs a name.") : ""
			if field(ui, st, &pl.name, tr("Name"), tr("Camille at Northwind"), name_prob, focus_first = i == st.focus_plan, disabled = disabled) {
				if !pl.handle_touched {
					clear(&pl.handle)
					h := handle_from(plan_name(&pl))
					append(&pl.handle, ..transmute([]u8)h)
				}
			}
			p.end(ui)
			p.col(ui, "flex-1 min-w-0")
			hp := handle_problem(plan_handle(&pl))
			hprob := ""
			if pl.err != "" {
				hprob = pl.err
			} else if hp != "" && (st.tried || pl.handle_touched) && len(pl.handle) > 0 {
				hprob = tr(hp)
			} else if hp != "" && st.tried {
				hprob = tr(hp)
			}
			addr := len(pl.handle) > 0 ? fmt.tprintf("%s@%s", plan_handle(&pl), st.domain) : fmt.tprintf("…@%s", st.domain)
			if field(ui, st, &pl.handle, tr("Handle"), "camille.northwind", hprob, trf("Mail address: %s. Permanent.", addr), disabled = disabled, mono = true) {
				pl.handle_touched = true
				lower_in_place(&pl.handle)
				delete(pl.err)
				pl.err = ""
			}
			p.end(ui)
			if len(st.plans) > 1 || usable_count(st) > 0 {
				p.col(ui, "pt-7")
				if button(ui, st, "", WI_X, .Ghost, size = .Icon, disabled = disabled) {
					remove = i
				}
				p.end(ui)
			}
			p.end(ui)

			// Kind and colour.
			p.row(ui, "w-full items-center gap-6")
			p.row(ui, "p-1 gap-1 rounded-lg bg-muted")
			for k in 0 ..< len(KINDS) {
				p.key(ui, fmt.tprintf("kind-%d", k))
				on := pl.kind == k
				t := p.row(ui, "items-center px-3 py-1 rounded-md cursor-pointer")
				p.apply(ui, on ? "bg-background shadow-sm" : "hover:bg-background/50")
				if !disabled {
					p.focusable(ui, t)
				}
				if p.focused(ui, t) {
					p.apply(ui, "ring-3 ring-ring/50")
				}
				if !disabled && (p.clickable(ui, t) || (p.focused(ui, t) && p.key_pressed(ui, p.KEY_SPACE, false))) {
					if pl.kind != k {
						pl.kind = k
						pl.services = kind_default_services(KINDS[k])
					}
				}
				text(ui, kind_label(k), on ? "text-xs font-medium text-foreground" : "text-xs text-muted-foreground")
				p.end(ui)
			}
			p.end(ui)
			txt(ui, kind_hint(pl.kind), "flex-1 min-w-0 text-xs text-muted-foreground")
			p.row(ui, "items-center gap-1.5")
			for h, c in PALETTE {
				p.key(ui, fmt.tprintf("hue-%d", c))
				on := pl.color == c
				sw := p.div(ui, fmt.tprintf("size-6 rounded-full items-center justify-center cursor-pointer %s", id_class("bg", c)))
				if on {
					p.apply(ui, "ring-2 ring-foreground/70")
				}
				if !disabled {
					p.focusable(ui, sw)
				}
				if p.focused(ui, sw) {
					p.apply(ui, "ring-3 ring-ring/60")
				}
				if !disabled && (p.clickable(ui, sw) || (p.focused(ui, sw) && p.key_pressed(ui, p.KEY_SPACE, false))) {
					pl.color = c
				}
				if on {
					p.icon(ui, WI_CHECK, "size-3.5 text-white")
				}
				p.end(ui)
				_ = h
			}
			p.end(ui)
			p.end(ui)
		}
		p.end(ui)
		_ = card
	}
	if remove >= 0 {
		remove_plan(st, remove)
	}

	if len(st.plans) < 6 {
		p.row(ui, "w-full items-center gap-3 pt-1")
		if button(ui, st, tr("Add an identity"), WI_PLUS, .Outline, disabled = disabled) {
			add_identity_row(st)
		}
		p.row(ui, "items-center gap-1 dir-ltr")
		sc.kbd(ui, "Ctrl")
		text(ui, "+", "text-xs text-muted-foreground")
		sc.kbd(ui, "N")
		p.end(ui)
		txt(ui, tr("Handles are permanent, because each is a mail address. Names and colours can change later."), "flex-1 min-w-0 text-xs text-muted-foreground")
		p.end(ui)
	}
}

// add_identity_row adds a row of the first kind not yet used (work, then
// project, public, personal) and gives its name field the keyboard.
add_identity_row :: proc(st: ^St) {
	kind := 1
	has := [4]bool{}
	for &q in st.plans {
		has[q.kind] = true
	}
	for k in ([?]int{1, 3, 2, 0}) {
		if !has[k] {
			kind = k
			break
		}
	}
	add_plan(st, kind)
	st.focus_plan = len(st.plans) - 1
	st.want_focus = true
}

lower_in_place :: proc(buf: ^[dynamic]u8) {
	for &b in buf {
		if b >= 'A' && b <= 'Z' {
			b += 'a' - 'A'
		}
	}
}

existing_card :: proc(st: ^St, ui: ^p.Ctx, pl: ^Plan) {
	p.row(ui, "w-full items-center gap-4 p-4 rounded-xl border border-border bg-card/60")
	monogram_box(ui, plan_mono(st, pl), pl.color, "size-10", "text-base")
	p.col(ui, "flex-1 gap-0.5 min-w-0")
	txt(ui, plan_name(pl), "text-sm font-semibold text-foreground")
	txt(ui, fmt.tprintf("%s@%s", plan_handle(pl), st.domain), "text-xs font-mono text-muted-foreground")
	p.end(ui)
	sc.badge(ui, kind_label(pl.kind), .Secondary)
	p.row(ui, "items-center gap-1.5")
	p.icon(ui, WI_CIRCLE_CHECK, "size-4 text-good")
	text(ui, tr("On your account"), "text-xs text-muted-foreground whitespace-nowrap")
	p.end(ui)
	p.end(ui)
}

// ---------------------------------------------------------------------------
// 5. Sync, per identity
// ---------------------------------------------------------------------------

service_icon :: proc(s: Service) -> p.Icon {
	switch s {
	case .Mail:
		return WI_MAIL
	case .Drive:
		return WI_HARD_DRIVE
	case .Calendar:
		return WI_CALENDAR
	case .Notes:
		return WI_NOTEBOOK_PEN
	case .Passwords:
		return WI_KEY_ROUND
	case .Chat:
		return WI_MESSAGE_SQUARE
	}
	return WI_INFO
}

service_label :: proc(s: Service) -> string {
	switch s {
	case .Mail:
		return tr("Mail")
	case .Drive:
		return tr("Drive")
	case .Calendar:
		return tr("Calendar & contacts")
	case .Notes:
		return tr("Notes")
	case .Passwords:
		return tr("Passwords")
	case .Chat:
		return tr("Chat")
	}
	return ""
}

service_detail :: proc(st: ^St, pl: ^Plan, s: Service) -> string {
	switch s {
	case .Mail:
		return fmt.tprintf("%s@%s", plan_handle(pl), st.domain)
	case .Drive:
		return trf("%s, both ways", fmt.tprintf("~/Drive/%s", plan_handle(pl)))
	case .Calendar:
		return tr("Events, invitations and people")
	case .Notes:
		return tr("This identity's notebook")
	case .Passwords:
		return tr("An end-to-end encrypted vault")
	case .Chat:
		return tr("Spaces, messages and calls")
	}
	return ""
}

page_sync :: proc(st: ^St, ui: ^p.Ctx) {
	p.col(ui, "w-full max-w-[960] gap-4")
	defer p.end(ui)
	first := true
	for &pl, i in st.plans {
		if !pl.existing {
			continue
		}
		p.key(ui, fmt.tprintf("sync-%d", i))
		p.col(ui, "w-full rounded-xl border border-border bg-card/60 overflow-hidden")
		// "Tint when single": this card is one identity's, so it carries the
		// identity's band, and its name next to the colour.
		p.div(ui, fmt.tprintf("w-full h-[3] %s", id_class("bg", pl.color)))
		p.end(ui)
		p.col(ui, "w-full gap-4 p-5")
		p.row(ui, "w-full items-center gap-3")
		monogram_box(ui, plan_mono(st, &pl), pl.color)
		p.col(ui, "flex-1 gap-0.5 min-w-0")
		txt(ui, plan_name(&pl), fmt.tprintf("text-sm font-semibold %s", id_class("text", pl.color)))
		txt(ui, fmt.tprintf("%s · %s@%s", kind_label(pl.kind), plan_handle(&pl), st.domain), "text-xs text-muted-foreground")
		p.end(ui)
		n := card_count(pl.services)
		text(ui, n == 0 ? tr("Nothing syncs") : trf("%d of 6", n), "text-xs text-muted-foreground whitespace-nowrap")
		p.end(ui)

		for line in 0 ..< 2 {
		p.row(ui, "w-full gap-3")
		for col in 0 ..< 3 {
			s := Service(line * 3 + col)
			p.key(ui, fmt.tprintf("svc-%v", s))
			on := s in pl.services
			row := p.row(ui, "flex-1 min-w-0 items-center gap-3 px-3 py-2.5 rounded-lg border cursor-pointer")
			p.apply(ui, on ? fmt.tprintf("%s %s", id_class("border", pl.color, "/50"), id_class("bg", pl.color, "/5")) : "border-border hover:bg-muted")
			p.focusable(ui, row)
			if first {
				focus_here(st, ui, row)
				first = false
			}
			if p.focused(ui, row) {
				p.apply(ui, "ring-3 ring-ring/50")
			}
			if p.clickable(ui, row) || (p.focused(ui, row) && p.key_pressed(ui, p.KEY_SPACE, false)) {
				if on {
					pl.services -= {s}
				} else {
					pl.services += {s}
				}
				on = !on
			}
			p.icon(ui, service_icon(s), on ? fmt.tprintf("size-4 shrink-0 %s", id_class("text", pl.color)) : "size-4 shrink-0 text-muted-foreground")
			p.col(ui, "flex-1 min-w-0")
			txt(ui, service_label(s), "text-sm text-foreground")
			txt(ui, service_detail(st, &pl, s), "text-xs text-muted-foreground truncate")
			p.end(ui)
			sc.switch_(ui, on, .SM)
			p.end(ui)
		}
		p.end(ui)
		}
		p.end(ui)
		p.end(ui)
	}
	p.row(ui, "w-full items-start gap-2 pt-1")
	p.icon(ui, WI_SHIELD_CHECK, "size-4 mt-px text-muted-foreground shrink-0")
	txt(ui, tr("The server enforces this, not the apps: a session for one identity cannot read another's data even by mistake."), "flex-1 text-xs text-muted-foreground")
	p.end(ui)
}

card_count :: proc(s: Services) -> int {
	n := 0
	for x in Service {
		if x in s {
			n += 1
		}
	}
	return n
}

// ---------------------------------------------------------------------------
// 6. Passwords: the vault and its Emergency Kit
// ---------------------------------------------------------------------------

page_passwords :: proc(st: ^St, ui: ^p.Ctx) {
	if st.vault_done && st.secret != "" {
		emergency_kit(st, ui)
		return
	}
	p.row(ui, "w-full max-w-[960] items-start gap-10")
	defer p.end(ui)

	// What it is, in three lines.
	p.col(ui, "w-[380] shrink-0 gap-4 p-5 rounded-xl border border-border bg-card/60")
	for item in ([?]struct {
			ic:   p.Icon,
			head: string,
			body: string,
		} {
			{WI_LOCK, N("Your master password"), N("You choose it and remember it. It is never sent anywhere. Make it different from your account password.")},
			{WI_KEY_ROUND, N("Your Secret Key"), N("128 random bits made on this computer. It joins the master password to encrypt everything, so a guessed password alone is useless.")},
			{WI_FILE_DOWN, N("Your Emergency Kit"), N("A page with the Secret Key on it, saved next. You need it to open your vault on a new computer.")},
		}) {
		p.row(ui, "w-full items-start gap-3")
		p.div(ui, "size-8 rounded-lg bg-muted items-center justify-center shrink-0")
		p.icon(ui, item.ic, "size-4 text-foreground")
		p.end(ui)
		p.col(ui, "flex-1 gap-0.5 min-w-0")
		txt(ui, tr(item.head), "text-sm font-medium text-foreground")
		txt(ui, tr(item.body), "text-xs text-muted-foreground")
		p.end(ui)
		p.end(ui)
	}
	who := make([dynamic]string, context.temp_allocator)
	for &pl in st.plans {
		if pl.existing && .Passwords in pl.services {
			append(&who, plan_name(&pl))
		}
	}
	p.end(ui)

	p.col(ui, "flex-1 gap-5 min-w-0")
	disabled := busy(st)
	if st.vault_enroll {
		field(ui, st, &st.secret_buf, tr("Secret Key"), "PV1-XXXXXX-XXXXXX-XXXXXX-XXXXXX-XX", "", tr("It is on your Emergency Kit, the page you saved when you made the vault."), focus_first = true, disabled = disabled, mono = true)
	} else {
		prob := st.vault_tried ? vault_problem(st) : ""
		field(ui, st, &st.vault_pw, tr("Master password"), "", prob == N("The master password needs at least 10 characters.") || prob == N("Use a different password from your account password.") ? tr(prob) : "", tr("At least 10 characters. A sentence works well."), secret = true, focus_first = true, disabled = disabled)
		field(ui, st, &st.vault_pw2, tr("Confirm master password"), "", prob == N("The passwords do not match.") ? tr(prob) : "", secret = true, disabled = disabled)
	}
	p.row(ui, "w-full items-start gap-2")
	p.icon(ui, WI_USERS, "size-4 mt-px text-muted-foreground shrink-0")
	txt(ui, tr("One Secret Key and one master password protect the whole account. Each identity gets a vault of its own, with its own keys: sharing between them is something you do, never something that happens."), "flex-1 text-xs text-muted-foreground")
	p.end(ui)
	if len(who) > 0 {
		p.row(ui, "w-full items-center gap-2 flex-wrap")
		text(ui, tr("Chosen for:"), "text-xs text-muted-foreground")
		for &pl in st.plans {
			if pl.existing && .Passwords in pl.services {
				identity_label(ui, plan_name(&pl), pl.color)
			}
		}
		p.end(ui)
	}
	p.end(ui)
}

emergency_kit :: proc(st: ^St, ui: ^p.Ctx) {
	p.row(ui, "w-full max-w-[960] items-start gap-8")
	defer p.end(ui)

	// The kit itself, as it will print: always light, like paper.
	p.col(ui, "w-[440] shrink-0 gap-4 p-6 rounded-xl bg-white border border-[#e4e4e7] shadow-lg")
	p.row(ui, "items-center gap-2")
	p.div(ui, "size-7 rounded-md bg-[#18181b] items-center justify-center")
	p.icon(ui, WI_PACKAGE, "size-4 text-white")
	p.end(ui)
	txt(ui, tr("Palmframe Emergency Kit"), "flex-1 text-base font-semibold text-[#18181b]")
	p.end(ui)
	kit_row(ui, tr("Account"), st.email)
	kit_row(ui, tr("Server"), server_label(st))
	p.col(ui, "w-full gap-1.5")
	txt(ui, tr("Secret Key"), "text-xs font-medium text-[#71717a]")
	p.div(ui, "w-full px-3 py-3 rounded-lg bg-[#f4f4f5] border border-[#e4e4e7]")
	text(ui, st.secret, "text-base font-mono font-semibold text-[#18181b] dir-ltr")
	p.end(ui)
	p.end(ui)
	p.col(ui, "w-full gap-1.5")
	txt(ui, tr("Master password"), "text-xs font-medium text-[#71717a]")
	p.div(ui, "w-full h-10 rounded-lg border border-dashed border-[#a1a1aa]")
	p.end(ui)
	txt(ui, tr("Write it here by hand, or keep it only in your head."), "text-xs text-[#71717a]")
	p.end(ui)
	p.end(ui)

	p.col(ui, "flex-1 gap-4 min-w-0")
	txt(ui, tr("Save the kit, then print it or copy it somewhere only you can reach: a drawer, a safe, a password manager you already trust. Then delete the saved files."), "text-sm text-foreground")
	p.row(ui, "items-center gap-3")
	n := p.node_count(ui)
	if button(ui, st, tr("Save Emergency Kit"), WI_SAVE, .Outline, disabled = busy(st)) {
		start_job(st, .Kit)
	}
	if st.kit_paths[0] == "" {
		focus_here(st, ui, n)
	}
	p.end(ui)
	if st.kit_paths[0] != "" {
		p.col(ui, "w-full gap-1 p-3 rounded-lg bg-muted")
		for f in st.kit_paths {
			if f != "" {
				p.row(ui, "items-center gap-2 min-w-0")
				p.icon(ui, WI_FILE_DOWN, "size-3.5 text-muted-foreground shrink-0")
				text(ui, f, "min-w-0 text-xs font-mono text-foreground truncate")
				p.end(ui)
			}
		}
		p.end(ui)
	}
	p.div(ui, "w-full pt-2")
	p.end(ui)
	n2 := p.node_count(ui)
	checkbox(ui, &st.kit_ack, tr("I have saved my Emergency Kit somewhere safe"), tr("Palmframe cannot recover your vault for you. That is what makes it yours."))
	if st.kit_paths[0] != "" && !st.kit_ack {
		focus_here(st, ui, n2)
	}
	p.end(ui)
}

kit_row :: proc(ui: ^p.Ctx, label, value: string) {
	p.col(ui, "w-full gap-0.5")
	txt(ui, label, "text-xs font-medium text-[#71717a]")
	text(ui, value, "text-sm font-mono text-[#18181b] dir-ltr")
	p.end(ui)
}

// ---------------------------------------------------------------------------
// 7. Setup
// ---------------------------------------------------------------------------

task_label :: proc(st: ^St, t: Task) -> string {
	switch t.what {
	case .Session:
		return tr("A session for this identity on this computer")
	case .Mailbox:
		return trf("Mailboxes for %s", fmt.tprintf("%s@%s", t.handle, st.domain))
	case .Mail_Client:
		return tr("Mail on this computer")
	case .Drive:
		return trf("Drive folder %s", fmt.tprintf("~/Drive/%s", t.handle))
	case .Calendar:
		return tr("Calendars")
	case .Contacts:
		return tr("Address books")
	case .Notes:
		return tr("Notes")
	case .Chat:
		return tr("Chat")
	case .Vault:
		return tr("Passwords, in this identity's vault")
	case .Sync_Conf:
		return tr("Remember these choices on this computer")
	}
	return ""
}

state_label :: proc(s: Task_State) -> string {
	switch s {
	case .Waiting:
		return tr("Waiting")
	case .Running:
		return tr("Working…")
	case .Done:
		return tr("Done")
	case .Pending_Server:
		return tr("Waiting for the server")
	case .Not_Installed:
		return tr("Not installed on this computer")
	case .Coming:
		return tr("Coming; your choice is saved")
	case .Failed:
		return tr("Failed")
	case .Skipped:
		return tr("Skipped")
	}
	return ""
}

state_icon :: proc(s: Task_State) -> (p.Icon, string) {
	switch s {
	case .Waiting:
		return WI_CHEVRON_RIGHT, "text-muted-foreground/60"
	case .Running:
		return WI_LOADER_CIRCLE, "text-foreground"
	case .Done:
		return WI_CIRCLE_CHECK, "text-good"
	case .Pending_Server, .Coming:
		return WI_REFRESH_CW, "text-warn"
	case .Not_Installed, .Skipped:
		return WI_INFO, "text-muted-foreground"
	case .Failed:
		return WI_CIRCLE_ALERT, "text-destructive"
	}
	return WI_INFO, ""
}

page_setup :: proc(st: ^St, ui: ^p.Ctx) {
	if !st.setup_ran && len(st.tasks) == 0 {
		plan_tasks(st)
	}
	lock(st)
	defer unlock(st)

	p.col(ui, "w-full max-w-[900] gap-4")
	defer p.end(ui)

	// Mail signs in once with the account password; ask only if this run
	// did not see it typed.
	if !st.setup_ran && any_service(st, .Mail) && len(st.pw_buf) == 0 {
		p.col(ui, "w-full max-w-[520] gap-2")
		field(ui, st, &st.mail_pw_buf, tr("Your account password, for mail"), "", "", tr("Mail on this computer signs in once with it. It is not stored."), secret = true, focus_first = true)
		p.end(ui)
	}

	groups := make([dynamic]string, context.temp_allocator)
	append(&groups, "")
	for t in st.tasks {
		if t.handle == "" {
			continue
		}
		seen := false
		for g in groups {
			if g == t.handle {
				seen = true
			}
		}
		if !seen {
			append(&groups, t.handle)
		}
	}
	setup_group(st, ui, "", "w-full")
	for i := 1; i < len(groups); i += 2 {
		p.key(ui, fmt.tprintf("pair-%d", i))
		p.row(ui, "w-full items-start gap-4")
		setup_group(st, ui, groups[i], "flex-1 min-w-0")
		if i + 1 < len(groups) {
			setup_group(st, ui, groups[i + 1], "flex-1 min-w-0")
		} else {
			p.div(ui, "flex-1 min-w-0")
			p.end(ui)
		}
		p.end(ui)
	}
}

// setup_group is one identity's tasks (or, for "", this computer's), in a
// card carrying that identity's band and name.
setup_group :: proc(st: ^St, ui: ^p.Ctx, g: string, class: string) {
	pl := g != "" ? find_plan(st, g) : nil
	p.key(ui, fmt.tprintf("group-%s", g))
	p.col(ui, "rounded-xl border border-border bg-card/60 overflow-hidden")
	p.apply(ui, class)
	if pl != nil {
		p.div(ui, fmt.tprintf("w-full h-[3] %s", id_class("bg", pl.color)))
		p.end(ui)
	}
	p.col(ui, "w-full gap-1.5 p-4")
	p.row(ui, "w-full items-center gap-3 pb-1")
	if pl != nil {
		monogram_box(ui, plan_mono(st, pl), pl.color, "size-7", "text-xs")
		txt(ui, plan_name(pl), fmt.tprintf("flex-1 min-w-0 text-sm font-semibold %s", id_class("text", pl.color)))
	} else {
		p.div(ui, "size-7 rounded-lg bg-muted items-center justify-center shrink-0")
		p.icon(ui, WI_LAPTOP, "size-4 text-foreground")
		p.end(ui)
		txt(ui, tr("This computer"), "flex-1 min-w-0 text-sm font-semibold text-foreground")
	}
	p.end(ui)
	for t, i in st.tasks {
		if t.handle != g {
			continue
		}
		p.key(ui, fmt.tprintf("task-%d", i))
		p.row(ui, "w-full items-start gap-3 py-0.5")
		ic, cls := state_icon(t.state)
		p.icon(ui, ic, fmt.tprintf("size-4 mt-0.5 shrink-0 %s", cls))
		p.col(ui, "flex-1 gap-0.5 min-w-0")
		txt(ui, task_label(st, t), "text-sm text-foreground")
		note := ""
		if t.state != .Done && t.state != .Waiting {
			note = state_label(t.state)
		}
		if t.detail != "" && t.state != .Waiting && !(t.state == .Done && (t.what == .Mailbox || t.what == .Drive)) {
			note = note == "" ? t.detail : fmt.tprintf("%s · %s", note, t.detail)
		}
		if note != "" {
			txt(ui, note, t.state == .Failed ? "text-xs text-destructive" : "text-xs text-muted-foreground")
		}
		p.end(ui)
		p.end(ui)
	}
	p.end(ui)
	p.end(ui)
}

// ---------------------------------------------------------------------------
// 8. Import: coming
// ---------------------------------------------------------------------------

page_import :: proc(st: ^St, ui: ^p.Ctx) {
	p.col(ui, "w-full max-w-[720] gap-3")
	defer p.end(ui)
	for src in ([?]struct {
			name: string,
			what: string,
		} {{"Google", N("Gmail, Contacts, Calendar and Drive")}, {"Microsoft", N("Outlook, People, Calendar and OneDrive")}}) {
		p.row(ui, "w-full items-center gap-4 p-5 rounded-xl border border-border bg-card/40")
		p.div(ui, "size-10 rounded-lg bg-muted items-center justify-center shrink-0")
		p.icon(ui, WI_DOWNLOAD, "size-5 text-muted-foreground")
		p.end(ui)
		p.col(ui, "flex-1 gap-0.5 min-w-0")
		txt(ui, src.name, "text-base font-semibold text-foreground")
		txt(ui, tr(src.what), "text-sm text-muted-foreground")
		p.end(ui)
		sc.badge(ui, tr("Coming"), .Secondary)
		p.end(ui)
	}
	p.row(ui, "w-full items-start gap-2 pt-2")
	p.icon(ui, WI_INFO, "size-4 mt-px text-muted-foreground shrink-0")
	txt(ui, tr("Nothing is imported now. Until it is, Mail and Calendar can each add an outside account of their own."), "flex-1 text-xs text-muted-foreground")
	p.end(ui)
}

// ---------------------------------------------------------------------------
// 9. Tour
// ---------------------------------------------------------------------------

page_tour :: proc(st: ^St, ui: ^p.Ctx) {
	p.row(ui, "w-full max-w-[1040] items-stretch gap-4")
	defer p.end(ui)

	// The start menu.
	tour_card_open(ui, WI_LAYOUT_GRID, tr("The start menu"), tr("Every app, and search. Start typing as soon as it opens."))
	p.col(ui, "w-full gap-1.5 p-3 rounded-lg bg-muted/60 border border-border")
	p.row(ui, "w-full items-center gap-2 px-2 py-1.5 rounded-md bg-background border border-border")
	p.icon(ui, WI_GLOBE, "size-3.5 text-muted-foreground")
	text(ui, tr("Search apps and files"), "text-xs text-muted-foreground")
	p.end(ui)
	p.row(ui, "w-full gap-1.5 pt-1")
	for ic in ([?]p.Icon{WI_MAIL, WI_CALENDAR, WI_HARD_DRIVE, WI_NOTEBOOK_PEN, WI_KEY_ROUND}) {
		p.div(ui, "flex-1 h-9 rounded-md bg-background border border-border items-center justify-center")
		p.icon(ui, ic, "size-4 text-foreground")
		p.end(ui)
	}
	p.end(ui)
	p.end(ui)
	tour_keys(ui, {"Super", "Space"}, tr("Open the start menu"))
	tour_card_close(ui)

	// The identity switcher.
	tour_card_open(ui, WI_USERS, tr("The identity switcher"), tr("At the left of the bar. New windows open in the current identity; the band on a window says whose it is."))
	p.col(ui, "w-full gap-1 p-3 rounded-lg bg-muted/60 border border-border")
	shown := 0
	for &pl in st.plans {
		if !pl.existing || shown >= 3 {
			continue
		}
		p.key(ui, fmt.tprintf("tour-%s", plan_handle(&pl)))
		p.row(ui, "w-full items-center gap-2 px-2 py-1.5 rounded-md")
		if shown == 0 {
			p.apply(ui, "bg-background border border-border")
		}
		monogram_box(ui, plan_mono(st, &pl), pl.color, "size-5", "text-[10px]")
		text(ui, plan_name(&pl), "flex-1 min-w-0 text-xs text-foreground truncate")
		if shown == 0 {
			p.icon(ui, WI_CHECK, "size-3.5 text-muted-foreground")
		}
		p.end(ui)
		shown += 1
	}
	if shown == 0 {
		// No account: the switcher stays out of the way until there is one.
		p.row(ui, "w-full items-center gap-2 px-2 py-1.5")
		p.icon(ui, WI_LAPTOP, "size-4 text-muted-foreground")
		text(ui, tr("Appears once you add an account"), "text-xs text-muted-foreground")
		p.end(ui)
	}
	p.end(ui)
	tour_keys(ui, {"Super", "I"}, tr("Switch identity"))
	tour_card_close(ui)

	// The keys.
	tour_card_open(ui, WI_KEYBOARD, tr("The keys"), tr("Everything works from the keyboard. These five are enough to start."))
	p.col(ui, "w-full gap-2")
	tour_keys(ui, {"Super", "Enter"}, tr("A terminal"))
	tour_keys(ui, {"Alt", "Tab"}, tr("Switch windows"))
	tour_keys(ui, {"Super", "W"}, tr("See every window"))
	tour_keys(ui, {"Super", "Q"}, tr("Close the window"))
	tour_keys(ui, {"Super", "/"}, tr("Every shortcut"))
	p.end(ui)
	tour_card_close(ui)
}

tour_card_open :: proc(ui: ^p.Ctx, ic: p.Icon, title, body: string) {
	p.col(ui, "flex-1 min-w-0 gap-4 p-5 rounded-xl border border-border bg-card/60")
	p.div(ui, "size-9 rounded-lg bg-muted items-center justify-center")
	p.icon(ui, ic, "size-5 text-foreground")
	p.end(ui)
	p.col(ui, "w-full gap-1")
	txt(ui, title, "text-base font-semibold text-foreground")
	txt(ui, body, "text-sm text-muted-foreground")
	p.end(ui)
}

tour_card_close :: proc(ui: ^p.Ctx) {
	p.end(ui)
}

tour_keys :: proc(ui: ^p.Ctx, keys: []string, what: string) {
	p.row(ui, "w-full items-center gap-2")
	p.row(ui, "items-center gap-1 dir-ltr")
	for k, i in keys {
		if i > 0 {
			text(ui, "+", "text-xs text-muted-foreground")
		}
		sc.kbd(ui, k)
	}
	p.end(ui)
	txt(ui, what, "flex-1 min-w-0 text-xs text-muted-foreground")
	p.end(ui)
}

// ---------------------------------------------------------------------------
// 10. Done
// ---------------------------------------------------------------------------

page_done :: proc(st: ^St, ui: ^p.Ctx) {
	p.col(ui, "w-full h-full items-center justify-center gap-6 pb-10")
	defer p.end(ui)
	p.div(ui, "size-14 rounded-full bg-primary items-center justify-center")
	p.icon(ui, WI_CHECK, "size-7 text-primary-foreground")
	p.end(ui)
	p.col(ui, "items-center gap-2 max-w-[560]")
	text(ui, tr("Palmframe is ready"), "text-3xl font-semibold tracking-tight text-foreground text-center")
	if st.mode == .Account && st.email != "" {
		text(ui, trf("Signed in as %s.", st.email), "text-sm text-muted-foreground text-center")
	} else {
		text(ui, tr("Everything stays on this computer. You can add an account whenever you like."), "text-sm text-muted-foreground text-center")
	}
	p.end(ui)

	if usable_count(st) > 0 {
		p.col(ui, "w-[560] gap-2 p-4 rounded-xl border border-border bg-card/60")
		for &pl in st.plans {
			if !pl.existing {
				continue
			}
			p.key(ui, fmt.tprintf("done-%s", plan_handle(&pl)))
			p.row(ui, "w-full items-center gap-3")
			monogram_box(ui, plan_mono(st, &pl), pl.color, "size-7", "text-xs")
			p.col(ui, "flex-1 min-w-0")
			txt(ui, plan_name(&pl), "text-sm font-medium text-foreground")
			txt(ui, fmt.tprintf("%s@%s", plan_handle(&pl), st.domain), "text-xs font-mono text-muted-foreground")
			p.end(ui)
			p.row(ui, "items-center gap-1.5")
			for s in Service {
				if s in pl.services {
					p.icon(ui, service_icon(s), fmt.tprintf("size-3.5 %s", id_class("text", pl.color)))
				}
			}
			p.end(ui)
			p.end(ui)
		}
		p.end(ui)
	}

	n := p.node_count(ui)
	if button(ui, st, tr("Start using Palmframe"), fwd_icon(), .Default, icon_after = true) {
		go_next(st)
	}
	focus_here(st, ui, n)
	p.row(ui, "items-center gap-2")
	text(ui, tr("To see this again:"), "text-xs text-muted-foreground")
	text(ui, "welcome run", "text-xs font-mono text-foreground dir-ltr")
	p.end(ui)
}
