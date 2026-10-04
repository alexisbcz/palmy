// The formula language: a tokeniser, a recursive-descent parser producing an
// AST, and a printer that turns an AST back into source. The printer is not a
// convenience — copy/paste and insert/delete both work by transforming the
// tree and writing it back out, so the round trip has to be exact.
package main

import "core:strconv"
import "core:strings"

// ---------------------------------------------------------------------------
// Tokens
// ---------------------------------------------------------------------------

Tok_Kind :: enum u8 {
	End,
	Number,
	Str,
	Ident, // a name followed by `(`, or a bare name
	Ref,
	Bool,
	Err_Lit,
	Op,
	LParen,
	RParen,
	Comma,
	Colon,
	Percent,
	Bad,
}

Op_Kind :: enum u8 {
	None,
	Add,
	Sub,
	Mul,
	Div,
	Pow,
	Concat,
	Eq,
	Ne,
	Lt,
	Le,
	Gt,
	Ge,
	Neg,
	Pos,
}

op_text :: proc(o: Op_Kind) -> string {
	switch o {
	case .None:
		return ""
	case .Add:
		return "+"
	case .Sub:
		return "-"
	case .Mul:
		return "*"
	case .Div:
		return "/"
	case .Pow:
		return "^"
	case .Concat:
		return "&"
	case .Eq:
		return "="
	case .Ne:
		return "<>"
	case .Lt:
		return "<"
	case .Le:
		return "<="
	case .Gt:
		return ">"
	case .Ge:
		return ">="
	case .Neg:
		return "-"
	case .Pos:
		return "+"
	}
	return ""
}

Token :: struct {
	kind: Tok_Kind,
	text: string, // a slice of the source, or an unescaped string literal
	num:  f64,
	op:   Op_Kind,
	ref:  Ref,
	err:  Err,
	b:    bool,
}

Lexer :: struct {
	src: string,
	i:   int,
}

// lex_all tokenises the whole formula up front. Formulas are short, and a flat
// token array makes the parser's lookahead trivial.
lex_all :: proc(src: string, allocator := context.allocator) -> (toks: [dynamic]Token, ok: bool) {
	toks = make([dynamic]Token, allocator)
	lx := Lexer{src = src}
	for {
		t, good := lex_next(&lx)
		if !good {
			return toks, false
		}
		append(&toks, t)
		if t.kind == .End {
			return toks, true
		}
	}
}

lex_next :: proc(lx: ^Lexer) -> (t: Token, ok: bool) {
	s := lx.src
	for lx.i < len(s) && (s[lx.i] == ' ' || s[lx.i] == '\t' || s[lx.i] == '\n' || s[lx.i] == '\r') {
		lx.i += 1
	}
	if lx.i >= len(s) {
		return {kind = .End}, true
	}
	c := s[lx.i]

	switch c {
	case '(':
		lx.i += 1
		return {kind = .LParen}, true
	case ')':
		lx.i += 1
		return {kind = .RParen}, true
	case ',', ';':
		lx.i += 1
		return {kind = .Comma}, true
	case ':':
		lx.i += 1
		return {kind = .Colon}, true
	case '%':
		lx.i += 1
		return {kind = .Percent}, true
	case '+':
		lx.i += 1
		return {kind = .Op, op = .Add}, true
	case '-':
		lx.i += 1
		return {kind = .Op, op = .Sub}, true
	case '*':
		lx.i += 1
		return {kind = .Op, op = .Mul}, true
	case '/':
		lx.i += 1
		return {kind = .Op, op = .Div}, true
	case '^':
		lx.i += 1
		return {kind = .Op, op = .Pow}, true
	case '&':
		lx.i += 1
		return {kind = .Op, op = .Concat}, true
	case '=':
		lx.i += 1
		return {kind = .Op, op = .Eq}, true
	case '<':
		lx.i += 1
		if lx.i < len(s) && s[lx.i] == '>' {
			lx.i += 1
			return {kind = .Op, op = .Ne}, true
		}
		if lx.i < len(s) && s[lx.i] == '=' {
			lx.i += 1
			return {kind = .Op, op = .Le}, true
		}
		return {kind = .Op, op = .Lt}, true
	case '>':
		lx.i += 1
		if lx.i < len(s) && s[lx.i] == '=' {
			lx.i += 1
			return {kind = .Op, op = .Ge}, true
		}
		return {kind = .Op, op = .Gt}, true
	case '"':
		return lex_string(lx)
	case '#':
		return lex_error_literal(lx)
	}

	if is_digit(c) || (c == '.' && lx.i + 1 < len(s) && is_digit(s[lx.i + 1])) {
		return lex_number(lx)
	}
	if is_alpha(c) || c == '$' || c == '_' {
		return lex_word(lx)
	}
	return {kind = .Bad}, false
}

lex_string :: proc(lx: ^Lexer) -> (Token, bool) {
	s := lx.src
	lx.i += 1 // opening quote
	b := strings.builder_make(context.temp_allocator)
	for lx.i < len(s) {
		if s[lx.i] == '"' {
			// A doubled quote is a literal quote, as in every spreadsheet.
			if lx.i + 1 < len(s) && s[lx.i + 1] == '"' {
				strings.write_byte(&b, '"')
				lx.i += 2
				continue
			}
			lx.i += 1
			return {kind = .Str, text = strings.to_string(b)}, true
		}
		strings.write_byte(&b, s[lx.i])
		lx.i += 1
	}
	return {kind = .Bad}, false // unterminated
}

lex_error_literal :: proc(lx: ^Lexer) -> (Token, bool) {
	s := lx.src
	start := lx.i
	lx.i += 1
	for lx.i < len(s) && (is_alpha(s[lx.i]) || is_digit(s[lx.i]) || s[lx.i] == '/' || s[lx.i] == '!' || s[lx.i] == '?') {
		lx.i += 1
		if s[lx.i - 1] == '!' || s[lx.i - 1] == '?' {
			break
		}
	}
	if e, ok := err_parse(s[start:lx.i]); ok {
		return {kind = .Err_Lit, err = e, text = s[start:lx.i]}, true
	}
	return {kind = .Bad}, false
}

lex_number :: proc(lx: ^Lexer) -> (Token, bool) {
	s := lx.src
	start := lx.i
	for lx.i < len(s) && is_digit(s[lx.i]) {
		lx.i += 1
	}
	if lx.i < len(s) && s[lx.i] == '.' {
		lx.i += 1
		for lx.i < len(s) && is_digit(s[lx.i]) {
			lx.i += 1
		}
	}
	// An exponent only counts when a sign or digit actually follows, so that
	// `1E` is a syntax error rather than a silent 1.
	if lx.i < len(s) && (s[lx.i] == 'e' || s[lx.i] == 'E') {
		save := lx.i
		lx.i += 1
		if lx.i < len(s) && (s[lx.i] == '+' || s[lx.i] == '-') {
			lx.i += 1
		}
		if lx.i < len(s) && is_digit(s[lx.i]) {
			for lx.i < len(s) && is_digit(s[lx.i]) {
				lx.i += 1
			}
		} else {
			lx.i = save
		}
	}
	x, ok := strconv.parse_f64(s[start:lx.i])
	if !ok {
		return {kind = .Bad}, false
	}
	return {kind = .Number, num = x, text = s[start:lx.i]}, true
}

// lex_word covers the three things that look alike: a function name, a cell
// reference, and a bare name. The disambiguation rule is the one a
// spreadsheet uses — a `(` immediately after makes it a call, so `LOG10(` is
// a function and `LOG10` on its own would be a reference if the column
// existed.
lex_word :: proc(lx: ^Lexer) -> (Token, bool) {
	s := lx.src
	start := lx.i
	for lx.i < len(s) {
		c := s[lx.i]
		if is_alpha(c) || is_digit(c) || c == '$' || c == '_' || c == '.' {
			lx.i += 1
		} else {
			break
		}
	}
	word := s[start:lx.i]

	j := lx.i
	for j < len(s) && (s[j] == ' ' || s[j] == '\t') {
		j += 1
	}
	if j < len(s) && s[j] == '(' {
		lx.i = j
		return {kind = .Ident, text = word}, true
	}

	if r, ok := ref_parse(word); ok {
		// `A` on its own is only a reference as part of `A:A`; otherwise it
		// is a name, which evaluates to #NAME?.
		if r.row == NO_ROW && !(j < len(s) && s[j] == ':') {
			return {kind = .Ident, text = word}, true
		}
		return {kind = .Ref, ref = r, text = word}, true
	}
	if strings.equal_fold(word, "TRUE") {
		return {kind = .Bool, b = true, text = word}, true
	}
	if strings.equal_fold(word, "FALSE") {
		return {kind = .Bool, b = false, text = word}, true
	}
	return {kind = .Ident, text = word}, true
}

// ---------------------------------------------------------------------------
// AST
// ---------------------------------------------------------------------------

Ast_Kind :: enum u8 {
	Num,
	Str,
	Bool,
	Err,
	Ref,
	Range,
	Unary,
	Binary,
	Percent,
	Call,
	Name, // an unknown bare name: #NAME?
}

Ast :: struct {
	kind: Ast_Kind,
	num:  f64,
	str:  string, // owned: a string literal, a call name, or a bare name
	err:  Err,
	b:    bool,
	ref:  Ref,
	ref2: Ref, // the second endpoint of a Range
	op:   Op_Kind,
	kids: [dynamic]^Ast,
}

ast_new :: proc(k: Ast_Kind) -> ^Ast {
	n := new(Ast)
	n.kind = k
	return n
}

ast_free :: proc(n: ^Ast) {
	if n == nil {
		return
	}
	for k in n.kids {
		ast_free(k)
	}
	delete(n.kids)
	if n.str != "" {
		delete(n.str)
	}
	free(n)
}

// ---------------------------------------------------------------------------
// Parser
//
// Precedence, lowest binding first:
//
//   = <> < <= > >=      comparison
//   &                   concatenation
//   + -                 additive
//   * /                 multiplicative
//   ^                   power, left associative (as in Excel: 2^3^2 = 64)
//   %                   postfix percent
//   - +                 unary, binding tighter than ^ (so -2^2 = 4)
//
// All binary operators are left associative.
// ---------------------------------------------------------------------------

Parser :: struct {
	toks: []Token,
	i:    int,
	fail: bool,
}

parse_formula :: proc(src: string) -> (root: ^Ast, ok: bool) {
	toks, lexed := lex_all(src, context.temp_allocator)
	if !lexed {
		return nil, false
	}
	ps := Parser {
		toks = toks[:],
	}
	n := p_compare(&ps)
	if ps.fail || n == nil || cur(&ps).kind != .End {
		ast_free(n)
		return nil, false
	}
	return n, true
}

cur :: proc(ps: ^Parser) -> Token {
	if ps.i < len(ps.toks) {
		return ps.toks[ps.i]
	}
	return {kind = .End}
}

advance :: proc(ps: ^Parser) {
	if ps.i < len(ps.toks) {
		ps.i += 1
	}
}

bin :: proc(op: Op_Kind, l, r: ^Ast) -> ^Ast {
	n := ast_new(.Binary)
	n.op = op
	n.kids = make([dynamic]^Ast, 0, 2)
	append(&n.kids, l)
	append(&n.kids, r)
	return n
}

p_compare :: proc(ps: ^Parser) -> ^Ast {
	l := p_concat(ps)
	for !ps.fail {
		t := cur(ps)
		if t.kind != .Op {
			break
		}
		if t.op != .Eq && t.op != .Ne && t.op != .Lt && t.op != .Le && t.op != .Gt && t.op != .Ge {
			break
		}
		advance(ps)
		r := p_concat(ps)
		l = bin(t.op, l, r)
	}
	return l
}

p_concat :: proc(ps: ^Parser) -> ^Ast {
	l := p_additive(ps)
	for !ps.fail {
		t := cur(ps)
		if t.kind != .Op || t.op != .Concat {
			break
		}
		advance(ps)
		r := p_additive(ps)
		l = bin(.Concat, l, r)
	}
	return l
}

p_additive :: proc(ps: ^Parser) -> ^Ast {
	l := p_multiplicative(ps)
	for !ps.fail {
		t := cur(ps)
		if t.kind != .Op || (t.op != .Add && t.op != .Sub) {
			break
		}
		advance(ps)
		r := p_multiplicative(ps)
		l = bin(t.op, l, r)
	}
	return l
}

p_multiplicative :: proc(ps: ^Parser) -> ^Ast {
	l := p_power(ps)
	for !ps.fail {
		t := cur(ps)
		if t.kind != .Op || (t.op != .Mul && t.op != .Div) {
			break
		}
		advance(ps)
		r := p_power(ps)
		l = bin(t.op, l, r)
	}
	return l
}

p_power :: proc(ps: ^Parser) -> ^Ast {
	l := p_unary(ps)
	for !ps.fail {
		t := cur(ps)
		if t.kind != .Op || t.op != .Pow {
			break
		}
		advance(ps)
		r := p_unary(ps)
		l = bin(.Pow, l, r)
	}
	return l
}

p_unary :: proc(ps: ^Parser) -> ^Ast {
	t := cur(ps)
	if t.kind == .Op && (t.op == .Sub || t.op == .Add) {
		advance(ps)
		k := p_unary(ps)
		if t.op == .Add {
			return k // a unary plus is a no-op, so do not keep a node for it
		}
		n := ast_new(.Unary)
		n.op = .Neg
		n.kids = make([dynamic]^Ast, 0, 1)
		append(&n.kids, k)
		return n
	}
	return p_postfix(ps)
}

p_postfix :: proc(ps: ^Parser) -> ^Ast {
	l := p_primary(ps)
	for !ps.fail && cur(ps).kind == .Percent {
		advance(ps)
		n := ast_new(.Percent)
		n.kids = make([dynamic]^Ast, 0, 1)
		append(&n.kids, l)
		l = n
	}
	return l
}

p_primary :: proc(ps: ^Parser) -> ^Ast {
	t := cur(ps)
	switch t.kind {
	case .Number:
		advance(ps)
		n := ast_new(.Num)
		n.num = t.num
		return n

	case .Str:
		advance(ps)
		n := ast_new(.Str)
		n.str = strings.clone(t.text)
		return n

	case .Bool:
		advance(ps)
		n := ast_new(.Bool)
		n.b = t.b
		return n

	case .Err_Lit:
		advance(ps)
		n := ast_new(.Err)
		n.err = t.err
		return n

	case .Ref:
		advance(ps)
		if cur(ps).kind == .Colon {
			advance(ps)
			t2 := cur(ps)
			// `A:A` ends on a bare column name, which the lexer can only tell
			// apart from a defined name by what follows it — and nothing
			// does. So accept an identifier here when it reads as a column.
			if t2.kind == .Ident {
				if r, good := ref_parse(t2.text); good && r.row == NO_ROW {
					t2 = Token{kind = .Ref, ref = r, text = t2.text}
				}
			}
			if t2.kind != .Ref {
				ps.fail = true
				return nil
			}
			advance(ps)
			// `A1:B2` and `A:A` are both ranges; a mix of the two is not.
			if (t.ref.row == NO_ROW) != (t2.ref.row == NO_ROW) {
				ps.fail = true
				return nil
			}
			n := ast_new(.Range)
			n.ref = t.ref
			n.ref2 = t2.ref
			return n
		}
		if t.ref.row == NO_ROW {
			ps.fail = true
			return nil
		}
		n := ast_new(.Ref)
		n.ref = t.ref
		return n

	case .LParen:
		advance(ps)
		inner := p_compare(ps)
		if ps.fail || cur(ps).kind != .RParen {
			ps.fail = true
			ast_free(inner)
			return nil
		}
		advance(ps)
		return inner

	case .Ident:
		advance(ps)
		if cur(ps).kind != .LParen {
			n := ast_new(.Name)
			n.str = strings.clone(t.text)
			return n
		}
		advance(ps) // (
		n := ast_new(.Call)
		n.str = strings.to_upper(t.text)
		n.kids = make([dynamic]^Ast, 0, 4)
		if cur(ps).kind == .RParen {
			advance(ps)
			return n
		}
		for {
			a := p_compare(ps)
			if ps.fail {
				ast_free(n)
				ast_free(a)
				return nil
			}
			append(&n.kids, a)
			if cur(ps).kind == .Comma {
				advance(ps)
				continue
			}
			break
		}
		if cur(ps).kind != .RParen {
			ps.fail = true
			ast_free(n)
			return nil
		}
		advance(ps)
		return n

	case .End, .Op, .RParen, .Comma, .Colon, .Percent, .Bad:
		ps.fail = true
		return nil
	}
	ps.fail = true
	return nil
}

// ---------------------------------------------------------------------------
// Printing
//
// The printer parenthesises by precedence rather than remembering the user's
// brackets, so `=(1+2)*3` comes back as `=(1+2)*3` and `=1+(2*3)` comes back
// as `=1+2*3`. Both mean the same thing, which is the contract that matters.
// ---------------------------------------------------------------------------

@(private = "file")
prec_of :: proc(n: ^Ast) -> int {
	switch n.kind {
	case .Binary:
		switch n.op {
		case .Eq, .Ne, .Lt, .Le, .Gt, .Ge:
			return 1
		case .Concat:
			return 2
		case .Add, .Sub:
			return 3
		case .Mul, .Div:
			return 4
		case .Pow:
			return 5
		case .None, .Neg, .Pos:
			return 9
		}
	case .Unary:
		return 7
	case .Percent:
		return 6
	case .Num, .Str, .Bool, .Err, .Ref, .Range, .Call, .Name:
		return 9
	}
	return 9
}

ast_print :: proc(n: ^Ast, b: ^strings.Builder) {
	if n == nil {
		return
	}
	switch n.kind {
	case .Num:
		strings.write_string(b, number_source(n.num))
	case .Str:
		strings.write_byte(b, '"')
		for i in 0 ..< len(n.str) {
			if n.str[i] == '"' {
				strings.write_byte(b, '"')
			}
			strings.write_byte(b, n.str[i])
		}
		strings.write_byte(b, '"')
	case .Bool:
		strings.write_string(b, n.b ? "TRUE" : "FALSE")
	case .Err:
		strings.write_string(b, err_text(n.err))
	case .Name:
		strings.write_string(b, n.str)
	case .Ref:
		strings.write_string(b, ref_text(n.ref))
	case .Range:
		strings.write_string(b, ref_text(n.ref))
		strings.write_byte(b, ':')
		strings.write_string(b, ref_text(n.ref2))
	case .Unary:
		strings.write_string(b, "-")
		write_operand(n.kids[0], 7, b, true)
	case .Percent:
		write_operand(n.kids[0], 6, b, false)
		strings.write_byte(b, '%')
	case .Binary:
		pr := prec_of(n)
		write_operand(n.kids[0], pr, b, false)
		strings.write_string(b, op_text(n.op))
		// The right operand of a left-associative operator needs brackets at
		// equal precedence: a-(b-c) is not a-b-c.
		write_operand(n.kids[1], pr, b, true)
	case .Call:
		strings.write_string(b, n.str)
		strings.write_byte(b, '(')
		for k, i in n.kids {
			if i > 0 {
				strings.write_byte(b, ',')
			}
			ast_print(k, b)
		}
		strings.write_byte(b, ')')
	}
}

@(private = "file")
write_operand :: proc(k: ^Ast, parent_prec: int, b: ^strings.Builder, right: bool) {
	kp := prec_of(k)
	need := right ? kp <= parent_prec : kp < parent_prec
	if need {
		strings.write_byte(b, '(')
		ast_print(k, b)
		strings.write_byte(b, ')')
	} else {
		ast_print(k, b)
	}
}

// ast_source renders a whole formula, leading `=` included.
ast_source :: proc(n: ^Ast, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_byte(&b, '=')
	ast_print(n, &b)
	return strings.to_string(b)
}

// ---------------------------------------------------------------------------
// Tree transforms
// ---------------------------------------------------------------------------

// ast_offset is the copy/paste rule applied to a whole tree.
ast_offset :: proc(n: ^Ast, drow, dcol: int) {
	if n == nil {
		return
	}
	switch n.kind {
	case .Ref:
		n.ref = ref_offset(n.ref, drow, dcol)
	case .Range:
		n.ref = ref_offset(n.ref, drow, dcol)
		n.ref2 = ref_offset(n.ref2, drow, dcol)
	case .Num, .Str, .Bool, .Err, .Name, .Unary, .Binary, .Percent, .Call:
	}
	for k in n.kids {
		ast_offset(k, drow, dcol)
	}
}

ast_structural :: proc(n: ^Ast, insert: bool, axis_row: bool, at, count: int) {
	if n == nil {
		return
	}
	switch n.kind {
	case .Ref:
		n.ref = insert ? ref_insert(n.ref, axis_row, at, count) : ref_delete(n.ref, axis_row, at, count)
	case .Range:
		if insert {
			// Inserting inside a range stretches it; inserting at its start
			// pushes it along. Both fall out of shifting each endpoint.
			n.ref = ref_insert(n.ref, axis_row, at, count)
			n.ref2 = ref_insert(n.ref2, axis_row, at, count)
		} else {
			a, b, _ := range_delete(n.ref, n.ref2, axis_row, at, count)
			n.ref, n.ref2 = a, b
		}
	case .Num, .Str, .Bool, .Err, .Name, .Unary, .Binary, .Percent, .Call:
	}
	for k in n.kids {
		ast_structural(k, insert, axis_row, at, count)
	}
}

// ast_deps collects the rectangles a formula reads, which is what the
// dependency graph is built from.
ast_deps :: proc(n: ^Ast, out: ^[dynamic]Rect_I, max_row: int) {
	if n == nil {
		return
	}
	switch n.kind {
	case .Ref:
		if !n.ref.bad {
			append(out, Rect_I{n.ref.row, n.ref.col, n.ref.row, n.ref.col})
		}
	case .Range:
		if !n.ref.bad && !n.ref2.bad {
			if n.ref.row == NO_ROW {
				append(
					out,
					Rect_I {
						0,
						min(n.ref.col, n.ref2.col),
						max_row,
						max(n.ref.col, n.ref2.col),
					},
				)
			} else {
				append(
					out,
					Rect_I {
						min(n.ref.row, n.ref2.row),
						min(n.ref.col, n.ref2.col),
						max(n.ref.row, n.ref2.row),
						max(n.ref.col, n.ref2.col),
					},
				)
			}
		}
	case .Num, .Str, .Bool, .Err, .Name, .Unary, .Binary, .Percent, .Call:
	}
	for k in n.kids {
		ast_deps(k, out, max_row)
	}
}

// ast_has_volatile reports whether a formula must be recomputed on every full
// pass regardless of its inputs. TODAY and NOW are the two.
ast_has_volatile :: proc(n: ^Ast) -> bool {
	if n == nil {
		return false
	}
	if n.kind == .Call && (n.str == "TODAY" || n.str == "NOW" || n.str == "RAND") {
		return true
	}
	for k in n.kids {
		if ast_has_volatile(k) {
			return true
		}
	}
	return false
}
