// The cloud parts of the window: the calendars sidebar, the account chip,
// the sign-in sheet and the invitations sheet.
package main

import "core:strings"
import p "palmy:."
import sc "shadcn:."

// ---------------------------------------------------------------------------
// Sidebar: identities and their calendars, each a toggle
// ---------------------------------------------------------------------------

sidebar :: proc(ui: ^p.Ctx, c: ^Cal) {
	p.col(ui, tfmt("w-[%d] shrink-0 h-full bg-sidebar border-r border-border overflow-hidden", SIDE_W))
	defer p.end(ui)

	p.row(ui, "w-full h-[40] shrink-0 items-center gap-2 px-4 pt-2")
	p.text(ui, "Calendars", "text-[11] font-semibold tracking-wide text-muted-foreground uppercase whitespace-nowrap")
	p.spacer(ui, "flex-1")
	if c.pane == .Sources {
		sc.kbd(ui, "Space")
	}
	p.end(ui)

	p.col(ui, "flex-1 min-h-0 w-full overflow-scroll px-2 pb-3 gap-0.5")
	// This device first, then each identity with its calendars.
	group_head(ui, "This device", "", 0)
	source_row(ui, c, 0)
	for ident in c.cloud.idents {
		first := true
		for s, i in c.cloud.sources {
			if s.device || s.handle != ident.handle {
				continue
			}
			if first {
				group_head(ui, ident.name, ident.handle, parse_color(ident.color))
				first = false
			}
			source_row(ui, c, i)
		}
	}
	p.end(ui)

	if !c.cloud.signed {
		p.col(ui, "w-full shrink-0 gap-2 px-4 py-3 border-t border-border")
		p.text(ui, "Sign in to see your identities' calendars, shared calendars and invitations.", "w-full text-[11.5] text-muted-foreground")
		p.row(ui, "items-center gap-1.5")
		sc.kbd(ui, "I")
		p.text(ui, "sign in", "text-[11] text-muted-foreground")
		p.style(ui).shrink = 0
		p.end(ui)
		p.end(ui)
		return
	}
	n := len(pending_invitations(&c.cloud, context.temp_allocator))
	p.key(ui, "invites")
	idx := p.row(ui, "w-full shrink-0 items-center gap-2 px-4 h-[40] border-t border-border hover:bg-accent/60 transition cursor-pointer")
	if p.clickable(ui, idx) {
		c.mode = .Invites
		c.inv_sel = 0
	}
	p.icon(ui, ICON_INBOX, "size-3.5 shrink-0 text-muted-foreground")
	p.text(ui, "Invitations", "flex-1 min-w-0 text-[12.5] font-medium")
	if n > 0 {
		p.div(ui, "flex-row h-[18] min-w-[18] px-1.5 items-center justify-center rounded-full bg-accent-blue shrink-0")
		p.textf(ui, "text-[10.5] font-semibold text-white", "%d", n)
		p.end(ui)
	} else {
		sc.kbd(ui, "V")
	}
	p.end(ui)
}

@(private = "file")
group_head :: proc(ui: ^p.Ctx, name, handle: string, color: u32) {
	p.row(ui, "w-full shrink-0 items-center gap-2 px-2 pt-3 pb-1")
	if handle != "" {
		p_register(tfmt("id-%s", handle), color)
		p.div(ui, tfmt("flex-row size-[18] shrink-0 items-center justify-center rounded-full bg-id-%s/20", handle))
		p.text(ui, initial(name), tfmt("text-[10] font-semibold text-id-%s", handle))
		p.end(ui)
	} else {
		p.div(ui, "flex-row size-[18] shrink-0 items-center justify-center rounded-full bg-muted")
		p.icon(ui, ICON_CALENDAR, "size-2.5 text-muted-foreground")
		p.end(ui)
	}
	p.col(ui, "flex-1 min-w-0 gap-px")
	p.text(ui, name, "w-full truncate text-[12] font-semibold text-foreground")
	if handle != "" {
		p.text(ui, tfmt("%s@%s", handle, mail_domain()), "w-full truncate text-[10.5] text-muted-foreground")
	}
	p.end(ui)
	p.end(ui)
}

initial :: proc(s: string) -> string {
	for r, i in s {
		_ = r
		end := i + 1
		for end < len(s) && (s[end] & 0xc0) == 0x80 {
			end += 1
		}
		return strings.to_upper(s[i:end], context.temp_allocator)
	}
	return "?"
}

@(private = "file")
source_row :: proc(ui: ^p.Ctx, c: ^Cal, i: int) {
	s := &c.cloud.sources[i]
	on := c.pane == .Sources && c.src_sel == i
	p.key(ui, tfmt("src-%s", s.key))
	idx := p.row(ui, "w-full shrink-0 items-center gap-2 pl-3 pr-2 h-[30] rounded-md transition cursor-pointer")
	p.apply(ui, on ? "bg-accent-blue/10 ring-2 ring-accent-blue/40" : "hover:bg-accent/60", idx)
	if p.clickable(ui, idx) {
		c.src_sel = i
		s.visible = !s.visible
		rebuild_view(c)
	}
	col := src_color(c, i)
	// A filled square when shown, an outline when hidden: the checkbox is
	// the colour swatch.
	if s.visible {
		p.div(ui, tfmt("flex-row size-[14] shrink-0 items-center justify-center rounded-[4] bg-%s", col))
		p.icon(ui, ICON_CHECK, "size-2.5 text-white")
		p.end(ui)
	} else {
		p.div(ui, tfmt("size-[14] shrink-0 rounded-[4] border-2 border-%s/60", col))
		p.end(ui)
	}
	p.text(ui, s.name, s.visible ? "flex-1 min-w-0 truncate text-[12.5] text-foreground" : "flex-1 min-w-0 truncate text-[12.5] text-muted-foreground")
	if s.access == "read" {
		p.icon(ui, ICON_LOCK, "size-3 shrink-0 text-muted-foreground")
	}
	if !s.device && s.access != "owner" {
		p.text(ui, s.owner, "max-w-[70] truncate text-[10.5] text-muted-foreground shrink-0")
	}
	p.end(ui)
}

// ---------------------------------------------------------------------------
// Header and status bar
// ---------------------------------------------------------------------------

account_chip :: proc(ui: ^p.Ctx, c: ^Cal) {
	p.key(ui, "account")
	idx := p.row(ui, "h-7 shrink-0 items-center gap-1.5 px-2.5 rounded-md border border-border bg-background hover:bg-accent transition cursor-pointer")
	if p.clickable(ui, idx) {
		if c.cloud.signed {
			do_sync(c)
		} else {
			c.mode = .Sign_In
			c.swallow = true
		}
	}
	if !c.cloud.signed {
		p.icon(ui, ICON_LOG_IN, "size-3.5 shrink-0 text-muted-foreground")
		p.text(ui, "Sign in", "text-[12] font-medium whitespace-nowrap")
	} else {
		p.icon(ui, c.cloud.online || c.cloud.fixture ? ICON_CLOUD : ICON_CLOUD_OFF, "size-3.5 shrink-0 text-muted-foreground")
		p.text(ui, c.cloud.email, "max-w-[180] truncate text-[12] font-medium")
		p.icon(ui, ICON_REFRESH_CW, "size-3 shrink-0 text-muted-foreground")
	}
	p.style(ui).shrink = 0
	p.end(ui)
}

status_sync :: proc(ui: ^p.Ctx, c: ^Cal) {
	text := "on this device"
	switch {
	case c.cloud.signed && c.cloud.status != "":
		text = c.cloud.status
	case c.cloud.signed:
		text = "not synced yet · R to sync"
	}
	p.text(ui, text, "text-[11] text-muted-foreground/80 whitespace-nowrap shrink-0")
}

// choice_value draws a cycling field: the calendar (with its colour) or the
// repetition.
choice_value :: proc(ui: ^p.Ctx, c: ^Cal, f: Field, active, editable: bool) {
	if f == .Calendar {
		if c.form.src >= 0 && c.form.src < len(c.cloud.sources) {
			s := c.cloud.sources[c.form.src]
			p.div(ui, tfmt("size-[10] rounded-full shrink-0 bg-%s", src_color(c, c.form.src)))
			p.end(ui)
			label := s.name
			if ident, ok := ident_of(&c.cloud, s.handle); ok {
				label = tfmt("%s — %s", s.name, ident.name)
			}
			p.text(ui, label, "flex-1 min-w-0 truncate text-[13] text-foreground pl-1")
		}
	} else {
		p.icon(ui, ICON_REPEAT, "size-3.5 shrink-0 text-muted-foreground")
		p.text(ui, editable ? RECUR_LABELS[c.form.recur] : "for calendars in your Palmy account",
			editable ? "flex-1 min-w-0 truncate text-[13] text-foreground pl-1" : "flex-1 min-w-0 truncate text-[13] text-muted-foreground/60 pl-1")
	}
	if editable && active {
		p.icon(ui, ICON_CHEVRON_LEFT, "size-3.5 shrink-0 text-muted-foreground")
		p.icon(ui, ICON_CHEVRON_RIGHT, "size-3.5 shrink-0 text-muted-foreground")
	}
}

// ---------------------------------------------------------------------------
// Sign in
// ---------------------------------------------------------------------------

sign_in_sheet :: proc(ui: ^p.Ctx, c: ^Cal) {
	scrim(ui, c)
	win := p.size(ui)
	sheet_open(ui, 420, max(8, win.y / 2 - 190))
	defer sheet_close(ui)

	p.col(ui, "w-full items-center px-6 pt-6 pb-2 gap-2")
	p.div(ui, "flex-row size-10 items-center justify-center rounded-full bg-accent-blue/10 shrink-0")
	p.icon(ui, ICON_CLOUD, "size-4.5 text-accent-blue")
	p.end(ui)
	p.text(ui, "Sign in to Palmy", "text-[16] font-semibold")
	p.text(ui, "Every identity's calendars, the ones shared with you, and invitations.", "max-w-[340] text-center text-[12] text-muted-foreground")
	p.end(ui)

	p.col(ui, "w-full px-6 pt-3 pb-4 gap-3")
	sign_field(ui, c, 0, "Email", string(c.sign.email[:]), "you@example.org", false)
	sign_field(ui, c, 1, "Password", string(c.sign.pass[:]), "", true)
	if c.sign.err != "" {
		p.row(ui, "w-full items-center gap-2")
		p.icon(ui, ICON_CIRCLE_ALERT, "size-3.5 shrink-0 text-destructive")
		p.text(ui, c.sign.err, "flex-1 min-w-0 text-[12] text-destructive")
		p.end(ui)
	}
	p.end(ui)

	p.row(ui, "h-[44] w-full shrink-0 items-center justify-end gap-3 px-5 border-t border-border bg-muted/40")
	hint(ui, "Esc", "cancel")
	hint(ui, "Tab", "next")
	hint(ui, "Enter", "sign in")
	p.end(ui)
}

@(private = "file")
sign_field :: proc(ui: ^p.Ctx, c: ^Cal, which: int, label, value, placeholder: string, masked: bool) {
	p.col(ui, "w-full gap-1.5")
	p.text(ui, label, "text-[12] font-medium text-muted-foreground")
	p.key(ui, label)
	idx := p.row(ui, "w-full h-9 items-center px-3 rounded-lg border border-input bg-background overflow-hidden cursor-text")
	if p.clickable(ui, idx) {
		c.sign.field = which
	}
	active := c.sign.field == which
	if active {
		p.apply(ui, "border-ring ring-3 ring-ring/40", idx)
	}
	shown := value
	if masked {
		shown = strings.repeat("•", strings.rune_count(value), context.temp_allocator)
	}
	p.text(ui, shown == "" ? placeholder : shown, shown == "" ? "text-[13] text-muted-foreground/60 whitespace-nowrap shrink-0" : "text-[13] text-foreground whitespace-nowrap shrink-0")
	if active && p.caret_on(ui) {
		p.div(ui, "w-px h-[16] ml-px bg-foreground shrink-0")
		p.end(ui)
	}
	p.end(ui)
	p.end(ui)
}

// ---------------------------------------------------------------------------
// Invitations
// ---------------------------------------------------------------------------

invites_sheet :: proc(ui: ^p.Ctx, c: ^Cal) {
	scrim(ui, c)
	win := p.size(ui)
	list := pending_invitations(&c.cloud, context.temp_allocator)
	sheet_open(ui, 560, max(8, win.y / 2 - 220))
	defer sheet_close(ui)

	p.row(ui, "w-full items-center gap-2.5 px-5 pt-5 pb-3 border-b border-border")
	p.div(ui, "flex-row size-8 shrink-0 items-center justify-center rounded-lg bg-accent-blue/10")
	p.icon(ui, ICON_INBOX, "size-4 text-accent-blue")
	p.end(ui)
	p.col(ui, "gap-0.5 min-w-0 flex-1")
	p.text(ui, "Invitations", "text-[15] font-semibold")
	p.text(ui, len(list) == 0 ? "Nothing is waiting for an answer." : tfmt("%d waiting for an answer, across your identities", len(list)), "text-[12] text-muted-foreground")
	p.end(ui)
	p.end(ui)

	p.col(ui, "w-full px-3 py-3 gap-1.5 max-h-[360] overflow-scroll")
	if len(list) == 0 {
		p.col(ui, "w-full items-center py-6 gap-2")
		p.icon(ui, ICON_CIRCLE_CHECK, "size-6 text-muted-foreground/60")
		p.text(ui, "All answered", "text-[13] font-medium text-muted-foreground")
		p.end(ui)
	}
	sel := clamp(c.inv_sel, 0, max(0, len(list) - 1))
	for inv, k in list {
		on := k == sel
		p.key(ui, tfmt("inv-%s", inv.obj))
		idx := p.row(ui, "w-full shrink-0 items-stretch gap-3 px-3 py-2.5 rounded-lg border transition cursor-pointer")
		p.apply(ui, on ? "bg-accent border-ring ring-3 ring-ring/30" : "bg-background border-border hover:bg-accent/60", idx)
		if p.clickable(ui, idx) {
			c.inv_sel = k
		}
		p.div(ui, tfmt("w-[3] shrink-0 rounded-full bg-%s", src_color(c, inv.src)))
		p.end(ui)
		p.col(ui, "flex-1 min-w-0 gap-1")
		p.row(ui, "w-full items-center gap-1.5")
		p.text(ui, inv.title != "" ? inv.title : "(no title)", "flex-1 min-w-0 truncate text-[13] font-semibold")
		if inv.recurring {
			p.icon(ui, ICON_REPEAT, "size-3 shrink-0 text-muted-foreground")
		}
		p.end(ui)
		d, m := to_local(&c.cloud, inv.start)
		p.text(ui, tfmt("%s %d %s %d · %s", DAYS_SHORT[weekday(d)], d.d, MONTHS_SHORT[d.m - 1], d.y, clock_text(m)), "text-[11.5] font-mono text-muted-foreground")
		p.row(ui, "w-full items-center gap-1.5")
		p.icon(ui, ICON_USER, "size-3 shrink-0 text-muted-foreground")
		p.text(ui, tfmt("from %s", inv.organizer), "flex-1 min-w-0 truncate text-[11.5] text-muted-foreground")
		p.text(ui, tfmt("to %s", inv.handle), "text-[11] text-muted-foreground/80 shrink-0")
		p.end(ui)
		p.end(ui)
		p.end(ui)
	}
	p.end(ui)

	p.row(ui, "h-[44] w-full shrink-0 items-center justify-end gap-3 px-5 border-t border-border bg-muted/40")
	hint(ui, "Up Down", "choose")
	hint(ui, "A", "accept")
	hint(ui, "T", "maybe")
	hint(ui, "D", "decline")
	hint(ui, "Esc", "close")
	p.end(ui)
}
