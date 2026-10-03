package main

import p "palmy:."
import sc "shadcn:."

// The accordion was captured at a half-pixel offset (`cropOffset.y` is 0.5).
// Chromium snaps a painted box edge, and a glyph origin, to whole device
// pixels; palmy antialiases them instead, which turns every hairline into two
// half-strength rows and rounds each baseline the other way. Nudging the whole
// case onto the pixel grid is what Chromium effectively does.
accordion_case :: proc(ui: ^p.Ctx, first_open, second_open: bool) {
	p.div(ui, "flex-col")
	defer p.end(ui)
	p.style(ui).margin[p.TOP] = 0.5

	sc.accordion_open(ui)
	sc.accordion_item(ui, "Shipping", "Ships in two days.", first_open, false)
	sc.accordion_item(ui, "Returns", "Thirty day window.", second_open, true)
	sc.accordion_close(ui)
}

@(init)
register_accordion_cases :: proc "contextless" () {
	add_case("accordion-default", proc(ui: ^p.Ctx) {accordion_case(ui, true, false)})
	add_case("accordion-closed", proc(ui: ^p.Ctx) {accordion_case(ui, false, false)})
	add_case("accordion-multiple", proc(ui: ^p.Ctx) {accordion_case(ui, true, true)})
}
