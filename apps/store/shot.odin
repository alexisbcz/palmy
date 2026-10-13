package main

// `store --shots <dir>`: every view of Software, rendered offscreen to PNGs.
//
// It runs on the demo catalogue (demo.odin) and the stand-in palmd, never
// on the machine it runs on: no palm is executed, no socket is opened. The
// pictures are driven through the same frame code the window runs, with the
// same clicks and keys a person would use where that is practical, and by
// setting the state directly where a click would need pixel coordinates.

import "core:fmt"
import "core:os"
import "core:strings"
import kit "kit:."
import p "palmy:."
import sc "shadcn:."

shots :: proc(dir: string) -> int {
	if err := os.make_directory_all(dir, os.perm(0o755)); err != nil && !os.exists(dir) {
		fmt.eprintfln("store: could not create %s", dir)
		return 1
	}
	off := p.offscreen_create(WIN_W, WIN_H, 1, "w-full h-full flex-col bg-background text-foreground overflow-hidden")
	defer p.offscreen_destroy(off)
	shot_fonts(&off.fonts)
	sc.register_shadcn_theme(false)
	p.set_text_gamma(1.8)
	p.register_color("selection", p.hex(SELECTION))

	st := new(State)
	st.demo = true
	state_init(st)

	// Twenty frames lets the sidebar's colour transitions settle, so a
	// picture shows where the view is rather than the fade between two.
	step :: proc(off: ^p.Offscreen, st: ^State, n := 20) {
		for _ in 0 ..< n {
			ui := p.offscreen_begin(off)
			tick(ui, st)
			handle_keys(ui, st)
			frame(ui, st)
			p.offscreen_end(off)
		}
	}
	count := 0
	shot :: proc(off: ^p.Offscreen, dir, name: string, n: ^int) {
		out := fmt.tprintf("%s/%s.png", dir, name)
		if p.offscreen_write_png(off, out) {
			n^ += 1
			fmt.printfln("  %s", out)
		}
	}

	// Discover: Featured, then every shelf.
	step(off, st)
	shot(off, dir, "01-discover", &count)

	// Discover scrolled, so the lower shelves are seen too.
	p.move_pointer(off, 700, 500)
	for _ in 0 ..< 12 {
		p.scroll_by(off, 0, 40)
		step(off, st, 1)
	}
	p.move_pointer(off, -10, -10)
	step(off, st)
	shot(off, dir, "02-discover-scrolled", &count)

	// One category.
	go(st, {view = .Category, category = "Office"})
	step(off, st)
	shot(off, dir, "03-category", &count)

	// Live search: "/" focuses the field, then typing filters.
	p.press_key(off, '/')
	step(off, st, 1)
	p.type_text(off, "ed")
	step(off, st)
	shot(off, dir, "04-search", &count)
	p.press_key(off, p.KEY_ESCAPE)
	step(off, st)

	// Installed: what you asked for, then everything.
	go(st, {view = .Installed})
	step(off, st)
	shot(off, dir, "05-installed", &count)
	st.installed_all = true
	step(off, st)
	shot(off, dir, "06-installed-everything", &count)
	st.installed_all = false

	// Updates.
	go(st, {view = .Updates})
	step(off, st)
	shot(off, dir, "07-updates", &count)

	// A package page: installed, with an update, required by palmframe.
	open_package(st, "term")
	step(off, st)
	shot(off, dir, "08-package-installed", &count)

	// A package that is not installed: Install, and files on request.
	open_package(st, "emoji")
	step(off, st)
	shot(off, dir, "09-package-available", &count)
	demo_files(find(&st.cat, "emoji"))

	// Install: the plan, as palmd would return it.
	start_change(st, .Add, "emoji")
	step(off, st)
	shot(off, dir, "10-plan-install", &count)

	// Confirmed: palm working. Enter is the confirm key.
	p.press_key(off, p.KEY_RETURN)
	step(off, st, 20)
	shot(off, dir, "11-progress", &count)

	// Done.
	step(off, st, 90)
	shot(off, dir, "12-done", &count)
	p.press_key(off, p.KEY_RETURN)
	step(off, st)

	// The page again: installed now, with Remove and Open.
	step(off, st)
	shot(off, dir, "13-package-now-installed", &count)

	// Remove something you installed: a destructive plan.
	open_package(st, "track")
	start_change(st, .Del, "track")
	step(off, st)
	shot(off, dir, "14-plan-remove", &count)
	p.press_key(off, p.KEY_ESCAPE)
	step(off, st)

	// Update all, from Updates.
	go(st, {view = .Updates})
	start_change(st, .Upgrade)
	step(off, st)
	shot(off, dir, "15-plan-upgrade", &count)
	p.press_key(off, p.KEY_ESCAPE)
	step(off, st)

	// A failure, worded the way palm words it.
	txn_reset(&st.txn)
	st.txn.action = .Add
	st.txn.packages = clone_strings({"shop"})
	txn_fail(&st.txn, "shop-0.1.0-r0.palm: sha256 mismatch -- the file does not match the signed index (want 3f1c…e09a, got 77b2…41d0); refusing", 4)
	step(off, st)
	shot(off, dir, "16-error", &count)
	txn_reset(&st.txn)

	// Refused by palmd: not in wheel.
	st.txn.action = .Add
	st.txn.packages = clone_strings({"shop"})
	txn_fail(&st.txn, "palmd: only root and members of group wheel may change the system", 4)
	step(off, st)
	shot(off, dir, "17-denied", &count)
	txn_reset(&st.txn)

	fmt.printfln("store --shots: %d PNGs in %s", count, dir)
	_ = strings.clone
	return 0
}

// shot_fonts loads the faces exactly as kit.start does.
shot_fonts :: proc(fonts: ^p.Fonts) {
	for pair in ([?]struct {
		file: string,
		wt:   p.Font_Weight,
	}{{"Geist-400.ttf", .Regular}, {"Geist-500.ttf", .Medium}, {"Geist-600.ttf", .Semibold}, {"Geist-700.ttf", .Bold}}) {
		p.load_font(fonts, fmt.tprintf("%s/%s", kit.FONT_DIR, pair.file), .Sans, pair.wt)
	}
	for wt in p.Font_Weight {
		p.use_synthetic_italic(fonts, .Sans, wt)
	}
	for path in ([?]string{"/usr/share/fonts/TTF/JetBrainsMonoNerdFont-Regular.ttf", "/usr/share/fonts/TTF/DejaVuSansMono.ttf", "/usr/share/fonts/liberation/LiberationMono-Regular.ttf"}) {
		if p.load_font(fonts, path, .Mono, .Regular) {
			p.load_font(fonts, path, .Mono, .Medium)
			p.load_font(fonts, path, .Mono, .Semibold)
			p.load_font(fonts, path, .Mono, .Bold)
			break
		}
	}
}
