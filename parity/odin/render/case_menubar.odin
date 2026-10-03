package main

import p "palmy:."
import sc "shadcn:."

@(init)
register_menubar_cases :: proc "contextless" () {
	add_case("menubar-closed", proc(ui: ^p.Ctx) {
		sc.menubar_open(ui)
		sc.menubar_trigger(ui, "File")
		sc.menubar_trigger(ui, "Edit")
		sc.menubar_trigger(ui, "View")
		sc.menubar_close(ui)
	})
	add_case("menubar-open", proc(ui: ^p.Ctx) {
		sc.menubar_content_open(ui)
		sc.menubar_item(ui, "New tab", "T")
		sc.menubar_item(ui, "New window")
		sc.menubar_separator(ui)
		sc.menubar_item(ui, "Print")
		sc.menubar_content_close(ui)
	})
}
