package palmy_tests

// bidi_test.odin — palmy/bidi.odin against libfribidi.
//
// UAX #9 is forty rules that interact, and an implementation written from the
// specification can be self-consistently wrong: expectations computed by the
// same reading of the same rule agree with the code and prove nothing. So the
// expectations here were not computed here. tools/bidi/gen-bidi-cases.py runs
// the corpus through ICU and libfribidi — two mature implementations nobody on
// this side wrote — and freezes their answers into tests/bidi_cases.odin;
// this file replays them. Neither library is linked: palmy links libc and
// libm, and the answers arrive as Odin source.
//
// An expectation counts only where *both* oracles give it. Neither is right
// everywhere — fribidi's rule N0 scans past sos and its X5c resolves some FSIs
// the wrong way, ICU's BD16 mispairs canonically equivalent brackets and it
// skips N0's clause about combining marks after a bracket — so a case the two
// answer differently is counted and left unasserted rather than settled by
// picking a favourite. There are a handful of those, and palmy follows the
// rules as written on each; tools/bidi/gen-bidi-cases.py --compare prints them
// and says which oracle palmy sided with.
//
// Where ICU reports the same levels lowered by an even amount — its documented
// minimisation, which clause C1 allows because only the ordering is normative
// — palmy has to match one side or the other, which is weaker but still
// catches an answer that is nobody's.
//
// Levels are compared only where the generated keep mask says 1 — at the
// characters rule X9 does not remove. The embedding controls and the boundary
// neutrals are invisible and UAX #9 leaves their levels undefined; palmy, ICU
// and fribidi each pick differently, and picking is not conformance.
//
// The corpus is deliberate and then random. The deliberate half walks the
// rules one at a time, so a failure names the rule it broke; the random half
// is thousands of mixed strings, because the rule you misread is the one you
// did not think to write a case for.

import "core:fmt"
import "core:mem"
import "core:strings"
import "core:testing"
import "core:unicode/utf8"
import p "../palmy"

// ---------------------------------------------------------------------------
// Parsing the generated data
// ---------------------------------------------------------------------------

@(private = "file")
BIDI_CLASS_NAMES := [?]struct {
	name:  string,
	class: p.Bidi_Class,
} {
	// Spelled out rather than derived from the enum's order, so that
	// reordering `Bidi_Class` cannot quietly reinterpret the generated data.
	{"L", .L},
	{"R", .R},
	{"AL", .AL},
	{"EN", .EN},
	{"ES", .ES},
	{"ET", .ET},
	{"AN", .AN},
	{"CS", .CS},
	{"NSM", .NSM},
	{"BN", .BN},
	{"B", .B},
	{"S", .S},
	{"WS", .WS},
	{"ON", .ON},
	{"LRE", .LRE},
	{"RLE", .RLE},
	{"LRO", .LRO},
	{"RLO", .RLO},
	{"PDF", .PDF},
	{"LRI", .LRI},
	{"RLI", .RLI},
	{"FSI", .FSI},
	{"PDI", .PDI},
}

@(private = "file")
bidi_class_named :: proc(name: string) -> (p.Bidi_Class, bool) {
	for e in BIDI_CLASS_NAMES {
		if e.name == name {
			return e.class, true
		}
	}
	return .L, false
}

@(private = "file")
field :: proc(s: ^string) -> string {
	if i := strings.index_byte(s^, '|'); i >= 0 {
		f := s^[:i]
		s^ = s^[i + 1:]
		return f
	}
	f := s^
	s^ = ""
	return f
}

// Hand-rolled so the replay loop allocates nothing: 4,549 cases through
// strconv and a split would be the slowest thing in the suite.
@(private = "file")
parse_ints :: proc(text: string, base: int, out: ^[dynamic]i32) {
	clear(out)
	value := i32(0)
	have := false
	for i in 0 ..< len(text) {
		c := text[i]
		digit := i32(-1)
		switch {
		case c >= '0' && c <= '9':
			digit = i32(c - '0')
		case c >= 'A' && c <= 'F':
			digit = i32(c - 'A' + 10)
		case c >= 'a' && c <= 'f':
			digit = i32(c - 'a' + 10)
		}
		if digit >= 0 && digit < i32(base) {
			value = value * i32(base) + digit
			have = true
			continue
		}
		if have {
			append(out, value)
		}
		value, have = 0, false
	}
	if have {
		append(out, value)
	}
}

@(private = "file")
encode :: proc(cps: []i32, out: ^[dynamic]u8) -> string {
	clear(out)
	for cp in cps {
		bytes, n := utf8.encode_rune(rune(cp))
		for i in 0 ..< n {
			append(out, bytes[i])
		}
	}
	return string(out[:])
}

// ---------------------------------------------------------------------------
// The replay
// ---------------------------------------------------------------------------

@(test)
test_bidi_matches_the_oracles :: proc(t: ^testing.T) {
	scratch: p.Bidi_Scratch
	p.bidi_scratch_init(&scratch)
	defer p.bidi_scratch_destroy(&scratch)

	cps := make([dynamic]i32, 0, 64)
	want_levels := make([dynamic]i32, 0, 64)
	want_order := make([dynamic]i32, 0, 64)
	par_levels := make([dynamic]i32, 0, 8192)
	text_buf := make([dynamic]u8, 0, 256)
	got_order := make([dynamic]i32, 0, 64)
	other_levels := make([dynamic]i32, 0, 64)
	cover := make([dynamic]u8, 0, 256)
	defer {
		delete(cps)
		delete(want_levels)
		delete(want_order)
		delete(par_levels)
		delete(text_buf)
		delete(got_order)
		delete(other_levels)
		delete(cover)
	}

	parse_ints(BIDI_PAR_LEVELS, 10, &par_levels)

	cases := 0
	checks := 0
	level_checks := 0
	order_checks := 0
	deviations := 0
	either_checks := 0
	failures := 0

	lines := BIDI_CASES
	for line in strings.split_lines_iterator(&lines) {
		if line == "" {
			continue
		}
		rest := line
		dir_field := field(&rest)
		cp_field := field(&rest)
		level_field := field(&rest)      // fribidi's
		icu_level_field := field(&rest)  // ICU's
		order_field := field(&rest)
		keep := field(&rest)
		agreed := field(&rest)
		label := rest

		dir := p.Bidi_Direction.Auto
		switch dir_field {
		case "L":
			dir = .LTR
		case "R":
			dir = .RTL
		case "A":
			dir = .Auto
		case:
			testing.expectf(t, false, "case %q: unknown base direction %q", label, dir_field)
			continue
		}
		if len(agreed) != 2 {
			testing.expectf(t, false, "case %q: malformed agreement flags %q", label, agreed)
			continue
		}
		order_agreed := agreed[0] == '1'
		levels_agreed := agreed[1] == '1' // '2' means "either oracle's answer"
		levels_either := agreed[1] == '2'
		if !order_agreed || agreed[1] == '0' {
			deviations += 1 // the oracles contradict each other here
		}

		parse_ints(cp_field, 16, &cps)
		parse_ints(level_field, 10, &want_levels)
		parse_ints(order_field, 10, &want_order)
		text := encode(cps[:], &text_buf)

		layout := p.bidi_resolve(text, dir, &scratch)
		cases += 1

		if len(keep) != len(cps) || len(want_levels) != len(cps) {
			testing.expectf(t, false, "case %q: malformed generated case", label)
			continue
		}

		// P2 and P3, on their own.
		checks += 1
		if cases - 1 < len(par_levels) && u8(par_levels[cases - 1]) != layout.base_level {
			failures += 1
			testing.expectf(
				t,
				false,
				"case %q: paragraph level %d, the oracle says %d",
				label,
				layout.base_level,
				par_levels[cases - 1],
			)
		}

		// The per-character levels: the W, N and I rules, then L1.
		checks += 1
		if !levels_agreed && !levels_either {
			// The oracles contradict each other: nothing to compare against.
		} else if len(layout.levels) != len(cps) {
			failures += 1
			testing.expectf(
				t,
				false,
				"case %q: %d levels for %d characters",
				label,
				len(layout.levels),
				len(cps),
			)
		} else {
			parse_ints(icu_level_field, 10, &other_levels)
			bad := -1
			like_fribidi, like_icu := true, true
			for i in 0 ..< len(cps) {
				if keep[i] == '0' {
					continue // removed by X9: no level to agree about
				}
				level_checks += 1
				got := i32(layout.levels[i])
				if got != want_levels[i] {
					like_fribidi = false
					if bad < 0 {
						bad = i
					}
				}
				if i >= len(other_levels) || got != other_levels[i] {
					like_icu = false
				}
			}
			if levels_either {
				either_checks += 1
				bad = like_fribidi || like_icu ? -1 : bad
			}
			if bad >= 0 {
				failures += 1
				testing.expectf(
					t,
					false,
					"case %q: levels %v, the oracle says %v (first difference at %d, keep %s)",
					label,
					layout.levels,
					want_levels[:],
					bad,
					keep,
				)
			}
		}

		// The reordering: L2, read back out of the runs.
		resize(&got_order, len(layout.levels))
		n := p.bidi_visual_order(layout, got_order[:])
		checks += 1
		if !order_agreed {
			// The oracles reorder this one differently: nothing to assert.
		} else if n != len(cps) {
			failures += 1
			testing.expectf(
				t,
				false,
				"case %q: %d visual positions for %d characters",
				label,
				n,
				len(cps),
			)
		} else {
			// Compare the visible characters' order, in order, skipping the
			// positions the oracle and palmy are free to place differently.
			bad := -1
			j := 0
			for i in 0 ..< n {
				if keep[got_order[i]] == '0' {
					continue
				}
				for j < len(want_order) && keep[want_order[j]] == '0' {
					j += 1
				}
				order_checks += 1
				if j >= len(want_order) || want_order[j] != got_order[i] {
					bad = i
					break
				}
				j += 1
			}
			if bad >= 0 {
				failures += 1
				testing.expectf(
					t,
					false,
					"case %q: visual order %v, the oracle says %v (first difference at %d, keep %s)",
					label,
					got_order[:n],
					want_order[:],
					bad,
					keep,
				)
			}
		}

		// The runs have to tile the string exactly — every byte covered once,
		// no gaps and no overlaps — or a caller drawing them left to right
		// would drop or double characters. They arrive in *visual* order, so
		// their byte ranges are not ascending.
		checks += 1
		resize(&cover, len(text))
		for i in 0 ..< len(text) {
			cover[i] = 0
		}
		tiled := true
		for run in layout.runs {
			if run.start < 0 || run.end > len(text) || run.end <= run.start {
				tiled = false
				break
			}
			for i in run.start ..< run.end {
				cover[i] += 1
			}
		}
		covered := 0
		for i in 0 ..< len(text) {
			if cover[i] == 1 {
				covered += 1
			}
		}
		if !tiled || covered != len(text) {
			failures += 1
			testing.expectf(
				t,
				false,
				"case %q: runs %v do not tile %d bytes",
				label,
				layout.runs,
				len(text),
			)
		}

		// Every run's level has to be the level of the characters in it, or a
		// caller would draw a right-to-left run left to right.
		checks += 1
		for run in layout.runs {
			first := p.bidi_rune_index(layout, run.start)
			if layout.levels[first] != run.level {
				failures += 1
				testing.expectf(
					t,
					false,
					"case %q: run %v holds a character at level %d",
					label,
					run,
					layout.levels[first],
				)
				break
			}
		}

		// palmy's own convention for the characters X9 removed: each takes the
		// level of the character before it — or of the one after it, at the
		// start of the text — so that an invisible control never forms a run
		// of its own and never splits one.
		checks += 1
		for i in 0 ..< len(cps) {
			if keep[i] == '1' {
				continue
			}
			lvl := layout.levels[i]
			neighbour := i > 0 ? layout.levels[i - 1] : (i + 1 < len(cps) ? layout.levels[i + 1] : layout.base_level)
			if lvl != neighbour {
				failures += 1
				testing.expectf(
					t,
					false,
					"case %q: the removed character at %d has level %d, its neighbour %d",
					label,
					i,
					lvl,
					neighbour,
				)
				break
			}
		}

		if failures > 8 {
			testing.expectf(t, false, "stopping after %d failing cases", failures)
			break
		}
	}

	testing.expectf(t, cases > 4000, "only %d cases replayed", cases)
	testing.expect_value(t, cases, len(par_levels))
	testing.expect_value(t, deviations, BIDI_N0_DEVIATIONS + BIDI_LEVEL_CONFLICTS)
	testing.expect_value(t, either_checks, BIDI_LEVEL_SIMPLIFICATIONS)
	fmt.printf(
		"\n  bidi: %d cases against ICU and fribidi, %d expectations (%d levels, %d visual positions), %d failures\n",
		cases,
		checks + level_checks + order_checks,
		level_checks,
		order_checks,
		failures,
	)
	fmt.printf(
		"  bidi: %d cases where ICU and fribidi contradict each other are counted and not asserted (%d of them rule N0); %d more allow either oracle's levels, where ICU's are the same levels lowered evenly\n",
		deviations,
		BIDI_N0_DEVIATIONS,
		either_checks,
	)
}

// ---------------------------------------------------------------------------
// The generated character tables, against fribidi's copy of the same data
// ---------------------------------------------------------------------------

@(test)
test_bidi_class_table :: proc(t: ^testing.T) {
	// palmy's table comes from Python's unicodedata and Perl's unicore files;
	// fribidi's comes from fribidi's own generator. Walking all 1,114,112
	// codepoints is the cheapest way to be sure the range table's binary
	// search and its boundaries are right.
	MAX :: 0x110000
	expect := make([]p.Bidi_Class, MAX)
	defer delete(expect)

	ranges := 0
	lines := BIDI_FRIBIDI_CLASSES
	for line in strings.split_lines_iterator(&lines) {
		if line == "" {
			continue
		}
		parts := strings.fields(line, context.temp_allocator)
		if len(parts) != 3 {
			testing.expectf(t, false, "bad class range %q", line)
			continue
		}
		lo := parse_hex(parts[0])
		hi := parse_hex(parts[1])
		class, ok := bidi_class_named(parts[2])
		testing.expectf(t, ok, "unknown class %q", parts[2])
		for cp in lo ..= hi {
			expect[cp] = class
		}
		ranges += 1
	}
	free_all(context.temp_allocator)
	testing.expectf(t, ranges > 1000, "only %d class ranges", ranges)

	// Where palmy deliberately differs — unassigned codepoints, where palmy
	// follows DerivedBidiClass's @missing defaults and fribidi does not.
	exceptions := 0
	excepted := 0
	elines := BIDI_CLASS_EXCEPTIONS
	for line in strings.split_lines_iterator(&elines) {
		if line == "" {
			continue
		}
		parts := strings.fields(line, context.temp_allocator)
		if len(parts) != 4 {
			testing.expectf(t, false, "bad exception %q", line)
			continue
		}
		lo := parse_hex(parts[0])
		hi := parse_hex(parts[1])
		mine, ok := bidi_class_named(parts[2])
		testing.expectf(t, ok, "unknown class %q", parts[2])
		for cp in lo ..= hi {
			expect[cp] = mine
			excepted += 1
		}
		exceptions += 1
	}
	free_all(context.temp_allocator)

	bad := 0
	first := -1
	for cp in 0 ..< MAX {
		if p.bidi_class(rune(cp)) != expect[cp] {
			if first < 0 {
				first = cp
			}
			bad += 1
		}
	}
	testing.expectf(
		t,
		bad == 0,
		"%d codepoints disagree with fribidi, first U+%04X: palmy %v, fribidi %v",
		bad,
		first,
		first >= 0 ? p.bidi_class(rune(first)) : p.Bidi_Class.L,
		first >= 0 ? expect[first] : p.Bidi_Class.L,
	)
	fmt.printf(
		"  bidi: %d codepoints checked against fribidi's class table, %d in %d ranges where palmy follows DerivedBidiClass's unassigned defaults instead\n",
		MAX,
		excepted,
		exceptions,
	)

	// Out-of-range codepoints must not walk off the table.
	testing.expect_value(t, p.bidi_class(rune(-1)), p.Bidi_Class.L)
	testing.expect_value(t, p.bidi_class(rune(0x110000)), p.Bidi_Class.L)
	testing.expect_value(t, p.bidi_class(rune(0x7FFFFFFF)), p.Bidi_Class.L)
}

@(private = "file")
parse_hex :: proc(s: string) -> int {
	v := 0
	for i in 0 ..< len(s) {
		c := s[i]
		switch {
		case c >= '0' && c <= '9':
			v = v * 16 + int(c - '0')
		case c >= 'A' && c <= 'F':
			v = v * 16 + int(c - 'A' + 10)
		case c >= 'a' && c <= 'f':
			v = v * 16 + int(c - 'a' + 10)
		}
	}
	return v
}

@(test)
test_bidi_mirror_table :: proc(t: ^testing.T) {
	pairs := 0
	lines := BIDI_FRIBIDI_MIRRORS
	for line in strings.split_lines_iterator(&lines) {
		if line == "" {
			continue
		}
		parts := strings.fields(line, context.temp_allocator)
		if len(parts) != 2 {
			testing.expectf(t, false, "bad mirror pair %q", line)
			continue
		}
		cp := rune(parse_hex(parts[0]))
		want := rune(parse_hex(parts[1]))
		testing.expectf(
			t,
			p.bidi_mirror(cp) == want,
			"U+%04X mirrors to U+%04X, fribidi says U+%04X",
			cp,
			p.bidi_mirror(cp),
			want,
		)
		testing.expect(t, p.bidi_mirrored(cp))
		pairs += 1
	}
	free_all(context.temp_allocator)
	testing.expectf(t, pairs > 400, "only %d mirror pairs", pairs)

	// And nothing else may claim a mirror: a stray entry would mirror a
	// character that should be drawn as itself.
	mirrored := 0
	for cp in 0 ..< 0x110000 {
		if p.bidi_mirrored(rune(cp)) {
			mirrored += 1
		}
	}
	testing.expect_value(t, mirrored, pairs)

	// The rule L4 cases that are visible to a reader.
	testing.expect_value(t, p.bidi_mirror('('), ')')
	testing.expect_value(t, p.bidi_mirror(')'), '(')
	testing.expect_value(t, p.bidi_mirror('<'), '>')
	testing.expect_value(t, p.bidi_mirror('['), ']')
	testing.expect_value(t, p.bidi_mirror('«'), '»')
	testing.expect_value(t, p.bidi_mirror('A'), 'A')
	testing.expect_value(t, p.bidi_mirror('א'), 'א')
	fmt.printf("  bidi: %d mirror pairs checked against fribidi\n", pairs)
}

@(test)
test_bidi_bracket_table :: proc(t: ^testing.T) {
	brackets := 0
	lines := BIDI_FRIBIDI_BRACKETS
	for line in strings.split_lines_iterator(&lines) {
		if line == "" {
			continue
		}
		parts := strings.fields(line, context.temp_allocator)
		if len(parts) != 3 {
			testing.expectf(t, false, "bad bracket %q", line)
			continue
		}
		cp := rune(parse_hex(parts[0]))
		paired, opening, ok := p.bidi_bracket(cp)
		testing.expectf(t, ok, "U+%04X is a bracket to fribidi but not to palmy", cp)
		testing.expectf(
			t,
			opening == (parts[1] == "O"),
			"U+%04X: palmy says opening=%v, fribidi says %q",
			cp,
			opening,
			parts[1],
		)
		// Every paired bracket is its own mirror, which is a second way of
		// saying the two tables agree about the pairing.
		testing.expectf(
			t,
			paired == p.bidi_mirror(cp),
			"U+%04X pairs with U+%04X but mirrors to U+%04X",
			cp,
			paired,
			p.bidi_mirror(cp),
		)
		brackets += 1
	}
	free_all(context.temp_allocator)
	testing.expectf(t, brackets > 100, "only %d brackets", brackets)

	found := 0
	for cp in 0 ..< 0x110000 {
		if _, _, ok := p.bidi_bracket(rune(cp)); ok {
			found += 1
		}
	}
	testing.expect_value(t, found, brackets)
	fmt.printf("  bidi: %d paired brackets checked against fribidi\n", brackets)
}

// ---------------------------------------------------------------------------
// The API the integration will call
// ---------------------------------------------------------------------------

@(test)
test_bidi_runs_are_what_a_caller_draws :: proc(t: ^testing.T) {
	scratch: p.Bidi_Scratch
	p.bidi_scratch_init(&scratch)
	defer p.bidi_scratch_destroy(&scratch)

	// "abc " then two Hebrew letters: the Latin draws first, the Hebrew after
	// it but reversed within its own run.
	text := "abc אב"
	layout := p.bidi_resolve(text, .Auto, &scratch)
	testing.expect_value(t, layout.base_level, u8(0))
	testing.expect_value(t, len(layout.runs), 2)
	testing.expect_value(t, layout.runs[0], p.Bidi_Run{start = 0, end = 4, level = 0})
	testing.expect_value(t, layout.runs[1], p.Bidi_Run{start = 4, end = 8, level = 1})
	testing.expect(t, !p.bidi_is_rtl(layout.runs[0].level))
	testing.expect(t, p.bidi_is_rtl(layout.runs[1].level))

	// The same string as a right-to-left paragraph: the Hebrew comes first
	// visually, and the space between the two scripts goes to the paragraph
	// level — N2 — so it rides with the Hebrew rather than with the Latin.
	layout = p.bidi_resolve(text, .RTL, &scratch)
	testing.expect_value(t, layout.base_level, u8(1))
	testing.expect(t, p.bidi_layout_rtl(layout))
	testing.expect_value(t, len(layout.runs), 2)
	testing.expect_value(t, layout.runs[0], p.Bidi_Run{start = 3, end = 8, level = 1})
	testing.expect_value(t, layout.runs[1], p.Bidi_Run{start = 0, end = 3, level = 2})

	// A Hebrew sentence with a number in it: the digits stay left to right
	// inside the right-to-left run, which is the W2/I1 pair at work.
	layout = p.bidi_resolve("אב 123 ג", .Auto, &scratch)
	testing.expect_value(t, layout.base_level, u8(1))
	levels := layout.levels
	testing.expect_value(t, levels[0], u8(1)) // alef
	testing.expect_value(t, levels[3], u8(2)) // '1'
	testing.expect_value(t, levels[5], u8(2)) // '3'
	testing.expect_value(t, levels[7], u8(1)) // gimel
	// Visually: gimel, then "123", then bet, alef.
	order := make([]i32, len(levels))
	defer delete(order)
	n := p.bidi_visual_order(layout, order)
	testing.expect_value(t, n, len(levels))
	testing.expect_value(t, order[0], i32(7))
	testing.expect_value(t, order[2], i32(3))
	testing.expect_value(t, order[4], i32(5))
	testing.expect_value(t, order[7], i32(0))
}

@(test)
test_bidi_brackets_bracket_the_right_way :: proc(t: ^testing.T) {
	scratch: p.Bidi_Scratch
	p.bidi_scratch_init(&scratch)
	defer p.bidi_scratch_destroy(&scratch)

	// N0: a parenthesised Latin aside inside Hebrew. Both parentheses must
	// end up at the Hebrew level — if N0 is skipped they stay neutral, resolve
	// to the Latin level, and the aside renders as ")hello(".
	layout := p.bidi_resolve("א(ab)ב", .Auto, &scratch)
	testing.expect_value(t, layout.levels[1], u8(1)) // '('
	testing.expect_value(t, layout.levels[4], u8(1)) // ')'
	testing.expect_value(t, layout.levels[2], u8(2)) // 'a'

	// And the mirroring that goes with it: at level 1 the '(' is drawn ')'.
	testing.expect(t, p.bidi_is_rtl(layout.levels[1]))
	testing.expect_value(t, p.bidi_mirror('('), ')')

	// N0 d: nothing strong inside, so the brackets stay neutral and follow
	// their surroundings rather than being forced.
	layout = p.bidi_resolve("a(!)א", .LTR, &scratch)
	testing.expect_value(t, layout.levels[1], u8(0))

	// Canonical equivalence, BD16: U+2329 pairs with U+3009.
	layout = p.bidi_resolve("א〈a〉ב", .Auto, &scratch)
	testing.expect_value(t, layout.levels[1], u8(1))
	testing.expect_value(t, layout.levels[3], u8(1))
}

@(test)
test_bidi_isolates :: proc(t: ^testing.T) {
	scratch: p.Bidi_Scratch
	p.bidi_scratch_init(&scratch)
	defer p.bidi_scratch_destroy(&scratch)

	// An LRI/PDI pair is how real text embeds a Latin name in a Hebrew
	// sentence without the punctuation leaking out of it.
	layout := p.bidi_resolve("א⁦ab!⁩ב", .Auto, &scratch)
	testing.expect_value(t, layout.base_level, u8(1))
	testing.expect_value(t, layout.levels[1], u8(1)) // the LRI itself
	testing.expect_value(t, layout.levels[2], u8(2)) // 'a'
	testing.expect_value(t, layout.levels[4], u8(2)) // '!' — inside, so LTR
	testing.expect_value(t, layout.levels[5], u8(1)) // the PDI

	// Without the isolate the '!' belongs to the Hebrew, which is the whole
	// point of the mechanism.
	layout = p.bidi_resolve("אab!ב", .Auto, &scratch)
	testing.expect_value(t, layout.levels[3], u8(1))

	// FSI picks its own direction from its contents.
	layout = p.bidi_resolve("a⁨אb⁩c", .LTR, &scratch)
	testing.expect_value(t, layout.levels[2], u8(1)) // alef, inside an RTL isolate

	// The controls themselves must never be drawn.
	testing.expect(t, p.bidi_is_control('⁦'))
	testing.expect(t, p.bidi_is_control('‬'))
	testing.expect(t, p.bidi_is_control('­'))
	testing.expect(t, !p.bidi_is_control('a'))
	testing.expect(t, !p.bidi_is_control(' '))
}

@(test)
test_bidi_degenerate_input :: proc(t: ^testing.T) {
	scratch: p.Bidi_Scratch
	p.bidi_scratch_init(&scratch)
	defer p.bidi_scratch_destroy(&scratch)

	layout := p.bidi_resolve("", .Auto, &scratch)
	testing.expect_value(t, len(layout.runs), 0)
	testing.expect_value(t, len(layout.levels), 0)
	testing.expect_value(t, layout.base_level, u8(0))
	testing.expect_value(t, p.bidi_level_at(layout, 0), u8(0))

	layout = p.bidi_resolve("", .RTL, &scratch)
	testing.expect_value(t, layout.base_level, u8(1))
	testing.expect_value(t, p.bidi_level_at(layout, 0), u8(1))
	testing.expect(t, p.bidi_layout_rtl(layout))

	// Only controls: every level is the paragraph level, and the runs still
	// tile the string.
	layout = p.bidi_resolve("‪‫‬⁦⁩", .RTL, &scratch)
	for lvl in layout.levels {
		testing.expect_value(t, lvl, u8(1))
	}
	testing.expect_value(t, len(layout.runs), 1)
	testing.expect_value(t, layout.runs[0].end, 15)

	// A line of nothing but neutrals takes the paragraph direction.
	layout = p.bidi_resolve("! * =", .RTL, &scratch)
	for lvl in layout.levels {
		testing.expect_value(t, lvl, u8(1))
	}

	// A zeroed scratch initialises itself on first use, which is the path a
	// caller takes who has not read the documentation.
	fresh: p.Bidi_Scratch
	lazy := p.bidi_resolve("a\u05d0\u05d1", .Auto, &fresh)
	testing.expect_value(t, len(lazy.levels), 3)
	testing.expect_value(t, len(lazy.runs), 2)
	testing.expect_value(t, lazy.runs[1].level, u8(1))
	p.bidi_scratch_destroy(&fresh)

	// P2/P3 without resolving anything.
	testing.expect_value(t, p.bidi_base_level(""), u8(0))
	testing.expect_value(t, p.bidi_base_level("hello"), u8(0))
	testing.expect_value(t, p.bidi_base_level("א"), u8(1))
	testing.expect_value(t, p.bidi_base_level("123 א"), u8(1))
	testing.expect_value(t, p.bidi_base_level("⁦א⁩a"), u8(0)) // isolate skipped
	testing.expect_value(t, p.bidi_base_level("⁦א"), u8(0)) // unterminated isolate
	testing.expect_value(t, p.bidi_base_level("א", .LTR), u8(0))
	testing.expect_value(t, p.bidi_base_level("a", .RTL), u8(1))

	// `bidi_base_level` has to agree with the full resolve, since a caller
	// that only needs the paragraph direction will use the cheap one.
	for s in ([?]string {
			"",
			"a",
			"א",
			"123א",
			"!اb",
			"⁦א⁩a",
			"⁧a⁩א",
		}) {
		layout = p.bidi_resolve(s, .Auto, &scratch)
		testing.expectf(
			t,
			p.bidi_base_level(s) == layout.base_level,
			"%q: base level %d on its own, %d from the resolve",
			s,
			p.bidi_base_level(s),
			layout.base_level,
		)
	}
}

@(test)
test_bidi_caret_helpers :: proc(t: ^testing.T) {
	scratch: p.Bidi_Scratch
	p.bidi_scratch_init(&scratch)
	defer p.bidi_scratch_destroy(&scratch)

	// Two Hebrew letters, two bytes each, then "ab".
	text := "אבab"
	layout := p.bidi_resolve(text, .Auto, &scratch)
	testing.expect_value(t, len(layout.levels), 4)
	testing.expect_value(t, len(layout.offsets), 5)
	testing.expect_value(t, layout.offsets[0], i32(0))
	testing.expect_value(t, layout.offsets[1], i32(2))
	testing.expect_value(t, layout.offsets[2], i32(4))
	testing.expect_value(t, layout.offsets[4], i32(6))

	testing.expect_value(t, p.bidi_rune_index(layout, 0), 0)
	testing.expect_value(t, p.bidi_rune_index(layout, 1), 0) // inside the first letter
	testing.expect_value(t, p.bidi_rune_index(layout, 2), 1)
	testing.expect_value(t, p.bidi_rune_index(layout, 5), 3)

	testing.expect_value(t, p.bidi_level_at(layout, 0), u8(1))
	testing.expect_value(t, p.bidi_level_at(layout, 4), u8(2))
	// Past the end a caret sits at the paragraph level, which is where the
	// next character typed will go.
	testing.expect_value(t, p.bidi_level_at(layout, 6), layout.base_level)

	// A short buffer must truncate rather than overrun.
	short := make([]i32, 2)
	defer delete(short)
	testing.expect_value(t, p.bidi_visual_order(layout, short), 2)
}

@(test)
test_bidi_scratch_stops_allocating :: proc(t: ^testing.T) {
	// This module is called per text node, per frame. A design that allocated
	// per call would be a cost nobody could see in a profile but everybody
	// would pay, so the scratch is the API and this is the test that it works.
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)

	scratch: p.Bidi_Scratch
	p.bidi_scratch_init(&scratch, mem.tracking_allocator(&track))

	samples := [?]string {
		"hello world",
		"שלום עולם",
		"السعر ١٢٣ $",
		"a(אב)b",
		"א⁦latin⁩ב",
		"mixed 123 ١٢ text אב end",
	}

	// Warm up: the buffers grow to the longest string once.
	for _ in 0 ..< 4 {
		for s in samples {
			_ = p.bidi_resolve(s, .Auto, &scratch)
		}
	}
	allocations := track.total_allocation_count

	for _ in 0 ..< 200 {
		for s in samples {
			layout := p.bidi_resolve(s, .Auto, &scratch)
			testing.expect(t, len(layout.runs) > 0)
		}
	}
	testing.expectf(
		t,
		track.total_allocation_count == allocations,
		"%d allocations in 1,200 warm resolves",
		track.total_allocation_count - allocations,
	)

	p.bidi_scratch_destroy(&scratch)
	testing.expectf(
		t,
		len(track.allocation_map) == 0,
		"%d allocations still live after the scratch was destroyed",
		len(track.allocation_map),
	)
	testing.expect_value(t, len(track.bad_free_array), 0)
}

@(test)
test_bidi_pathological_input_terminates :: proc(t: ^testing.T) {
	// The depth limits of X2–X5c and BD16 exist so that a string of nothing
	// but controls cannot cost unbounded work. A caller may well be handed
	// one by a paste.
	scratch: p.Bidi_Scratch
	p.bidi_scratch_init(&scratch)
	defer p.bidi_scratch_destroy(&scratch)

	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	for _ in 0 ..< 500 {
		strings.write_rune(&b, '‫') // RLE
	}
	strings.write_rune(&b, 'א')
	for _ in 0 ..< 500 {
		strings.write_rune(&b, '⁦') // LRI, never closed
	}
	strings.write_string(&b, "abc")
	text := strings.to_string(b)

	layout := p.bidi_resolve(text, .Auto, &scratch)
	testing.expect_value(t, len(layout.levels), 1004)
	testing.expect(t, layout.max_level <= 125 + 2)

	// Deeply nested brackets, past BD16's 63-pair stack.
	strings.builder_reset(&b)
	for _ in 0 ..< 200 {
		strings.write_rune(&b, '(')
	}
	strings.write_rune(&b, 'א')
	for _ in 0 ..< 200 {
		strings.write_rune(&b, ')')
	}
	layout = p.bidi_resolve(strings.to_string(b), .LTR, &scratch)
	testing.expect_value(t, len(layout.levels), 401)
	testing.expect_value(t, layout.levels[200], u8(1))
}

// ---------------------------------------------------------------------------
// Where the oracles are wrong
// ---------------------------------------------------------------------------

@(test)
test_bidi_where_the_oracles_disagree :: proc(t: ^testing.T) {
	// The four cases below are the ones ICU and libfribidi answer differently,
	// reduced until only one of them is wrong. Each expectation here was
	// derived by hand from the rules and is corroborated by whichever oracle
	// does not have the bug in question — which is also the reason the replay
	// above asserts nothing on a case the two disagree about. The same two
	// bugs, met together, are the only disagreements a 400,000-case fuzz run
	// turns up; `tools/bidi/gen-bidi-cases.py --compare` prints them.
	scratch: p.Bidi_Scratch
	p.bidi_scratch_init(&scratch)
	defer p.bidi_scratch_destroy(&scratch)

	expect_levels :: proc(
		t: ^testing.T,
		scratch: ^p.Bidi_Scratch,
		text: string,
		dir: p.Bidi_Direction,
		want: []u8,
		why: string,
	) {
		layout := p.bidi_resolve(text, dir, scratch)
		if len(layout.levels) != len(want) {
			testing.expectf(t, false, "%s: %d levels for %d expected", why, len(layout.levels), len(want))
			return
		}
		for lvl, i in layout.levels {
			testing.expectf(
				t,
				lvl == want[i],
				"%s: level %d at %d, expected %d (%v)",
				why,
				lvl,
				i,
				want[i],
				layout.levels,
			)
		}
	}

	// BD16 pops its stack at the *first* canonically equivalent closing
	// bracket, so U+3008 pairs with the U+3009 beside it and the later U+232A
	// is left unpaired — a neutral between two right-to-left letters, which N1
	// then makes right-to-left. ICU instead pairs U+3008 with the far U+232A,
	// which drags `=` to the left-to-right side. fribidi agrees with palmy.
	expect_levels(
		t,
		&scratch,
		"〈!〉ב〉=ا",
		.LTR,
		{0, 0, 0, 1, 1, 1, 1},
		"BD16 pairs the nearest canonical equivalent",
	)

	// N0's last clause: a combining mark immediately after a bracket that the
	// rule *changed* takes the bracket's direction. Here the pair holds a
	// Hebrew letter and the context before it is Hebrew too, so both brackets
	// become R and the mark after the closing bracket follows them. ICU skips
	// this clause and leaves the mark neutral; fribidi agrees with palmy.
	expect_levels(
		t,
		&scratch,
		"א(ב)̀A",
		.LTR,
		{1, 1, 1, 1, 1, 0},
		"N0 carries a combining mark with its bracket",
	)

	// The same clause must *not* fire when N0 left the brackets alone: this
	// pair holds nothing strong, so rule N0 d leaves both neutral and the mark
	// inside stays with the surrounding text. The unpaired `)` after it is
	// then a neutral between two right-to-left letters. fribidi carries the
	// change over anyway; ICU agrees with palmy.
	expect_levels(
		t,
		&scratch,
		"(̀)ב)=ا",
		.LTR,
		{0, 0, 0, 1, 1, 1, 1},
		"N0 d leaves an unchanged pair alone",
	)

	// N0's backward scan for the preceding strong context stops at sos, which
	// is the start of the isolating run sequence — here the start of the LRE's
	// own level run. sos is left-to-right, because it is the direction of the
	// higher of the two levels either side of the boundary, so the brackets
	// take the embedding direction rather than the Hebrew before them.
	// fribidi scans past sos, finds that Hebrew, and brackets the other way;
	// ICU agrees with palmy.
	expect_levels(
		t,
		&scratch,
		"א‪[א]A",
		.RTL,
		{1, 1, 2, 3, 2, 2},
		"N0 stops its backward scan at sos",
	)
}
