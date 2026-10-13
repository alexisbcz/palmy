package main

// installer — Palmframe's graphical installer.
//
// The live system starts it as root inside `wm --drm --kiosk --exec
// installer` (INSTALLER.md). It walks a person through eight pages —
// language, keyboard, time zone, disk, account, summary, install, done — and
// hands the plan to install_core, which runs on a worker thread while this
// thread draws its progress every frame.
//
//	installer [--demo] [--demo-fail] [--dry-run] [--lang CODE]
//	installer --shots DIR       offscreen PNGs of every page, no window
//	installer --selftest        flow, validation and catalogue checks
//
// Two modes, decided once at start (`choose_mode`):
//
//   - real: the disks, layouts and zones come from install_core, the keyboard
//     page switches the compositor's layout, and Install erases the chosen
//     disk. Only as root on a Palmframe system (/etc/palm/keys exists).
//     --dry-run keeps everything real except the install itself, which the
//     core then only describes (Options.dry_run): for trying the real disk
//     list and keyboard switching inside QEMU without writing the disk.
//   - demo: everything is fabricated and the install only sleeps. This is
//     what runs anywhere else, whether --demo was given or not, and the rail
//     says so. It is how the installer is developed and photographed on a
//     machine whose disks must not be touched.
//
// Layout files: flow.odin is the state machine, account.odin the account
// rules, backend.odin the only code that touches the system, demo.odin the
// fabrications, ui.odin the frame and pages.odin the pages.

import "core:fmt"
import "core:os"
import "core:sys/linux"
import kit "kit:."
import p "palmy:."

main :: proc() {
	want_demo := false
	demo_fail := false
	dry_run := false
	lang := ""

	args := os.args[1:]
	for i := 0; i < len(args); i += 1 {
		switch args[i] {
		case "--demo":
			want_demo = true
		case "--demo-fail":
			want_demo = true
			demo_fail = true
		case "--dry-run":
			dry_run = true
		case "--lang":
			i += 1
			if i < len(args) {
				lang = args[i]
			}
		case "--shots":
			i += 1
			os.exit(shots(i < len(args) ? args[i] : "distro/build/installer-gui"))
		case "--selftest":
			os.exit(selftest())
		case "-h", "--help":
			fmt.println(
				"installer [--demo] [--demo-fail] [--dry-run] [--lang CODE]\n" +
				"          --shots DIR   offscreen PNGs of every page in en, fr and ar; no window\n" +
				"          --selftest    step flow, validation and catalogue checks",
			)
			return
		case:
			fmt.eprintfln("installer: unknown argument %q", args[i])
			os.exit(2)
		}
	}

	b := Backend {
		demo      = choose_mode(want_demo),
		demo_fail = demo_fail,
		dry_run   = dry_run,
	}

	i18n_start(lang)
	st := new(St)
	state_init(st, b)
	if lang != "" {
		for l, i in st.languages {
			if l.code == lang || (len(lang) == 2 && len(l.code) >= 2 && l.code[:2] == lang) {
				pick_language(st, i)
			}
		}
	}

	cfg := p.Config {
		title      = "Install Palmframe",
		app_id     = "palmframe-installer",
		width      = 1280,
		height     = 800,
		min_width  = 960,
		min_height = 640,
		root_class = "w-full h-full bg-background text-foreground",
	}
	app, err := kit.start(cfg)
	if err != "" {
		fmt.eprintfln("installer: %s", err)
		os.exit(1)
	}
	defer p.destroy(app)
	register_dark_theme()
	// wm --kiosk fills the output with its first client whatever it asks
	// for; asking for fullscreen as well covers any other compositor.
	p.set_fullscreen(app, true)

	for ui in p.frames(app) {
		draw(st, ui)
	}
}

// choose_mode returns true for demo. Real mode needs all of: no --demo, root,
// and a Palmframe system underneath. A developer who runs the binary on
// their own desktop, even as root, gets the demo.
choose_mode :: proc(want_demo: bool) -> bool {
	if want_demo {
		return true
	}
	if linux.geteuid() != 0 {
		fmt.eprintln("installer: not running as root; starting in demo mode (nothing will be changed)")
		return true
	}
	if !os.exists("/etc/palm/keys") {
		fmt.eprintln("installer: this is not a Palmframe system; starting in demo mode (nothing will be changed)")
		return true
	}
	return false
}
