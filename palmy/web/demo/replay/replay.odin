package main

// The native half of the web backend's byte comparison.
//
// palmy/web/demo/native-replay.sh compiles this file into an application's
// own package, next to its unchanged main.odin and a small hook file that
// says how the app sets itself up and what one iteration of its frame loop
// does (palmy/web/demo/hooks/). With PALMY_REPLAY set, this @(init) runs
// before `main` and never returns: it reads the frame log the web build wrote
// (PALMY_WEB_LOG=1, one JSON object per frame the loop ran, logic frames
// included: viewport, clock,
// pointer, buttons, wheel, keys, text), feeds each frame's input to an
// offscreen renderer exactly as the browser fed it to the window, and writes
// the frames asked for as raw RGBA -- the same bytes a canvas's getImageData
// returns, so the comparison is a byte compare.
//
//	PALMY_REPLAY=<log.ndjson>      the frame log
//	PALMY_REPLAY_OUT=<dir>         where native-<n>.rgba and times.json go
//	PALMY_REPLAY_DUMP=3,7,12       frames to write (default: every frame)
//	PALMY_REPLAY_FONTS=<file>      write the font files the app loaded, the
//	                               list web-build.sh --ship-list takes, and stop

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import p "palmy:."

@(private = "file")
Frame_Rec :: struct {
	n, w, h, s:    int,
	paint:         int, // 0: a logic frame, run but never shown
	dt:            u32,
	now:           u64,
	mx, my:        u32,
	mdx, mdy:      u32,
	down, pr, re:  int,
	sx, sy:        u32,
	over, focused: int,
	mods:          int,
	serial:        u32,
	keys:          [][4]u32,
	text:          []i32,
	clip:          [][]i32, // [kind, ok, codepoints...] per clipboard read
}

@(init)
replay_init :: proc "contextless" () {
	context = runtime.default_context()
	log_path := os.get_env("PALMY_REPLAY", context.temp_allocator)
	fonts_path := os.get_env("PALMY_REPLAY_FONTS", context.temp_allocator)
	if log_path == "" && fonts_path == "" {
		return
	}
	hook := replay_hook()

	if fonts_path != "" {
		o := p.offscreen_create(64, 64, 1, hook.root_class)
		hook.setup(o)
		b := strings.builder_make()
		for f in o.fonts.owned {
			fmt.sbprintln(&b, f.path)
		}
		if e := p.emoji_font_path(&o.fonts); e != "" {
			fmt.sbprintln(&b, e)
		}
		_ = os.write_entire_file(fonts_path, transmute([]u8)strings.to_string(b))
		os.exit(0)
	}

	data, err := os.read_entire_file(log_path, context.allocator)
	if err != nil {
		fmt.eprintfln("replay: cannot read %s: %v", log_path, err)
		os.exit(1)
	}
	// Not the temp allocator: every frame ends with free_all on it.
	out := os.get_env("PALMY_REPLAY_OUT", context.allocator)
	if out == "" {
		out = "."
	}
	dump_all := true
	dump := make(map[int]bool)
	if d := os.get_env("PALMY_REPLAY_DUMP", context.temp_allocator); d != "" {
		dump_all = false
		for part in strings.split(d, ",", context.temp_allocator) {
			if n, ok := strconv.parse_int(strings.trim_space(part)); ok {
				dump[n] = true
			}
		}
	}

	o: ^p.Offscreen
	times := strings.builder_make()
	strings.write_string(&times, "[")
	frames := 0
	text := string(data)
	for line in strings.split_lines_iterator(&text) {
		if strings.trim_space(line) == "" {
			continue
		}
		rec: Frame_Rec
		if uerr := json.unmarshal_string(line, &rec, allocator = context.temp_allocator); uerr != nil {
			fmt.eprintfln("replay: bad frame record: %v", uerr)
			os.exit(1)
		}
		if o == nil {
			o = p.offscreen_create(rec.w, rec.h, f32(rec.s), hook.root_class)
			hook.setup(o)
		} else if rec.w != o.width || rec.h != o.height || f32(rec.s) != o.scale {
			// The window reallocated its buffer at the new size; so does this,
			// keeping the context (focus, scroll offsets, widget state).
			p.canvas_destroy(&o.canvas)
			delete(o.px)
			dw, dh := rec.w * rec.s, rec.h * rec.s
			o.px = make([]u32, dw * dh)
			o.canvas = p.canvas_from(o.px, dw, dh, f32(rec.s))
			o.width, o.height, o.scale = rec.w, rec.h, f32(rec.s)
			o.view = {f32(rec.w), f32(rec.h)}
		}

		in_ := &o.input
		in_.mouse = {transmute(f32)rec.mx, transmute(f32)rec.my}
		in_.mouse_delta = {transmute(f32)rec.mdx, transmute(f32)rec.mdy}
		in_.scroll = {transmute(f32)rec.sx, transmute(f32)rec.sy}
		for b in p.Mouse_Button {
			bit := 1 << uint(b)
			in_.down[b] = rec.down & bit != 0
			in_.pressed[b] = rec.pr & bit != 0
			in_.released[b] = rec.re & bit != 0
		}
		in_.over_surface = rec.over != 0
		in_.focused = rec.focused != 0
		in_.mods = transmute(p.Modifiers)u8(rec.mods)
		in_.click_serial = rec.serial
		clear(&in_.keys)
		for k in rec.keys {
			append(&in_.keys, p.Key_Event{sym = k[0], mods = transmute(p.Modifiers)u8(k[1]), repeat = k[2] != 0, unshifted = k[3]})
		}
		strings.builder_reset(&in_.text)
		for r in rec.text {
			strings.write_rune(&in_.text, rune(r))
		}

		// What the page's clipboard answered this frame, answered again by the
		// offscreen clipboard (a Ctx with no App).
		for c in rec.clip {
			if len(c) < 2 {
				continue
			}
			sb := strings.builder_make(context.temp_allocator)
			if c[1] != 0 {
				for r in c[2:] {
					strings.write_rune(&sb, rune(r))
				}
			}
			if c[0] == 0 {
				p.clipboard_set(&o.ctx, strings.to_string(sb))
			} else {
				p.primary_set(&o.ctx, strings.to_string(sb))
			}
		}

		t0 := time.tick_now()
		ui := p.offscreen_begin(o)
		// The windowed loop's clock, not the offscreen renderer's fixed step.
		ui.dt = transmute(f32)rec.dt
		ui.now = transmute(f64)rec.now
		hook.frame(ui)
		p.offscreen_end(o)
		ms := time.duration_milliseconds(time.tick_since(t0))
		fmt.sbprintf(&times, "%s{{\"n\":%d,\"ms\":%.3f}}", frames > 0 ? "," : "", rec.n, ms)
		frames += 1

		if dump_all || rec.n in dump {
			px := p.offscreen_pixels(o)
			rgba := make([]u8, len(px) * 4)
			for v, i in px {
				rgba[i * 4 + 0] = u8(v >> 16)
				rgba[i * 4 + 1] = u8(v >> 8)
				rgba[i * 4 + 2] = u8(v)
				rgba[i * 4 + 3] = 255
			}
			if werr := os.write_entire_file(fmt.tprintf("%s/native-%d.rgba", out, rec.n), rgba); werr != nil {
				fmt.eprintfln("replay: cannot write frame %d: %v", rec.n, werr)
				os.exit(1)
			}
			delete(rgba)
		}
		free_all(context.temp_allocator)
	}
	strings.write_string(&times, "]\n")
	_ = os.write_entire_file(fmt.tprintf("%s/native-times.json", out), transmute([]u8)strings.to_string(times))
	fmt.printfln("replay: %d frames", frames)
	os.exit(0)
}
