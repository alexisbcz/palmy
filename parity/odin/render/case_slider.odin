package main

import p "palmy:."
import sc "shadcn:."

@(init)
register_slider_cases :: proc "contextless" () {
	add_case("slider-default", proc(ui: ^p.Ctx) {sc.slider(ui, {0.5})})
	add_case("slider-range", proc(ui: ^p.Ctx) {sc.slider(ui, {0.25, 0.75})})
	add_case("slider-vertical", proc(ui: ^p.Ctx) {sc.slider(ui, {0.4}, true)})
}
