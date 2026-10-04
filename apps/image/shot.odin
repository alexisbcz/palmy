package main

// Headless rendering.
//
//   image.bin <media> --shot out.png [seconds] [keys]
//
// `--shot` and everything after it belongs to the screenshot, so the media to
// open goes first.
//
// palmy can run its whole UI without a compositor, which is the only sane way
// to look at a layout on a machine with a dozen other windows fighting for the
// screen. The loader thread runs exactly as it does in the real app, so the
// picture is of real decoded pixels.

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import kit "kit:."
import p "palmy:."

shot_requested :: proc() -> (out: string, seconds: f64, keys: string, ok: bool) {
	args := os.args[1:]
	for a, i in args {
		if a == "--shot" && i + 1 < len(args) {
			out = args[i + 1]
			seconds = 3
			if i + 2 < len(args) {
				if v, good := strconv.parse_f64(args[i + 2]); good {
					seconds = v
				} else {
					keys = args[i + 2]
				}
			}
			if i + 3 < len(args) {
				keys = args[i + 3]
			}
			return out, seconds, keys, true
		}
	}
	return "", 0, "", false
}

// shot_strip drops the screenshot flag and its arguments, leaving the ordinary
// command line the app would otherwise have seen.
shot_strip :: proc(args: []string) -> []string {
	for a, i in args {
		if a == "--shot" {
			return args[:i]
		}
	}
	return args
}

run_shot :: proc(st: ^St, out: string, seconds: f64, keys: string) {
	off := p.offscreen_create(
		WIN_W,
		WIN_H,
		1,
		"w-full h-full flex-col bg-background text-foreground overflow-hidden",
	)
	defer p.offscreen_destroy(off)
	load_fonts(&off.fonts)

	t0 := time.now()
	sent := false
	ticks := 0
	paint_ms := f64(0)
	for {
		el := time.duration_seconds(time.since(t0))
		if el >= seconds {
			break
		}
		free_all(context.temp_allocator)
		ticks += 1
		pump(st)

		pt := time.now()
		ui := p.offscreen_begin(off)
		if !sent && el > 0.8 && keys != "" {
			apply_keys(st, keys)
			sent = true
			pump(st)
		}
		switch st.view {
		case .Library:
			build_library_ui(ui, st)
		case .Viewer:
			build_viewer(ui, st)
		case .Grid:
			build_grid(ui, st)
		}
		// The same last step the real frame loop takes, so a shot of the file
		// dialog is a shot of what the window would show.
		pick_overlay(ui, st)
		p.offscreen_end(off)
		paint_ms += time.duration_milliseconds(time.since(pt))
		spent := time.duration_milliseconds(time.since(pt))
		if spent < 16 {
			time.sleep(time.Duration(f64(16 - spent) * f64(time.Millisecond)))
		}
	}
	if p.offscreen_write_png(off, out) {
		fmt.printfln("wrote %s", out)
		fmt.printfln(
			"ui: %.1f fps, paint %.2f ms/frame",
			f64(ticks) / seconds,
			paint_ms / f64(max(ticks, 1)),
		)
		done, total, avg := loader_stats(&st.ld)
		fmt.printfln(
			"thumbs=%d/%d avg=%.1fms current_decode=%.1fms scale=%.0f%% rot=%d",
			done,
			total,
			avg,
			st.cur_ms,
			effective_scale(st, st.shown) * 100,
			(((st.rot % 4) + 4) % 4) * 90,
		)
	} else {
		fmt.eprintfln("could not write %s", out)
	}
}

apply_keys :: proc(st: ^St, keys: string) {
	for k in strings.split(keys, ",", context.temp_allocator) {
		key := strings.trim_space(k)
		switch {
		case key == "grid":
			st.view = .Grid
			keep_grid_visible(st)
		case key == "viewer":
			st.view = .Viewer
		case key == "library":
			build_library(st)
			st.view = .Library
		case key == "info":
			st.info = !st.info
		case key == "next":
			step(st, 1)
		case key == "prev":
			step(st, -1)
		case key == "rot":
			st.rot += 1
		case key == "zoom":
			zoom_by(st, ZOOM_STEP)
		case key == "zoomout":
			zoom_by(st, 1 / ZOOM_STEP)
		case key == "fit":
			st.fit = true
			st.pan = {}
		case key == "actual":
			set_zoom(st, 1)
		case key == "panright":
			st.pan.x -= 220
			clamp_pan(st, display(st))
		case key == "down":
			st.lib_sel = min(st.lib_sel + 1, max(0, len(st.rows) - 1))
		case key == "open":
			open_row(st)
		case key == "pick":
			begin_pick(st, .File)
		case key == "pickdir":
			begin_pick(st, .Folder)
		case strings.has_prefix(key, "sel"):
			if v, ok := strconv.parse_int(key[3:]); ok {
				st.sel = clamp(v, 0, max(0, len(st.shots) - 1))
				loader_want(&st.ld, st.sel)
			}
		}
	}
}

load_fonts :: proc(f: ^p.Fonts) {
	for pair in ([?]struct {
		file: string,
		wt:   p.Font_Weight,
	}{
		{"Geist-400.ttf", .Regular},
		{"Geist-500.ttf", .Medium},
		{"Geist-600.ttf", .Semibold},
		{"Geist-700.ttf", .Bold},
	}) {
		p.load_font(f, fmt.tprintf("%s/%s", kit.FONT_DIR, pair.file), .Sans, pair.wt)
	}
	for path in ([?]string {
		"/usr/share/fonts/TTF/JetBrainsMonoNerdFont-Regular.ttf",
		"/usr/share/fonts/TTF/DejaVuSansMono.ttf",
		"/usr/share/fonts/liberation/LiberationMono-Regular.ttf",
	}) {
		if p.load_font(f, path, .Mono, .Regular) {
			p.load_font(f, path, .Mono, .Medium)
			p.load_font(f, path, .Mono, .Semibold)
			p.load_font(f, path, .Mono, .Bold)
			break
		}
	}
	p.set_text_gamma(1.8)
}
