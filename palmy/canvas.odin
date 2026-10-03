package palmy

import "core:math"

// Rect is an axis-aligned rectangle. Positions are in pixels and may be
// fractional; everything antialiases against the pixel grid.
Rect :: struct {
	x, y, w, h: f32,
}

// Radius holds the corner radii in clockwise order from the top left.
Radius :: [4]f32

rect_right :: #force_inline proc "contextless" (r: Rect) -> f32 {return r.x + r.w}
rect_bottom :: #force_inline proc "contextless" (r: Rect) -> f32 {return r.y + r.h}

rect_contains :: proc "contextless" (r: Rect, x, y: f32) -> bool {
	return x >= r.x && y >= r.y && x < r.x + r.w && y < r.y + r.h
}

rect_inset :: proc "contextless" (r: Rect, d: f32) -> Rect {
	return {r.x + d, r.y + d, max(0, r.w - 2 * d), max(0, r.h - 2 * d)}
}

rect_intersect :: proc "contextless" (a, b: Rect) -> Rect {
	x0 := max(a.x, b.x)
	y0 := max(a.y, b.y)
	x1 := min(rect_right(a), rect_right(b))
	y1 := min(rect_bottom(a), rect_bottom(b))
	return {x0, y0, max(0, x1 - x0), max(0, y1 - y0)}
}

rect_overlaps :: proc "contextless" (a, b: Rect) -> bool {
	r := rect_intersect(a, b)
	return r.w > 0 && r.h > 0
}

// Paint describes how a shape is filled: either a flat color or a two-stop
// linear gradient along one axis.
Paint :: struct {
	color:    Color,
	color2:   Color,
	gradient: bool,
	vertical: bool,
}

flat :: proc "contextless" (c: Color) -> Paint {
	return {color = c, color2 = c}
}

gradient :: proc "contextless" (from, to: Color, vertical := true) -> Paint {
	return {color = from, color2 = to, gradient = true, vertical = vertical}
}

// Canvas is a 32-bit XRGB pixel buffer plus a clip stack. The pixel memory is
// usually the compositor's shared-memory buffer, so writes land straight in the
// window with no intermediate copy.
Canvas :: struct {
	px:    []u32,
	w, h:  int,
	clip:  Rect,
	stack: [dynamic]Rect,
	// Device pixels per logical pixel. Drawing procedures work in device
	// pixels; the UI layer scales as it paints.
	scale: f32,
}

canvas_from :: proc(px: []u32, w, h: int, scale: f32 = 1) -> Canvas {
	return Canvas{px = px, w = w, h = h, clip = {0, 0, f32(w), f32(h)}, scale = scale}
}

canvas_destroy :: proc(c: ^Canvas) {
	delete(c.stack)
}

// push_clip intersects the clip region and remembers the previous one.
push_clip :: proc(c: ^Canvas, r: Rect) {
	append(&c.stack, c.clip)
	c.clip = rect_intersect(c.clip, r)
}

pop_clip :: proc(c: ^Canvas) {
	if n := len(c.stack); n > 0 {
		c.clip = c.stack[n - 1]
		pop(&c.stack)
	}
}

reset_clip :: proc(c: ^Canvas) {
	clear(&c.stack)
	c.clip = {0, 0, f32(c.w), f32(c.h)}
}

// ---------------------------------------------------------------------------
// Pixel access
// ---------------------------------------------------------------------------

@(private)
pack :: #force_inline proc "contextless" (c: Color) -> u32 {
	return 0xff00_0000 | (u32(c.r) << 16) | (u32(c.g) << 8) | u32(c.b)
}

// put writes one pixel, ignoring alpha.
put :: #force_inline proc "contextless" (c: ^Canvas, x, y: int, col: Color) {
	if x < 0 || y < 0 || x >= c.w || y >= c.h {
		return
	}
	c.px[y * c.w + x] = pack(col)
}

// get reads one pixel back as a color.
get :: #force_inline proc "contextless" (c: ^Canvas, x, y: int) -> Color {
	if x < 0 || y < 0 || x >= c.w || y >= c.h {
		return {}
	}
	v := c.px[y * c.w + x]
	return {u8(v >> 16), u8(v >> 8), u8(v), 255}
}

// blend composites one pixel with src-over alpha blending.
blend :: #force_inline proc "contextless" (c: ^Canvas, x, y: int, col: Color, cov: f32 = 1) {
	if x < 0 || y < 0 || x >= c.w || y >= c.h {
		return
	}
	a := u32(f32(col.a) * clamp(cov, 0, 1) + 0.5)
	if a == 0 {
		return
	}
	i := y * c.w + x
	if a >= 255 {
		c.px[i] = pack(col)
		return
	}
	dst := c.px[i]
	na := 255 - a
	dr := (dst >> 16) & 0xff
	dg := (dst >> 8) & 0xff
	db := dst & 0xff
	r := (u32(col.r) * a + dr * na + 127) / 255
	g := (u32(col.g) * a + dg * na + 127) / 255
	b := (u32(col.b) * a + db * na + 127) / 255
	c.px[i] = 0xff00_0000 | (r << 16) | (g << 8) | b
}

// span blends a horizontal run of constant color and coverage.
@(private)
span :: proc "contextless" (c: ^Canvas, x0, x1, y: int, col: Color, cov: f32) {
	if y < 0 || y >= c.h {
		return
	}
	lo := max(x0, 0)
	hi := min(x1, c.w)
	if lo >= hi {
		return
	}
	a := u32(f32(col.a) * clamp(cov, 0, 1) + 0.5)
	if a == 0 {
		return
	}
	row := c.px[y * c.w:][:c.w]
	if a >= 255 {
		v := pack(col)
		for x in lo ..< hi {
			row[x] = v
		}
		return
	}
	na := 255 - a
	cr := u32(col.r) * a + 127
	cg := u32(col.g) * a + 127
	cb := u32(col.b) * a + 127
	for x in lo ..< hi {
		dst := row[x]
		r := (cr + ((dst >> 16) & 0xff) * na) / 255
		g := (cg + ((dst >> 8) & 0xff) * na) / 255
		b := (cb + (dst & 0xff) * na) / 255
		row[x] = 0xff00_0000 | (r << 16) | (g << 8) | b
	}
}

clear_canvas :: proc(c: ^Canvas, col: Color) {
	v := pack(col)
	for i in 0 ..< len(c.px) {
		c.px[i] = v
	}
}

// ---------------------------------------------------------------------------
// Shapes
// ---------------------------------------------------------------------------

@(private)
axis_coverage :: #force_inline proc "contextless" (i: int, lo, hi: f32) -> f32 {
	a := max(f32(i), lo)
	b := min(f32(i + 1), hi)
	return max(0, b - a)
}

@(private)
shade :: #force_inline proc "contextless" (p: Paint, t: f32) -> Color {
	return p.gradient ? mix(p.color, p.color2, t) : p.color
}

// fill_rect fills an axis-aligned rectangle, antialiasing fractional edges.
fill_rect :: proc(c: ^Canvas, r: Rect, col: Color) {
	fill_rect_paint(c, r, flat(col))
}

fill_rect_paint :: proc(c: ^Canvas, r: Rect, p: Paint) {
	b := rect_intersect(r, c.clip)
	if b.w <= 0 || b.h <= 0 {
		return
	}
	x0 := int(math.floor(b.x))
	y0 := int(math.floor(b.y))
	x1 := int(math.ceil(rect_right(b)))
	y1 := int(math.ceil(rect_bottom(b)))
	lx, rx := b.x, rect_right(b)
	ty, by := b.y, rect_bottom(b)

	for y in y0 ..< y1 {
		cy := axis_coverage(y, ty, by)
		if cy <= 0 {
			continue
		}
		t := r.h > 1 ? clamp((f32(y) + 0.5 - r.y) / r.h, 0, 1) : 0
		col := p.vertical ? shade(p, t) : p.color
		if !p.gradient {
			col = p.color
		}

		if p.gradient && !p.vertical {
			// Horizontal gradients need per-pixel colors.
			for x in x0 ..< x1 {
				cx := axis_coverage(x, lx, rx)
				tx := r.w > 1 ? clamp((f32(x) + 0.5 - r.x) / r.w, 0, 1) : 0
				blend(c, x, y, shade(p, tx), cx * cy)
			}
			continue
		}

		// Left and right edge pixels, then one fast span for the interior.
		if x1 - x0 <= 2 {
			for x in x0 ..< x1 {
				blend(c, x, y, col, axis_coverage(x, lx, rx) * cy)
			}
			continue
		}
		blend(c, x0, y, col, axis_coverage(x0, lx, rx) * cy)
		blend(c, x1 - 1, y, col, axis_coverage(x1 - 1, lx, rx) * cy)
		span(c, x0 + 1, x1 - 1, y, col, cy)
	}
}

@(private)
sd_round_box :: #force_inline proc "contextless" (px, py, hw, hh: f32, rad: Radius) -> f32 {
	// Pick the radius belonging to the quadrant this point falls in.
	r := px > 0 ? (py > 0 ? rad[2] : rad[1]) : (py > 0 ? rad[3] : rad[0])
	r = min(r, min(hw, hh))
	qx := abs(px) - hw + r
	qy := abs(py) - hh + r
	outside := math.sqrt(max(qx, 0) * max(qx, 0) + max(qy, 0) * max(qy, 0))
	return min(max(qx, qy), 0) + outside - r
}

@(private)
has_radius :: proc "contextless" (rad: Radius) -> bool {
	return rad[0] > 0.01 || rad[1] > 0.01 || rad[2] > 0.01 || rad[3] > 0.01
}

// clamp_radius keeps radii from overlapping on small boxes, the way CSS does.
clamp_radius :: proc "contextless" (r: Rect, rad: Radius) -> Radius {
	m := min(r.w, r.h) / 2
	return {min(rad[0], m), min(rad[1], m), min(rad[2], m), min(rad[3], m)}
}

fill_round_rect :: proc(c: ^Canvas, r: Rect, rad: Radius, col: Color) {
	fill_round_rect_paint(c, r, rad, flat(col))
}

// fill_round_rect_paint fills a rounded rectangle. Rows that cross a corner are
// evaluated through a signed distance field for clean antialiasing; the rows in
// between are filled as flat spans, which keeps large panels cheap.
fill_round_rect_paint :: proc(c: ^Canvas, r: Rect, rad_in: Radius, p: Paint) {
	rad := clamp_radius(r, rad_in)
	if !has_radius(rad) {
		fill_rect_paint(c, r, p)
		return
	}

	b := rect_intersect(r, c.clip)
	if b.w <= 0 || b.h <= 0 {
		return
	}

	hw, hh := r.w / 2, r.h / 2
	cx, cy := r.x + hw, r.y + hh
	max_r := max(max(rad[0], rad[1]), max(rad[2], rad[3]))

	x0 := int(math.floor(b.x))
	y0 := int(math.floor(b.y))
	x1 := int(math.ceil(rect_right(b)))
	y1 := int(math.ceil(rect_bottom(b)))

	for y in y0 ..< y1 {
		py := f32(y) + 0.5 - cy
		t := r.h > 1 ? clamp((f32(y) + 0.5 - r.y) / r.h, 0, 1) : 0
		row_col := p.vertical ? shade(p, t) : p.color

		in_corner_band := (f32(y) + 1 > r.y && f32(y) < r.y + max_r + 1) ||
			(f32(y) + 1 > rect_bottom(r) - max_r - 1 && f32(y) < rect_bottom(r))

		if !in_corner_band && !(p.gradient && !p.vertical) {
			// Straight section: antialias only the vertical edges.
			lx, rx := r.x, rect_right(r)
			blend(c, x0, y, row_col, axis_coverage(x0, lx, rx))
			if x1 - x0 > 1 {
				blend(c, x1 - 1, y, row_col, axis_coverage(x1 - 1, lx, rx))
				span(c, x0 + 1, x1 - 1, y, row_col, 1)
			}
			continue
		}

		for x in x0 ..< x1 {
			px := f32(x) + 0.5 - cx
			d := sd_round_box(px, py, hw, hh, rad)
			cov := clamp(0.5 - d, 0, 1)
			if cov <= 0 {
				continue
			}
			col := row_col
			if p.gradient && !p.vertical {
				col = shade(p, r.w > 1 ? clamp((f32(x) + 0.5 - r.x) / r.w, 0, 1) : 0)
			}
			blend(c, x, y, col, cov)
		}
	}
}

// stroke_round_rect draws a border inside the given rectangle.
stroke_round_rect :: proc(c: ^Canvas, r: Rect, rad_in: Radius, width: f32, col: Color) {
	if width <= 0 {
		return
	}
	rad := clamp_radius(r, rad_in)
	b := rect_intersect(rect_inset(r, -1), c.clip)
	if b.w <= 0 || b.h <= 0 {
		return
	}

	hw, hh := r.w / 2, r.h / 2
	cx, cy := r.x + hw, r.y + hh
	ihw, ihh := max(0, hw - width), max(0, hh - width)
	irad := Radius {
		max(0, rad[0] - width),
		max(0, rad[1] - width),
		max(0, rad[2] - width),
		max(0, rad[3] - width),
	}

	x0 := int(math.floor(b.x))
	y0 := int(math.floor(b.y))
	x1 := int(math.ceil(rect_right(b)))
	y1 := int(math.ceil(rect_bottom(b)))

	// The fast path below only holds where the sides are actually straight.
	// On a circle or any large radius the ring follows an arc at every row, and
	// jumping to the two edge columns would erase the corners entirely.
	max_rad := max(max(rad[0], rad[1]), max(rad[2], rad[3]))
	straight_to := hh - max_rad - 1

	for y in y0 ..< y1 {
		py := f32(y) + 0.5 - cy
		// Skip the hollow middle of the ring in one jump.
		if abs(py) < min(ihh - 1, straight_to) && r.w > 2 * width + 2 {
			lx0 := int(math.floor(r.x))
			lx1 := int(math.ceil(r.x + width))
			rx0 := int(math.floor(rect_right(r) - width))
			rx1 := int(math.ceil(rect_right(r)))
			for x in lx0 ..< lx1 {
				ring_pixel(c, x, y, cx, cy, hw, hh, ihw, ihh, rad, irad, col)
			}
			for x in rx0 ..< rx1 {
				ring_pixel(c, x, y, cx, cy, hw, hh, ihw, ihh, rad, irad, col)
			}
			continue
		}
		for x in x0 ..< x1 {
			ring_pixel(c, x, y, cx, cy, hw, hh, ihw, ihh, rad, irad, col)
		}
	}
}

@(private)
ring_pixel :: #force_inline proc(c: ^Canvas, x, y: int, cx, cy, hw, hh, ihw, ihh: f32, rad, irad: Radius, col: Color) {
	px := f32(x) + 0.5 - cx
	py := f32(y) + 0.5 - cy
	outer := clamp(0.5 - sd_round_box(px, py, hw, hh, rad), 0, 1)
	if outer <= 0 {
		return
	}
	inner := clamp(0.5 - sd_round_box(px, py, ihw, ihh, irad), 0, 1)
	cov := outer - inner
	if cov > 0.002 {
		blend(c, x, y, col, cov)
	}
}

// drop_shadow draws a soft shadow for a rounded rectangle. The falloff is a
// smoothstep over the shape's distance field, which is a good approximation of
// a gaussian blur and costs a fraction as much.
drop_shadow :: proc(c: ^Canvas, r: Rect, rad_in: Radius, blur, spread: f32, offset: [2]f32, col: Color) {
	if col.a == 0 || blur <= 0 && spread <= 0 {
		return
	}
	sr := Rect{r.x + offset.x - spread, r.y + offset.y - spread, r.w + 2 * spread, r.h + 2 * spread}
	rad := clamp_radius(sr, {rad_in[0] + spread, rad_in[1] + spread, rad_in[2] + spread, rad_in[3] + spread})

	b := rect_intersect(rect_inset(sr, -blur - 1), c.clip)
	if b.w <= 0 || b.h <= 0 {
		return
	}

	hw, hh := sr.w / 2, sr.h / 2
	cx, cy := sr.x + hw, sr.y + hh
	inv := 1 / max(blur, 0.0001)

	x0 := int(math.floor(b.x))
	y0 := int(math.floor(b.y))
	x1 := int(math.ceil(rect_right(b)))
	y1 := int(math.ceil(rect_bottom(b)))

	for y in y0 ..< y1 {
		py := f32(y) + 0.5 - cy
		for x in x0 ..< x1 {
			px := f32(x) + 0.5 - cx
			d := sd_round_box(px, py, hw, hh, rad)
			if d > blur {
				continue
			}
			t := clamp(0.5 - d * inv * 0.5, 0, 1)
			cov := t * t * (3 - 2 * t) // smoothstep
			if cov > 0.003 {
				blend(c, x, y, col, cov)
			}
		}
	}
}

fill_circle :: proc(c: ^Canvas, cx, cy, radius: f32, col: Color) {
	fill_round_rect(
		c,
		{cx - radius, cy - radius, radius * 2, radius * 2},
		{radius, radius, radius, radius},
		col,
	)
}

// draw_line draws an antialiased line of the given thickness.
draw_line :: proc(c: ^Canvas, x0, y0, x1, y1, thickness: f32, col: Color) {
	dx, dy := x1 - x0, y1 - y0
	length := math.sqrt(dx * dx + dy * dy)
	if length < 0.0001 {
		fill_circle(c, x0, y0, thickness / 2, col)
		return
	}
	nx, ny := dx / length, dy / length
	half := max(thickness, 0.5) / 2

	bb := Rect {
		min(x0, x1) - half - 1,
		min(y0, y1) - half - 1,
		abs(dx) + 2 * half + 2,
		abs(dy) + 2 * half + 2,
	}
	b := rect_intersect(bb, c.clip)
	if b.w <= 0 || b.h <= 0 {
		return
	}

	for y in int(b.y) ..< int(math.ceil(rect_bottom(b))) {
		for x in int(b.x) ..< int(math.ceil(rect_right(b))) {
			px := f32(x) + 0.5 - x0
			py := f32(y) + 0.5 - y0
			// Distance to the segment.
			t := clamp(px * nx + py * ny, 0, length)
			ex := px - nx * t
			ey := py - ny * t
			d := math.sqrt(ex * ex + ey * ey) - half
			cov := clamp(0.5 - d, 0, 1)
			if cov > 0 {
				blend(c, x, y, col, cov)
			}
		}
	}
}

// ---------------------------------------------------------------------------
// Linear-light coverage blending.
//
// Compositing antialiased coverage directly in sRGB darkens light-on-dark text
// and thickens dark-on-light text, because sRGB is perceptually spaced rather
// than linear in light. Browsers blend glyph coverage in linear light; doing
// the same here is both more correct and what makes palmy's text match theirs.
// ---------------------------------------------------------------------------

// text_gamma shapes glyph coverage before compositing, the way Skia's text
// contrast LUT does: `coverage^(1/gamma)`, so values above 1 make glyph edges
// heavier. Unhinted coverage renders lighter than a hinted rasterizer, and
// measuring palmy against Chromium over 162 components put the minimum at
// about 1.8. That is a fit to one browser and one typeface, so the default here
// stays neutral; set it per application if you want to match a reference.
@(private)
text_gamma_value: f32 = 1.0

set_text_gamma :: proc "contextless" (g: f32) {
	text_gamma_value = max(g, 0.05)
}

@(private)
srgb_lut: [256]f32
@(private)
srgb_lut_ready: bool

@(private)
srgb_to_linear :: proc "contextless" (v: u8) -> f32 {
	return srgb_lut[v]
}

@(private)
linear_to_srgb :: proc "contextless" (v: f32) -> u8 {
	c := clamp(v, 0, 1)
	s := c <= 0.0031308 ? c * 12.92 : 1.055 * math.pow(c, 1.0 / 2.4) - 0.055
	return u8(clamp(s * 255 + 0.5, 0, 255))
}

@(private)
ensure_srgb_lut :: proc "contextless" () {
	if srgb_lut_ready {
		return
	}
	for i in 0 ..< 256 {
		c := f32(i) / 255
		srgb_lut[i] = c <= 0.04045 ? c / 12.92 : math.pow((c + 0.055) / 1.055, 2.4)
	}
	srgb_lut_ready = true
}

// blend_coverage composites one pixel of antialiased coverage in linear light.
blend_coverage :: proc "contextless" (c: ^Canvas, x, y: int, col: Color, cov: f32) {
	if x < 0 || y < 0 || x >= c.w || y >= c.h {
		return
	}
	a := clamp(cov, 0, 1) * (f32(col.a) / 255)
	if a <= 0 {
		return
	}
	ensure_srgb_lut()

	i := y * c.w + x
	dst := c.px[i]

	if text_gamma_value != 1.0 && a < 1 {
		// A contrast boost on partial coverage, in both directions. Skia
		// applies a gamma LUT that makes glyph edges heavier whichever way the
		// contrast runs; a direction-dependent correction gets one of the two
		// cases backwards.
		a = math.pow(a, 1 / text_gamma_value)
	}
	sr := srgb_to_linear(col.r)
	sg := srgb_to_linear(col.g)
	sb := srgb_to_linear(col.b)
	dr := srgb_to_linear(u8((dst >> 16) & 0xff))
	dg := srgb_to_linear(u8((dst >> 8) & 0xff))
	db := srgb_to_linear(u8(dst & 0xff))

	r := linear_to_srgb(sr * a + dr * (1 - a))
	g := linear_to_srgb(sg * a + dg * (1 - a))
	b := linear_to_srgb(sb * a + db * (1 - a))
	c.px[i] = 0xff00_0000 | (u32(r) << 16) | (u32(g) << 8) | u32(b)
}

// blit_mask composites an 8-bit coverage mask, which is how glyphs are drawn.
blit_mask :: proc(c: ^Canvas, x, y: int, mask: []u8, mw, mh: int, col: Color) {
	cx0 := max(x, int(c.clip.x))
	cy0 := max(y, int(c.clip.y))
	cx1 := min(x + mw, int(math.ceil(rect_right(c.clip))))
	cy1 := min(y + mh, int(math.ceil(rect_bottom(c.clip))))
	if cx0 >= cx1 || cy0 >= cy1 {
		return
	}
	for py in cy0 ..< cy1 {
		mrow := mask[(py - y) * mw:][:mw]
		for px in cx0 ..< cx1 {
			m := mrow[px - x]
			if m == 0 {
				continue
			}
			blend_coverage(c, px, py, col, f32(m) / 255)
		}
	}
}
