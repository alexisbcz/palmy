package main

import p "palmy:."
import sc "shadcn:."

@(init)
register_input_group_cases :: proc "contextless" () {
	add_case("input-group-icon", proc(ui: ^p.Ctx) {
		sc.input_group_open(ui)
		defer sc.input_group_end(ui)

		sc.ig_addon_open(ui, "inline-start", 16)
		p.icon(ui, sc.ICON_SEARCH, "size-4")
		sc.ig_addon_end(ui)

		sc.ig_input(ui, "Search", 6, 10)
	})

	add_case("input-group-button", proc(ui: ^p.Ctx) {
		sc.input_group_open(ui)
		defer sc.input_group_end(ui)

		sc.ig_input(ui, "Enter a URL", 10, 6)

		sc.ig_addon_open(ui, "inline-end", 24)
		// has-[>button]:mr-[-0.3rem]
		p.style(ui).margin[p.RIGHT] = -4.8
		sc.ig_button_open(ui)
		p.text(ui, "Copy", "whitespace-nowrap")
		p.style(ui).shrink = 0
		sc.ig_button_end(ui)
		sc.ig_addon_end(ui)
	})

	add_case("input-group-text", proc(ui: ^p.Ctx) {
		sc.input_group_open(ui)
		defer sc.input_group_end(ui)

		sc.ig_addon_open(ui, "inline-start", 20)
		sc.ig_text(ui, "https://")
		sc.ig_addon_end(ui)

		sc.ig_input(ui, "example.com", 6, 10)
	})

	add_case("input-group-textarea", proc(ui: ^p.Ctx) {
		sc.input_group_open(ui, true)
		defer sc.input_group_end(ui)

		sc.ig_textarea(ui, "Write a note")

		sc.ig_addon_open(ui, "block-end")
		sc.ig_button_open(ui)
		p.icon(ui, sc.ICON_SEND, "size-3.5")
		sc.ig_button_end(ui)
		sc.ig_addon_end(ui)
	})
}
