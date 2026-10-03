package main

import p "palmy:."
import sc "shadcn:."

@(init)
register_avatar_cases :: proc "contextless" () {
	add_case("avatar-default", proc(ui: ^p.Ctx) {sc.avatar(ui, "CN")})
	add_case("avatar-sm", proc(ui: ^p.Ctx) {sc.avatar(ui, "AB", .SM)})
	add_case("avatar-lg", proc(ui: ^p.Ctx) {sc.avatar(ui, "XY", .LG)})
	add_case("avatar-badge", proc(ui: ^p.Ctx) {
		sc.avatar_open(ui)
		sc.avatar_fallback(ui, "CN")
		sc.avatar_badge(ui)
		sc.avatar_end(ui)
	})
	// `-space-x-2` is a negative left margin on every avatar but the first.
	add_case("avatar-group", proc(ui: ^p.Ctx) {
		sc.avatar_group_open(ui)
		sc.avatar(ui, "CN", .Default, true)
		sc.avatar(ui, "AB", .Default, true, "ml-[-8]")
		sc.avatar(ui, "XY", .Default, true, "ml-[-8]")
		sc.avatar_group_count(ui, "+3", "ml-[-8]")
		sc.avatar_group_end(ui)
	})
}
