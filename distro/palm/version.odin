package palm

// Version comparison, apk's rules.
//
// A version is read as a sequence of tokens:
//
//	1.2.10a_rc3-r2
//	│ │ │ │ │   └── revision   -rN     (the packaging release, palm's pkgrel)
//	│ │ │ │ └────── suffix     _rc3    (_alpha _beta _pre _rc sort below the
//	│ │ │ │                             release; _cvs _svn _git _hg _p above)
//	│ │ │ └──────── letter     a
//	└─┴─┴────────── numbers    1 . 2 . 10   compared as numbers, so 1.2.10 > 1.2.9
//
// Two versions are walked token by token. Tokens of the same kind compare by
// value. Where the kinds differ the token kind decides, which is what makes
// all of these come out right without special cases:
//
//	1.2_rc1 < 1.2 < 1.2-r1 < 1.2_p1 < 1.2a < 1.2.1
//
// A version palm cannot tokenize (stray characters) falls back to a plain
// string comparison from that point, rather than refusing: a repository with
// one oddly-versioned package should not stop every other package installing.

import "core:strconv"
import "core:strings"

@(private = "file")
Tok_Kind :: enum {
	Pre_Suffix, // _alpha _beta _pre _rc
	End,
	Revision,
	Post_Suffix, // _p _cvs _svn _git _hg, and anything unknown
	Letter,
	Number,
	Invalid,
}

@(private = "file")
Tok :: struct {
	kind:   Tok_Kind,
	num:    string, // digits, leading zeros stripped
	suffix: int, // rank among suffixes
	letter: byte,
	rest:   string, // for Invalid: the unparsed remainder
}

@(private = "file")
SUFFIXES := [?]string{"alpha", "beta", "pre", "rc", "", "cvs", "svn", "git", "hg", "p"}

@(private = "file")
take_digits :: proc(s: string) -> (string, string) {
	i := 0
	for i < len(s) && s[i] >= '0' && s[i] <= '9' {
		i += 1
	}
	d := strings.trim_left(s[:i], "0")
	return d, s[i:]
}

// next_tok reads one token. `first` is true at the start of the string,
// where only a number is valid.
@(private = "file")
next_tok :: proc(s: ^string, first: bool) -> Tok {
	r := s^
	if len(r) == 0 {
		return Tok{kind = .End}
	}
	if first {
		if r[0] >= '0' && r[0] <= '9' {
			d, rest := take_digits(r)
			s^ = rest
			return Tok{kind = .Number, num = d}
		}
		return Tok{kind = .Invalid, rest = r}
	}
	switch {
	case r[0] == '.' && len(r) > 1 && r[1] >= '0' && r[1] <= '9':
		d, rest := take_digits(r[1:])
		s^ = rest
		return Tok{kind = .Number, num = d}
	case r[0] >= 'a' && r[0] <= 'z':
		s^ = r[1:]
		return Tok{kind = .Letter, letter = r[0]}
	case r[0] == '_':
		i := 1
		for i < len(r) && r[i] >= 'a' && r[i] <= 'z' {
			i += 1
		}
		word := r[1:i]
		d, rest := take_digits(r[i:])
		s^ = rest
		rank := 4
		for name, k in SUFFIXES {
			if name != "" && name == word {
				rank = k
			}
		}
		return Tok{kind = rank < 4 ? .Pre_Suffix : .Post_Suffix, suffix = rank, num = d}
	case strings.has_prefix(r, "-r") && len(r) > 2 && r[2] >= '0' && r[2] <= '9':
		d, rest := take_digits(r[2:])
		s^ = rest
		return Tok{kind = .Revision, num = d}
	}
	return Tok{kind = .Invalid, rest = r}
}

@(private = "file")
cmp_num :: proc(a, b: string) -> int {
	if len(a) != len(b) {
		return len(a) < len(b) ? -1 : 1
	}
	return strings.compare(a, b)
}

// version_compare returns -1, 0 or 1.
version_compare :: proc(a, b: string) -> int {
	ra, rb := a, b
	first := true
	for {
		ta := next_tok(&ra, first)
		tb := next_tok(&rb, first)
		first = false
		if ta.kind == .Invalid || tb.kind == .Invalid {
			x := ta.kind == .Invalid ? ta.rest : ra
			y := tb.kind == .Invalid ? tb.rest : rb
			c := strings.compare(x, y)
			return c < 0 ? -1 : (c > 0 ? 1 : 0)
		}
		// "-r0" is the same release as no revision at all.
		if ta.kind == .Revision && ta.num == "" && tb.kind == .End {ta.kind = .End}
		if tb.kind == .Revision && tb.num == "" && ta.kind == .End {tb.kind = .End}
		if ta.kind != tb.kind {
			return ta.kind < tb.kind ? -1 : 1
		}
		c := 0
		switch ta.kind {
		case .Number, .Revision:
			c = cmp_num(ta.num, tb.num)
		case .Letter:
			c = int(ta.letter) - int(tb.letter)
		case .Pre_Suffix, .Post_Suffix:
			c = ta.suffix - tb.suffix
			if c == 0 {
				c = cmp_num(ta.num, tb.num)
			}
		case .End:
			return 0
		case .Invalid:
		}
		if c != 0 {
			return c < 0 ? -1 : 1
		}
	}
}

version_valid :: proc(v: string) -> bool {
	r := v
	first := true
	for {
		t := next_tok(&r, first)
		first = false
		if t.kind == .Invalid {
			return false
		}
		if t.kind == .End {
			return true
		}
	}
}

// ---------------------------------------------------------------------------
// Constraints: "name", "name>=1.2", "name<2", "name=1.2.3-r1", "name~1.2"
//
// `~` is apk's fuzzy match: the version starts with the given one, so
// "foo~1.2" accepts 1.2, 1.2.5 and 1.2-r3 but not 1.20.
// ---------------------------------------------------------------------------

Op :: enum {
	Any,
	Eq,
	Lt,
	Le,
	Gt,
	Ge,
	Fuzzy,
}

Constraint :: struct {
	name:    string,
	op:      Op,
	version: string,
}

parse_constraint :: proc(text: string) -> (Constraint, bool) {
	s := strings.trim_space(text)
	i := strings.index_any(s, "<>=~")
	if i < 0 {
		return Constraint{name = s}, name_valid(s)
	}
	c := Constraint{name = s[:i]}
	rest := s[i:]
	switch {
	case strings.has_prefix(rest, ">="):
		c.op, rest = .Ge, rest[2:]
	case strings.has_prefix(rest, "<="):
		c.op, rest = .Le, rest[2:]
	case strings.has_prefix(rest, ">"):
		c.op, rest = .Gt, rest[1:]
	case strings.has_prefix(rest, "<"):
		c.op, rest = .Lt, rest[1:]
	case strings.has_prefix(rest, "~"):
		c.op, rest = .Fuzzy, rest[1:]
	case strings.has_prefix(rest, "="):
		c.op, rest = .Eq, rest[1:]
	}
	c.version = strings.trim_left(rest, "=")
	return c, name_valid(c.name) && c.version != "" && version_valid(c.version)
}

constraint_string :: proc(c: Constraint, allocator := context.temp_allocator) -> string {
	ops := [Op]string {
		.Any   = "",
		.Eq    = "=",
		.Lt    = "<",
		.Le    = "<=",
		.Gt    = ">",
		.Ge    = ">=",
		.Fuzzy = "~",
	}
	return strings.concatenate({c.name, ops[c.op], c.version}, allocator)
}

version_satisfies :: proc(v: string, op: Op, want: string) -> bool {
	switch op {
	case .Any:
		return true
	case .Fuzzy:
		if !strings.has_prefix(v, want) {
			return false
		}
		tail := v[len(want):]
		return tail == "" || tail[0] == '.' || tail[0] == '-' || tail[0] == '_' || (tail[0] >= 'a' && tail[0] <= 'z')
	case .Eq:
		// "=1.2" matches 1.2-r0 and 1.2-r7 unless a revision is given.
		if !strings.contains(want, "-r") {
			if c := version_compare(strip_revision(v), want); c == 0 {
				return true
			}
		}
		return version_compare(v, want) == 0
	case .Lt:
		return version_compare(v, want) < 0
	case .Le:
		return version_compare(v, want) <= 0
	case .Gt:
		return version_compare(v, want) > 0
	case .Ge:
		return version_compare(v, want) >= 0
	}
	return false
}

strip_revision :: proc(v: string) -> string {
	if i := strings.last_index(v, "-r"); i > 0 {
		if _, ok := strconv.parse_int(v[i + 2:]); ok {
			return v[:i]
		}
	}
	return v
}

// name_valid is the fence for anything that becomes a file name or a world
// line: lowercase letters, digits and "+-._:", starting with a letter or
// digit. The colon is there for provides such as "cmd:sh" and "so:libc.so.6".
name_valid :: proc(s: string) -> bool {
	if s == "" || len(s) > 128 {
		return false
	}
	for c, i in transmute([]byte)s {
		switch c {
		case 'a' ..= 'z', '0' ..= '9':
		case 'A' ..= 'Z':
		case '+', '-', '.', '_', ':':
			if i == 0 {
				return false
			}
		case:
			return false
		}
	}
	return true
}
