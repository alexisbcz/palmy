package main

// maps — a desktop map on palmy. Pan and zoom over rendered vector data,
// search for a place, and get a route with turn-by-turn directions.
//
// Where the files are:
//
//   proj.odin      Web Mercator, the tile scheme, distance and bearing
//   geo.odin       the data model, feature classes, widths and ranks
//   geojson.odin   the GeoJSON reader and writer
//   osm.odin       the OSM XML reader
//   gen.odin       the synthetic city generator
//   raster.odin    the scanline polygon filler and the stroker
//   render.odin    palette, paint order, the frame
//   label.odin     the text mask, the halo, the collision index
//   place.odin     label candidates and the placement contest
//   search.odin    the name index and the ranking
//   route.odin     the road graph, A*, turn-by-turn
//   app.odin       the model and the input
//   ui.odin        the interface
//   shot.odin      offscreen renders and the frame-time benchmark
//   selftest.odin  the headless assertions
//
// There is no network code in this program and no tile fetching of any kind.
// The data comes from a file, and if there is no file it comes from the
// generator.

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import kit "kit:."
import p "palmy:."

usage :: proc() {
	fmt.println("maps — a desktop map, rendered from GeoJSON or OSM XML")
	fmt.println("")
	fmt.println("  maps [file.geojson | file.osm]")
	fmt.println("  maps --selftest                 the headless assertions")
	fmt.println("  maps --gen <path>               write the generated city as GeoJSON")
	fmt.println("  maps --regen                    regenerate the city in the data directory")
	fmt.println("  maps --shot <out.png> [zoom]    render one frame offscreen")
	fmt.println("  maps --sheet <dir>              render a frame at every interesting zoom")
	fmt.println("  maps --bench                    frame times while panning, at three zooms")
	fmt.println("")
	fmt.println("Keys: drag or arrows to pan, wheel or +/- to zoom, / to search,")
	fmt.println("      m marker, r route, d measure, t time/distance, l labels,")
	fmt.println("      b buildings, c clear, f fit, Ctrl-O open, h help.")
}

main :: proc() {
	args := os.args[1:]
	file := ""
	for a, i in args {
		switch {
		case a == "--selftest" || a == "-selftest":
			os.exit(selftest())
		case a == "--help" || a == "-h":
			usage()
			return
		case a == "--gen":
			if i + 1 >= len(args) {
				fmt.eprintln("maps: --gen needs a path")
				os.exit(2)
			}
			m: Map
			map_init(&m)
			defer map_destroy(&m)
			generate_city(&m)
			if !write_geojson(&m, args[i + 1]) {
				fmt.eprintfln("maps: cannot write %s", args[i + 1])
				os.exit(1)
			}
			fmt.printfln(
				"maps: wrote %d features (%d points, %d lines, %d polygons) to %s",
				len(m.features),
				m.n_points,
				m.n_lines,
				m.n_polys,
				args[i + 1],
			)
			return
		case a == "--regen":
			path, made, err := ensure_city(true)
			if err != "" {
				fmt.eprintfln("maps: %s", err)
				os.exit(1)
			}
			fmt.printfln("maps: %s %s", made ? "wrote" : "kept", path)
			return
		case a == "--shot":
			if i + 1 >= len(args) {
				fmt.eprintln("maps: --shot needs an output path")
				os.exit(2)
			}
			zoom := 14.5
			if i + 2 < len(args) {
				if v, ok := strconv.parse_f64(args[i + 2]); ok {
					zoom = v
				}
			}
			os.exit(shot(args[i + 1], zoom, file))
		case a == "--sheet":
			if i + 1 >= len(args) {
				fmt.eprintln("maps: --sheet needs a directory")
				os.exit(2)
			}
			os.exit(sheet(args[i + 1], file))
		case a == "--bench":
			os.exit(bench(file))
		case strings.has_prefix(a, "-"):
			fmt.eprintfln("maps: unknown option %s", a)
			os.exit(2)
		case:
			file = a
		}
	}

	a := new(Maps)
	defer free(a)
	maps_init(a)
	defer maps_destroy(a)

	start_path := file
	note := ""
	if start_path == "" {
		start_path, note = startup_file()
	}

	app, err := kit.start({title = "Maps", width = 1500, height = 940, min_width = 900, min_height = 600})
	if err != "" {
		fmt.eprintln("maps:", err)
		os.exit(1)
	}
	a.win = app
	a.fonts = &app.fonts
	a.sc.fonts = &app.fonts
	a.sc.show_chrome = true
	defer p.destroy(app)

	if start_path != "" {
		ok, msg := load_file(a, start_path)
		if !ok {
			fmt.eprintfln("maps: %s", msg)
		}
		a.status = strings.clone(note != "" ? note : msg)
		a.status_until = 8
	} else {
		a.status = strings.clone(note == "" ? "no map data — press Ctrl-O to open a file" : note)
		a.status_until = 60
	}

	for ui in p.frames(app) {
		// The map panel's rectangle comes from the previous frame's layout.
		if a.map_id != 0 {
			a.map_rect = p.rect_of(ui, a.map_id)
		}
		fly_step(a, f64(p.delta_time(ui)))
		if a.fly {
			p.redraw(ui)
		}

		// The file dialog, when it is up, owns the keyboard and the pointer.
		if !kit.pick_active(&a.pick) {
			handle_keys(a, ui)
			handle_map_mouse(a, ui)
		} else {
			a.has_cursor = false
		}

		a.sc.view = a.view
		a.sc.cursor = a.cursor
		a.sc.has_cursor = a.has_cursor
		a.sc.show_route = a.route.ok

		draw_ui(a, ui)
		record_frame(a, f32(a.sc.ms_total))
	}
}
