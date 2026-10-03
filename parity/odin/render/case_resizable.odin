package main

import p "palmy:."
import sc "shadcn:."

@(init)
register_resizable_cases :: proc "contextless" () {
	add_case("resizable-horizontal", proc(ui: ^p.Ctx) {
		sc.resizable_group(ui, .Horizontal, {"Left", "Right"}, 606.5, true, 38)
	})
	add_case("resizable-vertical", proc(ui: ^p.Ctx) {
		pixel_snap(ui, sc.resizable_group(ui, .Vertical, {"Top", "Bottom"}, 0, false, 3), 0.5)
	})
}
