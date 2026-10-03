package main

import p "palmy:."
import sc "shadcn:."

@(init)
register_navigation_menu_cases :: proc "contextless" () {
	add_case("navigation-menu-closed", proc(ui: ^p.Ctx) {
		sc.navigation_menu_open(ui)
		sc.navigation_menu_trigger(ui, "Products")
		sc.navigation_menu_trigger(ui, "Company")
		sc.navigation_menu_close(ui)
	})
	add_case("navigation-menu-open", proc(ui: ^p.Ctx) {
		sc.navigation_menu_content_open(ui)
		sc.navigation_menu_link(ui, "Launch", sc.ICON_ROCKET)
		sc.navigation_menu_link(ui, "Favourites", sc.ICON_STAR)
		sc.navigation_menu_content_close(ui)
	})
}
