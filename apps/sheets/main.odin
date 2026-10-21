// Sheets — a spreadsheet for palmy.
//
// The engine lives in value.odin, refs.odin, parse.odin, eval.odin,
// sheet.odin and ops.odin; the application is app.odin, grid.odin, keys.odin
// and ui.odin. `sheets --selftest` runs the engine's test suite with no
// window at all.
package main

import "core:fmt"
import "core:os"
import "core:strings"
import kit "kit:."
import p "palmy:."
import collabui "../../cloud/collab/ui"

// The usage text and the headless exporter that used to live here are gone:
// `--help` is generated from the declaration in cli.odin, and `--export` is a
// command there. Two front ends over one engine means one description of it
// too — a hand-written usage string is the first thing to go out of date.
main :: proc() {
	// The command line is the other front end over the same engine: see
	// cli.odin for the declaration and apps/kit/cli.odin for the convention
	// it is parsed by. --selftest, --export, --shot and --film are commands
	// there now, with their old spellings kept as aliases. With no command,
	// or with a path, there is a window.
	ca, rest := collabui.parse_args(os.args[1:])
	if ca.doc == "" {
		if code, handled := kit.cli(surface()); handled {
			os.exit(code)
		}
	}

	app_win, err := kit.start({title = "Sheets", width = 1240, height = 760, min_width = 720, min_height = 420})
	if err != "" {
		fmt.eprintfln("sheets: %s", err)
		os.exit(1)
	}
	defer p.destroy(app_win)

	app := new(App)
	defer free(app)
	app_init(app)
	defer app_destroy(app)
	load_italics(&app_win.fonts)
	app.fonts = &app_win.fonts
	app.pal = palette_build()
	app.name = strings.clone("Untitled")

	loaded := false
	for arg in rest {
		if strings.has_prefix(arg, "-") {
			continue
		}
		if strings.has_suffix(arg, ".csv") || strings.has_suffix(arg, ".tsv") {
			// `book.csv` that is not there but whose `book-<Sheet>.csv`
			// files are: the several-sheet export, read back as a book.
			if ok, rows, cols, n := csv_open(app.sh, arg, {0, 0}); ok {
				sync_sheet(app)
				if n > 0 {
					set_status(app, "Imported %d sheets from %s", n, base_name(arg))
				} else {
					set_status(app, "Imported %d x %d from %s", rows, cols, base_name(arg))
				}
				loaded = true
			}
		} else if strings.has_suffix(arg, ".xlsx") {
			if ok, sheets, cells := xlsx_read_book(app.book, arg); ok {
				// The name follows the file, but `path` deliberately does
				// not: Ctrl+S writes the native JSON, and it must not land on
				// top of the workbook that was imported.
				sync_sheet(app)
				if app.name != "" {
					delete(app.name)
				}
				app.name = strings.clone(base_name(arg))
				set_status(app, "Imported %d sheet(s), %d cells, from %s", sheets, cells, base_name(arg))
				loaded = true
			}
		} else {
			if cur, anc, ok := doc_load_file(app.book.sheets[0], arg); ok {
				sync_sheet(app)
				app.cur, app.anchor = cur, anc
				set_path(app, arg)
				set_status(app, "Opened %s", arg)
				loaded = true
			}
		}
		break
	}
	if !loaded {
		seed_demo(app)
	}
	if ca.doc != "" {
		if ca.script != "" {
			os.exit(run_script(app, app_win, ca))
		}
		if e := collab_start(app, app_win, ca); e != "" {
			fmt.eprintfln("sheets: %s", e)
			os.exit(1)
		}
	}

	for ui in p.frames(app_win) {
		// The viewport is measured before the keyboard runs, because Page
		// Up/Down and following the cursor both need to know what fits.
		measure_viewport(app, p.size(ui))
		handle_keys(ui, app)
		handle_pointer(ui, app)
		collab_tick(ui, app)
		if app.quit {
			p.quit_app(app_win)
			break
		}
		frame(ui, app)
		retitle(app_win, app)
	}
}

@(private = "file")
last_title: string

retitle :: proc(win: ^p.App, app: ^App) {
	t := fmt.tprintf("%s%s — Sheets", app.modified ? "*" : "", app.name)
	if t != last_title {
		if last_title != "" {
			delete(last_title)
		}
		last_title = strings.clone(t)
		p.set_title(win, last_title)
	}
}

// seed_demo gives an empty launch something to look at and to try the keys
// on, the way a spreadsheet's sample book does. It is a *book*, because the
// thing worth showing is the cross-sheet reference: Summary reads Sales, and
// the chart on Summary reads the cells those formulas write.
seed_demo :: proc(app: ^App) {
	bk := app.book
	book_rename_sheet(bk, 0, "Sales")
	sales := bk.sheets[0]

	set_input(sales, {0, 0}, "Regional sales, 2026")
	set_cell_fmt(sales, {0, 0}, {bold = true, align = .Center})
	add_merge(sales, {0, 0, 0, 3})

	rows := [?][3]string {
		{"Region", "Units", "Price"},
		{"North", "120", "4.50"},
		{"South", "86", "4.50"},
		{"East", "203", "3.95"},
		{"West", "154", "4.25"},
		{"Central", "97", "4.10"},
	}
	for r, i in rows {
		for v, j in r {
			set_input(sales, {i + 1, j}, v)
		}
	}
	set_input(sales, {1, 3}, "Revenue")
	for i in 2 ..= 6 {
		set_input(sales, {i, 3}, fmt.tprintf("=B%d*C%d", i + 1, i + 1))
	}
	set_input(sales, {8, 0}, "Total")
	set_input(sales, {8, 1}, "=SUM(B3:B7)")
	set_input(sales, {8, 3}, "=SUM(D3:D7)")
	for col in 2 ..= 3 {
		for row in 2 ..= 8 {
			set_cell_fmt(sales, {row, col}, {num = .Currency, dec = 2})
		}
	}
	for col in 0 ..= 3 {
		set_cell_fmt(sales, {1, col}, {bold = true, align = .Center})
	}
	set_cell_fmt(sales, {8, 0}, {bold = true})
	set_cell_fmt(sales, {8, 1}, {bold = true})
	set_cell_fmt(sales, {8, 3}, {num = .Currency, dec = 2, bold = true})
	set_col_width(sales, 0, 120)
	set_col_width(sales, 3, 110)
	// A header row and a label column that stay put while the sheet scrolls.
	set_freeze(sales, 2, 1)

	// The summary tab: nothing but cross-sheet references, which is the point.
	sum := book_add_sheet(bk, "Summary")
	set_input(sum, {0, 0}, "Region")
	set_input(sum, {0, 1}, "Revenue")
	set_cell_fmt(sum, {0, 0}, {bold = true})
	set_cell_fmt(sum, {0, 1}, {bold = true, align = .Center})
	for i in 1 ..= 5 {
		set_input(sum, {i, 0}, fmt.tprintf("=Sales!A%d", i + 2))
		set_input(sum, {i, 1}, fmt.tprintf("=Sales!D%d", i + 2))
		set_cell_fmt(sum, {i, 1}, {num = .Currency, dec = 2})
	}
	set_input(sum, {7, 0}, "Total")
	set_input(sum, {7, 1}, "=SUM(Sales!D3:D7)")
	set_cell_fmt(sum, {7, 0}, {bold = true})
	set_cell_fmt(sum, {7, 1}, {num = .Currency, dec = 2, bold = true})
	set_input(sum, {8, 0}, "Average")
	set_input(sum, {8, 1}, "=AVERAGE(Sales!D3:D7)")
	set_cell_fmt(sum, {8, 1}, {num = .Currency, dec = 2})
	set_input(sum, {9, 0}, "Best region")
	set_input(sum, {9, 1}, "=INDEX(Sales!A3:A7,MATCH(MAX(Sales!D3:D7),Sales!D3:D7,0))")
	set_input(sum, {10, 0}, "Units sold")
	set_input(sum, {10, 1}, "=Sales!B9")
	set_col_width(sum, 0, 130)
	set_col_width(sum, 1, 110)
	book_set_name(bk, "Revenue", "Sales", {2, 3, 6, 3})

	append(
		&sum.charts,
		Chart {
			kind = .Bar,
			title = strings.clone("Revenue by region", sum.heap),
			sheet = strings.clone("", sum.heap),
			rect = {0, 0, 5, 1},
			at = {0, 3},
			w = 7,
			h = 14,
		},
	)

	book_recalc_all(bk)
	use_sheet(app, 0)
	app.modified = false
	set_status(app, "F1 for the keyboard map")
}
