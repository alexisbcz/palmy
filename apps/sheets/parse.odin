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
	kind:  Tok_Kind,
	text:  string, // a slice of the source, or an unescaped string literal
	num:   f64,
	op:    Op_Kind,
	ref:   Ref,
	sheet: string, // the `Sheet2` of `Sheet2!A1`; "" when unqualified
	// The far end of a 3-D reference: the `Sheet3` of `Sheet1:Sheet3!A1`.
	// "" for an ordinary one.
	sheet2: string,
	err:   Err,
	b:     bool,
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
	case '\'':
		// `'My Sheet'!A1`. A quoted name only ever introduces a reference,
		// so this is the one place an apostrophe can start a token.
		return lex_quoted_sheet(lx)
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

	// `Sheet2!A1` — the `!` binds the name to the reference after it. No
	// whitespace is allowed around it, which is what keeps `A1 ! B1` from
	// being read as a sheet reference.
	if lx.i < len(s) && s[lx.i] == '!' {
		lx.i += 1
		return lex_sheet_body(lx, word)
	}

	// `Sheet1:Sheet3!A1` — a 3-D reference. It is only one when the second
	// name runs straight into a `!`, and only when both names would be
	// written bare; a name that needs quotes (`Q1`, which is a cell) has to
	// come in the quoted form `'Q1:Q4'!A1`, exactly as in Excel. Without
	// that rule `A1:B2!C3` would silently stop being a range.
	if lx.i < len(s) && s[lx.i] == ':' {
		k := lx.i + 1
		for k < len(s) && (is_alpha(s[k]) || is_digit(s[k]) || s[k] == '_' || s[k] == '.' || s[k] >= 0x80) {
			k += 1
		}
		word2 := s[lx.i + 1:k]
		if k < len(s) && s[k] == '!' && word2 != "" && !sheet_needs_quote(word) && !sheet_needs_quote(word2) {
			lx.i = k + 1
			return lex_sheet_body(lx, word, word2)
		}
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

// lex_quoted_sheet reads `'name'!` and then the reference that must follow
// it. An inner apostrophe is written doubled, as in every spreadsheet.
lex_quoted_sheet :: proc(lx: ^Lexer) -> (Token, bool) {
	s := lx.src
	lx.i += 1 // opening quote
	b := strings.builder_make(context.temp_allocator)
	closed := false
	for lx.i < len(s) {
		if s[lx.i] == '\'' {
			if lx.i + 1 < len(s) && s[lx.i + 1] == '\'' {
				strings.write_byte(&b, '\'')
				lx.i += 2
				continue
			}
			lx.i += 1
			closed = true
			break
		}
		strings.write_byte(&b, s[lx.i])
		lx.i += 1
	}
	if !closed || lx.i >= len(s) || s[lx.i] != '!' {
		return {kind = .Bad}, false
	}
	lx.i += 1
	name := strings.to_string(b)
	if name == "" {
		return {kind = .Bad}, false
	}
	// `'Jan 2026:Mar 2026'!A1` is how a 3-D span is quoted: one pair of
	// quotes around the whole span. A sheet name may not contain a colon
	// (Excel's rule, and `book_rename_sheet` enforces it), so the first one
	// is the separator.
	if c := strings.index_byte(name, ':'); c >= 0 {
		a, z := name[:c], name[c + 1:]
		if a == "" || z == "" {
			return {kind = .Bad}, false
		}
		return lex_sheet_body(lx, a, z)
	}
	return lex_sheet_body(lx, name)
}

// lex_sheet_body reads the reference half of a sheet-qualified reference. It
// is deliberately strict: after a `!` nothing but a reference is legal, so a
// typo is a syntax error rather than a silently different formula.
lex_sheet_body :: proc(lx: ^Lexer, sheet: string, sheet2 := "") -> (Token, bool) {
	// `Sheet2:Sheet2!A1` spans one sheet, so it is an ordinary reference.
	far := sheet2
	if strings.equal_fold(sheet, far) {
		far = ""
	}
	s := lx.src
	start := lx.i
	for lx.i < len(s) {
		c := s[lx.i]
		if is_alpha(c) || is_digit(c) || c == '$' {
			lx.i += 1
		} else {
			break
		}
	}
	if lx.i == start {
		return {kind = .Bad}, false
	}
	word := s[start:lx.i]
	r, ok := ref_parse(word)
	if !ok {
		return {kind = .Bad}, false
	}
	return {kind = .Ref, ref = r, text = word, sheet = sheet, sheet2 = far}, true
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
	kind:  Ast_Kind,
	num:   f64,
	str:   string, // owned: a string literal, a call name, or a bare name
	err:   Err,
	b:     bool,
	ref:   Ref,
	ref2:  Ref, // the second endpoint of a Range
	sheet: string, // owned: the sheet a Ref or Range names; "" means this one
	// owned: the far end of a 3-D reference, `Sheet3` in `Sheet1:Sheet3!A1`.
	// The span is resolved by *position* every time it is read, so a sheet
	// moved between the two ends joins it and one moved out leaves it.
	sheet2: string,
	op:    Op_Kind,
	kids:  [dynamic]^Ast,
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
	if n.sheet != "" {
		delete(n.sheet)
	}
	if n.sheet2 != "" {
		delete(n.sheet2)
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

// ref_span classifies a range endpoint: 0 a cell, 1 a whole column (`A`),
// 2 a whole row (`1`). The two ends of a range must agree.
ref_span :: proc(r: Ref) -> int {
	if r.row == NO_ROW {
		return 1
	}
	if r.col == NO_COL {
		return 2
	}
	return 0
}

// row_ref_of turns a number token into a whole-row endpoint, when it really
// is a plain positive integer row number.
row_ref_of :: proc(t: Token) -> (Ref, bool) {
	if t.kind != .Number {
		return {}, false
	}
	for i in 0 ..< len(t.text) {
		if !is_digit(t.text[i]) {
			return {}, false // 1.5, 1e3: not a row
		}
	}
	return row_only(t.text)
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
		// `1:1` is a whole-row range, and `1` on its own is the number one.
		// The colon is the only thing that tells them apart, so the decision
		// is made here rather than in the lexer, where there is no lookahead
		// that could make it.
		if ps.i + 2 < len(ps.toks) && ps.toks[ps.i + 1].kind == .Colon {
			a, ok1 := row_ref_of(t)
			b, ok2 := row_ref_of(ps.toks[ps.i + 2])
			if ok1 && ok2 {
				ps.i += 3
				n := ast_new(.Range)
				n.ref = a
				n.ref2 = b
				return n
			}
		}
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
			// `1:1` ends on a plain number, which the lexer has no reason to
			// treat as anything else.
			if t2.kind == .Number {
				if r, good := row_ref_of(t2); good {
					t2 = Token{kind = .Ref, ref = r, text = t2.text}
				}
			}
			if t2.kind != .Ref {
				ps.fail = true
				return nil
			}
			advance(ps)
			// `A1:B2`, `A:A` and `1:1` are all ranges; a mix of two kinds is
			// not.
			if ref_span(t.ref) != ref_span(t2.ref) {
				ps.fail = true
				return nil
			}
			n := ast_new(.Range)
			n.ref = t.ref
			n.ref2 = t2.ref
			n.sheet = strings.clone(t.sheet != "" ? t.sheet : t2.sheet)
			n.sheet2 = strings.clone(t.sheet != "" ? t.sheet2 : t2.sheet2)
			return n
		}
		if t.ref.row == NO_ROW || t.ref.col == NO_COL {
			ps.fail = true
			return nil
		}
		n := ast_new(.Ref)
		n.ref = t.ref
		n.sheet = strings.clone(t.sheet)
		n.sheet2 = strings.clone(t.sheet2)
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
		strings.write_string(b, sheet_span_prefix(n.sheet, n.sheet2))
		strings.write_string(b, ref_text(n.ref))
	case .Range:
		strings.write_string(b, sheet_span_prefix(n.sheet, n.sheet2))
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

// ast_structural fixes up a formula after rows or columns were inserted or
// deleted on one sheet.
//
// `own` is the sheet the formula lives on and `target` the sheet that was
// edited. Only references that resolve to `target` move — which is the whole
// point: inserting a row on Sheet1 must shift `Sheet1!A5` written on Sheet2,
// and must leave `A5` written on Sheet2 exactly where it is.
ast_structural :: proc(
	n: ^Ast,
	insert: bool,
	axis_row: bool,
	at, count: int,
	bk: ^Book = nil,
	own: int = 0,
	target: int = 0,
) {
	if n == nil {
		return
	}
	switch n.kind {
	case .Ref, .Range:
		// A 3-D reference spans at least two sheets, and a row inserted on
		// one of them cannot move the same cells on the others — so it is
		// not shifted at all. LibreOffice does the same (it adjusts a 3-D
		// reference only when the edit covers every sheet in the span, which
		// a one-sheet insert never does), and so does Excel unless the
		// sheets are grouped, which this program has no notion of.
		if n.sheet2 != "" {
			break
		}
		if resolve_sheet(bk, n.sheet, own) != target {
			break
		}
		if n.kind == .Ref {
			n.ref =
				insert \
				? ref_insert(n.ref, axis_row, at, count) \
				: ref_delete(n.ref, axis_row, at, count)
			break
		}
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
		ast_structural(k, insert, axis_row, at, count, bk, own, target)
	}
}

// ast_rename_sheet rewrites the sheet part of every reference that named
// `from`, and reports whether anything changed.
ast_rename_sheet :: proc(n: ^Ast, from, to: string) -> bool {
	if n == nil {
		return false
	}
	hit := false
	if (n.kind == .Ref || n.kind == .Range) && n.sheet != "" && strings.equal_fold(n.sheet, from) {
		delete(n.sheet)
		n.sheet = strings.clone(to)
		hit = true
	}
	if (n.kind == .Ref || n.kind == .Range) && n.sheet2 != "" && strings.equal_fold(n.sheet2, from) {
		delete(n.sheet2)
		n.sheet2 = strings.clone(to)
		hit = true
	}
	for k in n.kids {
		if ast_rename_sheet(k, from, to) {
			hit = true
		}
	}
	return hit
}

// ast_sheets collects every sheet name a formula mentions, so the importer
// and the tests can see what a tree reaches without evaluating it.
ast_sheets :: proc(n: ^Ast, out: ^[dynamic]string) {
	if n == nil {
		return
	}
	if (n.kind == .Ref || n.kind == .Range) {
		for want in ([2]string{n.sheet, n.sheet2}) {
			if want == "" {
				continue
			}
			found := false
			for s in out {
				if strings.equal_fold(s, want) {
					found = true
					break
				}
			}
			if !found {
				append(out, want)
			}
		}
	}
	for k in n.kids {
		ast_sheets(k, out)
	}
}

// ast_deps collects the rectangles a formula reads, which is what the
// dependency graph is built from. Each one carries the sheet it lives on,
// resolved here — so a rename or a reorder takes effect on the next rebuild
// without touching a single tree.
ast_deps :: proc(n: ^Ast, out: ^[dynamic]Dep, max_row: int, bk: ^Book = nil, own: int = 0) {
	if n == nil {
		return
	}
	switch n.kind {
	case .Ref:
		if !n.ref.bad {
			lo, hi := dep_sheets(bk, n, own)
			for si in lo ..= hi {
				append(out, Dep{si, {n.ref.row, n.ref.col, n.ref.row, n.ref.col}})
			}
		}
	case .Range:
		if !n.ref.bad && !n.ref2.bad {
			rect: Rect_I
			switch ref_span(n.ref) {
			case 1: // A:A — every row of those columns
				rect = {0, min(n.ref.col, n.ref2.col), max_row, max(n.ref.col, n.ref2.col)}
			case 2: // 1:1 — every column of those rows
				rect = {min(n.ref.row, n.ref2.row), 0, max(n.ref.row, n.ref2.row), MAX_COLS - 1}
			case:
				rect = {
					min(n.ref.row, n.ref2.row),
					min(n.ref.col, n.ref2.col),
					max(n.ref.row, n.ref2.row),
					max(n.ref.col, n.ref2.col),
				}
			}
			lo, hi := dep_sheets(bk, n, own)
			for si in lo ..= hi {
				append(out, Dep{si, rect})
			}
		}
	case .Name:
		// A named range is a dependency on whatever it names.
		if nd, ok := book_get_name(bk, n.str); ok {
			si := resolve_sheet(bk, nd.sheet, 0)
			append(out, Dep{si, nd.rect})
		}
	case .Num, .Str, .Bool, .Err, .Unary, .Binary, .Percent, .Call:
	}
	for k in n.kids {
		ast_deps(k, out, max_row, bk, own)
	}
}

// dep_sheets is the run of sheet indices a reference reads: one for an
// ordinary reference, every sheet between the two ends (by position, now)
// for a 3-D one, and the single unresolvable index -1 when a name does not
// resolve, which the graph skips and the evaluator reports as #REF!.
dep_sheets :: proc(bk: ^Book, n: ^Ast, own: int) -> (lo, hi: int) {
	a := resolve_sheet(bk, n.sheet, own)
	if n.sheet2 == "" {
		return a, a
	}
	b := book_find(bk, n.sheet2)
	if a < 0 || b < 0 {
		return -1, -1
	}
	return min(a, b), max(a, b)
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
