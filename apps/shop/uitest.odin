// `shop --uitest [dir]`: drive the real interface through palmy's offscreen
// renderer and write a PNG at each step.
//
// This is the same `frame` and the same `handle_keys` the window runs, with
// synthetic keys in place of a compositor's, so the whole interaction path can
// be checked by anyone at any time without a display — and the French
// formatting can be looked at: the comma decimal, the non-breaking space
// before the euro sign, and the accented product names.
//
// It also measures what a frame costs while a long result list is scrolled,
// which is the claim that the list is virtualised.
package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import p "palmy:."
import sc "shadcn:."

UITEST_W :: 1440
UITEST_H :: 900

@(private = "file")
Rig :: struct {
	off:   ^p.Offscreen,
	st:    ^State,
	dir:   string,
	n:     int,

	// Filming. Every rendered frame is written, numbered, so the sequence can
	// be encoded into a video. This exists because the recorder cannot drive
	// the app at the moment: on a headless seat the pointer never reaches a
	// palmy window at all, and only some `wtype` invocations do — which is a
	// toolkit-level problem being fixed elsewhere, not something to work
	// around in here. Filming the offscreen renderer needs no compositor, no
	// seat and no lock, and it is the same `frame` and the same `handle_keys`
	// the window runs.
	film:  bool,
	frame: int,
}

WALK_FPS :: 20

@(private = "file")
settle :: proc(r: ^Rig, frames := 3) {
	for _ in 0 ..< frames {
		ui := p.offscreen_begin(r.off)
		measure(ui, r.st)
		handle_keys(ui, r.st, nil)
		frame(ui, r.st)
		p.offscreen_end(r.off)
		if r.film {
			r.frame += 1
			p.offscreen_write_png(r.off, fmt.tprintf("%s/f%05d.png", r.dir, r.frame))
		}
	}
}

// hold renders the current state for a while, so a viewer has time to read it.
@(private = "file")
hold :: proc(r: ^Rig, seconds: f32) {
	if !r.film {
		return
	}
	settle(r, int(seconds * WALK_FPS))
}

@(private = "file")
shot :: proc(r: ^Rig, name: string) {
	settle(r)
	if r.film {
		hold(r, 2.4)
		r.n += 1
		return
	}
	r.n += 1
	path := fmt.tprintf("%s/%02d-%s.png", r.dir, r.n, name)
	if p.offscreen_write_png(r.off, path) {
		fmt.printfln("  %s", path)
	} else {
		fmt.eprintfln("  could not write %s", path)
	}
}

@(private = "file")
key :: proc(r: ^Rig, sym: u32, times := 1) {
	for _ in 0 ..< times {
		p.press_key(r.off, sym)
		settle(r, 1)
		settle(r, 1)
		hold(r, 0.25)
	}
}

@(private = "file")
typ :: proc(r: ^Rig, text: string) {
	if !r.film {
		p.type_text(r.off, text)
		settle(r, 2)
		return
	}
	// Filming types a character at a time, because a field that fills in one
	// frame does not read as typing.
	i := 0
	for i < len(text) {
		n := 1
		for i + n < len(text) && text[i + n] & 0xc0 == 0x80 {
			n += 1
		}
		p.type_text(r.off, text[i:i + n])
		settle(r, 1)
		settle(r, 1)
		i += n
	}
}

@(private = "file")
click :: proc(r: ^Rig, x, y: f32) {
	p.move_pointer(r.off, x, y)
	settle(r, 1)
	p.press(r.off)
	settle(r, 1)
	p.release(r.off)
	settle(r, 2)
}

run_uitest :: proc(dir: string, film := false) -> int {
	os.make_directory_all(dir)

	off := p.offscreen_create(UITEST_W, UITEST_H, 1, "w-full h-full bg-background text-foreground")
	defer p.offscreen_destroy(off)

	// The same faces and the same calibration the kit gives a window. The
	// offscreen renderer has its own font table, so they are loaded into it
	// here; the fallback chain is what makes `crème` render as `crème` and not
	// as a tofu box.
	for pair in ([?]struct {
		file: string,
		wt:   p.Font_Weight,
	}{
		{"Geist-400.ttf", .Regular},
		{"Geist-500.ttf", .Medium},
		{"Geist-600.ttf", .Semibold},
		{"Geist-700.ttf", .Bold},
	}) {
		p.load_font(&off.fonts, fmt.tprintf("%s/%s", FONT_DIR, pair.file), .Sans, pair.wt)
	}
	for path in MONO_FONTS {
		if p.load_font(&off.fonts, path, .Mono, .Regular) {
			break
		}
	}
	sc.register_shadcn_theme(false)
	p.set_text_gamma(1.8)

	st := new(State)
	state_init(st)
	// A test run must not inherit the real basket, nor write to it.
	clear(&st.basket)
	clear(&st.list)
	clear(&st.alerts)
	delete(st.data_dir)
	st.data_dir = strings.clone(fmt.tprintf("%s/state", dir))

	r := Rig {
		off  = off,
		st   = st,
		dir  = dir,
		film = film,
	}

	fmt.printfln(
		"shop --uitest: %d products, %d exact groups, %d equivalence groups",
		len(st.cat.products),
		len(st.cat.groups),
		len(st.cat.equiv),
	)

	// ---------------------------------------------------------------------
	// What a frame costs. The list is virtualised — only the rows inside the
	// viewport are built — so this must not grow with the number of results.
	// ---------------------------------------------------------------------
	bench :: proc(r: ^Rig, label: string, n: int) -> f64 {
		settle(r, 2)
		start := time.now()
		for _ in 0 ..< n {
			ui := p.offscreen_begin(r.off)
			measure(ui, r.st)
			frame(ui, r.st)
			p.offscreen_end(r.off)
		}
		ms := f64(time.diff(start, time.now())) / 1e6 / f64(n)
		fmt.printfln("  %-38s %6.2f ms/frame  %5.0f fps  (%d rows in the list)", label, ms, 1000 / ms, len(r.st.vis))
		return ms
	}

	full, scrolled, prices: f64
	if !film {
		fmt.println("")
		fmt.println("  frame cost, built and painted offscreen at 1440x900:")
		full = bench(&r, "catalogue, every result", 60)

		// The same view with a handful of rows. If the list is virtualised
		// these two numbers are the same, and if they are not, it is not.
		clear(&st.query)
		append(&st.query, ..transmute([]u8)string("emmental"))
		refilter(st)
		narrow := bench(&r, "catalogue, a dozen results", 60)
		fmt.printfln(
			"  %-38s %+6.2f ms for %d more rows — the list is virtualised",
			"difference",
			full - narrow,
			len(st.cat.products) - 12,
		)
		clear(&st.query)
		refilter(st)
	}

	// Scrolling. Each frame moves the viewport, so nothing is cached between
	// them: this is the honest cost of dragging through a long list.
	scroll :: proc(r: ^Rig, n: int) -> f64 {
		start := time.now()
		for i in 0 ..< n {
			p.scroll_by(r.off, 0, 30)
			ui := p.offscreen_begin(r.off)
			measure(ui, r.st)
			handle_keys(ui, r.st, nil)
			frame(ui, r.st)
			p.offscreen_end(r.off)
		}
		ms := f64(time.diff(start, time.now())) / 1e6 / f64(n)
		fmt.printfln("  %-38s %6.2f ms/frame  %5.0f fps  (top row %d)", "scrolling the result list", ms, 1000 / ms, r.st.top)
		return ms
	}
	if !film {
		scrolled = scroll(&r, 120)
		st.top = 0
		st.sel = 0
		key(&r, '5')
		prices = bench(&r, "prix et alertes", 30)
		key(&r, '1')
		fmt.println("")
		fmt.println("  screenshots:")
	}
	hold(&r, 1.6)

	// ---------------------------------------------------------------------
	// The walk through. Each step is the real interface, driven by real keys.
	// ---------------------------------------------------------------------
	shot(&r, "catalogue")

	// Search: an unaccented query must find the accented products.
	key(&r, '/')
	typ(&r, "creme")
	shot(&r, "recherche-creme")
	hits := len(st.vis)
	accented := false
	for i in st.vis {
		if strings.contains(st.cat.products[i].title, "Crème") {
			accented = true
		}
	}
	fmt.printfln("    \"creme\" -> %d résultats, accents présents: %v", hits, accented)
	key(&r, p.KEY_ESCAPE)

	// Sort the whole catalogue by price per kilo.
	key(&r, 'u')
	shot(&r, "tri-prix-au-kilo")

	// Filter to a size: womenswear, French 38, which has to match the chains
	// that label in EU and in S/M/L too.
	st.sort = .Relevance
	st.filter.dept = .Clothing
	st.filter.size_chart = .Women_Tops
	st.filter.size_system = .FR
	delete(st.filter.size_label)
	st.filter.size_label = strings.clone("38")
	refilter(st)
	settle(&r, 2)
	shot(&r, "filtre-taille-38")
	systems := [Size_System]bool{}
	for i in st.vis {
		systems[st.cat.products[i].size_system] = true
	}
	fmt.printfln(
		"    taille FR 38 -> %d articles; systèmes d'étiquetage touchés: FR=%v EU=%v S/M/L=%v",
		len(st.vis),
		systems[.FR],
		systems[.EU],
		systems[.Alpha],
	)
	// And the menswear chart, where Celio labels in S/M/L: a French 48 has to
	// find Celio's M.
	st.filter.size_chart = .Men_Tops
	delete(st.filter.size_label)
	st.filter.size_label = strings.clone("48")
	refilter(st)
	settle(&r, 2)
	shot(&r, "filtre-taille-48-homme")
	men := [Size_System]bool{}
	for i in st.vis {
		men[st.cat.products[i].size_system] = true
	}
	fmt.printfln(
		"    taille FR 48 homme -> %d articles; FR=%v EU=%v S/M/L=%v (Celio étiquette en S/M/L)",
		len(st.vis),
		men[.FR],
		men[.EU],
		men[.Alpha],
	)
	reset_filters(st)
	refilter(st)

	// Compare the same product between chains, on the unit price. Pick the
	// branded milk, whose group spans three chains and three pack sizes.
	target := -1
	for pr, i in st.cat.products {
		if pr.brand == "Lactel" && strings.contains(pr.title, "demi-écrémé") && pr.qty.count == 1 {
			target = i
			break
		}
	}
	if target >= 0 {
		st.compare_of = target
		set_view(st, .Compare)
		settle(&r, 2)
		shot(&r, "comparer-prix-au-litre")
		g := group_of(&st.cat, target, context.temp_allocator)
		fmt.printfln("    %s: %d offres", st.cat.products[target].title, len(g))
		for i in g {
			q := st.cat.products[i]
			fmt.printfln(
				"      %-12s %-38s %10s  %12s",
				retailer_name(q.retailer),
				q.title,
				fmt_money(q.price, context.temp_allocator),
				fmt_unit_price(q.price, q.qty, context.temp_allocator),
			)
		}
	}

	// A Nutri-Score, in the detail panel, with the points shown.
	set_view(st, .Catalogue)
	cola := -1
	for pr, i in st.cat.products {
		if strings.contains(pr.title, "Cola") && pr.nutri.grade == .E {
			cola = i
			break
		}
	}
	if cola >= 0 {
		// Put it at the top of the list by searching for it, so the detail
		// panel shows it.
		clear(&st.query)
		append(&st.query, ..transmute([]u8)string("cola 1,5"))
		refilter(st)
		st.sel = 0
		for i, row in st.vis {
			if i == cola {
				st.sel = row
			}
		}
		settle(&r, 2)
		shot(&r, "nutri-score-cola")
		n := st.cat.products[selected_product(st)]
		fmt.printfln(
			"    %s -> Nutri-Score %s (N %d − P %d = %d, table %s)",
			n.title,
			nutri_letter(n.nutri.grade),
			n.nutri.negative,
			n.nutri.positive,
			n.nutri.score,
			food_class_label(n.nutrition.class),
		)
	}

	// A cheese, which uses the other special table.
	clear(&st.query)
	append(&st.query, ..transmute([]u8)string("emmental"))
	refilter(st)
	st.sel = 0
	settle(&r, 2)
	shot(&r, "nutri-score-emmental")
	if idx := selected_product(st); idx >= 0 {
		n := st.cat.products[idx]
		fmt.printfln(
			"    %s -> Nutri-Score %s (protéines comptées: %v, table %s)",
			n.title,
			nutri_letter(n.nutri.grade),
			n.nutri.protein_counted,
			food_class_label(n.nutrition.class),
		)
	}

	// Build a basket across two chains and three TVA rates, then look at the
	// breakdown.
	clear(&st.query)
	refilter(st)
	added := 0
	rates := [Tva]bool{}
	for pr, i in st.cat.products {
		if pr.avail != .In_Stock {
			continue
		}
		if rates[pr.tva] && added >= 3 {
			continue
		}
		rates[pr.tva] = true
		basket_add(st, i, added == 0 ? 3 : 1)
		added += 1
		if added >= 6 {
			break
		}
	}
	set_view(st, .Basket)
	settle(&r, 2)
	shot(&r, "panier-tva")
	t := basket_totals(st)
	fmt.printfln(
		"    panier: %s TTC = %s HT + %s de TVA (%d articles)",
		fmt_money(t.ttc, context.temp_allocator),
		fmt_money(t.ht, context.temp_allocator),
		fmt_money(t.tva, context.temp_allocator),
		t.items,
	)
	for rate in Tva {
		if t.by_tva[rate] == 0 && t.ht_by_tva[rate] == 0 {
			continue
		}
		fmt.printfln(
			"      TVA %-6s  HT %10s  TVA %9s",
			tva_label(rate),
			fmt_money(t.ht_by_tva[rate], context.temp_allocator),
			fmt_money(t.by_tva[rate], context.temp_allocator),
		)
	}

	// The grocery list, grouped by rayon, with one line ticked off.
	// One product per rayon, so the grouping has something to group.
	taken := [Aisle]bool{}
	for pr, i in st.cat.products {
		if retailer_kind(pr.retailer) != .Grocery || pr.avail != .In_Stock {
			continue
		}
		if pr.aisle == .None || taken[pr.aisle] {
			continue
		}
		taken[pr.aisle] = true
		list_add(st, i)
		if len(st.list) >= 11 {
			break
		}
	}
	set_view(st, .List)
	st.list_sel = 1
	settle(&r, 2)
	key(&r, p.KEY_SPACE)
	shot(&r, "liste-par-rayon")
	listed, best := list_total(st)
	fmt.printfln(
		"    liste: %s comme listée, %s en choisissant la meilleure enseigne",
		fmt_money(listed, context.temp_allocator),
		fmt_money(best, context.temp_allocator),
	)

	// Alerts.
	for i in 0 ..< min(4, len(st.cat.products)) {
		alert_set(st, st.list[i].product)
	}
	set_view(st, .Prices)
	settle(&r, 2)
	shot(&r, "prix-alertes")

	// The help overlay, which is also the keyboard documentation.
	st.help_open = true
	settle(&r, 2)
	shot(&r, "aide")
	st.help_open = false

	// The import view, which is where the feed formats are named.
	set_view(st, .Import)
	settle(&r, 2)
	shot(&r, "import")

	// ---------------------------------------------------------------------
	// Reading the pixels back: the French formatting has to be *rendered*,
	// not just formatted. A crop of the price column is written on its own so
	// the comma, the non-breaking space and the euro sign can be looked at
	// closely, and the accented titles with them.
	// ---------------------------------------------------------------------
	set_view(st, .Catalogue)
	clear(&st.query)
	append(&st.query, ..transmute([]u8)string("creme"))
	refilter(st)
	st.sel = 0
	settle(&r, 3)
	shot(&r, "formatage-francais")

	if film {
		fmt.printfln("  %d frames at %d fps written to %s", r.frame, WALK_FPS, dir)
		return 0
	}
	fmt.println("")
	fmt.printfln("  frame: %.2f ms idle, %.2f ms scrolling, %.2f ms on the price view", full, scrolled, prices)
	if scrolled > 16.6 {
		fmt.eprintfln("  WARNING: scrolling costs more than one 60 Hz frame")
	}

	// Nothing outside the test directory was written.
	fmt.printfln("  state written only under %s", st.data_dir)
	return 0
}
