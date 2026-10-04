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

main :: proc() {
	for arg, i in os.args[1:] {
		if arg == "--selftest" || arg == "-t" {
			os.exit(selftest())
		}
		if arg == "--shot" {
			os.exit(shot_mode(os.args[2 + i:]))
		}
		if arg == "--help" || arg == "-h" {
			fmt.println("sheets [--selftest] [file.sheet.json | file.csv]")
			os.exit(0)
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
	sheet_init(&app.sh)
	defer sheet_destroy(&app.sh)
	load_italics(&app_win.fonts)
	app.fonts = &app_win.fonts
	app.pal = palette_build()
	app.name = strings.clone("Untitled")

	loaded := false
	for arg in os.args[1:] {
		if strings.has_prefix(arg, "-") {
			continue
		}
		if strings.has_suffix(arg, ".csv") || strings.has_suffix(arg, ".tsv") {
			if ok, rows, cols := csv_read_file(&app.sh, arg, {0, 0}); ok {
				set_status(app, "Imported %d x %d from %s", rows, cols, base_name(arg))
				loaded = true
			}
		} else {
			if cur, anc, ok := doc_load_file(&app.sh, arg); ok {
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

	for ui in p.frames(app_win) {
		// The viewport is measured before the keyboard runs, because Page
		// Up/Down and following the cursor both need to know what fits.
		measure_viewport(app, p.size(ui))
		handle_keys(ui, app)
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
// on, the way a spreadsheet's sample book does.
seed_demo :: proc(app: ^App) {
	sh := &app.sh
	rows := [?][3]string {
		{"Region", "Units", "Price"},
		{"North", "120", "4.50"},
		{"South", "86", "4.50"},
		{"East", "203", "3.95"},
		{"West", "154", "4.25"},
	}
	for r, i in rows {
		for v, j in r {
			set_input(sh, {i, j}, v)
		}
	}
	set_input(sh, {0, 3}, "Revenue")
	for i in 1 ..= 4 {
		set_input(sh, {i, 3}, fmt.tprintf("=B%d*C%d", i + 1, i + 1))
	}
	set_input(sh, {6, 0}, "Total")
	set_input(sh, {6, 1}, "=SUM(B2:B5)")
	set_input(sh, {6, 3}, "=SUM(D2:D5)")
	set_input(sh, {7, 0}, "Average")
	set_input(sh, {7, 3}, "=AVERAGE(D2:D5)")
	set_input(sh, {8, 0}, "Best")
	set_input(sh, {8, 3}, "=MAX(D2:D5)")
	set_input(sh, {9, 0}, "Best region")
	set_input(sh, {9, 3}, "=INDEX(A2:A5,MATCH(MAX(D2:D5),D2:D5,0))")
	recalc(sh)

	for col in 0 ..= 3 {
		for row in 0 ..= 9 {
			if col == 3 || col == 2 {
				set_cell_fmt(sh, {row, col}, {num = .Currency, dec = 2})
			}
		}
	}
	for col in 0 ..= 3 {
		set_cell_fmt(sh, {0, col}, {bold = true, align = .Center})
	}
	set_cell_fmt(sh, {6, 0}, {bold = true})
	set_cell_fmt(sh, {6, 1}, {bold = true})
	set_cell_fmt(sh, {6, 3}, {num = .Currency, dec = 2, bold = true})
	set_cell_fmt(sh, {7, 3}, {num = .Currency, dec = 2})
	set_cell_fmt(sh, {8, 3}, {num = .Currency, dec = 2})
	set_col_width(sh, 0, 120)
	set_col_width(sh, 3, 110)
	app.modified = false
	set_status(app, "F1 for the keyboard map")
}
