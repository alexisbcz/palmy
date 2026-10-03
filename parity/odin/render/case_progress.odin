package main

import p "palmy:."
import sc "shadcn:."

@(init)
register_progress_cases :: proc "contextless" () {
	add_case("progress-default", proc(ui: ^p.Ctx) {
		sc.progress_open(ui, "w-72")
		sc.progress_track(ui, 60)
		sc.progress_end(ui)
	})
	add_case("progress-label", proc(ui: ^p.Ctx) {
		sc.progress_open(ui, "w-72")
		sc.progress_header(ui, "Uploading", "35%")
		sc.progress_track(ui, 35)
		sc.progress_end(ui)
	})
}
