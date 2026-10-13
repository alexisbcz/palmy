package main

// The change dialog: plan, confirm, progress, outcome.
//
// Nothing is installed or removed on a click. A click asks palmd for a plan,
// and this dialog shows that plan as palm computed it -- every package that
// will be installed, updated or removed, the download and the change in disk
// use -- with Cancel and the action. Confirming applies exactly that plan
// (palmd checks), and the dialog then shows palm working, step by step, and
// finally either what was done or palm's error, word for word.

import "core:fmt"
import "core:strings"
import p "palmy:."
import sc "shadcn:."

DIALOG_W :: 480

change_dialog :: proc(ui: ^p.Ctx, st: ^State) {
	t := &st.txn
	scrim := p.div(ui, "absolute inset-0 z-40 bg-black/35")
	if p.clickable(ui, scrim) && (t.stage == .Confirm || t.stage == .Done || t.stage == .Failed) {
		txn_cancel(t)
	}
	p.end(ui)

	win := p.size(ui)
	wrap := p.div(ui, tfmt("absolute z-50 w-[%d]", DIALOG_W))
	s := p.style(ui, wrap)
	s.inset[p.LEFT] = p.px((win.x - DIALOG_W) / 2)
	s.inset[p.TOP] = p.px(max(40, win.y * 0.16))
	defer p.end(ui)

	sc.dialog_content_open(ui)
	p.apply(ui, "shadow-2xl gap-4")
	defer p.end(ui)

	switch t.stage {
	case .Idle:
	case .Planning:
		planning(ui, st)
	case .Confirm:
		confirm(ui, st)
	case .Applying:
		applying(ui, st)
	case .Done:
		done(ui, st)
	case .Failed:
		failed(ui, st)
	}
}

// subject names what the change is about: "track", "track and emoji",
// "3 packages".
subject :: proc(t: ^Txn) -> string {
	switch len(t.packages) {
	case 0:
		return "the system"
	case 1:
		return t.packages[0]
	case 2:
		return tfmt("%s and %s", t.packages[0], t.packages[1])
	}
	return tfmt("%d packages", len(t.packages))
}

verb :: proc(a: Action) -> (present, past: string) {
	switch a {
	case .Add:
		return "Install", "installed"
	case .Del:
		return "Remove", "removed"
	case .Upgrade:
		return "Update", "updated"
	case .Update:
		return "Check for updates", "checked"
	}
	return "", ""
}

dialog_icon :: proc(ui: ^p.Ctx, ic: p.Icon, bg, fg: string) {
	p.div(ui, tfmt("flex-row size-10 shrink-0 items-center justify-center rounded-full %s", bg))
	p.icon(ui, ic, tfmt("size-5 %s", fg))
	p.end(ui)
}

dialog_head :: proc(ui: ^p.Ctx, ic: p.Icon, bg, fg, title, body: string) {
	p.row(ui, "w-full items-start gap-3")
	dialog_icon(ui, ic, bg, fg)
	p.col(ui, "flex-1 min-w-0 gap-1 pt-0.5")
	p.text(ui, title, "text-[15] font-semibold text-foreground")
	if body != "" {
		p.text(ui, body, "w-full text-[12.5] text-muted-foreground leading-[18]")
	}
	p.end(ui)
	p.end(ui)
}

planning :: proc(ui: ^p.Ctx, st: ^State) {
	present, _ := verb(st.txn.action)
	p.row(ui, "w-full items-center gap-3 py-2")
	sc.spinner(ui, "size-5 text-selection", f32(p.elapsed(ui)))
	p.col(ui, "flex-1 gap-0.5")
	p.text(ui, tfmt("%s %s", present, subject(&st.txn)), "text-[15] font-semibold text-foreground")
	p.text(ui, "Asking palmd what that would change…", "text-[12.5] text-muted-foreground")
	p.end(ui)
	p.end(ui)
	p.redraw(ui)
}

plan_group :: proc(ui: ^p.Ctx, title: string, items: []Plan_Item, ic: p.Icon, tone: string, show_from: bool) {
	if len(items) == 0 {
		return
	}
	p.col(ui, "w-full gap-1")
	p.row(ui, "w-full items-center gap-1.5")
	p.icon(ui, ic, tfmt("size-3.5 %s", tone))
	p.text(ui, tfmt("%s (%d)", title, len(items)), tfmt("text-[12] font-semibold whitespace-nowrap %s", tone))
	p.style(ui).shrink = 0
	p.end(ui)
	p.col(ui, "w-full rounded-lg border border-border bg-muted/40 px-3 py-1.5 gap-0.5")
	SHOW :: 8
	for it, i in items {
		if i >= SHOW {
			p.text(ui, tfmt("and %d more", len(items) - SHOW), "text-[12] text-muted-foreground py-0.5")
			break
		}
		p.row(ui, "w-full h-[22] items-center gap-2")
		p.text(ui, it.name, "text-[12.5] font-medium text-foreground whitespace-nowrap")
		p.style(ui).shrink = 0
		if show_from && it.from != "" {
			p.text(ui, tfmt("%s → %s", version_short(it.from), version_short(it.version)), "text-[12] text-muted-foreground whitespace-nowrap")
		} else {
			p.text(ui, version_short(it.version), "text-[12] text-muted-foreground whitespace-nowrap")
		}
		p.style(ui).shrink = 0
		p.spacer(ui, "flex-1")
		p.text(ui, human_size(it.size), "text-[12] text-muted-foreground whitespace-nowrap")
		p.style(ui).shrink = 0
		p.end(ui)
	}
	p.end(ui)
	p.end(ui)
}

confirm :: proc(ui: ^p.Ctx, st: ^State) {
	t := &st.txn
	present, _ := verb(t.action)
	if plan_empty(t.plan) {
		dialog_head(ui, ICON_CIRCLE_CHECK, "bg-emerald-500/15", "text-emerald-600", "Nothing to do", nothing_reason(st))
		p.div(ui, "flex-row w-full justify-end gap-2 pt-1")
		if button(ui, "dlg:close", "Close", nil, .Outline, .Default) {
			txn_reset(t)
		}
		p.end(ui)
		return
	}
	destructive := len(t.plan.remove) > 0 && len(t.plan.install) == 0 && len(t.plan.upgrade) == 0
	title := tfmt("%s %s?", present, subject(t))
	if t.action == .Upgrade {
		title = tfmt("Update %d %s?", len(t.plan.upgrade), len(t.plan.upgrade) == 1 ? "package" : "packages")
	}
	dialog_head(
		ui,
		destructive ? ICON_TRASH : ICON_PACKAGE,
		destructive ? "bg-destructive/10" : "bg-selection/10",
		destructive ? "text-destructive" : "text-selection",
		title,
		"palm worked out this plan. Nothing has changed yet.",
	)

	p.col(ui, "w-full gap-3")
	plan_group(ui, "Will install", t.plan.install, ICON_DOWNLOAD, "text-foreground", false)
	plan_group(ui, "Will update", t.plan.upgrade, ICON_REFRESH_CW, "text-foreground", true)
	plan_group(ui, "Will remove", t.plan.remove, ICON_TRASH, "text-destructive", false)
	p.end(ui)

	p.row(ui, "w-full items-center gap-4 px-0.5")
	summary_fact(ui, "Download", t.plan.download > 0 ? human_size(t.plan.download) : "nothing")
	change := t.plan.size_change
	summary_fact(ui, "Disk", change >= 0 ? tfmt("+%s", human_size(change)) : tfmt("−%s", human_size(-change)))
	p.end(ui)

	sc.dialog_footer_open(ui)
	p.apply(ui, "items-center")
	p.text(ui, "Enter to confirm · Esc to cancel", "text-[11.5] text-muted-foreground whitespace-nowrap")
	p.style(ui).shrink = 0
	p.spacer(ui, "flex-1")
	if button(ui, "dlg:cancel", "Cancel", nil, .Outline, .Default) {
		txn_cancel(t)
	}
	label := present
	if t.action == .Upgrade {
		label = "Update all"
	}
	if button(ui, "dlg:confirm", label, destructive ? ICON_TRASH : ICON_CHECK, destructive ? .Destructive : .Default, .Default, solid = true) {
		txn_confirm(t)
	}
	p.end(ui)
}

// nothing_reason explains an empty plan in terms of the request, which is
// the usual surprise: removing something another package needs.
nothing_reason :: proc(st: ^State) -> string {
	t := &st.txn
	if t.action == .Del && len(t.packages) == 1 {
		if pk := find(&st.cat, t.packages[0]); pk != nil && len(pk.required_by) > 0 {
			return tfmt("%s stays installed: %s %s it.", pk.name, strings.join(pk.required_by, ", ", context.temp_allocator), len(pk.required_by) == 1 ? "needs" : "need")
		}
	}
	if t.action == .Add {
		return tfmt("%s is already installed.", subject(t))
	}
	if t.action == .Upgrade {
		return "Every installed package is already the newest version the repository has."
	}
	return "palm found nothing to change."
}

summary_fact :: proc(ui: ^p.Ctx, label, value: string) {
	p.row(ui, "items-center gap-1.5")
	p.text(ui, label, "text-[12] text-muted-foreground whitespace-nowrap")
	p.style(ui).shrink = 0
	p.text(ui, value, "text-[12.5] font-semibold text-foreground whitespace-nowrap")
	p.style(ui).shrink = 0
	p.end(ui)
}

applying :: proc(ui: ^p.Ctx, st: ^State) {
	t := &st.txn
	present, _ := verb(t.action)
	title := t.action == .Update ? "Checking for updates" : tfmt("%s %s", ing(present), subject(t))
	p.row(ui, "w-full items-center gap-3")
	sc.spinner(ui, "size-5 text-selection", f32(p.elapsed(ui)))
	p.text(ui, title, "flex-1 text-[15] font-semibold text-foreground")
	p.end(ui)
	p.col(ui, "w-full gap-2")
	p.row(ui, "w-full items-center gap-2")
	p.text(ui, t.current != "" ? t.current : "Starting", "flex-1 min-w-0 text-[12.5] text-foreground truncate")
	if t.steps > 0 {
		p.text(ui, tfmt("%d of %d", t.step, t.steps), "text-[12] text-muted-foreground whitespace-nowrap")
		p.style(ui).shrink = 0
	}
	p.end(ui)
	pct := t.steps > 0 ? 100 * f32(t.step) / f32(t.steps) : 0
	progress_bar(ui, pct, t.steps == 0)
	p.end(ui)
	log_box(ui, t.log[:])
	p.text(ui, "palm keeps going if this window closes; /var/log/palmd.log records it.", "text-[11.5] text-muted-foreground")
	p.redraw(ui)
}

// progress_bar is shadcn's progress track in the accent colour, a little
// taller; before palm reports its first step there is no fraction to show,
// so it sweeps.
progress_bar :: proc(ui: ^p.Ctx, percent: f32, indeterminate: bool) {
	p.div(ui, "relative flex-row h-1.5 w-full items-center overflow-hidden rounded-full bg-muted")
	defer p.end(ui)
	if indeterminate {
		t := f32(ui.now) - f32(int(f32(ui.now) / 1.4)) * 1.4
		left := (t / 1.4) * 135 - 35
		p.div(ui, "absolute h-full bg-selection rounded-full")
		s := p.style(ui)
		s.inset[p.TOP] = p.px(0)
		s.inset[p.BOTTOM] = p.px(0)
		s.inset[p.LEFT] = p.pct(max(0, left))
		s.inset[p.RIGHT] = p.pct(max(0, 100 - (left + 35)))
		p.end(ui)
		ui.animating = true
		return
	}
	p.div(ui, "h-full bg-selection rounded-full")
	p.style(ui).w = p.pct(percent)
	p.end(ui)
}

ing :: proc(present: string) -> string {
	switch present {
	case "Install":
		return "Installing"
	case "Remove":
		return "Removing"
	case "Update":
		return "Updating"
	}
	return present
}

log_box :: proc(ui: ^p.Ctx, lines: []string) {
	if len(lines) == 0 {
		return
	}
	p.col(ui, "w-full rounded-lg border border-border bg-muted/40 px-3 py-2 gap-0.5")
	start := max(0, len(lines) - 6)
	for l in lines[start:] {
		p.text(ui, l, "w-full text-[11.5] font-mono text-muted-foreground")
	}
	p.end(ui)
}

done :: proc(ui: ^p.Ctx, st: ^State) {
	t := &st.txn
	_, past := verb(t.action)
	title := tfmt(len(t.packages) > 1 ? "%s are %s" : "%s is %s", subject(t), past)
	body := done_sentence(t.plan)
	switch t.action {
	case .Upgrade:
		title = "The system is up to date"
	case .Update:
		title = "Repositories checked"
		ups := len(upgradable(&st.cat))
		body = ups == 0 ? "Everything is up to date." : tfmt("%d %s available.", ups, ups == 1 ? "update is" : "updates are")
	case .Add, .Del:
	}
	dialog_head(ui, ICON_CIRCLE_CHECK, "bg-emerald-500/15", "text-emerald-600", title, body)
	log_box(ui, t.log[:])
	p.div(ui, "flex-row w-full justify-end gap-2 pt-1")
	if t.action == .Add && len(t.packages) == 1 {
		if pk := find(&st.cat, t.packages[0]); pk != nil && command_of(pk) != "" && pk.installed != "" {
			if button(ui, "dlg:open", "Open", ICON_EXTERNAL_LINK, .Outline, .Default) {
				open_app(st, pk)
				txn_reset(t)
				return
			}
		}
	}
	if button(ui, "dlg:done", "Done", nil, .Default, .Default) {
		txn_reset(t)
	}
	p.end(ui)
}

// done_sentence is plan_sentence after the fact: what palm did.
done_sentence :: proc(pl: Plan) -> string {
	parts := make([dynamic]string, context.temp_allocator)
	names :: proc(items: []Plan_Item) -> string {
		ns := make([dynamic]string, context.temp_allocator)
		for it in items {append(&ns, it.name)}
		return strings.join(ns[:], ", ", context.temp_allocator)
	}
	if len(pl.install) > 0 {append(&parts, tfmt("installed %s", names(pl.install)))}
	if len(pl.upgrade) > 0 {append(&parts, tfmt("updated %s", names(pl.upgrade)))}
	if len(pl.remove) > 0 {append(&parts, tfmt("removed %s", names(pl.remove)))}
	if len(parts) == 0 {
		return "Nothing needed changing."
	}
	s := strings.join(parts[:], "; ", context.temp_allocator)
	return tfmt("palm %s.", s)
}

failed :: proc(ui: ^p.Ctx, st: ^State) {
	t := &st.txn
	present, _ := verb(t.action)
	title := tfmt("Could not %s %s", strings.to_lower(present, context.temp_allocator), subject(t))
	if t.action == .Update {
		title = "Could not check for updates"
	}
	dialog_head(ui, ICON_CIRCLE_ALERT, "bg-destructive/10", "text-destructive", title, "palm's words, as it said them:")
	p.col(ui, "w-full rounded-lg border border-destructive/30 bg-destructive/5 px-3 py-2.5 gap-1")
	p.text(ui, t.error, "w-full text-[12] font-mono text-destructive leading-[17]")
	if t.code != 0 {
		p.text(ui, tfmt("exit %d · %s", t.code, exit_meaning(t.code)), "text-[11.5] text-muted-foreground")
	}
	p.end(ui)
	log_box(ui, t.log[:])
	if !plan_empty(t.plan) && t.code == 4 {
		p.text(ui, tfmt("The plan is now: %s.", plan_sentence(t.plan)), "w-full text-[12.5] text-muted-foreground")
	}
	p.div(ui, "flex-row w-full justify-end gap-2 pt-1")
	if button(ui, "dlg:close", "Close", nil, .Outline, .Default) {
		txn_reset(t)
	}
	p.end(ui)
}

// exit_meaning is palm's exit code table (distro/palm/main.odin).
exit_meaning :: proc(code: int) -> string {
	switch code {
	case 1:
		return "verify found problems"
	case 2:
		return "usage"
	case 3:
		return "not found"
	case 4:
		return "refused"
	case 6:
		return "unavailable"
	case 7:
		return "failed"
	}
	return fmt.tprintf("status %d", code)
}
