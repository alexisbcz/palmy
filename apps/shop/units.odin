// Quantity parsing and the unit price — the prix au kilo and the prix au litre.
//
// French law (code de la consommation, art. R. 112-1 and following) requires
// the price per kilo or per litre to be displayed next to the selling price,
// and it is the only honest way to compare two jars: 500 g at 3,20 € is
// 6,40 €/kg, 750 g at 4,50 € is 6,00 €/kg, so the bigger jar is the cheaper
// one even though it costs more. A shop that sorts on the shelf price is
// sorting on the wrong number.
//
// The quantity is not always in a tidy field. A real Google Merchant feed has
// `g:unit_pricing_measure` on some items and nothing on the rest, where the
// quantity lives in the title: "Bière blonde 33 cl — lot de 6",
// "Jambon blanc 12 tranches", "Lessive liquide 2,145 L". So the parser reads
// both, and `lot de N x M` — the case that catches people out, because the
// unit price must be computed over N*M and not over M — is handled explicitly
// and asserted.
//
// Everything is integer. Mass is milligrams, volume is microlitres, a count is
// thousandths of a piece. That is three decimal places more than any feed ever
// writes, which means a decimal quantity like "1,5 L" or "12,5 cl" is exact
// rather than nearly right.
package main

import "core:strings"

Unit_Kind :: enum u8 {
	None,
	Mass,
	Volume,
	Count,
}

// Quantity is what the parser found. `each` is the measure written on one
// package and `count` the number of packages, so a lot of six 33 cl bottles
// keeps both — the UI shows "6 × 33 cl" — while `amount` is the total the
// unit price is computed over.
Quantity :: struct {
	kind:   Unit_Kind,
	amount: i64, // total, in base units (mg / µl / milli-pieces)
	each:   i64, // one package, in base units
	count:  i64, // packages; 1 when the quantity is not a lot
	ok:     bool,
}

// Base units per written unit, so a value scaled by 1000 can be converted by
// a single multiply-divide with no rounding.
@(private = "file")
Unit_Def :: struct {
	name:  string,
	kind:  Unit_Kind,
	scale: i64, // base units in one of these
}

@(private = "file")
UNITS := [?]Unit_Def {
	{"mg", .Mass, 1},
	{"g", .Mass, 1_000},
	{"gr", .Mass, 1_000},
	{"grammes", .Mass, 1_000},
	{"gramme", .Mass, 1_000},
	{"kg", .Mass, 1_000_000},
	{"kgs", .Mass, 1_000_000},
	{"ml", .Volume, 1_000},
	{"cl", .Volume, 10_000},
	{"dl", .Volume, 100_000},
	{"cc", .Volume, 1_000},
	{"l", .Volume, 1_000_000},
	{"litre", .Volume, 1_000_000},
	{"litres", .Volume, 1_000_000},
	{"tranche", .Count, 1_000},
	{"tranches", .Count, 1_000},
	{"piece", .Count, 1_000},
	{"pieces", .Count, 1_000},
	{"unite", .Count, 1_000},
	{"unites", .Count, 1_000},
	{"oeuf", .Count, 1_000},
	{"oeufs", .Count, 1_000},
	{"capsule", .Count, 1_000},
	{"capsules", .Count, 1_000},
	{"dosette", .Count, 1_000},
	{"dosettes", .Count, 1_000},
	{"rouleau", .Count, 1_000},
	{"rouleaux", .Count, 1_000},
	{"sachet", .Count, 1_000},
	{"sachets", .Count, 1_000},
	{"portion", .Count, 1_000},
	{"portions", .Count, 1_000},
	{"pers", .Count, 1_000},
}

@(private = "file")
unit_lookup :: proc(w: string) -> (Unit_Def, bool) {
	for u in UNITS {
		if u.name == w {
			return u, true
		}
	}
	return {}, false
}

@(private = "file")
Tok_Kind :: enum u8 {
	Number,
	Word,
	Times,
	Other,
}

@(private = "file")
Tok :: struct {
	kind:  Tok_Kind,
	milli: i64,    // Number: the value scaled by 1000
	word:  string, // Word: folded letters
	used:  bool,
}

// fold_sep is fold with the decimal separators and the multiplication sign
// kept, which is what the quantity tokenizer needs; the search path wants them
// gone. Rather than two folders, the tokenizer calls this one.
@(private = "file")
fold_sep :: proc(s: string, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	strings.builder_grow(&b, len(s))
	for r in s {
		switch r {
		case ',', '.':
			strings.write_rune(&b, r)
			continue
		case '\u00d7':
			strings.write_rune(&b, 'x')
			continue
		}
		a, extra := fold_rune(r)
		for ch in ([?]rune{a, extra}) {
			if ch == 0 {
				continue
			}
			if (ch >= 'a' && ch <= 'z') || (ch >= '0' && ch <= '9') {
				strings.write_rune(&b, ch)
			} else {
				strings.write_rune(&b, ' ')
			}
		}
	}
	return strings.to_string(b)
}

// parse_quantity reads a quantity out of a string — a feed's
// `g:unit_pricing_measure`, or a product title when the field is absent.
//
// The shape it is looking for:
//
//	500 g                    -> 500 000 mg
//	1,5 L                    -> 1 500 000 µl
//	75 cl                    -> 750 000 µl
//	lot de 6 x 33 cl         -> 6 x 330 000 = 1 980 000 µl
//	6x33cl                   -> the same
//	Jambon 12 tranches       -> 12 pieces
//	Pâtes 500 g x 4          -> 2 000 000 mg
//	Jean slim homme          -> nothing; clothing has no unit price
parse_quantity :: proc(s: string) -> Quantity {
	toks := make([dynamic]Tok, context.temp_allocator)
	tokenize_sep(s, &toks)

	// Measures: a number immediately followed by a unit word.
	best_kind := Unit_Kind.None
	best_amount: i64 = 0
	best_at := -1
	for i in 0 ..< len(toks) {
		if toks[i].kind != .Number {
			continue
		}
		if i + 1 >= len(toks) || toks[i + 1].kind != .Word {
			continue
		}
		u, found := unit_lookup(toks[i + 1].word)
		if !found {
			continue
		}
		amount := toks[i].milli * u.scale / 1000
		if amount <= 0 {
			continue
		}
		// Mass and volume beat a count: "lot de 6 bouteilles de 1,5 L" is
		// priced per litre, not per bottle.
		better := false
		if best_at < 0 {
			better = true
		} else if best_kind == .Count && u.kind != .Count {
			better = true
		}
		if better {
			best_kind, best_amount, best_at = u.kind, amount, i
			toks[i].used = true
			toks[i + 1].used = true
		}
	}

	// Multipliers: `N x`, `x N`, and the number after "lot de" / "pack de".
	mult: i64 = 1
	for i in 0 ..< len(toks) {
		if toks[i].kind != .Number || toks[i].used || i == best_at {
			continue
		}
		n := toks[i].milli
		if n % 1000 != 0 || n <= 0 {
			continue // a multiplier is a whole number of packages
		}
		whole := n / 1000
		if whole > 1000 {
			continue // a barcode or a year, not a lot size
		}
		is_mult := false
		if i + 1 < len(toks) && toks[i + 1].kind == .Times {
			is_mult = true
		}
		if i > 0 && toks[i - 1].kind == .Times {
			is_mult = true
		}
		if !is_mult && i >= 2 && toks[i - 1].kind == .Word && toks[i - 1].word == "de" {
			switch toks[i - 2].word {
			case "lot", "pack", "paquet", "boite", "set", "colis":
				is_mult = true
			}
		}
		if !is_mult && i >= 1 && toks[i - 1].kind == .Word {
			switch toks[i - 1].word {
			case "lot", "pack", "paquet":
				is_mult = true
			}
		}
		if is_mult {
			toks[i].used = true
			mult *= whole
		}
	}

	if best_at < 0 {
		// No measure. A bare multiplier is still a quantity: "Yaourt nature
		// x 16" is sixteen pots, and €/pot is a real comparison.
		if mult > 1 {
			return {kind = .Count, amount = mult * 1000, each = 1000, count = mult, ok = true}
		}
		return {}
	}
	return {
		kind = best_kind,
		amount = best_amount * mult,
		each = best_amount,
		count = mult,
		ok = true,
	}
}

// tokenize_sep is the tokenizer over fold_sep, which keeps the decimal mark.
@(private = "file")
tokenize_sep :: proc(s: string, out: ^[dynamic]Tok) {
	folded := fold_sep(s)
	i := 0
	for i < len(folded) {
		c := folded[i]
		switch {
		case c >= '0' && c <= '9':
			whole: i64 = 0
			j := i
			for j < len(folded) && folded[j] >= '0' && folded[j] <= '9' {
				whole = whole * 10 + i64(folded[j] - '0')
				j += 1
			}
			frac: i64 = 0
			scale: i64 = 1
			if j + 1 < len(folded) && (folded[j] == ',' || folded[j] == '.') &&
			   folded[j + 1] >= '0' && folded[j + 1] <= '9' {
				j += 1
				for j < len(folded) && folded[j] >= '0' && folded[j] <= '9' {
					if scale < 1000 {
						frac = frac * 10 + i64(folded[j] - '0')
						scale *= 10
					}
					j += 1
				}
			}
			append(out, Tok{kind = .Number, milli = whole * 1000 + (frac * 1000) / scale})
			i = j
		case c >= 'a' && c <= 'z':
			j := i
			for j < len(folded) && folded[j] >= 'a' && folded[j] <= 'z' {
				j += 1
			}
			w := folded[i:j]
			if w == "x" {
				append(out, Tok{kind = .Times})
			} else {
				append(out, Tok{kind = .Word, word = w})
			}
			i = j
		case:
			if c == '*' {
				append(out, Tok{kind = .Times})
			} else if c != ' ' {
				append(out, Tok{kind = .Other})
			}
			i += 1
		}
	}
}

// ---------------------------------------------------------------------------
// The unit price
// ---------------------------------------------------------------------------

// Base units in the reference quantity: one kilo, one litre, one piece.
MG_PER_KG :: i64(1_000_000)
UL_PER_L :: i64(1_000_000)
MILLI_PER_PIECE :: i64(1_000)

// unit_price is the price per kilo, per litre or per piece, in centimes,
// rounded half up. It is the number the comparison sorts on.
unit_price :: proc(price: Centimes, q: Quantity) -> (Centimes, bool) {
	if !q.ok || q.amount <= 0 {
		return 0, false
	}
	ref: i64
	switch q.kind {
	case .Mass:
		ref = MG_PER_KG
	case .Volume:
		ref = UL_PER_L
	case .Count:
		ref = MILLI_PER_PIECE
	case .None:
		return 0, false
	}
	num := i64(price) * ref
	neg := num < 0
	if neg {
		num = -num
	}
	v := (num + q.amount / 2) / q.amount
	return Centimes(neg ? -v : v), true
}

unit_suffix :: proc(k: Unit_Kind) -> string {
	switch k {
	case .Mass:
		return "€/kg"
	case .Volume:
		return "€/L"
	case .Count:
		return "€/pièce"
	case .None:
		return ""
	}
	return ""
}

// fmt_unit_price is "6,40 €/kg".
fmt_unit_price :: proc(price: Centimes, q: Quantity, allocator := context.allocator) -> string {
	per, ok := unit_price(price, q)
	if !ok {
		return strings.clone("", allocator)
	}
	return strings.concatenate(
		{fmt_centimes(per, context.temp_allocator), NBSP, unit_suffix(q.kind)},
		allocator,
	)
}

// ---------------------------------------------------------------------------
// Writing a quantity back out
// ---------------------------------------------------------------------------

// fmt_dec writes `value / divisor` with at most `max_dec` decimals, French
// style, with the trailing zeros trimmed: 1500/1000 at 3 decimals is "1,5".
fmt_dec :: proc(value, divisor: i64, max_dec: int, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	v := value
	if v < 0 {
		strings.write_string(&b, "-")
		v = -v
	}
	whole := v / divisor
	rem := v % divisor

	digits: [24]u8
	n := 0
	if whole == 0 {
		digits[0] = '0'
		n = 1
	} else {
		for whole > 0 {
			digits[n] = u8('0' + whole % 10)
			whole /= 10
			n += 1
		}
	}
	for i := n - 1; i >= 0; i -= 1 {
		strings.write_byte(&b, digits[i])
	}

	if rem != 0 && max_dec > 0 {
		dec: [8]u8
		dn := 0
		d := divisor
		for dn < max_dec && rem != 0 {
			d /= 10
			if d <= 0 {
				break
			}
			dec[dn] = u8('0' + rem / d)
			rem %= d
			dn += 1
		}
		for dn > 0 && dec[dn - 1] == '0' {
			dn -= 1
		}
		if dn > 0 {
			strings.write_string(&b, ",")
			for i in 0 ..< dn {
				strings.write_byte(&b, dec[i])
			}
		}
	}
	return strings.to_string(b)
}

// fmt_amount writes a total in the unit a French label would use: grams below
// a kilo, kilos above; centilitres below a litre when they come out whole,
// millilitres otherwise; litres above.
fmt_amount :: proc(kind: Unit_Kind, amount: i64, allocator := context.allocator) -> string {
	switch kind {
	case .Mass:
		if amount >= 1_000_000 {
			return strings.concatenate({fmt_dec(amount, 1_000_000, 3, context.temp_allocator), NBSP, "kg"}, allocator)
		}
		return strings.concatenate({fmt_dec(amount, 1_000, 1, context.temp_allocator), NBSP, "g"}, allocator)
	case .Volume:
		if amount >= 1_000_000 {
			return strings.concatenate({fmt_dec(amount, 1_000_000, 3, context.temp_allocator), NBSP, "L"}, allocator)
		}
		if amount % 10_000 == 0 {
			return strings.concatenate({fmt_dec(amount, 10_000, 0, context.temp_allocator), NBSP, "cl"}, allocator)
		}
		return strings.concatenate({fmt_dec(amount, 1_000, 1, context.temp_allocator), NBSP, "ml"}, allocator)
	case .Count:
		n := amount / 1000
		word := n == 1 ? "pièce" : "pièces"
		return strings.concatenate({fmt_dec(amount, 1_000, 0, context.temp_allocator), NBSP, word}, allocator)
	case .None:
		return strings.clone("", allocator)
	}
	return strings.clone("", allocator)
}

// fmt_quantity is how the quantity is written on the shelf: "6 × 33 cl" for a
// lot, the plain amount otherwise.
fmt_quantity :: proc(q: Quantity, allocator := context.allocator) -> string {
	if !q.ok {
		return strings.clone("", allocator)
	}
	if q.count > 1 && q.each > 0 && q.kind != .Count {
		each := fmt_amount(q.kind, q.each, context.temp_allocator)
		return strings.concatenate(
			{fmt_dec(q.count, 1, 0, context.temp_allocator), NBSP, "×", NBSP, each},
			allocator,
		)
	}
	return fmt_amount(q.kind, q.amount, allocator)
}
