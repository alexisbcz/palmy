package oracle

import "core:fmt"
import "core:math/rand"
import "core:os"
import "core:strings"
import vt "../vt"

// ---------------------------------------------------------------------------
// The differential test.
//
// Everything here compares apps/term/vt against libghostty-vt over a fuzz
// corpus, and prints one line per component in the form "N of M differ". A
// terminal is a large pile of special cases and a hand-written expectation
// table only ever covers the cases its author already understood; an oracle
// covers the ones they did not.
//
// This program is not part of the terminal. It is built on its own and the
// shipped binary neither links nor opens libghostty.
// ---------------------------------------------------------------------------

Report :: struct {
	name:  string,
	total: int,
	diff:  int,
}

reports: [dynamic]Report
show_diffs := false
max_show := 400

add_report :: proc(name: string, total, diff: int) {
	append(&reports, Report{name, total, diff})
}

main :: proc() {
	for a in os.args[1:] {
		if a == "-v" || a == "--show" {
			show_diffs = true
		}
	}
	name, ok := load_ghostty()
	if !ok {
		fmt.eprintln("oracle: libghostty-vt is not installed; nothing to compare against")
		os.exit(77)
	}
	fmt.printfln("oracle: comparing apps/term/vt against %s", name)

	test_width()
	test_paste()
	test_sgr()
	test_osc()
	test_keys()

	total, diff := 0, 0
	fmt.println()
	for r in reports {
		fmt.printfln("  %-24s %9s of %9s differ", r.name, commas(r.diff), commas(r.total))
		// The per-flag key rows already add up to the key total, so the
		// summary line would count them twice.
		if r.name == "key encoding (total)" {
			continue
		}
		total += r.total
		diff += r.diff
	}
	fmt.printfln("  %-24s %9s of %9s differ", "TOTAL", commas(diff), commas(total))
	os.exit(diff == 0 ? 0 : 1)
}

commas :: proc(n: int) -> string {
	s := fmt.tprintf("%d", n)
	b := strings.builder_make(context.temp_allocator)
	for i in 0 ..< len(s) {
		if i > 0 && (len(s) - i) % 3 == 0 {
			strings.write_byte(&b, ',')
		}
		strings.write_byte(&b, s[i])
	}
	return strings.to_string(b)
}

shown := 0
note :: proc(format: string, args: ..any) {
	if !show_diffs || shown >= max_show {
		return
	}
	shown += 1
	fmt.printfln(format, ..args)
}

// ---------------------------------------------------------------------------

test_width :: proc() {
	shown = 0
	diff := 0
	for cp in 0 ..< 0x110000 {
		mine := vt.rune_width(rune(cp))
		theirs := int(g.ghostty_simd_codepoint_width(u32(cp)))
		if mine != theirs {
			diff += 1
			note("  width U+%04X: ours %d, ghostty %d", cp, mine, theirs)
		}
	}
	add_report("codepoint width", 0x110000, diff)
}

test_paste :: proc() {
	shown = 0
	cases := [dynamic]string{}
	defer delete(cases)
	append(&cases, "", "hello world", "hello\nworld", "\n", "\r", "\r\n", "a\tb")
	append(&cases, "\x1b[201~", "safe\x1b[201~unsafe", "\x1b[200~x", "x\x1b", "ls -la")
	r := rand.create(0x5eed)
	ctx := rand.default_random_generator(&r)
	alphabet := "abc \n\r\x1b[]201~\t"
	for _ in 0 ..< 20000 {
		n := int(rand.int31_max(24, ctx))
		b := strings.builder_make()
		for _ in 0 ..< n {
			strings.write_byte(&b, alphabet[rand.int31_max(i32(len(alphabet)), ctx)])
		}
		append(&cases, strings.to_string(b))
	}
	diff := 0
	for c in cases {
		mine := vt.paste_is_safe(c)
		pad: [1]u8
		p := raw_data(c)
		if p == nil {
			p = raw_data(pad[:])
		}
		theirs := g.ghostty_paste_is_safe(p, uint(len(c)))
		if mine != theirs {
			diff += 1
			note("  paste %q: ours %v, ghostty %v", c, mine, theirs)
		}
	}
	add_report("paste safety", len(cases), diff)
}

// ---------------------------------------------------------------------------

sgr_tag_name :: proc(t: i32) -> string {
	names := [?]string {
		"unset", "unknown", "bold", "reset_bold", "italic", "reset_italic",
		"faint", "underline", "underline_color", "underline_color_256",
		"reset_underline_color", "overline", "reset_overline", "blink",
		"reset_blink", "inverse", "reset_inverse", "invisible",
		"reset_invisible", "strikethrough", "reset_strikethrough",
		"direct_color_fg", "direct_color_bg", "bg_8", "fg_8", "reset_fg",
		"reset_bg", "bright_bg_8", "bright_fg_8", "bg_256", "fg_256",
	}
	if t < 0 || int(t) >= len(names) {
		return "?"
	}
	return names[t]
}

// describe_theirs renders one libghostty attribute as a comparable string.
describe_theirs :: proc(a: ^G_Sgr_Attr) -> string {
	v := transmute(^[64]u8)&a.value
	switch a.tag {
	case 7: // underline
		u := (transmute(^i32)v)^
		return fmt.tprintf("underline:%d", u)
	case 8, 21, 22: // underline_color, direct fg, direct bg
		return fmt.tprintf("%s:%d,%d,%d", sgr_tag_name(a.tag), v[0], v[1], v[2])
	case 9, 23, 24, 27, 28, 29, 30: // the palette-index carrying tags
		return fmt.tprintf("%s:%d", sgr_tag_name(a.tag), v[0])
	}
	return sgr_tag_name(a.tag)
}

describe_mine :: proc(a: vt.Sgr_Attr) -> string {
	switch a.tag {
	case .Underline:
		return fmt.tprintf("underline:%d", int(a.underline))
	case .Underline_Color, .Direct_Color_Fg, .Direct_Color_Bg:
		return fmt.tprintf("%s:%d,%d,%d", sgr_tag_name(i32(a.tag)), a.rgb[0], a.rgb[1], a.rgb[2])
	case .Underline_Color_256, .Bg_8, .Fg_8, .Bright_Bg_8, .Bright_Fg_8, .Bg_256, .Fg_256:
		return fmt.tprintf("%s:%d", sgr_tag_name(i32(a.tag)), a.idx)
	case .Unset, .Unknown, .Bold, .Reset_Bold, .Italic, .Reset_Italic, .Faint,
	     .Reset_Underline_Color, .Overline, .Reset_Overline, .Blink,
	     .Reset_Blink, .Inverse, .Reset_Inverse, .Invisible, .Reset_Invisible,
	     .Strikethrough, .Reset_Strikethrough, .Reset_Fg, .Reset_Bg:
	}
	return sgr_tag_name(i32(a.tag))
}

test_sgr :: proc() {
	shown = 0
	parser: rawptr
	if g.ghostty_sgr_new(nil, &parser) != 0 {
		fmt.eprintln("oracle: could not create an SGR parser")
		os.exit(1)
	}
	defer g.ghostty_sgr_free(parser)

	cases := build_sgr_corpus()
	defer {
		for c in cases {
			delete(c.params)
			delete(c.seps)
		}
		delete(cases)
	}

	diff := 0
	for c in cases {
		// Ours.
		mine := strings.builder_make()
		defer strings.builder_destroy(&mine)
		sp := vt.sgr_begin(c.params, c.seps)
		for {
			a, ok := vt.sgr_next(&sp)
			if !ok {
				break
			}
			strings.write_string(&mine, describe_mine(a))
			strings.write_byte(&mine, '|')
		}

		// Theirs.
		theirs := strings.builder_make()
		defer strings.builder_destroy(&theirs)
		g.ghostty_sgr_set_params(
			parser,
			raw_data(c.params),
			len(c.seps) > 0 ? raw_data(c.seps) : nil,
			uint(len(c.params)),
		)
		attr: G_Sgr_Attr
		for g.ghostty_sgr_next(parser, &attr) {
			strings.write_string(&theirs, describe_theirs(&attr))
			strings.write_byte(&theirs, '|')
		}

		if strings.to_string(mine) != strings.to_string(theirs) {
			diff += 1
			note("  sgr %s: ours %q, ghostty %q", c.text, strings.to_string(mine), strings.to_string(theirs))
		}
	}
	add_report("SGR attributes", len(cases), diff)
}

Sgr_Case :: struct {
	params: []u16,
	seps:   []u8,
	text:   string,
}

build_sgr_corpus :: proc() -> [dynamic]Sgr_Case {
	out: [dynamic]Sgr_Case
	add :: proc(out: ^[dynamic]Sgr_Case, params: []u16, seps: []u8) {
		p := make([]u16, len(params))
		copy(p, params)
		s := make([]u8, len(seps))
		copy(s, seps)
		b := strings.builder_make()
		for v, i in p {
			if i > 0 {
				strings.write_byte(&b, s[i - 1] == ':' ? ':' : ';')
			}
			strings.write_int(&b, int(v))
		}
		append(out, Sgr_Case{p, s, strings.to_string(b)})
	}

	// Every single parameter on its own.
	for v in u16(0) ..= 130 {
		add(&out, {v}, {';'})
	}
	// The colour forms, exhaustively over a sample of values.
	vals := [?]u16{0, 1, 2, 5, 7, 8, 15, 16, 128, 255, 256, 300, 65534}
	for base in ([?]u16{38, 48, 58}) {
		for k in ([?]u16{0, 1, 2, 3, 4, 5, 6}) {
			for a in vals {
				add(&out, {base, k, a}, {';', ';', ';'})
				add(&out, {base, k, a}, {':', ':', ';'})
				for b in vals {
					add(&out, {base, k, a, b, a}, {';', ';', ';', ';', ';'})
					add(&out, {base, k, a, b, a}, {':', ':', ':', ':', ';'})
					add(&out, {base, k, a, a, b, a}, {':', ':', ':', ':', ':', ';'})
				}
			}
		}
	}
	// Underline styles, both spellings.
	for v in u16(0) ..= 8 {
		add(&out, {4, v}, {':', ';'})
		add(&out, {4, v}, {';', ';'})
	}
	// Random lists, which is where the mixed separators get exercised.
	r := rand.create(0xC0FFEE)
	ctx := rand.default_random_generator(&r)
	interesting := [?]u16{0, 1, 2, 3, 4, 5, 7, 9, 21, 22, 24, 30, 38, 39, 48, 49, 53, 58, 59, 90, 100, 107, 255, 2, 5}
	for _ in 0 ..< 40000 {
		n := 1 + int(rand.int31_max(7, ctx))
		ps := make([]u16, n, context.temp_allocator)
		ss := make([]u8, n, context.temp_allocator)
		for i in 0 ..< n {
			if rand.int31_max(3, ctx) == 0 {
				ps[i] = u16(rand.int31_max(260, ctx))
			} else {
				ps[i] = interesting[rand.int31_max(i32(len(interesting)), ctx)]
			}
			ss[i] = i == n - 1 ? ';' : (rand.int31_max(2, ctx) == 0 ? ':' : ';')
		}
		add(&out, ps, ss)
	}
	free_all(context.temp_allocator)
	return out
}

// ---------------------------------------------------------------------------

osc_type_of :: proc(k: vt.Osc_Kind) -> i32 {
	switch k {
	case .Invalid:
		return 0
	case .Set_Title:
		return 1
	case .Set_Icon:
		return 2
	case .Semantic_Prompt:
		return 3
	case .Clipboard_Write, .Clipboard_Query:
		return 4
	case .Set_Pwd:
		return 5
	case .Mouse_Shape:
		return 6
	case .Set_Palette, .Query_Palette, .Reset_Palette, .Set_Default_Color,
	     .Query_Default_Color, .Reset_Default_Color, .Reset_Cursor_Color,
	     .Color_Op_Unknown:
		return 7
	case .Kitty_Color:
		return 8
	case .Notification:
		return 9
	case .Hyperlink_Start:
		return 10
	case .Hyperlink_End:
		return 11
	case .Conemu_Sleep:
		return 12
	case .Conemu_Message_Box:
		return 13
	case .Conemu_Tab_Title:
		return 14
	case .Conemu_Progress:
		return 15
	case .Conemu_Wait_Input:
		return 16
	}
	return 0
}

test_osc :: proc() {
	shown = 0
	parser: rawptr
	if g.ghostty_osc_new(nil, &parser) != 0 {
		fmt.eprintln("oracle: could not create an OSC parser")
		os.exit(1)
	}
	defer g.ghostty_osc_free(parser)

	cases := build_osc_corpus()
	defer delete(cases)

	diff_type := 0
	diff_title := 0
	titles := 0
	for c in cases {
		mine := vt.osc_parse(transmute([]u8)c, 0x07)
		g.ghostty_osc_reset(parser)
		for i in 0 ..< len(c) {
			g.ghostty_osc_next(parser, c[i])
		}
		cmd := g.ghostty_osc_end(parser, 0x07)
		theirs := g.ghostty_osc_command_type(cmd)

		if osc_type_of(mine.kind) != theirs {
			diff_type += 1
			note("  osc %q: ours %v (%d), ghostty %d", c, mine.kind, osc_type_of(mine.kind), theirs)
		}
		if theirs == 1 {
			titles += 1
			s: cstring
			if g.ghostty_osc_command_data(cmd, 1, &s) {
				if string(s) != mine.text {
					diff_title += 1
					note("  osc title %q: ours %q, ghostty %q", c, mine.text, string(s))
				}
			}
		}
	}
	add_report("OSC command type", len(cases), diff_type)
	add_report("OSC title payload", titles, diff_title)
}

build_osc_corpus :: proc() -> [dynamic]string {
	out: [dynamic]string
	fixed := [?]string {
		"0;hello", "0;", "1;icon", "2;a title with spaces", "2", "",
		"7;file:///home/user", "7;", "8;;https://example.com", "8;;",
		"8;id=xyz;https://example.com/a?b=c",
		"4;1;rgb:ff/00/00", "4;1;?", "4;256;rgb:00/00/00", "104", "104;5",
		"10;?", "11;?", "10;rgb:11/22/33", "11;#001122", "110", "111", "112",
		"52;c;aGVsbG8=", "52;c;?", "52;p;", "52;;aGk=",
		"133;A", "133;B;aid=1", "22;pointer", "9;notify", "777;notify;a;b",
		"21;foreground=?", "xyz", ";", "0", "99999999;x", "2;;;",
		"8;id=1:id=2;http://x", "4;0;rgb:1/2/3", "4;0;rgb:1111/2222/3333",
	}
	for f in fixed {
		append(&out, f)
	}
	r := rand.create(0xBEEF)
	ctx := rand.default_random_generator(&r)
	heads := [?]string{"0", "1", "2", "4", "7", "8", "9", "10", "11", "12", "21", "22", "52", "104", "110", "133", "777", "3", "99"}
	tails := [?]string{"", ";", ";x", ";?", ";rgb:ff/00/aa", ";#112233", ";1;?", ";1;rgb:0/0/0", ";c;aGk=", ";;u", ";id=a;u", ";A", "x", ";;", ";1;2;3"}
	for _ in 0 ..< 4000 {
		h := heads[rand.int31_max(i32(len(heads)), ctx)]
		t := tails[rand.int31_max(i32(len(tails)), ctx)]
		append(&out, strings.concatenate({h, t}))
	}
	return out
}

// ---------------------------------------------------------------------------

test_keys :: proc() {
	shown = 0
	enc: rawptr
	if g.ghostty_key_encoder_new(nil, &enc) != 0 {
		fmt.eprintln("oracle: could not create a key encoder")
		os.exit(1)
	}
	defer g.ghostty_key_encoder_free(enc)
	ev: rawptr
	if g.ghostty_key_event_new(nil, &ev) != 0 {
		fmt.eprintln("oracle: could not create a key event")
		os.exit(1)
	}
	defer g.ghostty_key_event_free(ev)

	mod_sets := [?]u16 {
		0,
		vt.MOD_SHIFT,
		vt.MOD_CTRL,
		vt.MOD_ALT,
		vt.MOD_SUPER,
		vt.MOD_CTRL | vt.MOD_SHIFT,
		vt.MOD_CTRL | vt.MOD_ALT,
		vt.MOD_ALT | vt.MOD_SHIFT,
		vt.MOD_CTRL | vt.MOD_ALT | vt.MOD_SHIFT,
		vt.MOD_CAPS,
		vt.MOD_NUM,
	}
	kitty_sets := [?]u8{0, 0x01, 0x03, 0x05, 0x09, 0x11, 0x1F}
	if len(os.args) > 2 && os.args[1] == "--only" {
		v: u8
		for c in os.args[2] {
			v = v * 16 + u8(c - (c <= '9' ? '0' : 'a' - 10))
		}
		kitty_sets = {v, v, v, v, v, v, v}
	}
	actions := [?]vt.Key_Action{.Press, .Repeat, .Release}

	total, diff := 0, 0
	buckets: map[string]int
	defer delete(buckets)

	for kf0 in kitty_sets {
		kf := kf0
		sub_total, sub_diff := 0, 0
		for cka in ([?]bool{false, true}) {
			for aep in ([?]bool{false, true}) {
				e := vt.Key_Encoder {
					kitty_flags            = kf,
					cursor_key_application = cka,
					alt_esc_prefix         = aep,
				}
				g.ghostty_key_encoder_setopt(enc, OPT_KITTY_FLAGS, &kf)
				c1 := cka
				g.ghostty_key_encoder_setopt(enc, OPT_CURSOR_KEY_APPLICATION, &c1)
				c2 := aep
				g.ghostty_key_encoder_setopt(enc, OPT_ALT_ESC_PREFIX, &c2)

				for ki in 0 ..< vt.KEY_COUNT {
					k := vt.Key(ki)
					for mods in mod_sets {
						for act in actions {
							text, cp := key_text(k, mods)
							kev := vt.Key_Event {
								action              = act,
								key                 = k,
								mods                = mods,
								utf8                = text,
								unshifted_codepoint = cp,
							}
							buf: [256]u8
							mine := vt.key_encode(e, kev, buf[:])

							g.ghostty_key_event_set_action(ev, i32(act))
							g.ghostty_key_event_set_key(ev, i32(ki))
							g.ghostty_key_event_set_mods(ev, mods)
							g.ghostty_key_event_set_consumed_mods(ev, 0)
							g.ghostty_key_event_set_composing(ev, false)
							g.ghostty_key_event_set_utf8(
								ev,
								len(text) > 0 ? raw_data(text) : nil,
								uint(len(text)),
							)
							g.ghostty_key_event_set_unshifted_codepoint(ev, u32(cp))
							gbuf: [256]u8
							n: uint
							res := g.ghostty_key_encoder_encode(enc, ev, raw_data(gbuf[:]), 256, &n)
							theirs := res == 0 ? gbuf[:n] : []u8{}

							total += 1
							sub_total += 1
							if string(mine) != string(theirs) {
								diff += 1
								sub_diff += 1
								key := fmt.aprintf("kitty=%02x key=%v", kf, k)
								if _, seen := buckets[key]; !seen {
									buckets[key] = 0
								}
								buckets[key] += 1
								note(
									"  key %v mods=%d act=%v kitty=%02x cka=%v aep=%v: ours %q, ghostty %q",
									k, mods, act, kf, cka, aep, string(mine), string(theirs),
								)
							}
						}
					}
				}
			}
		}
		label: string
		switch kf {
		case 0:
			label = "  keys: legacy"
		case vt.KITTY_DISAMBIGUATE:
			label = "  keys: kitty disamb"
		case 0x1F:
			label = "  keys: kitty all"
		case:
			label = fmt.aprintf("  keys: kitty 0x%02x", kf)
		}
		add_report(label, sub_total, sub_diff)
	}
	if show_diffs {
		fmt.println("  diff buckets:")
		shown2 := 0
		for k, v in buckets {
			if shown2 >= 40 {
				break
			}
			shown2 += 1
			fmt.printfln("    %-40s %d", k, v)
		}
	}
	add_report("key encoding (total)", total, diff)
}

// key_text supplies the text a key would produce on a US layout, which is what
// a real keyboard driver would hand the encoder.
key_text :: proc(k: vt.Key, mods: u16) -> (string, rune) {
	shift := mods & vt.MOD_SHIFT != 0
	lower := "abcdefghijklmnopqrstuvwxyz"
	upper := "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
	ki := int(k)
	a := int(vt.Key.A)
	if ki >= a && ki <= a + 25 {
		i := ki - a
		return shift ? upper[i:i + 1] : lower[i:i + 1], rune(lower[i])
	}
	d0 := int(vt.Key.Digit_0)
	if ki >= d0 && ki <= d0 + 9 {
		digits := "0123456789"
		shifted := ")!@#$%^&*("
		i := ki - d0
		return shift ? shifted[i:i + 1] : digits[i:i + 1], rune(digits[i])
	}
	#partial switch k {
	case .Space:
		return " ", ' '
	case .Minus:
		return shift ? "_" : "-", '-'
	case .Equal:
		return shift ? "+" : "=", '='
	case .Bracket_Left:
		return shift ? "{" : "[", '['
	case .Bracket_Right:
		return shift ? "}" : "]", ']'
	case .Backslash:
		return shift ? "|" : "\\", '\\'
	case .Semicolon:
		return shift ? ":" : ";", ';'
	case .Quote:
		return shift ? "\"" : "'", '\''
	case .Backquote:
		return shift ? "~" : "`", '`'
	case .Comma:
		return shift ? "<" : ",", ','
	case .Period:
		return shift ? ">" : ".", '.'
	case .Slash:
		return shift ? "?" : "/", '/'
	}
	return "", 0
}
