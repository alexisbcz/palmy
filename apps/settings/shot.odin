package main

// `settings --shots <dir>`: every page, light and dark, rendered offscreen.
//
// NOTHING ON THE MACHINE IS READ OR WRITTEN. The model is a fixture with
// `fixture = true`, so page_ensure reads nothing and every setter changes
// only the model; no wpctl, no palm, no files.

import "core:fmt"
import "core:os"
import "core:strings"
import kit "kit:."
import p "palmy:."
import sc "shadcn:."

SHOT_W :: 1080
SHOT_H :: 760

shot_fonts :: proc(f: ^p.Fonts) {
	for pair in ([?]struct {
		file: string,
		wt:   p.Font_Weight,
	}{{"Geist-400.ttf", .Regular}, {"Geist-500.ttf", .Medium}, {"Geist-600.ttf", .Semibold}, {"Geist-700.ttf", .Bold}}) {
		p.load_font(f, fmt.tprintf("%s/%s", kit.FONT_DIR, pair.file), .Sans, pair.wt)
	}
	for wt in p.Font_Weight {
		p.use_synthetic_italic(f, .Sans, wt)
	}
	for path in ([?]string{"/usr/share/fonts/TTF/JetBrainsMonoNerdFont-Regular.ttf", "/usr/share/fonts/TTF/DejaVuSansMono.ttf"}) {
		if p.load_font(f, path, .Mono, .Regular) {
			p.load_font(f, path, .Mono, .Medium)
			p.load_font(f, path, .Mono, .Semibold)
			p.load_font(f, path, .Mono, .Bold)
			break
		}
	}
}

@(private = "file")
SHOT_LAYOUTS := [?]Layout{
		{"al", "Albanian"},
		{"ara", "Arabic"},
		{"gb", "English (UK)"},
		{"us", "English (US)"},
		{"fi", "Finnish"},
		{"fr", "French"},
		{"de", "German"},
		{"it", "Italian"},
		{"jp", "Japanese"},
		{"es", "Spanish"},
		{"se", "Swedish"},
	}

@(private = "file")
SHOT_ZONES := [?]string{"Africa/Cairo", "America/New_York", "America/Sao_Paulo", "Asia/Kolkata", "Asia/Tokyo", "Australia/Sydney", "Europe/Berlin", "Europe/London", "Europe/Paris", "Pacific/Auckland", "UTC"}

@(private = "file")
SHOT_DISPLAYS := [?]Display{
			{name = "eDP-1", desc = "BOE 0x0BCA (built-in)", x = 0, y = 0, w = 1440, h = 900, mode_w = 2880, mode_h = 1800, refresh_mhz = 60001, scale = 2, mm_w = 302, mm_h = 189, connected = true},
			{name = "DP-2", desc = "Dell Inc. U2720Q", x = 1440, y = 0, w = 3840, h = 2160, mode_w = 3840, mode_h = 2160, refresh_mhz = 59997, scale = 1, mm_w = 597, mm_h = 336, connected = true},
		}

@(private = "file")
SHOT_SINKS := [?]Sink{{46, "Built-in Audio Analog Stereo", true, 0.62}, {51, "USB Headset", false, 0.4}}

@(private = "file")
SHOT_SOURCES := [?]Sink{{47, "Built-in Audio Digital Microphone", true, 1}}

@(private = "file")
SHOT_IFACES := [?]Iface{
		{name = "wlan0", kind = "Wi-Fi", state = "up", mac = "02:00:5e:10:00:01", addrs = []string{"192.168.1.42/24"}, ssid = "Northwind Guest"},
		{name = "enp3s0", kind = "Ethernet", state = "down", mac = "02:00:5e:10:00:02"},
	}

@(private = "file")
SHOT_USERS := [?]User{
		{name = "camille", gecos = "Camille Roux", home = "/home/camille", uid = 1000, gid = 1000, groups = []string{"camille", "wheel", "video", "audio", "input"}},
		{name = "sam", gecos = "Sam Roux", home = "/home/sam", uid = 1001, gid = 1001, groups = []string{"sam", "video", "audio"}},
	}

@(private = "file")
SHOT_UPGRADES := [?]string{"docs 0.1.0-r0 → 0.1.1-r0", "linux 6.18.2-r0 → 6.18.4-r0"}

shot_model :: proc() -> ^Model {
	m := new(Model)
	m.fixture = true
	m.loaded = ~bit_set[Page]{}
	m.accent = "#6366f1"
	m.wp_mode = "fill"
	m.super_tap = "menu"
	m.bar_pins = true
	m.hot_corner = true
	m.animations = "on"
	m.tap = true
	m.natural = true
	m.delay = 400
	m.rate = 25
	m.sys_layout = "fr"
	m.layout = ""
	m.sys_tz = "Europe/Paris"
	m.me = "camille"
	m.have = make(map[string]bool)
	for k in ([?]string{"term", "passwd", "mixer", "store"}) {
		m.have[k] = true
	}
	m.layouts = SHOT_LAYOUTS[:]
	m.zones = SHOT_ZONES[:]
	m.wm = Wm_State {
		ok            = true,
		bare          = true,
		kbd_rmlvo     = "evdev/pc105/fr",
		kbd_from      = "/etc/palm/keyboard",
		displays      = SHOT_DISPLAYS[:],
	}
	m.sound = Sound {
		available  = true,
		running    = true,
		volume     = 0.62,
		sinks      = SHOT_SINKS[:],
		sources    = SHOT_SOURCES[:],
	}
	m.ifaces = SHOT_IFACES[:]
	m.users = SHOT_USERS[:]
	m.updates = Updates {
		available  = true,
		installed  = 96,
		system_ver = "0.1.0-r0",
		palm_ver   = "palm 0.2.0",
		checked    = 1792396800,
		upgradable = SHOT_UPGRADES[:],
	}
	m.about = About {
		os_name      = "Palmframe",
		os_version   = "0.1.0",
		hostname     = "camille-laptop",
		kernel       = "6.18.4-palmframe",
		cpu          = "AMD Ryzen 7 7840U w/ Radeon 780M Graphics",
		cores        = 16,
		mem_total_kb = 32 * 1024 * 1024,
		disk_total   = 1_000_000_000_000,
		disk_free    = 712_000_000_000,
		gpu          = "amdgpu",
		uptime_s     = 3 * 3600 + 25 * 60,
	}
	return m
}

shots :: proc(dir: string) -> int {
	if err := os.make_directory_all(dir); err != nil && !os.exists(dir) {
		fmt.eprintfln("settings: could not create %s", dir)
		return 1
	}
	n := 0
	for light in ([2]bool{true, false}) {
		sc.register_shadcn_theme(!light)
		off := p.offscreen_create(SHOT_W, SHOT_H, 1, "w-full h-full bg-background text-foreground")
		shot_fonts(&off.fonts)
		p.set_text_gamma(1.8)
		m := shot_model()
		m.light = light
		for pg in Page {
			m.page = pg
			for _ in 0 ..< 3 {
				ui := p.offscreen_begin(off)
				build(ui, m)
				p.offscreen_end(off)
				free_all(context.temp_allocator)
			}
			name := fmt.tprintf("%s/%02d-%s-%s.png", dir, int(pg) + 1, PAGE_ID[pg], light ? "light" : "dark")
			if p.offscreen_write_png(off, name) {
				n += 1
				fmt.printfln("  %s", name)
			}
		}
		p.offscreen_destroy(off)
	}
	fmt.printfln("settings --shots: %d PNGs in %s", n, dir)
	_ = strings.clone
	return n > 0 ? 0 : 1
}
