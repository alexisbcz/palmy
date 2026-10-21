// `shop --selftest`: everything that can be wrong without being visible.
//
// The computations are the point of this application, so they are asserted
// against values worked out by hand rather than against whatever the code
// happened to produce. In particular:
//
//   - the unit price, including `lot de N x M`, decimal quantities and mixed
//     units, because a comparison on the wrong number is worse than none;
//   - the Nutri-Score at every grade boundary from A to E, plus the beverage,
//     cheese and added-fat tables and the protein rule, with the contrasting
//     case alongside each special table so the special case is shown to be
//     doing something;
//   - money as integer centimes, a basket total to the centime, and TVA at
//     each of the four French rates;
//   - the five size systems, in both directions, including the three places
//     where menswear and womenswear disagree about the same number;
//   - accent- and plural-insensitive search;
//   - feed parsing, and the refusal of malformed input: a missing price, a
//     comma decimal (which must be *accepted*), an unknown currency, a bad
//     check digit and a truncated document.
package main

import "core:fmt"
import kit "kit:."
import "core:os"
import "core:strings"
import "core:time"

@(private = "file")
checks := 0

@(private = "file")
failures := 0

@(private = "file")
ok :: proc(cond: bool, what: string, args: ..any) {
	checks += 1
	if !cond {
		failures += 1
		fmt.eprintf("  FAIL  ")
		fmt.eprintfln(what, ..args)
	}
}

@(private = "file")
eq_str :: proc(got, want: string, what: string) {
	checks += 1
	if got != want {
		failures += 1
		fmt.eprintfln("  FAIL  %s\n        got  %q\n        want %q", what, got, want)
	}
}

@(private = "file")
eq_int :: proc(got, want: i64, what: string) {
	checks += 1
	if got != want {
		failures += 1
		fmt.eprintfln("  FAIL  %s: got %d, want %d", what, got, want)
	}
}

@(private = "file")
eq_money :: proc(got, want: Centimes, what: string) {
	checks += 1
	if got != want {
		failures += 1
		fmt.eprintfln(
			"  FAIL  %s: got %s, want %s",
			what,
			fmt_money(got, context.temp_allocator),
			fmt_money(want, context.temp_allocator),
		)
	}
}

@(private = "file")
eq_grade :: proc(got: Nutri_Result, grade: Nutri, score: int, what: string) {
	checks += 1
	if got.grade != grade || got.score != score {
		failures += 1
		fmt.eprintfln(
			"  FAIL  %s: got %s (score %d), want %s (score %d)",
			what,
			nutri_letter(got.grade),
			got.score,
			nutri_letter(grade),
			score,
		)
	}
}

run_selftest :: proc() -> int {
	fmt.println("shop --selftest")

	test_money()
	test_tva()
	test_quantities()
	test_unit_prices()
	test_nutri_solid_boundaries()
	test_nutri_beverages()
	test_nutri_cheese_and_fats()
	test_sizes()
	test_search()
	test_ean()
	test_feed_xml()
	test_feed_refusals()
	test_feed_csv()
	test_catalogue()
	test_basket()
	test_list_and_alerts()
	test_round_trip()
	test_persistence()
	test_performance()
	test_cli()

	fmt.println("")
	if failures == 0 {
		fmt.printfln("%d assertions, all passed", checks)
		return 0
	}
	fmt.printfln("%d assertions, %d FAILED", checks, failures)
	return 1
}

// ---------------------------------------------------------------------------
// Money
// ---------------------------------------------------------------------------

@(private = "file")
test_money :: proc() {
	// The French convention, byte for byte. The separator before the euro sign
	// is U+00A0: a plain space would let a line break fall between the number
	// and its unit.
	eq_str(fmt_centimes(123456, context.temp_allocator), "1 234,56", "1 234,56 with a non-breaking group separator")
	eq_str(fmt_money(123456, context.temp_allocator), "1 234,56 €", "1 234,56 €")
	eq_str(fmt_money(0, context.temp_allocator), "0,00 €", "zero")
	eq_str(fmt_money(5, context.temp_allocator), "0,05 €", "five centimes")
	eq_str(fmt_money(-199, context.temp_allocator), "-1,99 €", "a negative price")
	eq_str(fmt_money(100_000_000, context.temp_allocator), "1 000 000,00 €", "a million euros groups twice")
	eq_str(fmt_money(199, context.temp_allocator), "1,99 €", "1,99 €")

	m := fmt_money(1299, context.temp_allocator)
	ok(len(m) == len("12,99") + 2 + len("€"), "the separator is two bytes, so it is U+00A0 and not an ASCII space")
	ok(!strings.contains(m, " "), "no ASCII space appears in a formatted price")

	// Reading prices, both separators and both conventions.
	v, good := parse_centimes("12,99")
	ok(good && v == 1299, "12,99 reads as 1299 centimes")
	v, good = parse_centimes("12.99")
	ok(good && v == 1299, "12.99 — an exporter that ignored the locale — also reads")
	v, good = parse_centimes("3,2")
	ok(good && v == 320, "one decimal place is tenths of a euro, not centimes")
	v, good = parse_centimes("1 234,56")
	ok(good && v == 123456, "a space thousands separator")
	v, good = parse_centimes("1 234,56")
	ok(good && v == 123456, "a non-breaking thousands separator")
	_, good = parse_centimes("3,205")
	ok(!good, "three decimals is not a price and is refused")
	_, good = parse_centimes("")
	ok(!good, "an empty price is refused")
	_, good = parse_centimes("gratuit")
	ok(!good, "a word is not a price")
	_, good = parse_centimes("12,,99")
	ok(!good, "two decimal marks are refused")

	v, good = parse_money("12,99 EUR")
	ok(good && v == 1299, "a feed price with the currency code")
	v, good = parse_money("9,99 €")
	ok(good && v == 999, "a feed price with the symbol")
	v, good = parse_money("12.99EUR")
	ok(good && v == 1299, "no space before the currency code")
	_, good = parse_money("12.99 USD")
	ok(!good, "a price in dollars is refused rather than taken as euros")
	_, good = parse_money("12,99 CHF")
	ok(!good, "francs likewise")

	eq_int(pct_change(1000, 800), -200, "a fifth off is -20,0 %")
	eq_int(pct_change(800, 1000), 250, "and back up is +25,0 %")
	eq_str(fmt_pct(-125, context.temp_allocator), "-12,5 %", "a percentage reads in French too")
}

@(private = "file")
test_tva :: proc() {
	// The four rates, each asserted on a price where the arithmetic is exact
	// and on one where it has to round.
	eq_money(price_ht(1200, .Standard), 1000, "20 % of 12,00 € TTC is 10,00 € HT")
	eq_money(price_tva(1200, .Standard), 200, "and 2,00 € of TVA")
	eq_money(price_ht(1100, .Reduced), 1000, "10 % : 11,00 € TTC is 10,00 € HT")
	eq_money(price_tva(1100, .Reduced), 100, "and 1,00 € of TVA")
	eq_money(price_ht(1055, .Food), 1000, "5,5 % : 10,55 € TTC is 10,00 € HT")
	eq_money(price_tva(1055, .Food), 55, "and 0,55 € of TVA")
	eq_money(price_ht(1021, .Super), 1000, "2,1 % : 10,21 € TTC is 10,00 € HT")
	eq_money(price_tva(1021, .Super), 21, "and 0,21 € of TVA")

	// Rounding: 5,99 € of food is 5,68 € HT and 31 centimes of tax, and the
	// two must still add up to what is on the shelf.
	eq_money(price_ht(599, .Food), 568, "5,99 € at 5,5 % is 5,68 € HT")
	eq_money(price_tva(599, .Food), 31, "and 31 centimes of TVA")
	for rate in Tva {
		for p in ([?]Centimes{1, 7, 99, 100, 349, 1299, 99999}) {
			checks += 1
			if price_ht(p, rate) + price_tva(p, rate) != p {
				failures += 1
				fmt.eprintfln(
					"  FAIL  HT + TVA must equal TTC exactly: %v at %s",
					p,
					tva_label(rate),
				)
			}
		}
	}
	eq_str(tva_label(.Food), "5,5 %", "the reduced food rate is written the French way")
}

// ---------------------------------------------------------------------------
// Quantities and unit prices
// ---------------------------------------------------------------------------

@(private = "file")
qcheck :: proc(text: string, kind: Unit_Kind, amount: i64, count: i64, what: string) {
	q := parse_quantity(text)
	checks += 1
	if !q.ok || q.kind != kind || q.amount != amount || q.count != count {
		failures += 1
		fmt.eprintfln(
			"  FAIL  %s (%q): got %v amount=%d count=%d, want %v amount=%d count=%d",
			what,
			text,
			q.kind,
			q.amount,
			q.count,
			kind,
			amount,
			count,
		)
	}
}

@(private = "file")
test_quantities :: proc() {
	// Mass. The base unit is the milligram, so a decimal kilo is exact.
	qcheck("500 g", .Mass, 500_000, 1, "500 g")
	qcheck("500g", .Mass, 500_000, 1, "500g, glued")
	qcheck("1 kg", .Mass, 1_000_000, 1, "1 kg")
	qcheck("1,5 kg", .Mass, 1_500_000, 1, "1,5 kg with a comma decimal")
	qcheck("2,5 kg", .Mass, 2_500_000, 1, "2,5 kg")
	qcheck("Pâtes Panzani Penne 500 g", .Mass, 500_000, 1, "a quantity found inside a title")

	// Volume. The base unit is the microlitre, so 12,5 cl is exact too.
	qcheck("1 L", .Volume, 1_000_000, 1, "1 L")
	qcheck("1,5 L", .Volume, 1_500_000, 1, "1,5 L")
	qcheck("75 cl", .Volume, 750_000, 1, "75 cl")
	qcheck("33 cl", .Volume, 330_000, 1, "33 cl")
	qcheck("250 ml", .Volume, 250_000, 1, "250 ml")
	qcheck("2,145 L", .Volume, 2_145_000, 1, "2,145 L — a real detergent size")

	// Lots. This is the case that catches people out: the unit price must be
	// computed over N x M, not over M.
	qcheck("lot de 6 x 33 cl", .Volume, 1_980_000, 6, "lot de 6 x 33 cl")
	qcheck("6 x 33 cl", .Volume, 1_980_000, 6, "6 x 33 cl, without the words")
	qcheck("6x33cl", .Volume, 1_980_000, 6, "6x33cl, glued")
	qcheck("6 × 33 cl", .Volume, 1_980_000, 6, "with the typographic multiplication sign")
	qcheck("lot de 3 x 125 g", .Mass, 375_000, 3, "lot de 3 x 125 g")
	qcheck("lot de 12 x 1 L", .Volume, 12_000_000, 12, "lot de 12 x 1 L")
	qcheck("Pâtes 500 g x 4", .Mass, 2_000_000, 4, "a multiplier written after the measure")
	qcheck("Bière blonde 33 cl - lot de 6", .Volume, 1_980_000, 6, "the lot stated after the size")
	qcheck("lot de 2 x 1,5 L", .Volume, 3_000_000, 2, "a lot of a decimal volume")

	// Counts.
	qcheck("12 tranches", .Count, 12_000, 1, "12 tranches")
	qcheck("Jambon blanc 4 tranches", .Count, 4_000, 1, "4 tranches, from a title")
	qcheck("6 oeufs", .Count, 6_000, 1, "6 oeufs")
	qcheck("lot de 4 x 100 g", .Mass, 400_000, 4, "a lot of pots is priced per kilo, not per pot")
	qcheck("Yaourt nature x 16", .Count, 16_000, 16, "a bare multiplier with no measure is a count")
	qcheck("lot de 5 x 10 capsules", .Count, 50_000, 5, "fifty capsules")

	// Mass beats a count when both are present: a crate of six 1,5 L bottles
	// is priced per litre.
	qcheck("lot de 6 bouteilles de 1,5 L", .Volume, 9_000_000, 6, "volume wins over a bottle count")

	// Noise that must not be read as a quantity.
	q := parse_quantity("Jean slim homme")
	ok(!q.ok, "a garment has no quantity and therefore no unit price")
	q = parse_quantity("Chocolat noir 70 % cacao 100 g")
	ok(q.ok && q.kind == .Mass && q.amount == 100_000, "a percentage is not a quantity")
	q = parse_quantity("Lessive liquide 2,145 L (33 lavages)")
	ok(q.ok && q.amount == 2_145_000, "an unknown unit beside the real one is ignored")
	q = parse_quantity("T-shirt col rond uni")
	ok(!q.ok, "no digits at all")

	// Writing a quantity back out, French style.
	eq_str(fmt_amount(.Mass, 500_000, context.temp_allocator), "500 g", "500 g")
	eq_str(fmt_amount(.Mass, 1_500_000, context.temp_allocator), "1,5 kg", "1,5 kg")
	eq_str(fmt_amount(.Volume, 1_980_000, context.temp_allocator), "1,98 L", "1,98 L")
	eq_str(fmt_amount(.Volume, 330_000, context.temp_allocator), "33 cl", "33 cl")
	eq_str(fmt_amount(.Count, 12_000, context.temp_allocator), "12 pièces", "12 pièces")
	eq_str(fmt_quantity(parse_quantity("lot de 6 x 33 cl"), context.temp_allocator), "6 × 33 cl", "a lot is written as 6 × 33 cl")
}

@(private = "file")
test_unit_prices :: proc() {
	// The example from the brief, worked by hand: a 500 g jar at 3,20 € is
	// 6,40 €/kg and a 750 g jar at 4,50 € is 6,00 €/kg, so the bigger jar is
	// cheaper per kilo although it costs more.
	small := parse_quantity("500 g")
	large := parse_quantity("750 g")
	u1, ok1 := unit_price(320, small)
	u2, ok2 := unit_price(450, large)
	ok(ok1 && ok2, "both jars have a unit price")
	eq_money(u1, 640, "500 g at 3,20 € is 6,40 €/kg")
	eq_money(u2, 600, "750 g at 4,50 € is 6,00 €/kg")
	ok(u2 < u1, "and the 4,50 € jar is the cheaper one per kilo")
	eq_str(fmt_unit_price(320, small, context.temp_allocator), "6,40 €/kg", "written as 6,40 €/kg")

	// The lot: six 33 cl bottles for 4,74 € is 2,39 €/L — computed over
	// 1,98 L and not over 33 cl, which would have said 14,36 €/L.
	lot := parse_quantity("lot de 6 x 33 cl")
	u, good := unit_price(474, lot)
	ok(good, "a lot has a unit price")
	eq_money(u, 239, "6 x 33 cl at 4,74 € is 2,39 €/L")
	eq_str(unit_suffix(lot.kind), "€/L", "and it is quoted per litre")
	one, _ := unit_price(99, parse_quantity("33 cl"))
	eq_money(one, 300, "a single 33 cl bottle at 0,99 € is 3,00 €/L")
	ok(u < one, "so the lot is genuinely cheaper per litre, which is the point")

	// Mixed units compared against each other.
	a, _ := unit_price(189, parse_quantity("1,5 L"))
	b, _ := unit_price(135, parse_quantity("1 L"))
	eq_money(a, 126, "1,5 L at 1,89 € is 1,26 €/L")
	eq_money(b, 135, "1 L at 1,35 € is 1,35 €/L")
	ok(a < b, "the larger bottle wins on the litre despite the higher sticker")

	// A count.
	c, _ := unit_price(189, parse_quantity("12 tranches"))
	eq_money(c, 16, "12 tranches at 1,89 € is 0,16 € the slice, rounded half up")

	// Rounding is half up and nothing else.
	d, _ := unit_price(100, parse_quantity("3 pieces"))
	eq_money(d, 33, "1,00 € for three is 0,33 € each")
	e, _ := unit_price(200, parse_quantity("3 pieces"))
	eq_money(e, 67, "2,00 € for three is 0,67 € each")

	// No quantity, no unit price — and nothing invented.
	_, bad := unit_price(2999, parse_quantity("Jean slim"))
	ok(!bad, "a product with no quantity has no unit price")
}

// ---------------------------------------------------------------------------
// Nutri-Score
// ---------------------------------------------------------------------------

@(private = "file")
solid :: proc(kj, sug, sat, sod, fib, pro, fru: i64, class := Food_Class.Solid, fat: i64 = 0) -> Nutrition {
	return Nutrition {
		energy_kj = kj,
		sugars_mg = sug,
		satfat_mg = sat,
		total_fat_mg = fat,
		sodium_mg = sod,
		fibre_mg = fib,
		protein_mg = pro,
		fruit_pct = fru,
		class = class,
		known = true,
	}
}

@(private = "file")
test_nutri_solid_boundaries :: proc() {
	// Each boundary of the general table, worked out by hand. The comment on
	// each line is the arithmetic.

	// N = 0, P = 1 (fruit 50 %) -> -1, which is the top of A.
	eq_grade(nutri_score(solid(300, 4_000, 500, 50, 0, 0, 50)), .A, -1, "score -1 is an A")

	// N = 1 (energy 400 kJ), P = 1 -> 0, the first B.
	eq_grade(nutri_score(solid(400, 4_000, 500, 50, 0, 0, 50)), .B, 0, "score 0 is a B, not an A")

	// N = 3 (energy 700 -> 2, sugars 5 g -> 1), P = 1 (fibre 1,5 g) -> 2.
	eq_grade(nutri_score(solid(700, 5_000, 500, 50, 1_500, 0, 0)), .B, 2, "score 2 is the last B")

	// The same without the fibre point -> 3, the first C.
	eq_grade(nutri_score(solid(700, 5_000, 500, 50, 0, 0, 0)), .C, 3, "score 3 is a C")

	// N = 10 (energy 3100 -> 9, sugars 5 g -> 1), P = 0 -> 10, the last C.
	eq_grade(nutri_score(solid(3_100, 5_000, 500, 50, 0, 0, 0)), .C, 10, "score 10 is the last C")

	// N = 11 (energy 3100 -> 9, sugars 10 g -> 2) with 10 g of protein.
	//
	// This is the protein rule: at 11 negative points the protein points are
	// withheld unless the fruit points are at their maximum. Counting them
	// would give 6 and a C; the rule gives 11 and a D.
	r := nutri_score(solid(3_100, 10_000, 500, 50, 0, 10_000, 0))
	eq_grade(r, .D, 11, "score 11 is a D")
	ok(!r.protein_counted, "and at 11 negative points the protein points are withheld")
	eq_int(i64(r.pts_protein), 5, "the protein points are still computed, just not counted")

	// The exception to the exception: fruit points at the maximum release the
	// protein points again. N = 11, P = 5 + 5 = 10 -> 1, a B.
	r2 := nutri_score(solid(3_100, 10_000, 500, 50, 0, 10_000, 85))
	ok(r2.protein_counted, "fruit points at the maximum release the protein points")
	eq_grade(r2, .B, 1, "the same food with 85 % fruit is a B")

	// N = 18 (energy 3400 -> 10, sugars 15 g -> 3, sat fat 5 g -> 4,
	// sodium 100 mg -> 1), protein withheld -> 18, the last D.
	eq_grade(nutri_score(solid(3_400, 15_000, 5_000, 100, 0, 9_000, 0)), .D, 18, "score 18 is the last D")

	// Five more grams of sugar is one more negative point, and that tips it
	// into E: 19 is the first E.
	eq_grade(nutri_score(solid(3_400, 20_000, 5_000, 100, 0, 9_000, 0)), .E, 19, "score 19 is an E")

	// Nothing at all declared is not an A; it is nothing.
	eq_grade(nutri_score(Nutrition{}), .None, 0, "a product with no nutrition table has no grade")

	// A plain yoghurt, for a sanity check against a real pot: N = 1 (4,6 g of
	// sugars), P = 2 (4 g of protein) -> -1, an A.
	eq_grade(nutri_score(solid(205, 4_600, 700, 60, 0, 4_000, 0)), .A, -1, "plain yoghurt is an A")
	// Semi-skimmed milk: scored on the general table, which is why it is a B.
	eq_grade(nutri_score(solid(196, 4_800, 900, 40, 0, 3_200, 0)), .B, 0, "semi-skimmed milk is a B")
	// Dried pasta.
	// Dried pasta: N = 4 (1490 kJ), P = 8 (3 g of fibre and 12,5 g of
	// protein) -> -4.
	eq_grade(nutri_score(solid(1_490, 3_000, 300, 10, 3_000, 12_500, 0)), .A, -4, "dried pasta is an A")
}

@(private = "file")
test_nutri_beverages :: proc() {
	// Water is graded A by the regulation, with no calculation at all.
	w := nutri_score(Nutrition{known = true, class = .Water, sodium_mg = 2})
	eq_grade(w, .A, 0, "water is an A by rule")

	// A cola: energy 180 kJ -> 6 on the beverage energy table, sugars 10,6 g
	// -> 8 on the beverage sugar table. N = 14, nothing positive.
	cola := nutri_score(Nutrition{known = true, class = .Beverage, energy_kj = 180, sugars_mg = 10_600, sodium_mg = 5})
	eq_grade(cola, .E, 14, "a sugared cola is an E")
	eq_int(i64(cola.pts_energy), 6, "on the beverage energy table, 180 kJ is 6 points")
	eq_int(i64(cola.pts_sugars), 8, "and 10,6 g of sugars is 8")

	// The same figures on the general table would be 0 and 2 — which is why
	// beverages need their own tables at all.
	as_solid := nutri_score(solid(180, 10_600, 0, 5, 0, 0, 0))
	eq_int(i64(as_solid.pts_energy), 0, "the general table scores 180 kJ at 0 points")
	eq_int(i64(as_solid.pts_sugars), 2, "and 10,6 g of sugars at 2")
	ok(as_solid.grade == .B, "so the cola would come out a B if it were scored as a solid, which is the trap")

	// A sugar-free cola: N = 1, which would be an A on the general table. No
	// beverage but water can be an A, so it is a B.
	zero := nutri_score(Nutrition{known = true, class = .Beverage, energy_kj = 2, sodium_mg = 10})
	eq_grade(zero, .B, 1, "a zero-sugar cola is a B")
	ok(zero.grade != .A, "because no drink except water may be graded A")

	// Pure orange juice: N = 12 (6 + 6), fruit 100 % gives 10 points on the
	// beverage fruit table, and because those points are at the maximum the
	// protein points are not withheld. 12 - 10 = 2, a C.
	oj := nutri_score(
		Nutrition {
			known = true,
			class = .Beverage,
			energy_kj = 180,
			sugars_mg = 9_000,
			fibre_mg = 200,
			protein_mg = 700,
			fruit_pct = 100,
		},
	)
	eq_grade(oj, .C, 2, "100 % orange juice is a C")
	eq_int(i64(oj.pts_fruit), 10, "the beverage fruit table goes to 10, not 5")
	ok(oj.protein_counted, "and fruit points at the maximum keep the protein rule from biting")

	// A nectar at 50 % fruit gets 2 fruit points, not 10.
	nectar := nutri_score(
		Nutrition{known = true, class = .Beverage, energy_kj = 200, sugars_mg = 11_000, fruit_pct = 50},
	)
	eq_int(i64(nectar.pts_fruit), 2, "50 % fruit is 2 points on the beverage table")
	eq_grade(nectar, .E, 13, "and the nectar is an E")
}

@(private = "file")
test_nutri_cheese_and_fats :: proc() {
	// Emmental: energy 1600 kJ -> 4, sugars 0, saturated fat 20 g -> 10,
	// sodium 320 mg -> 3. N = 17. Protein 28 g -> 5 points, and cheese is
	// named in the regulation as the exception to the protein rule, so they
	// count: 17 - 5 = 12, a D.
	emmental := solid(1_600, 0, 20_000, 320, 0, 28_000, 0, .Cheese)
	r := nutri_score(emmental)
	eq_grade(r, .D, 12, "Emmental is a D")
	ok(r.protein_counted, "because cheese always counts its protein")

	// The same figures without the cheese exemption: the protein points are
	// withheld, and the score is five points worse.
	not_cheese := emmental
	not_cheese.class = .Solid
	r2 := nutri_score(not_cheese)
	eq_grade(r2, .D, 17, "the same nutrition without the cheese rule scores 17, not 12")
	ok(!r2.protein_counted, "because its protein points are withheld")

	// Camembert is where the exemption changes the letter and not just the
	// number: 1240 kJ -> 3, sugars 0,5 g -> 0, sat fat 15 g -> 10, sodium
	// 700 mg -> 7. N = 20, protein 20 g -> 5. As a cheese that is 15, a D; on
	// the general table the protein is withheld and it is 20, an E.
	cam := nutri_score(solid(1_240, 500, 15_000, 700, 0, 20_000, 0, .Cheese))
	eq_grade(cam, .D, 15, "Camembert is a D")
	cam_solid := nutri_score(solid(1_240, 500, 15_000, 700, 0, 20_000, 0))
	eq_grade(cam_solid, .E, 20, "and would be an E without the cheese rule — the exemption changes the grade")

	// Olive oil. Two provisions apply at once, and both have to be right.
	//
	// First, for an added fat the saturated-fat component is the share of
	// total fat rather than grams per 100 g: 14 g of saturated fat in 100 g
	// of fat is 14 %, which is 1 point and not 10. Second, olive, rapeseed
	// and walnut oils are named in the fruit-and-vegetable component, so the
	// oil scores the maximum 5 positive points there — which is also what
	// releases the protein rule at 11 negative points.
	//
	// N = 10 + 0 + 1 + 0 = 11, P = 5, score 6: a C. That is the published
	// result, and it is the reason olive oil grades better than sunflower.
	oil := nutri_score(solid(3_700, 0, 14_000, 0, 0, 0, 100, .Added_Fat, 100_000))
	eq_grade(oil, .C, 6, "olive oil is a C")
	eq_int(i64(oil.pts_satfat), 1, "its saturated fat scores 1 point as a ratio")
	eq_int(i64(oil.pts_fruit), 5, "and olive oil counts as fruit for the positive component")

	// On the general table that same 14 g would be 10 points and the oil
	// would drop a grade, which is the mistake the added-fats table exists to
	// prevent.
	oil_wrong := nutri_score(solid(3_700, 0, 14_000, 0, 0, 0, 100))
	eq_int(i64(oil_wrong.pts_satfat), 10, "the general table would give it 10")
	eq_grade(oil_wrong, .D, 15, "and would grade olive oil a D")

	// Butter: 3060 kJ -> 9; 54 g of saturated fat in 82 g of fat is 65,9 %,
	// which is past the last threshold, so 10 points. N = 19 -> E.
	butter := nutri_score(solid(3_060, 600, 54_000, 10, 0, 700, 0, .Added_Fat, 82_000))
	eq_grade(butter, .E, 19, "butter is an E")
	eq_int(i64(butter.pts_satfat), 10, "its saturated-fat ratio is past the last threshold")

	// Sunflower oil: 11 g of 100 g is 11 %, which is 1 point, same as olive.
	sun := nutri_score(solid(3_700, 0, 11_000, 0, 0, 0, 0, .Added_Fat, 100_000))
	eq_int(i64(sun.pts_satfat), 1, "sunflower oil scores 1 point for saturated fat")
	eq_grade(sun, .D, 11, "and is a D")

	// The ratio table is on strict inequalities: exactly 10 % is 1 point, not 0.
	exact := nutri_score(solid(3_700, 0, 10_000, 0, 0, 0, 0, .Added_Fat, 100_000))
	eq_int(i64(exact.pts_satfat), 1, "exactly 10 % scores 1, because the table reads < 10 %")
}

// ---------------------------------------------------------------------------
// Sizes
// ---------------------------------------------------------------------------

@(private = "file")
conv :: proc(c: Size_Chart, label: string, from, to: Size_System, want: string, what: string) {
	got, found := size_convert(c, label, from, to)
	checks += 1
	if !found || got != want {
		failures += 1
		fmt.eprintfln("  FAIL  %s: got %q (found=%v), want %q", what, got, found, want)
	}
}

@(private = "file")
test_sizes :: proc() {
	// Womenswear. The French scale runs two sizes above the EU one, which is
	// the conversion that goes wrong most often.
	conv(.Women_Tops, "38", .FR, .EU, "36", "a women's FR 38 is an EU 36")
	conv(.Women_Tops, "38", .FR, .UK, "10", "and a UK 10")
	conv(.Women_Tops, "38", .FR, .US, "6", "and a US 6")
	conv(.Women_Tops, "38", .FR, .Alpha, "M", "and an M")
	conv(.Women_Tops, "36", .EU, .FR, "38", "and the conversion round-trips")
	conv(.Women_Tops, "10", .UK, .FR, "38", "from the UK scale too")
	conv(.Women_Tops, "42", .FR, .EU, "40", "a women's FR 42 is an EU 40")

	// Menswear. France quotes the same numbers as the rest of the EU here, so
	// the same input gives a different answer than it does for womenswear.
	conv(.Men_Tops, "48", .FR, .EU, "48", "a men's FR 48 is an EU 48 — no offset")
	conv(.Men_Tops, "48", .FR, .UK, "38", "and a UK 38")
	conv(.Men_Tops, "48", .FR, .Alpha, "M", "and an M")
	conv(.Men_Tops, "38", .UK, .FR, "48", "back from the UK scale")

	// The three disagreements, stated as assertions rather than as a comment.
	w, _ := size_convert(.Women_Tops, "M", .Alpha, .FR)
	m, _ := size_convert(.Men_Tops, "M", .Alpha, .FR)
	eq_str(w, "38", "an M is a 38 in womenswear")
	eq_str(m, "48", "and a 48 in menswear")
	ok(w != m, "so the same letter is a different number in each department")

	we, _ := size_convert(.Women_Tops, "40", .FR, .EU)
	me, _ := size_convert(.Men_Tops, "42", .FR, .EU)
	eq_str(we, "38", "FR 40 womenswear is EU 38")
	eq_str(me, "42", "FR 42 menswear is EU 42")

	wuk, _ := size_convert(.Women_Tops, "38", .EU, .UK)
	suk, _ := size_convert(.Women_Shoes, "38", .EU, .UK)
	eq_str(wuk, "12", "an EU 38 top is a UK 12")
	eq_str(suk, "5", "an EU 38 shoe is a UK 5")
	ok(wuk != suk, "the same EU number means something else on a shoe")

	// Children: France by age, the rest of the EU by height.
	conv(.Kids, "6 ans", .FR, .EU, "116", "a French 6 ans is 116 cm")
	conv(.Kids, "116", .EU, .FR, "6 ans", "and back")
	conv(.Kids, "116", .EU, .UK, "6Y", "a UK 6Y")
	conv(.Kids, "4 ans", .FR, .US, "4T", "a US 4T for a toddler")
	conv(.Kids, "6Y", .UK, .EU, "116", "the Y suffix is understood")
	conv(.Kids, "6", .FR, .EU, "116", "and so is the bare number")

	// Shoes, where the US column has half sizes.
	conv(.Men_Shoes, "42", .EU, .UK, "8", "a men's EU 42 is a UK 8")
	conv(.Men_Shoes, "42", .EU, .US, "9", "and a US 9")
	conv(.Men_Shoes, "44", .EU, .UK, "9,5", "a men's EU 44 is a UK 9,5")
	conv(.Women_Shoes, "38", .EU, .US, "7", "a women's EU 38 is a US 7")
	conv(.Women_Shoes, "42", .EU, .US, "10,5", "and an EU 42 is a US 10,5")
	got, _ := size_convert(.Men_Shoes, "9.5", .UK, .EU)
	eq_str(got, "44", "a UK 9.5 written with a point still resolves")

	// A size that is not in the table is refused, not guessed.
	_, found := size_convert(.Women_Tops, "99", .FR, .EU)
	ok(!found, "a size outside the chart is refused")
	_, found = size_convert(.Women_Shoes, "38", .EU, .Alpha)
	ok(!found, "a shoe has no S/M/L")

	// The filter: my size, their labels.
	bershka := []string{"32", "34", "36", "38", "40", "42"} // EU
	ok(
		size_matches(.Women_Tops, bershka, .EU, "38", .FR),
		"a shopper who is a French 38 matches a Bershka EU 36",
	)
	ok(
		!size_matches(.Women_Tops, bershka, .EU, "48", .FR),
		"and does not match a rail that stops at EU 42",
	)
	celio := []string{"S", "M", "L", "XL"} // alpha
	ok(size_matches(.Men_Tops, celio, .Alpha, "48", .FR), "a French 48 is Celio's M")
	ok(!size_matches(.Men_Tops, celio, .Alpha, "56", .FR), "a French 56 is not on that rail")

	all := size_all(.Women_Tops, "38", .FR, context.temp_allocator)
	ok(strings.contains(all, "FR 38") && strings.contains(all, "UK 10"), "every system in one line: %s", all)

	// Guessing the chart from a feed's category path.
	ok(chart_for("Vêtements > Femme > Robes") == .Women_Tops, "a dress is on the women's chart")
	ok(chart_for("Chaussures > Homme > Baskets") == .Men_Shoes, "trainers are on the men's shoe chart")
	ok(chart_for("Vêtements > Enfant > T-shirts") == .Kids, "a child's tee is on the kids' chart")
	ok(chart_for("Épicerie > Crèmerie") == .None, "a yoghurt has no size chart")
}

// ---------------------------------------------------------------------------
// Search
// ---------------------------------------------------------------------------

@(private = "file")
test_search :: proc() {
	eq_str(fold("Crème fraîche épaisse", context.temp_allocator), "creme fraiche epaisse", "folding strips the accents")
	eq_str(fold("CÔTE D'OR", context.temp_allocator), "cote d or", "and the case, and the apostrophe")
	eq_str(fold("Œufs", context.temp_allocator), "oeufs", "the oe ligature expands")
	eq_str(fold("Lait demi-écrémé UHT 1 L", context.temp_allocator), "lait demi ecreme uht 1 l", "punctuation becomes a space")

	hay := fold("Crème fraîche épaisse 30 % - 20 cl", context.temp_allocator)
	ok(matches_query(hay, fold("creme", context.temp_allocator)), "creme finds crème")
	ok(matches_query(hay, fold("crème", context.temp_allocator)), "and so does crème")
	ok(matches_query(hay, fold("cremes", context.temp_allocator)), "a plural in the query still matches")
	ok(matches_query(hay, fold("fraiche creme", context.temp_allocator)), "the tokens may be in any order")
	ok(matches_query(hay, fold("epaiss", context.temp_allocator)), "a prefix matches")
	ok(!matches_query(hay, fold("chocolat", context.temp_allocator)), "and an unrelated word does not")
	ok(!matches_query(hay, fold("creme chocolat", context.temp_allocator)), "every token must match, not just one")

	y := fold("Yaourts nature Danone", context.temp_allocator)
	ok(matches_query(y, fold("yaourt", context.temp_allocator)), "the singular finds the plural")
	ok(matches_query(y, fold("yaourts", context.temp_allocator)), "and the plural finds itself")

	p := fold("Pâtes Penne Panzani 500 g", context.temp_allocator)
	ok(matches_query(p, fold("pates", context.temp_allocator)), "pates finds Pâtes")
	ok(matches_query(p, fold("PÂTES", context.temp_allocator)), "in any case")

	g := fold("Gâteaux au chocolat", context.temp_allocator)
	ok(matches_query(g, fold("gateau", context.temp_allocator)), "the -eaux plural is handled")

	// Short words keep their s: `jus` must not be stemmed to `ju`.
	eq_str(singular("jus"), "jus", "jus stays jus")
	eq_str(singular("yaourts"), "yaourt", "yaourts loses its s")
	eq_str(singular("choux"), "chou", "choux loses its x")
	eq_str(singular("gateaux"), "gateau", "gateaux becomes gateau")

	// An empty query matches everything, which is what an empty search box
	// should do.
	ok(matches_query(hay, ""), "an empty query matches")

	// The match key, which is what groups the same product across retailers.
	k1 := match_key("Lactel", "Lait demi-écrémé UHT 1 L", context.temp_allocator)
	k2 := match_key("Lactel", "UHT lait demi écrémé (6x1L)", context.temp_allocator)
	eq_str(k1, k2, "word order, packaging and quantity do not change the match key")
	k3 := match_key("Lactel", "Lait entier UHT 1 L", context.temp_allocator)
	ok(k1 != k3, "but a different product does not share it")
	k4 := match_key("Candia", "Lait demi-écrémé UHT 1 L", context.temp_allocator)
	ok(k1 != k4, "and neither does a different brand")
	k5 := match_key("", "Lait demi-écrémé UHT 1 L", context.temp_allocator)
	k6 := match_key("", "Lait demi écrémé UHT - lot de 6 x 1 L", context.temp_allocator)
	eq_str(k5, k6, "two store brands of the same milk share a key whatever the pack size")
}

@(private = "file")
test_ean :: proc() {
	ok(ean13_valid("3560070462018"), "a valid EAN-13")
	ok(!ean13_valid("3560070462019"), "one digit off fails the check")
	ok(!ean13_valid("356007046201"), "twelve digits is not an EAN-13")
	ok(!ean13_valid("35600704620181"), "nor is fourteen")
	ok(!ean13_valid("356007046201X"), "nor one with a letter in it")
	d, good := ean13_check_digit("356007046201")
	ok(good && d == '8', "the check digit of 356007046201 is 8")
	_, good = ean13_check_digit("35600704620")
	ok(!good, "a body of the wrong length is refused")
}

// ---------------------------------------------------------------------------
// Feeds
// ---------------------------------------------------------------------------

GOOD_FEED :: `<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0" xmlns:g="http://base.google.com/ns/1.0">
<channel>
<title>Carrefour</title>
<item>
  <g:id>CRF-1</g:id>
  <g:title>Confiture de fraises Bonne Maman 370 g</g:title>
  <g:brand>Bonne Maman</g:brand>
  <g:gtin>3560070462018</g:gtin>
  <g:price>3,20 EUR</g:price>
  <g:availability>in stock</g:availability>
  <g:product_type>Épicerie &gt; Épicerie sucrée &gt; Confitures</g:product_type>
  <g:shipping><g:country>FR</g:country><g:price>4,90 EUR</g:price></g:shipping>
</item>
<item>
  <g:id>CRF-2</g:id>
  <g:title><![CDATA[Bière blonde 33 cl — lot de 6]]></g:title>
  <g:brand>Kronenbourg &amp; Cie</g:brand>
  <g:price>5,99 EUR</g:price>
  <g:sale_price>4,74 EUR</g:sale_price>
  <g:availability>out of stock</g:availability>
  <g:unit_pricing_measure>lot de 6 x 33 cl</g:unit_pricing_measure>
  <shop:tva>20</shop:tva>
</item>
<!-- a comment, which is legal and must be skipped -->
</channel>
</rss>
`

@(private = "file")
test_feed_xml :: proc() {
	res := parse_merchant_xml(GOOD_FEED, .Carrefour)
	defer feed_result_destroy(&res)

	eq_str(res.fatal, "", "a well-formed feed has no fatal error")
	eq_int(i64(len(res.products)), 2, "both items were read")
	eq_str(res.title, "Carrefour", "the channel title names the retailer")
	if len(res.products) < 2 {
		return
	}

	a := res.products[0]
	eq_str(a.id, "CRF-1", "the id")
	eq_str(a.title, "Confiture de fraises Bonne Maman 370 g", "the title, accents intact")
	eq_money(a.price, 320, "a price written with a comma decimal is read as 3,20 €")
	eq_str(a.gtin, "3560070462018", "the barcode survived")
	ok(strings.has_prefix(a.key, "gtin:"), "and is used as the identity")
	eq_money(a.shipping, 490, "the nested shipping price was read")
	ok(strings.contains(a.category, "Épicerie > Épicerie sucrée"), "the entity-escaped category path decoded: %s", a.category)
	ok(a.avail == .In_Stock, "availability")
	ok(a.tva == .Food, "a jam with no stated rate is food at 5,5 %")
	ok(a.qty.ok && a.qty.amount == 370_000, "the quantity came out of the title")
	u, _ := unit_price(a.price, a.qty)
	eq_money(u, 865, "3,20 € for 370 g is 8,65 €/kg")

	b := res.products[1]
	eq_str(b.title, "Bière blonde 33 cl — lot de 6", "a CDATA title")
	eq_str(b.brand, "Kronenbourg & Cie", "an &amp; in a brand name decoded")
	eq_money(b.list_price, 599, "the reference price")
	eq_money(b.price, 474, "and the promotional price is the one charged")
	ok(on_promo(b), "so it is on promotion")
	eq_int(discount_tenths(b), 209, "20,9 % off")
	ok(b.avail == .Out_Of_Stock, "out of stock was understood")
	eq_int(b.qty.amount, 1_980_000, "the unit_pricing_measure field gave 1,98 L")
	ub, _ := unit_price(b.price, b.qty)
	eq_money(ub, 239, "and 4,74 € for 1,98 L is 2,39 €/L")
	ok(b.gtin == "", "no barcode was published")
	ok(!strings.has_prefix(b.key, "gtin:"), "so it is matched on its title instead")

	// Entities, including the numeric forms.
	eq_str(decode_entities("a &amp; b &lt;c&gt; &quot;d&quot;", context.temp_allocator), "a & b <c> \"d\"", "the five named entities")
	eq_str(decode_entities("Cr&#232;me", context.temp_allocator), "Crème", "a decimal numeric entity")
	eq_str(decode_entities("Cr&#xE8;me", context.temp_allocator), "Crème", "a hexadecimal one")
	eq_str(decode_entities("100&nbsp;%", context.temp_allocator), "100 %", "and &nbsp;")
	eq_str(decode_entities("a &unknown; b", context.temp_allocator), "a &unknown; b", "an unknown entity is left alone rather than dropped")
}

@(private = "file")
test_feed_refusals :: proc() {
	// A missing price. The item is refused with a reason and the rest of the
	// feed still imports.
	src := `<rss><channel><item><g:id>A</g:id><g:title>Sans prix</g:title></item>` +
	       `<item><g:id>B</g:id><g:title>Avec prix 500 g</g:title><g:price>1,99 EUR</g:price></item></channel></rss>`
	res := parse_merchant_xml(src, .Leclerc)
	defer feed_result_destroy(&res)
	eq_int(i64(len(res.products)), 1, "the item with no price was refused and the other kept")
	eq_int(i64(len(res.errors)), 1, "one refusal was recorded")
	if len(res.errors) == 1 {
		ok(strings.contains(res.errors[0].reason, "prix"), "and it says the price was missing: %s", res.errors[0].reason)
		eq_str(res.errors[0].item, "A", "naming the item")
	}

	// An unknown currency. Taking 12.99 USD as 12,99 € would be a wrong price.
	res2 := parse_merchant_xml(
		`<rss><channel><item><g:id>C</g:id><g:title>Dollars</g:title><g:price>12.99 USD</g:price></item></channel></rss>`,
		.Leclerc,
	)
	defer feed_result_destroy(&res2)
	eq_int(i64(len(res2.products)), 0, "a price in dollars is refused")
	if len(res2.errors) == 1 {
		ok(strings.contains(res2.errors[0].reason, "devise"), "with the currency named: %s", res2.errors[0].reason)
	}

	// A comma decimal must be accepted: it is the French convention, not an
	// error.
	res3 := parse_merchant_xml(
		`<rss><channel><item><g:id>D</g:id><g:title>Virgule 1 kg</g:title><g:price>12,99 EUR</g:price></item></channel></rss>`,
		.Leclerc,
	)
	defer feed_result_destroy(&res3)
	eq_int(i64(len(res3.products)), 1, "a comma decimal is accepted")
	if len(res3.products) == 1 {
		eq_money(res3.products[0].price, 1299, "and reads as 12,99 €")
	}

	// A truncated document: the file ends inside the feed.
	trunc := parse_merchant_xml(
		`<rss><channel><item><g:id>E</g:id><g:title>Tronqué</g:title><g:price>1,00 EUR</g:price>`,
		.Leclerc,
	)
	defer feed_result_destroy(&trunc)
	ok(trunc.fatal != "", "a truncated document is a fatal error: %s", trunc.fatal)
	ok(strings.contains(trunc.fatal, "tronqu"), "and says so")

	// A tag that never closes.
	t2 := parse_merchant_xml(`<rss><channel><item><g:title>pas de fin`, .Leclerc)
	defer feed_result_destroy(&t2)
	ok(t2.fatal != "", "an unterminated tag is fatal")

	// A mismatched closing tag.
	t3 := parse_merchant_xml(`<rss><channel></rss></channel>`, .Leclerc)
	defer feed_result_destroy(&t3)
	ok(t3.fatal != "", "a mismatched closing tag is fatal: %s", t3.fatal)

	// A file that is not a feed at all.
	t4 := parse_merchant_xml(`<html><body>Bonjour</body></html>`, .Leclerc)
	defer feed_result_destroy(&t4)
	ok(t4.fatal != "", "an HTML page is not a product feed")

	// A barcode whose check digit is wrong: the product is kept but matched on
	// its title, because trusting it could merge two unrelated products.
	t5 := parse_merchant_xml(
		`<rss><channel><item><g:id>F</g:id><g:title>Mauvais code 1 kg</g:title>` +
		`<g:gtin>3560070462019</g:gtin><g:price>2,00 EUR</g:price></item></channel></rss>`,
		.Leclerc,
	)
	defer feed_result_destroy(&t5)
	eq_int(i64(len(t5.products)), 1, "a product with a bad barcode is still imported")
	if len(t5.products) == 1 {
		eq_str(t5.products[0].gtin, "", "but the barcode is discarded")
		ok(!strings.has_prefix(t5.products[0].key, "gtin:"), "and it is matched on its title")
	}
	ok(len(t5.errors) == 1, "and the problem was reported")

	// A promotional price above the reference price is a contradiction.
	t6 := parse_merchant_xml(
		`<rss><channel><item><g:id>G</g:id><g:title>Promo absurde</g:title>` +
		`<g:price>2,00 EUR</g:price><g:sale_price>3,00 EUR</g:sale_price></item></channel></rss>`,
		.Leclerc,
	)
	defer feed_result_destroy(&t6)
	eq_int(i64(len(t6.products)), 0, "a sale price above the list price is refused")
}

@(private = "file")
test_feed_csv :: proc() {
	// Semicolons, because a French exporter cannot use commas: the decimal
	// mark is already a comma. And a quoted field containing the delimiter.
	src :=
		"id;title;brand;price;sale_price;availability;product_type;unit_pricing_measure;tva;enseigne\n" +
		"ITM-1;\"Lait demi-écrémé UHT 1 L; bouteille\";Lactel;1,05;;in stock;Épicerie > Crèmerie;1 L;5,5;Intermarché\n" +
		"ITM-2;Pâtes Penne 500 g;Panzani;1,45;0,99;in stock;Épicerie > Épicerie salée;500 g;5,5;Intermarché\n"
	res := parse_merchant_csv(src, .None)
	defer feed_result_destroy(&res)

	eq_str(res.fatal, "", "the CSV parsed")
	eq_int(i64(len(res.products)), 2, "two rows")
	if len(res.products) == 2 {
		eq_str(res.products[0].title, "Lait demi-écrémé UHT 1 L; bouteille", "a quoted field kept its semicolon")
		eq_money(res.products[0].price, 105, "1,05 € read from a bare number")
		ok(res.products[0].retailer == .Intermarche, "the retailer column was honoured")
		ok(res.products[0].tva == .Food, "and the 5,5 % rate")
		eq_money(res.products[1].price, 99, "the sale price is the one charged")
		eq_money(res.products[1].list_price, 145, "with 1,45 € as the reference")
		u, _ := unit_price(res.products[1].price, res.products[1].qty)
		eq_money(u, 198, "0,99 € for 500 g is 1,98 €/kg")
	}

	// A row with the wrong number of columns is refused, not guessed at.
	bad := parse_merchant_csv("id;title;price\nX;Trop;1,00;extra\n", .None)
	defer feed_result_destroy(&bad)
	eq_int(i64(len(bad.products)), 0, "a row with too many fields is refused")
	eq_int(i64(len(bad.errors)), 1, "with a reason")

	// Tab separated, which is what Google's own documentation uses.
	tsv := "id\ttitle\tprice\nT-1\tRiz long grain 1 kg\t2,65\n"
	res2 := parse_merchant_csv(tsv, .Carrefour)
	defer feed_result_destroy(&res2)
	eq_int(i64(len(res2.products)), 1, "a tab-separated feed is detected")
	if len(res2.products) == 1 {
		eq_money(res2.products[0].price, 265, "and read")
	}

	// An empty file.
	empty := parse_merchant_csv("", .None)
	defer feed_result_destroy(&empty)
	ok(empty.fatal != "", "an empty file is refused")
}

// ---------------------------------------------------------------------------
// The catalogue
// ---------------------------------------------------------------------------

@(private = "file")
test_catalogue :: proc() {
	c := Catalog{}
	defer catalog_destroy(&c)
	fixture_build(&c)

	ok(len(c.products) > 2000, "the generated catalogue holds a few thousand products: %d", len(c.products))
	ok(c.generated, "and is flagged as generated, so the UI can say so")
	ok(strings.contains(c.source, "démonstration"), "its provenance is stated: %s", c.source)

	// Every barcode validates, because the comparison groups on them.
	bad := 0
	with_gtin := 0
	for p in c.products {
		if p.gtin != "" {
			with_gtin += 1
			if !ean13_valid(p.gtin) {
				bad += 1
			}
		}
	}
	eq_int(i64(bad), 0, "every generated barcode passes its check digit")
	ok(with_gtin > 1000, "and most groceries have one: %d", with_gtin)

	// Every grocery product has a unit price; no garment does.
	no_unit_grocery := 0
	unit_on_clothing := 0
	for p in c.products {
		if retailer_kind(p.retailer) == .Grocery && !p.has_unit {
			no_unit_grocery += 1
		}
		if retailer_kind(p.retailer) == .Clothing && p.has_unit {
			unit_on_clothing += 1
		}
	}
	eq_int(i64(no_unit_grocery), 0, "every grocery line has a prix au kilo or au litre")
	eq_int(i64(unit_on_clothing), 0, "and no garment pretends to have one")

	// The comparison: find the national-brand milk and check the group spans
	// the three chains and is ordered by unit price.
	milk := -1
	for p, i in c.products {
		if p.brand == "Lactel" && strings.contains(p.title, "demi-écrémé") && p.qty.count == 1 {
			milk = i
			break
		}
	}
	ok(milk >= 0, "the fixture contains a branded semi-skimmed milk")
	if milk >= 0 {
		g := group_of(&c, milk, context.temp_allocator)
		ok(len(g) >= 6, "its comparison group spans several chains and pack sizes: %d", len(g))
		chains := [Retailer]bool{}
		for i in g {
			chains[c.products[i].retailer] = true
		}
		ok(
			chains[.Intermarche] && chains[.Leclerc] && chains[.Carrefour],
			"all three grocery chains are in the comparison",
		)
		// Ordered by unit price, in-stock first.
		prev := Centimes(0)
		ordered := true
		for i in g {
			p := c.products[i]
			if p.avail != .In_Stock {
				continue
			}
			if p.has_unit {
				if p.unit < prev {
					ordered = false
				}
				prev = p.unit
			}
		}
		ok(ordered, "and ordered by the price per litre, not by the sticker")
		// The honest comparison: somewhere in this group the cheapest sticker
		// is not the cheapest litre.
		cheapest_sticker := -1
		cheapest_unit := -1
		for i in g {
			p := c.products[i]
			if p.avail != .In_Stock || !p.has_unit {
				continue
			}
			if cheapest_sticker < 0 || p.price < c.products[cheapest_sticker].price {
				cheapest_sticker = i
			}
			if cheapest_unit < 0 || p.unit < c.products[cheapest_unit].unit {
				cheapest_unit = i
			}
		}
		ok(
			cheapest_sticker >= 0 && cheapest_unit >= 0 && cheapest_sticker != cheapest_unit,
			"the cheapest sticker in the group is not the cheapest litre — which is why the unit price is computed",
		)
	}

	// A store brand at three chains groups together even though every chain
	// gives it a different barcode.
	mdd := -1
	for p, i in c.products {
		if p.brand == "" && retailer_kind(p.retailer) == .Grocery && p.gtin != "" {
			mdd = i
			break
		}
	}
	ok(mdd >= 0, "the fixture contains store-brand groceries")
	if mdd >= 0 {
		g := group_of(&c, mdd, context.temp_allocator)
		chains := 0
		seen := [Retailer]bool{}
		for i in g {
			r := c.products[i].retailer
			if !seen[r] {
				seen[r] = true
				chains += 1
			}
		}
		ok(chains >= 2, "store brands are matched across chains on the title, since their barcodes differ: %d chains", chains)
	}

	// Clothing: the same garment at two chains, in two size systems.
	tee := -1
	for p, i in c.products {
		if p.retailer == .Celio && strings.contains(p.title, "T-shirt") {
			tee = i
			break
		}
	}
	if tee >= 0 {
		g := group_of(&c, tee, context.temp_allocator)
		systems := 0
		seen := [Size_System]bool{}
		for i in g {
			s := c.products[i].size_system
			if !seen[s] {
				seen[s] = true
				systems += 1
			}
		}
		ok(systems >= 2, "a garment compares across chains that label sizes differently: %d systems", systems)
	}

	// Determinism: the same seed gives the same catalogue, which is what lets
	// a basket total be asserted at all.
	c2 := Catalog{}
	defer catalog_destroy(&c2)
	fixture_build(&c2)
	eq_int(i64(len(c2.products)), i64(len(c.products)), "the same seed gives the same number of products")
	same := true
	for i in 0 ..< min(200, len(c.products)) {
		if c.products[i].price != c2.products[i].price || c.products[i].id != c2.products[i].id {
			same = false
		}
	}
	ok(same, "and the same prices")

	// Price history ends at today's price and is the right length.
	for p, i in c.products {
		if i > 200 {
			break
		}
		checks += 1
		if p.history[HISTORY_LEN - 1] != p.price {
			failures += 1
			fmt.eprintfln("  FAIL  the last history point must be today's price (%s)", p.title)
			break
		}
	}
	drops := 0
	for p in c.products {
		if p.price < history_min(p) + 1 && history_max(p) > p.price {
			drops += 1
		}
	}
	ok(drops > 50, "a good number of products are at their lowest recorded price: %d", drops)
}

// ---------------------------------------------------------------------------
// The basket
// ---------------------------------------------------------------------------

@(private = "file")
test_basket :: proc() {
	// A basket built by hand, so the total can be asserted to the centime.
	//
	//   3 x 2,99 € at 5,5 %  =  8,97 € TTC  ->  8,50 € HT + 0,47 € TVA
	//   1 x 12,50 € at 20 %  = 12,50 € TTC  -> 10,42 € HT + 2,08 € TVA
	//   2 x 1,99 € at 10 %   =  3,98 € TTC  ->  3,62 € HT + 0,36 € TVA
	//                           -------         -------------------
	//                           25,45 € TTC     22,54 € HT + 2,91 € TVA
	st := new(State)
	defer free(st)
	st.cat.products = make([dynamic]Product)
	defer delete(st.cat.products)
	st.basket = make([dynamic]Basket_Line)
	defer delete(st.basket)

	append(&st.cat.products, Product{retailer = .Carrefour, price = 299, tva = .Food})
	append(&st.cat.products, Product{retailer = .Carrefour, price = 1250, tva = .Standard})
	append(&st.cat.products, Product{retailer = .Leclerc, price = 199, tva = .Reduced})
	append(&st.basket, Basket_Line{product = 0, qty = 3})
	append(&st.basket, Basket_Line{product = 1, qty = 1})
	append(&st.basket, Basket_Line{product = 2, qty = 2})

	t := basket_totals(st)
	eq_money(t.ttc, 2545, "the basket total is 25,45 € exactly")
	eq_money(t.ht, 2254, "22,54 € HT")
	eq_money(t.tva, 291, "2,91 € of TVA")
	eq_money(t.ht + t.tva, t.ttc, "HT and TVA add up to the total, to the centime")
	eq_money(t.by_tva[.Food], 47, "0,47 € collected at 5,5 %")
	eq_money(t.by_tva[.Standard], 208, "2,08 € at 20 %")
	eq_money(t.by_tva[.Reduced], 36, "0,36 € at 10 %")
	eq_money(t.by_retailer[.Carrefour], 2147, "21,47 € of it at Carrefour")
	eq_money(t.by_retailer[.Leclerc], 398, "3,98 € at Leclerc")
	eq_money(t.by_retailer[.Carrefour] + t.by_retailer[.Leclerc], t.ttc, "and the per-chain subtotals sum to the total")
	eq_int(i64(t.items), 6, "six items")
	eq_int(i64(t.lines), 3, "on three lines")

	// Thirty lines of 10 centimes is exactly 3,00 € — the sum a float would
	// get wrong. 0.1 is not representable in binary, so thirty of them in f32
	// drift; in centimes it is thirty times ten.
	clear(&st.basket)
	clear(&st.cat.products)
	append(&st.cat.products, Product{retailer = .Leclerc, price = 10, tva = .Food})
	append(&st.basket, Basket_Line{product = 0, qty = 30})
	t2 := basket_totals(st)
	eq_money(t2.ttc, 300, "thirty times ten centimes is 3,00 €, exactly")
	f: f32 = 0
	for _ in 0 ..< 30 {
		f += 0.1
	}
	ok(f != 3.0, "whereas thirty f32 additions of 0.1 do not give 3.0 — which is why none of this is floating point")

	// An empty basket is zero, not an error.
	clear(&st.basket)
	t3 := basket_totals(st)
	eq_money(t3.ttc, 0, "an empty basket costs nothing")
}

@(private = "file")
test_list_and_alerts :: proc() {
	st := new(State)
	defer free(st)
	st.compare_of = -1
	st.query = make([dynamic]u8)
	st.vis = make([dynamic]int)
	st.basket = make([dynamic]Basket_Line)
	st.list = make([dynamic]List_Item)
	st.alerts = make([dynamic]Alert)
	st.brands = make([dynamic]string)
	st.colors = make([dynamic]string)
	st.data_dir = strings.clone("")
	defer {
		delete(st.query)
		delete(st.vis)
		delete(st.basket)
		delete(st.list)
		delete(st.alerts)
		for b in st.brands {
			delete(b)
		}
		delete(st.brands)
		for c in st.colors {
			delete(c)
		}
		delete(st.colors)
		delete(st.data_dir)
		catalog_destroy(&st.cat)
	}
	fixture_build(&st.cat)
	build_facets(st)
	refilter(st)

	ok(len(st.vis) == len(st.cat.products), "with no filter every product is visible")

	// The grocery list groups by rayon, in shopping order.
	added := 0
	for p, i in st.cat.products {
		if retailer_kind(p.retailer) != .Grocery || p.avail != .In_Stock {
			continue
		}
		list_add(st, i)
		added += 1
		if added >= 12 {
			break
		}
	}
	grouped := list_by_aisle(st, context.temp_allocator)
	eq_int(i64(len(grouped)), i64(len(st.list)), "every list item appears exactly once when grouped by rayon")
	// Aisles must come out in enum order.
	last := Aisle.None
	in_order := true
	for gi in grouped {
		a := st.cat.products[st.list[gi].product].aisle
		if int(a) < int(last) {
			in_order = false
		}
		last = a
	}
	ok(in_order, "and the rayons come out in the order the shop is walked")

	listed, best := list_total(st)
	ok(best <= listed, "shopping the list at the cheapest chain is never more expensive: %s vs %s",
		fmt_money(best, context.temp_allocator), fmt_money(listed, context.temp_allocator))

	// Ticking an item off.
	list_toggle(st, 0)
	ok(st.list[0].done, "an item can be ticked off")
	list_toggle(st, 0)
	ok(!st.list[0].done, "and un-ticked")
	st.list[1].done = true
	before := len(st.list)
	list_clear_done(st)
	eq_int(i64(len(st.list)), i64(before - 1), "clearing the ticked items removes exactly those")

	// Alerts.
	target := st.list[0].product
	price := st.cat.products[target].price
	alert_set(st, target, price - 1)
	ok(alert_find(st, target) >= 0, "an alert can be armed")
	ok(!alert_hit(st, st.alerts[0]), "and does not fire above the threshold")
	alert_set(st, target, price)
	ok(alert_hit(st, st.alerts[0]), "but fires when the price reaches it")
	alert_set(st, target)
	eq_money(st.alerts[0].threshold, Centimes(i64(price) * 95 / 100), "the default threshold is five percent below today")
	alert_clear(st, target)
	ok(alert_find(st, target) < 0, "and can be cleared")

	// Filtering: each facet, asserted by counting.
	st.filter.retailers[.Kiabi] = true
	refilter(st)
	only_kiabi := true
	for i in st.vis {
		if st.cat.products[i].retailer != .Kiabi {
			only_kiabi = false
		}
	}
	ok(only_kiabi && len(st.vis) > 0, "the retailer filter restricts to one chain: %d rows", len(st.vis))
	st.filter.retailers[.Kiabi] = false

	st.filter.nutri_max = .B
	refilter(st)
	good_only := true
	for i in st.vis {
		g := st.cat.products[i].nutri.grade
		if g == .None || int(g) > int(Nutri.B) {
			good_only = false
		}
	}
	ok(good_only && len(st.vis) > 0, "the Nutri-Score filter keeps only A and B: %d rows", len(st.vis))
	st.filter.nutri_max = .None

	st.filter.promo_only = true
	refilter(st)
	promos := len(st.vis)
	all_promo := true
	for i in st.vis {
		if !on_promo(st.cat.products[i]) {
			all_promo = false
		}
	}
	ok(all_promo && promos > 0, "the promotions filter keeps only discounted lines: %d", promos)
	st.filter.promo_only = false

	st.filter.price_max = 200
	refilter(st)
	cheap := true
	for i in st.vis {
		if st.cat.products[i].price > 200 {
			cheap = false
		}
	}
	ok(cheap && len(st.vis) > 0, "the price ceiling holds: %d rows under 2,00 €", len(st.vis))
	st.filter.price_max = 0

	// The one-key "ma taille" toggle: on, off, and remembered in between.
	ok(toggle_my_size(st), "ma taille turns on")
	eq_str(st.filter.size_label, "38", "and defaults to a French 38")
	ok(st.filter.size_chart == .Women_Tops, "on the womenswear chart")
	with_size := len(st.vis)
	ok(with_size > 0, "which finds garments: %d", with_size)
	only_clothing := true
	for i in st.vis {
		if retailer_kind(st.cat.products[i].retailer) != .Clothing {
			only_clothing = false
		}
	}
	ok(only_clothing, "and only garments, since a yoghurt has no size")
	ok(!toggle_my_size(st), "pressing it again turns it off")
	eq_str(st.filter.size_label, "", "clearing the live filter")
	eq_str(st.saved_size_label, "38", "but remembering the size")
	ok(toggle_my_size(st), "so turning it back on restores it")
	eq_int(i64(len(st.vis)), i64(with_size), "to exactly the same rows")
	toggle_my_size(st)
	st.filter.dept = .All

	// My size, across chains that label differently.
	st.filter.size_label = strings.clone("38")
	st.filter.size_system = .FR
	st.filter.size_chart = .Women_Tops
	refilter(st)
	n_fr38 := len(st.vis)
	ok(n_fr38 > 0, "filtering on a French 38 finds garments: %d", n_fr38)
	systems := [Size_System]bool{}
	for i in st.vis {
		systems[st.cat.products[i].size_system] = true
	}
	ok(systems[.FR] && systems[.EU], "including rails labelled in EU sizes, not just the French ones")
	delete(st.filter.size_label)
	st.filter.size_label = ""
	st.filter.size_chart = .None
	refilter(st)

	// Search.
	clear(&st.query)
	append(&st.query, ..transmute([]u8)string("creme"))
	refilter(st)
	hits := len(st.vis)
	ok(hits > 0, "an unaccented search finds the accented products: %d hits for creme", hits)
	accented := false
	for i in st.vis {
		if strings.contains(st.cat.products[i].title, "Crème") {
			accented = true
		}
	}
	ok(accented, "and the results contain Crème with its accent")

	clear(&st.query)
	append(&st.query, ..transmute([]u8)string("zzzznotathing"))
	refilter(st)
	eq_int(i64(len(st.vis)), 0, "a search for nothing finds nothing, and does not crash")
	clear(&st.query)
	refilter(st)

	// Sorting by unit price puts the cheapest kilo first and the things
	// without a kilo last.
	st.sort = .Unit_Up
	refilter(st)
	prev := Centimes(0)
	seen_unitless := false
	ordered := true
	for i in st.vis {
		p := st.cat.products[i]
		if !p.has_unit {
			seen_unitless = true
			continue
		}
		if seen_unitless {
			ordered = false // something with a unit price after something without
		}
		if p.unit < prev {
			ordered = false
		}
		prev = p.unit
	}
	ok(ordered, "sorting by prix au kilo is monotonic, with the unitless products last")
	st.sort = .Relevance
	refilter(st)
}

// ---------------------------------------------------------------------------
// The round trip: generate, write a feed, read it back
// ---------------------------------------------------------------------------

@(private = "file")
test_round_trip :: proc() {
	dir := strings.concatenate({data_dir(context.temp_allocator), "/selftest"}, context.temp_allocator)
	os.make_directory_all(dir)

	c := Catalog{}
	defer catalog_destroy(&c)
	fixture_build(&c)

	xml_path := strings.concatenate({dir, "/feed.xml"}, context.temp_allocator)
	csv_path := strings.concatenate({dir, "/feed.csv"}, context.temp_allocator)
	ok(write_merchant_xml(xml_path, &c, .Carrefour), "the catalogue exports as an RSS product feed")
	ok(write_merchant_csv(csv_path, &c, .Carrefour), "and as a CSV one")

	expect := 0
	for p in c.products {
		if p.retailer == .Carrefour {
			expect += 1
		}
	}

	back := import_feed(xml_path, .Carrefour)
	defer feed_result_destroy(&back)
	eq_str(back.fatal, "", "and reads back without a fatal error")
	eq_int(i64(len(back.products)), i64(expect), "with every item intact")

	// Spot-check that the numbers survived the trip, including the nutrition
	// block and therefore the Nutri-Score.
	matched := 0
	for p in c.products {
		if p.retailer != .Carrefour {
			continue
		}
		for q in back.products {
			if q.id != p.id {
				continue
			}
			matched += 1
			if q.price != p.price || q.list_price != p.list_price {
				ok(false, "price survived the round trip for %s", p.id)
			}
			if q.has_unit != p.has_unit || q.unit != p.unit {
				ok(false, "unit price survived the round trip for %s (%v vs %v)", p.id, p.unit, q.unit)
			}
			if q.nutri.grade != p.nutri.grade {
				ok(false, "Nutri-Score survived the round trip for %s", p.id)
			}
			if q.tva != p.tva {
				ok(false, "the TVA rate survived the round trip for %s", p.id)
			}
			break
		}
	}
	eq_int(i64(matched), i64(expect), "every exported item was found again by id")

	back2 := import_feed(csv_path, .Carrefour)
	defer feed_result_destroy(&back2)
	eq_str(back2.fatal, "", "the CSV reads back too")
	eq_int(i64(len(back2.products)), i64(expect), "with the same item count")

	// A second import of the same feed shifts the price history along rather
	// than duplicating the products, which is how a weekly feed accumulates.
	before := len(c.products)
	again := import_feed(xml_path, .Carrefour)
	added, updated := catalog_absorb(&c, &again)
	feed_result_destroy(&again)
	eq_int(i64(added), 0, "re-importing the same feed adds nothing")
	eq_int(i64(updated), i64(expect), "and updates every item it names")
	eq_int(i64(len(c.products)), i64(before), "so the catalogue does not grow")

	os.remove(xml_path)
	os.remove(csv_path)
}

@(private = "file")
test_persistence :: proc() {
	dir := strings.concatenate({data_dir(context.temp_allocator), "/selftest"}, context.temp_allocator)
	os.make_directory_all(dir)

	st := new(State)
	st.compare_of = -1
	st.query = make([dynamic]u8)
	st.vis = make([dynamic]int)
	st.basket = make([dynamic]Basket_Line)
	st.list = make([dynamic]List_Item)
	st.alerts = make([dynamic]Alert)
	st.brands = make([dynamic]string)
	st.colors = make([dynamic]string)
	st.data_dir = strings.clone(dir)
	fixture_build(&st.cat)

	append(&st.basket, Basket_Line{product = 7, qty = 3})
	append(&st.list, List_Item{product = 11, qty = 2, done = true})
	append(&st.alerts, Alert{product = 11, threshold = 123})
	st.sort = .Unit_Up
	st.filter.size_label = strings.clone("38")
	ok(save_state(st), "the basket and the list are written to ~/.local/share/palmy-shop")

	st2 := new(State)
	st2.compare_of = -1
	st2.query = make([dynamic]u8)
	st2.vis = make([dynamic]int)
	st2.basket = make([dynamic]Basket_Line)
	st2.list = make([dynamic]List_Item)
	st2.alerts = make([dynamic]Alert)
	st2.brands = make([dynamic]string)
	st2.colors = make([dynamic]string)
	st2.data_dir = strings.clone(dir)
	fixture_build(&st2.cat)
	load_state(st2)

	eq_int(i64(len(st2.basket)), 1, "the basket came back")
	if len(st2.basket) == 1 {
		eq_int(i64(st2.basket[0].product), 7, "pointing at the same product")
		eq_int(i64(st2.basket[0].qty), 3, "with the same quantity")
	}
	eq_int(i64(len(st2.list)), 1, "the list came back")
	if len(st2.list) == 1 {
		ok(st2.list[0].done, "with the ticked item still ticked")
	}
	eq_int(i64(len(st2.alerts)), 1, "the alert came back")
	if len(st2.alerts) == 1 {
		eq_money(st2.alerts[0].threshold, 123, "with its threshold")
	}
	ok(st2.sort == .Unit_Up, "and the chosen sort order")
	eq_str(st2.saved_size_label, "38", "and the shopper's own size, remembered for next time")

	// The file names products by retailer and feed id, so it survives a
	// catalogue whose indices have moved.
	data, err := os.read_entire_file(state_path(st2), context.temp_allocator)
	ok(err == nil, "the state file is readable text")
	if err == nil {
		text := string(data)
		ok(!strings.contains(text, "\tindex\t"), "and holds no array indices")
		ok(strings.contains(text, "panier\t"), "it names the basket in French, like the rest of the app")
	}

	os.remove(state_path(st2))
	os.remove(dir)
	free(st)
	free(st2)
}

// ---------------------------------------------------------------------------
// Performance
//
// Not a claim, a measurement. A search that takes 30 ms is a search that
// stutters, so the number is printed every run and the assertion is only that
// it is in the right order of magnitude.
// ---------------------------------------------------------------------------

@(private = "file")
test_performance :: proc() {
	st := new(State)
	defer free(st)
	st.compare_of = -1
	st.query = make([dynamic]u8)
	st.vis = make([dynamic]int)
	st.basket = make([dynamic]Basket_Line)
	st.list = make([dynamic]List_Item)
	st.alerts = make([dynamic]Alert)
	st.brands = make([dynamic]string)
	st.colors = make([dynamic]string)
	st.data_dir = strings.clone("")
	fixture_build(&st.cat)
	build_facets(st)

	fmt.println("")
	fmt.printfln("  catalogue: %d products, %d exact groups, %d equivalence groups",
		len(st.cat.products), len(st.cat.groups), len(st.cat.equiv))

	bench :: proc(st: ^State, label: string, reps: int) -> f64 {
		start := time.now()
		for _ in 0 ..< reps {
			refilter(st)
		}
		ms := f64(time.diff(start, time.now())) / 1e6 / f64(reps)
		fmt.printfln("  %-34s %6.3f ms  (%d rows)", label, ms, len(st.vis))
		return ms
	}

	clear(&st.query)
	no_filter := bench(st, "no query, no filter", 20)

	clear(&st.query)
	append(&st.query, ..transmute([]u8)string("lait"))
	one_token := bench(st, "search \"lait\"", 20)

	clear(&st.query)
	append(&st.query, ..transmute([]u8)string("creme fraiche epaisse"))
	three_tokens := bench(st, "search \"creme fraiche epaisse\"", 20)

	clear(&st.query)
	st.filter.in_stock = true
	st.filter.nutri_max = .C
	st.filter.dept = .Grocery
	with_facets := bench(st, "three facets, no query", 20)
	st.filter = Filter{}
	st.filter.size_system = .FR

	st.sort = .Unit_Up
	clear(&st.query)
	unit_sorted := bench(st, "sorted by prix au kilo", 20)
	st.sort = .Relevance

	ok(no_filter < 60, "an unfiltered pass over the whole catalogue stays interactive: %.3f ms", no_filter)
	ok(one_token < 60, "a one-word search stays interactive: %.3f ms", one_token)
	ok(three_tokens < 60, "a three-word search too: %.3f ms", three_tokens)
	ok(with_facets < 60, "and so does a facet combination: %.3f ms", with_facets)
	ok(unit_sorted < 80, "sorting on the unit price is affordable: %.3f ms", unit_sorted)

	// The comparison group, which is the other thing a keystroke can trigger.
	start := time.now()
	n := 0
	for i in 0 ..< min(500, len(st.cat.products)) {
		g := group_of(&st.cat, i, context.temp_allocator)
		n += len(g)
	}
	per := f64(time.diff(start, time.now())) / 1e6 / 500
	fmt.printfln("  %-34s %6.3f ms  (avg group %d)", "group_of, averaged over 500", per, n / 500)
	ok(per < 2, "building a comparison group is cheap: %.3f ms", per)

	catalog_destroy(&st.cat)
	delete(st.query)
	delete(st.vis)
	delete(st.basket)
	delete(st.list)
	delete(st.alerts)
	for b in st.brands {
		delete(b)
	}
	delete(st.brands)
	for c in st.colors {
		delete(c)
	}
	delete(st.colors)
	delete(st.data_dir)
	fmt.println("")
}

// ---------------------------------------------------------------------------
// The command line
//
// The binary is run again as a child, against a scratch data directory, so
// the assertions are about what a caller actually receives: the document on
// stdout, the exit code, and the state file the window reads afterwards.
// ---------------------------------------------------------------------------

@(private = "file")
cli_run :: proc(dir: string, args: ..string) -> (out: string, code: int) {
	self, err := os.get_executable_path(context.temp_allocator)
	if err != nil {
		self = os.args[0]
	}
	line := strings.builder_make(context.temp_allocator)
	strings.write_string(&line, "WAYLAND_DISPLAY= DISPLAY= ")
	strings.write_string(&line, fmt.tprintf("PALMY_SHOP_DIR=%q PALM_AUDIT=%q %q", dir, fmt.tprintf("%s/audit.jsonl", dir), self))
	for a in args {
		strings.write_string(&line, fmt.tprintf(" %q", a))
	}
	state, sout, _, perr := os.process_exec({command = {"sh", "-c", strings.to_string(line)}}, context.temp_allocator)
	if perr != nil {
		return "", -1
	}
	return string(sout), state.exit_code
}

@(private = "file")
schema_ok :: proc(out: string, fields: []kit.Field, what: string) {
	problems := kit.cli_validate_output(out, fields, context.temp_allocator)
	ok(len(problems) == 0, "%s matches its declared schema%s", what, len(problems) > 0 ? fmt.tprintf(" (%s)", problems[0]) : "")
}

@(private = "file")
test_cli :: proc() {
	dir := fmt.tprintf("/tmp/palmy-shop-cli-%d", os.get_pid())
	os.make_directory_all(dir)
	defer os.remove_all(dir)

	sf := surface()
	ok(sf.noun == "shop", "the surface is named shop")
	for cmd in sf.commands {
		ok(cmd.run != nil && cmd.summary != "" && len(cmd.out) > 0 && len(cmd.examples) > 0, "%s is declared whole", cmd.verb)
		for ex in cmd.examples {
			words := kit.cli_split_example(ex, context.temp_allocator)
			ok(len(words) > 0 && words[0] == "shop", "the example %q starts with the binary", ex)
			args := make([dynamic]string, context.temp_allocator)
			for w in words[1:] {
				append(&args, w)
			}
			append(&args, "--parse-only")
			_, code := cli_run(dir, ..args[:])
			eq_int(i64(code), 0, fmt.tprintf("the example %q parses", ex))
		}
	}

	// Reads on an empty state: documents, not errors.
	{
		out, code := cli_run(dir, "basket", "--json")
		eq_int(i64(code), 0, "basket on an empty state exits 0")
		schema_ok(out, BASKET_FIELDS, "basket")
		out, code = cli_run(dir, "list", "--json")
		schema_ok(out, LIST_FIELDS, "list")
		out, code = cli_run(dir, "alerts", "--json")
		schema_ok(out, ALERTS_FIELDS, "alerts")
	}

	// Search goes through the window's refilter: the same query and facet
	// give the same count in process.
	{
		out, code := cli_run(dir, "search", "lait", "--retailer", "Leclerc", "--limit", "0", "--json")
		eq_int(i64(code), 0, "search exits 0")
		schema_ok(out, SEARCH_FIELDS, "search")
		st := new(State)
		state_init(st)
		append(&st.query, "lait")
		st.filter.retailers[.Leclerc] = true
		refilter(st)
		ok(strings.contains(out, fmt.tprintf(`"matched": %d`, len(st.vis))), "and finds what the window's search finds (%d)", len(st.vis))
		ok(len(st.vis) > 0, "which is something")
	}
	{
		out, code := cli_run(dir, "search", "--retailer", "Nowhere", "--json")
		eq_int(i64(code), 2, "an unknown chain is a usage error")
		ok(strings.contains(out, `"error": "usage"`), "with the documented error object")
	}
	{
		out, code := cli_run(dir, "show", "LEC-0000-0", "--json")
		eq_int(i64(code), 0, "show exits 0")
		schema_ok(out, SHOW_FIELDS, "show")
		out, code = cli_run(dir, "show", "E.Leclerc:LEC-0000-0", "--json")
		eq_int(i64(code), 0, "a product is found as Retailer:id too")
		out, code = cli_run(dir, "show", "NOPE-1", "--json")
		eq_int(i64(code), 3, "an unknown product exits 3")
		ok(strings.contains(out, `"error": "not found"`), "with the documented error object")
		out, code = cli_run(dir, "compare", "LEC-0000-0", "--json")
		schema_ok(out, COMPARE_FIELDS, "compare")
		ok(strings.count(out, `"retailer": "Carrefour"`) > 0, "and the comparison spans chains")
	}

	// Changes land in the file the window loads.
	{
		out, code := cli_run(dir, "basket-add", "LEC-0000-0", "--qty", "2", "--json")
		eq_int(i64(code), 0, "basket-add exits 0")
		schema_ok(out, CHANGED_FIELDS, "basket-add")
		_, _ = cli_run(dir, "list-add", "CRF-0000-1", "--json")
		_, _ = cli_run(dir, "list-check", "CRF-0000-1", "--json")
		out, code = cli_run(dir, "list-check", "CRF-0000-1", "--json")
		ok(strings.contains(out, `"changed": false`), "list-check is safe to repeat")
		_, _ = cli_run(dir, "alert-set", "LEC-0000-0", "--below", "1,10", "--json")
		_, _ = cli_run(dir, "basket-add", "ITM-0000-0", "--dry-run", "--json")

		st := new(State)
		st.compare_of = -1
		st.query = make([dynamic]u8)
		st.vis = make([dynamic]int)
		st.basket = make([dynamic]Basket_Line)
		st.list = make([dynamic]List_Item)
		st.alerts = make([dynamic]Alert)
		st.brands = make([dynamic]string)
		st.colors = make([dynamic]string)
		st.data_dir = strings.clone(dir)
		fixture_build(&st.cat)
		load_state(st)
		eq_int(i64(len(st.basket)), 1, "the window's load_state sees one basket line (the dry run wrote nothing)")
		if len(st.basket) == 1 {
			eq_str(st.cat.products[st.basket[0].product].id, "LEC-0000-0", "the line the CLI added")
			eq_int(i64(st.basket[0].qty), 2, "with its quantity")
		}
		eq_int(i64(len(st.list)), 1, "and one list item")
		ok(len(st.list) == 1 && st.list[0].done, "ticked")
		eq_int(i64(len(st.alerts)), 1, "and one alert")
		if len(st.alerts) == 1 {
			eq_money(st.alerts[0].threshold, 110, "at the threshold given")
		}

		out, code = cli_run(dir, "basket", "--json")
		schema_ok(out, BASKET_FIELDS, "basket with a line in it")
		ok(strings.contains(out, `"ttc_cents": 238`), "and its total is two litres of milk")
		out, code = cli_run(dir, "alerts", "--json")
		schema_ok(out, ALERTS_FIELDS, "alerts with one armed")
		out, code = cli_run(dir, "list-clear-done", "--json")
		ok(strings.contains(out, `"removed": 1`), "list-clear-done drops the ticked item")
	}

	// Export and check close the loop on the feed formats.
	{
		out, code := cli_run(dir, "export", "--json")
		eq_int(i64(code), 0, "export exits 0")
		schema_ok(out, EXPORT_FIELDS, "export")
		feed := fmt.tprintf("%s/catalogue-demo.xml", dir)
		ok(os.exists(feed), "and the feed is in the application's directory")
		out, code = cli_run(dir, "check", feed, "--json")
		eq_int(i64(code), 0, "check reads it back")
		schema_ok(out, CHECK_FIELDS, "check")
		out, code = cli_run(dir, fmt.tprintf("--check=%s", feed))
		eq_int(i64(code), 0, "the old --check=<feed> spelling still works")
		_, code = cli_run(dir, "check", fmt.tprintf("%s/missing.xml", dir), "--json")
		eq_int(i64(code), 3, "a feed that is not there exits 3")
	}

	// The audit log records changes and not reads.
	{
		audit, _ := os.read_entire_file(fmt.tprintf("%s/audit.jsonl", dir), context.temp_allocator)
		ok(strings.contains(string(audit), `"verb":"basket-add"`), "a change leaves an audit record")
		ok(!strings.contains(string(audit), `"verb":"basket"`) && !strings.contains(string(audit), `"verb":"search"`), "a read does not")
	}
}
