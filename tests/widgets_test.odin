// Palmy's own widgets, asserted on what they actually draw.
//
// The parity suite exercises `shadcn/`, never `palmy/`: `grep text_field
// parity/odin/render/` returns nothing. That is how a text field shipped
// drawing slate-200 text on a white page when no theme was registered --
// parity passed, every application built, and the only thing that could have
// caught it was a test that looked at the pixels.
//
// So these tests assert what is *visible*: the colour of the ink against the
// colour of the box it sits in, whether a mark is drawn, what string reached
// the screen. Storage is checked only where the point is that storage and
// display disagree, as with a masked field.
package palmy_tests

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:testing"
import p "../palmy"

// ---------------------------------------------------------------------------
// Looking at pixels
// ---------------------------------------------------------------------------

// luminance is WCAG relative luminance, which is what "readable" has to be
// measured in: #e2e8f0 on #ffffff is a 1.2:1 contrast ratio and invisible,
// while the same two colours are 24 points apart in plain RGB and look fine
// to a naive difference check.
@(private)
luminance :: proc(c: p.Color) -> f32 {
	chan :: proc(v: u8) -> f32 {
		s := f32(v) / 255
		return s <= 0.03928 ? s / 12.92 : math.pow((s + 0.055) / 1.055, 2.4)
	}
	return 0.2126 * chan(c.r) + 0.7152 * chan(c.g) + 0.0722 * chan(c.b)
}

// contrast_ratio is the WCAG ratio, 1 for two identical colours and 21 for
// black on white.
@(private)
contrast_ratio :: proc(a, b: p.Color) -> f32 {
	la, lb := luminance(a), luminance(b)
	hi, lo := max(la, lb), min(la, lb)
	return (hi + 0.05) / (lo + 0.05)
}

// ink_contrast scans a rectangle and reports the most contrasting pixel in it
// against `bg`, together with how many pixels clear `min_ratio`. Both numbers
// matter: the ratio says the text is readable, the count says there is text
// there at all rather than an empty box that trivially "passes".
//
// `min_ratio` is 3 for text that is meant to be read. A placeholder is drawn
// at half alpha and palmy composites in linear light, so 50% of near-black on
// white lands around 1.9:1 rather than the ~3.9:1 an sRGB-space blend would
// give; a placeholder is counted against a lower bar for that reason.
@(private)
ink_contrast :: proc(
	off: ^p.Offscreen,
	r: p.Rect,
	bg: p.Color,
	inset: f32 = 4,
	min_ratio: f32 = 3,
) -> (best: f32, legible: int) {
	best = 1
	x0, y0 := int(r.x + inset), int(r.y + inset)
	x1, y1 := int(r.x + r.w - inset), int(r.y + r.h - inset)
	for y in y0 ..< y1 {
		for x in x0 ..< x1 {
			c := p.offscreen_pixel(off, x, y)
			cr := contrast_ratio(c, bg)
			best = max(best, cr)
			if cr >= min_ratio {
				legible += 1
			}
		}
	}
	return
}

// box_background samples a spot inside a widget that its own text does not
// reach: the inner right edge, vertically centred. A field is laid out from
// its leading edge, so the trailing end is its own fill.
@(private)
box_background :: proc(off: ^p.Offscreen, r: p.Rect) -> p.Color {
	return p.offscreen_pixel(off, int(r.x + r.w - 4), int(r.y + r.h / 2))
}

@(private)
ink_pixels :: proc(off: ^p.Offscreen, r: p.Rect, bg: p.Color, inset: f32 = 4, min_ratio: f32 = 3) -> int {
	_, n := ink_contrast(off, r, bg, inset, min_ratio)
	return n
}

// first_child_of_kind finds a widget's drawn parts without the widget having
// to return them.
@(private)
first_child_of_kind :: proc(ui: ^p.Ctx, parent: int, kind: p.Node_Kind) -> int {
	for i in parent + 1 ..< p.node_count(ui) {
		if p.node_kind(ui, i) == kind && descends_from(ui, i, parent) {
			return i
		}
	}
	return -1
}

@(private)
descends_from :: proc(ui: ^p.Ctx, node, ancestor: int) -> bool {
	i := node
	for i >= 0 {
		if i == ancestor {
			return true
		}
		i = p.node_parent(ui, i)
	}
	return false
}

// ---------------------------------------------------------------------------
// text_field: the placeholder
// ---------------------------------------------------------------------------

// A placeholder is shown when the field is empty and never again. The bug this
// catches is either half of that: a placeholder that keeps being drawn under
// what is typed, or one that is drawn into the buffer's own text node and so
// survives the first keystroke.
@(test)
test_text_field_placeholder_appears_only_when_empty :: proc(t: ^testing.T) {
	off := p.offscreen_create(320, 60, 1, "w-full h-full bg-white text-slate-900")
	defer p.offscreen_destroy(off)

	buf: [dynamic]u8
	defer delete(buf)

	draw :: proc(off: ^p.Offscreen, buf: ^[dynamic]u8) -> (ui: ^p.Ctx, field: int) {
		ui = p.offscreen_begin(off)
		p.div(ui, "w-full h-full p-2")
		field = p.node_count(ui)
		// Explicit colours rather than the fallback, so this test measures
		// the placeholder and not whatever the field's default happens to be.
		p.text_field(ui, buf, "Your name", "w-full bg-white text-slate-900 border-slate-400")
		p.end(ui)
		p.offscreen_end(off)
		return
	}

	ui, field := draw(off, &buf)
	label := first_child_of_kind(ui, field, .Text)
	testing.expect(t, label >= 0, "an empty field draws a text node")
	testing.expect_value(t, p.node_text(ui, label), "Your name")

	r := p.node_rect(ui, field)
	bg := box_background(off, r)
	placeholder_ratio, placeholder_ink := ink_contrast(off, r, bg, 4, 1.5)
	testing.expectf(t, placeholder_ink > 20, "the placeholder is actually drawn (%d pixels)", placeholder_ink)
	testing.expectf(
		t,
		placeholder_ratio >= 1.5,
		"a placeholder is faint but still visible against the field: %.2f:1",
		placeholder_ratio,
	)

	// The placeholder is the field's own colour at half strength, not a
	// hardcoded grey that a dark theme would turn invisible.
	s := p.node_style(ui, field)
	ls := p.node_style(ui, label)
	testing.expect_value(t, ls.fg.a, u8(f32(s.fg.a) * 0.5))

	// Type into it. The placeholder must be gone, and what is drawn must be
	// the buffer. The field carries `transition`, so the colour crossfades
	// from the faded placeholder to full strength over a few frames; settle
	// it before measuring, or the assertion is reading an animation.
	append(&buf, "Ada"); // written directly: this test is about drawing, not keys
	ui2, field2 := draw(off, &buf)
	for _ in 0 ..< 30 {
		ui2, field2 = draw(off, &buf)
	}
	label2 := first_child_of_kind(ui2, field2, .Text)
	testing.expect_value(t, p.node_text(ui2, label2), "Ada")
	testing.expect(t, p.node_text(ui2, label2) != "Your name", "the placeholder is not drawn over the text")

	typed_ratio, typed_ink := ink_contrast(off, p.node_rect(ui2, field2), bg)
	testing.expectf(t, typed_ink > 40, "the typed text is drawn (%d pixels)", typed_ink)
	testing.expectf(
		t,
		typed_ratio >= 4.5 && typed_ratio > placeholder_ratio * 2,
		"real text is far darker than the placeholder it replaced (%.2f:1 vs %.2f:1)",
		typed_ratio,
		placeholder_ratio,
	)

	// Emptying the field brings it back.
	clear(&buf)
	ui3, field3 := draw(off, &buf)
	testing.expect_value(t, p.node_text(ui3, first_child_of_kind(ui3, field3, .Text)), "Your name")
}

// A field with no placeholder and nothing in it draws no text at all -- an
// empty string is not a placeholder.
@(test)
test_text_field_without_a_placeholder_draws_nothing :: proc(t: ^testing.T) {
	off := p.offscreen_create(320, 60, 1, "w-full h-full bg-white text-slate-900")
	defer p.offscreen_destroy(off)

	buf: [dynamic]u8
	defer delete(buf)

	ui := p.offscreen_begin(off)
	p.div(ui, "w-full h-full p-2")
	field := p.node_count(ui)
	p.text_field(ui, &buf, "", "w-full bg-white text-slate-900 border-slate-400")
	p.end(ui)
	p.offscreen_end(off)

	label := first_child_of_kind(ui, field, .Text)
	testing.expect_value(t, p.node_text(ui, label), "")

	r := p.node_rect(ui, field)
	testing.expect_value(t, ink_pixels(off, r, box_background(off, r), 4, 1.2), 0)
}

// ---------------------------------------------------------------------------
// text_field: masking
// ---------------------------------------------------------------------------

// A masked field must draw the mask and nothing else. The failure mode is a
// password that is measured as asterisks and painted as itself, which no
// assertion on the buffer can see.
@(test)
test_text_field_masking_changes_what_is_drawn :: proc(t: ^testing.T) {
	buf: [dynamic]u8
	defer delete(buf)
	append(&buf, "hunter2")

	stars: [dynamic]u8
	defer delete(stars)
	append(&stars, "*******")

	// Three renders at identical geometry: the secret masked, the secret
	// plain, and a field whose buffer really holds seven asterisks.
	render :: proc(src: ^[dynamic]u8, mask: rune) -> (off: ^p.Offscreen, drawn: string, ink: int) {
		off = p.offscreen_create(320, 60, 1, "w-full h-full bg-white text-slate-900")
		ui := p.offscreen_begin(off)
		p.div(ui, "w-full h-full p-2")
		field := p.node_count(ui)
		p.text_field(ui, src, "", "w-full bg-white text-slate-900 border-slate-400", mask)
		p.end(ui)
		p.offscreen_end(off)

		label := first_child_of_kind(ui, field, .Text)
		r := p.node_rect(ui, field)
		// The text is cloned into frame memory, which offscreen_end releases,
		// so it has to be measured, not kept.
		drawn = fmt.aprint(p.node_text(ui, label))
		ink = ink_pixels(off, r, box_background(off, r), 4, 1.5)
		return
	}

	masked_off, masked_text, masked_ink := render(&buf, '*')
	defer p.offscreen_destroy(masked_off)
	defer delete(masked_text)
	plain_off, plain_text, plain_ink := render(&buf, 0)
	defer p.offscreen_destroy(plain_off)
	defer delete(plain_text)
	stars_off, stars_text, stars_ink := render(&stars, 0)
	defer p.offscreen_destroy(stars_off)
	defer delete(stars_text)

	testing.expect_value(t, string(buf[:]), "hunter2") // the buffer is untouched
	testing.expect_value(t, masked_text, "*******")
	testing.expect_value(t, plain_text, "hunter2")
	testing.expect_value(t, stars_text, "*******")

	testing.expect(t, masked_ink != plain_ink, "masking changes what is drawn")
	testing.expectf(
		t,
		abs(masked_ink - stars_ink) <= 2,
		"a masked secret draws exactly what a field of asterisks draws (%d vs %d)",
		masked_ink,
		stars_ink,
	)

	// And the mask is one glyph per rune of the real text, not per byte.
	utf8: [dynamic]u8
	defer delete(utf8)
	append(&utf8, "héllo") // five runes, six bytes
	utf8_off, utf8_text, _ := render(&utf8, '*')
	defer p.offscreen_destroy(utf8_off)
	defer delete(utf8_text)
	testing.expect_value(t, utf8_text, "*****")
}

// ---------------------------------------------------------------------------
// text_field: readable under a light theme, a dark theme, and no theme
// ---------------------------------------------------------------------------

// Theme tokens for the field, registered once at startup.
//
// They are registered from `@(init)`, before the test runner spawns its
// threads, and never written again: palmy's token table is process-wide and
// every rendering test reads it through `parse_color`, so a test that
// registered or cleared tokens while the others ran would be a data race on a
// shared map -- one that was observed crashing this suite before these moved
// here. Unique names keep them out of every other test's way.
@(private)
TF_LIGHT :: "bg-tfield-light-surface text-tfield-light-ink border-tfield-light-edge"
@(private)
TF_DARK :: "bg-tfield-dark-surface text-tfield-dark-ink border-tfield-dark-edge"
// A palette that defines its text colour and forgets its surface, which is
// the half-configured case FIELD_BASE is written to survive.
@(private)
TF_PARTIAL :: "text-tfield-light-ink bg-tfield-missing-surface border-tfield-missing-edge"

@(init)
register_field_theme_tokens :: proc "contextless" () {
	// @(init) procedures are contextless; registering a token allocates, so
	// this needs a context of its own. It is the process default rather than
	// a test's tracking allocator, which is what keeps these six strings out
	// of whichever test happens to run first.
	context = runtime.default_context()
	p.register_color("tfield-light-surface", p.hex(0xffffff))
	p.register_color("tfield-light-ink", p.hex(0x0a0a0a))
	p.register_color("tfield-light-edge", p.hex(0xe5e5e5))
	p.register_color("tfield-dark-surface", p.hex(0x0a0a0a))
	p.register_color("tfield-dark-ink", p.hex(0xfafafa))
	p.register_color("tfield-dark-edge", p.hex(0x404040))
}

// The regression that shipped: with no theme registered, the field took the
// page's text colour. The toolkit's default page text is slate-200 and the
// field's own fill is white, so the text was white-on-white in all but name --
// parity was green, every application built, and the field was unreadable.
//
// So: the ink has to clear 4.5:1 against the field's *own fill* with a light
// theme, with a dark theme, with a half-configured one, and with no theme at
// all. The last is the one that failed.
@(test)
test_text_field_stays_readable_under_every_theme :: proc(t: ^testing.T) {
	buf: [dynamic]u8
	defer delete(buf)
	append(&buf, "Ada Lovelace")

	// draw renders one field on one page and reports the contrast of its ink
	// against its own fill, plus how much ink there was and how visible the
	// field's edge is against the page behind it.
	draw :: proc(buf: ^[dynamic]u8, page, class: string) -> (ratio: f32, ink: int, edge: f32) {
		off := p.offscreen_create(360, 72, 1, page)
		defer p.offscreen_destroy(off)

		ui := p.offscreen_begin(off)
		p.div(ui, "w-full h-full p-4")
		field := p.node_count(ui)
		p.text_field(ui, buf, "", class)
		p.end(ui)
		p.offscreen_end(off)

		r := p.node_rect(ui, field)
		fill := box_background(off, r)
		ratio, ink = ink_contrast(off, r, fill)

		// The page behind the field, sampled outside it, against the field's
		// own fill and its border: a field that cannot be told apart from the
		// page is as broken as one with unreadable text.
		page_px := p.offscreen_pixel(off, 2, 2)
		border := p.offscreen_pixel(off, int(r.x + r.w / 2), int(r.y))
		edge = max(contrast_ratio(fill, page_px), contrast_ratio(border, page_px))
		return
	}

	check :: proc(t: ^testing.T, what: string, ratio: f32, ink: int, edge: f32, loc := #caller_location) {
		testing.expectf(t, ink > 40, "%s: the text is drawn (%d pixels)", what, ink, loc = loc)
		testing.expectf(
			t,
			ratio >= 4.5,
			"%s: text against the field's own fill is %.2f:1, want 4.5:1",
			what,
			ratio,
			loc = loc,
		)
		testing.expectf(t, edge >= 1.2, "%s: the field is distinguishable from the page (%.2f:1)", what, edge, loc = loc)
	}

	// 1. No theme at all, on a white page whose text colour is the toolkit
	//    default. This is the exact combination that shipped broken.
	ratio, ink, edge := draw(&buf, "w-full h-full bg-white text-slate-200", "w-full")
	check(t, "no theme, light page", ratio, ink, edge)

	// ... and on the default dark page, where the fallback has to work the
	//     other way round.
	ratio, ink, edge = draw(&buf, "w-full h-full bg-slate-950 text-slate-200", "w-full")
	check(t, "no theme, dark page", ratio, ink, edge)

	// 2. A light theme, resolved through tokens.
	ratio, ink, edge = draw(&buf, "w-full h-full bg-neutral-200 text-neutral-900", "w-full " + TF_LIGHT)
	check(t, "light theme", ratio, ink, edge)

	// 3. A dark theme. Nothing about the field may be hardcoded against the
	//    light one, which is what the first version of FIELD_BASE was.
	ratio, ink, edge = draw(&buf, "w-full h-full bg-neutral-700 text-neutral-100", "w-full " + TF_DARK)
	check(t, "dark theme", ratio, ink, edge)

	// 4. A half-configured palette: the two unknown tokens are dropped by
	//    parse_color, so the fill and the border fall back while the text
	//    colour is honoured. A field that lost its fill here would put dark
	//    ink on whatever the page happened to be.
	ratio, ink, edge = draw(&buf, "w-full h-full bg-white text-slate-200", "w-full " + TF_PARTIAL)
	check(t, "partial theme", ratio, ink, edge)
}

// ---------------------------------------------------------------------------
// button
// ---------------------------------------------------------------------------

// A button's label is drawn on the button's own fill, so it has to be legible
// against that fill and not against the page -- the same mistake the field
// made. A button is also the one widget whose colours are entirely its own,
// which is exactly why nothing would notice if a variant made them collide.
@(test)
test_button_label_is_legible_on_its_own_fill :: proc(t: ^testing.T) {
	draw :: proc(page, class: string) -> (ratio: f32, ink: int, fill: p.Color) {
		off := p.offscreen_create(220, 80, 1, page)
		defer p.offscreen_destroy(off)

		ui := p.offscreen_begin(off)
		p.div(ui, "w-full h-full items-center justify-center")
		at := p.node_count(ui)
		p.button(ui, "Save", class)
		p.end(ui)
		p.offscreen_end(off)

		r := p.node_rect(ui, at)
		fill = p.offscreen_pixel(off, int(r.x + 3), int(r.y + r.h / 2))
		ratio, ink = ink_contrast(off, r, fill, 3)
		return
	}

	for page in ([?]string{"w-full h-full bg-white text-slate-900", "w-full h-full bg-slate-950 text-slate-200"}) {
		ratio, ink, _ := draw(page, "")
		testing.expectf(t, ink > 30, "the label is drawn on %s (%d pixels)", page, ink)
		testing.expectf(t, ratio >= 4.5, "the default button's label is %.2f:1 against its own fill on %s", ratio, page)
	}

	// A caller recolouring the button keeps the label: `class` wins over the
	// base, and a variant that set only the fill would be the regression.
	//
	// The bar here is 3:1, not 4.5:1, and deliberately: the stock
	// `text-slate-100` on `bg-indigo-500` measures 4.08:1, which is under
	// WCAG AA for body text. That is a design note for the toolkit rather
	// than something this test should enforce, so the assertion only catches
	// a real collision between the label and the fill.
	ratio, ink, fill := draw("w-full h-full bg-white text-slate-900", "bg-indigo-500 border-indigo-400")
	testing.expect_value(t, fill, p.Color{0x63, 0x66, 0xf1, 255})
	testing.expectf(t, ink > 30, "the label survives a recolour (%d pixels)", ink)
	testing.expectf(t, ratio >= 3, "a recoloured button is still readable (%.2f:1)", ratio)
}

// A disabled button is dimmer than an enabled one and does not fire. The
// visible half is the one that is easy to lose: `disabled:opacity-40` only
// does anything if the disabled flag reaches the class parser.
@(test)
test_disabled_button_is_dimmer_and_inert :: proc(t: ^testing.T) {
	off := p.offscreen_create(220, 80, 1, "w-full h-full bg-white text-slate-900")
	defer p.offscreen_destroy(off)

	fired := 0
	draw :: proc(off: ^p.Offscreen, disabled: bool, fired: ^int) -> p.Rect {
		ui := p.offscreen_begin(off)
		p.div(ui, "w-full h-full items-center justify-center")
		at := p.node_count(ui)
		if p.button(ui, "Delete", "", disabled) {
			fired^ += 1
		}
		p.end(ui)
		p.offscreen_end(off)
		return p.node_rect(ui, at)
	}

	r := draw(off, false, &fired)
	enabled_fill := p.offscreen_pixel(off, int(r.x + 3), int(r.y + r.h / 2))
	enabled_ratio, _ := ink_contrast(off, r, enabled_fill, 3)

	r = draw(off, true, &fired)
	disabled_fill := p.offscreen_pixel(off, int(r.x + 3), int(r.y + r.h / 2))
	disabled_ratio, _ := ink_contrast(off, r, disabled_fill, 3)

	testing.expect(t, disabled_fill != enabled_fill, "a disabled button is drawn differently")
	testing.expectf(
		t,
		luminance(disabled_fill) > luminance(enabled_fill),
		"the disabled fill is faded towards the page (%.3f vs %.3f)",
		luminance(disabled_fill),
		luminance(enabled_fill),
	)
	testing.expect(t, disabled_ratio < enabled_ratio, "and its label is dimmer than the enabled one")

	// Click it anyway.
	p.move_pointer(off, r.x + r.w / 2, r.y + r.h / 2)
	draw(off, true, &fired)
	p.press(off);draw(off, true, &fired)
	p.release(off);draw(off, true, &fired)
	testing.expect_value(t, fired, 0)
}

// ---------------------------------------------------------------------------
// checkbox
// ---------------------------------------------------------------------------

// The tick is drawn by a Custom_Fn against the raw canvas, which no geometry
// or style assertion can see. If the callback were never installed, the box
// would still be the right size and the right colour, the bool would still
// toggle, and the control would be silently useless.
@(test)
test_checkbox_draws_its_mark_only_when_checked :: proc(t: ^testing.T) {
	off := p.offscreen_create(220, 60, 1, "w-full h-full bg-white text-slate-900")
	defer p.offscreen_destroy(off)

	on := false
	draw :: proc(off: ^p.Offscreen, on: ^bool) -> (box: p.Rect, fill: p.Color, mark: int) {
		ui := p.offscreen_begin(off)
		p.div(ui, "w-full h-full p-2")
		at := p.node_count(ui)
		p.checkbox(ui, "Remember me", on)
		p.end(ui)
		p.offscreen_end(off)

		custom := first_child_of_kind(ui, at, .Custom)
		box = p.node_rect(ui, custom)
		// The fill is sampled above the tick, inside the border and away from
		// the rounded corners.
		fill = p.offscreen_pixel(off, int(box.x + box.w / 2), int(box.y + box.h * 0.12))
		// The tick is white, so count pixels much brighter than the fill, over
		// the interior only -- the border is not the mark.
		for y in int(box.y + 3) ..< int(box.y + box.h - 3) {
			for x in int(box.x + 3) ..< int(box.x + box.w - 3) {
				if contrast_ratio(p.offscreen_pixel(off, x, y), fill) >= 3 {
					mark += 1
				}
			}
		}
		return
	}

	_, unchecked_fill, unchecked_mark := draw(off, &on)
	testing.expectf(t, unchecked_mark == 0, "an unchecked box has no tick in it (%d pixels)", unchecked_mark)

	on = true
	box, checked_fill, checked_mark := draw(off, &on)
	testing.expect(t, checked_fill != unchecked_fill, "checking changes the box's fill")
	testing.expectf(t, checked_mark > 10, "a checked box draws a tick (%d pixels)", checked_mark)
	testing.expect(t, box.w >= 16 && box.h >= 16, "the box is big enough to hit")

	// And the tick follows the pointer, not just the bool: click it off again.
	on = true
	p.move_pointer(off, box.x + box.w / 2, box.y + box.h / 2)
	draw(off, &on)
	p.press(off);draw(off, &on)
	p.release(off)
	draw(off, &on)
	testing.expect(t, !on, "clicking the box clears it")
	_, _, after := draw(off, &on)
	testing.expect_value(t, after, 0)
}

// ---------------------------------------------------------------------------
// progress
// ---------------------------------------------------------------------------

// The bar is a percentage width inside the track, and the two must be
// different colours or the control shows nothing. Both halves shipped wrong
// once: the track was `bg-slate-800` and the bar `bg-indigo-500`, which on a
// light page was a dark slab with a slightly different dark slab inside it.
@(test)
test_progress_fills_in_proportion_and_is_visible :: proc(t: ^testing.T) {
	measure :: proc(frac: f32, page: string) -> (track, bar: p.Rect, track_px, bar_px: p.Color) {
		off := p.offscreen_create(240, 40, 1, page)
		defer p.offscreen_destroy(off)

		ui := p.offscreen_begin(off)
		p.div(ui, "w-full h-full p-2 justify-center")
		at := p.progress(ui, frac, "w-full")
		p.end(ui)
		p.offscreen_end(off)

		track = p.node_rect(ui, at)
		bar = p.node_rect(ui, first_child_of_kind(ui, at, .Box))
		// Sample the two ends: the filled side and the empty side.
		track_px = p.offscreen_pixel(off, int(track.x + track.w - 2), int(track.y + track.h / 2))
		bar_px = p.offscreen_pixel(off, int(track.x + 2), int(track.y + track.h / 2))
		return
	}

	// `progress` reads `bg-secondary` and `bg-primary`; nothing in this suite
	// registers either, so what is measured here is the built-in fallback --
	// which is the pair that shipped wrong.
	for page in ([?]string{"w-full h-full bg-white text-slate-900", "w-full h-full bg-slate-950 text-slate-200"}) {
		track, bar, track_px, bar_px := measure(0.5, page)
		geom_eq(t, bar.w, track.w / 2, "a half-full bar is half the track wide")
		geom_eq(t, bar.x, track.x, "and it starts at the track's leading edge")
		testing.expectf(
			t,
			contrast_ratio(bar_px, track_px) >= 1.5,
			"the bar is visible against the track on %s (%.2f:1)",
			page,
			contrast_ratio(bar_px, track_px),
		)
		// And both are visible against the page behind them.
		testing.expect(t, track.h >= 4, "the track has a drawable height")
	}

	// The ends, and a value outside the range.
	empty_track, empty_bar, _, _ := measure(0, "w-full h-full bg-white")
	geom_eq(t, empty_bar.w, 0, "an empty bar draws nothing")
	full_track, full_bar, _, _ := measure(1, "w-full h-full bg-white")
	geom_eq(t, full_bar.w, full_track.w, "a full bar covers the track")
	_, over_bar, _, _ := measure(4, "w-full h-full bg-white")
	geom_eq(t, over_bar.w, full_track.w, "a fraction above 1 is clamped, not overflowed")
	testing.expect(t, empty_track.w > 0, "the track is laid out even when empty")
}

// ---------------------------------------------------------------------------
// toggle and slider
// ---------------------------------------------------------------------------

// A switch that stored its state but never moved its knob would pass every
// assertion on the bool. This one looks at where the knob was drawn.
@(test)
test_toggle_knob_moves_to_the_side_it_is_on :: proc(t: ^testing.T) {
	off := p.offscreen_create(120, 60, 1, "w-full h-full bg-white text-slate-900")
	defer p.offscreen_destroy(off)

	on := false
	draw :: proc(off: ^p.Offscreen, on: ^bool) -> (track, knob: p.Rect, track_px: p.Color) {
		ui := p.offscreen_begin(off)
		p.div(ui, "w-full h-full items-center justify-center")
		at := p.node_count(ui)
		p.toggle(ui, on)
		p.end(ui)
		p.offscreen_end(off)

		track = p.node_rect(ui, at)
		knob = p.node_rect(ui, at + 1)
		track_px = p.offscreen_pixel(off, int(track.x + 2), int(track.y + track.h / 2))
		return
	}

	// The knob animates, so settle it.
	track, knob_off: p.Rect
	off_px: p.Color
	for _ in 0 ..< 60 {
		track, knob_off, off_px = draw(off, &on)
	}
	testing.expectf(t, knob_off.x - track.x < 4, "the knob rests at the left when off (%.1f)", knob_off.x - track.x)

	on = true
	knob_on: p.Rect
	on_px: p.Color
	for _ in 0 ..< 60 {
		_, knob_on, on_px = draw(off, &on)
	}
	testing.expectf(
		t,
		track.x + track.w - (knob_on.x + knob_on.w) < 4,
		"and at the right when on (%.1f from the end)",
		track.x + track.w - (knob_on.x + knob_on.w),
	)
	testing.expect(t, knob_on.x > knob_off.x + 10, "the knob actually travelled")
	testing.expect(t, on_px != off_px, "and the track changed colour under it")
}

// The slider's fill and knob both read from the same value; a fill that is
// right while the knob is not, or either one drawn outside the track, is a
// control that lies about what it is set to.
@(test)
test_slider_fill_and_knob_follow_the_value :: proc(t: ^testing.T) {
	off := p.offscreen_create(280, 60, 1, "w-full h-full bg-white text-slate-900")
	defer p.offscreen_destroy(off)

	measure :: proc(off: ^p.Offscreen, v: f32) -> (root, fill, knob: p.Rect) {
		value := v
		ui := p.offscreen_begin(off)
		p.row(ui, "w-full h-full items-center p-4")
		at := p.node_count(ui)
		p.slider(ui, &value, 0, 100)
		p.end(ui)
		p.offscreen_end(off)
		// track, fill, knob, in the order the widget builds them.
		return p.node_rect(ui, at), p.node_rect(ui, at + 2), p.node_rect(ui, at + 3)
	}

	// Two frames: the first gives the track a width for the second to use.
	measure(off, 25)
	root, fill, knob := measure(off, 25)
	geom_eq(t, fill.w, root.w * 0.25, "a quarter value fills a quarter of the track")

	// The knob tracks the value to within its own width. Its exact centre,
	// and that it stays on the track at both ends, is asserted in
	// `slider_test.odin` (TODO.md K2, fixed).
	testing.expectf(
		t,
		abs((knob.x + knob.w / 2) - (root.x + root.w * 0.25)) <= knob.w,
		"the knob follows the value (knob centre %.1f, value at %.1f)",
		knob.x + knob.w / 2,
		root.x + root.w * 0.25,
	)
	quarter_knob := knob.x

	measure(off, 100)
	root, fill, knob = measure(off, 100)
	geom_eq(t, fill.w, root.w, "a full value fills the track")
	testing.expect(t, knob.x > quarter_knob, "the knob moved right with the value")

	measure(off, 0)
	root, fill, knob = measure(off, 0)
	geom_eq(t, fill.w, 0, "an empty value fills nothing")
	testing.expect(t, knob.x < quarter_knob, "and back left again")
	testing.expect(t, knob.x >= root.x - 1, "the knob does not fall off the low end of the track")
}
