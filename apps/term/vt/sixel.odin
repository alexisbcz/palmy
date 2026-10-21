package vt

// ---------------------------------------------------------------------------
// Sixel.
//
// `DCS P1 ; P2 ; P3 q <data> ST`. The data is a stream of six-pixel-tall
// columns: each byte from `?` to `~` is six bits, one per pixel, painted in
// the current colour; `!n` repeats the next one n times, `$` returns to the
// left edge of the band, `-` moves down to the next band, `#n` selects colour
// register n and `#n;2;r;g;b` (percentages) or `#n;1;h;l;s` defines it, and
// `"pan;pad;w;h` declares the raster.
//
// The decoder is fed one byte at a time as the DCS arrives, so a large image
// is never held twice. Decisions, made against foot 1.16 as the oracle:
//
//   - Colour registers are private to each image and start as the VT340's
//     sixteen; there are 256 of them (what XTSMGRAPHICS reports).
//   - The aspect ratio is ignored, as foot and xterm do for anything that
//     declares a raster: a pixel is a pixel.
//   - P2 = 1 leaves unpainted pixels transparent; anything else paints them
//     in the background colour, as far as the declared raster reaches.
//   - The image is placed at the cursor, which ends on the last text row the
//     image covers, in the column it started in. foot does exactly this.
//   - Text printed over a Sixel image cuts that part of it, and a new Sixel
//     image replaces any old one it covers completely.
//   - Size is capped by the graphics budget: pixels past it are dropped, and
//     nothing is ever allocated beyond it.
// ---------------------------------------------------------------------------

SIXEL_REGISTERS :: 256

@(private = "file")
Sixel_State :: enum u8 {
	Data,
	Repeat,
	Color,
	Raster,
}

Sixel :: struct {
	active:     bool,
	state:      Sixel_State,
	params:     [5]int,
	nparams:    int,
	repeat:     int,
	transparent: bool,
	bg:         u32,
	palette:    [SIXEL_REGISTERS]u32,
	color:      u32,
	x, band:    int,
	// The pixel buffer grows as the image does: `w` and `h` are what has
	// been painted (or declared), `cap_w` and `cap_h` what is allocated.
	px:         []u32,
	cap_w:      int,
	cap_h:      int,
	w, h:       int,
	max_px:     int,
	clipped:    bool,
}

// The VT340's sixteen, in percent, which is what a stream that never defines
// a colour is drawn in.
@(private = "file")
VT340 := [16][3]u8 {
	{0, 0, 0}, {20, 20, 80}, {80, 13, 13}, {20, 80, 20},
	{80, 20, 80}, {20, 80, 80}, {80, 80, 20}, {53, 53, 53},
	{26, 26, 26}, {33, 33, 60}, {60, 26, 26}, {33, 60, 33},
	{60, 33, 60}, {33, 60, 60}, {60, 60, 33}, {80, 80, 80},
}

@(private = "file")
pct :: proc "contextless" (v: int) -> u32 {
	c := clamp(v, 0, 100)
	return u32((c * 255 + 50) / 100)
}

@(private = "file")
rgb_pct :: proc "contextless" (r, g, b: int) -> u32 {
	return 0xFF00_0000 | pct(r) << 16 | pct(g) << 8 | pct(b)
}

// hls converts DEC's HLS, whose hue starts at blue rather than red.
@(private = "file")
hls :: proc(h_in, l_in, s_in: int) -> u32 {
	h := f32((h_in + 240) % 360) / 360 // DEC 0 = blue = 240 standard
	l := f32(clamp(l_in, 0, 100)) / 100
	s := f32(clamp(s_in, 0, 100)) / 100
	if s == 0 {
		v := u32(l * 255 + 0.5)
		return 0xFF00_0000 | v << 16 | v << 8 | v
	}
	q := l < 0.5 ? l * (1 + s) : l + s - l * s
	p := 2 * l - q
	hue :: proc(p, q, t_in: f32) -> f32 {
		t := t_in
		if t < 0 {t += 1}
		if t > 1 {t -= 1}
		if t < 1.0 / 6 {return p + (q - p) * 6 * t}
		if t < 0.5 {return q}
		if t < 2.0 / 3 {return p + (q - p) * (2.0 / 3 - t) * 6}
		return p
	}
	r := u32(hue(p, q, h + 1.0 / 3) * 255 + 0.5)
	g := u32(hue(p, q, h) * 255 + 0.5)
	b := u32(hue(p, q, h - 1.0 / 3) * 255 + 0.5)
	return 0xFF00_0000 | r << 16 | g << 8 | b
}

sixel_begin :: proc(t: ^Terminal, a: Action) {
	sx := &t.sixel
	sixel_reset(sx)
	sx.active = true
	sx.transparent = param(a, 1, 0) == 1
	bg := terminal_bg(t)
	sx.bg = 0xFF00_0000 | u32(bg[0]) << 16 | u32(bg[1]) << 8 | u32(bg[2])
	for c, i in VT340 {
		sx.palette[i] = rgb_pct(int(c[0]), int(c[1]), int(c[2]))
	}
	for i in 16 ..< SIXEL_REGISTERS {
		sx.palette[i] = 0xFF00_0000
	}
	sx.color = sx.palette[0]
	sx.max_px = t.gfx.budget / 4
}

sixel_reset :: proc(sx: ^Sixel) {
	delete(sx.px)
	sx^ = {}
}

// grow makes sure pixel (x, y) exists, doubling the allocation as needed.
@(private = "file")
grow :: proc(sx: ^Sixel, need_w, need_h: int) -> bool {
	if need_w <= sx.cap_w && need_h <= sx.cap_h {
		return true
	}
	if need_w > MAX_IMAGE_SIDE || need_h > MAX_IMAGE_SIDE {
		sx.clipped = true
		return false
	}
	nw := max(sx.cap_w, 64)
	for nw < need_w {nw *= 2}
	nh := max(sx.cap_h, 60)
	for nh < need_h {nh *= 2}
	nw = min(nw, MAX_IMAGE_SIDE)
	nh = min(nh, MAX_IMAGE_SIDE)
	if nw * nh > sx.max_px {
		// Try the tight size before giving up.
		nw = max(sx.cap_w, need_w)
		nh = max(sx.cap_h, need_h)
		if nw * nh > sx.max_px {
			sx.clipped = true
			return false
		}
	}
	px := make([]u32, nw * nh)
	for y in 0 ..< sx.cap_h {
		copy(px[y * nw:][:sx.cap_w], sx.px[y * sx.cap_w:][:sx.cap_w])
	}
	delete(sx.px)
	sx.px = px
	sx.cap_w, sx.cap_h = nw, nh
	return true
}

// paint puts one sixel (six vertical bits) at the current position, `n`
// times across.
@(private = "file")
paint :: proc(sx: ^Sixel, bits: u8, n: int) {
	if n <= 0 {
		return
	}
	y0 := sx.band * 6
	x1 := sx.x + n
	if bits != 0 {
		top := 0
		for top < 6 && bits & (1 << uint(top)) == 0 {top += 1}
		bot := 5
		for bot > 0 && bits & (1 << uint(bot)) == 0 {bot -= 1}
		if grow(sx, x1, y0 + bot + 1) {
			for b in 0 ..< 6 {
				if bits & (1 << uint(b)) == 0 {
					continue
				}
				row := sx.px[(y0 + b) * sx.cap_w:]
				for x in sx.x ..< x1 {
					row[x] = sx.color
				}
			}
			sx.w = max(sx.w, x1)
			sx.h = max(sx.h, y0 + bot + 1)
		}
	}
	sx.x = x1
}

@(private = "file")
finish_params :: proc(sx: ^Sixel) {
	switch sx.state {
	case .Data:
	case .Repeat:
	case .Color:
		reg := sx.params[0] % SIXEL_REGISTERS
		if sx.nparams >= 5 {
			switch sx.params[1] {
			case 1:
				sx.palette[reg] = hls(sx.params[2], sx.params[3], sx.params[4])
			case 2:
				sx.palette[reg] = rgb_pct(sx.params[2], sx.params[3], sx.params[4])
			}
		}
		sx.color = sx.palette[reg]
	case .Raster:
		// "Pan;Pad;Ph;Pv: the declared size. Only the size matters here;
		// with an opaque background it is painted in, so a declared but
		// partly blank image still covers what it says it covers.
		if sx.nparams >= 4 {
			w := min(sx.params[2], MAX_IMAGE_SIDE)
			h := min(sx.params[3], MAX_IMAGE_SIDE)
			if w > 0 && h > 0 && grow(sx, w, h) {
				sx.w = max(sx.w, w)
				sx.h = max(sx.h, h)
			}
		}
	}
	sx.state = .Data
	sx.nparams = 0
	sx.params = {}
}

sixel_put :: proc(sx: ^Sixel, b: u8) {
	switch sx.state {
	case .Repeat:
		if b >= '0' && b <= '9' {
			sx.repeat = min(sx.repeat * 10 + int(b - '0'), MAX_IMAGE_SIDE)
			return
		}
		sx.state = .Data
		if b >= '?' && b <= '~' {
			paint(sx, b - '?', max(sx.repeat, 1))
			return
		}
	case .Color, .Raster:
		if b >= '0' && b <= '9' {
			if sx.nparams == 0 {sx.nparams = 1}
			i := sx.nparams - 1
			sx.params[i] = min(sx.params[i] * 10 + int(b - '0'), 100_000)
			return
		}
		if b == ';' {
			if sx.nparams == 0 {sx.nparams = 1}
			if sx.nparams < len(sx.params) {
				sx.nparams += 1
			}
			return
		}
		finish_params(sx)
	case .Data:
	}

	switch b {
	case '?' ..= '~':
		paint(sx, b - '?', 1)
	case '!':
		sx.state = .Repeat
		sx.repeat = 0
	case '#':
		sx.state = .Color
		sx.nparams = 0
		sx.params = {}
	case '"':
		sx.state = .Raster
		sx.nparams = 0
		sx.params = {}
	case '$':
		sx.x = 0
	case '-':
		sx.x = 0
		sx.band += 1
	}
}

// sixel_end turns what was decoded into an image and puts it on the screen.
sixel_end :: proc(t: ^Terminal) {
	sx := &t.sixel
	if !sx.active {
		return
	}
	if sx.state != .Data {
		finish_params(sx)
	}
	sx.active = false
	w, h := sx.w, sx.h
	if w <= 0 || h <= 0 {
		sixel_reset(sx)
		return
	}
	px := make([]u32, w * h)
	fill := sx.transparent ? 0 : sx.bg
	for y in 0 ..< h {
		src := sx.px[y * sx.cap_w:][:w]
		dst := px[y * w:][:w]
		for x in 0 ..< w {
			v := src[x]
			dst[x] = v == 0 ? fill : v
		}
	}
	sixel_reset(sx)
	img := image_add(t, px, w, h, true)
	if img == nil {
		return
	}
	pl := placement_new(&t.gfx, img)
	pl.sixel = true
	pl.z = -1
	placement_layout(pl)
	place_at_cursor(t, pl, true, t.modes.sixel_display)
}
