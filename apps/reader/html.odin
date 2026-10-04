// XHTML to blocks.
//
// This is the reader's HTML engine, and the honest description of it is: an
// element stack, a character style carried down it, and a block flushed at
// every block-level boundary. No boxes, no floats, no tables as tables. It
// covers what books are made of — headings, paragraphs, emphasis, lists,
// blockquotes, preformatted code, images, internal links and anchors — and
// degrades everything else into running text rather than dropping it.
//
// What is handled:
//
//   blocks    p div h1-h6 blockquote pre li ul ol dl dt dd hr section article
//             header footer nav aside figure figcaption center address main
//             td th tr caption (each cell becomes its own paragraph)
//   inline    b strong i em cite dfn var u ins s strike del code kbd samp tt
//             small big sup sub span a abbr q mark time font label
//   void      br hr img image meta link col wbr mbp:pagebreak
//   dropped   script style(collected as CSS) head noscript iframe object
//             audio video form input select textarea button template svg
//             (except an <image> inside it)
//
// What is not handled, and shows as a limitation on screen rather than a
// crash: tables as grids, floats and wrapped figures, ruby, MathML, inline
// SVG drawing, bidirectional text, and CSS beyond the subset in css.odin.
package main

import "core:strconv"
import "core:strings"

// Html_Opts is where this file sits in the book, which is everything needed to
// turn a relative href into something the archive can answer.
Html_Opts :: struct {
	self_path: string, // archive path of this file; "" for MOBI's single stream
	base_dir:  string, // directory of self_path
	css:       ^Css,
	mobi:      bool, // filepos links, recindex images, mbp:pagebreak
}

@(private = "file")
H_Frame :: struct {
	tag:    string,
	class:  string,
	id:     string,
	st:     Char_Style,
	kind:   Block_Kind,
	list:   List_Kind,
	depth:  u8,
	align:  Align,
	scale:  f32,
	indent: f32,
	indent_set: bool,
	before: f32,
	after:  f32,
	ord:    int, // <ol> counter
	pre:    bool,
	hidden: bool,
	skip:   bool, // the element's content is not text at all
}

@(private = "file")
H :: struct {
	b:       ^Doc_Builder,
	o:       Html_Opts,
	stack:   [dynamic]H_Frame,
	space:   bool, // a collapsed space is owed before the next word
	prev:    Char_Style, // the style of the last word written, for that space
	has_prev: bool,
	wrote:   bool, // anything in the current block yet
	brk:     bool, // a page break is owed to the next block
	style:   [dynamic]u8, // <style> content, parsed at the end
	in_style: bool,
	title:   string,
	in_title: bool,
	// The open element stack as the cascade sees it, innermost last. Kept
	// alongside `stack` so a descendant selector can be answered without
	// rebuilding it per element.
	anc:     [dynamic]Css_Sel,
}

// html_parse appends this file's blocks to the builder. It returns the
// document's <title>, which is the fallback for a spine item with no TOC
// entry.
html_parse :: proc(b: ^Doc_Builder, src: string, o: Html_Opts) -> (title: string) {
	h := H {
		b     = b,
		o     = o,
		stack = make([dynamic]H_Frame, 0, 32),
		style = make([dynamic]u8, 0, 256),
		anc   = make([dynamic]Css_Sel, 0, 32),
	}
	defer delete(h.stack)
	defer delete(h.style)
	defer delete(h.anc)

	append(
		&h.stack,
		H_Frame{tag = "", kind = .Para, align = .Left, scale = 1, st = {link = -1, scale = 1}},
	)

	x: Xml
	xml_init(&x, src)
	defer xml_destroy(&x)

	// A stylesheet inside the file applies to the file, so the first pass
	// collects <style> and the markup is walked with it already in place.
	// Two passes over the token stream is cheaper than it sounds — the
	// expensive part of opening a book is wrapping, not scanning.
	html_collect_style(&x, &h)
	if o.css != nil && len(h.style) > 0 {
		css_parse(o.css, string(h.style[:]))
	}
	x.at = 0
	x.n = 0

	html_open_block(&h, top_frame(&h)^)

	for {
		tok_at := x.at
		t := xml_next(&x)
		if t.kind == .Eof {
			break
		}
		switch t.kind {
		case .Eof:
		case .Decl:
		case .Text:
			html_text(&h, t.text)
		case .Open, .Empty:
			html_open(&h, t, tok_at, t.kind == .Empty)
		case .Close:
			html_close(&h, t.name)
		}
	}

	// Anything still open closes at end of file, which is the common shape of
	// a hand-written chapter: <p> never closed, </body> never written.
	for len(h.stack) > 1 {
		html_close(&h, h.stack[len(h.stack) - 1].tag)
	}
	builder_flush(b)
	return h.title
}

@(private = "file")
top_frame :: proc(h: ^H) -> ^H_Frame {
	return &h.stack[len(h.stack) - 1]
}

// html_collect_style runs the token stream once for <style> bodies only.
@(private = "file")
html_collect_style :: proc(x: ^Xml, h: ^H) {
	in_style := false
	for {
		t := xml_next(x)
		if t.kind == .Eof {
			break
		}
		switch t.kind {
		case .Open:
			if t.name == "style" {
				in_style = true
			}
		case .Close:
			if t.name == "style" {
				in_style = false
			}
		case .Text:
			if in_style {
				append(&h.style, t.text)
				append(&h.style, '\n')
			}
		case .Empty, .Decl, .Eof:
		}
	}
}

// ---------------------------------------------------------------------------
// Text
// ---------------------------------------------------------------------------

@(private = "file")
is_ws :: proc(c: u8) -> bool {
	return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f' || c == 0x0b
}

@(private = "file")
html_text :: proc(h: ^H, s: string) {
	f := top_frame(h)
	// The title is read before the skip test on purpose: <title> lives inside
	// <head>, and <head> is a skipped element.
	if h.in_title {
		if h.title == "" {
			t := strings.trim_space(s)
			if t != "" {
				h.title = strings.clone(t)
			}
		}
		return
	}
	if h.in_style || f.hidden || f.skip {
		return
	}

	if f.pre {
		// Preformatted: newlines are real. Each line becomes its own Code
		// block, which is how a code listing and a stanza both come out
		// right without the wrapper needing to know about hard breaks.
		rest := s
		for {
			nl := strings.index_byte(rest, '\n')
			piece := nl < 0 ? rest : rest[:nl]
			if len(piece) > 0 && piece[len(piece) - 1] == '\r' {
				piece = piece[:len(piece) - 1]
			}
			if len(piece) > 0 {
				builder_text(h.b, piece, f.st)
				h.wrote = true
			}
			if nl < 0 {
				break
			}
			html_hard_break(h)
			rest = rest[nl + 1:]
		}
		return
	}

	// Collapsed whitespace, the CSS default. A space is remembered rather
	// than written, so it never leaks to the start of a block or doubles up
	// across an inline element boundary.
	i := 0
	for i < len(s) {
		if is_ws(s[i]) {
			if h.wrote {
				h.space = true
			}
			i += 1
			continue
		}
		j := i
		for j < len(s) && !is_ws(s[j]) {
			j += 1
		}
		if h.space {
			builder_text(h.b, " ", space_style(h, f.st))
			h.space = false
		}
		builder_text(h.b, s[i:j], f.st)
		h.prev = f.st
		h.has_prev = true
		h.wrote = true
		i = j
	}
}

// space_style is the appearance of the collapsed space between two words: the
// decorations both of its neighbours agree on.
//
// A space belongs to neither word. Give it the style of the word that follows
// and the space before a link is drawn underlined, so every linked phrase
// appears to start one space early; give it the style of the word before and
// the space after a link is underlined instead. Taking the intersection puts
// the underline inside the link and nowhere else, which is what a browser
// draws.
@(private = "file")
space_style :: proc(h: ^H, next: Char_Style) -> Char_Style {
	sp := next
	if !h.has_prev {
		sp.link = -1
		sp.underline = false
		sp.strike = false
		return sp
	}
	if h.prev.link != next.link {
		sp.link = -1
	}
	if !h.prev.underline {
		sp.underline = false
	}
	if !h.prev.strike {
		sp.strike = false
	}
	return sp
}

// html_hard_break ends the current block and starts another of the same shape.
// A <br> and a newline inside <pre> both mean this.
@(private = "file")
html_hard_break :: proc(h: ^H) {
	f := top_frame(h)^
	cur := h.b.cur
	builder_flush(h.b)
	h.b.cur = cur
	h.b.open = true
	clear(&h.b.buf)
	clear(&h.b.segs)
	h.b.cur.before = 0
	h.b.cur.after = 0
	h.b.cur.brk = false
	h.b.cur.marker = -1
	h.b.cur.indent = 0
	h.space = false
	h.wrote = false
	h.has_prev = false
	_ = f
}

// ---------------------------------------------------------------------------
// Blocks
// ---------------------------------------------------------------------------

@(private = "file")
html_open_block :: proc(h: ^H, f: H_Frame) {
	builder_begin(h.b, f.kind)
	c := &h.b.cur
	c.list = f.list
	c.depth = f.depth
	c.align = f.align
	c.scale = f.scale
	c.indent = f.indent
	c.indent_set = f.indent_set
	c.before = f.before
	c.after = f.after
	c.brk = h.brk
	h.brk = false
	h.space = false
	h.wrote = false
	h.has_prev = false
}

// block_kind_of answers "is this tag a block, and what kind". A switch rather
// than a map, so it costs nothing at startup and nothing per element.
@(private = "file")
block_kind_of :: proc(name: string) -> (Block_Kind, bool) {
	switch name {
	case "p", "div", "section", "article", "header", "footer", "nav", "aside",
	     "main", "body", "figure", "figcaption", "caption", "center", "address",
	     "dl", "dt", "dd", "tr", "td", "th":
		return .Para, true
	case "h1":
		return .H1, true
	case "h2":
		return .H2, true
	case "h3":
		return .H3, true
	case "h4", "h5", "h6":
		return .H4, true
	case "blockquote":
		return .Quote, true
	case "pre":
		return .Code, true
	case "li":
		return .Item, true
	}
	return .Para, false
}

@(private = "file")
is_skip_tag :: proc(name: string) -> bool {
	switch name {
	case "script", "noscript", "iframe", "object", "embed", "audio", "video",
	     "form", "input", "select", "textarea", "button", "template", "map",
	     "head", "math", "rt", "rp":
		return true
	}
	return false
}

@(private = "file")
is_void_tag :: proc(name: string) -> bool {
	switch name {
	case "br", "hr", "img", "meta", "link", "col", "base", "area", "source",
	     "wbr", "param", "mbp:pagebreak", "pagebreak":
		return true
	}
	return false
}

@(private = "file")
html_open :: proc(h: ^H, t: Xml_Token, tok_at: int, self_close: bool) {
	name := t.name
	parent := top_frame(h)^

	// An id or an anchor name is a link target, and it belongs to whatever
	// block comes next.
	if id, ok := xml_attr(t, "id"); ok && id != "" {
		builder_add_anchor(h.b, anchor_key(h.o.self_path, id))
	}
	if name == "a" {
		if nm, ok := xml_attr(t, "name"); ok && nm != "" {
			builder_add_anchor(h.b, anchor_key(h.o.self_path, nm))
		}
	}

	switch name {
	case "title":
		h.in_title = true
		return
	case "style":
		h.in_style = true
		return
	case "br":
		if !parent.hidden && !parent.skip {
			html_hard_break(h)
		}
		return
	case "hr":
		if !parent.hidden && !parent.skip {
			builder_flush(h.b)
			bi := len(h.b.d.blocks)
			append(
				&h.b.d.blocks,
				Block {
					kind = .Rule,
					image = -1,
					marker = -1,
					chapter = h.b.chapter,
					at = i32(len(h.b.d.text)),
					n = 0,
					si = i32(len(h.b.d.segs)),
					sn = 0,
					before = 0.6,
					after = 0.6,
					brk = h.brk,
				},
			)
			h.brk = false
			builder_pending_to(h.b, bi)
			html_mark_pos(h, tok_at, bi)
			html_open_block(h, parent)
		}
		return
	case "img", "image":
		if !parent.hidden && !parent.skip {
			html_image(h, t, tok_at, parent)
		}
		return
	case "mbp:pagebreak", "pagebreak":
		h.brk = true
		return
	case "svg":
		// An <svg> wrapper around a cover image is the one shape worth
		// walking into; everything else inside it is drawing instructions.
		f := parent
		f.tag = name
		h_push(h, f, name)
		return
	}

	if is_skip_tag(name) {
		f := parent
		f.tag = name
		f.skip = true
		h_push(h, f, name)
		if self_close {
			h_pop(h)
		}
		return
	}

	f := parent
	f.tag = name
	f.ord = 0

	// Inline appearance first, so a block tag that is also styled (an
	// <h2 class="italic">) gets both.
	switch name {
	case "b", "strong":
		f.st.bold = true
	case "i", "em", "cite", "dfn", "var":
		f.st.italic = true
	case "u", "ins":
		f.st.underline = true
	case "s", "strike", "del":
		f.st.strike = true
	case "code", "kbd", "samp", "tt":
		f.st.mono = true
	case "small":
		f.st.scale = style_scale(f.st) * 0.86
	case "big":
		f.st.scale = style_scale(f.st) * 1.15
	case "sup":
		f.st.sup = true
		f.st.scale = style_scale(f.st) * 0.72
	case "sub":
		f.st.sub = true
		f.st.scale = style_scale(f.st) * 0.72
	case "a":
		href := ""
		if v, ok := xml_attr(t, "href"); ok {
			href = v
		} else if v2, ok2 := xml_attr(t, "filepos"); ok2 {
			href = strings.concatenate({"filepos:", v2}, context.temp_allocator)
		}
		if href != "" {
			f.st.link = doc_add_link(h.b.d, href)
			f.st.underline = true
		}
	}

	// The element's own stylesheet rules, then its inline style attribute.
	decl := Css_Decl{}
	class := xml_attr_or(t, "class", "")
	id := xml_attr_or(t, "id", "")
	f.class = class
	f.id = id
	if h.o.css != nil {
		css_match(h.o.css, name, class_lower(h, class), id, h.anc[:], &decl)
	}
	if inline, ok := xml_attr(t, "style"); ok && inline != "" {
		css_fold(&decl, css_parse_decl(inline))
	}
	if .Weight in decl.has {f.st.bold = decl.bold}
	if .Slant in decl.has {f.st.italic = decl.italic}
	if .Mono in decl.has {f.st.mono = decl.mono}
	if .Underline in decl.has {f.st.underline = decl.underline}
	if .Strike in decl.has {f.st.strike = decl.strike}
	if .Size in decl.has {f.st.scale = style_scale(f.st) * decl.size}
	if .Hidden in decl.has && decl.hidden {f.hidden = true}

	// List context.
	switch name {
	case "ul", "menu", "dir":
		f.list = .Bullet
		f.depth = min(f.depth + 1, 8)
	case "ol":
		f.list = .Numbered
		f.depth = min(f.depth + 1, 8)
		f.ord = 0
		if st, ok := xml_attr(t, "start"); ok {
			if v, good := strconv.parse_int(strings.trim_space(st)); good {
				f.ord = v - 1
			}
		}
	case "blockquote":
		f.depth = min(f.depth + 1, 8)
	}

	// Block-level: an implicit close of anything still open that cannot
	// contain it, then a fresh block.
	if kind, is_block := block_kind_of(name); is_block {
		html_imply_close(h, name)
		parent = top_frame(h)^
		// Re-derive from the (possibly changed) parent: the inline and list
		// work above was done against the old top, so redo the parts that
		// depend on the stack.
		f.st.link = parent.st.link
		f.kind = kind
		// A <p> inside a container that *is* a block kind belongs to that
		// kind: `<blockquote><p>` is a quotation, not a paragraph that
		// happens to sit inside one, and `<li><p>` is still the list item
		// that owns the marker. Without this a book that wraps every
		// quotation in a paragraph -- which is what the spec asks for --
		// loses its quotations entirely.
		if kind == .Para {
			switch parent.kind {
			case .Quote, .Item, .Code:
				f.kind = parent.kind
			case .Para, .H1, .H2, .H3, .H4, .Image, .Rule:
			}
		}
		f.pre = kind == .Code || f.kind == .Code || parent.pre
		if name == "center" {
			f.align = .Center
		}
		if name == "th" {
			f.st.bold = true
		}
		if name == "li" && f.list == .Numbered {
			// The counter lives on the <ol> frame, so find it.
			for i := len(h.stack) - 1; i >= 0; i -= 1 {
				if h.stack[i].tag == "ol" {
					h.stack[i].ord += 1
					f.ord = h.stack[i].ord
					break
				}
			}
		}
		if .Align in decl.has {f.align = decl.align}
		if .Indent in decl.has {
			f.indent = decl.indent
			f.indent_set = true
		}
		f.before = .Margin_Top in decl.has ? decl.margin_top : 0
		f.after = .Margin_Bottom in decl.has ? decl.margin_bot : 0
		if .Break in decl.has && decl.brk {
			h.brk = true
		}
		f.scale = .Size in decl.has ? parent.scale * decl.size : parent.scale
		if .Size in decl.has {
			// A block-level font-size is the block's size, not a run style.
			f.st.scale = 1
		}

		h_push(h, f, name)
		html_open_block(h, f)
		if name == "li" {
			h.b.cur.marker = f.list == .Numbered ? i32(f.ord) : -1
		}
		html_mark_pos(h, tok_at, len(h.b.d.blocks))
		if self_close || is_void_tag(name) {
			html_close(h, name)
		}
		return
	}

	if .Align in decl.has {f.align = decl.align}

	h_push(h, f, name)
	if self_close || is_void_tag(name) {
		h_pop(h)
	}
}

// h_push and h_pop keep the element stack and the cascade's view of it in
// step. They are the only two places either array changes.
@(private = "file")
h_push :: proc(h: ^H, f: H_Frame, name: string) {
	append(&h.stack, f)
	append(&h.anc, Css_Sel{tag = name, class = class_lower(h, f.class), id = f.id})
}

@(private = "file")
h_pop :: proc(h: ^H) -> H_Frame {
	f := h.stack[len(h.stack) - 1]
	pop(&h.stack)
	if len(h.anc) > 0 {
		pop(&h.anc)
	}
	return f
}

// class_lower lower-cases a class attribute once per element, since every
// selector it is compared against was lower-cased at parse time.
@(private = "file")
class_lower :: proc(h: ^H, class: string) -> string {
	if class == "" {
		return ""
	}
	return strings.to_lower(class, context.temp_allocator)
}

// html_imply_close pops frames that a new block-level element cannot legally
// sit inside. It is the whole of this parser's error recovery, and it is what
// makes a chapter of unclosed <p> tags read correctly.
@(private = "file")
html_imply_close :: proc(h: ^H, opening: string) {
	for len(h.stack) > 1 {
		t := h.stack[len(h.stack) - 1].tag
		close := false
		switch t {
		case "p", "dt", "dd", "td", "th", "h1", "h2", "h3", "h4", "h5", "h6":
			close = true
		case "li":
			// A nested list belongs to the item; a new item does not.
			close = opening == "li"
		case "tr":
			close = opening == "tr"
		}
		if !close {
			break
		}
		html_close_frame(h)
	}
}

@(private = "file")
html_close_frame :: proc(h: ^H) {
	if len(h.stack) <= 1 {
		return
	}
	f := h_pop(h)
	if _, was_block := block_kind_of(f.tag); was_block {
		builder_flush(h.b)
		html_open_block(h, top_frame(h)^)
	}
}

@(private = "file")
html_close :: proc(h: ^H, name: string) {
	switch name {
	case "title":
		h.in_title = false
		return
	case "style":
		h.in_style = false
		return
	}

	// Find the matching frame. A close tag for something that was never
	// opened is ignored rather than unwinding the whole document.
	found := -1
	for i := len(h.stack) - 1; i >= 1; i -= 1 {
		if h.stack[i].tag == name {
			found = i
			break
		}
	}
	if found < 0 {
		return
	}
	for len(h.stack) > found {
		html_close_frame(h)
	}
}

// ---------------------------------------------------------------------------
// Images
// ---------------------------------------------------------------------------

@(private = "file")
html_image :: proc(h: ^H, t: Xml_Token, tok_at: int, parent: H_Frame) {
	key := ""
	if h.o.mobi {
		// MOBI points at a record, not a file.
		if ri, ok := xml_attr(t, "recindex"); ok {
			if v, good := strconv.parse_int(strings.trim_space(ri)); good {
				key = strings.concatenate({"rec:", itoa_tmp(v)}, context.temp_allocator)
			}
		}
	}
	if key == "" {
		src := ""
		if v, ok := xml_attr(t, "src"); ok {
			src = v
		} else if v2, ok2 := xml_attr(t, "href"); ok2 {
			src = v2
		}
		if src == "" || strings.has_prefix(src, "data:") {
			// A data: URI would have to be base64-decoded and kept in
			// memory for the life of the book. Books use them for
			// decoration, so the alt text stands in.
			if src != "" {
				html_text(h, strings.trim_space(xml_attr_or(t, "alt", "")))
			}
			return
		}
		key = path_resolve(h.o.base_dir, src, context.temp_allocator)
	}
	if key == "" {
		return
	}

	alt := xml_attr_or(t, "alt", "")
	idx := doc_add_image(h.b.d, key, alt)

	builder_flush(h.b)
	bi := len(h.b.d.blocks)
	append(
		&h.b.d.blocks,
		Block {
			kind = .Image,
			image = idx,
			marker = -1,
			chapter = h.b.chapter,
			at = i32(len(h.b.d.text)),
			n = 0,
			si = i32(len(h.b.d.segs)),
			sn = 0,
			align = .Center,
			before = 0.5,
			after = 0.5,
			brk = h.brk,
		},
	)
	h.brk = false
	builder_pending_to(h.b, bi)
	html_mark_pos(h, tok_at, bi)
	html_open_block(h, parent)
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

style_scale :: proc(st: Char_Style) -> f32 {
	return st.scale > 0 ? st.scale : 1
}

anchor_key :: proc(path, frag: string, allocator := context.temp_allocator) -> string {
	return strings.concatenate({path, "#", frag}, allocator)
}

// html_mark_pos records "the block at this source byte offset", which is the
// only way a MOBI `filepos` link can be resolved — MOBI has no anchors, only
// offsets into the decompressed HTML.
@(private = "file")
html_mark_pos :: proc(h: ^H, off, bi: int) {
	if !h.o.mobi {
		return
	}
	d := h.b.d
	if n := len(d.pos_marks); n > 0 && d.pos_marks[n - 1][0] >= off {
		return
	}
	append(&d.pos_marks, [2]int{off, bi})
}

itoa_tmp :: proc(v: int) -> string {
	buf := make([]u8, 24, context.temp_allocator)
	return strconv.write_int(buf, i64(v), 10)
}
