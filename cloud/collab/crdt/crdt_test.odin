package crdt

import "core:testing"

@(test)
test_basic_text :: proc(t: ^testing.T) {
	a := doc_make(1)
	defer doc_destroy(a)
	insert_text(a, "b", 0, "hello")
	insert_text(a, "b", 5, " world")
	testing.expect_value(t, read_text(a, "b"), "hello world")
	remove(a, "b", 0, 6)
	testing.expect_value(t, read_text(a, "b"), "world")
	up := take_update(a)
	defer delete(up)

	b := doc_make(2)
	defer doc_destroy(b)
	testing.expect(t, apply_update(b, up))
	testing.expect_value(t, read_text(b, "b"), "world")
	testing.expect_value(t, dump(a), dump(b))
}

@(test)
test_concurrent_same_spot :: proc(t: ^testing.T) {
	a := doc_make(1)
	defer doc_destroy(a)
	b := doc_make(2)
	defer doc_destroy(b)
	insert_text(a, "b", 0, "ab")
	u0 := take_update(a)
	defer delete(u0)
	apply_update(b, u0)
	insert_text(a, "b", 1, "XXX")
	insert_text(b, "b", 1, "yyy")
	ua := take_update(a)
	defer delete(ua)
	ub := take_update(b)
	defer delete(ub)
	apply_update(a, ub)
	apply_update(b, ua)
	testing.expect_value(t, read_text(a, "b"), read_text(b, "b"))
	// no interleaving
	s := read_text(a, "b")
	testing.expect(t, s == "aXXXyyyb" || s == "ayyyXXXb", s)
}

@(test)
test_marks_expand :: proc(t: ^testing.T) {
	a := doc_make(1)
	defer doc_destroy(a)
	b := doc_make(2)
	defer doc_destroy(b)
	insert_text(a, "b", 0, "hello world")
	u0 := take_update(a)
	defer delete(u0)
	apply_update(b, u0)
	// a bolds "hello world"; b concurrently types inside and at the end
	mark(a, "b", 0, 11, "b", {'1'})
	insert_text(b, "b", 5, " big")
	insert_text(b, "b", 15, "!")
	ua := take_update(a)
	defer delete(ua)
	ub := take_update(b)
	defer delete(ub)
	apply_update(a, ub)
	apply_update(b, ua)
	testing.expect_value(t, dump(a), dump(b))
	sp := read_spans(a, "b")
	testing.expect_value(t, len(sp.spans) > 0, true)
	all_bold := true
	for x in sp.spans {
		if _, ok := attr_get(sp.attrs[x.attrs], "b"); !ok {
			all_bold = false
		}
	}
	testing.expect(t, all_bold, "concurrent inserts inside and at the end of a bold range are bold")
}

@(test)
test_snapshot_roundtrip :: proc(t: ^testing.T) {
	a := doc_make(1)
	defer doc_destroy(a)
	insert_text(a, "b", 0, "hello world")
	mark(a, "b", 0, 5, "i", {'1'})
	remove(a, "b", 2, 3)
	set_str(a, "deck", "title", "Plan")
	insert_virtual(a, "rows", 0, 1000)
	snap := encode_state(a)
	defer delete(snap)
	b, ok := doc_load(2, snap)
	testing.expect(t, ok)
	defer doc_destroy(b)
	testing.expect_value(t, dump(a), dump(b))
	// and keeps working
	insert_text(b, "b", 0, ">")
	u := take_update(b)
	defer delete(u)
	apply_update(a, u)
	testing.expect_value(t, dump(a), dump(b))
}

@(test)
test_undo_redo :: proc(t: ^testing.T) {
	a := doc_make(1)
	defer doc_destroy(a)
	begin(a, 1)
	insert_text(a, "b", 0, "hello")
	commit(a)
	begin(a)
	remove(a, "b", 1, 3)
	commit(a)
	testing.expect_value(t, read_text(a, "b"), "ho")
	undo(a)
	testing.expect_value(t, read_text(a, "b"), "hello")
	undo(a)
	testing.expect_value(t, read_text(a, "b"), "")
	redo(a)
	testing.expect_value(t, read_text(a, "b"), "hello")
	redo(a)
	testing.expect_value(t, read_text(a, "b"), "ho")
}
