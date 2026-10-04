package main

// Routing: a graph over the road network, A* across it, and the turn-by-turn
// directions that come out the other side.
//
// The graph. Every vertex of every road feature becomes a node, keyed by its
// coordinate quantised to 1e-7 degrees — the same precision the GeoJSON writer
// emits, so two ways that share a vertex in the file share a node here with no
// tolerance and no fuzz. Consecutive vertices become arcs, one or two
// depending on `oneway`. The adjacency is stored as CSR (a start offset per
// node into one flat arc array), which is both compact and the layout A* wants:
// a node's arcs are contiguous.
//
// What is *not* modelled, deliberately: an intersection is a shared vertex, not
// a shared location. Two roads that cross without a vertex in common — a bridge
// over a road, or two separately surveyed ways — do not connect. That is also
// how OSM works, and it is why the river in the generated city really does
// break the graph where there is no bridge.
//
// The cost. Two modes, and the UI says which is in use:
//
//   .Distance  metres. The heuristic is the great-circle distance to the
//              target, which is a lower bound on any path, so A* is admissible
//              and the answer is the exact shortest path.
//   .Time      seconds, from the per-class speed (or a `maxspeed` tag). The
//              heuristic is the great-circle distance over MAX_SPEED, likewise
//              a lower bound.
//
// The self-test asserts the distance mode against the generated city's
// arterial grid, where the shortest path is the Manhattan staircase and its
// cost can be summed independently.

import "core:fmt"
import "core:math"
import "core:strings"

Arc :: struct {
	to:    i32,
	len_m: f32,
	speed: f32, // km/h
	feat:  i32,
}

Graph :: struct {
	pos:    [dynamic]World_Pt,
	start:  [dynamic]i32, // len(pos)+1 entries
	arcs:   [dynamic]Arc,
	lookup: map[u64]i32,
	// Scratch, kept across searches so a route costs no allocation.
	dist:   [dynamic]f64,
	est:    [dynamic]f64,
	from:   [dynamic]i32,
	via:    [dynamic]i32,
	seen:   [dynamic]u32,
	stamp:  u32,
	heap:   [dynamic]Heap_Item,
	// Counters for the status line.
	n_edges_undirected: int,
	n_oneway: int,
}

Heap_Item :: struct {
	f:    f64,
	node: i32,
}

graph_destroy :: proc(g: ^Graph) {
	delete(g.pos)
	delete(g.start)
	delete(g.arcs)
	delete(g.lookup)
	delete(g.dist)
	delete(g.est)
	delete(g.from)
	delete(g.via)
	delete(g.seen)
	delete(g.heap)
	g^ = {}
}

// node_key quantises a world point to the precision the data is written at.
// Going through lon/lat rather than the world coordinate keeps the key stable
// across a write and a re-read of the same file.
node_key :: proc(w: World_Pt) -> u64 {
	lon, lat := world_to_lonlat(w)
	lonq := u64(math.round((clamp(lon, -180, 180) + 180) * 1e7))
	latq := u64(math.round((clamp(lat, -90, 90) + 90) * 1e7))
	return (lonq << 32) | (latq & 0xffff_ffff)
}

// graph_build walks every road feature and builds the adjacency.
graph_build :: proc(g: ^Graph, m: ^Map) {
	delete(g.lookup)
	clear(&g.pos)
	clear(&g.arcs)
	clear(&g.start)
	g.lookup = make(map[u64]i32)
	g.n_edges_undirected = 0
	g.n_oneway = 0

	// Pass one: nodes, and a temporary edge list.
	Pair :: struct {
		a, b:  i32,
		len_m: f32,
		speed: f32,
		feat:  i32,
		dir:   i8,
	}
	pairs := make([dynamic]Pair)
	defer delete(pairs)

	intern :: proc(g: ^Graph, w: World_Pt) -> i32 {
		k := node_key(w)
		if id, ok := g.lookup[k]; ok {
			return id
		}
		id := i32(len(g.pos))
		append(&g.pos, w)
		g.lookup[k] = id
		return id
	}

	for f, fi in m.features {
		if f.geom != .Line || !is_road(f.class) {
			continue
		}
		speed := f.speed > 0 ? f.speed : class_speed(f.class)
		for ri in f.first_ring ..< f.first_ring + f.ring_count {
			r := m.rings[ri]
			prev := i32(-1)
			for i in 0 ..< r.count {
				cur := intern(g, m.pts[r.first + i])
				if prev >= 0 && prev != cur {
					l := f32(world_distance(g.pos[prev], g.pos[cur]))
					if l > 0 {
						append(
							&pairs,
							Pair{a = prev, b = cur, len_m = l, speed = speed, feat = i32(fi), dir = f.oneway},
						)
					}
				}
				prev = cur
			}
		}
	}

	// Pass two: degrees, then CSR.
	n := len(g.pos)
	resize(&g.start, n + 1)
	for i in 0 ..= n {
		g.start[i] = 0
	}
	for e in pairs {
		fwd, back := arc_dirs(e.dir)
		if fwd {
			g.start[e.a + 1] += 1
		}
		if back {
			g.start[e.b + 1] += 1
		}
		g.n_edges_undirected += 1
		if e.dir != 0 {
			g.n_oneway += 1
		}
	}
	for i in 1 ..= n {
		g.start[i] += g.start[i - 1]
	}
	resize(&g.arcs, int(g.start[n]))
	fill := make([]i32, n, context.temp_allocator)
	for e in pairs {
		fwd, back := arc_dirs(e.dir)
		if fwd {
			at := g.start[e.a] + fill[e.a]
			g.arcs[at] = {to = e.b, len_m = e.len_m, speed = e.speed, feat = e.feat}
			fill[e.a] += 1
		}
		if back {
			at := g.start[e.b] + fill[e.b]
			g.arcs[at] = {to = e.a, len_m = e.len_m, speed = e.speed, feat = e.feat}
			fill[e.b] += 1
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

@(private = "file")
arc_dirs :: proc(oneway: i8) -> (fwd, back: bool) {
	switch oneway {
	case 1:
		return true, false
	case -1:
		return false, true
	}
	return true, true
}

graph_node_count :: proc(g: ^Graph) -> int {
	return len(g.pos)
}

graph_arc_count :: proc(g: ^Graph) -> int {
	return len(g.arcs)
}

// graph_find returns the node at an exact coordinate, or -1. The self-test
// uses it to name the junctions it knows the answer between.
graph_find :: proc(g: ^Graph, lon, lat: f64) -> i32 {
	if id, ok := g.lookup[node_key(lonlat_to_world(lon, lat))]; ok {
		return id
	}
	return -1
}

// graph_nearest is the node closest to a world point, which is what a click on
// the map resolves to. A linear scan: a city has tens of thousands of nodes and
// this runs once per click, not once per frame.
graph_nearest :: proc(g: ^Graph, w: World_Pt) -> (id: i32, dist_m: f64) {
	best := i32(-1)
	bd := f64(1e30)
	for q, i in g.pos {
		dx := q.x - w.x
		dy := q.y - w.y
		d := dx * dx + dy * dy
		if d < bd {
			bd = d
			best = i32(i)
		}
	}
	if best < 0 {
		return -1, 0
	}
	return best, world_distance(g.pos[best], w)
}

// ---------------------------------------------------------------------------
// A*
// ---------------------------------------------------------------------------

Cost_Mode :: enum u8 {
	Distance, // metres
	Time, // seconds
}

Maneuver :: enum u8 {
	Depart,
	Continue,
	Slight_Left,
	Left,
	Sharp_Left,
	Slight_Right,
	Right,
	Sharp_Right,
	U_Turn,
	Arrive,
}

maneuver_text :: proc(m: Maneuver) -> string {
	switch m {
	case .Depart:
		return "Head"
	case .Continue:
		return "Continue onto"
	case .Slight_Left:
		return "Bear left onto"
	case .Left:
		return "Turn left onto"
	case .Sharp_Left:
		return "Sharp left onto"
	case .Slight_Right:
		return "Bear right onto"
	case .Right:
		return "Turn right onto"
	case .Sharp_Right:
		return "Sharp right onto"
	case .U_Turn:
		return "Make a U-turn onto"
	case .Arrive:
		return "Arrive at"
	}
	return ""
}

Step :: struct {
	man:      Maneuver,
	name:     string,
	dist_m:   f64,
	time_s:   f64,
	at:       World_Pt,
	// The compass bearing the step leaves on, for the little arrow.
	heading:  f64,
	// The node range of the path this step covers.
	first, last: int,
}

Route :: struct {
	ok:       bool,
	why:      string,
	mode:     Cost_Mode,
	path:     [dynamic]i32, // node ids
	arcs:     [dynamic]i32, // arc index taken into path[i], for i >= 1
	dist_m:   f64,
	time_s:   f64,
	steps:    [dynamic]Step,
	explored: int,
	// The endpoints as the user gave them, so the markers can be drawn even
	// when no route exists.
	from_w, to_w: World_Pt,
}

route_destroy :: proc(r: ^Route) {
	delete(r.path)
	delete(r.arcs)
	delete(r.steps)
	r^ = {}
}

route_clear :: proc(r: ^Route) {
	clear(&r.path)
	clear(&r.arcs)
	clear(&r.steps)
	r.ok = false
	r.why = ""
	r.dist_m, r.time_s = 0, 0
	r.explored = 0
}

@(private = "file")
arc_cost :: proc(a: Arc, mode: Cost_Mode) -> f64 {
	switch mode {
	case .Distance:
		return f64(a.len_m)
	case .Time:
		sp := a.speed > 0 ? a.speed : 5
		return f64(a.len_m) / (f64(sp) * 1000 / 3600)
	}
	return f64(a.len_m)
}

@(private = "file")
heuristic :: proc(g: ^Graph, from, goal: i32, mode: Cost_Mode) -> f64 {
	d := world_distance(g.pos[from], g.pos[goal])
	switch mode {
	case .Distance:
		return d
	case .Time:
		return d / (f64(MAX_SPEED) * 1000 / 3600)
	}
	return d
}

// route_find runs A* from `s` to `t`. It handles the degenerate cases
// explicitly rather than letting them fall out of the loop: an empty graph, an
// out-of-range node, start equal to end, and no path at all are each a
// different answer and the UI shows a different thing for each.
route_find :: proc(g: ^Graph, m: ^Map, s, t: i32, mode: Cost_Mode, out: ^Route) {
	route_clear(out)
	out.mode = mode
	n := len(g.pos)
	if n == 0 {
		out.why = "the road network is empty"
		return
	}
	if s < 0 || t < 0 || int(s) >= n || int(t) >= n {
		out.why = "no road near one of the points"
		return
	}
	out.from_w = g.pos[s]
	out.to_w = g.pos[t]
	if s == t {
		// A zero-length route is a valid answer, not an error. One node, no
		// arcs, no distance, and a single "you are already there" step.
		append(&out.path, s)
		out.ok = true
		append(&out.steps, Step{man = .Arrive, name = "", dist_m = 0, time_s = 0, at = g.pos[s]})
		return
	}

	g.stamp += 1
	if g.stamp == 0 {
		// The stamp wrapped, so every seen marker has to be cleared once.
		for i in 0 ..< n {
			g.seen[i] = 0
		}
		g.stamp = 1
	}
	clear(&g.heap)
	g.dist[s] = 0
	g.from[s] = -1
	g.via[s] = -1
	g.seen[s] = g.stamp
	heap_push(&g.heap, {f = heuristic(g, s, t, mode), node = s})

	// `closed` is tracked in `est`: once a node is settled its final cost is
	// stored there, so a stale heap entry for it is recognised and dropped.
	for i in 0 ..< n {
		g.est[i] = -1
	}

	explored := 0
	found := false
	for len(g.heap) > 0 {
		it := heap_pop(&g.heap)
		u := it.node
		if g.est[u] >= 0 {
			continue // already settled through a cheaper entry
		}
		g.est[u] = g.dist[u]
		explored += 1
		if u == t {
			found = true
			break
		}
		for ai in g.start[u] ..< g.start[u + 1] {
			a := g.arcs[ai]
			nd := g.dist[u] + arc_cost(a, mode)
			if g.seen[a.to] == g.stamp && nd >= g.dist[a.to] {
				continue
			}
			g.seen[a.to] = g.stamp
			g.dist[a.to] = nd
			g.from[a.to] = u
			g.via[a.to] = ai
			heap_push(&g.heap, {f = nd + heuristic(g, a.to, t, mode), node = a.to})
		}
	}
	out.explored = explored
	if !found {
		out.why = "no route exists between those points"
		return
	}

	// Walk the predecessors back, then reverse.
	cur := t
	for cur >= 0 {
		append(&out.path, cur)
		if cur == s {
			break
		}
		append(&out.arcs, g.via[cur])
		cur = g.from[cur]
	}
	for i, j := 0, len(out.path) - 1; i < j; i, j = i + 1, j - 1 {
		out.path[i], out.path[j] = out.path[j], out.path[i]
	}
	for i, j := 0, len(out.arcs) - 1; i < j; i, j = i + 1, j - 1 {
		out.arcs[i], out.arcs[j] = out.arcs[j], out.arcs[i]
	}

	for ai in out.arcs {
		a := g.arcs[ai]
		out.dist_m += f64(a.len_m)
		sp := a.speed > 0 ? a.speed : 5
		out.time_s += f64(a.len_m) / (f64(sp) * 1000 / 3600)
	}
	out.ok = true
	build_steps(g, m, out)
}

// ---------------------------------------------------------------------------
// Turn-by-turn
// ---------------------------------------------------------------------------

// TURN_STRAIGHT is how far the bearing may change at a node before it counts
// as a turn rather than the road bending. Thirty degrees is generous, but a
// winding residential street changes bearing by twenty at every vertex and
// calling each of those a turn makes the directions useless.
TURN_STRAIGHT :: 30.0
TURN_SLIGHT :: 55.0
TURN_SHARP :: 130.0
TURN_UTURN :: 165.0

// classify_turn maps a signed bearing change to a manoeuvre. Negative is left.
classify_turn :: proc(delta: f64) -> Maneuver {
	a := abs(delta)
	switch {
	case a < TURN_STRAIGHT:
		return .Continue
	case a >= TURN_UTURN:
		return .U_Turn
	case a >= TURN_SHARP:
		return delta < 0 ? .Sharp_Left : .Sharp_Right
	case a >= TURN_SLIGHT:
		return delta < 0 ? .Left : .Right
	}
	return delta < 0 ? .Slight_Left : .Slight_Right
}

// build_steps turns the node path into instructions. Two things make this more
// than a loop over the vertices:
//
//   * A step is merged into the previous one when the road has the same name
//     and the bearing barely changed. Without that a winding street produces
//     one instruction per vertex.
//   * A turn onto a road with the *same* name is still a turn, because a grid's
//     named avenue can cross itself in the data; and a bend of more than
//     TURN_STRAIGHT on the same road is reported as a turn with no "onto",
//     which is what a driver needs at a right-angled kink.
build_steps :: proc(g: ^Graph, m: ^Map, r: ^Route) {
	clear(&r.steps)
	if len(r.path) < 2 {
		return
	}
	// A synthetic graph — the self-test's uniform grid — has no features
	// behind its arcs, so the feature index has to be checked rather than
	// trusted. Real data can carry the same hole: an arc whose way was
	// dropped by a partial parse.
	name_of :: proc(m: ^Map, g: ^Graph, ai: i32) -> string {
		fi := int(g.arcs[ai].feat)
		if fi < 0 || fi >= len(m.features) {
			return "the way"
		}
		f := m.features[fi]
		if f.name != "" {
			return f.name
		}
		if f.ref != "" {
			return f.ref
		}
		return class_road_word(f.class)
	}

	first_name := name_of(m, g, r.arcs[0])
	append(
		&r.steps,
		Step {
			man = .Depart,
			name = first_name,
			at = g.pos[r.path[0]],
			heading = world_bearing(g.pos[r.path[0]], g.pos[r.path[1]]),
			first = 0,
			last = 1,
		},
	)

	for i in 1 ..< len(r.path) - 1 {
		prev_arc := r.arcs[i - 1]
		next_arc := r.arcs[i]
		b_in := world_bearing(g.pos[r.path[i - 1]], g.pos[r.path[i]])
		b_out := world_bearing(g.pos[r.path[i]], g.pos[r.path[i + 1]])
		delta := angle_delta(b_in, b_out)
		nm := name_of(m, g, next_arc)
		same := nm == name_of(m, g, prev_arc)

		if same && abs(delta) < TURN_STRAIGHT {
			// The same road, still going the same way: extend the step.
			s := &r.steps[len(r.steps) - 1]
			s.last = i + 1
			continue
		}
		man := classify_turn(delta)
		if same && man == .Continue {
			s := &r.steps[len(r.steps) - 1]
			s.last = i + 1
			continue
		}
		append(
			&r.steps,
			Step {
				man = man,
				name = nm,
				at = g.pos[r.path[i]],
				heading = b_out,
				first = i,
				last = i + 1,
			},
		)
	}

	// Close the last step at the destination and add the arrival.
	if len(r.steps) > 0 {
		r.steps[len(r.steps) - 1].last = len(r.path) - 1
	}
	append(
		&r.steps,
		Step {
			man = .Arrive,
			name = "",
			at = g.pos[r.path[len(r.path) - 1]],
			first = len(r.path) - 1,
			last = len(r.path) - 1,
		},
	)

	// Fill in each step's own distance and time from the arcs it covers.
	for &s in r.steps {
		s.dist_m, s.time_s = 0, 0
		for k in s.first ..< s.last {
			a := g.arcs[r.arcs[k]]
			s.dist_m += f64(a.len_m)
			sp := a.speed > 0 ? a.speed : 5
			s.time_s += f64(a.len_m) / (f64(sp) * 1000 / 3600)
		}
	}
}

// class_road_word is what a step says when the road has no name at all.
class_road_word :: proc(c: Class) -> string {
	switch c {
	case .Motorway:
		return "the motorway"
	case .Trunk:
		return "the trunk road"
	case .Primary, .Secondary, .Tertiary:
		return "the road"
	case .Residential_Road:
		return "the street"
	case .Service:
		return "the service road"
	case .Path:
		return "the footpath"
	case .Unknown, .Ocean, .Water, .Wetland, .Landuse, .Grass, .Park, .Forest, .Sand, .Pitch,
	     .Building, .River, .Rail, .City, .Town, .Village, .Suburb, .Poi:
		return "the way"
	}
	return "the way"
}

// step_text is the full instruction line.
step_text :: proc(s: Step, allocator := context.temp_allocator) -> string {
	switch s.man {
	case .Depart:
		return fmt.aprintf(
			"Head %s on %s",
			compass_word(s.heading),
			s.name == "" ? "the road" : s.name,
			allocator = allocator,
		)
	case .Arrive:
		return strings.clone("Arrive at your destination", allocator)
	case .Continue:
		return fmt.aprintf("Continue on %s", s.name, allocator = allocator)
	case .Slight_Left, .Left, .Sharp_Left, .Slight_Right, .Right, .Sharp_Right, .U_Turn:
		return fmt.aprintf("%s %s", maneuver_text(s.man), s.name, allocator = allocator)
	}
	return ""
}

COMPASS := [?]string {
	"north", "north-east", "east", "south-east",
	"south", "south-west", "west", "north-west",
}

compass_word :: proc(b: f64) -> string {
	i := int(math.round(b / 45)) % 8
	if i < 0 {
		i += 8
	}
	return COMPASS[i]
}

// ---------------------------------------------------------------------------
// A binary heap
// ---------------------------------------------------------------------------

heap_push :: proc(h: ^[dynamic]Heap_Item, it: Heap_Item) {
	append(h, it)
	i := len(h) - 1
	for i > 0 {
		par := (i - 1) / 2
		if h[par].f <= h[i].f {
			break
		}
		h[par], h[i] = h[i], h[par]
		i = par
	}
}

heap_pop :: proc(h: ^[dynamic]Heap_Item) -> Heap_Item {
	top := h[0]
	last := pop(h)
	if len(h) == 0 {
		return top
	}
	h[0] = last
	i := 0
	n := len(h)
	for {
		l := 2 * i + 1
		if l >= n {
			break
		}
		c := l
		if l + 1 < n && h[l + 1].f < h[l].f {
			c = l + 1
		}
		if h[i].f <= h[c].f {
			break
		}
		h[i], h[c] = h[c], h[i]
		i = c
	}
	return top
}

// ---------------------------------------------------------------------------
// Formatting
// ---------------------------------------------------------------------------

format_distance :: proc(m: f64, allocator := context.temp_allocator) -> string {
	if m < 1 {
		return strings.clone("0 m", allocator)
	}
	if m < 950 {
		return fmt.aprintf("%d m", int(math.round(m / 10) * 10), allocator = allocator)
	}
	if m < 10_000 {
		return fmt.aprintf("%.1f km", m / 1000, allocator = allocator)
	}
	return fmt.aprintf("%.0f km", m / 1000, allocator = allocator)
}

format_duration :: proc(s: f64, allocator := context.temp_allocator) -> string {
	if s < 60 {
		return fmt.aprintf("%d s", int(s), allocator = allocator)
	}
	mins := int(math.round(s / 60))
	if mins < 60 {
		return fmt.aprintf("%d min", mins, allocator = allocator)
	}
	return fmt.aprintf("%d h %02d min", mins / 60, mins % 60, allocator = allocator)
}
