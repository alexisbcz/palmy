package main

import p "palmy:."
import sc "shadcn:."

@(init)
register_button_group_cases :: proc "contextless" () {
	add_case("button-group-horizontal", proc(ui: ^p.Ctx) {
		sc.button_group_open(ui, false)
		sc.button_group_button(ui, "Left", .First, false)
		sc.button_group_button(ui, "Middle", .Middle, false)
		sc.button_group_button(ui, "Right", .Last, false)
		sc.button_group_close(ui)
	})
	add_case("button-group-vertical", proc(ui: ^p.Ctx) {
		sc.button_group_open(ui, true)
		sc.button_group_button(ui, "Top", .First, true)
		sc.button_group_button(ui, "Middle", .Middle, true)
		sc.button_group_button(ui, "Bottom", .Last, true)
		sc.button_group_close(ui)
	})
	add_case("button-group-text", proc(ui: ^p.Ctx) {
		sc.button_group_open(ui, false)
		sc.button_group_text(ui, "https://", .First, false)
		sc.button_group_button(ui, "Copy", .Middle, false)
		sc.button_group_separator(ui, true)
		sc.button_group_button(ui, "Open", .Last, false)
		sc.button_group_close(ui)
	})
}
