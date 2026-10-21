// PDF — one page per slide, landscape, as real vector graphics.
//
// THE CHOICE. There are two honest ways to turn a deck into a PDF. The easy
// one is to embed the 1920x1080 PNGs this program already renders, one per
// page; that is a picture of a deck — nothing selectable, nothing searchable,
// and soft the moment anyone prints it or projects it larger than 1080p. The
// other is to write the slides as actual PDF content: paths for the shapes,
// text operators for the text. That is what this does. Every word is
// selectable and searchable, every edge prints at the printer's resolution,
// and the text of a six-slide deck with no pictures comes to about 90 KB.
// `pdftotext` on the output returns the deck's words, and the test suite
// asserts exactly that rather than taking it on trust.
//
// What that does NOT buy is small *pictures*. Odin's core library has a
// deflate decompressor and no compressor, so an embedded photograph goes in as
// RGB bytes through PDF's RunLengthDecode filter, which is a dozen lines and
// compresses a flat chart well and a photograph barely at all. Pictures are
// therefore box-filtered down to PDF_IMAGE_MAX on the long side first. The
// eight-slide fixture, which has two full-bleed generated pictures, comes to
// about 1.4 MB; the same deck as embedded 1080p page images would be far
// larger and would lose the text as well.
//
// The one thing a vector PDF cannot do for free is the typeface. Embedding a
// subset of Geist would mean writing a TrueType subsetter — a real piece of
// work, and one that attaches a font licence to every exported file. Instead
// the text is set in the base-14 faces every PDF reader is required to have
// (Helvetica, Helvetica-Bold, Courier, Courier-Bold), which are never embedded
// at all. Those have different metrics from Geist, so a line centred by this
// program would drift when a reader set it in Helvetica. The fix is the
// horizontal-scaling operator: each line is emitted with `Tz` set so that the
// Helvetica run is exactly as wide as the Geist run this program measured. The
// line breaks come from this program's own wrapping, so the PDF page and the
// PNG export break in the same places and every line starts and ends on the
// same coordinate. What differs is the shape of the letters, by a percent or
// two of width.
//
// Text extracts correctly because each font carries a /ToUnicode CMap built
// from the WinAnsiEncoding table in pdf_fonts.odin. Without one, a reader has
// to guess, and the usual guess is garbage.
//
// The coordinate system is set up once per page and then forgotten:
//
//     0.75 0 0 -0.75 0 540 cm
//
// A page is 960 x 540 points (13 1/3 x 7 1/2 inches, the same 16:9 as the
// .pptx), this program's slide space is 1280 x 720, and 960/1280 == 0.75. The
// negative vertical scale flips PDF's bottom-left origin to this program's
// top-left one, so everything below is written in plain slide coordinates.
// Text is the one exception: a glyph drawn in a flipped space would be upside
// down, so each run sets `1 0 0 -1 x y Tm`, which flips it back.
package main

import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"
import p "palmy:."

PDF_PT_PER_UNIT :: f32(0.75)
PDF_PAGE_W :: SLIDE_W * PDF_PT_PER_UNIT // 960pt
PDF_PAGE_H :: SLIDE_H * PDF_PT_PER_UNIT // 540pt

// The base-14 faces, in the order their PDF objects are written. The oblique
// four are what an italic run is set in; their advance widths are the upright
// faces' (Adobe's AFMs for Helvetica-Oblique and Helvetica-BoldOblique carry
// the same widths as their roman), so the `Tz` correction needs no new table.
PDF_F_SANS :: 0
PDF_F_SANS_BOLD :: 1
PDF_F_MONO :: 2
PDF_F_MONO_BOLD :: 3
PDF_F_OBLIQUE :: 4 // added to any of the four above
PDF_FONTS :: 8

PDF_FONT_NAMES := [PDF_FONTS]string {
	"Helvetica",
	"Helvetica-Bold",
	"Courier",
	"Courier-Bold",
	"Helvetica-Oblique",
	"Helvetica-BoldOblique",
	"Courier-Oblique",
	"Courier-BoldOblique",
}

// ---------------------------------------------------------------------------
// Encoding
// ---------------------------------------------------------------------------

// winansi maps a rune onto the single byte WinAnsiEncoding spells it with.
// Codes 0x20..0x7E and 0xA0..0xFF are Latin-1; the 0x80..0x9F block is where
// Windows put the typographic punctuation that this deck actually uses — the
// bullet, the en and em dashes, the curly quotes and the middle dot. Anything
// outside the encoding becomes a question mark, which is visible rather than
// silently missing.
winansi :: proc(r: rune) -> u8 {
	switch {
	case r >= 0x20 && r < 0x7f:
		return u8(r)
	case r >= 0xa0 && r <= 0xff:
		return u8(r)
	}
	switch r {
	case 0x20ac:
		return 0x80
	case 0x201a:
		return 0x82
	case 0x0192:
		return 0x83
	case 0x201e:
		return 0x84
	case 0x2026:
		return 0x85
	case 0x2020:
		return 0x86
	case 0x2021:
		return 0x87
	case 0x02c6:
		return 0x88
	case 0x2030:
		return 0x89
	case 0x0160:
		return 0x8a
	case 0x2039:
		return 0x8b
	case 0x0152:
		return 0x8c
	case 0x017d:
		return 0x8e
	case 0x2018:
		return 0x91
	case 0x2019:
		return 0x92
	case 0x201c:
		return 0x93
	case 0x201d:
		return 0x94
	case 0x2022:
		return 0x95
	case 0x2013:
		return 0x96
	case 0x2014:
		return 0x97
	case 0x02dc:
		return 0x98
	case 0x2122:
		return 0x99
	case 0x0161:
		return 0x9a
	case 0x203a:
		return 0x9b
	case 0x0153:
		return 0x9c
	case 0x017e:
		return 0x9e
	case 0x0178:
		return 0x9f
	}
	return '?'
}

// pdf_text_bytes converts a UTF-8 string to WinAnsi bytes and escapes the
// three characters a PDF literal string reserves.
pdf_text_bytes :: proc(s: string, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	for r in s {
		c := winansi(r)
		switch c {
		case '(', ')', '\\':
			strings.write_byte(&b, '\\')
		}
		strings.write_byte(&b, c)
	}
	return strings.to_string(b)
}

// pdf_run_width is how wide the chosen base-14 face would set this string, in
// 1/1000 em. It is only ever used as the denominator of the `Tz` correction,
// so a width that is slightly off moves the scaling slightly, not the text.
pdf_run_width :: proc(s: string, font: int) -> f32 {
	total := 0
	for r in s {
		c := winansi(r)
		w := 0
		switch font % PDF_F_OBLIQUE {
		case PDF_F_MONO, PDF_F_MONO_BOLD:
			w = 600
		case PDF_F_SANS_BOLD:
			w = int(pdf_bold_width(c))
		case:
			w = int(pdf_regular_width(c))
		}
		if w == 0 {
			w = 500 // an unassigned code still advances by something
		}
		total += w
	}
	return f32(total)
}

// ---------------------------------------------------------------------------
// The writer
// ---------------------------------------------------------------------------

Pdf :: struct {
	b:       strings.Builder,
	offsets: [dynamic]int, // byte offset of object n, indexed from 1
}

@(private = "file")
pdf_make :: proc(allocator := context.temp_allocator) -> Pdf {
	return {b = strings.builder_make(allocator), offsets = make([dynamic]int, allocator)}
}

// pdf_obj records where object `n` starts and opens it. Objects are written in
// a pre-agreed order, so the number is passed in rather than allocated here.
@(private = "file")
pdf_obj :: proc(f: ^Pdf, n: int) {
	for len(f.offsets) <= n {
		append(&f.offsets, 0)
	}
	f.offsets[n] = strings.builder_len(f.b)
	fmt.sbprintf(&f.b, "%d 0 obj\n", n)
}

@(private = "file")
pdf_endobj :: proc(f: ^Pdf) {
	strings.write_string(&f.b, "\nendobj\n")
}

// pdf_stream writes a stream object with its /Length filled in, which has to
// be exact or every reader past the first byte is lost.
@(private = "file")
pdf_stream :: proc(f: ^Pdf, n: int, dict: string, data: []u8) {
	pdf_obj(f, n)
	fmt.sbprintf(&f.b, "<< %s /Length %d >>\nstream\n", dict, len(data))
	strings.write_bytes(&f.b, data)
	strings.write_string(&f.b, "\nendstream")
	pdf_endobj(f)
}

// ---------------------------------------------------------------------------
// Paths
//
// Everything below writes into a content stream in slide coordinates. `k` is
// the circle constant for a cubic Bezier: four of them approximate a circle to
// within a thousandth of its radius, which is far below a printer's dot.
// ---------------------------------------------------------------------------

@(private = "file")
KAPPA :: f32(0.5522847498)

@(private = "file")
num :: proc(x: f32) -> string {
	// Three decimals is a twentieth of a point at this scale: more is noise,
	// and the file is smaller without it.
	s := fmt.tprintf("%.3f", x)
	// Trim the trailing zeros a PDF does not need.
	if strings.contains(s, ".") {
		n := len(s)
		for n > 0 && s[n - 1] == '0' {
			n -= 1
		}
		if n > 0 && s[n - 1] == '.' {
			n -= 1
		}
		s = s[:n]
	}
	return s == "-0" ? "0" : s
}

@(private = "file")
op :: proc(b: ^strings.Builder, args: ..f32) {
	for a in args {
		strings.write_string(b, num(a))
		strings.write_byte(b, ' ')
	}
}

@(private = "file")
path_rect :: proc(b: ^strings.Builder, x, y, w, h, r: f32) {
	rr := min(r, min(abs(w), abs(h)) / 2)
	if rr <= 0.01 {
		op(b, x, y, w, h)
		strings.write_string(b, "re\n")
		return
	}
	c := rr * KAPPA
	x1, y1 := x + w, y + h
	op(b, x + rr, y)
	strings.write_string(b, "m\n")
	op(b, x1 - rr, y)
	strings.write_string(b, "l\n")
	op(b, x1 - rr + c, y, x1, y + rr - c, x1, y + rr)
	strings.write_string(b, "c\n")
	op(b, x1, y1 - rr)
	strings.write_string(b, "l\n")
	op(b, x1, y1 - rr + c, x1 - rr + c, y1, x1 - rr, y1)
	strings.write_string(b, "c\n")
	op(b, x + rr, y1)
	strings.write_string(b, "l\n")
	op(b, x + rr - c, y1, x, y1 - rr + c, x, y1 - rr)
	strings.write_string(b, "c\n")
	op(b, x, y + rr)
	strings.write_string(b, "l\n")
	op(b, x, y + rr - c, x + rr - c, y, x + rr, y)
	strings.write_string(b, "c\nh\n")
}

@(private = "file")
path_ellipse :: proc(b: ^strings.Builder, x, y, w, h: f32) {
	rx, ry := w / 2, h / 2
	cx, cy := x + rx, y + ry
	ox, oy := rx * KAPPA, ry * KAPPA
	op(b, cx + rx, cy)
	strings.write_string(b, "m\n")
	op(b, cx + rx, cy + oy, cx + ox, cy + ry, cx, cy + ry)
	strings.write_string(b, "c\n")
	op(b, cx - ox, cy + ry, cx - rx, cy + oy, cx - rx, cy)
	strings.write_string(b, "c\n")
	op(b, cx - rx, cy - oy, cx - ox, cy - ry, cx, cy - ry)
	strings.write_string(b, "c\n")
	op(b, cx + ox, cy - ry, cx + rx, cy - oy, cx + rx, cy)
	strings.write_string(b, "c\nh\n")
}

// rot_push wraps the following operators in a rotation about (cx, cy). The
// page's vertical flip means the standard rotation matrix turns clockwise on
// screen, which is this program's convention for a rotated element.
@(private = "file")
rot_push :: proc(b: ^strings.Builder, cx, cy, deg: f32) -> bool {
	if deg == 0 {
		return false
	}
	t := math.to_radians(deg)
	co, si := math.cos(t), math.sin(t)
	strings.write_string(b, "q ")
	op(b, co, si, -si, co, cx - cx * co + cy * si, cy - cx * si - cy * co)
	strings.write_string(b, "cm\n")
	return true
}

@(private = "file")
set_rgb :: proc(b: ^strings.Builder, c: p.Color, stroke: bool) {
	op(b, f32(c.r) / 255, f32(c.g) / 255, f32(c.b) / 255)
	strings.write_string(b, stroke ? "RG\n" : "rg\n")
}

// ---------------------------------------------------------------------------
// Transparency
//
// PDF carries constant alpha in a graphics state dictionary, not inline, so
// the distinct alphas a page uses are collected and named /GA0, /GA1 and so on.
// ---------------------------------------------------------------------------

@(private = "file")
Alphas :: struct {
	vals: [dynamic]f32,
}

@(private = "file")
alpha_name :: proc(al: ^Alphas, a_in: f32) -> string {
	a := clamp(a_in, 0, 1)
	// Quantise, or a page of fades produces a hundred near-identical states.
	q := f32(int(a * 1000 + 0.5)) / 1000
	for v, i in al.vals {
		if v == q {
			return fmt.tprintf("/GA%d", i)
		}
	}
	append(&al.vals, q)
	return fmt.tprintf("/GA%d", len(al.vals) - 1)
}

@(private = "file")
set_alpha :: proc(b: ^strings.Builder, al: ^Alphas, a: f32) {
	fmt.sbprintf(b, "%s gs\n", alpha_name(al, a))
}

// ---------------------------------------------------------------------------
// Images
// ---------------------------------------------------------------------------

@(private = "file")
Pdf_Image :: struct {
	src:  string,
	w, h: int,
	rgb:  []u8,
	obj:  int,
}

// PDF_IMAGE_MAX bounds an embedded picture's long side. A slide is 1280 units
// wide and prints at well under 200 dpi at any sane size, so a picture larger
// than this is paying for pixels nobody will see — and these are uncompressed
// RGB bytes, so the pixels cost three bytes each before run-length coding.
PDF_IMAGE_MAX :: 800

// pdf_image_rgb decodes a picture and box-filters it down to the embedding
// size. Box filtering rather than point sampling, because a downscaled chart
// that aliases is worse than no chart.
@(private = "file")
pdf_image_rgb :: proc(img: p.Image) -> (w, h: int, rgb: []u8) {
	long := max(img.w, img.h)
	scale := 1
	if long > PDF_IMAGE_MAX {
		scale = (long + PDF_IMAGE_MAX - 1) / PDF_IMAGE_MAX
	}
	w = max(img.w / scale, 1)
	h = max(img.h / scale, 1)
	rgb = make([]u8, w * h * 3, context.temp_allocator)
	for y in 0 ..< h {
		for x in 0 ..< w {
			r, g, bl, n := 0, 0, 0, 0
			for sy in y * scale ..< min((y + 1) * scale, img.h) {
				for sx in x * scale ..< min((x + 1) * scale, img.w) {
					v := img.px[sy * img.w + sx]
					r += int(u8(v >> 16))
					g += int(u8(v >> 8))
					bl += int(u8(v))
					n += 1
				}
			}
			if n == 0 {
				n = 1
			}
			o := (y * w + x) * 3
			rgb[o + 0] = u8(r / n)
			rgb[o + 1] = u8(g / n)
			rgb[o + 2] = u8(bl / n)
		}
	}
	return
}

// run_length encodes bytes the way PDF's /RunLengthDecode filter reads them:
// a length byte 0..127 means "the next length+1 bytes are literal", 129..255
// means "repeat the next byte 257-length times", and 128 ends the data. It is
// twenty lines and it halves a generated picture, which is the whole reason a
// vector PDF of this deck is a hundred kilobytes rather than four megabytes.
run_length :: proc(src: []u8, allocator := context.temp_allocator) -> []u8 {
	out := make([dynamic]u8, allocator)
	i := 0
	for i < len(src) {
		// How long is the run starting here?
		run := 1
		for i + run < len(src) && src[i + run] == src[i] && run < 128 {
			run += 1
		}
		if run >= 2 {
			append(&out, u8(257 - run), src[i])
			i += run
			continue
		}
		// Otherwise gather literals until a run of three starts.
		start := i
		for i < len(src) && i - start < 128 {
			if i + 2 < len(src) && src[i] == src[i + 1] && src[i] == src[i + 2] {
				break
			}
			i += 1
		}
		append(&out, u8(i - start - 1))
		append(&out, ..src[start:i])
	}
	append(&out, 128) // end of data
	return out[:]
}

// ---------------------------------------------------------------------------
// Drawing one slide
// ---------------------------------------------------------------------------

@(private = "file")
Page_Ctx :: struct {
	b:      ^strings.Builder,
	al:     ^Alphas,
	fonts:  ^p.Fonts,
	imgs:   ^Img_Cache,
	images: ^[dynamic]Pdf_Image,
	used:   ^[dynamic]int, // indices into `images` this page draws
	th:     ^Theme,
}

@(private = "file")
pdf_fill_shape :: proc(pc: ^Page_Ctx, e: ^Element, c: p.Color, a: f32, ellipse: bool) {
	b := pc.b
	popped := rot_push(b, e.x + e.w / 2, e.y + e.h / 2, e.rotation)
	set_alpha(b, pc.al, a * f32(c.a) / 255)
	set_rgb(b, c, false)
	if ellipse {
		path_ellipse(b, e.x, e.y, e.w, e.h)
	} else {
		path_rect(b, e.x, e.y, e.w, e.h, e.radius)
	}
	strings.write_string(b, "f\n")
	if popped {
		strings.write_string(b, "Q\n")
	}
}

@(private = "file")
pdf_stroke_shape :: proc(pc: ^Page_Ctx, e: ^Element, c: p.Color, a: f32, ellipse: bool) {
	b := pc.b
	popped := rot_push(b, e.x + e.w / 2, e.y + e.h / 2, e.rotation)
	set_alpha(b, pc.al, a * f32(c.a) / 255)
	set_rgb(b, c, true)
	op(b, e.stroke_w)
	strings.write_string(b, "w\n")
	if ellipse {
		path_ellipse(b, e.x, e.y, e.w, e.h)
	} else {
		path_rect(b, e.x, e.y, e.w, e.h, e.radius)
	}
	strings.write_string(b, "S\n")
	if popped {
		strings.write_string(b, "Q\n")
	}
}

// pdf_font_for maps this program's family and weight onto the base-14 faces.
// Helvetica has no medium or semibold, so the four weights collapse onto two:
// anything at semibold or above sets bold.
pdf_font_for :: proc(fam: p.Font_Family, wt: p.Font_Weight, sl := p.Font_Slant.Upright) -> int {
	bold := wt == .Bold || wt == .Semibold
	f := bold ? PDF_F_SANS_BOLD : PDF_F_SANS
	if fam == .Mono {
		f = bold ? PDF_F_MONO_BOLD : PDF_F_MONO
	}
	if sl == .Italic {
		f += PDF_F_OBLIQUE
	}
	return f
}

// pdf_tz is the horizontal scaling, in percent, that makes a base-14 run as
// wide as the run this program measured. It is clamped: a line of one wide
// glyph, or an empty line, must not produce a scale that distorts the page.
pdf_tz :: proc(want_w, size: f32, s: string, font: int) -> f32 {
	if want_w <= 0 || size <= 0 || s == "" {
		return 100
	}
	natural := pdf_run_width(s, font) * size / 1000
	if natural <= 0.01 {
		return 100
	}
	return clamp(want_w / natural * 100, 25, 400)
}

@(private = "file")
pdf_text_element :: proc(pc: ^Page_Ctx, e: ^Element) {
	if strings.trim_space(e.text) == "" {
		return
	}
	b := pc.b
	th := pc.th
	spec := TYPE_SCALE[e.style]
	col := paint(th, e.color)
	if e.color == SLOT_NONE {
		col = spec.muted ? argb(th.muted) : argb(th.fg)
	}
	alpha := clamp(e.opacity, 0, 1)

	tl := text_layout(pc.fonts, {e.x, e.y, e.w, e.h}, 1, e, theme_family(th))

	for l in tl.lines {
		x := line_x(&tl, l, e)
		y := l.base
		if l.bullet {
			// The renderer draws a dot, not a glyph, so the PDF draws a dot.
			r := tl.size * 0.16
			acc := paint(th, SLOT_ACCENT)
			set_alpha(b, pc.al, alpha * f32(acc.a) / 255)
			set_rgb(b, acc, false)
			path_ellipse(b, tl.box.x + r * 0.6, y - tl.size * 0.3 - r, r * 2, r * 2)
			strings.write_string(b, "f\n")
		}
		// One text object per segment: a box without runs is one segment per
		// line, exactly as before runs existed. Each segment carries its own
		// face, size and colour, and its own `Tz`, so a bold word set in
		// Helvetica-Bold is stretched to the width Geist Bold gave it and the
		// next segment starts where this program's layout says it does.
		sx := x
		for sg in text_segments(e, l.start, l.end) {
			f := span_font(&tl.m, sg.s)
			run := e.text[sg.start:sg.end]
			w := p.text_width(pc.fonts, run, f.size, tl.fam, f.wt, f.tracking, f.sl)
			if strings.trim_space(run) != "" {
				font := pdf_font_for(tl.fam, f.wt, f.sl)
				c := col
				if sg.s.color != SLOT_NONE {
					c = paint(th, sg.s.color)
				}
				set_alpha(b, pc.al, alpha * f32(c.a) / 255)
				set_rgb(b, c, false)
				fmt.sbprintf(b, "BT /F%d ", font + 1)
				op(b, f.size)
				strings.write_string(b, "Tf ")
				op(b, pdf_tz(w, f.size, run, font))
				strings.write_string(b, "Tz 1 0 0 -1 ")
				op(b, sx, y)
				fmt.sbprintf(b, "Tm (%s) Tj ET\n", pdf_text_bytes(run))
			}
			sx += w
		}
	}
}

@(private = "file")
pdf_image_element :: proc(pc: ^Page_Ctx, e: ^Element) {
	img, ok := img_get(pc.imgs, e.src)
	if !ok || img.w <= 0 {
		// The editor draws a missing picture as a framed placeholder; so does
		// the PDF, so a deck moved between machines says what it is looking for.
		ph := e^
		ph.fill = SLOT_SURFACE
		pdf_fill_shape(pc, &ph, paint(pc.th, SLOT_SURFACE), clamp(e.opacity, 0, 1), false)
		ph.stroke_w = max(ph.stroke_w, 2)
		pdf_stroke_shape(pc, &ph, paint(pc.th, SLOT_MUTED), 0.6 * clamp(e.opacity, 0, 1), false)
		return
	}

	// One XObject per distinct source, however many slides use it.
	idx := -1
	for im, i in pc.images {
		if im.src == e.src {
			idx = i
			break
		}
	}
	if idx < 0 {
		w, h, rgb := pdf_image_rgb(img)
		append(pc.images, Pdf_Image{src = e.src, w = w, h = h, rgb = rgb})
		idx = len(pc.images) - 1
	}
	seen := false
	for u in pc.used {
		if u == idx {
			seen = true
			break
		}
	}
	if !seen {
		append(pc.used, idx)
	}

	b := pc.b
	popped := rot_push(b, e.x + e.w / 2, e.y + e.h / 2, e.rotation)
	strings.write_string(b, "q\n")
	set_alpha(b, pc.al, clamp(e.opacity, 0, 1))
	// The rounded box is the clip, so the corners are rounded exactly as the
	// editor rounds them.
	path_rect(b, e.x, e.y, e.w, e.h, e.radius)
	strings.write_string(b, "W n\n")
	// Cover: the shorter axis fills the box, the longer one overflows the clip.
	s := max(e.w / f32(img.w), e.h / f32(img.h))
	dw := f32(img.w) * s
	dh := f32(img.h) * s
	dx := e.x + (e.w - dw) / 2
	dy := e.y + (e.h - dh) / 2
	// The negative height un-flips the image: PDF puts an image's first row at
	// the *top* of the unit square, and this page's vertical axis is reversed.
	op(b, dw, 0, 0, -dh, dx, dy + dh)
	fmt.sbprintf(b, "cm /Im%d Do\nQ\n", idx)
	if popped {
		strings.write_string(b, "Q\n")
	}
}

@(private = "file")
pdf_line_element :: proc(pc: ^Page_Ctx, e: ^Element) {
	b := pc.b
	th := pc.th
	col := has_paint(e.stroke) ? paint(th, e.stroke) : paint(th, SLOT_FG)
	alpha := clamp(e.opacity, 0, 1)

	cx := e.x + e.w / 2
	cy := e.y + e.h / 2
	co := math.cos(math.to_radians(e.rotation))
	si := math.sin(math.to_radians(e.rotation))
	hx, hy := e.w / 2, e.h / 2
	ax := cx + (-hx * co - -hy * si)
	ay := cy + (-hx * si + -hy * co)
	bx := cx + (hx * co - hy * si)
	by := cy + (hx * si + hy * co)

	set_alpha(b, pc.al, alpha * f32(col.a) / 255)
	set_rgb(b, col, true)
	op(b, max(e.stroke_w, 1))
	strings.write_string(b, "w 1 J\n")
	op(b, ax, ay)
	strings.write_string(b, "m\n")
	op(b, bx, by)
	strings.write_string(b, "l\nS\n")

	if e.kind == .Arrow {
		size := max(e.head, 12)
		dx, dy := bx - ax, by - ay
		l := math.sqrt(dx * dx + dy * dy)
		if l < 0.01 {
			return
		}
		ux, uy := dx / l, dy / l
		tx, ty := bx - ux * size, by - uy * size
		w := size * 0.42
		set_rgb(b, col, false)
		op(b, bx, by)
		strings.write_string(b, "m\n")
		op(b, tx - uy * w, ty + ux * w)
		strings.write_string(b, "l\n")
		op(b, tx + uy * w, ty - ux * w)
		strings.write_string(b, "l\nh f\n")
	}
}

// pdf_slide writes one slide's content stream, in slide coordinates.
@(private = "file")
pdf_slide :: proc(pc: ^Page_Ctx, d: ^Deck, si: int, gradient: bool) {
	b := pc.b
	s := &d.slides[si]
	th := pc.th

	// Into slide coordinates, and stay there.
	fmt.sbprintf(b, "%s 0 0 %s 0 %s cm\n", num(PDF_PT_PER_UNIT), num(-PDF_PT_PER_UNIT), num(PDF_PAGE_H))

	// Background.
	set_alpha(b, pc.al, 1)
	if gradient {
		strings.write_string(b, "q\n")
		op(b, 0, 0, SLIDE_W, SLIDE_H)
		strings.write_string(b, "re W n\n/Sh0 sh\nQ\n")
	} else {
		set_rgb(b, argb(th.bg), false)
		op(b, 0, 0, SLIDE_W, SLIDE_H)
		strings.write_string(b, "re f\n")
	}

	// The master decoration, mirroring draw_master.
	accent := argb(th.accent)
	accent2 := argb(th.accent2)
	oval :: proc(pc: ^Page_Ctx, x, y, w, h: f32, c: p.Color, a: f32) {
		set_alpha(pc.b, pc.al, a)
		set_rgb(pc.b, c, false)
		path_ellipse(pc.b, x, y, w, h)
		strings.write_string(pc.b, "f\n")
	}
	bar :: proc(pc: ^Page_Ctx, x, y, w, h: f32, c: p.Color, a: f32) {
		set_alpha(pc.b, pc.al, a)
		set_rgb(pc.b, c, false)
		op(pc.b, x, y, w, h)
		strings.write_string(pc.b, "re f\n")
	}
	layout := d.no_decor ? Layout.Blank : s.layout
	switch layout {
	case .Title:
		oval(pc, 820, -220, 720, 720, accent, 0.13)
		oval(pc, -180, 420, 620, 620, accent2, 0.08)
		if ry, ok := title_rule_y(pc.fonts, d, si); ok {
			bar(pc, SLIDE_W / 2 - 70, ry, 140, 3, accent, 0.9)
		}
	case .Section_Header:
		bar(pc, 0, 0, 10, SLIDE_H, accent, 1)
		oval(pc, 980, 140, 440, 440, accent2, 0.1)
	case .Title_Content, .Two_Content, .Picture:
		ry, ok := title_rule_y(pc.fonts, d, si)
		if !ok {
			ry = 182
		}
		bar(pc, MARGIN, ry, 86, 3, accent, 1)
	case .Blank:
	}

	// Elements, in paint order.
	for i in 0 ..< len(s.elems) {
		e := &s.elems[i]
		alpha := clamp(e.opacity, 0, 1)
		switch e.kind {
		case .Rect, .Ellipse:
			if has_paint(e.fill) {
				pdf_fill_shape(pc, e, paint(th, e.fill), alpha * clamp(e.fill_a, 0, 1), e.kind == .Ellipse)
			}
			if has_paint(e.stroke) && e.stroke_w > 0 {
				pdf_stroke_shape(pc, e, paint(th, e.stroke), alpha, e.kind == .Ellipse)
			}
		case .Line, .Arrow:
			pdf_line_element(pc, e)
		case .Image:
			pdf_image_element(pc, e)
		case .Text:
			if has_paint(e.fill) {
				pdf_fill_shape(pc, e, paint(th, e.fill), alpha * clamp(e.fill_a, 0, 1), false)
			}
			if has_paint(e.stroke) && e.stroke_w > 0 {
				pdf_stroke_shape(pc, e, paint(th, e.stroke), alpha, false)
			}
			pdf_text_element(pc, e)
		}
	}

	// The footer, as the editor draws it.
	if s.layout != .Title && s.layout != .Blank && !d.no_decor {
		muted := argb(th.muted)
		bar(pc, MARGIN, SLIDE_H - 54, SLIDE_W - 2 * MARGIN, 1, muted, 0.25)
		left := text_box(d.title, .Caption, MARGIN, SLIDE_H - 50, (SLIDE_W - 2 * MARGIN) / 2, 30)
		left.size = 15
		left.color = SLOT_MUTED
		left.valign = .Top
		pdf_text_element(pc, &left)
		right := text_box(
			fmt.tprintf("%d / %d", si + 1, len(d.slides)),
			.Caption,
			SLIDE_W / 2,
			SLIDE_H - 50,
			SLIDE_W / 2 - MARGIN,
			30,
			.Right,
		)
		right.size = 15
		right.color = SLOT_MUTED
		right.bold = true
		pdf_text_element(pc, &right)
	}
}

// ---------------------------------------------------------------------------
// The file
// ---------------------------------------------------------------------------

pdf_bytes :: proc(d: ^Deck, fonts: ^p.Fonts, imgs: ^Img_Cache, allocator := context.allocator) -> []u8 {
	th := &d.theme
	n := len(d.slides)
	gradient := th.bg2 != 0 && th.bg2 != th.bg

	// Build every page's content stream first; the images a page uses are only
	// known once it has been drawn, and the object numbers depend on how many
	// there are.
	images := make([dynamic]Pdf_Image, context.temp_allocator)
	streams := make([dynamic]string, context.temp_allocator)
	alphas := make([dynamic]Alphas, context.temp_allocator)
	page_imgs := make([dynamic][dynamic]int, context.temp_allocator)

	for si in 0 ..< n {
		b := strings.builder_make(context.temp_allocator)
		al := Alphas {
			vals = make([dynamic]f32, context.temp_allocator),
		}
		used := make([dynamic]int, context.temp_allocator)
		pc := Page_Ctx {
			b      = &b,
			al     = &al,
			fonts  = fonts,
			imgs   = imgs,
			images = &images,
			used   = &used,
			th     = th,
		}
		pdf_slide(&pc, d, si, gradient)
		append(&streams, strings.to_string(b))
		append(&alphas, al)
		append(&page_imgs, used)
	}

	// Object numbering, fixed from here:
	//   1 catalog, 2 pages, 3..10 fonts, 11 the shared /ToUnicode CMap,
	//   12.. images, then a page object and a content object per slide.
	OBJ_CATALOG :: 1
	OBJ_PAGES :: 2
	OBJ_FONT0 :: 3
	OBJ_TOUNI :: OBJ_FONT0 + PDF_FONTS
	obj_img0 := OBJ_TOUNI + 1
	obj_page0 := obj_img0 + len(images)
	total := obj_page0 + 2 * n - 1
	for i in 0 ..< len(images) {
		images[i].obj = obj_img0 + i
	}

	f := pdf_make(context.temp_allocator)
	// The binary comment on line two tells every tool that handles this file
	// that it is not text and must not be newline-translated.
	strings.write_string(&f.b, "%PDF-1.7\n%\xe2\xe3\xcf\xd3\n")

	pdf_obj(&f, OBJ_CATALOG)
	fmt.sbprintf(&f.b, "<< /Type /Catalog /Pages %d 0 R >>", OBJ_PAGES)
	pdf_endobj(&f)

	pdf_obj(&f, OBJ_PAGES)
	strings.write_string(&f.b, "<< /Type /Pages /Kids [")
	for si in 0 ..< n {
		fmt.sbprintf(&f.b, "%s%d 0 R", si == 0 ? "" : " ", obj_page0 + 2 * si)
	}
	fmt.sbprintf(&f.b, "] /Count %d >>", n)
	pdf_endobj(&f)

	for name, i in PDF_FONT_NAMES {
		pdf_obj(&f, OBJ_FONT0 + i)
		fmt.sbprintf(
			&f.b,
			"<< /Type /Font /Subtype /Type1 /BaseFont /%s /Encoding /WinAnsiEncoding /ToUnicode %d 0 R >>",
			name,
			OBJ_TOUNI,
		)
		pdf_endobj(&f)
	}

	pdf_stream(&f, OBJ_TOUNI, "", transmute([]u8)pdf_tounicode_cmap())

	for im in images {
		enc := run_length(im.rgb, context.temp_allocator)
		pdf_stream(
			&f,
			im.obj,
			fmt.tprintf(
				"/Type /XObject /Subtype /Image /Width %d /Height %d /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /RunLengthDecode",
				im.w,
				im.h,
			),
			enc,
		)
	}

	for si in 0 ..< n {
		page := obj_page0 + 2 * si
		content := page + 1

		pdf_obj(&f, page)
		fmt.sbprintf(
			&f.b,
			"<< /Type /Page /Parent %d 0 R /MediaBox [0 0 %s %s] /Resources << /Font <<",
			OBJ_PAGES,
			num(PDF_PAGE_W),
			num(PDF_PAGE_H),
		)
		for fi in 0 ..< PDF_FONTS {
			fmt.sbprintf(&f.b, " /F%d %d 0 R", fi + 1, OBJ_FONT0 + fi)
		}
		strings.write_string(&f.b, " >>")
		// Graphics states, one per distinct alpha this page used.
		if len(alphas[si].vals) > 0 {
			strings.write_string(&f.b, " /ExtGState <<")
			for a, i in alphas[si].vals {
				fmt.sbprintf(&f.b, " /GA%d << /Type /ExtGState /ca %s /CA %s >>", i, num(a), num(a))
			}
			strings.write_string(&f.b, " >>")
		}
		if len(page_imgs[si]) > 0 {
			strings.write_string(&f.b, " /XObject <<")
			for idx in page_imgs[si] {
				fmt.sbprintf(&f.b, " /Im%d %d 0 R", idx, images[idx].obj)
			}
			strings.write_string(&f.b, " >>")
		}
		if gradient {
			c0 := argb(th.bg)
			c1 := argb(th.bg2)
			fmt.sbprintf(
				&f.b,
				" /Shading << /Sh0 << /ShadingType 2 /ColorSpace /DeviceRGB /Coords [0 0 0 %s] /Extend [true true] /Function << /FunctionType 2 /Domain [0 1] /N 1 /C0 [%s %s %s] /C1 [%s %s %s] >> >> >>",
				num(SLIDE_H),
				num(f32(c0.r) / 255),
				num(f32(c0.g) / 255),
				num(f32(c0.b) / 255),
				num(f32(c1.r) / 255),
				num(f32(c1.g) / 255),
				num(f32(c1.b) / 255),
			)
		}
		fmt.sbprintf(&f.b, " >> /Contents %d 0 R >>", content)
		pdf_endobj(&f)

		pdf_stream(&f, content, "", transmute([]u8)streams[si])
	}

	// The cross-reference table and the trailer.
	xref := strings.builder_len(f.b)
	fmt.sbprintf(&f.b, "xref\n0 %d\n0000000000 65535 f \n", total + 1)
	for i in 1 ..= total {
		off := i < len(f.offsets) ? f.offsets[i] : 0
		fmt.sbprintf(&f.b, "%010d 00000 n \n", off)
	}
	fmt.sbprintf(
		&f.b,
		"trailer\n<< /Size %d /Root %d 0 R /Info << /Title (%s) /Author (%s) /Producer (palmy slides) >> >>\nstartxref\n%d\n%%%%EOF\n",
		total + 1,
		OBJ_CATALOG,
		pdf_text_bytes(d.title),
		pdf_text_bytes(d.author),
		xref,
	)

	raw := transmute([]u8)strings.to_string(f.b)
	out := make([]u8, len(raw), allocator)
	copy(out, raw)
	return out
}

// pdf_tounicode_cmap maps every WinAnsi code onto the Unicode it stands for.
// Without this a reader has to guess what a byte means, and `pdftotext` on a
// deck full of curly quotes and em dashes returns rubbish. With it, the text
// extracts exactly as written.
pdf_tounicode_cmap :: proc() -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(
		&b,
		`/CIDInit /ProcSet findresource begin
12 dict begin
begincmap
/CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def
/CMapName /Adobe-Identity-UCS def
/CMapType 2 def
1 begincodespacerange
<00> <FF>
endcodespacerange
`,
	)
	// A bfchar block may hold at most 100 entries, which is the format's rule
	// and not a style choice.
	codes := make([dynamic]int, context.temp_allocator)
	for c in 0 ..< 256 {
		if pdf_unicode_for(u8(c)) != 0 {
			append(&codes, c)
		}
	}
	for start := 0; start < len(codes); start += 100 {
		end := min(start + 100, len(codes))
		fmt.sbprintf(&b, "%d beginbfchar\n", end - start)
		for i in start ..< end {
			fmt.sbprintf(&b, "<%02X> <%04X>\n", codes[i], pdf_unicode_for(u8(codes[i])))
		}
		strings.write_string(&b, "endbfchar\n")
	}
	strings.write_string(&b, "endcmap\nCMapName currentdict /CMap defineresource pop\nend\nend\n")
	return strings.to_string(b)
}

pdf_write_file :: proc(d: ^Deck, path: string, fonts: ^p.Fonts, imgs: ^Img_Cache) -> string {
	if slash := strings.last_index_byte(path, '/'); slash > 0 {
		_ = os.make_directory_all(path[:slash])
	}
	data := pdf_bytes(d, fonts, imgs, context.temp_allocator)
	if e := os.write_entire_file(path, data); e != nil {
		return fmt.tprintf("cannot write %s: %v", path, e)
	}
	return ""
}
