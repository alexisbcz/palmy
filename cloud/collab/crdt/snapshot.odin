package crdt

// Snapshots: the whole state of a document, in list order, so loading one is
// linking items rather than re-integrating every operation ever made.
//
//	'S' 0x01  agents  version  lamport  seqs  regs  pending
//
// A snapshot plus every update after it reproduces the document exactly; the
// sync service stores one every so often so that opening a document never
// replays its whole history (see cloud/docs/office.md).

import "core:encoding/endian"
import "core:fmt"
import "core:slice"
import "core:strings"

@(private)
put_stamp :: proc(e: ^Encoder, st: Stamp) {
	put_uv(&e.body, st.lamport)
	if st.agent == 0 {
		put_uv(&e.body, 0)
	} else {
		put_uv(&e.body, agent_ix(e, st.agent) + 1)
	}
}

@(private)
get_stamp :: proc(r: ^Reader, agents: []u64) -> Stamp {
	l := get_uv(r)
	i := get_uv(r)
	if i == 0 {
		return Stamp{l, 0}
	}
	if i - 1 >= u64(len(agents)) {
		r.bad = true
		return {}
	}
	return Stamp{l, agents[i - 1]}
}

sorted_keys :: proc(m: map[string]$V, allocator := context.temp_allocator) -> []string {
	ks := make([dynamic]string, 0, len(m), allocator)
	for k in m {
		append(&ks, k)
	}
	slice.sort(ks[:])
	return ks[:]
}

// encode_state writes a snapshot of `d`.
encode_state :: proc(d: ^Doc, allocator := context.allocator) -> []u8 {
	e: Encoder
	defer encoder_destroy(&e)
	b := &e.body

	agents := make([dynamic]u64, 0, len(d.next), context.temp_allocator)
	for a in d.next {append(&agents, a)}
	slice.sort(agents[:])
	put_uv(b, u64(len(agents)))
	for a in agents {
		put_uv(b, agent_ix(&e, a))
		put_uv(b, d.next[a])
	}
	put_uv(b, d.lamport)

	keys := sorted_keys(d.seqs)
	put_uv(b, u64(len(keys)))
	for k in keys {
		s := d.seqs[k]
		put_str(b, k)
		n := 0
		for it := s.head; it != nil; it = it.next {n += 1}
		put_uv(b, u64(n))
		for it := s.head; it != nil; it = it.next {
			put_id(&e, it.id)
			put_uv(b, it.len)
			put_id(&e, it.left_o)
			put_id(&e, it.right_o)
			append(b, u8(it.kind), it.flags, it.deleted ? 1 : 0)
			put_stamp(&e, it.dstamp)
			if it.kind != .Virtual {
				put_bytes(b, it.content[:])
			}
		}
		put_uv(b, u64(len(s.marks)))
		for m in s.marks {
			put_id(&e, m.id)
			put_stamp(&e, m.stamp)
			put_anchor(&e, m.start)
			put_anchor(&e, m.end)
			put_str(b, m.attr)
			put_bytes(b, m.value)
			append(b, m.deleted ? 1 : 0)
			put_stamp(&e, m.dstamp)
		}
	}

	owners := sorted_keys(d.regs)
	put_uv(b, u64(len(owners)))
	for o in owners {
		t := d.regs[o]
		put_str(b, o)
		fields := sorted_keys(t^)
		put_uv(b, u64(len(fields)))
		for f in fields {
			r := t[f]
			put_str(b, f)
			put_bytes(b, r.value)
			put_stamp(&e, r.stamp)
			put_id(&e, r.id)
			append(b, r.unset ? 1 : 0)
		}
	}

	put_uv(b, u64(len(d.pending)))
	for p in d.pending {
		put_bytes(b, p)
	}

	out := make([dynamic]u8, allocator)
	append(&out, 'S', 1)
	put_uv(&out, u64(len(e.agents)))
	for a in e.agents {
		var: [8]u8
		endian.put_u64(var[:], .Little, a)
		append(&out, ..var[:])
	}
	append(&out, ..e.body[:])
	return out[:]
}

// doc_load builds a document from a snapshot, for local agent `agent`.
doc_load :: proc(agent: u64, data: []u8, allocator := context.allocator) -> (d: ^Doc, ok: bool) {
	if len(data) < 2 || data[0] != 'S' || data[1] != 1 {
		return nil, false
	}
	r := Reader {
		data = data,
		i    = 2,
	}
	na := get_uv(&r)
	if r.bad || na > u64(len(data)) {
		return nil, false
	}
	agents := make([]u64, na, context.temp_allocator)
	for k in 0 ..< na {
		raw := get_raw(&r, 8)
		if r.bad {return nil, false}
		agents[k] = endian.unchecked_get_u64le(raw)
	}
	d = doc_make(agent, allocator)
	context.allocator = allocator
	fail := proc(d: ^Doc) -> (^Doc, bool) {
		doc_destroy(d)
		return nil, false
	}

	nv := get_uv(&r)
	if r.bad || nv > u64(len(data)) {return fail(d)}
	for _ in 0 ..< nv {
		a := get_agent(&r, agents)
		d.next[a] = get_uv(&r)
	}
	d.lamport = get_uv(&r)

	ns := get_uv(&r)
	if r.bad || ns > u64(len(data)) {return fail(d)}
	for _ in 0 ..< ns {
		key := get_str(&r)
		if r.bad {return fail(d)}
		s := seq_get(d, key)
		ni := get_uv(&r)
		if r.bad || ni > u64(len(data)) {return fail(d)}
		for _ in 0 ..< ni {
			it := new(Item)
			it.id = get_id(&r, agents)
			it.len = get_uv(&r)
			it.left_o = get_id(&r, agents)
			it.right_o = get_id(&r, agents)
			k := get_u8(&r)
			it.flags = get_u8(&r)
			it.deleted = get_u8(&r) != 0
			it.dstamp = get_stamp(&r, agents)
			if k > 2 || r.bad || it.len == 0 || it.id.agent == 0 {
				free(it)
				return fail(d)
			}
			it.kind = Kind(k)
			if it.kind != .Virtual {
				c := get_bytes(&r)
				it.content = make([dynamic]u8, len(c))
				copy(it.content[:], c)
			}
			link_before(s, it, nil)
			a := agent_store(d, it.id.agent)
			append(&a.items, it)
			if !it.deleted {
				s.vis += it.len
			}
		}
		nm := get_uv(&r)
		if r.bad || nm > u64(len(data)) {return fail(d)}
		for _ in 0 ..< nm {
			m := new(Mark)
			m.id = get_id(&r, agents)
			m.stamp = get_stamp(&r, agents)
			m.start = get_anchor(&r, agents)
			m.end = get_anchor(&r, agents)
			m.attr = clone_str(get_str(&r), allocator)
			m.value = clone_bytes(get_bytes(&r), allocator)
			m.deleted = get_u8(&r) != 0
			m.dstamp = get_stamp(&r, agents)
			m.seq = s
			append(&s.marks, m)
			d.marks[m.id] = m
			if r.bad {return fail(d)}
		}
	}
	for _, a in d.agents {
		slice.sort_by(a.items[:], proc(x, y: ^Item) -> bool {return x.id.seq < y.id.seq})
	}

	no := get_uv(&r)
	if r.bad || no > u64(len(data)) {return fail(d)}
	for _ in 0 ..< no {
		owner := get_str(&r)
		nf := get_uv(&r)
		if r.bad || nf > u64(len(data)) {return fail(d)}
		t := new(Reg_Table)
		t^ = make(Reg_Table)
		d.regs[clone_str(owner, allocator)] = t
		for _ in 0 ..< nf {
			f := get_str(&r)
			v := get_bytes(&r)
			st := get_stamp(&r, agents)
			id := get_id(&r, agents)
			unset := get_u8(&r) != 0
			if r.bad {return fail(d)}
			t[clone_str(f, allocator)] = Reg {
				value = clone_bytes(v, allocator),
				stamp = st,
				id    = id,
				unset = unset,
			}
		}
	}
	np := get_uv(&r)
	if r.bad || np > u64(len(data)) {return fail(d)}
	for _ in 0 ..< np {
		p := get_bytes(&r)
		if r.bad {return fail(d)}
		append(&d.pending, clone_bytes(p, allocator))
	}
	if r.bad || r.i != len(data) {
		return fail(d)
	}
	return d, true
}

// dump is a canonical text form of the converged state: element order and
// liveness (independent of how items happen to be split), formatting as read,
// registers and marks. Two replicas have converged exactly when their dumps
// are equal. Used by the tests.
dump :: proc(d: ^Doc, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	for k in sorted_keys(d.seqs) {
		s := d.seqs[k]
		fmt.sbprintf(&b, "seq %q vis=%d\n", k, s.vis)
		// element runs, merged across item boundaries
		have := false
		ra, rs, rl: u64
		rdel := false
		flush :: proc(b: ^strings.Builder, have: bool, a, s, l: u64, del: bool) {
			if have {
				fmt.sbprintf(b, "  %x:%d+%d%s\n", a, s, l, del ? " del" : "")
			}
		}
		for it := s.head; it != nil; it = it.next {
			if have && it.id.agent == ra && it.id.seq == rs + rl && it.deleted == rdel {
				rl += it.len
				continue
			}
			flush(&b, have, ra, rs, rl, rdel)
			have = true
			ra, rs, rl, rdel = it.id.agent, it.id.seq, it.len, it.deleted
		}
		flush(&b, have, ra, rs, rl, rdel)
		write_spans(&b, d, k)
	}
	for o in sorted_keys(d.regs) {
		t := d.regs[o]
		for f in sorted_keys(t^) {
			r := t[f]
			if r.unset {continue}
			fmt.sbprintf(&b, "reg %q %q = %q\n", o, f, string(r.value))
		}
	}
	return strings.to_string(b)
}

// write_spans prints a sequence's visible content with its formatting,
// merging adjacent text that shares attributes, so the result does not depend
// on how a replica happens to have split its items.
write_spans :: proc(b: ^strings.Builder, d: ^Doc, key: string) {
	sp := read_spans(d, key)
	i := 0
	for i < len(sp.spans) {
		x := sp.spans[i]
		fmt.sbprintf(b, "  span %v f%d [", x.kind, x.flags)
		for a in sp.attrs[x.attrs] {
			fmt.sbprintf(b, "%s=%q ", a.name, string(a.value))
		}
		strings.write_string(b, "] ")
		j := i + 1
		switch x.kind {
		case .Virtual:
			n := x.len
			for j < len(sp.spans) && sp.spans[j].kind == .Virtual && sp.spans[j].attrs == x.attrs && sp.spans[j].flags == x.flags {
				n += sp.spans[j].len
				j += 1
			}
			fmt.sbprintf(b, "%d\n", n)
		case .Embed:
			fmt.sbprintf(b, "%q\n", string(x.content))
		case .Text:
			t := strings.builder_make(context.temp_allocator)
			strings.write_bytes(&t, x.content)
			for j < len(sp.spans) && sp.spans[j].kind == .Text && sp.spans[j].attrs == x.attrs && sp.spans[j].flags == x.flags {
				strings.write_bytes(&t, sp.spans[j].content)
				j += 1
			}
			fmt.sbprintf(b, "%q\n", strings.to_string(t))
		}
		i = j
	}
}
