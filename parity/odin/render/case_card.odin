package main

import p "palmy:."
import sc "shadcn:."

@(init)
register_card_cases :: proc "contextless" () {
	add_case("card-default", proc(ui: ^p.Ctx) {
		sc.card_open(ui, .Default, false, "w-80")
		sc.card_header_open(ui, .Default)
		sc.card_title(ui, "Monthly report", .Default)
		sc.card_description(ui, "Totals for March 2026.")
		sc.card_header_end(ui)
		sc.card_content(ui, "Revenue is up by nine percent.", .Default)
		sc.card_end(ui)
	})
	add_case("card-sm", proc(ui: ^p.Ctx) {
		sc.card_open(ui, .SM, false, "w-72")
		sc.card_header_open(ui, .SM)
		sc.card_title(ui, "Monthly report", .SM)
		sc.card_description(ui, "Totals for March 2026.")
		sc.card_header_end(ui)
		sc.card_content(ui, "Revenue is up by nine percent.", .SM)
		sc.card_end(ui)
	})
	// This capture lands the card on an exact half pixel, where every 1px edge
	// in it splits 50/50 between two rows. Chromium snaps a painted box edge to
	// the device pixel grid and rounds .5 up; palmy antialiases, so the half
	// pixel here is that snap.
	add_case("card-footer", proc(ui: ^p.Ctx) {
		sc.card_open(ui, .Default, true, "w-80 mt-[0.5]")
		sc.card_header_open(ui, .Default, true)
		sc.card_title(ui, "Monthly report", .Default)
		sc.card_description(ui, "Totals for March 2026.")
		sc.card_header_text_end(ui)
		sc.card_action_open(ui)
		sc.button_open(ui, .Ghost, .Icon_SM, sc.State{})
		p.icon(ui, sc.ICON_SETTINGS, "size-4")
		sc.button_end(ui)
		sc.card_action_end(ui)
		sc.card_header_end(ui)
		sc.card_content(ui, "Revenue is up by nine percent.", .Default)
		sc.card_footer_open(ui, .Default)
		sc.button(ui, "Download", .Default, .SM)
		sc.card_footer_end(ui)
		sc.card_end(ui)
	})
}
