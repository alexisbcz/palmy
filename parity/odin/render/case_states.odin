package main

// Interaction states, captured from the browser by harness/interact.mjs and
// reproduced here. The id suffix after `@` is the state the browser was put in.

import p "palmy:."
import sc "shadcn:."

@(init)
register_state_cases :: proc "contextless" () {
	H :: sc.State{hover = true}
	F :: sc.State{focus = true}

	add_case("button-default@hover", proc(ui: ^p.Ctx) {sc.button(ui, "Button", .Default, .Default, sc.State{hover = true})})
	add_case("button-default@focus", proc(ui: ^p.Ctx) {sc.button(ui, "Button", .Default, .Default, sc.State{focus = true})})
	add_case("button-secondary@hover", proc(ui: ^p.Ctx) {sc.button(ui, "Button", .Secondary, .Default, sc.State{hover = true})})
	add_case("button-outline@hover", proc(ui: ^p.Ctx) {sc.button(ui, "Button", .Outline, .Default, sc.State{hover = true})})
	add_case("button-destructive@hover", proc(ui: ^p.Ctx) {sc.button(ui, "Button", .Destructive, .Default, sc.State{hover = true})})
	add_case("button-ghost@hover", proc(ui: ^p.Ctx) {sc.button(ui, "Button", .Ghost, .Default, sc.State{hover = true})})

	// Checkbox and switch states, captured by harness/interact.mjs.
	add_case("checkbox-default@hover", proc(ui: ^p.Ctx) {sc.checkbox(ui, .Off, sc.State{hover = true})})
	add_case("checkbox-default@focus", proc(ui: ^p.Ctx) {sc.checkbox(ui, .Off, sc.State{focus = true})})
	add_case("switch-off@hover", proc(ui: ^p.Ctx) {sc.switch_(ui, false, .Default, sc.State{hover = true})})
	add_case("switch-off@focus", proc(ui: ^p.Ctx) {sc.switch_(ui, false, .Default, sc.State{focus = true})})

	add_case("input-default@focus", proc(ui: ^p.Ctx) {sc.input(ui, "Ada Lovelace", "", sc.State{focus = true})})
	add_case("input-placeholder@focus", proc(ui: ^p.Ctx) {sc.input(ui, "", "Email address", sc.State{focus = true})})
	add_case("input-placeholder@typed", proc(ui: ^p.Ctx) {sc.input(ui, "Hello", "", sc.State{focus = true})})
}
