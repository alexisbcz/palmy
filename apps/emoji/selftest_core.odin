package main

// The command line and the core it shares with the window, headless.
//
// Run by `emoji --selftest` after selftest.odin. Every command is driven
// in-process through the kit (`cli_capture_json`), its output checked against
// the fields it declares, and the one claim that makes it a front end rather
// than a copy is checked both ways round: a character used from the command
// line is the first thing in the window's Recently used block, and one chosen
// in the window is the first thing `emoji recent` prints.
//
// HOME and PALM_AUDIT point into a scratch directory for the whole run (set in
// cli_selftest before either half starts), so neither the person's recent
// list nor their audit log is read or written.

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import kit "kit:."
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

CORE_SCRATCH :: "/tmp/palmy-emoji-selftest"

// selftest_isolate moves HOME and the audit log into scratch. Called before
// any test that could remember a character.
selftest_isolate :: proc() {
	_ = os.remove_all(CORE_SCRATCH)
	_ = os.make_directory_all(CORE_SCRATCH + "/home")
	os.set_env("HOME", CORE_SCRATCH + "/home")
	os.set_env("XDG_DATA_HOME", CORE_SCRATCH + "/home/.local/share")
	os.set_env("PALM_AUDIT", CORE_SCRATCH + "/audit.jsonl")
}

@(private = "file")
run :: proc(argv: ..string) -> (code: int, doc: json.Object, text: string) {
	c, v, t := kit.cli_capture_json(surface(), argv, context.temp_allocator)
	o, _ := v.(json.Object)
	return c, o, t
}

@(private = "file")
valid :: proc(text: string, fields: []kit.Field, what: string) {
	problems := kit.cli_validate_output(text, fields, context.temp_allocator)
	ok(len(problems) == 0, "%s does not match its declared output: %v", what, problems)
}

@(private = "file")
chars_of :: proc(o: json.Object) -> []json.Value {
	a, _ := o["chars"].(json.Array)
	return a[:]
}

@(private = "file")
str_of :: proc(v: json.Value, key: string) -> string {
	o, _ := v.(json.Object)
	s, _ := o[key].(json.String)
	return string(s)
}

@(private = "file")
int_of :: proc(o: json.Object, key: string) -> int {
	#partial switch n in o[key] {
	case json.Integer:
		return int(n)
	case json.Float:
		return int(n)
	}
	return -1
}

core_selftest :: proc() -> int {
	selftest_isolate()
	defer _ = os.remove_all(CORE_SCRATCH)
	g_test = true

	fmt.println("-- the core: search, names, blocks")
	{
		hits := make([dynamic]int, context.temp_allocator)
		search_chars(&hits, "u+2318", 0, nil)
		ok(len(hits) > 0 && CHARS[hits[0]].cp == 0x2318, "a codepoint query puts that character first")
		search_chars(&hits, "", 0, nil)
		ok(len(hits) > 0, "an empty query is the block")
		for h in hits {
			if CHARS[h].cat != 0 {
				ok(false, "an empty query in block 0 returned %q from another block", CHARS[h].name)
				break
			}
		}
		i, found := resolve_char("→")
		ok(found && CHARS[i].cp == 0x2192, "the character itself resolves")
		i, found = resolve_char("0x2192")
		ok(found && CHARS[i].cp == 0x2192, "0x2192 resolves")
		_, found = resolve_char("→→")
		ok(!found, "two characters are not one")
		_, found = resolve_char("hello")
		ok(!found, "a word is not a character")
		cat, cok := category_index("ARROWS")
		ok(cok && cat == 0, "a block name is case-folded")
		cat, cok = category_index("box")
		ok(cok && CATEGORIES[cat] == "Box drawing", "a unique prefix names a block")
		_, cok = category_index("s")
		ok(!cok, "an ambiguous prefix (Symbols, Shapes, Super & sub) names nothing")
		cat, cok = category_index("recent")
		ok(cok && cat == CAT_RECENT, "recent is the Recently used pseudo-block")
	}

	fmt.println("-- the commands, in process")
	{
		code, o, text := run("search", "arrow", "right")
		ok(code == kit.EXIT_OK, "search exits 0, got %d", code)
		valid(text, SEARCH_FIELDS, "search")
		cs := chars_of(o)
		found := false
		for c in cs {
			if str_of(c, "codepoint") == "U+2192" {found = true}
			low := strings.to_lower(fmt.tprintf("%s %s %s", str_of(c, "name"), str_of(c, "aliases"), str_of(c, "category")), context.temp_allocator)
			ok(strings.contains(low, "arrow") && strings.contains(low, "right"), "search returned %q, which lacks a term", str_of(c, "name"))
		}
		ok(found, "search arrow right finds U+2192")

		// The CLI's answer is the grid's answer, in the same order.
		hits := make([dynamic]int, context.temp_allocator)
		search_chars(&hits, "arrow right", 0, nil)
		ok(int_of(o, "total") == len(hits), "search total %d is the grid's %d", int_of(o, "total"), len(hits))
		same := len(cs) == min(50, len(hits))
		for c, k in cs {
			if k < len(hits) && str_of(c, "char") != CHARS[hits[k]].s {same = false}
		}
		ok(same, "search lists the grid's hits in the grid's order")

		code, o, text = run("search", "2318")
		cs = chars_of(o)
		ok(code == 0 && len(cs) > 0 && str_of(cs[0], "char") == "⌘", "search 2318 puts ⌘ first")

		code, o, _ = run("search", "heart", "--category", "symbols", "--limit", "3")
		cs = chars_of(o)
		ok(code == 0 && len(cs) <= 3 && len(cs) > 0, "search --category --limit gives 1..3, got %d", len(cs))
		for c in cs {
			ok(str_of(c, "category") == "Symbols", "--category symbols let %q through", str_of(c, "category"))
		}
		code, o, _ = run("search", "heart", "--category", "nope")
		ok(code == kit.EXIT_NOT_FOUND, "an unknown block is not found (3), got %d", code)
		_, has := o["categories"]
		ok(has, "the refusal names the blocks there are")

		code, o, text = run("info", "⌘")
		ok(code == 0, "info ⌘ exits 0")
		valid(text, CHAR_FIELDS, "info")
		ok(str_of(o, "codepoint") == "U+2318", "info ⌘ is U+2318, got %q", str_of(o, "codepoint"))
		ok(str_of(o, "utf8") == "e2 8c 98", "info's UTF-8 bytes are %q", str_of(o, "utf8"))
		ok(str_of(o, "html") == "&#x2318;", "info's entity is %q", str_of(o, "html"))
		ok(str_of(o, "name") == "PLACE OF INTEREST SIGN", "info's name is %q", str_of(o, "name"))
		code, o, _ = run("info", "nonsense")
		ok(code == kit.EXIT_NOT_FOUND, "info of a word is not found (3), got %d", code)
		ok(str_of(o, "error") != "", "a not-found info is the documented error object")

		code, o, text = run("categories")
		ok(code == 0, "categories exits 0")
		valid(text, CATEGORIES_FIELDS, "categories")
		cats, _ := o["categories"].(json.Array)
		total := 0
		for c in cats {
			co, _ := c.(json.Object)
			total += int_of(co, "count")
		}
		ok(len(cats) == len(CATEGORIES), "categories lists %d blocks", len(cats))
		ok(total == len(CHARS), "the block counts add up to the table: %d of %d", total, len(CHARS))

		code, o, text = run("list", "arrows", "--limit", "5")
		ok(code == 0, "list arrows exits 0")
		valid(text, LIST_FIELDS, "list")
		ok(len(chars_of(o)) == 5 && int_of(o, "total") > 100, "list arrows --limit 5 gives 5 of %d", int_of(o, "total"))
	}

	fmt.println("-- Recently used: the command line and the window share one list")
	{
		code, o, text := run("recent")
		ok(code == 0 && len(chars_of(o)) == 0, "a fresh home has nothing recent")
		valid(text, RECENT_FIELDS, "recent")

		code, o, text = run("use", "U+2192", "--dry-run")
		ok(code == 0, "use --dry-run exits 0")
		ok(!os.exists(recent_file()), "use --dry-run wrote %s", recent_file())

		code, o, text = run("use", "U+2192")
		ok(code == 0, "use U+2192 exits 0, got %d", code)
		valid(text, USE_FIELDS, "use")
		ok(str_of(o, "char") == "→" && int_of(o, "recent") == 1, "use answered %q with %d recent", str_of(o, "char"), int_of(o, "recent"))
		code, o, _ = run("use", "⌘")
		ok(code == 0 && int_of(o, "recent") == 2, "a second use makes two recent")

		// Text mode prints the character and nothing else.
		tcode, tout, _ := kit.cli_capture(surface(), {"use", "⌘"}, context.temp_allocator)
		ok(tcode == 0 && tout == "⌘\n", "text use printed %q, expected the character alone", tout)

		// The window, opened afresh as main() opens it, shows them first.
		off := p.offscreen_create(1060, 700, 1, "w-full h-full flex-col bg-background text-foreground")
		defer p.offscreen_destroy(off)
		st := St {
			hits   = make([dynamic]int),
			query  = make([dynamic]u8),
			recent = make([dynamic]rune),
			cat    = CAT_RECENT,
		}
		build_index(&st)
		recent_load(&st.recent)
		refilter(&st)
		ui := p.offscreen_begin(off)
		handle_keys(ui, nil, &st)
		build(ui, &st)
		p.offscreen_end(off)
		ok(len(st.hits) == 2, "the window's Recently used holds %d after two uses on the command line, expected 2", len(st.hits))
		if len(st.hits) == 2 {
			ok(CHARS[st.hits[0]].cp == 0x2318 && CHARS[st.hits[1]].cp == 0x2192, "the window's Recently used is ⌘ then →, newest first")
		}

		// And the other way: Enter in the window, then `emoji recent`.
		st.cat = 0
		clear(&st.query)
		append(&st.query, "omega")
		st.sel = 0
		refilter(&st)
		p.press_key(off, p.KEY_RETURN)
		ui = p.offscreen_begin(off)
		handle_keys(ui, nil, &st)
		build(ui, &st)
		p.offscreen_end(off)
		picked := st.recent[0] if len(st.recent) > 0 else 0
		code, o, _ = run("recent")
		cs := chars_of(o)
		ok(len(cs) == 3, "recent lists %d after the window chose a third, expected 3", len(cs))
		if len(cs) > 0 {
			ok(str_of(cs[0], "codepoint") == fmt.tprintf("U+%04X", picked), "recent starts with the window's choice U+%04X, got %s", picked, str_of(cs[0], "codepoint"))
		}
		code, o, _ = run("list", "recent")
		ok(code == 0 && len(chars_of(o)) == 3, "list recent is the same list")
		code, o, _ = run("search", "arrow", "--category", "recent")
		ok(code == 0 && len(chars_of(o)) == 1, "search --category recent finds only the recent arrow, got %d", len(chars_of(o)))

		code, o, text = run("forget", "→")
		ok(code == 0 && int_of(o, "removed") == 1 && int_of(o, "recent") == 2, "forget → removes one, leaving two")
		valid(text, FORGET_FIELDS, "forget")
		code, o, _ = run("forget", "→")
		ok(code == 0 && int_of(o, "removed") == 0, "forgetting it again removes nothing")

		code, o, _ = run("clear-recent")
		ok(code == kit.EXIT_NEEDS_YES, "clear-recent without --yes is refused (4), got %d", code)
		code, o, _ = run("recent")
		ok(len(chars_of(o)) == 2, "the refusal left the list alone")
		code, o, text = run("clear-recent", "--yes")
		ok(code == 0 && int_of(o, "removed") == 2, "clear-recent --yes removes both")
		valid(text, FORGET_FIELDS, "clear-recent")
		code, o, _ = run("recent")
		ok(len(chars_of(o)) == 0, "Recently used is empty afterwards")

		code, o, _ = run("use", "nonsense")
		ok(code == kit.EXIT_NOT_FOUND, "use of a word is not found (3), got %d", code)
		code, _, _ = run("bogus")
		ok(code == kit.EXIT_USAGE, "an unknown verb is a usage error, not a window: %d", code)
	}

	fmt.println("-- the audit log stayed in scratch")
	ok(os.exists(CORE_SCRATCH + "/audit.jsonl"), "the uses were audited into the scratch log")

	fmt.printfln("\n%s  %d checks, %d failure(s)", fails == 0 ? "PASS" : "FAILED", checks, fails)
	return fails
}
