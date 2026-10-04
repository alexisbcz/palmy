package main

// Markdown for chat messages: the subset Slack and Discord actually render,
// parsed into blocks and inline spans and then drawn with palmy text runs.
//
// Wrapping is why this is a two-stage model. palmy wraps the text inside one
// run, but a paragraph here is many runs with different weights, so it has to
// be broken into lines by hand.
//
// `flex-wrap` is not that mechanism, and this is worth recording: palmy wraps
// such a row's children correctly when it paints them, but measures the row at
// the height of a single line. A three-line paragraph therefore reports one
// line of height and the next message is laid out on top of it. So the words
// are measured here, the line breaks are decided here, and each visual line is
// emitted as its own fixed-height row — which also makes the height exact
// rather than merely correct.
//
// What is NOT here, and why: true italics. palmy's font table is
// `faces[family][weight]` over {Sans, Mono} × {Regular, Medium, Semibold,
// Bold} with no italic slot and no synthetic oblique in the rasterizer, so an
// app cannot reach a slanted face. Emphasis is rendered as a weight and colour
// shift instead, which is visible but is not an italic. See the gap note in
// the report.

import "core:strings"
import p "palmy:."

Block_Kind :: enum u8 {
	Para,
	Heading,
	Code,
	Quote,
	Bullet,
	Number,
	Rule,
}

Block :: struct {
	kind:  Block_Kind,
	text:  string, // inline source, or the body for Code
	lang:  string, // Code only
	level: int,    // heading level, or the list number
}

Span_Style :: enum u8 {
	Plain,
	Strong,
	Emph,
	Strong_Emph,
	Code,
	Link,
	Strike,
}

Span :: struct {
	text:  string,
	style: Span_Style,
	href:  string,
}

// ---------------------------------------------------------------------------
// Blocks
// ---------------------------------------------------------------------------

md_blocks :: proc(src: string, allocator := context.temp_allocator) -> []Block {
	out := make([dynamic]Block, allocator)
	lines := strings.split(src, "\n", allocator)

	i := 0
	for i < len(lines) {
		raw := lines[i]
		line := strings.trim_right_space(raw)
		trimmed := strings.trim_space(line)

		// Fenced code. An unterminated fence runs to the end of the message,
		// which is what every chat client does with a half-typed block.
		if strings.has_prefix(trimmed, "```") {
			lang := strings.trim_space(trimmed[3:])
			body := make([dynamic]string, allocator)
			i += 1
			for i < len(lines) {
				if strings.has_prefix(strings.trim_space(lines[i]), "```") {
					i += 1
					break
				}
				append(&body, lines[i])
				i += 1
			}
			append(
				&out,
				Block {
					kind = .Code,
					text = strings.join(body[:], "\n", allocator),
					lang = lang,
				},
			)
			continue
		}

		if trimmed == "" {
			i += 1
			continue
		}

		if trimmed == "---" || trimmed == "***" || trimmed == "___" {
			append(&out, Block{kind = .Rule})
			i += 1
			continue
		}

		// Headings: one block per `#` line, up to three levels.
		if strings.has_prefix(trimmed, "#") {
			n := 0
			for n < len(trimmed) && trimmed[n] == '#' {
				n += 1
			}
			if n <= 3 && n < len(trimmed) && trimmed[n] == ' ' {
				append(
					&out,
					Block {
						kind = .Heading,
						text = strings.trim_space(trimmed[n:]),
						level = n,
					},
				)
				i += 1
				continue
			}
		}

		// Blockquote: consecutive `>` lines fold into one block, so a quoted
		// paragraph wraps as a paragraph.
		if strings.has_prefix(trimmed, ">") {
			parts := make([dynamic]string, allocator)
			for i < len(lines) {
				t := strings.trim_space(lines[i])
				if !strings.has_prefix(t, ">") {
					break
				}
				append(&parts, strings.trim_space(t[1:]))
				i += 1
			}
			append(&out, Block{kind = .Quote, text = strings.join(parts[:], " ", allocator)})
			continue
		}

		if strings.has_prefix(trimmed, "- ") ||
		   strings.has_prefix(trimmed, "* ") ||
		   strings.has_prefix(trimmed, "+ ") {
			append(&out, Block{kind = .Bullet, text = strings.trim_space(trimmed[2:])})
			i += 1
			continue
		}

		if n, rest, ok := ordered_marker(trimmed); ok {
			append(&out, Block{kind = .Number, text = rest, level = n})
			i += 1
			continue
		}

		// A paragraph soaks up following plain lines, the way a markdown
		// paragraph does, so a soft-wrapped message reads as one paragraph.
		parts := make([dynamic]string, allocator)
		for i < len(lines) {
			t := strings.trim_space(lines[i])
			if t == "" || block_starts(t) {
				break
			}
			append(&parts, t)
			i += 1
		}
		append(&out, Block{kind = .Para, text = strings.join(parts[:], " ", allocator)})
	}

	if len(out) == 0 {
		append(&out, Block{kind = .Para, text = ""})
	}
	return out[:]
}

@(private = "file")
block_starts :: proc(t: string) -> bool {
	if strings.has_prefix(t, "```") ||
	   strings.has_prefix(t, ">") ||
	   strings.has_prefix(t, "- ") ||
	   strings.has_prefix(t, "* ") ||
	   strings.has_prefix(t, "+ ") ||
	   strings.has_prefix(t, "#") {
		return true
	}
	if t == "---" || t == "***" || t == "___" {
		return true
	}
	_, _, ok := ordered_marker(t)
	return ok
}

@(private = "file")
ordered_marker :: proc(t: string) -> (n: int, rest: string, ok: bool) {
	i := 0
	for i < len(t) && t[i] >= '0' && t[i] <= '9' {
		n = n * 10 + int(t[i] - '0')
		i += 1
	}
	if i == 0 || i > 3 || i + 1 >= len(t) {
		return 0, "", false
	}
	if (t[i] == '.' || t[i] == ')') && t[i + 1] == ' ' {
		return n, strings.trim_space(t[i + 2:]), true
	}
	return 0, "", false
}

// ---------------------------------------------------------------------------
// Inline spans
// ---------------------------------------------------------------------------

md_spans :: proc(src: string, allocator := context.temp_allocator) -> []Span {
	out := make([dynamic]Span, allocator)
	plain := strings.builder_make(allocator)

	flush :: proc(out: ^[dynamic]Span, b: ^strings.Builder) {
		if strings.builder_len(b^) > 0 {
			append(out, Span{text = strings.to_string(b^), style = .Plain})
			b^ = strings.builder_make(b.buf.allocator)
		}
	}

	i := 0
	for i < len(src) {
		c := src[i]

		// `code` wins over everything else, as it does in CommonMark.
		if c == '`' {
			if end := strings.index_byte(src[i + 1:], '`'); end >= 0 {
				flush(&out, &plain)
				append(&out, Span{text = src[i + 1:i + 1 + end], style = .Code})
				i += end + 2
				continue
			}
		}

		if c == '*' || c == '_' {
			// ***both*** / **strong** / *emph*
			run := 1
			for i + run < len(src) && src[i + run] == c {
				run += 1
			}
			run = min(run, 3)
			marker := src[i:i + run]
			if close := strings.index(src[i + run:], marker); close > 0 {
				style := Span_Style.Emph
				switch run {
				case 2:
					style = .Strong
				case 3:
					style = .Strong_Emph
				}
				flush(&out, &plain)
				append(&out, Span{text = src[i + run:i + run + close], style = style})
				i += run + close + run
				continue
			}
		}

		if c == '~' && i + 1 < len(src) && src[i + 1] == '~' {
			if close := strings.index(src[i + 2:], "~~"); close > 0 {
				flush(&out, &plain)
				append(&out, Span{text = src[i + 2:i + 2 + close], style = .Strike})
				i += close + 4
				continue
			}
		}

		// [label](href)
		if c == '[' {
			if rb := strings.index_byte(src[i:], ']'); rb > 0 && i + rb + 1 < len(src) && src[i + rb + 1] == '(' {
				if rp := strings.index_byte(src[i + rb + 2:], ')'); rp >= 0 {
					flush(&out, &plain)
					append(
						&out,
						Span {
							text = src[i + 1:i + rb],
							style = .Link,
							href = src[i + rb + 2:i + rb + 2 + rp],
						},
					)
					i += rb + 2 + rp + 1
					continue
				}
			}
		}

		// Bare URLs, so a pasted link is still a link.
		if c == 'h' && (strings.has_prefix(src[i:], "http://") || strings.has_prefix(src[i:], "https://")) {
			end := i
			for end < len(src) && !is_url_end(src[end]) {
				end += 1
			}
			// Trailing punctuation belongs to the sentence, not the URL.
			for end > i && (src[end - 1] == '.' || src[end - 1] == ',' || src[end - 1] == ')') {
				end -= 1
			}
			flush(&out, &plain)
			append(&out, Span{text = src[i:end], style = .Link, href = src[i:end]})
			i = end
			continue
		}

		strings.write_byte(&plain, c)
		i += 1
	}
	flush(&out, &plain)
	return out[:]
}

@(private = "file")
is_url_end :: proc(c: u8) -> bool {
	return c == ' ' || c == '\t' || c == '\n' || c == '<' || c == '>' || c == '"' || c == '`'
}

// ---------------------------------------------------------------------------
// Drawing
// ---------------------------------------------------------------------------

@(private = "file")
span_class :: proc(s: Span_Style, base: string) -> string {
	switch s {
	case .Plain:
		return base
	case .Strong:
		return "font-semibold text-foreground"
	case .Emph:
		// No italic face exists here; emphasis is a weight shift. See the
		// note at the top of this file.
		return "font-medium text-foreground"
	case .Strong_Emph:
		return "font-bold text-foreground"
	case .Strike:
		return "line-through text-muted-foreground"
	case .Code:
		return "font-mono"
	case .Link:
		return "underline text-primary"
	}
	return base
}

@(private = "file")
span_weight :: proc(s: Span_Style) -> p.Font_Weight {
	switch s {
	case .Strong:
		return .Semibold
	case .Emph:
		return .Medium
	case .Strong_Emph:
		return .Bold
	case .Plain, .Strike, .Link, .Code:
		return .Regular
	}
	return .Regular
}

// Atom is one indivisible piece of a line: a word with the space that followed
// it, or a whole inline-code box.
@(private = "file")
Atom :: struct {
	text:  string,
	style: Span_Style,
	adv:   f32, // width including the trailing space, for advancing
	fit:   f32, // width without it, for deciding whether it fits
	gap:   f32, // the spacer drawn after an inline-code box
}

CODE_PAD :: 4 // `px-1` on the inline-code box
CODE_GAP :: 4 // the hair of space after it
CODE_SIZE :: 12.5

@(private = "file")
atoms_of :: proc(ui: ^p.Ctx, src: string, size: f32, base_weight: p.Font_Weight) -> []Atom {
	out := make([dynamic]Atom, context.temp_allocator)
	spans := md_spans(src, context.temp_allocator)

	for sp, si in spans {
		if sp.style == .Code {
			tw := p.text_width(ui.fonts, sp.text, CODE_SIZE, .Mono, .Regular)
			box := tw + CODE_PAD * 2
			// A code box carries a hair of space after it — unless what
			// follows is punctuation, where a gap reads as a typo.
			gap: f32 = CODE_GAP
			if si + 1 < len(spans) && len(spans[si + 1].text) > 0 && is_punct(spans[si + 1].text[0]) {
				gap = 0
			}
			append(
				&out,
				Atom{text = sp.text, style = .Code, fit = box, adv = box + gap, gap = gap},
			)
			continue
		}
		wt := sp.style == .Plain ? base_weight : span_weight(sp.style)
		for wd in split_keep_spaces(sp.text, context.temp_allocator) {
			if wd == "" {
				continue
			}
			bare := strings.trim_right_space(wd)
			if bare == "" {
				// A run of pure whitespace between two styled spans: it
				// belongs to the previous word, text and width alike.
				if len(out) > 0 {
					last := &out[len(out) - 1]
					if last.style != .Code {
						last.text = strings.concatenate(
							{last.text, wd},
							context.temp_allocator,
						)
					}
					last.adv += p.text_width(ui.fonts, wd, size, .Sans, wt)
				}
				continue
			}
			append(
				&out,
				Atom {
					text = wd,
					style = sp.style,
					fit = p.text_width(ui.fonts, bare, size, .Sans, wt),
					adv = p.text_width(ui.fonts, wd, size, .Sans, wt),
				},
			)
		}
	}
	return out[:]
}

@(private = "file")
is_punct :: proc(c: u8) -> bool {
	switch c {
	case ',', '.', ';', ':', '!', '?', ')', ']', '}':
		return true
	}
	return false
}

// line_height matches shadcn's type scale: 14px text sits on a 20px line,
// 16px on 24px.
@(private = "file")
line_height :: proc(size: f32) -> f32 {
	return size <= 14.5 ? 20 : 24
}

// md_inline draws one run of inline markdown, broken into lines at `avail`
// pixels wide. Every line is its own row of a known height, so the block it
// belongs to measures at its real height.
md_inline :: proc(
	ui: ^p.Ctx,
	src: string,
	base := "text-sm text-foreground",
	avail: f32 = 560,
	size: f32 = 14,
	weight := p.Font_Weight.Regular,
) {
	atoms := atoms_of(ui, src, size, weight)
	lh := line_height(size)
	width := max(avail, 60)

	p.col(ui, "w-full min-w-0 gap-0")
	defer p.end(ui)

	if len(atoms) == 0 {
		p.div(ui, "w-full shrink-0")
		p.style(ui).h = p.px(lh)
		p.end(ui)
		return
	}

	start := 0
	x: f32 = 0
	emit :: proc(ui: ^p.Ctx, atoms: []Atom, from, to: int, base: string, lh: f32) {
		p.row(ui, "w-full min-w-0 shrink-0 items-center")
		p.style(ui).h = p.px(lh)
		defer p.end(ui)
		for i in from ..< to {
			a := atoms[i]
			if a.style == .Code {
				p.div(ui, "flex-row shrink-0 items-center rounded-[5] bg-muted px-1")
				p.style(ui).h = p.px(lh - 2)
				p.text(ui, a.text, "font-mono text-[12.5] text-foreground whitespace-nowrap")
				p.style(ui).shrink = 0
				p.end(ui)
				if a.gap > 0 {
					p.div(ui, "shrink-0")
					p.style(ui).w = p.px(a.gap)
					p.end(ui)
				}
				continue
			}
			p.text(ui, a.text, p.concat(ui, span_class(a.style, base), " whitespace-nowrap"))
			p.style(ui).shrink = 0
		}
	}

	for i in 0 ..< len(atoms) {
		if i > start && x + atoms[i].fit > width {
			emit(ui, atoms, start, i, base, lh)
			start = i
			x = 0
		}
		x += atoms[i].adv
	}
	emit(ui, atoms, start, len(atoms), base, lh)
}

// split_keep_spaces cuts a run into words with each word carrying the space
// that followed it, so the gaps in a wrapped line are the font's real space
// width rather than a guessed `gap-*`.
split_keep_spaces :: proc(s: string, allocator := context.temp_allocator) -> []string {
	out := make([dynamic]string, allocator)
	i := 0
	for i < len(s) {
		j := i
		for j < len(s) && s[j] != ' ' {
			j += 1
		}
		for j < len(s) && s[j] == ' ' {
			j += 1
		}
		append(&out, s[i:j])
		i = j
	}
	return out[:]
}

// md_render draws a whole message body into `avail` pixels of width.
md_render :: proc(ui: ^p.Ctx, src: string, base := "text-sm text-foreground", avail: f32 = 560) {
	blocks := md_blocks(src, context.temp_allocator)

	p.col(ui, "w-full min-w-0 gap-1.5")
	defer p.end(ui)

	for b in blocks {
		switch b.kind {
		case .Para:
			md_inline(ui, b.text, base, avail)

		case .Heading:
			size: f32 = b.level == 1 ? 16 : 14
			md_inline(
				ui,
				b.text,
				b.level == 1 \
				? "text-base font-semibold text-foreground" \
				: "text-sm font-semibold text-foreground",
				avail,
				size,
				.Semibold,
			)

		case .Rule:
			p.div(ui, "w-full h-px my-1 bg-border")
			p.end(ui)

		case .Code:
			p.col(ui, "w-full min-w-0 rounded-md border border-border bg-muted/60 overflow-hidden")
			if b.lang != "" {
				p.row(ui, "w-full shrink-0 items-center gap-1.5 px-2.5 pt-1.5")
				p.icon(ui, IC_CODE, "size-3 shrink-0 text-muted-foreground")
				p.text(ui, b.lang, "text-[10.5] uppercase tracking-wide text-muted-foreground whitespace-nowrap")
				p.style(ui).shrink = 0
				p.end(ui)
			}
			p.col(ui, "w-full min-w-0 px-2.5 py-2 gap-0")
			for line in strings.split(b.text, "\n", context.temp_allocator) {
				p.div(ui, "w-full shrink-0 flex-row items-center")
				p.style(ui).h = p.px(18)
				p.text(ui, line == "" ? " " : line, "font-mono text-[12.5] text-foreground whitespace-nowrap")
				p.style(ui).shrink = 0
				p.end(ui)
			}
			p.end(ui)
			p.end(ui)

		case .Quote:
			p.row(ui, "w-full min-w-0 items-stretch gap-2.5")
			p.div(ui, "w-[3] shrink-0 rounded-full bg-border")
			p.end(ui)
			p.col(ui, "flex-1 min-w-0 py-px")
			md_inline(ui, b.text, "text-sm text-muted-foreground", avail - 13)
			p.end(ui)
			p.end(ui)

		case .Bullet:
			p.row(ui, "w-full min-w-0 items-start gap-2")
			p.div(ui, "w-1.5 h-1.5 mt-[7.5] shrink-0 rounded-full bg-muted-foreground")
			p.end(ui)
			p.col(ui, "flex-1 min-w-0")
			md_inline(ui, b.text, base, avail - 14)
			p.end(ui)
			p.end(ui)

		case .Number:
			p.row(ui, "w-full min-w-0 items-start gap-2")
			p.div(ui, "w-[16] shrink-0 flex-row justify-end")
			p.style(ui).h = p.px(20)
			p.textf(ui, "text-sm text-muted-foreground whitespace-nowrap", "%d.", b.level)
			p.style(ui).shrink = 0
			p.end(ui)
			p.col(ui, "flex-1 min-w-0")
			md_inline(ui, b.text, base, avail - 24)
			p.end(ui)
			p.end(ui)
		}
	}
}

// md_preview flattens a message to one line, for a reply stub, a search hit or
// a sidebar summary.
md_preview :: proc(src: string, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	for blk, i in md_blocks(src, allocator) {
		if i > 0 {
			strings.write_string(&b, " · ")
		}
		if blk.kind == .Code {
			strings.write_string(&b, "code")
			continue
		}
		for sp in md_spans(blk.text, allocator) {
			strings.write_string(&b, sp.text)
		}
	}
	out := strings.to_string(b)
	// Collapse the newlines a code block may have left behind.
	return strings.replace_all(out, "\n", " ", allocator) or_else out
}
