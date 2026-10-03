package main

import p "palmy:."
import sc "shadcn:."

@(init)
register_alert_cases :: proc "contextless" () {
	add_case("alert-default", proc(ui: ^p.Ctx) {
		sc.alert_open(ui, .Default, false, false, "w-96")
		sc.alert_title(ui, "Heads up")
		sc.alert_description(ui, "The build finished in 12 seconds.")
		sc.alert_end(ui)
	})
	add_case("alert-destructive", proc(ui: ^p.Ctx) {
		sc.alert_open(ui, .Destructive, true, false, "w-96")
		sc.alert_icon(ui, sc.ICON_CIRCLE_ALERT)
		sc.alert_body_open(ui, true)
		sc.alert_title(ui, "Build failed")
		sc.alert_description(ui, "Two tests did not pass.", .Destructive)
		sc.alert_body_end(ui, true)
		sc.alert_end(ui)
	})
	add_case("alert-with-icon", proc(ui: ^p.Ctx) {
		sc.alert_open(ui, .Default, true, true, "w-96")
		sc.alert_icon(ui, sc.ICON_INFO)
		sc.alert_body_open(ui, true)
		sc.alert_title(ui, "New version")
		sc.alert_description(ui, "Version 2.1 is available.")
		sc.alert_body_end(ui, true)
		sc.alert_action_open(ui)
		sc.button(ui, "Update", .Outline, .XS)
		sc.alert_action_end(ui)
		sc.alert_end(ui)
	})
}
