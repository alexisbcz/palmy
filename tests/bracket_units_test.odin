// Bracket values with a unit (TODO.md K1).
//
// `max-w-[420px]` is the real Tailwind spelling. It used to fail to parse and
// the whole class vanished without a word: `apps/track`'s typography rendered
// at the inherited size, and a repro written with `[420px]` reported a live
// bug as fixed.
package palmy_tests

import "core:testing"
import p "../palmy"

@(test)
test_bracket_values_take_px_and_percent :: proc(t: ^testing.T) {
	off := p.offscreen_create(800, 400)
	defer p.offscreen_destroy(off)

	ui := p.offscreen_begin(off)
	p.col(ui, "w-full h-full items-start")
	a := p.div(ui, "w-[420px] h-[10px]");p.end(ui)
	b := p.div(ui, "w-[420] h-[10]");p.end(ui)
	c := p.div(ui, "w-[25%] h-[5%]");p.end(ui)
	d := p.div(ui, "w-[3rem] h-[10]");p.end(ui) // refused: no root size
	txt := p.text(ui, "Aa", "text-[11px]")
	txt2 := p.text(ui, "Aa", "text-[11]")
	p.end(ui)
	p.offscreen_end(off)

	ra, rb, rc, rd := p.node_rect(ui, a), p.node_rect(ui, b), p.node_rect(ui, c), p.node_rect(ui, d)
	geom_eq(t, ra.w, 420, "w-[420px] is 420 pixels")
	geom_eq(t, ra.h, 10, "h-[10px] is 10 pixels")
	geom_eq(t, ra.w, rb.w, "the same as the bare number")
	geom_eq(t, rc.w, 200, "w-[25%] is a quarter of the parent")
	geom_eq(t, rc.h, 20, "h-[5%] is a twentieth of it")
	geom_eq(t, rd.w, 0, "w-[3rem] is dropped (and reported), not guessed")
	testing.expect_value(t, p.node_style(ui, txt).font_size, 11)
	testing.expect_value(t, p.node_style(ui, txt2).font_size, 11)
}
