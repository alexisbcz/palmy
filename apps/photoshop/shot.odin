package main

// `photoshop --shot <file.png> [overlay]` renders the whole interface through
// palmy's offscreen path and writes it out.
//
// This exists because it is the only way to look at the app without opening a
// window: this machine runs a dozen of these at once, and a stray toplevel
// re-tiles the compositor underneath whatever else is being recorded. The
// offscreen renderer runs the identical build, layout and paint code the
// windowed loop runs, so what it writes is what the window shows.

import "core:fmt"
import "core:strconv"
import "core:strings"
import p "palmy:."
import sc "shadcn:."

SHOT_W :: 1360
SHOT_H :: 860

shot_overlay :: proc(name: string) -> Overlay {
	switch name {
	case "help":
		return .Help
	case "new":
		return .New_Doc
	case "open":
		return .Open
	case "save":
		return .Save_As
	case "picker":
		return .Picker
	case "adjust-menu":
		return .Adjust_Menu
	case "adjust":
		return .Adjust
	case "filter-menu":
		return .Filter_Menu
	case "filter":
		return .Filter
	case "layer-menu":
		return .Layer_Menu
	case "rename":
		return .Rename
	}
	return .None
}

render_shot :: proc(path: string, what: string, tool: Tool, w := SHOT_W, h := SHOT_H) -> bool {
	off := p.offscreen_create(
		w,
		h,
		1,
		"w-full h-full flex-col bg-background text-foreground overflow-hidden relative",
	)
	defer p.offscreen_destroy(off)

	for pair in ([?]struct {
		file: string,
		wt:   p.Font_Weight,
	}{
		{"Geist-400.ttf", .Regular},
		{"Geist-500.ttf", .Medium},
		{"Geist-600.ttf", .Semibold},
		{"Geist-700.ttf", .Bold},
	}) {
		p.load_font(&off.fonts, fmt.tprintf("%s/%s", kit_font_dir(), pair.file), .Sans, pair.wt)
	}
	for mono in ([?]string {
		"/usr/share/fonts/TTF/JetBrainsMonoNerdFont-Regular.ttf",
		"/usr/share/fonts/TTF/DejaVuSansMono.ttf",
		"/usr/share/fonts/liberation/LiberationMono-Regular.ttf",
	}) {
		if p.load_font(&off.fonts, mono, .Mono, .Regular) {
			p.load_font(&off.fonts, mono, .Mono, .Medium)
			p.load_font(&off.fonts, mono, .Mono, .Semibold)
			p.load_font(&off.fonts, mono, .Mono, .Bold)
			break
		}
	}
	sc.register_shadcn_theme(true)
	p.set_text_gamma(1.8)
	register_editor_theme()

	st: St
	st_init(&st)
	new_document(&st, 1024, 768, 0)
	starter_content(&st)
	st.tool = tool
	defer doc_free(&st.doc)
	defer hist_free(&st.hist)
	defer stroke_free(&st.stroke)

	// Something to look at: a stroke, a selection, and a non-trivial history.
	demo_content(&st)

	ov := shot_overlay(what)

	// Three passes. The first establishes the layout `rect_of` reports, the
	// second lets the canvas fit itself to that rectangle, the third is the one
	// that is written — the same one-frame settling the window does on its
	// first configure.
	for pass in 0 ..< 3 {
		if pass == 2 && ov != .None {
			open_overlay(&st, ov)
			if ov == .Adjust {
				st.adj_kind = .Brightness_Contrast
				st.adj_v = {0 = 28, 1 = 35, 2 = 0, 3 = 0, 4 = 0}
			}
			if ov == .Filter {
				st.flt_kind = .Gaussian_Blur
				st.flt_v = {0 = 8, 1 = 0, 2 = 0, 3 = 0, 4 = 0}
			}
			refresh_preview(&st)
		}
		ui := p.offscreen_begin(off)
		build_ui(ui, &st)
		doc_composite(&st.doc)
		p.offscreen_end(off)
	}

	ok := p.offscreen_write_png(off, path)
	fmt.printfln("%s %s", ok ? "wrote" : "failed to write", path)
	return ok
}

kit_font_dir :: proc() -> string {
	return "/home/alex/Work/palmy/parity/web/public/fonts"
}

// demo_content paints something onto the starter document so a screenshot shows
// an edited image rather than three flat shapes.
demo_content :: proc(st: ^St) {
	d := &st.doc
	add_layer(st)
	layer_set_name(active_layer(d), "Paint")

	br := Brush {
		size     = 54,
		hardness = 0.5,
		opacity  = 0.9,
	}
	stroke_begin(&st.stroke, d, false)
	for i in 0 ..= 60 {
		t := f32(i) / 60
		x := 120 + t * 780
		y := 560 + 90 * sin01(t * 3)
		r := stroke_to(&st.stroke, d, br, {x, y}, 0xff_22c55e, clip_rect(st))
		layer_touch(d, st.stroke.pool, r)
	}
	if pool, bbox, base, ok := stroke_end(&st.stroke); ok {
		push_pixel_edit(&st.hist, d, pool, bbox, copy_region(base, d.w, bbox), "Brush")
	}

	st.sel = {520, 120, 880, 420}
	st.has_sel = true
	st.zoom = 0.62
}

sin01 :: proc(t: f32) -> f32 {
	// A cheap smooth wiggle; `math.sin` would do but this keeps the import out.
	x := t - f32(int(t))
	return 4 * x * (1 - x) * 2 - 1
}

// shot_main is the argv handler, kept here so main.odin stays about the app.
shot_main :: proc(args: []string) -> bool {
	path := "/tmp/palmy-photoshop-shot.png"
	what := ""
	tool := Tool.Brush
	w, h := SHOT_W, SHOT_H
	for a, i in args {
		if i == 0 {
			continue // the "--shot" flag itself
		}
		if strings.has_suffix(strings.to_lower(a, context.temp_allocator), ".png") {
			path = a
		} else if t, ok := tool_by_name(a); ok {
			tool = t
		} else if sw, sh, ok2 := parse_size(a); ok2 {
			// `941x1030` — the compositor tiles this window to whatever it
			// likes, so the layout has to be checked at that size too.
			w, h = sw, sh
		} else {
			what = a
		}
	}
	return render_shot(path, what, tool, w, h)
}

parse_size :: proc(s: string) -> (w, h: int, ok: bool) {
	i := strings.index_byte(s, 'x')
	if i <= 0 || i + 1 >= len(s) {
		return 0, 0, false
	}
	a, oka := strconv.parse_int(s[:i])
	b, okb := strconv.parse_int(s[i + 1:])
	if !oka || !okb || a < 200 || b < 200 {
		return 0, 0, false
	}
	return a, b, true
}

tool_by_name :: proc(s: string) -> (Tool, bool) {
	for t in Tool {
		if strings.equal_fold(s, TOOL_NAMES[t]) {
			return t, true
		}
	}
	return .Brush, false
}
