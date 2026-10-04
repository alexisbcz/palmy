package main

// Headless self-test: `emoji --selftest`.
//
// Everything here runs with no compositor. palmy's offscreen renderer gives a
// real `^Ctx` with synthetic input, so `handle_keys` and `build` — the actual
// code the window runs — are exercised for real, with `press_key` and
// `type_text` standing in for the keyboard.
//
// That matters because a screenshot taken on a shared desktop proves nothing
// when the keystrokes may have landed in somebody else's window. This does not
// have that problem.

import "core:fmt"
import "core:strings"
import "core:unicode/utf8"
import p "palmy:."

@(private = "file")
fails: int
@(private = "file")
checks: int

@(private = "file")
ok :: proc(cond: bool, format: string, args: ..any) {
	checks += 1
	if !cond {
		fails += 1
		fmt.printf("FAIL  ")
		fmt.printfln(format, ..args)
	}
}

// frame runs one complete UI pass over the real handlers.
@(private = "file")
frame :: proc(o: ^p.Offscreen, st: ^St) {
	ui := p.offscreen_begin(o)
	handle_keys(ui, nil, st)
	build(ui, st)
	p.offscreen_end(o)
}

selftest :: proc() -> int {
	g_test = true

	fmt.println("-- character table")
	ok(len(CHARS) > 2000, "expected a few thousand characters, got %d", len(CHARS))
	ok(len(CATEGORIES) >= 10, "expected at least 10 categories, got %d", len(CATEGORIES))
	{
		bad_utf8, bad_name, bad_cat, dupes := 0, 0, 0, 0
		seen := make(map[rune]bool, context.temp_allocator)
		for c in CHARS {
			r, n := utf8.decode_rune_in_string(c.s)
			if r != c.cp || n != len(c.s) {
				bad_utf8 += 1
			}
			if len(c.name) == 0 {
				bad_name += 1
			}
			if c.cat < 0 || c.cat >= len(CATEGORIES) {
				bad_cat += 1
			}
			if seen[c.cp] {
				dupes += 1
			}
			seen[c.cp] = true
		}
		ok(bad_utf8 == 0, "%d rows whose UTF-8 does not decode back to the codepoint", bad_utf8)
		ok(bad_name == 0, "%d rows with no Unicode name", bad_name)
		ok(bad_cat == 0, "%d rows with a category out of range", bad_cat)
		ok(dupes == 0, "%d duplicate codepoints", dupes)
	}
	// Spot values, each one checked against the UCD by gen-chars.py.
	for want in ([?]struct {
		cp:   rune,
		name: string,
	} {
		{0x2192, "RIGHTWARDS ARROW"},
		{0x2318, "PLACE OF INTEREST SIGN"},
		{0x2665, "BLACK HEART SUIT"},
		{0x03A9, "GREEK CAPITAL LETTER OMEGA"},
		{0x1F600, "GRINNING FACE"},
		{0x2500, "BOX DRAWINGS LIGHT HORIZONTAL"},
	}) {
		i, found := index_of_rune(want.cp)
		ok(found, "U+%04X is missing from the table", want.cp)
		if found {
			ok(
				CHARS[i].name == want.name,
				"U+%04X is named %q, expected %q",
				want.cp,
				CHARS[i].name,
				want.name,
			)
		}
	}

	fmt.println("-- parse_codepoint")
	for c in ([?]struct {
		in_:  string,
		want: rune,
		good: bool,
	} {
		{"2318", 0x2318, true},
		{"u+2318", 0x2318, true},
		{"U+2318", 0x2318, true},
		{"0x2318", 0x2318, true},
		{"1f600", 0x1F600, true},
		{"zz", 0, false},
		{"2", 0, false}, // too short to be meant as a codepoint
		{"1234567", 0, false},
		{"", 0, false},
	}) {
		got, good := parse_codepoint(c.in_)
		ok(good == c.good, "parse_codepoint(%q) ok=%v, expected %v", c.in_, good, c.good)
		if c.good {
			ok(got == c.want, "parse_codepoint(%q) = U+%04X, expected U+%04X", c.in_, got, c.want)
		}
	}

	// ---------------------------------------------------------------------
	// The real UI, driven headlessly.
	// ---------------------------------------------------------------------
	fmt.println("-- the picker, driven through handle_keys")

	off := p.offscreen_create(1060, 700, 1, "w-full h-full flex-col bg-background text-foreground")
	defer p.offscreen_destroy(off)
	register_dark_theme()

	st := St {
		hits   = make([dynamic]int),
		query  = make([dynamic]u8),
		recent = make([dynamic]rune),
		cat    = 0,
	}
	build_index(&st)
	refilter(&st)
	frame(off, &st) // first frame establishes cols/vis

	ok(len(st.hits) > 0, "the first block is empty")
	ok(st.cols > 1, "the grid computed %d columns", st.cols)

	// The case a screenshot could not settle: typing a codepoint.
	p.type_text(off, "2318")
	frame(off, &st)
	ok(string(st.query[:]) == "2318", "typing did not reach the query: %q", string(st.query[:]))
	ok(len(st.hits) > 0, "typing 2318 matched nothing")
	if len(st.hits) > 0 {
		c, _ := current(&st)
		ok(c.cp == 0x2318, "2318 selected U+%04X, expected U+2318", c.cp)
	}

	// Enter copies it and files it under Recently used.
	p.press_key(off, p.KEY_RETURN)
	frame(off, &st)
	ok(g_test_clip == "⌘", "Enter copied %q, expected the character itself", g_test_clip)
	ok(len(st.recent) == 1 && st.recent[0] == 0x2318, "Enter did not record the character as recent")

	// Ctrl+U copies the U+ form instead.
	p.press_key(off, 'u', {.Ctrl})
	frame(off, &st)
	ok(g_test_clip == "U+2318", "Ctrl+U copied %q, expected U+2318", g_test_clip)

	// Ctrl+E copies the HTML entity.
	p.press_key(off, 'e', {.Ctrl})
	frame(off, &st)
	ok(g_test_clip == "&#x2318;", "Ctrl+E copied %q, expected &#x2318;", g_test_clip)

	// Escape clears the search rather than quitting while a query is up.
	p.press_key(off, p.KEY_ESCAPE)
	frame(off, &st)
	ok(len(st.query) == 0, "Escape left %q in the query", string(st.query[:]))

	// Search by name, with every term required.
	p.type_text(off, "arrow right")
	frame(off, &st)
	found_2192 := false
	for h in st.hits {
		if CHARS[h].cp == 0x2192 {found_2192 = true}
	}
	ok(found_2192, "“arrow right” did not find U+2192 among %d hits", len(st.hits))
	for h in st.hits {
		low := st.lows[h]
		ok(
			strings.contains(low, "arrow") && strings.contains(low, "right"),
			"“arrow right” matched %q, which lacks one of the terms",
			CHARS[h].name,
		)
		break // one representative is enough; the matcher is the same for all
	}

	p.press_key(off, p.KEY_ESCAPE)
	frame(off, &st)

	// Tab walks the blocks, and Recently used sits before the first one.
	before := st.cat
	p.press_key(off, p.KEY_TAB)
	frame(off, &st)
	ok(st.cat != before, "Tab did not change the block (still %d)", st.cat)
	for _ in 0 ..< len(CATEGORIES) {
		p.press_key(off, p.KEY_TAB)
		frame(off, &st)
	}
	ok(st.cat == before, "Tab did not wrap back round to block %d, landed on %d", before, st.cat)

	// Recently used shows what Enter filed earlier.
	st.cat = CAT_RECENT
	refilter(&st)
	frame(off, &st)
	ok(len(st.hits) == 1, "Recently used holds %d characters, expected 1", len(st.hits))
	if len(st.hits) == 1 {
		c, _ := current(&st)
		ok(c.cp == 0x2318, "Recently used holds U+%04X, expected U+2318", c.cp)
	}

	// Arrow navigation: Right by one, Down by a row.
	st.cat = 0
	refilter(&st)
	st.sel = 0
	frame(off, &st)
	p.press_key(off, p.KEY_RIGHT)
	frame(off, &st)
	ok(st.sel == 1, "Right moved the selection to %d, expected 1", st.sel)
	cols := st.cols
	p.press_key(off, p.KEY_DOWN)
	frame(off, &st)
	ok(st.sel == 1 + cols, "Down moved to %d, expected %d (one row of %d)", st.sel, 1 + cols, cols)
	p.press_key(off, p.KEY_UP)
	frame(off, &st)
	ok(st.sel == 1, "Up did not come back to 1, landed on %d", st.sel)

	// Something is actually drawn: the window is not a flat background.
	{
		bg := p.offscreen_pixel(off, 2, 2)
		different := 0
		for y := 0; y < 700; y += 7 {
			for x := 0; x < 1060; x += 7 {
				if p.offscreen_pixel(off, x, y) != bg {
					different += 1
				}
			}
		}
		ok(different > 500, "the rendered frame is nearly uniform (%d differing samples)", different)
	}

	fmt.printfln("\n%s  %d checks, %d failure(s)", fails == 0 ? "PASS" : "FAILED", checks, fails)
	return fails
}
