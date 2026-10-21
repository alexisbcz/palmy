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
	fmt.print(LEGACY_USAGE)
}

LEGACY_USAGE :: `maps — a desktop map, rendered from GeoJSON or OSM XML

  maps [file.geojson | file.osm]
  maps --selftest                 the headless assertions
  maps --gen <path>               write the generated city as GeoJSON
  maps --regen                    regenerate the city in the data directory
  maps --shot <out.png> [zoom]    render one frame offscreen
  maps --sheet <dir>              render a frame at every interesting zoom
  maps --bench                    frame times while panning, at three zooms

Keys: drag or arrows to pan, wheel or +/- to zoom, / to search,
      m marker, r route, d measure, t time/distance, l labels,
      b buildings, c clear, f fit, Ctrl-O open, h help.
`

// LEGACY_FLAGS are the options this program took before the shared command
// line existed. A line carrying any of them is handled exactly as it always
// was, by the loop below; everything else goes to the declared surface in
// cli.odin, which is also what a bare file or no argument at all falls through
// to the window from.
LEGACY_FLAGS :: [?]string{"--gen", "--regen", "--shot", "--sheet", "--bench", "-selftest"}

main :: proc() {
	args := os.args[1:]

	legacy := false
	for a in args {
		for l in LEGACY_FLAGS {
			if a == l {
				legacy = true
			}
		}
	}
	if !legacy {
		if code, handled := kit.cli(surface()); handled {
			os.exit(code)
		}
		// A bare word the CLI did not claim is a map file for the window —
		// unless there is no such file, in which case it is a typo, and the
		// answer to a typo is not a window that never returns to its caller.
		if len(args) > 0 && !strings.has_prefix(args[0], "-") && !os.exists(args[0]) {
			fmt.eprintfln("maps: %q is neither a command nor a file (maps --help)", args[0])
			os.exit(2)
		}
	}

	// Two passes over the command line. The first collects the file to open,
	// because an option that acts immediately — `--shot`, `--sheet`, `--bench`
	// — needs it and may well appear before it. One pass that acted as it went
	// rendered the generated city every time a file was named after the
	// option, which is the normal way round to type it.
	file := ""
	{
		i := 0
		for i < len(args) {
			a := args[i]
			switch a {
			case "--shot":
				i += 2 // an output path and an optional zoom
				if i < len(args) {
					if _, ok := strconv.parse_f64(args[i]); ok {
						i += 1
					}
				}
				continue
			case "--gen", "--sheet":
				i += 2
				continue
			}
			if !strings.has_prefix(a, "-") {
				file = a
			}
			i += 1
		}
	}

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
			g, ok := write_generated(args[i + 1])
			if !ok {
				fmt.eprintfln("maps: cannot write %s", args[i + 1])
				os.exit(1)
			}
			fmt.printfln(
				"maps: wrote %d features (%d points, %d lines, %d polygons) to %s",
				g.features,
				g.points,
				g.lines,
				g.polys,
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
		// The data directory could not be written. The generated city is still
		// the right thing to show, held in memory instead of on disk.
		if ok, msg := load_generated(a); ok {
			a.status = strings.clone(note != "" ? fmt.tprintf("%s — %s", note, msg) : msg)
			a.status_until = 8
		} else {
			a.status = strings.clone(note == "" ? "no map data — press Ctrl-O to open a file" : note)
			a.status_until = 60
		}
	}

	for ui in p.frames(app) {
		// The map panel's rectangle comes from the previous frame's layout.
		if a.map_id != 0 {
			a.map_rect = p.rect_of(ui, a.map_id)
		}
		sync_view_size(a)
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
		a.sc.crosshair = a.tool != .Pan

		draw_ui(a, ui)
		record_frame(a, f32(a.sc.ms_total))
	}
}
