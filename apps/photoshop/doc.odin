package main

// The document: a stack of RGBA layers and the composite they produce.
//
// Pixels are palmy's own format — straight (non-premultiplied) 0xAARRGGBB —
// everywhere, so a layer can be handed to `p.draw_image` or written out by
// `p.write_png_rgba` without a conversion pass.
//
// Two things make this fast enough to paint on with a software rasterizer:
//
//  1. The composite is *cached*. `doc.comp` holds the flattened document and is
//     only recomputed where something changed. A brush stamp dirties a 40x40
//     rectangle, so a stroke costs 1600 composite pixels per sample rather than
//     786432.
//  2. Layers live in a pool and the stack is a list of indices into it. That
//     makes reorder, delete and undo pure index work — no pixel buffer is ever
//     copied to move a layer — and it is what lets the history store a
//     structural change as a few dozen bytes.

import "core:math"
import "core:strings"

MAX_LAYERS :: 64
NAME_CAP :: 48

Blend :: enum u8 {
	Normal,
	Multiply,
	Screen,
	Overlay,
	Darken,
	Lighten,
	Soft_Light,
	Difference,
}

BLEND_NAMES := [Blend]string {
	.Normal     = "Normal",
	.Multiply   = "Multiply",
	.Screen     = "Screen",
	.Overlay    = "Overlay",
	.Darken     = "Darken",
	.Lighten    = "Lighten",
	.Soft_Light = "Soft Light",
	.Difference = "Difference",
}

// Rect_I is a half-open integer rectangle in document space. Empty when
// x1 <= x0; `rect_i_union` treats empty as the identity, which is what makes
// accumulating a dirty region a one-liner at every call site.
Rect_I :: struct {
	x0, y0, x1, y1: int,
}

Layer :: struct {
	name:     [NAME_CAP]u8,
	name_len: int,
	px:       []u32,
	visible:  bool,
	opacity:  f32,
	blend:    Blend,

	// Panel thumbnail, rebuilt lazily when the layer changes.
	thumb:     []u32,
	thumb_w:   int,
	thumb_h:   int,
	thumb_old: bool,
}

Doc :: struct {
	w, h:   int,
	pool:   [dynamic]Layer, // stable storage; an index is a layer's identity
	order:  [dynamic]int,   // bottom-to-top
	active: int,            // position in `order`

	comp:  []u32, // cached flattened document
	dirty: Rect_I,

	path:  string, // where Ctrl-S writes, "" until saved once
	saved: bool,
}

THUMB_MAX :: 40

// ---------------------------------------------------------------------------
// Rectangles
// ---------------------------------------------------------------------------

rect_i_empty :: proc "contextless" (r: Rect_I) -> bool {
	return r.x1 <= r.x0 || r.y1 <= r.y0
}

rect_i_union :: proc "contextless" (a, b: Rect_I) -> Rect_I {
	if rect_i_empty(a) {
		return b
	}
	if rect_i_empty(b) {
		return a
	}
	return {min(a.x0, b.x0), min(a.y0, b.y0), max(a.x1, b.x1), max(a.y1, b.y1)}
}

rect_i_clip :: proc "contextless" (r: Rect_I, w, h: int) -> Rect_I {
	out := Rect_I{max(r.x0, 0), max(r.y0, 0), min(r.x1, w), min(r.y1, h)}
	if out.x1 < out.x0 {out.x1 = out.x0}
	if out.y1 < out.y0 {out.y1 = out.y0}
	return out
}

rect_i_intersect :: proc "contextless" (a, b: Rect_I) -> Rect_I {
	out := Rect_I{max(a.x0, b.x0), max(a.y0, b.y0), min(a.x1, b.x1), min(a.y1, b.y1)}
	if out.x1 < out.x0 {out.x1 = out.x0}
	if out.y1 < out.y0 {out.y1 = out.y0}
	return out
}

rect_i_area :: proc "contextless" (r: Rect_I) -> int {
	if rect_i_empty(r) {
		return 0
	}
	return (r.x1 - r.x0) * (r.y1 - r.y0)
}

// ---------------------------------------------------------------------------
// Blending
//
// The channel functions are the W3C compositing-and-blending separable modes,
// taken on 0..1 and evaluated here in 8-bit fixed point: `b` and `s` are the
// backdrop and source channel bytes, and the result is a byte.
// ---------------------------------------------------------------------------

blend_channel :: #force_inline proc "contextless" (mode: Blend, b, s: u32) -> u32 {
	switch mode {
	case .Normal:
		return s
	case .Multiply:
		return (b * s + 127) / 255
	case .Screen:
		return 255 - ((255 - b) * (255 - s) + 127) / 255
	case .Overlay:
		// HardLight with the operands swapped.
		if b <= 127 {
			return (2 * b * s + 127) / 255
		}
		return 255 - (2 * (255 - b) * (255 - s) + 127) / 255
	case .Darken:
		return min(b, s)
	case .Lighten:
		return max(b, s)
	case .Soft_Light:
		// The PDF/W3C formula. The branch at s = 1/2 is the standard one; the
		// D(x) helper below 1/4 is what keeps dark backdrops from clipping.
		bf := f32(b) / 255
		sf := f32(s) / 255
		out: f32
		if sf <= 0.5 {
			out = bf - (1 - 2 * sf) * bf * (1 - bf)
		} else {
			d: f32
			if bf <= 0.25 {
				d = ((16 * bf - 12) * bf + 4) * bf
			} else {
				d = math.sqrt(bf)
			}
			out = bf + (2 * sf - 1) * (d - bf)
		}
		return u32(clamp(out * 255 + 0.5, 0, 255))
	case .Difference:
		return b > s ? b - s : s - b
	}
	return s
}

// blend_over composites one source pixel onto a backdrop pixel through `mode`,
// with the source alpha already scaled by the layer opacity (`alpha_mul` in
// 0..255). Both inputs and the result are straight-alpha 0xAARRGGBB.
//
// This is the general formula, not the opaque-backdrop shortcut: a document
// whose bottom layer has holes has to stay transparent through a Multiply
// layer, and only the (1 - ab) term gets that right.
blend_over :: proc "contextless" (dst, src: u32, mode: Blend, alpha_mul: u32) -> u32 {
	as_ := ((src >> 24) & 0xff) * alpha_mul / 255
	if as_ == 0 {
		return dst
	}
	ab := (dst >> 24) & 0xff

	if ab == 0 {
		// Nothing to blend against: the mode is the identity here, so this is
		// a plain alpha scale. (Also the fast path for the bottom layer.)
		return (as_ << 24) | (src & 0x00ff_ffff)
	}

	ao := as_ + ab - (as_ * ab + 127) / 255
	if ao == 0 {
		return 0
	}

	out: u32 = ao << 24
	for sh in ([3]u32{16, 8, 0}) {
		cb := (dst >> sh) & 0xff
		cs := (src >> sh) & 0xff
		bl := blend_channel(mode, cb, cs)
		// Premultiplied source-over of the blended colour:
		//   co = as*(1-ab)*Cs + as*ab*B + (1-as)*ab*Cb
		co := as_ * (255 - ab) * cs + as_ * ab * bl + (255 - as_) * ab * cb
		// co is scaled by 255*255; divide by ao to unpremultiply.
		v := (co / 255 + ao / 2) / ao
		out |= clamp(v, 0, 255) << sh
	}
	return out
}

// src_over is `blend_over` with mode Normal and no opacity, written out because
// every tool uses it per pixel.
src_over :: #force_inline proc "contextless" (dst, src: u32) -> u32 {
	as_ := (src >> 24) & 0xff
	if as_ == 255 {
		return src
	}
	if as_ == 0 {
		return dst
	}
	ab := (dst >> 24) & 0xff
	if ab == 0 {
		return src
	}
	ao := as_ + ab - (as_ * ab + 127) / 255
	out: u32 = ao << 24
	for sh in ([3]u32{16, 8, 0}) {
		cb := (dst >> sh) & 0xff
		cs := (src >> sh) & 0xff
		co := as_ * 255 * cs + (255 - as_) * ab * cb
		out |= clamp((co / 255 + ao / 2) / ao, 0, 255) << sh
	}
	return out
}

// ---------------------------------------------------------------------------
// Document lifetime
// ---------------------------------------------------------------------------

doc_init :: proc(d: ^Doc, w, h: int) {
	d.w, d.h = w, h
	d.pool = make([dynamic]Layer, 0, 8)
	d.order = make([dynamic]int, 0, 8)
	d.comp = make([]u32, w * h)
	d.active = 0
	d.dirty = {0, 0, w, h}
}

doc_free :: proc(d: ^Doc) {
	for &l in d.pool {
		delete(l.px)
		delete(l.thumb)
	}
	delete(d.pool)
	delete(d.order)
	delete(d.comp)
	free_str(d.path)
	d^ = {}
}

layer_set_name :: proc(l: ^Layer, s: string) {
	n := min(len(s), NAME_CAP)
	copy(l.name[:], s[:n])
	l.name_len = n
}

// layer_name borrows the name out of the pool. The pool is stable storage, so
// the slice stays valid; taking a `Layer` by value here would return a slice of
// a dead stack copy.
layer_name :: proc(l: ^Layer) -> string {
	return string(l.name[:l.name_len])
}

// doc_new_layer appends a layer to the pool and returns its pool index. It does
// not touch the stack — `doc_insert` does that, so a layer created for an undo
// entry can exist without being visible.
doc_new_layer :: proc(d: ^Doc, name: string, fill: u32 = 0) -> int {
	l := Layer {
		px        = make([]u32, d.w * d.h),
		visible   = true,
		opacity   = 1,
		blend     = .Normal,
		thumb_old = true,
	}
	layer_set_name(&l, name)
	if fill != 0 {
		for i in 0 ..< len(l.px) {
			l.px[i] = fill
		}
	}
	append(&d.pool, l)
	return len(d.pool) - 1
}

// doc_insert puts a pool index into the stack at `at` (0 = bottom).
doc_insert :: proc(d: ^Doc, pool_idx: int, at: int) {
	pos := clamp(at, 0, len(d.order))
	resize(&d.order, len(d.order) + 1)
	for i := len(d.order) - 1; i > pos; i -= 1 {
		d.order[i] = d.order[i - 1]
	}
	d.order[pos] = pool_idx
	d.active = pos
	doc_dirty_all(d)
}

doc_remove_at :: proc(d: ^Doc, pos: int) {
	if pos < 0 || pos >= len(d.order) {
		return
	}
	ordered_remove(&d.order, pos)
	d.active = clamp(d.active, 0, max(0, len(d.order) - 1))
	doc_dirty_all(d)
}

// active_layer returns a pointer into the pool. Valid only until the pool is
// appended to, which is why nothing holds one across a frame.
active_layer :: proc(d: ^Doc) -> ^Layer {
	if d.active < 0 || d.active >= len(d.order) {
		return nil
	}
	return &d.pool[d.order[d.active]]
}

active_pool :: proc(d: ^Doc) -> int {
	if d.active < 0 || d.active >= len(d.order) {
		return -1
	}
	return d.order[d.active]
}

doc_dirty :: proc(d: ^Doc, r: Rect_I) {
	d.dirty = rect_i_union(d.dirty, rect_i_clip(r, d.w, d.h))
}

doc_dirty_all :: proc(d: ^Doc) {
	d.dirty = {0, 0, d.w, d.h}
}

layer_touch :: proc(d: ^Doc, pool_idx: int, r: Rect_I) {
	if pool_idx >= 0 && pool_idx < len(d.pool) {
		d.pool[pool_idx].thumb_old = true
	}
	doc_dirty(d, r)
	d.saved = false
}

// ---------------------------------------------------------------------------
// Compositing
// ---------------------------------------------------------------------------

// doc_composite flattens the dirty region bottom-to-top into `comp` and clears
// the dirty flag. Returns the number of pixels it touched, which is what the
// status bar reports — the honest measure of whether dirtying is working.
doc_composite :: proc(d: ^Doc) -> int {
	r := rect_i_clip(d.dirty, d.w, d.h)
	d.dirty = {}
	if rect_i_empty(r) {
		return 0
	}

	// Clear the region first, then fold each visible layer over it.
	for y in r.y0 ..< r.y1 {
		row := d.comp[y * d.w:]
		for x in r.x0 ..< r.x1 {
			row[x] = 0
		}
	}

	for li in d.order {
		l := &d.pool[li]
		if !l.visible || l.opacity <= 0 {
			continue
		}
		am := u32(clamp(l.opacity * 255 + 0.5, 0, 255))
		mode := l.blend
		for y in r.y0 ..< r.y1 {
			srow := l.px[y * d.w:]
			drow := d.comp[y * d.w:]
			if mode == .Normal && am == 255 {
				for x in r.x0 ..< r.x1 {
					drow[x] = src_over(drow[x], srow[x])
				}
			} else {
				for x in r.x0 ..< r.x1 {
					drow[x] = blend_over(drow[x], srow[x], mode, am)
				}
			}
		}
	}
	return rect_i_area(r)
}

// ---------------------------------------------------------------------------
// Thumbnails
// ---------------------------------------------------------------------------

// layer_thumb rebuilds a layer's panel thumbnail if it is stale. A box filter,
// weighted by alpha so a transparent margin does not drag the edges to black.
layer_thumb :: proc(d: ^Doc, pool_idx: int) -> (px: []u32, w, h: int) {
	l := &d.pool[pool_idx]
	tw, th := THUMB_MAX, THUMB_MAX
	if d.w >= d.h {
		th = max(1, d.h * THUMB_MAX / d.w)
	} else {
		tw = max(1, d.w * THUMB_MAX / d.h)
	}
	if l.thumb == nil || l.thumb_w != tw || l.thumb_h != th {
		delete(l.thumb)
		l.thumb = make([]u32, tw * th)
		l.thumb_w, l.thumb_h = tw, th
		l.thumb_old = true
	}
	if !l.thumb_old {
		return l.thumb, tw, th
	}
	l.thumb_old = false

	for y in 0 ..< th {
		y0 := y * d.h / th
		y1 := max(y0 + 1, (y + 1) * d.h / th)
		for x in 0 ..< tw {
			x0 := x * d.w / tw
			x1 := max(x0 + 1, (x + 1) * d.w / tw)
			ar, ag, ab, aa, n: u32
			for sy in y0 ..< y1 {
				row := l.px[sy * d.w:]
				for sx in x0 ..< x1 {
					v := row[sx]
					a := (v >> 24) & 0xff
					ar += ((v >> 16) & 0xff) * a
					ag += ((v >> 8) & 0xff) * a
					ab += (v & 0xff) * a
					aa += a
					n += 1
				}
			}
			if n == 0 || aa == 0 {
				l.thumb[y * tw + x] = 0
				continue
			}
			l.thumb[y * tw + x] =
				((aa / n) << 24) | ((ar / aa) << 16) | ((ag / aa) << 8) | (ab / aa)
		}
	}
	return l.thumb, tw, th
}

// ---------------------------------------------------------------------------
// Export
// ---------------------------------------------------------------------------

// doc_rgba flattens the whole document into the byte order stb_image_write
// wants. Allocated in the caller's allocator.
doc_rgba :: proc(d: ^Doc, allocator := context.allocator) -> []u8 {
	doc_dirty_all(d)
	doc_composite(d)
	out := make([]u8, d.w * d.h * 4, allocator)
	for i in 0 ..< d.w * d.h {
		v := d.comp[i]
		out[i * 4 + 0] = u8((v >> 16) & 0xff)
		out[i * 4 + 1] = u8((v >> 8) & 0xff)
		out[i * 4 + 2] = u8(v & 0xff)
		out[i * 4 + 3] = u8((v >> 24) & 0xff)
	}
	return out
}

// ---------------------------------------------------------------------------
// Helpers the tools share
// ---------------------------------------------------------------------------

// copy_region lifts a rectangle out of a doc-sized buffer.
copy_region :: proc(src: []u32, w: int, r: Rect_I, allocator := context.allocator) -> []u32 {
	rw, rh := r.x1 - r.x0, r.y1 - r.y0
	if rw <= 0 || rh <= 0 {
		return nil
	}
	out := make([]u32, rw * rh, allocator)
	for y in 0 ..< rh {
		s := src[(r.y0 + y) * w + r.x0:][:rw]
		copy(out[y * rw:][:rw], s)
	}
	return out
}

// paste_region writes a rectangle back into a doc-sized buffer.
paste_region :: proc(dst: []u32, w: int, r: Rect_I, src: []u32) {
	rw, rh := r.x1 - r.x0, r.y1 - r.y0
	if rw <= 0 || rh <= 0 || len(src) < rw * rh {
		return
	}
	for y in 0 ..< rh {
		copy(dst[(r.y0 + y) * w + r.x0:][:rw], src[y * rw:][:rw])
	}
}

name_of_blend :: proc(b: Blend) -> string {
	return BLEND_NAMES[b]
}

// trim_name keeps the layers panel from stretching on a long name.
trim_name :: proc(s: string, n: int) -> string {
	if len(s) <= n {
		return s
	}
	return strings.concatenate({s[:n - 1], "..."}, context.temp_allocator)
}
