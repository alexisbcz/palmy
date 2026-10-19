// Convergence fuzzing for cloud/collab/crdt.
//
//	odin run cloud/collab/fuzz -- [rounds] [replicas] [seed]
//
// Every round builds N replicas with random 64-bit agents and lets them edit
// one document concurrently: text inserts (ASCII and multi-byte), deletions,
// formatting marks with every expand rule, registers set and unset, embeds,
// virtual runs, grouped transactions, and per-replica undo and redo. Updates
// travel through a hostile network: delivered late, out of order, twice, and
// with replicas partitioned for stretches. At the end of the round everything
// is delivered and the replicas must be identical — the same canonical dump,
// which covers element order, liveness, resolved formatting and registers —
// and a snapshot of each must load back to the same state.
//
// Two further properties are checked on the side:
//
//   * an oracle: a single replica's visible text always equals a plain string
//     edited with the same position-based operations;
//   * undo is exact when nobody else is editing: undoing a step restores the
//     visible state (text, formatting, registers) from before it.
package fuzz

import "core:fmt"
import "core:math/rand"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import crdt "../crdt"

KEYS := [?]string{"body", "cell/r1/c1", "notes"}
ATTRS := [?]string{"b", "i", "u", "color", "comment"}
WORDS := [?]string{"a", "bc", "def", "é", "日本", "x\n", "\n", "hello ", "🙂"}

Msg :: struct {
	from: int,
	data: []u8,
}

Replica :: struct {
	doc:   ^crdt.Doc,
	inbox: [dynamic]Msg,
	cut:   int, // rounds left partitioned
}

fail_count := 0

check :: proc(ok: bool, format: string, args: ..any) {
	if !ok {
		fail_count += 1
		fmt.eprintf("FAIL: ")
		fmt.eprintfln(format, ..args)
	}
}

// visible is what a user can see: text with formatting, and registers.
visible :: proc(d: ^crdt.Doc) -> string {
	b := strings.builder_make(context.temp_allocator)
	for k in KEYS {
		fmt.sbprintf(&b, "%s:\n", k)
		crdt.write_spans(&b, d, k)
	}
	for o in crdt.sorted_keys(d.regs) {
		t := d.regs[o]
		for f in crdt.sorted_keys(t^) {
			r := t[f]
			if r.unset {continue}
			fmt.sbprintf(&b, "%s.%s=%s\n", o, f, string(r.value))
		}
	}
	return strings.to_string(b)
}

random_edit :: proc(d: ^crdt.Doc, r: ^rand.Generator) {
	key := KEYS[rand.int_max(len(KEYS), r^)]
	s := crdt.seq_get(d, key)
	n := s.vis
	switch rand.int_max(100, r^) {
	case 0 ..< 40:
		pos := u64(rand.int_max(int(n) + 1, r^))
		w := WORDS[rand.int_max(len(WORDS), r^)]
		flags: u8 = rand.int_max(8, r^) == 0 ? crdt.FLAG_SUGGEST : 0
		crdt.insert_text(d, key, pos, w, flags)
	case 40 ..< 58:
		if n > 0 {
			pos := u64(rand.int_max(int(n), r^))
			cnt := u64(1 + rand.int_max(min(6, int(n - pos)), r^))
			crdt.remove(d, key, pos, cnt)
		}
	case 58 ..< 72:
		if n > 0 {
			from := u64(rand.int_max(int(n), r^))
			to := from + u64(1 + rand.int_max(int(n - from), r^))
			attr := ATTRS[rand.int_max(len(ATTRS), r^)]
			val: []u8
			switch rand.int_max(3, r^) {
			case 0:
				val = nil
			case 1:
				val = transmute([]u8)string("1")
			case 2:
				val = transmute([]u8)string("red")
			}
			crdt.mark(d, key, from, to, attr, val, crdt.Expand(rand.int_max(3, r^)))
		}
	case 72 ..< 84:
		owner := fmt.tprintf("o%d", rand.int_max(3, r^))
		field := fmt.tprintf("f%d", rand.int_max(3, r^))
		if rand.int_max(5, r^) == 0 {
			crdt.unset(d, owner, field)
		} else {
			crdt.set_str(d, owner, field, fmt.tprintf("v%d", rand.int_max(100, r^)))
		}
	case 84 ..< 90:
		pos := u64(rand.int_max(int(n) + 1, r^))
		crdt.insert_embed(d, key, pos, transmute([]u8)fmt.tprintf("table:%d", rand.int_max(9, r^)))
	case 90 ..< 94:
		pos := u64(rand.int_max(int(n) + 1, r^))
		crdt.insert_virtual(d, key, pos, u64(1 + rand.int_max(50, r^)))
	case:
		// a multi-op transaction
		crdt.insert_text(d, key, 0, "T")
		crdt.set_str(d, "o0", "f0", "txn")
	}
}

flush :: proc(reps: []Replica, from: int) {
	up := crdt.take_update(reps[from].doc)
	if up == nil {
		return
	}
	for i in 0 ..< len(reps) {
		if i == from {continue}
		cp := make([]u8, len(up))
		copy(cp, up)
		append(&reps[i].inbox, Msg{from, cp})
	}
	delete(up)
}

deliver_some :: proc(rp: ^Replica, r: ^rand.Generator, all := false) {
	if rp.cut > 0 && !all {
		rp.cut -= 1
		return
	}
	for len(rp.inbox) > 0 {
		if !all && rand.int_max(3, r^) == 0 {
			return
		}
		// out of order: pick any message
		i := rand.int_max(len(rp.inbox), r^)
		m := rp.inbox[i]
		ok := crdt.apply_update(rp.doc, m.data)
		check(ok, "an update failed to decode")
		if rand.int_max(10, r^) == 0 {
			crdt.apply_update(rp.doc, m.data) // duplicate delivery
		}
		delete(m.data)
		unordered_remove(&rp.inbox, i)
	}
}

oracle_round :: proc(seed: u64) {
	st := rand.create_u64(seed)
	g := rand.default_random_generator(&st)
	r := &g
	d := crdt.doc_make(rand.uint64(r^) | 1)
	defer crdt.doc_destroy(d)
	model := make([dynamic]u8)
	defer delete(model)
	for _ in 0 ..< 400 {
		n := len(model)
		if n == 0 || rand.int_max(3, r^) > 0 {
			pos := rand.int_max(n + 1, r^)
			w := WORDS[rand.int_max(len(WORDS), r^)]
			crdt.insert_text(d, "body", u64(pos), w)
			inject_at(&model, pos, ..transmute([]u8)w)
		} else {
			pos := rand.int_max(n, r^)
			cnt := 1 + rand.int_max(min(8, n - pos), r^)
			crdt.remove(d, "body", u64(pos), u64(cnt))
			remove_range(&model, pos, pos + cnt)
		}
		got := crdt.read_text(d, "body")
		if got != string(model[:]) {
			check(false, "oracle mismatch (seed %d): %q vs %q", seed, got, string(model[:]))
			return
		}
		free_all(context.temp_allocator)
	}
	u := crdt.take_update(d)
	delete(u)
}

undo_round :: proc(seed: u64) {
	st := rand.create_u64(seed)
	g := rand.default_random_generator(&st)
	r := &g
	d := crdt.doc_make(rand.uint64(r^) | 1)
	defer crdt.doc_destroy(d)
	history := make([dynamic]string)
	defer {
		for h in history {delete(h)}
		delete(history)
	}
	for _ in 0 ..< 60 {
		append(&history, strings.clone(visible(d)))
		crdt.begin(d)
		for _ in 0 ..< 1 + rand.int_max(3, r^) {
			random_edit(d, r)
		}
		crdt.commit(d)
		if len(d.undo.undo) < len(history) {
			// the step was empty (e.g. a no-op set); keep the stacks aligned
			delete(pop(&history))
		}
		free_all(context.temp_allocator)
	}
	// undo everything, one step at a time, comparing against history
	steps := 0
	for crdt.can_undo(d) {
		crdt.undo(d)
		want := pop(&history)
		got := visible(d)
		if got != want {
			gl := strings.split_lines(got, context.temp_allocator)
			wl := strings.split_lines(want, context.temp_allocator)
			for i in 0 ..< max(len(gl), len(wl)) {
				a := i < len(gl) ? gl[i] : ""
				b := i < len(wl) ? wl[i] : ""
				if a != b {
					check(false, "undo is not exact (seed %d, step %d):\n got  %s\n want %s", seed, steps, a, b)
					break
				}
			}
			delete(want)
			return
		}
		delete(want)
		steps += 1
		free_all(context.temp_allocator)
	}
	// and redo it all again: the last redo reaches the final state
	for crdt.can_redo(d) {
		crdt.redo(d)
	}
	_ = steps
	u := crdt.take_update(d)
	delete(u)
}

converge_round :: proc(seed: u64, nrep: int, steps: int) -> (ops: int) {
	st := rand.create_u64(seed)
	g := rand.default_random_generator(&st)
	r := &g
	reps := make([]Replica, nrep)
	defer delete(reps)
	for i in 0 ..< nrep {
		reps[i].doc = crdt.doc_make(rand.uint64(r^) | 1)
	}
	for _ in 0 ..< steps {
		i := rand.int_max(nrep, r^)
		rp := &reps[i]
		switch rand.int_max(20, r^) {
		case 0:
			crdt.undo(rp.doc)
		case 1:
			crdt.redo(rp.doc)
		case 2:
			rp.cut = 3 + rand.int_max(10, r^) // go offline for a while
		case:
			crdt.begin(rp.doc, rand.int_max(2, r^))
			for _ in 0 ..< 1 + rand.int_max(3, r^) {
				random_edit(rp.doc, r)
				ops += 1
			}
			crdt.commit(rp.doc)
		}
		if rand.int_max(3, r^) > 0 {
			flush(reps, i)
		}
		deliver_some(&reps[rand.int_max(nrep, r^)], r)
		free_all(context.temp_allocator)
	}
	for i in 0 ..< nrep {
		flush(reps, i)
	}
	for i in 0 ..< nrep {
		reps[i].cut = 0
		deliver_some(&reps[i], r, true)
	}
	d0 := crdt.dump(reps[0].doc)
	for i in 1 ..< nrep {
		di := crdt.dump(reps[i].doc)
		if di != d0 {
			check(false, "replicas 0 and %d diverged (seed %d)", i, seed)
			if dir := os.get_env("FUZZ_DUMP", context.temp_allocator); dir != "" {
				_ = os.write_entire_file(fmt.tprintf("%s/fuzz-a.txt", dir), transmute([]u8)d0)
				_ = os.write_entire_file(fmt.tprintf("%s/fuzz-b.txt", dir), transmute([]u8)di)
			}
			break
		}
		check(len(reps[i].doc.pending) == 0, "replica %d has %d ops stuck pending", i, len(reps[i].doc.pending))
	}
	for i in 0 ..< nrep {
		snap := crdt.encode_state(reps[i].doc)
		back, ok := crdt.doc_load(77, snap)
		check(ok, "snapshot did not load")
		if ok {
			db := crdt.dump(back)
			check(db == d0, "a snapshot does not reproduce the state (seed %d)", seed)
			if db != d0 {
				if dir := os.get_env("FUZZ_DUMP", context.temp_allocator); dir != "" {
					_ = os.write_entire_file(fmt.tprintf("%s/fuzz-a.txt", dir), transmute([]u8)d0)
					_ = os.write_entire_file(fmt.tprintf("%s/fuzz-b.txt", dir), transmute([]u8)db)
				}
			}
			crdt.doc_destroy(back)
		}
		delete(snap)
	}
	for i in 0 ..< nrep {
		for m in reps[i].inbox {delete(m.data)}
		delete(reps[i].inbox)
		crdt.doc_destroy(reps[i].doc)
	}
	free_all(context.temp_allocator)
	return
}

main :: proc() {
	rounds := 200
	nrep := 4
	seed := u64(time.now()._nsec)
	if len(os.args) > 1 {rounds, _ = strconv.parse_int(os.args[1])}
	if len(os.args) > 2 {nrep, _ = strconv.parse_int(os.args[2])}
	if len(os.args) > 3 {
		s, _ := strconv.parse_u64(os.args[3])
		seed = s
	}
	t0 := time.now()
	total_ops := 0
	for k in 0 ..< rounds {
		s := seed + u64(k)
		total_ops += converge_round(s, nrep, 300)
		oracle_round(s)
		undo_round(s)
		if fail_count > 0 {
			fmt.eprintfln("stopping at round %d (seed %d)", k, s)
			break
		}
	}
	el := time.since(t0)
	fmt.printfln(
		"fuzz: %d rounds x %d replicas, %d edits, seed %d: %s (%v)",
		rounds,
		nrep,
		total_ops,
		seed,
		fail_count == 0 ? "all converged, oracle and undo exact" : "FAILED",
		el,
	)
	os.exit(fail_count == 0 ? 0 : 1)
}
