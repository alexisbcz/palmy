package main

import p "palmy:."
import sc "shadcn:."

@(init)
register_kbd_cases :: proc "contextless" () {
	add_case("kbd-default", proc(ui: ^p.Ctx) {sc.kbd(ui, "K")})
	add_case("kbd-group", proc(ui: ^p.Ctx) {
		sc.kbd_group_open(ui)
		sc.kbd(ui, "Ctrl")
		sc.kbd(ui, "Shift")
		sc.kbd(ui, "P")
		sc.kbd_group_end(ui)
	})
}
