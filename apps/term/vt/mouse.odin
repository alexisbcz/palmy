package vt

import "core:strings"

// ---------------------------------------------------------------------------
// Mouse reporting.
//
// Four protocols, because the first one could not count past column 223 and
// each fix was adopted before the next was invented. SGR (1006) is the one to
// use and the one everything modern asks for; the others are here because
// something old will ask for them and reporting nothing is worse than
// reporting in a legacy format.
// ---------------------------------------------------------------------------

Mouse_Button_Kind :: enum u8 {
	Left   = 0,
	Middle = 1,
	Right  = 2,
	None   = 3,
	Wheel_Up,
	Wheel_Down,
	Wheel_Left,
	Wheel_Right,
}

Mouse_Action :: enum u8 {
	Press,
	Release,
	Motion,
}

Mouse_Event :: struct {
	button: Mouse_Button_Kind,
	action: Mouse_Action,
	// Zero-based cell coordinates.
	col:    int,
	row:    int,
	mods:   u16,
}

// mouse_encode writes a report for `ev` into `out`, or returns an empty slice
// when the current mode does not want to hear about it.
mouse_encode :: proc(t: ^Terminal, ev: Mouse_Event, out: []u8) -> []u8 {
	m := t.modes.mouse
	if m == .None {
		return out[:0]
	}
	switch m {
	case .None:
		return out[:0]
	case .X10:
		if ev.action != .Press {
			return out[:0]
		}
	case .Normal:
		if ev.action == .Motion {
			return out[:0]
		}
	case .Button:
		if ev.action == .Motion && ev.button == .None {
			return out[:0]
		}
	case .Any:
	}

	code := u32(0)
	switch ev.button {
	case .Left:
		code = 0
	case .Middle:
		code = 1
	case .Right:
		code = 2
	case .None:
		code = 3
	case .Wheel_Up:
		code = 64
	case .Wheel_Down:
		code = 65
	case .Wheel_Left:
		code = 66
	case .Wheel_Right:
		code = 67
	}
	if ev.action == .Motion {
		code += 32
	}
	if ev.mods & MOD_SHIFT != 0 {
		code += 4
	}
	if ev.mods & MOD_ALT != 0 {
		code += 8
	}
	if ev.mods & MOD_CTRL != 0 {
		code += 16
	}

	b := strings.builder_from_bytes(out)
	switch t.modes.mouse_encoding {
	case .Sgr:
		write_str(&b, "\x1b[<")
		write_u32(&b, code)
		strings.write_byte(&b, ';')
		write_u32(&b, u32(ev.col + 1))
		strings.write_byte(&b, ';')
		write_u32(&b, u32(ev.row + 1))
		strings.write_byte(&b, ev.action == .Release ? 'm' : 'M')
	case .Urxvt:
		write_str(&b, "\x1b[")
		write_u32(&b, code + 32 if ev.action != .Release else 3 + 32)
		strings.write_byte(&b, ';')
		write_u32(&b, u32(ev.col + 1))
		strings.write_byte(&b, ';')
		write_u32(&b, u32(ev.row + 1))
		strings.write_byte(&b, 'M')
	case .Utf8:
		write_str(&b, "\x1b[M")
		cp := ev.action == .Release ? u32(3) : code
		buf: [4]u8
		n := utf8_encode(buf[:], rune(cp + 32))
		strings.write_bytes(&b, buf[:n])
		n = utf8_encode(buf[:], rune(ev.col + 33))
		strings.write_bytes(&b, buf[:n])
		n = utf8_encode(buf[:], rune(ev.row + 33))
		strings.write_bytes(&b, buf[:n])
	case .X10:
		// The original protocol clamps rather than overflows: a click past
		// column 223 reports column 223, which is wrong but is what every
		// implementation does and what the few remaining clients expect.
		write_str(&b, "\x1b[M")
		cp := ev.action == .Release ? u32(3) : code
		strings.write_byte(&b, u8(min(cp + 32, 255)))
		strings.write_byte(&b, u8(min(ev.col + 33, 255)))
		strings.write_byte(&b, u8(min(ev.row + 33, 255)))
	}
	return out[:strings.builder_len(b)]
}

// mouse_wants reports whether the running program is listening at all, which
// is what decides between sending a report and scrolling the scrollback.
mouse_wants :: proc(t: ^Terminal) -> bool {
	return t.modes.mouse != .None
}

// paste_wrap writes pasted text the way the program asked to receive it. With
// bracketed paste on it is fenced, so a shell can tell typed text from pasted
// text and refuse to run it.
paste_encode :: proc(t: ^Terminal, text: string, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	if t.modes.bracketed_paste {
		strings.write_string(&b, "\x1b[200~")
	}
	// A pasted newline is a carriage return to the program; and the end
	// marker is stripped out of the payload so that pasted text cannot claim
	// the paste is over and have the rest of itself executed.
	s := text
	for len(s) > 0 {
		i := strings.index(s, "\x1b[201~")
		if i < 0 {
			break
		}
		write_paste_chunk(&b, s[:i])
		s = s[i + 6:]
	}
	write_paste_chunk(&b, s)
	if t.modes.bracketed_paste {
		strings.write_string(&b, "\x1b[201~")
	}
	return strings.to_string(b)
}

@(private = "file")
write_paste_chunk :: proc(b: ^strings.Builder, s: string) {
	for i in 0 ..< len(s) {
		c := s[i]
		if c == '\n' {
			strings.write_byte(b, '\r')
			continue
		}
		strings.write_byte(b, c)
	}
}

// focus_encode reports the window gaining or losing focus, for the programs
// that asked (mode 1004).
focus_encode :: proc(t: ^Terminal, focused: bool) -> string {
	if !t.modes.focus_events {
		return ""
	}
	return focused ? "\x1b[I" : "\x1b[O"
}
