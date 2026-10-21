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
	// The window-only modes keep their own spellings and are handled first;
	// everything else is the command line declared in cli.odin, where
	// `--selftest`, `--help`, `--export` and `--check=<feed>` now live.
	import_arg := ""
	legacy := false
	args := os.args[1:]
	for arg, i in args {
		switch {
		case arg == "--shots" || strings.has_prefix(arg, "--shots="):
			// Render the interface offscreen and write PNGs. See shot.odin.
			dir := ""
			if eq := strings.index_byte(arg, '='); eq > 0 {
				dir = arg[eq + 1:]
			} else if i + 1 < len(args) {
				dir = args[i + 1]
			}
			if dir == "" {
				fmt.eprintln("shop --shots <dossier>")
				os.exit(2)
			}
			os.exit(run_shots(dir))
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
			legacy = true
		}
	}

	if !legacy {
		if code, handled := kit.cli(surface()); handled {
			os.exit(code)
		}
		// Not a command: no arguments, or a bare feed path for the window.
		// A word that is neither a command nor a file is a typo, and the
		// answer to a typo is not a window that never returns to its caller.
		if len(args) > 0 {
			if !os.exists(args[0]) {
				fmt.eprintfln("shop: %q is neither a command nor a feed file (shop --help)", args[0])
				os.exit(2)
			}
			import_arg = args[0]
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
