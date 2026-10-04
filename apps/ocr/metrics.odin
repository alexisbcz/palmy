package main

// Character and word error rates, which is how accuracy gets reported here
// rather than asserted.
//
// Both are edit distance over the normalised text, divided by the length of
// the *reference* — not of the output. That denominator is the convention and
// it matters: a recogniser that drops half the page would otherwise score
// well, because its own output is short and mostly right.
//
//   CER = (substitutions + insertions + deletions) / reference characters
//   WER = the same over whitespace-separated tokens
//
// Both can exceed 1.0, when the output is longer than the reference and wrong.
// That is not a bug in the metric; it is what a hallucinated page looks like.
//
// Normalisation before comparison is a judgement call, so it is stated:
// whitespace runs collapse to one space, and the Unicode quotes and dashes a
// recogniser produces for ASCII ones are folded back. Nothing else — case is
// significant, punctuation is significant, and a comma read as a full stop is
// counted as the error it is.

import "core:fmt"
import "core:strings"

// normalise_for_compare folds the differences that are not recognition
// errors. Keeping this small is the point: every fold here is accuracy the
// measurement is choosing not to see.
normalise_for_compare :: proc(s: string, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	sp := false
	for r in s {
		c := r
		switch r {
		case '\u2018', '\u2019', '\u02bc':
			c = '\''
		case '\u201c', '\u201d':
			c = '"'
		case '\u2013', '\u2014', '\u2010', '\u2011':
			c = '-'
		case '\u00a0':
			c = ' '
		}
		if c == ' ' || c == '\t' || c == '\n' || c == '\r' {
			sp = true
			continue
		}
		if sp && strings.builder_len(b) > 0 {
			strings.write_byte(&b, ' ')
		}
		sp = false
		strings.write_rune(&b, c)
	}
	return strings.to_string(b)
}

// edit_distance is Levenshtein over two integer sequences, with two rows
// instead of a full matrix. The sequences are runes for CER and interned
// word ids for WER, so one implementation serves both.
edit_distance :: proc(a, b: []int) -> int {
	if len(a) == 0 {return len(b)}
	if len(b) == 0 {return len(a)}
	prev := make([]int, len(b) + 1, context.temp_allocator)
	cur := make([]int, len(b) + 1, context.temp_allocator)
	for j in 0 ..= len(b) {
		prev[j] = j
	}
	for i in 1 ..= len(a) {
		cur[0] = i
		for j in 1 ..= len(b) {
			cost := a[i - 1] == b[j - 1] ? 0 : 1
			cur[j] = min(cur[j - 1] + 1, prev[j] + 1, prev[j - 1] + cost)
		}
		copy(prev, cur)
	}
	return prev[len(b)]
}

runes_of :: proc(s: string, allocator := context.temp_allocator) -> []int {
	out := make([dynamic]int, allocator)
	for r in s {
		append(&out, int(r))
	}
	return out[:]
}

// words_of interns each distinct token to an integer so the same edit
// distance works on words. The map lives in the temp allocator and dies with
// the measurement.
words_of :: proc(s: string, ids: ^map[string]int, allocator := context.temp_allocator) -> []int {
	out := make([dynamic]int, allocator)
	for tok in strings.fields(s, context.temp_allocator) {
		id, found := ids[tok]
		if !found {
			id = len(ids)
			ids[strings.clone(tok, context.temp_allocator)] = id
		}
		append(&out, id)
	}
	return out[:]
}

Error_Rates :: struct {
	cer:      f64,
	wer:      f64,
	chars:    int, // reference length
	words:    int,
	char_err: int,
	word_err: int,
}

// error_rates measures `got` against `want`.
error_rates :: proc(got, want: string) -> Error_Rates {
	g := normalise_for_compare(got, context.temp_allocator)
	w := normalise_for_compare(want, context.temp_allocator)

	gr := runes_of(g)
	wr := runes_of(w)
	ce := edit_distance(gr, wr)

	ids := make(map[string]int, 256, context.temp_allocator)
	gw := words_of(g, &ids)
	ww := words_of(w, &ids)
	we := edit_distance(gw, ww)

	return Error_Rates {
		cer = len(wr) == 0 ? (len(gr) == 0 ? 0 : 1) : f64(ce) / f64(len(wr)),
		wer = len(ww) == 0 ? (len(gw) == 0 ? 0 : 1) : f64(we) / f64(len(ww)),
		chars = len(wr),
		words = len(ww),
		char_err = ce,
		word_err = we,
	}
}

rates_line :: proc(r: Error_Rates, allocator := context.allocator) -> string {
	return fmt.aprintf(
		"CER %5.2f%%  WER %5.2f%%  (%d/%d chars, %d/%d words)",
		r.cer * 100,
		r.wer * 100,
		r.char_err,
		r.chars,
		r.word_err,
		r.words,
		allocator = allocator,
	)
}

// first_difference finds where two strings diverge, so a failure says what
// went wrong instead of printing two paragraphs and leaving the reader to
// diff them by eye.
first_difference :: proc(got, want: string, window := 40, allocator := context.allocator) -> string {
	g := normalise_for_compare(got, context.temp_allocator)
	w := normalise_for_compare(want, context.temp_allocator)
	if g == w {
		return strings.clone("", allocator)
	}
	n := min(len(g), len(w))
	i := 0
	for i < n && g[i] == w[i] {
		i += 1
	}
	lo := max(0, i - 12)
	ghi := min(len(g), i + window)
	whi := min(len(w), i + window)
	return fmt.aprintf(
		"at byte %d:\n      got  ...%s...\n      want ...%s...",
		i,
		g[lo:ghi],
		w[lo:whi],
		allocator = allocator,
	)
}
