// Calc — an expression calculator for palmy.
//
// The engine is in expr.odin: a real tokeniser and a recursive-descent parser
// with precedence, parentheses, functions, constants and variables. This file
// is the state and the keyboard; ui.odin is the frame.
package main

import "core:fmt"
import "core:os"
import "core:strings"
import kit "kit:."
import p "palmy:."

tfmt :: fmt.tprintf

HEADER_H :: 52
STATUS_H :: 26
SIDE_W :: 320
PAD_COLS :: 5
PAD_ROWS :: 6
ACCENT :: 0x2563eb

Pane :: enum {
	Input,
	Pad,
	History,
}

Entry :: struct {
	expr:   string,
	out:    string,
	assign: string,
	ok:     bool,
	msg:    string,
}

Calc :: struct {
	input:    [dynamic]u8,
	cur:      int,
	live:     Result,
	live_msg: string, // the live error, owned: Result's message is temporary
	hist:     [dynamic]Entry,
	hist_sel: int,
	vars:     map[string]f64,
	names:    [dynamic]string, // in the order they were first assigned
	deg:      bool,
	pane:     Pane,
	pad:      int, // index into PAD
	help:     bool,
	swallow:  bool,
	toast:    string,
	toast_at: f64,
	browse:   int, // where Up/Down through history has walked to, -1 when idle
}

// ---------------------------------------------------------------------------
// The button pad
// ---------------------------------------------------------------------------

Pad_Act :: enum {
	Insert,
	Back,
	Clear,
	Eval,
}

Pad_Key :: struct {
	label: string,
	text:  string,
	act:   Pad_Act,
	tone:  int, // 0 plain, 1 operator, 2 function, 3 accent
}

PAD := [PAD_ROWS * PAD_COLS]Pad_Key {
	{"sqrt", "sqrt(", .Insert, 2},
	{"^", "^", .Insert, 1},
	{"(", "(", .Insert, 1},
	{")", ")", .Insert, 1},
	{"clear", "", .Clear, 1},
	{"7", "7", .Insert, 0},
	{"8", "8", .Insert, 0},
	{"9", "9", .Insert, 0},
	{"/", "/", .Insert, 1},
	{"del", "", .Back, 1},
	{"4", "4", .Insert, 0},
	{"5", "5", .Insert, 0},
	{"6", "6", .Insert, 0},
	{"*", "*", .Insert, 1},
	{"%", "%", .Insert, 1},
	{"1", "1", .Insert, 0},
	{"2", "2", .Insert, 0},
	{"3", "3", .Insert, 0},
	{"-", "-", .Insert, 1},
	{"pi", "pi", .Insert, 2},
	{"0", "0", .Insert, 0},
	{".", ".", .Insert, 0},
	{"e", "e", .Insert, 2},
	{"+", "+", .Insert, 1},
	{"=", "", .Eval, 3},
	{"sin", "sin(", .Insert, 2},
	{"cos", "cos(", .Insert, 2},
	{"tan", "tan(", .Insert, 2},
	{"ln", "ln(", .Insert, 2},
	{"log", "log(", .Insert, 2},
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

main :: proc() {
	// `calc <expression>` opens with it already typed in, and `calc --eval
	// <expression>` answers on stdout and exits. The parser is the same one
	// the window uses, so the two can never disagree.
	args := os.args[1:]
	if len(args) > 0 && args[0] == "--selftest" {
		run_selftest()
		os.exit(failures == 0 ? 0 : 1)
	}
	eval_only := len(args) > 0 && args[0] == "--eval"
	if eval_only {
		args = args[1:]
	}
	initial := strings.join(args, " ", context.temp_allocator)
	if eval_only {
		vars := make(map[string]f64)
		r := evaluate(initial, &vars, false)
		if !r.ok {
			fmt.eprintfln("%s", initial)
			for _ in 0 ..< r.err.pos {
				fmt.eprint(" ")
			}
			for _ in 0 ..< max(1, r.err.len) {
				fmt.eprint("^")
			}
			fmt.eprintfln("\n%s", r.err.msg)
			os.exit(1)
		}
		fmt.println(fmt_num(r.value))
		return
	}

	app, err := kit.start(
		{
			title = "Calculator",
			width = 1000,
			height = 700,
			min_width = 720,
			min_height = 480,
			root_class = "w-full h-full bg-background text-foreground",
		},
	)
	if err != "" {
		fmt.eprintfln("calc: %s", err)
		os.exit(1)
	}
	defer p.destroy(app)
	p.register_color("accent-blue", p.hex(ACCENT))

	c := Calc {
		browse = -1,
	}
	c.vars = make(map[string]f64)
	// `ans` always exists so a fresh session can refer to it.
	set_var(&c, "ans", 0)
	// Something on screen from the first frame beats an empty box.
	for b in transmute([]u8)(initial != "" ? initial : "2 * (3 + 4)^2") {
		append(&c.input, b)
	}
	c.cur = len(c.input)
	recompute(&c)

	for ui in p.frames(app) {
		keys(ui, &c, app)
		frame(ui, &c)
	}
}

// set_var owns its key.
//
// The name arrives as a slice of the tokeniser's view of the input buffer, and
// that buffer is cleared and typed over on the very next keystroke. Storing it
// as a map key without copying it leaves the key pointing at whatever is typed
// next, so `r = 4.5` followed by `area = pi * r^2` reported that r was not
// defined — the variable was there, under a name that had been overwritten.
set_var :: proc(c: ^Calc, name: string, v: f64) {
	if _, found := c.vars[name]; found {
		// The map keeps the key it already has, which is one we own.
		c.vars[name] = v
		return
	}
	key := strings.clone(name)
	c.vars[key] = v
	append(&c.names, key)
}

note :: proc(c: ^Calc, msg: string) {
	delete(c.toast)
	c.toast = strings.clone(msg)
	c.toast_at = 0
}

recompute :: proc(c: ^Calc) {
	// The live result is evaluated against a copy of the variables, so typing
	// `x = ` halfway through does not assign anything yet.
	scratch := make(map[string]f64, context.temp_allocator)
	for k, v in c.vars {
		scratch[k] = v
	}
	c.live = evaluate(string(c.input[:]), &scratch, c.deg)
	// The parser builds its messages in the frame allocator; the display
	// reads them again on every later frame, so keep a copy that outlives it.
	delete(c.live_msg)
	c.live_msg = strings.clone(c.live.err.msg)
	c.live.err.msg = c.live_msg
}

commit :: proc(c: ^Calc) {
	src := strings.trim_space(string(c.input[:]))
	if src == "" {
		return
	}
	r := evaluate(src, &c.vars, c.deg)
	e := Entry {
		expr   = strings.clone(src),
		ok     = r.ok,
		assign = strings.clone(r.assign),
	}
	if r.ok {
		e.out = strings.clone(fmt_num(r.value))
		set_var(c, "ans", r.value)
		if r.assign != "" {
			set_var(c, r.assign, r.value)
		}
	} else {
		e.out = strings.clone("—")
		e.msg = strings.clone(r.err.msg)
	}
	append(&c.hist, e)
	c.hist_sel = len(c.hist) - 1
	c.browse = -1
	clear(&c.input)
	c.cur = 0
	recompute(c)
}

insert_text :: proc(c: ^Calc, s: string) {
	bytes := transmute([]u8)s
	inject_at_elems(&c.input, min(c.cur, len(c.input)), ..bytes)
	c.cur = min(c.cur, len(c.input)) + len(bytes)
	c.browse = -1
	recompute(c)
}

backspace :: proc(c: ^Calc) {
	if c.cur <= 0 {
		return
	}
	n := 1
	for n < c.cur && c.input[c.cur - n] & 0xc0 == 0x80 {
		n += 1
	}
	remove_range(&c.input, c.cur - n, c.cur)
	c.cur -= n
	recompute(c)
}

press_pad :: proc(c: ^Calc, k: Pad_Key) {
	switch k.act {
	case .Insert:
		insert_text(c, k.text)
	case .Back:
		backspace(c)
	case .Clear:
		clear(&c.input)
		c.cur = 0
		recompute(c)
	case .Eval:
		commit(c)
	}
}

// ---------------------------------------------------------------------------
// Keyboard
// ---------------------------------------------------------------------------

plain :: proc(ui: ^p.Ctx, sym: u32) -> bool {
	for k in ui.input.keys {
		if k.sym == sym && !k.repeat && k.mods & {.Shift, .Ctrl, .Alt, .Super} == {} {
			return true
		}
	}
	return false
}

times :: proc(ui: ^p.Ctx, sym: u32) -> int {
	n := 0
	for k in ui.input.keys {
		if k.sym == sym && k.mods & {.Ctrl, .Alt, .Super} == {} {
			n += 1
		}
	}
	return n
}

keys :: proc(ui: ^p.Ctx, c: ^Calc, app: ^p.App) {
	swallow := c.swallow
	c.swallow = false

	if p.shortcut(ui, 'q', {.Ctrl}) {
		p.quit_app(app)
		return
	}
	if plain(ui, p.KEY_F1) {
		c.help = !c.help
		c.swallow = true
		return
	}
	if c.help {
		if plain(ui, p.KEY_ESCAPE) || plain(ui, p.KEY_RETURN) {
			c.help = false
		}
		return
	}
	if plain(ui, p.KEY_F2) {
		c.deg = !c.deg
		recompute(c)
		note(c, c.deg ? "Angles in degrees" : "Angles in radians")
	}
	if p.shortcut(ui, 'l', {.Ctrl}) {
		clear_history(c)
		note(c, "History cleared")
	}
	if p.shortcut(ui, 'c', {.Ctrl}) {
		copy_result(c)
	}

	if plain(ui, p.KEY_TAB) {
		c.pane = Pane((int(c.pane) + 1) % len(Pane))
		c.swallow = true
		return
	}
	if p.shortcut(ui, p.KEY_TAB, {.Shift}) {
		c.pane = Pane((int(c.pane) + len(Pane) - 1) % len(Pane))
		c.swallow = true
		return
	}

	switch c.pane {
	case .Pad:
		if n := times(ui, p.KEY_RIGHT); n > 0 {
			c.pad = min(c.pad + n, len(PAD) - 1)
		}
		if n := times(ui, p.KEY_LEFT); n > 0 {
			c.pad = max(c.pad - n, 0)
		}
		if n := times(ui, p.KEY_DOWN); n > 0 {
			c.pad = min(c.pad + n * PAD_COLS, len(PAD) - 1)
		}
		if n := times(ui, p.KEY_UP); n > 0 {
			c.pad = max(c.pad - n * PAD_COLS, 0)
		}
		if plain(ui, p.KEY_RETURN) || plain(ui, p.KEY_SPACE) {
			press_pad(c, PAD[c.pad])
		}
		if plain(ui, p.KEY_ESCAPE) {
			c.pane = .Input
		}
		if plain(ui, p.KEY_BACKSPACE) {
			backspace(c)
		}

	case .History:
		if n := times(ui, p.KEY_DOWN); n > 0 && len(c.hist) > 0 {
			c.hist_sel = min(c.hist_sel + n, len(c.hist) - 1)
		}
		if n := times(ui, p.KEY_UP); n > 0 && len(c.hist) > 0 {
			c.hist_sel = max(c.hist_sel - n, 0)
		}
		if plain(ui, p.KEY_HOME) {
			c.hist_sel = 0
		}
		if plain(ui, p.KEY_END) {
			c.hist_sel = max(0, len(c.hist) - 1)
		}
		if plain(ui, p.KEY_RETURN) && c.hist_sel < len(c.hist) {
			reuse(c, c.hist[c.hist_sel])
		}
		if plain(ui, p.KEY_DELETE) && c.hist_sel < len(c.hist) {
			drop_entry(c, c.hist_sel)
		}
		if plain(ui, p.KEY_ESCAPE) {
			c.pane = .Input
		}

	case .Input:
		if plain(ui, p.KEY_RETURN) {
			commit(c)
			return
		}
		if plain(ui, p.KEY_ESCAPE) {
			if len(c.input) > 0 {
				clear(&c.input)
				c.cur = 0
				recompute(c)
			}
		}
		for _ in 0 ..< times(ui, p.KEY_BACKSPACE) {
			backspace(c)
		}
		for _ in 0 ..< times(ui, p.KEY_DELETE) {
			if c.cur < len(c.input) {
				n := 1
				for c.cur + n < len(c.input) && c.input[c.cur + n] & 0xc0 == 0x80 {
					n += 1
				}
				remove_range(&c.input, c.cur, c.cur + n)
				recompute(c)
			}
		}
		if n := times(ui, p.KEY_LEFT); n > 0 {
			for _ in 0 ..< n {
				if c.cur > 0 {
					c.cur -= 1
					for c.cur > 0 && c.input[c.cur] & 0xc0 == 0x80 {
						c.cur -= 1
					}
				}
			}
		}
		if n := times(ui, p.KEY_RIGHT); n > 0 {
			for _ in 0 ..< n {
				if c.cur < len(c.input) {
					c.cur += 1
					for c.cur < len(c.input) && c.input[c.cur] & 0xc0 == 0x80 {
						c.cur += 1
					}
				}
			}
		}
		if plain(ui, p.KEY_HOME) || p.shortcut(ui, 'a', {.Ctrl}) {
			c.cur = 0
		}
		if plain(ui, p.KEY_END) || p.shortcut(ui, 'e', {.Ctrl}) {
			c.cur = len(c.input)
		}
		if p.shortcut(ui, 'u', {.Ctrl}) {
			clear(&c.input)
			c.cur = 0
			recompute(c)
		}
		// Up and Down walk the history into the input, the way a shell does.
		if times(ui, p.KEY_UP) > 0 && len(c.hist) > 0 {
			c.browse = c.browse < 0 ? len(c.hist) - 1 : max(0, c.browse - 1)
			load_browse(c)
		}
		if times(ui, p.KEY_DOWN) > 0 && c.browse >= 0 {
			if c.browse + 1 >= len(c.hist) {
				c.browse = -1
				clear(&c.input)
				c.cur = 0
				recompute(c)
			} else {
				c.browse += 1
				load_browse(c)
			}
		}
		if typed := p.typed_text(ui); len(typed) > 0 && !swallow {
			keep := make([dynamic]u8, 0, len(typed), context.temp_allocator)
			for b in transmute([]u8)typed {
				if b >= 0x20 && b != 0x7f {
					append(&keep, b)
				}
			}
			if len(keep) > 0 {
				insert_text(c, string(keep[:]))
			}
		}
	}
}

load_browse :: proc(c: ^Calc) {
	if c.browse < 0 || c.browse >= len(c.hist) {
		return
	}
	clear(&c.input)
	append(&c.input, ..transmute([]u8)c.hist[c.browse].expr)
	c.cur = len(c.input)
	c.hist_sel = c.browse
	recompute(c)
}

reuse :: proc(c: ^Calc, e: Entry) {
	// Reusing a result is more often wanted than reusing the expression, so
	// a successful entry hands over its value and a failed one its source.
	text := e.ok && e.assign == "" ? e.out : e.expr
	clean, _ := strings.remove_all(text, " ", context.temp_allocator)
	clear(&c.input)
	append(&c.input, ..transmute([]u8)clean)
	c.cur = len(c.input)
	c.pane = .Input
	c.browse = -1
	recompute(c)
}

copy_result :: proc(c: ^Calc) {
	text := ""
	if c.pane == .History && c.hist_sel < len(c.hist) {
		text = c.hist[c.hist_sel].out
	} else if c.live.ok {
		text = fmt_num(c.live.value)
	}
	if text == "" {
		note(c, "Nothing to copy")
		return
	}
	clean, _ := strings.remove_all(text, " ", context.temp_allocator)
	if kit.clipboard_set(clean) {
		note(c, tfmt("Copied %s", clean))
	} else {
		note(c, "wl-copy is not installed")
	}
}

drop_entry :: proc(c: ^Calc, i: int) {
	if i < 0 || i >= len(c.hist) {
		return
	}
	e := c.hist[i]
	delete(e.expr)
	delete(e.out)
	delete(e.assign)
	delete(e.msg)
	ordered_remove(&c.hist, i)
	c.hist_sel = clamp(c.hist_sel, 0, max(0, len(c.hist) - 1))
}

clear_history :: proc(c: ^Calc) {
	for e in c.hist {
		delete(e.expr)
		delete(e.out)
		delete(e.assign)
		delete(e.msg)
	}
	clear(&c.hist)
	c.hist_sel = 0
	c.browse = -1
}
