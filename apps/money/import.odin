// What an import produces, and how it reaches the ledger.
//
// Every format — CSV, OFX, CAMT.053 — parses into the same `Statement`: a
// list of rows with a date, a label, a signed amount in centimes and, when
// the bank gave one, its own transaction id. Nothing format-specific survives
// past this struct, so the de-duplication, the categorisation and the
// double-entry booking are written once.
//
// The import is deliberately two steps. Parsing cannot touch the ledger, so a
// malformed file cannot half-apply: it produces a Statement with errors
// listed and nothing is booked. Only `statement_ingest` writes, and it writes
// through `txn_add`, which refuses an unbalanced transaction.
package main

import "core:fmt"
import "core:os"
import "core:strings"

Import_Format :: enum {
	Unknown,
	CSV,
	OFX,
	CAMT053,
}

format_name :: proc(f: Import_Format) -> string {
	switch f {
	case .CSV:
		return "CSV"
	case .OFX:
		return "OFX/QFX"
	case .CAMT053:
		return "CAMT.053"
	case .Unknown:
		return "inconnu"
	}
	return "inconnu"
}

Raw_Txn :: struct {
	date:        Date,
	value:       Date,
	label:       string,
	ext_id:      string, // the bank's own id: FITID, NtryRef
	amount:      Cents, // signed: negative is money out
	balance:     Cents, // the running balance on the row, when given
	has_balance: bool,
	line:        int, // where in the file, for an error the user can act on
}

Statement :: struct {
	path:         string,
	format:       Import_Format,
	encoding:     Encoding,
	bank:         string, // the profile that read it
	iban:         string,
	acct_id:      string, // the bank's account number, when there is no IBAN
	currency:     string,
	closing:      Cents, // the statement's own closing balance
	has_closing:  bool,
	closing_date: Date,
	txns:         [dynamic]Raw_Txn,
	warnings:     [dynamic]string,
	errors:       [dynamic]string,
	rows_seen:    int,
	rows_bad:     int,
	header:       string, // the CSV header line, as a mapping fingerprint
}

statement_init :: proc(s: ^Statement) {
	s.txns = make([dynamic]Raw_Txn)
	s.warnings = make([dynamic]string)
	s.errors = make([dynamic]string)
	s.currency = "EUR"
}

statement_destroy :: proc(s: ^Statement) {
	for t in s.txns {
		delete(t.label)
		delete(t.ext_id)
	}
	delete(s.txns)
	for w in s.warnings {
		delete(w)
	}
	delete(s.warnings)
	for e in s.errors {
		delete(e)
	}
	delete(s.errors)
	delete(s.path)
	delete(s.iban)
	delete(s.acct_id)
	delete(s.bank)
	delete(s.header)
}

stmt_warn :: proc(s: ^Statement, format: string, args: ..any) {
	append(&s.warnings, fmt.aprintf(format, ..args))
}

stmt_error :: proc(s: ^Statement, format: string, args: ..any) {
	append(&s.errors, fmt.aprintf(format, ..args))
}

statement_ok :: proc(s: ^Statement) -> bool {
	return len(s.errors) == 0 && len(s.txns) > 0
}

// ---------------------------------------------------------------------------
// Sniffing the format
// ---------------------------------------------------------------------------

// detect_format looks at the content, not the extension. A bank that names a
// CAMT file `.xml` and another that names the same thing `.camt` should both
// work, and an OFX file called `.qfx` is the normal case rather than the
// exception.
detect_format :: proc(text: string, path := "") -> Import_Format {
	head := text
	if len(head) > 4096 {
		head = head[:4096]
	}
	upper := strings.to_upper(head, context.temp_allocator)
	switch {
	case strings.contains(upper, "<OFX>"), strings.contains(upper, "OFXHEADER"):
		return .OFX
	case strings.contains(upper, "<DOCUMENT"), strings.contains(upper, "<BKTOCSTMT"):
		return .CAMT053
	case strings.contains(upper, "CAMT.053"):
		return .CAMT053
	case strings.has_prefix(strings.trim_space(head), "<?XML"):
		// An XML file that is neither: CAMT is the only XML statement format
		// this reads, so try it and let the parser complain usefully.
		return .CAMT053
	}
	if strings.contains(head, ";") || strings.contains(head, ",") || strings.contains(head, "\t") {
		return .CSV
	}
	_ = path
	return .Unknown
}

// read_statement_file is the only place in this program that opens a file the
// user named. Nothing scans a directory looking for statements.
read_statement_file :: proc(
	path: string,
	profile: ^Bank_Profile = nil,
) -> (
	stmt: ^Statement,
	ok: bool,
) {
	raw, rerr := os.read_entire_file_from_path(path, context.allocator)
	if rerr != nil {
		s := new(Statement)
		statement_init(s)
		s.path = strings.clone(path)
		stmt_error(s, "impossible de lire %s", path)
		return s, false
	}
	defer delete(raw)

	want := Encoding.Auto
	if profile != nil {
		want = profile.encoding
	}
	text, enc := decode_text(raw, want)
	defer delete(text)

	s := new(Statement)
	statement_init(s)
	s.path = strings.clone(path)
	s.encoding = enc
	s.format = detect_format(text, path)

	switch s.format {
	case .CSV:
		parse_csv(s, text, profile)
	case .OFX:
		parse_ofx(s, text)
	case .CAMT053:
		parse_camt053(s, text)
	case .Unknown:
		stmt_error(s, "format non reconnu")
	}
	return s, statement_ok(s)
}

// parse_text is the same without touching the disk, which is what the tests
// use: every fixture is also exercised as a string so a failure is a parser
// failure and never a file-system one.
parse_text :: proc(
	text: string,
	profile: ^Bank_Profile = nil,
	name := "<texte>",
) -> ^Statement {
	s := new(Statement)
	statement_init(s)
	s.path = strings.clone(name)
	s.encoding = .UTF8
	s.format = detect_format(text)
	switch s.format {
	case .CSV:
		parse_csv(s, text, profile)
	case .OFX:
		parse_ofx(s, text)
	case .CAMT053:
		parse_camt053(s, text)
	case .Unknown:
		stmt_error(s, "format non reconnu")
	}
	return s
}

// ---------------------------------------------------------------------------
// Booking it
// ---------------------------------------------------------------------------

Import_Report :: struct {
	added:       int,
	duplicates:  int,
	categorised: int,
	rows_bad:    int,
	account:     int,
	format:      Import_Format,
	problem:     string, // "" when the book still balances afterwards
}

// dedup_key identifies a row for a bank that does not give its transactions
// ids. Date, amount and normalised label: the three things that are on the
// statement and cannot change between two exports of the same period.
dedup_key :: proc(account: int, t: Raw_Txn, allocator := context.temp_allocator) -> string {
	return fmt.aprintf(
		"%d|%s|%d|%s",
		account,
		date_iso(t.date, context.temp_allocator),
		i64(t.amount),
		label_normalize(t.label, context.temp_allocator),
		allocator = allocator,
	)
}

// statement_ingest books a parsed statement into an account.
//
// De-duplication is by count, not by presence, which matters: two identical
// coffees on the same day are two transactions, and refusing the second
// because it looks like the first loses real money. So the existing rows are
// counted per key, the incoming rows are counted per key, and only the excess
// is added. Re-importing the same file therefore adds nothing, importing an
// overlapping export adds exactly the new rows, and a genuine repeat survives.
//
// A bank that supplies its own ids (OFX's FITID, CAMT's NtryRef) is trusted
// instead: a repeated id is a duplicate whatever the rest of the row says.
statement_ingest :: proc(app: ^App, s: ^Statement, account: int) -> Import_Report {
	rep := Import_Report {
		account  = account,
		format   = s.format,
		rows_bad = s.rows_bad,
	}
	l := &app.led
	if account < 0 || account >= len(l.accounts) {
		rep.problem = "compte inconnu"
		return rep
	}

	// Count what is already in the book for this account.
	have := make(map[string]int, context.temp_allocator)
	for &t in l.txns {
		if t.dead {
			continue
		}
		acct, amount, ok := txn_asset_side(l, &t)
		if !ok || acct != account {
			continue
		}
		raw := Raw_Txn {
			date   = t.date,
			label  = t.label,
			amount = amount,
		}
		have[dedup_key(account, raw)] += 1
	}

	// And what the file is offering.
	want := make(map[string]int, context.temp_allocator)
	for t in s.txns {
		want[dedup_key(account, t)] += 1
	}
	seen := make(map[string]int, context.temp_allocator)

	for t in s.txns {
		if t.ext_id != "" {
			if _, dup := l.by_ext[t.ext_id]; dup {
				rep.duplicates += 1
				continue
			}
		} else {
			k := dedup_key(account, t)
			seen[k] += 1
			if seen[k] <= have[k] {
				rep.duplicates += 1
				continue
			}
		}

		method, _ := label_method(label_normalize(t.label, context.temp_allocator))
		holding := l.unallocated
		ents := [2]Entry{{account, t.amount}, {holding, -t.amount}}
		id, ok := txn_add(
			l,
			{
				date = t.date,
				value = t.value,
				label = t.label,
				method = method,
				ext_id = t.ext_id,
				entries = ents[:],
			},
		)
		if !ok {
			rep.duplicates += 1
			continue
		}
		_ = id
		rep.added += 1
	}

	rep.categorised = apply_rules(l, &app.cat)
	if pb := ledger_check(l); !pb.ok {
		rep.problem = pb.what
	}
	return rep
}

// import_file is the whole path: read, parse, pick the account, book.
//
// The account is chosen by the statement's own IBAN when it has one, which is
// what makes importing into the right account automatic. When it does not,
// the caller's `fallback` is used — the account the user had selected.
import_file :: proc(app: ^App, path: string, fallback: int) -> (rep: Import_Report, ok: bool) {
	profile := profile_for_path(app, path)
	s, good := read_statement_file(path, profile)
	defer {
		statement_destroy(s)
		free(s)
	}
	if !good {
		r := Import_Report {
			format   = s.format,
			rows_bad = s.rows_bad,
			problem  = len(s.errors) > 0 ? strings.clone(s.errors[0]) : "aucune opération lue",
		}
		return r, false
	}

	account := fallback
	if s.iban != "" {
		if idx, found := account_by_iban(&app.led, s.iban); found {
			account = idx
		} else if fallback >= 0 && fallback < len(app.led.accounts) {
			// Remember the IBAN on the account the user imported into, so the
			// next export of the same account lands here without being asked.
			if app.led.accounts[fallback].iban == "" {
				delete(app.led.accounts[fallback].iban)
				app.led.accounts[fallback].iban = strings.clone(s.iban)
			}
		}
	}
	if account < 0 {
		account = account_add(&app.led, "Compte importé", .Asset, s.iban, s.bank)
	}

	// Remember how this file was read, keyed by its header, so the next
	// export from the same bank needs no mapping at all. This is the part of
	// a CSV importer the user notices: getting it right once per bank.
	if s.format == .CSV && s.header != "" {
		profile_remember(app, s)
	}

	rep = statement_ingest(app, s, account)
	// A statement that states its own closing balance hands the
	// reconciliation view its target without the user retyping it.
	if s.has_closing {
		recon_note_statement(app, account, s.closing, s.closing_date)
	}
	return rep, rep.problem == ""
}

// import_mode is `money --import FILE`: the whole pipeline with no window, so
// the importer can be exercised from a script.
import_mode :: proc(args: []string) -> int {
	if len(args) == 0 {
		fmt.eprintln("money: --import needs a file")
		return 2
	}
	app := new(App)
	defer free(app)
	app_init(app)
	defer app_destroy(app)

	acct := account_add(&app.led, "Compte courant", .Asset)
	rep, ok := import_file(app, args[0], acct)
	fmt.printfln(
		"%s: format %s, %d ajoutées, %d doublons, %d catégorisées, %d lignes refusées",
		args[0],
		format_name(rep.format),
		rep.added,
		rep.duplicates,
		rep.categorised,
		rep.rows_bad,
	)
	if rep.problem != "" {
		fmt.eprintfln("  problème: %s", rep.problem)
	}
	fmt.printfln("solde: %s", money_text(app.led.accounts[acct].balance))
	return ok ? 0 : 1
}
