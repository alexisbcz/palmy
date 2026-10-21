// `sheets --selftest`, chart resize and data labels.
//
// A chart's size is whole cells — its frame is anchored to two cells, which
// is also how .xlsx anchors it — so a resize is a change of `w` and `h`, kept
// from the top-left corner, clamped, and carried by undo, the native file,
// the .xlsx anchor and the CLI. Data labels are one switch per chart, drawn
// in the cell's own number format, and written as Excel's `<c:dLbls>` with
// `<c:showVal val="1"/>` in each series, where the schema puts it.
package main

import "core:fmt"
import "core:os"
import "core:strings"
import kit "kit:."

@(private = "file")
chart_fixture :: proc(sh: ^Sheet) {
	rows := [?][3]string {
		{"Region", "Units", "Price"},
		{"North", "120", "4.5"},
		{"South", "86", "4.5"},
		{"East", "-20", "3.95"},
	}
	for r, i in rows {
		for v, j in r {
			set_input(sh, {i, j}, v)
		}
	}
	for row in 1 ..= 3 {
		set_cell_fmt(sh, {row, 2}, {num = .Currency, dec = 2})
	}
	append(
		&sh.charts,
		Chart {
			kind = .Bar,
			title = strings.clone("Units", sh.heap),
			sheet = strings.clone("", sh.heap),
			rect = {0, 0, 3, 2},
			at = {1, 5},
			w = 6,
			h = 12,
		},
	)
}

t_chart_ops :: proc(tc: ^TC) {
	// --- the model -----------------------------------------------------------
	{
		fx: Fx
		fx_init(&fx)
		defer fx_done(&fx)
		sh := &fx.sh
		chart_fixture(sh)
		recalc(sh)
		ok_mark(tc, chart_at(sh, {1, 5}) == 0 && chart_at(sh, {12, 10}) == 0, "a chart is found from either corner it covers")
		ok_mark(tc, chart_at(sh, {13, 5}) < 0 && chart_at(sh, {1, 4}) < 0 && chart_at(sh, {1, 11}) < 0, "and not from just outside it")

		ok_mark(tc, chart_resize(sh, 0, 9, 16), "a chart is resized")
		ch := sh.charts[0]
		ok_mark(tc, ch.w == 9 && ch.h == 16 && ch.at == Addr{1, 5}, "from its top-left corner, which stays put")
		ok_mark(tc, chart_at(sh, {16, 13}) == 0, "and now covers the cells it grew over")
		ok_mark(tc, !chart_resize(sh, 0, 9, 16), "the same size again is not a change")
		chart_resize(sh, 0, 0, -5)
		ok_mark(tc, sh.charts[0].w == CHART_MIN_W && sh.charts[0].h == CHART_MIN_H, "a size is clamped to the smallest chart")
		chart_resize(sh, 0, 1000, 1000)
		ok_mark(tc, sh.charts[0].w == CHART_MAX_W && sh.charts[0].h == CHART_MAX_H, "and to the largest")
		ok_mark(tc, !chart_resize(sh, 3, 5, 5), "a chart that is not there is not resized")

		w, h, ok := parse_chart_size("8x14")
		ok_mark(tc, ok && w == 8 && h == 14, "8x14 reads as a size")
		w, h, ok = parse_chart_size(" 8 X 14 ")
		ok_mark(tc, ok && w == 8 && h == 14, "so does 8 X 14")
		w, h, ok = parse_chart_size("8,14")
		ok_mark(tc, ok && w == 8 && h == 14, "and 8,14")
		_, _, ok = parse_chart_size("wide")
		ok_mark(tc, !ok, "a word does not")
		_, _, ok = parse_chart_size("8x")
		ok_mark(tc, !ok, "nor half a size")

		// Labels: the switch, and the headroom it buys on the value axis.
		chart_resize(sh, 0, 6, 12)
		plain := chart_read(sh, sh.charts[0])
		ok_mark(tc, chart_set_labels(sh, 0, true), "data labels are turned on")
		ok_mark(tc, !chart_set_labels(sh, 0, true), "turning them on twice is not a change")
		labelled := chart_read(sh, sh.charts[0])
		ok_mark(tc, labelled.hi > plain.hi && labelled.lo < plain.lo, "labels leave headroom above the tallest bar and below the deepest")
		ok_mark(tc, label_text(labelled.series[1], 4.5) == "$4.50", fmt.tprintf("a label is formatted as its cell is (%s)", label_text(labelled.series[1], 4.5)))
		ok_mark(tc, label_text(labelled.series[0], 120) == "120", "a General number stays plain")
		// A pie has no value axis, so no headroom.
		pie := sh.charts[0]
		pie.kind = .Pie
		pie.labels = false
		pd := chart_read(sh, pie)
		pie.labels = true
		pl := chart_read(sh, pie)
		ok_mark(tc, pd.hi == pl.hi && pd.lo == pl.lo, "a pie's range is not padded for labels")
	}

	// --- the window's commands, and undo -------------------------------------
	{
		app := new(App)
		defer free(app)
		app_init(app)
		defer app_destroy(app)
		chart_fixture(app.sh)
		book_recalc_all(app.book)
		app.cur, app.anchor = {0, 0}, {0, 0}
		run_cmd(app, .Chart_Wider)
		ok_mark(tc, app.sh.charts[0].w == 6 && strings.contains(app.status, "No chart"), "off a chart, resizing says there is none")
		app.cur, app.anchor = {3, 7}, {3, 7}
		run_cmd(app, .Chart_Wider)
		run_cmd(app, .Chart_Wider)
		run_cmd(app, .Chart_Taller)
		ok_mark(tc, app.sh.charts[0].w == 8 && app.sh.charts[0].h == 13, "Make the chart wider and taller step by one cell")
		ok_mark(tc, strings.contains(app.status, "8x13"), fmt.tprintf("and the status bar says the size (%s)", app.status))
		run_cmd(app, .Chart_Narrower)
		run_cmd(app, .Chart_Shorter)
		ok_mark(tc, app.sh.charts[0].w == 7 && app.sh.charts[0].h == 12, "and narrower and shorter")
		run_cmd(app, .Chart_Labels)
		ok_mark(tc, app.sh.charts[0].labels, "Alt+D's command turns labels on")
		run_cmd(app, .Undo)
		ok_mark(tc, !app.sh.charts[0].labels, "undo turns them off again")
		run_cmd(app, .Undo)
		run_cmd(app, .Undo)
		ok_mark(tc, app.sh.charts[0].w == 8 && app.sh.charts[0].h == 13, "and undoes a resize")
		run_cmd(app, .Chart_Size)
		ok_mark(tc, app.prompt == .Chart_Size && line_text(&app.pline) == "8x13", "Set the chart's size opens with the current one")
		run_prompt(app, "10x20")
		ok_mark(tc, app.sh.charts[0].w == 10 && app.sh.charts[0].h == 20, "and sets what is typed")
		run_prompt(app, "big")
		ok_mark(tc, app.sh.charts[0].w == 10 && strings.contains(app.status, "not a size"), "and refuses what is not a size")
		app.mode = .Nav
		app.prompt = .None
	}

	// --- the native document and .xlsx ----------------------------------------
	{
		b := bk_make("Data")
		defer bk_free(b)
		sh := b.sheets[0]
		chart_fixture(sh)
		append(
			&sh.charts,
			Chart {
				kind = .Line,
				title = strings.clone("Plain", sh.heap),
				sheet = strings.clone("", sh.heap),
				rect = {0, 0, 3, 2},
				at = {20, 5},
				w = 5,
				h = 9,
			},
		)
		chart_resize(sh, 0, 11, 17)
		chart_set_labels(sh, 0, true)
		book_recalc_all(b)

		text := doc_save_string(sh, "c", {}, {}, context.temp_allocator)
		b2 := book_new()
		defer bk_free(b2)
		_, _, _, ok := doc_load_string(b2.sheets[0], text)
		c2 := b2.sheets[0].charts
		ok_mark(tc, ok && len(c2) == 2 && c2[0].w == 11 && c2[0].h == 17 && c2[0].labels && !c2[1].labels, "the native file keeps the size and the labels")

		raw := xlsx_book_bytes(b, context.temp_allocator)
		files, _ := zip_read(raw, context.temp_allocator)
		dw, _ := zip_find(files, "xl/drawings/drawing1.xml")
		ok_mark(tc, strings.contains(string(dw), "<xdr:to><xdr:col>16</xdr:col><xdr:colOff>0</xdr:colOff><xdr:row>18</xdr:row>"), "the .xlsx anchor ends where the resized chart does")
		cp, _ := zip_find(files, "xl/charts/chart1.xml")
		cs := string(cp)
		ok_mark(tc, strings.count(cs, `<c:showVal val="1"/>`) == 2, "each series of the labelled chart shows its values")
		ok_mark(tc, strings.contains(cs, `<c:dLblPos val="outEnd"/>`), "above the bar end, a position a bar chart allows")
		d := strings.index(cs, "<c:dLbls>")
		cat := strings.index(cs, "<c:cat>")
		sp := strings.index(cs, "<c:spPr>")
		ok_mark(tc, d > sp && d < cat, "and the labels sit between the series colour and the categories, as the schema orders them")
		cp2, _ := zip_find(files, "xl/charts/chart2.xml")
		ok_mark(tc, !strings.contains(string(cp2), "dLbls"), "a chart without labels writes none")

		b3 := book_new()
		defer bk_free(b3)
		rok, _, _ := xlsx_read_book_bytes(b3, raw)
		c3 := b3.sheets[0].charts
		ok_mark(tc, rok && len(c3) == 2, "the workbook imports both charts")
		if len(c3) == 2 {
			ok_mark(tc, c3[0].w == 11 && c3[0].h == 17 && c3[0].at == Addr{1, 5}, "with the resized frame")
			ok_mark(tc, c3[0].labels && !c3[1].labels, "and each one's labels as they were")
		}
	}

	// --- labels written by another program ------------------------------------
	{
		mk :: proc(body: string) -> string {
			return fmt.tprintf(`<c:chartSpace xmlns:c="x"><c:chart><c:plotArea><c:barChart><c:ser><c:val><c:numRef><c:f>Sheet1!$B$2:$B$4</c:f></c:numRef></c:val></c:ser>%s</c:barChart></c:plotArea></c:chart></c:chartSpace>`, body)
		}
		cases := [?]struct {
			xml:  string,
			want: bool,
			what: string,
		} {
			{mk(""), false, "no dLbls: no labels"},
			{mk(`<c:dLbls><c:showLegendKey val="0"/><c:showVal val="1"/></c:dLbls>`), true, "a chart-group dLbls showing values"},
			{mk(`<c:dLbls><c:showVal val="0"/><c:showPercent val="1"/></c:dLbls>`), true, "percentages count as labels"},
			{mk(`<c:dLbls><c:showVal val="0"/></c:dLbls>`), false, "showVal 0 is off"},
			{mk(`<c:dLbls><c:delete val="1"/></c:dLbls>`), false, "a deleted dLbls is off"},
		}
		for k in cases {
			z := zip_make(context.temp_allocator)
			zip_add_string(&z, "xl/charts/chart1.xml", k.xml)
			files, _ := zip_read(zip_finish(&z), context.temp_allocator)
			pkg := Xlsx_Pkg{files = files}
			ch, ok := xlsx_read_chart(&pkg, "xl/charts/chart1.xml")
			ok_mark(tc, ok && ch.labels == k.want, k.what)
		}
	}

	// --- the command line ------------------------------------------------------
	{
		dir := fmt.tprintf("/tmp/palmy-sheets-charts-%d", os.get_pid())
		os.make_directory_all(dir)
		defer os.remove_all(dir)
		_ = os.set_env("PALM_AUDIT", fmt.tprintf("%s/audit.jsonl", dir))
		path := fmt.tprintf("%s/book.sheet.json", dir)
		_, code := cli_run("export", path, "--json")
		ok_mark(tc, code == 0, "the demo book is written out")

		out, c2 := cli_run("charts", path, "--json")
		problems := kit.cli_validate_output(out, CHARTS_FIELDS, context.temp_allocator)
		ok_mark(tc, c2 == 0 && len(problems) == 0, fmt.tprintf("charts matches its schema %v", problems))
		ok_mark(tc, strings.contains(out, `"w": 7`) && strings.contains(out, `"h": 14`) && strings.contains(out, `"labels": false`), "and lists the demo chart's size and labels")

		out, c2 = cli_run("chart-set", path, "Summary!F3", "--size", "9x16", "--labels", "--json")
		problems = kit.cli_validate_output(out, CHART_FIELDS, context.temp_allocator)
		ok_mark(tc, c2 == 0 && len(problems) == 0, fmt.tprintf("chart-set matches its schema %v", problems))
		ok_mark(tc, strings.contains(out, `"w": 9`) && strings.contains(out, `"h": 16`) && strings.contains(out, `"labels": true`), "and resizes and labels the chart")
		out, _ = cli_run("charts", path, "--sheet", "Summary", "--json")
		ok_mark(tc, strings.contains(out, `"w": 9`) && strings.contains(out, `"labels": true`), "which the next read sees")
		out, c2 = cli_run("chart-set", path, "Summary!D1", "--w", "4", "--no-labels", "--json")
		ok_mark(tc, c2 == 0 && strings.contains(out, `"w": 4`) && strings.contains(out, `"h": 16`) && strings.contains(out, `"labels": false`), "--w alone keeps the height, --no-labels turns them off")
		_, c2 = cli_run("chart-set", path, "Summary!A1", "--w", "4", "--json")
		ok_mark(tc, c2 == 3, "a cell no chart covers exits 3")
		_, c2 = cli_run("chart-set", path, "Summary!D1", "--size", "huge", "--json")
		ok_mark(tc, c2 == 2, "a size that is not one exits 2")

		// Through .xlsx and back, from the command line end to end.
		xl := fmt.tprintf("%s/book.xlsx", dir)
		cli_run("chart-set", path, "Summary!D1", "--size", "8x15", "--labels", "--json")
		_, c2 = cli_run("export", xl, path, "--json")
		out, _ = cli_run("charts", xl, "--json")
		ok_mark(tc, c2 == 0 && strings.contains(out, `"w": 8`) && strings.contains(out, `"h": 15`) && strings.contains(out, `"labels": true`), "a resized, labelled chart survives .xlsx")

		// The window's keys, rendered offscreen: Alt+Shift+Right on the
		// chart and Alt+D must change the picture. This also pins the shot
		// that used to segfault after writing its PNG (see
		// `offscreen_private_temp`).
		a := fmt.tprintf("%s/a.png", dir)
		bpng := fmt.tprintf("%s/b.png", dir)
		_, s1 := cli_run("shot", a, "c:PageDown", "k:Right", "k:Right", "k:Right")
		_, s2 := cli_run("shot", bpng, "c:PageDown", "k:Right", "k:Right", "k:Right", "a:d", "A:Right", "A:Down")
		ok_mark(tc, s1 == 0 && s2 == 0, "a shot of several steps exits 0 (it used to segfault in the audit)")
		da, _ := os.read_entire_file(a, context.temp_allocator)
		db, _ := os.read_entire_file(bpng, context.temp_allocator)
		ok_mark(tc, len(da) > 0 && len(db) > 0 && string(da) != string(db), "and resizing and labelling the chart changes the frame")
	}
}
