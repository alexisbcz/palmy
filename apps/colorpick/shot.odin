// `colorpick --shots <dir>`: render the colour editor offscreen and write PNGs.
//
// No compositor, no window — and, the part that matters here, no `grim`. The
// windowed app can read a pixel out of a capture of the whole screen, which is
// a picture of whatever the user happens to have open. The shot path never
// takes that capture: the screen-picking view is rendered over a synthetic
// image computed in `shot_capture` below, and the saved palette is fabricated
// here rather than loaded from the user's. `HOME` is redirected to a scratch
// directory as a second line of defence, so no stray save can reach the real
// palette file either.
package main

import "core:fmt"
import "core:os"
import "core:strings"
import kit "kit:."
import p "palmy:."
import sc "shadcn:."

// shot_fonts loads exactly what `kit.start` loads into a window.
@(private = "file")
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
	register_dark_theme()
}

// shot_capture invents the image the picker magnifies. `grim` is never run and
// the compositor is never asked for anything: every pixel below is computed.
// It is drawn to look like a desktop only so the loupe and the crosshair have
// edges and flat colour fields to land on, which is what the view is for.
@(private = "file")
shot_capture :: proc(w, h: int) -> p.Image {
	img := p.Image {
		px              = make([]u32, w * h),
		w               = w,
		h               = h,
		source_channels = 3,
	}
	put :: proc(img: ^p.Image, x, y: int, r, g, b: u32) {
		if x < 0 || y < 0 || x >= img.w || y >= img.h {
			return
		}
		img.px[y * img.w + x] = 0xff00_0000 | (min(r, 255) << 16) | (min(g, 255) << 8) | min(b, 255)
	}
	box :: proc(img: ^p.Image, x0, y0, bw, bh: int, r, g, b: u32) {
		for y in y0 ..< y0 + bh {
			for x in x0 ..< x0 + bw {
				put(img, x, y, r, g, b)
			}
		}
	}

	// A diagonal wallpaper wash.
	for y in 0 ..< h {
		fy := f32(y) / f32(h)
		for x in 0 ..< w {
			fx := f32(x) / f32(w)
			t := (fx + fy) * 0.5
			put(&img, x, y, u32(18 + 40 * t), u32(24 + 70 * (1 - t)), u32(46 + 120 * t))
		}
	}
	// A top bar.
	box(&img, 0, 0, w, h / 24, 16, 18, 24)
	// Two flat panels, the sort of thing a pixel is usually picked out of.
	box(&img, w / 12, h / 6, w / 3, h / 2, 0x7c, 0x3a, 0xed)
	box(&img, w / 12 + 24, h / 6 + 24, w / 3 - 48, h / 8, 0xf5, 0xf5, 0xf5)
	box(&img, w / 2, h / 4, w / 3, h / 3, 0x0e, 0xa5, 0xe9)
	box(&img, w / 2 + 30, h / 4 + 30, 120, 120, 0xf5, 0x9e, 0x0b)
	box(&img, w / 2 + 180, h / 4 + 30, 120, 120, 0x10, 0xb9, 0x81)
	// A strip of swatches along the bottom.
	swatches := [?][3]u32 {
		{0xef, 0x44, 0x44},
		{0xf9, 0x73, 0x16},
		{0xea, 0xb3, 0x08},
		{0x22, 0xc5, 0x5e},
		{0x06, 0xb6, 0xd4},
		{0x34, 0x65, 0xf1},
		{0xa8, 0x55, 0xf7},
		{0xec, 0x48, 0x99},
	}
	sw := w / len(swatches)
	for c, i in swatches {
		box(&img, i * sw, h - h / 7, sw, h / 7, c[0], c[1], c[2])
	}
	return img
}

shots :: proc(dir: string) -> int {
	if err := os.make_directory_all(dir, os.perm(0o700)); err != nil && !os.exists(dir) {
		fmt.eprintfln("colorpick: cannot create %s", dir)
		return 1
	}

	// `g_test` keeps any copy off `wl-copy`; the scratch HOME keeps any save
	// off the user's palette file. `load_palette` is never called.
	g_test = true
	scratch := strings.clone(fmt.tprintf("%s/colorpick-shot-home", dir))
	defer delete(scratch)
	_ = os.make_directory_all(scratch)
	_ = os.set_env("HOME", scratch)
	// The scratch home exists only so a stray save has somewhere harmless to
	// go; nothing should ever be written into it.
	defer _ = os.remove_all(scratch)

	off := p.offscreen_create(
		WIN_W,
		WIN_H,
		1,
		"w-full h-full flex-col bg-background text-foreground overflow-hidden",
	)
	defer p.offscreen_destroy(off)
	shot_fonts(off)

	st := St {
		rgb       = {0x7c / 255.0, 0x3a / 255.0, 0xed / 255.0},
		zoom      = 14,
		have_clip = true,
		have_grim = true, // the badge only; grim is never invoked here
		have_hypr = true,
		palette   = make([dynamic][3]u8),
	}
	defer delete(st.palette)
	for i in 0 ..< FIELD_N {
		st.bufs[i] = make([dynamic]u8)
	}
	defer for i in 0 ..< FIELD_N {
		delete(st.bufs[i])
	}
	// A fabricated palette, written out here. Nothing is read from disk.
	for c in ([?][3]u8 {
		{0x7c, 0x3a, 0xed},
		{0x0e, 0xa5, 0xe9},
		{0x10, 0xb9, 0x81},
		{0xf5, 0x9e, 0x0b},
		{0xef, 0x44, 0x44},
		{0xec, 0x48, 0x99},
		{0x64, 0x74, 0x8b},
		{0xfa, 0xfa, 0xfa},
	}) {
		append(&st.palette, c)
	}
	resync(&st, .Hex)
	st.hex_caret = len(st.bufs[0])

	step :: proc(off: ^p.Offscreen, st: ^St) {
		ui := p.offscreen_begin(off)
		handle_keys(ui, nil, st)
		switch st.mode {
		case .Editor:
			build_editor(ui, st)
		case .Screen:
			build_screen(ui, st)
		}
		p.offscreen_end(off)
		off.input.mods = {}
	}

	shot :: proc(off: ^p.Offscreen, dir, name: string) {
		// Not tprintf: `offscreen_end` frees the temp allocator between frames.
		out := fmt.aprintf("%s/%s.png", dir, name)
		defer delete(out)
		if !p.offscreen_write_png(off, out) {
			fmt.eprintfln("colorpick: cannot write %s", out)
			return
		}
		fmt.printfln("  %s (%dx%d)", out, WIN_W, WIN_H)
	}

	step(off, &st) // settle the first layout
	step(off, &st)
	shot(off, dir, "app-colorpick")

	// Down to the OKLCH lightness field and nudge it, so the spinner, the
	// derived fields and the contrast card are all visibly live.
	for _ in 0 ..< 7 {
		p.press_key(off, p.KEY_DOWN)
		step(off, &st)
	}
	for _ in 0 ..< 3 {
		p.press_key(off, p.KEY_RIGHT, {.Shift})
		step(off, &st)
	}
	step(off, &st)
	shot(off, dir, "02-colorpick-oklch")

	// The palette strip, focused.
	p.press_key(off, p.KEY_TAB)
	step(off, &st)
	p.press_key(off, p.KEY_RIGHT)
	step(off, &st)
	p.press_key(off, p.KEY_RIGHT)
	step(off, &st)
	step(off, &st)
	shot(off, dir, "03-colorpick-palette")

	// The screen-picking view, over the invented capture above. `grim` is not
	// run; `st.mode` is set directly rather than through F2 precisely so that
	// no capture of the real screen can happen.
	st.pane = .Fields
	st.shot.img = shot_capture(1280, 800)
	st.shot.ok = true
	st.shot.path = strings.clone("/var/tmp/palmy-colorpick/capture.png")
	// On the corner of one of the invented panels, so the loupe shows an edge
	// rather than a flat field — which is the case the magnifier exists for.
	st.px = 1280 / 2 + 31
	st.py = 800 / 4 + 31
	st.mode = .Screen
	defer {
		delete(st.shot.img.px)
		delete(st.shot.path)
	}
	step(off, &st)
	step(off, &st)
	shot(off, dir, "04-colorpick-screen")

	return 0
}
