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
import "core:slice"
import "core:strings"
import "core:time"
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


// ---------------------------------------------------------------------------
// A fake compositor, for the poll-race reproduction
//
// It is one slot, because that is what a clipboard is: `fake_offer` does not
// append, it OVERWRITES. That single line is the whole bug — the thing the
// poll missed was gone before the poll ran.
//
// `fake.watching` turns on the event stream that `wl-paste --watch` produces
// in the real application: one spool record per selection, carrying that
// selection's own bytes, written at the moment of the handover rather than
// read back afterwards.
// ---------------------------------------------------------------------------

@(private = "file")
Fake_Clip :: struct {
	types:    string,
	payload:  []u8,
	offers:   int,
	watching: bool,
}

@(private = "file")
fake: Fake_Clip

@(private = "file")
fake_list_types :: proc() -> (string, bool) {
	if fake.offers == 0 {
		return "", false
	}
	return fake.types, true
}

@(private = "file")
fake_read :: proc(mime: string) -> ([]u8, bool) {
	if fake.offers == 0 {
		return nil, false
	}
	// The caller owns what it is handed, exactly as `exec_raw` hands it over.
	return slice.clone(fake.payload), true
}

@(private = "file")
fake_offer :: proc(seq: int, types: string, text: string) {
	fake.types = types
	fake.payload = transmute([]u8)text
	fake.offers += 1
	if fake.watching {
		// `%019d` because the real stamps are nanosecond counts of fixed
		// width, and `spool_drain` sorts them as strings.
		spool_write(fmt.tprintf("%019d", seq), types, transmute([]u8)text)
	}
}

@(private = "file")
race_reset :: proc() {
	clear(&g.items)
	reap_locked()
	g.last_id = 0
	g.last_secret_id = 0
	watching := fake.watching
	fake = {}
	fake.watching = watching
	fake.watching = false
	spool_clear()
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
	// THE POLL RACE
	//
	// TODO.md records this as "the 0.7 s poll races a fast selection handover
	// and misses entries; measured, not theoretical". This is the
	// reproduction, and it is in three parts:
	//
	//   1. the handover, sampled — two selections inside one interval, and
	//      only the second survives;
	//   2. the same handover, event-driven — both survive;
	//   3. the same thing against the real clock, so "measured" means
	//      measured: selections offered every 150 ms for two seconds, sampled
	//      at 0.7 s, and then the identical run drained from the spool.
	//
	// Nothing here goes near the real clipboard. `g_source` is swapped for a
	// fake compositor — one slot, which is what a clipboard is — and the
	// spool is written by this file rather than by `wl-paste --watch`, in
	// exactly the format that child writes. The watcher thread is never
	// started, so no `wl-paste` process is ever spawned by the self-test and
	// the user's own selection is never read.
	// ---------------------------------------------------------------------
	fmt.println("-- the poll race: a fast selection handover, sampled and evented")
	{
		TXT :: "text/plain;charset=utf-8"
		saved_source := g_source
		g_source = Sel_Source {
			list_types = fake_list_types,
			read       = fake_read,
		}
		defer g_source = saved_source
		defer fake = {}

		sp := spool_dir(context.temp_allocator)
		ok(
			strings.has_prefix(sp, SCRATCH_HOME),
			"the spool must live under the scratch HOME, not the real one; it is %s",
			sp,
		)

		// --- 1. the race, reproduced ----------------------------------
		race_reset()
		fake_offer(1, TXT, "the first thing copied")
		fake_offer(2, TXT, "the second thing copied") // a quarter of a second later
		ok(fake.offers == 2, "the fixture offered two selections, not %d", fake.offers)
		r := sample_once()
		ok(r == .Stored, "the sample stored something, got %v", r)
		ok(len(g.items) == 1, "one sample of two selections can only yield one entry, got %d", len(g.items))
		ok(
			len(g.items) == 1 && g.items[0].text == "the second thing copied",
			"the sample sees whatever is on the clipboard NOW",
		)
		missed := true
		for e in g.items {
			if e.text == "the first thing copied" {missed = false}
		}
		ok(
			missed,
			"THE RACE: a selection replaced before the next 0.7s sample never reaches this process at all",
		)

		// --- 2. the same handover, event-driven -----------------------
		race_reset()
		fake.watching = true
		fake_offer(1, TXT, "the first thing copied")
		fake_offer(2, TXT, "the second thing copied")
		stored, seen := spool_drain()
		ok(seen == 2, "the spool held one record per selection, got %d", seen)
		ok(stored == 2, "both records were stored, got %d", stored)
		ok(len(g.items) == 2, "BOTH selections are in the history, got %d", len(g.items))
		ok(
			len(g.items) == 2 && g.items[0].text == "the second thing copied",
			"newest first",
		)
		ok(
			len(g.items) == 2 && g.items[1].text == "the first thing copied",
			"THE FIX: the selection the poll missed is here, with its own bytes",
		)
		{
			infos, derr := os.read_directory_by_path(sp, -1, context.temp_allocator)
			left := 0
			if derr == nil {
				for info in infos {
					if info.type == .Regular {left += 1}
				}
			}
			ok(left == 0, "a drained spool is empty, %d file(s) left", left)
		}

		// A burst keeps its order, and the order is the order of the
		// selections, not of the directory.
		race_reset()
		fake.watching = true
		for i in 1 ..= 6 {
			fake_offer(i, TXT, fmt.tprintf("burst %d", i))
		}
		bstored, bseen := spool_drain()
		ok(bseen == 6, "six selections, six records, got %d", bseen)
		ok(bstored == 6, "six stored, got %d", bstored)
		order_ok := len(g.items) == 6
		for i in 0 ..< min(len(g.items), 6) {
			if g.items[i].text != fmt.tprintf("burst %d", 6 - i) {order_ok = false}
		}
		ok(order_ok, "a burst comes back newest-first in the order it was copied")

		// A record whose payload has not been renamed into place yet is not
		// half-ingested: the rename is the commit.
		race_reset()
		{
			d := spool_ensure()
			_ = os.write_entire_file(
				fmt.tprintf("%s/0000000000000000009.types", d),
				transmute([]u8)string(TXT),
				os.perm_number(0o600),
			)
			_ = os.write_entire_file(
				fmt.tprintf("%s/0000000000000000009.part", d),
				transmute([]u8)string("half written"),
				os.perm_number(0o600),
			)
			ps, pseen := spool_drain()
			ok(ps == 0 && pseen == 0, "an uncommitted record is not ingested, got %d/%d", ps, pseen)
			ok(len(g.items) == 0, "...and nothing reached the history, got %d", len(g.items))
			spool_clear()
		}

		// The sensitivity gate applies on the event path too. This is the
		// one that matters: an event-driven capture that forgot it would
		// record passwords faster than the poll ever did.
		race_reset()
		fake.watching = true
		fake_offer(1, "text/plain\nx-kde-passwordmanagerhint", "hunter2-synthetic")
		fake_offer(2, TXT, "an ordinary line")
		before := g.secrets
		sstored, _ := spool_drain()
		ok(sstored == 1, "only the non-secret selection is stored, got %d", sstored)
		ok(len(g.items) == 1, "one entry, got %d", len(g.items))
		ok(
			len(g.items) == 1 && g.items[0].text == "an ordinary line",
			"and it is not the flagged one",
		)
		leaked := false
		for e in g.items {
			if strings.contains(e.text, "hunter2") {leaked = true}
		}
		ok(!leaked, "a selection flagged as a secret is never stored, however it arrived")
		ok(g.secrets > before, "...and it is counted as skipped")

		// The spool is written 0600. It holds real clipboard content for as
		// long as it takes the thread to notice it.
		race_reset()
		fake.watching = true
		fake_offer(1, TXT, "mode check")
		{
			d := spool_dir(context.temp_allocator)
			st, serr := os.stat(fmt.tprintf("%s/%019d.blob", d, 1), context.temp_allocator)
			ok(serr == nil, "the spool record exists")
			if serr == nil {
				ok(
					u32(transmute(u32)st.mode) & 0o077 == 0,
					"a spool record must not be group or world readable, mode is %o",
					u32(transmute(u32)st.mode) & 0o777,
				)
			}
			spool_drain()
		}

		// A secret's hash no longer aliases a content hash. Before this,
		// `is_sensitive` wrote fnv(types) into the same field `store_text`
		// compares payloads against.
		race_reset()
		g.last_id = fnv(transmute([]u8)string("some payload"))
		ingest_selection("text/plain\nsecret", nil)
		ok(
			g.last_id == fnv(transmute([]u8)string("some payload")),
			"a secret selection must not overwrite the content hash",
		)

		// --- 3. the same race against the real clock ------------------
		race_reset()
		{
			OFFER_EVERY :: 0.15
			RUN_FOR :: 2.1
			t0 := time.now()
			el :: proc(t0: time.Time) -> f64 {
				return time.duration_seconds(time.since(t0))
			}
			next_offer := 0.0
			next_sample := POLL_SECONDS
			n := 0
			for el(t0) < RUN_FOR {
				if el(t0) >= next_offer {
					n += 1
					fake_offer(n, TXT, fmt.tprintf("timed %d", n))
					next_offer += OFFER_EVERY
				}
				if el(t0) >= next_sample {
					sample_once()
					next_sample += POLL_SECONDS
				}
				time.sleep(5 * time.Millisecond)
			}
			sampled := len(g.items)
			fmt.printfln(
				"   measured: %d selections in %.1fs, sampled every %.1fs — %d reached the history, %d were missed",
				n,
				RUN_FOR,
				POLL_SECONDS,
				sampled,
				n - sampled,
			)
			ok(n >= 10, "the fixture offered at least ten selections, got %d", n)
			ok(
				sampled < n,
				"MEASURED: sampling at %.1fs missed %d of %d selections",
				POLL_SECONDS,
				n - sampled,
				n,
			)
			ok(
				sampled <= 5,
				"sampling %.1fs of selections every %.1fs cannot see more than a handful; it saw %d",
				RUN_FOR,
				POLL_SECONDS,
				sampled,
			)

			// The identical run, event-driven.
			race_reset()
			fake.watching = true
			t1 := time.now()
			next_offer2 := 0.0
			next_drain := SPOOL_POLL_SECONDS
			n2 := 0
			for el(t1) < RUN_FOR {
				if el(t1) >= next_offer2 {
					n2 += 1
					fake_offer(n2, TXT, fmt.tprintf("timed %d", n2))
					next_offer2 += OFFER_EVERY
				}
				if el(t1) >= next_drain {
					spool_drain()
					next_drain += SPOOL_POLL_SECONDS
				}
				time.sleep(5 * time.Millisecond)
			}
			spool_drain()
			evented := len(g.items)
			fmt.printfln(
				"   measured: %d selections in %.1fs, event-driven — %d reached the history, %d were missed",
				n2,
				RUN_FOR,
				evented,
				n2 - evented,
			)
			ok(n2 >= 10, "the second run offered at least ten selections, got %d", n2)
			ok(
				evented == n2,
				"THE FIX, MEASURED: every one of %d selections reached the history; %d did",
				n2,
				evented,
			)
			ok(
				evented > sampled,
				"the event-driven run kept %d where sampling kept %d",
				evented,
				sampled,
			)
		}
		race_reset()
		spool_clear()
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
