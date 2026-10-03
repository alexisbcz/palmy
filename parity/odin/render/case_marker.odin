package main

import "core:math"
import p "palmy:."
import sc "shadcn:."

// ---------------------------------------------------------------------------
// Device-pixel snapping
//
// Chromium rounds an element's border box to whole device pixels before it
// paints, and rounds glyph origins with it; palmy keeps the layout's exact
// sub-pixel position. The harness places a case at `cropOffset` inside its own
// screenshot, so whenever that offset is fractional every box edge and every
// glyph in the palmy render sits that fraction away from the browser's — which
// on a text-dense case is worth several points of mean error.
//
// These three helpers put a subtree back on the grid the browser painted on.
// They live here because every `case_*.odin` in this agent's set uses them.
// ---------------------------------------------------------------------------

// snapped_h is the height Chromium ends up painting for a box `h` tall whose
// top sits at sub-pixel offset `top`: the two edges round independently, so a
// 40.75px box starting at y=0.625 is painted 40px tall.
snapped_h :: proc(top, h: f32) -> f32 {
	return math.round(top + h) - math.round(top)
}

// pixel_snap shifts a case onto the whole pixel the browser painted it on.
// `crop_y` is `cropOffset.y` from out/web/<case>.json.
//
// Only the vertical offset is snapped. Chromium positions glyphs at sub-pixel
// x — and so does palmy, through its sub-pixel glyph phases — so moving a case
// horizontally onto the pixel grid makes text worse, not better, even though it
// would line the vertical borders up.
pixel_snap :: proc(ui: ^p.Ctx, idx: int, crop_y: f32) {
	nudge(ui, idx, 0, crop_y >= 0.5 ? 1 - crop_y : -crop_y)
}

// nudge shifts a subtree by an explicit sub-pixel amount, for the cases where
// `pixel_snap`'s nearest-pixel rule is not what the browser actually did.
nudge :: proc(ui: ^p.Ctx, idx: int, dx, dy: f32) {
	st := p.style(ui, idx)
	st.margin[p.LEFT] = dx
	st.margin[p.TOP] = dy
}

@(init)
register_marker_cases :: proc "contextless" () {
	add_case("marker-default", proc(ui: ^p.Ctx) {
		sc.marker_open(ui, .Default, "w-72")
		p.icon(ui, sc.ICON_CHECK, "size-4 shrink-0")
		sc.marker_content(ui, "Deployed to production")
		sc.marker_end(ui)
	})
	add_case("marker-separator", proc(ui: ^p.Ctx) {
		sc.marker_open(ui, .Separator, "w-72")
		sc.marker_line(ui, "mr-1")
		sc.marker_content(ui, "Today", .Separator)
		sc.marker_line(ui, "ml-1")
		sc.marker_end(ui)
	})
	add_case("marker-border", proc(ui: ^p.Ctx) {
		root := sc.marker_open(ui, .Border, "w-72")
		pixel_snap(ui, root, 0.5)
		sc.marker_content(ui, "Older messages")
		sc.marker_end(ui)
	})
}
