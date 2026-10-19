// Answering a query: candidates from postings, a ranking, and snippets.
//
// Ranking, in the order it matters (product.md §6, search.md):
//
//	BM25 over a field-weighted term frequency (title ×3, people ×2,
//	body ×1), so rare words count more than common ones and a long mail
//	does not win by being long
//	+ a title bonus and a people bonus per term: a title hit beats a person
//	  hit beats a body hit
//	+ exact phrase: the query's words in that order in the title or body
//	+ recency: halves every 30 days (for events: distance from now, either way)
//	+ unread, and a person waiting on you
//	× a prefix (still typing) or typo-corrected match counts for less than
//	  the word itself
//
// Every result carries the handle of the identity whose index it came from.
// The caller can't get a result without one: search_all labels as it merges.
package indexcore

import "core:math"
import "core:slice"
import "core:strings"
import "core:time"

Identity :: struct {
	id:      string,
	handle:  string,
	name:    string,
	kind:    string, // personal | work | public | project
	color:   string,
	address: string,
}

Order :: enum u8 {
	Relevance,
	Newest,
	Oldest,
}

Options :: struct {
	order:    Order, // Newest/Oldest rank by time only (Today's lists)
	limit:    int, // results overall, after per_kind (default 20)
	per_kind: int, // at most this many of one kind; 0 = no cap
	typing:   bool, // the last word is a prefix
	now:      i64, // unix seconds; 0 = the clock
	snippets: bool,
}

Mark :: [2]int // byte range [start, end) in the string it marks

Result :: struct {
	handle:      string, // the identity it belongs to; never empty
	kind:        Kind,
	flags:       Flags,
	time:        i64,
	dur:         i32,
	score:       f32,
	key:         string,
	title:       string,
	who:         string,
	detail:      string,
	uri:         string,
	app:         string,
	snippet:     string,
	marks:       []Mark, // in snippet
	title_marks: []Mark,
}

Correction :: struct {
	from, to: string,
}

Stats :: struct {
	searched:    int, // live documents in the indexes searched
	matched:     int, // documents that matched before limits
	per_kind:    [Kind]int,
	corrections: [dynamic]Correction,
	took_us:     i64,
}

@(private)
Cand :: struct {
	score: f32,
	seg:   ^Segment,
	doc:   u32,
	ix:    int, // which index in the fan-out
}

// Expansion is one dictionary term standing in for a query term.
@(private)
Expansion :: struct {
	text: string,
	mult: f32,
}

MAX_PREFIX_EXPAND :: 48
MAX_FUZZY_EXPAND :: 6

// edit_distance is Damerau–Levenshtein (adjacent transpositions), giving up
// early past `limit`.
edit_distance :: proc(a, b: string, limit: int) -> int {
	if abs(len(a) - len(b)) > limit {
		return limit + 1
	}
	if len(a) > 48 || len(b) > 48 {
		return limit + 1
	}
	rows: [3][50]int
	prev2, prev, cur := &rows[0], &rows[1], &rows[2]
	for j in 0 ..= len(b) {
		prev[j] = j
	}
	for i in 1 ..= len(a) {
		cur[0] = i
		best := cur[0]
		for j in 1 ..= len(b) {
			cost := a[i - 1] == b[j - 1] ? 0 : 1
			v := min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
			if i > 1 && j > 1 && a[i - 1] == b[j - 2] && a[i - 2] == b[j - 1] {
				v = min(v, prev2[j - 2] + 1)
			}
			cur[j] = v
			best = min(best, v)
		}
		if best > limit {
			return limit + 1
		}
		prev2, prev, cur = prev, cur, prev2
	}
	return prev[len(b)]
}

@(private)
Expanded :: struct {
	exp: [dynamic]Expansion,
}

// expand resolves one query term against an index's dictionaries: the word
// itself, its completions while typing, or near spellings when the word
// itself is nowhere.
@(private)
expand :: proc(ix: ^Index, t: Term, stats: ^Stats) -> [dynamic]Expansion {
	out := make([dynamic]Expansion, context.temp_allocator)
	seen := make(map[string]bool, allocator = context.temp_allocator)
	exact := false
	for s in ix.segs {
		if _, ok := term_find(s, t.text); ok {
			exact = true
			break
		}
	}
	if exact {
		append(&out, Expansion{t.text, 1})
		seen[t.text] = true
	}
	if t.prefix {
		// Completions with the highest document frequency, across segments.
		Cand_Term :: struct {
			text: string,
			df:   u32,
		}
		cands := make([dynamic]Cand_Term, context.temp_allocator)
		for s in ix.segs {
			i := term_lower_bound(s, t.text)
			scanned := 0
			for ; i < len(s.terms) && scanned < 50_000; i += 1 {
				tt := term_text(s, i)
				if !strings.has_prefix(tt, t.text) {
					break
				}
				scanned += 1
				if tt == t.text {
					continue
				}
				append(&cands, Cand_Term{tt, s.terms[i].df})
			}
		}
		slice.sort_by(cands[:], proc(a, b: Cand_Term) -> bool {return a.df > b.df})
		for c in cands {
			if len(out) >= MAX_PREFIX_EXPAND {
				break
			}
			if c.text in seen {
				continue
			}
			seen[c.text] = true
			// A completion counts for less the more of it is unwritten.
			m := 0.55 + 0.4 * f32(len(t.text)) / f32(len(c.text))
			append(&out, Expansion{c.text, m})
		}
	}
	if len(out) == 0 && len(t.text) >= 4 {
		// Typo tolerance: the word is not in this identity's index at all.
		// Within one edit (two from 8 letters), same first letter: people
		// rarely mistype the first letter, and that bound is what keeps this
		// to a slice of the dictionary.
		limit := len(t.text) >= 8 ? 2 : 1
		Fz :: struct {
			text: string,
			dist: int,
			df:   u32,
		}
		cands := make([dynamic]Fz, context.temp_allocator)
		first := t.text[:1]
		for s in ix.segs {
			i := term_lower_bound(s, first)
			for ; i < len(s.terms); i += 1 {
				tt := term_text(s, i)
				if tt[0] != first[0] {
					break
				}
				if abs(len(tt) - len(t.text)) > limit {
					continue
				}
				d := edit_distance(t.text, tt, limit)
				if d <= limit {
					append(&cands, Fz{tt, d, s.terms[i].df})
				}
				// While typing, a typo inside a word still being typed: match
				// the completions of a near spelling of what is there so far.
			}
		}
		slice.sort_by(cands[:], proc(a, b: Fz) -> bool {
			if a.dist != b.dist {
				return a.dist < b.dist
			}
			return a.df > b.df
		})
		for c in cands {
			if len(out) >= MAX_FUZZY_EXPAND {
				break
			}
			if c.text in seen {
				continue
			}
			seen[c.text] = true
			append(&out, Expansion{c.text, c.dist == 1 ? 0.7 : 0.5})
			if len(stats.corrections) < 8 && len(out) == 1 {
				append(&stats.corrections, Correction{t.text, strings.clone(c.text, context.temp_allocator)})
			}
		}
	}
	return out
}

@(private)
recency :: proc(t, now: i64, kind: Kind) -> f32 {
	age := f64(abs(now - t)) / 86400
	w := 1.6
	if kind == .Person {
		return 0.4 // people don't age
	}
	return f32(w * math.pow(0.5, age / 30))
}

// ranking_boosts is everything in the score that is not the text match:
// recency, the kind, unread, waiting.
ranking_boosts :: proc(r: Doc_Rec, now: i64) -> f32 {
	sc := recency(r.time, now, r.kind)
	sc += KIND_BOOST[r.kind]
	if .Unread in r.flags {
		sc += 0.5
	}
	if .Waiting in r.flags {
		sc += 0.4
	}
	return sc
}

KIND_BOOST := [Kind]f32 {
	.Mail   = 0,
	.Event  = 0.2,
	.Task   = 0.2,
	.Doc    = 0.3,
	.File   = 0,
	.Note   = 0.2,
	.Chat   = 0,
	.Person = 0.5,
	.Page   = -0.2,
	.Issue  = 0,
}

// phrase_in says `words` occur in order in `text` (the last may be a prefix
// while typing). ASCII text takes a fast path that searches for the longest
// word and checks its neighbours in place; anything else is tokenized.
phrase_in :: proc(text: string, words: []string, last_prefix := false) -> bool {
	if len(words) == 0 {
		return false
	}
	ascii := true
	for w in words {
		for i in 0 ..< len(w) {
			if w[i] >= 0x80 {
				ascii = false
			}
		}
	}
	if ascii {
		found, sure := phrase_ascii(text, words, last_prefix)
		if found {
			return true
		}
		if sure {
			return false
		}
	}
	return phrase_tokens(text, words, last_prefix)
}

@(private)
is_word_byte :: #force_inline proc(b: u8) -> bool {
	return b >= 0x80 || ASCII_FOLD[b] != 0
}

// phrase_ascii: sure = false when the text has non-ASCII bytes, which the
// fast path can't fold, so a miss must be confirmed by tokenizing.
@(private)
phrase_ascii :: proc(text: string, words: []string, last_prefix: bool) -> (found, sure: bool) {
	a := 0
	for w, i in words {
		if len(w) > len(words[a]) {
			a = i
		}
	}
	anchor := words[a]
	ap := last_prefix && a == len(words) - 1
	n, m := len(text), len(anchor)
	if m == 0 {
		return false, false
	}
	c0 := anchor[0]
	C0 := c0 >= 'a' && c0 <= 'z' ? c0 - 32 : c0
	hi := false
	i := 0
	for ; i + m <= n; i += 1 {
		b := text[i]
		if b >= 0x80 {
			// U+00C0–U+017F (lead bytes C3–C5) fold to ASCII letters: é is
			// e. Text with those can hide a match from this byte search.
			if b >= 0xc3 && b <= 0xc5 {
				hi = true
			}
			continue
		}
		if b != c0 && b != C0 {
			continue
		}
		if i > 0 && is_word_byte(text[i - 1]) {
			continue
		}
		ok := true
		for k in 1 ..< m {
			x := text[i + k]
			if x >= 0x80 || ASCII_FOLD[x] != anchor[k] {
				ok = false
				break
			}
		}
		if !ok {
			continue
		}
		end := i + m
		if ap {
			for end < n && text[end] < 0x80 && ASCII_FOLD[text[end]] != 0 {
				end += 1
			}
		}
		if end < n && is_word_byte(text[end]) {
			continue
		}
		if neighbours(text, i, end, words, a, last_prefix) {
			return true, true
		}
	}
	for j in i ..< n {
		if text[j] >= 0xc3 && text[j] <= 0xc5 {
			hi = true
			break
		}
	}
	return false, !hi
}

@(private)
same_word :: proc(text: string, w: string, prefix: bool) -> bool {
	if len(text) < len(w) || (!prefix && len(text) != len(w)) {
		return false
	}
	for k in 0 ..< len(w) {
		if ASCII_FOLD[text[k]] != w[k] {
			return false
		}
	}
	return true
}

@(private)
neighbours :: proc(text: string, start, end: int, words: []string, a: int, last_prefix: bool) -> bool {
	pos := start
	for j := a - 1; j >= 0; j -= 1 {
		for pos > 0 && !is_word_byte(text[pos - 1]) {
			pos -= 1
		}
		e := pos
		for pos > 0 && is_word_byte(text[pos - 1]) {
			if text[pos - 1] >= 0x80 {
				return false
			}
			pos -= 1
		}
		if !same_word(text[pos:e], words[j], false) {
			return false
		}
	}
	pos = end
	for j in a + 1 ..< len(words) {
		for pos < len(text) && !is_word_byte(text[pos]) {
			pos += 1
		}
		s := pos
		for pos < len(text) && is_word_byte(text[pos]) {
			if text[pos] >= 0x80 {
				return false
			}
			pos += 1
		}
		if !same_word(text[s:pos], words[j], last_prefix && j == len(words) - 1) {
			return false
		}
	}
	return true
}

@(private)
phrase_tokens :: proc(text: string, words: []string, last_prefix: bool) -> bool {
	t := tokenizer(text)
	k := 0
	// A ring of the last len(words) terms would be exact; matching greedily
	// and restarting is enough for the short phrases people type.
	for term in next_token(&t) {
		w := words[k]
		hit := term == w || (last_prefix && k == len(words) - 1 && strings.has_prefix(term, w))
		if hit {
			k += 1
			if k == len(words) {
				return true
			}
		} else {
			k = 0
			if term == words[0] {
				k = 1
				if k == len(words) {
					return true
				}
			}
		}
	}
	return false
}

Target :: struct {
	ident: Identity,
	ix:    ^Index,
}

// search_all runs one query over several identities' indexes and merges the
// results, labelling each with its identity. `targets` is already the scope:
// in a scoped session it holds exactly one identity, and nothing here can
// add another.
search_all :: proc(targets: []Target, q: ^Query, opt: Options, out: ^[dynamic]Result, stats: ^Stats) {
	t0 := time.tick_now()
	opt := opt
	if opt.limit <= 0 {
		opt.limit = 20
	}
	if opt.now == 0 {
		opt.now = time.to_unix_seconds(time.now())
	}
	stats.corrections = make([dynamic]Correction, context.temp_allocator)

	cap_n := opt.limit
	if opt.per_kind > 0 {
		cap_n = max(cap_n, opt.per_kind)
	}
	cap_n = cap_n * 2 + 8 // room for the phrase re-rank
	heaps: [Kind][dynamic]Cand
	for k in Kind {
		heaps[k] = make([dynamic]Cand, context.temp_allocator)
	}

	for tg, ti in targets {
		if tg.ix == nil {
			continue
		}
		stats.searched += tg.ix.ndocs
		search_one(tg.ix, ti, q, opt, &heaps, cap_n, stats)
	}

	tf := time.tick_now()
	defer if profile != nil {
		profile.final += time.tick_since(tf)
	}
	// Merge, phrase re-rank, cap per kind, then overall.
	all := make([dynamic]Cand, context.temp_allocator)
	words := make([dynamic]string, context.temp_allocator)
	for t in q.terms {
		if t.field == .Any {
			append(&words, t.text)
		}
	}
	last_prefix := len(q.terms) > 0 && q.terms[len(q.terms) - 1].prefix
	for k in Kind {
		h := heaps[k][:]
		if len(words) >= 2 {
			for &c in h {
				st := doc_stored(c.seg, int(c.doc))
				if phrase_in(st.title, words[:], last_prefix) {
					c.score += 3
				} else if phrase_in(st.body, words[:], last_prefix) {
					c.score += 1.5
				}
			}
		}
		slice.sort_by(h, proc(a, b: Cand) -> bool {return a.score > b.score})
		n := len(h)
		if opt.per_kind > 0 {
			n = min(n, opt.per_kind)
		}
		append(&all, ..h[:n])
	}
	slice.sort_by(all[:], proc(a, b: Cand) -> bool {return a.score > b.score})
	if len(all) > opt.limit {
		resize(&all, opt.limit)
	}

	mt := make([dynamic]string, context.temp_allocator)
	for t in q.terms {
		append(&mt, t.text)
	}
	for p in q.phrases {
		append(&mt, ..p)
	}
	for c in all {
		st := doc_stored(c.seg, int(c.doc))
		r := c.seg.docs[c.doc]
		res := Result {
			handle = targets[c.ix].ident.handle,
			kind   = r.kind,
			flags  = r.flags,
			time   = r.time,
			dur    = r.dur,
			score  = c.score,
			// Copied out of the mapping: a result outlives a reload of the
			// index it came from (Home keeps its rows across frames).
			key    = strings.clone(st.key, context.temp_allocator),
			title  = strings.clone(st.title, context.temp_allocator),
			who    = strings.clone(st.who, context.temp_allocator),
			detail = strings.clone(st.detail, context.temp_allocator),
			uri    = strings.clone(st.uri, context.temp_allocator),
			app    = strings.clone(st.app, context.temp_allocator),
		}
		res.title_marks = mark_terms(res.title, mt[:], true)
		if opt.snippets {
			res.snippet, res.marks = snippet(st.body, mt[:])
		}
		append(out, res)
	}
	stats.took_us = i64(time.duration_microseconds(time.tick_since(t0)))
}

@(private)
heap_push :: proc(h: ^[dynamic]Cand, c: Cand, cap_n: int) {
	// A bounded min-heap on score: the root is the weakest kept candidate.
	less :: proc(a, b: Cand) -> bool {return a.score < b.score}
	if len(h) < cap_n {
		append(h, c)
		i := len(h) - 1
		for i > 0 {
			p := (i - 1) / 2
			if !less(h[i], h[p]) {
				break
			}
			h[i], h[p] = h[p], h[i]
			i = p
		}
		return
	}
	if c.score <= h[0].score {
		return
	}
	h[0] = c
	i := 0
	n := len(h)
	for {
		l, r := 2 * i + 1, 2 * i + 2
		m := i
		if l < n && less(h[l], h[m]) {
			m = l
		}
		if r < n && less(h[r], h[m]) {
			m = r
		}
		if m == i {
			break
		}
		h[i], h[m] = h[m], h[i]
		i = m
	}
}

@(private)
search_one :: proc(ix: ^Index, ti: int, q: ^Query, opt: Options, heaps: ^[Kind][dynamic]Cand, cap_n: int, stats: ^Stats) {
	// Each required term (and each word of each phrase) is one group; a
	// document must hit every group.
	Group :: struct {
		exp:   [dynamic]Expansion,
		field: Field,
	}
	tp := time.tick_now()
	groups := make([dynamic]Group, context.temp_allocator)
	for t in q.terms {
		e := expand(ix, t, stats)
		if len(e) == 0 {
			return // a word found nowhere in this identity: nothing matches
		}
		append(&groups, Group{e, t.field})
	}
	// Each phrase's words, by group index, for the positional check.
	phrase_groups := make([dynamic][2]int, context.temp_allocator)
	for p in q.phrases {
		first := len(groups)
		for w, wi in p {
			e := expand(ix, Term{text = w, prefix = opt.typing && wi == len(p) - 1 && p_is_last(q, p)}, stats)
			if len(e) == 0 {
				return
			}
			append(&groups, Group{e, .Any})
		}
		append(&phrase_groups, [2]int{first, len(groups)})
	}
	if len(groups) > 32 {
		resize(&groups, 32)
	}
	full := u32(1 << uint(len(groups))) - 1 if len(groups) < 32 else max(u32)
	n_all := f32(max(ix.ndocs, 1))
	avgdl := f32(ix.total) / n_all
	if avgdl <= 0 {
		avgdl = 1
	}

	if profile != nil {
		profile.expand += time.tick_since(tp)
		tp = time.tick_now()
	}
	for s in ix.segs {
		nd := len(s.docs)
		if nd == 0 {
			continue
		}
		score: []f32
		mask: []u32
		if len(groups) > 0 {
			score = make([]f32, nd, context.temp_allocator)
			mask = make([]u32, nd, context.temp_allocator)
		}
		for g, gi in groups {
			bit := u32(1) << uint(gi)
			for e in g.exp {
				ti_, found := term_find(s, e.text)
				if !found {
					continue
				}
				tr := s.terms[ti_]
				df := f32(tr.df)
				idf := math.ln(1 + (n_all - df + 0.5) / (df + 0.5))
				post := s.post[tr.post_off:][:tr.post_len]
				pos := 0
				doc: u32 = 0
				for pos < len(post) {
					doc += u32(get_uvarint(post, &pos))
					tf := post[pos]
					pos += 1
					title := f32(tf & 3)
					who := f32((tf >> 2) & 3)
					body := f32(tf >> 4)
					if g.field == .Who && who == 0 {
						continue
					}
					w := 3 * title + 2 * who + body
					dl := f32(s.docs[doc].ntok)
					k1 :: 1.2
					b :: 0.75
					bm := idf * w * (k1 + 1) / (w + k1 * (1 - b + b * dl / avgdl))
					bonus: f32 = 0
					if title > 0 {
						bonus += 1.2
					} else if who > 0 {
						bonus += 0.6
					}
					score[doc] += (bm + bonus) * e.mult
					mask[doc] |= bit
				}
			}
		}
		// Words that must not appear.
		banned: []bool
		if len(q.not) > 0 {
			banned = make([]bool, nd, context.temp_allocator)
			for w in q.not {
				if ti_, found := term_find(s, w); found {
					tr := s.terms[ti_]
					post := s.post[tr.post_off:][:tr.post_len]
					pos := 0
					doc: u32 = 0
					for pos < len(post) {
						doc += u32(get_uvarint(post, &pos))
						pos += 1
						banned[doc] = true
					}
				}
			}
		}
		if profile != nil {
			profile.postings += time.tick_since(tp)
			tp = time.tick_now()
		}
		// Quoted phrases, from positions: only documents that hold every
		// word get this far, and only their positions are decoded.
		in_phrase: []bool
		for pg in phrase_groups {
			words := make([dynamic][]Expansion, context.temp_allocator)
			for gi in pg[0] ..< min(pg[1], len(groups)) {
				append(&words, groups[gi].exp[:])
			}
			ok := phrase_docs(s, words[:], mask, full)
			if in_phrase == nil {
				in_phrase = ok
			} else {
				for &x, i in in_phrase {
					x = x && ok[i]
				}
			}
		}
		if profile != nil {
			profile.verify += time.tick_since(tp)
			tp = time.tick_now()
		}
		for d in 0 ..< nd {
			if len(groups) > 0 && mask[d] != full {
				continue
			}
			if s.dead[d] || (banned != nil && banned[d]) || (in_phrase != nil && !in_phrase[d]) {
				continue
			}
			r := s.docs[d]
			if q.kinds != {} && r.kind not_in q.kinds {
				continue
			}
			if q.want - r.flags != {} || q.unwant & r.flags != {} {
				continue
			}
			if q.after != 0 && r.time < q.after {
				continue
			}
			if q.before != 0 && r.time >= q.before {
				continue
			}
			sc: f32 = len(groups) > 0 ? score[d] : 0
			switch opt.order {
			case .Newest:
				sc = f32(f64(r.time - opt.now) / 86400)
			case .Oldest:
				sc = -f32(f64(r.time - opt.now) / 86400)
			case .Relevance:
			}
			if opt.order == .Relevance {
				sc += ranking_boosts(r, opt.now)
			}
			stats.matched += 1
			stats.per_kind[r.kind] += 1
			heap_push(&heaps[r.kind], Cand{sc, s, u32(d), ti}, cap_n)
		}
	}

	if profile != nil {
		profile.filter += time.tick_since(tp)
	}
}

// p_is_last says the phrase is the last thing in the query text, so its
// last word is still being typed (an unclosed quote).
@(private)
p_is_last :: proc(q: ^Query, p: []string) -> bool {
	return len(q.phrases) > 0 && raw_data(q.phrases[len(q.phrases) - 1]) == raw_data(p) && !strings.has_suffix(strings.trim_right_space(q.raw), "\"")
}

// phrase_docs marks the documents where the words occur consecutively.
// Each word may stand for several dictionary terms (completions, near
// spellings); a position matches if any of them is there. Works word by
// word on (doc << 32 | position) pairs, keeping only those that continue a
// match of the words before, so the work shrinks as the phrase goes on.
@(private)
phrase_docs :: proc(s: ^Segment, words: [][]Expansion, mask: []u32, full: u32) -> []bool {
	nd := len(s.docs)
	ok := make([]bool, nd, context.temp_allocator)
	stamp := make([]u8, nd, context.temp_allocator) // last word index + 1 a doc survived
	prev := make([dynamic]u64, context.temp_allocator)
	for exps, j in words {
		cur := make([dynamic]u64, context.temp_allocator)
		for e in exps {
			ti, found := term_find(s, e.text)
			if !found {
				continue
			}
			tr := s.terms[ti]
			post := s.post[tr.post_off:][:tr.post_len]
			pos := s.pos[tr.pos_off:][:tr.pos_len]
			pp, qq := 0, 0
			doc: u32 = 0
			for pp < len(post) {
				doc += u32(get_uvarint(post, &pp))
				pp += 1
				n := int(get_uvarint(pos, &qq))
				g := qq
				qq += n
				if mask != nil && mask[doc] != full {
					continue
				}
				if j > 0 && int(stamp[doc]) != j {
					continue
				}
				p: u32 = 0
				for g < qq {
					p += u32(get_uvarint(pos, &g))
					append(&cur, u64(doc) << 32 | u64(p))
				}
			}
		}
		if len(exps) > 1 {
			slice.sort(cur[:])
		}
		if j > 0 {
			next := make([dynamic]u64, context.temp_allocator)
			k := 0
			for x in cur {
				want := x - 1
				for k < len(prev) && prev[k] < want {
					k += 1
				}
				if k < len(prev) && prev[k] == want {
					append(&next, x)
				}
			}
			cur = next
		}
		for x in cur {
			stamp[x >> 32] = u8(j + 1)
		}
		prev = cur
		if len(prev) == 0 {
			break
		}
	}
	for x in prev {
		ok[x >> 32] = true
	}
	return ok
}

// sift_down restores a max-heap on score below i.
@(private)
sift_down :: proc(h: []Cand, i: int) {
	i := i
	n := len(h)
	for {
		l := 2 * i + 1
		if l >= n {
			return
		}
		m := l
		if l + 1 < n && h[l + 1].score > h[l].score {
			m = l + 1
		}
		if h[m].score <= h[i].score {
			return
		}
		h[i], h[m] = h[m], h[i]
		i = m
	}
}

// Prof times the phases of a query when profile is set (index-bench --query).
Prof :: struct {
	expand, postings, filter, verify, final: time.Duration,
	checked:                                 int,
}
profile: ^Prof



// matches says a token of the text matches one of the query's terms: the
// term itself, or a completion of the last one while typing, or a near
// spelling (marks are drawn for what the index matched, roughly).
@(private)
term_matches :: proc(tok: string, terms: []string, allow_prefix: bool) -> bool {
	for t in terms {
		if tok == t {
			return true
		}
		if allow_prefix && len(t) >= 2 && strings.has_prefix(tok, t) {
			return true
		}
		if len(t) >= 4 && len(tok) >= 4 && tok[0] == t[0] && edit_distance(tok, t, 1) <= 1 {
			return true
		}
	}
	return false
}

mark_terms :: proc(text: string, terms: []string, allow_prefix: bool) -> []Mark {
	out := make([dynamic]Mark, context.temp_allocator)
	t := tokenizer(text)
	for tok in next_token(&t) {
		if term_matches(tok, terms, allow_prefix) {
			append(&out, Mark{t.start, t.end})
		}
	}
	return out[:]
}

SNIPPET_LEN :: 160

// snippet cuts the body around its first match: a little context before,
// the rest after, on word boundaries, with ellipses where it was cut.
snippet :: proc(body: string, terms: []string) -> (string, []Mark) {
	if len(body) == 0 {
		return "", nil
	}
	first := -1
	t := tokenizer(body)
	for tok in next_token(&t) {
		if term_matches(tok, terms, true) {
			first = t.start
			break
		}
	}
	start := 0
	if first > 50 {
		start = first - 40
		for start < first && body[start] != ' ' && body[start] != '\n' {
			start += 1
		}
		for start < len(body) && (body[start] == ' ' || body[start] == '\n') {
			start += 1
		}
	}
	end := min(len(body), start + SNIPPET_LEN)
	if end < len(body) {
		e := end
		for e > start + SNIPPET_LEN / 2 && body[e] != ' ' {
			e -= 1
		}
		end = e
		for end > start && body[end - 1] & 0xc0 == 0x80 {
			end -= 1
		}
		for end < len(body) && body[end] & 0xc0 == 0x80 {
			end += 1
		}
	}
	sb := strings.builder_make(context.temp_allocator)
	pre := 0
	if start > 0 {
		strings.write_string(&sb, "…")
		pre = len("…")
	}
	// Collapse runs of whitespace and newlines into one space, keeping a map
	// back to offsets so the marks land right.
	piece := body[start:end]
	offs := make([dynamic]int, context.temp_allocator) // body offset -> snippet offset
	space := false
	for i in 0 ..< len(piece) {
		c := piece[i]
		append(&offs, strings.builder_len(sb))
		if c == '\n' || c == '\r' || c == '\t' || c == ' ' {
			if !space && strings.builder_len(sb) > pre {
				strings.write_byte(&sb, ' ')
			}
			space = true
			continue
		}
		space = false
		strings.write_byte(&sb, c)
	}
	append(&offs, strings.builder_len(sb))
	if end < len(body) {
		strings.write_string(&sb, "…")
	}
	marks := make([dynamic]Mark, context.temp_allocator)
	t = tokenizer(piece)
	for tok in next_token(&t) {
		if term_matches(tok, terms, true) {
			append(&marks, Mark{offs[t.start], offs[t.end]})
		}
	}
	return strings.to_string(sb), marks[:]
}
