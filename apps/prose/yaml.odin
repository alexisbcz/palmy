package prose

// A YAML reader for exactly the subset Vale's rule files are written in.
//
// This is not a YAML implementation and must not be mistaken for one. Vale's
// schema is a flat map of scalars, with three shapes nested one level deep:
// a sequence of scalars (`tokens`, `metrics`, `exceptions`), a map of scalar
// to scalar (`swap`, `either`), and a map holding a sequence (`action`). Block
// scalars (`|`, `>`) appear in `description`. That is the whole grammar a
// `.yml` under a `styles/` directory ever uses, and supporting more would be
// code with no caller.
//
// What it deliberately does not do: anchors, aliases, tags, flow mappings,
// multi-document streams, or the dozen quoting corner cases that make YAML a
// bad format. A rule file that needs any of those is rejected with a reason
// rather than half-parsed, because a style rule that silently loses its
// `tokens` list would fire on nothing and look like it passed.

import "core:strconv"
import "core:strings"

Y_Kind :: enum {
	Scalar,
	List,
	Map,
}

Y_Node :: struct {
	kind:  Y_Kind,
	text:  string, // Scalar
	items: [dynamic]Y_Node, // List
	keys:  [dynamic]string, // Map
	vals:  [dynamic]Y_Node, // Map, parallel to keys
}

y_free :: proc(n: ^Y_Node) {
	for &it in n.items {
		y_free(&it)
	}
	delete(n.items)
	for &v in n.vals {
		y_free(&v)
	}
	delete(n.vals)
	delete(n.keys)
	n.items = nil
	n.vals = nil
	n.keys = nil
}

y_get :: proc(n: ^Y_Node, key: string) -> ^Y_Node {
	if n == nil || n.kind != .Map {
		return nil
	}
	for k, i in n.keys {
		if k == key {
			return &n.vals[i]
		}
	}
	return nil
}

y_str :: proc(n: ^Y_Node, key: string, def := "") -> string {
	v := y_get(n, key)
	if v == nil || v.kind != .Scalar {
		return def
	}
	return v.text
}

y_bool :: proc(n: ^Y_Node, key: string, def := false) -> bool {
	s := y_str(n, key, "")
	switch strings.to_lower(s, context.temp_allocator) {
	case "true", "yes", "on":
		return true
	case "false", "no", "off":
		return false
	}
	return def
}

y_int :: proc(n: ^Y_Node, key: string, def := 0) -> int {
	s := y_str(n, key, "")
	if s == "" {
		return def
	}
	v, ok := strconv.parse_int(strings.trim_space(s))
	return ok ? v : def
}

y_f64 :: proc(n: ^Y_Node, key: string, def := 0.0) -> f64 {
	s := y_str(n, key, "")
	if s == "" {
		return def
	}
	v, ok := strconv.parse_f64(strings.trim_space(s))
	return ok ? v : def
}

// y_list returns a key's value as a list of strings, accepting both a real
// sequence and a lone scalar — `tokens: foo` and `tokens:\n  - foo` mean the
// same thing to Vale, and a rule file in the wild uses whichever is shorter.
y_list :: proc(n: ^Y_Node, key: string, allocator := context.allocator) -> []string {
	v := y_get(n, key)
	if v == nil {
		return nil
	}
	if v.kind == .Scalar {
		out := make([]string, 1, allocator)
		out[0] = v.text
		return out
	}
	if v.kind != .List {
		return nil
	}
	out := make([dynamic]string, 0, len(v.items), allocator)
	for it in v.items {
		if it.kind == .Scalar {
			append(&out, it.text)
		}
	}
	return out[:]
}

// ---------------------------------------------------------------------------
// The reader
// ---------------------------------------------------------------------------

Y_Line :: struct {
	indent: int,
	text:   string, // trimmed of indentation and the trailing comment
	raw:    string, // trimmed of indentation only, comments intact
	no:     int,
}

@(private = "file")
y_split :: proc(src: string, allocator := context.temp_allocator) -> []Y_Line {
	out := make([dynamic]Y_Line, 0, 64, allocator)
	rest := src
	no := 0
	for line in strings.split_lines_iterator(&rest) {
		no += 1
		l := strings.trim_right(line, " \t\r")
		ind := 0
		for ind < len(l) && l[ind] == ' ' {
			ind += 1
		}
		body := l[ind:]
		if body == "" || body[0] == '#' {
			continue
		}
		if body == "---" || body == "..." {
			continue // a lone document marker, which rule files sometimes carry
		}
		append(&out, Y_Line{indent = ind, text = body, raw = body, no = no})
	}
	return out[:]
}

// y_unquote strips one layer of quotes and resolves the escapes that matter.
// Single quotes in YAML are literal except for a doubled `''`; double quotes
// take backslash escapes. Regex patterns live in single quotes for exactly
// this reason, so getting it wrong turns `\b` into a backspace.
y_unquote :: proc(s: string, allocator := context.allocator) -> string {
	t := strings.trim_space(s)
	if len(t) >= 2 && t[0] == '\'' && t[len(t) - 1] == '\'' {
		inner := t[1:len(t) - 1]
		if !strings.contains(inner, "''") {
			return strings.clone(inner, allocator)
		}
		return strings.replace_all(inner, "''", "'", allocator) or_else strings.clone(inner, allocator)
	}
	if len(t) >= 2 && t[0] == '"' && t[len(t) - 1] == '"' {
		sb := strings.builder_make(allocator)
		inner := t[1:len(t) - 1]
		i := 0
		for i < len(inner) {
			if inner[i] == '\\' && i + 1 < len(inner) {
				switch inner[i + 1] {
				case 'n':
					strings.write_byte(&sb, '\n')
				case 't':
					strings.write_byte(&sb, '\t')
				case 'r':
					strings.write_byte(&sb, '\r')
				case '\\':
					strings.write_byte(&sb, '\\')
				case '"':
					strings.write_byte(&sb, '"')
				case:
					// Unknown escape: YAML would reject it, but a rule file
					// writing `\b` inside double quotes means the regex, so
					// the backslash is kept rather than eaten.
					strings.write_byte(&sb, '\\')
					strings.write_byte(&sb, inner[i + 1])
				}
				i += 2
				continue
			}
			strings.write_byte(&sb, inner[i])
			i += 1
		}
		return strings.to_string(sb)
	}
	return strings.clone(t, allocator)
}

// y_strip_comment removes a trailing `# ...` that is not inside quotes.
@(private = "file")
y_strip_comment :: proc(s: string) -> string {
	q: u8 = 0
	for i in 0 ..< len(s) {
		c := s[i]
		switch {
		case q != 0:
			if c == q {
				q = 0
			}
		case c == '\'' || c == '"':
			q = c
		case c == '#' && i > 0 && (s[i - 1] == ' ' || s[i - 1] == '\t'):
			return strings.trim_right(s[:i], " \t")
		}
	}
	return s
}

// y_key splits `key: value` at the first colon outside quotes. Vale's `swap`
// maps have regex keys, and a regex can contain a colon, so the split has to
// require the colon be followed by a space or end of line.
@(private = "file")
y_key :: proc(s: string) -> (key, val: string, ok: bool) {
	q: u8 = 0
	depth := 0
	for i in 0 ..< len(s) {
		c := s[i]
		switch {
		case q != 0:
			if c == q {
				q = 0
			}
			continue
		case (c == '\'' || c == '"') && i == 0:
			// Only a quote opening the whole scalar is a YAML quote. A swap
			// key is often a regex, and `i(?:'| a)m` has an apostrophe in it
			// that is a character class member, not a string delimiter.
			q = c
			continue
		case c == '[' || c == '(':
			depth += 1
			continue
		case c == ']' || c == ')':
			depth -= 1
			continue
		case c == ':' && depth == 0:
			if i + 1 == len(s) {
				return y_unquote(s[:i], context.temp_allocator), "", true
			}
			if s[i + 1] == ' ' || s[i + 1] == '\t' {
				return y_unquote(s[:i], context.temp_allocator),
					strings.trim_space(s[i + 1:]),
					true
			}
		}
	}
	return "", "", false
}

Y_Error :: struct {
	line: int,
	what: string,
}

// y_parse reads the whole file into a tree. The allocator owns every string in
// it, so `y_free` plus deleting the strings is the whole teardown; in practice
// callers parse into `context.temp_allocator` and copy out what they keep.
y_parse :: proc(src: string, allocator := context.allocator) -> (root: Y_Node, err: Y_Error) {
	lines := y_split(src)
	i := 0
	root, err = y_parse_map(lines, &i, 0, allocator)
	return
}

@(private = "file")
y_block_scalar :: proc(
	lines: []Y_Line,
	i: ^int,
	parent_indent: int,
	fold: bool,
	allocator: Allocator,
) -> string {
	sb := strings.builder_make(allocator)
	base := -1
	for i^ < len(lines) {
		l := lines[i^]
		if l.indent <= parent_indent {
			break
		}
		if base < 0 {
			base = l.indent
		}
		if strings.builder_len(sb) > 0 {
			strings.write_byte(&sb, fold ? ' ' : '\n')
		}
		pad := max(0, l.indent - base)
		for _ in 0 ..< pad {
			strings.write_byte(&sb, ' ')
		}
		strings.write_string(&sb, l.raw)
		i^ += 1
	}
	// A literal block in YAML ends with a newline ("clip" chomping), and Vale
	// reports `description` with that newline present, so it is kept.
	if !fold && strings.builder_len(sb) > 0 {
		strings.write_byte(&sb, '\n')
	}
	return strings.to_string(sb)
}

@(private = "file")
y_parse_list :: proc(
	lines: []Y_Line,
	i: ^int,
	indent: int,
	allocator: Allocator,
) -> (
	out: Y_Node,
	err: Y_Error,
) {
	out.kind = .List
	out.items = make([dynamic]Y_Node, 0, 8, allocator)
	for i^ < len(lines) {
		l := lines[i^]
		if l.indent != indent || !strings.has_prefix(l.text, "- ") && l.text != "-" {
			break
		}
		body := strings.trim_space(y_strip_comment(l.text[1:]))
		i^ += 1
		if body == "" {
			// A nested sequence or map under a bare `-`. Vale never writes
			// one; refusing beats guessing.
			return out, Y_Error{l.no, "nested sequence entries are not supported"}
		}
		item := Y_Node {
			kind = .Scalar,
			text = y_unquote(body, allocator),
		}
		append(&out.items, item)
	}
	return
}

@(private = "file")
y_parse_map :: proc(
	lines: []Y_Line,
	i: ^int,
	indent: int,
	allocator: Allocator,
) -> (
	out: Y_Node,
	err: Y_Error,
) {
	out.kind = .Map
	out.keys = make([dynamic]string, 0, 8, allocator)
	out.vals = make([dynamic]Y_Node, 0, 8, allocator)

	for i^ < len(lines) {
		l := lines[i^]
		if l.indent < indent {
			break
		}
		if l.indent > indent {
			return out, Y_Error{l.no, "unexpected indentation"}
		}
		if strings.has_prefix(l.text, "- ") {
			break
		}
		key, val, ok := y_key(y_strip_comment(l.text))
		if !ok {
			return out, Y_Error{l.no, "expected `key: value`"}
		}
		i^ += 1

		node: Y_Node
		switch {
		case val == "|" || val == "|-" || val == "|+":
			node = Y_Node {
				kind = .Scalar,
				text = y_block_scalar(lines, i, indent, false, allocator),
			}
			if val == "|-" {
				node.text = strings.trim_right(node.text, "\n")
			}
		case val == ">" || val == ">-" || val == ">+":
			node = Y_Node {
				kind = .Scalar,
				text = y_block_scalar(lines, i, indent, true, allocator),
			}
		case val != "":
			node = Y_Node {
				kind = .Scalar,
				text = y_unquote(val, allocator),
			}
		case:
			// An empty value: whatever is indented under it. A `- ` first
			// line makes it a sequence, anything else a map, and nothing at
			// all makes it an empty scalar.
			if i^ < len(lines) && lines[i^].indent > indent {
				child := lines[i^]
				if strings.has_prefix(child.text, "- ") || child.text == "-" {
					node, err = y_parse_list(lines, i, child.indent, allocator)
				} else {
					node, err = y_parse_map(lines, i, child.indent, allocator)
				}
				if err.what != "" {
					return out, err
				}
			} else {
				node = Y_Node {
					kind = .Scalar,
					text = "",
				}
			}
		}
		append(&out.keys, strings.clone(key, allocator))
		append(&out.vals, node)
	}
	return
}
