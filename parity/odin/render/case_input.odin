package main

import p "palmy:."
import sc "shadcn:."

@(init)
register_input_cases :: proc "contextless" () {
	add_case("input-default", proc(ui: ^p.Ctx) {sc.input(ui, "Ada Lovelace")})
	add_case("input-placeholder", proc(ui: ^p.Ctx) {sc.input(ui, "", "Email address")})
	add_case("input-invalid", proc(ui: ^p.Ctx) {
		sc.input(ui, "nope", "", sc.State{invalid = true})
	})
	add_case("input-disabled", proc(ui: ^p.Ctx) {
		sc.input(ui, "Locked", "", sc.State{disabled = true})
	})
}
