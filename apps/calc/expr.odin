// The expression engine: a tokeniser and a recursive-descent parser.
//
// Every error carries the byte offset and length of the token that caused it,
// because "error" on its own is useless and a caret under the offending
// character is the whole difference between a toy and a tool.
//
// Grammar, lowest precedence first:
//
//	statement   := ident '=' expr | expr
//	expr        := term (('+' | '-') term)*
//	term        := unary (('*' | '/' | '%') unary)*
//	unary       := ('-' | '+') unary | power
//	power       := postfix ('^' unary)?        right associative
//	postfix     := primary '!'*
//	primary     := number | ident | ident '(' args ')' | '(' expr ')'
//
// `^` binds tighter than unary minus, so -2^2 is -4, and its right operand is
// a unary so 2^-1 parses. Both match what a calculator user expects.
package main

import "core:math"
import "core:strconv"
import "core:strings"

Kind :: enum {
	End,
	Num,
	Ident,
	Plus,
	Minus,
	Star,
	Slash,
	Percent,
	Caret,
	Bang,
	LParen,
	RParen,
	Comma,
	Assign,
	Bad,
}

Token :: struct {
	kind: Kind,
	pos:  int,
	len:  int,
	num:  f64,
	text: string,
}

Err :: struct {
	msg: string,
	pos: int,
	len: int,
}

// ---------------------------------------------------------------------------
// Tokeniser
// ---------------------------------------------------------------------------

is_digit :: proc(c: u8) -> bool {
	return c >= '0' && c <= '9'
}

is_ident_start :: proc(c: u8) -> bool {
	return c == '_' || (c | 32 >= 'a' && c | 32 <= 'z')
}

is_ident :: proc(c: u8) -> bool {
	return is_ident_start(c) || is_digit(c)
}

tokenise :: proc(src: string, allocator := context.temp_allocator) -> []Token {
	out := make([dynamic]Token, 0, 32, allocator)
	i := 0
	for i < len(src) {
		c := src[i]
		if c == ' ' || c == '\t' {
			i += 1
			continue
		}
		start := i

		if is_digit(c) || (c == '.' && i + 1 < len(src) && is_digit(src[i + 1])) {
			for i < len(src) && (is_digit(src[i]) || src[i] == '_') {
				i += 1
			}
			if i < len(src) && src[i] == '.' {
				i += 1
				for i < len(src) && (is_digit(src[i]) || src[i] == '_') {
					i += 1
				}
			}
			if i < len(src) && src[i] | 32 == 'e' {
				j := i + 1
				if j < len(src) && (src[j] == '+' || src[j] == '-') {
					j += 1
				}
				if j < len(src) && is_digit(src[j]) {
					i = j
					for i < len(src) && is_digit(src[i]) {
						i += 1
					}
				}
			}
			raw, _ := strings.replace_all(src[start:i], "_", "", allocator)
			v, ok := strconv.parse_f64(raw)
			append(
				&out,
				Token {
					kind = ok ? .Num : .Bad,
					pos = start,
					len = i - start,
					num = v,
					text = src[start:i],
				},
			)
			continue
		}

		if is_ident_start(c) {
			for i < len(src) && is_ident(src[i]) {
				i += 1
			}
			append(&out, Token{kind = .Ident, pos = start, len = i - start, text = src[start:i]})
			continue
		}

		k := Kind.Bad
		switch c {
		case '+':
			k = .Plus
		case '-':
			k = .Minus
		case '*':
			k = .Star
		case '/':
			k = .Slash
		case '%':
			k = .Percent
		case '^':
			k = .Caret
		case '!':
			k = .Bang
		case '(':
			k = .LParen
		case ')':
			k = .RParen
		case ',':
			k = .Comma
		case '=':
			k = .Assign
		}
		i += 1
		// ** is an alias for ^, which people type out of habit.
		if k == .Star && i < len(src) && src[i] == '*' {
			i += 1
			k = .Caret
		}
		append(&out, Token{kind = k, pos = start, len = i - start, text = src[start:i]})
	}
	append(&out, Token{kind = .End, pos = len(src), len = 0})
	return out[:]
}

// ---------------------------------------------------------------------------
// Parser
// ---------------------------------------------------------------------------

P :: struct {
	src:  string,
	toks: []Token,
	i:    int,
	vars: ^map[string]f64,
	deg:  bool,
	err:  Err,
	fail: bool,
}

Result :: struct {
	value:  f64,
	assign: string, // the variable this statement wrote, "" for a plain expression
	err:    Err,
	ok:     bool,
}

peek :: proc(p: ^P) -> Token {
	return p.toks[min(p.i, len(p.toks) - 1)]
}

next :: proc(p: ^P) -> Token {
	t := peek(p)
	if p.i < len(p.toks) - 1 {
		p.i += 1
	}
	return t
}

fail :: proc(p: ^P, t: Token, msg: string) -> f64 {
	if !p.fail {
		p.fail = true
		p.err = Err{msg, t.pos, max(1, t.len)}
	}
	return 0
}

// evaluate parses and evaluates one line. Nothing is written to `vars` unless
// the whole statement succeeded.
evaluate :: proc(src: string, vars: ^map[string]f64, deg: bool) -> Result {
	trimmed := strings.trim_space(src)
	if trimmed == "" {
		return Result{ok = false, err = Err{"Type an expression", 0, 1}}
	}

	p := P {
		src  = src,
		toks = tokenise(src),
		vars = vars,
		deg  = deg,
	}

	// An assignment is `ident = expr` and nothing else; `a == b` is not a
	// thing here, and `2 = 3` has to say so rather than quietly evaluating.
	name := ""
	if len(p.toks) >= 2 && p.toks[0].kind == .Ident && p.toks[1].kind == .Assign {
		if is_reserved(p.toks[0].text) {
			return Result {
				ok = false,
				err = Err {
					tfmt("%s is a constant and cannot be assigned", p.toks[0].text),
					p.toks[0].pos,
					p.toks[0].len,
				},
			}
		}
		name = p.toks[0].text
		p.i = 2
		if peek(&p).kind == .End {
			return Result{ok = false, err = Err{"Nothing on the right of =", peek(&p).pos, 1}}
		}
	} else {
		for t in p.toks {
			if t.kind == .Assign {
				return Result {
					ok = false,
					err = Err{"Only `name = value` can assign", t.pos, t.len},
				}
			}
		}
	}

	v := parse_expr(&p)
	if p.fail {
		return Result{ok = false, err = p.err}
	}
	if t := peek(&p); t.kind != .End {
		return Result {
			ok = false,
			err = Err{tfmt("Unexpected `%s`", t.text), t.pos, max(1, t.len)},
		}
	}
	// The write is the caller's to make: `evaluate` is also run on every
	// keystroke for the live preview, and a preview must not assign.
	return Result{value = v, assign = name, ok = true}
}

is_reserved :: proc(name: string) -> bool {
	return name == "pi" || name == "e" || name == "tau" || name == "ans" || is_function(name)
}

parse_expr :: proc(p: ^P) -> f64 {
	v := parse_term(p)
	for !p.fail {
		switch peek(p).kind {
		case .Plus:
			next(p)
			v += parse_term(p)
		case .Minus:
			next(p)
			v -= parse_term(p)
		case .End, .Num, .Ident, .Star, .Slash, .Percent, .Caret, .Bang, .LParen, .RParen, .Comma, .Assign, .Bad:
			return v
		}
	}
	return v
}

parse_term :: proc(p: ^P) -> f64 {
	v := parse_unary(p)
	for !p.fail {
		t := peek(p)
		switch t.kind {
		case .Star:
			next(p)
			v *= parse_unary(p)
		case .Slash:
			next(p)
			d := parse_unary(p)
			if d == 0 {
				return fail(p, t, "Division by zero")
			}
			v /= d
		case .Percent:
			next(p)
			d := parse_unary(p)
			if d == 0 {
				return fail(p, t, "Modulo by zero")
			}
			v = math.mod(v, d)
		case .End, .Num, .Ident, .Plus, .Minus, .Caret, .Bang, .LParen, .RParen, .Comma, .Assign, .Bad:
			return v
		}
	}
	return v
}

parse_unary :: proc(p: ^P) -> f64 {
	t := peek(p)
	if t.kind == .Minus {
		next(p)
		return -parse_unary(p)
	}
	if t.kind == .Plus {
		next(p)
		return parse_unary(p)
	}
	return parse_power(p)
}

parse_power :: proc(p: ^P) -> f64 {
	base := parse_postfix(p)
	if p.fail {
		return 0
	}
	if t := peek(p); t.kind == .Caret {
		next(p)
		exp := parse_unary(p) // right associative, and -1 is a valid exponent
		if p.fail {
			return 0
		}
		if base < 0 && exp != math.trunc(exp) {
			return fail(p, t, "A negative base needs a whole exponent")
		}
		if base == 0 && exp < 0 {
			return fail(p, t, "Zero to a negative power is infinite")
		}
		return math.pow(base, exp)
	}
	return base
}

parse_postfix :: proc(p: ^P) -> f64 {
	v := parse_primary(p)
	for !p.fail {
		t := peek(p)
		if t.kind != .Bang {
			break
		}
		next(p)
		if v < 0 || v != math.trunc(v) {
			return fail(p, t, "Factorial needs a whole number that is not negative")
		}
		if v > 170 {
			return fail(p, t, "Factorial is too large to represent")
		}
		acc := 1.0
		for k := 2.0; k <= v; k += 1 {
			acc *= k
		}
		v = acc
	}
	return v
}

parse_primary :: proc(p: ^P) -> f64 {
	t := next(p)
	switch t.kind {
	case .Num:
		return t.num
	case .LParen:
		v := parse_expr(p)
		if p.fail {
			return 0
		}
		if c := peek(p); c.kind != .RParen {
			return fail(p, c, c.kind == .End ? "This ( was never closed" : "Expected )")
		}
		next(p)
		return v
	case .Ident:
		if peek(p).kind == .LParen {
			return parse_call(p, t)
		}
		switch t.text {
		case "pi":
			return math.PI
		case "tau":
			return math.TAU
		case "e":
			return math.E
		}
		if v, ok := p.vars[t.text]; ok {
			return v
		}
		if is_function(t.text) {
			return fail(p, t, tfmt("%s is a function - write %s(x)", t.text, t.text))
		}
		return fail(p, t, tfmt("%s is not defined - set it with %s = ...", t.text, t.text))
	case .End:
		return fail(p, t, "The expression stops here, something is missing")
	case .RParen:
		return fail(p, t, "No ( to match this )")
	case .Bad:
		return fail(p, t, tfmt("`%s` means nothing here", t.text))
	case .Plus, .Minus, .Star, .Slash, .Percent, .Caret, .Bang, .Comma, .Assign:
		return fail(p, t, tfmt("`%s` needs a number before it", t.text))
	}
	return fail(p, t, "Expected a number")
}

FUNCTIONS := [?]string {
	"abs",
	"acos",
	"asin",
	"atan",
	"cbrt",
	"ceil",
	"cos",
	"exp",
	"floor",
	"hypot",
	"ln",
	"log",
	"log2",
	"max",
	"min",
	"round",
	"sign",
	"sin",
	"sqrt",
	"tan",
	"trunc",
}

is_function :: proc(name: string) -> bool {
	for f in FUNCTIONS {
		if f == name {
			return true
		}
	}
	return false
}

// arity is (min, max); -1 for "any number more than min".
fn_arity :: proc(name: string) -> (lo, hi: int) {
	switch name {
	case "min", "max":
		return 2, -1
	case "hypot":
		return 2, 2
	}
	return 1, 1
}

parse_call :: proc(p: ^P, name: Token) -> f64 {
	open := next(p) // the '('
	args := make([dynamic]f64, 0, 4, context.temp_allocator)
	if peek(p).kind != .RParen {
		for {
			v := parse_expr(p)
			if p.fail {
				return 0
			}
			append(&args, v)
			if peek(p).kind != .Comma {
				break
			}
			next(p)
		}
	}
	if c := peek(p); c.kind != .RParen {
		return fail(p, c.kind == .End ? open : c, "This ( was never closed")
	}
	next(p)

	if !is_function(name.text) {
		return fail(p, name, tfmt("There is no function called %s", name.text))
	}
	lo, hi := fn_arity(name.text)
	if len(args) < lo || (hi >= 0 && len(args) > hi) {
		want := hi < 0 ? tfmt("%d or more", lo) : (lo == hi ? tfmt("%d", lo) : tfmt("%d to %d", lo, hi))
		return fail(
			p,
			name,
			tfmt("%s takes %s argument%s, not %d", name.text, want, lo == 1 && hi == 1 ? "" : "s", len(args)),
		)
	}

	a := args[0]
	// Trigonometry reads its argument in whichever unit the mode says.
	ang := p.deg ? a * math.PI / 180 : a
	switch name.text {
	case "sqrt":
		if a < 0 {
			return fail(p, name, "sqrt of a negative number is not a real number")
		}
		return math.sqrt(a)
	case "cbrt":
		return math.pow(abs(a), 1.0 / 3.0) * (a < 0 ? -1 : 1)
	case "sin":
		return math.sin(ang)
	case "cos":
		return math.cos(ang)
	case "tan":
		return math.tan(ang)
	case "asin", "acos":
		if a < -1 || a > 1 {
			return fail(p, name, tfmt("%s only accepts -1 to 1", name.text))
		}
		r := name.text == "asin" ? math.asin(a) : math.acos(a)
		return p.deg ? r * 180 / math.PI : r
	case "atan":
		r := math.atan(a)
		return p.deg ? r * 180 / math.PI : r
	case "ln":
		if a <= 0 {
			return fail(p, name, "ln needs a number above zero")
		}
		return math.ln(a)
	case "log":
		if a <= 0 {
			return fail(p, name, "log needs a number above zero")
		}
		return math.log10(a)
	case "log2":
		if a <= 0 {
			return fail(p, name, "log2 needs a number above zero")
		}
		return math.log2(a)
	case "exp":
		return math.exp(a)
	case "abs":
		return abs(a)
	case "floor":
		return math.floor(a)
	case "ceil":
		return math.ceil(a)
	case "round":
		return math.round(a)
	case "trunc":
		return math.trunc(a)
	case "sign":
		return a > 0 ? 1 : (a < 0 ? -1 : 0)
	case "hypot":
		return math.sqrt(a * a + args[1] * args[1])
	case "min":
		v := a
		for x in args[1:] {
			v = min(v, x)
		}
		return v
	case "max":
		v := a
		for x in args[1:] {
			v = max(v, x)
		}
		return v
	}
	return fail(p, name, "Unknown function")
}

// ---------------------------------------------------------------------------
// Formatting
// ---------------------------------------------------------------------------

// fmt_num prints a result the way a person would write it: whole numbers
// grouped with thin separators, fractions to a sensible number of places, and
// scientific notation only when the alternative is unreadable.
fmt_num :: proc(v: f64, allocator := context.temp_allocator) -> string {
	if v != v {
		return strings.clone("not a number", allocator)
	}
	if v == math.inf_f64(1) {
		return strings.clone("infinity", allocator)
	}
	if v == math.inf_f64(-1) {
		return strings.clone("-infinity", allocator)
	}
	a := abs(v)
	if a != 0 && (a >= 1e15 || a < 1e-9) {
		return strings.clone(tfmt("%.9g", v), allocator)
	}
	if v == math.trunc(v) {
		return group(tfmt("%d", i64(v)), allocator)
	}
	s := tfmt("%.10f", v)
	s = strings.trim_right(s, "0")
	s = strings.trim_right(s, ".")
	dot := strings.index_byte(s, '.')
	if dot < 0 {
		return group(s, allocator)
	}
	return strings.concatenate({group(s[:dot], context.temp_allocator), s[dot:]}, allocator)
}

// group inserts a separator every three digits: 1234567 -> 1 234 567.
// A space rather than a comma, because a comma already means "next argument"
// here. The tokeniser does not accept spaces inside a number, so reusing a
// result from the history strips them again before it lands in the input.
group :: proc(s: string, allocator := context.temp_allocator) -> string {
	neg := len(s) > 0 && s[0] == '-'
	digits := neg ? s[1:] : s
	if len(digits) <= 4 {
		return strings.clone(s, allocator)
	}
	sb := strings.builder_make(allocator)
	if neg {
		strings.write_byte(&sb, '-')
	}
	lead := len(digits) % 3
	if lead == 0 {
		lead = 3
	}
	strings.write_string(&sb, digits[:lead])
	for i := lead; i < len(digits); i += 3 {
		strings.write_byte(&sb, ' ')
		strings.write_string(&sb, digits[i:i + 3])
	}
	return strings.to_string(sb)
}
