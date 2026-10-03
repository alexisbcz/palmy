package main

import p "palmy:."
import sc "shadcn:."

@(init)
register_textarea_cases :: proc "contextless" () {
	add_case("textarea-default", proc(ui: ^p.Ctx) {sc.textarea(ui, "", "Type a note")})
	add_case("textarea-disabled", proc(ui: ^p.Ctx) {
		sc.textarea(ui, "Locked note", "", sc.State{disabled = true})
	})
}
