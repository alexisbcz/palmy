package main

import p "palmy:."
import sc "shadcn:."

@(init)
register_toggle_cases :: proc "contextless" () {
	add_case("toggle-default", proc(ui: ^p.Ctx) {
		sc.toggle_open(ui, false)
		p.icon(ui, sc.ICON_BOLD, "size-4")
		sc.toggle_end(ui)
	})
	add_case("toggle-pressed", proc(ui: ^p.Ctx) {
		sc.toggle_open(ui, true)
		p.icon(ui, sc.ICON_BOLD, "size-4")
		sc.toggle_end(ui)
	})
	add_case("toggle-outline", proc(ui: ^p.Ctx) {
		sc.toggle_open(ui, false, .Outline)
		p.icon(ui, sc.ICON_SUN, "size-4")
		sc.toggle_end(ui)
	})
	add_case("toggle-sm", proc(ui: ^p.Ctx) {sc.toggle(ui, "Bold", false, .Default, .SM)})
	add_case("toggle-lg", proc(ui: ^p.Ctx) {sc.toggle(ui, "Bold", false, .Outline, .LG)})
}

@(init)
register_toggle_group_cases :: proc "contextless" () {
	add_case("toggle-group-default", proc(ui: ^p.Ctx) {
		sc.toggle_group_open(ui)
		defer sc.toggle_group_end(ui)

		sc.toggle_open(ui, true)
		p.icon(ui, sc.ICON_BOLD, "size-4")
		sc.toggle_end(ui)
		sc.toggle_open(ui, false)
		p.icon(ui, sc.ICON_ITALIC, "size-4")
		sc.toggle_end(ui)
		sc.toggle_open(ui, false)
		p.icon(ui, sc.ICON_UNDERLINE, "size-4")
		sc.toggle_end(ui)
	})
	add_case("toggle-group-outline", proc(ui: ^p.Ctx) {
		sc.toggle_group_open(ui, 0)
		defer sc.toggle_group_end(ui)

		sc.toggle_open(ui, true, .Outline, .Default, sc.State{}, .First)
		p.icon(ui, sc.ICON_TEXT_ALIGN_START, "size-4")
		sc.toggle_end(ui)
		sc.toggle_open(ui, false, .Outline, .Default, sc.State{}, .Last)
		p.icon(ui, sc.ICON_TEXT_ALIGN_CENTER, "size-4")
		sc.toggle_end(ui)
	})
	add_case("toggle-group-vertical", proc(ui: ^p.Ctx) {
		sc.toggle_group_open(ui, 2, true)
		defer sc.toggle_group_end(ui)

		sc.toggle_open(ui, true, .Default, .Default, sc.State{}, .No, true)
		p.icon(ui, sc.ICON_BOLD, "size-4")
		sc.toggle_end(ui)
		sc.toggle_open(ui, false, .Default, .Default, sc.State{}, .No, true)
		p.icon(ui, sc.ICON_ITALIC, "size-4")
		sc.toggle_end(ui)
	})
}
