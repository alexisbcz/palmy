// .pptx — PresentationML.
//
// A deck that only this program can open is a deck nobody can be sent. This
// writes the real thing: an OPC package (see zip.odin, method 0 "stored") of
// PresentationML parts that PowerPoint, Keynote and LibreOffice Impress all
// open as an editable deck, with every shape still a shape and every text box
// still editable text.
//
// The one number that must be right is the unit. DrawingML measures in EMU —
// English Metric Units, 914400 to the inch — and a 16:9 slide is
// 12192000 x 6858000 EMU, which is 13 1/3 x 7 1/2 inches. This program's slide
// space is 1280 x 720, so
//
//     12192000 / 1280 == 9525     and     6858000 / 720 == 9525
//
// exactly, in both axes. Every coordinate, size and stroke width multiplies by
// 9525 and nothing else. Get that factor wrong and the deck is still a valid
// file; it is just a file with everything in the wrong place, which is why the
// test suite pins the slide size, the factor and a known element's position.
//
// The other conversions:
//
//   * Rotation is in 60000ths of a degree, clockwise, like this program's.
//   * Font sizes are in hundredths of a point. A 1280-unit slide is 960pt
//     wide, so one slide unit is 0.75pt and `sz = size * 75`.
//   * Alpha is in thousandths of a percent: 100000 is opaque.
//   * An image crop is in the same thousandths-of-a-percent, which is how the
//     "cover" fit this program draws with is reproduced in a format that only
//     knows how to stretch.
//
// Theme slots are resolved to literal colours on the way out: a reader has no
// idea what this deck's "accent" means, and a file that renders differently
// elsewhere is not an interchange file.
package main

import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"
import p "palmy:."

EMU_PER_UNIT :: 9525
PPTX_SLIDE_CX :: 12192000
PPTX_SLIDE_CY :: 6858000
PPTX_NOTES_CX :: 6858000
PPTX_NOTES_CY :: 9144000

// One slide unit is 0.75pt, and `sz` counts hundredths of a point.
PPTX_SZ_PER_UNIT :: 75

emu :: proc(v: f32) -> i64 {
	return i64(math.round(f64(v) * EMU_PER_UNIT))
}

// ---------------------------------------------------------------------------
// Escaping
// ---------------------------------------------------------------------------

xml_escape :: proc(s: string, allocator := context.temp_allocator) -> string {
	need := false
	for i in 0 ..< len(s) {
		switch s[i] {
		case '&', '<', '>', '"', '\'', 0 ..< 0x09, 0x0b, 0x0c, 0x0e ..< 0x20:
			need = true
		}
		if need {
			break
		}
	}
	if !need {
		return s
	}
	b := strings.builder_make(allocator)
	for i in 0 ..< len(s) {
		switch c := s[i]; c {
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
		case '\t':
			strings.write_byte(&b, c)
		case 0 ..< 0x20:
			// XML 1.0 cannot carry these at all, escaped or not.
		case:
			strings.write_byte(&b, c)
		}
	}
	return strings.to_string(b)
}

// ---------------------------------------------------------------------------
// Colour
// ---------------------------------------------------------------------------

// srgb prints a resolved paint as the six hex digits DrawingML wants. The
// alpha channel is carried separately, because `a:srgbClr` has no alpha digit.
srgb :: proc(c: p.Color) -> string {
	return fmt.tprintf("%02X%02X%02X", c.r, c.g, c.b)
}

// pct is DrawingML's thousandths of a percent, clamped to the legal range.
pct :: proc(x: f32) -> int {
	return clamp(int(math.round(f64(x) * 100000)), 0, 100000)
}

// solid_fill writes a solid fill, folding an opacity multiplier into the
// colour's own alpha so a 50%-opaque element over a 50%-alpha paint lands at
// 25% the way it does on screen.
@(private = "file")
solid_fill :: proc(b: ^strings.Builder, tag: string, c: p.Color, alpha: f32) {
	a := f32(c.a) / 255 * clamp(alpha, 0, 1)
	if a >= 0.999 {
		fmt.sbprintf(b, "<%s><a:srgbClr val=\"%s\"/></%s>", tag, srgb(c), tag)
		return
	}
	fmt.sbprintf(b, "<%s><a:srgbClr val=\"%s\"><a:alpha val=\"%d\"/></a:srgbClr></%s>", tag, srgb(c), pct(a), tag)
}

// ---------------------------------------------------------------------------
// Geometry
// ---------------------------------------------------------------------------

// xfrm writes a shape's placement. A rotation is in 60000ths of a degree and
// turns about the shape's centre, which is this program's convention too.
@(private = "file")
xfrm :: proc(b: ^strings.Builder, x, y, w, h, rot: f32) {
	if rot != 0 {
		fmt.sbprintf(b, "<a:xfrm rot=\"%d\">", int(math.round(f64(rot) * 60000)))
	} else {
		strings.write_string(b, "<a:xfrm>")
	}
	fmt.sbprintf(
		b,
		"<a:off x=\"%d\" y=\"%d\"/><a:ext cx=\"%d\" cy=\"%d\"/></a:xfrm>",
		emu(x),
		emu(y),
		emu(max(w, 1)),
		emu(max(h, 1)),
	)
}

// round_rect_adj is DrawingML's corner adjustment: a fraction of half the
// shorter side, in thousandths of a percent, capped at a full semicircle.
round_rect_adj :: proc(w, h, radius: f32) -> int {
	short := min(abs(w), abs(h))
	if short <= 0 || radius <= 0 {
		return 0
	}
	return clamp(int(math.round(f64(radius / short) * 100000)), 0, 50000)
}

// ---------------------------------------------------------------------------
// Text
// ---------------------------------------------------------------------------

@(private = "file")
algn_name :: proc(a: Halign) -> string {
	switch a {
	case .Left:
		return "l"
	case .Center:
		return "ctr"
	case .Right:
		return "r"
	}
	return "l"
}

@(private = "file")
anchor_name :: proc(v: Valign) -> string {
	switch v {
	case .Top:
		return "t"
	case .Middle:
		return "ctr"
	case .Bottom:
		return "b"
	}
	return "t"
}

// The typeface a reader will actually have. The deck is set in Geist, which
// nobody else has installed, so the export names the nearest face that every
// system ships — and says so in the report rather than pretending otherwise.
PPTX_SANS :: "Arial"
PPTX_MONO :: "Courier New"

// Bullet indentation, in slide units, matching the renderer's `size * 1.15`.
@(private = "file")
bullet_indent :: proc(size: f32) -> f32 {
	return size * 1.15
}

// write_text_body turns an element's text into PresentationML paragraphs.
// Each line of the source is one paragraph — PowerPoint wraps inside a
// paragraph exactly as this renderer does inside a box — and a line that
// begins with "- " in a bulleted box becomes a real bullet rather than a
// hyphen, so the deck is editable rather than a transcription.
@(private = "file")
write_text_body :: proc(b: ^strings.Builder, th: ^Theme, e: ^Element) {
	spec := TYPE_SCALE[e.style]
	size := text_size(e)
	col := paint(th, e.color)
	if e.color == SLOT_NONE {
		col = spec.muted ? argb(th.muted) : argb(th.fg)
	}
	bold := e.bold || spec.bold
	face := th.mono ? PPTX_MONO : PPTX_SANS
	pad := has_paint(e.fill) ? f32(20) : 0

	fmt.sbprintf(
		b,
		"<p:txBody><a:bodyPr wrap=\"square\" lIns=\"%d\" tIns=\"%d\" rIns=\"%d\" bIns=\"%d\" anchor=\"%s\"><a:normAutofit/></a:bodyPr><a:lstStyle/>",
		emu(pad),
		emu(pad),
		emu(pad),
		emu(pad),
		anchor_name(e.valign),
	)

	text := e.text
	if text == "" {
		// An empty box still needs one paragraph, or the part is invalid.
		fmt.sbprintf(
			b,
			"<a:p><a:pPr algn=\"%s\"/><a:endParaRPr lang=\"en-US\" sz=\"%d\"/></a:p>",
			algn_name(e.halign),
			int(size * PPTX_SZ_PER_UNIT),
		)
		strings.write_string(b, "</p:txBody>")
		return
	}

	i := 0
	for {
		nl := strings.index_byte(text[i:], '\n')
		end := nl < 0 ? len(text) : i + nl
		para := text[i:end]

		bullet := e.style == .Bullets && (strings.has_prefix(para, "- ") || strings.has_prefix(para, "• "))
		ps := i // where the paragraph's words start in e.text
		if bullet {
			skip := strings.has_prefix(para, "- ") ? 2 : len("• ")
			para = para[skip:]
			ps += skip
		}

		strings.write_string(b, "<a:p><a:pPr")
		fmt.sbprintf(b, " algn=\"%s\"", algn_name(e.halign))
		if bullet {
			ind := bullet_indent(size)
			fmt.sbprintf(b, " marL=\"%d\" indent=\"%d\"", emu(ind), -emu(ind))
		} else {
			strings.write_string(b, " marL=\"0\" indent=\"0\"")
		}
		strings.write_string(b, ">")
		if spec.leading != 1 {
			fmt.sbprintf(b, "<a:lnSpc><a:spcPct val=\"%d\"/></a:lnSpc>", int(math.round(f64(spec.leading) * 100000)))
		}
		if bullet {
			fmt.sbprintf(b, "<a:buClr><a:srgbClr val=\"%s\"/></a:buClr><a:buChar char=\"•\"/>", srgb(paint(th, SLOT_ACCENT)))
		} else {
			strings.write_string(b, "<a:buNone/>")
		}
		strings.write_string(b, "</a:pPr>")

		if para != "" {
			// One `a:r` per styled segment: a run's bold, italic, colour and
			// size become that `a:r`'s own `a:rPr`, which is exactly the
			// model DrawingML has. A box without runs is one `a:r` per
			// paragraph, as it always was.
			for sg in text_segments(e, ps, end) {
				rsize := sg.s.size > 0 ? sg.s.size : size
				fmt.sbprintf(
					b,
					"<a:r><a:rPr lang=\"en-US\" sz=\"%d\" b=\"%d\"",
					int(rsize * PPTX_SZ_PER_UNIT),
					bold || sg.s.bold ? 1 : 0,
				)
				if sg.s.italic {
					strings.write_string(b, " i=\"1\"")
				}
				strings.write_string(b, " dirty=\"0\"")
				if spec.tracking != 0 {
					// `spc` is in hundredths of a point, and the tracking is a
					// fraction of the type size.
					fmt.sbprintf(b, " spc=\"%d\"", int(math.round(f64(spec.tracking * rsize) * PPTX_SZ_PER_UNIT)))
				}
				strings.write_string(b, ">")
				rc := col
				if sg.s.color != SLOT_NONE {
					rc = paint(th, sg.s.color)
				}
				solid_fill(b, "a:solidFill", rc, clamp(e.opacity, 0, 1))
				fmt.sbprintf(b, "<a:latin typeface=\"%s\"/><a:cs typeface=\"%s\"/></a:rPr>", face, face)
				fmt.sbprintf(b, "<a:t>%s</a:t></a:r>", xml_escape(e.text[sg.start:sg.end]))
			}
		} else {
			fmt.sbprintf(b, "<a:endParaRPr lang=\"en-US\" sz=\"%d\"/>", int(size * PPTX_SZ_PER_UNIT))
		}
		strings.write_string(b, "</a:p>")

		if nl < 0 {
			break
		}
		i = end + 1
		if i > len(text) {
			break
		}
		if i == len(text) {
			fmt.sbprintf(b, "<a:p><a:pPr algn=\"%s\"/><a:endParaRPr lang=\"en-US\" sz=\"%d\"/></a:p>", algn_name(e.halign), int(size * PPTX_SZ_PER_UNIT))
			break
		}
	}
	strings.write_string(b, "</p:txBody>")
}

// ---------------------------------------------------------------------------
// Shapes
// ---------------------------------------------------------------------------

@(private = "file")
Pptx_Media :: struct {
	name: string, // the part name inside ppt/media
	rid:  string,
	data: []u8,
	ext:  string,
}

// write_element emits one element as a PresentationML shape, picture or
// connector. `id` is the shape id, which must be unique within the slide and
// must not be 1 — that is the group shape every tree starts with.
@(private = "file")
write_element :: proc(b: ^strings.Builder, th: ^Theme, e: ^Element, id: int, rid: string, ph: Pptx_Ph = {}) {
	alpha := clamp(e.opacity, 0, 1)

	switch e.kind {
	case .Rect, .Ellipse, .Text:
		if e.kind == .Text && ph.tag != "" {
			// A placeholder: the slide's title or body, as PowerPoint's
			// outline view and every accessibility tool read it. It keeps its
			// own geometry and formatting below, so it renders exactly as a
			// text box would; the placeholder is what it *is*.
			fmt.sbprintf(
				b,
				"<p:sp><p:nvSpPr><p:cNvPr id=\"%d\" name=\"%s %d%s\"/><p:cNvSpPr><a:spLocks noGrp=\"1\"/></p:cNvSpPr><p:nvPr>%s</p:nvPr></p:nvSpPr><p:spPr>",
				id,
				ph.name,
				id,
				style_suffix(e),
				ph.tag,
			)
		} else {
			name := e.kind == .Text ? "TextBox" : KIND_NAMES[e.kind]
			if ph.name != "" {
				name = ph.name
			}
			fmt.sbprintf(
				b,
				"<p:sp><p:nvSpPr><p:cNvPr id=\"%d\" name=\"%s %d%s\"/><p:cNvSpPr%s/><p:nvPr/></p:nvSpPr><p:spPr>",
				id,
				name,
				id,
				e.kind == .Text ? style_suffix(e) : "",
				e.kind == .Text ? " txBox=\"1\"" : "",
			)
		}
		xfrm(b, e.x, e.y, e.w, e.h, e.rotation)
		if e.kind == .Ellipse {
			strings.write_string(b, "<a:prstGeom prst=\"ellipse\"><a:avLst/></a:prstGeom>")
		} else if e.radius > 0 {
			fmt.sbprintf(
				b,
				"<a:prstGeom prst=\"roundRect\"><a:avLst><a:gd name=\"adj\" fmla=\"val %d\"/></a:avLst></a:prstGeom>",
				round_rect_adj(e.w, e.h, e.radius),
			)
		} else {
			strings.write_string(b, "<a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom>")
		}
		if has_paint(e.fill) {
			solid_fill(b, "a:solidFill", paint(th, e.fill), alpha * clamp(e.fill_a, 0, 1))
		} else {
			strings.write_string(b, "<a:noFill/>")
		}
		if has_paint(e.stroke) && e.stroke_w > 0 {
			fmt.sbprintf(b, "<a:ln w=\"%d\">", emu(e.stroke_w))
			solid_fill(b, "a:solidFill", paint(th, e.stroke), alpha)
			strings.write_string(b, "</a:ln>")
		} else {
			strings.write_string(b, "<a:ln><a:noFill/></a:ln>")
		}
		strings.write_string(b, "</p:spPr>")
		if e.kind == .Text {
			write_text_body(b, th, e)
		} else {
			// Every `p:sp` needs a text body even when it holds no text.
			strings.write_string(b, "<p:txBody><a:bodyPr/><a:lstStyle/><a:p><a:endParaRPr lang=\"en-US\"/></a:p></p:txBody>")
		}
		strings.write_string(b, "</p:sp>")

	case .Line, .Arrow:
		// A connector runs corner to corner of its box; a negative width or
		// height is spelled as a flip, which is what keeps a line drawn
		// right-to-left pointing the same way it does on screen.
		col := has_paint(e.stroke) ? paint(th, e.stroke) : paint(th, SLOT_FG)
		x := min(e.x, e.x + e.w)
		y := min(e.y, e.y + e.h)
		fmt.sbprintf(
			b,
			"<p:cxnSp><p:nvCxnSpPr><p:cNvPr id=\"%d\" name=\"%s %d\"/><p:cNvCxnSpPr/><p:nvPr/></p:nvCxnSpPr><p:spPr>",
			id,
			KIND_NAMES[e.kind],
			id,
		)
		if e.rotation != 0 {
			fmt.sbprintf(b, "<a:xfrm rot=\"%d\"", int(math.round(f64(e.rotation) * 60000)))
		} else {
			strings.write_string(b, "<a:xfrm")
		}
		if e.w < 0 {
			strings.write_string(b, " flipH=\"1\"")
		}
		if e.h < 0 {
			strings.write_string(b, " flipV=\"1\"")
		}
		fmt.sbprintf(
			b,
			"><a:off x=\"%d\" y=\"%d\"/><a:ext cx=\"%d\" cy=\"%d\"/></a:xfrm>",
			emu(x),
			emu(y),
			emu(abs(e.w)),
			emu(abs(e.h)),
		)
		strings.write_string(b, "<a:prstGeom prst=\"line\"><a:avLst/></a:prstGeom>")
		fmt.sbprintf(b, "<a:ln w=\"%d\" cap=\"rnd\">", emu(max(e.stroke_w, 1)))
		solid_fill(b, "a:solidFill", col, alpha)
		if e.kind == .Arrow {
			// `len`/`w` are DrawingML's three-step sizes, not a length, so the
			// head is "large" when this deck's head is long for its stroke.
			big := e.head > max(e.stroke_w, 1) * 5
			fmt.sbprintf(b, "<a:tailEnd type=\"triangle\" w=\"%s\" len=\"%s\"/>", big ? "lg" : "med", big ? "lg" : "med")
		}
		strings.write_string(b, "</a:ln></p:spPr></p:cxnSp>")

	case .Image:
		fmt.sbprintf(
			b,
			"<p:pic><p:nvPicPr><p:cNvPr id=\"%d\" name=\"Picture %d\"/><p:cNvPicPr><a:picLocks noChangeAspect=\"1\"/></p:cNvPicPr><p:nvPr/></p:nvPicPr><p:blipFill>",
			id,
			id,
		)
		fmt.sbprintf(b, "<a:blip r:embed=\"%s\"/>", rid)
		strings.write_string(b, "<a:stretch><a:fillRect/></a:stretch></p:blipFill><p:spPr>")
		xfrm(b, e.x, e.y, e.w, e.h, e.rotation)
		if e.radius > 0 {
			fmt.sbprintf(
				b,
				"<a:prstGeom prst=\"roundRect\"><a:avLst><a:gd name=\"adj\" fmla=\"val %d\"/></a:avLst></a:prstGeom>",
				round_rect_adj(e.w, e.h, e.radius),
			)
		} else {
			strings.write_string(b, "<a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom>")
		}
		strings.write_string(b, "</p:spPr></p:pic>")
	}
}

// ---------------------------------------------------------------------------
// Placeholders
//
// PowerPoint's outline view, its accessibility checker, a screen reader and
// every "export outline" feature read a slide's text out of its *placeholders*
// — the title and body shapes a layout declares — and ignore free text boxes.
// A deck written as nothing but text boxes therefore has an empty outline even
// though every word is on the page. So each of this program's layouts is
// written as a real slide layout with the placeholders it has (the slots
// `apply_layout` creates), and on each slide the text boxes that fill those
// slots are written as placeholders that point at them:
//
//     layout          PowerPoint type   placeholders
//     Title           title             ctrTitle, subTitle idx 1
//     Title + Content obj               title, content idx 1
//     Two Content     twoObj            title, content idx 1 and 2
//     Section Header  secHead           title, body idx 1
//     Picture         picTx             title, body idx 2 (the caption)
//     Blank           blank             none
//
// Which box is which is decided by style, in reading order: the first
// Title-styled box is the title; the body is the first Bullets or Body box
// (Subtitle on the Title and Section layouts, where that is what the slot
// holds). Everything else stays a text box. A placeholder still carries its
// own position, size, insets and every run's formatting, so a reader that
// ignores inheritance and one that honours it draw the same slide.
// ---------------------------------------------------------------------------

Pptx_Ph :: struct {
	tag:  string, // the <p:ph .../> element; empty for a plain text box
	name: string, // the shape's name, as PowerPoint names placeholders
}

PPTX_LAYOUT_TYPE := [Layout]string {
	.Title          = "title",
	.Title_Content  = "obj",
	.Two_Content    = "twoObj",
	.Section_Header = "secHead",
	.Picture        = "picTx",
	.Blank          = "blank",
}

PPTX_LAYOUT_NAME := [Layout]string {
	.Title          = "Title Slide",
	.Title_Content  = "Title and Content",
	.Two_Content    = "Two Content",
	.Section_Header = "Section Header",
	.Picture        = "Picture with Caption",
	.Blank          = "Blank",
}

// pptx_placeholders says, for each element of a slide, which placeholder it
// fills (an empty tag for none).
pptx_placeholders :: proc(s: ^Slide, allocator := context.temp_allocator) -> []Pptx_Ph {
	out := make([]Pptx_Ph, len(s.elems), allocator)
	if s.layout == .Blank {
		return out
	}
	first :: proc(s: ^Slide, out: []Pptx_Ph, styles: []Style) -> int {
		for &e, i in s.elems {
			if e.kind != .Text || out[i].tag != "" {
				continue
			}
			for st in styles {
				if e.style == st {
					return i
				}
			}
		}
		return -1
	}
	if t := first(s, out, {.Title}); t >= 0 {
		out[t] = s.layout == .Title ? {`<p:ph type="ctrTitle"/>`, "Title"} : {`<p:ph type="title"/>`, "Title"}
	}
	switch s.layout {
	case .Title:
		if i := first(s, out, {.Subtitle}); i >= 0 {
			out[i] = {`<p:ph type="subTitle" idx="1"/>`, "Subtitle"}
		}
	case .Title_Content:
		if i := first(s, out, {.Bullets, .Body}); i >= 0 {
			out[i] = {`<p:ph idx="1"/>`, "Content Placeholder"}
		}
	case .Two_Content:
		for k in 1 ..= 2 {
			if i := first(s, out, {.Bullets, .Body}); i >= 0 {
				out[i] = {fmt.aprintf(`<p:ph sz="half" idx="%d"/>`, k, allocator = allocator), "Content Placeholder"}
			}
		}
	case .Section_Header:
		if i := first(s, out, {.Subtitle, .Body}); i >= 0 {
			out[i] = {`<p:ph type="body" idx="1"/>`, "Text Placeholder"}
		}
	case .Picture:
		if i := first(s, out, {.Body, .Caption, .Bullets}); i >= 0 {
			out[i] = {`<p:ph type="body" idx="2"/>`, "Text Placeholder"}
		}
	case .Blank:
	}
	return out
}

// layout_xml writes one slide layout: its type, its name and its placeholder
// shapes where `apply_layout` puts the slots, each with the slot's prompt as
// its text — what PowerPoint shows in an empty placeholder.
@(private = "file")
layout_xml :: proc(l: Layout, th: ^Theme) -> string {
	d := Deck {
		theme  = th^,
		slides = make([dynamic]Slide, context.temp_allocator),
	}
	append(&d.slides, Slide{layout = l, elems = make([dynamic]Element, context.temp_allocator)})
	apply_layout(&d, 0, l)
	s := &d.slides[0]
	phs := pptx_placeholders(s)
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(
		&b,
		`<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<p:sldLayout %s type="%s" preserve="1"><p:cSld name="%s"><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr>`,
		NS,
		PPTX_LAYOUT_TYPE[l],
		PPTX_LAYOUT_NAME[l],
	)
	id := 1
	for &e, i in s.elems {
		if phs[i].tag == "" {
			continue
		}
		id += 1
		write_element(&b, th, &e, id, "", phs[i])
	}
	strings.write_string(&b, "</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sldLayout>")
	return strings.to_string(b)
}

// transition_xml is a slide's `p:transition`, which follows `p:clrMapOvr` in
// the slide part. `spd` is DrawingML's three speeds (PowerPoint plays them at
// 0.5, 0.75 and 1 second); the nearest one to the slide's duration is used.
//
// The directions were settled against the one oracle in reach, LibreOffice
// 24.2: it reads `<p:push dir="r"/>` as SMIL pushWipe "fromRight" (the new
// slide enters from the right edge, which is what the projector draws going
// forward) and `<p:wipe dir="r"/>` as barWipe "leftToRight" (the reveal
// sweeps left to right, the projector's wipe). Its own export writes the
// same attributes back for those two effects, so the round trip is stable.
// PowerPoint itself could not be run here to confirm its reading.
transition_xml :: proc(s: ^Slide) -> string {
	if s.transition == .None {
		return ""
	}
	ms := s.transition_ms > 0 ? s.transition_ms : TRANSITION_MS
	spd := ms <= 600 ? "fast" : (ms <= 875 ? "med" : "slow")
	inner := ""
	switch s.transition {
	case .None:
	case .Fade:
		inner = "<p:fade/>"
	case .Push:
		inner = `<p:push dir="r"/>`
	case .Wipe:
		inner = `<p:wipe dir="r"/>`
	}
	return fmt.tprintf(`<p:transition spd="%s">%s</p:transition>`, spd, inner)
}

// style_suffix names a text box's type-scale style in its shape name
// ("TextBox 7 · Metric"). PresentationML has no notion of this deck's styles,
// and a size alone does not say whether 62pt was a Title or a big Body; the
// importer reads the name back when the file says it came from here, so a
// deck survives a round trip through .pptx with its styles intact.
style_suffix :: proc(e: ^Element) -> string {
	return fmt.tprintf(" · %s", STYLE_NAMES[e.style])
}

// cover_crop is the "cover" fit this renderer draws pictures with, expressed as
// the four insets DrawingML uses: the shorter axis fills the box and the longer
// one is cropped evenly from both ends. A format that only knows how to stretch
// still shows the right part of the picture.
cover_crop :: proc(box_w, box_h: f32, img_w, img_h: int) -> (l, t: int) {
	if img_w <= 0 || img_h <= 0 || box_w <= 0 || box_h <= 0 {
		return 0, 0
	}
	s := max(box_w / f32(img_w), box_h / f32(img_h))
	fx := clamp(box_w / (f32(img_w) * s), 0, 1)
	fy := clamp(box_h / (f32(img_h) * s), 0, 1)
	return pct((1 - fx) / 2), pct((1 - fy) / 2)
}

// ---------------------------------------------------------------------------
// The master decoration
//
// What `draw_master` paints before any element: the background, the layout's
// accent shapes, the rule under the title and the footer. It is reproduced
// here as real shapes rather than baked into a picture, so the exported deck
// is editable all the way down.
// ---------------------------------------------------------------------------

@(private = "file")
write_master_decor :: proc(b: ^strings.Builder, d: ^Deck, si: int, fonts: ^p.Fonts, id: ^int) {
	s := &d.slides[si]
	th := &d.theme
	accent := argb(th.accent)
	accent2 := argb(th.accent2)

	oval :: proc(b: ^strings.Builder, id: ^int, x, y, w, h: f32, c: p.Color, a: f32) {
		id^ += 1
		fmt.sbprintf(
			b,
			"<p:sp><p:nvSpPr><p:cNvPr id=\"%d\" name=\"Decor %d\"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr><p:spPr>",
			id^,
			id^,
		)
		xfrm(b, x, y, w, h, 0)
		strings.write_string(b, "<a:prstGeom prst=\"ellipse\"><a:avLst/></a:prstGeom>")
		solid_fill(b, "a:solidFill", c, a)
		strings.write_string(b, "<a:ln><a:noFill/></a:ln></p:spPr>")
		strings.write_string(b, "<p:txBody><a:bodyPr/><a:lstStyle/><a:p><a:endParaRPr lang=\"en-US\"/></a:p></p:txBody></p:sp>")
	}
	bar :: proc(b: ^strings.Builder, id: ^int, x, y, w, h: f32, c: p.Color, a: f32) {
		id^ += 1
		fmt.sbprintf(
			b,
			"<p:sp><p:nvSpPr><p:cNvPr id=\"%d\" name=\"Decor %d\"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr><p:spPr>",
			id^,
			id^,
		)
		xfrm(b, x, y, w, h, 0)
		strings.write_string(b, "<a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom>")
		solid_fill(b, "a:solidFill", c, a)
		strings.write_string(b, "<a:ln><a:noFill/></a:ln></p:spPr>")
		strings.write_string(b, "<p:txBody><a:bodyPr/><a:lstStyle/><a:p><a:endParaRPr lang=\"en-US\"/></a:p></p:txBody></p:sp>")
	}

	switch s.layout {
	case .Title:
		oval(b, id, 820, -220, 720, 720, accent, 0.13)
		oval(b, id, -180, 420, 620, 620, accent2, 0.08)
		if ry, ok := title_rule_y(fonts, d, si); ok {
			bar(b, id, SLIDE_W / 2 - 70, ry, 140, 3, accent, 0.9)
		}
	case .Section_Header:
		bar(b, id, 0, 0, 10, SLIDE_H, accent, 1)
		oval(b, id, 980, 140, 440, 440, accent2, 0.1)
	case .Title_Content, .Two_Content, .Picture:
		ry, ok := title_rule_y(fonts, d, si)
		if !ok {
			ry = 182
		}
		bar(b, id, MARGIN, ry, 86, 3, accent, 1)
	case .Blank:
	}
}

// title_rule_y is where the accent rule under a slide's title goes: just below
// the title's last baseline, so a title that wrapped to two lines carries the
// rule down with it. It mirrors `title_baseline` in render.odin, which is
// file-private there; the two are checked against each other by rendering a
// slide and reading the pixels back in the test suite.
title_rule_y :: proc(fonts: ^p.Fonts, d: ^Deck, si: int) -> (y: f32, ok: bool) {
	s := &d.slides[si]
	for i in 0 ..< len(s.elems) {
		e := &s.elems[i]
		if e.kind != .Text || e.style != .Title || strings.trim_space(e.text) == "" {
			continue
		}
		tl := text_layout(fonts, {e.x, e.y, e.w, e.h}, 1, e, theme_family(&d.theme))
		return text_bottom(fonts, &tl) + 18, true
	}
	return 0, false
}

// ---------------------------------------------------------------------------
// Parts
// ---------------------------------------------------------------------------

PML :: "http://schemas.openxmlformats.org/presentationml/2006/main"
DML :: "http://schemas.openxmlformats.org/drawingml/2006/main"
OREL :: "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
PREL :: "http://schemas.openxmlformats.org/package/2006/relationships"

@(private = "file")
NS :: `xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"`

// A theme part. Every master needs one, and its twelve-colour scheme is what a
// reader offers in its own colour picker, so it is filled with this deck's
// palette rather than with Office's defaults.
@(private = "file")
theme_xml :: proc(th: ^Theme, name: string) -> string {
	face := th.mono ? PPTX_MONO : PPTX_SANS
	return fmt.tprintf(
		`<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<a:theme xmlns:a="%s" name="%s"><a:themeElements><a:clrScheme name="%s"><a:dk1><a:srgbClr val="%s"/></a:dk1><a:lt1><a:srgbClr val="%s"/></a:lt1><a:dk2><a:srgbClr val="%s"/></a:dk2><a:lt2><a:srgbClr val="%s"/></a:lt2><a:accent1><a:srgbClr val="%s"/></a:accent1><a:accent2><a:srgbClr val="%s"/></a:accent2><a:accent3><a:srgbClr val="%s"/></a:accent3><a:accent4><a:srgbClr val="%s"/></a:accent4><a:accent5><a:srgbClr val="%s"/></a:accent5><a:accent6><a:srgbClr val="%s"/></a:accent6><a:hlink><a:srgbClr val="%s"/></a:hlink><a:folHlink><a:srgbClr val="%s"/></a:folHlink></a:clrScheme><a:fontScheme name="%s"><a:majorFont><a:latin typeface="%s"/><a:ea typeface=""/><a:cs typeface=""/></a:majorFont><a:minorFont><a:latin typeface="%s"/><a:ea typeface=""/><a:cs typeface=""/></a:minorFont></a:fontScheme><a:fmtScheme name="%s"><a:fillStyleLst><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:fillStyleLst><a:lnStyleLst><a:ln w="6350" cap="flat" cmpd="sng" algn="ctr"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:prstDash val="solid"/></a:ln><a:ln w="12700" cap="flat" cmpd="sng" algn="ctr"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:prstDash val="solid"/></a:ln><a:ln w="19050" cap="flat" cmpd="sng" algn="ctr"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:prstDash val="solid"/></a:ln></a:lnStyleLst><a:effectStyleLst><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle></a:effectStyleLst><a:bgFillStyleLst><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:bgFillStyleLst></a:fmtScheme></a:themeElements><a:objectDefaults/><a:extraClrSchemeLst/></a:theme>`,
		DML,
		xml_escape(name),
		xml_escape(th.name),
		srgb(argb(th.fg)),
		srgb(argb(th.bg)),
		srgb(argb(th.muted)),
		srgb(argb(th.surface)),
		srgb(argb(th.accent)),
		srgb(argb(th.accent2)),
		srgb(argb(th.muted)),
		srgb(argb(th.surface)),
		srgb(argb(th.fg)),
		srgb(argb(th.bg)),
		srgb(argb(th.accent)),
		srgb(argb(th.accent2)),
		xml_escape(th.name),
		face,
		face,
		xml_escape(th.name),
	)
}

// ---------------------------------------------------------------------------
// The package
// ---------------------------------------------------------------------------

pptx_bytes :: proc(d: ^Deck, fonts: ^p.Fonts, imgs: ^Img_Cache, allocator := context.allocator) -> []u8 {
	th := &d.theme
	z := zip_make(context.temp_allocator)

	media := make([dynamic]Pptx_Media, context.temp_allocator)

	// --- the slides --------------------------------------------------------
	slide_parts := make([dynamic]string, context.temp_allocator)
	slide_rels := make([dynamic]string, context.temp_allocator)
	notes_parts := make([dynamic]string, context.temp_allocator)
	notes_rels := make([dynamic]string, context.temp_allocator)
	has_notes := make([dynamic]bool, context.temp_allocator)

	for si in 0 ..< len(d.slides) {
		s := &d.slides[si]
		b := strings.builder_make(context.temp_allocator)
		rb := strings.builder_make(context.temp_allocator)
		fmt.sbprintf(&rb, "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<Relationships xmlns=\"%s\">", PREL)
		fmt.sbprintf(
			&rb,
			"<Relationship Id=\"rId1\" Type=\"%s/slideLayout\" Target=\"../slideLayouts/slideLayout%d.xml\"/>",
			OREL,
			int(s.layout) + 1,
		)
		next_rid := 2

		notes := strings.trim_space(s.notes)
		if notes != "" {
			fmt.sbprintf(
				&rb,
				"<Relationship Id=\"rId%d\" Type=\"%s/notesSlide\" Target=\"../notesSlides/notesSlide%d.xml\"/>",
				next_rid,
				OREL,
				si + 1,
			)
			next_rid += 1
		}
		append(&has_notes, notes != "")

		fmt.sbprintf(&b, "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<p:sld %s><p:cSld>", NS)

		// The background. A two-stop vertical gradient when the theme asks
		// for one, which is what the editor draws.
		strings.write_string(&b, "<p:bg><p:bgPr>")
		if th.bg2 != 0 && th.bg2 != th.bg {
			fmt.sbprintf(
				&b,
				"<a:gradFill rotWithShape=\"0\"><a:gsLst><a:gs pos=\"0\"><a:srgbClr val=\"%s\"/></a:gs><a:gs pos=\"100000\"><a:srgbClr val=\"%s\"/></a:gs></a:gsLst><a:lin ang=\"5400000\" scaled=\"0\"/></a:gradFill>",
				srgb(argb(th.bg)),
				srgb(argb(th.bg2)),
			)
		} else {
			fmt.sbprintf(&b, "<a:solidFill><a:srgbClr val=\"%s\"/></a:solidFill>", srgb(argb(th.bg)))
		}
		strings.write_string(&b, "<a:effectLst/></p:bgPr></p:bg>")

		fmt.sbprintf(
			&b,
			"<p:spTree><p:nvGrpSpPr><p:cNvPr id=\"1\" name=\"\"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr><a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"%d\" cy=\"%d\"/><a:chOff x=\"0\" y=\"0\"/><a:chExt cx=\"%d\" cy=\"%d\"/></a:xfrm></p:grpSpPr>",
			PPTX_SLIDE_CX,
			PPTX_SLIDE_CY,
			PPTX_SLIDE_CX,
			PPTX_SLIDE_CY,
		)

		id := 1
		if !d.no_decor {
			write_master_decor(&b, d, si, fonts, &id)
		}
		phs := pptx_placeholders(s)

		for i in 0 ..< len(s.elems) {
			e := &s.elems[i]
			id += 1
			rid := ""
			if e.kind == .Image {
				data, ext, ok := read_media(imgs, e.src)
				if !ok {
					// A picture that cannot be read is drawn as the editor
					// draws it: a framed placeholder naming the file.
					ph := e^
					ph.kind = .Rect
					ph.fill = SLOT_SURFACE
					ph.stroke = SLOT_MUTED
					ph.stroke_w = 2
					write_element(&b, th, &ph, id, "")
					continue
				}
				rid = fmt.tprintf("rId%d", next_rid)
				next_rid += 1
				name := fmt.tprintf("image%d.%s", len(media) + 1, ext)
				append(&media, Pptx_Media{name = name, rid = rid, data = data, ext = ext})
				fmt.sbprintf(
					&rb,
					"<Relationship Id=\"%s\" Type=\"%s/image\" Target=\"../media/%s\"/>",
					rid,
					OREL,
					name,
				)
				// Crop to the part of the picture the editor shows.
				iw, ih := 0, 0
				if img, got := img_get(imgs, e.src); got {
					iw, ih = img.w, img.h
				}
				l, t := cover_crop(e.w, e.h, iw, ih)
				if l > 0 || t > 0 {
					// Written into the blipFill below by re-emitting the
					// picture with a source rectangle.
					write_picture_cropped(&b, th, e, id, rid, l, t)
					continue
				}
			}
			write_element(&b, th, e, id, rid, phs[i])
		}

		// The footer: the deck title and the slide number, as the editor
		// draws them on every layout but Title and Blank.
		if s.layout != .Title && s.layout != .Blank && !d.no_decor {
			id += 1
			bar_c := argb(th.muted)
			fmt.sbprintf(
				&b,
				"<p:sp><p:nvSpPr><p:cNvPr id=\"%d\" name=\"Footer rule\"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr><p:spPr>",
				id,
			)
			xfrm(&b, MARGIN, SLIDE_H - 54, SLIDE_W - 2 * MARGIN, 1, 0)
			strings.write_string(&b, "<a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom>")
			solid_fill(&b, "a:solidFill", bar_c, 0.25)
			strings.write_string(&b, "<a:ln><a:noFill/></a:ln></p:spPr><p:txBody><a:bodyPr/><a:lstStyle/><a:p><a:endParaRPr lang=\"en-US\"/></a:p></p:txBody></p:sp>")

			left := text_box(d.title, .Caption, MARGIN, SLIDE_H - 50, (SLIDE_W - 2 * MARGIN) / 2, 30)
			left.size = 15
			left.color = SLOT_MUTED
			id += 1
			write_element(&b, th, &left, id, "", {name = "Footer title"})

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
			id += 1
			write_element(&b, th, &right, id, "", {name = "Footer number"})
		}

		strings.write_string(&b, "</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr>")
		strings.write_string(&b, transition_xml(s))
		strings.write_string(&b, "</p:sld>")
		strings.write_string(&rb, "</Relationships>")
		append(&slide_parts, strings.to_string(b))
		append(&slide_rels, strings.to_string(rb))

		// --- the speaker notes --------------------------------------------
		if notes != "" {
			nb := strings.builder_make(context.temp_allocator)
			fmt.sbprintf(&nb, "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<p:notes %s><p:cSld><p:spTree>", NS)
			strings.write_string(&nb, "<p:nvGrpSpPr><p:cNvPr id=\"1\" name=\"\"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/>")
			strings.write_string(
				&nb,
				"<p:sp><p:nvSpPr><p:cNvPr id=\"2\" name=\"Notes Placeholder\"/><p:cNvSpPr><a:spLocks noGrp=\"1\"/></p:cNvSpPr><p:nvPr><p:ph type=\"body\" idx=\"1\"/></p:nvPr></p:nvSpPr><p:spPr/><p:txBody><a:bodyPr/><a:lstStyle/>",
			)
			for para in strings.split(notes, "\n", context.temp_allocator) {
				if strings.trim_space(para) == "" {
					strings.write_string(&nb, "<a:p><a:endParaRPr lang=\"en-US\"/></a:p>")
					continue
				}
				fmt.sbprintf(&nb, "<a:p><a:r><a:rPr lang=\"en-US\" dirty=\"0\"/><a:t>%s</a:t></a:r></a:p>", xml_escape(para))
			}
			strings.write_string(&nb, "</p:txBody></p:sp></p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:notes>")
			append(&notes_parts, strings.to_string(nb))
			append(
				&notes_rels,
				fmt.tprintf(
					`<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="%s"><Relationship Id="rId1" Type="%s/notesMaster" Target="../notesMasters/notesMaster1.xml"/><Relationship Id="rId2" Type="%s/slide" Target="../slides/slide%d.xml"/></Relationships>`,
					PREL,
					OREL,
					OREL,
					si + 1,
				),
			)
		} else {
			append(&notes_parts, "")
			append(&notes_rels, "")
		}
	}

	// --- presentation.xml --------------------------------------------------
	pb := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&pb, "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<p:presentation %s saveSubsetFonts=\"1\">", NS)
	strings.write_string(&pb, "<p:sldMasterIdLst><p:sldMasterId id=\"2147483648\" r:id=\"rId1\"/></p:sldMasterIdLst>")
	strings.write_string(&pb, "<p:notesMasterIdLst><p:notesMasterId r:id=\"rId2\"/></p:notesMasterIdLst>")
	strings.write_string(&pb, "<p:sldIdLst>")
	for si in 0 ..< len(d.slides) {
		fmt.sbprintf(&pb, "<p:sldId id=\"%d\" r:id=\"rId%d\"/>", 256 + si, 3 + si)
	}
	strings.write_string(&pb, "</p:sldIdLst>")
	fmt.sbprintf(&pb, "<p:sldSz cx=\"%d\" cy=\"%d\"/><p:notesSz cx=\"%d\" cy=\"%d\"/>", PPTX_SLIDE_CX, PPTX_SLIDE_CY, PPTX_NOTES_CX, PPTX_NOTES_CY)
	strings.write_string(&pb, "</p:presentation>")

	prb := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&prb, "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<Relationships xmlns=\"%s\">", PREL)
	fmt.sbprintf(&prb, "<Relationship Id=\"rId1\" Type=\"%s/slideMaster\" Target=\"slideMasters/slideMaster1.xml\"/>", OREL)
	fmt.sbprintf(&prb, "<Relationship Id=\"rId2\" Type=\"%s/notesMaster\" Target=\"notesMasters/notesMaster1.xml\"/>", OREL)
	for si in 0 ..< len(d.slides) {
		fmt.sbprintf(&prb, "<Relationship Id=\"rId%d\" Type=\"%s/slide\" Target=\"slides/slide%d.xml\"/>", 3 + si, OREL, si + 1)
	}
	fmt.sbprintf(&prb, "<Relationship Id=\"rId%d\" Type=\"%s/theme\" Target=\"theme/theme1.xml\"/>", 3 + len(d.slides), OREL)
	strings.write_string(&prb, "</Relationships>")

	// --- the master and its six layouts --------------------------------------
	// The master declares the title and body placeholders every layout's own
	// inherit from, and the text styles they start with: the deck's own type
	// scale and palette, no bullets and no paragraph spacing, so a
	// placeholder a reader fills in by hand looks like this deck and not
	// like Office's default.
	face := th.mono ? PPTX_MONO : PPTX_SANS
	mb := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(
		&mb,
		`<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<p:sldMaster %s><p:cSld><p:bg><p:bgPr><a:solidFill><a:srgbClr val="%s"/></a:solidFill><a:effectLst/></p:bgPr></p:bg><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr>`,
		NS,
		srgb(argb(th.bg)),
	)
	{
		mt := text_box("Click to edit the title", .Title, MARGIN, 72, 1120, 96)
		mbody := text_box("Click to edit the text", .Body, MARGIN, 208, 1120, 432)
		write_element(&mb, th, &mt, 2, "", {`<p:ph type="title"/>`, "Title Placeholder"})
		write_element(&mb, th, &mbody, 3, "", {`<p:ph type="body" idx="1"/>`, "Text Placeholder"})
	}
	strings.write_string(
		&mb,
		`</p:spTree></p:cSld><p:clrMap bg1="lt1" tx1="dk1" bg2="lt2" tx2="dk2" accent1="accent1" accent2="accent2" accent3="accent3" accent4="accent4" accent5="accent5" accent6="accent6" hlink="hlink" folHlink="folHlink"/><p:sldLayoutIdLst>`,
	)
	for l in Layout {
		fmt.sbprintf(&mb, `<p:sldLayoutId id="%d" r:id="rId%d"/>`, 2147483649 + int(l), int(l) + 1)
	}
	fmt.sbprintf(
		&mb,
		`</p:sldLayoutIdLst><p:txStyles><p:titleStyle><a:lvl1pPr algn="l"><a:lnSpc><a:spcPct val="%d"/></a:lnSpc><a:spcBef><a:spcPts val="0"/></a:spcBef><a:buNone/><a:defRPr sz="%d" b="1"><a:solidFill><a:srgbClr val="%s"/></a:solidFill><a:latin typeface="%s"/><a:cs typeface="%s"/></a:defRPr></a:lvl1pPr></p:titleStyle><p:bodyStyle><a:lvl1pPr marL="0" indent="0" algn="l"><a:lnSpc><a:spcPct val="%d"/></a:lnSpc><a:spcBef><a:spcPts val="0"/></a:spcBef><a:buNone/><a:defRPr sz="%d"><a:solidFill><a:srgbClr val="%s"/></a:solidFill><a:latin typeface="%s"/><a:cs typeface="%s"/></a:defRPr></a:lvl1pPr></p:bodyStyle><p:otherStyle><a:lvl1pPr><a:defRPr sz="1800"><a:solidFill><a:srgbClr val="%s"/></a:solidFill></a:defRPr></a:lvl1pPr></p:otherStyle></p:txStyles></p:sldMaster>`,
		int(TYPE_SCALE[.Title].leading * 100000),
		int(TYPE_SCALE[.Title].size * PPTX_SZ_PER_UNIT),
		srgb(argb(th.fg)),
		face,
		face,
		int(TYPE_SCALE[.Body].leading * 100000),
		int(TYPE_SCALE[.Body].size * PPTX_SZ_PER_UNIT),
		srgb(argb(th.fg)),
		face,
		face,
		srgb(argb(th.fg)),
	)
	master := strings.to_string(mb)
	mrb := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&mrb, `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="%s">`, PREL)
	for l in Layout {
		fmt.sbprintf(&mrb, `<Relationship Id="rId%d" Type="%s/slideLayout" Target="../slideLayouts/slideLayout%d.xml"/>`, int(l) + 1, OREL, int(l) + 1)
	}
	fmt.sbprintf(&mrb, `<Relationship Id="rId%d" Type="%s/theme" Target="../theme/theme1.xml"/></Relationships>`, len(Layout) + 1, OREL)
	master_rels := strings.to_string(mrb)
	layout_rels := fmt.tprintf(
		`<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="%s"><Relationship Id="rId1" Type="%s/slideMaster" Target="../slideMasters/slideMaster1.xml"/></Relationships>`,
		PREL,
		OREL,
	)
	notes_master := fmt.tprintf(
		`<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<p:notesMaster %s><p:cSld><p:bg><p:bgPr><a:solidFill><a:srgbClr val="FFFFFF"/></a:solidFill><a:effectLst/></p:bgPr></p:bg><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr><p:sp><p:nvSpPr><p:cNvPr id="2" name="Notes Placeholder"/><p:cNvSpPr><a:spLocks noGrp="1"/></p:cNvSpPr><p:nvPr><p:ph type="body" idx="1"/></p:nvPr></p:nvSpPr><p:spPr><a:xfrm><a:off x="685800" y="4343400"/><a:ext cx="5486400" cy="4114800"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></p:spPr><p:txBody><a:bodyPr/><a:lstStyle/><a:p><a:endParaRPr lang="en-US"/></a:p></p:txBody></p:sp></p:spTree></p:cSld><p:clrMap bg1="lt1" tx1="dk1" bg2="lt2" tx2="dk2" accent1="accent1" accent2="accent2" accent3="accent3" accent4="accent4" accent5="accent5" accent6="accent6" hlink="hlink" folHlink="folHlink"/><p:notesStyle><a:lvl1pPr><a:defRPr sz="1200"/></a:lvl1pPr></p:notesStyle></p:notesMaster>`,
		NS,
	)
	notes_master_rels := fmt.tprintf(
		`<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="%s"><Relationship Id="rId1" Type="%s/theme" Target="../theme/theme2.xml"/></Relationships>`,
		PREL,
		OREL,
	)

	// --- [Content_Types].xml ----------------------------------------------
	cb := strings.builder_make(context.temp_allocator)
	strings.write_string(
		&cb,
		`<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Default Extension="png" ContentType="image/png"/><Default Extension="jpeg" ContentType="image/jpeg"/><Default Extension="jpg" ContentType="image/jpeg"/><Default Extension="gif" ContentType="image/gif"/><Default Extension="bmp" ContentType="image/bmp"/>`,
	)
	OT :: "application/vnd.openxmlformats-officedocument.presentationml"
	fmt.sbprintf(&cb, "<Override PartName=\"/ppt/presentation.xml\" ContentType=\"%s.presentation.main+xml\"/>", OT)
	fmt.sbprintf(&cb, "<Override PartName=\"/ppt/slideMasters/slideMaster1.xml\" ContentType=\"%s.slideMaster+xml\"/>", OT)
	for l in Layout {
		fmt.sbprintf(&cb, "<Override PartName=\"/ppt/slideLayouts/slideLayout%d.xml\" ContentType=\"%s.slideLayout+xml\"/>", int(l) + 1, OT)
	}
	fmt.sbprintf(&cb, "<Override PartName=\"/ppt/notesMasters/notesMaster1.xml\" ContentType=\"%s.notesMaster+xml\"/>", OT)
	strings.write_string(&cb, "<Override PartName=\"/ppt/theme/theme1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.theme+xml\"/>")
	strings.write_string(&cb, "<Override PartName=\"/ppt/theme/theme2.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.theme+xml\"/>")
	for si in 0 ..< len(d.slides) {
		fmt.sbprintf(&cb, "<Override PartName=\"/ppt/slides/slide%d.xml\" ContentType=\"%s.slide+xml\"/>", si + 1, OT)
		if has_notes[si] {
			fmt.sbprintf(&cb, "<Override PartName=\"/ppt/notesSlides/notesSlide%d.xml\" ContentType=\"%s.notesSlide+xml\"/>", si + 1, OT)
		}
	}
	strings.write_string(&cb, "<Override PartName=\"/docProps/core.xml\" ContentType=\"application/vnd.openxmlformats-package.core-properties+xml\"/>")
	strings.write_string(&cb, "<Override PartName=\"/docProps/app.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.extended-properties+xml\"/>")
	strings.write_string(&cb, "</Types>")

	root_rels := fmt.tprintf(
		`<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="%s"><Relationship Id="rId1" Type="%s/officeDocument" Target="ppt/presentation.xml"/><Relationship Id="rId2" Type="%s/metadata/core-properties" Target="docProps/core.xml"/><Relationship Id="rId3" Type="%s/extended-properties" Target="docProps/app.xml"/></Relationships>`,
		PREL,
		OREL,
		PREL,
		OREL,
	)

	core := fmt.tprintf(
		`<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"><dc:title>%s</dc:title><dc:creator>%s</dc:creator><cp:lastModifiedBy>%s</cp:lastModifiedBy></cp:coreProperties>`,
		xml_escape(d.title),
		xml_escape(d.author),
		xml_escape(d.author),
	)
	app_props := fmt.tprintf(
		`<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties" xmlns:vt="http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes"><Application>palmy slides</Application><Slides>%d</Slides><PresentationFormat>Widescreen</PresentationFormat></Properties>`,
		len(d.slides),
	)

	// --- assemble ----------------------------------------------------------
	zip_add_string(&z, "[Content_Types].xml", strings.to_string(cb))
	zip_add_string(&z, "_rels/.rels", root_rels)
	zip_add_string(&z, "docProps/core.xml", core)
	zip_add_string(&z, "docProps/app.xml", app_props)
	zip_add_string(&z, "ppt/presentation.xml", strings.to_string(pb))
	zip_add_string(&z, "ppt/_rels/presentation.xml.rels", strings.to_string(prb))
	zip_add_string(&z, "ppt/slideMasters/slideMaster1.xml", master)
	zip_add_string(&z, "ppt/slideMasters/_rels/slideMaster1.xml.rels", master_rels)
	for l in Layout {
		zip_add_string(&z, fmt.tprintf("ppt/slideLayouts/slideLayout%d.xml", int(l) + 1), layout_xml(l, th))
		zip_add_string(&z, fmt.tprintf("ppt/slideLayouts/_rels/slideLayout%d.xml.rels", int(l) + 1), layout_rels)
	}
	zip_add_string(&z, "ppt/notesMasters/notesMaster1.xml", notes_master)
	zip_add_string(&z, "ppt/notesMasters/_rels/notesMaster1.xml.rels", notes_master_rels)
	zip_add_string(&z, "ppt/theme/theme1.xml", theme_xml(th, "palmy"))
	zip_add_string(&z, "ppt/theme/theme2.xml", theme_xml(th, "palmy notes"))
	for si in 0 ..< len(d.slides) {
		zip_add_string(&z, fmt.tprintf("ppt/slides/slide%d.xml", si + 1), slide_parts[si])
		zip_add_string(&z, fmt.tprintf("ppt/slides/_rels/slide%d.xml.rels", si + 1), slide_rels[si])
		if has_notes[si] {
			zip_add_string(&z, fmt.tprintf("ppt/notesSlides/notesSlide%d.xml", si + 1), notes_parts[si])
			zip_add_string(&z, fmt.tprintf("ppt/notesSlides/_rels/notesSlide%d.xml.rels", si + 1), notes_rels[si])
		}
	}
	for m in media {
		zip_add(&z, fmt.tprintf("ppt/media/%s", m.name), m.data)
	}

	raw := zip_finish(&z)
	out := make([]u8, len(raw), allocator)
	copy(out, raw)
	return out
}

// write_picture_cropped is `write_element` for a picture that needs a source
// rectangle: the editor fits pictures by covering the box, and a reader that
// only stretches has to be told which part of the file to stretch.
@(private = "file")
write_picture_cropped :: proc(b: ^strings.Builder, th: ^Theme, e: ^Element, id: int, rid: string, l, t: int) {
	fmt.sbprintf(
		b,
		"<p:pic><p:nvPicPr><p:cNvPr id=\"%d\" name=\"Picture %d\"/><p:cNvPicPr><a:picLocks noChangeAspect=\"1\"/></p:cNvPicPr><p:nvPr/></p:nvPicPr><p:blipFill>",
		id,
		id,
	)
	fmt.sbprintf(b, "<a:blip r:embed=\"%s\"/>", rid)
	fmt.sbprintf(b, "<a:srcRect l=\"%d\" t=\"%d\" r=\"%d\" b=\"%d\"/>", l, t, l, t)
	strings.write_string(b, "<a:stretch><a:fillRect/></a:stretch></p:blipFill><p:spPr>")
	xfrm(b, e.x, e.y, e.w, e.h, e.rotation)
	if e.radius > 0 {
		fmt.sbprintf(
			b,
			"<a:prstGeom prst=\"roundRect\"><a:avLst><a:gd name=\"adj\" fmla=\"val %d\"/></a:avLst></a:prstGeom>",
			round_rect_adj(e.w, e.h, e.radius),
		)
	} else {
		strings.write_string(b, "<a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom>")
	}
	strings.write_string(b, "</p:spPr></p:pic>")
	_ = th
}

// read_media loads a picture's bytes straight off disk. The encoded file is
// what goes into the package — re-encoding a PNG through the decoder would
// lose nothing but gain nothing either, and would need an encoder.
read_media :: proc(imgs: ^Img_Cache, src: string) -> (data: []u8, ext: string, ok: bool) {
	if src == "" {
		return nil, "", false
	}
	path := img_path(imgs, src)
	raw, err := os.read_entire_file_from_path(path, context.temp_allocator)
	if err != nil || len(raw) < 8 {
		return nil, "", false
	}
	// Sniff the type rather than trusting the extension: the content type in
	// the package has to match the bytes or the reader rejects the picture.
	switch {
	case raw[0] == 0x89 && raw[1] == 'P' && raw[2] == 'N' && raw[3] == 'G':
		return raw, "png", true
	case raw[0] == 0xff && raw[1] == 0xd8:
		return raw, "jpeg", true
	case raw[0] == 'G' && raw[1] == 'I' && raw[2] == 'F':
		return raw, "gif", true
	case raw[0] == 'B' && raw[1] == 'M':
		return raw, "bmp", true
	}
	return nil, "", false
}

pptx_write_file :: proc(d: ^Deck, path: string, fonts: ^p.Fonts, imgs: ^Img_Cache) -> string {
	if slash := strings.last_index_byte(path, '/'); slash > 0 {
		_ = os.make_directory_all(path[:slash])
	}
	data := pptx_bytes(d, fonts, imgs, context.temp_allocator)
	if e := os.write_entire_file(path, data); e != nil {
		return fmt.tprintf("cannot write %s: %v", path, e)
	}
	return ""
}

// deck_slug is a filename made from the deck's title: lowercase, words joined
// by hyphens, nothing a shell or a filesystem has an opinion about.
deck_slug :: proc(st: ^St) -> string {
	b := strings.builder_make(context.temp_allocator)
	prev_dash := true
	for i in 0 ..< len(st.deck.title) {
		c := st.deck.title[i]
		switch {
		case c >= 'A' && c <= 'Z':
			strings.write_byte(&b, c + 32)
			prev_dash = false
		case (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9'):
			strings.write_byte(&b, c)
			prev_dash = false
		case:
			if !prev_dash {
				strings.write_byte(&b, '-')
				prev_dash = true
			}
		}
		if strings.builder_len(b) >= 48 {
			break
		}
	}
	out := strings.to_string(b)
	for len(out) > 0 && out[len(out) - 1] == '-' {
		out = out[:len(out) - 1]
	}
	return out == "" ? "deck" : out
}
