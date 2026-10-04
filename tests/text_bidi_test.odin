package palmy_tests

import "core:testing"
import p "../palmy"

// ---------------------------------------------------------------------------
// The bidi and shaping wiring in palmy/font.odin
//
// bidi.odin is checked against libfribidi and ICU, and shape.odin against
// harfbuzz; neither of those says anything about whether the text path uses
// them, or uses them in the right order. These tests are about the seam: that a
// right-to-left line comes out of `text_glyphs` reversed, that an Arabic one
// comes out joined, that the measurement and the drawing agree about it, and
// above all that the caret lands where the glyph is.
//
// The caret half is the part assertions describe badly, so the numbers here are
// structural -- an edge is to the left of another edge, two affinities differ,
// a walk is monotonic -- rather than pixel constants that would only re-state
// whatever the code happened to compute.
// ---------------------------------------------------------------------------

// A mixed line, which is where everything goes wrong. The byte offsets are
// worth having in front of you:
//
//   a 0   b 1   c 2   ␣ 3   ש 4   ל 6   ו 8   ם 10   ␣ 12   x 13   y 14   z 15
//
// and it is 16 bytes long. The Hebrew word is drawn between "abc " and " xyz",
// with its own letters running the other way.
MIXED :: "abc שלום xyz"
HEBREW :: "שלום עולם"
ARABIC :: "العربية"
LATIN :: "The quick brown fox jumps over the lazy dog, 0123456789."

@(private = "file")
fonts :: proc(t: ^testing.T) -> ^p.Offscreen {
	off := p.offscreen_create(640, 80, 1, "w-full h-full bg-black text-white")
	testing.expect(t, off.fonts.faces[.Sans][.Regular][.Upright].ok, "a sans face is needed")
	return off
}

// ---------------------------------------------------------------------------
// The fast path, which is the single most important thing not to disturb
// ---------------------------------------------------------------------------

@(test)
test_text_fast_path_covers_what_it_claims :: proc(t: ^testing.T) {
	// Everything that cannot reorder under a left-to-right base direction, and
	// therefore must never reach `bidi_resolve`: ASCII, and every script whose
	// codepoints sit below the first right-to-left block.
	for s in ([]string {
		"",
		"Hello, world!",
		LATIN,
		"Weiß — café “quotes” 1,234.56 €",
		"Ελληνικά",
		"Кириллица",
		"中文字符",
		"日本語のテキスト",
		"tab\tand\nnewline",
	}) {
		testing.expectf(t, p.bidi_cannot_reorder(s), "%q should take the fast path", s)
	}
	// And everything that must not.
	for s in ([]string{HEBREW, ARABIC, MIXED, "x‫forced‬y", "٤٢", "a֐b"}) {
		testing.expectf(t, !p.bidi_cannot_reorder(s), "%q must be resolved", s)
	}
}

@(test)
test_latin_caret_is_still_the_prefix_width :: proc(t: ^testing.T) {
	off := fonts(t)
	defer p.offscreen_destroy(off)

	// For text that cannot reorder, the caret is where it always was -- the
	// width of the prefix -- and the affinity makes no difference, which is why
	// nothing already written has to learn about it.
	latin := LATIN
	for i := 0; i <= len(latin); i += 1 {
		want := p.text_width(&off.fonts, latin[:i], 20)
		down := p.text_caret_x(&off.fonts, latin, i, 20, .Downstream)
		up := p.text_caret_x(&off.fonts, latin, i, 20, .Upstream)
		testing.expect_value(t, down, want)
		testing.expect_value(t, up, want)
		testing.expect_value(t, p.text_width_upto(&off.fonts, latin, i, 20), want)
	}
}

@(test)
test_latin_hit_test_is_unchanged_and_round_trips :: proc(t: ^testing.T) {
	off := fonts(t)
	defer p.offscreen_destroy(off)

	w := p.text_width(&off.fonts, LATIN, 20)
	for k in 0 ..= 64 {
		x := w * f32(k) / 64
		plain := p.text_index_at(&off.fonts, LATIN, 20, x)
		idx, aff := p.text_index_at_affinity(&off.fonts, LATIN, 20, x)
		testing.expect_value(t, idx, plain)
		testing.expect_value(t, aff, p.Caret_Affinity.Downstream)
		// The caret for the index a click produced is within half a character
		// of the click, which is the whole promise of "nearest boundary".
		back := p.text_caret_x(&off.fonts, LATIN, idx, 20)
		testing.expectf(t, abs(back - x) < 20, "click at %.1f produced a caret at %.1f", x, back)
	}
}

// ---------------------------------------------------------------------------
// Ordering
// ---------------------------------------------------------------------------

@(test)
test_rtl_line_is_drawn_right_to_left :: proc(t: ^testing.T) {
	off := fonts(t)
	defer p.offscreen_destroy(off)

	gs, total := p.text_glyphs(&off.fonts, HEBREW, 32)
	testing.expect(t, len(gs) > 0, "the line must produce glyphs")
	testing.expect(t, total > 0)
	testing.expect(t, p.text_base_rtl(HEBREW), "a Hebrew paragraph is right-to-left")

	// Every glyph is right-to-left, the x positions run forward, and the source
	// offsets run backward. That last one is the reordering, stated plainly.
	prev_src := len(HEBREW)
	prev_x := f32(-1)
	for g in gs {
		testing.expect(t, g.rtl, "every run of a Hebrew line is right-to-left")
		testing.expect(t, g.x > prev_x, "glyphs are placed left to right")
		testing.expectf(t, g.src < prev_src, "source offsets must descend, got %d after %d", g.src, prev_src)
		prev_src = g.src
		prev_x = g.x
	}
	// The leftmost glyph is the last character of the string.
	testing.expect_value(t, gs[0].src + gs[0].size, len(HEBREW))
	testing.expect_value(t, gs[len(gs) - 1].src, 0)
}

@(test)
test_mixed_line_leaves_the_latin_runs_in_place :: proc(t: ^testing.T) {
	off := fonts(t)
	defer p.offscreen_destroy(off)

	gs, _ := p.text_glyphs(&off.fonts, MIXED, 32)
	testing.expect_value(t, len(gs), 12)
	testing.expect(t, !p.text_base_rtl(MIXED), "a line beginning with Latin is a left-to-right paragraph")

	// "abc " keeps its order and its place at the left.
	for i in 0 ..< 4 {
		testing.expect_value(t, gs[i].src, i)
		testing.expect(t, !gs[i].rtl)
	}
	// The Hebrew word is reversed in the middle, and it is one right-to-left
	// run at level 1.
	want_src := [4]int{10, 8, 6, 4}
	for i in 0 ..< 4 {
		testing.expect_value(t, gs[4 + i].src, want_src[i])
		testing.expect(t, gs[4 + i].rtl)
		testing.expect_value(t, gs[4 + i].level, u8(1))
	}
	// " xyz" keeps its order and its place at the right.
	for i in 0 ..< 4 {
		testing.expect_value(t, gs[8 + i].src, 12 + i)
		testing.expect(t, !gs[8 + i].rtl)
	}
}

@(test)
test_base_direction_comes_from_the_paragraph :: proc(t: ^testing.T) {
	off := fonts(t)
	defer p.offscreen_destroy(off)

	// A line of a Hebrew paragraph that happens to begin with a Latin word.
	// Resolved on its own it is a left-to-right line; resolved as part of its
	// paragraph it is not, and the two put the words in opposite places. This
	// is the trap `bidi_direction_for_level` exists for: wrap first, take the
	// base level from the whole paragraph, pass it to every line.
	line := "HTTP שלום"
	para_dir := p.text_base_dir("שלום עולם HTTP שלום", .Auto)
	testing.expect_value(t, para_dir, p.Bidi_Direction.RTL)

	auto, _ := p.text_glyphs(&off.fonts, line, 32, dir = .Auto)
	auto_first := auto[0].src

	para, _ := p.text_glyphs(&off.fonts, line, 32, dir = para_dir)
	para_first := para[0].src

	testing.expectf(
		t,
		auto_first != para_first,
		"the line must be laid out differently as a paragraph of its own (%d) and as part of a Hebrew one (%d)",
		auto_first,
		para_first,
	)
	// Standing alone the Latin word leads from the left; inside the Hebrew
	// paragraph it is pushed to the right and the Hebrew leads.
	testing.expect_value(t, auto_first, 0)
	testing.expect(t, para_first > 4, "the Hebrew word should be leftmost in a right-to-left paragraph")
}

@(test)
test_arabic_is_joined_by_the_text_path :: proc(t: ^testing.T) {
	off := fonts(t)
	defer p.offscreen_destroy(off)

	gs, total := p.text_glyphs(&off.fonts, ARABIC, 32)
	testing.expect(t, len(gs) > 0)
	joined := 0
	prev_src := len(ARABIC)
	for g in gs {
		testing.expect(t, g.rtl)
		testing.expect(t, g.src < prev_src, "Arabic reorders like any other right-to-left run")
		prev_src = g.src
		if g.shaped {
			joined += 1
			testing.expect(
				t,
				g.cp >= 0xfb50 && g.cp <= 0xfeff,
				"a shaped letter is a presentation form",
			)
		}
	}
	testing.expectf(t, joined >= len(gs) - 1, "only the last letter may stand unjoined, %d of %d shaped", joined, len(gs))

	// Joining is not cosmetic: the joined word is narrower than its letters
	// standing alone, which is what it looked like before any of this was wired.
	apart := f32(0)
	for r in ARABIC {
		buf: [4]u8
		n := encode_rune(&buf, r)
		apart += p.text_width(&off.fonts, string(buf[:n]), 32)
	}
	testing.expectf(t, total < apart, "joined %.1f should be under isolated %.1f", total, apart)
}

@(private = "file")
encode_rune :: proc(buf: ^[4]u8, r: rune) -> int {
	v := u32(r)
	switch {
	case v < 0x80:
		buf[0] = u8(v)
		return 1
	case v < 0x800:
		buf[0] = 0xc0 | u8(v >> 6)
		buf[1] = 0x80 | u8(v & 0x3f)
		return 2
	case v < 0x10000:
		buf[0] = 0xe0 | u8(v >> 12)
		buf[1] = 0x80 | u8((v >> 6) & 0x3f)
		buf[2] = 0x80 | u8(v & 0x3f)
		return 3
	}
	buf[0] = 0xf0 | u8(v >> 18)
	buf[1] = 0x80 | u8((v >> 12) & 0x3f)
	buf[2] = 0x80 | u8((v >> 6) & 0x3f)
	buf[3] = 0x80 | u8(v & 0x3f)
	return 4
}

@(test)
test_directional_controls_have_no_width :: proc(t: ^testing.T) {
	off := fonts(t)
	defer p.offscreen_destroy(off)

	// A right-to-left override around a Latin word. The controls carry levels,
	// so they must survive into the glyph list and own their bytes, but they
	// have no outline in any face and would be .notdef boxes if they were drawn.
	s := "a‮RTL‬b"
	gs, _ := p.text_glyphs(&off.fonts, s, 32)
	controls := 0
	for g in gs {
		if p.bidi_is_control(g.cp) {
			controls += 1
			testing.expect(t, g.blank, "a directional control must not be drawn")
			testing.expect_value(t, g.adv, f32(0))
		}
	}
	testing.expect_value(t, controls, 2)

	// And the override did its job: the three letters between them are reversed.
	seen: [3]int
	n := 0
	for g in gs {
		if g.cp == 'R' || g.cp == 'T' || g.cp == 'L' {
			if n < 3 {
				seen[n] = g.src
			}
			n += 1
		}
	}
	testing.expect_value(t, n, 3)
	testing.expect(t, seen[0] > seen[1] && seen[1] > seen[2], "an RLO run is drawn backwards")
}

@(test)
test_measurement_and_drawing_agree_on_a_reordered_line :: proc(t: ^testing.T) {
	off := fonts(t)
	defer p.offscreen_destroy(off)

	// Rule three: shaping happens before both, so the two must produce the same
	// number. A few pixels of disagreement here is what makes every centred or
	// wrapped right-to-left line sit slightly wrong.
	for s in ([]string{MIXED, HEBREW, ARABIC, "لا", "Hello"}) {
		w := p.text_width(&off.fonts, s, 24)
		drawn := p.draw_text(&off.canvas, &off.fonts, s, 4, 40, 24, {255, 255, 255, 255})
		testing.expectf(t, abs(w - drawn) < 0.01, "%q measured %.3f and drew %.3f", s, w, drawn)
	}
}

// ---------------------------------------------------------------------------
// The caret
// ---------------------------------------------------------------------------

@(test)
test_caret_at_a_direction_boundary_has_two_answers :: proc(t: ^testing.T) {
	off := fonts(t)
	defer p.offscreen_destroy(off)

	// Byte 4 is the boundary: the end of "abc " and the start of the Hebrew.
	// One offset, two places on screen, and only the affinity says which.
	up := p.text_caret_x(&off.fonts, MIXED, 4, 32, .Upstream)
	down := p.text_caret_x(&off.fonts, MIXED, 4, 32, .Downstream)
	testing.expect(t, up != down, "a boundary offset must have two caret positions")

	// Upstream follows the space, so it is at the right edge of "abc ".
	testing.expectf(
		t,
		abs(up - p.text_width(&off.fonts, "abc ", 32)) < 0.01,
		"the upstream caret should sit after the space, at %.2f not %.2f",
		p.text_width(&off.fonts, "abc ", 32),
		up,
	)
	// Downstream precedes the first Hebrew letter, whose leading edge is its
	// *right* side -- so it is at the far side of the whole Hebrew word.
	total := p.text_width(&off.fonts, MIXED, 32)
	tail := p.text_width(&off.fonts, " xyz", 32)
	testing.expectf(t, abs(down - (total - tail)) < 0.05, "the downstream caret should sit at the right of the Hebrew, %.2f", down)
	testing.expect(t, down > up, "and that is to the right of the upstream answer")

	// The same two places, reached the other way: the offset at the far end of
	// the Hebrew word is the same pair of coordinates, swapped.
	testing.expect_value(t, p.text_caret_x(&off.fonts, MIXED, 12, 32, .Downstream), down)
	testing.expect_value(t, p.text_caret_x(&off.fonts, MIXED, 12, 32, .Upstream), up)
}

@(test)
test_hit_test_inside_an_rtl_run_counts_backwards :: proc(t: ^testing.T) {
	off := fonts(t)
	defer p.offscreen_destroy(off)

	gs, _ := p.text_glyphs(&off.fonts, HEBREW, 32)
	// Copy what we need: the glyph list is scratch and the next call rewrites it.
	first := gs[0]
	last := gs[len(gs) - 1]

	// The leftmost glyph is the last character. Clicking its right half -- its
	// leading edge -- is a caret *before* it, which is the larger byte offset.
	i, aff := p.text_index_at_affinity(&off.fonts, HEBREW, 32, first.x + first.adv * 0.75)
	testing.expect_value(t, i, first.src)
	testing.expect_value(t, aff, p.Caret_Affinity.Downstream)
	// Its left half is a caret after it, which is the end of the string.
	i, aff = p.text_index_at_affinity(&off.fonts, HEBREW, 32, first.x + first.adv * 0.25)
	testing.expect_value(t, i, first.src + first.size)
	testing.expect_value(t, aff, p.Caret_Affinity.Upstream)
	testing.expect_value(t, i, len(HEBREW))

	// And at the far right, the first character of the string.
	i, aff = p.text_index_at_affinity(&off.fonts, HEBREW, 32, last.x + last.adv * 0.75)
	testing.expect_value(t, i, 0)
	testing.expect_value(t, aff, p.Caret_Affinity.Downstream)
}

@(test)
test_hit_test_and_caret_round_trip :: proc(t: ^testing.T) {
	off := fonts(t)
	defer p.offscreen_destroy(off)

	// Whatever a click produces, drawing the caret for it must land back in the
	// character that was clicked on. Anything else is a caret that disagrees
	// with the glyphs, which is the failure this whole exercise is about.
	for s in ([]string{MIXED, HEBREW, ARABIC, LATIN}) {
		w := p.text_width(&off.fonts, s, 32)
		for k in 0 ..= 48 {
			x := w * f32(k) / 48
			i, aff := p.text_index_at_affinity(&off.fonts, s, 32, x)
			back := p.text_caret_x(&off.fonts, s, i, 32, aff)
			// The caret is on an edge of the glyph the click landed in, so it
			// is within one character's width of the click.
			testing.expectf(
				t,
				abs(back - x) < 40,
				"%q: click at %.1f gave index %d %v, caret at %.1f",
				s,
				x,
				i,
				aff,
				back,
			)
			testing.expect(t, i >= 0 && i <= len(s))
			testing.expect(t, back >= -0.01 && back <= w + 0.01, "the caret stays inside the line")
		}
	}
}

@(test)
test_caret_moves_left_and_right_on_screen :: proc(t: ^testing.T) {
	off := fonts(t)
	defer p.offscreen_destroy(off)

	// Visual movement, which is what an arrow key does. Stepping right must
	// move right on screen every time, including across the two direction
	// boundaries, where the byte offset jumps about instead.
	i := 0
	aff := p.Caret_Affinity.Downstream
	x := p.text_caret_x(&off.fonts, MIXED, i, 32, aff)
	steps := 0
	crossed_backwards := false
	for steps < 64 {
		ni, naff := p.text_caret_move(&off.fonts, MIXED, i, 32, .Right, aff)
		if ni == i && naff == aff {
			break
		}
		nx := p.text_caret_x(&off.fonts, MIXED, ni, 32, naff)
		testing.expectf(t, nx > x, "step %d moved from %.2f to %.2f", steps, x, nx)
		if ni < i {
			crossed_backwards = true
		}
		i, aff, x = ni, naff, nx
		steps += 1
	}
	testing.expect(t, steps >= 10, "the whole line should be walkable")
	testing.expect(t, crossed_backwards, "inside the Hebrew run the byte offset must decrease as the caret moves right")
	testing.expectf(t, abs(x - p.text_width(&off.fonts, MIXED, 32)) < 0.01, "the walk should end at the right edge, at %.2f", x)

	// And back again, left, to the left edge.
	steps = 0
	for steps < 64 {
		ni, naff := p.text_caret_move(&off.fonts, MIXED, i, 32, .Left, aff)
		if ni == i && naff == aff {
			break
		}
		nx := p.text_caret_x(&off.fonts, MIXED, ni, 32, naff)
		testing.expectf(t, nx < x, "left step %d moved from %.2f to %.2f", steps, x, nx)
		i, aff, x = ni, naff, nx
		steps += 1
	}
	testing.expect(t, steps >= 10)
	testing.expect_value(t, x, f32(0))
}

@(test)
test_caret_inside_a_lam_alef_ligature :: proc(t: ^testing.T) {
	off := fonts(t)
	defer p.offscreen_destroy(off)

	// lam-alef is one glyph standing for two letters, so a byte offset cannot
	// be recovered from the drawn codepoint -- which is why the shaper hands
	// back the source span it consumed.
	src := "لا"
	runes := p.shape_arabic_runes(src, p.DEFAULT_SHAPE_OPTIONS, context.allocator)
	defer delete(runes)
	testing.expect_value(t, len(runes), 1)
	testing.expect(t, runes[0].lig, "lam followed by alef is the one required ligature")
	testing.expect_value(t, runes[0].src, 0)
	testing.expect_value(t, runes[0].size, len(src))
	testing.expect_value(t, runes[0].cp, rune(0xfefb))

	// The text path carries that span through: one glyph, four source bytes.
	gs, total := p.text_glyphs(&off.fonts, src, 32)
	testing.expect_value(t, len(gs), 1)
	testing.expect_value(t, gs[0].size, len(src))
	testing.expect(t, gs[0].rtl)

	// There is no edge between the lam and the alef to measure, so a caret
	// between them is interpolated across the ligature. The two ends are the
	// ligature's own edges, right first because the run is right-to-left.
	lead := p.text_caret_x(&off.fonts, src, 0, 32)
	mid := p.text_caret_x(&off.fonts, src, 2, 32)
	trail := p.text_caret_x(&off.fonts, src, 4, 32)
	testing.expect_value(t, lead, total)
	testing.expect_value(t, trail, f32(0))
	testing.expect(t, mid < lead && mid > trail, "the caret between lam and alef is inside the ligature")

	// Selecting just the lam highlights its half of the ligature rather than
	// all of it or none of it.
	buf: [4]p.Text_Span
	n := p.text_selection_spans(&off.fonts, src, 0, 2, 32, buf[:])
	testing.expect_value(t, n, 1)
	testing.expect(t, buf[0].w < total && buf[0].w > 0)
	testing.expectf(t, abs(buf[0].x + buf[0].w - total) < 0.01, "the lam is the right half, at %.2f", buf[0].x)
}

// ---------------------------------------------------------------------------
// Selection
// ---------------------------------------------------------------------------

@(test)
test_selection_across_a_direction_boundary_is_two_rectangles :: proc(t: ^testing.T) {
	off := fonts(t)
	defer p.offscreen_destroy(off)

	buf: [8]p.Text_Span

	// "c", the space, and the first Hebrew letter: contiguous in the string,
	// and in two places on screen.
	n := p.text_selection_spans(&off.fonts, MIXED, 2, 6, 32, buf[:])
	testing.expect_value(t, n, 2)
	testing.expect(t, buf[0].w > 0 && buf[1].w > 0)
	testing.expect(t, buf[0].x + buf[0].w < buf[1].x, "the two rectangles must not touch")

	// The whole line is still one rectangle, because every glyph in it is
	// visually adjacent to the next however the runs are ordered.
	n = p.text_selection_spans(&off.fonts, MIXED, 0, len(MIXED), 32, buf[:])
	testing.expect_value(t, n, 1)
	testing.expect_value(t, buf[0].x, f32(0))
	testing.expectf(t, abs(buf[0].w - p.text_width(&off.fonts, MIXED, 32)) < 0.01, "got %.2f", buf[0].w)

	// So is the whole of the Hebrew word on its own.
	n = p.text_selection_spans(&off.fonts, MIXED, 4, 12, 32, buf[:])
	testing.expect_value(t, n, 1)

	// An empty range highlights nothing, and a left-to-right line is one
	// rectangle whatever is asked of it.
	testing.expect_value(t, p.text_selection_spans(&off.fonts, MIXED, 5, 5, 32, buf[:]), 0)
	n = p.text_selection_spans(&off.fonts, LATIN, 4, 9, 32, buf[:])
	testing.expect_value(t, n, 1)
	testing.expectf(
		t,
		abs(buf[0].x - p.text_width_upto(&off.fonts, LATIN, 4, 32)) < 0.01,
		"a left-to-right selection starts at the prefix width, got %.2f",
		buf[0].x,
	)
}

@(test)
test_selection_spans_respect_a_short_buffer :: proc(t: ^testing.T) {
	off := fonts(t)
	defer p.offscreen_destroy(off)

	one: [1]p.Text_Span
	n := p.text_selection_spans(&off.fonts, MIXED, 2, 6, 32, one[:])
	testing.expect_value(t, n, 1)
	testing.expect(t, one[0].w > 0, "the leftmost rectangle is the one that fits")

	none: []p.Text_Span
	testing.expect_value(t, p.text_selection_spans(&off.fonts, MIXED, 2, 6, 32, none), 0)
}

// ---------------------------------------------------------------------------
// Ink
// ---------------------------------------------------------------------------

@(test)
test_reordered_lines_actually_draw :: proc(t: ^testing.T) {
	off := fonts(t)
	defer p.offscreen_destroy(off)

	// A width assertion passes just as happily on a row of nothing, so count
	// the pixels. Each line is drawn on its own frame and the ink has to appear
	// within the width that was measured, not past it.
	for s in ([]string{HEBREW, ARABIC, MIXED, "لا"}) {
		p.offscreen_begin(off)
		p.offscreen_end(off)
		w := p.draw_text(&off.canvas, &off.fonts, s, 8, 50, 32, {255, 255, 255, 255})

		ink, rightmost := 0, 0
		for y in 0 ..< off.height {
			for x in 0 ..< off.width {
				if p.offscreen_pixel(off, x, y).r > 40 {
					ink += 1
					rightmost = max(rightmost, x)
				}
			}
		}
		testing.expectf(t, ink > 60, "%q drew %d lit pixels", s, ink)
		testing.expectf(
			t,
			f32(rightmost) <= 8 + w + 2,
			"%q put ink at x=%d, past the %.1f it measured",
			s,
			rightmost,
			w,
		)
	}
}
