package main

import p "palmy:."
import sc "shadcn:."

@(init)
register_message_scroller_cases :: proc "contextless" () {
	add_case("message-scroller-default", proc(ui: ^p.Ctx) {
		sc.message_scroller(ui, {"First message", "Second message", "Third message"}, "h-48 w-80")
	})
}
