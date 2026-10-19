package main

// The parts of the window only cloud mode has: who you are speaking as, the
// spaces you are in, invitations, and calls.
//
// Identity colour is used where cloud/docs/shell.md says it goes and nowhere
// else: the chip in the header, the From card (here, the identity card at the
// foot of the sidebar and the line above the composer), and the primary
// action. Colour is never the only signal: every use carries the name too.

import "core:fmt"
import "core:strings"
import p "palmy:."
import sc "shadcn:."
import w "wire"

RAIL_W :: 60

who_name :: proc(a: ^App, nick, hint: string) -> string {
	if hint != "" {
		return hint
	}
	return display_name(a, nick)
}

who_color :: proc(a: ^App, nick, hint: string) -> string {
	if hint != "" {
		return hint
	}
	return color_of(a, nick)
}

// avatar_who is an avatar in the person's identity colour, with the initials
// of their name, when the space has told us both.
avatar_who :: proc(ui: ^p.Ctx, a: ^App, nick, name, color: string, size := "size-9", text_class := "text-[12.5]") {
	label := who_name(a, nick, name)
	col := who_color(a, nick, color)
	bg := col != "" ? tint(col, "bg", "500") : avatar_bg(nick)
	p.div(ui, p.concat(ui, "shrink-0 flex-row items-center justify-center rounded-full ", size, " ", bg))
	defer p.end(ui)
	p.text(ui, initials(label, context.temp_allocator), p.concat(ui, text_class, " font-semibold text-white whitespace-nowrap"))
	p.style(ui).shrink = 0
}

// id_chip is the identity mark for a header: a dot in the identity's colour,
// its name, on a faint wash of the same colour (shell.md, "Chip").
id_chip :: proc(ui: ^p.Ctx, name, color: string, prefix := "") {
	p.row(ui, p.concat(ui, "shrink-0 items-center gap-1.5 h-6 px-2 rounded-full border ", tint(color, "border", "500/40"), " ", tint(color, "bg", "500/10")))
	defer p.end(ui)
	p.div(ui, p.concat(ui, "size-2 shrink-0 rounded-full ", tint(color, "bg", "500")))
	p.end(ui)
	if prefix != "" {
		p.text(ui, prefix, "text-[11] text-muted-foreground whitespace-nowrap")
		p.style(ui).shrink = 0
	}
	p.text(ui, name, "text-[11.5] font-medium whitespace-nowrap")
	p.style(ui).shrink = 0
}

// ---------------------------------------------------------------------------
// The space rail
// ---------------------------------------------------------------------------

space_rail :: proc(ui: ^p.Ctx, a: ^App) {
	p.col(ui, p.concat(ui, "h-full shrink-0 items-center gap-2 py-3 border-r border-border bg-muted/40 w-[", itoa(ui, RAIL_W), "]"))
	defer p.end(ui)

	for s, i in a.spaces {
		active := s.id == a.cur_space
		unread := 0
		for c in a.chans {
			if c.space == s.id && c.name != (current(a) != nil ? current(a).name : "") {
				unread += c.unread
			}
		}
		p.key(ui, s.id)
		holder := p.row(ui, "w-full shrink-0 items-center justify-center relative")
		// The active space gets the pill at the rail's edge, as Slack and
		// Discord do; the square stays the same size so nothing jumps.
		if active {
			pill := p.div(ui, "absolute w-[4] h-[28] rounded-r-full bg-foreground")
			ps := p.style(ui, pill)
			ps.position = .Absolute
			ps.inset[p.LEFT] = p.px(0)
			ps.inset[p.TOP] = p.px(6)
			p.end(ui)
		}
		box := p.div(ui, "size-10 shrink-0 flex-row items-center justify-center rounded-xl transition")
		p.apply(ui, active ? "bg-primary" : "bg-card border border-border hover:bg-accent", box)
		if p.clickable(ui, box) {
			switch_space(a, i)
		}
		p.text(
			ui,
			initials(s.name, context.temp_allocator),
			active ? "text-[13] font-semibold text-primary-foreground whitespace-nowrap" : "text-[13] font-semibold text-foreground whitespace-nowrap",
		)
		p.style(ui).shrink = 0
		p.end(ui)
		if unread > 0 && !active {
			dot := p.div(ui, "absolute size-[9] rounded-full bg-destructive ring-2 ring-background")
			ds := p.style(ui, dot)
			ds.position = .Absolute
			ds.inset[p.RIGHT] = p.px(8)
			ds.inset[p.TOP] = p.px(0)
			p.end(ui)
		}
		p.end(ui)
		if i < 9 {
			p.text(ui, fmt.tprintf("Alt %d", i + 1), "text-[8.5] text-muted-foreground whitespace-nowrap -mt-1")
			p.style(ui).shrink = 0
		}
	}

	p.spacer(ui)
	if len(a.invites) > 0 {
		p.row(ui, "w-full shrink-0 items-center justify-center relative")
		p.div(ui, "size-10 shrink-0 flex-row items-center justify-center rounded-xl border border-dashed border-primary/60 bg-primary/10")
		p.icon(ui, IC_MAIL, "size-4 text-primary")
		p.end(ui)
		badge := p.div(ui, "absolute h-[16] min-w-[16] flex-row items-center justify-center rounded-full bg-primary px-1")
		bs := p.style(ui, badge)
		bs.position = .Absolute
		bs.inset[p.RIGHT] = p.px(6)
		bs.inset[p.TOP] = p.px(-4)
		p.textf(ui, "text-[9.5] font-semibold text-primary-foreground whitespace-nowrap", "%d", len(a.invites))
		p.end(ui)
		p.end(ui)
		sc.kbd(ui, "F6")
	}
}

// ---------------------------------------------------------------------------
// Who you are speaking as
// ---------------------------------------------------------------------------

// identity_card is the foot of the sidebar in cloud mode: the identity this
// window speaks as, in its colour, with its address. It is the From card of
// every message typed here.
identity_card :: proc(ui: ^p.Ctx, a: ^App) {
	p.row(ui, "w-full h-[56] shrink-0 items-center gap-2.5 px-3 border-t border-border")
	defer p.end(ui)
	if a.link != .Online || a.me.id == "" {
		link_footer_body(ui, a)
		return
	}
	// The colour bar is the identity's mark; the name beside it says the
	// same thing in words.
	p.div(ui, p.concat(ui, "w-[3] h-[36] shrink-0 rounded-full ", tint(a.me.color, "bg", "500")))
	p.end(ui)
	avatar_who(ui, a, a.me.handle, a.me.name, a.me.color, "size-8", "text-[11.5]")
	p.col(ui, "flex-1 min-w-0 gap-0")
	p.row(ui, "w-full items-center gap-1.5")
	p.text(ui, a.me.name, "text-[12.5] font-semibold truncate")
	presence_dot(ui, a.away ? .Away : .Online)
	p.end(ui)
	p.textf(ui, "text-[10.5] text-muted-foreground truncate", "%s · %s", a.me.handle, a.me.kind)
	p.end(ui)
}

// ---------------------------------------------------------------------------
// Calls
// ---------------------------------------------------------------------------

call_banner :: proc(ui: ^p.Ctx, a: ^App) {
	c := current(a)
	if c == nil || c.call == "" {
		return
	}
	p.row(ui, "w-full shrink-0 items-center gap-3 px-5 py-2 border-b border-border bg-emerald-500/10")
	defer p.end(ui)
	p.div(ui, "size-7 shrink-0 flex-row items-center justify-center rounded-full bg-emerald-600")
	p.icon(ui, IC_PHONE, "size-3.5 text-white")
	p.end(ui)
	p.col(ui, "flex-1 min-w-0 gap-0")
	p.row(ui, "items-center gap-1.5")
	p.text(ui, "Call in progress", "text-[12.5] font-semibold whitespace-nowrap")
	p.style(ui).shrink = 0
	p.icon(ui, IC_SHIELD_CHECK, "size-3 shrink-0 text-emerald-600")
	p.text(ui, "end-to-end encrypted", "text-[10.5] text-muted-foreground whitespace-nowrap")
	p.style(ui).shrink = 0
	p.end(ui)
	names := make([dynamic]string, context.temp_allocator)
	for x in c.call_who {
		append(&names, x.name)
	}
	if len(names) == 0 {
		p.text(ui, "Nobody has joined yet", "text-[11] text-muted-foreground truncate")
	} else {
		p.text(ui, strings.join(names[:], ", ", context.temp_allocator), "text-[11] text-muted-foreground truncate")
	}
	p.end(ui)
	// The people in it, overlapping, each in their own colour.
	p.row(ui, "shrink-0 items-center")
	for x, i in c.call_who {
		if i >= 4 {
			break
		}
		p.div(ui, i > 0 ? "-ml-2 rounded-full ring-2 ring-background" : "rounded-full ring-2 ring-background")
		avatar_who(ui, a, x.nick, x.name, x.color, "size-6", "text-[9]")
		p.end(ui)
	}
	p.end(ui)
	btn := p.row(ui, "shrink-0 items-center gap-1.5 h-7 px-3 rounded-md bg-emerald-600 hover:bg-emerald-700 transition")
	if p.clickable(ui, btn) {
		start_call(a)
	}
	p.icon(ui, IC_VIDEO, "size-3.5 shrink-0 text-white")
	p.text(ui, "Join", "text-[12] font-semibold text-white whitespace-nowrap")
	p.style(ui).shrink = 0
	p.end(ui)
	sc.kbd(ui, "Ctrl J")
}

// ---------------------------------------------------------------------------
// Read receipts
// ---------------------------------------------------------------------------

// seen_line says, under the newest message of yours in a channel, who has
// read it. In a DM that is the one "Seen" a person looks for.
seen_line :: proc(ui: ^p.Ctx, a: ^App, c: ^Channel, m: ^w.Msg) {
	who := make([dynamic]string, context.temp_allocator)
	for s in c.seen {
		if s.id >= m.id && s.nick != a.nick {
			append(&who, display_name(a, s.nick))
		}
	}
	if len(who) == 0 {
		return
	}
	p.row(ui, "w-full shrink-0 items-center justify-end gap-1 px-2 pt-0.5")
	defer p.end(ui)
	p.icon(ui, IC_CHECK_CHECK, "size-3 shrink-0 text-sky-500")
	label := c.kind == .DM ? "Seen" : fmt.tprintf("Seen by %s", strings.join(who[:], ", ", context.temp_allocator))
	p.text(ui, label, "text-[10.5] text-muted-foreground whitespace-nowrap")
	p.style(ui).shrink = 0
}

// ---------------------------------------------------------------------------
// Overlays
// ---------------------------------------------------------------------------

invites_overlay :: proc(ui: ^p.Ctx, a: ^App) {
	scrim := p.col(ui, "absolute inset-0 items-center bg-background/70 z-50 pt-[110] px-6")
	p.style(ui, scrim).position = .Absolute
	defer p.end(ui)

	p.col(ui, "w-[520] shrink-0 rounded-xl border border-border bg-popover shadow-lg overflow-hidden")
	defer p.end(ui)
	p.row(ui, "w-full items-center gap-2 px-4 h-12 border-b border-border")
	p.icon(ui, IC_MAIL, "size-4 shrink-0 text-muted-foreground")
	p.text(ui, "Invitations", "flex-1 text-sm font-semibold")
	p.textf(ui, "text-[11] text-muted-foreground whitespace-nowrap", "for %s", a.me.name)
	p.end(ui)

	for v, i in a.invites {
		sel := i == a.sel_invite
		row := p.row(ui, "w-full shrink-0 items-start gap-3 px-4 py-3 border-b border-border")
		if sel {
			p.apply(ui, "bg-accent", row)
		}
		avatar_who(ui, a, v.from_handle, v.from_name, v.from_color, "size-8", "text-[11]")
		p.col(ui, "flex-1 min-w-0 gap-0.5")
		p.row(ui, "items-baseline gap-1.5")
		p.text(ui, v.from_name, "text-[13] font-semibold whitespace-nowrap")
		p.style(ui).shrink = 0
		p.text(ui, "invites you to", "text-[12] text-muted-foreground whitespace-nowrap")
		p.style(ui).shrink = 0
		target := v.ch_name != "" ? fmt.tprintf("#%s", v.ch_name) : v.space_name
		p.text(ui, target, "text-[13] font-semibold truncate")
		p.end(ui)
		grants := v.ch_name != "" \
			? fmt.tprintf("in %s, as a %s: this channel only", v.space_name, v.role) \
			: fmt.tprintf("as a %s: its public channels, and DMs with its members", v.role)
		p.text(ui, grants, "text-[11] text-muted-foreground truncate")
		if sel {
			p.row(ui, "items-center gap-2 pt-1.5")
			// The primary action is in the identity's colour: accepting is
			// done *as* this identity, and it is the one that joins.
			p.row(ui, p.concat(ui, "shrink-0 items-center gap-1.5 h-7 px-3 rounded-md ", tint(a.me.color, "bg", "600")))
			p.icon(ui, IC_CHECK, "size-3.5 shrink-0 text-white")
			p.textf(ui, "text-[12] font-semibold text-white whitespace-nowrap", "Join as %s", a.me.name)
			p.end(ui)
			sc.kbd(ui, "Enter")
			p.div(ui, "w-2")
			p.end(ui)
			p.text(ui, "Decline", "text-[12] text-muted-foreground whitespace-nowrap")
			p.style(ui).shrink = 0
			sc.kbd(ui, "Del")
			p.end(ui)
		}
		p.end(ui)
		p.end(ui)
	}
	p.row(ui, "w-full items-center gap-2 px-4 h-9 bg-muted/40")
	p.text(ui, "An invitation grants exactly what it names, and only to the identity it was sent to.", "flex-1 min-w-0 text-[10.5] text-muted-foreground truncate")
	sc.kbd(ui, "Esc")
	p.end(ui)
}

prompt_overlay :: proc(ui: ^p.Ctx, a: ^App) {
	scrim := p.col(ui, "absolute inset-0 items-center bg-background/70 z-50 pt-[140] px-6")
	p.style(ui, scrim).position = .Absolute
	defer p.end(ui)

	p.col(ui, "w-[480] shrink-0 rounded-xl border border-border bg-popover shadow-lg p-4 gap-3")
	defer p.end(ui)

	sp := space_of(a, a.cur_space)
	space_name := sp != nil ? sp.name : "this space"
	title, hint, ph: string
	c := current(a)
	switch a.prompt {
	case .Invite:
		if c != nil && c.private {
			title = fmt.tprintf("Invite to #%s", chan_label(a, c))
			hint = "They get this private channel only, as a guest of the space."
		} else {
			title = fmt.tprintf("Invite to %s", space_name)
			hint = "They get the space's public channels once they accept."
		}
		ph = "their handle, e.g. bob.northwind"
	case .New_Channel:
		title = fmt.tprintf("New channel in %s", space_name)
		hint = "Add \" private\" at the end for a channel only invited people can read."
		ph = "channel name"
	case .None:
	}
	p.text(ui, title, "text-[15] font-semibold")

	// The From card: who is doing this, before anything is typed.
	p.row(ui, "w-full items-center gap-2.5 px-3 py-2 rounded-lg border border-border bg-muted/40")
	p.div(ui, p.concat(ui, "w-[3] h-[28] shrink-0 rounded-full ", tint(a.me.color, "bg", "500")))
	p.end(ui)
	avatar_who(ui, a, a.me.handle, a.me.name, a.me.color, "size-6", "text-[9.5]")
	p.text(ui, "As", "text-[11.5] text-muted-foreground whitespace-nowrap")
	p.style(ui).shrink = 0
	p.text(ui, a.me.name, "text-[12.5] font-semibold whitespace-nowrap")
	p.style(ui).shrink = 0
	p.text(ui, a.me.handle, "flex-1 min-w-0 text-[11] text-muted-foreground truncate")
	p.end(ui)

	p.row(ui, "w-full h-9 items-center px-3 rounded-md border border-ring ring-3 ring-ring/40 bg-input/30")
	if len(a.pbuf) == 0 {
		p.text(ui, ph, "text-sm text-muted-foreground whitespace-nowrap")
	} else {
		p.text(ui, string(a.pbuf[:]), "text-sm whitespace-nowrap")
	}
	p.style(ui).shrink = 0
	if mod1(ui.now, 1.1) < 0.62 {
		p.div(ui, "w-[1.5] h-4 rounded-full bg-foreground ml-px")
		p.end(ui)
	}
	ui.animating = true
	p.end(ui)

	p.text(ui, hint, "text-[11] text-muted-foreground")
	p.row(ui, "w-full items-center gap-3")
	hint_key(ui, "Enter", a.prompt == .Invite ? "send invite" : "create")
	hint_key(ui, "Esc", "cancel")
	p.end(ui)
}

hint_key :: proc(ui: ^p.Ctx, k, label: string) {
	p.row(ui, "shrink-0 items-center gap-1")
	defer p.end(ui)
	sc.kbd(ui, k)
	p.text(ui, label, "text-[10.5] text-muted-foreground whitespace-nowrap")
	p.style(ui).shrink = 0
}
