package main

import p "palmy:."
import sc "shadcn:."

@(init)
register_breadcrumb_cases :: proc "contextless" () {
	add_case("breadcrumb-default", proc(ui: ^p.Ctx) {
		sc.breadcrumb_open(ui)
		sc.breadcrumb_link(ui, "Home")
		sc.breadcrumb_separator(ui)
		sc.breadcrumb_link(ui, "Docs")
		sc.breadcrumb_separator(ui)
		sc.breadcrumb_page(ui, "Button")
		sc.breadcrumb_close(ui)
	})
	add_case("breadcrumb-ellipsis", proc(ui: ^p.Ctx) {
		sc.breadcrumb_open(ui)
		sc.breadcrumb_link(ui, "Home")
		sc.breadcrumb_separator(ui)
		sc.breadcrumb_ellipsis(ui)
		sc.breadcrumb_separator(ui)
		sc.breadcrumb_page(ui, "Button")
		sc.breadcrumb_close(ui)
	})
}
