// A segment: one immutable file holding a set of documents, their terms and
// their postings, laid out so a reader can map it and answer a query without
// building anything in memory first.
//
//	header      80 bytes: magic, counts, section offsets
//	docs        ndocs × Doc_Rec (48 bytes): key hash, signature, time, kind,
//	            flags, token count, where its stored fields are
//	terms       nterms × Term_Rec (24 bytes), sorted by term bytes: df, and
//	            where its postings and its spelling are
//	blob        the terms' bytes, concatenated in sorted order
//	postings    per term: (uvarint doc delta, one tf byte) per document
//	positions   per term, same document order: (uvarint byte length, then
//	            uvarint position deltas) per document
//	store       per doc: uvarint-prefixed key, title, who, detail, uri, app,
//	            body — what results, snippets and merges are made from
//
// The tf byte packs where the term occurred: bits 0–1 the title count, 2–3
// the people count, 4–7 the body count, each saturating. That is enough for
// a field-weighted BM25 and for `from:` (people only). Positions live in a
// section of their own, read only by phrase queries, so an ordinary query
// never pays to skip them. A position is the token's index in its field
// plus a per-field base (title 0, people 16384, body 32768), so a phrase
// can't straddle two fields.
//
// Segments never change once written. An update writes a new small segment
// and marks the old copy dead in a tombstone list; merging folds small
// segments into bigger ones by re-reading their stored text (index.odin).
package indexcore

import "base:runtime"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sys/linux"

MAGIC :: u32(0x31584950) // "PIX1"
VERSION :: u32(2)

// Bodies past this are not indexed or stored: a 200-page PDF is found by its
// first 64 KiB of text and its name. Stated in search.md.
MAX_BODY :: 64 * 1024

Kind :: enum u8 {
	Mail,
	Event,
	Task,
	Doc,
	File,
	Note,
	Chat,
	Person,
	Page, // a browser bookmark or history entry
	Issue, // forge: an issue or a pull request
}

KIND_NAME := [Kind]string {
	.Mail   = "mail",
	.Event  = "event",
	.Task   = "task",
	.Doc    = "doc",
	.File   = "file",
	.Note   = "note",
	.Chat   = "chat",
	.Person = "person",
	.Page   = "page",
	.Issue  = "issue",
}

Flag :: enum u8 {
	Unread,
	Waiting, // a person is waiting on a reply from you
	Attachment,
	Done,
	Flagged,
	Sent, // you wrote it
	Opened, // you opened it recently (Recently opened on Today)
}
Flags :: bit_set[Flag;u8]

// Doc is one thing that can be found, as a source hands it to the index.
Doc :: struct {
	key:    string, // stable per identity: "mail:<maildir id>", "file:<rel path>"
	kind:   Kind,
	flags:  Flags,
	time:   i64, // unix seconds: received, modified, starts
	dur:    i32, // minutes; events
	sig:    u64, // source signature: changes exactly when the source does
	title:  string,
	who:    string, // people: sender and recipients, organiser, editor
	body:   string,
	detail: string, // the line under the title: folder, place, path
	uri:    string, // what opening it means (search.md, "Opening a result")
	app:    string, // the application it opens in
}

Header :: struct #packed {
	magic:     u32,
	version:   u32,
	ndocs:     u32,
	nterms:    u32,
	total_len: u64, // sum of every doc's token count, for avgdl
	off_docs:  u64,
	off_terms: u64,
	off_blob:  u64,
	off_post:  u64,
	off_pos:   u64,
	off_store: u64,
	size:      u64,
}
#assert(size_of(Header) == 80)

Doc_Rec :: struct #packed {
	key_hash:  u64,
	sig:       u64,
	time:      i64,
	store_off: u64,
	store_len: u32,
	ntok:      u32,
	dur:       i32,
	kind:      Kind,
	flags:     Flags,
	_:         u16,
}
#assert(size_of(Doc_Rec) == 48)

Term_Rec :: struct #packed {
	post_off: u64,
	pos_off:  u64,
	post_len: u32,
	pos_len:  u32,
	df:       u32,
	blob_off: u32,
	blob_len: u16,
	_:        u16,
	_:        u32,
}
#assert(size_of(Term_Rec) == 40)

POS_TITLE :: 0
POS_WHO :: 16384
POS_BODY :: 32768

// ---------------------------------------------------------------------------
// Building
// ---------------------------------------------------------------------------

@(private)
Hit_Triple :: struct {
	term:    u32,
	doc:     u32,
	pos_off: u64, // its positions group in Builder.pbuf
	tf:      u8,
}

Builder :: struct {
	arena:   runtime.Arena, // term spellings
	terms:   map[string]u32,
	names:   [dynamic]string,
	last:    [dynamic]u32, // per term: doc+1 that last touched it
	cur:     [dynamic]u8, // per term: the tf byte for that doc so far
	cnt:     [dynamic]u32, // per term: positions in that doc (then a fill cursor)
	off:     [dynamic]u32, // per term: where its positions start in `placed`
	placed:  [dynamic]u32,
	touched: [dynamic]u32,
	hits:    [dynamic]Hit_Triple,
	docpos:  [dynamic]u64, // this doc's (term << 32 | position), in text order
	pbuf:    [dynamic]u8, // positions groups, in hit order
	grp:     [dynamic]u8,
	docs:    [dynamic]Doc_Rec,
	store:   [dynamic]u8,
	total:   u64,
}

builder_init :: proc(b: ^Builder) {
	b.terms = make(map[string]u32, 1 << 14)
}

builder_destroy :: proc(b: ^Builder) {
	runtime.arena_destroy(&b.arena)
	delete(b.terms)
	delete(b.names)
	delete(b.last)
	delete(b.cur)
	delete(b.cnt)
	delete(b.off)
	delete(b.placed)
	delete(b.touched)
	delete(b.hits)
	delete(b.docpos)
	delete(b.pbuf)
	delete(b.grp)
	delete(b.docs)
	delete(b.store)
	b^ = {}
}

@(private)
put_field :: proc(buf: ^[dynamic]u8, s: string) {
	put_uvarint(buf, u64(len(s)))
	append(buf, ..transmute([]u8)s)
}

// clip cuts a body at MAX_BODY on a UTF-8 boundary.
clip :: proc(s: string, max := MAX_BODY) -> string {
	if len(s) <= max {
		return s
	}
	n := max
	for n > 0 && s[n] & 0xc0 == 0x80 {
		n -= 1
	}
	return s[:n]
}

@(private)
add_field :: proc(b: ^Builder, text: string, shift: uint, cap: u8, doc: u32, base: u32) -> u32 {
	n: u32
	t := tokenizer(text)
	for term in next_token(&t) {
		n += 1
		id, found := b.terms[term]
		if !found {
			s := strings.clone(term, runtime.arena_allocator(&b.arena))
			id = u32(len(b.names))
			b.terms[s] = id
			append(&b.names, s)
			append(&b.last, 0)
			append(&b.cur, 0)
			append(&b.cnt, 0)
			append(&b.off, 0)
		}
		if b.last[id] != doc + 1 {
			b.last[id] = doc + 1
			b.cur[id] = 0
			b.cnt[id] = 0
			append(&b.touched, id)
		}
		v := (b.cur[id] >> shift) & cap
		if v < cap {
			b.cur[id] += 1 << shift
		}
		if n < 16000 {
			append(&b.docpos, u64(id) << 32 | u64(base + n - 1))
			b.cnt[id] += 1
		}
	}
	return n
}

builder_add :: proc(b: ^Builder, d: Doc) {
	doc := u32(len(b.docs))
	body := clip(d.body)
	clear(&b.touched)
	clear(&b.docpos)
	ntok := add_field(b, d.title, 0, 3, doc, POS_TITLE)
	ntok += add_field(b, d.who, 2, 3, doc, POS_WHO)
	ntok += add_field(b, body, 4, 15, doc, POS_BODY)
	// Group this doc's positions by term without sorting: a counting
	// placement, since each term's count is known. Positions stay in text
	// order within a term. One hit and one positions group per term.
	run: u32 = 0
	for id in b.touched {
		b.off[id] = run
		run += b.cnt[id]
		b.cnt[id] = 0
	}
	resize(&b.placed, int(run))
	for x in b.docpos {
		id := u32(x >> 32)
		b.placed[b.off[id] + b.cnt[id]] = u32(x)
		b.cnt[id] += 1
	}
	for id in b.touched {
		clear(&b.grp)
		prev: u32 = 0
		for p in b.placed[b.off[id]:][:b.cnt[id]] {
			put_uvarint(&b.grp, u64(p - prev))
			prev = p
		}
		off := u64(len(b.pbuf))
		put_uvarint(&b.pbuf, u64(len(b.grp)))
		append(&b.pbuf, ..b.grp[:])
		append(&b.hits, Hit_Triple{id, doc, off, b.cur[id]})
	}
	off := len(b.store)
	put_field(&b.store, d.key)
	put_field(&b.store, d.title)
	put_field(&b.store, d.who)
	put_field(&b.store, d.detail)
	put_field(&b.store, d.uri)
	put_field(&b.store, d.app)
	put_field(&b.store, body)
	append(&b.docs, Doc_Rec {
		key_hash = fnv64(d.key),
		sig = d.sig,
		time = d.time,
		store_off = u64(off),
		store_len = u32(len(b.store) - off),
		ntok = ntok,
		dur = d.dur,
		kind = d.kind,
		flags = d.flags,
	})
	b.total += u64(ntok)
}

builder_ndocs :: proc(b: ^Builder) -> int {
	return len(b.docs)
}

// builder_write lays the segment out and writes it to `path` through a
// temporary file, so a reader never maps half a segment.
builder_write :: proc(b: ^Builder, path: string) -> bool {
	nterms := len(b.names)
	// Sort the dictionary, then renumber.
	order := make([]u32, nterms)
	defer delete(order)
	for i in 0 ..< nterms {
		order[i] = u32(i)
	}
	names := b.names[:]
	context.user_ptr = &names
	slice.sort_by(order, proc(x, y: u32) -> bool {
		n := (^[]string)(context.user_ptr)^
		return n[x] < n[y]
	})
	rank := make([]u32, nterms)
	defer delete(rank)
	for id, r in order {
		rank[id] = u32(r)
	}

	// Counting sort of the hits by term rank; docs stay ascending within a
	// term because hits were appended in doc order.
	start := make([]u32, nterms + 1)
	defer delete(start)
	for h in b.hits {
		start[rank[h.term] + 1] += 1
	}
	for i in 1 ..= nterms {
		start[i] += start[i - 1]
	}
	sorted := make([]Hit_Triple, len(b.hits))
	defer delete(sorted)
	fill := make([]u32, nterms)
	defer delete(fill)
	for h in b.hits {
		r := rank[h.term]
		sorted[start[r] + fill[r]] = h
		fill[r] += 1
	}

	terms := make([]Term_Rec, nterms)
	defer delete(terms)
	blob := make([dynamic]u8)
	defer delete(blob)
	post := make([dynamic]u8, 0, len(b.hits) * 2 + 16)
	defer delete(post)
	pos := make([dynamic]u8, 0, len(b.pbuf) + 16)
	defer delete(pos)
	for r in 0 ..< nterms {
		name := names[order[r]]
		t := &terms[r]
		t.blob_off = u32(len(blob))
		t.blob_len = u16(len(name))
		append(&blob, ..transmute([]u8)name)
		t.post_off = u64(len(post))
		prev: u32 = 0
		for h in sorted[start[r]:start[r + 1]] {
			put_uvarint(&post, u64(h.doc - prev))
			append(&post, h.tf)
			prev = h.doc
		}
		t.post_len = u32(u64(len(post)) - t.post_off)
		t.df = start[r + 1] - start[r]
		t.pos_off = u64(len(pos))
		for h in sorted[start[r]:start[r + 1]] {
			at := int(h.pos_off)
			n := int(get_uvarint(b.pbuf[:], &at))
			append(&pos, ..b.pbuf[h.pos_off:at + n])
		}
		t.pos_len = u32(u64(len(pos)) - t.pos_off)
	}

	h: Header
	h.magic = MAGIC
	h.version = VERSION
	h.ndocs = u32(len(b.docs))
	h.nterms = u32(nterms)
	h.total_len = b.total
	h.off_docs = size_of(Header)
	h.off_terms = h.off_docs + u64(len(b.docs) * size_of(Doc_Rec))
	h.off_blob = h.off_terms + u64(nterms * size_of(Term_Rec))
	h.off_post = h.off_blob + u64(len(blob))
	h.off_pos = h.off_post + u64(len(post))
	h.off_store = h.off_pos + u64(len(pos))
	h.size = h.off_store + u64(len(b.store))

	tmp := strings.concatenate({path, ".tmp"}, context.temp_allocator)
	f, err := os.open(tmp, {.Write, .Create, .Trunc}, os.perm_number(0o600))
	if err != nil {
		return false
	}
	ok := true
	write :: proc(f: ^os.File, data: []u8, ok: ^bool) {
		if len(data) == 0 || !ok^ {
			return
		}
		if n, e := os.write(f, data); e != nil || n != len(data) {
			ok^ = false
		}
	}
	hb := h
	write(f, slice.bytes_from_ptr(&hb, size_of(Header)), &ok)
	write(f, slice.to_bytes(b.docs[:]), &ok)
	write(f, slice.to_bytes(terms), &ok)
	write(f, blob[:], &ok)
	write(f, post[:], &ok)
	write(f, pos[:], &ok)
	write(f, b.store[:], &ok)
	os.close(f)
	if !ok || os.rename(tmp, path) != nil {
		os.remove(tmp)
		return false
	}
	return true
}

// ---------------------------------------------------------------------------
// Reading
// ---------------------------------------------------------------------------

Segment :: struct {
	name:  string,
	data:  []u8, // the whole file, mapped
	hdr:   ^Header,
	docs:  []Doc_Rec,
	terms: []Term_Rec,
	blob:  []u8,
	post:  []u8,
	pos:   []u8,
	store: []u8,
	dead:  []bool, // tombstones, one per doc
	ndead: int,
}

// opened_paths records every index file this process maps or reads, when
// it is non-nil. The isolation tests read it; nothing else does.
opened_paths: ^[dynamic]string

note_open :: proc(path: string) {
	if opened_paths != nil {
		append(opened_paths, strings.clone(path))
	}
}

segment_open :: proc(path: string, name: string) -> (s: ^Segment, ok: bool) {
	note_open(path)
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	fd, errno := linux.open(cpath, {.CLOEXEC})
	if errno != .NONE {
		return nil, false
	}
	defer linux.close(fd)
	st: linux.Stat
	if linux.fstat(fd, &st) != .NONE || st.size < size_of(Header) {
		return nil, false
	}
	size := uint(st.size)
	ptr, merr := linux.mmap(0, size, {.READ}, {.SHARED}, fd, 0)
	if merr != .NONE {
		return nil, false
	}
	data := ([^]u8)(ptr)[:size]
	h := (^Header)(ptr)
	if h.magic != MAGIC || h.version != VERSION || h.size != u64(size) {
		linux.munmap(ptr, size)
		return nil, false
	}
	s = new(Segment)
	s.name = strings.clone(name)
	s.data = data
	s.hdr = h
	s.docs = slice.reinterpret([]Doc_Rec, data[h.off_docs:h.off_terms])
	s.terms = slice.reinterpret([]Term_Rec, data[h.off_terms:h.off_blob])
	s.blob = data[h.off_blob:h.off_post]
	s.post = data[h.off_post:h.off_pos]
	s.pos = data[h.off_pos:h.off_store]
	s.store = data[h.off_store:h.size]
	s.dead = make([]bool, h.ndocs)
	return s, true
}

segment_close :: proc(s: ^Segment) {
	if s == nil {
		return
	}
	linux.munmap(raw_data(s.data), uint(len(s.data)))
	delete(s.dead)
	delete(s.name)
	free(s)
}

term_text :: #force_inline proc(s: ^Segment, i: int) -> string {
	t := s.terms[i]
	return string(s.blob[t.blob_off:][:t.blob_len])
}

// term_lower_bound is the first term >= key.
term_lower_bound :: proc(s: ^Segment, key: string) -> int {
	lo, hi := 0, len(s.terms)
	for lo < hi {
		mid := (lo + hi) / 2
		if term_text(s, mid) < key {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	return lo
}

term_find :: proc(s: ^Segment, key: string) -> (int, bool) {
	i := term_lower_bound(s, key)
	if i < len(s.terms) && term_text(s, i) == key {
		return i, true
	}
	return i, false
}

// Stored is a document's stored fields; strings point into the mapping.
Stored :: struct {
	key, title, who, detail, uri, app, body: string,
}

doc_stored :: proc(s: ^Segment, d: int) -> (st: Stored) {
	r := s.docs[d]
	data := s.store[r.store_off:][:r.store_len]
	pos := 0
	field :: proc(data: []u8, pos: ^int) -> string {
		n := int(get_uvarint(data, pos))
		v := string(data[pos^:][:n])
		pos^ += n
		return v
	}
	st.key = field(data, &pos)
	st.title = field(data, &pos)
	st.who = field(data, &pos)
	st.detail = field(data, &pos)
	st.uri = field(data, &pos)
	st.app = field(data, &pos)
	st.body = field(data, &pos)
	return
}

// doc_from_stored rebuilds the Doc a segment was given, for merging.
doc_from_stored :: proc(s: ^Segment, d: int) -> Doc {
	st := doc_stored(s, d)
	r := s.docs[d]
	return Doc {
		key = st.key,
		kind = r.kind,
		flags = r.flags,
		time = r.time,
		dur = r.dur,
		sig = r.sig,
		title = st.title,
		who = st.who,
		body = st.body,
		detail = st.detail,
		uri = st.uri,
		app = st.app,
	}
}

segment_live :: proc(s: ^Segment) -> int {
	return len(s.docs) - s.ndead
}
