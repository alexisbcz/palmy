package main

import p "palmy:."
import sc "shadcn:."

@(init)
register_label_cases :: proc "contextless" () {
	add_case("label-default", proc(ui: ^p.Ctx) {sc.label(ui, "Email address")})
}
