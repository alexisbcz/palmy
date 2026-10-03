package main

import p "palmy:."
import sc "shadcn:."

@(init)
register_carousel_cases :: proc "contextless" () {
	add_case("carousel-default", proc(ui: ^p.Ctx) {
		sc.carousel(ui, {"One", "Two", "Three"}, "w-72")
	})
}
