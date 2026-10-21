package main

// The deck model.
//
// A deck is a title, a theme and a list of slides; a slide is a layout, speaker
// notes and a list of elements in paint order. Every field is plain data —
// numbers, strings, enums — so the whole thing serialises to JSON and reads
// back byte for byte (see serialize.odin).
//
// Two conventions make the model both compact and theme-aware:
//
//   * Geometry is in *slide coordinates*, a fixed 1280x720 space. The renderer
//     scales that space into whatever rectangle it is handed, which is why one
//     renderer serves the canvas, the sorter thumbnails, the projector and the
//     PNG exporter.
//   * A paint is either a literal 0xAARRGGBB colour or one of the small
//     integers 1..6, which name a *slot in the theme*. A slot is resolved at
//     paint time, so switching the theme recolours every slide that referred to
//     the accent rather than to a particular blue. 0 means "no paint", which is
//     unambiguous because a literal colour with alpha 0 would be invisible.

import "core:strings"
import p "palmy:."

SLIDE_W :: f32(1280)
SLIDE_H :: f32(720)
MARGIN :: f32(80)

Kind :: enum u8 {
	Text,
	Rect,
	Ellipse,
	Line,
	Arrow,
	Image,
}

// Text styles are the deck's type scale. A text box stores the style, not a
// font size, so retyping the deck is one table edit.
Style :: enum u8 {
	Title,
	Subtitle,
	Body,
	Bullets,
	Caption,
	Quote,
	Metric,
}

Halign :: enum u8 {
	Left,
	Center,
	Right,
}

Valign :: enum u8 {
	Top,
	Middle,
	Bottom,
}

// Theme slots. See the note above.
SLOT_NONE :: u32(0)
SLOT_ACCENT :: u32(1)
SLOT_ACCENT2 :: u32(2)
SLOT_FG :: u32(3)
SLOT_MUTED :: u32(4)
SLOT_SURFACE :: u32(5)
SLOT_BG :: u32(6)
SLOT_MAX :: u32(6)

SLOT_NAMES := [7]string{"none", "accent", "accent 2", "foreground", "muted", "surface", "background"}

Element :: struct {
	kind:     Kind,
	x:        f32,
	y:        f32,
	w:        f32,
	h:        f32,

	// Text
	text:     string,
	style:    Style,
	halign:   Halign,
	valign:   Valign,
	size:     f32, // 0 takes the size from the style
	bold:     bool,
	color:    u32, // text paint; slot or literal, 0 means the theme foreground

	// Shape
	fill:     u32,
	fill_a:   f32, // alpha multiplier on the fill alone, 1 by default
	stroke:   u32,
	stroke_w: f32,
	radius:   f32,
	head:     f32, // arrow head length

	// Everything
	opacity:  f32,
	rotation: f32, // degrees, clockwise, about the element's centre

	// Image
	src:      string, // path, relative to the asset root when not absolute

	// Identity for collaboration (collab.odin); not part of the file.
	uid:      u64 `json:"-"`,
}

Layout :: enum u8 {
	Title,
	Title_Content,
	Two_Content,
	Section_Header,
	Picture,
	Blank,
}

LAYOUT_NAMES := [Layout]string {
	.Title          = "Title",
	.Title_Content  = "Title + Content",
	.Two_Content    = "Two Content",
	.Section_Header = "Section Header",
	.Picture        = "Picture",
	.Blank          = "Blank",
}

Slide :: struct {
	layout: Layout,
	notes:  string,
	elems:  [dynamic]Element,
	uid:    u64 `json:"-"`, // identity for collaboration; not part of the file
}

Theme :: struct {
	name:    string,
	bg:      u32, // literal colours: a theme is where the real values live
	bg2:     u32, // second stop of the background gradient; 0 means flat
	fg:      u32,
	muted:   u32,
	accent:  u32,
	accent2: u32,
	surface: u32,
	dark:    bool,
	mono:    bool, // set the whole deck in the monospace face
}

Deck :: struct {
	version: int,
	title:   string,
	author:  string,
	theme:   Theme,
	slides:  [dynamic]Slide,
}

THEMES := [?]Theme {
	{
		name = "Midnight",
		bg = 0xff0b1120,
		bg2 = 0xff141d33,
		fg = 0xfff8fafc,
		muted = 0xff93a3bd,
		accent = 0xff818cf8,
		accent2 = 0xff22d3ee,
		surface = 0xff1b2440,
		dark = true,
	},
	{
		name = "Paper",
		bg = 0xfffcfcfa,
		bg2 = 0xfff2f1ec,
		fg = 0xff1c1917,
		muted = 0xff78716c,
		accent = 0xffea580c,
		accent2 = 0xff0f766e,
		surface = 0xffe9e7e0,
		dark = false,
	},
	{
		name = "Sunset",
		bg = 0xff1a1024,
		bg2 = 0xff2d1033,
		fg = 0xfffdf4ff,
		muted = 0xffc4a8c9,
		accent = 0xfffb7185,
		accent2 = 0xfffbbf24,
		surface = 0xff34183d,
		dark = true,
	},
	{
		name = "Terminal",
		bg = 0xff0b0f0c,
		bg2 = 0xff0f1511,
		fg = 0xffd7f5df,
		muted = 0xff79a386,
		accent = 0xff4ade80,
		accent2 = 0xfffde047,
		surface = 0xff13201a,
		dark = true,
		mono = true,
	},
	{
		name = "Forest",
		bg = 0xff07140f,
		bg2 = 0xff0d241a,
		fg = 0xffecfdf5,
		muted = 0xff8fb5a3,
		accent = 0xff34d399,
		accent2 = 0xfffacc15,
		surface = 0xff123224,
		dark = true,
	},
}

// ---------------------------------------------------------------------------
// Colour resolution
// ---------------------------------------------------------------------------

// theme_family is the face the whole deck is set in. A theme that cannot change
// the typeface is only half a theme.
theme_family :: proc(th: ^Theme) -> p.Font_Family {
	return th.mono ? .Mono : .Sans
}

// paint resolves a stored paint value against the theme.
paint :: proc(th: ^Theme, v: u32) -> p.Color {
	switch v {
	case SLOT_NONE:
		return p.TRANSPARENT
	case SLOT_ACCENT:
		return argb(th.accent)
	case SLOT_ACCENT2:
		return argb(th.accent2)
	case SLOT_FG:
		return argb(th.fg)
	case SLOT_MUTED:
		return argb(th.muted)
	case SLOT_SURFACE:
		return argb(th.surface)
	case SLOT_BG:
		return argb(th.bg)
	}
	return argb(v)
}

has_paint :: proc(v: u32) -> bool {
	if v == SLOT_NONE {
		return false
	}
	if v <= SLOT_MAX {
		return true
	}
	return (v >> 24) != 0
}

paint_label :: proc(v: u32) -> string {
	if v <= SLOT_MAX {
		return SLOT_NAMES[v]
	}
	return "custom"
}

// The cycle a colour property steps through: the theme slots, then off. Keeping
// the editor on slots rather than a colour picker is deliberate — a deck whose
// shapes track the theme restyles in one keystroke.
PAINT_CYCLE := [?]u32{SLOT_ACCENT, SLOT_ACCENT2, SLOT_FG, SLOT_MUTED, SLOT_SURFACE, SLOT_BG, SLOT_NONE}

next_paint :: proc(v: u32, dir: int) -> u32 {
	at := len(PAINT_CYCLE) - 1
	for c, i in PAINT_CYCLE {
		if c == v {
			at = i
			break
		}
	}
	n := len(PAINT_CYCLE)
	return PAINT_CYCLE[((at + dir) % n + n) % n]
}

// ---------------------------------------------------------------------------
// The type scale
// ---------------------------------------------------------------------------

Type_Spec :: struct {
	size:     f32,
	bold:     bool,
	leading:  f32,
	tracking: f32,
	muted:    bool,
}

TYPE_SCALE := [Style]Type_Spec {
	.Title    = {size = 62, bold = true, leading = 1.12, tracking = -0.015},
	.Subtitle = {size = 30, bold = false, leading = 1.3, muted = true},
	.Body     = {size = 27, bold = false, leading = 1.42},
	.Bullets  = {size = 27, bold = false, leading = 1.5},
	.Caption  = {size = 18, bold = false, leading = 1.35, muted = true},
	.Quote    = {size = 38, bold = false, leading = 1.35},
	.Metric   = {size = 92, bold = true, leading = 1.0, tracking = -0.02},
}

STYLE_NAMES := [Style]string {
	.Title    = "Title",
	.Subtitle = "Subtitle",
	.Body     = "Body",
	.Bullets  = "Bullets",
	.Caption  = "Caption",
	.Quote    = "Quote",
	.Metric   = "Metric",
}

KIND_NAMES := [Kind]string {
	.Text    = "Text",
	.Rect    = "Rectangle",
	.Ellipse = "Ellipse",
	.Line    = "Line",
	.Arrow   = "Arrow",
	.Image   = "Image",
}

text_size :: proc(e: ^Element) -> f32 {
	if e.size > 0 {
		return e.size
	}
	return TYPE_SCALE[e.style].size
}

// ---------------------------------------------------------------------------
// Construction
// ---------------------------------------------------------------------------

text_box :: proc(text: string, style: Style, x, y, w, h: f32, align := Halign.Left) -> Element {
	return Element {
		kind = .Text,
		x = x,
		y = y,
		w = w,
		h = h,
		text = text,
		style = style,
		halign = align,
		valign = .Top,
		opacity = 1,
		fill_a = 1,
	}
}

shape :: proc(kind: Kind, x, y, w, h: f32, fill: u32, stroke: u32 = SLOT_NONE) -> Element {
	e := Element {
		kind     = kind,
		x        = x,
		y        = y,
		w        = w,
		h        = h,
		fill     = fill,
		fill_a   = 1,
		stroke   = stroke,
		stroke_w = stroke == SLOT_NONE ? 0 : 3,
		opacity  = 1,
	}
	if kind == .Rect {
		e.radius = 14
	}
	if kind == .Line || kind == .Arrow {
		e.fill = SLOT_NONE
		e.stroke = fill
		e.stroke_w = 4
		e.head = 26
	}
	return e
}

image_box :: proc(src: string, x, y, w, h: f32) -> Element {
	return Element {
		kind = .Image,
		x = x,
		y = y,
		w = w,
		h = h,
		src = src,
		opacity = 1,
		fill_a = 1,
		radius = 16,
	}
}

elem_rect :: proc(e: ^Element) -> p.Rect {
	return {e.x, e.y, e.w, e.h}
}

// normalise fixes up an element loaded from an older file or built by hand, so
// the renderer never has to defend itself.
normalise :: proc(e: ^Element) {
	if e.opacity <= 0 {
		e.opacity = 1
	}
	if e.fill_a <= 0 {
		e.fill_a = 1
	}
	e.opacity = clamp(e.opacity, 0.02, 1)
	e.fill_a = clamp(e.fill_a, 0.02, 1)
	if e.kind != .Line && e.kind != .Arrow {
		e.w = max(e.w, 8)
		e.h = max(e.h, 8)
	}
}

// ---------------------------------------------------------------------------
// Slides
// ---------------------------------------------------------------------------

slide_make :: proc(layout: Layout) -> Slide {
	s := Slide {
		layout = layout,
		elems  = make([dynamic]Element),
	}
	return s
}

// layout_slots returns the text placeholders a layout starts with, in reading
// order, plus any decoration elements the layout owns.
apply_layout :: proc(d: ^Deck, si: int, l: Layout) {
	s := &d.slides[si]
	s.layout = l

	// Harvest the text that is already on the slide so that reflowing into a
	// new layout keeps the words. Non-text elements are left exactly where the
	// user put them.
	old := make([dynamic]Element, context.temp_allocator)
	keep := make([dynamic]Element, context.temp_allocator)
	for e in s.elems {
		if e.kind == .Text {
			append(&old, e)
		} else {
			append(&keep, e)
		}
	}

	slots := make([dynamic]Element, context.temp_allocator)
	switch l {
	case .Title:
		append(&slots, text_box("Presentation title", .Title, 140, 248, 1000, 150, .Center))
		append(&slots, text_box("A subtitle, or the date", .Subtitle, 140, 410, 1000, 90, .Center))
	case .Title_Content:
		append(&slots, text_box("Slide title", .Title, MARGIN, 72, 1120, 96))
		append(&slots, text_box("- First point\n- Second point\n- Third point", .Bullets, MARGIN, 208, 1120, 432))
	case .Two_Content:
		append(&slots, text_box("Slide title", .Title, MARGIN, 72, 1120, 96))
		append(&slots, text_box("- Left column", .Bullets, MARGIN, 208, 540, 432))
		append(&slots, text_box("- Right column", .Bullets, 660, 208, 540, 432))
	case .Section_Header:
		append(&slots, text_box("Section", .Title, 140, 300, 1000, 110))
		append(&slots, text_box("What the next few slides cover", .Subtitle, 140, 424, 1000, 70))
	case .Picture:
		append(&slots, text_box("Slide title", .Title, MARGIN, 72, 1120, 96))
		append(&slots, text_box("A caption for the picture", .Body, 700, 236, 500, 360))
	case .Blank:
	}

	// Re-slot the old text, keeping each box's own style overrides only when it
	// came from the same slot position.
	for i in 0 ..< len(slots) {
		if i < len(old) && strings.trim_space(old[i].text) != "" {
			slots[i].text = old[i].text
			slots[i].color = old[i].color
			slots[i].size = old[i].size
			slots[i].bold = old[i].bold
		}
	}
	// Anything that did not fit the new layout keeps its own geometry rather
	// than being thrown away.
	for i in len(slots) ..< len(old) {
		append(&slots, old[i])
	}

	clear(&s.elems)
	for e in slots {
		ee := e
		normalise(&ee)
		append(&s.elems, ee)
	}
	for e in keep {
		append(&s.elems, e)
	}
}

slide_add :: proc(d: ^Deck, at: int, l: Layout) -> int {
	s := slide_make(l)
	idx := clamp(at, 0, len(d.slides))
	inject_at(&d.slides, idx, s)
	apply_layout(d, idx, l)
	return idx
}

slide_duplicate :: proc(d: ^Deck, si: int) -> int {
	if si < 0 || si >= len(d.slides) {
		return si
	}
	src := &d.slides[si]
	cp := slide_make(src.layout)
	cp.notes = src.notes
	for e in src.elems {
		append(&cp.elems, e)
	}
	inject_at(&d.slides, si + 1, cp)
	return si + 1
}

slide_delete :: proc(d: ^Deck, si: int) {
	if len(d.slides) <= 1 || si < 0 || si >= len(d.slides) {
		return
	}
	delete(d.slides[si].elems)
	ordered_remove(&d.slides, si)
}

slide_move :: proc(d: ^Deck, si, dir: int) -> int {
	to := si + dir
	if si < 0 || si >= len(d.slides) || to < 0 || to >= len(d.slides) {
		return si
	}
	d.slides[si], d.slides[to] = d.slides[to], d.slides[si]
	return to
}

// ---------------------------------------------------------------------------
// Elements
// ---------------------------------------------------------------------------

elem_add :: proc(s: ^Slide, e: Element) -> int {
	ee := e
	normalise(&ee)
	append(&s.elems, ee)
	return len(s.elems) - 1
}

elem_duplicate :: proc(s: ^Slide, i: int) -> int {
	if i < 0 || i >= len(s.elems) {
		return i
	}
	cp := s.elems[i]
	cp.x += 28
	cp.y += 28
	append(&s.elems, cp)
	return len(s.elems) - 1
}

elem_delete :: proc(s: ^Slide, i: int) {
	if i < 0 || i >= len(s.elems) {
		return
	}
	ordered_remove(&s.elems, i)
}

// Paint order is array order, which is the whole of the z model: raising an
// element is a swap, bringing it to the front is a move to the end.
elem_raise :: proc(s: ^Slide, i: int) -> int {
	if i < 0 || i + 1 >= len(s.elems) {
		return i
	}
	s.elems[i], s.elems[i + 1] = s.elems[i + 1], s.elems[i]
	return i + 1
}

elem_lower :: proc(s: ^Slide, i: int) -> int {
	if i <= 0 || i >= len(s.elems) {
		return i
	}
	s.elems[i], s.elems[i - 1] = s.elems[i - 1], s.elems[i]
	return i - 1
}

elem_to_front :: proc(s: ^Slide, i: int) -> int {
	if i < 0 || i >= len(s.elems) {
		return i
	}
	e := s.elems[i]
	ordered_remove(&s.elems, i)
	append(&s.elems, e)
	return len(s.elems) - 1
}

elem_to_back :: proc(s: ^Slide, i: int) -> int {
	if i < 0 || i >= len(s.elems) {
		return i
	}
	e := s.elems[i]
	ordered_remove(&s.elems, i)
	inject_at(&s.elems, 0, e)
	return 0
}

// hit_elem returns the topmost element containing a point in slide coordinates.
hit_elem :: proc(s: ^Slide, x, y: f32) -> int {
	for i := len(s.elems) - 1; i >= 0; i -= 1 {
		e := &s.elems[i]
		r := elem_rect(e)
		if e.kind == .Line || e.kind == .Arrow {
			// A line's box can be degenerate, so give it a grab margin.
			r = {min(e.x, e.x + e.w), min(e.y, e.y + e.h), abs(e.w), abs(e.h)}
			r = p.rect_inset(r, -14)
		}
		if p.rect_contains(r, x, y) {
			return i
		}
	}
	return -1
}

// ---------------------------------------------------------------------------
// Text, notes and the theme
//
// The three edits that are not an `invoke` command, because they carry a
// value: what an element says, what the speaker notes say, and which theme the
// deck wears. The window commits an in-place edit through these, and the
// command line sets them through the same procedures.
// ---------------------------------------------------------------------------

// elem_set_text commits a text box's words. The string is cloned: the window
// edits in a buffer it reuses, and the command line's arguments are not the
// deck's to keep.
elem_set_text :: proc(e: ^Element, text: string) {
	e.text = strings.clone(text)
}

slide_set_notes :: proc(s: ^Slide, text: string) {
	s.notes = strings.clone(text)
}

// theme_by_name finds a theme regardless of case, so `--theme paper` works.
theme_by_name :: proc(name: string) -> (Theme, bool) {
	for th in THEMES {
		if strings.equal_fold(th.name, name) {
			return th, true
		}
	}
	return {}, false
}

// theme_after is the next theme in the table, wrapping: what G does.
theme_after :: proc(current: string) -> Theme {
	at := 0
	for t, i in THEMES {
		if t.name == current {
			at = i
		}
	}
	return THEMES[(at + 1) % len(THEMES)]
}

// slide_title is the text a person would call the slide's title: the first
// Title-styled box, else the first text box with anything in it.
slide_title :: proc(s: ^Slide) -> string {
	for &e in s.elems {
		if e.kind == .Text && e.style == .Title && strings.trim_space(e.text) != "" {
			return e.text
		}
	}
	for &e in s.elems {
		if e.kind == .Text && strings.trim_space(e.text) != "" {
			return e.text
		}
	}
	return ""
}

// ---------------------------------------------------------------------------
// Undo
//
// The deck is plain data, so history is just copies of it: before anything
// destructive the whole deck is cloned onto a stack, and undo pops it back.
// Strings are immutable once committed, so a clone shares them; only the two
// arrays are copied, which for a deck of any sane size is a few kilobytes.
// ---------------------------------------------------------------------------

HISTORY_MAX :: 32

clone_deck :: proc(d: ^Deck) -> Deck {
	c := d^
	c.slides = make([dynamic]Slide)
	for s in d.slides {
		cs := s
		cs.elems = make([dynamic]Element)
		append(&cs.elems, ..s.elems[:])
		append(&c.slides, cs)
	}
	return c
}

deck_free :: proc(d: ^Deck) {
	for &s in d.slides {
		delete(s.elems)
	}
	delete(d.slides)
	d.slides = nil
}
