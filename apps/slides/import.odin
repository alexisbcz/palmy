package main

// Import: a deck from somebody else's .pptx, or from a PDF.
//
// .PPTX. A PresentationML package is read part by part: the presentation for
// the slide order and size, each slide with its layout and master behind it
// (placeholders inherit their position and type from both), the theme for its
// colours, the slide's relationships for its pictures and speaker notes. What
// comes out is an ordinary deck of this program's elements:
//
//   source                         becomes
//   title / ctrTitle placeholder   a Title text box
//   subTitle placeholder           a Subtitle text box
//   body / content placeholder     a Bullets box when its paragraphs have
//                                  bullets, a Body box otherwise
//   text box                       a Body (or Bullets) box
//   a:r with its a:rPr             a styled run: bold, italic, colour, size
//   rect, roundRect, ellipse       Rect and Ellipse, fill, line, opacity, rotation
//   line, connector                Line, or Arrow when it has an arrowhead
//   picture                        an Image, its file copied into DECK-media/
//   notes slide body               the speaker notes
//   p:transition fade/push/wipe    the slide's transition
//   layout type                    the slide's layout (title, obj, twoObj,
//                                  secHead, picTx, blank)
//   group                          its members, flattened, positioned through
//                                  the group's child transform
//   layout and master shapes       elements at the back of each slide
//   background                     the theme's background, or a full-bleed
//                                  rectangle where a slide's differs
//
// Text style resolves through the same chain PowerPoint uses: the run, the
// paragraph, the shape's list style, the layout placeholder, the master
// placeholder, the master's text styles. Colours resolve through the theme's
// scheme and the master's colour map, with lumMod/lumOff/alpha applied.
//
// A deck this program exported is recognised (docProps/app.xml says "palmy
// slides") and read back exactly: its theme by name, its literal colours back
// to theme slots, and the master decoration and footer the exporter writes as
// real shapes skipped, because the renderer draws them itself. Any other deck
// is imported with `no_decor` set, so this program's own decoration is not
// added on top of the author's.
//
// What is lost is reported, by kind and count, in `Import_Report.lost`, and
// `slides import` prints it: tables become text, charts and SmartArt are
// dropped, gradients and pattern fills are flattened to one colour, custom
// geometry becomes a rectangle, fonts are set in this deck's face, group
// rotation and picture cropping are not kept, animations are dropped.
//
// PDF. A PDF has no slides in it, only pages of drawing, so it is imported as
// what it is: one picture per page, rendered by poppler's `pdftoppm` at the
// export width, on a Blank slide, with the page's text (`pdftotext -layout`)
// as that slide's speaker notes so the words are still searchable. Nothing on
// the page is editable afterwards; the report says so.

import "core:encoding/xml"
import "core:fmt"
import "core:math"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import kit "kit:."
import p "palmy:."

Import_Report :: struct {
	pictures: int,
	lost:     [dynamic]string,
}

// media_dir_for is where an imported deck's pictures go: DECK-media beside it.
media_dir_for :: proc(deck_path: string) -> string {
	stem := deck_path
	if strings.has_suffix(strings.to_lower(stem, context.temp_allocator), ".json") {
		stem = stem[:len(stem) - 5]
	}
	return fmt.aprintf("%s-media", stem)
}

// media_src is how a deck refers to a picture in its media directory: by a
// path relative to the deck, so the two can be moved together.
@(private = "file")
media_src :: proc(media_dir, name: string) -> string {
	base := media_dir
	if i := strings.last_index_byte(base, '/'); i >= 0 {
		base = base[i + 1:]
	}
	return fmt.aprintf("%s/%s", base, name)
}

// ---------------------------------------------------------------------------
// XML helpers
// ---------------------------------------------------------------------------

@(private = "file")
XOPTS :: xml.Options {
	flags = {.Ignore_Unsupported, .Unbox_CDATA, .Decode_SGML_Entities},
}

@(private = "file")
Node :: struct {
	doc: ^xml.Document,
	id:  xml.Element_ID,
}

@(private = "file")
NO_NODE :: Node{}

@(private = "file")
ok_node :: proc(n: Node) -> bool {
	return n.doc != nil
}

@(private = "file")
local :: proc(ident: string) -> string {
	if i := strings.last_index_byte(ident, ':'); i >= 0 {
		return ident[i + 1:]
	}
	return ident
}

@(private = "file")
name_of :: proc(n: Node) -> string {
	if !ok_node(n) {
		return ""
	}
	return local(n.doc.elements[n.id].ident)
}

@(private = "file")
attr :: proc(n: Node, key: string) -> string {
	if !ok_node(n) {
		return ""
	}
	for a in n.doc.elements[n.id].attribs {
		if a.key == key || local(a.key) == key {
			return a.val
		}
	}
	return ""
}

@(private = "file")
has_attr :: proc(n: Node, key: string) -> bool {
	if !ok_node(n) {
		return false
	}
	for a in n.doc.elements[n.id].attribs {
		if a.key == key || local(a.key) == key {
			return true
		}
	}
	return false
}

@(private = "file")
attr_int :: proc(n: Node, key: string, def: i64 = 0) -> i64 {
	v, ok := strconv.parse_i64(attr(n, key))
	return ok ? v : def
}

@(private = "file")
kids :: proc(n: Node, name := "") -> [dynamic]Node {
	out := make([dynamic]Node, context.temp_allocator)
	if !ok_node(n) {
		return out
	}
	for v in n.doc.elements[n.id].value {
		if cid, ok := v.(xml.Element_ID); ok {
			if n.doc.elements[cid].kind != .Element {
				continue
			}
			if name == "" || local(n.doc.elements[cid].ident) == name {
				append(&out, Node{n.doc, cid})
			}
		}
	}
	return out
}

@(private = "file")
kid :: proc(n: Node, name: string) -> Node {
	if !ok_node(n) {
		return NO_NODE
	}
	for v in n.doc.elements[n.id].value {
		if cid, ok := v.(xml.Element_ID); ok {
			if n.doc.elements[cid].kind == .Element && local(n.doc.elements[cid].ident) == name {
				return Node{n.doc, cid}
			}
		}
	}
	return NO_NODE
}

// path walks down by child names: path(sp, "nvSpPr", "nvPr", "ph").
@(private = "file")
path :: proc(n: Node, names: ..string) -> Node {
	cur := n
	for nm in names {
		cur = kid(cur, nm)
		if !ok_node(cur) {
			return NO_NODE
		}
	}
	return cur
}

// find is the first descendant with a name, depth first.
@(private = "file")
find :: proc(n: Node, name: string) -> Node {
	if !ok_node(n) {
		return NO_NODE
	}
	for k in kids(n) {
		if name_of(k) == name {
			return k
		}
		if f := find(k, name); ok_node(f) {
			return f
		}
	}
	return NO_NODE
}

@(private = "file")
text_of :: proc(n: Node) -> string {
	if !ok_node(n) {
		return ""
	}
	b := strings.builder_make(context.temp_allocator)
	for v in n.doc.elements[n.id].value {
		if s, ok := v.(string); ok {
			strings.write_string(&b, s)
		}
	}
	return strings.to_string(b)
}

// ---------------------------------------------------------------------------
// The package
// ---------------------------------------------------------------------------

@(private = "file")
Imp :: struct {
	files:     [dynamic]Zip_File,
	docs:      map[string]^xml.Document,
	scheme:    map[string]u32, // dk1 lt1 dk2 lt2 accent1..6 hlink folHlink
	clrmap:    map[string]string, // bg1 tx1 bg2 tx2 → scheme names
	// EMU to slide units: x * s + ox
	s:         f64,
	ox, oy:    f64,
	media_dir: string,
	media:     map[string]string, // package part → deck src
	pictures:  int,
	lost:      map[string]int,
	palmy:     bool,
	theme:     Theme,
	ours:      bool, // the theme is one of THEMES, so colours map to slots
}

@(private = "file")
lose :: proc(im: ^Imp, what: string, n := 1) {
	im.lost[what] = im.lost[what] + n
}

@(private = "file")
part :: proc(im: ^Imp, name: string) -> Node {
	if d, ok := im.docs[name]; ok {
		return d == nil ? NO_NODE : Node{d, 0}
	}
	data, ok := zip_find(im.files, name)
	if !ok {
		im.docs[name] = nil
		return NO_NODE
	}
	doc, err := xml.parse_bytes(keep_spaces(data), XOPTS, name, nil, context.temp_allocator)
	if err != nil {
		im.docs[name] = nil
		return NO_NODE
	}
	im.docs[name] = doc
	return Node{doc, 0}
}

// keep_spaces protects the spaces inside every <a:t> (DrawingML's text run)
// by spelling them as character references. Odin's XML reader trims the
// whitespace around character data, which is right for markup and wrong for
// "Revenue grew " followed by a bold "fast": the space is the text. An
// escaped space is decoded after the trim, so it survives.
@(private = "file")
keep_spaces :: proc(data: []u8) -> []u8 {
	b := strings.builder_make(context.temp_allocator)
	i := 0
	n := len(data)
	for i < n {
		c := data[i]
		strings.write_byte(&b, c)
		i += 1
		if c != '<' {
			continue
		}
		// An opening tag whose local name is exactly `t`?
		j := i
		for j < n && data[j] != '>' && data[j] != ' ' && data[j] != '/' {
			j += 1
		}
		tag := string(data[i:j])
		if colon := strings.last_index_byte(tag, ':'); colon >= 0 {
			tag = tag[colon + 1:]
		}
		if tag != "t" || j >= n {
			continue
		}
		k := j
		for k < n && data[k] != '>' {
			k += 1
		}
		if k >= n || data[k - 1] == '/' {
			continue
		}
		strings.write_bytes(&b, data[i:k + 1])
		i = k + 1
		for i < n && data[i] != '<' {
			if data[i] == ' ' {
				strings.write_string(&b, "&#32;")
			} else {
				strings.write_byte(&b, data[i])
			}
			i += 1
		}
	}
	return transmute([]u8)strings.to_string(b)
}

// resolve joins a relationship target onto the directory of the part that
// named it.
@(private = "file")
resolve :: proc(base, target: string) -> string {
	if strings.has_prefix(target, "/") {
		return target[1:]
	}
	dir := base
	if i := strings.last_index_byte(dir, '/'); i >= 0 {
		dir = dir[:i]
	} else {
		dir = ""
	}
	t := target
	for {
		if strings.has_prefix(t, "../") {
			t = t[3:]
			if i := strings.last_index_byte(dir, '/'); i >= 0 {
				dir = dir[:i]
			} else {
				dir = ""
			}
		} else if strings.has_prefix(t, "./") {
			t = t[2:]
		} else {
			break
		}
	}
	if dir == "" {
		return strings.clone(t, context.temp_allocator)
	}
	return strings.concatenate({dir, "/", t}, context.temp_allocator)
}

@(private = "file")
rels_of :: proc(name: string) -> string {
	i := strings.last_index_byte(name, '/')
	return fmt.tprintf("%s/_rels/%s.rels", name[:max(i, 0)], name[i + 1:])
}

// rel_target finds a relationship by id; rel_of_type the first of a type.
@(private = "file")
rel_target :: proc(im: ^Imp, owner, rid: string) -> string {
	r := part(im, rels_of(owner))
	for rel in kids(r, "Relationship") {
		if attr(rel, "Id") == rid {
			return resolve(owner, attr(rel, "Target"))
		}
	}
	return ""
}

@(private = "file")
rel_of_type :: proc(im: ^Imp, owner, type_suffix: string) -> string {
	r := part(im, rels_of(owner))
	for rel in kids(r, "Relationship") {
		if strings.has_suffix(attr(rel, "Type"), type_suffix) {
			return resolve(owner, attr(rel, "Target"))
		}
	}
	return ""
}

// ---------------------------------------------------------------------------
// Colour
// ---------------------------------------------------------------------------

PRESET_COLOURS := [?]struct {
	name: string,
	v:    u32,
} {
	{"black", 0x000000},
	{"white", 0xffffff},
	{"red", 0xff0000},
	{"green", 0x008000},
	{"blue", 0x0000ff},
	{"yellow", 0xffff00},
	{"gray", 0x808080},
	{"orange", 0xffa500},
}

// colour reads a colour element (srgbClr, schemeClr, sysClr, prstClr) with its
// modifiers, into 0xAARRGGBB.
@(private = "file")
colour :: proc(im: ^Imp, c: Node) -> (v: u32, ok: bool) {
	rgb: u32
	switch name_of(c) {
	case "srgbClr":
		x, good := strconv.parse_u64_of_base(attr(c, "val"), 16)
		if !good {
			return 0, false
		}
		rgb = u32(x)
	case "schemeClr":
		key := attr(c, "val")
		if m, mapped := im.clrmap[key]; mapped {
			key = m
		}
		got, found := im.scheme[key]
		if !found {
			return 0, false
		}
		rgb = got & 0xffffff
	case "sysClr":
		x, good := strconv.parse_u64_of_base(attr(c, "lastClr"), 16)
		if !good {
			rgb = attr(c, "val") == "window" ? 0xffffff : 0
		} else {
			rgb = u32(x)
		}
	case "prstClr":
		for pc in PRESET_COLOURS {
			if pc.name == attr(c, "val") {
				rgb = pc.v
			}
		}
	case "scrgbClr", "hslClr":
		return 0, false
	case:
		return 0, false
	}
	r := f64((rgb >> 16) & 0xff)
	g := f64((rgb >> 8) & 0xff)
	b := f64(rgb & 0xff)
	a := 255.0
	for m in kids(c) {
		val := f64(attr_int(m, "val", 100000)) / 100000
		switch name_of(m) {
		case "lumMod", "shade":
			r, g, b = r * val, g * val, b * val
		case "lumOff":
			r, g, b = r + 255 * val, g + 255 * val, b + 255 * val
		case "tint":
			r, g, b = 255 - (255 - r) * val, 255 - (255 - g) * val, 255 - (255 - b) * val
		case "alpha":
			a = 255 * val
		}
	}
	cl :: proc(x: f64) -> u32 {return u32(clamp(math.round(x), 0, 255))}
	return cl(a) << 24 | cl(r) << 16 | cl(g) << 8 | cl(b), true
}

// fill_of reads a fill container's first colour: solidFill, the first stop of
// a gradient (reported), or nothing for noFill.
@(private = "file")
fill_of :: proc(im: ^Imp, container: Node) -> (v: u32, set: bool, none: bool) {
	if !ok_node(container) {
		return 0, false, false
	}
	if ok_node(kid(container, "noFill")) {
		return 0, true, true
	}
	if sf := kid(container, "solidFill"); ok_node(sf) {
		for c in kids(sf) {
			if got, ok := colour(im, c); ok {
				return got, true, false
			}
		}
		return 0, false, false
	}
	if gf := kid(container, "gradFill"); ok_node(gf) {
		lose(im, "gradient fills drawn in one colour")
		gs := kids(path(gf, "gsLst"), "gs")
		if len(gs) > 0 {
			for c in kids(gs[0]) {
				if got, ok := colour(im, c); ok {
					return got, true, false
				}
			}
		}
	}
	if ok_node(kid(container, "pattFill")) {
		lose(im, "pattern fills drawn in one colour")
		for c in kids(path(container, "pattFill", "fgClr")) {
			if got, ok := colour(im, c); ok {
				return got, true, false
			}
		}
	}
	if ok_node(kid(container, "blipFill")) {
		lose(im, "picture fills on shapes")
	}
	return 0, false, false
}

// paint_from turns a resolved colour into a stored paint: a theme slot when the
// deck wears one of this program's themes and the colour is that slot's.
@(private = "file")
paint_from :: proc(im: ^Imp, v: u32) -> u32 {
	if im.ours {
		th := &im.theme
		rgb := v & 0xffffff
		slots := [?]struct {
			c: u32,
			s: u32,
		}{{th.accent, SLOT_ACCENT}, {th.accent2, SLOT_ACCENT2}, {th.fg, SLOT_FG}, {th.muted, SLOT_MUTED}, {th.surface, SLOT_SURFACE}, {th.bg, SLOT_BG}}
		if v >> 24 == 0xff {
			for sl in slots {
				if sl.c & 0xffffff == rgb {
					return sl.s
				}
			}
		}
	}
	if v >> 24 == 0 {
		return SLOT_NONE
	}
	return v
}

// alpha_of is a colour's alpha as a fraction, to the hundredth: the 8-bit
// channel it travels in here would otherwise turn a 0.9 into 0.902.
@(private = "file")
alpha_of :: proc(v: u32) -> f32 {
	return f32(math.round(f64(v >> 24) / 255 * 100) / 100)
}

// tidy rounds a derived length to a tenth of a unit, so a radius written as a
// percentage of the short side comes back as the 14 it was, not 13.9995.
@(private = "file")
tidy :: proc(x: f32) -> f32 {
	return f32(math.round(f64(x) * 10) / 10)
}

// ---------------------------------------------------------------------------
// Geometry
// ---------------------------------------------------------------------------

// Xf maps EMU in the current group's child space to EMU on the slide.
@(private = "file")
Xf :: struct {
	ax, bx, ay, by: f64,
}

@(private = "file")
XF_ID :: Xf{1, 0, 1, 0}

@(private = "file")
Box :: struct {
	x, y, w, h: f32,
	rot:        f32,
	flip_h:     bool,
	flip_v:     bool,
	ok:         bool,
}

@(private = "file")
box_of :: proc(im: ^Imp, xfrm: Node, xf: Xf) -> Box {
	off := kid(xfrm, "off")
	ext := kid(xfrm, "ext")
	if !ok_node(off) || !ok_node(ext) {
		return {}
	}
	x := f64(attr_int(off, "x")) * xf.ax + xf.bx
	y := f64(attr_int(off, "y")) * xf.ay + xf.by
	w := f64(attr_int(ext, "cx")) * xf.ax
	h := f64(attr_int(ext, "cy")) * xf.ay
	return {
		x = f32(x * im.s + im.ox),
		y = f32(y * im.s + im.oy),
		w = f32(w * im.s),
		h = f32(h * im.s),
		rot = f32(f64(attr_int(xfrm, "rot")) / 60000),
		flip_h = attr(xfrm, "flipH") == "1",
		flip_v = attr(xfrm, "flipV") == "1",
		ok = true,
	}
}

// ---------------------------------------------------------------------------
// Placeholders and the style chain
// ---------------------------------------------------------------------------

@(private = "file")
Ph_Ref :: struct {
	type: string, // "" means obj (a content placeholder)
	idx:  string,
	ok:   bool,
}

@(private = "file")
ph_of :: proc(sp: Node) -> Ph_Ref {
	ph := Node{}
	for nv in ([?]string{"nvSpPr", "nvPicPr", "nvGrpSpPr", "nvCxnSpPr", "nvGraphicFramePr"}) {
		if n := path(sp, nv, "nvPr", "ph"); ok_node(n) {
			ph = n
			break
		}
	}
	if !ok_node(ph) {
		return {}
	}
	return {type = attr(ph, "type"), idx = attr(ph, "idx"), ok = true}
}

@(private = "file")
is_title :: proc(t: string) -> bool {
	return t == "title" || t == "ctrTitle"
}

// find_ph looks a placeholder up in a layout or master: by index first, then
// by type, the way PowerPoint matches them.
@(private = "file")
find_ph :: proc(tree: Node, want: Ph_Ref, master: bool) -> Node {
	if !ok_node(tree) {
		return NO_NODE
	}
	shapes := kids(path(tree, "cSld", "spTree"), "sp")
	if !master && want.idx != "" && !is_title(want.type) {
		for sp in shapes {
			r := ph_of(sp)
			if r.ok && r.idx == want.idx {
				return sp
			}
		}
	}
	wt := want.type
	if master {
		// A master has one title and one body; everything that is not a
		// title, a date, a footer or a slide number inherits the body.
		switch {
		case is_title(wt):
			wt = "title"
		case wt == "dt" || wt == "ftr" || wt == "sldNum":
		case:
			wt = "body"
		}
	}
	for sp in shapes {
		r := ph_of(sp)
		if !r.ok {
			continue
		}
		rt := r.type
		if master && rt == "" {
			rt = "body"
		}
		if rt == wt || (is_title(rt) && is_title(wt)) || (!master && rt == "" && wt == "") {
			return sp
		}
	}
	return NO_NODE
}

// Ctx is where a shape sits: its slide's layout and master, for inheritance.
@(private = "file")
Ctx :: struct {
	part:   string, // the part the shapes come from, for picture rels
	layout: Node,
	master: Node,
	xf:     Xf,
	skip_palmy_decor: bool,
}

// Chain lists, most specific first, the paragraph-property containers a
// paragraph at `lvl` inherits from.
@(private = "file")
chain :: proc(im: ^Imp, cx: ^Ctx, sp: Node, ph: Ph_Ref, para: Node, lvl: int) -> [dynamic]Node {
	out := make([dynamic]Node, context.temp_allocator)
	lv := fmt.tprintf("lvl%dpPr", lvl + 1)
	if pp := kid(para, "pPr"); ok_node(pp) {
		append(&out, pp)
	}
	if n := path(sp, "txBody", "lstStyle", lv); ok_node(n) {
		append(&out, n)
	}
	if ph.ok {
		if l := find_ph(cx.layout, ph, false); ok_node(l) {
			if n := path(l, "txBody", "lstStyle", lv); ok_node(n) {
				append(&out, n)
			}
		}
		if m := find_ph(cx.master, ph, true); ok_node(m) {
			if n := path(m, "txBody", "lstStyle", lv); ok_node(n) {
				append(&out, n)
			}
		}
	}
	styles := path(cx.master, "txStyles")
	which := "otherStyle"
	if ph.ok {
		which = is_title(ph.type) ? "titleStyle" : "bodyStyle"
	}
	if n := path(styles, which, lv); ok_node(n) {
		append(&out, n)
	}
	return out
}

@(private = "file")
Rp :: struct {
	sz:        int, // hundredths of a point; 0 unset
	b, i:      int, // -1 unset
	col:       u32,
	col_set:   bool,
	face:      string,
}

@(private = "file")
merge_rpr :: proc(im: ^Imp, r: ^Rp, n: Node) {
	if !ok_node(n) {
		return
	}
	if r.sz == 0 && has_attr(n, "sz") {
		r.sz = int(attr_int(n, "sz"))
	}
	if r.b < 0 && has_attr(n, "b") {
		r.b = attr(n, "b") == "1" || attr(n, "b") == "true" ? 1 : 0
	}
	if r.i < 0 && has_attr(n, "i") {
		r.i = attr(n, "i") == "1" || attr(n, "i") == "true" ? 1 : 0
	}
	if !r.col_set {
		if v, set, none := fill_of(im, n); set {
			r.col = none ? 0 : v
			r.col_set = true
		}
	}
	if r.face == "" {
		r.face = attr(kid(n, "latin"), "typeface")
	}
}

// is_descendant reports whether `n` sits somewhere under `root`.
@(private = "file")
is_descendant :: proc(root, n: Node) -> bool {
	if !ok_node(root) || !ok_node(n) || root.doc != n.doc {
		return false
	}
	id := n.id
	for depth := 0; depth < 64; depth += 1 {
		if id == root.id {
			return true
		}
		if id == 0 {
			return false
		}
		id = n.doc.elements[id].parent
	}
	return false
}

// ---------------------------------------------------------------------------
// Text
// ---------------------------------------------------------------------------

@(private = "file")
Piece :: struct {
	text: string,
	sz:   f32, // slide units
	b, i: bool,
	col:  u32,
}

@(private = "file")
read_text :: proc(im: ^Imp, cx: ^Ctx, sp: Node, ph: Ph_Ref) -> (pieces: [dynamic]Piece, bullets: bool, any_text: bool, align: Halign) {
	pieces = make([dynamic]Piece, context.temp_allocator)
	body := kid(sp, "txBody")
	paras := kids(body, "p")
	first := true
	for para, pi in paras {
		lvl := int(attr_int(kid(para, "pPr"), "lvl"))
		ch := chain(im, cx, sp, ph, para, lvl)
		// bullet and alignment: the first container that says
		bullet := false
		for c in ch {
			if ok_node(kid(c, "buNone")) {
				break
			}
			if ok_node(kid(c, "buChar")) || ok_node(kid(c, "buAutoNum")) || ok_node(kid(c, "buBlip")) {
				bullet = true
				break
			}
		}
		if first {
			for c in ch {
				if a := attr(c, "algn"); a != "" {
					align = a == "ctr" ? .Center : (a == "r" ? .Right : .Left)
					break
				}
			}
		}
		base := Rp {
			b = -1,
			i = -1,
		}
		styles := path(cx.master, "txStyles")
		for c in ch {
			// A shape's p:style names the colour its text defaults to (white
			// on PowerPoint's default blue shapes); that sits above the
			// master's text styles and below anything the shape says.
			if !base.col_set && c.doc == styles.doc && is_descendant(styles, c) {
				if fr := path(sp, "style", "fontRef"); ok_node(fr) {
					for cc in kids(fr) {
						if v, good := colour(im, cc); good {
							base.col, base.col_set = v, true
						}
					}
				}
			}
			merge_rpr(im, &base, kid(c, "defRPr"))
			if has_attr(kid(c, "defRPr"), "cap") && attr(kid(c, "defRPr"), "cap") != "none" {
				lose(im, "all-caps and small-caps text (kept in its own case)")
			}
		}
		if pi > 0 {
			append(&pieces, Piece{text = "\n"})
		}
		para_has := false
		for r in kids(para) {
			t := ""
			rp := base
			switch name_of(r) {
			case "r", "fld":
				t = text_of(kid(r, "t"))
				rp2 := Rp {
					b = -1,
					i = -1,
				}
				merge_rpr(im, &rp2, kid(r, "rPr"))
				// run first, then what the paragraph inherits
				if rp2.sz == 0 {rp2.sz = base.sz}
				if rp2.b < 0 {rp2.b = base.b}
				if rp2.i < 0 {rp2.i = base.i}
				if !rp2.col_set {rp2.col, rp2.col_set = base.col, base.col_set}
				if rp2.face == "" {rp2.face = base.face}
				rp = rp2
			case "br":
				t = "\n"
			case:
				continue
			}
			if t == "" {
				continue
			}
			if rp.face != "" && !strings.has_prefix(rp.face, "+") && rp.face != PPTX_SANS && rp.face != PPTX_MONO {
				lose(im, fmt.tprintf("the %s typeface (set in the deck's own face)", rp.face))
			}
			if !para_has && bullet {
				append(&pieces, Piece{text = "- "})
			}
			para_has = true
			sz := rp.sz > 0 ? rp.sz : 1800
			units := f32(f64(sz) / 100 * 12700 * im.s)
			col := rp.col_set ? rp.col : im.scheme["dk1"]
			if !rp.col_set {
				if m, ok := im.scheme[im.clrmap["tx1"]]; ok {
					col = m
				}
			}
			append(&pieces, Piece{text = t, sz = units, b = rp.b == 1, i = rp.i == 1, col = col})
			if strings.trim_space(t) != "" {
				any_text = true
			}
		}
		if bullet && para_has {
			bullets = true
		}
		first = false
	}
	return
}

// text_element folds pieces into one text box: the commonest size and colour
// become the box's, everything else becomes a run.
@(private = "file")
text_element :: proc(im: ^Imp, pieces: []Piece, style: Style, box: Box, align: Halign, valign: Valign) -> Element {
	e := text_box("", style, box.x, box.y, box.w, box.h, align)
	e.valign = valign
	e.rotation = box.rot
	b := strings.builder_make(context.temp_allocator)
	size_w := make(map[f32]int, 8, context.temp_allocator)
	col_w := make(map[u32]int, 8, context.temp_allocator)
	all_bold := true
	for pc in pieces {
		if pc.sz <= 0 {
			continue
		}
		n := len(strings.trim_space(pc.text))
		size_w[f32(math.round(f64(pc.sz) * 4) / 4)] += n
		col_w[pc.col] += n
		if n > 0 && !pc.b {
			all_bold = false
		}
	}
	best_size, best_col := text_size(&e), u32(0)
	bw, cw := -1, -1
	for k, v in size_w {
		if v > bw || (v == bw && k < best_size) {
			best_size, bw = k, v
		}
	}
	for k, v in col_w {
		if v > cw || (v == cw && k < best_col) {
			best_col, cw = k, v
		}
	}
	spec := TYPE_SCALE[style]
	e.size = abs(best_size - spec.size) < 0.3 ? 0 : best_size
	box_bold := spec.bold || (all_bold && bw > 0)
	if all_bold && bw > 0 && !spec.bold {
		e.bold = true
	}
	// The box's colour: the theme's own when it is what this style would
	// use anyway, so a theme change still recolours it.
	def := spec.muted ? im.theme.muted : im.theme.fg
	if best_col & 0xffffff == def & 0xffffff {
		e.color = SLOT_NONE
	} else {
		e.color = paint_from(im, best_col)
	}

	runs := make([dynamic]Run, context.temp_allocator)
	for pc in pieces {
		start := strings.builder_len(b)
		strings.write_string(&b, pc.text)
		if pc.sz <= 0 {
			continue
		}
		r := Run {
			start = start,
			end   = strings.builder_len(b),
		}
		r.bold = pc.b && !box_bold
		r.italic = pc.i
		if pc.col != best_col {
			r.color = paint_from(im, pc.col)
			if r.color == SLOT_NONE {
				r.color = 0
			}
		}
		if abs(pc.sz - best_size) >= 0.3 {
			r.size = pc.sz
		}
		append(&runs, r)
	}
	e.text = strings.clone(strings.to_string(b))
	e.runs = runs_clean(runs[:], len(e.text))
	// An exporter that folds a box's opacity into its text colour (this one
	// does) leaves every run translucent: that is the box's opacity.
	if a := best_col >> 24; a > 0 && a < 255 {
		e.opacity = alpha_of(best_col)
		if e.color > SLOT_MAX {
			e.color = paint_from(im, best_col | 0xff000000)
		} else if e.color == SLOT_NONE {
			e.color = SLOT_NONE
		}
		def2 := spec.muted ? im.theme.muted : im.theme.fg
		if best_col & 0xffffff == def2 & 0xffffff {
			e.color = SLOT_NONE
		}
	}
	return e
}

@(private = "file")
valign_of :: proc(im: ^Imp, cx: ^Ctx, sp: Node, ph: Ph_Ref) -> Valign {
	cands := [3]Node{path(sp, "txBody", "bodyPr"), {}, {}}
	if ph.ok {
		cands[1] = path(find_ph(cx.layout, ph, false), "txBody", "bodyPr")
		cands[2] = path(find_ph(cx.master, ph, true), "txBody", "bodyPr")
	}
	for c in cands {
		switch attr(c, "anchor") {
		case "t":
			return .Top
		case "ctr":
			return .Middle
		case "b":
			return .Bottom
		}
	}
	return .Top
}

// ---------------------------------------------------------------------------
// Shapes
// ---------------------------------------------------------------------------

@(private = "file")
style_for :: proc(ph: Ph_Ref, bullets: bool) -> Style {
	if ph.ok {
		switch {
		case is_title(ph.type):
			return .Title
		case ph.type == "subTitle":
			return .Subtitle
		}
	}
	return bullets ? .Bullets : .Body
}

@(private = "file")
shape_geometry :: proc(im: ^Imp, cx: ^Ctx, sp: Node, ph: Ph_Ref) -> Box {
	if b := box_of(im, path(sp, "spPr", "xfrm"), cx.xf); b.ok {
		return b
	}
	if ph.ok {
		if l := find_ph(cx.layout, ph, false); ok_node(l) {
			if b := box_of(im, path(l, "spPr", "xfrm"), XF_ID); b.ok {
				return b
			}
		}
		if m := find_ph(cx.master, ph, true); ok_node(m) {
			if b := box_of(im, path(m, "spPr", "xfrm"), XF_ID); b.ok {
				return b
			}
		}
	}
	return {}
}

// style_ref resolves a shape's p:style fillRef or lnRef: the theme colour a
// shape drawn with PowerPoint's default style is filled or outlined with.
@(private = "file")
style_ref :: proc(im: ^Imp, sp: Node, which: string) -> (u32, bool) {
	ref := path(sp, "style", which)
	if !ok_node(ref) || attr_int(ref, "idx") == 0 {
		return 0, false
	}
	for c in kids(ref) {
		if v, ok := colour(im, c); ok {
			return v, true
		}
	}
	return 0, false
}

@(private = "file")
add_shape :: proc(im: ^Imp, cx: ^Ctx, sp: Node, out: ^[dynamic]Element) {
	ph := ph_of(sp)
	if ph.ok && (ph.type == "dt" || ph.type == "ftr" || ph.type == "sldNum") && cx.layout.doc == nil {
		return
	}
	name := attr(path(sp, "nvSpPr", "cNvPr"), "name")
	if cx.skip_palmy_decor && (strings.has_prefix(name, "Decor ") || strings.has_prefix(name, "Footer ")) {
		return
	}
	box := shape_geometry(im, cx, sp, ph)
	if !box.ok {
		if !ph.ok {
			lose(im, "shapes with no position")
		}
		return
	}
	sppr := kid(sp, "spPr")
	prst := attr(kid(sppr, "prstGeom"), "prst")
	if bf := kid(sppr, "blipFill"); ok_node(bf) && ok_node(kid(bf, "blip")) {
		// A shape filled with a picture (LibreOffice writes a rounded picture
		// this way) is a picture in this program's model.
		src, good := copy_media(im, rel_target(im, cx.part, attr(kid(bf, "blip"), "embed")))
		if good {
			e := image_box(src, box.x, box.y, box.w, box.h)
			e.radius = 0
			if prst == "roundRect" {
				adj := 16667.0
				for gd in kids(path(sppr, "prstGeom", "avLst"), "gd") {
					if f := attr(gd, "fmla"); strings.has_prefix(f, "val ") {
						if v, ok := strconv.parse_f64(f[4:]); ok {
							adj = v
						}
					}
				}
				e.radius = tidy(f32(adj / 100000) * min(box.w, box.h))
			}
			e.rotation = box.rot
			append(out, e)
			return
		}
	}
	if ok_node(kid(sppr, "custGeom")) {
		lose(im, "custom shapes drawn as rectangles")
		prst = "rect"
	}
	fill, fill_set, fill_none := fill_of(im, sppr)
	if !fill_set {
		if v, ok := style_ref(im, sp, "fillRef"); ok {
			fill, fill_set = v, true
		}
	}
	ln := kid(sppr, "ln")
	stroke, stroke_set, stroke_none := fill_of(im, ln)
	if !stroke_set {
		if v, ok := style_ref(im, sp, "lnRef"); ok && !ok_node(kid(ln, "noFill")) {
			stroke, stroke_set = v, true
		}
	}
	stroke_w := f32(f64(attr_int(ln, "w", 12700)) * im.s)
	radius: f32 = 0
	if prst == "roundRect" {
		adj := 16667.0
		for gd in kids(path(sppr, "prstGeom", "avLst"), "gd") {
			f := attr(gd, "fmla")
			if strings.has_prefix(f, "val ") {
				if v, ok := strconv.parse_f64(f[4:]); ok {
					adj = v
				}
			}
		}
		radius = tidy(f32(adj / 100000) * min(abs(box.w), abs(box.h)))
	}

	if prst == "line" || prst == "straightConnector1" {
		add_line(im, sp, box, out)
		return
	}

	pieces, bullets, any_text, align := read_text(im, cx, sp, ph)
	has_fill := fill_set && !fill_none
	has_stroke := stroke_set && !stroke_none && stroke_w > 0

	// The shape itself, unless the text box can carry its fill (a text box
	// in this program has a rectangular, optionally rounded, background).
	shape_kind: Kind = prst == "ellipse" ? .Ellipse : .Rect
	if prst != "" && prst != "rect" && prst != "roundRect" && prst != "ellipse" {
		lose(im, fmt.tprintf("%s shapes drawn as rectangles", prst))
	}
	text_carries := shape_kind == .Rect && any_text
	if (has_fill || has_stroke) && !text_carries {
		e := shape(shape_kind, box.x, box.y, box.w, box.h, has_fill ? paint_from(im, fill) : SLOT_NONE)
		e.radius = radius
		e.rotation = box.rot
		e.fill_a = has_fill ? alpha_of(fill) : 1
		e.stroke = has_stroke ? paint_from(im, stroke | 0xff000000) : SLOT_NONE
		e.stroke_w = has_stroke ? stroke_w : 0
		if has_fill {
			e.fill = paint_from(im, fill | 0xff000000)
		} else {
			e.fill = SLOT_NONE
		}
		// A translucent outline is the element's opacity (this program's
		// exporter folds opacity into both alphas); the fill keeps the rest.
		if has_stroke && stroke >> 24 < 255 {
			e.opacity = alpha_of(stroke)
			if has_fill {
				e.fill_a = clamp(alpha_of(fill) / e.opacity, 0.02, 1)
			}
		}
		append(out, e)
	}
	if !any_text {
		return
	}
	style := style_for(ph, bullets)
	if style == .Title && !im.palmy {
		bold := true
		for pc in pieces {
			if pc.sz > 0 && strings.trim_space(pc.text) != "" && !pc.b {
				bold = false
			}
		}
		if !bold {
			lose(im, "titles set in a regular weight (this deck's Title style is bold)")
		}
	}
	if im.palmy {
		if i := strings.last_index(name, " · "); i >= 0 {
			for nm, st in STYLE_NAMES {
				if nm == name[i + len(" · "):] {
					style = st
				}
			}
		}
	}
	e := text_element(im, pieces[:], style, box, align, valign_of(im, cx, sp, ph))
	if text_carries {
		if has_fill {
			e.fill = paint_from(im, fill | 0xff000000)
			e.fill_a = alpha_of(fill)
		}
		if has_stroke {
			e.stroke = paint_from(im, stroke | 0xff000000)
			e.stroke_w = stroke_w
		}
		e.radius = radius
	}
	append(out, e)
}

@(private = "file")
add_line :: proc(im: ^Imp, sp: Node, box: Box, out: ^[dynamic]Element) {
	ln := path(sp, "spPr", "ln")
	col, set, none := fill_of(im, ln)
	if !set {
		if v, ok := style_ref(im, sp, "lnRef"); ok {
			col, set = v, true
		}
	}
	if none {
		return
	}
	head := attr(kid(ln, "headEnd"), "type")
	tail := attr(kid(ln, "tailEnd"), "type")
	arrow := (tail != "" && tail != "none") || (head != "" && head != "none")
	e := shape(arrow ? .Arrow : .Line, box.x, box.y, box.w, box.h, set ? paint_from(im, col | 0xff000000) : SLOT_FG)
	if box.flip_h {
		e.x += e.w
		e.w = -e.w
	}
	if box.flip_v {
		e.y += e.h
		e.h = -e.h
	}
	if (head != "" && head != "none") && !(tail != "" && tail != "none") {
		// The head is at the start: turn the line round.
		e.x, e.w = e.x + e.w, -e.w
		e.y, e.h = e.y + e.h, -e.h
	}
	e.rotation = box.rot
	e.stroke_w = max(f32(f64(attr_int(ln, "w", 12700)) * im.s), 1)
	// DrawingML sizes a head in three steps relative to the line width;
	// "lg" is what the exporter writes for this program's default head
	// (26 on a 4 wide line).
	end := (tail != "" && tail != "none") ? kid(ln, "tailEnd") : kid(ln, "headEnd")
	k: f32 = 4.5
	switch attr(end, "len") {
	case "lg":
		k = 6.5
	case "sm":
		k = 3
	}
	e.head = max(e.stroke_w * k, 12)
	append(out, e)
}

@(private = "file")
add_picture :: proc(im: ^Imp, cx: ^Ctx, pic: Node, out: ^[dynamic]Element) {
	ph := ph_of(pic)
	box := box_of(im, path(pic, "spPr", "xfrm"), cx.xf)
	if !box.ok && ph.ok {
		box = shape_geometry(im, cx, pic, ph)
	}
	if !box.ok {
		return
	}
	rid := attr(path(pic, "blipFill", "blip"), "embed")
	target := rel_target(im, cx.part, rid)
	src, ok := copy_media(im, target)
	if !ok {
		lose(im, "pictures in formats this program cannot draw (EMF, WMF, SVG, TIFF)")
		return
	}
	if ok_node(path(pic, "blipFill", "srcRect")) && !im.palmy {
		// The renderer fits a picture by covering its box; a crop the author
		// chose is approximated by that, not reproduced.
		r := path(pic, "blipFill", "srcRect")
		if attr_int(r, "l") != 0 || attr_int(r, "t") != 0 || attr_int(r, "r") != 0 || attr_int(r, "b") != 0 {
			lose(im, "picture crops (pictures are fitted to cover their box)")
		}
	}
	e := image_box(src, box.x, box.y, box.w, box.h)
	e.radius = 0
	if attr(path(pic, "spPr", "prstGeom"), "prst") == "roundRect" {
		adj := 16667.0
		for gd in kids(path(pic, "spPr", "prstGeom", "avLst"), "gd") {
			if f := attr(gd, "fmla"); strings.has_prefix(f, "val ") {
				if v, ok := strconv.parse_f64(f[4:]); ok {
					adj = v
				}
			}
		}
		e.radius = tidy(f32(adj / 100000) * min(box.w, box.h))
	}
	e.rotation = box.rot
	append(out, e)
}

// copy_media writes a package's picture into the media directory once, and
// returns how the deck refers to it.
@(private = "file")
copy_media :: proc(im: ^Imp, target: string) -> (string, bool) {
	if target == "" {
		return "", false
	}
	if got, ok := im.media[target]; ok {
		return got, got != ""
	}
	data, ok := zip_find(im.files, target)
	if !ok || len(data) < 8 {
		im.media[target] = ""
		return "", false
	}
	ext := ""
	switch {
	case data[0] == 0x89 && data[1] == 'P':
		ext = "png"
	case data[0] == 0xff && data[1] == 0xd8:
		ext = "jpeg"
	case data[0] == 'G' && data[1] == 'I' && data[2] == 'F':
		ext = "gif"
	case data[0] == 'B' && data[1] == 'M':
		ext = "bmp"
	}
	if ext == "" {
		im.media[target] = ""
		return "", false
	}
	im.pictures += 1
	name := fmt.tprintf("image%d.%s", im.pictures, ext)
	if im.media_dir != "" {
		_ = os.make_directory_all(im.media_dir)
		if os.write_entire_file(fmt.tprintf("%s/%s", im.media_dir, name), data) != nil {
			im.media[target] = ""
			return "", false
		}
	}
	src := media_src(im.media_dir == "" ? "media" : im.media_dir, name)
	im.media[target] = src
	return src, true
}

@(private = "file")
add_table :: proc(im: ^Imp, cx: ^Ctx, gf: Node, out: ^[dynamic]Element) {
	box := box_of(im, kid(gf, "xfrm"), cx.xf)
	tbl := find(gf, "tbl")
	if !ok_node(tbl) {
		if ok_node(find(gf, "chart")) {
			lose(im, "charts")
		} else {
			lose(im, "SmartArt and other embedded objects")
		}
		return
	}
	lose(im, "tables (kept as their text, one row per line)")
	if !box.ok {
		return
	}
	b := strings.builder_make(context.temp_allocator)
	for tr, ri in kids(tbl, "tr") {
		if ri > 0 {
			strings.write_byte(&b, '\n')
		}
		for tc, ci in kids(tr, "tc") {
			if ci > 0 {
				strings.write_string(&b, "  ·  ")
			}
			for para, pi in kids(kid(tc, "txBody"), "p") {
				if pi > 0 {
					strings.write_byte(&b, ' ')
				}
				for r in kids(para, "r") {
					strings.write_string(&b, text_of(kid(r, "t")))
				}
			}
		}
	}
	e := text_box(strings.clone(strings.to_string(b)), .Body, box.x, box.y, box.w, box.h)
	e.size = 20
	append(out, e)
}

// walk_tree adds every shape of a shape tree (or group) in paint order.
@(private = "file")
walk_tree :: proc(im: ^Imp, cx: ^Ctx, tree: Node, out: ^[dynamic]Element, only_decor := false) {
	for n in kids(tree) {
		switch name_of(n) {
		case "sp":
			if only_decor && ph_of(n).ok {
				continue
			}
			add_shape(im, cx, n, out)
		case "pic":
			if only_decor && ph_of(n).ok {
				continue
			}
			add_picture(im, cx, n, out)
		case "cxnSp":
			box := box_of(im, path(n, "spPr", "xfrm"), cx.xf)
			if box.ok {
				add_line(im, n, box, out)
			}
		case "grpSp":
			x := path(n, "grpSpPr", "xfrm")
			off, ext := kid(x, "off"), kid(x, "ext")
			coff, cext := kid(x, "chOff"), kid(x, "chExt")
			sub := cx^
			if ok_node(off) && ok_node(ext) && ok_node(cext) {
				cw := f64(attr_int(cext, "cx"))
				ch := f64(attr_int(cext, "cy"))
				kx := cw != 0 ? f64(attr_int(ext, "cx")) / cw : 1
				ky := ch != 0 ? f64(attr_int(ext, "cy")) / ch : 1
				// child → group space → parent space
				gx := f64(attr_int(off, "x")) - f64(attr_int(coff, "x")) * kx
				gy := f64(attr_int(off, "y")) - f64(attr_int(coff, "y")) * ky
				sub.xf = {cx.xf.ax * kx, cx.xf.ax * gx + cx.xf.bx, cx.xf.ay * ky, cx.xf.ay * gy + cx.xf.by}
			}
			if attr_int(x, "rot") != 0 {
				lose(im, "group rotation")
			}
			walk_tree(im, &sub, n, out, only_decor)
		case "graphicFrame":
			if only_decor {
				continue
			}
			add_table(im, cx, n, out)
		case "AlternateContent":
			// Prefer the fallback a reader without the extension draws.
			fb := kid(n, "Fallback")
			if !ok_node(fb) {
				fb = kid(n, "Choice")
			}
			walk_tree(im, cx, fb, out, only_decor)
		}
	}
}

// ---------------------------------------------------------------------------
// Slides
// ---------------------------------------------------------------------------

@(private = "file")
layout_of_type :: proc(t: string) -> Layout {
	switch t {
	case "title":
		return .Title
	case "obj", "tx", "titleOnly", "objTx", "txAndObj", "objAndTx", "clipArtAndTx", "txAndClipArt":
		return .Title_Content
	case "twoObj", "twoTxTwoObj", "twoColTx", "objOverTx", "txOverObj":
		return .Two_Content
	case "secHead":
		return .Section_Header
	case "picTx":
		return .Picture
	}
	return .Blank
}

@(private = "file")
bg_of :: proc(im: ^Imp, holder: Node) -> (v: u32, v2: u32, ok: bool) {
	bg := path(holder, "cSld", "bg")
	if !ok_node(bg) {
		return 0, 0, false
	}
	if pr := kid(bg, "bgPr"); ok_node(pr) {
		if gf := kid(pr, "gradFill"); ok_node(gf) {
			gs := kids(path(gf, "gsLst"), "gs")
			if len(gs) >= 2 {
				a, b: u32
				oka, okb := false, false
				for c in kids(gs[0]) {
					if x, good := colour(im, c); good {
						a, oka = x, true
					}
				}
				for c in kids(gs[len(gs) - 1]) {
					if x, good := colour(im, c); good {
						b, okb = x, true
					}
				}
				if oka && okb {
					return a | 0xff000000, b | 0xff000000, true
				}
			}
		}
		if x, set, none := fill_of(im, pr); set && !none {
			return x | 0xff000000, 0, true
		}
	}
	if ref := kid(bg, "bgRef"); ok_node(ref) {
		for c in kids(ref) {
			if x, good := colour(im, c); good {
				return x | 0xff000000, 0, true
			}
		}
	}
	return 0, 0, false
}

@(private = "file")
read_notes :: proc(im: ^Imp, slide_part: string) -> string {
	np := rel_of_type(im, slide_part, "/notesSlide")
	if np == "" {
		return ""
	}
	n := part(im, np)
	for sp in kids(path(n, "cSld", "spTree"), "sp") {
		ph := ph_of(sp)
		if !ph.ok || ph.type != "body" {
			continue
		}
		b := strings.builder_make(context.temp_allocator)
		for para, pi in kids(kid(sp, "txBody"), "p") {
			if pi > 0 {
				strings.write_byte(&b, '\n')
			}
			for r in kids(para) {
				switch name_of(r) {
				case "r", "fld":
					strings.write_string(&b, text_of(kid(r, "t")))
				case "br":
					strings.write_byte(&b, '\n')
				}
			}
		}
		return strings.clone(strings.trim_right_space(strings.to_string(b)))
	}
	return ""
}

@(private = "file")
read_transition :: proc(im: ^Imp, sld: Node) -> (Transition, int) {
	tr := find(sld, "transition")
	if !ok_node(tr) {
		return .None, 0
	}
	ms := 0
	switch attr(tr, "spd") {
	case "med":
		ms = 750
	case "slow":
		ms = 1000
	}
	if d := attr(tr, "dur"); d != "" {
		if v, ok := strconv.parse_int(d); ok {
			ms = v
		}
	}
	for k in kids(tr) {
		switch name_of(k) {
		case "fade":
			return .Fade, ms
		case "push", "wipe":
			// The projector has one direction for each: a push in from the
			// right, a wipe from the left (dir="r" for both, as LibreOffice
			// reads them). Any other direction plays that one.
			d := attr(k, "dir")
			if d != "" && d != "r" {
				lose(im, fmt.tprintf("%s directions other than the projector's", name_of(k)))
			}
			return name_of(k) == "push" ? .Push : .Wipe, ms
		case "cut":
			return .None, 0
		case "sndAc", "extLst":
			continue
		case:
			lose(im, fmt.tprintf("%s transitions played as a fade", name_of(k)))
			return .Fade, ms
		}
	}
	return .Fade, ms
}

// import_pptx reads a .pptx package. `media_dir` is where pictures are written;
// empty writes none (a dry run), and the deck still names where they would be.
import_pptx :: proc(raw: []u8, media_dir: string) -> (d: Deck, rep: Import_Report, err: string) {
	im := Imp {
		docs      = make(map[string]^xml.Document, 64, context.temp_allocator),
		scheme    = make(map[string]u32, 16, context.temp_allocator),
		clrmap    = make(map[string]string, 16, context.temp_allocator),
		media     = make(map[string]string, 16, context.temp_allocator),
		lost      = make(map[string]int, 16, context.temp_allocator),
		media_dir = media_dir,
	}
	files, ok := zip_read(raw, context.temp_allocator)
	if !ok {
		return {}, {}, "not a ZIP package"
	}
	im.files = files

	main_part := ""
	for rel in kids(part(&im, "_rels/.rels"), "Relationship") {
		if strings.has_suffix(attr(rel, "Type"), "/officeDocument") {
			main_part = resolve("", attr(rel, "Target"))
		}
	}
	pres := part(&im, main_part)
	if !ok_node(pres) || name_of(pres) != "presentation" {
		return {}, {}, "not a PowerPoint presentation (no ppt/presentation.xml)"
	}
	app := part(&im, "docProps/app.xml")
	im.palmy = strings.contains(text_of(kid(app, "Application")), "palmy slides")

	// Slide size, and the uniform scale that fits it into 1280x720.
	sz := kid(pres, "sldSz")
	cx := f64(attr_int(sz, "cx", PPTX_SLIDE_CX))
	cy := f64(attr_int(sz, "cy", PPTX_SLIDE_CY))
	im.s = min(f64(SLIDE_W) / cx, f64(SLIDE_H) / cy)
	im.ox = (f64(SLIDE_W) - cx * im.s) / 2
	im.oy = (f64(SLIDE_H) - cy * im.s) / 2
	if abs(cx / cy - 16.0 / 9) > 0.02 {
		lose(&im, fmt.tprintf("the %.2f:1 slide shape (centred on a 16:9 slide)", cx / cy))
	}

	// Slides, in the order the presentation lists them.
	slide_parts := make([dynamic]string, context.temp_allocator)
	for sid in kids(kid(pres, "sldIdLst"), "sldId") {
		// The relationship id is the namespaced `r:id`, not the plain `id`.
		rid := ""
		for a in sid.doc.elements[sid.id].attribs {
			if strings.contains(a.key, ":") && local(a.key) == "id" {
				rid = a.val
			}
		}
		t := rel_target(&im, main_part, rid)
		if t != "" {
			append(&slide_parts, t)
		}
	}
	if len(slide_parts) == 0 {
		return {}, {}, "the presentation has no slides"
	}

	// The theme and colour map come from the first slide's master.
	first_layout := rel_of_type(&im, slide_parts[0], "/slideLayout")
	master_part := rel_of_type(&im, first_layout, "/slideMaster")
	master := part(&im, master_part)
	theme_part := rel_of_type(&im, master_part, "/theme")
	theme := part(&im, theme_part)
	scheme := path(theme, "themeElements", "clrScheme")
	for c in kids(scheme) {
		for v in kids(c) {
			if got, good := colour(&im, v); good {
				im.scheme[name_of(c)] = got
			}
			if name_of(v) == "sysClr" {
				x, _ := strconv.parse_u64_of_base(attr(v, "lastClr"), 16)
				im.scheme[name_of(c)] = 0xff000000 | u32(x)
			}
		}
	}
	cm := kid(master, "clrMap")
	for a in ([?]string{"bg1", "tx1", "bg2", "tx2", "accent1", "accent2", "accent3", "accent4", "accent5", "accent6", "hlink", "folHlink"}) {
		v := attr(cm, a)
		im.clrmap[a] = v != "" ? v : a
	}

	th := Theme {
		name    = strings.clone(attr(scheme, "name") != "" ? attr(scheme, "name") : "Imported"),
		fg      = im.scheme[im.clrmap["tx1"]],
		bg      = im.scheme[im.clrmap["bg1"]],
		muted   = im.scheme[im.clrmap["tx2"]],
		surface = im.scheme[im.clrmap["bg2"]],
		accent  = im.scheme["accent1"],
		accent2 = im.scheme["accent2"],
	}
	if b1, b2, has := bg_of(&im, master); has {
		th.bg, th.bg2 = b1, b2
	}
	if im.palmy {
		if known, found := theme_by_name(th.name); found {
			th = known
			im.ours = true
		}
	}
	for v in ([?]^u32{&th.fg, &th.bg, &th.muted, &th.surface, &th.accent, &th.accent2}) {
		v^ |= 0xff000000
	}
	if !im.ours {
		lum := 0.2126 * f32((th.bg >> 16) & 0xff) + 0.7152 * f32((th.bg >> 8) & 0xff) + 0.0722 * f32(th.bg & 0xff)
		th.dark = lum < 128
		if th.fg & 0xffffff == th.bg & 0xffffff {
			th.fg = th.dark ? 0xffffffff : 0xff000000
		}
	}
	im.theme = th

	core := part(&im, "docProps/core.xml")
	d = Deck {
		version  = DECK_VERSION,
		title    = strings.clone(text_of(kid(core, "title"))),
		author   = strings.clone(text_of(kid(core, "creator"))),
		theme    = th,
		no_decor = !im.palmy,
		slides   = make([dynamic]Slide),
	}

	for sp_name in slide_parts {
		sld := part(&im, sp_name)
		if !ok_node(sld) {
			lose(&im, "slides that could not be read")
			continue
		}
		lay_name := rel_of_type(&im, sp_name, "/slideLayout")
		lay := part(&im, lay_name)
		mas_name := rel_of_type(&im, lay_name, "/slideMaster")
		mas := part(&im, mas_name)
		s := Slide {
			layout = layout_of_type(attr(lay, "type")),
			elems  = make([dynamic]Element),
		}
		elems := make([dynamic]Element, context.temp_allocator)

		// The background, when it is not the theme's.
		bgc, _, has_bg := bg_of(&im, sld)
		if !has_bg {
			bgc, _, has_bg = bg_of(&im, lay)
		}
		if has_bg && bgc & 0xffffff != th.bg & 0xffffff {
			r := shape(.Rect, 0, 0, SLIDE_W, SLIDE_H, paint_from(&im, bgc))
			r.radius = 0
			append(&elems, r)
		}

		// A foreign master's and layout's own shapes, behind the slide's.
		if !im.palmy {
			show_master := attr(sld, "showMasterSp") != "0"
			if show_master && attr(lay, "showMasterSp") != "0" {
				mcx := Ctx{part = mas_name, xf = XF_ID}
				walk_tree(&im, &mcx, path(mas, "cSld", "spTree"), &elems, true)
			}
			if show_master {
				lcx := Ctx{part = lay_name, xf = XF_ID}
				walk_tree(&im, &lcx, path(lay, "cSld", "spTree"), &elems, true)
			}
		}

		cx := Ctx {
			part             = sp_name,
			layout           = lay,
			master           = mas,
			xf               = XF_ID,
			skip_palmy_decor = im.palmy,
		}
		walk_tree(&im, &cx, path(sld, "cSld", "spTree"), &elems)
		for e in elems {
			ee := e
			normalise(&ee)
			append(&s.elems, ee)
		}
		s.notes = read_notes(&im, sp_name)
		s.transition, s.transition_ms = read_transition(&im, sld)
		if im.palmy && s.transition_ms == 0 {
			s.transition_ms = 0
		}
		if ok_node(find(sld, "timing")) {
			lose(&im, "animations")
		}
		append(&d.slides, s)
	}
	if d.title == "" {
		d.title = "Imported deck"
	}

	rep.pictures = im.pictures
	rep.lost = make([dynamic]string)
	keys := make([dynamic]string, context.temp_allocator)
	for k in im.lost {
		append(&keys, k)
	}
	slice.sort(keys[:])
	for k in keys {
		append(&rep.lost, fmt.aprintf("%d× %s", im.lost[k], k))
	}
	return d, rep, ""
}

import_pptx_file :: proc(path_in: string, media_dir: string) -> (Deck, Import_Report, string) {
	raw, e := os.read_entire_file_from_path(path_in, context.temp_allocator)
	if e != nil {
		return {}, {}, fmt.tprintf("cannot read %s", path_in)
	}
	return import_pptx(raw, media_dir)
}

// ---------------------------------------------------------------------------
// PDF
// ---------------------------------------------------------------------------

// import_pdf_file renders every page with poppler's pdftoppm into the media
// directory and makes one Blank slide per page. A dry run (empty media_dir)
// renders into a scratch directory to count the pages, and removes it.
import_pdf_file :: proc(path_in: string, media_dir: string) -> (d: Deck, rep: Import_Report, err: string) {
	if _, found := kit.run({"sh", "-c", "command -v pdftoppm"}); !found {
		return {}, {}, "PDF import needs pdftoppm (poppler-utils), which is not installed"
	}
	dir := media_dir
	scratch := dir == ""
	if scratch {
		tmp := os.get_env("TMPDIR", context.temp_allocator)
		dir = fmt.tprintf("%s/palmy-slides-pdf-dry-run", tmp == "" ? "/tmp" : tmp)
		kit.run({"rm", "-rf", dir})
	}
	_ = os.make_directory_all(dir)
	// Rendered at the export width: a 16:9 page comes out 1920 wide, exactly
	// the resolution the PNG exporter writes.
	if _, ok := kit.run({"pdftoppm", "-png", "-scale-to-x", "1920", "-scale-to-y", "-1", path_in, fmt.tprintf("%s/page", dir)}); !ok {
		return {}, {}, fmt.tprintf("pdftoppm could not render %s", path_in)
	}
	infos, derr := os.read_all_directory_by_path(dir, context.temp_allocator)
	if derr != nil {
		return {}, {}, fmt.tprintf("cannot list %s", dir)
	}
	pages := make([dynamic]string, context.temp_allocator)
	for fi in infos {
		if strings.has_prefix(fi.name, "page") && strings.has_suffix(fi.name, ".png") {
			append(&pages, strings.clone(fi.name, context.temp_allocator))
		}
	}
	// pdftoppm pads the page number to the width of the largest, so a plain
	// sort is page order.
	slice.sort(pages[:])
	if len(pages) == 0 {
		return {}, {}, fmt.tprintf("%s has no pages", path_in)
	}

	title, _ := kit.run({"sh", "-c", fmt.tprintf("pdfinfo %q 2>/dev/null | sed -n 's/^Title: *//p'", path_in)})
	author, _ := kit.run({"sh", "-c", fmt.tprintf("pdfinfo %q 2>/dev/null | sed -n 's/^Author: *//p'", path_in)})
	if title == "" {
		base := path_in
		if i := strings.last_index_byte(base, '/'); i >= 0 {
			base = base[i + 1:]
		}
		title = strings.clone(strings.trim_suffix(base, ".pdf"))
	}
	d = Deck {
		version  = DECK_VERSION,
		title    = title,
		author   = author,
		theme    = THEMES[0],
		no_decor = true,
		slides   = make([dynamic]Slide),
	}
	d.theme.bg = 0xff000000
	d.theme.bg2 = 0
	for name, i in pages {
		full := fmt.tprintf("%s/%s", dir, name)
		img, ok := p.load_image(full)
		x, y, w, h := f32(0), f32(0), SLIDE_W, SLIDE_H
		if ok && img.w > 0 && img.h > 0 {
			// Fit the page, centred: a portrait handout is letterboxed rather
			// than cropped.
			k := min(SLIDE_W / f32(img.w), SLIDE_H / f32(img.h))
			w, h = f32(img.w) * k, f32(img.h) * k
			x, y = (SLIDE_W - w) / 2, (SLIDE_H - h) / 2
			p.image_destroy(&img)
		}
		s := Slide {
			layout = .Blank,
			elems  = make([dynamic]Element),
		}
		e := image_box(media_src(media_dir == "" ? "media" : media_dir, name), x, y, w, h)
		e.radius = 0
		append(&s.elems, e)
		text, _ := kit.run({"pdftotext", "-layout", "-f", fmt.tprintf("%d", i + 1), "-l", fmt.tprintf("%d", i + 1), path_in, "-"})
		s.notes = strings.clone(strings.trim_space(text))
		append(&d.slides, s)
	}
	if scratch {
		kit.run({"rm", "-rf", dir})
	} else {
		rep.pictures = len(pages)
	}
	rep.lost = make([dynamic]string)
	append(&rep.lost, fmt.aprintf("%d× pages as pictures: nothing on them is editable; their text is in the speaker notes", len(pages)))
	append(&rep.lost, "vector drawing and type rasterised at 1920 pixels wide; links, forms and annotations dropped")
	return d, rep, ""
}
