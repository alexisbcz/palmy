package main

// `photoshop --selftest` — the headless half of the app.
//
// Everything checked here is maths that a screenshot cannot verify. A blend
// mode either matches the W3C formula or it does not; a gaussian kernel either
// sums to one or it quietly darkens the image; undo either restores the exact
// bytes or it does not. Each is asserted against a value computed by hand or
// derived from a property, never against whatever the code happened to produce.

import "core:fmt"
import "core:math"
import "core:os"
import p "palmy:."

@(private = "file")
checks := 0
@(private = "file")
fails := 0

@(private = "file")
expect :: proc(cond: bool, format: string, args: ..any) {
	checks += 1
	if !cond {
		fails += 1
		fmt.eprintf("  FAIL  ")
		fmt.eprintfln(format, ..args)
	}
}

@(private = "file")
near :: proc(a, b: f32, tol: f32, format: string, args: ..any) {
	checks += 1
	if abs(a - b) > tol {
		fails += 1
		fmt.eprintf("  FAIL  ")
		fmt.eprintfln(format, ..args)
		fmt.eprintfln("        %v vs %v (tolerance %v)", a, b, tol)
	}
}

@(private = "file")
eq_u32 :: proc(a, b: u32, format: string, args: ..any) {
	checks += 1
	if a != b {
		fails += 1
		fmt.eprintf("  FAIL  ")
		fmt.eprintfln(format, ..args)
		fmt.eprintfln("        got 0x%08x want 0x%08x", a, b)
	}
}

@(private = "file")
close_u32 :: proc(a, b: u32, tol: u32, format: string, args: ..any) {
	checks += 1
	d := px_distance(a, b)
	if d > tol {
		fails += 1
		fmt.eprintf("  FAIL  ")
		fmt.eprintfln(format, ..args)
		fmt.eprintfln("        got 0x%08x want 0x%08x (max channel delta %d > %d)", a, b, d, tol)
	}
}

selftest :: proc() -> bool {
	fmt.println("photoshop selftest")
	test_rects()
	test_blend_channels()
	test_blend_alpha()
	test_composite()
	test_dirty()
	test_brush()
	test_flood_fill()
	test_move()
	test_adjustments()
	test_filters()
	test_history()
	test_color()
	test_png_roundtrip()
	test_sampling()

	fmt.printfln("%d assertions, %d failures", checks, fails)
	if fails == 0 {
		fmt.println("PASS")
	} else {
		fmt.println("FAIL")
	}
	return fails == 0
}

// ---------------------------------------------------------------------------

@(private = "file")
test_rects :: proc() {
	expect(rect_i_empty({0, 0, 0, 0}), "a zero rect is empty")
	expect(rect_i_empty({5, 5, 3, 9}), "an inverted rect is empty")
	expect(!rect_i_empty({0, 0, 1, 1}), "a single pixel is not empty")

	a := Rect_I{2, 3, 6, 9}
	expect(rect_i_area(a) == 4 * 6, "area is width x height")
	expect(rect_i_union(a, {}) == a, "union with empty is the identity")
	expect(rect_i_union({}, a) == a, "union with empty is the identity either way")
	expect(rect_i_union(a, {0, 0, 3, 4}) == Rect_I{0, 0, 6, 9}, "union is the bounding box")
	expect(rect_i_intersect(a, {4, 4, 20, 20}) == Rect_I{4, 4, 6, 9}, "intersection clips")
	expect(rect_i_empty(rect_i_intersect(a, {40, 40, 50, 50})), "disjoint intersection is empty")
	expect(rect_i_clip({-5, -5, 100, 100}, 10, 8) == Rect_I{0, 0, 10, 8}, "clip to the document")
}

// ---------------------------------------------------------------------------
// Blend modes, per channel, against hand-computed values.
// ---------------------------------------------------------------------------

@(private = "file")
test_blend_channels :: proc() {
	// Multiply: b*s/255. 128*64/255 = 32.125 -> 32.
	expect(blend_channel(.Multiply, 128, 64) == 32, "multiply 128x64 = 32")
	expect(blend_channel(.Multiply, 255, 170) == 170, "multiply by white is the identity")
	expect(blend_channel(.Multiply, 0, 200) == 0, "multiply by black is black")

	// Screen: 255 - (255-b)(255-s)/255. b=128,s=64: 255 - 127*191/255 = 255-95.1 = 160.
	expect(blend_channel(.Screen, 128, 64) == 160, "screen 128x64 = 160")
	expect(blend_channel(.Screen, 0, 90) == 90, "screen over black is the source")
	expect(blend_channel(.Screen, 255, 10) == 255, "screen over white is white")

	// Overlay is hard-light with operands swapped, pivoting on the backdrop.
	// b=64 (<=127): 2*64*200/255 = 100.4 -> 100.
	expect(blend_channel(.Overlay, 64, 200) == 100, "overlay on a dark backdrop multiplies")
	// b=200 (>127): 255 - 2*55*55/255 = 255 - 23.7 = 231.
	expect(blend_channel(.Overlay, 200, 200) == 231, "overlay on a light backdrop screens")
	expect(blend_channel(.Overlay, 0, 128) == 0, "overlay keeps black black")
	expect(blend_channel(.Overlay, 255, 128) == 255, "overlay keeps white white")

	expect(blend_channel(.Darken, 90, 200) == 90, "darken takes the minimum")
	expect(blend_channel(.Darken, 200, 90) == 90, "darken is symmetric")
	expect(blend_channel(.Lighten, 90, 200) == 200, "lighten takes the maximum")
	expect(blend_channel(.Lighten, 200, 90) == 200, "lighten is symmetric")

	expect(blend_channel(.Difference, 200, 90) == 110, "difference is the absolute delta")
	expect(blend_channel(.Difference, 90, 200) == 110, "difference is symmetric")
	expect(blend_channel(.Difference, 77, 77) == 0, "difference with itself is black")

	expect(blend_channel(.Normal, 12, 200) == 200, "normal is the source")

	// Soft light at s = 1/2 is the identity on the backdrop.
	near(
		f32(blend_channel(.Soft_Light, 160, 128)),
		160,
		1.5,
		"soft light at 50%% leaves the backdrop",
	)
	expect(blend_channel(.Soft_Light, 0, 255) == 0, "soft light keeps black black")
	expect(blend_channel(.Soft_Light, 255, 0) == 255, "soft light keeps white white")
	expect(
		blend_channel(.Soft_Light, 128, 255) > 128,
		"soft light with a white source lightens",
	)
	expect(
		blend_channel(.Soft_Light, 128, 0) < 128,
		"soft light with a black source darkens",
	)

	// Every mode must be monotone in the source on a mid backdrop, which is the
	// property that makes a slider feel like a slider.
	for mode in Blend {
		if mode == .Difference {
			continue // |b-s| is V-shaped by definition
		}
		prev := blend_channel(mode, 128, 0)
		ok := true
		for s in u32(1) ..= 255 {
			v := blend_channel(mode, 128, s)
			if v + 1 < prev {
				ok = false
				break
			}
			prev = v
		}
		expect(ok, "%v is monotone in the source", mode)
	}
}

// ---------------------------------------------------------------------------
// Alpha compositing
// ---------------------------------------------------------------------------

@(private = "file")
test_blend_alpha :: proc() {
	black := u32(0xff00_0000)
	white := u32(0xffff_ffff)

	eq_u32(blend_over(black, white, .Normal, 255), white, "opaque white over black is white")
	eq_u32(blend_over(white, 0, .Normal, 255), white, "a transparent source changes nothing")
	eq_u32(blend_over(0, white, .Normal, 255), white, "white onto nothing is white")

	// 50% white over black: co = 0.5, Co = 0.5 -> 128.
	half_white := u32(0x80ff_ffff)
	close_u32(
		blend_over(black, half_white, .Normal, 255),
		0xff80_8080,
		2,
		"50%% white over black is mid grey",
	)

	// Layer opacity multiplies the source alpha, so 50% opacity on an opaque
	// white layer has to match a 50%-alpha white source.
	close_u32(
		blend_over(black, white, .Normal, 128),
		blend_over(black, half_white, .Normal, 255),
		2,
		"layer opacity equals source alpha",
	)

	// Over a transparent backdrop the blend mode cannot apply, so the result is
	// the source with its alpha scaled.
	eq_u32(blend_over(0, white, .Multiply, 128), 0x80ff_ffff, "multiply onto nothing scales alpha")

	// Alpha accumulation: 50% over 50% leaves 75%.
	out := blend_over(0x8000_0000, 0x80ff_ffff, .Normal, 255)
	near(f32((out >> 24) & 0xff), 191, 2, "50%% over 50%% gives 75%% alpha")

	// src_over must agree with blend_over(.Normal, 255) everywhere it is used.
	for a in u32(0) ..= 255 {
		s := (a << 24) | 0x0033_7788
		d := u32(0x9912_3456)
		close_u32(src_over(d, s), blend_over(d, s, .Normal, 255), 2, "src_over matches blend_over at alpha %d", a)
	}
}

// ---------------------------------------------------------------------------
// Compositing a stack
// ---------------------------------------------------------------------------

@(private = "file")
make_doc :: proc(w, h: int) -> Doc {
	d: Doc
	doc_init(&d, w, h)
	return d
}

@(private = "file")
fill_layer :: proc(d: ^Doc, pool: int, v: u32) {
	for i in 0 ..< d.w * d.h {
		d.pool[pool].px[i] = v
	}
	d.pool[pool].thumb_old = true
}

@(private = "file")
test_composite :: proc() {
	d := make_doc(4, 4)
	defer doc_free(&d)

	bottom := doc_new_layer(&d, "bottom")
	fill_layer(&d, bottom, 0xff80_8080)
	doc_insert(&d, bottom, 0)

	top := doc_new_layer(&d, "top")
	fill_layer(&d, top, 0xff40_4040)
	doc_insert(&d, top, 1)
	d.pool[top].blend = .Multiply
	doc_dirty_all(&d)
	doc_composite(&d)

	// 0x80 * 0x40 / 255 = 128*64/255 = 32 = 0x20.
	eq_u32(d.comp[0], 0xff20_2020, "multiply composites bottom-to-top")

	// Hiding the top layer leaves the bottom one.
	d.pool[top].visible = false
	doc_dirty_all(&d)
	doc_composite(&d)
	eq_u32(d.comp[0], 0xff80_8080, "a hidden layer contributes nothing")

	// Screen instead, at half opacity: blend is 255-(127*191)/255 = 160, and at
	// 50% opacity over an opaque backdrop the result is halfway to it.
	d.pool[top].visible = true
	d.pool[top].blend = .Screen
	d.pool[top].opacity = 0.5
	doc_dirty_all(&d)
	doc_composite(&d)
	near(f32((d.comp[0] >> 16) & 0xff), (128 + 160) / 2, 2, "half-opacity screen is halfway")

	// Order matters: swapping the stack with Darken on top must give min().
	d.pool[top].blend = .Darken
	d.pool[top].opacity = 1
	doc_dirty_all(&d)
	doc_composite(&d)
	eq_u32(d.comp[0], 0xff40_4040, "darken over a lighter backdrop takes the top")

	d.order[0], d.order[1] = d.order[1], d.order[0]
	// Now `bottom` (0x80, Normal) is on top of `top` (0x40, Darken over nothing).
	doc_dirty_all(&d)
	doc_composite(&d)
	eq_u32(d.comp[0], 0xff80_8080, "reordering changes the composite")

	// A transparent document stays transparent.
	d2 := make_doc(2, 2)
	defer doc_free(&d2)
	only := doc_new_layer(&d2, "empty")
	doc_insert(&d2, only, 0)
	doc_composite(&d2)
	eq_u32(d2.comp[0], 0, "an empty layer composites to nothing")

	// A Multiply layer over a hole must stay a hole, which is the case the
	// opaque-backdrop shortcut gets wrong.
	hole := doc_new_layer(&d2, "mul")
	fill_layer(&d2, hole, 0xff00_8000)
	d2.pool[hole].blend = .Multiply
	doc_insert(&d2, hole, 1)
	doc_composite(&d2)
	expect((d2.comp[0] >> 24) & 0xff == 255, "a multiply layer still contributes its own alpha")
	eq_u32(d2.comp[0] & 0x00ff_ffff, 0x0000_8000, "multiply over a hole is the source colour")
}

// ---------------------------------------------------------------------------
// Dirty rectangles
// ---------------------------------------------------------------------------

@(private = "file")
test_dirty :: proc() {
	d := make_doc(64, 64)
	defer doc_free(&d)
	l := doc_new_layer(&d, "a")
	fill_layer(&d, l, 0xffff_0000)
	doc_insert(&d, l, 0)

	expect(doc_composite(&d) == 64 * 64, "a fresh document composites in full")
	expect(doc_composite(&d) == 0, "a clean document composites nothing")

	// Change one pixel and dirty only its rectangle: the composite must cost
	// 100 pixels, not 4096.
	d.pool[l].px[10 * 64 + 10] = 0xff00_ff00
	doc_dirty(&d, {5, 5, 15, 15})
	expect(doc_composite(&d) == 100, "a 10x10 dirty region costs 100 pixels")
	eq_u32(d.comp[10 * 64 + 10], 0xff00_ff00, "the dirty region was actually recomposited")

	// A change outside the dirtied region must be absent from the cache, which
	// is the proof that the cache is really being reused rather than rebuilt.
	d.pool[l].px[40 * 64 + 40] = 0xff00_00ff
	doc_dirty(&d, {5, 5, 15, 15})
	doc_composite(&d)
	eq_u32(d.comp[40 * 64 + 40], 0xffff_0000, "a change outside the dirty region is not picked up")

	doc_dirty_all(&d)
	doc_composite(&d)
	eq_u32(d.comp[40 * 64 + 40], 0xff00_00ff, "a full dirty picks it up")

	// Dirtying accumulates as a bounding box.
	d.dirty = {}
	doc_dirty(&d, {1, 1, 3, 3})
	doc_dirty(&d, {20, 20, 22, 22})
	expect(d.dirty == Rect_I{1, 1, 22, 22}, "dirty regions accumulate into their bounding box")
}

// ---------------------------------------------------------------------------
// Brush
// ---------------------------------------------------------------------------

@(private = "file")
test_brush :: proc() {
	// Coverage profile.
	near(brush_coverage(0, 10, 1), 1, 0.001, "the brush centre is fully covered")
	near(brush_coverage(10, 10, 1), 0, 0.001, "the brush edge is uncovered")
	near(brush_coverage(20, 10, 0.5), 0, 0.001, "outside the radius is uncovered")
	expect(
		brush_coverage(5, 10, 0) > 0 && brush_coverage(5, 10, 0) < 1,
		"a soft brush is partial halfway out",
	)
	expect(
		brush_coverage(5, 10, 1) == 1,
		"a hard brush is still solid halfway out",
	)
	// Monotone decreasing.
	ok := true
	prev := f32(1.1)
	for i in 0 ..= 40 {
		v := brush_coverage(f32(i) * 0.5, 10, 0.4)
		if v > prev + 0.0001 {
			ok = false
		}
		prev = v
	}
	expect(ok, "brush coverage falls monotonically with distance")

	// A hardness-1 brush must still have an antialiased edge, or a circle is a
	// staircase. The pixel one unit inside the radius is partial.
	expect(
		brush_coverage(9.5, 10, 1) > 0 && brush_coverage(9.5, 10, 1) < 1,
		"a hard brush keeps one pixel of antialiasing",
	)

	// Stroke interpolation: two samples 60 px apart with a 10 px brush must
	// paint the whole line, not two dots.
	d := make_doc(128, 32)
	defer doc_free(&d)
	l := doc_new_layer(&d, "paint")
	doc_insert(&d, l, 0)
	s: Stroke
	defer stroke_free(&s)
	br := Brush {
		size     = 10,
		hardness = 1,
		opacity  = 1,
	}
	stroke_begin(&s, &d, false)
	stroke_to(&s, &d, br, {20, 16}, 0xffff_ffff, {0, 0, 128, 32})
	stroke_to(&s, &d, br, {100, 16}, 0xffff_ffff, {0, 0, 128, 32})
	gap := 0
	for x in 20 ..= 100 {
		if (d.pool[l].px[16 * 128 + x] >> 24) & 0xff < 250 {
			gap += 1
		}
	}
	expect(gap == 0, "a fast drag leaves no gaps (%d uncovered pixels)", gap)
	expect(s.stamps > 20, "the segment was interpolated into many stamps (%d)", s.stamps)
	expect(
		(d.pool[l].px[16 * 128 + 10] >> 24) & 0xff == 0,
		"the stroke does not paint before its start",
	)

	// No over-darkening: a 50%-opacity stroke over white must land exactly on
	// the 50% blend at every point along it, however many stamps overlapped.
	l2 := doc_new_layer(&d, "op")
	fill_layer(&d, l2, 0xffff_ffff)
	doc_insert(&d, l2, 1)
	d.active = 1
	br2 := Brush {
		size     = 20,
		hardness = 1,
		opacity  = 0.5,
	}
	stroke_begin(&s, &d, false)
	for x in 0 ..= 40 {
		stroke_to(&s, &d, br2, {20 + f32(x), 16}, 0xff00_0000, {0, 0, 128, 32})
	}
	mid := d.pool[l2].px[16 * 128 + 40]
	near(f32((mid >> 16) & 0xff), 128, 3, "a 50%% stroke deposits its opacity exactly once")

	// The eraser is destination-out: it removes alpha rather than painting.
	stroke_begin(&s, &d, true)
	stroke_to(&s, &d, br, {64, 16}, 0, {0, 0, 128, 32})
	expect((d.pool[l2].px[16 * 128 + 64] >> 24) & 0xff == 0, "the eraser clears alpha")

	// A stroke confined to a selection must not write outside it.
	l3 := doc_new_layer(&d, "clip")
	doc_insert(&d, l3, 2)
	d.active = 2
	stroke_begin(&s, &d, false)
	stroke_to(&s, &d, Brush{size = 40, hardness = 1, opacity = 1}, {64, 16}, 0xffff_ffff, {60, 10, 70, 20})
	expect((d.pool[l3].px[16 * 128 + 50] >> 24) & 0xff == 0, "the stroke respects the selection")
	expect((d.pool[l3].px[16 * 128 + 64] >> 24) & 0xff > 250, "the stroke paints inside the selection")
}

// ---------------------------------------------------------------------------
// Flood fill
// ---------------------------------------------------------------------------

@(private = "file")
test_flood_fill :: proc() {
	W, H := 16, 16
	px := make([]u32, W * H)
	defer delete(px)
	stack := make([dynamic][2]int)
	defer delete(stack)

	// A white field with a black 4x4 square at (6,6).
	for i in 0 ..< W * H {
		px[i] = 0xffff_ffff
	}
	for y in 6 ..< 10 {
		for x in 6 ..< 10 {
			px[y * W + x] = 0xff00_0000
		}
	}

	r := flood_fill(px, W, H, 0, 0, 0xffff_0000, 0, {}, &stack)
	expect(r == Rect_I{0, 0, 16, 16}, "the fill reaches the whole surrounding field")
	eq_u32(px[0], 0xffff_0000, "the seed pixel was filled")
	eq_u32(px[7 * W + 7], 0xff00_0000, "the black square was not crossed")
	eq_u32(px[5 * W + 7], 0xffff_0000, "the field above the square was filled")

	// Filling the square itself only touches the square.
	r2 := flood_fill(px, W, H, 7, 7, 0xff00_ff00, 0, {}, &stack)
	expect(r2 == Rect_I{6, 6, 10, 10}, "a bounded fill reports a bounded rectangle, got %v", r2)
	eq_u32(px[6 * W + 6], 0xff00_ff00, "the square was filled")
	eq_u32(px[0], 0xffff_0000, "the field outside was untouched")

	// Tolerance: a near-match is crossed when the tolerance allows it.
	for i in 0 ..< W * H {
		px[i] = 0xff80_8080
	}
	for y in 0 ..< H {
		px[y * W + 8] = 0xff8a_8a8a // a 10-level wall
	}
	count_filled :: proc(px: []u32, v: u32) -> int {
		n := 0
		for q in px {
			if q == v {
				n += 1
			}
		}
		return n
	}
	flood_fill(px, W, H, 0, 0, 0xffff_0000, 4, {}, &stack)
	expect(count_filled(px, 0xffff_0000) == 8 * H, "tolerance 4 stops at a 10-level wall")

	for i in 0 ..< W * H {
		px[i] = 0xff80_8080
	}
	for y in 0 ..< H {
		px[y * W + 8] = 0xff8a_8a8a
	}
	flood_fill(px, W, H, 0, 0, 0xffff_0000, 16, {}, &stack)
	expect(count_filled(px, 0xffff_0000) == W * H, "tolerance 16 crosses a 10-level wall")

	// Alpha counts: a transparent region is not the same colour as an opaque
	// one with the same RGB.
	for i in 0 ..< W * H {
		px[i] = 0x0080_8080
	}
	px[0] = 0xff80_8080
	r3 := flood_fill(px, W, H, 0, 0, 0xffff_0000, 0, {}, &stack)
	expect(rect_i_area(r3) == 1, "alpha is part of the tolerance metric")

	// A clip rectangle bounds the fill.
	for i in 0 ..< W * H {
		px[i] = 0xffff_ffff
	}
	r4 := flood_fill(px, W, H, 5, 5, 0xff00_00ff, 0, {4, 4, 8, 8}, &stack)
	expect(r4 == Rect_I{4, 4, 8, 8}, "the fill is confined to the selection, got %v", r4)

	// A seed outside the clip does nothing.
	r5 := flood_fill(px, W, H, 1, 1, 0xff00_ff00, 0, {4, 4, 8, 8}, &stack)
	expect(rect_i_empty(r5), "a seed outside the selection fills nothing")

	// A fill colour that is itself within tolerance of the target must still
	// terminate, and must fill each pixel exactly once. Without a visited map
	// the span algorithm loops here forever, and at tolerance 255 it loops for
	// every fill there is.
	for i in 0 ..< W * H {
		px[i] = 0xff80_8080
	}
	r6 := flood_fill(px, W, H, 0, 0, 0xff90_9090, 32, {}, &stack)
	expect(r6 == Rect_I{0, 0, 16, 16}, "a fill inside its own tolerance terminates")
	eq_u32(px[W * H - 1], 0xff90_9090, "and covers the region")

	for i in 0 ..< W * H {
		px[i] = 0xff80_8080
	}
	r7 := flood_fill(px, W, H, 8, 8, 0xff00_0000, 255, {}, &stack)
	expect(r7 == Rect_I{0, 0, 16, 16}, "tolerance 255 fills everything and stops")

	// Filling with the colour that is already there is a no-op.
	r8 := flood_fill(px, W, H, 8, 8, 0xff00_0000, 64, {}, &stack)
	expect(rect_i_empty(r8), "filling with the colour already there does nothing")

	// px_distance is the max norm over all four channels.
	expect(px_distance(0xff00_0000, 0xff00_0010) == 16, "px_distance is the max channel delta")
	expect(px_distance(0x0000_0000, 0xff00_0000) == 255, "px_distance sees alpha")
	expect(px_distance(0x1234_5678, 0x1234_5678) == 0, "px_distance of equals is zero")
}

// ---------------------------------------------------------------------------
// Move
// ---------------------------------------------------------------------------

@(private = "file")
test_move :: proc() {
	W, H := 8, 8
	base := make([]u32, W * H)
	dst := make([]u32, W * H)
	defer delete(base)
	defer delete(dst)
	base[2 * W + 2] = 0xffff_0000

	translate_layer(dst, base, W, H, 3, 1)
	eq_u32(dst[3 * W + 5], 0xffff_0000, "translate moves the pixel")
	eq_u32(dst[2 * W + 2], 0, "translate vacates the old position")

	// Off the edge and the pixel is gone, not wrapped.
	translate_layer(dst, base, W, H, 20, 0)
	for v in dst {
		expect(v == 0, "translating off the edge drops the pixel")
		break
	}

	// A selection move lifts only the selection.
	for i in 0 ..< W * H {
		base[i] = 0xff00_ff00
	}
	base[1 * W + 1] = 0xffff_0000
	translate_region(dst, base, W, H, {0, 0, 4, 4}, 4, 4)
	eq_u32(dst[5 * W + 5], 0xffff_0000, "the selected pixel landed at the offset")
	eq_u32(dst[1 * W + 1], 0, "the selection's old area was cleared")
	eq_u32(dst[7 * W + 7], 0xff00_ff00, "pixels outside the selection are untouched")

	b := moved_bounds({0, 0, 4, 4}, W, H, 4, 4)
	expect(b == Rect_I{0, 0, 8, 8}, "moved bounds cover source and destination, got %v", b)
}

// ---------------------------------------------------------------------------
// Adjustments
// ---------------------------------------------------------------------------

@(private = "file")
test_adjustments :: proc() {
	// Brightness/contrast identity.
	id := brightness_contrast_lut(0, 0)
	exact := true
	for i in 0 ..< 256 {
		if int(id[i]) != i {
			exact = false
		}
	}
	expect(exact, "brightness 0 / contrast 0 is the identity")

	up := brightness_contrast_lut(50, 0)
	expect(int(up[0]) == 128 || int(up[0]) == 127, "brightness +50 lifts black to mid (%d)", up[0])
	expect(up[255] == 255, "brightness cannot exceed white")

	cn := brightness_contrast_lut(0, 50)
	expect(cn[0] == 0 && cn[255] == 255, "contrast clamps at the ends")
	expect(cn[64] < 64, "contrast pushes the shadows down")
	expect(cn[192] > 192, "contrast pushes the highlights up")
	near(f32(cn[128]), 128, 1.5, "contrast pivots on mid grey")

	flat := brightness_contrast_lut(0, -100)
	for i in 0 ..< 256 {
		near(f32(flat[i]), 128, 1.5, "contrast -100 flattens everything to grey")
		break
	}

	// Levels identity.
	lid := levels_lut(0, 255, 1, 0, 255)
	exact2 := true
	for i in 0 ..< 256 {
		if abs(int(lid[i]) - i) > 1 {
			exact2 = false
		}
	}
	expect(exact2, "default levels are the identity")

	lv := levels_lut(64, 192, 1, 0, 255)
	expect(lv[64] == 0, "the input black point maps to 0")
	expect(lv[192] == 255, "the input white point maps to 255")
	expect(lv[32] == 0, "below the black point clips")
	expect(lv[220] == 255, "above the white point clips")
	near(f32(lv[128]), 127.5, 2, "the midpoint maps to the middle")

	g := levels_lut(0, 255, 2, 0, 255)
	expect(g[128] > 128, "gamma above 1 lightens the midtones")
	g2 := levels_lut(0, 255, 0.5, 0, 255)
	expect(g2[128] < 128, "gamma below 1 darkens the midtones")

	ob := levels_lut(0, 255, 1, 32, 224)
	expect(ob[0] == 32, "output black is honoured")
	expect(ob[255] == 224, "output white is honoured")

	// Monotonicity of every LUT.
	for lut in ([4][256]u8{id, cn, lv, g}) {
		mono := true
		for i in 1 ..< 256 {
			if lut[i] < lut[i - 1] {
				mono = false
			}
		}
		expect(mono, "a levels/contrast LUT is monotone")
	}

	// Invert and desaturate.
	px := []u32{0xff12_3456, 0x8000_0000}
	out := make([]u32, 2)
	defer delete(out)
	invert_region(out, px, 2, {0, 0, 2, 1})
	eq_u32(out[0], 0xffed_cba9, "invert complements RGB and keeps alpha")
	eq_u32(out[1], 0x80ff_ffff, "invert leaves alpha alone")

	desaturate_region(out, px, 2, {0, 0, 2, 1})
	r, g2b, b, _ := unpack_argb(out[0])
	expect(r == g2b && g2b == b, "desaturate produces a neutral")
	want := luma8(0x12, 0x34, 0x56) * 255
	near(f32(r), want, 1, "desaturate uses Rec. 709 luma")
	expect((out[0] >> 24) & 0xff == 255, "desaturate keeps alpha")

	// Hue/saturation.
	red := []u32{0xffff_0000}
	ho := make([]u32, 1)
	defer delete(ho)
	apply_hue_sat(ho, red, 1, {0, 0, 1, 1}, 120, 0, 0)
	close_u32(ho[0], 0xff00_ff00, 2, "a 120 degree hue shift turns red into green")
	apply_hue_sat(ho, red, 1, {0, 0, 1, 1}, 0, -100, 0)
	rr, gg, bb, _ := unpack_argb(ho[0])
	expect(rr == gg && gg == bb, "saturation -100 is a neutral")
	apply_hue_sat(ho, red, 1, {0, 0, 1, 1}, 0, 0, 0)
	close_u32(ho[0], 0xffff_0000, 2, "zero hue/sat/lightness is the identity")
	apply_hue_sat(ho, red, 1, {0, 0, 1, 1}, 0, 0, 100)
	eq_u32(ho[0], 0xffff_ffff, "lightness +100 is white")
	apply_hue_sat(ho, red, 1, {0, 0, 1, 1}, 0, 0, -100)
	eq_u32(ho[0], 0xff00_0000, "lightness -100 is black")

	// A hue shift of 360 is the identity.
	apply_hue_sat(ho, []u32{0xff3b_82f6}, 1, {0, 0, 1, 1}, 360, 0, 0)
	close_u32(ho[0], 0xff3b_82f6, 2, "a 360 degree hue shift is the identity")

	// Histogram.
	field := make([]u32, 16)
	defer delete(field)
	for i in 0 ..< 16 {
		field[i] = 0xffff_ffff
	}
	field[0] = 0
	bins, peak := histogram(field, 16, {0, 0, 16, 1})
	expect(bins[255] == 15, "the histogram counts the opaque pixels")
	expect(peak == 15, "the histogram peak is the tallest bin")
	expect(bins[0] == 0, "fully transparent pixels are not counted")
}

// ---------------------------------------------------------------------------
// Filters
// ---------------------------------------------------------------------------

@(private = "file")
test_filters :: proc() {
	// The gaussian kernel.
	for radius in ([5]f32{0.5, 1, 4, 12.5, 40}) {
		w, k := gaussian_kernel(radius)
		defer delete(w)
		total: f32 = 0
		for v in w {
			total += v
		}
		near(total, 1, 0.0001, "the kernel for radius %v is normalised", radius)
		expect(len(w) == 2 * k + 1, "the kernel has an odd length")
		sym := true
		for i in 0 ..< len(w) {
			if abs(w[i] - w[len(w) - 1 - i]) > 1e-6 {
				sym = false
			}
		}
		expect(sym, "the kernel for radius %v is symmetric", radius)
		centre := true
		for i in 0 ..< k {
			if w[i] > w[i + 1] + 1e-7 {
				centre = false
			}
		}
		expect(centre, "the kernel for radius %v peaks at the centre", radius)
		expect(w[k] == slice_max(w), "the centre tap is the largest")
	}

	// Blurring a constant field must not change it: that is what normalisation
	// buys, and the usual symptom of getting it wrong is a darkening edge.
	W, H := 32, 32
	src := make([]u32, W * H)
	dst := make([]u32, W * H)
	defer delete(src)
	defer delete(dst)
	for i in 0 ..< W * H {
		src[i] = 0xff80_4020
	}
	filter_blur(dst, src, W, H, {0, 0, W, H}, 6)
	worst := u32(0)
	for i in 0 ..< W * H {
		if d := px_distance(dst[i], 0xff80_4020); d > worst {
			worst = d
		}
	}
	expect(worst <= 1, "blurring a constant field is the identity (worst delta %d)", worst)

	// An impulse blurs into a symmetric kernel whose total mass is preserved.
	for i in 0 ..< W * H {
		src[i] = 0
	}
	src[16 * W + 16] = 0xffff_ffff
	filter_blur(dst, src, W, H, {0, 0, W, H}, 4)
	near(
		f32((dst[16 * W + 15] >> 24) & 0xff),
		f32((dst[16 * W + 17] >> 24) & 0xff),
		1,
		"a blurred impulse is symmetric horizontally",
	)
	near(
		f32((dst[15 * W + 16] >> 24) & 0xff),
		f32((dst[17 * W + 16] >> 24) & 0xff),
		1,
		"a blurred impulse is symmetric vertically",
	)
	near(
		f32((dst[16 * W + 15] >> 24) & 0xff),
		f32((dst[15 * W + 16] >> 24) & 0xff),
		1,
		"a blurred impulse is isotropic",
	)
	expect(
		(dst[16 * W + 16] >> 24) & 0xff < 255,
		"a blurred impulse spreads out",
	)
	// Premultiplied blur: the impulse stays white rather than fading to grey,
	// which is the halo bug a straight-alpha blur has.
	close_u32(dst[16 * W + 14] | 0xff00_0000, 0xffff_ffff, 2, "a blurred white impulse stays white")

	// Blur conserves total alpha. Checked on the f32 planes rather than on the
	// 8-bit result: a normalised kernel preserves the mass exactly, but a tail
	// value of 0.4/255 quantises to zero, so the quantised sum is always a few
	// percent light. Asserting the exact property on the exact numbers, and the
	// weaker property on the bytes, says which is which.
	{
		pm := pm_from(src, W, H, context.temp_allocator)
		pm_blur(&pm, 4)
		mass: f32 = 0
		for v in pm.a {
			mass += v
		}
		near(mass, 1, 0.0005, "a normalised gaussian conserves mass exactly")
	}
	total_out := 0
	for i in 0 ..< W * H {
		total_out += int((dst[i] >> 24) & 0xff)
	}
	expect(
		total_out > 230 && total_out <= 255,
		"the quantised blur keeps nearly all of the mass (%d of 255)",
		total_out,
	)

	// Sharpen with amount 0 is the identity.
	for i in 0 ..< W * H {
		src[i] = 0xff40_6080
	}
	src[16 * W + 16] = 0xffff_ffff
	filter_sharpen(dst, src, W, H, {0, 0, W, H}, 2, 0)
	same := true
	for i in 0 ..< W * H {
		if px_distance(dst[i], src[i]) > 1 {
			same = false
		}
	}
	expect(same, "unsharp mask with amount 0 is the identity")

	filter_sharpen(dst, src, W, H, {0, 0, W, H}, 2, 150)
	expect(
		(dst[16 * W + 14] & 0xff) <= (src[16 * W + 14] & 0xff),
		"unsharp mask darkens the ring around a bright point",
	)

	// Sobel: a vertical edge produces a response, a flat field does not.
	for y in 0 ..< H {
		for x in 0 ..< W {
			src[y * W + x] = x < 16 ? 0xff00_0000 : 0xffff_ffff
		}
	}
	filter_edges(dst, src, W, H, {0, 0, W, H}, 100)
	expect((dst[16 * W + 16] & 0xff) > 128, "sobel responds at an edge")
	expect((dst[16 * W + 4] & 0xff) < 8, "sobel is quiet on a flat field")
	near(
		f32(dst[8 * W + 16] & 0xff),
		f32(dst[24 * W + 16] & 0xff),
		1,
		"sobel's response along a straight edge is constant",
	)

	// Emboss: flat is mid grey, and the two directions are mirror images.
	for i in 0 ..< W * H {
		src[i] = 0xff70_7070
	}
	filter_emboss(dst, src, W, H, {0, 0, W, H}, 100, 135)
	near(f32(dst[16 * W + 16] & 0xff), 128, 1, "emboss maps a flat field to mid grey")
	for y in 0 ..< H {
		for x in 0 ..< W {
			src[y * W + x] = x < 16 ? 0xff00_0000 : 0xffff_ffff
		}
	}
	filter_emboss(dst, src, W, H, {0, 0, W, H}, 100, 0)
	a := f32(dst[16 * W + 16] & 0xff)
	filter_emboss(dst, src, W, H, {0, 0, W, H}, 100, 180)
	b := f32(dst[16 * W + 16] & 0xff)
	near(a + b, 256, 3, "opposite emboss angles are mirror images about mid grey")
}

@(private = "file")
slice_max :: proc(xs: []f32) -> f32 {
	m := xs[0]
	for v in xs {
		if v > m {
			m = v
		}
	}
	return m
}

// ---------------------------------------------------------------------------
// History
// ---------------------------------------------------------------------------

@(private = "file")
test_history :: proc() {
	d := make_doc(16, 16)
	defer doc_free(&d)
	h: History
	hist_init(&h)
	defer hist_free(&h)

	a := doc_new_layer(&d, "a")
	fill_layer(&d, a, 0xffff_0000)
	doc_insert(&d, a, 0)

	expect(!hist_can_undo(&h), "a fresh history has nothing to undo")
	expect(!hist_can_redo(&h), "a fresh history has nothing to redo")

	// Pixel edit round trip.
	r := Rect_I{2, 2, 6, 6}
	before := copy_region(d.pool[a].px, d.w, r)
	for y in r.y0 ..< r.y1 {
		for x in r.x0 ..< r.x1 {
			d.pool[a].px[y * d.w + x] = 0xff00_ff00
		}
	}
	push_pixel_edit(&h, &d, a, r, before, "Brush")
	expect(hist_can_undo(&h), "a recorded edit is undoable")
	expect(hist_undo_label(&h) == "Brush", "the label is kept")

	hist_undo(&h, &d)
	eq_u32(d.pool[a].px[3 * d.w + 3], 0xffff_0000, "undo restores the pixels")
	eq_u32(d.pool[a].px[0], 0xffff_0000, "undo does not touch pixels outside the rect")
	hist_redo(&h, &d)
	eq_u32(d.pool[a].px[3 * d.w + 3], 0xff00_ff00, "redo reapplies the pixels")

	// Several edits, undone and redone in order.
	for i in 0 ..< 4 {
		rr := Rect_I{i, 0, i + 1, 1}
		b := copy_region(d.pool[a].px, d.w, rr)
		d.pool[a].px[i] = 0xff00_00ff
		push_pixel_edit(&h, &d, a, rr, b, "dot")
	}
	expect(len(h.entries) == 5, "five edits recorded")
	for _ in 0 ..< 4 {
		hist_undo(&h, &d)
	}
	for i in 0 ..< 4 {
		eq_u32(d.pool[a].px[i], 0xffff_0000, "undo walked back through every dot")
	}
	for _ in 0 ..< 4 {
		hist_redo(&h, &d)
	}
	for i in 0 ..< 4 {
		eq_u32(d.pool[a].px[i], 0xff00_00ff, "redo walked forward through every dot")
	}

	// A new edit after an undo drops the redo tail.
	hist_undo(&h, &d)
	expect(hist_can_redo(&h), "there is a redo tail after an undo")
	rr := Rect_I{10, 10, 11, 11}
	b := copy_region(d.pool[a].px, d.w, rr)
	d.pool[a].px[10 * d.w + 10] = 0xff00_0000
	push_pixel_edit(&h, &d, a, rr, b, "new")
	expect(!hist_can_redo(&h), "a new edit discards the redo tail")

	// Structural edits: add, reorder, delete.
	m0 := meta_capture(&d)
	bb := doc_new_layer(&d, "b")
	fill_layer(&d, bb, 0xff00_00ff)
	doc_insert(&d, bb, 1)
	push_meta_edit(&h, &d, m0, "New layer")
	expect(len(d.order) == 2, "two layers in the stack")

	m1 := meta_capture(&d)
	d.order[0], d.order[1] = d.order[1], d.order[0]
	d.active = 0
	push_meta_edit(&h, &d, m1, "Reorder")
	expect(d.order[0] == bb, "the stack was reordered")
	hist_undo(&h, &d)
	expect(d.order[0] == a, "undo restores the order")
	hist_redo(&h, &d)
	expect(d.order[0] == bb, "redo reapplies the order")

	m2 := meta_capture(&d)
	doc_remove_at(&d, 0)
	push_meta_edit(&h, &d, m2, "Delete layer")
	expect(len(d.order) == 1, "the layer was removed")
	hist_undo(&h, &d)
	expect(len(d.order) == 2, "undo brings the layer back")
	// The pixels survived, because they live in the pool and only the stack
	// changed. This is the whole point of the pool.
	eq_u32(d.pool[bb].px[0], 0xff00_00ff, "the restored layer still has its pixels")

	// Metadata is restored too.
	m3 := meta_capture(&d)
	d.pool[a].opacity = 0.25
	d.pool[a].blend = .Overlay
	layer_set_name(&d.pool[a], "renamed")
	push_meta_edit(&h, &d, m3, "Properties")
	hist_undo(&h, &d)
	near(d.pool[a].opacity, 1, 0.001, "undo restores opacity")
	expect(d.pool[a].blend == .Normal, "undo restores the blend mode")
	expect(layer_name(&d.pool[a]) == "a", "undo restores the name")

	// The stack is bounded.
	h2: History
	hist_init(&h2)
	defer hist_free(&h2)
	for i in 0 ..< HIST_MAX + 20 {
		rrr := Rect_I{0, 0, 1, 1}
		bbb := copy_region(d.pool[a].px, d.w, rrr)
		push_pixel_edit(&h2, &d, a, rrr, bbb, "x")
	}
	expect(len(h2.entries) == HIST_MAX, "the history is bounded at %d entries", HIST_MAX)
	expect(h2.head == HIST_MAX, "the head follows the trimmed stack")
}

// ---------------------------------------------------------------------------
// Colour
// ---------------------------------------------------------------------------

@(private = "file")
test_color :: proc() {
	// Pack / unpack.
	v := pack_argb(0x12, 0x34, 0x56, 0x78)
	eq_u32(v, 0x7812_3456, "pack_argb lays out AARRGGBB")
	r, g, b, a := unpack_argb(v)
	expect(r == 0x12 && g == 0x34 && b == 0x56 && a == 0x78, "unpack is pack's inverse")

	// HSV round trip over the cube at a stride of 17, which is 4096 colours.
	worst_hsv := f32(0)
	worst_hsl := f32(0)
	for ri := 0; ri < 256; ri += 17 {
		for gi := 0; gi < 256; gi += 17 {
			for bi := 0; bi < 256; bi += 17 {
				rf := f32(ri) / 255
				gf := f32(gi) / 255
				bf := f32(bi) / 255

				h, s, vv := rgb_to_hsv(rf, gf, bf)
				r2, g2, b2 := hsv_to_rgb(h, s, vv)
				worst_hsv = max(worst_hsv, max(abs(r2 - rf), max(abs(g2 - gf), abs(b2 - bf))))

				hh, ss, ll := rgb_to_hsl(rf, gf, bf)
				r3, g3, b3 := hsl_to_rgb(hh, ss, ll)
				worst_hsl = max(worst_hsl, max(abs(r3 - rf), max(abs(g3 - gf), abs(b3 - bf))))
			}
		}
	}
	near(worst_hsv, 0, 0.002, "RGB -> HSV -> RGB round-trips over the cube")
	near(worst_hsl, 0, 0.002, "RGB -> HSL -> RGB round-trips over the cube")

	// Known values.
	h, s, vv := rgb_to_hsv(1, 0, 0)
	expect(h == 0 && s == 1 && vv == 1, "red is hue 0, fully saturated")
	h, s, vv = rgb_to_hsv(0, 1, 0)
	near(h, 120, 0.01, "green is hue 120")
	h, s, vv = rgb_to_hsv(0, 0, 1)
	near(h, 240, 0.01, "blue is hue 240")
	h, s, vv = rgb_to_hsv(0.5, 0.5, 0.5)
	expect(s == 0, "a neutral has no saturation")
	expect(h == 0, "a neutral reports hue 0 rather than noise")
	near(vv, 0.5, 0.001, "value is the maximum channel")

	_, _, l := rgb_to_hsl(1, 1, 1)
	near(l, 1, 0.001, "white has lightness 1")
	_, _, l = rgb_to_hsl(0, 0, 0)
	near(l, 0, 0.001, "black has lightness 0")
	_, _, l = rgb_to_hsl(1, 0, 0)
	near(l, 0.5, 0.001, "a pure hue has lightness 1/2")

	// hsv_to_rgb covers all six sectors.
	for sector in 0 ..< 6 {
		hh := f32(sector) * 60 + 30
		rr, gg, bb := hsv_to_rgb(hh, 1, 1)
		mx := max(rr, max(gg, bb))
		mn := min(rr, min(gg, bb))
		near(mx, 1, 0.001, "sector %d peaks at 1", sector)
		near(mn, 0, 0.001, "sector %d bottoms at 0", sector)
	}

	// Out-of-range hue wraps.
	r1, g1, b1 := hsv_to_rgb(370, 1, 1)
	r2, g2, b2 := hsv_to_rgb(10, 1, 1)
	near(r1, r2, 0.001, "hue wraps above 360")
	near(g1, g2, 0.001, "hue wraps above 360")
	near(b1, b2, 0.001, "hue wraps above 360")

	// Hex.
	expect(hex_string(0xff_3b82f6, context.temp_allocator) == "#3B82F6", "hex formatting is uppercase")
	hv, ok := parse_hex("#3b82f6")
	expect(ok && hv == 0xff_3b82f6, "a six-digit hex parses")
	hv, ok = parse_hex("3B82F6")
	expect(ok && hv == 0xff_3b82f6, "the hash is optional")
	hv, ok = parse_hex("#f0a")
	expect(ok && hv == 0xff_ff00aa, "a three-digit hex expands")
	hv, ok = parse_hex("#3b82f680")
	expect(ok && hv == 0x80_3b82f6, "an eight-digit hex carries alpha")
	_, ok = parse_hex("#zzz")
	expect(!ok, "a non-hex digit is rejected")
	_, ok = parse_hex("#12345")
	expect(!ok, "an odd length is rejected")

	// Round trip through the formatter and back.
	for v2 in SWATCHES {
		s2 := hex_string(v2, context.temp_allocator)
		back, good := parse_hex(s2)
		expect(good && back == v2, "%s round-trips through hex", s2)
	}

	// Luma weights sum to one.
	near(LUMA_R + LUMA_G + LUMA_B, 1, 0.0001, "the luma weights sum to 1")
	near(luma8(255, 255, 255), 1, 0.0001, "white has luma 1")
	near(luma8(0, 0, 0), 0, 0.0001, "black has luma 0")
}

// ---------------------------------------------------------------------------
// The display sampler
// ---------------------------------------------------------------------------

@(private = "file")
test_sampling :: proc() {
	a := u32(0xff00_0000)
	b := u32(0xffff_ffff)

	eq_u32(lerp32(a, b, 0) | 0xff00_0000, a, "lerp32 at t=0 is the first pixel")
	close_u32(lerp32(a, b, 255) | 0xff00_0000, b, 1, "lerp32 at t=255 is the second")
	close_u32(lerp32(a, b, 128) | 0xff00_0000, 0xff80_8080, 2, "lerp32 halfway is the average")
	close_u32(
		lerp32(0xff20_4060, 0xffa0_c0e0, 128) | 0xff00_0000,
		0xff60_80a0,
		2,
		"lerp32 interpolates each channel independently",
	)

	// The corners are exact.
	eq_u32(bilerp(a, b, b, b, 0, 0), a, "bilerp at (0,0) is the top-left sample")
	close_u32(bilerp(b, a, b, b, 255, 0), a, 1, "bilerp at (1,0) is the top-right sample")
	close_u32(bilerp(b, b, a, b, 0, 255), a, 1, "bilerp at (0,1) is the bottom-left sample")
	close_u32(bilerp(b, b, b, a, 255, 255), a, 1, "bilerp at (1,1) is the bottom-right sample")

	// The centre of four is their mean.
	close_u32(bilerp(a, b, b, a, 128, 128), 0xff80_8080, 3, "bilerp at the centre is the mean")

	// Alpha is interpolated, and a soft edge does not darken toward black: a
	// transparent black neighbour must not pull the colour of an opaque white
	// one down, only its alpha.
	v := bilerp(0xffff_ffff, 0x0000_0000, 0xffff_ffff, 0x0000_0000, 128, 0)
	near(f32((v >> 24) & 0xff), 128, 2, "bilerp halves the alpha at a hard matte edge")
	close_u32(v | 0xff00_0000, 0xffff_ffff, 2, "bilerp keeps the colour white across that edge")

	// A fully transparent neighbourhood stays transparent.
	expect(bilerp(0, 0, 0, 0, 128, 128) == 0, "bilerp of nothing is nothing")

	// Monotone in t.
	prev := u32(0)
	mono := true
	for t in u32(0) ..= 255 {
		c := lerp32(0xff00_0000, 0xffff_ffff, t) & 0xff
		if c < prev {
			mono = false
		}
		prev = c
	}
	expect(mono, "lerp32 is monotone in t")
}

// ---------------------------------------------------------------------------
// PNG round trip
// ---------------------------------------------------------------------------

@(private = "file")
test_png_roundtrip :: proc() {
	W, H := 23, 17 // deliberately not a multiple of anything
	d := make_doc(W, H)
	defer doc_free(&d)

	base := doc_new_layer(&d, "base")
	doc_insert(&d, base, 0)
	for y in 0 ..< H {
		for x in 0 ..< W {
			// A pattern that exercises every channel, including partial alpha.
			d.pool[base].px[y * W + x] = pack_argb(
				u8(x * 11 % 256),
				u8(y * 15 % 256),
				u8((x + y) * 7 % 256),
				u8(x == 0 ? 0 : 255),
			)
		}
	}

	top := doc_new_layer(&d, "top")
	doc_insert(&d, top, 1)
	for i in 0 ..< W * H {
		d.pool[top].px[i] = 0x8000_ff00
	}
	d.pool[top].blend = .Screen
	doc_dirty_all(&d)
	doc_composite(&d)

	want := make([]u32, W * H)
	defer delete(want)
	copy(want, d.comp)

	path := fmt.tprintf("/tmp/palmy-photoshop-selftest-%d.png", os.get_pid())
	rgba := doc_rgba(&d, context.temp_allocator)
	expect(len(rgba) == W * H * 4, "the exported buffer is w*h*4 bytes")
	expect(p.write_png_rgba(path, rgba, W, H), "write_png_rgba succeeds")

	img, ok := p.load_image(path, context.temp_allocator)
	expect(ok, "the PNG decodes again")
	if ok {
		expect(img.w == W && img.h == H, "the decoded image has the written dimensions")
		worst := u32(0)
		for i in 0 ..< W * H {
			if dd := px_distance(img.px[i], want[i]); dd > worst {
				worst = dd
			}
		}
		// PNG is lossless, so this has to be exact.
		expect(worst == 0, "the PNG round-trips the composite exactly (worst delta %d)", worst)
	}

	// And opening it back into a document reproduces the pixels.
	st := St {
		zoom      = 1,
		move_pool = -1,
		prev_pool = -1,
	}
	hist_init(&st.hist)
	defer hist_free(&st.hist)
	defer doc_free(&st.doc)
	expect(open_file(&st, path), "the saved file opens as a document")
	if st.doc.w == W {
		l := active_layer(&st.doc)
		worst := u32(0)
		for i in 0 ..< W * H {
			if dd := px_distance(l.px[i], want[i]); dd > worst {
				worst = dd
			}
		}
		expect(worst == 0, "the reopened layer matches what was saved")
	}
	os.remove(path)
	_ = math.sqrt(f32(1))
}
