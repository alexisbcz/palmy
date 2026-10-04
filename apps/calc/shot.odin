// `calc --shots <dir>`: render the calculator offscreen and write PNGs.
//
// No compositor, no window, nothing on anybody's screen: the same tree, the
// same layout engine and the same rasterizer the window uses, driven through
// `palmy`'s offscreen path. It is the fast way to check that the display, the
// keypad and the history column actually line up, and the expressions are
// fixtures typed in here, so no session of the user's is ever in an image.
package main

import "core:fmt"
import "core:os"
import kit "kit:."
import p "palmy:."
import sc "shadcn:."

SHOT_W :: 1000
SHOT_H :: 700

// shot_fonts loads exactly what `kit.start` loads into a window, because a
// screenshot in a different face proves nothing about the application.
shot_fonts :: proc(off: ^p.Offscreen) {
	for pair in ([?]struct {
		file: string,
		wt:   p.Font_Weight,
	}{
		{"Geist-400.ttf", .Regular},
		{"Geist-500.ttf", .Medium},
		{"Geist-600.ttf", .Semibold},
		{"Geist-700.ttf", .Bold},
	}) {
		p.load_font(&off.fonts, fmt.tprintf("%s/%s", kit.FONT_DIR, pair.file), .Sans, pair.wt)
	}
	for wt in p.Font_Weight {
		p.use_synthetic_italic(&off.fonts, .Sans, wt)
	}
	for path in ([?]string {
		"/usr/share/fonts/TTF/JetBrainsMonoNerdFont-Regular.ttf",
		"/usr/share/fonts/TTF/DejaVuSansMono.ttf",
		"/usr/share/fonts/liberation/LiberationMono-Regular.ttf",
	}) {
		if p.load_font(&off.fonts, path, .Mono, .Regular) {
			p.load_font(&off.fonts, path, .Mono, .Medium)
			p.load_font(&off.fonts, path, .Mono, .Semibold)
			p.load_font(&off.fonts, path, .Mono, .Bold)
			break
		}
	}
	sc.register_shadcn_theme(false)
	p.set_text_gamma(1.8)
}

shots :: proc(dir: string) -> int {
	if err := os.make_directory_all(dir, os.perm(0o700)); err != nil && !os.exists(dir) {
		fmt.eprintfln("calc: cannot create %s", dir)
		return 1
	}

	off := p.offscreen_create(
		SHOT_W,
		SHOT_H,
		1,
		"w-full h-full flex-col bg-background text-foreground overflow-hidden",
	)
	defer p.offscreen_destroy(off)
	shot_fonts(off)
	p.register_color("accent-blue", p.hex(ACCENT))

	// The keyboard handler wants an `^p.App` only so Ctrl-Q can close the
	// window; offscreen never presses it, so a stand-in is enough.
	app := new(p.App)
	defer free(app)
	app.win.width, app.win.height = SHOT_W, SHOT_H
	app.fonts = off.fonts

	c := Calc {
		browse = -1,
	}
	c.vars = make(map[string]f64)
	set_var(&c, "ans", 0)
	recompute(&c)

	step :: proc(off: ^p.Offscreen, c: ^Calc, app: ^p.App) {
		ui := p.offscreen_begin(off)
		keys(ui, c, app)
		frame(ui, c)
		p.offscreen_end(off)
		off.input.mods = {}
	}

	shot :: proc(off: ^p.Offscreen, dir, name: string) {
		// Not tprintf: `offscreen_end` frees the temp allocator, so a path
		// built there and used after another frame would dangle.
		out := fmt.aprintf("%s/%s.png", dir, name)
		defer delete(out)
		if !p.offscreen_write_png(off, out) {
			fmt.eprintfln("calc: cannot write %s", out)
			return
		}
		fmt.printfln("  %s (%dx%d)", out, SHOT_W, SHOT_H)
	}

	// Type a worked session, through the same keyboard the window uses, so
	// the history column and the variables panel fill the way they really do.
	entries := [?]string{"2 * (3 + 4)^2", "r = 4.5", "area = pi * r^2", "sqrt(2) + ln(e^3)"}
	step(off, &c, app) // settle the first layout
	step(off, &c, app)
	for e in entries {
		p.type_text(off, e)
		step(off, &c, app)
		step(off, &c, app)
		p.press_key(off, p.KEY_RETURN)
		step(off, &c, app)
		step(off, &c, app)
	}

	// Leave an expression mid-flight so the live result is on screen too.
	p.type_text(off, "ans / 7 + 2^10")
	step(off, &c, app)
	step(off, &c, app)
	shot(off, dir, "app-calc")

	// The keypad, selected, with the pad pane focused.
	p.press_key(off, p.KEY_TAB)
	step(off, &c, app)
	for _ in 0 ..< 2 {
		p.press_key(off, p.KEY_DOWN)
		step(off, &c, app)
	}
	p.press_key(off, p.KEY_RIGHT)
	step(off, &c, app)
	step(off, &c, app)
	shot(off, dir, "02-calc-keypad")

	// The history pane, with an entry selected.
	p.press_key(off, p.KEY_TAB)
	step(off, &c, app)
	p.press_key(off, p.KEY_UP)
	step(off, &c, app)
	step(off, &c, app)
	shot(off, dir, "03-calc-history")

	// The help sheet.
	c.pane = .Input
	p.press_key(off, p.KEY_F1)
	step(off, &c, app)
	step(off, &c, app)
	shot(off, dir, "04-calc-help")

	clear_history(&c)
	return 0
}
