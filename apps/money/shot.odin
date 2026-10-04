// `money --shot out.png [steps…]`: the real interface, rendered through
// palmy's offscreen path and written to a PNG.
//
// No compositor, no window manager, nothing on anybody's screen. The same
// tree, the same layout engine and the same rasterizer the window uses, so
// what the PNG shows is what the window would show — which is what makes it
// usable for checking that the French number formatting lines up and that the
// chart axes are readable, rather than merely present.
//
// Steps drive the same keyboard handler the window does:
//
//   t:<text>  type it        k:<Key>  press it       c:<Key>  with Ctrl
//   s:<Key>   with Shift     i:<path> import that file     .  one idle frame
package main

import "core:fmt"
import "core:os"
import "core:strings"
import kit "kit:."
import p "palmy:."
import sc "shadcn:."

SHOT_W :: 1360
SHOT_H :: 860

shot_key :: proc(name: string) -> u32 {
	switch name {
	case "Up":
		return p.KEY_UP
	case "Down":
		return p.KEY_DOWN
	case "Left":
		return p.KEY_LEFT
	case "Right":
		return p.KEY_RIGHT
	case "Return", "Enter":
		return p.KEY_RETURN
	case "Tab":
		return p.KEY_TAB
	case "Escape", "Esc":
		return p.KEY_ESCAPE
	case "BackSpace":
		return p.KEY_BACKSPACE
	case "Delete":
		return p.KEY_DELETE
	case "Home":
		return p.KEY_HOME
	case "End":
		return p.KEY_END
	case "PageUp":
		return p.KEY_PAGE_UP
	case "PageDown":
		return p.KEY_PAGE_DOWN
	}
	if len(name) > 0 {
		return u32(name[0])
	}
	return 0
}

shot_mode :: proc(args: []string) -> int {
	if len(args) == 0 {
		fmt.eprintln("money --shot <out.png> [steps...]")
		return 2
	}
	out := args[0]

	w := SHOT_W
	h := SHOT_H
	steps := args[1:]
	// An optional WxH before the steps.
	if len(steps) > 0 && strings.contains(steps[0], "x") && !strings.contains(steps[0], ":") {
		parts := strings.split(steps[0], "x", context.temp_allocator)
		if len(parts) == 2 {
			pw := 0
			ph := 0
			okw := true
			for ch in parts[0] {
				if ch < '0' || ch > '9' {okw = false;break}
				pw = pw * 10 + int(ch - '0')
			}
			for ch in parts[1] {
				if ch < '0' || ch > '9' {okw = false;break}
				ph = ph * 10 + int(ch - '0')
			}
			if okw && pw > 200 && ph > 200 {
				w = pw
				h = ph
				steps = steps[1:]
			}
		}
	}

	off := p.offscreen_create(w, h, 1, "w-full h-full bg-background text-foreground")
	defer p.offscreen_destroy(off)

	// The same fonts and the same calibration `kit.start` applies to a
	// window, because a screenshot in a different face proves nothing about
	// the application.
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
	for path in ([?]string {
		"/usr/share/fonts/TTF/JetBrainsMonoNerdFont-Regular.ttf",
		"/usr/share/fonts/TTF/DejaVuSansMono.ttf",
		"/usr/share/fonts/liberation/LiberationMono-Regular.ttf",
	}) {
		if p.load_font(&off.fonts, path, .Mono, .Regular) {
			p.load_font(&off.fonts, path, .Mono, .Medium)
			break
		}
	}
	sc.register_shadcn_theme(false)
	p.set_text_gamma(1.8)

	app := new(App)
	defer free(app)
	app_init(app)
	defer app_destroy(app)
	app.fonts = &off.fonts
	// A screenshot never reads the user's book: it is always the fictitious
	// demo data from fixtures.odin.
	seed_demo(app)

	run :: proc(off: ^p.Offscreen, app: ^App) {
		ui := p.offscreen_begin(off)
		frame(ui, app)
		p.offscreen_end(off)
	}

	run(off, app) // settle the first layout
	run(off, app)
	for step in steps {
		if step == "." {
			run(off, app)
			continue
		}
		if len(step) < 2 || step[1] != ':' {
			continue
		}
		body := step[2:]
		shifted := step[0] == 's'
		if shifted && len(body) == 1 && body[0] >= 'a' && body[0] <= 'z' {
			body = fmt.tprintf("%c", rune(body[0] - 32))
		}
		switch step[0] {
		case 'i':
			// An explicit import, named on the command line, which is the
			// same path the file dialog takes.
			do_import(app, body)
		case 't':
			p.type_text(off, body)
		case 'k':
			p.press_key(off, shot_key(body))
		case 'c':
			p.press_key(off, shot_key(body), {.Ctrl})
		case 's':
			p.press_key(off, shot_key(body), {.Shift})
		}
		run(off, app)
		off.input.mods = {}
	}
	run(off, app)

	if !p.offscreen_write_png(off, out) {
		fmt.eprintfln("money: cannot write %s", out)
		return 1
	}
	fmt.printfln("wrote %s (%dx%d)", out, w, h)
	return 0
}

_ :: os
