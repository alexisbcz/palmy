// Reading and writing documents.
//
// Three formats:
//
//   .json  the native format — a direct serialisation of the model, so a
//          document round-trips byte-for-byte through it. Written by hand so
//          the output is stable and readable; read with core:encoding/json.
//   .md    Markdown, as real interop: headings, bold, italic, underline
//          (<u>, which Markdown has no syntax for), inline code, fenced code
//          blocks, bullet and numbered lists with nesting, and quotes.
//   .html  export only, for pasting into something else.
package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

// ---------------------------------------------------------------------------
// Enum names, shared by the JSON writer and reader
// ---------------------------------------------------------------------------

kind_name :: proc(k: Para_Kind) -> string {
	switch k {
	case .Body:
		return "body"
	case .H1:
		return "h1"
	case .H2:
		return "h2"
	case .H3:
		return "h3"
	case .Quote:
		return "quote"
	case .Code:
		return "code"
	}
	return "body"
}

kind_from_name :: proc(s: string) -> Para_Kind {
	switch s {
	case "h1":
		return .H1
	case "h2":
		return .H2
	case "h3":
		return .H3
	case "quote":
		return .Quote
	case "code":
		return .Code
	}
	return .Body
}

align_name :: proc(a: Align) -> string {
	switch a {
	case .Left:
		return "left"
	case .Center:
		return "center"
	case .Right:
		return "right"
	case .Justify:
		return "justify"
	}
	return "left"
}

align_from_name :: proc(s: string) -> Align {
	switch s {
	case "center":
		return .Center
	case "right":
		return .Right
	case "justify":
		return .Justify
	}
	return .Left
}

list_name :: proc(l: List_Kind) -> string {
	switch l {
	case .None:
		return "none"
	case .Bullet:
		return "bullet"
	case .Numbered:
		return "number"
	}
	return "none"
}

list_from_name :: proc(s: string) -> List_Kind {
	switch s {
	case "bullet":
		return .Bullet
	case "number":
		return .Numbered
	}
	return .None
}

// ---------------------------------------------------------------------------
// The native format
// ---------------------------------------------------------------------------

json_escape :: proc(b: ^strings.Builder, s: string) {
	strings.write_byte(b, '"')
	for i in 0 ..< len(s) {
		c := s[i]
		switch c {
		case '"':
			strings.write_string(b, "\\\"")
		case '\\':
			strings.write_string(b, "\\\\")
		case '\n':
			strings.write_string(b, "\\n")
		case '\r':
			strings.write_string(b, "\\r")
		case '\t':
			strings.write_string(b, "\\t")
		case:
			if c < 0x20 {
				fmt.sbprintf(b, "\\u%04x", int(c))
			} else {
				strings.write_byte(b, c)
			}
		}
	}
	strings.write_byte(b, '"')
}

doc_to_json :: proc(d: ^Doc, alloc := context.allocator) -> string {
	b := strings.builder_make(alloc)
	strings.write_string(&b, "{\n  \"format\": \"palmy-docs\",\n  \"version\": 1,\n  \"page\": \"a4\",\n  \"paragraphs\": [\n")
	for &pa, pi in d.paras {
		strings.write_string(&b, "    {")
		fmt.sbprintf(&b, "\"kind\": \"%s\"", kind_name(pa.kind))
		if pa.align != .Left {
			fmt.sbprintf(&b, ", \"align\": \"%s\"", align_name(pa.align))
		}
		if pa.list != .None {
			fmt.sbprintf(&b, ", \"list\": \"%s\"", list_name(pa.list))
		}
		if pa.depth != 0 {
			fmt.sbprintf(&b, ", \"depth\": %d", pa.depth)
		}
		if pa.before != 0 {
			fmt.sbprintf(&b, ", \"before\": %.1f", pa.before)
		}
		if pa.after != 0 {
			fmt.sbprintf(&b, ", \"after\": %.1f", pa.after)
		}
		if pa.break_before {
			strings.write_string(&b, ", \"break\": true")
		}
		strings.write_string(&b, ", \"runs\": [")
		for &r, ri in pa.runs {
			if ri > 0 {
				strings.write_string(&b, ", ")
			}
			strings.write_string(&b, "{\"t\": ")
			json_escape(&b, string(r.text[:]))
			cs := r.style
			if cs.bold {strings.write_string(&b, ", \"b\": true")}
			if cs.italic {strings.write_string(&b, ", \"i\": true")}
			if cs.underline {strings.write_string(&b, ", \"u\": true")}
			if cs.mono {strings.write_string(&b, ", \"m\": true")}
			if cs.size != 0 {fmt.sbprintf(&b, ", \"size\": %.1f", cs.size)}
			if cs.color != 0 {fmt.sbprintf(&b, ", \"color\": \"#%06x\"", cs.color & 0xffffff)}
			strings.write_string(&b, "}")
		}
		strings.write_string(&b, "]}")
		if pi + 1 < len(d.paras) {
			strings.write_string(&b, ",")
		}
		strings.write_string(&b, "\n")
	}
	strings.write_string(&b, "  ]\n}\n")
	return strings.to_string(b)
}

@(private = "file")
jget :: proc(o: json.Object, key: string) -> (json.Value, bool) {
	v, ok := o[key]
	return v, ok
}

@(private = "file")
jstr :: proc(o: json.Object, key: string, def := "") -> string {
	if v, ok := jget(o, key); ok {
		if s, is := v.(json.String); is {
			return string(s)
		}
	}
	return def
}

@(private = "file")
jnum :: proc(o: json.Object, key: string, def: f64 = 0) -> f64 {
	if v, ok := jget(o, key); ok {
		#partial switch n in v {
		case json.Float:
			return f64(n)
		case json.Integer:
			return f64(n)
		}
	}
	return def
}

@(private = "file")
jbool :: proc(o: json.Object, key: string) -> bool {
	if v, ok := jget(o, key); ok {
		if bb, is := v.(json.Boolean); is {
			return bool(bb)
		}
	}
	return false
}

// doc_from_json parses the native format. Anything missing falls back to the
// model's own default, so a hand-edited file with half the fields still loads.
doc_from_json :: proc(src: string) -> (d: Doc, ok: bool) {
	root, err := json.parse(src, .JSON, false, context.temp_allocator)
	if err != .None {
		return {}, false
	}
	obj, is_obj := root.(json.Object)
	if !is_obj {
		return {}, false
	}
	paras_v, has := jget(obj, "paragraphs")
	if !has {
		return {}, false
	}
	arr, is_arr := paras_v.(json.Array)
	if !is_arr {
		return {}, false
	}

	out := Doc {
		paras = make([dynamic]Paragraph, 0, max(1, len(arr))),
	}
	for pv in arr {
		po, pis := pv.(json.Object)
		if !pis {
			continue
		}
		pa := Paragraph {
			kind   = kind_from_name(jstr(po, "kind", "body")),
			align  = align_from_name(jstr(po, "align", "left")),
			list   = list_from_name(jstr(po, "list", "none")),
			depth  = int(jnum(po, "depth", 0)),
			before = f32(jnum(po, "before", 0)),
			after  = f32(jnum(po, "after", 0)),
			break_before = jbool(po, "break"),
			runs   = make([dynamic]Run, 0, 2),
		}
		if rv, hr := jget(po, "runs"); hr {
			if ra, ria := rv.(json.Array); ria {
				for rvv in ra {
					ro, rois := rvv.(json.Object)
					if !rois {
						continue
					}
					cs := Char_Style {
						bold      = jbool(ro, "b"),
						italic    = jbool(ro, "i"),
						underline = jbool(ro, "u"),
						mono      = jbool(ro, "m"),
						size      = f32(jnum(ro, "size", 0)),
					}
					if c := jstr(ro, "color"); len(c) == 7 && c[0] == '#' {
						if v, pok := strconv.parse_u64_of_base(c[1:], 16); pok {
							cs.color = 0xff000000 | u32(v & 0xffffff)
						}
					}
					append(&pa.runs, run_make(cs, jstr(ro, "t")))
				}
			}
		}
		if len(pa.runs) == 0 {
			append(&pa.runs, run_make({}))
		}
		normalise(&pa)
		append(&out.paras, pa)
	}
	if len(out.paras) == 0 {
		append(&out.paras, para_make())
	}
	return out, true
}

save_doc :: proc(d: ^Doc, path: string) -> bool {
	text := doc_to_json(d, context.temp_allocator)
	return os.write_entire_file(path, transmute([]u8)text) == nil
}

load_doc :: proc(path: string) -> (d: Doc, ok: bool) {
	data, read_err := os.read_entire_file(path, context.temp_allocator)
	if read_err != nil {
		return {}, false
	}
	return doc_from_json(string(data))
}

// ---------------------------------------------------------------------------
// Markdown export
// ---------------------------------------------------------------------------

@(private = "file")
md_escape :: proc(b: ^strings.Builder, s: string) {
	for i in 0 ..< len(s) {
		c := s[i]
		switch c {
		case '\\', '*', '`', '<', '[', ']':
			strings.write_byte(b, '\\')
			strings.write_byte(b, c)
		case:
			strings.write_byte(b, c)
		}
	}
}

// md_marks returns the opening and closing delimiters for a character style.
// Whitespace at the edges of a run is moved outside them, because `**bold **`
// is not emphasis in any Markdown dialect.
@(private = "file")
md_write_run :: proc(b: ^strings.Builder, text: string, cs: Char_Style) {
	if len(text) == 0 {
		return
	}
	lead := 0
	for lead < len(text) && text[lead] == ' ' {
		lead += 1
	}
	tail := len(text)
	for tail > lead && text[tail - 1] == ' ' {
		tail -= 1
	}
	strings.write_string(b, text[:lead])
	core := text[lead:tail]

	if len(core) > 0 {
		if cs.underline {strings.write_string(b, "<u>")}
		if cs.bold {strings.write_string(b, "**")}
		if cs.italic {strings.write_string(b, "*")}
		if cs.mono {
			strings.write_byte(b, '`')
			strings.write_string(b, core)
			strings.write_byte(b, '`')
		} else {
			md_escape(b, core)
		}
		if cs.italic {strings.write_string(b, "*")}
		if cs.bold {strings.write_string(b, "**")}
		if cs.underline {strings.write_string(b, "</u>")}
	}
	strings.write_string(b, text[tail:])
}

@(private = "file")
md_write_inline :: proc(b: ^strings.Builder, pa: ^Paragraph) {
	for &r in pa.runs {
		md_write_run(b, string(r.text[:]), r.style)
	}
}

doc_to_markdown :: proc(d: ^Doc, alloc := context.allocator) -> string {
	b := strings.builder_make(alloc)
	in_code := false
	prev_block := false // a block that needs a blank line after it was written
	prev_list := false

	for &pa in d.paras {
		is_list := pa.list != .None

		if pa.kind == .Code {
			if !in_code {
				if prev_block {
					strings.write_string(&b, "\n")
				}
				strings.write_string(&b, "```\n")
				in_code = true
			}
			// Inside a fence everything is literal.
			for &r in pa.runs {
				strings.write_bytes(&b, r.text[:])
			}
			strings.write_string(&b, "\n")
			prev_block = true
			prev_list = false
			continue
		}
		if in_code {
			strings.write_string(&b, "```\n")
			in_code = false
		}

		// Blank line between blocks; consecutive list items stay packed.
		if prev_block && !(is_list && prev_list) {
			strings.write_string(&b, "\n")
		}

		switch pa.kind {
		case .H1:
			strings.write_string(&b, "# ")
		case .H2:
			strings.write_string(&b, "## ")
		case .H3:
			strings.write_string(&b, "### ")
		case .Quote:
			strings.write_string(&b, "> ")
		case .Body, .Code:
		}
		if is_list {
			for _ in 0 ..< pa.depth {
				strings.write_string(&b, "  ")
			}
			if pa.list == .Bullet {
				strings.write_string(&b, "- ")
			} else {
				strings.write_string(&b, "1. ")
			}
		}
		md_write_inline(&b, &pa)
		strings.write_string(&b, "\n")
		prev_block = true
		prev_list = is_list
	}
	if in_code {
		strings.write_string(&b, "```\n")
	}
	return strings.to_string(b)
}

// ---------------------------------------------------------------------------
// Markdown import
// ---------------------------------------------------------------------------

// md_parse_inline turns one line of Markdown into styled runs appended to
// `pa`. Emphasis is handled as a toggle rather than a tree, which is what the
// model can represent — nesting is expressed by the style flags, not by depth.
md_parse_inline :: proc(pa: ^Paragraph, s: string, base: Char_Style) {
	cs := base
	buf := strings.builder_make(context.temp_allocator)

	flush :: proc(pa: ^Paragraph, buf: ^strings.Builder, cs: Char_Style) {
		t := strings.to_string(buf^)
		if len(t) > 0 {
			append(&pa.runs, run_make(cs, t))
			strings.builder_reset(buf)
		}
	}

	i := 0
	for i < len(s) {
		c := s[i]

		// An escape is always one literal character.
		if c == '\\' && i + 1 < len(s) {
			strings.write_byte(&buf, s[i + 1])
			i += 2
			continue
		}

		if c == '`' {
			// Inline code runs to the next backtick, verbatim.
			j := i + 1
			for j < len(s) && s[j] != '`' {
				j += 1
			}
			if j < len(s) {
				flush(pa, &buf, cs)
				code := cs
				code.mono = true
				append(&pa.runs, run_make(code, s[i + 1:j]))
				i = j + 1
				continue
			}
		}

		if strings.has_prefix(s[i:], "<u>") {
			flush(pa, &buf, cs)
			cs.underline = true
			i += 3
			continue
		}
		if strings.has_prefix(s[i:], "</u>") {
			flush(pa, &buf, cs)
			cs.underline = false
			i += 4
			continue
		}
		if strings.has_prefix(s[i:], "<em>") {
			flush(pa, &buf, cs)
			cs.italic = true
			i += 4
			continue
		}
		if strings.has_prefix(s[i:], "</em>") {
			flush(pa, &buf, cs)
			cs.italic = false
			i += 5
			continue
		}
		if strings.has_prefix(s[i:], "<strong>") {
			flush(pa, &buf, cs)
			cs.bold = true
			i += 8
			continue
		}
		if strings.has_prefix(s[i:], "</strong>") {
			flush(pa, &buf, cs)
			cs.bold = false
			i += 9
			continue
		}

		if c == '*' || c == '_' {
			n := 0
			for i + n < len(s) && s[i + n] == c {
				n += 1
			}
			// An opening delimiter must be followed by text, a closing one
			// preceded by it. `_` additionally has to start at a word
			// boundary, so snake_case identifiers survive.
			after := i + n < len(s) ? s[i + n] : ' '
			before := i > 0 ? s[i - 1] : ' '
			opening := after != ' ' && after != 0
			closing := before != ' '
			if c == '_' && opening && !(i == 0 || before == ' ') {
				opening = false
			}
			want_bold := n >= 2
			want_ital := n == 1 || n >= 3
			is_open := want_bold ? !cs.bold : !cs.italic
			if (is_open && opening) || (!is_open && closing) {
				flush(pa, &buf, cs)
				if want_bold {cs.bold = !cs.bold}
				if want_ital {cs.italic = !cs.italic}
				i += min(n, 3)
				continue
			}
		}

		// `[label](url)` keeps the label; the model has no link attribute.
		if c == '[' {
			close := strings.index_byte(s[i:], ']')
			if close > 0 && i + close + 1 < len(s) && s[i + close + 1] == '(' {
				paren := strings.index_byte(s[i + close + 1:], ')')
				if paren > 0 {
					strings.write_string(&buf, s[i + 1:i + close])
					i += close + 1 + paren + 1
					continue
				}
			}
		}

		strings.write_byte(&buf, c)
		i += 1
	}
	flush(pa, &buf, cs)
	if len(pa.runs) == 0 {
		append(&pa.runs, run_make(base))
	}
	normalise(pa)
}

// detab turns tabs into four spaces. The model has no tab stops, and palmy
// draws U+0009 as a missing glyph, so a tab that reaches a run shows up as a
// box in the middle of a code block.
detab :: proc(s: string, alloc := context.temp_allocator) -> string {
	if strings.index_byte(s, '\t') < 0 {
		return s
	}
	b := strings.builder_make(alloc)
	for i in 0 ..< len(s) {
		if s[i] == '\t' {
			strings.write_string(&b, "    ")
		} else {
			strings.write_byte(&b, s[i])
		}
	}
	return strings.to_string(b)
}

// Block is the paragraph currently being accumulated. Markdown's "lazy
// continuation" means a line that is not itself a block marker belongs to
// whatever block is open — so a bullet wrapped over three source lines is one
// list item, not an item followed by two paragraphs.
@(private = "file")
Block :: struct {
	kind:  Para_Kind,
	list:  List_Kind,
	depth: int,
	open:  bool,
}

doc_from_markdown :: proc(src: string) -> Doc {
	out := Doc {
		paras = make([dynamic]Paragraph, 0, 32),
	}
	lines := strings.split_lines(detab(src), context.temp_allocator)

	pending := strings.builder_make(context.temp_allocator)
	blk := Block{}

	flush :: proc(out: ^Doc, pending: ^strings.Builder, blk: ^Block) {
		if !blk.open {
			return
		}
		pa := Paragraph {
			kind  = blk.kind,
			list  = blk.list,
			depth = blk.depth,
			runs  = make([dynamic]Run, 0, 2),
		}
		md_parse_inline(&pa, strings.to_string(pending^), {})
		append(&out.paras, pa)
		strings.builder_reset(pending)
		blk^ = {}
	}

	// cont appends a continuation line to the open block, with the single
	// space Markdown's soft wrap collapses to.
	cont :: proc(pending: ^strings.Builder, blk: ^Block, text: string) {
		if blk.open && strings.builder_len(pending^) > 0 {
			strings.write_byte(pending, ' ')
		}
		strings.write_string(pending, text)
		blk.open = true
	}

	in_code := false
	for raw in lines {
		line := raw

		if strings.has_prefix(strings.trim_left_space(line), "```") ||
		   strings.has_prefix(strings.trim_left_space(line), "~~~") {
			flush(&out, &pending, &blk)
			in_code = !in_code
			continue
		}
		if in_code {
			pa := Paragraph {
				kind = .Code,
				runs = make([dynamic]Run, 0, 1),
			}
			append(&pa.runs, run_make({}, line))
			append(&out.paras, pa)
			continue
		}

		trimmed := strings.trim_right(line, " \t")
		if len(strings.trim_space(trimmed)) == 0 {
			flush(&out, &pending, &blk)
			continue
		}

		// Leading spaces give a list its nesting depth: two per level.
		indent := 0
		for indent < len(trimmed) && trimmed[indent] == ' ' {
			indent += 1
		}
		body := trimmed[indent:]
		depth := indent / 2

		// Headings are always one line of their own.
		hashes := 0
		for hashes < len(body) && body[hashes] == '#' {
			hashes += 1
		}
		if hashes >= 1 && hashes <= 3 && hashes < len(body) && body[hashes] == ' ' {
			flush(&out, &pending, &blk)
			pa := Paragraph {
				kind = hashes == 1 ? .H1 : (hashes == 2 ? .H2 : .H3),
				runs = make([dynamic]Run, 0, 2),
			}
			md_parse_inline(&pa, body[hashes + 1:], {})
			append(&out.paras, pa)
			continue
		}

		// Bullets.
		if len(body) >= 2 && (body[0] == '-' || body[0] == '*' || body[0] == '+') && body[1] == ' ' {
			flush(&out, &pending, &blk)
			blk = {list = .Bullet, depth = depth}
			cont(&pending, &blk, body[2:])
			continue
		}

		// Numbered items: digits, then `.` or `)`, then a space.
		{
			k := 0
			for k < len(body) && body[k] >= '0' && body[k] <= '9' {
				k += 1
			}
			if k > 0 && k + 1 < len(body) && (body[k] == '.' || body[k] == ')') && body[k + 1] == ' ' {
				flush(&out, &pending, &blk)
				blk = {list = .Numbered, depth = depth}
				cont(&pending, &blk, body[k + 2:])
				continue
			}
		}

		// Quotes.
		if strings.has_prefix(body, ">") {
			rest := strings.trim_prefix(body, ">")
			rest = strings.trim_prefix(rest, " ")
			if blk.open && blk.kind != .Quote {
				flush(&out, &pending, &blk)
			}
			blk.kind = .Quote
			cont(&pending, &blk, rest)
			continue
		}

		// Horizontal rules are not in the model; skip them.
		if body == "---" || body == "***" || body == "___" {
			flush(&out, &pending, &blk)
			continue
		}

		// Anything else continues whatever block is open, or starts a body
		// paragraph if none is.
		cont(&pending, &blk, body)
	}
	flush(&out, &pending, &blk)

	if len(out.paras) == 0 {
		append(&out.paras, para_make())
	}
	return out
}

export_markdown :: proc(d: ^Doc, path: string) -> bool {
	text := doc_to_markdown(d, context.temp_allocator)
	return os.write_entire_file(path, transmute([]u8)text) == nil
}

import_markdown :: proc(path: string) -> (d: Doc, ok: bool) {
	data, read_err := os.read_entire_file(path, context.temp_allocator)
	if read_err != nil {
		return {}, false
	}
	return doc_from_markdown(string(data)), true
}

// ---------------------------------------------------------------------------
// HTML export
// ---------------------------------------------------------------------------

@(private = "file")
html_escape :: proc(b: ^strings.Builder, s: string) {
	for i in 0 ..< len(s) {
		switch s[i] {
		case '&':
			strings.write_string(b, "&amp;")
		case '<':
			strings.write_string(b, "&lt;")
		case '>':
			strings.write_string(b, "&gt;")
		case:
			strings.write_byte(b, s[i])
		}
	}
}

doc_to_html :: proc(d: ^Doc, title: string, alloc := context.allocator) -> string {
	b := strings.builder_make(alloc)
	strings.write_string(&b, "<!doctype html>\n<html><head><meta charset=\"utf-8\">\n<title>")
	html_escape(&b, title)
	strings.write_string(
		&b,
		"</title>\n<style>\nbody{margin:0;background:#d4d4d4;font-family:Geist,Inter,system-ui,sans-serif;color:#0a0a0a}\n" +
		".page{width:602px;min-height:931px;margin:32px auto;padding:96px;background:#fff;box-shadow:0 10px 30px rgba(0,0,0,.25)}\n" +
		"h1{font-size:30px;margin:24px 0 10px}h2{font-size:23px;margin:20px 0 8px}h3{font-size:18px;margin:16px 0 6px}\n" +
		"p{font-size:15px;line-height:1.56;margin:0 0 11px}\n" +
		"blockquote{margin:12px 0;padding-left:24px;border-left:3px solid #d4d4d4;font-style:italic}\n" +
		"pre{margin:12px 0;padding:10px 14px;background:#f5f5f5;border-radius:6px;font-size:13px;overflow-x:auto}\n" +
		"ul,ol{font-size:15px;line-height:1.56;padding-left:28px;margin:0 0 11px}\n</style></head>\n<body><div class=\"page\">\n",
	)

	emit_runs :: proc(b: ^strings.Builder, pa: ^Paragraph) {
		for &r in pa.runs {
			cs := r.style
			if cs.color != 0 || cs.size != 0 {
				strings.write_string(b, "<span style=\"")
				if cs.color != 0 {
					fmt.sbprintf(b, "color:#%06x;", cs.color & 0xffffff)
				}
				if cs.size != 0 {
					fmt.sbprintf(b, "font-size:%.0fpx;", cs.size)
				}
				strings.write_string(b, "\">")
			}
			if cs.bold {strings.write_string(b, "<strong>")}
			if cs.italic {strings.write_string(b, "<em>")}
			if cs.underline {strings.write_string(b, "<u>")}
			if cs.mono {strings.write_string(b, "<code>")}
			html_escape(b, string(r.text[:]))
			if cs.mono {strings.write_string(b, "</code>")}
			if cs.underline {strings.write_string(b, "</u>")}
			if cs.italic {strings.write_string(b, "</em>")}
			if cs.bold {strings.write_string(b, "</strong>")}
			if cs.color != 0 || cs.size != 0 {strings.write_string(b, "</span>")}
		}
	}

	list_open := List_Kind.None
	in_pre := false
	for &pa in d.paras {
		if pa.kind == .Code {
			if list_open != .None {
				strings.write_string(&b, list_open == .Bullet ? "</ul>\n" : "</ol>\n")
				list_open = .None
			}
			if !in_pre {
				strings.write_string(&b, "<pre>")
				in_pre = true
			} else {
				strings.write_string(&b, "\n")
			}
			for &r in pa.runs {
				html_escape(&b, string(r.text[:]))
			}
			continue
		}
		if in_pre {
			strings.write_string(&b, "</pre>\n")
			in_pre = false
		}
		if pa.list != list_open {
			if list_open != .None {
				strings.write_string(&b, list_open == .Bullet ? "</ul>\n" : "</ol>\n")
			}
			if pa.list != .None {
				strings.write_string(&b, pa.list == .Bullet ? "<ul>\n" : "<ol>\n")
			}
			list_open = pa.list
		}

		style := ""
		switch pa.align {
		case .Center:
			style = " style=\"text-align:center\""
		case .Right:
			style = " style=\"text-align:right\""
		case .Justify:
			style = " style=\"text-align:justify\""
		case .Left:
		}

		if pa.list != .None {
			fmt.sbprintf(&b, "<li%s>", style)
			emit_runs(&b, &pa)
			strings.write_string(&b, "</li>\n")
			continue
		}
		tag := "p"
		switch pa.kind {
		case .H1:
			tag = "h1"
		case .H2:
			tag = "h2"
		case .H3:
			tag = "h3"
		case .Quote:
			tag = "blockquote"
		case .Body, .Code:
		}
		fmt.sbprintf(&b, "<%s%s>", tag, style)
		emit_runs(&b, &pa)
		fmt.sbprintf(&b, "</%s>\n", tag)
	}
	if in_pre {
		strings.write_string(&b, "</pre>\n")
	}
	if list_open != .None {
		strings.write_string(&b, list_open == .Bullet ? "</ul>\n" : "</ol>\n")
	}
	strings.write_string(&b, "</div></body></html>\n")
	return strings.to_string(b)
}

export_html :: proc(d: ^Doc, path, title: string) -> bool {
	text := doc_to_html(d, title, context.temp_allocator)
	return os.write_entire_file(path, transmute([]u8)text) == nil
}

// ---------------------------------------------------------------------------
// Paths
// ---------------------------------------------------------------------------

swap_ext :: proc(path, ext: string, alloc := context.allocator) -> string {
	dot := strings.last_index_byte(path, '.')
	slash := strings.last_index_byte(path, '/')
	if dot > slash && dot >= 0 {
		return strings.concatenate({path[:dot], ext}, alloc)
	}
	return strings.concatenate({path, ext}, alloc)
}

expand_home :: proc(path: string, alloc := context.allocator) -> string {
	if strings.has_prefix(path, "~/") {
		home := os.get_env("HOME", context.temp_allocator)
		if home != "" {
			return strings.concatenate({home, path[1:]}, alloc)
		}
	}
	return strings.clone(path, alloc)
}
