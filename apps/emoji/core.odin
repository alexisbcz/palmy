package main

// The picker's core, shared by the window and the command line.
//
// Nothing here draws or reads a key. The search the grid shows, the character
// a word names, and the Recently used list on disk are each one procedure,
// called by `refilter`/`remember` in main.odin and by the commands in cli.odin
// alike, so a character used from `emoji use` is the one the window's Recent
// block shows next time it opens — same file, same order, same cap.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:unicode/utf8"

// ---------------------------------------------------------------------------
// The search index
// ---------------------------------------------------------------------------

// g_lows is name + aliases + category, lowercased, one per CHARS row. Built
// once per process and kept: the window and the CLI read the same table.
@(private = "file")
g_lows: []string

char_lows :: proc() -> []string {
	if g_lows == nil {
		g_lows = make([]string, len(CHARS))
		for c, i in CHARS {
			g_lows[i] = strings.to_lower(fmt.tprintf("%s %s %s", c.name, c.alias, CATEGORIES[c.cat]))
		}
	}
	return g_lows
}

// match requires every whitespace-separated term to appear, which is what makes
// "down arrow" find U+2193 without matching every arrow in the block.
match :: proc(hay: string, terms: []string) -> bool {
	for t in terms {
		if !strings.contains(hay, t) {
			return false
		}
	}
	return true
}

// parse_codepoint recognises "2192", "u+2192" and "0x2192", so a codepoint you
// already know is one search away.
parse_codepoint :: proc(q: string) -> (rune, bool) {
	s := strings.trim_space(q)
	s = strings.trim_prefix(s, "u+")
	s = strings.trim_prefix(s, "U+")
	s = strings.trim_prefix(s, "0x")
	if len(s) < 2 || len(s) > 6 {
		return 0, false
	}
	v: u32
	for i in 0 ..< len(s) {
		d: u32
		switch s[i] {
		case '0' ..= '9':
			d = u32(s[i] - '0')
		case 'a' ..= 'f':
			d = u32(s[i] - 'a' + 10)
		case 'A' ..= 'F':
			d = u32(s[i] - 'A' + 10)
		case:
			return 0, false
		}
		v = v * 16 + d
	}
	return rune(v), true
}

index_of_rune :: proc(r: rune) -> (int, bool) {
	for c, i in CHARS {
		if c.cp == r {
			return i, true
		}
	}
	return 0, false
}

// search_chars is what the grid shows for a query in a block. An empty query
// is the block itself (CAT_RECENT: the recent list, newest first); otherwise
// a literal codepoint comes first, then every character whose name, aliases
// and category hold all of the query's terms, in table order, whichever block
// is selected — the window searches everything.
search_chars :: proc(out: ^[dynamic]int, query: string, cat: int, recent: []rune) {
	clear(out)
	q := strings.to_lower(strings.trim_space(query), context.temp_allocator)

	if q == "" {
		if cat == CAT_RECENT {
			for r in recent {
				if i, ok := index_of_rune(r); ok {
					append(out, i)
				}
			}
		} else {
			for c, i in CHARS {
				if c.cat == cat {
					append(out, i)
				}
			}
		}
		return
	}

	if cp, ok := parse_codepoint(q); ok {
		if i, found := index_of_rune(cp); found {
			append(out, i)
		}
	}

	lows := char_lows()
	terms := strings.fields(q, context.temp_allocator)
	for i in 0 ..< len(CHARS) {
		if len(out) > 0 && out[0] == i {
			continue
		}
		if match(lows[i], terms) {
			append(out, i)
		}
	}
}

// category_index finds a block by name, case-folded, or by a unique prefix;
// "recent" is the Recently used pseudo-block.
category_index :: proc(name: string) -> (int, bool) {
	n := strings.to_lower(strings.trim_space(name), context.temp_allocator)
	if n == "" {
		return 0, false
	}
	if n == "recent" || n == "recently used" {
		return CAT_RECENT, true
	}
	for c, i in CATEGORIES {
		if strings.to_lower(c, context.temp_allocator) == n {
			return i, true
		}
	}
	found, hits := 0, 0
	for c, i in CATEGORIES {
		if strings.has_prefix(strings.to_lower(c, context.temp_allocator), n) {
			found = i
			hits += 1
		}
	}
	return found, hits == 1
}

// resolve_char names one row of the table: the character itself ("→"), or
// its codepoint in any form parse_codepoint takes ("U+2192", "2192").
resolve_char :: proc(word: string) -> (int, bool) {
	s := strings.trim_space(word)
	if s == "" {
		return 0, false
	}
	if r, n := utf8.decode_rune_in_string(s); n == len(s) && r != utf8.RUNE_ERROR {
		if i, ok := index_of_rune(r); ok {
			return i, true
		}
	}
	if cp, ok := parse_codepoint(s); ok {
		return index_of_rune(cp)
	}
	return 0, false
}

// ---------------------------------------------------------------------------
// Recently used
//
// ~/.local/share/palmy-emoji/recent — one `U+XXXX` per line, newest first, at
// most RECENT_CAP lines. Only characters still in the table are kept.
// ---------------------------------------------------------------------------

recent_dir :: proc(al := context.temp_allocator) -> string {
	home, err := os.user_home_dir(context.temp_allocator)
	if err != nil || home == "" {
		return ""
	}
	return fmt.aprintf("%s/.local/share/palmy-emoji", home, allocator = al)
}

recent_file :: proc(al := context.temp_allocator) -> string {
	dir := recent_dir()
	if dir == "" {
		return ""
	}
	return fmt.aprintf("%s/recent", dir, allocator = al)
}

recent_load :: proc(recent: ^[dynamic]rune) {
	clear(recent)
	path := recent_file()
	if path == "" {
		return
	}
	data, err := os.read_entire_file_from_path(path, context.temp_allocator)
	if err != nil {
		return
	}
	it := string(data)
	for line in strings.split_lines_iterator(&it) {
		if cp, ok := parse_codepoint(strings.trim_space(line)); ok {
			if _, found := index_of_rune(cp); found {
				append(recent, cp)
			}
		}
		if len(recent) >= RECENT_CAP {
			break
		}
	}
}

recent_save :: proc(recent: []rune) -> bool {
	dir := recent_dir()
	if dir == "" {
		return false
	}
	_ = os.make_directory_all(dir)
	_ = os.chmod(dir, os.perm_number(0o700))
	b := strings.builder_make(context.temp_allocator)
	for r in recent {
		fmt.sbprintfln(&b, "U+%04X", r)
	}
	path := fmt.tprintf("%s/recent", dir)
	return os.write_entire_file(path, transmute([]u8)strings.to_string(b), os.perm_number(0o600)) == nil
}

// recent_remember moves r to the front of the list, dropping the oldest past
// the cap. It does not save; the caller does, once.
recent_remember :: proc(recent: ^[dynamic]rune, r: rune) {
	for c, i in recent {
		if c == r {
			ordered_remove(recent, i)
			break
		}
	}
	inject_at(recent, 0, r)
	for len(recent) > RECENT_CAP {
		pop(recent)
	}
}

// recent_forget removes r; it reports whether it was there.
recent_forget :: proc(recent: ^[dynamic]rune, r: rune) -> bool {
	for c, i in recent {
		if c == r {
			ordered_remove(recent, i)
			return true
		}
	}
	return false
}
