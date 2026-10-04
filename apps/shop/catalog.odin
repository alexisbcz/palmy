// The data model: retailers, products, the catalogue that holds them, and the
// derived values every view needs.
//
// A product is read once and finalised once. Folding its title for search,
// parsing its quantity, computing its unit price, running the Nutri-Score and
// building its cross-retailer match key all happen in `finalise`, when the
// catalogue is loaded — never in a frame. Six thousand products times a
// keystroke is a stutter; six thousand products once is four milliseconds.
package main

import "core:slice"
import "core:strings"

// ---------------------------------------------------------------------------
// Retailers
//
// Six French chains: three clothing, three grocery. The names are used to
// label a generated catalogue and nothing in this binary ever contacts them —
// see the note at the top of main.odin.
// ---------------------------------------------------------------------------

Retailer :: enum u8 {
	None,
	Kiabi,
	Bershka,
	Celio,
	Intermarche,
	Leclerc,
	Carrefour,
}

Retailer_Kind :: enum u8 {
	Clothing,
	Grocery,
}

retailer_name :: proc(r: Retailer) -> string {
	switch r {
	case .Kiabi:
		return "Kiabi"
	case .Bershka:
		return "Bershka"
	case .Celio:
		return "Celio"
	case .Intermarche:
		return "Intermarché"
	case .Leclerc:
		return "E.Leclerc"
	case .Carrefour:
		return "Carrefour"
	case .None:
		return "—"
	}
	return "—"
}

retailer_kind :: proc(r: Retailer) -> Retailer_Kind {
	switch r {
	case .Kiabi, .Bershka, .Celio:
		return .Clothing
	case .Intermarche, .Leclerc, .Carrefour, .None:
		return .Grocery
	}
	return .Grocery
}

// A tint per chain, so a row says where it came from before the label is read.
retailer_class :: proc(r: Retailer) -> string {
	switch r {
	case .Kiabi:
		return "bg-[#e5007d] text-white"
	case .Bershka:
		return "bg-[#1a1a1a] text-white"
	case .Celio:
		return "bg-[#0a3d62] text-white"
	case .Intermarche:
		return "bg-[#e2001a] text-white"
	case .Leclerc:
		return "bg-[#0056a3] text-white"
	case .Carrefour:
		return "bg-[#004e9a] text-white"
	case .None:
		return "bg-muted text-muted-foreground"
	}
	return "bg-muted text-muted-foreground"
}

retailer_from_name :: proc(s: string) -> Retailer {
	f := fold(s, context.temp_allocator)
	switch {
	case strings.contains(f, "kiabi"):
		return .Kiabi
	case strings.contains(f, "bershka"):
		return .Bershka
	case strings.contains(f, "celio"):
		return .Celio
	case strings.contains(f, "intermarche"):
		return .Intermarche
	case strings.contains(f, "leclerc"):
		return .Leclerc
	case strings.contains(f, "carrefour"):
		return .Carrefour
	}
	return .None
}

// ---------------------------------------------------------------------------
// Aisles — the rayons a grocery list is grouped by, in the order they are
// walked in a French supermarket, which is the order that saves a second lap.
// ---------------------------------------------------------------------------

Aisle :: enum u8 {
	None,
	Fruits_Legumes,
	Boucherie,
	Poissonnerie,
	Cremerie,
	Boulangerie,
	Epicerie_Salee,
	Epicerie_Sucree,
	Boissons,
	Surgeles,
	Hygiene,
	Entretien,
	Bebe,
	Textile,
}

aisle_name :: proc(a: Aisle) -> string {
	switch a {
	case .Fruits_Legumes:
		return "Fruits et légumes"
	case .Boucherie:
		return "Boucherie"
	case .Poissonnerie:
		return "Poissonnerie"
	case .Cremerie:
		return "Crèmerie"
	case .Boulangerie:
		return "Boulangerie"
	case .Epicerie_Salee:
		return "Épicerie salée"
	case .Epicerie_Sucree:
		return "Épicerie sucrée"
	case .Boissons:
		return "Boissons"
	case .Surgeles:
		return "Surgelés"
	case .Hygiene:
		return "Hygiène et beauté"
	case .Entretien:
		return "Entretien"
	case .Bebe:
		return "Bébé"
	case .Textile:
		return "Textile"
	case .None:
		return "Divers"
	}
	return "Divers"
}

Availability :: enum u8 {
	In_Stock,
	Out_Of_Stock,
	Preorder,
	Backorder,
}

avail_label :: proc(a: Availability) -> string {
	switch a {
	case .In_Stock:
		return "En stock"
	case .Out_Of_Stock:
		return "Épuisé"
	case .Preorder:
		return "Précommande"
	case .Backorder:
		return "Réassort"
	}
	return ""
}

// parse_availability reads Google's vocabulary and the French words a local
// exporter uses for the same thing.
parse_availability :: proc(s: string) -> Availability {
	f := fold(s, context.temp_allocator)
	switch {
	case strings.contains(f, "out of stock"), strings.contains(f, "epuise"), strings.contains(f, "rupture"):
		return .Out_Of_Stock
	case strings.contains(f, "preorder"), strings.contains(f, "precommande"):
		return .Preorder
	case strings.contains(f, "backorder"), strings.contains(f, "reassort"):
		return .Backorder
	}
	return .In_Stock
}

// ---------------------------------------------------------------------------
// Products
// ---------------------------------------------------------------------------

// HISTORY_LEN snapshots of the catalogue, oldest first, the last of which is
// today's price. A real deployment would accumulate these by importing a feed
// once a week; the fixture generates them so the history view and the alerts
// have something true to show.
HISTORY_LEN :: 12

Product :: struct {
	id:          string,
	retailer:    Retailer,
	title:       string,
	brand:       string,
	gtin:        string, // EAN-13, "" when the retailer publishes none
	category:    string, // the g:product_type path
	aisle:       Aisle,
	group:       string, // g:item_group_id, which ties a garment's sizes together

	// Money. `price` is what is charged today, `list_price` what it was before
	// the promotion; they are equal when there is no promotion.
	price:       Centimes,
	list_price:  Centimes,
	tva:         Tva,
	shipping:    Centimes,

	avail:       Availability,
	color:       string,
	sizes:       []string,
	chart:       Size_Chart,
	size_system: Size_System,

	qty_text:    string,
	qty:         Quantity,
	unit:        Centimes,
	has_unit:    bool,

	nutrition:   Nutrition,
	nutri:       Nutri_Result,

	// Derived, computed once.
	folded:      string,
	key:         string, // exact identity: the barcode where there is one
	tkey:        string, // equivalence: what the thing is, ignoring the pack size
	history:     [HISTORY_LEN]Centimes,
}

product_free :: proc(p: ^Product) {
	delete(p.id)
	delete(p.title)
	delete(p.brand)
	delete(p.gtin)
	delete(p.category)
	delete(p.color)
	delete(p.qty_text)
	delete(p.group)
	delete(p.folded)
	delete(p.key)
	delete(p.tkey)
	for s in p.sizes {
		delete(s)
	}
	delete(p.sizes)
}

// on_promo is a price below the one the retailer quotes as its own reference.
on_promo :: proc(p: Product) -> bool {
	return p.list_price > p.price
}

discount_tenths :: proc(p: Product) -> i64 {
	if !on_promo(p) {
		return 0
	}
	return -pct_change(p.list_price, p.price)
}

// finalise computes everything derived from the fields a feed provides. It is
// called once per product, by the importer and by the fixture generator, so
// there is exactly one definition of what a product's unit price and search
// text are.
finalise :: proc(p: ^Product) {
	// The quantity comes from the dedicated field when there is one, and from
	// the title when there is not — which is most of the time.
	//
	// Clothing is excluded outright. A garment has no prix au kilo, and
	// reading one out of a title would invent one: "Pyjama 2 pièces" is a set
	// of two garments, not a quantity to divide a price by, and €/pièce on a
	// pyjama is a number that looks informative and is not.
	if retailer_kind(p.retailer) != .Clothing {
		q := parse_quantity(p.qty_text)
		if !q.ok {
			q = parse_quantity(p.title)
		}
		p.qty = q
		p.unit, p.has_unit = unit_price(p.price, q)
	} else {
		p.qty = Quantity{}
		p.unit, p.has_unit = 0, false
	}

	if p.nutrition.known {
		p.nutri = nutri_score(p.nutrition)
	}

	// The search skeleton covers everything a shopper might type: the brand,
	// the title, the colour and the category path.
	all := strings.concatenate(
		{p.brand, " ", p.title, " ", p.color, " ", p.category, " ", retailer_name(p.retailer)},
		context.temp_allocator,
	)
	delete(p.folded)
	p.folded = fold(all)

	// Two identities, because two different questions get asked of a product.
	//
	// `tkey` is "what is this thing": the title with the pack size, the units
	// and the packaging words stripped out, so a 1 L carton and a lot of six
	// 1 L cartons of the same milk share it. That is the set the comparison
	// view wants, because the whole point of a unit price is to compare across
	// pack sizes.
	//
	// `key` is "is this literally the same article": the barcode when the
	// retailer published a valid one. Store brands have a different barcode at
	// every chain, which is exactly why the title key has to exist too.
	delete(p.tkey)
	brand_part := retailer_kind(p.retailer) == .Clothing ? "" : p.brand
	title_part := p.title
	if retailer_kind(p.retailer) == .Clothing {
		title_part = strings.concatenate({p.title, " ", p.color}, context.temp_allocator)
	}
	p.tkey = match_key(brand_part, title_part)

	delete(p.key)
	switch {
	case p.gtin != "" && ean13_valid(p.gtin):
		// A valid barcode is the identity, and it is the same identity at
		// every retailer. A barcode that fails its check digit is treated as
		// absent rather than trusted, so a typo cannot merge two products.
		p.key = strings.concatenate({"gtin:", p.gtin})
	case:
		p.key = strings.clone(p.tkey)
	}
}

// ---------------------------------------------------------------------------
// The catalogue
// ---------------------------------------------------------------------------

Catalog :: struct {
	products: [dynamic]Product,
	source:   string, // where this came from, shown in the UI
	generated: bool,  // true for the fixture, false for an imported feed

	// Match groups. `groups` is keyed on the exact identity (the barcode where
	// there is one), `equiv` on the title key, which is what finds the same
	// product under three store brands and in three pack sizes.
	groups:   map[string][dynamic]int,
	equiv:    map[string][dynamic]int,

	// Labels for the history columns, oldest first.
	weeks:    [HISTORY_LEN]string,
}

catalog_destroy :: proc(c: ^Catalog) {
	for &p in c.products {
		product_free(&p)
	}
	delete(c.products)
	for k, v in c.groups {
		delete(k)
		delete(v)
	}
	delete(c.groups)
	for k, v in c.equiv {
		delete(k)
		delete(v)
	}
	delete(c.equiv)
	delete(c.source)
	for w in c.weeks {
		delete(w)
	}
}

// catalog_index builds the match groups. Called after every load or import.
catalog_index :: proc(c: ^Catalog) {
	for k, v in c.groups {
		delete(k)
		delete(v)
	}
	clear(&c.groups)
	for k, v in c.equiv {
		delete(k)
		delete(v)
	}
	clear(&c.equiv)

	for p, i in c.products {
		if p.key != "" {
			if existing, found := &c.groups[p.key]; found {
				append(existing, i)
			} else {
				list := make([dynamic]int)
				append(&list, i)
				c.groups[strings.clone(p.key)] = list
			}
		}
		if p.tkey != "" {
			if existing, found := &c.equiv[p.tkey]; found {
				append(existing, i)
			} else {
				list := make([dynamic]int)
				append(&list, i)
				c.equiv[strings.clone(p.tkey)] = list
			}
		}
	}
}

// group_of returns every product that is the same thing as this one, this one
// included, cheapest first *honestly* — ordered on the unit price where both
// have one, so a 1 kg bag does not come out ahead of a 500 g bag just because
// the sticker is smaller.
group_of :: proc(c: ^Catalog, idx: int, allocator := context.allocator) -> []int {
	if idx < 0 || idx >= len(c.products) {
		return nil
	}
	// The union of the exact group and the equivalence group, deduplicated:
	// every article that is this article, plus every pack size of it, at every
	// chain that sells one.
	seen := make(map[int]bool, 16, context.temp_allocator)
	gather := make([dynamic]int, context.temp_allocator)
	for pass in 0 ..< 2 {
		list: [dynamic]int
		found: bool
		if pass == 0 {
			list, found = c.groups[c.products[idx].key]
		} else {
			list, found = c.equiv[c.products[idx].tkey]
		}
		if !found {
			continue
		}
		for i in list {
			if !seen[i] {
				seen[i] = true
				append(&gather, i)
			}
		}
	}
	if len(gather) == 0 {
		out := make([]int, 1, allocator)
		out[0] = idx
		return out
	}
	out := make([]int, len(gather), allocator)
	copy(out, gather[:])
	sort_catalog = c
	slice.sort_by(out, cmp_by_value)
	return out
}

// Odin has no closures, so the comparator reads the catalogue through a file
// scoped pointer set immediately before the sort. Every sort in this program
// runs on the frame thread and finishes before the next one starts.
@(private = "file")
sort_catalog: ^Catalog

@(private = "file")
cmp_by_value :: proc(a, b: int) -> bool {
	c := sort_catalog
	if c == nil {
		return a < b
	}
	pa, pb := c.products[a], c.products[b]
	// In stock first: a cheaper price you cannot buy is not cheaper.
	if (pa.avail == .In_Stock) != (pb.avail == .In_Stock) {
		return pa.avail == .In_Stock
	}
	if pa.has_unit && pb.has_unit && pa.unit != pb.unit {
		return pa.unit < pb.unit
	}
	if pa.price != pb.price {
		return pa.price < pb.price
	}
	return pa.retailer < pb.retailer
}

// ---------------------------------------------------------------------------
// Price history
// ---------------------------------------------------------------------------

history_min :: proc(p: Product) -> Centimes {
	m := p.history[0]
	for v in p.history {
		if v < m {
			m = v
		}
	}
	return m
}

history_max :: proc(p: Product) -> Centimes {
	m := p.history[0]
	for v in p.history {
		if v > m {
			m = v
		}
	}
	return m
}

// history_change is the move from the oldest snapshot to today, in tenths of a
// percent.
history_change :: proc(p: Product) -> i64 {
	return pct_change(p.history[0], p.history[HISTORY_LEN - 1])
}

// at_lowest says whether today's price is the lowest this catalogue has seen,
// which is the only honest version of "best price ever".
at_lowest :: proc(p: Product) -> bool {
	return p.price <= history_min(p)
}
