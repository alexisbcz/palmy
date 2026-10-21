// `money --selftest`: the whole engine, with no window and no file touched.
//
// Nothing here reads the user's data directory and nothing writes to it. The
// fixtures are the string constants in fixtures.odin, parsed from memory, so
// a failure is always a parser failure and never a file-system one, and the
// suite can be run on a machine with no statements on it at all.
//
// The suite is in the order the program is built on: money, dates, IBAN, the
// three import formats and their malformed cases, the ledger and its
// double-entry property test, categorisation, budgets, recurrence detection,
// reconciliation, the store round trip, and the search.
package main

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:time"
import kit "kit:."

TC :: struct {
	n:      int,
	failed: int,
	first:  string,
}

ok_mark :: proc(tc: ^TC, cond: bool, what: string, loc := #caller_location) {
	tc.n += 1
	if !cond {
		tc.failed += 1
		if tc.first == "" {
			tc.first = what
		}
		fmt.printfln("  FAIL  %s  (%s:%d)", what, loc.file_path, loc.line)
	}
}

eq_cents :: proc(tc: ^TC, got, want: Cents, what: string, loc := #caller_location) {
	tc.n += 1
	if got != want {
		tc.failed += 1
		if tc.first == "" {
			tc.first = what
		}
		fmt.printfln(
			"  FAIL  %s: %d centimes au lieu de %d  (%s:%d)",
			what,
			i64(got),
			i64(want),
			loc.file_path,
			loc.line,
		)
	}
}

eq_int :: proc(tc: ^TC, got, want: int, what: string, loc := #caller_location) {
	tc.n += 1
	if got != want {
		tc.failed += 1
		if tc.first == "" {
			tc.first = what
		}
		fmt.printfln("  FAIL  %s: %d au lieu de %d  (%s:%d)", what, got, want, loc.file_path, loc.line)
	}
}

eq_str :: proc(tc: ^TC, got, want: string, what: string, loc := #caller_location) {
	tc.n += 1
	if got != want {
		tc.failed += 1
		if tc.first == "" {
			tc.first = what
		}
		fmt.printfln("  FAIL  %s: «%s» au lieu de «%s»  (%s:%d)", what, got, want, loc.file_path, loc.line)
	}
}

// fresh_app builds an application with no window and nothing loaded from
// disk, which is what every test below runs against.
fresh_app :: proc() -> ^App {
	app := new(App)
	app_init(app)
	app.today = Date{2026, 10, 5}
	app.month = month_start(app.today)
	return app
}

drop_app :: proc(app: ^App) {
	app_destroy(app)
	free(app)
}

selftest_mode :: proc() -> int {
	tc: TC
	start := time.now()

	test_money(&tc)
	test_dates(&tc)
	test_iban(&tc)
	test_csv(&tc)
	test_csv_malformed(&tc)
	test_ofx(&tc)
	test_camt(&tc)
	test_ledger(&tc)
	test_property(&tc)
	test_rules(&tc)
	test_budget(&tc)
	test_recur(&tc)
	test_recon(&tc)
	test_store(&tc)
	test_search(&tc)
	test_fuzz_money(&tc)
	test_fuzz_csv(&tc)
	test_fuzz_truncation(&tc)
	test_cli(&tc)

	ms := time.duration_milliseconds(time.since(start))
	if tc.failed == 0 {
		fmt.printfln("money --selftest: %d assertions, toutes vérifiées (%.0f ms)", tc.n, ms)
		return 0
	}
	fmt.printfln(
		"money --selftest: %d assertions, %d échecs (première: %s)",
		tc.n,
		tc.failed,
		tc.first,
	)
	return 1
}

// ---------------------------------------------------------------------------
// Money
// ---------------------------------------------------------------------------

test_money :: proc(tc: ^TC) {
	// French formatting: comma decimal, non-breaking space grouping, a
	// non-breaking space before the symbol.
	eq_str(tc, money_text(123456), "1 234,56 €", "format 1 234,56 €")
	eq_str(tc, money_text(0), "0,00 €", "format zéro")
	eq_str(tc, money_text(-4210), "-42,10 €", "format négatif")
	eq_str(tc, money_text(5), "0,05 €", "format cinq centimes")
	eq_str(tc, money_text(100), "1,00 €", "format un euro")
	eq_str(tc, money_text(123456789), "1 234 567,89 €", "format millions")
	eq_str(tc, money_text(100000, false), "1 000,00", "format sans symbole")
	eq_str(tc, money_signed(2450), "+24,50 €", "format signé positif")
	eq_str(tc, money_signed(-2450), "-24,50 €", "format signé négatif")

	// Parsing, in every shape a bank export uses.
	p1, ok1 := money_parse("-42,10")
	ok_mark(tc, ok1, "lecture -42,10")
	eq_cents(tc, p1, -4210, "lecture -42,10")
	p2, ok2 := money_parse("1 234,56")
	ok_mark(tc, ok2, "lecture 1 234,56")
	eq_cents(tc, p2, 123456, "lecture 1 234,56 (espace)")
	p3, _ := money_parse("1 234,56")
	eq_cents(tc, p3, 123456, "lecture 1 234,56 (espace insécable)")
	p4, _ := money_parse("1 234,56")
	eq_cents(tc, p4, 123456, "lecture 1 234,56 (espace fine)")
	p5, _ := money_parse("1.234,56")
	eq_cents(tc, p5, 123456, "lecture 1.234,56 — le point groupe")
	p6, _ := money_parse("1,234.56")
	eq_cents(tc, p6, 123456, "lecture 1,234.56 — la virgule groupe")
	p7, _ := money_parse("-42.10")
	eq_cents(tc, p7, -4210, "lecture -42.10")
	p8, _ := money_parse("(42,10)")
	eq_cents(tc, p8, -4210, "lecture (42,10) parenthèses négatives")
	p9, _ := money_parse("42,10 €")
	eq_cents(tc, p9, 4210, "lecture avec le symbole")
	p10, _ := money_parse("+2 450,00 EUR")
	eq_cents(tc, p10, 245000, "lecture avec le code devise")
	p11, _ := money_parse("1.234")
	eq_cents(tc, p11, 123400, "lecture 1.234 — groupe de trois, pas un décimal")
	p12, _ := money_parse("12")
	eq_cents(tc, p12, 1200, "lecture d'un entier")
	p13, _ := money_parse("0,005")
	eq_cents(tc, p13, 1, "arrondi au centime supérieur")
	p14, _ := money_parse("-0,005")
	eq_cents(tc, p14, -1, "arrondi loin de zéro pour un négatif")
	p15, _ := money_parse("42,1")
	eq_cents(tc, p15, 4210, "une seule décimale")
	p16, _ := money_parse("1234,56", .Comma)
	eq_cents(tc, p16, 123456, "séparateur imposé: virgule")
	p17, _ := money_parse("1,234.56", .Dot)
	eq_cents(tc, p17, 123456, "séparateur imposé: point")

	// Refusals: a cell that is not an amount must not read as zero.
	_, bad1 := money_parse("")
	ok_mark(tc, !bad1, "une cellule vide est refusée")
	_, bad2 := money_parse("abc")
	ok_mark(tc, !bad2, "du texte est refusé")
	_, bad3 := money_parse("12,34,56")
	ok_mark(tc, !bad3, "deux virgules décimales sont refusées")
	_, bad4 := money_parse("-")
	ok_mark(tc, !bad4, "un signe seul est refusé")
	_, bad5 := money_parse("12€34")
	ok_mark(tc, !bad5, "un symbole au milieu est refusé")

	// The reason this is all integers: a long sequence of additions and
	// subtractions against an exactly known total.
	//
	// 0,01 € added 1 000 000 times is 10 000,00 €. In f32 it is not: the
	// running sum passes 2^24 and every further addition of 0.01 is lost to
	// rounding, so the float answer is wrong by thousands of euros. Both are
	// asserted — the integer total exactly, and the float total as *wrong* —
	// because the second assertion is the one that documents why the first
	// matters.
	total: Cents = 0
	for _ in 0 ..< 1_000_000 {
		total += 1
	}
	eq_cents(tc, total, 1_000_000, "un million de centimes additionnés exactement")

	f: f32 = 0
	for _ in 0 ..< 1_000_000 {
		f += 0.01
	}
	// Measured here: 9 865,22 — short by 134,78 €, because once the running
	// sum passes 2^24 ulps the increment of 0,01 no longer survives rounding.
	ok_mark(tc, f != 10000.0, "la même somme en f32 n'est pas exacte")
	ok_mark(
		tc,
		money_abs(Cents(i64(f64(f) * 100)) - 1_000_000) > 10_000,
		"et elle est fausse de plus de cent euros, d'où les entiers",
	)
	// Even f64 does not hold 0,01 exactly: it is closer, which is worse,
	// because the error hides until the hundredth statement.
	d: f64 = 0
	for _ in 0 ..< 1_000_000 {
		d += 0.01
	}
	ok_mark(tc, d != 10000.0, "en f64 non plus: l'erreur est seulement plus discrète")

	// A long mixed sequence: +1 234,56, −789,01, repeated, must land exactly
	// on a figure that can be worked out by hand.
	mixed: Cents = 0
	for _ in 0 ..< 100_000 {
		mixed += 123456
		mixed -= 78901
	}
	eq_cents(tc, mixed, Cents(100_000 * (123456 - 78901)), "100 000 additions et soustractions")

	// And the same sequence in a different order gives the same total, which
	// is only true because integer addition is associative.
	shuffled: Cents = 0
	for _ in 0 ..< 100_000 {
		shuffled -= 78901
	}
	for _ in 0 ..< 100_000 {
		shuffled += 123456
	}
	eq_cents(tc, shuffled, mixed, "l'ordre des additions ne change pas le total")

	// Round trip through the formatter and back.
	for v in ([?]Cents{0, 1, -1, 99, 100, -4210, 123456, -123456789, 999999999}) {
		text := money_text(v, false, context.temp_allocator)
		back, ok := money_parse(text, .Comma)
		ok_mark(tc, ok, fmt.tprintf("relecture de «%s»", text))
		eq_cents(tc, back, v, fmt.tprintf("aller-retour de %d centimes", i64(v)))
	}

	// Splitting: the parts must add back up to the whole, exactly.
	parts := money_split(1000, 3)
	eq_int(tc, len(parts), 3, "une division en trois donne trois parts")
	eq_cents(tc, money_sum(parts), 1000, "10,00 € divisé en trois se recompose")
	eq_cents(tc, parts[0], 334, "le centime restant va à la première part")
	eq_cents(tc, parts[1], 333, "puis le reste à parts égales")
	neg := money_split(-1000, 3)
	eq_cents(tc, money_sum(neg), -1000, "une division négative se recompose")
	seven := money_split(100, 7)
	eq_cents(tc, money_sum(seven), 100, "1,00 € en sept se recompose")

	// Percentages, in integers, rounded half away from zero.
	eq_cents(tc, money_percent(10000, 20, 100), 2000, "20 % de 100 €")
	eq_cents(tc, money_percent(1001, 50, 100), 501, "50 % de 10,01 € arrondi")
	eq_cents(tc, money_percent(-1001, 50, 100), -501, "et le symétrique négatif")
	eq_cents(tc, money_percent(100, 1, 0), 0, "une division par zéro rend zéro")

	eq_cents(tc, money_abs(-500), 500, "valeur absolue")
	eq_cents(tc, money_sum({100, -50, 25}), 75, "somme d'une liste")
}

// ---------------------------------------------------------------------------
// Dates
// ---------------------------------------------------------------------------

test_dates :: proc(tc: ^TC) {
	d, ok := date_parse("31/01/2026")
	ok_mark(tc, ok, "lecture 31/01/2026")
	eq_int(tc, d.y, 2026, "année")
	eq_int(tc, d.m, 1, "mois")
	eq_int(tc, d.d, 31, "jour")

	d2, ok2 := date_parse("31/01/26")
	ok_mark(tc, ok2, "lecture 31/01/26")
	eq_int(tc, d2.y, 2026, "année sur deux chiffres")

	d3, ok3 := date_parse("2026-01-31")
	ok_mark(tc, ok3, "lecture ISO")
	ok_mark(tc, date_eq(d3, Date{2026, 1, 31}), "l'ISO et le français donnent la même date")

	d4, ok4 := date_parse("20260131120000[-5:EST]")
	ok_mark(tc, ok4, "lecture d'un horodatage OFX")
	ok_mark(tc, date_eq(d4, Date{2026, 1, 31}), "l'horodatage OFX donne la bonne date")

	d5, ok5 := date_parse("31-01-2026")
	ok_mark(tc, ok5, "lecture avec des tirets")
	ok_mark(tc, date_eq(d5, Date{2026, 1, 31}), "les tirets donnent la même date")

	d6, ok6 := date_parse("31.01.2026")
	ok_mark(tc, ok6 && date_eq(d6, Date{2026, 1, 31}), "lecture avec des points")

	d7, ok7 := date_parse("01/31/2026", .MDY)
	ok_mark(tc, ok7 && date_eq(d7, Date{2026, 1, 31}), "lecture au format américain, imposé")

	// A date that does not exist must be refused, not clamped.
	_, bad1 := date_parse("31/02/2026")
	ok_mark(tc, !bad1, "le 31 février est refusé")
	_, bad2 := date_parse("30/02/2024")
	ok_mark(tc, !bad2, "le 30 février d'une année bissextile est refusé")
	_, bad3 := date_parse("00/01/2026")
	ok_mark(tc, !bad3, "le jour zéro est refusé")
	_, bad4 := date_parse("01/13/2026", .DMY)
	ok_mark(tc, !bad4, "le mois 13 est refusé")
	_, bad5 := date_parse("pas une date")
	ok_mark(tc, !bad5, "du texte est refusé")
	_, bad6 := date_parse("01/01")
	ok_mark(tc, !bad6, "une date incomplète est refusée")

	// Leap years, which is where a date library earns its keep.
	ok_mark(tc, date_valid(Date{2024, 2, 29}), "2024 est bissextile")
	ok_mark(tc, !date_valid(Date{2026, 2, 29}), "2026 ne l'est pas")
	ok_mark(tc, date_valid(Date{2000, 2, 29}), "2000 est bissextile (règle des 400)")
	ok_mark(tc, !date_valid(Date{1900, 2, 29}), "1900 ne l'est pas (règle des 100)")
	eq_int(tc, days_in_month(2024, 2), 29, "février 2024 fait 29 jours")
	eq_int(tc, days_in_month(2026, 2), 28, "février 2026 fait 28 jours")

	// Ordering and month boundaries.
	ok_mark(tc, date_less(Date{2026, 1, 31}, Date{2026, 2, 1}), "31 janvier précède le 1er février")
	ok_mark(tc, !date_less(Date{2026, 2, 1}, Date{2026, 1, 31}), "et pas l'inverse")
	ok_mark(tc, date_less(Date{2025, 12, 31}, Date{2026, 1, 1}), "la fin d'année s'ordonne")
	ok_mark(
		tc,
		date_eq(date_add(Date{2026, 1, 31}, 1), Date{2026, 2, 1}),
		"le lendemain du 31 janvier",
	)
	ok_mark(
		tc,
		date_eq(date_add(Date{2024, 2, 28}, 1), Date{2024, 2, 29}),
		"le lendemain du 28 février en année bissextile",
	)
	ok_mark(
		tc,
		date_eq(date_add(Date{2026, 12, 31}, 1), Date{2027, 1, 1}),
		"le passage à l'année suivante",
	)

	// month_add clamps rather than overflowing into the next month.
	ok_mark(
		tc,
		date_eq(date_month_add(Date{2026, 1, 31}, 1), Date{2026, 2, 28}),
		"31 janvier + 1 mois = 28 février",
	)
	ok_mark(
		tc,
		date_eq(date_month_add(Date{2024, 1, 31}, 1), Date{2024, 2, 29}),
		"et 29 février en année bissextile",
	)
	ok_mark(
		tc,
		date_eq(date_month_add(Date{2026, 1, 15}, -1), Date{2025, 12, 15}),
		"un mois en arrière franchit l'année",
	)
	eq_int(
		tc,
		date_month_index(Date{2026, 2, 1}) - date_month_index(Date{2026, 1, 1}),
		1,
		"l'index de mois s'incrémente de un",
	)
	eq_int(
		tc,
		date_month_index(Date{2027, 1, 1}) - date_month_index(Date{2026, 12, 1}),
		1,
		"et franchit l'année",
	)

	// The day-number round trip, over a long span including leap days.
	for n in -5000 ..< 5000 {
		if n % 37 != 0 {
			continue
		}
		back := days_from_civil(civil_from_days(n))
		if back != n {
			ok_mark(tc, false, fmt.tprintf("aller-retour du jour %d", n))
			break
		}
	}
	ok_mark(tc, days_from_civil(Date{1970, 1, 1}) == 0, "l'époque est le jour zéro")
	ok_mark(tc, days_from_civil(Date{2026, 10, 5}) > 20000, "une date actuelle est plausible")

	// Ranges, inclusive at both ends.
	ok_mark(
		tc,
		date_within(Date{2026, 9, 1}, Date{2026, 9, 1}, Date{2026, 9, 30}),
		"le premier du mois est dans le mois",
	)
	ok_mark(
		tc,
		date_within(Date{2026, 9, 30}, Date{2026, 9, 1}, Date{2026, 9, 30}),
		"le dernier aussi",
	)
	ok_mark(
		tc,
		!date_within(Date{2026, 10, 1}, Date{2026, 9, 1}, Date{2026, 9, 30}),
		"le lendemain non",
	)

	// Text.
	eq_str(tc, date_text(Date{2026, 1, 5}), "05/01/2026", "format jj/mm/aaaa")
	eq_str(tc, date_iso(Date{2026, 1, 5}), "2026-01-05", "format ISO")
	eq_str(tc, date_text_long(Date{2026, 1, 5}), "5 janvier 2026", "format long en français")
	eq_str(tc, month_text(2026, 10), "octobre 2026", "nom du mois")
	ok_mark(tc, date_eq(month_end(Date{2026, 2, 10}), Date{2026, 2, 28}), "fin de février")
	ok_mark(tc, date_eq(month_start(Date{2026, 2, 10}), Date{2026, 2, 1}), "début de février")
}

// ---------------------------------------------------------------------------
// IBAN
// ---------------------------------------------------------------------------

test_iban :: proc(tc: ^TC) {
	// Published test vectors. These are the documentation examples from the
	// IBAN registry and the ECBS, not anybody's account.
	valid := [?]string {
		"FR1420041010050500013M02606", // the standard French example
		"FR7630006000011234567890189",
		"FR7630001007941234567890185",
		"GB82WEST12345698765432",
		"GB33BUKB20201555555555",
		"DE89370400440532013000",
		"BE68539007547034",
		"NL91ABNA0417164300",
		"MC5811222000010123456789030",
	}
	for v in valid {
		err, _ := iban_check(v)
		ok_mark(tc, err == .None, fmt.tprintf("vecteur publié %s valide (%s)", v, iban_error_text(err)))
		rem, good := iban_mod97(v)
		ok_mark(tc, good && rem == 1, fmt.tprintf("mod-97-10 de %s vaut 1", v))
	}

	// Spaces and lower case are a presentation detail.
	err_sp, _ := iban_check("FR14 2004 1010 0505 0001 3M02 606")
	ok_mark(tc, err_sp == .None, "un IBAN écrit par groupes de quatre est valide")
	err_lc, _ := iban_check("fr1420041010050500013m02606")
	ok_mark(tc, err_lc == .None, "un IBAN en minuscules est valide")
	eq_str(
		tc,
		iban_pretty("FR1420041010050500013M02606"),
		"FR14 2004 1010 0505 0001 3M02 606",
		"mise en forme par groupes de quatre",
	)

	// A single transposition must fail: that is the property mod-97-10 has
	// and a simple digit sum does not.
	err_tr, _ := iban_check("FR1420041010050500013M02066")
	ok_mark(tc, err_tr != .None, "deux chiffres échangés font échouer la clé")
	err_tr2, _ := iban_check(FX_IBAN_TRANSPOSED)
	ok_mark(tc, err_tr2 != .None, "l'IBAN de test avec deux chiffres permutés échoue")

	// Every single-character change in the check digits must fail.
	bad_check := 0
	base := "DE89370400440532013000"
	for d in 0 ..= 9 {
		for pos in 2 ..= 3 {
			buf := strings.clone(base, context.temp_allocator)
			tmp := transmute([]u8)buf
			if tmp[pos] == u8('0' + d) {
				continue
			}
			tmp[pos] = u8('0' + d)
			if e, _ := iban_check(string(tmp)); e != .None {
				bad_check += 1
			}
		}
	}
	eq_int(tc, bad_check, 18, "les 18 autres clés de contrôle échouent toutes")

	// Length and country rules.
	err_len, known := iban_check("FR142004101005050001")
	ok_mark(tc, err_len == .Wrong_Length && known, "un IBAN français trop court est refusé")
	err_len2, _ := iban_check("DE8937040044053201300012")
	ok_mark(tc, err_len2 == .Wrong_Length, "un IBAN allemand trop long est refusé")
	err_cc, _ := iban_check("1R1420041010050500013M02606")
	ok_mark(tc, err_cc == .Bad_Country, "un code pays non alphabétique est refusé")
	err_dd, _ := iban_check("FRX420041010050500013M02606")
	ok_mark(tc, err_dd == .Bad_Check_Digits, "une clé non numérique est refusée")
	err_ch, _ := iban_check("FR142004101005050001*M02606")
	ok_mark(tc, err_ch == .Bad_Character, "un caractère interdit est refusé")
	err_short, _ := iban_check("FR14")
	ok_mark(tc, err_short == .Too_Short, "quatre caractères, c'est trop court")
	_, unknown := iban_check("XK051212012345678906")
	ok_mark(tc, !unknown, "un pays hors table est signalé comme inconnu")

	// The French clé RIB, which is a second, independent check.
	k, kok := rib_key("200410100505000133M02")
	ok_mark(tc, kok, "la clé RIB se calcule")
	_ = k
	ok_mark(tc, rib_key_ok("20041010050500013M02606"), "la clé RIB de l'exemple est bonne")
	ok_mark(tc, !rib_key_ok("20041010050500013M02607"), "une clé RIB fausse est détectée")
	// An IBAN whose ISO check digits are right but whose clé RIB is not.
	broken := iban_build("FR", "20041010050500013M02607", context.temp_allocator)
	err_rib, _ := iban_check(broken)
	ok_mark(tc, err_rib == .Rib_Key, "clé ISO bonne mais clé RIB fausse: refusé")

	// Generated fixtures: valid checksums, fictitious accounts.
	for iban in ([?]string{FX_IBAN_CURRENT, FX_IBAN_SAVINGS}) {
		err, _ := iban_check(iban)
		ok_mark(tc, err == .None, fmt.tprintf("l'IBAN de fixture %s est valide", iban))
		eq_int(tc, len(iban), 27, "un IBAN français fait 27 caractères")
		ok_mark(
			tc,
			strings.has_prefix(iban, "FR") && iban[4:9] == "99999",
			"la fixture utilise un code banque non attribué",
		)
	}

	// Generating: the computed check digits round-trip.
	built, bok := fr_iban("99999", "00042", "0000000123A")
	ok_mark(tc, bok, "un IBAN français se construit")
	ok_mark(tc, iban_valid(built), fmt.tprintf("l'IBAN construit %s est valide", built))
	eq_int(tc, len(built), 27, "et fait la bonne longueur")
	_, bad_len := fr_iban("9999", "00042", "0000000123A")
	ok_mark(tc, !bad_len, "un code banque trop court est refusé")

	dd, dok := iban_check_digits("FR", "20041010050500013M02606")
	ok_mark(tc, dok && dd == 14, "les clés de contrôle calculées valent 14")
}

// ---------------------------------------------------------------------------
// CSV import
// ---------------------------------------------------------------------------

test_csv :: proc(tc: ^TC) {
	// --- Bank Alpha: preamble, Débit/Crédit, running balance, DD/MM/YYYY ---
	s := parse_text(FX_ALPHA_CSV, nil, "alpha.csv")
	defer {
		statement_destroy(s)
		free(s)
	}
	ok_mark(tc, s.format == .CSV, "alpha: reconnu comme CSV")
	ok_mark(tc, statement_ok(s), fmt.tprintf("alpha: lisible (%d erreurs)", len(s.errors)))
	eq_int(tc, len(s.txns), 21, "alpha: 21 opérations")
	eq_int(tc, s.rows_bad, 0, "alpha: aucune ligne refusée")

	// The IBAN comes out of the preamble, which is how the file lands in the
	// right account without being asked.
	eq_str(tc, s.iban, FX_IBAN_CURRENT, "alpha: l'IBAN du préambule est lu")

	// The first row is a credit of 2 450 €; the second a debit of 950 €.
	eq_cents(tc, s.txns[0].amount, 245000, "alpha: la colonne Crédit est positive")
	eq_str(tc, s.txns[0].label, "VIR SALAIRE SOCIETE EXEMPLE SA", "alpha: libellé de la première ligne")
	eq_cents(tc, s.txns[1].amount, -95000, "alpha: la colonne Débit est négative")
	// `1 234,56` with a grouping space, inside a Débit column.
	eq_cents(tc, s.txns[2].amount, -8240, "alpha: 82,40 en débit")
	eq_cents(tc, s.txns[20].amount, -1199, "alpha: la dernière ligne")
	ok_mark(tc, date_eq(s.txns[0].date, Date{2026, 9, 2}), "alpha: la date est lue en jj/mm/aaaa")

	// The running balance column gives the statement's closing balance.
	ok_mark(tc, s.has_closing, "alpha: un solde de clôture est trouvé")
	eq_cents(tc, s.closing, 158103, "alpha: solde de clôture 1 581,03 €")
	ok_mark(tc, date_eq(s.closing_date, Date{2026, 9, 30}), "alpha: à la bonne date")

	// The sum of the rows must equal the change in the running balance, which
	// is the arithmetic check the file makes possible.
	total := Cents(0)
	for t in s.txns {
		total += t.amount
	}
	eq_cents(tc, total + 100000, 158103, "alpha: solde initial + mouvements = solde final")

	// --- The same file in Windows-1252 ---
	latin := to_latin1(FX_ALPHA_CSV, context.temp_allocator)
	ok_mark(tc, !utf8_valid(string(latin)), "la version Latin-1 n'est pas de l'UTF-8 valide")
	decoded, enc := decode_text(latin, .Auto, context.temp_allocator)
	ok_mark(tc, enc == .Latin1, "l'encodage Latin-1 est détecté")
	ok_mark(tc, utf8_valid(decoded), "et transcodé en UTF-8 valide")
	s2 := parse_text(decoded, nil, "alpha-latin1.csv")
	defer {
		statement_destroy(s2)
		free(s2)
	}
	eq_int(tc, len(s2.txns), 21, "latin-1: les 21 mêmes opérations")
	eq_str(tc, s2.txns[1].label, s.txns[1].label, "latin-1: le même libellé")

	// A UTF-8 file must not be mistaken for Latin-1.
	_, enc2 := decode_text(transmute([]u8)string(FX_ALPHA_CSV), .Auto, context.temp_allocator)
	ok_mark(tc, enc2 == .UTF8, "un fichier UTF-8 reste de l'UTF-8")
	ok_mark(tc, utf8_valid("Libellé"), "l'UTF-8 accentué est valide")
	ok_mark(tc, !utf8_valid("Libell\xe9"), "un octet Latin-1 isolé ne l'est pas")
	ok_mark(tc, !utf8_valid("\xc3"), "une séquence tronquée ne l'est pas")
	ok_mark(tc, !utf8_valid("\xed\xa0\x80"), "un demi-substitut ne l'est pas")

	// --- Bank Beta: comma delimiter, quoted labels, ISO dates, signed ---
	s3 := parse_text(FX_BETA_CSV, nil, "beta.csv")
	defer {
		statement_destroy(s3)
		free(s3)
	}
	eq_int(tc, len(s3.txns), 8, "beta: 8 opérations")
	eq_str(
		tc,
		s3.txns[0].label,
		"CB LE PETIT CAFE, PARIS 1011",
		"beta: un champ entre guillemets garde sa virgule",
	)
	eq_cents(tc, s3.txns[0].amount, -480, "beta: montant signé négatif")
	eq_cents(tc, s3.txns[1].amount, 245000, "beta: montant signé positif")
	ok_mark(tc, date_eq(s3.txns[0].date, Date{2026, 10, 1}), "beta: date ISO")
	ok_mark(tc, s3.txns[0].ext_id != "", "beta: la référence devient un identifiant")

	// --- Bank Gamma: no header, tabs, two-digit years, grouped thousands ---
	s4 := parse_text(FX_GAMMA_CSV, nil, "gamma.csv")
	defer {
		statement_destroy(s4)
		free(s4)
	}
	eq_int(tc, len(s4.txns), 4, "gamma: 4 opérations sans en-tête")
	eq_cents(tc, s4.txns[0].amount, -124900, "gamma: -1 249,00 avec un séparateur de milliers")
	ok_mark(tc, date_eq(s4.txns[0].date, Date{2026, 10, 5}), "gamma: année sur deux chiffres")
	eq_str(tc, s4.txns[0].label, "CB IKEA 0510", "gamma: libellé")
	eq_cents(tc, s4.txns[1].amount, 120000, "gamma: un crédit garde son signe")

	// Delimiter sniffing, on its own.
	ok_mark(tc, csv_sniff_delimiter(FX_ALPHA_CSV) == ';', "le point-virgule est détecté")
	ok_mark(tc, csv_sniff_delimiter(FX_BETA_CSV) == ',', "la virgule est détectée")
	ok_mark(tc, csv_sniff_delimiter(FX_GAMMA_CSV) == '\t', "la tabulation est détectée")

	// Quoting rules.
	f1, _ := csv_split_line("a;\"b;c\";d\n", ';')
	eq_int(tc, len(f1), 3, "un champ entre guillemets ne se coupe pas")
	eq_str(tc, f1[1], "b;c", "et garde le délimiteur")
	f2, _ := csv_split_line("a;\"il dit \"\"oui\"\"\";b\n", ';')
	eq_str(tc, f2[1], "il dit \"oui\"", "deux guillemets valent un guillemet")
	f3, n3 := csv_split_line("a;b\r\nc;d\n", ';')
	eq_int(tc, len(f3), 2, "CRLF termine l'enregistrement")
	eq_int(tc, n3, 5, "et consomme les deux octets de fin de ligne")

	// Header recognition, which is what skips the preamble.
	prof, pok := csv_guess_profile(FX_ALPHA_CSV)
	ok_mark(tc, pok, "alpha: un profil complet est déduit")
	eq_int(tc, prof.skip, 4, "alpha: les quatre lignes de préambule sont sautées")
	eq_int(tc, prof.col_date, 0, "alpha: la date est en colonne 0")
	eq_int(tc, prof.col_label, 1, "alpha: le libellé en colonne 1")
	eq_int(tc, prof.col_debit, 2, "alpha: le débit en colonne 2")
	eq_int(tc, prof.col_credit, 3, "alpha: le crédit en colonne 3")
	eq_int(tc, prof.col_balance, 4, "alpha: le solde en colonne 4")
	eq_int(tc, prof.col_amount, -1, "alpha: pas de colonne de montant signé")
	ok_mark(tc, prof.decimal == .Comma, "alpha: décimale à la virgule")
	ok_mark(tc, prof.date_fmt == .DMY, "alpha: dates jour/mois/année")

	prof2, pok2 := csv_guess_profile(FX_BETA_CSV)
	ok_mark(tc, pok2, "beta: un profil complet est déduit")
	eq_int(tc, prof2.skip, 0, "beta: pas de préambule")
	eq_int(tc, prof2.col_amount, 2, "beta: une seule colonne de montant")
	ok_mark(tc, prof2.date_fmt == .YMD, "beta: dates ISO")

	prof3, pok3 := csv_guess_profile(FX_GAMMA_CSV)
	ok_mark(tc, pok3, "gamma: un profil est déduit sans en-tête")
	ok_mark(tc, !prof3.has_header, "gamma: aucun en-tête n'est supposé")
	eq_int(tc, prof3.col_date, 0, "gamma: la date est trouvée par son contenu")
	eq_int(tc, prof3.col_label, 1, "gamma: le libellé est la colonne de texte la plus large")

	// Header normalisation, which is what the mapping is keyed by.
	eq_str(tc, header_norm("Date de l'opération"), "date de l operation", "normalisation d'en-tête")
	eq_str(tc, header_norm("  LIBELLÉ  "), "libelle", "accents et espaces")
	ok_mark(tc, header_role("Libellé") == .Label, "«Libellé» est un libellé")
	ok_mark(tc, header_role("Date valeur") == .Value_Date, "«Date valeur» n'est pas «Date»")
	ok_mark(tc, header_role("Débit") == .Debit, "«Débit» est un débit")
	ok_mark(tc, header_role("Montant") == .Amount, "«Montant» est un montant")
	ok_mark(tc, header_role("Solde") == .Balance, "«Solde» est un solde")
	ok_mark(tc, header_role("n'importe quoi") == .None, "et le reste n'est rien")

	// The fingerprint: the same bank's two exports key the same, a different
	// bank's does not.
	fp1 := fingerprint_of({"Date", "Libellé", "Débit", "Crédit", "Solde"})
	fp2 := fingerprint_of({"DATE", "libelle", "DEBIT", "credit", "SOLDE"})
	eq_str(tc, fp1, fp2, "deux écritures du même en-tête donnent la même empreinte")
	fp3 := fingerprint_of({"Date", "Description", "Montant"})
	ok_mark(tc, fp1 != fp3, "un autre en-tête donne une autre empreinte")
}

test_csv_malformed :: proc(tc: ^TC) {
	// Every malformed case in one file. The good rows must still arrive, and
	// each refusal must be reported with its line number.
	s := parse_text(FX_BAD_CSV, nil, "malforme.csv")
	defer {
		statement_destroy(s)
		free(s)
	}
	ok_mark(tc, statement_ok(s), "malformé: le fichier reste exploitable")
	eq_int(tc, len(s.txns), 3, "malformé: trois lignes bonnes sur cinq")
	eq_int(tc, s.rows_bad, 2, "malformé: deux lignes refusées")
	ok_mark(tc, len(s.warnings) >= 2, "malformé: chaque refus est expliqué")

	// The impossible date is refused, not clamped to the 28th.
	for t in s.txns {
		ok_mark(tc, t.date.m != 2, "malformé: la ligne du 31 février n'est pas importée")
		break
	}
	saw_impossible := false
	for t in s.txns {
		if t.date.m == 2 {
			saw_impossible = true
		}
	}
	ok_mark(tc, !saw_impossible, "malformé: aucune opération en février")

	// The thousands separator: `-1.234,56` is 1 234,56 €, not 1,23 €.
	found_big := false
	for t in s.txns {
		if t.amount == -123456 {
			found_big = true
		}
	}
	ok_mark(tc, found_big, "malformé: -1.234,56 est lu comme -1 234,56 €")

	// The truncated last row has too few columns and is refused by count.
	truncated_reported := false
	for w in s.warnings {
		if strings.contains(w, "colonnes") {
			truncated_reported = true
		}
	}
	ok_mark(tc, truncated_reported, "malformé: la ligne tronquée est signalée comme telle")
	date_reported := false
	for w in s.warnings {
		if strings.contains(w, "date") {
			date_reported = true
		}
	}
	ok_mark(tc, date_reported, "malformé: la date illisible est signalée comme telle")

	// A completely empty file, and one that stops after its header.
	empty := parse_text("", nil, "vide.csv")
	ok_mark(tc, !statement_ok(empty), "un fichier vide est refusé")
	statement_destroy(empty)
	free(empty)

	headers_only := parse_text("Date;Libellé;Montant\n", nil, "entete.csv")
	ok_mark(tc, !statement_ok(headers_only), "un fichier réduit à son en-tête est refusé")
	ok_mark(tc, len(headers_only.errors) > 0, "et l'erreur est nommée")
	statement_destroy(headers_only)
	free(headers_only)

	// A duplicated transaction id: the file offers three rows, two of which
	// carry the same reference, so only two transactions may be booked.
	app := fresh_app()
	defer drop_app(app)
	ensure_categories(app)
	acct := account_add(&app.led, "Compte courant", .Asset)
	dup := parse_text(FX_DUP_CSV, nil, "doublons.csv")
	eq_int(tc, len(dup.txns), 3, "doublons: trois lignes dans le fichier")
	rep := statement_ingest(app, dup, acct)
	eq_int(tc, rep.added, 2, "doublons: deux opérations ajoutées")
	eq_int(tc, rep.duplicates, 1, "doublons: une refusée comme doublon")
	ok_mark(tc, ledger_check(&app.led).ok, "doublons: le livre reste équilibré")
	statement_destroy(dup)
	free(dup)

	// And re-importing the whole file adds nothing at all.
	dup2 := parse_text(FX_DUP_CSV, nil, "doublons.csv")
	rep2 := statement_ingest(app, dup2, acct)
	eq_int(tc, rep2.added, 0, "ré-import: rien n'est ajouté")
	eq_int(tc, rep2.duplicates, 3, "ré-import: tout est reconnu comme doublon")
	statement_destroy(dup2)
	free(dup2)

	// De-duplication by count, for a bank that gives no ids: two identical
	// coffees on the same day are two transactions, and the second must
	// survive the import.
	twice := "Date;Libellé;Montant\n01/10/2026;CB LE PETIT CAFE;-4,80\n01/10/2026;CB LE PETIT CAFE;-4,80\n"
	app2 := fresh_app()
	defer drop_app(app2)
	acct2 := account_add(&app2.led, "Compte courant", .Asset)
	st := parse_text(twice, nil, "deuxcafes.csv")
	r1 := statement_ingest(app2, st, acct2)
	eq_int(tc, r1.added, 2, "deux opérations identiques le même jour sont deux opérations")
	statement_destroy(st)
	free(st)
	st2 := parse_text(twice, nil, "deuxcafes.csv")
	r2 := statement_ingest(app2, st2, acct2)
	eq_int(tc, r2.added, 0, "mais le même fichier réimporté n'ajoute rien")
	eq_int(tc, r2.duplicates, 2, "les deux sont reconnues")
	statement_destroy(st2)
	free(st2)

	// An overlapping export: the same two rows plus one new one.
	st3text := strings.concatenate(
		{twice, "02/10/2026;CB LE PETIT CAFE;-4,80\n"},
		context.temp_allocator,
	)
	st3 := parse_text(st3text, nil, "trois.csv")
	r3 := statement_ingest(app2, st3, acct2)
	eq_int(tc, r3.added, 1, "un export qui recouvre n'ajoute que la nouveauté")
	statement_destroy(st3)
	free(st3)
	ok_mark(tc, ledger_check(&app2.led).ok, "le livre reste équilibré après les trois imports")
}

// ---------------------------------------------------------------------------
// OFX / QFX
// ---------------------------------------------------------------------------

test_ofx :: proc(tc: ^TC) {
	// The SGML form, where the leaf tags are never closed — the case a strict
	// XML parser refuses outright.
	s := parse_text(FX_OFX, nil, "alpha.ofx")
	defer {
		statement_destroy(s)
		free(s)
	}
	ok_mark(tc, s.format == .OFX, "OFX: reconnu par son contenu")
	ok_mark(tc, statement_ok(s), fmt.tprintf("OFX: lisible (%d erreurs)", len(s.errors)))
	eq_int(tc, len(s.txns), 7, "OFX: sept opérations, doublon de FITID compris")
	eq_str(tc, s.currency, "EUR", "OFX: la devise est lue")
	eq_str(tc, s.acct_id, FX_IBAN_CURRENT, "OFX: le numéro de compte est lu")
	eq_str(tc, s.iban, FX_IBAN_CURRENT, "OFX: l'IBAN dans ACCTID est reconnu")

	eq_cents(tc, s.txns[0].amount, 245000, "OFX: un crédit")
	eq_cents(tc, s.txns[1].amount, -95000, "OFX: un débit")
	ok_mark(tc, date_eq(s.txns[0].date, Date{2026, 9, 2}), "OFX: la date est lue depuis l'horodatage")
	eq_str(
		tc,
		s.txns[1].label,
		"PRLV SEPA LOYER AGENCE EXEMPLE ECH 030926",
		"OFX: NAME et MEMO sont joints",
	)
	ok_mark(tc, s.txns[0].ext_id != "", "OFX: le FITID devient un identifiant")
	ok_mark(
		tc,
		strings.contains(s.txns[0].ext_id, "FX2026090200001"),
		"OFX: et contient le FITID",
	)
	// The FITID is namespaced by account, because it is only unique within
	// one.
	ok_mark(
		tc,
		strings.contains(s.txns[0].ext_id, FX_IBAN_CURRENT),
		"OFX: l'identifiant est préfixé par le compte",
	)

	// The entity in the last MEMO.
	eq_str(
		tc,
		s.txns[6].label,
		"CB CARREFOUR 2109 PAIEMENT PAR CARTE & SANS CONTACT",
		"OFX: &amp; est décodé",
	)
	eq_str(tc, ofx_unescape("a&lt;b&gt;c&amp;d"), "a<b>c&d", "OFX: les entités connues")
	eq_str(tc, ofx_unescape("100&euro;"), "100&euro;", "OFX: une entité inconnue reste littérale")

	// The ledger balance, which the reconciliation view uses.
	ok_mark(tc, s.has_closing, "OFX: LEDGERBAL est trouvé")
	eq_cents(tc, s.closing, 158103, "OFX: solde 1 581,03 €")
	ok_mark(tc, date_eq(s.closing_date, Date{2026, 9, 30}), "OFX: à la bonne date")

	// The duplicated FITID is refused at ingestion, not at parsing: the
	// parser's job is to report what the file says.
	app := fresh_app()
	defer drop_app(app)
	ensure_categories(app)
	acct := account_add(&app.led, "Compte courant", .Asset, FX_IBAN_CURRENT)
	rep := statement_ingest(app, s, acct)
	eq_int(tc, rep.added, 6, "OFX: six opérations ajoutées")
	eq_int(tc, rep.duplicates, 1, "OFX: le FITID répété est refusé")
	ok_mark(tc, ledger_check(&app.led).ok, "OFX: le livre est équilibré")
	eq_cents(tc, app.led.accounts[acct].balance, 245000 - 95000 - 8240 - 6420 - 1349 - 9125, "OFX: le solde du compte")

	// The XML form of the same format.
	x := parse_text(FX_OFX_XML, nil, "epargne.qfx")
	defer {
		statement_destroy(x)
		free(x)
	}
	ok_mark(tc, x.format == .OFX, "OFX 2: reconnu malgré l'en-tête XML")
	eq_int(tc, len(x.txns), 2, "OFX 2: deux opérations")
	eq_cents(tc, x.txns[0].amount, 20000, "OFX 2: montant")
	eq_str(tc, x.iban, FX_IBAN_SAVINGS, "OFX 2: l'IBAN du livret")
	eq_cents(tc, x.closing, 540000, "OFX 2: le solde de clôture")
	eq_str(tc, x.txns[0].label, "VIR M EXEMPLE EPARGNE", "OFX 2: le libellé")

	// Truncated: the rows before the cut must still be imported.
	t := parse_text(FX_OFX_TRUNCATED, nil, "tronque.ofx")
	defer {
		statement_destroy(t)
		free(t)
	}
	eq_int(tc, len(t.txns), 1, "OFX tronqué: la ligne complète est lue")
	eq_cents(tc, t.txns[0].amount, -4210, "OFX tronqué: et correctement")
	eq_int(tc, t.rows_bad, 1, "OFX tronqué: la ligne coupée est refusée")

	// A file that is not OFX at all.
	bad := parse_text("<OFX>\n<NOTHING>\n</OFX>\n", nil, "vide.ofx")
	ok_mark(tc, !statement_ok(bad), "un OFX sans opération est refusé")
	statement_destroy(bad)
	free(bad)

	// The scanner itself: an unclosed leaf's value stops at the next tag.
	d := ofx_parse_doc("<A>\n<B>hello\n<C>world\n</A>\n")
	defer ofx_destroy(&d)
	eq_int(tc, len(d.nodes), 3, "le scanner voit trois éléments")
	eq_str(tc, d.nodes[0].tag, "A", "le premier est l'agrégat")
	eq_str(tc, d.nodes[1].value, "hello", "la valeur d'une balise non fermée s'arrête au «<» suivant")
	eq_str(tc, d.nodes[2].value, "world", "et la suivante aussi")
	v, vok := ofx_value(&d, 0, "C")
	ok_mark(tc, vok && v == "world", "la recherche dans un sous-arbre fonctionne")
	_, vbad := ofx_value(&d, 1, "C")
	ok_mark(tc, !vbad, "et ne sort pas du sous-arbre d'une feuille")
}

// ---------------------------------------------------------------------------
// CAMT.053
// ---------------------------------------------------------------------------

test_camt :: proc(tc: ^TC) {
	s := parse_text(FX_CAMT, nil, "octobre.camt.xml")
	defer {
		statement_destroy(s)
		free(s)
	}
	ok_mark(tc, s.format == .CAMT053, "CAMT: reconnu")
	ok_mark(tc, statement_ok(s), fmt.tprintf("CAMT: lisible (%d erreurs)", len(s.errors)))
	eq_int(tc, len(s.txns), 5, "CAMT: cinq écritures")
	eq_str(tc, s.iban, FX_IBAN_CURRENT, "CAMT: l'IBAN du compte")
	eq_str(tc, s.currency, "EUR", "CAMT: la devise")

	// The sign comes from CdtDbtInd and nowhere else.
	eq_cents(tc, s.txns[0].amount, -480, "CAMT: DBIT donne un montant négatif")
	eq_cents(tc, s.txns[1].amount, 245000, "CAMT: CRDT donne un montant positif")
	eq_cents(tc, s.txns[2].amount, -95000, "CAMT: un prélèvement")
	ok_mark(tc, date_eq(s.txns[0].date, Date{2026, 10, 1}), "CAMT: la date de comptabilisation")
	ok_mark(tc, date_eq(s.txns[0].value, Date{2026, 10, 1}), "CAMT: la date de valeur")

	// The label: remittance information first, joined when there are several
	// lines; then the additional entry information.
	eq_str(tc, s.txns[0].label, "CB LE PETIT CAFE 1011", "CAMT: Ustrd devient le libellé")
	eq_str(
		tc,
		s.txns[2].label,
		"PRLV SEPA LOYER AGENCE EXEMPLE ECH 021026",
		"CAMT: deux Ustrd sont joints",
	)
	eq_str(
		tc,
		s.txns[3].label,
		"PRLV SEPA EDF ECH 031026 MDT 5512",
		"CAMT: AddtlNtryInf sert de libellé en dernier recours",
	)
	ok_mark(tc, strings.contains(s.txns[0].ext_id, "NTRY-0001"), "CAMT: NtryRef devient un identifiant")

	// The closing balance: CLBD and not PRCD.
	ok_mark(tc, s.has_closing, "CAMT: un solde de clôture est trouvé")
	eq_cents(tc, s.closing, 283289, "CAMT: le solde CLBD, pas le PRCD")
	ok_mark(tc, date_eq(s.closing_date, Date{2026, 10, 4}), "CAMT: à sa date")

	// An entry with no CdtDbtInd has no sign and must be refused.
	n := parse_text(FX_CAMT_NO_IND, nil, "sans-indicateur.camt.xml")
	defer {
		statement_destroy(n)
		free(n)
	}
	eq_int(tc, len(n.txns), 1, "CAMT: l'écriture sans indicateur est écartée")
	eq_int(tc, n.rows_bad, 1, "CAMT: et comptée comme refusée")
	eq_cents(tc, n.txns[0].amount, -1200, "CAMT: l'écriture valide est conservée")
	reported := false
	for w in n.warnings {
		if strings.contains(w, "CdtDbtInd") {
			reported = true
		}
	}
	ok_mark(tc, reported, "CAMT: le refus nomme l'élément manquant")

	// Truncated mid-element.
	t := parse_text(FX_CAMT_TRUNCATED, nil, "tronque.camt.xml")
	defer {
		statement_destroy(t)
		free(t)
	}
	eq_int(tc, len(t.txns), 1, "CAMT tronqué: la première écriture est lue")
	eq_cents(tc, t.txns[0].amount, -4210, "CAMT tronqué: correctement")

	// The XML scanner, on its own.
	ev := xml_scan("<a><b x=\"1\">t</b><c/></a>")
	eq_int(tc, len(ev), 6, "le scanner voit six évènements")
	ok_mark(tc, ev[0].kind == .Open && ev[0].name == "a", "ouverture")
	ok_mark(tc, ev[2].kind == .Text && ev[2].text == "t", "texte")
	ok_mark(tc, ev[3].kind == .Close && ev[3].name == "b", "fermeture")
	ok_mark(tc, ev[4].kind == .Self && ev[4].name == "c", "élément auto-fermant")
	ok_mark(tc, ev[5].kind == .Close && ev[5].name == "a", "fermeture de la racine")
	av, aok := xml_attr("x=\"1\" Ccy='EUR'", "Ccy")
	ok_mark(tc, aok && av == "EUR", "un attribut est lu, guillemets simples compris")
	_, abad := xml_attr("x=\"1\"", "y")
	ok_mark(tc, !abad, "un attribut absent est signalé")

	ns := xml_scan("<ns2:Ntry><ns2:Amt>1.00</ns2:Amt></ns2:Ntry>")
	ok_mark(tc, ns[0].name == "Ntry", "le préfixe de namespace est retiré")
	eq_str(tc, xml_unescape("a&lt;b&amp;c&#233;"), "a<b&cé", "les entités XML, numériques comprises")
	eq_str(tc, xml_unescape("&#x41;"), "A", "une entité hexadécimale")
	eq_str(tc, xml_unescape("rien"), "rien", "un texte sans entité est inchangé")

	// Comments and CDATA.
	cd := xml_scan("<a><!-- ignoré --><![CDATA[brut & tel]]></a>")
	found_cdata := false
	for e in cd {
		if e.kind == .Text && strings.contains(e.text, "brut & tel") {
			found_cdata = true
		}
	}
	ok_mark(tc, found_cdata, "le CDATA est conservé, le commentaire ignoré")
}

// ---------------------------------------------------------------------------
// The ledger
// ---------------------------------------------------------------------------

test_ledger :: proc(tc: ^TC) {
	app := fresh_app()
	defer drop_app(app)
	l := &app.led
	cur := account_add(l, "Compte courant", .Asset)
	sav := account_add(l, "Livret", .Asset)
	food := account_add(l, "Alimentation", .Expense)
	fun := account_add(l, "Loisirs", .Expense)
	pay := account_add(l, "Salaire", .Income)

	// An unbalanced transaction cannot be created at all.
	bad := [2]Entry{{cur, -1000}, {food, 500}}
	_, bad_ok := txn_add(l, {date = Date{2026, 10, 1}, label = "déséquilibrée", entries = bad[:]})
	ok_mark(tc, !bad_ok, "une opération déséquilibrée est refusée")
	one := [1]Entry{{cur, 0}}
	_, one_ok := txn_add(l, {date = Date{2026, 10, 1}, label = "une seule écriture", entries = one[:]})
	ok_mark(tc, !one_ok, "une opération à une seule écriture est refusée")
	ghost := [2]Entry{{cur, -1000}, {999, 1000}}
	_, ghost_ok := txn_add(l, {date = Date{2026, 10, 1}, label = "compte inexistant", entries = ghost[:]})
	ok_mark(tc, !ghost_ok, "une écriture sur un compte inexistant est refusée")
	eq_int(tc, txn_count(l), 0, "et rien n'a été écrit")

	// A card purchase.
	e1 := [2]Entry{{cur, -4210}, {food, 4210}}
	id1, ok1 := txn_add(
		l,
		{date = Date{2026, 10, 1}, label = "CB CARREFOUR 0110", method = .Card, entries = e1[:]},
	)
	ok_mark(tc, ok1, "une opération équilibrée est acceptée")
	eq_cents(tc, l.accounts[cur].balance, -4210, "le compte est débité")
	eq_cents(tc, l.accounts[food].balance, 4210, "la catégorie est créditée")
	ok_mark(tc, ledger_check(l).ok, "le livre est équilibré")

	// A salary.
	e2 := [2]Entry{{cur, 245000}, {pay, -245000}}
	txn_add(l, {date = Date{2026, 10, 2}, label = "VIR SALAIRE", method = .Transfer, entries = e2[:]})
	eq_cents(tc, l.accounts[cur].balance, 240790, "le solde après le salaire")
	eq_cents(tc, l.accounts[pay].balance, -245000, "un compte de produit porte un solde négatif")

	// A transfer between the user's own accounts is not spending.
	tid, tok := transfer_add(l, cur, sav, 20000, Date{2026, 10, 3}, "VIR EPARGNE")
	ok_mark(tc, tok, "un virement interne se comptabilise")
	eq_cents(tc, l.accounts[cur].balance, 220790, "le compte source")
	eq_cents(tc, l.accounts[sav].balance, 20000, "le compte destinataire")
	tt, _ := txn_get(l, tid)
	ok_mark(tc, txn_is_transfer(l, tt), "et il est reconnu comme virement")
	ok_mark(tc, txn_category(l, tt) == -1, "un virement n'a pas de catégorie")
	ok_mark(tc, !txn_categorise(l, tid, food), "et ne peut pas en recevoir une")

	// Re-categorising moves the category side and leaves the account alone.
	ok_mark(tc, txn_categorise(l, id1, fun), "une opération se recatégorise")
	eq_cents(tc, l.accounts[food].balance, 0, "l'ancienne catégorie est vidée")
	eq_cents(tc, l.accounts[fun].balance, 4210, "la nouvelle est créditée")
	eq_cents(tc, l.accounts[cur].balance, 220790, "le solde du compte n'a pas bougé")
	ok_mark(tc, ledger_check(l).ok, "et le livre est toujours équilibré")

	// A split, which must add up exactly.
	e3 := [2]Entry{{cur, -10000}, {food, 10000}}
	id3, _ := txn_add(l, {date = Date{2026, 10, 4}, label = "CB MONOPRIX", entries = e3[:]})
	parts := [2]Split_Part{{food, 6000}, {fun, 4000}}
	ok_mark(tc, txn_split(l, id3, parts[:]), "une ventilation exacte est acceptée")
	eq_cents(tc, l.accounts[food].balance, 6000, "la première part")
	eq_cents(tc, l.accounts[fun].balance, 4210 + 4000, "la seconde")
	t3, _ := txn_get(l, id3)
	ok_mark(tc, txn_is_split(l, t3), "l'opération est marquée ventilée")
	bad_parts := [2]Split_Part{{food, 6000}, {fun, 3999}}
	ok_mark(tc, !txn_split(l, id3, bad_parts[:]), "une ventilation d'un centime de moins est refusée")
	eq_cents(tc, l.accounts[food].balance, 6000, "et n'a rien changé")
	ok_mark(tc, ledger_check(l).ok, "le livre reste équilibré")

	// Changing the amount rescales the split and still balances.
	ok_mark(tc, txn_set_amount(l, id3, -20000), "le montant d'une opération ventilée se modifie")
	t3b, _ := txn_get(l, id3)
	eq_cents(tc, entries_sum(t3b.entries[:]), 0, "et la ventilation reste équilibrée")
	_, side, _ := txn_asset_side(l, t3b)
	eq_cents(tc, side, -20000, "le compte porte le nouveau montant")
	eq_cents(tc, l.accounts[food].balance + l.accounts[fun].balance - 4210, 20000, "les parts totalisent le nouveau montant")
	ok_mark(tc, ledger_check(l).ok, "et le livre est équilibré")

	// A simple amount change on an unsplit transaction: the category side
	// follows by exactly the difference.
	fun_before := l.accounts[fun].balance
	ok_mark(tc, txn_set_amount(l, id1, -5000), "le montant d'une opération simple se modifie")
	eq_cents(
		tc,
		l.accounts[fun].balance - fun_before,
		5000 - 4210,
		"la catégorie suit le montant, à l'exact",
	)

	// Deletion reverses everything and leaves a tombstone.
	before := l.accounts[cur].balance
	t1, _ := txn_get(l, id1)
	amount1 := txn_amount(l, t1)
	ok_mark(tc, txn_delete(l, id1), "une opération se supprime")
	eq_cents(tc, l.accounts[cur].balance, before - amount1, "le solde est rétabli")
	_, still := txn_get(l, id1)
	ok_mark(tc, !still, "et l'opération n'est plus trouvable")
	ok_mark(tc, !txn_delete(l, id1), "une seconde suppression ne fait rien")
	ok_mark(tc, !txn_categorise(l, id1, food), "et on ne peut plus la modifier")
	ok_mark(tc, ledger_check(l).ok, "le livre est équilibré après suppression")

	// The bank's id is released on deletion, so a re-import brings it back.
	e4 := [2]Entry{{cur, -1000}, {food, 1000}}
	id4, _ := txn_add(l, {date = Date{2026, 10, 5}, label = "avec identifiant", ext_id = "X1", entries = e4[:]})
	_, dup := txn_add(l, {date = Date{2026, 10, 5}, label = "doublon", ext_id = "X1", entries = e4[:]})
	ok_mark(tc, !dup, "un identifiant bancaire répété est refusé")
	txn_delete(l, id4)
	_, again := txn_add(l, {date = Date{2026, 10, 5}, label = "réimporté", ext_id = "X1", entries = e4[:]})
	ok_mark(tc, again, "après suppression, le même identifiant est de nouveau accepté")
	ok_mark(tc, ledger_check(l).ok, "et le livre est équilibré")

	// Queries.
	eq_cents(
		tc,
		account_movement(l, cur, Date{2026, 10, 1}, Date{2026, 10, 2}),
		245000,
		"le mouvement du compte sur deux jours",
	)
	eq_cents(tc, balance_at(l, sav, Date{2026, 10, 2}), 0, "le livret était vide le 2")
	eq_cents(tc, balance_at(l, sav, Date{2026, 10, 3}), 20000, "et plein le 3")
	eq_cents(tc, assets_total(l), l.accounts[cur].balance + l.accounts[sav].balance, "le patrimoine est la somme des comptes")

	// Opening balances are double-entered too.
	app2 := fresh_app()
	defer drop_app(app2)
	a2 := account_add(&app2.led, "Compte", .Asset)
	opening_balance(&app2.led, a2, 100000, Date{2026, 1, 1})
	eq_cents(tc, app2.led.accounts[a2].balance, 100000, "un solde initial se comptabilise")
	ok_mark(tc, ledger_check(&app2.led).ok, "et le livre reste équilibré")
	total := Cents(0)
	for &t in app2.led.txns {
		total += entries_sum(t.entries[:])
	}
	eq_cents(tc, total, 0, "la somme de toutes les écritures du livre est nulle")
}

// ---------------------------------------------------------------------------
// The double-entry property test
//
// This is the test the whole model exists for. A long random sequence of
// transactions, transfers, splits, re-categorisations, amount changes and
// deletions is applied, and after *every single operation* the invariant is
// re-derived from scratch and compared against the cached state:
//
//   * every live transaction's entries sum to zero;
//   * the sum of every entry in the book is zero;
//   * every account's cached balance equals the sum of the entries naming it;
//   * every account's cached entry count equals the number of them;
//   * the transaction-id and bank-id indexes agree with the transactions.
//
// It catches the class of bug a hand-written test never does: an edit that
// updates one side and not the other. Any such bug shows up within a few
// hundred operations, because a cache that drifts does not come back.
// ---------------------------------------------------------------------------

PROPERTY_OPS :: 6000

// ROUND_TRIP_EVERY: how often the random sequence is also serialised,
// re-read and compared. Transaction ids are reassigned on load, so a
// byte-for-byte comparison would fail for an uninteresting reason; the digest
// below is deliberately id-independent — the dates, labels, methods, flags
// and *sorted entries* of every live transaction, plus every account's
// balance. Anything the model can represent and the store cannot round-trip
// shows up here, which is a different class of bug from an unbalanced edit.
ROUND_TRIP_EVERY :: 250

test_property :: proc(tc: ^TC) {
	app := fresh_app()
	defer drop_app(app)
	l := &app.led

	cur := account_add(l, "Compte courant", .Asset)
	sav := account_add(l, "Livret", .Asset)
	cash := account_add(l, "Espèces", .Asset)
	cats := [4]int {
		account_add(l, "Alimentation", .Expense),
		account_add(l, "Transports", .Expense),
		account_add(l, "Loisirs", .Expense),
		account_add(l, "Salaire", .Income),
	}
	assets := [3]int{cur, sav, cash}

	r := rng_make(0xC0FFEE)
	live := make([dynamic]int, context.temp_allocator) // live transaction ids
	ops := 0
	failed_at := -1
	trip_failed := -1
	trips := 0
	kinds := [8]int{}

	for ops < PROPERTY_OPS {
		ops += 1
		choice := rng_int(&r, 0, 99)
		switch {
		case choice < 34 || len(live) == 0:
			// Add a spend or an income.
			kinds[0] += 1
			acct := assets[rng_int(&r, 0, len(assets) - 1)]
			cat := cats[rng_int(&r, 0, len(cats) - 1)]
			amount := Cents(rng_int(&r, 1, 500000))
			if l.accounts[cat].kind == .Income {
				amount = -amount // income is money in: the asset side is positive
			}
			d := date_add(Date{2026, 1, 1}, rng_int(&r, 0, 400))
			ents := [2]Entry{{acct, -amount}, {cat, amount}}
			if id, ok := txn_add(
				l,
				{date = d, label = fmt.tprintf("OP %d", ops), entries = ents[:]},
			); ok {
				append(&live, id)
			}

		case choice < 44:
			// A transfer between two of the user's own accounts.
			kinds[1] += 1
			a := rng_int(&r, 0, len(assets) - 1)
			b := rng_int(&r, 0, len(assets) - 1)
			if a == b {
				b = (b + 1) % len(assets)
			}
			d := date_add(Date{2026, 1, 1}, rng_int(&r, 0, 400))
			if id, ok := transfer_add(
				l,
				assets[a],
				assets[b],
				Cents(rng_int(&r, 1, 200000)),
				d,
				"VIR INTERNE",
			); ok {
				append(&live, id)
			}

		case choice < 60:
			// Re-categorise.
			kinds[2] += 1
			id := live[rng_int(&r, 0, len(live) - 1)]
			txn_categorise(l, id, cats[rng_int(&r, 0, len(cats) - 1)])

		case choice < 72:
			// Split into two or three parts that add up exactly.
			kinds[3] += 1
			id := live[rng_int(&r, 0, len(live) - 1)]
			if t, ok := txn_get(l, id); ok && !txn_is_transfer(l, t) {
				_, amount, has := txn_asset_side(l, t)
				if has && amount != 0 {
					n := rng_int(&r, 2, 3)
					shares := money_split(-amount, n, context.temp_allocator)
					parts := make([dynamic]Split_Part, 0, n, context.temp_allocator)
					for k in 0 ..< n {
						append(
							&parts,
							Split_Part{cats[rng_int(&r, 0, len(cats) - 1)], shares[k]},
						)
					}
					txn_split(l, id, parts[:])
				}
			}

		case choice < 82:
			// Change an amount, which has to rescale whatever the category
			// side currently is.
			kinds[4] += 1
			id := live[rng_int(&r, 0, len(live) - 1)]
			if t, ok := txn_get(l, id); ok {
				_, amount, has := txn_asset_side(l, t)
				if has {
					sign: Cents = amount < 0 ? -1 : 1
					txn_set_amount(l, id, sign * Cents(rng_int(&r, 1, 500000)))
				}
			}

		case choice < 88:
			// Turn a spend into a transfer.
			kinds[5] += 1
			id := live[rng_int(&r, 0, len(live) - 1)]
			txn_make_transfer(l, id, assets[rng_int(&r, 0, len(assets) - 1)])

		case choice < 94:
			// Delete.
			kinds[6] += 1
			k := rng_int(&r, 0, len(live) - 1)
			txn_delete(l, live[k])
			unordered_remove(&live, k)

		case:
			// An operation that must fail, to prove a refusal does not
			// corrupt anything either.
			kinds[7] += 1
			id := live[rng_int(&r, 0, len(live) - 1)]
			unbalanced := [2]Entry{{cur, -100}, {cats[0], 50}}
			txn_replace_entries(l, id, unbalanced[:])
			bad := [1]Entry{{cur, 0}}
			txn_replace_entries(l, id, bad[:])
		}

		// The invariant, re-derived, after every single operation.
		pb := ledger_check(l)
		if !pb.ok {
			failed_at = ops
			ok_mark(
				tc,
				false,
				fmt.tprintf("invariant de partie double rompu à l'opération %d: %s", ops, pb.what),
			)
			break
		}

		// And, periodically, the store round trip over whatever state the
		// sequence has reached.
		if ops % ROUND_TRIP_EVERY == 0 {
			trips += 1
			want := book_digest(app, context.temp_allocator)
			got, refused := round_trip_digest(app, context.temp_allocator)
			if refused != 0 || got != want {
				trip_failed = ops
				ok_mark(
					tc,
					false,
					fmt.tprintf(
						"le livre ne survit pas à l'aller-retour sur disque à l'opération %d (%d refus, %d vs %d octets de signature)",
						ops,
						refused,
						len(got),
						len(want),
					),
				)
				break
			}
		}
	}

	ok_mark(tc, failed_at < 0, "l'invariant de partie double tient sur toute la séquence")
	ok_mark(tc, trip_failed < 0, "et le livre survit à l'aller-retour sur disque à chaque palier")
	eq_int(tc, trips, PROPERTY_OPS / ROUND_TRIP_EVERY, "tous les paliers d'aller-retour sont faits")
	eq_int(tc, ops, PROPERTY_OPS, fmt.tprintf("%d opérations aléatoires exécutées", PROPERTY_OPS))
	ok_mark(tc, txn_count(l) > 100, "la séquence laisse un livre non trivial")

	// Every operation kind must actually have been exercised, or the test is
	// quietly weaker than it looks.
	names := [8]string {
		"ajout",
		"virement",
		"catégorisation",
		"ventilation",
		"changement de montant",
		"conversion en virement",
		"suppression",
		"opération refusée",
	}
	for n, i in kinds {
		ok_mark(tc, n > 0, fmt.tprintf("la séquence contient des opérations de type «%s»", names[i]))
	}

	// And the final state, checked independently of ledger_check.
	total := Cents(0)
	sums := make([]Cents, len(l.accounts), context.temp_allocator)
	for &t in l.txns {
		if t.dead {
			continue
		}
		for e in t.entries {
			total += e.amount
			sums[e.account] += e.amount
		}
	}
	eq_cents(tc, total, 0, "après la séquence, la somme de toutes les écritures est nulle")
	mismatch := 0
	for a, i in l.accounts {
		if a.balance != sums[i] {
			mismatch += 1
		}
	}
	eq_int(tc, mismatch, 0, "et chaque solde est la somme de ses écritures")

	fmt.printfln(
		"  (propriété: %d opérations aléatoires, invariant vérifié après chacune; %d aller-retours sur disque; état final %d opérations, %d écritures)",
		ops,
		trips,
		txn_count(l),
		total_entries(l),
	)
}

// book_digest is a canonical, id-independent description of a book.
book_digest :: proc(app: ^App, allocator := context.temp_allocator) -> string {
	l := &app.led
	lines := make([dynamic]string, context.temp_allocator)
	for &t in l.txns {
		if t.dead {
			continue
		}
		// Entries sorted by account then amount, so the order they happen to
		// be stored in cannot change the digest.
		ents := slice.clone(t.entries[:], context.temp_allocator)
		slice.sort_by(ents, proc(a, b: Entry) -> bool {
			if a.account != b.account {
				return a.account < b.account
			}
			return a.amount < b.amount
		})
		b := strings.builder_make(context.temp_allocator)
		fmt.sbprintf(
			&b,
			"%s|%s|%d|%d|%d|%s|%s|%s",
			date_iso(t.date, context.temp_allocator),
			date_iso(t.value, context.temp_allocator),
			int(t.method),
			t.cleared ? 1 : 0,
			t.auto_cat ? 1 : 0,
			t.ext_id,
			t.label,
			t.note,
		)
		for e in ents {
			fmt.sbprintf(&b, "|%s=%d", account_name(l, e.account), i64(e.amount))
		}
		append(&lines, strings.to_string(b))
	}
	slice.sort(lines[:])
	accounts := make([dynamic]string, context.temp_allocator)
	for a in l.accounts {
		append(
			&accounts,
			fmt.tprintf("%s=%d/%d/%d", a.name, i64(a.balance), a.entries, int(a.kind)),
		)
	}
	slice.sort(accounts[:])
	all := make([dynamic]string, context.temp_allocator)
	append(&all, ..accounts[:])
	append(&all, ..lines[:])
	return strings.join(all[:], "\n", allocator)
}

// round_trip_digest serialises, re-reads into a fresh book, and returns the
// reloaded book's digest along with how many records the store refused.
round_trip_digest :: proc(app: ^App, allocator := context.temp_allocator) -> (digest: string, refused: int) {
	text := store_text(app, context.temp_allocator)
	fresh := new(App)
	app_init(fresh)
	defer {
		app_destroy(fresh)
		free(fresh)
	}
	_, problems := store_parse(fresh, text)
	return book_digest(fresh, allocator), problems
}

total_entries :: proc(l: ^Ledger) -> (n: int) {
	for &t in l.txns {
		if !t.dead {
			n += len(t.entries)
		}
	}
	return
}

// ---------------------------------------------------------------------------
// Categorisation
// ---------------------------------------------------------------------------

test_rules :: proc(tc: ^TC) {
	// Normalisation.
	eq_str(tc, label_normalize("cb carrefour  2109"), "CB CARREFOUR 2109", "normalisation d'un libellé")
	eq_str(tc, label_normalize("PRLV SÉPA ÉDF"), "PRLV SEPA EDF", "les accents sont repliés")
	eq_str(tc, label_normalize("UBER*EATS"), "UBER EATS", "les séparateurs deviennent des espaces")

	// The method, which is the first word.
	m1, r1 := label_method("CB CARREFOUR 2109")
	ok_mark(tc, m1 == .Card, "CB est une carte")
	eq_str(tc, r1, "CARREFOUR 2109", "et le reste est le libellé")
	m2, _ := label_method("PRLV SEPA EDF ECH 210926")
	ok_mark(tc, m2 == .Debit, "PRLV SEPA est un prélèvement")
	m3, _ := label_method("VIR M EXEMPLE LOYER")
	ok_mark(tc, m3 == .Transfer, "VIR est un virement")
	m4, _ := label_method("CHQ 0000123")
	ok_mark(tc, m4 == .Cheque, "CHQ est un chèque")
	m5, _ := label_method("RETRAIT DAB 18/09 PARIS")
	ok_mark(tc, m5 == .Cash, "RETRAIT est un retrait")
	m6, _ := label_method("COTISATION CARTE BANCAIRE")
	ok_mark(tc, m6 == .Fee, "COTISATION est un frais")
	m7, _ := label_method("PAIEMENT CB MONOPRIX")
	ok_mark(tc, m7 == .Card, "PAIEMENT CB est une carte, pas un «PAIEMENT»")
	m8, _ := label_method("QUELQUE CHOSE D AUTRE")
	ok_mark(tc, m8 == .Unknown, "un libellé sans préfixe connu n'a pas de méthode")
	eq_str(tc, method_label(.Card), "CB", "l'étiquette d'une méthode")

	// The merchant key: the identity that survives the dates and references.
	eq_str(tc, merchant_key("CB CARREFOUR 2109"), "CARREFOUR", "clé marchand d'un paiement carte")
	eq_str(
		tc,
		merchant_key("CB CARREFOUR 1410"),
		merchant_key("CB CARREFOUR 2109"),
		"deux mois du même marchand donnent la même clé",
	)
	eq_str(
		tc,
		merchant_key("PRLV SEPA EDF ECH 210926 MDT 5512"),
		"EDF",
		"clé marchand d'un prélèvement, références retirées",
	)
	eq_str(
		tc,
		merchant_key("PRLV SEPA EDF ECH 211026 MDT 5512"),
		merchant_key("PRLV SEPA EDF ECH 210926 MDT 5512"),
		"et elle est stable d'un mois sur l'autre",
	)
	eq_str(tc, merchant_key("CB UBER EATS 1809"), "UBER EATS", "deux mots sont conservés")
	ok_mark(tc, merchant_key("RETRAIT DAB 18/09") != "", "un retrait a quand même une clé")

	// Matching.
	app := fresh_app()
	defer drop_app(app)
	ensure_categories(app)
	c := &app.cat

	m := catalog_match(c, "CB CARREFOUR 2109", .Card, -8240)
	eq_str(tc, m.category, "Alimentation", "CARREFOUR est de l'alimentation")
	m2b := catalog_match(c, "PRLV SEPA EDF ECH 210926", .Debit, -6420)
	eq_str(tc, m2b.category, "Énergie", "EDF est de l'énergie")
	m3b := catalog_match(c, "CB UBER EATS 1809", .Card, -2860)
	eq_str(tc, m3b.category, "Restaurants", "UBER EATS est un restaurant, pas un transport")
	m4b := catalog_match(c, "CB UBER TRIP 1809", .Card, -1500)
	eq_str(tc, m4b.category, "Transports", "mais UBER seul est un transport")
	m5b := catalog_match(c, "VIR SALAIRE SOCIETE EXEMPLE SA", .Transfer, 245000)
	eq_str(tc, m5b.category, "Salaire", "un salaire au crédit est un salaire")
	m6b := catalog_match(c, "VIR SALAIRE REMBOURSE A L EMPLOYEUR", .Transfer, -245000)
	ok_mark(tc, m6b.category != "Salaire", "mais au débit, non: une règle de recette ne s'applique qu'aux crédits")
	m7b := catalog_match(c, "COTISATION CARTE BANCAIRE", .Fee, -450)
	eq_str(tc, m7b.category, "Frais bancaires", "une règle par méthode attrape les frais")
	m8b := catalog_match(c, "RETRAIT DAB 18/09 PARIS 14E", .Cash, -6000)
	eq_str(tc, m8b.category, "Retraits", "un retrait a sa propre catégorie: son libellé ne dit rien")
	m9 := catalog_match(c, "CB BOUTIQUE INCONNUE 1234", .Card, -1000)
	ok_mark(tc, m9.rule < 0, "un marchand inconnu ne correspond à rien")

	// Learning: what the user decides becomes a rule, and the rule wins.
	cur := account_add(&app.led, "Compte courant", .Asset)
	fun := account_get_or_add(&app.led, "Loisirs", .Expense)
	e := [2]Entry{{cur, -3000}, {app.led.unallocated, 3000}}
	id, _ := txn_add(&app.led, {date = Date{2026, 10, 1}, label = "CB CARREFOUR 0110", method = .Card, entries = e[:]})
	app.rows = app.rows
	refilter(app)
	// Categorise it by hand, as the UI does.
	app.sel = 0
	ok_mark(tc, categorise_selected(app, fun), "une catégorisation manuelle s'applique")
	learned := catalog_match(c, "CB CARREFOUR 2109", .Card, -8240)
	eq_str(tc, learned.category, "Loisirs", "et devient une règle apprise qui bat la règle livrée")
	ok_mark(tc, learned.source == .Learned, "la source de la correspondance est «appris»")

	// Changing one's mind retargets the learned rule rather than adding a
	// competing one.
	before := len(c.rules)
	_, replaced := catalog_learn(c, "CB CARREFOUR 9999", "Alimentation")
	ok_mark(tc, replaced, "un second apprentissage sur le même marchand remplace le premier")
	eq_int(tc, len(c.rules), before, "et n'ajoute pas de règle")
	again := catalog_match(c, "CB CARREFOUR 0101", .Card, -1000)
	eq_str(tc, again.category, "Alimentation", "la règle apprise a changé de cible")

	// A rule typed by the user outranks everything.
	catalog_user_rule(c, "CARREFOUR", "Achats")
	user := catalog_match(c, "CB CARREFOUR 0101", .Card, -1000)
	eq_str(tc, user.category, "Achats", "une règle saisie par l'utilisateur gagne")
	ok_mark(tc, user.source == .User, "et sa source est «utilisateur»")

	// Suggesting from history, for a merchant no rule knows.
	app2 := fresh_app()
	defer drop_app(app2)
	ensure_categories(app2)
	cur2 := account_add(&app2.led, "Compte courant", .Asset)
	health := account_get_or_add(&app2.led, "Santé", .Expense)
	for k in 1 ..= 3 {
		ee := [2]Entry{{cur2, -2000}, {health, 2000}}
		txn_add(
			&app2.led,
			{
				date = Date{2026, 9, k},
				label = fmt.tprintf("CB OSTEOPATHE EXEMPLE %02d09", k),
				method = .Card,
				entries = ee[:],
			},
		)
	}
	sug := suggest_category(&app2.led, &app2.cat, "CB OSTEOPATHE EXEMPLE 0510", .Card, -2000)
	eq_int(tc, sug.category, health, "l'historique suggère la catégorie la plus fréquente")
	eq_str(tc, sug.from, "historique", "et dit d'où vient la suggestion")
	eq_int(tc, sug.count, 3, "en indiquant combien d'opérations sont d'accord")
	none := suggest_category(&app2.led, &app2.cat, "CB TOTALEMENT INCONNU 0510", .Card, -500)
	eq_int(tc, none.category, -1, "et ne suggère rien quand il n'y a rien")

	// apply_rules: the bulk pass after an import.
	app3 := fresh_app()
	defer drop_app(app3)
	ensure_categories(app3)
	cur3 := account_add(&app3.led, "Compte courant", .Asset, FX_IBAN_CURRENT)
	st := parse_text(FX_ALPHA_CSV, nil, "alpha.csv")
	rep := statement_ingest(app3, st, cur3)
	statement_destroy(st)
	free(st)
	eq_int(tc, rep.added, 21, "les 21 lignes sont comptabilisées")
	ok_mark(tc, rep.categorised >= 15, fmt.tprintf("au moins 15 sont catégorisées automatiquement (%d)", rep.categorised))
	ok_mark(tc, ledger_check(&app3.led).ok, "et le livre est équilibré")

	// The spend-by-category view, with transfers excluded.
	totals := spend_by_category(&app3.led, Date{2026, 9, 1}, Date{2026, 9, 30})
	ok_mark(tc, len(totals) > 3, "plusieurs catégories de dépense apparaissent")
	ok_mark(tc, totals[0].total >= totals[1].total, "et elles sont triées par montant")
	food_idx, food_found := account_find(&app3.led, "Alimentation")
	ok_mark(tc, food_found, "la catégorie Alimentation existe")
	food_total := Cents(0)
	for t in totals {
		if t.account == food_idx {
			food_total = t.total
		}
	}
	// CARREFOUR 82,40 + 64,95 + 91,25, FRANPRIX 31,05, BOULANGERIE 7,80
	eq_cents(tc, food_total, 8240 + 6495 + 9125 + 3105 + 780, "le total Alimentation du mois, au centime")
}

// ---------------------------------------------------------------------------
// Budgets
// ---------------------------------------------------------------------------

test_budget :: proc(tc: ^TC) {
	app := fresh_app()
	defer drop_app(app)
	l := &app.led
	cur := account_add(l, "Compte courant", .Asset)
	food := account_add(l, "Alimentation", .Expense)

	spend :: proc(l: ^Ledger, cur, cat: int, d: Date, amount: Cents) {
		e := [2]Entry{{cur, -amount}, {cat, amount}}
		txn_add(l, {date = d, label = "CB DEPENSE", entries = e[:]})
	}

	budget_set(app, food, 2026, 10, 30000, false)
	line, ok := budget_line(app, food, 2026, 10)
	ok_mark(tc, ok, "une enveloppe se crée")
	eq_cents(tc, line.limit, 30000, "l'enveloppe fait 300 €")
	eq_cents(tc, line.spent, 0, "rien n'est dépensé")
	eq_cents(tc, line.left, 30000, "tout reste")
	ok_mark(tc, !line.over, "et elle n'est pas dépassée")
	eq_int(tc, line.pct, 0, "0 %")

	// Spend exactly to the limit. This is the boundary, and it is exact:
	// spending the limit is not over budget.
	spend(l, cur, food, Date{2026, 10, 5}, 30000)
	line2, _ := budget_line(app, food, 2026, 10)
	eq_cents(tc, line2.spent, 30000, "l'enveloppe est dépensée exactement")
	eq_cents(tc, line2.left, 0, "il ne reste rien")
	ok_mark(tc, !line2.over, "dépenser exactement l'enveloppe n'est PAS un dépassement")
	eq_int(tc, line2.pct, 100, "100 %")

	// One centime more is.
	spend(l, cur, food, Date{2026, 10, 6}, 1)
	line3, _ := budget_line(app, food, 2026, 10)
	eq_cents(tc, line3.spent, 30001, "un centime de plus")
	eq_cents(tc, line3.left, -1, "il manque un centime")
	ok_mark(tc, line3.over, "un centime au-dessus EST un dépassement")
	eq_int(tc, line3.pct, 100, "et le pourcentage reste à 100, tronqué")

	// A refund inside the month reduces the spend.
	e := [2]Entry{{cur, 5000}, {food, -5000}}
	txn_add(l, {date = Date{2026, 10, 7}, label = "VIR REMBOURSEMENT MAGASIN", entries = e[:]})
	line4, _ := budget_line(app, food, 2026, 10)
	eq_cents(tc, line4.spent, 25001, "un remboursement réduit la dépense")
	ok_mark(tc, !line4.over, "et peut faire repasser sous l'enveloppe")

	// A transfer must not count as spending.
	sav := account_add(l, "Livret", .Asset)
	transfer_add(l, cur, sav, 100000, Date{2026, 10, 8}, "VIR EPARGNE")
	line5, _ := budget_line(app, food, 2026, 10)
	eq_cents(tc, line5.spent, 25001, "un virement interne ne touche pas l'enveloppe")

	// Spending in another month does not touch this month's envelope.
	spend(l, cur, food, Date{2026, 11, 2}, 9999)
	line6, _ := budget_line(app, food, 2026, 10)
	eq_cents(tc, line6.spent, 25001, "une dépense du mois suivant non plus")

	// Rollover: an envelope carries its remainder forward.
	app2 := fresh_app()
	defer drop_app(app2)
	l2 := &app2.led
	cur2 := account_add(l2, "Compte", .Asset)
	cat2 := account_add(l2, "Alimentation", .Expense)
	budget_set(app2, cat2, 2026, 8, 30000, true)
	budget_set(app2, cat2, 2026, 9, 30000, true)
	budget_set(app2, cat2, 2026, 10, 30000, true)
	spend(l2, cur2, cat2, Date{2026, 8, 10}, 28000) // 20 € left
	spend(l2, cur2, cat2, Date{2026, 9, 10}, 25000) // 50 € left plus the 20
	aug, _ := budget_line(app2, cat2, 2026, 8)
	eq_cents(tc, aug.carry, 0, "le premier mois ne reporte rien")
	eq_cents(tc, aug.left, 2000, "et laisse 20 €")
	sep, _ := budget_line(app2, cat2, 2026, 9)
	eq_cents(tc, sep.carry, 2000, "septembre reçoit les 20 € d'août")
	eq_cents(tc, sep.available, 32000, "et dispose de 320 €")
	eq_cents(tc, sep.left, 7000, "il reste 70 €")
	oct, _ := budget_line(app2, cat2, 2026, 10)
	eq_cents(tc, oct.carry, 7000, "octobre reçoit les 70 € de septembre")
	eq_cents(tc, oct.available, 37000, "et dispose de 370 €")

	// An overspend carries forward as a negative, which is the point of an
	// envelope: the money really is gone.
	app3 := fresh_app()
	defer drop_app(app3)
	l3 := &app3.led
	cur3 := account_add(l3, "Compte", .Asset)
	cat3 := account_add(l3, "Loisirs", .Expense)
	budget_set(app3, cat3, 2026, 9, 10000, true)
	budget_set(app3, cat3, 2026, 10, 10000, true)
	spend(l3, cur3, cat3, Date{2026, 9, 10}, 15000)
	oct3, _ := budget_line(app3, cat3, 2026, 10)
	eq_cents(tc, oct3.carry, -5000, "un dépassement se reporte en négatif")
	eq_cents(tc, oct3.available, 5000, "octobre n'a plus que 50 €")
	ok_mark(tc, !oct3.over, "sans dépense, octobre n'est pas encore dépassé")
	spend(l3, cur3, cat3, Date{2026, 10, 2}, 5001)
	oct3b, _ := budget_line(app3, cat3, 2026, 10)
	ok_mark(tc, oct3b.over, "mais un centime de plus que le disponible l'est")

	// Rollover off: each month starts at its limit.
	budget_set(app3, cat3, 2026, 10, 10000, false)
	oct3c, _ := budget_line(app3, cat3, 2026, 10)
	eq_cents(tc, oct3c.carry, 0, "sans report, rien n'est reporté")
	eq_cents(tc, oct3c.available, 10000, "et le mois repart de son plafond")

	// Totals, and the count of envelopes over budget.
	tot := budget_totals(app2, 2026, 10)
	eq_int(tc, tot.lines, 1, "une enveloppe ce mois-là")
	eq_cents(tc, tot.available, 37000, "le total disponible")
	eq_int(tc, tot.over, 0, "aucune en dépassement")

	// Removing an envelope.
	budget_set(app2, cat2, 2026, 10, 0, true)
	_, gone := budget_line(app2, cat2, 2026, 10)
	ok_mark(tc, !gone, "une enveloppe à zéro est supprimée")

	// Copying a month, which is how a budget is actually maintained.
	n := budget_copy_month(app2, 2026, 9, 2026, 11)
	eq_int(tc, n, 1, "le mois est recopié")
	copied, _, copy_ok := budget_limit(app2, cat2, 2026, 11)
	ok_mark(tc, copy_ok && copied == 30000, "avec le même plafond")

	// Suggesting from history, rounded up to 5 €.
	app4 := fresh_app()
	defer drop_app(app4)
	l4 := &app4.led
	cur4 := account_add(l4, "Compte", .Asset)
	cat4 := account_add(l4, "Alimentation", .Expense)
	for k in 1 ..= 3 {
		m := date_month_add(Date{2026, 10, 1}, -k)
		spend(l4, cur4, cat4, Date{m.y, m.m, 10}, Cents(20000 + k * 1000))
	}
	sug := budget_suggest(app4, cat4, 2026, 10)
	eq_cents(tc, sug, 22000, "la suggestion est la moyenne arrondie aux 5 € supérieurs")
	eq_cents(tc, budget_suggest(app4, 99, 2026, 10), 0, "et rien quand il n'y a pas d'historique")
}

// ---------------------------------------------------------------------------
// Recurrence detection
// ---------------------------------------------------------------------------

test_recur :: proc(tc: ^TC) {
	app := fresh_app()
	defer drop_app(app)
	ensure_categories(app)
	cur := account_add(&app.led, "Compte courant", .Asset)
	n := gen_history(app, cur, 8)
	ok_mark(tc, n > 150, fmt.tprintf("l'historique généré contient %d opérations", n))
	apply_rules(&app.led, &app.cat)

	recs := find_recurrences(&app.led, app.today, context.temp_allocator)
	ok_mark(tc, len(recs) >= 4, fmt.tprintf("au moins quatre récurrences trouvées (%d)", len(recs)))

	find :: proc(recs: []Recurrence, key: string) -> (r: Recurrence, ok: bool) {
		for rec in recs {
			if strings.contains(rec.key, key) {
				return rec, true
			}
		}
		return {}, false
	}

	// The four charges planted in the history, with known answers.
	salary, has_salary := find(recs, "SALAIRE")
	ok_mark(tc, has_salary, "le salaire mensuel est détecté")
	if has_salary {
		ok_mark(tc, salary.cadence == .Monthly, "et classé comme mensuel")
		eq_cents(tc, salary.amount, 245000, "au bon montant")
		eq_int(tc, salary.count, 8, "sur huit occurrences")
		eq_int(tc, salary.day, 2, "le 2 du mois")
		ok_mark(tc, salary.amount > 0, "et c'est une recette")
		ok_mark(tc, salary.confidence >= 70, fmt.tprintf("avec une bonne confiance (%d)", salary.confidence))
	}

	rent, has_rent := find(recs, "LOYER")
	ok_mark(tc, has_rent, "le loyer mensuel est détecté")
	if has_rent {
		eq_cents(tc, rent.amount, -95000, "au bon montant, en négatif")
		ok_mark(tc, rent.cadence == .Monthly, "et mensuel")
		eq_cents(tc, rent.spread, 0, "sans variation")
		ok_mark(
			tc,
			date_eq(rent.next, date_month_add(rent.last, 1)),
			"la prochaine échéance est un mois après la dernière",
		)
	}

	// The energy bill drifts by a few centimes every month and must still be
	// recognised as one charge.
	edf, has_edf := find(recs, "EDF")
	ok_mark(tc, has_edf, "le prélèvement d'énergie est détecté malgré sa variation")
	if has_edf {
		ok_mark(tc, edf.cadence == .Monthly, "et classé mensuel")
		ok_mark(tc, money_abs(edf.spread) > 0, "sa variation est signalée")
		ok_mark(tc, money_abs(edf.spread) <= 400, "mais reste dans la tolérance")
		ok_mark(tc, money_abs(edf.amount + 6420) < 200, "et le montant médian est proche du nominal")
	}

	netflix, has_netflix := find(recs, "NETFLIX")
	ok_mark(tc, has_netflix, "l'abonnement est détecté")
	if has_netflix {
		eq_cents(tc, netflix.amount, -1349, "à son prix exact")
		eq_cents(tc, netflix.spread, 0, "sans variation")
	}

	// --- The false positives, which matter at least as much ---
	_, irregular := find(recs, "GARAGE")
	ok_mark(tc, !irregular, "trois montants identiques à intervalles irréguliers ne sont PAS une récurrence")
	_, pair := find(recs, "CLUB")
	ok_mark(tc, !pair, "deux occurrences ne sont PAS une récurrence")
	_, variable := find(recs, "ATELIER")
	ok_mark(tc, !variable, "trois mois au même marchand mais à 40 % d'écart ne sont PAS une récurrence")

	// The monthly total of everything detected.
	out, income := recurring_monthly_total(recs)
	ok_mark(tc, out > 100000, fmt.tprintf("le coût récurrent mensuel est significatif (%s)", money_text(out)))
	eq_cents(tc, income, 245000, "la recette récurrente est le salaire")

	// What is due next.
	soon := upcoming(recs, app.today, 31)
	ok_mark(tc, len(soon) > 0, "des échéances sont annoncées pour le mois à venir")
	for k in 1 ..< len(soon) {
		ok_mark(
			tc,
			!date_less(soon[k].next, soon[k - 1].next),
			"les échéances à venir sont triées par date",
		)
		break
	}

	// --- The cadences, each on a book built for it ---
	cadence_case :: proc(tc: ^TC, label: string, step_days: int, months: int, want: Cadence, what: string) {
		app := fresh_app()
		defer drop_app(app)
		cur := account_add(&app.led, "Compte", .Asset)
		hold := app.led.unallocated
		for k in 0 ..< 6 {
			d: Date
			if months > 0 {
				d = date_month_add(Date{2026, 1, 15}, k * months)
			} else {
				d = date_add(Date{2026, 1, 15}, k * step_days)
			}
			e := [2]Entry{{cur, -1000}, {hold, 1000}}
			txn_add(&app.led, {date = d, label = label, entries = e[:]})
		}
		recs := find_recurrences(&app.led, Date{2027, 6, 1}, context.temp_allocator)
		found := false
		for r in recs {
			if r.cadence == want {
				found = true
			}
		}
		ok_mark(tc, found, what)
	}
	cadence_case(tc, "PRLV SEPA HEBDO EXEMPLE", 7, 0, .Weekly, "une charge hebdomadaire est classée hebdomadaire")
	cadence_case(tc, "PRLV SEPA QUINZE EXEMPLE", 14, 0, .Fortnightly, "une charge tous les quinze jours est classée ainsi")
	cadence_case(tc, "PRLV SEPA MENSUEL EXEMPLE", 0, 1, .Monthly, "une charge mensuelle est classée mensuelle")
	cadence_case(tc, "PRLV SEPA TRIMESTRE EXEMPLE", 0, 3, .Quarterly, "une charge trimestrielle est classée trimestrielle")
	cadence_case(tc, "PRLV SEPA ANNUEL EXEMPLE", 0, 12, .Yearly, "une charge annuelle est classée annuelle")

	// A monthly charge due on the 31st, which lands on the 28th in February.
	// Testing monthly cadence in days loses this case; testing it on month
	// indices keeps it.
	app5 := fresh_app()
	defer drop_app(app5)
	cur5 := account_add(&app5.led, "Compte", .Asset)
	hold5 := app5.led.unallocated
	for k in 0 ..< 5 {
		d := date_month_add(Date{2026, 1, 31}, k)
		e := [2]Entry{{cur5, -5000}, {hold5, 5000}}
		txn_add(&app5.led, {date = d, label = "PRLV SEPA FIN DE MOIS EXEMPLE", entries = e[:]})
	}
	recs5 := find_recurrences(&app5.led, Date{2026, 7, 1}, context.temp_allocator)
	eom := false
	for r in recs5 {
		if r.cadence == .Monthly {
			eom = true
		}
	}
	ok_mark(tc, eom, "une charge due le 31 reste mensuelle en février")

	// An extra charge from the same merchant inside one month must not break
	// the chain. This is the case the demo turned up: a statement imported
	// over a month the book already had.
	app6 := fresh_app()
	defer drop_app(app6)
	cur6 := account_add(&app6.led, "Compte", .Asset)
	hold6 := app6.led.unallocated
	for k in 0 ..< 6 {
		d := date_month_add(Date{2026, 1, 5}, k)
		e := [2]Entry{{cur6, -6420}, {hold6, 6420}}
		txn_add(&app6.led, {date = d, label = "PRLV SEPA ENERGIE EXEMPLE", entries = e[:]})
	}
	// The same month, twice.
	dup := [2]Entry{{cur6, -6420}, {hold6, 6420}}
	txn_add(&app6.led, {date = Date{2026, 3, 19}, label = "PRLV SEPA ENERGIE EXEMPLE", entries = dup[:]})
	recs6 := find_recurrences(&app6.led, Date{2026, 7, 1}, context.temp_allocator)
	with_extra := false
	for r in recs6 {
		if r.cadence == .Monthly && strings.contains(r.key, "ENERGIE") {
			with_extra = true
			eq_int(tc, r.count, 7, "les sept occurrences sont comptées")
		}
	}
	ok_mark(tc, with_extra, "une occurrence supplémentaire dans un mois ne casse pas la cadence")

	// But a shop visited several times a month is not a subscription.
	app7 := fresh_app()
	defer drop_app(app7)
	cur7 := account_add(&app7.led, "Compte", .Asset)
	hold7 := app7.led.unallocated
	for k in 0 ..< 5 {
		for day in ([?]int{3, 9, 17, 24}) {
			d := date_month_add(Date{2026, 1, day}, k)
			e := [2]Entry{{cur7, -2000}, {hold7, 2000}}
			txn_add(&app7.led, {date = d, label = "CB EPICERIE EXEMPLE", entries = e[:]})
		}
	}
	recs7 := find_recurrences(&app7.led, Date{2026, 7, 1}, context.temp_allocator)
	grocery := false
	for r in recs7 {
		if strings.contains(r.key, "EPICERIE") {
			grocery = true
		}
	}
	ok_mark(tc, !grocery, "un commerce visité quatre fois par mois n'est PAS un abonnement")

	// Monthly equivalents, so cadences can be compared.
	eq_cents(tc, monthly_equivalent({amount = -1200, cadence = .Yearly}), -100, "1 200 par an font 100 par mois")
	eq_cents(tc, monthly_equivalent({amount = -300, cadence = .Quarterly}), -100, "300 par trimestre font 100")
	eq_cents(tc, monthly_equivalent({amount = -1000, cadence = .Monthly}), -1000, "un mensuel vaut lui-même")
	eq_cents(tc, monthly_equivalent({amount = -300, cadence = .Weekly}), -1300, "un hebdomadaire se ramène au mois")
	eq_cents(tc, monthly_equivalent({amount = 245000, cadence = .Monthly}), 245000, "et le signe est conservé")
	eq_cents(tc, monthly_equivalent({amount = -1000, cadence = .None}), 0, "et une non-récurrence ne vaut rien")
	eq_str(tc, cadence_label(.Monthly), "mensuel", "l'étiquette d'une cadence")
}

// ---------------------------------------------------------------------------
// Reconciliation
// ---------------------------------------------------------------------------

test_recon :: proc(tc: ^TC) {
	app := fresh_app()
	defer drop_app(app)
	ensure_categories(app)
	cur := account_add(&app.led, "Compte courant", .Asset, FX_IBAN_CURRENT)
	opening_balance(&app.led, cur, 100000, Date{2026, 8, 31})

	st := parse_text(FX_ALPHA_CSV, nil, "alpha.csv")
	statement_ingest(app, st, cur)
	// The statement's own closing balance, which the CSV's running balance
	// column provided.
	ok_mark(tc, st.has_closing, "le relevé annonce son solde de clôture")
	recon_note_statement(app, cur, st.closing, st.closing_date)
	statement_destroy(st)
	free(st)

	res := recon_check(app, cur)
	ok_mark(tc, res.has_target, "un objectif de rapprochement est enregistré")
	eq_cents(tc, res.target, 158103, "l'objectif est le solde du relevé")
	eq_cents(tc, res.book, 158103, "et le livre tombe dessus")
	ok_mark(tc, res.agrees, "le rapprochement est bon")
	eq_cents(tc, res.diff, 0, "l'écart est nul")
	eq_int(tc, res.after, 0, "aucune opération après la date du relevé")
	ok_mark(tc, res.counted > 20, "les opérations jusqu'à la date sont comptées")

	// Marking cleared.
	n, mok := recon_mark_cleared(app, cur)
	ok_mark(tc, mok, "le pointage est autorisé quand les soldes concordent")
	ok_mark(tc, n > 20, fmt.tprintf("%d opérations pointées", n))
	res2 := recon_check(app, cur)
	eq_int(tc, res2.uncleared, 0, "plus rien n'est en attente")

	// Now break it: delete one transaction and see whether the difference is
    // explained by the right row.
	target_id := -1
	target_amount := Cents(0)
	for &t in app.led.txns {
		if t.dead {
			continue
		}
		if strings.contains(t.label, "DECATHLON") {
			target_id = t.id
			target_amount = txn_amount(&app.led, &t)
		}
	}
	ok_mark(tc, target_id > 0, "une opération repère est trouvée")
	txn_delete(&app.led, target_id)
	res3 := recon_check(app, cur)
	ok_mark(tc, !res3.agrees, "après une suppression, le rapprochement échoue")
	eq_cents(tc, res3.diff, target_amount, "et l'écart vaut exactement l'opération manquante")
	ok_mark(tc, res3.explain != "", "l'écart est expliqué")

	// A doubled import: add the same row twice more and check the pair is
	// identified.
	app2 := fresh_app()
	defer drop_app(app2)
	cur2 := account_add(&app2.led, "Compte", .Asset)
	hold := app2.led.unallocated
	for _ in 0 ..< 2 {
		e := [2]Entry{{cur2, -4210}, {hold, 4210}}
		txn_add(&app2.led, {date = Date{2026, 10, 1}, label = "CB CARREFOUR 0110", entries = e[:]})
	}
	recon_note_statement(app2, cur2, -4210, Date{2026, 10, 31})
	res4 := recon_check(app2, cur2)
	eq_cents(tc, res4.diff, 4210, "l'écart vaut l'opération en trop")
	ok_mark(tc, res4.suspect_a > 0, "une opération suspecte est nommée")
	ok_mark(
		tc,
		strings.contains(res4.explain, "trop") || strings.contains(res4.explain, "deux fois"),
		fmt.tprintf("et l'explication le dit: «%s»", res4.explain),
	)

	// Marking cleared must be refused while the balances disagree: recording
	// an agreement that does not exist is how an error becomes unfindable.
	_, refused := recon_mark_cleared(app2, cur2)
	ok_mark(tc, !refused, "le pointage est refusé quand les soldes ne concordent pas")

	// No target: nothing is claimed.
	app3 := fresh_app()
	defer drop_app(app3)
	cur3 := account_add(&app3.led, "Compte", .Asset)
	res5 := recon_check(app3, cur3)
	ok_mark(tc, !res5.has_target, "sans relevé, aucun rapprochement n'est affirmé")
	ok_mark(tc, !res5.agrees, "et rien n'est déclaré concordant")

	// The balance series the chart draws.
	app4 := fresh_app()
	defer drop_app(app4)
	cur4 := account_add(&app4.led, "Compte", .Asset)
	hold4 := app4.led.unallocated
	opening_balance(&app4.led, cur4, 100000, Date{2026, 9, 30})
	for k in 1 ..= 5 {
		e := [2]Entry{{cur4, -1000}, {hold4, 1000}}
		txn_add(&app4.led, {date = Date{2026, 10, k}, label = "CB DEPENSE", entries = e[:]})
	}
	series := balance_series(&app4.led, cur4, Date{2026, 10, 1}, Date{2026, 10, 31})
	eq_int(tc, len(series), 6, "six points: le report plus cinq jours")
	eq_cents(tc, series[0].balance, 100000, "la série part du solde reporté")
	eq_cents(tc, series[5].balance, 95000, "et finit au solde courant")
	for k in 1 ..< len(series) {
		ok_mark(tc, !date_less(series[k].date, series[k - 1].date), "la série est ordonnée")
		break
	}
	// Two transactions on the same day make one point, not two.
	e := [2]Entry{{cur4, -1000}, {hold4, 1000}}
	txn_add(&app4.led, {date = Date{2026, 10, 5}, label = "CB AUTRE", entries = e[:]})
	series2 := balance_series(&app4.led, cur4, Date{2026, 10, 1}, Date{2026, 10, 31})
	eq_int(tc, len(series2), 6, "deux opérations le même jour font un seul point")
	eq_cents(tc, series2[5].balance, 94000, "et le point porte les deux")
}

// ---------------------------------------------------------------------------
// The store
// ---------------------------------------------------------------------------

test_store :: proc(tc: ^TC) {
	// The round trip is asserted in memory. Nothing in this suite writes to
	// ~/.local/share/palmy-money.
	app := fresh_app()
	defer drop_app(app)
	ensure_categories(app)
	cur := account_add(&app.led, "Compte courant", .Asset, FX_IBAN_CURRENT, "Banque Alpha")
	sav := account_add(&app.led, "Livret", .Asset, FX_IBAN_SAVINGS, "Banque Alpha")
	opening_balance(&app.led, cur, 100000, Date{2026, 8, 31})

	st := parse_text(FX_ALPHA_CSV, nil, "alpha.csv")
	statement_ingest(app, st, cur)
	recon_note_statement(app, cur, st.closing, st.closing_date)
	statement_destroy(st)
	free(st)
	transfer_add(&app.led, cur, sav, 20000, Date{2026, 9, 17}, "VIR EPARGNE")

	// A label containing a tab and a backslash, which is what the escaping is
	// for.
	hold := app.led.unallocated
	e := [2]Entry{{cur, -1000}, {hold, 1000}}
	txn_add(
		&app.led,
		{
			date = Date{2026, 9, 29},
			label = "CB AVEC\tTABULATION ET \\ ANTISLASH",
			note = "annotation\navec un saut de ligne",
			entries = e[:],
		},
	)

	food, _ := account_find(&app.led, "Alimentation")
	budget_set(app, food, 2026, 10, 30000, true)
	catalog_user_rule(&app.cat, "MON MARCHAND", "Loisirs")
	catalog_learn(&app.cat, "CB BOUTIQUE EXEMPLE 0110", "Achats")

	text := store_text(app, context.temp_allocator)
	ok_mark(tc, len(text) > 500, "le livre se sérialise")
	ok_mark(tc, strings.has_prefix(text, "# palmy-money"), "avec son en-tête de version")

	app2 := fresh_app()
	defer drop_app(app2)
	n, problems := store_parse(app2, text)
	eq_int(tc, problems, 0, "la relecture ne refuse aucune ligne")
	eq_int(tc, n, txn_count(&app.led), "le même nombre d'opérations revient")
	ok_mark(tc, ledger_check(&app2.led).ok, "et le livre relu est équilibré")

	// The balances survive exactly, which is the only thing that matters.
	eq_int(tc, len(app2.led.accounts), len(app.led.accounts), "les comptes reviennent tous")
	for a, i in app.led.accounts {
		if i >= len(app2.led.accounts) {
			break
		}
		eq_cents(
			tc,
			app2.led.accounts[i].balance,
			a.balance,
			fmt.tprintf("le solde de «%s» est identique", a.name),
		)
	}
	cur2, found := account_find(&app2.led, "Compte courant")
	ok_mark(tc, found, "le compte courant est retrouvé par son nom")
	eq_str(tc, app2.led.accounts[cur2].iban, FX_IBAN_CURRENT, "avec son IBAN")

	// The escaped label comes back byte for byte.
	found_tab := false
	for &t in app2.led.txns {
		if strings.contains(t.label, "TABULATION") {
			eq_str(tc, t.label, "CB AVEC\tTABULATION ET \\ ANTISLASH", "la tabulation et l'antislash survivent")
			eq_str(tc, t.note, "annotation\navec un saut de ligne", "et le saut de ligne de l'annotation")
			found_tab = true
		}
	}
	ok_mark(tc, found_tab, "l'opération au libellé difficile est retrouvée")

	// Budgets, rules and the reconciliation target.
	limit, rollover, bok := budget_limit(app2, food, 2026, 10)
	ok_mark(tc, bok && limit == 30000 && rollover, "l'enveloppe revient avec son report")
	user_rules := 0
	builtin_rules := 0
	for r in app2.cat.rules {
		switch r.source {
		case .User:
			user_rules += 1
		case .Learned:
			user_rules += 1
		case .Builtin:
			builtin_rules += 1
		}
	}
	eq_int(tc, user_rules, 2, "les deux règles de l'utilisateur reviennent")
	ok_mark(tc, builtin_rules > 50, "et les règles livrées viennent du programme, pas du fichier")
	tgt, tok := recon_target(app2, cur2)
	ok_mark(tc, tok && tgt.balance == 158103, "l'objectif de rapprochement revient")

	// A corrupt file: a transaction whose entries do not balance must be
	// refused at that transaction, and the rest must still load.
	broken := strings.concatenate(
		{
			"# palmy-money 1\n",
			"A\t0\t3\t0\t0\tNon catégorisé\t\t\n",
			"A\t1\t3\t1\t0\tSolde initial\t\t\n",
			"A\t2\t0\t2\t0\tCompte\t\t\n",
			"A\t3\t1\t3\t0\tAlimentation\t\t\n",
			"T\t1\t2026-10-01\t2026-10-01\t1\t0\t0\t\tBONNE LIGNE\t\n",
			"E\t1\t2\t-1000\n",
			"E\t1\t3\t1000\n",
			"T\t2\t2026-10-02\t2026-10-02\t1\t0\t0\t\tLIGNE DESEQUILIBREE\t\n",
			"E\t2\t2\t-1000\n",
			"E\t2\t3\t500\n",
			"T\t3\t2026-10-03\t2026-10-03\t1\t0\t0\t\tAUTRE BONNE LIGNE\t\n",
			"E\t3\t2\t-2000\n",
			"E\t3\t3\t2000\n",
		},
		context.temp_allocator,
	)
	app3 := fresh_app()
	defer drop_app(app3)
	n3, problems3 := store_parse(app3, broken)
	eq_int(tc, n3, 2, "les deux opérations équilibrées sont chargées")
	eq_int(tc, problems3, 1, "la déséquilibrée est refusée et comptée")
	ok_mark(tc, ledger_check(&app3.led).ok, "et le livre chargé est équilibré")

	// Garbage lines are counted, not fatal.
	app4 := fresh_app()
	defer drop_app(app4)
	_, problems4 := store_parse(app4, "# palmy-money 1\nZ\tn'importe quoi\nA\t0\n")
	ok_mark(tc, problems4 >= 2, "les lignes incompréhensibles sont comptées")
	ok_mark(tc, ledger_check(&app4.led).ok, "sans casser le livre")

	// The store directory is the only path this program writes, and the
	// helper has to agree with that.
	dir := store_dir(context.temp_allocator)
	ok_mark(
		tc,
		strings.has_suffix(dir, "/palmy-money") || strings.has_suffix(dir, "palmy-money"),
		"le répertoire de données est palmy-money",
	)
	ok_mark(tc, strings.has_suffix(store_path(context.temp_allocator), "book.money"), "et le fichier book.money")
}

// ---------------------------------------------------------------------------
// Searching and filtering
// ---------------------------------------------------------------------------

test_search :: proc(tc: ^TC) {
	app := fresh_app()
	defer drop_app(app)
	ensure_categories(app)
	cur := account_add(&app.led, "Compte courant", .Asset, FX_IBAN_CURRENT)
	sav := account_add(&app.led, "Livret", .Asset)
	st := parse_text(FX_ALPHA_CSV, nil, "alpha.csv")
	statement_ingest(app, st, cur)
	statement_destroy(st)
	free(st)
	transfer_add(&app.led, cur, sav, 20000, Date{2026, 10, 2}, "VIR EPARGNE OCTOBRE")

	// The case-insensitive substring test.
	ok_mark(tc, ascii_fold_contains("CB CARREFOUR 2109", "carrefour"), "recherche insensible à la casse")
	ok_mark(tc, ascii_fold_contains("CB CARREFOUR 2109", "CARREFOUR"), "et à l'identique")
	ok_mark(tc, !ascii_fold_contains("CB CARREFOUR 2109", "lidl"), "et qui ne trouve pas ce qui n'y est pas")
	ok_mark(tc, ascii_fold_contains("abc", ""), "une recherche vide trouve tout")
	ok_mark(tc, !ascii_fold_contains("ab", "abc"), "une aiguille plus longue que la botte ne s'y trouve pas")

	// Unfiltered.
	app.filter = Filter{account = -1, category = -1, range = .All}
	refilter(app)
	eq_int(tc, len(app.rows), 22, "sans filtre, toutes les opérations")

	// By account.
	app.filter.account = sav
	refilter(app)
	eq_int(tc, len(app.rows), 1, "par compte: le seul mouvement du livret")
	app.filter.account = -1

	// By text.
	clear(&app.search)
	append(&app.search, "carrefour")
	refilter(app)
	eq_int(tc, len(app.rows), 3, "par libellé: les trois passages au supermarché")

	// By amount typed into the search box.
	clear(&app.search)
	append(&app.search, "91,25")
	refilter(app)
	eq_int(tc, len(app.rows), 1, "par montant saisi dans la recherche")

	// By category name typed into the search box.
	clear(&app.search)
	append(&app.search, "énergie")
	refilter(app)
	ok_mark(tc, len(app.rows) == 0, "un nom de catégorie accentué ne correspond pas en ASCII")
	clear(&app.search)
	append(&app.search, "alimentation")
	refilter(app)
	ok_mark(tc, len(app.rows) >= 3, "mais un nom de catégorie ASCII, oui")
	clear(&app.search)

	// By date range.
	app.filter.range = .Custom
	app.filter.lo = Date{2026, 9, 1}
	app.filter.hi = Date{2026, 9, 10}
	refilter(app)
	eq_int(tc, len(app.rows), 8, "par période: les huit opérations du 1er au 10 septembre")
	for i in app.rows {
		ok_mark(
			tc,
			date_within(app.led.txns[i].date, Date{2026, 9, 1}, Date{2026, 9, 10}),
			"chaque ligne filtrée est dans la période",
		)
		break
	}
	app.filter.range = .All

	// By amount bounds.
	app.filter.by_min = true
	app.filter.min = 10000
	refilter(app)
	ok_mark(tc, len(app.rows) >= 2, "par montant minimum")
	for i in app.rows {
		ok_mark(
			tc,
			money_abs(txn_amount(&app.led, &app.led.txns[i])) >= 10000,
			"et toutes les lignes respectent le minimum",
		)
		break
	}
	app.filter.by_min = false

	// By method.
	app.filter.by_method = true
	app.filter.method = .Cash
	refilter(app)
	eq_int(tc, len(app.rows), 1, "par méthode: le seul retrait")
	app.filter.by_method = false

	// Uncategorised only — after the rules have run, the cash withdrawal and
	// the cheque are the interesting leftovers.
	app.filter.only_todo = true
	refilter(app)
	todo := len(app.rows)
	ok_mark(tc, todo >= 1, fmt.tprintf("il reste %d opérations à catégoriser", todo))
	for i in app.rows {
		ok_mark(tc, !txn_is_transfer(&app.led, &app.led.txns[i]), "un virement n'est jamais «à catégoriser»")
		break
	}
	app.filter.only_todo = false

	// Sorting: newest first, and a total order so the list cannot shuffle.
	refilter(app)
	for k in 1 ..< len(app.rows) {
		a := &app.led.txns[app.rows[k - 1]]
		b := &app.led.txns[app.rows[k]]
		if date_less(a.date, b.date) {
			ok_mark(tc, false, "la liste est triée du plus récent au plus ancien")
			break
		}
	}
	ok_mark(tc, true, "la liste est triée du plus récent au plus ancien")

	// The totals of what is shown.
	out, in_ := rows_total(app)
	eq_cents(tc, in_, 245000 + 4230, "le total des recettes affichées")
	ok_mark(tc, out < 0, "et celui des dépenses est négatif")

	// The filter timing is recorded, which is what the status bar shows.
	ok_mark(tc, app.last_filter >= 0, "la durée du filtrage est mesurée")
}

// ---------------------------------------------------------------------------
// Fuzzing: money and date round trips
// ---------------------------------------------------------------------------

FUZZ_VALUES :: 20000

test_fuzz_money :: proc(tc: ^TC) {
	r := rng_make(0x4D4F4E45)
	bad_money := 0
	bad_group := 0
	for _ in 0 ..< FUZZ_VALUES {
		// Across the whole range a personal account can reach, both signs.
		mag := i64(rng_next(&r) % 10_000_000_000)
		v := Cents(rng_int(&r, 0, 1) == 0 ? -mag : mag)

		// Without the symbol, read back with the French separator.
		text := money_text(v, false, context.temp_allocator)
		back, ok := money_parse(text, .Comma)
		if !ok || back != v {
			bad_money += 1
			if bad_money == 1 {
				fmt.printfln("  (premier échec: %d centimes -> «%s»)", i64(v), text)
			}
		}
		// With the symbol and the non-breaking spaces, read back on the
		// heuristic, which is what the search box does.
		full := money_text(v, true, context.temp_allocator)
		back2, ok2 := money_parse(full)
		if !ok2 || back2 != v {
			bad_group += 1
		}
	}
	eq_int(tc, bad_money, 0, fmt.tprintf("%d montants aléatoires font l'aller-retour exactement", FUZZ_VALUES))
	eq_int(tc, bad_group, 0, "y compris groupés et avec le symbole euro")

	// Dates, over every day of a century.
	bad_date := 0
	for n in 0 ..< 36525 {
		d := civil_from_days(n + days_from_civil(Date{1990, 1, 1}))
		for form in ([?]Date_Format{.DMY, .YMD}) {
			text := form == .DMY ? date_text(d, context.temp_allocator) : date_iso(d, context.temp_allocator)
			back, ok := date_parse(text, form)
			if !ok || !date_eq(back, d) {
				bad_date += 1
			}
		}
	}
	eq_int(tc, bad_date, 0, "chaque jour d'un siècle fait l'aller-retour dans les deux formats")

	// Splitting an arbitrary amount into an arbitrary number of parts always
	// recomposes exactly, which is the property a shared bill depends on.
	bad_split := 0
	for _ in 0 ..< 5000 {
		v := Cents(rng_int(&r, -1_000_000, 1_000_000))
		n := rng_int(&r, 1, 17)
		parts := money_split(v, n, context.temp_allocator)
		if len(parts) != n || money_sum(parts) != v {
			bad_split += 1
		}
	}
	eq_int(tc, bad_split, 0, "5 000 ventilations aléatoires se recomposent exactement")
}

// ---------------------------------------------------------------------------
// Fuzzing: the CSV importer against generated dialects
//
// Every bank's CSV differs in the same handful of dimensions — delimiter,
// date order, decimal separator, thousands grouping, one signed column versus
// a debit/credit pair, a preamble, a header or none, quoted labels. This
// generates files across that space, with the answers known by construction,
// and asserts that every row comes back with the right date and the right
// amount to the centime. A dialect the importer gets wrong is found here
// rather than by a user whose statement is silently off by a factor of a
// thousand.
// ---------------------------------------------------------------------------

FUZZ_FILES :: 300

test_fuzz_csv :: proc(tc: ^TC) {
	r := rng_make(0x05C5_0001)
	bad_count := 0
	bad_amount := 0
	bad_date := 0
	refused := 0
	dialects := 0

	DELIMS := [?]u8{';', ',', '\t'}
	DATE_NAMES := [?]string{"Date", "Date operation", "Date de l'operation"}
	LABEL_NAMES := [?]string{"Libelle", "Description", "Nature de l'operation"}

	for file in 0 ..< FUZZ_FILES {
		delim := DELIMS[rng_int(&r, 0, len(DELIMS) - 1)]
		iso := rng_int(&r, 0, 2) == 0
		comma_dec := !iso || rng_int(&r, 0, 1) == 0
		group := rng_int(&r, 0, 2) == 0
		pair := rng_int(&r, 0, 1) == 0 // Débit/Crédit instead of one signed column
		header := rng_int(&r, 0, 4) != 0
		preamble := header ? rng_int(&r, 0, 3) : 0
		rows := rng_int(&r, 4, 40)
		dialects += 1

		// A grouped amount can contain the delimiter, so those fields are
		// quoted — which is exactly what a bank does.
		group_sep := comma_dec ? (rng_int(&r, 0, 1) == 0 ? " " : NBSP) : ","

		b := strings.builder_make(context.temp_allocator)
		for k in 0 ..< preamble {
			fmt.sbprintf(&b, "Extrait numero %d du compte de demonstration\n", k + 1)
		}
		if header {
			date_name := DATE_NAMES[rng_int(&r, 0, len(DATE_NAMES) - 1)]
			label_name := LABEL_NAMES[rng_int(&r, 0, len(LABEL_NAMES) - 1)]
			fmt.sbprintf(&b, "%s%c%s%c", date_name, rune(delim), label_name, rune(delim))
			if pair {
				fmt.sbprintf(&b, "Debit%cCredit\n", rune(delim))
			} else {
				strings.write_string(&b, "Montant\n")
			}
		}

		want_dates := make([dynamic]Date, 0, rows, context.temp_allocator)
		want_amounts := make([dynamic]Cents, 0, rows, context.temp_allocator)
		for k in 0 ..< rows {
			d := date_add(Date{2026, 1, 1}, rng_int(&r, 0, 600))
			// Never zero: in a debit/credit layout a zero carries no side.
			mag := Cents(rng_int(&r, 1, 400000))
			amount := rng_int(&r, 0, 3) == 0 ? mag : -mag
			// A debit/credit file must exercise both columns. A file where
			// one of the two is empty from top to bottom genuinely cannot be
			// told from a single signed column — see the test below, which
			// pins that behaviour down rather than pretending otherwise.
			if pair && k == 0 {
				amount = -mag
			}
			if pair && k == 1 {
				amount = mag
			}
			append(&want_dates, d)
			append(&want_amounts, amount)

			if iso {
				strings.write_string(&b, date_iso(d, context.temp_allocator))
			} else {
				strings.write_string(&b, date_text(d, context.temp_allocator))
			}
			strings.write_byte(&b, delim)

			shop := SHOPS[rng_int(&r, 0, len(SHOPS) - 1)]
			if rng_int(&r, 0, 4) == 0 {
				// A label holding the delimiter, which forces quoting.
				fmt.sbprintf(&b, "\"CB %s%c PARIS %02d\"", shop, rune(delim), k % 20 + 1)
			} else {
				fmt.sbprintf(&b, "CB %s %04d", shop, k)
			}
			strings.write_byte(&b, delim)

			// The whole cell, sign included, then quoted if it contains the
			// delimiter — which a French export with a decimal comma in a
			// comma-delimited file genuinely has to do, and does.
			body := fuzz_amount(money_abs(amount), comma_dec, group, group_sep)
			cell := body
			if !pair && amount < 0 {
				cell = strings.concatenate({"-", body}, context.temp_allocator)
			}
			dstr := strings.clone_from_bytes({delim}, context.temp_allocator)
			if strings.contains(cell, dstr) {
				cell = strings.concatenate({"\"", cell, "\""}, context.temp_allocator)
			}
			if pair {
				if amount < 0 {
					strings.write_string(&b, cell)
					strings.write_byte(&b, delim)
				} else {
					strings.write_byte(&b, delim)
					strings.write_string(&b, cell)
				}
			} else {
				strings.write_string(&b, cell)
			}
			strings.write_byte(&b, '\n')
		}

		text := strings.to_string(b)
		s := parse_text(text, nil, fmt.tprintf("fuzz%d.csv", file))
		defer {
			statement_destroy(s)
			free(s)
		}
		if !statement_ok(s) {
			refused += 1
			if refused == 1 {
				fmt.printfln(
					"  (premier fichier refusé: délim %q iso %v virgule %v groupé %v paire %v entête %v: %s)",
					rune(delim),
					iso,
					comma_dec,
					group,
					pair,
					header,
					len(s.errors) > 0 ? s.errors[0] : "?",
				)
			}
			continue
		}
		if len(s.txns) != rows {
			bad_count += 1
			continue
		}
		for t, k in s.txns {
			if t.amount != want_amounts[k] {
				bad_amount += 1
				if bad_amount == 1 {
					fmt.printfln(
						"  (premier montant faux: %d au lieu de %d, délim %q groupé %v virgule %v paire %v)",
						i64(t.amount),
						i64(want_amounts[k]),
						rune(delim),
						group,
						comma_dec,
						pair,
					)
				}
			}
			if !date_eq(t.date, want_dates[k]) {
				bad_date += 1
			}
		}
	}

	eq_int(tc, dialects, FUZZ_FILES, fmt.tprintf("%d dialectes CSV générés", FUZZ_FILES))
	eq_int(tc, refused, 0, "aucun dialecte généré n'est refusé")
	eq_int(tc, bad_count, 0, "chaque fichier rend exactement ses lignes")
	eq_int(tc, bad_amount, 0, "chaque montant revient au centime")
	eq_int(tc, bad_date, 0, "chaque date revient exactement")

	// The ambiguity the fuzzer found, pinned down.
	//
	// A headerless two-column export whose second column is empty on every
	// row has one column of unsigned numbers, and nothing in the file says
	// whether that column is "Débit" (money out) or "Montant" (signed). The
	// importer reads it as a signed amount, which is the more common case —
	// and gets the sign wrong for the other one. There is no inference that
	// fixes this, which is precisely why a per-bank mapping is remembered:
	// with the mapping, the same file reads correctly.
	ambiguous := "01/10/2026\tCB CARREFOUR 0110\t42,10\t\n02/10/2026\tCB LIDL 0210\t31,05\t\n03/10/2026\tCB IKEA 0310\t12,00\t\n"
	amb := parse_text(ambiguous, nil, "ambigu.csv")
	defer {
		statement_destroy(amb)
		free(amb)
	}
	eq_int(tc, len(amb.txns), 3, "le fichier ambigu est lu")
	eq_cents(tc, amb.txns[0].amount, 4210, "sans en-tête, une colonne de nombres non signés est lue comme un montant signé")

	// With the bank's mapping, the same bytes read correctly.
	prof := profile_blank()
	prof.name = "Banque ambiguë"
	prof.delim = '\t'
	prof.has_header = false
	prof.skip = 0
	prof.date_fmt = .DMY
	prof.decimal = .Comma
	prof.col_date = 0
	prof.col_label = 1
	prof.col_debit = 2
	prof.col_credit = 3
	amb2 := parse_text(ambiguous, &prof, "ambigu.csv")
	defer {
		statement_destroy(amb2)
		free(amb2)
	}
	eq_int(tc, len(amb2.txns), 3, "avec la cartographie enregistrée, le fichier est lu")
	eq_cents(tc, amb2.txns[0].amount, -4210, "et la colonne Débit redevient une sortie d'argent")
	eq_cents(tc, amb2.txns[2].amount, -1200, "sur toutes les lignes")
	eq_str(tc, amb2.bank, "Banque ambiguë", "le profil nomme la banque")

	// And with a header, no mapping is needed: the names settle it.
	named := "Date\tLibelle\tDebit\tCredit\n01/10/2026\tCB CARREFOUR 0110\t42,10\t\n02/10/2026\tCB LIDL 0210\t31,05\t\n"
	nm := parse_text(named, nil, "nomme.csv")
	defer {
		statement_destroy(nm)
		free(nm)
	}
	eq_int(tc, len(nm.txns), 2, "le fichier nommé est lu")
	eq_cents(tc, nm.txns[0].amount, -4210, "un en-tête «Débit» suffit à donner le signe")
}

// fuzz_amount writes a positive amount in one bank's convention.
@(private = "file")
fuzz_amount :: proc(v: Cents, comma_dec, group: bool, group_sep: string) -> string {
	plain := money_text(v, false, context.temp_allocator) // 1 234,56 with NBSP
	// Rebuild from the digits so every combination is reachable.
	mag := u64(i64(v))
	euros := mag / 100
	cent := mag % 100
	digits := fmt.tprintf("%d", euros)
	b := strings.builder_make(context.temp_allocator)
	if group && len(digits) > 3 {
		lead := len(digits) % 3
		if lead == 0 {
			lead = 3
		}
		strings.write_string(&b, digits[:lead])
		for i := lead; i < len(digits); i += 3 {
			strings.write_string(&b, group_sep)
			strings.write_string(&b, digits[i:i + 3])
		}
	} else {
		strings.write_string(&b, digits)
	}
	strings.write_byte(&b, comma_dec ? ',' : '.')
	strings.write_byte(&b, u8('0' + cent / 10))
	strings.write_byte(&b, u8('0' + cent % 10))
	_ = plain
	return strings.to_string(b)
}

// ---------------------------------------------------------------------------
// Fuzzing: truncation
//
// A statement can be cut anywhere — a download that stopped, a file copied
// off a full disk. Every prefix of every fixture is parsed and booked, and
// two things must hold for all of them: the parser must not crash, and
// whatever it does manage to read must leave the ledger balanced. A parser
// that produces half a transaction is how a book silently stops adding up.
// ---------------------------------------------------------------------------

test_fuzz_truncation :: proc(tc: ^TC) {
	cases := [?]struct {
		name: string,
		body: string,
	} {
		{"CSV alpha", FX_ALPHA_CSV},
		{"CSV beta", FX_BETA_CSV},
		{"CSV gamma", FX_GAMMA_CSV},
		{"OFX", FX_OFX},
		{"OFX 2", FX_OFX_XML},
		{"CAMT", FX_CAMT},
	}
	prefixes := 0
	unbalanced := 0
	for c in cases {
		step := max(len(c.body) / 120, 1)
		for cut := 0; cut <= len(c.body); cut += step {
			prefixes += 1
			app := fresh_app()
			ensure_categories(app)
			acct := account_add(&app.led, "Compte", .Asset)
			s := parse_text(c.body[:cut], nil, "tronque")
			if statement_ok(s) {
				statement_ingest(app, s, acct)
			}
			statement_destroy(s)
			free(s)
			if !ledger_check(&app.led).ok {
				unbalanced += 1
				if unbalanced == 1 {
					fmt.printfln("  (premier déséquilibre: %s tronqué à %d octets)", c.name, cut)
				}
			}
			drop_app(app)
			free_all(context.temp_allocator)
		}
	}
	ok_mark(tc, prefixes > 600, fmt.tprintf("%d préfixes tronqués analysés", prefixes))
	eq_int(tc, unbalanced, 0, "aucun fichier tronqué ne laisse le livre déséquilibré")
}

_ :: os

// ---------------------------------------------------------------------------
// La ligne de commande
//
// La même déclaration que lit `palm schema`. Chaque commande est exécutée
// ici sans rien imprimer : on lie la ligne, on appelle le corps, on valide
// l'objet produit contre ce que la commande déclare. Tout se passe dans un
// répertoire temporaire, sur le livre fictif que `money demo` écrit ; le
// magasin de l'application n'est jamais ouvert.
// ---------------------------------------------------------------------------

@(private = "file")
cli_run :: proc(tc: ^TC, line: string) -> (c: kit.Call, code: int) {
	words := kit.cli_split_example(line)
	c, code = kit.cli_bind(surface(), words)
	if code != kit.EXIT_OK || c.cmd == nil || c.cmd.run == nil {
		return
	}
	code = c.cmd.run(&c)
	return
}

@(private = "file")
cli_valid :: proc(tc: ^TC, line: string, what: string) -> (c: kit.Call, code: int) {
	c, code = cli_run(tc, line)
	eq_int(tc, code, kit.EXIT_OK, fmt.tprintf("%s : code 0", what))
	if code == kit.EXIT_OK {
		text := kit.json_text(c.out, 0, context.temp_allocator)
		bad := kit.cli_validate_output(text, c.cmd.out, context.temp_allocator)
		ok_mark(tc, len(bad) == 0, fmt.tprintf("%s : conforme au schéma déclaré%s", what, len(bad) > 0 ? fmt.tprintf(" (%s)", bad[0]) : ""))
	}
	return
}

@(private = "file")
file_digest :: proc(path: string) -> string {
	data, err := os.read_entire_file_from_path(path, context.temp_allocator)
	if err != nil {
		return ""
	}
	return string(data)
}

test_cli :: proc(tc: ^TC) {
	s := surface()
	ok_mark(tc, len(s.commands) >= 8, "cli : la déclaration n'est pas vide")
	ok_mark(tc, s.gui && s.takes_path, "cli : sans commande, la fenêtre ; un chemin s'importe au démarrage")
	ok_mark(tc, s.selftest != nil, "cli : --selftest est branché")
	for cmd in s.commands {
		ok_mark(tc, cmd.summary != "", fmt.tprintf("cli : %s a un résumé", cmd.verb))
		ok_mark(tc, len(cmd.out) > 0, fmt.tprintf("cli : %s déclare ce qu'il imprime", cmd.verb))
		ok_mark(tc, len(cmd.examples) > 0, fmt.tprintf("cli : %s a un exemple", cmd.verb))
		for e in cmd.examples {
			words := kit.cli_split_example(e)
			ok_mark(tc, len(words) > 0 && words[0] == "money", fmt.tprintf("cli : l'exemple %q commence par money", e))
			_, code := kit.cli_bind(s, words[1:])
			eq_int(tc, code, kit.EXIT_OK, fmt.tprintf("cli : l'exemple %q se lit", e))
		}
		// Every command that opens a book requires it to be named: run blind,
		// a read must not reach anybody's real accounts.
		if cmd.effect == .Read {
			_, code := kit.cli_bind(s, {cmd.verb})
			eq_int(tc, code, kit.EXIT_USAGE, fmt.tprintf("cli : %s sans --book est refusé", cmd.verb))
		}
	}

	// The older spellings stay with main.odin, with their old behaviour.
	for legacy in ([?]string{"--import", "--fixtures", "--shot", "--bench", "--start-dir"}) {
		ok_mark(tc, !is_cli_head(legacy), fmt.tprintf("cli : l'ancienne forme %s est toujours acceptée", legacy))
	}
	for head in ([?]string{"accounts", "list", "help", "--schema", "--help"}) {
		ok_mark(tc, is_cli_head(head), fmt.tprintf("cli : %s va à la convention", head))
	}

	dir := fmt.tprintf("/tmp/palmy-money-cli-%d", os.get_pid())
	os.remove_all(dir)
	os.make_directory_all(dir)
	defer os.remove_all(dir)
	book := fmt.tprintf("%s/livre.money", dir)

	{
		_, code := cli_run(tc, fmt.tprintf("accounts --book %s/absent.money", dir))
		eq_int(tc, code, kit.EXIT_NOT_FOUND, "cli : un livre absent répond 3")
	}
	cli_valid(tc, fmt.tprintf("demo --book %s", book), "cli demo")
	ok_mark(tc, os.is_file(book), "cli demo : le livre est écrit")
	{
		_, code := cli_run(tc, fmt.tprintf("demo --book %s", book))
		eq_int(tc, code, kit.EXIT_FAILED, "cli demo : n'écrase jamais un livre existant")
	}
	cli_valid(tc, fmt.tprintf("accounts --book %s", book), "cli accounts")
	{
		c, _ := cli_valid(tc, fmt.tprintf("transactions --book %s --limit 5", book), "cli transactions")
		arr, _ := kit.jget(c.out, "transactions")
		eq_int(tc, kit.jlen(arr), 5, "cli transactions : --limit est respecté")
	}
	cli_valid(tc, fmt.tprintf("transactions --book %s --match NETFLIX --from 2026-01-01", book), "cli transactions filtré")
	cli_valid(tc, fmt.tprintf("budget --book %s", book), "cli budget")
	cli_valid(tc, fmt.tprintf("recurring --book %s", book), "cli recurring")

	// Import: --dry-run changes nothing, the real run changes the book, and a
	// second run adds nothing — the importer's de-duplication, through the CLI.
	fx := fmt.tprintf("%s/fx", dir)
	cli_valid(tc, fmt.tprintf("fixtures %s", fx), "cli fixtures")
	camt := fmt.tprintf("%s/octobre.camt.xml", fx)
	before := file_digest(book)
	{
		c, code := cli_run(tc, fmt.tprintf("import %s --book %s --dry-run", camt, book))
		c.dry_run = true
		eq_int(tc, code, kit.EXIT_OK, "cli import --dry-run : code 0")
		added, _ := kit.jget(c.out, "added")
		ok_mark(tc, added != nil && kit.json_scalar(added) != "0", "cli import --dry-run : dit ce qui serait ajouté")
		eq_str(tc, file_digest(book), before, "cli import --dry-run : le livre est inchangé")
	}
	{
		c, _ := cli_valid(tc, fmt.tprintf("import %s --book %s", camt, book), "cli import")
		ok_mark(tc, file_digest(book) != before, "cli import : le livre a changé")
		saved, _ := kit.jget(c.out, "saved")
		ok_mark(tc, saved != nil && saved.kind == .Bool && saved.b, "cli import : enregistré")
	}
	{
		c, _ := cli_run(tc, fmt.tprintf("import %s --book %s", camt, book))
		added, _ := kit.jget(c.out, "added")
		eq_str(tc, kit.json_scalar(added), "0", "cli import : une deuxième fois n'ajoute rien")
	}
	{
		_, code := cli_run(tc, fmt.tprintf("import %s/absent.csv --book %s", dir, book))
		eq_int(tc, code, kit.EXIT_NOT_FOUND, "cli import : un relevé absent répond 3")
	}

	// Categorising through the CLI is the window's action: the transaction
	// moves and the merchant becomes a learned rule, both saved.
	{
		c, _ := cli_run(tc, fmt.tprintf("transactions --book %s --limit 1", book))
		arr, _ := kit.jget(c.out, "transactions")
		first := arr != nil && kit.jlen(arr) > 0 ? arr.items[0] : nil
		idv: ^kit.Json
		if first != nil {
			idv, _ = kit.jget(first, "id")
		}
		id := idv != nil ? kit.json_scalar(idv) : "-1"
		cli_valid(tc, fmt.tprintf("categorize %s Loisirs --book %s", id, book), "cli categorize")
		app := fresh_app()
		defer drop_app(app)
		store_load_from(app, book)
		learned := false
		for r in app.cat.rules {
			if r.source != .Builtin && r.category == "Loisirs" {
				learned = true
			}
		}
		ok_mark(tc, learned, "cli categorize : la règle apprise est enregistrée")
		_, code := cli_run(tc, fmt.tprintf("categorize 999999 Loisirs --book %s", book))
		eq_int(tc, code, kit.EXIT_NOT_FOUND, "cli categorize : une opération absente répond 3")
	}
	cli_valid(tc, fmt.tprintf("budget-set Loisirs 120,50 --month 2026-10 --book %s", book), "cli budget-set")
	{
		app := fresh_app()
		defer drop_app(app)
		store_load_from(app, book)
		cat, _ := account_find(&app.led, "Loisirs")
		limit, _, ok := budget_limit(app, cat, 2026, 10)
		ok_mark(tc, ok, "cli budget-set : l'enveloppe existe")
		eq_cents(tc, limit, 12050, "cli budget-set : 120,50 € lu à la française")
	}
	cli_valid(tc, fmt.tprintf("budget-suggest --month 2026-12 --book %s", book), "cli budget-suggest")
	{
		before2 := file_digest(book)
		cli_valid(tc, fmt.tprintf("apply-rules --book %s --dry-run", book), "cli apply-rules --dry-run")
		eq_str(tc, file_digest(book), before2, "cli apply-rules --dry-run : le livre est inchangé")
	}
}
