package main

// Label placement: choosing which labels appear and where.
//
// The contest is greedy over a fixed priority order, which is the standard way
// and the only one that can be made stable: a candidate is placed if all of its
// boxes are clear, and once placed it never moves. The whole design question is
// therefore what the order is and where the candidates come from, and both are
// answered the same way — from the data, never from the viewport. See the
// header of label.odin.
//
// Candidate geometry per kind:
//
//   place     a dot with the name beside it. Four positions are tried, right
//             first, which is what every map does.
//   area      centred on the polygon's centroid, horizontal, and only if the
//             polygon is wide enough on screen to carry the name.
//   street    along the line. One to four anchors at fixed fractions of the
//             line's own length, each tried in turn; the text is laid out
//             character by character along the arc, and the whole candidate is
//             rejected if the line bends too far under it or if the text would
//             read right to left.
//   building  horizontal on the centroid, at high zoom only.
//   marker    a dropped pin or a route endpoint. These always win: they are
//             the user's own annotations and hiding one would look like a bug.

import "core:fmt"
import "core:math"
import p "palmy:."

// LABEL_CAP is a safety valve, not a design limit: it bounds the work a single
// frame can do on data far denser than anything here, and it is set well above
// what the zoom thresholds let through so that it normally never binds.
//
// It has to be set high, because a cap *does* break pan stability: a candidate
// drifting into the margin takes a slot and pushes the label at the cap's edge
// out. Measured at a cap of 190, fourteen of twenty-eight labels in the middle
// of the viewport flickered over seven pixels of pan. Where the cap binds,
// that is the accepted cost of bounding the frame.
LABEL_CAP :: 600

// utf8_len is how many bytes a rune occupies when encoded.
utf8_len :: proc(r: rune) -> int {
	switch {
	case r < 0x80:
		return 1
	case r < 0x800:
		return 2
	case r < 0x10000:
		return 3
	}
	return 4
}

// Label text sizes. A map's type scale is tighter than an interface's: two
// points of difference has to be enough to signal a rank difference.
label_size :: proc(cls: Class, zoom: f64) -> (size: f32, wt: p.Font_Weight) {
	z := f32(zoom)
	switch cls {
	case .City:
		return clamp(11 + z * 0.75, 13, 23), .Semibold
	case .Town:
		return clamp(10 + z * 0.55, 12, 18), .Semibold
	case .Suburb:
		return clamp(9 + z * 0.40, 11, 15), .Medium
	case .Village:
		return clamp(9 + z * 0.35, 10.5, 14), .Medium
	case .Poi:
		return clamp(8 + z * 0.22, 10, 12.5), .Regular
	case .Ocean, .Water, .River:
		return clamp(9 + z * 0.30, 10.5, 15), .Medium
	case .Park, .Forest, .Grass, .Wetland, .Sand, .Pitch, .Landuse:
		return clamp(8.5 + z * 0.25, 10, 13.5), .Medium
	case .Motorway, .Trunk, .Primary:
		return clamp(8.5 + z * 0.22, 10, 13), .Medium
	case .Secondary, .Tertiary:
		return clamp(8.5 + z * 0.20, 9.5, 12.5), .Medium
	case .Residential_Road, .Service, .Path, .Rail:
		return clamp(8 + z * 0.18, 9, 11.5), .Regular
	case .Building:
		return 9.5, .Regular
	case .Unknown:
		return 10, .Regular
	}
	return 10, .Regular
}

label_color :: proc(cls: Class) -> p.Color {
	switch cls {
	case .City, .Town, .Suburb, .Village:
		return p.hex(C_LABEL_PLACE)
	case .Ocean, .Water, .River:
		return p.hex(C_LABEL_WATER)
	case .Park, .Forest, .Grass, .Pitch:
		return p.hex(C_LABEL_PARK)
	case .Motorway, .Trunk, .Primary, .Secondary, .Tertiary, .Residential_Road, .Service,
	     .Path, .Rail:
		return p.hex(C_LABEL_ROAD)
	case .Unknown, .Wetland, .Landuse, .Sand, .Building, .Poi:
		return p.hex(C_LABEL)
	}
	return p.hex(C_LABEL)
}

// place_labels runs the whole contest for one frame.
place_labels :: proc(s: ^Scene, rect: p.Rect) {
	l := &s.lab
	region := p.rect_inset(rect, -LABEL_MARGIN)
	labeller_begin(l, region)
	origin := [2]f32{rect.x, rect.y}
	m := s.m
	zoom := s.view.zoom

	// 1. The user's own annotations, placed before anything can block them.
	for mk, i in s.markers {
		q := world_to_panel(s, mk.w, origin)
		if !p.rect_contains(region, q.x, q.y) {
			continue
		}
		dot := f32(5.5)
		txt := mk.label
		size, wt := f32(11.5), p.Font_Weight.Semibold
		clear(&l.cbox)
		clear(&l.cchunk)
		met := p.font_metrics(s.fonts, size, .Sans, wt)
		tw := txt == "" ? 0 : p.text_width(s.fonts, txt, size, .Sans, wt)
		append(&l.cbox, Box{q.x - dot - 2, q.y - dot - 2, dot * 2 + 4, dot * 2 + 4})
		if txt != "" {
			bx := q.x + dot + 5
			by := q.y + met.ascent * 0.36
			append(&l.cbox, Box{bx - 2, by - met.ascent - 1, tw + 4, met.ascent + met.descent + 2})
			append(&l.cchunk, Chunk{first = 0, last = i32(len(txt)), x = bx, y = by, angle = 0})
		}
		bf, bc := boxes_insert(l, l.cbox[:])
		cf := i32(len(l.chunks))
		for ch in l.cchunk {
			append(&l.chunks, ch)
		}
		append(
			&l.labels,
			Label {
				text = txt,
				size = size,
				weight = wt,
				col = p.hex(C_LABEL_PLACE),
				halo = p.hex(C_LABEL_HALO),
				halo_width = 2.0,
				kind = .Marker,
				feat = i32(-1 - i),
				dot = dot,
				dot_x = q.x,
				dot_y = q.y,
				chunk_first = cf,
				chunk_count = i32(len(l.cchunk)),
				box_first = bf,
				box_count = bc,
			},
		)
	}

	// 1b. The map's own furniture. The scale bar and the coordinate read-out
	// are painted over the map, so they are entered into the collision index
	// as blockers before anything else competes — otherwise a street name runs
	// under the scale bar and neither can be read.
	if s.show_chrome {
		plate, ro, _, _, _ := chrome_rects(s, rect)
		clear(&l.cbox)
		append(&l.cbox, Box{plate.x - 3, plate.y - 3, plate.w + 6, plate.h + 6})
		append(&l.cbox, Box{ro.x - 3, ro.y - 3, ro.w + 6, ro.h + 6})
		bf, bc := boxes_insert(l, l.cbox[:])
		append(
			&l.labels,
			Label{text = "", kind = .Marker, feat = -1_000_000, box_first = bf, box_count = bc},
		)
	}

	// 2. Everything from the data, as candidates.
	clear(&l.cands)
	vmin, vmax := view_bounds(s.view, f64(LABEL_MARGIN))
	vbox := Bbox{vmin, vmax}
	for f, i in m.features {
		if f.name == "" {
			continue
		}
		if f32(zoom) < f.min_zoom {
			continue
		}
		if f.class == .Building && (!s.show_buildings || zoom < 17.2) {
			continue
		}
		// A class is drawn before it is labelled. A residential street is a
		// hairline at z13.5 and its name would be the widest thing on the
		// map; it earns a label at z15, when the street is wide enough to put
		// one on.
		if f32(zoom) < class_label_zoom(f.class) {
			continue
		}
		if !bbox_overlaps(f.bbox, vbox) {
			continue
		}
		kind: Label_Kind
		nseq := 1
		switch {
		case is_place_class(f.class):
			kind = .Place
		case f.class == .Building:
			kind = .Building
		case f.geom == .Line:
			kind = .Street
			nseq = street_anchor_count(s, m, f, origin)
			if nseq == 0 {
				continue
			}
		case:
			kind = .Area
		}
		// No bonus for having been placed last frame. That is worth stating,
		// because a hysteresis term is the obvious way to stop labels
		// flickering and here it is the *cause* of flicker.
		//
		// Placement is already a pure function of the geometry and the
		// viewport, and every decision in it — the candidate positions, the
		// sort key, the bend and reading-direction tests, the collision boxes
		// — is invariant under a translation of the viewport. So panning by a
		// pixel moves every candidate by a pixel and the contest has exactly
		// the same outcome. That is the stability guarantee, and it is
		// structural rather than statistical.
		//
		// Adding a bonus breaks it. Measured: with "placed last frame" sorted
		// ahead of everything else, a label that was placed gets to try its
		// *preferred* position rather than the fallback it had, which can land
		// on a lower-ranked label that had been fitting beside it. That label
		// then disappears, so next frame it has no bonus, so it is placed late
		// and fits again — a two-frame oscillation. One grass strip beside the
		// river did exactly this at z15, on and off every other pixel of pan.
		for k in 0 ..< nseq {
			append(
				&l.cands,
				Cand {
					feat = i32(i),
					key = f.rank - f32(k) * 0.004,
					kind = kind,
					anchor = f32(k + 1) / f32(nseq + 1),
					seq = i32(k),
				},
			)
		}
	}

	sort_cands(l.cands[:])

	// 3. The contest.
	//
	// Capped, because past a couple of hundred labels a map is a page of text
	// with some lines behind it, and because the cost of placing and drawing
	// one is not negligible. The cap is safe to apply here and nowhere else:
	// the candidate order is total and viewport-independent, so cutting it off
	// at a fixed count is as stable as the rest of the contest.
	for cd in l.cands {
		if len(l.labels) >= LABEL_CAP {
			break
		}
		l.n_tried += 1
		f := m.features[cd.feat]
		switch cd.kind {
		case .Place:
			try_point(s, rect, cd, f, true)
		case .Area:
			try_point(s, rect, cd, f, false)
		case .Building:
			try_point(s, rect, cd, f, false)
		case .Street:
			try_street(s, rect, cd, f)
		case .Marker:
		}
	}
	for lb in l.labels {
		if lb.feat >= 0 {
			l.cur[lb.feat] = true
		}
	}
	l.n_placed = len(l.labels)
	labeller_end(l)
}

// sort_cands orders by key descending, then by feature index and sequence
// ascending. The second half is what makes the order *total*: two features with
// the same rank must not swap places between frames, and a rank is a float that
// several features share exactly.
@(private = "file")
sort_cands :: proc(a: []Cand) {
	less :: proc(x, y: Cand) -> bool {
		if x.key != y.key {
			return x.key > y.key
		}
		if x.feat != y.feat {
			return x.feat < y.feat
		}
		return x.seq < y.seq
	}
	n := len(a)
	if n < 2 {
		return
	}
	sift :: proc(a: []Cand, lo, hi: int) {
		root := lo
		for {
			child := 2 * root + 1
			if child >= hi {
				return
			}
			if child + 1 < hi && less(a[child + 1], a[child]) {
				child += 1
			}
			if less(a[child], a[root]) {
				return
			}
			a[root], a[child] = a[child], a[root]
			root = child
		}
	}
	for i := n / 2 - 1; i >= 0; i -= 1 {
		sift(a, i, n)
	}
	for i := n - 1; i > 0; i -= 1 {
		a[0], a[i] = a[i], a[0]
		sift(a, 0, i)
	}
}

// ---------------------------------------------------------------------------
// Horizontal labels: places, areas, buildings
// ---------------------------------------------------------------------------

@(private = "file")
try_point :: proc(s: ^Scene, rect: p.Rect, cd: Cand, f: Feature, with_dot: bool) -> bool {
	l := &s.lab
	origin := [2]f32{rect.x, rect.y}
	region := p.rect_inset(rect, -LABEL_MARGIN)
	anchor := s.ord.anchor[cd.feat]
	q := world_to_panel(s, anchor, origin)
	if !p.rect_contains(region, q.x, q.y) {
		return false
	}
	size, wt := label_size(f.class, s.view.zoom)
	met := p.font_metrics(s.fonts, size, .Sans, wt)
	tw := p.text_width(s.fonts, f.name, size, .Sans, wt)
	if tw <= 0 {
		return false
	}

	// An area label is only worth placing when the area can carry it: a park
	// narrower than its own name labelled anyway is how a map turns to soup.
	if !with_dot {
		mn := world_to_panel(s, f.bbox.min, origin)
		mx := world_to_panel(s, f.bbox.max, origin)
		if f.geom == .Polygon && (mx.x - mn.x) < tw * 0.78 {
			return false
		}
		if f.class == .Building && (mx.x - mn.x) < tw * 1.05 {
			return false
		}
	}

	dot := with_dot ? place_dot_size(f.class, s.view.zoom) : 0
	pad := f32(2.5)
	// Candidate positions. Right of the dot first, then left, then above and
	// below; an area or a building is centred and only tried once.
	Try :: struct {
		bx, by: f32,
	}
	tries: [4]Try
	ntries := 1
	if with_dot {
		tries[0] = {q.x + dot + 5, q.y + met.ascent * 0.36}
		tries[1] = {q.x - dot - 5 - tw, q.y + met.ascent * 0.36}
		tries[2] = {q.x - tw / 2, q.y - dot - 4}
		tries[3] = {q.x - tw / 2, q.y + dot + 4 + met.ascent}
		ntries = 4
	} else {
		tries[0] = {q.x - tw / 2, q.y + met.ascent * 0.38}
	}

	for ti in 0 ..< ntries {
		t := tries[ti]
		clear(&l.cbox)
		if with_dot {
			append(&l.cbox, Box{q.x - dot - 1.5, q.y - dot - 1.5, dot * 2 + 3, dot * 2 + 3})
		}
		append(
			&l.cbox,
			Box {
				t.bx - pad,
				t.by - met.ascent - pad,
				tw + 2 * pad,
				met.ascent + met.descent + 2 * pad,
			},
		)
		if !boxes_free(l, l.cbox[:]) {
			continue
		}
		bf, bc := boxes_insert(l, l.cbox[:])
		cf := i32(len(l.chunks))
		append(&l.chunks, Chunk{first = 0, last = i32(len(f.name)), x = t.bx, y = t.by, angle = 0})
		append(
			&l.labels,
			Label {
				text = f.name,
				size = size,
				weight = wt,
				col = label_color(f.class),
				halo = p.hex(C_LABEL_HALO),
				halo_width = halo_for(f.class),
				kind = cd.kind,
				feat = cd.feat,
				dot = dot,
				dot_x = q.x,
				dot_y = q.y,
				chunk_first = cf,
				chunk_count = 1,
				box_first = bf,
				box_count = bc,
			},
		)
		return true
	}
	return false
}

@(private = "file")
place_dot_size :: proc(cls: Class, zoom: f64) -> f32 {
	switch cls {
	case .City:
		return clamp(f32(zoom) * 0.28, 3, 5.5)
	case .Town:
		return clamp(f32(zoom) * 0.22, 2.5, 4.5)
	case .Suburb:
		return 0 // a neighbourhood has no point, only a name
	case .Village:
		return clamp(f32(zoom) * 0.18, 2, 3.5)
	case .Poi:
		return 2.6
	case .Unknown, .Ocean, .Water, .Wetland, .Landuse, .Grass, .Park, .Forest, .Sand, .Pitch,
	     .Building, .River, .Rail, .Path, .Service, .Residential_Road, .Tertiary, .Secondary,
	     .Primary, .Trunk, .Motorway:
		return 0
	}
	return 0
}

@(private = "file")
halo_for :: proc(cls: Class) -> f32 {
	if is_place_class(cls) {
		return 2.2
	}
	return 1.7
}

// ---------------------------------------------------------------------------
// Labels along a line
// ---------------------------------------------------------------------------

// street_anchor_count is how many times a street's name is repeated along it.
// It depends on the projected length of the whole line, so it changes with zoom
// but not with panning — which is the property the stability test checks.
@(private = "file")
street_anchor_count :: proc(s: ^Scene, m: ^Map, f: Feature, origin: [2]f32) -> int {
	r := m.rings[f.first_ring]
	if r.count < 2 {
		return 0
	}
	// The projected length, from the world length and the scale: no need to
	// project every vertex to find out how long the line is.
	wl := 0.0
	for i in 1 ..< r.count {
		a := m.pts[r.first + i - 1]
		b := m.pts[r.first + i]
		dx, dy := b.x - a.x, b.y - a.y
		wl += math.sqrt(dx * dx + dy * dy)
	}
	px := wl * view_scale(s.view)
	size, wt := label_size(f.class, s.view.zoom)
	tw := f64(p.text_width(s.fonts, f.name, size, .Sans, wt))
	if tw <= 0 || px < tw * 1.25 {
		return 0
	}
	return clamp(int(px / (tw * 6.5)) + 1, 1, 3)
}

@(private = "file")
try_street :: proc(s: ^Scene, rect: p.Rect, cd: Cand, f: Feature) -> bool {
	l := &s.lab
	m := s.m
	origin := [2]f32{rect.x, rect.y}
	region := p.rect_inset(rect, -LABEL_MARGIN)
	size, wt := label_size(f.class, s.view.zoom)
	met := p.font_metrics(s.fonts, size, .Sans, wt)

	// Per-rune advances, so each character can be positioned along the arc.
	//
	// Measured one rune at a time and then scaled so the total matches the
	// kerned width of the whole string. The obvious way — `text_width_upto`
	// at every rune boundary — measures every prefix and is quadratic in the
	// name's length; with a few thousand street candidates per frame that one
	// line was over half the frame. Per-rune measurement loses the kerning
	// *between* characters, and rescaling spreads that error evenly over the
	// label instead of letting it accumulate at the end, which is the only
	// place it would be visible.
	tw := p.text_width(s.fonts, f.name, size, .Sans, wt)
	if tw <= 0 {
		return false
	}
	clear(&l.adv)
	clear(&l.bnd)
	raw := f32(0)
	for r, bi in f.name {
		append(&l.bnd, i32(bi))
		append(&l.adv, raw)
		raw += p.text_width(s.fonts, f.name[bi:][:utf8_len(r)], size, .Sans, wt)
	}
	append(&l.bnd, i32(len(f.name)))
	append(&l.adv, raw)
	nr := len(l.bnd) - 1
	if nr == 0 || raw <= 0 {
		return false
	}
	k := tw / raw
	for i in 0 ..< len(l.adv) {
		l.adv[i] *= k
	}

	// Try the feature's rings in order; a MultiLineString street gets its
	// label on whichever part has room.
	for ri in f.first_ring ..< f.first_ring + f.ring_count {
		r := m.rings[ri]
		if r.count < 2 {
			continue
		}
		clear(&l.pts)
		for i in 0 ..< r.count {
			append(&l.pts, world_to_panel(s, m.pts[r.first + i], origin))
		}
		// Cumulative screen length.
		clear(&l.cum)
		append(&l.cum, 0)
		for i in 1 ..< len(l.pts) {
			d := l.pts[i] - l.pts[i - 1]
			append(&l.cum, l.cum[i - 1] + math.sqrt(d.x * d.x + d.y * d.y))
		}
		total := l.cum[len(l.cum) - 1]
		if total < tw * 1.1 {
			continue
		}
		mid := total * cd.anchor
		start := mid - tw / 2
		if start < 2 || start + tw > total - 2 {
			continue
		}

		// Reading direction, and which way round the polyline is walked.
		//
		// A shallow label reads left to right, so the line is reversed when it
		// runs right to left. A steep one has no useful left-to-right sense —
		// a due-north street's direction has no sideways component at all, and
		// deciding on the sign of a sideways component that is almost zero
		// makes neighbouring streets in the same grid read in opposite
		// directions. So past 45 degrees the rule changes to "read upwards",
		// which is the convention for vertical labels in a Latin script and
		// keeps a grid's columns consistent with each other.
		pa, _ := arc_at(l.pts[:], start)
		pb, _ := arc_at(l.pts[:], start + tw)
		pts := l.pts[:]
		ddx := pb.x - pa.x
		ddy := pb.y - pa.y
		flip := abs(ddy) > abs(ddx) ? ddy > 0 : ddx < 0
		if flip {
			clear(&l.rev)
			for i := len(l.pts) - 1; i >= 0; i -= 1 {
				append(&l.rev, l.pts[i])
			}
			pts = l.rev[:]
			start = total - (start + tw)
		}

		if place_along(s, rect, region, cd, f, pts, start, size, wt, met, nr) {
			return true
		}
	}
	return false
}

// place_along lays the characters out and, if every box is clear, commits.
@(private = "file")
place_along :: proc(
	s: ^Scene,
	rect, region: p.Rect,
	cd: Cand,
	f: Feature,
	pts: [][2]f32,
	start: f32,
	size: f32,
	wt: p.Font_Weight,
	met: p.Metrics,
	nr: int,
) -> bool {
	l := &s.lab
	clear(&l.cbox)
	clear(&l.cchunk)

	// MAX_BEND is how far the line may turn under one label. Past about forty
	// degrees the baseline reads as broken rather than curved, and a label on a
	// hairpin is worse than no label.
	MAX_BEND :: f32(0.72) // radians
	ang0 := f32(0)
	inside := false

	for k in 0 ..< nr {
		x_at := start + l.adv[k]
		pos, ang := arc_at(pts, x_at)
		if k == 0 {
			ang0 = ang
		} else if abs(angle_diff(ang, ang0)) > MAX_BEND {
			return false
		}
		// Past a quarter turn the glyphs are genuinely inverted and the label
		// is worse than none. Exactly a quarter turn is fine and is what a
		// north-south street gets; the reversal in try_street decides which
		// quarter turn, and this catches a hairpin it cannot.
		if abs(ang) > math.PI / 2 + 0.03 {
			return false
		}
		append(
			&l.cchunk,
			Chunk{first = l.bnd[k], last = l.bnd[k + 1], x = pos.x, y = pos.y, angle = ang},
		)
		if p.rect_contains(region, pos.x, pos.y) {
			inside = true
		}
		// One collision box per character: an axis-aligned box around the
		// rotated glyph cell. Per character rather than per label because a
		// curved label's bounding box would reserve a great deal of empty map.
		cw := l.adv[k + 1] - l.adv[k]
		h := met.ascent + met.descent
		cs, sn := math.cos(ang), math.sin(ang)
		// Corners of the cell, relative to the pen origin.
		cx0, cy0 := f32(0), -met.ascent
		corners := [4][2]f32{{cx0, cy0}, {cx0 + cw, cy0}, {cx0 + cw, cy0 + h}, {cx0, cy0 + h}}
		minx, miny := f32(1e30), f32(1e30)
		maxx, maxy := f32(-1e30), f32(-1e30)
		for cn in corners {
			px := pos.x + cn.x * cs - cn.y * sn
			py := pos.y + cn.x * sn + cn.y * cs
			minx = math.min(minx, px)
			maxx = math.max(maxx, px)
			miny = math.min(miny, py)
			maxy = math.max(maxy, py)
		}
		append(&l.cbox, Box{minx - 1, miny - 1, maxx - minx + 2, maxy - miny + 2})
	}
	if !inside {
		return false
	}
	if !boxes_free(l, l.cbox[:]) {
		return false
	}
	bf, bc := boxes_insert(l, l.cbox[:])
	cf := i32(len(l.chunks))
	for ch in l.cchunk {
		append(&l.chunks, ch)
	}
	append(
		&l.labels,
		Label {
			text = f.name,
			size = size,
			weight = wt,
			col = label_color(f.class),
			halo = p.hex(C_LABEL_HALO),
			halo_width = halo_for(f.class),
			kind = .Street,
			feat = cd.feat,
			chunk_first = cf,
			chunk_count = i32(len(l.cchunk)),
			box_first = bf,
			box_count = bc,
		},
	)
	return true
}

// arc_at is the point and tangent angle at a given distance along a polyline.
// It walks from the start rather than binary-searching a cumulative table,
// because the caller may be walking a *reversed* copy of the polyline — the
// table would then be in the wrong order — and a street has a handful of
// vertices, so the walk is cheaper than keeping two tables in step.
arc_at :: proc(pts: [][2]f32, s: f32) -> (pos: [2]f32, ang: f32) {
	n := len(pts)
	if n == 0 {
		return {}, 0
	}
	if n == 1 {
		return pts[0], 0
	}
	run := f32(0)
	for i in 0 ..< n - 1 {
		d := pts[i + 1] - pts[i]
		l := math.sqrt(d.x * d.x + d.y * d.y)
		if run + l >= s || i == n - 2 {
			u := l > 1e-6 ? (s - run) / l : 0
			u = clamp(u, 0, 1)
			return pts[i] + (pts[i + 1] - pts[i]) * u, math.atan2(d.y, d.x)
		}
		run += l
	}
	return pts[n - 1], 0
}

angle_diff :: proc(a, b: f32) -> f32 {
	d := a - b
	for d > math.PI {
		d -= 2 * math.PI
	}
	for d < -math.PI {
		d += 2 * math.PI
	}
	return d
}

// ---------------------------------------------------------------------------
// The furniture drawn over the map: scale bar, cursor read-out, attribution
// ---------------------------------------------------------------------------

// chrome_rects is where the scale bar and the read-out plates sit. Both the
// painter and the labeller need them: the painter to draw them, the labeller to
// keep a street name from running underneath one.
chrome_rects :: proc(s: ^Scene, rect: p.Rect) -> (scale, readout: p.Rect, bar: f32, chosen: f64, label: string) {
	fonts := s.fonts
	mpp := s.mpp > 0 ? s.mpp : 1

	// Pick a round number of metres whose bar is at least 60 pixels.
	nice := [?]f64 {
		1, 2, 5, 10, 20, 50, 100, 200, 500,
		1000, 2000, 5000, 10_000, 20_000, 50_000, 100_000, 200_000, 500_000,
		1_000_000, 2_000_000, 5_000_000,
	}
	chosen = nice[0]
	for v in nice {
		if v / mpp >= 60 {
			chosen = v
			break
		}
		chosen = v
	}
	bar = math.min(f32(chosen / mpp), rect.w - 40)
	label = chosen >= 1000 ? fmt.tprintf("%g km", chosen / 1000) : fmt.tprintf("%g m", chosen)
	lw := p.text_width(fonts, label, 11, .Sans, .Medium)
	bx := rect.x + 14
	by := p.rect_bottom(rect) - 18
	scale = {bx - 7, by - 19, math.max(bar, lw) + 20, 28}

	line1 := fmt.tprintf("z %.2f", s.view.zoom)
	line2 := s.has_cursor ? "000.00000, 000.00000" : ""
	w1 := p.text_width(fonts, line1, 10.5, .Mono, .Regular)
	w2 := line2 == "" ? 0 : p.text_width(fonts, line2, 10.5, .Mono, .Regular)
	wmax := math.max(w1, w2)
	rx := p.rect_right(rect) - wmax - 24
	ry := p.rect_bottom(rect) - (line2 == "" ? 26 : 40)
	readout = {rx - 8, ry - 4, wmax + 20, line2 == "" ? 22 : 36}
	return
}

// draw_chrome is the overlay that is part of the map rather than part of the
// interface: a scale bar, the coordinates under the cursor, and the zoom. They
// are drawn into the canvas rather than laid out as elements because they have
// to sit over the pixels and follow the panel exactly.
draw_chrome :: proc(c: ^p.Canvas, rect: p.Rect, s: ^Scene, cursor: World_Pt, has_cursor: bool) {
	fonts := s.fonts
	plate, _, bar, _, label := chrome_rects(s, rect)
	bx := rect.x + 14
	by := p.rect_bottom(rect) - 18
	// A plate behind it, so the bar is legible over dark water.
	p.fill_round_rect(c, plate, {6, 6, 6, 6}, p.Color{255, 255, 255, 215})

	p.fill_rect(c, {bx, by, bar, 2.5}, p.hex(0x3A3936))
	p.fill_rect(c, {bx, by - 4, 2, 7}, p.hex(0x3A3936))
	p.fill_rect(c, {bx + bar - 2, by - 4, 2, 7}, p.hex(0x3A3936))
	p.draw_text(c, fonts, label, bx + 1, by - 6, 11, p.hex(0x3A3936), .Sans, .Medium)

	// The read-out, bottom right: the cursor's coordinates and the zoom.
	_, ro, _, _, _ := chrome_rects(s, rect)
	line1 := fmt.tprintf("z %.2f", s.view.zoom)
	line2 := ""
	if has_cursor {
		lon, la := world_to_lonlat(cursor)
		line2 = fmt.tprintf("%.5f, %.5f", la, lon)
	}
	rx := ro.x + 8
	ry := ro.y + 4
	p.fill_round_rect(c, ro, {6, 6, 6, 6}, p.Color{255, 255, 255, 215})
	p.draw_text(c, fonts, line1, rx, ry + 10, 10.5, p.hex(0x3A3936), .Mono, .Regular)
	if line2 != "" {
		p.draw_text(c, fonts, line2, rx, ry + 26, 10.5, p.hex(0x3A3936), .Mono, .Regular)
	}
}
