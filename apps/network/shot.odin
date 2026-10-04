package main

// `network --shots <dir>`: render the panel offscreen and write PNGs.
//
// NOTHING IS EXECUTED. The windowed application reads the machine through
// `nmcli`; this path never starts the worker thread, never queues a job and
// never spawns a process. The `Store` is filled in by `shot_store` below with
// invented interfaces, invented SSIDs and invented BSSIDs, so no neighbouring
// network, no real MAC address and no real address of this machine can reach a
// committed image — and the host's connectivity is not touched in any way.

import "core:fmt"
import "core:os"
import "core:strings"
import kit "kit:."
import p "palmy:."
import sc "shadcn:."

SHOT_W :: 1180
SHOT_H :: 772

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

// shot_store is the fabricated scan. Every SSID is made up, every BSSID is in
// the 02:00:5e locally-administered range, and the addressing is RFC 5737
// documentation space where it is not RFC 1918.
shot_store :: proc(s: ^Store) {
	s.devices = make([dynamic]Dev)
	s.aps = make([dynamic]Ap)
	s.saved = make([dynamic]Saved)

	cl :: strings.clone

	append(
		&s.devices,
		Dev {
			name = cl("wlp3s0"),
			kind = cl("wifi"),
			state = .Connected,
			conn = cl("Hollow Pine"),
			hwaddr = cl("02:00:5E:11:4A:07"),
			mtu = cl("1500"),
			ip4 = cl("192.0.2.41"),
			prefix = cl("/24"),
			gw4 = cl("192.0.2.1"),
			dns = cl("192.0.2.1, 198.51.100.9"),
			ip6 = cl("2001:db8:4a7::41"),
		},
	)
	append(
		&s.devices,
		Dev {
			name = cl("enp0s31f6"),
			kind = cl("ethernet"),
			state = .Disconnected,
			hwaddr = cl("02:00:5E:11:4A:08"),
			mtu = cl("1500"),
			speed = cl("1000"),
		},
	)
	append(
		&s.devices,
		Dev {
			name = cl("wg-lab"),
			kind = cl("wireguard"),
			state = .Connected,
			external = true,
			conn = cl("wg-lab"),
			mtu = cl("1420"),
			ip4 = cl("10.77.0.4"),
			prefix = cl("/32"),
		},
	)
	append(
		&s.devices,
		Dev {
			name = cl("docker0"),
			kind = cl("bridge"),
			state = .Unmanaged,
			ip4 = cl("172.17.0.1"),
			prefix = cl("/16"),
			mtu = cl("1500"),
		},
	)
	append(&s.devices, Dev{name = cl("lo"), kind = cl("loopback"), state = .Unmanaged, mtu = cl("65536")})

	ap :: proc(
		ssid: string,
		signal, channel, freq: int,
		sec, rate, bssid, band: string,
		active := false,
		bssids := 1,
	) -> Ap {
		return Ap {
			ssid = strings.clone(ssid),
			security = strings.clone(sec),
			rate = strings.clone(rate),
			bssid = strings.clone(bssid),
			band = strings.clone(band),
			signal = signal,
			channel = channel,
			freq = freq,
			active = active,
			bssids = bssids,
		}
	}
	append(&s.aps, ap("Hollow Pine", 92, 44, 5220, "WPA2", "540 Mbit/s", "02:00:5E:A1:00:11", "5 GHz", true, 2))
	append(&s.aps, ap("Hollow Pine Guest", 84, 44, 5220, "WPA2", "540 Mbit/s", "02:00:5E:A1:00:12", "5 GHz"))
	append(&s.aps, ap("Marbled Teal", 71, 6, 2437, "WPA3", "270 Mbit/s", "02:00:5E:A1:00:21", "2.4 GHz", false, 3))
	append(&s.aps, ap("Fifth Floor Lab", 64, 149, 5745, "WPA2 802.1X", "866 Mbit/s", "02:00:5E:A1:00:31", "5 GHz"))
	append(&s.aps, ap("Quiet Coach", 52, 11, 2462, "WPA2", "130 Mbit/s", "02:00:5E:A1:00:41", "2.4 GHz"))
	append(&s.aps, ap("Printer Direct", 44, 1, 2412, "", "54 Mbit/s", "02:00:5E:A1:00:51", "2.4 GHz"))
	append(&s.aps, ap("Beacon Row", 37, 36, 5180, "WPA2", "433 Mbit/s", "02:00:5E:A1:00:61", "5 GHz"))
	append(&s.aps, ap("Larkspur Mesh", 29, 3, 2422, "WPA2", "130 Mbit/s", "02:00:5E:A1:00:71", "2.4 GHz", false, 2))
	append(&s.aps, ap("Tidewater", 21, 100, 5500, "WPA3", "866 Mbit/s", "02:00:5E:A1:00:81", "5 GHz"))

	sv :: proc(name, kind, device, uuid: string, auto: bool) -> Saved {
		return Saved {
			name = strings.clone(name),
			kind = strings.clone(kind),
			device = strings.clone(device),
			uuid = strings.clone(uuid),
			autoconnect = auto,
			active = device != "",
		}
	}
	append(&s.saved, sv("Hollow Pine", "Wi-Fi", "wlp3s0", "8f2c0a11-0000-4000-8000-000000000001", true))
	append(&s.saved, sv("wg-lab", "WireGuard", "wg-lab", "8f2c0a11-0000-4000-8000-000000000002", false))
	append(&s.saved, sv("Wired connection 1", "Ethernet", "", "8f2c0a11-0000-4000-8000-000000000003", true))
	append(&s.saved, sv("Marbled Teal", "Wi-Fi", "", "8f2c0a11-0000-4000-8000-000000000004", true))
	append(&s.saved, sv("Fifth Floor Lab", "Wi-Fi", "", "8f2c0a11-0000-4000-8000-000000000005", false))

	s.radio_on = true
	s.loaded = true
	s.scanned = true
	s.scan_at = strings.clone("20:41:06")
	s.message = strings.clone("9 networks in range")
	s.msg_kind = .Info
}

shots :: proc(dir: string) -> int {
	if err := os.make_directory_all(dir, os.perm(0o755)); err != nil && !os.exists(dir) {
		fmt.eprintfln("network: cannot create %s", dir)
		return 1
	}

	off := p.offscreen_create(SHOT_W, SHOT_H, 1, "w-full h-full bg-background text-foreground")
	defer p.offscreen_destroy(off)
	shot_fonts(&off.fonts)
	sc.register_shadcn_theme(false)
	p.set_text_gamma(1.8)

	store: Store
	shot_store(&store)

	u := UI {
		st      = &store,
		section = .Networks,
		cap     = {.Toolbar = TOOLBAR_ITEMS, .Devices = 8, .Networks = 8, .Saved = 8},
	}
	u.pw = make([dynamic]u8)

	step :: proc(off: ^p.Offscreen, u: ^UI) {
		ctx := p.offscreen_begin(off)
		keys(ctx, u)
		build(ctx, u)
		p.offscreen_end(off)
	}

	shot :: proc(off: ^p.Offscreen, dir, name: string) {
		out := fmt.tprintf("%s/%s.png", dir, name)
		p.offscreen_write_png(off, out)
		fmt.printfln("  %s", out)
	}

	// Two frames: hover and hit testing run against the previous one.
	step(off, &u)
	step(off, &u)
	shot(off, dir, "app-network")

	// The interface list focused, on the WireGuard tunnel, so the detail card
	// shows a different kind of link.
	u.section = .Devices
	u.picked_dev = true
	u.sel[.Devices] = 2
	step(off, &u)
	step(off, &u)
	shot(off, dir, "02-network-interfaces")

	// The connect dialog, with a password half typed into the real buffer.
	// `keys` is still the app's own handler; nothing is submitted, because the
	// Enter that would queue a .Connect job is never pressed.
	u.section = .Networks
	u.sel[.Networks] = 2
	step(off, &u)
	open_dialog(&u, store.aps[2])
	step(off, &u)
	p.type_text(off, "correct horse")
	step(off, &u)
	step(off, &u)
	shot(off, dir, "03-network-connect-dialog")
	close_dialog(&u)
	step(off, &u)

	// The saved profiles column.
	u.section = .Saved
	u.sel[.Saved] = 1
	step(off, &u)
	step(off, &u)
	shot(off, dir, "04-network-saved")

	// The radio off, which is a state the panel has to say something about.
	u.section = .Networks
	store.radio_on = false
	step(off, &u)
	step(off, &u)
	shot(off, dir, "05-network-radio-off")
	store.radio_on = true

	return 0
}
