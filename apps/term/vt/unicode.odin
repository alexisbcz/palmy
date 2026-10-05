package vt

// ---------------------------------------------------------------------------
// The Unicode layer: how wide a codepoint is, and which codepoints attach to
// the cell before them instead of claiming one of their own.
//
// Getting this wrong is not a cosmetic bug. A terminal that thinks a CJK
// ideograph is one cell wide will put the next character on top of it, and
// every subsequent line of that program's output is one column out.
// ---------------------------------------------------------------------------

// rune_width reports how many cells a codepoint occupies: 0, 1 or 2.
//
// Controls answer 1. That looks odd, but nothing ever asks for the width of a
// control -- the parser has already executed it -- and 1 is what libghostty
// answers, so the differential test has one less special case in it.
rune_width :: proc "contextless" (r: rune) -> int {
	cp := i32(r)
	if cp < 0 || cp > 0x10FFFF {
		return 1
	}
	// ASCII is the overwhelmingly common case and is never in the table.
	if cp < 0x0300 {
		return 1
	}
	lo, hi := 0, len(WIDTH_RUNS) - 1
	for lo <= hi {
		mid := (lo + hi) / 2
		run := WIDTH_RUNS[mid]
		switch {
		case cp < run[0]:
			hi = mid - 1
		case cp > run[1]:
			lo = mid + 1
		case:
			return int(run[2])
		}
	}
	return 1
}

// is_combining reports whether a codepoint joins the cell to its left rather
// than starting a new one. Zero width is the test, with the controls carved
// back out: a NUL is zero width in no useful sense.
is_combining :: proc "contextless" (r: rune) -> bool {
	if r < 0x20 || (r >= 0x7F && r < 0xA0) {
		return false
	}
	return rune_width(r) == 0
}

ZWJ :: rune(0x200D)
VS15 :: rune(0xFE0E)
VS16 :: rune(0xFE0F)

is_regional_indicator :: proc "contextless" (r: rune) -> bool {
	return r >= 0x1F1E6 && r <= 0x1F1FF
}

// is_emoji_modifier covers the five skin-tone modifiers, which follow a base
// emoji and must not take a cell of their own.
is_emoji_modifier :: proc "contextless" (r: rune) -> bool {
	return r >= 0x1F3FB && r <= 0x1F3FF
}

// ---------------------------------------------------------------------------
// UTF-8 decoding
//
// A terminal reads from a pipe, so a codepoint can be split across two reads.
// The decoder is therefore a small state machine that holds the partial
// sequence between calls, and it follows the WHATWG replacement policy: a
// malformed sequence produces exactly one U+FFFD and the offending byte is
// reconsidered, so `<80> A` prints a replacement and then an A rather than
// swallowing the A.
// ---------------------------------------------------------------------------

Utf8_Decoder :: struct {
	cp:        rune,
	remaining: int,
	lower:     u8, // the permitted range of the next continuation byte
	upper:     u8,
}

Utf8_Result :: enum u8 {
	Incomplete, // more bytes needed, nothing to emit
	Codepoint,  // `cp` is a decoded codepoint
	Invalid,    // emit U+FFFD, and feed this same byte again
	Invalid_Consumed, // emit U+FFFD; the byte was part of the bad sequence
}

utf8_reset :: proc "contextless" (d: ^Utf8_Decoder) {
	d^ = {}
}

// utf8_feed takes one byte and says what to do with it.
utf8_feed :: proc "contextless" (d: ^Utf8_Decoder, b: u8) -> (cp: rune, res: Utf8_Result) {
	if d.remaining == 0 {
		switch {
		case b <= 0x7F:
			return rune(b), .Codepoint
		case b >= 0xC2 && b <= 0xDF:
			d.cp = rune(b & 0x1F)
			d.remaining = 1
			d.lower, d.upper = 0x80, 0xBF
			return 0, .Incomplete
		case b >= 0xE0 && b <= 0xEF:
			d.cp = rune(b & 0x0F)
			d.remaining = 2
			// The tightened ranges reject overlong forms and surrogates
			// without a second pass over the decoded value.
			switch b {
			case 0xE0:
				d.lower, d.upper = 0xA0, 0xBF
			case 0xED:
				d.lower, d.upper = 0x80, 0x9F
			case:
				d.lower, d.upper = 0x80, 0xBF
			}
			return 0, .Incomplete
		case b >= 0xF0 && b <= 0xF4:
			d.cp = rune(b & 0x07)
			d.remaining = 3
			switch b {
			case 0xF0:
				d.lower, d.upper = 0x90, 0xBF
			case 0xF4:
				d.lower, d.upper = 0x80, 0x8F
			case:
				d.lower, d.upper = 0x80, 0xBF
			}
			return 0, .Incomplete
		case:
			// 0x80..0xC1 and 0xF5..0xFF can never start a sequence.
			return 0, .Invalid_Consumed
		}
	}

	if b < d.lower || b > d.upper {
		// The sequence is dead, but this byte may legitimately start a new
		// one, so it is handed back rather than eaten.
		utf8_reset(d)
		return 0, .Invalid
	}
	d.cp = (d.cp << 6) | rune(b & 0x3F)
	d.remaining -= 1
	d.lower, d.upper = 0x80, 0xBF
	if d.remaining == 0 {
		out := d.cp
		utf8_reset(d)
		return out, .Codepoint
	}
	return 0, .Incomplete
}

REPLACEMENT :: rune(0xFFFD)

// utf8_encode writes a codepoint into buf and returns how many bytes it used.
utf8_encode :: proc "contextless" (buf: []u8, r: rune) -> int {
	c := u32(r)
	switch {
	case c <= 0x7F:
		buf[0] = u8(c)
		return 1
	case c <= 0x7FF:
		buf[0] = 0xC0 | u8(c >> 6)
		buf[1] = 0x80 | u8(c & 0x3F)
		return 2
	case c <= 0xFFFF:
		buf[0] = 0xE0 | u8(c >> 12)
		buf[1] = 0x80 | u8((c >> 6) & 0x3F)
		buf[2] = 0x80 | u8(c & 0x3F)
		return 3
	case c <= 0x10FFFF:
		buf[0] = 0xF0 | u8(c >> 18)
		buf[1] = 0x80 | u8((c >> 12) & 0x3F)
		buf[2] = 0x80 | u8((c >> 6) & 0x3F)
		buf[3] = 0x80 | u8(c & 0x3F)
		return 4
	}
	return utf8_encode(buf, REPLACEMENT)
}
