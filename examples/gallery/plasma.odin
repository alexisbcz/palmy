package main

import "core:math"
import p "../../palmy"

// Plasma is the state behind the live canvas panel. `p.pixels` hands the draw
// procedure a pointer to it, so no globals and no closures are needed.
Plasma :: struct {
	t:    f32,
	warp: f32,
}

draw_plasma :: proc(c: ^p.Canvas, r: p.Rect, s: ^Plasma) {
	x0 := max(int(r.x), 0)
	y0 := max(int(r.y), 0)
	x1 := min(int(r.x + r.w), c.w)
	y1 := min(int(r.y + r.h), c.h)

	k := 0.03 + s.warp * 0.05
	for y in y0 ..< y1 {
		fy := f32(y - y0)
		row := c.px[y * c.w:][:c.w]
		for x in x0 ..< x1 {
			fx := f32(x - x0)
			v := math.sin(fx * k + s.t)
			v += math.sin(fy * k * 0.8 - s.t * 1.2)
			v += math.sin((fx + fy) * k * 0.5 + s.t * 0.6)
			v = v / 6 + 0.5

			// Indigo to emerald, so the panel sits inside the palette.
			a := p.hex(0x4f46e5)
			b := p.hex(0x10b981)
			col := p.mix(a, b, v)
			row[x] = 0xff00_0000 | (u32(col.r) << 16) | (u32(col.g) << 8) | u32(col.b)
		}
	}
}
