// dnd-check: one half of a drag between two palmy windows.
//
//	dnd-check source    a chip that starts a drag once the pointer moves 6 px
//	dnd-check target    a window that takes text/plain drops
//
// Each prints what happened on stdout (DRAG_START, DRAG_RESULT, DROPPED) for
// apps/tools/dnd-check.sh, which runs both on a private headless sway and
// drags from one to the other with a virtual pointer.
package dnd_check

import "core:fmt"
import "core:os"
import p "palmy:."

main :: proc() {
	role := len(os.args) > 1 ? os.args[1] : "source"
	app, err := p.create({title = role, app_id = role, width = 480, height = 360})
	if err != "" {
		fmt.eprintln(err)
		os.exit(1)
	}
	defer p.destroy(app)
	got := ""
	pressed_at: Maybe([2]f32)
	for ui in p.frames(app) {
		if role == "source" {
			p.div(ui, "absolute left-[40] top-[40] w-[160] h-[60] rounded-lg bg-sky-600 items-center justify-center cursor-grab")
			p.clickable(ui)
			if p.is_active(ui) && !p.drag_active(ui) {
				m := p.mouse_pos(ui)
				if at, ok := pressed_at.?; !ok {
					pressed_at = m
				} else if abs(m.x - at.x) + abs(m.y - at.y) > 6 {
					ok := p.drag_start(ui, {"text/plain;charset=utf-8"}, {"hello from the source window"})
					fmt.printfln("DRAG_START %v", ok)
				}
			}
			if !p.mouse_down(ui) {
				pressed_at = nil
			}
			p.text(ui, p.drag_active(ui) ? "dragging..." : "drag me", "text-white")
			p.end(ui)
			switch r := p.drag_result(ui); r {
			case .Dropped, .Cancelled:
				fmt.printfln("DRAG_RESULT %v", r)
			case .None:
			}
		} else {
			p.drop_accept(ui, {"text/plain;charset=utf-8"})
			if pos, types, over := p.drag_over(ui); over {
				p.text(ui, fmt.tprintf("a drag is over this window at %v, offering %v", pos, types), "text-amber-300")
			}
			if d, ok := p.dropped(ui); ok {
				delete(got)
				got = fmt.aprintf("dropped: %q at %v", d.data, d.pos)
				fmt.printfln("DROPPED %q %s at %v", d.data, d.mime, d.pos)
			}
			p.text(ui, got == "" ? "drop here" : got, "text-white text-xl")
		}
		os.flush(os.stdout)
	}
}
