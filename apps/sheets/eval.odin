// The evaluator: operators with spreadsheet coercion rules, and the function
// library. Errors are values here, so every operand is checked before it is
// used and the first error found is the result.
package main

import "core:math"
import "core:strings"
import "core:unicode/utf8"

// Res is what evaluating a node yields. A reference is not just a value: SUM
// needs the rectangle, not the number in its corner, so the rectangle travels
// alongside and is collapsed to a scalar only where a scalar is wanted.
Res :: struct {
	v:    Value,
	rng:  bool,
	rect: Rect_I,
	rsh:  ^Sheet, // the sheet `rect` lives on; nil means the formula's own
}

rv :: proc(v: Value) -> Res {
	return {v = v}
}

// res_sheet is where a cross-sheet reference stops being special: every
// consumer of a range asks which sheet it came from instead of assuming the
// formula's own, and `nil` means "mine".
res_sheet :: proc(sh: ^Sheet, r: Res) -> ^Sheet {
	return r.rsh != nil ? r.rsh : sh
}

res_scalar :: proc(sh: ^Sheet, r: Res) -> Value {
	if !r.rng {
		return r.v
	}
	rs := res_sheet(sh, r)
	if r.rect.r0 == r.rect.r1 && r.rect.c0 == r.rect.c1 {
		return ensure_value(rs, {r.rect.r0, r.rect.c0})
	}
	// A multi-cell range used where one value is wanted is an error, the same
	// way =A1:A5+1 is in a spreadsheet.
	return verr(.Value)
}

eval_ast :: proc(sh: ^Sheet, n: ^Ast, at: Addr) -> Res {
	if n == nil {
		return rv(verr(.Value))
	}
	switch n.kind {
	case .Num:
		return rv(vnum(n.num))
	case .Str:
		return rv(vtext(n.str))
	case .Bool:
		return rv(vbool(n.b))
	case .Err:
		return rv(verr(n.err))
	case .Name:
		// A bare name is a named range if one is in scope — this sheet's
		// own first, then the book's — and #NAME? otherwise.
		nd, ok, bad_sheet := name_lookup(sh.book, n, sh.index)
		if bad_sheet {
			return rv(verr(.Ref))
		}
		if ok {
			if nd.bad {
				return rv(verr(.Ref)) // `=#REF!`: what it named was deleted
			}
			if nd.sheet2 != "" {
				// A 3-D name, used where one value or one range is wanted.
				a, b := book_find(sh.book, nd.sheet), book_find(sh.book, nd.sheet2)
				return rv(verr(a < 0 || b < 0 ? .Ref : .Value))
			}
			ts := book_sheet(sh.book, resolve_sheet(sh.book, nd.sheet, 0))
			if ts == nil {
				return rv(verr(.Ref))
			}
			return {rng = true, rect = nd.rect, rsh = ts}
		}
		return rv(verr(.Name))

	case .Ref:
		if n.ref.bad || n.ref.row < 0 || n.ref.col < 0 {
			return rv(verr(.Ref))
		}
		if n.sheet2 != "" {
			return rv(verr(span_misuse(sh, n)))
		}
		ts := ref_sheet(sh, n)
		if ts == nil {
			return rv(verr(.Ref)) // the sheet was renamed away or deleted
		}
		a := Addr{n.ref.row, n.ref.col}
		return {
			v = ensure_value(ts, a),
			rng = true,
			rect = {a.row, a.col, a.row, a.col},
			rsh = ts,
		}

	case .Range:
		if n.sheet2 != "" {
			return rv(verr(span_misuse(sh, n)))
		}
		ts := ref_sheet(sh, n)
		if ts == nil {
			return rv(verr(.Ref))
		}
		rect, ok := range_rect(ts, n)
		if !ok {
			return rv(verr(.Ref))
		}
		return {rng = true, rect = rect, rsh = ts}

	case .Percent:
		v := res_scalar(sh, eval_ast(sh, n.kids[0], at))
		x, e := as_number(v)
		if e != .None {
			return rv(verr(e))
		}
		return rv(vnum(x / 100))

	case .Unary:
		v := res_scalar(sh, eval_ast(sh, n.kids[0], at))
		x, e := as_number(v)
		if e != .None {
			return rv(verr(e))
		}
		return rv(vnum(-x))

	case .Binary:
		return eval_binary(sh, n, at)

	case .Call:
		return eval_call(sh, n, at)
	}
	return rv(verr(.Value))
}

// ---------------------------------------------------------------------------
// 3-D references
//
// `Sheet1:Sheet3!A1` is not one rectangle but one per sheet, so it cannot
// travel as a `Res`. Rather than teach every consumer of a range about a
// third dimension, a 3-D reference is legal in exactly the places Excel
// allows it — the aggregates (SUM, AVERAGE, COUNT, COUNTA, MIN, MAX, PRODUCT,
// STDEV here) — which read it through `span_each` below. Anywhere else it is
// #VALUE!, which is Excel's answer for `=Sheet1:Sheet3!A1` on its own and
// LibreOffice's for a 3-D range used where one value is wanted.
//
// The span is resolved by *position* on every read: the two named sheets are
// looked up, and every sheet between them, in the book's current order, is
// in. So a sheet inserted or moved between the ends joins the sum, one moved
// outside leaves it, and moving an end widens or narrows the span — the
// behaviour both Excel and LibreOffice document. Deleting an end is the one
// case that rewrites the formula; see `book_fix_spans_for_delete`.
// ---------------------------------------------------------------------------

// is_span reports whether a node is a 3-D reference.
is_span :: proc(n: ^Ast) -> bool {
	return n != nil && (n.kind == .Ref || n.kind == .Range) && n.sheet2 != ""
}

// is_span_in is `is_span`, plus a name that resolves, from this sheet, to a
// 3-D range — which reads exactly like the reference it stands for.
is_span_in :: proc(sh: ^Sheet, n: ^Ast) -> bool {
	if is_span(n) {
		return true
	}
	if n == nil || n.kind != .Name {
		return false
	}
	nd, ok, _ := name_lookup(sh.book, n, sh.index)
	return ok && !nd.bad && nd.sheet2 != ""
}

// span_bounds resolves a 3-D reference to its first and last sheet index.
span_bounds :: proc(sh: ^Sheet, n: ^Ast) -> (lo, hi: int, ok: bool) {
	a := book_find(sh.book, n.sheet)
	b := book_find(sh.book, n.sheet2)
	if a < 0 || b < 0 {
		return 0, 0, false
	}
	return min(a, b), max(a, b), true
}

// span_misuse is the error for a 3-D reference where one value is wanted:
// #REF! if an end no longer exists, #VALUE! otherwise.
span_misuse :: proc(sh: ^Sheet, n: ^Ast) -> Err {
	if _, _, ok := span_bounds(sh, n); !ok {
		return .Ref
	}
	return .Value
}

// span_rect is the rectangle a 3-D reference covers on one sheet of its span.
span_rect :: proc(ts: ^Sheet, n: ^Ast) -> (Rect_I, bool) {
	if n.kind == .Ref {
		if n.ref.bad || n.ref.row < 0 || n.ref.col < 0 {
			return {}, false
		}
		return {n.ref.row, n.ref.col, n.ref.row, n.ref.col}, true
	}
	return range_rect(ts, n)
}

// span_values appends every value a 3-D reference reads, sheet by sheet in
// book order and row-major within each, skipping cells that do not exist —
// the same order and the same rule as a range on one sheet.
span_values :: proc(sh: ^Sheet, n: ^Ast, out: ^[dynamic]Value) -> Err {
	if n.kind == .Name {
		nd, ok, _ := name_lookup(sh.book, n, sh.index)
		if !ok || nd.bad {
			return .Ref
		}
		a, b := book_find(sh.book, nd.sheet), book_find(sh.book, nd.sheet2)
		if a < 0 || b < 0 {
			return .Ref
		}
		for si in min(a, b) ..= max(a, b) {
			rect_values(sh.book.sheets[si], nd.rect, out)
		}
		return .None
	}
	lo, hi, ok := span_bounds(sh, n)
	if !ok {
		return .Ref
	}
	for si in lo ..= hi {
		ts := sh.book.sheets[si]
		rect, good := span_rect(ts, n)
		if !good {
			return .Ref
		}
		rect_values(ts, rect, out)
	}
	return .None
}

// rect_values appends the values of the cells that exist in one rectangle of
// one sheet, row-major.
@(private = "file")
rect_values :: proc(ts: ^Sheet, rect: Rect_I, out: ^[dynamic]Value) {
	r, any := clamp_rect(ts, rect)
	if !any {
		return
	}
	for row in r.r0 ..= r.r1 {
		for col in r.c0 ..= r.c1 {
			if cell_at(ts, {row, col}) == nil {
				continue
			}
			append(out, ensure_value(ts, {row, col}))
		}
	}
}

// ref_sheet is the sheet a reference points at: another one when it is
// qualified, the formula's own when it is not, and nil when the name does not
// resolve — which is #REF!.
ref_sheet :: proc(sh: ^Sheet, n: ^Ast) -> ^Sheet {
	if n.sheet == "" {
		return sh
	}
	return book_sheet(sh.book, book_find(sh.book, n.sheet))
}

range_rect :: proc(sh: ^Sheet, n: ^Ast) -> (Rect_I, bool) {
	a, b := n.ref, n.ref2
	if a.bad || b.bad {
		return {}, false
	}
	if a.row == NO_ROW {
		// A whole-column range spans the used rows. An empty sheet gives an
		// empty rectangle, which every aggregate already handles.
		c0, c1 := min(a.col, b.col), max(a.col, b.col)
		return {0, c0, max(sh.max_row, 0), c1}, true
	}
	if a.col == NO_COL {
		// And a whole-row range spans the used columns.
		r0, r1 := min(a.row, b.row), max(a.row, b.row)
		return {r0, 0, r1, max(sh.max_col, 0)}, true
	}
	if a.row < 0 || b.row < 0 || a.col < 0 || b.col < 0 {
		return {}, false
	}
	return {
			min(a.row, b.row),
			min(a.col, b.col),
			max(a.row, b.row),
			max(a.col, b.col),
		},
		true
}

// ---------------------------------------------------------------------------
// Operators
// ---------------------------------------------------------------------------

eval_binary :: proc(sh: ^Sheet, n: ^Ast, at: Addr) -> Res {
	l := res_scalar(sh, eval_ast(sh, n.kids[0], at))
	if is_err(l) {
		return rv(l)
	}
	r := res_scalar(sh, eval_ast(sh, n.kids[1], at))
	if is_err(r) {
		return rv(r)
	}

	switch n.op {
	case .Add, .Sub, .Mul, .Div, .Pow:
		a, e1 := as_number(l)
		if e1 != .None {
			return rv(verr(e1))
		}
		b, e2 := as_number(r)
		if e2 != .None {
			return rv(verr(e2))
		}
		switch n.op {
		case .Add:
			return rv(vnum(a + b))
		case .Sub:
			return rv(vnum(a - b))
		case .Mul:
			return rv(vnum(a * b))
		case .Div:
			if b == 0 {
				return rv(verr(.Div0))
			}
			return rv(vnum(a / b))
		case .Pow:
			if a < 0 && b != math.trunc(b) {
				return rv(verr(.Num))
			}
			if a == 0 && b < 0 {
				return rv(verr(.Div0))
			}
			return rv(vnum(math.pow(a, b)))
		case .None, .Concat, .Eq, .Ne, .Lt, .Le, .Gt, .Ge, .Neg, .Pos:
		}

	case .Concat:
		sa, e1 := as_text(l)
		if e1 != .None {
			return rv(verr(e1))
		}
		sb, e2 := as_text(r)
		if e2 != .None {
			return rv(verr(e2))
		}
		return rv(vtext(strings.concatenate({sa, sb})))

	case .Eq, .Ne, .Lt, .Le, .Gt, .Ge:
		c, e := compare_values(l, r)
		if e != .None {
			return rv(verr(e))
		}
		switch n.op {
		case .Eq:
			return rv(vbool(c == 0))
		case .Ne:
			return rv(vbool(c != 0))
		case .Lt:
			return rv(vbool(c < 0))
		case .Le:
			return rv(vbool(c <= 0))
		case .Gt:
			return rv(vbool(c > 0))
		case .Ge:
			return rv(vbool(c >= 0))
		case .None, .Add, .Sub, .Mul, .Div, .Pow, .Concat, .Neg, .Pos:
		}

	case .None, .Neg, .Pos:
	}
	return rv(verr(.Value))
}

// compare_values orders values the way a spreadsheet does: within a type by
// the obvious rule (text case-insensitively), across types by
// number < text < boolean, with an empty cell taking on the other side's type.
compare_values :: proc(a_in, b_in: Value) -> (int, Err) {
	a, b := a_in, b_in
	if a.kind == .Error {
		return 0, a.err
	}
	if b.kind == .Error {
		return 0, b.err
	}
	if a.kind == .Empty && b.kind != .Empty {
		a = coerce_empty_like(b)
	}
	if b.kind == .Empty && a.kind != .Empty {
		b = coerce_empty_like(a)
	}
	if a.kind == .Empty && b.kind == .Empty {
		return 0, .None
	}
	ra, rb := type_rank(a), type_rank(b)
	if ra != rb {
		return ra < rb ? -1 : 1, .None
	}
	switch a.kind {
	case .Number, .Bool:
		if a.num < b.num {
			return -1, .None
		}
		return a.num > b.num ? 1 : 0, .None
	case .Text:
		return strings.compare(strings.to_lower(a.text), strings.to_lower(b.text)), .None
	case .Empty, .Error:
	}
	return 0, .None
}

coerce_empty_like :: proc(other: Value) -> Value {
	switch other.kind {
	case .Text:
		return vtext("")
	case .Bool:
		return vbool(false)
	case .Number, .Empty, .Error:
		return vnum(0)
	}
	return vnum(0)
}

type_rank :: proc(v: Value) -> int {
	switch v.kind {
	case .Number, .Empty:
		return 1
	case .Text:
		return 2
	case .Bool:
		return 3
	case .Error:
		return 4
	}
	return 0
}

// ---------------------------------------------------------------------------
// Aggregation
//
// The distinction between a range argument and a scalar argument is real and
// visible: SUM(A1:A3) ignores a cell holding "abc", while SUM("abc") is
// #VALUE!. Getting that wrong is the usual giveaway of a toy engine.
// ---------------------------------------------------------------------------

Agg :: struct {
	sum:    f64,
	count:  int, // numeric values only, as COUNT does
	counta: int, // anything non-empty, as COUNTA does
	lo:     f64,
	hi:     f64,
	have:   bool,
	err:    Err,
}

agg_add :: proc(ag: ^Agg, v: Value, from_range: bool) {
	if ag.err != .None {
		return
	}
	switch v.kind {
	case .Error:
		ag.err = v.err
		return
	case .Empty:
		return
	case .Text:
		ag.counta += 1
		if from_range {
			return // text in a range is simply skipped
		}
		x, e := as_number(v)
		if e != .None {
			ag.err = e
			return
		}
		agg_number(ag, x)
	case .Bool:
		ag.counta += 1
		if from_range {
			return // so is a boolean
		}
		agg_number(ag, v.num)
	case .Number:
		ag.counta += 1
		agg_number(ag, v.num)
	}
}

agg_number :: proc(ag: ^Agg, x: f64) {
	ag.sum += x
	ag.count += 1
	if !ag.have {
		ag.lo, ag.hi, ag.have = x, x, true
	} else {
		ag.lo = min(ag.lo, x)
		ag.hi = max(ag.hi, x)
	}
}

// agg_walk folds one argument into the accumulator, expanding a range.
agg_walk :: proc(sh: ^Sheet, n: ^Ast, at: Addr, ag: ^Agg) {
	if is_span_in(sh, n) {
		vals := make([dynamic]Value, 0, 16)
		if e := span_values(sh, n, &vals); e != .None {
			ag.err = e
			return
		}
		for v in vals {
			agg_add(ag, v, true)
			if ag.err != .None {
				return
			}
		}
		return
	}
	r := eval_ast(sh, n, at)
	if !r.rng {
		agg_add(ag, r.v, false)
		return
	}
	rs := res_sheet(sh, r)
	rect, any := clamp_rect(rs, r.rect)
	if !any {
		return
	}
	// Anything reached through a reference counts as coming from a range,
	// including a single cell: SUM(A1) where A1 holds "abc" is 0, while
	// SUM("abc") is #VALUE!.
	for row in rect.r0 ..= rect.r1 {
		for col in rect.c0 ..= rect.c1 {
			if cell_at(rs, {row, col}) == nil {
				continue
			}
			agg_add(ag, ensure_value(rs, {row, col}), true)
			if ag.err != .None {
				return
			}
		}
	}
}

// range_values flattens an argument into a list, which the text and lookup
// functions want in order.
range_values :: proc(sh: ^Sheet, n: ^Ast, at: Addr, out: ^[dynamic]Value) -> Err {
	r := eval_ast(sh, n, at)
	if !r.rng {
		if is_err(r.v) {
			return r.v.err
		}
		append(out, r.v)
		return .None
	}
	rs := res_sheet(sh, r)
	rect, any := clamp_rect(rs, r.rect)
	if !any {
		return .None
	}
	for row in rect.r0 ..= rect.r1 {
		for col in rect.c0 ..= rect.c1 {
			v := ensure_value(rs, {row, col})
			if is_err(v) {
				return v.err
			}
			append(out, v)
		}
	}
	return .None
}

// ---------------------------------------------------------------------------
// Functions
// ---------------------------------------------------------------------------

eval_call :: proc(sh: ^Sheet, n: ^Ast, at: Addr) -> Res {
	name := n.str
	k := n.kids[:]
	na := len(k)

	// Small helpers, written out rather than closed over, because Odin has no
	// closures and the explicit form reads no worse.
	sc :: proc(sh: ^Sheet, n: ^Ast, at: Addr) -> Value {
		return res_scalar(sh, eval_ast(sh, n, at))
	}

	switch name {
	case "SUM", "AVERAGE", "MIN", "MAX", "COUNT", "COUNTA", "PRODUCT", "STDEV":
		return agg_function(sh, name, k, at)

	case "IF":
		if na < 2 || na > 3 {
			return rv(verr(.Value))
		}
		cond, e := as_bool(sc(sh, k[0], at))
		if e != .None {
			return rv(verr(e))
		}
		if cond {
			return rv(sc(sh, k[1], at))
		}
		if na == 3 {
			return rv(sc(sh, k[2], at))
		}
		return rv(vbool(false))

	case "IFERROR":
		if na != 2 {
			return rv(verr(.Value))
		}
		v := sc(sh, k[0], at)
		if is_err(v) {
			return rv(sc(sh, k[1], at))
		}
		return rv(v)

	case "AND", "OR":
		if na == 0 {
			return rv(verr(.Value))
		}
		seen := false
		acc := name == "AND"
		for arg in k {
			vals := make([dynamic]Value, 0, 8)
			if e := range_values(sh, arg, at, &vals); e != .None {
				return rv(verr(e))
			}
			for v in vals {
				if v.kind == .Empty || v.kind == .Text {
					continue // ignored, as in a spreadsheet
				}
				b, e := as_bool(v)
				if e != .None {
					return rv(verr(e))
				}
				seen = true
				if name == "AND" {
					acc = acc && b
				} else {
					acc = acc || b
				}
			}
		}
		if !seen {
			return rv(verr(.Value))
		}
		return rv(vbool(acc))

	case "NOT":
		if na != 1 {
			return rv(verr(.Value))
		}
		b, e := as_bool(sc(sh, k[0], at))
		if e != .None {
			return rv(verr(e))
		}
		return rv(vbool(!b))

	case "ABS", "SQRT", "INT", "SIGN", "LN", "LOG10", "EXP":
		if na != 1 {
			return rv(verr(.Value))
		}
		x, e := as_number(sc(sh, k[0], at))
		if e != .None {
			return rv(verr(e))
		}
		switch name {
		case "ABS":
			return rv(vnum(abs(x)))
		case "SQRT":
			if x < 0 {
				return rv(verr(.Num))
			}
			return rv(vnum(math.sqrt(x)))
		case "INT":
			return rv(vnum(math.floor(x)))
		case "SIGN":
			return rv(vnum(x > 0 ? 1 : (x < 0 ? -1 : 0)))
		case "LN":
			if x <= 0 {
				return rv(verr(.Num))
			}
			return rv(vnum(math.ln(x)))
		case "LOG10":
			if x <= 0 {
				return rv(verr(.Num))
			}
			return rv(vnum(math.log10(x)))
		case "EXP":
			return rv(vnum(math.exp(x)))
		}

	case "ROUND":
		if na < 1 || na > 2 {
			return rv(verr(.Value))
		}
		x, e := as_number(sc(sh, k[0], at))
		if e != .None {
			return rv(verr(e))
		}
		d := 0.0
		if na == 2 {
			dd, e2 := as_number(sc(sh, k[1], at))
			if e2 != .None {
				return rv(verr(e2))
			}
			d = math.trunc(dd)
		}
		f := math.pow(f64(10), d)
		return rv(vnum(math.round(x * f) / f))

	case "FLOOR", "CEILING":
		if na < 1 || na > 2 {
			return rv(verr(.Value))
		}
		x, e := as_number(sc(sh, k[0], at))
		if e != .None {
			return rv(verr(e))
		}
		sig := 1.0
		if na == 2 {
			s, e2 := as_number(sc(sh, k[1], at))
			if e2 != .None {
				return rv(verr(e2))
			}
			sig = s
		}
		if sig == 0 {
			return rv(verr(.Div0))
		}
		if x > 0 && sig < 0 {
			return rv(verr(.Num))
		}
		q := x / sig
		return rv(vnum((name == "FLOOR" ? math.floor(q) : math.ceil(q)) * sig))

	case "POWER":
		if na != 2 {
			return rv(verr(.Value))
		}
		a, e1 := as_number(sc(sh, k[0], at))
		b, e2 := as_number(sc(sh, k[1], at))
		if e1 != .None {
			return rv(verr(e1))
		}
		if e2 != .None {
			return rv(verr(e2))
		}
		if a < 0 && b != math.trunc(b) {
			return rv(verr(.Num))
		}
		if a == 0 && b < 0 {
			return rv(verr(.Div0))
		}
		return rv(vnum(math.pow(a, b)))

	case "MOD":
		if na != 2 {
			return rv(verr(.Value))
		}
		a, e1 := as_number(sc(sh, k[0], at))
		b, e2 := as_number(sc(sh, k[1], at))
		if e1 != .None {
			return rv(verr(e1))
		}
		if e2 != .None {
			return rv(verr(e2))
		}
		if b == 0 {
			return rv(verr(.Div0))
		}
		// A spreadsheet's MOD takes the sign of the divisor, so
		// MOD(-3,2) is 1, not -1.
		return rv(vnum(a - b * math.floor(a / b)))

	case "CONCAT", "CONCATENATE":
		b := strings.builder_make()
		for arg in k {
			vals := make([dynamic]Value, 0, 8)
			if e := range_values(sh, arg, at, &vals); e != .None {
				return rv(verr(e))
			}
			for v in vals {
				s, e := as_text(v)
				if e != .None {
					return rv(verr(e))
				}
				strings.write_string(&b, s)
			}
		}
		return rv(vtext(strings.to_string(b)))

	case "LEN":
		if na != 1 {
			return rv(verr(.Value))
		}
		s, e := as_text(sc(sh, k[0], at))
		if e != .None {
			return rv(verr(e))
		}
		return rv(vnum(f64(utf8.rune_count_in_string(s))))

	case "UPPER", "LOWER", "TRIM":
		if na != 1 {
			return rv(verr(.Value))
		}
		s, e := as_text(sc(sh, k[0], at))
		if e != .None {
			return rv(verr(e))
		}
		switch name {
		case "UPPER":
			return rv(vtext(strings.to_upper(s)))
		case "LOWER":
			return rv(vtext(strings.to_lower(s)))
		case "TRIM":
			return rv(vtext(collapse_spaces(s)))
		}

	case "LEFT", "RIGHT":
		if na < 1 || na > 2 {
			return rv(verr(.Value))
		}
		s, e := as_text(sc(sh, k[0], at))
		if e != .None {
			return rv(verr(e))
		}
		cnt := 1
		if na == 2 {
			x, e2 := as_number(sc(sh, k[1], at))
			if e2 != .None {
				return rv(verr(e2))
			}
			if x < 0 {
				return rv(verr(.Value))
			}
			cnt = int(math.trunc(x))
		}
		rs := utf8.string_to_runes(s)
		cnt = min(cnt, len(rs))
		if name == "LEFT" {
			return rv(vtext(utf8.runes_to_string(rs[:cnt])))
		}
		return rv(vtext(utf8.runes_to_string(rs[len(rs) - cnt:])))

	case "MID":
		if na != 3 {
			return rv(verr(.Value))
		}
		s, e := as_text(sc(sh, k[0], at))
		if e != .None {
			return rv(verr(e))
		}
		st, e1 := as_number(sc(sh, k[1], at))
		cn, e2 := as_number(sc(sh, k[2], at))
		if e1 != .None {
			return rv(verr(e1))
		}
		if e2 != .None {
			return rv(verr(e2))
		}
		if st < 1 || cn < 0 {
			return rv(verr(.Value))
		}
		rs := utf8.string_to_runes(s)
		from := min(int(st) - 1, len(rs))
		to := min(from + int(cn), len(rs))
		return rv(vtext(utf8.runes_to_string(rs[from:to])))

	case "TODAY":
		return rv(vnum(today_serial()))

	case "NOW":
		return rv(vnum(now_serial()))

	case "DATE":
		if na != 3 {
			return rv(verr(.Value))
		}
		y, e1 := as_number(sc(sh, k[0], at))
		m, e2 := as_number(sc(sh, k[1], at))
		d, e3 := as_number(sc(sh, k[2], at))
		if e1 != .None {
			return rv(verr(e1))
		}
		if e2 != .None {
			return rv(verr(e2))
		}
		if e3 != .None {
			return rv(verr(e3))
		}
		return rv(vnum(f64(days_from_civil(int(y), int(m), int(d)) + UNIX_EPOCH_SERIAL)))

	case "YEAR", "MONTH", "DAY":
		if na != 1 {
			return rv(verr(.Value))
		}
		x, e := as_number(sc(sh, k[0], at))
		if e != .None {
			return rv(verr(e))
		}
		if x < 1 {
			return rv(verr(.Num))
		}
		y, m, d := civil_from_days(serial_to_unix_days(x))
		switch name {
		case "YEAR":
			return rv(vnum(f64(y)))
		case "MONTH":
			return rv(vnum(f64(m)))
		case "DAY":
			return rv(vnum(f64(d)))
		}

	case "VLOOKUP":
		return fn_vlookup(sh, k, at)

	case "MATCH":
		return fn_match(sh, k, at)

	case "INDEX":
		return fn_index(sh, k, at)

	case "ISERROR", "ISBLANK", "ISNUMBER", "ISTEXT":
		if na != 1 {
			return rv(verr(.Value))
		}
		v := sc(sh, k[0], at)
		switch name {
		case "ISERROR":
			return rv(vbool(is_err(v)))
		case "ISBLANK":
			return rv(vbool(v.kind == .Empty))
		case "ISNUMBER":
			return rv(vbool(v.kind == .Number))
		case "ISTEXT":
			return rv(vbool(v.kind == .Text))
		}
	}

	return rv(verr(.Name))
}

agg_function :: proc(sh: ^Sheet, name: string, k: []^Ast, at: Addr) -> Res {
	if len(k) == 0 {
		return rv(verr(.Value))
	}
	ag := Agg{}
	// PRODUCT and STDEV need every value, so collect them when asked for.
	nums := make([dynamic]f64, 0, 16)
	for arg in k {
		before := ag.count
		agg_walk(sh, arg, at, &ag)
		if ag.err != .None {
			return rv(verr(ag.err))
		}
		_ = before
	}
	switch name {
	case "SUM":
		return rv(vnum(ag.sum))
	case "COUNT":
		return rv(vnum(f64(ag.count)))
	case "COUNTA":
		return rv(vnum(f64(ag.counta)))
	case "AVERAGE":
		if ag.count == 0 {
			return rv(verr(.Div0))
		}
		return rv(vnum(ag.sum / f64(ag.count)))
	case "MIN":
		return rv(vnum(ag.have ? ag.lo : 0))
	case "MAX":
		return rv(vnum(ag.have ? ag.hi : 0))
	case "PRODUCT", "STDEV":
		clear(&nums)
		for arg in k {
			vals := make([dynamic]Value, 0, 16)
			e := is_span_in(sh, arg) ? span_values(sh, arg, &vals) : range_values(sh, arg, at, &vals)
			if e != .None {
				return rv(verr(e))
			}
			for v in vals {
				if v.kind == .Number {
					append(&nums, v.num)
				}
			}
		}
		if name == "PRODUCT" {
			acc := 1.0
			for x in nums {
				acc *= x
			}
			return rv(vnum(len(nums) == 0 ? 0 : acc))
		}
		if len(nums) < 2 {
			return rv(verr(.Div0))
		}
		mean := 0.0
		for x in nums {
			mean += x
		}
		mean /= f64(len(nums))
		ss := 0.0
		for x in nums {
			ss += (x - mean) * (x - mean)
		}
		return rv(vnum(math.sqrt(ss / f64(len(nums) - 1))))
	}
	return rv(verr(.Name))
}

fn_vlookup :: proc(sh: ^Sheet, k: []^Ast, at: Addr) -> Res {
	if len(k) < 3 || len(k) > 4 {
		return rv(verr(.Value))
	}
	key := res_scalar(sh, eval_ast(sh, k[0], at))
	if is_err(key) {
		return rv(key)
	}
	tbl := eval_ast(sh, k[1], at)
	if !tbl.rng {
		return rv(verr(.Value))
	}
	cidx, e := as_number(res_scalar(sh, eval_ast(sh, k[2], at)))
	if e != .None {
		return rv(verr(e))
	}
	approx := true
	if len(k) == 4 {
		b, e2 := as_bool(res_scalar(sh, eval_ast(sh, k[3], at)))
		if e2 != .None {
			return rv(verr(e2))
		}
		approx = b
	}
	ts := res_sheet(sh, tbl)
	rect := tbl.rect
	rect.r1 = min(rect.r1, max(ts.max_row, rect.r0))
	ci := int(math.trunc(cidx))
	if ci < 1 || rect.c0 + ci - 1 > rect.c1 {
		return rv(verr(.Ref))
	}
	best := -1
	for row in rect.r0 ..= rect.r1 {
		v := ensure_value(ts, {row, rect.c0})
		if is_err(v) {
			return rv(v)
		}
		c, ce := compare_values(v, key)
		if ce != .None {
			continue
		}
		if c == 0 {
			best = row
			break
		}
		if approx && c < 0 {
			best = row // the table is assumed ascending
		}
	}
	if best < 0 {
		return rv(verr(.NA))
	}
	return rv(ensure_value(ts, {best, rect.c0 + ci - 1}))
}

fn_match :: proc(sh: ^Sheet, k: []^Ast, at: Addr) -> Res {
	if len(k) < 2 || len(k) > 3 {
		return rv(verr(.Value))
	}
	key := res_scalar(sh, eval_ast(sh, k[0], at))
	if is_err(key) {
		return rv(key)
	}
	vec := eval_ast(sh, k[1], at)
	if !vec.rng {
		return rv(verr(.Value))
	}
	kind := 1
	if len(k) == 3 {
		x, e := as_number(res_scalar(sh, eval_ast(sh, k[2], at)))
		if e != .None {
			return rv(verr(e))
		}
		kind = int(math.trunc(x))
	}
	vs := res_sheet(sh, vec)
	rect, any := clamp_rect(vs, vec.rect)
	if !any {
		return rv(verr(.NA))
	}
	if rect.r0 != rect.r1 && rect.c0 != rect.c1 {
		return rv(verr(.NA)) // MATCH wants a single row or column
	}
	n := max(rect.r1 - rect.r0, rect.c1 - rect.c0) + 1
	best := -1
	for i in 0 ..< n {
		row := rect.r0 + (rect.r0 == rect.r1 ? 0 : i)
		col := rect.c0 + (rect.c0 == rect.c1 ? 0 : i)
		v := ensure_value(vs, {row, col})
		if is_err(v) {
			return rv(v)
		}
		c, ce := compare_values(v, key)
		if ce != .None {
			continue
		}
		switch kind {
		case 0:
			if c == 0 {
				return rv(vnum(f64(i + 1)))
			}
		case 1:
			if c <= 0 {
				best = i
			}
		case:
			if c >= 0 {
				best = i
			}
		}
	}
	if best < 0 {
		return rv(verr(.NA))
	}
	return rv(vnum(f64(best + 1)))
}

fn_index :: proc(sh: ^Sheet, k: []^Ast, at: Addr) -> Res {
	if len(k) < 2 || len(k) > 3 {
		return rv(verr(.Value))
	}
	src := eval_ast(sh, k[0], at)
	if !src.rng {
		return rv(verr(.Value))
	}
	xs := res_sheet(sh, src)
	rect := src.rect
	rect.r1 = min(rect.r1, max(xs.max_row, rect.r0))
	h := rect.r1 - rect.r0 + 1
	w := rect.c1 - rect.c0 + 1

	i1, e1 := as_number(res_scalar(sh, eval_ast(sh, k[1], at)))
	if e1 != .None {
		return rv(verr(e1))
	}
	a := int(math.trunc(i1))

	if len(k) == 2 {
		// One index into a single row or column indexes along it.
		if h == 1 {
			if a < 1 || a > w {
				return rv(verr(.Ref))
			}
			return rv(ensure_value(xs, {rect.r0, rect.c0 + a - 1}))
		}
		if w == 1 {
			if a < 1 || a > h {
				return rv(verr(.Ref))
			}
			return rv(ensure_value(xs, {rect.r0 + a - 1, rect.c0}))
		}
		return rv(verr(.Ref))
	}
	i2, e2 := as_number(res_scalar(sh, eval_ast(sh, k[2], at)))
	if e2 != .None {
		return rv(verr(e2))
	}
	b := int(math.trunc(i2))
	if a < 1 || a > h || b < 1 || b > w {
		return rv(verr(.Ref))
	}
	return rv(ensure_value(xs, {rect.r0 + a - 1, rect.c0 + b - 1}))
}

// collapse_spaces is TRIM: outer whitespace removed and every inner run
// reduced to one space.
collapse_spaces :: proc(s: string) -> string {
	b := strings.builder_make()
	t := strings.trim_space(s)
	space := false
	for r in t {
		if r == ' ' || r == '\t' || r == '\n' || r == '\r' {
			space = true
			continue
		}
		if space && strings.builder_len(b) > 0 {
			strings.write_rune(&b, ' ')
		}
		space = false
		strings.write_rune(&b, r)
	}
	return strings.to_string(b)
}
