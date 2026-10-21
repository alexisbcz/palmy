package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import p "palmy:."
import vt "./vt"

// ---------------------------------------------------------------------------
// The built-in checks.
//
// These are the assertions that do not need libghostty: the grid, the screen
// operations, reflow, the pty, and a render of real pixels read back out.
// The differential tests against libghostty-vt live in apps/term/oracle and
// are run by apps/term/oracle/run.sh, because the shipped binary must not
// link or open that library.
// ---------------------------------------------------------------------------

checks: int
failures: int

check :: proc(ok: bool, format: string, args: ..any) {
	checks += 1
	if !ok {
		failures += 1
		fmt.printfln("  FAIL  %s", fmt.tprintf(format, ..args))
	}
}

eq_s :: proc(got, want: string, what: string) {
	checks += 1
	if got != want {
		failures += 1
		fmt.printfln("  FAIL  %s: got %q, want %q", what, got, want)
	}
}

eq_i :: proc(got, want: int, what: string) {
	checks += 1
	if got != want {
		failures += 1
		fmt.printfln("  FAIL  %s: got %d, want %d", what, got, want)
	}
}

feed :: proc(t: ^vt.Terminal, s: string) {
	vt.terminal_feed(t, transmute([]u8)s)
}

line :: proc(t: ^vt.Terminal, y: int) -> string {
	return vt.terminal_line(t, y, context.temp_allocator)
}

selftest :: proc() -> int {
	t0 := time.now()
	fmt.println("term self-test")

	test_unicode()
	test_parser()
	test_sgr_engine()
	test_osc_engine()
	test_screen()
	test_scroll_regions()
	test_alt_screen()
	test_tabs_stops()
	test_charsets()
	test_reflow()
	test_keys()
	test_mouse()
	test_paste()
	test_replies()
	test_more_screen()
	test_colors()
	test_scrollback()
	test_pty()
	test_render()
	test_render_wide()
	test_keysyms()
	test_selection_click()
	test_graphics()
	test_splits()

	ms := time.duration_milliseconds(time.since(t0))
	fmt.printf("\n%d assertions, %d failures, %.0f ms\n", checks, failures, ms)
	return failures == 0 ? 0 : 1
}

// ---------------------------------------------------------------------------

// The legacy keysyms carry no codepoint in their value; a Cyrillic, Greek,
// Arabic or Hebrew layout, or a euro key, typed nothing through the encoder
// while keysym_codepoint knew only Latin-1 and 0x01xxxxxx.
@(private = "file")
test_keysyms :: proc() {
	Case :: struct {
		sym:  u32,
		want: rune,
		what: string,
	}
	cases := [?]Case {
		{'a', 'a', "ASCII"},
		{0xe9, 'é', "Latin-1 eacute"},
		{0x01a1, 'Ą', "Latin-2 Aogonek"},
		{0x06c1, 'а', "Cyrillic_a"},
		{0x06df, 'ъ', "Cyrillic_hardsign"},
		{0x06b3, 'Ё', "Cyrillic_IO"},
		{0x07e1, 'α', "Greek_alpha"},
		{0x07d9, 'Ω', "Greek_OMEGA"},
		{0x05c7, 'ا', "Arabic_alef"},
		{0x05ac, '،', "Arabic_comma"},
		{0x0ce0, 'א', "hebrew_aleph"},
		{0x0cfa, 'ת', "hebrew_taw"},
		{0x0da1, 'ก', "Thai_kokai"},
		{0x04b1, 'ア', "kana_A"},
		{0x20ac, '€', "EuroSign"},
		{0x0aa9, '—', "emdash"},
		{0x08fb, '←', "leftarrow"},
		{0x010020ac, '€', "the Unicode keysym for the euro"},
		{0x0100044f, 'я', "the Unicode keysym for ya"},
		{0xffbe, 0, "F1 is not a character"},
		{0xffe1, 0, "Shift_L is not a character"},
		{0x0100, 0, "an unassigned legacy keysym"},
	}
	for c in cases {
		got := keysym_codepoint(c.sym)
		check(got == c.want, "keysym 0x%x (%s) is U+%04X, got U+%04X", c.sym, c.what, u32(c.want), u32(got))
	}
	// And they reach the encoder as text.
	buf: [8]u8
	ev := key_event_from(p.Key_Event{sym = 0x06c1}, buf[:])
	eq_s(ev.utf8, "а", "Cyrillic_a reaches the encoder as text")
	ev = key_event_from(p.Key_Event{sym = 0x20ac}, buf[:])
	eq_s(ev.utf8, "€", "the euro sign reaches the encoder as text")
}

// A single click selects nothing; a drag selects; a drag that comes back to
// where it started selects that one cell.
@(private = "file")
test_selection_click :: proc() {
	s := sel_press(3, 10)
	check(!s.active, "a press alone selects nothing")
	check(!sel_contains(s, 10, 3), "the clicked cell is not highlighted")
	check(!sel_drag(&s, 3, 10), "a motion within the same cell changes nothing")
	check(!s.active, "a click that stays in its cell still selects nothing")

	s = sel_press(3, 10)
	check(sel_drag(&s, 6, 10), "moving to another cell changes the selection")
	check(s.active, "a drag selects")
	check(sel_contains(s, 10, 3) && sel_contains(s, 10, 6), "from the press to the pointer")
	check(sel_drag(&s, 3, 10), "coming back to the first cell changes it again")
	check(s.active && sel_contains(s, 10, 3), "and leaves that one cell selected")

	s.dragging = false
	check(!sel_drag(&s, 9, 10), "after the release, motion does nothing")
}

test_unicode :: proc() {
	eq_i(vt.rune_width('a'), 1, "width of a")
	eq_i(vt.rune_width('一'), 2, "width of a CJK ideograph")
	eq_i(vt.rune_width('́'), 0, "width of a combining acute")
	eq_i(vt.rune_width('\U0001F600'), 2, "width of an emoji")
	eq_i(vt.rune_width('Ａ'), 2, "width of a fullwidth A")
	eq_i(vt.rune_width('ᅠ'), 0, "width of a Hangul filler")
	eq_i(vt.rune_width('\U0001F1E6'), 2, "width of a regional indicator")
	check(vt.is_combining('́'), "the combining acute combines")
	check(!vt.is_combining('a'), "a does not combine")

	d: vt.Utf8_Decoder
	// A four-byte codepoint split across three feeds.
	seq := [?]u8{0xF0, 0x9F, 0x98, 0x80}
	got: rune
	for b, i in seq {
		cp, res := vt.utf8_feed(&d, b)
		if i < 3 {
			check(res == .Incomplete, "utf8 byte %d is incomplete", i)
		} else {
			check(res == .Codepoint, "utf8 completes on the last byte")
			got = cp
		}
	}
	eq_i(int(got), 0x1F600, "the split emoji decodes")

	// An overlong encoding is rejected rather than decoded.
	vt.utf8_reset(&d)
	_, r1 := vt.utf8_feed(&d, 0xC0)
	check(r1 == .Invalid_Consumed, "0xC0 cannot start a sequence")

	// A truncated sequence followed by ASCII yields one replacement and the A.
	vt.utf8_reset(&d)
	_, _ = vt.utf8_feed(&d, 0xE4)
	_, r2 := vt.utf8_feed(&d, 0x41)
	check(r2 == .Invalid, "a bad continuation hands the byte back")

	// A surrogate is not a codepoint.
	vt.utf8_reset(&d)
	_, _ = vt.utf8_feed(&d, 0xED)
	_, r3 := vt.utf8_feed(&d, 0xA0)
	check(r3 == .Invalid, "a surrogate is rejected")

	buf: [4]u8
	eq_i(vt.utf8_encode(buf[:], 'A'), 1, "encoding A takes one byte")
	eq_i(vt.utf8_encode(buf[:], '一'), 3, "encoding a CJK ideograph takes three")
	eq_i(vt.utf8_encode(buf[:], '\U0001F600'), 4, "encoding an emoji takes four")
}

// ---------------------------------------------------------------------------

@(private = "file")
Capture :: struct {
	acts: [dynamic]string,
}

@(private = "file")
capture_sink :: proc(user: rawptr, a: vt.Action) {
	c := (^Capture)(user)
	switch a.kind {
	case .Print:
		append(&c.acts, fmt.aprintf("print %c", a.cp))
	case .Execute:
		append(&c.acts, fmt.aprintf("exec %02x", a.b))
	case .Esc_Dispatch:
		append(&c.acts, fmt.aprintf("esc %s%c", string(a.intermediates), rune(a.b)))
	case .Csi_Dispatch:
		b := strings.builder_make()
		fmt.sbprintf(&b, "csi ")
		if a.private != 0 {
			fmt.sbprintf(&b, "%c", rune(a.private))
		}
		for v, i in a.params {
			if i > 0 {
				fmt.sbprintf(&b, "%c", rune(a.seps[i - 1]))
			}
			fmt.sbprintf(&b, "%d", v)
		}
		fmt.sbprintf(&b, "%s%c", string(a.intermediates), rune(a.b))
		append(&c.acts, strings.to_string(b))
	case .Osc_Dispatch:
		append(&c.acts, fmt.aprintf("osc %s", string(a.osc)))
	case .Dcs_Hook:
		append(&c.acts, fmt.aprintf("dcs %c", rune(a.b)))
	case .Dcs_Put:
		append(&c.acts, fmt.aprintf("put %c", rune(a.b)))
	case .Dcs_Unhook:
		append(&c.acts, "unhook")
	case .Apc_Dispatch:
		append(&c.acts, fmt.aprintf("apc %s", string(a.osc)))
	}
}

@(private = "file")
parse_to :: proc(input: string) -> []string {
	c := new(Capture)
	c.acts = make([dynamic]string)
	par: vt.Parser
	vt.parser_init(&par, {user = c, fn = capture_sink})
	vt.parse(&par, transmute([]u8)input)
	return c.acts[:]
}

@(private = "file")
joined :: proc(input: string) -> string {
	return strings.join(parse_to(input), "|", context.temp_allocator)
}

test_parser :: proc() {
	eq_s(joined("ab"), "print a|print b", "plain text")
	eq_s(joined("\x1b[31m"), "csi 31m", "a simple CSI")
	eq_s(joined("\x1b[?25h"), "csi ?25h", "a private CSI")
	eq_s(joined("\x1b[1;2;3m"), "csi 1;2;3m", "CSI with parameters")
	eq_s(joined("\x1b[4:3m"), "csi 4:3m", "CSI with a colon subparameter")
	eq_s(joined("\x1b[38;2;1;2;3m"), "csi 38;2;1;2;3m", "a direct colour")
	eq_s(joined("\x1b]0;hi\x07"), "osc 0;hi", "an OSC ended with BEL")
	eq_s(joined("\x1b]0;hi\x1b\\"), "osc 0;hi|esc \\", "an OSC ended with ST")
	eq_s(joined("\x1bPq\x1b\\"), "dcs q|unhook|esc \\", "an empty DCS")
	eq_s(joined("\x1bP1$rm\x1b\\"), "dcs r|put m|unhook|esc \\", "a DECRQSS reply shape")
	// A C0 control in the middle of a CSI is executed and the CSI continues.
	eq_s(joined("\x1b[1\x072m"), "exec 07|csi 12m", "a BEL inside a CSI")
	// CAN abandons the sequence.
	eq_s(joined("\x1b[1\x18m"), "exec 18|print m", "CAN abandons a CSI")
	// SS3 on the output side is an escape of its own: it shifts the next
	// character to G3. The keyboard spelling `ESC O P` for F1 is an input
	// sequence and never arrives here.
	eq_s(joined("\x1bOP"), "esc O|print P", "SS3 is its own escape")
	eq_s(joined("\x9b31m"), "csi 31m", "the eight-bit CSI")
	eq_s(joined("é"), "print é", "a two-byte codepoint")
	eq_s(joined("\x1b[>4;2m"), "csi >4;2m", "a CSI with a > prefix")
	// A parameter list longer than the limit is dropped rather than acted on.
	long := strings.repeat("1;", 40, context.temp_allocator)
	eq_s(joined(fmt.tprintf("\x1b[%sm", long)), "", "an over-long parameter list is dropped")
}

// ---------------------------------------------------------------------------

@(private = "file")
sgr_of :: proc(params: []u16, seps: []u8) -> string {
	b := strings.builder_make(context.temp_allocator)
	sp := vt.sgr_begin(params, seps)
	for {
		a, ok := vt.sgr_next(&sp)
		if !ok {
			break
		}
		fmt.sbprintf(&b, "%v;", a.tag)
	}
	return strings.to_string(b)
}

test_sgr_engine :: proc() {
	eq_s(sgr_of({1, 31}, {';', ';'}), "Bold;Fg_8;", "bold then red")
	eq_s(sgr_of({38, 5, 9}, {';', ';', ';'}), "Fg_256;", "a 256-colour foreground")
	eq_s(sgr_of({38, 2, 1, 2, 3}, {';', ';', ';', ';', ';'}), "Direct_Color_Fg;", "a direct colour")
	eq_s(sgr_of({4, 3}, {':', ';'}), "Underline;", "a curly underline")
	eq_s(sgr_of({4, 3}, {';', ';'}), "Underline;Italic;", "4;3 is underline then italic")

	sp := vt.sgr_begin({4, 3}, {':', ';'})
	a, _ := vt.sgr_next(&sp)
	check(a.underline == .Curly, "4:3 selects the curly style")

	sp2 := vt.sgr_begin({38, 2, 10, 20, 30}, {';', ';', ';', ';', ';'})
	b, _ := vt.sgr_next(&sp2)
	check(b.rgb == vt.Rgb{10, 20, 30}, "the direct colour keeps its channels")
}

test_osc_engine :: proc() {
	c := vt.osc_parse(transmute([]u8)string("0;hello"), 0x07)
	check(c.kind == .Set_Title, "OSC 0 sets the title")
	eq_s(c.text, "hello", "the title payload")

	c = vt.osc_parse(transmute([]u8)string("7;file://host/home/x"), 0x07)
	check(c.kind == .Set_Pwd, "OSC 7 reports the directory")

	c = vt.osc_parse(transmute([]u8)string("8;id=a;https://example.com"), 0x07)
	check(c.kind == .Hyperlink_Start, "OSC 8 starts a hyperlink")
	eq_s(c.id, "a", "the hyperlink id")
	eq_s(c.text, "https://example.com", "the hyperlink target")

	c = vt.osc_parse(transmute([]u8)string("8;;"), 0x07)
	check(c.kind == .Hyperlink_End, "an empty OSC 8 ends the hyperlink")

	c = vt.osc_parse(transmute([]u8)string("52;c;aGVsbG8="), 0x07)
	check(c.kind == .Clipboard_Write, "OSC 52 with data is a write")
	c = vt.osc_parse(transmute([]u8)string("52;c;?"), 0x07)
	check(c.kind == .Clipboard_Query, "OSC 52 with ? is a read")

	c = vt.osc_parse(transmute([]u8)string("4;1;rgb:ff/00/00"), 0x07)
	check(c.kind == .Set_Palette, "OSC 4 sets a palette entry")
	check(c.color == vt.Rgb{255, 0, 0}, "the palette colour parses")

	c = vt.osc_parse(transmute([]u8)string("11;#112233"), 0x07)
	check(c.color == vt.Rgb{0x11, 0x22, 0x33}, "the hash colour form parses")

	c = vt.osc_parse(transmute([]u8)string("9;4;1;42"), 0x07)
	check(c.kind == .Conemu_Progress, "OSC 9;4 is a progress report")
	eq_i(int(c.progress_pct), 42, "the progress percentage")

	data, ok := vt.base64_decode("aGVsbG8=")
	check(ok, "base64 decodes")
	eq_s(string(data), "hello", "the decoded clipboard payload")
	eq_s(vt.base64_encode(transmute([]u8)string("hello"), context.temp_allocator), "aGVsbG8=", "base64 round trip")
}

// ---------------------------------------------------------------------------

test_screen :: proc() {
	t: vt.Terminal
	vt.terminal_init(&t, 10, 4, 100)
	defer vt.terminal_destroy(&t)

	feed(&t, "hello")
	eq_s(line(&t, 0), "hello", "plain printing")
	x, y := vt.terminal_cursor(&t)
	eq_i(x, 5, "the cursor advances")
	eq_i(y, 0, "the cursor stays on the row")

	// The last column defers its wrap until one more character arrives.
	feed(&t, "\x1b[2J\x1b[H")
	feed(&t, "0123456789")
	x, y = vt.terminal_cursor(&t)
	eq_i(y, 0, "a full row does not wrap on its own")
	feed(&t, "A")
	_, y = vt.terminal_cursor(&t)
	eq_i(y, 1, "the next character wraps")
	eq_s(line(&t, 0), "0123456789", "the full row kept its text")
	eq_s(line(&t, 1), "A", "the wrapped character is on the next row")

	// Erase in line.
	feed(&t, "\x1b[2J\x1b[Habcdefghij\x1b[1;4H\x1b[K")
	eq_s(line(&t, 0), "abc", "erase to the end of the line")
	feed(&t, "\x1b[2J\x1b[Habcdefghij\x1b[1;4H\x1b[1K")
	eq_s(line(&t, 0), "    efghij", "erase to the start of the line")

	// Insert and delete characters.
	feed(&t, "\x1b[2J\x1b[Habcdef\x1b[1;3H\x1b[2@")
	eq_s(line(&t, 0), "ab  cdef", "insert two characters")
	feed(&t, "\x1b[2J\x1b[Habcdef\x1b[1;3H\x1b[2P")
	eq_s(line(&t, 0), "abef", "delete two characters")
	feed(&t, "\x1b[2J\x1b[Habcdef\x1b[1;3H\x1b[2X")
	eq_s(line(&t, 0), "ab  ef", "erase two characters")

	// Insert and delete lines.
	feed(&t, "\x1b[2J\x1b[Hone\r\ntwo\r\nthree")
	feed(&t, "\x1b[2;1H\x1b[L")
	eq_s(line(&t, 1), "", "the inserted line is blank")
	eq_s(line(&t, 2), "two", "the old line moved down")
	feed(&t, "\x1b[2;1H\x1b[M")
	eq_s(line(&t, 1), "two", "deleting a line pulls the rest up")

	// Wide characters take two cells and clear their spacer when overwritten.
	feed(&t, "\x1b[2J\x1b[H中文")
	eq_s(line(&t, 0), "中文", "two CJK characters")
	x, _ = vt.terminal_cursor(&t)
	eq_i(x, 4, "each CJK character took two cells")
	feed(&t, "\x1b[1;2HX")
	eq_s(line(&t, 0), " X文", "overwriting the right half clears the left")

	// Combining marks join the cell before them.
	feed(&t, "\x1b[2J\x1b[Hé")
	eq_s(line(&t, 0), "é", "a combining acute stays in one cell")
	x, _ = vt.terminal_cursor(&t)
	eq_i(x, 1, "a combining mark does not advance the cursor")

	// REP repeats the last character.
	feed(&t, "\x1b[2J\x1b[Hx\x1b[3b")
	eq_s(line(&t, 0), "xxxx", "REP repeats")

	// Scrolling pushes to the scrollback.
	t2: vt.Terminal
	vt.terminal_init(&t2, 10, 2, 100)
	defer vt.terminal_destroy(&t2)
	feed(&t2, "a\r\nb\r\nc\r\nd")
	eq_s(line(&t2, 0), "c", "the screen scrolled")
	eq_s(line(&t2, 1), "d", "the last line is at the bottom")
	eq_i(len(vt.screen(&t2).scrollback), 2, "two lines went to the scrollback")
}

test_scroll_regions :: proc() {
	t: vt.Terminal
	vt.terminal_init(&t, 10, 5, 100)
	defer vt.terminal_destroy(&t)

	feed(&t, "1\r\n2\r\n3\r\n4\r\n5")
	feed(&t, "\x1b[2;4r")      // region covers rows 2..4
	feed(&t, "\x1b[4;1H\r\nX") // at the bottom of the region, scroll it
	eq_s(line(&t, 0), "1", "the row above the region did not move")
	eq_s(line(&t, 1), "3", "the region scrolled")
	eq_s(line(&t, 3), "X", "the new text is at the bottom of the region")
	eq_s(line(&t, 4), "5", "the row below the region did not move")

	// Origin mode puts row 1 at the top of the region.
	feed(&t, "\x1b[?6h\x1b[1;1HO")
	eq_s(line(&t, 1), "O", "origin mode homes to the region")
	feed(&t, "\x1b[?6l")
	feed(&t, "\x1b[r") // reset the region
	feed(&t, "\x1b[1;1HZ")
	eq_s(line(&t, 0), "Z", "after reset, home is the top of the screen")
}

test_alt_screen :: proc() {
	t: vt.Terminal
	vt.terminal_init(&t, 10, 3, 100)
	defer vt.terminal_destroy(&t)

	feed(&t, "shell line")
	feed(&t, "\x1b[?1049h")
	eq_s(line(&t, 0), "", "the alternate screen starts blank")
	feed(&t, "editor")
	eq_s(line(&t, 0), "editor", "the editor drew on the alternate screen")
	check(len(vt.screen(&t).scrollback) == 0, "the alternate screen has no scrollback")
	feed(&t, "\x1b[?1049l")
	eq_s(line(&t, 0), "shell line", "leaving the alternate screen restores the shell")
}

test_tabs_stops :: proc() {
	t: vt.Terminal
	vt.terminal_init(&t, 24, 2, 10)
	defer vt.terminal_destroy(&t)
	feed(&t, "a\tb\tc")
	eq_s(line(&t, 0), "a       b       c", "the default stops are every eight columns")
	feed(&t, "\x1b[2J\x1b[H\x1b[3g") // clear every stop
	feed(&t, "\x1b[1;5H\x1bH")       // set one at column 5
	feed(&t, "\x1b[1;1Ha\tb")
	eq_s(line(&t, 0), "a   b", "a hand-set tab stop")
}

test_charsets :: proc() {
	t: vt.Terminal
	vt.terminal_init(&t, 10, 2, 10)
	defer vt.terminal_destroy(&t)
	feed(&t, "\x1b(0lqk\x1b(B")
	eq_s(line(&t, 0), "┌─┐", "the DEC line-drawing set")
	feed(&t, "\x1b[2J\x1b[Hlqk")
	eq_s(line(&t, 0), "lqk", "ASCII is restored")
}

test_reflow :: proc() {
	t: vt.Terminal
	vt.terminal_init(&t, 10, 3, 100)
	defer vt.terminal_destroy(&t)

	// A line that soft-wraps, then the window narrows and widens again.
	feed(&t, "abcdefghijklmno")
	eq_s(line(&t, 0), "abcdefghij", "the first row before the resize")
	eq_s(line(&t, 1), "klmno", "the second row before the resize")

	vt.terminal_resize(&t, 5, 3)
	eq_s(line(&t, 0), "abcde", "narrowing re-wraps the line")
	eq_s(line(&t, 1), "fghij", "the middle of the line is still there")
	eq_s(line(&t, 2), "klmno", "and so is the tail")
	eq_i(
		len(vt.screen(&t).scrollback),
		0,
		"nothing went to the scrollback: the text still fits",
	)

	// Narrowing far enough that it does not fit pushes the start up.
	vt.terminal_resize(&t, 4, 3)
	eq_s(line(&t, 2), "mno", "the end of the line stays on screen")
	check(len(vt.screen(&t).scrollback) >= 1, "the start of the line went to the scrollback")

	vt.terminal_resize(&t, 20, 3)
	eq_s(line(&t, 0), "abcdefghijklmno", "widening puts the line back together")

	// A hard line break must survive a resize unchanged.
	t2: vt.Terminal
	vt.terminal_init(&t2, 20, 4, 100)
	defer vt.terminal_destroy(&t2)
	feed(&t2, "one\r\ntwo\r\nthree")
	vt.terminal_resize(&t2, 6, 4)
	eq_s(line(&t2, 0), "one", "a hard break is not joined")
	eq_s(line(&t2, 1), "two", "the second line stands alone")
	eq_s(line(&t2, 2), "three", "the third line stands alone")
	vt.terminal_resize(&t2, 20, 4)
	eq_s(line(&t2, 0), "one", "and survives the round trip")
	eq_s(line(&t2, 2), "three", "all three lines survive")

	// A two-cell character must not be split by the wrap.
	t3: vt.Terminal
	vt.terminal_init(&t3, 8, 3, 100)
	defer vt.terminal_destroy(&t3)
	feed(&t3, "ab中文中文")
	vt.terminal_resize(&t3, 5, 3)
	found_split := false
	s := vt.screen(&t3)
	for i in 0 ..< vt.screen_total_rows(s) {
		r := vt.screen_row(s, i)
		if r == nil || len(r.cells) == 0 {
			continue
		}
		if .Spacer in r.cells[0].attrs {
			found_split = true
		}
	}
	check(!found_split, "no row begins with the tail of a wide character")

	// The alternate screen is resized but not re-wrapped.
	t4: vt.Terminal
	vt.terminal_init(&t4, 10, 3, 100)
	defer vt.terminal_destroy(&t4)
	feed(&t4, "\x1b[?1049habcdefghijXYZ")
	vt.terminal_resize(&t4, 5, 3)
	eq_i(len(vt.screen(&t4).lines[0].cells), 5, "the alternate screen took the new width")
}

test_keys :: proc() {
	buf: [64]u8
	enc := vt.Key_Encoder{}

	e :: proc(enc: vt.Key_Encoder, k: vt.Key, mods: u16, utf8: string, un: rune, buf: []u8) -> string {
		ev := vt.Key_Event {
			action              = .Press,
			key                 = k,
			mods                = mods,
			utf8                = utf8,
			unshifted_codepoint = un,
		}
		return string(vt.key_encode(enc, ev, buf))
	}

	eq_s(e(enc, .A, 0, "a", 'a', buf[:]), "a", "a plain letter")
	eq_s(e(enc, .A, vt.MOD_CTRL, "a", 'a', buf[:]), "\x01", "ctrl+a")
	eq_s(e(enc, .C, vt.MOD_CTRL, "c", 'c', buf[:]), "\x03", "ctrl+c")
	eq_s(e(enc, .Enter, 0, "", 0, buf[:]), "\r", "enter")
	eq_s(e(enc, .Tab, 0, "", 0, buf[:]), "\t", "tab")
	eq_s(e(enc, .Tab, vt.MOD_SHIFT, "", 0, buf[:]), "\x1b[Z", "shift+tab")
	eq_s(e(enc, .Backspace, 0, "", 0, buf[:]), "\x7f", "backspace")
	eq_s(e(enc, .Arrow_Up, 0, "", 0, buf[:]), "\x1b[A", "up")
	eq_s(e(enc, .Arrow_Up, vt.MOD_CTRL, "", 0, buf[:]), "\x1b[1;5A", "ctrl+up")
	eq_s(e(enc, .F1, 0, "", 0, buf[:]), "\x1bOP", "F1")
	eq_s(e(enc, .F5, 0, "", 0, buf[:]), "\x1b[15~", "F5")
	eq_s(e(enc, .Delete, 0, "", 0, buf[:]), "\x1b[3~", "delete")
	eq_s(e(enc, .Shift_Left, vt.MOD_SHIFT, "", 0, buf[:]), "", "a bare modifier sends nothing")

	app := enc
	app.cursor_key_application = true
	eq_s(e(app, .Arrow_Up, 0, "", 0, buf[:]), "\x1bOA", "up in application-cursor mode")

	k := enc
	k.kitty_flags = vt.KITTY_DISAMBIGUATE
	eq_s(e(k, .Escape, 0, "", 0, buf[:]), "\x1b[27u", "escape under the kitty protocol")
	eq_s(e(k, .A, vt.MOD_CTRL, "a", 'a', buf[:]), "\x1b[97;5u", "ctrl+a under the kitty protocol")
	eq_s(e(k, .A, 0, "a", 'a', buf[:]), "a", "an unmodified key keeps its legacy bytes")

	// Alt only prefixes with an escape when the mode asks for it.
	alt := enc
	eq_s(e(alt, .A, vt.MOD_ALT, "a", 'a', buf[:]), "a", "alt+a without mode 1036")
	alt.alt_esc_prefix = true
	eq_s(e(alt, .A, vt.MOD_ALT, "a", 'a', buf[:]), "\x1ba", "alt+a with mode 1036")
}

test_mouse :: proc() {
	t: vt.Terminal
	vt.terminal_init(&t, 80, 24, 10)
	defer vt.terminal_destroy(&t)
	buf: [32]u8

	ev := vt.Mouse_Event {
		button = .Left,
		action = .Press,
		col    = 4,
		row    = 2,
	}
	check(len(vt.mouse_encode(&t, ev, buf[:])) == 0, "nothing is reported before a mode is set")

	feed(&t, "\x1b[?1000h\x1b[?1006h")
	check(vt.mouse_wants(&t), "the program asked for mouse reports")
	eq_s(string(vt.mouse_encode(&t, ev, buf[:])), "\x1b[<0;5;3M", "an SGR press")
	ev.action = .Release
	eq_s(string(vt.mouse_encode(&t, ev, buf[:])), "\x1b[<0;5;3m", "an SGR release")
	ev.action = .Motion
	check(len(vt.mouse_encode(&t, ev, buf[:])) == 0, "motion is not reported in mode 1000")
	feed(&t, "\x1b[?1003h")
	eq_s(string(vt.mouse_encode(&t, ev, buf[:])), "\x1b[<32;5;3M", "motion in mode 1003")

	ev2 := vt.Mouse_Event {
		button = .Wheel_Up,
		action = .Press,
		col    = 0,
		row    = 0,
	}
	eq_s(string(vt.mouse_encode(&t, ev2, buf[:])), "\x1b[<64;1;1M", "a wheel notch")

	// A column past 223 is where the original protocol breaks and SGR does not.
	ev3 := vt.Mouse_Event {
		button = .Left,
		action = .Press,
		col    = 300,
		row    = 2,
	}
	eq_s(string(vt.mouse_encode(&t, ev3, buf[:])), "\x1b[<0;301;3M", "SGR counts past 223")
}

test_paste :: proc() {
	check(vt.paste_is_safe("ls -la"), "a plain command is safe to paste")
	check(!vt.paste_is_safe("ls\n"), "a trailing newline is not")
	check(!vt.paste_is_safe("a\x1b[201~b"), "an embedded end-marker is not")

	t: vt.Terminal
	vt.terminal_init(&t, 80, 24, 10)
	defer vt.terminal_destroy(&t)
	eq_s(vt.paste_encode(&t, "a\nb", context.temp_allocator), "a\rb", "a paste without bracketing")
	feed(&t, "\x1b[?2004h")
	eq_s(
		vt.paste_encode(&t, "a\nb", context.temp_allocator),
		"\x1b[200~a\rb\x1b[201~",
		"a bracketed paste",
	)
	// Text that tries to end the paste early has the marker removed.
	eq_s(
		vt.paste_encode(&t, "a\x1b[201~rm -rf /", context.temp_allocator),
		"\x1b[200~arm -rf /\x1b[201~",
		"an injected end-marker is stripped",
	)
}

test_replies :: proc() {
	t: vt.Terminal
	vt.terminal_init(&t, 80, 24, 10)
	defer vt.terminal_destroy(&t)

	feed(&t, "\x1b[6n")
	out := vt.terminal_take_output(&t)
	eq_s(string(out), "\x1b[1;1R", "the cursor position report")
	delete(out)

	feed(&t, "\x1b[10;5H\x1b[6n")
	out = vt.terminal_take_output(&t)
	eq_s(string(out), "\x1b[10;5R", "the report follows the cursor")
	delete(out)

	feed(&t, "\x1b[c")
	out = vt.terminal_take_output(&t)
	// The 4 is Sixel, which programs look for before they send any.
	eq_s(string(out), "\x1b[?62;4;22c", "the primary device attributes")
	delete(out)

	feed(&t, "\x1b[5n")
	out = vt.terminal_take_output(&t)
	eq_s(string(out), "\x1b[0n", "the device status report")
	delete(out)

	feed(&t, "\x1b[18t")
	out = vt.terminal_take_output(&t)
	eq_s(string(out), "\x1b[8;24;80t", "the size report")
	delete(out)

	// OSC 52 reads are refused: nothing is written back.
	feed(&t, "\x1b]52;c;?\x07")
	out = vt.terminal_take_output(&t)
	check(out == nil, "an OSC 52 clipboard read is answered with nothing")
	delete(out)

	// OSC 52 writes are accepted.
	feed(&t, "\x1b]52;c;aGVsbG8=\x07")
	check(t.clipboard_pending, "an OSC 52 write is offered to the clipboard")
	eq_s(t.clipboard_set, "hello", "the decoded clipboard payload")

	// Kitty keyboard flags push and pop.
	feed(&t, "\x1b[>5u")
	eq_i(int(vt.terminal_kitty_flags(&t)), 5, "the pushed kitty flags")
	feed(&t, "\x1b[<u")
	eq_i(int(vt.terminal_kitty_flags(&t)), 0, "the flags pop back")

	feed(&t, "\x1b]0;a title\x07")
	eq_s(t.title, "a title", "OSC 0 reaches the terminal")
	feed(&t, "\x1b]7;file://host/tmp\x07")
	eq_s(t.pwd, "/tmp", "OSC 7 reaches the terminal")
}

test_more_screen :: proc() {
	t: vt.Terminal
	vt.terminal_init(&t, 12, 4, 100)
	defer vt.terminal_destroy(&t)

	// Insert mode pushes what is already there to the right.
	feed(&t, "abcdef\x1b[1;1H\x1b[4hXY")
	eq_s(line(&t, 0), "XYabcdef", "insert mode shifts the rest right")
	feed(&t, "\x1b[4l\x1b[1;1HZ")
	eq_s(line(&t, 0), "ZYabcdef", "replace mode overwrites")

	// Reverse index at the top of the region scrolls it down.
	feed(&t, "\x1b[2J\x1b[H1\r\n2\r\n3")
	feed(&t, "\x1b[1;1H\x1bM")
	eq_s(line(&t, 0), "", "reverse index at the top inserts a blank line")
	eq_s(line(&t, 1), "1", "and pushes the rest down")

	// DECALN fills the screen, which is the quickest proof of the geometry.
	feed(&t, "\x1b#8")
	eq_s(line(&t, 0), "EEEEEEEEEEEE", "DECALN fills a row")
	eq_s(line(&t, 3), "EEEEEEEEEEEE", "DECALN fills the last row too")

	// Autowrap off pins the cursor to the last column.
	feed(&t, "\x1b[2J\x1b[H\x1b[?7l")
	feed(&t, "abcdefghijklmnop")
	eq_s(line(&t, 0), "abcdefghijkp", "with autowrap off the last column is overwritten")
	x, y := vt.terminal_cursor(&t)
	eq_i(y, 0, "and nothing moved to the next row")
	feed(&t, "\x1b[?7h")

	// A malformed UTF-8 byte prints one replacement character.
	feed(&t, "\x1b[2J\x1b[H")
	vt.terminal_feed(&t, []u8{'a', 0xFF, 'b'})
	eq_s(line(&t, 0), "a\ufffdb", "a bad byte becomes one replacement character")

	// A hyperlink is recorded on the cells it covers.
	feed(&t, "\x1b[2J\x1b[H\x1b]8;;https://example.com\x07link\x1b]8;;\x07 plain")
	s := vt.screen(&t)
	eq_s(line(&t, 0), "link plain", "the hyperlink text prints normally")
	check(s.lines[0].cells[0].link != 0, "the first cell carries a hyperlink")
	check(s.lines[0].cells[5].link == 0, "the text after it does not")
	eq_s(s.links[s.lines[0].cells[0].link], "https://example.com", "the recorded target")

	// SS2 shifts one character to G2 and then goes back.
	feed(&t, "\x1b[2J\x1b[H\x1b*0\x1bNqq")
	eq_s(line(&t, 0), "\u2500q", "SS2 applies to exactly one character")

	// A soft reset keeps the screen but clears the pen and the region.
	feed(&t, "\x1b[2J\x1b[Hkeep\x1b[31m\x1b[2;3r\x1b[!p")
	eq_s(line(&t, 0), "keep", "a soft reset leaves the screen alone")
	eq_i(t.top, 0, "a soft reset clears the scroll region")
	check(t.cursor.pen.fg == vt.COLOR_DEFAULT, "a soft reset clears the pen")
}

test_colors :: proc() {
	t: vt.Terminal
	vt.terminal_init(&t, 10, 2, 10)
	defer vt.terminal_destroy(&t)

	feed(&t, "\x1b[31mA")
	c := vt.screen(&t).lines[0].cells[0]
	check(vt.color_is_palette(c.fg), "SGR 31 sets a palette colour")
	eq_i(int(vt.color_index(c.fg)), 1, "palette entry 1 is red")

	// Bold promotes one of the first eight colours to its bright twin.
	feed(&t, "\x1b[1;32mB")
	c = vt.screen(&t).lines[0].cells[1]
	plain := vt.terminal_resolve(&t, vt.color_palette(2), true, {})
	bright := vt.terminal_resolve(&t, c.fg, true, c.attrs)
	check(plain != bright, "bold makes one of the first eight colours bright")
	check(bright == t.palette[10], "bold green resolves to palette entry 10")

	// OSC 4 repaints a palette entry, and OSC 104 puts it back.
	before := t.palette[1]
	feed(&t, "\x1b]4;1;rgb:12/34/56\x07")
	check(t.palette[1] == vt.Rgb{0x12, 0x34, 0x56}, "OSC 4 changes the palette")
	feed(&t, "\x1b]104;1\x07")
	check(t.palette[1] == before, "OSC 104 restores one entry")

	// OSC 11 changes the background everything resolves against.
	feed(&t, "\x1b]11;rgb:00/11/22\x07")
	check(vt.terminal_bg(&t) == vt.Rgb{0, 0x11, 0x22}, "OSC 11 changes the background")
	feed(&t, "\x1b]111\x07")
	check(vt.terminal_bg(&t) == t.default_bg, "OSC 111 restores it")

	// A direct colour survives round trip through a cell.
	feed(&t, "\x1b[38;2;10;20;30mC")
	c = vt.screen(&t).lines[0].cells[2]
	check(vt.terminal_resolve(&t, c.fg, true, {}) == vt.Rgb{10, 20, 30}, "a direct colour is kept exactly")
}

test_scrollback :: proc() {
	t: vt.Terminal
	vt.terminal_init(&t, 10, 3, 5)
	defer vt.terminal_destroy(&t)
	for i in 0 ..< 20 {
		feed(&t, fmt.tprintf("line%d\r\n", i))
	}
	s := vt.screen(&t)
	check(len(s.scrollback) <= 5, "the scrollback honours its limit")
	check(len(s.scrollback) > 0, "and keeps something")
	// The most recent lines are the ones kept.
	last := s.scrollback[len(s.scrollback) - 1]
	txt := strings.builder_make(context.temp_allocator)
	for cell in last.cells {
		strings.write_rune(&txt, cell.ch == 0 ? ' ' : cell.ch)
	}
	eq_s(strings.to_string(txt), "line17", "the newest scrollback line is the one just above the screen")

	// Erasing the scrollback (what `clear` sends) empties it.
	feed(&t, "\x1b[3J")
	eq_i(len(vt.screen(&t).scrollback), 0, "ED 3 clears the history")

	// The view offset is clamped to what there is.
	for i in 0 ..< 10 {
		feed(&t, fmt.tprintf("x%d\r\n", i))
	}
	total := vt.screen_total_rows(vt.screen(&t))
	check(total >= 3, "the screen has rows")
	check(total <= 5 + 3, "the total is the scrollback plus the screen")
}

// ---------------------------------------------------------------------------

test_pty :: proc() {
	// Only commands written here are ever run: never the user's login shell
	// with their own rc files, and never anything that reads their files.
	t: vt.Terminal
	vt.terminal_init(&t, 40, 6, 100)
	defer vt.terminal_destroy(&t)

	env := child_env("xterm-256color", nil)
	argv := []string{"/bin/sh", "-c", "printf 'hello from a pty\\n'; printf 'cols=%s\\n' \"$(tput cols 2>/dev/null || echo ?)\""}
	pty, err := pty_spawn({argv = argv, env = env, cols = 40, rows = 6})
	if err != "" {
		check(false, "spawning a pty: %s", err)
		return
	}
	defer pty_close(&pty)
	check(pty.pid > 0, "the child was forked")

	buf: [4096]u8
	start := time.now()
	for time.since(start) < 5 * time.Second {
		n, done := pty_read(&pty, buf[:])
		if n > 0 {
			vt.terminal_feed(&t, buf[:n])
			continue
		}
		if done {
			break
		}
		time.sleep(2 * time.Millisecond)
	}
	eq_s(line(&t, 0), "hello from a pty", "the child's output reached the grid")
	eq_s(line(&t, 1), "cols=40", "the child saw the window size we set")
	check(pty_reap(&pty), "the child was reaped")
	eq_i(pty_exit_code(&pty), 0, "the child exited cleanly")

	// A resize must reach the child.
	t2: vt.Terminal
	vt.terminal_init(&t2, 40, 6, 100)
	defer vt.terminal_destroy(&t2)
	argv2 := []string{"/bin/sh", "-c", "sleep 0.25; printf 'cols=%s\\n' \"$(tput cols 2>/dev/null || echo ?)\""}
	pty2, err2 := pty_spawn({argv = argv2, env = env, cols = 40, rows = 6})
	if err2 != "" {
		check(false, "spawning the resize pty: %s", err2)
		return
	}
	defer pty_close(&pty2)
	pty_resize(&pty2, 100, 30)
	start = time.now()
	for time.since(start) < 5 * time.Second {
		n, done := pty_read(&pty2, buf[:])
		if n > 0 {
			vt.terminal_feed(&t2, buf[:n])
			continue
		}
		if done {
			break
		}
		time.sleep(2 * time.Millisecond)
	}
	eq_s(line(&t2, 0), "cols=100", "TIOCSWINSZ reached the child")
	pty_reap(&pty2)

	// A child that dies is noticed.
	t3: vt.Terminal
	vt.terminal_init(&t3, 20, 3, 10)
	defer vt.terminal_destroy(&t3)
	pty3, err3 := pty_spawn(
		{argv = []string{"/bin/sh", "-c", "exit 7"}, env = env, cols = 20, rows = 3},
	)
	if err3 == "" {
		defer pty_close(&pty3)
		start = time.now()
		for time.since(start) < 5 * time.Second {
			_, done := pty_read(&pty3, buf[:])
			if done {
				break
			}
			time.sleep(2 * time.Millisecond)
		}
		for i in 0 ..< 200 {
			if pty_reap(&pty3) {
				break
			}
			time.sleep(5 * time.Millisecond)
		}
		eq_i(pty_exit_code(&pty3), 7, "the child's exit code came through")
	}
}

// ---------------------------------------------------------------------------

test_render :: proc() {
	// Render a real grid into a real buffer and read the pixels back. An
	// assertion that the model is right says nothing about what is on the
	// screen; this says something about what is on the screen.
	fonts: p.Fonts
	p.fonts_init(&fonts)
	defer p.fonts_destroy(&fonts)

	r := Grid_Renderer {
		fonts = &fonts,
	}
	renderer_metrics(&r, 14, 1)
	check(r.cell_w > 3, "the cell is wider than three pixels")
	check(r.cell_h > 6, "the cell is taller than six pixels")
	renderer_resize(&r, 20, 4)
	defer renderer_destroy(&r)

	t: vt.Terminal
	vt.terminal_init(&t, 20, 4, 100)
	defer vt.terminal_destroy(&t)
	feed(&t, "\x1b[31mRED\x1b[0m \x1b[44mBLUE\x1b[0m")
	feed(&t, "\x1b[2;1H中文 wide")
	renderer_draw(&r, &t, {}, true, true)

	// The background of the fourth cell of row one is the blue we set.
	bg_x := int(f32(r.cell_w) * 3.5)
	bg_y := int(f32(r.cell_h) * 0.5)
	px := r.px[bg_y * r.w + bg_x]
	check(px == (0xFF00_0000 | 0x000B_1120), "an unpainted cell keeps the default background")

	blue_x := int(f32(r.cell_w) * 5.5)
	blue := r.px[bg_y * r.w + blue_x]
	br := u8(blue >> 16)
	bb := u8(blue)
	check(bb > br, "the cell with a blue background is more blue than red")

	// Something was actually drawn: the first row is not uniform.
	uniform := true
	first := r.px[0]
	for i in 0 ..< r.w * r.cell_h {
		if r.px[i] != first {
			uniform = false
			break
		}
	}
	check(!uniform, "the first row has glyphs on it, not just background")

	// The cursor is drawn where the cursor is.
	cx, cy := vt.terminal_cursor(&t)
	ccol := r.px[(cy * r.cell_h + r.cell_h / 2) * r.w + cx * r.cell_w + r.cell_w / 2]
	check(ccol != first, "the cursor cell differs from the background")

	// Blinking text is drawn on one phase and not on the other, and the
	// renderer says so, which is what lets an idle terminal stay idle.
	t2: vt.Terminal
	vt.terminal_init(&t2, 20, 4, 10)
	defer vt.terminal_destroy(&t2)
	feed(&t2, "\x1b[5mblink")
	r2 := Grid_Renderer {
		fonts = &fonts,
	}
	renderer_metrics(&r2, 14, 1)
	renderer_resize(&r2, 20, 4)
	defer renderer_destroy(&r2)
	renderer_draw(&r2, &t2, {}, false, true)
	check(r2.has_blink, "the renderer noticed the blinking cell")
	on := count_ink(&r2)
	renderer_draw(&r2, &t2, {}, false, false)
	off := count_ink(&r2)
	check(off < on, "the blinking text is gone on the dark phase")
	renderer_draw(&r2, &t2, {}, false, true)
	eq_i(count_ink(&r2), on, "and back on the lit phase")

	// Only the dirty rows are repainted. This is the whole reason the pixel
	// cache exists, so it is worth an assertion rather than a comment.
	r.rows_drawn = 0
	renderer_draw(&r, &t, {}, true, true)
	check(r.rows_drawn <= 2, "an unchanged screen repaints at most the cursor rows")
	feed(&t, "\x1b[4;1Hnew text")
	r.rows_drawn = 0
	renderer_draw(&r, &t, {}, true, true)
	check(r.rows_drawn <= 3, "one changed row repaints at most three")
	r.full = true
	r.rows_drawn = 0
	renderer_draw(&r, &t, {}, true, true)
	eq_i(int(r.rows_drawn), 4, "a forced repaint draws every row")
}

@(private = "file")
count_ink :: proc(r: ^Grid_Renderer) -> int {
	bg := r.px[0]
	n := 0
	for v in r.px {
		if v != bg {
			n += 1
		}
	}
	return n
}

test_render_wide :: proc() {
	// A two-cell character must paint across both of its cells and the
	// spacer must not be drawn as a character of its own. A terminal that
	// gets this wrong looks fine in the model and corrupt on the screen.
	fonts: p.Fonts
	p.fonts_init(&fonts)
	defer p.fonts_destroy(&fonts)
	r := Grid_Renderer {
		fonts = &fonts,
	}
	renderer_metrics(&r, 16, 1)
	renderer_resize(&r, 8, 2)
	defer renderer_destroy(&r)

	t: vt.Terminal
	vt.terminal_init(&t, 8, 2, 10)
	defer vt.terminal_destroy(&t)
	feed(&t, "\x1b[44m\u4e2d\x1b[0m")
	renderer_draw(&r, &t, {}, false, true)

	// Both halves of the cell carry the blue background.
	y := r.cell_h / 2
	left := r.px[y * r.w + r.cell_w / 2]
	right := r.px[y * r.w + r.cell_w + r.cell_w / 2]
	check(u8(left) > u8(left >> 16), "the left half has the blue background")
	check(u8(right) > u8(right >> 16), "the right half has it too")

	// The glyph is drawn: some pixel in the pair is neither background nor
	// the untouched default.
	ink := false
	for x in 0 ..< r.cell_w * 2 {
		for yy in 0 ..< r.cell_h {
			if r.px[yy * r.w + x] != left {
				ink = true
			}
		}
	}
	check(ink, "the wide glyph put ink on the screen")

	// The third cell is untouched default background.
	third := r.px[y * r.w + r.cell_w * 2 + r.cell_w / 2]
	check(third != left, "the cell after the wide character is not painted blue")
}
