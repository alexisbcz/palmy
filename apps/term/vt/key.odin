package vt

import "core:strings"

// ---------------------------------------------------------------------------
// Turning a key press into bytes.
//
// This is the fiddliest part of a terminal and the part users notice first:
// every shell, editor and TUI has its own idea of what Ctrl+Left should send,
// and the answer depends on four terminal modes and whether the application
// has asked for the Kitty keyboard protocol. It is also the part this codebase
// has a real oracle for -- libghostty-vt exports Ghostty's encoder -- so the
// differential test in apps/term/oracle drives it rather than a hand-written
// table of expectations.
// ---------------------------------------------------------------------------

Key_Action :: enum u8 {
	Release = 0,
	Press   = 1,
	Repeat  = 2,
}

// Modifier bits, numbered to match libghostty's GhosttyMods.
MOD_SHIFT :: u16(1 << 0)
MOD_CTRL :: u16(1 << 1)
MOD_ALT :: u16(1 << 2)
MOD_SUPER :: u16(1 << 3)
MOD_CAPS :: u16(1 << 4)
MOD_NUM :: u16(1 << 5)
MOD_SHIFT_RIGHT :: u16(1 << 6)
MOD_CTRL_RIGHT :: u16(1 << 7)
MOD_ALT_RIGHT :: u16(1 << 8)
MOD_SUPER_RIGHT :: u16(1 << 9)

Key_Event :: struct {
	action:              Key_Action,
	key:                 Key,
	mods:                u16,
	// Modifiers the keyboard layout already used up producing `utf8`. On a
	// German layout AltGr+8 is `[`, and the Alt must not also be reported.
	consumed_mods:       u16,
	composing:           bool,
	utf8:                string,
	unshifted_codepoint: rune,
}

// Kitty keyboard protocol flags, as the application sets them with CSI > flags u.
KITTY_DISAMBIGUATE :: u8(1 << 0)
KITTY_REPORT_EVENTS :: u8(1 << 1)
KITTY_REPORT_ALTERNATES :: u8(1 << 2)
KITTY_REPORT_ALL :: u8(1 << 3)
KITTY_REPORT_ASSOCIATED :: u8(1 << 4)

Key_Encoder :: struct {
	cursor_key_application:     bool, // DECCKM, mode 1
	keypad_key_application:     bool, // mode 66
	ignore_keypad_with_numlock: bool, // mode 1035
	alt_esc_prefix:             bool, // mode 1036
	modify_other_keys_state_2:  bool, // xterm modifyOtherKeys 2
	kitty_flags:                u8,
}

// effective_mods drops the modifiers the layout consumed.
@(private = "file")
effective_mods :: proc(ev: Key_Event) -> u16 {
	return ev.mods & ~ev.consumed_mods
}

// binding_mods is the set that matters for deciding what a key means: the four
// real modifiers, with the lock states and the left/right sides removed.
@(private = "file")
binding_mods :: proc(m: u16) -> u16 {
	return m & (MOD_SHIFT | MOD_CTRL | MOD_ALT | MOD_SUPER)
}

// ---------------------------------------------------------------------------
// The functional-key table.
//
// `code` is the number the Kitty protocol uses, `final` the byte that ends the
// sequence. A 'u' or '~' final means the code is written out; a letter final
// (A, B, C, D, H, F, P, Q, S) means the legacy form `CSI 1 ; mods <letter>`.
// ---------------------------------------------------------------------------

Kitty_Entry :: struct {
	key:   Key,
	code:  u32,
	final: u8,
}

KITTY_ENTRIES := [?]Kitty_Entry {
	{.Escape, 27, 'u'},
	{.Enter, 13, 'u'},
	{.Tab, 9, 'u'},
	{.Backspace, 127, 'u'},
	{.Insert, 2, '~'},
	{.Delete, 3, '~'},
	{.Arrow_Left, 1, 'D'},
	{.Arrow_Right, 1, 'C'},
	{.Arrow_Up, 1, 'A'},
	{.Arrow_Down, 1, 'B'},
	{.Page_Up, 5, '~'},
	{.Page_Down, 6, '~'},
	{.Home, 1, 'H'},
	{.End, 1, 'F'},
	{.Caps_Lock, 57358, 'u'},
	{.Scroll_Lock, 57359, 'u'},
	{.Num_Lock, 57360, 'u'},
	{.Print_Screen, 57361, 'u'},
	{.Pause, 57362, 'u'},
	{.F1, 1, 'P'},
	{.F2, 1, 'Q'},
	{.F3, 13, '~'},
	{.F4, 1, 'S'},
	{.F5, 15, '~'},
	{.F6, 17, '~'},
	{.F7, 18, '~'},
	{.F8, 19, '~'},
	{.F9, 20, '~'},
	{.F10, 21, '~'},
	{.F11, 23, '~'},
	{.F12, 24, '~'},
	{.F13, 57376, 'u'},
	{.F14, 57377, 'u'},
	{.F15, 57378, 'u'},
	{.F16, 57379, 'u'},
	{.F17, 57380, 'u'},
	{.F18, 57381, 'u'},
	{.F19, 57382, 'u'},
	{.F20, 57383, 'u'},
	{.F21, 57384, 'u'},
	{.F22, 57385, 'u'},
	{.F23, 57386, 'u'},
	{.F24, 57387, 'u'},
	{.F25, 57388, 'u'},
	{.Numpad_0, 57399, 'u'},
	{.Numpad_1, 57400, 'u'},
	{.Numpad_2, 57401, 'u'},
	{.Numpad_3, 57402, 'u'},
	{.Numpad_4, 57403, 'u'},
	{.Numpad_5, 57404, 'u'},
	{.Numpad_6, 57405, 'u'},
	{.Numpad_7, 57406, 'u'},
	{.Numpad_8, 57407, 'u'},
	{.Numpad_9, 57408, 'u'},
	{.Numpad_Decimal, 57409, 'u'},
	{.Numpad_Divide, 57410, 'u'},
	{.Numpad_Multiply, 57411, 'u'},
	{.Numpad_Subtract, 57412, 'u'},
	{.Numpad_Add, 57413, 'u'},
	{.Numpad_Enter, 57414, 'u'},
	{.Numpad_Equal, 57415, 'u'},
	{.Numpad_Separator, 57416, 'u'},
	{.Numpad_Left, 57417, 'u'},
	{.Numpad_Right, 57418, 'u'},
	{.Numpad_Up, 57419, 'u'},
	{.Numpad_Down, 57420, 'u'},
	{.Numpad_Page_Up, 57421, 'u'},
	{.Numpad_Page_Down, 57422, 'u'},
	{.Numpad_Home, 57423, 'u'},
	{.Numpad_End, 57424, 'u'},
	{.Numpad_Insert, 57425, 'u'},
	{.Numpad_Delete, 57426, 'u'},
	{.Numpad_Begin, 57427, 'u'},
	{.Shift_Left, 57441, 'u'},
	{.Control_Left, 57442, 'u'},
	{.Alt_Left, 57443, 'u'},
	{.Meta_Left, 57444, 'u'},
	{.Shift_Right, 57447, 'u'},
	{.Control_Right, 57448, 'u'},
	{.Alt_Right, 57449, 'u'},
	{.Meta_Right, 57450, 'u'},
}

@(private = "file")
kitty_entry :: proc(k: Key) -> (Kitty_Entry, bool) {
	for e in KITTY_ENTRIES {
		if e.key == k {
			return e, true
		}
	}
	return {}, false
}

// is_modifier_key reports whether the key is itself a modifier, which never
// produces bytes outside the Kitty protocol.
@(private = "file")
is_modifier_key :: proc(k: Key) -> bool {
	#partial switch k {
	case .Shift_Left, .Shift_Right, .Control_Left, .Control_Right,
	     .Alt_Left, .Alt_Right, .Meta_Left, .Meta_Right,
	     .Caps_Lock, .Num_Lock:
		return true
	}
	return false
}

@(private = "file")
is_keypad_key :: proc(k: Key) -> bool {
	#partial switch k {
	case .Numpad_0, .Numpad_1, .Numpad_2, .Numpad_3, .Numpad_4, .Numpad_5,
	     .Numpad_6, .Numpad_7, .Numpad_8, .Numpad_9, .Numpad_Decimal,
	     .Numpad_Divide, .Numpad_Multiply, .Numpad_Subtract, .Numpad_Add,
	     .Numpad_Enter, .Numpad_Equal, .Numpad_Separator:
		return true
	}
	return false
}

// kitty_mod_value is the `modifiers` field: a one-based bitmask.
@(private = "file")
kitty_mod_value :: proc(m: u16) -> u32 {
	v := u32(0)
	if m & MOD_SHIFT != 0 {v |= 1}
	if m & MOD_ALT != 0 {v |= 2}
	if m & MOD_CTRL != 0 {v |= 4}
	if m & MOD_SUPER != 0 {v |= 8}
	if m & MOD_CAPS != 0 {v |= 64}
	if m & MOD_NUM != 0 {v |= 128}
	return v + 1
}

// legacy_mod_value is the same idea for the xterm forms, which never carry the
// lock states.
@(private = "file")
legacy_mod_value :: proc(m: u16) -> u32 {
	v := u32(0)
	if m & MOD_SHIFT != 0 {v |= 1}
	if m & MOD_ALT != 0 {v |= 2}
	if m & MOD_CTRL != 0 {v |= 4}
	if m & MOD_SUPER != 0 {v |= 8}
	return v + 1
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

// key_encode writes the bytes a key event should send into `out` and returns
// the slice that was written. An empty slice means the key sends nothing,
// which is normal: a bare Shift press does not.
key_encode :: proc(e: Key_Encoder, ev: Key_Event, out: []u8) -> []u8 {
	b := strings.builder_from_bytes(out)
	if ev.composing {
		return out[:0]
	}
	if e.kitty_flags != 0 {
		kitty_encode(e, ev, &b)
	} else {
		legacy_encode(e, ev, &b)
	}
	return out[:strings.builder_len(b)]
}

// ---------------------------------------------------------------------------
// The shared pieces
// ---------------------------------------------------------------------------

// Functional describes a key that has a CSI form: the number for the `CSI n ~`
// spelling, or a final letter for the `CSI 1 ; m X` spelling.
@(private = "file")
Functional :: struct {
	num:    u32, // non-zero for the `~` form
	letter: u8,  // non-zero for the letter form
	ss3:    bool, // may be written as SS3 when there are no modifiers
}

@(private = "file")
functional_of :: proc(k: Key) -> (Functional, bool) {
	#partial switch k {
	case .Arrow_Up:
		return {letter = 'A', ss3 = true}, true
	case .Arrow_Down:
		return {letter = 'B', ss3 = true}, true
	case .Arrow_Right:
		return {letter = 'C', ss3 = true}, true
	case .Arrow_Left:
		return {letter = 'D', ss3 = true}, true
	case .Home:
		return {letter = 'H', ss3 = true}, true
	case .End:
		return {letter = 'F', ss3 = true}, true
	case .Numpad_Begin:
		return {letter = 'E', ss3 = true}, true
	case .Insert:
		return {num = 2}, true
	case .Delete:
		return {num = 3}, true
	case .Page_Up:
		return {num = 5}, true
	case .Page_Down:
		return {num = 6}, true
	case .F1:
		return {letter = 'P', ss3 = true}, true
	case .F2:
		return {letter = 'Q', ss3 = true}, true
	case .F3:
		return {letter = 'R', ss3 = true}, true
	case .F4:
		return {letter = 'S', ss3 = true}, true
	case .F5:
		return {num = 15}, true
	case .F6:
		return {num = 17}, true
	case .F7:
		return {num = 18}, true
	case .F8:
		return {num = 19}, true
	case .F9:
		return {num = 20}, true
	case .F10:
		return {num = 21}, true
	case .F11:
		return {num = 23}, true
	case .F12:
		return {num = 24}, true
	}
	return {}, false
}

// write_functional writes the CSI form. `ss3_ok` lets the caller say whether
// an unmodified cursor key may use the SS3 spelling, which the legacy encoding
// does in application-cursor mode and the Kitty protocol never does.
@(private = "file")
write_functional :: proc(b: ^strings.Builder, f: Functional, mods: u32, ss3_ok: bool) {
	if f.num != 0 {
		write_str(b, "\x1b[")
		write_u32(b, f.num)
		if mods > 1 {
			strings.write_byte(b, ';')
			write_u32(b, mods)
		}
		strings.write_byte(b, '~')
		return
	}
	if mods > 1 {
		write_str(b, "\x1b[1;")
		write_u32(b, mods)
		strings.write_byte(b, f.letter)
		return
	}
	write_str(b, ss3_ok ? "\x1bO" : "\x1b[")
	strings.write_byte(b, f.letter)
}

// text_codepoint picks the character a key event stands for: what the layout
// produced, falling back to the unshifted key.
@(private = "file")
text_codepoint :: proc(ev: Key_Event) -> rune {
	if len(ev.utf8) > 0 {
		for r in ev.utf8 {
			return r
		}
	}
	return ev.unshifted_codepoint
}

// ctrl_code maps a character to the control character Ctrl+<it> sends.
//
// The three gaps matter. Ctrl+I would be 0x09 and Ctrl+M would be 0x0D, which
// are Tab and Enter, and Ctrl+[ would be 0x1B, which is Escape. Collapsing
// them loses information the application may want, so those three go through
// the CSI u fallback instead and the real Tab, Enter and Escape keys keep the
// control characters to themselves.
@(private = "file")
ctrl_code :: proc(cp: rune) -> (u8, bool) {
	switch cp {
	case ' ', '2':
		return 0x00, true
	case 'a' ..= 'z':
		if cp == 'i' || cp == 'm' {
			return 0, false
		}
		return u8(cp - 'a' + 1), true
	case '3':
		return 0x1B, true
	case '4', '\\':
		return 0x1C, true
	case '5', ']':
		return 0x1D, true
	case '6', '~', '^':
		return 0x1E, true
	case '7', '/', '_':
		return 0x1F, true
	case '8', '?':
		return 0x7F, true
	}
	return 0, false
}

// numpad_char is the character a keypad key stands for when the keypad is in
// numeric mode, which is where it spends almost all its life. The platform
// does not always hand one over, and a terminal that drops Ctrl+KP_4 is a
// terminal somebody will file a bug about.
@(private = "file")
numpad_char :: proc(k: Key) -> (rune, bool) {
	#partial switch k {
	case .Numpad_0:
		return '0', true
	case .Numpad_1:
		return '1', true
	case .Numpad_2:
		return '2', true
	case .Numpad_3:
		return '3', true
	case .Numpad_4:
		return '4', true
	case .Numpad_5:
		return '5', true
	case .Numpad_6:
		return '6', true
	case .Numpad_7:
		return '7', true
	case .Numpad_8:
		return '8', true
	case .Numpad_9:
		return '9', true
	case .Numpad_Decimal:
		return '.', true
	case .Numpad_Divide:
		return '/', true
	case .Numpad_Multiply:
		return '*', true
	case .Numpad_Subtract:
		return '-', true
	case .Numpad_Add:
		return '+', true
	case .Numpad_Equal:
		return '=', true
	}
	return 0, false
}

// numpad_alias maps the keypad's navigation keys onto the ordinary ones. In
// the legacy encoding KP_Left and Left are the same key.
@(private = "file")
numpad_alias :: proc(k: Key) -> (Key, bool) {
	#partial switch k {
	case .Numpad_Left:
		return .Arrow_Left, true
	case .Numpad_Right:
		return .Arrow_Right, true
	case .Numpad_Up:
		return .Arrow_Up, true
	case .Numpad_Down:
		return .Arrow_Down, true
	case .Numpad_Home:
		return .Home, true
	case .Numpad_End:
		return .End, true
	case .Numpad_Page_Up:
		return .Page_Up, true
	case .Numpad_Page_Down:
		return .Page_Down, true
	case .Numpad_Insert:
		return .Insert, true
	case .Numpad_Delete:
		return .Delete, true
	}
	return k, false
}

// csi_u_number works out what number to put in a `CSI n ; m u`, and which
// modifiers are still worth reporting once the character has absorbed them.
//
// Shift is the awkward one. On `Ctrl+Shift+A` the layout produced "A" and the
// right answer is "the A key, with shift" -- lowercase the letter and keep the
// modifier. On `Ctrl+Shift+2` the layout produced "@", which is already the
// shifted thing, so reporting shift as well would be saying it twice.
@(private = "file")
csi_u_number :: proc(ev: Key_Event, bind: u16) -> (cp: rune, mods: u16) {
	cp = text_codepoint(ev)
	mods = bind & (MOD_SHIFT | MOD_CTRL | MOD_ALT)
	if cp >= 'A' && cp <= 'Z' {
		cp += 32
		return
	}
	if bind & MOD_SHIFT != 0 && ev.unshifted_codepoint != 0 && cp != ev.unshifted_codepoint {
		mods &= ~MOD_SHIFT
	}
	return
}

@(private = "file")
write_csi_u :: proc(b: ^strings.Builder, cp: rune, mods: u32) {
	write_str(b, "\x1b[")
	write_u32(b, u32(cp))
	if mods > 1 {
		strings.write_byte(b, ';')
		write_u32(b, mods)
	}
	strings.write_byte(b, 'u')
}

// ---------------------------------------------------------------------------
// Legacy (xterm / VT) encoding
// ---------------------------------------------------------------------------

@(private = "file")
legacy_encode :: proc(e: Key_Encoder, ev: Key_Event, b: ^strings.Builder) {
	if ev.action == .Release || is_modifier_key(ev.key) {
		return
	}
	bind := binding_mods(effective_mods(ev))
	alt := bind & MOD_ALT != 0
	ctrl := bind & MOD_CTRL != 0
	shift := bind & MOD_SHIFT != 0
	super := bind & MOD_SUPER != 0
	m := legacy_mod_value(bind)

	key := ev.key
	if aliased, ok := numpad_alias(key); ok {
		key = aliased
	}

	if f, ok := functional_of(key); ok {
		// Modified F3 cannot use `CSI 1 ; m R`: that is the shape of the
		// cursor-position report an application may be waiting for, and
		// xterm has always written the `13 ~` form instead.
		if key == .F3 && m > 1 {
			f = {num = 13}
		}
		write_functional(b, f, m, e.cursor_key_application || f.letter == 'P' ||
			f.letter == 'Q' || f.letter == 'R' || f.letter == 'S')
		return
	}

	// Enter, Tab and Escape own a control character, so a modified one has
	// nowhere to go but xterm's modifyOtherKeys form.
	if key == .Numpad_Enter {
		// The keypad Enter sends a bare carriage return whatever is held
		// down. It has no modifyOtherKeys spelling because the main Enter
		// already owns code 13.
		strings.write_byte(b, '\r')
		return
	}

	code := u32(0)
	#partial switch key {
	case .Enter:
		code = 13
	case .Tab:
		code = 9
	case .Escape:
		code = 27
	}
	if code != 0 {
		if key == .Tab && bind == MOD_SHIFT {
			write_str(b, "\x1b[Z")
			return
		}
		if ctrl || shift || super {
			write_str(b, "\x1b[27;")
			write_u32(b, m)
			strings.write_byte(b, ';')
			write_u32(b, code)
			strings.write_byte(b, '~')
			return
		}
		if alt {
			strings.write_byte(b, 0x1b)
		}
		strings.write_byte(b, u8(code))
		return
	}

	if key == .Backspace {
		if alt {
			strings.write_byte(b, 0x1b)
		}
		strings.write_byte(b, ctrl ? 0x08 : 0x7F)
		return
	}

	if ctrl {
		cp := text_codepoint(ev)
		if cp == 0 && !shift {
			// The platform often sends no text for a keypad key. In numeric
			// mode it stands for its digit, and Ctrl+KP_4 should behave like
			// Ctrl+4 rather than vanish.
			if c, ok := numpad_char(key); ok {
				cp = c
			}
		}
		if cp == 0 {
			return
		}
		if !super {
			if c, ok := ctrl_code(cp); ok {
				// Alt always prefixes a control character with an escape;
				// mode 1036 only governs the ordinary text case.
				if alt {
					strings.write_byte(b, 0x1b)
				}
				strings.write_byte(b, c)
				return
			}
			// A digit with no control character of its own sends itself.
			// Ctrl+1 is not a thing, and swallowing it would be worse than
			// typing a 1.
			if cp >= '0' && cp <= '9' {
				if alt {
					strings.write_byte(b, 0x1b)
				}
				strings.write_byte(b, u8(cp))
				return
			}
		}
		ncp, nmods := csi_u_number(ev, bind)
		if ncp == 0 {
			return
		}
		write_csi_u(b, ncp, legacy_mod_value(nmods))
		return
	}

	if len(ev.utf8) > 0 {
		if alt && e.alt_esc_prefix {
			strings.write_byte(b, 0x1b)
		}
		write_str(b, ev.utf8)
	}
}

// ---------------------------------------------------------------------------
// Kitty keyboard protocol
// ---------------------------------------------------------------------------

@(private = "file")
kitty_encode :: proc(e: Key_Encoder, ev: Key_Event, b: ^strings.Builder) {
	flags := e.kitty_flags
	report_events := flags & KITTY_REPORT_EVENTS != 0
	report_alternates := flags & KITTY_REPORT_ALTERNATES != 0
	report_all := flags & KITTY_REPORT_ALL != 0
	report_text := flags & KITTY_REPORT_ASSOCIATED != 0

	if ev.action == .Release && !report_events {
		return
	}

	bind := binding_mods(effective_mods(ev))
	entry, has_entry := kitty_entry(ev.key)
	modifier_key := is_modifier_key(ev.key)

	if modifier_key && !report_all {
		return
	}

	// With only "disambiguate" set, anything that already has an unambiguous
	// legacy encoding keeps it. That is the point of the lowest flag: make
	// Ctrl+I distinguishable from Tab without changing what Tab sends.
	locks := ev.mods & (MOD_CAPS | MOD_NUM)
	extra := flags & ~KITTY_DISAMBIGUATE

	// A functional key with a letter final keeps the CSI letter spelling --
	// `CSI A` for Up rather than `CSI 57352 u` -- because every application
	// already understands it and the protocol gains nothing by changing it.
	if has_entry && entry.final != 'u' && entry.final != '~' {
		mods := kitty_mod_value(bind | locks)
		if !report_events {
			write_functional(b, {letter = entry.final}, mods, false)
			return
		}
		write_str(b, "\x1b[1;")
		write_u32(b, mods)
		if report_events {
			strings.write_byte(b, ':')
			write_u32(b, event_type(ev.action))
		}
		strings.write_byte(b, entry.final)
		return
	}

	// With only "disambiguate" set -- and optionally event reporting, which
	// changes nothing about a press -- the keys that are not ambiguous keep
	// their legacy bytes. Enter, Tab and Backspace are unambiguous when
	// nothing is held down; Escape never is, which is the whole reason the
	// flag exists.
	if extra & KITTY_REPORT_ALL == 0 {
		legacy_key := false
		#partial switch ev.key {
		case .Enter, .Tab, .Backspace:
			legacy_key = true
		}
		if legacy_key {
			// These three keep their control characters. A release has no
			// legacy spelling at all, so unless the application asked for
			// every event it hears nothing.
			if ev.action == .Release {
				return
			}
			if bind == 0 {
				legacy_encode(e, ev, b)
				return
			}
		} else if ev.action != .Release && bind == 0 && !has_entry && !modifier_key {
			legacy_encode(e, ev, b)
			return
		}
	}

	key_code := u32(0)
	final := u8('u')
	if has_entry {
		final = entry.final
		key_code = entry.code
	} else {
		cp := ev.unshifted_codepoint
		if cp == 0 {
			cp = text_codepoint(ev)
		}
		if cp == 0 {
			return
		}
		if cp >= 'A' && cp <= 'Z' {
			cp += 32
		}
		key_code = u32(cp)
	}

	// The alternate key is the shifted character, so an application can tell
	// Shift+2 from @ on a layout where they are not the same key.
	alt_code := u32(0)
	if report_alternates && bind & MOD_SHIFT != 0 && len(ev.utf8) > 0 {
		c := text_codepoint(ev)
		if u32(c) != key_code {
			alt_code = u32(c)
		}
	}

	mods := kitty_mod_value(bind | locks)
	evt := event_type(ev.action)

	text: string
	if report_text && ev.action != .Release && bind & (MOD_CTRL | MOD_ALT | MOD_SUPER) == 0 {
		if len(ev.utf8) > 0 && printable(ev.utf8) {
			text = ev.utf8
		}
	}

	// The base-layout key: what the physical key would produce on a plain
	// US layout. Only the keypad needs it -- its functional code says "the
	// keypad 4 key" and an application still wants to know that means "4".
	base_code := u32(0)
	if report_alternates {
		if c, ok := numpad_char(ev.key); ok {
			base_code = u32(c)
		}
	}

	write_str(b, "\x1b[")
	write_u32(b, key_code)
	if alt_code != 0 || base_code != 0 {
		strings.write_byte(b, ':')
		if alt_code != 0 {
			write_u32(b, alt_code)
		}
		if base_code != 0 {
			strings.write_byte(b, ':')
			write_u32(b, base_code)
		}
	}
	need_event := report_events && evt != 1
	if mods > 1 || need_event || len(text) > 0 {
		strings.write_byte(b, ';')
		if mods > 1 || need_event {
			write_u32(b, mods)
			if need_event {
				strings.write_byte(b, ':')
				write_u32(b, evt)
			}
		}
	}
	if len(text) > 0 {
		strings.write_byte(b, ';')
		first := true
		for r in text {
			if !first {
				strings.write_byte(b, ':')
			}
			first = false
			write_u32(b, u32(r))
		}
	}
	strings.write_byte(b, final)
}

@(private = "file")
event_type :: proc(a: Key_Action) -> u32 {
	switch a {
	case .Press:
		return 1
	case .Repeat:
		return 2
	case .Release:
		return 3
	}
	return 1
}

@(private = "file")
printable :: proc(s: string) -> bool {
	for r in s {
		if r < 0x20 || r == 0x7F {
			return false
		}
	}
	return len(s) > 0
}

// ---------------------------------------------------------------------------
// Small writers. A terminal writes a lot of short integers.
// ---------------------------------------------------------------------------

@(private)
write_str :: proc(b: ^strings.Builder, s: string) {
	strings.write_string(b, s)
}

@(private)
write_u32 :: proc(b: ^strings.Builder, v: u32) {
	if v >= 10 {
		write_u32(b, v / 10)
	}
	strings.write_byte(b, u8('0' + v % 10))
}
