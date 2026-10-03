package palmy

import "core:math"
import "core:mem"
import "core:strconv"

// ---------------------------------------------------------------------------
// Icons.
//
// Line icons such as lucide's are a handful of stroked paths on a square view
// box. This renders them directly: path data is flattened to polylines, and the
// stroke is accumulated into an 8-bit coverage mask as a union of capsules —
// taking the maximum per pixel rather than blending, so overlapping segments
// and joins do not darken where they meet. Round caps and round joins fall out
// of the capsule shape for free.
// ---------------------------------------------------------------------------

Icon :: struct {
	name:   string,
	d:      string, // SVG path data: M L C Q Z, absolute or relative
	view:   f32,    // view box edge, 24 for lucide
	stroke: f32,    // stroke width in view units, 2 for lucide
	fill:   bool,   // fill the path instead of stroking it
}

@(private)
Icon_Key :: struct {
	name:   string,
	size:   u16,
	stroke: u16, // tenths of a pixel
}

@(private)
Icon_Mask :: struct {
	mask: []u8,
	w, h: int,
}

Icons :: struct {
	cache: map[Icon_Key]Icon_Mask,
}

icons_init :: proc(ic: ^Icons) {
	ic.cache = make(map[Icon_Key]Icon_Mask)
}

icons_destroy :: proc(ic: ^Icons) {
	for _, m in ic.cache {
		delete(m.mask)
	}
	delete(ic.cache)
}

// ---------------------------------------------------------------------------
// Path parsing
// ---------------------------------------------------------------------------

@(private)
Path_Reader :: struct {
	s: string,
	i: int,
}

@(private)
skip_sep :: proc(r: ^Path_Reader) {
	for r.i < len(r.s) {
		c := r.s[r.i]
		if c == ' ' || c == ',' || c == '\t' || c == '\n' || c == '\r' {
			r.i += 1
		} else {
			break
		}
	}
}

@(private)
read_number :: proc(r: ^Path_Reader) -> (f32, bool) {
	skip_sep(r)
	start := r.i
	if r.i < len(r.s) && (r.s[r.i] == '-' || r.s[r.i] == '+') {
		r.i += 1
	}
	digits := false
	for r.i < len(r.s) {
		c := r.s[r.i]
		if c >= '0' && c <= '9' {
			digits = true
			r.i += 1
		} else if c == '.' {
			r.i += 1
		} else if c == 'e' || c == 'E' {
			r.i += 1
			if r.i < len(r.s) && (r.s[r.i] == '-' || r.s[r.i] == '+') {
				r.i += 1
			}
		} else {
			break
		}
	}
	if !digits {
		return 0, false
	}
	v, _ := strconv.parse_f64(r.s[start:r.i])
	return f32(v), true
}

@(private)
is_command :: proc(c: u8) -> bool {
	switch c {
	case 'M', 'm', 'L', 'l', 'H', 'h', 'V', 'v', 'C', 'c', 'S', 's', 'Q', 'q', 'T', 't', 'Z', 'z':
		return true
	}
	return false
}

// flatten turns path data into a list of polylines, in view-box units.
@(private)
flatten_path :: proc(d: string, allocator := context.temp_allocator) -> [dynamic][dynamic][2]f32 {
	polys := make([dynamic][dynamic][2]f32, allocator)
	cur := make([dynamic][2]f32, allocator)

	pos := [2]f32{0, 0}
	start := [2]f32{0, 0}
	last_ctrl := [2]f32{0, 0}
	had_curve := false

	flush :: proc(polys: ^[dynamic][dynamic][2]f32, cur: ^[dynamic][2]f32, allocator: mem.Allocator) {
		if len(cur) > 1 {
			append(polys, cur^)
		}
		cur^ = make([dynamic][2]f32, allocator)
	}

	// Cubic flattening at a fixed resolution; icons are small and this is well
	// under half a pixel of error at the sizes they are drawn.
	STEPS :: 24
	cubic :: proc(cur: ^[dynamic][2]f32, p0, p1, p2, p3: [2]f32) {
		for i in 1 ..= STEPS {
			t := f32(i) / STEPS
			u := 1 - t
			p :=
				p0 * (u * u * u) +
				p1 * (3 * u * u * t) +
				p2 * (3 * u * t * t) +
				p3 * (t * t * t)
			append(cur, p)
		}
	}

	r := Path_Reader{s = d}
	cmd: u8 = 0

	for {
		skip_sep(&r)
		if r.i >= len(r.s) {
			break
		}
		if is_command(r.s[r.i]) {
			cmd = r.s[r.i]
			r.i += 1
		}
		rel := cmd >= 'a' && cmd <= 'z'

		switch cmd {
		case 'M', 'm':
			x, okx := read_number(&r)
			y, oky := read_number(&r)
			if !okx || !oky {
				return polys
			}
			flush(&polys, &cur, allocator)
			pos = rel ? pos + {x, y} : {x, y}
			start = pos
			append(&cur, pos)
			// Subsequent coordinate pairs after a moveto are implicit linetos.
			cmd = rel ? 'l' : 'L'
			had_curve = false

		case 'L', 'l':
			x, okx := read_number(&r)
			y, oky := read_number(&r)
			if !okx || !oky {
				return polys
			}
			pos = rel ? pos + {x, y} : {x, y}
			append(&cur, pos)
			had_curve = false

		case 'H', 'h':
			x, ok := read_number(&r)
			if !ok {
				return polys
			}
			pos = rel ? {pos.x + x, pos.y} : {x, pos.y}
			append(&cur, pos)
			had_curve = false

		case 'V', 'v':
			y, ok := read_number(&r)
			if !ok {
				return polys
			}
			pos = rel ? {pos.x, pos.y + y} : {pos.x, y}
			append(&cur, pos)
			had_curve = false

		case 'C', 'c':
			x1, o1 := read_number(&r)
			y1, o2 := read_number(&r)
			x2, o3 := read_number(&r)
			y2, o4 := read_number(&r)
			x3, o5 := read_number(&r)
			y3, o6 := read_number(&r)
			if !(o1 && o2 && o3 && o4 && o5 && o6) {
				return polys
			}
			c1 := rel ? pos + {x1, y1} : [2]f32{x1, y1}
			c2 := rel ? pos + {x2, y2} : [2]f32{x2, y2}
			e := rel ? pos + {x3, y3} : [2]f32{x3, y3}
			if len(cur) == 0 {
				append(&cur, pos)
			}
			cubic(&cur, pos, c1, c2, e)
			last_ctrl = c2
			pos = e
			had_curve = true

		case 'S', 's':
			x2, o3 := read_number(&r)
			y2, o4 := read_number(&r)
			x3, o5 := read_number(&r)
			y3, o6 := read_number(&r)
			if !(o3 && o4 && o5 && o6) {
				return polys
			}
			c1 := had_curve ? pos * 2 - last_ctrl : pos
			c2 := rel ? pos + {x2, y2} : [2]f32{x2, y2}
			e := rel ? pos + {x3, y3} : [2]f32{x3, y3}
			if len(cur) == 0 {
				append(&cur, pos)
			}
			cubic(&cur, pos, c1, c2, e)
			last_ctrl = c2
			pos = e
			had_curve = true

		case 'Q', 'q':
			x1, o1 := read_number(&r)
			y1, o2 := read_number(&r)
			x2, o3 := read_number(&r)
			y2, o4 := read_number(&r)
			if !(o1 && o2 && o3 && o4) {
				return polys
			}
			q := rel ? pos + {x1, y1} : [2]f32{x1, y1}
			e := rel ? pos + {x2, y2} : [2]f32{x2, y2}
			// Raise the quadratic to a cubic.
			c1 := pos + (q - pos) * (2.0 / 3.0)
			c2 := e + (q - e) * (2.0 / 3.0)
			if len(cur) == 0 {
				append(&cur, pos)
			}
			cubic(&cur, pos, c1, c2, e)
			last_ctrl = q
			pos = e
			had_curve = true

		case 'Z', 'z':
			if len(cur) > 0 {
				append(&cur, start)
			}
			pos = start
			had_curve = false

		case:
			// Unknown command: stop rather than loop forever.
			return polys
		}
	}

	flush(&polys, &cur, allocator)
	return polys
}

// ---------------------------------------------------------------------------
// Rasterisation
// ---------------------------------------------------------------------------

// stroke_mask rasterises an icon into an 8-bit coverage mask at `size` pixels.
@(private)
build_mask :: proc(icon: Icon, size: f32) -> Icon_Mask {
	dim := int(math.ceil(size)) + 2
	m := Icon_Mask {
		mask = make([]u8, dim * dim),
		w    = dim,
		h    = dim,
	}

	scale := size / icon.view
	half := max(icon.stroke * scale * 0.5, 0.35)
	// Centre the glyph in the one pixel of padding.
	off := f32(1)

	polys := flatten_path(icon.d)
	cov := make([]f32, dim * dim, context.temp_allocator)

	for poly in polys {
		for i in 0 ..< len(poly) - 1 {
			ax := poly[i].x * scale + off
			ay := poly[i].y * scale + off
			bx := poly[i + 1].x * scale + off
			by := poly[i + 1].y * scale + off

			x0 := max(int(math.floor(min(ax, bx) - half - 1)), 0)
			y0 := max(int(math.floor(min(ay, by) - half - 1)), 0)
			x1 := min(int(math.ceil(max(ax, bx) + half + 1)), dim)
			y1 := min(int(math.ceil(max(ay, by) + half + 1)), dim)

			dx := bx - ax
			dy := by - ay
			len_sq := dx * dx + dy * dy

			for y in y0 ..< y1 {
				for x in x0 ..< x1 {
					px := f32(x) + 0.5 - ax
					py := f32(y) + 0.5 - ay
					t := len_sq > 0 ? clamp((px * dx + py * dy) / len_sq, 0, 1) : 0
					ex := px - dx * t
					ey := py - dy * t
					d := math.sqrt(ex * ex + ey * ey) - half
					c := clamp(0.5 - d, 0, 1)
					if c > 0 {
						idx := y * dim + x
						cov[idx] = max(cov[idx], c)
					}
				}
			}
		}
	}

	for v, i in cov {
		m.mask[i] = u8(clamp(v, 0, 1) * 255 + 0.5)
	}
	return m
}

@(private)
icon_mask :: proc(ic: ^Icons, icon: Icon, size: f32) -> Icon_Mask {
	key := Icon_Key {
		name   = icon.name,
		size   = u16(clamp(size + 0.5, 1, 1024)),
		stroke = u16(clamp(icon.stroke * 10, 0, 1000)),
	}
	if m, found := ic.cache[key]; found {
		return m
	}
	m := build_mask(icon, f32(key.size))
	ic.cache[key] = m
	return m
}

// draw_icon stamps an icon at the given top-left corner.
draw_icon :: proc(c: ^Canvas, ic: ^Icons, icon: Icon, x, y, size: f32, col: Color) {
	if icon.d == "" || size <= 0 {
		return
	}
	m := icon_mask(ic, icon, size)
	blit_mask(c, int(math.round(x)) - 1, int(math.round(y)) - 1, m.mask, m.w, m.h, col)
}
