package main

// A small fuzzy matcher: subsequence matching with the bonuses that make a
// ranked list feel right — a hit at the start of a word beats one in the
// middle, and a run of adjacent hits beats the same letters scattered.

MAX_HL :: 256

// Hit records which byte positions matched, so the row can pick them out.
Hit :: struct {
	bits: [MAX_HL / 64]u64,
}

hit_set :: proc(h: ^Hit, i: int) {
	if i >= 0 && i < MAX_HL {
		h.bits[i / 64] |= 1 << u64(i % 64)
	}
}

hit_at :: proc(h: Hit, i: int) -> bool {
	if i < 0 || i >= MAX_HL {
		return false
	}
	return h.bits[i / 64] & (1 << u64(i % 64)) != 0
}

hit_any :: proc(h: Hit) -> bool {
	for w in h.bits {
		if w != 0 {
			return true
		}
	}
	return false
}

is_sep :: proc(c: u8) -> bool {
	switch c {
	case ' ', '\t', '/', '\\', '-', '_', '.', ':', ',', ';', '(', ')', '[', ']', '{', '}', '"',
	     '\'', '=', '<', '>', '|', '@', '#':
		return true
	}
	return false
}

lower_byte :: proc(c: u8) -> u8 {
	return c >= 'A' && c <= 'Z' ? c + 32 : c
}

// fuzzy scores `needle` (already lowercase) against `hay`. An empty needle
// matches everything with score 0, which is what an empty search box means.
fuzzy :: proc(hay, needle: string) -> (score: int, h: Hit, ok: bool) {
	if needle == "" {
		return 0, {}, true
	}
	if len(needle) > len(hay) {
		return 0, {}, false
	}

	ni := 0
	prev_match := -2
	for i := 0; i < len(hay) && ni < len(needle); i += 1 {
		if lower_byte(hay[i]) != needle[ni] {
			continue
		}
		s := 10
		if i == 0 || is_sep(hay[i - 1]) {
			s += 24 // start of a word
		}
		if prev_match == i - 1 {
			s += 18 // adjacent to the previous hit
		}
		// Earlier is better, but only mildly, and never negative.
		s += max(0, 12 - i / 8)
		score += s
		hit_set(&h, i)
		prev_match = i
		ni += 1
	}
	if ni < len(needle) {
		return 0, {}, false
	}
	// A short haystack that matched everything is a better answer than a long
	// one that happened to contain the letters.
	score += max(0, 40 - len(hay) / 4)
	return score, h, true
}
