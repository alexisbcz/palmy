package prose

// Vale's rule schema, compiled.
//
// The format is Vale's, not ours, and that is the whole point of the choice:
// somebody who already maintains a style guide as a `styles/` directory —
// Microsoft's, Google's, proselint, write-good, alex — can point this at it
// and have it work, offline, with no `vale sync` and no network. Inventing a
// rule format would have meant nobody else's rules, and nobody else's rules
// means the feature is only as good as the rules shipped with it.
//
// The nine `extends:` values Vale defines:
//
//   existence       a pattern that should not appear
//   substitution    a pattern with a specific replacement
//   occurrence      a pattern appearing too often, or not often enough
//   consistency     two spellings of one thing, both used
//   repetition      a pattern repeated back to back
//   conditional     a pattern that requires another to exist
//   readability     a grade threshold over the whole document
//   spelling        a dictionary check
//   capitalization  a heading or sentence in the wrong case
//
// `spelling` is parsed and dispatched but has no dictionary on this machine —
// see `check.odin` for what it does instead of pretending.

import "base:runtime"
import "core:fmt"
import "core:strings"
import rx "core:text/regex"
import vmm "core:text/regex/virtual_machine"

Allocator :: runtime.Allocator

Severity :: enum u8 {
	Suggestion,
	Warning,
	Error,
}

SEVERITY_NAME := [Severity]string {
	.Suggestion = "suggestion",
	.Warning    = "warning",
	.Error      = "error",
}

severity_from :: proc(s: string, def := Severity.Warning) -> Severity {
	switch strings.to_lower(s, context.temp_allocator) {
	case "suggestion":
		return .Suggestion
	case "warning":
		return .Warning
	case "error":
		return .Error
	}
	return def
}

Rule_Kind :: enum u8 {
	Existence,
	Substitution,
	Occurrence,
	Consistency,
	Repetition,
	Conditional,
	Readability,
	Spelling,
	Capitalization,
}

RULE_KIND_NAME := [Rule_Kind]string {
	.Existence      = "existence",
	.Substitution   = "substitution",
	.Occurrence     = "occurrence",
	.Consistency    = "consistency",
	.Repetition     = "repetition",
	.Conditional    = "conditional",
	.Readability    = "readability",
	.Spelling       = "spelling",
	.Capitalization = "capitalization",
}

Scope_Unit :: enum u8 {
	Block, // the default: one match anywhere in a prose block
	Sentence,
	Paragraph,
	Summary, // the whole document, once
}

Scope_Sel :: struct {
	unit:   Scope_Unit,
	kinds:  bit_set[Scope_Kind],
	level:  int, // heading depth, 0 for any
	negate: bool,
}

Cased :: enum u8 {
	Any,
	Title,
	Sentence_Case,
	Lower,
	Upper,
}

Pattern :: struct {
	src:      string,
	re:       rx.Regular_Expression,
	has_re:   bool,
	lits:     []string, // non-empty when every token is a plain literal
	nonword:  bool,
	fold:     bool,

	// A set of literals, at least one of which any match must contain. A
	// window that holds none of them cannot match, and a fast substring scan
	// settles that far more cheaply than the regex VM can. `Plain.Passive` is
	// a hundred-way alternation whose program allocates a quarter of a
	// megabyte of thread state per run; most paragraphs contain no form of
	// "to be" at all and never pay for it.
	prefilter: []string,

	// The VM, kept rather than rebuilt. `vm.create` allocates two thread
	// arrays sized by the program, so building one per window turned a full
	// pass into a malloc benchmark.
	mach:     vmm.Machine,
	mach_ok:  bool,
	nthreads: int,
}

Swap :: struct {
	pat: Pattern,
	to:  string,
}

Pair :: struct {
	a: string,
	b: string,
}

Rule :: struct {
	name:       string, // "Plain.Hedging"
	pack:       string,
	id:         string,
	kind:       Rule_Kind,
	sev:        Severity,
	message:    string,
	desc:       string, // why it matters, shown in the UI
	link:       string,
	scope:      Scope_Sel,
	ignorecase: bool,
	nonword:    bool,
	alpha:      bool,

	// existence / occurrence / repetition
	pat:        Pattern,

	// substitution
	swaps:      []Swap,

	// occurrence
	max_n:      int,
	min_n:      int,
	has_max:    bool,
	has_min:    bool,

	// consistency
	pairs:      []Pair,

	// conditional
	first:      Pattern,
	second:     Pattern,

	// readability
	metrics:    []Metric,
	grade:      f64,

	// capitalization
	cased:      Cased,

	// shared
	exceptions: []string,
	fix:        string, // a replacement offered for every match
	drop:       bool, // the suggestion is "delete this"
	src_path:   string,
}

// ---------------------------------------------------------------------------
// Pattern compilation
// ---------------------------------------------------------------------------

// clone_list copies a list of strings out of the parse arena. Every string a
// Rule keeps has to outlive the YAML tree it came from, and a slice of temp
// strings that looks fine in the selftest and is garbage by the first
// keystroke is exactly the bug this exists to prevent.
clone_list :: proc(src: []string, allocator: Allocator) -> []string {
	if len(src) == 0 {
		return nil
	}
	out := make([]string, len(src), allocator)
	for s, i in src {
		out[i] = strings.clone(s, allocator)
	}
	return out
}

RX_META :: "\\^$.|?*+()[]{}"

// prefilter_on is a test seam, not a setting. `test_prefilter` runs every
// shipped rule over a corpus with it off and then on and asserts the two
// alert sets are identical — which is the only way to be sure an optimisation
// whose whole job is to skip work is not skipping a real match. It found two
// bugs on its first run.
prefilter_on := true

is_literal_token :: proc(t: string) -> bool {
	if t == "" {
		return false
	}
	for i in 0 ..< len(t) {
		if strings.index_byte(RX_META, t[i]) >= 0 {
			return false
		}
	}
	return true
}

// pattern_make builds one matcher from a token list. Vale joins the tokens
// into `\b(?:a|b|c)\b` unless `nonword` is set, and so does this — except
// when every token is a plain literal, where a direct scan is both faster and
// exactly equivalent, which matters because this runs per keystroke.
pattern_make :: proc(
	tokens: []string,
	fold, nonword: bool,
	allocator := context.allocator,
) -> (
	p: Pattern,
	err: string,
) {
	if len(tokens) == 0 {
		return {}, "no tokens"
	}
	p.fold = fold
	p.nonword = nonword

	all_lit := true
	for t in tokens {
		if !is_literal_token(t) {
			all_lit = false
			break
		}
	}
	if all_lit {
		lits := make([]string, len(tokens), allocator)
		for t, i in tokens {
			lits[i] = strings.clone(t, allocator)
		}
		p.lits = lits
		p.src = strings.clone(strings.join(tokens, "|", context.temp_allocator), allocator)
		return p, ""
	}

	sb := strings.builder_make(context.temp_allocator)
	if !nonword {
		strings.write_string(&sb, "\\b(?:")
	} else {
		strings.write_string(&sb, "(?:")
	}
	for t, i in tokens {
		if i > 0 {
			strings.write_byte(&sb, '|')
		}
		strings.write_string(&sb, t)
	}
	strings.write_string(&sb, nonword ? ")" : ")\\b")
	src := strings.clone(strings.to_string(sb), allocator)

	flags: rx.Flags
	if fold {
		flags |= {.Case_Insensitive}
	}
	re, rerr := rx.create(src, flags, allocator)
	if rerr != nil {
		delete(src, allocator)
		return {}, fmt.aprintf("bad pattern %q: %v", src, rerr, allocator = allocator)
	}
	p.src = src
	p.re = re
	p.has_re = true
	pattern_prepare(&p, allocator)
	return p, ""
}

// pattern_raw compiles a pattern that is already a complete regex, with no
// token joining — Vale's `raw:` key and the `first`/`second` of a conditional.
pattern_raw :: proc(
	src: string,
	fold: bool,
	allocator := context.allocator,
) -> (
	p: Pattern,
	err: string,
) {
	if src == "" {
		return {}, "empty pattern"
	}
	flags: rx.Flags
	if fold {
		flags |= {.Case_Insensitive}
	}
	kept := strings.clone(src, allocator)
	re, rerr := rx.create(kept, flags, allocator)
	if rerr != nil {
		delete(kept, allocator)
		return {}, fmt.aprintf("bad pattern %q: %v", src, rerr, allocator = allocator)
	}
	p.src = kept
	p.re = re
	p.has_re = true
	p.fold = fold
	p.nonword = true
	pattern_prepare(&p, allocator)
	return p, ""
}

// pattern_prepare builds the VM once and works out the prefilter.
pattern_prepare :: proc(p: ^Pattern, allocator: Allocator) {
	if !p.has_re {
		return
	}
	p.prefilter = prefilter_of(p.src, allocator)
	p.mach = vmm.create(p.re.program, "", allocator)
	p.mach.class_data = p.re.class_data
	p.nthreads = max(1, vmm.opcode_count(p.mach.code) - 1)
	p.mach_ok = true
}

// prefilter_of finds literals a match must contain.
//
// Two shapes are recognised, and between them they cover every pattern a style
// pack writes. A leading all-literal alternation — `\b(?:is|was|were)\s+...` —
// means one of those words has to be there. Otherwise the longest run of
// literal characters at the top level of the pattern, outside any group,
// class or optional quantifier, has to be there: `\w{4,}ly` must contain
// "ly", and `there (?:is|are) ` must contain "there ".
//
// Getting this wrong in the unsafe direction would silently drop alerts, so
// anything it is not sure about returns nothing and the regex runs.
prefilter_of :: proc(src: string, allocator: Allocator) -> []string {
	s := src
	// Up to a few layers of `\b(?: ... )\b`: `pattern_make` wraps whatever a
	// rule file wrote, and a rule file often wrote a wrapper of its own.
	for pass in 0 ..< 4 {
		if strings.has_prefix(s, "\\b") {
			s = s[2:]
		}
		if !strings.has_prefix(s, "(?:") {
			break
		}
		close, alts := group_split(s, 3, context.temp_allocator)
		if close < 0 {
			break
		}
		// A quantifier on the group makes the whole thing optional.
		if close + 1 < len(s) && (s[close + 1] == '?' || s[close + 1] == '*') {
			break
		}
		if len(alts) > 1 {
			all := true
			for t in alts {
				if t == "" || !is_literal_token(t) {
					all = false
					break
				}
			}
			if all {
				out := make([]string, len(alts), allocator)
				for t, k in alts {
					out[k] = strings.clone(t, allocator)
				}
				return out
			}
			break
		}
		// One alternative: unwrap it and look again at what is inside.
		if len(alts) == 1 && alts[0] != s {
			s = alts[0]
			continue
		}
		break
	}
	// Shape two: the longest mandatory top-level literal run.
	best, best_at := 0, -1
	depth := 0
	run_at := -1
	i := 0
	for i < len(s) {
		c := s[i]
		opt := i + 1 < len(s) && (s[i + 1] == '?' || s[i + 1] == '*' || s[i + 1] == '{')
		switch {
		case c == '\\':
			i += 2
			run_at = -1
			continue
		case c == '(' || c == '[' || c == '{':
			depth += 1
			run_at = -1
		case c == ')' || c == ']' || c == '}':
			depth = max(0, depth - 1)
			run_at = -1
		case depth > 0 || strings.index_byte(RX_META, c) >= 0 || opt:
			run_at = -1
		case:
			if run_at < 0 {
				run_at = i
			}
			if i - run_at + 1 > best {
				best = i - run_at + 1
				best_at = run_at
			}
		}
		i += 1
	}
	if best >= 2 && best_at >= 0 {
		out := make([]string, 1, allocator)
		out[0] = strings.clone(s[best_at:best_at + best], allocator)
		return out
	}
	return nil
}

// group_split finds the `)` closing the group opened before `at` and splits
// its body on the `|`s at that group's own depth — never on a nested one,
// which is what made the first version of this give up on every interesting
// pattern.
@(private = "file")
group_split :: proc(s: string, at: int, allocator: Allocator) -> (close: int, alts: []string) {
	depth := 1
	i := at
	start := at
	out := make([dynamic]string, 0, 8, allocator)
	for i < len(s) {
		switch s[i] {
		case '\\':
			i += 2
			continue
		case '[':
			// A class: skip it whole, so a `|` inside one is not a split.
			i += 1
			if i < len(s) && s[i] == '^' {
				i += 1
			}
			if i < len(s) && s[i] == ']' {
				i += 1
			}
			for i < len(s) && s[i] != ']' {
				if s[i] == '\\' {
					i += 1
				}
				i += 1
			}
		case '{':
			depth += 1
		case '}':
			depth = max(1, depth - 1)
		case '(':
			depth += 1
		case ')':
			depth -= 1
			if depth == 0 {
				append(&out, s[start:i])
				return i, out[:]
			}
		case '|':
			if depth == 1 {
				append(&out, s[start:i])
				start = i + 1
			}
		}
		i += 1
	}
	return -1, nil
}

pattern_destroy :: proc(p: ^Pattern, allocator := context.allocator) {
	if p.mach_ok {
		vmm.destroy(p.mach, allocator)
	}
	for l in p.prefilter {
		delete(l, allocator)
	}
	delete(p.prefilter, allocator)
	if p.has_re {
		rx.destroy_regex(p.re, allocator)
	}
	for l in p.lits {
		delete(l, allocator)
	}
	delete(p.lits, allocator)
	delete(p.src, allocator)
	p^ = {}
}

// ---------------------------------------------------------------------------
// Scope parsing
// ---------------------------------------------------------------------------

scope_parse :: proc(s: string) -> Scope_Sel {
	out := Scope_Sel{}
	if s == "" {
		return out
	}
	rest := s
	for part in strings.split_iterator(&rest, ",") {
		t := strings.trim_space(part)
		if t == "" {
			continue
		}
		if t[0] == '~' {
			out.negate = true
			t = t[1:]
		}
		// A format qualifier Vale allows and this ignores: `md.blockquote`.
		for pre in ([?]string{"md.", "markdown.", "rst.", "adoc.", "html.", "text."}) {
			if strings.has_prefix(t, pre) {
				t = t[len(pre):]
			}
		}
		switch {
		case t == "sentence":
			out.unit = .Sentence
		case t == "paragraph":
			out.unit = .Paragraph
		case t == "summary":
			out.unit = .Summary
		case t == "text" || t == "raw":
		// the default: everything that is prose
		case t == "blockquote":
			out.kinds |= {.Blockquote}
		case t == "list":
			out.kinds |= {.List}
		case t == "table" || strings.has_prefix(t, "table."):
			out.kinds |= {.Table_Cell}
		case strings.has_prefix(t, "heading"):
			out.kinds |= {.Heading}
			if strings.has_prefix(t, "heading.h") && len(t) > 9 {
				d := int(t[9] - '0')
				if d >= 1 && d <= 6 {
					out.level = d
				}
			}
		}
	}
	return out
}

scope_allows :: proc(sel: Scope_Sel, b: Block) -> bool {
	if b.kind == .None {
		return false
	}
	if sel.kinds == {} {
		return !sel.negate
	}
	hit := b.kind in sel.kinds
	if hit && sel.level > 0 && b.kind == .Heading {
		hit = b.level == sel.level
	}
	return sel.negate ? !hit : hit
}

// ---------------------------------------------------------------------------
// Compiling a rule file
// ---------------------------------------------------------------------------

// rule_compile turns one YAML document into a Rule. `pack` and `id` make the
// name Vale would print: `Microsoft.Contractions`.
rule_compile :: proc(
	pack, id, src: string,
	allocator := context.allocator,
) -> (
	r: Rule,
	err: string,
) {
	arena := runtime.default_temp_allocator_temp_begin()
	defer runtime.default_temp_allocator_temp_end(arena)

	doc, yerr := y_parse(src, context.temp_allocator)
	if yerr.what != "" {
		return {}, fmt.aprintf("%s/%s.yml:%d: %s", pack, id, yerr.line, yerr.what, allocator = allocator)
	}

	ext := y_str(&doc, "extends")
	kind := Rule_Kind.Existence
	found := false
	for k in Rule_Kind {
		if RULE_KIND_NAME[k] == ext {
			kind = k
			found = true
			break
		}
	}
	if !found {
		return {}, fmt.aprintf("%s/%s.yml: unknown extends %q", pack, id, ext, allocator = allocator)
	}

	r.pack = strings.clone(pack, allocator)
	r.id = strings.clone(id, allocator)
	r.name = fmt.aprintf("%s.%s", pack, id, allocator = allocator)
	r.kind = kind
	r.sev = severity_from(y_str(&doc, "level"), .Warning)
	r.message = strings.clone(y_str(&doc, "message"), allocator)
	r.desc = strings.clone(strings.trim_space(y_str(&doc, "description")), allocator)
	r.link = strings.clone(y_str(&doc, "link"), allocator)
	r.scope = scope_parse(y_str(&doc, "scope"))
	r.ignorecase = y_bool(&doc, "ignorecase", false)
	r.nonword = y_bool(&doc, "nonword", false)
	r.alpha = y_bool(&doc, "alpha", false)

	r.exceptions = clone_list(y_list(&doc, "exceptions", context.temp_allocator), allocator)

	// `action: {name: replace, params: [x]}` is Vale's own way of carrying a
	// fix, so a rule written for Vale brings its suggestion along.
	if act := y_get(&doc, "action"); act != nil && act.kind == .Map {
		switch y_str(act, "name") {
		case "replace":
			ps := y_list(act, "params", context.temp_allocator)
			if len(ps) > 0 {
				r.fix = strings.clone(ps[0], allocator)
			}
		case "remove":
			r.drop = true
		}
	}

	fold := r.ignorecase

	switch kind {
	case .Existence:
		toks := y_list(&doc, "tokens", context.temp_allocator)
		raw := y_list(&doc, "raw", context.temp_allocator)
		if len(raw) > 0 {
			joined := strings.concatenate(raw, context.temp_allocator)
			r.pat, err = pattern_raw(joined, fold, allocator)
		} else if len(toks) > 0 {
			r.pat, err = pattern_make(toks, fold, r.nonword, allocator)
		} else {
			err = "existence needs `tokens` or `raw`"
		}

	case .Substitution:
		sw := y_get(&doc, "swap")
		if sw == nil || sw.kind != .Map || len(sw.keys) == 0 {
			err = "substitution needs a `swap` map"
			break
		}
		swaps := make([dynamic]Swap, 0, len(sw.keys), allocator)
		for k, i in sw.keys {
			to := sw.vals[i].kind == .Scalar ? sw.vals[i].text : ""
			one := [1]string{k}
			p, perr := pattern_make(one[:], fold, r.nonword, allocator)
			if perr != "" {
				err = perr
				break
			}
			append(&swaps, Swap{pat = p, to = strings.clone(to, allocator)})
		}
		r.swaps = swaps[:]

	case .Occurrence:
		tok := y_str(&doc, "token")
		if tok == "" {
			err = "occurrence needs a `token`"
			break
		}
		r.pat, err = pattern_raw(tok, fold, allocator)
		if v := y_get(&doc, "max"); v != nil {
			r.max_n = y_int(&doc, "max", 0)
			r.has_max = true
		}
		if v := y_get(&doc, "min"); v != nil {
			r.min_n = y_int(&doc, "min", 0)
			r.has_min = true
		}
		if !r.has_max && !r.has_min {
			err = "occurrence needs `max` or `min`"
		}

	case .Consistency:
		ei := y_get(&doc, "either")
		if ei == nil || ei.kind != .Map || len(ei.keys) == 0 {
			err = "consistency needs an `either` map"
			break
		}
		ps := make([dynamic]Pair, 0, len(ei.keys), allocator)
		for k, i in ei.keys {
			b := ei.vals[i].kind == .Scalar ? ei.vals[i].text : ""
			append(
				&ps,
				Pair{a = strings.clone(k, allocator), b = strings.clone(b, allocator)},
			)
		}
		r.pairs = ps[:]

	case .Repetition:
		toks := y_list(&doc, "tokens", context.temp_allocator)
		if len(toks) == 0 {
			err = "repetition needs `tokens`"
			break
		}
		joined := strings.join(toks, "|", context.temp_allocator)
		r.pat, err = pattern_raw(len(toks) == 1 ? toks[0] : fmt.tprintf("(?:%s)", joined), fold, allocator)

	case .Conditional:
		f := y_str(&doc, "first")
		s := y_str(&doc, "second")
		if f == "" || s == "" {
			err = "conditional needs `first` and `second`"
			break
		}
		r.first, err = pattern_raw(f, fold, allocator)
		if err == "" {
			r.second, err = pattern_raw(s, fold, allocator)
		}

	case .Readability:
		names := y_list(&doc, "metrics", context.temp_allocator)
		ms := make([dynamic]Metric, 0, max(1, len(names)), allocator)
		for n in names {
			if m, ok := metric_from_name(n); ok {
				append(&ms, m)
			} else {
				err = fmt.aprintf("unknown metric %q", n, allocator = allocator)
			}
		}
		if len(ms) == 0 && err == "" {
			err = "readability needs `metrics`"
		}
		r.metrics = ms[:]
		r.grade = y_f64(&doc, "grade", 8)

	case .Spelling:
		// Parsed so that a style package containing one loads; see check.odin.
		r.exceptions = clone_list(y_list(&doc, "ignore", context.temp_allocator), allocator)
		if r.exceptions == nil {
			r.exceptions = clone_list(y_list(&doc, "filters", context.temp_allocator), allocator)
		}

	case .Capitalization:
		m := y_str(&doc, "match")
		switch m {
		case "$title":
			r.cased = .Title
		case "$sentence":
			r.cased = .Sentence_Case
		case "$lower":
			r.cased = .Lower
		case "$upper":
			r.cased = .Upper
		case:
			err = fmt.aprintf("unsupported capitalization match %q", m, allocator = allocator)
		}
		r.exceptions = clone_list(y_list(&doc, "exceptions", context.temp_allocator), allocator)
	}

	if err != "" {
		rule_destroy(&r, allocator)
		return {}, fmt.aprintf("%s/%s.yml: %s", pack, id, err, allocator = allocator)
	}
	return r, ""
}

rule_destroy :: proc(r: ^Rule, allocator := context.allocator) {
	pattern_destroy(&r.pat, allocator)
	pattern_destroy(&r.first, allocator)
	pattern_destroy(&r.second, allocator)
	for &s in r.swaps {
		pattern_destroy(&s.pat, allocator)
		delete(s.to, allocator)
	}
	delete(r.swaps, allocator)
	for p in r.pairs {
		delete(p.a, allocator)
		delete(p.b, allocator)
	}
	delete(r.pairs, allocator)
	for e in r.exceptions {
		delete(e, allocator)
	}
	delete(r.exceptions, allocator)
	delete(r.metrics, allocator)
	delete(r.name, allocator)
	delete(r.pack, allocator)
	delete(r.id, allocator)
	delete(r.message, allocator)
	delete(r.desc, allocator)
	delete(r.link, allocator)
	delete(r.fix, allocator)
	r^ = {}
}
