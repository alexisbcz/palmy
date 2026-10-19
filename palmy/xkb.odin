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
KEY_MENU      :: 0xff67
// The function keys are contiguous from F1: `0xffbd + n`. They stopped at F5
// and F11 here, and three applications went on to spell the rest of them
// locally, which is how `sheets` ended up with its own `KEY_F10`.
KEY_F1        :: 0xffbe
KEY_F2        :: 0xffbf
KEY_F3        :: 0xffc0
KEY_F4        :: 0xffc1
KEY_F5        :: 0xffc2
KEY_F6        :: 0xffc3
KEY_F7        :: 0xffc4
KEY_F8        :: 0xffc5
KEY_F9        :: 0xffc6
KEY_F10       :: 0xffc7
KEY_F11       :: 0xffc8
KEY_F12       :: 0xffc9
KEY_F13       :: 0xffca
KEY_F14       :: 0xffcb
KEY_F15       :: 0xffcc
KEY_F16       :: 0xffcd
KEY_F17       :: 0xffce
KEY_F18       :: 0xffcf
KEY_F19       :: 0xffd0
KEY_F20       :: 0xffd1
KEY_F21       :: 0xffd2
KEY_F22       :: 0xffd3
KEY_F23       :: 0xffd4
KEY_F24       :: 0xffd5
// The keypad. `KP_ENTER` was already here; the rest were not, and `image`
// spells `KP_ADD` and `KP_SUB` itself to zoom.
KEY_KP_MUL    :: 0xffaa
KEY_KP_ADD    :: 0xffab
KEY_KP_SUB    :: 0xffad
KEY_KP_DECIMAL :: 0xffae
KEY_KP_DIV    :: 0xffaf
KEY_KP_0      :: 0xffb0
KEY_KP_1      :: 0xffb1
KEY_KP_2      :: 0xffb2
KEY_KP_3      :: 0xffb3
KEY_KP_4      :: 0xffb4
KEY_KP_5      :: 0xffb5
KEY_KP_6      :: 0xffb6
KEY_KP_7      :: 0xffb7
KEY_KP_8      :: 0xffb8
KEY_KP_9      :: 0xffb9
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
	xkb_state_key_get_layout:   proc "c" (st: rawptr, key: u32) -> u32,
	xkb_keymap_key_get_syms_by_level: proc "c" (
		km: rawptr,
		key: u32,
		layout: u32,
		level: u32,
		syms_out: ^[^]u32,
	) -> i32,
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

	// The X11 core keyboard mapping, filled in from GetKeyboardMapping and
	// GetModifierMapping when the X11 backend is driving. It is that
	// backend's equivalent of the XKB keymap a Wayland compositor hands over:
	// the keysym values are the same XK_* constants either way, so nothing
	// above this layer can tell the two apart.
	x_syms:        []u32,
	x_per:         int,
	x_first:       u32,
	x_alt_mask:    u32,
	x_super_mask:  u32,
	x_level3_mask: u32,
	x_level3_active: bool,
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
	delete(k.x_syms)
	k.x_syms = nil
	k.x_per = 0
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

// keymap_sym resolves a keycode to a keysym. The argument is an evdev code,
// which is the X11 keycode minus 8 — the offset both windowing systems share.
keymap_sym :: proc(k: ^Keymap, code: u32) -> u32 {
	if k.x_syms != nil {
		return x_keymap_sym(k, code)
	}
	if k.state != nil {
		return xkb_api.xkb_state_key_get_one_sym(k.state, code + 8)
	}
	return fallback_sym(code, .Shift in k.mods)
}

// keymap_unshifted_sym is the keysym a key produces at its first shift
// level, in the layout currently active, whatever modifiers are held: `2` for
// the key that gives `@` with Shift on a US board, `é` on a French one. A
// terminal's key encoder needs it to tell Ctrl+Shift+2 from Ctrl+@.
keymap_unshifted_sym :: proc(k: ^Keymap, code: u32) -> u32 {
	if k.x_syms != nil {
		kc := code + 8
		if k.x_per <= 0 || kc < k.x_first {
			return 0
		}
		row := int(kc - k.x_first) * k.x_per
		if row >= len(k.x_syms) {
			return 0
		}
		// A single keysym in a group stands for a cased pair; its first
		// level is the lower case.
		return keysym_lower(k.x_syms[row])
	}
	if k.state != nil && k.keymap != nil &&
	   xkb_api.xkb_state_key_get_layout != nil && xkb_api.xkb_keymap_key_get_syms_by_level != nil {
		layout := xkb_api.xkb_state_key_get_layout(k.state, code + 8)
		syms: [^]u32
		if xkb_api.xkb_keymap_key_get_syms_by_level(k.keymap, code + 8, layout, 0, &syms) > 0 {
			return syms[0]
		}
		return 0
	}
	return fallback_sym(code, false)
}

// keymap_utf8 writes the text produced by a keycode, if any.
keymap_utf8 :: proc(k: ^Keymap, code: u32, buf: []u8) -> int {
	if k.x_syms != nil {
		return keysym_utf8(x_keymap_sym(k, code), buf)
	}
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
	if k.x_syms != nil {
		// The X11 server generates its own repeats, so palmy never has to
		// decide: the backend reports them as they arrive.
		return false
	}
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
		{63, KEY_F5, KEY_F5}, {64, KEY_F6, KEY_F6}, {65, KEY_F7, KEY_F7}, {66, KEY_F8, KEY_F8},
		{67, KEY_F9, KEY_F9}, {68, KEY_F10, KEY_F10}, {87, KEY_F11, KEY_F11}, {88, KEY_F12, KEY_F12},
		{183, KEY_F13, KEY_F13}, {184, KEY_F14, KEY_F14}, {185, KEY_F15, KEY_F15},
		{186, KEY_F16, KEY_F16}, {187, KEY_F17, KEY_F17}, {188, KEY_F18, KEY_F18},
		{189, KEY_F19, KEY_F19}, {190, KEY_F20, KEY_F20}, {191, KEY_F21, KEY_F21},
		{192, KEY_F22, KEY_F22}, {193, KEY_F23, KEY_F23}, {194, KEY_F24, KEY_F24},
		{127, KEY_MENU, KEY_MENU},
		// The keypad, as it reads with num lock on -- this fallback has no
		// lock state, and a layout that does arrives through libxkbcommon.
		{55, KEY_KP_MUL, KEY_KP_MUL}, {74, KEY_KP_SUB, KEY_KP_SUB},
		{78, KEY_KP_ADD, KEY_KP_ADD}, {98, KEY_KP_DIV, KEY_KP_DIV},
		{83, KEY_KP_DECIMAL, KEY_KP_DECIMAL},
		{82, KEY_KP_0, KEY_KP_0}, {79, KEY_KP_1, KEY_KP_1}, {80, KEY_KP_2, KEY_KP_2},
		{81, KEY_KP_3, KEY_KP_3}, {75, KEY_KP_4, KEY_KP_4}, {76, KEY_KP_5, KEY_KP_5},
		{77, KEY_KP_6, KEY_KP_6}, {71, KEY_KP_7, KEY_KP_7}, {72, KEY_KP_8, KEY_KP_8},
		{73, KEY_KP_9, KEY_KP_9},
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


// ---------------------------------------------------------------------------
// The X11 core keyboard mapping.
//
// GetKeyboardMapping hands back `keysyms-per-keycode` keysyms for every
// keycode, laid out as two groups of two levels. The protocol specifies how to
// read a short or ragged list, and how Shift and Lock pick a level; this is
// that rule, and nothing more. AltGr arrives as whichever modifier the server
// bound Mode_switch or ISO_Level3_Shift to, which GetModifierMapping reveals.
// ---------------------------------------------------------------------------

// Keysyms used while reading the modifier map.
@(private)
XK_ALT_L :: 0xffe9
@(private)
XK_ALT_R :: 0xffea
@(private)
XK_META_L :: 0xffe7
@(private)
XK_META_R :: 0xffe8
@(private)
XK_SUPER_L :: 0xffeb
@(private)
XK_SUPER_R :: 0xffec
@(private)
XK_HYPER_L :: 0xffed
@(private)
XK_MODE_SWITCH :: 0xff7e
@(private)
XK_ISO_LEVEL3_SHIFT :: 0xfe03

// X11 modifier mask bits, from the core protocol's SETofKEYMASK.
@(private)
X_MOD_SHIFT :: u32(1 << 0)
@(private)
X_MOD_LOCK :: u32(1 << 1)
@(private)
X_MOD_CONTROL :: u32(1 << 2)

// keymap_set_x11 installs a keycode-to-keysym table read from the server.
// `first` is the lowest X11 keycode the table covers.
keymap_set_x11 :: proc(k: ^Keymap, first: u32, per: int, syms: []u32) {
	delete(k.x_syms)
	k.x_syms = slice_clone_u32(syms)
	k.x_per = per
	k.x_first = first
}

// keymap_set_x11_mods records which modifier masks the server bound Alt, Super
// and the level-3 (AltGr) shift to.
keymap_set_x11_mods :: proc(k: ^Keymap, alt, super, level3: u32) {
	k.x_alt_mask = alt
	k.x_super_mask = super
	k.x_level3_mask = level3
}

// keymap_x11_state converts an X11 event's modifier mask into palmy's.
keymap_x11_state :: proc(k: ^Keymap, state: u32) -> Modifiers {
	m: Modifiers
	if state & X_MOD_SHIFT != 0 {
		m += {.Shift}
	}
	if state & X_MOD_LOCK != 0 {
		m += {.Caps}
	}
	if state & X_MOD_CONTROL != 0 {
		m += {.Ctrl}
	}
	if k.x_alt_mask != 0 && state & k.x_alt_mask != 0 {
		m += {.Alt}
	}
	if k.x_super_mask != 0 && state & k.x_super_mask != 0 {
		m += {.Super}
	}
	k.mods = m
	// Keep the raw bits so the level-3 group survives into keysym lookup.
	k.x_level3_active = k.x_level3_mask != 0 && state & k.x_level3_mask != 0
	return m
}

// x_keymap_sym applies the core protocol's level selection. `code` is an evdev
// code, so the X11 keycode is `code + 8`.
@(private)
x_keymap_sym :: proc(k: ^Keymap, code: u32) -> u32 {
	kc := code + 8
	if k.x_per <= 0 || kc < k.x_first {
		return 0
	}
	row := int(kc - k.x_first) * k.x_per
	if row + k.x_per > len(k.x_syms) {
		return 0
	}
	list := k.x_syms[row:row + k.x_per]

	// Trailing NoSymbol entries carry no information.
	n := len(list)
	for n > 0 && list[n - 1] == 0 {
		n -= 1
	}
	if n == 0 {
		return 0
	}

	// Widen a short list into two groups of two, as the protocol prescribes.
	g: [4]u32
	switch n {
	case 1:
		g = {list[0], 0, list[0], 0}
	case 2:
		g = {list[0], list[1], list[0], list[1]}
	case 3:
		g = {list[0], list[1], list[2], 0}
	case:
		g = {list[0], list[1], list[2], list[3]}
	}

	base := k.x_level3_active ? 2 : 0
	lo, hi := g[base], g[base + 1]
	if hi == 0 {
		// A single keysym for the group means a cased pair when the keysym has
		// one, and the same symbol at both levels when it does not.
		u := keysym_upper(lo)
		if u != lo {
			lo, hi = keysym_lower(lo), u
		} else {
			hi = lo
		}
	}

	shift := .Shift in k.mods
	caps := .Caps in k.mods
	sym := shift ? hi : lo
	if caps {
		// Caps Lock swaps the case of a cased keysym and leaves the rest be.
		sym = shift ? keysym_lower(sym) : keysym_upper(sym)
	}
	return sym
}

@(private)
keysym_upper :: proc(s: u32) -> u32 {
	switch {
	case s >= 'a' && s <= 'z':
		return s - 0x20
	case s >= 0xe0 && s <= 0xfe && s != 0xf7:
		return s - 0x20
	case s == 0xff: // y with diaeresis has its capital outside Latin-1
		return 0x13be
	}
	return s
}

@(private)
keysym_lower :: proc(s: u32) -> u32 {
	switch {
	case s >= 'A' && s <= 'Z':
		return s + 0x20
	case s >= 0xc0 && s <= 0xde && s != 0xd7:
		return s + 0x20
	}
	return s
}

// keysym_to_rune is the character a keysym stands for, or 0 when it stands
// for none (a function key, a modifier, the keypad). It covers what
// xkbcommon's `xkb_keysym_to_utf32` does for character keysyms: Latin-1, where
// keysym and codepoint coincide; the 0x01000000-prefixed Unicode keysyms; and
// the legacy ranges 0x0100-0x20ff -- Latin-2 to 4, Katakana, Arabic, Cyrillic,
// Greek, Hebrew, Thai, Hangul, technical and publishing symbols, the euro
// sign -- which need a table, `KEYSYM_TABLE`, generated from keysymdef.h.
keysym_to_rune :: proc(sym: u32) -> rune {
	switch {
	case sym >= 0x20 && sym <= 0x7e:
		return rune(sym)
	case sym >= 0xa0 && sym <= 0xff:
		return rune(sym)
	case sym >= 0x01000100 && sym <= 0x0110ffff:
		return rune(sym - 0x01000000)
	case sym >= 0x0100 && sym <= 0x20ff:
		lo, hi := 0, len(KEYSYM_TABLE)
		for lo < hi {
			mid := (lo + hi) / 2
			s := u32(KEYSYM_TABLE[mid].sym)
			if s == sym {
				return rune(KEYSYM_TABLE[mid].cp)
			}
			if s < sym {
				lo = mid + 1
			} else {
				hi = mid
			}
		}
	}
	return 0
}

// keysym_utf8 encodes the character a keysym stands for, if it stands for one:
// `keysym_to_rune`, plus the keypad keys that type ordinary characters.
keysym_utf8 :: proc(sym: u32, buf: []u8) -> int {
	r := keysym_rune(sym)
	if r == 0 {
		return 0
	}
	return encode_rune_into(r, buf)
}

@(private)
keysym_rune :: proc(sym: u32) -> rune {
	if r := keysym_to_rune(sym); r != 0 {
		return r
	}
	// The keypad, which produces ordinary characters.
	switch sym {
	case 0xff80:
		return ' '
	case 0xff89:
		return '\t'
	case 0xffaa:
		return '*'
	case 0xffab:
		return '+'
	case 0xffac:
		return ','
	case 0xffad:
		return '-'
	case 0xffae:
		return '.'
	case 0xffaf:
		return '/'
	case 0xffbd:
		return '='
	}
	if sym >= 0xffb0 && sym <= 0xffb9 {
		return rune('0' + (sym - 0xffb0))
	}
	return 0
}

// encode_rune_into writes one codepoint as UTF-8 and returns its length.
@(private)
encode_rune_into :: proc(r: rune, buf: []u8) -> int {
	c := u32(r)
	switch {
	case c < 0x80:
		if len(buf) < 1 {
			return 0
		}
		buf[0] = u8(c)
		return 1
	case c < 0x800:
		if len(buf) < 2 {
			return 0
		}
		buf[0] = 0xc0 | u8(c >> 6)
		buf[1] = 0x80 | u8(c & 0x3f)
		return 2
	case c < 0x10000:
		if len(buf) < 3 {
			return 0
		}
		buf[0] = 0xe0 | u8(c >> 12)
		buf[1] = 0x80 | u8((c >> 6) & 0x3f)
		buf[2] = 0x80 | u8(c & 0x3f)
		return 3
	case c <= 0x10ffff:
		if len(buf) < 4 {
			return 0
		}
		buf[0] = 0xf0 | u8(c >> 18)
		buf[1] = 0x80 | u8((c >> 12) & 0x3f)
		buf[2] = 0x80 | u8((c >> 6) & 0x3f)
		buf[3] = 0x80 | u8(c & 0x3f)
		return 4
	}
	return 0
}

@(private)
slice_clone_u32 :: proc(s: []u32) -> []u32 {
	out := make([]u32, len(s))
	copy(out, s)
	return out
}
