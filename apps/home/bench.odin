// `home --bench <query>`: type a query one letter at a time against this
// device's index, through the same path the search box takes (device_search:
// the per-identity counts, the grouped search, the conversion to items), and
// report the time per keystroke. The <30 ms p99 target is checked here.
package main

import "core:fmt"
import "core:os"
import "core:slice"
import "core:time"

bench :: proc(query: string) -> int {
	s := store_load(.Device)
	if len(s.identities) == 0 {
		fmt.eprintln("home --bench: no index on this device")
		return 6
	}
	lat := make([dynamic]f64)
	for rep in 0 ..< 5 {
		for n in 1 ..= len(query) {
			device.cache_q = ""
			t := time.tick_now()
			r := search(&s, query[:n], -1)
			d := time.duration_milliseconds(time.tick_since(t))
			if rep > 0 {
				append(&lat, d)
			}
			if rep == 1 {
				fmt.printfln("%-24q %6.2f ms  %3d results, %d searched", query[:n], d, len(r.hits), r.scanned)
			}
			free_all(context.temp_allocator)
		}
	}
	slice.sort(lat[:])
	pct :: proc(xs: []f64, p: f64) -> f64 {return xs[min(len(xs) - 1, int(p * f64(len(xs) - 1) + 0.5))]}
	fmt.printfln("keystrokes: %d  p50 %.2f ms  p99 %.2f ms  max %.2f ms", len(lat), pct(lat[:], 0.5), pct(lat[:], 0.99), lat[len(lat) - 1])
	return 0
}

// shots_device renders this device's real data: Today in every identity,
// Today in the second, a search and one being typed, and the palette.
// Nothing invented.
shots_device :: proc(dir: string, dark: bool) -> int {
	h := Home{}
	home_init(&h, dark, .Device)
	theme := dark ? "dark" : "light"
	n := 0
	// Heap, not temp: every rendered frame frees the temp allocator.
	q := os.get_env("PALM_HOME_SHOT_QUERY", context.allocator)
	if q == "" {
		q = "roadmap"
	}
	h.sel = -1
	shot(&h, dir, theme, "device-01-today-all", &n)
	if len(h.store.identities) > 1 {
		h.ident = 1
		shot(&h, dir, theme, "device-02-today-one", &n)
		h.ident = -1
	}
	set_buf(&h.query, q)
	h.sel = 0
	shot(&h, dir, theme, "device-03-search", &n)
	set_buf(&h.query, q[:max(1, len(q) - 2)])
	shot(&h, dir, theme, "device-04-typing", &n)
	clear(&h.query)
	h.mode = .Palette
	h.ident = len(h.store.identities) > 0 ? 0 : -1
	shot(&h, dir, theme, "device-05-palette", &n)
	return n
}
