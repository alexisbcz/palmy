// clipdemo: the smallest palmy program that copies and pastes, for testing
// the web backend's clipboard both ways (palmy/web/demo/scenarios/clip.json).
// The shadcn showcase's text_field pastes but never copies; text_area does
// both through palmy.clipboard_set / clipboard_get.
package main

import "core:fmt"
import "core:os"
import p "palmy:."

ROOT :: "w-full h-full flex-col gap-4 p-6 bg-slate-950 text-slate-200"

main :: proc() {
	app, err := p.create({title = "palmy web · clipboard", width = 640, height = 360, root_class = ROOT})
	if err != "" {
		fmt.eprintfln("clipdemo: %s", err)
		os.exit(1)
	}
	defer p.destroy(app)
	buf: [dynamic]u8
	defer delete(buf)
	for ui in p.frames(app) {
		build(ui, &buf)
	}
}

build :: proc(ui: ^p.Ctx, buf: ^[dynamic]u8) {
	p.text(ui, "Clipboard", "text-xl font-bold")
	p.text(ui, "Shift+Home selects to the start of the line; Ctrl+C copies, Ctrl+V pastes.", "text-sm text-slate-400")
	p.text_area(ui, buf, "Type here", "h-40")
	p.textf(ui, "text-xs text-slate-500", "%d bytes", len(buf))
}
