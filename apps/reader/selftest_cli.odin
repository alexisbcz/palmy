package main

// The command line, tested the way an agent uses it: this binary run again as
// a child, against a scratch store ($PALMY_READER_HOME) and a scratch audit
// log, with generated books. Every read is checked against the fields it
// declares, and every mutation is checked by reading the store back with the
// window's own procedures — library_load, marks_load, settings_load — because
// "the CLI wrote something" is not the claim; "the window would see it" is.

import "core:fmt"
import "core:os"
import "core:strings"
import kit "kit:."

@(private = "file")
cli_exe :: proc() -> string {
	if p, err := os.get_executable_path(context.temp_allocator); err == nil {
		return p
	}
	return os.args[0]
}

// cli_run runs this binary with the scratch store and hands back stdout and
// the exit code. The display variables are cleared, so a dispatch mistake can
// never open a window and hang the run.
@(private = "file")
cli_run :: proc(home: string, args: ..string) -> (out: string, code: int) {
	line := strings.builder_make(context.temp_allocator)
	strings.write_string(&line, "WAYLAND_DISPLAY= DISPLAY= ")
	strings.write_string(&line, fmt.tprintf("PALMY_READER_HOME=%q PALM_AUDIT=%q ", home, fmt.tprintf("%s.audit.jsonl", home)))
	strings.write_string(&line, fmt.tprintf("%q", cli_exe()))
	for a in args {
		strings.write_string(&line, fmt.tprintf(" %q", a))
	}
	state, sout, _, err := os.process_exec({command = {"sh", "-c", strings.to_string(line)}}, context.temp_allocator)
	if err != nil {
		return "", -1
	}
	return string(sout), state.exit_code
}

@(private = "file")
valid :: proc(t: ^T, out: string, fields: []kit.Field, what: string) {
	problems := kit.cli_validate_output(out, fields, context.temp_allocator)
	ck(t, len(problems) == 0, "%s matches its declared schema%s", what, len(problems) > 0 ? fmt.tprintf(" (%s)", problems[0]) : "")
}

// store_of loads the scratch store the way the window does.
@(private = "file")
store_of :: proc(home: string) -> Library {
	l := Library{dir = strings.clone(home)}
	l.books = make([dynamic]Lib_Entry, 0, 4)
	library_load(&l)
	return l
}

test_cli :: proc(t: ^T, png: []u8) {
	group(t, "cli")
	root := fmt.tprintf("/tmp/palmy-reader-cli-%d", os.get_pid())
	_ = os.remove_all(root)
	_ = os.make_directory_all(root)
	defer os.remove_all(root)
	home := fmt.tprintf("%s/home", root)
	epub := fmt.tprintf("%s/generated.epub", root)
	mobi := fmt.tprintf("%s/generated.mobi", root)
	ck(t, gen_epub_file(epub, fixture_book(png)), "the fixture EPUB is written")
	ck(
		t,
		gen_mobi_file(mobi, {title = "A Generated Mobipocket", author = "M. Fixture", html = MOBI_HTML, compress = true}),
		"the fixture MOBI is written",
	)

	// --- the declaration --------------------------------------------------
	sf := surface()
	ck(t, sf.noun == "reader", "the surface is named reader")
	ck(t, sf.selftest != nil && sf.gui && sf.takes_path, "it has a self-test, a window, and takes a path")
	destructive := 0
	for cmd in sf.commands {
		ck(t, cmd.run != nil, "%s has an implementation", cmd.verb)
		ck(t, cmd.summary != "" && len(cmd.out) > 0 && len(cmd.examples) > 0, "%s has a summary, output and an example", cmd.verb)
		if cmd.effect == .Destructive {
			destructive += 1
		}
		for ex in cmd.examples {
			words := kit.cli_split_example(ex, context.temp_allocator)
			ck(t, len(words) > 0 && words[0] == "reader", "the example %q starts with the binary", ex)
			args := make([dynamic]string, context.temp_allocator)
			for w in words[1:] {
				append(&args, w)
			}
			append(&args, "--parse-only")
			_, code := cli_run(home, ..args[:])
			ck_eq_int(t, code, 0, fmt.tprintf("the example %q parses", ex))
		}
	}
	ck_eq_int(t, destructive, 1, "exactly one command is destructive")
	{
		out, code := cli_run(home, "--schema")
		ck_eq_int(t, code, 0, "--schema exits 0")
		ck(t, strings.contains(out, `"verb": "highlight"`), "and declares the commands")
	}

	// --- reads on an empty store write nothing ----------------------------
	{
		out, code := cli_run(home, "library", "--json")
		ck_eq_int(t, code, 0, "library on an empty store exits 0")
		valid(t, out, LIBRARY_FIELDS, "library")
		ck(t, strings.contains(out, `"count": 0`), "and is empty")
		out2, code2 := cli_run(home, "settings", "--json")
		ck_eq_int(t, code2, 0, "settings exits 0")
		valid(t, out2, SETTINGS_FIELDS, "settings")
		_, code3 := cli_run(home, "position", "nothing", "--json")
		ck_eq_int(t, code3, 3, "a book that is not there is not found")
		ck(t, !os.exists(home), "and no read created the store")
	}

	// --- add, and the window's library sees it ----------------------------
	{
		out, code := cli_run(home, "add", epub, mobi, "--json")
		ck_eq_int(t, code, 0, "add exits 0")
		valid(t, out, ADD_FIELDS, "add")
		l := store_of(home)
		ck_eq_int(t, len(l.books), 2, "the window's store sees both books")
		if len(l.books) == 2 {
			ck_eq_str(t, l.books[0].title, "The Generated Book", "with the title from the OPF")
			ck(t, os.exists(cover_path(&l, l.books[0].id)), "and the cover the library grid draws")
		}
		library_destroy(&l)
		_, again := cli_run(home, "--add", epub)
		ck_eq_int(t, again, 0, "the old --add spelling still works")
		l2 := store_of(home)
		ck_eq_int(t, len(l2.books), 2, "and adding a book twice keeps one entry")
		library_destroy(&l2)
		_, missing := cli_run(home, "add", fmt.tprintf("%s/nope.epub", root))
		ck_eq_int(t, missing, 3, "adding a file that is not there is not found")
	}

	// --- the reads, each against its declaration --------------------------
	{
		out, code := cli_run(home, "info", "The Generated", "--json")
		ck_eq_int(t, code, 0, "info finds a book by a title prefix")
		valid(t, out, INFO_FIELDS, "info")
		ck(t, strings.contains(out, `"chapters": 4`), "and reports its chapters")
		out2, code2 := cli_run(home, "text", "generated.epub", "--chapter", "1", "--json")
		ck_eq_int(t, code2, 0, "text exits 0")
		valid(t, out2, TEXT_FIELDS, "text")
		ck(t, strings.contains(out2, "BETA-TWO") && !strings.contains(out2, "ALPHA-ONE"), "and is that chapter's text and only it")
		_, bad := cli_run(home, "text", "generated.epub", "--chapter", "99")
		ck_eq_int(t, bad, 3, "a chapter that does not exist is not found")
		out3, code3 := cli_run(home, "search", "generated.epub", "ALPHA-ONE", "--json")
		ck_eq_int(t, code3, 0, "search exits 0")
		valid(t, out3, SEARCH_FIELDS, "search")
		ck(t, strings.contains(out3, `"count": 1`), "and finds the marker exactly once")
		out4, code4 := cli_run(home, "info", epub, "--json")
		ck_eq_int(t, code4, 0, "info takes a file path too")
		ck(t, strings.contains(out4, `"in_library": true`), "and knows it is in the library")
		out5, code5 := cli_run(home, "library", "--json")
		ck_eq_int(t, code5, 0, "library exits 0")
		valid(t, out5, LIBRARY_FIELDS, "library")
	}

	// --- position: seek, and the window resumes there ---------------------
	{
		out, code := cli_run(home, "seek", "generated.epub", "--chapter", "2", "--json")
		ck_eq_int(t, code, 0, "seek exits 0")
		valid(t, out, POSITION_FIELDS, "seek")
		l := store_of(home)
		i := resolve_entry(&l, "generated.epub")
		ck(t, i >= 0, "the book resolves in the window's store")
		if i >= 0 {
			ck_eq_int(t, l.books[i].chapter, 2, "the window would open it at chapter 2")
			ck(t, l.books[i].frac > 0.5 && l.books[i].frac < 1, "with the progress bar past half way (%.3f)", l.books[i].frac)
		}
		library_destroy(&l)
		out2, code2 := cli_run(home, "position", "generated.epub", "--json")
		ck_eq_int(t, code2, 0, "position exits 0")
		valid(t, out2, POSITION_FIELDS, "position")
		ck(t, strings.contains(out2, `"chapter": 2`), "and reports the chapter seek set")
		_, half := cli_run(home, "seek", "generated.epub", "--percent", "50")
		ck_eq_int(t, half, 0, "seek by percentage exits 0")
		l2 := store_of(home)
		if j := resolve_entry(&l2, "generated.epub"); j >= 0 {
			ck(t, abs(l2.books[j].frac - 0.5) < 0.05, "and lands half way through (%.3f)", l2.books[j].frac)
		}
		library_destroy(&l2)
		_, none := cli_run(home, "seek", "generated.epub")
		ck_eq_int(t, none, 2, "seek with nowhere to go is a usage error")
	}

	// --- marks: idempotent bookmark, highlight, through the window's store -
	{
		marks_of :: proc(home: string) -> (bookmarks, highlights: int, text: string) {
			l := store_of(home)
			defer library_destroy(&l)
			i := resolve_entry(&l, "generated.epub")
			if i < 0 {
				return
			}
			marks_load(&l, i)
			for m in l.books[i].marks {
				if m.kind == .Bookmark {
					bookmarks += 1
				} else {
					highlights += 1
					text = strings.clone(m.text, context.temp_allocator)
				}
			}
			return
		}
		out, code := cli_run(home, "bookmark", "generated.epub", "--json")
		ck_eq_int(t, code, 0, "bookmark exits 0")
		valid(t, out, MARK_FIELDS, "bookmark")
		out2, _ := cli_run(home, "bookmark", "generated.epub", "--json")
		ck(t, strings.contains(out2, `"changed": false`), "bookmarking the same place again changes nothing")
		bm, _, _ := marks_of(home)
		ck_eq_int(t, bm, 1, "and the window's marks hold exactly one bookmark")
		hl_out, hl_code := cli_run(home, "highlight", "generated.epub", "--text", "BETA-TWO", "--json")
		ck_eq_int(t, hl_code, 0, "highlight exits 0")
		valid(t, hl_out, MARK_FIELDS, "highlight")
		_, hl, txt := marks_of(home)
		ck_eq_int(t, hl, 1, "the window's marks hold the highlight")
		ck_eq_str(t, txt, "BETA-TWO", "with the words highlighted")
		mk, mk_code := cli_run(home, "marks", "generated.epub", "--json")
		ck_eq_int(t, mk_code, 0, "marks exits 0")
		valid(t, mk, MARKS_FIELDS, "marks")
		_, _ = cli_run(home, "bookmark", "generated.epub", "--off")
		_, _ = cli_run(home, "highlight", "generated.epub", "--text", "BETA-TWO", "--off")
		bm2, hl2, _ := marks_of(home)
		ck(t, bm2 == 0 && hl2 == 0, "--off removes both (%d bookmarks, %d highlights left)", bm2, hl2)
		_, dry := cli_run(home, "bookmark", "generated.epub", "--dry-run")
		bm3, _, _ := marks_of(home)
		ck(t, dry == 0 && bm3 == 0, "--dry-run writes nothing")
	}

	// --- settings: the window's limits hold -------------------------------
	{
		out, code := cli_run(home, "set", "--theme", "sepia", "--size", "99", "--json")
		ck_eq_int(t, code, 0, "set exits 0")
		valid(t, out, SETTINGS_FIELDS, "set")
		l := store_of(home)
		s := settings_load(&l)
		library_destroy(&l)
		ck(t, s.theme == .Sepia, "the window reads the theme back")
		ck(t, s.size == SET_SIZE_MAX, "and the size is held to the window's own limit (%.0f)", s.size)
		_, bad := cli_run(home, "set", "--theme", "purple")
		ck_eq_int(t, bad, 2, "a theme that does not exist is a usage error")
	}

	// --- remove: refused without --yes; the file survives -----------------
	{
		_, refused := cli_run(home, "remove", "generated.mobi")
		ck_eq_int(t, refused, 4, "remove without --yes is refused")
		l := store_of(home)
		ck_eq_int(t, len(l.books), 2, "and nothing was removed")
		library_destroy(&l)
		out, code := cli_run(home, "remove", "generated.mobi", "--yes", "--json")
		ck_eq_int(t, code, 0, "remove --yes exits 0")
		valid(t, out, REMOVE_FIELDS, "remove")
		l2 := store_of(home)
		ck_eq_int(t, len(l2.books), 1, "the window's library has one book left")
		library_destroy(&l2)
		ck(t, os.exists(mobi), "and the book file itself is untouched")
	}

	// --- the audit log records mutations, not reads -----------------------
	{
		data, err := read_file(fmt.tprintf("%s.audit.jsonl", home), context.temp_allocator)
		text := string(data)
		ck(t, err == "" && strings.contains(text, `"verb":"seek"`), "a mutation leaves an audit record")
		ck(t, !strings.contains(text, `"verb":"library"`), "and a read does not")
	}
	_ = os.remove(fmt.tprintf("%s.audit.jsonl", home))
}
