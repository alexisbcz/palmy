package main

// The interface: a three-column Slack shape — channels, the conversation,
// members — plus the search and help overlays. There is no `xdg_popup` in
// palmy, so overlays are absolutely positioned children of the root.

import "core:fmt"
import "core:strings"
import "core:time"
import p "palmy:."
import sc "shadcn:."
import w "wire"

LINE_H :: 20

AVATAR_BG := [?]string {
	"bg-indigo-500",
	"bg-emerald-500",
	"bg-rose-500",
	"bg-amber-500",
	"bg-sky-500",
	"bg-violet-500",
	"bg-teal-500",
	"bg-orange-600",
}

build :: proc(ui: ^p.Ctx, a: ^App) {
	sidebar(ui, a)

	p.col(ui, "flex-1 min-w-0 h-full relative bg-background")
	channel_header(ui, a)
	message_list(ui, a)
	composer(ui, a)
	jump_button(ui, a)
	p.end(ui)

	member_panel(ui, a)

	if a.mode == .Search {
		search_overlay(ui, a)
	}
	if a.help {
		help_overlay(ui, a)
	}
	if a.toast != "" {
		toast_strip(ui, a)
	}
}

// ---------------------------------------------------------------------------
// Sidebar
// ---------------------------------------------------------------------------

sidebar :: proc(ui: ^p.Ctx, a: ^App) {
	p.col(ui, p.concat(ui, "h-full shrink-0 border-r border-border bg-card w-[", itoa(ui, SIDEBAR_W), "]"))
	defer p.end(ui)

	// Workspace header.
	p.row(ui, "w-full h-[52] shrink-0 items-center gap-2.5 px-3 border-b border-border")
	p.div(ui, "size-7 shrink-0 flex-row items-center justify-center rounded-md bg-primary")
	p.icon(ui, IC_MESSAGE_SQUARE, "size-4 text-primary-foreground")
	p.end(ui)
	p.col(ui, "flex-1 min-w-0 gap-0")
	p.text(ui, "palmy chat", "text-[13] font-semibold truncate")
	p.textf(ui, "text-[10.5] text-muted-foreground truncate", "127.0.0.1:%d", a.args.port)
	p.end(ui)
	p.end(ui)

	list := p.col(ui, "flex-1 min-h-0 w-full overflow-scroll py-2 gap-px")

	section_label(ui, "Channels", a.mode == .Channels)
	for c, i in a.chans {
		if c.kind != .Channel {
			continue
		}
		p.key(ui, c.name)
		channel_row(ui, a, i)
	}

	dms := 0
	for c in a.chans {
		if c.kind == .DM {
			dms += 1
		}
	}
	p.div(ui, "h-2")
	p.end(ui)
	section_label(ui, "Direct messages", false)
	if dms == 0 {
		p.row(ui, "w-full items-center gap-1.5 px-3 py-1")
		p.text(ui, "none yet —", "text-[11] text-muted-foreground whitespace-nowrap")
		p.style(ui).shrink = 0
		sc.kbd(ui, "F3")
		p.end(ui)
	}
	for c, i in a.chans {
		if c.kind != .DM {
			continue
		}
		p.key(ui, c.name)
		channel_row(ui, a, i)
	}
	p.end(ui)
	_ = list

	link_footer(ui, a)
}

section_label :: proc(ui: ^p.Ctx, label: string, active: bool) {
	p.row(ui, "w-full items-center gap-1.5 px-3 pt-1.5 pb-1")
	defer p.end(ui)
	p.text(
		ui,
		label,
		active \
		? "text-[10.5] font-semibold uppercase tracking-wide text-foreground whitespace-nowrap" \
		: "text-[10.5] font-semibold uppercase tracking-wide text-muted-foreground whitespace-nowrap",
	)
	p.style(ui).shrink = 0
	if active {
		p.spacer(ui)
		p.icon(ui, IC_CHEVRON_DOWN, "size-3 shrink-0 text-muted-foreground")
	}
}

channel_row :: proc(ui: ^p.Ctx, a: ^App, i: int) {
	c := &a.chans[i]
	active := i == a.cur
	cursor := a.mode == .Channels && i == a.sel_chan
	unread := c.unread > 0 && !active

	idx := p.row(ui, "w-full shrink-0 h-[30] items-center gap-2 px-2.5 mx-1.5 rounded-md transition")
	p.apply(ui, active ? "bg-accent" : "hover:bg-muted", idx)
	if cursor {
		p.apply(ui, "ring-1 ring-ring", idx)
	}
	if p.clickable(ui, idx) {
		switch_to(a, i)
	}
	defer p.end(ui)

	if c.kind == .DM {
		other := w.dm_other(c.name, a.nick)
		presence_dot(ui, presence_of_nick(a, other))
		p.text(
			ui,
			other,
			unread \
			? "flex-1 min-w-0 text-[13] font-semibold truncate" \
			: active ? "flex-1 min-w-0 text-[13] truncate" : "flex-1 min-w-0 text-[13] text-muted-foreground truncate",
		)
	} else {
		p.icon(
			ui,
			IC_HASH,
			active || unread ? "size-3.5 shrink-0 text-foreground" : "size-3.5 shrink-0 text-muted-foreground",
		)
		p.text(
			ui,
			c.name,
			unread \
			? "flex-1 min-w-0 text-[13] font-semibold truncate" \
			: active ? "flex-1 min-w-0 text-[13] truncate" : "flex-1 min-w-0 text-[13] text-muted-foreground truncate",
		)
	}

	if c.unread > 0 && !active {
		p.div(
			ui,
			c.mention \
			? "h-[18] min-w-[18] shrink-0 flex-row items-center justify-center rounded-full bg-destructive px-1.5" \
			: "h-[18] min-w-[18] shrink-0 flex-row items-center justify-center rounded-full bg-primary px-1.5",
		)
		p.textf(ui, "text-[10.5] font-semibold text-primary-foreground whitespace-nowrap", "%d", min(c.unread, 99))
		p.style(ui).shrink = 0
		p.end(ui)
	}
}

link_footer :: proc(ui: ^p.Ctx, a: ^App) {
	p.row(ui, "w-full h-[48] shrink-0 items-center gap-2.5 px-3 border-t border-border")
	defer p.end(ui)

	switch a.link {
	case .Online:
		avatar(ui, a.nick, "size-7", "text-[11]")
		p.col(ui, "flex-1 min-w-0 gap-0")
		p.text(ui, a.nick, "text-[12.5] font-medium truncate")
		p.row(ui, "items-center gap-1.5")
		presence_dot(ui, a.away ? .Away : .Online)
		p.text(
			ui,
			a.away ? "away" : "online",
			"text-[10.5] text-muted-foreground whitespace-nowrap",
		)
		p.style(ui).shrink = 0
		p.end(ui)
		p.end(ui)

	case .Connecting:
		p.icon(ui, IC_LOADER_CIRCLE, "size-4 shrink-0 text-muted-foreground", p.elapsed(ui) * 0.8)
		ui.animating = true
		p.col(ui, "flex-1 min-w-0 gap-0")
		p.text(ui, "Connecting…", "text-[12.5] font-medium truncate")
		p.textf(ui, "text-[10.5] text-muted-foreground truncate", "127.0.0.1:%d", a.args.port)
		p.end(ui)

	case .Offline:
		p.div(ui, "size-7 shrink-0 flex-row items-center justify-center rounded-md bg-destructive/15")
		p.icon(ui, IC_WIFI_OFF, "size-4 text-destructive")
		p.end(ui)
		p.col(ui, "flex-1 min-w-0 gap-0")
		p.text(ui, "Offline", "text-[12.5] font-medium text-destructive truncate")
		wait := max(0, a.retry_at - a.now)
		p.textf(ui, "text-[10.5] text-muted-foreground truncate", "retrying in %.0fs", wait + 0.5)
		p.end(ui)
	}
}

// ---------------------------------------------------------------------------
// Conversation header
// ---------------------------------------------------------------------------

channel_header :: proc(ui: ^p.Ctx, a: ^App) {
	p.row(ui, "w-full h-[52] shrink-0 items-center gap-3 px-5 border-b border-border")
	defer p.end(ui)

	c := current(a)
	if c == nil {
		p.text(ui, "No channel", "text-sm text-muted-foreground")
		return
	}

	if c.kind == .DM {
		other := w.dm_other(c.name, a.nick)
		avatar(ui, other, "size-6", "text-[10.5]")
		p.text(ui, other, "text-[15] font-semibold whitespace-nowrap")
		p.style(ui).shrink = 0
		sc.badge(ui, "direct", .Outline)
	} else {
		p.icon(ui, IC_HASH, "size-4 shrink-0 text-muted-foreground")
		p.text(ui, c.name, "text-[15] font-semibold whitespace-nowrap")
		p.style(ui).shrink = 0
	}

	if c.topic != "" {
		sc.separator(ui, .Vertical, "h-4 self-center")
		p.text(ui, c.topic, "flex-1 min-w-0 text-xs text-muted-foreground truncate")
	} else {
		p.spacer(ui)
	}

	online := 0
	for m in a.members {
		if m.state != .Offline {
			online += 1
		}
	}
	p.row(ui, "shrink-0 items-center gap-1.5")
	p.icon(ui, IC_USERS, "size-3.5 shrink-0 text-muted-foreground")
	p.textf(ui, "text-xs text-muted-foreground whitespace-nowrap", "%d", online)
	p.style(ui).shrink = 0
	p.end(ui)

	mode_chip(ui, a)

	p.row(ui, "shrink-0 items-center gap-1")
	sc.kbd(ui, "F4")
	p.icon(ui, IC_SEARCH, "size-3.5 shrink-0 text-muted-foreground")
	p.end(ui)
}

mode_chip :: proc(ui: ^p.Ctx, a: ^App) {
	label, ic := "", IC_SQUARE_PEN
	switch a.mode {
	case .Compose:
		label, ic = "compose", IC_SQUARE_PEN
	case .Browse:
		label, ic = "browse", IC_ARROW_UP
	case .Channels:
		label, ic = "channels", IC_HASH
	case .Members:
		label, ic = "members", IC_USERS
	case .Search:
		label, ic = "search", IC_SEARCH
	}
	p.row(ui, "shrink-0 items-center gap-1.5 h-6 px-2 rounded-md border border-border bg-muted/50")
	defer p.end(ui)
	p.icon(ui, ic, "size-3 shrink-0 text-muted-foreground")
	p.text(ui, label, "text-[11] font-medium text-muted-foreground whitespace-nowrap")
	p.style(ui).shrink = 0
}

// ---------------------------------------------------------------------------
// The message list
// ---------------------------------------------------------------------------

message_list :: proc(ui: ^p.Ctx, a: ^App) {
	list := p.col(ui, "flex-1 min-h-0 w-full overflow-scroll px-5 py-4 gap-0")
	a.list_id = p.node_id(ui, list)
	defer p.end(ui)

	c := current(a)
	if c == nil {
		return
	}

	if !c.loaded {
		for _ in 0 ..< 5 {
			p.row(ui, "w-full shrink-0 items-start gap-3 py-2")
			sc.skeleton(ui, "size-9 shrink-0 rounded-full")
			p.col(ui, "flex-1 min-w-0 gap-1.5 pt-1")
			sc.skeleton(ui, "h-3 w-[120]")
			sc.skeleton(ui, "h-3 w-full")
			p.end(ui)
			p.end(ui)
		}
		return
	}

	if len(c.msgs) == 0 {
		empty_channel(ui, a, c)
		return
	}

	// A conversation sits at the bottom of its pane when it is short, the way
	// every chat client does. A growing spacer is the honest way to get that:
	// `justify-end` on a scroll container makes the overflowing top
	// unreachable, this collapses to nothing as soon as there is overflow.
	p.div(ui, "w-full flex-1 min-h-0")
	p.end(ui)

	if c.more {
		p.row(ui, "w-full shrink-0 items-center justify-center gap-2 py-2")
		p.icon(ui, IC_CHEVRON_UP, "size-3 shrink-0 text-muted-foreground")
		p.text(ui, "older messages —", "text-[11] text-muted-foreground whitespace-nowrap")
		p.style(ui).shrink = 0
		sc.kbd(ui, "PgUp")
		p.end(ui)
	}

	for i in 0 ..< len(c.msgs) {
		p.key(ui, itoa64(ui, c.msgs[i].id))
		message_row(ui, a, c, i)
	}
}

empty_channel :: proc(ui: ^p.Ctx, a: ^App, c: ^Channel) {
	p.col(ui, "w-full flex-1 items-center justify-center gap-3 py-10")
	defer p.end(ui)

	p.div(ui, "size-12 flex-row items-center justify-center rounded-full bg-muted")
	p.icon(ui, c.kind == .DM ? IC_AT_SIGN : IC_HASH, "size-5 text-muted-foreground")
	p.end(ui)
	p.textf(ui, "text-sm font-semibold", "This is the start of %s", chan_label(a, c))
	p.text(
		ui,
		c.kind == .DM ? "Only the two of you can read this." : "Say something — everyone here will see it.",
		"text-xs text-muted-foreground",
	)
}

// message_row draws one message and returns whether the pointer is over it.
message_row :: proc(ui: ^p.Ctx, a: ^App, c: ^Channel, i: int) -> bool {
	m := &c.msgs[i]
	prev: ^w.Msg = i > 0 ? &c.msgs[i - 1] : nil

	new_day := prev == nil || day_of(a, m.ts) != day_of(a, prev.ts)
	if new_day {
		day_divider(ui, a, m.ts)
	}
	grouped :=
		!new_day &&
		prev != nil &&
		prev.nick == m.nick &&
		m.ts - prev.ts <= 300 &&
		m.reply_to == 0 &&
		!m.deleted &&
		!prev.deleted

	sel := a.mode == .Browse && a.sel_msg == m.id

	row := p.row(ui, "w-full shrink-0 items-start gap-3 px-2 rounded-md relative")
	p.apply(ui, grouped ? "py-px" : "pt-2.5 pb-1", row)
	if sel {
		p.apply(ui, "bg-accent ring-1 ring-ring/50", row)
	} else {
		p.apply(ui, "hover:bg-muted/60", row)
	}
	hov := p.is_hovered(ui, row)
	if p.clickable(ui, row) {
		a.sel_msg = m.id
		a.mode = .Browse
	}
	defer p.end(ui)

	// Gutter: the avatar on the first message of a run, the timestamp on the
	// rest — and only while the row is under the pointer, the way Slack does
	// it, so a run of messages reads as one block.
	if grouped {
		p.div(ui, "w-9 shrink-0 flex-row justify-end pt-px")
		if hov || sel {
			p.text(ui, hhmm(ui, a, m.ts), "text-[10] text-muted-foreground whitespace-nowrap")
			p.style(ui).shrink = 0
		}
		p.end(ui)
	} else {
		avatar(ui, m.nick, "size-9", "text-[12.5]")
	}

	body := p.col(ui, "flex-1 min-w-0 gap-1")
	avail := p.rect_of(ui, p.node_id(ui, body)).w
	if avail < 60 {
		avail = a.body_w > 60 ? a.body_w : 560
	} else {
		a.body_w = avail
	}

	if !grouped {
		p.row(ui, "w-full items-baseline gap-2")
		p.text(ui, m.nick, "text-[13] font-semibold whitespace-nowrap")
		p.style(ui).shrink = 0
		if m.nick == a.nick {
			p.text(ui, "you", "text-[10] text-muted-foreground whitespace-nowrap")
			p.style(ui).shrink = 0
		}
		p.text(ui, hhmm(ui, a, m.ts), "text-[11] text-muted-foreground whitespace-nowrap")
		p.style(ui).shrink = 0
		if m.edited != 0 {
			p.text(ui, "(edited)", "text-[10] text-muted-foreground whitespace-nowrap")
			p.style(ui).shrink = 0
		}
		p.end(ui)
	}

	if m.reply_to != 0 {
		reply_stub(ui, a, c, m.reply_to)
	}

	if m.deleted {
		p.row(ui, "items-center gap-1.5")
		p.icon(ui, IC_TRASH, "size-3 shrink-0 text-muted-foreground")
		p.text(ui, "This message was deleted", "text-[12.5] text-muted-foreground whitespace-nowrap")
		p.style(ui).shrink = 0
		p.end(ui)
	} else {
		md_render(ui, m.text, "text-sm text-foreground", avail)
	}

	if len(m.reacts) > 0 {
		reaction_row(ui, a, m)
	}
	if sel && !m.deleted {
		reaction_palette(ui, a, m)
	}
	p.end(ui)

	if (hov || sel) && !m.deleted {
		action_bar(ui, a, m)
	}
	return hov
}

reply_stub :: proc(ui: ^p.Ctx, a: ^App, c: ^Channel, id: i64) {
	p.row(ui, "w-full min-w-0 items-center gap-1.5 pb-px")
	defer p.end(ui)

	p.icon(ui, IC_REPLY, "size-3 shrink-0 text-muted-foreground")
	src := msg_at(c, id)
	if src == nil {
		p.text(ui, "replying to an older message", "text-[11] text-muted-foreground whitespace-nowrap")
		p.style(ui).shrink = 0
		return
	}
	avatar(ui, src.nick, "size-[14]", "text-[8]")
	p.text(ui, src.nick, "text-[11] font-medium text-muted-foreground whitespace-nowrap")
	p.style(ui).shrink = 0
	p.text(ui, md_preview(src.text, context.temp_allocator), "flex-1 min-w-0 text-[11] text-muted-foreground truncate")
}

reaction_row :: proc(ui: ^p.Ctx, a: ^App, m: ^w.Msg) {
	p.row(ui, "w-full flex-wrap items-center gap-1 pt-px")
	defer p.end(ui)

	for r in m.reacts {
		if len(r.nicks) == 0 {
			continue
		}
		mine := w.react_has(m^, r.key, a.nick)
		p.row(ui, "shrink-0 flex-row items-center gap-1 h-[22] px-1.5 rounded-full border transition")
		p.apply(ui, mine ? "border-primary/60 bg-primary/20" : "border-border bg-muted/60 hover:bg-muted")
		p.icon(
			ui,
			reaction_icon(r.key),
			mine ? "size-3 shrink-0 text-foreground" : "size-3 shrink-0 text-muted-foreground",
		)
		p.textf(
			ui,
			mine \
			? "text-[11] font-semibold text-foreground whitespace-nowrap" \
			: "text-[11] text-muted-foreground whitespace-nowrap",
			"%d",
			len(r.nicks),
		)
		p.style(ui).shrink = 0
		p.end(ui)
	}
}

// reaction_palette is the keyboard affordance: the six reactions with the
// number that applies them, shown on the selected message.
reaction_palette :: proc(ui: ^p.Ctx, a: ^App, m: ^w.Msg) {
	p.row(ui, "w-full flex-wrap items-center gap-1 pt-1")
	defer p.end(ui)

	for r, i in REACTIONS {
		mine := w.react_has(m^, r.key, a.nick)
		p.row(ui, "shrink-0 flex-row items-center gap-1 h-[22] px-1.5 rounded-md border border-dashed border-border")
		if mine {
			p.apply(ui, "bg-primary/15 border-solid")
		}
		p.textf(ui, "text-[10] font-semibold text-muted-foreground whitespace-nowrap", "%d", i + 1)
		p.style(ui).shrink = 0
		p.icon(ui, r.ic, "size-3 shrink-0 text-muted-foreground")
		p.end(ui)
	}
	p.text(ui, "react", "text-[10] text-muted-foreground whitespace-nowrap")
	p.style(ui).shrink = 0
}

action_bar :: proc(ui: ^p.Ctx, a: ^App, m: ^w.Msg) {
	p.row(ui, "absolute flex-row items-center gap-px h-7 px-1 rounded-md border border-border bg-popover shadow-sm z-10")
	st := p.style(ui)
	st.position = .Absolute
	st.inset[p.RIGHT] = p.px(8)
	st.inset[p.TOP] = p.px(-2)
	defer p.end(ui)

	action_icon(ui, IC_FACE_SLIGHTLY_SMILING_PLUS, "1-6")
	action_icon(ui, IC_REPLY, "r")
	if m.nick == a.nick {
		action_icon(ui, IC_PENCIL, "e")
		action_icon(ui, IC_TRASH, "d")
	}
}

action_icon :: proc(ui: ^p.Ctx, ic: p.Icon, key: string) {
	p.row(ui, "shrink-0 items-center gap-0.5 h-5 px-1 rounded hover:bg-muted")
	defer p.end(ui)
	p.icon(ui, ic, "size-3 shrink-0 text-muted-foreground")
	p.text(ui, key, "text-[9.5] text-muted-foreground whitespace-nowrap")
	p.style(ui).shrink = 0
}

day_divider :: proc(ui: ^p.Ctx, a: ^App, ts: i64) {
	p.row(ui, "w-full shrink-0 items-center gap-3 py-3")
	defer p.end(ui)
	p.div(ui, "flex-1 h-px bg-border")
	p.end(ui)
	p.div(ui, "shrink-0 h-6 px-2.5 flex-row items-center rounded-full border border-border bg-background")
	p.text(ui, day_label(ui, a, ts), "text-[11] font-medium text-muted-foreground whitespace-nowrap")
	p.style(ui).shrink = 0
	p.end(ui)
	p.div(ui, "flex-1 h-px bg-border")
	p.end(ui)
}

// jump_button is the "you are not at the bottom" affordance.
jump_button :: proc(ui: ^p.Ctx, a: ^App) {
	if a.pinned {
		return
	}
	p.row(ui, "absolute flex-row items-center gap-2 h-8 px-3 rounded-full border border-border bg-popover shadow-lg z-20")
	st := p.style(ui)
	st.position = .Absolute
	st.inset[p.RIGHT] = p.px(24)
	st.inset[p.BOTTOM] = p.px(108)
	defer p.end(ui)

	p.icon(ui, IC_ARROW_DOWN, "size-3.5 shrink-0 text-foreground")
	if a.new_below > 0 {
		p.textf(
			ui,
			"text-[11.5] font-medium whitespace-nowrap",
			"%d new message%s",
			a.new_below,
			a.new_below == 1 ? "" : "s",
		)
	} else {
		p.text(ui, "Jump to latest", "text-[11.5] font-medium whitespace-nowrap")
	}
	p.style(ui).shrink = 0
	sc.kbd(ui, "End")
}

// ---------------------------------------------------------------------------
// Composer
// ---------------------------------------------------------------------------

composer :: proc(ui: ^p.Ctx, a: ^App) {
	p.col(ui, "w-full shrink-0 px-5 pb-3 pt-1 gap-1.5")
	defer p.end(ui)

	typing_strip(ui, a)

	if a.editing != 0 || a.replying != 0 {
		draft_banner(ui, a)
	}

	focused := a.mode == .Compose
	box := p.col(ui, "w-full min-w-0 rounded-lg border bg-input/30 px-3 py-2 gap-1.5 transition")
	p.apply(ui, focused ? "border-ring ring-3 ring-ring/40" : "border-input")
	if a.link != .Online {
		p.apply(ui, "opacity-70")
	}
	defer p.end(ui)

	// The text area. Its width, measured on the previous frame, is what the
	// soft wrapper works against.
	area := p.col(ui, "w-full min-w-0 relative gap-0")
	a.compose_w = max(80, p.rect_of(ui, p.node_id(ui, area)).w)
	wrap_compose(a, ui.fonts, 14)

	if len(a.buf) == 0 {
		c := current(a)
		ph := "Message"
		if c != nil {
			ph = c.kind == .DM \
			? fmt.tprintf("Message %s", w.dm_other(c.name, a.nick)) \
			: fmt.tprintf("Message #%s", c.name)
		}
		if a.link != .Online {
			ph = "Disconnected — reconnecting"
		}
		p.div(ui, p.concat(ui, "w-full h-[", itoa(ui, LINE_H), "]"))
		p.text(ui, ph, "text-sm text-muted-foreground whitespace-nowrap")
		p.style(ui).shrink = 0
		p.end(ui)
	} else {
		src := string(a.buf[:])
		for v in a.vlines {
			p.div(ui, p.concat(ui, "w-full shrink-0 h-[", itoa(ui, LINE_H), "]"))
			seg := src[v.start:v.end]
			p.text(ui, seg, "text-sm text-foreground whitespace-nowrap")
			p.style(ui).shrink = 0
			p.end(ui)
		}
	}

	if focused {
		li := max(0, caret_line(a, a.caret))
		v := a.vlines[li]
		src := string(a.buf[:])
		pre := src[v.start:clamp(a.caret, v.start, v.end)]
		cx := p.text_width(ui.fonts, pre, 14, .Sans, .Regular)
		ui.animating = true
		if mod1(ui.now, 1.1) < 0.62 {
			car := p.div(ui, "absolute w-[1.5] rounded-full bg-foreground")
			cs := p.style(ui, car)
			cs.position = .Absolute
			cs.inset[p.LEFT] = p.px(cx)
			cs.inset[p.TOP] = p.px(f32(li) * LINE_H + 2)
			cs.h = p.px(LINE_H - 4)
			p.end(ui)
		}
	}
	p.end(ui) // area

	// Hints.
	p.row(ui, "w-full items-center gap-3")
	hint(ui, "Enter", "", a.editing != 0 ? "save edit" : "send")
	hint(ui, "Shift", "Enter", "newline")
	hint(ui, "Esc", "", a.editing != 0 || a.replying != 0 ? "cancel" : "browse")
	p.spacer(ui)
	if len(a.buf) > 0 {
		p.textf(ui, "text-[10] text-muted-foreground whitespace-nowrap", "%d", len(a.buf))
		p.style(ui).shrink = 0
	}
	hint(ui, "F1", "", "keys")
	p.end(ui)
	_ = box
}

typing_strip :: proc(ui: ^p.Ctx, a: ^App) {
	p.row(ui, "w-full h-[16] shrink-0 items-center gap-1.5")
	defer p.end(ui)

	who := typers_here(a, context.temp_allocator)
	if len(who) == 0 {
		return
	}
	// Three dots that actually move, because a static one reads as a bug.
	for k in 0 ..< 3 {
		phase := mod1(a.now * 1.6 + f64(k) * 0.22, 1.0)
		up := phase < 0.5
		p.div(ui, "size-1 shrink-0 rounded-full bg-muted-foreground")
		p.style(ui).margin[p.BOTTOM] = up ? f32(3) : 0
		p.end(ui)
	}
	ui.animating = true

	label: string
	switch len(who) {
	case 1:
		label = fmt.tprintf("%s is typing…", who[0])
	case 2:
		label = fmt.tprintf("%s and %s are typing…", who[0], who[1])
	case:
		label = fmt.tprintf("%d people are typing…", len(who))
	}
	p.text(ui, label, "text-[11] text-muted-foreground whitespace-nowrap")
	p.style(ui).shrink = 0
}

draft_banner :: proc(ui: ^p.Ctx, a: ^App) {
	c := current(a)
	p.row(ui, "w-full shrink-0 items-center gap-2 h-7 px-2.5 rounded-md border border-border bg-muted/50")
	defer p.end(ui)

	if a.editing != 0 {
		p.icon(ui, IC_PENCIL, "size-3 shrink-0 text-muted-foreground")
		p.text(ui, "Editing your message", "text-[11.5] text-muted-foreground whitespace-nowrap")
		p.style(ui).shrink = 0
	} else {
		p.icon(ui, IC_REPLY, "size-3 shrink-0 text-muted-foreground")
		src := msg_at(c, a.replying)
		if src != nil {
			p.textf(ui, "text-[11.5] text-muted-foreground whitespace-nowrap", "Replying to %s", src.nick)
			p.style(ui).shrink = 0
			p.text(ui, md_preview(src.text, context.temp_allocator), "flex-1 min-w-0 text-[11.5] text-muted-foreground truncate")
		}
	}
	p.spacer(ui)
	sc.kbd(ui, "Esc")
}

hint :: proc(ui: ^p.Ctx, k1, k2, label: string) {
	p.row(ui, "shrink-0 items-center gap-1")
	defer p.end(ui)
	sc.kbd(ui, k1)
	if k2 != "" {
		sc.kbd(ui, k2)
	}
	p.text(ui, label, "text-[10.5] text-muted-foreground whitespace-nowrap")
	p.style(ui).shrink = 0
}

// ---------------------------------------------------------------------------
// Member panel
// ---------------------------------------------------------------------------

member_panel :: proc(ui: ^p.Ctx, a: ^App) {
	p.col(ui, p.concat(ui, "h-full shrink-0 border-l border-border bg-card w-[", itoa(ui, MEMBERS_W), "]"))
	defer p.end(ui)

	p.row(ui, "w-full h-[52] shrink-0 items-center gap-2 px-3 border-b border-border")
	p.icon(ui, IC_USERS, "size-3.5 shrink-0 text-muted-foreground")
	p.text(ui, "Members", "flex-1 text-[13] font-semibold truncate")
	p.textf(ui, "text-[11] text-muted-foreground whitespace-nowrap", "%d", len(a.members))
	p.style(ui).shrink = 0
	p.end(ui)

	p.col(ui, "flex-1 min-h-0 w-full overflow-scroll py-2 gap-px")
	band := w.Presence.Online
	first := true
	for m, i in a.members {
		if first || m.state != band {
			band = m.state
			first = false
			p.row(ui, "w-full items-center px-3 pt-2 pb-1")
			p.text(
				ui,
				band == .Online ? "Here" : band == .Away ? "Away" : "Offline",
				"text-[10] font-semibold uppercase tracking-wide text-muted-foreground whitespace-nowrap",
			)
			p.style(ui).shrink = 0
			p.end(ui)
		}

		p.key(ui, m.nick)
		cursor := a.mode == .Members && i == a.sel_member
		idx := p.row(ui, "w-full shrink-0 h-[30] items-center gap-2 px-2.5 mx-1.5 rounded-md transition hover:bg-muted")
		if cursor {
			p.apply(ui, "bg-accent ring-1 ring-ring", idx)
		}
		avatar(ui, m.nick, "size-5", "text-[9]")
		p.text(
			ui,
			m.nick,
			m.state == .Offline \
			? "flex-1 min-w-0 text-[12.5] text-muted-foreground truncate" \
			: "flex-1 min-w-0 text-[12.5] truncate",
		)
		if m.nick == a.nick {
			p.text(ui, "you", "text-[9.5] text-muted-foreground whitespace-nowrap")
			p.style(ui).shrink = 0
		}
		presence_dot(ui, m.state)
		p.end(ui)
	}
	p.end(ui)

	p.row(ui, "w-full h-[48] shrink-0 items-center gap-2 px-3 border-t border-border")
	sc.kbd(ui, "F3")
	p.text(ui, "then", "text-[10.5] text-muted-foreground whitespace-nowrap")
	p.style(ui).shrink = 0
	sc.kbd(ui, "Enter")
	p.text(ui, "to DM", "text-[10.5] text-muted-foreground whitespace-nowrap")
	p.style(ui).shrink = 0
	p.end(ui)
}

presence_dot :: proc(ui: ^p.Ctx, state: w.Presence) {
	p.div(ui, "size-2 shrink-0 rounded-full")
	switch state {
	case .Online:
		p.apply(ui, "bg-emerald-500")
	case .Away:
		p.apply(ui, "bg-amber-500")
	case .Offline:
		p.apply(ui, "bg-transparent ring-1 ring-muted-foreground/60")
	}
	p.end(ui)
}

// ---------------------------------------------------------------------------
// Overlays
// ---------------------------------------------------------------------------

search_overlay :: proc(ui: ^p.Ctx, a: ^App) {
	scrim := p.col(ui, "absolute inset-0 items-center bg-background/70 z-50 pt-[72] px-6")
	p.style(ui, scrim).position = .Absolute
	defer p.end(ui)

	p.col(ui, "w-[680] max-w-full rounded-xl border border-border bg-popover shadow-2xl overflow-hidden")
	defer p.end(ui)

	// Query line.
	p.row(ui, "w-full h-[48] shrink-0 items-center gap-2.5 px-4 border-b border-border")
	p.icon(ui, IC_SEARCH, "size-4 shrink-0 text-muted-foreground")
	p.row(ui, "flex-1 min-w-0 h-full items-center relative overflow-hidden")
	q := string(a.query[:])
	if len(q) == 0 {
		p.text(ui, "Search every message…", "text-sm text-muted-foreground whitespace-nowrap")
	} else {
		p.text(ui, q, "text-sm whitespace-nowrap")
	}
	p.style(ui).shrink = 0
	ui.animating = true
	if mod1(ui.now, 1.1) < 0.62 {
		cx := p.text_width(ui.fonts, q[:clamp(a.qcaret, 0, len(q))], 14, .Sans, .Regular)
		car := p.div(ui, "absolute w-[1.5] rounded-full bg-foreground")
		cs := p.style(ui, car)
		cs.position = .Absolute
		cs.inset[p.LEFT] = p.px(cx)
		cs.inset[p.TOP] = p.px(15)
		cs.h = p.px(18)
		p.end(ui)
	}
	p.end(ui)
	if a.searched {
		p.textf(ui, "text-[11] text-muted-foreground whitespace-nowrap", "%d hits", len(a.results))
		p.style(ui).shrink = 0
	} else {
		sc.kbd(ui, "Enter")
	}
	p.end(ui)

	// Results.
	p.col(ui, "w-full max-h-[420] overflow-scroll py-1.5 gap-px")
	if !a.searched {
		p.col(ui, "w-full items-center justify-center gap-1.5 py-10")
		p.icon(ui, IC_SEARCH, "size-5 text-muted-foreground")
		p.text(ui, "Type a query and press Enter", "text-xs text-muted-foreground")
		p.end(ui)
	} else if len(a.results) == 0 {
		p.col(ui, "w-full items-center justify-center gap-1.5 py-10")
		p.icon(ui, IC_INFO, "size-5 text-muted-foreground")
		p.text(ui, "Nothing matched", "text-xs text-muted-foreground")
		p.end(ui)
	}
	for m, i in a.results {
		p.key(ui, itoa64(ui, m.id))
		idx := p.row(ui, "w-full shrink-0 items-start gap-2.5 px-3 py-2 mx-1.5 rounded-md")
		p.apply(ui, i == a.sel_result ? "bg-accent" : "hover:bg-muted", idx)
		avatar(ui, m.nick, "size-6", "text-[10]")
		p.col(ui, "flex-1 min-w-0 gap-0.5")
		p.row(ui, "w-full items-baseline gap-2")
		p.text(ui, m.nick, "text-[12] font-semibold whitespace-nowrap")
		p.style(ui).shrink = 0
		p.textf(ui, "text-[10.5] text-muted-foreground whitespace-nowrap", "%s · %s", chan_name_for(a, m.ch), hhmm(ui, a, m.ts))
		p.style(ui).shrink = 0
		p.end(ui)
		p.text(ui, md_preview(m.text, context.temp_allocator), "w-full text-[12.5] text-muted-foreground truncate")
		p.end(ui)
		p.end(ui)
	}
	p.end(ui)

	p.row(ui, "w-full h-[36] shrink-0 items-center gap-3 px-4 border-t border-border bg-muted/40")
	hint(ui, "Up", "Down", "pick")
	hint(ui, "Enter", "", a.searched ? "jump" : "search")
	p.spacer(ui)
	hint(ui, "Esc", "", "close")
	p.end(ui)
}

help_overlay :: proc(ui: ^p.Ctx, a: ^App) {
	scrim := p.col(ui, "absolute inset-0 items-center justify-center bg-background/80 z-50 px-6")
	p.style(ui, scrim).position = .Absolute
	defer p.end(ui)

	p.col(ui, "w-[720] max-w-full rounded-xl border border-border bg-popover shadow-2xl p-5 gap-4")
	defer p.end(ui)

	p.row(ui, "w-full items-center gap-2")
	p.icon(ui, IC_MESSAGE_SQUARE, "size-4 shrink-0 text-muted-foreground")
	p.text(ui, "Keys", "flex-1 text-sm font-semibold")
	p.text(ui, "any key closes", "text-[10.5] text-muted-foreground whitespace-nowrap")
	p.style(ui).shrink = 0
	p.end(ui)

	p.row(ui, "w-full items-start gap-5")
	help_col(
		ui,
		"Anywhere",
		[]Help_Line{
			{"F2", "channel list"},
			{"F3", "members"},
			{"F4 / Ctrl F", "search"},
			{"Ctrl Up/Down", "previous / next channel"},
			{"Ctrl 1-9", "channel by number"},
			{"Ctrl L", "jump to latest"},
			{"Ctrl G", "toggle away"},
			{"Ctrl Q", "quit"},
		},
	)
	help_col(
		ui,
		"Composing",
		[]Help_Line{
			{"Enter", "send"},
			{"Shift Enter", "newline"},
			{"Esc", "cancel, or browse"},
			{"Ctrl U", "clear the draft"},
			{"Ctrl W", "delete a word"},
			{"PgUp / PgDn", "scroll the conversation"},
		},
	)
	help_col(
		ui,
		"Browsing",
		[]Help_Line{
			{"Up/Down, j/k", "select a message"},
			{"1 - 6", "react"},
			{"r", "reply"},
			{"e", "edit yours"},
			{"d / Del", "delete yours"},
			{"y", "copy the text"},
			{"Home / End", "oldest / newest"},
			{"i / Enter", "back to composing"},
		},
	)
	p.end(ui)

	p.div(ui, "w-full h-px bg-border")
	p.end(ui)
	p.row(ui, "w-full items-center gap-2")
	p.icon(ui, IC_INFO, "size-3 shrink-0 text-muted-foreground")
	p.text(
		ui,
		"Markdown renders in messages: **bold**, `code`, ``` blocks, > quotes, - lists, [links](url).",
		"flex-1 text-[11] text-muted-foreground",
	)
	p.end(ui)
}

Help_Line :: struct {
	keys, what: string,
}

help_col :: proc(ui: ^p.Ctx, title: string, lines: []Help_Line) {
	p.col(ui, "flex-1 min-w-0 gap-1.5")
	defer p.end(ui)

	p.text(ui, title, "text-[10.5] font-semibold uppercase tracking-wide text-muted-foreground")
	for l in lines {
		p.row(ui, "w-full items-baseline gap-2")
		p.text(ui, l.keys, "w-[104] shrink-0 text-[11] font-mono text-foreground")
		p.text(ui, l.what, "flex-1 min-w-0 text-[11] text-muted-foreground")
		p.end(ui)
	}
}

toast_strip :: proc(ui: ^p.Ctx, a: ^App) {
	holder := p.row(ui, "absolute inset-0 items-end justify-center z-50 pb-[96]")
	st := p.style(ui, holder)
	st.position = .Absolute
	defer p.end(ui)

	p.row(ui, "shrink-0 items-center gap-2 h-8 px-3 rounded-full border border-border bg-popover shadow-lg")
	defer p.end(ui)
	p.icon(ui, IC_INFO, "size-3.5 shrink-0 text-muted-foreground")
	p.text(ui, a.toast, "text-[11.5] whitespace-nowrap")
	p.style(ui).shrink = 0
}

// ---------------------------------------------------------------------------
// Small parts
// ---------------------------------------------------------------------------

avatar :: proc(ui: ^p.Ctx, nick: string, size := "size-9", text_class := "text-[12.5]") {
	p.div(ui, p.concat(ui, "shrink-0 flex-row items-center justify-center rounded-full ", size, " ", avatar_bg(nick)))
	defer p.end(ui)
	p.text(ui, initials(nick, context.temp_allocator), p.concat(ui, text_class, " font-semibold text-white whitespace-nowrap"))
	p.style(ui).shrink = 0
}

avatar_bg :: proc(nick: string) -> string {
	return AVATAR_BG[hash_nick(nick) % u64(len(AVATAR_BG))]
}

hash_nick :: proc(s: string) -> u64 {
	h: u64 = 0xcbf29ce484222325
	for i in 0 ..< len(s) {
		h ~= u64(s[i])
		h *= 0x100000001b3
	}
	return h
}

initials :: proc(nick: string, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	want := 2
	take_next := true
	for r in nick {
		if r == ' ' || r == '.' || r == '_' || r == '-' {
			take_next = true
			continue
		}
		if take_next && want > 0 {
			strings.write_rune(&b, to_upper(r))
			want -= 1
			take_next = false
		}
	}
	if strings.builder_len(b) == 0 {
		strings.write_string(&b, "?")
	}
	return strings.to_string(b)
}

to_upper :: proc(r: rune) -> rune {
	if r >= 'a' && r <= 'z' {
		return r - 32
	}
	return r
}

reaction_icon :: proc(key: string) -> p.Icon {
	for r in REACTIONS {
		if r.key == key {
			return r.ic
		}
	}
	return IC_CIRCLE
}

chan_name_for :: proc(a: ^App, name: string) -> string {
	if i := find_chan(a, name); i >= 0 {
		c := &a.chans[i]
		return c.kind == .DM ? w.dm_other(c.name, a.nick) : fmt.tprintf("#%s", c.name)
	}
	return name
}

// ---------------------------------------------------------------------------
// Time
//
// core:time has no timezone database, so the offset is read once from `date`
// at startup and folded in here. Every label below is local time.
// ---------------------------------------------------------------------------

day_of :: proc(a: ^App, ts: i64) -> i64 {
	v := ts + a.tz
	if v < 0 {
		return (v - 86399) / 86400
	}
	return v / 86400
}

hhmm :: proc(ui: ^p.Ctx, a: ^App, ts: i64) -> string {
	v := ts + a.tz
	mins := ((v % 86400) + 86400) % 86400 / 60
	return fmt.tprintf("%2d:%02d", mins / 60, mins % 60)
}

WEEKDAYS := [?]string{"Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"}

day_label :: proc(ui: ^p.Ctx, a: ^App, ts: i64) -> string {
	d := day_of(a, ts)
	today := day_of(a, w.now_unix())
	switch today - d {
	case 0:
		return "Today"
	case 1:
		return "Yesterday"
	}
	year, month, day := time.date(time.unix(ts + a.tz, 0))
	wd := WEEKDAYS[((d % 7) + 7 + 4) % 7]
	return fmt.tprintf("%s, %d %v %d", wd, day, month, year)
}

// ---------------------------------------------------------------------------
// Helpers palmy does not provide
// ---------------------------------------------------------------------------

itoa :: proc(ui: ^p.Ctx, v: int) -> string {
	return fmt.tprintf("%d", v)
}

itoa64 :: proc(ui: ^p.Ctx, v: i64) -> string {
	return fmt.tprintf("%d", v)
}

mod1 :: proc(v, m: f64) -> f64 {
	n := v - m * f64(int(v / m))
	return n < 0 ? n + m : n
}
