package main

// The generator: a synthetic city, written out as GeoJSON.
//
// There is no map data on this machine and no network, so the app brings its
// own. That is not a consolation prize. Real data gives you no ground truth —
// you cannot assert the shortest path between two junctions in Berlin without
// computing it with the thing you are trying to test. A city you generated you
// know exactly, so the self-test can assert the *value*, not merely that a
// route was found.
//
// The structure, all of it deterministic from a fixed seed:
//
//   - an arterial grid, GRID_STEP metres apart, complete over the extent.
//     Between any two junctions of this grid on the same side of the river the
//     shortest path is the Manhattan staircase, and the self-test asserts the
//     exact cost against an independent sum of the same edges.
//   - winding residential streets inside each block (sinusoidal, so they are
//     strictly longer than the arterials and can never be a short cut).
//   - a river wandering north to south, with bridges at every second
//     east-west arterial. The arterials without a bridge are emitted as two
//     LineStrings with a gap, so the river really does break the graph.
//   - parks, one of them with a lake as a hole in the polygon; forest, grass,
//     a beach, residential and industrial landuse.
//   - a coastline and the sea to the east.
//   - a few hundred buildings, most of them named.
//   - place points: the city, its suburbs, outlying villages, and POIs.
//   - one railway line.
//
// Everything is laid out on a local tangent plane in metres and converted to
// lon/lat at the end, so the grid spacing means what it says.

import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"

// The city sits at an invented location in the Mediterranean, far from any
// real settlement, so nobody can mistake the file for an extract.
CITY_LON :: 7.4500
CITY_LAT :: 45.0000
CITY_NAME :: "Marisport"

MET_PER_DEG_LAT :: 111320.0

// The arterial grid. Both the generator and the self-test read these.
GRID_STEP :: 500.0
GRID_X0 :: -4000.0
GRID_X1 :: 4000.0
GRID_Y0 :: -3000.0
GRID_Y1 :: 3000.0
GRID_NX :: int((GRID_X1 - GRID_X0) / GRID_STEP) + 1 // 17
GRID_NY :: int((GRID_Y1 - GRID_Y0) / GRID_STEP) + 1 // 13

// The river's mean x position, and how far it wanders. The two together keep
// it strictly between the arterial columns at x = -1500 and x = -1000 and
// never on one, which matters for more than looks: an arterial whose vertices
// land in the water would be a bridge nobody built, and the whole river part
// of the routing test rests on the grid being broken exactly where the bridges
// are not.
RIVER_X :: -1250.0
RIVER_WANDER :: 150.0
RIVER_HALF_W :: 34.0
// An east-west arterial has a bridge when its row index is even.
bridge_row :: proc(j: int) -> bool {return j % 2 == 0}

// The coast. Everything east of this is sea, so the grid's two easternmost
// columns are over water and are not generated.
COAST_X :: 3400.0

// Rng is a 64-bit xorshift. A fixed seed means the city, the names, the
// building footprints and therefore every assertion are identical on every
// machine and every run.
Rng :: struct {
	s: u64,
}

rng_make :: proc(seed: u64) -> Rng {
	return {s = seed | 1}
}

rng_next :: proc(r: ^Rng) -> u64 {
	x := r.s
	x ~= x << 13
	x ~= x >> 7
	x ~= x << 17
	r.s = x
	return x
}

// rng_f returns a float in [0,1).
rng_f :: proc(r: ^Rng) -> f64 {
	return f64(rng_next(r) >> 11) / f64(u64(1) << 53)
}

rng_range :: proc(r: ^Rng, lo, hi: f64) -> f64 {
	return lo + (hi - lo) * rng_f(r)
}

rng_int :: proc(r: ^Rng, n: int) -> int {
	if n <= 0 {
		return 0
	}
	return int(rng_next(r) % u64(n))
}

// ---------------------------------------------------------------------------
// Local metres to lon/lat
// ---------------------------------------------------------------------------

// The latitude scale is taken at the city centre and held constant, so a
// GRID_STEP step in x is the same number of degrees everywhere in the city.
// Without that the grid would not be a grid: a degree of longitude shrinks
// with latitude, and the self-test's exact costs would drift by the width of
// the extent.
met_to_lonlat :: proc(x, y: f64) -> (lon, lat: f64) {
	lat = CITY_LAT + y / MET_PER_DEG_LAT
	lon = CITY_LON + x / (MET_PER_DEG_LAT * math.cos(CITY_LAT * math.PI / 180))
	return
}

// river_x is the river's centre line at a given northing.
river_x :: proc(y: f64) -> f64 {
	t := y / 1400
	return RIVER_X + RIVER_WANDER * math.sin(t) + 0.35 * RIVER_WANDER * math.sin(2.7 * t + 0.6)
}

// coast_x is the shoreline at a given northing.
coast_x :: proc(y: f64) -> f64 {
	return COAST_X + 150 * math.sin(y / 900) + 60 * math.cos(y / 380 + 1.1)
}

// ---------------------------------------------------------------------------
// Name tables. Deterministic, and chosen so the search test has exact targets.
// ---------------------------------------------------------------------------

STREET_HEADS := [?]string {
	"Harbour", "Mariner", "Lantern", "Quarry", "Juniper", "Ashgrove", "Kestrel",
	"Saltmarsh", "Clement", "Beacon", "Verity", "Oldmill", "Tanner", "Copperfield",
	"Hollow", "Marigold", "Pellam", "Thistle", "Windward", "Orchard", "Granite",
	"Fernway", "Alder", "Bramble", "Cinder", "Dovecote", "Elmshaw", "Foxglove",
	"Gatehouse", "Hazelmere", "Ivybridge", "Jessamine", "Kilnwood", "Lamplight",
	"Mulberry", "Northgate", "Oakhanger", "Primrose", "Quillon", "Ravensmoor",
	"Sparrow", "Tidewater", "Underhill", "Vantage", "Wheelwright", "Yarrow",
}

ARTERIAL_TAILS := [?]string{"Avenue", "Boulevard", "Parkway", "Highway"}
STREET_TAILS := [?]string{"Street", "Lane", "Road", "Row", "Walk", "Close", "Mews", "Crescent"}

BUILDING_HEADS := [?]string {
	"Admiralty", "Beaufort", "Carrick", "Dunmore", "Eastgate", "Fairholm",
	"Glenmara", "Holloway", "Inchcape", "Jerrold", "Kenmare", "Larkspur",
	"Montrose", "Netherby", "Ossian", "Pentland", "Quintrell", "Rosemount",
	"Selwyn", "Thorncliffe", "Ullswater", "Vexford", "Wrenfield", "Yester",
}
BUILDING_TAILS := [?]string {
	"House", "Hall", "Works", "Court", "Chambers", "Exchange", "Terrace",
	"Mill", "Depot", "Lodge", "Arcade", "Granary",
}

SUBURB_NAMES := [?]string {
	"Saltonbridge", "Netherfold", "Kirkmoor", "Highcombe", "Eastmere",
	"Wharfside", "Lowgate", "Stonecross",
}
VILLAGE_NAMES := [?]string{"Pendrick", "Ashcott", "Brinmouth", "Caldwell"}
PARK_NAMES := [?]string {
	"Jubilee Gardens", "Queensmere Park", "Harbourfield Common",
	"Silvermoor Park", "Caldecote Green", "Lanterncroft Park",
}
POI_NAMES := [?]string {
	"Marisport Central Station", "Saint Oswin's Hospital",
	"Marisport Maritime Museum", "Corn Exchange", "Old Customs House",
	"City Library", "Marisport University", "Westgate Market",
	"Lighthouse Point", "Observatory Hill",
}

// ---------------------------------------------------------------------------
// The generator
// ---------------------------------------------------------------------------

// generate_city fills a Map with the whole city. It is called both by the
// self-test and, once, to write the file the app loads.
generate_city :: proc(m: ^Map, seed: u64 = 0x5EED_C17A) {
	b: Builder
	builder_init(&b, m)
	defer builder_destroy(&b)
	r := rng_make(seed)

	gen_sea(&b)
	gen_landuse(&b, &r)
	gen_parks(&b, &r)
	gen_river(&b)
	gen_arterials(&b)
	gen_residential(&b, &r)
	gen_rail(&b)
	gen_buildings(&b, &r)
	gen_places(&b, &r)

	builder_finish(&b)
	delete(m.source)
	m.source = strings.clone("generated")
}

// gen_sea lays down the sea and the beach along the coast.
@(private = "file")
gen_sea :: proc(b: ^Builder) {
	// The sea: the shoreline, then out past the extent.
	begin_feature(b, .Polygon, .Ocean, "Gulf of Marisport", "")
	begin_ring(b)
	for y := GRID_Y0 - 900; y <= GRID_Y1 + 900; y += 100 {
		add_met(b, coast_x(y), y)
	}
	add_met(b, GRID_X1 + 2400, GRID_Y1 + 900)
	add_met(b, GRID_X1 + 2400, GRID_Y0 - 900)
	end_feature(b)

	// A beach strip just inland of it.
	begin_feature(b, .Polygon, .Sand, "Longsands", "")
	begin_ring(b)
	for y := GRID_Y0 - 400; y <= GRID_Y1 + 400; y += 100 {
		add_met(b, coast_x(y), y)
	}
	for y := GRID_Y1 + 400; y >= GRID_Y0 - 400; y -= 100 {
		add_met(b, coast_x(y) - 70, y)
	}
	end_feature(b)
}

// gen_landuse covers the blocks with residential, industrial and forest, so
// the map is not white between the roads.
@(private = "file")
gen_landuse :: proc(b: ^Builder, r: ^Rng) {
	// Residential over most of the grid, as one block per 4x4 arterial cells
	// with a slightly irregular edge.
	for bi in 0 ..< 4 {
		for bj in 0 ..< 3 {
			x0 := GRID_X0 + f64(bi) * 2000
			y0 := GRID_Y0 + f64(bj) * 2000
			x1 := math.min(x0 + 2000, GRID_X1)
			y1 := math.min(y0 + 2000, GRID_Y1)
			if x0 > coast_x(y0) - 200 {
				continue
			}
			cls := Class.Landuse
			name := ""
			// Industry by the river mouth, forest in the north west.
			if bi == 0 && bj == 2 {
				cls = .Forest
				name = "Netherfold Wood"
			} else if bi == 3 && bj == 0 {
				cls = .Landuse
				name = "Harbour Industrial Estate"
			}
			begin_feature(b, .Polygon, cls, name, "")
			begin_ring(b)
			jitter := 28.0
			for x := x0; x <= x1; x += 250 {
				add_met(b, math.min(x, coast_x(y0) - 120), y0 + rng_range(r, -jitter, jitter))
			}
			for y := y0; y <= y1; y += 250 {
				add_met(b, math.min(x1, coast_x(y) - 120) + rng_range(r, -jitter, jitter), y)
			}
			for x := x1; x >= x0; x -= 250 {
				add_met(b, math.min(x, coast_x(y1) - 120), y1 + rng_range(r, -jitter, jitter))
			}
			for y := y1; y >= y0; y -= 250 {
				add_met(b, x0 + rng_range(r, -jitter, jitter), y)
			}
			end_feature(b)
		}
	}

	// Grass verges along the river, which is what makes the river read as a
	// river rather than a blue line across a city.
	for side in 0 ..< 2 {
		begin_feature(b, .Polygon, .Grass, side == 0 ? "Westbank Meadows" : "Eastbank Meadows", "")
		begin_ring(b)
		off := side == 0 ? -1.0 : 1.0
		for y := GRID_Y0; y <= GRID_Y1; y += 120 {
			add_met(b, river_x(y) + off * RIVER_HALF_W, y)
		}
		for y := GRID_Y1; y >= GRID_Y0; y -= 120 {
			add_met(b, river_x(y) + off * (RIVER_HALF_W + 95), y)
		}
		end_feature(b)
	}
}

// gen_parks places parks on whole arterial blocks. One of them has a lake,
// which is a hole in the park polygon with a water polygon inside it — the
// case a scanline fill gets wrong if its winding rule is wrong.
@(private = "file")
gen_parks :: proc(b: ^Builder, r: ^Rng) {
	// Block corners chosen by hand so no park sits on the river.
	spots := [?][2]int{{2, 7}, {6, 3}, {10, 8}, {13, 5}, {4, 1}, {8, 10}}
	for s, k in spots {
		x0 := GRID_X0 + f64(s[0]) * GRID_STEP + 40
		y0 := GRID_Y0 + f64(s[1]) * GRID_STEP + 40
		x1 := x0 + GRID_STEP - 80
		y1 := y0 + GRID_STEP - 80
		name := PARK_NAMES[k % len(PARK_NAMES)]
		cls := k == 1 ? Class.Forest : Class.Park

		begin_feature(b, .Polygon, cls, name, "")
		// Outer ring, counter-clockwise in lon/lat (RFC 7946's preference,
		// though this renderer does not depend on the winding direction).
		begin_ring(b)
		add_met(b, x0, y0)
		add_met(b, x1, y0)
		add_met(b, x1, y1)
		add_met(b, x0, y1)

		if k == 0 {
			// The lake, as a hole. Clockwise, the opposite of the outer ring,
			// which is what a nonzero-winding fill needs to cut it out.
			cx, cy := (x0 + x1) / 2, (y0 + y1) / 2
			rad := (GRID_STEP - 80) * 0.26
			begin_ring(b, true)
			for i := 0; i < 24; i += 1 {
				a := -f64(i) / 24 * 2 * math.PI
				add_met(b, cx + rad * math.cos(a), cy + rad * math.sin(a) * 0.72)
			}
		}
		end_feature(b)

		if k == 0 {
			// And the water that shows through the hole.
			cx, cy := (x0 + x1) / 2, (y0 + y1) / 2
			rad := (GRID_STEP - 80) * 0.26
			begin_feature(b, .Polygon, .Water, "Jubilee Lake", "")
			begin_ring(b)
			for i := 0; i < 24; i += 1 {
				a := f64(i) / 24 * 2 * math.PI
				add_met(b, cx + rad * math.cos(a), cy + rad * math.sin(a) * 0.72)
			}
			end_feature(b)
		}

		// A sports pitch in a corner of two of them.
		if k == 2 || k == 4 {
			begin_feature(b, .Polygon, .Pitch, "", "")
			begin_ring(b)
			px := x0 + 30
			py := y0 + 30
			add_met(b, px, py)
			add_met(b, px + 105, py)
			add_met(b, px + 105, py + 68)
			add_met(b, px, py + 68)
			end_feature(b)
		}
		_ = r
	}

	// A wetland in the river's flood plain.
	begin_feature(b, .Polygon, .Wetland, "Saltmarsh Flats", "")
	begin_ring(b)
	for y := -600.0; y <= 400; y += 80 {
		add_met(b, river_x(y) - RIVER_HALF_W - 60, y)
	}
	for y := 400.0; y >= -600; y -= 80 {
		add_met(b, river_x(y) - RIVER_HALF_W - 230, y)
	}
	end_feature(b)
}

// gen_river emits the river twice: once as a water polygon with real width,
// and once as a line, which is what carries the name along its course.
@(private = "file")
gen_river :: proc(b: ^Builder) {
	begin_feature(b, .Polygon, .Water, "River Mare", "")
	begin_ring(b)
	for y := GRID_Y0 - 600; y <= GRID_Y1 + 600; y += 60 {
		add_met(b, river_x(y) - RIVER_HALF_W, y)
	}
	for y := GRID_Y1 + 600; y >= GRID_Y0 - 600; y -= 60 {
		add_met(b, river_x(y) + RIVER_HALF_W, y)
	}
	end_feature(b)

	begin_feature(b, .Line, .River, "River Mare", "")
	begin_ring(b)
	for y := GRID_Y0 - 600; y <= GRID_Y1 + 600; y += 60 {
		add_met(b, river_x(y), y)
	}
	end_feature(b)
}

// gen_arterials lays the grid. This is the part the routing assertions depend
// on, so it is deliberately plain: straight lines, exact spacing, one vertex
// at every crossing so the graph builder joins them without any tolerance.
@(private = "file")
gen_arterials :: proc(b: ^Builder) {
	// North-south. Columns whose whole length is out at sea are skipped.
	for i in 0 ..< GRID_NX {
		x := GRID_X0 + f64(i) * GRID_STEP
		if x > coast_x(0) {
			continue
		}
		cls := arterial_class(i)
		name := arterial_name(i, true)
		begin_feature(b, .Line, cls, name, arterial_ref(i, true))
		begin_ring(b)
		for j in 0 ..< GRID_NY {
			y := GRID_Y0 + f64(j) * GRID_STEP
			add_met(b, x, y)
		}
		end_feature(b)
	}

	// East-west. The ones without a bridge are split at the river.
	for j in 0 ..< GRID_NY {
		y := GRID_Y0 + f64(j) * GRID_STEP
		cls := arterial_class(j + 3)
		name := arterial_name(j, false)
		ref := arterial_ref(j, false)
		east_end := GRID_NX - 1
		for east_end > 0 && GRID_X0 + f64(east_end) * GRID_STEP > coast_x(y) {
			east_end -= 1
		}

		if bridge_row(j) {
			begin_feature(b, .Line, cls, name, ref)
			begin_ring(b)
			for i in 0 ..= east_end {
				add_met(b, GRID_X0 + f64(i) * GRID_STEP, y)
			}
			end_feature(b)
			continue
		}

		// No bridge: two carriageways with a gap over the water. The gap runs
		// between the arterial columns either side of the river, so the
		// western grid is only reachable from the eastern one via a bridge
		// row. The self-test relies on exactly this.
		rx := river_x(y)
		split := 0
		for split < GRID_NX - 1 && GRID_X0 + f64(split + 1) * GRID_STEP < rx {
			split += 1
		}
		begin_feature(b, .Line, cls, name, ref)
		begin_ring(b)
		for i in 0 ..= split {
			add_met(b, GRID_X0 + f64(i) * GRID_STEP, y)
		}
		end_feature(b)

		begin_feature(b, .Line, cls, name, ref)
		begin_ring(b)
		for i in split + 1 ..= east_end {
			add_met(b, GRID_X0 + f64(i) * GRID_STEP, y)
		}
		end_feature(b)
	}
}

// arterial_class makes the grid a hierarchy rather than 30 identical lines.
// Every fourth line is primary, every second of the rest secondary.
@(private = "file")
arterial_class :: proc(i: int) -> Class {
	switch {
	case i % 8 == 0:
		return .Trunk
	case i % 4 == 0:
		return .Primary
	case i % 2 == 0:
		return .Secondary
	}
	return .Tertiary
}

@(private = "file")
arterial_name :: proc(i: int, north_south: bool) -> string {
	head := STREET_HEADS[(i * (north_south ? 3 : 5) + (north_south ? 0 : 7)) % len(STREET_HEADS)]
	tail := ARTERIAL_TAILS[(i + (north_south ? 0 : 2)) % len(ARTERIAL_TAILS)]
	return fmt.tprintf("%s %s", head, tail)
}

@(private = "file")
arterial_ref :: proc(i: int, north_south: bool) -> string {
	if i % 4 != 0 {
		return ""
	}
	return fmt.tprintf("%s%d", north_south ? "A" : "B", 10 + i)
}

// gen_residential fills each arterial block with two winding streets each way.
// The wiggle is a sine of the along-street coordinate: it makes the street
// strictly longer than a straight line between the same ends, which is what
// keeps the arterial grid optimal and the routing assertions exact.
@(private = "file")
gen_residential :: proc(b: ^Builder, r: ^Rng) {
	n := 0
	for i in 0 ..< GRID_NX - 1 {
		for j in 0 ..< GRID_NY - 1 {
			bx := GRID_X0 + f64(i) * GRID_STEP
			by := GRID_Y0 + f64(j) * GRID_STEP
			if bx + GRID_STEP > coast_x(by) {
				continue
			}
			// Skip the block the river runs through: a residential street
			// across it would be a free bridge.
			rx0 := river_x(by)
			rx1 := river_x(by + GRID_STEP)
			crosses := (rx0 > bx && rx0 < bx + GRID_STEP) || (rx1 > bx && rx1 < bx + GRID_STEP)

			// Where the two north-south streets cross the middle of the block,
			// so the service alley below can be hung off them rather than
			// floating in the block as a pair of nodes with no way out.
			cross_x: [2]f64
			for k in 1 ..< 3 {
				if crosses {
					break
				}
				// A north-south street.
				//
				// The wiggle is `sin(3*pi*t)`, which is zero at t = 0, 1/3,
				// 2/3 and 1. That is not decoration: it puts a vertex exactly
				// on the street's nominal line at the two places the block's
				// east-west streets cross it, so the two really do share a
				// node and the block is a network rather than four lines
				// lying on top of each other. A graph built from shared
				// vertices only joins what the data actually joins.
				x := bx + f64(k) * GRID_STEP / 3
				amp := rng_range(r, 6, 16)
				cross_x[k - 1] = x + amp * math.sin(1.5 * math.PI)
				name := fmt.tprintf(
					"%s %s",
					STREET_HEADS[(n * 7 + 3) % len(STREET_HEADS)],
					STREET_TAILS[n % len(STREET_TAILS)],
				)
				n += 1
				begin_feature(b, .Line, .Residential_Road, name, "")
				begin_ring(b)
				// A stub along the arterial to the junction at the corner of
				// the block, so the street is reachable from the grid. Without
				// it every residential street in the city is an island: its
				// ends sit *on* an arterial but not on one of its vertices,
				// and nothing shares a node with it.
				add_met(b, bx, by)
				for j in 0 ..= 6 {
					t := f64(j) / 6
					add_met(b, x + amp * math.sin(3 * math.PI * t), by + t * GRID_STEP)
				}
				add_met(b, bx, by + GRID_STEP)
				end_feature(b)

				// An east-west one, built the same way.
				y := by + f64(k) * GRID_STEP / 3
				amp2 := rng_range(r, 6, 16)
				name2 := fmt.tprintf(
					"%s %s",
					STREET_HEADS[(n * 11 + 5) % len(STREET_HEADS)],
					STREET_TAILS[(n + 3) % len(STREET_TAILS)],
				)
				n += 1
				begin_feature(b, .Line, .Residential_Road, name2, "")
				begin_ring(b)
				add_met(b, bx, by)
				for j in 0 ..= 6 {
					t := f64(j) / 6
					add_met(b, bx + t * GRID_STEP, y + amp2 * math.sin(3 * math.PI * t))
				}
				add_met(b, bx + GRID_STEP, by)
				end_feature(b)
			}

			// A one-way service alley through the middle of every third
			// block, so the graph has directed edges to honour.
			if (i + j) % 3 == 0 && !crosses {
				begin_feature(
					b,
					.Line,
					.Service,
					fmt.tprintf("%s Yard", STREET_HEADS[(i * 5 + j) % len(STREET_HEADS)]),
					"",
				)
				begin_ring(b)
				// Through the two residential streets' own mid-block
				// vertices, so the alley is part of the network instead of an
				// island. The vertices are shared exactly, which is what the
				// graph builder joins on.
				add_met(b, bx + 60, by + GRID_STEP / 2)
				add_met(b, cross_x[0], by + GRID_STEP / 2)
				add_met(b, cross_x[1], by + GRID_STEP / 2)
				add_met(b, bx + GRID_STEP - 60, by + GRID_STEP / 2)
				end_feature(b)
				b.m.features[len(b.m.features) - 1].oneway = 1
			}

			// A footpath into the block, which routing may use at walking pace.
			if (i * 3 + j) % 5 == 0 && !crosses {
				begin_feature(b, .Line, .Path, "", "")
				begin_ring(b)
				add_met(b, bx, by)
				add_met(b, bx + GRID_STEP / 3, by + GRID_STEP / 3)
				end_feature(b)
			}
		}
	}
}

@(private = "file")
gen_rail :: proc(b: ^Builder) {
	begin_feature(b, .Line, .Rail, "Marisport Coast Line", "")
	begin_ring(b)
	for x := GRID_X0 - 600.0; x <= COAST_X - 200; x += 120 {
		add_met(b, x, 240 + 160 * math.sin(x / 1700))
	}
	end_feature(b)
}

// gen_buildings puts footprints along the residential streets. Most are
// anonymous, which is how real data looks; a named minority is what the search
// and the label collision test work on.
@(private = "file")
gen_buildings :: proc(b: ^Builder, r: ^Rng) {
	named := 0
	for i in 0 ..< GRID_NX - 1 {
		for j in 0 ..< GRID_NY - 1 {
			bx := GRID_X0 + f64(i) * GRID_STEP
			by := GRID_Y0 + f64(j) * GRID_STEP
			if bx + GRID_STEP > coast_x(by) {
				continue
			}
			rx := river_x(by + GRID_STEP / 2)
			if rx > bx - 60 && rx < bx + GRID_STEP + 60 {
				continue
			}
			// Three rows of four, set back from the street edges.
			for rowi in 0 ..< 3 {
				for coli in 0 ..< 4 {
					if rng_f(r) < 0.28 {
						continue
					}
					w := rng_range(r, 16, 34)
					h := rng_range(r, 14, 28)
					cx := bx + 70 + f64(coli) * 110 + rng_range(r, -12, 12)
					cy := by + 90 + f64(rowi) * 150 + rng_range(r, -14, 14)
					rot := rng_range(r, -0.09, 0.09)

					name := ""
					if named < 160 && rng_f(r) < 0.19 {
						name = fmt.tprintf(
							"%s %s",
							BUILDING_HEADS[named % len(BUILDING_HEADS)],
							BUILDING_TAILS[(named / len(BUILDING_HEADS) + named * 3) %
							len(BUILDING_TAILS)],
						)
						named += 1
					}
					begin_feature(b, .Polygon, .Building, name, "")
					begin_ring(b)
					cs, sn := math.cos(rot), math.sin(rot)
					corners := [4][2]f64{{-w / 2, -h / 2}, {w / 2, -h / 2}, {w / 2, h / 2}, {-w / 2, h / 2}}
					for c in corners {
						add_met(b, cx + c.x * cs - c.y * sn, cy + c.x * sn + c.y * cs)
					}
					end_feature(b)
				}
			}
		}
	}
}

@(private = "file")
gen_places :: proc(b: ^Builder, r: ^Rng) {
	point :: proc(b: ^Builder, cls: Class, name: string, x, y: f64) {
		begin_feature(b, .Point, cls, name, "")
		begin_ring(b)
		add_met(b, x, y)
		end_feature(b)
	}

	point(b, .City, CITY_NAME, 0, 0)

	spots := [?][2]f64 {
		{-2600, 1700}, {1900, 1500}, {-2200, -1800}, {2300, -1600},
		{400, 2300}, {-3400, -200}, {2700, 400}, {-700, -2400},
	}
	for s, k in spots {
		point(b, .Suburb, SUBURB_NAMES[k % len(SUBURB_NAMES)], s[0], s[1])
	}

	vill := [?][2]f64{{-3900, 2700}, {3000, 2700}, {-3800, -2800}, {1200, -2900}}
	for s, k in vill {
		point(b, .Village, VILLAGE_NAMES[k % len(VILLAGE_NAMES)], s[0], s[1])
	}

	for name, k in POI_NAMES {
		a := f64(k) / f64(len(POI_NAMES)) * 2 * math.PI
		rad := 900 + 700 * rng_f(r)
		point(b, .Poi, name, math.cos(a) * rad, math.sin(a) * rad * 0.8)
	}
}

@(private = "file")
add_met :: proc(b: ^Builder, x, y: f64) {
	lon, lat := met_to_lonlat(x, y)
	add_point(b, lon, lat)
}

// ---------------------------------------------------------------------------
// Where the data lives
// ---------------------------------------------------------------------------

// data_dir is the only directory this program writes to.
data_dir :: proc(allocator := context.temp_allocator) -> string {
	if d := os.get_env("XDG_DATA_HOME", context.temp_allocator); d != "" {
		return fmt.aprintf("%s/palmy-maps", d, allocator = allocator)
	}
	home := os.get_env("HOME", context.temp_allocator)
	return fmt.aprintf("%s/.local/share/palmy-maps", home, allocator = allocator)
}

default_city_path :: proc(allocator := context.temp_allocator) -> string {
	return fmt.aprintf("%s/city.geojson", data_dir(context.temp_allocator), allocator = allocator)
}

// ensure_city writes the generated city if it is not there yet, and returns
// the path. Regenerating is cheap but writing eight megabytes on every launch
// is not, and a user who has edited the file should keep their edit.
ensure_city :: proc(force := false) -> (path: string, made: bool, err: string) {
	dir := data_dir(context.temp_allocator)
	if merr := os.make_directory(dir); merr != nil && merr != os.General_Error.Exist {
		// A pre-existing directory reports differently on different kernels,
		// so check rather than trust the error.
		if !os.is_dir(dir) {
			return "", false, fmt.tprintf("cannot create %s", dir)
		}
	}
	p := default_city_path(context.temp_allocator)
	if !force && os.is_file(p) {
		return strings.clone(p), false, ""
	}
	m: Map
	map_init(&m)
	defer map_destroy(&m)
	generate_city(&m)
	if !write_geojson(&m, p) {
		return "", false, fmt.tprintf("cannot write %s", p)
	}
	return strings.clone(p), true, ""
}
