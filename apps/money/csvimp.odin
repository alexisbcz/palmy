// The CSV importer, and the per-bank mapping that makes it bearable.
//
// Every French retail bank exports a CSV and no two of them agree. Across the
// exports this was written against:
//
//   * the delimiter is `;` or `,` or a tab;
//   * the header sits on line 1, or on line 4 after a preamble naming the
//     account and the period, or there is no header at all;
//   * dates are `31/01/2026`, `31/01/26` or `2026-01-31`;
//   * amounts are `-42,10`, `-42.10`, `1 234,56`, `1.234,56` or `(42,10)`;
//   * an amount is one signed column, or two columns — Débit and Crédit —
//     where the debit column holds a positive number that means money out;
//   * the file is UTF-8 or Windows-1252;
//   * the label is one column, or two, or three that have to be joined.
//
// There is no detector that gets all of that right every time, so the
// importer does two things. It guesses, as well as it can, from the header
// names and from what the columns actually contain. And then it **remembers**,
// keyed by the header line, so a bank is configured once and never again.
// That is the whole user experience of importing: the first file takes a
// minute, every file after it takes a click.
package main

import "core:fmt"
import "core:strconv"
import "core:strings"

// Bank_Profile is one bank's column mapping. The zero value means "nothing
// known"; -1 in a column index means "this bank does not have that column".
Bank_Profile :: struct {
	name:        string, // what the user calls this bank
	fingerprint: string, // the normalised header line this profile matches
	delim:       u8,
	skip:        int, // preamble records before the header
	has_header:  bool,
	encoding:    Encoding,
	date_fmt:    Date_Format,
	decimal:     Separator,

	// Column indexes, -1 for absent.
	col_date:    int,
	col_value:   int,
	col_label:   int,
	col_label2:  int, // joined onto the label with a space
	col_label3:  int,
	col_amount:  int, // one signed column
	col_debit:   int, // positive means money out
	col_credit:  int, // positive means money in
	col_balance: int,
	col_ref:     int, // the bank's own reference, used for de-duplication

	// `true` when the signed amount column has money *out* as positive,
	// which two of the exports here do.
	flip:        bool,
	learned:     bool, // saved by the user rather than guessed
}

profile_blank :: proc() -> Bank_Profile {
	return Bank_Profile {
		delim = ';',
		has_header = true,
		encoding = .Auto,
		date_fmt = .Auto,
		decimal = .Auto,
		col_date = -1,
		col_value = -1,
		col_label = -1,
		col_label2 = -1,
		col_label3 = -1,
		col_amount = -1,
		col_debit = -1,
		col_credit = -1,
		col_balance = -1,
		col_ref = -1,
	}
}

profile_complete :: proc(p: Bank_Profile) -> bool {
	has_amount := p.col_amount >= 0 || p.col_debit >= 0 || p.col_credit >= 0
	return p.col_date >= 0 && p.col_label >= 0 && has_amount
}

// ---------------------------------------------------------------------------
// Recognising a header
// ---------------------------------------------------------------------------

Field_Role :: enum {
	None,
	Date,
	Value_Date,
	Label,
	Amount,
	Debit,
	Credit,
	Balance,
	Reference,
}

// HEADER_WORDS maps a normalised header cell to the role it plays. Longer
// phrases come first, because `date valeur` must not be taken for `date`.
//
// `exact` means the whole cell has to equal the word: `solde` is a balance,
// but `montant du solde` is not, and a substring test would get that wrong.
HEADER_WORDS := [?]struct {
	word:  string,
	role:  Field_Role,
	exact: bool,
} {
	{"date de valeur", .Value_Date, false},
	{"date valeur", .Value_Date, false},
	{"valeur", .Value_Date, true},
	{"date de l operation", .Date, false},
	{"date operation", .Date, false},
	{"date de comptabilisation", .Date, false},
	{"date comptable", .Date, false},
	{"date comptabilisation", .Date, false},
	{"date", .Date, true},
	{"dateop", .Date, true},
	{"booking date", .Date, false},
	{"libelle operation", .Label, false},
	{"libelle simplifie", .Label, false},
	{"nature de l operation", .Label, false},
	{"libelle", .Label, false},
	{"intitule", .Label, false},
	{"description", .Label, false},
	{"designation", .Label, false},
	{"motif", .Label, false},
	{"nature", .Label, true},
	{"operation", .Label, true},
	{"informations complementaires", .Label, false},
	{"montant de l operation", .Amount, false},
	{"montant en euros", .Amount, false},
	{"montant eur", .Amount, false},
	{"montant euro", .Amount, false},
	{"montant", .Amount, true},
	{"amount", .Amount, false},
	{"debit euros", .Debit, false},
	{"montant debit", .Debit, false},
	{"debit", .Debit, true},
	{"credit euros", .Credit, false},
	{"montant credit", .Credit, false},
	{"credit", .Credit, true},
	{"solde", .Balance, true},
	{"solde apres operation", .Balance, false},
	{"balance", .Balance, true},
	{"reference", .Reference, false},
	{"numero d operation", .Reference, false},
	{"id", .Reference, true},
}

header_role :: proc(cell: string) -> Field_Role {
	h := header_norm(cell, context.temp_allocator)
	if h == "" {
		return .None
	}
	for e in HEADER_WORDS {
		if e.exact {
			if h == e.word {
				return e.role
			}
		} else if strings.contains(h, e.word) {
			return e.role
		}
	}
	return .None
}

// header_score counts how many cells in a row look like column headings. A
// real header scores two or more; a data row scores zero, because `31/01/2026`
// is not the name of anything.
header_score :: proc(fields: []string) -> int {
	n := 0
	for f in fields {
		if header_role(f) != .None {
			n += 1
		}
	}
	return n
}

// ---------------------------------------------------------------------------
// Guessing a profile
// ---------------------------------------------------------------------------

// csv_guess_profile works out how to read a file it has never seen.
//
// It finds the header by scanning the first records for the one that looks
// most like column names — that is also how the preamble gets skipped, with
// no rule about how many lines a preamble has. Then it assigns roles from the
// header names, and finally it *checks the guess against the data*: a column
// claimed to be a date has to parse as a date in the rows below it, and an
// amount column has to parse as a number. A header that lies, or a file with
// no header at all, is resolved by content.
csv_guess_profile :: proc(text: string, name := "") -> (prof: Bank_Profile, ok: bool) {
	prof = profile_blank()
	prof.delim = csv_sniff_delimiter(text)
	prof.name = name

	rows := csv_rows(text, prof.delim, context.temp_allocator)
	if len(rows) == 0 {
		return prof, false
	}

	// The header is the best-scoring row among the first few, and it has to
	// have at least two recognisable names: one coincidence is not a header.
	head := -1
	best := 1
	limit := min(len(rows), 25)
	for i in 0 ..< limit {
		sc := header_score(rows[i].fields)
		if sc > best {
			best = sc
			head = i
		}
	}

	if head >= 0 {
		prof.has_header = true
		prof.skip = head
		assign_roles(&prof, rows[head].fields)
	} else {
		prof.has_header = false
		prof.skip = 0
	}

	// Verify, and fill in what the header did not say, from the data.
	data_start := prof.has_header ? prof.skip + 1 : 0
	verify_profile(&prof, rows[data_start:])
	return prof, profile_complete(prof)
}

@(private = "file")
assign_roles :: proc(prof: ^Bank_Profile, header: []string) {
	for cell, i in header {
		switch header_role(cell) {
		case .Date:
			if prof.col_date < 0 {
				prof.col_date = i
			}
		case .Value_Date:
			if prof.col_value < 0 {
				prof.col_value = i
			}
		case .Label:
			switch {
			case prof.col_label < 0:
				prof.col_label = i
			case prof.col_label2 < 0:
				prof.col_label2 = i
			case prof.col_label3 < 0:
				prof.col_label3 = i
			}
		case .Amount:
			if prof.col_amount < 0 {
				prof.col_amount = i
			}
		case .Debit:
			if prof.col_debit < 0 {
				prof.col_debit = i
			}
		case .Credit:
			if prof.col_credit < 0 {
				prof.col_credit = i
			}
		case .Balance:
			if prof.col_balance < 0 {
				prof.col_balance = i
			}
		case .Reference:
			if prof.col_ref < 0 {
				prof.col_ref = i
			}
		case .None:
		}
	}
}

// verify_profile tests the guess against up to 50 data rows and repairs it.
//
// This is the part that makes a headerless file work and a mislabelled header
// harmless: a column either parses as dates or it does not, and the widest
// text column is the label whatever the header called it.
@(private = "file")
verify_profile :: proc(prof: ^Bank_Profile, rows: []Csv_Row) {
	if len(rows) == 0 {
		return
	}
	ncols := 0
	for r in rows {
		ncols = max(ncols, len(r.fields))
	}
	if ncols == 0 {
		return
	}
	sample := min(len(rows), 50)

	dates := make([]int, ncols, context.temp_allocator)
	nums := make([]int, ncols, context.temp_allocator)
	texts := make([]int, ncols, context.temp_allocator)
	widths := make([]int, ncols, context.temp_allocator)
	dmy := 0
	ymd := 0
	comma := 0
	dot := 0

	for r in rows[:sample] {
		for f, c in r.fields {
			t := strings.trim_space(f)
			if t == "" {
				continue
			}
			if _, ok := date_parse(t); ok {
				dates[c] += 1
				// Four leading digits mean the year came first.
				lead4 := len(t) >= 4 &&
					t[0] >= '0' &&
					t[0] <= '9' &&
					t[1] >= '0' &&
					t[1] <= '9' &&
					t[2] >= '0' &&
					t[2] <= '9' &&
					t[3] >= '0' &&
					t[3] <= '9'
				if lead4 {
					ymd += 1
				} else {
					dmy += 1
				}
				continue
			}
			if _, ok := money_parse(t); ok {
				nums[c] += 1
				// Which decimal separator does this file use? A cell with a
				// comma two places from the end is the French form.
				if i := strings.last_index_byte(t, ','); i >= 0 && len(t) - i <= 3 {
					comma += 1
				} else if i := strings.last_index_byte(t, '.'); i >= 0 && len(t) - i <= 3 {
					dot += 1
				}
				continue
			}
			texts[c] += 1
			widths[c] += len(t)
		}
	}

	prof.date_fmt = ymd > dmy ? .YMD : .DMY
	if comma > dot {
		prof.decimal = .Comma
	} else if dot > comma {
		prof.decimal = .Dot
	} else {
		prof.decimal = .Auto
	}

	// A date column must actually hold dates.
	if prof.col_date >= 0 && (prof.col_date >= ncols || dates[prof.col_date] * 2 < sample) {
		prof.col_date = -1
	}
	if prof.col_date < 0 {
		for c in 0 ..< ncols {
			if dates[c] * 2 >= sample {
				prof.col_date = c
				break
			}
		}
	}
	if prof.col_value == prof.col_date {
		prof.col_value = -1
	}

	// The label is the widest text column.
	if prof.col_label >= 0 && (prof.col_label >= ncols || texts[prof.col_label] == 0) {
		prof.col_label = -1
	}
	if prof.col_label < 0 {
		bestw := 0
		for c in 0 ..< ncols {
			if texts[c] > 0 && widths[c] > bestw {
				bestw = widths[c]
				prof.col_label = c
			}
		}
	}

	// An amount column must hold numbers. When the header named neither an
	// amount nor a debit/credit pair, take the last numeric column that is
	// not the date — and if two numeric columns are left, the pair is
	// debit/credit, because a signed-amount export has exactly one.
	check :: proc(idx: ^int, nums: []int, ncols, sample: int) {
		if idx^ >= 0 && (idx^ >= ncols || nums[idx^] == 0) {
			idx^ = -1
		}
	}
	check(&prof.col_amount, nums, ncols, sample)
	check(&prof.col_debit, nums, ncols, sample)
	check(&prof.col_credit, nums, ncols, sample)
	check(&prof.col_balance, nums, ncols, sample)

	if prof.col_amount < 0 && prof.col_debit < 0 && prof.col_credit < 0 {
		numeric := make([dynamic]int, 0, ncols, context.temp_allocator)
		for c in 0 ..< ncols {
			if c == prof.col_date || c == prof.col_value || c == prof.col_label {
				continue
			}
			if nums[c] > 0 {
				append(&numeric, c)
			}
		}
		switch len(numeric) {
		case 0:
		case 1:
			prof.col_amount = numeric[0]
		case 2:
			prof.col_debit = numeric[0]
			prof.col_credit = numeric[1]
		case:
			// Three or more: the last is the running balance, the two before
			// it are debit and credit.
			prof.col_debit = numeric[len(numeric) - 3]
			prof.col_credit = numeric[len(numeric) - 2]
			prof.col_balance = numeric[len(numeric) - 1]
		}
	}
	if prof.col_label == prof.col_amount {
		prof.col_label = -1
	}
}

// ---------------------------------------------------------------------------
// Parsing with a profile
// ---------------------------------------------------------------------------

@(private = "file")
cell :: proc(fields: []string, idx: int) -> string {
	if idx < 0 || idx >= len(fields) {
		return ""
	}
	return strings.trim_space(fields[idx])
}

// parse_csv reads a statement. With no profile it guesses one; with a profile
// it uses it exactly, which is what makes a remembered mapping authoritative.
//
// A row it cannot read is counted and described, and the rest of the file is
// still imported. That is the right behaviour for a bank export: one
// malformed line in nine hundred should not cost the user the other 899, and
// a silent skip would be worse than either.
parse_csv :: proc(s: ^Statement, text: string, profile: ^Bank_Profile = nil) {
	prof: Bank_Profile
	if profile != nil && profile_complete(profile^) {
		prof = profile^
		s.bank = strings.clone(prof.name)
	} else {
		guessed, ok := csv_guess_profile(text)
		prof = guessed
		if !ok {
			stmt_error(
				s,
				"colonnes illisibles: date=%d libellé=%d montant=%d débit=%d crédit=%d",
				prof.col_date,
				prof.col_label,
				prof.col_amount,
				prof.col_debit,
				prof.col_credit,
			)
			return
		}
	}

	rows := csv_rows(text, prof.delim, context.temp_allocator)
	if len(rows) == 0 {
		stmt_error(s, "fichier vide")
		return
	}
	start := prof.has_header ? prof.skip + 1 : prof.skip
	if start >= len(rows) {
		stmt_error(s, "le fichier s'arrête après l'en-tête")
		return
	}
	if prof.has_header && prof.skip < len(rows) {
		s.header = strings.clone(fingerprint_of(rows[prof.skip].fields))
	}

	// A preamble often names the account. Worth reading: it is how a CSV
	// lands in the right account without being asked.
	if prof.skip > 0 {
		for i in 0 ..< prof.skip {
			for f in rows[i].fields {
				scan_iban_into(s, f)
			}
		}
	}

	ncols_expected := prof.has_header ? len(rows[prof.skip].fields) : 0

	for r in rows[start:] {
		s.rows_seen += 1
		// A truncated file ends in a row with too few columns. Refuse the
		// row, name the line, keep going.
		need := prof.col_date + 1
		need = max(need, prof.col_label + 1)
		need = max(need, prof.col_amount + 1)
		need = max(need, prof.col_debit + 1)
		need = max(need, prof.col_credit + 1)
		if len(r.fields) < need {
			s.rows_bad += 1
			stmt_warn(
				s,
				"ligne %d: %d colonnes au lieu de %d — ignorée",
				r.line,
				len(r.fields),
				max(need, ncols_expected),
			)
			continue
		}

		date_text_cell := cell(r.fields, prof.col_date)
		d, dok := date_parse(date_text_cell, prof.date_fmt)
		if !dok {
			s.rows_bad += 1
			stmt_warn(s, "ligne %d: date illisible «%s» — ignorée", r.line, date_text_cell)
			continue
		}

		amount: Cents
		aok := false
		if prof.col_amount >= 0 {
			amount, aok = money_parse(cell(r.fields, prof.col_amount), prof.decimal)
			if aok && prof.flip {
				amount = -amount
			}
		} else {
			deb, dok2 := money_parse(cell(r.fields, prof.col_debit), prof.decimal)
			cre, cok := money_parse(cell(r.fields, prof.col_credit), prof.decimal)
			switch {
			case dok2 && cok && deb != 0 && cre != 0:
				s.rows_bad += 1
				stmt_warn(s, "ligne %d: débit et crédit tous les deux remplis — ignorée", r.line)
				continue
			case dok2 && deb != 0:
				// The debit column holds a positive number meaning money
				// out. A bank that already signs it is handled too: the
				// absolute value then the sign, so `-42,10` in a Débit
				// column is still −42,10 €.
				amount = -money_abs(deb)
				aok = true
			case cok && cre != 0:
				amount = money_abs(cre)
				aok = true
			case dok2 || cok:
				amount = 0
				aok = true // a genuine zero-amount row; the bank wrote it
			}
		}
		if !aok {
			s.rows_bad += 1
			stmt_warn(s, "ligne %d: montant illisible — ignorée", r.line)
			continue
		}

		lbl := cell(r.fields, prof.col_label)
		if prof.col_label2 >= 0 {
			if extra := cell(r.fields, prof.col_label2); extra != "" {
				lbl = strings.concatenate({lbl, " ", extra}, context.temp_allocator)
			}
		}
		if prof.col_label3 >= 0 {
			if extra := cell(r.fields, prof.col_label3); extra != "" {
				lbl = strings.concatenate({lbl, " ", extra}, context.temp_allocator)
			}
		}
		lbl = strings.trim_space(lbl)
		if lbl == "" {
			lbl = "(sans libellé)"
		}

		t := Raw_Txn {
			date   = d,
			label  = strings.clone(lbl),
			amount = amount,
			line   = r.line,
		}
		if prof.col_value >= 0 {
			if v, ok := date_parse(cell(r.fields, prof.col_value), prof.date_fmt); ok {
				t.value = v
			}
		}
		if prof.col_balance >= 0 {
			if b, ok := money_parse(cell(r.fields, prof.col_balance), prof.decimal); ok {
				t.balance = b
				t.has_balance = true
				// The last row's running balance is the statement's closing
				// balance, which the reconciliation view can then check.
				s.closing = b
				s.has_closing = true
				s.closing_date = d
			}
		}
		if prof.col_ref >= 0 {
			if ref := cell(r.fields, prof.col_ref); ref != "" {
				t.ext_id = fmt.aprintf("csv:%s:%s", s.header, ref)
			}
		}
		append(&s.txns, t)
	}

	if len(s.txns) == 0 && s.rows_bad > 0 {
		stmt_error(s, "aucune ligne lisible (%d refusées)", s.rows_bad)
	} else if len(s.txns) == 0 {
		stmt_error(s, "aucune opération trouvée")
	}

	// A CSV with a running balance column states its closing balance on the
	// *last* row by date, not by position: some banks export newest first.
	if s.has_closing {
		best := 0
		for t, i in s.txns {
			if t.has_balance && !date_less(t.date, s.txns[best].date) {
				best = i
			}
		}
		if s.txns[best].has_balance {
			s.closing = s.txns[best].balance
			s.closing_date = s.txns[best].date
		}
	}
}

// fingerprint_of is the mapping key: the normalised header cells joined with
// `|`. Two exports from the same bank have the same fingerprint even if the
// encoding or the row count differs, and two different banks essentially
// never collide.
fingerprint_of :: proc(fields: []string, allocator := context.temp_allocator) -> string {
	parts := make([dynamic]string, 0, len(fields), context.temp_allocator)
	for f in fields {
		append(&parts, header_norm(f, context.temp_allocator))
	}
	return strings.join(parts[:], "|", allocator)
}

// scan_iban_into pulls an IBAN out of a preamble line. Only a string that
// passes the mod-97 check counts, so a reference number that happens to start
// with two letters is not mistaken for an account.
scan_iban_into :: proc(s: ^Statement, field: string) {
	if s.iban != "" {
		return
	}
	cleaned := iban_normalize(field, context.temp_allocator)
	// Scan every substring that starts with two letters followed by two
	// digits, which is the only shape an IBAN can have.
	for i := 0; i + 15 <= len(cleaned); i += 1 {
		if !(cleaned[i] >= 'A' && cleaned[i] <= 'Z') {
			continue
		}
		if !(cleaned[i + 1] >= 'A' && cleaned[i + 1] <= 'Z') {
			continue
		}
		if !(cleaned[i + 2] >= '0' && cleaned[i + 2] <= '9') {
			continue
		}
		want, known := iban_country_length(cleaned[i:i + 2])
		if !known || i + want > len(cleaned) {
			continue
		}
		cand := cleaned[i:i + want]
		if iban_valid(cand) {
			s.iban = strings.clone(cand)
			return
		}
	}
}

_ :: strconv
