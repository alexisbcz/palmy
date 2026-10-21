package main

// The replay hook for palmy/web/demo/clipdemo.

import p "palmy:."

@(private = "file")
g_buf: [dynamic]u8

Replay_Hook :: struct {
	root_class: string,
	setup:      proc(o: ^p.Offscreen),
	frame:      proc(ui: ^p.Ctx),
}

replay_hook :: proc() -> Replay_Hook {
	return {root_class = ROOT, setup = proc(o: ^p.Offscreen) {}, frame = proc(ui: ^p.Ctx) {build(ui, &g_buf)}}
}
