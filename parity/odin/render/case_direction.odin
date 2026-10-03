package main

import p "palmy:."
import sc "shadcn:."

@(init)
register_direction_cases :: proc "contextless" () {
	add_case("direction-rtl", proc(ui: ^p.Ctx) {
		sc.slider_rtl(ui, 1216, 367.188, 373.188)
	})
}
