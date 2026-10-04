package main

// The frame.
//
// Three columns: the conversation list, the workspace, and the parameter
// panel. Overlays (model picker, prompt library, model pull, the system
// prompt, confirmations) are drawn inside the window as absolutely positioned
// panels over a scrim, because palmy has no xdg_popup — that is a constraint
// of the toolkit, not a shortcut.

import "core:fmt"
import "core:strings"
import kit "kit:."
import p "palmy:."
import sc "shadcn:."

TOPBAR_H :: 52
FOOTER_H :: 30

build :: proc(ui: ^p.Ctx, st: ^St) {
	pv := probe_view(&st.probe, context.temp_allocator)

	sidebar(ui, st, pv)

	p.col(ui, "flex-1 min-w-0 h-full overflow-hidden")
	topbar(ui, st, pv)
	transcript(ui, st, pv)
	stats_strip(ui, st, pv)
	composer(ui, st)
	footer(ui, st)
	p.end(ui)

	if st.show_params {
		params_panel(ui, st, pv)
	}

	if st.overlay != .None {
		overlay(ui, st, pv)
	}
}

// ---------------------------------------------------------------------------
// Sidebar
// ---------------------------------------------------------------------------

sidebar :: proc(ui: ^p.Ctx, st: ^St, pv: Probe_View) {
	p.col(ui, "h-full shrink-0 border-r border-border bg-sidebar overflow-hidden")
	p.style(ui).w = p.px(SIDEBAR_W)
	defer p.end(ui)

	// Header.
	p.row(ui, "w-full items-center gap-2 px-3 shrink-0 border-b border-border")
	p.style(ui).h = p.px(TOPBAR_H)
	p.div(ui, "size-7 shrink-0 flex-row items-center justify-center rounded-lg bg-primary")
	p.icon(ui, IC_SPARKLES, "size-4 text-primary-foreground")
	p.end(ui)
	p.col(ui, "flex-1 min-w-0")
	p.text(ui, "palmy ai", "text-sm font-semibold whitespace-nowrap")
	p.text(ui, "local models only", "text-[10.5] text-muted-foreground whitespace-nowrap")
	p.end(ui)
	p.end(ui)

	// New conversation.
	p.row(ui, "w-full shrink-0 px-2.5 pt-2.5 pb-1.5 items-center gap-2")
	idx := p.div(
		ui,
		"flex-1 flex-row h-8 items-center gap-2 px-2.5 rounded-lg border border-border " +
		"bg-background hover:bg-muted transition cursor-pointer",
	)
	if p.clickable(ui, idx) {
		new_conversation(st)
	}
	p.icon(ui, sc.ICON_PLUS, "size-3.5 shrink-0 text-muted-foreground")
	p.text(ui, "New conversation", "text-xs font-medium whitespace-nowrap")
	p.style(ui).shrink = 0
	p.spacer(ui)
	sc.kbd(ui, "^N")
	p.end(ui)
	p.end(ui)

	// The list.
	list := p.col(ui, "w-full flex-1 min-h-0 px-2 pb-2 gap-0.5 overflow-scroll")
	for c, i in st.convs {
		p.key(ui, c.id)
		conv_row(ui, st, &st.convs[i], i, i == st.cur)
	}
	if len(st.convs) == 0 {
		p.text(ui, "No conversations yet", "text-xs text-muted-foreground p-2")
	}
	p.end(ui)
	_ = list

	// Runtime status.
	sc.separator(ui, .Horizontal)
	p.col(ui, "w-full shrink-0 gap-1 px-3 py-2.5")
	p.row(ui, "w-full items-center gap-2")
	up := pv.err == ""
	dot := p.div(ui, "size-2 shrink-0 rounded-full")
	p.apply(ui, up ? "bg-emerald-500" : "bg-destructive", dot)
	p.end(ui)
	p.text(
		ui,
		up ? (pv.version != "" ? p.concat(ui, "ollama ", pv.version) : "ollama") : "ollama is down",
		"text-[11] font-medium whitespace-nowrap",
	)
	p.style(ui).shrink = 0
	p.spacer(ui)
	if st.zone == .Chats {
		sc.badge(ui, "focus", .Outline)
	}
	p.end(ui)
	p.text(ui, "127.0.0.1:11434", "text-[10.5] font-mono text-muted-foreground whitespace-nowrap")
	if len(pv.loaded) > 0 {
		l := pv.loaded[0]
		p.textf(
			ui,
			"text-[10.5] text-muted-foreground whitespace-nowrap",
			"%s resident · %s",
			human_bytes(l.size, context.temp_allocator),
			l.vram > 0 ? "GPU" : "CPU",
		)
	} else {
		p.text(
			ui,
			"no model resident",
			"text-[10.5] text-muted-foreground whitespace-nowrap",
		)
	}
	p.end(ui)
}

conv_row :: proc(ui: ^p.Ctx, st: ^St, c: ^Conversation, i: int, sel: bool) {
	idx := p.col(ui, "w-full shrink-0 gap-0 px-2 py-1.5 rounded-lg transition cursor-pointer")
	p.apply(ui, sel ? "bg-sidebar-accent" : "hover:bg-muted", idx)
	if p.clickable(ui, idx) {
		pick_conv(st, i)
	}
	defer p.end(ui)

	p.row(ui, "w-full items-center gap-1.5")
	p.icon(
		ui,
		IC_MESSAGE_SQUARE,
		sel ? "size-3 shrink-0 text-foreground" : "size-3 shrink-0 text-muted-foreground",
	)
	p.text(ui, c.title, "flex-1 min-w-0 text-xs truncate whitespace-nowrap")
	p.end(ui)
	p.row(ui, "w-full items-center gap-1.5 pl-[18]")
	p.textf(
		ui,
		"text-[10] text-muted-foreground whitespace-nowrap",
		"%d messages",
		len(c.msgs),
	)
	p.style(ui).shrink = 0
	if c.model != "" {
		p.text(ui, "·", "text-[10] text-muted-foreground")
		p.text(ui, c.model, "text-[10] text-muted-foreground whitespace-nowrap truncate")
	}
	p.end(ui)
}

// ---------------------------------------------------------------------------
// Top bar
// ---------------------------------------------------------------------------

topbar :: proc(ui: ^p.Ctx, st: ^St, pv: Probe_View) {
	p.row(ui, "w-full shrink-0 items-center gap-2.5 px-4 border-b border-border")
	p.style(ui).h = p.px(TOPBAR_H)
	defer p.end(ui)

	mi, have := find_model(pv, st.model)

	// The model chip is the app's claim about what is answering, so it carries
	// the real numbers from /api/tags rather than a friendly name.
	idx := p.row(
		ui,
		"shrink-0 items-center gap-2 h-8 pl-2 pr-2.5 rounded-lg border border-border " +
		"bg-background hover:bg-muted transition cursor-pointer",
	)
	if p.clickable(ui, idx) {
		open_overlay(st, .Models)
	}
	p.icon(ui, IC_CPU, "size-3.5 shrink-0 text-muted-foreground")
	p.text(ui, st.model, "text-xs font-medium whitespace-nowrap")
	p.style(ui).shrink = 0
	if have {
		p.text(ui, "·", "text-xs text-muted-foreground")
		p.text(
			ui,
			mi.params == "" ? "?" : mi.params,
			"text-xs text-muted-foreground whitespace-nowrap",
		)
		p.style(ui).shrink = 0
		p.text(ui, "·", "text-xs text-muted-foreground")
		p.text(
			ui,
			human_bytes(mi.size, context.temp_allocator),
			"text-xs text-muted-foreground whitespace-nowrap",
		)
		p.style(ui).shrink = 0
	} else if pv.got && pv.err == "" {
		sc.badge(ui, "not installed", .Destructive)
	}
	p.icon(ui, IC_CHEVRONS_UP_DOWN, "size-3 shrink-0 text-muted-foreground")
	p.end(ui)

	if have && mi.quant != "" {
		sc.badge(ui, mi.quant, .Outline)
	}

	// Thinking and reasoning: both visible, both a key away, because a user
	// whose first reply is empty will think the program is broken.
	toggle_chip(ui, "Thinking", st.pr.think, IC_BRAIN, "^T")
	if p.clickable(ui) {
		st.pr.think = !st.pr.think
		settings_save(st.model, st.pr, st.show_think)
	}
	toggle_chip(ui, "Show reasoning", st.show_think, sc.ICON_INFO, "^R")
	if p.clickable(ui) {
		st.show_think = !st.show_think
		settings_save(st.model, st.pr, st.show_think)
	}

	p.spacer(ui)

	if len(pv.loaded) > 0 {
		l := pv.loaded[0]
		stat_chip(
			ui,
			IC_HARD_DRIVE,
			"resident",
			fmt.tprintf("%s", human_bytes(l.size, context.temp_allocator)),
		)
		if l.ctx > 0 {
			stat_chip(ui, IC_LIST_TREE, "ctx", fmt.tprintf("%d", l.ctx))
		}
	}

	pidx := p.row(
		ui,
		"shrink-0 items-center gap-1.5 h-8 px-2.5 rounded-lg border transition cursor-pointer",
	)
	p.apply(
		ui,
		st.show_params ? "border-border bg-muted" : "border-border bg-background hover:bg-muted",
		pidx,
	)
	if p.clickable(ui, pidx) {
		st.show_params = !st.show_params
	}
	p.icon(ui, sc.ICON_SETTINGS, "size-3.5 shrink-0 text-muted-foreground")
	p.text(ui, "Parameters", "text-xs font-medium whitespace-nowrap")
	p.style(ui).shrink = 0
	p.end(ui)
}

toggle_chip :: proc(ui: ^p.Ctx, label: string, on: bool, ic: p.Icon, key: string) -> int {
	idx := p.row(
		ui,
		"shrink-0 items-center gap-1.5 h-8 px-2 rounded-lg border transition cursor-pointer",
	)
	p.apply(
		ui,
		on \
		? "border-primary/40 bg-primary/15 text-foreground" \
		: "border-border bg-background text-muted-foreground hover:bg-muted",
		idx,
	)
	defer p.end(ui)
	p.icon(ui, ic, "size-3.5 shrink-0")
	p.text(ui, label, "text-xs font-medium whitespace-nowrap")
	p.style(ui).shrink = 0
	sc.switch_(ui, on, .SM)
	return idx
}

stat_chip :: proc(ui: ^p.Ctx, ic: p.Icon, label, value: string) {
	p.row(ui, "shrink-0 items-center gap-1.5 h-8 px-2.5 rounded-lg bg-muted")
	defer p.end(ui)
	p.icon(ui, ic, "size-3 shrink-0 text-muted-foreground")
	p.text(ui, label, "text-[11] text-muted-foreground whitespace-nowrap")
	p.style(ui).shrink = 0
	p.text(ui, value, "text-[11] font-medium font-mono whitespace-nowrap")
	p.style(ui).shrink = 0
}

find_model :: proc(pv: Probe_View, name: string) -> (Model_Info, bool) {
	for m in pv.models {
		if m.name == name {
			return m, true
		}
	}
	return {}, false
}

// ---------------------------------------------------------------------------
// Transcript
// ---------------------------------------------------------------------------

transcript :: proc(ui: ^p.Ctx, st: ^St, pv: Probe_View) {
	tr := p.col(ui, "w-full flex-1 min-h-0 px-5 py-4 gap-5 overflow-scroll")
	st.tr_id = p.node_id(ui, tr)
	defer p.end(ui)

	c := cur_conv(st)

	if pv.err != "" {
		runtime_down(ui, pv)
	}

	if c == nil || len(c.msgs) == 0 {
		if pv.err == "" {
			empty_state(ui, st, pv)
		}
	} else {
		width := p.size(ui).x - SIDEBAR_W - (st.show_params ? PARAMS_W : 0) - 40
		bubble_max := max(320, width * 0.78)
		for i in 0 ..< len(c.msgs) {
			p.key(ui, fmt.tprintf("m%d", i))
			live := st.streaming && i == len(c.msgs) - 1
			message_block(ui, st, &c.msgs[i], i, live, bubble_max)
		}
	}

	// The sentinel the pin scrolls to. `scroll_into_view` needs a target that
	// was laid out, which is why it is a real element rather than a number.
	endm := p.div(ui, "w-full shrink-0")
	p.style(ui).h = p.px(1)
	st.end_id = p.node_id(ui, endm)
	p.end(ui)

	if st.pinned {
		p.scroll_into_view(ui, st.tr_id, st.end_id, 4)
	}
}

runtime_down :: proc(ui: ^p.Ctx, pv: Probe_View) {
	p.col(
		ui,
		"w-full shrink-0 gap-2 p-4 rounded-xl border border-destructive/40 bg-destructive/10",
	)
	defer p.end(ui)
	p.row(ui, "items-center gap-2")
	p.icon(ui, IC_WIFI_OFF, "size-4 shrink-0 text-destructive")
	p.text(ui, "The ollama runtime is not answering", "text-sm font-semibold text-destructive")
	p.end(ui)
	p.text(ui, pv.err, "text-xs text-muted-foreground")
	p.text(ui, "Start it in a terminal, then this banner clears itself:", "text-xs")
	p.div(ui, "w-full rounded-lg bg-muted px-2.5 py-2 border border-border")
	p.text(ui, START_HINT, "font-mono text-[12.5] whitespace-nowrap")
	p.end(ui)
	p.text(
		ui,
		"It is deliberately a user process on this machine, not a system service.",
		"text-[11] text-muted-foreground",
	)
}

empty_state :: proc(ui: ^p.Ctx, st: ^St, pv: Probe_View) {
	p.col(ui, "w-full flex-1 items-center justify-center gap-3 py-10")
	defer p.end(ui)

	p.div(ui, "size-12 flex-row items-center justify-center rounded-2xl bg-muted ring-1 ring-border")
	p.icon(ui, IC_SPARKLES, "size-5 text-muted-foreground")
	p.end(ui)
	p.text(ui, "Everything here runs on this machine", "text-sm font-semibold")
	mi, have := find_model(pv, st.model)
	if have {
		p.textf(
			ui,
			"text-xs text-muted-foreground",
			"%s — %s parameters, %s on disk. A model this small is quick and often wrong; check what it tells you.",
			mi.name,
			mi.params,
			human_bytes(mi.size, context.temp_allocator),
		)
	} else {
		p.text(
			ui,
			"Pick a model with Ctrl+M, or pull one with Ctrl+O.",
			"text-xs text-muted-foreground",
		)
	}
	p.row(ui, "items-center gap-4 pt-2")
	hint(ui, "^P", "prompt library")
	hint(ui, "^T", "thinking")
	hint(ui, "^,", "parameters")
	hint(ui, "F1", "all keys")
	p.end(ui)
}

message_block :: proc(ui: ^p.Ctx, st: ^St, m: ^Message, i: int, live: bool, maxw: f32) {
	user := m.role == .User

	p.col(ui, "w-full min-w-0 gap-1.5")
	p.style(ui).items = user ? .End : .Start
	defer p.end(ui)

	text := live ? st.live.content : m.text
	think := live ? st.live.think : m.think

	// Caption: who said this, and — for a reply — what it cost.
	p.row(ui, "shrink-0 items-center gap-2 px-1")
	if user {
		p.text(ui, "You", "text-[11] font-medium text-muted-foreground whitespace-nowrap")
		p.style(ui).shrink = 0
		p.icon(ui, sc.ICON_USER, "size-3 shrink-0 text-muted-foreground")
	} else {
		p.icon(ui, IC_CPU, "size-3 shrink-0 text-muted-foreground")
		p.text(
			ui,
			m.model == "" ? "assistant" : m.model,
			"text-[11] font-medium text-muted-foreground whitespace-nowrap",
		)
		p.style(ui).shrink = 0
		if live {
			s := st.live
			p.text(ui, "·", "text-[11] text-muted-foreground")
			if s.ttft > 0 {
				p.textf(
					ui,
					"text-[11] font-mono text-muted-foreground whitespace-nowrap",
					"%.0f ms to first token",
					s.ttft * 1000,
				)
				p.style(ui).shrink = 0
			} else {
				p.text(
					ui,
					"waiting for the first token…",
					"text-[11] text-muted-foreground whitespace-nowrap",
				)
				p.style(ui).shrink = 0
			}
		} else if m.out_n > 0 {
			p.text(ui, "·", "text-[11] text-muted-foreground")
			p.textf(
				ui,
				"text-[11] font-mono text-muted-foreground whitespace-nowrap",
				"%d tok · %.1f tok/s · %.0f ms ttft",
				m.out_n,
				m.tps,
				m.ttft * 1000,
			)
			p.style(ui).shrink = 0
		}
		if m.halted {
			sc.badge(ui, "stopped", .Outline)
		}
		if live && st.live.reason == "length" {
			sc.badge(ui, "hit the reply limit", .Destructive)
		}
	}
	p.end(ui)

	// Reasoning, above the answer, collapsed by default once there is an
	// answer to read.
	if !user && think != "" && st.show_think {
		// Expanded while there is nothing else to read: a bubble that is
		// empty because the budget went into the reasoning should still show
		// the reasoning.
		reasoning_block(ui, st, i, think, text == "", min(maxw, 820))
	}

	if text == "" {
		if live && think == "" {
			thinking_dots(ui, st)
		} else if !live && think == "" {
			// A reply that was never recorded — an older conversation saved
			// while the runtime was down. Say so rather than drawing a gap.
			p.row(ui, "shrink-0 items-center gap-1.5 rounded-xl border border-dashed border-border px-3 py-1.5")
			p.icon(ui, sc.ICON_CIRCLE_ALERT, "size-3 shrink-0 text-muted-foreground")
			p.text(
				ui,
				"no reply was recorded",
				"text-[11.5] text-muted-foreground whitespace-nowrap",
			)
			p.style(ui).shrink = 0
			p.end(ui)
		}
		return
	}

	// The bubble. shadcn's `bubble_content` pins its text run to one line, so
	// the class vocabulary is reused and the body is composed here.
	b := p.col(ui, sc.BUBBLE_CONTENT_BASE)
	p.apply(ui, sc.bubble_content_class(user ? .Secondary : .Muted), b)
	p.apply(ui, "min-w-0", b)
	p.style(ui, b).max_w = p.px(maxw)
	p.style(ui, b).self = user ? .End : .Start
	if user {
		p.text(ui, text, "text-sm")
		p.style(ui).max_w = p.px(maxw - 26)
	} else {
		md_render(ui, text, maxw - 26, 14)
	}
	p.end(ui)

	if live && text != "" {
		// A caret at the end of the stream, so it is obvious the reply is
		// still arriving.
		p.row(ui, "shrink-0 items-center gap-1.5 px-1")
		p.div(ui, "w-1.5 h-3.5 rounded-sm bg-primary")
		p.end(ui)
		p.text(ui, "generating", "text-[10.5] text-muted-foreground whitespace-nowrap")
		p.style(ui).shrink = 0
		p.end(ui)
	}

	// Per-message actions.
	if !user && !live {
		p.row(ui, "shrink-0 items-center gap-1 px-1")
		if msg_action(ui, sc.ICON_COPY, "Copy") {
			if kit.clipboard_set(m.text) {
				toast(st, "Reply copied")
			} else {
				toast(st, "wl-copy is not installed, so there is no clipboard")
			}
		}
		if msg_action(ui, IC_REFRESH_CW, "Regenerate") {
			regenerate(st)
		}
		if msg_action(ui, IC_PENCIL, "Edit the question") {
			edit_last(st)
		}
		if m.in_n > 0 {
			p.textf(
				ui,
				"text-[10] font-mono text-muted-foreground whitespace-nowrap pl-1",
				"%d prompt tokens in",
				m.in_n,
			)
			p.style(ui).shrink = 0
		}
		p.end(ui)
	}
}

msg_action :: proc(ui: ^p.Ctx, ic: p.Icon, label: string) -> bool {
	idx := p.row(
		ui,
		"shrink-0 items-center gap-1 h-6 px-1.5 rounded-md border border-transparent " +
		"hover:bg-muted hover:border-border transition cursor-pointer",
	)
	hit := p.clickable(ui, idx)
	defer p.end(ui)
	p.icon(ui, ic, "size-3 shrink-0 text-muted-foreground")
	p.text(ui, label, "text-[10.5] text-muted-foreground whitespace-nowrap")
	p.style(ui).shrink = 0
	return hit
}

reasoning_block :: proc(ui: ^p.Ctx, st: ^St, i: int, think: string, force_open: bool, maxw: f32) {
	open := st.think_open[i] || force_open

	// An explicit width, not `max-w`: palmy sizes a shrink-to-fit box from its
	// text child, and the text child measures against the width the box had
	// last frame, so the two chase each other down to nothing.
	box := p.col(
		ui,
		"shrink-0 min-w-0 gap-1.5 rounded-lg border border-dashed border-border bg-muted/40 px-2.5 py-2",
	)
	p.style(ui, box).w = p.px(maxw)
	defer p.end(ui)

	head := p.row(ui, "w-full items-center gap-1.5 cursor-pointer")
	if p.clickable(ui, head) {
		st.think_open[i] = !st.think_open[i]
	}
	p.icon(ui, IC_BRAIN, "size-3 shrink-0 text-muted-foreground")
	p.text(ui, "Reasoning", "text-[11] font-medium text-muted-foreground whitespace-nowrap")
	p.style(ui).shrink = 0
	p.textf(
		ui,
		"text-[10] font-mono text-muted-foreground whitespace-nowrap",
		"%d chars",
		len(think),
	)
	p.style(ui).shrink = 0
	p.spacer(ui)
	if !force_open {
		sc.kbd(ui, "^B")
	}
	p.icon(
		ui,
		open ? sc.ICON_CHEVRON_UP : sc.ICON_CHEVRON_DOWN,
		"size-3 shrink-0 text-muted-foreground",
	)
	p.end(ui)

	if !open {
		// One line of it, so a collapsed block still says something.
		first := think
		if nl := strings.index_byte(first, '\n'); nl > 0 {
			first = first[:nl]
		}
		if len(first) > 110 {
			cut := 110
			for cut > 0 && first[cut] & 0xc0 == 0x80 {
				cut -= 1
			}
			first = first[:cut]
		}
		p.text(
			ui,
			p.concat(ui, first, "…"),
			"text-[11.5] text-muted-foreground/80 whitespace-nowrap truncate w-full",
		)
		return
	}
	p.col(ui, "w-full min-w-0 pt-0.5")
	p.text(ui, think, "text-[12] leading-[18] text-muted-foreground")
	p.style(ui).max_w = p.px(maxw - 22)
	p.end(ui)
}

thinking_dots :: proc(ui: ^p.Ctx, st: ^St) {
	p.row(ui, "shrink-0 items-center gap-2 rounded-xl bg-muted px-3 py-2")
	defer p.end(ui)
	p.icon(ui, sc.ICON_LOADER_CIRCLE, "size-3.5 shrink-0 text-muted-foreground", f32(mono()) * 0.8)
	label := st.pr.think ? "reasoning before answering…" : "the model is loading / prefilling…"
	p.text(ui, label, "text-xs text-muted-foreground whitespace-nowrap")
	p.style(ui).shrink = 0
	ui.animating = true
}

// ---------------------------------------------------------------------------
// Live stats
// ---------------------------------------------------------------------------

stats_strip :: proc(ui: ^p.Ctx, st: ^St, pv: Probe_View) {
	if !st.streaming && !st.pulling && st.live.eval_n == 0 {
		return
	}

	p.row(ui, "w-full shrink-0 items-center gap-3 px-4 border-t border-border bg-muted/30")
	p.style(ui).h = p.px(34)
	defer p.end(ui)

	if st.pulling {
		s := st.pull_live
		p.icon(ui, sc.ICON_DOWNLOAD, "size-3.5 shrink-0 text-muted-foreground")
		p.textf(ui, "text-xs whitespace-nowrap", "pulling %s", s.model)
		p.style(ui).shrink = 0
		p.text(ui, s.status, "text-xs text-muted-foreground whitespace-nowrap truncate")
		if s.total > 0 {
			frac := f32(f64(s.completed) / f64(s.total))
			p.div(ui, "h-1 flex-1 min-w-[80] rounded-full bg-muted overflow-hidden")
			p.div(ui, "h-full rounded-full bg-primary")
			p.style(ui).w = p.pct(clamp(frac, 0, 1) * 100)
			p.end(ui)
			p.end(ui)
			p.textf(ui, "text-xs font-mono whitespace-nowrap", "%.0f%%", frac * 100)
			p.style(ui).shrink = 0
		}
		return
	}

	s := st.live
	// While the reply is arriving the rate is measured from the chunks that
	// have landed; when it is over, ollama's own eval_count/eval_duration
	// replace the estimate.
	live_rate: f32 = 0
	gen := s.elapsed - s.ttft
	if st.streaming && gen > 0.05 && s.tokens > 1 {
		live_rate = f32(f64(s.tokens) / gen)
	}
	final_rate: f32 = 0
	if s.eval_ns > 0 {
		final_rate = f32(f64(s.eval_n) / (f64(s.eval_ns) / 1e9))
	}

	if st.streaming {
		p.icon(ui, IC_ZAP, "size-3.5 shrink-0 text-emerald-500")
		p.text(ui, "streaming", "text-xs font-medium whitespace-nowrap")
		p.style(ui).shrink = 0
	} else {
		p.icon(ui, sc.ICON_CIRCLE_CHECK, "size-3.5 shrink-0 text-muted-foreground")
		p.text(ui, "done", "text-xs font-medium text-muted-foreground whitespace-nowrap")
		p.style(ui).shrink = 0
	}

	num(ui, "tok/s", fmt.tprintf("%.1f", final_rate > 0 ? final_rate : live_rate))
	num(
		ui,
		"first token",
		s.ttft > 0 ? fmt.tprintf("%.0f ms", s.ttft * 1000) : "—",
	)
	num(ui, "out", fmt.tprintf("%d", s.eval_n > 0 ? s.eval_n : s.tokens))
	num(ui, "in", s.prompt_n > 0 ? fmt.tprintf("%d", s.prompt_n) : "—")
	num(ui, "elapsed", fmt.tprintf("%.1f s", s.elapsed))
	if s.load_ns > 0 {
		num(ui, "load", fmt.tprintf("%.0f ms", f64(s.load_ns) / 1e6))
	}
	if len(pv.loaded) > 0 {
		num(ui, "resident", human_bytes(pv.loaded[0].size, context.temp_allocator))
	}

	p.spacer(ui)
	if st.streaming {
		idx := p.row(
			ui,
			"shrink-0 items-center gap-1.5 h-7 px-2.5 rounded-lg border border-destructive/40 " +
			"bg-destructive/10 hover:bg-destructive/20 transition cursor-pointer",
		)
		if p.clickable(ui, idx) {
			stop_generation(st)
		}
		p.icon(ui, IC_SQUARE, "size-3 shrink-0 text-destructive")
		p.text(ui, "Stop", "text-xs font-medium text-destructive whitespace-nowrap")
		p.style(ui).shrink = 0
		sc.kbd(ui, "Esc")
		p.end(ui)
	}
}

num :: proc(ui: ^p.Ctx, label, value: string) {
	p.row(ui, "shrink-0 items-baseline gap-1")
	defer p.end(ui)
	p.text(ui, value, "text-xs font-mono font-medium whitespace-nowrap")
	p.style(ui).shrink = 0
	p.text(ui, label, "text-[10.5] text-muted-foreground whitespace-nowrap")
	p.style(ui).shrink = 0
}

// ---------------------------------------------------------------------------
// Composer
// ---------------------------------------------------------------------------

COMPOSER_LINES :: 6

composer :: proc(ui: ^p.Ctx, st: ^St) {
	focused := st.zone == .Composer && st.overlay == .None

	p.col(ui, "w-full shrink-0 px-4 pt-3 pb-2 gap-2 border-t border-border")
	defer p.end(ui)

	box := p.row(ui, "w-full items-end gap-2 rounded-xl border bg-background px-3 py-2.5 transition")
	p.apply(ui, focused ? "border-ring ring-3 ring-ring/40" : "border-input", box)
	if p.clickable(ui, box) {
		st.zone = .Composer
	}
	{
		// The editor. palmy's text_field is one line, so the wrapping, the
		// caret and the vertical scroll are this app's own; `text_width` and
		// `text_index_at` are the two measurements that make it possible.
		p.col(ui, "flex-1 min-w-0 gap-0 overflow-hidden")
		defer p.end(ui)

		avail := p.size(ui).x - SIDEBAR_W - (st.show_params ? PARAMS_W : 0) - 140
		size: f32 = 14
		text := composer_text(st)
		vis := wrap_visual(ui, text, size, max(120, avail))

		// Keep the caret's line on screen.
		cl := caret_line(vis, st.caret)
		first := 0
		if cl >= COMPOSER_LINES {
			first = cl - COMPOSER_LINES + 1
		}
		last := min(first + COMPOSER_LINES, len(vis))

		if len(text) == 0 {
			p.row(ui, "w-full items-center")
			p.style(ui).h = p.px(20)
			p.text(
				ui,
				"Ask the model something. Enter sends, Shift+Enter makes a new line.",
				"text-sm text-muted-foreground whitespace-nowrap",
			)
			p.style(ui).shrink = 0
			if focused {
				// A solid caret, not a blinking one. A blink has to mark the
				// window animating on every frame, and palmy then redraws a
				// 1920x1080 software-rasterised window at the display rate
				// forever — about half a core, for a window that is doing
				// nothing. An idle palmy window should cost nothing, so the
				// caret does not move.
				car := p.div(ui, "absolute w-[1.5] rounded-full bg-foreground")
				cs := p.style(ui, car)
				cs.inset[p.LEFT] = p.px(0)
				cs.inset[p.TOP] = p.px(2)
				cs.h = p.px(16)
				p.end(ui)
			}
			p.end(ui)
		}
		for li in first ..< (len(text) == 0 ? 0 : last) {
			p.key(ui, fmt.tprintf("cl%d", li))
			seg := vis[li]
			p.row(ui, "w-full items-center")
			p.style(ui).h = p.px(20)
			p.text(ui, text[seg.start:seg.end], "text-sm whitespace-nowrap")
			p.style(ui).shrink = 0
			if focused && st.caret >= seg.start && st.caret <= seg.end {
				// Placed by measuring the prefix, the same measurement that
				// would hit-test a click.
				cx := p.text_width(ui.fonts, text[seg.start:st.caret], size, .Sans, .Regular)
				car := p.div(ui, "absolute w-[1.5] rounded-full bg-foreground")
				cs := p.style(ui, car)
				cs.inset[p.LEFT] = p.px(cx)
				cs.inset[p.TOP] = p.px(2)
				cs.h = p.px(16)
				p.end(ui)
			}
			p.end(ui)
		}
		if len(vis) > COMPOSER_LINES {
			p.textf(
				ui,
				"text-[10] text-muted-foreground whitespace-nowrap",
				"%d of %d lines",
				last,
				len(vis),
			)
			p.style(ui).shrink = 0
		}
	}

	// Send / Stop.
	if st.streaming {
		idx := p.row(
			ui,
			"shrink-0 items-center gap-1.5 h-8 px-3 rounded-lg bg-destructive/15 " +
			"border border-destructive/40 hover:bg-destructive/25 transition cursor-pointer",
		)
		if p.clickable(ui, idx) {
			stop_generation(st)
		}
		p.icon(ui, IC_SQUARE, "size-3.5 shrink-0 text-destructive")
		p.text(ui, "Stop", "text-xs font-medium text-destructive whitespace-nowrap")
		p.style(ui).shrink = 0
		p.end(ui)
	} else {
		empty := strings.trim_space(composer_text(st)) == ""
		idx := p.row(ui, "shrink-0 items-center gap-1.5 h-8 px-3 rounded-lg transition cursor-pointer")
		p.apply(
			ui,
			empty ? "bg-muted text-muted-foreground" : "bg-primary text-primary-foreground",
			idx,
		)
		if p.clickable(ui, idx) && !empty {
			send(st)
		}
		p.icon(ui, sc.ICON_SEND, "size-3.5 shrink-0")
		p.text(ui, "Send", "text-xs font-medium whitespace-nowrap")
		p.style(ui).shrink = 0
		p.end(ui)
	}
	p.end(ui) // box
}

Seg :: struct {
	start, end: int,
}

// wrap_visual breaks the composer's text into the lines it will be drawn on:
// hard breaks at '\n', soft breaks at the last space that fits.
wrap_visual :: proc(ui: ^p.Ctx, text: string, size, maxw: f32) -> []Seg {
	out := make([dynamic]Seg, context.temp_allocator)
	line_start := 0
	for i := 0; i <= len(text); i += 1 {
		hard := i == len(text) || text[i] == '\n'
		if !hard {
			continue
		}
		// One logical line: [line_start, i)
		s := line_start
		for s <= i {
			// How much of text[s:i] fits?
			if p.text_width(ui.fonts, text[s:i], size, .Sans, .Regular) <= maxw {
				append(&out, Seg{s, i})
				break
			}
			// Binary search the longest prefix that fits, then back up to a
			// space so words stay whole.
			lo, hi := s, i
			for lo < hi {
				mid := (lo + hi + 1) / 2
				for mid > s && mid < i && text[mid] & 0xc0 == 0x80 {
					mid -= 1
				}
				if p.text_width(ui.fonts, text[s:mid], size, .Sans, .Regular) <= maxw {
					if lo == mid {
						break
					}
					lo = mid
				} else {
					hi = mid - 1
				}
			}
			cut := max(lo, s + 1)
			sp := -1
			for j := cut - 1; j > s; j -= 1 {
				if text[j] == ' ' {
					sp = j
					break
				}
			}
			if sp > s {
				cut = sp + 1
			}
			append(&out, Seg{s, cut})
			s = cut
		}
		line_start = i + 1
	}
	if len(out) == 0 {
		append(&out, Seg{0, 0})
	}
	return out[:]
}

caret_line :: proc(vis: []Seg, caret: int) -> int {
	for s, i in vis {
		if caret >= s.start && caret <= s.end {
			return i
		}
	}
	return max(0, len(vis) - 1)
}

// ---------------------------------------------------------------------------
// Footer
// ---------------------------------------------------------------------------

footer :: proc(ui: ^p.Ctx, st: ^St) {
	p.row(ui, "w-full shrink-0 items-center gap-3 px-4 border-t border-border")
	p.style(ui).h = p.px(FOOTER_H)
	defer p.end(ui)

	if st.toast != "" {
		p.icon(ui, sc.ICON_INFO, "size-3 shrink-0 text-muted-foreground")
		p.text(ui, st.toast, "flex-1 text-[11] text-muted-foreground truncate whitespace-nowrap")
		return
	}

	hint(ui, "Enter", "send")
	hint(ui, "Shift-Enter", "newline")
	hint(ui, "Esc", "stop")
	hint(ui, "^M", "model")
	hint(ui, "^T", "thinking")
	hint(ui, "^G", "regenerate")
	hint(ui, "^,", "parameters")
	p.spacer(ui)
	hint(ui, "F1", "all keys")
	if !st.pinned {
		p.text(ui, "scroll-locked", "text-[10.5] text-muted-foreground whitespace-nowrap")
		p.style(ui).shrink = 0
		sc.kbd(ui, "^End")
	}
}

hint :: proc(ui: ^p.Ctx, key, label: string) {
	p.row(ui, "shrink-0 items-center gap-1")
	defer p.end(ui)
	sc.kbd(ui, key)
	p.text(ui, label, "text-[10.5] text-muted-foreground whitespace-nowrap")
	p.style(ui).shrink = 0
}

// ---------------------------------------------------------------------------
// Parameters
// ---------------------------------------------------------------------------

params_panel :: proc(ui: ^p.Ctx, st: ^St, pv: Probe_View) {
	focused := st.zone == .Params && st.overlay == .None

	p.col(ui, "h-full shrink-0 border-l border-border bg-sidebar overflow-hidden")
	p.style(ui).w = p.px(PARAMS_W)
	defer p.end(ui)

	p.row(ui, "w-full shrink-0 items-center gap-2 px-3.5 border-b border-border")
	p.style(ui).h = p.px(TOPBAR_H)
	p.icon(ui, IC_GAUGE, "size-4 shrink-0 text-muted-foreground")
	p.text(ui, "Parameters", "text-sm font-semibold whitespace-nowrap")
	p.spacer(ui)
	if focused {
		sc.badge(ui, "←→ adjusts", .Outline)
	} else {
		sc.kbd(ui, "Tab")
	}
	p.end(ui)

	p.col(ui, "w-full flex-1 min-h-0 px-3.5 py-3 gap-4 overflow-scroll")
	defer p.end(ui)

	param_slider(
		ui,
		st,
		.Temperature,
		"Temperature",
		fmt.tprintf("%.2f", st.pr.temperature),
		st.pr.temperature / 2,
		"0 is deterministic; past 1.2 this model starts to wander.",
		focused,
	)
	param_slider(
		ui,
		st,
		.Top_P,
		"top_p",
		fmt.tprintf("%.2f", st.pr.top_p),
		st.pr.top_p,
		"Nucleus sampling: the share of probability mass kept.",
		focused,
	)
	param_slider(
		ui,
		st,
		.Num_Predict,
		"num_predict",
		fmt.tprintf("%d", st.pr.num_predict),
		f32(st.pr.num_predict) / 2048,
		"The hard ceiling on reply length, in tokens.",
		focused,
	)

	sc.separator(ui, .Horizontal)

	param_switch(
		ui,
		st,
		.Think,
		"Thinking",
		st.pr.think,
		"qwen3 reasons first unless think is false. With it on, the answer arrives after the reasoning — and a short reply limit may be spent entirely inside it.",
		focused,
	)
	param_switch(
		ui,
		st,
		.Reasoning,
		"Show reasoning",
		st.show_think,
		"Render message.thinking in a collapsed block above the answer.",
		focused,
	)

	sc.separator(ui, .Horizontal)

	// System prompt.
	p.col(ui, "w-full gap-1.5")
	p.row(ui, "w-full items-center gap-2")
	p.text(ui, "System prompt", "text-xs font-medium whitespace-nowrap")
	p.spacer(ui)
	sc.kbd(ui, "^S")
	p.end(ui)
	idx := p.col(
		ui,
		"w-full min-h-[64] rounded-lg border border-input bg-background px-2.5 py-2 cursor-pointer hover:bg-muted transition",
	)
	if p.clickable(ui, idx) {
		open_overlay(st, .System)
	}
	if strings.trim_space(st.pr.system) == "" {
		p.text(ui, "none — the model gets no instructions", "text-[11.5] text-muted-foreground")
	} else {
		p.text(ui, st.pr.system, "text-[11.5] leading-[17]")
	}
	p.end(ui)
	p.end(ui)

	sc.separator(ui, .Horizontal)

	// What the machine is doing.
	p.col(ui, "w-full gap-1.5")
	p.text(ui, "Runtime", "text-xs font-medium whitespace-nowrap")
	kv(ui, "endpoint", "127.0.0.1:11434")
	kv(ui, "version", pv.version == "" ? "unknown" : pv.version)
	kv(ui, "models installed", fmt.tprintf("%d", len(pv.models)))
	if len(pv.loaded) > 0 {
		l := pv.loaded[0]
		kv(ui, "loaded", l.name)
		kv(ui, "footprint", human_bytes(l.size, context.temp_allocator))
		kv(ui, "in VRAM", l.vram > 0 ? human_bytes(l.vram, context.temp_allocator) : "0 (CPU)")
		kv(ui, "context", fmt.tprintf("%d", l.ctx))
	} else {
		kv(ui, "loaded", "nothing resident")
	}
	if mi, have := find_model(pv, st.model); have {
		kv(ui, "parameters", mi.params)
		kv(ui, "quantisation", mi.quant)
		kv(ui, "max context", fmt.tprintf("%d", mi.ctx_len))
	}
	p.end(ui)

	p.col(ui, "w-full gap-1 pt-1")
	p.text(
		ui,
		"Nothing in this window leaves the machine.",
		"text-[10.5] text-muted-foreground",
	)
	p.text(
		ui,
		"Every request goes to the loopback address; there is no other endpoint in the binary.",
		"text-[10.5] text-muted-foreground",
	)
	p.end(ui)
}

kv :: proc(ui: ^p.Ctx, k, v: string) {
	p.row(ui, "w-full items-baseline gap-2")
	defer p.end(ui)
	p.text(ui, k, "text-[11] text-muted-foreground whitespace-nowrap")
	p.style(ui).shrink = 0
	p.spacer(ui)
	p.text(ui, v, "text-[11] font-mono whitespace-nowrap truncate")
	p.style(ui).shrink = 0
}

param_slider :: proc(
	ui: ^p.Ctx,
	st: ^St,
	row: Param_Row,
	label, value: string,
	frac: f32,
	note: string,
	zone_focus: bool,
) {
	sel := zone_focus && st.param_sel == row
	box := p.col(ui, "w-full gap-2 rounded-lg px-2 py-2 transition")
	p.apply(ui, sel ? "bg-accent ring-1 ring-ring/40" : "", box)
	if p.clickable(ui, box) {
		st.zone = .Params
		st.param_sel = row
	}
	defer p.end(ui)

	p.row(ui, "w-full items-center gap-2")
	p.text(ui, label, "text-xs font-medium whitespace-nowrap")
	p.style(ui).shrink = 0
	p.spacer(ui)
	p.text(ui, value, "text-xs font-mono whitespace-nowrap")
	p.style(ui).shrink = 0
	p.end(ui)

	vals := [1]f32{clamp(frac, 0, 1)}
	sc.slider(ui, vals[:], false, {focus = sel})

	p.text(ui, note, "text-[10.5] leading-[15] text-muted-foreground")
}

param_switch :: proc(
	ui: ^p.Ctx,
	st: ^St,
	row: Param_Row,
	label: string,
	on: bool,
	note: string,
	zone_focus: bool,
) {
	sel := zone_focus && st.param_sel == row
	box := p.col(ui, "w-full gap-1.5 rounded-lg px-2 py-2 transition")
	p.apply(ui, sel ? "bg-accent ring-1 ring-ring/40" : "", box)
	if p.clickable(ui, box) {
		st.zone = .Params
		st.param_sel = row
		switch row {
		case .Think:
			st.pr.think = !st.pr.think
		case .Reasoning:
			st.show_think = !st.show_think
		case .Temperature, .Top_P, .Num_Predict:
		}
		settings_save(st.model, st.pr, st.show_think)
	}
	defer p.end(ui)

	p.row(ui, "w-full items-center gap-2")
	p.text(ui, label, "text-xs font-medium whitespace-nowrap")
	p.style(ui).shrink = 0
	p.spacer(ui)
	sc.switch_(ui, on, .Default, {focus = sel})
	p.end(ui)
	p.text(ui, note, "text-[10.5] leading-[15] text-muted-foreground")
}

// ---------------------------------------------------------------------------
// Overlays
// ---------------------------------------------------------------------------

overlay :: proc(ui: ^p.Ctx, st: ^St, pv: Probe_View) {
	size := p.size(ui)

	scrim := p.div(ui, "absolute inset-0 bg-background/70 z-40")
	if p.clickable(ui, scrim) {
		st.overlay = .None
	}
	p.end(ui)

	w: f32 = 560
	switch st.overlay {
	case .Models:
		w = 620
	case .Prompts:
		w = 620
	case .Help:
		w = 660
	case .Pull, .Confirm_Delete, .System, .None:
		w = 540
	}

	panel := p.col(
		ui,
		"absolute flex-col rounded-xl border border-border bg-popover text-popover-foreground shadow-2xl z-50 overflow-hidden",
	)
	ps := p.style(ui, panel)
	ps.position = .Absolute
	ps.inset[p.LEFT] = p.px((size.x - w) / 2)
	ps.inset[p.TOP] = p.px(70)
	ps.w = p.px(w)
	ps.max_h = p.px(size.y - 150)
	defer p.end(ui)

	switch st.overlay {
	case .None:
	case .Models:
		models_overlay(ui, st, pv)
	case .Prompts:
		prompts_overlay(ui, st)
	case .Pull:
		pull_overlay(ui, st)
	case .Confirm_Delete:
		confirm_overlay(ui, st)
	case .System:
		system_overlay(ui, st)
	case .Help:
		help_overlay(ui, st)
	}
}

overlay_head :: proc(ui: ^p.Ctx, ic: p.Icon, title, note: string) {
	p.row(ui, "w-full shrink-0 items-center gap-2.5 px-4 py-3 border-b border-border")
	defer p.end(ui)
	p.div(ui, "size-7 shrink-0 flex-row items-center justify-center rounded-lg bg-muted")
	p.icon(ui, ic, "size-3.5 text-muted-foreground")
	p.end(ui)
	p.col(ui, "flex-1 min-w-0")
	p.text(ui, title, "text-sm font-semibold whitespace-nowrap")
	if note != "" {
		p.text(ui, note, "text-[11] text-muted-foreground")
	}
	p.end(ui)
	sc.kbd(ui, "Esc")
}

models_overlay :: proc(ui: ^p.Ctx, st: ^St, pv: Probe_View) {
	overlay_head(
		ui,
		IC_CPU,
		"Installed models",
		"straight from /api/tags — real size, real parameter count",
	)

	p.col(ui, "w-full min-h-0 p-1.5 gap-0.5 overflow-scroll")
	defer p.end(ui)

	if len(pv.models) == 0 {
		p.col(ui, "w-full items-center gap-2 py-8")
		p.icon(ui, sc.ICON_INBOX, "size-5 text-muted-foreground")
		p.text(
			ui,
			pv.err != "" ? "the runtime is not answering" : "no models installed",
			"text-sm font-medium",
		)
		p.text(ui, "Press Enter to pull one.", "text-xs text-muted-foreground")
		p.end(ui)
		return
	}

	for m, i in pv.models {
		p.key(ui, m.name)
		sel := i == st.ov_sel
		idx := p.row(ui, "w-full shrink-0 items-center gap-2.5 px-2.5 py-2 rounded-lg transition cursor-pointer")
		p.apply(ui, sel ? "bg-accent" : "hover:bg-muted", idx)
		if p.clickable(ui, idx) {
			delete(st.model)
			st.model = strings.clone(m.name)
			settings_save(st.model, st.pr, st.show_think)
			st.overlay = .None
		}
		if p.is_hovered(ui, idx) && st.moved {
			st.ov_sel = i
		}
		p.icon(
			ui,
			m.name == st.model ? sc.ICON_CIRCLE_CHECK : IC_CPU,
			m.name == st.model ? "size-4 shrink-0 text-foreground" : "size-4 shrink-0 text-muted-foreground",
		)
		p.col(ui, "flex-1 min-w-0 gap-0.5")
		p.row(ui, "items-center gap-2")
		p.text(ui, m.name, "text-sm font-medium whitespace-nowrap")
		p.style(ui).shrink = 0
		if m.thinking {
			sc.badge(ui, "thinking", .Secondary)
		}
		if m.quant != "" {
			sc.badge(ui, m.quant, .Outline)
		}
		p.end(ui)
		p.textf(
			ui,
			"text-[11] text-muted-foreground whitespace-nowrap",
			"%s parameters · %s on disk · %s · context %d",
			m.params == "" ? "?" : m.params,
			human_bytes(m.size, context.temp_allocator),
			m.family,
			m.ctx_len,
		)
		p.end(ui)
		if resident_of(pv, m.name) > 0 {
			sc.badge(ui, "resident", .Default)
		}
		p.end(ui)
	}

	p.row(ui, "w-full shrink-0 items-center gap-3 px-2 pt-2")
	hint(ui, "Up/Down", "choose")
	hint(ui, "Enter", "use it")
	hint(ui, "^O", "pull another")
	p.end(ui)
}

resident_of :: proc(pv: Probe_View, name: string) -> i64 {
	for l in pv.loaded {
		if l.name == name {
			return l.size
		}
	}
	return 0
}

prompts_overlay :: proc(ui: ^p.Ctx, st: ^St) {
	overlay_head(ui, IC_LIBRARY, "Prompt library", "saved on this machine, in prompts.txt")

	p.col(ui, "w-full min-h-0 p-1.5 gap-0.5 overflow-scroll")
	defer p.end(ui)

	for pr, i in st.prompts {
		p.key(ui, fmt.tprintf("p%d", i))
		sel := i == st.ov_sel
		idx := p.col(ui, "w-full shrink-0 gap-0.5 px-2.5 py-2 rounded-lg transition cursor-pointer")
		p.apply(ui, sel ? "bg-accent" : "hover:bg-muted", idx)
		if p.clickable(ui, idx) {
			clear(&st.input)
			append(&st.input, ..transmute([]u8)pr.body)
			st.caret = len(st.input)
			st.overlay = .None
			st.zone = .Composer
		}
		if p.is_hovered(ui, idx) && st.moved {
			st.ov_sel = i
		}
		p.row(ui, "w-full items-center gap-2")
		p.icon(ui, IC_BOOKMARK, "size-3 shrink-0 text-muted-foreground")
		p.text(ui, pr.name, "text-sm font-medium whitespace-nowrap")
		p.style(ui).shrink = 0
		p.end(ui)
		one := pr.body
		if nl := strings.index_byte(one, '\n'); nl > 0 {
			one = one[:nl]
		}
		p.text(ui, one, "text-[11] text-muted-foreground whitespace-nowrap truncate w-full")
		p.end(ui)
	}
	if len(st.prompts) == 0 {
		p.text(ui, "The library is empty.", "text-xs text-muted-foreground p-3")
	}

	p.row(ui, "w-full shrink-0 items-center gap-3 px-2 pt-2")
	hint(ui, "Enter", "load into the composer")
	hint(ui, "^A", "save the composer as a prompt")
	hint(ui, "^Del", "remove")
	p.end(ui)
}

pull_overlay :: proc(ui: ^p.Ctx, st: ^St) {
	overlay_head(ui, sc.ICON_DOWNLOAD, "Pull a model", "streams progress from /api/pull")

	p.col(ui, "w-full p-4 gap-3")
	defer p.end(ui)

	p.text(ui, "Model name", "text-xs font-medium")
	p.row(ui, "w-full h-9 items-center gap-2 px-2.5 rounded-lg border border-ring ring-3 ring-ring/40 bg-background")
	name := string(st.pull_name[:])
	if name == "" {
		p.text(ui, "qwen3:1.7b", "text-sm text-muted-foreground whitespace-nowrap")
	} else {
		p.text(ui, name, "text-sm whitespace-nowrap")
	}
	p.style(ui).shrink = 0
	if !st.pulling {
		cx := p.text_width(ui.fonts, name, 14, .Sans, .Regular)
		car := p.div(ui, "absolute w-[1.5] rounded-full bg-foreground")
		cs := p.style(ui, car)
		cs.inset[p.LEFT] = p.px(10 + cx)
		cs.inset[p.TOP] = p.px(10)
		cs.h = p.px(16)
		p.end(ui)
	}
	p.spacer(ui)
	if st.pulling {
		p.icon(ui, sc.ICON_LOADER_CIRCLE, "size-4 shrink-0 text-muted-foreground", f32(mono()))
	} else {
		sc.kbd(ui, "Enter")
	}
	p.end(ui)

	s := st.pull_live
	if st.pulling || s.status != "" {
		p.col(ui, "w-full gap-1.5 rounded-lg border border-border bg-muted/40 p-3")
		p.row(ui, "w-full items-center gap-2")
		p.text(ui, s.status == "" ? "starting…" : s.status, "text-xs whitespace-nowrap truncate")
		p.spacer(ui)
		if s.total > 0 {
			p.textf(
				ui,
				"text-xs font-mono whitespace-nowrap",
				"%s / %s",
				human_bytes(s.completed, context.temp_allocator),
				human_bytes(s.total, context.temp_allocator),
			)
			p.style(ui).shrink = 0
		}
		p.end(ui)
		if s.total > 0 {
			sc.progress_track(ui, clamp(f32(f64(s.completed) / f64(s.total)) * 100, 0, 100))
		}
		if s.err != "" {
			p.text(ui, s.err, "text-[11] text-destructive")
		}
		p.end(ui)
	}

	p.text(
		ui,
		"The download comes from the ollama registry through the local daemon; this window never opens a socket of its own except to 127.0.0.1.",
		"text-[10.5] text-muted-foreground",
	)
}

confirm_overlay :: proc(ui: ^p.Ctx, st: ^St) {
	c := cur_conv(st)
	overlay_head(ui, sc.ICON_TRASH, "Delete this conversation?", "the file is removed from disk")
	p.col(ui, "w-full p-4 gap-3")
	defer p.end(ui)
	p.text(
		ui,
		c == nil ? "" : c.title,
		"text-sm font-medium",
	)
	if c != nil {
		p.textf(
			ui,
			"text-xs text-muted-foreground",
			"%d messages · %s",
			len(c.msgs),
			conv_path(c.id, context.temp_allocator),
		)
	}
	p.row(ui, "w-full items-center gap-3 pt-1")
	hint(ui, "Enter", "delete")
	hint(ui, "Esc", "keep it")
	p.end(ui)
}

system_overlay :: proc(ui: ^p.Ctx, st: ^St) {
	overlay_head(
		ui,
		sc.ICON_FILE_TEXT,
		"System prompt",
		"sent as the first message of every request",
	)
	p.col(ui, "w-full p-4 gap-3")
	defer p.end(ui)

	p.col(
		ui,
		"w-full min-h-[120] rounded-lg border border-ring ring-3 ring-ring/40 bg-background px-3 py-2.5",
	)
	text := string(st.sys_buf[:])
	if text == "" {
		p.text(
			ui,
			"e.g. You are terse. Answer in at most three sentences and never apologise.",
			"text-sm text-muted-foreground",
		)
	} else {
		p.text(ui, text, "text-sm leading-[20]")
	}
	p.end(ui)

	p.row(ui, "w-full items-center gap-3")
	hint(ui, "Enter", "save")
	hint(ui, "Shift-Enter", "newline")
	hint(ui, "^U", "clear")
	p.spacer(ui)
	p.textf(ui, "text-[10.5] font-mono text-muted-foreground whitespace-nowrap", "%d chars", len(text))
	p.style(ui).shrink = 0
	p.end(ui)
}

help_overlay :: proc(ui: ^p.Ctx, st: ^St) {
	overlay_head(ui, sc.ICON_TERMINAL, "Keys", "the whole application is keyboard-driven")
	p.col(ui, "w-full min-h-0 p-4 gap-1.5 overflow-scroll")
	defer p.end(ui)

	rows := [?][2]string {
		{"Enter", "send the composer"},
		{"Shift+Enter", "a newline in the composer"},
		{"Esc", "stop the generation, or close a panel"},
		{"Tab", "move between the composer, the chat list and the parameters"},
		{"Ctrl+N  /  F2", "new conversation"},
		{"Ctrl+J / Ctrl+K", "next / previous conversation"},
		{"Ctrl+D", "delete this conversation"},
		{"Ctrl+M", "model picker"},
		{"Ctrl+O", "pull a model"},
		{"Ctrl+T  /  F3", "thinking on or off"},
		{"Ctrl+R  /  F4", "show or hide reasoning"},
		{"Ctrl+B", "collapse the newest reasoning block"},
		{"Ctrl+G", "regenerate the last reply"},
		{"Ctrl+E", "edit the last question and resend"},
		{"Ctrl+Y", "copy the last reply"},
		{"Ctrl+P", "prompt library"},
		{"Ctrl+S", "system prompt"},
		{"Ctrl+,  /  F5", "parameter panel"},
		{"PageUp / PageDown", "scroll the transcript"},
		{"Ctrl+End", "follow the bottom again"},
		{"Ctrl+Q", "quit"},
	}
	for r in rows {
		p.row(ui, "w-full shrink-0 items-center gap-3")
		p.div(ui, "shrink-0 flex-row justify-end")
		p.style(ui).w = p.px(178)
		sc.kbd(ui, r[0])
		p.end(ui)
		p.text(ui, r[1], "flex-1 text-xs text-muted-foreground")
		p.end(ui)
	}
	_ = st
}
