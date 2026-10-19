// Collaboration tests for `slides --selftest`: decks with their own CRDT
// replicas, edited the way the keys edit them, exchanging updates directly.
package main

import "core:fmt"
import "core:strings"
import crdt "../../cloud/collab/crdt"

@(private = "file")
Rep :: struct {
	st: ^St,
	cb: Slides_Collab,
}

@(private = "file")
rep_make :: proc(agent: u64) -> ^Rep {
	r := new(Rep)
	r.st = new(St)
	r.st.sel = -1
	r.st.deck = fixture_deck()
	saved := collab
	collab = {}
	collab.doc = crdt.doc_make(agent)
	collab.on = true
	r.cb = collab
	collab = saved
	return r
}

@(private = "file")
rep_free :: proc(r: ^Rep) {
	crdt.doc_destroy(r.cb.doc)
	free(r.st)
	free(r)
}

@(private = "file")
on :: proc(r: ^Rep) {collab = r.cb}
@(private = "file")
off :: proc(r: ^Rep) {r.cb = collab; collab = {}}

@(private = "file")
exchange :: proc(reps: ..^Rep) {
	ups := make([][]u8, len(reps), context.temp_allocator)
	for r, i in reps {
		on(r)
		collab_sync(r.st)
		ups[i] = crdt.take_update(collab.doc, context.temp_allocator)
		off(r)
	}
	for r, i in reps {
		on(r)
		changed := false
		for u, j in ups {
			if j != i && u != nil {
				crdt.apply_update(collab.doc, u)
				changed = true
			}
		}
		if changed {collab_materialise(r.st)}
		off(r)
	}
}

@(private = "file")
deck_text :: proc(r: ^Rep) -> string {
	b, _ := deck_bytes(&r.st.deck, context.temp_allocator)
	return string(b)
}

// change edits a replica as a key would: history first, then the change.
@(private = "file")
change :: proc(r: ^Rep, f: proc(st: ^St)) {
	on(r)
	push_history(r.st, nil)
	f(r.st)
	off(r)
}

t_collab :: proc(t: ^Checks) {
	// 1. The fixture deck round-trips.
	{
		a, b := rep_make(0xa1), rep_make(0xb2)
		defer rep_free(a)
		defer rep_free(b)
		on(a)
		collab_note_edit()
		off(a)
		exchange(a, b)
		check(t, deck_text(a) == deck_text(b), "collab: the fixture deck (8 slides, shapes, pictures, notes) arrives intact")
	}

	// 2. One person drags a shape while another recolours it.
	{
		a, b := rep_make(0xa1), rep_make(0xb2)
		defer rep_free(a)
		defer rep_free(b)
		on(a)
		collab_note_edit()
		off(a)
		exchange(a, b)
		change(a, proc(st: ^St) {st.deck.slides[1].elems[0].x += 100})
		change(b, proc(st: ^St) {st.deck.slides[1].elems[0].fill = SLOT_ACCENT2})
		exchange(a, b)
		e := a.st.deck.slides[1].elems[0]
		check(t, deck_text(a) == deck_text(b), "collab: concurrent move and recolour converge")
		check(t, e.fill == SLOT_ACCENT2 && e.x == b.st.deck.slides[1].elems[0].x, "collab: and both changes survive (fill %x)", e.fill)
	}

	// 3. Two people type in one text box.
	{
		a, b := rep_make(0xa1), rep_make(0xb2)
		defer rep_free(a)
		defer rep_free(b)
		on(a)
		collab_note_edit()
		off(a)
		exchange(a, b)
		change(a, proc(st: ^St) {
			e := &st.deck.slides[0].elems[0]
			e.text = strings.concatenate({e.text, " (draft)"})
		})
		change(b, proc(st: ^St) {
			e := &st.deck.slides[0].elems[0]
			e.text = strings.concatenate({"New: ", e.text})
		})
		exchange(a, b)
		ta := a.st.deck.slides[0].elems[0].text
		check(t, ta == b.st.deck.slides[0].elems[0].text, "collab: concurrent typing in one box converges")
		check(t, strings.has_prefix(ta, "New: ") && strings.has_suffix(ta, " (draft)"), "collab: with both edits in it (%q)", ta)
	}

	// 4. A slide moved while someone edits its notes; and moved by two at once.
	{
		a, b := rep_make(0xa1), rep_make(0xb2)
		defer rep_free(a)
		defer rep_free(b)
		on(a)
		collab_note_edit()
		off(a)
		exchange(a, b)
		n := len(a.st.deck.slides)
		change(a, proc(st: ^St) {slide_move(&st.deck, 3, -1); slide_move(&st.deck, 2, -1)})
		change(b, proc(st: ^St) {st.deck.slides[3].notes = "Bob's speaker notes"})
		exchange(a, b)
		check(t, deck_text(a) == deck_text(b), "collab: a move and a notes edit converge")
		check(t, a.st.deck.slides[1].notes == "Bob's speaker notes", "collab: the notes travelled with their slide to position 2")
		change(a, proc(st: ^St) {slide_move(&st.deck, 1, 1)})
		change(b, proc(st: ^St) {slide_move(&st.deck, 1, -1)})
		exchange(a, b)
		check(t, deck_text(a) == deck_text(b), "collab: two people moving one slide converge")
		check(t, len(a.st.deck.slides) == n, "collab: and it exists once (%d slides, %d before)", len(a.st.deck.slides), n)
	}

	// 5. Undo is per person.
	{
		a, b := rep_make(0xa1), rep_make(0xb2)
		defer rep_free(a)
		defer rep_free(b)
		on(a)
		collab_note_edit()
		off(a)
		exchange(a, b)
		change(a, proc(st: ^St) {st.deck.title = "Alice's title"})
		exchange(a, b)
		change(b, proc(st: ^St) {st.deck.slides[0].notes = "Bob was here"})
		exchange(a, b)
		on(a)
		collab_undo(a.st, false)
		off(a)
		exchange(a, b)
		check(t, b.st.deck.title != "Alice's title" && b.st.deck.slides[0].notes == "Bob was here", "collab: Alice's undo takes back her title and leaves Bob's notes")
	}

	// 6. Random editing, three replicas.
	{
		seed: u64 = 99
		rnd :: proc(s: ^u64, n: int) -> int {
			s^ = s^ * 6364136223846793005 + 1442695040888963407
			return int((s^ >> 33) % u64(max(1, n)))
		}
		diverged, total := 0, 0
		for round in 0 ..< 6 {
			reps := [3]^Rep{rep_make(0xa1 + u64(round)), rep_make(0xb2 + u64(round)), rep_make(0xc3 + u64(round))}
			on(reps[0])
			collab_note_edit()
			off(reps[0])
			exchange(reps[0], reps[1], reps[2])
			for _ in 0 ..< 50 {
				r := reps[rnd(&seed, 3)]
				on(r)
				st := r.st
				push_history(st, nil)
				si := rnd(&seed, len(st.deck.slides))
				sl := &st.deck.slides[si]
				switch rnd(&seed, 8) {
				case 0, 1:
					if len(sl.elems) > 0 {
						e := &sl.elems[rnd(&seed, len(sl.elems))]
						e.x += f32(rnd(&seed, 40)) - 20
					}
				case 2:
					if len(sl.elems) > 0 {
						e := &sl.elems[rnd(&seed, len(sl.elems))]
						e.text = fmt.aprintf("%s%d", e.text, rnd(&seed, 9))
					}
				case 3:
					if len(sl.elems) > 1 {elem_to_front(sl, rnd(&seed, len(sl.elems)))}
				case 4:
					slide_move(&st.deck, si, rnd(&seed, 2) == 0 ? 1 : -1)
				case 5:
					slide_add(&st.deck, si + 1, .Title_Content)
				case 6:
					if len(st.deck.slides) > 2 {slide_delete(&st.deck, si)}
				case 7:
					sl.notes = fmt.aprintf("%s+", sl.notes)
				}
				off(r)
				total += 1
				if rnd(&seed, 3) == 0 {exchange(reps[0], reps[1], reps[2])}
				free_all(context.temp_allocator)
			}
			exchange(reps[0], reps[1], reps[2])
			exchange(reps[0], reps[1], reps[2])
			t0 := deck_text(reps[0])
			for i in 1 ..< 3 {
				if deck_text(reps[i]) != t0 {diverged += 1}
			}
			for r in reps {rep_free(r)}
		}
		check(t, diverged == 0, "collab: %d random edits (moves, text, z-order, slide add/move/delete, notes) over 6 rounds, three replicas converge (%d diverged)", total, diverged)
	}
}
