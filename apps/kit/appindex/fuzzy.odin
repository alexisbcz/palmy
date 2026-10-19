package appindex

// Ranking.
//
// A launcher is judged almost entirely on the first row it offers, so the
// ranking is a cascade of increasingly weak kinds of match, each in its own
// score band: nothing scattered can ever outrank a prefix. Within a band the
// tie-breaks are length (a short name that matched is a better guess than a
// long one) and how often the entry has actually been launched.

import "core:strings"

// Hit records which bytes of a string the query landed on, so the row can draw
// the match. 128 bytes is far more than any application name needs.
Hit :: struct {
	mask: [2]u64,
}

hit_set :: proc(h: ^Hit, i: int) {
	if i >= 0 && i < 128 {
		h.mask[i / 64] |= 1 << u64(i % 64)
	}
}

hit_range :: proc(h: ^Hit, from, count: int) {
	for i in from ..< from + count {
		hit_set(h, i)
	}
}

hit_at :: proc(h: Hit, i: int) -> bool {
	if i < 0 || i >= 128 {
		return false
	}
	return h.mask[i / 64] & (1 << u64(i % 64)) != 0
}

hit_any :: proc(h: Hit) -> bool {
	return h.mask[0] != 0 || h.mask[1] != 0
}

Ranked :: struct {
	idx:   int, // index into the entry table
	score: int,
	name:  Hit,
	note:  Hit, // hits in the comment line
}

// Score bands. The gaps are wide enough that no tie-break can cross them.
BAND_PREFIX :: 900_000
BAND_WORD :: 700_000
BAND_SUB :: 500_000
BAND_ACRONYM :: 400_000
BAND_SEQ :: 250_000
BAND_NOTE :: 120_000
BAND_HAY :: 60_000

is_boundary :: proc(s: string, i: int) -> bool {
	if i == 0 {
		return true
	}
	c := s[i - 1]
	return c == ' ' || c == '-' || c == '_' || c == '.' || c == '/' || c == ':'
}

// subsequence_score walks the needle through the haystack greedily, rewarding
// runs and word starts the way every good fuzzy matcher does.
subsequence_score :: proc(hay, needle: string, h: ^Hit) -> (score: int, ok: bool) {
	hi, ni := 0, 0
	run := 0
	total := 0
	first := -1
	for ni < len(needle) && hi < len(hay) {
		if hay[hi] == needle[ni] {
			if first < 0 {
				first = hi
			}
			hit_set(h, hi)
			total += 8
			if run > 0 {
				total += 14 // consecutive
			}
			if is_boundary(hay, hi) {
				total += 12 // start of a word
			}
			run += 1
			ni += 1
		} else {
			run = 0
		}
		hi += 1
	}
	if ni < len(needle) {
		h^ = {}
		return 0, false
	}
	// A match that starts early is usually the one meant.
	total -= min(first, 20)
	return total, true
}

// acronym_match matches a query against the initials of each word, which is
// how "vsc" should find "Visual Studio Code".
acronym_match :: proc(hay, needle: string, h: ^Hit) -> bool {
	ni := 0
	for i in 0 ..< len(hay) {
		if ni >= len(needle) {
			break
		}
		if !is_boundary(hay, i) {
			continue
		}
		if hay[i] == needle[ni] {
			hit_set(h, i)
			ni += 1
		}
	}
	if ni < len(needle) {
		h^ = {}
		return false
	}
	return true
}

// rank_entry scores one entry against an already-lowercased query.
rank_entry :: proc(e: ^Entry, q: string) -> (r: Ranked, ok: bool) {
	// Frequently launched entries get a nudge that cannot jump a band.
	freq := min(e.uses, 30) * 120
	tie := freq - min(len(e.name), 60) * 60

	// With no query there is nothing to rank by but how often it has been
	// used; the sort is stable, so everything else stays alphabetical.
	if q == "" {
		return Ranked{score = freq * 4}, true
	}

	if strings.has_prefix(e.lower, q) {
		r.score = BAND_PREFIX + tie
		hit_range(&r.name, 0, len(q))
		return r, true
	}

	if idx := strings.index(e.lower, q); idx >= 0 {
		band := is_boundary(e.lower, idx) ? BAND_WORD : BAND_SUB
		r.score = band + tie - idx * 80
		hit_range(&r.name, idx, len(q))
		return r, true
	}

	if len(q) >= 2 && acronym_match(e.lower, q, &r.name) {
		r.score = BAND_ACRONYM + tie
		return r, true
	}

	if s, good := subsequence_score(e.lower, q, &r.name); good {
		r.score = BAND_SEQ + s * 300 + tie
		return r, true
	}

	// The name did not match. The comment is the next best thing to show,
	// and gets highlighted in its own line.
	if idx := strings.index(e.lcomment, q); idx >= 0 {
		r.score = BAND_NOTE + tie - idx * 40
		hit_range(&r.note, idx, len(q))
		return r, true
	}

	// Last resort: the Exec line, the categories, the desktop id. Nothing to
	// highlight, but the row is still a legitimate answer.
	if strings.contains(e.hay, q) {
		r.score = BAND_HAY + tie
		return r, true
	}

	return {}, false
}
