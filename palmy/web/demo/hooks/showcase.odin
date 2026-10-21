package main

// The replay hook for parity/odin/showcase: what its `main` does before the
// loop, and the body of `for ui in p.frames(app)`, against an Offscreen.
// Keep in step with parity/odin/showcase/main.odin.

import "core:fmt"
import p "palmy:."
import sc "shadcn:."

@(private = "file")
g_st: App_State

Replay_Hook :: struct {
	root_class: string,
	setup:      proc(o: ^p.Offscreen),
	frame:      proc(ui: ^p.Ctx),
}

replay_hook :: proc() -> Replay_Hook {
	return {
		// p.create's default, which the showcase does not override.
		root_class = "w-full h-full bg-slate-950 text-slate-200",
		setup = proc(o: ^p.Offscreen) {
			for pair in ([?]struct {
				file: string,
				wt:   p.Font_Weight,
			}{{"Geist-400.ttf", .Regular}, {"Geist-500.ttf", .Medium}, {"Geist-600.ttf", .Semibold}, {"Geist-700.ttf", .Bold}}) {
				p.load_font(&o.fonts, fmt.tprintf("%s/%s", FONT_DIR, pair.file), .Sans, pair.wt)
			}
			sc.register_shadcn_theme()
			p.set_text_gamma(1.8)
			g_st = App_State{volume = {64}}
		},
		frame = proc(ui: ^p.Ctx) {
			build(ui, &g_st)
		},
	}
}
