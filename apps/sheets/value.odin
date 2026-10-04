// The value model: the five things a spreadsheet cell can hold, the coercions
// between them, and how each one is rendered for display.
package main

import "core:fmt"
import "core:math"
import "core:strconv"
import "core:strings"
import "core:time"

// ---------------------------------------------------------------------------
// Errors
//
// A spreadsheet error is a value, not an exception: it flows through every
// operator and function so that a wrong cell poisons exactly the cells that
// read it and nothing else.
// ---------------------------------------------------------------------------

Err :: enum u8 {
	None,
	Div0,
	Ref,
	Name,
	Value,
	Circ,
	Num,
	NA,
}

err_text :: proc(e: Err) -> string {
	switch e {
	case .None:
		return ""
	case .Div0:
		return "#DIV/0!"
	case .Ref:
		return "#REF!"
	case .Name:
		return "#NAME?"
	case .Value:
		return "#VALUE!"
	case .Circ:
		return "#CIRC!"
	case .Num:
		return "#NUM!"
	case .NA:
		return "#N/A"
	}
	return ""
}

// err_parse recognises an error typed straight into a cell, which is how a
// test fixture (and a CSV round-trip) reproduces one.
err_parse :: proc(s: string) -> (Err, bool) {
	for e in Err {
		if e == .None {
			continue
		}
		if strings.equal_fold(s, err_text(e)) {
			return e, true
		}
	}
	return .None, false
}

// ---------------------------------------------------------------------------
// Values
// ---------------------------------------------------------------------------

Kind :: enum u8 {
	Empty,
	Number,
	Text,
	Bool,
	Error,
}

Value :: struct {
	kind: Kind,
	num:  f64,
	text: string,
	err:  Err,
}

EMPTY :: Value{}

vnum :: proc(x: f64) -> Value {
	// Odin's division by zero produces an infinity; a spreadsheet does not
	// have one, so anything non-finite becomes #NUM!.
	if math.is_nan(x) || math.is_inf(x) {
		return verr(.Num)
	}
	return {kind = .Number, num = x}
}

vtext :: proc(s: string) -> Value {
	return {kind = .Text, text = s}
}

vbool :: proc(b: bool) -> Value {
	return {kind = .Bool, num = b ? 1 : 0}
}

verr :: proc(e: Err) -> Value {
	return {kind = .Error, err = e}
}

is_err :: proc(v: Value) -> bool {
	return v.kind == .Error
}

// ---------------------------------------------------------------------------
// Coercion
//
// These are the spreadsheet rules, not Odin's: an empty cell is zero in
// arithmetic and "" in text, a boolean is 1 or 0, and text is converted only
// when it parses cleanly as a number.
// ---------------------------------------------------------------------------

as_number :: proc(v: Value) -> (f64, Err) {
	switch v.kind {
	case .Empty:
		return 0, .None
	case .Number, .Bool:
		return v.num, .None
	case .Text:
		t := strings.trim_space(v.text)
		if t == "" {
			return 0, .None
		}
		if x, ok := number_from_text(t); ok {
			return x, .None
		}
		return 0, .Value
	case .Error:
		return 0, v.err
	}
	return 0, .None
}

as_text :: proc(v: Value) -> (string, Err) {
	switch v.kind {
	case .Empty:
		return "", .None
	case .Text:
		return v.text, .None
	case .Number:
		return fmt.tprint(general_text(v.num)), .None
	case .Bool:
		return v.num != 0 ? "TRUE" : "FALSE", .None
	case .Error:
		return "", v.err
	}
	return "", .None
}

as_bool :: proc(v: Value) -> (bool, Err) {
	switch v.kind {
	case .Empty:
		return false, .None
	case .Bool, .Number:
		return v.num != 0, .None
	case .Text:
		t := strings.trim_space(v.text)
		if strings.equal_fold(t, "TRUE") {
			return true, .None
		}
		if strings.equal_fold(t, "FALSE") {
			return false, .None
		}
		return false, .Value
	case .Error:
		return false, v.err
	}
	return false, .None
}

// number_from_text accepts what a cell accepts: an optional currency sign,
// thousands separators, a trailing percent, and parentheses for negatives.
number_from_text :: proc(s_in: string) -> (f64, bool) {
	s := strings.trim_space(s_in)
	if s == "" {
		return 0, false
	}
	neg := false
	if len(s) >= 2 && s[0] == '(' && s[len(s) - 1] == ')' {
		neg = true
		s = s[1:len(s) - 1]
	}
	if len(s) > 0 && (s[0] == '-' || s[0] == '+') {
		neg = neg != (s[0] == '-')
		s = s[1:]
	}
	for len(s) > 0 && (s[0] == '$' || s[0] == 0xc2) {
		// 0xc2 is the lead byte of a non-breaking currency glyph; skip the
		// whole rune if one turns up.
		if s[0] == '$' {
			s = s[1:]
		} else if len(s) >= 2 {
			s = s[2:]
		} else {
			return 0, false
		}
	}
	pct := false
	if strings.has_suffix(s, "%") {
		pct = true
		s = s[:len(s) - 1]
	}
	// Strip thousands separators, but only where they sit between digits.
	if strings.contains(s, ",") {
		b := strings.builder_make(context.temp_allocator)
		for i in 0 ..< len(s) {
			if s[i] == ',' && i > 0 && i + 1 < len(s) && is_digit(s[i - 1]) && is_digit(s[i + 1]) {
				continue
			}
			strings.write_byte(&b, s[i])
		}
		s = strings.to_string(b)
	}
	s = strings.trim_space(s)
	if s == "" {
		return 0, false
	}
	x, ok := strconv.parse_f64(s)
	if !ok {
		return 0, false
	}
	if pct {
		x /= 100
	}
	if neg {
		x = -x
	}
	return x, true
}

is_digit :: proc(c: u8) -> bool {
	return c >= '0' && c <= '9'
}

// ---------------------------------------------------------------------------
// Number rendering
// ---------------------------------------------------------------------------

Num_Format :: enum u8 {
	General,
	Fixed,
	Percent,
	Currency,
	Date,
	Scientific,
}

num_format_name :: proc(f: Num_Format) -> string {
	switch f {
	case .General:
		return "General"
	case .Fixed:
		return "Fixed"
	case .Percent:
		return "Percent"
	case .Currency:
		return "Currency"
	case .Date:
		return "Date"
	case .Scientific:
		return "Scientific"
	}
	return ""
}

Halign :: enum u8 {
	Auto,
	Left,
	Center,
	Right,
}

Cell_Fmt :: struct {
	num:    Num_Format,
	dec:    u8,
	align:  Halign,
	bold:   bool,
	italic: bool,
}

fmt_is_default :: proc(f: Cell_Fmt) -> bool {
	return f == Cell_Fmt{}
}

// round_sig rounds to n significant digits, which is what makes a general
// cell show 0.3 for =0.1+0.2 instead of 0.30000000000000004.
round_sig :: proc(x: f64, n: int) -> f64 {
	if x == 0 || math.is_nan(x) || math.is_inf(x) {
		return x
	}
	mag := math.floor(math.log10(abs(x))) + 1
	p := f64(n) - mag
	if p > 300 || p < -300 {
		return x
	}
	f := math.pow(f64(10), p)
	return math.round(x * f) / f
}

// general_text is the "General" format: as many digits as are meaningful, no
// trailing zeros, scientific notation only when the magnitude demands it.
general_text :: proc(x_in: f64) -> string {
	x := x_in
	if x == 0 {
		return "0"
	}
	a := abs(x)
	if a >= 1e15 || a < 1e-10 {
		return trim_exponent(fmt.tprintf("%.5E", x))
	}
	x = round_sig(x, 10)
	if x == math.trunc(x) && abs(x) < 1e15 {
		return fmt.tprintf("%d", i64(x))
	}
	s := fmt.tprintf("%.11f", x)
	return trim_zeros(s)
}

// number_source prints a number for a *formula*, where fidelity matters more
// than looking tidy: shortest representation that reads back identically.
number_source :: proc(x: f64) -> string {
	if x == math.trunc(x) && abs(x) < 1e15 {
		return fmt.tprintf("%d", i64(x))
	}
	buf := make([]u8, 48, context.temp_allocator)
	// `write_float` emits a leading sign slot; precision -1 asks for the
	// shortest form that parses back to the same bits.
	s := strconv.write_float(buf, x, 'g', -1, 64)
	if len(s) > 0 && s[0] == '+' {
		return s[1:]
	}
	return s
}

trim_zeros :: proc(s: string) -> string {
	if !strings.contains(s, ".") {
		return s
	}
	n := len(s)
	for n > 0 && s[n - 1] == '0' {
		n -= 1
	}
	if n > 0 && s[n - 1] == '.' {
		n -= 1
	}
	return s[:n]
}

trim_exponent :: proc(s: string) -> string {
	// %E gives 1.50000E+08; drop the mantissa's trailing zeros.
	i := strings.index_byte(s, 'E')
	if i < 0 {
		return s
	}
	return fmt.tprintf("%s%s", trim_zeros(s[:i]), s[i:])
}

// group_digits inserts thousands separators into an already-formatted
// non-negative decimal string.
group_digits :: proc(s: string) -> string {
	intpart := s
	frac := ""
	if d := strings.index_byte(s, '.'); d >= 0 {
		intpart = s[:d]
		frac = s[d:]
	}
	if len(intpart) <= 3 {
		return fmt.tprintf("%s%s", intpart, frac)
	}
	b := strings.builder_make(context.temp_allocator)
	lead := len(intpart) % 3
	if lead == 0 {
		lead = 3
	}
	strings.write_string(&b, intpart[:lead])
	for i := lead; i < len(intpart); i += 3 {
		strings.write_byte(&b, ',')
		strings.write_string(&b, intpart[i:i + 3])
	}
	strings.write_string(&b, frac)
	return strings.to_string(b)
}

// format_value is what the grid and the status bar show. It never allocates
// beyond the temp allocator, so a frame's worth of formatting is free.
format_value :: proc(v: Value, f: Cell_Fmt) -> string {
	switch v.kind {
	case .Empty:
		return ""
	case .Error:
		return err_text(v.err)
	case .Bool:
		return v.num != 0 ? "TRUE" : "FALSE"
	case .Text:
		return v.text
	case .Number:
	}

	x := v.num
	switch f.num {
	case .General:
		return general_text(x)
	case .Fixed:
		s := fmt.tprintf("%.*f", int(f.dec), abs(x))
		g := group_digits(s)
		return x < 0 ? fmt.tprintf("-%s", g) : g
	case .Percent:
		return fmt.tprintf("%.*f%%", int(f.dec), x * 100)
	case .Currency:
		s := fmt.tprintf("%.*f", int(f.dec), abs(x))
		g := group_digits(s)
		return x < 0 ? fmt.tprintf("-$%s", g) : fmt.tprintf("$%s", g)
	case .Date:
		return date_text(x)
	case .Scientific:
		return fmt.tprintf("%.*E", int(f.dec), x)
	}
	return general_text(x)
}

// value_align resolves the automatic alignment rule every spreadsheet uses:
// numbers right, text left, booleans and errors centred.
value_align :: proc(v: Value, f: Cell_Fmt) -> Halign {
	if f.align != .Auto {
		return f.align
	}
	switch v.kind {
	case .Number:
		return .Right
	case .Bool, .Error:
		return .Center
	case .Text, .Empty:
		return .Left
	}
	return .Left
}

// ---------------------------------------------------------------------------
// Dates
//
// Serial numbers count days from 1899-12-30, the convention every spreadsheet
// agrees on for dates from 1900-03-01 onward. The fictitious 1900-02-29 that
// Lotus introduced and Excel kept is deliberately not reproduced.
// ---------------------------------------------------------------------------

UNIX_EPOCH_SERIAL :: 25569 // 1970-01-01

// civil_from_days is Howard Hinnant's algorithm, valid across the proleptic
// Gregorian calendar.
civil_from_days :: proc(z_in: i64) -> (y: int, m: int, d: int) {
	z := z_in + 719468
	era := (z >= 0 ? z : z - 146096) / 146097
	doe := z - era * 146097
	yoe := (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
	yy := yoe + era * 400
	doy := doe - (365 * yoe + yoe / 4 - yoe / 100)
	mp := (5 * doy + 2) / 153
	dd := doy - (153 * mp + 2) / 5 + 1
	mm := mp < 10 ? mp + 3 : mp - 9
	if mm <= 2 {
		yy += 1
	}
	return int(yy), int(mm), int(dd)
}

days_from_civil :: proc(y_in, m, d: int) -> i64 {
	y := i64(y_in)
	if m <= 2 {
		y -= 1
	}
	era := (y >= 0 ? y : y - 399) / 400
	yoe := y - era * 400
	mp := i64(m > 2 ? m - 3 : m + 9)
	doy := (153 * mp + 2) / 5 + i64(d) - 1
	doe := yoe * 365 + yoe / 4 - yoe / 100 + doy
	return era * 146097 + doe - 719468
}

serial_to_unix_days :: proc(serial: f64) -> i64 {
	return i64(math.floor(serial)) - UNIX_EPOCH_SERIAL
}

date_text :: proc(serial: f64) -> string {
	if serial < 0 || serial > 2958466 {
		return err_text(.Num)
	}
	y, m, d := civil_from_days(serial_to_unix_days(serial))
	frac := serial - math.floor(serial)
	if frac > 1.0 / 86400.0 {
		secs := int(math.round(frac * 86400))
		return fmt.tprintf(
			"%04d-%02d-%02d %02d:%02d",
			y,
			m,
			d,
			(secs / 3600) % 24,
			(secs / 60) % 60,
		)
	}
	return fmt.tprintf("%04d-%02d-%02d", y, m, d)
}

// date_parse accepts YYYY-MM-DD and YYYY/MM/DD, which is enough to type a
// date into a cell and get a number back.
date_parse :: proc(s_in: string) -> (f64, bool) {
	s := strings.trim_space(s_in)
	if len(s) < 8 || len(s) > 10 {
		return 0, false
	}
	sep: u8 = 0
	for c in transmute([]u8)s {
		if c == '-' || c == '/' {
			sep = c
			break
		}
	}
	if sep == 0 {
		return 0, false
	}
	parts := strings.split(s, sep == '-' ? "-" : "/", context.temp_allocator)
	if len(parts) != 3 {
		return 0, false
	}
	y, ok1 := strconv.parse_int(parts[0])
	m, ok2 := strconv.parse_int(parts[1])
	d, ok3 := strconv.parse_int(parts[2])
	if !ok1 || !ok2 || !ok3 {
		return 0, false
	}
	if y < 1900 || y > 9999 || m < 1 || m > 12 || d < 1 || d > 31 {
		return 0, false
	}
	return f64(days_from_civil(y, m, d) + UNIX_EPOCH_SERIAL), true
}

now_serial :: proc() -> f64 {
	ns := time.to_unix_nanoseconds(time.now())
	return f64(ns) / 86_400_000_000_000.0 + f64(UNIX_EPOCH_SERIAL)
}

today_serial :: proc() -> f64 {
	return math.floor(now_serial())
}
