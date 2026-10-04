// `calc --selftest` runs the parser against answers worked out by hand.
//
// A calculator is the one application where "it looks right" is worth nothing,
// so every case here is a value, not a rendering: precedence and associativity,
// the unary minus against the power operator, each function and its domain, and
// — just as important — the *position* each error points at, because a caret
// under the wrong character is a wrong answer of its own.
package main

import "core:fmt"
import "core:math"
import "core:strings"

checks: int
failures: int

check :: proc(ok: bool, what: string) {
	checks += 1
	if !ok {
		failures += 1
		fmt.printfln("  FAIL  %s", what)
	}
}

// eval_is asserts the value of an expression, to within floating point.
eval_is :: proc(src: string, want: f64, tol: f64 = 1e-12) {
	checks += 1
	vars := make(map[string]f64, context.temp_allocator)
	r := evaluate(src, &vars, false)
	if !r.ok {
		failures += 1
		fmt.printfln("  FAIL  %q should be %v, but: %s (at %d)", src, want, r.err.msg, r.err.pos)
		return
	}
	if abs(r.value - want) > tol {
		failures += 1
		fmt.printfln("  FAIL  %q is %v, expected %v", src, r.value, want)
	}
}

// eval_fails asserts that an expression is rejected, and that the caret lands
// on the character it should.
eval_fails :: proc(src: string, at: int, what: string) {
	checks += 1
	vars := make(map[string]f64, context.temp_allocator)
	r := evaluate(src, &vars, false)
	if r.ok {
		failures += 1
		fmt.printfln("  FAIL  %q should have been rejected (%s), got %v", src, what, r.value)
		return
	}
	if at >= 0 && r.err.pos != at {
		failures += 1
		fmt.printfln(
			"  FAIL  %q points at character %d, expected %d (%s)",
			src,
			r.err.pos,
			at,
			r.err.msg,
		)
	}
}

fmt_is :: proc(v: f64, want: string) {
	checks += 1
	got := fmt_num(v, context.temp_allocator)
	if got != want {
		failures += 1
		fmt.printfln("  FAIL  %v formats as %q, expected %q", v, got, want)
	}
}

run_selftest :: proc() {
	test_arithmetic()
	test_precedence()
	test_functions()
	test_variables()
	test_errors()
	test_tokeniser()
	test_formatting()
	test_session()

	if failures == 0 {
		fmt.printfln("calc selftest: %d checks passed", checks)
	} else {
		fmt.printfln("calc selftest: %d checks, %d FAILED", checks, failures)
	}
}

test_arithmetic :: proc() {
	eval_is("1", 1)
	eval_is("1 + 2", 3)
	eval_is("7 - 9", -2)
	eval_is("6 * 7", 42)
	eval_is("1 / 8", 0.125)
	eval_is("10 % 3", 1)
	eval_is("-10 % 3", -1)
	eval_is("2 ^ 10", 1024)
	eval_is("5!", 120)
	eval_is("0!", 1)
	eval_is("  3   +   4  ", 7)
	eval_is("1_000 + 1", 1001)
	eval_is("1e3", 1000)
	eval_is("1.5e-3", 0.0015)
	eval_is(".25 * 4", 1)
	eval_is("2 ** 3", 8)
}

test_precedence :: proc() {
	// The cases that separate a parser from a left-to-right adding machine.
	eval_is("2 + 3 * 4", 14)
	eval_is("(2 + 3) * 4", 20)
	eval_is("2 - 3 - 4", -5)
	eval_is("100 / 10 / 2", 5)
	eval_is("2 ^ 3 ^ 2", 512) // right associative, not 64
	eval_is("-2 ^ 2", -4) // power binds tighter than unary minus
	eval_is("(-2) ^ 2", 4)
	eval_is("2 ^ -1", 0.5) // the exponent may be unary
	eval_is("-(3 + 4)", -7)
	eval_is("--5", 5)
	eval_is("-3!", -6) // factorial binds tighter than unary minus
	eval_is("2 * 3 % 4", 2)
	eval_is("1 + 2 * 3 ^ 2 - 4 / 2", 17)
	eval_is("((((1 + 1))))", 2)
	eval_is("2 * (3 + (4 - (5 - 6)))", 16)
}

test_functions :: proc() {
	eval_is("sqrt(144)", 12)
	eval_is("sqrt(2) ^ 2", 2, 1e-9)
	eval_is("cbrt(-27)", -3, 1e-9)
	eval_is("abs(-7.5)", 7.5)
	eval_is("floor(-1.2)", -2)
	eval_is("ceil(-1.2)", -1)
	eval_is("round(2.5)", 3)
	eval_is("trunc(-2.9)", -2)
	eval_is("sign(-4)", -1)
	eval_is("exp(0)", 1)
	eval_is("ln(e)", 1)
	eval_is("log(1000)", 3, 1e-12)
	eval_is("log2(1024)", 10)
	eval_is("hypot(3, 4)", 5)
	eval_is("min(3, 7, -2)", -2)
	eval_is("max(1, 2, 9, 4)", 9)
	eval_is("min(2, 1) + max(2, 1)", 3)
	eval_is("pi", math.PI)
	eval_is("tau", math.TAU)
	eval_is("e", math.E)
	eval_is("sin(0)", 0)
	eval_is("cos(0)", 1)
	eval_is("sin(pi / 2)", 1, 1e-12)
	eval_is("atan(1) * 4", math.PI, 1e-12)
	eval_is("sqrt(abs(min(-16, 4)))", 4)
	eval_is("max(sqrt(16), 2 ^ 2, 4)", 4)

	// Degrees mode changes trigonometry and nothing else.
	vars := make(map[string]f64, context.temp_allocator)
	deg := evaluate("sin(90)", &vars, true)
	checks += 1
	if !deg.ok || abs(deg.value - 1) > 1e-12 {
		failures += 1
		fmt.println("  FAIL  sin(90) in degrees is 1")
	}
	rad := evaluate("sin(90)", &vars, false)
	checks += 1
	if !rad.ok || abs(rad.value - 1) < 0.1 {
		failures += 1
		fmt.println("  FAIL  sin(90) in radians is not 1")
	}
	asin_deg := evaluate("asin(1)", &vars, true)
	checks += 1
	if !asin_deg.ok || abs(asin_deg.value - 90) > 1e-12 {
		failures += 1
		fmt.println("  FAIL  asin(1) in degrees is 90")
	}
}

test_variables :: proc() {
	vars := make(map[string]f64, context.temp_allocator)

	r := evaluate("r = 4", &vars, false)
	check(r.ok && r.assign == "r" && r.value == 4, "an assignment reports its name and value")
	check(len(vars) == 0, "evaluate does not write the variable itself")

	vars["r"] = 4
	eval := evaluate("pi * r ^ 2", &vars, false)
	check(eval.ok && abs(eval.value - math.PI * 16) < 1e-12, "a variable is read back")

	vars["ans"] = 10
	a := evaluate("ans / 2", &vars, false)
	check(a.ok && a.value == 5, "ans is an ordinary variable")

	u := evaluate("unknown + 1", &vars, false)
	check(!u.ok && u.err.pos == 0, "an undefined name is rejected at its own position")
	check(strings.contains(u.err.msg, "unknown"), "and the message names it")

	p := evaluate("pi = 3", &vars, false)
	check(!p.ok, "a constant cannot be assigned")

	two := evaluate("2 = 3", &vars, false)
	check(!two.ok && two.err.pos == 2, "only a name can be assigned, and the = is blamed")
}

test_errors :: proc() {
	// The number is the character the caret must land under.
	eval_fails("1/0", 1, "division by zero")
	eval_fails("5 % 0", 2, "modulo by zero")
	eval_fails("2 +", 3, "an expression that stops early")
	eval_fails("(1 + 2", 0, "an unclosed parenthesis blames the ( that opened it")
	eval_fails("1 + 2)", 5, "a stray closing parenthesis")
	eval_fails(")", 0, "a leading closing parenthesis")
	eval_fails("3 @ 4", 2, "a character that means nothing")
	eval_fails("* 3", 0, "an operator with nothing before it")
	eval_fails("sqrt(-1)", 0, "sqrt of a negative number")
	eval_fails("ln(0)", 0, "ln of zero")
	eval_fails("log(-1)", 0, "log of a negative number")
	eval_fails("asin(2)", 0, "asin outside its domain")
	eval_fails("nosuchfn(1)", 0, "an unknown function")
	eval_fails("hypot(1)", 0, "too few arguments")
	eval_fails("sqrt(1, 2)", 0, "too many arguments")
	eval_fails("(-8) ^ 0.5", 5, "a fractional power of a negative base")
	eval_fails("0 ^ -1", 2, "zero to a negative power")
	eval_fails("200!", 3, "a factorial that cannot be represented")
	eval_fails("(-1)!", 4, "a factorial of a negative number")
	eval_fails("sqrt", 0, "a function used as a value")
	eval_fails("", 0, "nothing at all")
	eval_fails("   ", 0, "only spaces")
	eval_fails("x = ", 4, "an assignment with no right-hand side")

	// The caret has to be able to cover more than one character.
	vars := make(map[string]f64, context.temp_allocator)
	r := evaluate("nosuchfn(1)", &vars, false)
	check(!r.ok && r.err.len == 8, "the caret spans the whole offending token")
}

test_tokeniser :: proc() {
	toks := tokenise("1 + sin(2.5e-1) * x_1", context.temp_allocator)
	check(len(toks) == 9, "the token stream has the expected length")
	check(toks[0].kind == .Num && toks[0].num == 1, "a number token carries its value")
	check(toks[2].kind == .Ident && toks[2].text == "sin", "an identifier carries its text")
	check(toks[3].kind == .LParen, "parentheses are their own tokens")
	check(toks[4].kind == .Num && abs(toks[4].num - 0.25) < 1e-15, "an exponent is parsed")
	check(toks[7].kind == .Ident && toks[7].text == "x_1", "an underscore and a digit are part of a name")
	check(toks[len(toks) - 1].kind == .End, "the stream ends with End")

	// Positions are what the error caret is built on.
	toks = tokenise("  12 + 345", context.temp_allocator)
	check(toks[0].pos == 2 && toks[0].len == 2, "a token knows where it starts and how long it is")
	check(toks[2].pos == 7 && toks[2].len == 3, "and so does the one after the operator")

	toks = tokenise("2 ** 3", context.temp_allocator)
	check(toks[1].kind == .Caret && toks[1].len == 2, "** is one two-character power token")
}

test_formatting :: proc() {
	fmt_is(0, "0")
	fmt_is(42, "42")
	fmt_is(-42, "-42")
	fmt_is(1234, "1234")
	fmt_is(12345, "12 345")
	fmt_is(1234567, "1 234 567")
	fmt_is(-1234567, "-1 234 567")
	fmt_is(0.5, "0.5")
	fmt_is(-0.125, "-0.125")
	fmt_is(1.0 / 3.0, "0.3333333333")
	fmt_is(12345.5, "12 345.5")
	fmt_is(1e20, "1e+20")
	fmt_is(math.inf_f64(1), "infinity")
	fmt_is(math.nan_f64(), "not a number")

	// A grouped result has to survive being put back into the input, which is
	// what the history pane does when an entry is reused.
	cleaned, _ := strings.remove_all(fmt_num(1234567, context.temp_allocator), " ", context.temp_allocator)
	vars := make(map[string]f64, context.temp_allocator)
	again := evaluate(cleaned, &vars, false)
	check(again.ok && again.value == 1234567, "a grouped result parses again once the spaces go")
}

// ---------------------------------------------------------------------------
// A whole session, driven the way the keyboard drives it
//
// This is where the one bug this calculator shipped with lived: the variable
// name handed back by the parser is a slice of the input buffer, and the input
// buffer is cleared the moment the expression is committed. A variable stored
// under that name had a key that pointed at whatever was typed next.
// ---------------------------------------------------------------------------

type_into :: proc(c: ^Calc, s: string) {
	clear(&c.input)
	append(&c.input, ..transmute([]u8)s)
	c.cur = len(c.input)
	recompute(c)
}

test_session :: proc() {
	c := Calc {
		browse = -1,
	}
	c.vars = make(map[string]f64)
	set_var(&c, "ans", 0)

	type_into(&c, "r = 4.5")
	commit(&c)
	check(len(c.hist) == 1 && c.hist[0].assign == "r", "the assignment is in the history")
	rv, has_r := c.vars["r"]
	check(has_r && rv == 4.5, "r survived the commit that cleared the input")

	type_into(&c, "area = pi * r^2")
	commit(&c)
	last := c.hist[len(c.hist) - 1]
	check(last.ok, "the expression that uses r evaluates")
	check(len(c.vars) == 3, "ans, r and area are all defined")

	type_into(&c, "ans / 2")
	commit(&c)
	av, _ := c.vars["ans"]
	check(abs(av - 31.808625617843) < 1e-9, "ans follows the last result")

	// Every name in the panel has to still be in the map: a stale key would
	// show as a variable that cannot be read.
	for n in c.names {
		checks += 1
		if _, ok := c.vars[n]; !ok {
			failures += 1
			fmt.printfln("  FAIL  the variables panel lists %q, which the map does not have", n)
		}
	}

	// Reusing a history entry has to put something the parser accepts back in.
	reuse(&c, c.hist[1])
	again := evaluate(string(c.input[:]), &c.vars, false)
	check(again.ok, "a reused history entry parses again")

	// An error entry keeps its message after the input has moved on.
	type_into(&c, "1/0")
	commit(&c)
	type_into(&c, "9 + 9")
	commit(&c)
	bad := c.hist[len(c.hist) - 2]
	check(!bad.ok && strings.contains(bad.msg, "Division"), "a failed entry keeps its own message")
}
