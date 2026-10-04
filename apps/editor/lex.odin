// An Odin tokeniser.
//
// This is a real scanner, not a keyword-colouring pass: the line is walked
// character by character and every token is produced by the rule that owns it,
// so `"// not a comment"` stays a string, `0x_ff_u8` is one number, `'\''` is
// one rune literal, and a `/* /* */ */` nest closes at the right place because
// Odin's block comments nest.
//
// State that crosses a line boundary — the block comment depth and whether a
// backtick raw string is open — is returned so the caller can cache the state
// entering each line and rehighlight only what it is about to draw.
package main

import "core:strings"

Lex_State :: struct {
	depth: u16, // nested /* */ depth
	raw:   bool, // inside a `...` raw string
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
}

Token :: struct {
	kind: Tok,
	from: int,
	to:   int,
}

KEYWORDS := [?]string {
	"asm",
	"auto_cast",
	"bit_field",
	"bit_set",
	"break",
	"case",
	"cast",
	"context",
	"continue",
	"defer",
	"distinct",
	"do",
	"dynamic",
	"else",
	"enum",
	"fallthrough",
	"for",
	"foreign",
	"if",
	"import",
	"in",
	"map",
	"matrix",
	"not_in",
	"or_break",
	"or_continue",
	"or_else",
	"or_return",
	"package",
	"proc",
	"return",
	"struct",
	"switch",
	"transmute",
	"typeid",
	"union",
	"using",
	"when",
	"where",
}

TYPES := [?]string {
	"any",
	"b16",
	"b32",
	"b64",
	"b8",
	"bool",
	"byte",
	"complex128",
	"complex32",
	"complex64",
	"cstring",
	"f16",
	"f32",
	"f64",
	"i128",
	"i16",
	"i32",
	"i64",
	"i8",
	"int",
	"quaternion128",
	"quaternion256",
	"quaternion64",
	"rawptr",
	"rune",
	"string",
	"u128",
	"u16",
	"u32",
	"u64",
	"u8",
	"uint",
	"uintptr",
}

BUILTINS := [?]string {
	"abs",
	"align_of",
	"append",
	"cap",
	"clamp",
	"clear",
	"copy",
	"delete",
	"false",
	"free",
	"len",
	"make",
	"max",
	"min",
	"new",
	"nil",
	"offset_of",
	"ordered_remove",
	"raw_data",
	"remove_range",
	"reserve",
	"resize",
	"size_of",
	"swizzle",
	"true",
	"type_of",
	"unordered_remove",
}

@(private = "file")
in_set :: proc(set: []string, word: string) -> bool {
	// The tables are sorted, so this is a binary search.
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

// lex_line appends the tokens of one line and returns the state the next line
// starts in. Whitespace produces no token; the renderer fills the gaps.
lex_line :: proc(src: string, enter: Lex_State, out: ^[dynamic]Token) -> Lex_State {
	st := enter
	i := 0

	emit :: proc(out: ^[dynamic]Token, kind: Tok, from, to: int) {
		if to > from {
			append(out, Token{kind, from, to})
		}
	}

	// A block comment or raw string carried in from the previous line runs
	// until its terminator, wherever that is.
	if st.depth > 0 {
		start := i
		for i < len(src) {
			if i + 1 < len(src) && src[i] == '*' && src[i + 1] == '/' {
				i += 2
				st.depth -= 1
				if st.depth == 0 {
					break
				}
				continue
			}
			if i + 1 < len(src) && src[i] == '/' && src[i + 1] == '*' {
				i += 2
				st.depth += 1
				continue
			}
			i += 1
		}
		emit(out, .Comment, start, i)
	} else if st.raw {
		start := i
		for i < len(src) {
			if src[i] == '`' {
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

		// Comments.
		if c == '/' && i + 1 < len(src) {
			if src[i + 1] == '/' {
				emit(out, .Comment, i, len(src))
				return st
			}
			if src[i + 1] == '*' {
				start := i
				i += 2
				st.depth = 1
				for i < len(src) {
					if i + 1 < len(src) && src[i] == '/' && src[i + 1] == '*' {
						st.depth += 1
						i += 2
						continue
					}
					if i + 1 < len(src) && src[i] == '*' && src[i + 1] == '/' {
						st.depth -= 1
						i += 2
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
		}

		// Strings.
		if c == '"' {
			start := i
			i += 1
			for i < len(src) {
				if src[i] == '\\' && i + 1 < len(src) {
					i += 2
					continue
				}
				if src[i] == '"' {
					i += 1
					break
				}
				i += 1
			}
			emit(out, .Str, start, i)
			continue
		}
		if c == '`' {
			start := i
			i += 1
			st.raw = true
			for i < len(src) {
				if src[i] == '`' {
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
			i += 1
			for i < len(src) {
				if src[i] == '\\' && i + 1 < len(src) {
					i += 2
					continue
				}
				if src[i] == '\'' {
					i += 1
					break
				}
				i += 1
			}
			emit(out, .Rune_Lit, start, i)
			continue
		}

		// Directives and attributes: #partial, @(private).
		if c == '#' || c == '@' {
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
			if c == '0' && i + 1 < len(src) && (src[i + 1] | 32 == 'x' || src[i + 1] | 32 == 'b' || src[i + 1] | 32 == 'o' || src[i + 1] | 32 == 'd' || src[i + 1] | 32 == 'z' || src[i + 1] | 32 == 'h') {
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
			// A trailing type suffix, e.g. 1.5f32 or 3i.
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
			case in_set(KEYWORDS[:], word):
				kind = .Keyword
			case in_set(TYPES[:], word):
				kind = .Type
			case in_set(BUILTINS[:], word):
				kind = .Builtin
			case:
				// `name ::` is a declaration; `name(` is a call. Odin's own
				// style makes this the most useful distinction on screen.
				j := i
				for j < len(src) && (src[j] == ' ' || src[j] == '\t') {
					j += 1
				}
				if j + 1 < len(src) && src[j] == ':' && src[j + 1] == ':' {
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
			   d == '`' ||
			   d == '\'' ||
			   d == '#' ||
			   d == '@' ||
			   is_ident_start(d) ||
			   is_digit(d) {
				break
			}
			if d == '/' && i + 1 < len(src) && (src[i + 1] == '/' || src[i + 1] == '*') {
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
	case .Plain:
		return "text-foreground"
	}
	return "text-foreground"
}

// ---------------------------------------------------------------------------
// The per-line state cache
// ---------------------------------------------------------------------------

// lex_states_upto makes sure the entry state is known for every line below
// `limit`, scanning forward from the last line that is still valid. An edit on
// line L drops the cache to L, so the work after a keystroke is bounded by how
// far the viewport is from the edit.
lex_states_upto :: proc(b: ^Buffer, limit: int) {
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
		b.states[i + 1] = lex_line(buf_line(b, i), b.states[i], &toks)
	}
	b.valid = want
}

lex_state_at :: proc(b: ^Buffer, line: int) -> Lex_State {
	lex_states_upto(b, line + 1)
	if line < len(b.states) {
		return b.states[line]
	}
	return Lex_State{}
}
