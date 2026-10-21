package main

// A Bluetooth panel for Wayland, drawn by palmy's software rasterizer and
// driven entirely by `bluetoothctl` and `rfkill`.
//
// Everything on screen is read from the real adapter. Scanning runs on a
// worker thread so the window never stalls, and the only commands that change
// anything are the ones behind an explicit key press.

import "core:fmt"
import "core:math"
import "core:mem"
import "core:mem/virtual"
import "core:os"
import "core:strings"
import kit "kit:."
import p "palmy:."
import sc "shadcn:."

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

Pane :: enum {
	Paired,
	Nearby,
}

SCAN_SECS :: 9
HEADER_H :: 78
TOOLBAR_H :: 54
FOOTER_H :: 46

Model :: struct {
	arena:       virtual.Arena,
	al:          mem.Allocator,
	adapter:     Adapter,
	devices:     []Device,
	loaded:      bool,

	// Selection survives a reload by address, not by index.
	sel:         [32]u8,
	sel_len:     int,
	pane:        Pane,
	p_top:       int,
	n_top:       int,
	rows:        int, // how many list rows the window has room for
	tall:        bool, // enough height for the inspector's activity feed
	vis_p:       int,
	vis_n:       int,
	sel_row_id:  u64,

	filter:      [dynamic]u8,
	filter_focus: bool,

	menu_open:   bool,
	menu_sel:    int,
	log_open:    bool,

	// A pending action waiting for confirmation. Nothing that can take a live
	// connection away happens without passing through here.
	confirm:     Job_Kind,
	confirm_sel: int,

	scanning:    bool,
	scan_until:  f64,
	next_poll:   f64,

	toast:       [192]u8,
	toast_len:   int,
	toast_until: f64,
	toast_bad:   bool,

	spin:        Spin,
	busy_label:  [64]u8,
	busy_len:    int,
}

Spin :: struct {
	t:   f32,
	col: p.Color,
}

BLUE :: "bg-blue-600"

// The frame's clock, so `note` can time out a message without threading the
// context into every helper.
g_now: f64

main :: proc() {
	// `--shots <dir>` renders the panel offscreen and exits without opening a
	// window and without running a single bluetoothctl or rfkill command.
	// See shot.odin.
	for a, i in os.args[1:] {
		if a == "--shots" || a == "-shots" {
			rest := os.args[1:]
			if i + 1 >= len(rest) {
				fmt.eprintln("bluetooth --shots <dir>")
				os.exit(2)
			}
			os.exit(shots(rest[i + 1]))
		}
	}
	// Everything else on the command line is the other front end, declared
	// in cli.odin and parsed by the shared convention in apps/kit. With no
	// command there is a window.
	if code, handled := kit.cli(surface()); handled {
		os.exit(code)
	}

	app, err := kit.start(
		{
			title = "Bluetooth",
			width = 1060,
			height = 700,
			min_width = 880,
			min_height = 560,
			root_class = "w-full h-full bg-background text-foreground",
		},
	)
	if err != "" {
		fmt.eprintfln("bluetooth: %s", err)
		os.exit(1)
	}
	defer p.destroy(app)

	m := new(Model)
	virtual.arena_init_growing(&m.arena) or_else panic("arena")
	m.al = virtual.arena_allocator(&m.arena)
	reload(m)
	note(m, "Read adapter and device list", false)

	for ui in p.frames(app) {
		now := f64(p.elapsed(ui))

		// Collect a finished background command, then re-read the real state
		// so the UI can never disagree with BlueZ.
		if kind, label, subject, out, ok, got := job_collect(); got {
			_ = subject
			if kind == .Scan {
				m.scanning = false
			}
			reload(m)
			if ok {
				note(m, label, false)
			} else {
				first := strings.trim_space(out)
				if nl := strings.index_byte(first, '\n'); nl > 0 {
					first = first[:nl]
				}
				note(m, first == "" ? fmt.tprintf("%s failed", label) : first, true)
			}
			delete(out)
			m.busy_len = 0
		}

		// While a scan is up, keep asking BlueZ what it can see. The devices
		// are only in its cache for as long as discovery is running.
		if m.scanning {
			p.redraw(ui)
			if now >= m.next_poll {
				m.next_poll = now + 1.0
				reload(m, quiet = true)
			}
			if now >= m.scan_until + 2.0 {
				m.scanning = false
			}
		} else if job_busy() {
			p.redraw(ui)
		}

		g_now = now
		m.spin.t = f32(now)
		measure_rows(m, p.size(ui))

		// Input is handled before the tree is built, so the frame that follows
		// a key press already shows its result.
		keys(ui, app, m, build_view(m))
		build(ui, m, build_view(m))
	}
}

// measure_rows works out how many 56px rows the lists have room for. palmy
// only scrolls from the wheel, so the lists are windowed by hand and the
// window size decides how big that window is.
measure_rows :: proc(m: ^Model, vp: [2]f32) {
	list_h := vp.y - HEADER_H - TOOLBAR_H - FOOTER_H - 20 - 56 - 8 - 24
	m.rows = clamp(int(list_h / 56), 2, 40)
	m.tall = vp.y >= 800
}

// note shows a short line in the footer for a few seconds.
note :: proc(m: ^Model, s: string, bad: bool) {
	n := min(len(s), len(m.toast))
	copy(m.toast[:], s[:n])
	m.toast_len = n
	m.toast_bad = bad
	m.toast_until = g_now + 6.0
}

toast_text :: proc(m: ^Model) -> string {
	return string(m.toast[:m.toast_len])
}

busy :: proc(m: ^Model, s: string) {
	n := min(len(s), len(m.busy_label))
	copy(m.busy_label[:], s[:n])
	m.busy_len = n
}

// ---------------------------------------------------------------------------
// Reading the system
// ---------------------------------------------------------------------------

// reload re-reads everything from BlueZ. `quiet` is for the once-a-second poll
// that runs during a scan, which would otherwise bury the activity log.
reload :: proc(m: ^Model, quiet := false) {
	virtual.arena_free_all(&m.arena)
	m.al = virtual.arena_allocator(&m.arena)
	m.adapter = read_adapter(m.al)
	m.devices = read_devices(m.al)
	for &d in m.devices {
		if d.has_rssi {
			seen_note(d.addr, d.rssi)
		} else if r, ok := seen_get(d.addr); ok {
			d.rssi, d.has_rssi, d.rssi_old = r, true, true
		}
	}
	m.loaded = true
	if !quiet {
		log_command(
			{"rfkill list bluetooth; bluetoothctl show; bluetoothctl devices"},
			fmt.tprintf("+ info x%d", len(m.devices)),
			true,
		)
	}
}

sel_addr :: proc(m: ^Model) -> string {
	return string(m.sel[:m.sel_len])
}

set_sel :: proc(m: ^Model, addr: string) {
	n := min(len(addr), len(m.sel))
	copy(m.sel[:], addr[:n])
	m.sel_len = n
}

// ---------------------------------------------------------------------------
// Views over the device list
// ---------------------------------------------------------------------------

View :: struct {
	paired: []int, // indices into m.devices
	nearby: []int,
	sel:    int, // index into m.devices, -1 for none
	flat:   []int, // paired then nearby, the keyboard order
	at:     int, // position of the selection in `flat`, -1 for none
}

matches :: proc(d: Device, needle: string) -> bool {
	if needle == "" {
		return true
	}
	name, _ := display_name(d)
	return icontains(name, needle) || icontains(d.addr, needle)
}

icontains :: proc(hay, needle: string) -> bool {
	if len(needle) > len(hay) {
		return false
	}
	low :: proc(c: u8) -> u8 {return c >= 'A' && c <= 'Z' ? c + 32 : c}
	outer: for i in 0 ..= len(hay) - len(needle) {
		for j in 0 ..< len(needle) {
			if low(hay[i + j]) != low(needle[j]) {
				continue outer
			}
		}
		return true
	}
	return false
}

// better_nearby orders the nearby list the way a person scans it: strongest
// signal first, and anything that told us its name ahead of anything that
// did not.
better_nearby :: proc(a, b: Device) -> bool {
	_, an := display_name(a)
	_, bn := display_name(b)
	if an != bn {
		return an
	}
	if a.has_rssi != b.has_rssi {
		return a.has_rssi
	}
	if a.has_rssi && a.rssi != b.rssi {
		return a.rssi > b.rssi
	}
	return a.addr < b.addr
}

better_paired :: proc(a, b: Device) -> bool {
	if a.connected != b.connected {
		return a.connected
	}
	an, _ := display_name(a)
	bn, _ := display_name(b)
	return an < bn
}

build_view :: proc(m: ^Model) -> (v: View) {
	needle := string(m.filter[:])
	pd := make([dynamic]int, 0, len(m.devices), context.temp_allocator)
	nd := make([dynamic]int, 0, len(m.devices), context.temp_allocator)
	for d, i in m.devices {
		if !matches(d, needle) {
			continue
		}
		if d.paired {
			append(&pd, i)
		} else {
			append(&nd, i)
		}
	}
	// Insertion sort: these lists are a handful of entries long.
	sort :: proc(m: ^Model, xs: []int, less: proc(a, b: Device) -> bool) {
		for i in 1 ..< len(xs) {
			j := i
			for j > 0 && less(m.devices[xs[j]], m.devices[xs[j - 1]]) {
				xs[j], xs[j - 1] = xs[j - 1], xs[j]
				j -= 1
			}
		}
	}
	sort(m, pd[:], better_paired)
	sort(m, nd[:], better_nearby)

	flat := make([dynamic]int, 0, len(pd) + len(nd), context.temp_allocator)
	for i in pd {append(&flat, i)}
	for i in nd {append(&flat, i)}

	v = View {
		paired = pd[:],
		nearby = nd[:],
		flat   = flat[:],
		sel    = -1,
		at     = -1,
	}

	want := sel_addr(m)
	for i, k in v.flat {
		if m.devices[i].addr == want {
			v.sel = i
			v.at = k
			break
		}
	}
	if v.at < 0 && len(v.flat) > 0 {
		v.sel = v.flat[0]
		v.at = 0
		set_sel(m, m.devices[v.sel].addr)
	}
	// Split the available rows between the two sections, giving each at least
	// one and never leaving the list it is showing short of the other.
	budget := max(2, m.rows)
	wp := max(1, min(len(v.paired), budget))
	wn := max(1, min(len(v.nearby), budget))
	if wp + wn > budget {
		half := max(1, budget / 2)
		if wp > half && wn > budget - half {
			wp = half
		}
		wn = max(1, budget - wp)
	}
	m.vis_p, m.vis_n = wp, wn

	if v.at >= 0 {
		m.pane = v.at < len(v.paired) ? .Paired : .Nearby
		// Keep the selection inside its window.
		if m.pane == .Paired {
			i := v.at
			m.p_top = clamp(m.p_top, max(0, i - wp + 1), i)
		} else {
			i := v.at - len(v.paired)
			m.n_top = clamp(m.n_top, max(0, i - wn + 1), i)
		}
	}
	m.p_top = clamp(m.p_top, 0, max(0, len(v.paired) - wp))
	m.n_top = clamp(m.n_top, 0, max(0, len(v.nearby) - wn))
	return
}

move_sel :: proc(m: ^Model, v: View, delta: int) {
	if len(v.flat) == 0 {
		return
	}
	at := v.at < 0 ? 0 : clamp(v.at + delta, 0, len(v.flat) - 1)
	set_sel(m, m.devices[v.flat[at]].addr)
}

// ---------------------------------------------------------------------------
// Keyboard
// ---------------------------------------------------------------------------

keys :: proc(ui: ^p.Ctx, app: ^p.App, m: ^Model, v: View) {
	// A confirmation is modal: it is the only thing the keyboard can reach,
	// and it opens on Cancel.
	if m.confirm != .None {
		if p.key_pressed(ui, p.KEY_ESCAPE) {
			m.confirm = .None
		}
		if p.key_pressed(ui, p.KEY_LEFT) ||
		   p.key_pressed(ui, p.KEY_RIGHT) ||
		   p.key_pressed(ui, p.KEY_TAB) ||
		   p.key_pressed(ui, p.KEY_UP) ||
		   p.key_pressed(ui, p.KEY_DOWN) {
			m.confirm_sel = 1 - m.confirm_sel
		}
		if p.key_pressed(ui, p.KEY_RETURN) || p.key_pressed(ui, p.KEY_SPACE) {
			act := m.confirm
			m.confirm = .None
			if m.confirm_sel == 1 {
				exec_action(m, act, v)
			}
		}
		return
	}

	if m.menu_open {
		items := menu_items(m, v)
		if p.key_pressed(ui, p.KEY_ESCAPE) {
			m.menu_open = false
		}
		if p.key_pressed(ui, p.KEY_DOWN) {
			m.menu_sel = next_enabled(items, m.menu_sel, 1)
		}
		if p.key_pressed(ui, p.KEY_UP) {
			m.menu_sel = next_enabled(items, m.menu_sel, -1)
		}
		if p.key_pressed(ui, p.KEY_RETURN) || p.key_pressed(ui, p.KEY_SPACE) {
			if m.menu_sel >= 0 && m.menu_sel < len(items) && items[m.menu_sel].enabled {
				run_action(m, items[m.menu_sel].act, v)
			}
			m.menu_open = false
		}
		return
	}

	if m.log_open {
		if p.key_pressed(ui, p.KEY_ESCAPE) || p.key_pressed(ui, 'l') {
			m.log_open = false
		}
		return
	}

	if p.key_pressed(ui, p.KEY_DOWN) {move_sel(m, v, 1)}
	if p.key_pressed(ui, p.KEY_UP) {move_sel(m, v, -1)}
	if p.key_pressed(ui, p.KEY_PAGE_DOWN) {move_sel(m, v, 5)}
	if p.key_pressed(ui, p.KEY_PAGE_UP) {move_sel(m, v, -5)}
	if p.key_pressed(ui, p.KEY_HOME) {move_sel(m, v, -9999)}
	if p.key_pressed(ui, p.KEY_END) {move_sel(m, v, 9999)}

	if p.key_pressed(ui, p.KEY_RETURN) && v.sel >= 0 {
		open_menu(m, v)
	}

	if p.shortcut(ui, 'q', {.Ctrl}) {
		p.quit_app(app)
	}

	// Letter shortcuts stand down while the filter field has the keyboard.
	if m.filter_focus {
		if p.key_pressed(ui, p.KEY_ESCAPE) {
			clear(&m.filter)
		}
		return
	}

	if p.key_pressed(ui, p.KEY_ESCAPE) {
		if len(m.filter) > 0 {
			clear(&m.filter)
		}
	}
	if p.key_pressed(ui, 's') {start_scan(m)}
	if p.key_pressed(ui, 'r') {
		reload(m)
		note(m, "Refreshed from bluetoothctl", false)
	}
	if p.key_pressed(ui, 'p') {toggle_power(m)}
	if p.key_pressed(ui, 'd') {toggle_discoverable(m)}
	if p.key_pressed(ui, 'l') {m.log_open = true}
	// Device actions deliberately have no single-key shortcut: they go through
	// the menu or the buttons, where the label says what will happen.
}

// ---------------------------------------------------------------------------
// Actions. Every one of these is a single bluetoothctl invocation on a worker
// thread; nothing here is fired without a key press.
//
// Deliberately absent: `remove` and `untrust`. Forgetting a device is the one
// Bluetooth operation a person cannot undo without the device in hand, so this
// applet does not offer it at all.
// ---------------------------------------------------------------------------

start_scan :: proc(m: ^Model) {
	if job_busy() {
		return
	}
	if !m.adapter.powered {
		note(m, "Turn Bluetooth on before scanning", true)
		return
	}
	if job_start(
		.Scan,
		"Scan complete",
		"",
		argv_own(..action_words(.Scan, "", true)),
	) {
		m.scanning = true
		m.scan_until = g_now + f64(SCAN_SECS)
		m.next_poll = 0
		busy(m, "Scanning for devices")
		note(m, fmt.tprintf("bluetoothctl --timeout %d scan on", SCAN_SECS), false)
	}
}

toggle_power :: proc(m: ^Model) {
	if job_busy() {
		return
	}
	if m.adapter.hard_block {
		note(m, "Radio is hard-blocked; use the hardware switch", true)
		return
	}
	on := !m.adapter.powered
	if !on && any_connected(m) {
		// Turning the radio off drops whatever is playing through it.
		m.confirm = .Power
		m.confirm_sel = 0
		return
	}
	exec_power(m, on)
}

exec_power :: proc(m: ^Model, on: bool) {
	busy(m, on ? "Powering on" : "Powering off")
	job_start(
		.Power,
		on ? "Bluetooth on" : "Bluetooth off",
		"",
		argv_own(..action_words(.Power, "", on)),
	)
}

any_connected :: proc(m: ^Model) -> bool {
	for d in m.devices {
		if d.connected {
			return true
		}
	}
	return false
}

toggle_discoverable :: proc(m: ^Model) {
	if job_busy() {
		return
	}
	if !m.adapter.powered {
		note(m, "Turn Bluetooth on first", true)
		return
	}
	on := !m.adapter.discoverable
	busy(m, on ? "Becoming discoverable" : "Hiding")
	job_start(
		.Discoverable,
		on ? "Discoverable" : "Not discoverable",
		"",
		argv_own(..action_words(.Discoverable, "", on)),
	)
}

// run_action is the gate. Disconnecting is the only thing here that takes
// something away from the person using the machine, so it asks first.
run_action :: proc(m: ^Model, act: Job_Kind, v: View) {
	if v.sel < 0 || job_busy() {
		return
	}
	if act == .Disconnect {
		if !m.devices[v.sel].connected {
			note(m, "Not connected", true)
			return
		}
		m.confirm = .Disconnect
		m.confirm_sel = 0
		return
	}
	exec_action(m, act, v)
}

exec_action :: proc(m: ^Model, act: Job_Kind, v: View) {
	if job_busy() {
		return
	}
	if act == .Power {
		exec_power(m, !m.adapter.powered)
		return
	}
	if v.sel < 0 {
		return
	}
	d := m.devices[v.sel]
	switch act {
	case .Connect:
		if d.connected {
			note(m, "Already connected", true)
			return
		}
		busy(m, "Connecting")
		job_start(.Connect, "Connected", d.addr, argv_own(..action_words(.Connect, d.addr, true)))
	case .Disconnect:
		if !d.connected {
			note(m, "Not connected", true)
			return
		}
		busy(m, "Disconnecting")
		job_start(
			.Disconnect,
			"Disconnected",
			d.addr,
			argv_own(..action_words(.Disconnect, d.addr, true)),
		)
	case .Pair:
		if d.paired {
			note(m, "Already paired", true)
			return
		}
		busy(m, "Pairing")
		job_start(.Pair, "Paired", d.addr, argv_own(..action_words(.Pair, d.addr, true)))
	case .Trust:
		if d.trusted {
			note(m, "Already trusted", true)
			return
		}
		busy(m, "Trusting")
		job_start(.Trust, "Trusted", d.addr, argv_own(..action_words(.Trust, d.addr, true)))
	case .Copy:
		// palmy has no clipboard, so the address goes out through wl-copy.
		busy(m, "Copying address")
		job_start(.Copy, "Address copied", d.addr, argv_own("wl-copy", d.addr))
	case .None, .Scan, .Power, .Discoverable:
	// not device actions
	}
}

// ---------------------------------------------------------------------------
// The context menu
// ---------------------------------------------------------------------------

Menu_Item :: struct {
	label:    string,
	hint:     string,
	act:      Job_Kind,
	enabled:  bool,
	sep:      bool, // a separator sits above this item
	icon:     p.Icon,
	has_icon: bool,
}

menu_items :: proc(m: ^Model, v: View) -> []Menu_Item {
	out := make([dynamic]Menu_Item, 0, 8, context.temp_allocator)
	if v.sel < 0 {
		return out[:]
	}
	d := m.devices[v.sel]
	on := m.adapter.powered
	append(
		&out,
		Menu_Item {
			label = "Connect",
			act = .Connect,
			enabled = on && !d.connected,
			icon = IC_LINK_2,
			has_icon = true,
		},
	)
	append(
		&out,
		Menu_Item {
			label = "Disconnect",
			act = .Disconnect,
			enabled = on && d.connected,
			icon = IC_LINK_2_OFF,
			has_icon = true,
		},
	)
	append(
		&out,
		Menu_Item {
			label = "Pair",
			act = .Pair,
			enabled = on && !d.paired,
			sep = true,
			icon = IC_PLUS,
			has_icon = true,
		},
	)
	append(
		&out,
		Menu_Item {
			label = "Trust",
			act = .Trust,
			enabled = on && !d.trusted,
			icon = IC_SHIELD_CHECK,
			has_icon = true,
		},
	)
	append(
		&out,
		Menu_Item {
			label = "Copy address",
			act = .Copy,
			enabled = true,
			sep = true,
			icon = IC_COPY,
			has_icon = true,
		},
	)
	return out[:]
}

next_enabled :: proc(items: []Menu_Item, from, delta: int) -> int {
	if len(items) == 0 {
		return 0
	}
	i := from
	for _ in 0 ..< len(items) {
		i += delta
		if i < 0 {i = len(items) - 1}
		if i >= len(items) {i = 0}
		if items[i].enabled {
			return i
		}
	}
	return from
}

open_menu :: proc(m: ^Model, v: View) {
	items := menu_items(m, v)
	if len(items) == 0 {
		return
	}
	m.menu_open = true
	m.menu_sel = items[0].enabled ? 0 : next_enabled(items, 0, 1)
}
