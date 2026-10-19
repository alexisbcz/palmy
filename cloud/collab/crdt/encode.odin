package crdt

// The wire and storage format.
//
// An **update** is a batch of operations:
//
//	'U' 0x01  varint n_agents  n_agents x u64le   op...
//
// Agents are random 64-bit numbers, so every ID refers to them by index into
// the table at the front instead of repeating eight incompressible bytes per
// operation. Each op is
//
//	u8 kind   varint agent_index   varint seq   varint lamport   body
//
// and the bodies are, by kind:
//
//	Insert   str seq_key  id left  id right  u8 kind  u8 flags  varint len  content
//	Delete   varint n  (id varint len) x n
//	Restore  as Delete
//	Set      str owner  str field  u8 unset  bytes value
//	Mark     str seq_key  anchor start  anchor end  str attr  bytes value
//
// where `id` is `varint agent_index+1, varint seq` (0 meaning none), `anchor`
// is `id u8 after`, `str` and `bytes` are `varint len` then the bytes, and an
// Insert's content is `len` raw bytes for text, `bytes` for an embed and
// nothing for a virtual run.
//
// A **snapshot** (snapshot.odin) has its own layout, 'S' 0x01.

import "core:encoding/endian"

Op_Kind :: enum u8 {
	Insert  = 1,
	Delete  = 2,
	Restore = 3,
	Set     = 4,
	Mark    = 5,
}

Range :: struct {
	id:  ID,
	len: u64,
}

Op :: struct {
	kind:    Op_Kind,
	id:      ID,
	lamport: u64,
	key:     string, // sequence key (Insert, Mark) or register owner (Set)
	field:   string,
	left_o:  ID,
	right_o: ID,
	ikind:   Kind,
	flags:   u8,
	len:     u64,
	content: []u8,
	ranges:  []Range,
	start:   Anchor,
	end:     Anchor,
	attr:    string,
	value:   []u8,
	unset:   bool,
}

op_span :: proc(op: ^Op) -> u64 {
	return op.kind == .Insert ? op.len : 1
}

// ---------------------------------------------------------------------------
// Encoder
// ---------------------------------------------------------------------------

Encoder :: struct {
	agents: [dynamic]u64,
	index:  map[u64]u64,
	body:   [dynamic]u8,
}

encoder_destroy :: proc(e: ^Encoder) {
	delete(e.agents)
	delete(e.index)
	delete(e.body)
	e^ = {}
}

encoder_reset :: proc(e: ^Encoder) {
	clear(&e.agents)
	clear(&e.index)
	clear(&e.body)
}

put_uv :: proc(b: ^[dynamic]u8, v: u64) {
	x := v
	for x >= 0x80 {
		append(b, u8(x) | 0x80)
		x >>= 7
	}
	append(b, u8(x))
}

put_bytes :: proc(b: ^[dynamic]u8, s: []u8) {
	put_uv(b, u64(len(s)))
	append(b, ..s)
}

put_str :: proc(b: ^[dynamic]u8, s: string) {
	put_bytes(b, transmute([]u8)s)
}

agent_ix :: proc(e: ^Encoder, agent: u64) -> u64 {
	if i, ok := e.index[agent]; ok {
		return i
	}
	i := u64(len(e.agents))
	append(&e.agents, agent)
	e.index[agent] = i
	return i
}

put_id :: proc(e: ^Encoder, id: ID) {
	if id.agent == 0 {
		put_uv(&e.body, 0)
		return
	}
	put_uv(&e.body, agent_ix(e, id.agent) + 1)
	put_uv(&e.body, id.seq)
}

put_anchor :: proc(e: ^Encoder, a: Anchor) {
	put_id(e, a.id)
	append(&e.body, a.after ? 1 : 0)
}

encode_op :: proc(e: ^Encoder, op: ^Op) {
	b := &e.body
	append(b, u8(op.kind))
	put_uv(b, agent_ix(e, op.id.agent))
	put_uv(b, op.id.seq)
	put_uv(b, op.lamport)
	switch op.kind {
	case .Insert:
		put_str(b, op.key)
		put_id(e, op.left_o)
		put_id(e, op.right_o)
		append(b, u8(op.ikind), op.flags)
		put_uv(b, op.len)
		switch op.ikind {
		case .Text:
			append(b, ..op.content)
		case .Embed:
			put_bytes(b, op.content)
		case .Virtual:
		}
	case .Delete, .Restore:
		put_uv(b, u64(len(op.ranges)))
		for r in op.ranges {
			put_id(e, r.id)
			put_uv(b, r.len)
		}
	case .Set:
		put_str(b, op.key)
		put_str(b, op.field)
		append(b, op.unset ? 1 : 0)
		put_bytes(b, op.value)
	case .Mark:
		put_str(b, op.key)
		put_anchor(e, op.start)
		put_anchor(e, op.end)
		put_str(b, op.attr)
		put_bytes(b, op.value)
	}
}

// encoder_finish writes the agent table and the body into `out`.
encoder_finish :: proc(e: ^Encoder, out: ^[dynamic]u8) {
	append(out, 'U', 1)
	put_uv(out, u64(len(e.agents)))
	for a in e.agents {
		var: [8]u8
		endian.put_u64(var[:], .Little, a)
		append(out, ..var[:])
	}
	append(out, ..e.body[:])
}

// ---------------------------------------------------------------------------
// Decoder
// ---------------------------------------------------------------------------

Reader :: struct {
	data: []u8,
	i:    int,
	bad:  bool,
}

get_u8 :: proc(r: ^Reader) -> u8 {
	if r.i >= len(r.data) {
		r.bad = true
		return 0
	}
	v := r.data[r.i]
	r.i += 1
	return v
}

get_uv :: proc(r: ^Reader) -> u64 {
	v: u64 = 0
	shift: uint = 0
	for {
		if r.i >= len(r.data) || shift > 63 {
			r.bad = true
			return 0
		}
		c := r.data[r.i]
		r.i += 1
		v |= u64(c & 0x7f) << shift
		if c < 0x80 {
			return v
		}
		shift += 7
	}
}

get_raw :: proc(r: ^Reader, n: u64) -> []u8 {
	if n > u64(len(r.data) - r.i) {
		r.bad = true
		return nil
	}
	s := r.data[r.i:r.i + int(n)]
	r.i += int(n)
	return s
}

get_bytes :: proc(r: ^Reader) -> []u8 {
	return get_raw(r, get_uv(r))
}

get_str :: proc(r: ^Reader) -> string {
	return string(get_bytes(r))
}

Decoded :: struct {
	agents: []u64,
	ops:    [dynamic]Op,
}

get_agent :: proc(r: ^Reader, agents: []u64) -> u64 {
	i := get_uv(r)
	if i >= u64(len(agents)) {
		r.bad = true
		return 0
	}
	return agents[i]
}

get_id :: proc(r: ^Reader, agents: []u64) -> ID {
	i := get_uv(r)
	if i == 0 {
		return NONE
	}
	if i - 1 >= u64(len(agents)) {
		r.bad = true
		return NONE
	}
	return ID{agents[i - 1], get_uv(r)}
}

get_anchor :: proc(r: ^Reader, agents: []u64) -> Anchor {
	id := get_id(r, agents)
	return Anchor{id, get_u8(r) != 0}
}

// decode_update parses an update. Every slice in the result points into
// `data` or the temp allocator, so `data` must outlive the ops.
decode_update :: proc(data: []u8, allocator := context.temp_allocator) -> (dec: Decoded, ok: bool) {
	r := Reader {
		data = data,
	}
	if len(data) < 2 || data[0] != 'U' || data[1] != 1 {
		return {}, false
	}
	r.i = 2
	n := get_uv(&r)
	if r.bad || n > u64(len(data)) {
		return {}, false
	}
	agents := make([]u64, n, allocator)
	for k in 0 ..< n {
		raw := get_raw(&r, 8)
		if r.bad {
			return {}, false
		}
		agents[k] = endian.unchecked_get_u64le(raw)
	}
	ops := make([dynamic]Op, 0, 16, allocator)
	for r.i < len(data) {
		op: Op
		k := get_u8(&r)
		if k < 1 || k > 5 {
			return {}, false
		}
		op.kind = Op_Kind(k)
		op.id.agent = get_agent(&r, agents)
		op.id.seq = get_uv(&r)
		op.lamport = get_uv(&r)
		switch op.kind {
		case .Insert:
			op.key = get_str(&r)
			op.left_o = get_id(&r, agents)
			op.right_o = get_id(&r, agents)
			ik := get_u8(&r)
			if ik > 2 {
				return {}, false
			}
			op.ikind = Kind(ik)
			op.flags = get_u8(&r)
			op.len = get_uv(&r)
			switch op.ikind {
			case .Text:
				op.content = get_raw(&r, op.len)
			case .Embed:
				op.content = get_bytes(&r)
				if op.len != 1 {
					return {}, false
				}
			case .Virtual:
			}
			if op.len == 0 {
				return {}, false
			}
		case .Delete, .Restore:
			nr := get_uv(&r)
			if r.bad || nr > u64(len(data)) {
				return {}, false
			}
			rs := make([]Range, nr, allocator)
			for j in 0 ..< nr {
				rs[j].id = get_id(&r, agents)
				rs[j].len = get_uv(&r)
				if rs[j].id.agent == 0 || rs[j].len == 0 {
					return {}, false
				}
			}
			op.ranges = rs
		case .Set:
			op.key = get_str(&r)
			op.field = get_str(&r)
			op.unset = get_u8(&r) != 0
			op.value = get_bytes(&r)
		case .Mark:
			op.key = get_str(&r)
			op.start = get_anchor(&r, agents)
			op.end = get_anchor(&r, agents)
			op.attr = get_str(&r)
			op.value = get_bytes(&r)
		}
		if r.bad || op.id.agent == 0 {
			return {}, false
		}
		append(&ops, op)
	}
	return Decoded{agents = agents, ops = ops}, true
}
