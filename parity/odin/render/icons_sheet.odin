package main

// `render --icons <out.png>` draws every generated icon at several sizes, so
// the path parser and stroker can be eyeballed independently of any component.

import "core:fmt"
import p "palmy:."
import sc "shadcn:."

ALL_ICONS := [?]p.Icon {
	sc.ICON_ARROW_DOWN,
	sc.ICON_CHECK,
	sc.ICON_CHEVRON_DOWN,
	sc.ICON_CHEVRON_LEFT,
	sc.ICON_CHEVRON_RIGHT,
	sc.ICON_CHEVRON_UP,
	sc.ICON_CIRCLE_CHECK,
	sc.ICON_INFO,
	sc.ICON_LOADER_CIRCLE,
	sc.ICON_MINUS,
	sc.ICON_ELLIPSIS,
	sc.ICON_OCTAGON_X,
	sc.ICON_PANEL_LEFT,
	sc.ICON_SEARCH,
	sc.ICON_TRIANGLE_ALERT,
	sc.ICON_X,
}

// The body lives in its own procedure so that every `defer end` fires before
// the frame is finished, not after it.
@(private)
draw_icon_sheet :: proc(ui: ^p.Ctx) {
	p.col(ui, "w-full h-full p-6 gap-5 bg-white")
	defer p.end(ui)

	p.text(ui, "lucide paths, parsed and stroked by palmy", "text-sm font-semibold text-slate-900")

	p.row(ui, "flex-wrap gap-6")
	defer p.end(ui)

	for ic in ALL_ICONS {
		p.key(ui, ic.name)
		p.col(ui, "items-center gap-2 w-24 shrink-0")
		defer p.end(ui)

		p.row(ui, "items-end justify-center gap-2 h-12 w-full")
		p.icon(ui, ic, "size-4 text-slate-900")
		p.icon(ui, ic, "size-6 text-slate-900")
		p.icon(ui, ic, "size-10 text-slate-900")
		p.end(ui)

		p.text(ui, ic.name, "text-[10] text-slate-500 text-center w-full")
	}
}

icon_sheet :: proc(out: string) {
	off := p.offscreen_create(880, 520, 1, "w-full h-full bg-white")
	defer p.offscreen_destroy(off)
	pin_fonts(&off.fonts)

	for _ in 0 ..< 2 {
		draw_icon_sheet(p.offscreen_begin(off))
		p.offscreen_end(off)
	}

	if p.offscreen_write_png(off, out) {
		fmt.printfln("wrote %s", out)
	}
}
