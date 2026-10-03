package main

import p "palmy:."
import sc "shadcn:."

@(init)
register_sheet_cases :: proc "contextless" () {
	add_case("sheet-right", proc(ui: ^p.Ctx) {
		sc.sheet_content_open(ui, .Right)
		defer p.end(ui)

		sc.sheet_header_open(ui)
		sc.sheet_title(ui, "Edit profile")
		sc.sheet_description(ui, "Make changes and save.")
		p.end(ui)

		sc.sheet_spacer(ui)

		sc.sheet_footer_open(ui)
		// Focus lands on the first tabbable element when the sheet opens.
		sc.button(ui, "Save", .Default, .Default, sc.State{focus = true})
		p.end(ui)

		sc.dialog_close_button(ui, 12, 0)
	})

	add_case("sheet-bottom", proc(ui: ^p.Ctx) {
		sc.sheet_content_open(ui, .Bottom)
		defer p.end(ui)

		sc.sheet_header_open(ui)
		sc.sheet_title(ui, "Edit profile")
		sc.sheet_description(ui, "Make changes and save.")
		p.end(ui)

		sc.sheet_footer_open(ui)
		sc.button(ui, "Save", .Default, .Default, sc.State{focus = true})
		p.end(ui)

		sc.dialog_close_button(ui, 12, 0)
	})
}

@(init)
register_drawer_cases :: proc "contextless" () {
	add_case("drawer-bottom", proc(ui: ^p.Ctx) {
		sc.drawer_content_open(ui, .Bottom)
		defer p.end(ui)

		sc.drawer_body_open(ui, .Bottom)
		defer p.end(ui)

		sc.drawer_header_open(ui, true)
		sc.sheet_title(ui, "Share link")
		sc.sheet_description(ui, "Anyone can view this page.")
		p.end(ui)

		sc.drawer_footer_open(ui)
		sc.filled_button(ui, "Copy link", "border-popover")
		p.end(ui)
	})

	add_case("drawer-right", proc(ui: ^p.Ctx) {
		sc.drawer_content_open(ui, .Right)
		defer p.end(ui)

		sc.drawer_body_open(ui, .Right)
		defer p.end(ui)

		sc.drawer_header_open(ui, false)
		sc.sheet_title(ui, "Share link")
		sc.sheet_description(ui, "Anyone can view this page.")
		p.end(ui)

		sc.sheet_spacer(ui)

		sc.drawer_footer_open(ui)
		sc.filled_button(ui, "Copy link", "border-popover")
		p.end(ui)
	})
}

@(init)
register_toast_cases :: proc "contextless" () {
	add_case("toast-default", proc(ui: ^p.Ctx) {
		sc.toast_open(ui)
		defer p.end(ui)

		sc.toast_content_open(ui)
		defer p.end(ui)

		sc.toast_text_open(ui)
		sc.toast_title(ui, "Saved")
		sc.toast_description(ui, "Your changes are stored.")
		p.end(ui)

		sc.toast_close(ui)
	})

	add_case("toast-action", proc(ui: ^p.Ctx) {
		sc.toast_open(ui)
		defer p.end(ui)

		sc.toast_content_open(ui)
		defer p.end(ui)

		sc.toast_text_open(ui)
		sc.toast_title(ui, "Item deleted")
		sc.toast_description(ui, "The row was removed.")
		p.end(ui)

		sc.toast_action(ui, "Undo")
		sc.toast_close(ui)
	})
}
