package main

import p "palmy:."
import sc "shadcn:."

@(init)
register_input_otp_cases :: proc "contextless" () {
	add_case("input-otp-default", proc(ui: ^p.Ctx) {
		sc.input_otp_open(ui)
		defer sc.input_otp_end(ui)
		sc.input_otp_group(ui, {"1", "2", "3", "4", "5", "6"})
	})

	add_case("input-otp-separator", proc(ui: ^p.Ctx) {
		sc.input_otp_open(ui)
		defer sc.input_otp_end(ui)
		sc.input_otp_group(ui, {"1", "2", "3"})
		sc.input_otp_separator(ui)
		sc.input_otp_group(ui, {"4", "", ""})
	})
}
