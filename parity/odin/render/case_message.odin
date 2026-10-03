package main

import p "palmy:."
import sc "shadcn:."

@(init)
register_message_cases :: proc "contextless" () {
	add_case("message-start", proc(ui: ^p.Ctx) {
		root := sc.message_open(ui, false, "w-80")
		pixel_snap(ui, root, 0.625)
		p.style(ui, root).h = p.px(66.75)
		defer sc.message_end(ui)

		sc.message_avatar(ui, "AL", 0.75)
		sc.message_content_open(ui)
		sc.message_caption(ui, "Ada")
		sc.bubble_open(ui, false)
		i := sc.bubble_content(ui, "Patch looks good.", .Muted)
		p.style(ui, i).h = p.px(snapped_h(0.625, 40.75))
		sc.bubble_end(ui)
		sc.message_content_end(ui)
	})
	add_case("message-end", proc(ui: ^p.Ctx) {
		root := sc.message_open(ui, true, "w-80")
		pixel_snap(ui, root, 0.625)
		p.style(ui, root).h = p.px(66.75)
		defer sc.message_end(ui)

		sc.message_content_open(ui)
		sc.bubble_open(ui, true)
		i := sc.bubble_content(ui, "Thanks, merging now.", .Default, true)
		p.style(ui, i).h = p.px(snapped_h(0.625, 40.75))
		sc.bubble_end(ui)
		sc.message_caption(ui, "Sent", true)
		sc.message_content_end(ui)
	})
}
