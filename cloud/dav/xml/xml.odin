// Package xml is the XML WebDAV needs: a namespace-aware reader for request
// bodies and a writer for multistatus responses.
//
// WebDAV is XML with namespaces taken seriously: <D:prop xmlns:D="DAV:"> and
// <prop xmlns="DAV:"> are the same element, and a client may pick any prefix
// it likes. So the reader resolves every element to (namespace URI, local
// name) and nothing downstream ever sees a prefix. Not a general XML parser:
// no DTDs (a DOCTYPE is skipped, entities in it are not expanded, which is
// also the defence against entity expansion attacks), no processing
// instructions beyond skipping them.
package xml

import "core:strconv"
import "core:strings"
import "core:unicode/utf8"

NS_DAV :: "DAV:"
NS_CALDAV :: "urn:ietf:params:xml:ns:caldav"
NS_CARDDAV :: "urn:ietf:params:xml:ns:carddav"
NS_CS :: "http://calendarserver.org/ns/"
NS_APPLE :: "http://apple.com/ns/ical/"
NS_PALM :: "https://palmframe.dev/ns/dav"

Attr :: struct {
	ns:    string,
	name:  string,
	value: string,
}

Element :: struct {
	ns:       string,
	name:     string,
	attrs:    []Attr,
	children: [dynamic]^Element,
	text:     string, // character data directly inside, concatenated
}

is :: proc(e: ^Element, ns, name: string) -> bool {
	return e != nil && e.name == name && e.ns == ns
}

find :: proc(e: ^Element, ns, name: string) -> ^Element {
	if e == nil {
		return nil
	}
	for c in e.children {
		if c.name == name && c.ns == ns {
			return c
		}
	}
	return nil
}

find_all :: proc(e: ^Element, ns, name: string, allocator := context.temp_allocator) -> []^Element {
	out := make([dynamic]^Element, 0, 4, allocator)
	if e == nil {
		return out[:]
	}
	for c in e.children {
		if c.name == name && c.ns == ns {
			append(&out, c)
		}
	}
	return out[:]
}

attr :: proc(e: ^Element, name: string, ns := "") -> string {
	if e == nil {
		return ""
	}
	for a in e.attrs {
		if a.name == name && a.ns == ns {
			return a.value
		}
	}
	return ""
}

// ---------------------------------------------------------------------------
// Reading
// ---------------------------------------------------------------------------

@(private)
Reader :: struct {
	s:     string,
	i:     int,
	err:   string,
	depth: int,
}

@(private)
Scope :: struct {
	prefix: string,
	uri:    string,
}

parse :: proc(s: string) -> (root: ^Element, err: string) {
	r := Reader{s = s}
	scopes := make([dynamic]Scope, 0, 8, context.temp_allocator)
	append(&scopes, Scope{"xml", "http://www.w3.org/XML/1998/namespace"})
	skip_misc(&r)
	if r.i >= len(r.s) || r.s[r.i] != '<' {
		return nil, "no root element"
	}
	root = element(&r, &scopes)
	if r.err != "" {
		return nil, r.err
	}
	return root, ""
}

@(private)
skip_space :: proc(r: ^Reader) {
	for r.i < len(r.s) && (r.s[r.i] == ' ' || r.s[r.i] == '\t' || r.s[r.i] == '\n' || r.s[r.i] == '\r') {
		r.i += 1
	}
}

// skip_misc passes over the prolog: whitespace, <?...?>, comments, DOCTYPE,
// and a UTF-8 byte order mark.
@(private)
skip_misc :: proc(r: ^Reader) {
	if strings.has_prefix(r.s[r.i:], "\xef\xbb\xbf") {
		r.i += 3
	}
	for {
		skip_space(r)
		rest := r.s[r.i:]
		switch {
		case strings.has_prefix(rest, "<?"):
			end := strings.index(rest, "?>")
			if end < 0 {
				r.i = len(r.s)
				return
			}
			r.i += end + 2
		case strings.has_prefix(rest, "<!--"):
			end := strings.index(rest, "-->")
			if end < 0 {
				r.i = len(r.s)
				return
			}
			r.i += end + 3
		case strings.has_prefix(rest, "<!DOCTYPE"):
			// Skip to the matching '>', allowing one level of [ ... ].
			depth := 0
			k := 0
			for k < len(rest) {
				c := rest[k]
				if c == '[' {
					depth += 1
				} else if c == ']' {
					depth -= 1
				} else if c == '>' && depth <= 0 {
					break
				}
				k += 1
			}
			r.i += min(k + 1, len(rest))
		case:
			return
		}
	}
}

@(private)
name_char :: proc(c: u8) -> bool {
	return c != ' ' && c != '\t' && c != '\n' && c != '\r' && c != '>' && c != '/' && c != '=' && c != '<'
}

@(private)
resolve :: proc(scopes: []Scope, prefix: string) -> (string, bool) {
	#reverse for sc in scopes {
		if sc.prefix == prefix {
			return sc.uri, true
		}
	}
	if prefix == "" {
		return "", true
	}
	return "", false
}

@(private)
split_qname :: proc(q: string) -> (prefix, local: string) {
	if colon := strings.index_byte(q, ':'); colon >= 0 {
		return q[:colon], q[colon + 1:]
	}
	return "", q
}

@(private)
element :: proc(r: ^Reader, scopes: ^[dynamic]Scope) -> ^Element {
	r.depth += 1
	defer r.depth -= 1
	if r.depth > 64 {
		r.err = "the document nests too deeply"
		return nil
	}
	// r.s[r.i] == '<'
	r.i += 1
	start := r.i
	for r.i < len(r.s) && name_char(r.s[r.i]) {
		r.i += 1
	}
	qname := r.s[start:r.i]
	if qname == "" {
		r.err = "an element has no name"
		return nil
	}
	raw_attrs := make([dynamic][2]string, 0, 2, context.temp_allocator)
	self_closing := false
	for {
		skip_space(r)
		if r.i >= len(r.s) {
			r.err = "the document ends inside a tag"
			return nil
		}
		if r.s[r.i] == '/' {
			if r.i + 1 < len(r.s) && r.s[r.i + 1] == '>' {
				r.i += 2
				self_closing = true
				break
			}
			r.err = "a stray '/' in a tag"
			return nil
		}
		if r.s[r.i] == '>' {
			r.i += 1
			break
		}
		as := r.i
		for r.i < len(r.s) && name_char(r.s[r.i]) {
			r.i += 1
		}
		aname := r.s[as:r.i]
		skip_space(r)
		if r.i >= len(r.s) || r.s[r.i] != '=' {
			r.err = "an attribute has no value"
			return nil
		}
		r.i += 1
		skip_space(r)
		if r.i >= len(r.s) || (r.s[r.i] != '"' && r.s[r.i] != '\'') {
			r.err = "an attribute value is not quoted"
			return nil
		}
		q := r.s[r.i]
		r.i += 1
		vs := r.i
		for r.i < len(r.s) && r.s[r.i] != q {
			r.i += 1
		}
		if r.i >= len(r.s) {
			r.err = "an attribute value is not closed"
			return nil
		}
		append(&raw_attrs, [2]string{aname, decode_entities(r.s[vs:r.i])})
		r.i += 1
	}

	mark := len(scopes)
	for a in raw_attrs {
		if a[0] == "xmlns" {
			append(scopes, Scope{"", a[1]})
		} else if strings.has_prefix(a[0], "xmlns:") {
			append(scopes, Scope{a[0][6:], a[1]})
		}
	}
	defer resize(scopes, mark)

	e := new(Element)
	prefix, local := split_qname(qname)
	uri, ok := resolve(scopes[:], prefix)
	if !ok {
		r.err = strings.concatenate({"an undeclared namespace prefix: ", prefix})
		return nil
	}
	e.ns = uri
	e.name = local
	attrs := make([dynamic]Attr, 0, len(raw_attrs))
	for a in raw_attrs {
		if a[0] == "xmlns" || strings.has_prefix(a[0], "xmlns:") {
			continue
		}
		ap, al := split_qname(a[0])
		ans := ""
		if ap != "" {
			ans, _ = resolve(scopes[:], ap)
		}
		append(&attrs, Attr{ans, al, a[1]})
	}
	e.attrs = attrs[:]
	e.children = make([dynamic]^Element, 0, 0)
	if self_closing {
		return e
	}

	sb := strings.builder_make(context.temp_allocator)
	for {
		if r.i >= len(r.s) {
			r.err = "an element is not closed"
			return nil
		}
		rest := r.s[r.i:]
		switch {
		case strings.has_prefix(rest, "</"):
			end := strings.index_byte(rest, '>')
			if end < 0 {
				r.err = "a closing tag is not closed"
				return nil
			}
			closing := strings.trim_space(rest[2:end])
			if closing != qname {
				r.err = "a closing tag does not match"
				return nil
			}
			r.i += end + 1
			e.text = strings.clone(strings.to_string(sb))
			return e
		case strings.has_prefix(rest, "<!--"):
			end := strings.index(rest, "-->")
			if end < 0 {
				r.err = "a comment is not closed"
				return nil
			}
			r.i += end + 3
		case strings.has_prefix(rest, "<![CDATA["):
			end := strings.index(rest, "]]>")
			if end < 0 {
				r.err = "a CDATA section is not closed"
				return nil
			}
			strings.write_string(&sb, rest[9:end])
			r.i += end + 3
		case strings.has_prefix(rest, "<?"):
			end := strings.index(rest, "?>")
			if end < 0 {
				r.err = "a processing instruction is not closed"
				return nil
			}
			r.i += end + 2
		case rest[0] == '<':
			c := element(r, scopes)
			if c == nil {
				return nil
			}
			append(&e.children, c)
		case:
			end := strings.index_byte(rest, '<')
			if end < 0 {
				end = len(rest)
			}
			strings.write_string(&sb, decode_entities(rest[:end]))
			r.i += end
		}
	}
}

decode_entities :: proc(s: string) -> string {
	if strings.index_byte(s, '&') < 0 {
		return s
	}
	sb := strings.builder_make()
	i := 0
	for i < len(s) {
		if s[i] != '&' {
			strings.write_byte(&sb, s[i])
			i += 1
			continue
		}
		semi := strings.index_byte(s[i:], ';')
		if semi < 0 || semi > 10 {
			strings.write_byte(&sb, '&')
			i += 1
			continue
		}
		ent := s[i + 1:i + semi]
		switch ent {
		case "lt": strings.write_byte(&sb, '<')
		case "gt": strings.write_byte(&sb, '>')
		case "amp": strings.write_byte(&sb, '&')
		case "quot": strings.write_byte(&sb, '"')
		case "apos": strings.write_byte(&sb, '\'')
		case:
			if len(ent) > 1 && ent[0] == '#' {
				v: u64
				ok: bool
				if ent[1] == 'x' || ent[1] == 'X' {
					v, ok = strconv.parse_u64_of_base(ent[2:], 16)
				} else {
					v, ok = strconv.parse_u64_of_base(ent[1:], 10)
				}
				if ok && v < 0x110000 {
					strings.write_rune(&sb, rune(v))
				}
			} else {
				strings.write_string(&sb, s[i:i + semi + 1])
			}
		}
		i += semi + 1
	}
	return strings.to_string(sb)
}

// ---------------------------------------------------------------------------
// Writing
// ---------------------------------------------------------------------------

// The prefixes a response uses. Anything else is declared where it is used.
@(private)
PREFIXES := [?][2]string {
	{NS_DAV, "d"},
	{NS_CALDAV, "cal"},
	{NS_CARDDAV, "card"},
	{NS_CS, "cs"},
	{NS_APPLE, "ical"},
	{NS_PALM, "palm"},
}

prefix_of :: proc(ns: string) -> string {
	for p in PREFIXES {
		if p[0] == ns {
			return p[1]
		}
	}
	return ""
}

Writer :: struct {
	sb:    strings.Builder,
	stack: [dynamic]string, // qualified names to close
	extra: int, // counter for undeclared namespaces
}

writer_make :: proc(allocator := context.allocator) -> Writer {
	w := Writer{sb = strings.builder_make(allocator), stack = make([dynamic]string, 0, 16, allocator)}
	strings.write_string(&w.sb, `<?xml version="1.0" encoding="utf-8"?>` + "\n")
	return w
}

@(private)
qname :: proc(w: ^Writer, ns, name: string) -> (q: string, decl: string) {
	if p := prefix_of(ns); p != "" {
		return strings.concatenate({p, ":", name}), ""
	}
	if ns == "" {
		return name, ""
	}
	w.extra += 1
	p := strings.concatenate({"x", int_str(w.extra)})
	return strings.concatenate({p, ":", name}), strings.concatenate({" xmlns:", p, "=\"", escape(ns), "\""})
}

@(private)
int_str :: proc(n: int) -> string {
	buf: [20]u8
	return strings.clone(strconv.write_int(buf[:], i64(n), 10))
}

// open writes a start tag. The root carries the namespace declarations.
open :: proc(w: ^Writer, ns, name: string, attrs: ..[2]string) {
	q, decl := qname(w, ns, name)
	strings.write_byte(&w.sb, '<')
	strings.write_string(&w.sb, q)
	if len(w.stack) == 0 {
		for p in PREFIXES {
			strings.write_string(&w.sb, " xmlns:")
			strings.write_string(&w.sb, p[1])
			strings.write_string(&w.sb, "=\"")
			strings.write_string(&w.sb, p[0])
			strings.write_byte(&w.sb, '"')
		}
	}
	strings.write_string(&w.sb, decl)
	for a in attrs {
		strings.write_byte(&w.sb, ' ')
		strings.write_string(&w.sb, a[0])
		strings.write_string(&w.sb, "=\"")
		strings.write_string(&w.sb, escape(a[1]))
		strings.write_byte(&w.sb, '"')
	}
	strings.write_byte(&w.sb, '>')
	append(&w.stack, q)
}

close :: proc(w: ^Writer) {
	q := pop(&w.stack)
	strings.write_string(&w.sb, "</")
	strings.write_string(&w.sb, q)
	strings.write_byte(&w.sb, '>')
}

// empty writes <x/>.
empty :: proc(w: ^Writer, ns, name: string, attrs: ..[2]string) {
	q, decl := qname(w, ns, name)
	strings.write_byte(&w.sb, '<')
	strings.write_string(&w.sb, q)
	strings.write_string(&w.sb, decl)
	for a in attrs {
		strings.write_byte(&w.sb, ' ')
		strings.write_string(&w.sb, a[0])
		strings.write_string(&w.sb, "=\"")
		strings.write_string(&w.sb, escape(a[1]))
		strings.write_byte(&w.sb, '"')
	}
	strings.write_string(&w.sb, "/>")
}

// leaf writes <x>text</x>, escaped.
leaf :: proc(w: ^Writer, ns, name, text: string) {
	open(w, ns, name)
	strings.write_string(&w.sb, escape(text))
	close(w)
}

// raw_text writes character data, escaped, into the open element.
raw_text :: proc(w: ^Writer, text: string) {
	strings.write_string(&w.sb, escape(text))
}

finish :: proc(w: ^Writer) -> string {
	for len(w.stack) > 0 {
		close(w)
	}
	return strings.to_string(w.sb)
}

escape :: proc(s: string) -> string {
	if strings.index_any(s, "<>&\"\r") < 0 && valid(s) {
		return s
	}
	sb := strings.builder_make()
	for i := 0; i < len(s); i += 1 {
		switch s[i] {
		case '<': strings.write_string(&sb, "&lt;")
		case '>': strings.write_string(&sb, "&gt;")
		case '&': strings.write_string(&sb, "&amp;")
		case '"': strings.write_string(&sb, "&quot;")
		case '\r': strings.write_string(&sb, "&#13;")
		case:
			c := s[i]
			// Control characters other than tab and newline are not XML.
			if c < 0x20 && c != '\t' && c != '\n' {
				continue
			}
			strings.write_byte(&sb, c)
		}
	}
	return strings.to_string(sb)
}

@(private)
valid :: proc(s: string) -> bool {
	for i in 0 ..< len(s) {
		if s[i] < 0x20 && s[i] != '\t' && s[i] != '\n' {
			return false
		}
	}
	return utf8.valid_string(s)
}
