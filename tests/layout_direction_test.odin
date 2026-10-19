// Layout direction: `flex-row-reverse`, `flex-col-reverse` and `dir-rtl`.
//
// The installer and the greeter mirrored their rows for Arabic by hand,
// building every row twice in opposite orders. These are what replaces that.
package palmy_tests

import "core:testing"
import p "../palmy"

@(private)
three_in_a_row :: proc(t: ^testing.T, class: string) -> (a, b, c: p.Rect, row: p.Rect) {
	off := p.offscreen_create(400, 100)
	defer p.offscreen_destroy(off)
	ui := p.offscreen_begin(off)
	r := p.row(ui, class)
	ia := p.div(ui, "w-[40] h-[10]");p.end(ui)
	ib := p.div(ui, "w-[60] h-[10] ml-[8]");p.end(ui)
	ic := p.div(ui, "w-[20] h-[10]");p.end(ui)
	p.end(ui)
	p.offscreen_end(off)
	return p.node_rect(ui, ia), p.node_rect(ui, ib), p.node_rect(ui, ic), p.node_rect(ui, r)
}

@(test)
test_flex_row_reverse_starts_at_the_right :: proc(t: ^testing.T) {
	a, b, c, row := three_in_a_row(t, "w-full p-2 gap-4 flex-row-reverse")
	right := row.x + row.w - 8
	geom_eq(t, a.x + a.w, right, "the first child ends at the right padding edge")
	geom_eq(t, b.x + b.w, a.x - 16 - 8, "the second sits left of it, after the gap and its margin")
	geom_eq(t, c.x + c.w, b.x - 16, "the third left of that")

	// justify-start packs against the start, which is now the right.
	a2, _, c2, row2 := three_in_a_row(t, "w-full gap-4 flex-row-reverse justify-end")
	geom_eq(t, c2.x, row2.x, "justify-end packs against the left")
	testing.expect(t, a2.x > c2.x, "and the order is still reversed")
}

@(test)
test_dir_rtl_mirrors_a_row_and_a_column :: proc(t: ^testing.T) {
	a, _, c, row := three_in_a_row(t, "w-full gap-4 dir-rtl")
	geom_eq(t, a.x + a.w, row.x + row.w, "dir-rtl: the first child at the right")
	testing.expect(t, c.x < a.x, "dir-rtl: the last child to its left")

	// Two mirrors cancel, as in CSS: row-reverse inside rtl runs left to right.
	a2, _, c2, row2 := three_in_a_row(t, "w-full gap-4 dir-rtl flex-row-reverse")
	geom_eq(t, a2.x, row2.x, "rtl + reverse: the first child at the left")
	testing.expect(t, c2.x > a2.x, "rtl + reverse: the last child to its right")

	// A column's cross axis: items-start sits at the right under dir-rtl, and
	// the direction is inherited by a nested row.
	off := p.offscreen_create(400, 200)
	defer p.offscreen_destroy(off)
	ui := p.offscreen_begin(off)
	col := p.col(ui, "w-full h-full items-start dir-rtl")
	box := p.div(ui, "w-[50] h-[10]");p.end(ui)
	inner := p.row(ui, "w-full gap-2")
	first := p.div(ui, "w-[30] h-[10]");p.end(ui)
	second := p.div(ui, "w-[30] h-[10]");p.end(ui)
	p.end(ui)
	p.end(ui)
	p.offscreen_end(off)
	rc := p.node_rect(ui, col)
	geom_eq(t, p.node_rect(ui, box).x + 50, rc.x + rc.w, "items-start under dir-rtl is the right edge")
	rf, rs := p.node_rect(ui, first), p.node_rect(ui, second)
	geom_eq(t, rf.x + rf.w, rc.x + rc.w, "a nested row inherits the direction")
	geom_eq(t, rs.x + rs.w, rf.x - 8, "and runs right to left")
}

@(test)
test_flex_col_reverse_starts_at_the_bottom :: proc(t: ^testing.T) {
	off := p.offscreen_create(200, 200)
	defer p.offscreen_destroy(off)
	ui := p.offscreen_begin(off)
	col := p.col(ui, "w-full h-full gap-2 flex-col-reverse")
	a := p.div(ui, "w-[10] h-[20]");p.end(ui)
	b := p.div(ui, "w-[10] h-[30]");p.end(ui)
	p.end(ui)
	p.offscreen_end(off)
	rc, ra, rb := p.node_rect(ui, col), p.node_rect(ui, a), p.node_rect(ui, b)
	geom_eq(t, ra.y + ra.h, rc.y + rc.h, "the first child at the bottom")
	geom_eq(t, rb.y + rb.h, ra.y - 8, "the second above it")
	geom_eq(t, ra.x, rc.x, "the cross axis is not mirrored")
}

// `dir-rtl` sets the base direction of text, so `text-start` -- the default
// -- puts a Latin line at the right, and a `dir-ltr` puts Arabic at the left.
@(test)
test_dir_sets_the_base_direction_of_text :: proc(t: ^testing.T) {
	off := p.offscreen_create(400, 100)
	defer p.offscreen_destroy(off)
	ui := p.offscreen_begin(off)
	p.col(ui, "w-full h-full")
	latin := p.text(ui, "Hello", "w-full dir-rtl")
	arabic := p.text(ui, "مرحبا", "w-full dir-ltr")
	plain := p.text(ui, "مرحبا", "w-full")
	p.end(ui)
	p.offscreen_end(off)

	ll := p.node_lines(ui, latin)
	la := p.node_lines(ui, arabic)
	lp := p.node_lines(ui, plain)
	testing.expect(t, len(ll) == 1 && ll[0].dir == .RTL, "dir-rtl makes a Latin line right to left")
	testing.expect(t, len(la) == 1 && la[0].dir == .LTR, "dir-ltr makes an Arabic line left to right")
	testing.expect(t, len(lp) == 1 && lp[0].dir == .RTL, "with no dir the text decides, as before")
}

// A text field inside dir-rtl keeps its text and caret together: the field
// positions both itself and must not be mirrored as a row.
@(test)
test_a_text_field_under_dir_rtl_keeps_text_and_caret_together :: proc(t: ^testing.T) {
	off := p.offscreen_create(300, 80)
	defer p.offscreen_destroy(off)
	buf: [dynamic]u8
	defer delete(buf)
	append(&buf, "abc")

	ui: ^p.Ctx
	field: int
	for _ in 0 ..< 2 {
		ui = p.offscreen_begin(off)
		p.col(ui, "w-full h-full p-2 dir-rtl")
		field = p.node_count(ui)
		p.text_field(ui, &buf, "", "w-full")
		p.end(ui)
		p.offscreen_end(off)
	}
	rf := p.node_rect(ui, field)
	txt := field + 1
	testing.expect_value(t, p.node_kind(ui, txt), p.Node_Kind.Text)
	rt := p.node_rect(ui, txt)
	testing.expectf(t, rt.x < rf.x + 20, "the text stays at the field's left edge where its caret is computed, at %.1f in %.1f", rt.x, rf.x)
}
