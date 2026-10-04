package prose

// The two things this engine is most likely to be wrong about, measured.
//
// Sentence segmentation and syllable counting are both heuristics, and both
// feed every readability number. Asserting that they "work" would be the kind
// of claim this project does not make, so each has a measurement instead:
//
//   `prose --segment`    runs the segmenter over a corpus whose boundaries
//                        were marked by hand, in this file, and prints
//                        precision, recall and the cases it got wrong.
//   `prose --syllables`  runs the counter and `espeak-ng` over a word list
//                        and prints the disagreement rate.
//
// Both print numbers, not verdicts. `espeak-ng` is invoked only by that one
// command; the library and the application never shell out.

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:unicode/utf8"

// ---------------------------------------------------------------------------
// The segmentation corpus
// ---------------------------------------------------------------------------

// Every boundary is marked with `|` immediately after the last character of
// the sentence. The marker is stripped before the segmenter sees the text, so
// the offsets it is scored against are the ones a reader would mark.
//
// These are written for this test. None of it is anybody's real writing.
@(rodata)
SEG_CORPUS := [?]string {
	// --- the easy cases, which still have to pass -----------------------
	"The cat sat on the mat.| The dog did not.|",
	"Is it ready?| Yes.| Ship it.|",
	"Stop!| Do not touch that.|",
	"One sentence with no terminator at all",

	// --- abbreviations ---------------------------------------------------
	"Dr. Reed signed the form.| Mr. Okafor did not.|",
	"The meeting is at 4 p.m. on Tuesday.|",
	"See Fig. 3 for the layout.| It is on p. 12.|",
	"Smith et al. reported the same effect.|",
	"The St. Albans branch closed.| The Mt. Vernon one did not.|",
	"Acme Inc. filed late.| Beta Ltd. did not.|",
	"Compare vol. 2, ch. 4 with the 1998 ed.|",
	"We shipped 12 units, approx. 40 kg each.|",
	"The dept. was renamed.| It is now Div. 7.|",
	"Use water, e.g. from the tap.| Not oil.|",
	"That is, i.e. the second one.|",
	"Bring a pen, paper, etc.| Then sit down.|",
	"We tried cats, dogs, etc. and gave up.|",

	// --- initials --------------------------------------------------------
	"A. N. Whitehead wrote it.| J. R. R. Tolkien did not.|",
	"The author is K. Le Guin.| She is good.|",
	"Ask J. Smith.| He knows.|",

	// --- numbers ---------------------------------------------------------
	"It weighs 3.14 kg.| That is a lot.|",
	"Version 1.2.3 is out.| Upgrade now.|",
	"The price is $4.50.| Tax is extra.|",
	"Accuracy reached 99.9 percent.|",
	"1. Buy flour.|\n2. Buy yeast.|",
	"The ratio was 2.5 to 1.| We expected 3.|",

	// --- quotes ----------------------------------------------------------
	"\"He left.\"| She stayed.|",
	"She said \"go\" and he went.|",
	"\"Is it done?\"| \"Not yet.\"|",
	"He called it a \"fix.\"| It was not.|",

	// --- brackets --------------------------------------------------------
	"The result held (see p. 3.)| The next one did not.|",
	"We measured it (twice).| It agreed.|",
	"Use the second form (not the first).| It is shorter.|",

	// --- ellipses --------------------------------------------------------
	"I wondered... then I knew.|",
	"Wait...| What happened?|",
	"He trailed off…| Nobody spoke.|",
	"The list went on and on and on...|",

	// --- terminators in a row --------------------------------------------
	"What?!| I never agreed to that.|",
	"Really??| Show me.|",
	"No!!!| Absolutely not.|",

	// --- hard cases, honestly included -----------------------------------
	"The U.S. economy grew.| Canada's did not.|",
	"She has a Ph.D. in physics.| He has none.|",
	"Call at 9 a.m.| We open then.|",
	"It cost 10 cents vs. 12 for the other.|",
	"The No. 4 train was late.| The No. 5 was not.|",
	"Turn left on Elm Ave. and park.|",
	"He arrived Mon. and left Fri.|",
	"The file is notes.md and it is small.|",
	"Rule 3.b applies here.| Rule 4 does not.|",
	"This sentence ends in an abbreviation, Inc.|",

	// --- paragraph-shaped runs -------------------------------------------
	"A buffer is a line array.| Each line owns its bytes.| Splitting a line moves descriptors, not text.|",
	"Why not a gap buffer?| Because every question an editor asks is line-shaped.| A scan is the wrong cost.|",
	"First, measure.| Then decide.| Never the other way round.|",
	"The compositor may ignore the buffer.| That is within its rights.| Wait for the configure.|",
	"We tested it on Tue. and it passed.| On Wed. it did not.| Nobody knows why.|",
}

Seg_Score :: struct {
	cases:     int,
	expected:  int,
	predicted: int,
	hits:      int,
	exact:     int, // cases where every boundary matched and none was invented
}

// seg_strip removes the markers and returns the text plus the expected
// boundary offsets (the offset one past the final character of a sentence).
seg_strip :: proc(marked: string, allocator := context.temp_allocator) -> (text: string, bounds: []int) {
	sb := strings.builder_make(allocator)
	bs := make([dynamic]int, 0, 8, allocator)
	for i in 0 ..< len(marked) {
		if marked[i] == '|' {
			append(&bs, strings.builder_len(sb))
			continue
		}
		strings.write_byte(&sb, marked[i])
	}
	t := strings.to_string(sb)
	// An unmarked tail is still a sentence, and the corpus has one case of it.
	if len(bs) == 0 || bs[len(bs) - 1] != len(strings.trim_right(t, " ")) {
		trimmed := len(strings.trim_right(t, " "))
		if len(bs) == 0 || bs[len(bs) - 1] < trimmed {
			append(&bs, trimmed)
		}
	}
	return t, bs[:]
}

segment_score :: proc(verbose: bool) -> Seg_Score {
	sc := Seg_Score{}
	for marked in SEG_CORPUS {
		text, want := seg_strip(marked)
		got := sentences(text, 0, len(text), context.temp_allocator)
		sc.cases += 1
		sc.expected += len(want)
		sc.predicted += len(got)

		hit := 0
		for w in want {
			for g in got {
				if g.to == w {
					hit += 1
					break
				}
			}
		}
		sc.hits += hit
		if hit == len(want) && len(got) == len(want) {
			sc.exact += 1
		} else if verbose {
			fmt.printfln("  mismatch: %q", text)
			fmt.printf("    want ")
			for w in want {
				fmt.printf("%d ", w)
			}
			fmt.printf("\n    got  ")
			for g in got {
				fmt.printf("%d ", g.to)
			}
			fmt.println()
			for g in got {
				fmt.printfln("      %q", text[g.from:g.to])
			}
		}
	}
	return sc
}

segment_accuracy_report :: proc(path := "") -> int {
	sc := segment_score(true)
	prec := sc.predicted > 0 ? f64(sc.hits) / f64(sc.predicted) * 100 : 0
	rec := sc.expected > 0 ? f64(sc.hits) / f64(sc.expected) * 100 : 0
	f1 := (prec + rec) > 0 ? 2 * prec * rec / (prec + rec) : 0
	fmt.println()
	fmt.printfln("segmentation corpus: %d cases, %d hand-marked boundaries", sc.cases, sc.expected)
	fmt.printfln("  boundaries found      %d", sc.predicted)
	fmt.printfln("  correct               %d", sc.hits)
	fmt.printfln("  precision             %.1f%%", prec)
	fmt.printfln("  recall                %.1f%%", rec)
	fmt.printfln("  F1                    %.1f%%", f1)
	fmt.printfln(
		"  cases exactly right   %d of %d  (%.1f%%)",
		sc.exact,
		sc.cases,
		f64(sc.exact) / f64(max(1, sc.cases)) * 100,
	)
	fmt.println()
	fmt.println("  This corpus was written alongside the segmenter: every veto in")
	fmt.println("  segment.odin exists because a case here failed. A high score on it")
	fmt.println("  means the known hard cases are covered, not that the segmenter is")
	fmt.println("  good. For a number that is not circular, run apps/prose/oracle.sh,")
	fmt.println("  which compares against vale's own segmenter on a separate corpus.")

	if path != "" {
		data, err := os.read_entire_file_from_path(path, context.allocator)
		if err != nil {
			fmt.eprintfln("prose: cannot read %s", path)
			return 3
		}
		defer delete(data)
		m := mask(string(data))
		defer mask_destroy(&m)
		n := 0
		for b in m.blocks {
			if b.kind != .None {
				n += len(sentences(m.text, b.from, b.to, context.temp_allocator))
			}
		}
		fmt.printfln("  %s: %d sentences", path, n)
	}
	return 0
}

// ---------------------------------------------------------------------------
// The syllable oracle
// ---------------------------------------------------------------------------

// Vowel nuclei in the IPA espeak-ng emits for en-us. The diphthongs are
// listed first and matched greedily, because `aɪ` is one syllable and `iə`
// is two, and nothing but a list distinguishes them.
@(rodata)
IPA_DIPHTHONG := [?]string{"aɪ", "aʊ", "eɪ", "oʊ", "ɔɪ", "ɑɪ", "ɐʊ"}

@(rodata)
IPA_VOWEL := [?]rune {
	'i',
	'ɪ',
	'e',
	'ɛ',
	'æ',
	'a',
	'ɑ',
	'ɒ',
	'ɔ',
	'o',
	'ʊ',
	'u',
	'ʌ',
	'ə',
	'ɜ',
	'ɐ',
	'ɚ',
	'ɝ',
	'ɨ',
	'ʉ',
	'ɤ',
	'ɵ',
	'ø',
	'œ',
	'ɘ',
	'ɯ',
	'ʏ',
	'ɞ',
	// espeak-ng's own reduced vowels, which are not standard IPA. Leaving
	// these out made the oracle undercount and the estimator look worse than
	// it is: "allocated" is ˈæləkˌeɪɾᵻd, four nuclei, not three.
	'ᵻ',
	'ᵿ',
	'ɪ',
	'ʉ',
}

// ipa_syllables counts vowel nuclei in one IPA transcription.
ipa_syllables :: proc(ipa: string) -> int {
	n := 0
	s := ipa
	i := 0
	for i < len(s) {
		// Stress, length and tie marks carry no nucleus.
		r, size := utf8.decode_rune_in_string(s[i:])
		if size <= 0 {
			break
		}
		switch r {
		case 'ˈ', 'ˌ', 'ː', 'ˑ', '͡', '‿', ' ', '-', '\'', '_', ';', '|':
			i += size
			continue
		}
		hit := false
		for d in IPA_DIPHTHONG {
			if strings.has_prefix(s[i:], d) {
				n += 1
				i += len(d)
				hit = true
				break
			}
		}
		if hit {
			continue
		}
		is_v := false
		for v in IPA_VOWEL {
			if r == v {
				is_v = true
				break
			}
		}
		if is_v {
			n += 1
			// A following length mark or identical vowel is the same nucleus.
			i += size
			for i < len(s) {
				r2, s2 := utf8.decode_rune_in_string(s[i:])
				if s2 <= 0 {
					break
				}
				if r2 == 'ː' || r2 == r {
					i += s2
					continue
				}
				break
			}
			continue
		}
		i += size
	}
	return n
}

// syllable_error_report samples a word list, asks espeak-ng for each word's
// pronunciation in one batch, and prints how often the estimator disagrees.
syllable_error_report :: proc(list_path: string, want: int) -> int {
	data, err := os.read_entire_file_from_path(list_path, context.allocator)
	if err != nil {
		fmt.eprintfln("prose: cannot read %s", list_path)
		return 3
	}
	defer delete(data)

	// Only plain lowercase words of a useful length, evenly sampled across
	// the file so the sample is not all of one letter.
	all := make([dynamic]string, 0, 4096, context.allocator)
	defer delete(all)
	rest := string(data)
	for line in strings.split_lines_iterator(&rest) {
		w := strings.trim_space(line)
		if len(w) < 3 || len(w) > 16 {
			continue
		}
		ok := true
		for i in 0 ..< len(w) {
			if w[i] < 'a' || w[i] > 'z' {
				ok = false
				break
			}
		}
		if ok {
			append(&all, w)
		}
	}
	if len(all) == 0 {
		fmt.eprintfln("prose: no usable words in %s", list_path)
		return 7
	}
	step := max(1, len(all) / max(1, want))
	sample := make([dynamic]string, 0, want, context.allocator)
	defer delete(sample)
	for i := 0; i < len(all) && len(sample) < want; i += step {
		append(&sample, all[i])
	}

	// One subprocess, one line of IPA per word. A trailing full stop is what
	// makes espeak-ng emit a line per input line instead of one long run.
	tmp := fmt.tprintf("/tmp/prose-syl-%d.txt", os.get_pid())
	sb := strings.builder_make(context.temp_allocator)
	for w in sample {
		strings.write_string(&sb, w)
		strings.write_string(&sb, ".\n")
	}
	if werr := os.write_entire_file(tmp, transmute([]u8)strings.to_string(sb)); werr != nil {
		fmt.eprintln("prose: cannot write the word file")
		return 7
	}
	defer os.remove(tmp)

	state, sout, _, perr := os.process_exec(
		{command = {"espeak-ng", "-v", "en-us", "-q", "--ipa", "-f", tmp}},
		context.allocator,
	)
	if perr != nil || state.exit_code != 0 {
		fmt.println("syllable oracle: espeak-ng is not available on this machine.")
		fmt.println("  No pronunciation dictionary was found either (hunspell has no")
		fmt.println("  dictionaries installed, and /usr/share/dict holds only a password")
		fmt.println("  list). The counter is therefore validated only against the")
		fmt.println("  hand-checked table in syllable.odin, which the selftest asserts.")
		return 7
	}
	defer delete(sout)

	lines := strings.split_lines(string(sout), context.temp_allocator)
	n, agree := 0, 0
	off_by_one := 0
	over, under := 0, 0
	shown := 0
	fmt.println("disagreements (first 25):")
	for w, i in sample {
		if i >= len(lines) {
			break
		}
		ipa := strings.trim_space(lines[i])
		if ipa == "" {
			continue
		}
		truth := ipa_syllables(ipa)
		if truth == 0 {
			continue
		}
		mine := syllables(w)
		n += 1
		if mine == truth {
			agree += 1
			continue
		}
		if mine > truth {
			over += 1
		} else {
			under += 1
		}
		if abs(mine - truth) == 1 {
			off_by_one += 1
		}
		if shown < 25 {
			fmt.printfln("  %-16s mine %d  espeak %d  %s", w, mine, truth, ipa)
			shown += 1
		}
	}
	if n == 0 {
		fmt.println("prose: the oracle returned nothing usable")
		return 7
	}
	fmt.println()
	fmt.printfln("syllable counting against espeak-ng, %d words from %s", n, list_path)
	fmt.printfln("  exact agreement   %d  (%.1f%%)", agree, f64(agree) / f64(n) * 100)
	fmt.printfln("  error rate        %.1f%%", f64(n - agree) / f64(n) * 100)
	fmt.printfln("  off by one        %d  (%.1f%% of all words)", off_by_one, f64(off_by_one) / f64(n) * 100)
	fmt.printfln("  overcounted       %d", over)
	fmt.printfln("  undercounted      %d", under)
	fmt.println()
	fmt.println("  espeak-ng is an oracle, not the truth: it is a letter-to-sound")
	fmt.println("  ruleset with an exception dictionary, and disagrees with a human")
	fmt.println("  on contested words ('every', 'fire'). The number above is the rate")
	fmt.println("  at which this estimator differs from it, which is the best")
	fmt.println("  available proxy on a machine with no pronunciation dictionary.")
	return 0
}

_ :: strconv
