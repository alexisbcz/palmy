#+build wasi
package palmy

// The keyboard on the web backend. The browser has already resolved every key
// through the person's layout by the time palmy sees it: the page turns a
// KeyboardEvent into a keysym (`key`), its first-level keysym (`code`, read
// as a US board -- the DOM does not say what an unshifted key produces in
// another layout) and the text it typed, so there is no keymap to compile.
//
// The KEY_* constants and the keysym helpers (keysym_to_rune, keysym_utf8,
// encode_rune_into, ...) are not repeated here: web-build.sh lifts them out of
// xkb.odin verbatim, the rest of which loads libxkbcommon and cannot build.

Keymap :: struct {
	mods: Modifiers,
}

keymap_destroy :: proc(k: ^Keymap) {}

keymap_mods :: proc(k: ^Keymap) -> Modifiers {
	return k.mods
}

// keymap_text is the XKB keymap a compositor sent, for a nested compositor to
// forward. A browser sends none.
keymap_text :: proc(k: ^Keymap) -> string {
	return ""
}
