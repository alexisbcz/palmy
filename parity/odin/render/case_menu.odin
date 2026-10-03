package main

import p "palmy:."
import sc "shadcn:."

@(init)
register_dropdown_menu_cases :: proc "contextless" () {
	add_case("dropdown-menu-open", proc(ui: ^p.Ctx) {
		sc.menu_content_open(ui)
		defer p.end(ui)

		sc.menu_group_open(ui)
		sc.menu_label(ui, "My account")

		sc.menu_item_open(ui)
		p.icon(ui, sc.ICON_USER, "size-4 shrink-0")
		sc.menu_item_text(ui, "Profile")
		sc.menu_shortcut(ui, "P")
		p.end(ui)

		sc.menu_item_open(ui)
		p.icon(ui, sc.ICON_CREDIT_CARD, "size-4 shrink-0")
		sc.menu_item_text(ui, "Billing")
		p.end(ui)
		p.end(ui)

		sc.menu_separator(ui)

		sc.menu_item_open(ui, true)
		p.icon(ui, sc.ICON_LOG_OUT, "size-4 shrink-0")
		sc.menu_item_text(ui, "Sign out")
		p.end(ui)
	})

	add_case("dropdown-menu-checkbox", proc(ui: ^p.Ctx) {
		sc.menu_content_open(ui)
		defer p.end(ui)

		sc.menu_group_open(ui)
		defer p.end(ui)

		sc.menu_label(ui, "Columns")
		for entry in ([?]struct {
			label:   string,
			checked: bool,
		}{{"Name", true}, {"Email", false}, {"Role", true}}) {
			sc.menu_check_item_open(ui)
			sc.menu_item_text(ui, entry.label)
			if entry.checked {
				sc.menu_indicator(ui)
			}
			p.end(ui)
		}
	})

	add_case("dropdown-menu-radio", proc(ui: ^p.Ctx) {
		sc.menu_content_open(ui)
		defer p.end(ui)

		sc.menu_group_open(ui)
		defer p.end(ui)

		for entry in ([?]struct {
			label:    string,
			selected: bool,
		}{{"Light", true}, {"Dark", false}, {"System", false}}) {
			sc.menu_check_item_open(ui)
			sc.menu_item_text(ui, entry.label)
			if entry.selected {
				sc.menu_indicator(ui)
			}
			p.end(ui)
		}
	})
}

@(init)
register_context_menu_cases :: proc "contextless" () {
	add_case("context-menu-open", proc(ui: ^p.Ctx) {
		sc.menu_content_open(ui)
		defer p.end(ui)

		sc.menu_group_open(ui)
		sc.menu_label(ui, "Actions")

		sc.menu_item_open(ui)
		p.icon(ui, sc.ICON_COPY, "size-4 shrink-0")
		sc.menu_item_text(ui, "Copy")
		sc.menu_shortcut(ui, "C")
		p.end(ui)

		sc.menu_item_open(ui)
		p.icon(ui, sc.ICON_DOWNLOAD, "size-4 shrink-0")
		sc.menu_item_text(ui, "Download")
		p.end(ui)
		p.end(ui)

		sc.menu_separator(ui)

		sc.menu_item_open(ui, true)
		p.icon(ui, sc.ICON_TRASH, "size-4 shrink-0")
		sc.menu_item_text(ui, "Delete")
		p.end(ui)
	})

	add_case("context-menu-checkbox", proc(ui: ^p.Ctx) {
		sc.menu_content_open(ui)
		defer p.end(ui)

		sc.menu_check_item_open(ui)
		sc.menu_item_text(ui, "Show grid")
		sc.menu_indicator(ui)
		p.end(ui)

		sc.menu_check_item_open(ui)
		sc.menu_item_text(ui, "Show rulers")
		p.end(ui)

		sc.menu_separator(ui)

		sc.menu_item_open(ui)
		sc.menu_item_text(ui, "Reset")
		p.end(ui)
	})
}
