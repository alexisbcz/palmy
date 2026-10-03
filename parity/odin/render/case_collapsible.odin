package main

import p "palmy:."
import sc "shadcn:."

@(init)
register_collapsible_cases :: proc "contextless" () {
	add_case("collapsible-open", proc(ui: ^p.Ctx) {
		sc.collapsible(ui, "Details", "Four files changed.", true)
	})
	add_case("collapsible-closed", proc(ui: ^p.Ctx) {
		sc.collapsible(ui, "Details", "Four files changed.", false)
	})
}
