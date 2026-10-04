// The tokeniser.
//
// This is a real scanner, not a keyword-colouring pass: the line is walked
// character by character and every token is produced by the rule that owns it,
// so `"// not a comment"` stays a string, `0x_ff_u8` is one number, `'\''` is
// one rune literal, and Odin's `/* /* */ */` nest closes at the right place
// while C's `/* /* */` closes at the first terminator, because C's do not nest.
//
// State that crosses a line boundary — the block comment depth, whether a
// backtick raw string is open, whether a Markdown fence is open — is returned
// so the caller can cache the state entering each line and rehighlight only
// what it is about to draw.
//
// The scanner is one procedure driven by a `Syntax` (lang.odin). JSON and
// Markdown get their own, because neither is a C-family grammar: JSON's
// interesting distinction is key versus value, and Markdown's grammar is
// decided by the first character of the line.
package main

import "core:strings"

Lex_State :: struct {
	depth: u16, // nested /* */ depth
	raw:   bool, // inside a `...` raw string
	fence: bool, // inside a ``` Markdown code fence
}

Tok :: enum u8 {
	Plain,
	Keyword,
	Type,
	Builtin,
	Number,
	Str,
	Rune_Lit,
	Comment,
	Directive,
	Punct,
	Call,
	Decl,
	// The kinds the non-C-family languages need.
	Key, // a JSON object key
	Heading, // a Markdown heading
	Emph, // *italic*
	Strong, // **bold**
	Code, // `inline code` and fenced blocks
	Link, // [text](url)
	Marker, // a list bullet, a blockquote, a rule
}

Token :: struct {
	kind: Tok,
	from: int,
	to:   int,
}

@(private = "file")
in_set :: proc(set: []string, word: string) -> bool {
	// The tables are sorted, so this is a binary search. `--selftest` asserts
	// that they really are sorted, because a word out of order would simply
	// never match and nothing would look wrong.
	lo, hi := 0, len(set)
	for lo < hi {
		mid := (lo + hi) / 2
		switch strings.compare(set[mid], word) {
		case 0:
			return true
		case -1:
			lo = mid + 1
		case:
			hi = mid
		}
	}
	return false
}

@(private = "file")
is_ident_start :: proc(c: u8) -> bool {
	return c == '_' || c >= 0x80 || (c | 32 >= 'a' && c | 32 <= 'z')
}

@(private = "file")
is_ident :: proc(c: u8) -> bool {
	return is_ident_start(c) || (c >= '0' && c <= '9')
}

@(private = "file")
is_digit :: proc(c: u8) -> bool {
	return c >= '0' && c <= '9'
}

@(private = "file")
emit :: proc(out: ^[dynamic]Token, kind: Tok, from, to: int) {
	if to > from {
		append(out, Token{kind, from, to})
	}
}

// at reports whether `src` has `lit` at `i`. An empty literal never matches,
// which is how a language says it has no block comment.
@(private = "file")
at :: proc(src: string, i: int, lit: string) -> bool {
	return lit != "" && i + len(lit) <= len(src) && src[i:i + len(lit)] == lit
}

// lex_line appends the tokens of one line and returns the state the next line
// starts in. Whitespace produces no token; the renderer fills the gaps.
lex_line :: proc(
	src: string,
	enter: Lex_State,
	out: ^[dynamic]Token,
	lang := Lang.Odin,
) -> Lex_State {
	switch lang {
	case .Plain:
		return {}
	case .JSON:
		return lex_json(src, enter, out)
	case .Markdown:
		return lex_markdown(src, enter, out)
	case .Odin, .C, .Python, .Shell:
		s := syntax_of(lang)
		return lex_code(src, enter, out, &s)
	}
	return {}
}

// ---------------------------------------------------------------------------
// The C-family scanner: Odin, C, C++, Python, Shell
// ---------------------------------------------------------------------------

lex_code :: proc(src: string, enter: Lex_State, out: ^[dynamic]Token, sx: ^Syntax) -> Lex_State {
	st := enter
	i := 0

	// A block comment or raw string carried in from the previous line runs
	// until its terminator, wherever that is.
	if st.depth > 0 {
		start := i
		for i < len(src) {
			if at(src, i, sx.block_close) {
				i += len(sx.block_close)
				st.depth -= 1
				if st.depth == 0 {
					break
				}
				continue
			}
			if sx.nest_block && at(src, i, sx.block_open) {
				i += len(sx.block_open)
				st.depth += 1
				continue
			}
			i += 1
		}
		emit(out, .Comment, start, i)
	} else if st.raw && sx.raw_quote != 0 {
		start := i
		for i < len(src) {
			if src[i] == sx.raw_quote {
				i += 1
				st.raw = false
				break
			}
			i += 1
		}
		emit(out, .Str, start, i)
	}

	for i < len(src) {
		c := src[i]

		if c == ' ' || c == '\t' || c == '\r' {
			i += 1
			continue
		}

		// Comments. A line comment wins over everything, which is why a
		// language whose comment marker is `#` can never have `#` directives.
		if at(src, i, sx.line_comment) || at(src, i, sx.alt_comment) {
			emit(out, .Comment, i, len(src))
			return st
		}
		if at(src, i, sx.block_open) {
			start := i
			i += len(sx.block_open)
			st.depth = 1
			for i < len(src) {
				if sx.nest_block && at(src, i, sx.block_open) {
					st.depth += 1
					i += len(sx.block_open)
					continue
				}
				if at(src, i, sx.block_close) {
					st.depth -= 1
					i += len(sx.block_close)
					if st.depth == 0 {
						break
					}
					continue
				}
				i += 1
			}
			emit(out, .Comment, start, i)
			continue
		}

		// Strings.
		if c == '"' {
			start := i
			i = scan_quoted(src, i, '"')
			emit(out, .Str, start, i)
			continue
		}
		if sx.raw_quote != 0 && c == sx.raw_quote {
			start := i
			i += 1
			st.raw = true
			for i < len(src) {
				if src[i] == sx.raw_quote {
					i += 1
					st.raw = false
					break
				}
				i += 1
			}
			emit(out, .Str, start, i)
			continue
		}
		if c == '\'' {
			start := i
			i = scan_quoted(src, i, '\'')
			emit(out, sx.char_quote ? .Rune_Lit : .Str, start, i)
			continue
		}

		// Directives and attributes: #partial, @(private), #include.
		if sx.directive != "" && strings.contains_rune(sx.directive, rune(c)) {
			start := i
			i += 1
			for i < len(src) && is_ident(src[i]) {
				i += 1
			}
			emit(out, .Directive, start, i)
			continue
		}

		// Numbers, including 0x/0b/0o, digit separators and exponents.
		if is_digit(c) {
			start := i
			if c == '0' &&
			   i + 1 < len(src) &&
			   (src[i + 1] | 32 == 'x' ||
					   src[i + 1] | 32 == 'b' ||
					   src[i + 1] | 32 == 'o' ||
					   src[i + 1] | 32 == 'd' ||
					   src[i + 1] | 32 == 'z' ||
					   src[i + 1] | 32 == 'h') {
				i += 2
				for i < len(src) && (is_ident(src[i]) || is_digit(src[i])) {
					i += 1
				}
				emit(out, .Number, start, i)
				continue
			}
			for i < len(src) && (is_digit(src[i]) || src[i] == '_') {
				i += 1
			}
			if i < len(src) && src[i] == '.' && i + 1 < len(src) && is_digit(src[i + 1]) {
				i += 1
				for i < len(src) && (is_digit(src[i]) || src[i] == '_') {
					i += 1
				}
			}
			if i < len(src) && src[i] | 32 == 'e' {
				j := i + 1
				if j < len(src) && (src[j] == '+' || src[j] == '-') {
					j += 1
				}
				if j < len(src) && is_digit(src[j]) {
					i = j
					for i < len(src) && is_digit(src[i]) {
						i += 1
					}
				}
			}
			// A trailing type suffix, e.g. 1.5f32, 3i, 10UL.
			for i < len(src) && is_ident(src[i]) {
				i += 1
			}
			emit(out, .Number, start, i)
			continue
		}

		// Identifiers, and what follows decides how they are painted.
		if is_ident_start(c) {
			start := i
			for i < len(src) && is_ident(src[i]) {
				i += 1
			}
			word := src[start:i]
			kind := Tok.Plain
			switch {
			case in_set(sx.keywords, word):
				kind = .Keyword
			case in_set(sx.types, word):
				kind = .Type
			case in_set(sx.builtins, word):
				kind = .Builtin
			case start > 0 && src[start - 1] == '$':
				// A shell variable. `$` is punctuation, the name after it is
				// the thing worth seeing.
				kind = .Builtin
			case:
				// `name ::` is a declaration; `name(` is a call. Odin's own
				// style makes this the most useful distinction on screen.
				j := i
				for j < len(src) && (src[j] == ' ' || src[j] == '\t') {
					j += 1
				}
				if sx.decl_colon && j + 1 < len(src) && src[j] == ':' && src[j + 1] == ':' {
					kind = .Decl
				} else if j < len(src) && src[j] == '(' {
					kind = .Call
				} else if start > 0 && src[start - 1] == '.' {
					kind = .Plain
				} else if word[0] >= 'A' && word[0] <= 'Z' {
					kind = .Type
				}
			}
			emit(out, kind, start, i)
			continue
		}

		// Everything else is punctuation, run together so `::` is one token.
		start := i
		for i < len(src) {
			d := src[i]
			if d == ' ' ||
			   d == '\t' ||
			   d == '"' ||
			   d == '\'' ||
			   (sx.raw_quote != 0 && d == sx.raw_quote) ||
			   is_ident_start(d) ||
			   is_digit(d) {
				break
			}
			if sx.directive != "" && strings.contains_rune(sx.directive, rune(d)) {
				break
			}
			if at(src, i, sx.line_comment) || at(src, i, sx.alt_comment) || at(src, i, sx.block_open) {
				break
			}
			i += 1
		}
		if i == start {
			i += 1
		}
		emit(out, .Punct, start, i)
	}
	return st
}

// scan_quoted consumes a quoted run starting at the opening quote, honouring
// backslash escapes, and returns the index just past the closing quote (or the
// end of the line, for a string that does not close).
@(private = "file")
scan_quoted :: proc(src: string, from: int, q: u8) -> int {
	i := from + 1
	for i < len(src) {
		if src[i] == '\\' && i + 1 < len(src) {
			i += 2
			continue
		}
		if src[i] == q {
			return i + 1
		}
		i += 1
	}
	return i
}

// ---------------------------------------------------------------------------
// JSON
//
// The one distinction a JSON highlighter owes you is key versus value: in a
// document of a thousand lines the keys are the structure and the strings are
// the data, and painting both the same colour throws that away. A string is a
// key when the next non-space character is a colon.
// ---------------------------------------------------------------------------

lex_json :: proc(src: string, enter: Lex_State, out: ^[dynamic]Token) -> Lex_State {
	st := enter
	i := 0

	// JSONC: `//` and `/* */` are not in the standard but every editor accepts
	// them, and a comment painted as data is worse than a comment at all.
	if st.depth > 0 {
		start := i
		for i < len(src) {
			if at(src, i, "*/") {
				i += 2
				st.depth = 0
				break
			}
			i += 1
		}
		emit(out, .Comment, start, i)
	}

	for i < len(src) {
		c := src[i]
		if c == ' ' || c == '\t' || c == '\r' {
			i += 1
			continue
		}
		if at(src, i, "//") {
			emit(out, .Comment, i, len(src))
			return st
		}
		if at(src, i, "/*") {
			start := i
			i += 2
			st.depth = 1
			for i < len(src) {
				if at(src, i, "*/") {
					i += 2
					st.depth = 0
					break
				}
				i += 1
			}
			emit(out, .Comment, start, i)
			continue
		}
		if c == '"' {
			start := i
			i = scan_quoted(src, i, '"')
			// Look past the string: a colon makes it a key.
			j := i
			for j < len(src) && (src[j] == ' ' || src[j] == '\t') {
				j += 1
			}
			emit(out, j < len(src) && src[j] == ':' ? .Key : .Str, start, i)
			continue
		}
		if is_digit(c) || (c == '-' && i + 1 < len(src) && is_digit(src[i + 1])) {
			start := i
			i += 1
			for i < len(src) &&
			    (is_digit(src[i]) ||
					    src[i] == '.' ||
					    src[i] == 'e' ||
					    src[i] == 'E' ||
					    src[i] == '+' ||
					    src[i] == '-') {
				i += 1
			}
			emit(out, .Number, start, i)
			continue
		}
		if is_ident_start(c) {
			start := i
			for i < len(src) && is_ident(src[i]) {
				i += 1
			}
			word := src[start:i]
			// `true`, `false` and `null` are the whole of JSON's vocabulary.
			// Anything else is a syntax error, and painting it plain is how
			// an editor shows you that without pretending to be a validator.
			emit(
				out,
				word == "true" || word == "false" || word == "null" ? .Builtin : .Plain,
				start,
				i,
			)
			continue
		}
		start := i
		for i < len(src) {
			d := src[i]
			if d == ' ' || d == '\t' || d == '"' || is_ident_start(d) || is_digit(d) {
				break
			}
			if at(src, i, "//") || at(src, i, "/*") {
				break
			}
			if d == '-' && i + 1 < len(src) && is_digit(src[i + 1]) {
				break
			}
			i += 1
		}
		if i == start {
			i += 1
		}
		emit(out, .Punct, start, i)
	}
	return st
}

// ---------------------------------------------------------------------------
// Markdown
//
// A line grammar: what the first non-space character is decides what the line
// is. The one thing that crosses lines is a ``` fence, and inside one nothing
// is markup — which is exactly the case a regex highlighter gets wrong, since
// a `#` in a shell snippet is not a heading.
// ---------------------------------------------------------------------------

lex_markdown :: proc(src: string, enter: Lex_State, out: ^[dynamic]Token) -> Lex_State {
	st := enter

	indent := 0
	for indent < len(src) && (src[indent] == ' ' || src[indent] == '\t') {
		indent += 1
	}
	rest := src[indent:]

	// A fence opens and closes on its own line, and its content is code.
	if strings.has_prefix(rest, "```") || strings.has_prefix(rest, "~~~") {
		emit(out, .Code, 0, len(src))
		st.fence = !st.fence
		return st
	}
	if st.fence {
		emit(out, .Code, 0, len(src))
		return st
	}

	// Setext underlines and thematic breaks.
	if is_rule_line(rest) {
		emit(out, .Marker, 0, len(src))
		return st
	}

	i := indent

	// Block prefixes: heading, blockquote, list marker.
	switch {
	case strings.has_prefix(rest, "#"):
		n := 0
		for n < len(rest) && rest[n] == '#' {
			n += 1
		}
		if n <= 6 && (n == len(rest) || rest[n] == ' ') {
			// The whole line is the heading, markers and all.
			emit(out, .Heading, 0, len(src))
			return st
		}
	case strings.has_prefix(rest, ">"):
		j := indent
		for j < len(src) && (src[j] == '>' || src[j] == ' ') {
			j += 1
		}
		emit(out, .Marker, indent, j)
		i = j
	case:
		if m := list_marker_len(rest); m > 0 {
			emit(out, .Marker, indent, indent + m)
			i = indent + m
		}
	}

	// Inline spans. `code` wins over emphasis, which is why it is tested
	// first: a backtick run swallows whatever is inside it.
	for i < len(src) {
		c := src[i]
		if c == '`' {
			start := i
			n := 0
			for i < len(src) && src[i] == '`' {
				n += 1
				i += 1
			}
			// A run of n backticks closes on the next run of exactly n.
			for i < len(src) {
				if src[i] == '`' {
					k := 0
					for i + k < len(src) && src[i + k] == '`' {
						k += 1
					}
					if k == n {
						i += k
						break
					}
					i += k
					continue
				}
				i += 1
			}
			emit(out, .Code, start, i)
			continue
		}
		if c == '*' || c == '_' {
			start := i
			n := 0
			for i < len(src) && src[i] == c {
				n += 1
				i += 1
			}
			// An unmatched run is just punctuation; a matched one spans to its
			// partner.
			close := index_run(src, i, c, n)
			if close < 0 {
				emit(out, .Punct, start, i)
				continue
			}
			i = close + n
			emit(out, n >= 2 ? .Strong : .Emph, start, i)
			continue
		}
		if c == '[' || c == '!' {
			start := i
			j := i
			if src[j] == '!' {
				j += 1
			}
			if j < len(src) && src[j] == '[' {
				close := strings.index_byte(src[j:], ']')
				if close >= 0 {
					j += close + 1
					// `](url)` or `][ref]`, either of which belongs to the link.
					if j < len(src) && (src[j] == '(' || src[j] == '[') {
						shut: u8 = src[j] == '(' ? ')' : ']'
						k := strings.index_byte(src[j:], shut)
						if k >= 0 {
							j += k + 1
						}
					}
					emit(out, .Link, start, j)
					i = j
					continue
				}
			}
		}
		i += 1
	}
	return st
}

// is_rule_line is `---`, `***`, `___` or a Setext underline, which are the
// lines made entirely of one marker character.
@(private = "file")
is_rule_line :: proc(rest: string) -> bool {
	if len(rest) < 2 {
		return false
	}
	c := rest[0]
	if c != '-' && c != '*' && c != '_' && c != '=' {
		return false
	}
	n := 0
	for k in 0 ..< len(rest) {
		switch rest[k] {
		case c:
			n += 1
		case ' ', '\t':
		case:
			return false
		}
	}
	return n >= 2
}

// list_marker_len is the length of a leading list marker, including its space:
// `- `, `* `, `+ `, `1. `, `2) `, and the task-list forms.
@(private = "file")
list_marker_len :: proc(rest: string) -> int {
	if len(rest) >= 2 && (rest[0] == '-' || rest[0] == '*' || rest[0] == '+') && rest[1] == ' ' {
		// `- [ ] ` and `- [x] ` are one marker, not a bullet plus a link.
		if len(rest) >= 6 &&
		   rest[2] == '[' &&
		   rest[4] == ']' &&
		   rest[5] == ' ' &&
		   (rest[3] == ' ' || rest[3] | 32 == 'x') {
			return 6
		}
		return 2
	}
	n := 0
	for n < len(rest) && rest[n] >= '0' && rest[n] <= '9' {
		n += 1
	}
	if n > 0 && n + 1 < len(rest) && (rest[n] == '.' || rest[n] == ')') && rest[n + 1] == ' ' {
		return n + 2
	}
	return 0
}

// index_run finds the next run of exactly `n` copies of `c` at or after `from`.
@(private = "file")
index_run :: proc(src: string, from: int, c: u8, n: int) -> int {
	i := from
	for i < len(src) {
		if src[i] != c {
			i += 1
			continue
		}
		k := 0
		for i + k < len(src) && src[i + k] == c {
			k += 1
		}
		if k == n {
			return i
		}
		i += k
	}
	return -1
}

// ---------------------------------------------------------------------------
// Colours
// ---------------------------------------------------------------------------

// tok_class is the palmy class for a token kind, on the light shadcn theme.
// The hues are GitHub's light syntax theme, which is calibrated for white.
tok_class :: proc(k: Tok) -> string {
	switch k {
	case .Keyword:
		return "text-[#cf222e]"
	case .Type:
		return "text-[#8250df]"
	case .Builtin:
		return "text-[#0550ae]"
	case .Number:
		return "text-[#0550ae]"
	case .Str:
		return "text-[#0a3069]"
	case .Rune_Lit:
		return "text-[#0a3069]"
	case .Comment:
		return "text-[#6a737d]"
	case .Directive:
		return "text-[#953800]"
	case .Punct:
		return "text-[#57606a]"
	case .Call:
		return "text-[#6639ba]"
	case .Decl:
		return "text-[#111827] font-semibold"
	case .Key:
		return "text-[#0550ae] font-medium"
	case .Heading:
		return "text-[#0550ae] font-semibold"
	case .Emph:
		return "text-[#24292f] italic"
	case .Strong:
		return "text-[#24292f] font-semibold"
	case .Code:
		return "text-[#0a3069]"
	case .Link:
		return "text-[#0969da]"
	case .Marker:
		return "text-[#953800]"
	case .Plain:
		return "text-foreground"
	}
	return "text-foreground"
}

// tok_is_text answers "is this token prose or data rather than code", which is
// what bracket matching needs: a brace inside a string or a comment is not a
// brace the caret should jump to.
tok_is_text :: proc(k: Tok) -> bool {
	switch k {
	case .Str, .Rune_Lit, .Comment, .Code, .Link:
		return true
	case .Plain,
	     .Keyword,
	     .Type,
	     .Builtin,
	     .Number,
	     .Directive,
	     .Punct,
	     .Call,
	     .Decl,
	     .Key,
	     .Heading,
	     .Emph,
	     .Strong,
	     .Marker:
		return false
	}
	return false
}

// ---------------------------------------------------------------------------
// The per-line state cache
// ---------------------------------------------------------------------------

// lex_states_upto makes sure the entry state is known for every line below
// `limit`, scanning forward from the last line that is still valid. An edit on
// line L drops the cache to L, so the work after a keystroke is bounded by how
// far the viewport is from the edit.
lex_states_upto :: proc(b: ^Buffer, limit: int, lang: Lang) {
	want := min(limit, len(b.lines))
	if want <= b.valid {
		return
	}
	if len(b.states) < len(b.lines) + 1 {
		resize(&b.states, len(b.lines) + 1)
	}
	if b.valid == 0 {
		b.states[0] = Lex_State{}
	}
	toks := make([dynamic]Token, 0, 64, context.temp_allocator)
	for i in b.valid ..< want {
		clear(&toks)
		b.states[i + 1] = lex_line(buf_line(b, i), b.states[i], &toks, lang)
	}
	b.valid = want
}

lex_state_at :: proc(b: ^Buffer, line: int, lang := Lang.Odin) -> Lex_State {
	lex_states_upto(b, line + 1, lang)
	if line < len(b.states) {
		return b.states[line]
	}
	return Lex_State{}
}
