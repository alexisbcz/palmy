// Universal search: one query over every kind of thing, in every identity the
// window is allowed to see, answered from the local index.
//
// The query language is small on purpose. Plain words must all appear
// (title, people, detail, app). Three operators narrow:
//
//	in:northwind   only that identity (name, handle or kind: in:work)
//	type:mail      mail, event, task, doc, file, chat, person
//	is:unread      only unread
//
// Results come back grouped by kind, ranked inside a group: a hit in the
// title beats a hit in a person's name beats a hit in the body, and recent
// beats old. Every result keeps its identity, so the list can label it.
package main

import "core:slice"
import "core:strings"

Query :: struct {
	terms:    [dynamic]string,
	ident:    int, // -1 = any
	kind:     Maybe(Kind),
	unread:   bool,
	bad:      string, // an operator we did not understand, shown to the user
}

Hit :: struct {
	item:  int,
	score: f32,
}

Results :: struct {
	hits:     [dynamic]Hit, // grouped by kind, then by score
	per_kind: [Kind]int,
	per_id:   [8]int, // per identity, before the identity filter applies
	scanned:  int,
}

KIND_WORDS := [Kind]string {
	.Mail   = "mail",
	.Event  = "event",
	.Task   = "task",
	.Doc    = "doc",
	.File   = "file",
	.Chat   = "chat",
	.Person = "person",
}

identity_by_word :: proc(s: ^Store, w: string) -> int {
	for id, i in s.identities {
		if strings.has_prefix(strings.to_lower(id.name, context.temp_allocator), w) ||
		   strings.has_prefix(id.handle, w) {
			return i
		}
	}
	for id, i in s.identities {
		kind := strings.to_lower(tfmt("%v", id.kind), context.temp_allocator)
		if strings.has_prefix(kind, w) {
			return i
		}
	}
	return -1
}

parse_query :: proc(s: ^Store, text: string) -> Query {
	q := Query{ident = -1}
	q.terms = make([dynamic]string, context.temp_allocator)
	lower := strings.to_lower(text, context.temp_allocator)
	for tok in strings.fields(lower, context.temp_allocator) {
		switch {
		case strings.has_prefix(tok, "in:") && len(tok) > 3:
			q.ident = identity_by_word(s, tok[3:])
			if q.ident < 0 {
				q.bad = tok
			}
		case strings.has_prefix(tok, "type:") && len(tok) > 5:
			found := false
			for w, k in KIND_WORDS {
				if strings.has_prefix(w, tok[5:]) {
					q.kind = k
					found = true
					break
				}
			}
			if !found {
				q.bad = tok
			}
		case tok == "is:unread":
			q.unread = true
		case:
			append(&q.terms, tok)
		}
	}
	return q
}

contains :: proc(hay, needle: string) -> bool {
	return strings.contains(strings.to_lower(hay, context.temp_allocator), needle)
}

search :: proc(s: ^Store, text: string, filter_ident: int) -> Results {
	r: Results
	r.hits = make([dynamic]Hit, context.temp_allocator)
	q := parse_query(s, text)
	if len(q.terms) == 0 && q.ident < 0 && q.kind == nil && !q.unread {
		return r
	}
	// An identity chosen in the window narrows exactly like `in:` does; the
	// two together must agree or nothing matches.
	want_ident := q.ident
	if filter_ident >= 0 {
		if want_ident >= 0 && want_ident != filter_ident {
			return r
		}
		want_ident = filter_ident
	}

	for it, i in s.items {
		r.scanned += 1
		if k, ok := q.kind.?; ok && it.kind != k {
			continue
		}
		if q.unread && !it.unread {
			continue
		}
		score: f32 = 0
		all := true
		for t in q.terms {
			hit := false
			if contains(it.title, t) {
				score += 3
				hit = true
			}
			if contains(it.who, t) {
				score += 2
				hit = true
			}
			if contains(it.detail, t) || contains(it.app, t) {
				score += 1
				hit = true
			}
			if !hit {
				all = false
				break
			}
		}
		if !all {
			continue
		}
		if it.unread {
			score += 0.5
		}
		score += max(0, 2 - f32(abs(it.day)) * 0.15)
		// Counted before the identity filter, so the chips can say how many
		// each identity would show.
		if it.ident < len(r.per_id) {
			r.per_id[it.ident] += 1
		}
		if want_ident >= 0 && it.ident != want_ident {
			continue
		}
		append(&r.hits, Hit{i, score})
		r.per_kind[it.kind] += 1
	}

	items := s.items[:]
	context.user_ptr = &items
	slice.sort_by(r.hits[:], proc(a, b: Hit) -> bool {
		items := (^[]Item)(context.user_ptr)^
		ka, kb := items[a.item].kind, items[b.item].kind
		if ka != kb {
			return ka < kb
		}
		return a.score > b.score
	})
	return r
}

// split_match cuts `text` around the first occurrence of any term, for
// drawing the matched part in bold. Case-insensitive, byte offsets.
split_match :: proc(text: string, terms: []string) -> (pre, mid, post: string) {
	lower := strings.to_lower(text, context.temp_allocator)
	best, blen := -1, 0
	for t in terms {
		if t == "" {
			continue
		}
		at := strings.index(lower, t)
		if at >= 0 && (best < 0 || at < best) {
			best, blen = at, len(t)
		}
	}
	// to_lower can change byte lengths outside ASCII; only trust offsets when
	// it did not.
	if best < 0 || len(lower) != len(text) {
		return text, "", ""
	}
	return text[:best], text[best:best + blen], text[best + blen:]
}
