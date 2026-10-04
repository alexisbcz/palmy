package main

// Headless self-test: `clipboard --selftest`.
//
// No compositor, no wl-clipboard, no watcher thread. The store is driven
// directly and the UI is driven through palmy's offscreen renderer, which hands
// out a real `^Ctx` with synthetic input — so `handle_keys` and `build` are the
// same code the window runs.
//
// `HOME` is redirected to a scratch directory first, so the persistence checks
// never touch the real history.

import "core:fmt"
import "core:os"
import "core:strings"
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

@(private = "file")
frame :: proc(o: ^p.Offscreen, st: ^St) {
	ui := p.offscreen_begin(o)
	refilter(st)
	handle_keys(ui, nil, st)
	refilter(st)
	build(ui, st)
	p.offscreen_end(o)
}

@(private = "file")
mk :: proc(text: string, when_: i64) -> Entry {
	e := Entry {
		id    = fnv(transmute([]u8)text),
		kind  = .Text,
		text  = strings.clone(text),
		mime  = strings.clone("text/plain;charset=utf-8"),
		size  = len(text),
		when_ = when_,
	}
	e.preview = make_preview(e.text)
	e.lower = strings.to_lower(e.text)
	return e
}

// SCRATCH_HOME is set before anything else runs. `push` persists, so a single
// store check performed against the real HOME would overwrite the user's
// actual clipboard history with fixtures — which is exactly what happened the
// first time this file was written.
SCRATCH_HOME :: "/tmp/palmy-clipboard-selftest"

selftest :: proc() -> int {
	g_test = true

	_ = os.remove_all(SCRATCH_HOME)
	_ = os.make_directory_all(SCRATCH_HOME)
	_ = os.set_env("HOME", SCRATCH_HOME)
	ensure_dirs()
	{
		dir := data_dir()
		ok(
			strings.has_prefix(dir, SCRATCH_HOME),
			"the self-test must never touch the real history; data_dir is %s",
			dir,
		)
	}

	// ---------------------------------------------------------------------
	fmt.println("-- the fuzzy matcher")
	{
		score, hit, good := fuzzy("store.odin", "sto")
		ok(good, "“sto” should match “store.odin”")
		ok(score > 0, "a match should score above zero, got %d", score)
		ok(hit_at(hit, 0) && hit_at(hit, 1) && hit_at(hit, 2), "the first three bytes should be marked")

		_, _, g2 := fuzzy("store.odin", "sdn") // s, d, n in order
		ok(g2, "a scattered subsequence should still match")
		_, _, g3 := fuzzy("store.odin", "zzz")
		ok(!g3, "“zzz” should not match “store.odin”")
		_, _, g4 := fuzzy("abc", "")
		ok(g4, "an empty needle should match everything")
		_, _, g5 := fuzzy("ab", "abc")
		ok(!g5, "a needle longer than the haystack cannot match")

		// A hit at the start of a word beats one buried mid-word.
		a, _, _ := fuzzy("odin build", "b")
		b, _, _ := fuzzy("abcdb", "b")
		ok(a > b, "a word-initial hit (%d) should outscore a mid-word one (%d)", a, b)
		// Adjacent hits beat scattered ones.
		c, _, _ := fuzzy("report.txt", "rep")
		d, _, _ := fuzzy("rxexpxort", "rep")
		ok(c > d, "adjacent hits (%d) should outscore scattered ones (%d)", c, d)
	}

	fmt.println("-- previews, escaping and sizes")
	{
		ok(make_preview("  a\n\tb  ", context.temp_allocator) == "a b", "whitespace should collapse to single spaces")
		ok(make_preview("\n\n\n", context.temp_allocator) == "(whitespace)", "an all-whitespace payload needs a visible stand-in")

		for s in ([?]string{"plain", "a\tb", "a\nb", "a\\b", "a\r\nb\t\\c", "", "ünïcødé ✓"}) {
			b := strings.builder_make(context.temp_allocator)
			escape(&b, s)
			back := unescape(strings.to_string(b), context.temp_allocator)
			ok(back == s, "escape/unescape round trip failed for %q, got %q", s, back)
		}

		ok(human_size(512) == "512 B", "512 B, got %s", human_size(512))
		ok(human_size(2048) == "2.0 KB", "2.0 KB, got %s", human_size(2048))
		ok(strings.has_suffix(human_size(5 * 1024 * 1024), "MB"), "megabytes, got %s", human_size(5 * 1024 * 1024))

		v, good := parse_i64("1791108508")
		ok(good && v == 1791108508, "parse_i64 of a timestamp")
		_, bad := parse_i64("12x")
		ok(!bad, "parse_i64 should reject “12x”")
	}

	// ---------------------------------------------------------------------
	fmt.println("-- the sensitivity gate")
	{
		for types in ([?]string {
			"text/plain\nx-kde-passwordManagerHint",
			"application/x-kde-passwordManagerHint",
			"text/plain\nx-nextcloud-passwords",
			"text/plain\napplication/secret",
			"PASSWORD",
		}) {
			secret, hint := is_sensitive(types)
			ok(secret, "%q should be treated as sensitive", types)
			ok(hint != "", "a sensitive selection should name the hint it matched")
		}
		for types in ([?]string{"text/plain\ntext/html\nUTF8_STRING", "image/png\nimage/bmp"}) {
			secret, _ := is_sensitive(types)
			ok(!secret, "%q should not be treated as sensitive", types)
		}
	}

	fmt.println("-- choosing a type to ask for")
	{
		m, k, good := pick_type("text/plain\nimage/png\ntext/html")
		ok(good && k == .Image && m == "image/png", "an image should win over the text wrappers, got %v %q", k, m)

		m2, k2, good2 := pick_type("TEXT\ntext/plain\ntext/plain;charset=utf-8\nSTRING")
		ok(good2 && k2 == .Text && m2 == "text/plain;charset=utf-8", "UTF-8 plain text should be preferred, got %q", m2)

		m3, k3, good3 := pick_type("text/x-markdown")
		ok(good3 && k3 == .Text && m3 == "text/x-markdown", "any text/* should be accepted, got %q", m3)

		_, _, good4 := pick_type("application/x-rar-compressed")
		ok(!good4, "an unknown binary type should be declined rather than stored blind")
	}

	fmt.println("-- thumbnailing")
	{
		src := p.Image {
			px = make([]u32, 8 * 4),
			w  = 8,
			h  = 4,
		}
		defer delete(src.px)
		for i in 0 ..< len(src.px) {
			src.px[i] = 0xff0000ff // opaque blue everywhere
		}
		th := shrink(src, 4, 4)
		defer delete(th.px)
		ok(th.w == 4 && th.h == 2, "an 8x4 image fitted to 4x4 should be 4x2, got %dx%d", th.w, th.h)
		flat := true
		for v in th.px {
			if v != 0xff0000ff {flat = false}
		}
		ok(flat, "a uniform source should box-filter to the same uniform colour")

		big := shrink(src, 100, 100)
		defer delete(big.px)
		ok(big.w == 8 && big.h == 4, "shrink must never enlarge, got %dx%d", big.w, big.h)
	}

	// ---------------------------------------------------------------------
	fmt.println("-- the history: ordering, de-duplication, the cap and pins")
	{
		clear(&g.items)
		push(mk("one", 100))
		push(mk("two", 101))
		push(mk("three", 102))
		ok(len(g.items) == 3, "three pushes should give three entries, got %d", len(g.items))
		ok(g.items[0].text == "three", "the newest entry should be first, got %q", g.items[0].text)

		// The same payload again is promoted, not duplicated.
		push(mk("one", 103))
		ok(len(g.items) == 3, "a repeat should not add an entry, got %d", len(g.items))
		ok(g.items[0].text == "one", "a repeat should be promoted to the top, got %q", g.items[0].text)
		ok(g.items[0].when_ == 103, "a repeat should take the newer timestamp, got %d", g.items[0].when_)

		// The cap evicts the oldest unpinned entry and never a pinned one.
		clear(&g.items)
		for i in 0 ..< HISTORY_CAP + 20 {
			push(mk(fmt.tprintf("entry %d", i), i64(i)))
		}
		ok(len(g.items) == HISTORY_CAP, "the cap should hold at %d, got %d", HISTORY_CAP, len(g.items))
		ok(g.items[0].text == fmt.tprintf("entry %d", HISTORY_CAP + 19), "the newest entry survived")

		g.items[len(g.items) - 1].pinned = true
		pinned_text := strings.clone(g.items[len(g.items) - 1].text, context.temp_allocator)
		for i in 0 ..< 10 {
			push(mk(fmt.tprintf("later %d", i), i64(1000 + i)))
		}
		still := false
		for e in g.items {
			if e.text == pinned_text {still = true}
		}
		ok(still, "a pinned entry must survive the cap; %q was evicted", pinned_text)
		ok(len(g.items) == HISTORY_CAP, "the cap still holds at %d, got %d", HISTORY_CAP, len(g.items))
		reap_locked()
	}

	// ---------------------------------------------------------------------
	fmt.println("-- persistence, in a scratch HOME")
	{
		tmp := SCRATCH_HOME
		clear(&g.items)
		ensure_dirs()
		push(mk("a line with\ttab and\nnewline", 500))
		push(mk("plain", 501))
		g.items[1].pinned = true
		save_locked()

		dir := data_dir()
		ok(strings.has_prefix(dir, tmp), "the scratch HOME should redirect the data directory, got %s", dir)

		hist := fmt.tprintf("%s/history", dir)
		ok(os.exists(hist), "the history file should exist at %s", hist)
		if st, err := os.stat(hist, context.temp_allocator); err == nil {
			mode := transmute(u32)st.mode & 0o777
			ok(mode == 0o600, "the history file should be mode 0600, found 0%o", mode)
		} else {
			ok(false, "could not stat the history file")
		}
		if st, err := os.stat(dir, context.temp_allocator); err == nil {
			mode := transmute(u32)st.mode & 0o777
			ok(mode == 0o700, "the data directory should be mode 0700, found 0%o", mode)
		} else {
			ok(false, "could not stat the data directory")
		}

		// Reading it back gives the same entries, newlines and tabs intact.
		saved := len(g.items)
		for i := len(g.items) - 1; i >= 0; i -= 1 {
			drop_entry(i)
		}
		reap_locked()
		ok(len(g.items) == 0, "the store should be empty before the reload")
		load()
		ok(len(g.items) == saved, "the reload gave %d entries, expected %d", len(g.items), saved)
		if len(g.items) == 2 {
			ok(g.items[0].text == "plain", "order should survive the round trip, got %q", g.items[0].text)
			ok(g.items[1].pinned, "the pin should survive the round trip")
			ok(!g.items[0].pinned, "an unpinned entry should come back unpinned")
			ok(
				g.items[1].text == "a line with\ttab and\nnewline",
				"tabs and newlines should survive the round trip, got %q",
				g.items[1].text,
			)
		}
	}

	// ---------------------------------------------------------------------
	fmt.println("-- the window, driven through handle_keys")
	{
		off := p.offscreen_create(1100, 720, 1, "w-full h-full flex-col bg-background text-foreground")
		defer p.offscreen_destroy(off)
		register_dark_theme()

		clear(&g.items)
		for s in ([?]string {
			"https://odin-lang.org/docs/overview/",
			"SELECT id, name FROM users ORDER BY created_at DESC",
			"/home/alex/Work/palmy/apps/clipboard/store.odin",
			"odin build apps/clipboard -o:speed",
		}) {
			push(mk(s, 600))
		}

		st := St {
			query = make([dynamic]u8),
			hits  = make([dynamic]Ranked),
		}
		frame(off, &st)
		ok(len(st.hits) == 4, "the list should show four entries, got %d", len(st.hits))

		// Typing filters.
		p.type_text(off, "sel")
		frame(off, &st)
		ok(string(st.query[:]) == "sel", "typing did not reach the query: %q", string(st.query[:]))
		ok(len(st.hits) >= 1, "“sel” matched nothing")
		if len(st.hits) >= 1 {
			e := current(&st)
			ok(e != nil && strings.has_prefix(e.preview, "SELECT"), "“sel” should rank the SELECT line first, got %q", e.preview)
		}

		// The case a screenshot could not settle: Ctrl+U clears the query.
		p.press_key(off, 'u', {.Ctrl})
		frame(off, &st)
		ok(len(st.query) == 0, "Ctrl+U left %q in the query", string(st.query[:]))
		ok(len(st.hits) == 4, "clearing the query should restore all four rows, got %d", len(st.hits))

		// Down moves the selection.
		p.press_key(off, p.KEY_DOWN)
		frame(off, &st)
		ok(st.sel == 1, "Down moved the selection to %d, expected 1", st.sel)
		p.press_key(off, p.KEY_UP)
		frame(off, &st)
		ok(st.sel == 0, "Up moved the selection to %d, expected 0", st.sel)

		// The other case: Ctrl+P pins and unpins the selected entry.
		before := current(&st)
		ok(before != nil && !before.pinned, "nothing should be pinned to begin with")
		p.press_key(off, 'p', {.Ctrl})
		frame(off, &st)
		pinned := 0
		for e in g.items {
			if e.pinned {pinned += 1}
		}
		ok(pinned == 1, "Ctrl+P should pin exactly one entry, found %d pinned", pinned)
		p.press_key(off, 'p', {.Ctrl})
		frame(off, &st)
		pinned = 0
		for e in g.items {
			if e.pinned {pinned += 1}
		}
		ok(pinned == 0, "Ctrl+P again should unpin, found %d still pinned", pinned)

		// Enter copies the selection back.
		p.press_key(off, p.KEY_RETURN)
		frame(off, &st)
		// push() puts the newest first, so row 0 is the last thing pushed.
		ok(
			g_test_clip == "odin build apps/clipboard -o:speed",
			"Enter copied %q, expected the selected entry",
			g_test_clip,
		)

		// Tab walks the filters, and Images is empty in this fixture.
		p.press_key(off, p.KEY_TAB)
		frame(off, &st)
		ok(st.filter == .Text, "Tab should move to the Text filter, landed on %v", st.filter)
		p.press_key(off, p.KEY_TAB)
		frame(off, &st)
		ok(st.filter == .Images, "Tab should move to Images, landed on %v", st.filter)
		ok(len(st.hits) == 0, "there are no images in this fixture, but %d rows showed", len(st.hits))
		// Two presses in a single frame must both count — that is what
		// `key_count` is for, and a boolean `key_pressed` would drop one.
		p.press_key(off, p.KEY_TAB)
		p.press_key(off, p.KEY_TAB)
		frame(off, &st)
		ok(st.filter == .All, "two Tabs in one frame should wrap back to All, landed on %v", st.filter)

		// Ctrl+M pauses recording.
		was := g.enabled
		p.press_key(off, 'm', {.Ctrl})
		frame(off, &st)
		ok(g.enabled != was, "Ctrl+M did not toggle monitoring")

		// Delete removes the selected entry.
		n := len(g.items)
		p.press_key(off, p.KEY_DELETE)
		frame(off, &st)
		ok(len(g.items) == n - 1, "Delete removed %d entries, expected 1", n - len(g.items))

		// Ctrl+L asks before clearing, and Escape backs out.
		p.press_key(off, 'l', {.Ctrl})
		frame(off, &st)
		ok(st.confirm, "Ctrl+L should open the confirmation")
		p.press_key(off, p.KEY_ESCAPE)
		frame(off, &st)
		ok(!st.confirm, "Escape should close the confirmation")
		ok(len(g.items) > 0, "Escape must not have cleared anything")

		// Confirming does clear it.
		p.press_key(off, 'l', {.Ctrl})
		frame(off, &st)
		p.press_key(off, p.KEY_RETURN)
		frame(off, &st)
		ok(len(g.items) == 0, "confirming should have cleared the history, %d left", len(g.items))
		ok(!st.confirm, "the confirmation should close once it is acted on")

		// And the empty state renders rather than crashing.
		frame(off, &st)
		bg := p.offscreen_pixel(off, 2, 2)
		different := 0
		for y := 0; y < 720; y += 7 {
			for x := 0; x < 1100; x += 7 {
				if p.offscreen_pixel(off, x, y) != bg {different += 1}
			}
		}
		ok(different > 200, "the empty state drew almost nothing (%d differing samples)", different)
	}

	fmt.printfln("\n%s  %d checks, %d failure(s)", fails == 0 ? "PASS" : "FAILED", checks, fails)
	return fails
}
