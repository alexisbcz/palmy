package main

import p "palmy:."
import sc "shadcn:."

@(init)
register_aspect_ratio_cases :: proc "contextless" () {
	add_case("aspect-ratio-16-9", proc(ui: ^p.Ctx) {
		sc.aspect_ratio(ui, 320, 16.0 / 9.0, "rounded-lg bg-muted")
	})
	add_case("aspect-ratio-1-1", proc(ui: ^p.Ctx) {
		sc.aspect_ratio(ui, 192, 1, "rounded-lg bg-muted")
	})
}
