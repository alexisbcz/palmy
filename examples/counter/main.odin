package main

import "core:fmt"
import "core:os"
import p "../../palmy"

main :: proc() {
	app, err := p.create({title = "palmy · counter", width = 460, height = 340})
	if err != "" {
		fmt.eprintfln("palmy: %s", err)
		os.exit(1)
	}
	defer p.destroy(app)

	count := 0
	step := 1

	for ui in p.frames(app) {
		// A centred page.
		p.div(ui, "flex-col items-center justify-center gap-7 w-full h-full bg-gradient-to-b from-slate-950 to-slate-900")
		defer p.end(ui)

		p.text(ui, "COUNTER", "text-xs font-bold tracking-widest text-slate-500")

		// The card.
		p.div(ui, "flex-col items-center gap-5 w-72 px-10 py-8 rounded-2xl bg-slate-900 border border-slate-800 shadow-xl")
		{
			defer p.end(ui)

			p.textf(ui, "text-6xl font-bold text-white tracking-tight", "%d", count)

			p.row(ui, "gap-3")
			{
				defer p.end(ui)
				if p.button(ui, "−", "size-11 px-0 text-lg") {
					count -= step
				}
				if p.button(
					ui,
					"+",
					"size-11 px-0 text-lg bg-indigo-500 hover:bg-indigo-400 active:bg-indigo-600 border-indigo-400 text-white",
				) {
					count += step
				}
			}

			p.row(ui, "items-center gap-3 w-full")
			{
				defer p.end(ui)
				p.textf(ui, "text-xs text-slate-400 w-14", "step %d", step)
				v := f32(step)
				if p.slider(ui, &v, 1, 10) {
					step = int(v + 0.5)
				}
			}
		}

		if p.button(ui, "Reset", "bg-transparent border-transparent text-slate-500 hover:text-slate-200") {
			count = 0
		}
	}
}
