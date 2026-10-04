package main

// The interface around the map.
//
//   a toolbar        the search field, the tools, the layer switches
//   a side panel     search results, or the route's directions, or help
//   the map          one `p.pixels` element filling the rest
//   a status bar     the frame time, the feature counts, the last message
//
// There is no popup anywhere: palmy has no xdg_popup, so the file dialog is
// drawn as an absolutely positioned overlay inside the window, which is what
// `kit.pick_draw` expects and why the root element is `relative`.

import "core:fmt"
import kit "kit:."
import p "palmy:."

SIDE_W :: 338
LABEL_CLASS :: "text-[10.5] font-semibold uppercase tracking-wider text-muted-foreground"
ROW_CLASS :: "flex-row items-center gap-2 px-2.5 py-1.5 rounded-md cursor-pointer hover:bg-accent transition"
MONO_SM :: "font-mono text-[11] leading-[15]"

draw_ui :: proc(a: ^Maps, ui: ^p.Ctx) {
	p.col(ui, "w-full h-full bg-background text-foreground relative")
	defer p.end(ui)

	toolbar(a, ui)

	p.row(ui, "flex-1 min-h-0 w-full")
	{
		side_panel(a, ui)

		p.div(ui, "flex-1 min-w-0 h-full relative overflow-hidden")
		{
			idx := p.pixels(
				ui,
				a.tool == .Pan \
				? (a.dragging ? "w-full h-full cursor-grabbing" : "w-full h-full cursor-grab") \
				: "w-full h-full cursor-crosshair",
				&a.sc,
				draw_scene,
			)
			a.map_id = p.node_id(ui, idx)
			// The panel joins the Tab order so the whole map is reachable from
			// the keyboard: focus it and the arrows pan.
			p.focusable(ui, idx)
			map_overlay(a, ui)
		}
		p.end(ui)
	}
	p.end(ui)

	status_bar(a, ui)
	pick_overlay(a, ui)
}

// ---------------------------------------------------------------------------
// The toolbar
// ---------------------------------------------------------------------------

@(private = "file")
toolbar :: proc(a: ^Maps, ui: ^p.Ctx) {
	p.row(ui, "w-full h-12 shrink-0 items-center gap-2 px-3 border-b border-border bg-card")
	defer p.end(ui)

	p.row(ui, "items-center gap-2 shrink-0")
	p.icon(ui, kit.ICON_LAYOUT_GRID, "size-4 text-primary")
	p.text(ui, "Maps", "text-[13] font-semibold")
	p.end(ui)

	p.divider(ui, "w-px h-6 bg-border shrink-0")

	// The search field. It is wide because a street name is long, and it is
	// the first thing in the Tab order after the title for the same reason.
	p.div(ui, "w-[300] shrink-0 relative")
	{
		// The field's own node index, taken before it is built.
		//
		// `p.focused(ui)` with no index asks about the *innermost open*
		// element, and a text field closes itself before it returns — so the
		// bare call reports on this wrapper div, which is never focused. The
		// symptom is that the search box looks focused and typing into it runs
		// the single-key shortcuts instead: typing "Harbour" toggled the route
		// tool and turned the buildings off.
		fi := p.node_count(ui)
		changed, submitted := p.text_field(
			ui,
			&a.q,
			"Search places and streets",
			"w-full h-8 text-[12.5]",
		)
		if a.focus_search {
			p.set_focus(ui, p.node_id(ui, fi))
			a.focus_search = false
		}
		a.searching = p.focused(ui, fi)
		if changed {
			search(&a.ix, string(a.q[:]), &a.hits)
			a.sel = len(a.hits) > 0 ? 0 : -1
			a.panel = .Search
		}
		if submitted {
			// Enter always hands the keyboard back, result or no result.
			// Leaving it in the field on a query that matched nothing meant
			// every key after it — the tool shortcuts, the arrows, the panel
			// digits — was typed into the search box instead.
			if a.sel >= 0 && a.sel < len(a.hits) {
				goto_hit(a, ui, a.sel)
			} else {
				a.searching = false
				p.set_focus(ui, 0)
			}
		}
	}
	p.end(ui)

	if p.button(ui, "Clear", "h-8 px-2.5 text-[11.5] shrink-0") {
		clear(&a.q)
		clear(&a.hits)
		a.sel = -1
	}

	p.divider(ui, "w-px h-6 bg-border shrink-0")

	for t in Tool {
		on := a.tool == t
		cls := on \
		? "h-8 px-2.5 text-[11.5] shrink-0 bg-primary text-primary-foreground border-primary" \
		: "h-8 px-2.5 text-[11.5] shrink-0"
		if p.button(ui, tool_name(t), cls) {
			a.tool = t
			if t == .Route {
				a.from_node, a.to_node = -1, -1
				route_clear(&a.route)
				sync_route_markers(a)
			}
			if t == .Measure {
				clear(&a.sc.measure)
			}
		}
	}

	p.spacer(ui)

	// The cost the router optimises. It is a visible switch rather than a
	// setting because the two give different routes and the user has to know
	// which they are looking at.
	p.text(ui, "Optimise", "text-[11] text-muted-foreground shrink-0")
	if p.button(
		ui,
		a.cost == .Time ? "Travel time" : "Distance",
		"h-8 px-2.5 text-[11.5] shrink-0",
	) {
		a.cost = a.cost == .Time ? .Distance : .Time
		if a.from_node >= 0 && a.to_node >= 0 {
			recompute_route(a, ui)
		}
	}

	if p.button(ui, a.sc.show_labels ? "Labels on" : "Labels off", "h-8 px-2.5 text-[11.5] shrink-0") {
		a.sc.show_labels = !a.sc.show_labels
	}
	if p.button(
		ui,
		a.sc.show_buildings ? "Buildings on" : "Buildings off",
		"h-8 px-2.5 text-[11.5] shrink-0",
	) {
		a.sc.show_buildings = !a.sc.show_buildings
	}
	if p.button(ui, "Open", "h-8 px-2.5 text-[11.5] shrink-0") {
		begin_open(a)
	}
	if p.button(ui, "?", "h-8 w-8 text-[11.5] shrink-0") {
		a.panel = a.panel == .Help ? .Search : .Help
	}
}

// ---------------------------------------------------------------------------
// The side panel
// ---------------------------------------------------------------------------

@(private = "file")
side_panel :: proc(a: ^Maps, ui: ^p.Ctx) {
	p.col(ui, fmt.tprintf("w-[%d] h-full shrink-0 border-r border-border bg-sidebar", SIDE_W))
	defer p.end(ui)

	// Tabs.
	p.row(ui, "w-full h-9 shrink-0 items-center gap-1 px-2 border-b border-border")
	for tab, label in ([?]struct {
		tab:   Panel,
		label: string,
	}{{.Search, "Results"}, {.Route, "Directions"}, {.Layers, "Data"}, {.Help, "Keys"}}) {
		_ = label
		on := a.panel == tab.tab
		if p.button(
			ui,
			tab.label,
			on \
			? "h-7 px-2.5 text-[11.5] bg-accent text-accent-foreground border-transparent" \
			: "h-7 px-2.5 text-[11.5] bg-transparent border-transparent text-muted-foreground",
		) {
			a.panel = tab.tab
		}
	}
	p.end(ui)

	switch a.panel {
	case .Search:
		results_panel(a, ui)
	case .Route:
		route_panel(a, ui)
	case .Layers:
		data_panel(a, ui)
	case .Help:
		help_panel(a, ui)
	}
}

@(private = "file")
results_panel :: proc(a: ^Maps, ui: ^p.Ctx) {
	p.col(ui, "flex-1 min-h-0 w-full overflow-scroll p-2 gap-0.5")
	defer p.end(ui)

	if len(a.q) == 0 {
		hint(ui, "Type a name in the search box. Prefixes, words out of the middle and initials all match: \"mcs\" finds Marisport Central Station.")
		return
	}
	if len(a.hits) == 0 {
		hint(ui, fmt.tprintf("Nothing matches “%s”.", string(a.q[:])))
		return
	}

	p.textf(ui, "px-1 pb-1 " + LABEL_CLASS, "%d results", len(a.hits))
	for h, k in a.hits {
		e := a.ix.entries[h.entry]
		p.key(ui, e.name)
		sel := k == a.sel
		p.col(
			ui,
			sel \
			? "w-full gap-0 px-2.5 py-1.5 rounded-md cursor-pointer bg-accent" \
			: "w-full gap-0 " + ROW_CLASS,
		)
		if p.clickable(ui) {
			goto_hit(a, ui, k)
		}
		p.row(ui, "items-center gap-2 w-full")
		p.text(ui, e.name, "text-[12.5] font-medium truncate")
		p.spacer(ui)
		p.textf(ui, "font-mono text-[9.5] text-muted-foreground shrink-0", "%.0f", h.score)
		p.end(ui)
		p.row(ui, "items-center gap-2 w-full")
		p.text(ui, class_word(e.class), "text-[10.5] text-muted-foreground")
		if e.rank > 0 {
			lon, lat := world_to_lonlat((e.bbox.min + e.bbox.max) / 2)
			p.textf(ui, "font-mono text-[9.5] text-muted-foreground", "%.4f, %.4f", lat, lon)
		}
		p.end(ui)
		p.end(ui)
	}
}

@(private = "file")
route_panel :: proc(a: ^Maps, ui: ^p.Ctx) {
	p.col(ui, "flex-1 min-h-0 w-full overflow-scroll p-2 gap-1")
	defer p.end(ui)

	if !a.route.ok {
		if a.route.why != "" {
			p.col(ui, "w-full gap-1 p-2.5 rounded-md bg-destructive/10 border border-destructive/30")
			p.text(ui, "No route", "text-[12] font-semibold text-destructive")
			p.text(ui, a.route.why, "text-[11] text-muted-foreground")
			p.end(ui)
		}
		hint(
			ui,
			a.from_node >= 0 \
			? "Start set. Click the destination on the map." \
			: "Pick the Route tool, then click a start and a destination on the map. Press t to switch between the fastest and the shortest.",
		)
		return
	}

	// The summary.
	p.col(ui, "w-full gap-1 p-2.5 rounded-lg bg-card border border-border")
	p.row(ui, "items-baseline gap-2 w-full")
	p.text(ui, format_duration(a.route.time_s), "text-[19] font-semibold whitespace-nowrap shrink-0")
	p.text(
		ui,
		format_distance(a.route.dist_m),
		"text-[13] text-muted-foreground whitespace-nowrap shrink-0",
	)
	p.end(ui)
	p.row(ui, "items-center gap-2 w-full")
	p.textf(
		ui,
		"text-[10.5] text-muted-foreground",
		"optimised for %s · %d steps · %d of %d nodes explored",
		a.cost == .Time ? "travel time" : "distance",
		len(a.route.steps),
		a.route.explored,
		graph_node_count(&a.g),
	)
	p.end(ui)
	p.end(ui)

	// The directions.
	cum := 0.0
	for st, k in a.route.steps {
		p.key(ui, fmt.tprintf("step%d", k))
		sel := k == a.step_sel
		p.row(
			ui,
			sel \
			? "w-full items-start gap-2.5 px-2 py-2 rounded-md bg-accent cursor-pointer" \
			: "w-full items-start gap-2.5 px-2 py-2 rounded-md hover:bg-accent cursor-pointer transition",
		)
		if p.clickable(ui) {
			a.step_sel = k
			b := Bbox{st.at, st.at}
			fly_to(a, b)
		}
		p.focusable(ui)
		if p.activated(ui) {
			a.step_sel = k
			fly_to(a, Bbox{st.at, st.at})
		}

		// The manoeuvre arrow, rotated to the turn.
		p.div(ui, "w-6 h-6 shrink-0 items-center justify-center rounded-md bg-muted")
		p.icon(ui, maneuver_icon(st.man), "size-3.5 text-foreground", maneuver_turns(st.man))
		p.end(ui)

		p.col(ui, "flex-1 min-w-0 gap-0")
		p.text(ui, step_text(st), "text-[12] leading-[16]")
		p.row(ui, "items-center gap-2 w-full")
		META :: "text-[10.5] text-muted-foreground whitespace-nowrap shrink-0"
		if st.man != .Arrive {
			p.text(ui, format_distance(st.dist_m), META)
			p.text(ui, format_duration(st.time_s), META)
		}
		if k > 0 {
			p.textf(
				ui,
				"font-mono text-[9.5] text-muted-foreground whitespace-nowrap shrink-0",
				"at %s",
				format_distance(cum),
			)
		}
		p.end(ui)
		p.end(ui)
		p.end(ui)
		cum += st.dist_m
	}
}

@(private = "file")
data_panel :: proc(a: ^Maps, ui: ^p.Ctx) {
	p.col(ui, "flex-1 min-h-0 w-full overflow-scroll p-2 gap-2")
	defer p.end(ui)

	p.text(ui, "Loaded", LABEL_CLASS)
	p.text(ui, a.path == "" ? "(nothing)" : a.path, "text-[11] " + MONO_SM + " break-words")

	kv :: proc(ui: ^p.Ctx, k: string, format: string, args: ..any) {
		p.row(ui, "w-full items-baseline gap-2")
		p.text(ui, k, "text-[11] text-muted-foreground")
		p.spacer(ui)
		p.textf(ui, MONO_SM, format, ..args)
		p.end(ui)
	}

	p.col(ui, "w-full gap-0.5 p-2 rounded-md bg-card border border-border")
	kv(ui, "features", "%d", len(a.m.features))
	kv(ui, "points / lines / areas", "%d / %d / %d", a.m.n_points, a.m.n_lines, a.m.n_polys)
	kv(ui, "coordinates", "%d", len(a.m.pts))
	kv(ui, "rings", "%d", len(a.m.rings))
	kv(ui, "named", "%d", index_count(&a.ix))
	kv(ui, "graph nodes", "%d", graph_node_count(&a.g))
	kv(ui, "graph arcs", "%d", graph_arc_count(&a.g))
	kv(ui, "one-way edges", "%d", a.g.n_oneway)
	kv(ui, "load", "%.0f ms", a.load_ms)
	p.end(ui)

	p.text(ui, "This frame", LABEL_CLASS)
	mean, worst := frame_stats(a)
	p.col(ui, "w-full gap-0.5 p-2 rounded-md bg-card border border-border")
	kv(ui, "drawn features", "%d", a.sc.n_drawn)
	kv(ui, "stroked vertices", "%d", a.sc.n_seg)
	kv(ui, "labels placed", "%d of %d tried", a.sc.lab.n_placed, a.sc.lab.n_tried)
	kv(ui, "map", "%.2f ms", a.sc.ms_total)
	kv(ui, "of which labels", "%.2f ms", a.sc.ms_labels)
	kv(ui, "mean / worst", "%.2f / %.2f ms", mean, worst)
	kv(ui, "zoom", "%.3f", a.view.zoom)
	_, lat := world_to_lonlat(a.view.center)
	kv(ui, "metres per pixel", "%.3f", ground_resolution(lat, a.view.zoom))
	tx, ty := lonlat_to_tile_center(a.view)
	kv(ui, "tile", "%d/%d/%d", int(a.view.zoom), int(tx), int(ty))
	p.end(ui)

	p.text(ui, "Annotations", LABEL_CLASS)
	p.col(ui, "w-full gap-0.5 p-2 rounded-md bg-card border border-border")
	kv(ui, "markers", "%d", len(a.sc.markers))
	kv(ui, "measure points", "%d", len(a.sc.measure))
	if len(a.sc.measure) >= 2 {
		kv(ui, "measured", "%s", format_distance(measure_total(a)))
	}
	p.end(ui)
	if p.button(ui, "Clear annotations", "w-full h-8 text-[11.5]") {
		clear_annotations(a)
	}
	if p.button(ui, "Fit to data", "w-full h-8 text-[11.5]") {
		if bbox_valid(a.m.bbox) {
			fly_to(a, a.m.bbox)
		}
	}
}

lonlat_to_tile_center :: proc(v: View) -> (tx, ty: f64) {
	lon, lat := world_to_lonlat(v.center)
	return lonlat_to_tile(lon, lat, int(v.zoom))
}

@(private = "file")
help_panel :: proc(a: ^Maps, ui: ^p.Ctx) {
	p.col(ui, "flex-1 min-h-0 w-full overflow-scroll p-2 gap-1.5")
	defer p.end(ui)

	group :: proc(ui: ^p.Ctx, title: string) {
		p.text(ui, title, "pt-1.5 " + LABEL_CLASS)
	}
	keyrow :: proc(ui: ^p.Ctx, keys, what: string) {
		p.row(ui, "w-full items-baseline gap-2")
		p.text(ui, keys, "shrink-0 w-[92] font-mono text-[11] text-foreground")
		p.text(ui, what, "flex-1 min-w-0 text-[11] text-muted-foreground")
		p.end(ui)
	}

	group(ui, "Moving")
	keyrow(ui, "drag", "pan")
	keyrow(ui, "arrows", "pan from the keyboard")
	keyrow(ui, "wheel", "zoom about the cursor")
	keyrow(ui, "+ / -", "zoom in and out")
	keyrow(ui, "PgUp / PgDn", "a whole zoom level")
	keyrow(ui, "f", "fit the whole data set")
	group(ui, "Finding")
	keyrow(ui, "/  Ctrl-F", "the search box")
	keyrow(ui, "up / down", "move through the results")
	keyrow(ui, "Enter", "fly to the selected result")
	group(ui, "Tools")
	keyrow(ui, "m", "drop markers")
	keyrow(ui, "r", "route: a start, then a destination")
	keyrow(ui, "d", "measure along a line")
	keyrow(ui, "Enter", "with a tool armed, act at the crosshair")
	keyrow(ui, "click", "or act where you click")
	keyrow(ui, "t", "optimise travel time or distance")
	keyrow(ui, "c", "clear markers, measurement and route")
	keyrow(ui, "Escape", "back to panning")
	group(ui, "Drawing")
	keyrow(ui, "l", "labels on and off")
	keyrow(ui, "b", "buildings on and off")
	group(ui, "Panels")
	keyrow(ui, "1 2 3 4", "results, directions, data, keys")
	group(ui, "Data")
	keyrow(ui, "Ctrl-O", "open a .geojson or .osm file")

	p.text(ui, "About the data", "pt-3 " + LABEL_CLASS)
	p.text(
		ui,
		"This program never touches the network. With no file given it generates a city — an arterial grid, winding residential streets, a river with bridges, parks, a coastline and a few hundred buildings — and writes it as GeoJSON into ~/.local/share/palmy-maps. Open any RFC 7946 GeoJSON or OSM XML file over it.",
		"text-[11] leading-[16] text-muted-foreground",
	)
	_ = a
}

@(private = "file")
hint :: proc(ui: ^p.Ctx, text: string) {
	p.text(ui, text, "text-[11.5] leading-[17] text-muted-foreground p-1.5")
}

// ---------------------------------------------------------------------------
// Over the map
// ---------------------------------------------------------------------------

// map_overlay is the zoom buttons and the tool hint, drawn as absolutely
// positioned elements over the pixel panel. The scale bar and the coordinate
// read-out are not here — they are painted inside the canvas by `draw_chrome`,
// because they have to sit over the pixels at exact positions.
@(private = "file")
map_overlay :: proc(a: ^Maps, ui: ^p.Ctx) {
	p.col(ui, "absolute top-3 right-3 gap-1 z-10 items-end")
	defer p.end(ui)

	p.col(ui, "gap-0 rounded-lg overflow-hidden border border-border shadow-md bg-card ring-1 ring-black/10")
	if p.button(ui, "+", "w-9 h-9 text-[16] font-medium rounded-none border-0 bg-card hover:bg-accent") {
		view_zoom_at(&a.view, 1, a.view.w / 2, a.view.h / 2)
		a.fly = false
	}
	p.divider(ui, "h-px w-full bg-border")
	if p.button(ui, "−", "w-8 h-8 text-[14] rounded-none border-0 bg-card hover:bg-accent") {
		view_zoom_at(&a.view, -1, a.view.w / 2, a.view.h / 2)
		a.fly = false
	}
	p.end(ui)

	if a.tool != .Pan {
		p.div(ui, "px-2.5 py-1.5 rounded-md bg-card border border-border shadow-sm")
		p.text(ui, tool_hint(a), "text-[11] whitespace-nowrap")
		p.end(ui)
	}
	if len(a.sc.measure) >= 2 {
		p.div(ui, "px-2.5 py-1.5 rounded-md bg-card border border-border shadow-sm")
		p.textf(ui, "font-mono text-[11.5] whitespace-nowrap", "%s", format_distance(measure_total(a)))
		p.end(ui)
	}
}

@(private = "file")
tool_hint :: proc(a: ^Maps) -> string {
	switch a.tool {
	case .Pan:
		return ""
	case .Marker:
		return "click to drop a marker"
	case .Measure:
		return "click to add a point to the measurement"
	case .Route:
		if a.from_node < 0 {
			return "click the start of the route"
		}
		if a.to_node < 0 {
			return "click the destination"
		}
		return "click to start a new route"
	}
	return ""
}

// ---------------------------------------------------------------------------
// The status bar
// ---------------------------------------------------------------------------

@(private = "file")
status_bar :: proc(a: ^Maps, ui: ^p.Ctx) {
	p.row(ui, "w-full h-7 shrink-0 items-center gap-3 px-3 border-t border-border bg-card")
	defer p.end(ui)

	now := f64(p.elapsed(ui))
	msg := a.status
	if now > a.status_until {
		msg = ""
	}
	p.text(
		ui,
		msg == "" ? fmt.tprintf("%s · zoom %.2f", tool_name(a.tool), a.view.zoom) : msg,
		"text-[11] truncate",
	)
	p.spacer(ui)

	if a.has_cursor {
		lon, lat := world_to_lonlat(a.cursor)
		p.textf(ui, MONO_SM + " text-muted-foreground shrink-0", "%.5f, %.5f", lat, lon)
	}
	mean, worst := frame_stats(a)
	p.textf(
		ui,
		MONO_SM + " text-muted-foreground shrink-0",
		"%d feat · %d labels · %.1f ms (worst %.1f)",
		a.sc.n_drawn,
		a.sc.n_labels,
		mean,
		worst,
	)
}

// ---------------------------------------------------------------------------
// The file dialog
// ---------------------------------------------------------------------------

@(private = "file")
pick_overlay :: proc(a: ^Maps, ui: ^p.Ctx) {
	if !kit.pick_active(&a.pick) {
		return
	}
	res, done := kit.pick_draw(ui, &a.pick)
	if !done {
		return
	}
	defer kit.pick_result_free(res)
	a.picking = false
	if !res.ok {
		return
	}
	ok, msg := load_file(a, res.path)
	say(a, f64(p.elapsed(ui)), msg)
	_ = ok
}

// ---------------------------------------------------------------------------
// Shared behaviour
// ---------------------------------------------------------------------------

// goto_hit flies the view to a search result and drops a marker on it, so the
// answer is still visible once the animation has finished.
goto_hit :: proc(a: ^Maps, ui: ^p.Ctx, k: int) {
	if k < 0 || k >= len(a.hits) {
		return
	}
	a.sel = k
	e := a.ix.entries[a.hits[k].entry]
	fly_to(a, e.bbox)
	a.searching = false
	p.set_focus(ui, 0)
	say(a, f64(p.elapsed(ui)), fmt.tprintf("%s — %s", e.name, class_word(e.class)))
	p.redraw(ui)
}

// maneuver_icon and maneuver_turns pick the arrow for a step. palmy rotates an
// icon by turns, so one arrow covers every angle.
maneuver_icon :: proc(m: Maneuver) -> p.Icon {
	switch m {
	case .Depart:
		return kit.ICON_ARROW_UP
	case .Arrive:
		return kit.ICON_STAR
	case .U_Turn:
		return kit.ICON_CORNER_UP_LEFT
	case .Continue, .Slight_Left, .Left, .Sharp_Left, .Slight_Right, .Right, .Sharp_Right:
		return kit.ICON_ARROW_UP
	}
	return kit.ICON_ARROW_UP
}

maneuver_turns :: proc(m: Maneuver) -> f32 {
	// An eighth of a turn is 45 degrees.
	switch m {
	case .Slight_Left:
		return -0.11
	case .Left:
		return -0.25
	case .Sharp_Left:
		return -0.38
	case .Slight_Right:
		return 0.11
	case .Right:
		return 0.25
	case .Sharp_Right:
		return 0.38
	case .U_Turn, .Depart, .Arrive, .Continue:
		return 0
	}
	return 0
}
