// Drawing a page.
//
// The reflow engine has already decided where every fragment of every line
// goes, to the pixel. Turning that into palmy nodes would mean a few thousand
// elements per page, all of them absolutely positioned, so the page is drawn
// straight onto the canvas through `p.pixels` instead: one element, and the
// rasterizer's own `draw_text` for each fragment.
//
// Paged and continuous mode differ only in what the element's height is and
// which lines are inside it. Continuous mode makes the element as tall as the
// whole chapter and lets palmy's own scroll container move it, which is why
// there is no scroll arithmetic here.
package main

import "core:strings"
import p "palmy:."

Palette :: struct {
	page:   p.Color,
	ink:    p.Color,
	faint:  p.Color,
	accent: p.Color,
	rule:   p.Color,
	mark:   p.Color, // highlight wash
	found:  p.Color, // search hit wash
}

palette_of :: proc(t: Theme) -> Palette {
	switch t {
	case .Light:
		return {
			page = p.hex(0xfdfdfb),
			ink = p.hex(0x1b1b19),
			faint = p.hex(0x76736c),
			accent = p.hex(0x1d4ed8),
			rule = p.hex(0xe4e2dc),
			mark = p.rgba(250, 209, 64, 108),
			found = p.rgba(84, 153, 255, 88),
		}
	case .Sepia:
		return {
			page = p.hex(0xf5edda),
			ink = p.hex(0x3b3127),
			faint = p.hex(0x8a7a61),
			accent = p.hex(0x9a5523),
			rule = p.hex(0xdfd3b8),
			mark = p.rgba(219, 168, 56, 115),
			found = p.rgba(89, 128, 217, 88),
		}
	case .Dark:
		return {
			page = p.hex(0x15171b),
			ink = p.hex(0xd6d4cf),
			faint = p.hex(0x85847f),
			accent = p.hex(0x7fa6f8),
			rule = p.hex(0x2b2e35),
			mark = p.rgba(184, 140, 31, 108),
			found = p.rgba(77, 117, 217, 118),
		}
	}
	return {}
}

// Page_Draw is everything the draw procedure needs. It lives in the model, not
// on a stack frame: `p.pixels` borrows it until the frame is painted, which is
// after the whole tree has been built.
Page_Draw :: struct {
	fonts:   ^p.Fonts,
	doc:     ^Doc,
	book:    ^Book,
	pal:     Palette,
	lines:   []Line,
	frags:   []Frag,
	// The y of the first line, subtracted so a page's lines start at the top
	// of the element. Zero in continuous mode.
	y0:      f32,
	// A range to wash, for the selected search hit.
	hit_block: int,
	hit_start: int,
	hit_end:   int,
	// The live selection, which is what a highlight is made from.
	sel_block: int,
	sel_start: int,
	sel_end:   int,
	// Highlights in this chapter.
	marks:   []Mark,
	chapter: int,
	measure: f32,
}

// draw_page is the custom painter. Everything in it is arithmetic against
// numbers the layout already produced.
draw_page :: proc(c: ^p.Canvas, r: p.Rect, s: ^Page_Draw) {
	for ln in s.lines {
		top := r.y + ln.y - s.y0
		if top + ln.h < -8 || top > f32(c.h) + 8 {
			continue
		}
		x0 := r.x + ln.x
		base := top + ln.ascent

		switch ln.kind {
		case .Rule:
			p.fill_rect(
				c,
				{r.x + s.measure * 0.3, top + ln.h / 2, s.measure * 0.4, 1},
				s.pal.rule,
			)
			continue
		case .Image:
			if img, ok := book_image(s.book, ln.image); ok && img.w > 0 {
				p.draw_image(c, img, {x0, top, ln.w, ln.h})
			} else {
				// A placeholder that reads as "a picture goes here", not as a
				// rendering failure.
				p.stroke_round_rect(c, {x0, top, max(ln.w, 40), ln.h}, {4, 4, 4, 4}, 1, s.pal.rule)
				alt := ""
				if ln.image >= 0 && int(ln.image) < len(s.doc.images) {
					alt = s.doc.images[ln.image].alt
				}
				if alt != "" {
					p.draw_text(
						c,
						s.fonts,
						alt,
						x0 + 8,
						top + ln.h / 2,
						12,
						s.pal.faint,
						.Sans,
						.Regular,
					)
				}
			}
			continue
		case .Para, .H1, .H2, .H3, .H4, .Quote, .Code, .Item:
		}

		// A list marker, or a quote bar.
		if ln.marker >= 0 {
			mx := x0 - 1.1 * ln.h * 0.62
			if ln.marker == 0 {
				p.fill_circle(c, mx + 3, base - ln.h * 0.22, 2.2, s.pal.faint)
			} else {
				label := tfmt("%d.", ln.marker)
				w := p.text_width(s.fonts, label, ln.h * 0.56, .Sans, .Regular)
				p.draw_text(
					c,
					s.fonts,
					label,
					mx + 10 - w,
					base,
					ln.h * 0.56,
					s.pal.faint,
					.Sans,
					.Regular,
				)
			}
		}
		if ln.kind == .Quote {
			bar_x := r.x + ln.x - 14
			p.fill_rect(c, {max(r.x, bar_x), top, 2, ln.h}, s.pal.rule)
		}

		// Washes behind the text: highlights first, then the selected search
		// hit on top of them.
		for m in s.marks {
			if m.kind != .Highlight || m.block != ln.block {
				continue
			}
			wash_range(c, s, ln, x0, top, m.off, m.end, s.pal.mark)
		}
		if s.hit_block == ln.block && s.hit_end > s.hit_start {
			wash_range(c, s, ln, x0, top, s.hit_start, s.hit_end, s.pal.found)
		}
		if s.sel_block == ln.block && s.sel_end > s.sel_start {
			wash_range(c, s, ln, x0, top, s.sel_start, s.sel_end, s.pal.found)
		}

		for k in 0 ..< ln.fc {
			fi := ln.fi + k
			if fi < 0 || fi >= len(s.frags) {
				continue
			}
			f := s.frags[fi]
			text := frag_text(s.doc, ln.block, f)
			if text == "" {
				continue
			}
			col := f.link >= 0 ? s.pal.accent : s.pal.ink
			fx := x0 + f.x
			p.draw_text(
				c,
				s.fonts,
				text,
				fx,
				base + f.dy,
				f.size,
				col,
				f.fam,
				f.wt,
				0,
				f.sl,
			)
			if f.underline {
				p.fill_rect(c, {fx, base + f.dy + f.size * 0.12, f.w, max(1, f.size / 16)}, col)
			}
			if f.strike {
				p.fill_rect(c, {fx, base + f.dy - f.size * 0.26, f.w, max(1, f.size / 16)}, col)
			}
		}
	}
}

// frag_text is a fragment's bytes. Looked up live rather than stored, because
// the document's text arena is a [dynamic] and a stored slice would dangle.
frag_text :: proc(d: ^Doc, block: int, f: Frag) -> string {
	s := block_text(d, block)
	a := clamp(f.start, 0, len(s))
	b := clamp(f.end, a, len(s))
	return s[a:b]
}

// wash_range paints a background behind [from, to) of a line, measuring
// through the fragments so that a highlight that starts mid-word lands in the
// right place.
@(private = "file")
wash_range :: proc(
	c: ^p.Canvas,
	s: ^Page_Draw,
	ln: Line,
	x0, top: f32,
	from, to: int,
	col: p.Color,
) {
	if to <= ln.start || from >= ln.vis_end {
		return
	}
	text := block_text(s.doc, ln.block)
	for k in 0 ..< ln.fc {
		fi := ln.fi + k
		if fi < 0 || fi >= len(s.frags) {
			continue
		}
		f := s.frags[fi]
		a := max(f.start, from)
		b := min(f.end, to)
		if b <= a {
			continue
		}
		pre := f32(0)
		if a > f.start && f.start < len(text) {
			pre = p.text_width(
				s.fonts,
				text[clamp(f.start, 0, len(text)):clamp(a, 0, len(text))],
				f.size,
				f.fam,
				f.wt,
				0,
				f.sl,
			)
		}
		w := p.text_width(
			s.fonts,
			text[clamp(a, 0, len(text)):clamp(b, 0, len(text))],
			f.size,
			f.fam,
			f.wt,
			0,
			f.sl,
		)
		if w <= 0 {
			continue
		}
		p.fill_round_rect(
			c,
			{x0 + f.x + pre - 1, top + 1, w + 2, ln.h - 2},
			{2, 2, 2, 2},
			col,
		)
	}
}

// ---------------------------------------------------------------------------
// Hit testing
// ---------------------------------------------------------------------------

// page_line_at finds the line under a point, in element coordinates.
page_line_at :: proc(s: ^Page_Draw, lx, ly: f32) -> int {
	y := ly + s.y0
	for ln, i in s.lines {
		if y >= ln.y && y < ln.y + ln.h {
			return i
		}
	}
	return -1
}

// page_offset_at is the byte offset in a line's block under an x position,
// which is what turns a click into a position to highlight from.
page_offset_at :: proc(s: ^Page_Draw, li: int, lx: f32) -> int {
	if li < 0 || li >= len(s.lines) {
		return -1
	}
	ln := s.lines[li]
	text := block_text(s.doc, ln.block)
	for k in 0 ..< ln.fc {
		fi := ln.fi + k
		if fi < 0 || fi >= len(s.frags) {
			continue
		}
		f := s.frags[fi]
		if lx < ln.x + f.x + f.w || k == ln.fc - 1 {
			a := clamp(f.start, 0, len(text))
			b := clamp(f.end, a, len(text))
			inner := p.text_index_at(s.fonts, text[a:b], f.size, lx - (ln.x + f.x), f.fam, f.wt, 0, f.sl)
			return a + inner
		}
	}
	return ln.start
}

// page_link_at is the link under a point, or -1.
page_link_at :: proc(s: ^Page_Draw, lx, ly: f32) -> i32 {
	li := page_line_at(s, lx, ly)
	if li < 0 {
		return -1
	}
	ln := s.lines[li]
	for k in 0 ..< ln.fc {
		fi := ln.fi + k
		if fi < 0 || fi >= len(s.frags) {
			continue
		}
		f := s.frags[fi]
		if f.link >= 0 && lx >= ln.x + f.x && lx < ln.x + f.x + f.w {
			return f.link
		}
	}
	return -1
}

// ---------------------------------------------------------------------------
// Text of a range, for a highlight's label
// ---------------------------------------------------------------------------

range_text :: proc(d: ^Doc, block, from, to: int, allocator := context.allocator) -> string {
	s := block_text(d, block)
	a := clamp(from, 0, len(s))
	b := clamp(to, a, len(s))
	return strings.clone(s[a:b], allocator)
}
