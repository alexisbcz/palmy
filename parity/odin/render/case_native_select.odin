package main

import p "palmy:."
import sc "shadcn:."

@(init)
register_native_select_cases :: proc "contextless" () {
	add_case("native-select-default", proc(ui: ^p.Ctx) {sc.native_select(ui, "Banana")})
	add_case("native-select-sm", proc(ui: ^p.Ctx) {sc.native_select(ui, "Apple", .SM)})
}
