package main

// Two PDFs, written by hand, for the one assertion that needs both:
//
//   **a PDF that already has a text layer must not be OCRed.**
//
// Proving that needs a PDF with a text layer and a PDF without one, and they
// have to be generated rather than found, because nothing in a committed
// fixture may be a document of the user's. There is also no PDF writer on the
// machine that produces exactly these two shapes on demand, so they are
// assembled here — which is a few hundred lines and removes a dependency.
//
// A PDF is seven or eight objects and a cross-reference table. The table is
// the part that has to be right: every entry is the **byte offset** of its
// object from the start of the file, written as exactly ten digits, and
// `startxref` is the offset of the table itself. Readers seek by those
// numbers, so an offset that is one byte out is a file that opens nowhere.
//
// The text PDF uses Helvetica, one of the fourteen fonts every reader is
// required to have built in, so nothing has to be embedded. The scanned PDF
// carries the page as a 1-bit image: the corpus is black text on white, so a
// threshold loses nothing a recogniser would have used, and it turns 10 MB of
// RGB into 440 kB.

import "core:fmt"
import "core:os"
import "core:strings"
import p "palmy:."

@(private = "file")
Pdf :: struct {
	buf:     [dynamic]u8,
	offsets: [dynamic]int, // byte offset of object N, indexed from 1
}

@(private = "file")
pdf_begin :: proc(pb: ^Pdf) {
	pb.buf = make([dynamic]u8)
	pb.offsets = make([dynamic]int)
	append(&pb.offsets, 0) // object 0 is the free-list head and has no offset
	pdf_raw(pb, "%PDF-1.4\n")
	// A comment of high bytes right after the header is what tells a transfer
	// program the file is binary. Every real writer emits it.
	append(&pb.buf, '%', 0xe2, 0xe3, 0xcf, 0xd3, '\n')
}

@(private = "file")
pdf_free :: proc(pb: ^Pdf) {
	delete(pb.buf)
	delete(pb.offsets)
}

@(private = "file")
pdf_raw :: proc(pb: ^Pdf, s: string) {
	append(&pb.buf, ..transmute([]u8)s)
}

// pdf_obj opens object N at the current offset and records where it started.
@(private = "file")
pdf_obj :: proc(pb: ^Pdf, n: int, body: string) {
	for len(pb.offsets) <= n {
		append(&pb.offsets, 0)
	}
	pb.offsets[n] = len(pb.buf)
	pdf_raw(pb, fmt.tprintf("%d 0 obj\n", n))
	pdf_raw(pb, body)
	pdf_raw(pb, "\nendobj\n")
}

// pdf_stream writes a stream object whose /Length is the real byte count.
@(private = "file")
pdf_stream :: proc(pb: ^Pdf, n: int, dict: string, data: []u8) {
	for len(pb.offsets) <= n {
		append(&pb.offsets, 0)
	}
	pb.offsets[n] = len(pb.buf)
	pdf_raw(pb, fmt.tprintf("%d 0 obj\n<< %s /Length %d >>\nstream\n", n, dict, len(data)))
	append(&pb.buf, ..data)
	pdf_raw(pb, "\nendstream\nendobj\n")
}

// pdf_finish writes the cross-reference table and the trailer.
@(private = "file")
pdf_finish :: proc(pb: ^Pdf, root: int) -> []u8 {
	xref := len(pb.buf)
	n := len(pb.offsets)
	pdf_raw(pb, fmt.tprintf("xref\n0 %d\n", n))
	pdf_raw(pb, "0000000000 65535 f \n")
	for i in 1 ..< n {
		// Exactly ten digits, exactly five, one space, one letter, one space,
		// then a two-byte end of line: a 20-byte entry, and readers index
		// into the table by multiplying.
		pdf_raw(pb, fmt.tprintf("%010d 00000 n \n", pb.offsets[i]))
	}
	pdf_raw(pb, fmt.tprintf("trailer\n<< /Size %d /Root %d 0 R >>\nstartxref\n%d\n%%%%EOF\n", n, root, xref))
	return pb.buf[:]
}

// pdf_text_escape handles the three characters that end a PDF string early.
@(private = "file")
pdf_text_escape :: proc(s: string, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	for c in transmute([]u8)s {
		switch c {
		case '(', ')', '\\':
			strings.write_byte(&b, '\\')
			strings.write_byte(&b, c)
		case:
			if c < 0x20 || c > 0x7e {
				continue // WinAnsi only; the fixture text is ASCII by design
			}
			strings.write_byte(&b, c)
		}
	}
	return strings.to_string(b)
}

// ---------------------------------------------------------------------------
// A PDF with a text layer
// ---------------------------------------------------------------------------

// write_text_pdf lays `lines` down the page in 12pt Helvetica. The result is
// a born-digital PDF: `pdftotext` reads it exactly, and OCRing it would be
// strictly worse.
write_text_pdf :: proc(path: string, lines: []string) -> string {
	pb: Pdf
	pdf_begin(&pb)
	defer pdf_free(&pb)

	content := strings.builder_make(context.temp_allocator)
	strings.write_string(&content, "BT\n/F1 12 Tf\n14 TL\n72 720 Td\n")
	for l in lines {
		fmt.sbprintf(&content, "(%s) Tj T*\n", pdf_text_escape(l, context.temp_allocator))
	}
	strings.write_string(&content, "ET\n")

	pdf_obj(&pb, 1, "<< /Type /Catalog /Pages 2 0 R >>")
	pdf_obj(&pb, 2, "<< /Type /Pages /Kids [3 0 R] /Count 1 >>")
	pdf_obj(
		&pb,
		3,
		"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>",
	)
	pdf_stream(&pb, 4, "", transmute([]u8)strings.to_string(content))
	pdf_obj(&pb, 5, "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>")

	data := pdf_finish(&pb, 1)
	if err := os.write_entire_file(path, data); err != nil {
		return fmt.aprintf("cannot write %s: %v", path, err)
	}
	return ""
}

// ---------------------------------------------------------------------------
// A scanned PDF: one page, one image, no text at all
// ---------------------------------------------------------------------------

// write_scan_pdf wraps one PNG as a page. It is `write_scan_pdf_multi` with a
// single page, kept because that is what the text-layer test wants.
write_scan_pdf :: proc(path, png: string, dpi: int) -> string {
	return write_scan_pdf_multi(path, {png}, dpi)
}

// write_scan_pdf_multi builds a PDF whose every page is one image and nothing
// else — which is exactly what a flatbed scanner produces and what this
// program exists to convert. `pdftotext` finds nothing in it, so it is also
// the other half of the text-layer test.
//
// Object numbering: 1 catalog, 2 pages, then three objects per page (the page,
// its content stream, its image), so page N's objects are 3N, 3N+1, 3N+2.
// Getting that arithmetic wrong produces a file whose cross-reference table
// points at the wrong objects, which readers report as "damaged" with no hint
// as to which number was off.
write_scan_pdf_multi :: proc(path: string, pngs: []string, dpi: int) -> string {
	if len(pngs) == 0 {
		return "no pages"
	}
	pb: Pdf
	pdf_begin(&pb)
	defer pdf_free(&pb)

	kids := strings.builder_make(context.temp_allocator)
	for _, i in pngs {
		if i > 0 {
			strings.write_byte(&kids, ' ')
		}
		fmt.sbprintf(&kids, "%d 0 R", 3 + i * 3)
	}
	pdf_obj(&pb, 1, "<< /Type /Catalog /Pages 2 0 R >>")
	pdf_obj(
		&pb,
		2,
		fmt.tprintf("<< /Type /Pages /Kids [%s] /Count %d >>", strings.to_string(kids), len(pngs)),
	)

	for png, i in pngs {
		img, ok := p.load_image(png)
		if !ok {
			return fmt.aprintf("cannot decode %s", png)
		}
		defer p.image_destroy(&img)

		w := img.w
		h := img.h
		stride := (w + 7) / 8
		bits := make([]u8, stride * h, context.temp_allocator)
		for j in 0 ..< len(bits) {
			bits[j] = 0xff // white
		}
		for y in 0 ..< h {
			row := bits[y * stride:]
			for x in 0 ..< w {
				px := img.px[y * w + x]
				// Luma from the straight 0xAARRGGBB the decoder produced.
				r := int((px >> 16) & 0xff)
				g := int((px >> 8) & 0xff)
				b := int(px & 0xff)
				lum := (r * 299 + g * 587 + b * 114) / 1000
				if lum < 128 {
					row[x / 8] &= ~(u8(0x80) >> u8(x % 8)) // 0 is black
				}
			}
		}

		pw := f32(w) * 72 / f32(dpi)
		ph := f32(h) * 72 / f32(dpi)
		page_obj := 3 + i * 3
		content_obj := page_obj + 1
		image_obj := page_obj + 2

		pdf_obj(
			&pb,
			page_obj,
			fmt.tprintf(
				"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 %.2f %.2f] /Resources << /XObject << /Im1 %d 0 R >> >> /Contents %d 0 R >>",
				pw,
				ph,
				image_obj,
				content_obj,
			),
		)
		pdf_stream(
			&pb,
			content_obj,
			"",
			transmute([]u8)fmt.tprintf("q\n%.2f 0 0 %.2f 0 0 cm\n/Im1 Do\nQ\n", pw, ph),
		)
		pdf_stream(
			&pb,
			image_obj,
			fmt.tprintf(
				"/Type /XObject /Subtype /Image /Width %d /Height %d /ColorSpace /DeviceGray /BitsPerComponent 1",
				w,
				h,
			),
			bits,
		)
	}

	data := pdf_finish(&pb, 1)
	if err := os.write_entire_file(path, data); err != nil {
		return fmt.aprintf("cannot write %s: %v", path, err)
	}
	return ""
}
