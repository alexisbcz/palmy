// render — draw one shadcn case with palmy, at exactly the size the browser
// gave the same component, and dump the geometry for numeric comparison.
//
//   render <case-id> [...]     render the named cases
//   render --all               render every registered case
//   render --list              print the registered case ids
//
// Sizes come from parity/out/web/<id>.json, so a case can only be rendered
// after the browser capture has run. Nothing here reads the browser's pixels.
package main

import "core:encoding/json"
import "core:math"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import stbi "vendor:stb/image"
import p "palmy:."
import sc "shadcn:."

Case_Proc :: proc(ui: ^p.Ctx)

Case :: struct {
	id:   string,
	draw: Case_Proc,
}

MAX_CASES :: 1024

// A fixed table keeps `add_case` usable from @(init) without depending on
// allocator setup order.
cases: [MAX_CASES]Case
case_count: int

add_case :: proc "contextless" (id: string, draw: Case_Proc) {
	if case_count >= MAX_CASES {
		return
	}
	cases[case_count] = Case{id = id, draw = draw}
	case_count += 1
}

find_case :: proc(id: string) -> (Case, bool) {
	for i in 0 ..< case_count {
		if cases[i].id == id {
			return cases[i], true
		}
	}
	return {}, false
}

ROOT := "/home/alex/Work/palmy/parity"

// png_size reads the reference screenshot's pixel dimensions. Playwright crops
// an element on whole-pixel boundaries, so the image can be a pixel wider than
// the element's own box; the canvas has to match the image, not the box.
png_size :: proc(path: string) -> (w, h: int, ok: bool) {
	data, err := os.read_entire_file_from_path(path, context.temp_allocator)
	if err != nil {
		return 0, 0, false
	}
	x, y, comp: i32
	if stbi.info_from_memory(raw_data(data), i32(len(data)), &x, &y, &comp) == 0 {
		return 0, 0, false
	}
	return int(x), int(y), true
}

// target_size reads the root element's box out of the browser capture.
target_size :: proc(id: string) -> (w, h, dx, dy: f32, ok: bool) {
	path := fmt.tprintf("%s/out/web/%s.json", ROOT, id)
	data, err := os.read_entire_file_from_path(path, context.temp_allocator)
	if err != nil {
		return 0, 0, 0, 0, false
	}
	value, perr := json.parse(data, allocator = context.temp_allocator)
	if perr != nil {
		return 0, 0, 0, 0, false
	}
	obj, is_obj := value.(json.Object)
	if !is_obj {
		return 0, 0, 0, 0, false
	}
	rect, has_rect := obj["rect"].(json.Object)
	if !has_rect {
		return 0, 0, 0, 0, false
	}
	fw, _ := rect["w"].(json.Float)
	fh, _ := rect["h"].(json.Float)

	// The screenshot is clipped to whole pixels, so the element sits at a
	// fractional offset inside it.
	if off, has_off := obj["cropOffset"].(json.Object); has_off {
		ox, _ := off["x"].(json.Float)
		oy, _ := off["y"].(json.Float)
		dx, dy = f32(ox), f32(oy)
	}
	return f32(fw), f32(fh), dx, dy, fw > 0 && fh > 0
}

// pin_fonts loads the exact files the browser is pinned to, so any difference
// in text is rasterisation and not a different typeface.
pin_fonts :: proc(f: ^p.Fonts) {
	// The isolation route sets `font-kerning: none`, so the browser lays text
	// out on plain advances. Match it: Geist carries GPOS pairs that stb does
	// not fully read, and leaving kerning on here would shift every string.
	f.no_kerning = true

	dir := fmt.tprintf("%s/web/public/fonts", ROOT)
	pairs := [?]struct {
		file: string,
		wt:   p.Font_Weight,
	}{
		{"Geist-400.ttf", .Regular},
		{"Geist-500.ttf", .Medium},
		{"Geist-600.ttf", .Semibold},
		{"Geist-700.ttf", .Bold},
	}
	for pair in pairs {
		path := fmt.tprintf("%s/%s", dir, pair.file)
		if !p.load_font(f, path, .Sans, pair.wt) {
			fmt.eprintfln("warning: could not pin %s", path)
		}
		// shadcn uses the same family for mono-ish spots in these cases.
		p.load_font(f, path, .Mono, pair.wt)
	}
}

render_case :: proc(c: Case) -> (ok: bool, note: string) {
	w, h, dx, dy, have := target_size(c.id)
	if !have {
		return false, "no browser capture"
	}

	// Canvas from the reference image, layout at the element's exact size.
	ref := fmt.tprintf("%s/out/web/%s.png", ROOT, c.id)
	cw, ch, png_ok := png_size(ref)
	if !png_ok {
		cw, ch = int(math.ceil(w)), int(math.ceil(h))
	}

	off := p.offscreen_create(cw, ch, 1, "bg-white text-foreground")
	defer p.offscreen_destroy(off)
	p.offscreen_viewport(off, f32(cw), f32(ch))
	pin_fonts(&off.fonts)

	// Two frames: the first settles text wrapping, the second is measured.
	for _ in 0 ..< 2 {
		draw_case_frame(p.offscreen_begin(off), c, w, dx, dy)
		p.offscreen_end(off)
	}

	png := fmt.tprintf("%s/out/odin/%s.png", ROOT, c.id)
	if !p.offscreen_write_png(off, png) {
		return false, "could not write png"
	}
	dump_geometry(off, c.id)
	return true, ""
}

// draw_case_frame places the component where the browser placed it inside the
// screenshot, and gives it the width its container had. Height is deliberately
// left to the component, so a wrong height still shows up as a difference.
draw_case_frame :: proc(ui: ^p.Ctx, c: Case, width, dx, dy: f32) {
	p.div(ui, "absolute")
	p.style(ui).inset[p.LEFT] = p.px(dx)
	p.style(ui).inset[p.TOP] = p.px(dy)
	p.style(ui).w = p.px(width)
	c.draw(ui)
	p.end(ui)
}

// dump_geometry writes palmy's own boxes in the same shape as the browser's
// capture, so the two can be diffed as numbers.
dump_geometry :: proc(off: ^p.Offscreen, id: string) {
	b := strings.builder_make(context.temp_allocator)
	ui := &off.ctx

	strings.write_string(&b, "{\n  \"nodes\": [\n")
	n := p.node_count(ui)
	for i in 0 ..< n {
		r := p.node_rect(ui, i)
		st := p.node_style(ui, i)
		text := p.node_text(ui, i)
		if i > 0 {
			strings.write_string(&b, ",\n")
		}
		fmt.sbprintf(
			&b,
			`    {{"i":%d,"parent":%d,"kind":"%v","rect":{{"x":%.2f,"y":%.2f,"w":%.2f,"h":%.2f}},` +
			`"bg":"#%02x%02x%02x%02x","fg":"#%02x%02x%02x%02x","radius":[%.1f,%.1f,%.1f,%.1f],` +
			`"font":%.1f,"weight":"%v","text":%q}}`,
			i,
			p.node_parent(ui, i),
			p.node_kind(ui, i),
			r.x, r.y, r.w, r.h,
			st.bg.color.r, st.bg.color.g, st.bg.color.b, st.bg.color.a,
			st.fg.r, st.fg.g, st.fg.b, st.fg.a,
			st.radius[0], st.radius[1], st.radius[2], st.radius[3],
			st.font_size, st.weight, text,
		)
	}
	strings.write_string(&b, "\n  ]\n}\n")

	path := fmt.tprintf("%s/out/odin/%s.geom.json", ROOT, id)
	_ = os.write_entire_file(path, transmute([]u8)strings.to_string(b))
}

main :: proc() {
	// Design tokens are global, so register them once before anything renders.
	sc.register_shadcn_theme()

	// Glyph coverage boost, calibrated against Chromium. stb_truetype's
	// unhinted coverage renders systematically lighter than FreeType's hinted,
	// gamma-corrected output; sweeping this over all 162 captured cases put the
	// minimum at 1.8 (mean absolute error 5.02 -> 4.64). It is a fit to one
	// browser and one typeface, which is why it lives here and not in palmy's
	// defaults. PALMY_TEXT_GAMMA re-sweeps it without a rebuild.
	p.set_text_gamma(1.8)
	if g := os.get_env("PALMY_TEXT_GAMMA", context.temp_allocator); g != "" {
		if v, vok := strconv.parse_f32(g); vok {
			p.set_text_gamma(v)
		}
	}

	args := os.args[1:]
	if len(args) == 0 {
		fmt.eprintln("usage: render <case-id>... | --all | --list")
		os.exit(2)
	}

	if args[0] == "--measure" {
		measure_text_cli(args[1:])
		return
	}

	if args[0] == "--icons" {
		icon_sheet(len(args) > 1 ? args[1] : "icons.png")
		return
	}

	if args[0] == "--list" {
		for i in 0 ..< case_count {
			fmt.println(cases[i].id)
		}
		return
	}

	_ = os.make_directory(fmt.tprintf("%s/out/odin", ROOT))

	// Not the temp allocator: each case frees temp memory when it finishes,
	// which would pull this list out from under the loop.
	todo := make([dynamic]Case)
	defer delete(todo)
	if args[0] == "--all" {
		for i in 0 ..< case_count {
			append(&todo, cases[i])
		}
	} else {
		for a in args {
			if c, found := find_case(a); found {
				append(&todo, c)
			} else {
				fmt.eprintfln("unknown case: %s", a)
			}
		}
	}

	done, failed := 0, 0
	for c in todo {
		ok, note := render_case(c)
		if ok {
			done += 1
		} else {
			failed += 1
			fmt.eprintfln("skip %-40s %s", c.id, note)
		}
		free_all(context.temp_allocator)
	}
	fmt.printfln("rendered %d, skipped %d, registered %d", done, failed, case_count)
}
