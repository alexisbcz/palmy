package prose

// Sentence segmentation.
//
// Splitting on `.` is wrong, and it is wrong in a way that matters here:
// every readability number divides by the sentence count, so a segmenter that
// turns "Dr. Reed arrived." into two sentences halves the average sentence
// length and reports prose two grades simpler than it is. The errors do not
// cancel — abbreviations are common in exactly the registers (business,
// academic) where sentences are longest.
//
// The approach is a candidate-and-veto scan. Every `.`, `!`, `?` or `…` is a
// candidate boundary; a list of vetoes then rejects the ones that are not.
// The vetoes, in the order they fire:
//
//   1. a decimal or version number        3.14, 1.2.3, $4.50
//   2. an ellipsis                        wait... what
//   3. a single-letter initial            A. N. Whitehead, J. R. R. Tolkien
//   4. a known abbreviation               Mr. Dr. Inc. Fig. vs. et al.
//   5. an ordinal or numbered item        1. first    (also a list marker)
//   6. no whitespace after                google.com is handled by masking,
//                                         but `end.Then` is still one token
//   7. the next word is lowercase         ...unless the abbreviation is one
//                                         that commonly ends a sentence
//
// After a surviving candidate, closing quotes and brackets are pulled back
// into the sentence that ended — `"He left." She stayed.` breaks after the
// quote, not before it.
//
// The accuracy of all of this is not asserted, it is *measured* — twice, and
// the second number is the one to believe.
//
// `corpus.odin` holds hand-marked boundaries and `prose --segment` prints the
// hit rate: currently 100%. That number is worth exactly what it says and no
// more. The corpus was written alongside these rules and every veto above
// exists because a case in it failed, so 100% means "the cases I thought of
// are covered", not "this is a good segmenter".
//
// The number that is not circular comes from `oracle.sh`, which asks vale's
// own segmenter (the Go `prose` library) for sentence starts over a separate
// corpus and compares: **92.9% agreement**, 92 of 99 boundaries. Of the seven
// disagreements, four are vale splitting after "Fig.", "al.", "etc." and
// "Mon." where it should not, one is this engine splitting after "a.m. We"
// where it should, and two are front-matter values that vale lints for rules
// but does not expose as sentence scopes.

import "core:strings"

Span :: struct {
	from: int,
	to:   int,
}

// Abbreviations split by how much context they need.
//
// STRONG never ends a sentence: "Dr." is followed by a name, always. These
// veto a boundary whatever comes next.
//
// WEAK is the interesting half. "sat" is both Saturday and the past tense of
// sit; "no" is both Number and a refusal; "ch" is both chapter and nothing.
// For these the veto applies unless the next word begins with a capital,
// which is the one signal that distinguishes "on Sat. and left" from
// "He sat. Then he left." It is a heuristic and it is wrong sometimes — see
// the corpus in corpus.odin for which cases.
@(rodata)
ABBREV_STRONG := [?]string {
	// titles
	"mr",
	"mrs",
	"ms",
	"mx",
	"dr",
	"prof",
	"rev",
	"hon",
	"sr",
	"jr",
	"fr",
	"gen",
	"col",
	"lt",
	"sgt",
	"capt",
	"cmdr",
	"adm",
	"maj",
	"gov",
	"sen",
	"rep",
	"pres",
	"supt",
	// places, which are followed by a name
	"st",
	"mt",
	"blvd",
	"ave",
	"rd",
	"hwy",
	"apt",
	// organisations
	"inc",
	"ltd",
	"corp",
	"llc",
	"plc",
	"dept",
	"univ",
	"assn",
	"bros",
	// reference
	"fig",
	"figs",
	"eqs",
	"refs",
	"vol",
	"vols",
	"chap",
	"sect",
	"pp",
	"para",
	"eds",
	"repr",
	"cf",
	"ibid",
	"cit",
	"viz",
	"approx",
	"vs",
	"et",
	"incl",
	"excl",
	"attn",
	// single letters, which are initials or latin abbreviations
	"e",
	"g",
	"b",
	"n",
}

@(rodata)
ABBREV_WEAK := [?]string {
	"co",
	"ch",
	"sec",
	"ref",
	"eq",
	"ed",
	"trans",
	"op",
	"no",
	"p",
	"v",
	"ca",
	"est",
	"orig",
	"div",
	"fy",
	"qtr",
	"min",
	"max",
	"sq",
	"cm",
	"mm",
	"km",
	"kg",
	"lb",
	"lbs",
	"oz",
	"hr",
	"hrs",
	"wk",
	"yr",
	"am",
	"pm",
	"temp",
	"misc",
	"jan",
	"feb",
	"mar",
	"apr",
	"jun",
	"jul",
	"aug",
	"sept",
	"sep",
	"oct",
	"nov",
	"dec",
	"mon",
	"tue",
	"tues",
	"wed",
	"thu",
	"thur",
	"thurs",
	"fri",
	"sat",
	"sun",
}

// Abbreviations that DO often end a sentence, so only the next word's shape
// holds a boundary back.
@(rodata)
ABBREV_TERMINAL := [?]string{"etc", "al", "ibid", "ff", "seq"}

@(private = "file")
in_list :: proc(list: []string, w: string) -> bool {
	for a in list {
		if len(a) != len(w) {
			continue
		}
		same := true
		for i in 0 ..< len(a) {
			if a[i] != (w[i] | 32) {
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
is_space :: proc(c: u8) -> bool {
	return c == ' ' || c == '\t' || c == '\n' || c == '\r'
}

@(private = "file")
is_alpha :: proc(c: u8) -> bool {
	return (c | 32) >= 'a' && (c | 32) <= 'z'
}

@(private = "file")
is_digit :: proc(c: u8) -> bool {
	return c >= '0' && c <= '9'
}

@(private = "file")
is_upper :: proc(c: u8) -> bool {
	return c >= 'A' && c <= 'Z'
}

// word_before returns the run of letters ending just before `at`.
@(private = "file")
word_before :: proc(s: string, at: int) -> string {
	e := at
	for e > 0 && is_space(s[e - 1]) {
		e -= 1
	}
	b := e
	for b > 0 && (is_alpha(s[b - 1]) || s[b - 1] == '\'') {
		b -= 1
	}
	return s[b:e]
}

// sentences splits a range of (already masked) text into sentence spans. The
// spans are trimmed of surrounding whitespace, and whitespace between them
// belongs to neither.
sentences :: proc(s: string, from, to: int, allocator := context.allocator) -> []Span {
	out := make([dynamic]Span, 0, 16, allocator)
	lo := clamp(from, 0, len(s))
	hi := clamp(to, lo, len(s))

	start := -1
	i := lo
	for i < hi {
		c := s[i]
		if start < 0 {
			if is_space(c) {
				i += 1
				continue
			}
			start = i
		}

		is_end := c == '.' || c == '!' || c == '?'
		// A UTF-8 ellipsis.
		if c == 0xe2 && i + 2 < hi && s[i + 1] == 0x80 && s[i + 2] == 0xa6 {
			is_end = true
		}
		if !is_end {
			i += 1
			continue
		}

		// Consume a run of terminators: "What?!" is one boundary.
		e := i
		for e < hi && (s[e] == '.' || s[e] == '!' || s[e] == '?') {
			e += 1
		}
		if c == 0xe2 {
			e = i + 3
		}
		run := e - i

		veto := false

		if c == '.' && run == 1 {
			// 1. a decimal, a version, a time, a money amount
			if i > lo && is_digit(s[i - 1]) && i + 1 < hi && is_digit(s[i + 1]) {
				veto = true
			}
			// 6. nothing but a letter after it: `end.Then`, `3.b`, `notes.md`
			if !veto && i + 1 < hi && is_alpha(s[i + 1]) && !is_upper(s[i + 1]) {
				veto = true
			}
			if !veto && i + 1 < hi && is_alpha(s[i + 1]) && i > lo && is_alpha(s[i - 1]) {
				// `U.S.A`, `e.g`, `No.X` — a letter either side and no space.
				veto = true
			}
			if !veto {
				w := word_before(s, i)
				// 3. a single-letter initial: `A. N. Whitehead`
				if len(w) == 1 && is_upper(w[0]) {
					veto = true
				}
				// 3b. the tail of a dotted abbreviation: `a.m.`, `U.S.`,
				// `Ph.D.`, `i.e.`. The giveaway is a letter immediately
				// preceded by another full stop. These end a sentence only
				// when a capital plainly begins the next one.
				if !veto && i >= lo + 2 && is_alpha(s[i - 1]) && s[i - 2] == '.' {
					veto = !next_is_capital(s, e, hi)
				}
				// 4. a known abbreviation
				if !veto && len(w) > 0 {
					switch {
					case in_list(ABBREV_TERMINAL[:], w):
						veto = !next_starts_sentence(s, e, hi)
					case in_list(ABBREV_STRONG[:], w):
						veto = true
					case in_list(ABBREV_WEAK[:], w):
						veto = !next_is_capital(s, e, hi)
					}
				}
				// 5. a numbered list marker, which is a line-initial thing.
				// `1. Buy flour` is a marker; `was 2.5 to 1. We expected 3`
				// is a sentence that happens to end in a digit.
				if !veto {
					d := i
					for d > lo && is_digit(s[d - 1]) {
						d -= 1
					}
					if d < i && line_initial(s, lo, d) {
						veto = true
					}
				}
			}
		} else if run >= 3 && c == '.' {
			// 2. an ellipsis written as dots. It ends a sentence only when
			// what follows plainly begins one.
			veto = !next_starts_sentence(s, e, hi)
		} else if c == 0xe2 {
			veto = !next_starts_sentence(s, e, hi)
		}

		if veto {
			i = e
			continue
		}

		// Pull trailing closers into this sentence.
		j := e
		for j < hi &&
		    (s[j] == '"' ||
				    s[j] == '\'' ||
				    s[j] == ')' ||
				    s[j] == ']' ||
				    s[j] == '}' ||
				    s[j] == '*' ||
				    s[j] == '`') {
			j += 1
		}
		// A closing curly quote or single-quote in UTF-8.
		for j + 2 < hi && s[j] == 0xe2 && s[j + 1] == 0x80 && (s[j + 2] == 0x99 || s[j + 2] == 0x9d) {
			j += 3
		}
		// It is only a boundary if whitespace or the end follows.
		if j < hi && !is_space(s[j]) {
			i = e
			continue
		}

		append(&out, Span{start, j})
		start = -1
		i = j
	}
	if start >= 0 {
		t := hi
		for t > start && is_space(s[t - 1]) {
			t -= 1
		}
		if t > start {
			append(&out, Span{start, t})
		}
	}
	return out[:]
}

// line_initial: nothing but whitespace between `at` and the start of the line.
@(private = "file")
line_initial :: proc(s: string, lo, at: int) -> bool {
	i := at
	for i > lo {
		c := s[i - 1]
		if c == '\n' {
			return true
		}
		if c != ' ' && c != '\t' && c != '>' && c != '\r' {
			return false
		}
		i -= 1
	}
	return true
}

// next_is_capital: whitespace, then an upper-case letter. Stricter than
// `next_starts_sentence`, which also accepts a digit — the difference is what
// keeps "ch. 4" and "No. 5" from splitting.
@(private = "file")
next_is_capital :: proc(s: string, at, hi: int) -> bool {
	j := at
	for j < hi && (s[j] == '"' || s[j] == '\'' || s[j] == ')' || s[j] == ']') {
		j += 1
	}
	if j >= hi {
		return true
	}
	if !is_space(s[j]) {
		return false
	}
	for j < hi && is_space(s[j]) {
		j += 1
	}
	if j >= hi {
		return true
	}
	c := s[j]
	if c == '"' || c == '\'' || c == '(' || c == '[' {
		j += 1
		if j >= hi {
			return true
		}
		c = s[j]
	}
	return is_upper(c)
}

// next_starts_sentence: whitespace, then something a sentence can begin with.
@(private = "file")
next_starts_sentence :: proc(s: string, at, hi: int) -> bool {
	j := at
	for j < hi && (s[j] == '"' || s[j] == '\'' || s[j] == ')' || s[j] == ']') {
		j += 1
	}
	if j >= hi {
		return true
	}
	if !is_space(s[j]) {
		return false
	}
	for j < hi && is_space(s[j]) {
		j += 1
	}
	if j >= hi {
		return true
	}
	c := s[j]
	if c == '"' || c == '\'' || c == '(' || c == '[' || c == 0xe2 {
		j += 1
		for j < hi && (s[j] == 0x80 || s[j] == 0x9c || s[j] == 0x98) {
			j += 1
		}
		if j >= hi {
			return true
		}
		c = s[j]
	}
	return is_upper(c) || is_digit(c) || c >= 0x80
}

// ---------------------------------------------------------------------------
// Words
// ---------------------------------------------------------------------------

// words splits a range into word spans. A word is a run of letters, digits
// and the inner punctuation a word keeps: an apostrophe or a hyphen with a
// letter either side.
words :: proc(s: string, from, to: int, allocator := context.allocator) -> []Span {
	out := make([dynamic]Span, 0, 64, allocator)
	lo := clamp(from, 0, len(s))
	hi := clamp(to, lo, len(s))
	i := lo
	for i < hi {
		if !is_word_start(s[i]) {
			i += 1
			continue
		}
		j := i
		for j < hi {
			c := s[j]
			if is_alpha(c) || is_digit(c) || c >= 0x80 {
				j += 1
				continue
			}
			if (c == '\'' || c == '-' || c == 0xe2) &&
			   j + 1 < hi &&
			   j > i &&
			   (is_alpha(s[j + 1]) || s[j + 1] >= 0x80) {
				j += 1
				continue
			}
			break
		}
		// A trailing hyphen or apostrophe belongs to the punctuation.
		for j > i && (s[j - 1] == '-' || s[j - 1] == '\'') {
			j -= 1
		}
		if j > i {
			append(&out, Span{i, j})
		}
		i = max(j, i + 1)
	}
	return out[:]
}

@(private = "file")
is_word_start :: proc(c: u8) -> bool {
	return is_alpha(c) || is_digit(c) || c >= 0x80
}

// lower_ascii is the only case folding this engine needs: style rules are
// written for English and a Turkish dotless i has never appeared in one.
lower_ascii :: proc(s: string, allocator := context.temp_allocator) -> string {
	b := make([]u8, len(s), allocator)
	for i in 0 ..< len(s) {
		c := s[i]
		b[i] = (c >= 'A' && c <= 'Z') ? c + 32 : c
	}
	return string(b)
}

eq_fold :: proc(a, b: string) -> bool {
	if len(a) != len(b) {
		return false
	}
	for i in 0 ..< len(a) {
		x := a[i] | (a[i] >= 'A' && a[i] <= 'Z' ? 32 : 0)
		y := b[i] | (b[i] >= 'A' && b[i] <= 'Z' ? 32 : 0)
		if x != y {
			return false
		}
	}
	return true
}

// paragraphs are runs of blocks separated by a blank line. The masked text
// already knows where the blocks are; this groups the prose ones.
_ :: strings
