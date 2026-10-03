package main

import "core:fmt"
import "core:os"
import p "../../palmy"

main :: proc() {
	// `palmy render <file.png>` draws one frame without a compositor, which is
	// how the screenshots in the README are made.
	if len(os.args) > 2 && os.args[1] == "render" {
		tab := 0
		if len(os.args) > 3 {
			tab = int(os.args[3][0] - '0')
		}
		render_to(os.args[2], tab)
		return
	}

	app, err := p.create({title = "palmy · gallery", width = 1100, height = 740, min_width = 720, min_height = 480})
	if err != "" {
		fmt.eprintfln("palmy: %s", err)
		os.exit(1)
	}
	defer p.destroy(app)

	st := State {
		volume  = 64,
		density = 0.35,
		notify  = true,
	}
	defer delete(st.name)

	for ui in p.frames(app) {
		build(ui, &st)
		if p.shortcut(ui, 'q', {.Ctrl}) || p.key_pressed(ui, p.KEY_ESCAPE) {
			p.quit_app(app)
		}
	}
}

render_to :: proc(path: string, tab: int) {
	off := p.offscreen_create(1100, 740)
	defer p.offscreen_destroy(off)

	st := State {
		volume  = 64,
		density = 0.35,
		notify  = true,
		tab     = tab,
	}
	defer delete(st.name)

	// Two frames: the first settles the layout, the second paints it.
	for _ in 0 ..< 2 {
		build(p.offscreen_begin(off), &st)
		p.offscreen_end(off)
	}
	if p.offscreen_write_png(off, path) {
		fmt.printfln("wrote %s", path)
	} else {
		fmt.eprintfln("could not write %s", path)
		os.exit(1)
	}
}
