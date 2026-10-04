package palmy

import "core:dynlib"
import "core:strings"
import "core:sys/linux"

// ---------------------------------------------------------------------------
// Keyboard mapping.
//
// Wayland hands clients a raw XKB keymap and expects them to resolve it
// themselves. libxkbcommon is loaded lazily at runtime so that palmy links
// against nothing: if it is missing we fall back to a built-in US layout,
// which keeps shortcuts and basic typing working.
// ---------------------------------------------------------------------------

// Keysyms, matching <xkbcommon/xkbcommon-keysyms.h>.
KEY_BACKSPACE :: 0xff08
KEY_TAB       :: 0xff09
KEY_RETURN    :: 0xff0d
KEY_ESCAPE    :: 0xff1b
KEY_HOME      :: 0xff50
KEY_LEFT      :: 0xff51
KEY_UP        :: 0xff52
KEY_RIGHT     :: 0xff53
KEY_DOWN      :: 0xff54
KEY_PAGE_UP   :: 0xff55
KEY_PAGE_DOWN :: 0xff56
KEY_END       :: 0xff57
KEY_INSERT    :: 0xff63
KEY_KP_ENTER  :: 0xff8d
KEY_F1        :: 0xffbe
KEY_F2        :: 0xffbf
KEY_F3        :: 0xffc0
KEY_F4        :: 0xffc1
KEY_F5        :: 0xffc2
KEY_F11       :: 0xffc8
KEY_DELETE    :: 0xffff
KEY_SPACE     :: 0x0020

@(private)
XKB_FORMAT_TEXT_V1 :: 1
@(private)
XKB_STATE_MODS_EFFECTIVE :: 8

@(private)
Xkb :: struct {
	xkb_context_new:            proc "c" (flags: u32) -> rawptr,
	xkb_context_unref:          proc "c" (ctx: rawptr),
	xkb_keymap_new_from_string: proc "c" (ctx: rawptr, s: cstring, format, flags: u32) -> rawptr,
	xkb_keymap_unref:           proc "c" (km: rawptr),
	xkb_keymap_key_repeats:     proc "c" (km: rawptr, key: u32) -> i32,
	xkb_state_new:              proc "c" (km: rawptr) -> rawptr,
	xkb_state_unref:            proc "c" (st: rawptr),
	xkb_state_update_mask:      proc "c" (
		st: rawptr,
		depressed, latched, locked, dl, ll, locked_layout: u32,
	) -> u32,
	xkb_state_key_get_utf8:     proc "c" (st: rawptr, key: u32, buf: [^]u8, size: uint) -> i32,
	xkb_state_key_get_one_sym:  proc "c" (st: rawptr, key: u32) -> u32,
	xkb_state_mod_name_is_active: proc "c" (st: rawptr, name: cstring, type: u32) -> i32,
	__handle:                   dynlib.Library,
}

@(private)
xkb_api: Xkb
@(private)
xkb_tried: bool
@(private)
xkb_ok: bool

@(private)
xkb_load :: proc() -> bool {
	if xkb_tried {
		return xkb_ok
	}
	xkb_tried = true
	for name in ([?]string{"libxkbcommon.so.0", "libxkbcommon.so"}) {
		if _, ok := dynlib.initialize_symbols(&xkb_api, name); ok {
			xkb_ok = xkb_api.xkb_context_new != nil
			if xkb_ok {
				return true
			}
		}
	}
	return false
}

Keymap :: struct {
	ctx:     rawptr,
	keymap:  rawptr,
	state:   rawptr,
	mods:    Modifiers,

	// The XKB keymap text the compositor sent us, kept so it can be forwarded
	// verbatim to nested clients.
	text:    string,
	// Fallback bookkeeping when libxkbcommon is unavailable.
	fallback: bool,
}

// keymap_load consumes the keymap the compositor sent over the wire.
keymap_load :: proc(k: ^Keymap, fd: linux.Fd, size: int) {
	if !xkb_load() {
		k.fallback = true
		return
	}

	mem, merr := linux.mmap(0, uint(size), {.READ}, {.PRIVATE}, fd, 0)
	if merr != .NONE {
		k.fallback = true
		return
	}
	defer linux.munmap(mem, uint(size))

	// Tear down the previous keymap first: `keymap_destroy` frees the retained
	// text, so copying before this point would throw the copy away.
	keymap_destroy(k)

	// Retain the text before the mapping goes away, and before compiling, so a
	// keymap this build of libxkbcommon cannot compile can still be forwarded
	// verbatim by a nested compositor.
	k.text = strings.clone(string(cstring(mem)))

	k.ctx = xkb_api.xkb_context_new(0)
	if k.ctx == nil {
		k.fallback = true
		return
	}
	k.keymap = xkb_api.xkb_keymap_new_from_string(k.ctx, cstring(mem), XKB_FORMAT_TEXT_V1, 0)
	if k.keymap == nil {
		k.fallback = true
		return
	}
	k.state = xkb_api.xkb_state_new(k.keymap)
	k.fallback = k.state == nil
}

keymap_destroy :: proc(k: ^Keymap) {
	delete(k.text)
	k.text = ""
	if !xkb_ok {
		return
	}
	if k.state != nil {
		xkb_api.xkb_state_unref(k.state)
		k.state = nil
	}
	if k.keymap != nil {
		xkb_api.xkb_keymap_unref(k.keymap)
		k.keymap = nil
	}
	if k.ctx != nil {
		xkb_api.xkb_context_unref(k.ctx)
		k.ctx = nil
	}
}

keymap_update_mods :: proc(k: ^Keymap, depressed, latched, locked, group: u32) {
	if k.state != nil {
		xkb_api.xkb_state_update_mask(k.state, depressed, latched, locked, 0, 0, group)
		k.mods = {}
		active :: proc(k: ^Keymap, name: cstring) -> bool {
			return xkb_api.xkb_state_mod_name_is_active(k.state, name, XKB_STATE_MODS_EFFECTIVE) > 0
		}
		if active(k, "Shift")   { k.mods += {.Shift} }
		if active(k, "Control") { k.mods += {.Ctrl} }
		if active(k, "Mod1")    { k.mods += {.Alt} }
		if active(k, "Mod4")    { k.mods += {.Super} }
		if active(k, "Lock")    { k.mods += {.Caps} }
		return
	}

	// Fallback: interpret the raw modifier bitmask with the usual X11 order.
	m := depressed | latched | locked
	k.mods = {}
	if m & 1 != 0   { k.mods += {.Shift} }
	if m & 2 != 0   { k.mods += {.Caps} }
	if m & 4 != 0   { k.mods += {.Ctrl} }
	if m & 8 != 0   { k.mods += {.Alt} }
	if m & 0x40 != 0 { k.mods += {.Super} }
}

keymap_mods :: proc(k: ^Keymap) -> Modifiers {
	return k.mods
}

// keymap_sym resolves a wayland keycode to a keysym.
keymap_sym :: proc(k: ^Keymap, code: u32) -> u32 {
	if k.state != nil {
		return xkb_api.xkb_state_key_get_one_sym(k.state, code + 8)
	}
	return fallback_sym(code, .Shift in k.mods)
}

// keymap_utf8 writes the text produced by a keycode, if any.
keymap_utf8 :: proc(k: ^Keymap, code: u32, buf: []u8) -> int {
	if k.state != nil {
		n := xkb_api.xkb_state_key_get_utf8(k.state, code + 8, raw_data(buf), uint(len(buf)))
		return int(max(n, 0))
	}
	sym := fallback_sym(code, (.Shift in k.mods) != (.Caps in k.mods))
	if sym >= 0x20 && sym < 0x7f {
		buf[0] = u8(sym)
		return 1
	}
	return 0
}

keymap_repeats :: proc(k: ^Keymap, code: u32) -> bool {
	if k.keymap != nil {
		return xkb_api.xkb_keymap_key_repeats(k.keymap, code + 8) > 0
	}
	sym := fallback_sym(code, false)
	switch sym {
	case KEY_ESCAPE, KEY_RETURN, KEY_F11, 0:
		return false
	}
	return true
}

// fallback_sym maps evdev codes to keysyms for a US layout. It only runs when
// libxkbcommon could not be loaded.
@(private)
fallback_sym :: proc(code: u32, shift: bool) -> u32 {
	Row :: struct {
		code:  u32,
		plain: u32,
		upper: u32,
	}
	table := [?]Row {
		{1, KEY_ESCAPE, KEY_ESCAPE},
		{2, '1', '!'}, {3, '2', '@'}, {4, '3', '#'}, {5, '4', '$'}, {6, '5', '%'},
		{7, '6', '^'}, {8, '7', '&'}, {9, '8', '*'}, {10, '9', '('}, {11, '0', ')'},
		{12, '-', '_'}, {13, '=', '+'}, {14, KEY_BACKSPACE, KEY_BACKSPACE}, {15, KEY_TAB, KEY_TAB},
		{16, 'q', 'Q'}, {17, 'w', 'W'}, {18, 'e', 'E'}, {19, 'r', 'R'}, {20, 't', 'T'},
		{21, 'y', 'Y'}, {22, 'u', 'U'}, {23, 'i', 'I'}, {24, 'o', 'O'}, {25, 'p', 'P'},
		{26, '[', '{'}, {27, ']', '}'}, {28, KEY_RETURN, KEY_RETURN},
		{30, 'a', 'A'}, {31, 's', 'S'}, {32, 'd', 'D'}, {33, 'f', 'F'}, {34, 'g', 'G'},
		{35, 'h', 'H'}, {36, 'j', 'J'}, {37, 'k', 'K'}, {38, 'l', 'L'},
		{39, ';', ':'}, {40, '\'', '"'}, {41, '`', '~'}, {43, '\\', '|'},
		{44, 'z', 'Z'}, {45, 'x', 'X'}, {46, 'c', 'C'}, {47, 'v', 'V'}, {48, 'b', 'B'},
		{49, 'n', 'N'}, {50, 'm', 'M'}, {51, ',', '<'}, {52, '.', '>'}, {53, '/', '?'},
		{57, KEY_SPACE, KEY_SPACE},
		{59, KEY_F1, KEY_F1}, {60, KEY_F2, KEY_F2}, {61, KEY_F3, KEY_F3}, {62, KEY_F4, KEY_F4},
		{63, KEY_F5, KEY_F5}, {87, KEY_F11, KEY_F11},
		{102, KEY_HOME, KEY_HOME}, {103, KEY_UP, KEY_UP}, {104, KEY_PAGE_UP, KEY_PAGE_UP},
		{105, KEY_LEFT, KEY_LEFT}, {106, KEY_RIGHT, KEY_RIGHT}, {107, KEY_END, KEY_END},
		{108, KEY_DOWN, KEY_DOWN}, {109, KEY_PAGE_DOWN, KEY_PAGE_DOWN},
		{110, KEY_INSERT, KEY_INSERT}, {111, KEY_DELETE, KEY_DELETE},
		{96, KEY_KP_ENTER, KEY_KP_ENTER},
	}
	for row in table {
		if row.code == code {
			return shift ? row.upper : row.plain
		}
	}
	return 0
}

// keymap_text returns the XKB keymap the compositor handed this client, as the
// text the protocol carries. A nested compositor forwards it to its own clients
// so they interpret keycodes exactly as this one does.
keymap_text :: proc(k: ^Keymap) -> string {
	return k.text
}
