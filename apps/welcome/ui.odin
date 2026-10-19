package main

// The frame around every page: the rail of steps, the heading, the
// Back / Skip / Next bar, and the keys.
//
// It is the installer's visual language (apps/installer/ui.odin) on purpose,
// because the person has just come from it: the same rail, the same step
// discs, the same near-black wash in the dark, Geist, lucide icons and
// shadcn's buttons and inputs. What is new is light, which the installer
// does not offer, and identity colour, which appears the moment an identity
// exists: in a band across the top, in the rail, and on each identity's own
// card. It is never used as decoration (shell.md): only where it says
// "this belongs to that identity", and always next to the name or letter.
//
// Right to left: the root gets palmy's `dir-rtl`, rows run right to left and
// the Tab order follows; chevrons swap; addresses and paths stay `dir-auto`.

import "core:fmt"
import "core:time"
import p "palmy:."
import sc "shadcn:."

// ---------------------------------------------------------------------------
// Theme
// ---------------------------------------------------------------------------

register_theme :: proc(dark: bool) {
	sc.register_shadcn_theme(false)
	if dark {
		// The installer's (and the greeter's) palette, token for token.
		c :: p.hex
		p.register_color("background", c(0x0a0a0a))
		p.register_color("foreground", c(0xfafafa))
		p.register_color("card", c(0x18181b))
		p.register_color("card-foreground", c(0xfafafa))
		p.register_color("popover", c(0x262626))
		p.register_color("popover-foreground", c(0xfafafa))
		p.register_color("primary", c(0xe5e5e5))
		p.register_color("primary-foreground", c(0x171717))
		p.register_color("secondary", c(0x262626))
		p.register_color("secondary-foreground", c(0xfafafa))
		p.register_color("muted", c(0x262626))
		p.register_color("muted-foreground", c(0xa1a1a1))
		p.register_color("accent", c(0x3f3f46))
		p.register_color("accent-foreground", c(0xfafafa))
		p.register_color("destructive", c(0xff6467))
		p.register_color("destructive-foreground", c(0x450a0a))
		p.register_color("border", c(0x2e2e32))
		p.register_color("input", c(0x3a3a3f))
		p.register_color("ring", c(0x8e8e93))
		p.register_color("wash-top", c(0x121217))
		p.register_color("wash-bottom", c(0x07070a))
		p.register_color("good", c(0x34d399))
		p.register_color("warn", c(0xfbbf24))
	} else {
		p.register_color("wash-top", p.hex(0xffffff))
		p.register_color("wash-bottom", p.hex(0xf4f4f5))
		p.register_color("good", p.hex(0x059669))
		p.register_color("warn", p.hex(0xb45309))
	}
	for h in PALETTE {
		p.register_color(fmt.tprintf("id-%s", h.name), p.hex(dark ? h.dark : h.light))
	}
}

// id_class is a class string in an identity's colour: id_class("bg", 2, "/10")
// is "bg-id-amber/10".
id_class :: proc(prop: string, color: int, suffix := "") -> string {
	return fmt.tprintf("%s-id-%s%s", prop, PALETTE[clamp(color, 0, len(PALETTE) - 1)].name, suffix)
}

// ---------------------------------------------------------------------------
// Direction-aware text
// ---------------------------------------------------------------------------

text :: proc(ui: ^p.Ctx, s: string, class := "") -> int {
	idx := p.text(ui, s, class)
	p.apply(ui, "dir-auto", idx)
	return idx
}

textf :: proc(ui: ^p.Ctx, class: string, format: string, args: ..any) -> int {
	idx := p.textf(ui, class, format, ..args)
	p.apply(ui, "dir-auto", idx)
	return idx
}

txt :: proc(ui: ^p.Ctx, s: string, class := "") -> int {
	idx := text(ui, s, class)
	p.apply(ui, is_rtl() ? "text-right" : "text-left", idx)
	return idx
}

fwd_icon :: proc() -> p.Icon {
	return is_rtl() ? WI_CHEVRON_LEFT : WI_CHEVRON_RIGHT
}

back_icon :: proc() -> p.Icon {
	return is_rtl() ? WI_CHEVRON_RIGHT : WI_CHEVRON_LEFT
}

// ---------------------------------------------------------------------------
// Controls that work from the keyboard
// ---------------------------------------------------------------------------

// button is a shadcn button in the Tab order that answers Enter and Space.
// A focused button that takes Enter sets consumed_enter, so the page-wide
// Enter (Next) does not fire as well.
button :: proc(ui: ^p.Ctx, st: ^St, label: string, ic: Maybe(p.Icon), v: sc.Variant, disabled := false, icon_after := false, size := sc.Size.LG) -> bool {
	idx := sc.button_open(ui, v, size, {disabled = disabled})
	p.apply(ui, size == .LG ? "px-4 gap-2" : "px-3 gap-1.5")
	if !disabled {
		p.focusable(ui, idx)
	}
	if p.focused(ui, idx) {
		p.apply(ui, "border-ring ring-3 ring-ring/50", idx)
	}
	hit := false
	if !disabled {
		key := p.focused(ui, idx) && (p.key_pressed(ui, p.KEY_RETURN, false) || p.key_pressed(ui, p.KEY_KP_ENTER, false) || p.key_pressed(ui, p.KEY_SPACE, false))
		if key {
			st.consumed_enter = true
		}
		hit = key || p.clickable(ui, idx)
	}
	if i, has := ic.?; has && !icon_after {
		p.icon(ui, i, "size-4")
	}
	text(ui, label, "whitespace-nowrap")
	p.style(ui).shrink = 0
	if i, has := ic.?; has && icon_after {
		p.icon(ui, i, "size-4")
	}
	sc.button_end(ui)
	return hit
}

// choice_card is a large selectable card: an icon, a title, a line under
// it, a check when chosen. Focus, Space or a click chooses it; Enter on it
// chooses it and moves on, which is what a single-choice page should do.
choice_card :: proc(ui: ^p.Ctx, st: ^St, ic: p.Icon, title, detail: string, chosen: bool, class := "") -> (picked: bool) {
	card := p.row(ui, "w-full items-start gap-4 p-5 rounded-xl border cursor-pointer transition")
	p.apply(ui, chosen ? "border-foreground/60 bg-accent/60" : "border-border bg-card/60 hover:bg-muted")
	if class != "" {
		p.apply(ui, class)
	}
	p.focusable(ui, card)
	if p.focused(ui, card) {
		p.apply(ui, "ring-3 ring-ring/50")
	}
	picked = p.clickable(ui, card) || (p.focused(ui, card) && p.key_pressed(ui, p.KEY_SPACE, false))
	if p.focused(ui, card) && (p.key_pressed(ui, p.KEY_RETURN, false) || p.key_pressed(ui, p.KEY_KP_ENTER, false)) {
		picked = true
		// Enter also means Next: leave it unconsumed.
	}
	{
		p.div(ui, "size-10 rounded-lg bg-muted items-center justify-center shrink-0")
		p.icon(ui, ic, "size-5 text-foreground")
		p.end(ui)
		p.col(ui, "flex-1 gap-1 min-w-0")
		txt(ui, title, "text-base font-semibold text-foreground")
		txt(ui, detail, "text-sm text-muted-foreground")
		p.end(ui)
		p.div(ui, "size-5 shrink-0 items-center justify-center")
		if chosen {
			p.icon(ui, WI_CHECK, "size-5 text-foreground")
		}
		p.end(ui)
	}
	p.end(ui)
	return
}

// checkbox: a focusable row with a box and a label; Space or a click.
checkbox :: proc(ui: ^p.Ctx, on: ^bool, label: string, detail := "") -> bool {
	check := p.row(ui, "w-full items-start gap-3 py-1 rounded-md cursor-pointer")
	p.focusable(ui, check)
	if p.focused(ui, check) {
		p.apply(ui, "ring-3 ring-ring/50")
	}
	toggled := p.clickable(ui, check) || (p.focused(ui, check) && p.key_pressed(ui, p.KEY_SPACE, false))
	{
		p.div(ui, on^ ? "size-4 mt-0.5 rounded-sm bg-primary border border-primary items-center justify-center shrink-0" : "size-4 mt-0.5 rounded-sm border border-input shrink-0")
		if on^ {
			p.icon(ui, WI_CHECK, "size-3 text-primary-foreground")
		}
		p.end(ui)
		p.col(ui, "flex-1 gap-0.5 min-w-0")
		txt(ui, label, "text-sm text-foreground")
		if detail != "" {
			txt(ui, detail, "text-xs text-muted-foreground")
		}
		p.end(ui)
	}
	p.end(ui)
	if toggled {
		on^ = !on^
	}
	return toggled
}

// field is a labelled shadcn input with its problem, or a hint, under it.
field :: proc(ui: ^p.Ctx, st: ^St, buf: ^[dynamic]u8, label, placeholder: string, problem := "", hint := "", secret := false, focus_first := false, disabled := false, mono := false) -> (changed: bool) {
	p.col(ui, "w-full gap-2")
	defer p.end(ui)
	if label != "" {
		txt(ui, label, "text-sm font-medium text-foreground")
	}
	n := p.node_count(ui)
	ch := false
	if disabled && secret {
		// shadcn's disabled input is drawn from its display form, which has
		// no mask: a password would show in clear while the job runs.
		dots := make([]u8, len(buf) * 3, context.temp_allocator)
		k := 0
		for _ in string(buf[:]) {
			copy(dots[k:], "•")
			k += len("•")
		}
		sc.input(ui, string(dots[:k]), placeholder, {disabled = true})
	} else {
		ch, _ = sc.input(ui, buf, placeholder, {invalid = problem != "", disabled = disabled}, secret ? '•' : 0)
	}
	if mono {
		p.apply(ui, "font-mono", n)
	}
	if focus_first && st.want_focus {
		p.set_focus(ui, p.node_id(ui, n))
		st.want_focus = false
		p.redraw(ui)
	}
	if problem != "" {
		r := p.row(ui, "items-center gap-1.5")
		p.icon(ui, WI_CIRCLE_ALERT, "size-3.5 text-destructive shrink-0")
		txt(ui, problem, "flex-1 min-w-0 text-xs text-destructive")
		p.end(ui)
	} else if hint != "" {
		txt(ui, hint, "text-xs text-muted-foreground")
	}
	return ch
}

keys_hint :: proc(ui: ^p.Ctx, key, what: string) {
	p.row(ui, "items-center gap-2")
	sc.kbd(ui, key)
	text(ui, what, "text-xs text-muted-foreground whitespace-nowrap")
	p.end(ui)
}

// monogram_box draws an identity's letter on a wash of its colour.
monogram_box :: proc(ui: ^p.Ctx, letter: string, color: int, size := "size-9", text_class := "text-sm") {
	p.div(ui, fmt.tprintf("%s rounded-lg items-center justify-center shrink-0 %s %s", size, id_class("bg", color, "/15"), id_class("border", color, "/40")))
	p.apply(ui, "border")
	text(ui, letter, fmt.tprintf("%s font-semibold %s", text_class, id_class("text", color)))
	p.end(ui)
}

// identity_label: a dot and the name, the "label when mixed" mark.
identity_label :: proc(ui: ^p.Ctx, name: string, color: int) {
	p.row(ui, "items-center gap-1.5 min-w-0")
	p.div(ui, fmt.tprintf("size-2 rounded-full shrink-0 %s", id_class("bg", color)))
	p.end(ui)
	text(ui, name, "text-xs text-muted-foreground whitespace-nowrap")
	p.end(ui)
}

// ---------------------------------------------------------------------------
// The frame
// ---------------------------------------------------------------------------

RAIL_W :: 272

draw :: proc(st: ^St, ui: ^p.Ctx) {
	st.consumed_enter = false
	st.now = f64(p.elapsed(ui))
	poll_job(st)

	p.col(ui, "w-full h-full bg-background text-foreground")
	if is_rtl() {
		p.apply(ui, "dir-rtl")
	}
	defer p.end(ui)

	p.div(ui, "absolute inset-0 bg-gradient-to-b from-wash-top to-wash-bottom")
	p.end(ui)

	p.row(ui, "w-full h-full")
	rail(st, ui)
	p.col(ui, "flex-1 h-full min-w-0")
	{
		band(st, ui)
		heading(st, ui)
		p.col(ui, "flex-1 min-h-0 w-full px-12 pb-4 overflow-scroll")
		page(st, ui)
		p.end(ui)
		footer(st, ui)
	}
	p.end(ui)
	p.end(ui)

	handle_keys(st, ui)

	if busy(st) {
		p.wake_after(ui, 100 * time.Millisecond)
	}
}

// band is the identity band across the top: every identity's colour side by
// side, the "All identities" mark from Home, from the moment one exists.
band :: proc(st: ^St, ui: ^p.Ctx) {
	n := usable_count(st)
	p.row(ui, "w-full h-[3] shrink-0")
	if n > 0 {
		for &pl in st.plans {
			if pl.existing {
				p.div(ui, fmt.tprintf("flex-1 h-full %s", id_class("bg", pl.color)))
				p.end(ui)
			}
		}
	}
	p.end(ui)
}

step_title :: proc(s: Step) -> string {
	switch s {
	case .Welcome:
		return tr("Welcome")
	case .Account:
		return tr("Account")
	case .Sign_In:
		return tr("Sign in")
	case .Identities:
		return tr("Identities")
	case .Sync:
		return tr("Sync")
	case .Passwords:
		return tr("Passwords")
	case .Setup:
		return tr("Set up")
	case .Import:
		return tr("Import")
	case .Tour:
		return tr("Tour")
	case .Done:
		return tr("Done")
	}
	return ""
}

rail :: proc(st: ^St, ui: ^p.Ctx) {
	p.col(ui, "h-full gap-6 px-5 py-8 bg-card/40")
	p.style(ui).w = p.px(RAIL_W)
	p.style(ui).shrink = 0
	p.apply(ui, is_rtl() ? "border-l border-border" : "border-r border-border")
	defer p.end(ui)

	p.row(ui, "items-center gap-3 px-2")
	{
		p.div(ui, "size-9 rounded-lg bg-primary items-center justify-center")
		p.icon(ui, WI_PACKAGE, "size-5 text-primary-foreground")
		p.end(ui)
		p.col(ui, "gap-0")
		txt(ui, "Palmframe", "text-base font-semibold text-foreground")
		txt(ui, tr("First steps"), "text-xs text-muted-foreground")
		p.end(ui)
	}
	p.end(ui)

	p.col(ui, "gap-1")
	num := 0
	for s in Step {
		p.key(ui, fmt.tprintf("rail-%v", s))
		used := step_used(st, s)
		if used {
			num += 1
		}
		current := s == st.step
		done := used && s < st.step
		item := p.row(ui, "items-center gap-3 px-2 py-1 rounded-lg")
		if current {
			p.apply(ui, "bg-accent")
		}
		{
			DISC :: "size-7 rounded-full items-center justify-center border shrink-0"
			switch {
			case !used:
				p.div(ui, DISC + " border-border/50")
				p.div(ui, "w-2 h-px bg-muted-foreground/50")
				p.end(ui)
			case done:
				p.div(ui, DISC + " bg-primary border-primary")
				p.icon(ui, WI_CHECK, "size-4 text-primary-foreground")
			case current:
				p.div(ui, DISC + " border-foreground bg-background")
				textf(ui, "text-xs font-semibold text-foreground", "%d", num)
			case:
				p.div(ui, DISC + " border-border")
				textf(ui, "text-xs text-muted-foreground", "%d", num)
			}
			p.end(ui)
			p.col(ui, "flex-1 min-w-0")
			cls := "text-sm text-muted-foreground"
			if current {
				cls = "text-sm font-medium text-foreground"
			} else if done {
				cls = "text-sm text-foreground"
			} else if !used {
				cls = "text-sm text-muted-foreground/50"
			}
			txt(ui, step_title(s), cls)
			p.end(ui)
		}
		p.end(ui)
	}
	p.end(ui)

	// Identities, from the moment there is one.
	if usable_count(st) > 0 {
		p.col(ui, "gap-2 px-2")
		txt(ui, tr("Your identities"), "text-xs font-medium text-muted-foreground")
		for &pl in st.plans {
			if !pl.existing {
				continue
			}
			p.key(ui, fmt.tprintf("rail-id-%s", plan_handle(&pl)))
			p.row(ui, "items-center gap-2 min-w-0")
			monogram_box(ui, plan_mono(st, &pl), pl.color, "size-6", "text-xs")
			txt(ui, plan_name(&pl), "flex-1 min-w-0 text-sm text-foreground truncate")
			p.end(ui)
		}
		p.end(ui)
	}

	p.spacer(ui)

	p.col(ui, "gap-3 px-2")
	if st.step != .Done {
		keys_hint(ui, "Tab", tr("Move"))
		keys_hint(ui, "Enter", tr("Next"))
		keys_hint(ui, "Esc", tr("Back"))
	}
	p.end(ui)
}

step_number :: proc(st: ^St) -> (n, total: int) {
	for s in Step {
		if !step_used(st, s) {
			continue
		}
		total += 1
		if s <= st.step {
			n += 1
		}
	}
	return
}

heading :: proc(st: ^St, ui: ^p.Ctx) {
	p.col(ui, "w-full gap-2 px-12 pt-10 pb-6")
	defer p.end(ui)
	if st.step == .Done {
		return
	}
	n, total := step_number(st)
	txt(ui, trf("Step %d of %d", n, total), "text-xs font-medium text-muted-foreground")
	txt(ui, page_heading(st), "text-3xl font-semibold tracking-tight text-foreground")
	if sub := page_subtitle(st); sub != "" {
		txt(ui, sub, "text-sm text-muted-foreground max-w-[760]")
	}
}

footer :: proc(st: ^St, ui: ^p.Ctx) {
	if st.step == .Done {
		return
	}
	p.row(ui, "w-full items-center gap-3 px-12 py-5 border-t border-border")
	defer p.end(ui)

	if can_go_back(st) {
		if button(ui, st, tr("Back"), back_icon(), .Outline) {
			go_back(st)
		}
	}

	// The page's line: a server error, or the reason Next is not available.
	ok, why := can_leave(st)
	line := ""
	bad := false
	switch {
	case busy(st):
		line = busy_label(st)
	case st.msg != "":
		line = st.msg
		bad = st.msg_bad
	case !ok && why != "" && (st.tried || st.step == .Account):
		line = tr(why)
		bad = st.tried
	}
	p.row(ui, "flex-1 items-center gap-2 min-w-0")
	if is_rtl() {
		p.apply(ui, "justify-start")
	} else {
		p.apply(ui, "justify-end")
	}
	if busy(st) {
		p.icon(ui, WI_LOADER_CIRCLE, "size-4 text-muted-foreground shrink-0")
	} else if bad {
		p.icon(ui, WI_CIRCLE_ALERT, "size-4 text-destructive shrink-0")
	}
	text(ui, line, bad ? "min-w-0 text-xs text-destructive" : "min-w-0 text-xs text-muted-foreground")
	p.end(ui)

	if can_skip(st) {
		if button(ui, st, skip_label(st), nil, .Ghost) {
			skip(st)
		}
	}
	label, ic := next_label(st)
	if button(ui, st, label, ic, .Default, disabled = !ok && st.step != .Sign_In && st.step != .Identities && st.step != .Passwords, icon_after = true) {
		go_next(st)
	}
}

busy_label :: proc(st: ^St) -> string {
	switch st.job.kind {
	case .Sign_In:
		return tr("Signing in…")
	case .Sign_Up:
		return tr("Creating your account…")
	case .Identities:
		return tr("Creating identities…")
	case .Vault, .Vault_Enroll:
		return tr("Setting up the vault…")
	case .Kit:
		return tr("Saving the Emergency Kit…")
	case .Services:
		return tr("Setting up…")
	case .None:
	}
	return ""
}

skip_label :: proc(st: ^St) -> string {
	#partial switch st.step {
	case .Account, .Sign_In:
		return tr("Use without an account")
	}
	return tr("Skip")
}

next_label :: proc(st: ^St) -> (string, p.Icon) {
	#partial switch st.step {
	case .Sign_In:
		if !st.signed_in {
			return st.auth_tab == .Create ? tr("Create account") : tr("Sign in"), fwd_icon()
		}
	case .Identities:
		for &pl in st.plans {
			if !pl.existing {
				return tr("Create identities"), fwd_icon()
			}
		}
	case .Passwords:
		if !st.vault_done {
			return st.vault_enroll ? tr("Add this computer") : tr("Create vault"), WI_LOCK
		}
	case .Setup:
		if !st.setup_ran {
			return tr("Set up"), WI_ROCKET
		}
	}
	return tr("Next"), fwd_icon()
}

// ---------------------------------------------------------------------------
// Keys
// ---------------------------------------------------------------------------

handle_keys :: proc(st: ^St, ui: ^p.Ctx) {
	for k in ui.input.keys {
		if k.repeat {
			switch k.sym {
			case p.KEY_RETURN, p.KEY_KP_ENTER, p.KEY_ESCAPE:
				continue
			}
		}
		switch k.sym {
		case p.KEY_ESCAPE:
			go_back(st)
		case p.KEY_RETURN, p.KEY_KP_ENTER:
			if !st.consumed_enter && !busy(st) {
				go_next(st)
			}
		case p.KEY_UP, p.KEY_DOWN:
			list_step(st, k.sym == p.KEY_UP ? -1 : 1)
		}
	}
}

// list_step: the arrows move through the page's one list, where it has one.
list_step :: proc(st: ^St, d: int) {
	#partial switch st.step {
	case .Welcome:
		pick_language(st, clamp(st.lang_i + d, 0, len(LANGUAGES) - 1))
	case .Account:
		st.choice = d < 0 ? .Account : .Local
		st.want_focus = true // the chosen card takes the keyboard too
	}
}

pick_language :: proc(st: ^St, i: int) {
	if i == st.lang_i {
		return
	}
	st.lang_i = i
	set_language(LANGUAGES[i].code)
}
