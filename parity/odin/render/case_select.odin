package main

import p "palmy:."
import sc "shadcn:."

@(init)
register_select_cases :: proc "contextless" () {
	add_case("select-trigger", proc(ui: ^p.Ctx) {
		sc.select_trigger(ui, "Banana")
	})

	add_case("select-trigger-sm", proc(ui: ^p.Ctx) {
		sc.select_trigger(ui, "", "Pick a fruit", true)
	})

	add_case("select-open", proc(ui: ^p.Ctx) {
		sc.select_content_open(ui)
		defer p.end(ui)

		sc.select_list_open(ui)
		defer p.end(ui)

		sc.select_group_open(ui)
		defer p.end(ui)

		sc.select_label(ui, "Fruit")
		sc.select_item(ui, "Apple")
		sc.select_item(ui, "Banana", true)
		sc.menu_separator(ui)
		sc.select_item(ui, "Cherry")
	})
}

@(init)
register_combobox_cases :: proc "contextless" () {
	add_case("combobox-open", proc(ui: ^p.Ctx) {
		sc.combobox_content_open(ui)
		defer p.end(ui)

		sc.combobox_list_open(ui)
		defer p.end(ui)

		for fruit in ([?]string{"Apple", "Banana", "Cherry", "Date"}) {
			sc.combobox_item(ui, fruit)
		}
	})

	add_case("combobox-empty", proc(ui: ^p.Ctx) {
		sc.combobox_content_open(ui)
		sc.combobox_empty(ui, "No results.")
		p.end(ui)
	})

	add_case("combobox-chips", proc(ui: ^p.Ctx) {
		sc.combobox_chips_open(ui)
		defer p.end(ui)

		sc.combobox_chip(ui, "Apple")
		sc.combobox_chip(ui, "Cherry")
		sc.combobox_chips_input(ui, "Add")
	})
}
