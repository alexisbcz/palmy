// `clipboard --shots <dir>`: render the history browser offscreen and write
// PNGs. No compositor, no window, and — the point of this file — no clipboard.
//
// This is a clipboard history manager, so a screenshot of it is the one place
// where rendering the real state would be a disclosure: a history holds
// whatever the user last copied, which is routinely a password, a token or a
// private message. So the shot path never loads the stored history, never
// starts the watcher thread, and never runs `wl-paste` or `wl-copy`. It builds
// a fabricated history in memory, in this file, and renders that. `HOME` is
// redirected to a scratch directory first as a second line of defence, so even
// a stray `save_locked` cannot reach the real file.
package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import kit "kit:."
import p "palmy:."
import sc "shadcn:."

// shot_fonts loads exactly what `kit.start` loads into a window.
@(private = "file")
shot_fonts :: proc(off: ^p.Offscreen) {
	for pair in ([?]struct {
		file: string,
		wt:   p.Font_Weight,
	}{
		{"Geist-400.ttf", .Regular},
		{"Geist-500.ttf", .Medium},
		{"Geist-600.ttf", .Semibold},
		{"Geist-700.ttf", .Bold},
	}) {
		p.load_font(&off.fonts, fmt.tprintf("%s/%s", kit.FONT_DIR, pair.file), .Sans, pair.wt)
	}
	for wt in p.Font_Weight {
		p.use_synthetic_italic(&off.fonts, .Sans, wt)
	}
	for path in ([?]string {
		"/usr/share/fonts/TTF/JetBrainsMonoNerdFont-Regular.ttf",
		"/usr/share/fonts/TTF/DejaVuSansMono.ttf",
		"/usr/share/fonts/liberation/LiberationMono-Regular.ttf",
	}) {
		if p.load_font(&off.fonts, path, .Mono, .Regular) {
			p.load_font(&off.fonts, path, .Mono, .Medium)
			p.load_font(&off.fonts, path, .Mono, .Semibold)
			p.load_font(&off.fonts, path, .Mono, .Bold)
			break
		}
	}
	sc.register_shadcn_theme(false)
	p.set_text_gamma(1.8)
	register_dark_theme()
}

// shot_text builds one fabricated text entry. Nothing here came from a
// clipboard; every string is written out in this file.
@(private = "file")
shot_text :: proc(text, mime: string, age: i64, pinned := false) -> Entry {
	e := Entry {
		id     = fnv(transmute([]u8)text),
		kind   = .Text,
		text   = strings.clone(text),
		mime   = strings.clone(mime),
		size   = len(text),
		when_  = now_unix() - age,
		pinned = pinned,
	}
	e.preview = make_preview(e.text)
	e.lower = strings.to_lower(e.text)
	return e
}

// shot_picture draws a plausible-looking invented image — a gradient with a
// few bars across it. The screen is never captured, and no file on disk is
// read: these pixels are computed here.
@(private = "file")
shot_picture :: proc(w, h: int) -> p.Image {
	img := p.Image {
		px              = make([]u32, w * h),
		w               = w,
		h               = h,
		source_channels = 3,
	}
	for y in 0 ..< h {
		fy := f32(y) / f32(h)
		for x in 0 ..< w {
			fx := f32(x) / f32(w)
			r := u32(28 + 40 * fx)
			g := u32(60 + 120 * (1 - fy))
			b := u32(120 + 110 * fx * fy)
			// A few horizontal bars, so the thumbnail has structure rather
			// than being a smooth wash.
			if (y / 18) % 4 == 0 && x > w / 8 && x < w - w / 6 {
				bar := u32(200 + 40 * fx)
				r = bar
				g = min(bar, 235)
				b = 90
			}
			img.px[y * w + x] = 0xff00_0000 | (min(r, 255) << 16) | (min(g, 255) << 8) | min(b, 255)
		}
	}
	return img
}

shots :: proc(dir: string) -> int {
	if err := os.make_directory_all(dir, os.perm(0o700)); err != nil && !os.exists(dir) {
		fmt.eprintfln("clipboard: cannot create %s", dir)
		return 1
	}

	// Belt and braces: `g_test` keeps `copy_back` off `wl-copy`, and a
	// scratch HOME keeps any persistence away from the real history file.
	// `load()` is never called, `watcher_start()` is never called, and so
	// nothing the user ever copied is in this process at all.
	g_test = true
	scratch := strings.clone(fmt.tprintf("%s/clipboard-shot-home", dir))
	defer delete(scratch)
	_ = os.make_directory_all(scratch)
	_ = os.set_env("HOME", scratch)
	// The scratch home exists only so a stray save has somewhere harmless to
	// go; nothing should ever be written into it.
	defer _ = os.remove_all(scratch)

	off := p.offscreen_create(
		WIN_W,
		WIN_H,
		1,
		"w-full h-full flex-col bg-background text-foreground overflow-hidden",
	)
	defer p.offscreen_destroy(off)
	shot_fonts(off)

	// The fabricated history, newest first.
	pic := shot_picture(480, 300)
	thumb := shrink(pic, 480, 300)
	delete(pic.px)

	img := Entry {
		id        = 0x5f3c_a7b1,
		kind      = .Image,
		mime      = strings.clone("image/png"),
		size      = 184_320,
		w         = 1280,
		h         = 800,
		when_     = now_unix() - 240,
		blob      = strings.clone("/var/lib/palmy-clipboard/blobs/3f9c0a71e5.png"),
		thumb     = thumb,
		has_thumb = true,
	}
	img.preview = strings.clone("Screenshot 1280 × 800")
	img.lower = strings.clone("screenshot 1280 x 800")

	append(
		&g.items,
		shot_text(
			"odin build apps/clipboard -collection:palmy=./palmy -o:speed",
			"text/plain;charset=utf-8",
			45,
		),
	)
	append(&g.items, img)
	append(
		&g.items,
		shot_text("https://odin-lang.org/docs/overview/#procedures", "text/plain;charset=utf-8", 900),
	)
	append(
		&g.items,
		shot_text(
			"shrink :: proc(src: p.Image, max_w, max_h: int) -> p.Image {\n\ts := min(f32(max_w) / f32(src.w), f32(max_h) / f32(src.h), 1)\n\tdw := max(1, int(f32(src.w) * s))\n\tdh := max(1, int(f32(src.h) * s))\n\treturn resample(src, dw, dh)\n}",
			"text/plain;charset=utf-8",
			1_800,
		),
	)
	append(
		&g.items,
		shot_text(
			"The averaging reducer exists because nearest-neighbour turned a screenshot of text into noise. Every source pixel that lands in a destination cell is summed and divided, which costs nothing at thumbnail sizes and is the difference between a readable row and a smear.",
			"text/plain;charset=utf-8",
			5_400,
		),
	)
	append(&g.items, shot_text("/var/log/palmy/render.log", "text/plain;charset=utf-8", 9_000))
	append(
		&g.items,
		shot_text(
			"{\"frame\": 3184, \"layout_ms\": 0.42, \"paint_ms\": 1.17, \"nodes\": 2096}",
			"application/json",
			18_000,
			true,
		),
	)
	append(
		&g.items,
		shot_text("SELECT name, cap FROM panes WHERE cap > 0 ORDER BY name;", "text/plain;charset=utf-8", 40_000),
	)
	defer {
		for &e in g.items {
			free_entry(&e)
		}
		delete(g.items)
	}

	// The monitoring badge and the "skipped" counter are what the window
	// shows when the watcher is running; the watcher is *not* running here,
	// these are display state only.
	sync.atomic_store(&g.enabled, true)
	sync.atomic_store(&g.captured, 8)
	sync.atomic_store(&g.secrets, 2)

	st := St {
		query   = make([dynamic]u8),
		hits    = make([dynamic]Ranked),
		have_wl = true,
	}
	defer delete(st.query)
	defer delete(st.hits)

	step :: proc(off: ^p.Offscreen, st: ^St) {
		ui := p.offscreen_begin(off)
		refilter(st)
		handle_keys(ui, nil, st)
		refilter(st)
		build(ui, st)
		p.offscreen_end(off)
		off.input.mods = {}
	}

	shot :: proc(off: ^p.Offscreen, dir, name: string) {
		// Not tprintf: `offscreen_end` frees the temp allocator between frames.
		out := fmt.aprintf("%s/%s.png", dir, name)
		defer delete(out)
		if !p.offscreen_write_png(off, out) {
			fmt.eprintfln("clipboard: cannot write %s", out)
			return
		}
		fmt.printfln("  %s (%dx%d)", out, WIN_W, WIN_H)
	}

	step(off, &st) // settle the first layout
	step(off, &st)
	shot(off, dir, "app-clipboard")

	// Searching, with the fuzzy match picked out in the rows.
	p.type_text(off, "shrink")
	step(off, &st)
	step(off, &st)
	shot(off, dir, "02-clipboard-search")

	// Back to everything, then the Images filter with the picture selected.
	p.press_key(off, 'u', {.Ctrl})
	step(off, &st)
	for _ in 0 ..< 2 {
		p.press_key(off, p.KEY_TAB)
		step(off, &st)
	}
	step(off, &st)
	shot(off, dir, "03-clipboard-image")

	// Back to All (Tab cycles the filter), then down to the long prose entry,
	// which is what the detail pane's wrapping is for.
	for _ in 0 ..< 2 {
		p.press_key(off, p.KEY_TAB)
		step(off, &st)
	}
	for _ in 0 ..< 4 {
		p.press_key(off, p.KEY_DOWN)
		step(off, &st)
	}
	step(off, &st)
	shot(off, dir, "04-clipboard-detail")

	drop_preview(&st)
	return 0
}
