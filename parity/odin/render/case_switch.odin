package main

import p "palmy:."
import sc "shadcn:."

@(init)
register_switch_cases :: proc "contextless" () {
	add_case("switch-off", proc(ui: ^p.Ctx) {sc.switch_(ui, false)})
	add_case("switch-on", proc(ui: ^p.Ctx) {sc.switch_(ui, true)})
	add_case("switch-sm", proc(ui: ^p.Ctx) {sc.switch_(ui, true, .SM)})
	add_case("switch-disabled", proc(ui: ^p.Ctx) {
		sc.switch_(ui, true, .Default, sc.State{disabled = true})
	})
}
