package main

// `bluetooth --shots <dir>`: render the panel offscreen and write PNGs.
//
// NOTHING IS EXECUTED. The windowed application reads BlueZ through `rfkill`
// and `bluetoothctl`; this path calls neither `reload` nor `job_start`, so no
// child process is spawned, no scan is started, nothing is paired, unpaired,
// connected, disconnected or trusted, and the radio is not touched.
//
// The adapter and the device list below are invented. Every address is in the
// locally-administered 02:00:5E range rather than belonging to anything within
// radio range of this machine.

import "core:fmt"
import "core:os"
import kit "kit:."
import p "palmy:."
import sc "shadcn:."

SHOT_W :: 1060
SHOT_H :: 820 // tall enough for the inspector's activity feed

shot_fonts :: proc(f: ^p.Fonts) {
	for pair in ([?]struct {
		file: string,
		wt:   p.Font_Weight,
	}{
		{"Geist-400.ttf", .Regular},
		{"Geist-500.ttf", .Medium},
		{"Geist-600.ttf", .Semibold},
		{"Geist-700.ttf", .Bold},
	}) {
		p.load_font(f, fmt.tprintf("%s/%s", kit.FONT_DIR, pair.file), .Sans, pair.wt)
	}
	for wt in p.Font_Weight {
		p.use_synthetic_italic(f, .Sans, wt)
	}
	for path in ([?]string {
		"/usr/share/fonts/TTF/JetBrainsMonoNerdFont-Regular.ttf",
		"/usr/share/fonts/TTF/DejaVuSansMono.ttf",
		"/usr/share/fonts/liberation/LiberationMono-Regular.ttf",
	}) {
		if p.load_font(f, path, .Mono, .Regular) {
			p.load_font(f, path, .Mono, .Medium)
			p.load_font(f, path, .Mono, .Semibold)
			p.load_font(f, path, .Mono, .Bold)
			break
		}
	}
}

shot_fill :: proc(m: ^Model) {
	m.adapter = Adapter {
		present      = true,
		addr         = "02:00:5E:C0:11:00",
		addr_type    = "public",
		name         = "palmy",
		alias        = "palmy",
		class        = 0x0c0104,
		powered      = true,
		discoverable = false,
		pairable     = true,
		discovering  = false,
		disc_timeout = 180,
		services     = 7,
	}

	dev :: proc(
		addr, name, icon: string,
		kind: Kind,
		class: u32,
		paired, bonded, trusted, connected: bool,
		battery, rssi, services: int,
		modalias := "",
	) -> Device {
		return Device {
			addr = addr,
			addr_type = "public",
			name = name,
			alias = name,
			icon_name = icon,
			class = class,
			has_class = class != 0,
			paired = paired,
			bonded = bonded,
			trusted = trusted,
			connected = connected,
			battery = battery,
			rssi = rssi,
			has_rssi = rssi != 0,
			tx_power = rssi != 0 ? 4 : 0,
			has_tx = rssi != 0,
			services = services,
			modalias = modalias,
			reachable = true,
			kind = kind,
		}
	}

	list := make([]Device, 9)
	// Paired.
	list[0] = dev(
		"02:00:5E:A0:31:4C",
		"Aurora Buds Pro",
		"audio-headset",
		.Headphones,
		0x240418,
		true,
		true,
		true,
		true,
		74,
		-52,
		6,
		"bluetooth:v004Cp2014d0A1B",
	)
	list[1] = dev("02:00:5E:A0:12:9F", "Keychron Loft", "input-keyboard", .Keyboard, 0x002540, true, true, true, true, 88, -58, 3)
	list[2] = dev("02:00:5E:A0:77:21", "MX Drift", "input-mouse", .Mouse, 0x002580, true, true, true, false, -1, -71, 2)
	list[3] = dev("02:00:5E:A0:08:D3", "Hearth Speaker", "audio-card", .Speaker, 0x240414, true, true, false, false, -1, 0, 4)
	list[4] = dev("02:00:5E:A0:5B:60", "Pebble Watch 4", "watch", .Watch, 0x700704, true, false, false, false, 41, -79, 5)
	// Nearby, not paired.
	list[5] = dev("02:00:5E:B1:40:11", "Studio Monitor 22", "audio-card", .Speaker, 0x240414, false, false, false, false, -1, -63, 0)
	list[6] = dev("02:00:5E:B1:66:A2", "Rowan's Phone", "phone", .Phone, 0x5a020c, false, false, false, false, -1, -74, 0)
	list[7] = dev("02:00:5E:B1:19:7E", "", "", .Generic, 0, false, false, false, false, -1, -88, 0)
	list[8] = dev("02:00:5E:B1:C4:03", "Tilt Gamepad", "input-gaming", .Gamepad, 0x002508, false, false, false, false, -1, -81, 0)
	m.devices = list
	m.loaded = true

	// The activity feed is a record of what has been run. Since this path runs
	// nothing, it says so rather than inventing a command history.
	log_command({"(--shots: no command was executed)"}, "offscreen render", true)

	set_sel(m, list[0].addr)
}

shots :: proc(dir: string) -> int {
	if err := os.make_directory_all(dir, os.perm(0o755)); err != nil && !os.exists(dir) {
		fmt.eprintfln("bluetooth: cannot create %s", dir)
		return 1
	}

	off := p.offscreen_create(SHOT_W, SHOT_H, 1, "w-full h-full bg-background text-foreground")
	defer p.offscreen_destroy(off)
	shot_fonts(&off.fonts)
	sc.register_shadcn_theme(false)
	p.set_text_gamma(1.8)

	m := new(Model)
	m.filter = make([dynamic]u8)
	shot_fill(m)

	step :: proc(off: ^p.Offscreen, m: ^Model) {
		ui := p.offscreen_begin(off)
		g_now = f64(p.elapsed(ui))
		m.spin.t = f32(g_now)
		measure_rows(m, p.size(ui))
		keys(ui, nil, m, build_view(m))
		build(ui, m, build_view(m))
		p.offscreen_end(off)
	}

	shot :: proc(off: ^p.Offscreen, dir, name: string) {
		out := fmt.tprintf("%s/%s.png", dir, name)
		p.offscreen_write_png(off, out)
		fmt.printfln("  %s", out)
	}

	note(m, "Showing the fabricated device list", false)
	step(off, m)
	step(off, m)
	shot(off, dir, "app-bluetooth")

	// A nearby, unpaired device: the inspector offers Pair rather than Trust.
	set_sel(m, m.devices[6].addr)
	step(off, m)
	step(off, m)
	shot(off, dir, "02-bluetooth-nearby")

	// The per-device menu, opened directly rather than through a key, so no
	// action can be armed by accident.
	set_sel(m, m.devices[0].addr)
	step(off, m)
	open_menu(m, build_view(m))
	step(off, m)
	step(off, m)
	shot(off, dir, "03-bluetooth-menu")
	m.menu_open = false
	step(off, m)

	// The confirmation sheet. Setting `m.confirm` only draws it; the Return
	// that would run the command is never pressed.
	m.confirm = .Disconnect
	m.confirm_sel = 0
	step(off, m)
	step(off, m)
	shot(off, dir, "04-bluetooth-confirm")
	m.confirm = .None
	step(off, m)

	// The filter, in the real buffer the text field edits.
	append(&m.filter, 'o')
	step(off, m)
	step(off, m)
	shot(off, dir, "05-bluetooth-filter")
	clear(&m.filter)
	step(off, m)

	// The radio off, which is the state the panel has to explain.
	m.adapter.powered = false
	step(off, m)
	step(off, m)
	shot(off, dir, "06-bluetooth-radio-off")
	m.adapter.powered = true

	return 0
}
