// Money, and the French way of writing it.
//
// Every price in this application is an integer number of centimes. Nothing
// about a price is ever an f32 or an f64: a basket of thirty lines summed in
// floating point drifts, and the drift shows up as a total that is one centime
// away from the sum of the lines it is printed next to. There is no rounding
// policy that fixes that, because the error is in the representation. So the
// type is `Centimes`, a distinct i64, and the only division in here is
// integer division with the rounding written out.
//
// The formatting is the French convention, which is not negotiable either:
// comma for the decimal separator, a non-breaking space grouping the
// thousands, and a non-breaking space before the currency symbol. The spaces
// are U+00A0 and they are asserted byte for byte in the self-test, because a
// plain 0x20 would let the line break between the number and the euro sign.
package main

import "core:strconv"
import "core:strings"

// Centimes is a price in hundredths of a euro. i64 because a catalogue total
// in centimes is nowhere near 2^63 but a 32-bit count of centimes runs out at
// about 21 million euros, and a grocery chain's catalogue can exceed that.
Centimes :: distinct i64

// NBSP is U+00A0. French typography puts one before the currency symbol and
// one between thousands groups.
NBSP :: "\u00a0"

// ---------------------------------------------------------------------------
// TVA
//
// The rate belongs to the product, not to the shop: a bottle of water is 5,5 %
// and the bottle of washing-up liquid next to it on the same receipt is 20 %.
// Rates are held in basis points so the arithmetic stays integral — 5,5 % is
// 550, not 0.055.
// ---------------------------------------------------------------------------

Tva :: enum u8 {
	Standard, // 20 %   — non-food, clothing, household
	Reduced,  // 10 %   — some prepared food, takeaway meals
	Food,     // 5,5 %  — most unprocessed food
	Super,    // 2,1 %  — a short list, including some press and medicines
}

tva_bp :: proc(t: Tva) -> i64 {
	switch t {
	case .Standard:
		return 2000
	case .Reduced:
		return 1000
	case .Food:
		return 550
	case .Super:
		return 210
	}
	return 2000
}

tva_label :: proc(t: Tva) -> string {
	switch t {
	case .Standard:
		return "20 %"
	case .Reduced:
		return "10 %"
	case .Food:
		return "5,5 %"
	case .Super:
		return "2,1 %"
	}
	return "20 %"
}

// price_ht is the price excluding tax, from a shelf price that includes it.
// Shops quote TTC in France, so TTC is what the catalogue holds and HT is
// derived — the other way round would accumulate a rounding error per line.
//
// HT = TTC * 10000 / (10000 + bp), rounded half up, in integer arithmetic.
price_ht :: proc(ttc: Centimes, t: Tva) -> Centimes {
	bp := tva_bp(t)
	den := 10000 + bp
	num := i64(ttc) * 10000
	neg := num < 0
	if neg {
		num = -num
	}
	q := (num + den / 2) / den
	return Centimes(neg ? -q : q)
}

// price_tva is the tax itself, defined as the remainder so that HT + TVA is
// always exactly the TTC that is printed on the shelf.
price_tva :: proc(ttc: Centimes, t: Tva) -> Centimes {
	return ttc - price_ht(ttc, t)
}

// ---------------------------------------------------------------------------
// Formatting
// ---------------------------------------------------------------------------

// fmt_centimes writes 123456 as "1 234,56", with U+00A0 between the thousands
// groups and no currency symbol.
fmt_centimes :: proc(c: Centimes, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	v := i64(c)
	if v < 0 {
		strings.write_string(&b, "-")
		v = -v
	}
	whole := v / 100
	cents := v % 100

	// Digits of the integer part, then grouped from the right.
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
		if i > 0 && i % 3 == 0 {
			strings.write_string(&b, NBSP)
		}
	}
	strings.write_string(&b, ",")
	strings.write_byte(&b, u8('0' + cents / 10))
	strings.write_byte(&b, u8('0' + cents % 10))
	return strings.to_string(b)
}

// fmt_money is fmt_centimes with the euro sign, preceded by a non-breaking
// space: "1 234,56 €".
fmt_money :: proc(c: Centimes, allocator := context.allocator) -> string {
	num := fmt_centimes(c, context.temp_allocator)
	return strings.concatenate({num, NBSP, "€"}, allocator)
}

// parse_centimes reads a price the way a French feed writes it. Both
// separators are accepted — "12,99" is the local convention and "12.99" is
// what an exporter that forgot the locale emits — and so is a thousands
// separator, whether it is a space, a non-breaking space or an apostrophe.
//
// It refuses anything it cannot read exactly rather than guessing: an empty
// string, a stray letter, more than two decimals, or a second separator.
parse_centimes :: proc(s: string) -> (Centimes, bool) {
	t := strings.trim_space(s)
	if t == "" {
		return 0, false
	}
	neg := false
	if t[0] == '-' {
		neg = true
		t = t[1:]
	} else if t[0] == '+' {
		t = t[1:]
	}

	whole: i64 = 0
	frac: i64 = 0
	frac_digits := 0
	seen_sep := false
	any_digit := false

	i := 0
	for i < len(t) {
		ch := t[i]
		switch {
		case ch >= '0' && ch <= '9':
			any_digit = true
			if seen_sep {
				frac_digits += 1
				if frac_digits > 2 {
					return 0, false
				}
				frac = frac * 10 + i64(ch - '0')
			} else {
				whole = whole * 10 + i64(ch - '0')
				if whole > 1 << 50 {
					return 0, false
				}
			}
			i += 1
		case ch == ',' || ch == '.':
			if seen_sep || !any_digit {
				return 0, false
			}
			seen_sep = true
			i += 1
		case ch == ' ' || ch == '\'':
			// A thousands separator, only legal before the decimal mark.
			if seen_sep {
				return 0, false
			}
			i += 1
		case ch == 0xc2 && i + 1 < len(t) && t[i + 1] == 0xa0:
			if seen_sep {
				return 0, false
			}
			i += 2
		case:
			return 0, false
		}
	}
	if !any_digit {
		return 0, false
	}
	if frac_digits == 1 {
		frac *= 10
	}
	v := whole * 100 + frac
	return Centimes(neg ? -v : v), true
}

// parse_money reads a feed's price field, which carries a currency: Google's
// product feed specifies "12.99 EUR" and real French exporters write
// "12,99 EUR" or "12,99 €". Anything that is not euros is refused — silently
// treating 12.99 USD as 12,99 € would be a wrong price, which is worse than
// no price.
parse_money :: proc(s: string) -> (c: Centimes, ok: bool) {
	t := strings.trim_space(s)
	if t == "" {
		return 0, false
	}
	cur := ""
	// A trailing currency word or symbol.
	if strings.has_suffix(t, "€") {
		cur = "EUR"
		t = strings.trim_space(t[:len(t) - len("€")])
	} else if sp := strings.last_index_byte(t, ' '); sp > 0 {
		tail := strings.trim_space(t[sp + 1:])
		if len(tail) == 3 && is_alpha_ascii(tail) {
			cur = strings.to_upper(tail, context.temp_allocator)
			t = strings.trim_space(t[:sp])
		}
	} else if len(t) > 3 && is_alpha_ascii(t[len(t) - 3:]) {
		// "12.99EUR", no space.
		cur = strings.to_upper(t[len(t) - 3:], context.temp_allocator)
		t = strings.trim_space(t[:len(t) - 3])
	}
	if cur != "" && cur != "EUR" {
		return 0, false
	}
	return parse_centimes(t)
}

is_alpha_ascii :: proc(s: string) -> bool {
	if s == "" {
		return false
	}
	for i in 0 ..< len(s) {
		c := s[i]
		if !((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')) {
			return false
		}
	}
	return true
}

// pct_change is the signed change from `from` to `to`, in tenths of a percent,
// which is what the price-history column shows. Integer again: a percentage of
// a price is a derived display value and does not need to be a float to be
// right.
pct_change :: proc(from, to: Centimes) -> i64 {
	if from == 0 {
		return 0
	}
	d := (i64(to) - i64(from)) * 1000
	a := i64(from)
	if a < 0 {
		a = -a
	}
	if d < 0 {
		return -((-d + a / 2) / a)
	}
	return (d + a / 2) / a
}

// fmt_pct writes tenths of a percent as "-12,5 %", French style.
fmt_pct :: proc(tenths: i64, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	v := tenths
	if v < 0 {
		strings.write_string(&b, "-")
		v = -v
	} else {
		strings.write_string(&b, "+")
	}
	buf: [24]u8
	strings.write_string(&b, strconv.write_int(buf[:], v / 10, 10))
	strings.write_string(&b, ",")
	strings.write_byte(&b, u8('0' + v % 10))
	strings.write_string(&b, NBSP)
	strings.write_string(&b, "%")
	return strings.to_string(b)
}
