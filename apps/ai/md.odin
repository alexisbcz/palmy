package main

// Markdown: a tokeniser and a palmy renderer.
//
// A local model answers in markdown whether you ask it to or not, so showing
// the raw markup is not an option. This covers what a chat reply actually
// contains: ATX headings, bold, italic, inline code, fenced code blocks,
// bullet and numbered lists, blockquotes, horizontal rules and links.
//
// Two stages, split so the first can be asserted without a window:
//
//   md_blocks(src)  -> []Block   line-structure
//   md_spans(src)   -> []Span    inline markup within one block
//
// Rendering an inline run is the awkward part. palmy wraps the text inside one
// text node, but a run of mixed bold/italic/code is several nodes, so wrapping
// has to happen between them: the run is split into words and laid out in a
// `flex-wrap` row whose horizontal gap is set to the measured width of a
// space. A word made of more than one style becomes a nested gap-free row, so
// `**bold**text` stays glued together.

import "core:fmt"
import "core:mem"
import "core:strconv"
import "core:strings"
import p "palmy:."
import sc "shadcn:."

// ---------------------------------------------------------------------------
// Blocks
// ---------------------------------------------------------------------------

Block_Kind :: enum u8 {
	Paragraph,
	Heading,
	Bullet,
	Numbered,
	Quote,
	Code,
	Rule,
}

Block :: struct {
	kind:    Block_Kind,
	level:   int,      // heading level 1-6, or list nesting depth
	text:    string,   // inline source
	lang:    string,   // fenced code language
	lines:   []string, // fenced code content
	ordinal: int,      // numbered list item number
	open:    bool,     // an unterminated fence: the model is still typing it
}

md_blocks :: proc(src: string, allocator := context.allocator) -> []Block {
	out := make([dynamic]Block, allocator)
	lines := strings.split(src, "\n", context.temp_allocator)
	// A source ending in a newline yields one trailing empty element that is
	// the terminator, not a blank line. Dropping it keeps an unterminated
	// fence from gaining a phantom last line while the model is still typing.
	if len(lines) > 1 && lines[len(lines) - 1] == "" {
		lines = lines[:len(lines) - 1]
	}

	para := strings.builder_make(context.temp_allocator)
	quote := strings.builder_make(context.temp_allocator)

	flush_para :: proc(out: ^[dynamic]Block, b: ^strings.Builder, allocator: mem.Allocator) {
		t := strings.trim_space(strings.to_string(b^))
		if t != "" {
			append(out, Block{kind = .Paragraph, text = strings.clone(t, allocator)})
		}
		strings.builder_reset(b)
	}
	flush_quote :: proc(out: ^[dynamic]Block, b: ^strings.Builder, allocator: mem.Allocator) {
		t := strings.trim_space(strings.to_string(b^))
		if t != "" {
			append(out, Block{kind = .Quote, text = strings.clone(t, allocator)})
		}
		strings.builder_reset(b)
	}

	i := 0
	for i < len(lines) {
		raw := lines[i]
		trimmed := strings.trim_space(raw)

		// Fenced code. The fence may never close, which is the normal case
		// halfway through a streamed reply.
		if strings.has_prefix(trimmed, "```") || strings.has_prefix(trimmed, "~~~") {
			flush_para(&out, &para, allocator)
			flush_quote(&out, &quote, allocator)
			marker := trimmed[:3]
			lang := strings.trim_space(trimmed[3:])
			body := make([dynamic]string, allocator)
			i += 1
			closed := false
			for i < len(lines) {
				l := lines[i]
				if strings.has_prefix(strings.trim_space(l), marker) {
					closed = true
					i += 1
					break
				}
				append(&body, strings.clone(l, allocator))
				i += 1
			}
			append(
				&out,
				Block {
					kind = .Code,
					lang = strings.clone(lang, allocator),
					lines = body[:],
					open = !closed,
				},
			)
			continue
		}

		if trimmed == "" {
			flush_para(&out, &para, allocator)
			flush_quote(&out, &quote, allocator)
			i += 1
			continue
		}

		// Horizontal rule.
		if is_rule(trimmed) {
			flush_para(&out, &para, allocator)
			flush_quote(&out, &quote, allocator)
			append(&out, Block{kind = .Rule})
			i += 1
			continue
		}

		// ATX heading.
		if trimmed[0] == '#' {
			n := 0
			for n < len(trimmed) && trimmed[n] == '#' {
				n += 1
			}
			if n <= 6 && n < len(trimmed) && trimmed[n] == ' ' {
				flush_para(&out, &para, allocator)
				flush_quote(&out, &quote, allocator)
				append(
					&out,
					Block {
						kind = .Heading,
						level = n,
						text = strings.clone(strings.trim_space(trimmed[n:]), allocator),
					},
				)
				i += 1
				continue
			}
		}

		// Blockquote: consecutive `>` lines join into one block.
		if trimmed[0] == '>' {
			flush_para(&out, &para, allocator)
			body := strings.trim_space(trimmed[1:])
			if strings.builder_len(quote) > 0 {
				strings.write_byte(&quote, ' ')
			}
			strings.write_string(&quote, body)
			i += 1
			continue
		}
		flush_quote(&out, &quote, allocator)

		// List items. The indentation decides the depth; two spaces a level,
		// which is what every model emits.
		indent := 0
		for indent < len(raw) && (raw[indent] == ' ' || raw[indent] == '\t') {
			indent += raw[indent] == '\t' ? 4 : 1
		}
		if len(trimmed) > 1 &&
		   (trimmed[0] == '-' || trimmed[0] == '*' || trimmed[0] == '+') &&
		   trimmed[1] == ' ' {
			flush_para(&out, &para, allocator)
			append(
				&out,
				Block {
					kind = .Bullet,
					level = indent / 2,
					text = strings.clone(strings.trim_space(trimmed[2:]), allocator),
				},
			)
			i += 1
			continue
		}
		if n, rest, ok := leading_number(trimmed); ok {
			flush_para(&out, &para, allocator)
			append(
				&out,
				Block {
					kind = .Numbered,
					level = indent / 2,
					ordinal = n,
					text = strings.clone(strings.trim_space(rest), allocator),
				},
			)
			i += 1
			continue
		}

		// A plain paragraph line, soft-wrapped onto the previous one.
		if strings.builder_len(para) > 0 {
			strings.write_byte(&para, ' ')
		}
		strings.write_string(&para, trimmed)
		i += 1
	}

	flush_para(&out, &para, allocator)
	flush_quote(&out, &quote, allocator)
	return out[:]
}

@(private = "file")
is_rule :: proc(s: string) -> bool {
	if len(s) < 3 {
		return false
	}
	c := s[0]
	if c != '-' && c != '*' && c != '_' {
		return false
	}
	for i in 0 ..< len(s) {
		if s[i] != c && s[i] != ' ' {
			return false
		}
	}
	return true
}

@(private = "file")
leading_number :: proc(s: string) -> (n: int, rest: string, ok: bool) {
	i := 0
	for i < len(s) && s[i] >= '0' && s[i] <= '9' {
		i += 1
	}
	if i == 0 || i + 1 >= len(s) {
		return 0, s, false
	}
	if (s[i] != '.' && s[i] != ')') || s[i + 1] != ' ' {
		return 0, s, false
	}
	v, pok := strconv.parse_int(s[:i])
	if !pok {
		return 0, s, false
	}
	return v, s[i + 2:], true
}

// ---------------------------------------------------------------------------
// Inline spans
// ---------------------------------------------------------------------------

Span_Kind :: enum u8 {
	Text,
	Bold,
	Italic,
	Bold_Italic,
	Code,
	Strike,
	Link,
}

Span :: struct {
	kind: Span_Kind,
	text: string,
	href: string,
}

md_spans :: proc(src: string, allocator := context.allocator) -> []Span {
	out := make([dynamic]Span, allocator)
	plain := strings.builder_make(context.temp_allocator)

	flush :: proc(out: ^[dynamic]Span, b: ^strings.Builder, allocator: mem.Allocator) {
		if strings.builder_len(b^) > 0 {
			append(out, Span{kind = .Text, text = strings.clone(strings.to_string(b^), allocator)})
			strings.builder_reset(b)
		}
	}

	// Code spans are found first and treated as opaque from then on. Markdown
	// says nothing inside a code span is markup, and that has to hold in both
	// directions: `num_predict` inside backticks must not supply the closing
	// underscore for an emphasis run that started outside it.
	Code_Span :: struct {
		open, body_lo, body_hi, close_end: int,
	}
	codes := make([dynamic]Code_Span, context.temp_allocator)
	{
		i := 0
		for i < len(src) {
			if src[i] == '\\' {
				i += 2
				continue
			}
			if src[i] != '`' {
				i += 1
				continue
			}
			ticks := 1
			for i + ticks < len(src) && src[i + ticks] == '`' {
				ticks += 1
			}
			fence := src[i:i + ticks]
			rel := strings.index(src[i + ticks:], fence)
			if rel < 0 {
				i += ticks
				continue
			}
			lo := i + ticks
			hi := lo + rel
			append(&codes, Code_Span{i, lo, hi, hi + ticks})
			i = hi + ticks
		}
	}

	code_at :: proc(codes: []Code_Span, i: int) -> (Code_Span, bool) {
		for c in codes {
			if c.open == i {
				return c, true
			}
		}
		return {}, false
	}
	in_code :: proc(codes: []Code_Span, i: int) -> bool {
		for c in codes {
			if i >= c.open && i < c.close_end {
				return true
			}
		}
		return false
	}

	i := 0
	for i < len(src) {
		c := src[i]

		if cs, is_code := code_at(codes[:], i); is_code {
			flush(&out, &plain, allocator)
			append(
				&out,
				Span {
					kind = .Code,
					text = strings.clone(
						strings.trim_space(src[cs.body_lo:cs.body_hi]),
						allocator,
					),
				},
			)
			i = cs.close_end
			continue
		}

		if c == '\\' && i + 1 < len(src) {
			// An escaped marker is a literal.
			strings.write_byte(&plain, src[i + 1])
			i += 2
			continue
		}

		if c == '~' && i + 1 < len(src) && src[i + 1] == '~' {
			if close := strings.index(src[i + 2:], "~~"); close >= 0 {
				flush(&out, &plain, allocator)
				append(
					&out,
					Span{kind = .Strike, text = strings.clone(src[i + 2:i + 2 + close], allocator)},
				)
				i += 4 + close
				continue
			}
		}

		if c == '*' || c == '_' {
			run := 1
			for i + run < len(src) && src[i + run] == c {
				run += 1
			}
			// `***x***` is both; `**x**` bold; `*x*` italic.
			want := min(run, 3)
			marker := src[i:i + want]

			// CommonMark's flanking rules, in the forms that matter here: a
			// run followed by whitespace cannot open emphasis (so `2 * 3 * 4`
			// is arithmetic), a run preceded by whitespace cannot close it,
			// and an `_` touching a word character on the wrong side is part
			// of the word (so `some_long_name` and `num_predict` survive).
			opens := i + want < len(src) && !md_space(src[i + want])
			if c == '_' && i > 0 && is_wordish(src[i - 1]) {
				opens = false
			}
			if opens {
				at := -1
				search := i + want
				for search < len(src) {
					rel := strings.index(src[search:], marker)
					if rel < 0 {
						break
					}
					pos := search + rel
					ok := pos > i + want && !md_space(src[pos - 1]) && !in_code(codes[:], pos)
					if ok && c == '_' && pos + want < len(src) && is_wordish(src[pos + want]) {
						ok = false
					}
					if ok {
						at = pos
						break
					}
					search = pos + 1
				}
				if at > 0 {
					body := src[i + want:at]
					kind := Span_Kind.Italic
					switch want {
					case 2:
						kind = .Bold
					case 3:
						kind = .Bold_Italic
					}
					flush(&out, &plain, allocator)
					// The body may itself hold code spans, so it is tokenised
					// again and the emphasis is carried onto each piece.
					for inner in md_spans(body, allocator) {
						k := inner.kind == .Code ? Span_Kind.Code : kind
						append(&out, Span{kind = k, text = inner.text, href = inner.href})
					}
					i = at + want
					continue
				}
			}
		}

		if c == '[' {
			if rb := strings.index_byte(src[i:], ']'); rb > 0 {
				if i + rb + 1 < len(src) && src[i + rb + 1] == '(' {
					if rp := strings.index_byte(src[i + rb + 1:], ')'); rp > 0 {
						flush(&out, &plain, allocator)
						label := src[i + 1:i + rb]
						href := src[i + rb + 2:i + rb + 1 + rp]
						append(
							&out,
							Span {
								kind = .Link,
								text = strings.clone(label, allocator),
								href = strings.clone(href, allocator),
							},
						)
						i += rb + rp + 2
						continue
					}
				}
			}
		}

		strings.write_byte(&plain, c)
		i += 1
	}
	flush(&out, &plain, allocator)
	return out[:]
}

@(private = "file")
md_space :: proc(c: u8) -> bool {
	return c == ' ' || c == '\t' || c == '\n' || c == '\r'
}

@(private = "file")
is_wordish :: proc(c: u8) -> bool {
	return(
		(c >= 'a' && c <= 'z') ||
		(c >= 'A' && c <= 'Z') ||
		(c >= '0' && c <= '9') ||
		c == '_' \
	)
}

// md_plain strips markup, for a title or a clipboard copy of the prose.
md_plain :: proc(src: string, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	for blk in md_blocks(src, context.temp_allocator) {
		switch blk.kind {
		case .Code:
			for l in blk.lines {
				strings.write_string(&b, l)
				strings.write_byte(&b, '\n')
			}
		case .Rule:
			strings.write_string(&b, "\n")
		case .Paragraph, .Heading, .Bullet, .Numbered, .Quote:
			for s in md_spans(blk.text, context.temp_allocator) {
				strings.write_string(&b, s.text)
			}
			strings.write_byte(&b, '\n')
		}
	}
	return strings.trim_space(strings.to_string(b))
}

// ---------------------------------------------------------------------------
// Rendering
// ---------------------------------------------------------------------------

// Words. A word is one or more differently-styled fragments that must stay on
// the same line.
@(private = "file")
Frag :: struct {
	kind: Span_Kind,
	text: string,
	href: string,
}

@(private = "file")
words_of :: proc(spans: []Span, allocator := context.temp_allocator) -> [][]Frag {
	words := make([dynamic][]Frag, allocator)
	cur := make([dynamic]Frag, allocator)

	close_word :: proc(words: ^[dynamic][]Frag, cur: ^[dynamic]Frag, allocator: mem.Allocator) {
		if len(cur) > 0 {
			w := make([]Frag, len(cur), allocator)
			copy(w, cur[:])
			append(words, w)
			clear(cur)
		}
	}

	for s in spans {
		if s.kind == .Code {
			// A code span is one unbreakable chip, whatever is inside it.
			close_word(&words, &cur, allocator)
			append(&words, []Frag{{kind = .Code, text = s.text}})
			continue
		}
		start := 0
		for i := 0; i <= len(s.text); i += 1 {
			at_end := i == len(s.text)
			if at_end || s.text[i] == ' ' || s.text[i] == '\n' || s.text[i] == '\t' {
				if i > start {
					append(
						&cur,
						Frag{kind = s.kind, text = s.text[start:i], href = s.href},
					)
				}
				if !at_end {
					close_word(&words, &cur, allocator)
				}
				start = i + 1
			}
		}
	}
	close_word(&words, &cur, allocator)
	return words[:]
}

@(private = "file")
frag_class :: proc(f: Frag) -> string {
	switch f.kind {
	case .Bold:
		return "font-semibold"
	case .Bold_Italic:
		// palmy has no italic face and no `italic` class — Font_Family is
		// Sans or Mono and Font_Weight is the only other axis — so emphasis is
		// carried by weight and letter-spacing instead. Reported, not patched.
		return "font-semibold tracking-wide"
	case .Italic:
		return "font-medium tracking-wide"
	case .Strike:
		return "line-through text-muted-foreground"
	case .Link:
		return "underline text-primary"
	case .Code, .Text:
		return ""
	}
	return ""
}

@(private = "file")
frag_width :: proc(ui: ^p.Ctx, f: Frag, size: f32) -> f32 {
	if f.kind == .Code {
		// The chip: px-1 either side, a 1px border either side, and the mono
		// face one step down from the body size.
		return p.text_width(ui.fonts, f.text, size - 1.5, .Mono, .Regular) + 10
	}
	wt := p.Font_Weight.Regular
	#partial switch f.kind {
	case .Bold, .Bold_Italic:
		wt = .Semibold
	case .Italic:
		wt = .Medium
	}
	tracking: f32 = 0
	if f.kind == .Italic || f.kind == .Bold_Italic {
		tracking = 0.025 * size // tracking-wide
	}
	return p.text_width(ui.fonts, f.text, size, .Sans, wt, tracking)
}

// md_inline lays one inline run out.
//
// palmy measures a `flex-wrap` row against the width it is offered, but a
// bubble that is only width-constrained by `max-w` offers the full width
// during measurement and the real, narrower one during layout — so the row
// wraps onto more lines than it reserved height for, and the lines overlap.
// Rather than fight that, the line breaking is done here, at a width this app
// already knows, and each line is emitted as its own row. Nothing wraps, so
// nothing can disagree about how tall it is.
md_inline :: proc(ui: ^p.Ctx, src: string, size, width: f32, class := "") {
	spans := md_spans(src, context.temp_allocator)
	words := words_of(spans)
	space := p.text_width(ui.fonts, " ", size, .Sans, .Regular)
	avail := max(40, width)

	// Break into lines first, so a line is a slice of the word list.
	Line :: struct {
		lo, hi: int,
	}
	lines := make([dynamic]Line, context.temp_allocator)
	lo := 0
	x: f32 = 0
	for w, i in words {
		ww: f32 = 0
		for f in w {
			ww += frag_width(ui, f, size)
		}
		if i > lo && x + space + ww > avail {
			append(&lines, Line{lo, i})
			lo = i
			x = ww
			continue
		}
		x += (i > lo ? space : 0) + ww
	}
	if lo < len(words) {
		append(&lines, Line{lo, len(words)})
	}

	p.col(ui, "w-full min-w-0 gap-0")
	if class != "" {
		p.apply(ui, class)
	}
	defer p.end(ui)

	for ln, li in lines {
		p.key(ui, fmt.tprintf("ln%d", li))
		p.row(ui, "w-full shrink-0 items-baseline")
		p.style(ui).gap = {space, 0}
		for wi in ln.lo ..< ln.hi {
			w := words[wi]
			if len(w) == 1 {
				md_frag(ui, w[0], size)
				continue
			}
			p.row(ui, "shrink-0 items-baseline")
			p.style(ui).gap = {0, 0}
			for f in w {
				md_frag(ui, f, size)
			}
			p.end(ui)
		}
		p.end(ui)
	}
}

@(private = "file")
md_frag :: proc(ui: ^p.Ctx, f: Frag, size: f32) {
	if f.kind == .Code {
		p.div(ui, "flex-row shrink-0 items-center rounded-md bg-muted px-1 border border-border/60")
		defer p.end(ui)
		p.text(ui, f.text, "font-mono whitespace-nowrap text-foreground")
		st := p.style(ui)
		st.shrink = 0
		st.font_size = size - 1.5
		return
	}
	p.text(ui, f.text, frag_class(f))
	st := p.style(ui)
	st.shrink = 0
	st.font_size = size
}

// expand_tabs turns tabs into four spaces at the next stop.
expand_tabs :: proc(s: string, allocator := context.temp_allocator) -> string {
	if !strings.contains(s, "\t") {
		return s
	}
	b := strings.builder_make(allocator)
	col := 0
	for i in 0 ..< len(s) {
		if s[i] == '\t' {
			n := 4 - col % 4
			for _ in 0 ..< n {
				strings.write_byte(&b, ' ')
			}
			col += n
			continue
		}
		strings.write_byte(&b, s[i])
		col += 1
	}
	return strings.to_string(b)
}

// md_render draws a whole markdown document. `size` is the body text size, so
// the same renderer serves a transcript bubble and a smaller preview.
md_render :: proc(ui: ^p.Ctx, src: string, width: f32, size: f32 = 14) {
	blocks := md_blocks(src, context.temp_allocator)

	p.col(ui, "w-full min-w-0 gap-2")
	defer p.end(ui)

	for blk, bi in blocks {
		p.key(ui, fmt.tprintf("b%d", bi))
		switch blk.kind {
		case .Heading:
			cls := "text-base font-semibold"
			switch blk.level {
			case 1:
				cls = "text-xl font-semibold"
			case 2:
				cls = "text-lg font-semibold"
			case 3:
				cls = "text-base font-semibold"
			case:
				cls = "text-sm font-semibold text-muted-foreground"
			}
			hsize: f32 = 16
			switch blk.level {
			case 1:
				hsize = 20
			case 2:
				hsize = 18
			case 3:
				hsize = 16
			case:
				hsize = 14
			}
			p.col(ui, "w-full pt-1")
			md_inline(ui, blk.text, hsize, width, cls)
			p.end(ui)

		case .Paragraph:
			md_inline(ui, blk.text, size, width)

		case .Bullet, .Numbered:
			p.row(ui, "w-full min-w-0 items-start gap-2")
			p.style(ui).margin[p.LEFT] = f32(blk.level) * 16
			if blk.kind == .Bullet {
				// A dot on the text's first line, sized to the type.
				p.div(ui, "shrink-0 flex-row justify-center")
				p.style(ui).w = p.px(14)
				p.div(ui, "size-1.5 rounded-full bg-muted-foreground")
				p.style(ui).margin[p.TOP] = size * 0.55
				p.end(ui)
				p.end(ui)
			} else {
				p.div(ui, "shrink-0 flex-row justify-end")
				p.style(ui).w = p.px(16)
				p.textf(ui, "text-muted-foreground whitespace-nowrap", "%d.", blk.ordinal)
				p.style(ui).shrink = 0
				p.end(ui)
			}
			p.col(ui, "flex-1 min-w-0")
			md_inline(ui, blk.text, size, width - f32(blk.level) * 16 - 24)
			p.end(ui)
			p.end(ui)

		case .Quote:
			p.row(ui, "w-full min-w-0 items-stretch gap-2.5")
			p.div(ui, "w-0.5 shrink-0 rounded-full bg-border")
			p.end(ui)
			p.col(ui, "flex-1 min-w-0 py-0.5")
			md_inline(ui, blk.text, size, width - 12, "text-muted-foreground")
			p.end(ui)
			p.end(ui)

		case .Code:
			p.col(ui, "w-full min-w-0 rounded-lg border border-border bg-muted/60 overflow-hidden")
			if blk.lang != "" || blk.open {
				p.row(
					ui,
					"w-full items-center gap-2 px-2.5 py-1 border-b border-border bg-muted",
				)
				p.icon(ui, sc.ICON_TERMINAL, "size-3 shrink-0 text-muted-foreground")
				p.text(
					ui,
					blk.lang == "" ? "code" : blk.lang,
					"text-[11] font-medium text-muted-foreground whitespace-nowrap",
				)
				p.style(ui).shrink = 0
				if blk.open {
					p.spacer(ui)
					p.text(ui, "writing…", "text-[11] text-muted-foreground whitespace-nowrap")
					p.style(ui).shrink = 0
				}
				p.end(ui)
			}
			p.col(ui, "w-full min-w-0 px-2.5 py-2 gap-0 overflow-hidden")
			for l, li in blk.lines {
				p.key(ui, fmt.tprintf("l%d", li))
				// No font has a tab glyph, so a tab draws as .notdef. Code
				// out of a model is full of them.
				p.text(
					ui,
					l == "" ? " " : expand_tabs(l),
					"font-mono text-[12.5] leading-[18] whitespace-nowrap text-foreground",
				)
				p.style(ui).shrink = 0
			}
			p.end(ui)
			p.end(ui)

		case .Rule:
			sc.separator(ui, .Horizontal, "my-1")
		}
	}
}
