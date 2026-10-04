package main

// The map data model.
//
// One flat coordinate pool, one flat ring table, one feature table. A feature
// names a span of rings and a ring names a span of points, so loading a file is
// three appends and nothing is chased through pointers while drawing. All
// coordinates are normalised Mercator (see proj.odin) stored as f64 — f32 loses
// about a metre at city scale, which is visible as wobble when two streets
// should meet exactly.
//
// Feature classes are resolved once, at load, from the `properties` bag. The
// renderer then switches on an enum rather than comparing strings per frame.

import "core:math"
import "core:strings"

Geom :: enum u8 {
	Point,
	Line,
	Polygon,
}

// Class is the drawing and routing category. The order matters twice: the
// renderer draws in layer order (see `class_layer`), and routing only accepts
// the road classes.
Class :: enum u8 {
	Unknown,
	// Areas, painted bottom-up in this order.
	Ocean,
	Water, // lake, riverbank
	Wetland,
	Landuse, // residential, industrial
	Grass,
	Park,
	Forest,
	Sand,
	Pitch,
	Building,
	// Linear.
	River, // a waterway drawn as a line
	Rail,
	Path, // footway, cycleway
	Service,
	Residential_Road,
	Tertiary,
	Secondary,
	Primary,
	Trunk,
	Motorway,
	// Points.
	City,
	Town,
	Village,
	Suburb,
	Poi,
}

// is_road reports whether a class takes part in the routing graph.
is_road :: proc(c: Class) -> bool {
	switch c {
	case .Path, .Service, .Residential_Road, .Tertiary, .Secondary, .Primary, .Trunk, .Motorway:
		return true
	case .Unknown, .Ocean, .Water, .Wetland, .Landuse, .Grass, .Park, .Forest, .Sand,
	     .Pitch, .Building, .River, .Rail, .City, .Town, .Village, .Suburb, .Poi:
		return false
	}
	return false
}

is_area_class :: proc(c: Class) -> bool {
	switch c {
	case .Ocean, .Water, .Wetland, .Landuse, .Grass, .Park, .Forest, .Sand, .Pitch, .Building:
		return true
	case .Unknown, .River, .Rail, .Path, .Service, .Residential_Road, .Tertiary, .Secondary,
	     .Primary, .Trunk, .Motorway, .City, .Town, .Village, .Suburb, .Poi:
		return false
	}
	return false
}

is_place_class :: proc(c: Class) -> bool {
	switch c {
	case .City, .Town, .Village, .Suburb, .Poi:
		return true
	case .Unknown, .Ocean, .Water, .Wetland, .Landuse, .Grass, .Park, .Forest, .Sand, .Pitch,
	     .Building, .River, .Rail, .Path, .Service, .Residential_Road, .Tertiary, .Secondary,
	     .Primary, .Trunk, .Motorway:
		return false
	}
	return false
}

// Ring is a span of the coordinate pool. For a polygon the first ring of a
// feature is the outer boundary and the rest are holes; for a MultiPolygon the
// `hole` flag says which is which, because a feature may hold several outers.
Ring :: struct {
	first: i32,
	count: i32,
	hole:  bool,
}

// Bbox is a world-space extent, used for culling and for fit-to-feature.
Bbox :: struct {
	min, max: World_Pt,
}

bbox_empty :: proc() -> Bbox {
	return {{1e30, 1e30}, {-1e30, -1e30}}
}

bbox_add :: proc(b: ^Bbox, p: World_Pt) {
	b.min.x = math.min(b.min.x, p.x)
	b.min.y = math.min(b.min.y, p.y)
	b.max.x = math.max(b.max.x, p.x)
	b.max.y = math.max(b.max.y, p.y)
}

bbox_union :: proc(a, b: Bbox) -> Bbox {
	return {
		{math.min(a.min.x, b.min.x), math.min(a.min.y, b.min.y)},
		{math.max(a.max.x, b.max.x), math.max(a.max.y, b.max.y)},
	}
}

bbox_valid :: proc(b: Bbox) -> bool {
	return b.max.x >= b.min.x && b.max.y >= b.min.y
}

bbox_overlaps :: proc(a, b: Bbox) -> bool {
	return a.min.x <= b.max.x && a.max.x >= b.min.x && a.min.y <= b.max.y && a.max.y >= b.min.y
}

bbox_grow :: proc(b: Bbox, d: f64) -> Bbox {
	return {{b.min.x - d, b.min.y - d}, {b.max.x + d, b.max.y + d}}
}

Feature :: struct {
	geom:      Geom,
	class:     Class,
	name:      string, // owned by the Map's string arena
	ref:       string, // a road number, if the data carries one
	first_ring: i32,
	ring_count: i32,
	bbox:      Bbox,
	// Zoom range in which the feature is drawn. Derived from the class and
	// the feature's own size, so a small park disappears before a big one.
	min_zoom:  f32,
	// Label importance, 0..1. Higher wins a collision.
	rank:      f32,
	// Road attributes. `oneway` is +1 forward, -1 reversed, 0 both ways.
	oneway:    i8,
	speed:     f32, // km/h
	// Drawing order nudge from an OSM `layer` tag, so a bridge is over a
	// river rather than under it.
	layer:     i8,
	// Length in metres for lines, area in square metres for polygons. Both
	// are used for ranking and for the measure read-out.
	size:      f64,
}

Map :: struct {
	pts:      [dynamic]World_Pt,
	rings:    [dynamic]Ring,
	features: [dynamic]Feature,
	strings:  strings.Builder, // every name lives here; features hold slices
	bbox:     Bbox,
	source:   string,
	// Counts for the status line.
	n_points, n_lines, n_polys: int,
}

map_init :: proc(m: ^Map) {
	m.pts = make([dynamic]World_Pt)
	m.rings = make([dynamic]Ring)
	m.features = make([dynamic]Feature)
	m.strings = strings.builder_make()
	m.bbox = bbox_empty()
}

map_destroy :: proc(m: ^Map) {
	delete(m.pts)
	delete(m.rings)
	delete(m.features)
	strings.builder_destroy(&m.strings)
	delete(m.source)
	m^ = {}
}

map_clear :: proc(m: ^Map) {
	clear(&m.pts)
	clear(&m.rings)
	clear(&m.features)
	strings.builder_reset(&m.strings)
	m.bbox = bbox_empty()
	m.n_points, m.n_lines, m.n_polys = 0, 0, 0
}

// map_intern copies a string into the map's arena and returns a slice of it.
//
// The builder may reallocate as it grows, which would dangle every slice handed
// out before. So names are not read until loading has finished: `map_intern`
// returns an offset-based handle resolved by `map_str`. Keeping the two apart
// is the only thing that makes a single arena safe here.
Str :: struct {
	off, len: i32,
}

map_intern :: proc(m: ^Map, s: string) -> Str {
	if s == "" {
		return {}
	}
	off := i32(strings.builder_len(m.strings))
	strings.write_string(&m.strings, s)
	return {off, i32(len(s))}
}

map_str :: proc(m: ^Map, h: Str) -> string {
	if h.len == 0 {
		return ""
	}
	all := strings.to_string(m.strings)
	if int(h.off) + int(h.len) > len(all) {
		return ""
	}
	return all[h.off:][:h.len]
}

// Builder collects one feature at a time. It exists so the parsers do not each
// have to know about ring spans and bounding boxes.
Builder :: struct {
	m:     ^Map,
	// The feature under construction.
	f:     Feature,
	nameh: Str,
	refh:  Str,
	open:  bool,
	// Names cannot be resolved while the arena is still growing, so they are
	// recorded as handles and patched in at `builder_finish`.
	pend:  [dynamic]struct {
		idx:   int,
		name:  Str,
		ref:   Str,
	},
}

builder_init :: proc(b: ^Builder, m: ^Map) {
	b.m = m
	b.pend = make([dynamic]struct {
		idx:  int,
		name: Str,
		ref:  Str,
	})
}

builder_destroy :: proc(b: ^Builder) {
	delete(b.pend)
}

// begin_feature starts a feature. Rings are then appended with
// `begin_ring`/`add_point`, and `end_feature` commits it.
begin_feature :: proc(b: ^Builder, geom: Geom, class: Class, name, ref: string) {
	b.f = Feature {
		geom       = geom,
		class      = class,
		first_ring = i32(len(b.m.rings)),
		bbox       = bbox_empty(),
	}
	b.nameh = map_intern(b.m, name)
	b.refh = map_intern(b.m, ref)
	b.open = true
}

begin_ring :: proc(b: ^Builder, hole := false) {
	append(&b.m.rings, Ring{first = i32(len(b.m.pts)), count = 0, hole = hole})
	b.f.ring_count += 1
}

add_point :: proc(b: ^Builder, lon, lat: f64) {
	if len(b.m.rings) == 0 {
		begin_ring(b)
	}
	w := lonlat_to_world(lon, lat)
	append(&b.m.pts, w)
	b.m.rings[len(b.m.rings) - 1].count += 1
	bbox_add(&b.f.bbox, w)
}

add_world :: proc(b: ^Builder, w: World_Pt) {
	if len(b.m.rings) == 0 {
		begin_ring(b)
	}
	append(&b.m.pts, w)
	b.m.rings[len(b.m.rings) - 1].count += 1
	bbox_add(&b.f.bbox, w)
}

// end_feature commits, or discards a feature with no usable geometry.
end_feature :: proc(b: ^Builder) -> bool {
	if !b.open {
		return false
	}
	b.open = false
	// Drop degenerate rings from the tail and reject an empty feature.
	for b.f.ring_count > 0 {
		r := b.m.rings[b.f.first_ring + b.f.ring_count - 1]
		need := i32(b.f.geom == .Point ? 1 : (b.f.geom == .Line ? 2 : 3))
		if r.count >= need {
			break
		}
		resize(&b.m.pts, int(r.first))
		resize(&b.m.rings, int(b.f.first_ring + b.f.ring_count - 1))
		b.f.ring_count -= 1
	}
	if b.f.ring_count == 0 || !bbox_valid(b.f.bbox) {
		resize(&b.m.rings, int(b.f.first_ring))
		return false
	}

	b.f.size = feature_measure(b.m, b.f)
	feature_derive(&b.f)
	append(&b.m.features, b.f)
	append(&b.pend, struct {
		idx:  int,
		name: Str,
		ref:  Str,
	}{len(b.m.features) - 1, b.nameh, b.refh})
	b.m.bbox = bbox_union(b.m.bbox, b.f.bbox)
	switch b.f.geom {
	case .Point:
		b.m.n_points += 1
	case .Line:
		b.m.n_lines += 1
	case .Polygon:
		b.m.n_polys += 1
	}
	return true
}

// builder_finish resolves the interned names. Nothing may append to the string
// arena after this.
builder_finish :: proc(b: ^Builder) {
	for e in b.pend {
		b.m.features[e.idx].name = map_str(b.m, e.name)
		b.m.features[e.idx].ref = map_str(b.m, e.ref)
	}
	clear(&b.pend)
}

// feature_measure is length in metres for a line and area in square metres for
// a polygon. Mercator is conformal but not equal-area, so the area is corrected
// by cos(lat) squared at the feature's own latitude — exact enough for ranking
// a park against a car park.
feature_measure :: proc(m: ^Map, f: Feature) -> f64 {
	switch f.geom {
	case .Point:
		return 0
	case .Line:
		total := 0.0
		for ri in f.first_ring ..< f.first_ring + f.ring_count {
			r := m.rings[ri]
			for i in 1 ..< r.count {
				total += world_distance(m.pts[r.first + i - 1], m.pts[r.first + i])
			}
		}
		return total
	case .Polygon:
		// Shoelace in world units, then scaled to metres.
		acc := 0.0
		for ri in f.first_ring ..< f.first_ring + f.ring_count {
			r := m.rings[ri]
			if r.count < 3 {
				continue
			}
			s := 0.0
			for i in 0 ..< r.count {
				a := m.pts[r.first + i]
				b := m.pts[r.first + (i + 1) % r.count]
				s += a.x * b.y - b.x * a.y
			}
			acc += r.hole ? -abs(s / 2) : abs(s / 2)
		}
		_, lat := world_to_lonlat((f.bbox.min + f.bbox.max) / 2)
		mpu := EARTH_CIRCUMFERENCE * math.cos(clamp(lat, -MAX_LAT, MAX_LAT) * math.PI / 180)
		return math.max(0, acc) * mpu * mpu
	}
	return 0
}

// feature_derive fills in the zoom range, the rank and the default speed from
// the class and the measured size. Keeping it in one place means a GeoJSON
// feature and an OSM way end up ranked the same way.
feature_derive :: proc(f: ^Feature) {
	if f.speed == 0 {
		f.speed = class_speed(f.class)
	}
	f.min_zoom = class_min_zoom(f.class)
	f.rank = class_rank(f.class)

	// A big area survives further out than a small one; a long street outranks
	// a cul-de-sac. Both are a log of the size so the effect is gentle.
	switch f.geom {
	case .Polygon:
		if f.size > 0 {
			// 1 km^2 at zoom 10, each factor of 4 smaller costs a zoom level.
			z := 10 + math.log2(1_000_000 / math.max(f.size, 1)) / 2
			f.min_zoom = math.max(f.min_zoom, f32(clamp(z, 1, 20)))
			f.rank += f32(clamp(math.log10(math.max(f.size, 1)) / 14, 0, 0.1))
		}
	case .Line:
		if f.size > 0 {
			f.rank += f32(clamp(math.log10(math.max(f.size, 1)) / 50, 0, 0.08))
		}
	case .Point:
	}
	if f.class == .Ocean {
		f.min_zoom = 0 // the sea is never too small to draw
	}
	if f.class == .Building {
		f.min_zoom = math.max(f.min_zoom, 15.5)
	}
}

// class_min_zoom is the zoom at which a class first appears.
class_min_zoom :: proc(c: Class) -> f32 {
	switch c {
	case .Ocean:
		return 0
	case .Water, .River:
		return 5
	case .Landuse:
		return 11
	case .Park, .Forest, .Grass, .Wetland, .Sand:
		return 9
	case .Pitch:
		return 15
	case .Building:
		return 15.5
	case .Motorway, .Trunk:
		return 5
	case .Primary:
		return 8
	case .Secondary:
		return 10
	case .Tertiary:
		return 12
	case .Residential_Road:
		return 13.5
	case .Service:
		return 15
	case .Path:
		return 15
	case .Rail:
		return 9
	case .City:
		return 3
	case .Town:
		return 7
	case .Village:
		return 10
	case .Suburb:
		return 11
	case .Poi:
		return 15
	case .Unknown:
		return 13
	}
	return 13
}

// class_label_zoom is the zoom at which a class starts carrying its *name*,
// which is later than the zoom at which it is drawn. A street has to be wide
// enough for the label to belong to it.
class_label_zoom :: proc(c: Class) -> f32 {
	switch c {
	case .Residential_Road:
		return 15
	case .Service:
		return 16.5
	case .Path:
		return 17
	case .Tertiary:
		return 13.5
	case .Pitch:
		return 16.5
	case .Unknown, .Ocean, .Water, .Wetland, .Landuse, .Grass, .Park, .Forest, .Sand,
	     .Building, .River, .Rail, .Secondary, .Primary, .Trunk, .Motorway,
	     .City, .Town, .Village, .Suburb, .Poi:
		return 0
	}
	return 0
}

// class_rank orders labels. Places outrank streets, streets outrank buildings.
class_rank :: proc(c: Class) -> f32 {
	switch c {
	case .City:
		return 0.98
	case .Town:
		return 0.90
	case .Suburb:
		return 0.82
	case .Village:
		return 0.78
	case .Motorway:
		return 0.70
	case .Trunk:
		return 0.66
	case .Primary:
		return 0.62
	case .Secondary:
		return 0.56
	case .Water, .Ocean:
		return 0.52
	case .River:
		return 0.50
	case .Park, .Forest:
		return 0.48
	case .Tertiary:
		return 0.44
	case .Residential_Road:
		return 0.36
	case .Poi:
		return 0.30
	case .Service, .Path:
		return 0.22
	case .Rail:
		return 0.20
	case .Building:
		return 0.12
	case .Landuse, .Grass, .Wetland, .Sand, .Pitch:
		return 0.10
	case .Unknown:
		return 0.05
	}
	return 0.05
}

// class_speed is the default travel speed in km/h, used when the data does not
// carry a maxspeed. These are the figures the routing cost is built on.
class_speed :: proc(c: Class) -> f32 {
	switch c {
	case .Motorway:
		return 110
	case .Trunk:
		return 90
	case .Primary:
		return 65
	case .Secondary:
		return 50
	case .Tertiary:
		return 40
	case .Residential_Road:
		return 30
	case .Service:
		return 15
	case .Path:
		return 5
	case .Unknown, .Ocean, .Water, .Wetland, .Landuse, .Grass, .Park, .Forest, .Sand, .Pitch,
	     .Building, .River, .Rail, .City, .Town, .Village, .Suburb, .Poi:
		return 0
	}
	return 0
}

// MAX_SPEED is the fastest class, which the A* time heuristic divides by to
// stay admissible.
MAX_SPEED :: f32(110)

// class_layer is the painting order. Lower is painted first.
class_layer :: proc(c: Class) -> int {
	switch c {
	case .Ocean:
		return 0
	case .Landuse:
		return 1
	case .Grass:
		return 2
	case .Sand:
		return 2
	case .Forest:
		return 3
	case .Park:
		return 4
	case .Pitch:
		return 5
	case .Wetland:
		return 6
	case .Water:
		return 7
	case .River:
		return 8
	case .Building:
		return 9
	case .Rail:
		return 10
	case .Path:
		return 11
	case .Service:
		return 12
	case .Residential_Road:
		return 13
	case .Tertiary:
		return 14
	case .Secondary:
		return 15
	case .Primary:
		return 16
	case .Trunk:
		return 17
	case .Motorway:
		return 18
	case .Unknown:
		return 11
	case .City, .Town, .Village, .Suburb, .Poi:
		return 30
	}
	return 11
}

// class_width_m is how wide a road of this class actually is, in metres. A
// residential street is seven metres of carriageway, a motorway twenty-four
// with its shoulders.
class_width_m :: proc(c: Class) -> f32 {
	switch c {
	case .Motorway:
		return 26
	case .Trunk:
		return 19
	case .Primary:
		return 15
	case .Secondary:
		return 11
	case .Tertiary:
		return 9
	case .Residential_Road:
		return 7
	case .Service:
		return 4
	case .Path:
		return 2
	case .Rail:
		return 3.5
	case .River:
		return 22
	case .Unknown, .Ocean, .Water, .Wetland, .Landuse, .Grass, .Park, .Forest, .Sand, .Pitch,
	     .Building, .City, .Town, .Village, .Suburb, .Poi:
		return 6
	}
	return 6
}

// class_min_px is how thin a class is allowed to get. Below about a pixel a
// road stops being a line and becomes a grey wash, and this is also what
// carries the hierarchy when the city is zoomed out far enough that every road
// would otherwise round to the same hairline.
class_min_px :: proc(c: Class) -> f32 {
	switch c {
	case .Motorway:
		return 2.6
	case .Trunk:
		return 2.3
	case .Primary:
		return 2.0
	case .Secondary:
		return 1.7
	case .Tertiary:
		return 1.4
	case .Residential_Road:
		return 1.0
	case .Service:
		return 0.8
	case .Path:
		return 0.7
	case .Rail:
		return 0.9
	case .River:
		return 1.2
	case .Unknown, .Ocean, .Water, .Wetland, .Landuse, .Grass, .Park, .Forest, .Sand, .Pitch,
	     .Building, .City, .Town, .Village, .Suburb, .Poi:
		return 1.0
	}
	return 1.0
}

// road_width is the stroke width in pixels for a road class, given the ground
// resolution in metres per pixel.
//
// It is the road's real width divided by the scale, floored at the class's
// minimum. That is worth doing properly rather than fitting a curve to each
// class: a width that is a real measurement is right at every zoom by
// construction, follows a continuous zoom smoothly, and — the part a fitted
// ramp always gets wrong — is right at the deep end, where a street has to be
// wide enough to drive a route line down.
road_width :: proc(c: Class, mpp: f64) -> f32 {
	if mpp <= 0 {
		return class_min_px(c)
	}
	px := class_width_m(c) / f32(mpp)
	return clamp(px, class_min_px(c), 64)
}

// has_casing says whether a road is drawn as a dark outline plus a lighter
// fill. Only the classes wide enough for it to read.
has_casing :: proc(c: Class, width: f32) -> bool {
	if width < 1.6 {
		return false
	}
	switch c {
	case .Motorway, .Trunk, .Primary, .Secondary, .Tertiary, .Residential_Road:
		return true
	case .Unknown, .Ocean, .Water, .Wetland, .Landuse, .Grass, .Park, .Forest, .Sand, .Pitch,
	     .Building, .River, .Rail, .Path, .Service, .City, .Town, .Village, .Suburb, .Poi:
		return false
	}
	return false
}

// ---------------------------------------------------------------------------
// Tag classification, shared by the GeoJSON and OSM XML readers
// ---------------------------------------------------------------------------

// classify maps an OSM-style key/value pair to a class. GeoJSON exports from
// osmium, overpass, QGIS and Mapbox all use these keys, so one table covers
// both formats.
classify :: proc(key, value: string, geom: Geom) -> (Class, bool) {
	switch key {
	case "highway":
		switch value {
		case "motorway", "motorway_link":
			return .Motorway, true
		case "trunk", "trunk_link":
			return .Trunk, true
		case "primary", "primary_link":
			return .Primary, true
		case "secondary", "secondary_link":
			return .Secondary, true
		case "tertiary", "tertiary_link", "unclassified":
			return .Tertiary, true
		case "residential", "living_street":
			return .Residential_Road, true
		case "service", "track":
			return .Service, true
		case "footway", "path", "cycleway", "pedestrian", "steps", "bridleway":
			return .Path, true
		}
		return .Residential_Road, true
	case "waterway":
		switch value {
		case "riverbank", "dock":
			return .Water, true
		case "river", "stream", "canal", "drain", "ditch":
			return geom == .Polygon ? .Water : .River, true
		}
		return .River, true
	case "natural":
		switch value {
		case "water", "bay", "strait":
			return .Water, true
		case "coastline":
			return .Ocean, true
		case "wood", "forest", "scrub":
			return .Forest, true
		case "wetland", "marsh":
			return .Wetland, true
		case "beach", "sand", "dune":
			return .Sand, true
		case "grassland", "heath", "meadow":
			return .Grass, true
		}
	case "landuse":
		switch value {
		case "forest", "wood":
			return .Forest, true
		case "grass", "meadow", "village_green", "allotments", "orchard", "farmland":
			return .Grass, true
		case "reservoir", "basin":
			return .Water, true
		case "recreation_ground", "cemetery":
			return .Park, true
		case "residential", "commercial", "retail", "industrial", "construction":
			return .Landuse, true
		}
		return .Landuse, true
	case "leisure":
		switch value {
		case "park", "garden", "nature_reserve", "common":
			return .Park, true
		case "pitch", "playground", "sports_centre", "track", "golf_course":
			return .Pitch, true
		}
		return .Park, true
	case "building", "building:part":
		if value != "no" {
			return .Building, true
		}
	case "railway":
		switch value {
		case "rail", "light_rail", "subway", "tram", "narrow_gauge", "monorail":
			return .Rail, true
		}
	case "place":
		switch value {
		case "city", "metropolis":
			return .City, true
		case "town":
			return .Town, true
		case "village", "hamlet", "isolated_dwelling":
			return .Village, true
		case "suburb", "quarter", "neighbourhood", "borough", "city_block":
			return .Suburb, true
		}
		return .Village, true
	case "amenity", "shop", "tourism", "office", "historic":
		return .Poi, true
	// Non-OSM keys that GeoJSON exports from other tools use.
	case "class", "kind", "type", "fclass":
		// A bare class name, as Mapbox vector-tile derived GeoJSON writes.
		for k in ([?]string{"highway", "natural", "landuse", "leisure", "waterway", "place"}) {
			if c, ok := classify(k, value, geom); ok {
				return c, true
			}
		}
	}
	return .Unknown, false
}

// parse_oneway reads the OSM oneway vocabulary. Returns +1, -1 or 0.
parse_oneway :: proc(v: string) -> i8 {
	switch v {
	case "yes", "true", "1":
		return 1
	case "-1", "reverse":
		return -1
	}
	return 0
}
