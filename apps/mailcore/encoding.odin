package main

// Content-Transfer-Encoding codecs and charset transcoding.
//
// Everything here is deliberately lenient on input and strict on output: a
// decoder that refuses malformed mail is useless, because malformed mail is
// most of what arrives. Every decoder in this file is total — it returns
// something for every input, never panics, never loops.

import "core:strings"
import "core:unicode/utf8"

// ---------------------------------------------------------------------------
// base64
// ---------------------------------------------------------------------------

@(rodata)
B64_ALPHA := [64]u8 {
	'A','B','C','D','E','F','G','H','I','J','K','L','M','N','O','P',
	'Q','R','S','T','U','V','W','X','Y','Z','a','b','c','d','e','f',
	'g','h','i','j','k','l','m','n','o','p','q','r','s','t','u','v',
	'w','x','y','z','0','1','2','3','4','5','6','7','8','9','+','/',
}

@(private = "file")
b64_rev: [256]i8

@(init)
b64_init :: proc "contextless" () {
	for i in 0 ..< 256 {
		b64_rev[i] = -1
	}
	for i in 0 ..< len(B64_ALPHA) {
		b64_rev[B64_ALPHA[i]] = i8(i)
	}
	// Accept the URL-safe alphabet too; some mailers get this wrong.
	b64_rev['-'] = 62
	b64_rev['_'] = 63
}

// base64_decode ignores every byte outside the alphabet (newlines, spaces,
// stray punctuation) and tolerates missing padding. A trailing group of one
// sextet carries no whole byte and is dropped.
base64_decode :: proc(src: []u8, allocator := context.allocator) -> []u8 {
	out := make([dynamic]u8, 0, len(src) * 3 / 4 + 3, allocator)
	acc: u32
	n := 0
	for ch in src {
		if ch == '=' {
			// Padding ends the current quantum. Flush what it carries.
			break
		}
		v := b64_rev[ch]
		if v < 0 {
			continue
		}
		acc = acc << 6 | u32(v)
		n += 1
		if n == 4 {
			append(&out, u8(acc >> 16), u8(acc >> 8), u8(acc))
			acc = 0
			n = 0
		}
	}
	switch n {
	case 3:
		acc <<= 6
		append(&out, u8(acc >> 16), u8(acc >> 8))
	case 2:
		acc <<= 12
		append(&out, u8(acc >> 16))
	case:
	// 0 is a whole quantum; 1 sextet is 6 bits and carries no byte.
	}
	return out[:]
}

// base64_encode wraps at `line_len` columns with CRLF. line_len <= 0 means a
// single unwrapped line (what IMAP/SMTP command arguments want).
base64_encode :: proc(src: []u8, line_len := 76, allocator := context.allocator) -> string {
	sb := strings.builder_make(allocator)
	col := 0
	emit :: proc(sb: ^strings.Builder, col: ^int, line_len: int, ch: u8) {
		if line_len > 0 && col^ >= line_len {
			strings.write_string(sb, "\r\n")
			col^ = 0
		}
		strings.write_byte(sb, ch)
		col^ += 1
	}
	i := 0
	for ; i + 2 < len(src); i += 3 {
		v := u32(src[i]) << 16 | u32(src[i + 1]) << 8 | u32(src[i + 2])
		emit(&sb, &col, line_len, B64_ALPHA[v >> 18 & 63])
		emit(&sb, &col, line_len, B64_ALPHA[v >> 12 & 63])
		emit(&sb, &col, line_len, B64_ALPHA[v >> 6 & 63])
		emit(&sb, &col, line_len, B64_ALPHA[v & 63])
	}
	switch len(src) - i {
	case 1:
		v := u32(src[i]) << 16
		emit(&sb, &col, line_len, B64_ALPHA[v >> 18 & 63])
		emit(&sb, &col, line_len, B64_ALPHA[v >> 12 & 63])
		emit(&sb, &col, line_len, '=')
		emit(&sb, &col, line_len, '=')
	case 2:
		v := u32(src[i]) << 16 | u32(src[i + 1]) << 8
		emit(&sb, &col, line_len, B64_ALPHA[v >> 18 & 63])
		emit(&sb, &col, line_len, B64_ALPHA[v >> 12 & 63])
		emit(&sb, &col, line_len, B64_ALPHA[v >> 6 & 63])
		emit(&sb, &col, line_len, '=')
	}
	return strings.to_string(sb)
}

@(rodata)
HEXU := [16]u8{'0','1','2','3','4','5','6','7','8','9','A','B','C','D','E','F'}

// ---------------------------------------------------------------------------
// quoted-printable
// ---------------------------------------------------------------------------

@(private = "file")
hexval :: proc(ch: u8) -> (v: u8, ok: bool) {
	switch ch {
	case '0' ..= '9':
		return ch - '0', true
	case 'a' ..= 'f':
		return ch - 'a' + 10, true
	case 'A' ..= 'F':
		return ch - 'A' + 10, true
	}
	return 0, false
}

// qp_decode handles the three things people get wrong:
//
//   - a soft line break, `=` at end of line, which vanishes along with the
//     CRLF (and we tolerate whitespace between the `=` and the CRLF, which
//     RFC 2045 5.2 calls a transport-damaged but recoverable encoding);
//   - `=XX` split across a line boundary is *not* valid, but `=` followed by
//     something that is not two hex digits must be passed through literally
//     rather than dropped;
//   - trailing whitespace before a hard line break was never really part of
//     the data, so it is stripped.
//
// `is_header` switches on RFC 2047 Q-encoding, where `_` means space.
qp_decode :: proc(src: []u8, is_header := false, allocator := context.allocator) -> []u8 {
	out := make([dynamic]u8, 0, len(src), allocator)
	// `protect` is the length of output that must not be trimmed: whitespace
	// that arrived as an explicit `=20` or `=09` was deliberate and is data,
	// while literal trailing whitespace was added by some transport and is
	// not. Conflating the two is how a quoted-printable round trip loses the
	// space at the end of a line.
	protect := 0
	strip_trailing_ws :: proc(out: ^[dynamic]u8, protect: int) {
		for len(out) > protect && (out[len(out) - 1] == ' ' || out[len(out) - 1] == '\t') {
			pop(out)
		}
	}
	for i := 0; i < len(src); {
		ch := src[i]
		switch {
		case ch == '_' && is_header:
			append(&out, ' ')
			i += 1
		case ch == '=':
			// Soft break: '=' [ \t]* (CRLF | LF | CR)
			j := i + 1
			for j < len(src) && (src[j] == ' ' || src[j] == '\t') {
				j += 1
			}
			if j < len(src) && (src[j] == '\r' || src[j] == '\n') {
				if src[j] == '\r' && j + 1 < len(src) && src[j + 1] == '\n' {
					j += 1
				}
				i = j + 1
				continue
			}
			// =XX
			if i + 2 < len(src) {
				hi, ok1 := hexval(src[i + 1])
				lo, ok2 := hexval(src[i + 2])
				if ok1 && ok2 {
					append(&out, hi << 4 | lo)
					protect = len(out)
					i += 3
					continue
				}
			}
			// Anything else: a literal '='. Degrade, do not drop.
			append(&out, '=')
			i += 1
		case ch == '\r':
			if is_header {
				i += 1
				continue
			}
			strip_trailing_ws(&out, protect)
			if i + 1 < len(src) && src[i + 1] == '\n' {
				append(&out, '\r', '\n')
				i += 2
			} else {
				append(&out, '\r')
				i += 1
			}
		case ch == '\n':
			if is_header {
				i += 1
				continue
			}
			strip_trailing_ws(&out, protect)
			append(&out, '\n')
			i += 1
		case:
			append(&out, ch)
			i += 1
		}
	}
	return out[:]
}

// qp_encode produces a body encoding: CRLF line endings preserved as hard
// breaks, soft breaks inserted to keep lines under 76 columns.
qp_encode :: proc(src: []u8, allocator := context.allocator) -> string {
	sb := strings.builder_make(allocator)
	col := 0
	// A line pending whitespace is held back so it can be hex-escaped if it
	// turns out to sit at the end of a line.
	put :: proc(sb: ^strings.Builder, col: ^int, s: string) {
		if col^ + len(s) > 75 {
			strings.write_string(sb, "=\r\n")
			col^ = 0
		}
		strings.write_string(sb, s)
		col^ += len(s)
	}
	for i := 0; i < len(src); i += 1 {
		ch := src[i]
		if ch == '\r' && i + 1 < len(src) && src[i + 1] == '\n' {
			strings.write_string(&sb, "\r\n")
			col = 0
			i += 1
			continue
		}
		if ch == '\n' {
			strings.write_string(&sb, "\r\n")
			col = 0
			continue
		}
		at_eol :=
			i + 1 >= len(src) ||
			src[i + 1] == '\n' ||
			(src[i + 1] == '\r' && i + 2 < len(src) && src[i + 2] == '\n')
		if (ch == ' ' || ch == '\t') && !at_eol {
			put(&sb, &col, ch == ' ' ? " " : "\t")
			continue
		}
		if ch >= 33 && ch <= 126 && ch != '=' {
			put(&sb, &col, strings.string_from_ptr(&src[i], 1))
			continue
		}
		buf := [3]u8{'=', HEXU[ch >> 4], HEXU[ch & 15]}
		put(&sb, &col, string(buf[:]))
	}
	return strings.to_string(sb)
}

// ---------------------------------------------------------------------------
// Charsets
// ---------------------------------------------------------------------------

// The charsets this engine transcodes. Everything else is handled by the
// `Unknown` rule documented on `charset_to_utf8`.
Charset :: enum u8 {
	Unknown,
	UTF8,
	ASCII,
	Latin1, // ISO-8859-1
	Latin9, // ISO-8859-15
	CP1252, // windows-1252
	Latin2, // ISO-8859-2
	KOI8R,
}

charset_from_name :: proc(name: string) -> Charset {
	n := strings.to_lower(name, context.temp_allocator)
	n = strings.trim_space(n)
	// RFC 2231 allows a language tag on an encoded-word charset: UTF-8*en.
	if star := strings.index_byte(n, '*'); star >= 0 {
		n = n[:star]
	}
	switch n {
	case "utf-8", "utf8", "unicode-1-1-utf-8", "csutf8":
		return .UTF8
	case "us-ascii", "ascii", "iso646-us", "ansi_x3.4-1968", "csascii":
		return .ASCII
	case "iso-8859-1", "iso8859-1", "iso_8859-1", "latin1", "l1", "cp819", "csisolatin1", "8859-1":
		return .Latin1
	case "iso-8859-15", "iso8859-15", "iso_8859-15", "latin9", "l9":
		return .Latin9
	case "windows-1252", "cp1252", "win-1252", "ms-ansi":
		return .CP1252
	case "iso-8859-2", "iso8859-2", "iso_8859-2", "latin2", "l2":
		return .Latin2
	case "koi8-r", "koi8r", "cskoi8r":
		return .KOI8R
	}
	return .Unknown
}

// The high halves of the single-byte charsets, as Unicode code points for
// bytes 0x80..0xFF. Latin1 is the identity and needs no table.
@(private = "file", rodata)
CP1252_HIGH := [32]rune {
	0x20AC, 0x81, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021,
	0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0x8D, 0x017D, 0x8F,
	0x90, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014,
	0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x9D, 0x017E, 0x0178,
}

@(private = "file", rodata)
LATIN2_HIGH := [128]rune {
	0x80, 0x81, 0x82, 0x83, 0x84, 0x85, 0x86, 0x87,
	0x88, 0x89, 0x8A, 0x8B, 0x8C, 0x8D, 0x8E, 0x8F,
	0x90, 0x91, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97,
	0x98, 0x99, 0x9A, 0x9B, 0x9C, 0x9D, 0x9E, 0x9F,
	0x00A0, 0x0104, 0x02D8, 0x0141, 0x00A4, 0x013D, 0x015A, 0x00A7,
	0x00A8, 0x0160, 0x015E, 0x0164, 0x0179, 0x00AD, 0x017D, 0x017B,
	0x00B0, 0x0105, 0x02DB, 0x0142, 0x00B4, 0x013E, 0x015B, 0x02C7,
	0x00B8, 0x0161, 0x015F, 0x0165, 0x017A, 0x02DD, 0x017E, 0x017C,
	0x0154, 0x00C1, 0x00C2, 0x0102, 0x00C4, 0x0139, 0x0106, 0x00C7,
	0x010C, 0x00C9, 0x0118, 0x00CB, 0x011A, 0x00CD, 0x00CE, 0x010E,
	0x0110, 0x0143, 0x0147, 0x00D3, 0x00D4, 0x0150, 0x00D6, 0x00D7,
	0x0158, 0x016E, 0x00DA, 0x0170, 0x00DC, 0x00DD, 0x0162, 0x00DF,
	0x0155, 0x00E1, 0x00E2, 0x0103, 0x00E4, 0x013A, 0x0107, 0x00E7,
	0x010D, 0x00E9, 0x0119, 0x00EB, 0x011B, 0x00ED, 0x00EE, 0x010F,
	0x0111, 0x0144, 0x0148, 0x00F3, 0x00F4, 0x0151, 0x00F6, 0x00F7,
	0x0159, 0x016F, 0x00FA, 0x0171, 0x00FC, 0x00FD, 0x0163, 0x02D9,
}

@(private = "file", rodata)
KOI8R_HIGH := [128]rune {
	0x2500, 0x2502, 0x250C, 0x2510, 0x2514, 0x2518, 0x251C, 0x2524,
	0x252C, 0x2534, 0x253C, 0x2580, 0x2584, 0x2588, 0x258C, 0x2590,
	0x2591, 0x2592, 0x2593, 0x2320, 0x25A0, 0x2219, 0x221A, 0x2248,
	0x2264, 0x2265, 0x00A0, 0x2321, 0x00B0, 0x00B2, 0x00B7, 0x00F7,
	0x2550, 0x2551, 0x2552, 0x0451, 0x2553, 0x2554, 0x2555, 0x2556,
	0x2557, 0x2558, 0x2559, 0x255A, 0x255B, 0x255C, 0x255D, 0x255E,
	0x255F, 0x2560, 0x2561, 0x0401, 0x2562, 0x2563, 0x2564, 0x2565,
	0x2566, 0x2567, 0x2568, 0x2569, 0x256A, 0x256B, 0x256C, 0x00A9,
	0x044E, 0x0430, 0x0431, 0x0446, 0x0434, 0x0435, 0x0444, 0x0433,
	0x0445, 0x0438, 0x0439, 0x043A, 0x043B, 0x043C, 0x043D, 0x043E,
	0x043F, 0x044F, 0x0440, 0x0441, 0x0442, 0x0443, 0x0436, 0x0432,
	0x044C, 0x044B, 0x0437, 0x0448, 0x044D, 0x0449, 0x0447, 0x044A,
	0x042E, 0x0410, 0x0411, 0x0426, 0x0414, 0x0415, 0x0424, 0x0413,
	0x0425, 0x0418, 0x0419, 0x041A, 0x041B, 0x041C, 0x041D, 0x041E,
	0x041F, 0x042F, 0x0420, 0x0421, 0x0422, 0x0423, 0x0416, 0x0412,
	0x042C, 0x042B, 0x0417, 0x0428, 0x042D, 0x0429, 0x0427, 0x042A,
}

// utf8_is_valid reports whether `b` is well-formed UTF-8: no overlongs, no
// surrogates, nothing past U+10FFFF.
utf8_is_valid :: proc(b: []u8) -> bool {
	i := 0
	for i < len(b) {
		c := b[i]
		switch {
		case c < 0x80:
			i += 1
		case c >= 0xC2 && c <= 0xDF:
			if i + 1 >= len(b) || b[i + 1] & 0xC0 != 0x80 {return false}
			i += 2
		case c == 0xE0:
			if i + 2 >= len(b) ||
			   b[i + 1] < 0xA0 ||
			   b[i + 1] > 0xBF ||
			   b[i + 2] & 0xC0 != 0x80 {return false}
			i += 3
		case c >= 0xE1 && c <= 0xEC, c == 0xEE, c == 0xEF:
			if i + 2 >= len(b) || b[i + 1] & 0xC0 != 0x80 || b[i + 2] & 0xC0 != 0x80 {return false}
			i += 3
		case c == 0xED:
			// Exclude the surrogate range U+D800..U+DFFF.
			if i + 2 >= len(b) ||
			   b[i + 1] < 0x80 ||
			   b[i + 1] > 0x9F ||
			   b[i + 2] & 0xC0 != 0x80 {return false}
			i += 3
		case c == 0xF0:
			if i + 3 >= len(b) ||
			   b[i + 1] < 0x90 ||
			   b[i + 1] > 0xBF ||
			   b[i + 2] & 0xC0 != 0x80 ||
			   b[i + 3] & 0xC0 != 0x80 {return false}
			i += 4
		case c >= 0xF1 && c <= 0xF3:
			if i + 3 >= len(b) ||
			   b[i + 1] & 0xC0 != 0x80 ||
			   b[i + 2] & 0xC0 != 0x80 ||
			   b[i + 3] & 0xC0 != 0x80 {return false}
			i += 4
		case c == 0xF4:
			if i + 3 >= len(b) ||
			   b[i + 1] < 0x80 ||
			   b[i + 1] > 0x8F ||
			   b[i + 2] & 0xC0 != 0x80 ||
			   b[i + 3] & 0xC0 != 0x80 {return false}
			i += 4
		case:
			return false
		}
	}
	return true
}

// utf8_sanitise replaces every malformed byte with U+FFFD, so downstream code
// (and the UI reading the Maildir) only ever sees valid UTF-8.
utf8_sanitise :: proc(b: []u8, allocator := context.allocator) -> string {
	if utf8_is_valid(b) {
		return strings.clone(string(b), allocator)
	}
	sb := strings.builder_make(allocator)
	i := 0
	for i < len(b) {
		// Try the longest valid sequence starting here.
		found := false
		for n in 1 ..= 4 {
			if i + n > len(b) {
				break
			}
			if utf8_is_valid(b[i:i + n]) {
				strings.write_bytes(&sb, b[i:i + n])
				i += n
				found = true
				break
			}
		}
		if !found {
			strings.write_rune(&sb, utf8.RUNE_ERROR)
			i += 1
		}
	}
	return strings.to_string(sb)
}

// charset_to_utf8 transcodes `data` from `cs` into UTF-8.
//
// The rule for `Unknown` — which is the only place a charset decision can be
// wrong — is: if the bytes are already valid UTF-8, keep them; otherwise treat
// them as ISO-8859-1, which is the only single-byte charset that cannot fail.
// The caller gets `lossy = true` so it can record a warning.
charset_to_utf8 :: proc(
	data: []u8,
	cs: Charset,
	allocator := context.allocator,
) -> (
	out: string,
	lossy: bool,
) {
	cs := cs
	if cs == .Unknown {
		if utf8_is_valid(data) {
			return strings.clone(string(data), allocator), false
		}
		cs = .Latin1
		lossy = true
	}

	switch cs {
	case .UTF8:
		return utf8_sanitise(data, allocator), !utf8_is_valid(data)
	case .ASCII:
		// 8-bit bytes in a us-ascii part are a lie; Latin1 them and say so.
		for ch in data {
			if ch >= 0x80 {
				s, _ := charset_to_utf8(data, .Latin1, allocator)
				return s, true
			}
		}
		return strings.clone(string(data), allocator), false
	case .Latin1:
		sb := strings.builder_make(allocator)
		for ch in data {
			if ch < 0x80 {
				strings.write_byte(&sb, ch)
			} else {
				strings.write_rune(&sb, rune(ch))
			}
		}
		return strings.to_string(sb), lossy
	case .Latin9:
		sb := strings.builder_make(allocator)
		for ch in data {
			switch ch {
			case 0xA4:
				strings.write_rune(&sb, 0x20AC)
			case 0xA6:
				strings.write_rune(&sb, 0x0160)
			case 0xA8:
				strings.write_rune(&sb, 0x0161)
			case 0xB4:
				strings.write_rune(&sb, 0x017D)
			case 0xB8:
				strings.write_rune(&sb, 0x017E)
			case 0xBC:
				strings.write_rune(&sb, 0x0152)
			case 0xBD:
				strings.write_rune(&sb, 0x0153)
			case 0xBE:
				strings.write_rune(&sb, 0x0178)
			case:
				if ch < 0x80 {
					strings.write_byte(&sb, ch)
				} else {
					strings.write_rune(&sb, rune(ch))
				}
			}
		}
		return strings.to_string(sb), lossy
	case .CP1252:
		sb := strings.builder_make(allocator)
		for ch in data {
			switch {
			case ch < 0x80:
				strings.write_byte(&sb, ch)
			case ch < 0xA0:
				strings.write_rune(&sb, CP1252_HIGH[ch - 0x80])
			case:
				strings.write_rune(&sb, rune(ch))
			}
		}
		return strings.to_string(sb), lossy
	case .Latin2:
		sb := strings.builder_make(allocator)
		for ch in data {
			if ch < 0x80 {
				strings.write_byte(&sb, ch)
			} else {
				strings.write_rune(&sb, LATIN2_HIGH[ch - 0x80])
			}
		}
		return strings.to_string(sb), lossy
	case .KOI8R:
		sb := strings.builder_make(allocator)
		for ch in data {
			if ch < 0x80 {
				strings.write_byte(&sb, ch)
			} else {
				strings.write_rune(&sb, KOI8R_HIGH[ch - 0x80])
			}
		}
		return strings.to_string(sb), lossy
	case .Unknown:
	// Handled above.
	}
	return strings.clone(string(data), allocator), true
}
