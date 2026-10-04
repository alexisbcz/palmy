// `money --bench [n]`: how long an import takes, and how long a search takes
// over the result.
//
// Both numbers matter for different reasons. The import is a one-off per file,
// so a second would be tolerable — but it is also the operation most likely
// to be quadratic by accident, because de-duplication compares every incoming
// row against what is already there, and doing that with a linear scan per
// row is the classic way to make a 5 000-row import take a minute. The
// de-duplication here is a hash map, and this benchmark is what says so.
//
// The search is the opposite: it runs on every keystroke, so the budget is a
// frame. The filter is a linear pass with no index, which is a deliberate
// choice, and the only honest way to defend it is to measure it.
package main

import "core:fmt"
import "core:strings"
import "core:time"

bench_mode :: proc(args: []string) -> int {
	n := 5000
	if len(args) > 0 {
		v := 0
		ok := false
		for ch in args[0] {
			if ch < '0' || ch > '9' {
				ok = false
				break
			}
			v = v * 10 + int(ch - '0')
			ok = true
		}
		if ok && v > 0 {
			n = v
		}
	}

	fmt.printfln("money --bench: %d opérations", n)

	// Build a CSV with n rows, in the awkward French form, and time the whole
	// import path: decode, sniff, parse, de-duplicate, book, categorise.
	csv := bench_csv(n)
	defer delete(csv)
	fmt.printfln("  fichier CSV: %d octets", len(csv))

	app := new(App)
	defer free(app)
	app_init(app)
	defer app_destroy(app)
	ensure_categories(app)
	acct := account_add(&app.led, "Compte courant", .Asset, FX_IBAN_CURRENT)

	t0 := time.now()
	s := parse_text(csv, nil, "bench.csv")
	parse_ms := time.duration_milliseconds(time.since(t0))

	t1 := time.now()
	rep := statement_ingest(app, s, acct)
	ingest_ms := time.duration_milliseconds(time.since(t1))
	statement_destroy(s)
	free(s)

	fmt.printfln(
		"  %-28s %8s ms   (%d lignes, %.1f µs/ligne)",
		"analyse",
		fmt.tprintf("%.2f", parse_ms),
		n,
		parse_ms * 1000 / f64(max(n, 1)),
	)
	fmt.printfln(
		"  %-28s %8s ms   (%d ajoutées, %d doublons, %d catégorisées)",
		"comptabilisation",
		fmt.tprintf("%.2f", ingest_ms),
		rep.added,
		rep.duplicates,
		rep.categorised,
	)
	fmt.printfln(
		"  %-28s %8s ms",
		"TOTAL import",
		fmt.tprintf("%.2f", parse_ms + ingest_ms),
	)
	if rep.problem != "" {
		fmt.printfln("  PROBLÈME: %s", rep.problem)
	}

	// Re-importing the same file must add nothing, and that is the path that
	// does the most de-duplication work.
	t2 := time.now()
	s2 := parse_text(csv, nil, "bench.csv")
	rep2 := statement_ingest(app, s2, acct)
	redup_ms := time.duration_milliseconds(time.since(t2))
	statement_destroy(s2)
	free(s2)
	fmt.printfln(
		"  %-28s %8s ms   (%d ajoutées, %d doublons)",
		"ré-import (dédoublonnage)",
		fmt.tprintf("%.2f", redup_ms),
		rep2.added,
		rep2.duplicates,
	)

	// The invariant over the whole book.
	t3 := time.now()
	pb := ledger_check(&app.led)
	check_ms := time.duration_milliseconds(time.since(t3))
	fmt.printfln(
		"  %-28s %8s ms   (%s)",
		"vérification partie double",
		fmt.tprintf("%.2f", check_ms),
		pb.ok ? "équilibré" : pb.what,
	)

	// Filtering: the five cases the list actually runs.
	bench_filter(app, "tout", proc(a: ^App) {
		a.filter = Filter{account = -1, category = -1, range = .All}
		clear(&a.search)
	})
	bench_filter(app, "recherche «carrefour»", proc(a: ^App) {
		a.filter = Filter{account = -1, category = -1, range = .All}
		clear(&a.search)
		append(&a.search, "carrefour")
	})
	bench_filter(app, "mois courant", proc(a: ^App) {
		a.filter = Filter{account = -1, category = -1, range = .This_Month}
		clear(&a.search)
	})
	bench_filter(app, "montant > 50 €", proc(a: ^App) {
		a.filter = Filter{account = -1, category = -1, range = .All, by_min = true, min = 5000}
		clear(&a.search)
	})
	bench_filter(app, "non catégorisé", proc(a: ^App) {
		a.filter = Filter{account = -1, category = -1, range = .All, only_todo = true}
		clear(&a.search)
	})

	// Recurrence detection over the whole book.
	t4 := time.now()
	recs := find_recurrences(&app.led, app.today, context.allocator)
	rec_ms := time.duration_milliseconds(time.since(t4))
	fmt.printfln(
		"  %-28s %8s ms   (%d trouvées; le bruit aléatoire n'en contient pas)",
		"détection récurrences",
		fmt.tprintf("%.2f", rec_ms),
		len(recs),
	)
	for r in recs {
		delete(r.key)
		delete(r.label)
		delete(r.txns)
	}
	delete(recs)

	// Serialising the whole book, which is what a quit costs.
	t5 := time.now()
	text := store_text(app, context.allocator)
	save_ms := time.duration_milliseconds(time.since(t5))
	fmt.printfln(
		"  %-28s %8s ms   (%d octets)",
		"sérialisation",
		fmt.tprintf("%.2f", save_ms),
		len(text),
	)
	t6 := time.now()
	app2 := new(App)
	app_init(app2)
	np, problems := store_parse(app2, text)
	load_ms := time.duration_milliseconds(time.since(t6))
	fmt.printfln(
		"  %-28s %8s ms   (%d opérations, %d refusées, %s)",
		"relecture",
		fmt.tprintf("%.2f", load_ms),
		np,
		problems,
		ledger_check(&app2.led).ok ? "équilibré" : "DÉSÉQUILIBRÉ",
	)
	app_destroy(app2)
	free(app2)
	delete(text)
	return 0
}

// bench_filter times `refilter` five times and reports the best, because the
// first pass pays for whatever the allocator has to do and the question here
// is what a keystroke costs once the application is warm.
@(private = "file")
bench_filter :: proc(app: ^App, what: string, setup: proc(a: ^App)) {
	setup(app)
	best := f64(1e9)
	for _ in 0 ..< 5 {
		t := time.now()
		refilter(app)
		ms := time.duration_milliseconds(time.since(t))
		if ms < best {
			best = ms
		}
	}
	fmt.printfln(
		"  %-28s %8s ms   (%d lignes)",
		fmt.tprintf("filtre: %s", what),
		fmt.tprintf("%.3f", best),
		len(app.rows),
	)
}

// bench_csv generates a statement in the hardest of the CSV forms this
// importer handles: a preamble, separate Débit and Crédit columns, French
// amounts with grouped thousands, and DD/MM/YYYY dates.
@(private = "file")
bench_csv :: proc(n: int, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, "Relevé de compte - BANQUE ALPHA (exemple)\n")
	strings.write_string(&b, "Compte n° ")
	strings.write_string(&b, FX_IBAN_CURRENT)
	strings.write_string(&b, " - TITULAIRE EXEMPLE\n\n")
	strings.write_string(&b, "Date;Libellé;Débit;Crédit;Solde\n")

	r := rng_make(777)
	today := today_date()
	balance := Cents(100000)
	for i in 0 ..< n {
		// Spread the rows back over whatever number of months it takes.
		back := (i * 400) / max(n, 1)
		d := date_add(today, -back)
		shop := SHOPS[rng_int(&r, 0, len(SHOPS) - 1)]
		amount := Cents(rng_int(&r, 150, 24000))
		credit := rng_int(&r, 0, 11) == 0
		if credit {
			balance += amount
		} else {
			balance -= amount
		}
		fmt.sbprintf(&b, "%s;", date_text(d, context.temp_allocator))
		if credit {
			fmt.sbprintf(&b, "VIR %s REMBOURSEMENT;;", shop)
		} else {
			fmt.sbprintf(&b, "CB %s %02d%02d;", shop, d.d, d.m)
		}
		money_write(&b, amount, false)
		if credit {
			strings.write_byte(&b, ';')
		} else {
			strings.write_string(&b, ";;")
		}
		money_write(&b, balance, false)
		strings.write_byte(&b, '\n')
	}
	return strings.to_string(b)
}
