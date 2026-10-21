// Delimited text, both directions. One parser and one writer serve CSV files
// and the TSV that goes on the clipboard, because the quoting rules are the
// same and only the delimiter differs.
package main

import "core:os"
import "core:strings"

// needs_quoting follows RFC 4180: the delimiter, a quote, a newline or
// surrounding whitespace all force quotes.
needs_quoting :: proc(s: string, delim: u8) -> bool {
	if s == "" {
		return false
	}
	if s[0] == ' ' || s[len(s) - 1] == ' ' {
		return true
	}
	for i in 0 ..< len(s) {
		c := s[i]
		if c == delim || c == '"' || c == '\n' || c == '\r' {
			return true
		}
	}
	return false
}

write_field :: proc(b: ^strings.Builder, s: string, delim: u8) {
	if !needs_quoting(s, delim) {
		strings.write_string(b, s)
		return
	}
	strings.write_byte(b, '"')
	for i in 0 ..< len(s) {
		if s[i] == '"' {
			strings.write_byte(b, '"') // a quote is escaped by doubling it
		}
		strings.write_byte(b, s[i])
	}
	strings.write_byte(b, '"')
}

// delim_export renders a rectangle. `raw` writes what the user typed —
// formulas included — and otherwise the displayed value goes out, which is
// what another spreadsheet expects to receive.
delim_export :: proc(
	sh: ^Sheet,
	rect: Rect_I,
	delim: u8,
	raw: bool,
	allocator := context.allocator,
) -> string {
	b := strings.builder_make(allocator)
	for row in rect.r0 ..= rect.r1 {
		for col in rect.c0 ..= rect.c1 {
			if col > rect.c0 {
				strings.write_byte(&b, delim)
			}
			c := cell_at(sh, {row, col})
			if c == nil {
				continue
			}
			write_field(&b, raw ? c.input : format_value(c.val, c.fmt), delim)
		}
		strings.write_byte(&b, '\n')
	}
	return strings.to_string(b)
}

// delim_parse is a full RFC 4180 reader: quoted fields, doubled quotes,
// embedded newlines, and CRLF or LF line endings. A trailing newline does not
// produce a phantom last row, and a file without one still yields its last.
delim_parse :: proc(
	text: string,
	delim: u8,
	allocator := context.allocator,
) -> [dynamic][dynamic]string {
	rows := make([dynamic][dynamic]string, allocator)
	row := make([dynamic]string, allocator)
	field := strings.builder_make(context.temp_allocator)
	in_quotes := false
	started := false

	i := 0
	for i < len(text) {
		c := text[i]
		if in_quotes {
			if c == '"' {
				if i + 1 < len(text) && text[i + 1] == '"' {
					strings.write_byte(&field, '"')
					i += 2
					continue
				}
				in_quotes = false
				i += 1
				continue
			}
			strings.write_byte(&field, c)
			i += 1
			continue
		}
		switch {
		case c == '"':
			in_quotes = true
			started = true
			i += 1
		case c == '\r':
			i += 1
		case c == '\n':
			append(&row, strings.clone(strings.to_string(field), allocator))
			strings.builder_reset(&field)
			append(&rows, row)
			row = make([dynamic]string, allocator)
			started = false
			i += 1
		case c == delim:
			append(&row, strings.clone(strings.to_string(field), allocator))
			strings.builder_reset(&field)
			started = true
			i += 1
		case:
			strings.write_byte(&field, c)
			started = true
			i += 1
		}
	}
	if started || strings.builder_len(field) > 0 {
		append(&row, strings.clone(strings.to_string(field), allocator))
		append(&rows, row)
	} else {
		delete(row)
	}
	return rows
}

// import_delim writes parsed rows into the sheet at `at`. Fields are fed
// through `set_input`, so a CSV holding `=A1+1` arrives as a live formula and
// `50%` arrives as a percentage.
import_delim :: proc(sh: ^Sheet, text: string, at: Addr, delim: u8) -> (rows, cols: int) {
	parsed := delim_parse(text, delim, context.temp_allocator)
	for r, ri in parsed {
		for f, ci in r {
			if f == "" {
				continue
			}
			set_input(sh, {at.row + ri, at.col + ci}, f)
		}
		cols = max(cols, len(r))
	}
	rows = len(parsed)
	sh.book.graph_dirty = true
	recalc_all(sh)
	return
}

csv_write_file :: proc(sh: ^Sheet, path: string, rect: Rect_I) -> bool {
	text := delim_export(sh, rect, ',', false, context.temp_allocator)
	return os.write_entire_file(path, transmute([]u8)text) == nil
}

csv_read_file :: proc(sh: ^Sheet, path: string, at: Addr) -> (ok: bool, rows, cols: int) {
	data, read_err := os.read_entire_file(path, context.temp_allocator)
	if read_err != nil {
		return false, 0, 0
	}
	r, c := import_delim(sh, string(data), at, ',')
	return true, r, c
}

// ---------------------------------------------------------------------------
// A whole book as CSV
//
// CSV has no sheets, so a book of several has to become several files. The
// shape chosen is LibreOffice's (`soffice --convert-to csv:...:-1`, which
// exports every sheet): `book.csv` becomes `book-Sales.csv`,
// `book-Summary.csv`, one per sheet, in sheet order, beside where `book.csv`
// would have been. A book of one sheet writes `book.csv` itself, so the
// common case is unchanged. The alternatives were worse: one file with the
// sheets stacked and a marker row between them is not CSV any reader agrees
// on; a directory changes what the path you typed *means*; a .zip of CSVs is
// a format nobody asked for.
//
// Each file is what the single-sheet export writes: the used range, from A1,
// as displayed values — a formula's result, not its text, because a CSV
// reader cannot evaluate it, and `Jan:Mar!B2` would mean nothing to it. A
// `.tsv` path writes tabs. An empty sheet writes an empty file rather than
// being skipped, so the list of files is always the list of sheets.
// ---------------------------------------------------------------------------

delim_for :: proc(path: string) -> u8 {
	return strings.has_suffix(path, ".tsv") ? '\t' : ','
}

// csv_sheet_text is one sheet's used range as delimited text.
csv_sheet_text :: proc(sh: ^Sheet, delim: u8, allocator := context.temp_allocator) -> string {
	if sh.max_row < 0 || sh.max_col < 0 {
		return strings.clone("", allocator)
	}
	return delim_export(sh, {0, 0, sh.max_row, sh.max_col}, delim, false, allocator)
}

// csv_file_safe makes a sheet name usable in a file name. Only what a file
// system or a shell would trip on is replaced; spaces and accents stay.
csv_file_safe :: proc(name: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	for i in 0 ..< len(name) {
		c := name[i]
		switch c {
		case '/', '\\', ':', '*', '?', '"', '<', '>', '|':
			strings.write_byte(&b, '_')
		case:
			strings.write_byte(&b, c < 0x20 || c == 0x7f ? '_' : c)
		}
	}
	s := strings.to_string(b)
	if s == "" || s == "." || s == ".." {
		return "_"
	}
	return s
}

// csv_book_paths is where each sheet of the book goes when the book is
// exported to `path`. Two sheets whose names clean up to the same file name
// (`a/b` and `a_b`) get a counter, so no export overwrites itself.
csv_book_paths :: proc(bk: ^Book, path: string) -> []string {
	out := make([dynamic]string, 0, len(bk.sheets), context.temp_allocator)
	if len(bk.sheets) == 1 {
		append(&out, path)
		return out[:]
	}
	stem, ext := path, ""
	slash := strings.last_index_byte(path, '/')
	if dot := strings.last_index_byte(path, '.'); dot > slash + 1 {
		stem, ext = path[:dot], path[dot:]
	}
	for sh in bk.sheets {
		cand := strings.concatenate({stem, "-", csv_file_safe(sh.name), ext}, context.temp_allocator)
		for n := 2; ; n += 1 {
			taken := false
			for p in out {
				if strings.equal_fold(p, cand) {
					taken = true
					break
				}
			}
			if !taken {
				break
			}
			cand = strings.concatenate({stem, "-", csv_file_safe(sh.name), "-", int_text(n), ext}, context.temp_allocator)
		}
		append(&out, cand)
	}
	return out[:]
}

// csv_write_book writes every sheet, the window's "Export every sheet as CSV"
// and `sheets export book.csv` alike, and returns the files in sheet order.
// It stops at the first file it cannot write and says so.
csv_write_book :: proc(bk: ^Book, path: string) -> (files: []string, ok: bool) {
	paths := csv_book_paths(bk, path)
	delim := delim_for(path)
	for sh, i in bk.sheets {
		text := csv_sheet_text(sh, delim)
		if os.write_entire_file(paths[i], transmute([]u8)text) != nil {
			return paths[:i], false
		}
	}
	return paths, true
}

// csv_write_sheet writes one whole sheet to exactly `path`.
csv_write_sheet :: proc(sh: ^Sheet, path: string) -> bool {
	text := csv_sheet_text(sh, delim_for(path))
	return os.write_entire_file(path, transmute([]u8)text) == nil
}
