package prose

// Markdown scoping, by masking rather than by extraction.
//
// A linter that flags your code samples gets switched off inside a minute, so
// the first job is knowing which bytes are prose. The obvious way is to pull
// the prose out into a new string and keep a map back to the original offsets.
// This does the opposite: it copies the document and overwrites every byte
// that is not prose with a space.
//
// That one decision removes a whole class of bug. Offsets in the masked text
// *are* offsets in the document — no mapping table, no off-by-one when a
// region is dropped, and a span reported by a rule needs no translation before
// it can be underlined on screen. Word boundaries still work, because a run of
// spaces separates words exactly as the original punctuation did. Sentence
// segmentation gets it right for free, because a full stop inside a URL is
// masked and so cannot end a sentence.
//
// What gets masked:
//
//   front matter      the whole block, including the fences (see note below)
//   fenced code       ``` or ~~~ fences and everything between them
//   indented code     four spaces at the start of a block
//   inline code       `x`, ``x``, and the backticks
//   link targets      the `(...)` of [text](target), and <autolinks>
//   bare URLs         http://, https://, ftp://, mailto:, www.
//   HTML comments     <!-- ... -->, across lines
//   HTML tags         <div>, </div>, and attributes — the text between stays
//   markers           #, >, -, *, 1., |, and emphasis runs
//
// Vale lints the *values* inside YAML front matter. This masks the whole block
// instead, which is a deliberate divergence: a note's front matter is metadata
// the writer is not being graded on, and "title: Draft" firing a hedging rule
// is noise. `Opts.lint_front_matter` turns Vale's behaviour back on, and the
// oracle comparison sets it so the two engines are measured on the same text.

import "core:strings"

Scope_Kind :: enum {
	None, // masked out
	Paragraph,
	Heading,
	Blockquote,
	List,
	Table_Cell,
	Front_Matter,
}

// Block is one run of lines with a single scope. `from`/`to` are byte offsets
// into the document, so a block of the masked text and a block of the source
// are the same range.
Block :: struct {
	kind:  Scope_Kind,
	level: int, // heading depth, 1..6; 0 otherwise
	from:  int,
	to:    int,
}

Masked :: struct {
	text:   string, // same length as the source, non-prose blanked
	blocks: [dynamic]Block,
}

mask_destroy :: proc(m: ^Masked) {
	delete(m.text)
	delete(m.blocks)
	m^ = {}
}

@(private = "file")
blank :: proc(buf: []u8, from, to: int) {
	for i in max(0, from) ..< min(to, len(buf)) {
		if buf[i] != '\n' {
			buf[i] = ' '
		}
	}
}

@(private = "file")
is_url_start :: proc(s: string, i: int) -> int {
	for pre in ([?]string{"https://", "http://", "ftp://", "mailto:", "www."}) {
		if strings.has_prefix(s[i:], pre) {
			// Run to the first whitespace or a closing bracket, then trim the
			// trailing punctuation a sentence would have put there.
			j := i
			for j < len(s) && s[j] != ' ' && s[j] != '\t' && s[j] != '\n' && s[j] != ')' && s[j] != '>' && s[j] != ']' {
				j += 1
			}
			for j > i && strings.index_byte(".,;:!?\"'", s[j - 1]) >= 0 {
				j -= 1
			}
			return j
		}
	}
	return -1
}

// mask_inline blanks the inline constructs on one already-isolated line range.
@(private = "file")
mask_inline :: proc(buf: []u8, from, to: int) {
	s := string(buf[:])
	i := from
	for i < to {
		c := s[i]

		// Inline code: one or more backticks, closed by the same run length.
		if c == '`' {
			n := 0
			for i + n < to && s[i + n] == '`' {
				n += 1
			}
			j := i + n
			for j < to {
				if s[j] == '`' {
					m := 0
					for j + m < to && s[j + m] == '`' {
						m += 1
					}
					if m == n {
						blank(buf, i, j + m)
						i = j + m
						break
					}
					j += m
					continue
				}
				j += 1
			}
			if j >= to {
				// Unclosed: the backticks are literal text, so only they go.
				blank(buf, i, i + n)
				i += n
			}
			continue
		}

		// HTML comment, which may already have been handled across lines.
		if c == '<' && strings.has_prefix(s[i:min(i + 4, to)], "<!--") {
			if e := strings.index(s[i:to], "-->"); e >= 0 {
				blank(buf, i, i + e + 3)
				i += e + 3
				continue
			}
		}

		// An autolink or an HTML tag: the angle brackets and what is inside.
		if c == '<' {
			j := i + 1
			for j < to && s[j] != '>' && s[j] != ' ' && s[j] != '\n' {
				j += 1
			}
			if j < to && s[j] == '>' {
				inner := s[i + 1:j]
				if is_url_start(inner, 0) == len(inner) || looks_like_tag(inner) {
					blank(buf, i, j + 1)
					i = j + 1
					continue
				}
			}
			// A tag with attributes: `<div class="x">`.
			if j < to && s[j] == ' ' {
				if e := strings.index_byte(s[i:to], '>'); e > 0 && looks_like_tag(s[i + 1:i + e]) {
					blank(buf, i, i + e + 1)
					i += e + 1
					continue
				}
			}
		}

		// An image or link: `![alt](target)` / `[text](target)`. The label is
		// prose; the target is not. The brackets themselves go, so the label
		// keeps its own offsets.
		if c == '[' {
			if close := strings.index_byte(s[i:to], ']'); close > 0 {
				end := i + close
				if end + 1 < to && s[end + 1] == '(' {
					depth := 0
					j := end + 1
					for j < to {
						if s[j] == '(' {
							depth += 1
						} else if s[j] == ')' {
							depth -= 1
							if depth == 0 {
								break
							}
						}
						j += 1
					}
					if j < to {
						blank(buf, i, i + 1) // [
						blank(buf, end, j + 1) // ](target)
						if i > from && s[i - 1] == '!' {
							blank(buf, i - 1, i)
						}
						i += 1
						continue
					}
				}
				// A reference link `[text][ref]` or a bare `[text]`.
				blank(buf, i, i + 1)
				blank(buf, end, end + 1)
				if end + 1 < to && s[end + 1] == '[' {
					if r := strings.index_byte(s[end + 1:to], ']'); r > 0 {
						blank(buf, end + 1, end + r + 2)
					}
				}
				i += 1
				continue
			}
		}

		// A bare URL. The first-byte test matters: `is_url_start` compares
		// five prefixes, and calling it on every byte of the document was
		// most of the cost of masking a long note.
		if c == 'h' || c == 'f' || c == 'm' || c == 'w' {
			if e := is_url_start(s, i); e > i {
				blank(buf, i, e)
				i = e
				continue
			}
		}

		// Emphasis and strikethrough runs. The marks are not words, and
		// leaving them in makes `**very**` miss a `\bvery\b` rule.
		if c == '*' || c == '_' || c == '~' {
			n := 0
			for i + n < to && s[i + n] == c {
				n += 1
			}
			// `snake_case` is far more common than _emphasis_ mid-word.
			word_before := i > from && is_word_byte(s[i - 1])
			word_after := i + n < to && is_word_byte(s[i + n])
			if c == '_' && word_before && word_after {
				i += n
				continue
			}
			blank(buf, i, i + n)
			i += n
			continue
		}

		i += 1
	}
}

@(private = "file")
looks_like_tag :: proc(inner: string) -> bool {
	if inner == "" {
		return false
	}
	j := 0
	if inner[0] == '/' {
		j = 1
	}
	if j >= len(inner) {
		return false
	}
	c := inner[j] | 32
	if c < 'a' || c > 'z' {
		return false
	}
	for k in j ..< len(inner) {
		ch := inner[k]
		if ch == ' ' || ch == '/' {
			return true
		}
		lc := ch | 32
		if !(lc >= 'a' && lc <= 'z') && !(ch >= '0' && ch <= '9') && ch != '-' {
			return false
		}
	}
	return true
}

is_word_byte :: proc(c: u8) -> bool {
	return c == '_' || (c | 32 >= 'a' && c | 32 <= 'z') || (c >= '0' && c <= '9')
}

// ---------------------------------------------------------------------------

// mask walks the document once, line by line, blanking everything that is not
// prose and recording a block per run of lines that share a scope.
mask :: proc(src: string, lint_front_matter := false, allocator := context.allocator) -> Masked {
	buf := make([]u8, len(src), allocator)
	copy(buf, src)
	out := Masked {
		blocks = make([dynamic]Block, 0, 32, allocator),
	}

	// Line offsets, once.
	starts := make([dynamic]int, 0, 64, context.temp_allocator)
	append(&starts, 0)
	for i in 0 ..< len(src) {
		if src[i] == '\n' {
			append(&starts, i + 1)
		}
	}

	line_at :: proc(src: string, starts: []int, i: int) -> (from, to: int) {
		from = starts[i]
		to = i + 1 < len(starts) ? starts[i + 1] - 1 : len(src)
		return
	}

	fence := ""
	in_front := false
	in_comment := false
	prev_blank := true
	cur := Block {
		kind = .None,
		from = -1,
	}

	flush :: proc(out: ^Masked, cur: ^Block, at: int) {
		if cur.from >= 0 && cur.to > cur.from {
			append(&out.blocks, cur^)
		}
		cur^ = Block {
			kind = .None,
			from = -1,
		}
	}

	// `fresh` means this line opened a new unit of its own — a list item with
	// its own marker, a heading, a table cell. Vale scopes each of those
	// separately, and so must this: a list of five items is five scopes, not
	// one, which is why a sentence-length rule fires per item.
	open :: proc(out: ^Masked, cur: ^Block, kind: Scope_Kind, level, from, to: int, fresh := false) {
		joinable := !fresh && (kind == .Paragraph || kind == .Blockquote || kind == .List)
		if cur.from >= 0 && cur.kind == kind && cur.level == level && joinable {
			cur.to = to
			return
		}
		flush(out, cur, from)
		cur^ = Block {
			kind  = kind,
			level = level,
			from  = from,
			to    = to,
		}
		if !joinable {
			flush(out, cur, to)
		}
	}

	for li in 0 ..< len(starts) {
		lo, hi := line_at(src, starts[:], li)
		line := src[lo:hi]
		trimmed := strings.trim_space(line)

		// --- front matter ------------------------------------------------
		if li == 0 && (trimmed == "---" || trimmed == "+++") {
			in_front = true
			if !lint_front_matter {
				blank(buf, lo, hi)
			}
			flush(&out, &cur, lo)
			continue
		}
		if in_front {
			if trimmed == "---" || trimmed == "+++" || trimmed == "..." {
				in_front = false
				if !lint_front_matter {
					blank(buf, lo, hi)
				}
				continue
			}
			if lint_front_matter {
				// Vale lints the value half of `key: value`.
				if c := strings.index_byte(line, ':'); c >= 0 {
					blank(buf, lo, lo + c + 1)
					mask_inline(buf, lo + c + 1, hi)
					open(&out, &cur, .Front_Matter, 0, lo, hi)
				} else {
					blank(buf, lo, hi)
				}
			} else {
				blank(buf, lo, hi)
			}
			continue
		}

		// --- an HTML comment running across lines ------------------------
		if in_comment {
			if e := strings.index(line, "-->"); e >= 0 {
				in_comment = false
				blank(buf, lo, lo + e + 3)
				// The rest of the line is ordinary text; fall through.
				line = src[lo + e + 3:hi]
				trimmed = strings.trim_space(line)
				if trimmed == "" {
					prev_blank = true
					flush(&out, &cur, lo)
					continue
				}
			} else {
				blank(buf, lo, hi)
				continue
			}
		}
		if s := strings.index(line, "<!--"); s >= 0 && !strings.contains(line[s:], "-->") {
			in_comment = true
			blank(buf, lo + s, hi)
			if strings.trim_space(line[:s]) == "" {
				flush(&out, &cur, lo)
				continue
			}
			hi = lo + s
			line = src[lo:hi]
			trimmed = strings.trim_space(line)
		}

		// --- fenced code -------------------------------------------------
		if fence != "" {
			blank(buf, lo, hi)
			if strings.has_prefix(trimmed, fence) {
				fence = ""
			}
			flush(&out, &cur, lo)
			prev_blank = false
			continue
		}
		if strings.has_prefix(trimmed, "```") || strings.has_prefix(trimmed, "~~~") {
			fence = trimmed[:3]
			blank(buf, lo, hi)
			flush(&out, &cur, lo)
			prev_blank = false
			continue
		}

		// --- blank line --------------------------------------------------
		if trimmed == "" {
			prev_blank = true
			flush(&out, &cur, lo)
			continue
		}

		// --- an indented code block --------------------------------------
		// Only when it opens a block: four spaces inside a list is a nested
		// item, not code.
		if prev_blank && len(line) >= 4 && line[:4] == "    " {
			blank(buf, lo, hi)
			flush(&out, &cur, lo)
			prev_blank = false
			continue
		}
		if prev_blank && len(line) >= 1 && line[0] == '\t' {
			blank(buf, lo, hi)
			flush(&out, &cur, lo)
			prev_blank = false
			continue
		}
		prev_blank = false

		// --- a horizontal rule -------------------------------------------
		if is_rule_line(trimmed) {
			blank(buf, lo, hi)
			flush(&out, &cur, lo)
			continue
		}

		// --- block markers -----------------------------------------------
		i := lo
		for i < hi && (src[i] == ' ' || src[i] == '\t') {
			i += 1
		}
		kind := Scope_Kind.Paragraph
		level := 0
		fresh := false
		// An indented line under a list item is that item's continuation,
		// not a new paragraph.
		if cur.from >= 0 && cur.kind == .List && i > lo {
			kind = .List
		}

		switch {
		case src[i] == '#':
			h := 0
			for i + h < hi && src[i + h] == '#' {
				h += 1
			}
			if h <= 6 && (i + h >= hi || src[i + h] == ' ') {
				kind = .Heading
				level = h
				fresh = true
				blank(buf, lo, i + h)
				i += h
				// A closing run of hashes is not prose either.
				e := hi
				for e > i && src[e - 1] == ' ' {
					e -= 1
				}
				t := e
				for t > i && src[t - 1] == '#' {
					t -= 1
				}
				if t < e && t > i && src[t - 1] == ' ' {
					blank(buf, t, e)
				}
			}
		case src[i] == '>':
			kind = .Blockquote
			j := i
			for j < hi && (src[j] == '>' || src[j] == ' ') {
				j += 1
			}
			blank(buf, lo, j)
			i = j
		case src[i] == '|':
			// A separator row (`| --- |`) has no prose at all.
			if is_table_sep(trimmed) {
				blank(buf, lo, hi)
				flush(&out, &cur, lo)
				continue
			}
			// Each cell is its own scope, as it is in Vale. Blank the pipes
			// and emit one block per non-empty cell.
			flush(&out, &cur, lo)
			cell := -1
			for j in lo ..= hi {
				if j == hi || src[j] == '|' {
					if cell >= 0 {
						a, b := cell, j
						for a < b && (src[a] == ' ' || src[a] == '\t') {
							a += 1
						}
						for b > a && (src[b - 1] == ' ' || src[b - 1] == '\t') {
							b -= 1
						}
						if b > a {
							mask_inline(buf, a, b)
							append(&out.blocks, Block{kind = .Table_Cell, from = a, to = b})
						}
					}
					if j < hi {
						blank(buf, j, j + 1)
						cell = j + 1
					}
				}
			}
			continue
		case (src[i] == '-' || src[i] == '*' || src[i] == '+') && i + 1 < hi && src[i + 1] == ' ':
			kind = .List
			fresh = true
			j := i + 2
			// A task box is a marker, not prose.
			if j + 2 < hi && src[j] == '[' && src[j + 2] == ']' {
				j += 3
				for j < hi && src[j] == ' ' {
					j += 1
				}
			}
			blank(buf, lo, j)
			i = j
		case src[i] >= '0' && src[i] <= '9':
			d := 0
			for i + d < hi && src[i + d] >= '0' && src[i + d] <= '9' {
				d += 1
			}
			if i + d + 1 < hi && (src[i + d] == '.' || src[i + d] == ')') && src[i + d + 1] == ' ' {
				kind = .List
				fresh = true
				blank(buf, lo, i + d + 2)
				i += d + 2
			}
		}

		mask_inline(buf, i, hi)
		open(&out, &cur, kind, level, i, hi, fresh)
	}
	flush(&out, &cur, len(src))

	out.text = string(buf)
	return out
}

@(private = "file")
is_rule_line :: proc(t: string) -> bool {
	if len(t) < 3 {
		return false
	}
	c := t[0]
	if c != '-' && c != '*' && c != '_' {
		return false
	}
	n := 0
	for i in 0 ..< len(t) {
		if t[i] == c {
			n += 1
		} else if t[i] != ' ' {
			return false
		}
	}
	return n >= 3
}

@(private = "file")
is_table_sep :: proc(t: string) -> bool {
	seen := false
	for i in 0 ..< len(t) {
		switch t[i] {
		case '-', ':':
			seen = true
		case '|', ' ':
		case:
			return false
		}
	}
	return seen
}

// block_at finds the block a byte offset belongs to, or nil.
block_at :: proc(m: ^Masked, off: int) -> ^Block {
	for &b in m.blocks {
		if off >= b.from && off < b.to {
			return &b
		}
	}
	return nil
}
