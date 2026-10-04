// Application state: what is on screen, what has been filtered, what is in the
// basket and the list, and how all of that is written to disk.
//
// Search and filtering run over the whole catalogue on every keystroke, which
// is affordable because the expensive half — folding, quantity parsing, the
// Nutri-Score — was done once at load. What a keystroke costs is measured and
// shown in the status bar rather than claimed; see `st.filter_ms`.
package main

import kit "kit:."
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"

View :: enum u8 {
	Catalogue,
	Compare,
	Basket,
	List,
	Prices,
	Import,
}

view_label :: proc(v: View) -> string {
	switch v {
	case .Catalogue:
		return "Catalogue"
	case .Compare:
		return "Comparer"
	case .Basket:
		return "Panier"
	case .List:
		return "Liste de courses"
	case .Prices:
		return "Prix"
	case .Import:
		return "Importer un flux"
	}
	return ""
}

Sort_Key :: enum u8 {
	Relevance,
	Price_Up,
	Price_Down,
	Unit_Up,
	Unit_Down,
	Discount,
	Nutri,
	Name,
}

sort_label :: proc(s: Sort_Key) -> string {
	switch s {
	case .Relevance:
		return "Pertinence"
	case .Price_Up:
		return "Prix croissant"
	case .Price_Down:
		return "Prix décroissant"
	case .Unit_Up:
		return "Prix au kilo / au litre"
	case .Unit_Down:
		return "Prix au kilo décroissant"
	case .Discount:
		return "Promotions"
	case .Nutri:
		return "Nutri-Score"
	case .Name:
		return "Nom"
	}
	return ""
}

Dept_Filter :: enum u8 {
	All,
	Grocery,
	Clothing,
}

Filter :: struct {
	retailers:   [Retailer]bool, // all false means no restriction
	dept:        Dept_Filter,
	aisle:       Aisle,
	price_min:   Centimes,
	price_max:   Centimes, // 0 means no ceiling
	brand:       string,   // "" means any; "MDD" means no brand of its own
	color:       string,
	size_label:  string,
	size_system: Size_System,
	size_chart:  Size_Chart,
	in_stock:    bool,
	promo_only:  bool,
	nutri_max:   Nutri, // .None means no restriction
}

filter_any :: proc(f: Filter) -> bool {
	for r in Retailer {
		if f.retailers[r] {
			return true
		}
	}
	return f.dept != .All ||
	       f.aisle != .None ||
	       f.price_min > 0 ||
	       f.price_max > 0 ||
	       f.brand != "" ||
	       f.color != "" ||
	       f.size_label != "" ||
	       f.in_stock ||
	       f.promo_only ||
	       f.nutri_max != .None
}

Basket_Line :: struct {
	product: int,
	qty:     int,
}

List_Item :: struct {
	product: int,
	qty:     int,
	done:    bool,
}

Alert :: struct {
	product:   int,
	threshold: Centimes,
}

Pane :: enum u8 {
	Results,
	Search,
	Facets,
}

State :: struct {
	cat:        Catalog,
	view:       View,
	pane:       Pane,

	query:      [dynamic]u8,
	qfold:      string,
	searching:  bool, // the search field owns the keyboard this frame
	search_id:  u64,  // the field's element id, so `/` can focus it
	want_focus_search: bool,

	filter:     Filter,
	sort:       Sort_Key,
	vis:        [dynamic]int,

	sel:        int, // into vis
	top:        int,
	rows:       int,
	row_h:      f32,
	detail:     bool,
	compare_of: int, // product index, -1 when nothing is being compared

	basket:     [dynamic]Basket_Line,
	list:       [dynamic]List_Item,
	alerts:     [dynamic]Alert,
	list_sel:   int,
	basket_sel: int,

	// Facets, computed once from the catalogue.
	brands:     [dynamic]string,
	colors:     [dynamic]string,

	// What the last refilter cost, in milliseconds, reported rather than
	// asserted by vibes.
	filter_ms:  f64,
	frame_ms:   f64,

	data_dir:   string,
	import_msg: string,
	toast:      string,
	toast_at:   f64,
	now:        f64,

	pick:       kit.Pick,
	help_open:  bool,
	scroll_acc: f32,
}

// ---------------------------------------------------------------------------
// Set-up
// ---------------------------------------------------------------------------

state_init :: proc(st: ^State, seed: u64 = 0x5107) {
	st.compare_of = -1
	st.sort = .Relevance
	st.filter.size_system = .FR
	st.filter.nutri_max = .None
	st.row_h = 56
	st.query = make([dynamic]u8)
	st.vis = make([dynamic]int)
	st.basket = make([dynamic]Basket_Line)
	st.list = make([dynamic]List_Item)
	st.alerts = make([dynamic]Alert)
	st.brands = make([dynamic]string)
	st.colors = make([dynamic]string)
	st.data_dir = data_dir()

	fixture_build(&st.cat, seed)
	build_facets(st)
	load_state(st)
	refilter(st)
}

// data_dir is the one place this application writes. Nothing else on the disk
// is created, modified or scanned.
data_dir :: proc(allocator := context.allocator) -> string {
	home := os.get_env("HOME", context.temp_allocator)
	if home == "" {
		home = "/tmp"
	}
	return strings.concatenate({home, "/.local/share/palmy-shop"}, allocator)
}

build_facets :: proc(st: ^State) {
	for b in st.brands {
		delete(b)
	}
	clear(&st.brands)
	for c in st.colors {
		delete(c)
	}
	clear(&st.colors)

	seen_b := make(map[string]bool, 64, context.temp_allocator)
	seen_c := make(map[string]bool, 32, context.temp_allocator)
	for p in st.cat.products {
		if p.brand != "" && !seen_b[p.brand] {
			seen_b[p.brand] = true
			append(&st.brands, strings.clone(p.brand))
		}
		if p.color != "" && !seen_c[p.color] {
			seen_c[p.color] = true
			append(&st.colors, strings.clone(p.color))
		}
	}
	slice.sort(st.brands[:])
	slice.sort(st.colors[:])
}

// ---------------------------------------------------------------------------
// Filtering and sorting
// ---------------------------------------------------------------------------

@(private = "file")
sort_state: ^State

@(private = "file")
cmp_vis :: proc(a, b: int) -> bool {
	st := sort_state
	pa := &st.cat.products[a]
	pb := &st.cat.products[b]
	switch st.sort {
	case .Price_Up:
		if pa.price != pb.price {
			return pa.price < pb.price
		}
	case .Price_Down:
		if pa.price != pb.price {
			return pa.price > pb.price
		}
	case .Unit_Up:
		// Products with a unit price first, cheapest kilo first. A garment has
		// no unit price and sorts after everything that does, rather than
		// pretending to be free.
		if pa.has_unit != pb.has_unit {
			return pa.has_unit
		}
		if pa.has_unit && pa.unit != pb.unit {
			return pa.unit < pb.unit
		}
	case .Unit_Down:
		if pa.has_unit != pb.has_unit {
			return pa.has_unit
		}
		if pa.has_unit && pa.unit != pb.unit {
			return pa.unit > pb.unit
		}
	case .Discount:
		da, db := discount_tenths(pa^), discount_tenths(pb^)
		if da != db {
			return da > db
		}
	case .Nutri:
		ga, gb := pa.nutri.grade, pb.nutri.grade
		// An unknown grade sorts last, not first.
		ka := ga == .None ? 99 : int(ga)
		kb := gb == .None ? 99 : int(gb)
		if ka != kb {
			return ka < kb
		}
	case .Name:
	case .Relevance:
		// In stock, then on promotion, then cheapest.
		if (pa.avail == .In_Stock) != (pb.avail == .In_Stock) {
			return pa.avail == .In_Stock
		}
		if on_promo(pa^) != on_promo(pb^) {
			return on_promo(pa^)
		}
	}
	if pa.title != pb.title {
		return pa.title < pb.title
	}
	if pa.retailer != pb.retailer {
		return pa.retailer < pb.retailer
	}
	return pa.price < pb.price
}

// passes is the whole filter predicate for one product.
passes :: proc(st: ^State, p: ^Product) -> bool {
	f := st.filter

	restrict := false
	for r in Retailer {
		if f.retailers[r] {
			restrict = true
			break
		}
	}
	if restrict && !f.retailers[p.retailer] {
		return false
	}
	switch f.dept {
	case .Grocery:
		if retailer_kind(p.retailer) != .Grocery {
			return false
		}
	case .Clothing:
		if retailer_kind(p.retailer) != .Clothing {
			return false
		}
	case .All:
	}
	if f.aisle != .None && p.aisle != f.aisle {
		return false
	}
	if f.price_min > 0 && p.price < f.price_min {
		return false
	}
	if f.price_max > 0 && p.price > f.price_max {
		return false
	}
	if f.brand == "MDD" {
		if p.brand != "" {
			return false
		}
	} else if f.brand != "" && p.brand != f.brand {
		return false
	}
	if f.color != "" && p.color != f.color {
		return false
	}
	if f.in_stock && p.avail != .In_Stock {
		return false
	}
	if f.promo_only && !on_promo(p^) {
		return false
	}
	if f.nutri_max != .None {
		if p.nutri.grade == .None || int(p.nutri.grade) > int(f.nutri_max) {
			return false
		}
	}
	if f.size_label != "" {
		// A size filter only applies to things that have sizes; groceries are
		// excluded rather than silently dropped, which is what a shopper means
		// by "show me my size".
		if len(p.sizes) == 0 || p.chart == .None {
			return false
		}
		if f.size_chart != .None && p.chart != f.size_chart {
			return false
		}
		if !size_matches(p.chart, p.sizes, p.size_system, f.size_label, f.size_system) {
			return false
		}
	}
	if st.qfold != "" && !matches_query(p.folded, st.qfold) {
		return false
	}
	return true
}

// refilter rebuilds the visible list and times itself. Called on every
// keystroke in the search field and on every change of a facet.
refilter :: proc(st: ^State) {
	start := time.now()

	delete(st.qfold)
	st.qfold = fold(string(st.query[:]))

	clear(&st.vis)
	for i in 0 ..< len(st.cat.products) {
		if passes(st, &st.cat.products[i]) {
			append(&st.vis, i)
		}
	}
	sort_state = st
	slice.sort_by(st.vis[:], cmp_vis)

	st.filter_ms = f64(time.diff(start, time.now())) / 1e6
	st.sel = clamp(st.sel, 0, max(0, len(st.vis) - 1))
	st.top = clamp(st.top, 0, max(0, len(st.vis) - st.rows))
}

selected_product :: proc(st: ^State) -> int {
	if st.sel < 0 || st.sel >= len(st.vis) {
		return -1
	}
	return st.vis[st.sel]
}

ensure_visible :: proc(st: ^State) {
	if st.sel < st.top {
		st.top = st.sel
	}
	if st.sel >= st.top + st.rows {
		st.top = st.sel - st.rows + 1
	}
	st.top = clamp(st.top, 0, max(0, len(st.vis) - st.rows))
}

// ---------------------------------------------------------------------------
// Basket
// ---------------------------------------------------------------------------

Totals :: struct {
	ttc:         Centimes,
	ht:          Centimes,
	tva:         Centimes,
	by_retailer: [Retailer]Centimes,
	by_tva:      [Tva]Centimes, // the tax collected at each rate
	ht_by_tva:   [Tva]Centimes,
	lines:       int,
	items:       int,
}

// basket_totals sums the basket. Every number here is an integer count of
// centimes and the identity HT + TVA = TTC holds exactly, per line, per rate
// and in the grand total — which the self-test asserts, because this is the
// arithmetic a person checks against their receipt.
basket_totals :: proc(st: ^State) -> Totals {
	t := Totals{}
	for line in st.basket {
		if line.product < 0 || line.product >= len(st.cat.products) {
			continue
		}
		p := st.cat.products[line.product]
		line_ttc := Centimes(i64(p.price) * i64(line.qty))
		line_ht := price_ht(line_ttc, p.tva)
		line_tva := line_ttc - line_ht

		t.ttc += line_ttc
		t.ht += line_ht
		t.tva += line_tva
		t.by_retailer[p.retailer] += line_ttc
		t.by_tva[p.tva] += line_tva
		t.ht_by_tva[p.tva] += line_ht
		t.lines += 1
		t.items += line.qty
	}
	return t
}

basket_find :: proc(st: ^State, product: int) -> int {
	for l, i in st.basket {
		if l.product == product {
			return i
		}
	}
	return -1
}

basket_add :: proc(st: ^State, product: int, qty := 1) {
	if product < 0 {
		return
	}
	if at := basket_find(st, product); at >= 0 {
		st.basket[at].qty += qty
		if st.basket[at].qty < 1 {
			ordered_remove(&st.basket, at)
		}
	} else if qty > 0 {
		append(&st.basket, Basket_Line{product = product, qty = qty})
	}
	save_state(st)
}

basket_remove :: proc(st: ^State, at: int) {
	if at >= 0 && at < len(st.basket) {
		ordered_remove(&st.basket, at)
		save_state(st)
	}
}

// ---------------------------------------------------------------------------
// The grocery list
// ---------------------------------------------------------------------------

list_find :: proc(st: ^State, product: int) -> int {
	for l, i in st.list {
		if l.product == product {
			return i
		}
	}
	return -1
}

list_add :: proc(st: ^State, product: int, qty := 1) {
	if product < 0 {
		return
	}
	if at := list_find(st, product); at >= 0 {
		st.list[at].qty += qty
	} else {
		append(&st.list, List_Item{product = product, qty = qty})
	}
	save_state(st)
}

list_toggle :: proc(st: ^State, at: int) {
	if at >= 0 && at < len(st.list) {
		st.list[at].done = !st.list[at].done
		save_state(st)
	}
}

list_clear_done :: proc(st: ^State) {
	keep := make([dynamic]List_Item)
	for it in st.list {
		if !it.done {
			append(&keep, it)
		}
	}
	delete(st.list)
	st.list = keep
	save_state(st)
}

// list_by_aisle returns the list's items grouped and ordered by rayon, which
// is the order the shop is walked in. One lap, not three.
list_by_aisle :: proc(st: ^State, allocator := context.temp_allocator) -> []int {
	out := make([dynamic]int, allocator)
	for a in Aisle {
		for it, i in st.list {
			if it.product < 0 || it.product >= len(st.cat.products) {
				continue
			}
			if st.cat.products[it.product].aisle == a {
				append(&out, i)
			}
		}
	}
	return out[:]
}

// list_total is what the list would cost at the cheapest retailer for each
// item, and what it costs as listed — the difference being the reason to
// compare at all.
list_total :: proc(st: ^State) -> (as_listed, best: Centimes) {
	for it in st.list {
		if it.product < 0 || it.product >= len(st.cat.products) {
			continue
		}
		p := st.cat.products[it.product]
		as_listed += Centimes(i64(p.price) * i64(it.qty))
		cheap := p.price
		g := group_of(&st.cat, it.product, context.temp_allocator)
		for gi in g {
			q := st.cat.products[gi]
			if q.avail != .In_Stock {
				continue
			}
			// Compared honestly: the cheapest *equivalent* quantity, scaled to
			// the quantity of the item on the list.
			if p.has_unit && q.has_unit && p.qty.kind == q.qty.kind {
				scaled := Centimes(i64(q.unit) * p.qty.amount / (p.qty.kind == .Count ? 1_000 : 1_000_000))
				if scaled < cheap {
					cheap = scaled
				}
			} else if q.price < cheap {
				cheap = q.price
			}
		}
		best += Centimes(i64(cheap) * i64(it.qty))
	}
	return
}

// ---------------------------------------------------------------------------
// Alerts
// ---------------------------------------------------------------------------

alert_find :: proc(st: ^State, product: int) -> int {
	for a, i in st.alerts {
		if a.product == product {
			return i
		}
	}
	return -1
}

// alert_set arms a threshold. The default is five percent below today's price,
// which is a change worth being told about rather than noise.
alert_set :: proc(st: ^State, product: int, threshold: Centimes = 0) {
	if product < 0 || product >= len(st.cat.products) {
		return
	}
	th := threshold
	if th <= 0 {
		th = Centimes(i64(st.cat.products[product].price) * 95 / 100)
	}
	if at := alert_find(st, product); at >= 0 {
		st.alerts[at].threshold = th
	} else {
		append(&st.alerts, Alert{product = product, threshold = th})
	}
	save_state(st)
}

alert_clear :: proc(st: ^State, product: int) {
	if at := alert_find(st, product); at >= 0 {
		ordered_remove(&st.alerts, at)
		save_state(st)
	}
}

alert_hit :: proc(st: ^State, a: Alert) -> bool {
	if a.product < 0 || a.product >= len(st.cat.products) {
		return false
	}
	return st.cat.products[a.product].price <= a.threshold
}

alerts_firing :: proc(st: ^State) -> int {
	n := 0
	for a in st.alerts {
		if alert_hit(st, a) {
			n += 1
		}
	}
	return n
}

// ---------------------------------------------------------------------------
// Persistence
//
// A single text file in ~/.local/share/palmy-shop. Products are named by
// retailer and feed id, never by index, so the file survives a catalogue that
// has grown, shrunk or been reordered.
// ---------------------------------------------------------------------------

state_path :: proc(st: ^State, allocator := context.temp_allocator) -> string {
	return strings.concatenate({st.data_dir, "/state.txt"}, allocator)
}

find_product :: proc(st: ^State, ret: string, id: string) -> int {
	r := retailer_from_name(ret)
	for p, i in st.cat.products {
		if p.retailer == r && p.id == id {
			return i
		}
	}
	return -1
}

save_state :: proc(st: ^State) -> bool {
	if st.data_dir == "" {
		return false
	}
	os.make_directory_all(st.data_dir)
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "# palmy-shop\n# Panier, liste de courses et alertes. Aucun compte, aucun paiement.\n")
	for l in st.basket {
		if l.product < 0 || l.product >= len(st.cat.products) {
			continue
		}
		p := st.cat.products[l.product]
		strings.write_string(&b, "panier\t")
		strings.write_string(&b, retailer_name(p.retailer))
		strings.write_byte(&b, '\t')
		strings.write_string(&b, p.id)
		strings.write_byte(&b, '\t')
		write_int(&b, i64(l.qty))
		strings.write_byte(&b, '\n')
	}
	for it in st.list {
		if it.product < 0 || it.product >= len(st.cat.products) {
			continue
		}
		p := st.cat.products[it.product]
		strings.write_string(&b, "liste\t")
		strings.write_string(&b, retailer_name(p.retailer))
		strings.write_byte(&b, '\t')
		strings.write_string(&b, p.id)
		strings.write_byte(&b, '\t')
		write_int(&b, i64(it.qty))
		strings.write_byte(&b, '\t')
		strings.write_string(&b, it.done ? "1" : "0")
		strings.write_byte(&b, '\n')
	}
	for a in st.alerts {
		if a.product < 0 || a.product >= len(st.cat.products) {
			continue
		}
		p := st.cat.products[a.product]
		strings.write_string(&b, "alerte\t")
		strings.write_string(&b, retailer_name(p.retailer))
		strings.write_byte(&b, '\t')
		strings.write_string(&b, p.id)
		strings.write_byte(&b, '\t')
		write_int(&b, i64(a.threshold))
		strings.write_byte(&b, '\n')
	}
	strings.write_string(&b, "tri\t")
	write_int(&b, i64(st.sort))
	strings.write_byte(&b, '\n')
	if st.filter.size_label != "" {
		strings.write_string(&b, "taille\t")
		strings.write_string(&b, size_system_label(st.filter.size_system))
		strings.write_byte(&b, '\t')
		strings.write_string(&b, st.filter.size_label)
		strings.write_byte(&b, '\n')
	}
	return os.write_entire_file(state_path(st), transmute([]u8)strings.to_string(b)) == nil
}

write_int :: proc(b: ^strings.Builder, v: i64) {
	buf: [24]u8
	strings.write_string(b, strconv.write_int(buf[:], v, 10))
}

load_state :: proc(st: ^State) {
	data, err := os.read_entire_file(state_path(st), context.temp_allocator)
	if err != nil {
		return
	}
	clear(&st.basket)
	clear(&st.list)
	clear(&st.alerts)
	for raw in strings.split_lines(string(data), context.temp_allocator) {
		line := strings.trim_space(raw)
		if line == "" || line[0] == '#' {
			continue
		}
		f := strings.split(line, "\t", context.temp_allocator)
		switch f[0] {
		case "panier":
			if len(f) < 4 {
				continue
			}
			if idx := find_product(st, f[1], f[2]); idx >= 0 {
				q, _ := strconv.parse_int(f[3])
				append(&st.basket, Basket_Line{product = idx, qty = max(1, q)})
			}
		case "liste":
			if len(f) < 5 {
				continue
			}
			if idx := find_product(st, f[1], f[2]); idx >= 0 {
				q, _ := strconv.parse_int(f[3])
				append(&st.list, List_Item{product = idx, qty = max(1, q), done = f[4] == "1"})
			}
		case "alerte":
			if len(f) < 4 {
				continue
			}
			if idx := find_product(st, f[1], f[2]); idx >= 0 {
				v, _ := strconv.parse_i64(f[3])
				append(&st.alerts, Alert{product = idx, threshold = Centimes(v)})
			}
		case "tri":
			if len(f) >= 2 {
				v, _ := strconv.parse_int(f[1])
				if v >= 0 && v <= int(max(Sort_Key)) {
					st.sort = Sort_Key(v)
				}
			}
		case "taille":
			if len(f) >= 3 {
				st.filter.size_system = parse_size_system(f[1])
				delete(st.filter.size_label)
				st.filter.size_label = strings.clone(f[2])
			}
		}
	}
}

// ---------------------------------------------------------------------------
// Importing
// ---------------------------------------------------------------------------

// import_path reads a feed the user explicitly chose and folds it into the
// catalogue. Only that file is opened.
import_path :: proc(st: ^State, path: string) {
	res := import_feed(path)
	defer feed_result_destroy(&res)

	if res.fatal != "" {
		delete(st.import_msg)
		st.import_msg = strings.concatenate({"Refusé — ", res.fatal})
		return
	}
	added, updated := catalog_absorb(&st.cat, &res)
	delete(st.cat.source)
	st.cat.source = strings.clone(path)
	st.cat.generated = false
	build_facets(st)
	refilter(st)

	b := strings.builder_make()
	strings.write_string(&b, "Importé: ")
	write_int(&b, i64(added))
	strings.write_string(&b, " nouveaux, ")
	write_int(&b, i64(updated))
	strings.write_string(&b, " mis à jour")
	if len(res.errors) > 0 {
		strings.write_string(&b, ", ")
		write_int(&b, i64(len(res.errors)))
		strings.write_string(&b, " refusés")
	}
	delete(st.import_msg)
	st.import_msg = strings.to_string(b)
}

// export_fixture writes the generated catalogue out in both feed formats, into
// the application's own directory. It is how the import path is exercised
// against a file on disk, and how someone can see the format they would have
// to supply.
export_fixture :: proc(st: ^State) -> (xml_path, csv_path: string, ok: bool) {
	os.make_directory_all(st.data_dir)
	xp := strings.concatenate({st.data_dir, "/catalogue-demo.xml"})
	cp := strings.concatenate({st.data_dir, "/catalogue-demo.csv"})
	a := write_merchant_xml(xp, &st.cat)
	b := write_merchant_csv(cp, &st.cat)
	return xp, cp, a && b
}
