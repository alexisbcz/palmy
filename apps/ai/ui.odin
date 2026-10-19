package main

// The frame.
//
// Left: the identities, each in its colour, with what is waiting there, and
// the selected identity's conversations. "All identities" sits at the top
// and has no assistant: choosing it shows why, and the identities to pick.
// Right: the selected identity's assistant — a header that says in its
// colour whose assistant this is and what it can reach, and one of three
// views: the conversation, the action log, the settings.
//
// What the assistant did is shown inline, in order: every tool it called
// (with the arguments as the runtime ran them), what came back, anything it
// was refused, what it drafted, and every proposal as a card that does
// nothing until you press Confirm.

import "core:fmt"
import "core:strings"
import p "palmy:."
import sc "shadcn:."

// tone is an identity's colour as a class: `tone(v, "bg", 500)`.
tone :: proc(v: ^Ident_View, prefix: string, shade: int) -> string {
	c := v != nil && v.color != "" ? v.color : "zinc"
	return fmt.tprintf("%s-%s-%d", prefix, c, shade)
}

build :: proc(ui: ^p.Ctx, st: ^St) {
	sidebar(ui, st)
	main_col := p.col(ui, "flex-1 min-w-0 h-full overflow-hidden")
	st.main_id = p.node_id(ui, main_col)
	v := cur_ident(st)
	if !st.online && !st.fixture {
		offline(ui, st)
	} else if v == nil {
		all_identities(ui, st)
	} else {
		topbar(ui, st, v)
		switch st.view {
		case .Chat:
			transcript(ui, st, v)
			composer(ui, st, v)
		case .Log:
			log_view(ui, st, v)
		case .Settings:
			settings_view(ui, st, v)
		}
	}
	footer(ui, st)
	p.end(ui)
	if st.remote_ask {
		remote_dialog(ui, st)
	}
}

// ---------------------------------------------------------------------------
// Sidebar
// ---------------------------------------------------------------------------

sidebar :: proc(ui: ^p.Ctx, st: ^St) {
	p.col(ui, "h-full shrink-0 border-r border-border bg-sidebar overflow-hidden")
	p.style(ui).w = p.px(SIDEBAR_W)
	defer p.end(ui)

	p.row(ui, "w-full items-center gap-2.5 px-4 shrink-0 border-b border-border")
	p.style(ui).h = p.px(TOPBAR_H)
	p.div(ui, "size-7 shrink-0 flex-row items-center justify-center rounded-lg bg-primary")
	p.icon(ui, IC_SPARKLES, "size-4 text-primary-foreground")
	p.end(ui)
	p.col(ui, "flex-1 min-w-0")
	p.text(ui, "Assistant", "text-sm font-semibold whitespace-nowrap")
	p.text(ui, "one per identity", "text-[10.5] text-muted-foreground whitespace-nowrap")
	p.end(ui)
	p.end(ui)

	p.col(ui, "w-full shrink-0 px-2 pt-3 pb-2 gap-0.5")
	p.text(ui, "IDENTITIES", "px-2 pb-1 text-[10] font-semibold tracking-wide text-muted-foreground whitespace-nowrap")
	ident_row(ui, st, -1)
	for _, k in st.idents {
		p.key(ui, fmt.tprintf("id%d", k))
		ident_row(ui, st, k)
	}
	p.end(ui)

	v := cur_ident(st)
	if v != nil {
		sc.separator(ui, .Horizontal)
		p.row(ui, "w-full shrink-0 px-2.5 pt-2.5 pb-1.5 items-center gap-2")
		idx := p.div(ui, "flex-1 flex-row h-8 items-center gap-2 px-2.5 rounded-lg border border-border bg-background hover:bg-muted transition cursor-pointer")
		if p.clickable(ui, idx) {new_conversation(st)}
		p.icon(ui, sc.ICON_PLUS, "size-3.5 shrink-0 text-muted-foreground")
		p.text(ui, "New conversation", "text-xs font-medium whitespace-nowrap")
		p.style(ui).shrink = 0
		p.spacer(ui)
		sc.kbd(ui, "^N")
		p.end(ui)
		p.end(ui)
		p.col(ui, "w-full flex-1 min-h-0 px-2 pb-2 gap-0.5 overflow-scroll")
		for c, k in st.convs {
			p.key(ui, c.id)
			sel := c.id == st.conv
			row := p.row(ui, "w-full shrink-0 items-center gap-2 px-2 py-1.5 rounded-lg transition cursor-pointer")
			p.apply(ui, sel ? "bg-sidebar-accent" : "hover:bg-muted", row)
			if p.clickable(ui, row) && !st.sh.running {
				open_conv(st, c.id)
				st.view = .Chat
			}
			p.icon(ui, IC_MESSAGE_SQUARE, sel ? "size-3 shrink-0 text-foreground" : "size-3 shrink-0 text-muted-foreground")
			p.text(ui, c.title, "flex-1 min-w-0 text-xs truncate whitespace-nowrap")
			p.end(ui)
			_ = k
		}
		if len(st.convs) == 0 {
			p.text(ui, "No conversations yet", "text-xs text-muted-foreground p-2")
		}
		p.end(ui)
	} else {
		p.spacer(ui)
	}

	// What answers, and how it is held.
	sc.separator(ui, .Horizontal)
	p.col(ui, "w-full shrink-0 gap-1 px-3 py-2.5")
	pv := probe_view(&st.probe, context.temp_allocator)
	p.row(ui, "w-full items-center gap-2")
	up := pv.err == "" || st.fixture
	dot := p.div(ui, "size-2 shrink-0 rounded-full")
	p.apply(ui, up ? "bg-emerald-500" : "bg-destructive", dot)
	p.end(ui)
	p.text(ui, up ? "local models: ollama" : "ollama is not running", "text-[11] font-medium whitespace-nowrap")
	p.end(ui)
	p.row(ui, "w-full items-center gap-1.5")
	p.icon(ui, IC_SHIELD_CHECK, "size-3 shrink-0 text-muted-foreground")
	p.text(ui, st.sandbox != "" ? st.sandbox : "sandboxed: Landlock · seccomp", "text-[10.5] text-muted-foreground whitespace-nowrap truncate")
	p.end(ui)
	p.end(ui)
}

ident_row :: proc(ui: ^p.Ctx, st: ^St, k: int) {
	sel := st.sel == k
	row := p.row(ui, "w-full shrink-0 items-center gap-2.5 px-2 py-1.5 rounded-lg transition cursor-pointer")
	p.apply(ui, sel ? "bg-sidebar-accent" : "hover:bg-muted", row)
	if p.clickable(ui, row) {
		select_identity(st, k)
	}
	defer p.end(ui)
	if k < 0 {
		p.div(ui, "size-6 shrink-0 flex-row items-center justify-center rounded-md border border-dashed border-border")
		p.icon(ui, IC_USERS, "size-3.5 text-muted-foreground")
		p.end(ui)
		p.col(ui, "flex-1 min-w-0")
		p.text(ui, "All identities", "text-xs font-medium whitespace-nowrap")
		p.text(ui, "no assistant here", "text-[10.5] text-muted-foreground whitespace-nowrap")
		p.end(ui)
		sc.kbd(ui, "^0")
		return
	}
	v := &st.idents[k]
	sw := p.div(ui, "size-6 shrink-0 flex-row items-center justify-center rounded-md")
	p.apply(ui, tone(v, "bg", 500), sw)
	p.text(ui, strings.to_upper(v.name[:min(1, len(v.name))], context.temp_allocator), "text-[11] font-semibold text-white")
	p.end(ui)
	p.col(ui, "flex-1 min-w-0")
	p.text(ui, v.name, "text-xs font-medium whitespace-nowrap truncate")
	sub := !v.enabled ? "assistant off" : (v.provider == "anthropic" ? fmt.tprintf("remote · %s", v.remote_model) : fmt.tprintf("local · %s", v.model))
	p.text(ui, sub, "text-[10.5] text-muted-foreground whitespace-nowrap truncate")
	p.end(ui)
	if v.pending > 0 {
		b := p.div(ui, "shrink-0 h-5 min-w-5 px-1.5 flex-row items-center justify-center rounded-full")
		p.apply(ui, tone(v, "bg", 500), b)
		p.textf(ui, "text-[10.5] font-semibold text-white whitespace-nowrap", "%d", v.pending)
		p.end(ui)
	} else {
		sc.kbd(ui, fmt.tprintf("^%d", k + 1))
	}
}

// ---------------------------------------------------------------------------
// All identities: no assistant, and why
// ---------------------------------------------------------------------------

all_identities :: proc(ui: ^p.Ctx, st: ^St) {
	p.col(ui, "w-full flex-1 min-h-0 items-center justify-center px-8 overflow-scroll")
	defer p.end(ui)
	box := p.col(ui, "items-center gap-4 text-center")
	p.style(ui, box).max_w = p.px(520)
	p.div(ui, "size-12 flex-row items-center justify-center rounded-2xl bg-muted")
	p.icon(ui, IC_USERS, "size-6 text-muted-foreground")
	p.end(ui)
	p.text(ui, "The assistant works inside one identity", "text-lg font-semibold whitespace-nowrap")
	t := p.text(ui, "Choose one to ask it. There is no assistant that reads across your identities: answering across them would be exactly the reach the separation exists to prevent. Each identity's assistant holds a session scoped to it alone, and the database refuses it everything else.", "text-sm text-muted-foreground text-center")
	p.style(ui, t).max_w = p.px(500)
	p.row(ui, "flex-wrap justify-center gap-2 pt-2")
	for _, k in st.idents {
		v := &st.idents[k]
		p.key(ui, fmt.tprintf("pick%d", k))
		b := p.row(ui, "items-center gap-2 h-9 pl-2 pr-3 rounded-lg border border-border bg-background hover:bg-muted transition cursor-pointer")
		if p.clickable(ui, b) {select_identity(st, k)}
		d := p.div(ui, "size-3 rounded-full")
		p.apply(ui, tone(v, "bg", 500), d)
		p.end(ui)
		p.textf(ui, "text-sm font-medium whitespace-nowrap", "Ask the %s assistant", v.name)
		sc.kbd(ui, fmt.tprintf("^%d", k + 1))
		p.end(ui)
	}
	p.end(ui)
	p.end(ui)
}

offline :: proc(ui: ^p.Ctx, st: ^St) {
	p.col(ui, "w-full flex-1 min-h-0 items-center justify-center gap-3 px-8")
	defer p.end(ui)
	p.icon(ui, IC_LOCK, "size-6 text-muted-foreground")
	p.text(ui, "Not signed in", "text-lg font-semibold whitespace-nowrap")
	t := p.text(ui, st.offline, "text-sm text-muted-foreground text-center")
	p.style(ui, t).max_w = p.px(520)
	p.text(ui, "Sign in with Accounts; then each identity's assistant can be turned on here.", "text-sm text-muted-foreground whitespace-nowrap")
}

// ---------------------------------------------------------------------------
// Top bar
// ---------------------------------------------------------------------------

topbar :: proc(ui: ^p.Ctx, st: ^St, v: ^Ident_View) {
	bar := p.row(ui, "w-full shrink-0 items-center gap-3 px-5 border-b border-border")
	p.style(ui).h = p.px(TOPBAR_H)
	defer p.end(ui)
	_ = bar
	// The identity band: whose assistant, in its colour, and its reach in
	// one sentence.
	band := p.div(ui, "w-1 h-8 rounded-full shrink-0")
	p.apply(ui, tone(v, "bg", 500), band)
	p.end(ui)
	p.col(ui, "min-w-0 shrink-0")
	p.textf(ui, "text-sm font-semibold whitespace-nowrap", "The %s assistant", v.name)
	p.textf(ui, "text-[11] text-muted-foreground whitespace-nowrap", "Sees %s only · %s", v.name, v.address != "" ? v.address : fmt.tprintf("%s@palm.test", v.handle))
	p.end(ui)
	p.spacer(ui)
	// The model chip: what answers, and whether it leaves the machine.
	chip := p.row(ui, "shrink-0 items-center gap-1.5 h-7 px-2.5 rounded-lg border")
	remote := v.provider == "anthropic"
	p.apply(ui, remote ? "border-amber-500/50 bg-amber-500/10" : "border-border bg-background", chip)
	p.icon(ui, remote ? IC_GLOBE : IC_CPU, remote ? "size-3.5 shrink-0 text-amber-600" : "size-3.5 shrink-0 text-muted-foreground")
	p.text(ui, remote ? v.remote_model : v.model, "text-xs font-medium whitespace-nowrap")
	p.text(ui, remote ? "· remote, opted in" : "· on this machine", "text-xs text-muted-foreground whitespace-nowrap")
	p.end(ui)
	tab(ui, st, .Chat, "Conversation", IC_MESSAGE_SQUARE, "")
	tab(ui, st, .Log, "Action log", IC_SCROLL_TEXT, v.pending > 0 ? fmt.tprintf("%d", v.pending) : "")
	tab(ui, st, .Settings, "Settings", sc.ICON_SETTINGS, "")
}

tab :: proc(ui: ^p.Ctx, st: ^St, view: View, label: string, ic: p.Icon, badge: string) {
	on := st.view == view
	t := p.row(ui, "shrink-0 items-center gap-1.5 h-8 px-2.5 rounded-lg transition cursor-pointer")
	p.apply(ui, on ? "bg-muted text-foreground" : "text-muted-foreground hover:bg-muted", t)
	if p.clickable(ui, t) {
		st.view = view
		if view == .Log {load_log(st)}
	}
	p.icon(ui, ic, "size-3.5 shrink-0")
	p.text(ui, label, "text-xs font-medium whitespace-nowrap")
	if badge != "" {
		sc.badge(ui, badge, .Default)
	}
	p.end(ui)
}

// ---------------------------------------------------------------------------
// Transcript
// ---------------------------------------------------------------------------

transcript :: proc(ui: ^p.Ctx, st: ^St, v: ^Ident_View) {
	tr := p.col(ui, "w-full flex-1 min-h-0 px-6 py-5 gap-3 overflow-scroll")
	st.tr_id = p.node_id(ui, tr)
	defer p.end(ui)
	width := p.size(ui).x - SIDEBAR_W - 48
	maxw := min(f32(860), max(f32(360), width))

	if len(st.items) == 0 {
		empty_chat(ui, st, v)
	}
	for _, k in st.items {
		p.key(ui, fmt.tprintf("it%d", k))
		item_view(ui, st, v, &st.items[k], k, maxw)
	}
	if st.sh.running {
		p.row(ui, "shrink-0 items-center gap-2 rounded-xl bg-muted px-3 py-2")
		p.icon(ui, sc.ICON_LOADER_CIRCLE, "size-3.5 shrink-0 text-muted-foreground", f32(mono()) * 0.8)
		p.textf(ui, "text-xs text-muted-foreground whitespace-nowrap", "working inside %s · %.0f s", v.name, mono() - st.started_at)
		p.end(ui)
		ui.animating = true
	}
	endm := p.div(ui, "w-full shrink-0")
	p.style(ui).h = p.px(1)
	st.end_id = p.node_id(ui, endm)
	p.end(ui)
	if st.pinned {
		p.scroll_into_view(ui, st.tr_id, st.end_id, 4)
	}
}

empty_chat :: proc(ui: ^p.Ctx, st: ^St, v: ^Ident_View) {
	box := p.col(ui, "w-full items-start gap-3 pt-6")
	p.style(ui, box).max_w = p.px(640)
	p.textf(ui, "text-lg font-semibold whitespace-nowrap", "Ask the %s assistant", v.name)
	t := p.textf(ui, "text-sm text-muted-foreground", "It can read %s's mail, files, calendar and notes, and write drafts there. Anything that leaves %s — sending, sharing, inviting — comes back to you as a card to confirm. It cannot see your other identities at all.", v.name, v.name)
	p.style(ui, t).max_w = p.px(620)
	if !v.enabled {
		p.row(ui, "items-center gap-2 rounded-lg border border-border px-3 py-2")
		p.icon(ui, sc.ICON_INFO, "size-3.5 shrink-0 text-muted-foreground")
		p.textf(ui, "text-xs whitespace-nowrap", "The %s assistant is off. Turn it on in Settings (F4).", v.name)
		p.end(ui)
	}
	p.col(ui, "gap-1.5 pt-2")
	for s in ([?]string{"Summarise my unread mail.", "Find the signed Halden invoice in my files and draft a reply to Noor attaching it.", "Noor asked for a roadmap review. Schedule it in my calendar as she proposed."}) {
		b := p.row(ui, "items-center gap-2 h-8 px-3 rounded-lg border border-border bg-background hover:bg-muted transition cursor-pointer")
		if p.clickable(ui, b) {
			clear(&st.input)
			append(&st.input, ..transmute([]u8)s)
			st.caret = len(st.input)
		}
		p.icon(ui, sc.ICON_ARROW_RIGHT, "size-3 shrink-0 text-muted-foreground")
		p.text(ui, s, "text-xs whitespace-nowrap")
		p.end(ui)
	}
	p.end(ui)
	p.end(ui) // box
}

tool_icon :: proc(tool: string) -> p.Icon {
	switch {
	case strings.has_prefix(tool, "mail_draft"), strings.has_prefix(tool, "mail_send"):
		return IC_MAIL_PLUS
	case strings.has_prefix(tool, "mail"):
		return sc.ICON_MAIL
	case strings.has_prefix(tool, "drive"):
		return sc.ICON_FOLDER
	case strings.has_prefix(tool, "calendar_add"):
		return IC_CALENDAR_PLUS
	case strings.has_prefix(tool, "calendar"):
		return sc.ICON_CALENDAR
	case strings.has_prefix(tool, "notes"):
		return IC_NOTEBOOK_PEN
	case strings.has_prefix(tool, "chat"):
		return IC_MESSAGE_CIRCLE
	case strings.has_prefix(tool, "index"):
		return sc.ICON_SEARCH
	}
	return IC_WRENCH
}

item_view :: proc(ui: ^p.Ctx, st: ^St, v: ^Ident_View, it: ^Item, k: int, maxw: f32) {
	switch it.kind {
	case .User:
		row := p.col(ui, "w-full shrink-0 items-end gap-1 pt-2")
		_ = row
		b := p.col(ui, sc.BUBBLE_CONTENT_BASE)
		p.apply(ui, sc.bubble_content_class(.Secondary), b)
		p.style(ui, b).max_w = p.px(maxw * 0.8)
		t := p.text(ui, it.text, "text-sm")
		p.style(ui, t).max_w = p.px(maxw * 0.8 - 26)
		p.end(ui)
		p.end(ui)
	case .Step, .Draft:
		step_view(ui, st, it, maxw)
	case .Refused:
		r := p.row(ui, "shrink-0 items-start gap-2 rounded-lg border border-amber-500/40 bg-amber-500/10 px-3 py-2")
		p.style(ui, r).max_w = p.px(maxw)
		p.icon(ui, IC_BAN, "size-3.5 shrink-0 text-amber-600 mt-[1]")
		t := p.textf(ui, "text-xs", "Not done — %s: %s", it.tool, it.text)
		p.style(ui, t).max_w = p.px(maxw - 40)
		p.end(ui)
	case .Proposal:
		proposal_view(ui, st, v, it, maxw)
	case .Answer:
		b := p.col(ui, sc.BUBBLE_CONTENT_BASE)
		p.apply(ui, sc.bubble_content_class(.Muted), b)
		// shrink-0: in an overflowing column flexbox shrinks whatever may shrink,
		// and a bubble that may shrink is a bubble that disappears.
		p.apply(ui, "min-w-0 shrink-0", b)
		// An explicit width: a shrink-to-fit bubble measures its text against the
		// width it had last frame, and the two can chase each other to nothing.
		p.style(ui, b).w = p.px(maxw)
		md_render(ui, it.text, maxw - 26, 14)
		p.end(ui)
	case .Notice:
		r := p.row(ui, "shrink-0 items-start gap-2.5 rounded-xl border px-3.5 py-3")
		p.apply(ui, tone(v, "border", 500), r)
		p.style(ui, r).max_w = p.px(maxw)
		p.icon(ui, IC_SHIELD_ALERT, "size-4 shrink-0 mt-[1]")
		t := p.text(ui, it.text, "text-sm")
		p.style(ui, t).max_w = p.px(maxw - 50)
		p.end(ui)
	case .Error:
		r := p.row(ui, "shrink-0 items-start gap-2 rounded-lg border border-destructive/40 bg-destructive/10 px-3 py-2")
		p.style(ui, r).max_w = p.px(maxw)
		p.icon(ui, sc.ICON_CIRCLE_ALERT, "size-3.5 shrink-0 text-destructive mt-[1]")
		t := p.text(ui, it.text, "text-xs")
		p.style(ui, t).max_w = p.px(maxw - 40)
		p.end(ui)
	}
}

step_view :: proc(ui: ^p.Ctx, st: ^St, it: ^Item, maxw: f32) {
	box := p.col(ui, "shrink-0 rounded-lg border border-border bg-background overflow-hidden")
	p.style(ui, box).w = p.px(maxw)
	defer p.end(ui)
	head := p.row(ui, "w-full items-center gap-2 px-3 py-1.5 cursor-pointer hover:bg-muted/60")
	if p.clickable(ui, head) {it.open = !it.open}
	p.icon(ui, tool_icon(it.tool), "size-3.5 shrink-0 text-muted-foreground")
	p.text(ui, it.tool, "text-xs font-mono font-medium whitespace-nowrap")
	p.text(ui, it.text, "flex-1 min-w-0 text-xs font-mono text-muted-foreground whitespace-nowrap truncate")
	if it.class == "draft" {
		sc.badge(ui, "draft · not sent", .Secondary)
	}
	if it.untrusted && it.done && it.ok {
		sc.badge(ui, "untrusted content", .Outline)
	}
	if !it.done {
		p.icon(ui, sc.ICON_LOADER_CIRCLE, "size-3.5 shrink-0 text-muted-foreground", f32(mono()) * 0.8)
	} else if it.ok {
		p.icon(ui, sc.ICON_CIRCLE_CHECK, "size-3.5 shrink-0 text-emerald-600")
	} else {
		p.icon(ui, sc.ICON_CIRCLE_ALERT, "size-3.5 shrink-0 text-destructive")
	}
	p.icon(ui, it.open ? sc.ICON_CHEVRON_UP : sc.ICON_CHEVRON_DOWN, "size-3 shrink-0 text-muted-foreground")
	p.end(ui)
	if it.done && it.result != "" {
		r := p.row(ui, "w-full items-center gap-2 px-3 pb-1.5")
		_ = r
		p.text(ui, "→", "text-xs text-muted-foreground")
		p.text(ui, it.result, "flex-1 min-w-0 text-xs truncate whitespace-nowrap")
		p.end(ui)
	}
	if it.open && it.data != "" {
		d := p.col(ui, "w-full border-t border-border bg-muted/40 px-3 py-2")
		_ = d
		shown := it.data
		if len(shown) > 2400 {shown = fmt.tprintf("%s…", shown[:2400])}
		t := p.text(ui, shown, "text-[11] font-mono leading-[16] text-muted-foreground")
		p.style(ui, t).max_w = p.px(maxw - 26)
		p.end(ui)
	}
}

proposal_view :: proc(ui: ^p.Ctx, st: ^St, v: ^Ident_View, it: ^Item, maxw: f32) {
	card := p.col(ui, "shrink-0 rounded-xl border-2 bg-background overflow-hidden")
	p.apply(ui, tone(v, "border", 500), card)
	p.style(ui, card).w = p.px(maxw)
	defer p.end(ui)
	head := p.row(ui, "w-full items-center gap-2 px-3.5 py-2")
	p.apply(ui, tone(v, "bg", 500), head)
	p.icon(ui, IC_HAND, "size-3.5 shrink-0 text-white")
	p.textf(ui, "text-xs font-semibold text-white whitespace-nowrap", "Waiting for you · as %s", v.name)
	p.spacer(ui)
	p.text(ui, it.tool, "text-[11] font-mono text-white/80 whitespace-nowrap")
	p.end(ui)
	body := p.col(ui, "w-full gap-2 px-3.5 py-3")
	_ = body
	t := p.text(ui, it.text, "text-sm font-medium")
	p.style(ui, t).max_w = p.px(maxw - 30)
	for w in it.warnings {
		r := p.row(ui, "w-full items-start gap-2")
		_ = r
		warn := w.level == "warn"
		p.icon(ui, warn ? sc.ICON_TRIANGLE_ALERT : sc.ICON_INFO, warn ? "size-3.5 shrink-0 text-amber-600 mt-[1]" : "size-3.5 shrink-0 text-muted-foreground mt-[1]")
		wt := p.text(ui, w.text, warn ? "text-xs" : "text-xs text-muted-foreground")
		p.style(ui, wt).max_w = p.px(maxw - 60)
		p.end(ui)
	}
	p.end(ui)
	foot := p.row(ui, "w-full items-center gap-2 px-3.5 py-2.5 border-t border-border bg-muted/30")
	_ = foot
	switch it.status {
	case "proposed":
		if btn(ui, "Decline", .Outline, .SM) {
			decide_action(st, it.action_id, false)
		}
		yes := p.row(ui, "shrink-0 items-center gap-1.5 h-8 px-3 rounded-md cursor-pointer transition")
		p.apply(ui, tone(v, "bg", 600), yes)
		p.apply(ui, fmt.tprintf("hover:%s", tone(v, "bg", 700)), yes)
		if p.clickable(ui, yes) {
			decide_action(st, it.action_id, true)
		}
		p.icon(ui, sc.ICON_CHECK, "size-3.5 shrink-0 text-white")
		p.textf(ui, "text-xs font-semibold text-white whitespace-nowrap", "Confirm as %s", v.name)
		p.end(ui)
		p.spacer(ui)
		p.text(ui, "Nothing happens until you confirm. F6", "text-[11] text-muted-foreground whitespace-nowrap")
	case "executed":
		p.icon(ui, sc.ICON_CIRCLE_CHECK, "size-3.5 shrink-0 text-emerald-600")
		p.text(ui, "Done, by you", "text-xs font-medium whitespace-nowrap")
	case "declined":
		p.icon(ui, sc.ICON_X, "size-3.5 shrink-0 text-muted-foreground")
		p.text(ui, "Declined · nothing was done", "text-xs text-muted-foreground whitespace-nowrap")
	case:
		p.icon(ui, sc.ICON_CIRCLE_ALERT, "size-3.5 shrink-0 text-destructive")
		p.textf(ui, "text-xs whitespace-nowrap", "%s", it.status)
	}
	p.end(ui)
}

// ---------------------------------------------------------------------------
// Composer
// ---------------------------------------------------------------------------

composer :: proc(ui: ^p.Ctx, st: ^St, v: ^Ident_View) {
	p.col(ui, "w-full shrink-0 px-6 pt-3 pb-3 gap-2 border-t border-border")
	defer p.end(ui)
	box := p.row(ui, "w-full items-end gap-2 rounded-xl border bg-background px-3 py-2.5 transition")
	st.composer_id = p.node_id(ui, box)
	p.apply(ui, fmt.tprintf("%s ring-3 %s/25", tone(v, "border", 500), tone(v, "ring", 500)), box)
	{
		p.col(ui, "flex-1 min-w-0 gap-0 overflow-hidden")
		defer p.end(ui)
		text := string(st.input[:])
		if text == "" {
			p.row(ui, "w-full items-center")
			p.style(ui).h = p.px(20)
			p.textf(ui, "text-sm text-muted-foreground whitespace-nowrap", "Ask the %s assistant. Enter sends.", v.name)
			car := p.div(ui, "absolute w-[1.5] rounded-full bg-foreground")
			cs := p.style(ui, car)
			cs.inset[p.LEFT] = p.px(0)
			cs.inset[p.TOP] = p.px(2)
			cs.h = p.px(16)
			p.end(ui)
			p.end(ui)
		} else {
			t := p.text(ui, text, "text-sm")
			p.style(ui, t).max_w = p.px(p.size(ui).x - SIDEBAR_W - 180)
		}
	}
	if st.sh.running {
		idx := p.row(ui, "shrink-0 items-center gap-1.5 h-8 px-3 rounded-lg bg-destructive/15 border border-destructive/40 hover:bg-destructive/25 transition cursor-pointer")
		if p.clickable(ui, idx) {stop(st)}
		p.icon(ui, IC_SQUARE, "size-3.5 shrink-0 text-destructive")
		p.text(ui, "Stop", "text-xs font-medium text-destructive whitespace-nowrap")
		p.end(ui)
	} else {
		empty := strings.trim_space(string(st.input[:])) == ""
		idx := p.row(ui, "shrink-0 items-center gap-1.5 h-8 px-3 rounded-lg transition cursor-pointer")
		p.apply(ui, empty ? "bg-muted text-muted-foreground" : fmt.tprintf("%s text-white", tone(v, "bg", 600)), idx)
		if p.clickable(ui, idx) && !empty {send(st)}
		p.icon(ui, sc.ICON_SEND, "size-3.5 shrink-0")
		p.text(ui, "Ask", "text-xs font-medium whitespace-nowrap")
		p.end(ui)
	}
	p.end(ui)
	p.row(ui, "w-full items-center gap-1.5 px-1")
	p.icon(ui, IC_SHIELD_CHECK, "size-3 shrink-0 text-muted-foreground")
	p.textf(ui, "text-[11] text-muted-foreground whitespace-nowrap truncate", "Reads and drafts inside %s. Sending, sharing and inviting wait for you. Mail and files it reads are treated as data, never as instructions.", v.name)
	p.end(ui)
}

// ---------------------------------------------------------------------------
// The action log
// ---------------------------------------------------------------------------

status_class :: proc(s: string) -> string {
	switch s {
	case "proposed":
		return "bg-amber-500/15 text-amber-700"
	case "executed", "done":
		return "bg-emerald-500/15 text-emerald-700"
	case "declined", "expired":
		return "bg-muted text-muted-foreground"
	}
	return "bg-destructive/15 text-destructive"
}

log_view :: proc(ui: ^p.Ctx, st: ^St, v: ^Ident_View) {
	p.col(ui, "w-full flex-1 min-h-0 px-6 py-5 gap-3 overflow-scroll")
	defer p.end(ui)
	p.textf(ui, "text-sm font-semibold whitespace-nowrap", "Everything the %s assistant did", v.name)
	t := p.text(ui, "Every read, every draft, every refusal and every proposal, newest first. The database records which assistant session wrote each row; only you can move a proposal on, and a row's arguments cannot be changed once written.", "text-xs text-muted-foreground")
	p.style(ui, t).max_w = p.px(760)
	tbl := p.col(ui, "w-full rounded-lg border border-border overflow-hidden")
	_ = tbl
	hdr := p.row(ui, "w-full items-center gap-3 px-3 py-2 bg-muted/50 border-b border-border")
	_ = hdr
	cols := [?]struct {
		label: string,
		w:     f32,
	}{{"When", 70}, {"Status", 82}, {"Class", 64}, {"Tool", 130}}
	for c in cols {
		x := p.text(ui, c.label, "text-[11] font-semibold text-muted-foreground whitespace-nowrap")
		p.style(ui, x).w = p.px(c.w)
	}
	p.text(ui, "What", "flex-1 text-[11] font-semibold text-muted-foreground whitespace-nowrap")
	p.end(ui)
	if len(st.log) == 0 {
		p.text(ui, "Nothing yet.", "text-xs text-muted-foreground p-3")
	}
	for _, k in st.log {
		r := &st.log[k]
		p.key(ui, r.id)
		row := p.row(ui, "w-full items-start gap-3 px-3 py-2 border-b border-border")
		_ = row
		when_ := r.created
		if len(when_) >= 16 {when_ = when_[11:16]}
		w1 := p.text(ui, when_, "text-[11] font-mono text-muted-foreground whitespace-nowrap")
		p.style(ui, w1).w = p.px(70)
		sb := p.row(ui, "shrink-0 items-center")
		p.style(ui, sb).w = p.px(82)
		pill := p.div(ui, "h-5 px-1.5 flex-row items-center rounded-md")
		p.apply(ui, status_class(r.status), pill)
		p.text(ui, r.status, "text-[10.5] font-medium whitespace-nowrap")
		p.end(ui)
		p.end(ui)
		w3 := p.text(ui, r.class, "text-[11] text-muted-foreground whitespace-nowrap")
		p.style(ui, w3).w = p.px(64)
		w4 := p.row(ui, "shrink-0 items-center gap-1.5")
		p.style(ui, w4).w = p.px(130)
		p.icon(ui, tool_icon(r.tool), "size-3 shrink-0 text-muted-foreground")
		p.text(ui, r.tool, "text-[11] font-mono whitespace-nowrap truncate")
		p.end(ui)
		p.col(ui, "flex-1 min-w-0 gap-1")
		s := p.text(ui, r.summary, "text-xs")
		p.style(ui, s).max_w = p.px(p.size(ui).x - SIDEBAR_W - 460)
		if r.tainted && r.class == "confirm" {
			p.row(ui, "items-center gap-1")
			p.icon(ui, IC_EYE_OFF, "size-3 shrink-0 text-amber-600")
			p.text(ui, "proposed after reading content from outside you", "text-[10.5] text-amber-700 whitespace-nowrap")
			p.end(ui)
		}
		for w in r.warnings {
			if w.level != "warn" {continue}
			wt := p.textf(ui, "text-[10.5] text-amber-700", "! %s", w.text)
			p.style(ui, wt).max_w = p.px(p.size(ui).x - SIDEBAR_W - 460)
		}
		if r.status == "proposed" {
			p.row(ui, "items-center gap-2 pt-1")
			if btn(ui, "Decline", .Outline, .SM) {decide_action(st, r.id, false)}
			if btn(ui, "Confirm", .Default, .SM) {decide_action(st, r.id, true)}
			p.end(ui)
		}
		p.end(ui)
		p.end(ui)
	}
	p.end(ui)
}

// ---------------------------------------------------------------------------
// Settings
// ---------------------------------------------------------------------------

settings_view :: proc(ui: ^p.Ctx, st: ^St, v: ^Ident_View) {
	p.col(ui, "w-full flex-1 min-h-0 px-6 py-5 gap-4 overflow-scroll")
	defer p.end(ui)
	section := proc(ui: ^p.Ctx, title, sub: string) {
		p.col(ui, "w-full gap-0.5 pt-1")
		p.text(ui, title, "text-sm font-semibold whitespace-nowrap")
		t := p.text(ui, sub, "text-xs text-muted-foreground")
		p.style(ui, t).max_w = p.px(720)
		p.end(ui)
	}
	section(ui, fmt.tprintf("The %s assistant", v.name), "Off by default for every identity. Turning it off changes nothing else: search, Today and every app work as before.")
	r := p.row(ui, "items-center gap-3 rounded-lg border border-border px-3 py-2.5 cursor-pointer")
	if p.clickable(ui, r) {set_enabled(st, !v.enabled)}
	sc.switch_(ui, v.enabled, .Default)
	p.text(ui, v.enabled ? "On" : "Off", "text-sm font-medium whitespace-nowrap")
	p.end(ui)

	section(ui, "Model on this machine", "The default. The model runs here, through ollama on 127.0.0.1, and nothing it reads leaves the machine. Small models are often wrong; every proposal still waits for you.")
	pv := probe_view(&st.probe, context.temp_allocator)
	models := make([dynamic]string, context.temp_allocator)
	for m in pv.models {append(&models, m.name)}
	if len(models) == 0 {append(&models, v.model)}
	p.row(ui, "flex-wrap items-center gap-2")
	for m in models {
		on := m == v.model && v.provider != "anthropic"
		b := p.row(ui, "items-center gap-2 h-8 px-3 rounded-lg border transition cursor-pointer")
		p.apply(ui, on ? fmt.tprintf("%s bg-muted", tone(v, "border", 500)) : "border-border hover:bg-muted", b)
		if p.clickable(ui, b) {
			set_model(st, m)
			if v.provider == "anthropic" {set_remote(st, false)}
		}
		p.icon(ui, IC_CPU, "size-3.5 shrink-0 text-muted-foreground")
		p.text(ui, m, "text-xs font-medium whitespace-nowrap")
		if on {p.icon(ui, sc.ICON_CHECK, "size-3.5 shrink-0")}
		p.end(ui)
	}
	p.end(ui)

	section(ui, "A remote model (optional)", fmt.tprintf("Anthropic's Claude (%s), for %s only, and only if you opt in here. A remote model can read whatever the assistant shows it, which is %s's mail and files; that is the trade. The API key stays in your session's environment and never enters the assistant's sandbox.", REMOTE_MODEL_DEFAULT, v.name, v.name))
	if v.provider == "anthropic" {
		p.row(ui, "items-center gap-3 rounded-lg border border-amber-500/50 bg-amber-500/10 px-3 py-2.5")
		p.icon(ui, IC_GLOBE, "size-4 shrink-0 text-amber-600")
		p.textf(ui, "text-xs whitespace-nowrap", "On for %s since %s · %s", v.name, v.opted_in_at, v.remote_model)
		p.spacer(ui)
		if btn(ui, "Back to the local model", .Outline, .SM) {set_remote(st, false)}
		p.end(ui)
	} else {
		p.row(ui, "items-center")
		if btn(ui, fmt.tprintf("Use a remote model for %s…", v.name), .Outline, .Default) {st.remote_ask = true}
		p.end(ui)
	}

	section(ui, "What it can do", "Generated from each application's --schema and narrowed by policy. Reads run freely; drafts stay in the identity; everything else is a proposal.")
	rows := [?][3]string {
		{"Reads", "mail · files · calendar · notes · contacts · chats · issues · search", "runs, logged"},
		{"Drafts", "a mail draft · a new note", "runs, stays in the identity, logged"},
		{"Proposals", "send · share · link · invite · post · comment · delete", "waits for you; done by your session"},
		{"Never", "the vault · other identities · account settings · its own settings", "not offered, and refused by the database"},
	}
	p.col(ui, "w-full rounded-lg border border-border overflow-hidden")
	for rw, k in rows {
		p.key(ui, fmt.tprintf("cap%d", k))
		row := p.row(ui, "w-full items-center gap-3 px-3 py-2 border-b border-border")
		_ = row
		a := p.text(ui, rw[0], "text-xs font-semibold whitespace-nowrap")
		p.style(ui, a).w = p.px(80)
		p.text(ui, rw[1], "flex-1 min-w-0 text-xs truncate whitespace-nowrap")
		p.text(ui, rw[2], "text-[11] text-muted-foreground whitespace-nowrap")
		p.end(ui)
	}
	p.end(ui)
}

remote_dialog :: proc(ui: ^p.Ctx, st: ^St) {
	v := cur_ident(st)
	if v == nil {return}
	scrim := p.div(ui, "absolute w-full h-full flex-row items-center justify-center bg-black/50")
	s := p.style(ui, scrim)
	s.inset[p.LEFT] = p.px(0)
	s.inset[p.TOP] = p.px(0)
	box := p.col(ui, "gap-3 rounded-xl border border-border bg-background p-5 shadow-lg")
	p.style(ui, box).w = p.px(480)
	p.row(ui, "items-center gap-2")
	p.icon(ui, IC_GLOBE, "size-4 text-amber-600")
	p.textf(ui, "text-sm font-semibold whitespace-nowrap", "Use Claude for %s?", v.name)
	p.end(ui)
	t := p.textf(ui, "text-xs text-muted-foreground", "From now on, what the %s assistant reads — mail, files, events — is sent to Anthropic's API to be answered. Your other identities are not affected. You can switch back at any time. The assistant cannot make this choice for itself: the database refuses its session any change to its settings.", v.name)
	p.style(ui, t).max_w = p.px(440)
	p.row(ui, "w-full items-center justify-end gap-2 pt-1")
	if btn(ui, "Cancel", .Outline, .SM) {st.remote_ask = false}
	if btn(ui, fmt.tprintf("Opt %s in", v.name), .Default, .SM) {
		set_remote(st, true)
		st.remote_ask = false
	}
	p.end(ui)
	p.end(ui)
	p.end(ui)
}

// ---------------------------------------------------------------------------
// Footer
// ---------------------------------------------------------------------------

footer :: proc(ui: ^p.Ctx, st: ^St) {
	f := p.row(ui, "w-full shrink-0 items-center gap-3 px-4 border-t border-border")
	st.footer_id = p.node_id(ui, f)
	p.style(ui).h = p.px(FOOTER_H)
	defer p.end(ui)
	if st.toast != "" {
		p.icon(ui, sc.ICON_INFO, "size-3 shrink-0 text-muted-foreground")
		p.text(ui, st.toast, "flex-1 text-[11] text-muted-foreground truncate whitespace-nowrap")
		return
	}
	hint(ui, "Enter", "ask")
	hint(ui, "Esc", "stop")
	hint(ui, "^0–9", "identity")
	hint(ui, "^L", "action log")
	hint(ui, "^,", "settings")
	hint(ui, "F6", "confirm")
	p.spacer(ui)
	p.text(ui, "no assistant reads across identities", "text-[10.5] text-muted-foreground whitespace-nowrap")
}

hint :: proc(ui: ^p.Ctx, key, label: string) {
	p.row(ui, "shrink-0 items-center gap-1")
	sc.kbd(ui, key)
	p.text(ui, label, "text-[10.5] text-muted-foreground whitespace-nowrap")
	p.end(ui)
}

// btn is shadcn's button that says whether it was pressed.
btn :: proc(ui: ^p.Ctx, label: string, v := sc.Variant.Default, s := sc.Size.Default) -> bool {
	sc.button_open(ui, v, s, {})
	hit := p.clickable(ui)
	p.text(ui, label, "whitespace-nowrap")
	p.style(ui).shrink = 0
	sc.button_end(ui)
	return hit
}
