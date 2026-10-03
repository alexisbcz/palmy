package main

import p "palmy:."
import sc "shadcn:."

@(init)
register_button_cases :: proc "contextless" () {
	add_case("button-default", proc(ui: ^p.Ctx) {sc.button(ui, "Button")})
	add_case("button-secondary", proc(ui: ^p.Ctx) {sc.button(ui, "Button", .Secondary)})
	add_case("button-destructive", proc(ui: ^p.Ctx) {sc.button(ui, "Button", .Destructive)})
	add_case("button-outline", proc(ui: ^p.Ctx) {sc.button(ui, "Button", .Outline)})
	add_case("button-ghost", proc(ui: ^p.Ctx) {sc.button(ui, "Button", .Ghost)})
	add_case("button-link", proc(ui: ^p.Ctx) {sc.button(ui, "Button", .Link)})
	add_case("button-xs", proc(ui: ^p.Ctx) {sc.button(ui, "Button", .Default, .XS)})
	add_case("button-sm", proc(ui: ^p.Ctx) {sc.button(ui, "Button", .Default, .SM)})
	add_case("button-lg", proc(ui: ^p.Ctx) {sc.button(ui, "Button", .Default, .LG)})
	add_case("button-disabled", proc(ui: ^p.Ctx) {
		sc.button(ui, "Button", .Default, .Default, sc.State{disabled = true})
	})
	// `size="icon" variant="outline"` with a plus glyph.
	add_case("button-icon", proc(ui: ^p.Ctx) {
		sc.button_open(ui, .Outline, .Icon, sc.State{})
		p.icon(ui, sc.ICON_PLUS, "size-4")
		sc.button_end(ui)
	})
	add_case("button-icon-sm", proc(ui: ^p.Ctx) {
		sc.button_open(ui, .Ghost, .Icon_SM, sc.State{})
		p.icon(ui, sc.ICON_SETTINGS, "size-4")
		sc.button_end(ui)
	})
	// `has-data-[icon=inline-start]:pl-2` — a leading icon tightens the left
	// padding from 10px to 8px.
	add_case("button-with-icon", proc(ui: ^p.Ctx) {
		sc.button_open(ui, .Default, .Default, sc.State{})
		p.apply(ui, "pl-2")
		p.icon(ui, sc.ICON_SEND, "size-4")
		p.text(ui, "Send", "whitespace-nowrap")
		p.style(ui).shrink = 0
		sc.button_end(ui)
	})
}
