// PDF export — real PDF, not pictures of pages.
//
// The app already renders a page into a buffer and writes a PNG, and it would
// have been a morning's work to wrap those PNGs in a PDF. That file would be
// ten times the size and none of its text could be searched, selected, copied
// or read aloud, so this file writes the document structure instead: one
// content stream per page, text positioned from the same fragment table the
// screen draws from, with the real font program embedded and subset.
//
// ## Coordinates
//
// The layout is in CSS pixels at 96 dpi; PDF user space is 72 dpi. The whole
// conversion is therefore the constant `PT = 0.75`, applied to positions and
// to type sizes alike — get it wrong and every glyph is 33% too big. PDF's y
// axis also points up from the bottom-left of the page, so a layout y becomes
// `PDF_H - y * PT`.
//
// ## Fonts
//
// Each face the document uses becomes a `/Type0` composite font with
// `/Identity-H` encoding, so a string in the content stream is a sequence of
// big-endian glyph ids rather than of characters. That is the only encoding
// that reaches every glyph of a modern face, and it has one trap: with the
// text stored as glyph ids, a reader has no idea what the characters *are*.
// The `/ToUnicode` CMap is what tells it, and omitting it is the single most
// common way a hand-written PDF ends up extracting as mojibake. Every font
// here gets one.
//
// Faces are keyed by *file*, not by family and weight, because palmy's table
// aliases several slots onto the same file — the mono face fills all four
// weights, and this app parks the italics in two of them. Keying by path
// means one embedded subset per real font, with the glyph sets merged.
//
// ## Agreeing with the screen
//
// Line breaks are not recomputed: every line and fragment comes from
// `Layout`, so the PDF breaks exactly where the window does. Within a
// fragment the pen is a different matter — palmy applies kerning, and a PDF
// viewer advances by the widths in the font dictionary, which do not include
// it. So each glyph's expected advance is taken from palmy (the same
// `text_width` the caret is measured with), compared against the advance the
// viewer will use, and the difference is emitted as a `TJ` adjustment once it
// has drifted past a hundredth of a pixel. The result is glyph-for-glyph
// agreement with the rasterizer, at the cost of a handful of numbers per line.
package main

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:time"
import "core:unicode/utf8"
import p "palmy:."

// A4 at 72 dpi, to the three decimals every other producer writes.
PDF_W :: f32(595.276)
PDF_H :: f32(841.890)
PT :: f32(0.75) // 96 dpi → 72 dpi

// How far the pen may drift from palmy's measurement before the content
// stream corrects it.
KERN_TOL :: f32(0.01)

// ---------------------------------------------------------------------------
// Objects
// ---------------------------------------------------------------------------

Pdf :: struct {
	objs: [dynamic][dynamic]u8, // object n lives at index n-1
}

pdf_init :: proc(w: ^Pdf) {
	w.objs = make([dynamic][dynamic]u8, 0, 32)
}

pdf_destroy :: proc(w: ^Pdf) {
	for &o in w.objs {
		delete(o)
	}
	delete(w.objs)
	w^ = {}
}

// pdf_reserve hands out an object number before its body exists, which is
// what a /Pages dict needs: it has to name its children, and the children
// have to name it back.
pdf_reserve :: proc(w: ^Pdf) -> int {
	append(&w.objs, make([dynamic]u8, 0, 128))
	return len(w.objs)
}

pdf_set :: proc(w: ^Pdf, n: int, body: string) {
	o := &w.objs[n - 1]
	clear(o)
	append(o, ..transmute([]u8)body)
}

// pdf_set_stream writes a stream object: the dictionary, with /Length filled
// in, then the bytes. Nothing here is compressed — a PDF with uncompressed
// streams is entirely valid, and it is also readable with `less`, which is
// worth something while the format is being got right.
pdf_set_stream :: proc(w: ^Pdf, n: int, extra_dict: string, data: []u8) {
	o := &w.objs[n - 1]
	clear(o)
	head := fmt.tprintf("<< /Length %d%s%s >>\nstream\n", len(data), len(extra_dict) > 0 ? " " : "", extra_dict)
	append(o, ..transmute([]u8)head)
	append(o, ..data)
	append(o, ..transmute([]u8)string("\nendstream"))
}

// pdf_bytes serialises the file: header, body with an offset recorded per
// object, the classic cross-reference table, and the trailer.
pdf_bytes :: proc(w: ^Pdf, root, info: int, alloc := context.allocator) -> []u8 {
	out := make([dynamic]u8, 0, 1 << 16, alloc)
	// The binary comment on line two marks the file as containing 8-bit data,
	// so a transport that might mangle it knows not to treat it as text.
	append(&out, ..transmute([]u8)string("%PDF-1.7\n%\xe2\xe3\xcf\xd3\n"))

	offsets := make([]int, len(w.objs), context.temp_allocator)
	for i in 0 ..< len(w.objs) {
		offsets[i] = len(out)
		append(&out, ..transmute([]u8)fmt.tprintf("%d 0 obj\n", i + 1))
		append(&out, ..w.objs[i][:])
		append(&out, ..transmute([]u8)string("\nendobj\n"))
	}

	xref := len(out)
	append(&out, ..transmute([]u8)fmt.tprintf("xref\n0 %d\n", len(w.objs) + 1))
	append(&out, ..transmute([]u8)string("0000000000 65535 f \n"))
	for off in offsets {
		// Every entry is exactly 20 bytes, including the trailing space.
		append(&out, ..transmute([]u8)fmt.tprintf("%010d 00000 n \n", off))
	}
	append(
		&out,
		..transmute([]u8)fmt.tprintf(
			"trailer\n<< /Size %d /Root %d 0 R /Info %d 0 R >>\nstartxref\n%d\n%%%%EOF\n",
			len(w.objs) + 1,
			root,
			info,
			xref,
		),
	)
	return out[:]
}

// ---------------------------------------------------------------------------
// Strings and names
// ---------------------------------------------------------------------------

// pdf_text writes a literal string, escaping the three characters that would
// otherwise end it, and encoding anything non-ASCII as UTF-16BE with a byte
// order mark — which is how a PDF string carries text outside Latin-1.
pdf_text :: proc(b: ^strings.Builder, s: string) {
	ascii := true
	for i in 0 ..< len(s) {
		if s[i] >= 0x80 {
			ascii = false
			break
		}
	}
	if ascii {
		strings.write_byte(b, '(')
		for i in 0 ..< len(s) {
			switch s[i] {
			case '(', ')', '\\':
				strings.write_byte(b, '\\')
				strings.write_byte(b, s[i])
			case '\r':
				strings.write_string(b, "\\r")
			case '\n':
				strings.write_string(b, "\\n")
			case:
				strings.write_byte(b, s[i])
			}
		}
		strings.write_byte(b, ')')
		return
	}
	strings.write_string(b, "<FEFF")
	for r in s {
		c := u32(r)
		if c > 0xffff {
			c -= 0x10000
			fmt.sbprintf(b, "%04X%04X", 0xd800 + (c >> 10), 0xdc00 + (c & 0x3ff))
		} else {
			fmt.sbprintf(b, "%04X", c)
		}
	}
	strings.write_byte(b, '>')
}

// num writes a coordinate with two decimals and no trailing noise, which
// keeps content streams readable and small.
@(private = "file")
num :: proc(b: ^strings.Builder, v: f32) {
	r := f32(int(v * 100 + (v >= 0 ? 0.5 : -0.5))) / 100
	if r == f32(int(r)) {
		fmt.sbprintf(b, "%d", int(r))
	} else {
		fmt.sbprintf(b, "%.2f", r)
	}
}

// ---------------------------------------------------------------------------
// The font table
// ---------------------------------------------------------------------------

Pdf_Font :: struct {
	path:   string,
	ttf:    TTF,
	used:   map[u16]rune, // glyph id → a character that maps to it
	tag:    string, // the six-letter subset prefix
	obj:    int, // the /Type0 dictionary
	res:    string, // the resource name, "/F3"
	italic: bool,
}

Pdf_Ctx :: struct {
	st:     ^State,
	fonts:  [dynamic]Pdf_Font,
	by_key: map[u32]int, // family<<8 | weight → index into `fonts`
}

@(private = "file")
face_key :: proc(fam: p.Font_Family, wt: p.Font_Weight) -> u32 {
	return u32(fam) << 8 | u32(wt)
}

// pdf_face finds or opens the embedded font behind a palmy family and weight.
// The file is whatever palmy actually loaded, asked for by `p.font_path`, so
// the PDF embeds the very face the window measured with rather than a guess
// at which file that was.
pdf_face :: proc(cx: ^Pdf_Ctx, fam: p.Font_Family, wt: p.Font_Weight) -> int {
	k := face_key(fam, wt)
	if i, hit := cx.by_key[k]; hit {
		return i
	}
	path := p.font_path(cx.st.fonts, fam, wt)
	if path == "" {
		// Fall back to the regular sans, which is the one face the app
		// refuses to start without.
		path = p.font_path(cx.st.fonts, .Sans, .Regular)
	}
	for f, i in cx.fonts {
		if f.path == path {
			cx.by_key[k] = i
			return i
		}
	}
	ttf, ok := ttf_load(path)
	if !ok {
		cx.by_key[k] = -1
		return -1
	}
	append(
		&cx.fonts,
		Pdf_Font {
			path   = path,
			ttf    = ttf,
			used   = make(map[u16]rune),
			italic = ttf.italic_angle < -0.5 || ttf.italic_angle > 0.5,
		},
	)
	i := len(cx.fonts) - 1
	cx.by_key[k] = i
	return i
}

// pdf_need records every glyph a string will need, so the subset keeps them.
pdf_need :: proc(cx: ^Pdf_Ctx, fi: int, s: string) {
	if fi < 0 {
		return
	}
	pf := &cx.fonts[fi]
	for r in s {
		g := ttf_gid(&pf.ttf, r)
		if g != 0 {
			pf.used[g] = r
		}
	}
}

// pdf_has reports whether a face can draw a rune at all. The bullet is the
// one character this matters for: a UI sans may well not carry U+2022, and a
// missing-glyph box in the middle of a list would be worse than drawing the
// dot as a circle, which is what `emit_bullet` does instead.
pdf_has :: proc(cx: ^Pdf_Ctx, fi: int, r: rune) -> bool {
	return fi >= 0 && ttf_gid(&cx.fonts[fi].ttf, r) != 0
}

@(private = "file")
subset_tag :: proc(seed: u64) -> string {
	b := strings.builder_make(context.temp_allocator)
	h := seed
	for _ in 0 ..< 6 {
		strings.write_byte(&b, 'A' + u8(h % 26))
		h /= 26
		h = h * 1099511628211 + 0xcbf29ce4
	}
	return strings.clone(strings.to_string(b))
}

// ---------------------------------------------------------------------------
// Showing text
// ---------------------------------------------------------------------------

// pdf_show emits one `TJ` for a string, with the kerning corrections
// described at the top of the file. `size_px` is the layout's type size;
// the caller has already emitted the matching `Tf` at `size_px * PT`.
pdf_show :: proc(
	b: ^strings.Builder,
	cx: ^Pdf_Ctx,
	fi: int,
	s: string,
	size_px: f32,
	fam: p.Font_Family,
	wt: p.Font_Weight,
) {
	if fi < 0 || len(s) == 0 {
		return
	}
	pf := &cx.fonts[fi]
	fonts := cx.st.fonts

	strings.write_string(b, "[<")
	open_hex := true
	err := f32(0) // expected pen minus the pen the viewer will have
	cum_prev := f32(0)

	i := 0
	for i < len(s) {
		r, n := utf8.decode_rune_in_string(s[i:])
		j := i + max(1, n)

		// Expected advance: palmy's own prefix width, so kerning and any
		// per-face adjustment the rasterizer applies are included. Measuring
		// the prefix rather than the pair makes the two measurements cancel
		// any constant the face carries.
		cum := p.text_width_upto(fonts, s, j, size_px, fam, wt)
		want := cum - cum_prev
		cum_prev = cum

		g := ttf_gid(&pf.ttf, r)
		have := f32(ttf_advance(&pf.ttf, g)) / 1000 * size_px
		err += want - have

		if err > KERN_TOL || err < -KERN_TOL {
			// A TJ number moves the pen *left* by num/1000 of the type size,
			// so the sign is inverted.
			adj := -err / size_px * 1000
			rounded := f32(int(adj * 100 + (adj >= 0 ? 0.5 : -0.5))) / 100
			if open_hex {
				strings.write_byte(b, '>')
				open_hex = false
			}
			strings.write_byte(b, ' ')
			num(b, rounded)
			strings.write_string(b, " <")
			open_hex = true
			err += rounded / 1000 * size_px
		}
		fmt.sbprintf(b, "%04X", g)
		i = j
	}
	if open_hex {
		strings.write_byte(b, '>')
	}
	strings.write_string(b, "] TJ\n")
}

// ---------------------------------------------------------------------------
// Content streams
// ---------------------------------------------------------------------------

@(private = "file")
set_fill :: proc(b: ^strings.Builder, cur: ^u32, col: u32) {
	if cur^ == col {
		return
	}
	cur^ = col
	r := f32((col >> 16) & 0xff) / 255
	g := f32((col >> 8) & 0xff) / 255
	bl := f32(col & 0xff) / 255
	fmt.sbprintf(b, "%.3f %.3f %.3f rg\n", r, g, bl)
}

@(private = "file")
rect :: proc(b: ^strings.Builder, x_px, y_px, w_px, h_px: f32) {
	// `y_px` is the top of the box in layout space; a PDF rectangle is given
	// by its lower-left corner.
	num(b, x_px * PT)
	strings.write_byte(b, ' ')
	num(b, PDF_H - (y_px + h_px) * PT)
	strings.write_byte(b, ' ')
	num(b, w_px * PT)
	strings.write_byte(b, ' ')
	num(b, h_px * PT)
	strings.write_string(b, " re f\n")
}

// emit_bullet draws a list bullet as a filled circle, for the faces that have
// no U+2022. Four Béziers with the usual 0.5523 handle length.
@(private = "file")
emit_bullet :: proc(b: ^strings.Builder, cx_px, cy_px, r_px: f32) {
	x := cx_px * PT
	y := PDF_H - cy_px * PT
	r := r_px * PT
	k := r * 0.5523
	fmt.sbprintf(b, "%.2f %.2f m\n", x - r, y)
	fmt.sbprintf(b, "%.2f %.2f %.2f %.2f %.2f %.2f c\n", x - r, y + k, x - k, y + r, x, y + r)
	fmt.sbprintf(b, "%.2f %.2f %.2f %.2f %.2f %.2f c\n", x + k, y + r, x + r, y + k, x + r, y)
	fmt.sbprintf(b, "%.2f %.2f %.2f %.2f %.2f %.2f c\n", x + r, y - k, x + k, y - r, x, y - r)
	fmt.sbprintf(b, "%.2f %.2f %.2f %.2f %.2f %.2f c\n", x - k, y - r, x - r, y - k, x - r, y)
	strings.write_string(b, "f\n")
}

marker_label :: proc(marker: int) -> string {
	return marker == 0 ? "•" : fmt.tprintf("%d.", marker)
}

// pdf_collect is the first pass: it walks every line of every page exactly as
// the emitter will and registers the faces and glyphs they need, so the
// subsets are complete before a single byte of content is written.
pdf_collect :: proc(cx: ^Pdf_Ctx) {
	lay := &cx.st.lay
	for li in 0 ..< len(lay.lines) {
		l := lay.lines[li]
		for k in 0 ..< l.fc {
			f := lay.frags[l.fi + k]
			fi := pdf_face(cx, f.fam, f.wt)
			if f.end > f.start {
				pdf_need(cx, fi, frag_text(lay, l, f))
			}
		}
		if l.marker >= 0 && l.fc > 0 {
			f := lay.frags[l.fi]
			fi := pdf_face(cx, f.fam, f.wt)
			pdf_need(cx, fi, marker_label(l.marker))
		}
	}
	// The footer's page numbers, always in the regular sans.
	fi := pdf_face(cx, .Sans, .Regular)
	pdf_need(cx, fi, "0123456789")
}

// pdf_page_content renders one page into a content stream, mirroring
// `draw_page` block for block: paragraph decoration, list marker, the text,
// underlines, then the footer.
pdf_page_content :: proc(cx: ^Pdf_Ctx, pi: int, alloc := context.allocator) -> string {
	st := cx.st
	lay := &st.lay
	b := strings.builder_make(alloc)
	fill := u32(0xffffffff) // a value no colour can take, so the first set emits

	lo, hi := page_lines(lay, pi)
	if lo >= 0 {
		for li in lo ..= hi {
			l := lay.lines[li]
			pa := &st.doc.paras[l.para]
			top := MARGIN + l.y
			base := MARGIN + l.y + l.ascent

			switch pa.kind {
			case .Code:
				set_fill(&b, &fill, COL_CODE_BG)
				rect(&b, MARGIN + l.indent - 10, top, CONTENT_W - l.indent + 16, l.h)
			case .Quote:
				set_fill(&b, &fill, COL_RULE)
				rect(&b, MARGIN + l.indent - 16, top, 3, l.h)
			case .Body, .H1, .H2, .H3:
			}

			// The list marker, right-aligned against the text's left edge the
			// same way the renderer aligns it.
			if l.marker >= 0 && l.fc > 0 {
				f := lay.frags[l.fi]
				fi := pdf_face(cx, f.fam, f.wt)
				label := marker_label(l.marker)
				set_fill(&b, &fill, COL_INK)
				if l.marker == 0 && !pdf_has(cx, fi, '•') {
					// No bullet glyph: draw the dot.
					emit_bullet(&b, MARGIN + l.indent - 10 - f.size * 0.2, base - f.size * 0.3, f.size * 0.1)
				} else {
					mw := p.text_width(layout_fonts, label, f.size, f.fam, f.wt)
					strings.write_string(&b, "BT\n")
					fmt.sbprintf(&b, "%s ", cx.fonts[fi].res)
					num(&b, f.size * PT)
					strings.write_string(&b, " Tf\n")
					tm(&b, MARGIN + l.indent - 10 - mw, base)
					pdf_show(&b, cx, fi, label, f.size, f.fam, f.wt)
					strings.write_string(&b, "ET\n")
				}
			}

			// The text. One BT/ET per line, with the font and the colour set
			// only when they change.
			if l.fc > 0 {
				started := false
				cur_font := -1
				cur_size := f32(-1)
				for k in 0 ..< l.fc {
					f := lay.frags[l.fi + k]
					if f.end <= f.start {
						continue
					}
					fi := pdf_face(cx, f.fam, f.wt)
					if fi < 0 {
						continue
					}
					if !started {
						strings.write_string(&b, "BT\n")
						started = true
					}
					col := f.color == 0 ? COL_INK : f.color & 0xffffff
					// A colour change is a graphics-state operator and is
					// perfectly legal between BT and ET.
					set_fill(&b, &fill, col)
					if fi != cur_font || f.size != cur_size {
						fmt.sbprintf(&b, "%s ", cx.fonts[fi].res)
						num(&b, f.size * PT)
						strings.write_string(&b, " Tf\n")
						cur_font, cur_size = fi, f.size
					}
					tm(&b, MARGIN + l.x + f.x, base)
					pdf_show(&b, cx, fi, frag_text(lay, l, f), f.size, f.fam, f.wt)
				}
				if started {
					strings.write_string(&b, "ET\n")
				}
			}

			// Underlines, after the text, as the renderer draws them.
			for k in 0 ..< l.fc {
				f := lay.frags[l.fi + k]
				if !f.underline || f.end <= f.start {
					continue
				}
				col := f.color == 0 ? COL_INK : f.color & 0xffffff
				set_fill(&b, &fill, col)
				rect(&b, MARGIN + l.x + f.x, base + f.size * 0.14, f.w, max(1, f.size * 0.07))
			}
		}
	}

	// The footer page number.
	{
		label := fmt.tprintf("%d", pi + 1)
		fi := pdf_face(cx, .Sans, .Regular)
		if fi >= 0 {
			w := p.text_width(layout_fonts, label, 10, .Sans, .Regular)
			set_fill(&b, &fill, COL_FOOT)
			strings.write_string(&b, "BT\n")
			fmt.sbprintf(&b, "%s ", cx.fonts[fi].res)
			num(&b, 10 * PT)
			strings.write_string(&b, " Tf\n")
			tm(&b, (PAGE_W - w) / 2, PAGE_H - MARGIN * 0.42)
			pdf_show(&b, cx, fi, label, 10, .Sans, .Regular)
			strings.write_string(&b, "ET\n")
		}
	}
	return strings.to_string(b)
}

// tm sets the text matrix to an absolute position, in layout pixels.
@(private = "file")
tm :: proc(b: ^strings.Builder, x_px, base_px: f32) {
	strings.write_string(b, "1 0 0 1 ")
	num(b, x_px * PT)
	strings.write_byte(b, ' ')
	num(b, PDF_H - base_px * PT)
	strings.write_string(b, " Tm\n")
}

// ---------------------------------------------------------------------------
// The whole file
// ---------------------------------------------------------------------------

pdf_date :: proc() -> string {
	t := time.now()
	y, mo, d := time.date(t)
	h, mi, s := time.clock_from_time(t)
	return fmt.tprintf("D:%04d%02d%02d%02d%02d%02dZ", y, int(mo), d, h, mi, s)
}

pdf_author :: proc() -> string {
	if u := os.get_env("USER", context.temp_allocator); u != "" {
		return u
	}
	return "palmy docs"
}

// export_pdf writes the laid-out document in `st` as a PDF. The caller must
// have laid it out already; nothing here re-wraps anything, which is the
// point — the file's line breaks are the window's.
export_pdf :: proc(st: ^State, path: string, title: string) -> bool {
	if len(st.lay.lines) == 0 || st.lay.pages < 1 {
		return false
	}
	cx := Pdf_Ctx {
		fonts  = make([dynamic]Pdf_Font, 0, 6),
		by_key = make(map[u32]int),
		st     = st,
	}
	defer {
		for &f in cx.fonts {
			ttf_destroy(&f.ttf)
			delete(f.used)
			delete(f.tag)
			delete(f.res)
		}
		delete(cx.fonts)
		delete(cx.by_key)
	}

	pdf_collect(&cx)
	if len(cx.fonts) == 0 {
		return false
	}
	for &f, i in cx.fonts {
		f.res = fmt.aprintf("/F%d", i)
	}

	w: Pdf
	pdf_init(&w)
	defer pdf_destroy(&w)

	catalog := pdf_reserve(&w)
	pages := pdf_reserve(&w)
	info := pdf_reserve(&w)

	// --- fonts
	for &f, i in cx.fonts {
		t := &f.ttf
		// Glyph 0 — .notdef — is always in the subset and always in /W.
		//
		// It has to be: palmy measures a character the face cannot draw by
		// looking up glyph 0 and taking *its* advance, so a PDF that left it
		// out and fell back on /DW would lay a run of missing glyphs out
		// wider than the screen did and overlap whatever follows. Mapping it
		// to U+FFFD in /ToUnicode also means a reader extracts a replacement
		// character rather than silently dropping the text.
		f.used[0] = '\ufffd'
		gids := make([dynamic]u16, 0, len(f.used), context.temp_allocator)
		for g in f.used {
			append(&gids, g)
		}
		slice.sort(gids[:])

		keep := make(map[u16]bool, len(gids) + 4, context.temp_allocator)
		for g in gids {
			keep[g] = true
		}
		sub := ttf_subset(t, keep, context.temp_allocator)

		// A subset tag that depends on the glyph set, so two documents with
		// different subsets of one face never collide in a reader's cache.
		seed := u64(len(sub)) * 1000003 + u64(len(gids)) * 131 + u64(i)
		for k in 0 ..< len(f.path) {
			seed = (seed ~ u64(f.path[k])) * 0x100000001b3
		}
		f.tag = subset_tag(seed)
		base := fmt.tprintf("%s+%s", f.tag, t.ps_name)

		file_obj := pdf_reserve(&w)
		pdf_set_stream(&w, file_obj, fmt.tprintf("/Length1 %d", len(sub)), sub)

		desc := pdf_reserve(&w)
		flags := 32 // Nonsymbolic: the font uses the standard character set
		if t.fixed_pitch {
			flags |= 1
		}
		if f.italic {
			flags |= 64
		}
		if t.weight_class >= 600 {
			flags |= 1 << 18 // ForceBold
		}
		pdf_set(
			&w,
			desc,
			fmt.tprintf(
				"<< /Type /FontDescriptor /FontName /%s /Flags %d " +
				"/FontBBox [%d %d %d %d] /ItalicAngle %.1f /Ascent %d /Descent %d " +
				"/CapHeight %d /StemV %d /FontFile2 %d 0 R >>",
				base,
				flags,
				to_em1000(t, t.x_min),
				to_em1000(t, t.y_min),
				to_em1000(t, t.x_max),
				to_em1000(t, t.y_max),
				t.italic_angle,
				to_em1000(t, t.ascent),
				to_em1000(t, t.descent),
				to_em1000(t, t.cap_height),
				t.weight_class / 10 + 20,
				file_obj,
			),
		)

		// /W, with consecutive glyph ids collapsed into one run.
		wb := strings.builder_make(context.temp_allocator)
		strings.write_string(&wb, "[")
		k := 0
		for k < len(gids) {
			j := k + 1
			for j < len(gids) && gids[j] == gids[j - 1] + 1 {
				j += 1
			}
			fmt.sbprintf(&wb, " %d [", gids[k])
			for q in k ..< j {
				if q > k {
					strings.write_byte(&wb, ' ')
				}
				fmt.sbprintf(&wb, "%d", ttf_advance(t, gids[q]))
			}
			strings.write_string(&wb, "]")
			k = j
		}
		strings.write_string(&wb, " ]")

		cid := pdf_reserve(&w)
		to_uni := pdf_reserve(&w)
		pdf_set(
			&w,
			cid,
			fmt.tprintf(
				"<< /Type /Font /Subtype /CIDFontType2 /BaseFont /%s " +
				"/CIDSystemInfo << /Registry (Adobe) /Ordering (Identity) /Supplement 0 >> " +
				"/FontDescriptor %d 0 R /DW %d /W %s /CIDToGIDMap /Identity >>",
				base,
				desc,
				ttf_advance(t, 0),
				strings.to_string(wb),
			),
		)

		pdf_set_stream(&w, to_uni, "", transmute([]u8)to_unicode_cmap(&f, gids[:], context.temp_allocator))

		f.obj = pdf_reserve(&w)
		pdf_set(
			&w,
			f.obj,
			fmt.tprintf(
				"<< /Type /Font /Subtype /Type0 /BaseFont /%s /Encoding /Identity-H " +
				"/DescendantFonts [%d 0 R] /ToUnicode %d 0 R >>",
				base,
				cid,
				to_uni,
			),
		)
	}

	// --- the shared /Resources, naming every font once
	res := strings.builder_make(context.temp_allocator)
	strings.write_string(&res, "<< /Font << ")
	for f in cx.fonts {
		fmt.sbprintf(&res, "%s %d 0 R ", f.res, f.obj)
	}
	strings.write_string(&res, ">> /ProcSet [/PDF /Text] >>")
	res_obj := pdf_reserve(&w)
	pdf_set(&w, res_obj, strings.to_string(res))

	// --- pages
	page_objs := make([dynamic]int, 0, st.lay.pages, context.temp_allocator)
	for pi in 0 ..< st.lay.pages {
		content := pdf_page_content(&cx, pi, context.temp_allocator)
		cobj := pdf_reserve(&w)
		pdf_set_stream(&w, cobj, "", transmute([]u8)content)
		pobj := pdf_reserve(&w)
		pdf_set(
			&w,
			pobj,
			fmt.tprintf(
				"<< /Type /Page /Parent %d 0 R /MediaBox [0 0 %.3f %.3f] " +
				"/Resources %d 0 R /Contents %d 0 R >>",
				pages,
				PDF_W,
				PDF_H,
				res_obj,
				cobj,
			),
		)
		append(&page_objs, pobj)
	}

	kids := strings.builder_make(context.temp_allocator)
	strings.write_string(&kids, "[")
	for n in page_objs {
		fmt.sbprintf(&kids, " %d 0 R", n)
	}
	strings.write_string(&kids, " ]")
	pdf_set(
		&w,
		pages,
		fmt.tprintf("<< /Type /Pages /Count %d /Kids %s >>", len(page_objs), strings.to_string(kids)),
	)

	// --- an outline built from the headings, so a reader gets a sidebar
	outline := pdf_outline(&w, st, page_objs[:])

	cat := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&cat, "<< /Type /Catalog /Pages %d 0 R /Lang (en-US)", pages)
	if outline > 0 {
		fmt.sbprintf(&cat, " /Outlines %d 0 R /PageMode /UseOutlines", outline)
	}
	strings.write_string(&cat, " >>")
	pdf_set(&w, catalog, strings.to_string(cat))

	ib := strings.builder_make(context.temp_allocator)
	strings.write_string(&ib, "<< /Title ")
	pdf_text(&ib, title)
	strings.write_string(&ib, " /Author ")
	pdf_text(&ib, pdf_author())
	strings.write_string(&ib, " /Creator ")
	// Through `pdf_text`, not as a literal: a PDF string is PDFDocEncoded
	// unless it starts with a byte order mark, so raw UTF-8 in the source
	// would read back as mojibake in any viewer's document properties.
	pdf_text(&ib, "palmy docs")
	strings.write_string(&ib, " /Producer ")
	pdf_text(&ib, "palmy docs — hand-written PDF 1.7")
	fmt.sbprintf(&ib, " /CreationDate (%s) /ModDate (%s) >>", pdf_date(), pdf_date())
	pdf_set(&w, info, strings.to_string(ib))

	data := pdf_bytes(&w, catalog, info, context.temp_allocator)
	return os.write_entire_file(path, data) == nil
}

// to_unicode_cmap builds the CMap that turns glyph ids back into characters.
// Without it the text draws perfectly and extracts as garbage.
to_unicode_cmap :: proc(f: ^Pdf_Font, gids: []u16, alloc := context.allocator) -> string {
	b := strings.builder_make(alloc)
	strings.write_string(
		&b,
		"/CIDInit /ProcSet findresource begin\n12 dict begin\nbegincmap\n" +
		"/CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def\n" +
		"/CMapName /Adobe-Identity-UCS def\n/CMapType 2 def\n" +
		"1 begincodespacerange\n<0000> <FFFF>\nendcodespacerange\n",
	)
	// `bfchar` blocks hold at most 100 entries each — a hard limit in the
	// CMap specification, not a convention.
	at := 0
	for at < len(gids) {
		n := min(100, len(gids) - at)
		fmt.sbprintf(&b, "%d beginbfchar\n", n)
		for k in at ..< at + n {
			g := gids[k]
			r := u32(f.used[g])
			fmt.sbprintf(&b, "<%04X> <", g)
			if r > 0xffff {
				c := r - 0x10000
				fmt.sbprintf(&b, "%04X%04X", 0xd800 + (c >> 10), 0xdc00 + (c & 0x3ff))
			} else {
				fmt.sbprintf(&b, "%04X", r)
			}
			strings.write_string(&b, ">\n")
		}
		strings.write_string(&b, "endbfchar\n")
		at += n
	}
	strings.write_string(
		&b,
		"endcmap\nCMapName currentdict /CMap defineresource pop\nend\nend\n",
	)
	return strings.to_string(b)
}

// pdf_outline turns the document's headings into a flat outline. It returns 0
// when there are no headings, in which case the catalog omits the entry
// rather than pointing at an empty tree.
pdf_outline :: proc(w: ^Pdf, st: ^State, page_objs: []int) -> int {
	Item :: struct {
		title: string,
		page:  int,
		y:     f32,
		level: int,
	}
	items := make([dynamic]Item, 0, 16, context.temp_allocator)
	for li in 0 ..< len(st.lay.lines) {
		l := st.lay.lines[li]
		if !l.first {
			continue
		}
		pa := &st.doc.paras[l.para]
		level := 0
		switch pa.kind {
		case .H1:
			level = 1
		case .H2:
			level = 2
		case .H3:
			level = 3
		case .Body, .Quote, .Code:
			continue
		}
		t := para_text(pa, context.temp_allocator)
		if len(strings.trim_space(t)) == 0 {
			continue
		}
		append(&items, Item{title = t, page = l.page, y = MARGIN + l.y, level = level})
	}
	if len(items) == 0 {
		return 0
	}

	root := pdf_reserve(w)
	nums := make([]int, len(items), context.temp_allocator)
	for i in 0 ..< len(items) {
		nums[i] = pdf_reserve(w)
	}
	for it, i in items {
		b := strings.builder_make(context.temp_allocator)
		strings.write_string(&b, "<< /Title ")
		pdf_text(&b, it.title)
		pg := it.page >= 0 && it.page < len(page_objs) ? page_objs[it.page] : page_objs[0]
		fmt.sbprintf(&b, " /Parent %d 0 R /Dest [%d 0 R /XYZ 0 %.2f 0]", root, pg, PDF_H - it.y * PT)
		if i > 0 {
			fmt.sbprintf(&b, " /Prev %d 0 R", nums[i - 1])
		}
		if i + 1 < len(items) {
			fmt.sbprintf(&b, " /Next %d 0 R", nums[i + 1])
		}
		strings.write_string(&b, " >>")
		pdf_set(w, nums[i], strings.to_string(b))
	}
	pdf_set(
		w,
		root,
		fmt.tprintf(
			"<< /Type /Outlines /First %d 0 R /Last %d 0 R /Count %d >>",
			nums[0],
			nums[len(nums) - 1],
			len(items),
		),
	)
	return root
}
