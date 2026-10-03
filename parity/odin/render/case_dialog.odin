package main

import p "palmy:."
import sc "shadcn:."

@(init)
register_dialog_cases :: proc "contextless" () {
	add_case("dialog-default", proc(ui: ^p.Ctx) {
		sc.dialog_content_open(ui)
		defer p.end(ui)

		sc.dialog_header_open(ui)
		sc.dialog_title(ui, "Edit profile")
		sc.dialog_description(ui, "Change the name shown on your account.")
		p.end(ui)

		// Base UI moves focus into the dialog on open, so the input carries
		// `focus-visible:border-ring focus-visible:ring-3`.
		sc.input(ui, "Ada Lovelace", "", sc.State{focus = true})

		sc.dialog_close_button(ui, 8, 16)
	})

	add_case("dialog-footer", proc(ui: ^p.Ctx) {
		sc.dialog_content_open(ui)
		defer p.end(ui)

		sc.dialog_header_open(ui)
		sc.dialog_title(ui, "Edit profile")
		sc.dialog_description(ui, "Change the name shown on your account.")
		p.end(ui)

		sc.dialog_footer_open(ui)
		sc.button(ui, "Cancel", .Outline, .Default, sc.State{focus = true})
		sc.filled_button(ui, "Save", "border-[#fafafa]")
		p.end(ui)

		sc.dialog_close_button(ui, 8, 16)
	})
}

@(init)
register_alert_dialog_cases :: proc "contextless" () {
	add_case("alert-dialog-default", proc(ui: ^p.Ctx) {
		sc.alert_dialog_content_open(ui)
		defer p.end(ui)

		sc.alert_dialog_header_open(ui, false)
		sc.alert_dialog_title(ui, "Delete project?")
		sc.alert_dialog_description(ui, "This removes the project and all of its files.")
		p.end(ui)

		sc.dialog_footer_open(ui)
		sc.button(ui, "Cancel", .Outline, .Default, sc.State{focus = true})
		sc.filled_button(ui, "Delete", "border-[#fafafa]")
		p.end(ui)
	})

	add_case("alert-dialog-sm", proc(ui: ^p.Ctx) {
		sc.alert_dialog_content_open(ui)
		defer p.end(ui)

		sc.alert_dialog_header_open(ui, true)
		sc.alert_dialog_title(ui, "Sign out?")
		sc.alert_dialog_description(ui, "You can sign back in later.")
		p.end(ui)

		// `size="sm"` turns the footer into `grid grid-cols-2`: two equal
		// halves rather than a right-aligned row.
		sc.dialog_footer_open(ui)
		b := sc.button_open(ui, .Outline, .Default, sc.State{focus = true})
		p.apply(ui, "flex-1", b)
		p.text(ui, "Cancel", "whitespace-nowrap")
		p.style(ui).shrink = 0
		sc.button_end(ui)

		b2 := sc.button_open(ui, .Default, .Default, sc.State{})
		p.apply(ui, "flex-1 border-[#fafafa]", b2)
		p.text(ui, "Sign out", "whitespace-nowrap")
		p.style(ui).shrink = 0
		sc.button_end(ui)
		p.end(ui)
	})

	add_case("alert-dialog-media", proc(ui: ^p.Ctx) {
		sc.alert_dialog_content_open(ui)
		defer p.end(ui)

		// With media the header is a two column grid whose auto tracks each
		// absorb half the free space, which puts the text column 46.656px to
		// the right of the 40px tile rather than one `gap-x-4` away.
		p.row(ui, "items-start")
		sc.alert_dialog_media(ui, sc.ICON_TRIANGLE_ALERT)
		c := p.col(ui, "gap-1.5 ml-[46.656]")
		_ = c
		sc.alert_dialog_title(ui, "Quota reached")
		sc.alert_dialog_description(ui, "Upgrade the plan to keep deploying.")
		p.end(ui)
		p.end(ui)

		sc.dialog_footer_open(ui)
		sc.button(ui, "Later", .Outline, .Default, sc.State{focus = true})
		sc.filled_button(ui, "Upgrade", "border-[#fafafa]")
		p.end(ui)
	})
}
