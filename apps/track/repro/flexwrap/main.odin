// The reproduction `TODO.md` section T2 describes, as a program, so that the
// issue can carry a `verify:` command that points at it.
//
// T2 says a `flex-wrap` row whose width is constrained only by `max-w` does
// not grow its height when its children wrap, so the second line draws over
// whatever follows — and that **five bare chips do not trigger it** while
// five chips each carrying a Save button do. That is two claims, and the
// second is the kind that rots quietly: the bug gets fixed, or the repro gets
// narrower, and the note stays.
//
// So it is a program rather than a sentence. It builds both cases through
// `p.offscreen_*`, reads the geometry back, and exits:
//
//	0  the bug reproduces in at least one case — T2 is still describing
//	   something real
//	1  neither case overflows — T2 is stale and the tracker should say so
//	2  it could not run the measurement at all
//
// `track` runs this only under `track stale --run`. It is an ordinary Odin
// program in its own package, built separately from the application; nothing
// links it in.
package main

import "core:fmt"
import "core:os"
import p "palmy:."

Measured :: struct {
	row_h:    f32,
	needed:   f32,
	next_y:   f32,
	overflow: bool,
}

// measure builds the row, lays it out, and reads the rectangles back. Three
// frames because wrapping settles against the width measured on the frame
// before, and geometry is read after `offscreen_end`, which is when the tree
// has actually been arranged.
measure :: proc(with_button: bool, png: string) -> Measured {
	off := p.offscreen_create(520, 420, 1, "w-full h-full flex-col bg-white text-black p-4")
	defer p.offscreen_destroy(off)

	m := Measured{}
	for _ in 0 ..< 3 {
		ui := p.offscreen_begin(off)
		kids: [5]int
		row := p.div(ui, "flex-row flex-wrap gap-2 max-w-[420px] w-full")
		for i in 0 ..< 5 {
			kids[i] = p.div(ui, "flex-row items-center gap-2 px-3 py-2 rounded-md bg-slate-200")
			p.textf(ui, "text-sm", "attachment-%d.pdf", i)
			if with_button {
				p.button(ui, "Save", "text-xs px-2 py-1")
			}
			p.end(ui)
		}
		p.end(ui)
		after := p.text(ui, "FOLLOWING CONTENT", "text-base font-bold bg-amber-300")
		p.offscreen_end(off)

		rr := p.node_rect(ui, row)
		bottom := rr.y
		for k in kids {
			kr := p.node_rect(ui, k)
			if kr.y + kr.h > bottom {
				bottom = kr.y + kr.h
			}
		}
		ar := p.node_rect(ui, after)
		m = Measured {
			row_h    = rr.h,
			needed   = bottom - rr.y,
			next_y   = ar.y,
			// Half a pixel of slack: this is a layout bug, not a rounding
			// one, and the broken case was tens of pixels short.
			overflow = bottom > rr.y + rr.h + 0.5,
		}
	}
	if png != "" {
		p.offscreen_write_png(off, png)
	}
	return m
}

main :: proc() {
	png_dir := len(os.args) > 1 ? os.args[1] : ""
	shot :: proc(dir, name: string) -> string {
		return dir == "" ? "" : fmt.tprintf("%s/%s", dir, name)
	}

	bare := measure(false, shot(png_dir, "wrap-bare-chips.png"))
	btn := measure(true, shot(png_dir, "wrap-chips-with-button.png"))

	fmt.printfln(
		"five bare chips            row height %.1f, lines need %.1f, next element at %.1f  -> overflow %v",
		bare.row_h,
		bare.needed,
		bare.next_y,
		bare.overflow,
	)
	fmt.printfln(
		"five chips with a button   row height %.1f, lines need %.1f, next element at %.1f  -> overflow %v",
		btn.row_h,
		btn.needed,
		btn.next_y,
		btn.overflow,
	)

	if bare.row_h <= 0 || btn.row_h <= 0 {
		fmt.eprintln("the measurement did not run: the row has no height at all")
		os.exit(2)
	}
	if bare.overflow || btn.overflow {
		fmt.println("T2 still reproduces")
		os.exit(0)
	}
	fmt.println(
		"T2 does not reproduce: in both cases the row's height covers every line it laid out",
	)
	os.exit(1)
}
