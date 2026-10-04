package main

// The interface. One procedure per region, all of it rebuilt every frame from
// whatever `bluetoothctl` last told us.

import "core:fmt"
import "core:math"
import p "palmy:."
import sc "shadcn:."

// palmy's own text field ships a dark skin; this is the shadcn input dressed
// over it, the same way the showcase does.
FIELD_SKIN ::
	"h-8 rounded-lg border border-input bg-background text-foreground " +
	"text-sm px-2.5 focus:border-ring focus:ring-3 focus:ring-ring/50"

ROW_H :: "h-14"

kind_icon :: proc(k: Kind) -> p.Icon {
	switch k {
	case .Headphones:
		return IC_HEADPHONES
	case .Headset:
		return IC_HEADPHONES
	case .Speaker:
		return IC_SPEAKER
	case .Keyboard:
		return IC_KEYBOARD
	case .Mouse:
		return IC_MOUSE
	case .Gamepad:
		return IC_GAMEPAD_2
	case .Phone:
		return IC_SMARTPHONE
	case .Computer:
		return IC_LAPTOP
	case .Tablet:
		return IC_TABLET
	case .Watch:
		return IC_WATCH
	case .Display:
		return IC_MONITOR
	case .Printer:
		return IC_PRINTER
	case .Car:
		return IC_CAR
	case .Network:
		return IC_RSS
	case .Generic:
		return IC_BLUETOOTH
	}
	return IC_BLUETOOTH
}

// ---------------------------------------------------------------------------
// The frame
// ---------------------------------------------------------------------------

build :: proc(ui: ^p.Ctx, m: ^Model, v: View) {
	p.col(ui, "w-full h-full bg-background text-foreground")
	defer p.end(ui)

	header(ui, m)

	p.row(ui, "w-full flex-1 min-h-0")
	{
		left_pane(ui, m, v)
		p.div(ui, "w-px h-full shrink-0 bg-border")
		p.end(ui)
		detail_pane(ui, m, v)
	}
	p.end(ui)

	footer(ui, m, v)

	// There is no xdg_popup, so overlays are absolutely positioned children of
	// the window itself, lifted above the flow with `z`.
	if m.menu_open {
		menu_overlay(ui, m, v)
	}
	if m.log_open {
		log_overlay(ui, m)
	}
	if m.confirm != .None {
		confirm_overlay(ui, m, v)
	}
}

// ---------------------------------------------------------------------------
// Header: the adapter
// ---------------------------------------------------------------------------

header :: proc(ui: ^p.Ctx, m: ^Model) {
	a := m.adapter
	p.row(ui, "w-full h-[78] shrink-0 items-center gap-3.5 px-5 bg-card border-b border-border")
	defer p.end(ui)

	// The glyph carries the adapter's state on its own: filled blue when the
	// radio is up, hollow when it is not.
	p.div(ui, "size-11 shrink-0 flex-row items-center justify-center rounded-[14]")
	p.apply(
		ui,
		a.powered \
		? "bg-blue-600 text-white" \
		: (a.soft_block || a.hard_block ? "bg-destructive/10 text-destructive" : "bg-muted text-muted-foreground"),
	)
	p.icon(ui, adapter_icon(m), "size-5 shrink-0")
	p.end(ui)

	p.col(ui, "flex-1 min-w-0 gap-1")
	{
		p.row(ui, "items-center gap-2")
		p.text(ui, "Bluetooth", "text-[17] font-semibold tracking-tight whitespace-nowrap")
		p.style(ui).shrink = 0
		if a.present {
			sc.badge(ui, a.alias == "" ? "adapter" : a.alias, .Secondary)
		}
		p.end(ui)

		p.row(ui, "items-center gap-2 min-w-0")
		{
			dot_class := a.powered ? "bg-emerald-500" : "bg-neutral-400"
			if a.soft_block || a.hard_block {
				dot_class = "bg-destructive"
			}
			p.div(ui, p.concat(ui, "size-1.5 shrink-0 rounded-full ", dot_class))
			p.end(ui)
			p.text(ui, adapter_status(m), "text-xs text-muted-foreground whitespace-nowrap")
			p.style(ui).shrink = 0
			if a.present {
				p.text(ui, "·", "text-xs text-muted-foreground")
				p.style(ui).shrink = 0
				p.text(ui, a.addr, "text-xs font-mono text-muted-foreground whitespace-nowrap")
				p.style(ui).shrink = 0
			}
		}
		p.end(ui)
	}
	p.end(ui)

	// Two controls, both reachable with Tab and with a one-key shortcut.
	if switch_cell(ui, "Discoverable", "D", a.discoverable, a.powered && !job_busy()) {
		toggle_discoverable(m)
		p.redraw(ui)
	}
	if switch_cell(ui, "Bluetooth", "P", a.powered, !a.hard_block && !job_busy()) {
		toggle_power(m)
		p.redraw(ui)
	}
}

adapter_icon :: proc(m: ^Model) -> p.Icon {
	if m.adapter.soft_block || m.adapter.hard_block || !m.adapter.powered {
		return IC_BLUETOOTH_OFF
	}
	if m.scanning || m.adapter.discovering {
		return IC_BLUETOOTH_SEARCHING
	}
	return IC_BLUETOOTH
}

adapter_status :: proc(m: ^Model) -> string {
	a := m.adapter
	switch {
	case !a.present:
		return "No adapter found"
	case a.hard_block:
		return "Hard blocked by hardware switch"
	case a.soft_block:
		return "Soft blocked by rfkill"
	case !a.powered:
		return "Off"
	case m.scanning || a.discovering:
		return "On · Scanning"
	case a.discoverable:
		return "On · Discoverable"
	}
	return "On · Not discoverable"
}

// switch_cell is a labelled shadcn switch that joins the Tab order.
switch_cell :: proc(ui: ^p.Ctx, label, hint: string, on, enabled: bool) -> bool {
	idx := p.row(
		ui,
		"shrink-0 items-center gap-2.5 h-10 px-3 rounded-lg hover:bg-accent transition duration-120 cursor-pointer",
	)
	defer p.end(ui)
	if enabled {
		p.focusable(ui, idx)
	}
	p.text(ui, label, "text-xs font-medium whitespace-nowrap")
	p.style(ui).shrink = 0
	sc.switch_(ui, on, .Default, sc.State{focus = p.focused(ui, idx), disabled = !enabled})
	sc.kbd(ui, hint)
	return enabled && p.activated(ui, idx)
}

// ---------------------------------------------------------------------------
// Left pane: the device lists
// ---------------------------------------------------------------------------

left_pane :: proc(ui: ^p.Ctx, m: ^Model, v: View) {
	p.col(ui, "flex-1 min-w-0 h-full")
	defer p.end(ui)

	toolbar(ui, m, v)

	p.col(ui, "w-full flex-1 min-h-0 px-3 py-2.5 gap-0.5 overflow-hidden")
	defer p.end(ui)

	// Paired devices.
	section_label(ui, "My Devices", len(v.paired))
	if len(v.paired) == 0 {
		hint_line(ui, len(m.filter) > 0 ? "No paired device matches the filter" : "No paired devices")
	}
	lo := m.p_top
	hi := min(len(v.paired), lo + m.vis_p)
	for k in lo ..< hi {
		di := v.paired[k]
		if device_row(ui, m, m.devices[di], di == v.sel) {
			set_sel(m, m.devices[di].addr)
			p.redraw(ui)
		}
	}
	overflow_line(ui, len(v.paired), lo, hi)

	// Nearby devices.
	p.div(ui, "h-2 shrink-0")
	p.end(ui)
	nearby_label(ui, m, v)
	if len(v.nearby) == 0 {
		nearby_empty(ui, m)
	}
	nlo := m.n_top
	nhi := min(len(v.nearby), nlo + m.vis_n)
	for k in nlo ..< nhi {
		di := v.nearby[k]
		if device_row(ui, m, m.devices[di], di == v.sel) {
			set_sel(m, m.devices[di].addr)
			p.redraw(ui)
		}
	}
	overflow_line(ui, len(v.nearby), nlo, nhi)
}

toolbar :: proc(ui: ^p.Ctx, m: ^Model, v: View) {
	p.row(ui, "w-full h-[54] shrink-0 items-center gap-2.5 px-4 border-b border-border")
	defer p.end(ui)

	p.icon(ui, sc.ICON_SEARCH, "size-4 shrink-0 text-muted-foreground")
	at := p.node_count(ui)
	p.text_field(ui, &m.filter, "Filter by name or address", FIELD_SKIN + " flex-1 min-w-0")
	m.filter_focus = p.focused(ui, at)

	// Scan: the one command that takes real time, so it owns the spinner.
	scanning := m.scanning
	si := p.node_count(ui)
	hovered := p.hovered(ui, p.node_id(ui, si))
	sc.button_open(
		ui,
		scanning ? .Secondary : .Outline,
		.Default,
		sc.State {
			hover = hovered && !scanning,
			focus = p.focused(ui),
			disabled = scanning || job_busy() || !m.adapter.powered,
		},
	)
	p.apply(ui, "shrink-0 w-[110] justify-center")
	p.focusable(ui)
	act := p.activated(ui)
	if scanning {
		spinner(ui, m, "size-3.5 shrink-0")
		p.text(ui, "Scanning", "whitespace-nowrap")
		p.style(ui).shrink = 0
	} else {
		p.icon(ui, IC_REFRESH_CW, "size-3.5 shrink-0")
		p.text(ui, "Scan", "whitespace-nowrap")
		p.style(ui).shrink = 0
		sc.kbd(ui, "S")
	}
	sc.button_end(ui)
	if act {
		start_scan(m)
		p.redraw(ui)
	}
	_ = v
}

section_label :: proc(ui: ^p.Ctx, label: string, count: int) {
	p.row(ui, "w-full h-7 shrink-0 items-center gap-2 px-2")
	defer p.end(ui)
	p.text(
		ui,
		label,
		"text-[11] font-semibold uppercase tracking-wider text-muted-foreground whitespace-nowrap",
	)
	p.style(ui).shrink = 0
	p.textf(ui, "text-[11] font-medium text-muted-foreground/70", "%d", count)
	p.style(ui).shrink = 0
}

nearby_label :: proc(ui: ^p.Ctx, m: ^Model, v: View) {
	p.row(ui, "w-full h-7 shrink-0 items-center gap-2 px-2")
	defer p.end(ui)
	p.text(
		ui,
		"Nearby Devices",
		"text-[11] font-semibold uppercase tracking-wider text-muted-foreground whitespace-nowrap",
	)
	p.style(ui).shrink = 0
	p.textf(ui, "text-[11] font-medium text-muted-foreground/70", "%d", len(v.nearby))
	p.style(ui).shrink = 0
	p.div(ui, "flex-1")
	p.end(ui)
	if m.scanning {
		p.row(ui, "shrink-0 items-center gap-1.5")
		spinner(ui, m, "size-3 shrink-0")
		p.text(ui, "Listening for advertisements", "text-[11] text-blue-600 whitespace-nowrap")
		p.style(ui).shrink = 0
		p.end(ui)
	}
}

hint_line :: proc(ui: ^p.Ctx, s: string) {
	p.row(ui, "w-full h-9 shrink-0 items-center px-3")
	defer p.end(ui)
	p.text(ui, s, "text-xs text-muted-foreground")
}

// overflow_line stands in for a scrollbar: palmy only scrolls from the wheel,
// so the lists are windowed by hand and say how much is off-screen.
overflow_line :: proc(ui: ^p.Ctx, total, lo, hi: int) {
	if total <= hi - lo {
		return
	}
	p.row(ui, "w-full h-6 shrink-0 items-center gap-1.5 px-3")
	defer p.end(ui)
	p.icon(ui, IC_ELLIPSIS, "size-3 shrink-0 text-muted-foreground")
	p.textf(
		ui,
		"text-[11] text-muted-foreground whitespace-nowrap",
		"showing %d-%d of %d",
		lo + 1,
		hi,
		total,
	)
	p.style(ui).shrink = 0
}

nearby_empty :: proc(ui: ^p.Ctx, m: ^Model) {
	sc.empty_open(ui, "shrink-0 py-5 gap-3")
	defer sc.empty_end(ui)
	sc.empty_header_open(ui)
	defer sc.empty_header_end(ui)

	if m.scanning {
		p.div(ui, "mb-2 flex-row size-8 shrink-0 items-center justify-center rounded-lg bg-muted")
		spinner(ui, m, "size-4 shrink-0")
		p.end(ui)
		sc.empty_title(ui, "Scanning")
		sc.empty_description(ui, "Nothing has advertised yet. This takes a few seconds.")
		return
	}
	if !m.adapter.powered {
		sc.empty_media_icon(ui, IC_BLUETOOTH_OFF)
		sc.empty_title(ui, "Bluetooth is off")
		sc.empty_description(ui, "Turn the radio on to look for devices nearby.")
		return
	}
	if len(m.filter) > 0 {
		sc.empty_media_icon(ui, sc.ICON_SEARCH)
		sc.empty_title(ui, "No match")
		sc.empty_description(ui, "No nearby device matches that filter.")
		return
	}
	sc.empty_media_icon(ui, IC_BLUETOOTH_SEARCHING)
	sc.empty_title(ui, "No devices found")
	sc.empty_description(
		ui,
		"BlueZ forgets unpaired devices once discovery stops. Press S to scan again.",
	)
}

// ---------------------------------------------------------------------------
// A device row
// ---------------------------------------------------------------------------

device_row :: proc(ui: ^p.Ctx, m: ^Model, d: Device, selected: bool) -> (clicked: bool) {
	p.key(ui, d.addr)
	idx := p.row(
		ui,
		"w-full " +
		ROW_H +
		" shrink-0 items-center gap-3 px-3 rounded-[10] transition duration-120 cursor-pointer",
	)
	defer p.end(ui)
	p.apply(ui, selected ? "bg-blue-600 text-white" : "hover:bg-accent", idx)
	clicked = p.clickable(ui, idx)
	if selected {
		m.sel_row_id = p.node_id(ui, idx)
	}

	// Icon tile.
	p.div(ui, "size-9 shrink-0 flex-row items-center justify-center rounded-[10]")
	p.apply(
		ui,
		selected \
		? "bg-white/20 text-white" \
		: (d.connected ? "bg-blue-600 text-white" : "bg-muted text-muted-foreground"),
	)
	p.icon(ui, kind_icon(d.kind), "size-[18] shrink-0")
	p.end(ui)

	// Name and subtitle.
	name, named := display_name(d)
	p.col(ui, "flex-1 min-w-0 gap-0.5")
	{
		p.text(ui, name, p.concat(ui, "text-sm truncate ", named ? "font-medium" : "italic"))
		sub := row_subtitle(d)
		p.text(
			ui,
			sub,
			selected ? "text-xs text-white/75 truncate" : "text-xs text-muted-foreground truncate",
		)
	}
	p.end(ui)

	// Trailing status.
	p.row(ui, "shrink-0 items-center gap-2.5")
	defer p.end(ui)

	if d.battery >= 0 {
		battery_chip(ui, d.battery, selected)
	}
	if d.paired {
		if d.connected {
			p.row(ui, "items-center gap-1.5 shrink-0")
			p.div(ui, p.concat(ui, "size-1.5 rounded-full ", selected ? "bg-white" : "bg-emerald-500"))
			p.end(ui)
			p.text(
				ui,
				"Connected",
				selected ? "text-xs font-medium whitespace-nowrap" : "text-xs font-medium text-emerald-700 whitespace-nowrap",
			)
			p.style(ui).shrink = 0
			p.end(ui)
		} else {
			p.text(
				ui,
				"Not connected",
				selected ? "text-xs text-white/75 whitespace-nowrap" : "text-xs text-muted-foreground whitespace-nowrap",
			)
			p.style(ui).shrink = 0
		}
	} else if d.has_rssi {
		p.row(ui, "items-center gap-2 shrink-0")
		p.textf(
			ui,
			selected ? "text-[11] font-mono text-white/75 whitespace-nowrap" : "text-[11] font-mono text-muted-foreground whitespace-nowrap",
			"%d dBm",
			d.rssi,
		)
		p.style(ui).shrink = 0
		signal_bars(ui, bars_for_rssi(d.rssi), selected, d.rssi_old)
		p.end(ui)
	} else {
		p.text(
			ui,
			"advertising",
			selected ? "text-[11] text-white/75 whitespace-nowrap" : "text-[11] text-muted-foreground whitespace-nowrap",
		)
		p.style(ui).shrink = 0
	}

	if selected {
		p.icon(ui, IC_CHEVRON_RIGHT, "size-4 shrink-0 text-white/70")
	}
	return
}

row_subtitle :: proc(d: Device) -> string {
	if d.paired {
		parts := kind_label(d.kind)
		if d.trusted {
			return fmt.tprintf("%s · %s · Trusted", parts, d.addr)
		}
		return fmt.tprintf("%s · %s", parts, d.addr)
	}
	if d.has_class || d.icon_name != "" {
		return fmt.tprintf("%s · %s", d.addr, kind_label(d.kind))
	}
	return fmt.tprintf("%s · Low Energy", d.addr)
}

signal_bars :: proc(ui: ^p.Ctx, n: int, selected: bool, stale := false) {
	p.row(ui, "items-end gap-0.5 h-3.5 shrink-0")
	defer p.end(ui)
	heights := [4]string{"h-1.5", "h-2", "h-2.5", "h-3.5"}
	on := selected ? "bg-white" : (stale ? "bg-foreground/35" : "bg-foreground/70")
	off := selected ? "bg-white/30" : "bg-foreground/15"
	for i in 0 ..< 4 {
		p.div(ui, p.concat(ui, "w-[3] shrink-0 rounded-full ", heights[i], " ", i < n ? on : off))
		p.end(ui)
	}
}

battery_chip :: proc(ui: ^p.Ctx, pct: int, selected: bool) {
	ic := IC_BATTERY_FULL
	tone := selected ? "text-white" : "text-emerald-700"
	switch {
	case pct <= 15:
		ic = IC_BATTERY_WARNING
		tone = selected ? "text-white" : "text-destructive"
	case pct <= 40:
		ic = IC_BATTERY_LOW
		tone = selected ? "text-white" : "text-amber-600"
	case pct <= 75:
		ic = IC_BATTERY_MEDIUM
	}
	p.row(ui, p.concat(ui, "items-center gap-1 shrink-0 ", tone))
	defer p.end(ui)
	p.icon(ui, ic, "size-4 shrink-0")
	p.textf(ui, "text-[11] font-medium whitespace-nowrap", "%d%%", pct)
	p.style(ui).shrink = 0
}

// ---------------------------------------------------------------------------
// Right pane: one device in full
// ---------------------------------------------------------------------------

detail_pane :: proc(ui: ^p.Ctx, m: ^Model, v: View) {
	// The inspector keeps its proportion on a wide window rather than leaving
	// the device rows stretched across the whole display.
	vp := p.size(ui)
	idx := p.col(ui, "shrink-0 h-full bg-sidebar overflow-hidden")
	p.style(ui, idx).w = p.px(clamp(vp.x * 0.32, 392, 560))
	defer p.end(ui)

	if v.sel < 0 {
		p.col(ui, "w-full h-full items-center justify-center p-8")
		defer p.end(ui)
		sc.empty_open(ui)
		sc.empty_header_open(ui)
		sc.empty_media_icon(ui, IC_BLUETOOTH)
		sc.empty_title(ui, "No device selected")
		sc.empty_description(ui, "Scan for devices, then use Up and Down to pick one.")
		sc.empty_header_end(ui)
		sc.empty_end(ui)
		return
	}

	d := m.devices[v.sel]
	name, _ := display_name(d)

	p.col(ui, "w-full flex-1 min-h-0 p-5 gap-4 overflow-hidden")
	defer p.end(ui)

	// Hero.
	p.row(ui, "w-full shrink-0 items-center gap-3.5")
	{
		p.div(ui, "size-14 shrink-0 flex-row items-center justify-center rounded-2xl")
		p.apply(ui, d.connected ? "bg-blue-600 text-white" : "bg-muted text-muted-foreground")
		p.icon(ui, kind_icon(d.kind), "size-7 shrink-0")
		p.end(ui)

		p.col(ui, "flex-1 min-w-0 gap-1")
		p.text(ui, name, "text-base font-semibold tracking-tight truncate")
		p.text(ui, class_label(d), "text-xs text-muted-foreground truncate")
		p.end(ui)
	}
	p.end(ui)

	// Flags, as badges.
	p.row(ui, "w-full shrink-0 flex-wrap gap-1.5")
	{
		if d.connected {
			sc.badge_icon(ui, "Connected", IC_CIRCLE_CHECK, .Default)
		} else {
			sc.badge(ui, "Not connected", .Outline)
		}
		if d.paired {
			sc.badge_icon(ui, d.bonded ? "Paired · Bonded" : "Paired", IC_LOCK, .Secondary)
		} else {
			sc.badge(ui, "Not paired", .Outline)
		}
		if d.trusted {
			sc.badge_icon(ui, "Trusted", IC_SHIELD_CHECK, .Secondary)
		}
		if d.blocked {
			sc.badge(ui, "Blocked", .Destructive)
		}
		if !d.reachable {
			sc.badge(ui, "Out of range", .Outline)
		}
	}
	p.end(ui)

	// Actions, where macOS puts them: directly under the device they act on.
	p.row(ui, "w-full shrink-0 items-center gap-2 pt-0.5")
	{
		label := d.connected ? "Disconnect" : "Connect"
		ic := d.connected ? IC_LINK_2_OFF : IC_LINK_2
		live := m.adapter.powered && !job_busy()
		if action_button(ui, label, ic, live, d.connected ? .Secondary : .Default) {
			run_action(m, d.connected ? .Disconnect : .Connect, v)
			p.redraw(ui)
		}
		if !d.paired {
			if action_button(ui, "Pair", IC_PLUS, live, .Outline) {
				run_action(m, .Pair, v)
				p.redraw(ui)
			}
		} else if !d.trusted {
			if action_button(ui, "Trust", IC_SHIELD_CHECK, live, .Outline) {
				run_action(m, .Trust, v)
				p.redraw(ui)
			}
		}
		p.div(ui, "flex-1")
		p.end(ui)
		if action_button(ui, "", IC_ELLIPSIS, true, .Outline, icon_only = true) {
			open_menu(m, v)
			p.redraw(ui)
		}
	}
	p.end(ui)

	sc.separator(ui)

	// Status, one line per BlueZ property so nothing is implied.
	panel_label(ui, "Status")
	p.col(ui, "w-full shrink-0 gap-1.5")
	{
		flag_row(ui, "Connected", d.connected)
		flag_row(ui, "Paired", d.paired)
		flag_row(ui, "Trusted", d.trusted)
		flag_row(ui, "Blocked", d.blocked, invert = true)
	}
	p.end(ui)

	sc.separator(ui)

	panel_label(ui, "Device")
	p.col(ui, "w-full shrink-0 gap-1.5")
	{
		kv(ui, "Address", d.addr, mono = true)
		kv(ui, "Address type", d.addr_type == "" ? "unknown" : d.addr_type)
		kv(ui, "Type", kind_label(d.kind))
		if d.has_class {
			kv(ui, "Class", fmt.tprintf("0x%08x", d.class), mono = true)
		}
		if d.battery >= 0 {
			kv(ui, "Battery", fmt.tprintf("%d%%", d.battery))
		} else {
			kv(ui, "Battery", "Not reported", dim = true)
		}
		if d.has_rssi {
			kv(ui, "Signal", fmt.tprintf("%d dBm", d.rssi), mono = true)
		}
		if d.has_tx {
			kv(ui, "Tx power", fmt.tprintf("%d dBm", d.tx_power), mono = true)
		}
		if d.services > 0 {
			kv(ui, "Services", fmt.tprintf("%d profiles", d.services))
		}
		if d.modalias != "" {
			kv(ui, "Modalias", d.modalias, mono = true)
		}
	}
	p.end(ui)

	p.div(ui, "flex-1 min-h-0")
	p.end(ui)

	// A tall window has room for the activity feed. Every line in it was
	// executed against the real adapter, in that order.
	if m.tall {
		recent := log_recent(5)
		if len(recent) > 0 {
			sc.separator(ui)
			panel_label(ui, "Recent commands")
			p.col(ui, "w-full shrink-0 gap-1")
			defer p.end(ui)
			for e, i in recent {
				p.key(ui, fmt.tprintf("rc%d", i))
				p.row(ui, "w-full shrink-0 items-center gap-1.5")
				p.icon(
					ui,
					e.ok ? IC_CHECK : IC_X,
					p.concat(ui, "size-3 shrink-0 ", e.ok ? "text-emerald-600" : "text-destructive"),
				)
				p.text(ui, e.cmd, "flex-1 min-w-0 text-[11] font-mono text-muted-foreground truncate")
				p.end(ui)
			}
		}
	}
}

panel_label :: proc(ui: ^p.Ctx, s: string) {
	p.text(
		ui,
		s,
		"shrink-0 text-[11] font-semibold uppercase tracking-wider text-muted-foreground",
	)
}

kv :: proc(ui: ^p.Ctx, k, val: string, mono := false, dim := false) {
	p.row(ui, "w-full shrink-0 items-baseline gap-3")
	defer p.end(ui)
	p.text(ui, k, "w-[104] shrink-0 text-xs text-muted-foreground")
	p.text(
		ui,
		val,
		p.concat(
			ui,
			"flex-1 min-w-0 text-xs truncate ",
			mono ? "font-mono " : "",
			dim ? "text-muted-foreground" : "text-foreground",
		),
	)
}

flag_row :: proc(ui: ^p.Ctx, label: string, on: bool, invert := false) {
	good := invert ? !on : on
	p.row(ui, "w-full shrink-0 items-center gap-2")
	defer p.end(ui)
	p.icon(
		ui,
		on ? IC_CIRCLE_CHECK : IC_X,
		p.concat(
			ui,
			"size-3.5 shrink-0 ",
			good ? (on ? "text-emerald-600" : "text-muted-foreground") : "text-amber-600",
		),
	)
	p.text(ui, label, "flex-1 min-w-0 text-xs truncate")
	p.text(
		ui,
		on ? "yes" : "no",
		p.concat(ui, "shrink-0 text-xs font-medium ", on ? "text-foreground" : "text-muted-foreground"),
	)
}

action_button :: proc(
	ui: ^p.Ctx,
	label: string,
	ic: p.Icon,
	enabled: bool,
	variant: sc.Variant,
	icon_only := false,
) -> bool {
	at := p.node_count(ui)
	hovered := p.hovered(ui, p.node_id(ui, at))
	sc.button_open(
		ui,
		variant,
		icon_only ? .Icon : .Default,
		sc.State{hover = hovered && enabled, focus = p.focused(ui), disabled = !enabled},
	)
	defer sc.button_end(ui)
	if enabled {
		p.focusable(ui)
	}
	p.icon(ui, ic, "size-3.5 shrink-0")
	if label != "" {
		p.text(ui, label, "whitespace-nowrap")
		p.style(ui).shrink = 0
	}
	return enabled && p.activated(ui)
}

// ---------------------------------------------------------------------------
// Footer
// ---------------------------------------------------------------------------

footer :: proc(ui: ^p.Ctx, m: ^Model, v: View) {
	p.row(ui, "w-full h-[46] shrink-0 items-center gap-3 px-4 bg-card border-t border-border")
	defer p.end(ui)

	hint(ui, "Up", "Down", "select")
	hint(ui, "Enter", "", "actions")
	hint(ui, "S", "", "scan")
	hint(ui, "R", "", "refresh")
	hint(ui, "L", "", "log")

	p.div(ui, "flex-1 min-w-0")
	p.end(ui)

	// What the applet last did, verbatim.
	if job_busy() && m.busy_len > 0 {
		p.row(ui, "shrink-0 items-center gap-2")
		defer p.end(ui)
		spinner(ui, m, "size-3.5 shrink-0")
		p.text(
			ui,
			string(m.busy_label[:m.busy_len]),
			"text-xs text-blue-600 font-medium whitespace-nowrap",
		)
		p.style(ui).shrink = 0
		return
	}
	if m.toast_len > 0 && g_now < m.toast_until {
		p.row(ui, "shrink-0 items-center gap-2 max-w-[520]")
		defer p.end(ui)
		p.icon(
			ui,
			m.toast_bad ? IC_BATTERY_WARNING : IC_CIRCLE_CHECK,
			p.concat(ui, "size-3.5 shrink-0 ", m.toast_bad ? "text-destructive" : "text-emerald-600"),
		)
		p.text(
			ui,
			toast_text(m),
			p.concat(
				ui,
				"text-xs truncate ",
				m.toast_bad ? "text-destructive" : "text-muted-foreground",
			),
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
	_ = v
}

hint :: proc(ui: ^p.Ctx, a, b, label: string) {
	p.row(ui, "shrink-0 items-center gap-1.5")
	defer p.end(ui)
	sc.kbd(ui, a)
	if b != "" {
		sc.kbd(ui, b)
	}
	p.text(ui, label, "text-[11] text-muted-foreground whitespace-nowrap")
	p.style(ui).shrink = 0
}

// ---------------------------------------------------------------------------
// Overlays. palmy has no xdg_popup, so these are absolutely positioned inside
// the window and lifted with `z`.
// ---------------------------------------------------------------------------

MENU_W :: 216

menu_overlay :: proc(ui: ^p.Ctx, m: ^Model, v: View) {
	items := menu_items(m, v)
	if len(items) == 0 {
		m.menu_open = false
		return
	}

	// A scrim, so the menu reads as a layer above the panel and a click
	// anywhere else dismisses it.
	scrim := p.div(ui, "bg-foreground/10")
	sst := p.style(ui, scrim)
	sst.position = .Absolute
	sst.inset = {p.px(0), p.px(0), p.px(0), p.px(0)}
	sst.z = 40
	if p.clickable(ui, scrim) {
		m.menu_open = false
		p.redraw(ui)
	}
	p.end(ui)

	vp := p.size(ui)
	anchor := p.rect_of(ui, m.sel_row_id)
	seps := 0
	for it in items {
		if it.sep {seps += 1}
	}
	// Estimated height: the label row, one 28px row per item, a 9px rule for
	// each separator, and the popup's own padding.
	mh := 30 + f32(len(items)) * 28 + f32(seps) * 9 + 10

	x := anchor.w > 0 ? anchor.x + 44 : 24
	y := anchor.h > 0 ? anchor.y + anchor.h - 8 : 96
	x = clamp(x, 8, max(8, vp.x - MENU_W - 8))
	y = clamp(y, 8, max(8, vp.y - mh - f32(FOOTER_H) - 8))

	idx := sc.menu_content_open(ui)
	st := p.style(ui, idx)
	st.position = .Absolute
	st.inset[p.LEFT] = p.px(x)
	st.inset[p.TOP] = p.px(y)
	st.w = p.px(MENU_W)
	st.z = 50
	p.apply(ui, "shadow-lg", idx)
	defer p.end(ui)

	d := m.devices[v.sel]
	name, _ := display_name(d)
	sc.menu_label(ui, name)

	for it, i in items {
		if it.sep {
			sc.menu_separator(ui)
		}
		p.key(ui, it.label)
		ii := sc.menu_item_open(ui)
		p.apply(ui, "h-7 px-2 gap-2 shrink-0", ii)
		if i == m.menu_sel && it.enabled {
			p.apply(ui, "bg-blue-600 text-white", ii)
		}
		if !it.enabled {
			p.apply(ui, "opacity-40", ii)
		} else {
			p.apply(ui, "hover:bg-accent cursor-pointer", ii)
			if p.clickable(ui, ii) {
				run_action(m, it.act, v)
				m.menu_open = false
				p.redraw(ui)
			}
		}
		if it.has_icon {
			p.icon(ui, it.icon, "size-3.5 shrink-0")
		}
		sc.menu_item_text(ui, it.label)
		if it.hint != "" {
			sc.menu_shortcut(ui, it.hint)
			if i == m.menu_sel && it.enabled {
				p.apply(ui, "text-white/70")
			}
		}
		p.end(ui)
	}
}

// confirm_overlay is the one place this applet stops and asks. Connecting,
// pairing and trusting all add something and run straight away; taking a live
// connection away does not.
confirm_overlay :: proc(ui: ^p.Ctx, m: ^Model, v: View) {
	scrim := p.div(ui, "bg-foreground/30")
	sst := p.style(ui, scrim)
	sst.position = .Absolute
	sst.inset = {p.px(0), p.px(0), p.px(0), p.px(0)}
	sst.z = 80
	if p.clickable(ui, scrim) {
		m.confirm = .None
		p.redraw(ui)
	}
	p.end(ui)

	title, body, verb: string
	switch m.confirm {
	case .Disconnect:
		name := "this device"
		if v.sel >= 0 {
			name, _ = display_name(m.devices[v.sel])
		}
		title = "Disconnect?"
		body = fmt.tprintf(
			"%s will stop playing through this machine. It stays paired and trusted, so it can reconnect.",
			name,
		)
		verb = "Disconnect"
	case .Power:
		title = "Turn Bluetooth off?"
		body = "A device is connected. Turning the radio off will drop it."
		verb = "Turn off"
	case .None, .Scan, .Connect, .Pair, .Trust, .Copy, .Discoverable:
		title = "Are you sure?"
		body = ""
		verb = "Continue"
	}

	vp := p.size(ui)
	W :: 420.0
	idx := sc.alert_dialog_content_open(ui)
	st := p.style(ui, idx)
	st.position = .Absolute
	st.inset[p.LEFT] = p.px(max(8, (vp.x - W) / 2))
	st.inset[p.TOP] = p.px(max(8, vp.y * 0.30))
	st.w = p.px(W)
	st.z = 90
	p.apply(ui, "shadow-2xl", idx)
	defer p.end(ui)

	p.row(ui, "w-full items-start gap-3")
	sc.alert_dialog_media(ui, IC_LINK_2_OFF)
	sc.alert_dialog_header_open(ui, false)
	sc.alert_dialog_title(ui, title)
	sc.alert_dialog_description(ui, body)
	p.end(ui)
	p.end(ui)

	p.row(ui, "w-full items-center justify-end gap-2")
	defer p.end(ui)

	if confirm_button(ui, "Cancel", .Outline, m.confirm_sel == 0) {
		m.confirm = .None
		p.redraw(ui)
	}
	if confirm_button(ui, verb, .Destructive, m.confirm_sel == 1) {
		act := m.confirm
		m.confirm = .None
		exec_action(m, act, v)
		p.redraw(ui)
	}
}

// confirm_button draws one of the dialog's two choices. `armed` is the
// keyboard's current pick, which Enter activates.
confirm_button :: proc(ui: ^p.Ctx, label: string, variant: sc.Variant, armed: bool) -> bool {
	at := p.node_count(ui)
	hovered := p.hovered(ui, p.node_id(ui, at))
	idx := sc.button_open(ui, variant, .Default, sc.State{hover = hovered, focus = armed})
	defer sc.button_end(ui)
	p.apply(ui, "px-3.5", idx)
	p.text(ui, label, "whitespace-nowrap")
	p.style(ui).shrink = 0
	return p.clickable(ui, idx)
}

log_overlay :: proc(ui: ^p.Ctx, m: ^Model) {
	scrim := p.div(ui, "bg-foreground/25")
	sst := p.style(ui, scrim)
	sst.position = .Absolute
	sst.inset = {p.px(0), p.px(0), p.px(0), p.px(0)}
	sst.z = 60
	if p.clickable(ui, scrim) {
		m.log_open = false
		p.redraw(ui)
	}
	p.end(ui)

	vp := p.size(ui)
	W :: 620.0
	idx := p.col(
		ui,
		"rounded-xl bg-popover ring-1 ring-foreground/10 shadow-2xl overflow-hidden max-h-[440]",
	)
	st := p.style(ui, idx)
	st.position = .Absolute
	st.inset[p.LEFT] = p.px(max(8, (vp.x - W) / 2))
	st.inset[p.TOP] = p.px(max(8, vp.y * 0.22))
	st.w = p.px(W)
	st.z = 70
	defer p.end(ui)

	p.row(ui, "w-full shrink-0 items-center gap-2 px-4 h-12 border-b border-border")
	p.icon(ui, sc.ICON_TERMINAL, "size-4 shrink-0 text-muted-foreground")
	p.text(ui, "Commands executed", "text-sm font-semibold shrink-0")
	p.textf(ui, "flex-1 text-xs text-muted-foreground", "%d since launch", g_log_count)
	sc.kbd(ui, "Esc")
	p.end(ui)

	p.col(ui, "w-full shrink-0 p-2 gap-0 overflow-hidden")
	defer p.end(ui)
	entries := log_recent(12)
	if len(entries) == 0 {
		hint_line(ui, "Nothing yet.")
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
		if e.note != "" {
			p.text(ui, e.note, "shrink-0 text-[11] text-muted-foreground whitespace-nowrap")
		}
		p.end(ui)
	}
}

// ---------------------------------------------------------------------------
// The spinner
//
// shadcn's spinner is a lucide arc with `animate-spin`, and palmy has no
// transforms, so this is drawn straight onto the canvas instead: eight
// capsules around a circle with a fading trail.
// ---------------------------------------------------------------------------

spinner :: proc(ui: ^p.Ctx, m: ^Model, class := "size-4") {
	m.spin.col = p.hex(0x2563eb)
	p.pixels(ui, class, &m.spin, proc(c: ^p.Canvas, r: p.Rect, s: ^Spin) {
		cx := r.x + r.w * 0.5
		cy := r.y + r.h * 0.5
		th := max(1.25 * c.scale, min(r.w, r.h) * 0.11)
		rad := min(r.w, r.h) * 0.5 - th * 0.5
		if rad <= 0 {
			return
		}
		// A 290-degree arc, drawn as short chords whose alpha ramps from the
		// tail to the head. `animate-spin` has no equivalent here, so the head
		// is advanced by the frame clock instead.
		N :: 22
		SWEEP :: f32(math.TAU) * 0.80
		head := s.t * 5.0
		prev_x := cx + math.cos(head) * rad
		prev_y := cy + math.sin(head) * rad
		for i in 1 ..= N {
			t := f32(i) / f32(N)
			a := head - SWEEP * t
			x := cx + math.cos(a) * rad
			y := cy + math.sin(a) * rad
			p.draw_line(c, prev_x, prev_y, x, y, th, p.fade(s.col, (1 - t) * 0.95 + 0.05))
			prev_x, prev_y = x, y
		}
	})
}
