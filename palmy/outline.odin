package palmy

import "core:math"

// ---------------------------------------------------------------------------
// Text outline.
//
// A subtitle has to stay legible over whatever frame is behind it, which means
// a stroke around every glyph. The usual way to get one without rasteriser
// support is to draw the whole run several times at small offsets in the
// outline colour and then once more in the fill colour: the captions editor
// draws it eight times, so eight rasterisations, eight cache lookups and eight
// blits per glyph — and the result is still an octagon, because eight point
// samples cannot round a corner.
//
// The rasteriser already knows the exact shape: the glyph's coverage mask. The
// outline is that mask dilated by the stroke radius. Dilating it needs the
// signed distance to the mask's own half-coverage contour, which is two
// linear-time distance transforms over a few hundred pixels — computed once per
// (glyph, size, phase, radius) and cached beside the glyph itself, so a
// steady subtitle pays for it on the first frame and never again.
// ---------------------------------------------------------------------------

// Text_Outline is a stroke drawn behind the glyph fill. A zero width disables
// it, which is what lets it sit in a default argument and cost nothing.
Text_Outline :: struct {
	width: f32,
	color: Color,
}

@(private)
Outline_Key :: struct {
	glyph: Glyph_Key,
	// Radius in quarter-pixels. The dilation uses this quantised value rather
	// than the caller's float, so the cached mask always matches its key.
	r_q:   u16,
}

// A stroke wider than this is a fill with a hole in it, not an outline, and the
// dilation cost grows with its square.
@(private)
OUTLINE_MAX_PX :: f32(24)

// outline_glyph_for returns the glyph's coverage mask dilated by `radius`
// pixels, in the same (xoff, yoff) frame as the glyph itself.
@(private)
outline_glyph_for :: proc(f: ^Fonts, key: Glyph_Key, radius: f32) -> ^Glyph {
	r_q := u16(clamp(radius * 4 + 0.5, 1, OUTLINE_MAX_PX * 4))
	ok := Outline_Key{glyph = key, r_q = r_q}
	if g, found := &f.outlines[ok]; found {
		return g
	}

	// Rasterise (or find) the glyph first: this may insert into f.glyphs, and
	// the value is copied out before anything is inserted into f.outlines.
	src := glyph_for_key(f, key)^

	out := Glyph {
		advance = src.advance,
		xoff    = src.xoff,
		yoff    = src.yoff,
	}
	if src.mask != nil {
		r := f32(r_q) / 4
		pad := int(math.ceil(r)) + 1
		out.w = src.w + 2 * pad
		out.h = src.h + 2 * pad
		out.xoff -= pad
		out.yoff -= pad
		out.mask = dilate_mask(src.mask, src.w, src.h, pad, r)
	}
	f.outlines[ok] = out
	return &f.outlines[ok]
}

// dilate_mask grows a coverage mask outward by `r` pixels, antialiased.
//
// The trick is to recover a signed distance field from the coverage, which is
// easy because coverage *is* distance near the edge: a pixel that is 30%
// covered by a straight edge has its centre 0.2px outside that edge. Fully
// empty and fully solid pixels get their distance from a vector distance
// transform of the thresholded mask instead, and the two agree where they meet.
@(private)
dilate_mask :: proc(src: []u8, sw, sh, pad: int, r: f32) -> []u8 {
	w := sw + 2 * pad
	h := sh + 2 * pad
	n := w * h

	a := make([]u8, n, context.temp_allocator)
	for y in 0 ..< sh {
		copy(a[(y + pad) * w + pad:][:sw], src[y * sw:][:sw])
	}

	inside := make([]bool, n, context.temp_allocator)
	strong := 0
	for i in 0 ..< n {
		inside[i] = a[i] >= 128
		if inside[i] {
			strong += 1
		}
	}
	// A hairline stem at a small size can be under 50% covered everywhere, so
	// the thresholded set comes out empty and the transform has no seeds. Fall
	// back to any coverage at all; the per-pixel estimate below still carries
	// the sub-pixel position.
	if strong == 0 {
		for i in 0 ..< n {
			inside[i] = a[i] > 0
		}
	}

	d_out := vector_edt(inside, w, h) // distance from a hole to the shape
	for i in 0 ..< n {
		inside[i] = !inside[i]
	}
	d_in := vector_edt(inside, w, h) // distance from the shape to a hole

	out := make([]u8, n)
	for i in 0 ..< n {
		d: f32
		switch {
		case a[i] == 0:
			d = d_out[i] - 0.5
		case a[i] == 255:
			d = -(d_in[i] - 0.5)
		case:
			// Partial coverage: the contour runs through this very pixel.
			d = 0.5 - f32(a[i]) / 255
		}
		cov := clamp(r + 0.5 - d, 0, 1)
		if cov > 0 {
			out[i] = u8(cov * 255 + 0.5)
		}
	}
	return out
}

// vector_edt is an 8-point sequential Euclidean distance transform: two sweeps
// propagating, for every pixel, the offset to the nearest seed. It is linear in
// the pixel count, where comparing every pixel against every seed is quadratic
// and far too slow for a 96px subtitle glyph.
@(private)
vector_edt :: proc(seed: []bool, w, h: int) -> []f32 {
	FAR :: i32(1 << 13)
	g := make([][2]i32, w * h, context.temp_allocator)
	for i in 0 ..< w * h {
		g[i] = seed[i] ? [2]i32{0, 0} : [2]i32{FAR, FAR}
	}

	for y in 0 ..< h {
		for x in 0 ..< w {
			relax(g, w, h, x, y, -1, 0)
			relax(g, w, h, x, y, 0, -1)
			relax(g, w, h, x, y, -1, -1)
			relax(g, w, h, x, y, 1, -1)
		}
		for x := w - 1; x >= 0; x -= 1 {
			relax(g, w, h, x, y, 1, 0)
		}
	}
	for y := h - 1; y >= 0; y -= 1 {
		for x := w - 1; x >= 0; x -= 1 {
			relax(g, w, h, x, y, 1, 0)
			relax(g, w, h, x, y, 0, 1)
			relax(g, w, h, x, y, 1, 1)
			relax(g, w, h, x, y, -1, 1)
		}
		for x in 0 ..< w {
			relax(g, w, h, x, y, -1, 0)
		}
	}

	out := make([]f32, w * h, context.temp_allocator)
	for i in 0 ..< w * h {
		out[i] = math.sqrt(f32(dist_sq(g[i])))
	}
	return out
}

@(private)
dist_sq :: #force_inline proc "contextless" (v: [2]i32) -> i64 {
	return i64(v.x) * i64(v.x) + i64(v.y) * i64(v.y)
}

// relax offers pixel (x,y) the nearest seed its neighbour at (x+dx, y+dy) knows
// about. The neighbour stores the vector from itself to that seed, so stepping
// it back into this pixel's frame means adding the step between them.
@(private)
relax :: #force_inline proc(g: [][2]i32, w, h, x, y, dx, dy: int) {
	nx, ny := x + dx, y + dy
	if nx < 0 || ny < 0 || nx >= w || ny >= h {
		return
	}
	o := g[ny * w + nx]
	o.x += i32(dx)
	o.y += i32(dy)
	i := y * w + x
	if dist_sq(o) < dist_sq(g[i]) {
		g[i] = o
	}
}
