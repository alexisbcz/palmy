package main

// Headless rendering.
//
//   audio.bin <media> --shot out.png [seconds] [keys]
//
// `--shot` and everything after it belongs to the screenshot, so the media to
// open goes first.
//
// palmy can run its whole UI without a compositor, which is the only sane way
// to look at a layout on a machine with a dozen other windows fighting for the
// screen. The engine and the analyser run exactly as they do in the real app,
// so the picture is of real playback — not a mock.

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
	for {
		el := time.duration_seconds(time.since(t0))
		if el >= seconds {
			break
		}
		free_all(context.temp_allocator)
		if st.e.live {
			engine_tick(&st.e)
			st.now = engine_clock(&st.e)
			sync_audible(st)
			maybe_prefetch(st)
			if engine_eof(&st.e) {
				advance(st, 1, true)
			}
		}
		update_vis(st)

		ui := p.offscreen_begin(off)
		// Keys are applied once, a second in, so the screenshot shows the
		// state after them rather than the state during them.
		if !sent && el > 1.0 && keys != "" {
			apply_keys(st, keys)
			sent = true
		}
		build(ui, st)
		p.offscreen_end(off)

		time.sleep(16 * time.Millisecond)
	}
	if p.offscreen_write_png(off, out) {
		fmt.printfln("wrote %s", out)
	} else {
		fmt.eprintfln("could not write %s", out)
	}
}

// apply_keys runs a comma separated list of actions, which is enough to put the
// app into whatever state a screenshot is meant to show.
apply_keys :: proc(st: ^St, keys: string) {
	for k in strings.split(keys, ",", context.temp_allocator) {
		switch strings.trim_space(k) {
		case "down":
			st.sel = min(st.sel + 1, max(0, len(st.list) - 1))
		case "up":
			st.sel = max(st.sel - 1, 0)
		case "play":
			play(st, st.sel)
		case "next":
			advance(st, 1)
		case "prev":
			advance(st, -1)
		case "pause":
			engine_pause(&st.e, !engine_paused(&st.e))
		case "scope":
			st.vis_mode = .Scope
		case "spectrum":
			st.vis_mode = .Spectrum
		case "shuffle":
			st.shuffle = !st.shuffle
			rebuild_order(st)
			rethink_next(st)
		case "repeat":
			st.repeat = !st.repeat
			rethink_next(st)
		case "mute":
			engine_mute(&st.e, !st.e.muted)
		case "silent":
			engine_set_volume(&st.e, 0)
		case:
			// `seek0.8` jumps to eight tenths of the track, which is how a
			// headless run gets near a track boundary without waiting for it.
			if strings.has_prefix(k, "seek") {
				if v, good := strconv.parse_f64(strings.trim_space(k)[4:]); good {
					if c := current(st); c != nil {
						seek_to(st, c.m.duration * clamp(v, 0, 1))
					}
				}
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
