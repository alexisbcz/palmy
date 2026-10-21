package main

// The command-line front end of the character picker.
//
// Every answer comes from core.odin, the procedures the window itself runs:
// `search` is the grid under a query (search_chars, the same matcher, a
// literal codepoint first), `list` is a block with no query, `recent` is the
// Recently used block, and `use` is choosing a character — it goes to the
// front of the same recent file the window reads, so the next window opens
// with it there. Nothing is copied to the clipboard: on the command line the
// character is printed, and stdout is the clipboard of a pipeline.
//
// The only state is the recent list, ~/.local/share/palmy-emoji/recent.

import "core:fmt"
import "core:strings"
import kit "kit:."

// ---------------------------------------------------------------------------
// What the commands print
// ---------------------------------------------------------------------------

CHAR_FIELDS :: []kit.Field {
	{name = "char", kind = .String, help = "the character itself"},
	{name = "codepoint", kind = .String, help = "U+2192"},
	{name = "value", kind = .Int, help = "the codepoint as a number"},
	{name = "name", kind = .String, help = "the Unicode name"},
	{name = "aliases", kind = .String, help = "extra search terms, space separated; may be empty"},
	{name = "category", kind = .String, help = "the window's block"},
	{name = "utf8", kind = .String, help = "the UTF-8 bytes in hex: e2 86 92"},
	{name = "html", kind = .String, help = "the HTML entity: &#x2192;"},
}

SEARCH_FIELDS :: []kit.Field {
	{name = "query", kind = .String},
	{name = "category", kind = .String, help = "the block the results were narrowed to; empty for all"},
	{name = "total", kind = .Int, help = "matches before --limit"},
	{name = "count", kind = .Int, help = "matches shown"},
	{name = "chars", kind = .Array, of = CHAR_FIELDS},
}

LIST_FIELDS :: []kit.Field {
	{name = "category", kind = .String},
	{name = "total", kind = .Int},
	{name = "count", kind = .Int},
	{name = "chars", kind = .Array, of = CHAR_FIELDS},
}

CATEGORIES_FIELDS :: []kit.Field {
	{name = "unicode", kind = .String, help = "the UCD version the names come from"},
	{name = "total", kind = .Int, help = "characters in the table"},
	{
		name = "categories",
		kind = .Array,
		of = {{name = "name", kind = .String}, {name = "count", kind = .Int}},
	},
}

RECENT_FIELDS :: []kit.Field {
	{name = "file", kind = .String, help = "where the list lives"},
	{name = "count", kind = .Int},
	{name = "chars", kind = .Array, of = CHAR_FIELDS},
}

USE_FIELDS :: []kit.Field {
	{name = "char", kind = .String},
	{name = "codepoint", kind = .String},
	{name = "name", kind = .String},
	{name = "recent", kind = .Int, help = "characters in Recently used afterwards"},
}

FORGET_FIELDS :: []kit.Field {
	{name = "codepoint", kind = .String, opt = true},
	{name = "removed", kind = .Int},
	{name = "recent", kind = .Int, help = "characters left in Recently used"},
}

// ---------------------------------------------------------------------------
// The declaration
// ---------------------------------------------------------------------------

@(private = "file")
COMMANDS := []kit.Command {
	{
		verb = "search",
		summary = "characters whose name, aliases or block hold every word; a codepoint (2192, U+2192) comes first",
		effect = .Read,
		aliases = {"find"},
		args = {{name = "query", kind = .String, required = true, variadic = true, free = true, help = "words, or a codepoint"}},
		flags = {
			{name = "category", kind = .String, help = "only this block (a name or unique prefix: arrows, maths, …)"},
			{name = "limit", kind = .Int, def = "50", help = "at most this many; 0 is no limit"},
		},
		out = SEARCH_FIELDS,
		examples = {"emoji search arrow right --json", "emoji search U+2318 --json", "emoji search heart --category symbols --limit 5"},
		run = cmd_search,
	},
	{
		verb = "info",
		summary = "one character, given as itself or as a codepoint",
		effect = .Read,
		args = {{name = "char", kind = .String, required = true, free = true, help = "→, U+2192, 2192 or 0x2192"}},
		out = CHAR_FIELDS,
		examples = {"emoji info U+2192 --json", "emoji info ⌘"},
		run = cmd_info,
	},
	{
		verb = "categories",
		summary = "the blocks the window lists down its side, with how many characters each holds",
		effect = .Read,
		out = CATEGORIES_FIELDS,
		examples = {"emoji categories --json"},
		run = cmd_categories,
	},
	{
		verb = "list",
		summary = "every character in one block, in the window's order",
		effect = .Read,
		args = {{name = "category", kind = .String, required = true, help = "a block name or unique prefix; recent is Recently used"}},
		flags = {{name = "limit", kind = .Int, def = "0", help = "at most this many; 0 is no limit"}},
		out = LIST_FIELDS,
		examples = {"emoji list arrows --limit 10 --json", "emoji list currency"},
		run = cmd_list,
	},
	{
		verb = "recent",
		summary = "Recently used, newest first: what the window's first block shows",
		effect = .Read,
		flags = {{name = "limit", kind = .Int, def = "0", help = "at most this many; 0 is no limit"}},
		out = RECENT_FIELDS,
		examples = {"emoji recent --json"},
		run = cmd_recent,
	},
	{
		verb = "use",
		summary = "choose a character, as Enter does in the window: printed, and put first in Recently used",
		effect = .Mutate,
		args = {{name = "char", kind = .String, required = true, free = true, help = "→, U+2192, 2192 or 0x2192"}},
		out = USE_FIELDS,
		examples = {"emoji use U+2192", "emoji use ⌘ --json"},
		run = cmd_use,
	},
	{
		verb = "forget",
		summary = "take one character out of Recently used",
		effect = .Mutate,
		args = {{name = "char", kind = .String, required = true, free = true}},
		out = FORGET_FIELDS,
		examples = {"emoji forget U+2192 --json"},
		run = cmd_forget,
	},
	{
		verb = "clear-recent",
		summary = "empty Recently used",
		effect = .Destructive,
		out = FORGET_FIELDS,
		examples = {"emoji clear-recent --yes --json"},
		run = cmd_clear_recent,
	},
}

@(private = "file")
g_surface: kit.Surface

surface :: proc() -> ^kit.Surface {
	if g_surface.noun == "" {
		g_surface = kit.Surface {
			noun     = "emoji",
			summary  = "a character picker: search Unicode by name or codepoint, browse blocks, keep recently used",
			gui      = true,
			selftest = cli_selftest,
			notes    = SURFACE_NOTES,
			commands = COMMANDS,
		}
	}
	return &g_surface
}

@(private = "file")
SURFACE_NOTES :: `The table is the characters DejaVu Sans can draw (see main.odin for why it is
not colour emoji), named from the Unicode Character Database. A character may be
given as itself or as a codepoint: →, U+2192, 2192, 0x2192. Recently used is
~/.local/share/palmy-emoji/recent, the file the window reads. With no arguments
the window opens; --shots <dir> renders it offscreen.`

cli_selftest :: proc() -> int {
	// The picker's own half presses Enter, which remembers a character: it
	// must do that in a scratch home, never the person's.
	selftest_isolate()
	f := selftest()
	f += core_selftest()
	fmt.printfln("\n%s  emoji: %d failure(s) in all", f == 0 ? "PASS" : "FAILED", f)
	return f == 0 ? 0 : 1
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

@(private = "file")
char_json :: proc(i: int) -> ^kit.Json {
	c := CHARS[i]
	o := kit.jobj()
	kit.jset_str(o, "char", c.s)
	kit.jset_str(o, "codepoint", fmt.tprintf("U+%04X", c.cp))
	kit.jset_int(o, "value", int(c.cp))
	kit.jset_str(o, "name", c.name)
	kit.jset_str(o, "aliases", c.alias)
	kit.jset_str(o, "category", CATEGORIES[c.cat])
	b := strings.builder_make(context.temp_allocator)
	for i in 0 ..< len(c.s) {
		if i > 0 {
			strings.write_byte(&b, ' ')
		}
		fmt.sbprintf(&b, "%02x", c.s[i])
	}
	kit.jset_str(o, "utf8", strings.to_string(b))
	kit.jset_str(o, "html", fmt.tprintf("&#x%X;", c.cp))
	return o
}

@(private = "file")
chars_json :: proc(idx: []int, limit: int) -> (arr: ^kit.Json, n: int) {
	arr = kit.jarr()
	for i in idx {
		if limit > 0 && n >= limit {
			break
		}
		kit.jpush(arr, char_json(i))
		n += 1
	}
	return
}

@(private = "file")
resolve :: proc(c: ^kit.Call) -> (idx: int, code: int) {
	word := kit.cli_str(c, "char")
	i, ok := resolve_char(word)
	if !ok {
		code = kit.cli_failf(c, kit.EXIT_NOT_FOUND, "%q is not a character in the table (give it as itself or as U+XXXX)", word)
		kit.cli_err_field(c, "given", word)
		return 0, code
	}
	return i, kit.EXIT_OK
}

@(private = "file")
category_arg :: proc(c: ^kit.Call, name: string) -> (cat: int, code: int) {
	cat_i, ok := category_index(name)
	if !ok {
		names := make([dynamic]string, context.temp_allocator)
		append(&names, "recent")
		for n in CATEGORIES {
			append(&names, strings.to_lower(n, context.temp_allocator))
		}
		code = kit.cli_failf(c, kit.EXIT_NOT_FOUND, "no block named %q", name)
		kit.cli_err_field(c, "categories", names[:])
		return 0, code
	}
	return cat_i, kit.EXIT_OK
}

// ---------------------------------------------------------------------------
// Commands
// ---------------------------------------------------------------------------

@(private = "file")
cmd_search :: proc(c: ^kit.Call) -> int {
	query := strings.join(kit.cli_rest(c), " ", context.temp_allocator)
	limit := kit.cli_int(c, "limit", 50)
	cat_name := ""
	only := -2
	if kit.cli_has(c, "category") {
		cat, code := category_arg(c, kit.cli_str(c, "category"))
		if code != kit.EXIT_OK {
			return code
		}
		only = cat
		cat_name = cat == CAT_RECENT ? "Recently used" : CATEGORIES[cat]
	}

	recent := make([dynamic]rune, context.temp_allocator)
	if only == CAT_RECENT {
		recent_load(&recent)
	}
	hits := make([dynamic]int, context.temp_allocator)
	search_chars(&hits, query, 0, recent[:])

	kept := make([dynamic]int, context.temp_allocator)
	for h in hits {
		switch {
		case only == -2:
			append(&kept, h)
		case only == CAT_RECENT:
			for r in recent {
				if r == CHARS[h].cp {
					append(&kept, h)
					break
				}
			}
		case CHARS[h].cat == only:
			append(&kept, h)
		}
	}

	arr, n := chars_json(kept[:], limit)
	kit.jset_str(c.out, "query", query)
	kit.jset_str(c.out, "category", cat_name)
	kit.jset_int(c.out, "total", len(kept))
	kit.jset_int(c.out, "count", n)
	kit.jset(c.out, "chars", arr)
	return kit.EXIT_OK
}

@(private = "file")
cmd_info :: proc(c: ^kit.Call) -> int {
	i, code := resolve(c)
	if code != kit.EXIT_OK {
		return code
	}
	c.out = char_json(i)
	return kit.EXIT_OK
}

@(private = "file")
cmd_categories :: proc(c: ^kit.Call) -> int {
	counts := make([]int, len(CATEGORIES), context.temp_allocator)
	for ch in CHARS {
		counts[ch.cat] += 1
	}
	arr := kit.jarr()
	for name, i in CATEGORIES {
		o := kit.jobj()
		kit.jset_str(o, "name", name)
		kit.jset_int(o, "count", counts[i])
		kit.jpush(arr, o)
	}
	kit.jset_str(c.out, "unicode", UNICODE_VERSION)
	kit.jset_int(c.out, "total", len(CHARS))
	kit.jset(c.out, "categories", arr)
	return kit.EXIT_OK
}

@(private = "file")
cmd_list :: proc(c: ^kit.Call) -> int {
	cat, code := category_arg(c, kit.cli_str(c, "category"))
	if code != kit.EXIT_OK {
		return code
	}
	recent := make([dynamic]rune, context.temp_allocator)
	if cat == CAT_RECENT {
		recent_load(&recent)
	}
	hits := make([dynamic]int, context.temp_allocator)
	search_chars(&hits, "", cat, recent[:])
	arr, n := chars_json(hits[:], kit.cli_int(c, "limit", 0))
	kit.jset_str(c.out, "category", cat == CAT_RECENT ? "Recently used" : CATEGORIES[cat])
	kit.jset_int(c.out, "total", len(hits))
	kit.jset_int(c.out, "count", n)
	kit.jset(c.out, "chars", arr)
	return kit.EXIT_OK
}

@(private = "file")
cmd_recent :: proc(c: ^kit.Call) -> int {
	recent := make([dynamic]rune, context.temp_allocator)
	recent_load(&recent)
	hits := make([dynamic]int, context.temp_allocator)
	search_chars(&hits, "", CAT_RECENT, recent[:])
	arr, n := chars_json(hits[:], kit.cli_int(c, "limit", 0))
	kit.jset_str(c.out, "file", recent_file())
	kit.jset_int(c.out, "count", n)
	kit.jset(c.out, "chars", arr)
	return kit.EXIT_OK
}

@(private = "file")
cmd_use :: proc(c: ^kit.Call) -> int {
	i, code := resolve(c)
	if code != kit.EXIT_OK {
		return code
	}
	ch := CHARS[i]
	recent := make([dynamic]rune, context.temp_allocator)
	recent_load(&recent)
	recent_remember(&recent, ch.cp)
	if !c.dry_run && !recent_save(recent[:]) {
		return kit.cli_failf(c, kit.EXIT_FAILED, "could not write %s", recent_file())
	}
	if c.json {
		kit.jset_str(c.out, "char", ch.s)
		kit.jset_str(c.out, "codepoint", fmt.tprintf("U+%04X", ch.cp))
		kit.jset_str(c.out, "name", ch.name)
		kit.jset_int(c.out, "recent", len(recent))
	} else {
		// In text the result is the character and nothing else, so that
		// `emoji use U+2192 | wl-copy` copies exactly it.
		c.out = kit.jstr(ch.s)
	}
	return kit.EXIT_OK
}

@(private = "file")
cmd_forget :: proc(c: ^kit.Call) -> int {
	i, code := resolve(c)
	if code != kit.EXIT_OK {
		return code
	}
	recent := make([dynamic]rune, context.temp_allocator)
	recent_load(&recent)
	removed := recent_forget(&recent, CHARS[i].cp)
	if removed && !c.dry_run && !recent_save(recent[:]) {
		return kit.cli_failf(c, kit.EXIT_FAILED, "could not write %s", recent_file())
	}
	kit.jset_str(c.out, "codepoint", fmt.tprintf("U+%04X", CHARS[i].cp))
	kit.jset_int(c.out, "removed", removed ? 1 : 0)
	kit.jset_int(c.out, "recent", len(recent))
	return kit.EXIT_OK
}

@(private = "file")
cmd_clear_recent :: proc(c: ^kit.Call) -> int {
	recent := make([dynamic]rune, context.temp_allocator)
	recent_load(&recent)
	n := len(recent)
	if !c.dry_run && n > 0 && !recent_save(nil) {
		return kit.cli_failf(c, kit.EXIT_FAILED, "could not write %s", recent_file())
	}
	kit.jset_int(c.out, "removed", n)
	kit.jset_int(c.out, "recent", c.dry_run ? n : 0)
	return kit.EXIT_OK
}
