package main

// `slides.bin --selftest`, the command-line half.
//
// What these assertions are for is the claim at the top of cli.odin: that the
// command line is the editor's own code reached another way, not a second
// editor that will drift. So most of them do one thing twice — once through
// the real binary, as an agent would, and once in-process through `invoke`,
// as a key press would — and compare the decks byte for byte.
//
// The binary is run as a child with the display variables cleared, so a
// mistake in the dispatcher could never open a window and hang the run, and
// with $PALM_AUDIT in the scratch directory, so the real audit log is never
// written. Every deck lives in a scratch directory under $TMPDIR.

import "core:fmt"
import "core:os"
import "core:strings"
import kit "kit:."
import p "palmy:."

@(private = "file")
self_exe :: proc() -> string {
	if path, err := os.get_executable_path(context.temp_allocator); err == nil {
		return path
	}
	return os.args[0]
}

@(private = "file")
g_cli_dir: string

// run runs this binary with `args` and hands back stdout and the exit code.
@(private = "file")
run :: proc(args: ..string) -> (out: string, code: int) {
	line := strings.builder_make(context.temp_allocator)
	strings.write_string(&line, fmt.tprintf("cd %q && WAYLAND_DISPLAY= DISPLAY= PALM_AUDIT=%q %q", g_cli_dir, fmt.tprintf("%s/audit.jsonl", g_cli_dir), self_exe()))
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
same_file :: proc(a, b: string) -> bool {
	x, e1 := os.read_entire_file_from_path(a, context.temp_allocator)
	y, e2 := os.read_entire_file_from_path(b, context.temp_allocator)
	return e1 == nil && e2 == nil && string(x) == string(y)
}

// twin is the in-process half of a comparison: the built-in deck, put through
// the same steps the keyboard would take, and saved where it can be compared.
@(private = "file")
twin :: proc(name: string) -> (st: ^St, path: string) {
	path = fresh(name)
	st = state_new(exe_directory())
	st.deck, _ = load_deck(path)
	return st, path
}

@(private = "file")
fresh :: proc(name: string) -> string {
	path := fmt.tprintf("%s/%s", g_cli_dir, name)
	d := fixture_deck()
	save_deck(&d, path)
	return path
}

t_cli :: proc(t: ^Checks) {
	tmp := os.get_env("TMPDIR", context.temp_allocator)
	if tmp == "" {
		tmp = "/tmp"
	}
	g_cli_dir = fmt.aprintf("%s/palmy-slides-cli-%d", tmp, os.get_pid())
	_ = os.remove_all(g_cli_dir)
	_ = os.make_directory_all(g_cli_dir)
	defer os.remove_all(g_cli_dir)

	// --- the declaration ---------------------------------------------------
	sf := surface()
	check(t, sf.noun == "slides" && sf.gui && sf.takes_path, "the surface is slides, a window that takes a path")
	destructive := 0
	examples := 0
	for cmd in sf.commands {
		check(t, cmd.run != nil && cmd.summary != "" && len(cmd.out) > 0 && len(cmd.examples) > 0, "%s is declared in full", cmd.verb)
		if cmd.effect == .Destructive {
			destructive += 1
			check(t, strings.contains(cmd.examples[0], "--yes"), "the first example of %s passes --yes", cmd.verb)
		}
		for ex in cmd.examples {
			words := kit.cli_split_example(ex, context.temp_allocator)
			args := make([dynamic]string, context.temp_allocator)
			for w in words[1:] {
				append(&args, w)
			}
			append(&args, "--parse-only")
			_, code := run(..args[:])
			check(t, words[0] == "slides" && code == 0, "the example %q parses (exit %d)", ex, code)
			examples += 1
		}
	}
	check(t, destructive == 1, "exactly one command is destructive, found %d", destructive)
	check(t, examples >= 30, "the surface ships %d examples", examples)
	schema, scode := run("--schema")
	check(t, scode == 0 && strings.contains(schema, `"noun": "slides"`), "--schema answers")

	// --- every read, against the built-in deck, matches what it declared --
	reads := [?]struct {
		args:   []string,
		fields: []kit.Field,
	} {
		{{"info", "--json"}, INFO_FIELDS},
		{{"outline", "--json"}, OUTLINE_FIELDS},
		{{"text", "--json"}, TEXT_FIELDS},
		{{"notes", "--slide", "2", "--json"}, NOTES_FIELDS},
		{{"show", "4", "--json"}, SHOW_FIELDS},
		{{"show", "3", "--json"}, SHOW_FIELDS},
		{{"themes", "--json"}, THEMES_FIELDS},
	}
	for r in reads {
		out, code := run(..r.args)
		problems := kit.cli_validate_output(out, r.fields, context.temp_allocator)
		check(t, code == 0 && len(problems) == 0, "slides %s matches its schema (exit %d%s)", r.args[0], code, len(problems) > 0 ? fmt.tprintf(", %s", problems[0]) : "")
	}
	{
		out, _ := run("info", "--json")
		check(t, strings.contains(out, `"slides": 8`) && strings.contains(out, `"deck": "@fixture"`), "info with no deck reads the built-in deck")
		out2, _ := run("notes", "--slide", "1", "--json")
		d := fixture_deck()
		check(t, strings.contains(out2, "Press Right to begin"), "notes are the deck's own: %q", d.slides[0].notes[:20])
		out3, _ := run("show", "5", "--json")
		check(t, strings.contains(out3, `"src": "assets/vista.png"`), "show lists a picture's source")
	}

	// --- the same edit, through the binary and through invoke ---------------
	{
		a := fresh("dup.json")
		_, code := run("duplicate", a, "3", "--json")
		st, b := twin("dup-twin.json")
		st.slide = 2
		invoke(st, nil, nil, .Slide_Dup)
		save_deck(&st.deck, b)
		check(t, code == 0 && same_file(a, b), "slides duplicate writes the deck Shift D makes")
	}
	{
		a := fresh("move.json")
		_, code := run("move", a, "2", "6", "--json")
		st, b := twin("move-twin.json")
		st.slide = 1
		for _ in 0 ..< 4 {
			invoke(st, nil, nil, .Slide_Down)
		}
		save_deck(&st.deck, b)
		check(t, code == 0 && same_file(a, b), "slides move writes the deck four Shift J make")
		check(t, st.slide == 5, "and the moved slide is at 6")
	}
	{
		a := fresh("layout.json")
		_, code := run("layout", a, "3", "two-content", "--json")
		st, b := twin("layout-twin.json")
		st.slide = 2
		invoke(st, nil, nil, .Layout_Two)
		save_deck(&st.deck, b)
		check(t, code == 0 && same_file(a, b), "slides layout writes the deck pressing 3 makes")
	}
	{
		a := fresh("add.json")
		_, code := run("add", a, "--after", "2", "--layout", "section", "--title", "Part two", "--notes", "Breathe.\\nThen go on.", "--json")
		st, b := twin("add-twin.json")
		st.slide = 1
		invoke(st, nil, nil, .Slide_New)
		invoke(st, nil, nil, .Layout_Section)
		s := cur_slide(st)
		elem_set_text(&s.elems[find_element(s, "title")], "Part two")
		slide_set_notes(s, "Breathe.\nThen go on.")
		save_deck(&st.deck, b)
		check(t, code == 0 && same_file(a, b), "slides add writes the deck M, 4 and typing make")
		back, _ := load_deck(a)
		check(t, len(back.slides) == 9 && back.slides[2].layout == .Section_Header, "the new slide is the third, a section header")
		check(t, back.slides[2].notes == "Breathe.\nThen go on.", "and \\n in an argument is a new line in the notes")
	}
	{
		a := fresh("insert.json")
		_, code := run("insert", a, "6", "ellipse", "--left", "40", "--top", "50", "--width", "200", "--height", "100", "--json")
		st, b := twin("insert-twin.json")
		st.slide = 5
		invoke(st, nil, nil, .Add_Ellipse)
		e := cur_elem(st)
		e.x, e.y, e.w, e.h = 40, 50, 200, 100
		save_deck(&st.deck, b)
		check(t, code == 0 && same_file(a, b), "slides insert writes the deck E and the inspector make")
	}
	{
		a := fresh("text.json")
		_, code := run("set-text", a, "1", "title", "A new title", "--json")
		st, b := twin("text-twin.json")
		elem_set_text(&st.deck.slides[0].elems[0], "A new title")
		save_deck(&st.deck, b)
		check(t, code == 0 && same_file(a, b), "slides set-text commits the way an in-place edit does")
		out, _ := run("outline", a, "--json")
		check(t, strings.contains(out, `"title": "A new title"`), "and outline reads it back")
		_, again := run("set-text", a, "1", "title", "A new title", "--json")
		check(t, again == 0 && same_file(a, b), "set-text is idempotent")
		d := fixture_deck()
		shape_at := 0
		for &e, i in d.slides[5].elems {
			if e.kind != .Text && shape_at == 0 {
				shape_at = i + 1
			}
		}
		_, shape := run("set-text", a, "6", fmt.tprintf("%d", shape_at), "words", "--json")
		check(t, shape == kit.EXIT_USAGE, "a shape has no text to set (exit %d)", shape)
	}
	{
		a := fresh("theme.json")
		_, code := run("theme", a, "terminal", "--json")
		back, _ := load_deck(a)
		check(t, code == 0 && back.theme.name == "Terminal" && back.theme.mono, "slides theme takes a name in any case")
		_, bad := run("theme", a, "Plaid", "--json")
		check(t, bad == kit.EXIT_NOT_FOUND, "an unknown theme is not found (exit %d)", bad)
	}

	// --- styled runs, transitions and import ---------------------------------
	{
		a := fresh("style.json")
		_, code := run("style", a, "1", "title", "--match", "desktop", "--italic", "on", "--color", "accent", "--json")
		st, b := twin("style-twin.json")
		st.slide = 0
		st.sel = 0
		begin_text(st)
		at := strings.index(ed_text(st), "desktop")
		st.ed.anchor, st.ed.caret = at, at + len("desktop")
		invoke(st, nil, nil, .Run_Italic)
		invoke(st, nil, nil, .Run_Colour)
		commit_text(st, cur_elem(st))
		st.mode = .Browse
		save_deck(&st.deck, b)
		check(t, code == 0 && same_file(a, b), "slides style --match writes the deck selecting the word, Ctrl I and Ctrl Shift C make")
		out, _ := run("show", "1", a, "--json")
		check(t, strings.contains(out, `"text": "desktop"`) && strings.contains(out, `"italic": true`) && strings.contains(out, `"color": "accent"`), "and show lists the run")
		_, again := run("style", a, "1", "title", "--match", "desktop", "--italic", "on", "--color", "accent", "--json")
		check(t, again == 0 && same_file(a, b), "style is idempotent")
		_, c2 := run("style", a, "1", "title", "--from", "1", "--to", "7", "--size", "80", "--bold", "on", "--json")
		back, _ := load_deck(a)
		r := back.slides[0].elems[0].runs
		check(t, c2 == 0 && len(r) == 2 && r[0].start == 0 && r[0].end == 7 && r[0].size == 80 && r[0].bold, "--from/--to count characters from 1: %v", r)
		_, c3 := run("style", a, "1", "title", "--plain", "--json")
		back, _ = load_deck(a)
		check(t, c3 == 0 && len(back.slides[0].elems[0].runs) == 0, "--plain over the whole box clears it")
		_, bad := run("style", a, "1", "title", "--match", "nowhere", "--bold", "on", "--json")
		check(t, bad == kit.EXIT_NOT_FOUND, "a --match that is not there is not found (exit %d)", bad)
		_, none := run("style", a, "1", "title", "--json")
		check(t, none == kit.EXIT_USAGE, "a style with nothing to do is a usage error (exit %d)", none)
		_, shape := run("style", a, "6", "2", "--bold", "on", "--json")
		check(t, shape == kit.EXIT_USAGE, "a shape has no text to style (exit %d)", shape)
	}
	{
		a := fresh("trans.json")
		_, code := run("transition", a, "1", "wipe", "--ms", "400", "--json")
		st, b := twin("trans-twin.json")
		st.slide = 0
		for _ in 0 ..< 3 {
			invoke(st, nil, nil, .Transition_Next) // none, fade, push, wipe
		}
		st.deck.slides[0].transition_ms = 400
		save_deck(&st.deck, b)
		check(t, code == 0 && same_file(a, b), "slides transition writes the deck three Shift T make")
		_, all := run("transition", a, "all", "fade", "--json")
		back, _ := load_deck(a)
		every := true
		for s in back.slides {
			every = every && s.transition == .Fade && s.transition_ms == 0
		}
		check(t, all == 0 && every, "transition all sets every slide")
		out, _ := run("show", "2", a, "--json")
		check(t, strings.contains(out, `"transition": "fade"`) && strings.contains(out, `"transition_ms": 600`), "show reports it")
		png := fmt.tprintf("%s/t.png", g_cli_dir)
		_, rc := run("render", a, "2", png, "--width", "320", "--transition", "0.5", "--json")
		check(t, rc == 0 && os.exists(png), "render --transition writes a mid-transition frame")
		_, r1 := run("render", a, "1", png, "--transition", "0.5", "--json")
		check(t, r1 == kit.EXIT_USAGE, "slide 1 has nothing to arrive from (exit %d)", r1)
	}
	{
		pptx := fmt.tprintf("%s/rt.pptx", g_cli_dir)
		deck := fmt.tprintf("%s/rt.json", g_cli_dir)
		run("export", "@fixture", pptx, "--json")
		out, code := run("import", pptx, deck, "--json")
		back, err := load_deck(deck)
		check(t, code == 0 && err == "" && len(back.slides) == 8, "slides import reads the exported deck back: %s", out)
		check(t, os.exists(fmt.tprintf("%s/rt-media/image1.png", g_cli_dir)), "and writes its pictures beside it")
		o2, _ := run("outline", deck, "--json")
		o1, _ := run("outline", "--json")
		check(t, strings.contains(o1, `"title": "Pictures composite like anything else"`) && strings.contains(o2, `"title": "Pictures composite like anything else"`), "with the same outline")
		_, again := run("import", pptx, deck, "--json")
		check(t, again == kit.EXIT_USAGE, "import will not overwrite without --force (exit %d)", again)
		_, other := run("import", deck, fmt.tprintf("%s/x.json", g_cli_dir), "--json")
		check(t, other == kit.EXIT_USAGE, "a .json is not something to import (exit %d)", other)
		dry := fmt.tprintf("%s/dry-import.json", g_cli_dir)
		_, dc := run("import", pptx, dry, "--dry-run", "--json")
		check(t, dc == 0 && !os.exists(dry) && !os.exists(fmt.tprintf("%s/dry-import-media", g_cli_dir)), "import --dry-run writes neither the deck nor its pictures")
	}

	// --- refusal, dry runs and the things that are not there ----------------
	{
		a := fresh("delete.json")
		before, _ := os.read_entire_file_from_path(a, context.temp_allocator)
		out, code := run("delete", a, "2", "--json")
		check(t, code == kit.EXIT_NEEDS_YES && strings.contains(out, "needs --yes"), "delete without --yes is refused (exit %d)", code)
		_, dry := run("delete", a, "2", "--dry-run", "--json")
		after, _ := os.read_entire_file_from_path(a, context.temp_allocator)
		check(t, dry == 0 && string(before) == string(after), "and neither the refusal nor a dry run changed the file")
		_, yes := run("delete", a, "2", "--yes", "--json")
		st, b := twin("delete-twin.json")
		st.slide = 1
		invoke(st, nil, nil, .Slide_Del)
		save_deck(&st.deck, b)
		check(t, yes == 0 && same_file(a, b), "delete --yes writes the deck Shift X makes")
		_, el := run("delete", a, "5", "--element", "2", "--yes", "--json")
		st.slide = 4
		st.sel = 1
		invoke(st, nil, nil, .Elem_Del)
		save_deck(&st.deck, b)
		check(t, el == 0 && same_file(a, b), "delete --element writes the deck X makes")
		one := fmt.tprintf("%s/one.json", g_cli_dir)
		run("new", one, "--json")
		_, last := run("delete", one, "1", "--yes", "--json")
		check(t, last == kit.EXIT_USAGE, "the last slide cannot be deleted (exit %d)", last)
	}
	{
		_, c1 := run("show", "99", "--json")
		check(t, c1 == kit.EXIT_NOT_FOUND, "a slide past the end is not found (exit %d)", c1)
		_, c2 := run("info", "no-such-deck.json", "--json")
		check(t, c2 == kit.EXIT_NOT_FOUND, "a missing deck is not found (exit %d)", c2)
		_, c3 := run("set-text", "@fixture", "1", "title", "x", "--json")
		check(t, c3 == kit.EXIT_USAGE, "the built-in deck cannot be edited (exit %d)", c3)
		// A typo is an error, never a window: the kit hands a bare word to
		// the window, and main refuses one that is not a deck.
		_, c4 := run("lsit")
		check(t, c4 == kit.EXIT_USAGE, "a mistyped command is a usage error (exit %d)", c4)
		_, c5 := run("insert", "@fixture", "1", "rect", "--y", "3")
		check(t, c5 == kit.EXIT_USAGE, "--y is the kit's --yes, so insert takes --top (exit %d)", c5)
	}
	{
		path := fmt.tprintf("%s/new.json", g_cli_dir)
		out, code := run("new", path, "--title", "Quarterly review", "--subtitle", "October", "--theme", "paper", "--json")
		back, err := load_deck(path)
		check(t, code == 0 && err == "" && back.title == "Quarterly review" && back.theme.name == "Paper", "slides new writes a deck with its --title and --theme: %s", out)
		check(t, err == "" && len(back.slides) == 1 && back.slides[0].elems[0].text == "Quarterly review", "--title survives to the title slide (collab's parser used to eat it)")
		_, again := run("new", path, "--json")
		check(t, again == kit.EXIT_USAGE, "new will not overwrite without --force (exit %d)", again)
	}

	// --- pictures and files --------------------------------------------------
	{
		fonts: p.Fonts
		fonts_headless(&fonts)
		png := fmt.tprintf("%s/s1.png", g_cli_dir)
		_, code := run("render", "@fixture", "1", png, "--width", "640", "--json")
		img, ok := p.load_image(png)
		check(t, code == 0 && ok && img.w == 640 && img.h == 360, "render writes a 640x360 PNG")
		if ok {
			st := state_new(exe_directory())
			st.deck = fixture_deck()
			want := render_slide_buffer(&st.deck, 0, 640, 360, &fonts, &st.imgs, context.temp_allocator)
			differ := 0
			for v, i in want {
				if v & 0xffffff != img.px[i] & 0xffffff {
					differ += 1
				}
			}
			check(t, differ == 0, "and it is the canvas renderer's picture, pixel for pixel (%d differ)", differ)
		}
		pdf := fmt.tprintf("%s/deck.pdf", g_cli_dir)
		pptx := fmt.tprintf("%s/deck.pptx", g_cli_dir)
		dir := fmt.tprintf("%s/png", g_cli_dir)
		_, c1 := run("export", "@fixture", pdf, "--json")
		_, c2 := run("export", "@fixture", pptx, "--json")
		_, c3 := run("export", "@fixture", dir, "--json")
		raw1, _ := os.read_entire_file_from_path(pdf, context.temp_allocator)
		raw2, _ := os.read_entire_file_from_path(pptx, context.temp_allocator)
		check(t, c1 == 0 && strings.has_prefix(string(raw1), "%PDF-"), "export to .pdf writes a PDF")
		check(t, c2 == 0 && len(raw2) > 4 && raw2[0] == 'P' && raw2[1] == 'K', "export to .pptx writes a ZIP package")
		infos, _ := os.read_directory_by_path(dir, -1, context.temp_allocator)
		check(t, c3 == 0 && len(infos) == 9, "export to a directory writes 8 slides and a contact sheet, %d files", len(infos))
		// The window's Export PowerPoint is the same procedure, so the same
		// bytes.
		st := state_new(exe_directory())
		st.deck = fixture_deck()
		twin_pptx := fmt.tprintf("%s/twin.pptx", g_cli_dir)
		deck_export(&st.deck, twin_pptx, .Pptx, &fonts, &st.imgs)
		check(t, same_file(pptx, twin_pptx), "and export's .pptx is byte for byte what Ctrl Shift E writes")
		dry := fmt.tprintf("%s/dry.pdf", g_cli_dir)
		_, c4 := run("export", "@fixture", dry, "--dry-run", "--json")
		check(t, c4 == 0 && !os.exists(dry), "export --dry-run writes nothing")
	}

	// --- the older spellings still work ----------------------------------------
	{
		legacy := fmt.tprintf("%s/legacy.pptx", g_cli_dir)
		_, c1 := run("--pptx", legacy)
		check(t, c1 == 0 && os.exists(legacy), "slides --pptx FILE still writes the built-in deck")
		a := fresh("legacy.json")
		lpdf := fmt.tprintf("%s/legacy.pdf", g_cli_dir)
		out, c2 := run(a, "--pdf", lpdf)
		check(t, c2 == 0 && os.exists(lpdf) && strings.contains(out, "wrote"), "slides deck.json --pdf FILE still exports that deck")
	}

	// The audit log saw the edits and not the reads.
	{
		raw, _ := os.read_entire_file_from_path(fmt.tprintf("%s/audit.jsonl", g_cli_dir), context.temp_allocator)
		log := string(raw)
		check(t, strings.contains(log, `"verb":"duplicate"`) && strings.contains(log, `"verb":"delete"`), "edits are in the audit log")
		check(t, !strings.contains(log, `"verb":"info"`), "reads are not")
	}
}
