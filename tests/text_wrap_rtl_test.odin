// Wrapping, alignment and the text-field caret for text that reorders.
//
// The bugs these cover were all invisible until bidi was wired into the text
// path, because until then nothing reordered and logical order was visual
// order everywhere.
package palmy_tests

import p "../palmy"
import "core:testing"

// Long enough to wrap at the widths used below, and it contains a Latin word
// in the middle on purpose: that word is what used to flip a line's direction,
// because each line was resolved .Auto and a line starting with "HTTP" looks
// left-to-right when you only look at the line.
HEB_PARA :: "שלום עולם זהו טקסט עברי ארוך שנועד להישבר לכמה שורות וגם מכיל HTTP ועוד מילים בעברית כדי להמשיך"
LTR_PARA :: "The quick brown fox jumps over the lazy dog and keeps running well past the edge of the box"

@(private = "file")
shot :: proc(w, h: int) -> ^p.Offscreen {
	return p.offscreen_create(w, h, 1, "w-full h-full bg-black text-white")
}

// ---------------------------------------------------------------------------
// Wrapping
// ---------------------------------------------------------------------------

@(test)
test_wrapped_rtl_paragraph_keeps_one_direction :: proc(t: ^testing.T) {
	off := shot(300, 400)
	defer p.offscreen_destroy(off)

	idx: int
	ui: ^p.Ctx
	for _ in 0 ..< 2 {
		ui = p.offscreen_begin(off)
		p.div(ui, "w-[260]")
		idx = p.text(ui, HEB_PARA)
		p.end(ui)
		p.offscreen_end(off)
	}

	lines := p.node_lines(ui, idx)
	testing.expectf(t, len(lines) >= 3, "expected several lines, got %d", len(lines))
	for l, i in lines {
		testing.expectf(
			t,
			l.dir == .RTL,
			"line %d of a Hebrew paragraph resolved %v, not .RTL -- the line containing a Latin word is the one that flips",
			i,
			l.dir,
		)
	}
}

@(test)
test_wrapped_latin_paragraph_is_ltr :: proc(t: ^testing.T) {
	off := shot(300, 400)
	defer p.offscreen_destroy(off)

	idx: int
	ui: ^p.Ctx
	for _ in 0 ..< 2 {
		ui = p.offscreen_begin(off)
		p.div(ui, "w-[260]")
		idx = p.text(ui, LTR_PARA)
		p.end(ui)
		p.offscreen_end(off)
	}

	lines := p.node_lines(ui, idx)
	testing.expectf(t, len(lines) >= 3, "expected several lines, got %d", len(lines))
	for l, i in lines {
		testing.expectf(t, l.dir == .LTR, "line %d resolved %v, not .LTR", i, l.dir)
	}
}

// The width a line is measured at has to be the width it is drawn at, or
// alignment and truncation are both off. They go through the same `dir`, and
// this is the assertion that says so.
@(test)
test_line_width_matches_its_own_direction :: proc(t: ^testing.T) {
	off := shot(300, 400)
	defer p.offscreen_destroy(off)

	for para in ([]string{HEB_PARA, LTR_PARA, "abc שלום xyz", "العربية والإنجليزية mixed"}) {
		idx: int
		ui: ^p.Ctx
		for _ in 0 ..< 2 {
			ui = p.offscreen_begin(off)
			p.div(ui, "w-[260]")
			idx = p.text(ui, para)
			p.end(ui)
			p.offscreen_end(off)
		}
		st := p.node_style(ui, idx)
		for l, i in p.node_lines(ui, idx) {
			w := p.text_width(
				&off.fonts,
				l.text,
				st.font_size,
				st.family,
				st.weight,
				st.tracking_em * st.font_size,
				st.slant,
				st.tabular,
				l.dir,
			)
			testing.expectf(
				t,
				abs(w - l.width) < 0.01,
				"line %d of %q measured %f when stored as %f",
				i,
				para,
				w,
				l.width,
			)
		}
	}
}

// ---------------------------------------------------------------------------
// Alignment
// ---------------------------------------------------------------------------

// Where the ink actually is, as a fraction across the box. A right-aligned
// line puts its last inked column near the right edge and leaves the left
// margin empty; a left-aligned one does the opposite.
@(private = "file")
ink_bounds :: proc(off: ^p.Offscreen) -> (first: int, last: int, any: bool) {
	first, last = -1, -1
	for y in 0 ..< off.height {
		for x in 0 ..< off.width {
			c := p.offscreen_pixel(off, x, y)
			if c.r > 40 || c.g > 40 || c.b > 40 {
				if first < 0 || x < first {
					first = x
				}
				if x > last {
					last = x
				}
				any = true
			}
		}
	}
	return
}

@(test)
test_rtl_paragraph_aligns_to_the_right_by_default :: proc(t: ^testing.T) {
	// Start is the default alignment and the only one that reads the text: a
	// Hebrew paragraph sits on the right without anything being set.
	off := shot(400, 120)
	defer p.offscreen_destroy(off)
	for _ in 0 ..< 2 {
		ui := p.offscreen_begin(off)
		p.div(ui, "w-full h-full")
		p.text(ui, "שלום עולם")
		p.end(ui)
		p.offscreen_end(off)
	}
	first, last, any := ink_bounds(off)
	testing.expect(t, any, "the Hebrew line put ink on the canvas")
	testing.expectf(t, last > 400 - 40, "right-aligned text should reach the right edge, last ink at %d", last)
	testing.expectf(t, first > 200, "and should leave the left half empty, first ink at %d", first)
}

@(test)
test_ltr_paragraph_still_aligns_left :: proc(t: ^testing.T) {
	off := shot(400, 120)
	defer p.offscreen_destroy(off)
	for _ in 0 ..< 2 {
		ui := p.offscreen_begin(off)
		p.div(ui, "w-full h-full")
		p.text(ui, "hello world")
		p.end(ui)
		p.offscreen_end(off)
	}
	first, last, any := ink_bounds(off)
	testing.expect(t, any, "the Latin line put ink on the canvas")
	testing.expectf(t, first < 40, "left-aligned text starts at the left, first ink at %d", first)
	testing.expectf(t, last < 300, "and does not reach the right edge, last ink at %d", last)
}

@(test)
test_text_left_overrides_the_base_direction :: proc(t: ^testing.T) {
	// An explicit `text-left` means left for everything. Only Start and End
	// consult the direction.
	off := shot(400, 120)
	defer p.offscreen_destroy(off)
	for _ in 0 ..< 2 {
		ui := p.offscreen_begin(off)
		p.div(ui, "w-full h-full")
		p.text(ui, "שלום עולם", "text-left")
		p.end(ui)
		p.offscreen_end(off)
	}
	first, _, any := ink_bounds(off)
	testing.expect(t, any, "ink")
	testing.expectf(t, first < 40, "text-left wins over the RTL base, first ink at %d", first)
}

// ---------------------------------------------------------------------------
// The text-field caret
// ---------------------------------------------------------------------------

// In a right-to-left field the caret at byte 0 sits at the *right* edge, so
// pressing the left arrow moves it left on screen, which means forward through
// the string. Under the old code the left arrow was rune_back and did nothing
// at all at offset 0, which is the bug: the caret could not be moved into the
// text it was sitting in front of.
@(test)
test_rtl_field_left_arrow_moves_into_the_text :: proc(t: ^testing.T) {
	off := shot(360, 80)
	defer p.offscreen_destroy(off)

	buf := make([dynamic]u8)
	defer delete(buf)
	append(&buf, "שלום"); // 4 letters, 2 bytes each

	at: int
	frame :: proc(off: ^p.Offscreen, buf: ^[dynamic]u8) -> (^p.Ctx, int) {
		ui := p.offscreen_begin(off)
		p.div(ui, "w-full h-full p-2")
		idx := p.node_count(ui)
		p.text_field(ui, buf)
		p.end(ui)
		p.offscreen_end(off)
		return ui, idx
	}

	ui, idx := frame(off, &buf)
	r := p.node_rect(ui, idx)
	testing.expect(t, r.w > 0, "the field got a size")

	// Focus it the way a user would.
	p.move_pointer(off, r.x + r.w / 2, r.y + r.h / 2)
	frame(off, &buf)
	p.press(off)
	frame(off, &buf)
	p.release(off)
	frame(off, &buf)

	start := p.widget_cursor(ui, idx)
	testing.expect_value(t, start, 0)

	p.press_key(off, p.KEY_LEFT)
	frame(off, &buf)
	after := p.widget_cursor(ui, idx)

	testing.expectf(
		t,
		after > start,
		"left arrow in a right-to-left field must move into the text (visual left = logical forward); cursor went %d -> %d",
		start,
		after,
	)
}

// The same key in a left-to-right field still walks backwards, so nothing that
// already worked changed meaning.
@(test)
test_ltr_field_left_arrow_still_walks_back :: proc(t: ^testing.T) {
	off := shot(360, 80)
	defer p.offscreen_destroy(off)

	buf := make([dynamic]u8)
	defer delete(buf)
	append(&buf, "hello")

	frame :: proc(off: ^p.Offscreen, buf: ^[dynamic]u8) -> (^p.Ctx, int) {
		ui := p.offscreen_begin(off)
		p.div(ui, "w-full h-full p-2")
		idx := p.node_count(ui)
		p.text_field(ui, buf)
		p.end(ui)
		p.offscreen_end(off)
		return ui, idx
	}

	ui, idx := frame(off, &buf)
	r := p.node_rect(ui, idx)
	p.move_pointer(off, r.x + r.w / 2, r.y + r.h / 2)
	frame(off, &buf)
	p.press(off)
	frame(off, &buf)
	p.release(off)
	frame(off, &buf)

	// Put the caret at the end, then walk left twice.
	p.press_key(off, p.KEY_END)
	frame(off, &buf)
	testing.expect_value(t, p.widget_cursor(ui, idx), 5)
	p.press_key(off, p.KEY_LEFT)
	frame(off, &buf)
	testing.expect_value(t, p.widget_cursor(ui, idx), 4)
	p.press_key(off, p.KEY_LEFT)
	frame(off, &buf)
	testing.expect_value(t, p.widget_cursor(ui, idx), 3)
}
