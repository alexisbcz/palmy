package main

// The command-line front end of Maps.
//
// Nothing here re-implements the map. Loading goes through `load_file` (or
// `load_generated`) and `rebuild` on a Maps with no window, searching through
// the same `search` and index the search field uses, and routing through
// `route_between` / `snap_endpoint`, which are what a click with the Route
// tool calls. `maps render` draws the real interface through `render_frame`,
// which `--shot` uses too.
//
// There is no network code in this program; every command reads a file the
// caller named, the data directory's city, or — when neither exists — the
// generated city built in memory. A `read` never writes the city to disk:
// that is `gen` and `regen`, which say so.

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import kit "kit:."
import p "palmy:."
import sc "shadcn:."

@(private = "file")
COMMANDS := []kit.Command {
	{
		verb = "info",
		summary = "what the map holds: features by kind, extent, road graph, named places",
		effect = .Read,
		flags = {FILE_FLAG},
		out = INFO_FIELDS,
		examples = {"maps info --json", "maps info --file city.geojson --json"},
		run = cmd_info,
	},
	{
		verb = "search",
		summary = "find a place or a street by name, best first, the way the search field does",
		effect = .Read,
		args = {{name = "query", kind = .String, help = "a name, a prefix, part of one, or a fuzzy abbreviation", required = true}},
		flags = {FILE_FLAG, {name = "limit", kind = .Int, help = "how many hits at most", def = "10"}},
		out = SEARCH_FIELDS,
		examples = {"maps search Harbour --json", "maps search \"jubilee\" --limit 3 --json"},
		run = cmd_search,
	},
	{
		verb = "route",
		summary = "turn-by-turn directions between two places, snapped to roads like the Route tool",
		effect = .Read,
		args = {
			{name = "from", kind = .String, help = "a place name (its best search hit) or lat,lon", required = true},
			{name = "to", kind = .String, help = "a place name (its best search hit) or lat,lon", required = true},
		},
		flags = {
			FILE_FLAG,
			{name = "by", kind = .Enum, values = {"time", "distance"}, def = "time", help = "what the router optimises"},
		},
		out = ROUTE_FIELDS,
		examples = {
			"maps route \"Marisport Central Station\" \"Lighthouse Point\" --json",
			"maps route 45.01,7.44 \"City Library\" --by distance --json",
		},
		run = cmd_route,
	},
	{
		verb = "nearest",
		summary = "what a click with no tool reports: the nearest road and how far it is",
		effect = .Read,
		args = {{name = "at", kind = .String, help = "lat,lon (a negative latitude needs -- before it)", required = true}},
		flags = {FILE_FLAG},
		out = NEAREST_FIELDS,
		examples = {"maps nearest 45.0,7.45 --json"},
		run = cmd_nearest,
	},
	{
		verb = "render",
		summary = "draw the interface offscreen at a zoom and centre and write a PNG",
		effect = .Mutate,
		args = {{name = "out", kind = .Path, help = "the PNG to write", required = true}},
		flags = {
			FILE_FLAG,
			{name = "zoom", kind = .Float, help = "web-mercator zoom", def = "14.5"},
			{name = "center", kind = .String, help = "lat,lon; the map's centre when omitted"},
			{name = "width", kind = .Int, help = "pixels", def = "1500"},
			{name = "height", kind = .Int, help = "pixels", def = "940"},
		},
		out = RENDER_FIELDS,
		examples = {"maps render /tmp/maps.png --zoom 15 --json"},
		run = cmd_render,
	},
	{
		verb = "gen",
		summary = "write the generated city as GeoJSON to a path",
		effect = .Mutate,
		args = {{name = "path", kind = .Path, help = "where to write it", required = true}},
		out = GEN_FIELDS,
		examples = {"maps gen /tmp/city.geojson --json"},
		run = cmd_gen,
	},
	{
		verb = "regen",
		summary = "regenerate the city in the data directory, replacing what is there",
		effect = .Idempotent,
		out = GEN_FIELDS,
		examples = {"maps regen --json"},
		run = cmd_regen,
	},
}

@(private = "file")
FILE_FLAG :: kit.Param {
	name = "file",
	kind = .Path,
	help = "a GeoJSON or OSM XML file; the data directory's city, else the generated one",
}

@(private = "file")
g_surface: kit.Surface

surface :: proc() -> ^kit.Surface {
	if g_surface.noun == "" {
		g_surface = kit.Surface {
			noun       = "maps",
			summary    = "a map of GeoJSON or OSM data: search, routes, renders; no network",
			gui        = true,
			takes_path = true,
			takes_word = kit.cli_word_is_path, // a file opens; a typo is a usage error
			selftest   = cli_selftest,
			notes      = SURFACE_NOTES,
			commands   = COMMANDS,
		}
	}
	return &g_surface
}

@(private = "file")
SURFACE_NOTES :: `With no command, maps opens the window; ` + "`maps <file>`" + ` opens that file in it.
Data: --file, else $XDG_DATA_HOME/palmy-maps/city.geojson (~/.local/share when
unset), else the generated city held in memory. Reads never write the city.

The options this program had before the shared command line still work
exactly as they did:
` + LEGACY_USAGE

cli_selftest :: proc() -> int {
	return selftest()
}

// ---------------------------------------------------------------------------
// Declared output
// ---------------------------------------------------------------------------

INFO_FIELDS := []kit.Field {
	{name = "path", kind = .String, help = "the file read, \"\" for the generated city in memory"},
	{name = "generated", kind = .Bool, help = "true when nothing was on disk and the city was generated in memory"},
	{name = "features", kind = .Int},
	{name = "points", kind = .Int},
	{name = "lines", kind = .Int},
	{name = "polygons", kind = .Int},
	{name = "bbox", kind = .Object, of = { {name = "west", kind = .Float}, {name = "south", kind = .Float}, {name = "east", kind = .Float}, {name = "north", kind = .Float}, }},
	{name = "nodes", kind = .Int, help = "road graph nodes"},
	{name = "arcs", kind = .Int, help = "road graph arcs (one per direction of travel)"},
	{name = "names", kind = .Int, help = "distinct searchable names"},
	{name = "load_ms", kind = .Float},
}

SEARCH_FIELDS := []kit.Field {
	{name = "query", kind = .String},
	{
		name = "hits",
		kind = .Array,
		of = {
			{name = "name", kind = .String},
			{name = "class", kind = .String},
			{name = "lat", kind = .Float, help = "the centre of its extent"},
			{name = "lon", kind = .Float},
			{name = "bbox", kind = .Object, of = { {name = "west", kind = .Float}, {name = "south", kind = .Float}, {name = "east", kind = .Float}, {name = "north", kind = .Float}, }},
			{name = "score", kind = .Float},
		},
	},
	{name = "count", kind = .Int},
}

ROUTE_FIELDS := []kit.Field {
	{name = "from", kind = .Object, of = { {name = "query", kind = .String, help = "what was asked for"}, {name = "name", kind = .String, help = "the search hit it resolved to, \"\" for coordinates"}, {name = "lat", kind = .Float, help = "the road point it was snapped to"}, {name = "lon", kind = .Float}, }},
	{name = "to", kind = .Object, of = { {name = "query", kind = .String, help = "what was asked for"}, {name = "name", kind = .String, help = "the search hit it resolved to, \"\" for coordinates"}, {name = "lat", kind = .Float, help = "the road point it was snapped to"}, {name = "lon", kind = .Float}, }},
	{name = "by", kind = .String},
	{name = "distance_m", kind = .Float},
	{name = "time_s", kind = .Float},
	{name = "distance", kind = .String, help = "as the panel shows it"},
	{name = "duration", kind = .String},
	{name = "explored", kind = .Int, help = "nodes the search settled"},
	{name = "nodes", kind = .Int, help = "nodes on the path"},
	{
		name = "steps",
		kind = .Array,
		of = {
			{name = "maneuver", kind = .String},
			{name = "instruction", kind = .String},
			{name = "name", kind = .String},
			{name = "distance_m", kind = .Float},
			{name = "time_s", kind = .Float},
			{name = "lat", kind = .Float},
			{name = "lon", kind = .Float},
		},
	},
}

NEAREST_FIELDS := []kit.Field {
	{name = "lat", kind = .Float},
	{name = "lon", kind = .Float},
	{name = "on_road", kind = .Bool, help = "within the distance a click counts as on a road"},
	{name = "road_m", kind = .Float, help = "distance to the nearest road node, -1 with no roads"},
	{name = "road_lat", kind = .Float, opt = true},
	{name = "road_lon", kind = .Float, opt = true},
	{name = "says", kind = .String, help = "what the status bar would say"},
}

RENDER_FIELDS := []kit.Field {
	{name = "out", kind = .String},
	{name = "written", kind = .Bool},
	{name = "zoom", kind = .Float},
	{name = "lat", kind = .Float},
	{name = "lon", kind = .Float},
	{name = "width", kind = .Int},
	{name = "height", kind = .Int},
	{name = "drawn", kind = .Int, help = "features drawn"},
	{name = "labels", kind = .Int, help = "labels placed"},
	{name = "ms", kind = .Float, help = "map drawing time"},
}

GEN_FIELDS := []kit.Field {
	{name = "path", kind = .String},
	{name = "written", kind = .Bool},
	{name = "features", kind = .Int},
	{name = "points", kind = .Int},
	{name = "lines", kind = .Int},
	{name = "polygons", kind = .Int},
}

// ---------------------------------------------------------------------------
// Loading
// ---------------------------------------------------------------------------

// cli_load fills a windowless Maps the way the window does: the file named,
// else the data directory's city — and, unlike the window, the generated city
// in memory rather than writing one to disk.
@(private = "file")
cli_load :: proc(c: ^kit.Call, a: ^Maps) -> int {
	maps_init(a)
	file := kit.cli_str(c, "file")
	if file == "" {
		if d := default_city_path(); os.is_file(d) {
			file = d
		}
	}
	if file == "" {
		if ok, msg := load_generated(a); !ok {
			return kit.cli_fail(c, kit.EXIT_FAILED, msg)
		}
		return kit.EXIT_OK
	}
	if !os.exists(file) {
		code := kit.cli_failf(c, kit.EXIT_NOT_FOUND, "no such file: %s", file)
		kit.cli_err_field(c, "file", file)
		return code
	}
	ok, msg := load_file(a, file)
	if !ok {
		return kit.cli_fail(c, kit.EXIT_FAILED, msg)
	}
	kit.cli_trace(c, "%s", msg)
	return kit.EXIT_OK
}

// parse_latlon reads "lat,lon".
parse_latlon :: proc(s: string) -> (w: World_Pt, ok: bool) {
	comma := strings.index_byte(s, ',')
	if comma < 0 {
		return {}, false
	}
	lat, ok1 := strconv.parse_f64(strings.trim_space(s[:comma]))
	lon, ok2 := strconv.parse_f64(strings.trim_space(s[comma + 1:]))
	if !ok1 || !ok2 || lat < -90 || lat > 90 || lon < -180 || lon > 180 {
		return {}, false
	}
	return lonlat_to_world(lon, lat), true
}

// resolve_place turns a name or coordinates into a point. A name is its best
// search hit, which is the first row the search panel would show.
@(private = "file")
resolve_place :: proc(a: ^Maps, q: string) -> (w: World_Pt, name: string, ok: bool) {
	if pt, is_ll := parse_latlon(q); is_ll {
		return pt, "", true
	}
	hits := make([dynamic]Hit, context.temp_allocator)
	search(&a.ix, q, &hits, 1)
	if len(hits) == 0 {
		return {}, "", false
	}
	e := a.ix.entries[hits[0].entry]
	return (e.bbox.min + e.bbox.max) / 2, e.name, true
}

@(private = "file")
bbox_json :: proc(b: Bbox) -> ^kit.Json {
	// World y grows southwards, so the box's min corner is the north west.
	w, n := world_to_lonlat(b.min)
	e, s := world_to_lonlat(b.max)
	o := kit.jobj()
	kit.jset_num(o, "west", min(w, e))
	kit.jset_num(o, "south", min(s, n))
	kit.jset_num(o, "east", max(w, e))
	kit.jset_num(o, "north", max(s, n))
	return o
}

@(private = "file")
set_latlon :: proc(o: ^kit.Json, w: World_Pt, lat_key := "lat", lon_key := "lon") {
	lon, lat := world_to_lonlat(w)
	kit.jset_num(o, lat_key, lat)
	kit.jset_num(o, lon_key, lon)
}

// ---------------------------------------------------------------------------
// Commands
// ---------------------------------------------------------------------------

@(private = "file")
cmd_info :: proc(c: ^kit.Call) -> int {
	a := new(Maps) // not temp: an offscreen frame frees the temp allocator
	defer free(a)
	if code := cli_load(c, a); code != kit.EXIT_OK {
		return code
	}
	defer maps_destroy(a)
	kit.jset_str(c.out, "path", a.path)
	kit.jset_bool(c.out, "generated", a.path == "")
	kit.jset_int(c.out, "features", len(a.m.features))
	kit.jset_int(c.out, "points", a.m.n_points)
	kit.jset_int(c.out, "lines", a.m.n_lines)
	kit.jset_int(c.out, "polygons", a.m.n_polys)
	kit.jset(c.out, "bbox", bbox_json(a.m.bbox))
	kit.jset_int(c.out, "nodes", graph_node_count(&a.g))
	kit.jset_int(c.out, "arcs", graph_arc_count(&a.g))
	kit.jset_int(c.out, "names", index_count(&a.ix))
	kit.jset_num(c.out, "load_ms", a.load_ms)
	return kit.EXIT_OK
}

@(private = "file")
cmd_search :: proc(c: ^kit.Call) -> int {
	a := new(Maps) // not temp: an offscreen frame frees the temp allocator
	defer free(a)
	if code := cli_load(c, a); code != kit.EXIT_OK {
		return code
	}
	defer maps_destroy(a)
	q := kit.cli_str(c, "query")
	limit := max(1, kit.cli_int(c, "limit", 10))
	// The same procedure, index and ranking as the search field.
	search(&a.ix, q, &a.hits, limit)
	arr := kit.jarr()
	for h in a.hits {
		e := a.ix.entries[h.entry]
		o := kit.jobj()
		kit.jset_str(o, "name", e.name)
		kit.jset_str(o, "class", class_word(e.class))
		set_latlon(o, (e.bbox.min + e.bbox.max) / 2)
		kit.jset(o, "bbox", bbox_json(e.bbox))
		kit.jset_num(o, "score", f64(h.score))
		kit.jpush(arr, o)
	}
	kit.jset_str(c.out, "query", q)
	kit.jset(c.out, "hits", arr)
	kit.jset_int(c.out, "count", kit.jlen(arr))
	return kit.EXIT_OK
}

@(private = "file")
cmd_route :: proc(c: ^kit.Call) -> int {
	a := new(Maps) // not temp: an offscreen frame frees the temp allocator
	defer free(a)
	if code := cli_load(c, a); code != kit.EXIT_OK {
		return code
	}
	defer maps_destroy(a)
	fq, tq := kit.cli_str(c, "from"), kit.cli_str(c, "to")
	from, from_name, ok1 := resolve_place(a, fq)
	if !ok1 {
		code := kit.cli_failf(c, kit.EXIT_NOT_FOUND, "no place matching %q", fq)
		kit.cli_err_field(c, "place", fq)
		return code
	}
	to, to_name, ok2 := resolve_place(a, tq)
	if !ok2 {
		code := kit.cli_failf(c, kit.EXIT_NOT_FOUND, "no place matching %q", tq)
		kit.cli_err_field(c, "place", tq)
		return code
	}
	a.cost = kit.cli_str(c, "by") == "distance" ? .Distance : .Time
	if ok, why := route_between(a, from, to); !ok {
		// No road near an end, or no path between them: either way there is
		// no route to be found, which is a documented outcome rather than a
		// failure of the program.
		return kit.cli_failf(c, kit.EXIT_NOT_FOUND, "no route: %s", why)
	}

	place :: proc(q, name: string, w: World_Pt) -> ^kit.Json {
		o := kit.jobj()
		kit.jset_str(o, "query", q)
		kit.jset_str(o, "name", name)
		set_latlon(o, w)
		return o
	}
	r := &a.route
	kit.jset(c.out, "from", place(fq, from_name, a.g.pos[a.from_node]))
	kit.jset(c.out, "to", place(tq, to_name, a.g.pos[a.to_node]))
	kit.jset_str(c.out, "by", a.cost == .Distance ? "distance" : "time")
	kit.jset_num(c.out, "distance_m", r.dist_m)
	kit.jset_num(c.out, "time_s", r.time_s)
	kit.jset_str(c.out, "distance", format_distance(r.dist_m))
	kit.jset_str(c.out, "duration", format_duration(r.time_s))
	kit.jset_int(c.out, "explored", r.explored)
	kit.jset_int(c.out, "nodes", len(r.path))
	steps := kit.jarr()
	for st in r.steps {
		o := kit.jobj()
		kit.jset_str(o, "maneuver", fmt.tprintf("%v", st.man))
		kit.jset_str(o, "instruction", fmt.tprintf("%s %s", maneuver_text(st.man), st.name))
		kit.jset_str(o, "name", st.name)
		kit.jset_num(o, "distance_m", st.dist_m)
		kit.jset_num(o, "time_s", st.time_s)
		set_latlon(o, st.at)
		kit.jpush(steps, o)
	}
	kit.jset(c.out, "steps", steps)
	return kit.EXIT_OK
}

@(private = "file")
cmd_nearest :: proc(c: ^kit.Call) -> int {
	at := kit.cli_str(c, "at")
	w, ok := parse_latlon(at)
	if !ok {
		return kit.cli_failf(c, kit.EXIT_USAGE, "%q is not lat,lon", at)
	}
	a := new(Maps) // not temp: an offscreen frame frees the temp allocator
	defer free(a)
	if code := cli_load(c, a); code != kit.EXIT_OK {
		return code
	}
	defer maps_destroy(a)
	node, d, on_road := identify_at(a, w)
	set_latlon(c.out, w)
	kit.jset_bool(c.out, "on_road", on_road)
	kit.jset_num(c.out, "road_m", node >= 0 ? d : -1)
	if node >= 0 {
		set_latlon(c.out, a.g.pos[node], "road_lat", "road_lon")
	}
	lon, lat := world_to_lonlat(w)
	says := on_road ? fmt.tprintf("%s from the nearest road", format_distance(d)) : fmt.tprintf("%.5f, %.5f", lat, lon)
	kit.jset_str(c.out, "says", says)
	return kit.EXIT_OK
}

@(private = "file")
cmd_render :: proc(c: ^kit.Call) -> int {
	out := kit.cli_str(c, "out")
	zoom := kit.cli_f64(c, "zoom", 14.5)
	w := clamp(kit.cli_int(c, "width", SHOT_W), 320, 8192)
	h := clamp(kit.cli_int(c, "height", SHOT_H), 240, 8192)

	center_given := kit.cli_has(c, "center")
	center: World_Pt
	if center_given {
		cw, ok := parse_latlon(kit.cli_str(c, "center"))
		if !ok {
			return kit.cli_failf(c, kit.EXIT_USAGE, "--center %q is not lat,lon", kit.cli_str(c, "center"))
		}
		center = cw
	}

	sc.register_shadcn_theme(false)
	p.set_text_gamma(1.8)
	off := p.offscreen_create(w, h, 1, "w-full h-full bg-background text-foreground")
	defer p.offscreen_destroy(off)
	load_map_fonts(&off.fonts)

	a := new(Maps) // not temp: an offscreen frame frees the temp allocator
	defer free(a)
	if code := cli_load(c, a); code != kit.EXIT_OK {
		return code
	}
	defer maps_destroy(a)
	a.fonts = &off.fonts
	a.sc.fonts = &off.fonts
	a.sc.show_chrome = true
	if !center_given {
		center = (a.m.bbox.min + a.m.bbox.max) / 2
	}

	kit.jset_str(c.out, "out", out)
	kit.jset_num(c.out, "zoom", zoom)
	set_latlon(c.out, center)
	kit.jset_int(c.out, "width", w)
	kit.jset_int(c.out, "height", h)
	if c.dry_run {
		kit.jset_bool(c.out, "written", false)
		kit.jset_int(c.out, "drawn", 0)
		kit.jset_int(c.out, "labels", 0)
		kit.jset_num(c.out, "ms", 0)
		return kit.EXIT_OK
	}
	r := render_frame(a, off, out, zoom, center)
	kit.jset_bool(c.out, "written", r.ok)
	kit.jset_int(c.out, "drawn", r.drawn)
	kit.jset_int(c.out, "labels", r.placed)
	kit.jset_num(c.out, "ms", f64(r.ms))
	if !r.ok {
		return kit.cli_failf(c, kit.EXIT_FAILED, "cannot write %s", out)
	}
	return kit.EXIT_OK
}

@(private = "file")
gen_json :: proc(c: ^kit.Call, path: string, written: bool, g: Gen_Counts) {
	kit.jset_str(c.out, "path", path)
	kit.jset_bool(c.out, "written", written)
	kit.jset_int(c.out, "features", g.features)
	kit.jset_int(c.out, "points", g.points)
	kit.jset_int(c.out, "lines", g.lines)
	kit.jset_int(c.out, "polygons", g.polys)
}

// generated_counts is what write_generated would write, without writing it,
// for --dry-run.
@(private = "file")
generated_counts :: proc() -> Gen_Counts {
	m: Map
	map_init(&m)
	defer map_destroy(&m)
	generate_city(&m)
	return {len(m.features), m.n_points, m.n_lines, m.n_polys}
}

@(private = "file")
cmd_gen :: proc(c: ^kit.Call) -> int {
	path := kit.cli_str(c, "path")
	if c.dry_run {
		gen_json(c, path, false, generated_counts())
		return kit.EXIT_OK
	}
	g, ok := write_generated(path)
	gen_json(c, path, ok, g)
	if !ok {
		return kit.cli_failf(c, kit.EXIT_FAILED, "cannot write %s", path)
	}
	return kit.EXIT_OK
}

@(private = "file")
cmd_regen :: proc(c: ^kit.Call) -> int {
	if c.dry_run {
		gen_json(c, default_city_path(), false, generated_counts())
		return kit.EXIT_OK
	}
	path, _, err := ensure_city(true)
	if err != "" {
		return kit.cli_fail(c, kit.EXIT_FAILED, err)
	}
	// Read back what was written, so the counts describe the file on disk.
	a := new(Maps) // not temp: an offscreen frame frees the temp allocator
	defer free(a)
	maps_init(a)
	defer maps_destroy(a)
	ok, _ := load_file(a, path)
	gen_json(c, path, ok, {len(a.m.features), a.m.n_points, a.m.n_lines, a.m.n_polys})
	return kit.EXIT_OK
}

// ---------------------------------------------------------------------------
// The self-test of this front end
// ---------------------------------------------------------------------------

@(private = "file")
cli_self_exe :: proc() -> string {
	if pth, err := os.get_executable_path(context.temp_allocator); err == nil {
		return pth
	}
	return os.args[0]
}

// cli_run runs this binary again with a private data directory and audit log,
// and the display variables cleared so a dispatcher mistake cannot open a
// window and hang the run.
@(private = "file")
cli_run :: proc(dir: string, args: ..string) -> (out: string, code: int) {
	line := strings.builder_make(context.temp_allocator)
	strings.write_string(&line, "WAYLAND_DISPLAY= DISPLAY= ")
	strings.write_string(&line, fmt.tprintf("XDG_DATA_HOME=%q PALM_AUDIT=%q ", dir, fmt.tprintf("%s/audit.jsonl", dir)))
	strings.write_string(&line, fmt.tprintf("%q", cli_self_exe()))
	for x in args {
		strings.write_string(&line, fmt.tprintf(" %q", x))
	}
	state, sout, _, err := os.process_exec({command = {"sh", "-c", strings.to_string(line)}}, context.temp_allocator)
	if err != nil {
		return "", -1
	}
	return string(sout), state.exit_code
}

@(private = "file")
schema_ok :: proc(out: string, fields: []kit.Field, what: string) {
	problems := kit.cli_validate_output(out, fields, context.temp_allocator)
	check(len(problems) == 0, "%s matches its declared schema%s", what, len(problems) > 0 ? fmt.tprintf(" (%s)", problems[0]) : "")
}

test_cli :: proc() {
	fmt.println("- the command line")
	dir := fmt.tprintf("/tmp/palmy-maps-cli-%d", os.get_pid())
	os.make_directory_all(dir)
	defer os.remove_all(dir)

	sf := surface()
	check(sf.noun == "maps", "the surface is named maps")
	check(sf.gui && sf.takes_path, "a bare file still opens the window")
	for cmd in sf.commands {
		check(cmd.run != nil, "%s has an implementation", cmd.verb)
		check(len(cmd.out) > 0, "%s declares what it prints", cmd.verb)
		check(len(cmd.examples) > 0, "%s ships an example", cmd.verb)
		for ex in cmd.examples {
			words := kit.cli_split_example(ex, context.temp_allocator)
			check(len(words) > 0 && words[0] == "maps", "the example %q starts with the binary", ex)
			args := make([dynamic]string, context.temp_allocator)
			for w in words[1:] {
				append(&args, w)
			}
			append(&args, "--parse-only")
			_, code := cli_run(dir, ..args[:])
			check(code == 0, "the example %q parses (exit %d)", ex, code)
		}
	}

	// With an empty data directory, a read uses the generated city in memory
	// and writes nothing.
	{
		out, code := cli_run(dir, "info", "--json")
		check(code == 0, "info with no data exits 0, got %d", code)
		schema_ok(out, INFO_FIELDS, "info")
		check(strings.contains(out, `"generated": true`), "and says the city is generated")
		check(!os.exists(fmt.tprintf("%s/palmy-maps/city.geojson", dir)), "and a read wrote no city to disk")
	}

	city := fmt.tprintf("%s/city.geojson", dir)
	{
		out, code := cli_run(dir, "gen", city, "--json")
		check(code == 0, "gen exits 0")
		schema_ok(out, GEN_FIELDS, "gen")
		check(os.is_file(city), "and the file is there")
		_, dcode := cli_run(dir, "gen", fmt.tprintf("%s/dry.geojson", dir), "--dry-run", "--json")
		check(dcode == 0 && !os.exists(fmt.tprintf("%s/dry.geojson", dir)), "gen --dry-run writes nothing")
	}

	// The in-process model the window would hold, for agreement.
	ref: City
	city_make(&ref)
	defer city_free(&ref)
	{
		out, code := cli_run(dir, "info", "--file", city, "--json")
		check(code == 0, "info --file exits 0")
		schema_ok(out, INFO_FIELDS, "info --file")
		check(strings.contains(out, fmt.tprintf(`"features": %d`, len(ref.m.features))), "and counts what the generator made")
		check(strings.contains(out, fmt.tprintf(`"nodes": %d`, graph_node_count(&ref.g))), "and the same road graph")
	}
	{
		out, code := cli_run(dir, "search", "Jubilee", "--file", city, "--limit", "3", "--json")
		check(code == 0, "search exits 0")
		schema_ok(out, SEARCH_FIELDS, "search")
		hits := make([dynamic]Hit, context.temp_allocator)
		search(&ref.ix, "Jubilee", &hits, 3)
		check(len(hits) > 0 && strings.contains(out, fmt.tprintf(`"name": "%s"`, ref.ix.entries[hits[0].entry].name)), "and its first hit is the search field's")
		_, nf := cli_run(dir, "search", "Jubilee", "--file", fmt.tprintf("%s/nope.geojson", dir), "--json")
		check(nf == kit.EXIT_NOT_FOUND, "a missing --file exits 3, got %d", nf)
	}
	{
		from, to := "Marisport Central Station", "Lighthouse Point"
		out, code := cli_run(dir, "route", from, to, "--file", city, "--json")
		check(code == 0, "route between two named places exits 0, got %d", code)
		schema_ok(out, ROUTE_FIELDS, "route")

		// The same question asked in-process through the window's own path.
		a := new(Maps)
		defer free(a)
		maps_init(a)
		defer maps_destroy(a)
		ok, _ := load_file(a, city)
		check(ok, "the generated file loads in-process")
		fw, _, f_ok := resolve_place(a, from)
		tw, _, t_ok := resolve_place(a, to)
		check(f_ok && t_ok, "both places resolve")
		rok, why := route_between(a, fw, tw)
		check(rok, "and route_between finds a route (%s)", why)
		if rok {
			check(strings.contains(out, fmt.tprintf(`"nodes": %d`, len(a.route.path))), "the CLI's route visits as many nodes as the window's")
			check(strings.contains(out, fmt.tprintf(`"explored": %d`, a.route.explored)), "and explored the same search")
			check(len(a.route.steps) > 1 && strings.contains(out, a.route.steps[1].name), "and names the same streets")
		}
		dout, dcode := cli_run(dir, "route", from, to, "--file", city, "--by", "distance", "--json")
		check(dcode == 0 && strings.contains(dout, `"by": "distance"`), "--by distance is honoured")
		_, nf := cli_run(dir, "route", "zzqqxx-nowhere", to, "--file", city, "--json")
		check(nf == kit.EXIT_NOT_FOUND, "an unknown place exits 3, got %d", nf)
		_, far := cli_run(dir, "route", "10.0,10.0", to, "--file", city, "--json")
		check(far == kit.EXIT_NOT_FOUND, "a start far from any road exits 3, got %d", far)
	}
	{
		out, code := cli_run(dir, "nearest", "45.0,7.45", "--file", city, "--json")
		check(code == 0, "nearest exits 0")
		schema_ok(out, NEAREST_FIELDS, "nearest")
		_, bad := cli_run(dir, "nearest", "not-a-point", "--json")
		check(bad == kit.EXIT_USAGE, "nearest with no coordinates is a usage error")
	}
	{
		png := fmt.tprintf("%s/r.png", dir)
		out, code := cli_run(dir, "render", png, "--file", city, "--zoom", "15", "--width", "640", "--height", "400", "--json")
		check(code == 0, "render exits 0")
		schema_ok(out, RENDER_FIELDS, "render")
		check(strings.contains(out, `"drawn": `) && !strings.contains(out, `"drawn": 0,`), "and draws the map, not an empty panel")
		img, ok := p.load_image(png)
		check(ok && img.w == 640 && img.h == 400, "and writes a PNG of the size asked for")
		if ok {
			p.image_destroy(&img)
		}
	}
	{
		out, code := cli_run(dir, "regen", "--json")
		check(code == 0, "regen exits 0")
		schema_ok(out, GEN_FIELDS, "regen")
		check(os.is_file(fmt.tprintf("%s/palmy-maps/city.geojson", dir)), "and writes the data directory's city, inside XDG_DATA_HOME")
		out2, _ := cli_run(dir, "info", "--json")
		check(strings.contains(out2, `"generated": false`), "after which reads use the file")
	}
	{
		_, code := cli_run(dir, "nosuchverb")
		check(code >= 0, "a bare word is a file for the window, which without a display exits rather than hanging")
		out, scode := cli_run(dir, "--schema")
		check(scode == 0 && strings.contains(out, `"noun": "maps"`), "--schema answers")
	}
}
