package prose

// Readability formulas, and the honest framing they need.
//
// Every one of these was fitted in the middle of the twentieth century to a
// particular corpus — school textbooks graded by teachers, Navy training
// manuals, insurance policies — using two or three surface features, because
// two or three surface features were what you could count by hand. None of
// them reads. None of them knows whether a sentence is coherent, whether a
// word is used in its common sense, or whether the reader knows the subject.
// Flesch–Kincaid gives "Don't eat the brown mushrooms" a grade of 2 and
// "Ontological commitment is cheap" a grade of 9, and would be wrong about
// which one a nine-year-old can act on.
//
// They are still worth computing, for one reason: *relative* movement within
// one writer's own draft tracks something real. If a paragraph's grade is four
// above the rest of the document, that paragraph is doing something the others
// are not — usually a forty-word sentence. The number is a pointer, not a
// verdict.
//
// So the API returns a number and a band, and the UI is required to show the
// band. `band()` maps a grade to plain English; there is no code path that
// renders "grade 9.2" on its own, and `Report.caveat` carries the sentence
// that says what the number is not.

import "core:math"

Metric :: enum {
	Flesch_Reading_Ease,
	Flesch_Kincaid,
	Gunning_Fog,
	Coleman_Liau,
	Automated_Readability,
	SMOG,
}

METRIC_NAME := [Metric]string {
	.Flesch_Reading_Ease   = "Flesch Reading Ease",
	.Flesch_Kincaid        = "Flesch-Kincaid",
	.Gunning_Fog           = "Gunning Fog",
	.Coleman_Liau          = "Coleman-Liau",
	.Automated_Readability = "Automated Readability",
	.SMOG                  = "SMOG",
}

metric_from_name :: proc(s: string) -> (Metric, bool) {
	for m in Metric {
		if eq_fold(METRIC_NAME[m], s) {
			return m, true
		}
	}
	// The hyphenless and lowercase spellings rule files use.
	for m in Metric {
		if eq_fold(compact(METRIC_NAME[m]), compact(s)) {
			return m, true
		}
	}
	return .Flesch_Kincaid, false
}

@(private = "file")
compact :: proc(s: string, allocator := context.temp_allocator) -> string {
	b := make([dynamic]u8, 0, len(s), allocator)
	for i in 0 ..< len(s) {
		c := s[i]
		if c == ' ' || c == '-' || c == '_' {
			continue
		}
		append(&b, (c >= 'A' && c <= 'Z') ? c + 32 : c)
	}
	return string(b[:])
}

// Counts is everything the formulas need, gathered in one pass.
Counts :: struct {
	sentences:  int,
	words:      int,
	syllables:  int,
	letters:    int, // a-z only, which is what Coleman-Liau was fitted on
	chars:      int, // letters, digits and punctuation inside words, for ARI
	polysyl:    int, // three syllables or more
	long_words: int, // six letters or more
}

// counts_of gathers the statistics over a set of sentence spans.
counts_of :: proc(text: string, sents: []Span) -> (c: Counts) {
	for s in sents {
		ws := words(text, s.from, s.to, context.temp_allocator)
		if len(ws) == 0 {
			continue
		}
		c.sentences += 1
		for w in ws {
			tok := text[w.from:w.to]
			c.words += 1
			sy := syllables(tok)
			c.syllables += sy
			if sy >= 3 {
				c.polysyl += 1
			}
			nl := 0
			for i in 0 ..< len(tok) {
				ch := tok[i] | 32
				if ch >= 'a' && ch <= 'z' {
					nl += 1
				}
			}
			c.letters += nl
			c.chars += len(tok)
			if nl >= 6 {
				c.long_words += 1
			}
		}
	}
	return
}

// metric computes one formula. It returns `ok = false` when there is not
// enough text for the formula to mean anything, rather than a number from a
// division by a very small denominator.
metric_value :: proc(m: Metric, c: Counts) -> (value: f64, ok: bool) {
	if c.words < 1 || c.sentences < 1 {
		return 0, false
	}
	w := f64(c.words)
	s := f64(c.sentences)
	sy := f64(c.syllables)

	switch m {
	case .Flesch_Reading_Ease:
		return 206.835 - 1.015 * (w / s) - 84.6 * (sy / w), true
	case .Flesch_Kincaid:
		return 0.39 * (w / s) + 11.8 * (sy / w) - 15.59, true
	case .Gunning_Fog:
		return 0.4 * ((w / s) + 100.0 * (f64(c.polysyl) / w)), true
	case .Coleman_Liau:
		L := f64(c.letters) / w * 100.0
		S := s / w * 100.0
		return 0.0588 * L - 0.296 * S - 15.8, true
	case .Automated_Readability:
		return 4.71 * (f64(c.chars) / w) + 0.5 * (w / s) - 21.43, true
	case .SMOG:
		// Fitted on thirty-sentence samples. Below ten sentences the
		// extrapolation is not worth printing.
		if c.sentences < 3 {
			return 0, false
		}
		return 1.0430 * math.sqrt(f64(c.polysyl) * (30.0 / s)) + 3.1291, true
	}
	return 0, false
}

// band turns a US grade level into language that does not overclaim.
band :: proc(grade: f64) -> string {
	switch {
	case grade < 6:
		return "very easy — most readers, any age"
	case grade < 9:
		return "easy — a general audience"
	case grade < 12:
		return "moderate — a motivated general reader"
	case grade < 15:
		return "hard — expects a specialist reader"
	case grade < 18:
		return "very hard — academic or legal register"
	}
	return "extremely hard — few readers will finish it"
}

// ease_band does the same for Flesch Reading Ease, which runs the other way.
ease_band :: proc(ease: f64) -> string {
	switch {
	case ease >= 90:
		return "very easy"
	case ease >= 70:
		return "easy"
	case ease >= 60:
		return "plain"
	case ease >= 50:
		return "fairly hard"
	case ease >= 30:
		return "hard"
	}
	return "very hard"
}

CAVEAT ::
	"Readability formulas count syllables and sentence length. They were " +
	"fitted to other people's corpora and cannot tell whether a sentence is " +
	"clear. Treat a grade as a rough pointer, not a measurement."

// ---------------------------------------------------------------------------
// Reading time
// ---------------------------------------------------------------------------

// WPM_SILENT is the middle of the range meta-analyses report for adults
// reading non-fiction silently (Brysbaert 2019 puts it near 238). It is used
// for an estimate shown in minutes, never in seconds, because the spread
// between readers is wider than any precision a second would imply.
WPM_SILENT :: 238.0

reading_minutes :: proc(words_n: int) -> f64 {
	return f64(words_n) / WPM_SILENT
}
