package main

// The canvas: document pixels on screen.
//
// This is the only place in the app that writes into the window buffer, and it
// is deliberately one pass. For every device pixel inside the document's
// on-screen rectangle it samples the cached composite, composites that sample
// over the transparency checkerboard, and writes an opaque pixel. No
// intermediate image is allocated, nothing is copied twice, and the cost is
// exactly the number of pixels the document covers on screen — not the number
// of pixels the document has.
//
// Sampling switches from bilinear to nearest-neighbour once a document pixel is
// larger than two device pixels. Past that point a smooth filter is a lie: the
// user zoomed in to see pixels, and interpolating them away hides exactly what
// they were looking for.

import "core:math"
import "core:time"
import p "palmy:."

WORKSPACE :: p.Color{24, 24, 27, 255}
CHECK_A :: p.Color{64, 64, 70, 255}
CHECK_B :: p.Color{48, 48, 53, 255}
CHECK_CELL :: f32(9)

NEAREST_ABOVE :: f32(2)

draw_canvas :: proc(c: ^p.Canvas, r: p.Rect, st: ^St) {
	t0 := time.tick_now()
	d := &st.doc
	p.fill_rect(c, r, WORKSPACE)
	if d.w <= 0 || len(d.comp) < d.w * d.h {
		return
	}

	s := st.zoom * c.scale
	w := f32(d.w) * s
	h := f32(d.h) * s
	cx := r.x + r.w / 2 + st.pan.x * c.scale
	cy := r.y + r.h / 2 + st.pan.y * c.scale
	dst := p.Rect{math.round(cx - w / 2), math.round(cy - h / 2), w, h}

	// A soft drop shadow, so a white document reads as a sheet on a desk rather
	// than as a hole in the panel — drawn only in the band around the document,
	// because the blit overwrites the interior opaquely a moment later. Letting
	// palmy evaluate its signed distance field over the whole document costs
	// 7.5 ms at this size, which is more than everything else in the frame put
	// together; the band costs 0.6.
	shadow_band(c, dst, 18 * c.scale, 4 * c.scale)

	vis := p.rect_intersect(p.rect_intersect(dst, r), c.clip)
	if vis.w <= 0 || vis.h <= 0 {
		return
	}

	x0 := int(math.floor(vis.x))
	y0 := int(math.floor(vis.y))
	x1 := int(math.ceil(p.rect_right(vis)))
	y1 := int(math.ceil(p.rect_bottom(vis)))
	x0 = clamp(x0, 0, c.w)
	x1 = clamp(x1, 0, c.w)
	y0 = clamp(y0, 0, c.h)
	y1 = clamp(y1, 0, c.h)

	// Two sampling paths, chosen once per frame rather than once per pixel, and
	// each written as its own loop: a branch that is constant for three quarters
	// of a million iterations has no business being inside them.
	//
	//   magnified or 1:1   nearest neighbour, which is what the user zoomed for
	//   otherwise          bilinear in 8.8 fixed point, premultiplied
	//
	// The checkerboard is only evaluated where a sample is not opaque, so an
	// ordinary photograph never pays for it at all.
	nearest := s > NEAREST_ABOVE || abs(s - 1) < 0.0005
	inv := 1 / s


	ca := u32(CHECK_A.r) << 16 | u32(CHECK_A.g) << 8 | u32(CHECK_A.b)
	cb := u32(CHECK_B.r) << 16 | u32(CHECK_B.g) << 8 | u32(CHECK_B.b)

	// The inner loop walks the source in 16.16 fixed point. `math.floor` on an
	// f32 is a call out to libm here, and at this pixel count one call per pixel
	// is the difference between a smooth drag and a sticky one; an integer
	// accumulator needs no floor, no conversion and no float compare.
	du := i64(f64(inv) * 65536)
	u_start := i64(f64((f32(x0) + 0.5 - dst.x) * inv) * 65536)
	v_base := f64(0.5 - dst.y) * f64(inv) * 65536
	dv := f64(inv) * 65536

	// check_under is only reached for a sample that is not fully opaque. Keeping
	// it out of line matters: the integer division that finds the checkerboard
	// cell costs more than the whole opaque path, and a photograph never needs
	// it even once.
	check_under :: proc "contextless" (v: u32, gx, gy: int, ca, cb: u32) -> u32 {
		base := ((gx + gy) & 1) == 0 ? ca : cb
		a := v >> 24
		if a == 0 {
			return 0xff00_0000 | base
		}
		ia := 255 - a
		return(
			0xff00_0000 |
			(((((v >> 16) & 0xff) * a + ((base >> 16) & 0xff) * ia) / 255) << 16) |
			(((((v >> 8) & 0xff) * a + ((base >> 8) & 0xff) * ia) / 255) << 8) |
			(((v & 0xff) * a + (base & 0xff) * ia) / 255) \
		)
	}

	cell := max(1, int(CHECK_CELL * c.scale))

	#no_bounds_check if nearest {
		for y in y0 ..< y1 {
			vq := i64(v_base + f64(y) * dv)
			row := c.px[y * c.w:]
			sy := clamp(int(vq >> 16), 0, d.h - 1) * d.w
			gy := y / cell
			uq := u_start
			for x in x0 ..< x1 {
				v := d.comp[sy + clamp(int(uq >> 16), 0, d.w - 1)]
				uq += du
				row[x] = v >= 0xff00_0000 \
					? 0xff00_0000 | (v & 0x00ff_ffff) \
					: check_under(v, x / cell, gy, ca, cb)
			}
		}
	} else {
		for y in y0 ..< y1 {
			vq := i64(v_base + f64(y) * dv) - 32768
			row := c.px[y * c.w:]
			iy := int(vq >> 16)
			ty := u32((vq >> 8) & 0xff)
			ry0 := clamp(iy, 0, d.h - 1) * d.w
			ry1 := clamp(iy + 1, 0, d.h - 1) * d.w
			gy := y / cell
			uq := u_start - 32768
			for x in x0 ..< x1 {
				ix := int(uq >> 16)
				tx := u32((uq >> 8) & 0xff)
				uq += du
				ax := clamp(ix, 0, d.w - 1)
				bx := clamp(ix + 1, 0, d.w - 1)
				v := bilerp(
					d.comp[ry0 + ax],
					d.comp[ry0 + bx],
					d.comp[ry1 + ax],
					d.comp[ry1 + bx],
					tx,
					ty,
				)
				row[x] = v >= 0xff00_0000 \
					? 0xff00_0000 | (v & 0x00ff_ffff) \
					: check_under(v, x / cell, gy, ca, cb)
			}
		}
	}

	st.blit_px = (x1 - x0) * (y1 - y0)
	st.blit_ms = time.duration_milliseconds(time.tick_since(t0))

	// A hairline so the document's edge is visible against the workspace.
	p.stroke_round_rect(c, dst, {0, 0, 0, 0}, 1, p.Color{255, 255, 255, 36})

	if st.has_sel {
		draw_marquee(c, st, dst, s)
	}
	if nearest && s >= 8 {
		draw_pixel_grid(c, dst, s, vis)
	}
	draw_tool_cursor(c, st, dst, s)
}

// ---------------------------------------------------------------------------
// Sampling
// ---------------------------------------------------------------------------

// shadow_band draws the document's drop shadow in four clipped strips around
// it. The result is identical to the unclipped call, because the document's own
// pixels — opaque, checkerboard included — land on top of the interior.
@(private = "file")
shadow_band :: proc(c: ^p.Canvas, dst: p.Rect, blur, dy: f32) {
	m := blur + dy + 2
	bands := [4]p.Rect {
		{dst.x - m, dst.y - m, dst.w + 2 * m, m},
		{dst.x - m, p.rect_bottom(dst), dst.w + 2 * m, m},
		{dst.x - m, dst.y, m, dst.h},
		{p.rect_right(dst), dst.y, m, dst.h},
	}
	for b in bands {
		if b.w <= 0 || b.h <= 0 {
			continue
		}
		p.push_clip(c, b)
		p.drop_shadow(c, dst, {0, 0, 0, 0}, blur, 0, {0, dy}, {0, 0, 0, 130})
		p.pop_clip(c)
	}
}

// lerp32 interpolates two packed pixels with one multiply per 16-bit lane.
//
// The red and blue channels are spaced 16 bits apart, so they can share a
// multiply without carrying into each other; green goes on its own. `t` runs
// 0..255 rather than 0..256 precisely so that `a*(255-t) + b*t` cannot exceed
// 0xFE01 in any lane and the packing stays valid.
lerp32 :: #force_inline proc "contextless" (a, b: u32, t: u32) -> u32 {
	it := 255 - t
	rb := (((a & 0x00ff_00ff) * it + (b & 0x00ff_00ff) * t) >> 8) & 0x00ff_00ff
	g := (((a & 0x0000_ff00) * it + (b & 0x0000_ff00) * t) >> 8) & 0x0000_ff00
	return rb | g
}

// bilerp is a bilinear sample in 8.8 fixed point, with `tx` and `ty` in 0..255.
//
// Fully opaque neighbours — a photograph, every pixel — take the packed path:
// three `lerp32` calls and no division at all. Anything else is interpolated
// premultiplied and unpremultiplied once at the end. Averaging straight alpha
// drags a soft edge toward whatever colour sits behind the transparent side —
// usually black — which is the halo every naive image scaler has.
bilerp :: proc "contextless" (p00, p10, p01, p11: u32, tx, ty: u32) -> u32 {
	if (p00 & p10 & p01 & p11) >= 0xff00_0000 {
		top := lerp32(p00, p10, tx)
		bot := lerp32(p01, p11, tx)
		return 0xff00_0000 | lerp32(top, bot, ty)
	}

	w00 := (256 - tx) * (256 - ty)
	w10 := tx * (256 - ty)
	w01 := (256 - tx) * ty
	w11 := tx * ty

	a00 := p00 >> 24
	a10 := p10 >> 24
	a01 := p01 >> 24
	a11 := p11 >> 24
	af := a00 * w00 + a10 * w10 + a01 * w01 + a11 * w11 // scaled by 65536
	if af < 32768 {
		return 0
	}
	out: u32 = (af >> 16) << 24
	for sh in ([3]u32{16, 8, 0}) {
		acc :=
			((p00 >> sh) & 0xff) * a00 * w00 / 255 +
			((p10 >> sh) & 0xff) * a10 * w10 / 255 +
			((p01 >> sh) & 0xff) * a01 * w01 / 255 +
			((p11 >> sh) & 0xff) * a11 * w11 / 255
		out |= min(acc * 255 / af, 255) << sh
	}
	return out
}

// ---------------------------------------------------------------------------
// Overlays on the canvas
// ---------------------------------------------------------------------------

// draw_marquee is the selection's marching-ants border: a dashed hairline in
// alternating black and white, so it is visible over any content.
@(private = "file")
draw_marquee :: proc(c: ^p.Canvas, st: ^St, dst: p.Rect, s: f32) {
	sel := st.sel
	rx0 := dst.x + f32(sel.x0) * s
	ry0 := dst.y + f32(sel.y0) * s
	rx1 := dst.x + f32(sel.x1) * s
	ry1 := dst.y + f32(sel.y1) * s

	dash :: proc(c: ^p.Canvas, x, y: int, i: int) {
		if x < 0 || y < 0 || x >= c.w || y >= c.h {
			return
		}
		if !p.rect_contains(c.clip, f32(x), f32(y)) {
			return
		}
		on := (i / 4) % 2 == 0
		col: u32 = on ? 0xffff_ffff : 0xff00_0000
		c.px[y * c.w + x] = col
	}

	ix0, iy0 := int(math.round(rx0)), int(math.round(ry0))
	ix1, iy1 := int(math.round(rx1)), int(math.round(ry1))
	i := 0
	for x in ix0 ..= ix1 {
		dash(c, x, iy0, i)
		dash(c, x, iy1, i)
		i += 1
	}
	i = 0
	for y in iy0 ..= iy1 {
		dash(c, ix0, y, i)
		dash(c, ix1, y, i)
		i += 1
	}
}

// draw_pixel_grid draws the document's pixel lattice once it is big enough for
// the lines to sit between pixels rather than on them.
@(private = "file")
draw_pixel_grid :: proc(c: ^p.Canvas, dst: p.Rect, s: f32, vis: p.Rect) {
	col := p.Color{255, 255, 255, 22}
	x := dst.x
	for x <= p.rect_right(dst) {
		if x >= vis.x && x <= p.rect_right(vis) {
			p.fill_rect(c, {math.round(x), vis.y, 1, vis.h}, col)
		}
		x += s
	}
	y := dst.y
	for y <= p.rect_bottom(dst) {
		if y >= vis.y && y <= p.rect_bottom(vis) {
			p.fill_rect(c, {vis.x, math.round(y), vis.w, 1}, col)
		}
		y += s
	}
}

// draw_tool_cursor shows the brush at its real size, which is the only way to
// know what a 36-pixel brush will cover at 300% zoom. Two concentric rings —
// one dark, one light — so it reads on any colour.
//
// When the pointer is not over the canvas the same cursor is drawn at the
// keyboard cursor instead, because that is where Return will act. It is marked
// with a crosshair so the two are never confused.
@(private = "file")
draw_tool_cursor :: proc(c: ^p.Canvas, st: ^St, dst: p.Rect, s: f32) {
	// A live keyboard stroke wins over the pointer: the ring has to be where
	// the paint is going.
	pos := (st.over_canvas && !st.kb_live) ? st.cursor_doc : st.kb
	keyboard := !st.over_canvas || st.kb_live
	cx := dst.x + pos.x * s
	cy := dst.y + pos.y * s

	if keyboard {
		p.draw_line(c, cx - 11, cy, cx - 3, cy, 1, {0, 0, 0, 150})
		p.draw_line(c, cx + 3, cy, cx + 11, cy, 1, {0, 0, 0, 150})
		p.draw_line(c, cx, cy - 11, cx, cy - 3, 1, {0, 0, 0, 150})
		p.draw_line(c, cx, cy + 3, cx, cy + 11, 1, {0, 0, 0, 150})
		p.draw_line(c, cx - 10, cy - 0.5, cx - 4, cy - 0.5, 1, {255, 255, 255, 220})
		p.draw_line(c, cx + 4, cy - 0.5, cx + 10, cy - 0.5, 1, {255, 255, 255, 220})
		p.draw_line(c, cx - 0.5, cy - 10, cx - 0.5, cy - 4, 1, {255, 255, 255, 220})
		p.draw_line(c, cx - 0.5, cy + 4, cx - 0.5, cy + 10, 1, {255, 255, 255, 220})
	}

	switch st.tool {
	case .Brush, .Eraser:
		rad := max(st.brush.size / 2 * s, 3)
		ring(c, cx, cy, rad, 1.6, {0, 0, 0, 170})
		ring(c, cx, cy, rad - 1.3, 1.2, st.kb_live ? p.Color{120, 230, 160, 230} : p.Color{255, 255, 255, 210})
		if st.brush.hardness < 0.95 {
			// Where the hard core ends, which is what hardness actually means.
			core := rad * clamp(st.brush.hardness, 0, 1)
			if core > 2 {
				ring(c, cx, cy, core, 1, {255, 255, 255, 70})
			}
		}
	case .Eyedropper, .Fill, .Select, .Move, .Pan:
		if !keyboard {
			p.draw_line(c, cx - 7, cy, cx + 7, cy, 1, {255, 255, 255, 150})
			p.draw_line(c, cx, cy - 7, cx, cy + 7, 1, {255, 255, 255, 150})
		}
	}
}

// ring draws an antialiased circular outline. palmy's rasterizer fills circles
// and strokes rounded rectangles but has no stroked circle, so the coverage is
// computed here from the same signed distance the rest of the toolkit uses.
@(private = "file")
ring :: proc(c: ^p.Canvas, cx, cy, radius, width: f32, col: p.Color) {
	if radius <= 0 {
		return
	}
	half := width / 2
	x0 := int(math.floor(cx - radius - half - 1))
	x1 := int(math.ceil(cx + radius + half + 1))
	y0 := int(math.floor(cy - radius - half - 1))
	y1 := int(math.ceil(cy + radius + half + 1))
	x0 = clamp(x0, int(c.clip.x), int(p.rect_right(c.clip)))
	x1 = clamp(x1, int(c.clip.x), int(p.rect_right(c.clip)))
	y0 = clamp(y0, int(c.clip.y), int(p.rect_bottom(c.clip)))
	y1 = clamp(y1, int(c.clip.y), int(p.rect_bottom(c.clip)))
	for y in y0 ..< y1 {
		fy := f32(y) + 0.5 - cy
		for x in x0 ..< x1 {
			fx := f32(x) + 0.5 - cx
			d := math.sqrt(fx * fx + fy * fy) - radius
			cov := clamp(half + 0.5 - abs(d), 0, 1)
			if cov > 0 {
				p.blend_coverage(c, x, y, col, cov)
			}
		}
	}
}
