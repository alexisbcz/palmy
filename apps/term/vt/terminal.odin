package vt

import "core:strings"

// ---------------------------------------------------------------------------
// The terminal.
//
// This is where the parser's actions become changes to the grid. It is the
// one file that has to know what `ESC [ 2 J` means, and the one place a
// program's output and a person's expectations have to agree.
// ---------------------------------------------------------------------------

Cursor :: struct {
	x, y:     int,
	// Set once the cursor has been pushed past the right edge but before
	// anything has been printed there. The next printable character wraps.
	// Without this a line that exactly fills the width wraps one character
	// too early, which is the classic "last column" bug.
	pending:  bool,
	pen:      Pen,
	charset:  [4]Charset,
	gl, gr:   int,
	// Set by SS2 and SS3, which shift to G2 or G3 for exactly one character.
	single_shift: int,
	origin:   bool,
}

Charset :: enum u8 {
	Ascii,
	Dec_Special, // the line-drawing set, which is how ncurses draws boxes
	Uk,
}

Mouse_Mode :: enum u8 {
	None,
	X10,     // 9:   press only
	Normal,  // 1000: press and release
	Button,  // 1002: and drag
	Any,     // 1003: and plain motion
}

Mouse_Encoding :: enum u8 {
	X10,  // the original, broken past column 223
	Sgr,  // 1006
	Utf8, // 1005
	Urxvt, // 1015
}

Modes :: struct {
	cursor_keys_app:   bool, // 1   DECCKM
	reverse_video:     bool, // 5   DECSCNM
	origin:            bool, // 6   DECOM
	autowrap:          bool, // 7   DECAWM
	cursor_visible:    bool, // 25  DECTCEM
	cursor_blink:      bool, // 12
	keypad_app:        bool, // 66  DECNKM
	ignore_keypad_num: bool, // 1035
	alt_esc_prefix:    bool, // 1036
	mouse:             Mouse_Mode,
	mouse_encoding:    Mouse_Encoding,
	focus_events:      bool, // 1004
	bracketed_paste:   bool, // 2004
	synchronized:      bool, // 2026
	insert:            bool, // IRM
	linefeed_newline:  bool, // LNM
	reverse_wrap:      bool, // 45
	modify_other_keys: bool,
	sixel_display:     bool, // 80  DECSDM: sixels at the top left, no scrolling
}

Terminal :: struct {
	parser:        Parser,
	cols, rows:    int,
	primary:       Screen,
	alt:           Screen,
	on_alt:        bool,
	cursor:        Cursor,
	saved:         [2]Cursor,
	modes:         Modes,
	top, bot:      int, // the scroll region, inclusive, zero based
	tabs:          [dynamic]bool,
	palette:       [256]Rgb,
	default_fg:    Rgb,
	default_bg:    Rgb,
	default_cursor: Rgb,
	fg_override:   Maybe(Rgb),
	bg_override:   Maybe(Rgb),

	// Everything the embedder needs to look at after a feed.
	title:         string,
	icon_title:    string,
	pwd:           string,
	bell:          int,
	progress:      Progress_State,
	progress_pct:  u8,
	// Bytes the terminal wants written back to the pty: replies to queries,
	// mouse reports, and so on.
	out:           [dynamic]u8,
	// Clipboard writes requested by OSC 52. Reads are refused; see the note
	// in osc_dispatch.
	clipboard_set: string,
	clipboard_pending: bool,

	kitty_stack:   [dynamic]u8,

	// Scrollback viewing offset, in lines above the bottom. Zero means the
	// live screen.
	view_offset:   int,

	// DCS collection, used for DECRQSS.
	dcs_kind:      u8,
	dcs_buf:       [dynamic]u8,

	// Set whenever anything changed, so a sleeping frame loop knows there is
	// something to draw.
	damaged:       bool,

	// Images: Sixel and the Kitty graphics protocol. See graphics.odin.
	gfx:           Graphics,
	sixel:         Sixel,
}

DEFAULT_SCROLLBACK :: 10_000

terminal_init :: proc(t: ^Terminal, cols, rows: int, scrollback := DEFAULT_SCROLLBACK) {
	t.cols = max(cols, 1)
	t.rows = max(rows, 1)
	screen_init(&t.primary, t.cols, t.rows, scrollback)
	screen_init(&t.alt, t.cols, t.rows, 0)
	t.tabs = make([dynamic]bool, t.cols)
	reset_tabs(t)
	t.out = make([dynamic]u8)
	t.dcs_buf = make([dynamic]u8)
	t.kitty_stack = make([dynamic]u8)
	append(&t.kitty_stack, 0)
	default_palette(&t.palette)
	t.default_fg = {0xE2, 0xE8, 0xF0}
	t.default_bg = {0x0B, 0x11, 0x20}
	t.default_cursor = {0xE2, 0xE8, 0xF0}
	t.modes.autowrap = true
	t.modes.cursor_visible = true
	t.top = 0
	t.bot = t.rows - 1
	graphics_init(&t.gfx)
	parser_init(&t.parser, Sink{user = t, fn = on_action})
}

terminal_destroy :: proc(t: ^Terminal) {
	// The screens first: releasing their rows releases placements, which
	// the image store has to still be there to receive.
	screen_destroy(&t.primary)
	screen_destroy(&t.alt)
	graphics_destroy(&t.gfx)
	sixel_reset(&t.sixel)
	parser_destroy(&t.parser)
	delete(t.tabs)
	delete(t.out)
	delete(t.dcs_buf)
	delete(t.kitty_stack)
	delete(t.title)
	delete(t.icon_title)
	delete(t.pwd)
	delete(t.clipboard_set)
}

screen :: proc(t: ^Terminal) -> ^Screen {
	return t.on_alt ? &t.alt : &t.primary
}

terminal_feed :: proc(t: ^Terminal, data: []u8) {
	parse(&t.parser, data)
}

// terminal_take_output hands over anything the terminal wants to write back
// and empties the buffer.
terminal_take_output :: proc(t: ^Terminal) -> []u8 {
	if len(t.out) == 0 {
		return nil
	}
	b := make([]u8, len(t.out))
	copy(b, t.out[:])
	clear(&t.out)
	return b
}

reply :: proc(t: ^Terminal, s: string) {
	append(&t.out, s)
}

reply_u32 :: proc(t: ^Terminal, v: u32) {
	buf: [12]u8
	n := 0
	x := v
	if x == 0 {
		append(&t.out, u8('0'))
		return
	}
	for x > 0 {
		buf[n] = u8('0' + x % 10)
		n += 1
		x /= 10
	}
	for i := n - 1; i >= 0; i -= 1 {
		append(&t.out, buf[i])
	}
}

@(private = "file")
reset_tabs :: proc(t: ^Terminal) {
	resize(&t.tabs, t.cols)
	for i in 0 ..< t.cols {
		t.tabs[i] = i > 0 && i % 8 == 0
	}
}

// ---------------------------------------------------------------------------
// Action dispatch
// ---------------------------------------------------------------------------

@(private = "file")
on_action :: proc(user: rawptr, a: Action) {
	t := (^Terminal)(user)
	t.damaged = true
	switch a.kind {
	case .Print:
		print_rune(t, a.cp)
	case .Execute:
		execute(t, a.b)
	case .Esc_Dispatch:
		esc_dispatch(t, a)
	case .Csi_Dispatch:
		csi_dispatch(t, a)
	case .Osc_Dispatch:
		osc_dispatch(t, a)
	case .Dcs_Hook:
		clear(&t.dcs_buf)
		t.dcs_kind = a.b
		if len(a.intermediates) > 0 {
			t.dcs_kind = a.intermediates[0] | 0x80 // mark that it had one
		}
		if a.b == 'q' && len(a.intermediates) == 1 && a.intermediates[0] == '$' {
			t.dcs_kind = 'Q' // DECRQSS
		} else if a.b == 'q' && len(a.intermediates) == 0 {
			t.dcs_kind = 'S' // Sixel
			sixel_begin(t, a)
		} else {
			t.dcs_kind = 0
		}
	case .Dcs_Put:
		if t.dcs_kind == 'S' {
			sixel_put(&t.sixel, a.b)
		} else if len(t.dcs_buf) < MAX_DCS {
			append(&t.dcs_buf, a.b)
		}
	case .Dcs_Unhook:
		if t.dcs_kind == 'S' {
			t.dcs_kind = 0
			sixel_end(t)
		} else {
			dcs_finish(t)
		}
	case .Apc_Dispatch:
		if len(a.osc) > 0 && a.osc[0] == 'G' {
			kitty_command(t, a.osc[1:])
		}
	}
}

// ---------------------------------------------------------------------------
// Printing
// ---------------------------------------------------------------------------

@(private = "file")
cell_at :: proc(t: ^Terminal, x, y: int) -> ^Cell {
	s := screen(t)
	if y < 0 || y >= len(s.lines) {
		return nil
	}
	r := &s.lines[y]
	if x < 0 || x >= len(r.cells) {
		return nil
	}
	r.dirty = true
	return &r.cells[x]
}

@(private = "file")
print_rune :: proc(t: ^Terminal, r0: rune) {
	s := screen(t)
	r := translate_charset(t, r0)

	// A zero-width mark belongs to the cell before the cursor, not to a cell
	// of its own. This is what keeps "é" written as e + U+0301 in one cell.
	if is_combining(r) {
		x := t.cursor.x
		if t.cursor.pending {
			x = t.cols
		}
		x -= 1
		for x >= 0 {
			c := cell_at(t, x, t.cursor.y)
			if c == nil {
				return
			}
			if .Spacer in c.attrs {
				x -= 1
				continue
			}
			screen_grapheme_append(s, c, r)
			return
		}
		return
	}

	w := rune_width(r)
	if w == 0 {
		w = 1
	}

	if t.cursor.pending && t.modes.autowrap {
		// The deferred wrap finally happens.
		mark_wrapped(t)
		t.cursor.x = 0
		cursor_down_scroll(t)
		t.cursor.pending = false
	}

	if t.cursor.x + w > t.cols {
		if t.modes.autowrap {
			mark_wrapped(t)
			t.cursor.x = 0
			cursor_down_scroll(t)
		} else {
			// Without autowrap the last column is overwritten forever.
			t.cursor.x = t.cols - w
			if t.cursor.x < 0 {
				t.cursor.x = 0
			}
		}
	}

	if t.modes.insert {
		insert_chars(t, w)
	}

	c := cell_at(t, t.cursor.x, t.cursor.y)
	if c == nil {
		return
	}
	// Overwriting half of a wide character has to clear the other half, or
	// the screen keeps a stray spacer that nothing will ever draw over.
	clear_wide_at(t, t.cursor.x, t.cursor.y)
	c^ = Cell {
		ch    = r,
		fg    = t.cursor.pen.fg,
		bg    = t.cursor.pen.bg,
		ul    = t.cursor.pen.ul,
		attrs = t.cursor.pen.attrs,
		under = t.cursor.pen.under,
		link  = t.cursor.pen.link,
	}
	if w == 2 {
		c.attrs |= {.Wide}
		if sp := cell_at(t, t.cursor.x + 1, t.cursor.y); sp != nil {
			sp^ = Cell {
				ch    = 0,
				fg    = t.cursor.pen.fg,
				bg    = t.cursor.pen.bg,
				attrs = t.cursor.pen.attrs | {.Spacer},
			}
		}
	}

	// Text replaces the part of a Sixel image it lands on.
	if row := &s.lines[t.cursor.y]; row.frags != nil {
		row_cut(row, t.cursor.x, t.cursor.x + w)
	}

	t.cursor.x += w
	if t.cursor.x >= t.cols {
		t.cursor.x = t.cols - 1
		t.cursor.pending = true
	}
}

@(private = "file")
mark_wrapped :: proc(t: ^Terminal) {
	s := screen(t)
	if t.cursor.y >= 0 && t.cursor.y < len(s.lines) {
		s.lines[t.cursor.y].wrapped = true
	}
}

// clear_wide_at removes the other half of a two-cell character that the given
// position is part of.
@(private = "file")
clear_wide_at :: proc(t: ^Terminal, x, y: int) {
	c := cell_at(t, x, y)
	if c == nil {
		return
	}
	if .Wide in c.attrs {
		if sp := cell_at(t, x + 1, y); sp != nil && .Spacer in sp.attrs {
			sp^ = blank_cell(t.cursor.pen)
		}
	}
	if .Spacer in c.attrs {
		if lead := cell_at(t, x - 1, y); lead != nil && .Wide in lead.attrs {
			lead^ = blank_cell(t.cursor.pen)
		}
	}
}

@(private = "file")
translate_charset :: proc(t: ^Terminal, r: rune) -> rune {
	slot := t.cursor.gl
	if t.cursor.single_shift != 0 {
		slot = t.cursor.single_shift
		t.cursor.single_shift = 0
	}
	if r < 0x20 || r > 0x7E {
		return r
	}
	switch t.cursor.charset[slot] {
	case .Ascii:
		return r
	case .Uk:
		return r == '#' ? '£' : r
	case .Dec_Special:
		return dec_special(r)
	}
	return r
}

// dec_special is the VT100 line-drawing set. Every box ncurses draws comes
// through here, so getting it wrong turns a dialog into a field of letters.
@(private = "file")
dec_special :: proc(r: rune) -> rune {
	switch r {
	case '`': return '◆'
	case 'a': return '▒'
	case 'b': return '␉'
	case 'c': return '␌'
	case 'd': return '␍'
	case 'e': return '␊'
	case 'f': return '°'
	case 'g': return '±'
	case 'h': return '␤'
	case 'i': return '␋'
	case 'j': return '┘'
	case 'k': return '┐'
	case 'l': return '┌'
	case 'm': return '└'
	case 'n': return '┼'
	case 'o': return '⎺'
	case 'p': return '⎻'
	case 'q': return '─'
	case 'r': return '⎼'
	case 's': return '⎽'
	case 't': return '├'
	case 'u': return '┤'
	case 'v': return '┴'
	case 'w': return '┬'
	case 'x': return '│'
	case 'y': return '≤'
	case 'z': return '≥'
	case '{': return 'π'
	case '|': return '≠'
	case '}': return '£'
	case '~': return '·'
	case '_': return ' '
	}
	return r
}

// ---------------------------------------------------------------------------
// C0 controls
// ---------------------------------------------------------------------------

@(private = "file")
execute :: proc(t: ^Terminal, b: u8) {
	switch b {
	case 0x07: // BEL
		t.bell += 1
	case 0x08: // BS
		if t.cursor.pending {
			t.cursor.pending = false
		} else if t.cursor.x > 0 {
			t.cursor.x -= 1
		} else if t.modes.reverse_wrap && t.cursor.y > t.top {
			t.cursor.y -= 1
			t.cursor.x = t.cols - 1
		}
	case 0x09: // HT
		tab_forward(t, 1)
	case 0x0A, 0x0B, 0x0C: // LF, VT, FF
		cursor_down_scroll(t)
		t.cursor.pending = false
		if t.modes.linefeed_newline {
			t.cursor.x = 0
		}
	case 0x0D: // CR
		t.cursor.x = 0
		t.cursor.pending = false
	case 0x0E: // SO
		t.cursor.gl = 1
	case 0x0F: // SI
		t.cursor.gl = 0
	case 0x84: // IND
		cursor_down_scroll(t)
	case 0x85: // NEL
		t.cursor.x = 0
		cursor_down_scroll(t)
	case 0x88: // HTS
		if t.cursor.x < len(t.tabs) {
			t.tabs[t.cursor.x] = true
		}
	case 0x8D: // RI
		reverse_index(t)
	}
}

cursor_down_scroll :: proc(t: ^Terminal) {
	if t.cursor.y == t.bot {
		screen_scroll_up(screen(t), t.top, t.bot, 1, t.cursor.pen, !t.on_alt)
	} else if t.cursor.y < t.rows - 1 {
		t.cursor.y += 1
	}
}

@(private = "file")
reverse_index :: proc(t: ^Terminal) {
	if t.cursor.y == t.top {
		screen_scroll_down(screen(t), t.top, t.bot, 1, t.cursor.pen)
	} else if t.cursor.y > 0 {
		t.cursor.y -= 1
	}
}

@(private = "file")
tab_forward :: proc(t: ^Terminal, n: int) {
	for _ in 0 ..< max(n, 1) {
		x := t.cursor.x + 1
		for x < t.cols && !t.tabs[x] {
			x += 1
		}
		t.cursor.x = min(x, t.cols - 1)
	}
	t.cursor.pending = false
}

@(private = "file")
tab_back :: proc(t: ^Terminal, n: int) {
	for _ in 0 ..< max(n, 1) {
		x := t.cursor.x - 1
		for x > 0 && !t.tabs[x] {
			x -= 1
		}
		t.cursor.x = max(x, 0)
	}
}

// ---------------------------------------------------------------------------
// ESC sequences
// ---------------------------------------------------------------------------

@(private = "file")
esc_dispatch :: proc(t: ^Terminal, a: Action) {
	if len(a.intermediates) == 1 {
		i := a.intermediates[0]
		switch i {
		case '(', ')', '*', '+':
			slot := int(i - '(')
			cs := Charset.Ascii
			switch a.b {
			case '0':
				cs = .Dec_Special
			case 'A':
				cs = .Uk
			}
			t.cursor.charset[slot] = cs
			return
		case '#':
			if a.b == '8' {
				// DECALN: fill the screen with E. It exists to line up a
				// CRT, and it is the one sequence that proves a terminal's
				// grid geometry in one keystroke.
				s := screen(t)
				for &row in s.lines {
					for i in 0 ..< len(row.cells) {
						row.cells[i] = Cell{ch = 'E'}
					}
					row.dirty = true
				}
				t.cursor.x, t.cursor.y = 0, 0
			}
			return
		}
		return
	}

	switch a.b {
	case '7': // DECSC
		t.saved[t.on_alt ? 1 : 0] = t.cursor
	case '8': // DECRC
		restore_cursor(t)
	case 'D': // IND
		cursor_down_scroll(t)
	case 'E': // NEL
		t.cursor.x = 0
		cursor_down_scroll(t)
	case 'H': // HTS
		if t.cursor.x < len(t.tabs) {
			t.tabs[t.cursor.x] = true
		}
	case 'M': // RI
		reverse_index(t)
	case 'c': // RIS
		terminal_reset(t)
	case '=': // DECKPAM
		t.modes.keypad_app = true
	case '>': // DECKPNM
		t.modes.keypad_app = false
	case 'n': // LS2
		t.cursor.gl = 2
	case 'o': // LS3
		t.cursor.gl = 3
	case 'N': // SS2
		t.cursor.single_shift = 2
	case 'O': // SS3
		t.cursor.single_shift = 3
	}
}

@(private = "file")
restore_cursor :: proc(t: ^Terminal) {
	t.cursor = t.saved[t.on_alt ? 1 : 0]
	t.cursor.x = clamp(t.cursor.x, 0, t.cols - 1)
	t.cursor.y = clamp(t.cursor.y, 0, t.rows - 1)
}

terminal_reset :: proc(t: ^Terminal) {
	t.cursor = {}
	t.cursor.pen = {}
	t.saved = {}
	t.modes = {}
	t.modes.autowrap = true
	t.modes.cursor_visible = true
	t.on_alt = false
	t.top = 0
	t.bot = t.rows - 1
	t.view_offset = 0
	t.fg_override = nil
	t.bg_override = nil
	// A full reset forgets every image, as kitty and xterm do.
	for pl in t.gfx.placements {
		pl.doomed = true
	}
	purge_doomed(t)
	for len(t.gfx.images) > 0 {
		image_delete(t, t.gfx.images[len(t.gfx.images) - 1])
	}
	kitty_load_reset(&t.gfx.kitty)
	default_palette(&t.palette)
	reset_tabs(t)
	clear(&t.kitty_stack)
	append(&t.kitty_stack, 0)
	erase_screen(t, 2)
	screen_mark_all_dirty(&t.primary)
	screen_mark_all_dirty(&t.alt)
}

// ---------------------------------------------------------------------------
// CSI sequences
// ---------------------------------------------------------------------------

@(private = "file")
csi_dispatch :: proc(t: ^Terminal, a: Action) {
	p0 := int(param(a, 0, 1))
	p0z := int(param(a, 0, 0))

	if a.private == '?' {
		switch a.b {
		case 'h':
			for i in 0 ..< max(param_count(a), 1) {
				set_dec_mode(t, int(param(a, i, 0)), true)
			}
		case 'l':
			for i in 0 ..< max(param_count(a), 1) {
				set_dec_mode(t, int(param(a, i, 0)), false)
			}
		case 's':
			// XTSAVE: nothing here keeps a mode stack deep enough to care.
		case 'r':
		case 'u':
			// Query the Kitty keyboard flags.
			reply(t, "\x1b[?")
			reply_u32(t, u32(kitty_flags(t)))
			reply(t, "u")
		case 'S':
			xtsmgraphics(t, a)
		case 'n':
			if p0z == 6 {
				// DECXCPR, the private cursor report.
				reply(t, "\x1b[?")
				reply_u32(t, u32(t.cursor.y + 1))
				reply(t, ";")
				reply_u32(t, u32(t.cursor.x + 1))
				reply(t, "R")
			}
		}
		return
	}

	if a.private == '>' {
		switch a.b {
		case 'c': // Secondary device attributes
			reply(t, "\x1b[>1;10;0c")
		case 'u': // Push Kitty keyboard flags
			append(&t.kitty_stack, u8(param(a, 0, 0) & 0x1F))
			if len(t.kitty_stack) > 16 {
				ordered_remove(&t.kitty_stack, 0)
			}
		case 'q': // XTVERSION
			reply(t, "\x1bP>|palmy-term 1.0\x1b\\")
		case 'm':
			t.modes.modify_other_keys = param(a, 0, 0) == 4 && param(a, 1, 0) >= 1
		}
		return
	}

	if a.private == '<' {
		if a.b == 'u' {
			n := max(1, int(param(a, 0, 1)))
			for _ in 0 ..< n {
				if len(t.kitty_stack) > 1 {
					pop(&t.kitty_stack)
				}
			}
		}
		return
	}

	if a.private == '=' {
		if a.b == 'u' {
			// Set Kitty flags with a mode: 1 set, 2 or, 3 and-not.
			f := u8(param(a, 0, 0) & 0x1F)
			mode := int(param(a, 1, 1))
			cur := kitty_flags(t)
			switch mode {
			case 1:
				cur = f
			case 2:
				cur |= f
			case 3:
				cur &= ~f
			}
			t.kitty_stack[len(t.kitty_stack) - 1] = cur
		}
		return
	}

	if len(a.intermediates) > 0 {
		switch a.intermediates[0] {
		case ' ':
			if a.b == 'q' {
				// DECSCUSR: the cursor shape. 0 and 1 blink a block, 2 is a
				// steady block, 3/4 underline, 5/6 bar.
				t.modes.cursor_blink = p0z == 0 || p0z % 2 == 1
			}
		case '!':
			if a.b == 'p' {
				// DECSTR, the soft reset. Unlike RIS it keeps the screen.
				soft_reset(t)
			}
		case '$':
			if a.b == 'p' {
				report_mode(t, int(param(a, 0, 0)), false)
			}
		case '"':
			if a.b == 'q' {
				// DECSCA
				if p0z == 1 {
					t.cursor.pen.attrs |= {.Protected}
				} else {
					t.cursor.pen.attrs &= ~Attrs{.Protected}
				}
			}
		}
		return
	}

	switch a.b {
	case '@': // ICH
		insert_chars(t, p0)
	case 'A': // CUU
		move_cursor(t, t.cursor.x, t.cursor.y - p0)
	case 'B', 'e': // CUD, VPR
		move_cursor(t, t.cursor.x, t.cursor.y + p0)
	case 'C', 'a': // CUF, HPR
		move_cursor(t, t.cursor.x + p0, t.cursor.y)
	case 'D': // CUB
		move_cursor(t, t.cursor.x - p0, t.cursor.y)
	case 'E': // CNL
		move_cursor(t, 0, t.cursor.y + p0)
	case 'F': // CPL
		move_cursor(t, 0, t.cursor.y - p0)
	case 'G', '`': // CHA, HPA
		move_cursor(t, p0 - 1, t.cursor.y)
	case 'H', 'f': // CUP, HVP
		y := int(param(a, 0, 1)) - 1
		x := int(param(a, 1, 1)) - 1
		if t.cursor.origin {
			y += t.top
		}
		move_cursor(t, x, y)
	case 'I': // CHT
		tab_forward(t, p0)
	case 'J': // ED
		erase_screen(t, p0z)
	case 'K': // EL
		erase_line(t, p0z)
	case 'L': // IL
		if t.cursor.y >= t.top && t.cursor.y <= t.bot {
			screen_scroll_down(screen(t), t.cursor.y, t.bot, p0, t.cursor.pen)
		}
	case 'M': // DL
		if t.cursor.y >= t.top && t.cursor.y <= t.bot {
			screen_scroll_up(screen(t), t.cursor.y, t.bot, p0, t.cursor.pen, false)
		}
	case 'P': // DCH
		delete_chars(t, p0)
	case 'S': // SU
		screen_scroll_up(screen(t), t.top, t.bot, p0, t.cursor.pen, false)
	case 'T': // SD
		screen_scroll_down(screen(t), t.top, t.bot, p0, t.cursor.pen)
	case 'X': // ECH
		erase_chars(t, p0)
	case 'Z': // CBT
		tab_back(t, p0)
	case 'b': // REP
		repeat_last(t, p0)
	case 'd': // VPA
		y := p0 - 1
		if t.cursor.origin {
			y += t.top
		}
		move_cursor(t, t.cursor.x, y)
	case 'c': // DA1 -- a VT220 with colour and Sixel (the 4), which is what
		// img2sixel, chafa and every other Sixel program look for.
		reply(t, "\x1b[?62;4;22c")
	case 'g': // TBC
		switch p0z {
		case 0:
			if t.cursor.x < len(t.tabs) {
				t.tabs[t.cursor.x] = false
			}
		case 3:
			for i in 0 ..< len(t.tabs) {
				t.tabs[i] = false
			}
		}
	case 'h':
		for i in 0 ..< max(param_count(a), 1) {
			set_ansi_mode(t, int(param(a, i, 0)), true)
		}
	case 'l':
		for i in 0 ..< max(param_count(a), 1) {
			set_ansi_mode(t, int(param(a, i, 0)), false)
		}
	case 'm':
		apply_sgr(t, a)
	case 'n':
		switch p0z {
		case 5:
			reply(t, "\x1b[0n")
		case 6:
			y := t.cursor.y
			if t.cursor.origin {
				y -= t.top
			}
			reply(t, "\x1b[")
			reply_u32(t, u32(y + 1))
			reply(t, ";")
			reply_u32(t, u32(t.cursor.x + 1))
			reply(t, "R")
		}
	case 'r': // DECSTBM
		top := int(param(a, 0, 1)) - 1
		bot := int(param(a, 1, u16(t.rows))) - 1
		if top < 0 {
			top = 0
		}
		if bot >= t.rows {
			bot = t.rows - 1
		}
		if top < bot {
			t.top = top
			t.bot = bot
			t.cursor.x = 0
			t.cursor.y = t.cursor.origin ? t.top : 0
			t.cursor.pending = false
		}
	case 's': // Save cursor
		t.saved[t.on_alt ? 1 : 0] = t.cursor
	case 'u': // Restore cursor
		restore_cursor(t)
	case 't': // Window operations
		window_op(t, a)
	}
}

@(private = "file")
kitty_flags :: proc(t: ^Terminal) -> u8 {
	if len(t.kitty_stack) == 0 {
		return 0
	}
	return t.kitty_stack[len(t.kitty_stack) - 1]
}

// terminal_kitty_flags is what the key encoder needs.
terminal_kitty_flags :: proc(t: ^Terminal) -> u8 {
	return kitty_flags(t)
}

@(private = "file")
soft_reset :: proc(t: ^Terminal) {
	t.cursor.pen = {}
	t.cursor.origin = false
	t.cursor.charset = {}
	t.cursor.gl, t.cursor.gr = 0, 2
	t.modes.autowrap = true
	t.modes.cursor_visible = true
	t.modes.insert = false
	t.modes.origin = false
	t.top = 0
	t.bot = t.rows - 1
	t.saved[t.on_alt ? 1 : 0] = t.cursor
}

@(private = "file")
window_op :: proc(t: ^Terminal, a: Action) {
	switch int(param(a, 0, 0)) {
	case 14: // Report the text area in pixels: rows and columns of cells.
		reply(t, "\x1b[4;")
		reply_u32(t, u32(t.rows * t.gfx.cell_h))
		reply(t, ";")
		reply_u32(t, u32(t.cols * t.gfx.cell_w))
		reply(t, "t")
	case 16: // Report the cell size in pixels, which is what an image
		// program sizes its output by.
		reply(t, "\x1b[6;")
		reply_u32(t, u32(t.gfx.cell_h))
		reply(t, ";")
		reply_u32(t, u32(t.gfx.cell_w))
		reply(t, "t")
	case 18: // Report the size in characters
		reply(t, "\x1b[8;")
		reply_u32(t, u32(t.rows))
		reply(t, ";")
		reply_u32(t, u32(t.cols))
		reply(t, "t")
	case 19:
		reply(t, "\x1b[9;")
		reply_u32(t, u32(t.rows))
		reply(t, ";")
		reply_u32(t, u32(t.cols))
		reply(t, "t")
	case 11:
		reply(t, "\x1b[1t")
	case 21:
		reply(t, "\x1b]l")
		reply(t, t.title)
		reply(t, "\x1b\\")
	}
}

@(private = "file")
report_mode :: proc(t: ^Terminal, m: int, dec: bool) {
	// DECRPM: 0 not recognised, 1 set, 2 reset.
	reply(t, "\x1b[")
	reply_u32(t, u32(m))
	reply(t, ";0$y")
}

@(private = "file")
move_cursor :: proc(t: ^Terminal, x, y: int) {
	lo, hi := 0, t.rows - 1
	if t.cursor.origin {
		lo, hi = t.top, t.bot
	}
	t.cursor.x = clamp(x, 0, t.cols - 1)
	t.cursor.y = clamp(y, lo, hi)
	t.cursor.pending = false
}

@(private = "file")
insert_chars :: proc(t: ^Terminal, n: int) {
	s := screen(t)
	if t.cursor.y >= len(s.lines) {
		return
	}
	row := &s.lines[t.cursor.y]
	row.dirty = true
	count := min(max(n, 1), t.cols - t.cursor.x)
	for i := t.cols - 1; i >= t.cursor.x + count; i -= 1 {
		row.cells[i] = row.cells[i - count]
	}
	b := blank_cell(t.cursor.pen)
	for i in t.cursor.x ..< t.cursor.x + count {
		row.cells[i] = b
	}
}

@(private = "file")
delete_chars :: proc(t: ^Terminal, n: int) {
	s := screen(t)
	if t.cursor.y >= len(s.lines) {
		return
	}
	row := &s.lines[t.cursor.y]
	row.dirty = true
	count := min(max(n, 1), t.cols - t.cursor.x)
	for i := t.cursor.x; i < t.cols - count; i += 1 {
		row.cells[i] = row.cells[i + count]
	}
	b := blank_cell(t.cursor.pen)
	for i in t.cols - count ..< t.cols {
		row.cells[i] = b
	}
}

@(private = "file")
erase_chars :: proc(t: ^Terminal, n: int) {
	s := screen(t)
	if t.cursor.y >= len(s.lines) {
		return
	}
	row := &s.lines[t.cursor.y]
	row.dirty = true
	b := blank_cell(t.cursor.pen)
	for i in t.cursor.x ..< min(t.cursor.x + max(n, 1), t.cols) {
		row.cells[i] = b
	}
	row_cut(row, t.cursor.x, min(t.cursor.x + max(n, 1), t.cols))
}

@(private = "file")
erase_line :: proc(t: ^Terminal, mode: int) {
	s := screen(t)
	if t.cursor.y >= len(s.lines) {
		return
	}
	row := &s.lines[t.cursor.y]
	row.dirty = true
	b := blank_cell(t.cursor.pen)
	switch mode {
	case 0:
		for i in t.cursor.x ..< t.cols {
			row.cells[i] = b
		}
		row.wrapped = false
		row_cut(row, t.cursor.x, t.cols)
	case 1:
		for i in 0 ..= min(t.cursor.x, t.cols - 1) {
			row.cells[i] = b
		}
		row_cut(row, 0, min(t.cursor.x, t.cols - 1) + 1)
	case 2:
		row_clear(row, t.cursor.pen)
	}
}

@(private = "file")
erase_screen :: proc(t: ^Terminal, mode: int) {
	s := screen(t)
	switch mode {
	case 0:
		erase_line(t, 0)
		for y in t.cursor.y + 1 ..< len(s.lines) {
			row_clear(&s.lines[y], t.cursor.pen)
		}
	case 1:
		erase_line(t, 1)
		for y in 0 ..< min(t.cursor.y, len(s.lines)) {
			row_clear(&s.lines[y], t.cursor.pen)
		}
	case 2:
		for y in 0 ..< len(s.lines) {
			row_clear(&s.lines[y], t.cursor.pen)
		}
	case 3:
		// Erase the scrollback. This is what `clear` sends after the screen.
		for &r in s.scrollback {
			row_free(&r)
		}
		clear(&s.scrollback)
		t.view_offset = 0
	}
}

@(private = "file")
repeat_last :: proc(t: ^Terminal, n: int) {
	x := t.cursor.x - 1
	if t.cursor.pending {
		x = t.cols - 1
	}
	c := cell_at(t, x, t.cursor.y)
	if c == nil || c.ch == 0 {
		return
	}
	r := c.ch
	for _ in 0 ..< max(n, 1) {
		print_rune(t, r)
	}
}

// ---------------------------------------------------------------------------
// Modes
// ---------------------------------------------------------------------------

@(private = "file")
set_ansi_mode :: proc(t: ^Terminal, m: int, on: bool) {
	switch m {
	case 4:
		t.modes.insert = on
	case 20:
		t.modes.linefeed_newline = on
	}
}

@(private = "file")
set_dec_mode :: proc(t: ^Terminal, m: int, on: bool) {
	switch m {
	case 1:
		t.modes.cursor_keys_app = on
	case 3:
		// DECCOLM also clears the screen, which programs rely on even when
		// the column count does not change.
		erase_screen(t, 2)
		move_cursor(t, 0, 0)
	case 5:
		t.modes.reverse_video = on
	case 6:
		t.modes.origin = on
		t.cursor.origin = on
		move_cursor(t, 0, on ? t.top : 0)
	case 7:
		t.modes.autowrap = on
	case 9:
		t.modes.mouse = on ? .X10 : .None
	case 12:
		t.modes.cursor_blink = on
	case 25:
		t.modes.cursor_visible = on
	case 45:
		t.modes.reverse_wrap = on
	case 66:
		t.modes.keypad_app = on
	case 1000:
		t.modes.mouse = on ? .Normal : .None
	case 1002:
		t.modes.mouse = on ? .Button : .None
	case 1003:
		t.modes.mouse = on ? .Any : .None
	case 1004:
		t.modes.focus_events = on
	case 1005:
		t.modes.mouse_encoding = on ? .Utf8 : .X10
	case 1006:
		t.modes.mouse_encoding = on ? .Sgr : .X10
	case 1015:
		t.modes.mouse_encoding = on ? .Urxvt : .X10
	case 1035:
		t.modes.ignore_keypad_num = on
	case 1036:
		t.modes.alt_esc_prefix = on
	case 1047:
		switch_alt(t, on, false)
	case 1048:
		if on {
			t.saved[t.on_alt ? 1 : 0] = t.cursor
		} else {
			restore_cursor(t)
		}
	case 1049:
		switch_alt(t, on, true)
	case 2004:
		t.modes.bracketed_paste = on
	case 2026:
		t.modes.synchronized = on
	case 80:
		t.modes.sixel_display = on
	}
}

// xtsmgraphics answers XTSMGRAPHICS (CSI ? Pi ; Pa ; Pv S): how many colour
// registers there are and how large a Sixel image may be. Nothing here can be
// changed by it, so a set or reset answers with the values as they stand.
@(private = "file")
xtsmgraphics :: proc(t: ^Terminal, a: Action) {
	item := int(param(a, 0, 0))
	act := int(param(a, 1, 0))
	reply(t, "\x1b[?")
	reply_u32(t, u32(item))
	switch item {
	case 1:
		if act < 1 || act > 4 {
			reply(t, ";2;0S")
			return
		}
		reply(t, ";0;")
		reply_u32(t, SIXEL_REGISTERS)
		reply(t, "S")
	case 2:
		if act < 1 || act > 4 {
			reply(t, ";2;0S")
			return
		}
		// The largest image that fits the budget and the screen is what
		// is reported; a program sizes its output to it.
		w := min(MAX_IMAGE_SIDE, t.cols * t.gfx.cell_w)
		h := min(MAX_IMAGE_SIDE, t.rows * t.gfx.cell_h)
		if act == 4 {
			w = min(MAX_IMAGE_SIDE, 4096)
			h = min(MAX_IMAGE_SIDE, t.gfx.budget / 4 / w)
		}
		reply(t, ";0;")
		reply_u32(t, u32(w))
		reply(t, ";")
		reply_u32(t, u32(h))
		reply(t, "S")
	case:
		reply(t, ";1;0S")
	}
}

@(private = "file")
switch_alt :: proc(t: ^Terminal, on, save: bool) {
	if on == t.on_alt {
		return
	}
	if on {
		if save {
			t.saved[0] = t.cursor
		}
		t.on_alt = true
		t.view_offset = 0
		// The alternate screen always starts blank. Programs assume it.
		for y in 0 ..< len(t.alt.lines) {
			row_clear(&t.alt.lines[y], t.cursor.pen)
		}
		if save {
			t.cursor.x, t.cursor.y = 0, 0
			t.cursor.pending = false
		}
	} else {
		t.on_alt = false
		if save {
			t.cursor = t.saved[0]
			t.cursor.x = clamp(t.cursor.x, 0, t.cols - 1)
			t.cursor.y = clamp(t.cursor.y, 0, t.rows - 1)
		}
		screen_mark_all_dirty(&t.primary)
	}
	t.top = 0
	t.bot = t.rows - 1
}

// ---------------------------------------------------------------------------
// SGR
// ---------------------------------------------------------------------------

@(private = "file")
apply_sgr :: proc(t: ^Terminal, a: Action) {
	if param_count(a) == 0 {
		t.cursor.pen = Pen{link = t.cursor.pen.link}
		return
	}
	// An empty parameter means zero here: `ESC[;31m` is reset then red.
	params := make([]u16, param_count(a), context.temp_allocator)
	for i in 0 ..< param_count(a) {
		params[i] = a.empty[i] ? 0 : a.params[i]
	}
	sp := sgr_begin(params, a.seps)
	for {
		attr, ok := sgr_next(&sp)
		if !ok {
			break
		}
		pen := &t.cursor.pen
		switch attr.tag {
		case .Unset:
			pen^ = Pen{link = pen.link}
		case .Unknown:
		case .Bold:
			pen.attrs |= {.Bold}
		case .Reset_Bold:
			pen.attrs &= ~Attrs{.Bold, .Faint}
		case .Faint:
			pen.attrs |= {.Faint}
		case .Italic:
			pen.attrs |= {.Italic}
		case .Reset_Italic:
			pen.attrs &= ~Attrs{.Italic}
		case .Underline:
			pen.under = attr.underline
		case .Underline_Color:
			pen.ul = color_rgb(attr.rgb)
		case .Underline_Color_256:
			pen.ul = color_palette(attr.idx)
		case .Reset_Underline_Color:
			pen.ul = COLOR_DEFAULT
		case .Overline:
			pen.attrs |= {.Overline}
		case .Reset_Overline:
			pen.attrs &= ~Attrs{.Overline}
		case .Blink:
			pen.attrs |= {.Blink}
		case .Reset_Blink:
			pen.attrs &= ~Attrs{.Blink}
		case .Inverse:
			pen.attrs |= {.Inverse}
		case .Reset_Inverse:
			pen.attrs &= ~Attrs{.Inverse}
		case .Invisible:
			pen.attrs |= {.Invisible}
		case .Reset_Invisible:
			pen.attrs &= ~Attrs{.Invisible}
		case .Strikethrough:
			pen.attrs |= {.Strike}
		case .Reset_Strikethrough:
			pen.attrs &= ~Attrs{.Strike}
		case .Direct_Color_Fg:
			pen.fg = color_rgb(attr.rgb)
		case .Direct_Color_Bg:
			pen.bg = color_rgb(attr.rgb)
		case .Fg_8, .Bright_Fg_8, .Fg_256:
			pen.fg = color_palette(attr.idx)
		case .Bg_8, .Bright_Bg_8, .Bg_256:
			pen.bg = color_palette(attr.idx)
		case .Reset_Fg:
			pen.fg = COLOR_DEFAULT
		case .Reset_Bg:
			pen.bg = COLOR_DEFAULT
		}
	}
}

// ---------------------------------------------------------------------------
// OSC
// ---------------------------------------------------------------------------

@(private = "file")
set_string :: proc(dst: ^string, src: string) {
	delete(dst^)
	dst^ = strings.clone(src)
}

@(private = "file")
osc_dispatch :: proc(t: ^Terminal, a: Action) {
	cmd := osc_parse(a.osc, a.osc_term)
	#partial switch cmd.kind {
	case .Set_Title, .Conemu_Tab_Title:
		set_string(&t.title, cmd.text)
	case .Set_Icon:
		set_string(&t.icon_title, cmd.text)
	case .Set_Pwd:
		set_string(&t.pwd, strip_file_uri(cmd.text))
	case .Hyperlink_Start:
		append(&screen(t).links, strings.clone(cmd.text))
		t.cursor.pen.link = u32(len(screen(t).links) - 1)
	case .Hyperlink_End:
		t.cursor.pen.link = 0
	case .Set_Palette:
		t.palette[cmd.palette_index] = cmd.color
	case .Reset_Palette:
		if cmd.has_color {
			def: [256]Rgb
			default_palette(&def)
			t.palette[cmd.palette_index] = def[cmd.palette_index]
		} else {
			default_palette(&t.palette)
		}
	case .Query_Palette:
		reply_color(t, 4, int(cmd.palette_index), t.palette[cmd.palette_index], cmd.terminator)
	case .Set_Default_Color:
		switch cmd.target {
		case .Foreground:
			t.fg_override = cmd.color
		case .Background:
			t.bg_override = cmd.color
		case .Cursor:
			t.default_cursor = cmd.color
		}
	case .Reset_Default_Color:
		switch cmd.target {
		case .Foreground:
			t.fg_override = nil
		case .Background:
			t.bg_override = nil
		case .Cursor:
			t.default_cursor = t.default_fg
		}
	case .Query_Default_Color:
		c: Rgb
		switch cmd.target {
		case .Foreground:
			c = terminal_fg(t)
		case .Background:
			c = terminal_bg(t)
		case .Cursor:
			c = t.default_cursor
		}
		reply_color(t, 10 + int(cmd.target), -1, c, cmd.terminator)
	case .Clipboard_Write:
		// The write path is supported. The read path is not: see
		// terminal_clipboard_query_refused below.
		if data, ok := base64_decode(cmd.clipboard); ok {
			delete(t.clipboard_set)
			t.clipboard_set = string(data)
			t.clipboard_pending = true
		}
	case .Clipboard_Query:
		// Deliberately answered with nothing. A program that can read the
		// clipboard can read whatever was last copied -- a password, a
		// token, a private key -- and send it anywhere. Writing is a
		// convenience; reading is an exfiltration channel, and the usual
		// mitigation ("ask the user") does not survive a program that asks
		// a hundred times. The sequence is parsed, recognised and dropped.
	case .Conemu_Progress:
		t.progress = cmd.progress
		t.progress_pct = cmd.progress_pct
	case .Notification:
	case .Invalid:
	}
}

@(private = "file")
strip_file_uri :: proc(s: string) -> string {
	if len(s) > 7 && s[:7] == "file://" {
		rest := s[7:]
		if i := strings.index_byte(rest, '/'); i >= 0 {
			return rest[i:]
		}
	}
	return s
}

@(private = "file")
reply_color :: proc(t: ^Terminal, num, index: int, c: Rgb, term: u8) {
	hex :: proc(t: ^Terminal, v: u8) {
		digits := "0123456789abcdef"
		append(&t.out, digits[v >> 4], digits[v & 15])
		append(&t.out, digits[v >> 4], digits[v & 15])
	}
	reply(t, "\x1b]")
	reply_u32(t, u32(num))
	reply(t, ";")
	if index >= 0 {
		reply_u32(t, u32(index))
		reply(t, ";")
	}
	reply(t, "rgb:")
	hex(t, c[0])
	reply(t, "/")
	hex(t, c[1])
	reply(t, "/")
	hex(t, c[2])
	if term == 0x07 {
		append(&t.out, u8(0x07))
	} else {
		reply(t, "\x1b\\")
	}
}

// ---------------------------------------------------------------------------
// DCS
// ---------------------------------------------------------------------------

@(private = "file")
dcs_finish :: proc(t: ^Terminal) {
	if t.dcs_kind != 'Q' {
		return
	}
	// DECRQSS: the application is asking what a setting currently is.
	req := string(t.dcs_buf[:])
	switch req {
	case "m":
		reply(t, "\x1bP1$r0m\x1b\\")
	case "r":
		reply(t, "\x1bP1$r")
		reply_u32(t, u32(t.top + 1))
		reply(t, ";")
		reply_u32(t, u32(t.bot + 1))
		reply(t, "r\x1b\\")
	case:
		reply(t, "\x1bP0$r\x1b\\")
	}
}

// ---------------------------------------------------------------------------
// Colours
// ---------------------------------------------------------------------------

terminal_fg :: proc(t: ^Terminal) -> Rgb {
	if v, ok := t.fg_override.?; ok {
		return v
	}
	return t.default_fg
}

terminal_bg :: proc(t: ^Terminal) -> Rgb {
	if v, ok := t.bg_override.?; ok {
		return v
	}
	return t.default_bg
}

// resolve turns a cell colour into pixels, applying bold-is-bright and the
// inverse attribute the way every other terminal does.
terminal_resolve :: proc(t: ^Terminal, c: Color, is_fg: bool, attrs: Attrs) -> Rgb {
	if color_is_default(c) {
		base := is_fg ? terminal_fg(t) : terminal_bg(t)
		return base
	}
	if color_is_palette(c) {
		i := int(color_index(c))
		if is_fg && .Bold in attrs && i < 8 {
			i += 8
		}
		return t.palette[i]
	}
	return color_value(c)
}

default_palette :: proc(p: ^[256]Rgb) {
	// The first sixteen are a dark, readable set in the same family as the
	// rest of this toolkit's theme rather than the 1980s VGA colours.
	base := [16]Rgb {
		{0x1E, 0x29, 0x3B}, {0xEF, 0x44, 0x44}, {0x22, 0xC5, 0x5E}, {0xEA, 0xB3, 0x08},
		{0x3B, 0x82, 0xF6}, {0xA8, 0x55, 0xF7}, {0x06, 0xB6, 0xD4}, {0xCB, 0xD5, 0xE1},
		{0x47, 0x55, 0x69}, {0xF8, 0x71, 0x71}, {0x4A, 0xDE, 0x80}, {0xFA, 0xCC, 0x15},
		{0x60, 0xA5, 0xFA}, {0xC0, 0x84, 0xFC}, {0x22, 0xD3, 0xEE}, {0xF1, 0xF5, 0xF9},
	}
	for i in 0 ..< 16 {
		p[i] = base[i]
	}
	// The 6x6x6 colour cube, with xterm's non-linear ramp.
	steps := [6]u8{0, 95, 135, 175, 215, 255}
	i := 16
	for r in 0 ..< 6 {
		for g in 0 ..< 6 {
			for b in 0 ..< 6 {
				p[i] = {steps[r], steps[g], steps[b]}
				i += 1
			}
		}
	}
	// Twenty-four greys.
	for j in 0 ..< 24 {
		v := u8(8 + j * 10)
		p[232 + j] = {v, v, v}
	}
}

// ---------------------------------------------------------------------------
// Convenience for tests and for the UI
// ---------------------------------------------------------------------------

// terminal_line renders one row of the active screen as a string, which is
// what the self-test asserts against.
terminal_line :: proc(t: ^Terminal, y: int, allocator := context.allocator) -> string {
	s := screen(t)
	if y < 0 || y >= len(s.lines) {
		return ""
	}
	b := strings.builder_make(allocator)
	row := s.lines[y]
	n := row_used(row)
	for i in 0 ..< n {
		c := row.cells[i]
		if .Spacer in c.attrs {
			continue
		}
		strings.write_rune(&b, c.ch == 0 ? ' ' : c.ch)
		for g in screen_grapheme(s, c) {
			strings.write_rune(&b, g)
		}
	}
	return strings.to_string(b)
}

terminal_cursor :: proc(t: ^Terminal) -> (x, y: int) {
	return t.cursor.x, t.cursor.y
}
