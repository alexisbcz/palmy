package main

import p "palmy:."
import sc "shadcn:."

@(init)
register_checkbox_cases :: proc "contextless" () {
	add_case("checkbox-default", proc(ui: ^p.Ctx) {sc.checkbox(ui, .Off)})
	add_case("checkbox-checked", proc(ui: ^p.Ctx) {sc.checkbox(ui, .On)})
	add_case("checkbox-indeterminate", proc(ui: ^p.Ctx) {sc.checkbox(ui, .Indeterminate)})
	add_case("checkbox-disabled", proc(ui: ^p.Ctx) {
		sc.checkbox(ui, .On, sc.State{disabled = true})
	})
}
