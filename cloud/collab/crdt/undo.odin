package crdt

// Undo and redo, per replica.
//
// Collaborative undo must undo *your* last change, not the document's: a
// snapshot-swapping undo would erase whatever a collaborator typed in the
// meantime. So each local transaction records what it did — elements it
// inserted, elements it deleted or restored, marks it added, registers it
// wrote with their previous values — and undo emits the inverse as ordinary
// new operations, which then merge with everyone else's like any edit.
//
// Two rules keep undo from trampling other people:
//
//   * a register is set back only if this replica wrote the value it holds
//     now; if someone else has changed it since, their change stands;
//   * a deletion (or restoration) is reverted only for elements whose state is
//     still the one this transaction set, last set by this replica.
//
// Inserted elements are deleted on undo and restored on redo — the same
// elements, so comments and cursors anchored to them survive the round trip.

Txn_Set :: struct {
	owner: string,
	field: string,
	had:   bool,
	prev:  []u8,
	mine:  ID, // the op that wrote the new value
}

Txn_Flip :: struct {
	id:  ID, // a mark
	del: bool, // what the transaction set it to
}

Txn_Range_Flip :: struct {
	r:     Range,
	del:   bool,
	stamp: Stamp,
}

Txn :: struct {
	inserted:   [dynamic]Range,
	flips:      [dynamic]Txn_Range_Flip,
	marks:      [dynamic]ID,
	mark_flips: [dynamic]Txn_Flip,
	sets:       [dynamic]Txn_Set,
	tag:        int, // the binding's notion of an edit kind, for coalescing
	// Opaque to the CRDT: the binding stores where the caret was before the
	// transaction, so undo can put it back.
	before:     [dynamic]u8,
}

Undo :: struct {
	undo:  [dynamic]^Txn,
	redo:  [dynamic]^Txn,
	open:  bool, // the newest undo entry still absorbs same-tag edits
	limit: int,
}

txn_destroy :: proc(d: ^Doc, t: ^Txn) {
	context.allocator = d.allocator
	delete(t.inserted)
	delete(t.flips)
	delete(t.marks)
	delete(t.mark_flips)
	for s in t.sets {
		delete(s.owner)
		delete(s.field)
		delete(s.prev)
	}
	delete(t.sets)
	delete(t.before)
	free(t)
}

txn_empty :: proc(t: ^Txn) -> bool {
	return len(t.inserted) == 0 && len(t.flips) == 0 && len(t.marks) == 0 && len(t.mark_flips) == 0 && len(t.sets) == 0
}

undo_destroy :: proc(d: ^Doc) {
	for t in d.undo.undo {txn_destroy(d, t)}
	for t in d.undo.redo {txn_destroy(d, t)}
	delete(d.undo.undo)
	delete(d.undo.redo)
	if d.recording != nil {
		txn_destroy(d, d.recording)
		d.recording = nil
	}
}

txn_new :: proc(d: ^Doc) -> ^Txn {
	context.allocator = d.allocator
	t := new(Txn)
	return t
}

// begin starts recording a local edit. `tag` groups consecutive edits of the
// same kind into one undo step (typing a word is one step); pass a tag of 0
// for an edit that never coalesces.
begin :: proc(d: ^Doc, tag := 0, before: []u8 = nil) {
	if d.recording != nil {
		return
	}
	t := txn_new(d)
	t.tag = tag
	if len(before) > 0 {
		append(&t.before, ..before)
	}
	d.recording = t
}

// commit ends the edit begun by `begin` and files it for undo.
commit :: proc(d: ^Doc) {
	t := d.recording
	if t == nil {
		return
	}
	d.recording = nil
	if txn_empty(t) {
		txn_destroy(d, t)
		return
	}
	for r in d.undo.redo {txn_destroy(d, r)}
	clear(&d.undo.redo)
	u := &d.undo
	if u.open && t.tag != 0 && len(u.undo) > 0 && u.undo[len(u.undo) - 1].tag == t.tag {
		last := u.undo[len(u.undo) - 1]
		append(&last.inserted, ..t.inserted[:])
		append(&last.flips, ..t.flips[:])
		append(&last.marks, ..t.marks[:])
		append(&last.mark_flips, ..t.mark_flips[:])
		append(&last.sets, ..t.sets[:])
		clear(&t.sets) // ownership moved
		txn_destroy(d, t)
		return
	}
	append(&u.undo, t)
	u.open = t.tag != 0
	limit := u.limit > 0 ? u.limit : 500
	for len(u.undo) > limit {
		txn_destroy(d, u.undo[0])
		ordered_remove(&u.undo, 0)
	}
}

// close_group stops the newest undo step from absorbing further edits.
close_group :: proc(d: ^Doc) {
	d.undo.open = false
}

can_undo :: proc(d: ^Doc) -> bool {return len(d.undo.undo) > 0}
can_redo :: proc(d: ^Doc) -> bool {return len(d.undo.redo) > 0}

// invert emits the inverse of `t` as a new recorded transaction and returns it.
@(private)
invert :: proc(d: ^Doc, t: ^Txn) -> ^Txn {
	begin(d, 0, t.before[:])
	// Registers, newest first, so a field written twice in one step returns to
	// the value it had before the step.
	#reverse for s in t.sets {
		tab, ok := d.regs[s.owner]
		if !ok {continue}
		cur, has := tab[s.field]
		if !has || cur.id.agent != d.agent {
			continue // someone else wrote it since
		}
		if s.had {
			op := Op {
				kind  = .Set,
				key   = s.owner,
				field = s.field,
				value = s.prev,
			}
			emit(d, &op)
		} else {
			op := Op {
				kind  = .Set,
				key   = s.owner,
				field = s.field,
				unset = true,
			}
			emit(d, &op)
		}
	}
	// Marks this step added are withdrawn; marks it withdrew come back.
	for id in t.marks {
		if m, ok := d.marks[id]; ok && !m.deleted {
			delete_ids(d, {Range{id, 1}})
		}
	}
	#reverse for f in t.mark_flips {
		if m, ok := d.marks[f.id]; ok && m.deleted == f.del {
			if f.del {
				restore_ids(d, {Range{f.id, 1}})
			} else {
				delete_ids(d, {Range{f.id, 1}})
			}
		}
	}
	// Deletions and restorations are reverted where they still hold.
	back_del := make([dynamic]Range, 0, 4, context.temp_allocator)
	back_res := make([dynamic]Range, 0, 4, context.temp_allocator)
	#reverse for f in t.flips {
		collect_still(d, f, &back_del, &back_res)
	}
	restore_ids(d, back_res[:])
	delete_ids(d, back_del[:])
	// What this step inserted is deleted.
	ins := make([dynamic]Range, 0, 4, context.temp_allocator)
	for r in t.inserted {
		alive_ranges(d, r, &ins)
	}
	delete_ids(d, ins[:])

	inv := d.recording
	d.recording = nil
	return inv
}

// collect_still finds the parts of a flipped range whose state is still the
// one the flip set, and files them as the inverse.
@(private)
collect_still :: proc(d: ^Doc, f: Txn_Range_Flip, back_del, back_res: ^[dynamic]Range) {
	seq := f.r.id.seq
	end := f.r.id.seq + f.r.len
	for seq < end {
		it, off := find_item(d, ID{f.r.id.agent, seq})
		if it == nil {return}
		take := min(it.len - off, end - seq)
		if it.deleted == f.del && it.dstamp.agent == d.agent {
			r := Range{ID{f.r.id.agent, seq}, take}
			if f.del {
				append(back_res, r)
			} else {
				append(back_del, r)
			}
		}
		seq += take
	}
}

@(private)
alive_ranges :: proc(d: ^Doc, r: Range, out: ^[dynamic]Range) {
	seq := r.id.seq
	end := r.id.seq + r.len
	for seq < end {
		it, off := find_item(d, ID{r.id.agent, seq})
		if it == nil {return}
		take := min(it.len - off, end - seq)
		if !it.deleted {
			append(out, Range{ID{r.id.agent, seq}, take})
		}
		seq += take
	}
}

// undo reverts the newest local step. It returns the caret bytes the binding
// stored when the step began, and false when there was nothing to undo.
undo :: proc(d: ^Doc) -> (before: []u8, ok: bool) {
	u := &d.undo
	if len(u.undo) == 0 {
		return nil, false
	}
	t := pop(&u.undo)
	inv := invert(d, t)
	u.open = false
	before = clone_bytes(t.before[:], context.temp_allocator)
	if inv != nil {
		append(&u.redo, inv)
	}
	txn_destroy(d, t)
	return before, true
}

redo :: proc(d: ^Doc) -> (ok: bool) {
	u := &d.undo
	if len(u.redo) == 0 {
		return false
	}
	t := pop(&u.redo)
	inv := invert(d, t)
	u.open = false
	if inv != nil {
		append(&u.undo, inv)
	}
	txn_destroy(d, t)
	return true
}
