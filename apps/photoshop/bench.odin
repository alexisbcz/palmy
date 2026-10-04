package main

// `photoshop --bench` — the frame budget, measured.
//
// Every number the README-style claims in this app rest on is produced here, on
// this machine, from the same procedures the window runs. A software rasterizer
// has no slack: if the composite and the blit together do not fit inside a
// frame the drag feels like a drag.

import "core:fmt"
import "core:time"
import p "palmy:."

@(private = "file")
Result :: struct {
	name: string,
	ms:   f64,
	px:   int,
}

@(private = "file")
bench :: proc(name: string, px: int, iters: int, user: ^St, body: proc(st: ^St)) -> Result {
	body(user) // warm
	best := max(f64)
	for _ in 0 ..< iters {
		t := time.tick_now()
		body(user)
		ms := time.duration_milliseconds(time.tick_since(t))
		best = min(best, ms)
	}
	return {name, best, px}
}

bench_main :: proc() -> bool {
	W, H := 1024, 768
	st: St
	st_init(&st)
	new_document(&st, W, H, 0)
	starter_content(&st)
	defer doc_free(&st.doc)
	defer hist_free(&st.hist)
	defer stroke_free(&st.stroke)

	// A canvas the size of the editor's viewport.
	VW, VH := 1032, 740
	px := make([]u32, VW * VH)
	defer delete(px)
	canvas := p.canvas_from(px, VW, VH, 1)
	defer p.canvas_destroy(&canvas)
	st.view = {0, 0, f32(VW), f32(VH)}

	results := make([dynamic]Result)
	defer delete(results)

	append(
		&results,
		bench("composite, full 1024x768 x 3 layers", W * H, 30, &st, proc(st: ^St) {
			doc_dirty_all(&st.doc)
			doc_composite(&st.doc)
		}),
	)
	append(
		&results,
		bench("composite, 64x64 dirty rect (a brush stamp)", 64 * 64, 2000, &st, proc(st: ^St) {
			doc_dirty(&st.doc, {200, 200, 264, 264})
			doc_composite(&st.doc)
		}),
	)

	// Blits. `bench` takes no closure, so the canvas travels through the state.
	bench_canvas = &canvas
	bench_rect = {0, 0, f32(VW), f32(VH)}

	st.zoom = 1
	st.pan = {}
	append(&results, bench("blit 1:1 (nearest fast path)", 1024 * 740, 60, &st, blit_once))

	st.zoom = 0.92
	append(&results, bench("blit at 92% (bilinear)", 942 * 707, 60, &st, blit_once))

	st.zoom = 0.5
	append(&results, bench("blit at 50% (bilinear)", 512 * 384, 60, &st, blit_once))

	st.zoom = 4
	append(&results, bench("blit at 400% (nearest)", VW * VH, 60, &st, blit_once))

	st.zoom = 1

	append(
		&results,
		bench("  included above: workspace fill", VW * VH, 60, &st, proc(st: ^St) {
			p.fill_rect(bench_canvas, bench_rect, WORKSPACE)
		}),
	)
	append(
		&results,
		bench("  rejected: the same drop shadow unclipped", 0, 20, &st, proc(st: ^St) {
			p.drop_shadow(bench_canvas, {4, 4, 1024, 740}, {0, 0, 0, 0}, 18, 0, {0, 4}, {0, 0, 0, 130})
		}),
	)

	// Painting.
	append(
		&results,
		bench("brush: one 36 px stamp + resolve", 40 * 40, 2000, &st, proc(st: ^St) {
			stroke_begin(&st.stroke, &st.doc, false)
			stroke_to(&st.stroke, &st.doc, st.brush, {400, 400}, st.fg, clip_rect(st))
		}),
	)
	append(
		&results,
		bench("brush: a 600 px drag in one sample (interpolated)", 0, 200, &st, proc(st: ^St) {
			stroke_begin(&st.stroke, &st.doc, false)
			stroke_to(&st.stroke, &st.doc, st.brush, {100, 400}, st.fg, clip_rect(st))
			stroke_to(&st.stroke, &st.doc, st.brush, {700, 400}, st.fg, clip_rect(st))
		}),
	)

	// Adjustments and filters, over the whole layer.
	append(
		&results,
		bench("brightness / contrast (LUT)", W * H, 30, &st, proc(st: ^St) {
			l := active_layer(&st.doc)
			apply_adjust(.Brightness_Contrast, {0 = 20, 1 = 30, 2 = 0, 3 = 0, 4 = 0}, l.px, l.px, st.doc.w, {0, 0, st.doc.w, st.doc.h})
		}),
	)
	append(
		&results,
		bench("hue / saturation (per pixel HSL)", W * H, 10, &st, proc(st: ^St) {
			l := active_layer(&st.doc)
			apply_adjust(.Hue_Sat, {0 = 30, 1 = 20, 2 = 0, 3 = 0, 4 = 0}, l.px, l.px, st.doc.w, {0, 0, st.doc.w, st.doc.h})
		}),
	)
	append(
		&results,
		bench("gaussian blur, radius 8 (separable)", W * H, 5, &st, proc(st: ^St) {
			l := active_layer(&st.doc)
			filter_blur(l.px, l.px, st.doc.w, st.doc.h, {0, 0, st.doc.w, st.doc.h}, 8)
		}),
	)
	append(
		&results,
		bench("unsharp mask, radius 2 / 100%", W * H, 5, &st, proc(st: ^St) {
			l := active_layer(&st.doc)
			filter_sharpen(l.px, l.px, st.doc.w, st.doc.h, {0, 0, st.doc.w, st.doc.h}, 2, 100)
		}),
	)
	append(
		&results,
		bench("sobel edge detect", W * H, 10, &st, proc(st: ^St) {
			l := active_layer(&st.doc)
			filter_edges(l.px, l.px, st.doc.w, st.doc.h, {0, 0, st.doc.w, st.doc.h}, 100)
		}),
	)
	append(
		&results,
		bench("layer thumbnail (box filter)", W * H, 50, &st, proc(st: ^St) {
			st.doc.pool[active_pool(&st.doc)].thumb_old = true
			layer_thumb(&st.doc, active_pool(&st.doc))
		}),
	)

	fmt.println("photoshop bench — best of n, milliseconds")
	fmt.println()
	for r in results {
		if r.px > 0 {
			fmt.printfln("  %-50s %7.3f ms   %5.1f ns/px", r.name, r.ms, r.ms * 1e6 / f64(r.px))
		} else {
			fmt.printfln("  %-50s %7.3f ms", r.name, r.ms)
		}
	}
	fmt.println()
	return true
}

@(private = "file")
bench_canvas: ^p.Canvas
@(private = "file")
bench_rect: p.Rect

@(private = "file")
blit_once :: proc(st: ^St) {
	p.reset_clip(bench_canvas)
	draw_canvas(bench_canvas, bench_rect, st)
}
