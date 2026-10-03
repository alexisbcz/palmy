package main

import p "palmy:."
import sc "shadcn:."

@(init)
register_sidebar_cases :: proc "contextless" () {
	add_case("sidebar-default", proc(ui: ^p.Ctx) {
		sc.sidebar_open(ui, "h-96")

		sc.sidebar_header_open(ui)
		sc.sidebar_menu_open(ui)
		sc.sidebar_menu_item_open(ui)
		sc.sidebar_menu_button(ui, "Acme Inc", sc.ICON_HOUSE, false, true)
		sc.sidebar_close_one(ui)
		sc.sidebar_close_one(ui)
		sc.sidebar_section_close(ui)

		sc.sidebar_separator(ui)

		sc.sidebar_content_open(ui)
		sc.sidebar_group_open(ui)
		sc.sidebar_group_label(ui, "Platform")
		sc.sidebar_group_content_open(ui)
		sc.sidebar_menu_open(ui)

		sc.sidebar_menu_item_open(ui)
		sc.sidebar_menu_button(ui, "Inbox", sc.ICON_INBOX, true)
		sc.sidebar_menu_badge(ui, "4", true)
		sc.sidebar_close_one(ui)

		sc.sidebar_menu_item_open(ui)
		sc.sidebar_menu_button(ui, "Calendar", sc.ICON_CALENDAR)
		sc.sidebar_close_one(ui)

		sc.sidebar_close_one(ui)
		sc.sidebar_close_one(ui)
		sc.sidebar_close_one(ui)
		sc.sidebar_close_one(ui)

		sc.sidebar_footer_open(ui)
		sc.sidebar_menu_open(ui)
		sc.sidebar_menu_item_open(ui)
		sc.sidebar_menu_button(ui, "Settings", sc.ICON_SETTINGS)
		sc.sidebar_close_one(ui)
		sc.sidebar_close_one(ui)
		sc.sidebar_section_close(ui)

		sc.sidebar_close(ui)
	})

	add_case("sidebar-submenu", proc(ui: ^p.Ctx) {
		sc.sidebar_open(ui, "h-72")
		sc.sidebar_content_open(ui)
		sc.sidebar_group_open(ui)
		sc.sidebar_group_label(ui, "Project")
		sc.sidebar_menu_open(ui)
		sc.sidebar_menu_item_open(ui)
		sc.sidebar_menu_button(ui, "src", sc.ICON_FOLDER)
		sc.sidebar_menu_sub_open(ui)
		sc.sidebar_menu_sub_button(ui, "index.ts")
		sc.sidebar_menu_sub_button(ui, "app.tsx", true)
		sc.sidebar_close_one(ui)
		sc.sidebar_close_one(ui)
		sc.sidebar_close_one(ui)
		sc.sidebar_close_one(ui)
		sc.sidebar_close_one(ui)
		sc.sidebar_close(ui)
	})
}
