package main

// The interface. One procedure per region, rebuilt every frame from whatever
// the last sample read out of /proc.
//
// The graphs are the only thing here that is not made of elements: an area
// chart is a per-pixel job, so it is drawn straight onto the canvas through
// `p.pixels` while everything around it stays ordinary flexbox.

import "core:fmt"
import "core:math"
import kit "kit:."
import p "palmy:."
import sc "shadcn:."

WIN_W :: 1380
WIN_H :: 940
LEFT_W :: 452

FIELD_SKIN ::
	"h-8 rounded-lg border border-input bg-background text-foreground " +
	"text-sm px-2.5 focus:border-ring focus:ring-3 focus:ring-ring/50"

// Series colours. Chosen from the Tailwind palette the rest of the UI uses, so
// a graph and a badge of the same subject agree.
CPU_HEX :: 0x2563eb
MEM_HEX :: 0x7c3aed
SWAP_HEX :: 0xd97706
RX_HEX :: 0x059669
TX_HEX :: 0x0284c7

LABEL ::
	"shrink-0 text-[11] font-semibold uppercase tracking-wider text-muted-foreground whitespace-nowrap"

start_window :: proc() -> (^p.App, string) {
	return kit.start(
		{
			title = "System Monitor",
			width = WIN_W,
			height = WIN_H,
			min_width = 1100,
			min_height = 700,
			root_class = "w-full h-full bg-background text-foreground",
			// A monitor has something new to show every frame, so it asks for
			// one every vsync rather than waiting for input.
			always = true,
		},
	)
}

// measure_rows works out how many process rows fit. palmy scrolls from the
// wheel only, so the table is windowed by hand and the window size decides how
// large that window is.
measure_rows :: proc(m: ^Model, vp: [2]f32) {
	body := vp.y - HEADER_H - STRIP_H - FOOTER_H
	table := body - 50 - 30 - 28 // toolbar, column header, padding and footer line
	m.rows = clamp(int(table / ROW_H), 3, 120)
}

// ---------------------------------------------------------------------------
// Graphs
// ---------------------------------------------------------------------------

Graph :: struct {
	a:     ^Series,
	b:     ^Series, // optional second trace, drawn over the first
	col_a: p.Color,
	col_b: p.Color,
	// 0 autoscales to the peak in the window, rounded up to something tidy.
	fixed: f32,
	grid:  int,
}

graph_draw :: proc(c: ^p.Canvas, r: p.Rect, g: ^Graph) {
	grid_col := p.hexa(0x14000000)

	// Horizontal rules, so a reader can judge a height without an axis.
	if g.grid > 1 {
		for i in 1 ..< g.grid {
			y := math.floor(r.y + r.h * f32(i) / f32(g.grid))
			p.fill_rect(c, {r.x, y, r.w, max(1, c.scale * 0.5)}, grid_col)
		}
	}

	top := g.fixed
	if top <= 0 {
		top = series_peak(g.a)
		if g.b != nil {
			top = max(top, series_peak(g.b))
		}
		top = nice_ceiling(top)
	}
	if top <= 0 {
		return
	}

	trace(c, r, g.a, g.col_a, top)
	if g.b != nil {
		trace(c, r, g.b, g.col_b, top)
	}
}

// nice_ceiling rounds a peak up to 1, 2 or 5 times a power of ten, so an
// autoscaling axis steps rather than jitters.
nice_ceiling :: proc(v: f32) -> f32 {
	if v <= 0 {
		return 0
	}
	e := math.pow(f32(10), math.floor(math.log10(v)))
	m := v / e
	switch {
	case m <= 1:
		return e
	case m <= 2:
		return 2 * e
	case m <= 5:
		return 5 * e
	}
	return 10 * e
}

@(private)
trace :: proc(c: ^p.Canvas, r: p.Rect, s: ^Series, col: p.Color, top: f32) {
	n := series_count(s)
	if n < 2 {
		return
	}
	// The newest sample sits on the right edge and the window scrolls left, so
	// a short history is a short run at the right rather than a stretched one.
	step := r.w / f32(HIST - 1)
	ypos :: proc(r: p.Rect, v, top: f32) -> f32 {
		h := clamp(v / top, 0, 1) * r.h
		return r.y + r.h - h
	}

	area := p.fade(col, 0.2)
	th := max(1.25 * c.scale, 1.25)

	x_lo := max(int(r.x), int(c.clip.x), 0)
	x_hi := min(int(r.x + r.w), int(c.clip.x + c.clip.w), c.w)
	y_bot := min(int(r.y + r.h), int(c.clip.y + c.clip.h), c.h)

	for i in 0 ..< n - 1 {
		x0 := r.x + r.w - f32(n - 1 - i) * step
		x1 := x0 + step
		if x1 < f32(x_lo) {
			continue
		}
		v0 := series_at(s, i)
		v1 := series_at(s, i + 1)
		y0 := ypos(r, v0, top)
		y1 := ypos(r, v1, top)

		// The band under the segment, interpolated per column. This writes the
		// pixels itself rather than calling fill_rect once per column: a
		// one-pixel-wide rect misses the rasterizer's span fast path and falls
		// back to the antialiased per-pixel path, which composites in linear
		// light through a pow() per channel. At five traces and sixty frames a
		// second that is tens of millions of pow() calls, and it showed up as
		// most of this program's CPU time.
		px0 := max(int(x0), x_lo)
		px1 := min(int(x1 + 1), x_hi)
		for px in px0 ..< px1 {
			t := clamp((f32(px) + 0.5 - x0) / step, 0, 1)
			column(c, px, int(y0 + (y1 - y0) * t), y_bot, area)
		}
		p.draw_line(c, x0, y0, x1, y1, th, col)
	}
}

// column blends one vertical run straight into the buffer, with the same
// integer arithmetic the rasterizer's own span fill uses.
@(private)
column :: proc "contextless" (c: ^p.Canvas, x, y_top, y_bot: int, col: p.Color) {
	y0 := max(y_top, int(c.clip.y), 0)
	if y0 >= y_bot || x < 0 || x >= c.w {
		return
	}
	a := u32(col.a)
	if a == 0 {
		return
	}
	if a >= 255 {
		v := 0xff00_0000 | (u32(col.r) << 16) | (u32(col.g) << 8) | u32(col.b)
		for y in y0 ..< y_bot {
			c.px[y * c.w + x] = v
		}
		return
	}
	na := 255 - a
	cr := u32(col.r) * a + 127
	cg := u32(col.g) * a + 127
	cb := u32(col.b) * a + 127
	for y in y0 ..< y_bot {
		i := y * c.w + x
		dst := c.px[i]
		rr := (cr + ((dst >> 16) & 0xff) * na) / 255
		gg := (cg + ((dst >> 8) & 0xff) * na) / 255
		bb := (cb + (dst & 0xff) * na) / 255
		c.px[i] = 0xff00_0000 | (rr << 16) | (gg << 8) | bb
	}
}

// ---------------------------------------------------------------------------
// The frame
// ---------------------------------------------------------------------------

build :: proc(ui: ^p.Ctx, m: ^Model, v: View) {
	p.col(ui, "w-full h-full bg-background text-foreground")
	defer p.end(ui)

	header(ui, m, v)

	p.row(ui, "w-full flex-1 min-h-0")
	{
		left_column(ui, m)
		p.div(ui, "w-px h-full shrink-0 bg-border")
		p.end(ui)
		process_pane(ui, m, v)
	}
	p.end(ui)

	strip(ui, m)
	footer(ui, m, v)

	// palmy has no xdg_popup, so overlays are absolutely positioned children
	// of the window, lifted with `z`.
	if m.detail_open {
		detail_overlay(ui, m, v)
	}
	if m.help_open {
		help_overlay(ui, m)
	}
}

// ---------------------------------------------------------------------------
// Header
// ---------------------------------------------------------------------------

header :: proc(ui: ^p.Ctx, m: ^Model, v: View) {
	p.row(ui, "w-full shrink-0 items-center gap-4 px-5 bg-card border-b border-border")
	p.style(ui).h = p.px(HEADER_H)
	defer p.end(ui)

	p.div(ui, "size-11 shrink-0 flex-row items-center justify-center rounded-[14] bg-blue-600 text-white")
	p.icon(ui, IC_ACTIVITY, "size-5 shrink-0")
	p.end(ui)

	p.col(ui, "shrink-0 gap-1 max-w-[320]")
	{
		p.row(ui, "items-center gap-2")
		p.text(ui, m.host.hostname, "text-[17] font-semibold tracking-tight whitespace-nowrap")
		p.style(ui).shrink = 0
		if m.paused {
			sc.badge(ui, "Paused", .Destructive)
		} else if m.samples <= 1 {
			sc.badge(ui, "Priming", .Secondary)
		}
		p.end(ui)

		sub := m.host.distro == "" \
			? fmt.tprintf("Linux %s", m.host.kernel) \
			: fmt.tprintf("%s · Linux %s", m.host.distro, m.host.kernel)
		p.text(ui, sub, "text-xs text-muted-foreground truncate")
	}
	p.end(ui)

	p.div(ui, "w-px h-10 shrink-0 bg-border")
	p.end(ui)

	// The summary. Five figures that answer "is this machine busy".
	p.row(ui, "flex-1 min-w-0 items-center gap-5")
	{
		stat(
			ui,
			"CPU",
			m.samples > 1 ? fmt.tprintf("%.1f%%", m.cpu.agg * 100) : "—",
			fmt.tprintf("%s · %d threads", short_cpu(m.host.cpu_model), max(m.cpu.cores, m.host.threads)),
			IC_CPU,
			load_tone(m.cpu.agg),
		)
		stat(
			ui,
			"Memory",
			m.mem.ok ? fmt.tprintf("%.1f%%", pct(mem_used(m.mem), m.mem.total)) : "—",
			m.mem.ok \
			? fmt.tprintf("%s of %s", fmt_bytes(mem_used(m.mem)), fmt_bytes(m.mem.total)) \
			: "unavailable",
			IC_MEMORY_STICK,
			load_tone(f32(pct(mem_used(m.mem), m.mem.total) / 100)),
		)
		stat(
			ui,
			"Load",
			m.load.ok ? fmt.tprintf("%.2f", m.load.avg[0]) : "—",
			fmt.tprintf("%.2f, %.2f over 5 and 15 min", m.load.avg[1], m.load.avg[2]),
			IC_GAUGE,
			load_tone(m.load.avg[0] / f32(max(1, m.host.threads))),
		)
		stat(
			ui,
			"Network",
			m.samples > 1 ? fmt_rate(m.net.rx_rate + m.net.tx_rate) : "—",
			fmt.tprintf("%s down · %s up", fmt_rate(m.net.rx_rate), fmt_rate(m.net.tx_rate)),
			IC_NETWORK,
			"text-foreground",
		)
		stat(
			ui,
			"Uptime",
			fmt_uptime(m.uptime),
			fmt.tprintf("%d processes · %d running", v.total, m.load.running),
			IC_CLOCK,
			"text-foreground",
		)
	}
	p.end(ui)
}

short_cpu :: proc(s: string) -> string {
	// "AMD Ryzen 9 6900HX with Radeon Graphics" reads better without the tail.
	if i := index_of(s, " with "); i > 0 {
		return s[:i]
	}
	return s
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

pct :: proc(a, b: u64) -> f64 {
	if b == 0 {
		return 0
	}
	return f64(a) / f64(b) * 100
}

load_tone :: proc(frac: f32) -> string {
	switch {
	case frac >= 0.9:
		return "text-destructive"
	case frac >= 0.7:
		return "text-amber-600"
	}
	return "text-foreground"
}

stat :: proc(ui: ^p.Ctx, label, value, sub: string, ic: p.Icon, tone: string) {
	p.col(ui, "flex-1 min-w-0 gap-0.5")
	defer p.end(ui)

	p.row(ui, "items-center gap-1.5")
	p.icon(ui, ic, "size-3 shrink-0 text-muted-foreground")
	p.text(ui, label, LABEL)
	p.end(ui)

	p.text(ui, value, p.concat(ui, "text-[19] font-semibold tracking-tight truncate ", tone))
	p.text(ui, sub, "text-[11] text-muted-foreground truncate")
}

// ---------------------------------------------------------------------------
// Left column: the three live graphs
// ---------------------------------------------------------------------------

left_column :: proc(ui: ^p.Ctx, m: ^Model) {
	p.col(ui, "shrink-0 h-full min-h-0 p-4 gap-3.5 bg-sidebar")
	p.style(ui).w = p.px(LEFT_W)
	defer p.end(ui)

	cpu_card(ui, m)
	memory_card(ui, m)
	network_card(ui, m)
}

card_open :: proc(ui: ^p.Ctx, class := "") -> int {
	idx := p.col(ui, "w-full rounded-xl border border-border bg-card p-3 gap-2 overflow-hidden")
	p.apply(ui, class, idx)
	return idx
}

card_head :: proc(ui: ^p.Ctx, ic: p.Icon, title, value, sub: string, tone: string) {
	p.row(ui, "w-full shrink-0 items-center gap-2")
	defer p.end(ui)
	p.icon(ui, ic, "size-3.5 shrink-0 text-muted-foreground")
	p.text(ui, title, LABEL)
	p.div(ui, "flex-1 min-w-0")
	p.end(ui)
	if sub != "" {
		p.text(ui, sub, "shrink-0 text-[11] text-muted-foreground whitespace-nowrap")
	}
	p.text(ui, value, p.concat(ui, "shrink-0 text-sm font-semibold tabular-nums whitespace-nowrap ", tone))
}

cpu_card :: proc(ui: ^p.Ctx, m: ^Model) {
	card_open(ui, "flex-1 min-h-0")
	defer p.end(ui)

	card_head(
		ui,
		IC_CPU,
		"Processor",
		m.samples > 1 ? fmt.tprintf("%.1f%%", m.cpu.agg * 100) : "priming",
		fmt.tprintf("%d cores · %d threads", max(1, m.host.cores), max(m.cpu.cores, 1)),
		load_tone(m.cpu.agg),
	)

	m.g_cpu = Graph {
		a     = &m.h_cpu,
		col_a = p.hex(CPU_HEX),
		fixed = 100,
		grid  = 4,
	}
	graph_panel(ui, m, &m.g_cpu, "flex-1 min-h-[52]", "100%", "0%")

	// Per core, so a single pegged thread is visible rather than averaged away.
	p.col(ui, "w-full shrink-0 gap-1")
	defer p.end(ui)
	p.row(ui, "w-full shrink-0 items-end gap-1 h-[38]")
	{
		n := max(m.cpu.cores, 1)
		for i in 0 ..< n {
			f := m.cpu.per_core[i]
			// Track, with the bar growing from its floor.
			p.div(ui, "flex-1 min-w-[6] h-full flex-col justify-end rounded-[3] bg-muted overflow-hidden")
			{
				h := max(2, f * 38)
				p.div(ui, p.concat(ui, "w-full rounded-[3] ", core_tone(f)))
				p.style(ui).h = p.px(h)
				p.end(ui)
			}
			p.end(ui)
		}
	}
	p.end(ui)
	p.row(ui, "w-full shrink-0 items-center gap-1")
	{
		n := max(m.cpu.cores, 1)
		for i in 0 ..< n {
			p.textf(ui, "flex-1 min-w-[6] text-[8] text-center text-muted-foreground/70", "%d", i)
		}
	}
	p.end(ui)
}

core_tone :: proc(f: f32) -> string {
	switch {
	case f >= 0.85:
		return "bg-destructive"
	case f >= 0.6:
		return "bg-amber-500"
	case f >= 0.02:
		return "bg-blue-600"
	}
	return "bg-blue-600/30"
}

memory_card :: proc(ui: ^p.Ctx, m: ^Model) {
	card_open(ui, "flex-1 min-h-0")
	defer p.end(ui)

	card_head(
		ui,
		IC_MEMORY_STICK,
		"Memory",
		m.mem.ok ? fmt.tprintf("%.1f%%", pct(mem_used(m.mem), m.mem.total)) : "—",
		fmt.tprintf("%s available", fmt_bytes(m.mem.available)),
		load_tone(f32(pct(mem_used(m.mem), m.mem.total) / 100)),
	)

	m.g_mem = Graph {
		a     = &m.h_mem,
		b     = &m.h_swap,
		col_a = p.hex(MEM_HEX),
		col_b = p.hex(SWAP_HEX),
		fixed = 100,
		grid  = 4,
	}
	graph_panel(ui, m, &m.g_mem, "flex-1 min-h-[36]", "100%", "0%")

	meter(
		ui,
		"RAM",
		fmt.tprintf("%s / %s", fmt_bytes(mem_used(m.mem)), fmt_bytes(m.mem.total)),
		f32(pct(mem_used(m.mem), m.mem.total) / 100),
		"bg-violet-600",
	)
	if m.mem.swap_total > 0 {
		used := m.mem.swap_total - m.mem.swap_free
		meter(
			ui,
			"Swap",
			fmt.tprintf("%s / %s", fmt_bytes(used), fmt_bytes(m.mem.swap_total)),
			f32(pct(used, m.mem.swap_total) / 100),
			"bg-amber-600",
		)
	} else {
		meter(ui, "Swap", "none configured", 0, "bg-amber-600")
	}
	p.row(ui, "w-full shrink-0 items-center gap-3")
	{
		mini(ui, "Cached", fmt_bytes(m.mem.cached))
		mini(ui, "Buffers", fmt_bytes(m.mem.buffers))
	}
	p.end(ui)
}

mini :: proc(ui: ^p.Ctx, k, val: string) {
	p.row(ui, "flex-1 min-w-0 items-baseline gap-1.5")
	defer p.end(ui)
	p.text(ui, k, "shrink-0 text-[10] uppercase tracking-wide text-muted-foreground")
	p.text(ui, val, "flex-1 min-w-0 text-[11] font-medium truncate")
}

meter :: proc(ui: ^p.Ctx, label, value: string, frac: f32, tone: string) {
	p.col(ui, "w-full shrink-0 gap-1")
	defer p.end(ui)
	p.row(ui, "w-full items-baseline gap-2")
	p.text(ui, label, "shrink-0 text-[11] font-medium")
	p.div(ui, "flex-1 min-w-0")
	p.end(ui)
	p.text(ui, value, "shrink-0 text-[11] text-muted-foreground whitespace-nowrap")
	p.end(ui)

	p.div(ui, "w-full h-1.5 shrink-0 rounded-full bg-muted overflow-hidden flex-row")
	{
		w := clamp(frac, 0, 1)
		p.div(ui, p.concat(ui, "h-full rounded-full ", tone))
		p.style(ui).w = p.pct(w * 100)
		p.end(ui)
	}
	p.end(ui)
}

network_card :: proc(ui: ^p.Ctx, m: ^Model) {
	card_open(ui, "flex-1 min-h-0")
	defer p.end(ui)

	peak := max(series_peak(&m.h_rx), series_peak(&m.h_tx))
	card_head(
		ui,
		IC_NETWORK,
		"Network",
		m.samples > 1 ? fmt_rate(m.net.rx_rate + m.net.tx_rate) : "priming",
		fmt.tprintf("peak %s", fmt_rate(f64(nice_ceiling(peak)))),
		"text-foreground",
	)

	m.g_net = Graph {
		a     = &m.h_rx,
		b     = &m.h_tx,
		col_a = p.hex(RX_HEX),
		col_b = p.hex(TX_HEX),
		fixed = 0,
		grid  = 4,
	}
	graph_panel(ui, m, &m.g_net, "flex-1 min-h-[52]", fmt_rate(f64(nice_ceiling(peak))), "0")

	p.row(ui, "w-full shrink-0 items-center gap-4")
	{
		legend(ui, "bg-emerald-600", "Download", fmt_rate(m.net.rx_rate))
		legend(ui, "bg-sky-600", "Upload", fmt_rate(m.net.tx_rate))
	}
	p.end(ui)
}

legend :: proc(ui: ^p.Ctx, dot, label, value: string) {
	p.row(ui, "flex-1 min-w-0 items-center gap-1.5")
	defer p.end(ui)
	p.div(ui, p.concat(ui, "size-2 shrink-0 rounded-full ", dot))
	p.end(ui)
	p.text(ui, label, "shrink-0 text-[11] text-muted-foreground whitespace-nowrap")
	p.text(ui, value, "flex-1 min-w-0 text-[11] font-semibold tabular-nums truncate")
}

// graph_panel wraps the canvas with its axis labels and an honest empty state
// for the first second, when there is one sample and therefore no rate yet.
graph_panel :: proc(ui: ^p.Ctx, m: ^Model, g: ^Graph, class, hi, lo: string) {
	p.div(ui, p.concat(ui, "w-full relative rounded-lg bg-muted/40 overflow-hidden ", class))
	defer p.end(ui)

	p.pixels(ui, "w-full h-full", g, graph_draw)

	if series_count(g.a) < 2 {
		p.div(ui, "absolute inset-0 flex-row items-center justify-center")
		p.text(ui, "collecting the first two samples…", "text-[11] text-muted-foreground")
		p.end(ui)
		return
	}

	// Axis labels, laid over the plot in the corners the trace rarely reaches.
	p.text(ui, hi, "absolute top-1 right-1.5 text-[9] font-medium text-muted-foreground")
	p.text(ui, lo, "absolute bottom-1 right-1.5 text-[9] font-medium text-muted-foreground")
}

// ---------------------------------------------------------------------------
// The process table
// ---------------------------------------------------------------------------

W_PID :: f32(66)
W_CPU :: f32(74)
W_MEM :: f32(86)
W_THR :: f32(60)
W_USER :: f32(94)

process_pane :: proc(ui: ^p.Ctx, m: ^Model, v: View) {
	p.col(ui, "flex-1 min-w-0 h-full min-h-0")
	defer p.end(ui)

	process_toolbar(ui, m, v)
	process_header(ui, m)

	p.col(ui, "w-full flex-1 min-h-0 px-2 pt-1 overflow-hidden")
	defer p.end(ui)

	if len(v.rows) == 0 {
		process_empty(ui, m)
		return
	}

	lo := clamp(m.top, 0, max(0, len(v.rows) - 1))
	hi := min(len(v.rows), lo + m.rows)
	for k in lo ..< hi {
		i := v.rows[k]
		process_row(ui, m, m.procs[i], i == v.sel)
	}

	p.div(ui, "flex-1 min-h-0")
	p.end(ui)

	if len(v.rows) > hi - lo {
		p.row(ui, "w-full h-6 shrink-0 items-center gap-1.5 px-2")
		p.icon(ui, IC_ELLIPSIS, "size-3 shrink-0 text-muted-foreground")
		p.textf(
			ui,
			"text-[11] text-muted-foreground whitespace-nowrap",
			"showing %d-%d of %d matching processes",
			lo + 1,
			hi,
			len(v.rows),
		)
		p.end(ui)
	}
}

process_toolbar :: proc(ui: ^p.Ctx, m: ^Model, v: View) {
	p.row(ui, "w-full h-[50] shrink-0 items-center gap-2.5 px-4 border-b border-border")
	defer p.end(ui)

	p.icon(ui, IC_SEARCH, "size-4 shrink-0 text-muted-foreground")
	at := p.node_count(ui)
	p.text_field(ui, &m.filter, "Filter by name, command, user or pid", FIELD_SKIN + " flex-1 min-w-0 max-w-[340]")
	m.filter_focus = p.focused(ui, at)
	m.filter_id = p.node_id(ui, at)
	if !m.filter_focus && len(m.filter) == 0 {
		sc.kbd(ui, "/")
	}

	p.div(ui, "flex-1 min-w-0")
	p.end(ui)

	p.row(ui, "shrink-0 items-center gap-1.5")
	{
		p.textf(
			ui,
			"text-[11] text-muted-foreground whitespace-nowrap",
			"%d of %d",
			len(v.rows),
			v.total,
		)
		p.style(ui).shrink = 0
		sc.badge_icon(
			ui,
			fmt.tprintf("%s %s", sort_label(m.sort), m.desc ? "desc" : "asc"),
			m.desc ? IC_ARROW_DOWN : IC_ARROW_UP,
			.Secondary,
		)
		chip(ui, "Kernel threads", "K", m.show_kernel)
		chip(ui, "Idle", "I", m.show_idle)
	}
	p.end(ui)
}

// chip is a read-only indicator for a boolean the keyboard owns: a pointer
// cannot be clicked on this compositor, so it shows the key instead of
// pretending to be a button.
chip :: proc(ui: ^p.Ctx, label, hint: string, on: bool) {
	p.row(
		ui,
		p.concat(
			ui,
			"shrink-0 items-center gap-1.5 h-6 px-2 rounded-md border ",
			on ? "border-blue-600/30 bg-blue-600/10 text-blue-700" : "border-border text-muted-foreground",
		),
	)
	defer p.end(ui)
	p.icon(ui, on ? IC_CHECK : IC_X, "size-3 shrink-0")
	p.text(ui, label, "text-[11] font-medium whitespace-nowrap")
	p.style(ui).shrink = 0
	sc.kbd(ui, hint)
}

process_header :: proc(ui: ^p.Ctx, m: ^Model) {
	p.row(ui, "w-full h-[30] shrink-0 items-center px-2 bg-muted/50 border-b border-border")
	defer p.end(ui)

	head_cell(ui, m, "PID", .Pid, W_PID, right = true)
	head_cell(ui, m, "Process", .Name, 0, right = false)
	head_cell(ui, m, "CPU %", .Cpu, W_CPU, right = true)
	head_cell(ui, m, "Memory", .Mem, W_MEM, right = true)
	head_cell(ui, m, "Thr", .Threads, W_THR, right = true)
	head_cell(ui, m, "User", .User, W_USER, right = false)
	p.div(ui, "w-6 shrink-0")
	p.end(ui)
}

head_cell :: proc(ui: ^p.Ctx, m: ^Model, label: string, k: Sort_Key, w: f32, right: bool) {
	active := m.sort == k
	idx := p.row(ui, "h-full items-center gap-1 px-2 overflow-hidden")
	if w > 0 {
		p.style(ui, idx).w = p.px(w)
		p.style(ui, idx).shrink = 0
	} else {
		p.apply(ui, "flex-1 min-w-0", idx)
	}
	if right {
		p.apply(ui, "justify-end", idx)
	}
	defer p.end(ui)

	p.text(
		ui,
		label,
		p.concat(
			ui,
			"text-[11] font-semibold uppercase tracking-wider whitespace-nowrap ",
			active ? "text-foreground" : "text-muted-foreground",
		),
	)
	p.style(ui).shrink = 0
	if active {
		p.icon(ui, m.desc ? IC_ARROW_DOWN : IC_ARROW_UP, "size-3 shrink-0 text-blue-600")
	}
}

process_row :: proc(ui: ^p.Ctx, m: ^Model, r: Proc_Row, selected: bool) {
	p.key(ui, fmt.tprintf("%d", r.pid))
	idx := p.row(ui, "w-full shrink-0 items-center rounded-md transition duration-100")
	p.style(ui, idx).h = p.px(ROW_H)
	p.apply(ui, selected ? "bg-blue-600 text-white" : "hover:bg-accent", idx)
	defer p.end(ui)
	if p.clickable(ui, idx) {
		m.sel_pid = r.pid
	}

	dim := selected ? "text-white/70" : "text-muted-foreground"

	// PID
	cell(ui, W_PID, true)
	p.textf(ui, p.concat(ui, "text-xs font-mono whitespace-nowrap ", dim), "%d", r.pid)
	p.end(ui)

	// Name, then as much of the command line as fits.
	cell(ui, 0, false)
	p.text(ui, r.name, "shrink-0 text-xs font-medium whitespace-nowrap max-w-[190] truncate")
	tail := cmd_tail(r)
	if tail != "" {
		p.text(ui, tail, p.concat(ui, "flex-1 min-w-0 ml-2 text-[11] font-mono truncate ", dim))
	}
	p.end(ui)

	// CPU
	cell(ui, W_CPU, true)
	if r.cpu >= 0.05 {
		p.textf(
			ui,
			p.concat(
				ui,
				"text-xs font-medium tabular-nums whitespace-nowrap ",
				selected ? "text-white" : cpu_tone(r.cpu),
			),
			"%.1f",
			r.cpu,
		)
	} else {
		p.text(ui, "·", p.concat(ui, "text-xs ", dim))
	}
	p.end(ui)

	// Memory
	cell(ui, W_MEM, true)
	if r.rss > 0 {
		p.text(
			ui,
			fmt_bytes_short(r.rss),
			p.concat(ui, "text-xs tabular-nums whitespace-nowrap ", selected ? "text-white" : "text-foreground"),
		)
	} else {
		p.text(ui, "·", p.concat(ui, "text-xs ", dim))
	}
	p.end(ui)

	// Threads
	cell(ui, W_THR, true)
	p.textf(ui, p.concat(ui, "text-xs tabular-nums whitespace-nowrap ", dim), "%d", r.threads)
	p.end(ui)

	// User
	cell(ui, W_USER, false)
	p.text(ui, user_or_uid(r), p.concat(ui, "text-xs truncate ", dim))
	p.end(ui)

	// State dot.
	p.div(ui, "w-6 shrink-0 flex-row items-center justify-center")
	p.div(ui, p.concat(ui, "size-1.5 rounded-full ", state_tone(r.state, selected)))
	p.end(ui)
	p.end(ui)
}

cell :: proc(ui: ^p.Ctx, w: f32, right: bool) {
	idx := p.row(ui, "h-full items-center px-2 overflow-hidden")
	if w > 0 {
		p.style(ui, idx).w = p.px(w)
		p.style(ui, idx).shrink = 0
	} else {
		p.apply(ui, "flex-1 min-w-0", idx)
	}
	if right {
		p.apply(ui, "justify-end", idx)
	}
}

user_or_uid :: proc(r: Proc_Row) -> string {
	if r.user == "" {
		return "uid?"
	}
	return r.user
}

cpu_tone :: proc(c: f32) -> string {
	switch {
	case c >= 80:
		return "text-destructive"
	case c >= 25:
		return "text-amber-600"
	}
	return "text-foreground"
}

state_tone :: proc(s: u8, selected: bool) -> string {
	if selected {
		return "bg-white/70"
	}
	switch s {
	case 'R':
		return "bg-emerald-500"
	case 'D':
		return "bg-amber-500"
	case 'Z':
		return "bg-destructive"
	case 'T', 't':
		return "bg-blue-500"
	}
	return "bg-muted-foreground/30"
}

// cmd_tail drops argv[0] when it only repeats the process name, which is the
// common case and would otherwise waste half the column.
cmd_tail :: proc(r: Proc_Row) -> string {
	if r.kernel {
		return "kernel thread"
	}
	s := r.cmd
	sp := index_of(s, " ")
	head := sp < 0 ? s : s[:sp]
	// basename
	base := head
	for i := len(head) - 1; i >= 0; i -= 1 {
		if head[i] == '/' {
			base = head[i + 1:]
			break
		}
	}
	if base == r.name || (len(r.name) == 15 && len(base) >= 15 && base[:15] == r.name) {
		return sp < 0 ? "" : s[sp + 1:]
	}
	return s
}

process_empty :: proc(ui: ^p.Ctx, m: ^Model) {
	sc.empty_open(ui, "w-full flex-1 justify-center")
	defer sc.empty_end(ui)
	sc.empty_header_open(ui)
	defer sc.empty_header_end(ui)

	if m.samples == 0 {
		sc.empty_media_icon(ui, IC_SERVER)
		sc.empty_title(ui, "Reading /proc")
		sc.empty_description(ui, "The first sample is on its way.")
		return
	}
	if len(m.filter) > 0 {
		sc.empty_media_icon(ui, IC_SEARCH)
		sc.empty_title(ui, "No process matches")
		sc.empty_description(
			ui,
			fmt.tprintf("Nothing called \"%s\" is running. Escape clears the filter.", string(m.filter[:])),
		)
		return
	}
	if !m.show_idle {
		sc.empty_media_icon(ui, IC_PAUSE)
		sc.empty_title(ui, "Nothing is using the CPU")
		sc.empty_description(ui, "Press I to show idle processes again.")
		return
	}
	sc.empty_media_icon(ui, IC_SERVER)
	sc.empty_title(ui, "No processes")
	sc.empty_description(ui, "That should not happen; /proc may not be mounted.")
}

// ---------------------------------------------------------------------------
// Bottom strip: filesystems, interfaces, sensors
// ---------------------------------------------------------------------------

strip :: proc(ui: ^p.Ctx, m: ^Model) {
	p.row(ui, "w-full shrink-0 border-t border-border bg-card")
	p.style(ui).h = p.px(STRIP_H)
	defer p.end(ui)

	disks_panel(ui, m)
	p.div(ui, "w-px h-full shrink-0 bg-border")
	p.end(ui)
	ifs_panel(ui, m)
	p.div(ui, "w-px h-full shrink-0 bg-border")
	p.end(ui)
	temps_panel(ui, m)
}

panel_open :: proc(ui: ^p.Ctx, ic: p.Icon, title: string, count: int, w: f32) {
	idx := p.col(ui, "h-full min-h-0 px-4 py-3 gap-1.5 overflow-hidden")
	if w > 0 {
		p.style(ui, idx).w = p.px(w)
		p.style(ui, idx).shrink = 0
	} else {
		p.apply(ui, "flex-1 min-w-0", idx)
	}

	p.row(ui, "w-full shrink-0 items-center gap-2")
	p.icon(ui, ic, "size-3.5 shrink-0 text-muted-foreground")
	p.text(ui, title, LABEL)
	p.textf(ui, "text-[11] font-medium text-muted-foreground/70", "%d", count)
	p.end(ui)
}

disks_panel :: proc(ui: ^p.Ctx, m: ^Model) {
	panel_open(ui, IC_HARD_DRIVE, "Filesystems", len(m.disks), 0)
	defer p.end(ui)

	if len(m.disks) == 0 {
		p.text(ui, "No block devices mounted", "text-xs text-muted-foreground")
		return
	}
	shown := min(len(m.disks), 3)
	for d in m.disks[:shown] {
		p.key(ui, d.mount)
		p.row(ui, "w-full h-[26] shrink-0 items-center gap-3")
		defer p.end(ui)

		p.text(ui, d.mount, "w-[92] shrink-0 text-xs font-medium truncate")
		p.text(ui, d.fstype, "w-[46] shrink-0 text-[10] uppercase tracking-wide text-muted-foreground")
		p.text(ui, d.source, "w-[132] shrink-0 text-[11] font-mono text-muted-foreground truncate")
		// Subvolumes and bind mounts share a device and therefore share these
		// figures; naming them is more honest than repeating the row.
		p.text(
			ui,
			d.extra == "" ? "" : fmt.tprintf("also %s", d.extra),
			"w-[150] shrink-0 text-[10] text-muted-foreground/70 truncate",
		)

		if !d.ok {
			p.text(ui, "did not answer statvfs", "flex-1 text-[11] text-amber-600")
			continue
		}
		used := d.total - d.free
		frac := f32(pct(used, d.total) / 100)
		p.div(ui, "flex-1 min-w-[60] h-1.5 rounded-full bg-muted overflow-hidden flex-row")
		{
			p.div(ui, p.concat(ui, "h-full rounded-full ", frac > 0.9 ? "bg-destructive" : (frac > 0.75 ? "bg-amber-500" : "bg-blue-600")))
			p.style(ui).w = p.pct(clamp(frac, 0, 1) * 100)
			p.end(ui)
		}
		p.end(ui)
		p.text(
			ui,
			fmt.tprintf("%s free of %s", fmt_bytes(d.free), fmt_bytes(d.total)),
			"w-[168] shrink-0 text-[11] text-muted-foreground text-right whitespace-nowrap",
		)
		p.textf(ui, "w-[40] shrink-0 text-[11] font-semibold text-right tabular-nums", "%.0f%%", pct(used, d.total))
	}
	if len(m.disks) > shown {
		p.textf(ui, "text-[11] text-muted-foreground", "+%d more mounted", len(m.disks) - shown)
	}
}

ifs_panel :: proc(ui: ^p.Ctx, m: ^Model) {
	live := 0
	for i in 0 ..< m.net.n {
		if m.net.ifs[i].name != "lo" {
			live += 1
		}
	}
	panel_open(ui, IC_NETWORK, "Interfaces", live, 330)
	defer p.end(ui)

	shown := 0
	for i in 0 ..< m.net.n {
		e := m.net.ifs[i]
		if e.name == "lo" || shown >= 3 {
			continue
		}
		shown += 1
		p.key(ui, e.name)
		p.row(ui, "w-full h-[26] shrink-0 items-center gap-2")
		defer p.end(ui)

		p.div(ui, p.concat(ui, "size-1.5 shrink-0 rounded-full ", e.up ? "bg-emerald-500" : "bg-muted-foreground/30"))
		p.end(ui)
		p.text(ui, e.name, "w-[66] shrink-0 text-xs font-medium truncate")
		if !e.up {
			p.text(ui, "down", "flex-1 text-[11] text-muted-foreground")
			continue
		}
		p.row(ui, "flex-1 min-w-0 items-center gap-1")
		p.icon(ui, IC_ARROW_DOWN, "size-3 shrink-0 text-emerald-600")
		p.text(ui, fmt_rate(e.rx_rate), "flex-1 min-w-0 text-[11] tabular-nums truncate")
		p.end(ui)
		p.row(ui, "flex-1 min-w-0 items-center gap-1")
		p.icon(ui, IC_ARROW_UP, "size-3 shrink-0 text-sky-600")
		p.text(ui, fmt_rate(e.tx_rate), "flex-1 min-w-0 text-[11] tabular-nums truncate")
		p.end(ui)
	}
	if shown == 0 {
		p.text(ui, "No interfaces up", "text-xs text-muted-foreground")
	}
}

temps_panel :: proc(ui: ^p.Ctx, m: ^Model) {
	panel_open(ui, IC_THERMOMETER, "Sensors", len(m.temps), 300)
	defer p.end(ui)

	if len(m.temps) == 0 {
		p.text(
			ui,
			temps_busy() ? "Reading hwmon…" : "No hwmon sensors exposed",
			"text-xs text-muted-foreground",
		)
		return
	}
	shown := min(len(m.temps), 3)
	for t in m.temps[:shown] {
		p.key(ui, fmt.tprintf("%s-%s", t.chip, t.label))
		p.row(ui, "w-full h-[26] shrink-0 items-center gap-2")
		defer p.end(ui)
		p.text(ui, t.label, "flex-1 min-w-0 text-xs truncate")
		p.text(ui, t.chip, "shrink-0 text-[10] text-muted-foreground/70 whitespace-nowrap max-w-[72] truncate")
		p.textf(
			ui,
			p.concat(ui, "w-[56] shrink-0 text-xs font-semibold text-right tabular-nums ", temp_tone(t)),
			"%.0f °C",
			t.c,
		)
	}
	p.row(ui, "w-full items-center gap-1.5")
	defer p.end(ui)
	if len(m.temps) > shown {
		p.textf(ui, "text-[11] text-muted-foreground", "+%d more", len(m.temps) - shown)
	}
	p.div(ui, "flex-1")
	p.end(ui)
	// Sensors read slowly on purpose; say so rather than implying 1 Hz.
	p.text(
		ui,
		temps_busy() ? "reading…" : fmt.tprintf("%.0fs ago", g_now - m.temps_at),
		"shrink-0 text-[10] text-muted-foreground/70 whitespace-nowrap",
	)
}

temp_tone :: proc(t: Temp) -> string {
	limit := t.crit > 0 ? t.crit : 95
	switch {
	case t.c >= limit * 0.92:
		return "text-destructive"
	case t.c >= limit * 0.78:
		return "text-amber-600"
	}
	return "text-foreground"
}

// ---------------------------------------------------------------------------
// Footer
// ---------------------------------------------------------------------------

footer :: proc(ui: ^p.Ctx, m: ^Model, v: View) {
	p.row(ui, "w-full shrink-0 items-center gap-3 px-4 bg-card border-t border-border")
	p.style(ui).h = p.px(FOOTER_H)
	defer p.end(ui)

	hint(ui, "/", "", "filter")
	hint(ui, "C", "M", "sort")
	hint(ui, "Left", "Right", "column")
	hint(ui, "R", "", "reverse")
	hint(ui, "D", "", "details")
	hint(ui, "Space", "", "pause")
	hint(ui, "?", "", "keys")

	p.div(ui, "flex-1 min-w-0")
	p.end(ui)

	if m.toast_len > 0 && g_now < m.toast_until {
		p.row(ui, "shrink-0 items-center gap-1.5 mr-3")
		p.icon(ui, IC_CHECK, "size-3 shrink-0 text-emerald-600")
		p.text(ui, string(m.toast[:m.toast_len]), "text-[11] text-muted-foreground whitespace-nowrap")
		p.end(ui)
	}

	// What the sample cost. A monitor that cannot say what it costs to run is
	// hiding the one number that matters about itself.
	p.text(
		ui,
		fmt.tprintf(
			"sample %d · %.1f ms (%.1f ms in /proc/<pid>) · %.0f fps",
			m.samples,
			m.sample_ms,
			m.proc_ms,
			p.frames_per_second(ui),
		),
		"shrink-0 text-[11] font-mono text-muted-foreground/80 whitespace-nowrap",
	)
	_ = v
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

detail_overlay :: proc(ui: ^p.Ctx, m: ^Model, v: View) {
	s := scrim(ui, "bg-foreground/25", 60)
	if p.clickable(ui, s) {
		m.detail_open = false
	}

	vp := p.size(ui)
	W :: f32(620)
	idx := p.col(
		ui,
		"rounded-xl bg-popover ring-1 ring-foreground/10 shadow-2xl overflow-hidden",
	)
	st := p.style(ui, idx)
	st.position = .Absolute
	st.inset[p.LEFT] = p.px(max(8, (vp.x - W) / 2))
	st.inset[p.TOP] = p.px(max(8, vp.y * 0.18))
	st.w = p.px(W)
	st.z = 70
	defer p.end(ui)

	p.row(ui, "w-full shrink-0 items-center gap-2 px-4 h-12 border-b border-border")
	p.icon(ui, IC_SERVER, "size-4 shrink-0 text-muted-foreground")
	p.text(ui, "Process detail", "text-sm font-semibold shrink-0")
	p.div(ui, "flex-1")
	p.end(ui)
	sc.kbd(ui, "Esc")
	p.end(ui)

	if v.sel < 0 {
		p.col(ui, "w-full p-6")
		p.text(ui, "Nothing selected.", "text-sm text-muted-foreground")
		p.end(ui)
		return
	}

	r := m.procs[v.sel]
	p.col(ui, "w-full p-5 gap-3")
	defer p.end(ui)

	p.row(ui, "w-full items-center gap-3")
	{
		p.div(ui, "size-10 shrink-0 flex-row items-center justify-center rounded-xl bg-blue-600 text-white")
		p.icon(ui, r.kernel ? IC_MICROCHIP : IC_BOXES, "size-5 shrink-0")
		p.end(ui)
		p.col(ui, "flex-1 min-w-0 gap-0.5")
		p.text(ui, r.name, "text-base font-semibold tracking-tight truncate")
		p.textf(ui, "text-xs text-muted-foreground truncate", "pid %d · parent %d · %s", r.pid, r.ppid, state_label(r.state))
		p.end(ui)
		if r.kernel {
			sc.badge(ui, "kernel thread", .Secondary)
		}
	}
	p.end(ui)

	sc.separator(ui)

	p.row(ui, "w-full gap-6")
	{
		p.col(ui, "flex-1 min-w-0 gap-1.5")
		kv(ui, "CPU", fmt.tprintf("%.2f %% of one core", r.cpu))
		kv(ui, "Resident", fmt_bytes(r.rss))
		kv(ui, "Virtual", fmt_bytes(r.vsz))
		kv(ui, "Threads", fmt.tprintf("%d", r.threads))
		p.end(ui)
		p.col(ui, "flex-1 min-w-0 gap-1.5")
		kv(ui, "User", user_or_uid(r))
		kv(ui, "Nice", fmt.tprintf("%d", r.nice))
		kv(ui, "CPU time", fmt.tprintf("%.1f s", f64(r.ticks) / g_hz))
		kv(ui, "State", fmt.tprintf("%c · %s", rune(r.state), state_label(r.state)))
		p.end(ui)
	}
	p.end(ui)

	sc.separator(ui)

	p.text(ui, "COMMAND LINE", LABEL)
	p.div(ui, "w-full rounded-lg bg-muted px-3 py-2")
	p.text(ui, r.cmd, "text-[11] font-mono leading-relaxed")
	p.end(ui)

	p.text(
		ui,
		"This monitor reads only. There is no signal, renice or kill here — a destructive action driven from a synthetic-input demo script is not worth the risk.",
		"text-[11] text-muted-foreground leading-relaxed",
	)
}

kv :: proc(ui: ^p.Ctx, k, val: string) {
	p.row(ui, "w-full shrink-0 items-baseline gap-3")
	defer p.end(ui)
	p.text(ui, k, "w-[76] shrink-0 text-xs text-muted-foreground")
	p.text(ui, val, "flex-1 min-w-0 text-xs font-medium truncate")
}

help_overlay :: proc(ui: ^p.Ctx, m: ^Model) {
	s := scrim(ui, "bg-foreground/25", 80)
	if p.clickable(ui, s) {
		m.help_open = false
	}

	vp := p.size(ui)
	W :: f32(540)
	idx := p.col(ui, "rounded-xl bg-popover ring-1 ring-foreground/10 shadow-2xl overflow-hidden")
	st := p.style(ui, idx)
	st.position = .Absolute
	st.inset[p.LEFT] = p.px(max(8, (vp.x - W) / 2))
	st.inset[p.TOP] = p.px(max(8, vp.y * 0.16))
	st.w = p.px(W)
	st.z = 90
	defer p.end(ui)

	p.row(ui, "w-full shrink-0 items-center gap-2 px-4 h-12 border-b border-border")
	p.icon(ui, IC_SEARCH, "size-4 shrink-0 text-muted-foreground")
	p.text(ui, "Keyboard", "text-sm font-semibold shrink-0")
	p.div(ui, "flex-1")
	p.end(ui)
	sc.kbd(ui, "Esc")
	p.end(ui)

	p.col(ui, "w-full p-4 gap-1.5")
	defer p.end(ui)

	rows := [?][2]string {
		{"/  or  Ctrl F", "Filter the process list"},
		{"Esc", "Close an overlay, clear the filter, drop focus"},
		{"Up Down PgUp PgDn Home End", "Move the selection"},
		{"Left Right", "Previous or next sort column"},
		{"C M P N T U", "Sort by CPU, memory, pid, name, threads, user"},
		{"R", "Reverse the sort direction"},
		{"K", "Show or hide kernel threads"},
		{"I", "Show or hide processes using no CPU"},
		{"D", "Open the detail panel for the selection; D or Esc closes it"},
		{"Space", "Pause and resume sampling"},
		{"Ctrl Q", "Quit"},
	}
	for r in rows {
		p.row(ui, "w-full shrink-0 items-center gap-3 h-7")
		p.text(ui, r[0], "w-[190] shrink-0 text-[11] font-mono text-foreground")
		p.text(ui, r[1], "flex-1 min-w-0 text-xs text-muted-foreground truncate")
		p.end(ui)
	}

	sc.separator(ui)
	p.text(
		ui,
		"Every figure is read from /proc and /sys directly. No subprocess runs, and nothing here can change the system.",
		"text-[11] text-muted-foreground leading-relaxed",
	)
}
