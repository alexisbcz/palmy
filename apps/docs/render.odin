// Drawing the pages.
//
// The workspace is one `p.pixels` panel: the grey desk, the pages floating on
// it with a drop shadow, and the laid-out text drawn fragment by fragment with
// `p.draw_text`. palmy's element tree draws the chrome; nothing above this file
// knows how a page is painted, and nothing in this file knows about the model
// beyond what `Layout` already worked out.
//
// Two coordinate systems meet here. The layout is in document pixels, at
// zoom 1. The canvas is in device pixels. `k = zoom * canvas.scale` converts
// one to the other, and is applied to type sizes as well as positions —
// palmy's advances scale linearly with size, so a caret measured at zoom 1
// still lands on the right glyph at 150%.
package main

import "core:fmt"
import "core:math"
import p "palmy:."

PAGE_GAP :: f32(26)
PAGE_PAD :: f32(28)

COL_DESK :: u32(0xc8c8c9)
COL_DESK_DARK :: u32(0x1c1c20)

// dark_chrome says whether the window's theme is dark. The page stays paper
// white either way — it is the document — but the desk and the ruler around
// it follow the chrome, or a dark window would hold a light-grey slab.
dark_chrome :: proc() -> bool {
	c, ok := p.parse_color("background")
	if !ok {
		return false
	}
	return int(c.r) + int(c.g) + int(c.b) < 3 * 96
}
COL_PAGE :: u32(0xffffff)
COL_INK :: u32(0x121212)
COL_SEL :: u32(0x2563eb)
COL_CODE_BG :: u32(0xf4f4f5)
COL_RULE :: u32(0xd4d4d4)
COL_FOOT :: u32(0x9a9a9a)
COL_FIND :: u32(0xfacc15)
COL_IMG_PH :: u32(0xe6e6e7)

// A selection and a find hit are washes rather than solid fills, so the text
// under them keeps its own colour.
sel_wash :: proc() -> p.Color {
	c := p.hex(COL_SEL)
	c.a = 64
	return c
}

find_wash :: proc() -> p.Color {
	c := p.hex(COL_FIND)
	c.a = 110
	return c
}

// ---------------------------------------------------------------------------
// Where the pages sit
// ---------------------------------------------------------------------------

page_view_rect :: proc(st: ^State, i: int) -> p.Rect {
	z := st.zoom
	pw, ph := PAGE_W * z, PAGE_H * z
	x := max(PAGE_PAD, (st.view.w - pw) / 2) - st.hscroll
	y := PAGE_PAD + f32(i) * (ph + PAGE_GAP) - st.scroll
	return {x, y, pw, ph}
}

doc_view_height :: proc(st: ^State) -> f32 {
	n := f32(max(1, st.lay.pages))
	return PAGE_PAD * 2 + n * PAGE_H * st.zoom + (n - 1) * PAGE_GAP
}

doc_view_width :: proc(st: ^State) -> f32 {
	return PAGE_W * st.zoom + PAGE_PAD * 2
}

// caret_view_point gives the caret's position within the workspace, which is
// what "scroll the caret into view" needs.
caret_view_point :: proc(st: ^State) -> (x, y, h: f32, ok: bool) {
	li := line_of(&st.lay, st.caret)
	if li < 0 {
		return 0, 0, 0, false
	}
	l := st.lay.lines[li]
	pr := page_view_rect(st, l.page)
	z := st.zoom
	cx := caret_x(&st.lay, li, st.caret.off)
	return pr.x + (MARGIN + cx) * z, pr.y + (MARGIN + l.y) * z, l.h * z, true
}

// ---------------------------------------------------------------------------
// Hit testing
// ---------------------------------------------------------------------------

// pos_at_view maps a point in the workspace back to a document position: the
// page it landed on, then the line, then `p.text_index_at` inside the one
// fragment that contains the x.
pos_at_view :: proc(st: ^State, vx, vy: f32) -> Pos {
	if len(st.lay.lines) == 0 {
		return {}
	}
	z := st.zoom

	// Pick the page whose band contains vy, clamping past the ends.
	page := 0
	best := max(f32)
	for i in 0 ..< st.lay.pages {
		pr := page_view_rect(st, i)
		d := f32(0)
		if vy < pr.y {
			d = pr.y - vy
		} else if vy > pr.y + pr.h {
			d = vy - (pr.y + pr.h)
		}
		if d < best {
			best, page = d, i
		}
	}
	pr := page_view_rect(st, page)
	lx := (vx - pr.x) / z - MARGIN
	ly := (vy - pr.y) / z - MARGIN

	lo, hi := page_lines(&st.lay, page)
	if lo < 0 {
		return doc_end(&st.doc)
	}
	pick := lo
	for li in lo ..= hi {
		l := st.lay.lines[li]
		if ly < l.y + l.h {
			pick = li
			break
		}
		pick = li
	}
	l := st.lay.lines[pick]
	if l.repeat {
		// A click on a repeated header row belongs to the row the model has.
		for li in lo ..= hi {
			if !st.lay.lines[li].repeat && line_blk(st.lay.lines[li]) == line_blk(l) {
				l = st.lay.lines[li]
				break
			}
		}
	}
	return line_pos(l, off_at_x(&st.lay, pick, lx))
}

// ---------------------------------------------------------------------------
// The workspace panel
// ---------------------------------------------------------------------------

draw_workspace :: proc(c: ^p.Canvas, r: p.Rect, st: ^State) {
	sc := c.scale
	p.fill_rect(c, r, p.hex(dark_chrome() ? COL_DESK_DARK : COL_DESK))
	p.push_clip(c, r)
	defer p.pop_clip(c)

	for pi in 0 ..< st.lay.pages {
		vr := page_view_rect(st, pi)
		if vr.y > st.view.h + 4 || vr.y + vr.h < -4 {
			continue
		}
		dr := p.Rect{r.x + vr.x * sc, r.y + vr.y * sc, vr.w * sc, vr.h * sc}
		rad := p.Radius{2 * sc, 2 * sc, 2 * sc, 2 * sc}
		page_shadow(c, dr, rad, sc)
		p.fill_round_rect(c, dr, rad, p.hex(COL_PAGE))
		draw_page(c, st, pi, dr, st.zoom, sc, true)
	}

	draw_ruler(c, r, st)
}

// page_shadow draws the shadow in four bands around the page instead of one
// call over the whole box.
//
// palmy's `drop_shadow` evaluates its distance field across every pixel of the
// rectangle it is given — the interior saturates to full coverage rather than
// being skipped — so a shadow under an A4 page costs 890,000 blends a frame,
// all of them immediately painted over by the page itself. There is no way to
// ask it for the ring only, so the ring is cut out here with four clips. It is
// the single biggest cost in a frame, and this takes about 90% of it away.
page_shadow :: proc(c: ^p.Canvas, dr: p.Rect, rad: p.Radius, sc: f32) {
	blur := 20 * sc
	spread := 1 * sc
	off := [2]f32{0, 7 * sc}
	col := p.Color{0, 0, 0, 78}
	m := blur + spread + off.y + 2 * sc

	o := p.Rect{dr.x - m, dr.y - m, dr.w + 2 * m, dr.h + 2 * m}
	bands := [4]p.Rect {
		{o.x, o.y, o.w, dr.y - o.y},
		{o.x, dr.y + dr.h, o.w, (o.y + o.h) - (dr.y + dr.h)},
		{o.x, dr.y, dr.x - o.x, dr.h},
		{dr.x + dr.w, dr.y, (o.x + o.w) - (dr.x + dr.w), dr.h},
	}
	for b in bands {
		if b.w <= 0 || b.h <= 0 || !p.rect_overlaps(b, c.clip) {
			continue
		}
		p.push_clip(c, b)
		p.drop_shadow(c, dr, rad, blur, spread, off, col)
		p.pop_clip(c)
	}
}

// draw_page paints one page's content into `dr`. It is used both for the
// window and, at zoom 1 onto a plain buffer, for the PNG export — so what the
// exported image shows is the same pagination the window shows.
draw_page :: proc(c: ^p.Canvas, st: ^State, pi: int, dr: p.Rect, z, sc: f32, live: bool) {
	k := z * sc
	ox := dr.x + MARGIN * k
	oy := dr.y + MARGIN * k
	lay := &st.lay

	p.push_clip(c, dr)
	defer p.pop_clip(c)

	// Tables first: the rules and the header shading sit under every line that
	// falls inside them, and they come straight out of the layout's cell boxes
	// so the window and the PDF cannot disagree about where a cell is.
	draw_table_cells(c, st, pi, ox, oy, k)

	lo, hi := page_lines(lay, pi)
	sel_lo, sel_hi, has_sel := selection(st)

	if lo >= 0 {
		for li in lo ..= hi {
			l := lay.lines[li]
			pa := &st.doc.paras[l.para]
			ly := oy + l.y * k
			lh := l.h * k
			base := ly + l.ascent * k

			// Paragraph decoration.
			switch pa.kind {
			case .Code:
				p.fill_rect(
					c,
					{ox + (l.indent - 10) * k, ly, (CONTENT_W - l.indent + 16) * k, lh},
					p.hex(COL_CODE_BG),
				)
			case .Quote:
				p.fill_rect(c, {ox + (l.indent - 16) * k, ly, 3 * k, lh}, p.hex(COL_RULE))
			case .Image:
				draw_image_para(c, pa, {ox + l.x * k, ly, l.w * k, lh})
			case .Table:
				// A line that belongs to a table paragraph is a line inside
				// one of its cells, so the cell's own paragraph has to be
				// resolved to find out whether it is a picture.
				if cp := blk_para(&st.doc, Blk{l.para, l.row, l.col, l.cpara});
				   cp != nil && cp.kind == .Image {
					draw_image_para(c, cp, {ox + l.x * k, ly, l.w * k, lh})
				}
			case .Body, .H1, .H2, .H3:
			}

			// Find highlights sit under the selection.
			if live && len(st.find) > 0 {
				draw_find_marks(c, st, li, ox, ly, lh, k)
			}

			// Prose marks go under the text and over the find wash: they are
			// about the words, not about a match the caret is chasing.
			if live && len(st.prose.alerts) > 0 {
				draw_prose_marks(c, st, li, ox, ly, lh, k)
			}

			if live && st.collab.on {
				draw_collab_line(c, st, li, ox, ly, lh, base, k)
			}

			// Selection.
			if live && has_sel {
				a := l.para == sel_lo.para ? max(l.start, sel_lo.off) : l.start
				b := l.para == sel_hi.para ? min(l.end, sel_hi.off) : l.end
				covered := !pos_less(pos(l.para, l.end), sel_lo) && !pos_less(sel_hi, pos(l.para, l.start))
				if covered && b >= a {
					x0 := caret_x(lay, li, a)
					x1 := caret_x(lay, li, b)
					w := (x1 - x0) * k
					// A selection that runs on past this paragraph swallows
					// the paragraph break, so show a sliver for it.
					if l.last && sel_hi.para > l.para {
						w += 5 * k
					} else if w < 1 && b > a {
						w = 2 * k
					}
					if w > 0.5 {
						p.fill_rect(c, {ox + x0 * k, ly, w, lh}, sel_wash())
					}
				}
			}

			// List marker on the first line of an item.
			if l.marker >= 0 && l.fc > 0 {
				f := lay.frags[l.fi]
				label := l.marker == 0 ? "•" : fmt.tprintf("%d.", l.marker)
				mw := p.text_width(layout_fonts, label, f.size * k, f.fam, f.wt)
				mx := ox + (l.indent - 10) * k - mw
				p.draw_text(c, layout_fonts, label, mx, base, f.size * k, p.hex(COL_INK), f.fam, f.wt)
			}

			// The text itself.
			for j in 0 ..< l.fc {
				f := lay.frags[l.fi + j]
				if f.end <= f.start {
					continue
				}
				s := frag_text(lay, l, f)
				col := f.color == 0 ? p.hex(COL_INK) : p.hex(f.color & 0xffffff)
				fx := ox + (l.x + f.x) * k
				p.draw_text(c, layout_fonts, s, fx, base, f.size * k, col, f.fam, f.wt)
				if f.underline {
					uy := base + f.size * 0.14 * k
					p.fill_rect(c, {fx, uy, f.w * k, max(1, f.size * 0.07 * k)}, col)
				}
			}
		}
	}

	// A faint page number in the footer, which is most of what makes a stack
	// of white rectangles read as a document.
	{
		label := fmt.tprintf("%d", pi + 1)
		fs := 10 * k
		w := p.text_width(layout_fonts, label, fs, .Sans, .Regular)
		p.draw_text(
			c,
			layout_fonts,
			label,
			dr.x + (dr.w - w) / 2,
			dr.y + dr.h - MARGIN * k * 0.42,
			fs,
			p.hex(COL_FOOT),
			.Sans,
			.Regular,
		)
	}

	if live && st.collab.on {
		draw_remote_carets(c, st, pi, ox, oy, k)
	}

	// The caret, last, so it is never painted over.
	if live && st.focus_doc {
		li := line_of(&st.lay, st.caret)
		if li >= 0 && st.lay.lines[li].page == pi && st.caret_on {
			l := st.lay.lines[li]
			cx := caret_x(&st.lay, li, st.caret.off)
			p.fill_rect(
				c,
				{ox + cx * k - max(0.5, 0.75 * k), oy + l.y * k + 1 * k, max(1.4, 1.7 * k), l.h * k - 2 * k},
				p.hex(COL_INK),
			)
		}
	}
}

// draw_find_marks highlights every occurrence of the search term on a line.
// The match the caret is sitting on is left alone: it already wears the
// selection, and two washes on top of each other read as neither.
//
// The search runs over the whole block, not over the line's slice, because
// whole-word mode has to see the characters either side of a match and a match
// that starts on the previous line is not this line's business.
draw_find_marks :: proc(c: ^p.Canvas, st: ^State, li: int, ox, ly, lh, k: f32) {
	l := st.lay.lines[li]
	hay := block_string(&st.lay, l.blk)
	needle := string(st.find[:])
	if len(needle) == 0 || l.end > len(hay) {
		return
	}
	sel_lo, sel_hi, has_sel := selection(st)
	at := l.start
	for at <= l.end {
		i := find_index(hay, needle, at, !st.find_case, st.find_word)
		if i < 0 || i >= l.end {
			break
		}
		a := i
		b := min(i + len(needle), l.end)
		at = i + max(1, len(needle))
		if has_sel && sel_lo == line_pos(l, a) && sel_hi == line_pos(l, i + len(needle)) {
			continue
		}
		x0 := caret_x(&st.lay, li, a)
		x1 := caret_x(&st.lay, li, b)
		if x1 > x0 {
			p.fill_rect(c, {ox + x0 * k, ly, (x1 - x0) * k, lh}, find_wash())
		}
	}
}

// ---------------------------------------------------------------------------
// Tables and images
// ---------------------------------------------------------------------------

// draw_table_cells paints the header shading and the cell rules for every
// table box on one page. The geometry is the layout's, not recomputed here, so
// a rule is in the same place on screen, in the PNG and in the PDF.
draw_table_cells :: proc(c: ^p.Canvas, st: ^State, page: int, ox, oy, k: f32) {
	lay := &st.lay
	lo, hi := page_cells(lay, page)
	if lo < 0 {
		return
	}
	rule := max(1, TABLE_RULE * k)
	for i in lo ..= hi {
		cb := lay.cells[i]
		if cb.para < 0 || cb.para >= len(st.doc.paras) {
			continue
		}
		t := st.doc.paras[cb.para].table
		x := ox + cb.x * k
		y := oy + cb.y * k
		w := cb.w * k
		h := cb.h * k
		if cb.header {
			p.fill_rect(c, {x, y, w, h}, p.hex(COL_TABLE_HEAD))
		}
		if t == nil || !t.borders {
			continue
		}
		col := p.hex(COL_TABLE_RULE)
		// All four edges of every cell. Neighbouring cells overlap on their
		// shared edge, which is exactly what a single-weight grid wants and
		// means a cell never has a missing side at the end of a row.
		p.fill_rect(c, {x, y, w, rule}, col)
		p.fill_rect(c, {x, y + h - rule, w, rule}, col)
		p.fill_rect(c, {x, y, rule, h}, col)
		p.fill_rect(c, {x + w - rule, y, rule, h}, col)
	}
}

// draw_image_para blits one picture into its line box, or draws a framed
// placeholder when the bytes would not decode — a document that has travelled
// should say what it is missing rather than closing the gap silently.
draw_image_para :: proc(c: ^p.Canvas, pa: ^Paragraph, dst: p.Rect) {
	if dst.w <= 0 || dst.h <= 0 {
		return
	}
	if pa.img != nil && len(pa.img.px) >= pa.img.w * pa.img.h && pa.img.w > 0 {
		img := p.Image {
			px = pa.img.px[:pa.img.w * pa.img.h],
			w  = pa.img.w,
			h  = pa.img.h,
		}
		p.draw_image(c, img, dst)
		return
	}
	p.fill_rect(c, dst, p.hex(COL_IMG_PH))
	p.fill_rect(c, {dst.x, dst.y, dst.w, 1}, p.hex(COL_RULE))
	p.fill_rect(c, {dst.x, dst.y + dst.h - 1, dst.w, 1}, p.hex(COL_RULE))
	p.fill_rect(c, {dst.x, dst.y, 1, dst.h}, p.hex(COL_RULE))
	p.fill_rect(c, {dst.x + dst.w - 1, dst.y, 1, dst.h}, p.hex(COL_RULE))
}

// draw_ruler is the strip across the top of the workspace: the page's measure
// with its margins shaded, ticked every quarter inch.
draw_ruler :: proc(c: ^p.Canvas, r: p.Rect, st: ^State) {
	sc := c.scale
	h := f32(20)
	dr := p.Rect{r.x, r.y, r.w, h * sc}
	dark := dark_chrome()
	p.fill_rect(c, dr, p.hex(dark ? 0x232327 : 0xe9e9ea))
	p.fill_rect(c, {dr.x, dr.y + dr.h - sc, dr.w, sc}, p.hex(dark ? 0x34343a : 0xc0c0c1))

	z := st.zoom
	pw := PAGE_W * z
	px := r.x + (max(PAGE_PAD, (st.view.w - pw) / 2) - st.hscroll) * sc
	p.push_clip(c, dr)
	defer p.pop_clip(c)

	// The measure in white, the margins in grey.
	p.fill_rect(c, {px, dr.y + 4 * sc, pw * sc, dr.h - 8 * sc}, p.hex(dark ? 0x3a3a40 : 0xbdbdbe))
	p.fill_rect(
		c,
		{px + MARGIN * z * sc, dr.y + 4 * sc, CONTENT_W * z * sc, dr.h - 8 * sc},
		p.hex(dark ? 0x52525a : 0xfdfdfd),
	)

	inch := 96 * z * sc
	n := int(PAGE_W) / 96 + 1
	for i in 0 ..< n * 4 {
		x := px + f32(i) * inch / 4
		if x < dr.x || x > dr.x + dr.w || x > px + pw * sc + 0.5 {
			continue
		}
		major := i % 4 == 0
		th := major ? dr.h * 0.42 : dr.h * 0.22
		p.fill_rect(c, {x, dr.y + (dr.h - th) / 2, max(1, sc), th}, p.hex(major ? 0x8a8a8b : 0xaeaeaf))
		if major && i > 0 {
			label := fmt.tprintf("%d", i / 4)
			fs := 8 * sc
			w := p.text_width(layout_fonts, label, fs, .Sans, .Regular)
			p.draw_text(
				c,
				layout_fonts,
				label,
				x - w / 2,
				dr.y + dr.h * 0.5 + fs * 0.36,
				fs,
				p.hex(0x6b6b6c),
				.Sans,
				.Regular,
			)
		}
	}
}

// ---------------------------------------------------------------------------
// PNG export
// ---------------------------------------------------------------------------

// export_page_png renders one page at 100% into its own buffer and writes it
// out, which is the easiest way to see that pagination is real.
export_page_png :: proc(st: ^State, path: string, pi: int) -> bool {
	w, h := int(PAGE_W), int(PAGE_H)
	px := make([]u32, w * h)
	defer delete(px)
	c := p.canvas_from(px, w, h, 1)
	defer p.canvas_destroy(&c)

	p.fill_rect(&c, {0, 0, f32(w), f32(h)}, p.hex(COL_PAGE))
	draw_page(&c, st, pi, {0, 0, f32(w), f32(h)}, 1, 1, false)

	rgba := make([]u8, w * h * 4)
	defer delete(rgba)
	for i in 0 ..< w * h {
		v := px[i]
		rgba[i * 4 + 0] = u8((v >> 16) & 0xff)
		rgba[i * 4 + 1] = u8((v >> 8) & 0xff)
		rgba[i * 4 + 2] = u8(v & 0xff)
		rgba[i * 4 + 3] = 255
	}
	return p.write_png_rgba(path, rgba, w, h)
}

export_all_pages_png :: proc(st: ^State, base: string) -> int {
	n := 0
	for pi in 0 ..< st.lay.pages {
		path := fmt.tprintf("%s-p%d.png", base, pi + 1)
		if export_page_png(st, path, pi) {
			n += 1
		}
	}
	return n
}

// blink_phase keeps the caret on for 620ms of every 1060, which is the rate
// the rest of these apps use.
blink_phase :: proc(t: f32) -> bool {
	return math.mod(f64(t), 1.06) < 0.62
}
