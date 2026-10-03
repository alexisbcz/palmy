package main

import p "palmy:."
import sc "shadcn:."

@(init)
register_skeleton_cases :: proc "contextless" () {
	add_case("skeleton-default", proc(ui: ^p.Ctx) {sc.skeleton(ui, "h-4 w-64")})
	add_case("skeleton-circle", proc(ui: ^p.Ctx) {sc.skeleton(ui, "size-10 rounded-full")})
}
