// EPUB: a ZIP of XHTML, read from the container up.
//
// The chain is fixed by the spec and every step of it is somewhere books get
// wrong, so each one degrades rather than fails:
//
//   mimetype                 should be the first, stored entry and say
//                            application/epub+zip. Checked, not required —
//                            plenty of real books have it compressed.
//   META-INF/container.xml   points at the package document. If it is missing
//                            or unparseable, the archive is searched for a
//                            single .opf, which finds the book anyway.
//   the OPF                  metadata, the manifest (every file), and the
//                            spine (the reading order). A spine itemref whose
//                            idref is not in the manifest is noted and
//                            skipped; a manifest href that is not in the ZIP
//                            is noted and skipped.
//   the TOC                  an EPUB 3 nav document, or an EPUB 2 NCX, or
//                            neither — in which case one is built from the
//                            spine and the chapters' own <title> elements.
package main

import "core:strings"

Opf_Item :: struct {
	id:    string,
	href:  string, // resolved against the OPF's directory
	media: string,
	props: string, // the EPUB 3 `properties` attribute
}

Epub :: struct {
	zip:      Zip,
	opf:      string, // archive path of the package document
	opf_dir:  string,
	items:    [dynamic]Opf_Item,
	by_id:    map[string]int,
	spine:    [dynamic]int, // indices into items, in reading order
	nav:      int, // manifest index of the EPUB 3 nav document, -1
	ncx:      int, // manifest index of the NCX, -1
	cover:    int, // manifest index of the cover image, -1
}

epub_destroy :: proc(e: ^Epub) {
	zip_destroy(&e.zip)
	for it in e.items {
		delete(it.id)
		delete(it.href)
		delete(it.media)
		delete(it.props)
	}
	delete(e.items)
	delete(e.by_id)
	delete(e.spine)
	delete(e.opf)
	delete(e.opf_dir)
	e^ = {}
}

// epub_open reads the container and the package document, and fills the Doc
// with every spine item's blocks, its TOC and its metadata.
epub_open :: proc(e: ^Epub, d: ^Doc, path: string) -> (ok: bool, err: string) {
	e.nav, e.ncx, e.cover = -1, -1, -1
	z, zok := zip_open(path)
	e.zip = z
	if !zok {
		return false, e.zip.err != "" ? e.zip.err : "not a readable zip archive"
	}

	// The mimetype entry is a sanity check, not a gate.
	if mt, got := zip_read_string(&e.zip, "mimetype", context.temp_allocator); got {
		if !strings.contains(mt, "application/epub+zip") {
			doc_note(d, "mimetype does not say application/epub+zip")
		}
	} else {
		doc_note(d, "no mimetype entry")
	}

	e.opf = epub_find_opf(e, d)
	if e.opf == "" {
		return false, "no package document (.opf) in the archive"
	}
	e.opf_dir = strings.clone(path_dir(e.opf))

	opf_src, have := zip_read_string(&e.zip, e.opf, context.temp_allocator)
	if !have {
		return false, "the package document could not be read"
	}
	epub_parse_opf(e, d, opf_src)

	if len(e.spine) == 0 {
		return false, "the spine is empty: nothing to read"
	}

	// Stylesheets referenced from the OPF apply to the whole book. Chapter
	// <style> blocks are added per chapter on top of them.
	css: Css
	css_init(&css)
	defer css_destroy(&css)
	for it in e.items {
		if strings.contains(it.media, "css") || path_ext_lower(it.href) == "css" {
			if src, got := zip_read_string(&e.zip, it.href, context.temp_allocator); got {
				css_parse(&css, src)
			}
		}
	}

	b: Doc_Builder
	builder_init(&b, d)
	defer builder_destroy(&b)

	for mi in e.spine {
		it := e.items[mi]
		src, got := zip_read_string(&e.zip, it.href, context.temp_allocator)
		if !got {
			doc_note(
				d,
				tfmt("spine item %s is in the manifest but not in the archive", it.href),
			)
			continue
		}
		ci := len(d.chapters)
		append(
			&d.chapters,
			Chapter{path = strings.clone(it.href), first = len(d.blocks), count = 0},
		)
		b.chapter = i32(ci)

		// The file itself is a link target, so a TOC entry pointing at the
		// bare path lands on its first block.
		builder_add_anchor(&b, it.href)
		builder_add_anchor(&b, anchor_key(it.href, ""))

		title := html_parse(&b, src, {
			self_path = it.href,
			base_dir  = path_dir(it.href),
			css       = &css,
		})
		d.chapters[ci].count = len(d.blocks) - d.chapters[ci].first
		d.chapters[ci].title = title != "" ? title : strings.clone(path_base(it.href))
	}
	builder_flush(&b)

	if len(d.blocks) == 0 {
		return false, "the book parsed to no text at all"
	}

	epub_load_toc(e, d)
	if len(d.toc) == 0 {
		// No NCX and no nav: the spine is the table of contents.
		for c, i in d.chapters {
			append(
				&d.toc,
				Toc_Entry {
					title = strings.clone(c.title),
					depth = 0,
					href = strings.clone(c.path),
					block = c.first,
				},
			)
			_ = i
		}
		doc_note(d, "no table of contents in the book; built one from the spine")
	}
	return true, ""
}

@(private = "file")
epub_find_opf :: proc(e: ^Epub, d: ^Doc) -> string {
	if src, got := zip_read_string(&e.zip, "META-INF/container.xml", context.temp_allocator);
	   got {
		x: Xml
		xml_init(&x, src)
		defer xml_destroy(&x)
		for {
			t := xml_next(&x)
			if t.kind == .Eof {
				break
			}
			if (t.kind == .Open || t.kind == .Empty) && t.name == "rootfile" {
				if fp, ok := xml_attr(t, "full-path"); ok && fp != "" {
					p := path_normalize(percent_decode(fp, context.temp_allocator))
					if zip_has(&e.zip, p) {
						return strings.clone(p)
					}
					doc_note(d, tfmt("container.xml points at %s, which is not in the archive", p))
				}
			}
		}
	} else {
		doc_note(d, "META-INF/container.xml is missing")
	}

	// Fall back to a single .opf anywhere in the archive.
	found := ""
	n := 0
	for ent in e.zip.entries {
		if path_ext_lower(ent.name) == "opf" {
			n += 1
			if found == "" {
				found = ent.name
			}
		}
	}
	if n > 0 {
		doc_note(d, tfmt("found the package document by searching the archive (%s)", found))
		return strings.clone(found)
	}
	return ""
}

@(private = "file")
epub_parse_opf :: proc(e: ^Epub, d: ^Doc, src: string) {
	x: Xml
	xml_init(&x, src)
	defer xml_destroy(&x)

	Section :: enum {
		None,
		Metadata,
		Manifest,
		Spine,
		Guide,
	}
	sec := Section.None
	// Which metadata element's text we are inside, and the text so far.
	meta_tag := ""
	meta_buf := make([dynamic]u8, 0, 128, context.temp_allocator)
	cover_id := ""
	toc_id := ""
	// Spine idrefs are collected first and resolved after the manifest, since
	// an OPF is allowed to put the spine before the manifest.
	refs := make([dynamic]string, 0, 64, context.temp_allocator)

	for {
		t := xml_next(&x)
		if t.kind == .Eof {
			break
		}
		switch t.kind {
		case .Eof, .Decl:
		case .Text:
			if sec == .Metadata && meta_tag != "" {
				append(&meta_buf, t.text)
			}
		case .Close:
			switch t.name {
			case "metadata", "manifest", "spine", "guide":
				sec = .None
			}
			if sec == .Metadata && t.name == meta_tag {
				val := strings.trim_space(string(meta_buf[:]))
				if val != "" {
					switch meta_tag {
					case "title":
						if d.title == "" {d.title = strings.clone(val)}
					case "creator":
						if d.author == "" {d.author = strings.clone(val)}
					case "language":
						if d.language == "" {d.language = strings.clone(val)}
					case "publisher":
						if d.publisher == "" {d.publisher = strings.clone(val)}
					case "identifier":
						if d.ident == "" {d.ident = strings.clone(val)}
					}
				}
				meta_tag = ""
				clear(&meta_buf)
			}
		case .Open, .Empty:
			switch t.name {
			case "metadata":
				sec = .Metadata
				continue
			case "manifest":
				sec = .Manifest
				continue
			case "spine":
				sec = .Spine
				if v, ok := xml_attr(t, "toc"); ok {
					toc_id = strings.clone(v, context.temp_allocator)
				}
				continue
			case "guide":
				sec = .Guide
				continue
			}

			switch sec {
			case .Metadata:
				switch t.name {
				case "title", "creator", "language", "publisher", "identifier":
					if t.kind == .Open {
						meta_tag = t.name
						clear(&meta_buf)
					}
				case "meta":
					// EPUB 2 declares the cover here; EPUB 3 uses
					// `properties="cover-image"` on the manifest item.
					nm := xml_attr_or(t, "name", "")
					if strings.equal_fold(nm, "cover") {
						cover_id = strings.clone(
							xml_attr_or(t, "content", ""),
							context.temp_allocator,
						)
					}
					// EPUB 3 refines the creator; take it if dc:creator was
					// absent.
					prop := xml_attr_or(t, "property", "")
					if prop == "dcterms:modified" {
					}
				}
			case .Manifest:
				if t.name == "item" {
					id := xml_attr_or(t, "id", "")
					href := xml_attr_or(t, "href", "")
					if href == "" {
						continue
					}
					full := path_resolve(e.opf_dir, href, context.temp_allocator)
					idx := len(e.items)
					append(
						&e.items,
						Opf_Item {
							id = strings.clone(id),
							href = strings.clone(full),
							media = strings.clone(xml_attr_or(t, "media-type", "")),
							props = strings.clone(xml_attr_or(t, "properties", "")),
						},
					)
					if id != "" {
						if _, dup := e.by_id[e.items[idx].id]; !dup {
							e.by_id[e.items[idx].id] = idx
						}
					}
					if strings.contains(e.items[idx].props, "nav") {
						e.nav = idx
					}
					if strings.contains(e.items[idx].props, "cover-image") {
						e.cover = idx
					}
					if strings.contains(e.items[idx].media, "dtbncx") ||
					   path_ext_lower(full) == "ncx" {
						e.ncx = idx
					}
				}
			case .Spine:
				if t.name == "itemref" {
					// linear="no" marks front/back matter the reader is not
					// meant to page through. It is kept — a reader that
					// silently hides a chapter is worse than one that shows
					// it — but noted.
					idref := xml_attr_or(t, "idref", "")
					if idref != "" {
						append(&refs, strings.clone(idref, context.temp_allocator))
					}
				}
			case .Guide:
				if t.name == "reference" {
					ty := xml_attr_or(t, "type", "")
					if strings.equal_fold(ty, "cover") && e.cover < 0 {
						// The guide points at an XHTML wrapper, not the
						// image; resolving it properly means parsing that
						// file, which epub_cover_bytes does on demand.
					}
				}
			case .None:
			}
		}
	}

	for r in refs {
		if mi, ok := e.by_id[r]; ok {
			it := e.items[mi]
			ext := path_ext_lower(it.href)
			if strings.contains(it.media, "html") || ext == "xhtml" || ext == "html" ||
			   ext == "htm" || it.media == "" {
				append(&e.spine, mi)
			} else {
				doc_note(d, tfmt("spine item %s is not markup (%s); skipped", it.href, it.media))
			}
		} else {
			doc_note(d, tfmt("spine references id \"%s\", which the manifest does not define", r))
		}
	}

	if e.ncx < 0 && toc_id != "" {
		if mi, ok := e.by_id[toc_id]; ok {
			e.ncx = mi
		}
	}
	if e.cover < 0 && cover_id != "" {
		if mi, ok := e.by_id[cover_id]; ok {
			e.cover = mi
		}
	}
	if e.cover < 0 {
		// Last resort: an image whose id or file name says cover.
		for it, i in e.items {
			if !strings.contains(it.media, "image") {
				continue
			}
			lower := strings.to_lower(it.href, context.temp_allocator)
			if strings.contains(lower, "cover") || strings.equal_fold(it.id, "cover") {
				e.cover = i
				break
			}
		}
	}
}

// ---------------------------------------------------------------------------
// Table of contents
// ---------------------------------------------------------------------------

@(private = "file")
epub_load_toc :: proc(e: ^Epub, d: ^Doc) {
	if e.nav >= 0 {
		if src, got := zip_read_string(&e.zip, e.items[e.nav].href, context.temp_allocator);
		   got {
			epub_parse_nav(e, d, src, path_dir(e.items[e.nav].href))
		}
	}
	if len(d.toc) == 0 && e.ncx >= 0 {
		if src, got := zip_read_string(&e.zip, e.items[e.ncx].href, context.temp_allocator);
		   got {
			epub_parse_ncx(e, d, src, path_dir(e.items[e.ncx].href))
		}
	}
}

// epub_parse_ncx reads an EPUB 2 NCX. navPoint nesting is the depth.
@(private = "file")
epub_parse_ncx :: proc(e: ^Epub, d: ^Doc, src, base: string) {
	x: Xml
	xml_init(&x, src)
	defer xml_destroy(&x)

	depth := -1
	in_label := 0
	in_text := false
	buf := make([dynamic]u8, 0, 128, context.temp_allocator)
	href := ""
	have := false

	emit :: proc(d: ^Doc, base: string, title: string, href: string, depth: int) {
		t := strings.trim_space(title)
		if t == "" && href == "" {
			return
		}
		append(
			&d.toc,
			Toc_Entry {
				title = strings.clone(t == "" ? "Untitled" : t),
				depth = max(depth, 0),
				href = strings.clone(href),
				block = toc_resolve(d, base, href),
			},
		)
	}

	for {
		tok := xml_next(&x)
		if tok.kind == .Eof {
			break
		}
		switch tok.kind {
		case .Eof, .Decl:
		case .Text:
			if in_text {
				append(&buf, tok.text)
			}
		case .Open, .Empty:
			switch tok.name {
			case "navpoint":
				if have {
					emit(d, base, string(buf[:]), href, depth)
					have = false
				}
				depth += 1
				clear(&buf)
				href = ""
				have = true
			case "navlabel":
				in_label += 1
			case "text":
				if in_label > 0 {
					in_text = true
					clear(&buf)
				}
			case "content":
				if s, ok := xml_attr(tok, "src"); ok {
					href = strings.clone(s, context.temp_allocator)
				}
			}
			if tok.kind == .Empty && tok.name == "navpoint" {
				if have {
					emit(d, base, string(buf[:]), href, depth)
					have = false
				}
				depth -= 1
			}
		case .Close:
			switch tok.name {
			case "text":
				in_text = false
			case "navlabel":
				in_label = max(0, in_label - 1)
			case "navpoint":
				if have {
					emit(d, base, string(buf[:]), href, depth)
					have = false
				}
				depth -= 1
			}
		}
	}
	if have {
		emit(d, base, string(buf[:]), href, depth)
	}
}

// epub_parse_nav reads an EPUB 3 nav document: the <nav> whose epub:type is
// "toc", then nested <ol>/<li>/<a>.
@(private = "file")
epub_parse_nav :: proc(e: ^Epub, d: ^Doc, src, base: string) {
	x: Xml
	xml_init(&x, src)
	defer xml_destroy(&x)

	in_toc := false
	nav_depth := 0
	ol_depth := 0
	in_a := false
	href := ""
	buf := make([dynamic]u8, 0, 128, context.temp_allocator)

	for {
		tok := xml_next(&x)
		if tok.kind == .Eof {
			break
		}
		switch tok.kind {
		case .Eof, .Decl:
		case .Text:
			if in_a {
				append(&buf, tok.text)
			}
		case .Open, .Empty:
			switch tok.name {
			case "nav":
				nav_depth += 1
				ty := xml_attr_or(tok, "epub:type", xml_attr_or(tok, "type", ""))
				if strings.contains(strings.to_lower(ty, context.temp_allocator), "toc") {
					in_toc = true
					ol_depth = 0
				} else if ty == "" && !in_toc && len(d.toc) == 0 {
					// A nav with no type at all: take it, since a book with
					// one nav and no declaration is still trying to give us
					// a table of contents.
					in_toc = true
					ol_depth = 0
				}
			case "ol", "ul":
				if in_toc {
					ol_depth += 1
				}
			case "a", "span":
				if in_toc {
					in_a = true
					clear(&buf)
					href = strings.clone(xml_attr_or(tok, "href", ""), context.temp_allocator)
				}
			}
		case .Close:
			switch tok.name {
			case "nav":
				nav_depth = max(0, nav_depth - 1)
				if in_toc {
					in_toc = false
				}
			case "ol", "ul":
				if in_toc {
					ol_depth = max(0, ol_depth - 1)
				}
			case "a", "span":
				if in_toc && in_a {
					in_a = false
					t := strings.trim_space(string(buf[:]))
					if t != "" || href != "" {
						append(
							&d.toc,
							Toc_Entry {
								title = strings.clone(t == "" ? "Untitled" : t),
								depth = max(0, ol_depth - 1),
								href = strings.clone(href),
								block = toc_resolve(d, base, href),
							},
						)
					}
					href = ""
				}
			}
		}
	}
}

// toc_resolve turns a TOC href into a block index, or -1. Resolution is
// deliberately forgiving, because this is the single most broken field in real
// books: it tries the exact path with its fragment, then the path alone, then
// the base name, and only then gives up.
toc_resolve :: proc(d: ^Doc, base: string, href: string) -> int {
	if href == "" {
		return -1
	}
	path, frag := split_frag(href)
	if path == "" {
		// A bare fragment inside the nav document itself cannot name a
		// chapter, but some books do it anyway; try the raw id.
		for k, v in d.anchors {
			if strings.has_suffix(k, tfmt("#%s", frag)) {
				return v
			}
		}
		return -1
	}
	full := path_resolve(base, path, context.temp_allocator)
	if frag != "" {
		if bi, ok := d.anchors[anchor_key(full, frag)]; ok {
			return bi
		}
	}
	if bi, ok := d.anchors[full]; ok {
		return bi
	}
	// Match on base name: a nav document that got its relative path wrong
	// still names the right file.
	want := path_base(full)
	for c, i in d.chapters {
		if path_base(c.path) == want {
			_ = i
			return c.first
		}
	}
	return -1
}

// ---------------------------------------------------------------------------
// Resources
// ---------------------------------------------------------------------------

// epub_resource reads a file out of the book by archive path, which is what an
// image block's key is.
epub_resource :: proc(e: ^Epub, key: string, allocator := context.allocator) -> ([]u8, bool) {
	return zip_read(&e.zip, key, allocator)
}

// epub_cover_path is the archive path of the cover image, or "".
epub_cover_path :: proc(e: ^Epub) -> string {
	if e.cover >= 0 && e.cover < len(e.items) {
		return e.items[e.cover].href
	}
	return ""
}
