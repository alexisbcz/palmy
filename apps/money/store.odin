// Persistence: one text file, in one directory, that this program owns.
//
//     ~/.local/share/palmy-money/book.money
//
// Nothing is written anywhere else, nothing outside that directory is read
// without the user picking it in the file dialog, and no part of this program
// goes looking through the home directory for statements.
//
// The format is tab-separated records with a one-letter tag, which is chosen
// over JSON for a reason that matters for a file holding someone's accounts:
// it is readable and repairable by hand. If this application ever writes
// something wrong, the user can open the file in a text editor, see which
// line is the problem, and fix it. A single-line JSON blob offers them
// nothing. Amounts are written as plain integer centimes, so the file is also
// exactly what was in memory — no decimal formatting on the way out and no
// parsing of decimals on the way back in.
//
//     A  id  kind  tint  archived  name  iban  bank
//     T  id  date  value  method  cleared  auto  ext_id  label  note
//     E  txn_id  account  amount
//     B  category  year  month  limit  rollover
//     R  source  method  income  category  pattern
//     P  name  fingerprint  delim  skip  header  encoding  datefmt  decimal  flip  <10 column indexes>
//     S  account  balance  date
package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

STORE_DIR_NAME :: "palmy-money"
STORE_FILE :: "book.money"
STORE_VERSION :: 1

// store_dir is the one directory this program writes to. It follows
// XDG_DATA_HOME when set, which is what a user who has moved their data
// directory expects.
store_dir :: proc(allocator := context.temp_allocator) -> string {
	if xdg := os.get_env("XDG_DATA_HOME", context.temp_allocator); xdg != "" {
		return fmt.aprintf("%s/%s", xdg, STORE_DIR_NAME, allocator = allocator)
	}
	home := os.get_env("HOME", context.temp_allocator)
	if home == "" {
		return fmt.aprintf("./%s", STORE_DIR_NAME, allocator = allocator)
	}
	return fmt.aprintf("%s/.local/share/%s", home, STORE_DIR_NAME, allocator = allocator)
}

store_path :: proc(allocator := context.temp_allocator) -> string {
	return fmt.aprintf("%s/%s", store_dir(context.temp_allocator), STORE_FILE, allocator = allocator)
}

// mkdir_all creates the store directory and its parents. "Already there" is
// success, which is the normal case on every run after the first.
@(private = "file")
mkdir_all :: proc(path: string) -> bool {
	if os.is_dir(path) {
		return true
	}
	_ = os.make_directory_all(path)
	return os.is_dir(path)
}

// ---------------------------------------------------------------------------
// Escaping
// ---------------------------------------------------------------------------

// A label can contain anything the bank felt like, including a tab. Escaping
// is the three characters that would otherwise break the record format.
@(private = "file")
esc :: proc(s: string, allocator := context.temp_allocator) -> string {
	if !strings.contains_any(s, "\\\t\n\r") {
		return s
	}
	b := strings.builder_make(allocator)
	for i in 0 ..< len(s) {
		switch s[i] {
		case '\\':
			strings.write_string(&b, "\\\\")
		case '\t':
			strings.write_string(&b, "\\t")
		case '\n':
			strings.write_string(&b, "\\n")
		case '\r':
			strings.write_string(&b, "\\r")
		case:
			strings.write_byte(&b, s[i])
		}
	}
	return strings.to_string(b)
}

@(private = "file")
unesc :: proc(s: string, allocator := context.temp_allocator) -> string {
	if !strings.contains(s, "\\") {
		return strings.clone(s, allocator)
	}
	b := strings.builder_make(allocator)
	i := 0
	for i < len(s) {
		if s[i] != '\\' || i + 1 >= len(s) {
			strings.write_byte(&b, s[i])
			i += 1
			continue
		}
		switch s[i + 1] {
		case 't':
			strings.write_byte(&b, '\t')
		case 'n':
			strings.write_byte(&b, '\n')
		case 'r':
			strings.write_byte(&b, '\r')
		case '\\':
			strings.write_byte(&b, '\\')
		case:
			strings.write_byte(&b, s[i + 1])
		}
		i += 2
	}
	return strings.to_string(b)
}

// ---------------------------------------------------------------------------
// Writing
// ---------------------------------------------------------------------------

// store_text serialises the whole book. Separated from the file write so the
// round trip can be asserted in the selftest without touching the disk —
// which is also why the test suite never writes to the store directory.
store_text :: proc(app: ^App, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	fmt.sbprintfln(&b, "# palmy-money %d", STORE_VERSION)

	l := &app.led
	for a in l.accounts {
		fmt.sbprintfln(
			&b,
			"A\t%d\t%d\t%d\t%d\t%s\t%s\t%s",
			a.id,
			int(a.kind),
			a.tint,
			a.archived ? 1 : 0,
			esc(a.name),
			esc(a.iban),
			esc(a.bank),
		)
	}
	for &t in l.txns {
		if t.dead {
			continue
		}
		fmt.sbprintfln(
			&b,
			"T\t%d\t%s\t%s\t%d\t%d\t%d\t%s\t%s\t%s",
			t.id,
			date_iso(t.date),
			date_iso(t.value),
			int(t.method),
			t.cleared ? 1 : 0,
			t.auto_cat ? 1 : 0,
			esc(t.ext_id),
			esc(t.label),
			esc(t.note),
		)
		for e in t.entries {
			fmt.sbprintfln(&b, "E\t%d\t%d\t%d", t.id, e.account, i64(e.amount))
		}
	}
	for bg in app.budgets {
		fmt.sbprintfln(
			&b,
			"B\t%d\t%d\t%d\t%d\t%d",
			bg.category,
			bg.year,
			bg.month,
			i64(bg.limit),
			bg.rollover ? 1 : 0,
		)
	}
	// Only the rules the user is responsible for: the built-in table lives in
	// the program and reloading it from disk would freeze it at whatever the
	// version that wrote the file happened to ship.
	for r in app.cat.rules {
		if r.source == .Builtin {
			continue
		}
		fmt.sbprintfln(
			&b,
			"R\t%d\t%d\t%d\t%s\t%s",
			int(r.source),
			int(r.method),
			r.income ? 1 : 0,
			esc(r.category),
			esc(r.pattern),
		)
	}
	for p in app.profiles {
		fmt.sbprintfln(
			&b,
			"P\t%s\t%s\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d",
			esc(p.name),
			esc(p.fingerprint),
			int(p.delim),
			p.skip,
			p.has_header ? 1 : 0,
			int(p.encoding),
			int(p.date_fmt),
			int(p.decimal),
			p.flip ? 1 : 0,
			p.col_date,
			p.col_value,
			p.col_label,
			p.col_label2,
			p.col_label3,
			p.col_amount,
			p.col_debit,
			p.col_credit,
			p.col_balance,
			p.col_ref,
		)
	}
	for r in app.recon {
		if !r.set {
			continue
		}
		fmt.sbprintfln(&b, "S\t%d\t%d\t%s", r.account, i64(r.balance), date_iso(r.as_of))
	}
	return strings.to_string(b)
}

// store_save writes the book. The write is atomic in the way that matters:
// a temporary file in the same directory, then a rename, so an interrupted
// save cannot leave a half-written book where the real one was.
store_save :: proc(app: ^App) -> bool {
	dir := store_dir(context.temp_allocator)
	if !mkdir_all(dir) {
		return false
	}
	return store_save_to(app, fmt.tprintf("%s/%s", dir, STORE_FILE))
}

// store_save_to writes the book to a named file, the same way. It is what
// `store_save` does for the application's own store, and what the command
// line does for the book named by --book: one writer, two callers.
store_save_to :: proc(app: ^App, final: string) -> bool {
	text := store_text(app, context.temp_allocator)
	tmp := fmt.tprintf("%s.tmp", final)
	if werr := os.write_entire_file(tmp, transmute([]u8)text); werr != nil {
		return false
	}
	if err := os.rename(tmp, final); err != nil {
		os.remove(tmp)
		return false
	}
	app.dirty = false
	return true
}

// ---------------------------------------------------------------------------
// Reading
// ---------------------------------------------------------------------------

@(private = "file")
num :: proc(s: string) -> int {
	v, _ := strconv.parse_int(strings.trim_space(s))
	return v
}

@(private = "file")
cents :: proc(s: string) -> Cents {
	v, _ := strconv.parse_i64(strings.trim_space(s))
	return Cents(v)
}

@(private = "file")
flag :: proc(s: string) -> bool {
	return strings.trim_space(s) == "1"
}

// store_parse rebuilds a book from text.
//
// Transactions are assembled entry by entry and only committed through
// `txn_add`, which refuses an unbalanced set — so a store file that has been
// edited by hand into something that does not add up is rejected at the
// transaction that breaks, loudly, rather than loaded into a ledger that
// silently does not balance.
store_parse :: proc(app: ^App, text: string) -> (loaded: int, problems: int) {
	l := &app.led
	// A fresh ledger: the two equity accounts are recreated by name below so
	// that ids line up with the file.
	pending_id := -1
	pending := make([dynamic]Entry, context.temp_allocator)
	pending_t: Txn_Spec
	pending_cleared := false

	commit :: proc(
		l: ^Ledger,
		spec: ^Txn_Spec,
		ents: ^[dynamic]Entry,
		cleared: bool,
		problems: ^int,
	) {
		if len(ents^) == 0 {
			return
		}
		spec.entries = ents^[:]
		id, ok := txn_add(l, spec^)
		if !ok {
			problems^ += 1
		} else if cleared {
			if t, found := txn_get(l, id); found {
				t.cleared = true
			}
		}
		clear(ents)
	}

	for line in strings.split_lines(text, context.temp_allocator) {
		// Only the carriage return is trimmed. `trim_right_space` would eat
		// the trailing tabs, and a trailing tab is an empty *field* — an
		// account with no IBAN, a transaction with no note — so trimming it
		// loses the field count and the record is refused.
		raw := strings.trim_right(line, "\r")
		if raw == "" || raw[0] == '#' {
			continue
		}
		f := strings.split(raw, "\t", context.temp_allocator)
		if len(f) < 2 {
			continue
		}
		switch f[0] {
		case "A":
			if len(f) < 8 {
				problems += 1
				continue
			}
			id := num(f[1])
			kind := Account_Kind(clamp(num(f[2]), 0, len(Account_Kind) - 1))
			name := unesc(f[5], context.temp_allocator)
			// Accounts are written in id order and ids are indexes, so a gap
			// means a corrupt file; fill it rather than misalign every entry.
			for len(l.accounts) < id {
				account_add(l, fmt.tprintf("(compte %d)", len(l.accounts)), .Equity)
			}
			idx := -1
			if existing, found := account_find(l, name); found {
				idx = existing
			} else {
				idx = account_add(
					l,
					name,
					kind,
					unesc(f[6], context.temp_allocator),
					unesc(f[7], context.temp_allocator),
				)
			}
			l.accounts[idx].tint = num(f[3])
			l.accounts[idx].archived = flag(f[4])
			if l.accounts[idx].iban == "" {
				delete(l.accounts[idx].iban)
				l.accounts[idx].iban = strings.clone(unesc(f[6], context.temp_allocator))
			}
		case "T":
			commit(l, &pending_t, &pending, pending_cleared, &problems)
			if len(f) < 10 {
				problems += 1
				pending_id = -1
				continue
			}
			d, dok := date_parse(f[2], .YMD)
			if !dok {
				problems += 1
				pending_id = -1
				continue
			}
			v, _ := date_parse(f[3], .YMD)
			pending_id = num(f[1])
			pending_t = Txn_Spec {
				date   = d,
				value  = v,
				method = Method(clamp(num(f[4]), 0, len(Method) - 1)),
				ext_id = unesc(f[7], context.temp_allocator),
				label  = unesc(f[8], context.temp_allocator),
				note   = unesc(f[9], context.temp_allocator),
				auto   = flag(f[6]),
			}
			pending_cleared = flag(f[5])
		case "E":
			if len(f) < 4 || pending_id < 0 {
				problems += 1
				continue
			}
			if num(f[1]) != pending_id {
				problems += 1
				continue
			}
			acct := num(f[2])
			if acct < 0 || acct >= len(l.accounts) {
				problems += 1
				continue
			}
			append(&pending, Entry{acct, cents(f[3])})
		case "B":
			if len(f) < 6 {
				problems += 1
				continue
			}
			budget_set(app, num(f[1]), num(f[2]), num(f[3]), cents(f[4]), flag(f[5]))
		case "R":
			if len(f) < 6 {
				problems += 1
				continue
			}
			src := Rule_Source(clamp(num(f[1]), 0, len(Rule_Source) - 1))
			append(
				&app.cat.rules,
				Rule {
					pattern = strings.clone(unesc(f[5], context.temp_allocator)),
					category = strings.clone(unesc(f[4], context.temp_allocator)),
					method = Method(clamp(num(f[2]), 0, len(Method) - 1)),
					income = flag(f[3]),
					source = src,
				},
			)
		case "P":
			if len(f) < 20 {
				problems += 1
				continue
			}
			pr := profile_blank()
			pr.name = strings.clone(unesc(f[1], context.temp_allocator))
			pr.fingerprint = strings.clone(unesc(f[2], context.temp_allocator))
			pr.delim = u8(num(f[3]))
			pr.skip = num(f[4])
			pr.has_header = flag(f[5])
			pr.encoding = Encoding(clamp(num(f[6]), 0, len(Encoding) - 1))
			pr.date_fmt = Date_Format(clamp(num(f[7]), 0, len(Date_Format) - 1))
			pr.decimal = Separator(clamp(num(f[8]), 0, len(Separator) - 1))
			pr.flip = flag(f[9])
			pr.col_date = num(f[10])
			pr.col_value = num(f[11])
			pr.col_label = num(f[12])
			pr.col_label2 = num(f[13])
			pr.col_label3 = num(f[14])
			pr.col_amount = num(f[15])
			pr.col_debit = num(f[16])
			pr.col_credit = num(f[17])
			pr.col_balance = num(f[18])
			pr.col_ref = num(f[19])
			pr.learned = true
			append(&app.profiles, pr)
		case "S":
			if len(f) < 4 {
				problems += 1
				continue
			}
			if d, ok := date_parse(f[3], .YMD); ok {
				recon_note_statement(app, num(f[1]), cents(f[2]), d)
			}
		case:
			problems += 1
		}
	}
	commit(l, &pending_t, &pending, pending_cleared, &problems)
	return txn_count(l), problems
}

// store_load reads the book if there is one. A missing file is not an error:
// it is the first run.
store_load :: proc(app: ^App) -> bool {
	loaded, _ := store_load_from(app, store_path(context.temp_allocator))
	return loaded
}

// store_load_from reads a named book: the window's own store through
// `store_load`, or the book the command line was given with --book. `found`
// is false only when there is no such file.
store_load_from :: proc(app: ^App, path: string) -> (loaded: bool, found: bool) {
	if !os.is_file(path) {
		return false, false
	}
	raw, rerr := os.read_entire_file_from_path(path, context.allocator)
	if rerr != nil {
		return false, true
	}
	defer delete(raw)
	text, _ := decode_text(raw, .UTF8, context.temp_allocator)
	n, problems := store_parse(app, text)
	if problems > 0 {
		app.status = fmt.aprintf("%d ligne(s) du fichier de données refusée(s)", problems)
	}
	return n > 0, true
}

// ---------------------------------------------------------------------------
// Bank profiles: remembering how a bank's CSV is laid out
// ---------------------------------------------------------------------------

// profile_for_fingerprint finds the saved mapping for a header line.
profile_for_fingerprint :: proc(app: ^App, fp: string) -> ^Bank_Profile {
	for &p in app.profiles {
		if p.fingerprint == fp && profile_complete(p) {
			return &p
		}
	}
	return nil
}

// profile_for_path reads just enough of a file to work out its header, then
// looks the mapping up. It reads only the file the user picked, and only its
// first few kilobytes.
profile_for_path :: proc(app: ^App, path: string) -> ^Bank_Profile {
	raw, rerr := os.read_entire_file_from_path(path, context.allocator)
	if rerr != nil {
		return nil
	}
	defer delete(raw)
	head := raw
	if len(head) > 8192 {
		head = head[:8192]
	}
	text, _ := decode_text(head, .Auto, context.temp_allocator)
	if detect_format(text, path) != .CSV {
		return nil
	}
	// The fingerprint needs the header row, which needs the delimiter and the
	// preamble length — exactly what the guesser works out.
	guessed, good := csv_guess_profile(text)
	if !good {
		return nil
	}
	delim := guessed.delim
	rows := csv_rows(text, delim, context.temp_allocator)
	if guessed.skip >= len(rows) {
		return nil
	}
	fp := fingerprint_of(rows[guessed.skip].fields, context.temp_allocator)
	return profile_for_fingerprint(app, fp)
}

// profile_remember saves the mapping that just worked, keyed by the header
// line. This is the part of a CSV importer that decides whether the thing is
// pleasant to use: a bank is configured once.
profile_remember :: proc(app: ^App, s: ^Statement) {
	if s.header == "" {
		return
	}
	if existing := profile_for_fingerprint(app, s.header); existing != nil {
		return
	}
	// Re-derive the mapping from the file that was just read, so what is
	// saved is exactly what worked.
	raw, rerr := os.read_entire_file_from_path(s.path, context.allocator)
	if rerr != nil {
		return
	}
	defer delete(raw)
	text, _ := decode_text(raw, .Auto, context.temp_allocator)
	guessed, good := csv_guess_profile(text)
	if !good {
		return
	}
	guessed.fingerprint = strings.clone(s.header)
	name := s.bank
	if name == "" {
		name = profile_name_from(s.header)
	}
	guessed.name = strings.clone(name)
	guessed.learned = false
	append(&app.profiles, guessed)
	app.dirty = true
}

// profile_name_from makes a human name for a mapping out of its header line,
// which is better than "Profil 3" when the user comes to look at the list.
profile_name_from :: proc(fp: string, allocator := context.temp_allocator) -> string {
	parts := strings.split(fp, "|", context.temp_allocator)
	if len(parts) == 0 {
		return strings.clone("Banque", allocator)
	}
	return fmt.aprintf("CSV %d colonnes", len(parts), allocator = allocator)
}

// profile_save_explicit records a mapping the user set by hand in the import
// dialog, which outranks a guess.
profile_save_explicit :: proc(app: ^App, prof: Bank_Profile) {
	for &p in app.profiles {
		if p.fingerprint == prof.fingerprint {
			name := p.name
			fp := p.fingerprint
			p = prof
			p.name = name
			p.fingerprint = fp
			p.learned = true
			app.dirty = true
			return
		}
	}
	pr := prof
	pr.name = strings.clone(prof.name)
	pr.fingerprint = strings.clone(prof.fingerprint)
	pr.learned = true
	append(&app.profiles, pr)
	app.dirty = true
}
