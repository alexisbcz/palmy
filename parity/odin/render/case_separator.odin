package main

import p "palmy:."
import sc "shadcn:."

// The capture puts both separators on a half pixel (`cropOffset` 0.5), and
// Chromium snaps a hairline's background box to the device pixel grid, rounding
// .5 up. palmy antialiases instead, so the extra half pixel here is the snap the
// browser performs; without it the line is split 50/50 across two rows.
@(init)
register_separator_cases :: proc "contextless" () {
	add_case("separator-horizontal", proc(ui: ^p.Ctx) {sc.separator(ui, .Horizontal, "w-64 mt-[0.5]")})
	add_case("separator-vertical", proc(ui: ^p.Ctx) {sc.separator(ui, .Vertical, "h-16 ml-[0.5]")})
}
