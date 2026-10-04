// Reading the formats retailers actually publish.
//
// Nothing here goes near a website. A comparison site does not scrape a shop;
// it is given a product feed, and the format is standardised: Google Merchant
// Center's RSS 2.0 with the `g:` namespace, and the flat CSV/TSV variant of
// the same field names. That is what this file reads, so a real affiliate feed
// dropped into the import dialog works without a line of new code.
//
//	<item>
//	  <g:id>CRF-0001</g:id>
//	  <g:title>Lait demi-écrémé UHT 1 L — lot de 6</g:title>
//	  <g:brand>Carrefour</g:brand>
//	  <g:price>6,54 EUR</g:price>
//	  <g:sale_price>5,88 EUR</g:sale_price>
//	  <g:gtin>3560070462018</g:gtin>
//	  <g:availability>in stock</g:availability>
//	  <g:product_type>Épicerie &gt; Crèmerie &gt; Lait</g:product_type>
//	  <g:unit_pricing_measure>6 x 1 l</g:unit_pricing_measure>
//	  <g:shipping><g:country>FR</g:country><g:price>4,90 EUR</g:price></g:shipping>
//	</item>
//
// The nutrition block has no equivalent in Google's specification — no
// retailer publishes one — so it is carried in a `shop:` namespace of this
// application's own, and the Nutri-Score is computed from it rather than
// trusted from a feed. A feed that only states the letter is honoured as a
// letter, and the detail panel says which of the two it is showing.
//
// Malformed input is refused, per item, with a reason, and never crashes the
// importer: a missing price, a price in a currency that is not the euro, a
// quantity that does not parse, a truncated document. Those are not
// hypothetical — a feed is a file on someone else's build server.
package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

Feed_Error :: struct {
	item:   string, // the item's id, or its position when the id is missing
	reason: string,
}

Feed_Result :: struct {
	products: [dynamic]Product,
	errors:   [dynamic]Feed_Error,
	title:    string, // the channel title, usually the retailer's name
	fatal:    string, // set when the document itself could not be read
}

feed_result_destroy :: proc(r: ^Feed_Result) {
	for &p in r.products {
		product_free(&p)
	}
	delete(r.products)
	for e in r.errors {
		delete(e.item)
		delete(e.reason)
	}
	delete(r.errors)
	delete(r.title)
	delete(r.fatal)
}

@(private = "file")
refuse :: proc(r: ^Feed_Result, item: string, reason: string) {
	append(&r.errors, Feed_Error{item = strings.clone(item), reason = strings.clone(reason)})
}

// ---------------------------------------------------------------------------
// Entities and small parsers
// ---------------------------------------------------------------------------

// decode_entities expands the five XML entities and both numeric forms. A
// French feed is full of `&gt;` in the category path and `&amp;` in brand
// names ("Bonne Maman & Cie"), so this is not optional.
decode_entities :: proc(s: string, allocator := context.allocator) -> string {
	if !strings.contains(s, "&") {
		return strings.clone(s, allocator)
	}
	b := strings.builder_make(allocator)
	i := 0
	for i < len(s) {
		if s[i] != '&' {
			strings.write_byte(&b, s[i])
			i += 1
			continue
		}
		semi := strings.index_byte(s[i:], ';')
		if semi < 0 || semi > 12 {
			strings.write_byte(&b, s[i])
			i += 1
			continue
		}
		ent := s[i + 1:i + semi]
		switch ent {
		case "amp":
			strings.write_byte(&b, '&')
		case "lt":
			strings.write_byte(&b, '<')
		case "gt":
			strings.write_byte(&b, '>')
		case "quot":
			strings.write_byte(&b, '"')
		case "apos":
			strings.write_byte(&b, '\'')
		case "nbsp":
			strings.write_string(&b, NBSP)
		case:
			if len(ent) > 1 && ent[0] == '#' {
				cp: int
				ok := false
				if len(ent) > 2 && (ent[1] == 'x' || ent[1] == 'X') {
					v, good := strconv.parse_int(ent[2:], 16)
					cp, ok = v, good
				} else {
					v, good := strconv.parse_int(ent[1:], 10)
					cp, ok = v, good
				}
				if ok && cp > 0 && cp <= 0x10ffff {
					strings.write_rune(&b, rune(cp))
				} else {
					strings.write_string(&b, s[i:i + semi + 1])
				}
			} else {
				// An unknown entity is left as it was found rather than
				// dropped: a title is better slightly wrong than silently
				// shortened.
				strings.write_string(&b, s[i:i + semi + 1])
			}
		}
		i += semi + 1
	}
	return strings.to_string(b)
}

// parse_milli reads a decimal with up to three places and returns it scaled by
// a thousand, which is how nutrition values become milligrams. Both decimal
// marks are accepted; anything else is refused.
parse_milli :: proc(s: string) -> (i64, bool) {
	t := strings.trim_space(s)
	if t == "" {
		return 0, false
	}
	neg := false
	if t[0] == '-' {
		neg = true
		t = t[1:]
	}
	whole: i64 = 0
	frac: i64 = 0
	scale: i64 = 1
	seen := false
	any := false
	for i in 0 ..< len(t) {
		c := t[i]
		switch {
		case c >= '0' && c <= '9':
			any = true
			if seen {
				if scale < 1000 {
					frac = frac * 10 + i64(c - '0')
					scale *= 10
				}
			} else {
				whole = whole * 10 + i64(c - '0')
			}
		case c == ',' || c == '.':
			if seen {
				return 0, false
			}
			seen = true
		case c == ' ':
		case:
			return 0, false
		}
	}
	if !any {
		return 0, false
	}
	v := whole * 1000 + frac * 1000 / scale
	return neg ? -v : v, true
}

// parse_int_field is a plain integer field — energy in kJ, a fruit percentage.
parse_int_field :: proc(s: string) -> (i64, bool) {
	m, ok := parse_milli(s)
	if !ok {
		return 0, false
	}
	return m / 1000, true
}

parse_tva :: proc(s: string) -> (Tva, bool) {
	f := strings.trim_space(s)
	if f == "" {
		return .Standard, false
	}
	m, ok := parse_milli(f)
	if !ok {
		switch fold(f, context.temp_allocator) {
		case "standard", "normal":
			return .Standard, true
		case "reduit", "intermediaire":
			return .Reduced, true
		case "alimentaire":
			return .Food, true
		}
		return .Standard, false
	}
	// A rate written as a percentage: 20, 10, 5,5 or 2,1.
	switch m {
	case 20_000:
		return .Standard, true
	case 10_000:
		return .Reduced, true
	case 5_500:
		return .Food, true
	case 2_100:
		return .Super, true
	}
	return .Standard, false
}

parse_food_class :: proc(s: string) -> Food_Class {
	switch fold(s, context.temp_allocator) {
	case "beverage", "boisson":
		return .Beverage
	case "water", "eau":
		return .Water
	case "cheese", "fromage":
		return .Cheese
	case "added fat", "added_fat", "matiere grasse", "huile":
		return .Added_Fat
	}
	return .Solid
}

parse_aisle :: proc(s: string) -> Aisle {
	f := fold(s, context.temp_allocator)
	for a in Aisle {
		if fold(aisle_name(a), context.temp_allocator) == f {
			return a
		}
	}
	// Fall back to the category path's vocabulary.
	switch {
	case strings.contains(f, "fruit"), strings.contains(f, "legume"):
		return .Fruits_Legumes
	case strings.contains(f, "boucherie"), strings.contains(f, "viande"):
		return .Boucherie
	case strings.contains(f, "poisson"):
		return .Poissonnerie
	case strings.contains(f, "cremerie"), strings.contains(f, "laitier"), strings.contains(f, "fromage"):
		return .Cremerie
	case strings.contains(f, "boulangerie"), strings.contains(f, "pain"):
		return .Boulangerie
	case strings.contains(f, "boisson"), strings.contains(f, "eau"), strings.contains(f, "jus"):
		return .Boissons
	case strings.contains(f, "surgele"):
		return .Surgeles
	case strings.contains(f, "hygiene"), strings.contains(f, "beaute"):
		return .Hygiene
	case strings.contains(f, "entretien"), strings.contains(f, "menage"):
		return .Entretien
	case strings.contains(f, "bebe"):
		return .Bebe
	case strings.contains(f, "vetement"), strings.contains(f, "textile"), strings.contains(f, "chaussure"):
		return .Textile
	case strings.contains(f, "sucre"), strings.contains(f, "biscuit"), strings.contains(f, "chocolat"):
		return .Epicerie_Sucree
	case strings.contains(f, "epicerie"):
		return .Epicerie_Salee
	}
	return .None
}

parse_size_system :: proc(s: string) -> Size_System {
	switch fold(s, context.temp_allocator) {
	case "fr", "france":
		return .FR
	case "eu", "europe":
		return .EU
	case "uk", "gb":
		return .UK
	case "us", "usa":
		return .US
	case "alpha", "s m l":
		return .Alpha
	}
	return .FR
}

// ---------------------------------------------------------------------------
// The item under construction
// ---------------------------------------------------------------------------

@(private = "file")
Raw :: struct {
	id:         string,
	title:      string,
	brand:      string,
	gtin:       string,
	price:      string,
	sale_price: string,
	avail:      string,
	ptype:      string,
	color:      string,
	size:       string,
	size_sys:   string,
	measure:    string,
	group:      string,
	ship:       string,
	tva:        string,
	aisle:      string,
	retailer:   string,
	nutri:      string,
	food_class: string,
	energy:     string,
	sugars:     string,
	satfat:     string,
	totalfat:   string,
	sodium:     string,
	fibre:      string,
	protein:    string,
	fruit:      string,
}

@(private = "file")
raw_set :: proc(r: ^Raw, field, value: string) {
	switch field {
	case "id", "g:id":
		r.id = value
	case "title", "g:title":
		r.title = value
	case "brand", "g:brand":
		r.brand = value
	case "gtin", "g:gtin", "ean":
		r.gtin = value
	case "price", "g:price":
		r.price = value
	case "sale_price", "g:sale_price":
		r.sale_price = value
	case "availability", "g:availability":
		r.avail = value
	case "product_type", "g:product_type":
		r.ptype = value
	case "color", "g:color", "couleur":
		r.color = value
	case "size", "g:size", "taille":
		r.size = value
	case "size_system", "g:size_system":
		r.size_sys = value
	case "unit_pricing_measure", "g:unit_pricing_measure", "quantite":
		r.measure = value
	case "item_group_id", "g:item_group_id":
		r.group = value
	case "shipping_price", "shipping", "g:shipping":
		r.ship = value
	case "tax_rate", "tva", "shop:tva":
		r.tva = value
	case "aisle", "rayon", "shop:rayon":
		r.aisle = value
	case "retailer", "enseigne", "shop:enseigne":
		r.retailer = value
	case "nutri_score", "nutriscore", "shop:nutri_score":
		r.nutri = value
	case "food_class", "shop:food_class":
		r.food_class = value
	case "energy_kj", "shop:energy_kj":
		r.energy = value
	case "sugars_g", "shop:sugars_g":
		r.sugars = value
	case "saturated_fat_g", "shop:saturated_fat_g":
		r.satfat = value
	case "total_fat_g", "shop:total_fat_g":
		r.totalfat = value
	case "sodium_mg", "shop:sodium_mg":
		r.sodium = value
	case "fibre_g", "shop:fibre_g":
		r.fibre = value
	case "protein_g", "shop:protein_g":
		r.protein = value
	case "fruit_pct", "shop:fruit_pct":
		r.fruit = value
	}
}

// build turns a collected item into a Product, or refuses it with a reason.
// Every refusal here is a case that a real feed produces.
@(private = "file")
build :: proc(res: ^Feed_Result, raw: Raw, pos: int, fallback: Retailer) -> bool {
	label := raw.id != "" ? raw.id : fmt.tprintf("item #%d", pos)

	if strings.trim_space(raw.id) == "" {
		refuse(res, label, "identifiant (g:id) absent")
		return false
	}
	if strings.trim_space(raw.title) == "" {
		refuse(res, label, "titre (g:title) absent")
		return false
	}
	if strings.trim_space(raw.price) == "" {
		refuse(res, label, "prix (g:price) absent")
		return false
	}
	list_price, price_ok := parse_money(raw.price)
	if !price_ok {
		refuse(res, label, fmt.tprintf("prix illisible ou devise non reconnue: %q", raw.price))
		return false
	}
	if list_price <= 0 {
		refuse(res, label, fmt.tprintf("prix non positif: %q", raw.price))
		return false
	}
	price := list_price
	if strings.trim_space(raw.sale_price) != "" {
		sp, ok := parse_money(raw.sale_price)
		if !ok {
			refuse(res, label, fmt.tprintf("prix promotionnel illisible: %q", raw.sale_price))
			return false
		}
		if sp > 0 && sp <= list_price {
			price = sp
		} else if sp > list_price {
			refuse(res, label, "prix promotionnel supérieur au prix de référence")
			return false
		}
	}

	p := Product{}
	p.id = strings.clone(strings.trim_space(raw.id))
	p.title = strings.clone(strings.trim_space(raw.title))
	p.brand = strings.clone(strings.trim_space(raw.brand))
	p.category = strings.clone(strings.trim_space(raw.ptype))
	p.color = strings.clone(strings.trim_space(raw.color))
	p.qty_text = strings.clone(strings.trim_space(raw.measure))
	p.group = strings.clone(strings.trim_space(raw.group))
	p.price = price
	p.list_price = list_price
	p.avail = parse_availability(raw.avail)

	g := strings.trim_space(raw.gtin)
	if g != "" && !ean13_valid(g) {
		// Not fatal: the product is kept, but it will be matched on its title
		// rather than on a barcode that does not check out.
		refuse(res, label, fmt.tprintf("GTIN invalide (chiffre de contrôle): %q — apparié sur le titre", g))
		g = ""
	}
	p.gtin = strings.clone(g)

	if r := retailer_from_name(raw.retailer); r != .None {
		p.retailer = r
	} else if r2 := retailer_from_name(raw.brand); r2 != .None {
		p.retailer = r2
	} else {
		p.retailer = fallback
	}

	if t, ok := parse_tva(raw.tva); ok {
		p.tva = t
	} else {
		// No rate in the feed: infer from the department, which is what a
		// price comparison has to do. Food is 5,5 %, everything else 20 %.
		p.tva = retailer_kind(p.retailer) == .Grocery ? Tva.Food : Tva.Standard
		if a := parse_aisle(raw.ptype); a == .Hygiene || a == .Entretien || a == .Textile {
			p.tva = .Standard
		}
	}

	if raw.ship != "" {
		if s, ok := parse_money(raw.ship); ok {
			p.shipping = s
		}
	}

	p.aisle = raw.aisle != "" ? parse_aisle(raw.aisle) : parse_aisle(raw.ptype)
	p.chart = chart_for(raw.ptype)
	p.size_system = parse_size_system(raw.size_sys)
	if s := strings.trim_space(raw.size); s != "" {
		sizes := make([dynamic]string)
		for part in strings.split(s, ",", context.temp_allocator) {
			t := strings.trim_space(part)
			if t != "" {
				append(&sizes, strings.clone(t))
			}
		}
		p.sizes = sizes[:]
	}

	// Nutrition, when the feed carries the block.
	if raw.energy != "" {
		n := Nutrition{}
		n.known = true
		n.class = parse_food_class(raw.food_class)
		if v, ok := parse_int_field(raw.energy); ok {
			n.energy_kj = v
		}
		if v, ok := parse_milli(raw.sugars); ok {
			n.sugars_mg = v
		}
		if v, ok := parse_milli(raw.satfat); ok {
			n.satfat_mg = v
		}
		if v, ok := parse_milli(raw.totalfat); ok {
			n.total_fat_mg = v
		}
		if v, ok := parse_int_field(raw.sodium); ok {
			n.sodium_mg = v
		}
		if v, ok := parse_milli(raw.fibre); ok {
			n.fibre_mg = v
		}
		if v, ok := parse_milli(raw.protein); ok {
			n.protein_mg = v
		}
		if v, ok := parse_int_field(raw.fruit); ok {
			n.fruit_pct = v
		}
		p.nutrition = n
	} else if raw.nutri != "" {
		// Only the letter was published. Honour it, and mark that it was not
		// computed here by leaving the nutrition table unknown.
		p.nutri = Nutri_Result{grade = nutri_from_letter(raw.nutri)}
	}

	// A fresh import has no history yet, so today's price fills it; importing
	// a second snapshot shifts it along (see catalog_absorb).
	for i in 0 ..< HISTORY_LEN {
		p.history[i] = p.price
	}

	finalise(&p)
	append(&res.products, p)
	return true
}

// ---------------------------------------------------------------------------
// RSS 2.0 with the g: namespace
// ---------------------------------------------------------------------------

// parse_merchant_xml reads a Google Merchant Center product feed. It is a
// deliberately small XML reader: elements, text, CDATA, comments, processing
// instructions and entities, which is the whole of what a product feed uses.
// Attributes are skipped, because no field in the specification lives in one.
//
// A document that ends inside a tag, or with an element still open, is a
// fatal error with a line number — not a silent half-import.
parse_merchant_xml :: proc(src: string, fallback: Retailer) -> Feed_Result {
	res := Feed_Result{}
	res.products = make([dynamic]Product)
	res.errors = make([dynamic]Feed_Error)

	stack := make([dynamic]string, context.temp_allocator)
	text := strings.builder_make(context.temp_allocator)

	raw := Raw{}
	in_item := false
	in_shipping := false
	items := 0
	line := 1

	fatal :: proc(res: ^Feed_Result, line: int, what: string) -> Feed_Result {
		res.fatal = strings.clone(fmt.tprintf("ligne %d: %s", line, what))
		return res^
	}

	i := 0
	for i < len(src) {
		c := src[i]
		if c != '<' {
			if c == '\n' {
				line += 1
			}
			strings.write_byte(&text, c)
			i += 1
			continue
		}

		// A markup construct. Work out which.
		if strings.has_prefix(src[i:], "<!--") {
			end := strings.index(src[i:], "-->")
			if end < 0 {
				return fatal(&res, line, "commentaire non terminé — document tronqué")
			}
			for j in i ..< i + end {
				if src[j] == '\n' {
					line += 1
				}
			}
			i += end + 3
			continue
		}
		if strings.has_prefix(src[i:], "<![CDATA[") {
			end := strings.index(src[i:], "]]>")
			if end < 0 {
				return fatal(&res, line, "section CDATA non terminée — document tronqué")
			}
			strings.write_string(&text, src[i + 9:i + end])
			i += end + 3
			continue
		}
		if strings.has_prefix(src[i:], "<?") {
			end := strings.index(src[i:], "?>")
			if end < 0 {
				return fatal(&res, line, "déclaration XML non terminée — document tronqué")
			}
			i += end + 2
			continue
		}
		if strings.has_prefix(src[i:], "<!") {
			end := strings.index_byte(src[i:], '>')
			if end < 0 {
				return fatal(&res, line, "déclaration non terminée — document tronqué")
			}
			i += end + 1
			continue
		}

		close_at := strings.index_byte(src[i:], '>')
		if close_at < 0 {
			return fatal(&res, line, "balise non fermée — document tronqué")
		}
		inner := src[i + 1:i + close_at]
		i += close_at + 1
		if inner == "" {
			return fatal(&res, line, "balise vide")
		}

		closing := inner[0] == '/'
		self := strings.has_suffix(inner, "/")
		body := inner
		if closing {
			body = body[1:]
		}
		if self {
			body = body[:len(body) - 1]
		}
		name := body
		if sp := strings.index_any(body, " \t\r\n"); sp >= 0 {
			name = body[:sp]
		}
		name = strings.trim_space(name)
		if name == "" {
			return fatal(&res, line, "nom de balise absent")
		}

		if closing {
			if len(stack) == 0 {
				return fatal(&res, line, fmt.tprintf("balise fermante </%s> sans ouvrante", name))
			}
			open := stack[len(stack) - 1]
			if open != name {
				return fatal(
					&res,
					line,
					fmt.tprintf("balise fermante </%s> alors que <%s> est ouverte", name, open),
				)
			}
			pop(&stack)

			value := strings.trim_space(strings.to_string(text))
			strings.builder_reset(&text)

			switch {
			case name == "item":
				in_item = false
				items += 1
				build(&res, raw, items, fallback)
				raw = Raw{}
			case name == "g:shipping":
				in_shipping = false
			case name == "channel" || name == "rss":
			// nothing
			case in_item:
				if in_shipping {
					// Only the price inside the shipping block is of interest.
					if name == "g:price" || name == "price" {
						raw.ship = decode_entities(value, context.temp_allocator)
					}
				} else {
					raw_set(&raw, name, decode_entities(value, context.temp_allocator))
				}
			case len(stack) > 0 && stack[len(stack) - 1] == "channel" && name == "title":
				delete(res.title)
				res.title = decode_entities(value)
			}
			continue
		}

		// An opening tag. Text collected before it belongs to the parent and
		// is dropped, which is correct for a feed: no element has both text
		// and children.
		strings.builder_reset(&text)
		if !self {
			append(&stack, name)
		}
		switch name {
		case "item":
			in_item = true
			raw = Raw{}
		case "g:shipping":
			if in_item {
				in_shipping = true
			}
		}
	}

	if len(stack) != 0 {
		return fatal(&res, line, fmt.tprintf("<%s> jamais fermée — document tronqué", stack[len(stack) - 1]))
	}
	if items == 0 {
		res.fatal = strings.clone("aucun <item> trouvé: ce fichier n'est pas un flux produits")
	}
	merge_variants(&res)
	return res
}

// ---------------------------------------------------------------------------
// The CSV / TSV variant
// ---------------------------------------------------------------------------

// parse_merchant_csv reads the flat form of the same feed. The delimiter is
// detected from the header line, because a French exporter writes semicolons
// (the decimal comma makes a comma-separated file ambiguous) while Google's
// own documentation uses tabs.
parse_merchant_csv :: proc(src: string, fallback: Retailer) -> Feed_Result {
	res := Feed_Result{}
	res.products = make([dynamic]Product)
	res.errors = make([dynamic]Feed_Error)

	lines := split_csv_lines(src, context.temp_allocator)
	if len(lines) < 2 {
		res.fatal = strings.clone("fichier vide ou sans ligne d'en-tête")
		return res
	}
	delim := detect_delimiter(lines[0])
	header := split_csv_row(lines[0], delim, context.temp_allocator)
	cols := make([]string, len(header), context.temp_allocator)
	for h, i in header {
		cols[i] = strings.to_lower(strings.trim_space(h), context.temp_allocator)
		// Accept both the dotted and the underscored spelling.
		cols[i], _ = strings.replace_all(cols[i], " ", "_", context.temp_allocator)
	}

	for li in 1 ..< len(lines) {
		if strings.trim_space(lines[li]) == "" {
			continue
		}
		fields := split_csv_row(lines[li], delim, context.temp_allocator)
		if len(fields) != len(cols) {
			refuse(
				&res,
				fmt.tprintf("ligne %d", li + 1),
				fmt.tprintf("%d colonnes pour %d en-têtes", len(fields), len(cols)),
			)
			continue
		}
		raw := Raw{}
		for f, ci in fields {
			raw_set(&raw, cols[ci], strings.trim_space(f))
		}
		build(&res, raw, li, fallback)
	}
	merge_variants(&res)
	return res
}

@(private = "file")
detect_delimiter :: proc(header: string) -> u8 {
	semi, tab, comma := 0, 0, 0
	for i in 0 ..< len(header) {
		switch header[i] {
		case ';':
			semi += 1
		case '\t':
			tab += 1
		case ',':
			comma += 1
		}
	}
	if tab >= semi && tab >= comma && tab > 0 {
		return '\t'
	}
	if semi >= comma && semi > 0 {
		return ';'
	}
	return ','
}

// split_csv_lines splits on newlines that are not inside quotes, so a product
// description containing a line break does not break the file.
@(private = "file")
split_csv_lines :: proc(src: string, allocator := context.allocator) -> []string {
	out := make([dynamic]string, allocator)
	start := 0
	inq := false
	i := 0
	for i < len(src) {
		c := src[i]
		if c == '"' {
			inq = !inq
			i += 1
			continue
		}
		if !inq && (c == '\n' || c == '\r') {
			append(&out, src[start:i])
			if c == '\r' && i + 1 < len(src) && src[i + 1] == '\n' {
				i += 1
			}
			i += 1
			start = i
			continue
		}
		i += 1
	}
	if start < len(src) {
		append(&out, src[start:])
	}
	return out[:]
}

@(private = "file")
split_csv_row :: proc(line: string, delim: u8, allocator := context.allocator) -> []string {
	out := make([dynamic]string, allocator)
	b := strings.builder_make(allocator)
	inq := false
	i := 0
	for i < len(line) {
		c := line[i]
		switch {
		case c == '"':
			if inq && i + 1 < len(line) && line[i + 1] == '"' {
				strings.write_byte(&b, '"')
				i += 2
				continue
			}
			inq = !inq
			i += 1
		case c == delim && !inq:
			append(&out, strings.to_string(b))
			b = strings.builder_make(allocator)
			i += 1
		case:
			strings.write_byte(&b, c)
			i += 1
		}
	}
	append(&out, strings.to_string(b))
	return out[:]
}

// ---------------------------------------------------------------------------
// Variants
// ---------------------------------------------------------------------------

// merge_variants folds a clothing feed's per-size items into one product. A
// real feed lists a jumper once per size, tied together by g:item_group_id;
// a shopper wants one row that says which sizes it comes in, priced at the
// cheapest variant, so the merge happens at import.
@(private = "file")
merge_variants :: proc(res: ^Feed_Result) {
	any_group := false
	for p in res.products {
		if p.group != "" {
			any_group = true
			break
		}
	}
	if !any_group {
		return
	}

	kept := make([dynamic]Product)
	first := make(map[string]int)
	defer delete(first)

	for &p in res.products {
		if p.group == "" {
			append(&kept, p)
			continue
		}
		gkey := strings.concatenate({retailer_name(p.retailer), "/", p.group}, context.temp_allocator)
		at, found := first[gkey]
		if !found {
			first[strings.clone(gkey, context.temp_allocator)] = len(kept)
			append(&kept, p)
			continue
		}
		host := &kept[at]
		// The sizes this variant adds.
		sizes := make([dynamic]string)
		for s in host.sizes {
			append(&sizes, s)
		}
		for s in p.sizes {
			dup := false
			for e in sizes {
				if e == s {
					dup = true
					break
				}
			}
			if dup {
				delete(s)
			} else {
				append(&sizes, s)
			}
		}
		delete(host.sizes)
		delete(p.sizes)
		p.sizes = nil
		host.sizes = sizes[:]
		if p.price < host.price {
			host.price = p.price
			host.list_price = p.list_price
		}
		if p.avail == .In_Stock {
			host.avail = .In_Stock
		}
		finalise(host)
		product_free(&p)
	}

	delete(res.products)
	res.products = kept
}

// ---------------------------------------------------------------------------
// Writing a feed back out
// ---------------------------------------------------------------------------

@(private = "file")
xml_escape :: proc(s: string, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	for i in 0 ..< len(s) {
		switch s[i] {
		case '&':
			strings.write_string(&b, "&amp;")
		case '<':
			strings.write_string(&b, "&lt;")
		case '>':
			strings.write_string(&b, "&gt;")
		case '"':
			strings.write_string(&b, "&quot;")
		case:
			strings.write_byte(&b, s[i])
		}
	}
	return strings.to_string(b)
}

// write_merchant_xml exports the catalogue in the format it reads, which is
// what makes the round trip assertable: generate, write, read back, compare.
write_merchant_xml :: proc(path: string, c: ^Catalog, only: Retailer = .None) -> bool {
	b := strings.builder_make()
	defer strings.builder_destroy(&b)

	strings.write_string(&b, "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n")
	strings.write_string(
		&b,
		"<rss version=\"2.0\" xmlns:g=\"http://base.google.com/ns/1.0\" xmlns:shop=\"https://palmy.local/ns/shop\">\n",
	)
	strings.write_string(&b, "<channel>\n")
	fmt.sbprintf(&b, "<title>%s</title>\n", xml_escape(only == .None ? c.source : retailer_name(only), context.temp_allocator))
	strings.write_string(&b, "<description>Catalogue de démonstration — aucun prix réel</description>\n")

	for p in c.products {
		if only != .None && p.retailer != only {
			continue
		}
		strings.write_string(&b, "<item>\n")
		fmt.sbprintf(&b, "  <g:id>%s</g:id>\n", xml_escape(p.id, context.temp_allocator))
		fmt.sbprintf(&b, "  <g:title>%s</g:title>\n", xml_escape(p.title, context.temp_allocator))
		if p.brand != "" {
			fmt.sbprintf(&b, "  <g:brand>%s</g:brand>\n", xml_escape(p.brand, context.temp_allocator))
		}
		if p.gtin != "" {
			fmt.sbprintf(&b, "  <g:gtin>%s</g:gtin>\n", p.gtin)
		}
		fmt.sbprintf(&b, "  <g:price>%s EUR</g:price>\n", fmt_centimes(p.list_price, context.temp_allocator))
		if p.price != p.list_price {
			fmt.sbprintf(&b, "  <g:sale_price>%s EUR</g:sale_price>\n", fmt_centimes(p.price, context.temp_allocator))
		}
		fmt.sbprintf(&b, "  <g:availability>%s</g:availability>\n", avail_feed_word(p.avail))
		if p.category != "" {
			fmt.sbprintf(&b, "  <g:product_type>%s</g:product_type>\n", xml_escape(p.category, context.temp_allocator))
		}
		if p.color != "" {
			fmt.sbprintf(&b, "  <g:color>%s</g:color>\n", xml_escape(p.color, context.temp_allocator))
		}
		if len(p.sizes) > 0 {
			fmt.sbprintf(&b, "  <g:size>%s</g:size>\n", xml_escape(strings.join(p.sizes, ",", context.temp_allocator), context.temp_allocator))
			fmt.sbprintf(&b, "  <g:size_system>%s</g:size_system>\n", size_system_label(p.size_system))
		}
		if p.qty_text != "" {
			fmt.sbprintf(&b, "  <g:unit_pricing_measure>%s</g:unit_pricing_measure>\n", xml_escape(p.qty_text, context.temp_allocator))
		}
		if p.shipping > 0 {
			fmt.sbprintf(
				&b,
				"  <g:shipping><g:country>FR</g:country><g:price>%s EUR</g:price></g:shipping>\n",
				fmt_centimes(p.shipping, context.temp_allocator),
			)
		}
		fmt.sbprintf(&b, "  <shop:tva>%s</shop:tva>\n", tva_feed_word(p.tva))
		fmt.sbprintf(&b, "  <shop:enseigne>%s</shop:enseigne>\n", xml_escape(retailer_name(p.retailer), context.temp_allocator))
		fmt.sbprintf(&b, "  <shop:rayon>%s</shop:rayon>\n", xml_escape(aisle_name(p.aisle), context.temp_allocator))
		if p.nutrition.known {
			n := p.nutrition
			fmt.sbprintf(&b, "  <shop:food_class>%s</shop:food_class>\n", food_class_word(n.class))
			fmt.sbprintf(&b, "  <shop:energy_kj>%d</shop:energy_kj>\n", n.energy_kj)
			fmt.sbprintf(&b, "  <shop:sugars_g>%s</shop:sugars_g>\n", fmt_dec(n.sugars_mg, 1000, 3, context.temp_allocator))
			fmt.sbprintf(&b, "  <shop:saturated_fat_g>%s</shop:saturated_fat_g>\n", fmt_dec(n.satfat_mg, 1000, 3, context.temp_allocator))
			fmt.sbprintf(&b, "  <shop:total_fat_g>%s</shop:total_fat_g>\n", fmt_dec(n.total_fat_mg, 1000, 3, context.temp_allocator))
			fmt.sbprintf(&b, "  <shop:sodium_mg>%d</shop:sodium_mg>\n", n.sodium_mg)
			fmt.sbprintf(&b, "  <shop:fibre_g>%s</shop:fibre_g>\n", fmt_dec(n.fibre_mg, 1000, 3, context.temp_allocator))
			fmt.sbprintf(&b, "  <shop:protein_g>%s</shop:protein_g>\n", fmt_dec(n.protein_mg, 1000, 3, context.temp_allocator))
			fmt.sbprintf(&b, "  <shop:fruit_pct>%d</shop:fruit_pct>\n", n.fruit_pct)
		}
		strings.write_string(&b, "</item>\n")
	}
	strings.write_string(&b, "</channel>\n</rss>\n")
	return os.write_entire_file(path, transmute([]u8)strings.to_string(b)) == nil
}

avail_feed_word :: proc(a: Availability) -> string {
	switch a {
	case .In_Stock:
		return "in stock"
	case .Out_Of_Stock:
		return "out of stock"
	case .Preorder:
		return "preorder"
	case .Backorder:
		return "backorder"
	}
	return "in stock"
}

tva_feed_word :: proc(t: Tva) -> string {
	switch t {
	case .Standard:
		return "20"
	case .Reduced:
		return "10"
	case .Food:
		return "5,5"
	case .Super:
		return "2,1"
	}
	return "20"
}

food_class_word :: proc(f: Food_Class) -> string {
	switch f {
	case .Solid:
		return "solid"
	case .Beverage:
		return "beverage"
	case .Water:
		return "water"
	case .Cheese:
		return "cheese"
	case .Added_Fat:
		return "added_fat"
	}
	return "solid"
}

// write_merchant_csv is the flat export, semicolon separated because that is
// what a French spreadsheet opens without a dialog.
write_merchant_csv :: proc(path: string, c: ^Catalog, only: Retailer = .None) -> bool {
	b := strings.builder_make()
	defer strings.builder_destroy(&b)

	cols := [?]string {
		"id", "title", "brand", "gtin", "price", "sale_price", "availability",
		"product_type", "color", "size", "size_system", "unit_pricing_measure",
		"tva", "enseigne", "rayon", "food_class", "energy_kj", "sugars_g",
		"saturated_fat_g", "total_fat_g", "sodium_mg", "fibre_g", "protein_g",
		"fruit_pct",
	}
	for col, i in cols {
		if i > 0 {
			strings.write_byte(&b, ';')
		}
		strings.write_string(&b, col)
	}
	strings.write_byte(&b, '\n')

	q :: proc(b: ^strings.Builder, s: string) {
		needs := strings.contains(s, ";") || strings.contains(s, "\"") || strings.contains(s, "\n")
		if !needs {
			strings.write_string(b, s)
			return
		}
		strings.write_byte(b, '"')
		for i in 0 ..< len(s) {
			if s[i] == '"' {
				strings.write_string(b, "\"\"")
			} else {
				strings.write_byte(b, s[i])
			}
		}
		strings.write_byte(b, '"')
	}

	for p in c.products {
		if only != .None && p.retailer != only {
			continue
		}
		n := p.nutrition
		fields := [?]string {
			p.id,
			p.title,
			p.brand,
			p.gtin,
			fmt_centimes(p.list_price, context.temp_allocator),
			p.price != p.list_price ? fmt_centimes(p.price, context.temp_allocator) : "",
			avail_feed_word(p.avail),
			p.category,
			p.color,
			len(p.sizes) > 0 ? strings.join(p.sizes, ",", context.temp_allocator) : "",
			len(p.sizes) > 0 ? size_system_label(p.size_system) : "",
			p.qty_text,
			tva_feed_word(p.tva),
			retailer_name(p.retailer),
			aisle_name(p.aisle),
			n.known ? food_class_word(n.class) : "",
			n.known ? fmt.tprintf("%d", n.energy_kj) : "",
			n.known ? fmt_dec(n.sugars_mg, 1000, 3, context.temp_allocator) : "",
			n.known ? fmt_dec(n.satfat_mg, 1000, 3, context.temp_allocator) : "",
			n.known ? fmt_dec(n.total_fat_mg, 1000, 3, context.temp_allocator) : "",
			n.known ? fmt.tprintf("%d", n.sodium_mg) : "",
			n.known ? fmt_dec(n.fibre_mg, 1000, 3, context.temp_allocator) : "",
			n.known ? fmt_dec(n.protein_mg, 1000, 3, context.temp_allocator) : "",
			n.known ? fmt.tprintf("%d", n.fruit_pct) : "",
		}
		for f, i in fields {
			if i > 0 {
				strings.write_byte(&b, ';')
			}
			q(&b, f)
		}
		strings.write_byte(&b, '\n')
	}
	return os.write_entire_file(path, transmute([]u8)strings.to_string(b)) == nil
}

// ---------------------------------------------------------------------------
// Importing into a catalogue
// ---------------------------------------------------------------------------

// import_feed reads a file, picking the parser from its extension and, failing
// that, from its first non-blank character. Only the file the user named is
// read; nothing else on the disk is touched.
import_feed :: proc(path: string, fallback: Retailer = .None) -> Feed_Result {
	data, rerr := os.read_entire_file(path, context.temp_allocator)
	if rerr != nil {
		res := Feed_Result{}
		res.products = make([dynamic]Product)
		res.errors = make([dynamic]Feed_Error)
		res.fatal = strings.clone(fmt.tprintf("impossible de lire %s", path))
		return res
	}
	src := string(data)
	lower := strings.to_lower(path, context.temp_allocator)
	xmlish := strings.has_suffix(lower, ".xml") || strings.has_suffix(lower, ".rss")
	if !xmlish && !strings.has_suffix(lower, ".csv") && !strings.has_suffix(lower, ".tsv") &&
	   !strings.has_suffix(lower, ".txt") {
		t := strings.trim_left_space(src)
		xmlish = strings.has_prefix(t, "<")
	}
	if xmlish {
		return parse_merchant_xml(src, fallback)
	}
	return parse_merchant_csv(src, fallback)
}

// catalog_absorb moves an imported set of products into the catalogue. A
// product already present (same retailer, same id) keeps its history and gets
// today's price appended, which is how the price history accumulates from
// weekly feeds rather than being invented.
catalog_absorb :: proc(c: ^Catalog, res: ^Feed_Result) -> (added, updated: int) {
	for &np in res.products {
		found := -1
		for p, i in c.products {
			if p.retailer == np.retailer && p.id == np.id {
				found = i
				break
			}
		}
		if found < 0 {
			append(&c.products, np)
			added += 1
			continue
		}
		old := &c.products[found]
		for i in 0 ..< HISTORY_LEN - 1 {
			old.history[i] = old.history[i + 1]
		}
		old.history[HISTORY_LEN - 1] = np.price
		old.price = np.price
		old.list_price = np.list_price
		old.avail = np.avail
		finalise(old)
		product_free(&np)
		updated += 1
	}
	clear(&res.products)
	catalog_index(c)
	return
}
