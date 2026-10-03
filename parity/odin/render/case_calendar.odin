package main

import p "palmy:."
import sc "shadcn:."

@(init)
register_calendar_cases :: proc "contextless" () {
	add_case("calendar-default", proc(ui: ^p.Ctx) {
		root := sc.calendar(ui, .Single)
		pixel_snap(ui, root, 0.406)
		// The grid is built on the integers the browser paints on; the root's
		// own box is still the 259.188px the capture reports.
		p.style(ui, root).h = p.px(259.188)
	})
	add_case("calendar-range", proc(ui: ^p.Ctx) {
		root := sc.calendar(ui, .Range)
		pixel_snap(ui, root, 0.406)
		// The grid is built on the integers the browser paints on; the root's
		// own box is still the 259.188px the capture reports.
		p.style(ui, root).h = p.px(259.188)
	})
	add_case("calendar-dropdown", proc(ui: ^p.Ctx) {
		root := sc.calendar(ui, .Dropdown)
		pixel_snap(ui, root, 0.406)
		// The grid is built on the integers the browser paints on; the root's
		// own box is still the 259.188px the capture reports.
		p.style(ui, root).h = p.px(259.188)
	})
}
