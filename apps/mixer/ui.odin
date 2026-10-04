package main

// The interface, rebuilt every frame from whatever pactl last said.

import "core:fmt"
import kit "kit:."
import p "palmy:."
import sc "shadcn:."

WIN_W :: 1180
WIN_H :: 780

LABEL ::
	"shrink-0 text-[11] font-semibold uppercase tracking-wider text-muted-foreground whitespace-nowrap"

start_window :: proc() -> (^p.App, string) {
	return kit.start(
		{
			title = "Audio Mixer",
			width = WIN_W,
			height = WIN_H,
			min_width = 940,
			min_height = 620,
			root_class = "w-full h-full bg-background text-foreground",
			// The device list is re-read on a timer and the input meter moves
			// at frame rate, so this window asks for a frame every vsync.
			always = true,
		},
	)
}

build :: proc(ui: ^p.Ctx, m: ^Model) {
	p.col(ui, "w-full h-full bg-background text-foreground")
	defer p.end(ui)

	header(ui, m)

	p.row(ui, "w-full flex-1 min-h-0")
	{
		devices_pane(ui, m)
		p.div(ui, "w-px h-full shrink-0 bg-border")
		p.end(ui)
		right_pane(ui, m)
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
// Header: the default output, in full
// ---------------------------------------------------------------------------

header :: proc(ui: ^p.Ctx, m: ^Model) {
	d, has := default_out(m)

	p.row(ui, "w-full shrink-0 items-center gap-4 px-5 bg-card border-b border-border")
	p.style(ui).h = p.px(HEADER_H)
	defer p.end(ui)

	tone := has && !d.mute ? "bg-blue-600 text-white" : "bg-muted text-muted-foreground"
	p.div(ui, p.concat(ui, "size-12 shrink-0 flex-row items-center justify-center rounded-[16] ", tone))
	p.icon(ui, has ? vol_icon(d.vol, d.mute) : IC_VOLUME_X, "size-6 shrink-0")
	p.end(ui)

	p.col(ui, "flex-1 min-w-0 gap-1.5")
	{
		p.row(ui, "items-center gap-2 min-w-0")
		p.text(
			ui,
			has ? d.desc : "No output device",
			"text-[17] font-semibold tracking-tight truncate max-w-[380]",
		)
		if has {
			if d.port != "" {
				sc.badge(ui, d.port, .Secondary)
			}
			if b := bus_label(d); b != "" {
				sc.badge(ui, b, .Outline)
			}
			if d.mute {
				sc.badge_icon(ui, "Muted", IC_VOLUME_X, .Destructive)
			}
			if st := state_label(d.state); st != "" {
				p.text(ui, st, "text-[11] text-muted-foreground whitespace-nowrap")
				p.style(ui).shrink = 0
			}
		}
		p.div(ui, "flex-1")
		p.end(ui)
		p.end(ui)

		// The master bar: the same track the rows use, at full width.
		p.row(ui, "w-full items-center gap-3")
		track(ui, has ? d.vol : 0, has && d.mute, "h-2")
		p.text(
			ui,
			has ? pct_label(d.vol) : "—",
			p.concat(
				ui,
				"w-[58] shrink-0 text-right text-[19] font-semibold tracking-tight tabular-nums ",
				has && d.mute ? "text-muted-foreground line-through" : "text-foreground",
			),
		)
		p.end(ui)
	}
	p.end(ui)

	p.div(ui, "w-px h-12 shrink-0 bg-border")
	p.end(ui)

	// The default input, smaller, beside it.
	s, has_in := default_in(m)
	p.col(ui, "w-[260] shrink-0 gap-1.5")
	{
		p.row(ui, "items-center gap-2")
		p.icon(ui, has_in && !s.mute ? IC_MIC : IC_MIC_OFF, "size-3.5 shrink-0 text-muted-foreground")
		p.text(ui, "DEFAULT INPUT", LABEL)
		p.end(ui)
		p.text(ui, has_in ? s.desc : "No input device", "text-sm font-medium truncate")
		p.row(ui, "w-full items-center gap-2.5")
		track(ui, has_in ? s.vol : 0, has_in && s.mute, "h-1.5")
		p.text(
			ui,
			has_in ? pct_label(s.vol) : "—",
			"w-[42] shrink-0 text-right text-xs font-medium tabular-nums",
		)
		p.end(ui)
	}
	p.end(ui)
}

default_out :: proc(m: ^Model) -> (Dev, bool) {
	for d in m.a.outs {
		if d.default {
			return d, true
		}
	}
	if len(m.a.outs) > 0 {
		return m.a.outs[0], true
	}
	return {}, false
}

default_in :: proc(m: ^Model) -> (Dev, bool) {
	for d in m.a.ins {
		if d.default {
			return d, true
		}
	}
	if len(m.a.ins) > 0 {
		return m.a.ins[0], true
	}
	return {}, false
}

vol_icon :: proc(v: f32, mute: bool) -> p.Icon {
	if mute || v <= 0.001 {
		return IC_VOLUME_X
	}
	if v < 0.5 {
		return IC_VOLUME_1
	}
	return IC_VOLUME_2
}

dev_icon :: proc(d: Dev) -> p.Icon {
	if d.input {
		return IC_MIC
	}
	switch d.form {
	case "headset", "headphone":
		return IC_HEADPHONES
	case "speaker":
		return IC_SPEAKER
	}
	if d.bus == "bluetooth" {
		return IC_BLUETOOTH
	}
	if index_of(d.desc, "HDMI") >= 0 {
		return IC_MONITOR
	}
	return IC_SPEAKER
}

index_of :: proc(hay, needle: string) -> int {
	if len(needle) > len(hay) {
		return -1
	}
	outer: for i in 0 ..= len(hay) - len(needle) {
		for j in 0 ..< len(needle) {
			if hay[i + j] != needle[j] {
				continue outer
			}
		}
		return i
	}
	return -1
}

// ---------------------------------------------------------------------------
// The volume track
//
// shadcn's slider is built for a pointer and this compositor cannot synthesise
// a click, so the track here is a read-out that the keyboard drives. It is the
// same geometry and the same tokens; it simply does not pretend to be
// draggable.
// ---------------------------------------------------------------------------

track :: proc(ui: ^p.Ctx, v: f32, mute: bool, h: string, on_blue := false) {
	p.div(
		ui,
		p.concat(
			ui,
			"flex-1 min-w-[60] rounded-full overflow-hidden flex-row ",
			on_blue ? "bg-white/25 " : "bg-muted ",
			h,
		),
	)
	defer p.end(ui)
	fill := on_blue \
		? (mute ? "bg-white/40" : "bg-white") \
		: (mute ? "bg-muted-foreground/40" : "bg-blue-600")
	p.div(ui, p.concat(ui, "h-full rounded-full ", fill))
	p.style(ui).w = p.pct(clamp(v, 0, 1) * 100)
	p.end(ui)
}

// ---------------------------------------------------------------------------
// Devices
// ---------------------------------------------------------------------------

devices_pane :: proc(ui: ^p.Ctx, m: ^Model) {
	p.col(ui, "flex-1 min-w-0 h-full min-h-0 p-4 gap-2 overflow-hidden")
	defer p.end(ui)

	if !m.have_tools {
		missing_tools(ui)
		return
	}

	section(ui, IC_SPEAKER, "Outputs", len(m.a.outs))
	if len(m.a.outs) == 0 {
		empty_line(ui, m.loaded ? "PipeWire reports no sinks" : "Reading the graph…")
	}
	for d, i in m.a.outs {
		device_row(ui, m, d, selected(m, .Out, i))
	}

	p.div(ui, "h-3 shrink-0")
	p.end(ui)

	section(ui, IC_MIC, "Inputs", len(m.a.ins))
	if len(m.a.ins) == 0 {
		empty_line(ui, m.loaded ? "No capture device (monitors are not listed)" : "Reading the graph…")
	}
	for d, i in m.a.ins {
		device_row(ui, m, d, selected(m, .In, i))
	}

	p.div(ui, "flex-1 min-h-0")
	p.end(ui)
}

selected :: proc(m: ^Model, kind: Item_Kind, i: int) -> bool {
	if m.at < 0 || m.at >= len(m.items) {
		return false
	}
	it := m.items[m.at]
	return it.kind == kind && it.i == i
}

section :: proc(ui: ^p.Ctx, ic: p.Icon, title: string, count: int) {
	p.row(ui, "w-full h-7 shrink-0 items-center gap-2 px-1")
	defer p.end(ui)
	p.icon(ui, ic, "size-3.5 shrink-0 text-muted-foreground")
	p.text(ui, title, LABEL)
	p.textf(ui, "text-[11] font-medium text-muted-foreground/70", "%d", count)
}

empty_line :: proc(ui: ^p.Ctx, s: string) {
	p.row(ui, "w-full h-10 shrink-0 items-center px-3")
	defer p.end(ui)
	p.text(ui, s, "text-xs text-muted-foreground")
}

device_row :: proc(ui: ^p.Ctx, m: ^Model, d: Dev, sel: bool) {
	p.key(ui, d.name)
	idx := p.row(ui, "w-full h-[68] shrink-0 items-center gap-3 px-3 rounded-xl transition duration-120")
	p.apply(ui, sel ? "bg-blue-600 text-white" : "hover:bg-accent", idx)
	defer p.end(ui)
	if p.clickable(ui, idx) {
		set_sel(m, fmt.tprintf("%s:%s", d.input ? "i" : "o", d.name))
	}

	dim := sel ? "text-white/75" : "text-muted-foreground"

	tile := sel \
		? "bg-white/20 text-white" \
		: (d.default ? "bg-blue-600 text-white" : "bg-muted text-muted-foreground")
	p.div(ui, p.concat(ui, "size-10 shrink-0 flex-row items-center justify-center rounded-[12] ", tile))
	p.icon(ui, d.mute ? IC_VOLUME_X : dev_icon(d), "size-5 shrink-0")
	p.end(ui)

	p.col(ui, "flex-1 min-w-0 gap-1")
	{
		p.row(ui, "items-center gap-2 min-w-0")
		p.text(ui, d.desc, "text-sm font-medium truncate max-w-[280]")
		if d.default {
			sc.badge_icon(ui, "Default", IC_CHECK, sel ? .Outline : .Default)
		}
		if d.mute {
			sc.badge(ui, "Muted", sel ? .Outline : .Destructive)
		}
		p.div(ui, "flex-1")
		p.end(ui)
		p.end(ui)

		p.text(ui, dev_subtitle(d), p.concat(ui, "text-[11] truncate ", dim))
	}
	p.end(ui)

	p.col(ui, "w-[260] shrink-0 gap-1.5")
	{
		p.row(ui, "w-full items-center gap-2.5")
		track(ui, d.vol, d.mute, "h-1.5", sel)
		p.text(
			ui,
			pct_label(d.vol),
			p.concat(
				ui,
				"w-[46] shrink-0 text-right text-sm font-semibold tabular-nums ",
				d.mute ? p.concat(ui, "line-through ", dim) : (sel ? "text-white" : "text-foreground"),
			),
		)
		p.end(ui)
		p.text(
			ui,
			fmt.tprintf("node %d · %s", d.node, d.spec == "" ? "—" : d.spec),
			p.concat(ui, "text-[10] font-mono truncate ", dim),
		)
	}
	p.end(ui)

	if sel {
		p.icon(ui, IC_CHEVRON_RIGHT, "size-4 shrink-0 text-white/70")
	}
}

// stream_subtitle names the stream rather than repeating the application: two
// rows both saying "Chromium" tell a person nothing about which is which.
stream_subtitle :: proc(s: Stream) -> string {
	if s.media != "" && s.media != s.app {
		return s.media
	}
	if s.binary != "" {
		return fmt.tprintf("%s · %d", s.binary, s.index)
	}
	return fmt.tprintf("stream %d", s.index)
}

dev_subtitle :: proc(d: Dev) -> string {
	parts := [4]string{}
	n := 0
	add :: proc(parts: ^[4]string, n: ^int, s: string) {
		if s != "" && n^ < 4 {
			parts[n^] = s
			n^ += 1
		}
	}
	add(&parts, &n, d.port)
	add(&parts, &n, bus_label(d))
	add(&parts, &n, state_label(d.state))
	switch n {
	case 0:
		return d.name
	case 1:
		return parts[0]
	case 2:
		return fmt.tprintf("%s · %s", parts[0], parts[1])
	}
	return fmt.tprintf("%s · %s · %s", parts[0], parts[1], parts[2])
}

missing_tools :: proc(ui: ^p.Ctx) {
	sc.empty_open(ui, "w-full flex-1 justify-center")
	defer sc.empty_end(ui)
	sc.empty_header_open(ui)
	defer sc.empty_header_end(ui)
	sc.empty_media_icon(ui, IC_TRIANGLE_ALERT)
	sc.empty_title(ui, "pactl and wpctl are not on PATH")
	sc.empty_description(
		ui,
		"This mixer drives PipeWire through its own command line tools. Install pipewire-pulse and wireplumber.",
	)
}

// ---------------------------------------------------------------------------
// Right pane: application streams and the input meter
// ---------------------------------------------------------------------------

right_pane :: proc(ui: ^p.Ctx, m: ^Model) {
	p.col(ui, "shrink-0 h-full min-h-0 bg-sidebar p-4 gap-2 overflow-hidden")
	p.style(ui).w = p.px(RIGHT_W)
	defer p.end(ui)

	playing, recording := 0, 0
	for s in m.a.streams {
		if s.record {recording += 1} else {playing += 1}
	}

	section(ui, IC_AUDIO_LINES, "Applications", playing)
	if playing == 0 {
		empty_line(ui, "Nothing is playing")
	}
	for s, i in m.a.streams {
		if s.record {
			continue
		}
		stream_row(ui, m, s, i, selected(m, .Stream, i))
	}

	if recording > 0 {
		p.div(ui, "h-3 shrink-0")
		p.end(ui)
		section(ui, IC_MIC, "Recording", recording)
		for s, i in m.a.streams {
			if !s.record {
				continue
			}
			stream_row(ui, m, s, i, selected(m, .Stream, i))
		}
	}

	p.div(ui, "flex-1 min-h-0")
	p.end(ui)

	meter_card(ui, m)
}

stream_row :: proc(ui: ^p.Ctx, m: ^Model, s: Stream, i: int, sel: bool) {
	p.key(ui, fmt.tprintf("s%d%d", s.record ? 1 : 0, s.index))
	idx := p.row(ui, "w-full h-[58] shrink-0 items-center gap-2.5 px-2.5 rounded-lg transition duration-120")
	p.apply(ui, sel ? "bg-blue-600 text-white" : "hover:bg-accent", idx)
	defer p.end(ui)
	if p.clickable(ui, idx) {
		set_sel(m, fmt.tprintf("s:%d:%d", s.record ? 1 : 0, s.index))
	}

	dim := sel ? "text-white/75" : "text-muted-foreground"

	tile := sel ? "bg-white/20 text-white" : "bg-muted text-muted-foreground"
	p.div(ui, p.concat(ui, "size-8 shrink-0 flex-row items-center justify-center rounded-[10] ", tile))
	p.icon(ui, s.record ? IC_MIC : (s.mute ? IC_VOLUME_X : IC_MUSIC), "size-4 shrink-0")
	p.end(ui)

	p.col(ui, "flex-1 min-w-0 gap-1")
	{
		p.row(ui, "items-center gap-1.5 min-w-0")
		p.text(ui, s.app, "text-xs font-medium truncate max-w-[150]")
		if s.corked {
			sc.badge(ui, "paused", .Outline)
		}
		p.div(ui, "flex-1")
		p.end(ui)
		p.text(ui, pct_label(s.vol), p.concat(ui, "shrink-0 text-xs font-semibold tabular-nums ", s.mute ? "line-through" : ""))
		p.end(ui)

		p.row(ui, "w-full items-center gap-2")
		track(ui, s.vol, s.mute, "h-1", sel)
		p.text(
			ui,
			stream_subtitle(s),
			p.concat(ui, "w-[108] shrink-0 text-[10] truncate text-right ", dim),
		)
		p.end(ui)
	}
	p.end(ui)
}

// ---------------------------------------------------------------------------
// The input level meter
// ---------------------------------------------------------------------------

meter_card :: proc(ui: ^p.Ctx, m: ^Model) {
	l := &m.level
	p.col(ui, "w-full shrink-0 rounded-xl border border-border bg-card p-3.5 gap-2.5")
	defer p.end(ui)

	p.row(ui, "w-full shrink-0 items-center gap-2")
	{
		p.icon(
			ui,
			l.on ? IC_MIC : IC_MIC_OFF,
			p.concat(ui, "size-3.5 shrink-0 ", l.on ? "text-destructive" : "text-muted-foreground"),
		)
		p.text(ui, "Input level", LABEL)
		p.div(ui, "flex-1")
		p.end(ui)
		if l.on {
			p.div(ui, "size-1.5 shrink-0 rounded-full bg-destructive")
			p.end(ui)
			p.text(ui, "listening", "text-[11] font-medium text-destructive whitespace-nowrap")
			p.style(ui).shrink = 0
		}
		sc.kbd(ui, "L")
	}
	p.end(ui)

	if !l.on {
		p.text(
			ui,
			"PipeWire publishes no peak level, so the only honest meter is one that opens the source and looks at the samples. Press L to start; nothing is recorded until you do.",
			"text-[11] text-muted-foreground leading-relaxed",
		)
		return
	}

	// The bar: RMS as the body, peak as a bright cap, and a decaying hold.
	p.div(ui, "w-full h-5 shrink-0 rounded-md bg-muted overflow-hidden relative")
	{
		p.div(ui, p.concat(ui, "absolute top-0 bottom-0 left-0 rounded-md ", meter_tone(l.peak)))
		p.style(ui).w = p.pct(clamp(l.peak, 0, 1) * 100)
		p.end(ui)

		p.div(ui, "absolute top-0 bottom-0 left-0 bg-foreground/25")
		p.style(ui).w = p.pct(clamp(l.rms, 0, 1) * 100)
		p.end(ui)

		// Peak hold.
		p.div(ui, "absolute top-0 bottom-0 w-[2] bg-foreground/70")
		p.style(ui).inset[p.LEFT] = p.pct(clamp(l.hold, 0, 1) * 100)
		p.end(ui)
	}
	p.end(ui)

	// A short history strip, drawn straight onto the canvas.
	p.pixels(ui, "w-full h-[34] shrink-0 rounded-md bg-muted/50 overflow-hidden", l, meter_hist)

	p.row(ui, "w-full shrink-0 items-baseline gap-3")
	{
		p.text(ui, "peak", "shrink-0 text-[10] uppercase tracking-wide text-muted-foreground")
		p.text(ui, db_label(l.peak), "shrink-0 text-xs font-semibold tabular-nums")
		p.text(ui, "rms", "shrink-0 text-[10] uppercase tracking-wide text-muted-foreground")
		p.text(ui, db_label(l.rms), "shrink-0 text-xs font-medium tabular-nums")
		p.div(ui, "flex-1")
		p.end(ui)
		p.text(
			ui,
			l.have ? fmt.tprintf("%d kB captured", l.bytes / 1024) : "waiting for samples",
			"shrink-0 text-[10] text-muted-foreground whitespace-nowrap",
		)
	}
	p.end(ui)

	p.text(ui, level_cmd(l), "w-full text-[10] font-mono text-muted-foreground/80 truncate")
}

meter_tone :: proc(v: f32) -> string {
	switch {
	case v >= 0.95:
		return "bg-destructive"
	case v >= 0.7:
		return "bg-amber-500"
	}
	return "bg-emerald-500"
}

meter_hist :: proc(c: ^p.Canvas, r: p.Rect, l: ^Level) {
	if l.n < 2 {
		return
	}
	col := p.hex(0x059669)
	n := l.n
	w := int(r.w)
	if w <= 0 {
		return
	}
	for px in 0 ..< w {
		// Oldest on the left, newest on the right.
		i := n - 1 - (w - 1 - px) * n / max(1, w)
		if i < 0 || i >= n {
			continue
		}
		v := clamp(level_hist_at(l, i), 0, 1)
		h := v * r.h
		x := int(r.x) + px
		y0 := int(r.y + r.h - h)
		column(c, x, y0, int(r.y + r.h), p.fade(col, 0.85))
	}
}

// column blends one vertical run straight into the buffer. A one-pixel-wide
// fill_rect misses the rasterizer's span fast path and falls back to the
// antialiased per-pixel path, which composites in linear light through a pow()
// per channel — far too expensive to do once per column per frame.
column :: proc "contextless" (c: ^p.Canvas, x, y_top, y_bot: int, col: p.Color) {
	y0 := max(y_top, int(c.clip.y), 0)
	y1 := min(y_bot, int(c.clip.y + c.clip.h), c.h)
	if y0 >= y1 || x < 0 || x >= c.w {
		return
	}
	a := u32(col.a)
	if a == 0 {
		return
	}
	na := 255 - a
	cr := u32(col.r) * a + 127
	cg := u32(col.g) * a + 127
	cb := u32(col.b) * a + 127
	for y in y0 ..< y1 {
		i := y * c.w + x
		dst := c.px[i]
		rr := (cr + ((dst >> 16) & 0xff) * na) / 255
		gg := (cg + ((dst >> 8) & 0xff) * na) / 255
		bb := (cb + (dst & 0xff) * na) / 255
		c.px[i] = 0xff00_0000 | (rr << 16) | (gg << 8) | bb
	}
}

// ---------------------------------------------------------------------------
// Footer
// ---------------------------------------------------------------------------

footer :: proc(ui: ^p.Ctx, m: ^Model) {
	p.row(ui, "w-full shrink-0 items-center gap-3 px-4 bg-card border-t border-border")
	p.style(ui).h = p.px(FOOTER_H)
	defer p.end(ui)

	hint(ui, "Up", "Down", "select")
	hint(ui, "Left", "Right", "volume")
	hint(ui, "M", "", "mute")
	hint(ui, "D", "", "default")
	hint(ui, "L", "", "meter")
	hint(ui, "U", "", "restore")
	hint(ui, "C", "", "log")

	p.div(ui, "flex-1 min-w-0")
	p.end(ui)

	if m.toast_len > 0 && g_now < m.toast_until {
		p.row(ui, "shrink-0 items-center gap-1.5 max-w-[520]")
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

	// What the default sink was when this window opened. A mixer that changes
	// the machine should always be able to say what it changed it from.
	if m.orig_ok {
		p.text(
			ui,
			fmt.tprintf(
				"%s was %.0f%%%s at launch%s",
				m.orig_name,
				m.orig_vol * 100,
				m.orig_mute ? " and muted" : "",
				m.touched ? " · U restores it" : "",
			),
			"shrink-0 text-[11] text-muted-foreground whitespace-nowrap",
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
	panel(ui, 660, 0.18, 70)
	defer p.end(ui)

	p.row(ui, "w-full shrink-0 items-center gap-2 px-4 h-12 border-b border-border")
	p.icon(ui, IC_TERMINAL, "size-4 shrink-0 text-muted-foreground")
	p.text(ui, "Commands executed", "text-sm font-semibold shrink-0")
	p.textf(ui, "flex-1 text-xs text-muted-foreground", "%d since launch", g_log_count)
	sc.kbd(ui, "Esc")
	p.end(ui)

	p.col(ui, "w-full shrink-0 p-2 gap-0")
	defer p.end(ui)
	entries := log_recent(14)
	if len(entries) == 0 {
		empty_line(ui, "Nothing yet — this applet has only read.")
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
	panel(ui, 560, 0.14, 90)
	defer p.end(ui)

	p.row(ui, "w-full shrink-0 items-center gap-2 px-4 h-12 border-b border-border")
	p.icon(ui, IC_SLIDERS_HORIZONTAL, "size-4 shrink-0 text-muted-foreground")
	p.text(ui, "Keyboard", "text-sm font-semibold shrink-0")
	p.div(ui, "flex-1")
	p.end(ui)
	sc.kbd(ui, "Esc")
	p.end(ui)

	p.col(ui, "w-full p-4 gap-1.5")
	defer p.end(ui)
	rows := [?][2]string {
		{"Up Down Home End", "Move between devices and streams"},
		{"Left Right", "Volume by 5%"},
		{"Shift Left/Right", "Volume by 1%"},
		{"M", "Mute or unmute the selection"},
		{"D or Enter", "Make the selected device the default"},
		{"L", "Start or stop the input level meter"},
		{"U", "Put the default output back to its launch volume"},
		{"R", "Re-read the graph now"},
		{"C", "Every command this applet has run"},
		{"Ctrl Q", "Quit"},
	}
	for r in rows {
		p.row(ui, "w-full shrink-0 items-center gap-3 h-7")
		p.text(ui, r[0], "w-[160] shrink-0 text-[11] font-mono text-foreground")
		p.text(ui, r[1], "flex-1 min-w-0 text-xs text-muted-foreground truncate")
		p.end(ui)
	}

	sc.separator(ui)
	p.text(
		ui,
		"Volume is never set above 100%: PipeWire amplifies past it in software, and this applet will not hand anyone a clipped output. The input meter records from the microphone only while it is on.",
		"text-[11] text-muted-foreground leading-relaxed",
	)
}
