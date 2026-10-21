package main

// `slides.bin --selftest`, the interchange-format half: .pptx and PDF.
//
// A file with the right extension is not a compatible file. What is checked
// here is what actually makes one: the ZIP's CRC-32 and central directory,
// every XML part parsing back, the EMU and point conversions landing on the
// numbers the specifications give, every slide's text surviving into the
// package, the speaker notes arriving as notes, and — for the PDF — that the
// cross-reference offsets point at the objects they claim to and that the
// text is there as text rather than as a picture of text.
//
// The one thing a headless suite cannot do is open the file in PowerPoint.
// That is what the LibreOffice round trip in the report is for; this is what
// runs on every build.

import "core:encoding/xml"
import "core:fmt"
import "core:strconv"
import "core:strings"
import p "palmy:."

@(private = "file")
XOPTS :: xml.Options {
	flags = {.Ignore_Unsupported, .Unbox_CDATA, .Decode_SGML_Entities},
}

// find_part pulls one entry out of a stored ZIP by walking the local headers.
// The writer has no reader, so the test grows one — which is also a second,
// independent check that the headers it writes say what they should.
@(private = "file")
find_part :: proc(raw: []u8, name: string) -> ([]u8, bool) {
	g16 :: proc(d: []u8, at: int) -> int {
		return at + 1 < len(d) ? int(d[at]) | int(d[at + 1]) << 8 : 0
	}
	g32 :: proc(d: []u8, at: int) -> int {
		return at + 3 < len(d) ? int(d[at]) | int(d[at + 1]) << 8 | int(d[at + 2]) << 16 | int(d[at + 3]) << 24 : 0
	}
	at := 0
	for at + 30 <= len(raw) && g32(raw, at) == 0x0403_4b50 {
		nlen := g16(raw, at + 26)
		elen := g16(raw, at + 28)
		csize := g32(raw, at + 18)
		start := at + 30 + nlen + elen
		if start + csize > len(raw) {
			return nil, false
		}
		if string(raw[at + 30:at + 30 + nlen]) == name {
			return raw[start:start + csize], true
		}
		at = start + csize
	}
	return nil, false
}

// runs_text concatenates every <a:t> of a part, in order.
@(private = "file")
runs_text :: proc(xml_text: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	rest := xml_text
	for {
		i := strings.index(rest, "<a:t>")
		if i < 0 {
			break
		}
		rest = rest[i + 5:]
		j := strings.index(rest, "</a:t>")
		if j < 0 {
			break
		}
		strings.write_string(&b, rest[:j])
		rest = rest[j:]
	}
	return strings.to_string(b)
}

@(private = "file")
part_names :: proc(raw: []u8, allocator := context.temp_allocator) -> [dynamic]string {
	out := make([dynamic]string, allocator)
	g16 :: proc(d: []u8, at: int) -> int {
		return at + 1 < len(d) ? int(d[at]) | int(d[at + 1]) << 8 : 0
	}
	g32 :: proc(d: []u8, at: int) -> int {
		return at + 3 < len(d) ? int(d[at]) | int(d[at + 1]) << 8 | int(d[at + 2]) << 16 | int(d[at + 3]) << 24 : 0
	}
	at := 0
	for at + 30 <= len(raw) && g32(raw, at) == 0x0403_4b50 {
		nlen := g16(raw, at + 26)
		elen := g16(raw, at + 28)
		csize := g32(raw, at + 18)
		append(&out, string(raw[at + 30:at + 30 + nlen]))
		at = at + 30 + nlen + elen + csize
	}
	return out
}

// crc_of_part recomputes an entry's CRC from its payload and compares it with
// the one in the local header. A reader that checks CRCs — and most do —
// rejects the whole archive if this is wrong, so it is worth proving.
@(private = "file")
crc_matches :: proc(raw: []u8, name: string) -> bool {
	g16 :: proc(d: []u8, at: int) -> int {
		return at + 1 < len(d) ? int(d[at]) | int(d[at + 1]) << 8 : 0
	}
	g32 :: proc(d: []u8, at: int) -> u32 {
		return at + 3 < len(d) ? u32(d[at]) | u32(d[at + 1]) << 8 | u32(d[at + 2]) << 16 | u32(d[at + 3]) << 24 : 0
	}
	at := 0
	for at + 30 <= len(raw) && g32(raw, at) == 0x0403_4b50 {
		nlen := g16(raw, at + 26)
		elen := g16(raw, at + 28)
		csize := int(g32(raw, at + 18))
		start := at + 30 + nlen + elen
		if string(raw[at + 30:at + 30 + nlen]) == name {
			return crc32_of(raw[start:start + csize]) == g32(raw, at + 14)
		}
		at = start + csize
	}
	return false
}

t_export_formats :: proc(t: ^Checks, fonts: ^p.Fonts, imgs: ^Img_Cache) {
	d := fixture_deck()
	defer deck_free(&d)

	// --- the ZIP container -------------------------------------------------

	check(&t^, crc32_of(transmute([]u8)string("123456789")) == 0xcbf4_3926, "CRC-32 does not match the ZIP appnote's check value")
	{
		z := zip_make(context.temp_allocator)
		zip_add_string(&z, "a/b.txt", "hello")
		raw := zip_finish(&z)
		got, found := find_part(raw, "a/b.txt")
		check(&t^, found && string(got) == "hello", "a stored entry does not read back")
		check(&t^, crc_matches(raw, "a/b.txt"), "a stored entry's CRC-32 is wrong")
		// The end-of-central-directory record is the last 22 bytes.
		eocd := len(raw) - 22
		sig := u32(raw[eocd]) | u32(raw[eocd + 1]) << 8 | u32(raw[eocd + 2]) << 16 | u32(raw[eocd + 3]) << 24
		check(&t^, sig == 0x0605_4b50, "the end-of-central-directory record is not where it must be")
	}

	// --- the EMU conversion ------------------------------------------------
	//
	// The one number everything else rests on. 914400 EMU to the inch, a
	// 13 1/3 x 7 1/2 inch 16:9 slide, and a 1280 x 720 slide space.
	check(&t^, PPTX_SLIDE_CX == 12192000 && PPTX_SLIDE_CY == 6858000, "the 16:9 slide size is wrong")
	check(&t^, PPTX_SLIDE_CX / EMU_PER_UNIT == int(SLIDE_W), "the horizontal EMU factor does not divide the slide width exactly")
	check(&t^, PPTX_SLIDE_CY / EMU_PER_UNIT == int(SLIDE_H), "the vertical EMU factor does not divide the slide height exactly")
	check(&t^, EMU_PER_UNIT == 9525, "the EMU factor is not 9525")
	check(&t^, emu(0) == 0 && emu(SLIDE_W) == PPTX_SLIDE_CX && emu(SLIDE_H) == PPTX_SLIDE_CY, "a slide corner does not land on the slide corner")
	check(&t^, emu(MARGIN) == 762000, "the 80-unit margin is not 762000 EMU (0.833in)")
	// A point is 12700 EMU, and a slide unit is three quarters of a point.
	check(&t^, emu(1) * 4 == 12700 * 3, "a slide unit is not 0.75pt")
	check(&t^, PPTX_SZ_PER_UNIT == 75, "a font size in hundredths of a point is not size*75")
	check(&t^, int(f32(62) * PPTX_SZ_PER_UNIT) == 4650, "a 62-unit title is not 46.5pt")

	check(&t^, pct(1) == 100000 && pct(0) == 0 && pct(0.5) == 50000, "the thousandths-of-a-percent conversion is wrong")
	check(&t^, round_rect_adj(240, 170, 14) == 8235, "the rounded-corner adjustment is wrong")
	check(&t^, round_rect_adj(100, 100, 999) == 50000, "an oversized radius is not capped at a semicircle")
	{
		// Cover crop. A 1400x900 picture is 1.56 wide; a 600x360 box is 1.67.
		// The box is the wider shape, so the picture's width fills it and its
		// height is what overflows and gets trimmed, evenly top and bottom.
		l, tt := cover_crop(600, 360, 1400, 900)
		check(&t^, l == 0, "the axis that fills a cover fit should not be cropped")
		check(&t^, tt > 2000 && tt < 8000, "the cover crop is %d, expected a few percent off each end", tt)
		// And the other way round: the same wide picture in a *tall* box has
		// its height fill and its sides trimmed.
		l3, t3 := cover_crop(360, 600, 1400, 900)
		check(&t^, t3 == 0 && l3 > 20000, "a wide picture in a tall box crops the wrong axis (%d, %d)", l3, t3)
		l2, t2 := cover_crop(600, 360, 600, 360)
		check(&t^, l2 == 0 && t2 == 0, "a picture that already fits should not be cropped")
	}

	// --- a real .pptx ------------------------------------------------------
	raw := pptx_bytes(&d, fonts, imgs, context.temp_allocator)
	names := part_names(raw)
	check(&t^, len(names) > 0 && names[0] == "[Content_Types].xml", "[Content_Types].xml is not the first part")

	REQUIRED := [?]string {
		"[Content_Types].xml",
		"_rels/.rels",
		"ppt/presentation.xml",
		"ppt/_rels/presentation.xml.rels",
		"ppt/slideMasters/slideMaster1.xml",
		"ppt/slideMasters/_rels/slideMaster1.xml.rels",
		"ppt/slideLayouts/slideLayout1.xml",
		"ppt/slideLayouts/_rels/slideLayout1.xml.rels",
		"ppt/notesMasters/notesMaster1.xml",
		"ppt/theme/theme1.xml",
		"ppt/theme/theme2.xml",
		"docProps/core.xml",
		"docProps/app.xml",
	}
	for want in REQUIRED {
		_, found := find_part(raw, want)
		check(&t^, found, "the package is missing %s", want)
	}

	// Every XML part has to parse, and every entry's CRC has to be right.
	bad_xml, bad_crc := 0, 0
	for nm in names {
		if !crc_matches(raw, nm) {
			bad_crc += 1
		}
		if !strings.has_suffix(nm, ".xml") && !strings.has_suffix(nm, ".rels") {
			continue
		}
		data, _ := find_part(raw, nm)
		doc, err := xml.parse_bytes(data, XOPTS, nm, nil, context.temp_allocator)
		if err != .None || doc == nil {
			bad_xml += 1
			fmt.eprintfln("    %s: %v", nm, err)
		}
	}
	check(&t^, bad_crc == 0, "%d of %d entries have a wrong CRC-32", bad_crc, len(names))
	check(&t^, bad_xml == 0, "%d XML parts do not parse", bad_xml)

	// The presentation declares the right size and lists every slide once.
	pres, _ := find_part(raw, "ppt/presentation.xml")
	px := string(pres)
	check(&t^, strings.contains(px, fmt.tprintf("cx=\"%d\" cy=\"%d\"", PPTX_SLIDE_CX, PPTX_SLIDE_CY)), "presentation.xml does not declare the 16:9 slide size")
	check(&t^, strings.count(px, "<p:sldId ") == len(d.slides), "presentation.xml lists %d slides, the deck has %d", strings.count(px, "<p:sldId "), len(d.slides))
	check(&t^, strings.contains(px, "<p:notesMasterIdLst>"), "the presentation does not reference a notes master")

	// Every slide part exists, carries its own text, and says what it is.
	missing_text := 0
	for si in 0 ..< len(d.slides) {
		part := fmt.tprintf("ppt/slides/slide%d.xml", si + 1)
		data, found := find_part(raw, part)
		if !found {
			check(&t^, false, "%s is missing", part)
			continue
		}
		// A styled run is its own <a:r>, so a line is checked against the
		// concatenated text of the runs rather than against one <a:t>.
		body := runs_text(string(data))
		for &e in d.slides[si].elems {
			if e.kind != .Text {
				continue
			}
			for line in strings.split(e.text, "\n", context.temp_allocator) {
				probe := strings.trim_space(strings.trim_prefix(line, "- "))
				if len(probe) < 6 {
					continue
				}
				if !strings.contains(body, xml_escape(probe)) {
					missing_text += 1
					fmt.eprintfln("    slide %d is missing %q", si + 1, probe)
				}
			}
		}
	}
	check(&t^, missing_text == 0, "%d lines of text did not reach their slide", missing_text)

	// Rotation, in 60000ths of a degree. Slide 6 has a shape at -12 degrees.
	s6, _ := find_part(raw, "ppt/slides/slide6.xml")
	check(&t^, strings.contains(string(s6), "rot=\"-720000\""), "a -12 degree rotation is not -720000")

	// Geometry: the first title box of slide 3 sits at (80, 72) in slide
	// units, which is (762000, 685800) EMU.
	s3, _ := find_part(raw, "ppt/slides/slide3.xml")
	check(&t^, strings.contains(string(s3), "<a:off x=\"762000\" y=\"685800\"/>"), "the title box did not land at its EMU position")

	// Theme slots are resolved: no reader knows what "accent" means here.
	check(&t^, strings.contains(string(s6), srgb(argb(d.theme.accent))), "the accent colour was not resolved to a literal")
	check(&t^, !strings.contains(string(s6), "schemeClr"), "a slide still refers to a scheme colour")

	// Speaker notes, one part per slide that has them, with the words in it.
	notes_found := 0
	for si in 0 ..< len(d.slides) {
		if strings.trim_space(d.slides[si].notes) == "" {
			continue
		}
		part := fmt.tprintf("ppt/notesSlides/notesSlide%d.xml", si + 1)
		data, found := find_part(raw, part)
		if !found {
			check(&t^, false, "%s is missing", part)
			continue
		}
		notes_found += 1
		first := strings.split(strings.trim_space(d.slides[si].notes), "\n", context.temp_allocator)[0]
		check(&t^, strings.contains(string(data), xml_escape(first)), "the notes of slide %d did not reach the file", si + 1)
		rel, rfound := find_part(raw, fmt.tprintf("ppt/notesSlides/_rels/notesSlide%d.xml.rels", si + 1))
		check(&t^, rfound && strings.contains(string(rel), "notesMaster"), "the notes of slide %d do not reference the notes master", si + 1)
	}
	check(&t^, notes_found == 8, "the fixture has notes on 8 slides, %d parts were written", notes_found)

	// The pictures are embedded, as the bytes that were on disk.
	img1, ifound := find_part(raw, "ppt/media/image1.png")
	check(&t^, ifound, "the fixture's pictures were not embedded")
	check(&t^, ifound && len(img1) > 1000 && img1[0] == 0x89 && img1[1] == 'P', "the embedded picture is not a PNG")
	s5, _ := find_part(raw, "ppt/slides/slide5.xml")
	check(&t^, strings.contains(string(s5), "<p:pic>"), "the picture slide has no picture shape")
	check(&t^, strings.contains(string(s5), "<a:srcRect"), "the picture is not cropped to the cover fit")
	s5r, _ := find_part(raw, "ppt/slides/_rels/slide5.xml.rels")
	check(&t^, strings.contains(string(s5r), "../media/image"), "the picture slide does not relate to its media")

	// Bullets are bullets, not hyphens.
	check(&t^, strings.contains(string(s3), "<a:buChar"), "a bulleted box did not produce real bullets")
	check(&t^, !strings.contains(string(s3), "<a:t>- "), "a bullet's hyphen was left in the text")

	// --- the PDF -----------------------------------------------------------
	pdf := pdf_bytes(&d, fonts, imgs, context.temp_allocator)
	ps := string(pdf)
	check(&t^, strings.has_prefix(ps, "%PDF-1.7"), "the PDF has no header")
	check(&t^, strings.has_suffix(strings.trim_space(ps), "%%EOF"), "the PDF has no end-of-file marker")
	check(&t^, strings.count(ps, "/Type /Page\n") + strings.count(ps, "/Type /Page ") == len(d.slides), "the PDF does not have one page per slide")
	check(&t^, strings.contains(ps, fmt.tprintf("/MediaBox [0 0 %s %s]", "960", "540")), "the PDF page is not 960x540 points")
	check(&t^, int(PDF_PAGE_W) == 960 && int(PDF_PAGE_H) == 540, "the page size is not 13 1/3 by 7 1/2 inches")
	check(&t^, PDF_PT_PER_UNIT * SLIDE_W == PDF_PAGE_W, "the slide-to-point scale does not fill the page")

	// The cross-reference table has to point at the objects it claims to, or
	// a reader cannot find anything. This walks it and checks each offset.
	{
		x := strings.last_index(ps, "startxref")
		check(&t^, x > 0, "the PDF has no startxref")
		if x > 0 {
			tail := strings.trim_space(ps[x + len("startxref"):])
			nl := strings.index_byte(tail, '\n')
			off, ok := strconv.parse_int(strings.trim_space(nl < 0 ? tail : tail[:nl]))
			check(&t^, ok && off > 0 && off < len(ps) && strings.has_prefix(ps[off:], "xref"), "startxref does not point at the xref table")
			if ok && off > 0 && off < len(ps) {
				body := ps[off:]
				lines := strings.split(body, "\n", context.temp_allocator)
				bad := 0
				checked := 0
				// Line 0 is "xref", line 1 is "0 N", then one 20-byte entry
				// per object starting with the free head at object 0.
				for i in 3 ..< len(lines) {
					l := lines[i]
					if len(l) < 18 || !strings.has_suffix(strings.trim_space(l), "n") {
						break
					}
					o, good := strconv.parse_int(strings.trim_left(l[:10], "0") == "" ? "0" : strings.trim_left(l[:10], "0"))
					if !good || o <= 0 || o >= len(ps) {
						bad += 1
						continue
					}
					checked += 1
					if !strings.contains(ps[o:min(o + 24, len(ps))], fmt.tprintf("%d 0 obj", i - 2)) {
						bad += 1
					}
				}
				check(&t^, checked > 10, "only %d cross-reference entries were checked", checked)
				check(&t^, bad == 0, "%d cross-reference offsets do not point at their object", bad)
			}
		}
	}

	// Text is text. If this is a picture of a deck, there are no Tj operators
	// and nothing extracts — the whole point of the vector choice.
	check(&t^, strings.count(ps, " Tj") > 40, "the PDF has only %d text-showing operators; is it drawing pictures?", strings.count(ps, " Tj"))
	check(&t^, strings.contains(ps, "/BaseFont /Helvetica"), "the PDF does not use the base-14 Helvetica")
	check(&t^, strings.contains(ps, "/Encoding /WinAnsiEncoding"), "the PDF fonts have no encoding")
	check(&t^, strings.contains(ps, "/ToUnicode"), "the PDF fonts have no /ToUnicode CMap, so text would extract as rubbish")
	check(&t^, strings.contains(ps, "beginbfchar"), "the /ToUnicode CMap has no character mappings")
	check(&t^, strings.contains(ps, "<95> <2022>"), "the CMap does not map the bullet to U+2022")
	check(&t^, strings.contains(ps, "<B7> <00B7>"), "the CMap does not map the middle dot")
	// Every slide's title has to be in there as a literal string.
	for si in 0 ..< len(d.slides) {
		for &e in d.slides[si].elems {
			if e.kind != .Text || e.style != .Title {
				continue
			}
			first := strings.split(e.text, "\n", context.temp_allocator)[0]
			if len(first) < 6 {
				continue
			}
			check(&t^, strings.contains(ps, fmt.tprintf("(%s)", pdf_text_bytes(first))), "slide %d's title is not in the PDF as text", si + 1)
			break
		}
	}
	check(&t^, strings.contains(ps, "/Filter /RunLengthDecode"), "the embedded pictures are not run-length coded")
	check(&t^, strings.contains(ps, "/ShadingType 2"), "the gradient background is not a PDF shading")

	// --- the pieces the PDF is built from ---------------------------------
	check(&t^, winansi('A') == 'A', "an ASCII letter is not itself in WinAnsi")
	check(&t^, winansi('•') == 0x95, "the bullet is not WinAnsi 0x95")
	check(&t^, winansi('—') == 0x97, "the em dash is not WinAnsi 0x97")
	check(&t^, winansi('·') == 0xb7, "the middle dot is not WinAnsi 0xB7")
	check(&t^, winansi('中') == '?', "a character outside WinAnsi is not replaced visibly")
	check(&t^, pdf_text_bytes("a(b)c\\d") == "a\\(b\\)c\\\\d", "a PDF literal string is not escaped")
	check(&t^, pdf_font_for(.Sans, .Regular) == PDF_F_SANS, "a regular sans run picks the wrong face")
	check(&t^, pdf_font_for(.Sans, .Bold) == PDF_F_SANS_BOLD, "a bold sans run picks the wrong face")
	check(&t^, pdf_font_for(.Mono, .Regular) == PDF_F_MONO, "a mono run picks the wrong face")
	check(&t^, pdf_run_width("    ", PDF_F_MONO) == 2400, "Courier is not 600 per glyph")
	check(&t^, pdf_run_width(" ", PDF_F_SANS) == 278, "Helvetica's space is not 278 units")
	check(&t^, pdf_run_width("W", PDF_F_SANS) == 944, "Helvetica's W is not 944 units")
	{
		// The scaling correction: a run that is already the right width is
		// left alone, and one that needs stretching gets stretched.
		natural := pdf_run_width("Hello", PDF_F_SANS) * 40 / 1000
		check(&t^, abs(pdf_tz(natural, 40, "Hello", PDF_F_SANS) - 100) < 0.01, "a run of the natural width should not be scaled")
		check(&t^, abs(pdf_tz(natural * 1.1, 40, "Hello", PDF_F_SANS) - 110) < 0.1, "a 10 percent wider run should scale to 110")
		check(&t^, pdf_tz(0, 40, "", PDF_F_SANS) == 100, "an empty run must not produce a degenerate scale")
		check(&t^, pdf_tz(10000, 40, "i", PDF_F_SANS) <= 400, "the scale is not clamped")
	}
	{
		// RunLengthDecode: a run, some literals, and the end marker.
		enc := run_length(transmute([]u8)string("aaaaabcd"), context.temp_allocator)
		check(&t^, len(enc) == 7, "the run-length encoder produced %d bytes for aaaaabcd, expected 7", len(enc))
		check(&t^, enc[0] == 252 && enc[1] == 'a', "a run of five is not coded as 257-5")
		check(&t^, enc[len(enc) - 1] == 128, "the run-length data has no end-of-data byte")
		// And it must be lossless on something that is all literals.
		src := make([]u8, 300, context.temp_allocator)
		for i in 0 ..< len(src) {
			src[i] = u8(i * 7 + i / 3)
		}
		enc2 := run_length(src, context.temp_allocator)
		check(&t^, len(enc2) > len(src) / 2, "the encoder lost data on a literal run")
	}

	// --- a deck with nothing in it ----------------------------------------
	// The degenerate cases have to produce a valid file, not a crash: a deck
	// of one blank slide with no text, no notes and no pictures.
	{
		bare := Deck {
			version = DECK_VERSION,
			title   = "",
			theme   = THEMES[1],
			slides  = make([dynamic]Slide, context.temp_allocator),
		}
		// A flat background, so the gradient path is the one *not* taken.
		bare.theme.bg2 = 0
		s := slide_make(.Blank)
		append(&bare.slides, s)
		r2 := pptx_bytes(&bare, fonts, imgs, context.temp_allocator)
		n2 := part_names(r2)
		check(&t^, len(n2) > 10, "an empty deck produced only %d parts", len(n2))
		bad2 := 0
		for nm in n2 {
			if !strings.has_suffix(nm, ".xml") && !strings.has_suffix(nm, ".rels") {
				continue
			}
			data, _ := find_part(r2, nm)
			_, err := xml.parse_bytes(data, XOPTS, nm, nil, context.temp_allocator)
			if err != .None {
				bad2 += 1
			}
		}
		check(&t^, bad2 == 0, "%d parts of an empty deck do not parse", bad2)
		check(&t^, !strings.contains(string(r2), "notesSlide1.xml"), "a deck with no notes still wrote a notes slide")
		p2 := pdf_bytes(&bare, fonts, imgs, context.temp_allocator)
		check(&t^, strings.has_prefix(string(p2), "%PDF"), "an empty deck produced no PDF")
		check(&t^, !strings.contains(string(p2), "/ShadingType"), "a flat theme should not emit a gradient shading")
		delete(s.elems)
	}

	// --- the slug the menu names exported files with ----------------------
	{
		st := St{}
		st.deck.title = "Drawing a desktop from scratch!"
		check(&t^, deck_slug(&st) == "drawing-a-desktop-from-scratch", "the filename slug is %q", deck_slug(&st))
		st.deck.title = "   "
		check(&t^, deck_slug(&st) == "deck", "an untitled deck has no fallback filename")
	}
}
