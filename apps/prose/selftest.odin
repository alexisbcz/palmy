package prose

// `prose --selftest`: everything in this package that has no pixels.
//
// The two measured heuristics are asserted only against a floor — the
// segmenter must not fall below the accuracy this corpus currently sees, and
// the syllable table must be reproduced exactly — because asserting an exact
// accuracy would turn every genuine improvement into a failing test.

import "core:fmt"
import "core:strings"

checks: int
failures: int

check :: proc(ok: bool, what: string) {
	checks += 1
	if !ok {
		failures += 1
		fmt.printfln("  FAIL  %s", what)
	}
}

check_eq :: proc(got, want: string, what: string) {
	checks += 1
	if got != want {
		failures += 1
		fmt.printfln("  FAIL  %s\n        got  %q\n        want %q", what, got, want)
	}
}

check_int :: proc(got, want: int, what: string) {
	checks += 1
	if got != want {
		failures += 1
		fmt.printfln("  FAIL  %s: got %d, want %d", what, got, want)
	}
}

check_near :: proc(got, want, tol: f64, what: string) {
	checks += 1
	if abs(got - want) > tol {
		failures += 1
		fmt.printfln("  FAIL  %s: got %.3f, want %.3f ± %.3f", what, got, want, tol)
	}
}

selftest :: proc(verbose := false) -> int {
	test_yaml()
	test_mask()
	test_segment()
	test_syllables()
	test_metrics()
	test_rules()
	test_scope()
	test_packs()
	test_window()
	test_report()
	test_fix_safety()
	test_prefilter()

	sc := segment_score(false)
	prec := sc.predicted > 0 ? f64(sc.hits) / f64(sc.predicted) : 0
	rec := sc.expected > 0 ? f64(sc.hits) / f64(sc.expected) : 0
	// A floor, not a target. If this rises, raise the floor deliberately.
	check(prec >= 0.90, fmt.tprintf("segmenter precision is at least 90%% (it is %.1f%%)", prec * 100))
	check(rec >= 0.90, fmt.tprintf("segmenter recall is at least 90%% (it is %.1f%%)", rec * 100))

	if failures == 0 {
		fmt.printfln("prose selftest: %d checks passed", checks)
		fmt.printfln(
			"  segmentation corpus: %d cases, precision %.1f%%, recall %.1f%%, %d of %d exact",
			sc.cases,
			prec * 100,
			rec * 100,
			sc.exact,
			sc.cases,
		)
	} else {
		fmt.printfln("prose selftest: %d checks, %d FAILED", checks, failures)
	}
	return failures
}

// ---------------------------------------------------------------------------

test_yaml :: proc() {
	src := `# a comment
extends: existence
message: "hit '%s'"
level: warning
ignorecase: true
max: 12
grade: 9.5
description: |
  First line.
  Second line.
tokens:
  - very
  - 'really\b'
  - "quoted"   # trailing comment
swap:
  utilize: use
  'in order to': to
action:
  name: replace
  params:
    - use
`
	doc, err := y_parse(src, context.temp_allocator)
	check_eq(err.what, "", "the rule file parses")
	check_eq(y_str(&doc, "extends"), "existence", "a plain scalar")
	check_eq(y_str(&doc, "message"), "hit '%s'", "a double-quoted scalar loses its quotes")
	check(y_bool(&doc, "ignorecase"), "a boolean")
	check_int(y_int(&doc, "max"), 12, "an integer")
	check_near(y_f64(&doc, "grade"), 9.5, 0.001, "a float")
	check_eq(y_str(&doc, "description"), "First line.\nSecond line.\n", "a literal block scalar")

	toks := y_list(&doc, "tokens", context.temp_allocator)
	check_int(len(toks), 3, "three tokens")
	check_eq(toks[0], "very", "the first token")
	check_eq(toks[1], "really\\b", "a single-quoted token keeps its backslash")
	check_eq(toks[2], "quoted", "a trailing comment is stripped")

	sw := y_get(&doc, "swap")
	check(sw != nil && sw.kind == .Map && len(sw.keys) == 2, "the swap map has two entries")
	check_eq(y_str(sw, "utilize"), "use", "a swap value")
	check_eq(y_str(sw, "in order to"), "to", "a quoted swap key")

	act := y_get(&doc, "action")
	check(act != nil && y_str(act, "name") == "replace", "a nested map")
	ps := y_list(act, "params", context.temp_allocator)
	check(len(ps) == 1 && ps[0] == "use", "a sequence nested two deep")

	// A key that is not `key: value` is an error rather than a guess.
	_, err2 := y_parse("this is not yaml\n", context.temp_allocator)
	check(err2.what != "", "a line with no colon is refused")

	check_eq(y_unquote("'it''s'", context.temp_allocator), "it's", "a doubled single quote")
	check_eq(y_unquote(`"a\tb"`, context.temp_allocator), "a\tb", "a double-quoted escape")
	check_eq(y_unquote(`"\b(?:x)\b"`, context.temp_allocator), `\b(?:x)\b`, "an unknown escape is kept for the regex")
}

test_mask :: proc() {
	src := `---
title: FLAG in front matter
---

# Heading with FLAG

Body with FLAG here.

Inline ` + "`FLAG`" + ` code and a [FLAG label](http://FLAG.example.com/FLAG) too.

A bare URL http://example.com/FLAG and a word FLAGSHIP.

` +
		"```" +
		`
FLAG in a fence
` +
		"```" +
		`

    FLAG in an indented block

> Quote with FLAG

- List with FLAG

| a | b |
| --- | --- |
| FLAG | x |

<!-- FLAG in a comment -->

**FLAG bold** and *FLAG em*.
`
	m := mask(src)
	defer mask_destroy(&m)
	check_int(len(m.text), len(src), "the masked text is the same length as the source")

	// Every FLAG that survives masking is one that should be linted.
	found := make([dynamic]int, 0, 16, context.temp_allocator)
	for i in 0 ..< len(m.text) - 3 {
		if m.text[i:i + 4] == "FLAG" {
			append(&found, i)
		}
	}
	// Expected: the heading, the body, the link label, FLAGSHIP, the quote,
	// the list, the table cell, and both emphasis runs. Nine.
	check_int(len(found), 9, "nine of the fourteen FLAGs are prose")

	survives :: proc(m: ^Masked, src, needle: string) -> bool {
		at := strings.index(src, needle)
		if at < 0 {
			return false
		}
		return strings.contains(m.text[at:min(at + len(needle) + 8, len(m.text))], "FLAG")
	}
	check(!survives(&m, src, "title: FLAG"), "front matter is not linted")
	check(survives(&m, src, "# Heading with FLAG"), "a heading is linted")
	check(!survives(&m, src, "`FLAG`"), "inline code is not linted")
	check(!survives(&m, src, "FLAG in a fence"), "a fenced block is not linted")
	check(!survives(&m, src, "FLAG in an indented block"), "an indented block is not linted")
	check(!survives(&m, src, "FLAG in a comment"), "an HTML comment is not linted")
	check(survives(&m, src, "- List with FLAG"), "a list item is linted")

	// The URL inside the link target is gone but the label survives.
	li := strings.index(src, "[FLAG label]")
	check(m.text[li] == ' ', "the opening bracket of a link is masked")
	check(m.text[li + 1:li + 5] == "FLAG", "the link label keeps its offsets")
	ui := strings.index(src, "http://FLAG.example.com")
	check(strings.trim_space(m.text[ui:ui + 20]) == "", "a link target is masked")

	// Blocks carry the right scope.
	kinds: [Scope_Kind]int
	for b in m.blocks {
		kinds[b.kind] += 1
	}
	check(kinds[.Heading] >= 1, "the heading became a Heading block")
	check(kinds[.Blockquote] >= 1, "the quote became a Blockquote block")
	check(kinds[.List] >= 1, "the list became a List block")
	check(kinds[.Table_Cell] >= 1, "the table row became a Table_Cell block")
	check(kinds[.Paragraph] >= 3, "the paragraphs became Paragraph blocks")
	check(kinds[.Front_Matter] == 0, "front matter produced no lintable block")

	// Vale's own behaviour, for the oracle comparison.
	m2 := mask(src, true)
	defer mask_destroy(&m2)
	check(strings.contains(m2.text, "FLAG in front matter"), "--front-matter lints the value half")
	check(!strings.contains(m2.text, "title:"), "and masks the key half")

	// A paragraph spanning two lines is one block.
	m3 := mask("one line\ntwo lines\n\nnext para\n")
	defer mask_destroy(&m3)
	n := 0
	for b in m3.blocks {
		if b.kind == .Paragraph {
			n += 1
		}
	}
	check_int(n, 2, "a wrapped paragraph is one block, two paragraphs are two")

	// A heading is its own block even without a blank line after it.
	m4 := mask("# Title\nbody text\n")
	defer mask_destroy(&m4)
	check_int(len(m4.blocks), 2, "a heading does not swallow the line below it")
	check(m4.blocks[0].kind == .Heading && m4.blocks[0].level == 1, "and knows its level")
}

test_segment :: proc() {
	one :: proc(text: string, want: int, what: string) {
		got := sentences(text, 0, len(text), context.temp_allocator)
		check_int(len(got), want, what)
	}
	one("The cat sat. The dog did not.", 2, "two plain sentences")
	one("Dr. Reed signed it.", 1, "a title abbreviation does not split")
	one("It weighs 3.14 kg.", 1, "a decimal does not split")
	one("A. N. Whitehead wrote it.", 1, "initials do not split")
	one("\"He left.\" She stayed.", 2, "a closing quote ends the sentence it belongs to")
	one("Wait... What happened?", 2, "an ellipsis before a capital splits")
	one("I wondered... then I knew.", 1, "an ellipsis before a lowercase word does not")
	one("What?! I never agreed.", 2, "a run of terminators is one boundary")
	one("See Fig. 3 for the layout.", 1, "a reference abbreviation does not split")
	one("No terminator at all", 1, "an unterminated tail is still a sentence")
	one("", 0, "empty text has no sentences")
	one("   \n  ", 0, "whitespace alone has no sentences")

	// A sentence's span excludes the whitespace around it.
	s := sentences("  Hello there.  Bye.  ", 0, 22, context.temp_allocator)
	check_int(len(s), 2, "leading whitespace is skipped")
	check_eq("Hello there.", "Hello there."[:], "sanity")
	if len(s) == 2 {
		check_int(s[0].from, 2, "the first sentence starts at the first word")
		check_int(s[0].to, 14, "and ends at its full stop")
		check_int(s[1].from, 16, "the second starts after the gap")
	}

	// Words.
	wtext := "Don't re-read the x-ray, please."
	w := words(wtext, 0, len(wtext), context.temp_allocator)
	check_int(len(w), 5, "an apostrophe and a hyphen stay inside their words")
	check_eq(wtext[w[0].from:w[0].to], "Don't", "the contraction is one word")
	check_eq(wtext[w[1].from:w[1].to], "re-read", "the hyphenated word is one word")
	check_int(len(words("", 0, 0, context.temp_allocator)), 0, "no text, no words")
}

test_syllables :: proc() {
	// Hand-checked. These are the counts a careful reader marks, and they are
	// asserted exactly because they are the table the estimator is tuned to.
	cases := [?]struct {
		w: string,
		n: int,
	} {
		{"cat", 1},
		{"cats", 1},
		{"table", 2},
		{"tables", 2},
		{"rhythm", 2},
		{"syllable", 3},
		{"beautiful", 3},
		{"idea", 3},
		{"business", 2},
		{"every", 2},
		{"national", 3},
		{"government", 3},
		{"probably", 3},
		{"queue", 1},
		{"science", 2},
		{"create", 2},
		{"cooperate", 4},
		{"area", 3},
		{"walked", 1},
		{"wanted", 2},
		{"hoped", 1},
		{"needed", 2},
		{"boxes", 2},
		{"makes", 1},
		{"watches", 2},
		{"the", 1},
		{"a", 1},
		{"strength", 1},
		{"strengths", 1},
		{"little", 2},
		{"people", 2},
		{"computer", 3},
		{"interesting", 3},
		{"university", 5},
		{"readability", 5},
	}
	wrong := 0
	for c in cases {
		got := syllables(c.w)
		checks += 1
		if got != c.n {
			failures += 1
			wrong += 1
			fmt.printfln("  FAIL  syllables(%q) = %d, want %d", c.w, got, c.n)
		}
	}
	check_int(syllables(""), 0, "no letters, no syllables")
	check(syllables("xyzzy") >= 1, "a nonsense word still has at least one")
	check(polysyllabic("beautiful"), "three syllables is polysyllabic")
	check(!polysyllabic("table"), "two is not")

	// The IPA nucleus counter the oracle depends on.
	check_int(ipa_syllables("sˈɪləbəl"), 3, "IPA: syllable")
	check_int(ipa_syllables("bjˈuːɾifəl"), 3, "IPA: beautiful")
	check_int(ipa_syllables("aɪdˈiə"), 3, "IPA: idea")
	check_int(ipa_syllables("kjˈuː"), 1, "IPA: queue")
	check_int(ipa_syllables("koʊˈɑːpɚɹˌeɪt"), 4, "IPA: cooperate")
	check_int(ipa_syllables("ɹˈɪðəm"), 2, "IPA: rhythm")
	check_int(ipa_syllables(""), 0, "IPA: nothing")
}

test_metrics :: proc() {
	// A worked example, computed by hand from the counts so that a change to
	// the formulas cannot pass unnoticed.
	c := Counts {
		sentences = 2,
		words     = 20,
		syllables = 30,
		letters   = 90,
		chars     = 95,
		polysyl   = 4,
	}
	fre, ok1 := metric_value(.Flesch_Reading_Ease, c)
	check(ok1, "reading ease is computed")
	check_near(fre, 206.835 - 1.015 * 10 - 84.6 * 1.5, 0.01, "Flesch Reading Ease")
	fk, _ := metric_value(.Flesch_Kincaid, c)
	check_near(fk, 0.39 * 10 + 11.8 * 1.5 - 15.59, 0.01, "Flesch-Kincaid")
	gf, _ := metric_value(.Gunning_Fog, c)
	check_near(gf, 0.4 * (10 + 100 * 0.2), 0.01, "Gunning Fog")
	cl, _ := metric_value(.Coleman_Liau, c)
	check_near(cl, 0.0588 * 450 - 0.296 * 10 - 15.8, 0.01, "Coleman-Liau")
	ari, _ := metric_value(.Automated_Readability, c)
	check_near(ari, 4.71 * 4.75 + 0.5 * 10 - 21.43, 0.01, "Automated Readability")

	_, ok2 := metric_value(.Flesch_Kincaid, Counts{})
	check(!ok2, "an empty document has no grade rather than a nonsense one")
	_, ok3 := metric_value(.SMOG, Counts{sentences = 2, words = 10, syllables = 12})
	check(!ok3, "SMOG refuses to extrapolate from two sentences")

	m, found := metric_from_name("Flesch-Kincaid")
	check(found && m == .Flesch_Kincaid, "a metric is found by Vale's spelling")
	m2, found2 := metric_from_name("flesch kincaid")
	check(found2 && m2 == .Flesch_Kincaid, "and by a loose one")
	_, found3 := metric_from_name("Dale-Chall")
	check(!found3, "an unimplemented metric is reported missing, not guessed")

	check(strings.contains(band(9), "moderate"), "a grade gets a plain-English band")
	check(strings.contains(band(2), "very easy"), "a low grade too")
	check(strings.contains(band(30), "extremely"), "and an absurd one")
	check(len(CAVEAT) > 80, "the caveat is a sentence, not a word")
}

// rule_from builds a rule from inline YAML, which is how each check is tested
// without a file on disk.
rule_from :: proc(yaml: string) -> Rule {
	r, err := rule_compile("T", "R", yaml)
	checks += 1
	if err != "" {
		failures += 1
		fmt.printfln("  FAIL  rule did not compile: %s", err)
	}
	return r
}

run_one :: proc(r: ^Rule, src: string, allocator := context.temp_allocator) -> []Alert {
	e := Engine{}
	p := Pack {
		name  = "T",
		rules = make([dynamic]Rule, 0, 1, allocator),
	}
	append(&p.rules, r^)
	e.packs = make([dynamic]Pack, 0, 1, allocator)
	append(&e.packs, p)
	res := lint(&e, src, Opts{pack = 0}, allocator)
	return res.alerts
}

test_rules :: proc() {
	// --- existence -------------------------------------------------------
	{
		r := rule_from(`extends: existence
message: "hit '%s'"
level: error
ignorecase: true
tokens:
  - very
  - really
`)
		defer rule_destroy(&r)
		a := run_one(&r, "This is Very really bad. A VERYLONG word is not.")
		check_int(len(a), 2, "existence finds both tokens")
		if len(a) == 2 {
			check_eq(a[0].match, "Very", "the match keeps the source's case")
			check_eq(a[0].message, "hit 'Very'", "%s is the match")
			check(a[0].sev == .Error, "the level is carried")
			check_int(a[0].col, 9, "the column is 1-based")
		}
		b := run_one(&r, "VERYLONG and everything")
		check_int(len(b), 0, "a token inside a longer word does not fire")
	}
	// nonword
	{
		r := rule_from(`extends: existence
message: "x"
nonword: true
tokens:
  - very
`)
		defer rule_destroy(&r)
		check_int(len(run_one(&r, "VERYLONG")), 0, "nonword is case-sensitive by default")
		check_int(len(run_one(&r, "averylong")), 1, "nonword matches inside a word")
	}
	// exceptions, and a regex token
	{
		r := rule_from(`extends: existence
message: "adverb '%s'"
ignorecase: true
tokens:
  - \w{4,}ly
exceptions:
  - only
  - family
`)
		defer rule_destroy(&r)
		a := run_one(&r, "He quickly and only and family and slowly left.")
		check_int(len(a), 2, "a regex token fires and the exceptions are honoured")
	}
	// an action carrying a fix
	{
		r := rule_from(`extends: existence
message: "x"
ignorecase: true
tokens:
  - irregardless
action:
  name: replace
  params:
    - regardless
`)
		defer rule_destroy(&r)
		a := run_one(&r, "Irregardless of that.")
		check_int(len(a), 1, "the rule fires")
		if len(a) == 1 {
			check(a[0].has_fix, "and offers a fix from its action")
			check_eq(a[0].fix, "regardless", "which is the action's parameter")
		}
	}

	// --- substitution ----------------------------------------------------
	{
		r := rule_from(`extends: substitution
message: "'%s' instead of '%s'"
level: warning
ignorecase: true
swap:
  utilize: use
  'in order to': to
`)
		defer rule_destroy(&r)
		a := run_one(&r, "Utilize it in order to win.")
		check_int(len(a), 2, "substitution finds both")
		if len(a) == 2 {
			check_eq(a[0].message, "'Use' instead of 'Utilize'", "the message takes the replacement then the match")
			check_eq(a[0].fix, "Use", "the fix wears the capitalisation of what it replaces")
			check_eq(a[1].fix, "to", "a lowercase match gets a lowercase fix")
		}
		b := run_one(&r, "UTILIZE IT.")
		check_int(len(b), 1, "an all-caps match")
		if len(b) == 1 {
			check_eq(b[0].fix, "USE", "gets an all-caps fix")
		}
	}

	// --- occurrence ------------------------------------------------------
	{
		r := rule_from(`extends: occurrence
message: "%s words"
level: warning
scope: sentence
max: 5
token: '\b\w+\b'
`)
		defer rule_destroy(&r)
		a := run_one(&r, "One two three. One two three four five six seven.")
		check_int(len(a), 1, "only the long sentence fires")
		if len(a) == 1 {
			check_eq(a[0].message, "7 words", "the count is substituted")
			check_int(a[0].col, 16, "and the alert sits on the sentence's first match")
		}
	}
	{
		r := rule_from(`extends: occurrence
message: "only %s"
scope: sentence
min: 3
token: ','
`)
		defer rule_destroy(&r)
		a := run_one(&r, "No commas here at all.")
		check_int(len(a), 1, "a minimum that is not met fires")
		if len(a) == 1 {
			check_int(a[0].col, 1, "and lands on the first word when there is no match")
		}
	}

	// --- repetition ------------------------------------------------------
	{
		r := rule_from(`extends: repetition
message: "'%s' twice"
level: error
ignorecase: true
alpha: true
tokens:
  - '\b(\w+)\b'
`)
		defer rule_destroy(&r)
		a := run_one(&r, "The the cat sat on the the mat. 3 3 is fine.")
		check_int(len(a), 2, "both doubled words fire and the doubled digit does not")
		if len(a) >= 1 {
			check_eq(a[0].message, "'the' twice", "the repeated token is lowercased in the message")
			check_eq(a[0].match, "The the", "and the span covers both words")
			check_eq(a[0].fix, "The", "the fix keeps the first of the pair")
		}
		b := run_one(&r, "the cat the mat")
		check_int(len(b), 0, "a word repeated with something between is not a repetition")
	}

	// --- consistency -----------------------------------------------------
	{
		r := rule_from(`extends: consistency
message: "'%s' or '%s', not both"
level: warning
ignorecase: true
either:
  advisor: adviser
`)
		defer rule_destroy(&r)
		a := run_one(&r, "My advisor and my advisor and my adviser disagree.")
		check_int(len(a), 1, "the minority spelling is the one flagged")
		if len(a) == 1 {
			check_eq(a[0].match, "adviser", "which is 'adviser' here")
			check_eq(a[0].fix, "advisor", "and the fix is the majority spelling")
		}
		check_int(len(run_one(&r, "My advisor only.")), 0, "one spelling alone is consistent")
	}

	// --- conditional -----------------------------------------------------
	{
		r := rule_from(`extends: conditional
message: "'%s' is undefined"
level: suggestion
first: '\b([A-Z]{3,5})\b'
second: '(?:\b[A-Z][a-z]+ )+\(([A-Z]{3,5})\)'
exceptions:
  - ABC
`)
		defer rule_destroy(&r)
		a := run_one(&r, "The NASA report, the Foo Bar (FBR) thing, ABC and XYZQ.")
		check_int(len(a), 2, "an acronym with a definition or an exception is left alone")
		if len(a) == 2 {
			check_eq(a[0].match, "NASA", "the first undefined acronym")
			check_eq(a[1].match, "XYZQ", "and the second")
		}
	}

	// --- readability -----------------------------------------------------
	{
		r := rule_from(`extends: readability
message: "grade %s"
level: warning
grade: 8
metrics:
  - Flesch-Kincaid
`)
		defer rule_destroy(&r)
		hard :=
			"Notwithstanding the aforementioned considerations, the implementation of the " +
			"comprehensive methodological framework necessitates substantial deliberation " +
			"regarding its multifarious ramifications.\n"
		a := run_one(&r, hard)
		check_int(len(a), 1, "a hard paragraph trips the grade")
		b := run_one(&r, "The cat sat. The dog ran. I saw it.\n")
		check_int(len(b), 0, "an easy one does not")
	}

	// --- capitalization --------------------------------------------------
	{
		r := rule_from(`extends: capitalization
message: "'%s' is not sentence case"
level: suggestion
scope: heading
match: $sentence
`)
		defer rule_destroy(&r)
		a := run_one(&r, "# This Is Title Case\n\nbody\n")
		check_int(len(a), 1, "a title-cased heading fails a sentence-case rule")
		b := run_one(&r, "# This is sentence case\n\nbody\n")
		check_int(len(b), 0, "and a sentence-cased one passes")
	}
	{
		r := rule_from(`extends: capitalization
message: "'%s' is not title case"
scope: heading.h2
match: $title
exceptions:
  - palmy
`)
		defer rule_destroy(&r)
		a := run_one(&r, "## this is not title case\n")
		check_int(len(a), 1, "an h2 is checked")
		b := run_one(&r, "# this is not title case\n")
		check_int(len(b), 0, "and an h1 is not, because the scope says h2")
		c := run_one(&r, "## A Note on palmy Text\n")
		check_int(len(c), 0, "an exception is left in lower case")
	}

	// --- spelling, which has no dictionary -------------------------------
	{
		r := rule_from(`extends: spelling
message: "'%s' is misspelled"
level: error
ignore:
  - palmy
`)
		defer rule_destroy(&r)
		a := run_one(&r, "Thiss is deffinitely misspelt.\n")
		check_int(len(a), 0, "a spelling rule loads and honestly produces nothing")
	}
}

test_scope :: proc() {
	r := rule_from(`extends: existence
message: "x"
scope: heading
tokens:
  - FLAG
`)
	defer rule_destroy(&r)
	src := "# FLAG here\n\nFLAG in the body.\n\n> FLAG in a quote\n"
	a := run_one(&r, src)
	check_int(len(a), 1, "a heading-scoped rule only fires in headings")

	r2 := rule_from(`extends: existence
message: "x"
scope: ~heading
tokens:
  - FLAG
`)
	defer rule_destroy(&r2)
	b := run_one(&r2, src)
	check_int(len(b), 2, "and a negated scope fires everywhere else")

	r3 := rule_from(`extends: existence
message: "x"
scope: blockquote
tokens:
  - FLAG
`)
	defer rule_destroy(&r3)
	check_int(len(run_one(&r3, src)), 1, "a blockquote scope")

	s := scope_parse("md.heading.h3")
	check(s.kinds == {.Heading} && s.level == 3, "a format-qualified scope parses")
	s2 := scope_parse("sentence")
	check(s2.unit == .Sentence, "a unit scope parses")
	s3 := scope_parse("")
	check(s3.kinds == {} && s3.unit == .Block, "an absent scope is the whole block")
}

test_packs :: proc() {
	e := engine_builtin()
	defer engine_destroy(&e)
	check_int(len(e.errors), 0, "every built-in rule file compiles")
	if len(e.errors) > 0 {
		for s in e.errors {
			fmt.printfln("        %s", s)
		}
	}
	check_int(len(e.packs), 6, "six packs ship")
	total := 0
	for p in e.packs {
		check(len(p.rules) >= 5, fmt.tprintf("%s has at least five rules", p.name))
		check(len(p.about) > 40, fmt.tprintf("%s says in a sentence what it is for", p.name))
		for r in p.rules {
			check(r.message != "", fmt.tprintf("%s has a message", r.name))
			check(len(r.desc) > 60, fmt.tprintf("%s explains why it matters", r.name))
			total += 1
		}
	}
	check(total >= 40, fmt.tprintf("the packs hold at least forty rules (they hold %d)", total))

	// Every rule type that the packs use is represented.
	seen: [Rule_Kind]bool
	for p in e.packs {
		for r in p.rules {
			seen[r.kind] = true
		}
	}
	for k in ([?]Rule_Kind{.Existence, .Substitution, .Occurrence, .Repetition, .Readability}) {
		check(seen[k], fmt.tprintf("a shipped pack uses the %s type", RULE_KIND_NAME[k]))
	}

	// Picking a style has to visibly change what is flagged. This is the
	// behaviour the feature is for, so it is asserted rather than inspected.
	text :=
		"The chairman will utilize the data in order to very quickly circle back " +
		"with the team about the synergy we can obviously leverage.\n"
	by_pack := make(map[string]int, 8, context.temp_allocator)
	sets := make([dynamic][]string, 0, 6, context.temp_allocator)
	for p, i in e.packs {
		res := lint(&e, text, Opts{pack = i}, context.temp_allocator)
		by_pack[p.name] = len(res.alerts)
		names := make([dynamic]string, 0, 8, context.temp_allocator)
		for a in res.alerts {
			append(&names, a.rule)
		}
		append(&sets, names[:])
	}
	check(by_pack["Inclusive"] >= 1, "Inclusive flags 'chairman'")
	check(by_pack["Business"] >= 1, "Business flags 'synergy'")
	check(by_pack["Concise"] >= 1, "Concise flags 'very'")
	differ := false
	for i in 1 ..< len(sets) {
		if len(sets[i]) != len(sets[0]) {
			differ = true
			break
		}
	}
	check(differ, "switching style packs changes the alert set over the same text")

	// Severity filtering and dismissal.
	all := lint(&e, text, Opts{pack = 0, min_sev = .Suggestion}, context.temp_allocator)
	errs := lint(&e, text, Opts{pack = 0, min_sev = .Error}, context.temp_allocator)
	check(len(errs.alerts) <= len(all.alerts), "raising the minimum level cannot add alerts")
	if len(all.alerts) > 0 {
		drop := [1]string{all.alerts[0].rule}
		less := lint(&e, text, Opts{pack = 0, dismissed = drop[:]}, context.temp_allocator)
		for a in less.alerts {
			check(a.rule != drop[0], "a dismissed rule produces nothing")
		}
		if !(len(less.alerts) < len(all.alerts)) {
			fmt.printfln("        DEBUG dropped=%s all=%d less=%d", drop[0], len(all.alerts), len(less.alerts))
			for a in all.alerts {
				fmt.printfln("          all:  %s @%d", a.rule, a.from)
			}
			for a in less.alerts {
				fmt.printfln("          less: %s @%d", a.rule, a.from)
			}
		}
		check(len(less.alerts) < len(all.alerts), "and dismissing it removes its alerts")
	}

	// Nothing fires in a code block or a URL, whichever pack is active.
	safe :=
		"See http://example.com/very/really/utilize for more.\n\n" +
		"```\nWe will utilize the synergy to circle back very quickly.\n```\n\n" +
		"Inline `utilize` too.\n"
	for _, i in e.packs {
		res := lint(&e, safe, Opts{pack = i}, context.temp_allocator)
		for a in res.alerts {
			checks += 1
			if a.from >= strings.index(safe, "```") {
				failures += 1
				fmt.printfln("  FAIL  %s fired inside a code block or after it: %q", a.rule, a.match)
			}
		}
		check_int(len(res.alerts), 0, fmt.tprintf("%s fires nothing in code or a URL", e.packs[i].name))
	}
}

test_window :: proc() {
	e := engine_builtin()
	defer engine_destroy(&e)

	src :=
		"The chairman will utilize it.\n\n" +
		"We should circle back very quickly.\n\n" +
		"The synergy is obviously there.\n"
	full := lint(&e, src, Opts{pack = 0}, context.temp_allocator)

	// The second paragraph alone must produce exactly the block-local alerts
	// the full pass produced inside it — that equivalence is the whole basis
	// for re-analysing one paragraph per keystroke.
	from := strings.index(src, "We should")
	to := from + len("We should circle back very quickly.")
	win := lint_window(&e, src, from, to, Opts{pack = 0}, context.temp_allocator)

	want := make([dynamic]Alert, 0, 8, context.temp_allocator)
	for a in full.alerts {
		if a.from >= from && a.to <= to {
			switch a.kind {
			case .Consistency, .Conditional, .Readability:
			case .Existence, .Substitution, .Occurrence, .Repetition, .Capitalization, .Spelling:
				append(&want, a)
			}
		}
	}
	check_int(len(win.alerts), len(want), "a window reproduces the full pass's local alerts")
	ok := len(win.alerts) == len(want)
	if ok {
		for a, i in win.alerts {
			if a.from != want[i].from || a.rule != want[i].rule {
				ok = false
			}
		}
	}
	check(ok, "with the same spans and the same rules")

	for a in win.alerts {
		check(a.from >= from - 1 && a.to <= to + 1, "a window produces nothing outside itself")
	}
	check_int(len(lint_window(&e, src, 0, 0, Opts{pack = 0}, context.temp_allocator).alerts), 0, "an empty window finds nothing")
}

test_report :: proc() {
	e := engine_builtin()
	defer engine_destroy(&e)
	src :=
		"# A note\n\n" +
		"This is short. This is also short. This one is short too. " +
		"This fourth sentence is appreciably longer than the three before it, " +
		"which is the point of having it here at all.\n\n" +
		"We will utilize the synergy. We will circle back.\n"
	res := lint(&e, src, Opts{pack = 1}, context.temp_allocator)
	rp := report_of(&res, context.temp_allocator)

	check(rp.words > 40, "the report counts the words")
	check_int(rp.sentences, 7, "and the sentences")
	check(rp.paragraphs == 2, "and the paragraphs, not counting the heading")
	check(rp.minutes > 0, "and estimates a reading time")
	check(rp.grade_ok, "and produces a grade")
	check(rp.len_max > rp.len_min, "the length range is not degenerate")
	check(rp.len_sd > 0, "and has a standard deviation")
	check(strings.contains(rp.caveat, "pointer"), "the caveat travels with the report")

	// Every grade either has a value and a band, or says it has neither.
	for g in rp.grades {
		check((g.ok && g.band != "") || (!g.ok && g.band == ""), fmt.tprintf("%s has a band iff it has a value", METRIC_NAME[g.metric]))
	}

	// The recurring-issue tally is the part that changes behaviour.
	found := false
	for t in rp.issues {
		if strings.contains(t.rule, "Buzzwords") && t.n >= 1 {
			found = true
		}
	}
	check(found, "the tally names the rule that recurs")
	sorted := true
	for i in 1 ..< len(rp.issues) {
		if rp.issues[i - 1].n < rp.issues[i].n {
			sorted = false
		}
	}
	check(sorted, "and is sorted by how often each rule fired")

	// Repeated openers.
	ops := false
	for o in rp.openers {
		if o.word == "this" && o.n >= 3 {
			ops = true
		}
	}
	check(ops, "three sentences opening with the same word are reported")

	check(strings.contains(variance_note(&rp), "length") || strings.contains(variance_note(&rp), "mix") || strings.contains(variance_note(&rp), "rhythm"), "the variance note says something")

	empty := lint(&e, "", Opts{pack = 0}, context.temp_allocator)
	erp := report_of(&empty, context.temp_allocator)
	check_int(erp.words, 0, "an empty note reports zero words")
	check(!erp.grade_ok, "and no grade at all rather than a made-up one")
}

// test_prefilter: the literal prefilter exists only to skip regex work, so the
// one thing it must never do is change an answer. This runs every shipped rule
// over a corpus twice, with it off and on, and asserts the alert sets match.
test_prefilter :: proc() {
	e := engine_builtin()
	defer engine_destroy(&e)

	corpus := [?]string {
		"The chairman will utilize the data in order to very quickly circle back.\n",
		"It is important to note that the form was signed by the committee.\n",
		"He quickly and only and family and slowly left, obviously.\n",
		"The the cat sat. My advisor and my adviser and my advisor disagree.\n",
		"There are three reasons why this is clearly a paradigm shift.\n",
		"# This Heading Is Title Case\n\n- A list item that is really very bad\n",
		"Notwithstanding the aforementioned considerations, the implementation of " +
		"the comprehensive methodological framework necessitates deliberation.\n",
		"We have made a decision. Action will be taken in due course.\n",
		"She was crazy about the whitelist, and the chairman was tone-deaf.\n",
		"I wondered... then I knew. Dr. Reed signed it at 4 p.m. on Tuesday.\n",
		"```\nutilize(very, really);\n```\n\nSee http://x.example/utilize now.\n",
	}

	mismatch := 0
	for src in corpus {
		for _, i in e.packs {
			prefilter_on = false
			a := lint(&e, src, Opts{pack = i}, context.temp_allocator)
			prefilter_on = true
			b := lint(&e, src, Opts{pack = i}, context.temp_allocator)
			if len(a.alerts) != len(b.alerts) {
				mismatch += 1
				fmt.printfln(
					"        prefilter changed %s: %d without, %d with, on %q",
					e.packs[i].name,
					len(a.alerts),
					len(b.alerts),
					src[:min(40, len(src))],
				)
				continue
			}
			for x, k in a.alerts {
				y := b.alerts[k]
				if x.rule != y.rule || x.from != y.from || x.to != y.to {
					mismatch += 1
					fmt.printfln("        prefilter moved %s @%d to %s @%d", x.rule, x.from, y.rule, y.from)
				}
			}
		}
	}
	check_int(mismatch, 0, "the literal prefilter never changes an alert set")

	// And the analyser itself, on the shapes it is supposed to recognise.
	one :: proc(src: string, want: string) {
		got := prefilter_of(src, context.temp_allocator)
		joined := strings.join(got, ",", context.temp_allocator)
		check_eq(joined, want, fmt.tprintf("prefilter of %s", src))
	}
	one(`\b(?:very|really)\b`, "very,really")
	one(`\b(?:\w{4,}ly)\b`, "ly")
	one(`\b(?:\b(?:is|was)\s+\w+ed\b)\b`, "is,was")
	one(`\b(?:there (?:is|are) \w+)\b`, "there ")
	// Not an alternation, so the analyser falls back to the longest run of
	// literal characters the pattern must contain.
	one(`\b(?:utili[sz]e)\b`, "utili")
	one(`\b\w+\b`, "")
}

// test_fix_safety: a suggestion has to be applicable without corrupting the
// text it is applied to. The application applies them one at a time through
// the editor's own edit path, but the invariants are the same.
test_fix_safety :: proc() {
	e := engine_builtin()
	defer engine_destroy(&e)
	src := "We will utilize it in order to make a decision about the chairman.\n"
	for _, i in e.packs {
		res := lint(&e, src, Opts{pack = i}, context.temp_allocator)
		for a in res.alerts {
			check(a.from >= 0 && a.to <= len(src), fmt.tprintf("%s span is inside the document", a.rule))
			check(a.to > a.from, fmt.tprintf("%s span is not empty", a.rule))
			check_eq(a.match, src[a.from:a.to], fmt.tprintf("%s match is exactly its span", a.rule))
			if a.has_fix {
				check(a.fix != "" || a.kind == .Substitution, fmt.tprintf("%s offers a non-empty fix", a.rule))
			}
		}
		// Applying every suggestion back to front must leave valid text.
		out := strings.clone(src, context.temp_allocator)
		for k := len(res.alerts) - 1; k >= 0; k -= 1 {
			a := res.alerts[k]
			if !a.has_fix || a.fix == "" {
				continue
			}
			out = strings.concatenate({out[:a.from], a.fix, out[a.to:]}, context.temp_allocator)
		}
		check(len(out) > 0, "applying every fix leaves text behind")
		res2 := lint(&e, out, Opts{pack = i}, context.temp_allocator)
		check(len(res2.alerts) <= len(res.alerts), fmt.tprintf("%s: taking the suggestions does not add alerts", e.packs[i].name))
	}

	// alert_at picks the mark under the caret.
	res := lint(&e, src, Opts{pack = 0}, context.temp_allocator)
	if len(res.alerts) > 0 {
		a := res.alerts[0]
		check_int(alert_at(res.alerts, a.from), 0, "alert_at finds the mark at its start")
		check(alert_at(res.alerts, a.to + 10000) == -1, "and finds nothing past the end")
	}
	check_int(alert_at(nil, 0), -1, "alert_at on nothing is -1")
}
