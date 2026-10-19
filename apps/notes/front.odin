// Front matter: the few facts about a note that are not its text.
//
//	---
//	id: 7f3c2a1e-…            the note's stable id, which is also its sync id
//	tags: [travel, q4]
//	pinned: true
//	shared_from: alice.martin  (a note someone shared with this identity)
//	access: read
//	carried_from: northwind/…  (where a carried copy came from, for the reader)
//	---
//	# Title
//
// It is YAML-shaped so every other Markdown tool (Obsidian, Hugo, pandoc)
// reads it, but only this flat subset is understood. Keys this file does not
// know are kept exactly as they were written, in order, so a note that carries
// someone's own `aliases:` or `date:` survives being saved here.
//
// A note with no front matter at all is still a note: it gets an id the first
// time it is synced, and until then it is identified by its file.
package main

import "core:crypto"
import "core:fmt"
import "core:strings"

Meta :: struct {
	id:           string,
	tags:         [dynamic]string,
	pinned:       bool,
	shared_from:  string,
	access:       string, // "read" or "edit" on a shared note
	carried_from: string,
	extra:        string, // unknown lines, verbatim
}

meta_free :: proc(m: ^Meta) {
	delete(m.id)
	for t in m.tags {delete(t)}
	delete(m.tags)
	delete(m.shared_from)
	delete(m.access)
	delete(m.carried_from)
	delete(m.extra)
	m^ = {}
}

meta_clone :: proc(m: Meta, allocator := context.allocator) -> Meta {
	out := Meta {
		id           = strings.clone(m.id, allocator),
		pinned       = m.pinned,
		shared_from  = strings.clone(m.shared_from, allocator),
		access       = strings.clone(m.access, allocator),
		carried_from = strings.clone(m.carried_from, allocator),
		extra        = strings.clone(m.extra, allocator),
	}
	out.tags = make([dynamic]string, 0, len(m.tags), allocator)
	for t in m.tags {append(&out.tags, strings.clone(t, allocator))}
	return out
}

// split_front separates a file into its front matter (without the fences)
// and its Markdown body. A file that does not open with `---` on its own line
// has none, and a fence that is never closed is not front matter either —
// it is a horizontal rule at the top of somebody's note.
split_front :: proc(text: string) -> (front: string, body: string, has: bool) {
	t := text
	if strings.has_prefix(t, "\xef\xbb\xbf") {
		t = t[3:]
	}
	if !strings.has_prefix(t, "---\n") && !strings.has_prefix(t, "---\r\n") {
		return "", text, false
	}
	start := strings.index_byte(t, '\n') + 1
	i := start
	for i <= len(t) {
		nl := strings.index_byte(t[i:], '\n')
		line := nl < 0 ? t[i:] : t[i:i + nl]
		line = strings.trim_right(line, "\r")
		if line == "---" || line == "..." {
			after := nl < 0 ? len(t) : i + nl + 1
			// One blank line after the fence is part of the layout, not the body.
			b := t[after:]
			if strings.has_prefix(b, "\n") {
				b = b[1:]
			}
			return t[start:i], b, true
		}
		if nl < 0 {
			break
		}
		i += nl + 1
	}
	return "", text, false
}

// parse_front reads the subset: `key: value`, `key: [a, b]`, and a list
// written as `key:` followed by `- item` lines.
parse_front :: proc(front: string, allocator := context.allocator) -> Meta {
	m := Meta{}
	m.tags = make([dynamic]string, allocator)
	extra := strings.builder_make(allocator)
	rest := front
	list_key := ""
	for line in strings.split_lines_iterator(&rest) {
		raw := strings.trim_right(line, "\r")
		t := strings.trim_space(raw)
		if list_key != "" && strings.has_prefix(t, "- ") {
			if list_key == "tags" {
				add_tag(&m.tags, strings.trim_space(t[2:]), allocator)
			} else {
				strings.write_string(&extra, raw)
				strings.write_byte(&extra, '\n')
			}
			continue
		}
		list_key = ""
		colon := strings.index_byte(t, ':')
		if colon <= 0 {
			if t != "" {
				strings.write_string(&extra, raw)
				strings.write_byte(&extra, '\n')
			}
			continue
		}
		key := strings.trim_space(t[:colon])
		val := unquote(strings.trim_space(t[colon + 1:]))
		switch key {
		case "id":
			m.id = strings.clone(val, allocator)
		case "pinned":
			m.pinned = val == "true" || val == "yes"
		case "shared_from":
			m.shared_from = strings.clone(val, allocator)
		case "access":
			m.access = strings.clone(val, allocator)
		case "carried_from":
			m.carried_from = strings.clone(val, allocator)
		case "tags":
			if val == "" {
				list_key = "tags"
			} else {
				for tag in parse_list(val, context.temp_allocator) {
					add_tag(&m.tags, tag, allocator)
				}
			}
		case:
			if val == "" {
				list_key = key
			}
			strings.write_string(&extra, raw)
			strings.write_byte(&extra, '\n')
		}
	}
	m.extra = strings.to_string(extra)
	return m
}

@(private = "file")
unquote :: proc(s: string) -> string {
	if len(s) >= 2 && ((s[0] == '"' && s[len(s) - 1] == '"') || (s[0] == '\'' && s[len(s) - 1] == '\'')) {
		return s[1:len(s) - 1]
	}
	return s
}

@(private = "file")
parse_list :: proc(v: string, allocator := context.temp_allocator) -> []string {
	s := strings.trim_space(v)
	s = strings.trim_prefix(s, "[")
	s = strings.trim_suffix(s, "]")
	out := make([dynamic]string, allocator)
	for part in strings.split(s, ",", context.temp_allocator) {
		p := unquote(strings.trim_space(part))
		if p != "" {
			append(&out, p)
		}
	}
	return out[:]
}

// add_tag normalises a tag (no leading #, lower case, no spaces) and keeps
// the list free of duplicates.
add_tag :: proc(tags: ^[dynamic]string, raw: string, allocator := context.allocator) {
	t := strings.trim_space(strings.trim_left(strings.trim_space(raw), "#"))
	if t == "" {
		return
	}
	low := strings.to_lower(t, context.temp_allocator)
	low, _ = strings.replace_all(low, " ", "-", context.temp_allocator)
	for x in tags {
		if x == low {
			return
		}
	}
	append(tags, strings.clone(low, allocator))
}

// render_front writes the front matter back, or nothing when there is
// nothing to say. The order is fixed, so saving twice changes no bytes.
render_front :: proc(m: Meta, allocator := context.temp_allocator) -> string {
	if m.id == "" && len(m.tags) == 0 && !m.pinned && m.shared_from == "" && m.carried_from == "" && m.extra == "" {
		return ""
	}
	b := strings.builder_make(allocator)
	strings.write_string(&b, "---\n")
	if m.id != "" {
		fmt.sbprintf(&b, "id: %s\n", m.id)
	}
	if len(m.tags) > 0 {
		strings.write_string(&b, "tags: [")
		for t, i in m.tags {
			if i > 0 {strings.write_string(&b, ", ")}
			strings.write_string(&b, t)
		}
		strings.write_string(&b, "]\n")
	}
	if m.pinned {
		strings.write_string(&b, "pinned: true\n")
	}
	if m.shared_from != "" {
		fmt.sbprintf(&b, "shared_from: %s\n", m.shared_from)
		if m.access != "" {
			fmt.sbprintf(&b, "access: %s\n", m.access)
		}
	}
	if m.carried_from != "" {
		fmt.sbprintf(&b, "carried_from: %s\n", m.carried_from)
	}
	strings.write_string(&b, m.extra)
	strings.write_string(&b, "---\n\n")
	return strings.to_string(b)
}

// compose is the whole file for a note: front matter, then the body.
compose :: proc(m: Meta, body: string, allocator := context.temp_allocator) -> string {
	return strings.concatenate({render_front(m, context.temp_allocator), body}, allocator)
}

// new_id is a random (version 4) UUID: what the cloud keys the note by, and
// chosen here so a note created offline already has its final id.
new_id :: proc(allocator := context.allocator) -> string {
	b: [16]u8
	crypto.rand_bytes(b[:])
	b[6] = (b[6] & 0x0f) | 0x40
	b[8] = (b[8] & 0x3f) | 0x80
	return fmt.aprintf(
		"%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x",
		b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15],
		allocator = allocator,
	)
}

is_uuid :: proc(s: string) -> bool {
	if len(s) != 36 {
		return false
	}
	for c, i in transmute([]u8)s {
		if i == 8 || i == 13 || i == 18 || i == 23 {
			if c != '-' {return false}
			continue
		}
		if !((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) {
			return false
		}
	}
	return true
}

// inline_tags finds #hashtags in a body: a # at a word start, followed by a
// letter, outside code. A heading's `# ` never matches because a space
// follows it.
inline_tags :: proc(body: string, out: ^[dynamic]string, allocator := context.allocator) {
	in_code := false
	rest := body
	for line in strings.split_lines_iterator(&rest) {
		if strings.has_prefix(strings.trim_space(line), "```") {
			in_code = !in_code
			continue
		}
		if in_code {
			continue
		}
		tick := false
		for i := 0; i < len(line); i += 1 {
			c := line[i]
			if c == '`' {
				tick = !tick
				continue
			}
			if tick || c != '#' {
				continue
			}
			if i > 0 && !is_space_byte(line[i - 1]) && line[i - 1] != '(' {
				continue
			}
			j := i + 1
			if j >= len(line) || !is_tag_start(line[j]) {
				continue
			}
			for j < len(line) && is_tag_byte(line[j]) {
				j += 1
			}
			add_tag(out, line[i + 1:j], allocator)
			i = j - 1
		}
	}
}

@(private = "file")
is_tag_start :: proc(c: u8) -> bool {
	return (c | 32 >= 'a' && c | 32 <= 'z') || c >= 0x80
}

@(private = "file")
is_tag_byte :: proc(c: u8) -> bool {
	return is_tag_start(c) || (c >= '0' && c <= '9') || c == '-' || c == '_' || c == '/'
}
