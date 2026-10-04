// Clothing sizes, and the fact that there are five answers to "what size am I".
//
// A French shopper knows one number — "je fais du 38" — and every retailer
// quotes something different. Bershka labels in EU, so their 36 is that same
// 38. A UK-sourced listing says 10 and a US one says 6. And it changes again
// between departments: FR womenswear runs two sizes above the EU scale, while
// FR menswear *is* the EU scale, so a men's 48 is an M and a women's 48 is not
// a size at all. Shoes are a third system, gendered, with half sizes in the US
// column that cannot be held in an integer.
//
// So a size here is never a bare number. It is a (chart, system, label) triple
// resolved through a published table, and the tables are asserted in the
// self-test — including the three places where the men's and women's answers
// differ for the same input, which is the whole reason this file exists.
package main

import "core:strings"

Size_System :: enum u8 {
	FR,
	EU,
	UK,
	US,
	Alpha,
}

size_system_label :: proc(s: Size_System) -> string {
	switch s {
	case .FR:
		return "FR"
	case .EU:
		return "EU"
	case .UK:
		return "UK"
	case .US:
		return "US"
	case .Alpha:
		return "S/M/L"
	}
	return "FR"
}

Size_Chart :: enum u8 {
	None,
	Women_Tops,
	Men_Tops,
	Kids,
	Women_Shoes,
	Men_Shoes,
}

size_chart_label :: proc(c: Size_Chart) -> string {
	switch c {
	case .Women_Tops:
		return "Femme"
	case .Men_Tops:
		return "Homme"
	case .Kids:
		return "Enfant"
	case .Women_Shoes:
		return "Chaussures femme"
	case .Men_Shoes:
		return "Chaussures homme"
	case .None:
		return "—"
	}
	return "—"
}

// A row is one physical size written five ways. An empty cell means the system
// does not name that size — shoes have no S/M/L.
Size_Row :: struct {
	fr, eu, uk, us, alpha: string,
}

// Womenswear: tops, dresses and coats. FR = EU + 2, which is the conversion
// everyone gets wrong.
@(private = "file")
WOMEN_TOPS := [?]Size_Row {
	{"32", "30", "4", "0", "XXS"},
	{"34", "32", "6", "2", "XS"},
	{"36", "34", "8", "4", "S"},
	{"38", "36", "10", "6", "M"},
	{"40", "38", "12", "8", "L"},
	{"42", "40", "14", "10", "XL"},
	{"44", "42", "16", "12", "XXL"},
	{"46", "44", "18", "14", "3XL"},
	{"48", "46", "20", "16", "4XL"},
}

// Menswear: shirts, jackets and knitwear on the chest scale. France quotes the
// same numbers as the rest of the EU here, and UK/US run ten below.
@(private = "file")
MEN_TOPS := [?]Size_Row {
	{"42", "42", "32", "32", "XXS"},
	{"44", "44", "34", "34", "XS"},
	{"46", "46", "36", "36", "S"},
	{"48", "48", "38", "38", "M"},
	{"50", "50", "40", "40", "L"},
	{"52", "52", "42", "42", "XL"},
	{"54", "54", "44", "44", "XXL"},
	{"56", "56", "46", "46", "3XL"},
}

// Children: France sizes by age, the rest of the EU by height in centimetres,
// the UK by age with a Y and the US with a T for toddlers.
@(private = "file")
KIDS := [?]Size_Row {
	{"2 ans", "92", "2Y", "2T", "2A"},
	{"3 ans", "98", "3Y", "3T", "3A"},
	{"4 ans", "104", "4Y", "4T", "4A"},
	{"5 ans", "110", "5Y", "5", "5A"},
	{"6 ans", "116", "6Y", "6", "6A"},
	{"8 ans", "128", "8Y", "8", "8A"},
	{"10 ans", "140", "10Y", "10", "10A"},
	{"12 ans", "152", "12Y", "12", "12A"},
	{"14 ans", "164", "14Y", "14", "14A"},
}

@(private = "file")
WOMEN_SHOES := [?]Size_Row {
	{"36", "36", "3,5", "5,5", ""},
	{"37", "37", "4", "6", ""},
	{"38", "38", "5", "7", ""},
	{"39", "39", "6", "8", ""},
	{"40", "40", "6,5", "9", ""},
	{"41", "41", "7,5", "10", ""},
	{"42", "42", "8", "10,5", ""},
}

@(private = "file")
MEN_SHOES := [?]Size_Row {
	{"40", "40", "6", "7", ""},
	{"41", "41", "7", "8", ""},
	{"42", "42", "8", "9", ""},
	{"43", "43", "9", "10", ""},
	{"44", "44", "9,5", "10,5", ""},
	{"45", "45", "10,5", "11,5", ""},
	{"46", "46", "11,5", "12,5", ""},
}

size_rows :: proc(c: Size_Chart) -> []Size_Row {
	switch c {
	case .Women_Tops:
		return WOMEN_TOPS[:]
	case .Men_Tops:
		return MEN_TOPS[:]
	case .Kids:
		return KIDS[:]
	case .Women_Shoes:
		return WOMEN_SHOES[:]
	case .Men_Shoes:
		return MEN_SHOES[:]
	case .None:
		return nil
	}
	return nil
}

size_cell :: proc(r: Size_Row, s: Size_System) -> string {
	switch s {
	case .FR:
		return r.fr
	case .EU:
		return r.eu
	case .UK:
		return r.uk
	case .US:
		return r.us
	case .Alpha:
		return r.alpha
	}
	return ""
}

// same_label compares two size labels the way a shopper would: case folded,
// accents gone, both decimal marks accepted ("9.5" is "9,5"), and the French
// "ans" or an English "Y"/"T" suffix ignored so "6 ans" matches "6".
@(private = "file")
same_label :: proc(a, b: string) -> bool {
	na := norm_size(a)
	nb := norm_size(b)
	return na != "" && na == nb
}

@(private = "file")
norm_size :: proc(s: string) -> string {
	f := fold(s, context.temp_allocator)
	// "6 ans" -> "6", "6y" -> "6", "2t" -> "2"
	if i := strings.index(f, " an"); i > 0 {
		f = f[:i]
	}
	f = strings.trim_space(f)
	if len(f) > 1 {
		last := f[len(f) - 1]
		if (last == 'y' || last == 't') && f[0] >= '0' && f[0] <= '9' {
			f = f[:len(f) - 1]
		}
	}
	// A US half size may arrive with either separator.
	out := strings.builder_make(context.temp_allocator)
	for i in 0 ..< len(f) {
		c := f[i]
		if c == '.' {
			strings.write_byte(&out, ',')
		} else if c != ' ' {
			strings.write_byte(&out, c)
		}
	}
	return strings.to_string(out)
}

// size_lookup finds the row a label belongs to within a chart, and says which
// system it was quoted in. A label that appears in two columns resolves to the
// system asked for first, so a product that declares its own system is never
// reinterpreted.
size_lookup :: proc(c: Size_Chart, label: string, prefer := Size_System.FR) -> (row: int, sys: Size_System, ok: bool) {
	rows := size_rows(c)
	order := [?]Size_System{prefer, .FR, .EU, .UK, .US, .Alpha}
	for s in order {
		for r, i in rows {
			if same_label(size_cell(r, s), label) {
				return i, s, true
			}
		}
	}
	return 0, .FR, false
}

// size_convert is the whole point: a label in one system, out in another.
//
//	size_convert(.Women_Tops, "38", .FR, .UK)  ->  "10"
//	size_convert(.Men_Tops,   "38", .UK, .FR)  ->  "48"
size_convert :: proc(c: Size_Chart, label: string, from, to: Size_System) -> (string, bool) {
	rows := size_rows(c)
	for r in rows {
		if same_label(size_cell(r, from), label) {
			out := size_cell(r, to)
			if out == "" {
				return "", false
			}
			return out, true
		}
	}
	return "", false
}

// size_all writes one size in every system, for the detail panel: a shopper
// who knows their FR size should be able to read a Bershka listing without
// doing arithmetic.
size_all :: proc(c: Size_Chart, label: string, from: Size_System, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	first := true
	for s in Size_System {
		v, ok := size_convert(c, label, from, s)
		if !ok {
			continue
		}
		if !first {
			strings.write_string(&b, " · ")
		}
		first = false
		strings.write_string(&b, size_system_label(s))
		strings.write_string(&b, " ")
		strings.write_string(&b, v)
	}
	return strings.to_string(b)
}

// size_matches answers the filter "show me what exists in my size", where the
// shopper's size is quoted in their own system and the product's sizes are
// quoted in the retailer's. Both are resolved to a row index in the chart, so
// the comparison happens on the physical size and not on the label.
size_matches :: proc(
	c: Size_Chart,
	product_sizes: []string,
	product_system: Size_System,
	want_label: string,
	want_system: Size_System,
) -> bool {
	if c == .None || want_label == "" {
		return true
	}
	target, _, ok := size_lookup(c, want_label, want_system)
	if !ok {
		return false
	}
	for s in product_sizes {
		row, _, found := size_lookup(c, s, product_system)
		if found && row == target {
			return true
		}
	}
	return false
}

// chart_for guesses the chart from a product type path like
// "Vêtements > Femme > Robes", which is what the feed's g:product_type says.
// It is only a guess, so a feed that states the department wins over it.
chart_for :: proc(product_type: string) -> Size_Chart {
	f := fold(product_type, context.temp_allocator)
	shoes := strings.contains(f, "chaussure") || strings.contains(f, "basket") ||
	         strings.contains(f, "sneaker") || strings.contains(f, "bottine")
	switch {
	case strings.contains(f, "enfant") || strings.contains(f, "bebe") || strings.contains(f, "fille") || strings.contains(f, "garcon"):
		return .Kids
	case strings.contains(f, "femme"):
		return shoes ? .Women_Shoes : .Women_Tops
	case strings.contains(f, "homme"):
		return shoes ? .Men_Shoes : .Men_Tops
	}
	return .None
}
