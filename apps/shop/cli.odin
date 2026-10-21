package main

// The command-line front end of Shop.
//
// Nothing here re-implements the comparator. A command builds the same
// `State` the window builds (`state_init`: the generated catalogue, the saved
// basket, list, alerts and sort), sets the same query and facets the window's
// search field and facet pills set, and calls the same procedures the keys
// and buttons call — `refilter`, `group_of`, `basket_add`, `list_add`,
// `list_toggle`, `alert_set`, `import_path`, `export_fixture`. Something added
// to the basket here is in the window's basket the next time it opens,
// because it went through `save_state` like a click would.
//
// The safety notes at the top of main.odin hold here too: no network, reads
// limited to a feed file named on the command line, writes only into the
// application's own directory ($PALMY_SHOP_DIR, else ~/.local/share/palmy-shop).
//
// --dry-run on a mutating command runs the same procedure against a State
// whose data directory is empty, which is the one condition under which
// `save_state` writes nothing — so the printed result is exactly what the real
// run would print, and nothing on disk changes.

import "core:os"
import "core:strings"
import kit "kit:."

// ---------------------------------------------------------------------------
// Declared output
//
// Declared before the commands that use them. Odin orders package
// initialisers by dependency, but kit/cli.odin warns of a schema captured
// empty, and declaring in use order costs nothing.
// ---------------------------------------------------------------------------

PRODUCT_FIELDS := []kit.Field {
	{name = "id", kind = .String, help = "the feed id: what every other command takes as <product>"},
	{name = "retailer", kind = .String},
	{name = "title", kind = .String},
	{name = "brand", kind = .String, help = "\"\" for a store brand"},
	{name = "price_cents", kind = .Int, help = "TTC, in centimes"},
	{name = "price", kind = .String, help = "formatted the French way"},
	{name = "list_price_cents", kind = .Int, help = "the retailer's reference price; above price_cents means a promotion"},
	{name = "promo", kind = .Bool},
	{name = "unit_price", kind = .String, help = "per kilo / litre / piece, \"\" for clothing"},
	{name = "unit_cents", kind = .Int, help = "the same, in centimes per base unit; 0 when there is none"},
	{name = "quantity", kind = .String},
	{name = "aisle", kind = .String},
	{name = "availability", kind = .String},
	{name = "nutri", kind = .String, help = "A..E, \"\" when unknown"},
	{name = "gtin", kind = .String},
	{name = "color", kind = .String},
	{name = "sizes", kind = .Array, of = {{kind = .String}}},
	{name = "tva", kind = .String},
}

SEARCH_FIELDS := []kit.Field {
	{name = "query", kind = .String},
	{name = "matched", kind = .Int, help = "how many products pass, before --limit"},
	{name = "catalogue", kind = .Int, help = "how many products there are"},
	{name = "generated", kind = .Bool, help = "true: the generated catalogue, not live prices"},
	{name = "source", kind = .String},
	{name = "sort", kind = .String},
	{name = "products", kind = .Array, of = PRODUCT_FIELDS},
}

SHOW_FIELDS := []kit.Field {
	{name = "product", kind = .Object, of = PRODUCT_FIELDS},
	{name = "history_cents", kind = .Array, of = {{kind = .Int}}, help = "weekly snapshots, oldest first; the last is today"},
	{name = "lowest", kind = .Bool, help = "today's price is the lowest in the history"},
	{name = "in_basket", kind = .Int, help = "quantity in the basket, 0 when absent"},
	{name = "on_list", kind = .Int, help = "quantity on the list, 0 when absent"},
	{name = "alert_cents", kind = .Int, help = "the alert threshold, 0 when none"},
	{name = "same_product", kind = .Int, help = "offers of this product across retailers and pack sizes, itself included"},
}

COMPARE_FIELDS := []kit.Field {
	{name = "of", kind = .String, help = "the product compared"},
	{name = "offers", kind = .Array, of = PRODUCT_FIELDS, help = "cheapest first, by unit price where both have one"},
	{name = "cheapest", kind = .String, help = "the id of the first offer"},
}

BASKET_FIELDS := []kit.Field {
	{
		name = "lines",
		kind = .Array,
		of = {
			{name = "id", kind = .String},
			{name = "retailer", kind = .String},
			{name = "title", kind = .String},
			{name = "qty", kind = .Int},
			{name = "price_cents", kind = .Int},
			{name = "line_cents", kind = .Int},
			{name = "tva", kind = .String},
		},
	},
	{name = "items", kind = .Int},
	{name = "ttc_cents", kind = .Int},
	{name = "ht_cents", kind = .Int},
	{name = "tva_cents", kind = .Int, help = "HT + TVA = TTC, exactly"},
	{name = "ttc", kind = .String},
	{name = "by_rate", kind = .Array, of = {{name = "rate", kind = .String}, {name = "ht_cents", kind = .Int}, {name = "tva_cents", kind = .Int}}},
	{name = "by_retailer", kind = .Array, of = {{name = "retailer", kind = .String}, {name = "ttc_cents", kind = .Int}}},
}

LIST_FIELDS := []kit.Field {
	{
		name = "items",
		kind = .Array,
		help = "grouped by rayon, in the order the shop is walked",
		of = {
			{name = "id", kind = .String},
			{name = "retailer", kind = .String},
			{name = "title", kind = .String},
			{name = "aisle", kind = .String},
			{name = "qty", kind = .Int},
			{name = "done", kind = .Bool},
		},
	},
	{name = "as_listed_cents", kind = .Int},
	{name = "best_cents", kind = .Int, help = "the same list bought at the cheapest equivalent in stock"},
	{name = "saving_cents", kind = .Int},
}

ALERTS_FIELDS := []kit.Field {
	{
		name = "alerts",
		kind = .Array,
		of = {
			{name = "id", kind = .String},
			{name = "retailer", kind = .String},
			{name = "title", kind = .String},
			{name = "threshold_cents", kind = .Int},
			{name = "price_cents", kind = .Int},
			{name = "hit", kind = .Bool, help = "today's price is at or under the threshold"},
		},
	},
	{name = "firing", kind = .Int},
}

CHANGED_FIELDS := []kit.Field {
	{name = "id", kind = .String},
	{name = "title", kind = .String},
	{name = "qty", kind = .Int, help = "the quantity now; 0 when the line is gone"},
	{name = "saved", kind = .Bool, help = "written to the state file; false under --dry-run"},
}

LIST_CHECK_FIELDS := []kit.Field {
	{name = "id", kind = .String},
	{name = "title", kind = .String},
	{name = "done", kind = .Bool},
	{name = "changed", kind = .Bool},
	{name = "saved", kind = .Bool},
}

CLEARED_FIELDS := []kit.Field {
	{name = "removed", kind = .Int},
	{name = "left", kind = .Int},
	{name = "saved", kind = .Bool},
}

ALERT_FIELDS := []kit.Field {
	{name = "id", kind = .String},
	{name = "title", kind = .String},
	{name = "threshold_cents", kind = .Int, help = "0 when cleared"},
	{name = "armed", kind = .Bool},
	{name = "saved", kind = .Bool},
}

CHECK_FIELDS := []kit.Field {
	{name = "path", kind = .String},
	{name = "title", kind = .String, help = "the channel title"},
	{name = "fatal", kind = .String, help = "\"\" unless the document itself was refused"},
	{name = "products", kind = .Int},
	{name = "refused", kind = .Array, of = {{name = "item", kind = .String}, {name = "reason", kind = .String}}},
	{name = "sample", kind = .Array, of = PRODUCT_FIELDS, help = "the first five products read"},
}

EXPORT_FIELDS := []kit.Field {
	{name = "products", kind = .Int},
	{name = "xml", kind = .String},
	{name = "csv", kind = .String},
}

// ---------------------------------------------------------------------------
// The commands
// ---------------------------------------------------------------------------

@(private = "file")
COMMANDS := []kit.Command {
	{
		verb = "search",
		summary = "the catalogue through the window's own search and facets",
		effect = .Read,
		args = {{name = "query", kind = .String, help = "words, folded like the search field folds them; omit for everything"}},
		flags = {
			{name = "retailer", kind = .String, help = "comma-separated chains, e.g. Leclerc,Carrefour"},
			{name = "dept", kind = .Enum, values = {"all", "grocery", "clothing"}, def = "all", help = "department"},
			{name = "aisle", kind = .String, help = "a rayon by name, e.g. Crèmerie"},
			{name = "min", kind = .String, help = "lowest price, e.g. 1,50"},
			{name = "max", kind = .String, help = "highest price"},
			{name = "brand", kind = .String, help = "a brand; MDD means store brands"},
			{name = "promo", kind = .Bool, help = "only promotions"},
			{name = "in-stock", kind = .Bool, help = "only what is in stock"},
			{name = "nutri", kind = .Enum, values = {"A", "B", "C", "D", "E"}, help = "Nutri-Score no worse than this"},
			{name = "sort", kind = .Enum, values = {"relevance", "price", "price-down", "unit", "unit-down", "discount", "nutri", "name"}, help = "order; the saved sort when omitted"},
			{name = "limit", kind = .Int, def = "20", help = "how many at most; 0 for all"},
			{name = "feed", kind = .Path, help = "import this Merchant feed first, as `shop <feed>` does"},
		},
		out = SEARCH_FIELDS,
		examples = {"shop search lait --json", "shop search --retailer Leclerc --promo --sort unit --json", "shop search jean --dept clothing --limit 5 --json"},
		run = cmd_search,
	},
	{
		verb = "show",
		summary = "one product: prices, unit price, Nutri-Score, sizes, history, and where it is in the basket and list",
		effect = .Read,
		args = {{name = "product", kind = .String, help = "a feed id, or Retailer:id", required = true}},
		flags = {{name = "feed", kind = .Path, help = "import this Merchant feed first"}},
		out = SHOW_FIELDS,
		examples = {"shop show LEC-0000-0 --json"},
		run = cmd_show,
	},
	{
		verb = "compare",
		summary = "the same product at every chain and in every pack size, cheapest first",
		effect = .Read,
		args = {{name = "product", kind = .String, help = "a feed id, or Retailer:id", required = true}},
		flags = {{name = "feed", kind = .Path, help = "import this Merchant feed first"}},
		out = COMPARE_FIELDS,
		examples = {"shop compare LEC-0000-0 --json"},
		run = cmd_compare,
	},
	{
		verb = "basket",
		summary = "the basket, with its TVA breakdown per rate and its total per chain",
		effect = .Read,
		out = BASKET_FIELDS,
		examples = {"shop basket --json"},
		run = cmd_basket,
	},
	{
		verb = "basket-add",
		summary = "add to the basket; a negative --qty takes units away and zero units removes the line",
		effect = .Mutate,
		args = {{name = "product", kind = .String, help = "a feed id, or Retailer:id", required = true}},
		flags = {{name = "qty", kind = .Int, def = "1", help = "how many"}},
		out = CHANGED_FIELDS,
		examples = {"shop basket-add LEC-0000-0 --qty 2 --json"},
		run = cmd_basket_add,
	},
	{
		verb = "basket-remove",
		summary = "take a line out of the basket",
		effect = .Idempotent,
		args = {{name = "product", kind = .String, help = "a feed id, or Retailer:id", required = true}},
		out = CHANGED_FIELDS,
		examples = {"shop basket-remove LEC-0000-0 --json"},
		run = cmd_basket_remove,
	},
	{
		verb = "list",
		summary = "the shopping list, grouped by rayon, with what it would cost bought at the cheapest equivalent",
		effect = .Read,
		out = LIST_FIELDS,
		examples = {"shop list --json"},
		run = cmd_list,
	},
	{
		verb = "list-add",
		summary = "put a product on the shopping list",
		effect = .Mutate,
		args = {{name = "product", kind = .String, help = "a feed id, or Retailer:id", required = true}},
		flags = {{name = "qty", kind = .Int, def = "1", help = "how many"}},
		out = CHANGED_FIELDS,
		examples = {"shop list-add CRF-0000-1 --json"},
		run = cmd_list_add,
	},
	{
		verb = "list-check",
		summary = "tick an item off the list, or --off to untick it",
		effect = .Idempotent,
		args = {{name = "product", kind = .String, help = "a feed id, or Retailer:id", required = true}},
		flags = {{name = "off", kind = .Bool, help = "untick instead"}},
		out = LIST_CHECK_FIELDS,
		examples = {"shop list-check CRF-0000-1 --json"},
		run = cmd_list_check,
	},
	{
		verb = "list-clear-done",
		summary = "drop every ticked item from the list",
		effect = .Idempotent,
		out = CLEARED_FIELDS,
		examples = {"shop list-clear-done --json"},
		run = cmd_list_clear_done,
	},
	{
		verb = "alerts",
		summary = "price alerts, and which are firing",
		effect = .Read,
		out = ALERTS_FIELDS,
		examples = {"shop alerts --json"},
		run = cmd_alerts,
	},
	{
		verb = "alert-set",
		summary = "arm a price alert; the default threshold is five percent under today's price",
		effect = .Idempotent,
		args = {{name = "product", kind = .String, help = "a feed id, or Retailer:id", required = true}},
		flags = {{name = "below", kind = .String, help = "the threshold, e.g. 2,49"}},
		out = ALERT_FIELDS,
		examples = {"shop alert-set LEC-0000-0 --json", "shop alert-set LEC-0000-0 --below 1,20 --json"},
		run = cmd_alert_set,
	},
	{
		verb = "alert-clear",
		summary = "disarm a price alert",
		effect = .Idempotent,
		args = {{name = "product", kind = .String, help = "a feed id, or Retailer:id", required = true}},
		out = ALERT_FIELDS,
		examples = {"shop alert-clear LEC-0000-0 --json"},
		run = cmd_alert_clear,
	},
	{
		verb = "check",
		summary = "read a Merchant feed (RSS 2.0 or CSV) and say what it holds and what it refuses, importing nothing",
		effect = .Read,
		aliases = {"--check"},
		args = {{name = "feed", kind = .Path, help = "the feed file", required = true}},
		out = CHECK_FIELDS,
		examples = {"shop check catalogue-demo.xml --json", "shop --check=catalogue-demo.csv"},
		run = cmd_check,
	},
	{
		verb = "export",
		summary = "write the catalogue as Merchant feeds (XML and CSV) into the application's directory",
		effect = .Idempotent,
		aliases = {"--export"},
		out = EXPORT_FIELDS,
		examples = {"shop export --json", "shop --export"},
		run = cmd_export,
	},
}

@(private = "file")
g_surface: kit.Surface

surface :: proc() -> ^kit.Surface {
	if g_surface.noun == "" {
		g_surface = kit.Surface {
			noun       = "shop",
			summary    = "price comparison across six French chains, on a generated catalogue",
			gui        = true,
			takes_path = true, // `shop feed.xml` imports a feed and opens the window
			selftest   = run_selftest,
			notes      = SURFACE_NOTES,
			commands   = COMMANDS,
		}
	}
	return &g_surface
}

@(private = "file")
SURFACE_NOTES :: `The catalogue is generated locally and says so ("generated": true); these
are not live prices, and nothing is ever fetched. A Merchant Center feed
(RSS 2.0 with the g: namespace, or its CSV variant) is read only when named:
--feed on a read, check, or ` + "`shop <feed>`" + ` for the window.

<product> is a feed id such as LEC-0000-0 (ids carry their chain's prefix),
or Retailer:id. Nothing matching exits 3.

The basket, the list and the alerts live in $PALMY_SHOP_DIR/state.txt
(default ~/.local/share/palmy-shop), the same file the window reads and
writes, so a change here is in the window the next time it opens.

Window-only options, kept: --shots <dir>, --uitest[=dir], --walkthrough[=dir],
--import=<feed>.`

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

// cli_state builds the State the window builds. With --dry-run the data
// directory is emptied after loading, which is what makes save_state a no-op.
@(private = "file")
cli_state :: proc(c: ^kit.Call) -> ^State {
	st := new(State)
	state_init(st)
	if feed := kit.cli_str(c, "feed"); feed != "" {
		import_path(st, feed)
		kit.cli_trace(c, "shop: %s", st.import_msg)
	}
	if c.dry_run {
		st.data_dir = ""
	}
	return st
}

// find_ref resolves <product>: an id (case-insensitive), or Retailer:id.
find_ref :: proc(st: ^State, ref: string) -> int {
	r := strings.trim_space(ref)
	if colon := strings.index_byte(r, ':'); colon > 0 {
		if idx := find_product(st, r[:colon], r[colon + 1:]); idx >= 0 {
			return idx
		}
	}
	for p, i in st.cat.products {
		if strings.equal_fold(p.id, r) {
			return i
		}
	}
	return -1
}

@(private = "file")
resolve :: proc(c: ^kit.Call, st: ^State) -> (idx: int, code: int) {
	ref := kit.cli_str(c, "product")
	idx = find_ref(st, ref)
	if idx < 0 {
		code = kit.cli_failf(c, kit.EXIT_NOT_FOUND, "no product %q in the catalogue", ref)
		kit.cli_err_field(c, "product", ref)
		return -1, code
	}
	return idx, kit.EXIT_OK
}

@(private = "file")
product_json :: proc(p: Product) -> ^kit.Json {
	o := kit.jobj()
	kit.jset_str(o, "id", p.id)
	kit.jset_str(o, "retailer", retailer_name(p.retailer))
	kit.jset_str(o, "title", p.title)
	kit.jset_str(o, "brand", p.brand)
	kit.jset_int(o, "price_cents", int(p.price))
	kit.jset_str(o, "price", fmt_money(p.price, context.temp_allocator))
	kit.jset_int(o, "list_price_cents", int(p.list_price))
	kit.jset_bool(o, "promo", on_promo(p))
	kit.jset_str(o, "unit_price", p.has_unit ? fmt_unit_price(p.price, p.qty, context.temp_allocator) : "")
	kit.jset_int(o, "unit_cents", p.has_unit ? int(p.unit) : 0)
	kit.jset_str(o, "quantity", p.qty.ok ? fmt_quantity(p.qty, context.temp_allocator) : "")
	kit.jset_str(o, "aisle", p.aisle != .None ? aisle_name(p.aisle) : "")
	kit.jset_str(o, "availability", avail_feed_word(p.avail))
	kit.jset_str(o, "nutri", p.nutri.grade != .None ? nutri_letter(p.nutri.grade) : "")
	kit.jset_str(o, "gtin", p.gtin)
	kit.jset_str(o, "color", p.color)
	sizes := kit.jarr()
	for s in p.sizes {
		kit.jpush(sizes, kit.jstr(s))
	}
	kit.jset(o, "sizes", sizes)
	kit.jset_str(o, "tva", tva_label(p.tva))
	return o
}

@(private = "file")
SORT_WORDS := [Sort_Key]string {
	.Relevance  = "relevance",
	.Price_Up   = "price",
	.Price_Down = "price-down",
	.Unit_Up    = "unit",
	.Unit_Down  = "unit-down",
	.Discount   = "discount",
	.Nutri      = "nutri",
	.Name       = "name",
}

@(private = "file")
saved :: proc(st: ^State) -> bool {
	return st.data_dir != ""
}

// ---------------------------------------------------------------------------
// Reads
// ---------------------------------------------------------------------------

@(private = "file")
cmd_search :: proc(c: ^kit.Call) -> int {
	st := cli_state(c)

	// The same fields the search box and the facet pills write.
	q := kit.cli_str(c, "query")
	clear(&st.query)
	append(&st.query, q)

	f := &st.filter
	if rs := kit.cli_str(c, "retailer"); rs != "" {
		for name in strings.split(rs, ",", context.temp_allocator) {
			r := retailer_from_name(name)
			if r == .None {
				code := kit.cli_failf(c, kit.EXIT_USAGE, "no chain called %q", strings.trim_space(name))
				kit.cli_err_field(c, "retailer", name)
				return code
			}
			f.retailers[r] = true
		}
	}
	switch kit.cli_str(c, "dept") {
	case "grocery":
		f.dept = .Grocery
	case "clothing":
		f.dept = .Clothing
	case:
		f.dept = .All
	}
	if a := kit.cli_str(c, "aisle"); a != "" {
		f.aisle = parse_aisle(a)
		if f.aisle == .None {
			return kit.cli_failf(c, kit.EXIT_USAGE, "no rayon called %q", a)
		}
	}
	for name in ([?]string{"min", "max"}) {
		s := kit.cli_str(c, name)
		if s == "" {
			continue
		}
		v, ok := parse_money(s)
		if !ok {
			return kit.cli_failf(c, kit.EXIT_USAGE, "--%s wants a price such as 2,49, got %q", name, s)
		}
		if name == "min" {
			f.price_min = v
		} else {
			f.price_max = v
		}
	}
	if b := kit.cli_str(c, "brand"); b != "" {
		f.brand = b
	}
	f.promo_only = kit.cli_bool(c, "promo")
	f.in_stock = kit.cli_bool(c, "in-stock")
	if n := kit.cli_str(c, "nutri"); n != "" {
		f.nutri_max = nutri_from_letter(n)
	}
	if s := kit.cli_str(c, "sort"); s != "" {
		for word, k in SORT_WORDS {
			if word == s {
				st.sort = k
			}
		}
	}
	refilter(st)

	limit := kit.cli_int(c, "limit", 20)
	arr := kit.jarr()
	for idx in st.vis {
		if limit > 0 && kit.jlen(arr) >= limit {
			break
		}
		kit.jpush(arr, product_json(st.cat.products[idx]))
	}
	kit.jset_str(c.out, "query", q)
	kit.jset_int(c.out, "matched", len(st.vis))
	kit.jset_int(c.out, "catalogue", len(st.cat.products))
	kit.jset_bool(c.out, "generated", st.cat.generated)
	kit.jset_str(c.out, "source", st.cat.source)
	kit.jset_str(c.out, "sort", SORT_WORDS[st.sort])
	kit.jset(c.out, "products", arr)
	return kit.EXIT_OK
}

@(private = "file")
cmd_show :: proc(c: ^kit.Call) -> int {
	st := cli_state(c)
	idx, code := resolve(c, st)
	if idx < 0 {
		return code
	}
	p := st.cat.products[idx]
	kit.jset(c.out, "product", product_json(p))
	h := kit.jarr()
	for v in p.history {
		kit.jpush(h, kit.jint(int(v)))
	}
	kit.jset(c.out, "history_cents", h)
	kit.jset_bool(c.out, "lowest", at_lowest(p))
	in_basket, on_list, alert := 0, 0, 0
	if at := basket_find(st, idx); at >= 0 {
		in_basket = st.basket[at].qty
	}
	if at := list_find(st, idx); at >= 0 {
		on_list = st.list[at].qty
	}
	if at := alert_find(st, idx); at >= 0 {
		alert = int(st.alerts[at].threshold)
	}
	kit.jset_int(c.out, "in_basket", in_basket)
	kit.jset_int(c.out, "on_list", on_list)
	kit.jset_int(c.out, "alert_cents", alert)
	kit.jset_int(c.out, "same_product", len(group_of(&st.cat, idx, context.temp_allocator)))
	return kit.EXIT_OK
}

@(private = "file")
cmd_compare :: proc(c: ^kit.Call) -> int {
	st := cli_state(c)
	idx, code := resolve(c, st)
	if idx < 0 {
		return code
	}
	// group_of is the comparison view's own list, already in its order.
	g := group_of(&st.cat, idx, context.temp_allocator)
	arr := kit.jarr()
	for gi in g {
		kit.jpush(arr, product_json(st.cat.products[gi]))
	}
	kit.jset_str(c.out, "of", st.cat.products[idx].id)
	kit.jset(c.out, "offers", arr)
	kit.jset_str(c.out, "cheapest", len(g) > 0 ? st.cat.products[g[0]].id : "")
	return kit.EXIT_OK
}

@(private = "file")
cmd_basket :: proc(c: ^kit.Call) -> int {
	st := cli_state(c)
	lines := kit.jarr()
	for l in st.basket {
		if l.product < 0 || l.product >= len(st.cat.products) {
			continue
		}
		p := st.cat.products[l.product]
		o := kit.jobj()
		kit.jset_str(o, "id", p.id)
		kit.jset_str(o, "retailer", retailer_name(p.retailer))
		kit.jset_str(o, "title", p.title)
		kit.jset_int(o, "qty", l.qty)
		kit.jset_int(o, "price_cents", int(p.price))
		kit.jset_int(o, "line_cents", int(p.price) * l.qty)
		kit.jset_str(o, "tva", tva_label(p.tva))
		kit.jpush(lines, o)
	}
	t := basket_totals(st)
	kit.jset(c.out, "lines", lines)
	kit.jset_int(c.out, "items", t.items)
	kit.jset_int(c.out, "ttc_cents", int(t.ttc))
	kit.jset_int(c.out, "ht_cents", int(t.ht))
	kit.jset_int(c.out, "tva_cents", int(t.tva))
	kit.jset_str(c.out, "ttc", fmt_money(t.ttc, context.temp_allocator))
	rates := kit.jarr()
	for rate in Tva {
		if t.ht_by_tva[rate] == 0 && t.by_tva[rate] == 0 {
			continue
		}
		o := kit.jobj()
		kit.jset_str(o, "rate", tva_label(rate))
		kit.jset_int(o, "ht_cents", int(t.ht_by_tva[rate]))
		kit.jset_int(o, "tva_cents", int(t.by_tva[rate]))
		kit.jpush(rates, o)
	}
	kit.jset(c.out, "by_rate", rates)
	chains := kit.jarr()
	for r in Retailer {
		if t.by_retailer[r] == 0 {
			continue
		}
		o := kit.jobj()
		kit.jset_str(o, "retailer", retailer_name(r))
		kit.jset_int(o, "ttc_cents", int(t.by_retailer[r]))
		kit.jpush(chains, o)
	}
	kit.jset(c.out, "by_retailer", chains)
	return kit.EXIT_OK
}

@(private = "file")
cmd_list :: proc(c: ^kit.Call) -> int {
	st := cli_state(c)
	items := kit.jarr()
	for li in list_by_aisle(st) {
		it := st.list[li]
		p := st.cat.products[it.product]
		o := kit.jobj()
		kit.jset_str(o, "id", p.id)
		kit.jset_str(o, "retailer", retailer_name(p.retailer))
		kit.jset_str(o, "title", p.title)
		kit.jset_str(o, "aisle", p.aisle != .None ? aisle_name(p.aisle) : "")
		kit.jset_int(o, "qty", it.qty)
		kit.jset_bool(o, "done", it.done)
		kit.jpush(items, o)
	}
	as_listed, best := list_total(st)
	kit.jset(c.out, "items", items)
	kit.jset_int(c.out, "as_listed_cents", int(as_listed))
	kit.jset_int(c.out, "best_cents", int(best))
	kit.jset_int(c.out, "saving_cents", int(as_listed - best))
	return kit.EXIT_OK
}

@(private = "file")
cmd_alerts :: proc(c: ^kit.Call) -> int {
	st := cli_state(c)
	arr := kit.jarr()
	for a in st.alerts {
		if a.product < 0 || a.product >= len(st.cat.products) {
			continue
		}
		p := st.cat.products[a.product]
		o := kit.jobj()
		kit.jset_str(o, "id", p.id)
		kit.jset_str(o, "retailer", retailer_name(p.retailer))
		kit.jset_str(o, "title", p.title)
		kit.jset_int(o, "threshold_cents", int(a.threshold))
		kit.jset_int(o, "price_cents", int(p.price))
		kit.jset_bool(o, "hit", alert_hit(st, a))
		kit.jpush(arr, o)
	}
	kit.jset(c.out, "alerts", arr)
	kit.jset_int(c.out, "firing", alerts_firing(st))
	return kit.EXIT_OK
}

@(private = "file")
cmd_check :: proc(c: ^kit.Call) -> int {
	path := kit.cli_str(c, "feed")
	res := import_feed(path)
	defer feed_result_destroy(&res)
	// import_feed reports an unreadable file as fatal; a file that is not
	// there at all is the documented "not found", not a refused document.
	if res.fatal != "" && len(res.products) == 0 && !file_exists(path) {
		code := kit.cli_failf(c, kit.EXIT_NOT_FOUND, "no feed at %s", path)
		kit.cli_err_field(c, "feed", path)
		return code
	}
	kit.jset_str(c.out, "path", path)
	kit.jset_str(c.out, "title", res.title)
	kit.jset_str(c.out, "fatal", res.fatal)
	kit.jset_int(c.out, "products", len(res.products))
	refused := kit.jarr()
	for e in res.errors {
		o := kit.jobj()
		kit.jset_str(o, "item", e.item)
		kit.jset_str(o, "reason", e.reason)
		kit.jpush(refused, o)
	}
	kit.jset(c.out, "refused", refused)
	sample := kit.jarr()
	for i in 0 ..< min(5, len(res.products)) {
		kit.jpush(sample, product_json(res.products[i]))
	}
	kit.jset(c.out, "sample", sample)
	if res.fatal != "" {
		return kit.cli_failf(c, kit.EXIT_FAILED, "refused: %s", res.fatal)
	}
	return kit.EXIT_OK
}

// ---------------------------------------------------------------------------
// Changes: each one the procedure a key or a button calls
// ---------------------------------------------------------------------------

@(private = "file")
changed :: proc(c: ^kit.Call, st: ^State, idx: int, qty: int) {
	p := st.cat.products[idx]
	kit.jset_str(c.out, "id", p.id)
	kit.jset_str(c.out, "title", p.title)
	kit.jset_int(c.out, "qty", qty)
	kit.jset_bool(c.out, "saved", saved(st))
}

@(private = "file")
cmd_basket_add :: proc(c: ^kit.Call) -> int {
	st := cli_state(c)
	idx, code := resolve(c, st)
	if idx < 0 {
		return code
	}
	basket_add(st, idx, kit.cli_int(c, "qty", 1))
	now := 0
	if at := basket_find(st, idx); at >= 0 {
		now = st.basket[at].qty
	}
	changed(c, st, idx, now)
	return kit.EXIT_OK
}

@(private = "file")
cmd_basket_remove :: proc(c: ^kit.Call) -> int {
	st := cli_state(c)
	idx, code := resolve(c, st)
	if idx < 0 {
		return code
	}
	basket_remove(st, basket_find(st, idx))
	changed(c, st, idx, 0)
	return kit.EXIT_OK
}

@(private = "file")
cmd_list_add :: proc(c: ^kit.Call) -> int {
	st := cli_state(c)
	idx, code := resolve(c, st)
	if idx < 0 {
		return code
	}
	list_add(st, idx, max(1, kit.cli_int(c, "qty", 1)))
	changed(c, st, idx, st.list[list_find(st, idx)].qty)
	return kit.EXIT_OK
}

@(private = "file")
cmd_list_check :: proc(c: ^kit.Call) -> int {
	st := cli_state(c)
	idx, code := resolve(c, st)
	if idx < 0 {
		return code
	}
	at := list_find(st, idx)
	if at < 0 {
		code = kit.cli_failf(c, kit.EXIT_NOT_FOUND, "%s is not on the list", st.cat.products[idx].id)
		kit.cli_err_field(c, "product", st.cat.products[idx].id)
		return code
	}
	want := !kit.cli_bool(c, "off")
	flip := st.list[at].done != want
	if flip {
		// The window's tick is a toggle, so it is called only when the state
		// differs: that is what makes the command safe to repeat.
		list_toggle(st, at)
	}
	kit.jset_str(c.out, "id", st.cat.products[idx].id)
	kit.jset_str(c.out, "title", st.cat.products[idx].title)
	kit.jset_bool(c.out, "done", st.list[at].done)
	kit.jset_bool(c.out, "changed", flip)
	kit.jset_bool(c.out, "saved", saved(st))
	return kit.EXIT_OK
}

@(private = "file")
cmd_list_clear_done :: proc(c: ^kit.Call) -> int {
	st := cli_state(c)
	before := len(st.list)
	list_clear_done(st)
	kit.jset_int(c.out, "removed", before - len(st.list))
	kit.jset_int(c.out, "left", len(st.list))
	kit.jset_bool(c.out, "saved", saved(st))
	return kit.EXIT_OK
}

@(private = "file")
alert_out :: proc(c: ^kit.Call, st: ^State, idx: int) {
	p := st.cat.products[idx]
	th := 0
	if at := alert_find(st, idx); at >= 0 {
		th = int(st.alerts[at].threshold)
	}
	kit.jset_str(c.out, "id", p.id)
	kit.jset_str(c.out, "title", p.title)
	kit.jset_int(c.out, "threshold_cents", th)
	kit.jset_bool(c.out, "armed", th > 0)
	kit.jset_bool(c.out, "saved", saved(st))
}

@(private = "file")
cmd_alert_set :: proc(c: ^kit.Call) -> int {
	st := cli_state(c)
	idx, code := resolve(c, st)
	if idx < 0 {
		return code
	}
	th := Centimes(0)
	if s := kit.cli_str(c, "below"); s != "" {
		v, ok := parse_money(s)
		if !ok || v <= 0 {
			return kit.cli_failf(c, kit.EXIT_USAGE, "--below wants a price such as 2,49, got %q", s)
		}
		th = v
	}
	alert_set(st, idx, th)
	alert_out(c, st, idx)
	return kit.EXIT_OK
}

@(private = "file")
cmd_alert_clear :: proc(c: ^kit.Call) -> int {
	st := cli_state(c)
	idx, code := resolve(c, st)
	if idx < 0 {
		return code
	}
	alert_clear(st, idx)
	alert_out(c, st, idx)
	return kit.EXIT_OK
}

@(private = "file")
cmd_export :: proc(c: ^kit.Call) -> int {
	st := new(State)
	state_init(st)
	if c.dry_run {
		kit.jset_int(c.out, "products", len(st.cat.products))
		kit.jset_str(c.out, "xml", strings.concatenate({st.data_dir, "/catalogue-demo.xml"}, context.temp_allocator))
		kit.jset_str(c.out, "csv", strings.concatenate({st.data_dir, "/catalogue-demo.csv"}, context.temp_allocator))
		return kit.EXIT_OK
	}
	// The `e` key's procedure.
	xp, cp, good := export_fixture(st)
	if !good {
		return kit.cli_failf(c, kit.EXIT_FAILED, "cannot write into %s", st.data_dir)
	}
	kit.jset_int(c.out, "products", len(st.cat.products))
	kit.jset_str(c.out, "xml", xp)
	kit.jset_str(c.out, "csv", cp)
	if !c.json {
		kit.cli_note(c, "%d produits écrits", len(st.cat.products))
	}
	return kit.EXIT_OK
}

@(private = "file")
file_exists :: proc(path: string) -> bool {
	return os.exists(path)
}
