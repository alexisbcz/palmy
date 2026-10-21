package main

// Offscreen renders and the frame-time benchmark.
//
// A map can pass every assertion in selftest.odin and still have its roads
// under its water, its labels upside down or its parks the colour of the sea.
// None of that is a property you can assert; it is a property you have to look
// at. So `--shot` and `--sheet` render real frames through palmy's offscreen
// renderer and write PNGs, at exactly the size asked for, with no compositor
// and nothing on anybody's screen.
//
// `--bench` answers the other question: whether it holds a frame. It pans the
// view a pixel at a time at three zoom levels and reports the distribution of
// the time one frame of map drawing takes — not the whole UI, because the map
// panel is the part that could be slow.

import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"
import "core:time"
import p "palmy:."
import sc "shadcn:."

SHOT_W :: 1500
SHOT_H :: 940

FONT_DIR :: "/home/alex/Work/palmy/parity/web/public/fonts"
MONO_FALLBACKS := [?]string {
	"/usr/share/fonts/TTF/JetBrainsMonoNerdFont-Regular.ttf",
	"/usr/share/fonts/TTF/DejaVuSansMono.ttf",
	"/usr/share/fonts/liberation/LiberationMono-Regular.ttf",
}

// load_map_fonts mirrors what kit.start does to a window's font set. kit only
// offers it attached to a real window, so an offscreen render repeats it.
load_map_fonts :: proc(f: ^p.Fonts) {
	for pair in ([?]struct {
		file: string,
		wt:   p.Font_Weight,
	}{
		{"Geist-400.ttf", .Regular},
		{"Geist-500.ttf", .Medium},
		{"Geist-600.ttf", .Semibold},
		{"Geist-700.ttf", .Bold},
	}) {
		p.load_font(f, fmt.tprintf("%s/%s", FONT_DIR, pair.file), .Sans, pair.wt)
	}
	for path in MONO_FALLBACKS {
		if p.load_font(f, path, .Mono, .Regular) {
			p.load_font(f, path, .Mono, .Medium)
			p.load_font(f, path, .Mono, .Semibold)
			p.load_font(f, path, .Mono, .Bold)
			break
		}
	}
}

// shot_state loads the data and brings the model up to the point a screenshot
// is worth taking: a route computed, a search run, markers dropped.
@(private = "file")
shot_state :: proc(a: ^Maps, off: ^p.Offscreen, file: string) -> bool {
	maps_init(a)
	a.fonts = &off.fonts
	a.sc.fonts = &off.fonts
	a.sc.show_chrome = true

	path := file
	note := ""
	if path == "" {
		path, note = startup_file()
	}
	_ = note
	ok: bool
	msg: string
	if path == "" {
		// The data directory could not be written: render the generated
		// city from memory, as the window does.
		ok, msg = load_generated(a)
	} else {
		ok, msg = load_file(a, path)
	}
	if !ok {
		fmt.eprintfln("maps: %s", msg)
		return false
	}
	fmt.printfln("shot: %s", msg)
	return true
}

// shot renders one frame at a zoom level, with a route and a search result
// showing, and writes a PNG.
shot :: proc(out_path: string, zoom: f64, file: string) -> int {
	sc.register_shadcn_theme(false)
	p.set_text_gamma(1.8)
	w, h := SHOT_W, SHOT_H
	off := p.offscreen_create(w, h, 1, "w-full h-full bg-background text-foreground")
	defer p.offscreen_destroy(off)
	load_map_fonts(&off.fonts)

	a := new(Maps)
	defer free(a)
	if !shot_state(a, off, file) {
		return 1
	}
	defer maps_destroy(a)

	// Centre on the city and compute a route across it, so the screenshot
	// shows the features rather than an empty grid.
	setup_demo(a)
	r := render_frame(a, off, out_path, zoom, lonlat_to_world(CITY_LON, CITY_LAT))
	fmt.printfln(
		"shot: %s (%v) — z%.2f, %d features drawn, %d labels of %d tried, %.2f ms (%.2f in labels)",
		out_path,
		r.ok,
		zoom,
		r.drawn,
		r.placed,
		r.tried,
		r.ms,
		r.ms_labels,
	)
	return r.ok ? 0 : 1
}

Render_Info :: struct {
	ok:            bool,
	drawn:         int,
	placed, tried: int,
	ms, ms_labels: f64,
}

// render_frame draws whatever the model holds through the real interface into
// an offscreen and writes it as a PNG. It prints nothing: `--shot` and
// `maps render` each report it their own way, and under --json stdout belongs
// to the document. The model must already be loaded, with its fonts pointed
// at the offscreen's.
render_frame :: proc(a: ^Maps, off: ^p.Offscreen, out_path: string, zoom: f64, center: World_Pt) -> Render_Info {
	w, h := off.width, off.height
	a.view.center = center
	a.view.zoom = zoom
	a.view.w, a.view.h = f64(w - SIDE_W), f64(h - 19 - 48 - 28)

	// Two frames: the first establishes the panel's rectangle from the layout,
	// which the second one's input and chrome read.
	for _ in 0 ..< 2 {
		ui := p.offscreen_begin(off)
		if a.map_id != 0 {
			a.map_rect = p.rect_of(ui, a.map_id)
		}
		a.sc.view = a.view
		a.sc.show_route = a.route.ok
		draw_ui(a, ui)
		p.offscreen_end(off)
	}

	return Render_Info {
		ok = p.offscreen_write_png(off, out_path),
		drawn = a.sc.n_drawn,
		placed = a.sc.lab.n_placed,
		tried = a.sc.lab.n_tried,
		ms = a.sc.ms_total,
		ms_labels = a.sc.ms_labels,
	}
}

// setup_demo computes the route and search that the screenshots and the
// recording show, so every one of them is the same scene.
setup_demo :: proc(a: ^Maps) {
	// A route across the city, from the south west of the grid to the north
	// east, which crosses the river.
	s := grid_node(&a.g, 6, 2)
	t := grid_node(&a.g, 13, 10)
	if s >= 0 && t >= 0 {
		a.from_node, a.to_node = s, t
		sync_route_markers(a)
		recompute_route(a, nil)
	}
	a.panel = .Route
	set_query(a, "Harbour")
}

set_query :: proc(a: ^Maps, q: string) {
	clear(&a.q)
	append(&a.q, q)
	search(&a.ix, string(a.q[:]), &a.hits)
	a.sel = len(a.hits) > 0 ? 0 : -1
}

// sheet renders the map at every zoom worth looking at, into one directory.
// Reading these side by side is how the width ramps, the zoom thresholds and
// the label density were settled.
sheet :: proc(dir: string, file: string) -> int {
	sc.register_shadcn_theme(false)
	p.set_text_gamma(1.8)
	os.make_directory(dir)

	W :: 1200
	H :: 820
	off := p.offscreen_create(W, H, 1, "w-full h-full bg-white")
	defer p.offscreen_destroy(off)
	load_map_fonts(&off.fonts)

	a := new(Maps)
	defer free(a)
	if !shot_state(a, off, file) {
		return 1
	}
	defer maps_destroy(a)
	setup_demo(a)

	rect := p.Rect{0, 0, W, H}
	bad := 0
	for z in ([?]f64{4, 8, 11, 12.5, 14, 15.5, 16.5, 17.5, 18.5}) {
		a.view = {center = lonlat_to_world(CITY_LON, CITY_LAT), zoom = z, w = W, h = H}
		a.sc.view = a.view
		a.sc.show_route = a.route.ok
		a.sc.has_cursor = true
		a.sc.cursor = a.view.center
		ui := p.offscreen_begin(off)
		p.div(ui, "w-full h-full")
		p.end(ui)
		p.offscreen_end(off)
		// Draw the map alone, filling the canvas: a contact sheet is about the
		// cartography, not the chrome.
		cv := p.offscreen_canvas(off)
		draw_scene(cv, rect, &a.sc)
		path := fmt.tprintf("%s/z%04.1f.png", dir, z)
		if !p.offscreen_write_png(off, path) {
			bad += 1
		}
		fmt.printfln(
			"sheet: %s — %d features, %d labels, %d stroked vertices, %.2f ms (%.2f labels)",
			path,
			a.sc.n_drawn,
			a.sc.n_labels,
			a.sc.n_seg,
			a.sc.ms_total,
			a.sc.ms_labels,
		)
	}
	return bad == 0 ? 0 : 1
}

// ---------------------------------------------------------------------------
// The benchmark
// ---------------------------------------------------------------------------

BENCH_W :: 1162 // the map panel's width in a 1500px window
BENCH_H :: 845

// bench pans the view one pixel per frame at three zoom levels and reports the
// distribution of the time one map frame takes. One pixel per frame is the
// hardest case for the labeller — every frame is a fresh contest — and it is
// also what a drag actually does.
bench :: proc(file: string) -> int {
	sc.register_shadcn_theme(false)
	p.set_text_gamma(1.8)
	off := p.offscreen_create(BENCH_W, BENCH_H, 1, "w-full h-full bg-white")
	defer p.offscreen_destroy(off)
	load_map_fonts(&off.fonts)

	a := new(Maps)
	defer free(a)
	if !shot_state(a, off, file) {
		return 1
	}
	defer maps_destroy(a)
	setup_demo(a)

	rect := p.Rect{0, 0, BENCH_W, BENCH_H}
	cv := p.offscreen_canvas(off)

	// MAPS_PROFILE=1 prints where a frame's time goes, class by class.
	if os.get_env("MAPS_PROFILE", context.temp_allocator) != "" {
		for z in ([?]f64{11.0, 14.5, 17.5}) {
			a.view = {center = lonlat_to_world(CITY_LON, CITY_LAT), zoom = z, w = BENCH_W, h = BENCH_H}
			a.sc.view = a.view
			draw_scene(cv, rect, &a.sc)
			fmt.printfln("profile z%.1f:", z)
			a.sc.profile = true
			draw_scene(cv, rect, &a.sc)
			a.sc.profile = false
			fmt.printfln(
				"    total %.2f ms — labels %.2f (placing %.2f, drawing %.2f) over %d labels",
				a.sc.ms_total,
				a.sc.ms_labels,
				a.sc.ms_place,
				a.sc.ms_labels - a.sc.ms_place,
				a.sc.n_labels,
			)
		}
	}

	fmt.printfln("")
	fmt.printfln(
		"bench: %dx%d panel, %d features, %d graph nodes",
		BENCH_W,
		BENCH_H,
		len(a.m.features),
		graph_node_count(&a.g),
	)
	fmt.printfln(
		"       %-26s %8s %8s %8s %8s %7s %7s",
		"zoom",
		"mean",
		"median",
		"p95",
		"worst",
		"fps",
		"labels",
	)

	levels := [?]struct {
		name: string,
		zoom: f64,
	}{{"low (the whole city)", 11.0}, {"middle (a district)", 14.5}, {"high (a street)", 17.5}}

	N :: 180
	worst_mean := 0.0
	for lv in levels {
		a.view = {center = lonlat_to_world(CITY_LON, CITY_LAT), zoom = lv.zoom, w = BENCH_W, h = BENCH_H}
		// Warm up: the glyph cache and the scratch buffers fill on the first
		// few frames and measuring those measures the allocator.
		for _ in 0 ..< 10 {
			a.sc.view = a.view
			draw_scene(cv, rect, &a.sc)
		}
		times := make([]f64, N, context.temp_allocator)
		step := 1.0 / view_scale(a.view) // exactly one pixel
		labels := 0
		for i in 0 ..< N {
			a.view.center.x += step
			a.sc.view = a.view
			t0 := time.now()
			draw_scene(cv, rect, &a.sc)
			times[i] = time.duration_milliseconds(time.since(t0))
			labels += a.sc.n_labels
		}
		// Sort for the percentiles.
		for i in 1 ..< N {
			v := times[i]
			j := i - 1
			for j >= 0 && times[j] > v {
				times[j + 1] = times[j]
				j -= 1
			}
			times[j + 1] = v
		}
		sum := 0.0
		for v in times {
			sum += v
		}
		mean := sum / N
		worst_mean = math.max(worst_mean, mean)
		fmt.printfln(
			"       %-26s %7.2f %8.2f %8.2f %8.2f %7.0f %7d",
			fmt.tprintf("%s z%.1f", lv.name, lv.zoom),
			mean,
			times[N / 2],
			times[N * 95 / 100],
			times[N - 1],
			1000 / math.max(mean, 0.001),
			labels / N,
		)
	}

	// And the same three with labels off, which separates the cartography from
	// the labeller.
	fmt.printfln("")
	a.sc.show_labels = false
	for lv in levels {
		a.view = {center = lonlat_to_world(CITY_LON, CITY_LAT), zoom = lv.zoom, w = BENCH_W, h = BENCH_H}
		for _ in 0 ..< 5 {
			a.sc.view = a.view
			draw_scene(cv, rect, &a.sc)
		}
		sum := 0.0
		step := 1.0 / view_scale(a.view)
		for _ in 0 ..< N {
			a.view.center.x += step
			a.sc.view = a.view
			t0 := time.now()
			draw_scene(cv, rect, &a.sc)
			sum += time.duration_milliseconds(time.since(t0))
		}
		fmt.printfln(
			"       %-26s %7.2f ms mean, labels off",
			fmt.tprintf("%s z%.1f", lv.name, lv.zoom),
			sum / N,
		)
	}
	a.sc.show_labels = true

	// Routing, searching and loading, which are not per-frame costs but are
	// the three things a user waits for.
	fmt.printfln("")
	{
		s := grid_node(&a.g, 6, 1)
		t := grid_node(&a.g, 14, 11)
		if s >= 0 && t >= 0 {
			for mode in ([?]Cost_Mode{.Distance, .Time}) {
				t0 := time.now()
				for _ in 0 ..< 50 {
					route_find(&a.g, &a.m, s, t, mode, &a.route)
				}
				ms := time.duration_milliseconds(time.since(t0)) / 50
				fmt.printfln(
					"       route across the city (%v): %.2f ms, %d nodes explored of %d, %s",
					mode,
					ms,
					a.route.explored,
					graph_node_count(&a.g),
					format_distance(a.route.dist_m),
				)
			}
		}
	}
	{
		hits := make([dynamic]Hit)
		defer delete(hits)
		t0 := time.now()
		for _ in 0 ..< 200 {
			search(&a.ix, "harb", &hits)
		}
		fmt.printfln(
			"       search over %d names: %.3f ms, %d hits",
			index_count(&a.ix),
			time.duration_milliseconds(time.since(t0)) / 200,
			len(hits),
		)
	}
	fmt.printfln("       load and index %d features: %.0f ms", len(a.m.features), a.load_ms)

	_ = strings.contains
	return 0
}
