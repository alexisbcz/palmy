// Tokenizing: text into the terms the index stores and the query looks up.
//
// One rule for both sides, so a query and a document always agree on what a
// word is: a term is a run of letters and digits, lowercased, with the common
// Latin diacritics folded (é → e, ß → ss, ø → o), so "Théo" is found by
// typing "theo". Everything else separates terms: an address like
// priya.shah@northwind.coop is the terms priya, shah, northwind, coop. Han,
// kana and hangul have no spaces to split on, so each of their characters is
// a term of its own (unigrams: crude, but it finds things, and it is honest
// about being crude in cloud/docs/search.md).
//
// Terms longer than MAX_TERM bytes are dropped: they are hashes, base64 and
// URLs, never something a person types.
package indexcore

import "core:unicode"
import "core:unicode/utf8"

MAX_TERM :: 40

// fold maps one rune to its lowercase, accent-free form. It returns up to two
// runes (ß → ss, æ → ae, œ → oe); n is how many.
fold :: proc(r: rune) -> (a, b: rune, n: int) {
	switch r {
	case 'A' ..= 'Z':
		return r + 32, 0, 1
	case 'a' ..= 'z', '0' ..= '9':
		return r, 0, 1
	case 'À' ..= 'Å', 'à' ..= 'å', 'Ā' ..= 'ą':
		return 'a', 0, 1
	case 'Ç', 'ç', 'Ć' ..= 'č':
		return 'c', 0, 1
	case 'Ď' ..= 'đ':
		return 'd', 0, 1
	case 'È' ..= 'Ë', 'è' ..= 'ë', 'Ē' ..= 'ě':
		return 'e', 0, 1
	case 'Ĝ' ..= 'ģ':
		return 'g', 0, 1
	case 'Ĥ' ..= 'ħ':
		return 'h', 0, 1
	case 'Ì' ..= 'Ï', 'ì' ..= 'ï', 'Ĩ' ..= 'ı':
		return 'i', 0, 1
	case 'Ĵ', 'ĵ':
		return 'j', 0, 1
	case 'Ķ', 'ķ':
		return 'k', 0, 1
	case 'Ĺ' ..= 'ł':
		return 'l', 0, 1
	case 'Ñ', 'ñ', 'Ń' ..= 'ň':
		return 'n', 0, 1
	case 'Ò' ..= 'Ö', 'Ø', 'ò' ..= 'ö', 'ø', 'Ō' ..= 'ő':
		return 'o', 0, 1
	case 'Ŕ' ..= 'ř':
		return 'r', 0, 1
	case 'Ś' ..= 'š':
		return 's', 0, 1
	case 'Ţ' ..= 'ŧ':
		return 't', 0, 1
	case 'Ù' ..= 'Ü', 'ù' ..= 'ü', 'Ũ' ..= 'ų':
		return 'u', 0, 1
	case 'Ý', 'ý', 'ÿ', 'Ÿ':
		return 'y', 0, 1
	case 'Ź' ..= 'ž':
		return 'z', 0, 1
	case 'ß':
		return 's', 's', 2
	case 'Æ', 'æ':
		return 'a', 'e', 2
	case 'Œ', 'œ':
		return 'o', 'e', 2
	}
	if r < 0x80 {
		return 0, 0, 0 // ASCII punctuation and space separate terms
	}
	if unicode.is_letter(r) || unicode.is_digit(r) {
		return unicode.to_lower(r), 0, 1
	}
	return 0, 0, 0
}

// is_unigram says a rune is from a script written without spaces, which is
// indexed one character per term.
is_unigram :: proc(r: rune) -> bool {
	switch r {
	case 0x3040 ..= 0x30ff, 0x3400 ..= 0x4dbf, 0x4e00 ..= 0x9fff, 0xac00 ..= 0xd7af, 0xf900 ..= 0xfaff:
		return true
	}
	return false
}

// ASCII_FOLD maps an ASCII byte to its folded form, 0 for a separator.
ASCII_FOLD := #partial [128]u8 {
	'0' = '0', '1' = '1', '2' = '2', '3' = '3', '4' = '4', '5' = '5', '6' = '6', '7' = '7', '8' = '8', '9' = '9',
	'a' = 'a', 'b' = 'b', 'c' = 'c', 'd' = 'd', 'e' = 'e', 'f' = 'f', 'g' = 'g', 'h' = 'h', 'i' = 'i', 'j' = 'j',
	'k' = 'k', 'l' = 'l', 'm' = 'm', 'n' = 'n', 'o' = 'o', 'p' = 'p', 'q' = 'q', 'r' = 'r', 's' = 's', 't' = 't',
	'u' = 'u', 'v' = 'v', 'w' = 'w', 'x' = 'x', 'y' = 'y', 'z' = 'z',
	'A' = 'a', 'B' = 'b', 'C' = 'c', 'D' = 'd', 'E' = 'e', 'F' = 'f', 'G' = 'g', 'H' = 'h', 'I' = 'i', 'J' = 'j',
	'K' = 'k', 'L' = 'l', 'M' = 'm', 'N' = 'n', 'O' = 'o', 'P' = 'p', 'Q' = 'q', 'R' = 'r', 'S' = 's', 'T' = 't',
	'U' = 'u', 'V' = 'v', 'W' = 'w', 'X' = 'x', 'Y' = 'y', 'Z' = 'z',
}

// Tokenizer walks text and yields terms into a caller-owned buffer, so
// tokenizing allocates nothing per term. `start`/`end` are the byte offsets
// of the term in the original text, which is what snippets highlight.
Tokenizer :: struct {
	text:  string,
	pos:   int,
	buf:   [MAX_TERM * 2 + 8]u8,
	n:     int,
	start: int,
	end:   int,
}

tokenizer :: proc(text: string) -> Tokenizer {
	return Tokenizer{text = text}
}

// next_token returns the next term, valid until the following call.
next_token :: proc(t: ^Tokenizer) -> (term: string, ok: bool) {
	for t.pos < len(t.text) {
		t.n = 0
		t.start = -1
		t.end = -1
		too_long := false
		for t.pos < len(t.text) {
			c := t.text[t.pos]
			// ASCII fast path: most text is, and this loop is the indexer's
			// and the phrase check's hot path.
			if c < 0x80 {
				lc := ASCII_FOLD[c]
				if lc == 0 {
					if t.start >= 0 {
						t.end = t.pos
						t.pos += 1
						break
					}
					t.pos += 1
					continue
				}
				if t.start < 0 {
					t.start = t.pos
				}
				t.pos += 1
				if t.n < MAX_TERM {
					t.buf[t.n] = lc
					t.n += 1
				} else {
					too_long = true
				}
				continue
			}
			r: rune
			w := 1
			{
				r, w = utf8.decode_rune_in_string(t.text[t.pos:])
			}
			if is_unigram(r) {
				if t.start >= 0 {
					t.end = t.pos
					break // ends the word in progress; the unigram comes next
				}
				t.start = t.pos
				t.pos += w
				e, en := utf8.encode_rune(r)
				for i in 0 ..< en {
					t.buf[t.n] = e[i]
					t.n += 1
				}
				break
			}
			a, b, k := fold(r)
			if k == 0 {
				if t.start >= 0 {
					t.end = t.pos
					t.pos += w
					break
				}
				t.pos += w
				continue
			}
			if t.start < 0 {
				t.start = t.pos
			}
			t.pos += w
			for x, i in ([2]rune{a, b}) {
				if i >= k {
					break
				}
				if x < 0x80 {
					if t.n < MAX_TERM {
						t.buf[t.n] = u8(x)
						t.n += 1
					} else {
						too_long = true
					}
				} else {
					e, en := utf8.encode_rune(x)
					if t.n + en <= MAX_TERM {
						for j in 0 ..< en {
							t.buf[t.n] = e[j]
							t.n += 1
						}
					} else {
						too_long = true
					}
				}
			}
		}
		if t.start >= 0 && t.n > 0 && !too_long {
			if t.end < 0 {
				t.end = t.pos
			}
			return string(t.buf[:t.n]), true
		}
	}
	return "", false
}

// normalize folds a whole query word the way documents are folded, keeping
// only its first term. Used for operator values and prefixes.
normalize :: proc(word: string, allocator := context.temp_allocator) -> string {
	t := tokenizer(word)
	if term, ok := next_token(&t); ok {
		return clone_str(term, allocator)
	}
	return ""
}

clone_str :: proc(s: string, allocator := context.allocator) -> string {
	if len(s) == 0 {
		return ""
	}
	b := make([]u8, len(s), allocator)
	copy(b, s)
	return string(b)
}

// ---------------------------------------------------------------------------
// Varints: postings and stored fields are sequences of LEB128 integers.
// ---------------------------------------------------------------------------

put_uvarint :: proc(buf: ^[dynamic]u8, v: u64) {
	x := v
	for x >= 0x80 {
		append(buf, u8(x) | 0x80)
		x >>= 7
	}
	append(buf, u8(x))
}

get_uvarint :: #force_inline proc(data: []u8, pos: ^int) -> u64 {
	x: u64
	s: uint
	for {
		b := data[pos^]
		pos^ += 1
		if b < 0x80 {
			return x | u64(b) << s
		}
		x |= u64(b & 0x7f) << s
		s += 7
	}
}

// fnv64 hashes a document key; the hash is what the doc table stores, and
// what an update looks a document up by.
fnv64 :: proc(s: string) -> u64 {
	h: u64 = 0xcbf29ce484222325
	for i in 0 ..< len(s) {
		h ~= u64(s[i])
		h *= 0x100000001b3
	}
	return h
}
