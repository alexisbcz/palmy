// The interchange formats: .docx, .odt and .rtf out; .docx and .odt in.
//
// A word processor that can only write its own JSON is a toy, however good
// its pagination. These three formats are what "send it to someone" means in
// practice, and all three are written here from scratch — the ZIP container
// in zip.odin, the XML below, no library in between.
//
// The thing worth insisting on is *structure*. It would be easy, and wrong,
// to emit every paragraph as body text with direct formatting that happens to
// look like a heading. Then the document has no outline, no navigation pane,
// no way to restyle, and no accessibility. So the paragraph kinds map onto
// real named styles — `Heading1`, `Quote`, `Code` in Word; `Heading_20_1`,
// `Quote`, `Preformatted_20_Text` in ODF — and the character formatting rides
// on top of them.
//
// Three specification details that bite:
//
//   * `.odt` requires `mimetype` to be the archive's **first** entry and
//     **stored uncompressed**. Nothing here is ever compressed, so the only
//     thing to get right is the order.
//   * ODF collapses runs of spaces, so a code block's indentation vanishes
//     unless the spaces are written as `<text:s text:c="n"/>`.
//   * `.docx` needs `[Content_Types].xml` to declare an override for every
//     part, and a relationship chain from `_rels/.rels` to the document and
//     from `word/_rels/document.xml.rels` to the styles and numbering. A
//     missing link there is the usual reason Word calls a file corrupt.
package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:unicode/utf8"

// ---------------------------------------------------------------------------
// Units
// ---------------------------------------------------------------------------

// The layout is CSS pixels at 96 dpi. Word measures in twentieths of a point
// (twips) and half-points; ODF measures in physical units.
tw :: proc(px: f32) -> int {
	return int(px * 15 + 0.5) // px → pt → twips: px * 0.75 * 20
}

half_pt :: proc(px: f32) -> int {
	return int(px * 1.5 + 0.5) // px → pt → half-points
}

// OOXML drawing sizes are in English Metric Units: 914400 per inch, so 9525
// per CSS pixel at 96 dpi.
emu :: proc(px: f32) -> int {
	return int(px * 9525 + 0.5)
}

// Media is one embedded picture, shared by the .docx and .odt writers: the
// part name inside the archive, the relationship id .docx refers to it by, and
// the original file bytes.
Media :: struct {
	part:  string,
	rid:   string,
	mime:  string,
	ext:   string,
	bytes: []u8,
	img:   ^Doc_Image, // which picture this is, so a cell's can be found too
}

// collect_media walks the document and lists the pictures to embed, in order.
// Both container formats need the list before they can write their manifest,
// and both refer to the entries by index, so it is gathered once.
// It walks the *blocks*, not the top-level paragraphs: a picture inside a
// table cell is a picture to embed like any other, and leaving the cells out
// is how one used to be exported as nothing at all.
collect_media :: proc(d: ^Doc, prefix: string, alloc := context.temp_allocator) -> []Media {
	out := make([dynamic]Media, 0, 4, alloc)
	for blk in doc_blocks(d, context.temp_allocator) {
		pa := blk_para(d, blk)
		if pa == nil || pa.kind != .Image || pa.img == nil || len(pa.img.bytes) == 0 {
			continue
		}
		n := len(out) + 1
		ext := image_ext(pa.img.kind)
		// `tprintf`, not `aprintf`: the list itself is temporary and is
		// consumed inside the one export call, and `zip_add` clones the names
		// it is given.
		append(
			&out,
			Media {
				part = fmt.tprintf("%simage%d.%s", prefix, n, ext),
				rid = fmt.tprintf("rIdImg%d", n),
				mime = image_mime(pa.img.kind),
				ext = ext,
				bytes = pa.img.bytes,
				img = pa.img,
			},
		)
	}
	return out[:]
}

// media_for finds the entry for one picture by identity. The index of the
// paragraph it sits in is not enough any more — a picture in a cell has no
// top-level index — and the picture itself is unique.
media_for :: proc(media: []Media, img: ^Doc_Image) -> (Media, bool) {
	if img == nil {
		return {}, false
	}
	for m in media {
		if m.img == img {
			return m, true
		}
	}
	return {}, false
}

// media_of is the same lookup for a top-level paragraph index, kept because
// that is what the body writers have in hand.
media_of :: proc(d: ^Doc, media: []Media, want: int) -> (Media, bool) {
	if want < 0 || want >= len(d.paras) {
		return {}, false
	}
	return media_for(media, d.paras[want].img)
}

@(private = "file")
xml_escape :: proc(b: ^strings.Builder, s: string) {
	for i in 0 ..< len(s) {
		switch s[i] {
		case '&':
			strings.write_string(b, "&amp;")
		case '<':
			strings.write_string(b, "&lt;")
		case '>':
			strings.write_string(b, "&gt;")
		case '"':
			strings.write_string(b, "&quot;")
		case '\'':
			strings.write_string(b, "&apos;")
		case 0 ..< 0x09, 0x0b, 0x0c, 0x0e ..< 0x20:
			// XML 1.0 cannot represent these at all, not even as a reference.
			strings.write_byte(b, ' ')
		case:
			strings.write_byte(b, s[i])
		}
	}
}

// ---------------------------------------------------------------------------
// .docx
// ---------------------------------------------------------------------------

@(private = "file")
docx_style :: proc(pa: ^Paragraph) -> string {
	switch pa.kind {
	case .H1:
		return "Heading1"
	case .H2:
		return "Heading2"
	case .H3:
		return "Heading3"
	case .Quote:
		return "Quote"
	case .Code:
		return "Code"
	case .Body, .Table, .Image:
		return pa.list != .None ? "ListParagraph" : "BodyText"
	}
	return "BodyText"
}

@(private = "file")
docx_runs :: proc(b: ^strings.Builder, pa: ^Paragraph) {
	for &r in pa.runs {
		text := string(r.text[:])
		if len(text) == 0 {
			continue
		}
		cs := r.style
		strings.write_string(b, "<w:r>")
		if cs.bold || cs.italic || cs.underline || cs.mono || cs.size != 0 || cs.color != 0 {
			strings.write_string(b, "<w:rPr>")
			if cs.mono {
				strings.write_string(
					b,
					"<w:rFonts w:ascii=\"Courier New\" w:hAnsi=\"Courier New\" w:cs=\"Courier New\"/>",
				)
			}
			if cs.bold {strings.write_string(b, "<w:b/>")}
			if cs.italic {strings.write_string(b, "<w:i/>")}
			if cs.underline {strings.write_string(b, "<w:u w:val=\"single\"/>")}
			if cs.color != 0 {
				fmt.sbprintf(b, "<w:color w:val=\"%06X\"/>", cs.color & 0xffffff)
			}
			if cs.size != 0 {
				n := half_pt(cs.size)
				fmt.sbprintf(b, "<w:sz w:val=\"%d\"/><w:szCs w:val=\"%d\"/>", n, n)
			}
			strings.write_string(b, "</w:rPr>")
		}
		// xml:space="preserve" is not optional: without it a run that is just
		// spaces, or one with a leading space, loses it.
		strings.write_string(b, "<w:t xml:space=\"preserve\">")
		xml_escape(b, text)
		strings.write_string(b, "</w:t></w:r>")
	}
}

// docx_ppr writes a paragraph's <w:pPr>. It is shared between a body
// paragraph and a paragraph inside a table cell, which is the whole point of a
// cell holding ordinary paragraphs.
@(private = "file")
docx_ppr :: proc(b: ^strings.Builder, pa: ^Paragraph, in_cell := false) {
	km := kind_metrics(pa.kind)
	strings.write_string(b, "<w:pPr>")
	fmt.sbprintf(b, "<w:pStyle w:val=\"%s\"/>", docx_style(pa))
	if pa.break_before && !in_cell {
		strings.write_string(b, "<w:pageBreakBefore/>")
	}
	if pa.list != .None {
		fmt.sbprintf(
			b,
			"<w:numPr><w:ilvl w:val=\"%d\"/><w:numId w:val=\"%d\"/></w:numPr>",
			min(pa.depth, 8),
			pa.list == .Bullet ? 1 : 2,
		)
	} else if pa.depth > 0 {
		fmt.sbprintf(b, "<w:ind w:left=\"%d\"/>", tw(f32(pa.depth) * DEPTH_INDENT))
	}
	if pa.before != 0 || pa.after != 0 {
		fmt.sbprintf(
			b,
			"<w:spacing w:before=\"%d\" w:after=\"%d\"/>",
			tw(km.before + pa.before),
			tw(km.after + pa.after),
		)
	}
	switch pa.align {
	case .Center:
		strings.write_string(b, "<w:jc w:val=\"center\"/>")
	case .Right:
		strings.write_string(b, "<w:jc w:val=\"right\"/>")
	case .Justify:
		strings.write_string(b, "<w:jc w:val=\"both\"/>")
	case .Left:
	}
	strings.write_string(b, "</w:pPr>")
}

// docx_table writes a <w:tbl>.
//
// Four things in here are not optional, and getting any of them wrong is the
// usual reason Word says a file is corrupt or LibreOffice shows one wide
// column:
//
//   * `<w:tblGrid>` must name every column, and the widths must agree with the
//     `<w:tcW>` in each cell;
//   * every `<w:tc>` must contain at least one `<w:p>`, even an empty one;
//   * `<w:tblLayout w:type="fixed"/>` is what makes the grid widths binding
//     rather than a suggestion the reader may re-fit;
//   * `<w:tblHeader/>` on the first row's `<w:trPr>` is what repeats the header
//     on a page break — the same rule this app's own pagination uses, so the
//     exported file breaks the way the window does.
@(private = "file")
// `media` and `img_seq` are passed in because a cell may hold a picture, and
// the drawing ids have to stay unique across the whole document.
docx_table :: proc(b: ^strings.Builder, t: ^Table, media: []Media, img_seq: ^int) {
	ncols := table_cols(t)
	strings.write_string(b, "<w:tbl><w:tblPr><w:tblStyle w:val=\"TableGrid\"/>")
	fmt.sbprintf(b, "<w:tblW w:w=\"%d\" w:type=\"dxa\"/>", tw(CONTENT_W))
	if t.borders {
		strings.write_string(b, "<w:tblBorders>")
		for side in ([?]string{"top", "left", "bottom", "right", "insideH", "insideV"}) {
			fmt.sbprintf(
				b,
				"<w:%s w:val=\"single\" w:sz=\"6\" w:space=\"0\" w:color=\"A8A8AA\"/>",
				side,
			)
		}
		strings.write_string(b, "</w:tblBorders>")
	} else {
		strings.write_string(b, "<w:tblBorders>")
		for side in ([?]string{"top", "left", "bottom", "right", "insideH", "insideV"}) {
			fmt.sbprintf(b, "<w:%s w:val=\"none\" w:sz=\"0\" w:space=\"0\"/>", side)
		}
		strings.write_string(b, "</w:tblBorders>")
	}
	fmt.sbprintf(
		b,
		"<w:tblCellMar><w:top w:w=\"%d\" w:type=\"dxa\"/><w:left w:w=\"%d\" w:type=\"dxa\"/>" +
		"<w:bottom w:w=\"%d\" w:type=\"dxa\"/><w:right w:w=\"%d\" w:type=\"dxa\"/></w:tblCellMar>",
		tw(CELL_PAD),
		tw(CELL_PAD),
		tw(CELL_PAD),
		tw(CELL_PAD),
	)
	strings.write_string(b, "<w:tblLayout w:type=\"fixed\"/></w:tblPr>")

	strings.write_string(b, "<w:tblGrid>")
	for c in 0 ..< ncols {
		fmt.sbprintf(b, "<w:gridCol w:w=\"%d\"/>", tw(table_width(t, c)))
	}
	strings.write_string(b, "</w:tblGrid>")

	// Every row a merge joins to the header repeats with it, as in the window.
	head_end := table_head_end(t)
	for r in 0 ..< len(t.rows) {
		strings.write_string(b, "<w:tr>")
		head := t.header && r == 0
		strings.write_string(b, "<w:trPr><w:cantSplit/>")
		if r <= head_end {
			strings.write_string(b, "<w:tblHeader/>")
		}
		strings.write_string(b, "</w:trPr>")
		for c in 0 ..< ncols {
			// Merged cells, WordprocessingML's way: across a row, one <w:tc>
			// with `gridSpan`; down a column, a <w:tc> in every row, the first
			// with `vMerge restart` and the rest with a bare `vMerge` and an
			// empty paragraph. So a covered cell in its anchor's row writes
			// nothing, and one below writes a continuation as wide as the
			// anchor when it is in the anchor's column, nothing otherwise.
			span := 1
			vm := ""
			if cl := table_cell(t, r, c); cl != nil {
				if cl.covered {
					ar, ac := table_anchor(t, r, c)
					a := table_cell(t, ar, ac)
					if ar == r || ac != c || a == nil {
						continue
					}
					strings.write_string(b, "<w:tc><w:tcPr>")
					fmt.sbprintf(b, "<w:tcW w:w=\"%d\" w:type=\"dxa\"/>", tw(table_span_w(t, ar, ac)))
					if cell_cspan(a) > 1 {
						fmt.sbprintf(b, "<w:gridSpan w:val=\"%d\"/>", cell_cspan(a))
					}
					strings.write_string(b, "<w:vMerge/>")
					if head {
						strings.write_string(b, "<w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"F1F1F2\"/>")
					}
					strings.write_string(b, "</w:tcPr><w:p/></w:tc>")
					continue
				}
				span = cell_cspan(cl)
				if cell_rspan(cl) > 1 {
					vm = "<w:vMerge w:val=\"restart\"/>"
				}
			}
			strings.write_string(b, "<w:tc><w:tcPr>")
			fmt.sbprintf(b, "<w:tcW w:w=\"%d\" w:type=\"dxa\"/>", tw(table_span_w(t, r, c)))
			if span > 1 {
				fmt.sbprintf(b, "<w:gridSpan w:val=\"%d\"/>", span)
			}
			strings.write_string(b, vm)
			if head {
				strings.write_string(b, "<w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"F1F1F2\"/>")
			}
			strings.write_string(b, "</w:tcPr>")
			cl := table_cell(t, r, c)
			if cl == nil || len(cl.paras) == 0 {
				// A cell with no paragraph is not a legal <w:tc>.
				strings.write_string(b, "<w:p/>")
			} else {
				for &cp in cl.paras {
					strings.write_string(b, "<w:p>")
					docx_ppr(b, &cp, true)
					if cp.kind == .Image {
						// A picture in a cell is the same `<w:drawing>` as one
						// in the body; only its measure differs, and
						// `docx_drawing` is told which.
						if m, got := media_for(media, cp.img); got {
							img_seq^ += 1
							docx_drawing(b, &cp, m, img_seq^, max(20, table_span_w(t, r, c) - 2 * CELL_PAD))
						} else {
							strings.write_string(b, "<w:r><w:t xml:space=\"preserve\">[")
							xml_escape(b, cp.img == nil ? "picture" : (cp.img.alt != "" ? cp.img.alt : cp.img.path))
							strings.write_string(b, "]</w:t></w:r>")
						}
						strings.write_string(b, "</w:p>")
						continue
					}
					if head {
						// A header cell's text is bold, matching the shading.
						for &r2 in cp.runs {
							if len(r2.text) == 0 {
								continue
							}
							cs := r2.style
							cs.bold = true
							strings.write_string(b, "<w:r><w:rPr><w:b/>")
							if cs.italic {strings.write_string(b, "<w:i/>")}
							if cs.underline {strings.write_string(b, "<w:u w:val=\"single\"/>")}
							if cs.mono {
								strings.write_string(
									b,
									"<w:rFonts w:ascii=\"Courier New\" w:hAnsi=\"Courier New\" w:cs=\"Courier New\"/>",
								)
							}
							strings.write_string(b, "</w:rPr><w:t xml:space=\"preserve\">")
							xml_escape(b, string(r2.text[:]))
							strings.write_string(b, "</w:t></w:r>")
						}
					} else {
						docx_runs(b, &cp)
					}
					strings.write_string(b, "</w:p>")
				}
			}
			strings.write_string(b, "</w:tc>")
		}
		strings.write_string(b, "</w:tr>")
	}
	strings.write_string(b, "</w:tbl>")
}

// docx_drawing writes an inline picture: a <w:drawing> holding a DrawingML
// <pic:pic> that points at a relationship, which points at the part in
// word/media. The extents are given twice — once on <wp:extent> for the layout
// and once on <a:ext> for the shape — and a reader that finds them disagreeing
// scales the picture to the wrong size.
@(private = "file")
docx_drawing :: proc(b: ^strings.Builder, pa: ^Paragraph, m: Media, id: int, measure := f32(CONTENT_W)) {
	w, h := image_para_size(pa, measure, CONTENT_H)
	cx, cy := emu(w), emu(h)
	strings.write_string(b, "<w:r><w:drawing>")
	strings.write_string(b, "<wp:inline distT=\"0\" distB=\"0\" distL=\"0\" distR=\"0\">")
	fmt.sbprintf(b, "<wp:extent cx=\"%d\" cy=\"%d\"/>", cx, cy)
	strings.write_string(b, "<wp:effectExtent l=\"0\" t=\"0\" r=\"0\" b=\"0\"/>")
	fmt.sbprintf(b, "<wp:docPr id=\"%d\" name=\"Picture %d\" descr=\"", id, id)
	xml_escape(b, pa.img == nil ? "" : pa.img.alt)
	strings.write_string(b, "\"/>")
	strings.write_string(
		b,
		"<wp:cNvGraphicFramePr><a:graphicFrameLocks xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" noChangeAspect=\"1\"/></wp:cNvGraphicFramePr>",
	)
	strings.write_string(
		b,
		"<a:graphic xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\">" +
		"<a:graphicData uri=\"http://schemas.openxmlformats.org/drawingml/2006/picture\">" +
		"<pic:pic xmlns:pic=\"http://schemas.openxmlformats.org/drawingml/2006/picture\">" +
		"<pic:nvPicPr>",
	)
	fmt.sbprintf(b, "<pic:cNvPr id=\"%d\" name=\"", id)
	xml_escape(b, base_name(m.part))
	strings.write_string(b, "\" descr=\"")
	xml_escape(b, pa.img == nil ? "" : pa.img.alt)
	strings.write_string(b, "\"/><pic:cNvPicPr/></pic:nvPicPr><pic:blipFill>")
	fmt.sbprintf(b, "<a:blip r:embed=\"%s\"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>", m.rid)
	strings.write_string(b, "<pic:spPr><a:xfrm><a:off x=\"0\" y=\"0\"/>")
	fmt.sbprintf(b, "<a:ext cx=\"%d\" cy=\"%d\"/></a:xfrm>", cx, cy)
	strings.write_string(b, "<a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom></pic:spPr></pic:pic>")
	strings.write_string(b, "</a:graphicData></a:graphic></wp:inline></w:drawing></w:r>")
}

doc_to_docx_document :: proc(d: ^Doc, media: []Media = nil, alloc := context.allocator) -> string {
	b := strings.builder_make(alloc)
	strings.write_string(
		&b,
		`<?xml version="1.0" encoding="UTF-8" standalone="yes"?>` + "\n" +
		`<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" ` +
		`xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" ` +
		`xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" ` +
		`xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" ` +
		`xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"><w:body>`,
	)
	img_id := 1
	for &pa, pi in d.paras {
		if pa.kind == .Table && pa.table != nil {
			docx_table(&b, pa.table, media, &img_id)
			// A table may not be the last thing in a body: Word and
			// LibreOffice both want a paragraph after it, and without one the
			// file opens with the table merged into the section break.
			if pi == len(d.paras) - 1 {
				strings.write_string(&b, "<w:p/>")
			}
			continue
		}
		strings.write_string(&b, "<w:p>")
		docx_ppr(&b, &pa)
		if pa.kind == .Image {
			if m, got := media_of(d, media, pi); got {
				docx_drawing(&b, &pa, m, img_id)
				img_id += 1
			} else {
				// No bytes to embed: say what is missing, in text, rather than
				// writing an empty paragraph.
				strings.write_string(&b, "<w:r><w:t xml:space=\"preserve\">[")
				xml_escape(&b, pa.img == nil ? "picture" : (pa.img.alt != "" ? pa.img.alt : pa.img.path))
				strings.write_string(&b, "]</w:t></w:r>")
			}
		} else {
			docx_runs(&b, &pa)
		}
		strings.write_string(&b, "</w:p>")
	}
	// A4 with one-inch margins, so the page matches the app's own A4.
	strings.write_string(
		&b,
		"<w:sectPr><w:pgSz w:w=\"11906\" w:h=\"16838\"/>" +
		"<w:pgMar w:top=\"1440\" w:right=\"1440\" w:bottom=\"1440\" w:left=\"1440\" " +
		"w:header=\"708\" w:footer=\"708\" w:gutter=\"0\"/></w:sectPr>",
	)
	strings.write_string(&b, "</w:body></w:document>")
	return strings.to_string(b)
}

@(private = "file")
docx_styles :: proc(alloc := context.allocator) -> string {
	b := strings.builder_make(alloc)
	strings.write_string(
		&b,
		`<?xml version="1.0" encoding="UTF-8" standalone="yes"?>` + "\n" +
		`<w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">`,
	)
	// The document defaults carry the body face and size, so every style
	// that does not override them inherits from one place.
	fmt.sbprintf(
		&b,
		"<w:docDefaults><w:rPrDefault><w:rPr>" +
		"<w:rFonts w:ascii=\"Geist\" w:hAnsi=\"Geist\" w:cs=\"Geist\"/>" +
		"<w:sz w:val=\"%d\"/><w:szCs w:val=\"%d\"/></w:rPr></w:rPrDefault>" +
		"<w:pPrDefault><w:pPr><w:spacing w:after=\"%d\" w:line=\"%d\" w:lineRule=\"auto\"/>" +
		"</w:pPr></w:pPrDefault></w:docDefaults>",
		half_pt(15),
		half_pt(15),
		tw(11),
		374,
	)

	style :: proc(
		b: ^strings.Builder,
		id, name: string,
		size_px: f32,
		bold: bool,
		before, after, line: f32,
		extra := "",
		next := "BodyText",
		outline := -1,
	) {
		fmt.sbprintf(
			b,
			"<w:style w:type=\"paragraph\" w:styleId=\"%s\"><w:name w:val=\"%s\"/>" +
			"<w:basedOn w:val=\"Normal\"/><w:next w:val=\"%s\"/><w:qFormat/><w:pPr>",
			id,
			name,
			next,
		)
		fmt.sbprintf(
			b,
			"<w:spacing w:before=\"%d\" w:after=\"%d\" w:line=\"%d\" w:lineRule=\"auto\"/>",
			tw(before),
			tw(after),
			int(line * 240),
		)
		if outline >= 0 {
			fmt.sbprintf(b, "<w:outlineLvl w:val=\"%d\"/>", outline)
		}
		strings.write_string(b, extra)
		strings.write_string(b, "</w:pPr><w:rPr>")
		if bold {
			strings.write_string(b, "<w:b/><w:bCs/>")
		}
		fmt.sbprintf(b, "<w:sz w:val=\"%d\"/><w:szCs w:val=\"%d\"/>", half_pt(size_px), half_pt(size_px))
		strings.write_string(b, "</w:rPr></w:style>")
	}

	// Normal is the root every other style is based on.
	fmt.sbprintf(
		&b,
		"<w:style w:type=\"paragraph\" w:default=\"1\" w:styleId=\"Normal\">" +
		"<w:name w:val=\"Normal\"/><w:qFormat/></w:style>",
	)
	style(&b, "BodyText", "Body Text", 15, false, 0, 11, 1.56)
	style(&b, "Heading1", "heading 1", 30, true, 24, 10, 1.22, "", "BodyText", 0)
	style(&b, "Heading2", "heading 2", 23, true, 20, 8, 1.28, "", "BodyText", 1)
	style(&b, "Heading3", "heading 3", 18, true, 16, 6, 1.36, "", "BodyText", 2)
	style(
		&b,
		"Quote",
		"Quote",
		15,
		false,
		12,
		12,
		1.6,
		"<w:ind w:left=\"" +
		"480" +
		"\"/><w:pBdr><w:left w:val=\"single\" w:sz=\"18\" w:space=\"8\" w:color=\"D4D4D4\"/></w:pBdr>",
	)
	// Word's own name for a preformatted paragraph is "HTML Preformatted";
	// using it means LibreOffice and Word both recognise the style rather
	// than treating it as a stranger.
	fmt.sbprintf(
		&b,
		"<w:style w:type=\"paragraph\" w:styleId=\"Code\"><w:name w:val=\"HTML Preformatted\"/>" +
		"<w:basedOn w:val=\"Normal\"/><w:next w:val=\"Code\"/><w:qFormat/><w:pPr>" +
		"<w:spacing w:before=\"%d\" w:after=\"%d\" w:line=\"%d\" w:lineRule=\"auto\"/>" +
		"<w:ind w:left=\"%d\"/><w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"F4F4F5\"/></w:pPr>" +
		"<w:rPr><w:rFonts w:ascii=\"Courier New\" w:hAnsi=\"Courier New\" w:cs=\"Courier New\"/>" +
		"<w:sz w:val=\"%d\"/><w:szCs w:val=\"%d\"/></w:rPr></w:style>",
		tw(12),
		tw(12),
		389,
		tw(14),
		half_pt(13),
		half_pt(13),
	)
	fmt.sbprintf(
		&b,
		"<w:style w:type=\"paragraph\" w:styleId=\"ListParagraph\"><w:name w:val=\"List Paragraph\"/>" +
		"<w:basedOn w:val=\"Normal\"/><w:qFormat/><w:pPr>" +
		"<w:spacing w:after=\"%d\" w:line=\"%d\" w:lineRule=\"auto\"/>" +
		"<w:contextualSpacing/></w:pPr></w:style>",
		tw(4),
		374,
	)
	// A real table style, so an exported table is restyleable in Word rather
	// than a grid of direct formatting.
	fmt.sbprintf(
		&b,
		"<w:style w:type=\"table\" w:styleId=\"TableGrid\"><w:name w:val=\"Table Grid\"/>" +
		"<w:basedOn w:val=\"TableNormal\"/><w:qFormat/><w:tblPr>" +
		"<w:tblBorders>" +
		"<w:top w:val=\"single\" w:sz=\"6\" w:space=\"0\" w:color=\"A8A8AA\"/>" +
		"<w:left w:val=\"single\" w:sz=\"6\" w:space=\"0\" w:color=\"A8A8AA\"/>" +
		"<w:bottom w:val=\"single\" w:sz=\"6\" w:space=\"0\" w:color=\"A8A8AA\"/>" +
		"<w:right w:val=\"single\" w:sz=\"6\" w:space=\"0\" w:color=\"A8A8AA\"/>" +
		"<w:insideH w:val=\"single\" w:sz=\"6\" w:space=\"0\" w:color=\"A8A8AA\"/>" +
		"<w:insideV w:val=\"single\" w:sz=\"6\" w:space=\"0\" w:color=\"A8A8AA\"/>" +
		"</w:tblBorders></w:tblPr></w:style>" +
		"<w:style w:type=\"table\" w:default=\"1\" w:styleId=\"TableNormal\">" +
		"<w:name w:val=\"Normal Table\"/></w:style>",
	)
	strings.write_string(&b, "</w:styles>")
	return strings.to_string(b)
}

// docx_numbering defines two lists — bullets as numId 1, decimals as numId 2
// — each with nine levels, so `depth` maps straight onto `w:ilvl`.
@(private = "file")
docx_numbering :: proc(alloc := context.allocator) -> string {
	b := strings.builder_make(alloc)
	strings.write_string(
		&b,
		`<?xml version="1.0" encoding="UTF-8" standalone="yes"?>` + "\n" +
		`<w:numbering xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">`,
	)
	BULLETS := [?]string{"\u2022", "\u25E6", "\u25AA"}
	for abs in 0 ..< 2 {
		fmt.sbprintf(&b, "<w:abstractNum w:abstractNumId=\"%d\"><w:multiLevelType w:val=\"hybridMultilevel\"/>", abs)
		for lvl in 0 ..< 9 {
			left := tw(LIST_INDENT + f32(lvl + 1) * DEPTH_INDENT + 24)
			fmt.sbprintf(&b, "<w:lvl w:ilvl=\"%d\"><w:start w:val=\"1\"/>", lvl)
			if abs == 0 {
				fmt.sbprintf(
					&b,
					"<w:numFmt w:val=\"bullet\"/><w:lvlText w:val=\"%s\"/>",
					BULLETS[lvl % 3],
				)
			} else {
				fmt.sbprintf(
					&b,
					"<w:numFmt w:val=\"decimal\"/><w:lvlText w:val=\"%%%d.\"/>",
					lvl + 1,
				)
			}
			fmt.sbprintf(
				&b,
				"<w:lvlJc w:val=\"left\"/><w:pPr><w:ind w:left=\"%d\" w:hanging=\"%d\"/></w:pPr></w:lvl>",
				left,
				tw(24),
			)
		}
		strings.write_string(&b, "</w:abstractNum>")
	}
	strings.write_string(
		&b,
		"<w:num w:numId=\"1\"><w:abstractNumId w:val=\"0\"/></w:num>" +
		"<w:num w:numId=\"2\"><w:abstractNumId w:val=\"1\"/></w:num></w:numbering>",
	)
	return strings.to_string(b)
}

export_docx :: proc(d: ^Doc, path, title: string) -> bool {
	z: Zip
	zip_init(&z)
	defer zip_destroy(&z)

	media := collect_media(d, "word/media/", context.temp_allocator)

	// [Content_Types].xml has to declare a default for every extension in the
	// package, so a picture needs its own entry or the reader rejects the part.
	ct := strings.builder_make(context.temp_allocator)
	strings.write_string(
		&ct,
		`<?xml version="1.0" encoding="UTF-8" standalone="yes"?>` + "\n" +
		`<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">` +
		`<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>` +
		`<Default Extension="xml" ContentType="application/xml"/>`,
	)
	for ext in ([?][2]string{{"png", "image/png"}, {"jpeg", "image/jpeg"}, {"jpg", "image/jpeg"}}) {
		used := false
		for m in media {
			if m.ext == ext[0] {
				used = true
			}
		}
		if used {
			fmt.sbprintf(&ct, `<Default Extension="%s" ContentType="%s"/>`, ext[0], ext[1])
		}
	}
	strings.write_string(
		&ct,
		`<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>` +
		`<Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>` +
		`<Override PartName="/word/numbering.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml"/>` +
		`<Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>` +
		`<Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/>` +
		`</Types>`,
	)
	zip_add_string(&z, "[Content_Types].xml", strings.to_string(ct))

	zip_add_string(
		&z,
		"_rels/.rels",
		`<?xml version="1.0" encoding="UTF-8" standalone="yes"?>` + "\n" +
		`<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">` +
		`<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>` +
		`<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>` +
		`<Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties" Target="docProps/app.xml"/>` +
		`</Relationships>`,
	)

	rels := strings.builder_make(context.temp_allocator)
	strings.write_string(
		&rels,
		`<?xml version="1.0" encoding="UTF-8" standalone="yes"?>` + "\n" +
		`<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">` +
		`<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>` +
		`<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/numbering" Target="numbering.xml"/>`,
	)
	for m in media {
		fmt.sbprintf(
			&rels,
			`<Relationship Id="%s" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="media/%s"/>`,
			m.rid,
			base_name(m.part),
		)
	}
	strings.write_string(&rels, `</Relationships>`)
	zip_add_string(&z, "word/_rels/document.xml.rels", strings.to_string(rels))

	core := strings.builder_make(context.temp_allocator)
	strings.write_string(
		&core,
		`<?xml version="1.0" encoding="UTF-8" standalone="yes"?>` + "\n" +
		`<cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" ` +
		`xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" ` +
		`xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"><dc:title>`,
	)
	xml_escape(&core, title)
	strings.write_string(&core, "</dc:title><dc:creator>")
	xml_escape(&core, pdf_author())
	strings.write_string(&core, "</dc:creator><cp:lastModifiedBy>")
	xml_escape(&core, pdf_author())
	strings.write_string(&core, "</cp:lastModifiedBy></cp:coreProperties>")
	zip_add_string(&z, "docProps/core.xml", strings.to_string(core))

	words, chars := doc_counts(d)
	zip_add_string(
		&z,
		"docProps/app.xml",
		fmt.tprintf(
			`<?xml version="1.0" encoding="UTF-8" standalone="yes"?>` + "\n" +
			`<Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties">` +
			`<Application>palmy docs</Application><Paragraphs>%d</Paragraphs>` +
			`<Words>%d</Words><Characters>%d</Characters></Properties>`,
			len(d.paras),
			words,
			chars,
		),
	)

	zip_add_string(&z, "word/document.xml", doc_to_docx_document(d, media, context.temp_allocator))
	zip_add_string(&z, "word/styles.xml", docx_styles(context.temp_allocator))
	zip_add_string(&z, "word/numbering.xml", docx_numbering(context.temp_allocator))
	for m in media {
		zip_add(&z, m.part, m.bytes)
	}
	return os.write_entire_file(path, zip_finish(&z)) == nil
}

// ---------------------------------------------------------------------------
// .odt
// ---------------------------------------------------------------------------

@(private = "file")
odt_para_style :: proc(k: Para_Kind) -> string {
	switch k {
	case .H1:
		return "Heading_20_1"
	case .H2:
		return "Heading_20_2"
	case .H3:
		return "Heading_20_3"
	case .Quote:
		return "Quote"
	case .Code:
		return "Preformatted_20_Text"
	case .Body, .Table, .Image:
		return "Standard"
	}
	return "Standard"
}

// odt_write_text writes ODF character data. ODF collapses whitespace, so a
// run of spaces has to be spelled out with `<text:s>` or a code block loses
// its indentation entirely.
//
// `at_start` says whether the pen is still at the beginning of the paragraph.
// It matters: ODF discards a *leading* literal space outright, so the usual
// "first space literal, the rest explicit" trick silently eats one space off
// the front of every indented code line.
@(private = "file")
odt_write_text :: proc(b: ^strings.Builder, s: string, at_start: ^bool) {
	i := 0
	for i < len(s) {
		if s[i] == ' ' {
			n := 0
			for i + n < len(s) && s[i + n] == ' ' {
				n += 1
			}
			if at_start^ {
				fmt.sbprintf(b, "<text:s text:c=\"%d\"/>", n)
			} else {
				// Mid-paragraph the first space survives as itself.
				strings.write_byte(b, ' ')
				if n > 1 {
					fmt.sbprintf(b, "<text:s text:c=\"%d\"/>", n - 1)
				}
			}
			i += n
			continue
		}
		at_start^ = false
		switch s[i] {
		case '&':
			strings.write_string(b, "&amp;")
		case '<':
			strings.write_string(b, "&lt;")
		case '>':
			strings.write_string(b, "&gt;")
		case 0 ..< 0x20:
			strings.write_byte(b, ' ')
		case:
			strings.write_byte(b, s[i])
		}
		i += 1
	}
}

// Odt_Styles collects the automatic styles the body refers to. ODF keeps them
// in a block that comes *before* the body, so the body is built into its own
// buffer and the two are stitched together at the end.
@(private = "file")
Odt_Styles :: struct {
	text:  [dynamic]string, // property XML, index + 1 is the T-number
	para:  [dynamic]string,
}

@(private = "file")
odt_text_style :: proc(st: ^Odt_Styles, cs: Char_Style) -> string {
	if cs == (Char_Style{}) {
		return ""
	}
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "<style:text-properties")
	if cs.bold {strings.write_string(&b, " fo:font-weight=\"bold\" style:font-weight-asian=\"bold\"")}
	if cs.italic {strings.write_string(&b, " fo:font-style=\"italic\"")}
	if cs.underline {
		strings.write_string(
			&b,
			" style:text-underline-style=\"solid\" style:text-underline-width=\"auto\" style:text-underline-color=\"font-color\"",
		)
	}
	if cs.mono {
		strings.write_string(&b, " style:font-name=\"Monospace\"")
	}
	if cs.size != 0 {
		fmt.sbprintf(&b, " fo:font-size=\"%.1fpt\"", cs.size * 0.75)
	}
	if cs.color != 0 {
		fmt.sbprintf(&b, " fo:color=\"#%06x\"", cs.color & 0xffffff)
	}
	strings.write_string(&b, "/>")
	props := strings.to_string(b)
	for p, i in st.text {
		if p == props {
			return fmt.tprintf("T%d", i + 1)
		}
	}
	append(&st.text, strings.clone(props, context.temp_allocator))
	return fmt.tprintf("T%d", len(st.text))
}

@(private = "file")
odt_para_auto :: proc(st: ^Odt_Styles, pa: ^Paragraph) -> string {
	needs := pa.align != .Left || pa.break_before || pa.before != 0 || pa.after != 0 || (pa.depth > 0 && pa.list == .None)
	if !needs {
		return ""
	}
	km := kind_metrics(pa.kind)
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "parent=%s|", odt_para_style(pa.kind))
	strings.write_string(&b, "<style:paragraph-properties")
	switch pa.align {
	case .Center:
		strings.write_string(&b, " fo:text-align=\"center\"")
	case .Right:
		strings.write_string(&b, " fo:text-align=\"end\"")
	case .Justify:
		strings.write_string(&b, " fo:text-align=\"justify\"")
	case .Left:
	}
	if pa.break_before {
		strings.write_string(&b, " fo:break-before=\"page\"")
	}
	if pa.before != 0 {
		fmt.sbprintf(&b, " fo:margin-top=\"%.3fin\"", (km.before + pa.before) / 96)
	}
	if pa.after != 0 {
		fmt.sbprintf(&b, " fo:margin-bottom=\"%.3fin\"", (km.after + pa.after) / 96)
	}
	if pa.depth > 0 && pa.list == .None {
		fmt.sbprintf(&b, " fo:margin-left=\"%.3fin\"", f32(pa.depth) * DEPTH_INDENT / 96)
	}
	strings.write_string(&b, "/>")
	props := strings.to_string(b)
	for q, i in st.para {
		if q == props {
			return fmt.tprintf("P%d", i + 1)
		}
	}
	append(&st.para, strings.clone(props, context.temp_allocator))
	return fmt.tprintf("P%d", len(st.para))
}

doc_to_odt_content :: proc(d: ^Doc, media: []Media = nil, alloc := context.allocator) -> string {
	styles := Odt_Styles {
		text = make([dynamic]string, 0, 8, context.temp_allocator),
		para = make([dynamic]string, 0, 8, context.temp_allocator),
	}
	body := strings.builder_make(context.temp_allocator)

	// A stack of open <text:list> levels. The item at the top level is left
	// open after each entry, because a deeper list has to nest inside it —
	// see the long comment in the header.
	levels := 0
	list_kind := List_Kind.None

	close_lists :: proc(b: ^strings.Builder, levels: ^int, lk: ^List_Kind) {
		for levels^ > 0 {
			strings.write_string(b, "</text:list-item></text:list>")
			levels^ -= 1
		}
		lk^ = .None
	}

	emit_inline :: proc(b: ^strings.Builder, st: ^Odt_Styles, pa: ^Paragraph) {
		at_start := true
		for &r in pa.runs {
			text := string(r.text[:])
			if len(text) == 0 {
				continue
			}
			name := odt_text_style(st, r.style)
			if name == "" {
				odt_write_text(b, text, &at_start)
			} else {
				fmt.sbprintf(b, "<text:span text:style-name=\"%s\">", name)
				odt_write_text(b, text, &at_start)
				strings.write_string(b, "</text:span>")
			}
		}
	}

	// odt_table writes a <table:table>. ODF puts a repeating header inside
	// <table:table-header-rows>, which is both the structure and the
	// pagination instruction — the same rule the app's own layout uses.
	odt_table :: proc(b: ^strings.Builder, st: ^Odt_Styles, t: ^Table, n: int, media: []Media, img_seq: ^int) {
		ncols := table_cols(t)
		fmt.sbprintf(
			b,
			"<table:table table:name=\"Table%d\" table:style-name=\"Tbl%d\">",
			n,
			n,
		)
		for c in 0 ..< ncols {
			fmt.sbprintf(b, "<table:table-column table:style-name=\"Tbl%d.%d\"/>", n, c)
		}
		row :: proc(
			b: ^strings.Builder,
			st: ^Odt_Styles,
			t: ^Table,
			n, r, ncols: int,
			media: []Media,
			img_seq: ^int,
		) {
			head := t.header && r == 0
			strings.write_string(b, "<table:table-row>")
			for c in 0 ..< ncols {
				// ODF keeps the grid whole: the anchor says how far it spans
				// and every cell it hides is a <table:covered-table-cell/>.
				cl := table_cell(t, r, c)
				if cl != nil && cl.covered {
					strings.write_string(b, "<table:covered-table-cell/>")
					continue
				}
				fmt.sbprintf(
					b,
					"<table:table-cell table:style-name=\"Tbl%d.%s\" office:value-type=\"string\"",
					n,
					head ? "H" : "C",
				)
				if cl != nil && cell_cspan(cl) > 1 {
					fmt.sbprintf(b, " table:number-columns-spanned=\"%d\"", cell_cspan(cl))
				}
				if cl != nil && cell_rspan(cl) > 1 {
					fmt.sbprintf(b, " table:number-rows-spanned=\"%d\"", cell_rspan(cl))
				}
				strings.write_string(b, ">")
				if cl == nil || len(cl.paras) == 0 {
					strings.write_string(b, "<text:p/>")
				} else {
					for &cp in cl.paras {
						// A picture in a cell is the same <draw:frame> as one
						// in the body, sized against the column rather than
						// the page.
						if cp.kind == .Image {
							href := ""
							if m, got := media_for(media, cp.img); got {
								href = m.part
							}
							img_seq^ += 1
							odt_image(b, &cp, href, img_seq^, max(20, table_span_w(t, r, c) - 2 * CELL_PAD))
							continue
						}
						name := head ? "TblHead" : odt_para_style(cp.kind)
						fmt.sbprintf(b, "<text:p text:style-name=\"%s\">", name)
						emit_inline(b, st, &cp)
						strings.write_string(b, "</text:p>")
					}
				}
				strings.write_string(b, "</table:table-cell>")
			}
			strings.write_string(b, "</table:table-row>")
		}
		if t.header && len(t.rows) > 0 {
			// The header is row 0 and any rows a merge joins to it.
			he := table_head_end(t)
			strings.write_string(b, "<table:table-header-rows>")
			for r in 0 ..= he {
				row(b, st, t, n, r, ncols, media, img_seq)
			}
			strings.write_string(b, "</table:table-header-rows>")
			for r in he + 1 ..< len(t.rows) {
				row(b, st, t, n, r, ncols, media, img_seq)
			}
		} else {
			for r in 0 ..< len(t.rows) {
				row(b, st, t, n, r, ncols, media, img_seq)
			}
		}
		strings.write_string(b, "</table:table>")
	}

	// odt_image writes a <draw:frame> anchored as a character inside its own
	// paragraph, which is how ODF says "an inline picture".
	odt_image :: proc(b: ^strings.Builder, pa: ^Paragraph, href: string, n: int, measure := f32(CONTENT_W)) {
		w, h := image_para_size(pa, measure, CONTENT_H)
		align := "center"
		switch pa.align {
		case .Left:
			align = "start"
		case .Right:
			align = "end"
		case .Center, .Justify:
		}
		fmt.sbprintf(b, "<text:p text:style-name=\"Img%s\">", align)
		fmt.sbprintf(
			b,
			"<draw:frame draw:style-name=\"Frame1\" draw:name=\"Image%d\" text:anchor-type=\"as-char\" " +
			"svg:width=\"%.3fin\" svg:height=\"%.3fin\" draw:z-index=\"%d\">",
			n,
			w / 96,
			h / 96,
			n,
		)
		if href != "" {
			fmt.sbprintf(
				b,
				"<draw:image xlink:href=\"%s\" xlink:type=\"simple\" xlink:show=\"embed\" xlink:actuate=\"onLoad\"/>",
				href,
			)
		}
		if pa.img != nil && pa.img.alt != "" {
			strings.write_string(b, "<svg:title>")
			xml_escape(b, pa.img.alt)
			strings.write_string(b, "</svg:title>")
		}
		strings.write_string(b, "</draw:frame></text:p>")
	}

	tbl_n := 0
	img_n := 0
	for &pa, pi in d.paras {
		if pa.kind == .Table && pa.table != nil {
			close_lists(&body, &levels, &list_kind)
			tbl_n += 1
			odt_table(&body, &styles, pa.table, tbl_n, media, &img_n)
			continue
		}
		if pa.kind == .Image {
			close_lists(&body, &levels, &list_kind)
			img_n += 1
			href := ""
			if m, got := media_of(d, media, pi); got {
				href = m.part
			}
			odt_image(&body, &pa, href, img_n)
			continue
		}
		if pa.list == .None {
			close_lists(&body, &levels, &list_kind)
			auto := odt_para_auto(&styles, &pa)
			name := auto != "" ? auto : odt_para_style(pa.kind)
			switch pa.kind {
			case .H1, .H2, .H3:
				lvl := pa.kind == .H1 ? 1 : (pa.kind == .H2 ? 2 : 3)
				fmt.sbprintf(
					&body,
					"<text:h text:style-name=\"%s\" text:outline-level=\"%d\">",
					name,
					lvl,
				)
				emit_inline(&body, &styles, &pa)
				strings.write_string(&body, "</text:h>")
			case .Body, .Quote, .Code, .Table, .Image:
				fmt.sbprintf(&body, "<text:p text:style-name=\"%s\">", name)
				emit_inline(&body, &styles, &pa)
				strings.write_string(&body, "</text:p>")
			}
			continue
		}

		target := min(pa.depth, 8) + 1
		if list_kind != pa.list {
			close_lists(&body, &levels, &list_kind)
			list_kind = pa.list
		}
		style_name := pa.list == .Bullet ? "LBullet" : "LNumber"
		switch {
		case levels > target:
			for levels > target {
				strings.write_string(&body, "</text:list-item></text:list>")
				levels -= 1
			}
			strings.write_string(&body, "</text:list-item>")
		case levels == target:
			strings.write_string(&body, "</text:list-item>")
		case:
			for i := levels + 1; i <= target; i += 1 {
				if i > levels + 1 {
					strings.write_string(&body, "<text:list-item>")
				}
				fmt.sbprintf(&body, "<text:list text:style-name=\"%s\">", style_name)
			}
			levels = target
		}
		strings.write_string(&body, "<text:list-item><text:p text:style-name=\"Standard\">")
		emit_inline(&body, &styles, &pa)
		strings.write_string(&body, "</text:p>")
	}
	close_lists(&body, &levels, &list_kind)

	out := strings.builder_make(alloc)
	strings.write_string(
		&out,
		`<?xml version="1.0" encoding="UTF-8"?>` + "\n" + `<office:document-content ` +
		`xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" ` +
		`xmlns:style="urn:oasis:names:tc:opendocument:xmlns:style:1.0" ` +
		`xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0" ` +
		`xmlns:table="urn:oasis:names:tc:opendocument:xmlns:table:1.0" ` +
		`xmlns:draw="urn:oasis:names:tc:opendocument:xmlns:drawing:1.0" ` +
		`xmlns:svg="urn:oasis:names:tc:opendocument:xmlns:svg-compatible:1.0" ` +
		`xmlns:xlink="http://www.w3.org/1999/xlink" ` +
		`xmlns:fo="urn:oasis:names:tc:opendocument:xmlns:xsl-fo-compatible:1.0" ` +
		`office:version="1.3"><office:automatic-styles>`,
	)
	for props, i in styles.text {
		fmt.sbprintf(
			&out,
			"<style:style style:name=\"T%d\" style:family=\"text\">%s</style:style>",
			i + 1,
			props,
		)
	}
	for entry, i in styles.para {
		// The key is "parent=NAME|<xml>", so split it back apart.
		bar := strings.index_byte(entry, '|')
		parent := entry[len("parent="):bar]
		fmt.sbprintf(
			&out,
			"<style:style style:name=\"P%d\" style:family=\"paragraph\" style:parent-style-name=\"%s\">%s</style:style>",
			i + 1,
			parent,
			entry[bar + 1:],
		)
	}
	// The automatic styles for every table: one for the table's width, one per
	// column, and two cell styles — the header's and the body's.
	{
		n := 0
		for &pa in d.paras {
			if pa.kind != .Table || pa.table == nil {
				continue
			}
			n += 1
			t := pa.table
			fmt.sbprintf(
				&out,
				"<style:style style:name=\"Tbl%d\" style:family=\"table\">" +
				"<style:table-properties style:width=\"%.3fin\" table:align=\"margins\"/></style:style>",
				n,
				CONTENT_W / 96,
			)
			for c in 0 ..< table_cols(t) {
				fmt.sbprintf(
					&out,
					"<style:style style:name=\"Tbl%d.%d\" style:family=\"table-column\">" +
					"<style:table-column-properties style:column-width=\"%.3fin\"/></style:style>",
					n,
					c,
					table_width(t, c) / 96,
				)
			}
			border := t.borders ? "0.0007in solid #a8a8aa" : "none"
			for pair in ([?][2]string{{"H", "#f1f1f2"}, {"C", "transparent"}}) {
				fmt.sbprintf(
					&out,
					"<style:style style:name=\"Tbl%d.%s\" style:family=\"table-cell\">" +
					"<style:table-cell-properties fo:padding=\"%.3fin\" fo:border=\"%s\"",
					n,
					pair[0],
					CELL_PAD / 96,
					border,
				)
				if pair[0] == "H" {
					fmt.sbprintf(&out, " fo:background-color=\"%s\"", pair[1])
				}
				strings.write_string(&out, "/></style:style>")
			}
		}
	}
	// A frame style for pictures, and the three alignments an image paragraph
	// can take.
	strings.write_string(
		&out,
		"<style:style style:name=\"Frame1\" style:family=\"graphic\">" +
		"<style:graphic-properties style:vertical-pos=\"top\" style:vertical-rel=\"baseline\" " +
		"fo:border=\"none\" style:wrap=\"none\"/></style:style>",
	)
	for al in ([?][2]string{{"start", "start"}, {"center", "center"}, {"end", "end"}}) {
		fmt.sbprintf(
			&out,
			"<style:style style:name=\"Img%s\" style:family=\"paragraph\" style:parent-style-name=\"Standard\">" +
			"<style:paragraph-properties fo:text-align=\"%s\" fo:margin-top=\"0.125in\" fo:margin-bottom=\"0.125in\"/>" +
			"</style:style>",
			al[0],
			al[1],
		)
	}
	strings.write_string(&out, odt_list_styles())
	strings.write_string(&out, "</office:automatic-styles><office:body><office:text>")
	strings.write_string(&out, strings.to_string(body))
	strings.write_string(&out, "</office:text></office:body></office:document-content>")
	return strings.to_string(out)
}

@(private = "file")
odt_list_styles :: proc() -> string {
	b := strings.builder_make(context.temp_allocator)
	BULLETS := [?]string{"\u2022", "\u25E6", "\u25AA"}
	for pass in 0 ..< 2 {
		fmt.sbprintf(
			&b,
			"<text:list-style style:name=\"%s\">",
			pass == 0 ? "LBullet" : "LNumber",
		)
		for lvl in 1 ..= 9 {
			indent := (LIST_INDENT + f32(lvl) * DEPTH_INDENT) / 96
			if pass == 0 {
				fmt.sbprintf(
					&b,
					"<text:list-level-style-bullet text:level=\"%d\" text:style-name=\"Bullet_20_Symbols\" text:bullet-char=\"%s\">",
					lvl,
					BULLETS[(lvl - 1) % 3],
				)
			} else {
				fmt.sbprintf(
					&b,
					"<text:list-level-style-number text:level=\"%d\" style:num-suffix=\".\" style:num-format=\"1\">",
					lvl,
				)
			}
			fmt.sbprintf(
				&b,
				"<style:list-level-properties text:list-level-position-and-space-mode=\"label-alignment\">" +
				"<style:list-level-label-alignment text:label-followed-by=\"listtab\" fo:text-indent=\"-0.25in\" fo:margin-left=\"%.3fin\"/>" +
				"</style:list-level-properties>",
				indent,
			)
			strings.write_string(
				&b,
				pass == 0 ? "</text:list-level-style-bullet>" : "</text:list-level-style-number>",
			)
		}
		strings.write_string(&b, "</text:list-style>")
	}
	return strings.to_string(b)
}

@(private = "file")
odt_styles_xml :: proc(alloc := context.allocator) -> string {
	b := strings.builder_make(alloc)
	strings.write_string(
		&b,
		`<?xml version="1.0" encoding="UTF-8"?>` + "\n" + `<office:document-styles ` +
		`xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" ` +
		`xmlns:style="urn:oasis:names:tc:opendocument:xmlns:style:1.0" ` +
		`xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0" ` +
		`xmlns:fo="urn:oasis:names:tc:opendocument:xmlns:xsl-fo-compatible:1.0" ` +
		`xmlns:svg="urn:oasis:names:tc:opendocument:xmlns:svg-compatible:1.0" ` +
		`office:version="1.3"><office:font-face-decls>` +
		`<style:font-face style:name="Geist" svg:font-family="Geist, Inter, sans-serif" style:font-family-generic="swiss"/>` +
		`<style:font-face style:name="Monospace" svg:font-family="&apos;DejaVu Sans Mono&apos;, monospace" style:font-family-generic="modern" style:font-pitch="fixed"/>` +
		`</office:font-face-decls><office:styles>`,
	)

	pstyle :: proc(
		b: ^strings.Builder,
		name, display, parent: string,
		size_px: f32,
		bold: bool,
		before, after, line: f32,
		extra_p := "",
		extra_t := "",
		outline := 0,
	) {
		fmt.sbprintf(
			b,
			"<style:style style:name=\"%s\" style:display-name=\"%s\" style:family=\"paragraph\"",
			name,
			display,
		)
		if parent != "" {
			fmt.sbprintf(b, " style:parent-style-name=\"%s\"", parent)
		}
		if outline > 0 {
			fmt.sbprintf(b, " style:default-outline-level=\"%d\"", outline)
		}
		fmt.sbprintf(
			b,
			"><style:paragraph-properties fo:margin-top=\"%.3fin\" fo:margin-bottom=\"%.3fin\" fo:line-height=\"%.0f%%\"%s/>",
			before / 96,
			after / 96,
			line * 100,
			extra_p,
		)
		fmt.sbprintf(b, "<style:text-properties fo:font-size=\"%.1fpt\"", size_px * 0.75)
		if bold {
			strings.write_string(b, " fo:font-weight=\"bold\"")
		}
		strings.write_string(b, extra_t)
		strings.write_string(b, "/></style:style>")
	}

	// Standard is ODF's root paragraph style; everything else parents to it.
	fmt.sbprintf(
		&b,
		"<style:style style:name=\"Standard\" style:family=\"paragraph\" style:class=\"text\">" +
		"<style:paragraph-properties fo:margin-bottom=\"%.3fin\" fo:line-height=\"156%%\"/>" +
		"<style:text-properties style:font-name=\"Geist\" fo:font-size=\"%.1fpt\"/></style:style>",
		f32(11) / 96,
		f32(15) * 0.75,
	)
	// The header-cell paragraph style, so an exported header row is bold by
	// style rather than by direct formatting on every run.
	fmt.sbprintf(
		&b,
		"<style:style style:name=\"TblHead\" style:display-name=\"Table Heading\" style:family=\"paragraph\" " +
		"style:parent-style-name=\"Standard\"><style:paragraph-properties fo:margin-bottom=\"0in\"/>" +
		"<style:text-properties fo:font-weight=\"bold\" fo:font-size=\"%.1fpt\"/></style:style>",
		f32(15) * 0.75,
	)
	fmt.sbprintf(
		&b,
		"<style:style style:name=\"TblBody\" style:display-name=\"Table Contents\" style:family=\"paragraph\" " +
		"style:parent-style-name=\"Standard\"><style:paragraph-properties fo:margin-bottom=\"0in\"/>" +
		"<style:text-properties fo:font-size=\"%.1fpt\"/></style:style>",
		f32(15) * 0.75,
	)
	pstyle(&b, "Heading", "Heading", "Standard", 18, true, 16, 6, 1.36)
	pstyle(&b, "Heading_20_1", "Heading 1", "Heading", 30, true, 24, 10, 1.22, "", "", 1)
	pstyle(&b, "Heading_20_2", "Heading 2", "Heading", 23, true, 20, 8, 1.28, "", "", 2)
	pstyle(&b, "Heading_20_3", "Heading 3", "Heading", 18, true, 16, 6, 1.36, "", "", 3)
	pstyle(
		&b,
		"Quote",
		"Quote",
		"Standard",
		15,
		false,
		12,
		12,
		1.6,
		" fo:margin-left=\"0.25in\" fo:border-left=\"0.02in solid #d4d4d4\" fo:padding-left=\"0.08in\"",
		" fo:font-style=\"italic\"",
	)
	pstyle(
		&b,
		"Preformatted_20_Text",
		"Preformatted Text",
		"Standard",
		13,
		false,
		12,
		12,
		1.62,
		" fo:margin-left=\"0.15in\" fo:background-color=\"#f4f4f5\"",
		" style:font-name=\"Monospace\"",
	)
	strings.write_string(
		&b,
		"</office:styles><office:automatic-styles>" +
		"<style:page-layout style:name=\"A4\"><style:page-layout-properties " +
		"fo:page-width=\"8.268in\" fo:page-height=\"11.693in\" style:print-orientation=\"portrait\" " +
		"fo:margin-top=\"1in\" fo:margin-bottom=\"1in\" fo:margin-left=\"1in\" fo:margin-right=\"1in\"/>" +
		"</style:page-layout></office:automatic-styles>" +
		"<office:master-styles><style:master-page style:name=\"Standard\" style:page-layout-name=\"A4\"/>" +
		"</office:master-styles></office:document-styles>",
	)
	return strings.to_string(b)
}

ODT_MIME :: "application/vnd.oasis.opendocument.text"

export_odt :: proc(d: ^Doc, path, title: string) -> bool {
	z: Zip
	zip_init(&z)
	defer zip_destroy(&z)

	media := collect_media(d, "Pictures/", context.temp_allocator)

	// First entry, stored, no extra field — the one hard requirement ODF
	// makes of the container, so that `file(1)` can identify the type from
	// the first thirty-odd bytes of the archive.
	zip_add_string(&z, "mimetype", ODT_MIME)

	man := strings.builder_make(context.temp_allocator)
	strings.write_string(
		&man,
		`<?xml version="1.0" encoding="UTF-8"?>` + "\n" +
		`<manifest:manifest xmlns:manifest="urn:oasis:names:tc:opendocument:xmlns:manifest:1.0" manifest:version="1.3">` +
		`<manifest:file-entry manifest:full-path="/" manifest:version="1.3" manifest:media-type="` +
		ODT_MIME +
		`"/>` +
		`<manifest:file-entry manifest:full-path="content.xml" manifest:media-type="text/xml"/>` +
		`<manifest:file-entry manifest:full-path="styles.xml" manifest:media-type="text/xml"/>` +
		`<manifest:file-entry manifest:full-path="meta.xml" manifest:media-type="text/xml"/>`,
	)
	for m in media {
		fmt.sbprintf(
			&man,
			`<manifest:file-entry manifest:full-path="%s" manifest:media-type="%s"/>`,
			m.part,
			m.mime,
		)
	}
	strings.write_string(&man, `</manifest:manifest>`)
	zip_add_string(&z, "META-INF/manifest.xml", strings.to_string(man))

	meta := strings.builder_make(context.temp_allocator)
	strings.write_string(
		&meta,
		`<?xml version="1.0" encoding="UTF-8"?>` + "\n" + `<office:document-meta ` +
		`xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" ` +
		`xmlns:dc="http://purl.org/dc/elements/1.1/" ` +
		`xmlns:meta="urn:oasis:names:tc:opendocument:xmlns:meta:1.0" ` +
		`office:version="1.3"><office:meta><dc:title>`,
	)
	xml_escape(&meta, title)
	strings.write_string(&meta, "</dc:title><meta:initial-creator>")
	xml_escape(&meta, pdf_author())
	strings.write_string(&meta, "</meta:initial-creator><dc:language>en-US</dc:language>")
	strings.write_string(&meta, "<meta:generator>palmy docs</meta:generator></office:meta></office:document-meta>")

	zip_add_string(&z, "content.xml", doc_to_odt_content(d, media, context.temp_allocator))
	zip_add_string(&z, "styles.xml", odt_styles_xml(context.temp_allocator))
	zip_add_string(&z, "meta.xml", strings.to_string(meta))
	for m in media {
		zip_add(&z, m.part, m.bytes)
	}
	return os.write_entire_file(path, zip_finish(&z)) == nil
}

// ---------------------------------------------------------------------------
// .rtf
// ---------------------------------------------------------------------------

// rtf_text escapes RTF's three control characters and spells out everything
// outside ASCII as `\uN?`, which is the only encoding every RTF reader since
// 1.5 agrees on. Astral characters become a UTF-16 surrogate pair, because
// the `\u` argument is a signed 16-bit integer.
@(private = "file")
rtf_text :: proc(b: ^strings.Builder, s: string) {
	i := 0
	for i < len(s) {
		c := s[i]
		switch {
		case c == '\\' || c == '{' || c == '}':
			strings.write_byte(b, '\\')
			strings.write_byte(b, c)
			i += 1
		case c < 0x80:
			strings.write_byte(b, c < 0x20 ? ' ' : c)
			i += 1
		case:
			r, n := utf8.decode_rune_in_string(s[i:])
			cp := u32(r)
			if cp > 0xffff {
				v := cp - 0x10000
				fmt.sbprintf(b, "\\u%d?", i32(i16(u16(0xd800 + (v >> 10)))))
				fmt.sbprintf(b, "\\u%d?", i32(i16(u16(0xdc00 + (v & 0x3ff)))))
			} else {
				fmt.sbprintf(b, "\\u%d?", i32(i16(u16(cp))))
			}
			i += max(1, n)
		}
	}
}

doc_to_rtf :: proc(d: ^Doc, title: string, alloc := context.allocator) -> string {
	b := strings.builder_make(alloc)
	strings.write_string(
		&b,
		"{\\rtf1\\ansi\\ansicpg1252\\uc1\\deff0\\deflang1033\n" +
		"{\\fonttbl{\\f0\\fswiss\\fcharset0 Geist;}{\\f1\\fmodern\\fcharset0 Courier New;}}\n",
	)

	// A colour table: index 0 is "auto", 1 is the ink, and the rest are
	// whatever colours the document actually uses.
	cols := make([dynamic]u32, 0, 8, context.temp_allocator)
	for blk in doc_blocks(d, context.temp_allocator) {
		pa := blk_para(d, blk)
		if pa == nil {
			continue
		}
		for &r in pa.runs {
			if r.style.color == 0 {
				continue
			}
			c := r.style.color & 0xffffff
			seen := false
			for q in cols {
				if q == c {
					seen = true
					break
				}
			}
			if !seen {
				append(&cols, c)
			}
		}
	}
	// Index 1 is the ink and index 2 is the header-row shading, so a table's
	// `\clcbpat2` resolves without a per-document lookup.
	strings.write_string(&b, "{\\colortbl;\\red18\\green18\\blue18;\\red241\\green241\\blue242;")
	for c in cols {
		fmt.sbprintf(&b, "\\red%d\\green%d\\blue%d;", (c >> 16) & 0xff, (c >> 8) & 0xff, c & 0xff)
	}
	strings.write_string(&b, "}\n")

	// A stylesheet, so the headings arrive as headings rather than as large
	// bold body text.
	//
	// Note the deliberate avoidance of `fmt.sbprintf` for anything containing
	// a brace: Odin's formatter reads `{` as the start of a format argument,
	// so an RTF group written through it comes out as
	// "%!(MISSING CLOSE BRACE)" and the file is unreadable. Braces are
	// written literally and only the numbers are formatted.
	strings.write_string(&b, "{\\stylesheet\n{\\s0\\snext0 Normal;}\n")
	head_style :: proc(b: ^strings.Builder, n: int, before, after, size: f32) {
		strings.write_byte(b, '{')
		fmt.sbprintf(
			b,
			"\\s%d\\sb%d\\sa%d\\b\\fs%d\\snext0 heading %d;",
			n,
			tw(before),
			tw(after),
			half_pt(size),
			n,
		)
		strings.write_string(b, "}\n")
	}
	head_style(&b, 1, 24, 10, 30)
	head_style(&b, 2, 20, 8, 23)
	head_style(&b, 3, 16, 6, 18)
	strings.write_byte(&b, '{')
	fmt.sbprintf(&b, "\\s4\\sb%d\\sa%d\\li%d\\i\\snext4 Quote;", tw(12), tw(12), tw(24))
	strings.write_string(&b, "}\n")
	strings.write_byte(&b, '{')
	fmt.sbprintf(
		&b,
		"\\s5\\sb%d\\sa%d\\li%d\\f1\\fs%d\\snext5 Preformatted Text;",
		tw(12),
		tw(12),
		tw(14),
		half_pt(13),
	)
	strings.write_string(&b, "}\n}\n")

	strings.write_string(
		&b,
		"\\paperw11906\\paperh16838\\margl1440\\margr1440\\margt1440\\margb1440\n{\\info{\\title ",
	)
	rtf_text(&b, title)
	strings.write_string(&b, "}}\n")

	for &pa, pi in d.paras {
		// A table is the one construct RTF expresses as a *sequence of
		// paragraphs* rather than as a container: every cell is a paragraph
		// marked `\intbl`, the row's geometry is declared once in `\trowd`
		// before the cells, and `\row` closes it. It is the oldest and
		// ugliest of the three table syntaxes and it works everywhere.
		if pa.kind == .Table && pa.table != nil {
			rtf_table(&b, pa.table, cols[:])
			continue
		}
		if pa.kind == .Image {
			rtf_image(&b, &pa)
			continue
		}
		km := kind_metrics(pa.kind)
		strings.write_string(&b, "\\pard\\plain")
		switch pa.kind {
		case .H1:
			strings.write_string(&b, "\\s1")
		case .H2:
			strings.write_string(&b, "\\s2")
		case .H3:
			strings.write_string(&b, "\\s3")
		case .Quote:
			strings.write_string(&b, "\\s4")
		case .Code:
			strings.write_string(&b, "\\s5")
		case .Body, .Table, .Image:
			strings.write_string(&b, "\\s0")
		}
		if pa.break_before && pi > 0 {
			strings.write_string(&b, "\\page")
		}
		fmt.sbprintf(&b, "\\sb%d\\sa%d", tw(km.before + pa.before), tw(km.after + pa.after))
		switch pa.align {
		case .Center:
			strings.write_string(&b, "\\qc")
		case .Right:
			strings.write_string(&b, "\\qr")
		case .Justify:
			strings.write_string(&b, "\\qj")
		case .Left:
			strings.write_string(&b, "\\ql")
		}
		indent := km.indent + f32(pa.depth) * DEPTH_INDENT
		if pa.list != .None {
			// The RTF 1.5 way of writing a list item: the literal marker in a
			// `\pntext` group for readers that do not understand `\pn`, and
			// the `\pn` description for those that do.
			indent += LIST_INDENT
			if pa.list == .Bullet {
				strings.write_string(
					&b,
					"{\\pntext\\f0\\'b7\\tab}{\\*\\pn\\pnlvlblt\\pnf0\\pnindent0{\\pntxtb\\'b7}}",
				)
			} else {
				strings.write_string(
					&b,
					"{\\pntext\\f0 1.\\tab}{\\*\\pn\\pnlvlbody\\pnf0\\pnindent0\\pnstart1\\pndec{\\pntxta.}}",
				)
			}
			fmt.sbprintf(&b, "\\fi-%d", tw(24))
		}
		if indent > 0 {
			fmt.sbprintf(&b, "\\li%d", tw(indent))
		}
		if pa.kind != .Code {
			fmt.sbprintf(&b, "\\f0\\fs%d", half_pt(km.size))
		}
		strings.write_byte(&b, ' ')

		rtf_runs(&b, &pa, cols[:], false, pa.kind == .Code)
		strings.write_string(&b, "\\par\n")
	}
	strings.write_string(&b, "}\n")
	return strings.to_string(b)
}

// rtf_runs writes one paragraph's runs. Control words go into their own buffer
// first for the reason given in `doc_to_rtf`: a control word swallows the space
// that terminates it, and a group with none would keep that space as text.
@(private = "file")
rtf_runs :: proc(b: ^strings.Builder, pa: ^Paragraph, cols: []u32, force_bold := false, mono := false) {
	// Index 0 is "auto", 1 the ink and 2 the header shading, so the document's
	// own colours start at 3.
	color_index :: proc(cols: []u32, c: u32) -> int {
		for q, i in cols {
			if q == c & 0xffffff {
				return i + 3
			}
		}
		return 1
	}
	for &r in pa.runs {
		text := string(r.text[:])
		if len(text) == 0 {
			continue
		}
		cs := r.style
		cw := strings.builder_make(context.temp_allocator)
		if cs.mono || mono {strings.write_string(&cw, "\\f1")}
		if cs.bold || force_bold {strings.write_string(&cw, "\\b")}
		if cs.italic {strings.write_string(&cw, "\\i")}
		if cs.underline {strings.write_string(&cw, "\\ul")}
		if cs.size != 0 {fmt.sbprintf(&cw, "\\fs%d", half_pt(cs.size))}
		if cs.color != 0 {fmt.sbprintf(&cw, "\\cf%d", color_index(cols, cs.color))}
		strings.write_byte(b, '{')
		if strings.builder_len(cw) > 0 {
			strings.write_string(b, strings.to_string(cw))
			strings.write_byte(b, ' ')
		}
		rtf_text(b, text)
		strings.write_byte(b, '}')
	}
}

// rtf_table writes one table as a run of `\trowd` rows.
//
// The two things that make or break it:
//
//   * `\cellx` is the *cumulative* right edge of each column in twips, not the
//     column's width. Writing widths instead gives a table whose columns all
//     collapse into the first one.
//   * the row definition has to be repeated before every row. A reader that
//     meets `\intbl` without a preceding `\trowd` either drops the row or
//     merges it into the one before.
@(private = "file")
rtf_table :: proc(b: ^strings.Builder, t: ^Table, cols: []u32) {
	ncols := table_cols(t)
	head_end := table_head_end(t)
	for r in 0 ..< len(t.rows) {
		head := t.header && r == 0
		strings.write_string(b, "\\trowd\\trgaph")
		fmt.sbprintf(b, "%d\\trleft0", tw(CELL_PAD) / 2)
		if r <= head_end {
			// `\trhdr` is RTF's repeating header row — the same pagination
			// promise the .docx `<w:tblHeader/>` makes.
			strings.write_string(b, "\\trhdr")
		}
		strings.write_string(b, "\\trkeep")
		edge := f32(0)
		for c in 0 ..< ncols {
			edge += table_width(t, c)
			// Merged cells keep one \cellx per grid column, flagged: `\clmgf`
			// starts a run merged across, `\clmrg` continues it; `\clvmgf`
			// and `\clvmrg` do the same downwards. A cell inside a merge
			// both ways carries one of each.
			ar, ac := table_anchor(t, r, c)
			if a := table_cell(t, ar, ac); cell_is_merged(a) {
				if cell_rspan(a) > 1 {
					strings.write_string(b, r == ar ? "\\clvmgf" : "\\clvmrg")
				}
				if cell_cspan(a) > 1 {
					strings.write_string(b, c == ac ? "\\clmgf" : "\\clmrg")
				}
			}
			if t.borders {
				strings.write_string(
					b,
					"\\clbrdrt\\brdrs\\brdrw10\\clbrdrl\\brdrs\\brdrw10" +
					"\\clbrdrb\\brdrs\\brdrw10\\clbrdrr\\brdrs\\brdrw10",
				)
			}
			if head {
				// Cell shading, in hundredths of a percent, plus the colour.
				strings.write_string(b, "\\clcbpat2")
			}
			fmt.sbprintf(b, "\\cellx%d", tw(edge))
		}
		strings.write_byte(b, '\n')
		for c in 0 ..< ncols {
			strings.write_string(b, "\\pard\\intbl\\ql")
			fmt.sbprintf(b, "\\f0\\fs%d ", half_pt(15))
			if cl := table_cell(t, r, c); cl != nil && !cl.covered {
				for &cp, i in cl.paras {
					if i > 0 {
						// Several paragraphs in one cell are separated by
						// `\line`; `\par` inside a cell ends the cell in some
						// readers.
						strings.write_string(b, "\\line ")
					}
					if cp.kind == .Image {
						// The same `{\pict}` group as in the body, sized
						// against the column. No `\pard` and no `\par`: both
						// would end the cell.
						rtf_pict(b, &cp, max(20, table_span_w(t, r, c) - 2 * CELL_PAD))
						continue
					}
					rtf_runs(b, &cp, cols, head, cp.kind == .Code)
				}
			}
			strings.write_string(b, "\\cell\n")
		}
		strings.write_string(b, "\\row\n")
	}
	strings.write_string(b, "\\pard\\plain\\s0 \n")
}

// rtf_image writes a `{\pict}` group with the file's bytes in hex.
//
// RTF has no container and no compression: the picture goes in as hexadecimal
// digits, two per byte, which doubles it. `\pngblip` and `\jpegblip` say what
// the bytes are, `\picw`/`\pich` give the intrinsic size in pixels and
// `\picwgoal`/`\pichgoal` the drawn size in twips — a reader that finds only
// the first pair draws the picture at its pixel size in points, which is a
// third too big.
@(private = "file")
rtf_image :: proc(b: ^strings.Builder, pa: ^Paragraph) {
	strings.write_string(b, "\\pard\\plain\\s0")
	switch pa.align {
	case .Center, .Justify:
		strings.write_string(b, "\\qc")
	case .Right:
		strings.write_string(b, "\\qr")
	case .Left:
		strings.write_string(b, "\\ql")
	}
	strings.write_byte(b, ' ')
	rtf_pict(b, pa)
	strings.write_string(b, "\\par\n")
}

// rtf_pict is the `{\pict}` group alone, without the paragraph around it: a
// picture in a table cell needs the group and must not have the `\pard` or
// the `\par`, either of which would end the cell.
@(private = "file")
rtf_pict :: proc(b: ^strings.Builder, pa: ^Paragraph, measure := f32(CONTENT_W)) {
	im := pa.img
	w, h := image_para_size(pa, measure, CONTENT_H)
	if im == nil || len(im.bytes) == 0 || im.kind == .Unknown {
		strings.write_byte(b, '{')
		rtf_text(b, fmt.tprintf("[%s]", im == nil ? "picture" : (im.alt != "" ? im.alt : im.path)))
		strings.write_byte(b, '}')
		return
	}
	strings.write_byte(b, '{')
	strings.write_string(b, "\\pict")
	strings.write_string(b, im.kind == .PNG ? "\\pngblip" : "\\jpegblip")
	fmt.sbprintf(
		b,
		"\\picw%d\\pich%d\\picwgoal%d\\pichgoal%d\n",
		im.w,
		im.h,
		tw(w),
		tw(h),
	)
	hex := "0123456789abcdef"
	for v, i in im.bytes {
		strings.write_byte(b, hex[v >> 4])
		strings.write_byte(b, hex[v & 0xf])
		if i % 40 == 39 {
			strings.write_byte(b, '\n')
		}
	}
	strings.write_byte(b, '}')
}

export_rtf :: proc(d: ^Doc, path, title: string) -> bool {
	text := doc_to_rtf(d, title, context.temp_allocator)
	return os.write_entire_file(path, transmute([]u8)text) == nil
}

// ---------------------------------------------------------------------------
// A small XML scanner, for .docx import
// ---------------------------------------------------------------------------
//
// Not a parser: a scanner that walks tags and character data in order. That
// is all `word/document.xml` needs, because WordprocessingML's structure is
// flat where it matters — paragraphs contain runs contain text — and a real
// parser would be several hundred lines for no gain here.

Xml_Kind :: enum u8 {
	Open,
	Close,
	Empty,
	Text,
	Done,
}

Xml :: struct {
	src:   string,
	at:    int,
	kind:  Xml_Kind,
	name:  string,
	attrs: string,
	text:  string,
}

xml_attr :: proc(x: ^Xml, key: string, alloc := context.temp_allocator) -> (string, bool) {
	s := x.attrs
	k := 0
	for {
		i := strings.index(s[k:], key)
		if i < 0 {
			return "", false
		}
		at := k + i
		// The match must be a whole attribute name: preceded by space and
		// followed by `=`, so `w:val` does not match `w:value`.
		before_ok := at == 0 || s[at - 1] == ' ' || s[at - 1] == '\t'
		j := at + len(key)
		for j < len(s) && s[j] == ' ' {
			j += 1
		}
		if !before_ok || j >= len(s) || s[j] != '=' {
			k = at + len(key)
			continue
		}
		j += 1
		for j < len(s) && s[j] == ' ' {
			j += 1
		}
		if j >= len(s) || (s[j] != '"' && s[j] != '\'') {
			return "", false
		}
		q := s[j]
		j += 1
		e := j
		for e < len(s) && s[e] != q {
			e += 1
		}
		return xml_unescape(s[j:e], alloc), true
	}
}

xml_unescape :: proc(s: string, alloc := context.temp_allocator) -> string {
	if strings.index_byte(s, '&') < 0 {
		return s
	}
	b := strings.builder_make(alloc)
	i := 0
	for i < len(s) {
		if s[i] != '&' {
			strings.write_byte(&b, s[i])
			i += 1
			continue
		}
		semi := strings.index_byte(s[i:], ';')
		if semi < 0 || semi > 12 {
			strings.write_byte(&b, s[i])
			i += 1
			continue
		}
		ent := s[i + 1:i + semi]
		switch ent {
		case "amp":
			strings.write_byte(&b, '&')
		case "lt":
			strings.write_byte(&b, '<')
		case "gt":
			strings.write_byte(&b, '>')
		case "quot":
			strings.write_byte(&b, '"')
		case "apos":
			strings.write_byte(&b, '\'')
		case:
			if len(ent) > 1 && ent[0] == '#' {
				hex := ent[1] == 'x' || ent[1] == 'X'
				v, got := strconv.parse_u64_of_base(hex ? ent[2:] : ent[1:], hex ? 16 : 10)
				if got && v > 0 && v <= 0x10ffff {
					strings.write_rune(&b, rune(v))
				}
			}
		}
		i += semi + 1
	}
	return strings.to_string(b)
}

xml_next :: proc(x: ^Xml) -> bool {
	s := x.src
	if x.at >= len(s) {
		x.kind = .Done
		return false
	}
	if s[x.at] != '<' {
		e := strings.index_byte(s[x.at:], '<')
		end := e < 0 ? len(s) : x.at + e
		x.kind = .Text
		x.text = s[x.at:end]
		x.name = ""
		x.at = end
		return true
	}
	// Declarations, comments and CDATA: skipped wholesale.
	if strings.has_prefix(s[x.at:], "<!--") {
		e := strings.index(s[x.at:], "-->")
		x.at = e < 0 ? len(s) : x.at + e + 3
		return xml_next(x)
	}
	if strings.has_prefix(s[x.at:], "<?") || strings.has_prefix(s[x.at:], "<!") {
		e := strings.index_byte(s[x.at:], '>')
		x.at = e < 0 ? len(s) : x.at + e + 1
		return xml_next(x)
	}

	i := x.at + 1
	closing := i < len(s) && s[i] == '/'
	if closing {
		i += 1
	}
	ns := i
	for i < len(s) && s[i] != ' ' && s[i] != '\t' && s[i] != '\n' && s[i] != '\r' && s[i] != '>' && s[i] != '/' {
		i += 1
	}
	x.name = s[ns:i]

	// Attributes run to the closing `>`, with quoted values skipped over so a
	// `>` inside one does not end the tag early.
	as := i
	for i < len(s) && s[i] != '>' {
		if s[i] == '"' || s[i] == '\'' {
			q := s[i]
			i += 1
			for i < len(s) && s[i] != q {
				i += 1
			}
		}
		i += 1
	}
	raw := s[as:min(i, len(s))]
	empty := strings.has_suffix(strings.trim_right_space(raw), "/")
	if empty {
		raw = raw[:strings.last_index_byte(raw, '/')]
	}
	x.attrs = raw
	x.kind = closing ? .Close : (empty ? .Empty : .Open)
	x.text = ""
	x.at = min(i + 1, len(s))
	return true
}

// ---------------------------------------------------------------------------
// .docx import
// ---------------------------------------------------------------------------

// docx_kind maps a Word style id onto a paragraph kind. Style ids vary by
// producer — Word writes `Heading1`, LibreOffice writes `Heading_20_1` into
// ODF and `Heading1` into OOXML, Pandoc writes `Heading1` too — so the id is
// folded to lower case with separators removed before matching.
@(private = "file")
docx_kind :: proc(id: string) -> (Para_Kind, bool) {
	b := strings.builder_make(context.temp_allocator)
	for i in 0 ..< len(id) {
		c := id[i]
		switch {
		case c >= 'A' && c <= 'Z':
			strings.write_byte(&b, c + 32)
		case c >= 'a' && c <= 'z', c >= '0' && c <= '9':
			strings.write_byte(&b, c)
		}
	}
	switch strings.to_string(b) {
	case "heading1", "title", "h1":
		return .H1, true
	case "heading2", "subtitle", "h2":
		return .H2, true
	case "heading3", "heading4", "heading5", "heading6", "h3":
		return .H3, true
	case "quote", "blockquote", "intensequote", "blocktext":
		return .Quote, true
	case "code", "htmlpreformatted", "preformattedtext", "sourcetext", "sourcecode", "plaintext":
		return .Code, true
	}
	return .Body, false
}

// attr_int reads an integer attribute. It exists because `int_arg` in
// main.odin treats 0 as "absent" — fine for a command-line page count, fatal
// here, where `w:abstractNumId="0"` is the bullet list.
@(private = "file")
attr_int :: proc(x: ^Xml, key: string, def: int) -> int {
	v, has := xml_attr(x, key)
	if !has || len(v) == 0 {
		return def
	}
	neg := v[0] == '-'
	n := 0
	digits := 0
	for i in (neg ? 1 : 0) ..< len(v) {
		if v[i] < '0' || v[i] > '9' {
			return def
		}
		n = n * 10 + int(v[i] - '0')
		digits += 1
	}
	if digits == 0 {
		return def
	}
	return neg ? -n : n
}

@(private = "file")
docx_on :: proc(x: ^Xml) -> bool {
	// `<w:b/>` means on; `<w:b w:val="0"/>` means off.
	if v, has := xml_attr(x, "w:val"); has {
		return !(v == "0" || v == "false" || v == "none" || v == "off")
	}
	return true
}

// docx_numbering_kinds reads word/numbering.xml and reports, for each numId,
// whether level 0 is a bullet or a number. Without it an imported document
// cannot tell "1." from "•", since the paragraph only names a numId.
@(private = "file")
docx_numbering_kinds :: proc(src: string) -> map[int]List_Kind {
	abstract := make(map[int]List_Kind, 8, context.temp_allocator)
	out := make(map[int]List_Kind, 8, context.temp_allocator)
	x := Xml {
		src = src,
	}
	cur_abs := -1
	cur_lvl := -1
	cur_num := -1
	for xml_next(&x) {
		if x.kind == .Text {
			continue
		}
		switch x.name {
		case "w:abstractNum":
			cur_abs = x.kind == .Open ? attr_int(&x, "w:abstractNumId", -1) : -1
		case "w:lvl":
			if x.kind == .Open || x.kind == .Empty {
				cur_lvl = attr_int(&x, "w:ilvl", -1)
			}
		case "w:numFmt":
			// Only level 0 decides: a list that starts with bullets and
			// switches to numbers deeper down is still a bullet list here.
			if cur_abs >= 0 && cur_lvl == 0 {
				if v, has := xml_attr(&x, "w:val"); has {
					abstract[cur_abs] = v == "bullet" || v == "none" ? .Bullet : .Numbered
				}
			}
		case "w:num":
			cur_num = x.kind == .Open ? attr_int(&x, "w:numId", -1) : -1
		case "w:abstractNumId":
			if cur_num >= 0 {
				a := attr_int(&x, "w:val", -1)
				out[cur_num] = abstract[a] or_else .Numbered
			}
		}
	}
	return out
}

// doc_from_docx_xml is the import proper: a walk over document.xml that
// assembles paragraphs and runs. It is deliberately forgiving — anything it
// does not recognise is ignored rather than rejected, because a .docx from
// the wild carries a great deal this model has no place for.
// docx_rel_targets reads word/_rels/document.xml.rels and maps a relationship
// id to its target. The import needs it for pictures: a <a:blip> names an id,
// and only the relationship part says which file in word/media that is.
@(private = "file")
docx_rel_targets :: proc(src: string) -> map[string]string {
	out := make(map[string]string, 8, context.temp_allocator)
	x := Xml {
		src = src,
	}
	for xml_next(&x) {
		if x.name != "Relationship" || x.kind == .Text || x.kind == .Close {
			continue
		}
		id, has_id := xml_attr(&x, "Id")
		target, has_t := xml_attr(&x, "Target")
		if has_id && has_t {
			out[strings.clone(id, context.temp_allocator)] = strings.clone(target, context.temp_allocator)
		}
	}
	return out
}

doc_from_docx_xml :: proc(
	document, numbering: string,
	rels := "",
	archive: []u8 = nil,
) -> Doc {
	num_kinds := docx_numbering_kinds(numbering)
	rel_map := docx_rel_targets(rels)
	out := Doc {
		paras = make([dynamic]Paragraph, 0, 64),
	}

	x := Xml {
		src = document,
	}
	in_para := false
	in_ppr := false
	in_rpr := false
	in_run := false
	in_text := false
	preserve := false
	drop_depth := 0 // inside a part whose text must not be imported

	pa: Paragraph
	cs: Char_Style
	explicit_size := f32(0)
	num_id := -1
	ilvl := 0

	// --- table state.
	//
	// The scanner is flat, so the table is assembled in three accumulators:
	// the table being built, the row, and the cell. A paragraph that closes
	// while `cell_open` is set goes into the cell instead of into the
	// document, which is the whole of the nesting this needs.
	//
	// `tbl_depth` guards against a nested table: the model has no place for
	// one, so an inner table's paragraphs are flattened into the cell that
	// contains it rather than producing a grid nothing would lay out.
	tbl_depth := 0
	tbl: Table
	row: Row
	cell: Cell
	cell_open := false
	row_open := false
	grid := make([dynamic]f32, 0, 8, context.temp_allocator)
	tbl_header := false
	tbl_borders := true
	// Merged cells: `gridSpan` and `vMerge` on the cell being read, and the
	// grid positions that continue a merge, resolved when the table closes.
	tc_span := 1
	tc_vcont := false
	conts_h := make([dynamic][2]int, 0, 8, context.temp_allocator)
	conts_v := make([dynamic][2]int, 0, 8, context.temp_allocator)
	// --- picture state
	blip_rid := ""
	run_text := strings.builder_make(context.temp_allocator)
	// One `<w:t>` at a time, so `xml:space` can be honoured per element:
	// without `preserve`, OOXML says the edges of the text may be trimmed,
	// and a producer that relies on that writes " word " meaning "word".
	t_text := strings.builder_make(context.temp_allocator)

	start_para :: proc(pa: ^Paragraph) {
		pa^ = Paragraph {
			runs = make([dynamic]Run, 0, 4),
		}
	}

	for xml_next(&x) {
		if x.kind == .Text {
			if in_text && drop_depth == 0 {
				strings.write_string(&t_text, xml_unescape(x.text))
			}
			continue
		}

		// Deleted text and field instructions are not document content.
		switch x.name {
		case "w:delText", "w:instrText", "mc:Fallback", "w:proofErr":
			if x.kind == .Open {
				drop_depth += 1
			} else if x.kind == .Close && drop_depth > 0 {
				drop_depth -= 1
			}
			continue
		}

		switch x.name {
		case "w:tbl":
			switch x.kind {
			case .Open:
				tbl_depth += 1
				if tbl_depth == 1 {
					tbl = Table {
						rows    = make([dynamic]Row, 0, 4),
						widths  = make([dynamic]f32, 0, 4),
						borders = true,
					}
					clear(&grid)
					clear(&conts_h)
					clear(&conts_v)
					tbl_header = false
					tbl_borders = true
				}
			case .Close:
				if tbl_depth == 1 {
					tbl.header = tbl_header
					tbl.borders = tbl_borders
					for w in grid {
						append(&tbl.widths, w)
					}
					if len(tbl.rows) == 0 {
						r := Row {
							cells = make([dynamic]Cell, 0, 1),
						}
						append(&r.cells, cell_make())
						append(&tbl.rows, r)
					}
					table_fit_widths(&tbl)
					table_apply_conts(&tbl, conts_h[:], conts_v[:])
					tp := para_make(.Table)
					tp.table = new(Table)
					tp.table^ = tbl
					append(&out.paras, tp)
					tbl = {}
				}
				tbl_depth = max(0, tbl_depth - 1)
			case .Empty, .Text, .Done:
			}
		case "w:tblBorders":
			// A border block that names `none` on every side means the table
			// was written without rules.
			if x.kind == .Open && tbl_depth == 1 {
				tbl_borders = false
			}
		case "w:top", "w:left", "w:bottom", "w:right", "w:insideH", "w:insideV":
			if tbl_depth == 1 {
				if v, has := xml_attr(&x, "w:val"); has && v != "none" && v != "nil" {
					tbl_borders = true
				}
			}
		case "w:gridCol":
			if tbl_depth == 1 {
				if n := attr_int(&x, "w:w", 0); n > 0 {
					append(&grid, f32(n) / 15) // twips → px
				}
			}
		case "w:tblHeader":
			if tbl_depth == 1 && docx_on(&x) {
				tbl_header = true
			}
		case "w:tr":
			if tbl_depth != 1 {
				break
			}
			switch x.kind {
			case .Open:
				row = Row {
					cells = make([dynamic]Cell, 0, 4),
				}
				row_open = true
			case .Close:
				if row_open {
					if len(row.cells) == 0 {
						append(&row.cells, cell_make())
					}
					append(&tbl.rows, row)
					row_open = false
				}
			case .Empty, .Text, .Done:
			}
		case "w:tc":
			if tbl_depth != 1 {
				break
			}
			switch x.kind {
			case .Open:
				cell = Cell {
					paras = make([dynamic]Paragraph, 0, 1),
				}
				cell_open = true
				tc_span = 1
				tc_vcont = false
			case .Close:
				if cell_open {
					if len(cell.paras) == 0 {
						append(&cell.paras, para_make())
					}
					if row_open {
						// A cell spanning n grid columns holds the first and
						// stands for the rest, which are filled in as empty
						// cells continuing it so the grid stays positional.
						at := [2]int{len(tbl.rows), len(row.cells)}
						if tc_vcont {
							append(&conts_v, at)
						}
						append(&row.cells, cell)
						for k in 1 ..< clamp(tc_span, 1, TABLE_MAX_COLS) {
							append(&row.cells, cell_make())
							append(&conts_h, [2]int{at[0], at[1] + k})
						}
					} else {
						cell_destroy(&cell)
					}
					cell_open = false
				}
			case .Empty, .Text, .Done:
			}
		case "w:gridSpan":
			if tbl_depth == 1 && cell_open {
				tc_span = attr_int(&x, "w:val", 1)
			}
		case "w:vMerge":
			// `restart` begins a merge; no value, or `continue`, carries on.
			if tbl_depth == 1 && cell_open {
				v, has := xml_attr(&x, "w:val")
				tc_vcont = !has || v == "continue"
			}
		case "a:blip":
			if v, has := xml_attr(&x, "r:embed"); has {
				blip_rid = strings.clone(v, context.temp_allocator)
			}
		case "w:p":
			switch x.kind {
			case .Open:
				start_para(&pa)
				in_para = true
				num_id, ilvl = -1, 0
				blip_rid = ""
			case .Close:
				if in_para {
					if num_id > 0 {
						pa.list = num_kinds[num_id] or_else .Numbered
						pa.depth = clamp(ilvl, 0, 8)
					}
					// A paragraph that carried a picture becomes an image
					// paragraph, with the bytes read back out of the archive.
					// This used to be skipped inside a cell, because the
					// model had nowhere to put a picture in one. It has.
					if blip_rid != "" {
						if target, has := rel_map[blip_rid]; has {
							part := strings.has_prefix(target, "/") 							? target[1:] 							: fmt.tprintf("word/%s", target)
							if data, got := zip_read_entry(archive, part, context.temp_allocator);
							   got {
								if im, decoded := image_from_bytes(data, part, "", 1); decoded {
									for &r in pa.runs {
										delete(r.text)
									}
									clear(&pa.runs)
									pa.kind = .Image
									pa.img = new(Doc_Image)
									pa.img^ = im
								}
							}
						}
					}
					blip_rid = ""
					if len(pa.runs) == 0 {
						append(&pa.runs, run_make({}))
					}
					normalise(&pa)
					if cell_open {
						// Inside a cell: cell paragraphs carry no page break
						// and no table of their own. A picture is allowed —
						// only a nested table is not.
						pa.break_before = false
						if !text_kind(pa.kind) && pa.kind != .Image {
							pa.kind = .Body
							if pa.img != nil {
								image_destroy(pa.img)
								free(pa.img)
								pa.img = nil
							}
						}
						append(&cell.paras, pa)
					} else {
						append(&out.paras, pa)
					}
					in_para = false
				}
			case .Empty:
				start_para(&pa)
				append(&pa.runs, run_make({}))
				if cell_open {
					append(&cell.paras, pa)
				} else {
					append(&out.paras, pa)
				}
			case .Text, .Done:
			}
		case "w:pPr":
			in_ppr = x.kind == .Open
		case "w:rPr":
			in_rpr = x.kind != .Close
			if x.kind == .Open {
				cs = {}
				explicit_size = 0
			}
		case "w:pStyle":
			if in_ppr && in_para {
				if v, has := xml_attr(&x, "w:val"); has {
					if k, known := docx_kind(v); known {
						pa.kind = k
					}
				}
			}
		case "w:jc":
			if in_ppr && in_para {
				if v, has := xml_attr(&x, "w:val"); has {
					switch v {
					case "center":
						pa.align = .Center
					case "right", "end":
						pa.align = .Right
					case "both", "distribute":
						pa.align = .Justify
					}
				}
			}
		case "w:numId":
			if in_ppr {
				num_id = attr_int(&x, "w:val", -1)
			}
		case "w:ilvl":
			if in_ppr {
				ilvl = attr_int(&x, "w:val", 0)
			}
		case "w:pageBreakBefore":
			if in_ppr && in_para {
				pa.break_before = docx_on(&x)
			}
		case "w:r":
			switch x.kind {
			case .Open:
				in_run = true
				cs = {}
				explicit_size = 0
				strings.builder_reset(&run_text)
			case .Close:
				if in_run && in_para {
					t := strings.to_string(run_text)
					if len(t) > 0 {
						style := cs
						// A size that matches the paragraph style's own is
						// left as "inherit", so the model stays clean.
						if explicit_size > 0 {
							if abs(explicit_size - kind_metrics(pa.kind).size) > 0.6 {
								style.size = explicit_size
							}
						}
						append(&pa.runs, run_make(style, detab(t)))
					}
					strings.builder_reset(&run_text)
				}
				in_run = false
			case .Empty, .Text, .Done:
			}
		case "w:b", "w:bCs":
			if in_rpr {cs.bold = docx_on(&x)}
		case "w:i", "w:iCs":
			if in_rpr {cs.italic = docx_on(&x)}
		case "w:u":
			if in_rpr {
				v, _ := xml_attr(&x, "w:val")
				cs.underline = v != "none" && v != "0"
			}
		case "w:color":
			if in_rpr {
				if v, has := xml_attr(&x, "w:val"); has && v != "auto" && len(v) == 6 {
					if n, pok := strconv.parse_u64_of_base(v, 16); pok {
						c := u32(n & 0xffffff)
						// Near-black is the default ink, not a colour.
						if c != 0 && c != 0x121212 {
							cs.color = 0xff000000 | c
						}
					}
				}
			}
		case "w:sz":
			if in_rpr {
				if v, has := xml_attr(&x, "w:val"); has {
					if n, pok := strconv.parse_f64(v); pok && n > 0 {
						explicit_size = f32(n) * 2 / 3 // half-points → px
					}
				}
			}
		case "w:rFonts":
			if in_rpr {
				v, _ := xml_attr(&x, "w:ascii")
				lower := strings.to_lower(v, context.temp_allocator)
				for name in ([?]string{"courier", "mono", "consolas", "menlo"}) {
					if strings.contains(lower, name) {
						cs.mono = true
						break
					}
				}
			}
		case "w:t":
			switch x.kind {
			case .Open:
				in_text = true
				v, _ := xml_attr(&x, "xml:space")
				preserve = v == "preserve"
				strings.builder_reset(&t_text)
			case .Close:
				in_text = false
				t := strings.to_string(t_text)
				strings.write_string(&run_text, preserve ? t : strings.trim_space(t))
				strings.builder_reset(&t_text)
			case .Empty, .Text, .Done:
			}
		case "w:tab":
			if in_run && drop_depth == 0 {
				strings.write_string(&run_text, "    ")
			}
		case "w:br", "w:cr":
			// A soft break inside a run becomes a space; the model has no
			// line break of its own, and losing the word boundary would be
			// worse than losing the break.
			if in_run && drop_depth == 0 {
				strings.write_byte(&run_text, ' ')
			}
		}
	}

	// A .docx may not end with a table: the body needs a paragraph after one,
	// and every writer — this one included — emits an empty paragraph to
	// satisfy that. It is structure, not content, so reading it back as a
	// blank paragraph would make a round trip grow a line every time. Dropping
	// exactly that one trailing empty paragraph is the inverse of the rule the
	// writer applies.
	if len(out.paras) >= 2 {
		last := &out.paras[len(out.paras) - 1]
		prev := &out.paras[len(out.paras) - 2]
		if prev.kind == .Table && last.kind == .Body && para_len(last) == 0 && last.list == .None {
			para_destroy(last)
			pop(&out.paras)
		}
	}

	if len(out.paras) == 0 {
		append(&out.paras, para_make())
	}
	return out
}

import_docx :: proc(path: string) -> (d: Doc, ok: bool) {
	archive, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		return {}, false
	}
	document, got := zip_read_entry(archive, "word/document.xml", context.temp_allocator)
	if !got {
		return {}, false
	}
	numbering, _ := zip_read_entry(archive, "word/numbering.xml", context.temp_allocator)
	rels, _ := zip_read_entry(archive, "word/_rels/document.xml.rels", context.temp_allocator)
	return doc_from_docx_xml(string(document), string(numbering), string(rels), archive), true
}

// ---------------------------------------------------------------------------
// .odt import
// ---------------------------------------------------------------------------
//
// The twin of the .docx importer, and the same shape: one forward scan of
// `content.xml` with the little XML scanner above, assembling paragraphs,
// lists, tables and pictures as the tags go by.
//
// ODF differs from OOXML in three ways that matter here, and all three are
// handled before the body walk rather than during it:
//
//   * **Formatting is by reference.** A run says `text:style-name="T3"`, and
//     what T3 *is* lives in `<office:automatic-styles>` earlier in the same
//     file. So the styles are collected in a first pass and looked up in the
//     second.
//   * **Repetition is compressed.** `table:number-columns-repeated="5"` means
//     five identical columns, and a writer uses it freely. Expanding it is not
//     optional: a table read without it has one column where it should have
//     five.
//   * **Whitespace is structural.** A run of spaces is `<text:s text:c="n"/>`,
//     a tab is `<text:tab/>`, and literal runs of spaces in the file are
//     collapsed. Reading the character data alone loses every indent.

// odt_len_px converts an ODF length — they carry their unit — to layout pixels.
@(private = "file")
odt_len_px :: proc(s: string) -> f32 {
	n := len(s)
	if n == 0 {
		return 0
	}
	unit := ""
	digits := n
	for i := n; i > 0; i -= 1 {
		c := s[i - 1]
		if (c >= '0' && c <= '9') || c == '.' || c == '-' || c == '+' {
			digits = i
			break
		}
	}
	if digits < n {
		unit = s[digits:]
	}
	v, ok := strconv.parse_f64(s[:digits])
	if !ok {
		return 0
	}
	switch unit {
	case "in":
		return f32(v) * 96
	case "cm":
		return f32(v) * 96 / 2.54
	case "mm":
		return f32(v) * 96 / 25.4
	case "pt":
		return f32(v) * 96 / 72
	case "pc":
		return f32(v) * 16
	case "px", "":
		return f32(v)
	}
	return f32(v)
}

// odt_style_name decodes ODF's `_XX_` escapes, which is how a space becomes
// `_20_` — so `Heading_20_1` is the style display-named "Heading 1". Without
// this every named style arrives as a stranger and the document imports as a
// wall of body text.
@(private = "file")
odt_style_name :: proc(s: string, alloc := context.temp_allocator) -> string {
	if strings.index_byte(s, '_') < 0 {
		return s
	}
	b := strings.builder_make(alloc)
	i := 0
	for i < len(s) {
		if s[i] == '_' && i + 3 < len(s) && s[i + 3] == '_' {
			if v, ok := strconv.parse_u64_of_base(s[i + 1:i + 3], 16); ok && v >= 0x20 && v < 0x7f {
				strings.write_byte(&b, u8(v))
				i += 4
				continue
			}
		}
		strings.write_byte(&b, s[i])
		i += 1
	}
	return strings.to_string(b)
}

@(private = "file")
Odt_Styles_In :: struct {
	text:  map[string]Char_Style, // T1 → the character style it names
	para:  map[string]string, // P1 → the parent style name it inherits
	align: map[string]Align,
	brk:   map[string]bool,
	col:   map[string]f32, // a table-column style → its width in px
	list:  map[string]List_Kind, // L1 → bullet or numbered
}

// odt_collect_styles is the first pass: everything the body will refer to by
// name.
@(private = "file")
odt_collect_styles :: proc(src: string) -> Odt_Styles_In {
	out := Odt_Styles_In {
		text  = make(map[string]Char_Style, 16, context.temp_allocator),
		para  = make(map[string]string, 16, context.temp_allocator),
		align = make(map[string]Align, 16, context.temp_allocator),
		brk   = make(map[string]bool, 8, context.temp_allocator),
		col   = make(map[string]f32, 16, context.temp_allocator),
		list  = make(map[string]List_Kind, 8, context.temp_allocator),
	}
	x := Xml {
		src = src,
	}
	name := ""
	family := ""
	list_name := ""
	for xml_next(&x) {
		if x.kind == .Text {
			continue
		}
		switch x.name {
		case "style:style":
			if x.kind == .Close {
				name, family = "", ""
				break
			}
			name, _ = xml_attr(&x, "style:name")
			name = strings.clone(name, context.temp_allocator)
			family, _ = xml_attr(&x, "style:family")
			family = strings.clone(family, context.temp_allocator)
			if family == "paragraph" {
				if parent, has := xml_attr(&x, "style:parent-style-name"); has {
					out.para[name] = strings.clone(parent, context.temp_allocator)
				}
			}
		case "style:text-properties":
			if name == "" || (family != "text" && family != "paragraph") {
				break
			}
			cs := out.text[name] or_else Char_Style{}
			if v, has := xml_attr(&x, "fo:font-weight"); has && v == "bold" {
				cs.bold = true
			}
			if v, has := xml_attr(&x, "fo:font-style"); has && (v == "italic" || v == "oblique") {
				cs.italic = true
			}
			if v, has := xml_attr(&x, "style:text-underline-style"); has && v != "none" {
				cs.underline = true
			}
			if v, has := xml_attr(&x, "style:font-name"); has {
				low := strings.to_lower(v, context.temp_allocator)
				for m in ([?]string{"mono", "courier", "consolas", "menlo"}) {
					if strings.contains(low, m) {
						cs.mono = true
					}
				}
			}
			if v, has := xml_attr(&x, "fo:font-size"); has {
				if px := odt_len_px(v); px > 0 {
					cs.size = px
				}
			}
			if v, has := xml_attr(&x, "fo:color"); has && len(v) == 7 && v[0] == '#' {
				if n, ok := strconv.parse_u64_of_base(v[1:], 16); ok {
					c := u32(n & 0xffffff)
					if c != 0 && c != 0x121212 {
						cs.color = 0xff000000 | c
					}
				}
			}
			out.text[name] = cs
		case "style:paragraph-properties":
			if name == "" || family != "paragraph" {
				break
			}
			if v, has := xml_attr(&x, "fo:text-align"); has {
				switch v {
				case "center":
					out.align[name] = .Center
				case "end", "right":
					out.align[name] = .Right
				case "justify":
					out.align[name] = .Justify
				case "start", "left":
					out.align[name] = .Left
				}
			}
			if v, has := xml_attr(&x, "fo:break-before"); has && v == "page" {
				out.brk[name] = true
			}
		case "style:table-column-properties":
			if name != "" {
				if v, has := xml_attr(&x, "style:column-width"); has {
					out.col[name] = odt_len_px(v)
				}
			}
		case "text:list-style":
			if x.kind == .Close {
				list_name = ""
				break
			}
			v, _ := xml_attr(&x, "style:name")
			list_name = strings.clone(v, context.temp_allocator)
		case "text:list-level-style-bullet", "text:list-level-style-image":
			// Only level 1 decides, as in the .docx importer.
			if list_name != "" && attr_int(&x, "text:level", 0) == 1 {
				out.list[list_name] = .Bullet
			}
		case "text:list-level-style-number":
			if list_name != "" && attr_int(&x, "text:level", 0) == 1 {
				out.list[list_name] = .Numbered
			}
		}
	}
	return out
}

// odt_kind resolves a paragraph style name to a paragraph kind, following one
// level of `style:parent-style-name` for the automatic styles a writer
// generates (`P3` whose parent is `Quote`).
@(private = "file")
odt_kind :: proc(st: ^Odt_Styles_In, style: string) -> (Para_Kind, bool) {
	if style == "" {
		return .Body, false
	}
	if k, known := docx_kind(odt_style_name(style)); known {
		return k, true
	}
	if parent, has := st.para[style]; has {
		if k, known := docx_kind(odt_style_name(parent)); known {
			return k, true
		}
	}
	return .Body, false
}

// odt_align resolves alignment the same way, through the parent.
@(private = "file")
odt_align :: proc(st: ^Odt_Styles_In, style: string) -> (Align, bool) {
	if a, has := st.align[style]; has {
		return a, true
	}
	if parent, has := st.para[style]; has {
		if a, got := st.align[parent]; got {
			return a, true
		}
	}
	return .Left, false
}

doc_from_odt_xml :: proc(content: string, archive: []u8 = nil) -> Doc {
	styles := odt_collect_styles(content)
	out := Doc {
		paras = make([dynamic]Paragraph, 0, 64),
	}

	x := Xml {
		src = content,
	}

	// The open paragraph, plus the character style stack the spans push.
	pa: Paragraph
	in_para := false
	span: [16]Char_Style
	span_n := 0
	buf := strings.builder_make(context.temp_allocator)

	// Lists nest by element, so the depth is just how many are open, and the
	// kind comes from the outermost one that named a style.
	list_depth := 0
	list_kind := List_Kind.None

	// Table state, exactly as the .docx importer keeps it.
	tbl_depth := 0
	tbl: Table
	row: Row
	cell: Cell
	cell_open := false
	row_open := false
	in_header := false
	widths := make([dynamic]f32, 0, 8, context.temp_allocator)
	// Picture state: a frame's size and target, read off the attributes.
	frame_w, frame_h := f32(0), f32(0)
	frame_href := ""
	frame_align := Align.Center

	cur_style :: proc(span: []Char_Style, n: int) -> Char_Style {
		return n > 0 ? span[n - 1] : Char_Style{}
	}

	flush_run :: proc(pa: ^Paragraph, buf: ^strings.Builder, cs: Char_Style) {
		t := strings.to_string(buf^)
		if len(t) > 0 {
			append(&pa.runs, run_make(cs, detab(t)))
			strings.builder_reset(buf)
		}
	}

	for xml_next(&x) {
		if x.kind == .Text {
			if in_para {
				strings.write_string(&buf, xml_unescape(x.text))
			}
			continue
		}

		switch x.name {
		// --- whitespace that ODF spells out
		case "text:s":
			if in_para {
				n := attr_int(&x, "text:c", 1)
				for _ in 0 ..< clamp(n, 1, 512) {
					strings.write_byte(&buf, ' ')
				}
			}
		case "text:tab":
			if in_para {
				strings.write_string(&buf, "    ")
			}
		case "text:line-break":
			if in_para {
				strings.write_byte(&buf, ' ')
			}

		// --- character styles
		case "text:span":
			switch x.kind {
			case .Open:
				if in_para {
					flush_run(&pa, &buf, cur_style(span[:], span_n))
					cs := cur_style(span[:], span_n)
					if v, has := xml_attr(&x, "text:style-name"); has {
						if s2, got := styles.text[v]; got {
							// A span inherits what it does not override.
							if s2.bold {cs.bold = true}
							if s2.italic {cs.italic = true}
							if s2.underline {cs.underline = true}
							if s2.mono {cs.mono = true}
							if s2.size != 0 {cs.size = s2.size}
							if s2.color != 0 {cs.color = s2.color}
						}
					}
					if span_n < len(span) {
						span[span_n] = cs
						span_n += 1
					}
				}
			case .Close:
				if in_para && span_n > 0 {
					flush_run(&pa, &buf, cur_style(span[:], span_n))
					span_n -= 1
				}
			case .Empty, .Text, .Done:
			}

		// --- pictures
		case "draw:frame":
			switch x.kind {
			case .Open, .Empty:
				frame_w, frame_h, frame_href = 0, 0, ""
				if v, has := xml_attr(&x, "svg:width"); has {
					frame_w = odt_len_px(v)
				}
				if v, has := xml_attr(&x, "svg:height"); has {
					frame_h = odt_len_px(v)
				}
			case .Close, .Text, .Done:
			}
		case "draw:image":
			if v, has := xml_attr(&x, "xlink:href"); has {
				frame_href = strings.clone(v, context.temp_allocator)
			}

		// --- paragraphs and headings
		case "text:p", "text:h":
			switch x.kind {
			case .Open:
				pa = Paragraph {
					runs = make([dynamic]Run, 0, 4),
				}
				in_para = true
				span_n = 0
				strings.builder_reset(&buf)
				frame_href = ""
				frame_w, frame_h = 0, 0
				style, _ := xml_attr(&x, "text:style-name")
				style = strings.clone(style, context.temp_allocator)
				if k, known := odt_kind(&styles, style); known {
					pa.kind = k
				}
				if x.name == "text:h" {
					lvl := attr_int(&x, "text:outline-level", 1)
					pa.kind = lvl <= 1 ? .H1 : (lvl == 2 ? .H2 : .H3)
				}
				if a, got := odt_align(&styles, style); got {
					pa.align = a
				}
				frame_align = pa.align
				if b, got := styles.brk[style]; got && b {
					pa.break_before = true
				}
				if list_depth > 0 && !cell_open {
					pa.list = list_kind
					pa.depth = clamp(list_depth - 1, 0, 8)
					if pa.kind == .Code {
						pa.kind = .Body
					}
				}
			case .Close:
				if !in_para {
					break
				}
				flush_run(&pa, &buf, cur_style(span[:], span_n))
				span_n = 0

				// A paragraph whose only content was a frame is a picture —
				// in a table cell as readily as in the body, now that the
				// model has a place for one.
				if frame_href != "" {
					if data, got := zip_read_entry(archive, frame_href, context.temp_allocator); got {
						if im, decoded := image_from_bytes(data, frame_href, "", 1); decoded {
							im2 := im
							// The frame's drawn size is what the document asked
							// for; turn it back into a scale on the intrinsic
							// pixels so the model stays in its own terms.
							if frame_w > 0 && im2.w > 0 {
								im2.scale = frame_w / f32(im2.w)
							}
							for &r in pa.runs {
								delete(r.text)
							}
							clear(&pa.runs)
							pa.kind = .Image
							pa.align = frame_align
							pa.img = new(Doc_Image)
							pa.img^ = im2
						}
					}
				}
				frame_href = ""

				if len(pa.runs) == 0 {
					append(&pa.runs, run_make({}))
				}
				normalise(&pa)
				if cell_open {
					pa.break_before = false
					// A picture is allowed in a cell; a nested table is not.
					if !text_kind(pa.kind) && pa.kind != .Image {
						pa.kind = .Body
						if pa.img != nil {
							image_destroy(pa.img)
							free(pa.img)
							pa.img = nil
						}
					}
					append(&cell.paras, pa)
				} else {
					append(&out.paras, pa)
				}
				in_para = false
			case .Empty:
				np := para_make()
				if cell_open {
					append(&cell.paras, np)
				} else {
					append(&out.paras, np)
				}
			case .Text, .Done:
			}

		// --- lists
		case "text:list":
			switch x.kind {
			case .Open:
				list_depth += 1
				if v, has := xml_attr(&x, "text:style-name"); has {
					if k, got := styles.list[v]; got {
						list_kind = k
					} else if list_kind == .None {
						list_kind = .Bullet
					}
				} else if list_kind == .None {
					list_kind = .Bullet
				}
			case .Close:
				list_depth = max(0, list_depth - 1)
				if list_depth == 0 {
					list_kind = .None
				}
			case .Empty, .Text, .Done:
			}

		// --- tables
		case "table:table":
			switch x.kind {
			case .Open:
				tbl_depth += 1
				if tbl_depth == 1 {
					tbl = Table {
						rows    = make([dynamic]Row, 0, 4),
						widths  = make([dynamic]f32, 0, 4),
						borders = true,
					}
					clear(&widths)
					in_header = false
				}
			case .Close:
				if tbl_depth == 1 {
					for w in widths {
						append(&tbl.widths, w)
					}
					if len(tbl.rows) == 0 {
						r := Row {
							cells = make([dynamic]Cell, 0, 1),
						}
						append(&r.cells, cell_make())
						append(&tbl.rows, r)
					}
					table_fit_widths(&tbl)
					table_normalise(&tbl) // spans were read off each cell; covered cells came as their own elements
					tp := para_make(.Table)
					tp.table = new(Table)
					tp.table^ = tbl
					append(&out.paras, tp)
					tbl = {}
				}
				tbl_depth = max(0, tbl_depth - 1)
			case .Empty, .Text, .Done:
			}
		case "table:table-column":
			if tbl_depth == 1 {
				w := f32(0)
				if v, has := xml_attr(&x, "table:style-name"); has {
					w = styles.col[v] or_else 0
				}
				for _ in 0 ..< clamp(attr_int(&x, "table:number-columns-repeated", 1), 1, TABLE_MAX_COLS) {
					append(&widths, w)
				}
			}
		case "table:table-header-rows":
			if tbl_depth == 1 {
				// Every row inside this element is a header row; this model
				// has one, which is the first.
				in_header = x.kind == .Open
				if x.kind == .Open {
					tbl.header = true
				}
			}
		case "table:table-row":
			if tbl_depth != 1 {
				break
			}
			switch x.kind {
			case .Open:
				row = Row {
					cells = make([dynamic]Cell, 0, 4),
				}
				row_open = true
			case .Close:
				if row_open {
					if len(row.cells) == 0 {
						append(&row.cells, cell_make())
					}
					// `table:number-rows-repeated` is not expanded: it is rare
					// outside spreadsheets, and a writer that uses it on a
					// text table is asking for identical rows, which is not
					// something this importer needs to invent.
					append(&tbl.rows, row)
					row_open = false
				}
			case .Empty, .Text, .Done:
			}
		case "table:table-cell", "table:covered-table-cell":
			if tbl_depth != 1 {
				break
			}
			switch x.kind {
			case .Open:
				cell = Cell {
					paras = make([dynamic]Paragraph, 0, 1),
					cspan = attr_int(&x, "table:number-columns-spanned", 1),
					rspan = attr_int(&x, "table:number-rows-spanned", 1),
				}
				cell_open = true
			case .Close:
				if cell_open {
					if len(cell.paras) == 0 {
						append(&cell.paras, para_make())
					}
					if row_open {
						append(&row.cells, cell)
					} else {
						cell_destroy(&cell)
					}
					cell_open = false
				}
			case .Empty:
				// An empty cell element still occupies its columns, and an
				// empty merged cell still spans.
				if row_open {
					for k in 0 ..< clamp(attr_int(&x, "table:number-columns-repeated", 1), 1, TABLE_MAX_COLS) {
						cl := cell_make()
						if k == 0 && x.name == "table:table-cell" {
							cl.cspan = attr_int(&x, "table:number-columns-spanned", 1)
							cl.rspan = attr_int(&x, "table:number-rows-spanned", 1)
						}
						append(&row.cells, cl)
					}
				}
			case .Text, .Done:
			}
		}
	}

	if len(out.paras) == 0 {
		append(&out.paras, para_make())
	}
	return out
}

import_odt :: proc(path: string) -> (d: Doc, ok: bool) {
	archive, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		return {}, false
	}
	content, got := zip_read_entry(archive, "content.xml", context.temp_allocator)
	if !got {
		return {}, false
	}
	return doc_from_odt_xml(string(content), archive), true
}
