// A CRDT for collaborative documents, written for Palmframe's office suite.
//
// One `Doc` holds three kinds of shared state, all addressed by plain byte
// keys rather than by object handles:
//
//   * **sequences** — ordered lists of elements, used for text (one element
//     per UTF-8 byte), embeds (one element carrying a payload: a table, an
//     image) and virtual runs (elements with no content at all: the million
//     rows of a spreadsheet axis). Ordering is FugueMax / YjsMod (Weidner and
//     Kleppmann 2023; Gentle's reference-crdts), which never interleaves two
//     people's concurrent typing at the same spot.
//   * **registers** — last-writer-wins values keyed by (owner, field). An owner
//     is any byte string: "deck", a slide key, the encoded ID of a paragraph's
//     newline, a spreadsheet cell's (sheet, row, column) triple.
//   * **marks** — Peritext-style formatting spans over a sequence, anchored to
//     elements rather than offsets, so a bold range grows when someone types at
//     its end and keeps covering text another person inserts inside it.
//
// Because containers are addressed by key, no "create object" operation is
// ever needed and two replicas that both start typing into the same table cell
// type into the same sequence. That removes the most common data-loss case of
// map-of-nested-objects designs (two people creating the same nested object
// concurrently, one of them winning and the other's typing vanishing).
//
// Deletion is a last-writer-wins flag per element (and per mark), not a
// one-way tombstone, so undo restores the *same* elements: comments,
// formatting and other people's cursors anchored to them keep working.
package crdt

import "core:mem"
import "core:slice"

ID :: struct {
	agent: u64, // 0 is "no ID"
	seq:   u64,
}

NONE :: ID{}

// Stamp orders concurrent writes: Lamport clock first, agent as tiebreak.
Stamp :: struct {
	lamport: u64,
	agent:   u64,
}

stamp_less :: proc(a, b: Stamp) -> bool {
	if a.lamport != b.lamport {return a.lamport < b.lamport}
	return a.agent < b.agent
}

Kind :: enum u8 {
	Text    = 0, // `len` bytes of UTF-8, one element per byte
	Embed   = 1, // one element; `content` is an opaque payload
	Virtual = 2, // `len` elements with no content (spreadsheet axes)
}

// Item flags.
FLAG_SUGGEST :: u8(1) // inserted in suggestion mode; shown as a proposal

Item :: struct {
	id:      ID, // the first element; the rest are id.seq+1 .. id.seq+len-1
	len:     u64,
	left_o:  ID, // origin left: the element this was typed after (NONE: start)
	right_o: ID, // origin right: the element that followed it (NONE: end)
	kind:    Kind,
	flags:   u8,
	deleted: bool,
	dstamp:  Stamp, // the delete/restore that set `deleted`
	content: [dynamic]u8, // Text: len bytes; Embed: payload; Virtual: empty
	prev:    ^Item,
	next:    ^Item,
	seq:     ^Seq,
}

Seq :: struct {
	key:       string,
	head:      ^Item,
	tail:      ^Item,
	vis:       u64, // visible elements
	marks:     [dynamic]^Mark,
	// Search marker: one remembered (item, visible offset of its start). Local
	// edits cluster, so most position lookups start a few items away.
	cache:     ^Item,
	cache_off: u64,
}

// Anchor names a gap: just before or just after an element. `id == NONE`
// means the start of the sequence (after = false) or its end (after = true).
Anchor :: struct {
	id:    ID,
	after: bool,
}

Mark :: struct {
	id:      ID,
	stamp:   Stamp,
	seq:     ^Seq,
	start:   Anchor,
	end:     Anchor,
	attr:    string,
	value:   []u8, // empty: the attribute is removed over the range
	deleted: bool,
	dstamp:  Stamp,
}

Reg :: struct {
	value: []u8,
	stamp: Stamp,
	id:    ID, // the op that wrote it, so undo can tell whether it is still ours
	unset: bool, // a deletion of the key
}

Reg_Table :: map[string]Reg

// Agent_Store indexes everything one agent created, sorted by seq, so an ID
// resolves with a binary search.
Agent_Store :: struct {
	items: [dynamic]^Item,
}

Doc :: struct {
	agent:      u64, // this replica's agent, for local operations
	next:       map[u64]u64, // version vector: next expected seq per agent
	lamport:    u64,
	seqs:       map[string]^Seq,
	regs:       map[string]^Reg_Table,
	agents:     map[u64]^Agent_Store,
	marks:      map[ID]^Mark,

	// Updates that could not be applied yet because something they depend on
	// has not arrived. Retried after every successful application.
	pending:    [dynamic][]u8,

	// What remote application touched, for bindings that refresh
	// incrementally. Cleared by the binding.
	touched_seqs: map[string]bool,
	touched_regs: map[string]bool,
	structural:   bool, // a sequence changed shape (not only registers)

	// Local operations not yet handed to the network, as one encoded update.
	outbox:     [dynamic]u8,
	out_ops:    int,
	enc:        Encoder, // scratch for the outbox

	undo:       Undo,
	recording:  ^Txn, // the transaction local ops are being recorded into

	allocator:  mem.Allocator,
}

doc_make :: proc(agent: u64, allocator := context.allocator) -> ^Doc {
	context.allocator = allocator
	d := new(Doc)
	d.agent = agent
	d.allocator = allocator
	d.next = make(map[u64]u64)
	d.seqs = make(map[string]^Seq)
	d.regs = make(map[string]^Reg_Table)
	d.agents = make(map[u64]^Agent_Store)
	d.marks = make(map[ID]^Mark)
	d.touched_seqs = make(map[string]bool)
	d.touched_regs = make(map[string]bool)
	return d
}

doc_destroy :: proc(d: ^Doc) {
	if d == nil {return}
	context.allocator = d.allocator
	for k, s in d.seqs {
		it := s.head
		for it != nil {
			n := it.next
			delete(it.content)
			free(it)
			it = n
		}
		for m in s.marks {
			delete(m.attr)
			delete(m.value)
			free(m)
		}
		delete(s.marks)
		delete(k)
		free(s)
	}
	delete(d.seqs)
	for k, t in d.regs {
		for f, r in t {
			delete(f)
			delete(r.value)
		}
		delete(t^)
		free(t)
		delete(k)
	}
	delete(d.regs)
	for _, a in d.agents {
		delete(a.items)
		free(a)
	}
	delete(d.agents)
	delete(d.marks)
	delete(d.next)
	for p in d.pending {delete(p)}
	delete(d.pending)
	for k in d.touched_seqs {delete(k)}
	delete(d.touched_seqs)
	for k in d.touched_regs {delete(k)}
	delete(d.touched_regs)
	delete(d.outbox)
	encoder_destroy(&d.enc)
	undo_destroy(d)
	free(d)
}

// ---------------------------------------------------------------------------
// Lookup
// ---------------------------------------------------------------------------

seq_get :: proc(d: ^Doc, key: string, create := true) -> ^Seq {
	if s, ok := d.seqs[key]; ok {
		return s
	}
	if !create {
		return nil
	}
	s := new(Seq, d.allocator)
	s.key = clone_str(key, d.allocator)
	s.marks = make([dynamic]^Mark, d.allocator)
	d.seqs[s.key] = s
	return s
}

has_id :: proc(d: ^Doc, id: ID) -> bool {
	if id.agent == 0 {
		return true
	}
	return id.seq < d.next[id.agent]
}

agent_store :: proc(d: ^Doc, agent: u64) -> ^Agent_Store {
	if a, ok := d.agents[agent]; ok {
		return a
	}
	a := new(Agent_Store, d.allocator)
	a.items = make([dynamic]^Item, d.allocator)
	d.agents[agent] = a
	return a
}

// store_index is the index of the last item whose first seq is <= seq.
store_index :: proc(a: ^Agent_Store, seq: u64) -> int {
	lo, hi := 0, len(a.items)
	for lo < hi {
		mid := (lo + hi) / 2
		if a.items[mid].id.seq <= seq {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	return lo - 1
}

// find_item returns the item holding element `id` and the element's offset in
// it, or nil when the element is unknown (or is a mark).
find_item :: proc(d: ^Doc, id: ID) -> (^Item, u64) {
	a, ok := d.agents[id.agent]
	if !ok {
		return nil, 0
	}
	i := store_index(a, id.seq)
	if i < 0 {
		return nil, 0
	}
	it := a.items[i]
	if id.seq < it.id.seq + it.len {
		return it, id.seq - it.id.seq
	}
	return nil, 0
}

store_add :: proc(d: ^Doc, it: ^Item) {
	a := agent_store(d, it.id.agent)
	i := store_index(a, it.id.seq) + 1
	inject_at(&a.items, i, it)
}

// split cuts `it` so that a new item starts at element offset `at` and returns
// the new right half. Per-element origins make this exact: the right half's
// left origin is the element just before it, its right origin is unchanged.
split :: proc(d: ^Doc, it: ^Item, at: u64) -> ^Item {
	assert(at > 0 && at < it.len)
	r := new(Item, d.allocator)
	r^ = it^
	r.id = ID{it.id.agent, it.id.seq + at}
	r.len = it.len - at
	r.left_o = ID{it.id.agent, it.id.seq + at - 1}
	r.content = nil
	if it.kind == .Text {
		r.content = make([dynamic]u8, r.len, d.allocator)
		copy(r.content[:], it.content[at:])
		resize(&it.content, int(at))
	}
	it.len = at
	// link
	r.prev = it
	r.next = it.next
	if it.next != nil {
		it.next.prev = r
	} else {
		it.seq.tail = r
	}
	it.next = r
	store_add(d, r)
	return r
}

// item_ending_at splits so that element `id` is the last of its item.
item_ending_at :: proc(d: ^Doc, id: ID) -> ^Item {
	it, off := find_item(d, id)
	if it == nil {
		return nil
	}
	if off + 1 < it.len {
		split(d, it, off + 1)
	}
	return it
}

// item_starting_at splits so that element `id` is the first of its item.
item_starting_at :: proc(d: ^Doc, id: ID) -> ^Item {
	it, off := find_item(d, id)
	if it == nil {
		return nil
	}
	if off > 0 {
		return split(d, it, off)
	}
	return it
}

visible_len :: proc(it: ^Item) -> u64 {
	return it.deleted ? 0 : it.len
}

// ---------------------------------------------------------------------------
// Integration (FugueMax / YjsMod)
// ---------------------------------------------------------------------------

link_before :: proc(s: ^Seq, it: ^Item, before: ^Item) {
	it.seq = s
	if before == nil {
		it.prev = s.tail
		it.next = nil
		if s.tail != nil {
			s.tail.next = it
		} else {
			s.head = it
		}
		s.tail = it
		return
	}
	it.next = before
	it.prev = before.prev
	if before.prev != nil {
		before.prev.next = it
	} else {
		s.head = it
	}
	before.prev = it
}

// in_range reports whether element `id` lies inside one of the items `r`.
in_range :: proc(r: []^Item, id: ID) -> bool {
	if id.agent == 0 {
		return false
	}
	for it in r {
		if it.id.agent == id.agent && id.seq >= it.id.seq && id.seq < it.id.seq + it.len {
			return true
		}
	}
	return false
}

// integrate places a new item (whose origins are known to be present) into
// its sequence. This is the reference YjsMod algorithm, which Weidner and
// Kleppmann show equals FugueMax: among the items concurrently inserted
// between the same two neighbours, order is decided by the origins, and two
// items with identical origins are ordered by agent.
//
// The loop only ever walks the "concurrent range" between the left and right
// origins, which in practice is empty or a handful of items, so it is written
// for clarity over that range rather than against whole-document indices.
integrate :: proc(d: ^Doc, s: ^Seq, it: ^Item) {
	left: ^Item = nil
	if it.left_o != NONE {
		left = item_ending_at(d, it.left_o)
	}
	right: ^Item = nil
	if it.right_o != NONE {
		right = item_starting_at(d, it.right_o)
	}
	start := left == nil ? s.head : left.next

	rng := make([dynamic]^Item, 0, 8, context.temp_allocator)
	for o := start; o != nil && o != right; o = o.next {
		append(&rng, o)
	}

	dest := 0
	scanning := false
	for i := 0;; i += 1 {
		if !scanning {
			dest = i
		}
		if i == len(rng) {
			break
		}
		other := rng[i]

		// Where is other's left origin relative to ours? It cannot be after
		// `other` itself, so it is either our left origin, inside the
		// concurrent range (after ours), or before ours.
		ol_cmp: int // -1 before ours, 0 same, 1 after
		if other.left_o == it.left_o {
			ol_cmp = 0
		} else if in_range(rng[:i], other.left_o) {
			ol_cmp = 1
		} else {
			ol_cmp = -1
		}
		// And its right origin relative to ours: inside the range is before
		// ours, equal is equal, anything else is after.
		or_cmp: int
		if other.right_o == it.right_o {
			or_cmp = 0
		} else if in_range(rng[i + 1:], other.right_o) {
			or_cmp = -1
		} else {
			or_cmp = 1
		}

		if ol_cmp < 0 {
			break
		} else if ol_cmp == 0 {
			if or_cmp < 0 {
				scanning = true
				continue
			} else if or_cmp == 0 {
				if it.id.agent < other.id.agent {
					break
				}
				scanning = false
				continue
			} else {
				scanning = false
				continue
			}
		} else {
			continue
		}
	}

	before := dest < len(rng) ? rng[dest] : right
	link_before(s, it, before)
	store_add(d, it)
	if !it.deleted {
		s.vis += it.len
	}
	cache_check(s, it)
}

// cache_check keeps the search marker after a change at item `it` only when
// the change cannot have moved the marker: `it` is the marker or comes after
// it. Local edits change the item the marker was just set to, so the walk
// back is almost always zero or one step.
cache_check :: proc(s: ^Seq, it: ^Item) {
	if s.cache == nil {
		return
	}
	o := it
	for k := 0; k < 16 && o != nil; k += 1 {
		if o == s.cache {
			return
		}
		o = o.prev
	}
	s.cache = nil
}

// ---------------------------------------------------------------------------
// Positions
// ---------------------------------------------------------------------------

// locate finds the item containing visible offset `pos` and the offset inside
// it. `pos == s.vis` returns (nil, 0): the end. With `prefer_end`, an offset
// on a boundary resolves to the end of the item on its left instead, which is
// what "the element before the caret" wants.
locate :: proc(s: ^Seq, pos: u64) -> (^Item, u64) {
	if pos >= s.vis {
		return nil, 0
	}
	it := s.head
	off: u64 = 0
	if s.cache != nil && s.cache.seq == s {
		it = s.cache
		off = s.cache_off
		// walk back when the target is before the marker
		for it != nil && pos < off {
			it = it.prev
			if it != nil {
				off -= visible_len(it)
			}
		}
		if it == nil {
			it = s.head
			off = 0
		}
	}
	for it != nil {
		l := visible_len(it)
		if pos < off + l {
			s.cache = it
			s.cache_off = off
			return it, pos - off
		}
		off += l
		it = it.next
	}
	return nil, 0
}

// id_at is the ID of the visible element at `pos`.
id_at :: proc(s: ^Seq, pos: u64) -> ID {
	it, off := locate(s, pos)
	if it == nil {
		return NONE
	}
	return ID{it.id.agent, it.id.seq + off}
}

// offset_of returns the visible offset of element `id`. A deleted element
// reports the offset where it would be, and `alive` false.
offset_of :: proc(d: ^Doc, id: ID) -> (off: u64, alive: bool, found: bool) {
	it, k := find_item(d, id)
	if it == nil {
		return 0, false, false
	}
	s := it.seq
	acc: u64 = 0
	for o := s.head; o != nil && o != it; o = o.next {
		acc += visible_len(o)
	}
	if it.deleted {
		return acc, false, true
	}
	return acc + k, true, true
}

clone_str :: proc(s: string, a: mem.Allocator) -> string {
	b := make([]u8, len(s), a)
	copy(b, s)
	return string(b)
}

clone_bytes :: proc(s: []u8, a: mem.Allocator) -> []u8 {
	if len(s) == 0 {
		return nil
	}
	b := make([]u8, len(s), a)
	copy(b, s)
	return b
}

_ :: slice
