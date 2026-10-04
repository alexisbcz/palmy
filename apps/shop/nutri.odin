// Nutri-Score.
//
// This is a published algorithm, not an impression. It is the 2017 French
// scheme (arrêté du 31 octobre 2017, after the Food Standards Agency score as
// adapted by Santé publique France): negative points from energy, sugars,
// saturated fat and sodium, positive points from fruit/vegetable/legume
// content, fibre and protein, the difference bucketed into A to E.
//
// Three things make it easy to get subtly wrong, and all three are implemented
// and asserted here:
//
//   - **Beverages have their own tables.** Energy and sugars are scored on a
//     much tighter scale, the fruit points go up to 10 rather than 5, and the
//     grade boundaries are different: only water can be an A.
//   - **Cheese is exempt from the protein rule.** Normally, when the negative
//     points reach 11 the protein points are withheld, so that a salty fatty
//     food cannot buy its way back with protein. Cheese is named as an
//     exception and always counts its protein, which is why an Emmental is a
//     D rather than an E.
//   - **Added fats score saturated fat as a ratio.** For oils, butter and
//     margarine the component is saturated fat as a percentage of total fat,
//     not grams per 100 g — otherwise every oil would sit at the top of the
//     table and olive oil could not be a D.
//
// All arithmetic is integer. Nutrient values arrive in milligrams per 100 g
// and energy in kilojoules per 100 g, so a threshold like "4,5 g of sugars"
// is the exact comparison `sugars_mg <= 4500` rather than a float that may or
// may not be 4.5.
package main

Nutri :: enum u8 {
	None,
	A,
	B,
	C,
	D,
	E,
}

nutri_letter :: proc(n: Nutri) -> string {
	switch n {
	case .A:
		return "A"
	case .B:
		return "B"
	case .C:
		return "C"
	case .D:
		return "D"
	case .E:
		return "E"
	case .None:
		return "—"
	}
	return "—"
}

// The official colours, which shoppers read before they read the letter.
nutri_class :: proc(n: Nutri) -> string {
	switch n {
	case .A:
		return "bg-[#038141] text-white"
	case .B:
		return "bg-[#85bb2f] text-white"
	case .C:
		return "bg-[#fecb02] text-black"
	case .D:
		return "bg-[#ee8100] text-white"
	case .E:
		return "bg-[#e63e11] text-white"
	case .None:
		return "bg-muted text-muted-foreground"
	}
	return "bg-muted text-muted-foreground"
}

// Food_Class picks the tables. It is a property of the product, declared in
// the catalogue, because no algorithm can tell a cheese from a yoghurt by its
// nutrition alone.
Food_Class :: enum u8 {
	Solid,
	Beverage,
	Water,
	Cheese,
	Added_Fat,
}

// Nutrition is per 100 g for a solid and per 100 ml for a drink, which is how
// the EU nutrition declaration is written and how a feed carries it.
Nutrition :: struct {
	energy_kj:    i64, // kJ
	sugars_mg:    i64,
	satfat_mg:    i64,
	total_fat_mg: i64, // only used by the added-fats ratio
	sodium_mg:    i64,
	fibre_mg:     i64,
	protein_mg:   i64,
	fruit_pct:    i64, // fruit, vegetables, legumes, nuts and rapeseed/walnut/olive oils
	class:        Food_Class,
	known:        bool,
}

Nutri_Result :: struct {
	grade:           Nutri,
	score:           int,
	negative:        int,
	positive:        int,
	protein_counted: bool,
	pts_energy:      int,
	pts_sugars:      int,
	pts_satfat:      int,
	pts_sodium:      int,
	pts_fruit:       int,
	pts_fibre:       int,
	pts_protein:     int,
}

// points_le walks a table of inclusive upper bounds: the first bound the value
// does not exceed gives its index as the point count, and a value past the end
// gets len(bounds).
@(private = "file")
points_le :: proc(v: i64, bounds: []i64) -> int {
	for b, i in bounds {
		if v <= b {
			return i
		}
	}
	return len(bounds)
}

@(private = "file")
ENERGY_SOLID := [?]i64{335, 670, 1005, 1340, 1675, 2010, 2345, 2680, 3015, 3350}

@(private = "file")
ENERGY_DRINK := [?]i64{0, 30, 60, 90, 120, 150, 180, 210, 240, 270}

@(private = "file")
SUGARS_SOLID := [?]i64{4500, 9000, 13500, 18000, 22500, 27000, 31000, 36000, 40000, 45000}

@(private = "file")
SUGARS_DRINK := [?]i64{0, 1500, 3000, 4500, 6000, 7500, 9000, 10500, 12000, 13500}

@(private = "file")
SATFAT := [?]i64{1000, 2000, 3000, 4000, 5000, 6000, 7000, 8000, 9000, 10000}

@(private = "file")
SODIUM := [?]i64{90, 180, 270, 360, 450, 540, 630, 720, 810, 900}

@(private = "file")
FIBRE := [?]i64{900, 1900, 2800, 3700, 4700}

@(private = "file")
PROTEIN := [?]i64{1600, 3200, 4800, 6400, 8000}

// satfat_ratio_points is the added-fats component: saturated fat as a share of
// total fat, in tenths of a percent, scored on strict inequalities exactly as
// the published table writes them (< 10 %, < 16 %, … , >= 64 %).
@(private = "file")
satfat_ratio_points :: proc(satfat_mg, total_fat_mg: i64) -> int {
	if total_fat_mg <= 0 {
		return 0
	}
	r := satfat_mg * 1000 / total_fat_mg // tenths of a percent
	bounds := [?]i64{100, 160, 220, 280, 340, 400, 460, 520, 580, 640}
	for b, i in bounds {
		if r < b {
			return i
		}
	}
	return 10
}

// fruit_points: the solid table tops out at 5 and skips 3 and 4; the beverage
// table tops out at 10 and steps in twos.
@(private = "file")
fruit_points :: proc(pct: i64, drink: bool) -> int {
	if drink {
		switch {
		case pct <= 40:
			return 0
		case pct <= 60:
			return 2
		case pct <= 80:
			return 4
		}
		return 10
	}
	switch {
	case pct <= 40:
		return 0
	case pct <= 60:
		return 1
	case pct <= 80:
		return 2
	}
	return 5
}

// nutri_score computes the grade and keeps every intermediate point count, so
// the detail panel can show the working and the self-test can assert it.
nutri_score :: proc(n: Nutrition) -> Nutri_Result {
	r: Nutri_Result
	if !n.known {
		return r
	}
	// Water is graded A by the regulation itself, without a calculation.
	if n.class == .Water {
		r.grade = .A
		return r
	}

	drink := n.class == .Beverage

	r.pts_energy = points_le(n.energy_kj, drink ? ENERGY_DRINK[:] : ENERGY_SOLID[:])
	r.pts_sugars = points_le(n.sugars_mg, drink ? SUGARS_DRINK[:] : SUGARS_SOLID[:])
	if n.class == .Added_Fat {
		r.pts_satfat = satfat_ratio_points(n.satfat_mg, n.total_fat_mg)
	} else {
		r.pts_satfat = points_le(n.satfat_mg, SATFAT[:])
	}
	r.pts_sodium = points_le(n.sodium_mg, SODIUM[:])
	r.negative = r.pts_energy + r.pts_sugars + r.pts_satfat + r.pts_sodium

	r.pts_fruit = fruit_points(n.fruit_pct, drink)
	r.pts_fibre = points_le(n.fibre_mg, FIBRE[:])
	r.pts_protein = points_le(n.protein_mg, PROTEIN[:])

	// The protein rule. Below 11 negative points everything counts. At 11 or
	// more the protein points are withheld, unless the fruit/vegetable points
	// are at their maximum for this table, or the food is a cheese.
	max_fruit := drink ? 10 : 5
	r.protein_counted = r.negative < 11 || r.pts_fruit >= max_fruit || n.class == .Cheese

	r.positive = r.pts_fruit + r.pts_fibre
	if r.protein_counted {
		r.positive += r.pts_protein
	}
	r.score = r.negative - r.positive

	if drink {
		switch {
		case r.score <= 1:
			r.grade = .B // a drink that is not water cannot reach A
		case r.score <= 5:
			r.grade = .C
		case r.score <= 9:
			r.grade = .D
		case:
			r.grade = .E
		}
		return r
	}
	switch {
	case r.score <= -1:
		r.grade = .A
	case r.score <= 2:
		r.grade = .B
	case r.score <= 10:
		r.grade = .C
	case r.score <= 18:
		r.grade = .D
	case:
		r.grade = .E
	}
	return r
}

// nutri_from_letter reads the grade a feed states directly, for the case where
// a retailer publishes the letter but not the nutrition table behind it.
nutri_from_letter :: proc(s: string) -> Nutri {
	if len(s) == 0 {
		return .None
	}
	c := s[0]
	if c >= 'a' && c <= 'z' {
		c -= 32
	}
	switch c {
	case 'A':
		return .A
	case 'B':
		return .B
	case 'C':
		return .C
	case 'D':
		return .D
	case 'E':
		return .E
	}
	return .None
}
