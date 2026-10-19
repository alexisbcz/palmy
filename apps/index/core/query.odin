// The query language (product.md §6, specified in cloud/docs/search.md).
//
//	plain words        all must match, in any field; the last one is a
//	                   prefix while typing ("road" finds roadmap)
//	"two words"        an exact phrase, required
//	-word              must not match
//	in:northwind       one identity, by name, handle or kind (in:work); may
//	                   repeat, and then means either
//	type:mail          mail event task doc file note chat person page issue
//	                   (plurals and a few synonyms: email, meeting, todo, pr…)
//	is:unread is:read is:waiting is:flagged is:done
//	has:attachment
//	from:priya         the word must be in the people field (sender,
//	with:priya         organiser, author) — `with:` is the same
//	before:2026-10-01  dates are YYYY-MM-DD, YYYY-MM, or today, yesterday,
//	after:7d           Nd, Nw, Nm, Ny (that long ago)
//
// An operator this list does not know is reported in `unknown`, and the
// search runs without it rather than silently dropping it or failing. Words
// that only look like operators (10:30, https://…) are plain words.
package indexcore

import "core:strconv"
import "core:strings"
import "core:time"

Field :: enum u8 {
	Any,
	Who,
}

Term :: struct {
	text:   string, // normalized
	prefix: bool, // as-you-type: the word is still being typed
	field:  Field,
}

Query :: struct {
	raw:       string,
	terms:     [dynamic]Term, // required, ANDed
	phrases:   [dynamic][]string, // each a required run of terms
	not:       [dynamic]string,
	in_words:  [dynamic]string, // identity words, resolved by the caller
	kinds:     bit_set[Kind],
	want:      Flags, // flags a result must have
	unwant:    Flags, // flags a result must not have
	after:     i64, // unix, 0 = open
	before:    i64,
	unknown:   [dynamic]string,
}

query_empty :: proc(q: ^Query) -> bool {
	return len(q.terms) == 0 && len(q.phrases) == 0 && q.kinds == {} && q.want == {} && q.unwant == {} && q.after == 0 && q.before == 0 && len(q.in_words) == 0
}

// has_text says the query has words, as opposed to only filters.
query_has_text :: proc(q: ^Query) -> bool {
	return len(q.terms) > 0 || len(q.phrases) > 0
}

KIND_WORDS := [?]struct {
	word: string,
	kind: Kind,
}{
	{"mail", .Mail}, {"mails", .Mail}, {"email", .Mail}, {"emails", .Mail}, {"message", .Mail},
	{"event", .Event}, {"events", .Event}, {"meeting", .Event}, {"meetings", .Event}, {"calendar", .Event},
	{"task", .Task}, {"tasks", .Task}, {"todo", .Task}, {"todos", .Task},
	{"doc", .Doc}, {"docs", .Doc}, {"document", .Doc}, {"documents", .Doc}, {"sheet", .Doc}, {"slides", .Doc},
	{"file", .File}, {"files", .File},
	{"note", .Note}, {"notes", .Note},
	{"chat", .Chat}, {"chats", .Chat},
	{"person", .Person}, {"people", .Person}, {"contact", .Person}, {"contacts", .Person},
	{"page", .Page}, {"pages", .Page}, {"web", .Page}, {"bookmark", .Page}, {"bookmarks", .Page}, {"history", .Page},
	{"issue", .Issue}, {"issues", .Issue}, {"pr", .Issue}, {"prs", .Issue}, {"pull", .Issue},
}

kind_by_word :: proc(w: string) -> (Kind, bool) {
	for e in KIND_WORDS {
		if e.word == w {
			return e.kind, true
		}
	}
	// A prefix of a canonical name: type:ev, type:pers.
	if len(w) >= 2 {
		for name, k in KIND_NAME {
			if strings.has_prefix(name, w) {
				return k, true
			}
		}
	}
	return .Mail, false
}

@(private)
is_operator_name :: proc(s: string) -> bool {
	if len(s) == 0 || len(s) > 12 {
		return false
	}
	for c in transmute([]u8)s {
		if !(c >= 'a' && c <= 'z') {
			return false
		}
	}
	return true
}

// parse_date reads an absolute or relative date into unix seconds at the
// start of that day (UTC), relative to `now`.
parse_date :: proc(v: string, now: i64) -> (i64, bool) {
	day :: 86400
	today := now - now %% day
	switch v {
	case "today":
		return today, true
	case "yesterday":
		return today - day, true
	case "now":
		return now, true
	}
	if len(v) >= 2 {
		unit := v[len(v) - 1]
		if n, ok := strconv.parse_int(v[:len(v) - 1]); ok && n >= 0 {
			switch unit {
			case 'd':
				return today - i64(n) * day, true
			case 'w':
				return today - i64(n) * 7 * day, true
			case 'm':
				return today - i64(n) * 30 * day, true
			case 'y':
				return today - i64(n) * 365 * day, true
			}
		}
	}
	parts := strings.split(v, "-", context.temp_allocator)
	if len(parts) >= 1 && len(parts) <= 3 {
		y, m, d := 0, 1, 1
		ok := true
		y, ok = strconv.parse_int(parts[0])
		if ok && len(parts) > 1 {
			m, ok = strconv.parse_int(parts[1])
		}
		if ok && len(parts) > 2 {
			d, ok = strconv.parse_int(parts[2])
		}
		if ok && y > 1970 && y < 3000 && m >= 1 && m <= 12 && d >= 1 && d <= 31 {
			t, tok := time.components_to_time(y, m, d, 0, 0, 0)
			if tok {
				return time.to_unix_seconds(t), true
			}
		}
	}
	return 0, false
}

// parse_query reads the query text. `typing` says the person is still
// typing, so an unfinished last word is a prefix.
parse_query :: proc(text: string, now: i64, typing := false, allocator := context.temp_allocator) -> Query {
	context.allocator = allocator
	q: Query
	q.raw = text
	q.terms = make([dynamic]Term)
	q.phrases = make([dynamic][]string)
	q.not = make([dynamic]string)
	q.in_words = make([dynamic]string)
	q.unknown = make([dynamic]string)

	ends_open := typing && len(text) > 0 && text[len(text) - 1] != ' ' && text[len(text) - 1] != '"'
	last_plain := -1

	i := 0
	for i < len(text) {
		for i < len(text) && (text[i] == ' ' || text[i] == '\t' || text[i] == '\n') {
			i += 1
		}
		if i >= len(text) {
			break
		}
		if text[i] == '"' {
			j := i + 1
			for j < len(text) && text[j] != '"' {
				j += 1
			}
			words := make([dynamic]string)
			t := tokenizer(text[i + 1:j])
			for term in next_token(&t) {
				append(&words, strings.clone(term))
			}
			if len(words) == 1 {
				append(&q.terms, Term{text = words[0]})
			} else if len(words) > 1 {
				append(&q.phrases, words[:])
			}
			i = j + 1
			continue
		}
		j := i
		for j < len(text) && text[j] != ' ' && text[j] != '\t' && text[j] != '\n' {
			j += 1
		}
		tok := text[i:j]
		i = j
		lower := strings.to_lower(tok)

		if colon := strings.index_byte(lower, ':'); colon > 0 && colon < len(lower) - 1 && is_operator_name(lower[:colon]) && !strings.contains(lower, "://") {
			name, val := lower[:colon], lower[colon + 1:]
			ok := true
			switch name {
			case "in":
				append(&q.in_words, val)
			case "type", "kind":
				if k, kok := kind_by_word(val); kok {
					q.kinds += {k}
				} else {
					ok = false
				}
			case "is":
				switch val {
				case "unread":
					q.want += {.Unread}
				case "read":
					q.unwant += {.Unread}
				case "waiting":
					q.want += {.Waiting}
				case "flagged", "starred":
					q.want += {.Flagged}
				case "done":
					q.want += {.Done}
				case "open", "undone":
					q.unwant += {.Done}
				case "sent":
					q.want += {.Sent}
				case:
					ok = false
				}
			case "has":
				if val == "attachment" || val == "attachments" || val == "file" {
					q.want += {.Attachment}
				} else {
					ok = false
				}
			case "from", "with", "by":
				t := tokenizer(val)
				for term in next_token(&t) {
					append(&q.terms, Term{text = strings.clone(term), field = .Who})
				}
			case "before":
				if v, dok := parse_date(val, now); dok {
					q.before = v
				} else {
					ok = false
				}
			case "after", "since":
				if v, dok := parse_date(val, now); dok {
					q.after = v
				} else {
					ok = false
				}
			case:
				ok = false
			}
			if !ok {
				append(&q.unknown, tok)
			}
			continue
		}
		if len(tok) > 1 && tok[0] == '-' {
			t := tokenizer(tok[1:])
			for term in next_token(&t) {
				append(&q.not, strings.clone(term))
			}
			continue
		}
		t := tokenizer(tok)
		for term in next_token(&t) {
			append(&q.terms, Term{text = strings.clone(term)})
			last_plain = len(q.terms) - 1
		}
		if j < len(text) {
			last_plain = -1 // followed by a space: finished
		}
	}
	if ends_open && last_plain >= 0 && last_plain == len(q.terms) - 1 {
		q.terms[last_plain].prefix = true
	}
	return q
}
