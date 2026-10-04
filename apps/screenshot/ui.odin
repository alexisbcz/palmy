package main

// The interface.

import "core:fmt"
import "core:math"
import "core:os"
import kit "kit:."
import p "palmy:."
import sc "shadcn:."

WIN_W :: 1200
WIN_H :: 820

LABEL ::
	"shrink-0 text-[11] font-semibold uppercase tracking-wider text-muted-foreground whitespace-nowrap"

start_window :: proc() -> (^p.App, string) {
	// A palmy window only draws when something changed, which is right for a
	// screenshot tool and wrong for a screen recorder: a compositor presents
	// no frames while the UI is idle, so the capture's timestamps come out
	// compressed. PALMY_CONTINUOUS=1 asks for a frame every vsync instead.
	continuous := os.get_env("PALMY_CONTINUOUS", context.temp_allocator) != ""
	if continuous {
		fmt.eprintfln("[screenshot] continuous redraw on (recording mode)")
	}
	return kit.start(
		{
			title = "Screenshot",
			width = WIN_W,
			height = WIN_H,
			min_width = 900,
			min_height = 620,
			root_class = "w-full h-full bg-background text-foreground",
			// Otherwise deliberately not `always`: this window has nothing to
			// animate while it is idle, so it asks for frames only during a
			// countdown or while grim or slurp is running, and costs nothing
			// the rest of the time.
			always = continuous,
		},
	)
}

build :: proc(ui: ^p.Ctx, m: ^Model) {
	p.col(ui, "w-full h-full bg-background text-foreground")
	defer p.end(ui)

	header(ui, m)

	p.row(ui, "w-full flex-1 min-h-0")
	{
		sidebar(ui, m)
		p.div(ui, "w-px h-full shrink-0 bg-border")
		p.end(ui)
		preview(ui, m)
	}
	p.end(ui)

	footer(ui, m)

	if m.log_open {
		log_overlay(ui, m)
	}
	if m.help_open {
		help_overlay(ui, m)
	}
}

// ---------------------------------------------------------------------------
// Header: what is about to be captured
// ---------------------------------------------------------------------------

header :: proc(ui: ^p.Ctx, m: ^Model) {
	p.row(ui, "w-full shrink-0 items-center gap-4 px-5 bg-card border-b border-border")
	p.style(ui).h = p.px(HEADER_H)
	defer p.end(ui)

	p.div(ui, "size-11 shrink-0 flex-row items-center justify-center rounded-[14] bg-blue-600 text-white")
	p.icon(ui, IC_CAMERA, "size-5 shrink-0")
	p.end(ui)

	p.col(ui, "shrink-0 gap-1 w-[196]")
	{
		p.text(ui, "Screenshot", "text-[17] font-semibold tracking-tight whitespace-nowrap")
		p.text(ui, capture_summary(m), "text-xs text-muted-foreground truncate")
	}
	p.end(ui)

	p.div(ui, "w-px h-9 shrink-0 bg-border")
	p.end(ui)

	// The mode, as a segmented control. Keys 1 2 3 pick one.
	p.row(ui, "shrink-0 items-center gap-1 p-1 rounded-lg bg-muted")
	{
		seg(ui, m, .Screen, "Screen", IC_MAXIMIZE, "1", true)
		seg(ui, m, .Output, "Output", IC_MONITOR, "2", len(m.outputs) > 0)
		seg(ui, m, .Region, "Region", IC_SQUARE_DASHED, "3", m.have_slurp)
	}
	p.end(ui)

	// Which output, when that is the mode.
	if len(m.outputs) > 0 {
		o := m.outputs[m.out_at % len(m.outputs)]
		if chip(ui, IC_MONITOR, fmt.tprintf("%s · %dx%d", o.name, o.w, o.h), "O", m.mode == .Output) {
			m.out_at = (m.out_at + 1) % len(m.outputs)
			m.mode = .Output
		}
	}

	if chip(
		ui,
		IC_TIMER,
		delay_secs(m) == 0 ? "No delay" : fmt.tprintf("%d s delay", delay_secs(m)),
		"T",
		delay_secs(m) > 0,
	) {
		m.delay_at = (m.delay_at + 1) % len(Delay_Choices)
	}

	p.div(ui, "flex-1 min-w-0")
	p.end(ui)

	capture_button(ui, m)
}

capture_summary :: proc(m: ^Model) -> string {
	switch m.mode {
	case .Screen:
		if len(m.outputs) > 1 {
			return fmt.tprintf("Every output, composited (%d)", len(m.outputs))
		}
		return "The whole screen"
	case .Output:
		if len(m.outputs) == 0 {
			return "No output reported"
		}
		o := m.outputs[m.out_at % len(m.outputs)]
		return o.desc == "" ? o.name : o.desc
	case .Region:
		if !m.have_slurp {
			return "slurp is not installed"
		}
		if m.have_region {
			return fmt.tprintf("Drag a rectangle · A repeats %s", geom_arg(m.region))
		}
		return "A rectangle you drag with slurp"
	}
	return ""
}

seg :: proc(ui: ^p.Ctx, m: ^Model, mode: Mode, label: string, ic: p.Icon, key: string, enabled: bool) {
	on := m.mode == mode
	idx := p.row(ui, "shrink-0 items-center gap-1.5 h-8 px-2.5 rounded-md transition duration-120")
	p.apply(
		ui,
		on ? "bg-background shadow-sm text-foreground" : "text-muted-foreground hover:bg-background/60",
		idx,
	)
	if !enabled {
		p.apply(ui, "opacity-40", idx)
	}
	defer p.end(ui)
	if enabled && p.clickable(ui, idx) {
		m.mode = mode
	}
	p.icon(ui, ic, "size-3.5 shrink-0")
	p.text(ui, label, "text-xs font-medium whitespace-nowrap")
	p.style(ui).shrink = 0
	sc.kbd(ui, key)
}

chip :: proc(ui: ^p.Ctx, ic: p.Icon, label, key: string, on: bool) -> bool {
	idx := p.row(
		ui,
		p.concat(
			ui,
			"shrink-0 items-center gap-1.5 h-8 px-2.5 rounded-lg border cursor-pointer ",
			on \
			? "border-blue-600/30 bg-blue-600/10 text-blue-700" \
			: "border-border text-muted-foreground hover:bg-accent",
		),
	)
	defer p.end(ui)
	p.icon(ui, ic, "size-3.5 shrink-0")
	p.text(ui, label, "text-xs font-medium whitespace-nowrap")
	p.style(ui).shrink = 0
	sc.kbd(ui, key)
	return p.clickable(ui, idx)
}

capture_button :: proc(ui: ^p.Ctx, m: ^Model) {
	busy := m.phase != .Idle
	at := p.node_count(ui)
	hovered := p.hovered(ui, p.node_id(ui, at))
	idx := sc.button_open(
		ui,
		.Default,
		.LG,
		sc.State{hover = hovered && !busy, focus = p.focused(ui), disabled = busy},
	)
	p.apply(ui, "shrink-0 w-[168] justify-center gap-2", idx)
	defer sc.button_end(ui)
	p.focusable(ui, idx)

	if m.phase == .Counting {
		p.icon(ui, IC_TIMER, "size-4 shrink-0")
		p.textf(ui, "whitespace-nowrap", "%d…", int(math.ceil(m.count_until - g_now)))
		p.style(ui).shrink = 0
		return
	}
	if busy {
		p.icon(ui, IC_ELLIPSIS, "size-4 shrink-0")
		p.text(ui, "Working", "whitespace-nowrap")
		p.style(ui).shrink = 0
		return
	}
	p.icon(ui, IC_CAMERA, "size-4 shrink-0")
	p.text(ui, "Capture", "whitespace-nowrap")
	p.style(ui).shrink = 0
	sc.kbd(ui, "Enter")

	if p.activated(ui, idx) {
		start_capture(m)
	}
}

// ---------------------------------------------------------------------------
// Sidebar: this session's captures, and where they go
// ---------------------------------------------------------------------------

sidebar :: proc(ui: ^p.Ctx, m: ^Model) {
	p.col(ui, "shrink-0 h-full min-h-0 bg-sidebar p-4 gap-2 overflow-hidden")
	p.style(ui).w = p.px(SIDE_W)
	defer p.end(ui)

	p.row(ui, "w-full h-7 shrink-0 items-center gap-2 px-1")
	p.icon(ui, IC_IMAGE, "size-3.5 shrink-0 text-muted-foreground")
	p.text(ui, "Captures", LABEL)
	p.textf(ui, "text-[11] font-medium text-muted-foreground/70", "%d", m.n_shots)
	p.end(ui)

	if m.n_shots == 0 {
		p.col(ui, "w-full shrink-0 rounded-xl border border-dashed border-border p-5 gap-1.5 items-center")
		p.icon(ui, IC_CAMERA, "size-5 shrink-0 text-muted-foreground")
		p.text(ui, "Nothing captured yet", "text-xs font-medium text-muted-foreground")
		p.text(ui, "Press Enter to take one", "text-[11] text-muted-foreground/70")
		p.end(ui)
	}

	for i in 0 ..< m.n_shots {
		shot_row(ui, m, i)
	}

	p.div(ui, "flex-1 min-h-0")
	p.end(ui)

	// Where a save will land, named before it happens.
	p.col(ui, "w-full shrink-0 rounded-xl border border-border bg-card p-3.5 gap-2")
	defer p.end(ui)
	p.row(ui, "w-full items-center gap-2")
	p.icon(ui, IC_FOLDER_OPEN, "size-3.5 shrink-0 text-muted-foreground")
	p.text(ui, "Destination", LABEL)
	p.end(ui)
	p.text(ui, pictures_dir(), "w-full text-[11] font-mono truncate")
	p.text(
		ui,
		"screenshot-YYYY-MM-DD_HH-MM-SS.png",
		"w-full text-[11] font-mono text-muted-foreground truncate",
	)

	p.row(ui, "w-full items-center gap-2 pt-1")
	tool_dot(ui, "grim", m.have_grim)
	tool_dot(ui, "slurp", m.have_slurp)
	tool_dot(ui, "wl-copy", m.have_wlcopy)
	p.end(ui)
}

tool_dot :: proc(ui: ^p.Ctx, name: string, ok: bool) {
	p.row(ui, "shrink-0 items-center gap-1.5")
	defer p.end(ui)
	p.div(ui, p.concat(ui, "size-1.5 shrink-0 rounded-full ", ok ? "bg-emerald-500" : "bg-destructive"))
	p.end(ui)
	p.text(ui, name, "text-[10] font-mono text-muted-foreground whitespace-nowrap")
	p.style(ui).shrink = 0
}

shot_row :: proc(ui: ^p.Ctx, m: ^Model, i: int) {
	s := m.shots[i]
	sel := i == m.sel
	p.key(ui, s.path)
	idx := p.row(ui, "w-full h-[56] shrink-0 items-center gap-2.5 px-2.5 rounded-lg transition duration-120")
	p.apply(ui, sel ? "bg-blue-600 text-white" : "hover:bg-accent", idx)
	defer p.end(ui)
	if p.clickable(ui, idx) {
		m.sel = i
		m.zoom = 1
	}

	dim := sel ? "text-white/75" : "text-muted-foreground"
	tile := sel ? "bg-white/20 text-white" : "bg-muted text-muted-foreground"
	p.div(ui, p.concat(ui, "size-9 shrink-0 flex-row items-center justify-center rounded-[10] ", tile))
	p.icon(ui, mode_icon(s.mode), "size-4 shrink-0")
	p.end(ui)

	p.col(ui, "flex-1 min-w-0 gap-0.5")
	{
		p.row(ui, "items-center gap-1.5 min-w-0")
		p.textf(ui, "text-xs font-medium whitespace-nowrap", "%d x %d", s.w, s.h)
		p.style(ui).shrink = 0
		if s.saved != "" {
			sc.badge_icon(ui, "Saved", IC_CHECK, sel ? .Outline : .Secondary)
		}
		if s.copied {
			sc.badge_icon(ui, "Copied", IC_COPY, .Outline)
		}
		p.div(ui, "flex-1")
		p.end(ui)
		p.end(ui)
		p.text(
			ui,
			fmt.tprintf("%s · %s · %s", s.when_, human_bytes(s.bytes), shot_where(s)),
			p.concat(ui, "text-[11] truncate ", dim),
		)
	}
	p.end(ui)
}

shot_where :: proc(s: Shot) -> string {
	if s.mode == .Output && s.out != "" {
		return s.out
	}
	return mode_label(s.mode)
}

mode_icon :: proc(m: Mode) -> p.Icon {
	switch m {
	case .Screen:
		return IC_MAXIMIZE
	case .Output:
		return IC_MONITOR
	case .Region:
		return IC_SQUARE_DASHED
	}
	return IC_IMAGE
}

// ---------------------------------------------------------------------------
// Preview: the real, decoded capture
// ---------------------------------------------------------------------------

preview :: proc(ui: ^p.Ctx, m: ^Model) {
	p.col(ui, "flex-1 min-w-0 h-full min-h-0")
	defer p.end(ui)

	p.col(ui, "w-full flex-1 min-h-0 p-5")
	{
		p.col(ui, "w-full h-full rounded-xl border border-border bg-muted/50 overflow-hidden items-center justify-center")
		defer p.end(ui)

		switch {
		case m.phase == .Counting:
			countdown(ui, m)
		case m.phase == .Working:
			working(ui, m)
		case m.n_shots == 0:
			preview_empty(ui, m)
		case:
			ensure_decoded(m)
			if m.img_ok {
				// `.None` with a zoom shows real pixels past 2x, which is the
				// point of zooming into a screenshot.
				if m.zoom > 1.001 {
					p.image(ui, m.img, "w-full h-full", .None, m.zoom)
				} else {
					p.image(ui, m.img, "w-full h-full", .Contain)
				}
			} else {
				p.text(ui, "Could not decode that file", "text-sm text-muted-foreground")
			}
		}
	}
	p.end(ui)

	preview_bar(ui, m)
}

countdown :: proc(ui: ^p.Ctx, m: ^Model) {
	left := max(0, m.count_until - g_now)
	p.col(ui, "items-center gap-3")
	defer p.end(ui)
	p.textf(ui, "text-8xl font-bold tracking-tight text-blue-600 tabular-nums", "%d", int(math.ceil(left)))
	p.text(ui, "Switch to whatever you want in the shot", "text-sm text-muted-foreground")
	p.row(ui, "items-center gap-1.5")
	sc.kbd(ui, "Esc")
	p.text(ui, "cancels", "text-[11] text-muted-foreground")
	p.end(ui)
}

working :: proc(ui: ^p.Ctx, m: ^Model) {
	p.col(ui, "items-center gap-3 max-w-[420]")
	defer p.end(ui)
	p.div(ui, "size-12 flex-row items-center justify-center rounded-2xl bg-blue-600/10 text-blue-600")
	p.icon(ui, m.mode == .Region ? IC_CROP : IC_CAMERA, "size-6 shrink-0")
	p.end(ui)
	p.text(ui, m.status, "text-sm font-medium text-center")
	if m.mode == .Region {
		p.text(
			ui,
			"slurp owns the screen until a rectangle is dragged or Escape is pressed. This window keeps running; it is not waiting on the frame.",
			"text-[11] text-muted-foreground text-center leading-relaxed",
		)
	}
}

// preview_empty is hand-rolled rather than shadcn's `empty`: that component
// constrains its text with `max-w-sm`, and palmy does not treat `max-w-*` as a
// wrapping constraint, so a description longer than a few words runs off the
// edge. An explicit `w-*` does wrap, so this uses one.
preview_empty :: proc(ui: ^p.Ctx, m: ^Model) {
	p.col(ui, "w-[480] shrink-0 items-center gap-2 p-6")
	defer p.end(ui)

	p.div(ui, "mb-2 flex-row size-8 shrink-0 items-center justify-center rounded-lg bg-muted text-foreground")
	p.icon(ui, IC_IMAGE, "size-4 shrink-0")
	p.end(ui)

	p.text(ui, "No capture yet", "text-sm font-medium tracking-tight")
	p.text(
		ui,
		m.have_grim \
		? "Press Enter and the shot appears here, decoded by palmy and shown at full size. This window is part of the screen, so use the delay if you want it out of the way." \
		: "grim is not installed, so there is nothing to capture with.",
		"w-full text-sm leading-relaxed text-muted-foreground text-center",
	)
}

preview_bar :: proc(ui: ^p.Ctx, m: ^Model) {
	p.row(ui, "w-full h-[56] shrink-0 items-center gap-3 px-5 border-t border-border bg-card")
	defer p.end(ui)

	if m.sel < 0 || m.sel >= m.n_shots {
		p.text(ui, "Nothing selected", "text-xs text-muted-foreground")
		return
	}
	s := m.shots[m.sel]

	p.icon(ui, IC_FILE_IMAGE, "size-4 shrink-0 text-muted-foreground")
	p.col(ui, "flex-1 min-w-0 gap-0.5")
	p.text(
		ui,
		s.saved != "" ? s.saved : s.path,
		"w-full text-xs font-mono truncate",
	)
	p.textf(
		ui,
		"w-full text-[11] text-muted-foreground truncate",
		"%d x %d · %s · %s%s",
		s.w,
		s.h,
		human_bytes(s.bytes),
		mode_label(s.mode),
		s.saved == "" ? " · not saved yet" : "",
	)
	p.end(ui)

	if m.zoom > 1.001 {
		p.row(ui, "shrink-0 items-center gap-1.5")
		p.icon(ui, IC_ZOOM_IN, "size-3.5 shrink-0 text-muted-foreground")
		p.textf(ui, "text-xs font-medium tabular-nums whitespace-nowrap", "%.1fx", m.zoom)
		p.end(ui)
	}

	if act(ui, "Save", IC_SAVE, "S", s.saved == "", .Default) {
		save_selected(m)
	}
	if act(ui, "Copy", IC_CLIPBOARD, "C", m.have_wlcopy, .Outline) {
		copy_selected(m)
	}
	if act(ui, "Discard", IC_TRASH, "X", true, .Ghost) {
		discard_selected(m)
	}
}

// act draws one of the preview bar's buttons. The key is printed on the face
// of each one, because this compositor cannot synthesise a pointer click and
// the keyboard is the only way a demo can reach them.
act :: proc(
	ui: ^p.Ctx,
	label: string,
	ic: p.Icon,
	key: string,
	enabled: bool,
	v: sc.Variant,
) -> bool {
	at := p.node_count(ui)
	hovered := p.hovered(ui, p.node_id(ui, at))
	idx := sc.button_open(ui, v, .SM, sc.State{hover = hovered && enabled, disabled = !enabled})
	p.apply(ui, "shrink-0 gap-1.5", idx)
	defer sc.button_end(ui)
	// Deliberately not focusable: Enter is already "capture", and a Save
	// button in the Tab order would fire both on the same key.
	p.icon(ui, ic, "size-3.5 shrink-0")
	p.text(ui, label, "whitespace-nowrap")
	p.style(ui).shrink = 0
	sc.kbd(ui, key)
	return enabled && p.clickable(ui, idx)
}

// ---------------------------------------------------------------------------
// Footer
// ---------------------------------------------------------------------------

footer :: proc(ui: ^p.Ctx, m: ^Model) {
	p.row(ui, "w-full shrink-0 items-center gap-3 px-4 bg-card border-t border-border")
	p.style(ui).h = p.px(FOOTER_H)
	defer p.end(ui)

	hint(ui, "Enter", "", "capture")
	hint(ui, "1", "3", "mode")
	hint(ui, "A", "", "same region")
	hint(ui, "T", "", "delay")
	hint(ui, "S", "", "save")
	hint(ui, "C", "", "copy")
	hint(ui, "+", "-", "zoom")
	hint(ui, "G", "", "log")

	p.div(ui, "flex-1 min-w-0")
	p.end(ui)

	if m.toast_len > 0 && g_now < m.toast_until {
		p.row(ui, "shrink-0 items-center gap-1.5 max-w-[560]")
		defer p.end(ui)
		p.icon(
			ui,
			m.toast_bad ? IC_TRIANGLE_ALERT : IC_CIRCLE_CHECK,
			p.concat(ui, "size-3.5 shrink-0 ", m.toast_bad ? "text-destructive" : "text-emerald-600"),
		)
		p.text(
			ui,
			string(m.toast[:m.toast_len]),
			p.concat(ui, "text-[11] truncate ", m.toast_bad ? "text-destructive" : "text-muted-foreground"),
		)
		return
	}

	entries := log_recent(1)
	if len(entries) > 0 {
		p.text(
			ui,
			entries[0].cmd,
			"shrink-0 text-[11] font-mono text-muted-foreground/80 whitespace-nowrap",
		)
	}
}

hint :: proc(ui: ^p.Ctx, a, b, label: string) {
	p.row(ui, "shrink-0 items-center gap-1")
	defer p.end(ui)
	sc.kbd(ui, a)
	if b != "" {
		sc.kbd(ui, b)
	}
	p.text(ui, label, "text-[11] text-muted-foreground whitespace-nowrap ml-0.5")
	p.style(ui).shrink = 0
}

// ---------------------------------------------------------------------------
// Overlays
// ---------------------------------------------------------------------------

scrim :: proc(ui: ^p.Ctx, class: string, z: int) -> int {
	idx := p.div(ui, class)
	st := p.style(ui, idx)
	st.position = .Absolute
	st.inset = {p.px(0), p.px(0), p.px(0), p.px(0)}
	st.z = z
	p.end(ui)
	return idx
}

panel :: proc(ui: ^p.Ctx, w: f32, top: f32, z: int) -> int {
	vp := p.size(ui)
	idx := p.col(ui, "rounded-xl bg-popover ring-1 ring-foreground/10 shadow-2xl overflow-hidden")
	st := p.style(ui, idx)
	st.position = .Absolute
	st.inset[p.LEFT] = p.px(max(8, (vp.x - w) / 2))
	st.inset[p.TOP] = p.px(max(8, vp.y * top))
	st.w = p.px(w)
	st.z = z
	return idx
}

log_overlay :: proc(ui: ^p.Ctx, m: ^Model) {
	s := scrim(ui, "bg-foreground/25", 60)
	if p.clickable(ui, s) {
		m.log_open = false
	}
	panel(ui, 680, 0.2, 70)
	defer p.end(ui)

	p.row(ui, "w-full shrink-0 items-center gap-2 px-4 h-12 border-b border-border")
	p.icon(ui, IC_ELLIPSIS, "size-4 shrink-0 text-muted-foreground")
	p.text(ui, "Commands executed", "text-sm font-semibold shrink-0")
	p.textf(ui, "flex-1 text-xs text-muted-foreground", "%d since launch", g_log_count)
	sc.kbd(ui, "Esc")
	p.end(ui)

	p.col(ui, "w-full shrink-0 p-2")
	defer p.end(ui)
	entries := log_recent(12)
	if len(entries) == 0 {
		p.row(ui, "w-full h-9 items-center px-2")
		p.text(ui, "Nothing yet.", "text-xs text-muted-foreground")
		p.end(ui)
		return
	}
	for e, i in entries {
		p.key(ui, fmt.tprintf("%d-%s", i, e.cmd))
		p.row(ui, "w-full h-7 shrink-0 items-center gap-2 px-2 rounded-md")
		p.icon(
			ui,
			e.ok ? IC_CHECK : IC_X,
			p.concat(ui, "size-3 shrink-0 ", e.ok ? "text-emerald-600" : "text-destructive"),
		)
		p.text(ui, e.cmd, "flex-1 min-w-0 text-xs font-mono truncate")
		p.end(ui)
	}
}

help_overlay :: proc(ui: ^p.Ctx, m: ^Model) {
	s := scrim(ui, "bg-foreground/25", 80)
	if p.clickable(ui, s) {
		m.help_open = false
	}
	panel(ui, 560, 0.16, 90)
	defer p.end(ui)

	p.row(ui, "w-full shrink-0 items-center gap-2 px-4 h-12 border-b border-border")
	p.icon(ui, IC_CAMERA, "size-4 shrink-0 text-muted-foreground")
	p.text(ui, "Keyboard", "text-sm font-semibold shrink-0")
	p.div(ui, "flex-1")
	p.end(ui)
	sc.kbd(ui, "Esc")
	p.end(ui)

	p.col(ui, "w-full p-4 gap-1.5")
	defer p.end(ui)
	rows := [?][2]string {
		{"Enter / Space", "Capture"},
		{"1 2 3", "Whole screen, one output, a region"},
		{"O", "Next output"},
		{"A", "Capture the last region again, with no drag"},
		{"T", "Cycle the delay: none, 3, 5, 10 seconds"},
		{"Esc", "Cancel a running countdown"},
		{"Up Down", "Move through this session's captures"},
		{"S", "Save the selection into ~/Pictures"},
		{"C", "Copy it to the clipboard as image/png"},
		{"X", "Drop it from the list (a saved copy is untouched)"},
		{"+ - F", "Zoom in, out, fit"},
		{"G", "Every command this tool has run"},
		{"Ctrl Q", "Quit"},
	}
	for r in rows {
		p.row(ui, "w-full shrink-0 items-center gap-3 h-7")
		p.text(ui, r[0], "w-[150] shrink-0 text-[11] font-mono text-foreground")
		p.text(ui, r[1], "flex-1 min-w-0 text-xs text-muted-foreground truncate")
		p.end(ui)
	}

	sc.separator(ui)
	p.text(
		ui,
		"This window is part of the screen, so it appears in its own full-screen captures. That is what the delay is for.",
		"text-[11] text-muted-foreground leading-relaxed",
	)
}
