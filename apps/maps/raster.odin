package main

// The rasterizer the map is drawn with.
//
// palmy gives you rounded rectangles, lines, circles and glyphs. A map needs
// something it does not have: an arbitrary filled polygon, with holes, and a
// stroked polyline with joins. So this file adds a scanline filler.
//
// How it works. Every subpath is reduced to a list of edges, each stored with
// the direction it was traversed in. For each pixel row an active edge list is
// maintained, and the row is sampled at SUB sub-scanlines. On each
// sub-scanline the edge crossings are sorted by x and walked, accumulating a
// winding number (nonzero) or a parity (even-odd); each inside span adds
// 1/SUB coverage into a float row, with fractional ends. The row is then
// blended in one pass. That gives vertical antialiasing from the sub-sampling
// and exact horizontal antialiasing from the fractional span ends, which is
// the same quality palmy's own shapes have and composites with `blend`, so a
// polygon edge and a rounded-rectangle edge look alike.
//
// Strokes go through the same filler. A polyline becomes a set of quads, one
// per segment, plus a polygon at each join; every one of them is emitted with
// the same orientation, so a nonzero fill is their union and overlapping
// pieces do not double-darken. That is what makes a road with a casing — a
// wide dark fill under a narrower light one — come out as a road rather than
// as a row of overlapping lozenges.

import "core:math"
import p "palmy:."

// SUB is the number of sub-scanlines per pixel row. Five is where the
// staircase on a near-horizontal edge stops being visible; the cost is linear
// in it.
SUB :: 5
INV_SUB :: f32(1.0) / f32(SUB)

Fill_Rule :: enum u8 {
	Nonzero,
	Even_Odd,
}

@(private = "file")
Edge :: struct {
	ytop:  f32, // the smaller y
	ybot:  f32,
	x:     f32, // x at ytop
	dxdy:  f32,
	// Only meaningful for an edge in the active list: where it crosses the
	// middle of the row being scanned. It is what the active list is kept
	// sorted by.
	cx:    f32,
	dir:   i8, // +1 the edge ran downward, -1 upward
}

@(private = "file")
Cross :: struct {
	x:   f32,
	dir: i8,
}

Raster :: struct {
	edges:  [dynamic]Edge,
	// Edges bucketed by the first pixel row they touch: `head[row]` is the
	// first, and `link[edge]` the next. A counting sort rather than a
	// comparison sort, because a dense frame hands the filler a quarter of a
	// million edges and O(n log n) on that is measurable where O(n) is not.
	head:   [dynamic]i32,
	link:   [dynamic]i32,
	// The active list holds *copies* of the edges rather than indices into
	// `edges`. Five sub-scanlines a row walk it, and with a hundred edges
	// live that is five hundred random reads into a quarter-megabyte array
	// per row; copying twenty bytes on admission turns all of them into one
	// sequential pass over two kilobytes, which fits in L1.
	active: [dynamic]Edge,
	xs:     [dynamic]Cross,
	cov:    [dynamic]f32,
	// A bit per DIRTY_BLOCK pixels of the coverage row, so blending and
	// clearing touch only the parts of the row something was actually drawn
	// into. Without it every fill that spans the canvas costs a pass over the
	// full width on every row whatever shape it is.
	dirty:  [dynamic]u64,
	clip:   p.Rect,
	ymin:   f32,
	ymax:   f32,
	// Current subpath.
	sx, sy: f32,
	cx, cy: f32,
	has:    bool,
	// Counters for the frame-time report: rows blended, edges submitted, and
	// how many times the active list was walked for a crossing.
	rows:   int,
	n_edges: int,
	n_active: int,
	n_blend: int,
}

raster_destroy :: proc(r: ^Raster) {
	delete(r.edges)
	delete(r.head)
	delete(r.link)
	delete(r.active)
	delete(r.dirty)
	delete(r.xs)
	delete(r.cov)
	r^ = {}
}

// raster_begin clears the path and sets the clip rectangle. Nothing outside it
// is ever touched, which is how the map panel stays inside its box.
raster_begin :: proc(r: ^Raster, clip: p.Rect) {
	clear(&r.edges)
	if cap(r.edges) < 4096 {
		reserve(&r.edges, 4096)
	}
	r.clip = clip
	r.ymin = 1e30
	r.ymax = -1e30
	r.has = false
	n := int(math.ceil(p.rect_right(clip))) - int(clip.x) + 2
	if len(r.cov) < n {
		resize(&r.cov, n)
	}
}

raster_move_to :: proc(r: ^Raster, x, y: f32) {
	raster_close(r)
	r.sx, r.sy = x, y
	r.cx, r.cy = x, y
	r.has = true
}

raster_line_to :: proc(r: ^Raster, x, y: f32) {
	if !r.has {
		raster_move_to(r, x, y)
		return
	}
	add_edge(r, r.cx, r.cy, x, y)
	r.cx, r.cy = x, y
}

// raster_close joins the current point back to where the subpath started. A
// fill always behaves as if every subpath were closed, which is what the
// even-odd and nonzero rules are defined against.
raster_close :: proc(r: ^Raster) {
	if !r.has {
		return
	}
	if r.cx != r.sx || r.cy != r.sy {
		add_edge(r, r.cx, r.cy, r.sx, r.sy)
	}
	r.cx, r.cy = r.sx, r.sy
	r.has = false
}

@(private = "file")
add_edge :: proc(r: ^Raster, x0, y0, x1, y1: f32) {
	if y0 == y1 {
		return // horizontal edges contribute no crossings
	}
	// Reject an edge entirely above or below the clip; it can never cross a
	// sampled sub-scanline. An edge to the left or right is kept, because the
	// winding number of a span inside the clip depends on it.
	top := math.min(y0, y1)
	bot := math.max(y0, y1)
	if bot <= r.clip.y || top >= p.rect_bottom(r.clip) {
		return
	}
	e: Edge
	if y0 < y1 {
		e = {ytop = y0, ybot = y1, x = x0, dxdy = (x1 - x0) / (y1 - y0), dir = 1}
	} else {
		e = {ytop = y1, ybot = y0, x = x1, dxdy = (x0 - x1) / (y0 - y1), dir = -1}
	}
	append(&r.edges, e)
	r.ymin = math.min(r.ymin, e.ytop)
	r.ymax = math.max(r.ymax, e.ybot)
}

// raster_fill scan-converts everything accumulated and blends it.
raster_fill :: proc(r: ^Raster, c: ^p.Canvas, col: p.Color, rule := Fill_Rule.Nonzero) {
	raster_close(r)
	if len(r.edges) == 0 || col.a == 0 {
		return
	}

	y0 := int(math.max(math.floor(r.ymin), math.floor(r.clip.y)))
	y1 := int(math.min(math.ceil(r.ymax), math.ceil(p.rect_bottom(r.clip))))
	x_lo := int(math.floor(r.clip.x))
	x_hi := int(math.ceil(p.rect_right(r.clip)))
	if y0 >= y1 || x_lo >= x_hi {
		return
	}
	y0 = max(y0, 0)
	y1 = min(y1, c.h)
	x_lo = max(x_lo, 0)
	x_hi = min(x_hi, c.w)
	if y0 >= y1 || x_lo >= x_hi {
		return
	}

	// Bucket every edge by the row it starts on. An edge that starts above the
	// top row goes into the top row's bucket, so it is admitted on the first
	// iteration and retired by the usual test.
	rows := y1 - y0
	if len(r.head) < rows {
		resize(&r.head, rows)
	}
	for i in 0 ..< rows {
		r.head[i] = -1
	}
	if len(r.link) < len(r.edges) {
		resize(&r.link, len(r.edges))
	}
	for i in 0 ..< len(r.edges) {
		row := int(math.floor(r.edges[i].ytop)) - y0
		if row >= rows {
			continue // starts below the last row we will visit
		}
		if row < 0 {
			row = 0
		}
		r.link[i] = r.head[row]
		r.head[row] = i32(i)
	}

	r.n_edges += len(r.edges)
	clear(&r.active)
	width := x_hi - x_lo
	nblocks := (width + DIRTY_BLOCK - 1) / DIRTY_BLOCK
	nwords := (nblocks + 63) / 64
	if len(r.dirty) < nwords {
		resize(&r.dirty, nwords)
	}
	for i in 0 ..< nwords {
		r.dirty[i] = 0
	}
	if len(r.cov) < width + 2 {
		resize(&r.cov, width + 2)
	}
	// The coverage row is left zeroed by whoever used it last, so only the
	// span actually written is cleared after each row. Clearing the whole row
	// instead costs a thousand float writes per row whatever the shape is,
	// which on a full-height polygon dominated everything else.
	cov := r.cov[:width]

	for y in y0 ..< y1 {
		row_top := f32(y)

		// Retire every edge that ended above the top of this row, keeping the
		// survivors in order — a swap-remove would be cheaper here and far
		// more expensive below, because the order is the whole point.
		mid := row_top + 0.5
		wj := 0
		for k in 0 ..< len(r.active) {
			if r.active[k].ybot > row_top {
				e := r.active[k]
				e.cx = e.x + (mid - e.ytop) * e.dxdy
				r.active[wj] = e
				wj += 1
			}
		}
		resize(&r.active, wj)
		for ei := r.head[y - y0]; ei >= 0; ei = r.link[ei] {
			e := r.edges[ei]
			e.cx = e.x + (mid - e.ytop) * e.dxdy
			append(&r.active, e)
		}
		if len(r.active) == 0 {
			continue
		}

		// Keep the active list sorted by where each edge crosses this row.
		//
		// This is the difference between a map that draws in two milliseconds
		// and one that draws in ten. The crossings on a sub-scanline have to
		// be in x order to be walked with a winding number, and sorting them
		// from an unordered active list is an insertion sort over fifty-odd
		// elements, five times a row, eight hundred rows — ten million
		// comparisons a frame. Sorted here instead, the list changes order
		// only where two edges actually cross, so the insertion sort is linear
		// from one row to the next and the per-sub-scanline sort has almost
		// nothing left to do.
		#no_bounds_check for i in 1 ..< len(r.active) {
			v := r.active[i]
			j := i - 1
			for j >= 0 && r.active[j].cx > v.cx {
				r.active[j + 1] = r.active[j]
				j -= 1
			}
			r.active[j + 1] = v
		}

		r.n_active += len(r.active) * SUB
		#no_bounds_check for s in 0 ..< SUB {
			sy := row_top + (f32(s) + 0.5) * INV_SUB
			clear(&r.xs)
			for &e in r.active {
				if sy < e.ytop || sy >= e.ybot {
					continue
				}
				append(&r.xs, Cross{x = e.x + (sy - e.ytop) * e.dxdy, dir = e.dir})
			}
			if len(r.xs) < 2 {
				continue
			}
			// Insertion sort: the crossing count per sub-scanline is small
			// even on a dense map, and it is already nearly sorted from the
			// previous sub-scanline's ordering of the same edges.
			for i in 1 ..< len(r.xs) {
				v := r.xs[i]
				j := i - 1
				for j >= 0 && r.xs[j].x > v.x {
					r.xs[j + 1] = r.xs[j]
					j -= 1
				}
				r.xs[j + 1] = v
			}

			wind := 0
			for i in 0 ..< len(r.xs) - 1 {
				switch rule {
				case .Nonzero:
					wind += int(r.xs[i].dir)
				case .Even_Odd:
					wind = wind == 0 ? 1 : 0
				}
				if wind == 0 {
					continue
				}
				a := r.xs[i].x
				b := r.xs[i + 1].x
				if b <= a {
					continue
				}
				slo, shi, any := add_span(cov, a, b, INV_SUB, x_lo, x_hi)
				if any {
					b0 := slo / DIRTY_BLOCK
					b1 := shi / DIRTY_BLOCK
					for bi in b0 ..= b1 {
						r.dirty[bi >> 6] |= u64(1) << uint(bi & 63)
					}
				}
			}
		}

		// Blend and clear only the blocks something landed in, and merge
		// adjacent ones so a wide shape is still one run.
		any_row := false
		bi := 0
		for bi < nblocks {
			if r.dirty[bi >> 6] & (u64(1) << uint(bi & 63)) == 0 {
				bi += 1
				continue
			}
			bj := bi
			for bj + 1 < nblocks && r.dirty[(bj + 1) >> 6] & (u64(1) << uint((bj + 1) & 63)) != 0 {
				bj += 1
			}
			lo := bi * DIRTY_BLOCK
			hi := min((bj + 1) * DIRTY_BLOCK, width)
			r.n_blend += hi - lo
			blend_row(c, cov[lo:hi], x_lo + lo, y, col)
			for i in lo ..< hi {
				cov[i] = 0
			}
			any_row = true
			bi = bj + 1
		}
		if any_row {
			r.rows += 1
		}
		for i in 0 ..< nwords {
			r.dirty[i] = 0
		}
	}
}

// blend_px is one pixel of src-over, with the same /255 rounding as blend_row
// and no division. The label blitter uses it too.
blend_px :: #force_inline proc "contextless" (row: []u32, x: int, cr, cg, cb: u32, a: u32) {
	if a == 0 {
		return
	}
	if a >= 255 {
		row[x] = 0xff00_0000 | (cr << 16) | (cg << 8) | cb
		return
	}
	na := 255 - a
	dst := row[x]
	tr := cr * a + ((dst >> 16) & 0xff) * na + 128
	tg := cg * a + ((dst >> 8) & 0xff) * na + 128
	tb := cb * a + (dst & 0xff) * na + 128
	row[x] =
		0xff00_0000 |
		((((tr + (tr >> 8)) >> 8) & 0xff) << 16) |
		((((tg + (tg >> 8)) >> 8) & 0xff) << 8) |
		(((tb + (tb >> 8)) >> 8) & 0xff)
}

// DIRTY_BLOCK is the granularity of the per-row touched mask. Sixteen pixels:
// small enough that a hairline road costs sixteen pixels of blending rather
// than a thousand, large enough that the mask itself is a couple of words.
DIRTY_BLOCK :: 16

// add_span accumulates coverage over [a, b) in pixel units, with fractional
// ends. Returns whether anything landed inside the clip.
@(private = "file")
add_span :: #force_inline proc(cov: []f32, a_in, b_in: f32, amt: f32, x_lo, x_hi: int) -> (lo, hi: int, any: bool) {
	a := math.max(a_in, f32(x_lo))
	b := math.min(b_in, f32(x_hi))
	if b <= a {
		return 0, 0, false
	}
	i0 := int(math.floor(a))
	i1 := int(math.floor(b))
	if i1 >= x_hi {
		i1 = x_hi - 1
	}
	if i0 == i1 {
		cov[i0 - x_lo] += (b - a) * amt
		return i0 - x_lo, i0 - x_lo, true
	}
	cov[i0 - x_lo] += (f32(i0 + 1) - a) * amt
	for i in i0 + 1 ..< i1 {
		cov[i - x_lo] += amt
	}
	cov[i1 - x_lo] += (b - f32(i1)) * amt
	return i0 - x_lo, i1 - x_lo, true
}

// blend_row composites one accumulated row.
//
// This is where a map frame's time goes, so it does its own src-over rather
// than calling the toolkit's per-pixel `blend`. Two reasons, both measured on
// a frame at zoom 14.5 that composites 1.2 million partially covered pixels:
//
//   * `blend` divides by 255 three times per pixel. An integer division is
//     twenty-odd cycles; `(t + (t >> 8)) >> 8` after adding 128 rounds exactly
//     the same way for every value this can produce, in three.
//   * a cross-package call per pixel is a call per pixel.
//
// Together they took the middle zoom from 31 ms a frame to single figures. The
// arithmetic is identical to palmy's, so a polygon edge still composites the
// same as a rounded rectangle's.
@(private = "file")
blend_row :: proc(c: ^p.Canvas, cov: []f32, x_lo, y: int, col: p.Color) {
	row := c.px[y * c.w:][:c.w]
	solid := u32(0xff00_0000) | (u32(col.r) << 16) | (u32(col.g) << 8) | u32(col.b)
	opaque := col.a >= 255
	ca := f32(col.a)
	cr := u32(col.r)
	cg := u32(col.g)
	cb := u32(col.b)

	#no_bounds_check for i := 0; i < len(cov); i += 1 {
		v := cov[i]
		if v <= 0.002 {
			continue
		}
		if opaque && v >= 0.998 {
			// A run of full coverage is the interior of a shape, which on a
			// filled polygon is most of it.
			j := i
			for j < len(cov) && cov[j] >= 0.998 {
				row[x_lo + j] = solid
				j += 1
			}
			i = j - 1
			continue
		}
		a := u32(v * ca + 0.5)
		if a == 0 {
			continue
		}
		na := 255 - a
		dst := row[x_lo + i]
		tr := cr * a + ((dst >> 16) & 0xff) * na + 128
		tg := cg * a + ((dst >> 8) & 0xff) * na + 128
		tb := cb * a + (dst & 0xff) * na + 128
		row[x_lo + i] =
			0xff00_0000 |
			((((tr + (tr >> 8)) >> 8) & 0xff) << 16) |
			((((tg + (tg >> 8)) >> 8) & 0xff) << 8) |
			(((tb + (tb >> 8)) >> 8) & 0xff)
	}
}

// ---------------------------------------------------------------------------
// Strokes
// ---------------------------------------------------------------------------

// stroke_polyline adds a stroked polyline to the path. Every piece is emitted
// counter-clockwise in screen space, so a nonzero fill unions them.
//
// `pts` is screen-space and may be long; `closed` joins the last point to the
// first, which is what an area outline needs.
stroke_polyline :: proc(r: ^Raster, pts: [][2]f32, width: f32, closed := false, round := true) {
	if len(pts) < 2 {
		if len(pts) == 1 && width > 0 {
			add_disc(r, pts[0].x, pts[0].y, width / 2)
		}
		return
	}
	half := math.max(width, 0.35) / 2
	n := len(pts)
	last := closed ? n : n - 1
	for i in 0 ..< last {
		a := pts[i]
		b := pts[(i + 1) % n]
		dx, dy := b.x - a.x, b.y - a.y
		l := math.sqrt(dx * dx + dy * dy)
		if l < 1e-6 {
			continue
		}
		nx, ny := -dy / l * half, dx / l * half
		quad(r, a.x + nx, a.y + ny, b.x + nx, b.y + ny, b.x - nx, b.y - ny, a.x - nx, a.y - ny)
	}
	if !round || half <= 0.6 {
		return
	}
	// A disc at each interior vertex is the join. Round joins, because a map's
	// roads curve and a miter on a tight bend on a winding street spikes.
	//
	// But only where the bend leaves a gap worth filling. Two quads meeting at
	// an angle leave a notch about `half * (1 - cos(delta/2))` deep, and below
	// a third of a pixel nobody can see it. A winding residential street turns
	// by twenty degrees at every vertex, which at a three-pixel stroke is a
	// notch of a twentieth of a pixel — and there are twelve thousand of them
	// in a frame. Skipping those discs took the middle zoom's stroke work down
	// by about two thirds.
	lo := closed ? 0 : 1
	hi := closed ? n : n - 1
	for i in lo ..< hi {
		a := pts[(i - 1 + n) % n]
		b := pts[i]
		cq := pts[(i + 1) % n]
		d0x, d0y := b.x - a.x, b.y - a.y
		d1x, d1y := cq.x - b.x, cq.y - b.y
		l0 := math.sqrt(d0x * d0x + d0y * d0y)
		l1 := math.sqrt(d1x * d1x + d1y * d1y)
		if l0 < 1e-6 || l1 < 1e-6 {
			continue
		}
		// cos of the turn, from the dot product of the unit tangents.
		ct := clamp((d0x * d1x + d0y * d1y) / (l0 * l1), -1, 1)
		// cos(delta/2) from the half-angle identity, with delta the turn.
		half_cos := math.sqrt(math.max(0, (1 + ct) / 2))
		if half * (1 - half_cos) < 0.33 {
			continue
		}
		add_disc(r, pts[i].x, pts[i].y, half)
	}
}

// stroke_caps rounds the two ends of an open polyline, which keeps a road from
// ending in a sharp corner where it leaves the viewport.
stroke_caps :: proc(r: ^Raster, pts: [][2]f32, width: f32) {
	half := math.max(width, 0.35) / 2
	// Below about three pixels across, a square end and a round one differ by
	// a corner the antialiasing already softens.
	if len(pts) == 0 || half <= 1.5 {
		return
	}
	add_disc(r, pts[0].x, pts[0].y, half)
	add_disc(r, pts[len(pts) - 1].x, pts[len(pts) - 1].y, half)
}

// quad adds a quadrilateral, flipped to counter-clockwise if it is not.
@(private = "file")
quad :: proc(r: ^Raster, x0, y0, x1, y1, x2, y2, x3, y3: f32) {
	area := (x1 - x0) * (y2 - y0) - (x2 - x0) * (y1 - y0)
	if area >= 0 {
		raster_move_to(r, x0, y0)
		raster_line_to(r, x1, y1)
		raster_line_to(r, x2, y2)
		raster_line_to(r, x3, y3)
	} else {
		raster_move_to(r, x3, y3)
		raster_line_to(r, x2, y2)
		raster_line_to(r, x1, y1)
		raster_line_to(r, x0, y0)
	}
	raster_close(r)
}

// add_disc approximates a circle. The segment count follows the radius so a
// 1px join is a triangle and a 20px one is smooth.
@(private = "file")
add_disc :: proc(r: ^Raster, cx, cy, rad: f32) {
	if rad <= 0.2 {
		return
	}
	segs := clamp(int(rad * 2.2) + 5, 6, 28)
	raster_move_to(r, cx + rad, cy)
	for i in 1 ..< segs {
		a := f32(i) / f32(segs) * 2 * math.PI
		raster_line_to(r, cx + rad * math.cos(a), cy + rad * math.sin(a))
	}
	raster_close(r)
}

// add_rect is a convenience for an axis-aligned box in the same path.
add_rect :: proc(r: ^Raster, x, y, w, h: f32) {
	raster_move_to(r, x, y)
	raster_line_to(r, x + w, y)
	raster_line_to(r, x + w, y + h)
	raster_line_to(r, x, y + h)
	raster_close(r)
}

add_circle :: proc(r: ^Raster, cx, cy, rad: f32) {
	add_disc(r, cx, cy, rad)
}

// ---------------------------------------------------------------------------
// Clipping a polyline to a rectangle
// ---------------------------------------------------------------------------

// clip_polyline splits a polyline against a rectangle and appends the pieces
// that are inside to `out`, each as a run of points with its length recorded.
//
// This matters for more than correctness: a street that runs for a hundred
// kilometres off the side of a zoomed-in viewport would otherwise be stroked
// over its whole length, with every quad rejected one at a time. Clipping
// first turns that into two vertices.
Run :: struct {
	first: int,
	count: int,
}

clip_polyline :: proc(
	pts: [][2]f32,
	clip: p.Rect,
	out: ^[dynamic][2]f32,
	runs: ^[dynamic]Run,
) {
	if len(pts) < 2 {
		if len(pts) == 1 && p.rect_contains(clip, pts[0].x, pts[0].y) {
			append(runs, Run{len(out), 1})
			append(out, pts[0])
		}
		return
	}
	x0, y0 := clip.x, clip.y
	x1, y1 := p.rect_right(clip), p.rect_bottom(clip)

	open := false
	for i in 0 ..< len(pts) - 1 {
		b_orig := pts[i + 1]
		ca, cb := pts[i], b_orig
		if !clip_segment(&ca, &cb, x0, y0, x1, y1) {
			open = false
			continue
		}
		// A run continues only when this segment starts exactly where the last
		// one ended; otherwise the stretch between them was outside and the
		// polyline must be broken, or the join would cut across the viewport.
		if open && out[len(out) - 1] == ca {
			append(out, cb)
			runs[len(runs) - 1].count += 1
		} else {
			append(runs, Run{len(out), 2})
			append(out, ca)
			append(out, cb)
			open = true
		}
		if cb != b_orig {
			open = false // the segment was cut short at the boundary
		}
	}
}

// clip_segment is Liang-Barsky. It moves the endpoints onto the clip boundary
// and returns false when the segment misses the rectangle entirely.
@(private = "file")
clip_segment :: proc(a, b: ^[2]f32, x0, y0, x1, y1: f32) -> bool {
	t0, t1 := f32(0), f32(1)
	dx := b.x - a.x
	dy := b.y - a.y
	ax, ay := a.x, a.y

	test :: proc(p_, q: f32, t0, t1: ^f32) -> bool {
		if p_ == 0 {
			return q >= 0
		}
		t := q / p_
		if p_ < 0 {
			if t > t1^ {
				return false
			}
			if t > t0^ {
				t0^ = t
			}
		} else {
			if t < t0^ {
				return false
			}
			if t < t1^ {
				t1^ = t
			}
		}
		return true
	}

	if !test(-dx, ax - x0, &t0, &t1) {return false}
	if !test(dx, x1 - ax, &t0, &t1) {return false}
	if !test(-dy, ay - y0, &t0, &t1) {return false}
	if !test(dy, y1 - ay, &t0, &t1) {return false}

	b^ = {ax + t1 * dx, ay + t1 * dy}
	a^ = {ax + t0 * dx, ay + t0 * dy}
	return true
}
