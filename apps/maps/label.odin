package main

// Labels: the part that separates a map from a plot.
//
// Three problems, and they are all solved here.
//
// 1. Text that follows a line. palmy draws horizontal runs; a street name has
//    to lie along the street. There is no public way to get at a glyph's
//    coverage mask, so a label is rendered once into a scratch buffer with
//    `p.draw_text` and then each character's column range is resampled into
//    the canvas with its own rotation. See `mask_*` and `blit_rot`.
//
// 2. A halo. Dark text on a pale map needs a light outline or it disappears
//    over a road. The scratch buffer is dilated with a separable max filter,
//    which gives an outline of uniform width for the cost of two passes over a
//    small bitmap.
//
// 3. Collisions. No two labels may overlap, the more important feature wins,
//    and — the hard part — a label must not blink as you pan by a pixel. Three
//    things together give that:
//
//    * Candidate positions are derived from the *feature's own geometry*, not
//      from what is visible. A street's label sits at a fixed fraction of that
//      street's total length, so panning slides it rather than re-choosing it.
//    * The priority order is (rank, feature index, anchor) — total, and
//      independent of the viewport, so the same contest has the same winner
//      every frame.
//    * Placement runs over the viewport grown by LABEL_MARGIN, so a label just
//      off screen still takes part in the contest and still blocks the ones
//      behind it. Without that, a label entering from the left would displace
//      something in the middle of the screen the instant its anchor crossed
//      the edge.
//
//    Together those make placement a pure function of the geometry and the
//    viewport, and every decision in it is invariant under translating the
//    viewport. So a one-pixel pan moves every label a pixel and changes
//    nothing else. There is deliberately *no* hysteresis term; see the comment
//    in place.odin for the oscillation one causes.
//
//    `prev` and `cur` are still kept, because they are what the frame counter
//    in the status bar reports, and because they are the hook a future
//    cross-fade would need.

import "core:math"
import "core:strings"
import p "palmy:."

// Placement runs over the viewport grown by this much, in pixels, so labels
// crossing the edge are decided consistently.
LABEL_MARGIN :: f32(220)

// Chunk is a run of bytes of a label drawn at one position and angle. A
// horizontal label is a single chunk; a label following a line is one chunk per
// character.
Chunk :: struct {
	first, last: i32, // byte range in the label's text
	x, y:        f32, // pen origin on the baseline
	angle:       f32, // radians, clockwise on screen
}

Box :: struct {
	x, y, w, h: f32,
}

// Cell_Node links one box into one grid cell.
Cell_Node :: struct {
	box:  i32,
	next: i32,
}

box_overlaps :: proc(a, b: Box) -> bool {
	return a.x < b.x + b.w && b.x < a.x + a.w && a.y < b.y + b.h && b.y < a.y + a.h
}

Label_Kind :: enum u8 {
	Place,
	Area,
	Street,
	Building,
	Marker,
}

Label :: struct {
	text:        string,
	size:        f32,
	weight:      p.Font_Weight,
	col:         p.Color,
	halo:        p.Color,
	halo_width:  f32,
	kind:        Label_Kind,
	feat:        i32,
	// A symbol drawn at (dot_x, dot_y) before the text, for a place or a POI.
	dot:         f32,
	dot_x:       f32,
	dot_y:       f32,
	chunk_first: i32,
	chunk_count: i32,
	box_first:   i32,
	box_count:   i32,
}

// Labeller owns the per-frame placement and the collision index.
Labeller :: struct {
	labels:  [dynamic]Label,
	chunks:  [dynamic]Chunk,
	// Every placed box, once each and in placement order. The self-test
	// asserts that no two of these intersect, so it must hold no duplicates —
	// which is why the grid links through a separate node array rather than
	// through the boxes themselves.
	boxes:   [dynamic]Box,
	// The collision grid: a bucket per cell, each a linked list of nodes that
	// point at a box. A box wider than a cell gets one node per cell it
	// touches.
	cells:   [dynamic]Cell_Node,
	order:   [dynamic]i32,    // draw order, grouped by label text
	pivots:  [dynamic][2]f32, // one chunk's mask column span
	heads:   [dynamic]i32, // one per cell, -1 when empty
	cell:    f32,
	gx, gy:  int,
	gorigin: [2]f32,
	// Which features carried a label last frame, for the hysteresis bonus.
	prev:    map[i32]bool,
	cur:     map[i32]bool,
	// Scratch.
	cands:   [dynamic]Cand,
	pts:     [dynamic][2]f32, // a projected ring
	rev:     [dynamic][2]f32, // the same ring, reversed
	cum:     [dynamic]f32,    // cumulative screen length along it
	cbox:    [dynamic]Box,    // boxes of the candidate being tried
	cchunk:  [dynamic]Chunk,  // chunks of the candidate being tried
	adv:     [dynamic]f32,    // cumulative advance per rune boundary
	bnd:     [dynamic]i32,    // byte offset of each rune boundary
	mask:    Text_Mask,
	cache:   Mask_Cache,
	// Counters for the report.
	n_tried: int,
	n_placed: int,
}

Cand :: struct {
	feat:  i32,
	key:   f32, // sort key, descending
	kind:  Label_Kind,
	// For a street, which anchor along the line this candidate is.
	anchor: f32,
	seq:    i32,
}

labeller_init :: proc(l: ^Labeller) {
	l.cell = 48
	l.prev = make(map[i32]bool)
	l.cur = make(map[i32]bool)
}

labeller_destroy :: proc(l: ^Labeller) {
	delete(l.labels)
	delete(l.chunks)
	delete(l.boxes)
	delete(l.cells)
	delete(l.order)
	delete(l.pivots)
	delete(l.heads)
	delete(l.prev)
	delete(l.cur)
	delete(l.cands)
	delete(l.pts)
	delete(l.rev)
	delete(l.cum)
	delete(l.cbox)
	delete(l.cchunk)
	delete(l.adv)
	delete(l.bnd)
	mask_destroy(&l.mask)
	cache_destroy(&l.cache)
}

// labeller_begin clears the frame and sizes the collision grid to the region
// labels may be placed in.
labeller_begin :: proc(l: ^Labeller, region: p.Rect) {
	clear(&l.labels)
	clear(&l.chunks)
	clear(&l.boxes)
	clear(&l.cells)
	clear(&l.cands)
	l.n_tried, l.n_placed = 0, 0

	l.gorigin = {region.x, region.y}
	l.gx = max(1, int(math.ceil(region.w / l.cell)))
	l.gy = max(1, int(math.ceil(region.h / l.cell)))
	n := l.gx * l.gy
	if len(l.heads) < n {
		resize(&l.heads, n)
	}
	for i in 0 ..< n {
		l.heads[i] = -1
	}

	clear(&l.cur)
}

// labeller_end rolls the placed set forward, which is what gives the
// hysteresis something to remember.
labeller_end :: proc(l: ^Labeller) {
	clear(&l.prev)
	for k in l.cur {
		l.prev[k] = true
	}
}

// sort_labels groups the draw order by (text, size, weight) so the mask can be
// reused across a run. Heapsort, in place, over an index array.
@(private = "file")
sort_labels :: proc(labels: []Label, idx: []i32) {
	less :: proc(a, b: Label) -> bool {
		if a.text != b.text {
			return a.text < b.text
		}
		if a.size != b.size {
			return a.size < b.size
		}
		if a.weight != b.weight {
			return a.weight < b.weight
		}
		return a.halo_width < b.halo_width
	}
	n := len(idx)
	if n < 2 {
		return
	}
	sift :: proc(labels: []Label, idx: []i32, lo, hi: int) {
		root := lo
		for {
			child := 2 * root + 1
			if child >= hi {
				return
			}
			if child + 1 < hi && less(labels[idx[child]], labels[idx[child + 1]]) {
				child += 1
			}
			if less(labels[idx[child]], labels[idx[root]]) {
				return
			}
			idx[root], idx[child] = idx[child], idx[root]
			root = child
		}
	}
	for i := n / 2 - 1; i >= 0; i -= 1 {
		sift(labels, idx, i, n)
	}
	for i := n - 1; i > 0; i -= 1 {
		idx[0], idx[i] = idx[i], idx[0]
		sift(labels, idx, 0, i)
	}
}

// ---------------------------------------------------------------------------
// Collision
// ---------------------------------------------------------------------------

@(private = "file")
cell_range :: proc(l: ^Labeller, b: Box) -> (x0, y0, x1, y1: int) {
	x0 = clamp(int((b.x - l.gorigin.x) / l.cell), 0, l.gx - 1)
	y0 = clamp(int((b.y - l.gorigin.y) / l.cell), 0, l.gy - 1)
	x1 = clamp(int((b.x + b.w - l.gorigin.x) / l.cell), 0, l.gx - 1)
	y1 = clamp(int((b.y + b.h - l.gorigin.y) / l.cell), 0, l.gy - 1)
	return
}

// boxes_free reports whether every one of the candidate boxes is clear.
boxes_free :: proc(l: ^Labeller, cand: []Box) -> bool {
	for b in cand {
		x0, y0, x1, y1 := cell_range(l, b)
		for cy in y0 ..= y1 {
			for cx in x0 ..= x1 {
				i := l.heads[cy * l.gx + cx]
				for i >= 0 {
					n := l.cells[i]
					if box_overlaps(b, l.boxes[n.box]) {
						return false
					}
					i = n.next
				}
			}
		}
	}
	return true
}

// boxes_insert commits the boxes and returns their span in `l.boxes`.
boxes_insert :: proc(l: ^Labeller, cand: []Box) -> (first, count: i32) {
	first = i32(len(l.boxes))
	for b in cand {
		bi := i32(len(l.boxes))
		append(&l.boxes, b)
		x0, y0, x1, y1 := cell_range(l, b)
		for cy in y0 ..= y1 {
			for cx in x0 ..= x1 {
				c := cy * l.gx + cx
				ni := i32(len(l.cells))
				append(&l.cells, Cell_Node{box = bi, next = l.heads[c]})
				l.heads[c] = ni
			}
		}
	}
	return first, i32(len(l.boxes)) - first
}

// ---------------------------------------------------------------------------
// The scratch text mask
// ---------------------------------------------------------------------------

MASK_PAD :: 6

Text_Mask :: struct {
	px:     []u32,
	cv:     p.Canvas,
	w, h:   int,
	a:      []u8, // coverage
	halo:   []u8, // dilated coverage
	// The sub-rectangle of the buffer the last render used.
	used_w:   int,
	used_h:   int,
	// Where the drawn text sits in the buffer.
	text_w:   f32,
	baseline: f32,
	ascent:   f32,
	descent:  f32,
}

mask_destroy :: proc(tm: ^Text_Mask) {
	delete(tm.px)
	delete(tm.a)
	delete(tm.halo)
	p.canvas_destroy(&tm.cv)
	tm^ = {}
}

@(private = "file")
mask_ensure :: proc(tm: ^Text_Mask, w, h: int) {
	if tm.w >= w && tm.h >= h {
		return
	}
	nw := max(w, tm.w)
	nh := max(h, tm.h)
	delete(tm.px)
	delete(tm.a)
	delete(tm.halo)
	tm.px = make([]u32, nw * nh)
	tm.a = make([]u8, nw * nh)
	tm.halo = make([]u8, nw * nh)
	tm.w, tm.h = nw, nh
	p.canvas_destroy(&tm.cv)
	tm.cv = p.canvas_from(tm.px, nw, nh, 1)
}

// mask_render draws the text white on black into the scratch buffer and takes
// one channel as coverage. Drawing through `p.draw_text` is the point: the
// glyphs are the same rasterizer, the same hinting and the same subpixel
// positioning as the rest of the toolkit, so a rotated label is not a
// different typeface from the UI around it.
// GAMMA_LUT applies the text contrast curve that `p.set_text_gamma` would
// otherwise apply inside the glyph blitter.
//
// It has to move out of the blitter because the blitter applies it with a
// `pow` *per glyph pixel*, and a frame with eighty-five map labels in it
// rasterises a hundred thousand of them. The same curve over a 256-entry table,
// applied once when the mask is copied out, is one load instead.
@(private = "file")
gamma_lut: [256]u8
@(private = "file")
gamma_ready := false

@(private = "file")
ensure_gamma_lut :: proc() {
	if gamma_ready {
		return
	}
	for i in 0 ..< 256 {
		gamma_lut[i] = u8(clamp(math.pow(f32(i) / 255, 1.0 / 1.8) * 255 + 0.5, 0, 255))
	}
	gamma_ready = true
}

mask_render :: proc(tm: ^Text_Mask, fonts: ^p.Fonts, text: string, size: f32, wt: p.Font_Weight, halo_w: f32) {
	ensure_gamma_lut()
	met := p.font_metrics(fonts, size, .Sans, wt)
	tw := p.text_width(fonts, text, size, .Sans, wt)
	pad := MASK_PAD + int(math.ceil(halo_w)) + 1
	w := int(math.ceil(tw)) + 2 * pad
	h := int(math.ceil(met.ascent + met.descent)) + 2 * pad
	mask_ensure(tm, w, h)

	// Only the sub-rectangle in use is cleared; the buffer is reused for every
	// label in the frame and clearing all of it would dominate.
	for y in 0 ..< h {
		row := tm.px[y * tm.w:][:w]
		for x in 0 ..< w {
			row[x] = 0xff00_0000
		}
	}
	tm.cv.clip = {0, 0, f32(w), f32(h)}
	tm.used_w, tm.used_h = w, h
	tm.baseline = f32(pad) + met.ascent
	tm.text_w = tw
	tm.ascent, tm.descent = met.ascent, met.descent
	// Draw the glyphs with the contrast curve switched off; it is reapplied
	// through the table below. The setting is global to palmy, so it is put
	// back immediately — nothing else paints in between, this being a leaf of
	// one custom draw procedure.
	p.set_text_gamma(1.0)
	p.draw_text(&tm.cv, fonts, text, f32(pad), tm.baseline, size, p.WHITE, .Sans, wt)
	p.set_text_gamma(1.8)

	#no_bounds_check for y in 0 ..< h {
		src := tm.px[y * tm.w:][:w]
		dst := tm.a[y * tm.w:][:w]
		for x in 0 ..< w {
			dst[x] = gamma_lut[src[x] & 0xff]
		}
	}
	mask_dilate(tm, w, h, int(math.ceil(halo_w)))
}

// mask_dilate is a separable max filter: the halo. Two linear passes, so the
// cost does not grow with the square of the radius.
@(private = "file")
mask_dilate :: proc(tm: ^Text_Mask, w, h, rad: int) {
	if rad <= 0 {
		copy(tm.halo, tm.a)
		return
	}
	// Horizontal into halo.
	for y in 0 ..< h {
		src := tm.a[y * tm.w:][:w]
		dst := tm.halo[y * tm.w:][:w]
		for x in 0 ..< w {
			m := u8(0)
			lo := max(0, x - rad)
			hi := min(w - 1, x + rad)
			for k in lo ..= hi {
				if src[k] > m {
					m = src[k]
				}
			}
			dst[x] = m
		}
	}
	// Vertical, in place via the px buffer as scratch (it is free now).
	for x in 0 ..< w {
		for y in 0 ..< h {
			m := u8(0)
			lo := max(0, y - rad)
			hi := min(h - 1, y + rad)
			for k in lo ..= hi {
				v := tm.halo[k * tm.w + x]
				if v > m {
					m = v
				}
			}
			tm.px[y * tm.w + x] = u32(m)
		}
	}
	for y in 0 ..< h {
		for x in 0 ..< w {
			tm.halo[y * tm.w + x] = u8(tm.px[y * tm.w + x])
		}
	}
}

// ---------------------------------------------------------------------------
// The mask cache
// ---------------------------------------------------------------------------
//
// Rendering a label's glyphs costs more than it should, and not because of
// anything this program does: palmy composites glyph coverage in linear light,
// and `linear_to_srgb` is a `pow` per channel per pixel. For interface text —
// a few hundred pixels a frame — that is invisible. For a map it is not:
// eighty-five labels is a hundred thousand glyph pixels and three hundred
// thousand `pow` calls, which measured at about ten milliseconds a frame.
//
// The toolkit is not ours to change, so the work is done once instead of every
// frame. A label's rasterised mask depends only on its text, size, weight and
// halo width — never on where it sits — so it is cached across frames and a
// pan costs no glyph rasterisation at all. Entries unused for a while are
// dropped, which bounds the memory at a few megabytes on any real data.

MASK_CACHE_BYTES :: 8 << 20
MASK_CACHE_IDLE :: 240 // frames an entry may go unused before it is dropped

Mask_Entry :: struct {
	text:     string,
	size:     f32,
	weight:   p.Font_Weight,
	halo_w:   f32,
	w, h:     int,
	baseline: f32,
	// The rows of the mask that actually hold ink, halo included. The blitter
	// walks the destination rectangle this maps to, and a label's bitmap is
	// mostly empty above the capitals and below the descenders — bounding it
	// properly more than halves the pixels a rotated blit touches.
	ink_y0:   int,
	ink_y1:   int,
	a:        []u8,
	halo:     []u8,
	used:     u32,
}

Mask_Cache :: struct {
	items: [dynamic]Mask_Entry,
	index: map[u64][dynamic]i32,
	stamp: u32,
	bytes: int,
	hits:  int,
	misses: int,
}

cache_destroy :: proc(mc: ^Mask_Cache) {
	for &e in mc.items {
		delete(e.a)
		delete(e.halo)
		delete(e.text)
	}
	delete(mc.items)
	for _, &v in mc.index {
		delete(v)
	}
	delete(mc.index)
	mc^ = {}
}

@(private = "file")
mask_key :: proc(text: string, size: f32, wt: p.Font_Weight, halo_w: f32) -> u64 {
	h := u64(0xcbf29ce484222325)
	for b in transmute([]u8)text {
		h = (h ~ u64(b)) * 0x100000001b3
	}
	h = (h ~ u64(transmute(u32)size)) * 0x100000001b3
	h = (h ~ u64(wt)) * 0x100000001b3
	h = (h ~ u64(transmute(u32)halo_w)) * 0x100000001b3
	return h
}

// mask_get returns the rasterised mask for a label, rendering it on a miss.
mask_get :: proc(
	l: ^Labeller,
	fonts: ^p.Fonts,
	text: string,
	size: f32,
	wt: p.Font_Weight,
	halo_w: f32,
) -> ^Mask_Entry {
	mc := &l.cache
	k := mask_key(text, size, wt, halo_w)
	if bucket, ok := &mc.index[k]; ok {
		for idx in bucket {
			e := &mc.items[idx]
			if e.text == text && e.size == size && e.weight == wt && e.halo_w == halo_w {
				e.used = mc.stamp
				mc.hits += 1
				return e
			}
		}
	}
	mc.misses += 1
	mask_render(&l.mask, fonts, text, size, wt, halo_w)
	tm := &l.mask
	// The scratch buffer is wider than the label; pack the used rectangle.
	w := tm.used_w
	h := tm.used_h
	e := Mask_Entry {
		text     = strings.clone(text),
		size     = size,
		weight   = wt,
		halo_w   = halo_w,
		w        = w,
		h        = h,
		baseline = tm.baseline,
		a        = make([]u8, w * h),
		halo     = make([]u8, w * h),
		used     = mc.stamp,
	}
	e.ink_y0 = h
	e.ink_y1 = 0
	for y in 0 ..< h {
		copy(e.a[y * w:][:w], tm.a[y * tm.w:][:w])
		copy(e.halo[y * w:][:w], tm.halo[y * tm.w:][:w])
		row := e.halo[y * w:][:w]
		for x in 0 ..< w {
			if row[x] != 0 {
				if y < e.ink_y0 {
					e.ink_y0 = y
				}
				e.ink_y1 = y + 1
				break
			}
		}
	}
	if e.ink_y1 <= e.ink_y0 {
		e.ink_y0, e.ink_y1 = 0, h
	}
	mc.bytes += 2 * w * h
	append(&mc.items, e)
	idx := i32(len(mc.items) - 1)
	if bucket, ok := &mc.index[k]; ok {
		append(bucket, idx)
	} else {
		b := make([dynamic]i32)
		append(&b, idx)
		mc.index[k] = b
	}
	if mc.bytes > MASK_CACHE_BYTES {
		cache_sweep(mc)
	}
	return &mc.items[idx]
}

// cache_sweep drops everything that has not been asked for recently and
// rebuilds the index, which is simpler and no slower than unlinking in place.
@(private = "file")
cache_sweep :: proc(mc: ^Mask_Cache) {
	keep := make([dynamic]Mask_Entry)
	for &e in mc.items {
		if mc.stamp - e.used < MASK_CACHE_IDLE {
			append(&keep, e)
		} else {
			mc.bytes -= 2 * e.w * e.h
			delete(e.a)
			delete(e.halo)
			delete(e.text)
		}
	}
	delete(mc.items)
	mc.items = keep
	for _, &v in mc.index {
		delete(v)
	}
	clear(&mc.index)
	for e, i in mc.items {
		k := mask_key(e.text, e.size, e.weight, e.halo_w)
		if bucket, ok := &mc.index[k]; ok {
			append(bucket, i32(i))
		} else {
			b := make([dynamic]i32)
			append(&b, i32(i))
			mc.index[k] = b
		}
	}
}

// blit_rot resamples a column range of the mask into the canvas, rotated about
// a pivot.
//
// The pivot is a point in mask space — the chunk's pen origin on the baseline —
// that lands at (ox, oy) on the canvas; `angle` rotates clockwise about it.
// The pivot need not be inside [lo, hi]: a halo pass draws a few columns either
// side of the chunk and must still line up with the glyph pass.
//
// Sampling is bilinear, because a rotated bitmap taken nearest-neighbour
// crawls along the baseline as the angle changes by a degree.
blit_rot :: proc(
	c: ^p.Canvas,
	clip: p.Rect,
	m: []u8,
	mw, mh: int,
	lo, hi: int,
	sy0, sy1: int,
	pivot_x, pivot_y: f32,
	ox, oy: f32,
	angle: f32,
	col: p.Color,
) {
	cs, sn := math.cos(angle), math.sin(angle)
	minx, miny := f32(1e30), f32(1e30)
	maxx, maxy := f32(-1e30), f32(-1e30)
	for cx in ([?]f32{f32(lo) - 1, f32(hi) + 1}) {
		for cy in ([?]f32{f32(sy0) - 1, f32(sy1) + 1}) {
			dx := cx - pivot_x
			dy := cy - pivot_y
			px := ox + dx * cs - dy * sn
			py := oy + dx * sn + dy * cs
			minx = math.min(minx, px)
			maxx = math.max(maxx, px)
			miny = math.min(miny, py)
			maxy = math.max(maxy, py)
		}
	}
	bx0 := max(int(math.floor(minx)), int(clip.x), 0)
	by0 := max(int(math.floor(miny)), int(clip.y), 0)
	bx1 := min(int(math.ceil(maxx)) + 1, int(math.ceil(p.rect_right(clip))), c.w)
	by1 := min(int(math.ceil(maxy)) + 1, int(math.ceil(p.rect_bottom(clip))), c.h)
	if bx0 >= bx1 || by0 >= by1 {
		return
	}

	// The inverse transform is affine, so stepping one pixel to the right
	// steps the source position by a constant. Computing it incrementally
	// keeps two multiplies out of the inner loop of what is, at a hundred
	// labels a frame, the busiest loop in the program.
	cr := u32(col.r)
	cg := u32(col.g)
	cb := u32(col.b)
	ca := f32(col.a) / 255
	lo_f := f32(lo) - 0.5
	hi_f := f32(hi) + 0.5
	src_top := f32(max(sy0 - 1, 0))
	src_bot := f32(min(sy1, mh - 1))

	#no_bounds_check for y in by0 ..< by1 {
		dx0 := f32(bx0) + 0.5 - ox
		dy0 := f32(y) + 0.5 - oy
		sx := pivot_x + dx0 * cs + dy0 * sn
		sy := pivot_y - dx0 * sn + dy0 * cs
		row := c.px[y * c.w:][:c.w]
		for x in bx0 ..< bx1 {
			defer {
				sx += cs
				sy -= sn
			}
			if sx < lo_f || sx > hi_f || sy < src_top || sy > src_bot {
				continue
			}
			ix := int(sx)
			iy := int(sy)
			if ix < 0 || iy < 0 || ix >= mw - 1 || iy >= mh - 1 {
				continue
			}
			fx := sx - f32(ix)
			fy := sy - f32(iy)
			a00 := f32(m[iy * mw + ix])
			a10 := f32(m[iy * mw + ix + 1])
			a01 := f32(m[(iy + 1) * mw + ix])
			a11 := f32(m[(iy + 1) * mw + ix + 1])
			v := (a00 * (1 - fx) + a10 * fx) * (1 - fy) + (a01 * (1 - fx) + a11 * fx) * fy
			if v < 1 {
				continue
			}
			blend_px(row, x, cr, cg, cb, u32(v * ca + 0.5))
		}
	}
}

// blit_straight is the unrotated case: an integer-aligned copy, so a
// horizontal label is pixel-exact rather than resampled. Most labels on a map
// are horizontal, so this is also the fast path.
blit_straight :: proc(
	c: ^p.Canvas,
	clip: p.Rect,
	m: []u8,
	mw, mh: int,
	lo, hi: int,
	sy0, sy1: int,
	pivot_x, pivot_y: f32,
	ox, oy: f32,
	col: p.Color,
) {
	dx := int(math.round(ox - pivot_x))
	dy := int(math.round(oy - pivot_y))
	x0 := max(lo, int(clip.x) - dx, -dx)
	x1 := min(hi + 1, int(math.ceil(p.rect_right(clip))) - dx, c.w - dx, mw)
	y0 := max(sy0, int(clip.y) - dy, -dy)
	y1 := min(sy1, mh, int(math.ceil(p.rect_bottom(clip))) - dy, c.h - dy)
	cr := u32(col.r)
	cg := u32(col.g)
	cb := u32(col.b)
	ca := f32(col.a) / 255
	#no_bounds_check for y in y0 ..< y1 {
		src := m[y * mw:][:mw]
		dst := c.px[(y + dy) * c.w:][:c.w]
		for x in x0 ..< x1 {
			v := src[x]
			if v == 0 {
				continue
			}
			blend_px(dst, x + dx, cr, cg, cb, u32(f32(v) * ca + 0.5))
		}
	}
}

// ---------------------------------------------------------------------------
// Drawing the placed labels
// ---------------------------------------------------------------------------

labels_draw :: proc(l: ^Labeller, c: ^p.Canvas, clip: p.Rect, fonts: ^p.Fonts) {
	// Labels are drawn in an order grouped by their text, size and weight, so
	// a street split into eleven ways renders its mask once rather than eleven
	// times. Re-ordering is free here precisely because the contest guarantees
	// no two labels overlap: with nothing to composite over anything else,
	// paint order carries no meaning.
	clear(&l.order)
	for i in 0 ..< len(l.labels) {
		append(&l.order, i32(i))
	}
	sort_labels(l.labels[:], l.order[:])

	l.cache.stamp += 1
	for oi in l.order {
		lb := l.labels[oi]
		if lb.dot > 0 {
			p.fill_circle(c, lb.dot_x, lb.dot_y, lb.dot + 1.3, p.Color{255, 255, 255, 230})
			p.fill_circle(c, lb.dot_x, lb.dot_y, lb.dot, lb.col)
		}
		if lb.text == "" || lb.chunk_count == 0 {
			continue
		}
		tm := mask_get(l, fonts, lb.text, lb.size, lb.weight, lb.halo_width)
		// Halo first, over the whole label, then the glyphs. Per chunk would
		// print one character's halo over the glyph of the one before it.
		// Each chunk's pen origin inside the mask, measured once for the whole
		// label. Asking `text_width_upto` for it inside `draw_chunk` measures
		// every prefix of the label again for every character of it.
		pad := f32(MASK_PAD) + math.ceil(lb.halo_width) + 1
		clear(&l.pivots)
		for ci in lb.chunk_first ..< lb.chunk_first + lb.chunk_count {
			ch := l.chunks[ci]
			append(
				&l.pivots,
				[2]f32 {
					pad + p.text_width_upto(fonts, lb.text, int(ch.first), lb.size, .Sans, lb.weight),
					pad + p.text_width_upto(fonts, lb.text, int(ch.last), lb.size, .Sans, lb.weight),
				},
			)
		}
		if lb.halo.a > 0 && lb.halo_width > 0 {
			for ci in lb.chunk_first ..< lb.chunk_first + lb.chunk_count {
				draw_chunk(c, clip, tm, lb, l.chunks[ci], l.pivots[ci - lb.chunk_first], tm.halo, lb.halo)
			}
		}
		for ci in lb.chunk_first ..< lb.chunk_first + lb.chunk_count {
			draw_chunk(c, clip, tm, lb, l.chunks[ci], l.pivots[ci - lb.chunk_first], tm.a, lb.col)
		}
	}
}

@(private = "file")
draw_chunk :: proc(
	c: ^p.Canvas,
	clip: p.Rect,
	tm: ^Mask_Entry,
	lb: Label,
	ch: Chunk,
	span: [2]f32,
	m: []u8,
	col: p.Color,
) {
	// The chunk's pen origin inside the mask, and the column range to draw.
	// The range is grown by the halo width so the dilated edge comes with it.
	pivot := span[0]
	right := span[1]
	grow := math.ceil(lb.halo_width) + 1
	lo := max(0, int(math.floor(pivot - grow)))
	hi := min(tm.w - 2, int(math.ceil(right + grow)))
	if hi <= lo {
		return
	}
	if abs(ch.angle) < 0.0015 {
		blit_straight(
			c, clip, m, tm.w, tm.h, lo, hi, tm.ink_y0, tm.ink_y1,
			pivot, tm.baseline, ch.x, ch.y, col,
		)
		return
	}
	blit_rot(
		c, clip, m, tm.w, tm.h, lo, hi, tm.ink_y0, tm.ink_y1,
		pivot, tm.baseline, ch.x, ch.y, ch.angle, col,
	)
}
