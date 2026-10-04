// CAMT.053, the ISO 20022 bank-to-customer statement.
//
// This is what a European bank hands you when it has moved past CSV, and it
// is real XML — namespaced, attributed, nested four or five levels deep:
//
//     <Ntry>
//       <Amt Ccy="EUR">42.10</Amt>
//       <CdtDbtInd>DBIT</CdtDbtInd>
//       <BookgDt><Dt>2026-09-21</Dt></BookgDt>
//       <NtryDtls><TxDtls><RmtInf><Ustrd>CB CARREFOUR 2109</Ustrd>…
//
// Two things about it are easy to get wrong and both cost money. The sign is
// not in the amount — `<Amt>` is always positive and `<CdtDbtInd>` says DBIT
// or CRDT, so an importer that ignores the indicator books every debit as
// income. And a balance carries the same indicator, so an overdrawn closing
// balance is `<Amt>120.00</Amt><CdtDbtInd>DBIT</CdtDbtInd>`, meaning −120 €.
//
// The parser is a small event scanner rather than a DOM: elements are matched
// by local name with the namespace prefix stripped, because banks differ on
// whether they use a default namespace or a prefix and no consumer should
// care.
package main

import "core:strings"

Xml_Kind :: enum {
	Open,
	Close,
	Text,
	Self,
}

Xml_Event :: struct {
	kind: Xml_Kind,
	name: string, // local name, namespace prefix removed
	text: string, // Text only
	attr: string, // the raw attribute text of an Open/Self tag
}

// xml_scan tokenises a document. It is not a validating parser: a CAMT file
// is machine-written and well-formed, and what matters here is that a
// malformed one produces a short event list rather than a crash, so the
// importer can say "truncated" and stop.
xml_scan :: proc(text: string, allocator := context.temp_allocator) -> []Xml_Event {
	out := make([dynamic]Xml_Event, allocator)
	i := 0
	for i < len(text) {
		lt := strings.index_byte(text[i:], '<')
		if lt < 0 {
			break
		}
		// Text before the tag.
		if lt > 0 {
			t := strings.trim_space(text[i:i + lt])
			if t != "" {
				append(&out, Xml_Event{kind = .Text, text = t})
			}
		}
		i += lt
		if strings.has_prefix(text[i:], "<!--") {
			end := strings.index(text[i:], "-->")
			if end < 0 {
				break
			}
			i += end + 3
			continue
		}
		if strings.has_prefix(text[i:], "<![CDATA[") {
			end := strings.index(text[i:], "]]>")
			if end < 0 {
				break
			}
			body := text[i + 9:i + end]
			if strings.trim_space(body) != "" {
				append(&out, Xml_Event{kind = .Text, text = body})
			}
			i += end + 3
			continue
		}
		gt := strings.index_byte(text[i:], '>')
		if gt < 0 {
			break // truncated mid-tag
		}
		raw := text[i + 1:i + gt]
		i += gt + 1
		if raw == "" {
			continue
		}
		if raw[0] == '?' || raw[0] == '!' {
			continue
		}
		closing := raw[0] == '/'
		if closing {
			raw = raw[1:]
		}
		self := strings.has_suffix(raw, "/")
		if self {
			raw = raw[:len(raw) - 1]
		}
		name := strings.trim_space(raw)
		attrs := ""
		if sp := strings.index_any(name, " \t\r\n"); sp > 0 {
			attrs = strings.trim_space(name[sp:])
			name = name[:sp]
		}
		// Strip the namespace prefix: `ns2:Ntry` and `Ntry` are the same
		// element, and a bank may use either.
		if c := strings.last_index_byte(name, ':'); c >= 0 {
			name = name[c + 1:]
		}
		if name == "" {
			continue
		}
		kind: Xml_Kind = closing ? .Close : (self ? .Self : .Open)
		append(&out, Xml_Event{kind = kind, name = name, attr = attrs})
	}
	return out[:]
}

// xml_attr reads one attribute out of a tag's raw attribute text.
xml_attr :: proc(attrs: string, key: string) -> (value: string, ok: bool) {
	rest := attrs
	for {
		eq := strings.index_byte(rest, '=')
		if eq < 0 {
			return "", false
		}
		name := strings.trim_space(rest[:eq])
		if c := strings.last_index_byte(name, ':'); c >= 0 {
			name = name[c + 1:]
		}
		rest = rest[eq + 1:]
		rest = strings.trim_left_space(rest)
		if rest == "" {
			return "", false
		}
		q := rest[0]
		if q != '"' && q != '\'' {
			return "", false
		}
		end := strings.index_byte(rest[1:], q)
		if end < 0 {
			return "", false
		}
		val := rest[1:1 + end]
		rest = rest[end + 2:]
		if name == key {
			return val, true
		}
	}
}

// xml_unescape handles the five predefined entities plus numeric references,
// because a remittance line can legitimately contain `&` and `<`.
xml_unescape :: proc(s: string, allocator := context.temp_allocator) -> string {
	if !strings.contains(s, "&") {
		return strings.clone(s, allocator)
	}
	b := strings.builder_make(allocator)
	i := 0
	for i < len(s) {
		if s[i] != '&' {
			strings.write_byte(&b, s[i])
			i += 1
			continue
		}
		semi := strings.index_byte(s[i:], ';')
		if semi < 0 || semi > 10 {
			strings.write_byte(&b, s[i])
			i += 1
			continue
		}
		ent := s[i + 1:i + semi]
		switch {
		case ent == "amp":
			strings.write_byte(&b, '&')
		case ent == "lt":
			strings.write_byte(&b, '<')
		case ent == "gt":
			strings.write_byte(&b, '>')
		case ent == "quot":
			strings.write_byte(&b, '"')
		case ent == "apos":
			strings.write_byte(&b, '\'')
		case len(ent) > 1 && ent[0] == '#':
			cp := 0
			digits := ent[1:]
			hex := len(digits) > 0 && (digits[0] == 'x' || digits[0] == 'X')
			if hex {
				digits = digits[1:]
			}
			good := len(digits) > 0
			for k in 0 ..< len(digits) {
				c := digits[k]
				switch {
				case c >= '0' && c <= '9':
					cp = cp * (hex ? 16 : 10) + int(c - '0')
				case hex && c >= 'a' && c <= 'f':
					cp = cp * 16 + int(c-'a') + 10
				case hex && c >= 'A' && c <= 'F':
					cp = cp * 16 + int(c-'A') + 10
				case:
					good = false
				}
			}
			if good && cp > 0 && cp <= 0x10FFFF {
				strings.write_rune(&b, rune(cp))
			} else {
				strings.write_string(&b, s[i:i + semi + 1])
			}
		case:
			strings.write_string(&b, s[i:i + semi + 1])
		}
		i += semi + 1
	}
	return strings.to_string(b)
}

// ---------------------------------------------------------------------------
// Statement extraction
// ---------------------------------------------------------------------------

// A path tracker: the scanner is flat, so "am I inside <Bal>" is answered by
// keeping the open element names on a stack.
@(private = "file")
Camt_State :: struct {
	stack: [dynamic]string,
}

@(private = "file")
in_element :: proc(st: ^Camt_State, name: string) -> bool {
	for s in st.stack {
		if s == name {
			return true
		}
	}
	return false
}

// parse_camt053 reads the account, the closing balance and every entry.
//
// The structure walked is Document → BkToCstmrStmt → Stmt → Ntry, and inside
// an entry the label is assembled from the remittance information, the
// creditor or debtor name and the additional entry information, in that order
// of preference — which is the order that produces something a human
// recognises.
parse_camt053 :: proc(s: ^Statement, text: string) {
	events := xml_scan(text)
	if len(events) == 0 {
		stmt_error(s, "CAMT: document vide ou illisible")
		return
	}

	st := Camt_State {
		stack = make([dynamic]string, context.temp_allocator),
	}

	// Per-entry accumulators.
	in_entry := false
	entry_amt: Cents
	entry_amt_ok := false
	entry_dbit := false
	entry_ind_ok := false
	ustrd := make([dynamic]string, context.temp_allocator)
	name_cd := ""
	name_dbt := ""
	addtl := ""
	ref := ""
	booking: Date
	booking_ok := false
	value_dt: Date
	value_ok := false

	// Balance accumulators.
	in_bal := false
	bal_code := ""
	bal_amt: Cents
	bal_amt_ok := false
	bal_dbit := false
	bal_date: Date
	bal_date_ok := false

	last_open := ""
	last_attr := ""
	saw_root := false

	reset_entry :: proc(
		ustrd: ^[dynamic]string,
		name_cd, name_dbt, addtl, ref: ^string,
		amt_ok, ind_ok, bok, vok: ^bool,
	) {
		clear(ustrd)
		name_cd^ = ""
		name_dbt^ = ""
		addtl^ = ""
		ref^ = ""
		amt_ok^ = false
		ind_ok^ = false
		bok^ = false
		vok^ = false
	}

	for ev in events {
		switch ev.kind {
		case .Open, .Self:
			last_open = ev.name
			last_attr = ev.attr
			switch ev.name {
			case "Document", "BkToCstmrStmt":
				saw_root = true
			case "Ntry":
				in_entry = true
				reset_entry(
					&ustrd,
					&name_cd,
					&name_dbt,
					&addtl,
					&ref,
					&entry_amt_ok,
					&entry_ind_ok,
					&booking_ok,
					&value_ok,
				)
				s.rows_seen += 1
			case "Bal":
				if !in_entry {
					in_bal = true
					bal_code = ""
					bal_amt_ok = false
					bal_dbit = false
					bal_date_ok = false
				}
			}
			if ev.kind == .Open {
				append(&st.stack, ev.name)
			}

		case .Close:
			switch ev.name {
			case "Ntry":
				if in_entry {
					finish_entry(
						s,
						ustrd[:],
						name_cd,
						name_dbt,
						addtl,
						ref,
						entry_amt,
						entry_amt_ok,
						entry_dbit,
						entry_ind_ok,
						booking,
						booking_ok,
						value_dt,
						value_ok,
					)
				}
				in_entry = false
			case "Bal":
				if in_bal {
					// CLBD is the closing booked balance, which is the figure
					// printed at the bottom of a statement. PRCD is the
					// previous one and OPBD the opening; neither is what a
					// reconciliation compares against.
					if bal_code == "CLBD" && bal_amt_ok {
						s.closing = bal_dbit ? -money_abs(bal_amt) : money_abs(bal_amt)
						s.has_closing = true
						if bal_date_ok {
							s.closing_date = bal_date
						}
					}
					in_bal = false
				}
			}
			// Unwind to the matching open.
			for k := len(st.stack) - 1; k >= 0; k -= 1 {
				if st.stack[k] == ev.name {
					resize(&st.stack, k)
					break
				}
			}

		case .Text:
			t := strings.trim_space(ev.text)
			if t == "" {
				continue
			}
			switch last_open {
			case "IBAN":
				if s.iban == "" && !in_entry && iban_valid(t) {
					s.iban = strings.clone(iban_normalize(t, context.temp_allocator))
				}
			case "Othr", "Id":
				// <Acct><Id><Othr><Id> is the account number when there is
				// no IBAN. Only accept it at the account level.
				if s.acct_id == "" && in_element(&st, "Acct") && !in_entry {
					s.acct_id = strings.clone(t)
				}
			case "Ccy":
				if !in_entry {
					s.currency = t
				}
			case "Amt":
				v, ok := money_parse(t, .Dot)
				if ok {
					if in_entry {
						entry_amt = v
						entry_amt_ok = true
					} else if in_bal {
						bal_amt = v
						bal_amt_ok = true
					}
				}
			case "CdtDbtInd":
				dbit := t == "DBIT"
				if in_entry {
					entry_dbit = dbit
					entry_ind_ok = true
				} else if in_bal {
					bal_dbit = dbit
				}
			case "Cd":
				if in_bal && in_element(&st, "Tp") {
					bal_code = t
				}
			case "Dt", "DtTm":
				if d, ok := date_parse(t); ok {
					switch {
					case in_entry && in_element(&st, "BookgDt"):
						booking = d
						booking_ok = true
					case in_entry && in_element(&st, "ValDt"):
						value_dt = d
						value_ok = true
					case in_bal:
						bal_date = d
						bal_date_ok = true
					}
				}
			case "Ustrd":
				if in_entry {
					append(&ustrd, xml_unescape(t, context.temp_allocator))
				}
			case "Nm":
				if in_entry {
					if in_element(&st, "Cdtr") && name_cd == "" {
						name_cd = xml_unescape(t, context.temp_allocator)
					} else if in_element(&st, "Dbtr") && name_dbt == "" {
						name_dbt = xml_unescape(t, context.temp_allocator)
					}
				}
			case "AddtlNtryInf":
				if in_entry {
					addtl = xml_unescape(t, context.temp_allocator)
				}
			case "NtryRef", "AcctSvcrRef", "EndToEndId":
				if in_entry && ref == "" {
					ref = t
				}
			}
			// The amount's currency lives in an attribute, not an element.
			if last_open == "Amt" && !in_entry && !in_bal {
				if ccy, ok := xml_attr(last_attr, "Ccy"); ok {
					s.currency = ccy
				}
			}
		}
	}

	if !saw_root {
		stmt_error(s, "CAMT: ni <Document> ni <BkToCstmrStmt>")
		return
	}
	if len(s.txns) == 0 {
		if s.rows_bad > 0 {
			stmt_error(s, "CAMT: aucune écriture lisible (%d refusées)", s.rows_bad)
		} else {
			stmt_error(s, "CAMT: aucune écriture")
		}
	}
}

// finish_entry turns one accumulated `<Ntry>` into a row, or explains why it
// cannot. The sign comes from CdtDbtInd and nowhere else: an entry without
// one is refused rather than guessed, because guessing it wrong inverts a
// transaction.
@(private = "file")
finish_entry :: proc(
	s: ^Statement,
	ustrd: []string,
	name_cd, name_dbt, addtl, ref: string,
	amount: Cents,
	amount_ok: bool,
	dbit: bool,
	ind_ok: bool,
	booking: Date,
	booking_ok: bool,
	value: Date,
	value_ok: bool,
) {
	if !amount_ok {
		s.rows_bad += 1
		stmt_warn(s, "CAMT: écriture sans <Amt> — ignorée")
		return
	}
	if !ind_ok {
		s.rows_bad += 1
		stmt_warn(s, "CAMT: écriture sans <CdtDbtInd> — ignorée")
		return
	}
	if !booking_ok {
		s.rows_bad += 1
		stmt_warn(s, "CAMT: écriture sans date de comptabilisation — ignorée")
		return
	}

	label := ""
	if len(ustrd) > 0 {
		label = strings.join(ustrd, " ", context.temp_allocator)
	}
	if label == "" {
		label = dbit ? name_cd : name_dbt
	}
	if label == "" {
		label = name_cd != "" ? name_cd : name_dbt
	}
	if label == "" {
		label = addtl
	}
	if strings.trim_space(label) == "" {
		label = "(sans libellé)"
	}

	t := Raw_Txn {
		date   = booking,
		label  = strings.clone(strings.trim_space(label)),
		amount = dbit ? -money_abs(amount) : money_abs(amount),
	}
	if value_ok {
		t.value = value
	}
	if ref != "" {
		t.ext_id = strings.concatenate({"camt:", s.iban != "" ? s.iban : s.acct_id, ":", ref})
	}
	append(&s.txns, t)
}
