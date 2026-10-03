package main

import p "palmy:."
import sc "shadcn:."

// Both radio cases render the same pixels: `disabled` on the RadioGroup does
// not reach the Field, so nothing in the captured styles changes.
radio_group_case :: proc(ui: ^p.Ctx) {
	sc.radio_group_open(ui)
	defer sc.radio_group_end(ui)

	items := [?]struct {
		text:    string,
		checked: bool,
	}{{"Free", false}, {"Pro", true}}

	for it in items {
		p.key(ui, it.text)
		p.row(ui, "w-full gap-2 items-center")
		sc.radio(ui, it.checked)
		sc.label(ui, it.text, "leading-[19.25] flex-auto")
		p.end(ui)
	}
}

@(init)
register_radio_group_cases :: proc "contextless" () {
	add_case("radio-group-default", radio_group_case)
	add_case("radio-group-disabled", radio_group_case)
}
