// References: A1 notation in both directions, the absolute/relative markers,
// and the two transforms that most toy spreadsheets get wrong — offsetting a
// reference when a formula is copied, and fixing one up when a row or column
// is inserted or deleted.
package main

import "core:fmt"
import "core:strings"

MAX_COLS :: 16384 // A .. XFD, like every other spreadsheet
MAX_ROWS :: 1048576

Addr :: struct {
	row: int,
	col: int,
}

// Ref is one A1-style reference. `row == NO_ROW` means the reference named a
// column and no row, as the `A` in `A:A` does; `col == NO_COL` is the mirror
// image, the `1` in `1:1`, which names a row and no column.
NO_ROW :: -2
NO_COL :: -2

Ref :: struct {
	col:     int,
	row:     int,
	abs_col: bool,
	abs_row: bool,
	bad:     bool, // the target was deleted: evaluates to #REF!
}

Rect_I :: struct {
	r0, c0, r1, c1: int,
}

rect_contains :: proc(r: Rect_I, a: Addr) -> bool {
	return a.row >= r.r0 && a.row <= r.r1 && a.col >= r.c0 && a.col <= r.c1
}

rect_norm :: proc(a, b: Addr) -> Rect_I {
	return {min(a.row, b.row), min(a.col, b.col), max(a.row, b.row), max(a.col, b.col)}
}

// ---------------------------------------------------------------------------
// Column letters
// ---------------------------------------------------------------------------

// col_name is the bijective base-26 name of a column: 0 -> A, 25 -> Z,
// 26 -> AA. Note it is *not* plain base 26; there is no zero digit.
col_name :: proc(col: int) -> string {
	if col < 0 {
		return "#REF!"
	}
	buf: [8]u8
	n := 0
	c := col
	for {
		buf[n] = u8('A' + c % 26)
		n += 1
		c = c / 26 - 1
		if c < 0 || n >= len(buf) {
			break
		}
	}
	out := make([]u8, n, context.temp_allocator)
	for i in 0 ..< n {
		out[i] = buf[n - 1 - i]
	}
	return string(out)
}

col_from_name :: proc(s: string) -> (int, bool) {
	if len(s) == 0 || len(s) > 3 {
		return 0, false
	}
	v := 0
	for i in 0 ..< len(s) {
		c := s[i]
		if c >= 'a' && c <= 'z' {
			c -= 32
		}
		if c < 'A' || c > 'Z' {
			return 0, false
		}
		v = v * 26 + int(c - 'A' + 1)
	}
	v -= 1
	if v >= MAX_COLS {
		return 0, false
	}
	return v, true
}

addr_name :: proc(a: Addr) -> string {
	return fmt.tprintf("%s%d", col_name(a.col), a.row + 1)
}

// ref_text prints a reference the way it was written, dollar signs included,
// so a formula survives a round trip through the AST unchanged.
ref_text :: proc(r: Ref) -> string {
	if r.bad {
		return err_text(.Ref)
	}
	if r.col == NO_COL {
		// A whole-row endpoint: `1`, or `$1`.
		if r.row < 0 {
			return err_text(.Ref)
		}
		return fmt.tprintf("%s%d", r.abs_row ? "$" : "", r.row + 1)
	}
	if r.col < 0 {
		return err_text(.Ref)
	}
	cpart := fmt.tprintf("%s%s", r.abs_col ? "$" : "", col_name(r.col))
	if r.row == NO_ROW {
		return cpart
	}
	if r.row < 0 {
		return err_text(.Ref)
	}
	return fmt.tprintf("%s%s%d", cpart, r.abs_row ? "$" : "", r.row + 1)
}

// ref_parse reads `A1`, `$A1`, `A$1`, `$A$1` and the column-only `A` / `$A`.
// It is strict: anything left over means this is not a reference.
ref_parse :: proc(s: string) -> (Ref, bool) {
	i := 0
	r := Ref{}
	if i < len(s) && s[i] == '$' {
		r.abs_col = true
		i += 1
	}
	start := i
	for i < len(s) && is_alpha(s[i]) {
		i += 1
	}
	if i == start {
		// No letters: a bare row number, which is the `1` of `1:1`. It is
		// only ever valid inside a range, which the parser enforces.
		if row, good := row_only(s); good {
			return row, true
		}
		return {}, false
	}
	col, ok := col_from_name(s[start:i])
	if !ok {
		return {}, false
	}
	r.col = col
	if i == len(s) {
		r.row = NO_ROW
		return r, true
	}
	if s[i] == '$' {
		r.abs_row = true
		i += 1
	}
	dstart := i
	for i < len(s) && is_digit(s[i]) {
		i += 1
	}
	if i != len(s) || dstart == i {
		return {}, false
	}
	row := 0
	for k in dstart ..< i {
		row = row * 10 + int(s[k] - '0')
		if row > MAX_ROWS {
			return {}, false
		}
	}
	if row < 1 {
		return {}, false
	}
	r.row = row - 1
	return r, true
}

is_alpha :: proc(c: u8) -> bool {
	return (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z')
}

// ---------------------------------------------------------------------------
// Offsetting — the copy/paste rule
//
// Copying a formula moves every *relative* component by the distance the
// formula moved, and leaves every component marked with `$` exactly where it
// is. A relative component that would leave the sheet becomes #REF!.
// ---------------------------------------------------------------------------

ref_offset :: proc(r_in: Ref, drow, dcol: int) -> Ref {
	r := r_in
	if r.bad {
		return r
	}
	if !r.abs_col && r.col != NO_COL {
		r.col += dcol
		if r.col < 0 || r.col >= MAX_COLS {
			r.bad = true
		}
	}
	if !r.abs_row && r.row != NO_ROW {
		r.row += drow
		if r.row < 0 || r.row >= MAX_ROWS {
			r.bad = true
		}
	}
	return r
}

// ---------------------------------------------------------------------------
// Structural fixups
//
// Inserting a row shifts every reference at or below it, absolute or not —
// `$A$5` really does become `$A$6`, because the cell it names has moved.
// Deleting the row a reference names turns it into #REF!.
// ---------------------------------------------------------------------------

ref_insert :: proc(r_in: Ref, axis_row: bool, at, n: int) -> Ref {
	r := r_in
	if r.bad {
		return r
	}
	if axis_row {
		if r.row != NO_ROW && r.row >= at {
			r.row += n
			if r.row >= MAX_ROWS {
				r.bad = true
			}
		}
	} else {
		if r.col != NO_COL && r.col >= at {
			r.col += n
			if r.col >= MAX_COLS {
				r.bad = true
			}
		}
	}
	return r
}

ref_delete :: proc(r_in: Ref, axis_row: bool, at, n: int) -> Ref {
	r := r_in
	if r.bad {
		return r
	}
	if axis_row {
		if r.row == NO_ROW {
			return r
		}
		if r.row >= at && r.row < at + n {
			r.bad = true
		} else if r.row >= at + n {
			r.row -= n
		}
	} else {
		if r.col == NO_COL {
			return r
		}
		if r.col >= at && r.col < at + n {
			r.bad = true
		} else if r.col >= at + n {
			r.col -= n
		}
	}
	return r
}

// A range endpoint is clamped rather than invalidated when only part of the
// range is deleted, so SUM(A1:A10) with rows 3-4 removed becomes SUM(A1:A8)
// instead of #REF!.
range_delete :: proc(a_in, b_in: Ref, axis_row: bool, at, n: int) -> (a, b: Ref, ok: bool) {
	a, b = a_in, b_in
	get :: proc(r: Ref, axis_row: bool) -> int {
		return axis_row ? r.row : r.col
	}
	set :: proc(r: ^Ref, axis_row: bool, v: int) {
		if axis_row {r.row = v} else {r.col = v}
	}
	if axis_row && (a.row == NO_ROW || b.row == NO_ROW) {
		// A whole-column range only dies when the columns themselves go.
		return a, b, true
	}
	if !axis_row && (a.col == NO_COL || b.col == NO_COL) {
		// And a whole-row range only when the rows do.
		return a, b, true
	}
	ia, ib := get(a, axis_row), get(b, axis_row)
	lo, hi := min(ia, ib), max(ia, ib)
	if at <= lo && at + n > hi {
		a.bad = true
		b.bad = true
		return a, b, false
	}
	// Map each endpoint through the deletion, clamping an endpoint that fell
	// inside the deleted block onto the edge of what is left.
	new_lo := lo < at ? lo : (lo >= at + n ? lo - n : at)
	new_hi := hi < at ? hi : (hi >= at + n ? hi - n : at - 1)
	if ia <= ib {
		set(&a, axis_row, new_lo)
		set(&b, axis_row, new_hi)
	} else {
		set(&a, axis_row, new_hi)
		set(&b, axis_row, new_lo)
	}
	return a, b, true
}

// ---------------------------------------------------------------------------
// Parsing a range typed by the user, for Go To
// ---------------------------------------------------------------------------

parse_a1_range :: proc(s_in: string) -> (r: Rect_I, ok: bool) {
	s := strings.trim_space(s_in)
	if i := strings.index_byte(s, ':'); i >= 0 {
		a, ok1 := ref_parse(strings.trim_space(s[:i]))
		b, ok2 := ref_parse(strings.trim_space(s[i + 1:]))
		if !ok1 || !ok2 {
			return {}, false
		}
		ar := a.row == NO_ROW ? 0 : a.row
		br := b.row == NO_ROW ? 0 : b.row
		ac := a.col == NO_COL ? 0 : a.col
		bc := b.col == NO_COL ? 0 : b.col
		return rect_norm({ar, ac}, {br, bc}), true
	}
	a, ok1 := ref_parse(s)
	if !ok1 || a.row == NO_ROW || a.col == NO_COL {
		return {}, false
	}
	return {a.row, a.col, a.row, a.col}, true
}

// ---------------------------------------------------------------------------
// Sheet-qualified references
//
// `Sheet2!A1` and `'My Sheet'!A1:B4`. The quoting rule is Excel's: a name is
// bare when it reads as an identifier and does not read as a cell reference,
// and otherwise goes in single quotes with an inner quote doubled.
// ---------------------------------------------------------------------------

sheet_needs_quote :: proc(name: string) -> bool {
	if name == "" {
		return false
	}
	if is_digit(name[0]) {
		return true
	}
	for i in 0 ..< len(name) {
		c := name[i]
		if c >= 0x80 {
			continue // UTF-8 continuation or lead byte: fine bare
		}
		if !(is_alpha(c) || is_digit(c) || c == '_' || c == '.') {
			return true
		}
	}
	// A name that reads as a reference would be ambiguous with one.
	if _, ok := ref_parse(name); ok {
		return true
	}
	return false
}

// sheet_prefix renders `Sheet2!` or `'My Sheet'!`, or nothing for an
// unqualified reference.
sheet_prefix :: proc(name: string) -> string {
	if name == "" {
		return ""
	}
	if !sheet_needs_quote(name) {
		return strings.concatenate({name, "!"}, context.temp_allocator)
	}
	b := strings.builder_make(context.temp_allocator)
	strings.write_byte(&b, '\'')
	for i in 0 ..< len(name) {
		if name[i] == '\'' {
			strings.write_byte(&b, '\'')
		}
		strings.write_byte(&b, name[i])
	}
	strings.write_string(&b, "'!")
	return strings.to_string(b)
}

// split_sheet_ref peels a `Sheet!` or `'Sheet'!` prefix off a reference. The
// `!` has to be the *last* one, so `'a!b'!A1` keeps its quoted name intact.
split_sheet_ref :: proc(s_in: string) -> (sheet, rest: string, ok: bool) {
	s := strings.trim_space(s_in)
	if len(s) == 0 {
		return "", s_in, false
	}
	if s[0] == '\'' {
		i := 1
		b := strings.builder_make(context.temp_allocator)
		for i < len(s) {
			if s[i] == '\'' {
				if i + 1 < len(s) && s[i + 1] == '\'' {
					strings.write_byte(&b, '\'')
					i += 2
					continue
				}
				i += 1
				break
			}
			strings.write_byte(&b, s[i])
			i += 1
		}
		if i >= len(s) || s[i] != '!' {
			return "", s_in, false
		}
		return strings.to_string(b), s[i + 1:], true
	}
	if i := strings.last_index_byte(s, '!'); i > 0 {
		return s[:i], s[i + 1:], true
	}
	return "", s, false
}

// parse_ref_target reads what a named range or a Go To box may hold: an
// optional sheet, then a cell or a range. `abs` reports whether every
// component carried a dollar sign, which is how a defined name is written
// back out.
parse_ref_target :: proc(text: string) -> (sheet: string, rect: Rect_I, abs: bool, ok: bool) {
	sh, rest, _ := split_sheet_ref(text)
	body := strings.trim_space(rest)
	if i := strings.index_byte(body, ':'); i >= 0 {
		a, ok1 := ref_parse(strings.trim_space(body[:i]))
		// A second endpoint may repeat the sheet: `Sheet1!A1:Sheet1!B2`.
		_, tail, _ := split_sheet_ref(body[i + 1:])
		b, ok2 := ref_parse(strings.trim_space(tail))
		if !ok1 || !ok2 {
			return "", {}, false, false
		}
		ar := a.row == NO_ROW ? 0 : a.row
		br := b.row == NO_ROW ? 0 : b.row
		ac := a.col == NO_COL ? 0 : a.col
		bc := b.col == NO_COL ? 0 : b.col
		return sh,
			rect_norm({ar, ac}, {br, bc}),
			a.abs_col && a.abs_row && b.abs_col && b.abs_row,
			true
	}
	a, good := ref_parse(body)
	if !good || a.row == NO_ROW || a.col == NO_COL {
		return "", {}, false, false
	}
	return sh, {a.row, a.col, a.row, a.col}, a.abs_col && a.abs_row, true
}

// row_only reads `1` or `$1`: a whole-row endpoint, the mirror image of the
// `A` in `A:A`.
row_only :: proc(s: string) -> (Ref, bool) {
	i := 0
	r := Ref{col = NO_COL}
	if i < len(s) && s[i] == '$' {
		r.abs_row = true
		i += 1
	}
	if i >= len(s) {
		return {}, false
	}
	row := 0
	for k in i ..< len(s) {
		if !is_digit(s[k]) {
			return {}, false
		}
		row = row * 10 + int(s[k] - '0')
		if row > MAX_ROWS {
			return {}, false
		}
	}
	if row < 1 {
		return {}, false
	}
	r.row = row - 1
	return r, true
}
