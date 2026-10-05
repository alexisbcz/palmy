package vt

import "core:strconv"
import "core:strings"

// ---------------------------------------------------------------------------
// OSC: Operating System Command, the `ESC ] 0 ; title BEL` family.
//
// These are the sequences that talk to the window rather than to the grid:
// the title, the working directory, hyperlinks, the clipboard and the palette.
// Two of them are security-relevant and are handled deliberately rather than
// generously -- see the note on OSC 52 below.
// ---------------------------------------------------------------------------

Osc_Kind :: enum u8 {
	Invalid,
	Set_Title,          // 0, 2
	Set_Icon,           // 1
	Set_Palette,        // 4;i;spec
	Query_Palette,      // 4;i;?
	Reset_Palette,      // 104
	Set_Pwd,            // 7
	Hyperlink_Start,    // 8;params;uri
	Hyperlink_End,      // 8;;
	Set_Default_Color,  // 10, 11, 12
	Query_Default_Color,// 10;? etc
	Reset_Default_Color,// 110, 111, 112
	Clipboard_Write,    // 52;c;<base64>
	Clipboard_Query,    // 52;c;?
	Semantic_Prompt,    // 133
	Mouse_Shape,        // 22
	Notification,       // 9, 777
	Kitty_Color,        // 21
	Reset_Cursor_Color, // 112
	// A colour operation whose payload could not be read. It is kept apart
	// from Invalid so the terminal can ignore a malformed palette change
	// without treating the sequence as something it has never heard of.
	Color_Op_Unknown,
	// ConEmu's OSC 9 subcommands. Only the progress report and the tab title
	// do anything here; the rest are recognised so they are not mistaken for
	// a desktop notification, which is what OSC 9 means without a number.
	Conemu_Sleep,       // 9;1
	Conemu_Message_Box, // 9;2
	Conemu_Tab_Title,   // 9;3
	Conemu_Progress,    // 9;4
	Conemu_Wait_Input,  // 9;5
}

// Progress_State is the ConEmu OSC 9;4 state, which is what makes a long
// download show a bar on its tab instead of nothing at all.
Progress_State :: enum u8 {
	Remove      = 0,
	Set         = 1,
	Error       = 2,
	Indetermine = 3,
	Pause       = 4,
}

// Which of the three default colours an OSC 10/11/12 refers to.
Color_Target :: enum u8 {
	Foreground = 0,
	Background = 1,
	Cursor     = 2,
}

Osc_Command :: struct {
	kind:          Osc_Kind,
	// The payload slices point into the bytes handed to osc_parse and are
	// only valid until the next read from the pty.
	text:          string, // title, icon name, pwd, uri, notification body
	id:            string, // hyperlink id= parameter
	clipboard:     string, // the base64 payload, or "?" for a query
	clipboard_sel: u8,     // 'c', 'p', 's', ...
	target:        Color_Target,
	palette_index: u8,
	color:         Rgb,
	has_color:     bool,
	progress:      Progress_State,
	progress_pct:  u8,
	terminator:    u8,
}

// osc_parse reads the body of an OSC sequence: everything between the `ESC ]`
// and the terminator, with the terminator passed separately.
osc_parse :: proc(body: []u8, terminator: u8 = 0x07) -> Osc_Command {
	s := string(body)
	cmd := Osc_Command {
		terminator = terminator,
	}

	num, rest, had_sep, ok := split_number(s)
	if !ok {
		return cmd
	}

	switch num {
	case 0, 2:
		// OSC 0 sets the icon name as well, but nothing here shows icon
		// names, so both spellings land on the title.
		if !had_sep {
			return cmd
		}
		cmd.kind = .Set_Title
		cmd.text = rest
	case 1:
		if !had_sep {
			return cmd
		}
		cmd.kind = .Set_Icon
		cmd.text = rest
	case 4:
		cmd.kind = .Color_Op_Unknown
		return osc_palette(rest, cmd)
	case 7:
		if !had_sep {
			return cmd
		}
		cmd.kind = .Set_Pwd
		cmd.text = rest
	case 8:
		if !had_sep {
			return cmd
		}
		return osc_hyperlink(rest, cmd)
	case 9:
		if !had_sep {
			return cmd
		}
		return osc_conemu(rest, cmd)
	case 10, 11, 12:
		cmd.kind = .Color_Op_Unknown
		cmd.target = Color_Target(num - 10)
		if rest == "?" {
			cmd.kind = .Query_Default_Color
		} else if rgb, cok := parse_color_spec(rest); cok {
			cmd.kind = .Set_Default_Color
			cmd.color = rgb
			cmd.has_color = true
		}
	case 21:
		if !had_sep {
			return cmd
		}
		cmd.kind = .Kitty_Color
		cmd.text = rest
	case 22:
		if !had_sep {
			return cmd
		}
		cmd.kind = .Mouse_Shape
		cmd.text = rest
	case 52:
		if !had_sep {
			return cmd
		}
		return osc_clipboard(rest, cmd)
	case 104:
		cmd.kind = .Reset_Palette
		if rest != "" {
			if i, iok := strconv.parse_int(rest); iok && i >= 0 && i <= 255 {
				cmd.palette_index = u8(i)
				cmd.has_color = true // "one index" rather than "all of them"
			}
		}
	case 110, 111, 112:
		cmd.kind = .Reset_Default_Color
		cmd.target = Color_Target(num - 110)
	case 133:
		if !had_sep {
			return cmd
		}
		// A semantic prompt marks where a prompt, its input and its output
		// begin. Only the four defined kinds count; anything else is a
		// sequence from a shell integration nobody has written yet.
		if len(rest) > 0 {
			switch rest[0] {
			case 'A', 'B', 'C', 'D':
				cmd.kind = .Semantic_Prompt
				cmd.text = rest
			}
		}
	case 777:
		if !had_sep {
			return cmd
		}
		// `777;notify;title;body` is the rxvt extension everything uses.
		if len(rest) > 7 && rest[:7] == "notify;" {
			cmd.kind = .Notification
			cmd.text = rest[7:]
		}
	}
	return cmd
}

@(private = "file")
split_number :: proc(s: string) -> (num: int, rest: string, had_sep: bool, ok: bool) {
	i := 0
	for i < len(s) && s[i] >= '0' && s[i] <= '9' {
		i += 1
	}
	if i == 0 || i > 5 {
		return 0, "", false, false
	}
	n, pok := strconv.parse_int(s[:i])
	if !pok {
		return 0, "", false, false
	}
	if i < len(s) && s[i] == ';' {
		return n, s[i + 1:], true, true
	}
	if i == len(s) {
		return n, "", false, true
	}
	return 0, "", false, false
}

// osc_conemu reads OSC 9. Without a leading number it is a desktop
// notification, which is what most programs mean; with one it is a ConEmu
// subcommand, and 9;4 -- the progress report -- is the one worth having,
// because it is how a long-running command can show a bar on its tab.
@(private = "file")
osc_conemu :: proc(rest: string, cmd_in: Osc_Command) -> Osc_Command {
	cmd := cmd_in
	if len(rest) == 0 || rest[0] < '0' || rest[0] > '9' {
		cmd.kind = .Notification
		cmd.text = rest
		return cmd
	}
	sub := rest[0] - '0'
	tail := len(rest) > 1 && rest[1] == ';' ? rest[2:] : ""
	if len(rest) > 1 && rest[1] != ';' {
		cmd.kind = .Notification
		cmd.text = rest
		return cmd
	}
	switch sub {
	case 1:
		cmd.kind = .Conemu_Sleep
		cmd.text = tail
	case 2:
		cmd.kind = .Conemu_Message_Box
		cmd.text = tail
	case 3:
		cmd.kind = .Conemu_Tab_Title
		cmd.text = tail
	case 4:
		cmd.kind = .Conemu_Progress
		st := tail
		pct := ""
		if k := strings.index_byte(tail, ';'); k >= 0 {
			st = tail[:k]
			pct = tail[k + 1:]
		}
		if v, vok := strconv.parse_int(st); vok && v >= 0 && v <= 4 {
			cmd.progress = Progress_State(v)
		}
		if v, vok := strconv.parse_int(pct); vok {
			cmd.progress_pct = u8(clamp(v, 0, 100))
		}
	case 5:
		cmd.kind = .Conemu_Wait_Input
	case:
		cmd.kind = .Notification
		cmd.text = rest
	}
	return cmd
}

@(private = "file")
osc_palette :: proc(rest: string, cmd_in: Osc_Command) -> Osc_Command {
	cmd := cmd_in
	semi := strings.index_byte(rest, ';')
	if semi < 0 {
		return cmd
	}
	idx, iok := strconv.parse_int(rest[:semi])
	if !iok || idx < 0 || idx > 255 {
		return cmd
	}
	cmd.kind = .Color_Op_Unknown
	cmd.palette_index = u8(idx)
	spec := rest[semi + 1:]
	if spec == "?" {
		cmd.kind = .Query_Palette
		return cmd
	}
	if rgb, ok := parse_color_spec(spec); ok {
		cmd.kind = .Set_Palette
		cmd.color = rgb
		cmd.has_color = true
	}
	return cmd
}

@(private = "file")
osc_hyperlink :: proc(rest: string, cmd_in: Osc_Command) -> Osc_Command {
	cmd := cmd_in
	semi := strings.index_byte(rest, ';')
	if semi < 0 {
		return cmd
	}
	params := rest[:semi]
	uri := rest[semi + 1:]
	if uri == "" {
		cmd.kind = .Hyperlink_End
		return cmd
	}
	cmd.kind = .Hyperlink_Start
	cmd.text = uri
	// Parameters are `key=value` pairs joined by colons; `id` is the only one
	// anyone implements.
	for part in strings.split_iterator(&params, ":") {
		if len(part) > 3 && part[:3] == "id=" {
			cmd.id = part[3:]
		}
	}
	return cmd
}

@(private = "file")
osc_clipboard :: proc(rest: string, cmd_in: Osc_Command) -> Osc_Command {
	cmd := cmd_in
	semi := strings.index_byte(rest, ';')
	if semi < 0 {
		return cmd
	}
	// The selection is a string of destination letters: c for the clipboard,
	// p for primary, s for whichever the configuration prefers, and 0..7 for
	// the cut buffers. Anything else is not an OSC 52 at all.
	sel := rest[:semi]
	for i in 0 ..< len(sel) {
		switch sel[i] {
		case 'c', 'p', 'q', 's', '0' ..= '7':
		case:
			return cmd
		}
	}
	cmd.clipboard_sel = len(sel) > 0 ? sel[0] : 'c'
	data := rest[semi + 1:]
	if data == "?" {
		cmd.kind = .Clipboard_Query
		return cmd
	}
	cmd.kind = .Clipboard_Write
	cmd.clipboard = data
	return cmd
}

// parse_color_spec reads the colour spellings an OSC can use: the X11
// `rgb:RR/GG/BB` form at 1, 2, 3 or 4 digits per channel, and `#RRGGBB`.
parse_color_spec :: proc(s: string) -> (Rgb, bool) {
	if len(s) > 4 && s[:4] == "rgb:" {
		body := s[4:]
		parts: [3]string
		n := 0
		start := 0
		for i := 0; i <= len(body); i += 1 {
			if i == len(body) || body[i] == '/' {
				if n >= 3 {
					return {}, false
				}
				parts[n] = body[start:i]
				n += 1
				start = i + 1
			}
		}
		if n != 3 {
			return {}, false
		}
		out: Rgb
		for i in 0 ..< 3 {
			v, ok := hex_channel(parts[i])
			if !ok {
				return {}, false
			}
			out[i] = v
		}
		return out, true
	}
	if len(s) == 7 && s[0] == '#' {
		out: Rgb
		for i in 0 ..< 3 {
			v, ok := strconv.parse_u64_of_base(s[1 + i * 2:][:2], 16)
			if !ok {
				return {}, false
			}
			out[i] = u8(v)
		}
		return out, true
	}
	if len(s) == 13 && s[0] == '#' {
		// #RRRRGGGGBBBB
		out: Rgb
		for i in 0 ..< 3 {
			v, ok := strconv.parse_u64_of_base(s[1 + i * 4:][:4], 16)
			if !ok {
				return {}, false
			}
			out[i] = u8(v >> 8)
		}
		return out, true
	}
	return {}, false
}

@(private = "file")
hex_channel :: proc(s: string) -> (u8, bool) {
	if len(s) == 0 || len(s) > 4 {
		return 0, false
	}
	v, ok := strconv.parse_u64_of_base(s, 16)
	if !ok {
		return 0, false
	}
	// Scale whatever precision was given up to eight bits.
	switch len(s) {
	case 1:
		return u8(v) * 17, true
	case 2:
		return u8(v), true
	case 3:
		return u8(v >> 4), true
	case 4:
		return u8(v >> 8), true
	}
	return 0, false
}

// ---------------------------------------------------------------------------
// base64, for OSC 52.
// ---------------------------------------------------------------------------

@(private = "file")
B64 := "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

base64_encode :: proc(src: []u8, allocator := context.allocator) -> string {
	n := (len(src) + 2) / 3 * 4
	out := make([]u8, n, allocator)
	o := 0
	i := 0
	for i + 2 < len(src) {
		v := u32(src[i]) << 16 | u32(src[i + 1]) << 8 | u32(src[i + 2])
		out[o + 0] = B64[(v >> 18) & 63]
		out[o + 1] = B64[(v >> 12) & 63]
		out[o + 2] = B64[(v >> 6) & 63]
		out[o + 3] = B64[v & 63]
		o += 4
		i += 3
	}
	switch len(src) - i {
	case 1:
		v := u32(src[i]) << 16
		out[o + 0] = B64[(v >> 18) & 63]
		out[o + 1] = B64[(v >> 12) & 63]
		out[o + 2] = '='
		out[o + 3] = '='
		o += 4
	case 2:
		v := u32(src[i]) << 16 | u32(src[i + 1]) << 8
		out[o + 0] = B64[(v >> 18) & 63]
		out[o + 1] = B64[(v >> 12) & 63]
		out[o + 2] = B64[(v >> 6) & 63]
		out[o + 3] = '='
		o += 4
	}
	return string(out[:o])
}

base64_decode :: proc(src: string, allocator := context.allocator) -> (out: []u8, ok: bool) {
	val :: proc(c: u8) -> (u8, bool) {
		switch {
		case c >= 'A' && c <= 'Z':
			return c - 'A', true
		case c >= 'a' && c <= 'z':
			return c - 'a' + 26, true
		case c >= '0' && c <= '9':
			return c - '0' + 52, true
		case c == '+':
			return 62, true
		case c == '/':
			return 63, true
		}
		return 0, false
	}
	buf := make([dynamic]u8, 0, len(src) * 3 / 4 + 3, allocator)
	acc := u32(0)
	bits := 0
	for i in 0 ..< len(src) {
		c := src[i]
		if c == '=' || c == '\n' || c == '\r' {
			continue
		}
		v, vok := val(c)
		if !vok {
			delete(buf)
			return nil, false
		}
		acc = acc << 6 | u32(v)
		bits += 6
		if bits >= 8 {
			bits -= 8
			append(&buf, u8(acc >> uint(bits)))
		}
	}
	return buf[:], true
}
