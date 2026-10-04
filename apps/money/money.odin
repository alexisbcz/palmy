// Money, as integers.
//
// Every amount in this application is a signed count of centimes in an i64.
// There is no f32 or f64 anywhere on the money path, and that is not fussiness:
// a statement is thousands of additions, and a binary float cannot hold 0,01 €
// exactly, so the error accumulates until a balance is wrong by a centime and
// nobody can say which line is at fault. An i64 of centimes holds ±92 000
// milliards of euros exactly, which is enough.
//
// Formatting is French: `1 234,56 €`, comma for the decimal, a non-breaking
// space grouping the thousands, and a non-breaking space before the symbol so
// the amount never wraps away from its currency.
package main

import "core:strings"

// Cents is a signed number of centimes. Negative is money leaving an account.
Cents :: distinct i64

// U+00A0, the non-breaking space, as the two bytes UTF-8 spells it with.
NBSP :: " "

// ---------------------------------------------------------------------------
// Formatting
// ---------------------------------------------------------------------------

// money_text writes the French form: sign, grouped euros, comma, two
// centimes, then a non-breaking space and the euro sign.
money_text :: proc(c: Cents, symbol := true, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	money_write(&b, c, symbol)
	return strings.to_string(b)
}

// money_write is the same, into a builder the caller owns.
money_write :: proc(b: ^strings.Builder, c: Cents, symbol := true) {
	v := i64(c)
	if v < 0 {
		strings.write_string(b, "-")
	}
	// -(min) overflows in two's complement, so negate in u64.
	mag := v < 0 ? u64(-(v + 1)) + 1 : u64(v)
	euros := mag / 100
	cent := mag % 100

	// Group the euros in threes from the right.
	digits: [24]u8
	n := 0
	if euros == 0 {
		digits[0] = '0'
		n = 1
	} else {
		for e := euros; e > 0; e /= 10 {
			digits[n] = u8('0' + e % 10)
			n += 1
		}
	}
	for i := n - 1; i >= 0; i -= 1 {
		strings.write_byte(b, digits[i])
		if i > 0 && i % 3 == 0 {
			strings.write_string(b, NBSP)
		}
	}
	strings.write_byte(b, ',')
	strings.write_byte(b, u8('0' + cent / 10))
	strings.write_byte(b, u8('0' + cent % 10))
	if symbol {
		strings.write_string(b, NBSP)
		strings.write_string(b, "€")
	}
}

// money_signed always shows the sign, which is what a ledger column wants so
// that a credit and a debit cannot be confused at a glance.
money_signed :: proc(c: Cents, allocator := context.temp_allocator) -> string {
	if c > 0 {
		return strings.concatenate({"+", money_text(c, true, allocator)}, allocator)
	}
	return money_text(c, true, allocator)
}

// ---------------------------------------------------------------------------
// Parsing
// ---------------------------------------------------------------------------

// Separator says which character the file uses for the decimal point. A bank
// export is consistent within itself, so the importer states it rather than
// guessing per row — a guess per row is how `1.234` becomes 1,23 € on one
// line and 1 234,00 € on the next.
Separator :: enum {
	Auto, // decide from the string: the last `.` or `,` is the decimal point
	Comma, // 1.234,56 — French
	Dot, // 1,234.56 — Anglo
}

// money_parse reads an amount out of a statement cell.
//
// It accepts a leading or trailing sign, parentheses for negative (some
// exports still do that), a currency symbol or code, thousands separators as
// spaces (ASCII, NBSP or the narrow NBSP), apostrophes or the other separator,
// and up to two decimals. A third decimal digit rounds half away from zero.
// Anything else — a letter in the middle, two decimal points, no digit at all
// — is refused rather than silently read as zero, because a zero that should
// have been 428,90 € is a bug the user will not see.
money_parse :: proc(text: string, sep := Separator.Auto) -> (c: Cents, ok: bool) {
	s := strings.trim_space(text)
	if s == "" {
		return 0, false
	}

	neg := false
	// Parentheses, the accountant's minus.
	if len(s) >= 2 && s[0] == '(' && s[len(s) - 1] == ')' {
		neg = true
		s = strings.trim_space(s[1:len(s) - 1])
	}

	// Strip a currency marker from either end.
	for marker in ([?]string{"€", "EUR", "eur", "EURO", "¤"}) {
		if strings.has_prefix(s, marker) {
			s = strings.trim_space(s[len(marker):])
		}
		if strings.has_suffix(s, marker) {
			s = strings.trim_space(s[:len(s) - len(marker)])
		}
	}
	if s == "" {
		return 0, false
	}
	// U+2212, the typographer's minus, is three bytes, so it has to be tested
	// as a string and not as a byte.
	if strings.has_prefix(s, "−") {
		neg = !neg
		s = s[3:]
	} else if s[0] == '+' {
		s = s[1:]
	} else if s[0] == '-' {
		neg = !neg
		s = s[1:]
	} else if s[len(s) - 1] == '-' { 	// trailing minus, as some exports do
		neg = !neg
		s = s[:len(s) - 1]
	}
	s = strings.trim_space(s)
	if s == "" {
		return 0, false
	}

	// Which character is the decimal point?
	dec: u8 = 0
	switch sep {
	case .Comma:
		dec = ','
	case .Dot:
		dec = '.'
	case .Auto:
		last_comma := strings.last_index_byte(s, ',')
		last_dot := strings.last_index_byte(s, '.')
		if last_comma >= 0 && last_dot >= 0 {
			// Both appear: the rightmost is the decimal point.
			dec = last_comma > last_dot ? ',' : '.'
		} else if last_comma >= 0 {
			dec = ','
		} else if last_dot >= 0 {
			// A lone `.` followed by exactly three digits, with digits before
			// it, is a thousands separator in a French export: `1.234`.
			tail := len(s) - last_dot - 1
			if tail == 3 && last_dot > 0 {
				dec = ','
			} else {
				dec = '.'
			}
		}
	}

	whole: i64 = 0
	frac: [4]u8
	nfrac := 0
	seen_digit := false
	in_frac := false
	for i := 0; i < len(s); i += 1 {
		ch := s[i]
		switch {
		case ch >= '0' && ch <= '9':
			seen_digit = true
			if in_frac {
				if nfrac < len(frac) {
					frac[nfrac] = ch
				}
				nfrac += 1
			} else {
				if whole > (1 << 53) {
					return 0, false
				}
				whole = whole * 10 + i64(ch - '0')
			}
		case dec != 0 && ch == dec:
			if in_frac {
				return 0, false // two decimal points
			}
			in_frac = true
		case ch == ' ' || ch == '\'' || ch == '.' || ch == ',':
			// A grouping separator. Inside the fraction it is nonsense.
			if in_frac {
				return 0, false
			}
		case ch == 0xc2 && i + 1 < len(s) && s[i + 1] == 0xa0:
			i += 1 // NBSP
		case ch == 0xe2 && i + 2 < len(s) && s[i + 1] == 0x80 && s[i + 2] == 0xaf:
			i += 2 // U+202F narrow NBSP
		case:
			return 0, false
		}
	}
	if !seen_digit {
		return 0, false
	}

	// Pad or round the fraction to exactly two digits.
	cents: i64 = 0
	switch {
	case nfrac == 0:
		cents = 0
	case nfrac == 1:
		cents = i64(frac[0] - '0') * 10
	case:
		cents = i64(frac[0] - '0') * 10 + i64(frac[1] - '0')
		if nfrac > 2 && frac[2] >= '5' {
			cents += 1 // half away from zero
		}
	}
	total := whole * 100 + cents
	if neg {
		total = -total
	}
	return Cents(total), true
}

// ---------------------------------------------------------------------------
// Arithmetic helpers
//
// There is nothing clever here, which is the point: addition of integers is
// exact and associative, so a balance does not depend on the order the rows
// arrived in.
// ---------------------------------------------------------------------------

money_abs :: proc(c: Cents) -> Cents {
	return c < 0 ? -c : c
}

money_sum :: proc(xs: []Cents) -> (total: Cents) {
	for x in xs {
		total += x
	}
	return
}

// money_split divides an amount into n parts that add back up to exactly the
// original — the remainder centimes go one each to the first parts, which is
// how a shared bill is actually settled. 10,00 € over 3 is 3,34 / 3,33 / 3,33.
money_split :: proc(c: Cents, n: int, allocator := context.temp_allocator) -> []Cents {
	if n <= 0 {
		return nil
	}
	out := make([]Cents, n, allocator)
	sign: i64 = i64(c) < 0 ? -1 : 1
	mag := i64(money_abs(c))
	base := mag / i64(n)
	rem := mag % i64(n)
	for i in 0 ..< n {
		v := base
		if i64(i) < rem {
			v += 1
		}
		out[i] = Cents(v * sign)
	}
	return out
}

// money_percent is a percentage of an amount, rounded half away from zero,
// done in integers so 33 % of 10,01 € is a fixed answer rather than a float's.
money_percent :: proc(c: Cents, numerator, denominator: i64) -> Cents {
	if denominator == 0 {
		return 0
	}
	v := i64(c) * numerator
	half := denominator / 2
	if (v < 0) != (denominator < 0) {
		return Cents((v - half) / denominator)
	}
	return Cents((v + half) / denominator)
}
