// Markdown, rendered rather than shown.
//
// This is not a full CommonMark implementation and does not pretend to be. It
// is the subset people actually write in a notes app — headings, emphasis,
// code, lists, quotes, rules, links — turned into palmy text styling so the
// preview reads as a document instead of as source.
//
// Wrapping is the interesting constraint. A paragraph with no inline marks is
// one text node, so palmy's own word wrap handles it. A paragraph that mixes
// styles becomes one node per *word* in a wrapping row, which puts the break
// opportunities back where they belong — between words, not between spans.
package main

import "core:strings"
import p "palmy:."

Span :: struct {
	text: string,
	bold: bool,
	em:   bool,
	code: bool,
	link: bool,
}

Block_Kind :: enum {
	Para,
	H1,
	H2,
	H3,
	Bullet,
	Number,
	Quote,
	Code,
	Rule,
	Blank,
	Check_Off,
	Check_On,
}

Block :: struct {
	kind:   Block_Kind,
	text:   string,
	marker: string, // "1." for ordered items
}

// ---------------------------------------------------------------------------
// Blocks
// ---------------------------------------------------------------------------

md_blocks :: proc(body: string, allocator := context.temp_allocator) -> []Block {
	out := make([dynamic]Block, 0, 64, allocator)
	in_code := false
	rest := body
	for line in strings.split_lines_iterator(&rest) {
		t := strings.trim_right(line, " \t\r")

		if strings.has_prefix(strings.trim_space(t), "```") {
			in_code = !in_code
			continue
		}
		if in_code {
			append(&out, Block{kind = .Code, text = t})
			continue
		}

		trimmed := strings.trim_left(t, " \t")
		switch {
		case trimmed == "":
			append(&out, Block{kind = .Blank})
		case trimmed == "---" || trimmed == "***" || trimmed == "___":
			append(&out, Block{kind = .Rule})
		case strings.has_prefix(trimmed, "### "):
			append(&out, Block{kind = .H3, text = trimmed[4:]})
		case strings.has_prefix(trimmed, "## "):
			append(&out, Block{kind = .H2, text = trimmed[3:]})
		case strings.has_prefix(trimmed, "# "):
			append(&out, Block{kind = .H1, text = trimmed[2:]})
		case strings.has_prefix(trimmed, "> "):
			append(&out, Block{kind = .Quote, text = trimmed[2:]})
		case strings.has_prefix(trimmed, "- [ ] ") || strings.has_prefix(trimmed, "* [ ] "):
			append(&out, Block{kind = .Check_Off, text = trimmed[6:]})
		case strings.has_prefix(trimmed, "- [x] ") || strings.has_prefix(trimmed, "* [x] "):
			append(&out, Block{kind = .Check_On, text = trimmed[6:]})
		case strings.has_prefix(trimmed, "- ") || strings.has_prefix(trimmed, "* "):
			append(&out, Block{kind = .Bullet, text = trimmed[2:]})
		case is_ordered(trimmed):
			dot := strings.index_byte(trimmed, '.')
			append(
				&out,
				Block{kind = .Number, text = strings.trim_left(trimmed[dot + 1:], " "), marker = trimmed[:dot + 1]},
			)
		case:
			append(&out, Block{kind = .Para, text = trimmed})
		}
	}
	return out[:]
}

is_ordered :: proc(s: string) -> bool {
	i := 0
	for i < len(s) && s[i] >= '0' && s[i] <= '9' {
		i += 1
	}
	return i > 0 && i < len(s) - 1 && s[i] == '.' && s[i + 1] == ' '
}

// ---------------------------------------------------------------------------
// Inline
// ---------------------------------------------------------------------------

md_spans :: proc(src: string, allocator := context.temp_allocator) -> []Span {
	out := make([dynamic]Span, 0, 8, allocator)
	cur := Span{}
	sb := strings.builder_make(allocator)

	flush :: proc(out: ^[dynamic]Span, sb: ^strings.Builder, cur: Span) {
		if strings.builder_len(sb^) == 0 {
			return
		}
		s := cur
		s.text = strings.clone(strings.to_string(sb^), sb.buf.allocator)
		append(out, s)
		strings.builder_reset(sb)
	}

	i := 0
	for i < len(src) {
		c := src[i]
		switch {
		case c == '\\' && i + 1 < len(src):
			strings.write_byte(&sb, src[i + 1])
			i += 2
			continue
		case c == '`':
			end := strings.index_byte(src[i + 1:], '`')
			if end >= 0 {
				flush(&out, &sb, cur)
				append(&out, Span{text = src[i + 1:i + 1 + end], code = true, bold = cur.bold, em = cur.em})
				i += end + 2
				continue
			}
		case c == '*' && i + 1 < len(src) && src[i + 1] == '*':
			flush(&out, &sb, cur)
			cur.bold = !cur.bold
			i += 2
			continue
		case c == '*' || c == '_':
			// A lone underscore inside a word is not emphasis: snake_case is
			// far more common in notes than _emphasis_ mid-word.
			if c == '_' && i > 0 && is_word_byte(src[i - 1]) && i + 1 < len(src) && is_word_byte(src[i + 1]) {
				break
			}
			flush(&out, &sb, cur)
			cur.em = !cur.em
			i += 1
			continue
		case c == '[':
			close := strings.index_byte(src[i:], ']')
			if close > 0 && i + close + 1 < len(src) && src[i + close + 1] == '(' {
				tail := strings.index_byte(src[i + close:], ')')
				if tail > 0 {
					flush(&out, &sb, cur)
					l := cur
					l.link = true
					l.text = src[i + 1:i + close]
					append(&out, l)
					i += close + tail + 1
					continue
				}
			}
		}
		strings.write_byte(&sb, c)
		i += 1
	}
	flush(&out, &sb, cur)
	return out[:]
}

is_word_byte :: proc(c: u8) -> bool {
	return c == '_' || (c | 32 >= 'a' && c | 32 <= 'z') || (c >= '0' && c <= '9')
}

// ---------------------------------------------------------------------------
// Render
// ---------------------------------------------------------------------------

span_class :: proc(s: Span, base: string) -> string {
	out := base
	if s.code {
		out = tfmt("%s font-mono text-[12.5] text-[#8250df]", out)
	}
	if s.bold {
		out = tfmt("%s font-semibold", out)
	}
	if s.em {
		// No italic face is loaded, and palmy does not synthesise one, so
		// emphasis is carried by weight and colour instead. Noted as a gap.
		out = tfmt("%s font-medium text-[#1d4ed8]", out)
	}
	if s.link {
		out = tfmt("%s underline text-[#1d4ed8]", out)
	}
	return out
}

// Atom is one drawable piece. `glued` means it follows the previous atom with
// no space between them in the source — `**Bold**,` is two atoms and one word,
// and without this the comma would float away from the word it belongs to.
Atom :: struct {
	span:  Span,
	glued: bool,
}

md_atoms :: proc(spans: []Span, allocator := context.temp_allocator) -> []Atom {
	out := make([dynamic]Atom, 0, 16, allocator)
	glue := false
	for s in spans {
		if s.code || s.link {
			// Inline code and links stay whole: they are short, and breaking
			// a chip across two lines looks like a mistake.
			append(&out, Atom{s, glue})
			glue = true
			continue
		}
		t := s.text
		i := 0
		for i < len(t) {
			for i < len(t) && is_space_byte(t[i]) {
				i += 1
				glue = false
			}
			if i >= len(t) {
				break
			}
			j := i
			for j < len(t) && !is_space_byte(t[j]) {
				j += 1
			}
			w := s
			w.text = t[i:j]
			append(&out, Atom{w, glue})
			glue = true
			i = j
		}
		if len(t) > 0 && is_space_byte(t[len(t) - 1]) {
			glue = false
		}
	}
	return out[:]
}

is_space_byte :: proc(c: u8) -> bool {
	return c == ' ' || c == '\t'
}

// md_inline draws a run of marked-up text. One node when it is plain, and
// otherwise one group per word in a wrapping row, so the line breaks fall
// between words rather than between styles.
md_inline :: proc(ui: ^p.Ctx, src: string, base: string, space_w: f32) {
	spans := md_spans(src)
	if len(spans) == 0 {
		p.text(ui, "", base)
		return
	}
	if len(spans) == 1 && !spans[0].bold && !spans[0].em && !spans[0].code && !spans[0].link {
		p.text(ui, spans[0].text, tfmt("w-full %s", base))
		return
	}

	idx := p.row(ui, tfmt("w-full flex-wrap items-baseline %s", base))
	st := p.style(ui, idx)
	st.gap = {space_w, 2}
	defer p.end(ui)

	atoms := md_atoms(spans)
	i := 0
	for i < len(atoms) {
		j := i + 1
		for j < len(atoms) && atoms[j].glued {
			j += 1
		}
		if j == i + 1 && !atoms[i].span.code {
			draw_atom(ui, atoms[i].span, base)
			i = j
			continue
		}
		// A word made of several styles is one shrink-0 row with no gap.
		g := p.row(ui, "shrink-0 items-baseline")
		p.style(ui, g).gap = {0, 0}
		for k in i ..< j {
			draw_atom(ui, atoms[k].span, base)
		}
		p.end(ui)
		i = j
	}
}

draw_atom :: proc(ui: ^p.Ctx, s: Span, base: string) {
	if s.code {
		p.row(ui, "shrink-0 px-1 rounded bg-muted items-center")
		p.text(ui, s.text, span_class(s, base))
		p.end(ui)
		return
	}
	p.text(ui, s.text, tfmt("shrink-0 whitespace-nowrap %s", span_class(s, base)))
}

// md_render draws the whole document.
md_render :: proc(ui: ^p.Ctx, body: string, space_w: f32) {
	blocks := md_blocks(body)

	code_run := false
	for b, i in blocks {
		if b.kind == .Code && !code_run {
			code_run = true
			p.col(ui, "w-full shrink-0 rounded-lg bg-muted border border-border px-3 py-2.5 my-1 gap-0 overflow-hidden")
		}
		if b.kind != .Code && code_run {
			code_run = false
			p.end(ui)
		}

		switch b.kind {
		case .Code:
			p.text(ui, b.text == "" ? " " : b.text, "w-full font-mono text-[12.5] leading-[19] text-foreground whitespace-nowrap")
		case .Blank:
			// Blank lines between paragraphs are spacing, not empty rows.
			if i > 0 && i + 1 < len(blocks) {
				p.div(ui, "w-full h-[8] shrink-0")
				p.end(ui)
			}
		case .Rule:
			p.div(ui, "w-full h-px my-3 shrink-0 bg-border")
			p.end(ui)
		case .H1:
			p.col(ui, "w-full shrink-0 pt-2 pb-1.5 gap-1")
			md_inline(ui, b.text, "text-[24] leading-[32] font-semibold text-foreground", space_w)
			p.end(ui)
		case .H2:
			p.col(ui, "w-full shrink-0 pt-3 pb-1 gap-1")
			md_inline(ui, b.text, "text-[18] leading-[26] font-semibold text-foreground", space_w)
			p.end(ui)
		case .H3:
			p.col(ui, "w-full shrink-0 pt-2.5 pb-0.5")
			md_inline(ui, b.text, "text-[15] leading-[22] font-semibold text-foreground", space_w)
			p.end(ui)
		case .Quote:
			p.row(ui, "w-full shrink-0 gap-3 my-1 pl-0.5 items-stretch")
			p.div(ui, "w-[3] shrink-0 rounded-full bg-border")
			p.end(ui)
			p.col(ui, "flex-1 min-w-0")
			md_inline(ui, b.text, "text-[13.5] leading-[21] text-muted-foreground", space_w)
			p.end(ui)
			p.end(ui)
		case .Bullet:
			p.row(ui, "w-full shrink-0 gap-2.5 items-start")
			p.div(ui, "w-[5] h-[5] mt-[8] ml-[4] shrink-0 rounded-full bg-muted-foreground/70")
			p.end(ui)
			p.col(ui, "flex-1 min-w-0")
			md_inline(ui, b.text, "text-[13.5] leading-[21] text-foreground", space_w)
			p.end(ui)
			p.end(ui)
		case .Number:
			p.row(ui, "w-full shrink-0 gap-2 items-start")
			p.text(ui, b.marker, "w-[20] shrink-0 text-right text-[13.5] leading-[21] text-muted-foreground")
			p.col(ui, "flex-1 min-w-0")
			md_inline(ui, b.text, "text-[13.5] leading-[21] text-foreground", space_w)
			p.end(ui)
			p.end(ui)
		case .Check_Off, .Check_On:
			on := b.kind == .Check_On
			p.row(ui, "w-full shrink-0 gap-2.5 items-start")
			box := p.div(ui, "flex-row size-[14] mt-[4] shrink-0 items-center justify-center rounded border")
			p.apply(ui, on ? "bg-accent-blue border-accent-blue" : "bg-background border-input", box)
			if on {
				p.icon(ui, ICON_CHECK, "size-2.5 text-white")
			}
			p.end(ui)
			p.col(ui, "flex-1 min-w-0")
			md_inline(
				ui,
				b.text,
				on \
				? "text-[13.5] leading-[21] text-muted-foreground line-through" \
				: "text-[13.5] leading-[21] text-foreground",
				space_w,
			)
			p.end(ui)
			p.end(ui)
		case .Para:
			p.col(ui, "w-full shrink-0")
			md_inline(ui, b.text, "text-[13.5] leading-[21] text-foreground", space_w)
			p.end(ui)
		}
	}
	if code_run {
		p.end(ui)
	}
}
