package crdt

// Reading a sequence back: its visible elements, grouped into spans that
// share one set of formatting attributes.
//
// Formatting is resolved Peritext-style. Each live mark is active between its
// start anchor and its end anchor in list order — including over elements
// inserted later between them — and for every attribute the active mark with
// the greatest stamp wins. A winning mark with an empty value means "this
// attribute is off here", which is how un-bolding part of a bold range works
// without deleting the original mark.

import "core:mem"
import "core:slice"
import "core:strings"

Attr :: struct {
	name:  string,
	value: []u8,
}

Span :: struct {
	kind:    Kind,
	flags:   u8,
	first:   ID, // the first element
	len:     u64,
	content: []u8, // Text: the bytes; Embed: the payload; Virtual: nil
	attrs:   int, // index into the attribute table
}

Spans :: struct {
	spans: [dynamic]Span,
	attrs: [dynamic][]Attr, // attrs[0] is always the empty set
}

@(private)
Event :: struct {
	id:       ID,
	boundary: u64, // element offset within the item, filled per item
	after:    bool,
	start:    bool,
	m:        ^Mark,
}

@(private)
event_less :: proc(a, b: Event) -> bool {
	if a.id.agent != b.id.agent {return a.id.agent < b.id.agent}
	return a.id.seq < b.id.seq
}

// read_spans materialises sequence `key`. Everything returned is allocated in
// `allocator` except `content`, which points into the document and is valid
// until the next edit.
read_spans :: proc(d: ^Doc, key: string, allocator := context.temp_allocator) -> Spans {
	out := Spans {
		spans = make([dynamic]Span, 0, 16, allocator),
		attrs = make([dynamic][]Attr, 0, 4, allocator),
	}
	append(&out.attrs, []Attr{})
	s, ok := d.seqs[key]
	if !ok {
		return out
	}

	context.allocator = context.temp_allocator
	events := make([dynamic]Event, 0, len(s.marks) * 2)
	state := make(map[^Mark]u8)
	active := make([dynamic]^Mark, 0, 8)
	for m in s.marks {
		if m.deleted {continue}
		if m.start.id == NONE {
			if !m.start.after {
				append(&active, m)
				state[m] = 1
			}
		} else {
			append(&events, Event{id = m.start.id, after = m.start.after, start = true, m = m})
		}
		if m.end.id != NONE {
			append(&events, Event{id = m.end.id, after = m.end.after, start = false, m = m})
		}
	}
	slice.sort_by(events[:], event_less)

	sig_index := make(map[string]int)
	sig_index[""] = 0
	cur_attrs := 0
	dirty := true

	resolve :: proc(active: []^Mark, out: ^Spans, sig_index: ^map[string]int, allocator: mem.Allocator) -> int {
		// winner per attribute
		win := make([dynamic]^Mark, 0, len(active), context.temp_allocator)
		outer: for m in active {
			for &w in win {
				if w.attr == m.attr {
					if stamp_less(w.stamp, m.stamp) {
						w = m
					}
					continue outer
				}
			}
			append(&win, m)
		}
		slice.sort_by(win[:], proc(a, b: ^Mark) -> bool {return a.attr < b.attr})
		b := strings.builder_make(context.temp_allocator)
		n := 0
		for w in win {
			if len(w.value) == 0 {continue}
			strings.write_string(&b, w.attr)
			strings.write_byte(&b, 0)
			strings.write_bytes(&b, w.value)
			strings.write_byte(&b, 0)
			n += 1
		}
		sig := strings.to_string(b)
		if i, ok := sig_index[sig]; ok {
			return i
		}
		attrs := make([]Attr, n, allocator)
		k := 0
		for w in win {
			if len(w.value) == 0 {continue}
			attrs[k] = Attr{w.attr, w.value}
			k += 1
		}
		i := len(out.attrs)
		append(&out.attrs, attrs)
		sig_index[sig] = i
		return i
	}

	apply_event :: proc(e: Event, state: ^map[^Mark]u8, active: ^[dynamic]^Mark) -> bool {
		st := state[e.m]
		if e.start {
			if st == 0 {
				state[e.m] = 1
				append(active, e.m)
				return true
			}
		} else {
			if st == 1 {
				for a, i in active {
					if a == e.m {
						unordered_remove(active, i)
						break
					}
				}
				state[e.m] = 2
				return true
			}
			state[e.m] = 2
		}
		return false
	}

	emit_span :: proc(out: ^Spans, it: ^Item, from, to: u64, attrs: int) {
		if to <= from || it.deleted {
			return
		}
		sp := Span {
			kind  = it.kind,
			flags = it.flags,
			first = ID{it.id.agent, it.id.seq + from},
			len   = to - from,
			attrs = attrs,
		}
		switch it.kind {
		case .Text:
			sp.content = it.content[from:to]
		case .Embed:
			sp.content = it.content[:]
		case .Virtual:
		}
		// Coalesce with the previous span when it continues it exactly.
		if n := len(out.spans); n > 0 {
			p := &out.spans[n - 1]
			if p.kind == .Virtual && sp.kind == .Virtual && p.attrs == sp.attrs && p.flags == sp.flags &&
			   p.first.agent == sp.first.agent && p.first.seq + p.len == sp.first.seq {
				p.len += sp.len
				return
			}
		}
		append(&out.spans, sp)
	}

	local := make([dynamic]Event, 0, 8)
	for it := s.head; it != nil; it = it.next {
		// The events anchored inside this item.
		clear(&local)
		if len(events) > 0 {
			lo, hi := 0, len(events)
			for lo < hi {
				mid := (lo + hi) / 2
				if event_less(events[mid], Event{id = it.id}) {
					lo = mid + 1
				} else {
					hi = mid
				}
			}
			for j := lo; j < len(events); j += 1 {
				e := events[j]
				if e.id.agent != it.id.agent || e.id.seq >= it.id.seq + it.len {break}
				if e.id.seq < it.id.seq {continue}
				e.boundary = e.id.seq - it.id.seq + (e.after ? 1 : 0)
				append(&local, e)
			}
			slice.sort_by(local[:], proc(a, b: Event) -> bool {
				if a.boundary != b.boundary {return a.boundary < b.boundary}
				// At one boundary, ends close before starts open, so a mark
				// ending where another begins does not leak into it.
				return !a.start && b.start
			})
		}
		at: u64 = 0
		for e in local {
			if dirty {
				cur_attrs = resolve(active[:], &out, &sig_index, allocator)
				dirty = false
			}
			emit_span(&out, it, at, e.boundary, cur_attrs)
			at = max(at, e.boundary)
			if apply_event(e, &state, &active) {
				dirty = true
			}
		}
		if dirty {
			cur_attrs = resolve(active[:], &out, &sig_index, allocator)
			dirty = false
		}
		emit_span(&out, it, at, it.len, cur_attrs)
	}
	return out
}

// attr_get finds an attribute's value in a set.
attr_get :: proc(set: []Attr, name: string) -> ([]u8, bool) {
	for a in set {
		if a.name == name {
			return a.value, true
		}
	}
	return nil, false
}

// read_text is the visible text of a sequence (embeds as U+FFFC), for tests
// and plain-text consumers.
read_text :: proc(d: ^Doc, key: string, allocator := context.temp_allocator) -> string {
	s, ok := d.seqs[key]
	if !ok {
		return ""
	}
	b := strings.builder_make(allocator)
	for it := s.head; it != nil; it = it.next {
		if it.deleted {continue}
		switch it.kind {
		case .Text:
			strings.write_bytes(&b, it.content[:])
		case .Embed:
			strings.write_string(&b, "￼")
		case .Virtual:
		}
	}
	return strings.to_string(b)
}

// ---------------------------------------------------------------------------
// Sticky positions
// ---------------------------------------------------------------------------

// Sticky is a caret that survives other people's edits: it names the element
// it sits after (or the start of the sequence), not an offset.
Sticky :: struct {
	after: ID, // NONE: the start
}

sticky_at :: proc(d: ^Doc, key: string, pos: u64) -> Sticky {
	s := seq_get(d, key, false)
	if s == nil || pos == 0 {
		return {}
	}
	return Sticky{id_at(s, min(pos, s.vis) - 1)}
}

// sticky_resolve gives the visible offset now. When the element it sat after
// has been deleted, the caret lands where that element was.
sticky_resolve :: proc(d: ^Doc, st: Sticky) -> u64 {
	if st.after == NONE {
		return 0
	}
	off, alive, found := offset_of(d, st.after)
	if !found {
		return 0
	}
	return alive ? off + 1 : off
}
