package main

// EPUB 3, written by hand.
//
// An EPUB is an OCF container — a ZIP — holding five kinds of thing, and all
// five are generated here:
//
//   mimetype                 first, stored, no extra field. OCF 3.3 §3.4.
//   META-INF/container.xml   points at the package document, and nothing else
//   OEBPS/content.opf        the package: metadata, manifest, spine
//   OEBPS/nav.xhtml          the EPUB 3 navigation document (the ToC)
//   OEBPS/chNNN.xhtml        one XHTML document per chapter
//   OEBPS/style.css          enough CSS that the text is readable
//
// Four things reading software is strict about, and a hand-written EPUB gets
// wrong by default:
//
//   * **the unique identifier is declared twice.** `<package unique-identifier
//     ="bookid">` names an id, and a `<dc:identifier id="bookid">` must carry
//     it. A mismatch and the package is invalid.
//   * **`dcterms:modified` is required** in EPUB 3 and must be a UTC timestamp
//     with no fractional seconds: `2026-10-04T12:00:00Z`. Nothing else is
//     accepted.
//   * **the nav document is both a manifest item with `properties="nav"` and a
//     real XHTML file** with an `<nav epub:type="toc">`. Readers that ignore
//     the OPF guide use this and only this.
//   * **XHTML, not HTML.** Every element closes, the namespace is declared,
//     and the five XML entities are escaped. A bare `&` from a scanned page
//     is enough to make the whole chapter unparseable, which is why
//     `xml_escape` is applied to every piece of recognised text with no
//     exceptions.
//
// There is no cover image. One could be made from the first page raster, but
// that would put a picture of the user's document inside a file they may
// share, and the page images stay out of the EPUB for the same reason.

import "core:fmt"
import "core:strings"
import "core:time"

EPUB_MIMETYPE :: "application/epub+zip"

// ---------------------------------------------------------------------------
// XML escaping
// ---------------------------------------------------------------------------

// xml_escape handles the five predefined entities plus the control characters
// XML 1.0 forbids outright. OCR on a noisy scan does produce stray control
// bytes, and a literal 0x0c in a chapter is a hard parse error in every
// reader; dropping them is the only valid option, since XML 1.0 has no escape
// for them either.
xml_escape :: proc(s: string, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	for r in s {
		switch r {
		case '&':
			strings.write_string(&b, "&amp;")
		case '<':
			strings.write_string(&b, "&lt;")
		case '>':
			strings.write_string(&b, "&gt;")
		case '"':
			strings.write_string(&b, "&quot;")
		case '\'':
			strings.write_string(&b, "&apos;")
		case '\t', '\n':
			strings.write_byte(&b, ' ')
		case:
			if r < 0x20 || r == 0x7f || (r >= 0xfffe && r <= 0xffff) {
				continue // not representable in XML 1.0, escaped or not
			}
			strings.write_rune(&b, r)
		}
	}
	return strings.to_string(b)
}

// ---------------------------------------------------------------------------
// Identifiers
// ---------------------------------------------------------------------------

// epub_uid builds a stable `urn:uuid:`-shaped identifier from the document
// itself, so re-converting the same scan produces the same book id rather than
// a new one each time. It is a hash, not a random UUID: a real v4 UUID would
// make every export a different book to a reader's library.
epub_uid :: proc(d: ^Doc, allocator := context.allocator) -> string {
	h := u64(0xcbf29ce484222325)
	mix :: proc(h: ^u64, s: string) {
		for c in transmute([]u8)s {
			h^ = (h^ ~ u64(c)) * 0x100000001b3
		}
	}
	mix(&h, d.title)
	mix(&h, base_name(d.source))
	for b in d.blocks {
		mix(&h, b.text)
	}
	return fmt.aprintf(
		"urn:uuid:%08x-%04x-4%03x-8%03x-%012x",
		u32(h >> 32),
		u16(h >> 16),
		u16(h) & 0xfff,
		u16(h >> 48) & 0xfff,
		h & 0xffffffffffff,
		allocator = allocator,
	)
}

// epub_now is the `dcterms:modified` value. EPUB 3 requires exactly
// "YYYY-MM-DDThh:mm:ssZ" — no milliseconds, no offset other than Z.
epub_now :: proc(allocator := context.allocator) -> string {
	t := time.now()
	y, mo, dd := time.date(t)
	hh, mi, ss := time.clock_from_time(t)
	return fmt.aprintf("%04d-%02d-%02dT%02d:%02d:%02dZ", y, int(mo), dd, hh, mi, ss, allocator = allocator)
}

// ---------------------------------------------------------------------------
// The parts
// ---------------------------------------------------------------------------

CONTAINER_XML ::
	`<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>
`

STYLE_CSS ::
	`html { font-size: 100%; }
body { margin: 0 5%; line-height: 1.5; text-align: left; }
h1 { font-size: 1.6em; margin: 1.6em 0 0.6em; line-height: 1.25; }
h2 { font-size: 1.3em; margin: 1.4em 0 0.5em; line-height: 1.3; }
h3 { font-size: 1.1em; margin: 1.2em 0 0.4em; }
p  { margin: 0 0 0.75em; text-indent: 0; }
p.cont { text-indent: 1.2em; margin-top: -0.75em; }
hr.page { border: 0; border-top: 1px solid #ccc; margin: 1.5em 20%; }
nav ol { list-style: none; padding-left: 0; }
nav li { margin: 0.35em 0; }
.lowconf { }
`

// chapter_xhtml renders one chapter. The chapter's own first heading becomes
// the document title, which is what a reader shows in its chapter list when it
// has not read the nav document.
chapter_xhtml :: proc(d: ^Doc, c: Chapter, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, `<?xml version="1.0" encoding="UTF-8"?>`)
	strings.write_byte(&b, '\n')
	strings.write_string(
		&b,
		`<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="`,
	)
	strings.write_string(&b, xml_escape(d.lang, context.temp_allocator))
	strings.write_string(&b, `" lang="`)
	strings.write_string(&b, xml_escape(d.lang, context.temp_allocator))
	strings.write_string(&b, "\">\n<head>\n  <title>")
	strings.write_string(&b, xml_escape(c.title, context.temp_allocator))
	strings.write_string(&b, "</title>\n  <meta charset=\"utf-8\"/>\n")
	strings.write_string(&b, "  <link rel=\"stylesheet\" type=\"text/css\" href=\"style.css\"/>\n")
	strings.write_string(&b, "</head>\n<body>\n")

	for i in c.from ..< min(c.to, len(d.blocks)) {
		blk := d.blocks[i]
		switch blk.kind {
		case .Heading:
			lvl := max(1, min(6, blk.level))
			fmt.sbprintf(&b, "  <h%d>%s</h%d>\n", lvl, xml_escape(blk.text, context.temp_allocator), lvl)
		case .Paragraph:
			fmt.sbprintf(&b, "  <p>%s</p>\n", xml_escape(blk.text, context.temp_allocator))
		case .Page_Break:
			// A page boundary in a reflowable book is not a page break, it is
			// a note that the source had one. `epub:type="pagebreak"` is the
			// standard way to say so without forcing a break.
			fmt.sbprintf(
				&b,
				"  <span epub:type=\"pagebreak\" role=\"doc-pagebreak\" id=\"pg%d\" aria-label=\"%d\"/>\n",
				blk.page,
				blk.page,
			)
		}
	}
	strings.write_string(&b, "</body>\n</html>\n")
	return strings.to_string(b)
}

nav_xhtml :: proc(d: ^Doc, chapters: []Chapter, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, `<?xml version="1.0" encoding="UTF-8"?>`)
	strings.write_byte(&b, '\n')
	strings.write_string(
		&b,
		`<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="`,
	)
	strings.write_string(&b, xml_escape(d.lang, context.temp_allocator))
	strings.write_string(&b, "\">\n<head>\n  <title>Contents</title>\n  <meta charset=\"utf-8\"/>\n")
	strings.write_string(&b, "  <link rel=\"stylesheet\" type=\"text/css\" href=\"style.css\"/>\n")
	strings.write_string(&b, "</head>\n<body>\n")
	strings.write_string(&b, "  <nav epub:type=\"toc\" id=\"toc\" role=\"doc-toc\">\n    <h1>Contents</h1>\n    <ol>\n")
	for c, i in chapters {
		fmt.sbprintf(
			&b,
			"      <li><a href=\"%s\">%s</a></li>\n",
			chapter_file(i, context.temp_allocator),
			xml_escape(c.title, context.temp_allocator),
		)
	}
	strings.write_string(&b, "    </ol>\n  </nav>\n")
	// A landmarks nav is optional but every reader looks for it, and without
	// one some of them synthesise a wrong "start reading" position.
	fmt.sbprintf(
		&b,
		"  <nav epub:type=\"landmarks\" hidden=\"hidden\">\n    <h2>Guide</h2>\n    <ol>\n      <li><a epub:type=\"bodymatter\" href=\"%s\">Start of text</a></li>\n    </ol>\n  </nav>\n",
		chapter_file(0, context.temp_allocator),
	)
	strings.write_string(&b, "</body>\n</html>\n")
	return strings.to_string(b)
}

chapter_file :: proc(i: int, allocator := context.allocator) -> string {
	return fmt.aprintf("ch%03d.xhtml", i + 1, allocator = allocator)
}

content_opf :: proc(d: ^Doc, chapters: []Chapter, uid: string, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, `<?xml version="1.0" encoding="UTF-8"?>`)
	strings.write_byte(&b, '\n')
	fmt.sbprintf(
		&b,
		"<package xmlns=\"http://www.idpf.org/2007/opf\" version=\"3.0\" unique-identifier=\"bookid\" xml:lang=\"%s\">\n",
		xml_escape(d.lang, context.temp_allocator),
	)
	strings.write_string(&b, "  <metadata xmlns:dc=\"http://purl.org/dc/elements/1.1/\">\n")
	fmt.sbprintf(&b, "    <dc:identifier id=\"bookid\">%s</dc:identifier>\n", xml_escape(uid, context.temp_allocator))
	fmt.sbprintf(&b, "    <dc:title>%s</dc:title>\n", xml_escape(d.title, context.temp_allocator))
	fmt.sbprintf(&b, "    <dc:language>%s</dc:language>\n", xml_escape(d.lang, context.temp_allocator))
	if d.author != "" {
		fmt.sbprintf(&b, "    <dc:creator>%s</dc:creator>\n", xml_escape(d.author, context.temp_allocator))
	}
	// Provenance, in the file itself. A converted scan should say it is one.
	fmt.sbprintf(
		&b,
		"    <dc:source>%s</dc:source>\n",
		xml_escape(base_name(d.source), context.temp_allocator),
	)
	fmt.sbprintf(
		&b,
		"    <meta property=\"dcterms:modified\">%s</meta>\n",
		epub_now(context.temp_allocator),
	)
	fmt.sbprintf(
		&b,
		"    <meta name=\"generator\" content=\"palmy ocr / %s\"/>\n",
		xml_escape(d.backend, context.temp_allocator),
	)
	strings.write_string(&b, "  </metadata>\n")

	strings.write_string(&b, "  <manifest>\n")
	strings.write_string(
		&b,
		"    <item id=\"nav\" href=\"nav.xhtml\" media-type=\"application/xhtml+xml\" properties=\"nav\"/>\n",
	)
	strings.write_string(&b, "    <item id=\"css\" href=\"style.css\" media-type=\"text/css\"/>\n")
	for _, i in chapters {
		fmt.sbprintf(
			&b,
			"    <item id=\"ch%03d\" href=\"%s\" media-type=\"application/xhtml+xml\"/>\n",
			i + 1,
			chapter_file(i, context.temp_allocator),
		)
	}
	strings.write_string(&b, "  </manifest>\n")

	strings.write_string(&b, "  <spine>\n")
	for _, i in chapters {
		fmt.sbprintf(&b, "    <itemref idref=\"ch%03d\"/>\n", i + 1)
	}
	strings.write_string(&b, "  </spine>\n")
	strings.write_string(&b, "</package>\n")
	return strings.to_string(b)
}

// ---------------------------------------------------------------------------
// The container
// ---------------------------------------------------------------------------

// doc_to_epub returns the whole archive. The caller owns the bytes.
doc_to_epub :: proc(d: ^Doc, allocator := context.allocator) -> []u8 {
	z: Zip
	zip_init(&z)
	// First, uncompressed, no extra field. Everything else depends on this
	// having happened before anything was written.
	zip_add_mimetype(&z)
	zip_add_string(&z, "META-INF/container.xml", CONTAINER_XML)

	chapters := doc_chapters(d, context.temp_allocator)
	uid := epub_uid(d, context.temp_allocator)

	zip_add_string(&z, "OEBPS/content.opf", content_opf(d, chapters, uid, context.temp_allocator))
	zip_add_string(&z, "OEBPS/nav.xhtml", nav_xhtml(d, chapters, context.temp_allocator))
	zip_add_string(&z, "OEBPS/style.css", STYLE_CSS)
	for c, i in chapters {
		zip_add_string(
			&z,
			fmt.tprintf("OEBPS/%s", chapter_file(i, context.temp_allocator)),
			chapter_xhtml(d, c, context.temp_allocator),
		)
	}
	whole := zip_finish(&z)
	out := make([]u8, len(whole), allocator)
	copy(out, whole)
	zip_destroy(&z)
	return out
}

// epub_xml_parts lists the archive members that must parse as XML, which is
// what the self-test hands to xmllint.
epub_xml_parts :: proc(members: []Zip_Member, allocator := context.allocator) -> []string {
	out := make([dynamic]string, allocator)
	for m in members {
		if strings.has_suffix(m.name, ".xml") ||
		   strings.has_suffix(m.name, ".opf") ||
		   strings.has_suffix(m.name, ".xhtml") {
			append(&out, m.name)
		}
	}
	return out[:]
}
