package main

// `slides.bin --selftest` — the headless test suite.
//
// Everything this application does that is not pixels on a compositor can be
// checked without one: the model's mutations, the undo stack, snapping, text
// wrapping and the caret round trip, the renderer (into an ordinary buffer),
// the JSON format, and the PNG exporter. The renderer checks probe real pixels
// out of a rendered slide, which is the only way to know the thing draws what
// it says it draws.

import "core:fmt"
import "core:os"
import "core:strings"
import p "palmy:."

Checks :: struct {
	ok:   int,
	fail: int,
}

check :: proc(t: ^Checks, cond: bool, format: string, args: ..any) {
	if cond {
		t.ok += 1
		return
	}
	t.fail += 1
	fmt.eprintf("  FAIL: ")
	fmt.eprintfln(format, ..args)
}

// px_at reads a pixel out of a rendered slide buffer.
@(private = "file")
px_at :: proc(buf: []u32, w: int, x, y: int) -> p.Color {
	v := buf[y * w + x]
	return {u8(v >> 16), u8(v >> 8), u8(v), 255}
}

@(private = "file")
near :: proc(a, b: p.Color, tol: int = 6) -> bool {
	d :: proc(x, y: u8) -> int {return abs(int(x) - int(y))}
	return d(a.r, b.r) <= tol && d(a.g, b.g) <= tol && d(a.b, b.b) <= tol
}

selftest :: proc(exe_dir: string) -> int {
	t: Checks
	fonts: p.Fonts
	fonts_headless(&fonts)
	// The fixture's pictures sit beside the binary when it is built into
	// apps/slides, and in the source tree otherwise; a binary built anywhere
	// else used to fail eight picture checks for want of them.
	asset_root := exe_dir
	if !os.exists(fmt.tprintf("%s/assets/vista.png", exe_dir)) {
		asset_root = #directory
	}
	imgs := img_cache_make(asset_root)

	tmp := os.get_env("TMPDIR", context.temp_allocator)
	if tmp == "" {
		tmp = "/tmp"
	}

	// --- the model -------------------------------------------------------
	d := fixture_deck()
	check(&t, len(d.slides) == 8, "fixture has %d slides, expected 8", len(d.slides))
	all_have_elements := true
	for s in d.slides {
		if len(s.elems) == 0 {
			all_have_elements = false
		}
	}
	check(&t, all_have_elements, "a fixture slide has no elements")
	notes_everywhere := true
	for s in d.slides {
		if strings.trim_space(s.notes) == "" {
			notes_everywhere = false
		}
	}
	check(&t, notes_everywhere, "a fixture slide has no speaker notes")

	// Every layout is reachable and leaves a drawable slide.
	for l in Layout {
		n := slide_add(&d, len(d.slides), l)
		check(&t, d.slides[n].layout == l, "layout %v did not apply", l)
		slide_delete(&d, n)
	}
	check(&t, len(d.slides) == 8, "layout probing changed the deck length (%d)", len(d.slides))

	// Reflowing keeps the words.
	title_before := d.slides[2].elems[0].text
	apply_layout(&d, 2, .Two_Content)
	check(&t, d.slides[2].elems[0].text == title_before, "the title did not survive a layout change")
	check(&t, len(d.slides[2].elems) >= 3, "Two Content produced %d elements", len(d.slides[2].elems))
	apply_layout(&d, 2, .Title_Content)

	// z-order is array order.
	s := &d.slides[5]
	first := s.elems[0]
	n0 := len(s.elems)
	i := elem_raise(s, 0)
	check(&t, i == 1 && s.elems[1].kind == first.kind, "raise did not move the element up")
	i = elem_lower(s, i)
	check(&t, i == 0 && s.elems[0].x == first.x, "lower did not put it back")
	i = elem_to_front(s, 0)
	check(&t, i == len(s.elems) - 1, "to front did not reach the end")
	i = elem_to_back(s, i)
	check(&t, i == 0 && len(s.elems) == n0, "to back did not reach the start")

	j := elem_duplicate(s, 0)
	check(&t, len(s.elems) == n0 + 1, "duplicate did not add an element")
	check(&t, s.elems[j].x == first.x + 28, "the duplicate is not offset")
	elem_delete(s, j)
	check(&t, len(s.elems) == n0, "delete did not remove the duplicate")

	// Hit testing picks the topmost element under a point.
	s.elems[0].x, s.elems[0].y, s.elems[0].w, s.elems[0].h = 100, 100, 200, 200
	elem_to_front(s, 0)
	check(&t, hit_elem(s, 150, 150) == len(s.elems) - 1, "hit testing missed the topmost element")
	check(&t, hit_elem(s, 1270, 10) == -1, "hit testing found an element in an empty corner")

	ns := len(d.slides)
	k := slide_duplicate(&d, 0)
	check(&t, len(d.slides) == ns + 1 && d.slides[k].notes == d.slides[0].notes, "slide duplicate lost the notes")
	slide_delete(&d, k)
	check(&t, len(d.slides) == ns, "slide delete did not remove it")

	// --- undo ------------------------------------------------------------
	st := new(St)
	defer free(st)
	st.deck = d
	st.slide = 5
	st.sel = 0
	st.snap = true
	st.guides = make([dynamic]Guide)
	before := len(cur_slide(st).elems)
	push_history(st, nil)
	elem_delete(cur_slide(st), 0)
	check(&t, len(cur_slide(st).elems) == before - 1, "the test deletion did not happen")
	undo_step(st, nil, false)
	check(&t, len(cur_slide(st).elems) == before, "undo did not restore the element")
	undo_step(st, nil, true)
	check(&t, len(cur_slide(st).elems) == before - 1, "redo did not re-apply the deletion")
	undo_step(st, nil, false)

	// --- snapping --------------------------------------------------------
	st.sel = 0
	e := &cur_slide(st).elems[0]
	e.w, e.h = 200, 100
	e.x = SLIDE_W / 2 - e.w / 2 + 4 // four units off centre
	e.y = 300
	snap_element(st, e, false)
	check(&t, abs(e.x + e.w / 2 - SLIDE_W / 2) < 0.01, "a near-centre element did not snap (x = %.2f)", e.x)
	check(&t, len(st.guides) >= 1, "snapping produced no guide to draw")
	e.x = 300 // far from everything
	st.snap = false
	snap_element(st, e, false)
	check(&t, e.x == 300 && len(st.guides) == 0, "snapping acted while switched off")
	st.snap = true

	// --- text ------------------------------------------------------------
	long := "The quick brown fox jumps over the lazy dog, and then it does the whole thing again twice more for luck."
	lines := wrap_text(&fonts, long, 28, .Regular, 0, 320, false)
	check(&t, len(lines) > 2, "a long string wrapped into %d lines at 320px", len(lines))
	fits := true
	covered := 0
	for l in lines {
		if l.w > 320.5 {
			fits = false
		}
		covered += l.end - l.start
	}
	check(&t, fits, "a wrapped line is wider than the box")
	check(&t, covered >= len(long) - len(lines), "wrapping lost %d bytes", len(long) - covered)

	// The caret round trip: a measured offset maps back to the same index.
	round_trips := true
	for idx in ([?]int{0, 1, 5, 17, 40, len(long)}) {
		x := p.text_width_upto(&fonts, long, idx, 28)
		back := p.text_index_at(&fonts, long, 28, x)
		if back != idx {
			round_trips = false
		}
	}
	check(&t, round_trips, "a caret position did not round trip through the measurements")

	// Bullets get a hanging indent, and the indent is on every wrapped line.
	bl := wrap_text(&fonts, "- a bullet that is quite long and certainly has to wrap at this width", 28, .Regular, 0, 300, true)
	check(&t, len(bl) > 1 && bl[0].bullet && !bl[1].bullet, "the bullet marker is not on the first line only")
	check(&t, bl[0].indent > 0 && bl[1].indent == bl[0].indent, "the hanging indent is not carried to the wrapped line")

	// --- the renderer ----------------------------------------------------
	W :: 640
	H :: 360
	d2 := st.deck
	buf := render_slide_buffer(&d2, 0, W, H, &fonts, &imgs, context.temp_allocator)
	check(&t, near(px_at(buf, W, 3, 3), argb(d2.theme.bg), 10), "the slide background is not the theme background")
	ink := 0
	for v in buf {
		if v != buf[0] {
			ink += 1
		}
	}
	check(&t, ink > W * H / 20, "the rendered slide is nearly empty (%d pixels differ)", ink)

	// A big opaque rectangle lands where the model says it does.
	probe := slide_make(.Blank)
	append(&probe.elems, shape(.Rect, 400, 200, 400, 300, SLOT_ACCENT))
	probe.elems[0].radius = 0
	append(&d2.slides, probe)
	pi := len(d2.slides) - 1
	buf2 := render_slide_buffer(&d2, pi, W, H, &fonts, &imgs, context.temp_allocator)
	cx := int(600.0 / SLIDE_W * W)
	cy := int(350.0 / SLIDE_H * H)
	check(&t, near(px_at(buf2, W, cx, cy), argb(d2.theme.accent)), "the rectangle is not its fill colour at its centre")
	out_x := int(200.0 / SLIDE_W * W)
	check(&t, !near(px_at(buf2, W, out_x, cy), argb(d2.theme.accent)), "the rectangle bled outside its rect")

	// Rotation moves pixels: the same shape turned 45 degrees is not the same
	// image, and its own corner is now empty.
	d2.slides[pi].elems[0].rotation = 45
	buf3 := render_slide_buffer(&d2, pi, W, H, &fonts, &imgs, context.temp_allocator)
	corner_x := int(410.0 / SLIDE_W * W)
	corner_y := int(210.0 / SLIDE_H * H)
	check(&t, near(px_at(buf2, W, corner_x, corner_y), argb(d2.theme.accent)), "the unrotated corner is not filled")
	check(&t, !near(px_at(buf3, W, corner_x, corner_y), argb(d2.theme.accent)), "rotation did not move the corner")

	// Opacity composites rather than replacing.
	d2.slides[pi].elems[0].rotation = 0
	d2.slides[pi].elems[0].opacity = 0.5
	buf4 := render_slide_buffer(&d2, pi, W, H, &fonts, &imgs, context.temp_allocator)
	half := px_at(buf4, W, cx, cy)
	check(
		&t,
		!near(half, argb(d2.theme.accent)) && !near(half, argb(d2.theme.bg)),
		"a half transparent fill is neither blended nor composited",
	)
	ordered_remove(&d2.slides, pi)

	// A thumbnail is the same renderer, and still draws something.
	thumb := render_slide_buffer(&d2, 0, 160, 90, &fonts, &imgs, context.temp_allocator)
	tink := 0
	for v in thumb {
		if v != thumb[0] {
			tink += 1
		}
	}
	check(&t, tink > 160 * 90 / 50, "the 160px thumbnail is nearly empty (%d pixels)", tink)

	// --- images ----------------------------------------------------------
	img, ok := img_get(&imgs, "assets/vista.png")
	check(&t, ok && img.w > 0 && img.h > 0, "the generated picture did not decode (run --make-assets)")
	img2, ok2 := img_get(&imgs, "assets/vista.png")
	check(&t, ok2 && raw_data(img2.px) == raw_data(img.px), "the image cache decoded the same file twice")
	_, bad := img_get(&imgs, "assets/not-here.png")
	check(&t, !bad, "a missing image reported success")

	// --- the file format -------------------------------------------------
	path := fmt.tprintf("%s/palmy-slides-selftest.json", tmp)
	identical, detail := roundtrip(&d2, path)
	check(&t, identical, "the deck does not round trip: %s", detail)

	raw, rerr := os.read_entire_file_from_path(path, context.temp_allocator)
	check(&t, rerr == nil, "the saved deck cannot be read back")
	text := string(raw)
	check(&t, strings.contains(text, `"layout": "Title"`), "layouts are not saved as names")
	check(&t, strings.contains(text, `"style": "Bullets"`), "text styles are not saved as names")
	check(&t, strings.contains(text, `"notes":`), "speaker notes are not in the file")

	// A theme change survives the file, including the face it selects.
	d3 := clone_deck(&d2)
	for th in THEMES {
		if th.mono {
			d3.theme = th
		}
	}
	check(&t, d3.theme.name == "Terminal", "no monospace theme in the table")
	check(&t, theme_family(&d3.theme) == .Mono, "the mono theme does not select the mono face")
	mono_path := fmt.tprintf("%s/palmy-slides-mono.json", tmp)
	if e := save_deck(&d3, mono_path); e != "" {
		check(&t, false, "saving the mono deck failed: %s", e)
	} else {
		back, lerr := load_deck(mono_path)
		check(&t, lerr == "" && back.theme.mono && back.theme.name == "Terminal", "the mono theme did not load back")
	}

	// --- the exporter ----------------------------------------------------
	dir := fmt.tprintf("%s/palmy-slides-selftest-png", tmp)
	n, eerr := export_deck(&d2, dir, &fonts, &imgs)
	check(&t, eerr == "" && n == len(d2.slides), "export wrote %d of %d slides (%s)", n, len(d2.slides), eerr)
	png, perr := os.read_entire_file_from_path(fmt.tprintf("%s/slide-01.png", dir), context.temp_allocator)
	check(
		&t,
		perr == nil && len(png) > 1000 && png[0] == 0x89 && png[1] == 'P' && png[2] == 'N' && png[3] == 'G',
		"slide-01.png is not a PNG",
	)
	sheet, serr := os.read_entire_file_from_path(fmt.tprintf("%s/contact-sheet.png", dir), context.temp_allocator)
	check(&t, serr == nil && len(sheet) > 1000, "the contact sheet was not written")

	// --- the interchange formats ----------------------------------------
	t_export_formats(&t, &fonts, &imgs)

	// --- collaboration -----------------------------------------------------
	t_collab(&t)

	fmt.printfln("%d checks, %d passed, %d failed", t.ok + t.fail, t.ok, t.fail)
	return t.fail == 0 ? 0 : 1
}
