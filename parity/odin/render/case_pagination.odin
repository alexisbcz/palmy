package main

import p "palmy:."
import sc "shadcn:."

@(init)
register_pagination_cases :: proc "contextless" () {
	add_case("pagination-default", proc(ui: ^p.Ctx) {
		sc.pagination_open(ui)
		sc.pagination_previous(ui)
		sc.pagination_link(ui, "1")
		sc.pagination_link(ui, "2", true)
		sc.pagination_link(ui, "3")
		sc.pagination_ellipsis(ui)
		sc.pagination_next(ui)
		sc.pagination_close(ui)
	})
}
