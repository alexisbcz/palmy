package main

import p "palmy:."
import sc "shadcn:."

@(init)
register_field_cases :: proc "contextless" () {
	add_case("field-vertical", proc(ui: ^p.Ctx) {
		sc.field_open(ui)
		defer sc.field_end(ui)

		sc.field_label(ui, "Email")
		sc.input(ui, "", "ada@example.com")
		sc.field_description(ui, "We never share this address.")
	})

	add_case("field-horizontal", proc(ui: ^p.Ctx) {
		sc.field_open(ui, true)
		defer sc.field_end(ui)

		sc.switch_(ui, false)
		sc.field_content_open(ui)
		sc.field_title(ui, "Notifications")
		sc.field_description(ui, "Send a weekly digest.")
		p.end(ui)
	})

	add_case("field-error", proc(ui: ^p.Ctx) {
		sc.field_open(ui)
		// data-invalid=true turns the whole field destructive.
		p.apply(ui, "text-destructive")
		defer sc.field_end(ui)

		sc.field_label(ui, "Email")
		sc.field_invalid_input(ui, "nope")
		sc.field_error(ui, "Enter a valid address.")
	})

	add_case("field-group", proc(ui: ^p.Ctx) {
		sc.field_group_open(ui)
		defer p.end(ui)

		sc.field_open(ui)
		sc.field_label(ui, "Name")
		sc.input(ui, "", "Ada")
		sc.field_end(ui)

		sc.field_separator(ui, "or")

		sc.field_open(ui)
		sc.field_label(ui, "Email")
		sc.input(ui, "", "ada@example.com")
		sc.field_end(ui)
	})

	add_case("field-set", proc(ui: ^p.Ctx) {
		// A rendered <legend> is not a flex item: Chromium puts it above the
		// fieldset's anonymous content box, so the gap-4 never applies to it.
		// Its own mb-1.5 and the description's -mt-1.5 then cancel out.
		p.div(ui, "flex-col w-full")
		defer p.end(ui)

		p.text(ui, "Address", sc.FIELD_LEGEND_CLASS + " self-start")
		sc.field_description(ui, "Where should we ship it?")

		sc.field_group_open(ui)
		p.style(ui).margin[p.TOP] = 16
		defer p.end(ui)

		sc.field_open(ui)
		sc.field_label(ui, "City")
		sc.input(ui, "", "Paris")
		sc.field_end(ui)
	})
}
