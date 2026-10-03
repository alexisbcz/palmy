package main

import p "palmy:."
import sc "shadcn:."

tabs_case :: proc(ui: ^p.Ctx, v: sc.Tabs_Variant, vertical: bool) {
	sc.tabs_open(ui, vertical)
	sc.tabs_list_open(ui, v, vertical)
	sc.tabs_trigger(ui, "Account", true, v, vertical)
	sc.tabs_trigger(ui, "Password", false, v, vertical)
	sc.tabs_list_close(ui)
	sc.tabs_content(ui, "Account settings.")
	sc.tabs_close(ui)
}

@(init)
register_tabs_cases :: proc "contextless" () {
	add_case("tabs-default", proc(ui: ^p.Ctx) {tabs_case(ui, .Default, false)})
	add_case("tabs-line", proc(ui: ^p.Ctx) {tabs_case(ui, .Line, false)})
	add_case("tabs-vertical", proc(ui: ^p.Ctx) {tabs_case(ui, .Default, true)})
}
