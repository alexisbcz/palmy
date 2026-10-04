package main

// `maps --selftest` — everything in this program that is not a picture.
//
// The shape of the file follows the shape of the risk. The projection is pure
// arithmetic with published reference values, so it is checked against those
// values and not against itself. The polygon filler is checked by counting
// pixels, including the two cases a winding rule gets wrong: a hole, and a ring
// that overlaps itself. The GeoJSON reader is checked against documents that
// are *wrong*, because that is what a file a user drops in will be. Routing is
// checked against a graph whose shortest paths are known analytically, and then
// against the generated city's arterial grid, where the shortest path is the
// Manhattan staircase and the node sequence can be written down in advance.
//
// Where a float comparison would be fragile, the assertion is structural
// instead: the exact sequence of nodes a route visits, rather than its cost to
// seventeen digits.

import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"
import p "palmy:."
import sc "shadcn:."

checks := 0
failures := 0

check :: proc(ok: bool, what: string, args: ..any) {
	checks += 1
	if ok {
		return
	}
	failures += 1
	msg := fmt.tprintf(what, ..args)
	fmt.printf("  FAIL  %s\n", msg)
}

near :: proc(a, b, tol: f64, what: string, args: ..any) {
	checks += 1
	if abs(a - b) <= tol {
		return
	}
	failures += 1
	fmt.printf("  FAIL  %s: %.12g vs %.12g (tol %.3g)\n", fmt.tprintf(what, ..args), a, b, tol)
}

rel :: proc(a, b, tol: f64, what: string, args: ..any) {
	checks += 1
	d := abs(a - b) / math.max(abs(b), 1e-30)
	if d <= tol {
		return
	}
	failures += 1
	fmt.printf(
		"  FAIL  %s: %.12g vs %.12g (relative %.3g > %.3g)\n",
		fmt.tprintf(what, ..args),
		a,
		b,
		d,
		tol,
	)
}

selftest :: proc() -> int {
	fmt.println("maps selftest")
	test_projection()
	test_distance()
	test_raster()
	test_clip()
	test_geojson()
	test_geojson_malformed()
	test_osm_xml()
	test_generator()
	test_roundtrip()
	test_graph()
	test_routing_analytic()
	test_routing_city()
	test_routing_degenerate()
	test_directions()
	test_search()
	test_labels()
	test_interaction()
	test_format()

	fmt.printf("\n%d assertions, %d failures\n", checks, failures)
	return failures == 0 ? 0 : 1
}

// ---------------------------------------------------------------------------
// Projection
// ---------------------------------------------------------------------------

test_projection :: proc() {
	fmt.println("- web mercator and the tile scheme")

	// The Mercator limit. The published value is 180/pi * atan(sinh(pi)); the
	// tile scheme is defined by it, so it has to be exact rather than close.
	want_lat := 180 / math.PI * math.atan(math.sinh(math.PI))
	near(MAX_LAT, want_lat, 1e-10, "MAX_LAT is atan(sinh(pi))")

	// The three corners of the world square.
	o := lonlat_to_world(0, 0)
	near(o.x, 0.5, 1e-15, "lon 0 is world x 0.5")
	near(o.y, 0.5, 1e-15, "lat 0 is world y 0.5")
	nw := lonlat_to_world(-180, MAX_LAT)
	near(nw.x, 0, 1e-15, "lon -180 is world x 0")
	near(nw.y, 0, 1e-12, "the Mercator limit is world y 0")
	se := lonlat_to_world(180, -MAX_LAT)
	near(se.x, 1, 1e-15, "lon +180 is world x 1")
	near(se.y, 1, 1e-12, "the southern limit is world y 1")

	// Past the limit the latitude clamps rather than diverging.
	a := lonlat_to_world(0, 89.9)
	b := lonlat_to_world(0, MAX_LAT)
	near(a.y, b.y, 1e-15, "latitude clamps at the Mercator limit")
	check(lonlat_to_world(0, 90).y == b.y, "lat 90 clamps too")
	check(lonlat_to_world(0, -90).y == lonlat_to_world(0, -MAX_LAT).y, "lat -90 clamps")

	// 2^z tiles per axis.
	for z in 0 ..= 20 {
		check(tiles_per_axis(z) == i64(1) << uint(z), "zoom %d has 2^%d tiles per axis", z, z)
	}

	// The canonical worked example from the OSM slippy-map tilenames page:
	// zoom 2, lat 41.85, lon -87.65 lands in tile (1, 1).
	tx, ty := lonlat_to_tile(-87.65, 41.85, 2)
	check(int(math.floor(tx)) == 1, "Chicago at z2 is tile x 1, got %v", tx)
	check(int(math.floor(ty)) == 1, "Chicago at z2 is tile y 1, got %v", ty)
	// The same point at zoom 0 is the only tile there is.
	t0x, t0y := lonlat_to_tile(-87.65, 41.85, 0)
	check(int(math.floor(t0x)) == 0 && int(math.floor(t0y)) == 0, "everything is tile 0/0 at zoom 0")
	// And against the published formula itself, written the other way round.
	// The OSM wiki states it with tan and sec of the latitude; this file
	// implements it with sin, because that form has no pole at 90 degrees. The
	// two agreeing to twelve digits is a real check and not a tautology.
	wiki_tile :: proc(lon, lat: f64, z: int) -> (x, y: f64) {
		n := f64(i64(1) << uint(z))
		rad := lat * math.PI / 180
		x = (lon + 180) / 360 * n
		y = (1 - math.ln(math.tan(rad) + 1 / math.cos(rad)) / math.PI) / 2 * n
		return
	}
	for q in ([?][2]f64 {
		{-87.65, 41.85}, {13.3777, 52.5163}, {151.2093, -33.8688},
		{-74.006, 40.7128}, {0, 0}, {7.45, 45},
	}) {
		for z in ([?]int{0, 2, 10, 16, 19}) {
			ax, ay := lonlat_to_tile(q[0], q[1], z)
			bx, by := wiki_tile(q[0], q[1], z)
			rel(ax, bx + 1e-30, 1e-12, "tile x against the published formula at z%d", z)
			near(ay, by, 1e-9 * f64(i64(1) << uint(z)), "tile y against the published formula at z%d", z)
		}
	}

	// The equator and prime meridian meet at the corner of four tiles at any
	// zoom above 0, so the fractional coordinate is exactly 2^(z-1).
	for z in 1 ..= 18 {
		fx, fy := lonlat_to_tile(0, 0, z)
		near(fx, f64(i64(1) << uint(z - 1)), 1e-9, "lon 0 at z%d", z)
		near(fy, f64(i64(1) << uint(z - 1)), 1e-9, "lat 0 at z%d", z)
	}

	// Round trip, lon/lat -> world -> lon/lat.
	pts := [?][2]f64 {
		{0, 0}, {13.3777, 52.5163}, {-74.006, 40.7128}, {151.2093, -33.8688},
		{-0.1276, 51.5072}, {139.6917, 35.6895}, {-58.3816, -34.6037},
		{179.999, 84.9}, {-179.999, -84.9}, {7.45, 45.0},
	}
	for q in pts {
		w := lonlat_to_world(q[0], q[1])
		lon, lat := world_to_lonlat(w)
		near(lon, q[0], 1e-11, "lon round trip at %v", q[0])
		near(lat, q[1], 1e-10, "lat round trip at %v", q[1])
		check(w.x >= 0 && w.x <= 1 && w.y >= 0 && w.y <= 1, "world coords stay in the unit square")
	}

	// Round trip through a tile coordinate at a high zoom.
	for q in pts {
		z := 14
		tx2, ty2 := lonlat_to_tile(q[0], q[1], z)
		lon, lat := tile_to_lonlat(tx2, ty2, z)
		near(lon, q[0], 1e-9, "lon tile round trip")
		near(lat, q[1], 1e-9, "lat tile round trip")
	}

	// Ground resolution. The published figure for a 256-pixel tile at the
	// equator and zoom 0 is 156543.03392804097 m/px.
	near(ground_resolution(0, 0), 156543.03392804097, 1e-6, "ground resolution at z0")
	for z in 1 ..= 20 {
		rel(
			ground_resolution(0, f64(z)),
			156543.03392804097 / f64(i64(1) << uint(z)),
			1e-12,
			"ground resolution halves at z%d",
			z,
		)
	}
	// And it scales by cos(latitude).
	rel(ground_resolution(60, 0), 156543.03392804097 * 0.5, 1e-9, "resolution at 60 degrees")
	rel(
		ground_resolution(45, 10),
		156543.03392804097 * math.cos(45 * math.PI / 180) / 1024,
		1e-12,
		"resolution at 45 degrees, z10",
	)

	// world_scale is 256 * 2^z, continuous in between.
	near(world_scale(0), 256, 1e-12, "world scale at z0")
	near(world_scale(10), 256 * 1024, 1e-9, "world scale at z10")
	near(world_scale(0.5), 256 * math.sqrt(2.0), 1e-9, "world scale is continuous")

	// The viewport.
	v := View {
		center = lonlat_to_world(7.45, 45),
		zoom   = 14,
		w      = 1200,
		h      = 800,
	}
	sc := world_to_screen(v, v.center)
	near(sc.x, 600, 1e-9, "the centre is the middle of the panel")
	near(sc.y, 400, 1e-9, "the centre is the middle of the panel")
	for q in ([?][2]f64{{10, 10}, {1190, 790}, {600, 400}, {0, 0}}) {
		w := screen_to_world(v, q[0], q[1])
		s2 := world_to_screen(v, w)
		near(s2.x, q[0], 1e-6, "screen round trip x")
		near(s2.y, q[1], 1e-6, "screen round trip y")
	}

	// A wheel zoom must keep the world point under the cursor fixed; that is
	// the whole contract of view_zoom_at and it is easy to get wrong by half a
	// panel.
	for anchor in ([?][2]f64{{300, 200}, {0, 0}, {1199, 799}, {600, 400}}) {
		v2 := v
		before := screen_to_world(v2, anchor[0], anchor[1])
		view_zoom_at(&v2, 1.37, anchor[0], anchor[1])
		after := screen_to_world(v2, anchor[0], anchor[1])
		near(after.x, before.x, 1e-12, "zoom keeps the anchor's x")
		near(after.y, before.y, 1e-12, "zoom keeps the anchor's y")
		near(v2.zoom, v.zoom + 1.37, 1e-12, "zoom is continuous, not stepped")
	}

	// view_fit shows the whole box.
	v3 := View{w = 900, h = 600}
	sw := lonlat_to_world(7.40, 44.96)
	ne := lonlat_to_world(7.50, 45.04)
	// A south-west / north-east pair has its world y the other way round, so
	// view_fit is handed both orders and must cope with each.
	for pair in ([?][2]World_Pt{{sw, ne}, {ne, sw}}) {
		view_fit(&v3, pair[0], pair[1])
		c0 := world_to_screen(v3, sw)
		c1 := world_to_screen(v3, ne)
		check(
			math.min(c0.x, c1.x) >= -0.01 &&
			math.max(c0.x, c1.x) <= 900.01 &&
			math.min(c0.y, c1.y) >= -0.01 &&
			math.max(c0.y, c1.y) <= 600.01,
			"view_fit puts the whole bounding box on screen (%v %v %v %v)",
			c0.x,
			c1.x,
			c0.y,
			c1.y,
		)
	}

	// The centre is clamped into the world square.
	v4 := View{center = {2, -3}, zoom = 5, w = 100, h = 100}
	view_clamp(&v4)
	check(v4.center.x == 1 && v4.center.y == 0, "the centre clamps into the world square")
}

test_distance :: proc() {
	fmt.println("- distance and bearing")

	// One degree of longitude at the equator is 2*pi*R/360.
	rel(haversine(0, 0, 1, 0), 2 * math.PI * EARTH_RADIUS / 360, 1e-12, "a degree of longitude at the equator")
	rel(haversine(0, 0, 0, 1), 2 * math.PI * EARTH_RADIUS / 360, 1e-12, "a degree of latitude")
	near(haversine(7.45, 45, 7.45, 45), 0, 1e-9, "a point is no distance from itself")
	rel(haversine(10, 20, 30, 40), haversine(30, 40, 10, 20), 1e-14, "distance is symmetric")
	// A degree of longitude at 60 degrees north: the great circle between the
	// two points is slightly *shorter* than the arc of the parallel through
	// them, which is cos(60) of a degree at the equator. That difference is
	// the point of using haversine rather than a flat approximation, so the
	// assertion is the inequality and its size, not an equality.
	{
		gc := haversine(0, 60, 1, 60)
		parallel := math.cos(60 * math.PI / 180) * 2 * math.PI * EARTH_RADIUS / 360
		check(gc < parallel, "a great circle is shorter than the parallel arc")
		rel(gc, parallel, 1e-4, "but only by a hair over one degree")
	}
	// Berlin to Paris is about 878 km, which is the figure every geodesy
	// library agrees on to a kilometre.
	d := haversine(13.4050, 52.5200, 2.3522, 48.8566) / 1000
	check(d > 875 && d < 882, "Berlin to Paris is about 878 km, got %.1f", d)

	// Bearings.
	near(bearing(0, 0, 0, 1), 0, 1e-9, "due north is 0")
	near(bearing(0, 0, 1, 0), 90, 1e-9, "due east is 90")
	near(bearing(0, 1, 0, 0), 180, 1e-9, "due south is 180")
	near(bearing(1, 0, 0, 0), 270, 1e-9, "due west is 270")

	near(angle_delta(10, 20), 10, 1e-12, "a small right turn")
	near(angle_delta(350, 10), 20, 1e-12, "a right turn across north")
	near(angle_delta(10, 350), -20, 1e-12, "a left turn across north")
	near(angle_delta(0, 180), 180, 1e-12, "a half turn is +180")
	near(angle_delta(180, 0), 180, 1e-12, "and so is the other way round")
	near(angle_delta(90, 270), 180, 1e-12, "east to west")

	check(classify_turn(0) == .Continue, "straight on")
	check(classify_turn(-10) == .Continue, "a ten degree bend is not a turn")
	check(classify_turn(-90) == .Left, "ninety degrees anticlockwise is left")
	check(classify_turn(90) == .Right, "ninety degrees clockwise is right")
	check(classify_turn(-40) == .Slight_Left, "forty degrees is a slight left")
	check(classify_turn(140) == .Sharp_Right, "a hundred and forty is sharp")
	check(classify_turn(178) == .U_Turn, "a hundred and seventy-eight is a U-turn")
	check(compass_word(0) == "north", "compass north")
	check(compass_word(90) == "east", "compass east")
	check(compass_word(225) == "south-west", "compass south-west")
	check(compass_word(359) == "north", "compass wraps")
}

// ---------------------------------------------------------------------------
// The rasterizer
// ---------------------------------------------------------------------------

Test_Canvas :: struct {
	px: []u32,
	cv: p.Canvas,
}

tc_make :: proc(w, h: int) -> Test_Canvas {
	px := make([]u32, w * h)
	for i in 0 ..< len(px) {
		px[i] = 0xff00_0000
	}
	return {px = px, cv = p.canvas_from(px, w, h, 1)}
}

tc_free :: proc(t: ^Test_Canvas) {
	p.canvas_destroy(&t.cv)
	delete(t.px)
}

tc_at :: proc(t: ^Test_Canvas, x, y: int) -> u32 {
	if x < 0 || y < 0 || x >= t.cv.w || y >= t.cv.h {
		return 0
	}
	return t.px[y * t.cv.w + x] & 0x00ff_ffff
}

// tc_coverage sums how much of the canvas the fill colour covers, in pixels,
// reading the red channel against a black background. That turns "did the
// polygon come out the right size" into a number.
tc_coverage :: proc(t: ^Test_Canvas) -> f64 {
	s := 0.0
	for v in t.px {
		s += f64((v >> 16) & 0xff) / 255
	}
	return s
}

WHITE :: p.Color{255, 255, 255, 255}

test_raster :: proc() {
	fmt.println("- scanline polygon fill")
	r: Raster
	defer raster_destroy(&r)

	// A plain square, on integer boundaries.
	{
		t := tc_make(64, 64)
		defer tc_free(&t)
		raster_begin(&r, {0, 0, 64, 64})
		add_rect(&r, 10, 10, 20, 20)
		raster_fill(&r, &t.cv, WHITE)
		check(tc_at(&t, 20, 20) == 0xffffff, "a square's interior is filled")
		check(tc_at(&t, 5, 20) == 0, "outside it is not")
		check(tc_at(&t, 35, 20) == 0, "nor to the right")
		check(tc_at(&t, 20, 5) == 0, "nor above")
		near(tc_coverage(&t), 400, 0.5, "a 20x20 square covers 400 pixels")
	}

	// A fractional square: the area must still come out right, which is what
	// says the antialiasing is a coverage computation and not a rounding.
	{
		t := tc_make(64, 64)
		defer tc_free(&t)
		raster_begin(&r, {0, 0, 64, 64})
		add_rect(&r, 10.25, 10.5, 20.5, 20.25)
		raster_fill(&r, &t.cv, WHITE)
		// The vertical direction is sampled at SUB sub-scanlines, so the area
		// is exact to within 1/SUB of a row along each horizontal edge.
		near(tc_coverage(&t), 20.5 * 20.25, 20.5 * 2.0 / SUB, "a fractional square's area")
		e := tc_at(&t, 10, 20)
		check(e > 0 && e < 0xffffff, "the fractional left edge is a partial pixel, got %x", e)
	}

	// A triangle: half of the box.
	{
		t := tc_make(80, 80)
		defer tc_free(&t)
		raster_begin(&r, {0, 0, 80, 80})
		raster_move_to(&r, 10, 10)
		raster_line_to(&r, 70, 10)
		raster_line_to(&r, 10, 70)
		raster_close(&r)
		raster_fill(&r, &t.cv, WHITE)
		rel(tc_coverage(&t), 60.0 * 60 / 2, 0.01, "a right triangle is half its box")
	}

	// A hole. The outer ring runs one way and the hole the other, which is
	// what map_prepare guarantees and what nonzero winding needs.
	{
		t := tc_make(80, 80)
		defer tc_free(&t)
		raster_begin(&r, {0, 0, 80, 80})
		// Outer, clockwise on screen.
		raster_move_to(&r, 10, 10)
		raster_line_to(&r, 70, 10)
		raster_line_to(&r, 70, 70)
		raster_line_to(&r, 10, 70)
		raster_close(&r)
		// Hole, anticlockwise.
		raster_move_to(&r, 30, 30)
		raster_line_to(&r, 30, 50)
		raster_line_to(&r, 50, 50)
		raster_line_to(&r, 50, 30)
		raster_close(&r)
		raster_fill(&r, &t.cv, WHITE)
		check(tc_at(&t, 20, 20) == 0xffffff, "the ring is filled")
		check(tc_at(&t, 40, 40) == 0, "the hole is not")
		check(tc_at(&t, 40, 20) == 0xffffff, "above the hole is filled")
		near(tc_coverage(&t), 60.0 * 60 - 20.0 * 20, 1.0, "the ring's area is the outer less the hole")
	}

	// A hole wound the *same* way as the outer ring is not a hole under
	// nonzero winding — it is a doubly covered region. Even-odd disagrees, and
	// that disagreement is exactly the difference between the two rules.
	{
		t := tc_make(80, 80)
		defer tc_free(&t)
		build :: proc(r: ^Raster) {
			raster_move_to(r, 10, 10)
			raster_line_to(r, 70, 10)
			raster_line_to(r, 70, 70)
			raster_line_to(r, 10, 70)
			raster_close(r)
			raster_move_to(r, 30, 30)
			raster_line_to(r, 50, 30)
			raster_line_to(r, 50, 50)
			raster_line_to(r, 30, 50)
			raster_close(r)
		}
		raster_begin(&r, {0, 0, 80, 80})
		build(&r)
		raster_fill(&r, &t.cv, WHITE, .Nonzero)
		check(tc_at(&t, 40, 40) == 0xffffff, "nonzero fills a co-wound inner ring")
		near(tc_coverage(&t), 60.0 * 60, 1.0, "and the area is the outer square")

		t2 := tc_make(80, 80)
		defer tc_free(&t2)
		raster_begin(&r, {0, 0, 80, 80})
		build(&r)
		raster_fill(&r, &t2.cv, WHITE, .Even_Odd)
		check(tc_at(&t2, 40, 40) == 0, "even-odd cuts it out")
		check(tc_at(&t2, 20, 20) == 0xffffff, "but keeps the ring")
		near(tc_coverage(&t2), 60.0 * 60 - 20.0 * 20, 1.0, "even-odd area is the ring")
	}

	// A self-touching ring: a figure of eight pinched at one point. Both lobes
	// must come out filled and nothing may run off the end of an array.
	{
		t := tc_make(80, 120)
		defer tc_free(&t)
		raster_begin(&r, {0, 0, 80, 120})
		raster_move_to(&r, 40, 60) // the pinch
		raster_line_to(&r, 10, 10)
		raster_line_to(&r, 70, 10)
		raster_close(&r) // back through the pinch
		raster_move_to(&r, 40, 60)
		raster_line_to(&r, 70, 110)
		raster_line_to(&r, 10, 110)
		raster_close(&r)
		raster_fill(&r, &t.cv, WHITE)
		check(tc_at(&t, 40, 25) == 0xffffff, "the upper lobe of a pinched ring is filled")
		check(tc_at(&t, 40, 95) == 0xffffff, "and the lower lobe")
		check(tc_at(&t, 5, 60) == 0, "and the pinch point does not bleed sideways")
	}

	// A single ring that doubles back on itself in one subpath — the same
	// vertex visited twice — must not crash and must still fill.
	{
		t := tc_make(60, 60)
		defer tc_free(&t)
		raster_begin(&r, {0, 0, 60, 60})
		raster_move_to(&r, 10, 10)
		raster_line_to(&r, 50, 10)
		raster_line_to(&r, 30, 30)
		raster_line_to(&r, 50, 50)
		raster_line_to(&r, 10, 50)
		raster_line_to(&r, 30, 30) // revisited
		raster_close(&r)
		raster_fill(&r, &t.cv, WHITE)
		// (30,14) is inside the upper lobe and (40,45) inside the lower; (45,20)
		// is in the notch the ring folds out of itself. None of the three sits
		// on an edge, which would make the test a coin toss.
		check(tc_at(&t, 30, 14) == 0xffffff, "a doubled-back ring fills its upper lobe")
		check(tc_at(&t, 40, 45) == 0xffffff, "and its lower lobe")
		check(tc_at(&t, 45, 20) == 0, "and not the notch between them")
	}

	// Degenerate input: an empty path, one point, a zero-area ring, a ring
	// entirely outside the clip.
	{
		t := tc_make(40, 40)
		defer tc_free(&t)
		raster_begin(&r, {0, 0, 40, 40})
		raster_fill(&r, &t.cv, WHITE)
		near(tc_coverage(&t), 0, 1e-9, "an empty path draws nothing")

		raster_begin(&r, {0, 0, 40, 40})
		raster_move_to(&r, 10, 10)
		raster_close(&r)
		raster_fill(&r, &t.cv, WHITE)
		near(tc_coverage(&t), 0, 1e-9, "a single point draws nothing")

		raster_begin(&r, {0, 0, 40, 40})
		add_rect(&r, 5, 5, 10, 0)
		raster_fill(&r, &t.cv, WHITE)
		near(tc_coverage(&t), 0, 1e-9, "a zero-height rectangle draws nothing")

		raster_begin(&r, {0, 0, 40, 40})
		add_rect(&r, 100, 100, 20, 20)
		raster_fill(&r, &t.cv, WHITE)
		near(tc_coverage(&t), 0, 1e-9, "a rectangle outside the clip draws nothing")

		raster_begin(&r, {0, 0, 40, 40})
		add_rect(&r, -50, -50, 20, 20)
		raster_fill(&r, &t.cv, WHITE)
		near(tc_coverage(&t), 0, 1e-9, "nor one before the origin")
	}

	// The clip rectangle is respected in both directions.
	{
		t := tc_make(60, 60)
		defer tc_free(&t)
		raster_begin(&r, {20, 20, 20, 20})
		add_rect(&r, 0, 0, 60, 60)
		raster_fill(&r, &t.cv, WHITE)
		check(tc_at(&t, 30, 30) == 0xffffff, "inside the clip is painted")
		check(tc_at(&t, 10, 30) == 0, "left of the clip is not")
		check(tc_at(&t, 50, 30) == 0, "nor right of it")
		check(tc_at(&t, 30, 10) == 0, "nor above it")
		check(tc_at(&t, 30, 50) == 0, "nor below it")
		near(tc_coverage(&t), 400, 0.5, "the clip rectangle's own area is covered")
	}

	// A huge polygon against a small clip: the cost must be bounded by the
	// clip, which is what makes a zoomed-in city affordable. The check here is
	// correctness; the frame times in --bench are the performance claim.
	{
		t := tc_make(40, 40)
		defer tc_free(&t)
		raster_begin(&r, {0, 0, 40, 40})
		add_rect(&r, -100_000, -100_000, 200_000, 200_000)
		raster_fill(&r, &t.cv, WHITE)
		near(tc_coverage(&t), 1600, 0.5, "a polygon far larger than the canvas fills it exactly")
	}

	fmt.println("- strokes")
	// A horizontal stroke of width 4 covers four rows over its length.
	{
		t := tc_make(80, 40)
		defer tc_free(&t)
		raster_begin(&r, {0, 0, 80, 40})
		stroke_polyline(&r, []([2]f32){{10, 20}, {70, 20}}, 4, false, false)
		raster_fill(&r, &t.cv, WHITE)
		near(tc_coverage(&t), 60.0 * 4, 1.0, "a 60px stroke of width 4 covers 240 pixels")
		check(tc_at(&t, 40, 20) == 0xffffff, "the stroke's centre is solid")
		check(tc_at(&t, 40, 25) == 0, "and 5px away it is not")
	}

	// Overlapping quads from a polyline must union, not double-darken. With a
	// half-transparent colour a doubled pixel would come out brighter.
	{
		t := tc_make(80, 80)
		defer tc_free(&t)
		raster_begin(&r, {0, 0, 80, 80})
		stroke_polyline(&r, []([2]f32){{10, 40}, {40, 40}, {40, 70}}, 8, false, true)
		raster_fill(&r, &t.cv, p.Color{255, 255, 255, 128})
		v := tc_at(&t, 40, 40) >> 16
		check(v > 110 && v < 140, "an overlapping join does not double-blend, got %d", v)
	}

	// A closed stroke is a ring.
	{
		t := tc_make(80, 80)
		defer tc_free(&t)
		raster_begin(&r, {0, 0, 80, 80})
		stroke_polyline(&r, []([2]f32){{20, 20}, {60, 20}, {60, 60}, {20, 60}}, 3, true, false)
		raster_fill(&r, &t.cv, WHITE)
		check(tc_at(&t, 40, 20) == 0xffffff, "the top of a closed stroke")
		check(tc_at(&t, 40, 60) == 0xffffff, "the bottom")
		check(tc_at(&t, 40, 40) == 0, "and the middle is hollow")
	}

	// Degenerate strokes.
	{
		t := tc_make(40, 40)
		defer tc_free(&t)
		raster_begin(&r, {0, 0, 40, 40})
		stroke_polyline(&r, []([2]f32){}, 4)
		stroke_polyline(&r, []([2]f32){{20, 20}}, 0)
		stroke_polyline(&r, []([2]f32){{20, 20}, {20, 20}}, 4, false, false)
		raster_fill(&r, &t.cv, WHITE)
		check(true, "a degenerate stroke does not crash")
	}
}

test_clip :: proc() {
	fmt.println("- polyline clipping")
	out := make([dynamic][2]f32)
	runs := make([dynamic]Run)
	defer delete(out)
	defer delete(runs)
	clip := p.Rect{0, 0, 100, 100}

	// Entirely inside: one run, every vertex kept.
	clear(&out)
	clear(&runs)
	clip_polyline([]([2]f32){{10, 10}, {50, 20}, {90, 80}}, clip, &out, &runs)
	check(len(runs) == 1, "a polyline inside the clip is one run, got %d", len(runs))
	check(len(out) == 3, "with all three vertices, got %d", len(out))

	// Entirely outside.
	clear(&out)
	clear(&runs)
	clip_polyline([]([2]f32){{-50, -50}, {-10, -20}}, clip, &out, &runs)
	check(len(runs) == 0, "a polyline outside the clip is no runs")

	// Crossing out and back in: two runs.
	clear(&out)
	clear(&runs)
	clip_polyline(
		[]([2]f32){{10, 50}, {-20, 50}, {-20, 60}, {10, 60}},
		clip,
		&out,
		&runs,
	)
	check(len(runs) == 2, "out and back in is two runs, got %d", len(runs))

	// Every clipped vertex is inside the rectangle, give or take rounding.
	clear(&out)
	clear(&runs)
	clip_polyline(
		[]([2]f32){{-500, 50}, {500, 50}, {500, -500}, {-500, 200}},
		clip,
		&out,
		&runs,
	)
	allin := true
	for q in out {
		if q.x < -0.01 || q.x > 100.01 || q.y < -0.01 || q.y > 100.01 {
			allin = false
		}
	}
	check(allin, "clipped vertices land inside the rectangle")
	check(len(runs) >= 1, "a crossing polyline produces at least one run")

	// A long line across the viewport becomes two vertices, which is the point
	// of clipping before stroking.
	clear(&out)
	clear(&runs)
	clip_polyline([]([2]f32){{-100_000, 50}, {100_000, 50}}, clip, &out, &runs)
	check(len(out) == 2, "a world-spanning line clips to two vertices, got %d", len(out))
	near(f64(out[0].x), 0, 0.01, "clipped at the left edge")
	near(f64(out[1].x), 100, 0.01, "clipped at the right edge")
}

// ---------------------------------------------------------------------------
// GeoJSON
// ---------------------------------------------------------------------------

SAMPLE :: `{
  "type": "FeatureCollection",
  "features": [
    {"type":"Feature","properties":{"place":"city","name":"Testville"},
     "geometry":{"type":"Point","coordinates":[7.0,45.0]}},
    {"type":"Feature","properties":{"highway":"primary","name":"Main Street","oneway":"yes","maxspeed":"50"},
     "geometry":{"type":"LineString","coordinates":[[7.0,45.0],[7.01,45.0],[7.01,45.01]]}},
    {"type":"Feature","properties":{"leisure":"park","name":"Holey Park"},
     "geometry":{"type":"Polygon","coordinates":[
        [[7.0,45.0],[7.02,45.0],[7.02,45.02],[7.0,45.02],[7.0,45.0]],
        [[7.005,45.005],[7.015,45.005],[7.015,45.015],[7.005,45.015],[7.005,45.005]]]}},
    {"type":"Feature","properties":{"natural":"water","name":"Two Lakes"},
     "geometry":{"type":"MultiPolygon","coordinates":[
        [[[7.03,45.0],[7.04,45.0],[7.04,45.01],[7.03,45.0]]],
        [[[7.05,45.0],[7.06,45.0],[7.06,45.01],[7.05,45.0]]]]}},
    {"type":"Feature","properties":{"highway":"residential","name":"Split Road"},
     "geometry":{"type":"MultiLineString","coordinates":[
        [[7.0,45.03],[7.01,45.03]],[[7.02,45.03],[7.03,45.03]]]}},
    {"type":"Feature","properties":{"amenity":"cafe","name":"Two Spots"},
     "geometry":{"type":"MultiPoint","coordinates":[[7.07,45.0],[7.08,45.0]]}},
    {"type":"Feature","properties":{"name":"Nothing There"},"geometry":null},
    {"type":"Feature","properties":{"building":"yes","name":"Elevated","extra":{"a":[1,2,{"b":3}]}},
     "geometry":{"type":"Polygon","coordinates":[
        [[7.09,45.0,120.5],[7.095,45.0,120.5],[7.095,45.005,120.5],[7.09,45.0,120.5]]]}}
  ]
}`

test_geojson :: proc() {
	fmt.println("- geojson")
	m: Map
	map_init(&m)
	defer map_destroy(&m)
	n, err := parse_geojson(&m, SAMPLE)
	check(err.msg == "", "the sample parses: %s", err.msg)
	check(n == 7, "seven features (the null geometry is skipped), got %d", n)
	check(m.n_points == 2, "two point features, got %d", m.n_points)
	check(m.n_lines == 2, "two line features, got %d", m.n_lines)
	check(m.n_polys == 3, "three polygon features, got %d", m.n_polys)

	find :: proc(m: ^Map, name: string) -> int {
		for f, i in m.features {
			if f.name == name {
				return i
			}
		}
		return -1
	}

	ci := find(&m, "Testville")
	check(ci >= 0, "the city is there")
	if ci >= 0 {
		check(m.features[ci].class == .City, "place=city becomes City, got %v", m.features[ci].class)
		check(m.features[ci].geom == .Point, "and it is a point")
		lon, lat := world_to_lonlat(m.pts[m.rings[m.features[ci].first_ring].first])
		near(lon, 7.0, 1e-9, "the city's longitude survived")
		near(lat, 45.0, 1e-9, "and its latitude")
	}

	si := find(&m, "Main Street")
	check(si >= 0, "the street is there")
	if si >= 0 {
		f := m.features[si]
		check(f.class == .Primary, "highway=primary becomes Primary, got %v", f.class)
		check(f.oneway == 1, "oneway=yes is read, got %d", f.oneway)
		near(f64(f.speed), 50, 1e-6, "maxspeed=50 is read")
		check(f.ring_count == 1 && m.rings[f.first_ring].count == 3, "three vertices")
		check(is_road(f.class), "a primary road routes")
		check(f.size > 1000 && f.size < 2000, "its length is about 1.5 km, got %.0f", f.size)
	}

	pi := find(&m, "Holey Park")
	check(pi >= 0, "the park is there")
	if pi >= 0 {
		f := m.features[pi]
		check(f.class == .Park, "leisure=park becomes Park")
		check(f.ring_count == 2, "two rings, got %d", f.ring_count)
		check(!m.rings[f.first_ring].hole, "the first ring is the outer one")
		check(m.rings[f.first_ring + 1].hole, "the second is a hole")
	}

	wi := find(&m, "Two Lakes")
	check(wi >= 0 && m.features[wi].ring_count == 2, "a MultiPolygon keeps both outers")
	if wi >= 0 {
		check(!m.rings[m.features[wi].first_ring].hole, "neither is a hole")
		check(!m.rings[m.features[wi].first_ring + 1].hole, "neither is a hole")
	}

	mi := find(&m, "Split Road")
	check(mi >= 0 && m.features[mi].ring_count == 2, "a MultiLineString keeps both parts")

	mp := find(&m, "Two Spots")
	check(mp >= 0 && m.features[mp].ring_count == 2, "a MultiPoint keeps both points")

	bi := find(&m, "Elevated")
	check(bi >= 0, "a position with an elevation is accepted")
	if bi >= 0 {
		check(m.features[bi].class == .Building, "building=yes becomes Building")
		lon, _ := world_to_lonlat(m.pts[m.rings[m.features[bi].first_ring].first])
		near(lon, 7.09, 1e-9, "the third coordinate is ignored, not shifted into x")
	}

	check(bbox_valid(m.bbox), "the collection has a bounding box")
	check(m.bbox.min.x < m.bbox.max.x, "and it is not inverted")

	// A bare geometry at the top level, which several tools emit.
	m2: Map
	map_init(&m2)
	defer map_destroy(&m2)
	n2, e2 := parse_geojson(&m2, `{"type":"LineString","coordinates":[[1,2],[3,4]]}`)
	check(e2.msg == "" && n2 == 1, "a bare geometry at the top level parses: %s", e2.msg)

	// A GeometryCollection.
	m3: Map
	map_init(&m3)
	defer map_destroy(&m3)
	n3, e3 := parse_geojson(
		&m3,
		`{"type":"GeometryCollection","geometries":[{"type":"Point","coordinates":[1,2]},{"type":"Point","coordinates":[3,4]}]}`,
	)
	check(e3.msg == "" && n3 == 2, "a GeometryCollection parses: %s", e3.msg)

	// An empty collection is valid and holds nothing.
	m4: Map
	map_init(&m4)
	defer map_destroy(&m4)
	n4, e4 := parse_geojson(&m4, `{"type":"FeatureCollection","features":[]}`)
	check(e4.msg == "" && n4 == 0, "an empty FeatureCollection is legal")

	// A byte-order mark, which Windows tools add.
	m5: Map
	map_init(&m5)
	defer map_destroy(&m5)
	n5, e5 := parse_geojson(&m5, "\xef\xbb\xbf{\"type\":\"Point\",\"coordinates\":[1,2]}")
	check(e5.msg == "" && n5 == 1, "a UTF-8 BOM is not a syntax error: %s", e5.msg)

	// Escapes in a name, including a surrogate pair.
	m6: Map
	map_init(&m6)
	defer map_destroy(&m6)
	n6, e6 := parse_geojson(
		&m6,
		`{"type":"Feature","properties":{"name":"Café \"Le Pont\"\u000a😀"},"geometry":{"type":"Point","coordinates":[1,2]}}`,
	)
	check(e6.msg == "" && n6 == 1, "escapes in a name parse: %s", e6.msg)
	if n6 == 1 {
		check(
			strings.contains(m6.features[0].name, "Café") &&
			strings.contains(m6.features[0].name, "\"Le Pont\""),
			"and decode, got %q",
			m6.features[0].name,
		)
		check(strings.contains(m6.features[0].name, "\U0001F600"), "including a surrogate pair")
	}
}

// test_geojson_malformed is the important half. Every one of these must be
// *refused* — a message and a line number — and none of them may crash,
// allocate unboundedly or leave a half-built feature in the map.
test_geojson_malformed :: proc() {
	fmt.println("- geojson, refusing malformed input")
	bad := [?]struct {
		what:  string,
		doc:   string,
		keeps: int, // features legitimately read before the error
	} {
		{"an empty document", "", 0},
		{"only whitespace", "   \n\t ", 0},
		{"a bare number", "42", 0},
		{"a bare string", `"hello"`, 0},
		{"an array at the top level", `[1,2,3]`, 0},
		{"an unterminated object", `{"type":"Point","coordinates":[1,2]`, 0},
		{"an unterminated array", `{"type":"Point","coordinates":[1,2`, 0},
		{"an unterminated string", `{"type":"Poin`, 0},
		{"a trailing comma in an object", `{"type":"Point","coordinates":[1,2],}`, 0},
		{"a trailing comma in an array", `{"type":"Point","coordinates":[1,2,]}`, 0},
		{"a missing comma", `{"type":"Point" "coordinates":[1,2]}`, 0},
		{"a missing colon", `{"type" "Point","coordinates":[1,2]}`, 0},
		{"a single-quoted string", `{'type':'Point','coordinates':[1,2]}`, 0},
		{"an unquoted key", `{type:"Point","coordinates":[1,2]}`, 0},
		{"no type member", `{"coordinates":[1,2]}`, 0},
		{"an unknown geometry type", `{"type":"Hyperbola","coordinates":[1,2]}`, 0},
		{"a geometry with no coordinates", `{"type":"Point"}`, 0},
		{"a FeatureCollection with no features", `{"type":"FeatureCollection"}`, 0},
		{"a Feature with no geometry", `{"type":"Feature","properties":{}}`, 0},
		{"a coordinate that is a string", `{"type":"Point","coordinates":["1","2"]}`, 0},
		{"a coordinate that is null", `{"type":"Point","coordinates":[null,2]}`, 0},
		{"a one-element position", `{"type":"Point","coordinates":[1]}`, 0},
		{"an empty position", `{"type":"Point","coordinates":[]}`, 0},
		{"a longitude out of range", `{"type":"Point","coordinates":[200,45]}`, 0},
		{"a latitude out of range", `{"type":"Point","coordinates":[7,95]}`, 0},
		{"a number with no digits", `{"type":"Point","coordinates":[-,2]}`, 0},
		{"an exponent with no digits", `{"type":"Point","coordinates":[1e,2]}`, 0},
		{"a bad escape", `{"type":"Feature","properties":{"name":"a\qb"},"geometry":null}`, 0},
		{"a truncated unicode escape", `{"type":"Feature","properties":{"name":"a\u00"},"geometry":null}`, 0},
		// A valid document followed by rubbish: the first geometry really was
		// read, so it is kept and the trailing content is still an error.
		{"trailing content", `{"type":"Point","coordinates":[1,2]} {"and":"more"}`, 1},
		{"a features member that is not an array", `{"type":"FeatureCollection","features":{}}`, 0},
		{"a non-object inside features", `{"type":"FeatureCollection","features":[7]}`, 0},
		{"an empty object", `{}`, 0},
		{"an unterminated comment-like sequence", `{"type":"Point","coordinates":[1,2]/*`, 0},
	}
	for b in bad {
		m: Map
		map_init(&m)
		n, err := parse_geojson(&m, b.doc)
		check(err.msg != "", "%s is refused", b.what)
		check(n == b.keeps, "%s keeps %d features, got %d", b.what, b.keeps, n)
		if b.keeps == 0 {
			check(len(m.pts) == 0, "%s leaves no coordinates behind, got %d", b.what, len(m.pts))
			check(len(m.rings) == 0, "%s leaves no rings behind, got %d", b.what, len(m.rings))
		}
		map_destroy(&m)
	}

	// Nesting depth: a document of ten thousand open brackets must be refused
	// rather than recursing until the stack runs out.
	{
		sb := strings.builder_make()
		defer strings.builder_destroy(&sb)
		strings.write_string(&sb, `{"type":"Point","coordinates":`)
		for _ in 0 ..< 10_000 {
			strings.write_string(&sb, "[")
		}
		m: Map
		map_init(&m)
		defer map_destroy(&m)
		_, err := parse_geojson(&m, strings.to_string(sb))
		check(err.msg != "", "a pathologically nested document is refused")
	}

	// A document that is valid up to a point keeps what it read and says where
	// it stopped, which is more useful than throwing eleven thousand good
	// features away over one bad one.
	{
		m: Map
		map_init(&m)
		defer map_destroy(&m)
		n, err := parse_geojson(
			&m,
			`{"type":"FeatureCollection","features":[
			   {"type":"Feature","properties":{"name":"Good"},"geometry":{"type":"Point","coordinates":[1,2]}},
			   {"type":"Feature","properties":{"name":"Bad"},"geometry":{"type":"Point","coordinates":[1,}}
			 ]}`,
		)
		check(err.msg != "", "a collection that goes wrong part way is still an error")
		check(n == 1, "and keeps the features before the error, got %d", n)
		check(err.line == 3, "and reports the line, got %d", err.line)
	}
}

test_osm_xml :: proc() {
	fmt.println("- osm xml")
	doc := `<?xml version="1.0" encoding="UTF-8"?>
<osm version="0.6" generator="selftest">
  <bounds minlat="44.9" minlon="7.0" maxlat="45.1" maxlon="7.2"/>
  <node id="1" lat="45.000" lon="7.000"/>
  <node id="2" lat="45.000" lon="7.010"/>
  <node id="3" lat="45.010" lon="7.010"/>
  <node id="4" lat="45.010" lon="7.000"/>
  <node id="5" lat="45.005" lon="7.005">
    <tag k="place" v="village"/>
    <tag k="name" v="Little &amp; Large"/>
  </node>
  <way id="100">
    <nd ref="1"/><nd ref="2"/><nd ref="3"/>
    <tag k="highway" v="secondary"/>
    <tag k="name" v="Coast Road"/>
    <tag k="oneway" v="yes"/>
    <tag k="maxspeed" v="30 mph"/>
  </way>
  <way id="101">
    <nd ref="1"/><nd ref="2"/><nd ref="3"/><nd ref="4"/><nd ref="1"/>
    <tag k="leisure" v="park"/>
    <tag k="name" v="Green Square"/>
  </way>
  <way id="102">
    <nd ref="1"/><nd ref="2"/><nd ref="3"/><nd ref="4"/><nd ref="1"/>
    <tag k="highway" v="residential"/>
    <tag k="name" v="Ring Street"/>
  </way>
  <relation id="200">
    <member type="way" ref="101" role="outer"/>
    <tag k="type" v="multipolygon"/>
  </relation>
</osm>`
	m: Map
	map_init(&m)
	defer map_destroy(&m)
	n, err := parse_osm_xml(&m, doc)
	check(n == 4, "four features from the OSM document, got %d", n)
	check(strings.contains(err, "relation"), "and the skipped relation is reported: %q", err)

	find :: proc(m: ^Map, name: string) -> int {
		for f, i in m.features {
			if f.name == name {
				return i
			}
		}
		return -1
	}
	vi := find(&m, "Little & Large")
	check(vi >= 0, "an XML entity in a name is decoded")
	if vi >= 0 {
		check(m.features[vi].class == .Village, "a tagged node becomes a place")
		check(m.features[vi].geom == .Point, "and it is a point")
	}
	ri := find(&m, "Coast Road")
	check(ri >= 0, "the way is there")
	if ri >= 0 {
		f := m.features[ri]
		check(f.geom == .Line, "an open way is a line")
		check(f.class == .Secondary, "highway=secondary")
		check(f.oneway == 1, "oneway is read")
		near(f64(f.speed), 30 * 1.609344, 0.01, "30 mph is converted to km/h")
	}
	gi := find(&m, "Green Square")
	check(gi >= 0 && m.features[gi].geom == .Polygon, "a closed way with an area tag is a polygon")
	si := find(&m, "Ring Street")
	check(
		si >= 0 && m.features[si].geom == .Line,
		"a closed way tagged highway is still a line, not a filled blob",
	)

	// Refusals.
	for bad in ([?]struct {
		what: string,
		doc:  string,
	} {
		{"a node with no latitude", `<osm><node id="1" lon="7"/></osm>`},
		{"a node out of range", `<osm><node id="1" lat="200" lon="7"/></osm>`},
		{"an unterminated element", `<osm><node id="1" lat="45" lon="7"`},
		{"an unterminated comment", `<osm><!-- oh dear`},
		{"something that is not OSM at all", `<html><body>hello</body></html>`},
	}) {
		m2: Map
		map_init(&m2)
		_, e := parse_osm_xml(&m2, bad.doc)
		check(e != "", "%s is refused", bad.what)
		map_destroy(&m2)
	}
}

// ---------------------------------------------------------------------------
// The generator
// ---------------------------------------------------------------------------

test_generator :: proc() {
	fmt.println("- the generated city")
	m: Map
	map_init(&m)
	defer map_destroy(&m)
	generate_city(&m)
	check(len(m.features) > 2000, "the city has thousands of features, got %d", len(m.features))
	check(bbox_valid(m.bbox), "with a bounding box")

	// The generator is deterministic: the same seed is the same city, down to
	// the last coordinate. Every other assertion in this file depends on it.
	m2: Map
	map_init(&m2)
	defer map_destroy(&m2)
	generate_city(&m2)
	check(len(m.features) == len(m2.features), "two runs give the same feature count")
	check(len(m.pts) == len(m2.pts), "and the same coordinate count")
	same := len(m.pts) == len(m2.pts)
	if same {
		for i in 0 ..< len(m.pts) {
			if m.pts[i] != m2.pts[i] {
				same = false
				break
			}
		}
	}
	check(same, "and the identical coordinates")

	// A census, so a change to the generator that quietly drops a layer shows
	// up here rather than in a screenshot.
	counts: [Class]int
	named := 0
	for f in m.features {
		counts[f.class] += 1
		if f.name != "" {
			named += 1
		}
	}
	check(counts[.Ocean] >= 1, "there is a sea")
	check(counts[.Water] >= 2, "there is water: the river and the lake")
	check(counts[.Park] + counts[.Forest] >= 5, "there are parks")
	check(counts[.Building] > 300, "there are hundreds of buildings, got %d", counts[.Building])
	check(counts[.Motorway] + counts[.Trunk] + counts[.Primary] >= 6, "there are arterials")
	check(counts[.Residential_Road] > 200, "and residential streets, got %d", counts[.Residential_Road])
	check(counts[.Service] > 10, "and service roads")
	check(counts[.Path] > 5, "and footpaths")
	check(counts[.Rail] == 1, "and a railway")
	check(counts[.City] == 1, "one city")
	check(counts[.Suburb] == len(SUBURB_NAMES), "every suburb")
	check(counts[.Village] == len(VILLAGE_NAMES), "every village")
	check(counts[.Poi] == len(POI_NAMES), "every POI")
	check(named > 400, "most of it is named, got %d", named)
	check(counts[.Wetland] >= 1, "and a wetland")
	check(counts[.Sand] >= 1, "and a beach")
	check(counts[.Pitch] >= 2, "and sports pitches")

	// One-way streets exist, which the routing test needs.
	ones := 0
	for f in m.features {
		if f.oneway != 0 {
			ones += 1
		}
	}
	check(ones > 10, "there are one-way streets, got %d", ones)

	// The park with a hole, and the lake that shows through it.
	holes := 0
	for f in m.features {
		if f.geom != .Polygon {
			continue
		}
		for ri in f.first_ring ..< f.first_ring + f.ring_count {
			if m.rings[ri].hole {
				holes += 1
			}
		}
	}
	check(holes >= 1, "a park has a lake cut out of it, got %d holes", holes)

	// map_prepare: windings, and a paint order that is a permutation in layer
	// order.
	d: Draw_Order
	defer draw_order_destroy(&d)
	map_prepare(&m, &d)
	bad_wind := 0
	for f in m.features {
		if f.geom != .Polygon {
			continue
		}
		for ri in f.first_ring ..< f.first_ring + f.ring_count {
			r := m.rings[ri]
			if r.count < 3 {
				continue
			}
			a := ring_signed_area(&m, r)
			if r.hole && a >= 0 {
				bad_wind += 1
			}
			if !r.hole && a <= 0 {
				bad_wind += 1
			}
		}
	}
	check(bad_wind == 0, "every outer ring winds one way and every hole the other, %d wrong", bad_wind)

	check(len(d.order) == len(m.features), "the paint order covers every feature")
	seen := make([]bool, len(m.features))
	defer delete(seen)
	dup := 0
	for i in d.order {
		if seen[i] {
			dup += 1
		}
		seen[i] = true
	}
	check(dup == 0, "and holds each one once")
	mono := true
	for k in 1 ..< len(d.order) {
		if class_layer(m.features[d.order[k]].class) < class_layer(m.features[d.order[k - 1]].class) {
			mono = false
		}
	}
	check(mono, "the paint order never goes back down a layer")
	// And the layer offsets partition it.
	part := true
	for l in 0 ..< N_LAYERS {
		if d.layer[l] > d.layer[l + 1] {
			part = false
		}
		for k in int(d.layer[l]) ..< int(d.layer[l + 1]) {
			if class_layer(m.features[d.order[k]].class) != l {
				part = false
			}
		}
	}
	check(part, "the layer offsets partition the paint order")
	check(d.layer[0] == 0 && int(d.layer[N_LAYERS]) == len(m.features), "and cover all of it")

	// Anchors are inside their feature's bounding box.
	out := 0
	for f, i in m.features {
		a := d.anchor[i]
		if a.x < f.bbox.min.x - 1e-12 || a.x > f.bbox.max.x + 1e-12 ||
		   a.y < f.bbox.min.y - 1e-12 || a.y > f.bbox.max.y + 1e-12 {
			out += 1
		}
	}
	check(out == 0, "every label anchor is inside its feature, %d outside", out)
}

// test_roundtrip writes the generated city out and reads it back, which checks
// the writer, the reader and that the two agree to the precision the writer
// claims.
test_roundtrip :: proc() {
	fmt.println("- geojson round trip")
	dir := "/tmp/palmy-maps-selftest"
	os.make_directory(dir)
	path := fmt.tprintf("%s/roundtrip.geojson", dir)

	a: Map
	map_init(&a)
	defer map_destroy(&a)
	generate_city(&a)
	check(write_geojson(&a, path), "the city writes out")

	b: Map
	map_init(&b)
	defer map_destroy(&b)
	n, err := load_geojson(&b, path)
	check(err.msg == "", "and reads back: %s at line %d", err.msg, err.line)
	check(n == len(a.features), "with the same feature count: %d vs %d", n, len(a.features))
	check(len(b.pts) == len(a.pts), "and the same coordinate count")

	if len(b.features) == len(a.features) {
		mismatch := 0
		worst := 0.0
		for i in 0 ..< len(a.features) {
			fa, fb := a.features[i], b.features[i]
			if fa.name != fb.name || fa.class != fb.class || fa.geom != fb.geom ||
			   fa.ring_count != fb.ring_count || fa.oneway != fb.oneway {
				mismatch += 1
				if mismatch == 1 {
					fmt.printf(
						"        first mismatch at %d: %q/%v/%v/%d/%d vs %q/%v/%v/%d/%d\n",
						i,
						fa.name, fa.class, fa.geom, fa.ring_count, fa.oneway,
						fb.name, fb.class, fb.geom, fb.ring_count, fb.oneway,
					)
				}
				continue
			}
			for ri in 0 ..< fa.ring_count {
				ra := a.rings[fa.first_ring + ri]
				rb := b.rings[fb.first_ring + ri]
				if ra.count != rb.count || ra.hole != rb.hole {
					mismatch += 1
					break
				}
				for k in 0 ..< ra.count {
					lon1, lat1 := world_to_lonlat(a.pts[ra.first + k])
					lon2, lat2 := world_to_lonlat(b.pts[rb.first + k])
					worst = math.max(worst, abs(lon1 - lon2))
					worst = math.max(worst, abs(lat1 - lat2))
				}
			}
		}
		check(mismatch == 0, "every feature survives the round trip, %d differ", mismatch)
		// The writer prints seven decimals, so a coordinate may move by half of
		// the seventh — about a centimetre.
		check(worst <= 5e-8, "and no coordinate moves more than half a unit in the last place (%.3g)", worst)
	}

	// A one-way street's direction survives, which routing depends on.
	ones_a, ones_b := 0, 0
	for f in a.features {
		if f.oneway != 0 {
			ones_a += 1
		}
	}
	for f in b.features {
		if f.oneway != 0 {
			ones_b += 1
		}
	}
	check(ones_a == ones_b && ones_a > 0, "one-way flags survive: %d vs %d", ones_a, ones_b)
	os.remove(path)
}

// ---------------------------------------------------------------------------
// The routing graph
// ---------------------------------------------------------------------------

// grid_node is the node at an arterial grid intersection, by index. The whole
// routing ground truth rests on these existing and being shared between the
// north-south and east-west arterials, so it is checked before it is used.
grid_node :: proc(g: ^Graph, i, j: int) -> i32 {
	lon, lat := met_to_lonlat(GRID_X0 + f64(i) * GRID_STEP, GRID_Y0 + f64(j) * GRID_STEP)
	return graph_find(g, lon, lat)
}

// stair_cost is the cost of one monotone staircase across the arterial grid:
// vertically along column i0 to row via_j, horizontally along that row, then
// vertically along column i1. The lengths come from the graph's own arcs, so
// this is an independent sum of the same numbers the router adds up, not a
// re-derivation of them.
stair_cost :: proc(c: ^City, i0, j0, i1, j1, via_j: int) -> f64 {
	total := 0.0
	seg :: proc(c: ^City, ia, ja, ib, jb: int) -> f64 {
		a := grid_node(&c.g, ia, ja)
		b := grid_node(&c.g, ib, jb)
		if a < 0 || b < 0 {
			return 1e30
		}
		// f32, because that is the precision an arc's length is stored at.
		return f64(f32(world_distance(c.g.pos[a], c.g.pos[b])))
	}
	sj := via_j > j0 ? 1 : -1
	for k in 1 ..= abs(via_j - j0) {
		total += seg(c, i0, j0 + (k - 1) * sj, i0, j0 + k * sj)
	}
	si := i1 > i0 ? 1 : -1
	for k in 1 ..= abs(i1 - i0) {
		total += seg(c, i0 + (k - 1) * si, via_j, i0 + k * si, via_j)
	}
	tj := j1 > via_j ? 1 : -1
	for k in 1 ..= abs(j1 - via_j) {
		total += seg(c, i1, via_j + (k - 1) * tj, i1, via_j + k * tj)
	}
	return total
}

City :: struct {
	m:   Map,
	ord: Draw_Order,
	g:   Graph,
	ix:  Search_Index,
}

city_make :: proc(c: ^City) {
	map_init(&c.m)
	generate_city(&c.m)
	map_prepare(&c.m, &c.ord)
	graph_build(&c.g, &c.m)
	index_build(&c.ix, &c.m)
}

city_free :: proc(c: ^City) {
	index_destroy(&c.ix)
	graph_destroy(&c.g)
	draw_order_destroy(&c.ord)
	map_destroy(&c.m)
}

test_graph :: proc() {
	fmt.println("- the routing graph")
	c: City
	city_make(&c)
	defer city_free(&c)

	check(graph_node_count(&c.g) > 2000, "thousands of nodes, got %d", graph_node_count(&c.g))
	check(graph_arc_count(&c.g) > 4000, "and more arcs, got %d", graph_arc_count(&c.g))
	check(c.g.n_oneway > 10, "some of them one-way, got %d", c.g.n_oneway)

	// The CSR offsets are a valid partition.
	n := graph_node_count(&c.g)
	check(len(c.g.start) == n + 1, "the CSR has one offset per node plus one")
	ok := c.g.start[0] == 0 && int(c.g.start[n]) == graph_arc_count(&c.g)
	for i in 1 ..= n {
		if c.g.start[i] < c.g.start[i - 1] {
			ok = false
		}
	}
	check(ok, "and its offsets never go backwards")
	// Every arc points at a real node and has a positive length.
	badarc := 0
	for a in c.g.arcs {
		if int(a.to) < 0 || int(a.to) >= n || a.len_m <= 0 {
			badarc += 1
		}
	}
	check(badarc == 0, "every arc is well formed, %d are not", badarc)

	// The arterial grid's intersections exist, and are shared.
	missing := 0
	low_degree := 0
	for i in 5 ..= 14 {
		for j in 0 ..= GRID_NY - 1 {
			id := grid_node(&c.g, i, j)
			if id < 0 {
				missing += 1
				continue
			}
			deg := int(c.g.start[id + 1] - c.g.start[id])
			// An interior junction has four ways out. Column 6 is where the
			// river's eastern carriageway begins, so a junction there has
			// three on a row with no bridge, which is the point of the river.
			want := (i > 6 && i < 14 && j > 0 && j < GRID_NY - 1) ? 4 : 2
			if deg < want {
				low_degree += 1
				if low_degree <= 3 {
					fmt.printf("        junction (%d,%d) has degree %d, wanted %d\n", i, j, deg, want)
				}
			}
		}
	}
	check(missing == 0, "every eastern grid intersection is a node, %d missing", missing)
	check(low_degree == 0, "and the crossing arterials share it, %d too sparse", low_degree)

	// A one-way service road is directed: there is an arc one way and not the
	// other between its two ends.
	found_directed := false
	for f, fi in c.m.features {
		if f.oneway != 1 || f.geom != .Line {
			continue
		}
		r := c.m.rings[f.first_ring]
		if r.count < 2 {
			continue
		}
		u := graph_find_world(&c.g, c.m.pts[r.first])
		v := graph_find_world(&c.g, c.m.pts[r.first + 1])
		if u < 0 || v < 0 {
			continue
		}
		fwd := has_arc(&c.g, u, v)
		back := has_arc(&c.g, v, u)
		if fwd && !back {
			found_directed = true
		}
		_ = fi
		break
	}
	check(found_directed, "a one-way street has an arc one way only")
}

graph_find_world :: proc(g: ^Graph, w: World_Pt) -> i32 {
	if id, ok := g.lookup[node_key(w)]; ok {
		return id
	}
	return -1
}

has_arc :: proc(g: ^Graph, u, v: i32) -> bool {
	for ai in g.start[u] ..< g.start[u + 1] {
		if g.arcs[ai].to == v {
			return true
		}
	}
	return false
}

// ---------------------------------------------------------------------------
// Routing against known answers
// ---------------------------------------------------------------------------

// build_uniform_grid makes an nx by ny grid graph whose every arc costs
// exactly `w` metres at exactly `kmh`, regardless of the geometry. The
// positions are a real lon/lat grid — A* needs them for the heuristic — but
// they are deliberately much closer together than `w`, so the great-circle
// heuristic stays a lower bound and A* stays admissible.
//
// In such a graph the cost of a shortest path is exactly
// (|di| + |dj|) * w, which is an analytic answer rather than a measured one.
build_uniform_grid :: proc(g: ^Graph, nx, ny: int, w: f32, kmh: f32) {
	delete(g.lookup)
	clear(&g.pos)
	clear(&g.arcs)
	clear(&g.start)
	g.lookup = make(map[u64]i32)

	// 0.0001 degrees is about 11 metres, well under any `w` used here.
	STEP :: 0.0001
	for j in 0 ..< ny {
		for i in 0 ..< nx {
			lon := 7.0 + f64(i) * STEP
			lat := 0.0 + f64(j) * STEP
			wp := lonlat_to_world(lon, lat)
			append(&g.pos, wp)
			g.lookup[node_key(wp)] = i32(j * nx + i)
		}
	}
	n := nx * ny
	resize(&g.start, n + 1)
	deg := make([]i32, n, context.temp_allocator)
	for j in 0 ..< ny {
		for i in 0 ..< nx {
			k := j * nx + i
			if i > 0 {deg[k] += 1}
			if i < nx - 1 {deg[k] += 1}
			if j > 0 {deg[k] += 1}
			if j < ny - 1 {deg[k] += 1}
		}
	}
	g.start[0] = 0
	for k in 0 ..< n {
		g.start[k + 1] = g.start[k] + deg[k]
	}
	resize(&g.arcs, int(g.start[n]))
	fill := make([]i32, n, context.temp_allocator)
	push :: proc(g: ^Graph, fill: []i32, from, to: int, w, kmh: f32) {
		at := g.start[from] + fill[from]
		g.arcs[at] = {to = i32(to), len_m = w, speed = kmh}
		fill[from] += 1
	}
	for j in 0 ..< ny {
		for i in 0 ..< nx {
			k := j * nx + i
			if i > 0 {push(g, fill, k, k - 1, w, kmh)}
			if i < nx - 1 {push(g, fill, k, k + 1, w, kmh)}
			if j > 0 {push(g, fill, k, k - nx, w, kmh)}
			if j < ny - 1 {push(g, fill, k, k + nx, w, kmh)}
		}
	}
	resize(&g.dist, n)
	resize(&g.est, n)
	resize(&g.from, n)
	resize(&g.via, n)
	resize(&g.seen, n)
	for i in 0 ..< n {
		g.seen[i] = 0
	}
	g.stamp = 0
}

test_routing_analytic :: proc() {
	fmt.println("- routing against analytically known shortest paths")
	// A grid where every arc costs exactly 100 m at exactly 36 km/h, which is
	// 10 m/s, so the shortest path's cost is (|di|+|dj|)*100 metres and
	// (|di|+|dj|)*10 seconds. Both are exact.
	NX :: 12
	NY :: 9
	W :: f32(100)
	KMH :: f32(36)
	g: Graph
	defer graph_destroy(&g)
	build_uniform_grid(&g, NX, NY, W, KMH)
	m: Map // no features; the graph is synthetic, so steps have no names
	map_init(&m)
	defer map_destroy(&m)

	rt: Route
	defer route_destroy(&rt)

	pairs := [?][4]int {
		{0, 0, 11, 8}, {0, 0, 0, 8}, {0, 0, 11, 0}, {5, 4, 5, 4},
		{3, 1, 9, 7}, {11, 8, 0, 0}, {2, 6, 8, 2}, {1, 1, 2, 1},
		{0, 8, 11, 0}, {6, 0, 6, 8}, {4, 4, 7, 4}, {10, 7, 1, 2},
	}
	for q in pairs {
		s := i32(q[1] * NX + q[0])
		t := i32(q[3] * NX + q[2])
		hops := abs(q[2] - q[0]) + abs(q[3] - q[1])

		route_find(&g, &m, s, t, .Distance, &rt)
		check(rt.ok, "a route exists from (%d,%d) to (%d,%d)", q[0], q[1], q[2], q[3])
		if !rt.ok {
			continue
		}
		near(
			rt.dist_m,
			f64(hops) * f64(W),
			1e-9,
			"the exact shortest distance from (%d,%d) to (%d,%d) is %d hops",
			q[0],
			q[1],
			q[2],
			q[3],
			hops,
		)
		check(
			len(rt.path) == hops + 1,
			"and it takes exactly %d hops, got %d",
			hops,
			len(rt.path) - 1,
		)
		check(len(rt.arcs) == hops, "with one arc per hop")
		// The path is connected, every step is a real arc, and it ends where
		// it was asked to.
		conn := rt.path[0] == s && rt.path[len(rt.path) - 1] == t
		for k in 1 ..< len(rt.path) {
			if !has_arc(&g, rt.path[k - 1], rt.path[k]) {
				conn = false
			}
			if g.arcs[rt.arcs[k - 1]].to != rt.path[k] {
				conn = false
			}
		}
		check(conn, "and every step of it is a real arc")

		route_find(&g, &m, s, t, .Time, &rt)
		near(
			rt.time_s,
			f64(hops) * 10,
			1e-9,
			"and the exact shortest time is %d seconds",
			hops * 10,
		)
	}

	// A* must not be fooled into exploring the whole graph: a straight run
	// along one row should settle far fewer nodes than there are.
	route_find(&g, &m, 0, i32(NX - 1), .Distance, &rt)
	check(rt.explored < NX * NY, "A* settles fewer nodes than the graph has, %d of %d", rt.explored, NX * NY)

	// Removing the middle column must make the detour longer by exactly the
	// two extra rows it costs. This is the river-and-bridge case in miniature,
	// with an answer that can be written down.
	{
		g2: Graph
		defer graph_destroy(&g2)
		build_uniform_grid(&g2, 5, 5, 100, 36)
		// Cut every arc crossing between column 1 and column 2 except on row 0.
		for j in 1 ..< 5 {
			cut_arc(&g2, i32(j * 5 + 1), i32(j * 5 + 2))
			cut_arc(&g2, i32(j * 5 + 2), i32(j * 5 + 1))
		}
		route_find(&g2, &m, i32(4 * 5 + 1), i32(4 * 5 + 2), .Distance, &rt)
		check(rt.ok, "a route round the barrier exists")
		// From (1,4) to (2,4): down four rows to row 0, across, back up four.
		// Nine hops rather than one.
		near(rt.dist_m, 9 * 100, 1e-9, "and costs exactly the detour: nine hops")
		check(len(rt.path) == 10, "ten nodes on the detour, got %d", len(rt.path))
	}
}

// cut_arc removes the arc u->v by pointing it at itself with an enormous cost,
// which is the cheapest way to perforate a CSR graph in a test without
// rebuilding it.
cut_arc :: proc(g: ^Graph, u, v: i32) {
	for ai in g.start[u] ..< g.start[u + 1] {
		if g.arcs[ai].to == v {
			g.arcs[ai].to = u
			g.arcs[ai].len_m = 1e9
		}
	}
}

test_routing_city :: proc() {
	fmt.println("- routing across the generated city's arterial grid")
	c: City
	city_make(&c)
	defer city_free(&c)
	rt: Route
	defer route_destroy(&rt)

	// Along one row of the grid the shortest path is unique: the row itself.
	// So the whole node sequence can be written down in advance, which is an
	// exact assertion that no floating-point tolerance can hide.
	for j in ([?]int{2, 6, 10}) {
		for span in ([?][2]int{{8, 13}, {9, 10}, {13, 8}}) {
			s := grid_node(&c.g, span[0], j)
			t := grid_node(&c.g, span[1], j)
			if s < 0 || t < 0 {
				check(false, "grid nodes (%d,%d) and (%d,%d) exist", span[0], j, span[1], j)
				continue
			}
			route_find(&c.g, &c.m, s, t, .Distance, &rt)
			check(rt.ok, "a route along row %d from %d to %d", j, span[0], span[1])
			if !rt.ok {
				continue
			}
			step := span[1] > span[0] ? 1 : -1
			nhop := abs(span[1] - span[0])
			exact := len(rt.path) == nhop + 1
			if exact {
				for k in 0 ..= nhop {
					if rt.path[k] != grid_node(&c.g, span[0] + k * step, j) {
						exact = false
						break
					}
				}
			}
			check(
				exact,
				"and it is exactly the row's own junctions, %d to %d on row %d (%d nodes)",
				span[0],
				span[1],
				j,
				len(rt.path),
			)
			// And the cost is the sum of those segments, computed here rather
			// than taken from the router.
			want := 0.0
			for k in 1 ..= nhop {
				want += f64(f32(world_distance(
					c.g.pos[grid_node(&c.g, span[0] + (k - 1) * step, j)],
					c.g.pos[grid_node(&c.g, span[0] + k * step, j)],
				)))
			}
			rel(rt.dist_m, want, 1e-9, "and costs the sum of those segments")
			// The nominal spacing: each hop is GRID_STEP metres by
			// construction, give or take the spherical approximation in the
			// generator's flat-earth conversion.
			rel(rt.dist_m, f64(nhop) * GRID_STEP, 2e-3, "which is %d x %g m", nhop, GRID_STEP)
		}
	}

	// Along one column, likewise.
	for i in ([?]int{8, 11, 14}) {
		s := grid_node(&c.g, i, 1)
		t := grid_node(&c.g, i, 11)
		check(s >= 0 && t >= 0, "column %d has junctions at rows 1 and 11", i)
		if s < 0 || t < 0 {
			continue
		}
		route_find(&c.g, &c.m, s, t, .Distance, &rt)
		check(rt.ok, "a route along column %d", i)
		if !rt.ok {
			continue
		}
		exact := len(rt.path) == 11
		if exact {
			for k in 0 ..= 10 {
				if rt.path[k] != grid_node(&c.g, i, 1 + k) {
					exact = false
					break
				}
			}
		}
		check(exact, "and it is exactly that column's junctions, got %d nodes", len(rt.path))
		rel(rt.dist_m, 10 * GRID_STEP, 2e-3, "costing ten grid steps")
	}

	// An L-shaped journey. Here the shortest path is not unique — every
	// monotone staircase has the same cost — so the assertion is on the cost
	// and the hop count rather than the sequence.
	for q in ([?][4]int{{8, 2, 13, 9}, {9, 10, 14, 3}, {13, 1, 8, 11}, {10, 4, 12, 6}}) {
		s := grid_node(&c.g, q[0], q[1])
		t := grid_node(&c.g, q[2], q[3])
		check(s >= 0 && t >= 0, "both corners of the L exist")
		if s < 0 || t < 0 {
			continue
		}
		hops := abs(q[2] - q[0]) + abs(q[3] - q[1])
		// The exact optimum, written down rather than measured.
		//
		// Every monotone staircase uses the same number of north-south hops,
		// and a north-south hop is the same length in every column — the
		// generator lays the grid out on constant steps of latitude. An
		// east-west hop, though, is a little shorter the further from the
		// equator it is, because a degree of longitude shrinks. So the
		// cheapest staircase puts *all* of its east-west hops on whichever of
		// the two rows is further north, and that staircase is one of exactly
		// two: turn at the start row, or turn at the end row.
		want := math.min(
			stair_cost(&c, q[0], q[1], q[2], q[3], q[1]),
			stair_cost(&c, q[0], q[1], q[2], q[3], q[3]),
		)
		route_find(&c.g, &c.m, s, t, .Distance, &rt)
		check(rt.ok, "the L-shaped route exists")
		if !rt.ok {
			continue
		}
		check(len(rt.path) == hops + 1, "and takes exactly %d hops, got %d", hops, len(rt.path) - 1)
		rel(rt.dist_m, want, 1e-9, "and costs exactly the cheapest staircase")
		rel(rt.dist_m, f64(hops) * GRID_STEP, 2e-3, "which is %d grid steps", hops)
	}

	// The river. An east-west arterial on an odd row has no bridge, so a
	// journey across it must detour to a bridge row and cost strictly more
	// than the Manhattan distance.
	{
		// Row 5 has no bridge (odd), so go from west of the river to east of
		// it along it.
		s := grid_node(&c.g, 2, 5)
		t := grid_node(&c.g, 8, 5)
		check(s >= 0 && t >= 0, "junctions either side of the river exist")
		if s >= 0 && t >= 0 {
			route_find(&c.g, &c.m, s, t, .Distance, &rt)
			check(rt.ok, "a route across the river exists, via a bridge")
			manhattan := 6 * GRID_STEP
			check(
				rt.dist_m > manhattan * 1.1,
				"and it is longer than the straight line, %.0f vs %.0f",
				rt.dist_m,
				manhattan,
			)
			check(len(rt.path) > 7, "taking more than the %d direct hops, got %d", 6, len(rt.path) - 1)
			// It must cross on an even row, which is where the bridges are.
			crossed := false
			for id in rt.path {
				for j in 0 ..< GRID_NY {
					if !bridge_row(j) {
						continue
					}
					if id == grid_node(&c.g, 5, j) || id == grid_node(&c.g, 4, j) {
						crossed = true
					}
				}
			}
			check(crossed, "and it goes through a bridge row")
		}
	}

	// Time and distance are different answers. Over a long diagonal the
	// time-optimal route should prefer the faster classes, so its distance is
	// no shorter than the distance-optimal one.
	{
		s := grid_node(&c.g, 8, 1)
		t := grid_node(&c.g, 14, 11)
		if s >= 0 && t >= 0 {
			route_find(&c.g, &c.m, s, t, .Distance, &rt)
			dist_opt := rt.dist_m
			time_of_dist := rt.time_s
			route_find(&c.g, &c.m, s, t, .Time, &rt)
			check(
				rt.time_s <= time_of_dist + 1e-6,
				"the time-optimal route is no slower than the distance-optimal one: %.1f vs %.1f",
				rt.time_s,
				time_of_dist,
			)
			check(
				rt.dist_m >= dist_opt - 1e-6,
				"and no shorter than the shortest: %.1f vs %.1f",
				rt.dist_m,
				dist_opt,
			)
		}
	}

	// A one-way street may not be driven backwards. Find one, route along it
	// the wrong way, and the answer must not be the single arc.
	{
		for f in c.m.features {
			if f.oneway != 1 || f.geom != .Line {
				continue
			}
			r := c.m.rings[f.first_ring]
			u := graph_find_world(&c.g, c.m.pts[r.first])
			v := graph_find_world(&c.g, c.m.pts[r.first + r.count - 1])
			if u < 0 || v < 0 || u == v {
				continue
			}
			route_find(&c.g, &c.m, v, u, .Distance, &rt)
			direct := f64(0)
			for k in 1 ..< r.count {
				direct += world_distance(c.m.pts[r.first + k - 1], c.m.pts[r.first + k])
			}
			if rt.ok {
				check(
					rt.dist_m > direct * 1.01,
					"driving a one-way street backwards costs a detour: %.1f vs %.1f",
					rt.dist_m,
					direct,
				)
			} else {
				check(true, "or is impossible, which is also honouring it")
			}
			break
		}
	}

	// graph_nearest finds a node near a point on a road and nothing absurd
	// far away.
	{
		s := grid_node(&c.g, 10, 6)
		if s >= 0 {
			id, d := graph_nearest(&c.g, c.g.pos[s])
			check(id == s, "the nearest node to a node is itself")
			near(d, 0, 1e-6, "at no distance")
			// Half a grid step away, the nearest node is within a grid step.
			off := c.g.pos[s]
			off.x += GRID_STEP * 0.4 / EARTH_CIRCUMFERENCE
			id2, d2 := graph_nearest(&c.g, off)
			check(id2 >= 0 && d2 < GRID_STEP, "and a point beside a road finds one, %.0f m away", d2)
		}
	}
}

test_routing_degenerate :: proc() {
	fmt.println("- routing, the degenerate cases")
	m: Map
	map_init(&m)
	defer map_destroy(&m)
	rt: Route
	defer route_destroy(&rt)

	// An empty graph.
	{
		g: Graph
		defer graph_destroy(&g)
		graph_build(&g, &m)
		check(graph_node_count(&g) == 0, "a map with no roads has no nodes")
		route_find(&g, &m, 0, 0, .Distance, &rt)
		check(!rt.ok, "and no route can be found in it")
		check(rt.why != "", "with a reason given: %q", rt.why)
		id, _ := graph_nearest(&g, {0.5, 0.5})
		check(id == -1, "and nothing is nearest to anything")
	}

	// A one-node graph. Start equals end, which is a valid zero-length route
	// and not an error.
	{
		g: Graph
		defer graph_destroy(&g)
		build_uniform_grid(&g, 1, 1, 100, 36)
		check(graph_node_count(&g) == 1, "a one-node graph has one node")
		check(graph_arc_count(&g) == 0, "and no arcs")
		route_find(&g, &m, 0, 0, .Distance, &rt)
		check(rt.ok, "routing from a node to itself succeeds")
		near(rt.dist_m, 0, 1e-12, "at no distance")
		near(rt.time_s, 0, 1e-12, "and no time")
		check(len(rt.path) == 1, "one node on the path, got %d", len(rt.path))
		check(len(rt.arcs) == 0, "and no arcs")
		check(len(rt.steps) == 1, "and a single instruction, got %d", len(rt.steps))
		if len(rt.steps) == 1 {
			check(rt.steps[0].man == .Arrive, "which is to arrive")
		}
		// Out of range in both directions.
		route_find(&g, &m, 0, 1, .Distance, &rt)
		check(!rt.ok, "a node past the end is refused")
		route_find(&g, &m, -1, 0, .Distance, &rt)
		check(!rt.ok, "and so is a negative one")
		route_find(&g, &m, 5, 9, .Distance, &rt)
		check(!rt.ok, "and so are two of them")
	}

	// Two components with no arc between them: a route must fail cleanly.
	{
		g: Graph
		defer graph_destroy(&g)
		build_uniform_grid(&g, 4, 1, 100, 36)
		// Cut the graph in half between nodes 1 and 2.
		cut_arc(&g, 1, 2)
		cut_arc(&g, 2, 1)
		route_find(&g, &m, 0, 3, .Distance, &rt)
		// The cut arcs are self-loops with an enormous cost, so a path still
		// technically exists; what matters is that it is not the cheap one.
		check(!rt.ok || rt.dist_m > 1e8, "a severed graph gives no cheap route")

		// A properly disconnected graph: build one with no arcs at all.
		g2: Graph
		defer graph_destroy(&g2)
		build_uniform_grid(&g2, 2, 1, 100, 36)
		for i in 0 ..< len(g2.arcs) {
			g2.arcs[i].to = i32(i % 2)
		}
		clear(&g2.arcs)
		for i in 0 ..= 2 {
			g2.start[i] = 0
		}
		route_find(&g2, &m, 0, 1, .Distance, &rt)
		check(!rt.ok, "a graph with no arcs has no route")
		check(rt.why == "no route exists between those points", "and says so: %q", rt.why)
		check(len(rt.path) == 0, "and returns no path")
		check(len(rt.steps) == 0, "and no instructions")
	}

	// Routing twice in a row must give the same answer: the search scratch is
	// reused between calls and a stale `seen` stamp would be the bug.
	{
		g: Graph
		defer graph_destroy(&g)
		build_uniform_grid(&g, 6, 6, 100, 36)
		route_find(&g, &m, 0, 35, .Distance, &rt)
		first := rt.dist_m
		firstn := len(rt.path)
		for _ in 0 ..< 5 {
			route_find(&g, &m, 0, 35, .Distance, &rt)
		}
		near(rt.dist_m, first, 1e-12, "repeating a search gives the same cost")
		check(len(rt.path) == firstn, "and the same path length")
		// And interleaving other searches does not corrupt it.
		route_find(&g, &m, 3, 20, .Time, &rt)
		route_find(&g, &m, 0, 35, .Distance, &rt)
		near(rt.dist_m, first, 1e-12, "even after other searches")
	}
}

test_directions :: proc() {
	fmt.println("- turn-by-turn directions")
	c: City
	city_make(&c)
	defer city_free(&c)
	rt: Route
	defer route_destroy(&rt)

	// A journey east then north along the grid turns left once.
	s := grid_node(&c.g, 8, 4)
	mid := grid_node(&c.g, 12, 4)
	t := grid_node(&c.g, 12, 8)
	check(s >= 0 && mid >= 0 && t >= 0, "the three corners exist")
	if s < 0 || mid >= 0 && t < 0 {
		return
	}

	route_find(&c.g, &c.m, s, t, .Distance, &rt)
	check(rt.ok, "the L-shaped route is found")
	if !rt.ok {
		return
	}
	check(len(rt.steps) >= 3, "it has a departure, a turn and an arrival, got %d", len(rt.steps))
	check(rt.steps[0].man == .Depart, "the first instruction is to depart")
	check(rt.steps[len(rt.steps) - 1].man == .Arrive, "and the last is to arrive")

	// Grid north is a higher northing, so travelling north from an eastbound
	// road is a left turn.
	turns := 0
	lefts := 0
	rights := 0
	for st in rt.steps {
		switch st.man {
		case .Left, .Slight_Left, .Sharp_Left:
			turns += 1
			lefts += 1
		case .Right, .Slight_Right, .Sharp_Right, .U_Turn:
			turns += 1
			rights += 1
		case .Depart, .Arrive, .Continue:
		}
	}
	check(turns == 1, "exactly one turn on an L, got %d", turns)
	// Which way it turns depends on which leg A* takes first, and both legs
	// cost very nearly the same. So the assertion is that the turn agrees with
	// the geometry: leaving north and ending east is a right turn, leaving
	// east and ending north is a left.
	north_first := abs(angle_delta(rt.steps[0].heading, 0)) < 20
	east_first := abs(angle_delta(rt.steps[0].heading, 90)) < 20
	check(north_first || east_first, "the departure follows the grid, bearing %.1f", rt.steps[0].heading)
	if north_first {
		check(rights == 1, "leaving north and ending east is a right turn, got %d", rights)
	} else if east_first {
		check(lefts == 1, "leaving east and ending north is a left turn, got %d", lefts)
	}

	// The step distances add up to the route, and each step names its road.
	sum := 0.0
	tsum := 0.0
	named := 0
	for st in rt.steps {
		sum += st.dist_m
		tsum += st.time_s
		if st.name != "" {
			named += 1
		}
	}
	rel(sum, rt.dist_m, 1e-9, "the step distances sum to the route distance")
	rel(tsum, rt.time_s, 1e-9, "and the step times to the route time")
	check(named >= len(rt.steps) - 1, "every step but the arrival names a road")

	// The steps partition the path: step k ends where step k+1 begins, the
	// first starts at the start and the last ends at the end.
	ok := rt.steps[0].first == 0
	for k in 1 ..< len(rt.steps) {
		if rt.steps[k].first != rt.steps[k - 1].last {
			ok = false
		}
	}
	if rt.steps[len(rt.steps) - 1].last != len(rt.path) - 1 {
		ok = false
	}
	check(ok, "the steps partition the path")

	// The departure follows a grid arterial, so its bearing is a cardinal one.
	check(
		abs(angle_delta(rt.steps[0].heading, 0)) < 1.5 ||
		abs(angle_delta(rt.steps[0].heading, 90)) < 1.5,
		"the departure bearing is cardinal, got %.2f",
		rt.steps[0].heading,
	)

	// A straight run along one road is a single instruction plus the arrival,
	// not one instruction per junction — which is what the name-merging in
	// build_steps is for.
	{
		s2 := grid_node(&c.g, 8, 6)
		t2 := grid_node(&c.g, 14, 6)
		route_find(&c.g, &c.m, s2, t2, .Distance, &rt)
		check(rt.ok, "a straight run along one road")
		if rt.ok {
			check(
				len(rt.steps) == 2,
				"is two instructions, not one per junction: got %d over %d hops",
				len(rt.steps),
				len(rt.path) - 1,
			)
			check(rt.steps[0].dist_m > 2500, "and the first covers the whole run, %.0f m", rt.steps[0].dist_m)
		}
	}

	// The instruction text is well formed and mentions the road.
	route_find(&c.g, &c.m, s, t, .Distance, &rt)
	if rt.ok && len(rt.steps) >= 2 {
		txt := step_text(rt.steps[0])
		check(strings.has_prefix(txt, "Head "), "a departure reads 'Head ...': %q", txt)
		for st in rt.steps[1:len(rt.steps) - 1] {
			tx := step_text(st)
			check(len(tx) > 0 && strings.contains(tx, st.name), "a turn names its road: %q", tx)
		}
		check(step_text(rt.steps[len(rt.steps) - 1]) == "Arrive at your destination", "the arrival reads plainly")
	}
	_ = mid
}

// label_clashes counts the pairs of *distinct* labels whose boxes overlap.
label_clashes :: proc(l: ^Labeller) -> (n: int, first: string) {
	for i in 0 ..< len(l.labels) {
		a := l.labels[i]
		for j in i + 1 ..< len(l.labels) {
			b := l.labels[j]
			hit := false
			for x in a.box_first ..< a.box_first + a.box_count {
				for y in b.box_first ..< b.box_first + b.box_count {
					if box_overlaps(l.boxes[x], l.boxes[y]) {
						hit = true
					}
				}
			}
			if hit {
				n += 1
				if first == "" {
					first = fmt.tprintf("%q over %q", a.text, b.text)
				}
			}
		}
	}
	return
}

// ---------------------------------------------------------------------------
// Search
// ---------------------------------------------------------------------------

test_search :: proc() {
	fmt.println("- search")
	c: City
	city_make(&c)
	defer city_free(&c)
	hits := make([dynamic]Hit)
	defer delete(hits)

	check(index_count(&c.ix) > 200, "the index has hundreds of names, got %d", index_count(&c.ix))

	name_of :: proc(c: ^City, hits: []Hit, k: int) -> string {
		if k >= len(hits) {
			return ""
		}
		return c.ix.entries[hits[k].entry].name
	}

	// Exact.
	search(&c.ix, CITY_NAME, &hits)
	check(len(hits) > 0 && name_of(&c, hits[:], 0) == CITY_NAME, "an exact name is the first hit")

	// Case and accents are folded.
	search(&c.ix, "marisport", &hits)
	check(len(hits) > 0 && name_of(&c, hits[:], 0) == CITY_NAME, "case is folded")
	search(&c.ix, "MARISPORT", &hits)
	check(len(hits) > 0 && name_of(&c, hits[:], 0) == CITY_NAME, "in both directions")

	// A prefix.
	search(&c.ix, "Jubilee", &hits)
	found := false
	for k in 0 ..< min(5, len(hits)) {
		if strings.has_prefix(name_of(&c, hits[:], k), "Jubilee") {
			found = true
		}
	}
	check(found, "a prefix finds the park, %d hits", len(hits))

	// A word prefix: the second word of a two-word name.
	search(&c.ix, "Gardens", &hits)
	found = false
	for k in 0 ..< min(8, len(hits)) {
		if strings.contains(name_of(&c, hits[:], k), "Gardens") {
			found = true
		}
	}
	check(found, "a word prefix finds a name by its second word")

	// A substring that spans a word boundary.
	search(&c.ix, "lee Gard", &hits)
	check(len(hits) > 0 && strings.contains(name_of(&c, hits[:], 0), "Jubilee Gardens"), "a substring across words")

	// Fuzzy: initials of a two-word name.
	search(&c.ix, "mcs", &hits)
	found = false
	for k in 0 ..< min(8, len(hits)) {
		if name_of(&c, hits[:], k) == "Marisport Central Station" {
			found = true
		}
	}
	check(found, "the initials find Marisport Central Station, %d hits", len(hits))

	// A typo'd prefix still finds it by subsequence.
	search(&c.ix, "marisprt", &hits)
	found = false
	for k in 0 ..< min(6, len(hits)) {
		if strings.has_prefix(name_of(&c, hits[:], k), "Marisport") {
			found = true
		}
	}
	check(found, "a dropped letter still finds the city")

	// Nonsense finds nothing.
	search(&c.ix, "zzqxwvj", &hits)
	check(len(hits) == 0, "nonsense finds nothing, got %d", len(hits))
	search(&c.ix, "", &hits)
	check(len(hits) == 0, "an empty query finds nothing")
	search(&c.ix, "   ", &hits)
	check(len(hits) == 0, "nor does whitespace")

	// A query longer than any name finds nothing rather than reading past an
	// array.
	search(&c.ix, strings.repeat("a", 400, context.temp_allocator), &hits)
	check(len(hits) == 0, "an absurdly long query finds nothing")

	// A street that the generator split in two around the river appears once,
	// with an extent covering both halves.
	{
		// Find a name carried by more than one feature.
		dupname := ""
		seen := make(map[string]int, allocator = context.temp_allocator)
		for f in c.m.features {
			if f.name == "" {
				continue
			}
			seen[f.name] += 1
			if seen[f.name] > 1 && dupname == "" {
				dupname = f.name
			}
		}
		check(dupname != "", "the generator does split a street into several ways")
		if dupname != "" {
			search(&c.ix, dupname, &hits)
			n := 0
			for h in hits {
				if c.ix.entries[h.entry].name == dupname {
					n += 1
				}
			}
			check(n == 1, "and search returns it once, not %d times", n)
		}
	}

	// Determinism: the same query twice in a row is the same ranking.
	{
		search(&c.ix, "harbour", &hits)
		first := make([]Hit, len(hits), context.temp_allocator)
		copy(first, hits[:])
		search(&c.ix, "harbour", &hits)
		same := len(first) == len(hits)
		if same {
			for k in 0 ..< len(hits) {
				if first[k].entry != hits[k].entry {
					same = false
				}
			}
		}
		check(same, "the same query gives the same order")
	}

	// The limit is respected.
	search(&c.ix, "a", &hits, 7)
	check(len(hits) <= 7, "the result limit is honoured, got %d", len(hits))

	// Every hit's bounding box is inside the city.
	bad := 0
	search(&c.ix, "s", &hits, 40)
	for h in hits {
		e := c.ix.entries[h.entry]
		if !bbox_overlaps(e.bbox, c.m.bbox) {
			bad += 1
		}
	}
	check(bad == 0, "every result has an extent inside the map, %d do not", bad)

	// And the scores come back in order.
	ordered := true
	for k in 1 ..< len(hits) {
		if hits[k].score > hits[k - 1].score {
			ordered = false
		}
	}
	check(ordered, "results are ordered by score")

	check(fold_rune('É') == 'e', "accents fold")
	check(fold_rune('Z') == 'z', "capitals fold")
	check(fold_rune('7') == '7', "digits are left alone")
}

// ---------------------------------------------------------------------------
// Labels
// ---------------------------------------------------------------------------

LABEL_W :: 1100
LABEL_H :: 700

// test_labels renders the city headlessly and interrogates the placement.
test_labels :: proc() {
	fmt.println("- label placement")
	off := p.offscreen_create(LABEL_W, LABEL_H, 1, "w-full h-full bg-white")
	defer p.offscreen_destroy(off)
	load_map_fonts(&off.fonts)

	c: City
	city_make(&c)
	defer city_free(&c)

	s: Scene
	defer scene_destroy(&s)
	labeller_init(&s.lab)
	s.m = &c.m
	s.ord = &c.ord
	s.g = &c.g
	s.fonts = &off.fonts
	s.show_labels = true
	s.show_buildings = true
	rect := p.Rect{0, 0, LABEL_W, LABEL_H}

	for zoom in ([?]f64{12.0, 14.0, 15.5, 17.5}) {
		s.view = {center = lonlat_to_world(CITY_LON, CITY_LAT), zoom = zoom, w = LABEL_W, h = LABEL_H}
		place_labels(&s, rect)
		check(len(s.lab.labels) > 3, "labels are placed at z%g, got %d", zoom, len(s.lab.labels))

		// The whole point: no two *labels* may overlap.
		//
		// Between labels, not between boxes: a label that follows a line
		// reserves one box per character, and consecutive characters of the
		// same word necessarily touch. What must never happen is one label's
		// box touching another label's.
		clashes, worst := label_clashes(&s.lab)
		check(clashes == 0, "no two labels overlap at z%g, %d pairs do (%s)", zoom, clashes, worst)

		// No label is upside down, and a street label follows its line.
		upside := 0
		rotated := 0
		for lb in s.lab.labels {
			for ci in lb.chunk_first ..< lb.chunk_first + lb.chunk_count {
				a := s.lab.chunks[ci].angle
				// A quarter turn either way is the limit: a north-south
				// street reads bottom to top, which is exactly -pi/2.
				if abs(a) > math.PI / 2 + 0.05 {
					upside += 1
				}
				if abs(a) > 0.08 {
					rotated += 1
				}
			}
		}
		check(upside == 0, "no label is upside down at z%g, %d are", zoom, upside)
		if zoom >= 14 {
			check(rotated > 0, "some street labels follow their line at z%g", zoom)
		}

		// A horizontal label's chunks are one per label; a curved one is one
		// per character.
		for lb in s.lab.labels {
			if lb.kind == .Place || lb.kind == .Area || lb.kind == .Building {
				check(lb.chunk_count == 1, "a horizontal label is one chunk, got %d", lb.chunk_count)
			}
		}
	}

	// A north-south street must carry a near-vertical label. The grid's
	// columns run due north, so this is a direct check that the text follows
	// the line rather than sitting beside it.
	{
		s.view = {center = lonlat_to_world(CITY_LON, CITY_LAT), zoom = 15.0, w = LABEL_W, h = LABEL_H}
		place_labels(&s, rect)
		steep := 0
		for lb in s.lab.labels {
			if lb.kind != .Street {
				continue
			}
			for ci in lb.chunk_first ..< lb.chunk_first + lb.chunk_count {
				if abs(s.lab.chunks[ci].angle) > 1.2 {
					steep += 1
					check(
						s.lab.chunks[ci].angle < 0,
						"a vertical street label reads bottom to top, angle %.3f",
						s.lab.chunks[ci].angle,
					)
				}
			}
		}
		check(steep > 0, "a north-south street's label runs up the street, %d steep chunks", steep)
	}

	// Stability. Pan by one pixel at a time and the set of labelled features
	// well inside the viewport must not change. Labels near the edge may
	// legitimately come and go, so the comparison is restricted to an inset.
	{
		inset := p.rect_inset(rect, 140)
		base := lonlat_to_world(CITY_LON, CITY_LAT)
		STEPS :: 8
		for zoom in ([?]f64{13.0, 15.0, 16.5}) {
			// `inner[k]` is what is well inside the viewport after k pixels of
			// pan; `all[k]` is everything placed. A label may legitimately
			// drift out of the inset, so the test is that whatever was well
			// inside at the start is still labelled *somewhere* at every later
			// step — which is what "does not flicker" means.
			inner := make([]map[i32]bool, STEPS, context.temp_allocator)
			all := make([]map[i32]bool, STEPS, context.temp_allocator)
			for k in 0 ..< STEPS {
				inner[k] = make(map[i32]bool, allocator = context.temp_allocator)
				all[k] = make(map[i32]bool, allocator = context.temp_allocator)
				dx := f64(k) / view_scale({zoom = zoom})
				s.view = {center = {base.x + dx, base.y}, zoom = zoom, w = LABEL_W, h = LABEL_H}
				place_labels(&s, rect)
				for lb in s.lab.labels {
					if lb.feat < 0 {
						continue
					}
					all[k][lb.feat] = true
					ok := lb.box_count > 0
					for bi in lb.box_first ..< lb.box_first + lb.box_count {
						b := s.lab.boxes[bi]
						if !p.rect_contains(inset, b.x, b.y) ||
						   !p.rect_contains(inset, b.x + b.w, b.y + b.h) {
							ok = false
						}
					}
					if ok {
						inner[k][lb.feat] = true
					}
				}
			}
			lost := 0
			for k in 1 ..< STEPS {
				for f in inner[0] {
					if !all[k][f] {
						lost += 1
						if lost <= 4 {
							fmt.printf(
								"        z%g step %d lost feature %d: %q, %v, %v\n",
								zoom,
								k,
								f,
								c.m.features[f].name,
								c.m.features[f].class,
								c.m.features[f].geom,
							)
						}
					}
				}
			}
			check(
				lost == 0,
				"no label flickers over a %d-pixel pan at z%g, %d did of %d",
				STEPS - 1,
				zoom,
				lost,
				len(inner[0]),
			)
		}
	}

	// Switching labels off places none.
	s.show_labels = false
	s.view = {center = lonlat_to_world(CITY_LON, CITY_LAT), zoom = 15, w = LABEL_W, h = LABEL_H}
	draw_scene(p.offscreen_canvas(off), rect, &s)
	check(s.n_labels == 0, "turning labels off places none")
	s.show_labels = true

	// And a frame with labels on draws something other than the background.
	draw_scene(p.offscreen_canvas(off), rect, &s)
	check(s.n_labels > 0, "turning them back on places some")
	check(s.n_drawn > 50, "and the geometry is drawn too, %d features", s.n_drawn)

	// The collision grid must not depend on the region's origin: place at an
	// offset rectangle and the result must be the same labels, shifted.
	{
		r2 := p.Rect{37, 23, LABEL_W - 74, LABEL_H - 46}
		s.view = {center = lonlat_to_world(CITY_LON, CITY_LAT), zoom = 15, w = f64(r2.w), h = f64(r2.h)}
		place_labels(&s, r2)
		clashes, _ := label_clashes(&s.lab)
		check(clashes == 0, "an offset panel still places without collisions, %d clashes", clashes)
	}

	// Markers always get placed, whatever is under them.
	{
		s.view = {center = lonlat_to_world(CITY_LON, CITY_LAT), zoom = 16, w = LABEL_W, h = LABEL_H}
		clear(&s.markers)
		for k in 0 ..< 4 {
			append(
				&s.markers,
				Marker {
					w = lonlat_to_world(CITY_LON + f64(k) * 0.001, CITY_LAT),
					label = "X",
					col = p.hex(C_MARKER),
				},
			)
		}
		place_labels(&s, rect)
		nm := 0
		for lb in s.lab.labels {
			if lb.kind == .Marker {
				nm += 1
			}
		}
		check(nm == 4, "every marker is labelled, got %d", nm)
		clear(&s.markers)
	}
}

// ---------------------------------------------------------------------------
// The application, driven headlessly
// ---------------------------------------------------------------------------

// test_interaction runs the real interface through palmy's offscreen renderer
// and drives it with synthetic input — the same `move_pointer`, `press`,
// `release` and `scroll_by` a compositor's events end up as.
//
// This is the part of the program a screenshot cannot check and a recording
// checks only if the recording works. It is also the part most likely to break
// silently: a click that lands on the wrong element still draws a perfectly
// good frame.
test_interaction :: proc() {
	fmt.println("- the interface, driven headlessly")
	W :: 1500
	H :: 940
	sc.register_shadcn_theme(false)
	p.set_text_gamma(1.8)
	off := p.offscreen_create(W, H, 1, "w-full h-full bg-background text-foreground")
	defer p.offscreen_destroy(off)
	load_map_fonts(&off.fonts)

	a := new(Maps)
	defer free(a)
	maps_init(a)
	defer maps_destroy(a)
	a.fonts = &off.fonts
	a.sc.fonts = &off.fonts
	a.sc.show_chrome = true
	generate_city(&a.m)
	rebuild(a)
	view_fit(&a.view, a.m.bbox.min, a.m.bbox.max)

	frame :: proc(a: ^Maps, off: ^p.Offscreen) {
		ui := p.offscreen_begin(off)
		if a.map_id != 0 {
			a.map_rect = p.rect_of(ui, a.map_id)
		}
		sync_view_size(a)
		fly_step(a, 1.0 / 60)
		handle_keys(a, ui)
		handle_map_mouse(a, ui)
		a.sc.view = a.view
		a.sc.cursor = a.cursor
		a.sc.has_cursor = a.has_cursor
		a.sc.show_route = a.route.ok
		draw_ui(a, ui)
		p.offscreen_end(off)
	}
	click_at :: proc(a: ^Maps, off: ^p.Offscreen, x, y: f32) {
		p.move_pointer(off, x, y)
		frame(a, off)
		p.press(off)
		frame(a, off)
		p.release(off)
		frame(a, off)
		frame(a, off)
	}

	// Two frames to settle the layout, then the map panel must have a real
	// rectangle taken from it.
	frame(a, off)
	frame(a, off)
	check(a.map_id != 0, "the map panel has an identity")
	check(a.map_rect.w > 900 && a.map_rect.h > 700, "and a rectangle: %v x %v", a.map_rect.w, a.map_rect.h)
	mid_x := a.map_rect.x + a.map_rect.w / 2
	mid_y := a.map_rect.y + a.map_rect.h / 2

	// The cursor read-out follows the pointer.
	p.move_pointer(off, mid_x, mid_y)
	frame(a, off)
	check(a.has_cursor, "the pointer over the map is noticed")
	near(a.cursor.x, a.view.center.x, 1e-6, "and the centre of the panel is the centre of the view")
	p.move_pointer(off, 40, 400) // over the side panel
	frame(a, off)
	check(!a.has_cursor, "and the pointer off the map is not")

	// A wheel over the map zooms about the cursor.
	{
		at_x := a.map_rect.x + 300
		at_y := a.map_rect.y + 200
		p.move_pointer(off, at_x, at_y)
		frame(a, off)
		before_zoom := a.view.zoom
		before_pt := screen_to_world(a.view, f64(at_x - a.map_rect.x), f64(at_y - a.map_rect.y))
		p.scroll_by(off, 0, -1)
		frame(a, off)
		check(a.view.zoom > before_zoom, "the wheel zooms in: %.3f to %.3f", before_zoom, a.view.zoom)
		after_pt := screen_to_world(a.view, f64(at_x - a.map_rect.x), f64(at_y - a.map_rect.y))
		near(after_pt.x, before_pt.x, 1e-12, "and keeps the point under the cursor, in x")
		near(after_pt.y, before_pt.y, 1e-12, "and in y")
	}

	// A drag pans by exactly the distance dragged.
	{
		p.move_pointer(off, mid_x, mid_y)
		frame(a, off)
		before := a.view.center
		scale := view_scale(a.view)
		p.press(off)
		frame(a, off)
		p.move_pointer(off, mid_x - 120, mid_y - 80)
		frame(a, off)
		p.release(off)
		frame(a, off)
		near((a.view.center.x - before.x) * scale, 120, 0.001, "a drag pans by the distance dragged, in x")
		near((a.view.center.y - before.y) * scale, 80, 0.001, "and in y")
		check(!a.dragging, "and the drag ends on the release")
	}

	// A drag must not be read as a click: the pan tool reports a position on a
	// click, and dragging the map should not.
	{
		a.tool = .Marker
		n := len(a.sc.markers)
		p.move_pointer(off, mid_x, mid_y)
		frame(a, off)
		p.press(off)
		frame(a, off)
		p.move_pointer(off, mid_x + 90, mid_y + 40)
		frame(a, off)
		p.release(off)
		frame(a, off)
		check(len(a.sc.markers) == n, "dragging with the marker tool does not drop one")
	}

	// The marker tool drops one on a click.
	{
		a.tool = .Marker
		n := len(a.sc.markers)
		click_at(a, off, mid_x + 60, mid_y + 60)
		check(len(a.sc.markers) == n + 1, "a click with the marker tool drops a marker, got %d", len(a.sc.markers))
	}

	// The measuring tool accumulates points and a length.
	{
		a.tool = .Measure
		clear(&a.sc.measure)
		click_at(a, off, mid_x - 150, mid_y - 100)
		click_at(a, off, mid_x + 150, mid_y - 100)
		check(len(a.sc.measure) == 2, "two clicks make two measuring points, got %d", len(a.sc.measure))
		d := measure_total(a)
		check(d > 0, "and a distance, %s", format_distance(d))
		// 300 pixels at this scale.
		_, lat := world_to_lonlat(a.view.center)
		rel(d, 300 * ground_resolution(lat, a.view.zoom), 0.02, "which is 300 pixels' worth of ground")
	}

	// The route tool: two clicks make a route with directions.
	{
		a.tool = .Route
		a.from_node, a.to_node = -1, -1
		route_clear(&a.route)
		click_at(a, off, mid_x - 200, mid_y + 120)
		check(a.from_node >= 0, "the first click sets the start")
		check(!a.route.ok, "and there is no route yet")
		click_at(a, off, mid_x + 220, mid_y - 140)
		check(a.to_node >= 0, "the second sets the destination")
		check(a.route.ok, "and a route is found: %s", a.route.why)
		check(len(a.route.steps) >= 2, "with directions, got %d steps", len(a.route.steps))
		check(a.panel == .Route, "and the directions panel comes forward")
		check(a.route.dist_m > 100, "over a real distance, %s", format_distance(a.route.dist_m))
		// A marker at each end.
		ends := 0
		for mk in a.sc.markers {
			if mk.kind != 0 {
				ends += 1
			}
		}
		check(ends == 2, "and a pin at each end, got %d", ends)

		// Switching the cost recomputes it.
		before := a.route.time_s
		a.cost = .Distance
		recompute_route(a, nil)
		check(a.route.ok, "the route survives switching to distance")
		check(a.route.time_s >= before - 1e-6, "and takes no less time than the fastest one")
		a.cost = .Time
		recompute_route(a, nil)
	}

	// The `/` shortcut has to actually move the focus, not merely set a flag.
	// It did only the latter once, and the symptom was that every character of
	// a typed query ran as a single-key shortcut instead: "Jubilee" turned the
	// labels and the buildings off, and "mcs" armed the marker tool and
	// cleared the map.
	{
		a.tool = .Pan
		a.searching = false
		p.press_key(off, '/')
		frame(a, off)
		frame(a, off)
		check(a.searching, "slash puts the keyboard in the search field")
		check(a.panel == .Search, "and brings the results panel forward")
		before_labels := a.sc.show_labels
		p.type_text(off, "ell")
		frame(a, off)
		frame(a, off)
		check(string(a.q[:]) == "ell", "and typing goes into the field, got %q", string(a.q[:]))
		check(a.sc.show_labels == before_labels, "not into the single-key shortcuts")
		p.press_key(off, p.KEY_ESCAPE)
		frame(a, off)
		frame(a, off)
		check(!a.searching, "and Escape gives the keyboard back")

		// A second `/` starts a fresh query rather than appending to the
		// first, and Enter on a query that matches nothing still hands the
		// keyboard back.
		p.press_key(off, '/')
		frame(a, off)
		p.type_text(off, "Jubilee")
		frame(a, off)
		frame(a, off)
		check(string(a.q[:]) == "Jubilee", "a second query starts empty, got %q", string(a.q[:]))
		check(len(a.hits) > 0, "and matches")
		// Enter on a result flies there and hands the keyboard back, so the
		// next `/` is a shortcut again and starts a third query from empty.
		p.press_key(off, p.KEY_RETURN)
		frame(a, off)
		frame(a, off)
		check(!a.searching, "Enter on a result gives the keyboard back")
		a.fly = false
		p.press_key(off, '/')
		frame(a, off)
		p.type_text(off, "zzqx")
		frame(a, off)
		frame(a, off)
		check(string(a.q[:]) == "zzqx", "and again, got %q", string(a.q[:]))
		check(len(a.hits) == 0, "which matches nothing")
		p.press_key(off, p.KEY_RETURN)
		frame(a, off)
		frame(a, off)
		check(!a.searching, "and Enter on it still gives the keyboard back")
		before_tool := a.tool
		p.press_key(off, 'm')
		frame(a, off)
		frame(a, off)
		check(a.tool != before_tool, "so the next key is a shortcut again")
		a.tool = .Pan
		clear(&a.q)
		clear(&a.hits)
	}

	// Search through the real field: type into the buffer the way the widget
	// would, run the query, and fly to the result.
	{
		clear(&a.q)
		append(&a.q, "Jubilee")
		search(&a.ix, string(a.q[:]), &a.hits)
		a.sel = 0
		check(len(a.hits) > 0, "the field's text finds something")
		before := a.view.center
		ui := p.offscreen_begin(off)
		goto_hit(a, ui, 0)
		draw_ui(a, ui)
		p.offscreen_end(off)
		check(a.fly, "and the view starts flying")
		for _ in 0 ..< 80 {
			frame(a, off)
		}
		check(!a.fly, "and arrives")
		check(before != a.view.center, "somewhere else")
		e := a.ix.entries[a.hits[0].entry]
		tgt := (e.bbox.min + e.bbox.max) / 2
		near(a.view.center.x, tgt.x, 1e-9, "centred on the result, in x")
		near(a.view.center.y, tgt.y, 1e-9, "and in y")
	}

	// And the same two things from the keyboard: with a tool armed, Enter acts
	// at the centre of the view. This is the path a pointerless seat takes,
	// and the only one a headless recording can drive.
	{
		clear_annotations(a)
		a.tool = .Route
		press_enter :: proc(a: ^Maps, off: ^p.Offscreen) {
			p.press_key(off, p.KEY_RETURN)
			frame(a, off)
			frame(a, off)
		}
		press_enter(a, off)
		check(a.from_node >= 0, "Enter with the route tool sets the start at the crosshair")
		near(
			world_distance(a.g.pos[a.from_node], a.view.center),
			0,
			600,
			"on a road near the centre of the view",
		)
		// Pan a long way and set the destination.
		a.view.center.x += 900.0 / view_scale(a.view)
		a.view.center.y += 500.0 / view_scale(a.view)
		frame(a, off)
		press_enter(a, off)
		check(a.to_node >= 0, "and again for the destination")
		check(a.route.ok, "giving a route from the keyboard alone: %s", a.route.why)

		a.tool = .Marker
		n := len(a.sc.markers)
		press_enter(a, off)
		check(len(a.sc.markers) == n + 1, "Enter with the marker tool drops one")
		a.tool = .Pan
		press_enter(a, off)
		check(len(a.sc.markers) == n + 1, "and with no tool armed it does nothing")
	}

	// Clearing removes the annotations but not the data.
	{
		clear_annotations(a)
		check(len(a.sc.markers) == 0, "clearing removes the markers")
		check(len(a.sc.measure) == 0, "and the measurement")
		check(!a.route.ok, "and the route")
		check(len(a.m.features) > 0, "but not the map")
	}

	// Every panel draws without falling over, and the frame is not blank.
	for panel in Panel {
		a.panel = panel
		frame(a, off)
	}
	nonbg := 0
	for y in 100 ..< 900 {
		for x in 400 ..< 1400 {
			if p.offscreen_pixel(off, x, y) != p.offscreen_pixel(off, 401, 101) {
				nonbg += 1
			}
		}
	}
	check(nonbg > 20_000, "the map panel is not a flat colour, %d pixels differ", nonbg)
}

test_format :: proc() {
	fmt.println("- formatting")
	check(format_distance(0) == "0 m", "zero distance")
	check(format_distance(12) == "10 m", "metres round to ten")
	check(format_distance(940) == "940 m", "under a kilometre stays in metres")
	check(format_distance(1500) == "1.5 km", "over a kilometre")
	check(format_distance(42_000) == "42 km", "and tens of kilometres lose the decimal")
	check(format_duration(30) == "30 s", "seconds")
	check(format_duration(90) == "2 min", "minutes")
	check(format_duration(3660) == "1 h 01 min", "hours, got %q", format_duration(3660))
	check(format_duration(7200) == "2 h 00 min", "whole hours, got %q", format_duration(7200))
	check(maneuver_text(.Left) == "Turn left onto", "the manoeuvre words")
	check(class_word(.Park) == "Park", "class words")
	check(class_road_word(.Motorway) == "the motorway", "road words")
}
