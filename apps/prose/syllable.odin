package prose

// Syllable counting, which every readability formula divides by.
//
// There is no way to do this correctly from spelling. English orthography does
// not encode syllable count: "business" is two, "busyness" is three, and the
// letters barely differ. The honest position is that this is an estimator with
// a measured error rate, not a function that returns the right answer.
//
// So it is measured. `espeak-ng` is installed on this machine and has a real
// English letter-to-sound ruleset plus an exception dictionary; asking it for
// IPA and counting vowel nuclei gives a pronunciation-derived syllable count
// that is right far more often than any spelling rule. `prose --syllables`
// runs this counter and that oracle over a word list and prints the
// disagreement rate. The number is in the report, and the oracle is never
// invoked by the library or by the application — only by the test command.
//
// The estimator itself is the classic vowel-group count with the corrections
// that actually pay for themselves, in this order:
//
//   1. an exception table, for the words the rules cannot reach
//   2. count vowel groups, treating `y` as a vowel except word-initially
//   3. split the vowel pairs that are reliably two nuclei (`ia`, `io`, `ua`…)
//   4. drop a silent final `e`, unless the word then has no vowel left, or
//      the `e` is the nucleus of a final `-le`/`-re` after a consonant
//   5. drop the `e` of a `-ed` that is not preceded by `t` or `d`
//   6. add one for a final `-le` after a consonant, and for `-ism`, `-ual`
//   7. never return less than one
//
// Every one of those rules exists because removing it made the measured error
// rate worse.

import "core:strings"

// Words the rules get wrong often enough to be worth naming. Short, and only
// for cases a rule cannot fix without breaking something else.
@(rodata)
SYL_EXCEPT := [?]struct {
	word: string,
	n:    int,
} {
	{"the", 1},
	{"a", 1},
	{"i", 1},
	{"business", 2},
	{"every", 2},
	{"everything", 3},
	{"everyone", 3},
	{"everybody", 4},
	{"people", 2},
	{"idea", 3},
	{"ideas", 3},
	{"area", 3},
	{"areas", 3},
	{"being", 2},
	{"doing", 2},
	{"going", 2},
	{"science", 2},
	{"sciences", 3},
	{"quiet", 2},
	{"queue", 1},
	{"squirrel", 2},
	{"colonel", 2},
	{"wednesday", 2},
	{"february", 4},
	{"interesting", 3},
	{"comfortable", 3},
	{"vegetable", 3},
	{"chocolate", 3},
	{"family", 3},
	{"camera", 3},
	{"memory", 3},
	{"favourite", 3},
	{"favorite", 3},
	{"different", 3},
	{"probably", 3},
	{"actually", 4},
	{"usually", 4},
	{"literally", 4},
	{"basically", 4},
	{"generally", 4},
	{"especially", 4},
	{"temperature", 4},
	{"laboratory", 5},
	{"onion", 2},
	{"union", 2},
	{"opinion", 3},
	{"million", 2},
	{"billion", 2},
	{"question", 2},
	{"nation", 2},
	{"national", 3},
	{"ocean", 2},
	{"create", 2},
	{"created", 3},
	{"creates", 2},
	{"creating", 3},
	{"creative", 3},
	{"cooperate", 4},
	{"poem", 2},
	{"poet", 2},
	{"poetry", 3},
	{"real", 1},
	{"really", 2},
	{"reality", 4},
	{"theatre", 3},
	{"theater", 3},
	{"maybe", 2},
	{"aisle", 1},
	{"iron", 2},
	{"fire", 1},
	{"hour", 1},
	{"our", 1},
	{"your", 1},
	{"are", 1},
	{"were", 1},
	{"where", 1},
	{"there", 1},
	{"here", 1},
	{"one", 1},
	{"once", 1},
	{"some", 1},
	{"come", 1},
	{"done", 1},
	{"gone", 1},
	{"none", 1},
	{"live", 1},
	{"give", 1},
	{"have", 1},
	{"love", 1},
	{"move", 1},
	{"prove", 1},
	{"shoe", 1},
	{"toe", 1},
	{"because", 2},
	{"beautiful", 3},
	{"anyone", 3},
	{"anything", 3},
	{"someone", 2},
	{"something", 2},
	{"nothing", 2},
	{"sure", 1},
	{"pure", 1},
	{"cure", 1},
	{"guarantee", 3},
}

@(private = "file")
has_vowel :: proc(w: string) -> bool {
	for i in 0 ..< len(w) {
		if is_vowel(w[i]) || w[i] == 'y' {
			return true
		}
	}
	return false
}

@(private = "file")
is_vowel :: proc(c: u8) -> bool {
	switch c {
	case 'a', 'e', 'i', 'o', 'u':
		return true
	}
	return false
}

// Vowel pairs that are reliably two nuclei rather than one.
@(rodata)
SYL_SPLIT := [?]string {
	"ia",
	"io",
	"iu",
	"ua",
	"uo",
	"ue",
	"eo",
	"ya",
	"yo",
	"ii",
	"uu",
	"iе",
}

// Vowel pairs that are reliably one nucleus. Checked before the split list,
// so `ue` in "queue" does not become two.
@(rodata)
SYL_GLUE := [?]string {
	"ae",
	"ai",
	"au",
	"ay",
	"ea",
	"ee",
	"ei",
	"ey",
	"oi",
	"oo",
	"oa",
	"ou",
	"oy",
	"ui",
	"ie",
	"oe",
	"aw",
	"ew",
	"ow",
}

// syllables estimates the syllable count of one word. The word is expected to
// be a single token; punctuation and case do not matter.
syllables :: proc(raw: string) -> int {
	// Strip to letters, lowercased.
	tmp: [64]u8
	n := 0
	for i in 0 ..< len(raw) {
		c := raw[i]
		lc := (c >= 'A' && c <= 'Z') ? c + 32 : c
		if lc >= 'a' && lc <= 'z' {
			if n < len(tmp) {
				tmp[n] = lc
				n += 1
			}
			continue
		}
		// A digit sequence: each digit is read as its own word, which is a
		// guess, but is closer than ignoring numbers entirely.
		if c >= '0' && c <= '9' {
			return digit_syllables(raw)
		}
	}
	if n == 0 {
		return 0
	}
	w := string(tmp[:n])

	for e in SYL_EXCEPT {
		if e.word == w {
			return e.n
		}
	}

	// A plural or past tense of an exception: strip one suffix and retry.
	for suf, add in ([?]struct {
		s:   string,
		add: int,
	}{{"s", 0}, {"es", 0}, {"d", 0}, {"ing", 1}, {"ly", 1}, {"ness", 1}}) {
		_ = add
		if len(w) > len(suf.s) + 2 && strings.has_suffix(w, suf.s) {
			stem := w[:len(w) - len(suf.s)]
			for e in SYL_EXCEPT {
				if e.word == stem {
					return e.n + extra_for_suffix(suf.s, stem)
				}
			}
		}
	}

	// A derivational suffix with a fixed syllable count: the stem keeps its
	// own silent `e`, which is why "advancement" is three and not four.
	// Counting the stem and adding the suffix is both simpler and more
	// accurate than trying to decide whether that `e` is silent in place.
	for suf in SYL_SUFFIX {
		if !strings.has_suffix(w, suf.s) {
			continue
		}
		stem := w[:len(w) - len(suf.s)]
		// The stem has to be a plausible word on its own, or "string" loses
		// its only vowel to "str" and comes back as two syllables.
		if len(stem) < 3 || !has_vowel(stem) {
			continue
		}
		return syllables(stem) + suf.n
	}

	return count_rules(w)
}

// Suffixes whose own syllable count does not depend on the stem.
@(rodata)
SYL_SUFFIX := [?]struct {
	s: string,
	n: int,
} {
	{"ments", 1},
	{"ment", 1},
	{"nesses", 2},
	{"ness", 1},
	{"lessly", 2},
	{"lessness", 2},
	{"less", 1},
	{"fully", 2},
	{"fulness", 2},
	{"ful", 1},
	{"ships", 1},
	{"ship", 1},
	{"hood", 1},
	{"wards", 1},
	{"ward", 1},
	{"wise", 1},
	{"isms", 2},
	{"ism", 2},
	{"ing", 1},
	{"ly", 1},
}

@(private = "file")
extra_for_suffix :: proc(suf, stem: string) -> int {
	switch suf {
	case "ing", "ness":
		return 1
	case "ly":
		return strings.has_suffix(stem, "le") ? 0 : 1
	case "es":
		// `-es` is a syllable only after a sibilant.
		if len(stem) > 0 {
			switch stem[len(stem) - 1] {
			case 's', 'x', 'z':
				return 1
			}
			if len(stem) > 1 {
				two := stem[len(stem) - 2:]
				if two == "ch" || two == "sh" {
					return 1
				}
			}
		}
		return 0
	}
	return 0
}

@(private = "file")
count_rules :: proc(w: string) -> int {
	n := len(w)
	count := 0

	i := 0
	for i < n {
		c := w[i]
		v := is_vowel(c) || (c == 'y' && i > 0)
		if !v {
			i += 1
			continue
		}
		// A vowel group: take the run, then decide how many nuclei it holds.
		j := i
		for j < n && (is_vowel(w[j]) || (w[j] == 'y' && j > 0)) {
			j += 1
		}
		count += nuclei_in(w[i:j], i > 0 ? w[i - 1] : 0)
		i = j
	}

	// A silent final `e`.
	if n >= 2 && w[n - 1] == 'e' {
		drop := true
		// `-le` / `-re` after a consonant keeps its nucleus: ta-ble, ac-re.
		if n >= 3 && (w[n - 2] == 'l' || w[n - 2] == 'r') && !is_vowel(w[n - 3]) && w[n - 3] != 'y' {
			drop = false
		}
		// A final `-ee`, `-ye`, `-oe` is not silent.
		if n >= 2 && (w[n - 2] == 'e' || w[n - 2] == 'y') {
			drop = false
		}
		if drop && count > 1 {
			count -= 1
		}
	}

	// `-ed` after anything but t or d is one syllable short.
	if n >= 4 && w[n - 1] == 'd' && w[n - 2] == 'e' {
		b := w[n - 3]
		if b != 't' && b != 'd' && !is_vowel(b) && count > 1 {
			count -= 1
		}
	}

	// `-es` after anything but a sibilant likewise — except after a `-le`
	// or `-re`, where the `e` is the nucleus: "tables" is two, "makes" one.
	if n >= 4 && w[n - 1] == 's' && w[n - 2] == 'e' {
		b := w[n - 3]
		sib := b == 's' || b == 'x' || b == 'z' || b == 'c' || b == 'g' || b == 'h'
		liquid := (b == 'l' || b == 'r') && n >= 5 && !is_vowel(w[n - 4]) && w[n - 4] != 'y'
		// `-ies`, `-ees`, `-oes`: the letter before the `e` is a vowel, so
		// the `e` was never its own group to take away.
		vowelled := is_vowel(b)
		if !sib && !liquid && !vowelled && count > 1 {
			count -= 1
		}
	}

	// A syllabic `m` with two consonants in front of it: "rhythm",
	// "algorithm", "logarithm" — and their plurals, where the `m` is no
	// longer last. Not "prism" or "film", where the vowel is adjacent and
	// the nasal joins it.
	tail := w
	if n >= 4 && w[n - 1] == 's' && w[n - 2] == 'm' {
		tail = w[:n - 1]
	}
	t := len(tail)
	if t >= 3 && tail[t - 1] == 'm' && !is_vowel(tail[t - 2]) && tail[t - 2] != 'y' {
		if !is_vowel(tail[t - 3]) && tail[t - 3] != 'y' {
			count += 1
		}
	}

	return max(1, count)
}

// nuclei_in decides how many syllables one run of vowel letters holds. The
// consonant in front of the run matters: `io` is two nuclei in "violin" and
// one in "nation", and the only thing that distinguishes them is the `t`.
@(private = "file")
nuclei_in :: proc(run: string, before: u8) -> int {
	// `qu` is /kw/: the `u` is a glide, not a nucleus. Without this, every
	// "acquaint", "quiet" and "require" counts one syllable too many, and
	// there are a lot of them.
	r := run
	if before == 'q' && len(r) > 1 && r[0] == 'u' {
		r = r[1:]
	}
	if len(r) == 1 {
		return 1
	}
	if len(r) == 0 {
		return 1
	}
	run := r
	count := 0
	i := 0
	for i < len(run) {
		if i + 1 < len(run) {
			pair := run[i:i + 2]
			glued := false
			for g in SYL_GLUE {
				if g == pair {
					glued = true
					break
				}
			}
			if glued {
				count += 1
				i += 2
				continue
			}
			split := false
			for s in SYL_SPLIT {
				if s == pair {
					split = true
					break
				}
			}
			if split {
				// `-tion`, `-sion`, `-cial`, `-gious`: after a sibilant or a
				// soft g the glide is absorbed and the pair is one nucleus —
				// na-tion, not na-ti-on. After anything else it really is two:
				// vi-o-lin, di-al.
				if i == 0 &&
				   pair[0] == 'i' &&
				   (before == 't' || before == 's' || before == 'c' || before == 'x' || before == 'g') {
					count += 1
				} else {
					count += 2
				}
				i += 2
				continue
			}
		}
		count += 1
		i += 1
	}
	return max(1, count)
}

@(private = "file")
digit_syllables :: proc(raw: string) -> int {
	D := [10]int{2, 1, 1, 1, 1, 1, 1, 2, 1, 1} // zero one two ... seven nine
	n := 0
	for i in 0 ..< len(raw) {
		c := raw[i]
		if c >= '0' && c <= '9' {
			n += D[c - '0']
		} else if (c | 32) >= 'a' && (c | 32) <= 'z' {
			n += 1
		}
	}
	return max(1, n)
}

// polysyllabic is three or more syllables, which is what Gunning Fog and SMOG
// both count. Fog excludes words made long only by a suffix and proper nouns;
// that exclusion is applied by the caller, which knows the word's position.
polysyllabic :: proc(word: string) -> bool {
	return syllables(word) >= 3
}
