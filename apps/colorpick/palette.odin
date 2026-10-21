package main

// The palette, as one store the window and the command line share.
//
// ~/.local/share/palmy-colorpick/palette — one `#rrggbb` per line, newest
// first, at most PALETTE_CAP lines. The window's Ctrl+S and `color save` both
// go through palette_add, Delete in the palette and `color remove` through
// palette_remove_at, so a colour saved from a terminal is the first swatch the
// next window shows, and a duplicate is refused the same way in both.

import "core:fmt"
import "core:os"
import "core:strings"

palette_dir :: proc(al := context.temp_allocator) -> string {
	home, err := os.user_home_dir(context.temp_allocator)
	if err != nil || home == "" {
		return ""
	}
	return fmt.aprintf("%s/.local/share/palmy-colorpick", home, allocator = al)
}

palette_path :: proc(al := context.temp_allocator) -> string {
	dir := palette_dir()
	if dir == "" {
		return ""
	}
	return fmt.aprintf("%s/palette", dir, allocator = al)
}

// palette_read appends the stored palette to `pal`. A missing file is an empty
// palette, not an error; unparseable lines are skipped.
palette_read :: proc(pal: ^[dynamic][3]u8) {
	path := palette_path()
	if path == "" {
		return
	}
	data, err := os.read_entire_file_from_path(path, context.temp_allocator)
	if err != nil {
		return
	}
	it := string(data)
	for line in strings.split_lines_iterator(&it) {
		if len(pal) >= PALETTE_CAP {
			break
		}
		if rgb, ok := parse_hex(strings.trim_space(line)); ok {
			append(pal, to_bytes(rgb))
		}
	}
}

// palette_write replaces the stored palette. The folder is private (0700) and
// the file 0600: a palette is harmless, but it is somebody's.
palette_write :: proc(pal: [][3]u8) -> bool {
	dir := palette_dir()
	if dir == "" {
		return false
	}
	_ = os.make_directory_all(dir)
	_ = os.chmod(dir, os.perm_number(0o700))
	b := strings.builder_make(context.temp_allocator)
	for c in pal {
		fmt.sbprintfln(&b, "#%02x%02x%02x", c[0], c[1], c[2])
	}
	path := fmt.tprintf("%s/palette", dir)
	if os.write_entire_file(path, transmute([]u8)strings.to_string(b), os.perm_number(0o600)) != nil {
		return false
	}
	_ = os.chmod(path, os.perm_number(0o600))
	return true
}

// palette_add puts a colour first, unless it is already there, and trims the
// palette to PALETTE_CAP. It returns where the colour now is.
palette_add :: proc(pal: ^[dynamic][3]u8, b: [3]u8) -> (at: int, already: bool) {
	for c, i in pal {
		if c == b {
			return i, true
		}
	}
	inject_at(pal, 0, b)
	for len(pal) > PALETTE_CAP {
		pop(pal)
	}
	return 0, false
}

palette_index :: proc(pal: [][3]u8, b: [3]u8) -> (int, bool) {
	for c, i in pal {
		if c == b {
			return i, true
		}
	}
	return -1, false
}

palette_remove_at :: proc(pal: ^[dynamic][3]u8, i: int) -> bool {
	if i < 0 || i >= len(pal) {
		return false
	}
	ordered_remove(pal, i)
	return true
}
