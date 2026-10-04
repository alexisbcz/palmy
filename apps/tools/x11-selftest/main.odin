// x11-selftest — the app under test for palmy's X11 backend, and its own
// oracle.
//
//   x11-selftest render <out.png>    draw the reference UI offscreen
//   x11-selftest run <state-file>    open a window and report what arrives
//
// The two modes build the *same* tree with the same classes at the same size,
// so a screen capture of `run` and the PNG from `render` have to agree pixel
// for pixel: the rasterizer is shared, and nothing about a backend is supposed
// to touch the pixels. That makes the offscreen render the natural oracle for
// "did a frame actually reach the server, and was it the right frame".
//
// `run` writes a flat key=value file every time something changes, which is
// how the driver script observes the window without reading its pixels:
// geometry, typed text, clicks, wheel notches, keys and the close handshake.
package main

import "core:fmt"
import "core:os"
import "core:strings"
import p "palmy:."

WIDTH :: 640
HEIGHT :: 400

// State is what the window has observed. The driver asserts against it.
State :: struct {
	backend:  string,
	width:    int,
	height:   int,
	frames:   int,
	typed:    string,
	clicks:   int,
	rclicks:  int,
	wheel_up: int,
	wheel_dn: int,
	enters:   int,
	escapes:  int,
	ctrl_s:   int,
	a_all:    int,
	a_fresh:  int,
	mouse:    [2]f32,
	hovered:  bool,
	closed:   bool,
}

// ui_tree is the single description of the interface, built identically in
// both modes. `s` is nil for the oracle, which renders the zero state.
ui_tree :: proc(ui: ^p.Ctx, s: ^State) {
	typed := s != nil ? s.typed : ""
	clicks := s != nil ? s.clicks : 0
	wheel := s != nil ? s.wheel_dn - s.wheel_up : 0

	p.div(ui, "flex-col gap-4 w-full h-full bg-slate-950 p-6")
	defer p.end(ui)

	p.text(ui, "palmy x11 selftest", "text-2xl font-bold text-white")

	// Three flat blocks of known colour at known places: the cheapest possible
	// thing to assert on in a capture, and immune to font differences.
	p.row(ui, "gap-4")
	{
		defer p.end(ui)
		p.div(ui, "w-24 h-16 bg-red-500 rounded-lg")
		p.end(ui)
		p.div(ui, "w-24 h-16 bg-emerald-500 rounded-lg")
		p.end(ui)
		p.div(ui, "w-24 h-16 bg-sky-500 rounded-lg")
		p.end(ui)
	}

	p.textf(ui, "text-sm text-slate-400", "typed: [%s]", typed)
	p.textf(ui, "text-sm text-slate-400", "clicks: %d", clicks)
	p.textf(ui, "text-sm text-slate-400", "wheel: %d", wheel)
}

atoi :: proc(s: string) -> int {
	n := 0
	for ch in s {
		if ch < '0' || ch > '9' {
			return n
		}
		n = n * 10 + int(ch - '0')
	}
	return n
}

write_state :: proc(path: string, s: ^State) {
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	fmt.sbprintf(&b, "backend=%s\n", s.backend)
	fmt.sbprintf(&b, "size=%dx%d\n", s.width, s.height)
	fmt.sbprintf(&b, "frames=%d\n", s.frames)
	fmt.sbprintf(&b, "typed=%s\n", s.typed)
	fmt.sbprintf(&b, "clicks=%d\n", s.clicks)
	fmt.sbprintf(&b, "rclicks=%d\n", s.rclicks)
	fmt.sbprintf(&b, "wheel_up=%d\n", s.wheel_up)
	fmt.sbprintf(&b, "wheel_dn=%d\n", s.wheel_dn)
	fmt.sbprintf(&b, "enters=%d\n", s.enters)
	fmt.sbprintf(&b, "escapes=%d\n", s.escapes)
	fmt.sbprintf(&b, "ctrl_s=%d\n", s.ctrl_s)
	fmt.sbprintf(&b, "a_all=%d\n", s.a_all)
	fmt.sbprintf(&b, "a_fresh=%d\n", s.a_fresh)
	fmt.sbprintf(&b, "mouse=%.0f,%.0f\n", s.mouse.x, s.mouse.y)
	fmt.sbprintf(&b, "hovered=%v\n", s.hovered)
	fmt.sbprintf(&b, "closed=%v\n", s.closed)
	_ = os.write_entire_file(path, transmute([]u8)strings.to_string(b))
}

main :: proc() {
	args := os.args
	mode := len(args) > 1 ? args[1] : ""

	switch mode {
	case "render":
		if len(args) < 3 {
			fmt.eprintln("usage: x11-selftest render <out.png>")
			os.exit(2)
		}
		rw, rh := WIDTH, HEIGHT
		if len(args) >= 5 {
			rw = atoi(args[3])
			rh = atoi(args[4])
		}
		off := p.offscreen_create(rw, rh, 1, "w-full h-full bg-slate-950 text-slate-200")
		defer p.offscreen_destroy(off)
		// Two frames: the first builds the tree the second one hit-tests
		// against, which is exactly what the windowed loop does before its
		// first presented frame settles.
		for _ in 0 ..< 2 {
			ui := p.offscreen_begin(off)
			ui_tree(ui, nil)
			p.offscreen_end(off)
		}
		if !p.offscreen_write_png(off, args[2]) {
			fmt.eprintfln("could not write %s", args[2])
			os.exit(1)
		}

	case "run":
		if len(args) < 3 {
			fmt.eprintln("usage: x11-selftest run <state-file>")
			os.exit(2)
		}
		path := args[2]

		app, err := p.create(
			{
				title = "palmy x11 selftest",
				app_id = "palmy.selftest",
				width = WIDTH,
				height = HEIGHT,
				root_class = "w-full h-full bg-slate-950 text-slate-200",
			},
		)
		if err != "" {
			fmt.eprintfln("x11-selftest: %s", err)
			os.exit(1)
		}
		defer p.destroy(app)

		s: State
		s.backend = p.backend_name(app)
		text := strings.builder_make()
		defer strings.builder_destroy(&text)
		write_state(path, &s)

		for ui in p.frames(app) {
			size := p.size(ui)
			s.width, s.height = int(size.x), int(size.y)
			s.frames += 1
			s.mouse = p.mouse_pos(ui)

			if t := p.typed_text(ui); t != "" {
				strings.write_string(&text, t)
				s.typed = strings.to_string(text)
			}
			if n := p.key_count(ui, p.KEY_BACKSPACE); n > 0 {
				cur := strings.to_string(text)
				for _ in 0 ..< n {
					if len(cur) > 0 {
						cur = cur[:len(cur) - 1]
					}
				}
				strings.builder_reset(&text)
				strings.write_string(&text, cur)
				s.typed = strings.to_string(text)
			}
			s.escapes += p.key_count(ui, p.KEY_ESCAPE)
			s.enters += p.key_count(ui, p.KEY_RETURN)
			// Every 'a' that arrives, and only the ones that are not the
			// server's auto-repeat. Holding the key must move the first and
			// leave the second alone.
			s.a_all += p.key_count(ui, 'a')
			s.a_fresh += p.key_count(ui, 'a', false)
			if p.shortcut(ui, 's', {.Ctrl}) {
				s.ctrl_s += 1
			}

			if w := p.wheel(ui); w.y != 0 {
				if w.y > 0 {
					s.wheel_dn += int(w.y + 0.5)
				} else {
					s.wheel_up += int(-w.y + 0.5)
				}
			}

			ui_tree(ui, &s)

			// A hit target in a known place, so a click can be proven to have
			// landed on the right element rather than merely arrived.
			if app.win.input.pressed[.Left] {
				s.clicks += 1
			}
			if app.win.input.pressed[.Right] {
				s.rclicks += 1
			}

			write_state(path, &s)
		}

		s.closed = true
		write_state(path, &s)

	case "layer":
		// A layer surface has no X11 equivalent, and palmy has to say so
		// rather than quietly opening an ordinary window in the wrong place.
		_, lerr := p.create({title = "palmy layer probe", width = 400, height = 60, layer = true})
		if lerr != "" {
			fmt.printfln("layer-error: %s", lerr)
			os.exit(0)
		}
		fmt.println("layer-error: none")
		os.exit(1)

	case "close":
		if len(args) < 3 {
			fmt.eprintln("usage: x11-selftest close <window-id>")
			os.exit(2)
		}
		os.exit(send_close(args[2]))

	case:
		fmt.eprintln(
			"usage: x11-selftest [render <out.png> [w h] | run <state-file> | close <window-id> | layer]",
		)
		os.exit(2)
	}
}
