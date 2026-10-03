// Keycodes.
//
// palmy hands its application keysyms, not keycodes, because that is what an
// application wants. A compositor needs the opposite: wl_keyboard.key carries a
// raw evdev keycode, and the client resolves it through the keymap we gave it.
//
// So we load the host's keymap ourselves through libxkbcommon and build the
// reverse table: for every keysym the layout can produce, which keycode and
// shift level produces it. Host keysym in, keycode out, and the nested client
// sees exactly the key the user pressed.
package wm

import "core:dynlib"
import "core:strings"

Xkb_Api :: struct {
	xkb_context_new:            proc "c" (flags: u32) -> rawptr,
	xkb_context_unref:          proc "c" (ctx: rawptr),
	xkb_keymap_new_from_string: proc "c" (ctx: rawptr, s: cstring, format, flags: u32) -> rawptr,
	xkb_keymap_new_from_names:  proc "c" (ctx: rawptr, names: ^Rule_Names, flags: u32) -> rawptr,
	xkb_keymap_get_as_string:   proc "c" (km: rawptr, format: u32) -> cstring,
	xkb_keymap_unref:           proc "c" (km: rawptr),
	xkb_keymap_min_keycode:     proc "c" (km: rawptr) -> u32,
	xkb_keymap_max_keycode:     proc "c" (km: rawptr) -> u32,
	xkb_keymap_mod_get_index:   proc "c" (km: rawptr, name: cstring) -> u32,
	xkb_state_new:              proc "c" (km: rawptr) -> rawptr,
	xkb_state_unref:            proc "c" (st: rawptr),
	xkb_state_update_mask:      proc "c" (st: rawptr, d, l, lk, dl, ll, lg: u32) -> u32,
	xkb_state_key_get_one_sym:  proc "c" (st: rawptr, key: u32) -> u32,
	__handle:                   dynlib.Library,
}

// Rule_Names is struct xkb_rule_names: the RMLVO description of a layout.
Rule_Names :: struct {
	rules:   cstring,
	model:   cstring,
	layout:  cstring,
	variant: cstring,
	options: cstring,
}

xkb: Xkb_Api

Rev :: struct {
	code:  u32, // wayland keycode (evdev code, i.e. xkb keycode - 8)
	shift: bool,
}

Key_Table :: struct {
	ok:        bool,
	ctx:       rawptr,
	km:        rawptr,
	st:        rawptr,
	m_shift:   u32,
	m_ctrl:    u32,
	m_alt:     u32,
	m_super:   u32,
	m_caps:    u32,
	rev:       map[u32]Rev,

	// The keymap text handed to nested clients. It is either the one the host
	// gave us or, when that is unavailable, one we compile ourselves from the
	// host's layout so that both halves agree on what a keycode means.
	text:      string,
	source:    string,
}

XKB_MOD_INVALID :: 0xffff_ffff

xkb_load :: proc() -> bool {
	if xkb.xkb_context_new == nil {
		loaded := false
		for name in ([?]string{"libxkbcommon.so.0", "libxkbcommon.so"}) {
			if _, ok := dynlib.initialize_symbols(&xkb, name); ok && xkb.xkb_context_new != nil {
				loaded = true
				break
			}
		}
		if !loaded {
			return false
		}
	}
	return true
}

// keytable_build compiles a keymap and derives the keysym to keycode table.
//
// `host_text` is what palmy was handed by the host compositor. When it is
// empty we compile the host's own RMLVO description instead, which keeps the
// nested keymap identical to the one the user is actually typing on.
keytable_build :: proc(kt: ^Key_Table, host_text: string, names: Rule_Names) -> bool {
	if !xkb_load() {
		return false
	}

	kt.ctx = xkb.xkb_context_new(0)
	if kt.ctx == nil {
		return false
	}
	if host_text != "" {
		ctext := strings.clone_to_cstring(host_text, context.temp_allocator)
		kt.km = xkb.xkb_keymap_new_from_string(kt.ctx, ctext, 1, 0)
		kt.text = strings.clone(host_text)
		kt.source = "the host compositor"
	}
	if kt.km == nil {
		n := names
		kt.km = xkb.xkb_keymap_new_from_names(kt.ctx, &n, 0)
		kt.source = "a locally compiled layout"
		if kt.km == nil {
			return false
		}
		if cs := xkb.xkb_keymap_get_as_string(kt.km, 1); cs != nil {
			delete(kt.text)
			kt.text = strings.clone(string(cs))
		}
	}
	if kt.text == "" {
		return false
	}
	kt.st = xkb.xkb_state_new(kt.km)
	if kt.st == nil {
		return false
	}

	kt.m_shift = xkb.xkb_keymap_mod_get_index(kt.km, "Shift")
	kt.m_ctrl = xkb.xkb_keymap_mod_get_index(kt.km, "Control")
	kt.m_alt = xkb.xkb_keymap_mod_get_index(kt.km, "Mod1")
	kt.m_super = xkb.xkb_keymap_mod_get_index(kt.km, "Mod4")
	kt.m_caps = xkb.xkb_keymap_mod_get_index(kt.km, "Lock")

	kt.rev = make(map[u32]Rev)
	lo := xkb.xkb_keymap_min_keycode(kt.km)
	hi := xkb.xkb_keymap_max_keycode(kt.km)
	shift_mask := kt.m_shift == XKB_MOD_INVALID ? u32(0) : u32(1) << kt.m_shift

	for level in 0 ..< 2 {
		mask := level == 0 ? u32(0) : shift_mask
		xkb.xkb_state_update_mask(kt.st, mask, 0, 0, 0, 0, 0)
		for kc in lo ..= hi {
			sym := xkb.xkb_state_key_get_one_sym(kt.st, kc)
			if sym == 0 {
				continue
			}
			if _, taken := kt.rev[sym]; taken {
				continue
			}
			kt.rev[sym] = Rev{code = kc - 8, shift = level == 1}
		}
	}
	xkb.xkb_state_update_mask(kt.st, 0, 0, 0, 0, 0, 0)

	kt.ok = true
	return true
}

keytable_destroy :: proc(kt: ^Key_Table) {
	delete(kt.rev)
	if xkb.xkb_context_new == nil {
		return
	}
	if kt.st != nil {xkb.xkb_state_unref(kt.st)}
	if kt.km != nil {xkb.xkb_keymap_unref(kt.km)}
	if kt.ctx != nil {xkb.xkb_context_unref(kt.ctx)}
	kt^ = {}
}

// keycode_for resolves a keysym back to the keycode and shift level that
// produces it in the host layout.
keycode_for :: proc(kt: ^Key_Table, sym: u32) -> (Rev, bool) {
	if !kt.ok {
		return {}, false
	}
	v, ok := kt.rev[sym]
	return v, ok
}

mod_bit :: proc(idx: u32) -> u32 {
	if idx == XKB_MOD_INVALID {
		return 0
	}
	return u32(1) << idx
}
