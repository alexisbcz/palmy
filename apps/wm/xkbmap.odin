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
	code:    u32, // wayland keycode (evdev code, i.e. xkb keycode - 8)
	shift:   bool,
	// AltGr. Only the bare-metal table fills this in: on a French or German
	// keyboard @, |, {, [ and \ all live on level three, and a table of the
	// first two levels alone could not type them.
	level3:  bool,
	// With Caps Lock on, Lock by itself already produces this keysym, so the
	// extra Shift must not be added: Shift+Lock on a letter is lowercase.
	lock_ok: bool,
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
	m_level3:  u32,
	// The XKB group (layout, when several are configured) the reverse table
	// was built for, and the one wl_keyboard.modifiers announces.
	group:     u32,
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
	kt.m_level3 = XKB_MOD_INVALID

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

// keytable_from_compiled fills the same table from the keymap xkbcomp.odin
// compiled, with no libxkbcommon at all. This is the bare-metal path: the
// keymap handed to clients is `xkb_km.text`, the keysyms the input layer
// produces come out of `xkb_lookup` over the same tables, and so the reverse
// lookup `forward_key` does lands on exactly the key that was pressed.
//
// Modifier indices are the real modifiers' bit positions. A client's
// libxkbcommon always numbers Shift, Lock, Control and Mod1..Mod5 as 0..7,
// before any virtual modifier, so a mask built from them means the same thing
// on both sides of the socket.
//
// `group` picks the layout the table is for when the keymap has several; the
// compositor rebuilds it on a group switch (keyboard.odin). Levels three and
// four (AltGr, Shift+AltGr) are included so that every character the layout
// can type reaches the client.
keytable_from_compiled :: proc(kt: ^Key_Table, km: ^Xkb_Keymap, group := 0) -> bool {
	if !km.ok || km.text == "" {
		return false
	}
	first_bit :: proc(m: u32, fallback: u32) -> u32 {
		for i in u32(0) ..< 8 {
			if m & (1 << i) != 0 {
				return i
			}
		}
		return fallback
	}
	kt.m_shift = 0
	kt.m_caps = 1
	kt.m_ctrl = 2
	kt.m_alt = first_bit(xkb_mod_mask(km, {"Alt"}), 3)
	kt.m_super = first_bit(xkb_mod_mask(km, {"Super"}), 6)
	l3 := xkb_mod_mask(km, {"LevelThree"}) & 0xff
	kt.m_level3 = l3 != 0 ? first_bit(l3, 7) : XKB_MOD_INVALID
	kt.group = u32(max(group, 0))

	kt.rev = make(map[u32]Rev)
	for level in 0 ..< 4 {
		shift := level == 1 || level == 3
		third := level >= 2
		if third && l3 == 0 {
			break
		}
		mods := (shift ? XKB_MOD_SHIFT : 0) | (third ? l3 : 0)
		for code in km.min_code ..= km.max_code {
			if code < EV_XKB_OFFSET {
				continue
			}
			sym, _, _ := xkb_lookup(km, code, mods, group)
			if sym == XKB_SYM_NO || sym == XKB_SYM_VOID {
				continue
			}
			if _, taken := kt.rev[sym]; taken {
				continue
			}
			lock_ok := false
			if shift {
				lsym, _, _ := xkb_lookup(km, code, XKB_MOD_LOCK | (third ? l3 : 0), group)
				lock_ok = lsym == sym
			}
			kt.rev[sym] = Rev{code = code - EV_XKB_OFFSET, shift = shift, level3 = third, lock_ok = lock_ok}
		}
	}
	kt.text = strings.clone(km.text)
	kt.source = km.source != "" ? km.source : "the compositor's own XKB compiler"
	kt.ok = true
	return true
}
