package main

import p "palmy:."
import sc "shadcn:."

@(init)
register_scroll_area_cases :: proc "contextless" () {
	add_case("scroll-area-default", proc(ui: ^p.Ctx) {
		sc.scroll_area_open(ui, "h-40 w-64")
		p.div(ui, "flex-col gap-2 p-3 text-sm")
		ROWS := [?]string {
			"Row one",
			"Row two",
			"Row three",
			"Row four",
			"Row five",
			"Row six",
			"Row seven",
			"Row eight",
			"Row nine",
			"Row ten",
		}
		for r in ROWS {
			p.div(ui, "")
			p.text(ui, r, "whitespace-nowrap")
			p.end(ui)
		}
		p.end(ui)
		// 158px of viewport over 296px of content.
		sc.scroll_area_end(ui, 83.266)
	})
}
