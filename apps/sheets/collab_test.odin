// Collaboration tests for `sheets --selftest`: several workbooks, each with
// its own CRDT replica, edited through the same procedures the keys call,
// exchanging updates directly.
package main

import "core:fmt"
import "core:strings"
import crdt "../../cloud/collab/crdt"

Replica :: struct {
	app: ^App,
	cb:  Sheets_Collab,
}

@(private = "file")
rep_make :: proc(agent: u64, handle: string) -> ^Replica {
	r := new(Replica)
	r.app = new(App)
	app_init(r.app)
	r.app.name = strings.clone("Shared")
	saved := collab
	collab = {}
	collab_init_doc(r.app, crdt.doc_make(agent))
	collab.ui.handle = strings.clone(handle)
	collab.ui.name = strings.clone(handle)
	collab.ui.color = strings.clone("indigo")
	r.cb = collab
	collab = saved
	return r
}

@(private = "file")
rep_free :: proc(r: ^Replica) {
	crdt.doc_destroy(r.cb.doc)
	app_destroy(r.app)
	free(r.app)
	free(r)
}

// with runs `f` with the replica's binding installed as the global one.
@(private = "file")
with :: proc(r: ^Replica, f: proc(app: ^App)) {
	saved := collab
	collab = r.cb
	f(r.app)
	r.cb = collab
	collab = saved
}

@(private = "file")
cur_rep: ^Replica

@(private = "file")
begin_on :: proc(r: ^Replica) {
	cur_rep = r
	collab = r.cb
}

@(private = "file")
end_on :: proc() {
	cur_rep.cb = collab
	collab = {}
}

@(private = "file")
sync_all :: proc(reps: ..^Replica) {
	ups := make([][]u8, len(reps), context.temp_allocator)
	for r, i in reps {
		begin_on(r)
		collab_sync(r.app)
		ups[i] = crdt.take_update(collab.doc, context.temp_allocator)
		end_on()
	}
	for r, i in reps {
		begin_on(r)
		collab_save_cursor(r.app)
		changed := false
		for u, j in ups {
			if j != i && u != nil {
				crdt.apply_update(collab.doc, u)
				changed = true
			}
		}
		if changed {collab_materialise(r.app)}
		collab.saved = false
		end_on()
	}
}

@(private = "file")
book_text :: proc(r: ^Replica) -> string {
	return doc_save_string(r.app.book.sheets[0], "x", {}, {}, context.temp_allocator)
}

@(private = "file")
cell :: proc(r: ^Replica, sheet: int, at: string) -> string {
	sh := r.app.book.sheets[sheet]
	return input_at(sh, ref(at))
}

@(private = "file")
shown :: proc(r: ^Replica, sheet: int, at: string) -> string {
	sh := r.app.book.sheets[sheet]
	return display_at(sh, ref(at))
}

// edit types into a cell the way the keyboard does.
@(private = "file")
edit :: proc(r: ^Replica, sheet: int, at: string, text: string) {
	begin_on(r)
	use_sheet(r.app, sheet)
	r.app.cur = ref(at)
	r.app.anchor = r.app.cur
	line_set(&r.app.edit, text)
	commit_edit(r.app, 0, 0)
	end_on()
}

@(private = "file")
cmd_at :: proc(r: ^Replica, sheet: int, at: string, c: Cmd) {
	begin_on(r)
	use_sheet(r.app, sheet)
	r.app.cur = ref(at)
	r.app.anchor = r.app.cur
	run_cmd(r.app, c)
	end_on()
}

t_collab :: proc(tc: ^TC) {
	fmt.println("  collaboration: the workbook on a CRDT")

	// 1. A whole demo book round-trips through the CRDT.
	{
		a := rep_make(0xa1, "alice")
		b := rep_make(0xb2, "bob")
		defer rep_free(a)
		defer rep_free(b)
		begin_on(a)
		seed_demo(a.app)
		collab_note_edit(a.app)
		end_on()
		sync_all(a, b)
		ok_mark(tc, len(b.app.book.sheets) == len(a.app.book.sheets), fmt.tprintf("the sheets arrive (%d / %d)", len(b.app.book.sheets), len(a.app.book.sheets)))
		ok_mark(tc, book_text(a) == book_text(b), "the seeded book (cells, formats, formulas across sheets, charts) is identical on both sides")
	}

	// 2. A row inserted above a cell another person is typing in.
	{
		a := rep_make(0xa1, "alice")
		b := rep_make(0xb2, "bob")
		defer rep_free(a)
		defer rep_free(b)
		edit(a, 0, "A1", "Item")
		edit(a, 0, "B1", "Cost")
		edit(a, 0, "A5", "Paper")
		edit(a, 0, "B5", "10")
		sync_all(a, b)
		// Alice inserts a row above row 3; Bob, concurrently, changes B5 and
		// writes a total that refers to it.
		cmd_at(a, 0, "A3", .Insert_Row)
		edit(b, 0, "B5", "12")
		edit(b, 0, "D1", "=B5*2")
		sync_all(a, b)
		ok_mark(tc, book_text(a) == book_text(b), "row insertion and a concurrent edit converge")
		ok_mark(tc, cell(a, 0, "B6") == "12", fmt.tprintf("Bob's value follows its row to B6 (B6=%q)", cell(a, 0, "B6")))
		ok_mark(tc, cell(a, 0, "B5") == "", "and B5, the inserted row, is empty")
		ok_mark(tc, cell(a, 0, "D1") == "=B6*2", fmt.tprintf("Bob's formula follows the row it names (%q)", cell(a, 0, "D1")))
		ok_mark(tc, shown(a, 0, "D1") == "24" && shown(b, 0, "D1") == "24", "and both recalculate it to 24")
	}

	// 3. The same cell, at once: one value wins, everywhere.
	{
		a := rep_make(0xa1, "alice")
		b := rep_make(0xb2, "bob")
		defer rep_free(a)
		defer rep_free(b)
		edit(a, 0, "C3", "start")
		sync_all(a, b)
		edit(a, 0, "C3", "from alice")
		edit(b, 0, "C3", "from bob")
		sync_all(a, b)
		ok_mark(tc, cell(a, 0, "C3") == cell(b, 0, "C3"), "concurrent writes to one cell converge")
		v := cell(a, 0, "C3")
		ok_mark(tc, v == "from alice" || v == "from bob", fmt.tprintf("to one of the two values (%q)", v))
	}

	// 4. A formula whose row is deleted becomes #REF! on both sides.
	{
		a := rep_make(0xa1, "alice")
		b := rep_make(0xb2, "bob")
		defer rep_free(a)
		defer rep_free(b)
		edit(a, 0, "A2", "5")
		sync_all(a, b)
		cmd_at(a, 0, "A2", .Delete_Row)
		edit(b, 0, "C1", "=A2+1")
		sync_all(a, b)
		ok_mark(tc, cell(a, 0, "C1") == cell(b, 0, "C1"), "converges")
		ok_mark(tc, strings.contains(cell(a, 0, "C1"), "#REF!"), fmt.tprintf("a reference to a row deleted concurrently is #REF! (%q)", cell(a, 0, "C1")))
	}

	// 5. A sheet renamed while someone writes a formula that names it.
	{
		a := rep_make(0xa1, "alice")
		b := rep_make(0xb2, "bob")
		defer rep_free(a)
		defer rep_free(b)
		begin_on(a)
		book_add_sheet(a.app.book, "Data")
		collab_note_edit(a.app)
		end_on()
		edit(a, 1, "A1", "7")
		sync_all(a, b)
		begin_on(a)
		undo_push(a.app)
		book_rename_sheet(a.app.book, 1, "Inputs")
		end_on()
		edit(b, 0, "A1", "=Data!A1*3")
		sync_all(a, b)
		ok_mark(tc, cell(a, 0, "A1") == "=Inputs!A1*3" && cell(b, 0, "A1") == "=Inputs!A1*3", fmt.tprintf("a formula naming a renamed sheet follows the rename (%q)", cell(a, 0, "A1")))
		ok_mark(tc, shown(b, 0, "A1") == "21", "and evaluates")
	}

	// 5b. The same for a 3-D reference: both of its ends are sheets, and both
	// are anchored to the sheets' identities, so a collaborator renaming
	// either end — while the formula is being typed — rewrites it.
	{
		a := rep_make(0xa1, "alice")
		b := rep_make(0xb2, "bob")
		defer rep_free(a)
		defer rep_free(b)
		begin_on(a)
		book_add_sheet(a.app.book, "Jan")
		book_add_sheet(a.app.book, "Feb")
		book_add_sheet(a.app.book, "Mar")
		collab_note_edit(a.app)
		end_on()
		edit(a, 1, "B2", "1")
		edit(a, 2, "B2", "2")
		edit(a, 3, "B2", "3")
		sync_all(a, b)
		begin_on(a)
		undo_push(a.app)
		book_rename_sheet(a.app.book, 1, "January")
		book_rename_sheet(a.app.book, 3, "Q1 end")
		end_on()
		edit(b, 0, "A1", "=SUM(Jan:Mar!B2)*2")
		edit(b, 0, "A2", "=SUM(Jan:Mar!$B$2:B3)")
		sync_all(a, b)
		want := "=SUM('January:Q1 end'!B2)*2"
		ok_mark(tc, cell(a, 0, "A1") == want && cell(b, 0, "A1") == want, fmt.tprintf("a 3-D reference follows a concurrent rename of both its ends (%q / %q)", cell(a, 0, "A1"), cell(b, 0, "A1")))
		ok_mark(tc, cell(a, 0, "A2") == "=SUM('January:Q1 end'!$B$2:B3)", fmt.tprintf("and so does a 3-D range, its dollar signs kept (%q)", cell(a, 0, "A2")))
		ok_mark(tc, shown(a, 0, "A1") == "12" && shown(b, 0, "A1") == "12", "and evaluates on both sides")
		// Which tab each person is looking at is theirs, not the book's.
		a.app.book.active, b.app.book.active = 0, 0
		ok_mark(tc, book_text(a) == book_text(b), "the two books converge")
		// A sheet inserted inside the span joins it on both sides: the span
		// is still positional, only its ends are anchored.
		begin_on(b)
		undo_push(b.app)
		ins := book_insert_sheet(b.app.book, "Extra", 2)
		set_input(ins, {1, 1}, "10")
		end_on()
		sync_all(a, b)
		ok_mark(tc, shown(a, 0, "A1") == "32", fmt.tprintf("a sheet a collaborator inserts inside the span joins it (%q)", shown(a, 0, "A1")))
	}

	// 6. Undo is per person.
	{
		a := rep_make(0xa1, "alice")
		b := rep_make(0xb2, "bob")
		defer rep_free(a)
		defer rep_free(b)
		edit(a, 0, "A1", "alice")
		sync_all(a, b)
		edit(b, 0, "B1", "bob")
		sync_all(a, b)
		begin_on(a)
		do_undo(a.app)
		end_on()
		sync_all(a, b)
		ok_mark(tc, cell(b, 0, "A1") == "" && cell(b, 0, "B1") == "bob", "Alice's undo removes her cell and leaves Bob's")
	}

	// 7. Random editing, three replicas.
	{
		seed: u64 = 77
		rnd :: proc(s: ^u64, n: int) -> int {
			s^ = s^ * 6364136223846793005 + 1442695040888963407
			return int((s^ >> 33) % u64(max(1, n)))
		}
		diverged := 0
		total := 0
		for round in 0 ..< 8 {
			reps := [3]^Replica{rep_make(0xa1 + u64(round), "a"), rep_make(0xb2 + u64(round), "b"), rep_make(0xc3 + u64(round), "c")}
			edit(reps[0], 0, "A1", "1")
			sync_all(reps[0], reps[1], reps[2])
			for _ in 0 ..< 60 {
				r := reps[rnd(&seed, 3)]
				at := fmt.tprintf("%s%d", col_name(rnd(&seed, 5)), 1 + rnd(&seed, 8))
				switch rnd(&seed, 10) {
				case 0, 1, 2, 3:
					edit(r, 0, at, fmt.tprintf("%d", rnd(&seed, 100)))
				case 4, 5:
					refs := [?]string{"=A1+B2", "=SUM(A1:C3)", "=A2*2", "=B$3-$A4", "=COUNT(A:A)"}
					edit(r, 0, at, refs[rnd(&seed, len(refs))])
				case 6:
					cmd_at(r, 0, at, .Insert_Row)
				case 7:
					cmd_at(r, 0, at, .Delete_Row)
				case 8:
					cmd_at(r, 0, at, rnd(&seed, 2) == 0 ? .Insert_Col : .Delete_Col)
				case 9:
					cmd_at(r, 0, at, .Bold)
				}
				total += 1
				if rnd(&seed, 3) == 0 {sync_all(reps[0], reps[1], reps[2])}
				free_all(context.temp_allocator)
			}
			sync_all(reps[0], reps[1], reps[2])
			sync_all(reps[0], reps[1], reps[2])
			t0 := book_text(reps[0])
			for i in 1 ..< 3 {
				if book_text(reps[i]) != t0 {diverged += 1}
			}
			for r in reps {rep_free(r)}
		}
		ok_mark(tc, diverged == 0, fmt.tprintf("random editing: %d edits incl. row/column insertions and deletions over 8 rounds, three replicas converge (%d diverged)", total, diverged))
	}
}
