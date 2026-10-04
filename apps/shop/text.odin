// French text handling: folding accents away, and matching a query against a
// product name the way a shopper expects.
//
// Someone typing in a hurry types `creme`, not `crème`, and `yaourts` rather
// than `yaourt`. A search that misses "Crème fraîche épaisse" because the user
// did not reach for the accent key is a broken search, so every comparison in
// this application runs over a folded form: accents stripped, case folded,
// ligatures expanded, punctuation reduced to spaces. The folded form is
// computed once per product when the catalogue is built and kept next to it,
// because folding six thousand titles on every keystroke is exactly the kind
// of per-frame work that makes a list stutter.
package main

import "core:strings"

// fold_rune maps one rune to its ASCII skeleton. The Latin-1 Supplement and
// the parts of Latin Extended-A that French, and the brand names on a French
// shelf, actually use. A rune with no mapping is returned unchanged.
fold_rune :: proc(r: rune) -> (rune, rune) {
	switch r {
	case 'A' ..= 'Z':
		return r + 32, 0
	case 'À', 'Á', 'Â', 'Ã', 'Ä', 'Å':
		return 'a', 0
	case 'à', 'á', 'â', 'ã', 'ä', 'å':
		return 'a', 0
	case 'Æ':
		return 'a', 'e'
	case 'æ':
		return 'a', 'e'
	case 'Ç', 'ç':
		return 'c', 0
	case 'È', 'É', 'Ê', 'Ë':
		return 'e', 0
	case 'è', 'é', 'ê', 'ë':
		return 'e', 0
	case 'Ì', 'Í', 'Î', 'Ï':
		return 'i', 0
	case 'ì', 'í', 'î', 'ï':
		return 'i', 0
	case 'Ñ', 'ñ':
		return 'n', 0
	case 'Ò', 'Ó', 'Ô', 'Õ', 'Ö', 'Ø':
		return 'o', 0
	case 'ò', 'ó', 'ô', 'õ', 'ö', 'ø':
		return 'o', 0
	case 'Œ':
		return 'o', 'e'
	case 'œ':
		return 'o', 'e'
	case 'Ù', 'Ú', 'Û', 'Ü':
		return 'u', 0
	case 'ù', 'ú', 'û', 'ü':
		return 'u', 0
	case 'Ý', 'Ÿ', 'ý', 'ÿ':
		return 'y', 0
	case 'ß':
		return 's', 's'
	case '\u2019', '\u2018', '\'', '`', '\u00b4':
		// An apostrophe joins words in French — "l'eau", "Classic'" — and a
		// query will not reproduce the typographic one, so it becomes a space
		// and the tokens either side stand on their own.
		return ' ', 0
	case '\u00a0', '\u202f', '\u2009':
		return ' ', 0
	}
	return r, 0
}

// fold returns the search skeleton of a string: lower case, no accents, every
// run of non-alphanumeric reduced to one space, trimmed.
fold :: proc(s: string, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	strings.builder_grow(&b, len(s))
	pending_space := false
	for r in s {
		a, extra := fold_rune(r)
		for ch in ([?]rune{a, extra}) {
			if ch == 0 {
				continue
			}
			keep := (ch >= 'a' && ch <= 'z') || (ch >= '0' && ch <= '9')
			if keep {
				if pending_space && strings.builder_len(b) > 0 {
					strings.write_rune(&b, ' ')
				}
				pending_space = false
				strings.write_rune(&b, ch)
			} else {
				pending_space = true
			}
		}
	}
	return strings.to_string(b)
}

// singular drops the French plural marks a shopper types without thinking:
// a trailing `s` or `x` on a word of four letters or more. It is a heuristic
// and it is applied to both sides of every comparison, so `yaourts` matches
// `yaourt` and `yaourt` matches `yaourts`; what it must never do is collapse
// two different products, which is why it leaves short words alone (`jus`,
// `bas`, `riz`, `pois`).
singular :: proc(w: string) -> string {
	if len(w) < 5 {
		return w
	}
	if strings.has_suffix(w, "eaux") {
		// gateaux -> gateau
		return w[:len(w) - 1]
	}
	last := w[len(w) - 1]
	if last == 's' || last == 'x' {
		return w[:len(w) - 1]
	}
	return w
}

// token_matches is one query word against one haystack word: a prefix match on
// the singular forms, so `crem` finds `creme` and `cremes` finds `creme`.
token_matches :: proc(hay_word, needle: string) -> bool {
	if needle == "" {
		return true
	}
	if strings.has_prefix(hay_word, needle) {
		return true
	}
	h := singular(hay_word)
	n := singular(needle)
	return strings.has_prefix(h, n)
}

// matches_query answers whether a folded haystack satisfies a folded query:
// every query token must match the start of some word in the haystack, in any
// order. That is what people expect from a shop search — `lait demi` finds
// "Lait demi-écrémé" — and it is cheap enough to run over the whole catalogue
// on every keystroke.
matches_query :: proc(hay_folded: string, query_folded: string) -> bool {
	if query_folded == "" {
		return true
	}
	q := query_folded
	for {
		q = strings.trim_left_space(q)
		if q == "" {
			break
		}
		end := strings.index_byte(q, ' ')
		tok: string
		if end < 0 {
			tok = q
			q = ""
		} else {
			tok = q[:end]
			q = q[end + 1:]
		}
		if tok == "" {
			continue
		}
		if !word_in(hay_folded, tok) {
			return false
		}
	}
	return true
}

// word_in walks the haystack's words looking for one the token matches.
word_in :: proc(hay: string, tok: string) -> bool {
	rest := hay
	for {
		rest = strings.trim_left_space(rest)
		if rest == "" {
			return false
		}
		end := strings.index_byte(rest, ' ')
		w: string
		if end < 0 {
			w = rest
			rest = ""
		} else {
			w = rest[:end]
			rest = rest[end + 1:]
		}
		if token_matches(w, tok) {
			return true
		}
	}
	return false
}

// ---------------------------------------------------------------------------
// Title normalisation, for matching the same product across retailers
// ---------------------------------------------------------------------------

// Words that carry no identity: they are packaging, marketing or the quantity
// itself, and two retailers will not agree on them.
@(private = "file")
NOISE := [?]string {
	"lot", "de", "du", "des", "le", "la", "les", "l", "d", "en", "au", "aux",
	"et", "x", "pack", "paquet", "boite", "bouteille", "brique", "pot", "sachet",
	"barquette", "filet", "flacon", "bidon", "promo", "format", "familial",
	"nouveau", "nouvelle", "offre", "speciale", "pur", "pure",
}

@(private = "file")
is_noise :: proc(w: string) -> bool {
	for n in NOISE {
		if w == n {
			return true
		}
	}
	return false
}

@(private = "file")
all_digits :: proc(w: string) -> bool {
	if w == "" {
		return false
	}
	for i in 0 ..< len(w) {
		if w[i] < '0' || w[i] > '9' {
			return false
		}
	}
	return true
}

@(private = "file")
is_unit_word :: proc(w: string) -> bool {
	switch w {
	case "g", "kg", "mg", "l", "ml", "cl", "dl", "cc", "tranches", "tranche",
	     "pieces", "piece", "unites", "unite", "capsules", "dosettes", "oeufs",
	     "rouleaux", "sachets", "portions", "portion":
		return true
	}
	return false
}

// match_key is the identity of a product when no GTIN is available: the folded
// title with the quantity, the units and the packaging words removed, the
// remaining words sorted so word order between two retailers does not matter,
// and the brand folded in front. "Lait demi-écrémé UHT 1 L - lot de 6" and
// "UHT lait demi écrémé (6x1L)" reduce to the same key.
//
// Sorting the words is what makes it symmetric; keeping digits out is what
// makes a 500 g jar and a 750 g jar share a key, which is exactly what the
// comparison view wants, because it prices them per kilo afterwards.
match_key :: proc(brand, title: string, allocator := context.allocator) -> string {
	ft := fold(title, context.temp_allocator)
	fb := fold(brand, context.temp_allocator)

	words := make([dynamic]string, context.temp_allocator)
	rest := ft
	for {
		rest = strings.trim_left_space(rest)
		if rest == "" {
			break
		}
		end := strings.index_byte(rest, ' ')
		w: string
		if end < 0 {
			w = rest
			rest = ""
		} else {
			w = rest[:end]
			rest = rest[end + 1:]
		}
		if w == "" || is_noise(w) || all_digits(w) || is_unit_word(w) {
			continue
		}
		// A glued quantity like "33cl" or "500g".
		if len(w) > 1 && w[0] >= '0' && w[0] <= '9' {
			continue
		}
		append(&words, singular(w))
	}

	// Insertion sort: the lists are a handful of words long.
	for i in 1 ..< len(words) {
		j := i
		for j > 0 && words[j - 1] > words[j] {
			words[j - 1], words[j] = words[j], words[j - 1]
			j -= 1
		}
	}
	// Drop neighbouring duplicates, which the sort has made adjacent.
	b := strings.builder_make(allocator)
	if fb != "" {
		strings.write_string(&b, fb)
		strings.write_byte(&b, '|')
	}
	prev := ""
	for w in words {
		if w == prev {
			continue
		}
		if prev != "" {
			strings.write_byte(&b, ' ')
		}
		strings.write_string(&b, w)
		prev = w
	}
	return strings.to_string(b)
}

// ---------------------------------------------------------------------------
// EAN-13
// ---------------------------------------------------------------------------

// ean13_valid checks the check digit. The comparison view groups products on
// GTIN, so a mistyped barcode in an imported feed must not be allowed to merge
// two unrelated products; a number that fails the checksum is treated as if it
// had no GTIN at all and falls back to the title key.
ean13_valid :: proc(s: string) -> bool {
	if len(s) != 13 {
		return false
	}
	sum := 0
	for i in 0 ..< 12 {
		c := s[i]
		if c < '0' || c > '9' {
			return false
		}
		d := int(c - '0')
		sum += i % 2 == 0 ? d : 3 * d
	}
	if s[12] < '0' || s[12] > '9' {
		return false
	}
	check := (10 - sum % 10) % 10
	return int(s[12] - '0') == check
}

// ean13_check_digit computes the 13th digit of a 12-digit body, which is how
// the fixture builds barcodes that validate.
ean13_check_digit :: proc(body12: string) -> (u8, bool) {
	if len(body12) != 12 {
		return 0, false
	}
	sum := 0
	for i in 0 ..< 12 {
		c := body12[i]
		if c < '0' || c > '9' {
			return 0, false
		}
		d := int(c - '0')
		sum += i % 2 == 0 ? d : 3 * d
	}
	return u8('0' + (10 - sum % 10) % 10), true
}

// utf8_truncate cuts a string to at most n runes, appending an ellipsis when
// it had to cut. Byte slicing a French title is how you get a mojibake
// half-rune on screen.
utf8_truncate :: proc(s: string, n: int, allocator := context.allocator) -> string {
	count := 0
	for _ in s {
		count += 1
	}
	if count <= n {
		return strings.clone(s, allocator)
	}
	b := strings.builder_make(allocator)
	i := 0
	for r in s {
		if i >= n - 1 {
			break
		}
		strings.write_rune(&b, r)
		i += 1
	}
	strings.write_string(&b, "…")
	return strings.to_string(b)
}

