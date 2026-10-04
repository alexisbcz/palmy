package main

// Images in, images out.
//
// Going in: slide pictures are decoded through palmy's stb_image binding and
// cached by path, because a sorter strip redraws nine thumbnails a frame and
// decoding a JPEG nine times a frame is not a plan.
//
// Coming out: every slide renders to a PNG through exactly the renderer the
// editor draws with, plus a contact sheet of the whole deck. That is the
// clearest possible test of the renderer — a slide that exports wrong is a
// slide that was drawn wrong.

import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"
import kit "kit:."
import p "palmy:."

Img_Cache :: struct {
	m:    map[string]p.Image,
	root: string, // where relative paths are resolved from
}

img_cache_make :: proc(root: string) -> Img_Cache {
	return {m = make(map[string]p.Image), root = root}
}

// img_get decodes on first use and remembers failures as a zero image, so a
// missing file costs one stat rather than one per frame.
img_get :: proc(ic: ^Img_Cache, src: string) -> (img: p.Image, ok: bool) {
	if src == "" {
		return {}, false
	}
	if have, found := ic.m[src]; found {
		return have, have.w > 0
	}
	path := src
	if !strings.has_prefix(src, "/") {
		path = fmt.tprintf("%s/%s", ic.root, src)
	}
	got, good := p.load_image(path)
	if !good {
		ic.m[strings.clone(src)] = p.Image{}
		return {}, false
	}
	ic.m[strings.clone(src)] = got
	return got, true
}

// ---------------------------------------------------------------------------
// Rendering to a buffer
// ---------------------------------------------------------------------------

// render_slide_buffer renders one slide at an arbitrary pixel size.
render_slide_buffer :: proc(
	d: ^Deck,
	si: int,
	w, h: int,
	fonts: ^p.Fonts,
	imgs: ^Img_Cache,
	allocator := context.allocator,
) -> []u32 {
	px := make([]u32, w * h, allocator)
	c := p.canvas_from(px, w, h, 1)
	defer p.canvas_destroy(&c)
	draw_slide(
		&c,
		{0, 0, f32(w), f32(h)},
		d,
		si,
		{fonts = fonts, imgs = imgs, footer = true, number = si + 1, total = len(d.slides), selected = -1},
	)
	return px
}

// write_png turns palmy's XRGB buffer into the RGBA bytes stb expects.
write_png :: proc(path: string, px: []u32, w, h: int) -> bool {
	rgba := make([]u8, w * h * 4, context.temp_allocator)
	for i in 0 ..< w * h {
		v := px[i]
		rgba[i * 4 + 0] = u8(v >> 16)
		rgba[i * 4 + 1] = u8(v >> 8)
		rgba[i * 4 + 2] = u8(v)
		rgba[i * 4 + 3] = 255
	}
	return p.write_png_rgba(path, rgba, w, h)
}

EXPORT_W :: 1920
EXPORT_H :: 1080

// export_deck writes slide-01.png … slide-NN.png plus contact-sheet.png.
export_deck :: proc(d: ^Deck, dir: string, fonts: ^p.Fonts, imgs: ^Img_Cache) -> (n: int, err: string) {
	_ = os.make_directory_all(dir)
	for si in 0 ..< len(d.slides) {
		px := render_slide_buffer(d, si, EXPORT_W, EXPORT_H, fonts, imgs, context.temp_allocator)
		path := fmt.tprintf("%s/slide-%02d.png", dir, si + 1)
		if !write_png(path, px, EXPORT_W, EXPORT_H) {
			return n, fmt.tprintf("cannot write %s", path)
		}
		delete(px, context.temp_allocator)
		n += 1
	}
	if !contact_sheet(d, fmt.tprintf("%s/contact-sheet.png", dir), fonts, imgs) {
		return n, "contact sheet failed"
	}
	return n, ""
}

// contact_sheet lays every slide out on one page, numbered — the thing you
// actually print before a talk.
contact_sheet :: proc(d: ^Deck, path: string, fonts: ^p.Fonts, imgs: ^Img_Cache) -> bool {
	COLS :: 3
	TW :: 520
	TH :: TW * 9 / 16
	PAD :: 28
	LABEL :: 30
	rows := (len(d.slides) + COLS - 1) / COLS
	if rows == 0 {
		return false
	}
	w := COLS * TW + (COLS + 1) * PAD
	h := rows * (TH + LABEL) + (rows + 1) * PAD + 64

	px := make([]u32, w * h, context.temp_allocator)
	c := p.canvas_from(px, w, h, 1)
	defer p.canvas_destroy(&c)

	page := d.theme.dark ? p.hex(0x0a0a0a) : p.hex(0xf4f4f5)
	ink := d.theme.dark ? p.hex(0xf4f4f5) : p.hex(0x18181b)
	p.clear_canvas(&c, page)

	p.draw_text(&c, fonts, d.title, f32(PAD), 44, 26, ink, .Sans, .Bold)
	sub := fmt.tprintf("%d slides · %s", len(d.slides), d.theme.name)
	p.draw_text(&c, fonts, sub, f32(w - PAD) - p.text_width(fonts, sub, 15, .Sans, .Regular), 42, 15, p.fade(ink, 0.6), .Sans, .Regular)

	for si in 0 ..< len(d.slides) {
		col := si % COLS
		row := si / COLS
		x := f32(PAD + col * (TW + PAD))
		y := f32(64 + PAD + row * (TH + LABEL + PAD))
		p.drop_shadow(&c, {x, y, TW, TH}, {6, 6, 6, 6}, 18, 0, {0, 6}, p.hexa(0x00000066))
		draw_slide(
			&c,
			{x, y, TW, TH},
			d,
			si,
			{fonts = fonts, imgs = imgs, footer = false, thumb = true, selected = -1},
		)
		p.stroke_round_rect(&c, {x, y, TW, TH}, {6, 6, 6, 6}, 1, p.fade(ink, 0.18))
		label := fmt.tprintf("%d. %s", si + 1, LAYOUT_NAMES[d.slides[si].layout])
		p.draw_text(&c, fonts, label, x, y + TH + 20, 14, p.fade(ink, 0.65), .Sans, .Medium)
	}
	return write_png(path, px, w, h)
}

// ---------------------------------------------------------------------------
// Headless fonts
//
// Export can run without a window (`slides.bin --export DIR`), and a renderer
// with no fonts draws no text, so the same faces kit loads are loaded here.
// ---------------------------------------------------------------------------

fonts_headless :: proc(f: ^p.Fonts) {
	p.fonts_init(f)
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
	p.set_text_gamma(1.8)
}

// ---------------------------------------------------------------------------
// Generated assets
//
// The fixture deck ships with two pictures so that the image path is exercised
// by default rather than only when a user happens to have a photo handy. They
// are generated rather than committed as binaries: `--make-assets` writes them
// next to the binary, through the same PNG writer the exporter uses.
// ---------------------------------------------------------------------------

make_assets :: proc(dir: string) -> string {
	_ = os.make_directory_all(dir)

	// A vista: a graded sky, a low sun and three ridges of hills, drawn with
	// sine ridgelines. A picture with structure in it tells you whether the
	// sampler is working; a smooth gradient does not.
	{
		W :: 1400
		H :: 900
		px := make([]u32, W * H, context.temp_allocator)
		c := p.canvas_from(px, W, H, 1)
		defer p.canvas_destroy(&c)

		sky_top := p.hex(0x1b1038)
		sky_mid := p.hex(0x7c3f6b)
		sky_low := p.hex(0xf0885a)
		horizon := f32(H) * 0.62
		for y in 0 ..< H {
			t := f32(y) / horizon
			col := t < 1 ? p.mix(sky_top, p.mix(sky_mid, sky_low, clamp(t * t, 0, 1)), clamp(t, 0, 1)) : sky_low
			p.fill_rect(&c, {0, f32(y), W, 1}, col)
		}

		// The sun, with a soft halo built from concentric fades.
		sun_x := f32(W) * 0.68
		sun_y := horizon - 60
		for i := 46; i >= 1; i -= 1 {
			p.fill_circle(&c, sun_x, sun_y, 70 + f32(i) * 6.5, p.fade(p.hex(0xffd3a0), 0.011))
		}
		p.fill_circle(&c, sun_x, sun_y, 72, p.hex(0xffe9c9))

		// Ridges: furthest first, each a sine ridgeline filled downwards.
		ridges := [?]struct {
			base, amp, freq, phase: f32,
			col:                    u32,
		} {
			{0.60, 46, 2.3, 0.4, 0x4a3160},
			{0.70, 70, 1.5, 2.1, 0x2e1f47},
			{0.82, 96, 1.1, 5.0, 0x171032},
		}
		for rg in ridges {
			for x in 0 ..< W {
				u := f32(x) / W
				y :=
					f32(H) * rg.base -
					rg.amp * math.sin(u * rg.freq * math.TAU + rg.phase) -
					rg.amp * 0.4 * math.sin(u * rg.freq * 2.7 * math.TAU + rg.phase * 1.7)
				p.fill_rect(&c, {f32(x), y, 1, f32(H) - y}, p.hex(rg.col))
			}
		}
		if !write_png(fmt.tprintf("%s/vista.png", dir), px, W, H) {
			return "cannot write vista.png"
		}
	}

	// A bar chart, drawn with palmy's rasterizer onto a transparent-looking
	// dark panel. No text: the slide puts the labels on.
	{
		W :: 900
		H :: 600
		px := make([]u32, W * H, context.temp_allocator)
		c := p.canvas_from(px, W, H, 1)
		defer p.canvas_destroy(&c)
		p.clear_canvas(&c, p.hex(0x101a2e))
		for i in 1 ..< 5 {
			y := f32(H) * f32(i) / 5
			p.fill_rect(&c, {40, y, W - 80, 1}, p.hexa(0xffffff1f))
		}
		vals := [?]f32{0.32, 0.48, 0.41, 0.67, 0.72, 0.88}
		bw := f32(W - 120) / f32(len(vals))
		for v, i in vals {
			x := 60 + f32(i) * bw
			hh := (H - 120) * v
			col := p.mix(p.hex(0x6366f1), p.hex(0x22d3ee), f32(i) / f32(len(vals) - 1))
			p.fill_round_rect(&c, {x + 10, f32(H) - 60 - hh, bw - 20, hh}, {10, 10, 0, 0}, col)
		}
		p.fill_rect(&c, {40, H - 60, W - 80, 2}, p.hexa(0xffffff55))
		if !write_png(fmt.tprintf("%s/bars.png", dir), px, W, H) {
			return "cannot write bars.png"
		}
	}
	return ""
}
