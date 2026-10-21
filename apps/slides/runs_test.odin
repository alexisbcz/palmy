package main

// `slides.bin --selftest`: styled runs, transitions, placeholders and import.
//
// Each group below checks a claim the code makes in its header comment, with
// assertions that fail when the claim stops being true: run lists keep their
// invariants through edits, a styled word is drawn and exported in its style,
// a transition frame is the mix it says it is, the PowerPoint outline has its
// placeholders, and a deck survives a round trip through .pptx.

import "core:fmt"
import "core:os"
import "core:strings"
import kit "kit:."
import p "palmy:."

@(private = "file")
part_of :: proc(raw: []u8, name: string) -> string {
	files, ok := zip_read(raw, context.temp_allocator)
	if !ok {
		return ""
	}
	data, found := zip_find(files, name)
	return found ? string(data) : ""
}

@(private = "file")
px :: proc(buf: []u32, w, x, y: int) -> p.Color {
	v := buf[y * w + x]
	return {u8(v >> 16), u8(v >> 8), u8(v), 255}
}

t_runs :: proc(t: ^Checks, fonts: ^p.Fonts, imgs: ^Img_Cache) {
	// --- the run list --------------------------------------------------------
	{
		text := "Ship it fast, then fix it"
		r := runs_apply(nil, len(text), 8, 12, .Bold)
		check(t, len(r) == 1 && r[0].start == 8 && r[0].end == 12 && r[0].bold, "bold on [8,12) is one run: %v", r)
		r = runs_apply(r, len(text), 10, 16, .Italic)
		check(t, len(r) == 3, "an overlapping italic splits it into three runs, got %d", len(r))
		r2 := runs_apply(r, len(text), 0, len(text), .Plain)
		check(t, len(r2) == 0, "plain over everything clears every run")
		check(t, len(r) == 3, "and leaves the list it was given alone (copy on write)")
		// Neighbours with one style merge; a run that changes nothing goes.
		m := runs_clean({{start = 0, end = 3, bold = true}, {start = 3, end = 6, bold = true}, {start = 6, end = 9}}, 9)
		check(t, len(m) == 1 && m[0].end == 6, "runs_clean merges equal neighbours and drops plain runs: %v", m)
		// Typing moves runs: at the end of a bold word it continues bold, in
		// front of it it stays plain.
		b := []Run{{start = 4, end = 8, bold = true}}
		after := runs_splice(b, 8, 0, 3, 15)
		check(t, len(after) == 1 && after[0].start == 4 && after[0].end == 11, "typing at a run's end extends it: %v", after)
		before := runs_splice(b, 4, 0, 2, 14)
		check(t, len(before) == 1 && before[0].start == 6 && before[0].end == 10, "typing at a run's start moves it: %v", before)
		gone := runs_splice(b, 2, 8, 0, 4)
		check(t, len(gone) == 0, "deleting all of a run's text deletes the run")
		over := runs_splice(b, 4, 4, 2, 12)
		check(t, len(over) == 1 && over[0].start == 4 && over[0].end == 6, "typing over a bold selection stays bold: %v", over)
		// The command line replaces whole texts; the styling stays on the
		// words that stayed.
		e := text_box("Revenue grew fast", .Body, 0, 0, 400, 100)
		e.runs = runs_apply(nil, len(e.text), 13, 17, .Bold)
		elem_set_text(&e, "Revenue grew very fast")
		check(t, len(e.runs) == 1 && e.text[e.runs[0].start:e.runs[0].end] == "fast", "set-text keeps \"fast\" bold: %v", e.runs)
		segs := text_segments(&e, 0, len(e.text))
		check(t, len(segs) == 2 && segs[1].s.bold && segs[0].end == segs[1].start, "segments partition the text: %v", segs)
	}

	// --- editing: the window's own path --------------------------------------
	{
		st := state_new(exe_directory())
		st.deck = fixture_deck()
		st.slide = 0
		st.sel = 0 // "Drawing a desktop\nfrom scratch"
		begin_text(st)
		// Select "desktop" with the editor's own selection, as Shift+Left
		// would leave it, and bold it through the command Ctrl+B runs.
		at := strings.index(ed_text(st), "desktop")
		st.ed.anchor = at
		st.ed.caret = at + len("desktop")
		invoke(st, nil, nil, .Run_Bold)
		invoke(st, nil, nil, .Run_Italic)
		invoke(st, nil, nil, .Run_Colour)
		e := cur_elem(st)
		check(t, len(e.runs) == 1 && e.runs[0].italic && e.runs[0].color == SLOT_ACCENT, "Ctrl I and Ctrl Shift C style the selection: %v", e.runs)
		check(t, e.text[e.runs[0].start:e.runs[0].end] == "desktop", "exactly the selected word")
		// Typing into the buffer through ed_replace, the one way it changes,
		// with the log text_keys replays.
		clear(&st.ed.log)
		ed_replace(&st.ed, 0, 0, transmute([]u8)string("Now "), true)
		n := len(e.text)
		for ev in st.ed.log {
			n = n - ev.removed + ev.inserted
			e.runs = runs_splice(e.runs, ev.at, ev.removed, ev.inserted, n)
		}
		e.text = ed_text(st)
		check(t, e.text[e.runs[0].start:e.runs[0].end] == "desktop", "a run follows its word when text is typed before it")
		// Nothing selected: the style is armed for what is typed next.
		st.ed.anchor = st.ed.caret
		invoke(st, nil, nil, .Run_Bold)
		check(t, len(st.ed.pending) == 1 && st.ed.pending[0].op == .Bold, "Ctrl B with no selection arms bold for typing")
		commit_text(st, e)
		st.mode = .Browse
		// Outside the box, the commands style the whole box.
		invoke(st, nil, nil, .Run_Plain)
		check(t, len(e.runs) == 0, "Plain on a selected box clears its runs")
		invoke(st, nil, nil, .Undo)
		check(t, len(cur_slide(st).elems[0].runs) == 1, "and undo brings them back")
	}

	// --- collaboration carries them --------------------------------------------
	{
		runs := []Run{{start = 2, end = 5, bold = true, color = SLOT_ACCENT}, {start = 7, end = 9, italic = true, size = 40}}
		enc := runs_encode(runs)
		dec := runs_decode(enc, 20)
		check(t, fmt.tprintf("%v", dec) == fmt.tprintf("%v", runs), "runs survive the shared register: %s", enc)
		clipped := runs_decode(enc, 6)
		check(t, len(clipped) == 1 && clipped[0].end == 5, "and a run past a concurrently shortened text is clipped, not read out of range")
	}

	// --- rendering -----------------------------------------------------------
	{
		d := Deck {
			theme  = THEMES[0],
			slides = make([dynamic]Slide, context.temp_allocator),
		}
		s := slide_make(.Blank)
		append(&s.elems, text_box("Plain words here", .Body, 100, 100, 1000, 100))
		append(&s.elems, text_box("Plain words here", .Body, 100, 300, 1000, 100))
		e := &s.elems[1]
		e.runs = runs_apply(nil, len(e.text), 0, 5, .Bold)
		e.runs = runs_apply(e.runs, len(e.text), 6, 11, .Color, color = SLOT_ACCENT)
		append(&d.slides, s)
		m := Measure {
			fonts = fonts,
			text  = e.text,
			e     = e,
			size  = 27,
			sc    = 1,
			wt    = .Regular,
			fam   = .Sans,
		}
		plain := m
		plain.e = &s.elems[0]
		check(t, measure_width(&m, 0, 5) > measure_width(&plain, 0, 5) + 0.5, "a bold run measures wider than the same word plain")
		W :: 1280
		H :: 720
		buf := render_slide_buffer(&d, 0, W, H, fonts, imgs, context.temp_allocator)
		// The coloured word: some pixel in its box is near the accent, and
		// none in the plain copy above it is.
		acc := argb(d.theme.accent)
		found, found_plain := false, false
		for y in 300 ..< 340 {
			for x in 100 ..< 400 {
				c := px(buf, W, x, y)
				if abs(int(c.r) - int(acc.r)) < 30 && abs(int(c.g) - int(acc.g)) < 30 && abs(int(c.b) - int(acc.b)) < 30 {
					found = true
				}
				c2 := px(buf, W, x, y - 200)
				if abs(int(c2.r) - int(acc.r)) < 30 && abs(int(c2.g) - int(acc.g)) < 30 && abs(int(c2.b) - int(acc.b)) < 30 {
					found_plain = true
				}
			}
		}
		check(t, found && !found_plain, "the coloured run is drawn in the accent (%v), the plain copy is not (%v)", found, found_plain)
		// A larger run makes its line taller.
		e.runs = runs_apply(e.runs, len(e.text), 12, 16, .Size, size = 60)
		tl := text_layout(fonts, {100, 300, 1000, 100}, 1, e)
		check(t, tl.lines[0].lh > tl.line_h + 10, "a 60-unit run makes its line taller (%.1f vs %.1f)", tl.lines[0].lh, tl.line_h)
		// Italic changes the glyphs.
		e.runs = runs_apply(nil, len(e.text), 0, len(e.text), .Italic)
		bi := render_slide_buffer(&d, 0, W, H, fonts, imgs, context.temp_allocator)
		diff := 0
		for y in 300 ..< 360 {
			for x in 100 ..< 500 {
				if bi[y * W + x] != bi[(y - 200) * W + x] {
					diff += 1
				}
			}
		}
		check(t, diff > 200, "an italic box is drawn differently from the upright one (%d pixels)", diff)
	}

	// --- PPTX and PDF carry the runs -----------------------------------------
	d := fixture_deck()
	raw := pptx_bytes(&d, fonts, imgs, context.temp_allocator)
	{
		s3 := part_of(raw, "ppt/slides/slide3.xml")
		check(t, strings.contains(s3, `b="1" dirty="0"`) && strings.contains(s3, `<a:t>theme slots</a:t>`), "slide 3's bold run is its own a:r")
		check(t, strings.contains(s3, `i="1"`) && strings.contains(s3, `<a:t>plain data</a:t>`), "and its italic run carries i=\"1\"")
		acc := srgb(argb(d.theme.accent))
		check(t, strings.contains(s3, fmt.tprintf(`<a:srgbClr val="%s"/></a:solidFill><a:latin typeface="Arial"/><a:cs typeface="Arial"/></a:rPr><a:t>theme slots`, acc)), "and its colour is the accent's")
		s7 := part_of(raw, "ppt/slides/slide7.xml")
		check(t, strings.contains(s7, fmt.tprintf(`sz="%d"`, 34 * PPTX_SZ_PER_UNIT)), "slide 7's 34-unit run is written at 25.5pt")
	}
	{
		pdf := string(pdf_bytes(&d, fonts, imgs, context.temp_allocator))
		check(t, strings.contains(pdf, "/BaseFont /Helvetica-Oblique"), "the PDF declares the oblique face")
		check(t, strings.contains(pdf, "/F5 ") && strings.contains(pdf, "(plain data) Tj"), "and sets the italic run in it")
	}

	// --- transitions ---------------------------------------------------------
	{
		W :: 8
		H :: 2
		a := make([]u32, W * H, context.temp_allocator)
		b := make([]u32, W * H, context.temp_allocator)
		out := make([]u32, W * H, context.temp_allocator)
		for i in 0 ..< W * H {
			a[i] = 0xff000000
			b[i] = 0xffc8c8c8
		}
		a[5] = 0xff0000ff // a marker in the old slide
		compose_transition(out, a, b, W, H, .Fade, 0, false)
		check(t, out[0] == a[0], "a fade at 0 is the old slide")
		compose_transition(out, a, b, W, H, .Fade, 1, false)
		check(t, out[0] == b[0], "a fade at 1 is the new slide")
		compose_transition(out, a, b, W, H, .Fade, 0.5, false)
		mid := out[0] & 0xff
		check(t, mid > 90 && mid < 110, "a fade half way is half way (%d of 200)", mid)
		compose_transition(out, a, b, W, H, .Push, 0.5, false)
		check(t, out[1] == a[5] && out[W - 1] == b[0], "a push half way has moved the old slide left by half (%x)", out[1])
		compose_transition(out, a, b, W, H, .Push, 0.5, true)
		check(t, out[0] == b[0] && out[4] == a[0], "and pushes the other way going back")
		compose_transition(out, a, b, W, H, .Wipe, 0.5, false)
		check(t, out[0] == b[0] && out[W - 1] == a[W - 1], "a wipe half way shows the new slide on the left, the old on the right")
		compose_transition(out, a, b, W, H, .Wipe, 0.5, true)
		check(t, out[W - 1] == b[W - 1] && out[0] == a[0], "and the other way round going back")

		k, back, secs := transition_kind(&d, 1, 2)
		check(t, k == d.slides[2].transition && !back && secs == 0.6, "moving forward plays the arriving slide's transition")
		k, back, _ = transition_kind(&d, 2, 1)
		check(t, k == d.slides[2].transition && back, "moving back plays the departing slide's, mirrored")

		// The projector's frame and the command line's are one composition.
		f := transition_frame(&d, 2, 3, 0.5, 320, 180, fonts, imgs, context.temp_allocator)
		ra := render_slide_buffer(&d, 2, 320, 180, fonts, imgs, context.temp_allocator)
		rb := render_slide_buffer(&d, 3, 320, 180, fonts, imgs, context.temp_allocator)
		check(t, f[10 * 320 + 10] == rb[10 * 320 + 10] && f[10 * 320 + 310] == ra[10 * 320 + 310], "a wipe frame of the fixture is the new slide left, the old right")

		x := transition_xml(&d.slides[1])
		check(t, x == `<p:transition spd="fast"><p:push dir="l"/></p:transition>`, "slide 2's push is written as %s", x)
		s4 := part_of(raw, "ppt/slides/slide4.xml")
		check(t, strings.contains(s4, `<p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr><p:transition spd="fast"><p:wipe dir="r"/></p:transition></p:sld>`), "and slide 4's wipe follows the colour map, where the schema puts it")
		s1 := part_of(raw, "ppt/slides/slide1.xml")
		check(t, !strings.contains(s1, "p:transition"), "a slide with none writes none")
	}

	// --- placeholders --------------------------------------------------------
	{
		layouts := 0
		for l in Layout {
			lx := part_of(raw, fmt.tprintf("ppt/slideLayouts/slideLayout%d.xml", int(l) + 1))
			if strings.contains(lx, fmt.tprintf(`type="%s"`, PPTX_LAYOUT_TYPE[l])) {
				layouts += 1
			}
		}
		check(t, layouts == len(Layout), "every layout is its own slideLayout part with its type (%d)", layouts)
		ct := part_of(raw, "[Content_Types].xml")
		check(t, strings.count(ct, "slideLayout+xml") == len(Layout), "and each is declared in the content types")
		master := part_of(raw, "ppt/slideMasters/slideMaster1.xml")
		check(t, strings.contains(master, `<p:ph type="title"/>`) && strings.contains(master, `<p:ph type="body" idx="1"/>`), "the master has a title and a body placeholder")
		s1 := part_of(raw, "ppt/slides/slide1.xml")
		check(t, strings.contains(s1, `<p:ph type="ctrTitle"/>`) && strings.contains(s1, `<p:ph type="subTitle" idx="1"/>`), "the title slide's title and subtitle are placeholders")
		rel1 := part_of(raw, "ppt/slides/_rels/slide1.xml.rels")
		check(t, strings.contains(rel1, "slideLayout1.xml"), "and it uses the Title layout")
		s3 := part_of(raw, "ppt/slides/slide3.xml")
		check(t, strings.contains(s3, `<p:ph type="title"/>`) && strings.contains(s3, `<p:ph idx="1"/>`), "a content slide's title and bullets are placeholders")
		s4 := part_of(raw, "ppt/slides/slide4.xml")
		check(t, strings.contains(s4, `<p:ph sz="half" idx="1"/>`) && strings.contains(s4, `<p:ph sz="half" idx="2"/>`), "Two Content has both content placeholders")
		s6 := part_of(raw, "ppt/slides/slide6.xml")
		check(t, !strings.contains(s6, "<p:ph"), "a Blank slide has none")
		// Each ph appears once per slide, on the box it names.
		phs := pptx_placeholders(&d.slides[0])
		check(t, phs[0].tag != "" && phs[1].tag != "" && phs[2].tag == "", "the caption under a title slide stays a text box")
	}

	// --- import: the fixture through .pptx and back --------------------------
	{
		back, rep, err := import_pptx(raw, "")
		check(t, err == "", "the exported deck imports: %s", err)
		check(t, len(back.slides) == len(d.slides), "with every slide (%d)", len(back.slides))
		check(t, back.theme.name == d.theme.name && !back.no_decor, "in its own theme, with the master decoration drawn by the renderer")
		check(t, len(rep.lost) == 0, "and nothing lost: %v", rep.lost)
		same_text, same_style, same_runs, same_box, same_notes, same_tr, same_layout := 0, 0, 0, 0, 0, 0, 0
		total := 0
		for si in 0 ..< min(len(back.slides), len(d.slides)) {
			a := &d.slides[si]
			b := &back.slides[si]
			if a.notes == b.notes {same_notes += 1}
			if a.transition == b.transition {same_tr += 1}
			if a.layout == b.layout {same_layout += 1}
			if len(a.elems) != len(b.elems) {
				fmt.eprintfln("    slide %d: %d elements back, %d out", si + 1, len(b.elems), len(a.elems))
				continue
			}
			for i in 0 ..< len(a.elems) {
				ea, eb := &a.elems[i], &b.elems[i]
				total += 1
				if ea.text == eb.text {same_text += 1}
				if ea.style == eb.style && ea.kind == eb.kind {same_style += 1}
				if fmt.tprintf("%v", ea.runs) == fmt.tprintf("%v", eb.runs) {
					same_runs += 1
				} else {
					fmt.eprintfln("    slide %d element %d runs: %v back as %v", si + 1, i + 1, ea.runs, eb.runs)
				}
				if abs(ea.x - eb.x) < 0.5 && abs(ea.y - eb.y) < 0.5 && abs(ea.w - eb.w) < 0.5 && abs(ea.h - eb.h) < 0.5 {same_box += 1}
			}
		}
		n := len(d.slides)
		check(t, same_layout == n && same_notes == n && same_tr == n, "layouts %d, notes %d and transitions %d of %d come back", same_layout, same_notes, same_tr, n)
		check(t, total > 20 && same_text == total && same_style == total && same_runs == total && same_box == total, "every element comes back: text %d, style %d, runs %d, geometry %d of %d", same_text, same_style, same_runs, same_box, total)
		// And it draws the same.
		differ := 0
		for si in 0 ..< len(back.slides) {
			ra := render_slide_buffer(&d, si, 320, 180, fonts, imgs, context.temp_allocator)
			rb := render_slide_buffer(&back, si, 320, 180, fonts, imgs, context.temp_allocator)
			for v, i in ra {
				if v != rb[i] {
					differ += 1
				}
			}
		}
		// The pictures are named media/imageN.png in the imported deck and
		// were not written (no media directory), so they draw as missing
		// frames: compare only the slides without pictures.
		_ = differ
		differ = 0
		for si in ([?]int{0, 1, 2, 3, 5, 7}) {
			ra := render_slide_buffer(&d, si, 320, 180, fonts, imgs, context.temp_allocator)
			rb := render_slide_buffer(&back, si, 320, 180, fonts, imgs, context.temp_allocator)
			before_n := differ
			for v, i in ra {
				if v != rb[i] {
					differ += 1
				}
			}
			if differ != before_n {
				fmt.eprintfln("    slide %d: %d pixels differ", si + 1, differ - before_n)
				for &e, k in d.slides[si].elems {
					if k < len(back.slides[si].elems) {
						if fmt.tprintf("%v", e) != fmt.tprintf("%v", back.slides[si].elems[k]) {
							fmt.eprintfln("      %v\n      %v", e, back.slides[si].elems[k])
						}
					}
				}
			}
		}
		check(t, differ == 0, "the round-tripped deck renders identically (%d pixels differ)", differ)
	}

	// --- import: a package this program did not write ------------------------
	{
		raw2 := foreign_pptx()
		back, rep, err := import_pptx(raw2, "")
		check(t, err == "" && len(back.slides) == 2, "a hand-written foreign package imports: %s", err)
		if err == "" && len(back.slides) == 2 {
			check(t, back.no_decor && back.title == "Foreign", "as a deck without this program's decoration, titled from core.xml")
			s := &back.slides[0]
			check(t, s.layout == .Title_Content, "the layout type obj is Title + Content (%v)", s.layout)
			title, body := -1, -1
			for &e, i in s.elems {
				if e.kind == .Text && e.style == .Title {title = i}
				if e.kind == .Text && e.style == .Bullets {body = i}
			}
			check(t, title >= 0 && body >= 0, "the title and body placeholders become Title and Bullets boxes")
			if title >= 0 && body >= 0 {
				te := &s.elems[title]
				check(t, abs(te.x - 80) < 0.5 && abs(te.y - 40) < 0.5, "the title takes its position from the layout (%.1f, %.1f)", te.x, te.y)
				be := &s.elems[body]
				check(t, be.text == "- Revenue grew fast this quarter\n- Costs held", "the body keeps its spaces and bullets: %q", be.text)
				ok := false
				for r in be.runs {
					if be.text[r.start:r.end] == "fast" && r.bold && r.color == 0xffc02020 {
						ok = true
					}
				}
				check(t, ok, "\"fast\" is a bold red run: %v", be.runs)
				check(t, abs(text_size(be) - 32) < 0.5, "the body's size is the master's 24pt, 32 units (%.1f)", text_size(be))
			}
			shape_ok := false
			for &e in s.elems {
				if e.kind == .Text && e.text == "In a circle" {
					shape_ok = e.color == 0xffffffff
				}
			}
			check(t, shape_ok, "text in a shape takes the shape style's font colour")
			check(t, s.notes == "Speak slowly.", "the notes come from the notes slide: %q", s.notes)
			check(t, s.transition == .Push && back.slides[1].transition == .Fade, "push stays push and an unknown transition plays as a fade")
			lost := strings.join(rep.lost[:], "; ", context.temp_allocator)
			check(t, strings.contains(lost, "tables") && strings.contains(lost, "split transitions"), "the report names what was lost: %s", lost)
			found_table := false
			for &e in back.slides[1].elems {
				if strings.contains(e.text, "North  ·  42") {
					found_table = true
				}
			}
			check(t, found_table, "a table comes in as its text")
		}
	}

	// --- import: PDF, through poppler ----------------------------------------
	if _, has := kit.run({"sh", "-c", "command -v pdftoppm"}); has {
		tmp := os.get_env("TMPDIR", context.temp_allocator)
		dir := fmt.tprintf("%s/palmy-slides-pdf-import-%d", tmp == "" ? "/tmp" : tmp, os.get_pid())
		_ = os.make_directory_all(dir)
		defer os.remove_all(dir)
		pdf := fmt.tprintf("%s/fx.pdf", dir)
		pdf_write_file(&d, pdf, fonts, imgs)
		media := fmt.tprintf("%s/back-media", dir)
		back, rep, err := import_pdf_file(pdf, media)
		check(t, err == "" && len(back.slides) == len(d.slides), "a PDF imports one slide per page (%d): %s", len(back.slides), err)
		if err == "" && len(back.slides) > 2 {
			e := &back.slides[2].elems[0]
			check(t, e.kind == .Image && e.w == SLIDE_W && e.h == SLIDE_H, "each page is a full-bleed picture")
			check(t, strings.contains(back.slides[2].notes, "The slide is the model"), "with its text in the notes")
			check(t, rep.pictures == len(d.slides) && len(rep.lost) > 0, "and the report says the pages are pictures")
			ic := img_cache_make(dir)
			img_set_deck(&ic, fmt.tprintf("%s/back.json", dir))
			got, ok := img_get(&ic, e.src)
			check(t, ok && got.w == 1920, "the page picture resolves beside the deck and is 1920 wide (%d)", got.w)
		}
	} else {
		fmt.eprintln("  note: pdftoppm is not installed; PDF import is not checked")
	}
}

// foreign_pptx is a minimal package in the shape PowerPoint writes: a master
// with text styles, a layout whose placeholders carry the positions, slides
// whose placeholders carry none, a shape styled by p:style, a table, notes, and
// transitions — one this program knows and one it does not.
@(private = "file")
foreign_pptx :: proc() -> []u8 {
	NSX :: `xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"`
	REL :: `<?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">`
	T :: "http://schemas.openxmlformats.org/officeDocument/2006/relationships/"
	z := zip_make(context.temp_allocator)
	zip_add_string(&z, "_rels/.rels", REL + `<Relationship Id="rId1" Type="` + T + `officeDocument" Target="ppt/presentation.xml"/></Relationships>`)
	zip_add_string(&z, "docProps/core.xml", `<cp:coreProperties xmlns:cp="x" xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>Foreign</dc:title></cp:coreProperties>`)
	zip_add_string(&z, "docProps/app.xml", `<Properties><Application>Microsoft Office PowerPoint</Application></Properties>`)
	zip_add_string(&z, "ppt/presentation.xml", `<p:presentation ` + NSX + `><p:sldIdLst><p:sldId id="256" r:id="rId2"/><p:sldId id="257" r:id="rId3"/></p:sldIdLst><p:sldSz cx="12192000" cy="6858000"/></p:presentation>`)
	zip_add_string(&z, "ppt/_rels/presentation.xml.rels", REL + `<Relationship Id="rId2" Type="` + T + `slide" Target="slides/slide1.xml"/><Relationship Id="rId3" Type="` + T + `slide" Target="slides/slide2.xml"/></Relationships>`)
	zip_add_string(&z, "ppt/theme/theme1.xml", `<a:theme ` + NSX + ` name="Office"><a:themeElements><a:clrScheme name="Office"><a:dk1><a:sysClr val="windowText" lastClr="000000"/></a:dk1><a:lt1><a:sysClr val="window" lastClr="FFFFFF"/></a:lt1><a:dk2><a:srgbClr val="44546A"/></a:dk2><a:lt2><a:srgbClr val="E7E6E6"/></a:lt2><a:accent1><a:srgbClr val="4472C4"/></a:accent1><a:accent2><a:srgbClr val="ED7D31"/></a:accent2></a:clrScheme></a:themeElements></a:theme>`)
	zip_add_string(&z, "ppt/slideMasters/slideMaster1.xml", `<p:sldMaster ` + NSX + `><p:cSld><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/><p:sp><p:nvSpPr><p:cNvPr id="2" name="Title"/><p:cNvSpPr/><p:nvPr><p:ph type="title"/></p:nvPr></p:nvSpPr><p:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="100" cy="100"/></a:xfrm></p:spPr></p:sp></p:spTree></p:cSld><p:clrMap bg1="lt1" tx1="dk1" bg2="lt2" tx2="dk2" accent1="accent1" accent2="accent2"/><p:txStyles><p:titleStyle><a:lvl1pPr><a:defRPr sz="4400"/></a:lvl1pPr></p:titleStyle><p:bodyStyle><a:lvl1pPr><a:buChar char="•"/><a:defRPr sz="2400"><a:solidFill><a:schemeClr val="tx1"/></a:solidFill></a:defRPr></a:lvl1pPr></p:bodyStyle><p:otherStyle><a:lvl1pPr><a:defRPr sz="1800"><a:solidFill><a:schemeClr val="tx1"/></a:solidFill></a:defRPr></a:lvl1pPr></p:otherStyle></p:txStyles></p:sldMaster>`)
	zip_add_string(&z, "ppt/slideMasters/_rels/slideMaster1.xml.rels", REL + `<Relationship Id="rId1" Type="` + T + `theme" Target="../theme/theme1.xml"/></Relationships>`)
	zip_add_string(&z, "ppt/slideLayouts/slideLayout1.xml", `<p:sldLayout ` + NSX + ` type="obj"><p:cSld><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/><p:sp><p:nvSpPr><p:cNvPr id="2" name="Title 1"/><p:cNvSpPr/><p:nvPr><p:ph type="title"/></p:nvPr></p:nvSpPr><p:spPr><a:xfrm><a:off x="762000" y="381000"/><a:ext cx="10668000" cy="952500"/></a:xfrm></p:spPr></p:sp><p:sp><p:nvSpPr><p:cNvPr id="3" name="Content 2"/><p:cNvSpPr/><p:nvPr><p:ph idx="1"/></p:nvPr></p:nvSpPr><p:spPr><a:xfrm><a:off x="762000" y="1714500"/><a:ext cx="10668000" cy="4000500"/></a:xfrm></p:spPr></p:sp></p:spTree></p:cSld></p:sldLayout>`)
	zip_add_string(&z, "ppt/slideLayouts/_rels/slideLayout1.xml.rels", REL + `<Relationship Id="rId1" Type="` + T + `slideMaster" Target="../slideMasters/slideMaster1.xml"/></Relationships>`)
	zip_add_string(
		&z,
		"ppt/slides/slide1.xml",
		`<p:sld ` + NSX + `><p:cSld><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/>` +
		`<p:sp><p:nvSpPr><p:cNvPr id="2" name="Title 1"/><p:cNvSpPr/><p:nvPr><p:ph type="title"/></p:nvPr></p:nvSpPr><p:spPr/><p:txBody><a:bodyPr/><a:p><a:r><a:rPr b="1"/><a:t>What changed</a:t></a:r></a:p></p:txBody></p:sp>` +
		`<p:sp><p:nvSpPr><p:cNvPr id="3" name="Content 2"/><p:cNvSpPr/><p:nvPr><p:ph idx="1"/></p:nvPr></p:nvSpPr><p:spPr/><p:txBody><a:bodyPr/><a:p><a:r><a:t>Revenue grew </a:t></a:r><a:r><a:rPr b="1"><a:solidFill><a:srgbClr val="C02020"/></a:solidFill></a:rPr><a:t>fast</a:t></a:r><a:r><a:t> this quarter</a:t></a:r></a:p><a:p><a:r><a:t>Costs held</a:t></a:r></a:p></p:txBody></p:sp>` +
		`<p:sp><p:nvSpPr><p:cNvPr id="4" name="Oval 3"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr><p:spPr><a:xfrm><a:off x="8000000" y="4000000"/><a:ext cx="2000000" cy="1500000"/></a:xfrm><a:prstGeom prst="ellipse"><a:avLst/></a:prstGeom></p:spPr><p:style><a:lnRef idx="0"><a:schemeClr val="accent1"/></a:lnRef><a:fillRef idx="1"><a:schemeClr val="accent1"/></a:fillRef><a:effectRef idx="0"><a:schemeClr val="accent1"/></a:effectRef><a:fontRef idx="minor"><a:schemeClr val="lt1"/></a:fontRef></p:style><p:txBody><a:bodyPr anchor="ctr"/><a:p><a:pPr algn="ctr"/><a:r><a:t>In a circle</a:t></a:r></a:p></p:txBody></p:sp>` +
		`</p:spTree></p:cSld><p:transition spd="med"><p:push dir="u"/></p:transition></p:sld>`,
	)
	zip_add_string(&z, "ppt/slides/_rels/slide1.xml.rels", REL + `<Relationship Id="rId1" Type="` + T + `slideLayout" Target="../slideLayouts/slideLayout1.xml"/><Relationship Id="rId2" Type="` + T + `notesSlide" Target="../notesSlides/notesSlide1.xml"/></Relationships>`)
	zip_add_string(&z, "ppt/notesSlides/notesSlide1.xml", `<p:notes ` + NSX + `><p:cSld><p:spTree><p:sp><p:nvSpPr><p:cNvPr id="2" name="Notes"/><p:cNvSpPr/><p:nvPr><p:ph type="body" idx="1"/></p:nvPr></p:nvSpPr><p:txBody><a:p><a:r><a:t>Speak slowly.</a:t></a:r></a:p></p:txBody></p:sp></p:spTree></p:cSld></p:notes>`)
	zip_add_string(
		&z,
		"ppt/slides/slide2.xml",
		`<p:sld ` + NSX + `><p:cSld><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/>` +
		`<p:graphicFrame><p:nvGraphicFramePr><p:cNvPr id="2" name="Table"/><p:cNvGraphicFramePr/><p:nvPr/></p:nvGraphicFramePr><p:xfrm><a:off x="762000" y="762000"/><a:ext cx="4000000" cy="1000000"/></p:xfrm><a:graphic><a:graphicData><a:tbl><a:tr><a:tc><a:txBody><a:p><a:r><a:t>Region</a:t></a:r></a:p></a:txBody></a:tc><a:tc><a:txBody><a:p><a:r><a:t>Sales</a:t></a:r></a:p></a:txBody></a:tc></a:tr><a:tr><a:tc><a:txBody><a:p><a:r><a:t>North</a:t></a:r></a:p></a:txBody></a:tc><a:tc><a:txBody><a:p><a:r><a:t>42</a:t></a:r></a:p></a:txBody></a:tc></a:tr></a:tbl></a:graphicData></a:graphic></p:graphicFrame>` +
		`</p:spTree></p:cSld><p:transition><p:split orient="vert"/></p:transition></p:sld>`,
	)
	zip_add_string(&z, "ppt/slides/_rels/slide2.xml.rels", REL + `<Relationship Id="rId1" Type="` + T + `slideLayout" Target="../slideLayouts/slideLayout1.xml"/></Relationships>`)
	return zip_finish(&z)
}
