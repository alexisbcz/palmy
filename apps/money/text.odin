// Reading a file a bank wrote.
//
// Two problems live here and both are real. The first is the encoding: a
// French bank's CSV export is as likely to be Windows-1252 as UTF-8, and
// `LIBELLÉ` in Latin-1 is a single byte 0xC9 that is not valid UTF-8 at all.
// Rendering it raw gives mojibake in the transaction list, so the bytes are
// sniffed and transcoded once, on the way in.
//
// The second is CSV itself: quoted fields containing the delimiter, doubled
// quotes inside a quoted field, CRLF line endings, a UTF-8 byte-order mark in
// front of the first header, and a few lines of preamble before the header
// row. Every one of those appears in a real export and every one of them is
// handled here rather than in the importer.
package main

import "core:strings"

// ---------------------------------------------------------------------------
// Encoding
// ---------------------------------------------------------------------------

Encoding :: enum {
	Auto,
	UTF8,
	Latin1, // ISO-8859-1 / Windows-1252
}

// utf8_valid is a full validation, not a heuristic: overlong forms,
// surrogates and truncated sequences are all rejected. A file that passes is
// UTF-8; one that fails is treated as Windows-1252, which is what the other
// possibility is in practice.
utf8_valid :: proc(s: string) -> bool {
	i := 0
	for i < len(s) {
		c := s[i]
		switch {
		case c < 0x80:
			i += 1
		case c >= 0xc2 && c <= 0xdf:
			if i + 1 >= len(s) || s[i + 1] & 0xc0 != 0x80 {
				return false
			}
			i += 2
		case c == 0xe0:
			if i + 2 >= len(s) || s[i + 1] < 0xa0 || s[i + 1] > 0xbf || s[i + 2] & 0xc0 != 0x80 {
				return false
			}
			i += 3
		case c >= 0xe1 && c <= 0xef:
			if i + 2 >= len(s) || s[i + 1] & 0xc0 != 0x80 || s[i + 2] & 0xc0 != 0x80 {
				return false
			}
			// U+D800..U+DFFF, the surrogates, are not characters.
			if c == 0xed && s[i + 1] >= 0xa0 {
				return false
			}
			i += 3
		case c >= 0xf0 && c <= 0xf4:
			if i + 3 >= len(s) {
				return false
			}
			if s[i + 1] & 0xc0 != 0x80 || s[i + 2] & 0xc0 != 0x80 || s[i + 3] & 0xc0 != 0x80 {
				return false
			}
			i += 4
		case:
			return false // 0x80..0xc1 and 0xf5..0xff are never a lead byte
		}
	}
	return true
}

// CP1252_HIGH is the 0x80..0x9F range, where Windows-1252 differs from
// ISO-8859-1 and where it keeps the characters a bank actually uses: the euro
// sign at 0x80 and the typographic quotes.
CP1252_HIGH := [32]rune {
	'€',
	0xFFFD,
	'‚',
	'ƒ',
	'„',
	'…',
	'†',
	'‡',
	'ˆ',
	'‰',
	'Š',
	'‹',
	'Œ',
	0xFFFD,
	'Ž',
	0xFFFD,
	0xFFFD,
	'\'',
	'\'',
	'"',
	'"',
	'•',
	'–',
	'—',
	'˜',
	'™',
	'š',
	'›',
	'œ',
	0xFFFD,
	'ž',
	'Ÿ',
}

// latin1_to_utf8 transcodes byte by byte. Every byte maps to exactly one
// rune, so this cannot fail and cannot lose data.
latin1_to_utf8 :: proc(s: string, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	strings.builder_grow(&b, len(s) + len(s) / 4)
	for i in 0 ..< len(s) {
		c := s[i]
		switch {
		case c < 0x80:
			strings.write_byte(&b, c)
		case c < 0xa0:
			strings.write_rune(&b, CP1252_HIGH[c - 0x80])
		case:
			strings.write_rune(&b, rune(c))
		}
	}
	return strings.to_string(b)
}

// decode_text normalises a file's bytes into UTF-8 text, dropping a
// byte-order mark if there is one. The returned string is always freshly
// allocated, so the caller frees one thing whichever branch was taken.
decode_text :: proc(
	raw: []u8,
	enc := Encoding.Auto,
	allocator := context.allocator,
) -> (
	text: string,
	used: Encoding,
) {
	s := string(raw)
	if strings.has_prefix(s, "\xef\xbb\xbf") {
		s = s[3:]
	}
	e := enc
	if e == .Auto {
		e = utf8_valid(s) ? .UTF8 : .Latin1
	}
	if e == .Latin1 {
		return latin1_to_utf8(s, allocator), .Latin1
	}
	return strings.clone(s, allocator), .UTF8
}

// ---------------------------------------------------------------------------
// CSV
// ---------------------------------------------------------------------------

// csv_split_line splits one physical record on a delimiter, honouring RFC
// 4180 quoting: a quoted field may contain the delimiter and a newline, and
// two quotes inside a quoted field mean one quote.
//
// It returns the fields and how many bytes of input it consumed, so the
// caller can step through a file where a field spans several lines.
csv_split_line :: proc(
	text: string,
	delim: u8,
	allocator := context.temp_allocator,
) -> (
	fields: []string,
	consumed: int,
) {
	out := make([dynamic]string, allocator)
	b := strings.builder_make(allocator)
	i := 0
	quoted := false
	for i < len(text) {
		c := text[i]
		if quoted {
			if c == '"' {
				if i + 1 < len(text) && text[i + 1] == '"' {
					strings.write_byte(&b, '"')
					i += 2
					continue
				}
				quoted = false
				i += 1
				continue
			}
			strings.write_byte(&b, c)
			i += 1
			continue
		}
		switch {
		case c == '"':
			quoted = true
			i += 1
		case c == delim:
			append(&out, strings.to_string(b))
			b = strings.builder_make(allocator)
			i += 1
		case c == '\r':
			i += 1
			if i < len(text) && text[i] == '\n' {
				i += 1
			}
			append(&out, strings.to_string(b))
			return out[:], i
		case c == '\n':
			i += 1
			append(&out, strings.to_string(b))
			return out[:], i
		case:
			strings.write_byte(&b, c)
			i += 1
		}
	}
	append(&out, strings.to_string(b))
	return out[:], i
}

Csv_Row :: struct {
	fields: []string,
	line:   int, // 1-based, for an error message that points at the file
}

// csv_rows splits a whole document. Empty records are dropped — a trailing
// newline is not a transaction — but their line numbers are still counted, so
// a complaint about line 214 means line 214 of the file.
csv_rows :: proc(text: string, delim: u8, allocator := context.temp_allocator) -> []Csv_Row {
	out := make([dynamic]Csv_Row, allocator)
	i := 0
	line := 1
	for i < len(text) {
		fields, n := csv_split_line(text[i:], delim, allocator)
		if n == 0 {
			break
		}
		// Count the newlines consumed, including any inside a quoted field.
		for k in i ..< i + n {
			if text[k] == '\n' {
				line += 1
			}
		}
		i += n
		blank := true
		for f in fields {
			if strings.trim_space(f) != "" {
				blank = false
				break
			}
		}
		if !blank {
			append(&out, Csv_Row{fields, line - 1})
		}
	}
	return out[:]
}

// csv_sniff_delimiter picks the separator. A French export is almost always
// `;`, because the decimal comma makes `,` unusable, but an export from a
// bank's English interface is `,` and a few are tab-separated.
//
// The test is not "which character is most common" — a label full of commas
// would win that. It is "which character gives the most rows the same field
// count", which is the property a delimiter has and a character inside a
// field does not.
csv_sniff_delimiter :: proc(text: string) -> u8 {
	best: u8 = ';'
	best_score := -1
	for d in ([?]u8{';', ',', '\t', '|'}) {
		counts := make(map[int]int, context.temp_allocator)
		rows := 0
		i := 0
		for i < len(text) && rows < 40 {
			fields, n := csv_split_line(text[i:], d, context.temp_allocator)
			if n == 0 {
				break
			}
			i += n
			if len(fields) > 1 {
				counts[len(fields)] += 1
				rows += 1
			}
		}
		// The score is the size of the largest agreeing group, weighted by
		// how many columns it has: a delimiter that finds four consistent
		// columns beats one that finds two.
		score := 0
		for ncols, n in counts {
			if n * ncols > score {
				score = n * ncols
			}
		}
		if score > best_score {
			best = d
			best_score = score
		}
	}
	return best
}

// header_norm reduces a header cell to something comparable: lower case, no
// accents, no punctuation, single spaces. `"Date de l'opération"` and
// `DATE OPERATION` both become `date de l operation` / `date operation`.
header_norm :: proc(s: string, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	space := true
	for r in s {
		c := r
		switch c {
		case 'à', 'â', 'ä', 'á', 'À', 'Â', 'Ä', 'Á':
			c = 'a'
		case 'é', 'è', 'ê', 'ë', 'É', 'È', 'Ê', 'Ë':
			c = 'e'
		case 'î', 'ï', 'Î', 'Ï':
			c = 'i'
		case 'ô', 'ö', 'Ô', 'Ö':
			c = 'o'
		case 'ù', 'û', 'ü', 'Ù', 'Û', 'Ü':
			c = 'u'
		case 'ç', 'Ç':
			c = 'c'
		}
		switch {
		case c >= 'A' && c <= 'Z':
			strings.write_rune(&b, c + 32)
			space = false
		case (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9'):
			strings.write_rune(&b, c)
			space = false
		case:
			if !space {
				strings.write_byte(&b, ' ')
				space = true
			}
		}
	}
	return strings.trim_space(strings.to_string(b))
}
