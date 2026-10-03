package main

import p "palmy:."
import sc "shadcn:."

@(init)
register_popover_cases :: proc "contextless" () {
	add_case("popover-default", proc(ui: ^p.Ctx) {
		sc.popover_content_open(ui)
		p.text(ui, "Dimensions are applied on save.", "whitespace-nowrap")
		p.end(ui)
	})

	add_case("popover-header", proc(ui: ^p.Ctx) {
		sc.popover_content_open(ui)
		defer p.end(ui)

		sc.popover_header_open(ui)
		sc.popover_title(ui, "Dimensions")
		sc.popover_description(ui, "Set the width and height.")
		p.end(ui)

		// The popover takes focus when it opens, so the field is ringed.
		sc.input(ui, "", "Width", sc.State{focus = true})
	})
}

@(init)
register_tooltip_cases :: proc "contextless" () {
	// The arrow is a 10px square rotated 45 degrees, the same colour as the
	// panel, centred under it: inside the captured box it is covered by the
	// panel's own background, and the part that sticks out is clipped away by
	// the element screenshot. Nothing to draw.
	add_case("tooltip-default", proc(ui: ^p.Ctx) {
		sc.tooltip_content_open(ui)
		p.text(ui, "Add to library", "whitespace-nowrap")
		p.style(ui).shrink = 0
		p.end(ui)
	})

	add_case("tooltip-kbd", proc(ui: ^p.Ctx) {
		idx := sc.tooltip_content_open(ui)
		// `has-data-[slot=kbd]:pr-1.5`.
		p.apply(ui, "pr-1.5", idx)
		p.text(ui, "Save", "whitespace-nowrap")
		p.style(ui).shrink = 0
		sc.tooltip_kbd(ui, "S")
		p.end(ui)
	})
}

@(init)
register_hover_card_cases :: proc "contextless" () {
	add_case("hover-card-open", proc(ui: ^p.Ctx) {
		sc.hover_card_content_open(ui)
		defer p.end(ui)

		p.row(ui, "gap-2")
		defer p.end(ui)

		sc.avatar_fallback_sm(ui, "AL")

		p.col(ui, "text-sm")
		p.text(ui, "Ada Lovelace", "font-medium whitespace-nowrap")
		p.text(ui, "First programmer.", "text-muted-foreground whitespace-nowrap")
		p.end(ui)
	})
}
