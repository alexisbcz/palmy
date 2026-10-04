// IBAN validation, ISO 13616, and the French RIB key underneath it.
//
// Two independent checks live here and they catch different mistakes:
//
//   * The IBAN check digits (positions 3 and 4) are a mod-97-10 checksum over
//     the whole account identifier. It is computed exactly — no floating
//     point, no big-integer library, just a running remainder — and it catches
//     every single-character error and every transposition of two adjacent
//     characters.
//
//   * A French BBAN carries its own *clé RIB*, the last two digits, a second
//     mod-97 over bank code, branch code and account number. An IBAN can pass
//     ISO 13616 and still not be a well-formed French account, so both are
//     checked.
//
// Nothing here talks to a bank, looks anything up, or needs to: a checksum is
// arithmetic. That also means this file can generate IBANs that are
// structurally valid and belong to nobody, which is what the fixtures use.
package main

import "core:strings"

// The registered length of an IBAN, by country. A country not in this table
// is accepted on the checksum alone, with its length unverified, and
// `iban_check` says so — refusing an unknown country outright would reject a
// legitimate account from a registry update this table has not seen.
IBAN_LENGTHS := [?]struct {
	cc:  string,
	len: int,
} {
	{"AD", 24},
	{"AT", 20},
	{"BE", 16},
	{"BG", 22},
	{"CH", 21},
	{"CY", 28},
	{"CZ", 24},
	{"DE", 22},
	{"DK", 18},
	{"EE", 20},
	{"ES", 24},
	{"FI", 18},
	{"FR", 27},
	{"GB", 22},
	{"GI", 23},
	{"GR", 27},
	{"HR", 21},
	{"HU", 28},
	{"IE", 22},
	{"IS", 26},
	{"IT", 27},
	{"LI", 21},
	{"LT", 20},
	{"LU", 20},
	{"LV", 21},
	{"MC", 27},
	{"MT", 31},
	{"NL", 18},
	{"NO", 15},
	{"PL", 28},
	{"PT", 25},
	{"RO", 24},
	{"SE", 24},
	{"SI", 19},
	{"SK", 24},
	{"SM", 27},
}

Iban_Error :: enum {
	None,
	Too_Short,
	Bad_Country, // the first two characters are not letters
	Bad_Check_Digits, // positions 3 and 4 are not digits
	Bad_Character, // something that is neither a letter nor a digit
	Wrong_Length, // right shape, wrong length for the country
	Checksum, // mod-97-10 did not come out to 1
	Rib_Key, // a French BBAN whose clé RIB does not match
}

iban_error_text :: proc(e: Iban_Error) -> string {
	switch e {
	case .None:
		return "valide"
	case .Too_Short:
		return "trop court"
	case .Bad_Country:
		return "code pays invalide"
	case .Bad_Check_Digits:
		return "clé de contrôle non numérique"
	case .Bad_Character:
		return "caractère interdit"
	case .Wrong_Length:
		return "longueur incorrecte pour ce pays"
	case .Checksum:
		return "clé de contrôle fausse"
	case .Rib_Key:
		return "clé RIB fausse"
	}
	return "invalide"
}

// iban_normalize strips the spaces a human types and upper-cases the letters.
// Nothing else: a character that does not belong is left in place so the
// validator can name it rather than quietly deleting it.
iban_normalize :: proc(s: string, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	for i in 0 ..< len(s) {
		ch := s[i]
		switch {
		case ch == ' ' || ch == '\t' || ch == '-':
		// dropped
		case ch >= 'a' && ch <= 'z':
			strings.write_byte(&b, ch - 32)
		case:
			strings.write_byte(&b, ch)
		}
	}
	return strings.to_string(b)
}

// iban_pretty groups an IBAN in fours, the way it is printed on a statement.
iban_pretty :: proc(s: string, allocator := context.temp_allocator) -> string {
	n := iban_normalize(s, context.temp_allocator)
	b := strings.builder_make(allocator)
	for i in 0 ..< len(n) {
		if i > 0 && i % 4 == 0 {
			strings.write_byte(&b, ' ')
		}
		strings.write_byte(&b, n[i])
	}
	return strings.to_string(b)
}

iban_country_length :: proc(cc: string) -> (n: int, known: bool) {
	for e in IBAN_LENGTHS {
		if e.cc == cc {
			return e.len, true
		}
	}
	return 0, false
}

// iban_mod97 is the mod-97-10 remainder of the rearranged IBAN.
//
// ISO 13616 says: move the first four characters to the end, replace each
// letter by its position in the alphabet plus 9 (A=10 … Z=35), read the result
// as one enormous decimal number, and take it modulo 97. A valid IBAN leaves 1.
//
// The number is far too long for any integer type, so the remainder is carried
// digit by digit: r = (r*10 + d) % 97. That is exact, allocates nothing, and
// is the whole algorithm.
iban_mod97 :: proc(normalized: string) -> (rem: int, ok: bool) {
	if len(normalized) < 5 {
		return 0, false
	}
	r := 0
	feed :: proc(r: int, ch: u8) -> (int, bool) {
		switch {
		case ch >= '0' && ch <= '9':
			return (r * 10 + int(ch - '0')) % 97, true
		case ch >= 'A' && ch <= 'Z':
			v := int(ch - 'A') + 10
			// Two decimal digits, so both have to be fed in.
			return ((r * 10 + v / 10) * 10 + v % 10) % 97, true
		}
		return r, false
	}
	// The BBAN first, then the country code and check digits.
	for i in 4 ..< len(normalized) {
		nr, good := feed(r, normalized[i])
		if !good {
			return 0, false
		}
		r = nr
	}
	for i in 0 ..< 4 {
		nr, good := feed(r, normalized[i])
		if !good {
			return 0, false
		}
		r = nr
	}
	return r, true
}

// iban_check validates an IBAN and says precisely what is wrong with it.
iban_check :: proc(raw: string) -> (err: Iban_Error, country_known: bool) {
	s := iban_normalize(raw, context.temp_allocator)
	if len(s) < 5 {
		return .Too_Short, false
	}
	if !(s[0] >= 'A' && s[0] <= 'Z') || !(s[1] >= 'A' && s[1] <= 'Z') {
		return .Bad_Country, false
	}
	if !(s[2] >= '0' && s[2] <= '9') || !(s[3] >= '0' && s[3] <= '9') {
		return .Bad_Check_Digits, false
	}
	for i in 0 ..< len(s) {
		ch := s[i]
		if !((ch >= '0' && ch <= '9') || (ch >= 'A' && ch <= 'Z')) {
			return .Bad_Character, false
		}
	}
	want, known := iban_country_length(s[:2])
	if known && len(s) != want {
		return .Wrong_Length, true
	}
	rem, ok := iban_mod97(s)
	if !ok || rem != 1 {
		return .Checksum, known
	}
	if s[:2] == "FR" {
		if !rib_key_ok(s[4:]) {
			return .Rib_Key, true
		}
	}
	return .None, known
}

iban_valid :: proc(raw: string) -> bool {
	err, _ := iban_check(raw)
	return err == .None
}

// iban_check_digits computes the two digits that make a country code and BBAN
// into a valid IBAN. Used to build fixtures, and to finish an IBAN a user
// typed with `00` in the middle.
iban_check_digits :: proc(cc: string, bban: string) -> (dd: int, ok: bool) {
	probe := strings.concatenate({cc, "00", bban}, context.temp_allocator)
	rem, good := iban_mod97(probe)
	if !good {
		return 0, false
	}
	return (98 - rem) % 97, true
}

// iban_build assembles cc + check digits + bban.
iban_build :: proc(cc: string, bban: string, allocator := context.temp_allocator) -> string {
	dd, ok := iban_check_digits(cc, bban)
	if !ok {
		return ""
	}
	b := strings.builder_make(allocator)
	strings.write_string(&b, cc)
	strings.write_byte(&b, u8('0' + dd / 10))
	strings.write_byte(&b, u8('0' + dd % 10))
	strings.write_string(&b, bban)
	return strings.to_string(b)
}

// ---------------------------------------------------------------------------
// The French clé RIB
//
// A French BBAN is 5 digits of bank code, 5 of branch code, 11 of account
// number, then 2 of key. The key is
//
//   97 - (89*bank + 15*branch + 3*account) mod 97
//
// with letters in the account number folded to digits by the standard table.
// It is the check that catches a mistyped account number inside an otherwise
// well-formed IBAN, and it is why a French IBAN is 27 characters.
// ---------------------------------------------------------------------------

FR_BBAN_LEN :: 23

// rib_letter maps a letter in an account number to its digit, per the
// published table: A,J → 1; B,K,S → 2; C,L,T → 3; and so on.
rib_letter :: proc(ch: u8) -> (v: int, ok: bool) {
	if ch >= '0' && ch <= '9' {
		return int(ch - '0'), true
	}
	if ch < 'A' || ch > 'Z' {
		return 0, false
	}
	// A..I -> 1..9, J..R -> 1..9, S..Z -> 2..9
	switch {
	case ch <= 'I':
		return int(ch - 'A') + 1, true
	case ch <= 'R':
		return int(ch - 'J') + 1, true
	case:
		return int(ch - 'S') + 2, true
	}
}

// rib_key computes the two-digit key for a 21-character BBAN body (bank 5,
// branch 5, account 11). The three components are reduced modulo 97
// separately, so no intermediate value can overflow.
rib_key :: proc(body: string) -> (key: int, ok: bool) {
	if len(body) != 21 {
		return 0, false
	}
	part :: proc(s: string) -> (v: int, ok: bool) {
		r := 0
		for i in 0 ..< len(s) {
			d, good := rib_letter(s[i])
			if !good {
				return 0, false
			}
			r = (r * 10 + d) % 97
		}
		return r, true
	}
	bank, ok1 := part(body[0:5])
	branch, ok2 := part(body[5:10])
	acct, ok3 := part(body[10:21])
	if !ok1 || !ok2 || !ok3 {
		return 0, false
	}
	// The account number is only folded to digits for this sum; its letters
	// stay letters in the IBAN itself.
	sum := (89 * bank + 15 * branch + 3 * acct) % 97
	k := 97 - sum
	if k == 97 {
		k = 0
	}
	return k, true
}

// rib_key_ok checks the key already in a 23-character French BBAN.
rib_key_ok :: proc(bban: string) -> bool {
	if len(bban) != FR_BBAN_LEN {
		return false
	}
	want, ok := rib_key(bban[:21])
	if !ok {
		return false
	}
	if bban[21] < '0' || bban[21] > '9' || bban[22] < '0' || bban[22] > '9' {
		return false
	}
	got := int(bban[21] - '0') * 10 + int(bban[22] - '0')
	return got == want
}

// fr_iban assembles a French IBAN from the three components, computing both
// the clé RIB and the ISO check digits. Hand it a bank code that the registry
// does not issue — 99999 here — and the result is a valid-looking IBAN that
// cannot be anybody's account, which is exactly what a fixture needs.
fr_iban :: proc(
	bank, branch, account: string,
	allocator := context.temp_allocator,
) -> (
	iban: string,
	ok: bool,
) {
	if len(bank) != 5 || len(branch) != 5 || len(account) != 11 {
		return "", false
	}
	body := strings.concatenate({bank, branch, account}, context.temp_allocator)
	k, good := rib_key(body)
	if !good {
		return "", false
	}
	kb := [2]u8{u8('0' + k / 10), u8('0' + k % 10)}
	bban := strings.concatenate({body, string(kb[:])}, context.temp_allocator)
	out := iban_build("FR", bban, allocator)
	if out == "" {
		return "", false
	}
	return out, true
}
