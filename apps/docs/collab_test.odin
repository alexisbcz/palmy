// The collaboration section of `docs --selftest`: two (or three) editors, each
// with its own CRDT replica, driven through the same commands the keyboard
// calls, exchanging updates directly — no network, so what is tested is the
// binding and the merge, not the transport (cloud/collab/cli e2e does that).
package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import p "palmy:."
import crdt "../../cloud/collab/crdt"

@(private = "file")
c_checks, c_fails: int

@(private = "file")
c_ok :: proc(cond: bool, msg: string, args: ..any) {
	c_checks += 1
	if !cond {
		c_fails += 1
		fmt.eprintf("  FAIL  %s\n", fmt.tprintf(msg, ..args))
	}
}

@(private = "file")
c_eq :: proc(got, want: string, msg: string, args: ..any) {
	c_checks += 1
	if got != want {
		c_fails += 1
		fmt.eprintf("  FAIL  %s:\n    got  %q\n    want %q\n", fmt.tprintf(msg, ..args), got, want)
	}
}

// editor makes a headless editor with its own replica.
@(private = "file")
editor :: proc(fonts: ^p.Fonts, agent: u64, handle: string) -> ^State {
	st := new(State)
	state_init(st, fonts)
	collab_init(&st.collab, crdt.doc_make(agent))
	st.collab.handle = handle
	st.collab.name = handle
	st.collab.color = "indigo"
	return st
}

@(private = "file")
editor_free :: proc(st: ^State) {
	state_destroy(st)
	free(st)
}

// sync_pair delivers everything each side has emitted to the others and
// rebuilds every model, as poll() would.
@(private = "file")
exchange :: proc(eds: ..^State) {
	ups := make([][]u8, len(eds), context.temp_allocator)
	for st, i in eds {
		collab_sync(st)
		ups[i] = crdt.take_update(st.collab.doc, context.temp_allocator)
	}
	for st, i in eds {
		changed := false
		collab_save_carets(st)
		for u, j in ups {
			if j != i && u != nil {
				crdt.apply_update(st.collab.doc, u)
				changed = true
			}
		}
		if changed {
			collab_materialise(st, {}, true)
			relayout(st)
		}
	}
}

@(private = "file")
plain :: proc(st: ^State) -> string {
	b := strings.builder_make(context.temp_allocator)
	for blk, i in doc_blocks(&st.doc, context.temp_allocator) {
		if i > 0 {strings.write_byte(&b, '\n')}
		pa := blk_para(&st.doc, blk)
		if pa == nil {continue}
		for &r in pa.runs {strings.write_bytes(&b, r.text[:])}
	}
	return strings.to_string(b)
}

@(private = "file")
para_plain :: proc(st: ^State, i: int) -> string {
	return para_text(&st.doc.paras[i], context.temp_allocator)
}

// load puts a starting document into the first editor and shares it.
@(private = "file")
load :: proc(a: ^State, md: string, others: ..^State) {
	replace_document(a, doc_from_markdown(md))
	relayout(a)
	collab_note_edit(a, .Structural)
	collab_sync(a)
	up := crdt.take_update(a.collab.doc, context.temp_allocator)
	for o in others {
		crdt.apply_update(o.collab.doc, up)
		collab_materialise(o, {}, false)
		relayout(o)
	}
}

test_collab :: proc(fonts: ^p.Fonts) -> (checks, fails: int) {
	fmt.printf("  collaboration: the model on a CRDT, two editors at once\n")

	// --- 1. the seed document round-trips through the CRDT exactly
	{
		a := editor(fonts, 0xa1, "alice")
		b := editor(fonts, 0xb2, "bob")
		defer editor_free(a)
		defer editor_free(b)
		load(a, SEED, b)
		c_eq(doc_to_json(&b.doc, context.temp_allocator), doc_to_json(&a.doc, context.temp_allocator),
			"the seed document (headings, lists, quote, bold, italic, mono) arrives intact")
		c_ok(len(b.doc.paras) == len(a.doc.paras), "same paragraph count (%d / %d)", len(b.doc.paras), len(a.doc.paras))
	}

	// --- 2. tables and their cells' styles round-trip
	{
		a := editor(fonts, 0xa1, "alice")
		b := editor(fonts, 0xb2, "bob")
		defer editor_free(a)
		defer editor_free(b)
		load(a, "Intro\n\n| Name | Role |\n| --- | --- |\n| **Ada** | engineer |\n| Grace | *admiral* |\n\nOutro", b)
		c_eq(doc_to_json(&b.doc, context.temp_allocator), doc_to_json(&a.doc, context.temp_allocator),
			"a table with styled cells arrives intact")
		has_table := false
		for &pa in b.doc.paras {if pa.kind == .Table {has_table = true}}
		c_ok(has_table, "and it is a table on the other side")
	}

	// --- 3. two people type at the same spot: no interleaving
	{
		a := editor(fonts, 0xa1, "alice")
		b := editor(fonts, 0xb2, "bob")
		defer editor_free(a)
		defer editor_free(b)
		load(a, "Hello world", b)
		a.caret, a.anchor = pos(0, 5), pos(0, 5)
		b.caret, b.anchor = pos(0, 5), pos(0, 5)
		for ch in ([]string{" big", " bad"}) {
			_ = ch
		}
		type_text(a, ",")
		type_text(a, " dear")
		type_text(b, " wide")
		exchange(a, b)
		c_eq(plain(a), plain(b), "concurrent typing converges")
		s := plain(a)
		c_ok(s == "Hello, dear wide world" || s == "Hello wide, dear world", "and neither person's words are interleaved: %q", s)
	}

	// --- 4. bold over a word while someone types inside it (Peritext)
	{
		a := editor(fonts, 0xa1, "alice")
		b := editor(fonts, 0xb2, "bob")
		defer editor_free(a)
		defer editor_free(b)
		load(a, "make this bold now", b)
		a.anchor, a.caret = pos(0, 5), pos(0, 14)
		toggle_bold(a)
		b.caret, b.anchor = pos(0, 9), pos(0, 9)
		type_text(b, " text")
		exchange(a, b)
		c_eq(plain(a), plain(b), "converges")
		c_eq(plain(a), "make this text bold now", "both edits survive")
		pa := &a.doc.paras[0]
		bold_text := strings.builder_make(context.temp_allocator)
		for &r in pa.runs {if r.style.bold {strings.write_bytes(&bold_text, r.text[:])}}
		c_eq(strings.to_string(bold_text), "this text bold", "text typed inside a range being bolded is bold too")
		c_eq(doc_to_json(&a.doc, context.temp_allocator), doc_to_json(&b.doc, context.temp_allocator), "styles agree")
	}

	// --- 5. a paragraph split against typing at its end
	{
		a := editor(fonts, 0xa1, "alice")
		b := editor(fonts, 0xb2, "bob")
		defer editor_free(a)
		defer editor_free(b)
		load(a, "First half. Second half.", b)
		a.caret, a.anchor = pos(0, 11), pos(0, 11)
		split_line(a)
		set_kind(a, .H2)
		b.caret, b.anchor = pos(0, 24), pos(0, 24)
		type_text(b, " And more.")
		exchange(a, b)
		c_eq(plain(a), plain(b), "converges")
		c_ok(len(a.doc.paras) == 2, "two paragraphs (%d)", len(a.doc.paras))
		if len(a.doc.paras) == 2 {
			c_eq(para_plain(a, 1), " Second half. And more.", "the typing lands in the second half")
			c_ok(a.doc.paras[1].kind == .H2 && b.doc.paras[1].kind == .H2, "the new paragraph's heading style travels")
		}
	}

	// --- 6. a row inserted while someone types in the row below it
	{
		a := editor(fonts, 0xa1, "alice")
		b := editor(fonts, 0xb2, "bob")
		defer editor_free(a)
		defer editor_free(b)
		load(a, "| A | B |\n| --- | --- |\n| 1 | 2 |\n| 3 | 4 |", b)
		ti := -1
		for &pa, i in a.doc.paras {if pa.kind == .Table {ti = i}}
		c_ok(ti >= 0, "the table is there")
		if ti >= 0 {
			a.caret = Pos{para = ti, row = 1, col = 0, off = 0}
			a.anchor = a.caret
			table_row_cmd(a, true) // a row below "1 | 2"
			a.caret = Pos{para = ti, row = 2, col = 0, off = 0}
			a.anchor = a.caret
			type_text(a, "new")
			b.caret = Pos{para = ti, row = 2, col = 1, off = 1}
			b.anchor = b.caret
			type_text(b, "!")
			exchange(a, b)
			c_eq(plain(a), plain(b), "converges")
			t := a.doc.paras[ti].table
			c_ok(t != nil && len(t.rows) == 4, "four rows on both sides")
			if t != nil && len(t.rows) == 4 {
				c_eq(cell_text(table_cell(t, 3, 1), context.temp_allocator), "4!", "the edit follows its row, not its index")
				c_eq(cell_text(table_cell(t, 2, 0), context.temp_allocator), "new", "the inserted row has its text")
			}
		}
	}

	// --- 7. undo is per person
	{
		a := editor(fonts, 0xa1, "alice")
		b := editor(fonts, 0xb2, "bob")
		defer editor_free(a)
		defer editor_free(b)
		load(a, "one\n\ntwo", b)
		a.caret, a.anchor = pos(0, 3), pos(0, 3)
		type_text(a, " alice")
		exchange(a, b)
		b.caret, b.anchor = pos(1, 3), pos(1, 3)
		type_text(b, " bob")
		exchange(a, b)
		do_undo(a)
		exchange(a, b)
		c_eq(plain(a), "one\ntwo bob", "Alice's undo takes back her words and leaves Bob's")
		c_eq(plain(b), plain(a), "on both sides")
		do_redo(a)
		exchange(a, b)
		c_eq(plain(b), "one alice\ntwo bob", "and redo puts them back")
	}

	// --- 8. a caret stays on its text while someone edits above it
	{
		a := editor(fonts, 0xa1, "alice")
		b := editor(fonts, 0xb2, "bob")
		defer editor_free(a)
		defer editor_free(b)
		load(a, "alpha\n\nbeta\n\ngamma", b)
		b.caret, b.anchor = pos(2, 3), pos(2, 3) // gam|ma
		a.caret, a.anchor = pos(0, 0), pos(0, 0)
		type_text(a, "Title")
		split_line(a)
		exchange(a, b)
		c_ok(b.caret.para == 3 && b.caret.off == 3, "Bob's caret is still inside 'gamma' (para %d off %d)", b.caret.para, b.caret.off)
	}

	// --- 9. suggestions: proposed, shown, accepted and rejected
	{
		a := editor(fonts, 0xa1, "alice")
		b := editor(fonts, 0xb2, "bob")
		defer editor_free(a)
		defer editor_free(b)
		load(a, "The plan is final.", b)
		b.collab.suggest = true
		b.caret, b.anchor = pos(0, 12), pos(0, 12)
		type_text(b, "almost ")
		exchange(a, b)
		c_eq(plain(a), "The plan is almost final.", "a suggested insertion is visible to everyone")
		ins := 0
		for dc in a.collab.decos {if dc.kind == .Sugg_Ins && dc.id == "bob" {ins += dc.to - dc.from}}
		c_ok(ins == 7, "and marked as Bob's suggestion (%d bytes)", ins)
		// Bob proposes deleting "The "
		b.anchor, b.caret = pos(0, 0), pos(0, 4)
		backspace(b)
		exchange(a, b)
		c_eq(plain(b), "The plan is almost final.", "a suggested deletion keeps the text, struck through")
		del := 0
		for dc in a.collab.decos {if dc.kind == .Sugg_Del {del += dc.to - dc.from}}
		c_ok(del == 4, "and is marked for deletion (%d bytes)", del)
		// Alice accepts the insertion, rejects the deletion
		a.caret, a.anchor = pos(0, 14), pos(0, 14)
		collab_decide(a, true)
		a.caret, a.anchor = pos(0, 1), pos(0, 1)
		collab_decide(a, false)
		exchange(a, b)
		c_eq(plain(a), "The plan is almost final.", "accepted and rejected")
		c_ok(len(a.collab.decos) == 0, "no suggestions remain (%d)", len(a.collab.decos))
		c_eq(plain(b), plain(a), "on both sides")
		// and accepting a deletion removes the text
		b.anchor, b.caret = pos(0, 12), pos(0, 19)
		backspace(b)
		exchange(a, b)
		a.caret, a.anchor = pos(0, 13), pos(0, 13)
		collab_decide(a, true)
		exchange(a, b)
		c_eq(plain(b), "The plan is final.", "an accepted deletion deletes")
	}

	// --- 10. a comment keeps its words as text moves around it
	{
		a := editor(fonts, 0xa1, "alice")
		b := editor(fonts, 0xb2, "bob")
		defer editor_free(a)
		defer editor_free(b)
		load(a, "We ship on Friday.", b)
		a.anchor, a.caret = pos(0, 11), pos(0, 17)
		cid := collab_comment(a, "Is Friday realistic?")
		c_ok(cid != "", "a comment is added on a selection")
		b.caret, b.anchor = pos(0, 0), pos(0, 0)
		type_text(b, "Honestly, ")
		exchange(a, b)
		found := false
		for c in b.collab.comments {
			if c.id == cid {
				found = true
				c_eq(c.quote, "Friday", "the comment still covers its word after text is typed before it")
				c_eq(c.text, "Is Friday realistic?", "and its text travelled")
			}
		}
		c_ok(found, "Bob sees Alice's comment")
		collab_reply(b, cid, "Yes, if QA signs off.")
		exchange(a, b)
		for c in a.collab.comments {
			if c.id == cid {
				c_ok(len(c.replies) == 1 && c.replies[0].author == "bob", "Bob's reply reaches Alice")
			}
		}
		// replace-all elsewhere does not disturb the commented word
		a.caret, a.anchor = pos(0, 0), pos(0, 0)
		clear(&a.find)
		append(&a.find, ..transmute([]u8)string("ship"))
		clear(&a.repl)
		append(&a.repl, ..transmute([]u8)string("launch"))
		replace_all(a)
		exchange(a, b)
		for c in b.collab.comments {
			if c.id == cid {c_eq(c.quote, "Friday", "a replace-all elsewhere leaves the comment's range alone")}
		}
		collab_resolve(a, cid)
		exchange(a, b)
		for c in b.collab.comments {
			if c.id == cid {c_ok(c.resolved, "resolving reaches everyone")}
		}
	}

	// --- 11. three editors, offline, then everything at once
	{
		a := editor(fonts, 0xa1, "alice")
		b := editor(fonts, 0xb2, "bob")
		c := editor(fonts, 0xc3, "carol")
		defer editor_free(a)
		defer editor_free(b)
		defer editor_free(c)
		load(a, "Agenda\n\nItem one\n\nItem two", b, c)
		a.caret, a.anchor = pos(1, 8), pos(1, 8)
		type_text(a, " (Alice)")
		b.caret, b.anchor = pos(2, 0), pos(2, 0)
		type_text(b, "Bob's ")
		set_list(b, .Bullet)
		c.anchor, c.caret = pos(0, 0), pos(0, 6)
		set_kind(c, .H1)
		toggle_italic(c)
		exchange(a, b, c)
		c_eq(plain(a), plain(b), "a and b converge")
		c_eq(plain(b), plain(c), "b and c converge")
		c_eq(doc_to_json(&a.doc, context.temp_allocator), doc_to_json(&c.doc, context.temp_allocator), "including every style and paragraph property")
		c_ok(a.doc.paras[0].kind == .H1 && a.doc.paras[2].list == .Bullet, "each person's change is there")
	}

	// --- 12. random editing through the real commands, three editors
	random_editing(fonts)

	return c_checks, c_fails
}

// random_editing drives three editors with random commands at random carets —
// typing, deleting, splitting, restyling, paragraph kinds, lists, tables and
// their rows and columns, undo and redo — and exchanges updates at random
// moments. Every editor must end with the same document, and each one's model
// must be exactly what its CRDT materialises to.
@(private = "file")
random_editing :: proc(fonts: ^p.Fonts) {
	seed: u64 = 0x5eed
	rnd :: proc(s: ^u64, n: int) -> int {
		s^ = s^ * 6364136223846793005 + 1442695040888963407
		return int((s^ >> 33) % u64(max(1, n)))
	}
	rounds := 6
	if v := os.get_env("DOCS_COLLAB_ROUNDS", context.temp_allocator); v != "" {
		rounds, _ = strconv.parse_int(v)
	}
	diverged := 0
	mismatched := 0
	total := 0
	for round in 0 ..< rounds {
		eds := [3]^State{editor(fonts, 0xa1 + u64(round) * 16, "a"), editor(fonts, 0xb2 + u64(round) * 16, "b"), editor(fonts, 0xc3 + u64(round) * 16, "c")}
		load(eds[0], "Start here.\n\nA second paragraph with **bold** text.\n\n- one\n- two", eds[1], eds[2])
		for step in 0 ..< 70 {
			st := eds[rnd(&seed, 3)]
			blocks := doc_blocks(&st.doc, context.temp_allocator)
			b := blocks[rnd(&seed, len(blocks))]
			l := blk_len(&st.doc, b)
			q := pos_clamp(&st.doc, blk_pos(b, rnd(&seed, l + 1)))
			st.caret, st.anchor = q, q
			if rnd(&seed, 3) == 0 {
				st.anchor = pos_clamp(&st.doc, blk_pos(b, rnd(&seed, l + 1)))
			}
			switch rnd(&seed, 14) {
			case 0, 1, 2:
				words := [?]string{"x", "hello ", "é", "日本 ", "w"}
				type_text(st, words[rnd(&seed, len(words))])
			case 3:
				backspace(st)
			case 4:
				delete_forward(st)
			case 5:
				split_line(st)
			case 6:
				toggle_bold(st)
			case 7:
				toggle_italic(st)
			case 8:
				kinds := [?]Para_Kind{.Body, .H1, .H2, .Quote}
				set_kind(st, kinds[rnd(&seed, len(kinds))])
			case 9:
				set_list(st, rnd(&seed, 2) == 0 ? .Bullet : .None)
			case 10:
				if !in_table(st) && rnd(&seed, 3) == 0 {
					insert_table(st, 2, 2)
				} else if in_table(st) {
					if rnd(&seed, 2) == 0 {table_row_cmd(st, true)} else {table_col_cmd(st, true)}
				}
			case 11:
				do_undo(st)
			case 12:
				do_redo(st)
			case 13:
				set_align(st, .Center)
			}
			relayout(st)
			collab_sync(st)
			total += 1
			if rnd(&seed, 4) == 0 {
				exchange(eds[0], eds[1], eds[2])
			}
			_ = step
			free_all(context.temp_allocator)
		}
		exchange(eds[0], eds[1], eds[2])
		exchange(eds[0], eds[1], eds[2])
		j0 := doc_to_json(&eds[0].doc, context.temp_allocator)
		for i in 1 ..< 3 {
			if doc_to_json(&eds[i].doc, context.temp_allocator) != j0 {diverged += 1}
		}
		for st in eds {
			// the model must be exactly the CRDT's materialisation
			before := strings.clone(doc_to_json(&st.doc, context.temp_allocator), context.temp_allocator)
			collab_materialise(st, {}, false)
			if doc_to_json(&st.doc, context.temp_allocator) != before {mismatched += 1}
		}
		for st in eds {editor_free(st)}
		free_all(context.temp_allocator)
	}
	c_ok(diverged == 0, "random editing: %d commands over %d rounds, three editors converge (%d diverged)", total, rounds, diverged)
	c_ok(mismatched == 0, "random editing: every model equals its CRDT's materialisation (%d did not)", mismatched)
}
