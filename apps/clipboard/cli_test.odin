package main

// `clipboard --selftest`, part two: the offer path and the command line.
//
// The offer path is driven through palmy's offscreen clipboard
// (`offscreen_clipboard_offer`), which feeds the same queue a compositor's
// data-control offers do, so `drain_offers` and `ingest_offer` here are the
// code the window runs — no spool, no wl-paste, no compositor, and no real
// clipboard anywhere near it.
//
// The command line is run as a child process against a scratch history
// ($PALMY_CLIPBOARD_DIR), with the display variables cleared and the audit log
// redirected, because `clipboard delete` is only honestly testable against a
// file it may really change.

import "core:fmt"
import "core:os"
import "core:strings"
import kit "kit:."
import p "palmy:."

@(private = "file")
TXT :: "text/plain;charset=utf-8"
@(private = "file")
HINT :: "x-kde-passwordManagerHint"

@(private = "file")
reset_store :: proc() {
	for i := len(g.items) - 1; i >= 0; i -= 1 {
		drop_entry(i)
	}
	reap_locked()
	g.last_id = 0
	g.last_secret_id = 0
}

@(private = "file")
history_holds :: proc(needle: string) -> bool {
	for &e in g.items {
		if strings.contains(e.text, needle) || strings.contains(e.preview, needle) {
			return true
		}
	}
	raw, err := os.read_entire_file_from_path(fmt.tprintf("%s/history", data_dir()), context.temp_allocator)
	return err == nil && strings.contains(string(raw), needle)
}

test_offers :: proc() {
	fmt.println("-- the offer path: palmy's offers, decided and read one at a time")
	off := p.offscreen_create(64, 64)
	defer p.offscreen_destroy(off)
	ui := p.offscreen_begin(off)
	defer p.offscreen_end(off)

	tcheck(p.clipboard_watch(ui) == .Always, "an offscreen frame watches with every change")
	defer p.clipboard_watch(ui, {})
	reset_store()
	g.enabled = true

	// A password manager's copy (text plus the hint), an ordinary copy, and
	// what `wl-copy --type x-kde-passwordManagerHint` offers (the hint alone),
	// all before one frame drains them.
	secrets_before := g.secrets
	tcheck(p.offscreen_clipboard_offer(.Clipboard, {TXT, HINT}, {"hunter2-synthetic", "secret"}), "offer one queued")
	tcheck(p.offscreen_clipboard_offer(.Clipboard, {TXT, "text/plain"}, {"an ordinary line", "an ordinary line"}), "offer two queued")
	tcheck(p.offscreen_clipboard_offer(.Clipboard, {HINT}, {"hunter3-synthetic"}), "offer three queued")
	reads := g_offer_reads
	stored, seen := drain_offers(ui)
	tcheck(seen == 3, "three offers were handed out, got %d", seen)
	tcheck(stored == 1, "one was stored, got %d", stored)
	tcheck(g_offer_reads - reads == 1, "ONE read was made, for the ordinary copy; the two flagged offers were never read (%d reads)", g_offer_reads - reads)
	tcheck(len(g.items) == 1 && g.items[0].text == "an ordinary line", "the history holds the ordinary copy and nothing else")
	tcheck(!history_holds("hunter"), "no flagged payload reached memory or the history file")
	tcheck(g.secrets - secrets_before == 2, "both flagged offers were counted as skipped, got %d", g.secrets - secrets_before)

	// The burst the poll used to lose: six copies between two frames are six
	// offers, and six entries, in the order they were made.
	reset_store()
	for i in 1 ..= 6 {
		p.offscreen_clipboard_offer(.Clipboard, {TXT}, {fmt.tprintf("burst %d", i)})
	}
	stored, seen = drain_offers(ui)
	tcheck(seen == 6 && stored == 6, "six copies between two frames: %d offers, %d stored", seen, stored)
	order := len(g.items) == 6
	for i in 0 ..< min(len(g.items), 6) {
		if g.items[i].text != fmt.tprintf("burst %d", 6 - i) {order = false}
	}
	tcheck(order, "newest first, in the order they were copied")

	// A read is of the offer just handed out and of nothing else: an offer
	// that has been let go of is refused rather than answered with whatever
	// the clipboard holds now. This is the seam the wl-paste path could not
	// close — its verdict and its bytes came from two different questions.
	reset_store()
	p.offscreen_clipboard_offer(.Clipboard, {TXT}, {"the older copy"})
	p.offscreen_clipboard_offer(.Clipboard, {TXT}, {"the newer copy"})
	a, _ := p.clipboard_next_offer(ui)
	b, _ := p.clipboard_next_offer(ui)
	tcheck(ingest_offer(ui, a) == .Failed, "an offer that is no longer held cannot be read")
	tcheck(len(g.items) == 0, "...and nothing was stored under its name")
	tcheck(ingest_offer(ui, b) == .Stored && g.items[0].text == "the newer copy", "the held one reads its own bytes")

	// The bytes come back untouched: leading whitespace, tabs, no newline
	// added or taken away.
	reset_store()
	code := "\tif x {\n\t\treturn\n\t}\n"
	p.offscreen_clipboard_offer(.Clipboard, {TXT}, {code})
	drain_offers(ui)
	tcheck(len(g.items) == 1 && g.items[0].text == code, "a code block is stored byte for byte")

	// An image wins over its text wrapper, and is read as an image.
	reset_store()
	{
		png_path := fmt.tprintf("%s/offer.png", SCRATCH_HOME)
		rgba := make([]u8, 8 * 6 * 4, context.temp_allocator)
		for i in 0 ..< len(rgba) {
			rgba[i] = u8(i * 7)
		}
		p.write_png_rgba(png_path, rgba, 8, 6)
		png, _ := os.read_entire_file_from_path(png_path, context.temp_allocator)
		p.offscreen_clipboard_offer(.Clipboard, {"text/html", "image/png"}, {"<img src=x>", string(png)})
		drain_offers(ui)
		tcheck(len(g.items) == 1 && g.items[0].kind == .Image && g.items[0].w == 8 && g.items[0].h == 6, "an image offer is stored as an 8x6 image")
		if len(g.items) == 1 {
			st, err := os.stat(g.items[0].blob, context.temp_allocator)
			tcheck(err == nil && transmute(u32)st.mode & 0o077 == 0, "its blob is private to the user")
		}
	}

	// Paused records nothing and reads nothing, but still lets the offers go.
	reset_store()
	g.enabled = false
	p.offscreen_clipboard_offer(.Clipboard, {TXT}, {"copied while paused"})
	reads = g_offer_reads
	stored, seen = drain_offers(ui)
	tcheck(seen == 1 && stored == 0 && g_offer_reads == reads, "paused: the offer is let go of, unread (%d seen, %d stored)", seen, stored)
	_, left := p.clipboard_next_offer(ui)
	tcheck(!left, "and nothing is left queued")
	g.enabled = true

	// A cleared selection is an offer with no types: nothing to store.
	p.offscreen_clipboard_offer(.Clipboard, nil, nil)
	stored, seen = drain_offers(ui)
	tcheck(seen == 1 && stored == 0, "a cleared selection stores nothing")
	reset_store()
}

// ---------------------------------------------------------------------------
// The command line
// ---------------------------------------------------------------------------

@(private = "file")
self_exe :: proc() -> string {
	if path, err := os.get_executable_path(context.temp_allocator); err == nil {
		return path
	}
	return os.args[0]
}

@(private = "file")
g_cli_dir: string

@(private = "file")
run :: proc(args: ..string) -> (out: string, code: int) {
	line := strings.builder_make(context.temp_allocator)
	strings.write_string(
		&line,
		fmt.tprintf(
			"WAYLAND_DISPLAY= DISPLAY= HOME=%q PALMY_CLIPBOARD_DIR=%q PALM_AUDIT=%q %q",
			SCRATCH_HOME,
			g_cli_dir,
			fmt.tprintf("%s/audit.jsonl", SCRATCH_HOME),
			self_exe(),
		),
	)
	for a in args {
		strings.write_string(&line, fmt.tprintf(" %q", a))
	}
	state, sout, serr, err := os.process_exec({command = {"sh", "-c", strings.to_string(line)}}, context.temp_allocator)
	if err != nil {
		return "", -1
	}
	// A secret must not reach stderr either: everything the child said is
	// checked, so both streams are handed back together.
	return strings.concatenate({string(sout), string(serr)}, context.temp_allocator), state.exit_code
}

// id_of pulls the first `"id": "..."` out of a JSON answer.
@(private = "file")
id_of :: proc(out: string) -> string {
	k := `"id": "`
	i := strings.index(out, k)
	if i < 0 {
		return ""
	}
	rest := out[i + len(k):]
	j := strings.index_byte(rest, '"')
	return j < 0 ? "" : rest[:j]
}

test_cli :: proc() {
	fmt.println("-- the command line, against a scratch history")
	g_cli_dir = fmt.aprintf("%s/cli-history", SCRATCH_HOME)
	_ = os.remove_all(g_cli_dir)

	sf := surface()
	destructive := 0
	for cmd in sf.commands {
		tcheck(cmd.run != nil && cmd.summary != "" && len(cmd.out) > 0 && len(cmd.examples) > 0, "%s is declared in full", cmd.verb)
		if cmd.effect == .Destructive {
			destructive += 1
			tcheck(strings.contains(cmd.examples[0], "--yes"), "%s's first example passes --yes", cmd.verb)
		}
		for ex in cmd.examples {
			words := kit.cli_split_example(ex, context.temp_allocator)
			args := make([dynamic]string, context.temp_allocator)
			for w in words[1:] {
				append(&args, w)
			}
			append(&args, "--parse-only")
			_, code := run(..args[:])
			tcheck(words[0] == "clipboard" && code == 0, "the example %q parses (exit %d)", ex, code)
		}
	}
	tcheck(destructive == 2, "delete and clear are the destructive ones, found %d", destructive)

	{
		out, code := run("list", "--json")
		tcheck(code == 0 && len(kit.cli_validate_output(out, LIST_FIELDS, context.temp_allocator)) == 0, "list on no history matches its schema")
		tcheck(strings.contains(out, `"total": 0`), "and is empty, not an error")
		sout, scode := run("status", "--json")
		tcheck(scode == 0 && len(kit.cli_validate_output(sout, STATUS_FIELDS, context.temp_allocator)) == 0, "status matches its schema")
		tcheck(strings.contains(sout, g_cli_dir), "and names the scratch directory, not the real one")
	}

	// Recording, through the watcher's own gate.
	a_out, a_code := run("add", "SELECT id, name FROM users", "--json")
	run("add", "odin build apps/clipboard -o:speed", "--json")
	c_out, _ := run("add", "line one\\n\\tindented", "--json")
	tcheck(a_code == 0 && len(kit.cli_validate_output(a_out, ADD_FIELDS, context.temp_allocator)) == 0, "add matches its schema")
	sel_id := id_of(a_out)
	tab_id := id_of(c_out)
	{
		out, _ := run("list", "--json")
		tcheck(strings.contains(out, `"total": 3`), "three entries after three adds")
		first := strings.index(out, "line one")
		last := strings.index(out, "SELECT")
		tcheck(first >= 0 && last > first, "newest first")
		dup, _ := run("add", "odin build apps/clipboard -o:speed", "--json")
		tcheck(strings.contains(dup, `"outcome": "stored"`), "a repeat is folded back to the top")
		out2, _ := run("list", "--json")
		tcheck(strings.contains(out2, `"total": 3`) && strings.index(out2, "odin build") < strings.index(out2, "line one"), "...not added twice")
		show, scode := run("show", tab_id[:6], "--json")
		tcheck(scode == 0 && strings.contains(show, `"text": "line one\n\tindented"`), "show prints the whole text, tab and newline intact")
		tcheck(len(kit.cli_validate_output(show, SHOW_FIELDS, context.temp_allocator)) == 0, "show matches its schema")
	}

	// The search is the window's.
	{
		out, code := run("search", "sel", "--json")
		tcheck(code == 0 && len(kit.cli_validate_output(out, SEARCH_FIELDS, context.temp_allocator)) == 0, "search matches its schema")
		tcheck(id_of(out) == sel_id, "“sel” finds the SELECT line first")
		_ = os.set_env("PALMY_CLIPBOARD_DIR", g_cli_dir)
		load(false)
		hits := make([dynamic]Ranked, context.temp_allocator)
		rank_locked(&hits, "sel", .All)
		tcheck(len(hits) > 0 && entry_ref(&g.items[hits[0].idx]) == sel_id, "and so does the window's ranking, in-process")
		_ = os.unset_env("PALMY_CLIPBOARD_DIR")
		reset_store()
	}

	// Pins.
	{
		out, code := run("pin", sel_id[:8], "--json")
		tcheck(code == 0 && strings.contains(out, `"changed": true`), "pin pins")
		again, _ := run("pin", sel_id[:8], "--json")
		tcheck(strings.contains(again, `"changed": false`), "and is idempotent")
		list, _ := run("list", "--json")
		tcheck(id_of(list) == sel_id, "a pinned entry lists first")
		pinned, _ := run("list", "--filter", "pinned", "--json")
		tcheck(strings.contains(pinned, `"count": 1`), "the pinned filter shows it alone")
		_, short := run("pin", "ab", "--json")
		tcheck(short == kit.EXIT_NOT_FOUND, "a prefix under four digits names nothing (exit %d)", short)
	}

	// THE SENSITIVITY GATE. An entry recorded under a password-manager type is
	// planted in the history file the way an older version, or a hand edit,
	// could have left it. No command may print a byte of it.
	PLANT :: "hunter2-synthetic-plant"
	secret_id: string
	{
		path := fmt.tprintf("%s/history", g_cli_dir)
		raw, _ := os.read_entire_file_from_path(path, context.temp_allocator)
		planted := fmt.tprintf("%s%s\t%d\t0\t%s\t%d\t%s\n", string(raw), "T", now_unix(), "x-kde-passwordmanagerhint", len(PLANT), PLANT)
		_ = os.write_entire_file(path, transmute([]u8)planted, os.perm_number(0o600))
		secret_id = fmt.tprintf("%016x", fnv(transmute([]u8)string(PLANT)))

		for args in ([][]string {
				{"list"},
				{"list", "--json"},
				{"list", "--filter", "text", "--json", "--limit", "0"},
				{"search", "hunter"},
				{"search", "synthetic", "--json"},
				{"search", "plant", "--json"},
				{"show", secret_id},
				{"show", secret_id, "--json"},
				{"show", secret_id[:6], "--verbose"},
				{"status", "--json"},
				{"copy", secret_id, "--json"},
			}) {
			out, _ := run(..args)
			tcheck(!strings.contains(out, "hunter2"), "`clipboard %s` never prints a secret's text", strings.join(args, " ", context.temp_allocator))
		}
		list, _ := run("list", "--json")
		tcheck(strings.contains(list, secret_id) && strings.contains(list, `"secret": true`), "the secret is listed, so it can be seen to exist and deleted")
		find, _ := run("search", "hunter", "--json")
		tcheck(strings.contains(find, `"count": 0`), "a search never matches a secret's text")
		show, scode := run("show", secret_id, "--json")
		tcheck(scode == 0 && !strings.contains(show, `"text":`), "show gives a secret's metadata and no text field")
		_, ccode := run("copy", secret_id, "--json")
		tcheck(ccode == kit.EXIT_FAILED, "copy refuses a secret (exit %d)", ccode)
		st, _ := run("status", "--json")
		tcheck(strings.contains(st, `"secrets": 1`), "status counts it")

		// And `add` is gated the way a copy is.
		out, acode := run("add", "hunter4-synthetic", "--mime", HINT, "--json")
		tcheck(acode == kit.EXIT_FAILED && strings.contains(out, `"outcome": "secret"`), "add refuses a flagged type (exit %d)", acode)
		raw2, _ := os.read_entire_file_from_path(path, context.temp_allocator)
		tcheck(!strings.contains(string(raw2), "hunter4"), "...and it never reaches the history file")
	}

	// The window reloads what the command line changed, rather than writing
	// its own copy back over it.
	{
		_ = os.set_env("PALMY_CLIPBOARD_DIR", g_cli_dir)
		load(false)
		before := len(g.items)
		tcheck(!history_changed(), "a freshly loaded history is unchanged")
		_, dcode := run("delete", secret_id, "--yes", "--json")
		tcheck(dcode == 0, "delete --yes removes the secret")
		tcheck(history_changed(), "the window sees the file move under it")
		reload_locked()
		reap_locked()
		tcheck(len(g.items) == before - 1, "and reloads to the command line's version (%d entries, was %d)", len(g.items), before)
		gone := true
		for &e in g.items {
			if entry_ref(&e) == secret_id {gone = false}
		}
		tcheck(gone, "the deleted entry is gone from the window too")
		_ = os.unset_env("PALMY_CLIPBOARD_DIR")
		reset_store()
	}

	// Refusal, dry runs, and the things that are not there.
	{
		out, code := run("delete", sel_id, "--json")
		tcheck(code == kit.EXIT_NEEDS_YES && strings.contains(out, "needs --yes"), "delete without --yes is refused (exit %d)", code)
		_, dry := run("delete", sel_id, "--dry-run", "--json")
		list, _ := run("list", "--json")
		tcheck(dry == 0 && strings.contains(list, sel_id), "a dry run deletes nothing")
		_, nf := run("show", "ffffffffffff", "--json")
		tcheck(nf == kit.EXIT_NOT_FOUND, "an unknown id is not found (exit %d)", nf)
		_, unav := run("copy", tab_id, "--json")
		tcheck(unav == kit.EXIT_UNAVAILABLE, "copy with no Wayland session is unavailable (exit %d)", unav)
		_, typo := run("lsit")
		tcheck(typo == kit.EXIT_USAGE, "a mistyped command is a usage error, never a window (exit %d)", typo)
	}
	{
		hist := fmt.tprintf("%s/history", g_cli_dir)
		fi, err := os.stat(hist, context.temp_allocator)
		tcheck(err == nil && transmute(u32)fi.mode & 0o777 == 0o600, "the command line leaves the history file 0600")
		di, derr := os.stat(g_cli_dir, context.temp_allocator)
		tcheck(derr == nil && transmute(u32)di.mode & 0o777 == 0o700, "and its directory 0700")
	}
	{
		out, code := run("clear", "--keep-pinned", "--yes", "--json")
		tcheck(code == 0 && strings.contains(out, `"kept": 1`) && len(kit.cli_validate_output(out, CLEAR_FIELDS, context.temp_allocator)) == 0, "clear --keep-pinned spares the pin")
		list, _ := run("list", "--json")
		tcheck(strings.contains(list, `"total": 1`) && strings.contains(list, sel_id), "and only the pin is left")
		_, all := run("clear", "--yes", "--json")
		list2, _ := run("list", "--json")
		tcheck(all == 0 && strings.contains(list2, `"total": 0`), "clear --yes empties it")
	}
	{
		raw, _ := os.read_entire_file_from_path(fmt.tprintf("%s/audit.jsonl", SCRATCH_HOME), context.temp_allocator)
		log := string(raw)
		tcheck(strings.contains(log, `"verb": "clear"`) && strings.contains(log, `"verb": "pin"`), "the edits are in the audit log")
		tcheck(!strings.contains(log, `"verb": "list"`), "the reads are not")
		tcheck(strings.contains(log, `"verb": "add"`), "add is audited")
		tcheck(!strings.contains(log, "hunter") && !strings.contains(log, "SELECT id"), "but what was added — copied text, a refused secret — is not in the audit log")
	}
	{
		// The kit's private_args, not a scrub of our own, keeps it out: the
		// text sits after a flag with a value and after `--`, where a hand
		// scrub has to know every flag to find it.
		audit := fmt.tprintf("%s/audit.jsonl", SCRATCH_HOME)
		os.remove(audit)
		_, c1 := run("add", "--mime", "text/plain", "correct-horse-7319", "--json")
		_, c2 := run("add", "--identity", "alex", "--json", "--", "-battery-staple-7319")
		_, c4 := run("add", "-free-text-7319", "--json")
		po, c3 := run("add", "--parse-only", "staple-parse-7319", "--json")
		raw, _ := os.read_entire_file_from_path(audit, context.temp_allocator)
		log := string(raw)
		tcheck(c1 == 0 && c2 == 0 && c3 == 0 && c4 == 0, "add after a flag, after --, starting with a dash, and under --parse-only all succeed (%d %d %d %d)", c1, c2, c3, c4)
		tcheck(strings.count(log, `"verb": "add"`) == 3 && strings.contains(log, "<redacted>"), "the three adds are audited, with <redacted> in the text's place")
		tcheck(!strings.contains(po, "7319") && strings.contains(po, "<redacted>"), "--parse-only echoes <redacted> too")
		tcheck(!strings.contains(log, "7319"), "grepping the audit log for the added text finds nothing")
		list, _ := run("list", "--json")
		tcheck(strings.contains(list, "correct-horse-7319") && strings.contains(list, "-battery-staple-7319"), "and the history has the real text, not the placeholder")
		tcheck(strings.contains(list, `"-free-text-7319"`), "a text starting with a dash is free text, not an unknown flag")
		run("clear", "--yes")
	}
}
