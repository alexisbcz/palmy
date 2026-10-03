package main

import p "palmy:."
import sc "shadcn:."

@(init)
register_spinner_cases :: proc "contextless" () {
	add_case("spinner-default", proc(ui: ^p.Ctx) {sc.spinner(ui)})
	add_case("spinner-lg", proc(ui: ^p.Ctx) {sc.spinner(ui, "size-8")})
}
