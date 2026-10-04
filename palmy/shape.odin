package palmy

import "core:strings"
import "core:unicode/utf8"

// ---------------------------------------------------------------------------
// Arabic text shaping.
//
// Arabic letters are cursive: a letter takes a different shape depending on
// whether it stands alone, joins the letter before it, the letter after it, or
// both. palmy draws one glyph per codepoint, so without this module Arabic
// comes out as a row of isolated forms -- recognisably Arabic, joined to
// nothing, and wrong in the way a word written with every letter in a box is
// wrong.
//
// THE ROUTE: PRESENTATION FORMS, NOT GSUB
//
// Unicode encodes the four positional shapes of every Arabic letter as
// distinct codepoints, in Arabic Presentation Forms-B (U+FE70..U+FEFF) and,
// for the Persian, Urdu and Sindhi letters, Presentation Forms-A
// (U+FB50..U+FBFF). So shaping can be done entirely in the codepoint domain:
// resolve each letter's position from its neighbours and substitute the
// codepoint for that position. The font then renders the result with no GSUB,
// no lookup machinery and no glyph-id plumbing -- `cmap` already maps those
// codepoints to the shaped glyphs, which was measured rather than assumed:
// NotoSansArabic-Regular covers 141 of the 144 slots in Forms-B (the three
// misses are unassigned) and 160 of 176 in Forms-A.
//
// The alternative was to parse GSUB and apply `init`/`medi`/`fina`/`isol`/
// `rlig`. That is the more correct answer and the only road to any other
// complex script, but it is a much larger piece of work, and on its own it is
// not enough: Arabic diacritics need GPOS mark attachment to sit in the right
// place, Devanagari needs matra reordering before GSUB even runs, and Thai
// needs mark positioning. A half-built GSUB engine would produce text that is
// wrong in ways that are hard to see, where this produces text that is right
// for the script it claims and visibly untouched for everything else.
//
// WHAT THIS DOES NOT DO
//
//   * No other complex script. Devanagari (matra reordering, conjuncts), Thai
//     and Lao (mark positioning), Khmer, Myanmar, Tibetan and Indic generally
//     are NOT shaped by this and are not improved by it. They still render as
//     one glyph per codepoint in logical order.
//   * No mark positioning. A harakat is preserved and drawn, but where it
//     lands is whatever the font's own advance says, not where GPOS would put
//     it. Fully vocalised Quranic text will have its vowels sitting low and
//     flat compared to a real shaper.
//   * No optional ligatures. lam-alef is formed because it is required; the
//     Forms-A ligature block (U+FC00..U+FDFF, including U+FDF2 Allah) is not,
//     because those are stylistic and a font may not carry them.
//   * Nothing font-specific. A font's own `rlig`, `calt`, swashes and the
//     cursive positioning that makes fine Naskh beautiful are out of reach.
//   * No bidi. This module works in logical order and does not reorder
//     anything; reordering is `bidi.odin`'s job. Shaping and reordering
//     commute here, because every joining decision is made from logical
//     neighbours.
//   * Text that is already shaped is left alone -- see `shape_arabic`. A
//     string that mixes presentation forms with unshaped letters will not
//     re-join across the boundary.
//
// THE RULES, which are the whole of the correctness argument:
//
//   * Each letter has a joining type (ArabicShaping.txt semantics):
//     dual-joining (D), right-joining (R), left-joining (L, which no Arabic
//     letter is -- it occurs in Mongolian and Syriac), join-causing (C:
//     tatweel and ZWJ), transparent (T: the harakat and every other Mn/Me/Cf)
//     or non-joining (U: everything else, including spaces, digits and Latin).
//   * A letter joins the character before it when that character can join
//     forward, i.e. its type is D, L or C. It joins the character after it
//     when that character can join backward, i.e. its type is D, R or C.
//   * A dual-joining letter with both takes MEDIAL, with only the one before
//     FINAL, with only the one after INITIAL, with neither ISOLATED.
//   * A right-joining letter (alef, dal, raa, zain, waw, ...) only ever takes
//     ISOLATED or FINAL: it cannot join forward. This is the rule that decides
//     whether Arabic looks right, because it means the letter *after* an alef
//     starts a fresh joining group however many letters follow.
//   * Transparent characters are skipped when looking at neighbours. A fatha
//     between two letters does not break the join -- it is invisible to it.
//   * lam followed by alef is a required ligature. The four encoded pairs
//     (U+FEF5..U+FEFC) are used; the ligature takes the final form when the
//     lam joins what precedes it and the isolated form otherwise.
//   * A space, a digit, a Latin letter or any other non-joining character
//     breaks the run, and so does ZWNJ.
//
// The tables are generated, not typed: see tools/arabic/gen-joining.py and the
// generated block at the bottom of this file.
// ---------------------------------------------------------------------------

// Joining_Type is a character's cursive joining behaviour, as
// ArabicShaping.txt defines it.
Joining_Type :: enum u8 {
	Non_Joining, // U -- breaks the run
	Right,       // R -- joins the character before it only
	Left,        // L -- joins the character after it only
	Dual,        // D -- joins both
	Causing,     // C -- joins both and has no shape of its own (tatweel, ZWJ)
	Transparent, // T -- invisible to joining (harakat, Mn/Me/Cf)
}

// Shape_Form is the positional form a letter takes. The order matches the
// `forms` array in the generated table and Unicode's own ordering of the
// presentation-form blocks.
Shape_Form :: enum u8 {
	Isolated,
	Final,
	Initial,
	Medial,
}

@(private)
Joining_Range :: struct {
	first, last: rune,
	jt:          Joining_Type,
}

@(private)
Arabic_Letter :: struct {
	base:  rune,
	forms: [4]rune, // indexed by Shape_Form; 0 where Unicode encodes no form
}

@(private)
Lam_Alef :: struct {
	alef:  rune,
	forms: [2]rune, // isolated, final
}

// Shaped_Rune is one output glyph and where it came from, which is what a
// caller needs to place a caret or map a hit back to a byte offset.
Shaped_Rune :: struct {
	cp:     rune,       // the codepoint to draw
	form:   Shape_Form, // the position resolved for it; Isolated when it has no form
	src:    int,        // byte offset of the first source rune it came from
	size:   int,        // number of source bytes it consumed (two runes for a ligature)
	shaped: bool,       // cp differs from the source codepoint
	lig:    bool,       // a lam-alef ligature, so `size` spans two letters
}

// Shape_Options exists for the two decisions a caller might reasonably want to
// make differently.
Shape_Options :: struct {
	// Form the required lam-alef ligature. Off leaves lam and alef as two
	// letters, which is legible but not correct Arabic.
	lam_alef: bool,
	// Use the Presentation Forms-A letter forms (U+FB50..U+FBFF), which are
	// what Persian, Urdu and Sindhi letters need. Noto's Arabic faces carry
	// them, but a font that has the base letters and not these would render
	// tofu, so it can be turned off; the letters then keep their base form.
	forms_a:  bool,
}

DEFAULT_SHAPE_OPTIONS :: Shape_Options {
	lam_alef = true,
	forms_a  = true,
}

// arabic_joining_type reports a character's joining behaviour. Everything
// outside the generated ranges -- Latin, digits, spaces, punctuation, CJK --
// is non-joining, which is exactly what breaks a joining run.
arabic_joining_type :: proc "contextless" (r: rune) -> Joining_Type {
	if r < 0x0600 {
		return .Non_Joining // the entire ASCII and Latin-1 fast path
	}
	lo, hi := 0, len(ARABIC_JOINING) - 1
	for lo <= hi {
		mid := (lo + hi) / 2
		e := ARABIC_JOINING[mid]
		switch {
		case r < e.first:
			hi = mid - 1
		case r > e.last:
			lo = mid + 1
		case:
			return e.jt
		}
	}
	return .Non_Joining
}

// arabic_shapable reports whether Unicode encodes any presentation form for a
// codepoint, i.e. whether shaping can change it. A presentation form itself is
// not shapable, which is what makes shaping idempotent.
arabic_shapable :: proc "contextless" (r: rune) -> bool {
	_, ok := arabic_letter(r)
	return ok
}

// arabic_presentation maps a base letter and a position to the codepoint
// Unicode encodes for that shape.
//
// When the exact form is not encoded the request falls back towards the
// isolated form -- medial to final to isolated, initial to isolated -- so a
// letter that has only two forms still joins on the side it can. `ok` is false
// only when the letter has no presentation forms at all.
arabic_presentation :: proc "contextless" (
	base: rune,
	form: Shape_Form,
	opts := DEFAULT_SHAPE_OPTIONS,
) -> (cp: rune, ok: bool) {
	letter, found := arabic_letter(base)
	if !found {
		return base, false
	}
	// The fallback chain for each requested form, most specific first.
	chain: []Shape_Form
	switch form {
	case .Medial:
		chain = {.Medial, .Final, .Isolated}
	case .Initial:
		chain = {.Initial, .Isolated}
	case .Final:
		chain = {.Final, .Isolated}
	case .Isolated:
		chain = {.Isolated}
	}
	for f in chain {
		c := letter.forms[f]
		if c == 0 {
			continue
		}
		if !opts.forms_a && c < 0xFE70 {
			continue // a Forms-A codepoint, which the caller has declined
		}
		return c, true
	}
	return base, false
}

// needs_arabic_shaping reports whether a string contains anything shaping can
// change. It is a cheap scan, and it is what lets a text path shape only the
// strings that need it and allocate nothing for the rest.
needs_arabic_shaping :: proc "contextless" (s: string) -> bool {
	// Walking the bytes is enough: every shapable letter is U+0620..U+06D3,
	// which in UTF-8 is a lead byte of 0xD8..0xDB.
	for i := 0; i < len(s); i += 1 {
		if s[i] < 0xD8 || s[i] > 0xDB {
			continue
		}
		r, _ := utf8.decode_rune_in_string(s[i:])
		if arabic_shapable(r) {
			return true
		}
	}
	return false
}

// shape_arabic returns `s` with every Arabic letter replaced by the
// presentation form for its position, in logical order, as a freshly allocated
// string the caller owns.
//
// Everything that is not an Arabic letter -- Latin, digits, punctuation,
// spaces, emoji, harakat, the presentation forms of an already-shaped string --
// is copied through unchanged, so the function is idempotent: shaping shaped
// text is a no-op. Call `needs_arabic_shaping` first to skip the allocation
// entirely for text that has no Arabic in it.
shape_arabic :: proc(
	s: string,
	opts := DEFAULT_SHAPE_OPTIONS,
	allocator := context.allocator,
) -> string {
	b := strings.builder_make(0, len(s) + 8, allocator)
	ctx := Shape_Ctx{}
	for {
		out, done := shape_step(s, &ctx, opts)
		if done {
			break
		}
		strings.write_rune(&b, out.cp)
	}
	return strings.to_string(b)
}

// shape_arabic_runes is `shape_arabic` with the decisions kept: one entry per
// output glyph, carrying the form that was chosen and the source bytes it came
// from. A caller that has to map a click or a caret back into the original
// string needs this rather than the string.
shape_arabic_runes :: proc(
	s: string,
	opts := DEFAULT_SHAPE_OPTIONS,
	allocator := context.allocator,
) -> []Shaped_Rune {
	out := make([dynamic]Shaped_Rune, 0, len(s) / 2 + 4, allocator)
	ctx := Shape_Ctx{}
	for {
		sr, done := shape_step(s, &ctx, opts)
		if done {
			break
		}
		append(&out, sr)
	}
	return out[:]
}

// ---------------------------------------------------------------------------
// The shaper
//
// One left-to-right pass over the logical string with no buffer: the joining
// type of the previous non-transparent character is carried in the state, and
// the next one is found by scanning forward over the transparent run. A
// lam-alef ligature is the only case that emits out of step with the input --
// it emits the ligature, then the harakat that stood between lam and alef, so
// no codepoint is ever lost.
// ---------------------------------------------------------------------------

@(private)
Shape_Ctx :: struct {
	i:       int,          // byte offset of the next source rune
	prev:    Joining_Type, // joining type of the last non-transparent character
	pending: int,          // bytes of transparent marks held back by a ligature
	pend_at: int,          // where that run starts
}

@(private)
shape_step :: proc(s: string, c: ^Shape_Ctx, opts: Shape_Options) -> (out: Shaped_Rune, done: bool) {
	// Marks held back while a lam-alef ligature was emitted come out next, in
	// their original order, unchanged.
	if c.pending > 0 {
		r, n := utf8.decode_rune_in_string(s[c.pend_at:])
		out = {cp = r, form = .Isolated, src = c.pend_at, size = n}
		c.pend_at += n
		c.pending -= n
		return out, false
	}
	if c.i >= len(s) {
		return {}, true
	}

	at := c.i
	r, n := utf8.decode_rune_in_string(s[at:])
	c.i = at + n
	jt := arabic_joining_type(r)

	// A transparent character is passed through and does not disturb the
	// joining state: the letters on either side of it still see each other.
	if jt == .Transparent {
		return Shaped_Rune{cp = r, form = .Isolated, src = at, size = n}, false
	}

	// Look ahead past any transparent run to the character that decides
	// whether this one joins forward.
	next_jt, next_r, next_at, next_n := arabic_next(s, c.i)
	joins_prev := c.prev == .Dual || c.prev == .Left || c.prev == .Causing
	joins_next := next_jt == .Dual || next_jt == .Right || next_jt == .Causing

	// lam + alef is required, and it swallows the alef and any harakat the two
	// letters had between them.
	if opts.lam_alef && r == ARABIC_LAM && next_n > 0 {
		if lig, found := arabic_lam_alef(next_r); found {
			form := joins_prev ? Shape_Form.Final : Shape_Form.Isolated
			cp := lig.forms[form == .Final ? 1 : 0]
			if cp != 0 {
				// The marks between lam and alef are queued; the next step
				// hands them back before it reads any more input.
				c.pend_at = c.i
				c.pending = next_at - c.i
				c.i = next_at + next_n
				// The alef ends the group: nothing after it can join back.
				c.prev = arabic_joining_type(next_r)
				return Shaped_Rune {
						cp = cp,
						form = form,
						src = at,
						size = (next_at + next_n) - at,
						shaped = true,
						lig = true,
					},
					false
			}
		}
	}

	c.prev = jt

	form := Shape_Form.Isolated
	switch jt {
	case .Dual:
		switch {
		case joins_prev && joins_next:
			form = .Medial
		case joins_prev:
			form = .Final
		case joins_next:
			form = .Initial
		}
	case .Right:
		// Joins backward only, so it never takes an initial or medial form --
		// and the letter after it cannot take one either, because `prev` is
		// now .Right and .Right is not in the joins-forward set.
		if joins_prev {
			form = .Final
		}
	case .Left:
		if joins_next {
			form = .Initial
		}
	case .Non_Joining, .Causing, .Transparent:
		// Nothing to shape: tatweel and ZWJ have no forms, and a non-joining
		// character is not Arabic.
		return Shaped_Rune{cp = r, form = .Isolated, src = at, size = n}, false
	}

	// An isolated letter is left as its own codepoint rather than swapped for
	// the isolated presentation form. The base codepoint already *is* the
	// isolated shape -- that is what the font's nominal glyph for it draws, and
	// it is what the font's own `isol` feature maps to. The legacy
	// presentation-form glyph can be a different drawing with different
	// metrics: in NotoSansArabic-Regular, U+0647 heh is 672 units wide and
	// U+FEE9 is 405. Substituting it would make a line of unjoined Arabic
	// narrower than the same line rendered by harfbuzz, for no gain.
	if form == .Isolated {
		return Shaped_Rune{cp = r, form = .Isolated, src = at, size = n}, false
	}
	if cp, ok := arabic_presentation(r, form, opts); ok {
		return Shaped_Rune{cp = cp, form = form, src = at, size = n, shaped = cp != r}, false
	}
	return Shaped_Rune{cp = r, form = form, src = at, size = n}, false
}

// arabic_next finds the first non-transparent character at or after `from`,
// which is the neighbour a joining decision is made against. A zero `n` means
// there is none and the run ends here.
@(private)
arabic_next :: proc "contextless" (s: string, from: int) -> (jt: Joining_Type, r: rune, at, n: int) {
	i := from
	for i < len(s) {
		rr, nn := utf8.decode_rune_in_string(s[i:])
		t := arabic_joining_type(rr)
		if t != .Transparent {
			return t, rr, i, nn
		}
		i += nn
	}
	return .Non_Joining, 0, len(s), 0
}

@(private)
arabic_letter :: proc "contextless" (r: rune) -> (letter: Arabic_Letter, ok: bool) {
	if r < ARABIC_FORMS_LO || r > ARABIC_FORMS_HI {
		return {}, false
	}
	lo, hi := 0, len(ARABIC_FORMS) - 1
	for lo <= hi {
		mid := (lo + hi) / 2
		e := ARABIC_FORMS[mid]
		switch {
		case r < e.base:
			hi = mid - 1
		case r > e.base:
			lo = mid + 1
		case:
			return e, true
		}
	}
	return {}, false
}

@(private)
arabic_lam_alef :: proc "contextless" (alef: rune) -> (lig: Lam_Alef, ok: bool) {
	for e in ARABIC_LAM_ALEF {
		if e.alef == alef {
			return e, true
		}
	}
	return {}, false
}

ARABIC_LAM :: rune(0x0644)

// BEGIN GENERATED -- do not edit by hand.
//
// tools/arabic/gen-joining.py, from Unicode 16.0.0 (python unicodedata) and
// libfribidi's ArabicShaping tables (Unicode 16.0.0). Regenerate with
//
//	python3 tools/arabic/gen-joining.py --splice
//
// 116 joining ranges, 76 shapable letters, 4 lam-alef ligatures.
// The generator cross-checks the two sources against each other with 1855
// assertions before emitting anything.

@(private)
ARABIC_JOINING := [?]Joining_Range {
	{0x0610, 0x061a, .Transparent},
	{0x061c, 0x061c, .Transparent},
	{0x0620, 0x0620, .Dual},
	{0x0622, 0x0625, .Right},
	{0x0626, 0x0626, .Dual},
	{0x0627, 0x0627, .Right},
	{0x0628, 0x0628, .Dual},
	{0x0629, 0x0629, .Right},
	{0x062a, 0x062e, .Dual},
	{0x062f, 0x0632, .Right},
	{0x0633, 0x063f, .Dual},
	{0x0640, 0x0640, .Causing},
	{0x0641, 0x0647, .Dual},
	{0x0648, 0x0648, .Right},
	{0x0649, 0x064a, .Dual},
	{0x064b, 0x065f, .Transparent},
	{0x066e, 0x066f, .Dual},
	{0x0670, 0x0670, .Transparent},
	{0x0671, 0x0673, .Right},
	{0x0675, 0x0677, .Right},
	{0x0678, 0x0687, .Dual},
	{0x0688, 0x0699, .Right},
	{0x069a, 0x06bf, .Dual},
	{0x06c0, 0x06c0, .Right},
	{0x06c1, 0x06c2, .Dual},
	{0x06c3, 0x06cb, .Right},
	{0x06cc, 0x06cc, .Dual},
	{0x06cd, 0x06cd, .Right},
	{0x06ce, 0x06ce, .Dual},
	{0x06cf, 0x06cf, .Right},
	{0x06d0, 0x06d1, .Dual},
	{0x06d2, 0x06d3, .Right},
	{0x06d5, 0x06d5, .Right},
	{0x06d6, 0x06dc, .Transparent},
	{0x06df, 0x06e4, .Transparent},
	{0x06e7, 0x06e8, .Transparent},
	{0x06ea, 0x06ed, .Transparent},
	{0x06ee, 0x06ef, .Right},
	{0x06fa, 0x06fc, .Dual},
	{0x06ff, 0x06ff, .Dual},
	{0x070f, 0x070f, .Transparent},
	{0x0710, 0x0710, .Right},
	{0x0711, 0x0711, .Transparent},
	{0x0712, 0x0714, .Dual},
	{0x0715, 0x0719, .Right},
	{0x071a, 0x071d, .Dual},
	{0x071e, 0x071e, .Right},
	{0x071f, 0x0727, .Dual},
	{0x0728, 0x0728, .Right},
	{0x0729, 0x0729, .Dual},
	{0x072a, 0x072a, .Right},
	{0x072b, 0x072b, .Dual},
	{0x072c, 0x072c, .Right},
	{0x072d, 0x072e, .Dual},
	{0x072f, 0x072f, .Right},
	{0x0730, 0x074a, .Transparent},
	{0x074d, 0x074d, .Right},
	{0x074e, 0x0758, .Dual},
	{0x0759, 0x075b, .Right},
	{0x075c, 0x076a, .Dual},
	{0x076b, 0x076c, .Right},
	{0x076d, 0x0770, .Dual},
	{0x0771, 0x0771, .Right},
	{0x0772, 0x0772, .Dual},
	{0x0773, 0x0774, .Right},
	{0x0775, 0x0777, .Dual},
	{0x0778, 0x0779, .Right},
	{0x077a, 0x077f, .Dual},
	{0x07a6, 0x07b0, .Transparent},
	{0x07ca, 0x07ea, .Dual},
	{0x07eb, 0x07f3, .Transparent},
	{0x07fa, 0x07fa, .Causing},
	{0x07fd, 0x07fd, .Transparent},
	{0x0816, 0x0819, .Transparent},
	{0x081b, 0x0823, .Transparent},
	{0x0825, 0x0827, .Transparent},
	{0x0829, 0x082d, .Transparent},
	{0x0840, 0x0840, .Right},
	{0x0841, 0x0845, .Dual},
	{0x0846, 0x0847, .Right},
	{0x0848, 0x0848, .Dual},
	{0x0849, 0x0849, .Right},
	{0x084a, 0x0853, .Dual},
	{0x0854, 0x0854, .Right},
	{0x0855, 0x0855, .Dual},
	{0x0856, 0x0858, .Right},
	{0x0859, 0x085b, .Transparent},
	{0x0860, 0x0860, .Dual},
	{0x0862, 0x0865, .Dual},
	{0x0867, 0x0867, .Right},
	{0x0868, 0x0868, .Dual},
	{0x0869, 0x086a, .Right},
	{0x0870, 0x0882, .Right},
	{0x0883, 0x0885, .Causing},
	{0x0886, 0x0886, .Dual},
	{0x0889, 0x088d, .Dual},
	{0x088e, 0x088e, .Right},
	{0x0897, 0x089f, .Transparent},
	{0x08a0, 0x08a9, .Dual},
	{0x08aa, 0x08ac, .Right},
	{0x08ae, 0x08ae, .Right},
	{0x08af, 0x08b0, .Dual},
	{0x08b1, 0x08b2, .Right},
	{0x08b3, 0x08b8, .Dual},
	{0x08b9, 0x08b9, .Right},
	{0x08ba, 0x08c8, .Dual},
	{0x08ca, 0x08e1, .Transparent},
	{0x08e3, 0x08ff, .Transparent},
	{0x200d, 0x200d, .Causing},
	{0x200e, 0x200f, .Transparent},
	{0x202a, 0x202e, .Transparent},
	{0x2060, 0x2064, .Transparent},
	{0x206a, 0x206f, .Transparent},
	{0xfe00, 0xfe0f, .Transparent},
	{0xfe20, 0xfe2f, .Transparent},
	{0xfeff, 0xfeff, .Transparent},
}

// One row per letter Unicode encodes a presentation form for, sorted by
// codepoint: {base, {isolated, final, initial, medial}}. A zero means that
// form is not encoded, and shaping falls back towards the isolated form.
@(private)
ARABIC_FORMS := [?]Arabic_Letter {
	{0x0621, {0xfe80, 0x0000, 0x0000, 0x0000}}, // ARABIC LETTER HAMZA
	{0x0622, {0xfe81, 0xfe82, 0x0000, 0x0000}}, // ARABIC LETTER ALEF WITH MADDA ABOVE
	{0x0623, {0xfe83, 0xfe84, 0x0000, 0x0000}}, // ARABIC LETTER ALEF WITH HAMZA ABOVE
	{0x0624, {0xfe85, 0xfe86, 0x0000, 0x0000}}, // ARABIC LETTER WAW WITH HAMZA ABOVE
	{0x0625, {0xfe87, 0xfe88, 0x0000, 0x0000}}, // ARABIC LETTER ALEF WITH HAMZA BELOW
	{0x0626, {0xfe89, 0xfe8a, 0xfe8b, 0xfe8c}}, // ARABIC LETTER YEH WITH HAMZA ABOVE
	{0x0627, {0xfe8d, 0xfe8e, 0x0000, 0x0000}}, // ARABIC LETTER ALEF
	{0x0628, {0xfe8f, 0xfe90, 0xfe91, 0xfe92}}, // ARABIC LETTER BEH
	{0x0629, {0xfe93, 0xfe94, 0x0000, 0x0000}}, // ARABIC LETTER TEH MARBUTA
	{0x062a, {0xfe95, 0xfe96, 0xfe97, 0xfe98}}, // ARABIC LETTER TEH
	{0x062b, {0xfe99, 0xfe9a, 0xfe9b, 0xfe9c}}, // ARABIC LETTER THEH
	{0x062c, {0xfe9d, 0xfe9e, 0xfe9f, 0xfea0}}, // ARABIC LETTER JEEM
	{0x062d, {0xfea1, 0xfea2, 0xfea3, 0xfea4}}, // ARABIC LETTER HAH
	{0x062e, {0xfea5, 0xfea6, 0xfea7, 0xfea8}}, // ARABIC LETTER KHAH
	{0x062f, {0xfea9, 0xfeaa, 0x0000, 0x0000}}, // ARABIC LETTER DAL
	{0x0630, {0xfeab, 0xfeac, 0x0000, 0x0000}}, // ARABIC LETTER THAL
	{0x0631, {0xfead, 0xfeae, 0x0000, 0x0000}}, // ARABIC LETTER REH
	{0x0632, {0xfeaf, 0xfeb0, 0x0000, 0x0000}}, // ARABIC LETTER ZAIN
	{0x0633, {0xfeb1, 0xfeb2, 0xfeb3, 0xfeb4}}, // ARABIC LETTER SEEN
	{0x0634, {0xfeb5, 0xfeb6, 0xfeb7, 0xfeb8}}, // ARABIC LETTER SHEEN
	{0x0635, {0xfeb9, 0xfeba, 0xfebb, 0xfebc}}, // ARABIC LETTER SAD
	{0x0636, {0xfebd, 0xfebe, 0xfebf, 0xfec0}}, // ARABIC LETTER DAD
	{0x0637, {0xfec1, 0xfec2, 0xfec3, 0xfec4}}, // ARABIC LETTER TAH
	{0x0638, {0xfec5, 0xfec6, 0xfec7, 0xfec8}}, // ARABIC LETTER ZAH
	{0x0639, {0xfec9, 0xfeca, 0xfecb, 0xfecc}}, // ARABIC LETTER AIN
	{0x063a, {0xfecd, 0xfece, 0xfecf, 0xfed0}}, // ARABIC LETTER GHAIN
	{0x0641, {0xfed1, 0xfed2, 0xfed3, 0xfed4}}, // ARABIC LETTER FEH
	{0x0642, {0xfed5, 0xfed6, 0xfed7, 0xfed8}}, // ARABIC LETTER QAF
	{0x0643, {0xfed9, 0xfeda, 0xfedb, 0xfedc}}, // ARABIC LETTER KAF
	{0x0644, {0xfedd, 0xfede, 0xfedf, 0xfee0}}, // ARABIC LETTER LAM
	{0x0645, {0xfee1, 0xfee2, 0xfee3, 0xfee4}}, // ARABIC LETTER MEEM
	{0x0646, {0xfee5, 0xfee6, 0xfee7, 0xfee8}}, // ARABIC LETTER NOON
	{0x0647, {0xfee9, 0xfeea, 0xfeeb, 0xfeec}}, // ARABIC LETTER HEH
	{0x0648, {0xfeed, 0xfeee, 0x0000, 0x0000}}, // ARABIC LETTER WAW
	{0x0649, {0xfeef, 0xfef0, 0xfbe8, 0xfbe9}}, // ARABIC LETTER ALEF MAKSURA
	{0x064a, {0xfef1, 0xfef2, 0xfef3, 0xfef4}}, // ARABIC LETTER YEH
	{0x0671, {0xfb50, 0xfb51, 0x0000, 0x0000}}, // ARABIC LETTER ALEF WASLA
	{0x0677, {0xfbdd, 0x0000, 0x0000, 0x0000}}, // ARABIC LETTER U WITH HAMZA ABOVE
	{0x0679, {0xfb66, 0xfb67, 0xfb68, 0xfb69}}, // ARABIC LETTER TTEH
	{0x067a, {0xfb5e, 0xfb5f, 0xfb60, 0xfb61}}, // ARABIC LETTER TTEHEH
	{0x067b, {0xfb52, 0xfb53, 0xfb54, 0xfb55}}, // ARABIC LETTER BEEH
	{0x067e, {0xfb56, 0xfb57, 0xfb58, 0xfb59}}, // ARABIC LETTER PEH
	{0x067f, {0xfb62, 0xfb63, 0xfb64, 0xfb65}}, // ARABIC LETTER TEHEH
	{0x0680, {0xfb5a, 0xfb5b, 0xfb5c, 0xfb5d}}, // ARABIC LETTER BEHEH
	{0x0683, {0xfb76, 0xfb77, 0xfb78, 0xfb79}}, // ARABIC LETTER NYEH
	{0x0684, {0xfb72, 0xfb73, 0xfb74, 0xfb75}}, // ARABIC LETTER DYEH
	{0x0686, {0xfb7a, 0xfb7b, 0xfb7c, 0xfb7d}}, // ARABIC LETTER TCHEH
	{0x0687, {0xfb7e, 0xfb7f, 0xfb80, 0xfb81}}, // ARABIC LETTER TCHEHEH
	{0x0688, {0xfb88, 0xfb89, 0x0000, 0x0000}}, // ARABIC LETTER DDAL
	{0x068c, {0xfb84, 0xfb85, 0x0000, 0x0000}}, // ARABIC LETTER DAHAL
	{0x068d, {0xfb82, 0xfb83, 0x0000, 0x0000}}, // ARABIC LETTER DDAHAL
	{0x068e, {0xfb86, 0xfb87, 0x0000, 0x0000}}, // ARABIC LETTER DUL
	{0x0691, {0xfb8c, 0xfb8d, 0x0000, 0x0000}}, // ARABIC LETTER RREH
	{0x0698, {0xfb8a, 0xfb8b, 0x0000, 0x0000}}, // ARABIC LETTER JEH
	{0x06a4, {0xfb6a, 0xfb6b, 0xfb6c, 0xfb6d}}, // ARABIC LETTER VEH
	{0x06a6, {0xfb6e, 0xfb6f, 0xfb70, 0xfb71}}, // ARABIC LETTER PEHEH
	{0x06a9, {0xfb8e, 0xfb8f, 0xfb90, 0xfb91}}, // ARABIC LETTER KEHEH
	{0x06ad, {0xfbd3, 0xfbd4, 0xfbd5, 0xfbd6}}, // ARABIC LETTER NG
	{0x06af, {0xfb92, 0xfb93, 0xfb94, 0xfb95}}, // ARABIC LETTER GAF
	{0x06b1, {0xfb9a, 0xfb9b, 0xfb9c, 0xfb9d}}, // ARABIC LETTER NGOEH
	{0x06b3, {0xfb96, 0xfb97, 0xfb98, 0xfb99}}, // ARABIC LETTER GUEH
	{0x06ba, {0xfb9e, 0xfb9f, 0x0000, 0x0000}}, // ARABIC LETTER NOON GHUNNA
	{0x06bb, {0xfba0, 0xfba1, 0xfba2, 0xfba3}}, // ARABIC LETTER RNOON
	{0x06be, {0xfbaa, 0xfbab, 0xfbac, 0xfbad}}, // ARABIC LETTER HEH DOACHASHMEE
	{0x06c0, {0xfba4, 0xfba5, 0x0000, 0x0000}}, // ARABIC LETTER HEH WITH YEH ABOVE
	{0x06c1, {0xfba6, 0xfba7, 0xfba8, 0xfba9}}, // ARABIC LETTER HEH GOAL
	{0x06c5, {0xfbe0, 0xfbe1, 0x0000, 0x0000}}, // ARABIC LETTER KIRGHIZ OE
	{0x06c6, {0xfbd9, 0xfbda, 0x0000, 0x0000}}, // ARABIC LETTER OE
	{0x06c7, {0xfbd7, 0xfbd8, 0x0000, 0x0000}}, // ARABIC LETTER U
	{0x06c8, {0xfbdb, 0xfbdc, 0x0000, 0x0000}}, // ARABIC LETTER YU
	{0x06c9, {0xfbe2, 0xfbe3, 0x0000, 0x0000}}, // ARABIC LETTER KIRGHIZ YU
	{0x06cb, {0xfbde, 0xfbdf, 0x0000, 0x0000}}, // ARABIC LETTER VE
	{0x06cc, {0xfbfc, 0xfbfd, 0xfbfe, 0xfbff}}, // ARABIC LETTER FARSI YEH
	{0x06d0, {0xfbe4, 0xfbe5, 0xfbe6, 0xfbe7}}, // ARABIC LETTER E
	{0x06d2, {0xfbae, 0xfbaf, 0x0000, 0x0000}}, // ARABIC LETTER YEH BARREE
	{0x06d3, {0xfbb0, 0xfbb1, 0x0000, 0x0000}}, // ARABIC LETTER YEH BARREE WITH HAMZA ABOVE
}

// The span of the letter table, so a string with no Arabic in it costs one
// comparison per rune and no search.
ARABIC_FORMS_LO :: rune(0x0621)
ARABIC_FORMS_HI :: rune(0x06d3)

// lam + alef is a required ligature. These four pairs are the only ones
// Unicode encodes a form for, and they are the only ones palmy forms.
@(private)
ARABIC_LAM_ALEF := [?]Lam_Alef {
	{0x0622, {0xfef5, 0xfef6}}, // lam + ARABIC LETTER ALEF WITH MADDA ABOVE
	{0x0623, {0xfef7, 0xfef8}}, // lam + ARABIC LETTER ALEF WITH HAMZA ABOVE
	{0x0625, {0xfef9, 0xfefa}}, // lam + ARABIC LETTER ALEF WITH HAMZA BELOW
	{0x0627, {0xfefb, 0xfefc}}, // lam + ARABIC LETTER ALEF
}

// END GENERATED
