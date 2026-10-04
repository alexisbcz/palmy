// Shop — a price comparison desktop application for the French market, on
// palmy.
//
// Clothing across Kiabi, Bershka and Celio; groceries across Intermarché,
// E.Leclerc and Carrefour. Browse, search, filter, compare the same product
// between chains on its price per kilo, build a basket with its TVA breakdown
// and a shopping list grouped by rayon.
//
// SAFETY, stated once and true everywhere below.
//
//   - **There is no network code in this binary.** No socket is opened, no
//     host resolved, no URL fetched, and nothing is scraped. Kiabi, Leclerc,
//     Carrefour and the rest prohibit automated access in their terms, a
//     scraper would break the week after it was written, and none of it is
//     needed: the formats those retailers already publish for comparison
//     sites — Google Merchant Center's RSS 2.0 product feed and its CSV
//     variant — are implemented as the import path, and the catalogue shipped
//     here is generated locally.
//   - **The catalogue says it is generated**, in the status bar of every view
//     and in every export it writes, so nobody can mistake it for a live
//     price.
//   - **Reads** are limited to a feed file the user explicitly names, either
//     on the command line or through the file dialog. The user's home
//     directory is never scanned.
//   - **Writes** go only to ~/.local/share/palmy-shop: the basket, the list,
//     the alerts, and the exported demonstration feeds.
//   - No telemetry, no accounts, no payment of any kind. This browses and
//     compares; it does not buy. There is no personal data in any fixture.
package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import kit "kit:."
import p "palmy:."

FONT_DIR :: "/home/alex/Work/palmy/parity/web/public/fonts"

MONO_FONTS :: [?]string {
	"/usr/share/fonts/TTF/JetBrainsMonoNerdFont-Regular.ttf",
	"/usr/share/fonts/TTF/DejaVuSansMono.ttf",
	"/usr/share/fonts/liberation/LiberationMono-Regular.ttf",
}

main :: proc() {
	// The modes that need no window, handled before one is opened.
	import_arg := ""
	for arg in os.args[1:] {
		switch {
		case arg == "--selftest":
			os.exit(run_selftest())
		case arg == "--help" || arg == "-h":
			usage()
			os.exit(0)
		case arg == "--export":
			os.exit(run_export())
		case strings.has_prefix(arg, "--check="):
			os.exit(run_check(arg[len("--check="):]))
		case strings.has_prefix(arg, "--walkthrough"):
			dir := "/tmp/palmy-shop-walkthrough"
			if eq := strings.index_byte(arg, '='); eq > 0 {
				dir = arg[eq + 1:]
			}
			os.exit(run_uitest(dir, true))
		case strings.has_prefix(arg, "--uitest"):
			dir := "/tmp/palmy-shop-uitest"
			if eq := strings.index_byte(arg, '='); eq > 0 {
				dir = arg[eq + 1:]
			}
			os.exit(run_uitest(dir))
		case strings.has_prefix(arg, "--import="):
			import_arg = arg[len("--import="):]
		case strings.has_prefix(arg, "-"):
			fmt.eprintfln("shop: option inconnue %q", arg)
			usage()
			os.exit(2)
		case:
			import_arg = arg
		}
	}

	app, err := kit.start(
		{
			title = "Comparateur",
			app_id = "palmy-shop",
			width = 1440,
			height = 900,
			min_width = 1040,
			min_height = 600,
			root_class = "w-full h-full bg-background text-foreground",
		},
	)
	if err != "" {
		fmt.eprintfln("shop: %s", err)
		os.exit(1)
	}
	defer p.destroy(app)

	st := new(State)
	state_init(st)
	if import_arg != "" {
		import_path(st, import_arg)
		fmt.printfln("shop: %s", st.import_msg)
	}

	// A recording wants real time on the clock. palmy only draws when
	// something changed, which is right for a desktop and wrong for a camera:
	// an idle window emits no frames, so a screen recorder tags the handful it
	// gets as if they were consecutive and a thirty-second walkthrough comes
	// out as six seconds. SHOP_DEMO=1 keeps the frame clock running so the
	// recording has the timing the viewer saw.
	demo := os.get_env("SHOP_DEMO", context.temp_allocator) != ""

	for ui in p.frames(app) {
		start := time.now()
		if demo {
			p.redraw(ui)
		}
		st.now = f64(p.app_elapsed(app))
		measure(ui, st)
		handle_keys(ui, st, app)
		frame(ui, st)
		// The frame time reported in the status bar is the build cost of the
		// tree, measured rather than guessed. Painting is palmy's half.
		st.frame_ms = f64(time.diff(start, time.now())) / 1e6
	}
}

usage :: proc() {
	fmt.println(
		`shop — comparateur de prix (France), sur palmy

  shop                      ouvre la fenêtre avec le catalogue généré
  shop <fichier>            importe un flux produits et l'ouvre
  shop --import=<fichier>   idem
  shop --export             écrit le catalogue en flux Merchant (XML + CSV)
  shop --check=<fichier>    lit un flux et dit ce qu'il contient et ce qu'il refuse
  shop --selftest           vérifie les calculs, sans fenêtre
  shop --uitest[=dossier]   rend l'interface hors écran en PNG
  shop --walkthrough[=dir]  filme la visite image par image (20 i/s)

Formats d'import: Google Merchant Center RSS 2.0 (namespace g:) et sa variante
CSV/TSV. Aucun accès réseau: rien n'est téléchargé ni collecté en ligne, et le
catalogue livré est généré localement — ce ne sont pas des prix réels.`,
	)
}

// run_check reads a feed and reports what it found and what it refused,
// without opening a window. It is how a feed is diagnosed before it is
// imported, and it is the shortest demonstration that bad input is refused
// rather than swallowed.
run_check :: proc(path: string) -> int {
	res := import_feed(path)
	defer feed_result_destroy(&res)

	fmt.printfln("%s", path)
	if res.title != "" {
		fmt.printfln("  flux: %s", res.title)
	}
	if res.fatal != "" {
		fmt.printfln("  REFUSÉ: %s", res.fatal)
		return 1
	}
	fmt.printfln("  %d produits lus, %d refusés", len(res.products), len(res.errors))
	for e in res.errors {
		fmt.printfln("    refusé %-16s %s", e.item, e.reason)
	}
	shown := min(5, len(res.products))
	for i in 0 ..< shown {
		p := res.products[i]
		fmt.printfln(
			"    %-12s %-44s %10s  %12s  %s",
			retailer_name(p.retailer),
			utf8_truncate(p.title, 44, context.temp_allocator),
			fmt_money(p.price, context.temp_allocator),
			p.has_unit ? fmt_unit_price(p.price, p.qty, context.temp_allocator) : "—",
			p.nutri.grade != .None ? nutri_letter(p.nutri.grade) : "",
		)
	}
	return len(res.errors) > 0 ? 0 : 0
}

run_export :: proc() -> int {
	st := new(State)
	state_init(st)
	xp, cp, good := export_fixture(st)
	if !good {
		fmt.eprintfln("shop: écriture impossible dans %s", st.data_dir)
		return 1
	}
	fmt.printfln("%d produits écrits:", len(st.cat.products))
	fmt.printfln("  %s", xp)
	fmt.printfln("  %s", cp)
	return 0
}
