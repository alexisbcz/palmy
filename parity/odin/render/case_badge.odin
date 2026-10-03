package main

import p "palmy:."
import sc "shadcn:."

@(init)
register_badge_cases :: proc "contextless" () {
	add_case("badge-default", proc(ui: ^p.Ctx) {sc.badge(ui, "Badge")})
	add_case("badge-secondary", proc(ui: ^p.Ctx) {sc.badge(ui, "Badge", .Secondary)})
	add_case("badge-destructive", proc(ui: ^p.Ctx) {sc.badge(ui, "Badge", .Destructive)})
	add_case("badge-outline", proc(ui: ^p.Ctx) {sc.badge(ui, "Badge", .Outline)})
	add_case("badge-ghost", proc(ui: ^p.Ctx) {sc.badge(ui, "Badge", .Ghost)})
	add_case("badge-link", proc(ui: ^p.Ctx) {sc.badge(ui, "Badge", .Link)})
	add_case("badge-icon", proc(ui: ^p.Ctx) {sc.badge_icon(ui, "Verified", sc.ICON_BADGE_CHECK, .Secondary)})
	add_case("badge-notification", proc(ui: ^p.Ctx) {sc.badge_icon(ui, "9", sc.ICON_BELL, .Destructive)})
}
