package main

// Save and load.
//
// The native format is JSON: the `Deck` struct marshalled with enum names, two
// space indentation and keys in declaration order. It is the model written out
// verbatim — no separate schema, nothing computed, nothing dropped — so a deck
// saved and loaded is the same deck, and `--selftest` proves it by serialising
// the reloaded copy and comparing the bytes.

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"

DECK_VERSION :: 1

MARSHAL_OPTS := json.Marshal_Options {
	pretty         = true,
	use_spaces     = true,
	spaces         = 2,
	use_enum_names = true,
}

deck_bytes :: proc(d: ^Deck, allocator := context.allocator) -> (data: []u8, err: string) {
	dd := d^
	dd.version = DECK_VERSION
	opts := MARSHAL_OPTS
	bytes, e := json.marshal(dd, opts, allocator)
	if e != nil {
		return nil, fmt.tprintf("%v", e)
	}
	return bytes, ""
}

save_deck :: proc(d: ^Deck, path: string) -> string {
	data, err := deck_bytes(d, context.temp_allocator)
	if err != "" {
		return err
	}
	if slash := strings.last_index_byte(path, '/'); slash > 0 {
		_ = os.make_directory_all(path[:slash])
	}
	if e := os.write_entire_file(path, data); e != nil {
		return fmt.tprintf("cannot write %s: %v", path, e)
	}
	return ""
}

load_deck :: proc(path: string) -> (d: Deck, err: string) {
	data, e := os.read_entire_file_from_path(path, context.temp_allocator)
	if e != nil {
		return {}, fmt.tprintf("cannot read %s", path)
	}
	if ue := json.unmarshal(data, &d, json.DEFAULT_SPECIFICATION, context.allocator); ue != nil {
		return {}, fmt.tprintf("%s is not a deck: %v", path, ue)
	}
	if len(d.slides) == 0 {
		return {}, fmt.tprintf("%s has no slides", path)
	}
	// A file from an older version, or hand edited, still has to be safe to
	// draw: fix up anything the renderer would otherwise have to defend
	// against.
	if d.theme.fg == 0 {
		d.theme = THEMES[0]
	}
	if d.title == "" {
		d.title = "Untitled deck"
	}
	for &s in d.slides {
		if s.elems == nil {
			s.elems = make([dynamic]Element)
		}
		for &el in s.elems {
			normalise(&el)
		}
	}
	return d, ""
}

// roundtrip reports whether the deck survives a save/load cycle byte for byte.
roundtrip :: proc(d: ^Deck, path: string) -> (ok: bool, detail: string) {
	if e := save_deck(d, path); e != "" {
		return false, e
	}
	back, e2 := load_deck(path)
	if e2 != "" {
		return false, e2
	}
	a, ea := deck_bytes(d, context.temp_allocator)
	b, eb := deck_bytes(&back, context.temp_allocator)
	if ea != "" || eb != "" {
		return false, "re-marshal failed"
	}
	if len(a) != len(b) {
		return false, fmt.tprintf("%d bytes out, %d bytes back", len(a), len(b))
	}
	for i in 0 ..< len(a) {
		if a[i] != b[i] {
			return false, fmt.tprintf("byte %d differs", i)
		}
	}
	return true, fmt.tprintf("%d bytes, %d slides", len(a), len(back.slides))
}

default_deck_path :: proc(allocator := context.allocator) -> string {
	home, err := os.user_home_dir(context.temp_allocator)
	if err != nil {
		return strings.clone("deck.json", allocator)
	}
	return strings.concatenate({home, "/.local/share/palmy-slides/deck.json"}, allocator)
}

default_export_dir :: proc(allocator := context.allocator) -> string {
	home, err := os.user_home_dir(context.temp_allocator)
	if err != nil {
		return strings.clone("slides-export", allocator)
	}
	return strings.concatenate({home, "/Pictures/palmy-slides"}, allocator)
}
