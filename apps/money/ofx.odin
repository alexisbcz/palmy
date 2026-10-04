// OFX and QFX, which are not XML and must not be parsed as if they were.
//
// OFX 1.x is SGML. Its leaf elements have no closing tag:
//
//     <STMTTRN>
//     <TRNTYPE>DEBIT
//     <DTPOSTED>20260921120000[-5:EST]
//     <TRNAMT>-42.10
//     <FITID>2026092100042
//     <NAME>CB CARREFOUR 2109
//     </STMTTRN>
//
// `<TRNTYPE>` is never closed; it ends where the next tag begins. A strict XML
// parser rejects the whole document — which is the single most common reason
// an import of a perfectly valid QFX fails in other software — and an XML
// parser made lenient enough to accept it usually mis-nests the aggregates.
//
// So this is a real SGML-ish scanner rather than XML with the checks turned
// off. The rule it implements is OFX's own: a tag with text after it is a
// leaf, and the text runs to the next `<`; a tag with another tag after it is
// an aggregate and stays open until its matching close tag. That one rule
// handles both OFX 1.x SGML and OFX 2.x XML, so the same code reads both, and
// the XML form's redundant `</TRNTYPE>` closes an element that is already
// closed and is simply ignored.
//
// The header above the first `<OFX>` is `KEY:VALUE` lines, not markup, and
// carries the character set — which is how a Windows-1252 OFX announces
// itself.
package main

import "core:strings"

Ofx_Node :: struct {
	tag:    string, // upper-cased
	value:  string, // leaf text, "" for an aggregate
	parent: int,
	depth:  int,
}

Ofx_Doc :: struct {
	nodes:   [dynamic]Ofx_Node,
	headers: map[string]string, // the KEY:VALUE preamble
	xml:     bool, // OFX 2.x
}

ofx_destroy :: proc(d: ^Ofx_Doc) {
	delete(d.nodes)
	delete(d.headers)
}

// ofx_parse_doc scans the document into a flat node list with parent links,
// which is all any consumer here needs and avoids building a tree of
// allocations. Strings are slices into the caller's text and are not copied.
ofx_parse_doc :: proc(text: string, allocator := context.temp_allocator) -> Ofx_Doc {
	d := Ofx_Doc {
		nodes   = make([dynamic]Ofx_Node, allocator),
		headers = make(map[string]string, allocator),
	}

	body := text
	// The preamble: either `OFXHEADER:100` lines (1.x) or an `<?OFX ... ?>`
	// processing instruction (2.x).
	if start := strings.index_byte(text, '<'); start > 0 {
		head := text[:start]
		for line in strings.split_lines(head, context.temp_allocator) {
			l := strings.trim_space(line)
			if l == "" {
				continue
			}
			if c := strings.index_byte(l, ':'); c > 0 {
				k := strings.to_upper(strings.trim_space(l[:c]), allocator)
				v := strings.trim_space(l[c + 1:])
				d.headers[k] = v
			}
		}
		body = text[start:]
	}

	stack := make([dynamic]int, context.temp_allocator)
	i := 0
	for i < len(body) {
		lt := strings.index_byte(body[i:], '<')
		if lt < 0 {
			break
		}
		i += lt
		gt := strings.index_byte(body[i:], '>')
		if gt < 0 {
			break
		}
		raw := body[i + 1:i + gt]
		i += gt + 1

		if raw == "" {
			continue
		}
		// `<?xml ... ?>`, `<!-- -->`, `<!DOCTYPE ...>`: not elements.
		if raw[0] == '?' {
			if strings.contains(strings.to_upper(raw, context.temp_allocator), "XML") {
				d.xml = true
			}
			continue
		}
		if raw[0] == '!' {
			continue
		}

		if raw[0] == '/' {
			// A close tag. Unwind to it; an unmatched close is ignored rather
			// than fatal, because an OFX file from a small bank will have one.
			name := strings.to_upper(strings.trim_space(raw[1:]), allocator)
			for k := len(stack) - 1; k >= 0; k -= 1 {
				if d.nodes[stack[k]].tag == name {
					resize(&stack, k)
					break
				}
			}
			continue
		}

		// An open tag. Strip any attributes — OFX has none that matter here.
		name := raw
		if sp := strings.index_any(name, " \t\r\n"); sp > 0 {
			name = name[:sp]
		}
		self_closing := strings.has_suffix(name, "/")
		if self_closing {
			name = name[:len(name) - 1]
		}
		tag := strings.to_upper(strings.trim_space(name), allocator)
		if tag == "" {
			continue
		}

		// The text between here and the next `<` is this element's value.
		// Empty means it is an aggregate.
		next := strings.index_byte(body[i:], '<')
		value := next < 0 ? body[i:] : body[i:i + next]
		value = strings.trim_space(value)

		parent := len(stack) > 0 ? stack[len(stack) - 1] : -1
		idx := len(d.nodes)
		append(&d.nodes, Ofx_Node{tag = tag, value = value, parent = parent, depth = len(stack)})
		if value == "" && !self_closing {
			append(&stack, idx)
		}
	}
	return d
}

// ofx_value finds a descendant's value inside one aggregate.
//
// The subtree is a contiguous run: every node after `parent` with a greater
// depth, ending at the first node that is back at the parent's level. So the
// `<ACCTID>` found is the one inside *this* `<BANKACCTFROM>` and never one
// further down the document, which is what matters in a file holding several
// accounts.
ofx_value :: proc(d: ^Ofx_Doc, parent: int, tag: string) -> (value: string, ok: bool) {
	if parent < 0 || parent >= len(d.nodes) {
		return "", false
	}
	pd := d.nodes[parent].depth
	for i := parent + 1; i < len(d.nodes); i += 1 {
		n := d.nodes[i]
		if n.depth <= pd {
			break
		}
		if n.tag == tag && n.value != "" {
			return n.value, true
		}
	}
	return "", false
}

// ofx_unescape turns the handful of entities OFX uses back into text.
ofx_unescape :: proc(s: string, allocator := context.temp_allocator) -> string {
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
		if semi < 0 || semi > 8 {
			strings.write_byte(&b, s[i])
			i += 1
			continue
		}
		ent := s[i + 1:i + semi]
		switch ent {
		case "amp":
			strings.write_byte(&b, '&')
		case "lt":
			strings.write_byte(&b, '<')
		case "gt":
			strings.write_byte(&b, '>')
		case "quot":
			strings.write_byte(&b, '"')
		case "apos":
			strings.write_byte(&b, '\'')
		case "nbsp":
			strings.write_string(&b, " ")
		case:
			// A numeric entity, or one this does not know: keep it verbatim
			// rather than dropping a character out of a label.
			strings.write_string(&b, s[i:i + semi + 1])
		}
		i += semi + 1
	}
	return strings.to_string(b)
}

// ---------------------------------------------------------------------------
// Statement extraction
// ---------------------------------------------------------------------------

// parse_ofx pulls the account, the transactions and the ledger balance out of
// an OFX or QFX file.
//
// FITID is the bank's own transaction id and it is the best de-duplication
// key there is: it survives a re-export, a different date window and a
// changed label. It is namespaced by the account id here, because FITIDs are
// only unique within an account.
parse_ofx :: proc(s: ^Statement, text: string) {
	d := ofx_parse_doc(text)
	defer ofx_destroy(&d)

	if len(d.nodes) == 0 {
		stmt_error(s, "OFX: aucun élément")
		return
	}
	// A file that does not contain <OFX> at all is not one.
	has_ofx := false
	for n in d.nodes {
		if n.tag == "OFX" {
			has_ofx = true
			break
		}
	}
	if !has_ofx {
		stmt_error(s, "OFX: balise <OFX> absente")
		return
	}

	if cs, ok := d.headers["CHARSET"]; ok {
		if strings.contains(cs, "1252") || strings.contains(cs, "8859") {
			s.encoding = .Latin1
		}
	}

	// The account. BANKACCTFROM holds the bank code and account number;
	// CCACCTFROM is a credit card, which has only a number.
	for n, i in d.nodes {
		if n.tag == "BANKACCTFROM" || n.tag == "CCACCTFROM" {
			if v, ok := ofx_value(&d, i, "ACCTID"); ok && s.acct_id == "" {
				s.acct_id = strings.clone(strings.trim_space(v))
				// Some European banks put the IBAN in ACCTID.
				if iban_valid(v) {
					s.iban = strings.clone(iban_normalize(v, context.temp_allocator))
				}
			}
			if v, ok := ofx_value(&d, i, "IBAN"); ok && s.iban == "" && iban_valid(v) {
				s.iban = strings.clone(iban_normalize(v, context.temp_allocator))
			}
			break
		}
	}
	for n in d.nodes {
		if n.tag == "CURDEF" && n.value != "" {
			s.currency = n.value
			break
		}
	}

	// The ledger balance, which is the statement's closing balance and gives
	// the reconciliation view something to check against.
	for n, i in d.nodes {
		if n.tag != "LEDGERBAL" {
			continue
		}
		if v, ok := ofx_value(&d, i, "BALAMT"); ok {
			if amount, good := money_parse(v, .Dot); good {
				s.closing = amount
				s.has_closing = true
			}
		}
		if v, ok := ofx_value(&d, i, "DTASOF"); ok {
			if dt, good := date_parse(v); good {
				s.closing_date = dt
			}
		}
		break
	}

	// The transactions.
	for n, i in d.nodes {
		if n.tag != "STMTTRN" {
			continue
		}
		s.rows_seen += 1

		dt, has_dt := ofx_value(&d, i, "DTPOSTED")
		amt, has_amt := ofx_value(&d, i, "TRNAMT")
		if !has_dt || !has_amt {
			s.rows_bad += 1
			stmt_warn(s, "OFX: opération sans DTPOSTED ou TRNAMT — ignorée")
			continue
		}
		date, dok := date_parse(dt)
		if !dok {
			s.rows_bad += 1
			stmt_warn(s, "OFX: date illisible «%s» — ignorée", dt)
			continue
		}
		// OFX amounts are always dot-decimal, by specification. Parsing them
		// as French would turn 1.234 into 1 234,00 €.
		amount, aok := money_parse(amt, .Dot)
		if !aok {
			s.rows_bad += 1
			stmt_warn(s, "OFX: montant illisible «%s» — ignorée", amt)
			continue
		}

		name, _ := ofx_value(&d, i, "NAME")
		memo, _ := ofx_value(&d, i, "MEMO")
		payee, _ := ofx_value(&d, i, "PAYEE")
		label := strings.trim_space(ofx_unescape(name, context.temp_allocator))
		if label == "" {
			label = strings.trim_space(ofx_unescape(payee, context.temp_allocator))
		}
		if memo != "" {
			m := strings.trim_space(ofx_unescape(memo, context.temp_allocator))
			if m != "" && m != label {
				label = label == "" ? m : strings.concatenate({label, " ", m}, context.temp_allocator)
			}
		}
		if label == "" {
			if tt, ok := ofx_value(&d, i, "TRNTYPE"); ok {
				label = tt
			} else {
				label = "(sans libellé)"
			}
		}

		t := Raw_Txn {
			date   = date,
			label  = strings.clone(label),
			amount = amount,
		}
		if v, ok := ofx_value(&d, i, "DTUSER"); ok {
			if vd, good := date_parse(v); good {
				t.value = vd
			}
		}
		if fit, ok := ofx_value(&d, i, "FITID"); ok && strings.trim_space(fit) != "" {
			acct := s.acct_id != "" ? s.acct_id : "?"
			t.ext_id = strings.concatenate(
				{"ofx:", acct, ":", strings.trim_space(fit)},
			)
		}
		append(&s.txns, t)
	}

	if len(s.txns) == 0 {
		stmt_error(s, "OFX: aucune opération (%d refusées)", s.rows_bad)
	}
}
