package main

// The tools.
//
// The one thing worth reading closely here is how a stroke works. Stamping a
// round brush repeatedly with source-over darkens every overlap, so a slow drag
// at 40% opacity comes out as a string of dark beads. Photoshop does not do
// that, and neither does this: a stroke owns a coverage mask, each stamp takes
// the *maximum* of its own coverage and what is already there, and the layer is
// recomputed from a snapshot taken when the stroke began. One stroke therefore
// deposits its opacity exactly once however many samples the pointer produced,
// and the whole stroke is a single undo entry.
//
// Interpolation falls out of the same structure: a fast drag arrives as two
// distant samples, so the segment between them is walked at a quarter of the
// brush radius and stamped at each step. Gaps are impossible by construction.

import "core:math"

Tool :: enum u8 {
	Brush,
	Eraser,
	Fill,
	Eyedropper,
	Select,
	Move,
	Pan,
}

TOOL_NAMES := [Tool]string {
	.Brush      = "Brush",
	.Eraser     = "Eraser",
	.Fill       = "Fill",
	.Eyedropper = "Eyedropper",
	.Select     = "Select",
	.Move       = "Move",
	.Pan        = "Pan",
}

TOOL_KEYS := [Tool]string {
	.Brush      = "B",
	.Eraser     = "E",
	.Fill       = "G",
	.Eyedropper = "I",
	.Select     = "M",
	.Move       = "V",
	.Pan        = "H",
}

// Stroke holds everything a single drag owns.
Stroke :: struct {
	live:      bool,
	pool:      int,
	base:      []u32, // layer pixels when the stroke started
	mask:      []u8,  // accumulated coverage, doc-sized
	touched:   Rect_I, // where the mask is non-zero (so clearing is cheap)
	bbox:      Rect_I, // total region written to the layer
	last:      [2]f32,
	have_last: bool,
	erase:     bool,
	samples:   int,
	stamps:    int,
}

Brush :: struct {
	size:     f32, // diameter in document pixels
	hardness: f32, // 0 = fully feathered, 1 = one pixel of antialiasing
	opacity:  f32, // 0..1, applied once per stroke
	flow_tol: f32, // fill tolerance, 0..255 — lives here so `[`/`]` can share
}

BRUSH_MIN :: f32(1)
BRUSH_MAX :: f32(400)

// ---------------------------------------------------------------------------
// Coverage
// ---------------------------------------------------------------------------

// brush_coverage is the stamp profile: 1 inside the hard core, falling to 0 at
// the radius over a feather band that is never narrower than one pixel, so a
// hardness-1 brush still has an antialiased edge rather than a staircase.
// Smoothstepped, because a linear ramp reads as a visible ring.
brush_coverage :: proc "contextless" (dist, radius, hardness: f32) -> f32 {
	if radius <= 0 {
		return 0
	}
	feather := max(1, radius * (1 - clamp(hardness, 0, 1)))
	t := clamp((radius - dist) / feather, 0, 1)
	return t * t * (3 - 2 * t)
}

// ---------------------------------------------------------------------------
// Stroke lifetime
// ---------------------------------------------------------------------------

stroke_alloc :: proc(s: ^Stroke, d: ^Doc) {
	if len(s.base) != d.w * d.h {
		delete(s.base)
		delete(s.mask)
		s.base = make([]u32, d.w * d.h)
		s.mask = make([]u8, d.w * d.h)
		s.touched = {}
	}
}

stroke_free :: proc(s: ^Stroke) {
	delete(s.base)
	delete(s.mask)
	s^ = {}
}

stroke_begin :: proc(s: ^Stroke, d: ^Doc, erase: bool) {
	l := active_layer(d)
	if l == nil {
		return
	}
	stroke_alloc(s, d)
	// Only the region the previous stroke touched needs clearing.
	cl := rect_i_clip(s.touched, d.w, d.h)
	for y in cl.y0 ..< cl.y1 {
		row := s.mask[y * d.w:]
		for x in cl.x0 ..< cl.x1 {
			row[x] = 0
		}
	}
	copy(s.base, l.px)
	s.live = true
	s.pool = active_pool(d)
	s.touched = {}
	s.bbox = {}
	s.have_last = false
	s.erase = erase
	s.samples = 0
	s.stamps = 0
}

// stroke_to extends the stroke to a new pointer sample, interpolating from the
// previous one. Returns the rectangle it rewrote, for dirtying.
stroke_to :: proc(s: ^Stroke, d: ^Doc, br: Brush, pt: [2]f32, color: u32, clip: Rect_I) -> Rect_I {
	if !s.live {
		return {}
	}
	s.samples += 1
	radius := max(br.size, BRUSH_MIN) / 2
	step := max(radius * 0.25, 0.75)

	written := Rect_I{}
	if !s.have_last {
		written = stroke_stamp(s, d, br, pt, color, clip)
		s.last = pt
		s.have_last = true
		return written
	}

	dx := pt.x - s.last.x
	dy := pt.y - s.last.y
	dist := math.sqrt(dx * dx + dy * dy)
	n := int(dist / step)
	for i in 1 ..= n {
		t := f32(i) * step / dist
		q := [2]f32{s.last.x + dx * t, s.last.y + dy * t}
		written = rect_i_union(written, stroke_stamp(s, d, br, q, color, clip))
	}
	// Always stamp the sample itself so the stroke ends where the pointer is.
	written = rect_i_union(written, stroke_stamp(s, d, br, pt, color, clip))
	s.last = pt
	return written
}

// stroke_stamp lays one dab into the mask and recomputes the layer from the
// stroke's base snapshot over the dab's rectangle.
stroke_stamp :: proc(s: ^Stroke, d: ^Doc, br: Brush, pt: [2]f32, color: u32, clip: Rect_I) -> Rect_I {
	radius := max(br.size, BRUSH_MIN) / 2
	r := Rect_I {
		int(math.floor(pt.x - radius - 1)),
		int(math.floor(pt.y - radius - 1)),
		int(math.ceil(pt.x + radius + 1)) + 1,
		int(math.ceil(pt.y + radius + 1)) + 1,
	}
	r = rect_i_clip(r, d.w, d.h)
	if !rect_i_empty(clip) {
		r = rect_i_intersect(r, clip)
	}
	if rect_i_empty(r) {
		return {}
	}
	s.stamps += 1

	for y in r.y0 ..< r.y1 {
		fy := f32(y) + 0.5 - pt.y
		mrow := s.mask[y * d.w:]
		for x in r.x0 ..< r.x1 {
			fx := f32(x) + 0.5 - pt.x
			cov := brush_coverage(math.sqrt(fx * fx + fy * fy), radius, br.hardness)
			if cov <= 0 {
				continue
			}
			v := u8(clamp(cov * 255 + 0.5, 0, 255))
			if v > mrow[x] {
				mrow[x] = v
			}
		}
	}
	s.touched = rect_i_union(s.touched, r)
	s.bbox = rect_i_union(s.bbox, r)
	stroke_resolve(s, d, br, r, color)
	return r
}

// stroke_resolve writes `base` composited with the stroke mask into the layer.
// Idempotent over a region, which is the whole reason the mask exists.
stroke_resolve :: proc(s: ^Stroke, d: ^Doc, br: Brush, r: Rect_I, color: u32) {
	l := &d.pool[s.pool]
	op := clamp(br.opacity, 0, 1)
	ca := u32(clamp(f32((color >> 24) & 0xff) * op + 0.5, 0, 255))
	rgb := color & 0x00ff_ffff

	for y in r.y0 ..< r.y1 {
		mrow := s.mask[y * d.w:]
		brow := s.base[y * d.w:]
		drow := l.px[y * d.w:]
		for x in r.x0 ..< r.x1 {
			m := u32(mrow[x])
			if m == 0 {
				drow[x] = brow[x]
				continue
			}
			if s.erase {
				// Destination-out: scale the base alpha down by the coverage,
				// which is what an eraser is on a layer with transparency.
				keep := 255 - (m * u32(op * 255 + 0.5) / 255)
				b := brow[x]
				a := ((b >> 24) & 0xff) * keep / 255
				drow[x] = (a << 24) | (b & 0x00ff_ffff)
			} else {
				a := ca * m / 255
				drow[x] = src_over(brow[x], (a << 24) | rgb)
			}
		}
	}
}

stroke_end :: proc(s: ^Stroke) -> (pool: int, bbox: Rect_I, base: []u32, ok: bool) {
	if !s.live {
		return 0, {}, nil, false
	}
	s.live = false
	s.have_last = false
	return s.pool, s.bbox, s.base, !rect_i_empty(s.bbox)
}

// ---------------------------------------------------------------------------
// Flood fill
// ---------------------------------------------------------------------------

// px_distance is the tolerance metric: the largest absolute per-channel
// difference, alpha included. Comparing premultiplied or summed channels makes
// a tolerance of 30 mean something different on dark and light regions; the max
// norm does not.
px_distance :: proc "contextless" (a, b: u32) -> u32 {
	d: u32 = 0
	for sh in ([4]u32{24, 16, 8, 0}) {
		x := (a >> sh) & 0xff
		y := (b >> sh) & 0xff
		v := x > y ? x - y : y - x
		if v > d {
			d = v
		}
	}
	return d
}

// flood_fill is a scanline flood fill with tolerance, 4-connected, over one
// layer. Returns the rectangle it changed.
//
// Spans rather than per-pixel recursion: a 1024-wide region pushes one entry
// per row instead of one per pixel, so the stack is bounded by the height and
// not by the area.
//
// The `seen` map is not an optimisation, it is what makes this terminate. The
// textbook algorithm relies on a filled pixel no longer matching the target —
// but with a tolerance the fill colour can still be *within* tolerance of it,
// and at tolerance 255 everything is. Without `seen`, filling a grey region
// with a slightly different grey loops forever.
flood_fill :: proc(
	px: []u32,
	w, h: int,
	sx, sy: int,
	color: u32,
	tol: u32,
	clip_in: Rect_I,
	scratch: ^[dynamic][2]int,
) -> Rect_I {
	clip := rect_i_empty(clip_in) ? Rect_I{0, 0, w, h} : rect_i_clip(clip_in, w, h)
	if sx < clip.x0 || sx >= clip.x1 || sy < clip.y0 || sy >= clip.y1 {
		return {}
	}
	target := px[sy * w + sx]
	if target == color {
		return {}
	}
	seen := make([]bool, w * h, context.temp_allocator)

	clear(scratch)
	append(scratch, [2]int{sx, sy})
	out := Rect_I{sx, sy, sx + 1, sy + 1}

	for len(scratch) > 0 {
		pt := pop(scratch)
		x, y := pt[0], pt[1]
		row := px[y * w:]
		srow := seen[y * w:]
		if srow[x] || px_distance(row[x], target) > tol {
			continue
		}
		// Walk left and right to the ends of the span.
		x0 := x
		for x0 > clip.x0 && !srow[x0 - 1] && px_distance(row[x0 - 1], target) <= tol {
			x0 -= 1
		}
		x1 := x
		for x1 + 1 < clip.x1 && !srow[x1 + 1] && px_distance(row[x1 + 1], target) <= tol {
			x1 += 1
		}
		for i in x0 ..= x1 {
			row[i] = color
			srow[i] = true
		}
		out = rect_i_union(out, Rect_I{x0, y, x1 + 1, y + 1})

		// Seed the rows above and below, one entry per contiguous run.
		for dy in ([2]int{-1, 1}) {
			ny := y + dy
			if ny < clip.y0 || ny >= clip.y1 {
				continue
			}
			nrow := px[ny * w:]
			nseen := seen[ny * w:]
			ok :: #force_inline proc "contextless" (
				nrow: []u32,
				nseen: []bool,
				i: int,
				target, tol: u32,
			) -> bool {
				return !nseen[i] && px_distance(nrow[i], target) <= tol
			}
			i := x0
			for i <= x1 {
				if ok(nrow, nseen, i, target, tol) {
					append(scratch, [2]int{i, ny})
					for i <= x1 && ok(nrow, nseen, i, target, tol) {
						i += 1
					}
				} else {
					i += 1
				}
			}
		}
	}
	return out
}

// ---------------------------------------------------------------------------
// Move
// ---------------------------------------------------------------------------

// translate_layer writes `base` offset by (dx, dy) into `dst`. Pixels that fall
// off the edge are dropped; the vacated area becomes transparent.
translate_layer :: proc(dst, base: []u32, w, h, dx, dy: int) {
	for y in 0 ..< h {
		sy := y - dy
		drow := dst[y * w:]
		if sy < 0 || sy >= h {
			for x in 0 ..< w {
				drow[x] = 0
			}
			continue
		}
		srow := base[sy * w:]
		for x in 0 ..< w {
			sx := x - dx
			drow[x] = (sx >= 0 && sx < w) ? srow[sx] : 0
		}
	}
}

// translate_region is the selection case: the selected rectangle is lifted out,
// the hole left behind is cleared, and the lifted pixels are composited at the
// offset. Everything outside both rectangles is untouched.
translate_region :: proc(dst, base: []u32, w, h: int, sel: Rect_I, dx, dy: int) {
	r := rect_i_clip(sel, w, h)
	if rect_i_empty(r) {
		translate_layer(dst, base, w, h, dx, dy)
		return
	}
	copy(dst, base)
	for y in r.y0 ..< r.y1 {
		row := dst[y * w:]
		for x in r.x0 ..< r.x1 {
			row[x] = 0
		}
	}
	for y in r.y0 ..< r.y1 {
		ny := y + dy
		if ny < 0 || ny >= h {
			continue
		}
		srow := base[y * w:]
		drow := dst[ny * w:]
		for x in r.x0 ..< r.x1 {
			nx := x + dx
			if nx < 0 || nx >= w {
				continue
			}
			drow[nx] = src_over(drow[nx], srow[x])
		}
	}
}

// moved_bounds is the union of where the pixels were and where they went, which
// is what has to be dirtied and recorded.
moved_bounds :: proc(sel: Rect_I, w, h, dx, dy: int) -> Rect_I {
	r := rect_i_empty(sel) ? Rect_I{0, 0, w, h} : rect_i_clip(sel, w, h)
	moved := Rect_I{r.x0 + dx, r.y0 + dy, r.x1 + dx, r.y1 + dy}
	return rect_i_clip(rect_i_union(r, moved), w, h)
}
