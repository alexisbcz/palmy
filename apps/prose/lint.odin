package prose

// The engine: packs in, alerts out.
//
// Two entry points, and the difference between them is the whole performance
// story. `lint` does a full pass: mask the document, segment it, run every
// rule including the three that need the whole text (consistency, conditional,
// readability). `lint_window` runs only the block-local rules, only over the
// blocks that overlap a byte range — which is what a keystroke needs, because
// a keystroke changes one paragraph and cannot change whether a word three
// paragraphs up is spelled two ways.
//
// The caller is expected to use both: `lint_window` on the paragraph under the
// caret after a short debounce, and `lint` once the typing stops. That keeps
// the marks under the caret live without re-reading the document on every key,
// and keeps the document-level rules honest because they are never computed
// from a stale window.

import "core:slice"
import "core:strings"

Pack :: struct {
	name:   string,
	about:  string, // one sentence: what this pack is for
	rules:  [dynamic]Rule,
	source: string, // "built-in" or the directory it came from
}

Engine :: struct {
	packs:            [dynamic]Pack,
	errors:           [dynamic]string, // rule files that would not compile
	skipped_spelling: int,
}

Opts :: struct {
	pack:              int, // index into Engine.packs
	lint_front_matter: bool, // Vale's behaviour; off for the application
	min_sev:           Severity,
	dismissed:         []string, // rule names to drop entirely
}

Result :: struct {
	alerts:    []Alert,
	counts:    Counts,
	sentences: []Span,
	masked:    Masked,
	lines:     []int, // byte offset of the start of each line
}

result_destroy :: proc(r: ^Result, allocator := context.allocator) {
	for a in r.alerts {
		delete(a.match, allocator)
		delete(a.message, allocator)
		delete(a.fix, allocator)
	}
	delete(r.alerts, allocator)
	delete(r.sentences, allocator)
	delete(r.lines, allocator)
	mask_destroy(&r.masked)
	r^ = {}
}

engine_destroy :: proc(e: ^Engine) {
	for &p in e.packs {
		for &r in p.rules {
			rule_destroy(&r)
		}
		delete(p.rules)
		delete(p.name)
		delete(p.about)
		delete(p.source)
	}
	delete(e.packs)
	for s in e.errors {
		delete(s)
	}
	delete(e.errors)
	e^ = {}
}

pack_index :: proc(e: ^Engine, name: string) -> int {
	for p, i in e.packs {
		if eq_fold(p.name, name) {
			return i
		}
	}
	return -1
}

// ---------------------------------------------------------------------------
// Line arithmetic
// ---------------------------------------------------------------------------

line_starts :: proc(src: string, allocator := context.allocator) -> []int {
	out := make([dynamic]int, 0, 64, allocator)
	append(&out, 0)
	for i in 0 ..< len(src) {
		if src[i] == '\n' {
			append(&out, i + 1)
		}
	}
	return out[:]
}

// line_col converts a byte offset into the 1-based line and column Vale
// reports, which is a byte column within the line.
line_col :: proc(lines: []int, off: int) -> (line, col: int) {
	lo, hi := 0, len(lines) - 1
	for lo < hi {
		mid := (lo + hi + 1) / 2
		if lines[mid] <= off {
			lo = mid
		} else {
			hi = mid - 1
		}
	}
	return lo + 1, off - lines[lo] + 1
}

// ---------------------------------------------------------------------------
// Running a pack
// ---------------------------------------------------------------------------

@(private = "file")
dismissed_rule :: proc(o: Opts, name: string) -> bool {
	for d in o.dismissed {
		if d == name {
			return true
		}
	}
	return false
}

// targets_for expands a rule's scope into the spans it should be run over.
@(private = "file")
targets_for :: proc(
	r: ^Rule,
	m: ^Masked,
	window: Span,
	allocator := context.temp_allocator,
) -> []Span {
	out := make([dynamic]Span, 0, 16, allocator)
	for b in m.blocks {
		if b.to <= window.from || b.from >= window.to {
			continue
		}
		if !scope_allows(r.scope, b) {
			continue
		}
		switch r.scope.unit {
		case .Block, .Paragraph, .Summary:
			append(&out, Span{b.from, b.to})
		case .Sentence:
			append(&out, ..sentences(m.text, b.from, b.to, allocator))
		}
	}
	return out[:]
}

// prose_spans is every block that holds prose, which is what the whole-document
// rules and the statistics run over.
prose_spans :: proc(m: ^Masked, allocator := context.temp_allocator) -> []Span {
	out := make([dynamic]Span, 0, 16, allocator)
	for b in m.blocks {
		if b.kind != .None {
			append(&out, Span{b.from, b.to})
		}
	}
	return out[:]
}

// all_sentences is every sentence in every prose block, in document order.
all_sentences :: proc(m: ^Masked, allocator := context.allocator) -> []Span {
	out := make([dynamic]Span, 0, 32, allocator)
	for b in m.blocks {
		if b.kind == .None {
			continue
		}
		append(&out, ..sentences(m.text, b.from, b.to, context.temp_allocator))
	}
	return out[:]
}

// lint does a full pass over a document.
lint :: proc(e: ^Engine, src: string, o: Opts, allocator := context.allocator) -> Result {
	res := Result{}
	res.masked = mask(src, o.lint_front_matter, allocator)
	res.lines = line_starts(src, allocator)
	res.sentences = all_sentences(&res.masked, allocator)
	res.counts = counts_of(res.masked.text, res.sentences)

	alerts := make([dynamic]Alert, 0, 32, allocator)
	if o.pack >= 0 && o.pack < len(e.packs) {
		whole := Span{0, len(src)}
		spans := prose_spans(&res.masked)
		for &r in e.packs[o.pack].rules {
			if r.sev < o.min_sev || dismissed_rule(o, r.name) {
				continue
			}
			switch r.kind {
			case .Consistency:
				check_consistency(&r, res.masked.text, spans, &alerts, allocator)
			case .Conditional:
				check_conditional(&r, res.masked.text, spans, &alerts, allocator)
			case .Readability:
				check_readability(&r, res.masked.text, res.counts, &alerts, allocator)
			case .Existence, .Substitution, .Occurrence, .Repetition, .Capitalization, .Spelling:
				run_local(&r, &res.masked, whole, &alerts, allocator)
			}
		}
	}
	finish(&res, alerts, allocator)
	return res
}

// lint_window runs only the rules that can be decided inside one block, and
// only over the blocks touching [from,to). This is the per-keystroke path.
lint_window :: proc(
	e: ^Engine,
	src: string,
	from, to: int,
	o: Opts,
	allocator := context.allocator,
) -> Result {
	res := Result{}
	res.masked = mask(src, o.lint_front_matter, allocator)
	res.lines = line_starts(src, allocator)

	// Widen to whole blocks, so a rule never sees half a sentence.
	w := Span{from, to}
	for b in res.masked.blocks {
		if b.to > from && b.from < to {
			w.from = min(w.from, b.from)
			w.to = max(w.to, b.to)
		}
	}
	res.sentences = make([]Span, 0, allocator)

	alerts := make([dynamic]Alert, 0, 16, allocator)
	if o.pack >= 0 && o.pack < len(e.packs) {
		for &r in e.packs[o.pack].rules {
			if r.sev < o.min_sev || dismissed_rule(o, r.name) {
				continue
			}
			switch r.kind {
			case .Consistency, .Conditional, .Readability:
				continue
			case .Existence, .Substitution, .Occurrence, .Repetition, .Capitalization, .Spelling:
				run_local(&r, &res.masked, w, &alerts, allocator)
			}
		}
	}
	finish(&res, alerts, allocator)
	return res
}

@(private = "file")
run_local :: proc(
	r: ^Rule,
	m: ^Masked,
	window: Span,
	alerts: ^[dynamic]Alert,
	allocator: Allocator,
) {
	for t in targets_for(r, m, window) {
		before := len(alerts)
		defer for i in before ..< len(alerts) {
			alerts[i].scope_from = t.from
			alerts[i].scope_to = t.to
		}
		switch r.kind {
		case .Existence:
			check_existence(r, m.text, t, alerts, allocator)
		case .Substitution:
			check_substitution(r, m.text, t, alerts, allocator)
		case .Occurrence:
			check_occurrence(r, m.text, t, alerts, allocator)
		case .Repetition:
			check_repetition(r, m.text, t, alerts, allocator)
		case .Capitalization:
			check_capitalization(r, m.text, t, alerts, allocator)
		case .Spelling:
			check_spelling(r, m.text, t, alerts, allocator)
		case .Consistency, .Conditional, .Readability:
		}
	}
}

@(private = "file")
finish :: proc(res: ^Result, alerts: [dynamic]Alert, allocator: Allocator) {
	out := alerts
	for &a in out {
		a.line, a.col = line_col(res.lines, a.from)
		_, ec := line_col(res.lines, max(a.from, a.to - 1))
		a.end_col = ec
	}
	slice.sort_by(out[:], proc(a, b: Alert) -> bool {
		if a.from != b.from {
			return a.from < b.from
		}
		if a.sev != b.sev {
			return a.sev > b.sev
		}
		return a.rule < b.rule
	})
	res.alerts = out[:]
}

// alert_at finds the alert covering a byte offset, preferring the most severe
// and then the narrowest — which is what a caret sitting inside two
// overlapping marks should select.
alert_at :: proc(alerts: []Alert, off: int) -> int {
	best := -1
	for a, i in alerts {
		if off < a.from || off >= a.to {
			continue
		}
		if best < 0 {
			best = i
			continue
		}
		b := alerts[best]
		if a.sev > b.sev || (a.sev == b.sev && (a.to - a.from) < (b.to - b.from)) {
			best = i
		}
	}
	return best
}

_ :: strings
