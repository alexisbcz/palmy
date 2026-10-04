package main

// Headless rendering.
//
//   video.bin <media> --shot out.png [seconds] [keys]
//
// `--shot` and everything after it belongs to the screenshot, so the media to
// open goes first.
//
// palmy can run its whole UI without a compositor, which is the only sane way
// to look at a layout on a machine with a dozen other windows fighting for the
// screen. ffmpeg, pw-cat and both reader threads run exactly as they do in the
// real app, so the frame that lands in the PNG is a frame that was decoded,
// clocked against the audio and blitted — not a mock.

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
	paint_ns := f64(0)
	for {
		el := time.duration_seconds(time.since(t0))
		if el >= seconds {
			break
		}
		free_all(context.temp_allocator)
		ticks += 1

		if st.view == .Player && st.open {
			engine_tick(&st.e)
			now := engine_clock(&st.e)
			engine_take(&st.e, now)
			if engine_finished(&st.e) && !st.ended {
				st.ended = true
				engine_pause(&st.e, true)
			}
		}

		pt := time.now()
		ui := p.offscreen_begin(off)
		if !sent && el > 1.2 && keys != "" {
			apply_keys(st, keys)
			sent = true
		}
		switch st.view {
		case .Library:
			build_library(ui, st)
		case .Player:
			build_player(ui, st)
		}
		p.offscreen_end(off)
		paint_ns += time.duration_milliseconds(time.since(pt))
		apply_resize(st, el)

		// A real window is paced by the compositor's frame callback; here the
		// loop paces itself at roughly the same rate so the numbers mean the
		// same thing.
		spent := time.duration_milliseconds(time.since(pt))
		if spent < 16 {
			time.sleep(time.Duration(f64(16 - spent) * f64(time.Millisecond)))
		}
	}
	if p.offscreen_write_png(off, out) {
		fmt.printfln("wrote %s", out)
		fmt.printfln(
			"ui: %d frames in %.2fs = %.1f fps, paint %.2f ms/frame",
			ticks,
			seconds,
			f64(ticks) / seconds,
			paint_ns / f64(max(ticks, 1)),
		)
		report(st)
	} else {
		fmt.eprintfln("could not write %s", out)
	}
}

// report prints the numbers the screenshot cannot show, which is how the
// pipeline is actually measured.
report :: proc(st: ^St) {
	if !st.open {
		return
	}
	shown, dropped, decoded, queued, avg, mx, last, lat, locked := engine_stats(&st.e)
	fmt.printfln(
		"decode=%dx%d@%.3ffps delivered=%.1ffps shown=%d dropped=%d decoded=%d queue=%d",
		st.e.w,
		st.e.h,
		st.e.fps,
		engine_decode_fps(&st.e),
		shown,
		dropped,
		decoded,
		queued,
	)
	fmt.printfln(
		"clock=%s sink_buffer=%.1fms%s mean|err|=%.2fms worst=%.2fms last=%+.2fms",
		st.e.have_audio ? "audio-bytes" : "wall",
		lat * 1000,
		locked ? " (measured)" : " (settling)",
		avg * 1000,
		mx * 1000,
		last * 1000,
	)
	if st.seek_count > 0 {
		fmt.printfln("seeks=%d avg=%.0fms", st.seek_count, st.seek_ms_sum / f64(st.seek_count))
	}
}

apply_keys :: proc(st: ^St, keys: string) {
	for k in strings.split(keys, ",", context.temp_allocator) {
		key := strings.trim_space(k)
		switch {
		case key == "pause":
			engine_pause(&st.e, !engine_paused(&st.e))
		case key == "stats":
			st.stats = !st.stats
		case key == "info":
			st.info = !st.info
		case key == "step":
			engine_pause(&st.e, true)
			step_frame(st, 1)
		case key == "stepback":
			engine_pause(&st.e, true)
			step_frame(st, -1)
		case key == "down":
			st.sel = min(st.sel + 1, max(0, len(st.lib) - 1))
		case key == "play":
			start_playing(st)
		case key == "mute":
			engine_mute(&st.e, !st.e.muted)
		case key == "subs":
			subs_cycle(&st.subs, 1)
		case key == "panel":
			st.subs.panel = !st.subs.panel
		case key == "hide":
			st.subs.show = !st.subs.show
		case key == "faster":
			engine_set_speed(&st.e, engine_speed(&st.e) + SPEED_STEP)
		case key == "slower":
			engine_set_speed(&st.e, engine_speed(&st.e) - SPEED_STEP)
		case key == "chapnext":
			if t, ok := chapter_seek_target(st.e.m.chapters, engine_clock(&st.e), 1); ok {
				seek_to(st, t)
			}
		case key == "chapprev":
			if t, ok := chapter_seek_target(st.e.m.chapters, engine_clock(&st.e), -1); ok {
				seek_to(st, t)
			}
		case strings.has_prefix(key, "speed"):
			if v, ok := strconv.parse_f64(key[5:]); ok {
				engine_set_speed(&st.e, v)
			}
		case strings.has_prefix(key, "seek"):
			if v, ok := strconv.parse_f64(key[4:]); ok {
				seek_to(st, v)
			}
		}
	}
}

// load_fonts mirrors what kit.start does for a real window, because an
// offscreen context has its own font table.
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
