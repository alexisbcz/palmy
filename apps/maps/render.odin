package main

// Drawing the map into a `p.pixels` canvas.
//
// The shape of a frame:
//
//   1. background
//   2. for each paint layer, in `class_layer` order, the visible features of
//      one class at a time, batched into a single path and filled once. Roads
//      go round twice — every casing in the class, then every fill — because a
//      casing drawn per road would print over the junction the previous road's
//      fill just made.
//   3. the route, the measuring line, then the labels on top.
//
// Batching a whole class into one path is the main reason this holds a frame
// budget. The rasterizer's cost is dominated by maintaining the active edge
// list, and one pass over four thousand road segments costs far less than four
// thousand passes over one.
//
// Culling happens twice: a feature whose bounding box misses the viewport is
// never projected, and a polyline that survives that is clipped to the panel
// before it is stroked, so a motorway that crosses the world is two vertices
// by the time it reaches the filler.

import "core:fmt"
import "core:math"
import "core:time"
import p "palmy:."

// ---------------------------------------------------------------------------
// The palette
// ---------------------------------------------------------------------------

C_LAND :: 0xF4F1EA
C_OCEAN :: 0xA9CFE5
C_WATER :: 0xA9CFE5
C_WETLAND :: 0xC6DCCB
C_LANDUSE :: 0xEAE6DD
C_GRASS :: 0xD6E8C2
C_PARK :: 0xC9E7B2
C_FOREST :: 0xBADBA0
C_SAND :: 0xF3E7CB
C_PITCH :: 0xAFDCA2
C_BUILDING :: 0xDFD8C8
C_BUILDING_EDGE :: 0xBCB2A0
C_RAIL :: 0x9A9A96
C_PATH :: 0xA98B6C
C_ROUTE :: 0x1D6FE8
C_ROUTE_CASE :: 0xFFFFFF
C_MEASURE :: 0xD6422E
C_MARKER_A :: 0x1F8A4C
C_MARKER_B :: 0xC0392B
C_MARKER :: 0xE2453A

C_LABEL :: 0x31302C
C_LABEL_HALO :: 0xFFFFFF
C_LABEL_PLACE :: 0x1E1D1A
C_LABEL_WATER :: 0x3A7FAE
C_LABEL_PARK :: 0x3C7438
C_LABEL_ROAD :: 0x4A4842

// class_fill is the area colour for a class.
class_fill :: proc(c: Class) -> p.Color {
	switch c {
	case .Ocean:
		return p.hex(C_OCEAN)
	case .Water:
		return p.hex(C_WATER)
	case .Wetland:
		return p.hex(C_WETLAND)
	case .Landuse:
		return p.hex(C_LANDUSE)
	case .Grass:
		return p.hex(C_GRASS)
	case .Park:
		return p.hex(C_PARK)
	case .Forest:
		return p.hex(C_FOREST)
	case .Sand:
		return p.hex(C_SAND)
	case .Pitch:
		return p.hex(C_PITCH)
	case .Building:
		return p.hex(C_BUILDING)
	case .Unknown, .River, .Rail, .Path, .Service, .Residential_Road, .Tertiary, .Secondary,
	     .Primary, .Trunk, .Motorway, .City, .Town, .Village, .Suburb, .Poi:
		return p.hex(C_LANDUSE)
	}
	return p.hex(C_LANDUSE)
}

// road_colors returns the fill and the casing. The hierarchy is carried by
// hue as well as width: the fast roads are warm, everything else is white, so
// a route reads at a glance even where every road is the same width.
road_colors :: proc(c: Class) -> (fill, casing: p.Color) {
	switch c {
	case .Motorway:
		return p.hex(0xF9A85A), p.hex(0xD2873A)
	case .Trunk:
		return p.hex(0xFBC77D), p.hex(0xD5A151)
	case .Primary:
		return p.hex(0xFDD88B), p.hex(0xD9B362)
	case .Secondary:
		return p.hex(0xFFF3C0), p.hex(0xDAC98A)
	case .Tertiary:
		return p.hex(0xFFFFFF), p.hex(0xC6C1B2)
	case .Residential_Road:
		return p.hex(0xFFFFFF), p.hex(0xCCC7B8)
	case .Service:
		return p.hex(0xFFFFFF), p.hex(0xD4CFC0)
	case .Path:
		return p.hex(C_PATH), p.hex(0xEDE6DC)
	case .Rail:
		return p.hex(C_RAIL), p.hex(0xD8D8D4)
	case .River:
		return p.hex(C_WATER), p.hex(C_WATER)
	case .Unknown, .Ocean, .Water, .Wetland, .Landuse, .Grass, .Park, .Forest, .Sand, .Pitch,
	     .Building, .City, .Town, .Village, .Suburb, .Poi:
		return p.hex(0xFFFFFF), p.hex(0xD4D0C5)
	}
	return p.hex(0xFFFFFF), p.hex(0xD4D0C5)
}

// ---------------------------------------------------------------------------
// Preparing a loaded map for drawing
// ---------------------------------------------------------------------------

N_LAYERS :: 32

// Draw_Order is the paint order and the per-layer offsets into it, built once
// per load. The alternative — sorting the visible set every frame — costs more
// than drawing does.
Draw_Order :: struct {
	order:  [dynamic]i32,
	layer:  [N_LAYERS + 1]i32,
	anchor: [dynamic]World_Pt, // one per feature: where its label is anchored
}

draw_order_destroy :: proc(d: ^Draw_Order) {
	delete(d.order)
	delete(d.anchor)
	d^ = {}
}

// map_prepare normalises ring winding, builds the paint order and computes each
// feature's label anchor.
//
// Winding first, and it matters: a nonzero fill cuts a hole out of a polygon
// only when the hole runs the opposite way round from the outer ring, and
// GeoJSON does not require that — RFC 7946 states a preference and real files
// ignore it. So every ring is measured and flipped to the orientation this
// renderer needs, once, at load. Everything downstream can then assume it.
map_prepare :: proc(m: ^Map, d: ^Draw_Order) {
	// 1. Winding.
	for f in m.features {
		if f.geom != .Polygon {
			continue
		}
		for ri in f.first_ring ..< f.first_ring + f.ring_count {
			r := m.rings[ri]
			if r.count < 3 {
				continue
			}
			a := ring_signed_area(m, r)
			want_positive := !r.hole
			if (a > 0) != want_positive {
				// Reverse in place.
				lo := int(r.first)
				hi := int(r.first + r.count) - 1
				for lo < hi {
					m.pts[lo], m.pts[hi] = m.pts[hi], m.pts[lo]
					lo += 1
					hi -= 1
				}
			}
		}
	}

	// 2. Paint order: layer, then class (so a class is one contiguous batch),
	// then biggest first inside a class, so a small park draws over the big
	// one it sits in rather than under it.
	clear(&d.order)
	for _, i in m.features {
		append(&d.order, i32(i))
	}
	sort_order(m, d.order[:])

	for i in 0 ..= N_LAYERS {
		d.layer[i] = i32(len(d.order))
	}
	for k := len(d.order) - 1; k >= 0; k -= 1 {
		f := m.features[d.order[k]]
		l := clamp(class_layer(f.class), 0, N_LAYERS - 1)
		d.layer[l] = i32(k)
	}
	// A layer with no features inherits the next one's start, so the ranges
	// stay a partition.
	for i := N_LAYERS - 1; i >= 0; i -= 1 {
		if d.layer[i] > d.layer[i + 1] {
			d.layer[i] = d.layer[i + 1]
		}
	}

	// 3. Label anchors.
	resize(&d.anchor, len(m.features))
	for f, i in m.features {
		d.anchor[i] = feature_anchor(m, f)
	}
}

ring_signed_area :: proc(m: ^Map, r: Ring) -> f64 {
	s := 0.0
	for i in 0 ..< r.count {
		a := m.pts[r.first + i]
		b := m.pts[r.first + (i + 1) % r.count]
		s += a.x * b.y - b.x * a.y
	}
	return s / 2
}

// sort_key packs the paint order into one integer so the sort is a plain
// comparison:
//
//   bits 56..62  the class's paint layer
//   bits 48..55  the class itself, so one class is one contiguous batch
//   bits 44..47  the feature's own `layer` tag, which puts a bridge over the
//                road beside it without breaking the batch
//   bits 24..43  the size, log-quantised and inverted, so the biggest feature
//                of a class is painted first and the small one sits on top
//
// The layer tag deliberately sorts *inside* the class rather than outside it:
// `draw_features` walks the paint order in runs of one class, and a tag that
// could move a feature into another layer's range would split those runs.
@(private = "file")
sort_key :: proc(m: ^Map, i: i32) -> u64 {
	f := m.features[i]
	l := u64(clamp(class_layer(f.class), 0, 127))
	c := u64(f.class) & 0xff
	lt := u64(clamp(int(f.layer) + 8, 0, 15))
	sz := u64(clamp(int(math.log2(math.max(f.size, 1)) * 10000), 0, 1 << 20 - 1))
	return (l << 56) | (c << 48) | (lt << 44) | ((u64(1 << 20) - 1 - sz) << 24)
}

@(private = "file")
sort_order :: proc(m: ^Map, idx: []i32) {
	// Heapsort, for the same reason the rasterizer uses it: the input is very
	// nearly sorted already and a quicksort's worst case on that is quadratic.
	n := len(idx)
	if n < 2 {
		return
	}
	sift :: proc(m: ^Map, idx: []i32, lo, hi: int) {
		root := lo
		for {
			child := 2 * root + 1
			if child >= hi {
				return
			}
			if child + 1 < hi && sort_key(m, idx[child]) < sort_key(m, idx[child + 1]) {
				child += 1
			}
			if sort_key(m, idx[root]) >= sort_key(m, idx[child]) {
				return
			}
			idx[root], idx[child] = idx[child], idx[root]
			root = child
		}
	}
	for i := n / 2 - 1; i >= 0; i -= 1 {
		sift(m, idx, i, n)
	}
	for i := n - 1; i > 0; i -= 1 {
		idx[0], idx[i] = idx[i], idx[0]
		sift(m, idx, 0, i)
	}
}

// feature_anchor is where a label hangs off a feature, in world space, so that
// panning moves it rather than re-deciding it.
feature_anchor :: proc(m: ^Map, f: Feature) -> World_Pt {
	switch f.geom {
	case .Point:
		return m.pts[m.rings[f.first_ring].first]
	case .Polygon:
		// The area centroid of the outer rings. For a concave shape it can
		// fall outside, so it is pulled back into the bounding box.
		cx, cy, a := 0.0, 0.0, 0.0
		for ri in f.first_ring ..< f.first_ring + f.ring_count {
			r := m.rings[ri]
			if r.hole || r.count < 3 {
				continue
			}
			for i in 0 ..< r.count {
				q := m.pts[r.first + i]
				w := m.pts[r.first + (i + 1) % r.count]
				cr := q.x * w.y - w.x * q.y
				a += cr
				cx += (q.x + w.x) * cr
				cy += (q.y + w.y) * cr
			}
		}
		if abs(a) < 1e-18 {
			return (f.bbox.min + f.bbox.max) / 2
		}
		c := World_Pt{cx / (3 * a), cy / (3 * a)}
		c.x = clamp(c.x, f.bbox.min.x, f.bbox.max.x)
		c.y = clamp(c.y, f.bbox.min.y, f.bbox.max.y)
		return c
	case .Line:
		i, t := line_anchor(m, f, 0.5)
		return line_point(m, f, i, t)
	}
	return (f.bbox.min + f.bbox.max) / 2
}

// line_anchor finds the vertex index and fraction at a given fraction of the
// feature's first ring, measured in world length. Because it is a property of
// the geometry and not of the viewport, the same fraction is the same physical
// point at every zoom and every pan — which is what stops a street name from
// sliding along its street as you drag.
line_anchor :: proc(m: ^Map, f: Feature, frac: f64) -> (idx: int, t: f64) {
	r := m.rings[f.first_ring]
	if r.count < 2 {
		return int(r.first), 0
	}
	total := 0.0
	for i in 1 ..< r.count {
		total += world_len(m.pts[r.first + i - 1], m.pts[r.first + i])
	}
	if total <= 0 {
		return int(r.first), 0
	}
	want := total * clamp(frac, 0, 1)
	acc := 0.0
	for i in 1 ..< r.count {
		l := world_len(m.pts[r.first + i - 1], m.pts[r.first + i])
		if acc + l >= want {
			return int(r.first + i - 1), l > 0 ? (want - acc) / l : 0
		}
		acc += l
	}
	return int(r.first + r.count - 2), 1
}

line_point :: proc(m: ^Map, f: Feature, idx: int, t: f64) -> World_Pt {
	if idx + 1 >= len(m.pts) {
		return m.pts[idx]
	}
	a := m.pts[idx]
	b := m.pts[idx + 1]
	return a + (b - a) * t
}

@(private = "file")
world_len :: proc(a, b: World_Pt) -> f64 {
	dx := b.x - a.x
	dy := b.y - a.y
	return math.sqrt(dx * dx + dy * dy)
}

// ---------------------------------------------------------------------------
// The scene
// ---------------------------------------------------------------------------

Marker :: struct {
	w:     World_Pt,
	label: string,
	col:   p.Color,
	kind:  u8, // 0 plain, 1 route start, 2 route end
}

// Scene is everything the draw procedure reads. It lives in the application
// model, never on a stack: `p.pixels` keeps the pointer until the frame is
// painted, which is long after the procedure that built the tree returned.
Scene :: struct {
	m:        ^Map,
	ord:      ^Draw_Order,
	g:        ^Graph,
	fonts:    ^p.Fonts,
	view:     View,
	rast:     Raster,
	lab:      Labeller,

	route:    ^Route,
	markers:  [dynamic]Marker,
	measure:  [dynamic]World_Pt,
	highlight: Bbox,
	has_highlight: bool,

	show_labels:    bool,
	show_buildings: bool,
	show_route:     bool,
	show_chrome:    bool,
	// A crosshair at the centre of the view, shown while a tool is armed so
	// that Enter has a visible target.
	crosshair:      bool,
	profile:        bool, // print a per-class timing breakdown
	// Where the pointer is, for the coordinate read-out drawn over the map.
	cursor:         World_Pt,
	has_cursor:     bool,

	// The projection, memoised. `world_scale` is a `pow`, and calling it once
	// per vertex — which is what a procedure that takes only the View ends up
	// doing — cost more than the rasterizer did.
	pzoom:  f64,
	pscale: f64,
	// Metres per pixel at the view's latitude, which is what road widths are
	// derived from.
	mpp:    f64,

	// Scratch, reused every frame.
	sp:    [dynamic][2]f32,
	cl:    [dynamic][2]f32,
	runs:  [dynamic]Run,
	group: [dynamic]i32,

	// Instrumentation.
	ms_total:  f64,
	ms_labels: f64,
	ms_place:  f64,
	n_drawn:   int,
	n_labels:  int,
	n_seg:     int,
}

scene_destroy :: proc(s: ^Scene) {
	raster_destroy(&s.rast)
	labeller_destroy(&s.lab)
	delete(s.markers)
	delete(s.measure)
	delete(s.sp)
	delete(s.cl)
	delete(s.runs)
	delete(s.group)
}

// draw_scene is the procedure handed to `p.pixels`.
draw_scene :: proc(c: ^p.Canvas, r: p.Rect, s: ^Scene) {
	t0 := time.now()
	s.view.w = f64(r.w)
	s.view.h = f64(r.h)
	_, lat := world_to_lonlat(s.view.center)
	s.mpp = ground_resolution(lat, s.view.zoom)
	s.n_drawn, s.n_seg = 0, 0

	p.fill_rect(c, r, p.hex(C_LAND))
	if s.m == nil || len(s.m.features) == 0 {
		s.ms_total = time.duration_milliseconds(time.since(t0))
		return
	}

	draw_features(s, c, r)
	if s.show_route {
		draw_route(s, c, r)
	}
	draw_measure(s, c, r)
	if s.crosshair {
		draw_crosshair(c, r)
	}

	t1 := time.now()
	if s.show_labels {
		place_labels(s, r)
		s.ms_place = time.duration_milliseconds(time.since(t1))
		labels_draw(&s.lab, c, r, s.fonts)
		s.n_labels = len(s.lab.labels)
	} else {
		s.n_labels = 0
	}
	s.ms_labels = time.duration_milliseconds(time.since(t1))
	if s.show_chrome {
		draw_chrome(c, r, s, s.cursor, s.has_cursor)
	}
	s.ms_total = time.duration_milliseconds(time.since(t0))
}

// scene_scale is the memoised pixels-per-world-unit for this frame.
scene_scale :: #force_inline proc(s: ^Scene) -> f64 {
	if s.pzoom != s.view.zoom || s.pscale == 0 {
		s.pzoom = s.view.zoom
		s.pscale = world_scale(s.view.zoom)
	}
	return s.pscale
}

world_to_panel :: #force_inline proc(s: ^Scene, w: World_Pt, origin: [2]f32) -> [2]f32 {
	v := s.view
	sc := scene_scale(s)
	return {
		f32(f64(origin.x) + v.w / 2 + (w.x - v.center.x) * sc),
		f32(f64(origin.y) + v.h / 2 + (w.y - v.center.y) * sc),
	}
}

// simplify_step is the world-space distance below which two consecutive
// vertices land on the same pixel and the second can be dropped. Dropping them
// before stroking is the single biggest win when zoomed out: a coastline with
// three thousand vertices becomes forty.
@(private = "file")
simplify_step :: proc(s: ^Scene) -> f64 {
	return 0.7 / scene_scale(s)
}

@(private = "file")
draw_features :: proc(s: ^Scene, c: ^p.Canvas, rect: p.Rect) {
	origin := [2]f32{rect.x, rect.y}
	vmin, vmax := view_bounds(s.view, 96)
	vbox := Bbox{vmin, vmax}
	zoom := s.view.zoom
	m := s.m
	d := s.ord

	seg0 := 0
	for layer in 0 ..< N_LAYERS {
		lo := int(d.layer[layer])
		hi := int(d.layer[layer + 1])
		if lo >= hi {
			continue
		}
		k := lo
		for k < hi {
			cls := m.features[d.order[k]].class
			if is_place_class(cls) {
				break // places are labels, not geometry
			}
			// Collect the visible features of this class.
			clear(&s.group)
			for k < hi && m.features[d.order[k]].class == cls {
				fi := d.order[k]
				k += 1
				f := m.features[fi]
				if f32(zoom) < f.min_zoom {
					continue
				}
				if cls == .Building && !s.show_buildings {
					continue
				}
				if !bbox_overlaps(f.bbox, vbox) {
					continue
				}
				append(&s.group, fi)
			}
			if len(s.group) == 0 {
				continue
			}
			s.n_drawn += len(s.group)
			t0 := time.now()
			e0 := s.rast.rows
			ed0, ac0, bl0 := s.rast.n_edges, s.rast.n_active, s.rast.n_blend
			if is_area_class(cls) {
				draw_area_group(s, c, rect, origin, cls)
			} else {
				draw_line_group(s, c, rect, origin, cls)
			}
			if s.profile {
				fmt.printf(
					"    %-18v %4d feat %6d vert %6d rows %8d edge %9d act %9d blend %7.2f ms\n",
					cls,
					len(s.group),
					s.n_seg - seg0,
					s.rast.rows - e0,
					s.rast.n_edges - ed0,
					s.rast.n_active - ac0,
					s.rast.n_blend - bl0,
					time.duration_milliseconds(time.since(t0)),
				)
				seg0 = s.n_seg
			}
		}
	}
}

@(private = "file")
draw_area_group :: proc(s: ^Scene, c: ^p.Canvas, rect: p.Rect, origin: [2]f32, cls: Class) {
	m := s.m
	col := class_fill(cls)
	step := simplify_step(s)

	sc := scene_scale(s)
	ox := f64(origin.x) + s.view.w / 2 - s.view.center.x * sc
	oy := f64(origin.y) + s.view.h / 2 - s.view.center.y * sc

	raster_begin(&s.rast, rect)
	for fi in s.group {
		f := m.features[fi]
		for ri in f.first_ring ..< f.first_ring + f.ring_count {
			r := m.rings[ri]
			if r.count < 3 {
				continue
			}
			clear(&s.sp)
			// Simplify in world space before projecting: cheaper, and the
			// threshold is a pixel either way.
			prev := m.pts[r.first]
			append(&s.sp, [2]f32{f32(prev.x * sc + ox), f32(prev.y * sc + oy)})
			for i in 1 ..< r.count {
				q := m.pts[r.first + i]
				dx := q.x - prev.x
				dy := q.y - prev.y
				if dx * dx + dy * dy < step * step && i != r.count - 1 {
					continue
				}
				append(&s.sp, [2]f32{f32(q.x * sc + ox), f32(q.y * sc + oy)})
				prev = q
			}
			if len(s.sp) < 3 {
				continue
			}
			s.n_seg += len(s.sp)
			raster_move_to(&s.rast, s.sp[0].x, s.sp[0].y)
			for i in 1 ..< len(s.sp) {
				raster_line_to(&s.rast, s.sp[i].x, s.sp[i].y)
			}
			raster_close(&s.rast)
		}
	}
	raster_fill(&s.rast, c, col, .Nonzero)

	// A building gets a hairline edge once it is big enough for one to read.
	if cls == .Building && s.mpp < 1.4 {
		raster_begin(&s.rast, rect)
		for fi in s.group {
			f := m.features[fi]
			for ri in f.first_ring ..< f.first_ring + f.ring_count {
				r := m.rings[ri]
				if r.count < 3 {
					continue
				}
				clear(&s.sp)
				for i in 0 ..< r.count {
					append(&s.sp, world_to_panel(s, m.pts[r.first + i], origin))
				}
				stroke_polyline(&s.rast, s.sp[:], f32(clamp(0.8 / s.mpp, 0.8, 2.0)), true, false)
			}
		}
		raster_fill(&s.rast, c, p.hex(C_BUILDING_EDGE), .Nonzero)
	}
}

@(private = "file")
draw_line_group :: proc(s: ^Scene, c: ^p.Canvas, rect: p.Rect, origin: [2]f32, cls: Class) {
	m := s.m
	zoom := s.view.zoom
	w := road_width(cls, s.mpp)
	fill, casing := road_colors(cls)
	cased := has_casing(cls, w)
	case_w := w + math.max(1.7, w * 0.22)
	step := simplify_step(s)

	// Two passes over the same geometry. The casing pass first, for every road
	// in the class, then the fill — otherwise the second road's casing paints
	// over the junction the first road's fill just completed.
	sc := scene_scale(s)
	ox := f64(origin.x) + s.view.w / 2 - s.view.center.x * sc
	oy := f64(origin.y) + s.view.h / 2 - s.view.center.y * sc

	// The projected, simplified geometry is built once and both passes stroke
	// it, rather than projecting every vertex twice. `s.cl`/`s.runs` hold the
	// clipped runs, so the casing and the fill also share the clipping work.
	clear(&s.cl)
	clear(&s.runs)
	grow := math.max(cased ? case_w : w, 2)
	for fi in s.group {
		f := m.features[fi]
		for ri in f.first_ring ..< f.first_ring + f.ring_count {
			r := m.rings[ri]
			if r.count < 2 {
				continue
			}
			clear(&s.sp)
			prev := m.pts[r.first]
			append(&s.sp, [2]f32{f32(prev.x * sc + ox), f32(prev.y * sc + oy)})
			for i in 1 ..< r.count {
				q := m.pts[r.first + i]
				dx := q.x - prev.x
				dy := q.y - prev.y
				if dx * dx + dy * dy < step * step && i != r.count - 1 {
					continue
				}
				append(&s.sp, [2]f32{f32(q.x * sc + ox), f32(q.y * sc + oy)})
				prev = q
			}
			clip_polyline(s.sp[:], p.rect_inset(rect, -grow), &s.cl, &s.runs)
		}
	}
	for run in s.runs {
		s.n_seg += run.count
	}

	passes := cased ? 2 : 1
	for pass in 0 ..< passes {
		width := pass == 0 && cased ? case_w : w
		col := pass == 0 && cased ? casing : fill
		raster_begin(&s.rast, rect)
		for run in s.runs {
			pts := s.cl[run.first:][:run.count]
			stroke_polyline(&s.rast, pts, width, false, width > 1.6)
			if width > 2 {
				stroke_caps(&s.rast, pts, width)
			}
		}
		raster_fill(&s.rast, c, col, .Nonzero)
	}

	// Railways get sleeper ticks once they are wide enough to show them.
	if cls == .Rail && w > 1.4 {
		raster_begin(&s.rast, rect)
		for fi in s.group {
			f := m.features[fi]
			for ri in f.first_ring ..< f.first_ring + f.ring_count {
				r := m.rings[ri]
				clear(&s.sp)
				for i in 0 ..< r.count {
					append(&s.sp, world_to_panel(s, m.pts[r.first + i], origin))
				}
				tick_along(&s.rast, s.sp[:], rect, math.max(8, w * 3), w * 2.6, math.max(0.8, w * 0.5))
			}
		}
		raster_fill(&s.rast, c, p.hex(0xF2F2F0), .Nonzero)
	}
}

// tick_along places short perpendicular bars at a fixed pixel spacing, which
// is how a railway is drawn and how a one-way arrow could be.
@(private = "file")
tick_along :: proc(r: ^Raster, pts: [][2]f32, clip: p.Rect, spacing, length, width: f32) {
	if len(pts) < 2 {
		return
	}
	carry := f32(0)
	for i in 0 ..< len(pts) - 1 {
		a, b := pts[i], pts[i + 1]
		dx, dy := b.x - a.x, b.y - a.y
		l := math.sqrt(dx * dx + dy * dy)
		if l < 1e-4 {
			continue
		}
		ux, uy := dx / l, dy / l
		t := spacing - carry
		for t < l {
			cx := a.x + ux * t
			cy := a.y + uy * t
			if p.rect_contains(p.rect_inset(clip, -length), cx, cy) {
				hx, hy := -uy * length / 2, ux * length / 2
				stroke_polyline(r, []([2]f32){{cx - hx, cy - hy}, {cx + hx, cy + hy}}, width, false, false)
			}
			t += spacing
		}
		carry = (carry + l) - math.floor((carry + l) / spacing) * spacing
	}
}

// ---------------------------------------------------------------------------
// Overlays
// ---------------------------------------------------------------------------

@(private = "file")
draw_route :: proc(s: ^Scene, c: ^p.Canvas, rect: p.Rect) {
	if s.route == nil || !s.route.ok || len(s.route.path) < 2 {
		return
	}
	origin := [2]f32{rect.x, rect.y}
	clear(&s.sp)
	for id in s.route.path {
		append(&s.sp, world_to_panel(s, s.g.pos[id], origin))
	}
	clear(&s.cl)
	clear(&s.runs)
	clip_polyline(s.sp[:], p.rect_inset(rect, -16), &s.cl, &s.runs)

	// Wide enough to sit on the road it follows, which means scaling with the
	// ground resolution the way a road width does rather than with the zoom
	// number. At street level a route line thinner than the street reads as a
	// stripe painted down the middle of it.
	w := f32(clamp(9.0 / s.mpp, 4, 26))
	for pass in 0 ..< 2 {
		raster_begin(&s.rast, rect)
		width := pass == 0 ? w + 3.4 : w
		for run in s.runs {
			pts := s.cl[run.first:][:run.count]
			stroke_polyline(&s.rast, pts, width, false, true)
			stroke_caps(&s.rast, pts, width)
		}
		raster_fill(&s.rast, c, pass == 0 ? p.hex(C_ROUTE_CASE) : p.hex(C_ROUTE), .Nonzero)
	}
}

// draw_crosshair marks where Enter will act.
@(private = "file")
draw_crosshair :: proc(c: ^p.Canvas, rect: p.Rect) {
	cx := rect.x + rect.w / 2
	cy := rect.y + rect.h / 2
	white := p.Color{255, 255, 255, 220}
	dark := p.hex(0x33322E)
	for pass in 0 ..< 2 {
		t := pass == 0 ? f32(3.0) : f32(1.2)
		col := pass == 0 ? white : dark
		p.fill_rect(c, {cx - 11, cy - t / 2, 22, t}, col)
		p.fill_rect(c, {cx - t / 2, cy - 11, t, 22}, col)
	}
	p.fill_circle(c, cx, cy, 3.4, white)
	p.fill_circle(c, cx, cy, 2.0, dark)
}

@(private = "file")
draw_measure :: proc(s: ^Scene, c: ^p.Canvas, rect: p.Rect) {
	if len(s.measure) < 1 {
		return
	}
	origin := [2]f32{rect.x, rect.y}
	clear(&s.sp)
	for w in s.measure {
		append(&s.sp, world_to_panel(s, w, origin))
	}
	if len(s.sp) >= 2 {
		raster_begin(&s.rast, rect)
		stroke_polyline(&s.rast, s.sp[:], 2.6, false, true)
		raster_fill(&s.rast, c, p.hex(C_ROUTE_CASE), .Nonzero)
		raster_begin(&s.rast, rect)
		stroke_polyline(&s.rast, s.sp[:], 1.6, false, true)
		raster_fill(&s.rast, c, p.hex(C_MEASURE), .Nonzero)
	}
	for q in s.sp {
		if !p.rect_contains(rect, q.x, q.y) {
			continue
		}
		p.fill_circle(c, q.x, q.y, 4.2, p.hex(C_ROUTE_CASE))
		p.fill_circle(c, q.x, q.y, 2.8, p.hex(C_MEASURE))
	}
}
