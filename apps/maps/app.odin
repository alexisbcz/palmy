package main

// The application model and the input handling.
//
// The map panel reads the raw pointer against its own rectangle rather than
// going through palmy's hit testing, the same way videoedit's timeline does: a
// drag has to keep panning after the pointer leaves the element, and a wheel
// has to zoom about the cursor rather than scroll the nearest scrollable
// ancestor. The rectangle comes from the previous frame's layout, which is the
// same geometry palmy's own hit testing uses, so the two never disagree.
//
// Everything slow happens on a load, not in a frame: parsing, winding
// normalisation, the paint order, the search index and the routing graph are
// all built once in `load_file`. A frame projects, strokes and labels, and
// nothing else. There are no worker threads here because there is nothing for
// them to do — the only blocking operation is reading a file, and that happens
// when the user asks for it, not on a timer.

import "core:fmt"
import "core:math"
import "core:strings"
import "core:time"
import kit "kit:."
import p "palmy:."

Tool :: enum u8 {
	Pan,
	Marker,
	Measure,
	Route,
}

tool_name :: proc(t: Tool) -> string {
	switch t {
	case .Pan:
		return "Pan"
	case .Marker:
		return "Marker"
	case .Measure:
		return "Measure"
	case .Route:
		return "Route"
	}
	return ""
}

Panel :: enum u8 {
	Search,
	Route,
	Layers,
	Help,
}

Maps :: struct {
	win:    ^p.App,
	fonts:  ^p.Fonts,
	m:      Map,
	ord:    Draw_Order,
	g:      Graph,
	ix:     Search_Index,
	sc:     Scene,
	route:  Route,
	path:   string, // the file currently loaded

	// The camera, and the fly-to animation.
	view:   View,
	fly:    bool,
	fly_t:  f64,
	fly_from_c, fly_to_c: World_Pt,
	fly_from_z, fly_to_z: f64,

	// Interaction.
	tool:      Tool,
	dragging:  bool,
	drag_last: [2]f32,
	drag_moved: bool,
	map_rect:  p.Rect,
	map_id:    u64,
	cursor:    World_Pt,
	has_cursor: bool,

	// Search.
	q:       [dynamic]u8,
	hits:    [dynamic]Hit,
	sel:     int,
	searching: bool,
	// Set by the `/` shortcut and consumed by the toolbar, which is the only
	// place the field's node id exists. Focus belongs to palmy and is keyed by
	// node, so a key handler that runs before the tree is built cannot move it
	// itself — it can only leave a note.
	focus_search: bool,

	// Routing.
	from_node, to_node: i32,
	cost:    Cost_Mode,
	step_sel: int,

	panel:   Panel,
	status:  string,
	status_until: f64,
	pick:    kit.Pick,
	picking: bool,

	// Frame time, as a ring of the last 120 samples.
	ms:      [120]f32,
	ms_at:   int,
	ms_n:    int,
	load_ms: f64,
}

maps_init :: proc(a: ^Maps) {
	map_init(&a.m)
	labeller_init(&a.sc.lab)
	a.sc.m = &a.m
	a.sc.ord = &a.ord
	a.sc.g = &a.g
	a.sc.route = &a.route
	a.sc.show_labels = true
	a.sc.show_buildings = true
	a.sc.show_route = true
	a.from_node = -1
	a.to_node = -1
	a.sel = -1
	a.step_sel = -1
	a.cost = .Time
	a.view = {center = {0.5, 0.5}, zoom = 3, w = 1200, h = 800}
	a.q = make([dynamic]u8)
	a.hits = make([dynamic]Hit)
}

maps_destroy :: proc(a: ^Maps) {
	scene_destroy(&a.sc)
	route_destroy(&a.route)
	index_destroy(&a.ix)
	graph_destroy(&a.g)
	draw_order_destroy(&a.ord)
	map_destroy(&a.m)
	delete(a.q)
	delete(a.hits)
	delete(a.status)
	delete(a.path)
	kit.pick_destroy(&a.pick)
}

say :: proc(a: ^Maps, now: f64, msg: string) {
	delete(a.status)
	a.status = strings.clone(msg)
	a.status_until = now + 5
}

// ---------------------------------------------------------------------------
// Loading
// ---------------------------------------------------------------------------

// load_file reads a map file and rebuilds everything derived from it. The
// format is chosen by extension and then by sniffing the first non-space byte,
// because a file a user drops in may be called anything.
load_file :: proc(a: ^Maps, path: string, fit := true) -> (ok: bool, msg: string) {
	t0 := time.now()
	map_clear(&a.m)
	route_clear(&a.route)
	a.from_node, a.to_node = -1, -1
	clear(&a.sc.markers)
	clear(&a.sc.measure)

	lower := strings.to_lower(path, context.temp_allocator)
	n := 0
	err: Json_Err
	if strings.has_suffix(lower, ".osm") || strings.has_suffix(lower, ".xml") {
		cnt, oerr := load_osm_xml(&a.m, path)
		n = cnt
		if oerr != "" {
			return false, fmt.tprintf("%s: %s", kit.pick_base(path), oerr)
		}
	} else {
		n, err = load_geojson(&a.m, path)
		if err.msg != "" {
			if n == 0 {
				return false, fmt.tprintf("%s: %s at line %d", kit.pick_base(path), err.msg, err.line)
			}
			// A document that goes wrong half way through still has the
			// features it managed; say so rather than throwing them away.
			msg = fmt.tprintf(
				"%s: %s at line %d — kept %d features",
				kit.pick_base(path),
				err.msg,
				err.line,
				n,
			)
		}
	}
	if n == 0 {
		return false, msg != "" ? msg : fmt.tprintf("%s holds no usable features", kit.pick_base(path))
	}

	rebuild(a)
	delete(a.path)
	a.path = strings.clone(path)
	if fit {
		view_fit(&a.view, a.m.bbox.min, a.m.bbox.max)
	}
	a.load_ms = time.duration_milliseconds(time.since(t0))
	if msg == "" {
		msg = fmt.tprintf(
			"%s — %d features, %d nodes, %.0f ms",
			kit.pick_base(path),
			len(a.m.features),
			graph_node_count(&a.g),
			a.load_ms,
		)
	}
	return true, msg
}

// rebuild derives the paint order, the graph and the search index from
// whatever is in the Map. Called after any load.
rebuild :: proc(a: ^Maps) {
	map_prepare(&a.m, &a.ord)
	graph_build(&a.g, &a.m)
	index_build(&a.ix, &a.m)
	clear(&a.hits)
	a.sel = -1
}

// ---------------------------------------------------------------------------
// The camera
// ---------------------------------------------------------------------------

// fly_to starts the animation that takes the view to a bounding box. An
// instant jump loses the user: on a map, where you came from is information.
fly_to :: proc(a: ^Maps, b: Bbox) {
	target := a.view
	if b.max.x - b.min.x < 1e-9 && b.max.y - b.min.y < 1e-9 {
		target.center = b.min
		target.zoom = math.max(a.view.zoom, 16)
	} else {
		view_fit(&target, b.min, b.max, 90)
		target.zoom = math.min(target.zoom, 18)
	}
	a.fly = true
	a.fly_t = 0
	a.fly_from_c = a.view.center
	a.fly_to_c = target.center
	a.fly_from_z = a.view.zoom
	a.fly_to_z = target.zoom
}

FLY_SECONDS :: 0.55

fly_step :: proc(a: ^Maps, dt: f64) {
	if !a.fly {
		return
	}
	a.fly_t += dt / FLY_SECONDS
	t := clamp(a.fly_t, 0, 1)
	// Ease in and out. The zoom is interpolated in log space — which is what
	// `zoom` already is — so the apparent speed is even rather than lurching.
	e := t < 0.5 ? 4 * t * t * t : 1 - math.pow(-2 * t + 2, 3) / 2
	a.view.center = a.fly_from_c + (a.fly_to_c - a.fly_from_c) * e
	a.view.zoom = a.fly_from_z + (a.fly_to_z - a.fly_from_z) * e
	view_clamp(&a.view)
	if t >= 1 {
		a.fly = false
	}
}

// ---------------------------------------------------------------------------
// Input
// ---------------------------------------------------------------------------

// sync_view_size copies the panel's real size into the camera.
//
// It has to happen before any input is handled, not when the panel is painted:
// `screen_to_world` divides by the viewport's width, so a camera still holding
// the size it was initialised with turns every cursor read-out and every
// click-to-place into a position off by half the difference. The panel's size
// is only known from the previous frame's layout, which is where it comes from.
sync_view_size :: proc(a: ^Maps) {
	if a.map_rect.w > 0 && a.map_rect.h > 0 {
		a.view.w = f64(a.map_rect.w)
		a.view.h = f64(a.map_rect.h)
	}
}

handle_map_mouse :: proc(a: ^Maps, ui: ^p.Ctx) {
	r := a.map_rect
	if r.w <= 0 || r.h <= 0 {
		return
	}
	mp := p.mouse_pos(ui)
	inside := p.rect_contains(r, mp.x, mp.y)

	a.has_cursor = inside
	if inside {
		a.cursor = screen_to_world(a.view, f64(mp.x - r.x), f64(mp.y - r.y))
	}

	// Wheel: zoom about the cursor. palmy reports the wheel for the frame
	// regardless of what is under it, so the rectangle test is ours to make.
	if inside {
		wh := p.wheel(ui)
		if wh.y != 0 {
			a.fly = false
			view_zoom_at(&a.view, f64(-wh.y) * 0.42, f64(mp.x - r.x), f64(mp.y - r.y))
			p.redraw(ui)
		}
	}

	if p.mouse_down(ui) {
		if !a.dragging && inside {
			a.dragging = true
			a.drag_moved = false
			a.drag_last = mp
			a.fly = false
		} else if a.dragging {
			d := mp - a.drag_last
			if d.x != 0 || d.y != 0 {
				s := view_scale(a.view)
				a.view.center -= {f64(d.x) / s, f64(d.y) / s}
				view_clamp(&a.view)
				a.drag_last = mp
				if abs(d.x) + abs(d.y) > 1 {
					a.drag_moved = true
				}
				p.redraw(ui)
			}
		}
		return
	}

	if a.dragging {
		was_drag := a.drag_moved
		a.dragging = false
		a.drag_moved = false
		if !was_drag && inside {
			map_click(a, ui, screen_to_world(a.view, f64(mp.x - r.x), f64(mp.y - r.y)))
		}
	}
}

// map_click is what a click on the map means, which depends on the tool.
map_click :: proc(a: ^Maps, ui: ^p.Ctx, w: World_Pt) {
	now := f64(p.elapsed(ui))
	switch a.tool {
	case .Pan:
		// A click with no tool selected identifies what is there, which is
		// what a map should answer first.
		if _, d, on_road := identify_at(a, w); on_road {
			say(a, now, fmt.tprintf("%s from the nearest road", format_distance(d)))
		} else {
			lon, lat := world_to_lonlat(w)
			say(a, now, fmt.tprintf("%.5f, %.5f", lat, lon))
		}
	case .Marker:
		// Numbered among the dropped pins only. The route's own A and B live
		// in the same list, and counting them made the first marker a user
		// dropped come out as "3".
		n := 1
		for mk in a.sc.markers {
			if mk.kind == 0 {
				n += 1
			}
		}
		append(&a.sc.markers, Marker{w = w, label = fmt.aprintf("%d", n), col = p.hex(C_MARKER)})
		say(a, now, fmt.tprintf("marker %d dropped", n))
	case .Measure:
		append(&a.sc.measure, w)
		say(a, now, fmt.tprintf("%s measured", format_distance(measure_total(a))))
	case .Route:
		// Snapped to a road you could actually drive down, not merely to the
		// nearest vertex: a service yard or a footpath stub is often closer
		// and routing from one is a dead end.
		id, why := snap_endpoint(a, w)
		if id < 0 {
			say(a, now, why)
			return
		}
		if a.from_node < 0 || a.to_node >= 0 {
			a.from_node = id
			a.to_node = -1
			route_clear(&a.route)
			say(a, now, "start set — click the destination")
		} else {
			a.to_node = id
			recompute_route(a, ui)
		}
		sync_route_markers(a)
	}
	p.redraw(ui)
}

// ---------------------------------------------------------------------------
// The entry points the window and the command line share
//
// A click with the Pan tool, a click with the Route tool and `maps nearest` /
// `maps route` are the same questions asked two ways, so they are answered by
// the same procedures: the window calls them from map_click, cli.odin calls
// them on a headless Maps. Keep the thresholds here and nowhere else.
// ---------------------------------------------------------------------------

// IDENTIFY_ROAD_M is how close a click has to be to a road to be "on" it.
IDENTIFY_ROAD_M :: 120
// SNAP_ROAD_M is how far a route endpoint may be snapped to reach a road.
SNAP_ROAD_M :: 400

// identify_at is what a click with no tool means: the nearest graph node and
// whether the point is close enough to a road to say so.
identify_at :: proc(a: ^Maps, w: World_Pt) -> (node: i32, dist_m: f64, on_road: bool) {
	id, d := graph_nearest(&a.g, w)
	return id, d, id >= 0 && d < IDENTIFY_ROAD_M
}

// snap_endpoint puts a route endpoint on a road you could actually drive down,
// not merely the nearest vertex: a service yard or a footpath stub is often
// closer and routing from one is a dead end.
snap_endpoint :: proc(a: ^Maps, w: World_Pt) -> (node: i32, why: string) {
	id, d := graph_nearest(&a.g, w, true)
	if id < 0 {
		return -1, "no road network loaded"
	}
	if d > SNAP_ROAD_M {
		return -1, "no road near there"
	}
	return id, ""
}

// route_between is the Route tool's two clicks in one call: snap both ends,
// set them as the endpoints, and route with the current cost mode.
route_between :: proc(a: ^Maps, from, to: World_Pt) -> (ok: bool, why: string) {
	s, why_s := snap_endpoint(a, from)
	if s < 0 {
		return false, fmt.tprintf("start: %s", why_s)
	}
	t, why_t := snap_endpoint(a, to)
	if t < 0 {
		return false, fmt.tprintf("destination: %s", why_t)
	}
	a.from_node, a.to_node = s, t
	sync_route_markers(a)
	recompute_route(a, nil)
	if !a.route.ok {
		return false, a.route.why
	}
	return true, ""
}

// load_generated puts the generated city into the model without writing it
// anywhere. The window falls back to it when the data directory cannot be
// written; the command line uses it so that a read never creates a file.
load_generated :: proc(a: ^Maps, fit := true) -> (ok: bool, msg: string) {
	t0 := time.now()
	map_clear(&a.m)
	route_clear(&a.route)
	a.from_node, a.to_node = -1, -1
	clear(&a.sc.markers)
	clear(&a.sc.measure)
	generate_city(&a.m)
	rebuild(a)
	delete(a.path)
	a.path = ""
	if fit {
		view_fit(&a.view, a.m.bbox.min, a.m.bbox.max)
	}
	a.load_ms = time.duration_milliseconds(time.since(t0))
	return len(a.m.features) > 0, fmt.tprintf("the generated city — %d features, in memory", len(a.m.features))
}

measure_total :: proc(a: ^Maps) -> f64 {
	t := 0.0
	for i in 1 ..< len(a.sc.measure) {
		t += world_distance(a.sc.measure[i - 1], a.sc.measure[i])
	}
	return t
}

recompute_route :: proc(a: ^Maps, ui: ^p.Ctx) {
	now := ui == nil ? 0 : f64(p.elapsed(ui))
	if a.from_node < 0 || a.to_node < 0 {
		return
	}
	t0 := time.now()
	route_find(&a.g, &a.m, a.from_node, a.to_node, a.cost, &a.route)
	ms := time.duration_milliseconds(time.since(t0))
	a.step_sel = -1
	if a.route.ok {
		a.panel = .Route
		say(
			a,
			now,
			fmt.tprintf(
				"%s, %s — %d steps, %d nodes explored in %.1f ms",
				format_distance(a.route.dist_m),
				format_duration(a.route.time_s),
				len(a.route.steps),
				a.route.explored,
				ms,
			),
		)
	} else {
		say(a, now, a.route.why)
	}
}

// sync_route_markers keeps the two endpoint pins in step with the endpoints.
// They are held at the front of the marker list so a dropped pin never has to
// be renumbered.
sync_route_markers :: proc(a: ^Maps) {
	// Drop any existing endpoint markers.
	k := 0
	for k < len(a.sc.markers) {
		if a.sc.markers[k].kind != 0 {
			delete(a.sc.markers[k].label)
			ordered_remove(&a.sc.markers, k)
		} else {
			k += 1
		}
	}
	if a.from_node >= 0 {
		inject_at(
			&a.sc.markers,
			0,
			Marker{w = a.g.pos[a.from_node], label = strings.clone("A"), col = p.hex(C_MARKER_A), kind = 1},
		)
	}
	if a.to_node >= 0 {
		append(
			&a.sc.markers,
			Marker{w = a.g.pos[a.to_node], label = strings.clone("B"), col = p.hex(C_MARKER_B), kind = 2},
		)
	}
}

clear_annotations :: proc(a: ^Maps) {
	for mk in a.sc.markers {
		delete(mk.label)
	}
	clear(&a.sc.markers)
	clear(&a.sc.measure)
	route_clear(&a.route)
	a.from_node, a.to_node = -1, -1
}

// handle_keys is everything the keyboard does outside a text field.
handle_keys :: proc(a: ^Maps, ui: ^p.Ctx) {
	now := f64(p.elapsed(ui))
	if a.searching {
		// While the search field has the keyboard, only navigation and escape
		// are taken; everything printable belongs to the field.
		if p.key_pressed(ui, p.KEY_ESCAPE) {
			a.searching = false
			a.focus_search = false
			p.set_focus(ui, 0)
		}
		n := len(a.hits)
		if n > 0 {
			for _ in 0 ..< p.key_count(ui, p.KEY_DOWN) {
				a.sel = min(a.sel + 1, n - 1)
			}
			for _ in 0 ..< p.key_count(ui, p.KEY_UP) {
				a.sel = max(a.sel - 1, 0)
			}
		}
		return
	}

	// Panning by keyboard. `key_count` rather than `key_pressed`, so holding
	// an arrow moves smoothly and a scripted demo's fast keys each count.
	step := f64(90) / view_scale(a.view)
	if nx := p.key_count(ui, p.KEY_LEFT); nx > 0 {
		a.view.center.x -= step * f64(nx)
		a.fly = false
	}
	if nx := p.key_count(ui, p.KEY_RIGHT); nx > 0 {
		a.view.center.x += step * f64(nx)
		a.fly = false
	}
	if nx := p.key_count(ui, p.KEY_UP); nx > 0 {
		a.view.center.y -= step * f64(nx)
		a.fly = false
	}
	if nx := p.key_count(ui, p.KEY_DOWN); nx > 0 {
		a.view.center.y += step * f64(nx)
		a.fly = false
	}
	view_clamp(&a.view)

	zc := p.key_count(ui, '+') + p.key_count(ui, '=')
	for _ in 0 ..< zc {
		view_zoom_at(&a.view, 0.5, a.view.w / 2, a.view.h / 2)
		a.fly = false
	}
	for _ in 0 ..< p.key_count(ui, '-') {
		view_zoom_at(&a.view, -0.5, a.view.w / 2, a.view.h / 2)
		a.fly = false
	}
	for _ in 0 ..< p.key_count(ui, p.KEY_PAGE_UP) {
		view_zoom_at(&a.view, 1, a.view.w / 2, a.view.h / 2)
	}
	for _ in 0 ..< p.key_count(ui, p.KEY_PAGE_DOWN) {
		view_zoom_at(&a.view, -1, a.view.w / 2, a.view.h / 2)
	}

	// Enter acts at the centre of the view, which is what makes every tool
	// usable without a pointer: pan and zoom to the place you mean, then
	// press Enter. A crosshair is drawn there while a tool is active so there
	// is no doubt about where "here" is. It is also the only way to drive the
	// map on a seat with no pointer, which is what a headless compositor is.
	if a.tool != .Pan && (p.key_pressed(ui, p.KEY_RETURN) || p.key_pressed(ui, p.KEY_KP_ENTER)) {
		map_click(a, ui, a.view.center)
	}

	// The side panel's four tabs.
	for panel, k in ([?]Panel{.Search, .Route, .Layers, .Help}) {
		if p.key_pressed(ui, u32('1') + u32(k)) {
			a.panel = panel
		}
	}

	if p.key_pressed(ui, '/') || p.shortcut(ui, 'f', {.Ctrl}) {
		// A fresh query. Clearing the buffer also resets the caret, which the
		// widget clamps to the text's length — and a stale caret is how a
		// second search ends up spliced into the middle of the first.
		clear(&a.q)
		clear(&a.hits)
		a.sel = -1
		a.panel = .Search
		a.searching = true
		a.focus_search = true
	}
	if p.key_pressed(ui, 'm') {
		a.tool = a.tool == .Marker ? .Pan : .Marker
		say(a, now, fmt.tprintf("%s tool", tool_name(a.tool)))
	}
	if p.key_pressed(ui, 'r') {
		a.tool = a.tool == .Route ? .Pan : .Route
		if a.tool == .Route {
			a.from_node, a.to_node = -1, -1
			route_clear(&a.route)
			sync_route_markers(a)
			say(a, now, "click the start of the route")
		}
	}
	if p.key_pressed(ui, 'd') {
		a.tool = a.tool == .Measure ? .Pan : .Measure
		if a.tool == .Measure {
			clear(&a.sc.measure)
		}
		say(a, now, fmt.tprintf("%s tool", tool_name(a.tool)))
	}
	if p.key_pressed(ui, 'l') {
		a.sc.show_labels = !a.sc.show_labels
		say(a, now, a.sc.show_labels ? "labels on" : "labels off")
	}
	if p.key_pressed(ui, 'b') {
		a.sc.show_buildings = !a.sc.show_buildings
		say(a, now, a.sc.show_buildings ? "buildings on" : "buildings off")
	}
	if p.key_pressed(ui, 't') {
		a.cost = a.cost == .Time ? .Distance : .Time
		say(a, now, a.cost == .Time ? "optimising travel time" : "optimising distance")
		if a.from_node >= 0 && a.to_node >= 0 {
			recompute_route(a, ui)
		}
	}
	if p.key_pressed(ui, 'c') {
		clear_annotations(a)
		say(a, now, "cleared")
	}
	if p.key_pressed(ui, 'h') || p.key_pressed(ui, '?') {
		a.panel = a.panel == .Help ? .Search : .Help
	}
	if p.key_pressed(ui, 'f') && !p.shortcut(ui, 'f', {.Ctrl}) {
		if bbox_valid(a.m.bbox) {
			fly_to(a, a.m.bbox)
		}
	}
	if p.shortcut(ui, 'o', {.Ctrl}) {
		begin_open(a)
	}
	if p.key_pressed(ui, p.KEY_ESCAPE) {
		if a.tool != .Pan {
			a.tool = .Pan
		} else {
			a.panel = .Search
		}
	}
}

MAP_FILTERS := [?]kit.Pick_Filter {
	{"Map data", {"geojson", "json", "osm", "xml"}},
	{"GeoJSON", {"geojson", "json"}},
	{"OSM XML", {"osm", "xml"}},
	kit.PICK_ALL,
}

begin_open :: proc(a: ^Maps) {
	dir := a.path == "" ? data_dir(context.temp_allocator) : kit.pick_parent(a.path)
	kit.pick_begin(
		&a.pick,
		.Open_File,
		{title = "Open Map Data", dir = dir, filters = MAP_FILTERS[:], confirm = "Open"},
	)
	a.picking = true
}

// record_frame keeps the last 120 frame times, which is what the status bar
// reports and what the --bench mode summarises.
record_frame :: proc(a: ^Maps, ms: f32) {
	a.ms[a.ms_at] = ms
	a.ms_at = (a.ms_at + 1) % len(a.ms)
	a.ms_n = min(a.ms_n + 1, len(a.ms))
}

frame_stats :: proc(a: ^Maps) -> (mean, worst: f32) {
	if a.ms_n == 0 {
		return 0, 0
	}
	sum := f32(0)
	for i in 0 ..< a.ms_n {
		sum += a.ms[i]
		worst = math.max(worst, a.ms[i])
	}
	return sum / f32(a.ms_n), worst
}

// startup_file decides what to show when the program opens with no argument:
// whatever is in the data directory, generating it the first time.
startup_file :: proc() -> (path: string, note: string) {
	p_, made, err := ensure_city()
	if err != "" {
		return "", err
	}
	if made {
		return p_, fmt.tprintf("generated a city at %s", p_)
	}
	return p_, ""
}
