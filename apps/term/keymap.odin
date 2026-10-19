package main

import p "palmy:."
import vt "./vt"

// ---------------------------------------------------------------------------
// From a keysym to a key event.
//
// palmy hands an application X keysyms, resolved through the real keyboard
// layout. The VT key encoder wants the physical key, the modifiers and the
// text the layout produced, because that is what the Kitty protocol reports
// and what the legacy encoding needs in order to tell Ctrl+Shift+2 from
// Ctrl+@.
//
// One thing is missing and is approximated here: palmy does not report the
// *unshifted* keysym alongside the shifted one, so the unshifted codepoint is
// recovered with a US-layout reverse table. On a US or UK layout that is
// exact. On a layout where Shift+8 is not `*` it will report the wrong base
// key for that one chord, and the fix belongs in palmy rather than here --
// see the note in the report.
// ---------------------------------------------------------------------------

KEY_PRIOR :: 0xff55
KEY_NEXT :: 0xff56
KEY_KP_ENTER :: 0xff8d
KEY_KP_MULTIPLY :: 0xffaa
KEY_KP_ADD :: 0xffab
KEY_KP_SEPARATOR :: 0xffac
KEY_KP_SUBTRACT :: 0xffad
KEY_KP_DECIMAL :: 0xffae
KEY_KP_DIVIDE :: 0xffaf
KEY_KP_0 :: 0xffb0
KEY_KP_HOME :: 0xff95
KEY_KP_LEFT :: 0xff96
KEY_KP_UP :: 0xff97
KEY_KP_RIGHT :: 0xff98
KEY_KP_DOWN :: 0xff99
KEY_KP_PRIOR :: 0xff9a
KEY_KP_NEXT :: 0xff9b
KEY_KP_END :: 0xff9c
KEY_KP_BEGIN :: 0xff9d
KEY_KP_INSERT :: 0xff9e
KEY_KP_DELETE :: 0xff9f

// keysym_to_key maps a keysym to the physical key the encoder expects.
keysym_to_key :: proc(sym: u32) -> vt.Key {
	switch sym {
	case 0xff08:
		return .Backspace
	case 0xff09, 0xfe20: // Tab, ISO_Left_Tab
		return .Tab
	case 0xff0d:
		return .Enter
	case 0xff1b:
		return .Escape
	case 0xff50:
		return .Home
	case 0xff51:
		return .Arrow_Left
	case 0xff52:
		return .Arrow_Up
	case 0xff53:
		return .Arrow_Right
	case 0xff54:
		return .Arrow_Down
	case KEY_PRIOR:
		return .Page_Up
	case KEY_NEXT:
		return .Page_Down
	case 0xff57:
		return .End
	case 0xff63:
		return .Insert
	case 0xffff:
		return .Delete
	case 0xff7f:
		return .Num_Lock
	case 0xffe5:
		return .Caps_Lock
	case 0xff14:
		return .Scroll_Lock
	case 0xff13:
		return .Pause
	case 0xff61:
		return .Print_Screen
	case KEY_KP_ENTER:
		return .Numpad_Enter
	case KEY_KP_MULTIPLY:
		return .Numpad_Multiply
	case KEY_KP_ADD:
		return .Numpad_Add
	case KEY_KP_SEPARATOR:
		return .Numpad_Separator
	case KEY_KP_SUBTRACT:
		return .Numpad_Subtract
	case KEY_KP_DECIMAL:
		return .Numpad_Decimal
	case KEY_KP_DIVIDE:
		return .Numpad_Divide
	case KEY_KP_HOME:
		return .Numpad_Home
	case KEY_KP_LEFT:
		return .Numpad_Left
	case KEY_KP_UP:
		return .Numpad_Up
	case KEY_KP_RIGHT:
		return .Numpad_Right
	case KEY_KP_DOWN:
		return .Numpad_Down
	case KEY_KP_PRIOR:
		return .Numpad_Page_Up
	case KEY_KP_NEXT:
		return .Numpad_Page_Down
	case KEY_KP_END:
		return .Numpad_End
	case KEY_KP_BEGIN:
		return .Numpad_Begin
	case KEY_KP_INSERT:
		return .Numpad_Insert
	case KEY_KP_DELETE:
		return .Numpad_Delete
	case 0xffe1, 0xffe2:
		return sym == 0xffe1 ? .Shift_Left : .Shift_Right
	case 0xffe3, 0xffe4:
		return sym == 0xffe3 ? .Control_Left : .Control_Right
	case 0xffe9, 0xffea:
		return sym == 0xffe9 ? .Alt_Left : .Alt_Right
	case 0xffeb, 0xffec:
		return sym == 0xffeb ? .Meta_Left : .Meta_Right
	case 0xfe03: // ISO_Level3_Shift, i.e. AltGr
		return .Alt_Right
	}
	if sym >= KEY_KP_0 && sym <= KEY_KP_0 + 9 {
		return vt.Key(int(vt.Key.Numpad_0) + int(sym - KEY_KP_0))
	}
	if sym >= 0xffbe && sym <= 0xffbe + 24 {
		return vt.Key(int(vt.Key.F1) + int(sym - 0xffbe))
	}

	cp := keysym_codepoint(sym)
	if cp == 0 {
		return .Unidentified
	}
	base := unshift_us(cp)
	if base >= 'a' && base <= 'z' {
		return vt.Key(int(vt.Key.A) + int(base - 'a'))
	}
	if base >= '0' && base <= '9' {
		return vt.Key(int(vt.Key.Digit_0) + int(base - '0'))
	}
	switch base {
	case ' ':
		return .Space
	case '-':
		return .Minus
	case '=':
		return .Equal
	case '[':
		return .Bracket_Left
	case ']':
		return .Bracket_Right
	case '\\':
		return .Backslash
	case ';':
		return .Semicolon
	case '\'':
		return .Quote
	case '`':
		return .Backquote
	case ',':
		return .Comma
	case '.':
		return .Period
	case '/':
		return .Slash
	}
	return .Unidentified
}

// keysym_codepoint turns a keysym into the character it stands for, following
// xkbcommon's xkb_keysym_to_utf32: Latin-1 keysyms are their own codepoint,
// everything above 0x01000000 carries one directly, and the legacy ranges
// (Cyrillic, Greek, Arabic, Hebrew, the euro sign...) go through the table
// palmy generates from keysymdef.h. See `p.keysym_to_rune`.
keysym_codepoint :: proc(sym: u32) -> rune {
	return p.keysym_to_rune(sym)
}

// unshift_us undoes a US layout's shift for the characters where it matters.
unshift_us :: proc(cp: rune) -> rune {
	if cp >= 'A' && cp <= 'Z' {
		return cp + 32
	}
	switch cp {
	case '!':
		return '1'
	case '@':
		return '2'
	case '#':
		return '3'
	case '$':
		return '4'
	case '%':
		return '5'
	case '^':
		return '6'
	case '&':
		return '7'
	case '*':
		return '8'
	case '(':
		return '9'
	case ')':
		return '0'
	case '_':
		return '-'
	case '+':
		return '='
	case '{':
		return '['
	case '}':
		return ']'
	case '|':
		return '\\'
	case ':':
		return ';'
	case '"':
		return '\''
	case '~':
		return '`'
	case '<':
		return ','
	case '>':
		return '.'
	case '?':
		return '/'
	}
	return cp
}

mods_from_palmy :: proc(m: p.Modifiers) -> u16 {
	out := u16(0)
	if .Shift in m {
		out |= vt.MOD_SHIFT
	}
	if .Ctrl in m {
		out |= vt.MOD_CTRL
	}
	if .Alt in m {
		out |= vt.MOD_ALT
	}
	if .Super in m {
		out |= vt.MOD_SUPER
	}
	if .Caps in m {
		out |= vt.MOD_CAPS
	}
	return out
}

// key_event_from builds the encoder's input from one palmy key event.
key_event_from :: proc(k: p.Key_Event, buf: []u8) -> vt.Key_Event {
	ev := vt.Key_Event {
		action = k.repeat ? .Repeat : .Press,
		key    = keysym_to_key(k.sym),
		mods   = mods_from_palmy(k.mods),
	}
	cp := keysym_codepoint(k.sym)
	if cp != 0 {
		n := vt.utf8_encode(buf, cp)
		ev.utf8 = string(buf[:n])
		ev.unshifted_codepoint = unshift_us(cp)
		// palmy reports the key's own first-level keysym now, which is
		// right on every layout; the US reverse table is only the fallback
		// for input that did not carry it.
		if k.unshifted != 0 {
			if r := p.keysym_to_rune(k.unshifted); r != 0 {
				ev.unshifted_codepoint = r
			}
		}
	}
	// A control chord has no text: the layout would have produced the
	// control character and the encoder works that out for itself.
	if ev.mods & (vt.MOD_CTRL | vt.MOD_SUPER) != 0 && cp != 0 && cp < 0x80 {
		// Keep the text; the encoder's control table reads it.
	}
	return ev
}
