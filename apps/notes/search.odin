// Search across the identities on this device. Local first: it reads the
// files, so it works on a plane, and nothing about a query leaves the machine.
//
// A query is words, all of which must appear (title, body or tags), plus
// operators, which product.md §6 defines for every app:
//
//	in:northwind     only that identity (a scoped process has only its own)
//	tag:travel       #travel    a tag, from front matter or a #hashtag
//	notebook:Travel  a folder
//	is:pinned  is:shared  is:trashed  (the trash is left out otherwise)
//
// Unknown operators are reported, never silently ignored. Every result
// carries its identity, so a mixed list is always labelled.
//
// Ranking: a title hit beats a tag hit beats body hits; then pinned; then
// the newest. It is a scan, not an index: a few thousand notes of a few KB
// each are read in milliseconds, and a scan cannot go stale.
package main

import "core:slice"
import "core:strings"

Hit :: struct {
	note:     int,
	score:    int,
	in_title: bool,
	hits:     int, // matching body lines
	line:     string, // the first matching line
}

Query :: struct {
	words:    [dynamic]string,
	ident:    string, // in:
	tags:     [dynamic]string,
	notebook: string,
	pinned:   bool,
	shared:   bool,
	trashed:  bool,
	unknown:  [dynamic]string, // operators this does not understand
}

parse_query :: proc(q: string, allocator := context.temp_allocator) -> Query {
	out := Query{}
	out.words = make([dynamic]string, allocator)
	out.tags = make([dynamic]string, allocator)
	out.unknown = make([dynamic]string, allocator)
	for w in strings.fields(q, allocator) {
		switch {
		case strings.has_prefix(w, "in:"):
			out.ident = w[3:]
		case strings.has_prefix(w, "tag:"):
			add_tag(&out.tags, w[4:], allocator)
		case strings.has_prefix(w, "#") && len(w) > 1:
			add_tag(&out.tags, w[1:], allocator)
		case strings.has_prefix(w, "notebook:"):
			out.notebook = w[9:]
		case w == "is:pinned":
			out.pinned = true
		case w == "is:shared":
			out.shared = true
		case w == "is:trashed":
			out.trashed = true
		case strings.contains(w, ":") && !strings.contains(w, "://") && strings.index_byte(w, ':') > 1 &&
		     strings.index_byte(w, ':') < len(w) - 1 && is_operator_word(w[:strings.index_byte(w, ':')]):
			append(&out.unknown, w)
		case:
			append(&out.words, w)
		}
	}
	return out
}

@(private = "file")
is_operator_word :: proc(s: string) -> bool {
	for c in transmute([]u8)s {
		if !(c >= 'a' && c <= 'z') {
			return false
		}
	}
	return true
}

// search_notes runs a query over notes from any number of identities.
// `handles[i]` is identity i's handle, for `in:`.
search_notes :: proc(all: []Note, handles: []string, q: Query, allocator := context.temp_allocator) -> []Hit {
	out := make([dynamic]Hit, allocator)
	for n, i in all {
		if q.trashed != n.trashed {
			continue
		}
		if q.ident != "" && (n.ident < 0 || n.ident >= len(handles) || !strings.equal_fold(handles[n.ident], q.ident)) {
			continue
		}
		if q.pinned && !n.meta.pinned {
			continue
		}
		if q.shared && !n.shared {
			continue
		}
		if q.notebook != "" && !strings.equal_fold(n.notebook, q.notebook) &&
		   !strings.has_prefix(strings.to_lower(n.notebook, context.temp_allocator), strings.to_lower(q.notebook, context.temp_allocator)) {
			continue
		}
		tag_ok := true
		for t in q.tags {
			found := false
			for x in n.tags {
				if x == t || strings.has_prefix(x, tfmt("%s/", t)) {
					found = true
				}
			}
			if !found {
				tag_ok = false
			}
		}
		if !tag_ok {
			continue
		}

		h := Hit{note = i}
		all_words := true
		for w in q.words {
			in_title := contains_fold(n.title, w)
			in_tags := false
			for x in n.tags {
				if contains_fold(x, w) {in_tags = true}
			}
			in_body := contains_fold(n.body, w)
			if !in_title && !in_tags && !in_body {
				all_words = false
				break
			}
			if in_title {
				h.in_title = true
				h.score += 100
			} else if in_tags {
				h.score += 40
			}
		}
		if !all_words {
			continue
		}
		if len(q.words) > 0 {
			rest := n.body
			for line in strings.split_lines_iterator(&rest) {
				hit := false
				for w in q.words {
					if contains_fold(line, w) {
						hit = true
					}
				}
				if hit {
					h.hits += 1
					if h.line == "" {
						t := strings.trim_space(line)
						if len(t) > 140 {
							t = t[:140]
						}
						h.line = t
					}
				}
			}
			h.score += min(h.hits, 10) * 10
		}
		if n.meta.pinned {
			h.score += 5
		}
		append(&out, h)
	}
	ctx := all
	slice.sort_by(out[:], proc(a, b: Hit) -> bool {
		if a.score != b.score {
			return a.score > b.score
		}
		return a.note < b.note // store_load's order: pinned, then newest
	})
	_ = ctx
	return out[:]
}
