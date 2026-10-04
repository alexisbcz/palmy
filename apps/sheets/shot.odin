// `sheets --shot out.png [steps...]` renders the real interface through
// palmy's offscreen path and saves a PNG. No compositor, no window manager,
// no other application's windows in the frame — which is what makes it
// usable for checking the layout while building it.
//
// Steps drive the same keyboard handler the window does:
//   t:<text>   type it      k:<key>   press it      c:<key>  with Ctrl
//   s:<key>    with Shift   a:<key>   with Alt      C:<key>  Ctrl+Shift
//   A:<key>    Alt+Shift    .         one idle frame
package main

import "core:fmt"
import "core:os"
import "core:strings"
import p "palmy:."
import sc "shadcn:."

SHOT_W :: 1240
SHOT_H :: 760

key_sym :: proc(name: string) -> u32 {
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
	case "Delete":
		return p.KEY_DELETE
	case "BackSpace":
		return p.KEY_BACKSPACE
	case "Home":
		return p.KEY_HOME
	case "End":
		return p.KEY_END
	case "PageUp":
		return p.KEY_PAGE_UP
	case "PageDown":
		return p.KEY_PAGE_DOWN
	case "F1":
		return p.KEY_F1
	case "F2":
		return p.KEY_F2
	case "F10":
		return KEY_F10
	}
	if len(name) > 0 {
		return u32(name[0])
	}
	return 0
}

// film_mode is `--shot` with the shutter left open: one PNG per step, from a
// single run, so a sequence of frames can be stitched into a demo without a
// compositor. It exists because palmy's Wayland keyboard currently delivers
// one key event per window and then goes silent (see the report), which makes
// a recorded take impossible — while the offscreen path drives exactly the
// same `handle_keys` and `frame` code.
film_mode :: proc(args: []string) -> int {
	if len(args) == 0 {
		fmt.eprintln("sheets --film <out-prefix> [steps...]")
		return 1
	}
	return shot_run(args, true)
}

shot_mode :: proc(args: []string) -> int {
	if len(args) == 0 {
		fmt.eprintln("sheets --shot <out.png> [steps...]")
		return 1
	}
	return shot_run(args, false)
}

shot_run :: proc(args: []string, film: bool) -> int {
	out := args[0]

	off := p.offscreen_create(
		SHOT_W,
		SHOT_H,
		1,
		"w-full h-full bg-background text-foreground",
	)
	defer p.offscreen_destroy(off)

	load_sans(&off.fonts)
	load_italics(&off.fonts)

	sc.register_shadcn_theme()
	p.set_text_gamma(1.8)

	app := new(App)
	defer free(app)
	app_init(app)
	defer app_destroy(app)
	app.fonts = &off.fonts
	app.pal = palette_build()
	app.name = strings.clone("Untitled")
	seed_demo(app)

	run_frame :: proc(off: ^p.Offscreen, app: ^App) {
		ui := p.offscreen_begin(off)
		measure_viewport(app, p.size(ui))
		handle_keys(ui, app)
		frame(ui, app)
		p.offscreen_end(off)
	}

	shot_n := 0
	emit :: proc(off: ^p.Offscreen, prefix: string, n: ^int) -> bool {
		path := fmt.tprintf("%s-%04d.png", prefix, n^)
		n^ += 1
		return p.offscreen_write_png(off, path)
	}

	run_frame(off, app) // settle the first layout
	if film {
		emit(off, out, &shot_n)
	}
	for step in args[1:] {
		if step == "." {
			run_frame(off, app)
			if film {
				emit(off, out, &shot_n)
			}
			continue
		}
		if len(step) < 2 || step[1] != ':' {
			continue
		}
		body := step[2:]
		// A shifted letter arrives from xkb as the capital, so the harness
		// has to shift it too or `Ctrl+Shift+O` would never match.
		shifted := step[0] == 's' || step[0] == 'C' || step[0] == 'A'
		if shifted && len(body) == 1 && body[0] >= 'a' && body[0] <= 'z' {
			body = fmt.tprintf("%c", rune(body[0] - 32))
		}
		switch step[0] {
		case 't':
			p.type_text(off, body)
		case 'k':
			p.press_key(off, key_sym(body))
		case 'c':
			p.press_key(off, key_sym(body), {.Ctrl})
		case 's':
			p.press_key(off, key_sym(body), {.Shift})
		case 'a':
			p.press_key(off, key_sym(body), {.Alt})
		case 'C':
			p.press_key(off, key_sym(body), {.Ctrl, .Shift})
		case 'A':
			p.press_key(off, key_sym(body), {.Alt, .Shift})
		}
		run_frame(off, app)
		off.input.mods = {}
		if film {
			emit(off, out, &shot_n)
		}
	}
	run_frame(off, app)
	if film {
		emit(off, out, &shot_n)
		fmt.printfln("wrote %d frames to %s-NNNN.png (%dx%d)", shot_n, out, SHOT_W, SHOT_H)
		return 0
	}

	if !p.offscreen_write_png(off, out) {
		fmt.eprintfln("sheets: could not write %s", out)
		return 1
	}
	fmt.printfln("wrote %s (%dx%d)", out, SHOT_W, SHOT_H)
	return 0
}

_ :: os
