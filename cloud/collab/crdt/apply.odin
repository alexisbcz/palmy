package crdt

// Applying operations. Local edits and remote updates go through the same
// `apply_op`, so there is exactly one implementation of what an operation
// means; a local edit merely computes its origins from a visible position
// first.

Apply_Result :: enum u8 {
	Done,
	Duplicate,
	Missing, // something it depends on has not arrived yet
	Invalid,
}

// deps_present reports whether everything `op` refers to has been applied.
deps_present :: proc(d: ^Doc, op: ^Op) -> bool {
	switch op.kind {
	case .Insert:
		return has_id(d, op.left_o) && has_id(d, op.right_o)
	case .Delete, .Restore:
		for r in op.ranges {
			if !has_id(d, ID{r.id.agent, r.id.seq + r.len - 1}) {
				return false
			}
		}
		return true
	case .Mark:
		return has_id(d, op.start.id) && has_id(d, op.end.id)
	case .Set:
		return true
	}
	return true
}

touch_seq :: proc(d: ^Doc, key: string) {
	if key not_in d.touched_seqs {
		d.touched_seqs[clone_str(key, d.allocator)] = true
	}
}

touch_reg :: proc(d: ^Doc, owner: string) {
	if owner not_in d.touched_regs {
		d.touched_regs[clone_str(owner, d.allocator)] = true
	}
}

// apply_op applies one operation. `local` ops are recorded for undo.
apply_op :: proc(d: ^Doc, op_in: ^Op, local := false) -> Apply_Result {
	op := op_in^
	nxt := d.next[op.id.agent]
	span := op_span(&op)
	if op.id.seq + span <= nxt {
		return .Duplicate
	}
	if op.id.seq > nxt {
		return .Missing
	}
	if op.id.seq < nxt {
		// Only an insert spans more than one seq, so only an insert can
		// overlap what is already here. Keep the part that is new.
		if op.kind != .Insert {
			return .Duplicate
		}
		k := nxt - op.id.seq
		op.left_o = ID{op.id.agent, nxt - 1}
		op.id.seq = nxt
		op.len -= k
		if op.ikind == .Text {
			op.content = op.content[k:]
		}
	}
	if !deps_present(d, &op) {
		return .Missing
	}

	stamp := Stamp{op.lamport, op.id.agent}
	switch op.kind {
	case .Insert:
		s := seq_get(d, op.key)
		it := new(Item, d.allocator)
		it.id = op.id
		it.len = op.len
		it.left_o = op.left_o
		it.right_o = op.right_o
		it.kind = op.ikind
		it.flags = op.flags
		if op.ikind != .Virtual {
			it.content = make([dynamic]u8, len(op.content), d.allocator)
			copy(it.content[:], op.content)
		}
		if !try_extend(d, s, it) {
			integrate(d, s, it)
		}
		touch_seq(d, s.key)
		d.structural = true
		if local && d.recording != nil {
			append(&d.recording.inserted, Range{op.id, op.len})
		}
	case .Delete, .Restore:
		del := op.kind == .Delete
		for r in op.ranges {
			set_deleted(d, r, del, stamp, local)
		}
	case .Set:
		t, ok := d.regs[op.key]
		if !ok {
			t = new(Reg_Table, d.allocator)
			t^ = make(Reg_Table, 4, d.allocator)
			d.regs[clone_str(op.key, d.allocator)] = t
		}
		cur, has := t[op.field]
		if local && d.recording != nil {
			append(
				&d.recording.sets,
				Txn_Set {
					owner = clone_str(op.key, d.allocator),
					field = clone_str(op.field, d.allocator),
					had = has && !cur.unset,
					prev = has ? clone_bytes(cur.value, d.allocator) : nil,
					mine = op.id,
				},
			)
		}
		if !has || stamp_less(cur.stamp, stamp) {
			if has {
				delete(cur.value, d.allocator)
				t[op.field] = Reg {
					value = clone_bytes(op.value, d.allocator),
					stamp = stamp,
					id    = op.id,
					unset = op.unset,
				}
			} else {
				t[clone_str(op.field, d.allocator)] = Reg {
					value = clone_bytes(op.value, d.allocator),
					stamp = stamp,
					id    = op.id,
					unset = op.unset,
				}
			}
			touch_reg(d, op.key)
		}
	case .Mark:
		s := seq_get(d, op.key)
		m := new(Mark, d.allocator)
		m.id = op.id
		m.stamp = stamp
		m.seq = s
		m.start = op.start
		m.end = op.end
		m.attr = clone_str(op.attr, d.allocator)
		m.value = clone_bytes(op.value, d.allocator)
		append(&s.marks, m)
		d.marks[m.id] = m
		touch_seq(d, s.key)
		if local && d.recording != nil {
			append(&d.recording.marks, m.id)
		}
	}
	d.next[op.id.agent] = op.id.seq + op_span(&op)
	if op.lamport > d.lamport {
		d.lamport = op.lamport
	}
	return .Done
}

// try_extend appends a local continuation to the item it continues, so a
// typed word is one item rather than one per keystroke. The result is
// identical to integrating it: the new elements' origins are exactly what a
// split of the merged item would report.
try_extend :: proc(d: ^Doc, s: ^Seq, it: ^Item) -> bool {
	if it.kind != .Text || it.left_o.agent != it.id.agent {
		return false
	}
	l, off := find_item(d, it.left_o)
	if l == nil || l.seq != s || off + 1 != l.len {
		return false
	}
	// The merged elements share one delete state, so `l` must be in the state
	// a new element starts in: never deleted or restored.
	if l.kind != .Text || l.deleted || l.dstamp != (Stamp{}) || l.flags != it.flags || l.right_o != it.right_o {
		return false
	}
	if l.id.seq + l.len != it.id.seq {
		return false
	}
	// Only when nothing has been integrated between the end of `l` and its
	// right origin — otherwise ordering against that item must be decided.
	if l.right_o == NONE {
		if l.next != nil {
			return false
		}
	} else {
		r, roff := find_item(d, l.right_o)
		if r == nil || roff != 0 || l.next != r {
			return false
		}
	}
	append(&l.content, ..it.content[:])
	l.len += it.len
	if !l.deleted {
		s.vis += it.len
	}
	delete(it.content)
	free(it, d.allocator)
	cache_check(s, l)
	return true
}

// set_deleted applies a delete or restore to a range of elements, which may
// span several items, or to a mark.
set_deleted :: proc(d: ^Doc, r: Range, del: bool, stamp: Stamp, local: bool) {
	if r.len == 1 {
		if m, ok := d.marks[r.id]; ok {
			if stamp_less(m.dstamp, stamp) {
				was := m.deleted
				m.deleted = del
				m.dstamp = stamp
				touch_seq(d, m.seq.key)
				if local && d.recording != nil && was != del {
					append(&d.recording.mark_flips, Txn_Flip{m.id, del})
				}
			}
			return
		}
	}
	seq := r.id.seq
	end := r.id.seq + r.len
	for seq < end {
		it, off := find_item(d, ID{r.id.agent, seq})
		if it == nil {
			return
		}
		if off > 0 {
			it = split(d, it, off)
		}
		if seq + it.len > end {
			split(d, it, end - seq)
		}
		if stamp_less(it.dstamp, stamp) {
			if it.deleted != del {
				if del {
					it.seq.vis -= it.len
				} else {
					it.seq.vis += it.len
				}
				if local && d.recording != nil {
					append(&d.recording.flips, Txn_Range_Flip{Range{it.id, it.len}, del, stamp})
				}
			}
			it.deleted = del
			it.dstamp = stamp
			cache_check(it.seq, it)
			touch_seq(d, it.seq.key)
			d.structural = true
		}
		seq += it.len
	}
}

// apply_update applies a remote update. Operations whose dependencies have
// not arrived are kept and retried, so updates may arrive in any order.
apply_update :: proc(d: ^Doc, data: []u8) -> bool {
	dec, ok := decode_update(data)
	if !ok {
		return false
	}
	for &op in dec.ops {
		res := apply_op(d, &op)
		if res == .Missing {
			park(d, &op)
		}
	}
	retry_pending(d)
	return true
}

park :: proc(d: ^Doc, op: ^Op) {
	e: Encoder
	encode_op(&e, op)
	out := make([dynamic]u8, d.allocator)
	encoder_finish(&e, &out)
	encoder_destroy(&e)
	append(&d.pending, out[:])
}

retry_pending :: proc(d: ^Doc) {
	for {
		progress := false
		i := 0
		for i < len(d.pending) {
			dec, ok := decode_update(d.pending[i])
			if !ok || len(dec.ops) != 1 {
				delete(d.pending[i], d.allocator)
				ordered_remove(&d.pending, i)
				continue
			}
			res := apply_op(d, &dec.ops[0])
			if res == .Missing {
				i += 1
				continue
			}
			delete(d.pending[i], d.allocator)
			ordered_remove(&d.pending, i)
			progress = true
		}
		if !progress {
			return
		}
	}
}

// ---------------------------------------------------------------------------
// Local operations
// ---------------------------------------------------------------------------

next_id :: proc(d: ^Doc) -> ID {
	return ID{d.agent, d.next[d.agent]}
}

// emit applies a locally generated op and queues it for the network.
emit :: proc(d: ^Doc, op: ^Op) {
	op.id = next_id(d)
	op.lamport = d.lamport + 1
	res := apply_op(d, op, true)
	assert(res == .Done, "a local operation must apply")
	encode_op(&d.enc, op)
	d.out_ops += 1
}

// take_update returns everything emitted since the last call as one update,
// or nil when nothing was. The caller owns the result.
take_update :: proc(d: ^Doc, allocator := context.allocator) -> []u8 {
	if d.out_ops == 0 {
		return nil
	}
	out := make([dynamic]u8, allocator)
	encoder_finish(&d.enc, &out)
	encoder_reset(&d.enc)
	d.out_ops = 0
	return out[:]
}

// gap_origins returns the origins for an insertion at visible offset `pos`:
// the visible element before it, and whatever element (visible or not)
// follows that one.
gap_origins :: proc(s: ^Seq, pos: u64) -> (left, right: ID) {
	if pos == 0 {
		left = NONE
		if s.head != nil {
			right = s.head.id
		}
		return
	}
	it, off := locate(s, pos - 1)
	if it == nil {
		return NONE, NONE
	}
	left = ID{it.id.agent, it.id.seq + off}
	if off + 1 < it.len {
		right = ID{it.id.agent, it.id.seq + off + 1}
	} else if it.next != nil {
		right = it.next.id
	} else {
		right = NONE
	}
	return
}

// insert puts `content` at visible offset `pos` of sequence `key` and returns
// the ID of its first element.
insert :: proc(d: ^Doc, key: string, pos: u64, content: []u8, kind := Kind.Text, flags: u8 = 0) -> ID {
	s := seq_get(d, key)
	p := min(pos, s.vis)
	l, r := gap_origins(s, p)
	op := Op {
		kind    = .Insert,
		key     = key,
		left_o  = l,
		right_o = r,
		ikind   = kind,
		flags   = flags,
		content = content,
		len     = kind == .Text ? u64(len(content)) : 1,
	}
	if kind == .Text && len(content) == 0 {
		return NONE
	}
	emit(d, &op)
	return op.id
}

insert_text :: proc(d: ^Doc, key: string, pos: u64, text: string, flags: u8 = 0) -> ID {
	return insert(d, key, pos, transmute([]u8)text, .Text, flags)
}

insert_embed :: proc(d: ^Doc, key: string, pos: u64, payload: []u8, flags: u8 = 0) -> ID {
	return insert(d, key, pos, payload, .Embed, flags)
}

// insert_virtual adds `n` content-free elements: rows, columns.
insert_virtual :: proc(d: ^Doc, key: string, pos: u64, n: u64) -> ID {
	if n == 0 {
		return NONE
	}
	s := seq_get(d, key)
	p := min(pos, s.vis)
	l, r := gap_origins(s, p)
	op := Op {
		kind    = .Insert,
		key     = key,
		left_o  = l,
		right_o = r,
		ikind   = .Virtual,
		len     = n,
	}
	emit(d, &op)
	return op.id
}

// visible_ranges lists the IDs of `n` visible elements starting at `pos`,
// coalesced into runs.
visible_ranges :: proc(s: ^Seq, pos, n: u64, allocator := context.temp_allocator) -> []Range {
	out := make([dynamic]Range, 0, 4, allocator)
	if n == 0 || pos >= s.vis {
		return out[:]
	}
	it, off := locate(s, pos)
	left := min(n, s.vis - pos)
	for it != nil && left > 0 {
		if it.deleted {
			it = it.next
			off = 0
			continue
		}
		take := min(it.len - off, left)
		id := ID{it.id.agent, it.id.seq + off}
		if k := len(out); k > 0 && out[k - 1].id.agent == id.agent && out[k - 1].id.seq + out[k - 1].len == id.seq {
			out[k - 1].len += take
		} else {
			append(&out, Range{id, take})
		}
		left -= take
		it = it.next
		off = 0
	}
	return out[:]
}

// remove deletes `n` visible elements at `pos`.
remove :: proc(d: ^Doc, key: string, pos, n: u64) {
	s := seq_get(d, key, false)
	if s == nil || n == 0 {
		return
	}
	rs := visible_ranges(s, pos, n)
	if len(rs) == 0 {
		return
	}
	op := Op {
		kind   = .Delete,
		ranges = rs,
	}
	emit(d, &op)
}

// delete_ids and restore_ids act on elements (or marks) by identity.
delete_ids :: proc(d: ^Doc, rs: []Range) {
	if len(rs) == 0 {return}
	op := Op {
		kind   = .Delete,
		ranges = rs,
	}
	emit(d, &op)
}

restore_ids :: proc(d: ^Doc, rs: []Range) {
	if len(rs) == 0 {return}
	op := Op {
		kind   = .Restore,
		ranges = rs,
	}
	emit(d, &op)
}

// set writes a register. Writing the value it already holds is skipped, so a
// binding can call this freely.
set :: proc(d: ^Doc, owner, field: string, value: []u8) {
	if cur, ok := reg_get(d, owner, field); ok && bytes_equal(cur, value) {
		return
	}
	op := Op {
		kind  = .Set,
		key   = owner,
		field = field,
		value = value,
	}
	emit(d, &op)
}

set_str :: proc(d: ^Doc, owner, field, value: string) {
	set(d, owner, field, transmute([]u8)value)
}

// unset removes a register's value, as a write that can itself be undone.
unset :: proc(d: ^Doc, owner, field: string) {
	if _, ok := reg_get(d, owner, field); !ok {
		return
	}
	op := Op {
		kind  = .Set,
		key   = owner,
		field = field,
		unset = true,
	}
	emit(d, &op)
}

reg_get :: proc(d: ^Doc, owner, field: string) -> ([]u8, bool) {
	t, ok := d.regs[owner]
	if !ok {
		return nil, false
	}
	r, has := t[field]
	if !has || r.unset {
		return nil, false
	}
	return r.value, true
}

reg_str :: proc(d: ^Doc, owner, field: string, def := "") -> string {
	v, ok := reg_get(d, owner, field)
	return ok ? string(v) : def
}

bytes_equal :: proc(a, b: []u8) -> bool {
	if len(a) != len(b) {return false}
	for i in 0 ..< len(a) {
		if a[i] != b[i] {return false}
	}
	return true
}

// Expand says which edges of a formatting range grow when text is typed
// exactly at them. Bold and italic grow at the end, as in every word
// processor; links and comments grow at neither.
Expand :: enum u8 {
	None,
	End,
	Both,
}

// mark formats [from, to) of a sequence: `attr` takes `value`, or loses its
// value when `value` is empty.
mark :: proc(d: ^Doc, key: string, from, to: u64, attr: string, value: []u8, expand := Expand.End) -> ID {
	s := seq_get(d, key)
	if from >= to || from >= s.vis {
		return NONE
	}
	hi := min(to, s.vis)
	start, end: Anchor
	if expand == .Both && from > 0 {
		start = Anchor{id_at(s, from - 1), true}
	} else {
		start = Anchor{id_at(s, from), false}
	}
	if expand == .None {
		end = Anchor{id_at(s, hi - 1), true}
	} else if hi < s.vis {
		end = Anchor{id_at(s, hi), false}
	} else {
		end = Anchor{NONE, true}
	}
	op := Op {
		kind  = .Mark,
		key   = key,
		start = start,
		end   = end,
		attr  = attr,
		value = value,
	}
	emit(d, &op)
	return op.id
}
