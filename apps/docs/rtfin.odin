// .rtf import.
//
// The third format this program could write but not read. RTF is the oldest
// of the three and the only one that is not a tree: it is a stream of control
// words with a brace-delimited group stack, and the document structure has to
// be inferred from the order things arrive in. That is the whole difficulty,
// and it is why this is a state machine rather than a walk.
//
// WHAT IS READ
//
//   * paragraphs, with `\pard` resetting them and `\par` ending them;
//   * character formatting — `\b \i \ul \f` against the font table, `\cf`
//     against the colour table, `\fs` for a size that differs from the kind;
//   * paragraph kinds, from `\sN` resolved through the `\stylesheet` group by
//     *name*, so a file from LibreOffice or Word maps its own style numbers
//     onto Heading 1, Quote and Preformatted Text as readily as one this
//     program wrote;
//   * alignment (`\ql \qc \qr \qj`), page breaks (`\page`), indents (`\li`);
//   * lists, from the `{\pntext …}` and `{\listtext …}` marker groups — the
//     marker text itself says whether the list is bulleted or numbered, which
//     is more reliable than chasing `\pn` and `\listtable` variants;
//   * tables: `\trowd`, the `\cellx` edges, `\intbl`, `\cell` and `\row`,
//     including the header flag from `\trhdr` and merged cells from
//     `\clmgf`/`\clmrg` (across) and `\clvmgf`/`\clvmrg` (down);
//   * pictures: `{\pict\pngblip …}` and `\jpegblip`, hex-decoded back into the
//     original file bytes, so a .rtf round trip keeps the picture rather than
//     a note that there was one.
//
// WHAT IS SKIPPED, ON PURPOSE
//
// `{\*\…}` — RTF's own "ignore this if you do not know it" marker — and the
// destinations this model has nowhere to put: `\fonttbl` (read for the mono
// flag and then dropped), `\info`, `\header`, `\footer`, `\footnote`,
// `\field`, `\object`. Skipping is by group depth, so a destination's nested
// groups go with it.
//
// WHAT IS NOT SUPPORTED
//
// Merged cells (`\clmgf`/`\clmrg`/`\clvmgf`), because the table model has no
// span to put them in; nested tables (`\itap`), which collapse into the outer
// one; and `\bin` binary picture data, which no writer here produces.
package main

import "core:os"
import "core:strings"
import "core:unicode/utf8"

// CP1252_HIGH is the 0x80–0x9f range, which is where Windows-1252 differs
// from Latin-1. `\'hh` is a byte in the document's code page, and every RTF
// this program is likely to meet says `\ansicpg1252`.
@(private = "file")
CP1252_HIGH := [32]rune {
	0x20ac, 0x0081, 0x201a, 0x0192, 0x201e, 0x2026, 0x2020, 0x2021,
	0x02c6, 0x2030, 0x0160, 0x2039, 0x0152, 0x008d, 0x017d, 0x008f,
	0x0090, 0x2018, 0x2019, 0x201c, 0x201d, 0x2022, 0x2013, 0x2014,
	0x02dc, 0x2122, 0x0161, 0x203a, 0x0153, 0x009d, 0x017e, 0x0178,
}

@(private = "file")
Rtf_Char :: struct {
	bold:      bool,
	italic:    bool,
	underline: bool,
	mono:      bool,
	color:     u32, // 0 = the default ink
	size:      f32, // px, 0 = whatever the paragraph kind says
}

// Rtf_Group is one `{`…`}` level. RTF's rule is that character formatting is
// restored on `}`, which is exactly a stack of these.
@(private = "file")
Rtf_Group :: struct {
	ch:   Rtf_Char,
	dest: Rtf_Dest,
	skip: bool,
}

@(private = "file")
Rtf_Dest :: enum {
	Body,
	Skip,
	Color_Table,
	Font_Table,
	Stylesheet,
	Style_Entry,
	Pict,
	Marker, // {\pntext …} or {\listtext …}
}

@(private = "file")
Rtf_Reader :: struct {
	s:        string,
	i:        int,
	stack:    [dynamic]Rtf_Group,
	doc:      Doc,

	// The paragraph being built, and the properties `\pard` resets.
	cur:      Paragraph,
	kind:     Para_Kind,
	align:    Align,
	list:     List_Kind,
	depth:    int,
	li_px:    f32,
	brk:      bool,
	intbl:    bool,
	has_text: bool,
	// A picture is its own paragraph and the `\par` that follows it in the
	// file belongs to it, not to an empty paragraph after it.
	after_block: bool,

	// Tables.
	tbl:      ^Table,
	row_cells: [dynamic]Cell,
	cell:     ^Cell,
	edges:    [dynamic]f32, // \cellx, in px, cumulative
	row_edges: [dynamic]f32,
	hdr_row:  bool,
	first_row_hdr: bool,
	in_row:   bool,
	// Merged cells: the flags the next `\cellx` takes (1 = continues a merge
	// across, 2 = continues one down), each cell's flags in this row, and the
	// continuing cells of the table so far, resolved when it is flushed.
	cell_flag: u8,
	row_flags: [dynamic]u8,
	conts_h:  [dynamic][2]int,
	conts_v:  [dynamic][2]int,
	// Every row's own `\cellx` edges, kept for the flush: a writer that
	// merges across by writing one wider cell (LibreOffice, Word) leaves
	// rows with fewer cells, and only the union of all rows' edges says
	// which grid columns that wider cell covers.
	tbl_edges: [dynamic][]f32,

	// The tables RTF keeps at the top of the file.
	colors:   [dynamic]u32,
	col_r:    int,
	col_g:    int,
	col_b:    int,
	col_seen: bool,
	mono_fonts: map[int]bool,
	font_num: int,
	font_mono: bool,
	font_name: strings.Builder,
	styles:   map[int]Para_Kind,
	style_num: int,
	style_name: strings.Builder,

	// A picture being collected.
	pict:     strings.Builder,
	pict_kind: Image_Format,
	pict_w:   int,
	pict_h:   int,
	pict_gw:  f32,
	pict_gh:  f32,

	// The text of a `{\pntext}` or `{\listtext}` marker group, which says
	// whether the list is bulleted or numbered.
	marker:   strings.Builder,

	uc:       int, // how many characters a \uN replacement occupies
	pending_surrogate: rune,
}

import_rtf :: proc(path: string) -> (d: Doc, ok: bool) {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		return {}, false
	}
	text := string(data)
	// The magic. A file that does not start with `{\rtf` is not one, and
	// guessing would produce a document full of control words as text.
	trimmed := strings.trim_left_space(text)
	if !strings.has_prefix(trimmed, "{\\rtf") {
		return {}, false
	}
	return doc_from_rtf(trimmed), true
}

doc_from_rtf :: proc(src: string) -> Doc {
	r := Rtf_Reader {
		s          = src,
		doc        = Doc{paras = make([dynamic]Paragraph, 0, 32)},
		stack      = make([dynamic]Rtf_Group, 0, 16),
		row_cells  = make([dynamic]Cell, 0, 8),
		edges      = make([dynamic]f32, 0, 8),
		row_edges  = make([dynamic]f32, 0, 8),
		row_flags  = make([dynamic]u8, 0, 8, context.temp_allocator),
		conts_h    = make([dynamic][2]int, 0, 8, context.temp_allocator),
		conts_v    = make([dynamic][2]int, 0, 8, context.temp_allocator),
		tbl_edges  = make([dynamic][]f32, 0, 8, context.temp_allocator),
		colors     = make([dynamic]u32, 0, 8),
		mono_fonts = make(map[int]bool),
		styles     = make(map[int]Para_Kind),
		font_name  = strings.builder_make(),
		style_name = strings.builder_make(),
		pict       = strings.builder_make(),
		marker     = strings.builder_make(),
		uc         = 1,
	}
	defer {
		delete(r.stack)
		delete(r.row_cells)
		delete(r.edges)
		delete(r.row_edges)
		delete(r.colors)
		delete(r.mono_fonts)
		delete(r.styles)
		strings.builder_destroy(&r.font_name)
		strings.builder_destroy(&r.style_name)
		strings.builder_destroy(&r.pict)
		strings.builder_destroy(&r.marker)
	}
	append(&r.stack, Rtf_Group{})
	r.cur = para_make()

	rtf_scan(&r)

	// Whatever is still open at the end.
	rtf_end_row(&r, true)
	rtf_flush_table(&r)
	if r.has_text || para_len(&r.cur) > 0 {
		rtf_end_para(&r)
	} else {
		para_destroy(&r.cur)
	}
	if len(r.doc.paras) == 0 {
		append(&r.doc.paras, para_make())
	}
	return r.doc
}

// ---------------------------------------------------------------------------
// The scanner
// ---------------------------------------------------------------------------

@(private = "file")
top :: proc(r: ^Rtf_Reader) -> ^Rtf_Group {
	return &r.stack[len(r.stack) - 1]
}

@(private = "file")
rtf_scan :: proc(r: ^Rtf_Reader) {
	for r.i < len(r.s) {
		c := r.s[r.i]
		switch c {
		case '{':
			r.i += 1
			// A nested group inherits the destination it is inside — the
			// entries of a font table are groups within the font table — and
			// a destination control word at the start of it takes over.
			append(&r.stack, top(r)^)
		case '}':
			r.i += 1
			rtf_close_group(r)
		case '\\':
			rtf_control(r)
		case '\r', '\n':
			r.i += 1 // a line break in the file is not text
		case:
			j := r.i
			for j < len(r.s) && r.s[j] != '\\' && r.s[j] != '{' && r.s[j] != '}' && r.s[j] != '\r' && r.s[j] != '\n' {
				j += 1
			}
			rtf_text_in(r, r.s[r.i:j])
			r.i = j
		}
	}
}

@(private = "file")
rtf_close_group :: proc(r: ^Rtf_Reader) {
	if len(r.stack) <= 1 {
		return
	}
	g := top(r)^
	switch g.dest {
	case .Pict:
		rtf_finish_pict(r)
	case .Style_Entry:
		rtf_finish_style(r)
	case .Font_Table:
		rtf_finish_font(r)
	case .Marker:
		rtf_finish_marker(r)
	case .Color_Table:
		// The table ends with the group; a trailing entry without a `;` is
		// not legal and is ignored.
	case .Body, .Skip, .Stylesheet:
	}
	pop(&r.stack)
}

// rtf_control reads one control word or symbol and acts on it.
@(private = "file")
rtf_control :: proc(r: ^Rtf_Reader) {
	r.i += 1 // past the backslash
	if r.i >= len(r.s) {
		return
	}
	c := r.s[r.i]

	// Control symbols: a single non-alphabetic character.
	if !is_alpha_byte(c) {
		r.i += 1
		switch c {
		case '\\', '{', '}':
			rtf_put_rune(r, rune(c))
		case '\'':
			// A byte in the document's code page.
			if r.i + 1 < len(r.s) {
				v := hex_val(r.s[r.i]) * 16 + hex_val(r.s[r.i + 1])
				r.i += 2
				if v >= 0 {
					rtf_put_byte_cp1252(r, u8(v))
				}
			}
		case '~':
			rtf_put_rune(r, 0x00a0)
		case '_':
			rtf_put_rune(r, '-')
		case '-':
			// An optional hyphen: nothing, unless it is used.
		case '*':
			// "Ignore this destination if you do not understand it." The
			// destinations that *are* understood set themselves below, which
			// is why this only marks and the control word that follows can
			// still claim the group.
			top(r).skip = true
			top(r).dest = .Skip
		case '\r', '\n':
			rtf_par(r)
		}
		return
	}

	// A control word: letters, then an optional signed number, then one
	// optional space which belongs to the word rather than to the text.
	start := r.i
	for r.i < len(r.s) && is_alpha_byte(r.s[r.i]) {
		r.i += 1
	}
	word := r.s[start:r.i]
	num := 0
	has_num := false
	neg := false
	if r.i < len(r.s) && r.s[r.i] == '-' {
		neg = true
		r.i += 1
	}
	for r.i < len(r.s) && r.s[r.i] >= '0' && r.s[r.i] <= '9' {
		num = num * 10 + int(r.s[r.i] - '0')
		r.i += 1
		has_num = true
	}
	if neg {
		num = -num
	}
	if r.i < len(r.s) && r.s[r.i] == ' ' {
		r.i += 1
	}
	rtf_word(r, word, num, has_num)
}

@(private = "file")
is_alpha_byte :: proc(c: u8) -> bool {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
}

@(private = "file")
hex_val :: proc(c: u8) -> int {
	switch {
	case c >= '0' && c <= '9':
		return int(c - '0')
	case c >= 'a' && c <= 'f':
		return int(c - 'a') + 10
	case c >= 'A' && c <= 'F':
		return int(c - 'A') + 10
	}
	return -1
}

// ---------------------------------------------------------------------------
// The control words
// ---------------------------------------------------------------------------

@(private = "file")
rtf_word :: proc(r: ^Rtf_Reader, word: string, num: int, has_num: bool) {
	g := top(r)

	// Destinations claim the group they appear at the start of, whatever the
	// `\*` before them said.
	switch word {
	case "colortbl":
		g.dest, g.skip = .Color_Table, false
		r.col_r, r.col_g, r.col_b, r.col_seen = 0, 0, 0, false
		return
	case "fonttbl":
		g.dest, g.skip = .Font_Table, false
		return
	case "stylesheet":
		g.dest, g.skip = .Stylesheet, false
		return
	case "pict":
		g.dest, g.skip = .Pict, false
		strings.builder_reset(&r.pict)
		r.pict_kind, r.pict_w, r.pict_h, r.pict_gw, r.pict_gh = .Unknown, 0, 0, 0, 0
		return
	case "pntext", "listtext":
		g.dest, g.skip = .Marker, false
		strings.builder_reset(&r.marker)
		return
	case "info", "header", "footer", "headerl", "headerr", "footerl", "footerr",
	     "footnote", "field", "object", "themedata", "colorschememapping",
	     "latentstyles", "datastore", "generator", "listtable", "listoverridetable",
	     "pgdsctbl", "revtbl", "xmlnstbl", "fldinst", "nonshppict", "mmathPr":
		g.dest, g.skip = .Skip, true
		return
	}

	// Inside the file's tables, only their own words matter.
	#partial switch g.dest {
	case .Color_Table:
		switch word {
		case "red":
			r.col_r, r.col_seen = num, true
		case "green":
			r.col_g, r.col_seen = num, true
		case "blue":
			r.col_b, r.col_seen = num, true
		}
		return
	case .Font_Table:
		switch word {
		case "f":
			r.font_num = num
			r.font_mono = false
		case "fmodern":
			r.font_mono = true
		}
		return
	case .Stylesheet:
		// A style entry is a nested group; the number arrives first.
		g.dest = .Style_Entry
		strings.builder_reset(&r.style_name)
		r.style_num = 0
		fallthrough
	case .Style_Entry:
		switch word {
		case "s":
			r.style_num = num
		case "cs", "ds", "ts":
			r.style_num = -1 // a character or table style, not a paragraph one
		}
		return
	case .Pict:
		switch word {
		case "pngblip":
			r.pict_kind = .PNG
		case "jpegblip":
			r.pict_kind = .JPEG
		case "picw":
			r.pict_w = num
		case "pich":
			r.pict_h = num
		case "picwgoal":
			r.pict_gw = f32(num) / 15
		case "pichgoal":
			r.pict_gh = f32(num) / 15
		}
		return
	case .Marker:
		// Inside a marker group everything is decoration except the text,
		// which `rtf_text_in` collects.
		return
	case .Skip:
		return
	}

	switch word {
	// --- character formatting
	case "b":
		g.ch.bold = !has_num || num != 0
	case "i":
		g.ch.italic = !has_num || num != 0
	case "ul":
		g.ch.underline = !has_num || num != 0
	case "ulnone":
		g.ch.underline = false
	case "plain":
		g.ch = {}
	case "f":
		g.ch.mono = r.mono_fonts[num]
	case "fs":
		// Half-points to layout pixels. A size equal to the kind's own is
		// dropped later, so a plain document does not arrive covered in
		// explicit sizes.
		g.ch.size = f32(num) / 1.5
	case "cf":
		// `\cfN` indexes the colour table from zero, where entry zero is the
		// "auto" colour a leading `;` declares. The model's colours carry an
		// alpha byte, and a run that is simply the document's ink carries no
		// colour of its own — otherwise every paragraph of a Word file would
		// arrive explicitly coloured black.
		g.ch.color = 0
		if num > 0 && num < len(r.colors) {
			c := r.colors[num]
			if c != 0 && c != COL_INK {
				g.ch.color = 0xff000000 | c
			}
		}
	case "cb", "highlight", "chcbpat":
	// --- paragraph formatting
	case "pard":
		r.kind = .Body
		r.align = .Left
		r.list = .None
		r.depth = 0
		r.li_px = 0
	case "par":
		rtf_par(r)
	case "line":
		// Our own writer separates several paragraphs in one cell with
		// `\line`, because `\par` ends the cell in some readers.
		rtf_par(r)
	case "s":
		if k, got := r.styles[num]; got {
			r.kind = k
		} else if k2, got2 := rtf_default_style(num); got2 {
			r.kind = k2
		} else {
			r.kind = .Body
		}
	case "outlinelevel":
		switch num {
		case 0:
			r.kind = .H1
		case 1:
			r.kind = .H2
		case 2, 3, 4, 5:
			r.kind = .H3
		}
	case "ql":
		r.align = .Left
	case "qc":
		r.align = .Center
	case "qr":
		r.align = .Right
	case "qj":
		r.align = .Justify
	case "li":
		r.li_px = f32(num) / 15
	case "page":
		r.brk = true
	case "tab":
		rtf_put_rune(r, '\t')
	case "uc":
		r.uc = max(0, num)
	case "u":
		rtf_put_utf16(r, num)
		// The replacement characters that follow belong to the `\u`.
		rtf_skip_replacement(r)
	// --- tables
	case "trowd":
		rtf_begin_row(r)
	case "trhdr":
		r.hdr_row = true
	case "cellx":
		append(&r.row_edges, f32(num) / 15)
		append(&r.row_flags, r.cell_flag)
		r.cell_flag = 0
	case "clmrg":
		r.cell_flag |= 1
	case "clvmrg":
		r.cell_flag |= 2
	case "intbl":
		r.intbl = true
	case "cell":
		rtf_end_cell(r)
	case "row":
		rtf_end_row(r, false)
	case "nestrow", "nesttableprops":
	// --- everything else is formatting this model has nowhere to keep
	}
}

// rtf_default_style is the mapping this program's own writer uses, for a file
// with no stylesheet to resolve the numbers through.
@(private = "file")
rtf_default_style :: proc(n: int) -> (Para_Kind, bool) {
	switch n {
	case 1:
		return .H1, true
	case 2:
		return .H2, true
	case 3:
		return .H3, true
	case 4:
		return .Quote, true
	case 5:
		return .Code, true
	}
	return .Body, false
}

// rtf_skip_replacement eats the `\uc` characters that stand in for a `\u`
// escape for readers that cannot show it — `?` in everything this writes.
@(private = "file")
rtf_skip_replacement :: proc(r: ^Rtf_Reader) {
	left := r.uc
	for left > 0 && r.i < len(r.s) {
		if r.s[r.i] == '\\' {
			// `\'hh` counts as one character.
			if r.i + 3 < len(r.s) && r.s[r.i + 1] == '\'' {
				r.i += 4
				left -= 1
				continue
			}
			break
		}
		if r.s[r.i] == '{' || r.s[r.i] == '}' {
			break
		}
		r.i += 1
		left -= 1
	}
}

// ---------------------------------------------------------------------------
// Text
// ---------------------------------------------------------------------------

@(private = "file")
rtf_text_in :: proc(r: ^Rtf_Reader, s: string) {
	g := top(r)
	#partial switch g.dest {
	case .Skip:
		return
	case .Marker:
		strings.write_string(&r.marker, s)
		return
	case .Pict:
		// Hexadecimal picture data.
		for i in 0 ..< len(s) {
			if hex_val(s[i]) >= 0 {
				strings.write_byte(&r.pict, s[i])
			}
		}
		return
	case .Color_Table:
		// The entries are separated by semicolons; a `;` with no components
		// before it is the "auto" colour.
		for i in 0 ..< len(s) {
			if s[i] != ';' {
				continue
			}
			append(&r.colors, u32(r.col_r & 0xff) << 16 | u32(r.col_g & 0xff) << 8 | u32(r.col_b & 0xff))
			r.col_r, r.col_g, r.col_b, r.col_seen = 0, 0, 0, false
		}
		return
	case .Font_Table:
		strings.write_string(&r.font_name, s)
		return
	case .Stylesheet, .Style_Entry:
		strings.write_string(&r.style_name, s)
		return
	case .Body:
	}
	if s == "" {
		return
	}
	rtf_append(r, s)
}

@(private = "file")
rtf_put_rune :: proc(r: ^Rtf_Reader, c: rune) {
	buf, n := utf8.encode_rune(c)
	rtf_text_in(r, string(buf[:n]))
}

@(private = "file")
rtf_put_byte_cp1252 :: proc(r: ^Rtf_Reader, b: u8) {
	c := rune(b)
	if b >= 0x80 && b <= 0x9f {
		c = CP1252_HIGH[b - 0x80]
	}
	rtf_put_rune(r, c)
}

// rtf_put_utf16 takes one UTF-16 code unit, pairing surrogates.
@(private = "file")
rtf_put_utf16 :: proc(r: ^Rtf_Reader, n: int) {
	v := u16(u32(n) & 0xffff) // `\u` is signed 16-bit, so -10179 is 0xd83d
	switch {
	case v >= 0xd800 && v <= 0xdbff:
		r.pending_surrogate = rune(v)
		return
	case v >= 0xdc00 && v <= 0xdfff:
		if r.pending_surrogate != 0 {
			hi := u32(r.pending_surrogate) - 0xd800
			lo := u32(v) - 0xdc00
			r.pending_surrogate = 0
			rtf_put_rune(r, rune(0x10000 + (hi << 10) + lo))
			return
		}
		return
	}
	r.pending_surrogate = 0
	rtf_put_rune(r, rune(v))
}

// rtf_append puts text into the paragraph under construction, in the current
// character style.
@(private = "file")
rtf_append :: proc(r: ^Rtf_Reader, s: string) {
	g := top(r)
	cs := Char_Style {
		bold      = g.ch.bold,
		italic    = g.ch.italic,
		underline = g.ch.underline,
		mono      = g.ch.mono,
		color     = g.ch.color,
	}
	// Formatting the paragraph kind already implies is dropped, so a heading
	// does not arrive as a heading full of bold runs. Word and LibreOffice
	// both write the style's own bold, italic and font onto every run inside
	// it; the .docx and .odt readers here drop them for the same reason.
	#partial switch r.kind {
	case .H1, .H2, .H3:
		cs.bold = false
	case .Quote:
		cs.italic = false
	case .Code:
		cs.mono = false
	}
	// A size is only worth keeping when it differs from what the paragraph
	// kind would give anyway.
	if g.ch.size > 0 && abs(g.ch.size - kind_metrics(r.kind).size) > 0.6 {
		cs.size = g.ch.size
	}
	// A run that agrees with the last one is appended to it, so a document
	// does not arrive as one run per control word.
	if n := len(r.cur.runs); n > 0 && r.cur.runs[n - 1].style == cs {
		append(&r.cur.runs[n - 1].text, ..transmute([]u8)s)
	} else {
		if n == 1 && len(r.cur.runs[0].text) == 0 {
			// The empty run every fresh paragraph starts with.
			r.cur.runs[0].style = cs
			append(&r.cur.runs[0].text, ..transmute([]u8)s)
		} else {
			append(&r.cur.runs, run_make(cs, s))
		}
	}
	r.has_text = true
	r.after_block = false
}

// ---------------------------------------------------------------------------
// Paragraphs, cells, rows
// ---------------------------------------------------------------------------

@(private = "file")
rtf_apply_props :: proc(r: ^Rtf_Reader, pa: ^Paragraph) {
	pa.kind = r.kind
	pa.align = r.align
	pa.list = r.list
	pa.depth = r.depth
	pa.break_before = r.brk
}

@(private = "file")
rtf_end_para :: proc(r: ^Rtf_Reader) {
	// A paragraph outside a table closes the table that came before it. The
	// rows are collected as they arrive and only become a paragraph here, so
	// without this the table would be appended at the end of the document
	// rather than where it was written.
	if !r.intbl && r.tbl != nil {
		rtf_flush_table(r)
	}
	rtf_apply_props(r, &r.cur)
	if r.intbl && r.cell != nil {
		// Cell paragraphs carry no page break and no list indent of their own.
		r.cur.break_before = false
		append(&r.cell.paras, r.cur)
	} else {
		append(&r.doc.paras, r.cur)
	}
	r.cur = para_make()
	r.brk = false
	r.has_text = false
}

@(private = "file")
rtf_par :: proc(r: ^Rtf_Reader) {
	if top(r).dest == .Skip {
		return
	}
	if r.after_block && !r.has_text && para_len(&r.cur) == 0 {
		r.after_block = false
		return
	}
	if r.intbl && r.cell == nil {
		rtf_ensure_cell(r)
	}
	rtf_end_para(r)
}

@(private = "file")
rtf_begin_row :: proc(r: ^Rtf_Reader) {
	// A `\trowd` while a row is open means the previous one was not closed.
	if r.in_row {
		rtf_end_row(r, false)
	}
	clear(&r.row_edges)
	clear(&r.row_flags)
	r.cell_flag = 0
	r.hdr_row = false
	r.in_row = true
	r.intbl = true
}

@(private = "file")
rtf_ensure_cell :: proc(r: ^Rtf_Reader) {
	if r.cell != nil {
		return
	}
	append(&r.row_cells, Cell{paras = make([dynamic]Paragraph, 0, 1)})
	r.cell = &r.row_cells[len(r.row_cells) - 1]
}

@(private = "file")
rtf_end_cell :: proc(r: ^Rtf_Reader) {
	rtf_ensure_cell(r)
	if r.has_text || para_len(&r.cur) > 0 || len(r.cell.paras) == 0 {
		rtf_end_para(r)
	}
	r.cell = nil
}

// rtf_end_row closes the row being built and hands it to the table. `final`
// is the end-of-document flush, where there may be no row at all.
@(private = "file")
rtf_end_row :: proc(r: ^Rtf_Reader, final: bool) {
	if !r.in_row && len(r.row_cells) == 0 {
		r.intbl = false
		return
	}
	// Anything typed after the last `\cell` belongs to one.
	if r.cell != nil || r.has_text || para_len(&r.cur) > 0 {
		if r.has_text || para_len(&r.cur) > 0 {
			rtf_end_cell(r)
		}
		r.cell = nil
	}
	if len(r.row_cells) == 0 {
		r.in_row = false
		r.intbl = false
		return
	}
	if r.tbl == nil {
		r.tbl = new(Table)
		r.tbl^ = Table {
			rows    = make([dynamic]Row, 0, 4),
			widths  = make([dynamic]f32, 0, 4),
			borders = true,
			header  = false,
		}
		r.first_row_hdr = r.hdr_row
		r.tbl.header = r.hdr_row
	}
	row := Row {
		cells = make([dynamic]Cell, 0, len(r.row_cells)),
	}
	for i in 0 ..< min(len(r.row_cells), len(r.row_flags)) {
		at := [2]int{len(r.tbl.rows), i}
		if r.row_flags[i] & 1 != 0 {append(&r.conts_h, at)}
		if r.row_flags[i] & 2 != 0 {append(&r.conts_v, at)}
	}
	for c in r.row_cells {
		cl := c
		if len(cl.paras) == 0 {
			append(&cl.paras, para_make())
		}
		append(&row.cells, cl)
	}
	append(&r.tbl.rows, row)
	{
		es := make([]f32, len(r.row_edges), context.temp_allocator)
		copy(es, r.row_edges[:])
		append(&r.tbl_edges, es)
	}
	// Column widths from the `\cellx` edges, which are cumulative.
	if len(r.row_edges) > len(r.edges) {
		clear(&r.edges)
		for e in r.row_edges {
			append(&r.edges, e)
		}
	}
	clear(&r.row_cells)
	r.in_row = false
	r.intbl = false
	r.cell = nil
	_ = final
}

// rtf_regrid lays every row onto one column grid: the union of all rows'
// `\cellx` edges (within 2 px, which absorbs twip rounding). A cell whose left
// and right edges are several grid columns apart becomes a merge across that
// many columns, and the continuation flags collected per cell are moved to
// the cell's grid column. A row whose edges do not match its cells is left
// as it was.
@(private = "file")
rtf_regrid :: proc(r: ^Rtf_Reader, t: ^Table) {
	grid := make([dynamic]f32, 0, 16, context.temp_allocator)
	for es in r.tbl_edges {
		outer: for e in es {
			for g in grid {
				if abs(g - e) <= 2 {
					continue outer
				}
			}
			append(&grid, e)
		}
	}
	for i in 1 ..< len(grid) {
		for j := i; j > 0 && grid[j] < grid[j - 1]; j -= 1 {
			grid[j], grid[j - 1] = grid[j - 1], grid[j]
		}
	}
	if len(grid) == 0 || len(grid) > TABLE_MAX_COLS {
		return
	}
	col_of :: proc(grid: []f32, e: f32) -> int {
		for g, i in grid {
			if abs(g - e) <= 2 {
				return i
			}
		}
		return -1
	}
	// Where each (row, cell) landed, to move the continuation flags.
	moved := make(map[[2]int]int, 16, context.temp_allocator)
	changed := false
	for ri in 0 ..< min(len(t.rows), len(r.tbl_edges)) {
		es := r.tbl_edges[ri]
		row := &t.rows[ri]
		if len(es) != len(row.cells) || len(es) == len(grid) {
			for k in 0 ..< len(row.cells) {
				moved[{ri, k}] = k
			}
			continue
		}
		cells := make([dynamic]Cell, 0, len(grid))
		for k in 0 ..< len(row.cells) {
			start := k == 0 ? 0 : col_of(grid[:], es[k - 1]) + 1
			end := col_of(grid[:], es[k]) // inclusive
			if start < 0 || end < start {
				start, end = len(cells), len(cells)
			}
			for len(cells) < start {
				append(&cells, cell_make())
			}
			cl := row.cells[k]
			if end > start {
				cl.cspan = end - start + 1
			}
			moved[{ri, k}] = len(cells)
			append(&cells, cl)
			for len(cells) <= end {
				append(&cells, cell_make())
			}
		}
		for len(cells) < len(grid) {
			append(&cells, cell_make())
		}
		delete(row.cells)
		row.cells = cells
		changed = true
	}
	if !changed {
		return
	}
	for &q in r.conts_h {
		q[1] = moved[q] or_else q[1]
	}
	for &q in r.conts_v {
		q[1] = moved[q] or_else q[1]
	}
	clear(&r.edges)
	for g in grid {
		append(&r.edges, g)
	}
}

// rtf_flush_table turns the rows collected so far into a table paragraph.
@(private = "file")
rtf_flush_table :: proc(r: ^Rtf_Reader) {
	if r.tbl == nil {
		return
	}
	t := r.tbl
	r.tbl = nil
	if len(t.rows) == 0 {
		table_destroy(t)
		free(t)
		clear(&r.edges)
		clear(&r.tbl_edges)
		return
	}
	rtf_regrid(r, t)
	// Widths from the cumulative edges, clamped onto the content measure by
	// `table_fit_widths` the way every other table here is.
	n := table_cols(t)
	prev := f32(0)
	for i in 0 ..< n {
		w := i < len(r.edges) ? r.edges[i] - prev : CONTENT_W / f32(n)
		if i < len(r.edges) {
			prev = r.edges[i]
		}
		append(&t.widths, max(w, TABLE_MIN_COL))
	}
	table_fit_widths(t)
	table_apply_conts(t, r.conts_h[:], r.conts_v[:])
	clear(&r.conts_h)
	clear(&r.conts_v)
	clear(&r.tbl_edges)
	clear(&r.edges)

	pa := para_make(.Table)
	pa.table = t
	append(&r.doc.paras, pa)
}

// ---------------------------------------------------------------------------
// Group endings that mean something
// ---------------------------------------------------------------------------

@(private = "file")
rtf_finish_font :: proc(r: ^Rtf_Reader) {
	name := strings.to_string(r.font_name)
	mono := r.font_mono
	if !mono {
		low := strings.to_lower(name, context.temp_allocator)
		mono = strings.contains(low, "courier") || strings.contains(low, "mono") || strings.contains(low, "consolas")
	}
	if mono {
		r.mono_fonts[r.font_num] = true
	}
	strings.builder_reset(&r.font_name)
	r.font_mono = false
}

// rtf_finish_style maps one `{\sN … Name;}` entry onto a paragraph kind by
// its *name*, which is the only part of a stylesheet that means the same
// thing in every producer.
@(private = "file")
rtf_finish_style :: proc(r: ^Rtf_Reader) {
	raw := strings.to_string(r.style_name)
	name := strings.trim_space(strings.trim_right(strings.trim_space(raw), ";"))
	strings.builder_reset(&r.style_name)
	if r.style_num < 0 || name == "" {
		return
	}
	low := strings.to_lower(name, context.temp_allocator)
	// Separators removed, so "heading 1", "Heading1" and "heading_20_1" all
	// land on the same key.
	b := strings.builder_make(context.temp_allocator)
	for i in 0 ..< len(low) {
		c := low[i]
		if (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') {
			strings.write_byte(&b, c)
		}
	}
	switch strings.to_string(b) {
	case "heading1", "title", "h1":
		r.styles[r.style_num] = .H1
	case "heading2", "subtitle", "h2":
		r.styles[r.style_num] = .H2
	case "heading3", "heading4", "heading5", "heading6", "h3":
		r.styles[r.style_num] = .H3
	case "quote", "blockquote", "intensequote", "blocktext":
		r.styles[r.style_num] = .Quote
	case "preformattedtext", "code", "sourcecode", "plaintext", "htmlpreformatted":
		r.styles[r.style_num] = .Code
	}
}

// rtf_finish_marker reads the literal list marker a writer put in the file for
// readers that do not implement `\pn`: a digit means a numbered list, anything
// else means a bullet. That is a more reliable signal than the half-dozen
// competing list descriptions, and it is the one thing every producer writes.
@(private = "file")
rtf_finish_marker :: proc(r: ^Rtf_Reader) {
	text := strings.trim_space(strings.to_string(r.marker))
	strings.builder_reset(&r.marker)
	if text == "" {
		r.list = .Bullet
		return
	}
	for i in 0 ..< len(text) {
		if text[i] >= '0' && text[i] <= '9' {
			r.list = .Numbered
			return
		}
	}
	r.list = .Bullet
}

// rtf_finish_pict hex-decodes the picture and makes it a paragraph.
@(private = "file")
rtf_finish_pict :: proc(r: ^Rtf_Reader) {
	hex := strings.to_string(r.pict)
	defer strings.builder_reset(&r.pict)
	if len(hex) < 2 {
		return
	}
	bytes := make([]u8, len(hex) / 2, context.temp_allocator)
	for i in 0 ..< len(bytes) {
		hi, lo := hex_val(hex[i * 2]), hex_val(hex[i * 2 + 1])
		if hi < 0 || lo < 0 {
			return
		}
		bytes[i] = u8(hi * 16 + lo)
	}
	im, got := image_from_bytes(bytes, "", "", 1)
	if !got {
		return
	}
	// `\picwgoal` is the drawn width in twips; the scale is what turns the
	// intrinsic pixels into it, which is how the picture comes back the size
	// it was exported at.
	if r.pict_gw > 0 && im.w > 0 {
		image_set_scale(&im, r.pict_gw / f32(im.w))
	}
	pa := image_para_make(im, r.align)
	// A picture interrupts the paragraph it is in: anything typed before it
	// is its own paragraph, and the picture is the next one.
	if r.has_text || para_len(&r.cur) > 0 {
		rtf_end_para(r)
	}
	if r.intbl && r.cell != nil {
		append(&r.cell.paras, pa)
	} else {
		// Same ordering rule as `rtf_end_para`: a table still being collected
		// belongs before the picture that follows it.
		if r.tbl != nil {
			rtf_flush_table(r)
		}
		append(&r.doc.paras, pa)
	}
	r.after_block = true
}
