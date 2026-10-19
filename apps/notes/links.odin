// [[Wiki links]] and backlinks, inside one identity.
//
//	[[Lisbon trip]]            a note of this identity, by title (or file name)
//	[[Lisbon trip|the trip]]   the same, shown as "the trip"
//	[[Lisbon trip#Hotels]]     a heading in it (followed to the note)
//	[[northwind:Q4 plan]]      a note of *another* of your identities
//
// The rule for crossing is the product's (cloud/docs/product.md P4): nothing
// crosses silently. An unqualified link resolves only among this identity's
// notes — including notes shared *with* it, which it can already read — and
// never falls through to another identity's note of the same name; with no
// match it is an unresolved link that offers to create the note here.
//
// A qualified link names another identity on purpose. It is drawn as a link
// *out* (the target identity's colour and name, never the target's content),
// following it opens the note in that identity's own scope with a one-line
// notice (P1), and it never creates a backlink there: the target identity
// does not learn that another identity points at it. A scoped session — an
// assistant — cannot follow it at all; `notes links` reports it as out of
// scope and `notes open` exits 5.
package main

import "core:strings"

Link :: struct {
	target: string, // as written, without qualifier, alias or heading
	handle: string, // the identity qualifier, "" for none
	alias:  string,
	head:   string,
	from:   int, // byte range of the whole [[...]] in the body
	to:     int,
}

Link_Kind :: enum u8 {
	Resolved, // a note of this identity (or shared with it)
	Unresolved, // nothing of that name here: create it?
	Elsewhere, // a qualified link to another of your identities
}

links_in :: proc(body: string, allocator := context.temp_allocator) -> []Link {
	out := make([dynamic]Link, allocator)
	in_code := false
	off := 0
	rest := body
	for line in strings.split_lines_iterator(&rest) {
		defer off += len(line) + 1
		if strings.has_prefix(strings.trim_space(line), "```") {
			in_code = !in_code
			continue
		}
		if in_code {
			continue
		}
		i := 0
		for i + 4 <= len(line) {
			if line[i] == '[' && line[i + 1] == '[' {
				end := strings.index(line[i + 2:], "]]")
				if end > 0 {
					inner := line[i + 2:i + 2 + end]
					if l, ok := parse_link(inner); ok {
						l.from = off + i
						l.to = off + i + 2 + end + 2
						append(&out, l)
					}
					i += end + 4
					continue
				}
			}
			i += 1
		}
	}
	return out[:]
}

parse_link :: proc(inner: string) -> (l: Link, ok: bool) {
	s := strings.trim_space(inner)
	if s == "" || strings.contains(s, "[[") {
		return {}, false
	}
	if bar := strings.index_byte(s, '|'); bar >= 0 {
		l.alias = strings.trim_space(s[bar + 1:])
		s = strings.trim_space(s[:bar])
	}
	if hash := strings.index_byte(s, '#'); hash >= 0 {
		l.head = strings.trim_space(s[hash + 1:])
		s = strings.trim_space(s[:hash])
	}
	// A qualifier is a handle followed by a colon, and a handle has no
	// spaces: "Meeting: Tuesday" is a title, "northwind:Q4" is a qualifier.
	if colon := strings.index_byte(s, ':'); colon > 0 {
		h := s[:colon]
		if handle_like(h) {
			l.handle = h
			s = strings.trim_space(s[colon + 1:])
		}
	}
	l.target = s
	return l, l.target != ""
}

@(private = "file")
handle_like :: proc(h: string) -> bool {
	if len(h) < 2 || len(h) > 63 {
		return false
	}
	for c in transmute([]u8)h {
		ok := (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '.' || c == '_' || c == '-'
		if !ok {
			return false
		}
	}
	return true
}

// link_resolve finds the note a link means, among the notes of identity
// `ident` only. `handles` maps identity index to handle, so a link
// qualified with this identity's own handle is treated as unqualified.
link_resolve :: proc(all: []Note, ident: int, own_handle: string, l: Link) -> (Link_Kind, int) {
	if l.handle != "" && l.handle != own_handle {
		return .Elsewhere, -1
	}
	want := l.target
	want_slug := slug(want)
	// A title, then a file name, then a case-insensitive title.
	for n, i in all {
		if n.ident == ident && !n.trashed && n.title == want {
			return .Resolved, i
		}
	}
	for n, i in all {
		if n.ident == ident && !n.trashed && strings.trim_suffix(base_name(n.path), ".md") == want_slug {
			return .Resolved, i
		}
	}
	for n, i in all {
		if n.ident == ident && !n.trashed && strings.equal_fold(n.title, want) {
			return .Resolved, i
		}
	}
	return .Unresolved, -1
}

// backlinks lists the notes of the same identity that link to `target`.
// Links from other identities never count: the target identity does not get
// to see who in another identity points at it.
backlinks :: proc(all: []Note, target: int, own_handle: string, allocator := context.temp_allocator) -> []int {
	out := make([dynamic]int, allocator)
	t := all[target]
	for n, i in all {
		if i == target || n.ident != t.ident || n.trashed {
			continue
		}
		for l in links_in(n.body) {
			kind, at := link_resolve(all, n.ident, own_handle, l)
			if kind == .Resolved && at == target {
				append(&out, i)
				break
			}
		}
	}
	return out[:]
}

// link_context is the line around a backlink, for the panel: where the other
// note mentions this one.
link_context :: proc(body: string, l: Link) -> string {
	start := l.from
	for start > 0 && body[start - 1] != '\n' {
		start -= 1
	}
	end := l.to
	for end < len(body) && body[end] != '\n' {
		end += 1
	}
	t := strings.trim_space(body[start:end])
	t = strings.trim_left(t, "-*> #")
	if len(t) > 140 {
		t = t[:140]
	}
	return t
}
