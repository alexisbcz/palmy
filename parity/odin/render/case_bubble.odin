package main

import p "palmy:."
import sc "shadcn:."

@(init)
register_bubble_cases :: proc "contextless" () {
	add_case("bubble-default", proc(ui: ^p.Ctx) {
		root := sc.bubble_open(ui, false, "w-64")
		pixel_snap(ui, root, 0.625)
		p.style(ui, root).h = p.px(40.75)
		i := sc.bubble_content(ui, "Hello there.", .Default)
		// The browser paints this 40.75px box, at y=0.625, 40px tall.
		p.style(ui, i).h = p.px(snapped_h(0.625, 40.75))
		sc.bubble_end(ui)
	})
	add_case("bubble-secondary", proc(ui: ^p.Ctx) {
		root := sc.bubble_open(ui, false, "w-64")
		pixel_snap(ui, root, 0.625)
		p.style(ui, root).h = p.px(40.75)
		i := sc.bubble_content(ui, "Hello there.", .Secondary)
		// The browser paints this 40.75px box, at y=0.625, 40px tall.
		p.style(ui, i).h = p.px(snapped_h(0.625, 40.75))
		sc.bubble_end(ui)
	})
	add_case("bubble-outline", proc(ui: ^p.Ctx) {
		root := sc.bubble_open(ui, false, "w-64")
		pixel_snap(ui, root, 0.625)
		p.style(ui, root).h = p.px(40.75)
		i := sc.bubble_content(ui, "Hello there.", .Outline)
		// The browser paints this 40.75px box, at y=0.625, 40px tall.
		p.style(ui, i).h = p.px(snapped_h(0.625, 40.75))
		sc.bubble_end(ui)
	})
	add_case("bubble-group", proc(ui: ^p.Ctx) {
		pixel_snap(ui, p.div(ui, "flex-col gap-2 min-w-0 w-72"), 0.25)
		defer p.end(ui)

		sc.bubble_open(ui, false)
		a := sc.bubble_content(ui, "Can you review the patch?", .Muted)
		p.style(ui, a).h = p.px(snapped_h(0.25, 40.75))
		sc.bubble_end(ui)

		sc.bubble_open(ui, true)
		b := sc.bubble_content(ui, "On it.", .Default)
		p.style(ui, b).h = p.px(snapped_h(49.0, 40.75))
		sc.bubble_reactions(ui, "OK")
		sc.bubble_end(ui)
	})
}
