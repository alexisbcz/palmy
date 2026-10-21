package palmy_tests

import "core:testing"
import p "../palmy"

// ---------------------------------------------------------------------------
// Emoji sequences (palmy/emoji.odin, palmy/gsub.odin)
//
// A ZWJ sequence, a skin tone, a flag, a keycap and a tag flag are each one
// glyph of the colour font, reachable only through its GSUB table. Before
// emoji_compose these drew as their parts: "👍🏽" was a thumb and a brown
// swatch, two advances wide, and "🇫🇷" was two letters.
//
// The ids asserted here are not written down from HarfBuzz -- they depend on
// the font version -- but the full comparison was run: every fully- and
// minimally-qualified sequence and component in Unicode's emoji-test.txt
// (5,001 strings) plus six malformed ones, palmy's ids against `hb-shape`'s on
// NotoColorEmoji 2.047, and all 5,007 agreed once HarfBuzz's zero-width ZWJ
// glyph (which palmy folds into the glyph before it) was dropped.
// ---------------------------------------------------------------------------

// The sequences, one of each kind GSUB composes.
@(private = "file")
SEQUENCES := [?]struct {
	s:    string,
	what: string,
} {
	{"\U0001f468‍\U0001f4bb", "a profession (man, ZWJ, laptop)"},
	{"\U0001f469\U0001f3fd‍⚕️", "a profession with a skin tone and VS16"},
	{"\U0001f468‍\U0001f469‍\U0001f467‍\U0001f466", "a family of four"},
	{"\U0001f44d\U0001f3fd", "a skin-tone modifier"},
	{"✌\U0001f3fd", "a skin tone on a text-default base"},
	{"\U0001f1eb\U0001f1f7", "a flag"},
	{"\U0001f3f4\U000e0067\U000e0062\U000e0073\U000e0063\U000e0074\U000e007f", "a tag flag (Scotland)"},
	{"\U0001f3f3️‍\U0001f308", "the rainbow flag"},
	{"1️⃣", "a keycap"},
	{"\U0001f469‍❤️‍\U0001f468", "a couple, through a text-default heart"},
}

@(test)
test_emoji_sequences_compose :: proc(t: ^testing.T) {
	off := p.offscreen_create(10, 10)
	defer p.offscreen_destroy(off)
	f := &off.fonts
	if p.emoji_font_path(f) == "" {
		return // no colour emoji font installed
	}

	one := p.text_width(f, "\U0001f44d", 16)
	for c in SEQUENCES {
		gids := p.emoji_shape_glyphs(f, c.s, context.temp_allocator)
		testing.expectf(t, len(gids) == 1, "%s draws as one glyph, not %d (%v)", c.what, len(gids), gids)
		if len(gids) == 1 {
			testing.expectf(t, gids[0] != 0, "%s is drawn by the colour font", c.what)
		}
		// One glyph, one advance: the swatch and the second letter are gone
		// from the measurement too, which is what a caret and a wrap read.
		w := p.text_width(f, c.s, 16)
		testing.expectf(t, near(w, one, 0.01), "%s is one emoji wide: %.2f vs %.2f", c.what, w, one)
		widths_agree(t, off, c.s, c.what)
	}

	// The composed glyph is a different picture from the base: the tone was
	// applied, not dropped.
	base := p.emoji_shape_glyphs(f, "\U0001f44d", context.temp_allocator)
	toned := p.emoji_shape_glyphs(f, "\U0001f44d\U0001f3fd", context.temp_allocator)
	testing.expect(t, len(base) == 1 && len(toned) == 1 && base[0] != toned[0], "👍🏽 is not 👍")

	// What does not form a sequence stays apart, as a browser shows it.
	apart := [?]struct {
		s:    string,
		n:    int,
		what: string,
	} {
		{"\U0001f3fd", 1, "a lone modifier is its swatch"},
		{"\U0001f44d \U0001f3fd", 3, "a modifier after a space does not reach back"},
		{"\U0001f1eb\U0001f1f7\U0001f1e9\U0001f1ea\U0001f1eb", 3, "five indicators are two flags and a letter"},
		{"a\U0001f44d\U0001f3fdb", 3, "a toned thumb between letters"},
		{"\U0001f468‍\U0001f436", 2, "a ZWJ pair the font has no glyph for"},
	}
	for c in apart {
		gids := p.emoji_shape_glyphs(f, c.s, context.temp_allocator)
		testing.expectf(t, len(gids) == c.n, "%s: %d glyphs, wanted %d (%v)", c.what, len(gids), c.n, gids)
	}
}

// widths_agree is the half of assert_metrics_agree that holds for a sequence:
// measured and drawn advance agree. The other half, every rune boundary
// round-tripping through the hit test, deliberately does not -- a boundary
// inside a sequence is not a caret stop.
@(private = "file")
widths_agree :: proc(t: ^testing.T, off: ^p.Offscreen, text, what: string) {
	measured := p.text_width(&off.fonts, text, 16)
	drawn := p.draw_text(p.offscreen_canvas(off), &off.fonts, text, 0, 0, 16, p.WHITE)
	testing.expectf(t, near(measured, drawn, 0.01), "%s: text_width %.4f but draw_text advanced %.4f", what, measured, drawn)
}

// The composed glyph owns the whole sequence: the caret has no stop inside it
// and a click on either half lands on an edge of it.
@(test)
test_emoji_sequence_is_one_caret_unit :: proc(t: ^testing.T) {
	off := p.offscreen_create(10, 10)
	defer p.offscreen_destroy(off)
	f := &off.fonts
	if p.emoji_font_path(f) == "" {
		return
	}
	s := "a\U0001f469\U0001f3fd‍⚕️b"
	seq_start, seq_end := 1, len(s) - 1
	x0 := p.text_caret_x(f, s, seq_start, 16)
	x1 := p.text_caret_x(f, s, seq_end, 16)
	one := p.text_width(f, "\U0001f44d", 16)
	testing.expectf(t, near(x1 - x0, one, 0.01), "the sequence spans one advance (%.2f..%.2f)", x0, x1)

	left := p.text_index_at(f, s, 16, x0 + one * 0.25)
	right := p.text_index_at(f, s, 16, x0 + one * 0.75)
	testing.expectf(t, left == seq_start, "a click on the left half is before the sequence (%d)", left)
	testing.expectf(t, right == seq_end, "a click on the right half is after it (%d)", right)

	// Right to left, the sequence is reversed as a unit and still reads as one.
	rtl := "שלום \U0001f468‍\U0001f4bb עולם"
	gids := p.emoji_shape_glyphs(f, rtl, context.temp_allocator)
	emoji := 0
	for g in gids {
		if g != 0 {
			emoji += 1
		}
	}
	testing.expectf(t, emoji == 1, "a sequence in a Hebrew line is one glyph (%v)", gids)
	widths_agree(t, off, rtl, "a sequence in a right-to-left line")
}

// Drawn, a toned thumb is one emoji's worth of ink. Before composition it was
// two -- the hand and a brown square after it -- and this is the assertion
// that would have caught it.
@(test)
test_emoji_skin_tone_draws_no_swatch :: proc(t: ^testing.T) {
	ink_width :: proc(s: string) -> (w: int, ok: bool) {
		off := p.offscreen_create(160, 60, 1, "w-full h-full bg-white")
		defer p.offscreen_destroy(off)
		if p.emoji_font_path(&off.fonts) == "" {
			return 0, false
		}
		ui := p.offscreen_begin(off)
		p.text(ui, s, "text-[32] whitespace-nowrap")
		p.end(ui)
		p.offscreen_end(off)
		lo, hi := 160, -1
		for y in 0 ..< 60 {
			for x in 0 ..< 160 {
				c := p.offscreen_pixel(off, x, y)
				if int(c.r) + int(c.g) + int(c.b) < 3 * 235 {
					lo, hi = min(lo, x), max(hi, x)
				}
			}
		}
		return hi - lo + 1, hi >= 0
	}
	plain, ok := ink_width("\U0001f44d")
	if !ok {
		return
	}
	toned, _ := ink_width("\U0001f44d\U0001f3ff")
	testing.expectf(t, toned <= plain + 2, "a toned thumb is one emoji of ink (%d px) like a plain one (%d px)", toned, plain)
}
