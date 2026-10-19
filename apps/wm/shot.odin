package wm

// `wm --shots <dir>`: render the compositor's own output offscreen as PNGs.
//
// The window manager is the one application here that cannot be screenshotted
// by driving its own widgets, because it has none: everything inside a frame
// belongs to a client that connected over the socket. Offscreen there is no
// socket and there are no clients, so the surfaces are fabricated — an
// `img` buffer per window, painted with palmy's primitives exactly as a client
// would paint its own — and then handed to the real `draw`. The frames, the
// title bars, the focus ring, the shadows, the bar and the dock are all the
// compositor's own code paths, drawing real pixels it did not produce.

import "core:fmt"
import "core:os"
import "core:strings"
import kit "kit:."
import p "palmy:."

SHOT_W :: 1600
SHOT_H :: 940

shots :: proc(dir: string) -> int {
	if err := os.make_directory_all(dir, os.perm(0o700)); err != nil && !os.exists(dir) {
		fmt.eprintfln("wm: could not create %s", dir)
		return 1
	}

	off := p.offscreen_create(SHOT_W, SHOT_H, 1, "w-full h-full bg-background")
	defer p.offscreen_destroy(off)
	shot_fonts(&off.fonts)
	p.set_text_gamma(1.8)

	// `draw` takes an `^p.App` only for its font table and its fps readout.
	app := new(p.App)
	defer free(app)
	app.win.width, app.win.height, app.win.scale = SHOT_W, SHOT_H, 1
	app.fonts = off.fonts
	app.fps = 60

	cv := p.offscreen_canvas(off)

	s := &server
	s.out_w, s.out_h = SHOT_W, SHOT_H
	s.path = "/run/user/1000/wayland-palmy"
	s.display_name = "wayland-palmy"

	// Four clients, so the bar's client count is not a lie about the picture.
	for _ in 0 ..< 4 {
		append(&s.clients, new(Client))
	}

	editor := fake_window(s, "renderer.odin — Codex", "codex", 60, 120, 700, 520, paint_editor)
	term := fake_window(s, "shellward: ~/src/palmy", "foot", 540, 330, 620, 400, paint_term)
	gallery := fake_window(s, "Tessera — Library", "tessera", 820, 110, 680, 450, paint_gallery)
	meter := fake_window(s, "Sentinel", "sentinel", 240, 560, 420, 300, paint_meter)
	meter.minimized = true

	s.focus = gallery
	gallery.activated = true

	n := 0
	shot :: proc(off: ^p.Offscreen, dir, name: string, n: ^int) {
		out := fmt.tprintf("%s/%s.png", dir, name)
		if p.offscreen_write_png(off, out) {
			n^ += 1
			fmt.printfln("  %s", out)
		}
	}

	step :: proc(s: ^Server, app: ^p.App, cv: ^p.Canvas) {
		draw(s, app, cv)
		free_all(context.temp_allocator)
	}

	// Three framed clients, one minimised to the dock, the top one focused.
	step(s, app, cv)
	step(s, app, cv)
	shot(off, dir, "app-wm", &n)

	// Hovering the close button of an unfocused window: the frame buttons
	// light up per-window, which is most of what a title bar has to get right.
	s.hover_t = editor
	s.hover_btn = 1
	step(s, app, cv)
	step(s, app, cv)
	shot(off, dir, "02-wm-frame-hover", &n)

	// Window mode: F10 hands the keyboard to the compositor rather than the
	// focused client, and the bar says so.
	s.hover_t = nil
	s.hover_btn = 0
	s.wm_mode = true
	note(s, "focus → shellward: ~/src/palmy")
	s.focus = term
	gallery.activated = false
	term.activated = true
	raise_window(s, term)
	step(s, app, cv)
	step(s, app, cv)
	shot(off, dir, "03-wm-window-mode", &n)

	// A maximised window, which is the geometry F11 produces. The real
	// `set_maximized` configures the client and waits for it to commit a new
	// buffer; a fabricated client commits by being repainted.
	s.wm_mode = false
	s.status = ""
	gallery.saved = {gallery.x, gallery.y, gallery.w, gallery.h}
	gallery.maximized = true
	gallery.x, gallery.y = BORDER, BAR_H + TITLE_H
	gallery.w = s.out_w - 2 * BORDER
	gallery.h = s.out_h - BAR_H - TITLE_H - BORDER
	gallery.req_w, gallery.req_h = gallery.w, gallery.h
	repaint(gallery, paint_gallery)
	raise_window(s, gallery)
	s.focus = gallery
	gallery.activated = true
	term.activated = false
	step(s, app, cv)
	step(s, app, cv)
	shot(off, dir, "04-wm-maximised", &n)

	// The start menu, the desktop menu and the power menu, dark and light
	// (shell_shot.odin), over the windows as they are.
	gallery.maximized = false
	gallery.x, gallery.y, gallery.w, gallery.h = gallery.saved[0], gallery.saved[1], gallery.saved[2], gallery.saved[3]
	repaint(gallery, paint_gallery)
	shell_shots(s, app, cv, off, dir, &n)

	// And the empty desktop, which is what a nested compositor shows before
	// anything has connected to it.
	clear(&s.stack)
	clear(&s.clients)
	s.focus = nil
	step(s, app, cv)
	step(s, app, cv)
	shot(off, dir, "05-wm-empty", &n)

	fmt.printfln("wm --shots: %d PNGs in %s", n, dir)
	return 0
}

// ---------------------------------------------------------------------------
// Fabricated clients
//
// A client is, to the compositor, a surface with a pixel buffer and a size.
// That is all these are: no socket, no protocol objects beyond the ones the
// drawing code dereferences.
// ---------------------------------------------------------------------------

Painter :: proc(cv: ^p.Canvas, f: ^p.Fonts, w, h: int)

shot_paint_fonts: p.Fonts

fake_window :: proc(
	s: ^Server,
	title, app_id: string,
	x, y, w, h: int,
	paint: Painter,
) -> ^Toplevel {
	surf := new(Surface)
	surf.id = u32(len(s.surfaces) + 1)
	surf.iw, surf.ih = w, h
	surf.scale = 1
	surf.opaque = true
	surf.img = make([]u32, w * h)
	surf.role = .Xdg
	append(&s.surfaces, surf)

	xdg := new(Xdg_Surface)
	xdg.surf = surf
	surf.xdg = xdg

	t := new(Toplevel)
	t.xdg = xdg
	t.title = strings.clone(title)
	t.app_id = strings.clone(app_id)
	t.x, t.y, t.w, t.h = x, y, w, h
	t.mapped = true
	t.client = len(s.clients) > 0 ? s.clients[0] : nil
	xdg.top = t
	append(&s.stack, t)

	repaint(t, paint)
	return t
}

// repaint re-renders a fabricated client at its current size, which is what a
// real one does when the compositor configures it.
repaint :: proc(t: ^Toplevel, paint: Painter) {
	surf := t.xdg.surf
	if surf.iw != t.w || surf.ih != t.h {
		delete(surf.img)
		surf.iw, surf.ih = t.w, t.h
		surf.img = make([]u32, t.w * t.h)
	}
	cv := p.canvas_from(surf.img, surf.iw, surf.ih)
	defer p.canvas_destroy(&cv)
	paint(&cv, &shot_paint_fonts, surf.iw, surf.ih)
}

paint_editor :: proc(cv: ^p.Canvas, f: ^p.Fonts, w, h: int) {
	W, H := f32(w), f32(h)
	p.fill_rect(cv, {0, 0, W, H}, p.hex(0x14141a))
	// Gutter.
	p.fill_rect(cv, {0, 0, 54, H}, p.hex(0x101016))
	// Tab strip.
	p.fill_rect(cv, {0, 0, W, 30}, p.hex(0x1b1b22))
	p.fill_rect(cv, {54, 0, 150, 30}, p.hex(0x14141a))
	p.fill_rect(cv, {54, 28, 150, 2}, p.hex(0x6366f1))
	p.draw_text(cv, f, "renderer.odin", 66, 20, 12, p.hex(0xe4e4e7), .Sans, .Medium)
	p.draw_text(cv, f, "shape.odin", 220, 20, 12, p.hex(0x71717a), .Sans)

	lines := [?]struct {
		indent: int,
		code:   string,
		col:    u32,
	} {
		{0, "draw_text :: proc(", 0x93c5fd},
		{1, "cv: ^Canvas,", 0xd4d4d8},
		{1, "f: ^Fonts,", 0xd4d4d8},
		{1, "text: string,", 0xd4d4d8},
		{1, "x, y, size: f32,", 0xd4d4d8},
		{1, "col: Color,", 0xd4d4d8},
		{0, ") -> f32 {", 0x93c5fd},
		{1, "// Lay the run out once, then blend each", 0x6b7280},
		{1, "// coverage mask into the canvas.", 0x6b7280},
		{1, "pen := x", 0xd4d4d8},
		{1, "for r in text {", 0xf9a8d4},
		{2, "g := glyph(f, r, size)", 0xd4d4d8},
		{2, "blend_mask(cv, g, pen, y, col)", 0xd4d4d8},
		{2, "pen += g.advance", 0xd4d4d8},
		{1, "}", 0xf9a8d4},
		{1, "return pen - x", 0xfcd34d},
		{0, "}", 0x93c5fd},
	}
	y := f32(52)
	for l, i in lines {
		num := fmt.tprintf("%d", i + 41)
		nw := p.text_width(f, num, 11, .Mono)
		p.draw_text(cv, f, num, 42 - nw, y, 11, p.hex(0x3f3f46), .Mono)
		p.draw_text(cv, f, l.code, 66 + f32(l.indent) * 18, y, 12.5, p.hex(l.col), .Mono)
		y += 20
	}
	// Caret.
	p.fill_rect(cv, {66 + 36, y - 20 - 11, 1.5, 15}, p.hex(0xe4e4e7))
	// Status strip.
	p.fill_rect(cv, {0, H - 22, W, 22}, p.hex(0x1b1b22))
	p.draw_text(cv, f, "odin  ·  ln 57, col 3  ·  spaces: 4", 10, H - 7, 11, p.hex(0x71717a), .Sans)
}

paint_term :: proc(cv: ^p.Canvas, f: ^p.Fonts, w, h: int) {
	W, H := f32(w), f32(h)
	p.fill_rect(cv, {0, 0, W, H}, p.hex(0x0c0c0e))
	lines := [?]struct {
		text: string,
		col:  u32,
	} {
		{"$ odin build apps/wm -o:speed", 0xa7f3d0},
		{"wm: listening on wayland-palmy", 0xa1a1aa},
		{"wm: keymap from host, 2411 keysyms", 0xa1a1aa},
		{"", 0xa1a1aa},
		{"$ wl-info | head", 0xa7f3d0},
		{"interface: wl_compositor   version 4", 0xd4d4d8},
		{"interface: wl_shm          version 1", 0xd4d4d8},
		{"interface: wl_seat         version 7", 0xd4d4d8},
		{"interface: xdg_wm_base     version 5", 0xd4d4d8},
		{"interface: zwlr_layer_shell_v1  version 4", 0xd4d4d8},
		{"", 0xa1a1aa},
		{"$ ", 0xa7f3d0},
	}
	y := f32(26)
	for l in lines {
		p.draw_text(cv, f, l.text, 14, y, 12.5, p.hex(l.col), .Mono)
		y += 19
	}
	p.fill_rect(cv, {14 + p.text_width(f, "$ ", 12.5, .Mono), y - 19 - 11, 8, 15}, p.hex(0xa7f3d0))
}

paint_gallery :: proc(cv: ^p.Canvas, f: ^p.Fonts, w, h: int) {
	W, H := f32(w), f32(h)
	p.fill_rect(cv, {0, 0, W, H}, p.hex(0xfafafa))
	p.fill_rect(cv, {0, 0, W, 40}, p.hex(0xffffff))
	p.fill_rect(cv, {0, 39, W, 1}, p.hex(0xe4e4e7))
	p.draw_text(cv, f, "Tessera", 16, 26, 14, p.hex(0x18181b), .Sans, .Semibold)
	p.draw_text(cv, f, "Library · sorted by date", 90, 26, 12, p.hex(0x71717a), .Sans)

	tints := [?]u32 {
		0xfca5a5,
		0xfdba74,
		0xfde047,
		0x86efac,
		0x67e8f9,
		0x93c5fd,
		0xc4b5fd,
		0xf0abfc,
		0xa3e635,
		0x5eead4,
		0xfda4af,
		0xcbd5e1,
	}
	cols := max(3, int(W / 160))
	pad := f32(14)
	tw := (W - pad * f32(cols + 1)) / f32(cols)
	th := tw * 0.66
	i := 0
	for {
		cx := pad + f32(i % cols) * (tw + pad)
		cy := 54 + f32(i / cols) * (th + pad)
		if cy + th > H - pad {
			break
		}
		p.fill_round_rect(cv, {cx, cy, tw, th}, {8, 8, 8, 8}, p.hex(tints[i % len(tints)]))
		// A horizon, so each tile reads as a picture rather than a swatch.
		p.push_clip(cv, {cx, cy, tw, th})
		p.fill_rect(cv, {cx, cy + th * 0.62, tw, th * 0.38}, p.hexa(0x00000022))
		p.fill_circle(cv, cx + tw * 0.74, cy + th * 0.3, th * 0.11, p.hexa(0xffffff88))
		p.pop_clip(cv)
		if i == 5 {
			p.stroke_round_rect(cv, p.rect_inset({cx, cy, tw, th}, -2.5), {10, 10, 10, 10}, 2.5, p.hex(0x6366f1))
		}
		i += 1
		if i >= 64 {
			break
		}
	}
}

paint_meter :: proc(cv: ^p.Canvas, f: ^p.Fonts, w, h: int) {
	W, H := f32(w), f32(h)
	p.fill_rect(cv, {0, 0, W, H}, p.hex(0x111116))
	p.draw_text(cv, f, "Sentinel", 16, 30, 14, p.hex(0xfafafa), .Sans, .Semibold)
	rows := [?]struct {
		label: string,
		frac:  f32,
		col:   u32,
	}{{"cpu", 0.42, 0x6366f1}, {"memory", 0.71, 0x22c55e}, {"swap", 0.08, 0xeab308}, {"disk", 0.55, 0xec4899}}
	y := f32(56)
	for r in rows {
		p.draw_text(cv, f, r.label, 16, y + 11, 12, p.hex(0xa1a1aa), .Sans)
		p.fill_round_rect(cv, {90, y, W - 110, 14}, {7, 7, 7, 7}, p.hex(0x27272a))
		p.fill_round_rect(cv, {90, y, (W - 110) * r.frac, 14}, {7, 7, 7, 7}, p.hex(r.col))
		y += 34
	}
}

// ---------------------------------------------------------------------------
// Fonts, exactly as `kit.start` loads them
// ---------------------------------------------------------------------------

shot_fonts :: proc(fonts: ^p.Fonts) {
	for pair in ([?]struct {
		file: string,
		wt:   p.Font_Weight,
	}{
		{"Geist-400.ttf", .Regular},
		{"Geist-500.ttf", .Medium},
		{"Geist-600.ttf", .Semibold},
		{"Geist-700.ttf", .Bold},
	}) {
		p.load_font(fonts, fmt.tprintf("%s/%s", kit.FONT_DIR, pair.file), .Sans, pair.wt)
	}
	for path in ([?]string {
		"/usr/share/fonts/TTF/JetBrainsMonoNerdFont-Regular.ttf",
		"/usr/share/fonts/TTF/DejaVuSansMono.ttf",
		"/usr/share/fonts/liberation/LiberationMono-Regular.ttf",
	}) {
		if p.load_font(fonts, path, .Mono, .Regular) {
			p.load_font(fonts, path, .Mono, .Medium)
			p.load_font(fonts, path, .Mono, .Semibold)
			p.load_font(fonts, path, .Mono, .Bold)
			break
		}
	}
	// The client painters get the same table; they are handed a plain
	// `^p.Fonts` because they are not drawing through a `^p.App`.
	shot_paint_fonts = fonts^
}
