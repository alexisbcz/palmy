package main

// The interface.

import "core:fmt"
import "core:strings"
import kit "kit:."
import p "palmy:."
import sc "shadcn:."

WIN_W :: 1160
WIN_H :: 880

LABEL ::
	"shrink-0 text-[11] font-semibold uppercase tracking-wider text-muted-foreground whitespace-nowrap"

start_window :: proc() -> (^p.App, string) {
	return kit.start(
		{
			title = "Power & Session",
			width = WIN_W,
			height = WIN_H,
			min_width = 940,
			min_height = 660,
			root_class = "w-full h-full bg-background text-foreground",
			// Uptime and the per-core frequencies move every second, so this
			// window asks for a frame every vsync.
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
		left(ui, m)
		p.div(ui, "w-px h-full shrink-0 bg-border")
		p.end(ui)
		right(ui, m)
	}
	p.end(ui)

	footer(ui, m)

	if m.log_open {
		log_overlay(ui, m)
	}
	if m.help_open {
		help_overlay(ui, m)
	}
	if m.confirm {
		confirm_overlay(ui, m)
	}
}

// ---------------------------------------------------------------------------
// Header
// ---------------------------------------------------------------------------

header :: proc(ui: ^p.Ctx, m: ^Model) {
	p.row(ui, "w-full shrink-0 items-center gap-4 px-5 bg-card border-b border-border")
	p.style(ui).h = p.px(HEADER_H)
	defer p.end(ui)

	p.div(ui, "size-12 shrink-0 flex-row items-center justify-center rounded-[16] bg-blue-600 text-white")
	p.icon(ui, IC_POWER, "size-6 shrink-0")
	p.end(ui)

	p.col(ui, "w-[320] shrink-0 gap-1")
	{
		p.row(ui, "items-center gap-2")
		p.text(ui, m.host.hostname, "text-[17] font-semibold tracking-tight whitespace-nowrap")
		p.style(ui).shrink = 0
		sc.badge(ui, chassis_label(m.host.chassis), .Secondary)
		p.end(ui)
		p.text(
			ui,
			m.host.distro == "" \
			? fmt.tprintf("Linux %s", m.host.kernel) \
			: fmt.tprintf("%s · Linux %s", m.host.distro, m.host.kernel),
			"text-xs text-muted-foreground truncate",
		)
	}
	p.end(ui)

	p.div(ui, "w-px h-12 shrink-0 bg-border")
	p.end(ui)

	p.row(ui, "flex-1 min-w-0 items-center gap-5")
	{
		stat(ui, IC_CLOCK, "Uptime", fmt_uptime(m.up), fmt.tprintf("booted %s", boot_label(m.btime)))
		stat(
			ui,
			IC_CPU,
			"CPU clock",
			fmt_ghz(cpufreq_avg(m.freq)),
			m.freq.present \
			? fmt.tprintf("%s · %s", m.freq.governor, m.freq.driver) \
			: "no cpufreq driver",
		)
		stat(
			ui,
			IC_THERMOMETER,
			"Package",
			package_temp(m),
			len(m.temps) == 0 ? "reading hwmon…" : fmt.tprintf("%d sensors", len(m.temps)),
		)
		stat(
			ui,
			IC_USERS,
			"Sessions",
			fmt.tprintf("%d", len(m.sessions)),
			active_session_label(m),
		)
	}
	p.end(ui)
}

stat :: proc(ui: ^p.Ctx, ic: p.Icon, label, value, sub: string) {
	p.col(ui, "flex-1 min-w-0 gap-0.5")
	defer p.end(ui)
	p.row(ui, "items-center gap-1.5")
	p.icon(ui, ic, "size-3 shrink-0 text-muted-foreground")
	p.text(ui, label, LABEL)
	p.end(ui)
	p.text(ui, value, "text-[19] font-semibold tracking-tight truncate tabular-nums")
	p.text(ui, sub, "text-[11] text-muted-foreground truncate")
}

// package_temp picks the sensor a person means by "the CPU temperature":
// k10temp's Tctl on AMD, falling back to the hottest thing found.
package_temp :: proc(m: ^Model) -> string {
	if len(m.temps) == 0 {
		return "—"
	}
	for t in m.temps {
		if t.chip == "k10temp" || t.chip == "coretemp" {
			return fmt.tprintf("%.0f °C", t.c)
		}
	}
	hottest := m.temps[0]
	for t in m.temps {
		if t.c > hottest.c {
			hottest = t
		}
	}
	return fmt.tprintf("%.0f °C", hottest.c)
}

active_session_label :: proc(m: ^Model) -> string {
	for s in m.sessions {
		if s.active {
			return fmt.tprintf("%s on %s, %s", s.user, s.seat == "" ? "no seat" : s.seat, s.type_)
		}
	}
	return m.loaded ? "none active" : "reading loginctl…"
}

// ---------------------------------------------------------------------------
// Left: what is actually true about this machine's power
// ---------------------------------------------------------------------------

left :: proc(ui: ^p.Ctx, m: ^Model) {
	p.col(ui, "flex-1 min-w-0 h-full min-h-0 p-4 gap-3.5 overflow-hidden")
	defer p.end(ui)

	sessions_card(ui, m)
	cpu_card(ui, m)
	thermal_card(ui, m)
}

card_open :: proc(ui: ^p.Ctx, class := "") -> int {
	idx := p.col(ui, "w-full shrink-0 rounded-xl border border-border bg-card p-4 gap-2.5 overflow-hidden")
	p.apply(ui, class, idx)
	return idx
}

card_head :: proc(ui: ^p.Ctx, ic: p.Icon, title: string, right_text: string) {
	p.row(ui, "w-full shrink-0 items-center gap-2")
	defer p.end(ui)
	p.icon(ui, ic, "size-3.5 shrink-0 text-muted-foreground")
	p.text(ui, title, LABEL)
	p.div(ui, "flex-1 min-w-0")
	p.end(ui)
	if right_text != "" {
		p.text(ui, right_text, "shrink-0 text-[11] text-muted-foreground whitespace-nowrap")
	}
}

sessions_card :: proc(ui: ^p.Ctx, m: ^Model) {
	card_open(ui)
	defer p.end(ui)
	card_head(ui, IC_USERS, "Logged in", "loginctl list-sessions")

	if len(m.sessions) == 0 {
		p.text(
			ui,
			m.loaded ? "loginctl reported no sessions" : "Reading…",
			"text-xs text-muted-foreground",
		)
		return
	}
	for s in m.sessions {
		p.key(ui, s.id)
		p.row(ui, "w-full h-[44] shrink-0 items-center gap-3")
		defer p.end(ui)

		p.div(
			ui,
			p.concat(
				ui,
				"size-8 shrink-0 flex-row items-center justify-center rounded-[10] ",
				s.active ? "bg-blue-600 text-white" : "bg-muted text-muted-foreground",
			),
		)
		p.icon(ui, s.class == "manager" ? IC_TERMINAL : IC_USERS, "size-4 shrink-0")
		p.end(ui)

		p.col(ui, "w-[200] shrink-0 gap-0.5")
		p.row(ui, "items-center gap-1.5")
		p.textf(ui, "text-xs font-medium whitespace-nowrap", "%s · session %s", s.user, s.id)
		p.style(ui).shrink = 0
		p.end(ui)
		p.text(
			ui,
			fmt.tprintf(
				"%s%s · %s",
				s.class,
				s.type_ == "" ? "" : fmt.tprintf(" · %s", s.type_),
				s.service == "" ? "no service" : s.service,
			),
			"text-[11] text-muted-foreground truncate",
		)
		p.end(ui)

		p.row(ui, "flex-1 min-w-0 items-center gap-1.5 flex-wrap")
		if s.active {
			sc.badge_icon(ui, "Active", IC_CHECK, .Default)
		} else {
			sc.badge(ui, s.state == "" ? "inactive" : s.state, .Outline)
		}
		if s.seat != "" {
			sc.badge(ui, s.seat, .Secondary)
		}
		if s.tty != "" {
			sc.badge(ui, s.tty, .Outline)
		}
		if s.locked {
			sc.badge_icon(ui, "Locked", IC_LOCK, .Secondary)
		}
		if s.idle {
			sc.badge_icon(ui, "Idle", IC_HOURGLASS, .Secondary)
		}
		p.end(ui)

		p.text(
			ui,
			s.since,
			"w-[210] shrink-0 text-[11] text-muted-foreground text-right truncate",
		)
	}
}

cpu_card :: proc(ui: ^p.Ctx, m: ^Model) {
	card_open(ui, "flex-1 min-h-0")
	defer p.end(ui)
	card_head(
		ui,
		IC_CPU,
		"Processor power",
		m.freq.present ? "/sys/devices/system/cpu/cpu*/cpufreq" : "",
	)

	if !m.freq.present {
		p.text(ui, "This kernel exposes no cpufreq policy.", "text-xs text-muted-foreground")
		return
	}

	p.row(ui, "w-full shrink-0 items-center gap-2 flex-wrap")
	{
		sc.badge_icon(ui, m.freq.governor, IC_GAUGE, .Default)
		sc.badge(ui, m.freq.driver, .Secondary)
		if m.freq.epp != "" {
			sc.badge(ui, fmt.tprintf("EPP %s", m.freq.epp), .Outline)
		}
		if m.freq.boost >= 0 {
			sc.badge_icon(
				ui,
				m.freq.boost == 1 ? "Boost on" : "Boost off",
				IC_ZAP,
				m.freq.boost == 1 ? .Secondary : .Outline,
			)
		}
		if m.freq.mixed {
			sc.badge_icon(ui, "Governors differ per core", IC_TRIANGLE_ALERT, .Destructive)
		}
	}
	p.end(ui)

	p.text(ui, m.host.cpu_model, "w-full text-xs text-muted-foreground truncate")

	// Per core, as a bar between the policy's own min and max.
	lo := f64(m.freq.min_khz)
	hi := f64(max(m.freq.max_khz, m.freq.hw_max_khz))
	p.row(ui, "w-full flex-1 min-h-[52] shrink-0 items-end gap-1")
	{
		for i in 0 ..< m.freq.n {
			f := hi > lo ? clamp((f64(m.freq.cur[i]) - lo) / (hi - lo), 0, 1) : 0
			p.div(ui, "flex-1 min-w-[8] h-full flex-col justify-end rounded-[3] bg-muted overflow-hidden")
			{
				p.div(ui, p.concat(ui, "w-full rounded-[3] ", freq_tone(f32(f))))
				p.style(ui).h = p.pct(f32(max(f, 0.03)) * 100)
				p.end(ui)
			}
			p.end(ui)
		}
	}
	p.end(ui)

	p.row(ui, "w-full shrink-0 items-baseline gap-5")
	{
		kv(ui, "Average", fmt_ghz(cpufreq_avg(m.freq)))
		kv(ui, "Policy range", fmt.tprintf("%s – %s", fmt_ghz(m.freq.min_khz), fmt_ghz(m.freq.max_khz)))
		kv(ui, "Hardware max", fmt_ghz(m.freq.hw_max_khz))
		kv(ui, "Cores", fmt.tprintf("%d", m.freq.n))
	}
	p.end(ui)
}

freq_tone :: proc(f: f32) -> string {
	switch {
	case f >= 0.85:
		return "bg-amber-500"
	case f >= 0.4:
		return "bg-blue-600"
	}
	return "bg-blue-600/40"
}

kv :: proc(ui: ^p.Ctx, k, v: string) {
	p.col(ui, "flex-1 min-w-0 gap-0.5")
	defer p.end(ui)
	p.text(ui, k, "text-[10] uppercase tracking-wide text-muted-foreground whitespace-nowrap")
	p.text(ui, v, "text-xs font-medium truncate tabular-nums")
}

thermal_card :: proc(ui: ^p.Ctx, m: ^Model) {
	card_open(ui)
	defer p.end(ui)
	card_head(
		ui,
		IC_THERMOMETER,
		"Thermal",
		len(m.temps) == 0 \
		? "" \
		: fmt.tprintf("hwmon · read %.0fs ago, off the frame thread", g_now - m.temps_at),
	)

	if len(m.temps) == 0 {
		p.text(
			ui,
			temps_busy() ? "Reading hwmon…" : "No hwmon sensors exposed",
			"text-xs text-muted-foreground",
		)
		return
	}

	shown := min(len(m.temps), 4)
	for t in m.temps[:shown] {
		p.key(ui, fmt.tprintf("%s-%s", t.chip, t.label))
		p.row(ui, "w-full h-[26] shrink-0 items-center gap-3")
		defer p.end(ui)
		p.text(ui, t.label, "w-[150] shrink-0 text-xs truncate")
		p.text(ui, t.chip, "w-[80] shrink-0 text-[10] text-muted-foreground/70 truncate")

		limit := t.crit > 0 ? t.crit : 95
		f := clamp(t.c / limit, 0, 1)
		p.div(ui, "flex-1 min-w-[80] h-1.5 rounded-full bg-muted overflow-hidden flex-row")
		{
			p.div(ui, p.concat(ui, "h-full rounded-full ", temp_tone(t)))
			p.style(ui).w = p.pct(f * 100)
			p.end(ui)
		}
		p.end(ui)

		p.text(
			ui,
			t.crit > 0 ? fmt.tprintf("crit %.0f", t.crit) : "",
			"w-[58] shrink-0 text-[10] text-muted-foreground text-right whitespace-nowrap",
		)
		p.textf(
			ui,
			p.concat(ui, "w-[56] shrink-0 text-xs font-semibold text-right tabular-nums ", temp_tone_text(t)),
			"%.0f °C",
			t.c,
		)
	}
	if len(m.temps) > shown {
		p.textf(ui, "text-[11] text-muted-foreground", "+%d more sensors", len(m.temps) - shown)
	}
}

temp_tone :: proc(t: Temp) -> string {
	limit := t.crit > 0 ? t.crit : 95
	switch {
	case t.c >= limit * 0.92:
		return "bg-destructive"
	case t.c >= limit * 0.78:
		return "bg-amber-500"
	}
	return "bg-blue-600"
}

temp_tone_text :: proc(t: Temp) -> string {
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
// Right: the power supply truth, and the session actions
// ---------------------------------------------------------------------------

right :: proc(ui: ^p.Ctx, m: ^Model) {
	p.col(ui, "shrink-0 h-full min-h-0 bg-sidebar p-4 gap-3.5 overflow-hidden")
	p.style(ui).w = p.px(RIGHT_W)
	defer p.end(ui)

	supply_card(ui, m)
	actions_card(ui, m)
}

supply_card :: proc(ui: ^p.Ctx, m: ^Model) {
	card_open(ui)
	defer p.end(ui)
	card_head(ui, IC_BATTERY_WARNING, "Power supply", "")

	if len(m.supplies) == 0 {
		// The finding, stated as a finding.
		p.row(ui, "w-full shrink-0 items-start gap-2.5 rounded-lg bg-muted p-3")
		{
			p.icon(ui, IC_INFO, "size-4 shrink-0 text-muted-foreground mt-0.5")
			p.col(ui, "flex-1 min-w-0 gap-1")
			p.text(ui, "No battery on this machine", "text-xs font-medium")
			p.text(
				ui,
				fmt.tprintf(
					"/sys/class/power_supply is empty and DMI calls this a %s. There is nothing to gauge, so no gauge is drawn.",
					chassis_label(m.host.chassis),
				),
				"w-full text-[11] leading-relaxed text-muted-foreground",
			)
			p.end(ui)
		}
		p.end(ui)
	} else {
		for s in m.supplies {
			p.key(ui, s.name)
			p.row(ui, "w-full h-[32] shrink-0 items-center gap-2")
			defer p.end(ui)
			p.text(ui, s.name, "flex-1 min-w-0 text-xs font-medium truncate")
			p.text(ui, s.type_, "shrink-0 text-[11] text-muted-foreground")
			if s.pct >= 0 {
				p.textf(ui, "w-[42] shrink-0 text-xs font-semibold text-right", "%d%%", s.pct)
			}
		}
	}

	sc.separator(ui)

	// What upower does see. A Bluetooth headset is not a system power supply,
	// but its charge is a real reading and worth showing.
	p.row(ui, "w-full shrink-0 items-center gap-2")
	p.text(ui, "upower --dump", "shrink-0 text-[10] font-mono text-muted-foreground")
	p.div(ui, "flex-1")
	p.end(ui)
	if m.upower.version != "" {
		p.text(ui, fmt.tprintf("v%s", m.upower.version), "shrink-0 text-[10] text-muted-foreground")
	}
	p.end(ui)

	if !m.upower.ok {
		p.text(ui, "upower is not installed or did not answer", "text-[11] text-muted-foreground")
		return
	}
	real := 0
	for d in m.upower.devs {
		if d.pct < 0 || d.kind == "unknown" {
			continue
		}
		real += 1
		p.key(ui, d.path)
		p.row(ui, "w-full h-[34] shrink-0 items-center gap-2.5")
		defer p.end(ui)
		p.div(ui, "size-7 shrink-0 flex-row items-center justify-center rounded-lg bg-muted text-muted-foreground")
		p.icon(ui, d.kind == "headset" ? IC_HEADPHONES : IC_ZAP, "size-3.5 shrink-0")
		p.end(ui)
		p.col(ui, "flex-1 min-w-0 gap-0.5")
		p.text(ui, d.model == "" ? d.path : d.model, "text-xs font-medium truncate")
		p.text(
			ui,
			fmt.tprintf("%s · not a system supply", d.kind == "" ? "device" : d.kind),
			"text-[10] text-muted-foreground truncate",
		)
		p.end(ui)
		p.textf(
			ui,
			p.concat(
				ui,
				"shrink-0 text-sm font-semibold tabular-nums ",
				d.pct <= 20 ? "text-amber-600" : "text-foreground",
			),
			"%d%%",
			d.pct,
		)
	}
	if real == 0 {
		p.text(
			ui,
			"upower reports no device with a charge level.",
			"text-[11] text-muted-foreground",
		)
	}
	p.row(ui, "w-full shrink-0 items-center gap-3 pt-0.5")
	flag(ui, "on battery", m.upower.on_battery)
	flag(ui, "lid present", m.upower.lid_present)
	p.text(
		ui,
		m.upower.crit_action == "" ? "" : fmt.tprintf("critical: %s", m.upower.crit_action),
		"flex-1 text-[10] text-muted-foreground text-right truncate",
	)
	p.end(ui)
}

flag :: proc(ui: ^p.Ctx, label: string, on: bool) {
	p.row(ui, "shrink-0 items-center gap-1.5")
	defer p.end(ui)
	p.div(ui, p.concat(ui, "size-1.5 shrink-0 rounded-full ", on ? "bg-emerald-500" : "bg-muted-foreground/30"))
	p.end(ui)
	p.text(ui, label, "text-[10] text-muted-foreground whitespace-nowrap")
	p.style(ui).shrink = 0
}

actions_card :: proc(ui: ^p.Ctx, m: ^Model) {
	card_open(ui, "flex-1 min-h-0 gap-2")
	defer p.end(ui)

	p.row(ui, "w-full shrink-0 items-center gap-2")
	p.icon(ui, IC_POWER, "size-3.5 shrink-0 text-muted-foreground")
	p.text(ui, "Session", LABEL)
	p.div(ui, "flex-1")
	p.end(ui)
	sc.badge_icon(ui, "Stubbed", IC_BAN, .Destructive)
	p.end(ui)

	// The warning sits above the buttons, not under them, because somebody
	// reading this list should know before they press anything.
	p.row(ui, "w-full shrink-0 items-start gap-2.5 rounded-lg border border-amber-500/30 bg-amber-500/10 p-3")
	{
		p.icon(ui, IC_SHIELD_ALERT, "size-4 shrink-0 text-amber-600 mt-0.5")
		p.col(ui, "flex-1 min-w-0 gap-1")
		p.text(ui, "None of these run", "text-xs font-medium text-amber-700")
		p.text(
			ui,
			"Each one logs the command it would have issued and does nothing else. A demo script driving this window with synthetic input must not be able to reboot a machine.",
			"w-full text-[11] leading-relaxed text-amber-700/90",
		)
		p.end(ui)
	}
	p.end(ui)

	for a in Action {
		action_row(ui, m, a)
	}
}

action_row :: proc(ui: ^p.Ctx, m: ^Model, a: Action) {
	info := ACTIONS[a]
	sel := m.sel == a
	p.key(ui, info.label)
	idx := p.row(ui, "w-full h-[44] shrink-0 items-center gap-2.5 px-3 rounded-xl transition duration-120")
	p.apply(
		ui,
		sel ? (info.severe ? "bg-destructive text-white" : "bg-blue-600 text-white") : "hover:bg-accent",
		idx,
	)
	defer p.end(ui)
	if p.clickable(ui, idx) {
		arm(m, a)
	}

	dim := sel ? "text-white/75" : "text-muted-foreground"
	tile := sel \
		? "bg-white/20 text-white" \
		: (info.severe ? "bg-destructive/10 text-destructive" : "bg-muted text-muted-foreground")
	p.div(ui, p.concat(ui, "size-8 shrink-0 flex-row items-center justify-center rounded-[10] ", tile))
	p.icon(ui, info.icon, "size-4 shrink-0")
	p.end(ui)

	p.col(ui, "flex-1 min-w-0 gap-0.5")
	p.text(ui, info.label, "text-sm font-medium truncate")
	p.text(ui, info.cmd, p.concat(ui, "text-[10] font-mono truncate ", dim))
	p.end(ui)

	sc.kbd(ui, info.key)
	if sel {
		sc.kbd(ui, "Enter")
	}
}

// ---------------------------------------------------------------------------
// Footer
// ---------------------------------------------------------------------------

footer :: proc(ui: ^p.Ctx, m: ^Model) {
	p.row(ui, "w-full shrink-0 items-center gap-3 px-4 bg-card border-t border-border")
	p.style(ui).h = p.px(FOOTER_H)
	defer p.end(ui)

	hint(ui, "Up", "Down", "choose")
	hint(ui, "Enter", "", "confirm")
	hint(ui, "L", "O", "lock, log out")
	hint(ui, "S", "B", "suspend, restart")
	hint(ui, "P", "", "shut down")
	hint(ui, "C", "", "intents")
	hint(ui, "R", "", "refresh")

	p.div(ui, "flex-1 min-w-0")
	p.end(ui)

	if m.toast_len > 0 && g_now < m.toast_until {
		p.row(ui, "shrink-0 items-center gap-1.5 max-w-[620]")
		defer p.end(ui)
		p.icon(ui, IC_BAN, "size-3.5 shrink-0 text-amber-600")
		p.text(ui, string(m.toast[:m.toast_len]), "text-[11] text-muted-foreground truncate")
		return
	}

	p.text(
		ui,
		fmt.tprintf(
			"%d intent(s) logged, 0 executed · %.1f / %.1f ms",
			g_log_count,
			m.fast_ms,
			m.slow_ms,
		),
		"shrink-0 text-[11] font-mono text-muted-foreground/80 whitespace-nowrap",
	)
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

confirm_overlay :: proc(ui: ^p.Ctx, m: ^Model) {
	s := scrim(ui, "bg-foreground/30", 80)
	if p.clickable(ui, s) {
		m.confirm = false
	}

	info := ACTIONS[m.sel]
	idx := panel(ui, 480, 0.26, 90)
	p.apply(ui, "p-5 gap-4", idx)
	defer p.end(ui)

	p.row(ui, "w-full items-start gap-3")
	{
		p.div(
			ui,
			p.concat(
				ui,
				"size-10 shrink-0 flex-row items-center justify-center rounded-xl ",
				info.severe ? "bg-destructive/10 text-destructive" : "bg-blue-600/10 text-blue-600",
			),
		)
		p.icon(ui, info.icon, "size-5 shrink-0")
		p.end(ui)

		p.col(ui, "flex-1 min-w-0 gap-1.5")
		p.textf(ui, "text-base font-semibold tracking-tight", "%s?", info.label)
		p.text(ui, info.desc, "w-full text-xs leading-relaxed text-muted-foreground")
		p.end(ui)
	}
	p.end(ui)

	// The dialog repeats the stub warning, because this is the last screen
	// before the button and the only one somebody in a hurry will read.
	p.col(ui, "w-full rounded-lg border border-amber-500/30 bg-amber-500/10 p-3 gap-1.5")
	{
		p.row(ui, "w-full items-center gap-2")
		p.icon(ui, IC_BAN, "size-3.5 shrink-0 text-amber-600")
		p.text(ui, "This will not actually happen", "text-xs font-medium text-amber-700")
		p.end(ui)
		p.text(
			ui,
			"Confirming writes one line to the applet's log and returns. The command below is never executed.",
			"w-full text-[11] leading-relaxed text-amber-700/90",
		)
		p.div(ui, "w-full rounded-md bg-background/70 px-2.5 py-1.5")
		p.text(ui, fmt.tprintf("$ %s", info.cmd), "text-[11] font-mono")
		p.end(ui)
	}
	p.end(ui)

	p.row(ui, "w-full items-center justify-end gap-2")
	defer p.end(ui)
	if dialog_button(ui, "Cancel", .Outline, m.confirm_sel == 0) {
		m.confirm = false
	}
	if dialog_button(
		ui,
		fmt.tprintf("Log %s", strings.to_lower(info.label, context.temp_allocator)),
		info.severe ? .Destructive : .Default,
		m.confirm_sel == 1,
	) {
		m.confirm = false
		perform(m, m.sel)
	}
}

dialog_button :: proc(ui: ^p.Ctx, label: string, v: sc.Variant, armed: bool) -> bool {
	at := p.node_count(ui)
	hovered := p.hovered(ui, p.node_id(ui, at))
	idx := sc.button_open(ui, v, .Default, sc.State{hover = hovered, focus = armed})
	defer sc.button_end(ui)
	p.apply(ui, "px-3.5", idx)
	p.text(ui, label, "whitespace-nowrap")
	p.style(ui).shrink = 0
	return p.clickable(ui, idx)
}

log_overlay :: proc(ui: ^p.Ctx, m: ^Model) {
	s := scrim(ui, "bg-foreground/25", 60)
	if p.clickable(ui, s) {
		m.log_open = false
	}
	panel(ui, 640, 0.2, 70)
	defer p.end(ui)

	p.row(ui, "w-full shrink-0 items-center gap-2 px-4 h-12 border-b border-border")
	p.icon(ui, IC_TERMINAL, "size-4 shrink-0 text-muted-foreground")
	p.text(ui, "Intents logged", "text-sm font-semibold shrink-0")
	p.textf(ui, "flex-1 text-xs text-muted-foreground", "%d · none executed", g_log_count)
	sc.kbd(ui, "Esc")
	p.end(ui)

	p.col(ui, "w-full shrink-0 p-3 gap-1")
	defer p.end(ui)
	entries := log_recent(10)
	if len(entries) == 0 {
		p.text(
			ui,
			"Nothing yet. Pick an action and confirm it; the command it would have run lands here.",
			"w-full text-xs text-muted-foreground leading-relaxed",
		)
		return
	}
	for e, i in entries {
		p.key(ui, fmt.tprintf("%d-%s", i, e.cmd))
		p.row(ui, "w-full h-8 shrink-0 items-center gap-2.5 px-2 rounded-md")
		p.icon(ui, IC_BAN, "size-3 shrink-0 text-amber-600")
		p.text(ui, e.when_, "w-[66] shrink-0 text-[11] font-mono text-muted-foreground")
		p.text(ui, e.cmd, "flex-1 min-w-0 text-xs font-mono truncate")
		p.text(ui, "not run", "shrink-0 text-[11] text-muted-foreground whitespace-nowrap")
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
	p.icon(ui, IC_POWER, "size-4 shrink-0 text-muted-foreground")
	p.text(ui, "Keyboard", "text-sm font-semibold shrink-0")
	p.div(ui, "flex-1")
	p.end(ui)
	sc.kbd(ui, "Esc")
	p.end(ui)

	p.col(ui, "w-full p-4 gap-1.5")
	defer p.end(ui)
	rows := [?][2]string {
		{"Up Down", "Choose a session action"},
		{"Enter / Space", "Open its confirmation"},
		{"L O S B P", "Lock, log out, suspend, restart, shut down"},
		{"Left Right", "Move between Cancel and the action"},
		{"Esc", "Cancel"},
		{"C", "Every intent this applet has logged"},
		{"R", "Re-read sessions, cpufreq, upower and sensors"},
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
		"There is no battery gauge because this machine has no battery: /sys/class/power_supply is empty. Everything shown is read from /proc, /sys, loginctl or upower.",
		"w-full text-[11] text-muted-foreground leading-relaxed",
	)
}
