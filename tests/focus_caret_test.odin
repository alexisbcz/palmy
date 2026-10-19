// Keyboard focus and where it leaves the caret.
//
// Tabbing into a prefilled field and typing must append, not prepend. The
// installer's "Computer name" field holds `palmy`; tabbing into it and
// typing `analytical` gave `analyticalpalmy`, because a field that had
// never been clicked kept its caret at 0.
package palmy_tests

import "core:testing"
import p "../palmy"

@(test)
test_tab_into_a_prefilled_field_puts_the_caret_at_the_end :: proc(t: ^testing.T) {
	off := p.offscreen_create(400, 160)
	defer p.offscreen_destroy(off)

	first: [dynamic]u8
	second: [dynamic]u8
	notes: [dynamic]u8
	defer delete(first)
	defer delete(second)
	defer delete(notes)
	append(&second, "palmy")
	append(&notes, "line one")

	draw :: proc(off: ^p.Offscreen, a, b, c: ^[dynamic]u8) {
		ui := p.offscreen_begin(off)
		p.col(ui, "w-full h-full p-2 gap-2")
		p.text_field(ui, a, "", "w-full")
		p.text_field(ui, b, "", "w-full")
		p.text_area(ui, c, "", "w-full h-[60]")
		p.end(ui)
		p.offscreen_end(off)
	}

	draw(off, &first, &second, &notes)
	draw(off, &first, &second, &notes)

	// Tab, Tab: the second field.
	p.press_key(off, p.KEY_TAB)
	draw(off, &first, &second, &notes)
	p.press_key(off, p.KEY_TAB)
	draw(off, &first, &second, &notes)
	p.type_text(off, "-01")
	draw(off, &first, &second, &notes)
	testing.expect_value(t, string(second[:]), "palmy-01")
	testing.expect_value(t, string(first[:]), "")

	// Tab again: the multi-line field, also at its end.
	p.press_key(off, p.KEY_TAB)
	draw(off, &first, &second, &notes)
	p.type_text(off, ", two")
	draw(off, &first, &second, &notes)
	testing.expect_value(t, string(notes[:]), "line one, two")

	// Moving the caret by hand still works after a Tab in.
	p.press_key(off, p.KEY_HOME)
	draw(off, &first, &second, &notes)
	p.type_text(off, ">")
	draw(off, &first, &second, &notes)
	testing.expect_value(t, string(notes[:]), ">line one, two")
}
