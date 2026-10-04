package prose

// Running the rules.
//
// Each `extends:` type gets one procedure. They all take the masked document,
// the span they were asked to look at, and append alerts; nothing here knows
// about files, panels or keystrokes.
//
// The matcher underneath has two paths. A rule whose tokens are all plain
// literals — which is most of a style pack — is matched by a direct scan with
// word-boundary checks, because that is both faster than a regex and exactly
// what `\b(?:a|b|c)\b` means. Anything with a metacharacter in it goes through
// `core:text/regex`. The regex path uses a hand-built `Match_Iterator` over the
// *whole* string rather than re-slicing after each hit, so that `\b` still
// sees the character to the left of a match and cannot be fooled into a false
// boundary at a slice edge.

import "base:runtime"
import "core:fmt"
import "core:slice"
import "core:strings"
import rx "core:text/regex"
import vm "core:text/regex/virtual_machine"

Hit :: struct {
	from:  int,
	to:    int,
	token: string, // capture group 1 when the pattern has one, else the match
}

// ---------------------------------------------------------------------------
// Matching
// ---------------------------------------------------------------------------

// contains_fold is a plain substring search inside a window, folding case when
// the pattern does.
@(private = "file")
contains_fold :: proc(s: string, lo, hi: int, needle: string, fold: bool) -> bool {
	n := len(needle)
	if n == 0 || hi - lo < n {
		return false
	}
	for i in lo ..= hi - n {
		same := true
		for j in 0 ..< n {
			a := s[i + j]
			b := needle[j]
			if fold {
				a = (a >= 'A' && a <= 'Z') ? a + 32 : a
				b = (b >= 'A' && b <= 'Z') ? b + 32 : b
			}
			if a != b {
				same = false
				break
			}
		}
		if same {
			return true
		}
	}
	return false
}

@(private = "file")
boundary_ok :: proc(s: string, from, to: int) -> bool {
	if from > 0 && is_word_byte(s[from - 1]) {
		return false
	}
	if to < len(s) && is_word_byte(s[to]) {
		return false
	}
	return true
}

// pat_each finds every match of a pattern inside [from,to).
pat_each :: proc(p: ^Pattern, s: string, from, to: int, allocator := context.temp_allocator) -> []Hit {
	out := make([dynamic]Hit, 0, 8, allocator)
	lo := clamp(from, 0, len(s))
	hi := clamp(to, lo, len(s))

	if len(p.lits) > 0 {
		i := lo
		for i < hi {
			matched := false
			for lit in p.lits {
				n := len(lit)
				if i + n > hi {
					continue
				}
				same := true
				for j in 0 ..< n {
					a := s[i + j]
					b := lit[j]
					if p.fold {
						a = (a >= 'A' && a <= 'Z') ? a + 32 : a
						b = (b >= 'A' && b <= 'Z') ? b + 32 : b
					}
					if a != b {
						same = false
						break
					}
				}
				if !same {
					continue
				}
				if !p.nonword && !boundary_ok(s, i, i + n) {
					continue
				}
				append(&out, Hit{i, i + n, s[i:i + n]})
				i += n
				matched = true
				break
			}
			if !matched {
				i += 1
			}
		}
		return out[:]
	}

	if !p.has_re {
		return out[:]
	}

	// The cheap test first: if none of the literals a match must contain is
	// anywhere in the window, there is nothing to find.
	if prefilter_on && len(p.prefilter) > 0 {
		any := false
		for lit in p.prefilter {
			if contains_fold(s, lo, hi, lit, p.fold) {
				any = true
				break
			}
		}
		if !any {
			return out[:]
		}
	}

	// The VM is given the *whole* string but started at `lo`, with the byte
	// before it installed as the previous rune. Two things fall out of that.
	// `\b` still sees its left context, so a pattern cannot be fooled into a
	// false word boundary at the edge of a window — which re-slicing the
	// string would do. And the scan is O(window), not O(document): without
	// this, a full pass over a twenty-kilobyte note ran every regex rule from
	// byte zero once per paragraph and took half a second.
	it := rx.Match_Iterator {
		regex   = p.re,
		capture = rx.preallocate_capture(context.temp_allocator),
		temp    = context.temp_allocator,
		vm      = p.mach,
	}
	// `s[:hi]`, not `s`: the slice shares the base pointer so every offset is
	// unchanged, but the VM stops at the end of the window instead of walking
	// the rest of the document looking for a match that cannot be reported.
	// Without this, a rule that matched nothing in a paragraph still scanned
	// every byte after it, and a full pass was quadratic in the note's length.
	it.vm.memory = s[:hi]
	it.vm.string_pointer = 0
	it.vm.top_thread = 0
	it.vm.current_rune = 0
	it.vm.current_rune_size = 0
	it.vm.last_rune = 0
	it.threads = p.nthreads
	// The thread arrays are deliberately *not* cleared. `run` only ever reads
	// `threads[i]` for `i < top_thread`, so entries past the mark are dead,
	// and zeroing two arrays of a thousand 168-byte threads per window made
	// the engine a memset benchmark.
	//
	// The busy map does have to be cleared, and this is the subtle part of
	// reusing a machine. `virtual_machine.run` zeroes it at the top of its
	// per-rune loop, but it adds the *starting* thread before that loop runs —
	// so a stale bit left by the previous run can reject the initial thread
	// and the pattern silently matches nothing. It cost an afternoon: the
	// selftest lost one alert out of three, only on the seventh lint of a
	// run, only for the one swap entry that was a regex. (`regex.reset` in
	// core has the same gap.)
	slice.zero(it.vm.busy_map[:])
	if lo > 0 {
		it.vm.string_pointer = lo
		it.vm.last_rune = rune(s[lo - 1])
	}

	for {
		cap, _, ok := rx.match_iterator(&it)
		if !ok {
			break
		}
		if len(cap.pos) == 0 {
			break
		}
		a, b := cap.pos[0][0], cap.pos[0][1]
		if b <= a {
			continue
		}
		if a >= hi {
			break
		}
		if a < lo {
			continue
		}
		tok := cap.groups[0]
		if len(cap.groups) > 1 && len(cap.groups[1]) > 0 {
			tok = cap.groups[1]
		}
		append(&out, Hit{a, b, tok})
	}
	return out[:]
}

@(private = "file")
excepted :: proc(r: ^Rule, tok: string) -> bool {
	for e in r.exceptions {
		if eq_fold(e, tok) {
			return true
		}
		// An exception in a rule file may be a regex; a literal compare first
		// covers the common case without compiling anything.
		if strings.contains(e, "\\") || strings.contains(e, "[") {
			if m, ok := rx.match_and_allocate_capture(
				compile_cached(e),
				tok,
				context.temp_allocator,
				context.temp_allocator,
			); ok && len(m.pos) > 0 && m.pos[0][0] == 0 && m.pos[0][1] == len(tok) {
				return true
			}
		}
	}
	return false
}

// A tiny cache so an exception regex is compiled once per process rather than
// once per match. Style packs have a handful of them.
@(private = "file")
exc_cache: map[string]rx.Regular_Expression

@(private = "file")
compile_cached :: proc(pattern: string) -> rx.Regular_Expression {
	if re, ok := exc_cache[pattern]; ok {
		return re
	}
	re, err := rx.create(pattern)
	if err != nil {
		re = {}
	}
	exc_cache[strings.clone(pattern)] = re
	return re
}

cache_destroy :: proc() {
	for k, v in exc_cache {
		rx.destroy_regex(v)
		delete(k)
	}
	delete(exc_cache)
	exc_cache = nil
}

// ---------------------------------------------------------------------------
// Alerts
// ---------------------------------------------------------------------------

Alert :: struct {
	rule:    string, // "Plain.Hedging"
	kind:    Rule_Kind,
	sev:     Severity,
	from:    int, // byte offset in the document
	to:      int,

	// The span the rule was judged over: the sentence for a sentence-scoped
	// rule, the block otherwise. An occurrence alert sits on the first match
	// in its scope — Vale puts it there and so does this — but "35 words in
	// one sentence" underlined beneath one word reads as a complaint about
	// that word. The interface uses this to mark the sentence instead.
	scope_from: int,
	scope_to:   int,
	line:    int, // 1-based
	col:     int, // 1-based byte column
	end_col: int, // 1-based, inclusive, as Vale reports it
	match:   string,
	message: string,
	why:     string, // the rule's `description`
	link:    string,
	fix:     string, // a concrete replacement, "" when the rule cannot offer one
	has_fix: bool,
}

@(private = "file")
emit :: proc(
	out: ^[dynamic]Alert,
	r: ^Rule,
	from, to: int,
	match: string,
	msg: string,
	fix: string,
	has_fix: bool,
	allocator: Allocator,
) {
	append(
		out,
		Alert {
			rule = r.name,
			kind = r.kind,
			sev = r.sev,
			from = from,
			to = to,
			match = strings.clone(match, allocator),
			message = strings.clone(msg, allocator),
			why = r.desc,
			link = r.link,
			fix = strings.clone(fix, allocator),
			has_fix = has_fix,
		},
	)
}

// msg_fill substitutes Vale's `%s` placeholders. Vale passes one argument for
// most types and two for substitution — the replacement first, then what was
// written — which is the order its own message strings expect.
msg_fill :: proc(tmpl: string, a: string, b := "", allocator := context.temp_allocator) -> string {
	if !strings.contains(tmpl, "%s") {
		return strings.clone(tmpl, allocator)
	}
	sb := strings.builder_make(allocator)
	n := 0
	i := 0
	for i < len(tmpl) {
		if i + 1 < len(tmpl) && tmpl[i] == '%' && tmpl[i + 1] == 's' {
			strings.write_string(&sb, n == 0 ? a : b)
			n += 1
			i += 2
			continue
		}
		strings.write_byte(&sb, tmpl[i])
		i += 1
	}
	return strings.to_string(sb)
}

// ---------------------------------------------------------------------------
// The checks
// ---------------------------------------------------------------------------

check_existence :: proc(r: ^Rule, s: string, w: Span, out: ^[dynamic]Alert, allocator: Allocator) {
	for h in pat_each(&r.pat, s, w.from, w.to) {
		if excepted(r, h.token) {
			continue
		}
		fix := r.fix
		has := r.fix != "" || r.drop
		emit(
			out,
			r,
			h.from,
			h.to,
			s[h.from:h.to],
			msg_fill(r.message, s[h.from:h.to]),
			fix,
			has,
			allocator,
		)
	}
}

check_substitution :: proc(r: ^Rule, s: string, w: Span, out: ^[dynamic]Alert, allocator: Allocator) {
	// Vale's swap map is unordered in YAML but applied as one alternation; a
	// left-to-right pass per entry with overlap suppression gives the same
	// alert set without depending on map order.
	taken := make([dynamic]Span, 0, 8, context.temp_allocator)
	for &sw in r.swaps {
		for h in pat_each(&sw.pat, s, w.from, w.to) {
			if excepted(r, h.token) {
				continue
			}
			clash := false
			for t in taken {
				if h.from < t.to && t.from < h.to {
					clash = true
					break
				}
			}
			if clash {
				continue
			}
			append(&taken, Span{h.from, h.to})
			got := s[h.from:h.to]
			to := match_case(sw.to, got, context.temp_allocator)
			emit(out, r, h.from, h.to, got, msg_fill(r.message, to, got), to, true, allocator)
		}
	}
}

// match_case makes a replacement wear the capitalisation of what it replaces,
// so "Utilize the thing" is offered "Use", not "use". Without this the one
// feature that makes a suggestion worth taking — pressing a key and being
// done — produces a sentence starting in lower case.
match_case :: proc(repl, got: string, allocator := context.temp_allocator) -> string {
	if repl == "" || got == "" {
		return strings.clone(repl, allocator)
	}
	all_upper := true
	for i in 0 ..< len(got) {
		c := got[i]
		if c >= 'a' && c <= 'z' {
			all_upper = false
			break
		}
	}
	if all_upper && len(got) > 1 {
		return strings.to_upper(repl, allocator)
	}
	if got[0] >= 'A' && got[0] <= 'Z' {
		b := strings.clone(repl, allocator)
		raw := transmute([]u8)b
		if raw[0] >= 'a' && raw[0] <= 'z' {
			raw[0] -= 32
		}
		return string(raw)
	}
	return strings.clone(repl, allocator)
}

check_occurrence :: proc(r: ^Rule, s: string, w: Span, out: ^[dynamic]Alert, allocator: Allocator) {
	hits := pat_each(&r.pat, s, w.from, w.to)
	n := len(hits)
	bad := false
	if r.has_max && n > r.max_n {
		bad = true
	}
	if r.has_min && n < r.min_n {
		bad = true
	}
	if !bad {
		return
	}
	// Vale puts the alert on the first match in the scope; when a minimum is
	// missed there is no match, so the scope's first word carries it.
	from, to := w.from, w.from + 1
	if n > 0 {
		from, to = hits[0].from, hits[0].to
	} else {
		ws := words(s, w.from, w.to, context.temp_allocator)
		if len(ws) > 0 {
			from, to = ws[0].from, ws[0].to
		}
	}
	emit(
		out,
		r,
		from,
		to,
		s[from:to],
		msg_fill(r.message, fmt.tprintf("%d", n)),
		"",
		false,
		allocator,
	)
}

// check_repetition: two *consecutive* matches that are equal.
//
// What may sit between them took a session with the oracle to pin down. Vale
// flags "a, a" and "word\nword" and even the "R. R" of "J. R. R. Tolkien", so
// punctuation and newlines are not barriers — but it does not flag
// "He left. Left is fine." The rule is not about the gap at all: it is that
// both matches have to be in the same sentence. So this segments the span and
// compares within each sentence, which reproduces all four of those results.
check_repetition :: proc(r: ^Rule, s: string, w: Span, out: ^[dynamic]Alert, allocator: Allocator) {
	for sent in sentences(s, w.from, w.to, context.temp_allocator) {
		check_repetition_in(r, s, sent, out, allocator)
	}
}

@(private = "file")
check_repetition_in :: proc(
	r: ^Rule,
	s: string,
	w: Span,
	out: ^[dynamic]Alert,
	allocator: Allocator,
) {
	hits := pat_each(&r.pat, s, w.from, w.to)
	for i in 1 ..< len(hits) {
		a, b := hits[i - 1], hits[i]
		same := r.ignorecase ? eq_fold(a.token, b.token) : a.token == b.token
		if !same {
			continue
		}
		if r.alpha {
			ok := len(a.token) > 0
			for j in 0 ..< len(a.token) {
				c := a.token[j] | 32
				if c < 'a' || c > 'z' {
					ok = false
					break
				}
			}
			if !ok {
				continue
			}
		}
		if excepted(r, a.token) {
			continue
		}
		emit(
			out,
			r,
			a.from,
			b.to,
			s[a.from:b.to],
			msg_fill(r.message, lower_ascii(a.token)),
			s[a.from:a.to],
			true,
			allocator,
		)
	}
}

// check_consistency needs the whole document: an inconsistency is two
// spellings of one word both appearing, which no single sentence can show.
check_consistency :: proc(
	r: ^Rule,
	s: string,
	spans: []Span,
	out: ^[dynamic]Alert,
	allocator: Allocator,
) {
	for p in r.pairs {
		one := [1]string{p.a}
		two := [1]string{p.b}
		pa, ea := pattern_make(one[:], r.ignorecase, r.nonword, context.temp_allocator)
		pb, eb := pattern_make(two[:], r.ignorecase, r.nonword, context.temp_allocator)
		if ea != "" || eb != "" {
			continue
		}
		ha := make([dynamic]Hit, 0, 4, context.temp_allocator)
		hb := make([dynamic]Hit, 0, 4, context.temp_allocator)
		for w in spans {
			append(&ha, ..pat_each(&pa, s, w.from, w.to))
			append(&hb, ..pat_each(&pb, s, w.from, w.to))
		}
		if len(ha) == 0 || len(hb) == 0 {
			continue
		}
		// Vale reports the *minority* spelling: the one used less is the one
		// to change, and if they tie it reports the second.
		losers := len(ha) < len(hb) ? ha : hb
		keep := len(ha) < len(hb) ? p.b : p.a
		for h in losers {
			emit(
				out,
				r,
				h.from,
				h.to,
				s[h.from:h.to],
				msg_fill(r.message, s[h.from:h.to], keep),
				match_case(keep, s[h.from:h.to], context.temp_allocator),
				true,
				allocator,
			)
		}
	}
}

// check_conditional: every match of `first` must have a match of `second`
// somewhere in the document carrying the same captured text.
check_conditional :: proc(
	r: ^Rule,
	s: string,
	spans: []Span,
	out: ^[dynamic]Alert,
	allocator: Allocator,
) {
	defined := make(map[string]bool, 8, context.temp_allocator)
	for w in spans {
		for h in pat_each(&r.second, s, w.from, w.to) {
			defined[h.token] = true
		}
	}
	for w in spans {
		for h in pat_each(&r.first, s, w.from, w.to) {
			if defined[h.token] || excepted(r, h.token) {
				continue
			}
			emit(
				out,
				r,
				h.from,
				h.to,
				s[h.from:h.to],
				msg_fill(r.message, h.token),
				"",
				false,
				allocator,
			)
		}
	}
}

check_readability :: proc(
	r: ^Rule,
	s: string,
	c: Counts,
	out: ^[dynamic]Alert,
	allocator: Allocator,
) {
	total := 0.0
	n := 0
	for m in r.metrics {
		if v, ok := metric_value(m, c); ok {
			total += v
			n += 1
		}
	}
	if n == 0 {
		return
	}
	avg := total / f64(n)
	if avg <= r.grade {
		return
	}
	emit(
		out,
		r,
		0,
		1,
		"",
		msg_fill(r.message, fmt.tprintf("%.2f", avg)),
		"",
		false,
		allocator,
	)
}

check_capitalization :: proc(r: ^Rule, s: string, w: Span, out: ^[dynamic]Alert, allocator: Allocator) {
	txt := strings.trim_space(s[clamp(w.from, 0, len(s)):clamp(w.to, 0, len(s))])
	if txt == "" {
		return
	}
	ok := true
	switch r.cased {
	case .Any:
		return
	case .Lower:
		ok = txt == strings.to_lower(txt, context.temp_allocator)
	case .Upper:
		ok = txt == strings.to_upper(txt, context.temp_allocator)
	case .Sentence_Case:
		ok = sentence_cased(txt, r.exceptions)
	case .Title:
		ok = title_cased(txt, r.exceptions)
	}
	if ok {
		return
	}
	from := w.from
	for from < w.to && (s[from] == ' ' || s[from] == '\t') {
		from += 1
	}
	emit(out, r, from, from + len(txt), txt, msg_fill(r.message, txt), "", false, allocator)
}

// Words a title-case style guide leaves lowercase unless they lead.
@(rodata)
MINOR_WORDS := [?]string {
	"a",
	"an",
	"and",
	"as",
	"at",
	"but",
	"by",
	"for",
	"from",
	"if",
	"in",
	"into",
	"nor",
	"of",
	"on",
	"onto",
	"or",
	"over",
	"per",
	"so",
	"the",
	"to",
	"up",
	"via",
	"with",
	"yet",
}

@(private = "file")
title_cased :: proc(txt: string, exceptions: []string) -> bool {
	ws := words(txt, 0, len(txt), context.temp_allocator)
	for w, i in ws {
		tok := txt[w.from:w.to]
		if tok_excepted(tok, exceptions) {
			continue
		}
		minor := false
		for m in MINOR_WORDS {
			if eq_fold(m, tok) {
				minor = true
				break
			}
		}
		lead := i == 0 || i == len(ws) - 1
		upper := tok[0] >= 'A' && tok[0] <= 'Z'
		if minor && !lead {
			continue // either case is accepted for a minor word
		}
		if !upper && !(tok[0] >= '0' && tok[0] <= '9') {
			return false
		}
	}
	return true
}

@(private = "file")
sentence_cased :: proc(txt: string, exceptions: []string) -> bool {
	ws := words(txt, 0, len(txt), context.temp_allocator)
	for w, i in ws {
		tok := txt[w.from:w.to]
		if tok_excepted(tok, exceptions) {
			continue
		}
		upper := tok[0] >= 'A' && tok[0] <= 'Z'
		if i == 0 {
			if !upper && (tok[0] | 32) >= 'a' && (tok[0] | 32) <= 'z' {
				return false
			}
			continue
		}
		// A later word in upper case is only allowed if it is an acronym or
		// an exception, which this cannot know; one capital is let through,
		// a run of them is not.
		if upper && len(tok) > 1 {
			allcaps := true
			for j in 0 ..< len(tok) {
				if tok[j] >= 'a' && tok[j] <= 'z' {
					allcaps = false
					break
				}
			}
			if !allcaps {
				return false
			}
		}
	}
	return true
}

@(private = "file")
tok_excepted :: proc(tok: string, exceptions: []string) -> bool {
	for e in exceptions {
		if e == tok || eq_fold(e, tok) {
			return true
		}
	}
	return false
}

// check_spelling has no dictionary.
//
// This machine has `hunspell` installed with no dictionaries at all — the
// search path is empty — and there is no wordlist under /usr/share/dict but a
// password cracker's. Shipping an English dictionary inside this repository to
// make the rule type look implemented would be a fifty-thousand-word fixture
// nobody reviewed, and a spelling checker that is quietly wrong is worse than
// one that is absent.
//
// So the rule type loads, is dispatched, and honestly produces nothing. A
// style pack containing a `spelling` rule is not rejected; the rule is skipped
// and `Engine.skipped_spelling` counts it so the caller can say so.
check_spelling :: proc(r: ^Rule, s: string, w: Span, out: ^[dynamic]Alert, allocator: Allocator) {
	// Intentionally empty. See the comment above.
}

_ :: runtime
