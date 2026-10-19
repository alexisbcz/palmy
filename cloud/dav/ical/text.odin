// Package ical reads, writes and computes with iCalendar (RFC 5545), and
// lends its content-line layer to vCard (RFC 6350), which shares the syntax.
//
// The model is deliberately thin: a Component is a name, its properties in
// order, and its children. A property keeps its value exactly as it was
// written (still escaped), so a component that is parsed and written back is
// the same text, byte for byte apart from line folding. Interpretation —
// dates, recurrence, time zones — is done on demand by the procedures in the
// other files, never by mutating what the client sent.
//
// Allocation: everything comes from context.allocator. The server runs each
// request on an arena and drops it whole; an app that keeps components keeps
// the arena.
package ical

import "core:strings"

Param :: struct {
	name:   string, // upper-cased
	values: []string, // unquoted
}

Prop :: struct {
	group:  string, // vCard "item1." prefix, without the dot
	name:   string, // upper-cased
	params: []Param,
	value:  string, // raw, as written (escapes intact)
}

Component :: struct {
	name:     string, // upper-cased: VCALENDAR, VEVENT, VCARD...
	props:    [dynamic]Prop,
	children: [dynamic]^Component,
}

Parse_Error :: struct {
	line:    int,
	message: string,
}

// unfold joins folded lines (CRLF or LF followed by a space or a tab) and
// returns the logical lines. Bare LF is accepted because real files have it.
unfold :: proc(text: string) -> []string {
	out := make([dynamic]string, 0, 64)
	sb := strings.builder_make()
	i := 0
	have := false
	for i < len(text) {
		j := strings.index_byte(text[i:], '\n')
		line: string
		if j < 0 {
			line = text[i:]
			i = len(text)
		} else {
			line = text[i:i + j]
			i += j + 1
		}
		if len(line) > 0 && line[len(line) - 1] == '\r' {
			line = line[:len(line) - 1]
		}
		if len(line) > 0 && (line[0] == ' ' || line[0] == '\t') {
			strings.write_string(&sb, line[1:])
			continue
		}
		if have {
			append(&out, strings.clone(strings.to_string(sb)))
			strings.builder_reset(&sb)
		}
		strings.write_string(&sb, line)
		have = true
	}
	if have && strings.builder_len(sb) > 0 {
		append(&out, strings.clone(strings.to_string(sb)))
	}
	strings.builder_destroy(&sb)
	return out[:]
}

// parse_line splits one logical line into a property.
//   [group "."] name *(";" param) ":" value
// A parameter value may be quoted, and a quoted value may contain ':' ';' ','.
parse_line :: proc(line: string) -> (p: Prop, ok: bool) {
	i := 0
	n := len(line)
	// Name, possibly with a group.
	start := 0
	for i < n && line[i] != ';' && line[i] != ':' {
		if line[i] == '.' {
			p.group = line[start:i]
			start = i + 1
		}
		i += 1
	}
	if i >= n || i == start {
		return {}, false
	}
	p.name = strings.to_upper(line[start:i])
	params := make([dynamic]Param, 0, 2)
	for i < n && line[i] == ';' {
		i += 1
		ps := i
		for i < n && line[i] != '=' && line[i] != ';' && line[i] != ':' {
			i += 1
		}
		pname := strings.to_upper(line[ps:i])
		values := make([dynamic]string, 0, 1)
		if i < n && line[i] == '=' {
			i += 1
			for {
				if i < n && line[i] == '"' {
					i += 1
					vs := i
					for i < n && line[i] != '"' {
						i += 1
					}
					append(&values, unescape_param(line[vs:i]))
					if i < n {
						i += 1
					}
				} else {
					vs := i
					for i < n && line[i] != ',' && line[i] != ';' && line[i] != ':' {
						i += 1
					}
					append(&values, unescape_param(line[vs:i]))
				}
				if i < n && line[i] == ',' {
					i += 1
					continue
				}
				break
			}
		} else {
			// vCard 2.1/3.0 bare type: "TEL;WORK:..." means TYPE=WORK.
			append(&values, pname)
			pname = "TYPE"
		}
		append(&params, Param{name = pname, values = values[:]})
	}
	if i >= n || line[i] != ':' {
		return {}, false
	}
	p.params = params[:]
	p.value = line[i + 1:]
	return p, true
}

// RFC 6868 caret escapes in parameter values: ^n newline, ^' quote, ^^ caret.
unescape_param :: proc(s: string) -> string {
	if strings.index_byte(s, '^') < 0 {
		return s
	}
	sb := strings.builder_make()
	for i := 0; i < len(s); i += 1 {
		if s[i] == '^' && i + 1 < len(s) {
			switch s[i + 1] {
			case 'n':
				strings.write_byte(&sb, '\n'); i += 1; continue
			case '\'':
				strings.write_byte(&sb, '"'); i += 1; continue
			case '^':
				strings.write_byte(&sb, '^'); i += 1; continue
			}
		}
		strings.write_byte(&sb, s[i])
	}
	return strings.to_string(sb)
}

// parse reads a whole stream: one or more top-level components. Lines before
// the first BEGIN, and unknown junk between components, are an error; an
// unterminated component is an error.
parse :: proc(text: string) -> (roots: []^Component, err: Parse_Error, ok: bool) {
	lines := unfold(text)
	out := make([dynamic]^Component, 0, 1)
	stack := make([dynamic]^Component, 0, 4, context.temp_allocator)
	for line, ln in lines {
		if len(strings.trim_space(line)) == 0 {
			continue
		}
		p, good := parse_line(line)
		if !good {
			return nil, {ln + 1, "a line is not a property"}, false
		}
		if p.name == "BEGIN" {
			c := new(Component)
			c.name = strings.to_upper(strings.trim_space(p.value))
			c.props = make([dynamic]Prop, 0, 8)
			c.children = make([dynamic]^Component, 0, 0)
			if len(stack) > 0 {
				append(&stack[len(stack) - 1].children, c)
			} else {
				append(&out, c)
			}
			append(&stack, c)
			continue
		}
		if p.name == "END" {
			name := strings.to_upper(strings.trim_space(p.value), context.temp_allocator)
			if len(stack) == 0 || stack[len(stack) - 1].name != name {
				return nil, {ln + 1, "END does not match BEGIN"}, false
			}
			pop(&stack)
			continue
		}
		if len(stack) == 0 {
			return nil, {ln + 1, "a property outside any component"}, false
		}
		append(&stack[len(stack) - 1].props, p)
	}
	if len(stack) > 0 {
		return nil, {len(lines), "a component is not closed"}, false
	}
	if len(out) == 0 {
		return nil, {0, "no component"}, false
	}
	return out[:], {}, true
}

// parse_one is parse for the usual case: exactly one top-level component.
parse_one :: proc(text: string) -> (^Component, Parse_Error, bool) {
	roots, err, ok := parse(text)
	if !ok {
		return nil, err, false
	}
	if len(roots) != 1 {
		return nil, {0, "more than one top-level component"}, false
	}
	return roots[0], {}, true
}

// ---------------------------------------------------------------------------
// Access
// ---------------------------------------------------------------------------

prop :: proc(c: ^Component, name: string) -> ^Prop {
	if c == nil {
		return nil
	}
	for &p in c.props {
		if p.name == name {
			return &p
		}
	}
	return nil
}

props :: proc(c: ^Component, name: string, allocator := context.temp_allocator) -> []^Prop {
	out := make([dynamic]^Prop, 0, 2, allocator)
	for &p in c.props {
		if p.name == name {
			append(&out, &p)
		}
	}
	return out[:]
}

value :: proc(c: ^Component, name: string) -> string {
	if p := prop(c, name); p != nil {
		return p.value
	}
	return ""
}

text :: proc(c: ^Component, name: string) -> string {
	if p := prop(c, name); p != nil {
		return unescape_text(p.value)
	}
	return ""
}

param :: proc(p: ^Prop, name: string) -> string {
	if p == nil {
		return ""
	}
	for q in p.params {
		if q.name == name && len(q.values) > 0 {
			return q.values[0]
		}
	}
	return ""
}

param_values :: proc(p: ^Prop, name: string) -> []string {
	if p == nil {
		return nil
	}
	for q in p.params {
		if q.name == name {
			return q.values
		}
	}
	return nil
}

has_param_value :: proc(p: ^Prop, name, v: string) -> bool {
	for q in p.params {
		if q.name != name {
			continue
		}
		for x in q.values {
			if strings.equal_fold(x, v) {
				return true
			}
		}
	}
	return false
}

children :: proc(c: ^Component, name: string, allocator := context.temp_allocator) -> []^Component {
	out := make([dynamic]^Component, 0, 2, allocator)
	for ch in c.children {
		if ch.name == name {
			append(&out, ch)
		}
	}
	return out[:]
}

child :: proc(c: ^Component, name: string) -> ^Component {
	for ch in c.children {
		if ch.name == name {
			return ch
		}
	}
	return nil
}

// set_prop replaces the first property of that name (dropping any others),
// or appends it.
set_prop :: proc(c: ^Component, name, raw_value: string, params: []Param = nil) {
	idx := -1
	for i := 0; i < len(c.props); {
		if c.props[i].name == name {
			if idx < 0 {
				idx = i
				i += 1
			} else {
				ordered_remove(&c.props, i)
			}
			continue
		}
		i += 1
	}
	np := Prop{name = name, value = raw_value, params = params}
	if idx >= 0 {
		c.props[idx] = np
	} else {
		append(&c.props, np)
	}
}

remove_props :: proc(c: ^Component, name: string) {
	for i := 0; i < len(c.props); {
		if c.props[i].name == name {
			ordered_remove(&c.props, i)
		} else {
			i += 1
		}
	}
}

set_param :: proc(p: ^Prop, name, v: string) {
	out := make([dynamic]Param, 0, len(p.params) + 1)
	done := false
	for q in p.params {
		if q.name == name {
			if !done {
				vals := make([]string, 1)
				vals[0] = v
				append(&out, Param{name = name, values = vals})
				done = true
			}
			continue
		}
		append(&out, q)
	}
	if !done {
		vals := make([]string, 1)
		vals[0] = v
		append(&out, Param{name = name, values = vals})
	}
	p.params = out[:]
}

remove_param :: proc(p: ^Prop, name: string) {
	out := make([dynamic]Param, 0, len(p.params))
	for q in p.params {
		if q.name != name {
			append(&out, q)
		}
	}
	p.params = out[:]
}

// clone is a deep copy.
clone :: proc(c: ^Component) -> ^Component {
	n := new(Component)
	n.name = c.name
	n.props = make([dynamic]Prop, 0, len(c.props))
	for p in c.props {
		append(&n.props, p)
	}
	n.children = make([dynamic]^Component, 0, len(c.children))
	for ch in c.children {
		append(&n.children, clone(ch))
	}
	return n
}

// ---------------------------------------------------------------------------
// TEXT values
// ---------------------------------------------------------------------------

unescape_text :: proc(s: string) -> string {
	if strings.index_byte(s, '\\') < 0 {
		return s
	}
	sb := strings.builder_make()
	for i := 0; i < len(s); i += 1 {
		if s[i] == '\\' && i + 1 < len(s) {
			i += 1
			switch s[i] {
			case 'n', 'N':
				strings.write_byte(&sb, '\n')
			case:
				strings.write_byte(&sb, s[i])
			}
			continue
		}
		strings.write_byte(&sb, s[i])
	}
	return strings.to_string(sb)
}

escape_text :: proc(s: string) -> string {
	sb := strings.builder_make()
	for i := 0; i < len(s); i += 1 {
		switch s[i] {
		case '\\':
			strings.write_string(&sb, "\\\\")
		case ';':
			strings.write_string(&sb, "\\;")
		case ',':
			strings.write_string(&sb, "\\,")
		case '\n':
			strings.write_string(&sb, "\\n")
		case '\r':
		case:
			strings.write_byte(&sb, s[i])
		}
	}
	return strings.to_string(sb)
}

// split_unescaped splits a structured or list value on `sep`, honouring
// backslash escapes (N is "family;given;additional;prefix;suffix").
split_unescaped :: proc(s: string, sep: byte, allocator := context.allocator) -> []string {
	out := make([dynamic]string, 0, 4, allocator)
	start := 0
	for i := 0; i < len(s); i += 1 {
		if s[i] == '\\' {
			i += 1
			continue
		}
		if s[i] == sep {
			append(&out, s[start:i])
			start = i + 1
		}
	}
	append(&out, s[start:])
	return out[:]
}

// ---------------------------------------------------------------------------
// Writing
// ---------------------------------------------------------------------------

write :: proc(c: ^Component, allocator := context.allocator) -> string {
	sb := strings.builder_make(allocator)
	write_to(&sb, c)
	return strings.to_string(sb)
}

write_to :: proc(sb: ^strings.Builder, c: ^Component) {
	fold_line(sb, strings.concatenate({"BEGIN:", c.name}, context.temp_allocator))
	for &p in c.props {
		fold_line(sb, prop_line(&p))
	}
	for ch in c.children {
		write_to(sb, ch)
	}
	fold_line(sb, strings.concatenate({"END:", c.name}, context.temp_allocator))
}

prop_line :: proc(p: ^Prop) -> string {
	sb := strings.builder_make(context.temp_allocator)
	if p.group != "" {
		strings.write_string(&sb, p.group)
		strings.write_byte(&sb, '.')
	}
	strings.write_string(&sb, p.name)
	for q in p.params {
		strings.write_byte(&sb, ';')
		strings.write_string(&sb, q.name)
		strings.write_byte(&sb, '=')
		for v, k in q.values {
			if k > 0 {
				strings.write_byte(&sb, ',')
			}
			needs_quote := strings.contains_any(v, ":;,")
			if needs_quote {
				strings.write_byte(&sb, '"')
			}
			for i in 0 ..< len(v) {
				switch v[i] {
				case '\n':
					strings.write_string(&sb, "^n")
				case '"':
					strings.write_string(&sb, "^'")
				case '^':
					strings.write_string(&sb, "^^")
				case '\r':
				case:
					strings.write_byte(&sb, v[i])
				}
			}
			if needs_quote {
				strings.write_byte(&sb, '"')
			}
		}
	}
	strings.write_byte(&sb, ':')
	strings.write_string(&sb, p.value)
	return strings.to_string(sb)
}

// fold_line writes a logical line folded at 75 octets, never inside a UTF-8
// sequence, CRLF-terminated.
fold_line :: proc(sb: ^strings.Builder, line: string) {
	limit := 75
	i := 0
	first := true
	for i < len(line) {
		room := first ? limit : limit - 1
		end := min(len(line), i + room)
		if end < len(line) {
			for end > i && (line[end] & 0xc0) == 0x80 {
				end -= 1
			}
		}
		if !first {
			strings.write_byte(sb, ' ')
		}
		strings.write_string(sb, line[i:end])
		strings.write_string(sb, "\r\n")
		i = end
		first = false
	}
	if len(line) == 0 {
		strings.write_string(sb, "\r\n")
	}
}
