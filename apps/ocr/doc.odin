package main

// The document model, and the two text serialisations.
//
// Everything in this application funnels through `Doc`. An OCR backend
// produces either word boxes (tesseract) or already-structured Markdown
// (Mistral); `structure.odin` turns the first into a Doc and `markdown.odin`
// turns the second into one. EPUB, Markdown and plain text are then three
// writers over the same tree, which is the only way three exporters stay in
// agreement about what the document *is*.
//
// The model is deliberately flat: a list of blocks, each with a page number
// and a column index. A nested tree would be more faithful to XHTML and would
// buy nothing, because OCR cannot recover nesting it never saw.

import "core:fmt"
import "core:strings"

Block_Kind :: enum u8 {
	Paragraph,
	Heading,
	Page_Break, // a hard page boundary, kept so a reader can be told about it
}

Block :: struct {
	kind:  Block_Kind,
	level: int, // 1..6 for Heading, 0 otherwise
	text:  string, // heap-owned
	page:  int, // 1-based source page
	col:   int, // 0-based column within that page
	// Diagnostics, carried so the UI can show why a block was classified the
	// way it was and the self-test can assert on it.
	size:  f32, // the median glyph height the block was recognised at
	conf:  f32, // mean word confidence, 0..100; -1 when unknown
}

Doc :: struct {
	title:    string, // heap-owned
	author:   string, // heap-owned
	lang:     string, // heap-owned, a BCP-47 tag
	source:   string, // heap-owned: the input path, for provenance
	backend:  string, // heap-owned: which recogniser produced this
	blocks:   [dynamic]Block,
	// Running totals, for the report line in the UI.
	pages:    int,
	words:    int,
	// Structure-recovery notes, one line each, shown in the UI and printed by
	// --convert. These are how a user finds out that a header was dropped.
	notes:    [dynamic]string,
}

doc_init :: proc(d: ^Doc) {
	d.blocks = make([dynamic]Block)
	d.notes = make([dynamic]string)
	d.lang = strings.clone("en")
	d.title = strings.clone("Untitled")
	d.author = strings.clone("")
	d.source = strings.clone("")
	d.backend = strings.clone("")
}

doc_destroy :: proc(d: ^Doc) {
	for b in d.blocks {
		delete(b.text)
	}
	delete(d.blocks)
	for n in d.notes {
		delete(n)
	}
	delete(d.notes)
	delete(d.title)
	delete(d.author)
	delete(d.lang)
	delete(d.source)
	delete(d.backend)
	d^ = {}
}

doc_note :: proc(d: ^Doc, format: string, args: ..any) {
	append(&d.notes, fmt.aprintf(format, ..args))
}

doc_set :: proc(dst: ^string, value: string) {
	if dst^ != "" {
		delete(dst^)
	}
	dst^ = strings.clone(value)
}

doc_add :: proc(d: ^Doc, kind: Block_Kind, text: string, page, col: int, level := 0, size: f32 = 0, conf: f32 = -1) {
	t := strings.trim_space(text)
	if t == "" && kind != .Page_Break {
		return
	}
	append(
		&d.blocks,
		Block {
			kind = kind,
			level = level,
			text = strings.clone(t),
			page = page,
			col = col,
			size = size,
			conf = conf,
		},
	)
	if kind != .Page_Break {
		d.words += count_words(t)
	}
	if page > d.pages {
		d.pages = page
	}
}

count_words :: proc(s: string) -> int {
	n := 0
	in_word := false
	for r in s {
		sp := r == ' ' || r == '\t' || r == '\n' || r == '\r'
		if sp {
			in_word = false
		} else if !in_word {
			in_word = true
			n += 1
		}
	}
	return n
}

// ---------------------------------------------------------------------------
// Chapters
//
// EPUB wants the text split across XHTML documents, and a reader's table of
// contents is only useful if the split means something. The rule:
//
//   * a level-1 heading starts a chapter;
//   * if the document has no level-1 headings at all, every page is a chapter,
//     named "Page N" — which is honest about the fact that nothing better was
//     recoverable.
//
// A chapter is a half-open range of block indices, so no text is copied.
// ---------------------------------------------------------------------------

Chapter :: struct {
	title:    string, // heap-owned
	from, to: int, // block indices, [from, to)
}

doc_chapters :: proc(d: ^Doc, allocator := context.allocator) -> []Chapter {
	out := make([dynamic]Chapter, allocator)

	has_h1 := false
	for b in d.blocks {
		if b.kind == .Heading && b.level == 1 {
			has_h1 = true
			break
		}
	}

	if has_h1 {
		for b, i in d.blocks {
			if b.kind == .Heading && b.level == 1 {
				if len(out) > 0 {
					out[len(out) - 1].to = i
				} else if i > 0 {
					// Front matter before the first heading.
					append(&out, Chapter{title = strings.clone("Front matter", allocator), from = 0, to = i})
				}
				append(&out, Chapter{title = strings.clone(b.text, allocator), from = i, to = len(d.blocks)})
			}
		}
		// Fix the ordering: the front-matter insert above lands after the first
		// real chapter, so sort by `from`.
		for i in 1 ..< len(out) {
			j := i
			for j > 0 && out[j - 1].from > out[j].from {
				out[j - 1], out[j] = out[j], out[j - 1]
				j -= 1
			}
		}
		for i in 0 ..< len(out) - 1 {
			out[i].to = out[i + 1].from
		}
		if len(out) > 0 {
			out[len(out) - 1].to = len(d.blocks)
		}
		return out[:]
	}

	// No headings: one chapter per page.
	page := -1
	for b, i in d.blocks {
		if b.kind == .Page_Break {
			continue
		}
		if b.page != page {
			if len(out) > 0 {
				out[len(out) - 1].to = i
			}
			page = b.page
			append(
				&out,
				Chapter {
					title = fmt.aprintf("Page %d", page, allocator = allocator),
					from = i,
					to = len(d.blocks),
				},
			)
		}
	}
	if len(out) == 0 {
		append(&out, Chapter{title = strings.clone("Text", allocator), from = 0, to = len(d.blocks)})
	}
	return out[:]
}

chapters_free :: proc(cs: []Chapter, allocator := context.allocator) {
	for c in cs {
		delete(c.title, allocator)
	}
	delete(cs, allocator)
}

// ---------------------------------------------------------------------------
// Plain text
// ---------------------------------------------------------------------------

// doc_to_text is the lowest-fidelity export and the one a diff reads best:
// blocks separated by a blank line, headings underlined, nothing else.
doc_to_text :: proc(d: ^Doc, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	first := true
	for blk in d.blocks {
		if blk.kind == .Page_Break {
			continue
		}
		if !first {
			strings.write_string(&b, "\n\n")
		}
		first = false
		strings.write_string(&b, blk.text)
		if blk.kind == .Heading {
			strings.write_byte(&b, '\n')
			rule := blk.level == 1 ? '=' : '-'
			for _ in 0 ..< rune_len(blk.text) {
				strings.write_rune(&b, rule)
			}
		}
	}
	strings.write_byte(&b, '\n')
	return strings.to_string(b)
}

rune_len :: proc(s: string) -> int {
	n := 0
	for _ in s {
		n += 1
	}
	return n
}

// doc_body_text is every paragraph and heading run together with single
// spaces, which is what an accuracy comparison wants: it removes every
// decision about line breaking and leaves only the words.
doc_body_text :: proc(d: ^Doc, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	for blk in d.blocks {
		if blk.kind == .Page_Break {
			continue
		}
		if strings.builder_len(b) > 0 {
			strings.write_byte(&b, ' ')
		}
		strings.write_string(&b, blk.text)
	}
	return strings.to_string(b)
}

// ---------------------------------------------------------------------------
// Markdown
// ---------------------------------------------------------------------------

doc_to_markdown :: proc(d: ^Doc, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	if d.title != "" && d.title != "Untitled" {
		fmt.sbprintfln(&b, "---")
		fmt.sbprintfln(&b, "title: %s", d.title)
		if d.source != "" {
			fmt.sbprintfln(&b, "source: %s", base_name(d.source))
		}
		if d.backend != "" {
			fmt.sbprintfln(&b, "recognised_by: %s", d.backend)
		}
		fmt.sbprintfln(&b, "---")
		strings.write_byte(&b, '\n')
	}
	for blk in d.blocks {
		if blk.kind == .Page_Break {
			continue
		}
		switch blk.kind {
		case .Heading:
			for _ in 0 ..< max(1, min(6, blk.level)) {
				strings.write_byte(&b, '#')
			}
			strings.write_byte(&b, ' ')
			strings.write_string(&b, md_escape_inline(blk.text, context.temp_allocator))
			strings.write_string(&b, "\n\n")
		case .Paragraph:
			strings.write_string(&b, md_escape_inline(blk.text, context.temp_allocator))
			strings.write_string(&b, "\n\n")
		case .Page_Break:
		}
	}
	out := strings.to_string(b)
	return out
}

// md_escape_inline neutralises the handful of characters that would turn a
// recognised word into Markdown syntax. OCR output is arbitrary text, and a
// line that happens to start with "* " must not silently become a list item.
md_escape_inline :: proc(s: string, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	at_start := true
	for r, i in s {
		switch r {
		case '\\', '`', '*', '_', '[', ']':
			strings.write_byte(&b, '\\')
			strings.write_rune(&b, r)
		case '#', '>':
			if at_start {
				strings.write_byte(&b, '\\')
			}
			strings.write_rune(&b, r)
		case:
			strings.write_rune(&b, r)
		}
		_ = i
		at_start = false
	}
	return strings.to_string(b)
}

base_name :: proc(path: string) -> string {
	if i := strings.last_index_byte(path, '/'); i >= 0 {
		return path[i + 1:]
	}
	return path
}

stem_name :: proc(path: string) -> string {
	n := base_name(path)
	if i := strings.last_index_byte(n, '.'); i > 0 {
		return n[:i]
	}
	return n
}
