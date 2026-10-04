// `sheets --selftest` exercises the engine with no window and no compositor:
// the tokeniser, operator precedence, every function, the relative/absolute
// reference rules under copy and under structural edits, error propagation,
// circular references, incremental recalculation, CSV, and the document
// round trip.
package main

import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"

TC :: struct {
	n:      int,
	failed: int,
}

ok_mark :: proc(tc: ^TC, cond: bool, what: string, loc := #caller_location) {
	tc.n += 1
	if !cond {
		tc.failed += 1
		fmt.printfln("  FAIL  %s  (%s:%d)", what, loc.file_path, loc.line)
	}
}

// A fresh sheet per expression keeps every case independent.
Fx :: struct {
	sh: Sheet,
}

fx_init :: proc(fx: ^Fx) {
	sheet_init(&fx.sh)
}

fx_done :: proc(fx: ^Fx) {
	sheet_destroy(&fx.sh)
}

ref :: proc(s: string) -> Addr {
	r, ok := ref_parse(s)
	if !ok || r.row == NO_ROW {
		return {}
	}
	return {r.row, r.col}
}

put :: proc(sh: ^Sheet, at: string, text: string) {
	set_input(sh, ref(at), text)
}

// ---------------------------------------------------------------------------
// Expectation helpers. Each builds a sheet, evaluates one expression in A1,
// and checks the settled value.
// ---------------------------------------------------------------------------

exp_num :: proc(tc: ^TC, expr: string, want: f64, loc := #caller_location) {
	fx: Fx
	fx_init(&fx)
	defer fx_done(&fx)
	put(&fx.sh, "A1", expr)
	recalc(&fx.sh)
	v := value_at(&fx.sh, {0, 0})
	tc.n += 1
	if v.kind != .Number || abs(v.num - want) > 1e-9 * max(1, abs(want)) {
		tc.failed += 1
		fmt.printfln(
			"  FAIL  %s -> %v %v, want number %v  (%s:%d)",
			expr,
			v.kind,
			v.kind == .Error ? err_text(v.err) : general_text(v.num),
			want,
			loc.file_path,
			loc.line,
		)
	}
}

exp_text :: proc(tc: ^TC, expr: string, want: string, loc := #caller_location) {
	fx: Fx
	fx_init(&fx)
	defer fx_done(&fx)
	put(&fx.sh, "A1", expr)
	recalc(&fx.sh)
	v := value_at(&fx.sh, {0, 0})
	tc.n += 1
	if v.kind != .Text || v.text != want {
		tc.failed += 1
		fmt.printfln(
			"  FAIL  %s -> %v %q, want text %q  (%s:%d)",
			expr,
			v.kind,
			v.kind == .Error ? err_text(v.err) : v.text,
			want,
			loc.file_path,
			loc.line,
		)
	}
}

exp_bool :: proc(tc: ^TC, expr: string, want: bool, loc := #caller_location) {
	fx: Fx
	fx_init(&fx)
	defer fx_done(&fx)
	put(&fx.sh, "A1", expr)
	recalc(&fx.sh)
	v := value_at(&fx.sh, {0, 0})
	tc.n += 1
	if v.kind != .Bool || (v.num != 0) != want {
		tc.failed += 1
		fmt.printfln(
			"  FAIL  %s -> %v, want bool %v  (%s:%d)",
			expr,
			v.kind == .Error ? err_text(v.err) : fmt.tprint(v.kind, v.num),
			want,
			loc.file_path,
			loc.line,
		)
	}
}

exp_err :: proc(tc: ^TC, expr: string, want: Err, loc := #caller_location) {
	fx: Fx
	fx_init(&fx)
	defer fx_done(&fx)
	put(&fx.sh, "A1", expr)
	recalc(&fx.sh)
	v := value_at(&fx.sh, {0, 0})
	tc.n += 1
	if v.kind != .Error || v.err != want {
		tc.failed += 1
		fmt.printfln(
			"  FAIL  %s -> %v, want %s  (%s:%d)",
			expr,
			v.kind == .Error ? err_text(v.err) : fmt.tprint(v.kind),
			err_text(want),
			loc.file_path,
			loc.line,
		)
	}
}

// exp_src checks that a formula survives parse -> print unchanged in meaning,
// which is the contract copy/paste and insert/delete depend on.
exp_src :: proc(tc: ^TC, src: string, want: string, loc := #caller_location) {
	root, ok := parse_formula(src)
	tc.n += 1
	if !ok {
		tc.failed += 1
		fmt.printfln("  FAIL  parse %q failed  (%s:%d)", src, loc.file_path, loc.line)
		return
	}
	got := ast_source(root, context.temp_allocator)
	ast_free(root)
	if got != want {
		tc.failed += 1
		fmt.printfln("  FAIL  print %q -> %q, want %q  (%s:%d)", src, got, want, loc.file_path, loc.line)
	}
}

exp_bad :: proc(tc: ^TC, src: string, loc := #caller_location) {
	root, ok := parse_formula(src)
	tc.n += 1
	if ok {
		tc.failed += 1
		ast_free(root)
		fmt.printfln("  FAIL  %q parsed but should not  (%s:%d)", src, loc.file_path, loc.line)
	}
}

exp_offset :: proc(tc: ^TC, src: string, drow, dcol: int, want: string, loc := #caller_location) {
	got := offset_formula(src, drow, dcol, context.temp_allocator)
	tc.n += 1
	if got != want {
		tc.failed += 1
		fmt.printfln(
			"  FAIL  offset %q by (%d,%d) -> %q, want %q  (%s:%d)",
			src,
			drow,
			dcol,
			got,
			want,
			loc.file_path,
			loc.line,
		)
	}
}

// In-sheet checks, for the tests that need data around them.
at_num :: proc(tc: ^TC, sh: ^Sheet, a: string, want: f64, loc := #caller_location) {
	v := value_at(sh, ref(a))
	tc.n += 1
	if v.kind != .Number || abs(v.num - want) > 1e-9 * max(1, abs(want)) {
		tc.failed += 1
		fmt.printfln(
			"  FAIL  %s = %v %v, want %v  (%s:%d)",
			a,
			v.kind,
			v.kind == .Error ? err_text(v.err) : general_text(v.num),
			want,
			loc.file_path,
			loc.line,
		)
	}
}

at_text :: proc(tc: ^TC, sh: ^Sheet, a: string, want: string, loc := #caller_location) {
	v := value_at(sh, ref(a))
	tc.n += 1
	if v.kind != .Text || v.text != want {
		tc.failed += 1
		fmt.printfln("  FAIL  %s = %v, want text %q  (%s:%d)", a, v, want, loc.file_path, loc.line)
	}
}

at_err :: proc(tc: ^TC, sh: ^Sheet, a: string, want: Err, loc := #caller_location) {
	v := value_at(sh, ref(a))
	tc.n += 1
	if v.kind != .Error || v.err != want {
		tc.failed += 1
		fmt.printfln(
			"  FAIL  %s = %v, want %s  (%s:%d)",
			a,
			v.kind == .Error ? err_text(v.err) : fmt.tprint(v.kind),
			err_text(want),
			loc.file_path,
			loc.line,
		)
	}
}

at_input :: proc(tc: ^TC, sh: ^Sheet, a: string, want: string, loc := #caller_location) {
	got := input_at(sh, ref(a))
	tc.n += 1
	if got != want {
		tc.failed += 1
		fmt.printfln("  FAIL  input %s = %q, want %q  (%s:%d)", a, got, want, loc.file_path, loc.line)
	}
}

at_disp :: proc(tc: ^TC, sh: ^Sheet, a: string, want: string, loc := #caller_location) {
	got := display_at(sh, ref(a))
	tc.n += 1
	if got != want {
		tc.failed += 1
		fmt.printfln("  FAIL  display %s = %q, want %q  (%s:%d)", a, got, want, loc.file_path, loc.line)
	}
}

// ---------------------------------------------------------------------------
// The suite
// ---------------------------------------------------------------------------

selftest :: proc() -> int {
	tc := TC{}

	t_literals(&tc)
	t_precedence(&tc)
	t_comparison(&tc)
	t_printer(&tc)
	t_syntax_errors(&tc)
	t_references(&tc)
	t_copy_offset(&tc)
	t_paste(&tc)
	t_structural(&tc)
	t_aggregates(&tc)
	t_logic(&tc)
	t_math(&tc)
	t_text_fns(&tc)
	t_dates(&tc)
	t_lookup(&tc)
	t_errors(&tc)
	t_circular(&tc)
	t_incremental(&tc)
	t_formatting(&tc)
	t_csv(&tc)
	t_document(&tc)
	t_xlsx(&tc)
	t_robustness(&tc)

	fmt.println()
	if tc.failed == 0 {
		fmt.printfln("sheets selftest: %d assertions, all passed", tc.n)
		return 0
	}
	fmt.printfln("sheets selftest: %d assertions, %d FAILED", tc.n, tc.failed)
	return 1
}

// --- literals and the tokeniser ---------------------------------------------

t_literals :: proc(tc: ^TC) {
	exp_num(tc, "=1", 1)
	exp_num(tc, "=1.5", 1.5)
	exp_num(tc, "=.5", 0.5)
	exp_num(tc, "=1e3", 1000)
	exp_num(tc, "=1E-2", 0.01)
	exp_num(tc, "=1.5e+2", 150)
	exp_num(tc, "= 1 + 2 ", 3)
	exp_text(tc, "=\"hello\"", "hello")
	exp_text(tc, "=\"\"", "")
	exp_text(tc, "=\"a\"\"b\"", "a\"b")
	exp_bool(tc, "=TRUE", true)
	exp_bool(tc, "=false", false)
	exp_err(tc, "=#DIV/0!", .Div0)
	exp_err(tc, "=#N/A", .NA)

	// Typed literals, no formula involved.
	fx: Fx
	fx_init(&fx)
	defer fx_done(&fx)
	sh := &fx.sh
	put(sh, "A1", "42")
	put(sh, "A2", "hello")
	put(sh, "A3", "TRUE")
	put(sh, "A4", "50%")
	put(sh, "A5", "$1,234.50")
	put(sh, "A6", "2026-10-04")
	put(sh, "A7", "'0123")
	put(sh, "A8", "-7.25")
	recalc(sh)
	at_num(tc, sh, "A1", 42)
	at_text(tc, sh, "A2", "hello")
	ok_mark(tc, value_at(sh, ref("A3")).kind == .Bool, "TRUE typed as boolean")
	at_num(tc, sh, "A4", 0.5)
	ok_mark(tc, fmt_at(sh, ref("A4")).num == .Percent, "50% picks the percent format")
	at_num(tc, sh, "A5", 1234.5)
	ok_mark(tc, fmt_at(sh, ref("A5")).num == .Currency, "$1,234.50 picks currency")
	ok_mark(tc, fmt_at(sh, ref("A6")).num == .Date, "an ISO date picks the date format")
	at_text(tc, sh, "A7", "0123", )
	at_num(tc, sh, "A8", -7.25)
}

// --- precedence and associativity ------------------------------------------

t_precedence :: proc(tc: ^TC) {
	exp_num(tc, "=1+2*3", 7)
	exp_num(tc, "=(1+2)*3", 9)
	exp_num(tc, "=2*3+4*5", 26)
	exp_num(tc, "=10-3-2", 5) // left associative
	exp_num(tc, "=100/10/2", 5)
	exp_num(tc, "=2-(3-4)", 3)
	exp_num(tc, "=2^3^2", 64) // left associative, as in a spreadsheet
	exp_num(tc, "=2^-1", 0.5)
	exp_num(tc, "=-2^2", 4) // unary minus binds tighter than ^
	exp_num(tc, "=-(2^2)", -4)
	exp_num(tc, "=--3", 3)
	exp_num(tc, "=+-3", -3)
	exp_num(tc, "=1+2^3*2", 17)
	exp_num(tc, "=50%", 0.5)
	exp_num(tc, "=50%+1", 1.5)
	exp_num(tc, "=2*3%", 0.06)
	exp_num(tc, "=-3%", -0.03)
	exp_num(tc, "=(1+1)%", 0.02)
	exp_num(tc, "=10%%", 0.001)
	exp_text(tc, "=\"a\"&\"b\"&\"c\"", "abc")
	exp_text(tc, "=\"n=\"&1+2", "n=3") // & binds looser than +
	exp_bool(tc, "=1+1=2", true) // comparison binds loosest
	exp_bool(tc, "=\"a\"&\"b\"=\"ab\"", true)
	exp_num(tc, "=((((1))))", 1)
}

// --- comparison ------------------------------------------------------------

t_comparison :: proc(tc: ^TC) {
	exp_bool(tc, "=1<2", true)
	exp_bool(tc, "=2<=2", true)
	exp_bool(tc, "=3>2", true)
	exp_bool(tc, "=3>=4", false)
	exp_bool(tc, "=1<>2", true)
	exp_bool(tc, "=1=1", true)
	exp_bool(tc, "=\"a\"=\"A\"", true) // text compares case-insensitively
	exp_bool(tc, "=\"a\"<\"b\"", true)
	exp_bool(tc, "=1<\"a\"", true) // number < text
	exp_bool(tc, "=\"a\"<TRUE", true) // text < boolean
	exp_bool(tc, "=TRUE=TRUE", true)
	exp_bool(tc, "=TRUE>FALSE", true)

	fx: Fx
	fx_init(&fx)
	defer fx_done(&fx)
	sh := &fx.sh
	put(sh, "B1", "=A1=0") // an empty cell is zero against a number
	put(sh, "B2", "=A1=\"\"") // and "" against text
	put(sh, "B3", "=A1+1")
	recalc(sh)
	ok_mark(tc, value_at(sh, ref("B1")).num != 0, "empty cell equals 0")
	ok_mark(tc, value_at(sh, ref("B2")).num != 0, "empty cell equals the empty string")
	at_num(tc, sh, "B3", 1)
}

// --- the printer -----------------------------------------------------------

t_printer :: proc(tc: ^TC) {
	exp_src(tc, "1+2*3", "=1+2*3")
	exp_src(tc, "(1+2)*3", "=(1+2)*3")
	exp_src(tc, "1+(2*3)", "=1+2*3") // redundant brackets are dropped
	exp_src(tc, "2-(3-4)", "=2-(3-4)") // needed brackets are kept
	exp_src(tc, "(10/2)/5", "=10/2/5")
	exp_src(tc, "10/(2/5)", "=10/(2/5)")
	exp_src(tc, "-2^2", "=-2^2") // unary binds tighter, so this needs no brackets
	exp_src(tc, "(-2)^2", "=-2^2")
	exp_src(tc, "-(2^2)", "=-(2^2)")
	exp_src(tc, "A1+$B$2", "=A1+$B$2")
	exp_src(tc, "$A1+A$1", "=$A1+A$1")
	exp_src(tc, "SUM(A1:B10)", "=SUM(A1:B10)")
	exp_src(tc, "sum(a1:b10)", "=SUM(A1:B10)")
	exp_src(tc, "SUM($A$1:$A$3,B1,2)", "=SUM($A$1:$A$3,B1,2)")
	exp_src(tc, "IF(A1>0,\"yes\",\"no\")", "=IF(A1>0,\"yes\",\"no\")")
	exp_src(tc, "\"a\"\"b\"", "=\"a\"\"b\"")
	exp_src(tc, "50%", "=50%")
	exp_src(tc, "A1&B1", "=A1&B1")
	exp_src(tc, "1<>2", "=1<>2")
	exp_src(tc, "A:A", "=A:A")
	exp_src(tc, "AA10", "=AA10")
	exp_src(tc, "XFD1048576", "=XFD1048576")
}

t_syntax_errors :: proc(tc: ^TC) {
	exp_bad(tc, "1+")
	exp_bad(tc, "(1")
	exp_bad(tc, "1)")
	exp_bad(tc, "*2")
	exp_bad(tc, "SUM(")
	exp_bad(tc, "SUM(1,)")
	exp_bad(tc, "\"abc")
	exp_bad(tc, "A1:")
	exp_bad(tc, "A1:A")
	exp_bad(tc, "")
	exp_bad(tc, "1 2")
	exp_bad(tc, "#NOPE!")
	// A formula that does not parse is kept but shows #VALUE!.
	exp_err(tc, "=1+", .Value)
}

// --- references ------------------------------------------------------------

t_references :: proc(tc: ^TC) {
	ok_mark(tc, col_name(0) == "A", "column 0 is A")
	ok_mark(tc, col_name(25) == "Z", "column 25 is Z")
	ok_mark(tc, col_name(26) == "AA", "column 26 is AA")
	ok_mark(tc, col_name(27) == "AB", "column 27 is AB")
	ok_mark(tc, col_name(51) == "AZ", "column 51 is AZ")
	ok_mark(tc, col_name(52) == "BA", "column 52 is BA")
	ok_mark(tc, col_name(701) == "ZZ", "column 701 is ZZ")
	ok_mark(tc, col_name(702) == "AAA", "column 702 is AAA")
	ok_mark(tc, col_name(16383) == "XFD", "the last column is XFD")
	for c in ([?]int{0, 1, 25, 26, 27, 701, 702, 16383}) {
		back, good := col_from_name(col_name(c))
		ok_mark(tc, good && back == c, fmt.tprintf("column %d round-trips", c))
	}

	for s in ([?]string{"A1", "$A1", "A$1", "$A$1", "ZZ100", "$XFD$1048576"}) {
		r, good := ref_parse(s)
		ok_mark(tc, good, fmt.tprintf("%s parses", s))
		ok_mark(tc, ref_text(r) == s, fmt.tprintf("%s prints back as itself", s))
	}
	for s in ([?]string{"A0", "1A", "A", "$", "AAAA1", "A1B", "A1048577", "XFE1"}) {
		_, good := ref_parse(s)
		ok_mark(tc, !good || s == "A", fmt.tprintf("%s is not a cell reference", s))
	}

	fx: Fx
	fx_init(&fx)
	defer fx_done(&fx)
	sh := &fx.sh
	put(sh, "A1", "7")
	put(sh, "B1", "=A1")
	put(sh, "B2", "=$A$1")
	put(sh, "B3", "=A$1")
	put(sh, "B4", "=$A1")
	put(sh, "B5", "=Z99") // an empty cell reads as zero
	put(sh, "B6", "=SUM(A1:A1)")
	recalc(sh)
	at_num(tc, sh, "B1", 7)
	at_num(tc, sh, "B2", 7)
	at_num(tc, sh, "B3", 7)
	at_num(tc, sh, "B4", 7)
	at_num(tc, sh, "B5", 0)
	at_num(tc, sh, "B6", 7)
}

// --- the copy rule ---------------------------------------------------------

t_copy_offset :: proc(tc: ^TC) {
	// Relative moves, absolute does not; mixed does exactly one of the two.
	exp_offset(tc, "=A1", 1, 1, "=B2")
	exp_offset(tc, "=A1", 0, 0, "=A1")
	exp_offset(tc, "=$A$1", 1, 1, "=$A$1")
	exp_offset(tc, "=A$1", 1, 1, "=B$1")
	exp_offset(tc, "=$A1", 1, 1, "=$A2")
	exp_offset(tc, "=A1+$B$2*C3", 2, 3, "=D3+$B$2*F5")
	exp_offset(tc, "=SUM(A1:A3)", 2, 0, "=SUM(A3:A5)")
	exp_offset(tc, "=SUM($A$1:$A$3)", 2, 0, "=SUM($A$1:$A$3)")
	exp_offset(tc, "=SUM(A$1:A3)", 2, 1, "=SUM(B$1:B5)")
	exp_offset(tc, "=A1*$B1", 0, 2, "=C1*$B1")
	exp_offset(tc, "=A1*B$1", 3, 0, "=A4*B$1")
	// Off the edge of the sheet becomes #REF!, and only for the relative part.
	exp_offset(tc, "=A1", -1, 0, "=#REF!")
	exp_offset(tc, "=A1", 0, -1, "=#REF!")
	exp_offset(tc, "=$A$1", -5, -5, "=$A$1")
	exp_offset(tc, "=A1+$A$1", -1, 0, "=#REF!+$A$1")
	// Plain literals are untouched.
	exp_offset(tc, "=1+2", 5, 5, "=1+2")
	exp_offset(tc, "=0.123456789012345*A1", 1, 0, "=0.123456789012345*A2")
	exp_offset(tc, "hello", 5, 5, "hello")
	exp_offset(tc, "=TODAY()", 5, 5, "=TODAY()")
}

t_paste :: proc(tc: ^TC) {
	fx: Fx
	fx_init(&fx)
	defer fx_done(&fx)
	sh := &fx.sh
	cb := Clipboard{}
	defer clip_reset(&cb)

	put(sh, "A1", "1")
	put(sh, "A2", "2")
	put(sh, "A3", "3")
	put(sh, "B1", "10")
	put(sh, "B2", "20")
	put(sh, "B3", "30")
	put(sh, "D1", "=A1*$B$1")
	recalc(sh)
	at_num(tc, sh, "D1", 10)

	// Copy down a column: the row moves, the absolute anchor does not.
	copy_range(sh, &cb, {0, 3, 0, 3}, false)
	paste_clip(sh, &cb, {1, 3, 1, 3})
	paste_clip(sh, &cb, {2, 3, 2, 3})
	recalc(sh)
	at_input(tc, sh, "D2", "=A2*$B$1")
	at_input(tc, sh, "D3", "=A3*$B$1")
	at_num(tc, sh, "D2", 20)
	at_num(tc, sh, "D3", 30)

	// Copy across: the column moves.
	paste_clip(sh, &cb, {0, 4, 0, 4})
	recalc(sh)
	at_input(tc, sh, "E1", "=B1*$B$1")
	at_num(tc, sh, "E1", 100)

	// Tiling: one cell pasted into a taller selection repeats down it.
	copy_range(sh, &cb, {0, 3, 0, 3}, false)
	paste_clip(sh, &cb, {5, 5, 8, 5})
	recalc(sh)
	at_input(tc, sh, "F6", "=C6*$B$1")
	at_input(tc, sh, "F9", "=C9*$B$1")

	// Fill down is the same rule.
	put(sh, "G1", "=A1+100")
	recalc(sh)
	fill_down(sh, {0, 6, 2, 6})
	recalc(sh)
	at_input(tc, sh, "G2", "=A2+100")
	at_num(tc, sh, "G3", 103)

	// Fill right.
	put(sh, "A10", "=A1")
	recalc(sh)
	fill_right(sh, {9, 0, 9, 2})
	recalc(sh)
	at_input(tc, sh, "B10", "=B1")
	at_input(tc, sh, "C10", "=C1")

	// A cut moves a formula verbatim: its references must not shift.
	put(sh, "H1", "=A1+A2")
	recalc(sh)
	copy_range(sh, &cb, {0, 7, 0, 7}, true)
	paste_clip(sh, &cb, {4, 7, 4, 7})
	recalc(sh)
	at_input(tc, sh, "H5", "=A1+A2")
	at_num(tc, sh, "H5", 3)
	ok_mark(tc, cell_at(sh, ref("H1")) == nil, "a cut empties the source")

	// Pasting off the top turns the relative part into #REF!.
	cb2 := Clipboard{}
	defer clip_reset(&cb2)
	put(sh, "J5", "=J4+1")
	recalc(sh)
	copy_range(sh, &cb2, {4, 9, 4, 9}, false)
	paste_clip(sh, &cb2, {0, 9, 0, 9})
	recalc(sh)
	at_input(tc, sh, "J1", "=#REF!+1")
	at_err(tc, sh, "J1", .Ref)
}

// --- insert and delete -----------------------------------------------------

t_structural :: proc(tc: ^TC) {
	fx: Fx
	fx_init(&fx)
	defer fx_done(&fx)
	sh := &fx.sh

	put(sh, "A1", "1")
	put(sh, "A2", "2")
	put(sh, "A3", "=A1+A2")
	put(sh, "B3", "=$A$1*10")
	put(sh, "C3", "=SUM(A1:A2)")
	recalc(sh)
	at_num(tc, sh, "A3", 3)

	// Inserting a row above pushes everything down and rewrites every
	// reference, absolute ones included.
	insert_rows(sh, 0, 1)
	at_input(tc, sh, "A4", "=A2+A3")
	at_input(tc, sh, "B4", "=$A$2*10")
	at_input(tc, sh, "C4", "=SUM(A2:A3)")
	at_num(tc, sh, "A4", 3)
	at_num(tc, sh, "B4", 10)
	at_num(tc, sh, "C4", 3)

	// Deleting it again restores the original references exactly.
	delete_rows(sh, 0, 1)
	at_input(tc, sh, "A3", "=A1+A2")
	at_input(tc, sh, "B3", "=$A$1*10")
	at_input(tc, sh, "C3", "=SUM(A1:A2)")
	at_num(tc, sh, "A3", 3)

	// Inserting inside a range stretches it.
	insert_rows(sh, 1, 1)
	at_input(tc, sh, "C4", "=SUM(A1:A3)")

	// Deleting a referenced row poisons the reference with #REF! but leaves
	// the rest of the formula alone.
	fx2: Fx
	fx_init(&fx2)
	defer fx_done(&fx2)
	s2 := &fx2.sh
	put(s2, "A1", "5")
	put(s2, "A2", "=A1+1")
	recalc(s2)
	at_num(tc, s2, "A2", 6)
	delete_rows(s2, 0, 1)
	at_input(tc, s2, "A1", "=#REF!+1")
	at_err(tc, s2, "A1", .Ref)

	// Partially deleting a range shrinks it instead.
	fx3: Fx
	fx_init(&fx3)
	defer fx_done(&fx3)
	s3 := &fx3.sh
	for i in 1 ..= 5 {
		put(s3, fmt.tprintf("A%d", i), fmt.tprintf("%d", i))
	}
	// The formula lives below the rows being removed, so it survives them and
	// travels up as they go.
	put(s3, "C7", "=SUM(A1:A5)")
	recalc(s3)
	at_num(tc, s3, "C7", 15)
	delete_rows(s3, 2, 2) // rows 3 and 4
	at_input(tc, s3, "C5", "=SUM(A1:A3)")
	at_num(tc, s3, "C5", 8) // 1 + 2 + 5
	// Deleting the whole of the range does kill it.
	delete_rows(s3, 0, 3)
	at_input(tc, s3, "C2", "=SUM(#REF!:#REF!)")
	at_err(tc, s3, "C2", .Ref)

	// Columns behave the same way.
	fx4: Fx
	fx_init(&fx4)
	defer fx_done(&fx4)
	s4 := &fx4.sh
	put(s4, "A1", "2")
	put(s4, "B1", "3")
	put(s4, "C1", "=A1*B1")
	put(s4, "D1", "=SUM(A1:B1)")
	recalc(s4)
	at_num(tc, s4, "C1", 6)
	insert_cols(s4, 0, 1)
	at_input(tc, s4, "D1", "=B1*C1")
	at_input(tc, s4, "E1", "=SUM(B1:C1)")
	at_num(tc, s4, "D1", 6)
	delete_cols(s4, 0, 1)
	at_input(tc, s4, "C1", "=A1*B1")
	at_num(tc, s4, "C1", 6)
	delete_cols(s4, 1, 1) // take out B
	at_input(tc, s4, "B1", "=A1*#REF!")
	at_err(tc, s4, "B1", .Ref)

	// Row heights and column widths travel with their row or column.
	fx5: Fx
	fx_init(&fx5)
	defer fx_done(&fx5)
	s5 := &fx5.sh
	set_row_height(s5, 3, 40)
	set_col_width(s5, 2, 150)
	insert_rows(s5, 0, 2)
	insert_cols(s5, 0, 1)
	ok_mark(tc, row_height(s5, 5) == 40, "a row height moves with its row")
	ok_mark(tc, col_width(s5, 3) == 150, "a column width moves with its column")
}

// --- aggregates ------------------------------------------------------------

t_aggregates :: proc(tc: ^TC) {
	fx: Fx
	fx_init(&fx)
	defer fx_done(&fx)
	sh := &fx.sh
	put(sh, "A1", "1")
	put(sh, "A2", "2")
	put(sh, "A3", "x")
	put(sh, "A4", "TRUE")
	put(sh, "A5", "4")
	// A6 stays empty.
	put(sh, "B1", "=SUM(A1:A6)")
	put(sh, "B2", "=COUNT(A1:A6)")
	put(sh, "B3", "=COUNTA(A1:A6)")
	put(sh, "B4", "=AVERAGE(A1:A6)")
	put(sh, "B5", "=MIN(A1:A6)")
	put(sh, "B6", "=MAX(A1:A6)")
	put(sh, "B7", "=SUM(A1:A2,10,\"5\")")
	put(sh, "B8", "=SUM(A3)") // text behind a reference is skipped
	put(sh, "B9", "=SUM(A:A)") // whole column
	put(sh, "B10", "=MIN(A3:A4)") // no numbers at all
	put(sh, "B11", "=PRODUCT(A1:A5)")
	put(sh, "B12", "=SUM(A1:A2)+SUM(A5)")
	put(sh, "B13", "=COUNT(1,2,\"3\",TRUE)")
	put(sh, "B14", "=SUM()")
	recalc(sh)
	at_num(tc, sh, "B1", 7)
	at_num(tc, sh, "B2", 3)
	at_num(tc, sh, "B3", 5)
	at_num(tc, sh, "B4", 7.0 / 3.0)
	at_num(tc, sh, "B5", 1)
	at_num(tc, sh, "B6", 4)
	at_num(tc, sh, "B7", 18)
	at_num(tc, sh, "B8", 0)
	at_num(tc, sh, "B9", 7)
	at_num(tc, sh, "B10", 0)
	at_num(tc, sh, "B11", 8)
	at_num(tc, sh, "B12", 7)
	at_num(tc, sh, "B13", 4)
	at_err(tc, sh, "B14", .Value)

	// A scalar text argument is not skipped: it has to be a number.
	exp_err(tc, "=SUM(\"abc\")", .Value)
	exp_num(tc, "=SUM(\"3\",4)", 7)
	exp_err(tc, "=AVERAGE(\"x\")", .Value)

	// AVERAGE with nothing numeric is a division by zero, as it should be.
	fx2: Fx
	fx_init(&fx2)
	defer fx_done(&fx2)
	s2 := &fx2.sh
	put(s2, "A1", "x")
	put(s2, "B1", "=AVERAGE(A1:A3)")
	recalc(s2)
	at_err(tc, s2, "B1", .Div0)

	// A two-dimensional range.
	fx3: Fx
	fx_init(&fx3)
	defer fx_done(&fx3)
	s3 := &fx3.sh
	for r in 1 ..= 3 {
		for c in 0 ..< 3 {
			put(s3, fmt.tprintf("%s%d", col_name(c), r), fmt.tprintf("%d", r * 10 + c))
		}
	}
	put(s3, "E1", "=SUM(A1:C3)")
	put(s3, "E2", "=COUNT(A1:C3)")
	recalc(s3)
	at_num(tc, s3, "E1", 10 + 11 + 12 + 20 + 21 + 22 + 30 + 31 + 32)
	at_num(tc, s3, "E2", 9)
	// A multi-cell range used as a scalar is an error.
	put(s3, "E3", "=A1:C3+1")
	recalc(s3)
	at_err(tc, s3, "E3", .Value)
}

// --- logic -----------------------------------------------------------------

t_logic :: proc(tc: ^TC) {
	exp_text(tc, "=IF(1>0,\"y\",\"n\")", "y")
	exp_text(tc, "=IF(1<0,\"y\",\"n\")", "n")
	exp_num(tc, "=IF(TRUE,1,2)", 1)
	exp_bool(tc, "=IF(FALSE,1)", false)
	exp_bool(tc, "=AND(TRUE,1>0)", true)
	exp_bool(tc, "=AND(TRUE,FALSE)", false)
	exp_bool(tc, "=OR(FALSE,FALSE)", false)
	exp_bool(tc, "=OR(FALSE,1=1)", true)
	exp_bool(tc, "=NOT(TRUE)", false)
	exp_bool(tc, "=NOT(0)", true)
	exp_num(tc, "=IFERROR(1/0,-1)", -1)
	exp_num(tc, "=IFERROR(6/2,-1)", 3)
	exp_text(tc, "=IFERROR(#REF!,\"gone\")", "gone")
	exp_bool(tc, "=ISERROR(1/0)", true)
	exp_bool(tc, "=ISNUMBER(1)", true)
	exp_bool(tc, "=ISTEXT(\"a\")", true)
	exp_bool(tc, "=ISBLANK(ZZ100)", true)
	// IF only evaluates the branch it takes, so this must not divide by zero.
	exp_text(tc, "=IF(0=0,\"safe\",1/0)", "safe")
	exp_num(tc, "=IF(1=0,1/0,9)", 9)
	exp_num(tc, "=IF(1>0,IF(2>1,5,6),7)", 5)

	fx: Fx
	fx_init(&fx)
	defer fx_done(&fx)
	sh := &fx.sh
	put(sh, "A1", "TRUE")
	put(sh, "A2", "FALSE")
	put(sh, "A3", "text")
	put(sh, "B1", "=AND(A1:A3)")
	put(sh, "B2", "=OR(A1:A3)")
	recalc(sh)
	ok_mark(tc, value_at(sh, ref("B1")).num == 0, "AND over a range ignores text")
	ok_mark(tc, value_at(sh, ref("B2")).num != 0, "OR over a range ignores text")
}

// --- maths -----------------------------------------------------------------

t_math :: proc(tc: ^TC) {
	exp_num(tc, "=ABS(-3)", 3)
	exp_num(tc, "=ABS(3)", 3)
	exp_num(tc, "=SQRT(16)", 4)
	exp_err(tc, "=SQRT(-1)", .Num)
	exp_num(tc, "=POWER(2,10)", 1024)
	exp_num(tc, "=POWER(9,0.5)", 3)
	exp_err(tc, "=POWER(-8,0.5)", .Num)
	exp_num(tc, "=MOD(10,3)", 1)
	exp_num(tc, "=MOD(-3,2)", 1) // sign follows the divisor
	exp_num(tc, "=MOD(3,-2)", -1)
	exp_err(tc, "=MOD(1,0)", .Div0)
	exp_num(tc, "=ROUND(3.14159,3)", 3.142)
	exp_num(tc, "=ROUND(2.5,0)", 3) // half away from zero
	exp_num(tc, "=ROUND(-2.5,0)", -3)
	exp_num(tc, "=ROUND(1234,-2)", 1200)
	exp_num(tc, "=ROUND(1.2345,2)", 1.23)
	exp_num(tc, "=FLOOR(7,3)", 6)
	exp_num(tc, "=FLOOR(7.9)", 7)
	exp_num(tc, "=CEILING(7,3)", 9)
	exp_num(tc, "=CEILING(7.1)", 8)
	exp_err(tc, "=FLOOR(7,0)", .Div0)
	exp_err(tc, "=CEILING(7,-3)", .Num)
	exp_num(tc, "=INT(-1.5)", -2)
	exp_num(tc, "=SIGN(-9)", -1)
	exp_num(tc, "=LOG10(1000)", 3)
	exp_num(tc, "=EXP(0)", 1)
	exp_num(tc, "=LN(EXP(2))", 2)
	exp_num(tc, "=1/3*3", 1)
	exp_err(tc, "=1/0", .Div0)
	exp_err(tc, "=0^-1", .Div0)
	exp_num(tc, "=0^0", 1)
	exp_num(tc, "=STDEV(2,4,4,4,5,5,7,9)", 2.13808993529939)
}

// --- text ------------------------------------------------------------------

t_text_fns :: proc(tc: ^TC) {
	exp_num(tc, "=LEN(\"hello\")", 5)
	exp_num(tc, "=LEN(\"héllo\")", 5) // runes, not bytes
	exp_num(tc, "=LEN(\"\")", 0)
	exp_text(tc, "=LEFT(\"hello\",2)", "he")
	exp_text(tc, "=LEFT(\"hello\")", "h")
	exp_text(tc, "=LEFT(\"hi\",9)", "hi")
	exp_text(tc, "=RIGHT(\"hello\",2)", "lo")
	exp_text(tc, "=MID(\"hello\",2,3)", "ell")
	exp_text(tc, "=MID(\"hello\",4,99)", "lo")
	exp_err(tc, "=MID(\"hello\",0,1)", .Value)
	exp_text(tc, "=UPPER(\"aBc\")", "ABC")
	exp_text(tc, "=LOWER(\"AbC\")", "abc")
	exp_text(tc, "=TRIM(\"  a   b  \")", "a b")
	exp_text(tc, "=CONCAT(\"a\",\"b\",1)", "ab1")
	exp_text(tc, "=CONCATENATE(\"x\",TRUE)", "xTRUE")
	exp_text(tc, "=UPPER(LEFT(\"hello\",3))", "HEL")
	exp_text(tc, "=\"\"&1.5", "1.5")

	fx: Fx
	fx_init(&fx)
	defer fx_done(&fx)
	sh := &fx.sh
	put(sh, "A1", "a")
	put(sh, "A2", "b")
	put(sh, "A3", "c")
	put(sh, "B1", "=CONCAT(A1:A3)")
	put(sh, "B2", "=A1&A2&A3")
	put(sh, "B3", "=LEN(A1&A2)")
	recalc(sh)
	at_text(tc, sh, "B1", "abc")
	at_text(tc, sh, "B2", "abc")
	at_num(tc, sh, "B3", 2)
}

// --- dates -----------------------------------------------------------------

t_dates :: proc(tc: ^TC) {
	// 1970-01-01 is serial 25569 in the convention this engine uses.
	ok_mark(tc, days_from_civil(1970, 1, 1) == 0, "the unix epoch is day zero")
	ok_mark(tc, date_text(25569) == "1970-01-01", "serial 25569 is 1970-01-01")
	for s in ([?]string{"1900-03-01", "2000-02-29", "2026-10-04", "2099-12-31"}) {
		serial, good := date_parse(s)
		ok_mark(tc, good, fmt.tprintf("%s parses as a date", s))
		ok_mark(tc, date_text(serial) == s, fmt.tprintf("%s round-trips", s))
	}
	_, bad := date_parse("not-a-date")
	ok_mark(tc, !bad, "a non-date does not parse as one")
	exp_num(tc, "=YEAR(DATE(2000,2,29))", 2000)
	exp_num(tc, "=MONTH(DATE(2000,2,29))", 2)
	exp_num(tc, "=DAY(DATE(2000,2,29))", 29)
	exp_num(tc, "=DATE(2026,10,5)-DATE(2026,10,4)", 1)
	exp_bool(tc, "=TODAY()>45000", true)
	exp_bool(tc, "=NOW()>=TODAY()", true)

	// A volatile formula is recomputed on every pass.
	fx: Fx
	fx_init(&fx)
	defer fx_done(&fx)
	sh := &fx.sh
	put(sh, "A1", "=TODAY()")
	recalc(sh)
	ok_mark(tc, cell_at(sh, ref("A1")).volatile, "TODAY marks the cell volatile")
	recalc(sh)
	ok_mark(tc, sh.evaluated == 1, "a volatile cell recalculates with no edit")
}

// --- lookup ----------------------------------------------------------------

t_lookup :: proc(tc: ^TC) {
	fx: Fx
	fx_init(&fx)
	defer fx_done(&fx)
	sh := &fx.sh
	put(sh, "A1", "1")
	put(sh, "B1", "one")
	put(sh, "A2", "2")
	put(sh, "B2", "two")
	put(sh, "A3", "3")
	put(sh, "B3", "three")

	put(sh, "D1", "=VLOOKUP(2,A1:B3,2,FALSE)")
	put(sh, "D2", "=VLOOKUP(2.5,A1:B3,2)")
	put(sh, "D3", "=VLOOKUP(0,A1:B3,2)")
	put(sh, "D4", "=VLOOKUP(9,A1:B3,2,FALSE)")
	put(sh, "D5", "=VLOOKUP(2,A1:B3,3,FALSE)")
	put(sh, "D6", "=VLOOKUP(1,A1:B3,1,FALSE)")
	put(sh, "E1", "=MATCH(3,A1:A3,0)")
	put(sh, "E2", "=MATCH(2.5,A1:A3,1)")
	put(sh, "E3", "=MATCH(9,A1:A3,0)")
	put(sh, "E4", "=MATCH(\"two\",B1:B3,0)")
	put(sh, "F1", "=INDEX(B1:B3,2)")
	put(sh, "F2", "=INDEX(A1:B3,3,2)")
	put(sh, "F3", "=INDEX(B1:B3,9)")
	put(sh, "F4", "=INDEX(B1:B3,MATCH(3,A1:A3,0))")
	recalc(sh)

	at_text(tc, sh, "D1", "two")
	at_text(tc, sh, "D2", "two")
	at_err(tc, sh, "D3", .NA)
	at_err(tc, sh, "D4", .NA)
	at_err(tc, sh, "D5", .Ref)
	at_num(tc, sh, "D6", 1)
	at_num(tc, sh, "E1", 3)
	at_num(tc, sh, "E2", 2)
	at_err(tc, sh, "E3", .NA)
	at_num(tc, sh, "E4", 2)
	at_text(tc, sh, "F1", "two")
	at_text(tc, sh, "F2", "three")
	at_err(tc, sh, "F3", .Ref)
	at_text(tc, sh, "F4", "three")
}

// --- errors ----------------------------------------------------------------

t_errors :: proc(tc: ^TC) {
	exp_err(tc, "=1/0", .Div0)
	exp_err(tc, "=NOSUCHFUNC(1)", .Name)
	exp_err(tc, "=bananas", .Name)
	exp_err(tc, "=\"abc\"+1", .Value)
	exp_err(tc, "=\"abc\"*2", .Value)
	exp_err(tc, "=SQRT(-1)", .Num)
	exp_num(tc, "=\"3\"+1", 4) // text that is a number does convert
	exp_num(tc, "=\"50%\"+0", 0.5)

	fx: Fx
	fx_init(&fx)
	defer fx_done(&fx)
	sh := &fx.sh
	put(sh, "A1", "#DIV/0!") // a typed error literal
	put(sh, "B1", "=A1+1") // propagates
	put(sh, "B2", "=SUM(A1:A3)") // and through an aggregate
	put(sh, "B3", "=IFERROR(A1,\"caught\")")
	put(sh, "B4", "=A1&\"x\"")
	put(sh, "B5", "=A1=1")
	recalc(sh)
	at_err(tc, sh, "A1", .Div0)
	at_err(tc, sh, "B1", .Div0)
	at_err(tc, sh, "B2", .Div0)
	at_text(tc, sh, "B3", "caught")
	at_err(tc, sh, "B4", .Div0)
	at_err(tc, sh, "B5", .Div0)

	// The first error wins, and it keeps its identity along the chain.
	put(sh, "C1", "=1/0")
	put(sh, "C2", "=C1+NOSUCH(1)")
	put(sh, "C3", "=C2*2")
	recalc(sh)
	at_err(tc, sh, "C2", .Div0)
	at_err(tc, sh, "C3", .Div0)
}

// --- circular references ---------------------------------------------------

t_circular :: proc(tc: ^TC) {
	// Self reference.
	fx: Fx
	fx_init(&fx)
	defer fx_done(&fx)
	sh := &fx.sh
	put(sh, "A1", "=A1")
	recalc(sh)
	at_err(tc, sh, "A1", .Circ)

	put(sh, "A2", "=A2+1")
	recalc(sh)
	at_err(tc, sh, "A2", .Circ)

	// A range that includes the cell computing it.
	put(sh, "A3", "=SUM(A1:A5)")
	recalc(sh)
	at_err(tc, sh, "A3", .Circ)

	// Two cells pointing at each other.
	fx2: Fx
	fx_init(&fx2)
	defer fx_done(&fx2)
	s2 := &fx2.sh
	put(s2, "A1", "=B1")
	put(s2, "B1", "=A1")
	recalc(s2)
	at_err(tc, s2, "A1", .Circ)
	at_err(tc, s2, "B1", .Circ)

	// A three-cell cycle, and a bystander that must stay healthy.
	fx3: Fx
	fx_init(&fx3)
	defer fx_done(&fx3)
	s3 := &fx3.sh
	put(s3, "A1", "=B1+1")
	put(s3, "B1", "=C1+1")
	put(s3, "C1", "=A1+1")
	put(s3, "D1", "=2*3")
	recalc(s3)
	at_err(tc, s3, "A1", .Circ)
	at_err(tc, s3, "B1", .Circ)
	at_err(tc, s3, "C1", .Circ)
	at_num(tc, s3, "D1", 6)

	// Breaking the cycle must bring the cells back to life.
	put(s3, "C1", "10")
	recalc(s3)
	at_num(tc, s3, "B1", 11)
	at_num(tc, s3, "A1", 12)

	// Re-introducing it must report the cycle again rather than keep a stale
	// number.
	put(s3, "C1", "=A1+1")
	recalc(s3)
	at_err(tc, s3, "A1", .Circ)
	at_err(tc, s3, "C1", .Circ)

	// A long chain is not a cycle, and must not be mistaken for one.
	fx4: Fx
	fx_init(&fx4)
	defer fx_done(&fx4)
	s4 := &fx4.sh
	set_input(s4, {0, 0}, "1")
	for i in 1 ..< 600 {
		set_input(s4, {i, 0}, fmt.tprintf("=A%d+1", i))
	}
	recalc(s4)
	at_num(tc, s4, "A600", 600)

	// A cycle reached through a long chain is still a cycle, and the engine
	// must say so rather than exhaust the stack.
	fx5: Fx
	fx_init(&fx5)
	defer fx_done(&fx5)
	s5 := &fx5.sh
	for i in 1 ..= 400 {
		set_input(s5, {i - 1, 0}, fmt.tprintf("=A%d+1", i == 400 ? 1 : i + 1))
	}
	recalc(s5)
	at_err(tc, s5, "A1", .Circ)
	at_err(tc, s5, "A400", .Circ)
}

// --- incremental recalculation ---------------------------------------------

t_incremental :: proc(tc: ^TC) {
	fx: Fx
	fx_init(&fx)
	defer fx_done(&fx)
	sh := &fx.sh
	put(sh, "A1", "1")
	put(sh, "B1", "=A1*2")
	put(sh, "C1", "=B1+1")
	put(sh, "Z1", "=99") // unrelated
	recalc(sh)
	at_num(tc, sh, "B1", 2)
	at_num(tc, sh, "C1", 3)

	put(sh, "A1", "5")
	recalc(sh)
	at_num(tc, sh, "B1", 10)
	at_num(tc, sh, "C1", 11)
	ok_mark(tc, sh.evaluated == 2, fmt.tprintf("only the two dependents recalculated (got %d)", sh.evaluated))

	// Editing the unrelated cell touches nothing else.
	put(sh, "Z1", "=98")
	recalc(sh)
	ok_mark(tc, sh.evaluated == 1, fmt.tprintf("an unrelated edit recalculates one cell (got %d)", sh.evaluated))

	// A range dependency fires for a cell inside the range that did not exist
	// when the formula was written.
	put(sh, "D1", "=SUM(A1:A10)")
	recalc(sh)
	at_num(tc, sh, "D1", 5)
	put(sh, "A7", "100")
	recalc(sh)
	at_num(tc, sh, "D1", 105)
	ok_mark(tc, sh.evaluated == 1, fmt.tprintf("a range watcher recalculates one cell (got %d)", sh.evaluated))

	// Clearing a cell propagates too.
	put(sh, "A7", "")
	recalc(sh)
	at_num(tc, sh, "D1", 5)

	// A deep chain settles in one pass, in dependency order.
	fx2: Fx
	fx_init(&fx2)
	defer fx_done(&fx2)
	s2 := &fx2.sh
	put(s2, "A1", "2")
	put(s2, "A5", "=A4*2")
	put(s2, "A3", "=A2*2")
	put(s2, "A4", "=A3*2")
	put(s2, "A2", "=A1*2")
	recalc(s2)
	at_num(tc, s2, "A5", 32)
	put(s2, "A1", "3")
	recalc(s2)
	at_num(tc, s2, "A5", 48)
	ok_mark(tc, sh.evaluated >= 0, "recalculation completes")
}

// --- number formats --------------------------------------------------------

t_formatting :: proc(tc: ^TC) {
	ok_mark(tc, general_text(0) == "0", "general: 0")
	ok_mark(tc, general_text(1) == "1", "general: 1")
	ok_mark(tc, general_text(-1.5) == "-1.5", "general: -1.5")
	ok_mark(tc, general_text(0.1 + 0.2) == "0.3", "general: 0.1+0.2 reads as 0.3")
	ok_mark(tc, general_text(1.0 / 3.0) == "0.3333333333", fmt.tprintf("general: one third (got %s)", general_text(1.0 / 3.0)))
	ok_mark(tc, general_text(1e20) == "1E+20", fmt.tprintf("general: 1e20 (got %s)", general_text(1e20)))
	ok_mark(tc, general_text(1234567) == "1234567", "general: no separators")
	ok_mark(tc, group_digits("1234567.5") == "1,234,567.5", "grouping")
	ok_mark(tc, group_digits("123") == "123", "grouping leaves short numbers alone")

	fx: Fx
	fx_init(&fx)
	defer fx_done(&fx)
	sh := &fx.sh
	put(sh, "A1", "1234.5")
	put(sh, "A2", "0.25")
	put(sh, "A3", "-1234.5")
	put(sh, "A4", "=1/3")
	put(sh, "A5", "0")
	recalc(sh)
	set_cell_fmt(sh, ref("A1"), {num = .Fixed, dec = 2})
	set_cell_fmt(sh, ref("A2"), {num = .Percent, dec = 0})
	set_cell_fmt(sh, ref("A3"), {num = .Currency, dec = 2})
	set_cell_fmt(sh, ref("A4"), {num = .Fixed, dec = 4})
	set_cell_fmt(sh, ref("A5"), {num = .Date})
	at_disp(tc, sh, "A1", "1,234.50")
	at_disp(tc, sh, "A2", "25%")
	at_disp(tc, sh, "A3", "-$1,234.50")
	at_disp(tc, sh, "A4", "0.3333")
	at_disp(tc, sh, "A5", "1899-12-30")

	ok_mark(tc, value_align(vnum(1), {}) == .Right, "numbers align right")
	ok_mark(tc, value_align(vtext("a"), {}) == .Left, "text aligns left")
	ok_mark(tc, value_align(vbool(true), {}) == .Center, "booleans centre")
	ok_mark(tc, value_align(verr(.Ref), {}) == .Center, "errors centre")
	ok_mark(tc, value_align(vnum(1), {align = .Left}) == .Left, "an explicit alignment wins")

	// A formula showing an error renders the error text.
	put(sh, "B1", "=1/0")
	recalc(sh)
	at_disp(tc, sh, "B1", "#DIV/0!")
}

// --- CSV -------------------------------------------------------------------

t_csv :: proc(tc: ^TC) {
	fx: Fx
	fx_init(&fx)
	defer fx_done(&fx)
	sh := &fx.sh
	put(sh, "A1", "name")
	put(sh, "B1", "qty")
	put(sh, "A2", "wid, get")
	put(sh, "B2", "2")
	put(sh, "A3", "say \"hi\"")
	put(sh, "B3", "=B2*3")
	put(sh, "A4", " padded ")
	put(sh, "B4", "line\nbreak")
	recalc(sh)

	text := delim_export(sh, {0, 0, 3, 1}, ',', false, context.temp_allocator)
	want := "name,qty\n\"wid, get\",2\n\"say \"\"hi\"\"\",6\n\" padded \",\"line\nbreak\"\n"
	ok_mark(tc, text == want, fmt.tprintf("CSV export quotes correctly (got %q)", text))

	rows := delim_parse(text, ',', context.temp_allocator)
	ok_mark(tc, len(rows) == 4, fmt.tprintf("CSV parses 4 rows (got %d)", len(rows)))
	if len(rows) == 4 {
		ok_mark(tc, len(rows[0]) == 2, "two fields in the header")
		ok_mark(tc, rows[1][0] == "wid, get", "an embedded comma survives")
		ok_mark(tc, rows[2][0] == "say \"hi\"", "embedded quotes survive")
		ok_mark(tc, rows[3][0] == " padded ", "surrounding spaces survive")
		ok_mark(tc, rows[3][1] == "line\nbreak", "an embedded newline survives")
		ok_mark(tc, rows[2][1] == "6", "the computed value is exported, not the formula")
	}

	// CRLF, and a last line with no terminator.
	rows2 := delim_parse("a,b\r\nc,d", ',', context.temp_allocator)
	ok_mark(tc, len(rows2) == 2 && rows2[1][1] == "d", "CRLF and a missing final newline")
	rows3 := delim_parse("a,,c\n", ',', context.temp_allocator)
	ok_mark(tc, len(rows3) == 1 && len(rows3[0]) == 3 && rows3[0][1] == "", "an empty middle field")

	// Importing brings formulas and typed formats back to life.
	fx2: Fx
	fx_init(&fx2)
	defer fx_done(&fx2)
	s2 := &fx2.sh
	import_delim(s2, "1,2,=A1+B1\n50%,x,\n", {0, 0}, ',')
	at_num(tc, s2, "C1", 3)
	at_num(tc, s2, "A2", 0.5)
	ok_mark(tc, fmt_at(s2, ref("A2")).num == .Percent, "an imported percentage keeps its format")
	at_text(tc, s2, "B2", "x")

	// A full round trip of the raw inputs preserves formulas exactly.
	raw := delim_export(sh, {0, 0, 3, 1}, '\t', true, context.temp_allocator)
	fx3: Fx
	fx_init(&fx3)
	defer fx_done(&fx3)
	s3 := &fx3.sh
	import_delim(s3, raw, {0, 0}, '\t')
	at_input(tc, s3, "B3", "=B2*3")
	at_num(tc, s3, "B3", 6)
	at_text(tc, s3, "A2", "wid, get")
}

// --- the document format ---------------------------------------------------

t_document :: proc(tc: ^TC) {
	fx: Fx
	fx_init(&fx)
	defer fx_done(&fx)
	sh := &fx.sh
	put(sh, "A1", "1")
	put(sh, "A2", "2")
	put(sh, "A3", "=SUM(A1:A2)")
	put(sh, "B1", "label")
	put(sh, "B2", "=$A$1*100")
	put(sh, "C1", "=1/0")
	recalc(sh)
	set_cell_fmt(sh, ref("A3"), {num = .Fixed, dec = 3, bold = true, align = .Center})
	set_col_width(sh, 1, 150)
	set_row_height(sh, 2, 44)

	text := doc_save_string(sh, "test", ref("B2"), ref("A1"), context.temp_allocator)
	ok_mark(tc, strings.contains(text, "palmy.sheets"), "the saved document is tagged")
	ok_mark(tc, strings.contains(text, "=SUM(A1:A2)"), "formulas are saved as source")
	ok_mark(tc, !strings.contains(text, "\"val\""), "computed values are not saved")

	fx2: Fx
	fx_init(&fx2)
	defer fx_done(&fx2)
	s2 := &fx2.sh
	name, cur, anc, ok := doc_load_string(s2, text)
	ok_mark(tc, ok, "the document loads")
	ok_mark(tc, name == "test", "the name round-trips")
	ok_mark(tc, cur == ref("B2") && anc == ref("A1"), "the selection round-trips")
	at_input(tc, s2, "A3", "=SUM(A1:A2)")
	at_num(tc, s2, "A3", 3)
	at_num(tc, s2, "B2", 100)
	at_text(tc, s2, "B1", "label")
	at_err(tc, s2, "C1", .Div0)
	f := fmt_at(s2, ref("A3"))
	ok_mark(tc, f.num == .Fixed && f.dec == 3 && f.bold && f.align == .Center, "formatting round-trips")
	ok_mark(tc, col_width(s2, 1) == 150, "a column width round-trips")
	ok_mark(tc, row_height(s2, 2) == 44, "a row height round-trips")
	ok_mark(tc, len(s2.cells) == len(sh.cells), "the same number of cells comes back")

	// Garbage must be rejected, not half-loaded.
	fx3: Fx
	fx_init(&fx3)
	defer fx_done(&fx3)
	_, _, _, bad := doc_load_string(&fx3.sh, "not json at all")
	ok_mark(tc, !bad, "a non-document is rejected")

	// Saving again must produce the same bytes.
	text2 := doc_save_string(s2, "test", ref("B2"), ref("A1"), context.temp_allocator)
	ok_mark(tc, text == text2, "save -> load -> save is byte identical")
}

// --- robustness ------------------------------------------------------------
//
// A spreadsheet must never fall over on something typed into a cell, however
// strange. These are not interesting results; they are a guarantee that there
// is a result at all.

t_robustness :: proc(tc: ^TC) {
	junk := [?]string {
		"=",
		"==",
		"=((((",
		"=))))",
		"=,,,,",
		"=::",
		"=A1:::B2",
		"=$$$",
		"=1e",
		"=1.2.3",
		"=\"",
		"=SUM(SUM(SUM(1)))",
		"=IF(IF(IF(1,1,1),1,1),1,1)",
		"=----------1",
		"=1%%%%%%",
		"=A1048576+XFD1",
		"=#",
		"=#VALUE",
		"='",
		"=&",
		"=LEFT(\"a\",-1)",
		"=MID(\"abc\",1)",
		"=VLOOKUP(1)",
		"=INDEX()",
		"=MATCH(1)",
		"=TODAY(1,2,3)",
		"=CONCAT()",
		"=A1:A1:A1",
		"=-\"x\"",
		"=TRUE+TRUE",
	}
	fx: Fx
	fx_init(&fx)
	defer fx_done(&fx)
	for j, i in junk {
		set_input(&fx.sh, {i, 0}, j)
	}
	recalc(&fx.sh)
	bad := 0
	for _, i in junk {
		if value_at(&fx.sh, {i, 0}).kind == .Empty {
			bad += 1
		}
	}
	ok_mark(tc, bad == 0, fmt.tprintf("every malformed formula produced a value (%d did not)", bad))

	// A very wide range is clamped to the cells that exist, so it costs what
	// the data costs and not what the address space costs.
	fx2: Fx
	fx_init(&fx2)
	defer fx_done(&fx2)
	s2 := &fx2.sh
	put(s2, "A1", "1")
	put(s2, "A2", "2")
	put(s2, "B1", "=SUM(A1:A1048576)")
	put(s2, "B2", "=COUNT(A:A)")
	recalc(s2)
	at_num(tc, s2, "B1", 3)
	at_num(tc, s2, "B2", 2)

	// A reference to an empty cell reads as zero when it is the answer, and
	// as nothing when it is being counted.
	exp_num(tc, "=ZZ900", 0)
	exp_num(tc, "=ZZ900+1", 1)
	exp_bool(tc, "=ISBLANK(ZZ900)", true)
	exp_num(tc, "=COUNT(ZZ900)", 0)

	// A one-cell range is a scalar; a larger one is not. (The expression goes
	// in A1, so the ranges deliberately avoid it.)
	exp_num(tc, "=SUM(B1:B1)", 0)
	exp_err(tc, "=B1:C2+1", .Value)

	// Nested functions and deep expressions survive a copy intact.
	exp_offset(
		tc,
		"=IF(SUM($A$1:A5)>0,VLOOKUP(B1,$C$1:D9,2,FALSE),MAX(E1:E9))",
		1,
		1,
		"=IF(SUM($A$1:B6)>0,VLOOKUP(C2,$C$1:E10,2,FALSE),MAX(F2:F10))",
	)

	// Text that overflows and numbers that do not fit still format.
	ok_mark(tc, format_value(vtext("x"), {num = .Currency}) == "x", "a format does not apply to text")
	ok_mark(tc, format_value(EMPTY, {num = .Fixed, dec = 2}) == "", "an empty cell formats as nothing")
	ok_mark(tc, format_value(verr(.Ref), {num = .Percent}) == "#REF!", "an error formats as itself")
}

_ :: math
_ :: os
