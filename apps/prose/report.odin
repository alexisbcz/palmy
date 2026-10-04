package prose

// The writing report.
//
// Of everything in this feature, the part that changes how somebody writes is
// not the inline marks — it is the list of what they do repeatedly. A writer
// who sees "utilize" underlined fixes that word. A writer who sees "this note
// hedges nine times" stops hedging.
//
// So the report has four parts, in descending order of how much they are
// worth: the recurring issues, the sentence-length shape, the readability
// estimates with their caveat attached, and the raw counts.

import "core:math"
import "core:slice"
import "core:strings"

Issue_Tally :: struct {
	rule:  string,
	n:     int,
	sev:   Severity,
	first: int, // byte offset of the first instance, so the UI can jump there
	fix:   bool, // at least one instance offers a rewrite
}

Grade :: struct {
	metric: Metric,
	value:  f64,
	band:   string,
	ok:     bool,
}

Opener :: struct {
	word: string,
	n:    int,
}

Report :: struct {
	words:       int,
	sentences:   int,
	paragraphs:  int,
	syllables:   int,
	minutes:     f64,
	grades:      []Grade,
	grade_mean:  f64, // the mean of the grade-level metrics, excluding ease
	grade_ok:    bool,
	ease:        f64,
	ease_ok:     bool,
	caveat:      string,

	// sentence shape
	len_min:     int,
	len_max:     int,
	len_mean:    f64,
	len_median:  int,
	len_sd:      f64, // the variance writers are told to want
	buckets:     [6]int, // <=10, 11-15, 16-20, 21-25, 26-35, 36+
	longest_at:  int, // byte offset of the longest sentence

	// the things that recur
	issues:      []Issue_Tally,
	openers:     []Opener, // sentence-opening words used three times or more
	alerts_n:    int,
}

BUCKET_LABEL := [6]string{"1-10", "11-15", "16-20", "21-25", "26-35", "36+"}

@(private = "file")
bucket_of :: proc(n: int) -> int {
	switch {
	case n <= 10:
		return 0
	case n <= 15:
		return 1
	case n <= 20:
		return 2
	case n <= 25:
		return 3
	case n <= 35:
		return 4
	}
	return 5
}

// report_of builds the report from a finished lint. It re-walks the sentences
// rather than threading the per-sentence numbers through the engine, because
// the report is computed when a panel opens and not per keystroke.
report_of :: proc(res: ^Result, allocator := context.allocator) -> Report {
	rp := Report {
		words     = res.counts.words,
		sentences = res.counts.sentences,
		syllables = res.counts.syllables,
		minutes   = reading_minutes(res.counts.words),
		caveat    = CAVEAT,
		alerts_n  = len(res.alerts),
	}
	for b in res.masked.blocks {
		if b.kind == .Paragraph {
			rp.paragraphs += 1
		}
	}

	// --- sentence shape --------------------------------------------------
	lens := make([dynamic]int, 0, max(1, len(res.sentences)), context.temp_allocator)
	rp.len_min = 1 << 30
	for s in res.sentences {
		n := len(words(res.masked.text, s.from, s.to, context.temp_allocator))
		if n == 0 {
			continue
		}
		append(&lens, n)
		rp.buckets[bucket_of(n)] += 1
		if n < rp.len_min {
			rp.len_min = n
		}
		if n > rp.len_max {
			rp.len_max = n
			rp.longest_at = s.from
		}
	}
	if len(lens) == 0 {
		rp.len_min = 0
	} else {
		total := 0
		for n in lens {
			total += n
		}
		rp.len_mean = f64(total) / f64(len(lens))
		sorted := slice.clone(lens[:], context.temp_allocator)
		slice.sort(sorted)
		rp.len_median = sorted[len(sorted) / 2]
		if len(lens) > 1 {
			acc := 0.0
			for n in lens {
				d := f64(n) - rp.len_mean
				acc += d * d
			}
			rp.len_sd = math.sqrt(acc / f64(len(lens) - 1))
		}
	}

	// --- readability -----------------------------------------------------
	grades := make([dynamic]Grade, 0, 6, allocator)
	sum, n := 0.0, 0
	for m in Metric {
		v, ok := metric_value(m, res.counts)
		g := Grade {
			metric = m,
			value  = v,
			ok     = ok,
		}
		if m == .Flesch_Reading_Ease {
			g.band = ok ? ease_band(v) : ""
			rp.ease, rp.ease_ok = v, ok
		} else {
			g.band = ok ? band(v) : ""
			if ok {
				sum += v
				n += 1
			}
		}
		append(&grades, g)
	}
	rp.grades = grades[:]
	if n > 0 {
		rp.grade_mean = sum / f64(n)
		rp.grade_ok = true
	}

	// --- what recurs -----------------------------------------------------
	tally := make([dynamic]Issue_Tally, 0, 16, context.temp_allocator)
	for a in res.alerts {
		at := -1
		for t, i in tally {
			if t.rule == a.rule {
				at = i
				break
			}
		}
		if at < 0 {
			append(
				&tally,
				Issue_Tally{rule = a.rule, n = 1, sev = a.sev, first = a.from, fix = a.has_fix},
			)
			continue
		}
		tally[at].n += 1
		tally[at].fix = tally[at].fix || a.has_fix
	}
	slice.sort_by(tally[:], proc(a, b: Issue_Tally) -> bool {
		if a.n != b.n {
			return a.n > b.n
		}
		if a.sev != b.sev {
			return a.sev > b.sev
		}
		return a.rule < b.rule
	})
	rp.issues = slice.clone(tally[:], allocator)

	// --- repeated sentence openers ---------------------------------------
	// Three sentences in a row beginning "This" is the single most visible
	// rhythm problem in a draft, and no rule type in Vale can express it.
	counts := make([dynamic]Opener, 0, 16, context.temp_allocator)
	for s in res.sentences {
		ws := words(res.masked.text, s.from, s.to, context.temp_allocator)
		if len(ws) == 0 {
			continue
		}
		w := lower_ascii(res.masked.text[ws[0].from:ws[0].to], context.temp_allocator)
		at := -1
		for c, i in counts {
			if c.word == w {
				at = i
				break
			}
		}
		if at < 0 {
			append(&counts, Opener{w, 1})
		} else {
			counts[at].n += 1
		}
	}
	keep := make([dynamic]Opener, 0, 8, allocator)
	for c in counts {
		if c.n >= 3 {
			append(&keep, Opener{strings.clone(c.word, allocator), c.n})
		}
	}
	slice.sort_by(keep[:], proc(a, b: Opener) -> bool {return a.n > b.n})
	rp.openers = keep[:]

	return rp
}

report_destroy :: proc(rp: ^Report, allocator := context.allocator) {
	delete(rp.grades, allocator)
	delete(rp.issues, allocator)
	for o in rp.openers {
		delete(o.word, allocator)
	}
	delete(rp.openers, allocator)
	rp^ = {}
}

// variance_note says what the standard deviation of sentence length means in
// words, without inventing a threshold. The advice "vary your sentence
// length" is real but unquantified; this reports the number and names the two
// ends it can recognise.
variance_note :: proc(rp: ^Report) -> string {
	if rp.sentences < 4 {
		return "too few sentences to say anything about rhythm"
	}
	switch {
	case rp.len_sd < 4:
		return "every sentence is about the same length, which reads as a drone"
	case rp.len_sd > 14:
		return "lengths swing widely, which can read as unedited"
	}
	return "a varied mix of lengths"
}
