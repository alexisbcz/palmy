// The self-test for everything identities and sync added: front matter, the
// diff that turns an edited file into CRDT operations, the merge of two
// devices' offline edits, links and backlinks inside one identity, search
// across identities, and the folder layout.
//
// The merge tests run two real CRDT replicas in-process — the same
// cloud/collab/crdt the sync server and the office suite use — with the
// network replaced by handing one replica's updates to the other. The
// network itself is covered by e2e.sh against a real stack.
package main

import "core:fmt"
import "core:math/rand"
import "core:os"
import "core:strings"
import crdt "../../cloud/collab/crdt"

run_selftest_sync :: proc() {
	test_front()
	test_inline_tags()
	test_diff()
	test_merge()
	test_merge_registers()
	test_links()
	test_query()
	test_idents()
	test_store_folders()
}

test_front :: proc() {
	f, b, has := split_front("---\nid: 0b6c1b9e-4c2a-4f0e-9a51-6f0f0e2d3c4b\ntags: [Travel, q4]\npinned: true\naliases: [Lisbon]\n---\n\n# Lisbon\n")
	check(has, "front matter is found")
	check_eq(b, "# Lisbon\n", "and the body starts after the blank line that follows it")
	m := parse_front(f, context.temp_allocator)
	check_eq(m.id, "0b6c1b9e-4c2a-4f0e-9a51-6f0f0e2d3c4b", "the id is read")
	check(len(m.tags) == 2 && m.tags[0] == "travel" && m.tags[1] == "q4", "tags are read and lower-cased")
	check(m.pinned, "pinned is read")
	check(strings.contains(m.extra, "aliases: [Lisbon]"), "a key it does not know is kept verbatim")
	again := compose(m, b)
	f2, b2, _ := split_front(again)
	m2 := parse_front(f2, context.temp_allocator)
	check_eq(b2, b, "writing it back keeps the body")
	check(m2.id == m.id && m2.pinned && len(m2.tags) == 2, "and the facts")
	check(strings.contains(f2, "aliases: [Lisbon]"), "and the unknown key")
	check_eq(compose(m2, b2), again, "and saving twice changes no bytes")

	_, b3, has3 := split_front("---\nnot closed\n# Title\n")
	check(!has3, "an unclosed fence is not front matter")
	check_eq(b3, "---\nnot closed\n# Title\n", "and the text is left alone")
	_, _, has4 := split_front("# Title\n---\nid: x\n---\n")
	check(!has4, "a rule further down is not front matter")
	_, b5, has5 := split_front("\xef\xbb\xbf---\nid: x\n---\nhi\n")
	check(has5 && b5 == "hi\n", "a byte order mark before the fence is tolerated")
	l := parse_front("tags:\n  - one\n  - Two words\n", context.temp_allocator)
	check(len(l.tags) == 2 && l.tags[1] == "two-words", "a YAML list of tags works too")
	check_eq(render_front(Meta{}), "", "a note with nothing to say has no front matter")
	check_eq(title_of("---\nid: x\n---\n\n# Real title\n", context.temp_allocator), "Real title", "the title skips front matter")
	id := new_id(context.temp_allocator)
	check(is_uuid(id) && id[14] == '4', "new ids are version 4 UUIDs")
	check(new_id(context.temp_allocator) != id, "and they differ")
}

test_inline_tags :: proc() {
	tags := make([dynamic]string, context.temp_allocator)
	inline_tags("# Heading\nBuy #groceries and #Travel/Lisbon today.\n`#notatag` and\n```\n#nor this\n```\nprice#5 no\n", &tags, context.temp_allocator)
	check(len(tags) == 2, "two #tags found, not the heading, code or a mid-word #")
	if len(tags) == 2 {
		check_eq(tags[0], "groceries", "the first")
		check_eq(tags[1], "travel/lisbon", "nested tags keep their slash")
	}
}

test_diff :: proc() {
	same := diff_text("abc\n", "abc\n")
	check(len(same) == 0, "no change, no hunks")

	old := "# Trip\n\nline one\nline two\nline three\nline four\nline five\n"
	new := "# Trip\n\nline one!\nline two\nline three\nline FOUR\nline five\nline six\n"
	hs := diff_text(old, new)
	check_eq(apply_hunks(old, hs), new, "hunks rebuild the new text")
	check(len(hs) == 3, "three scattered edits are three hunks, not one big replace")
	small := true
	for h in hs {
		if h.remove > 4 || len(h.insert) > 10 {small = false}
	}
	check(small, "and each touches only the characters that changed")

	cafe := "café crème\n"
	u := diff_text(cafe, "café crêpe\n")
	check_eq(apply_hunks(cafe, u), "café crêpe\n", "a change next to a multibyte character")
	for h in u {
		check(h.at == len(cafe) || (cafe[h.at] & 0xc0) != 0x80, "a hunk never starts inside a character")
	}

	// Random edit scripts: the diff must always rebuild the new text exactly.
	r := rand.create(42)
	context.random_generator = rand.default_random_generator(&r)
	words := [?]string{"alpha ", "beta ", "\n", "- [ ] task\n", "é", "日本 ", "## h\n", "x"}
	ok := true
	for round in 0 ..< 400 {
		a := strings.builder_make(context.temp_allocator)
		for _ in 0 ..< rand.int_max(40) {
			strings.write_string(&a, words[rand.int_max(len(words))])
		}
		at := strings.to_string(a)
		b := strings.builder_make(context.temp_allocator)
		i := 0
		for i < len(at) {
			switch rand.int_max(10) {
			case 0:
				strings.write_string(&b, words[rand.int_max(len(words))])
			case 1:
				// drop a rune
				i += 1
				for i < len(at) && (at[i] & 0xc0) == 0x80 {i += 1}
				continue
			}
			strings.write_byte(&b, at[i])
			i += 1
		}
		bt := strings.to_string(b)
		if apply_hunks(at, diff_text(at, bt)) != bt {
			ok = false
			fmt.printfln("  diff round %d failed", round)
			break
		}
	}
	check(ok, "400 random edit scripts are rebuilt exactly")
}

// replica is one device's copy of a note, with its pending updates.
@(private = "file")
Replica :: struct {
	d:   ^crdt.Doc,
	out: [dynamic][]u8,
}

@(private = "file")
replica_edit :: proc(r: ^Replica, text: string) {
	crdt.begin(r.d)
	doc_set_body(r.d, text)
	crdt.commit(r.d)
	if up := crdt.take_update(r.d); up != nil {
		append(&r.out, up)
	}
}

@(private = "file")
deliver :: proc(from, to: ^Replica) {
	for up in from.out {
		crdt.apply_update(to.d, up)
	}
}

test_merge :: proc() {
	base := "# Lisbon trip\n\nFlights on Friday.\n\n## To book\n- [ ] the hotel near Alfama\n- [ ] a table at Prado\n\n## Ideas\nThe tram to Belém.\n"
	laptop := Replica{d = crdt.doc_make(0x1111)}
	phone := Replica{d = crdt.doc_make(0x2222)}
	defer crdt.doc_destroy(laptop.d)
	defer crdt.doc_destroy(phone.d)

	// Created on the laptop, synced to the phone.
	replica_edit(&laptop, base)
	deliver(&laptop, &phone) // the log keeps it: delivering it again later is harmless
	check_eq(doc_body(phone.d), base, "the phone starts from the laptop's note")

	// Offline, in different places.
	replica_edit(&laptop, strings.concatenate({"# Lisbon trip\n\nFlights on Friday, 07:40 from Orly.\n\n## To book\n- [x] the hotel near Alfama\n- [ ] a table at Prado\n\n## Ideas\nThe tram to Belém.\n"}, context.temp_allocator))
	replica_edit(&phone, strings.concatenate({base, "Pastéis at Manteigaria.\n"}, context.temp_allocator))
	// And on the same line.
	cur_l := doc_body(laptop.d)
	replica_edit(&laptop, strings.concatenate({cur_l[:strings.index(cur_l, "Prado") + 5], " for Saturday", cur_l[strings.index(cur_l, "Prado") + 5:]}, context.temp_allocator))
	cur_p := doc_body(phone.d)
	replica_edit(&phone, strings.concatenate({cur_p[:strings.index(cur_p, "Prado") + 5], " (terrace)", cur_p[strings.index(cur_p, "Prado") + 5:]}, context.temp_allocator))

	deliver(&laptop, &phone)
	deliver(&phone, &laptop)
	a := doc_body(laptop.d)
	b := doc_body(phone.d)
	check_eq(a, b, "after exchanging updates both devices hold the same text")
	check(strings.contains(a, "07:40 from Orly"), "the laptop's edit is in it")
	check(strings.contains(a, "- [x] the hotel"), "the laptop's ticked box is in it")
	check(strings.contains(a, "Manteigaria"), "the phone's line is in it")
	check(strings.contains(a, "Prado for Saturday") || strings.contains(a, "Prado (terrace)"), "both edits of one line are in it")
	check(strings.contains(a, "for Saturday") && strings.contains(a, "(terrace)"), "neither one lost")
	check(strings.count(a, "Lisbon trip") == 1, "and nothing is duplicated")

	// Delivery order and duplicates do not matter.
	c := Replica{d = crdt.doc_make(0x3333)}
	defer crdt.doc_destroy(c.d)
	#reverse for up in phone.out {crdt.apply_update(c.d, up)}
	for up in laptop.out {crdt.apply_update(c.d, up)}
	for up in laptop.out {crdt.apply_update(c.d, up)}
	check_eq(doc_body(c.d), a, "a third device converges whatever order the updates arrive in")
}

test_merge_registers :: proc() {
	l := Replica{d = crdt.doc_make(0xaaaa)}
	p := Replica{d = crdt.doc_make(0xbbbb)}
	defer crdt.doc_destroy(l.d)
	defer crdt.doc_destroy(p.d)
	crdt.begin(l.d)
	doc_set_meta(l.d, Doc_Meta{notebook = "Travel"})
	crdt.commit(l.d)
	append(&l.out, crdt.take_update(l.d))
	deliver(&l, &p)
	clear(&l.out)

	crdt.begin(l.d)
	doc_set_meta(l.d, Doc_Meta{notebook = "Travel/2026", tags = "travel"})
	crdt.commit(l.d)
	append(&l.out, crdt.take_update(l.d))
	crdt.begin(p.d)
	doc_set_meta(p.d, Doc_Meta{notebook = "Travel", pinned = true})
	crdt.commit(p.d)
	append(&p.out, crdt.take_update(p.d))
	deliver(&l, &p)
	deliver(&p, &l)
	ml, mp := doc_meta(l.d), doc_meta(p.d)
	check(ml == mp, "moved on one device and pinned on the other: both agree")
	check(ml.notebook == "Travel/2026" && ml.pinned && ml.tags == "travel", "and both changes stand")
}

test_links :: proc() {
	ls := links_in("See [[Lisbon trip]] and [[Lisbon trip|the trip]], [[Plan#Hotels]].\n`[[not a link]]`\n[[northwind:Q4 plan]] and [[Meeting: Tuesday]]\n```\n[[in code]]\n```\n")
	check(len(ls) == 6, "six links (inline code is not skipped by design: it is rare, and cheap to ignore)")
	if len(ls) >= 6 {
		check_eq(ls[1].alias, "the trip", "an alias")
		check_eq(ls[2].head, "Hotels", "a heading")
		check_eq(ls[4].handle, "northwind", "a qualified link names an identity")
		check_eq(ls[4].target, "Q4 plan", "and a note")
		check_eq(ls[5].handle, "", "a title with a colon and a space is not a qualifier")
		check_eq(ls[5].target, "Meeting: Tuesday", "it is the title")
	}

	notes := make([dynamic]Note, context.temp_allocator)
	mk :: proc(notes: ^[dynamic]Note, ident: int, path, body: string) {
		n := note_from_text(path, base_name(path), body, {})
		n.ident = ident
		append(notes, n)
	}
	mk(&notes, 0, "/p/lisbon-trip.md", "# Lisbon trip\n")
	mk(&notes, 0, "/p/plan.md", "# Plan\n\nSee [[Lisbon trip]].\n")
	mk(&notes, 1, "/w/q4.md", "# Lisbon trip\n\nA work note with the same title.\n")
	mk(&notes, 1, "/w/standup.md", "# Standup\n\n[[Lisbon trip]] and [[camille:Lisbon trip]]\n")
	k, at := link_resolve(notes[:], 0, "camille", ls[0])
	check(k == .Resolved && at == 0, "a link resolves to its own identity's note")
	k2, at2 := link_resolve(notes[:], 1, "northwind", ls[0])
	check(k2 == .Resolved && at2 == 2, "the same link in the work identity resolves to the work note, never across")
	cross := Link{target = "Lisbon trip", handle = "camille"}
	k3, _ := link_resolve(notes[:], 1, "northwind", cross)
	check(k3 == .Elsewhere, "a link qualified with another identity is never resolved from here")
	own := Link{target = "Standup", handle = "northwind"}
	k4, at4 := link_resolve(notes[:], 1, "northwind", own)
	check(k4 == .Resolved && at4 == 3, "qualified with its own handle, it is an ordinary link")
	k5, _ := link_resolve(notes[:], 0, "camille", Link{target = "Nowhere"})
	check(k5 == .Unresolved, "nothing of that name: unresolved, not a guess")
	bl := backlinks(notes[:], 0, "camille")
	check(len(bl) == 1 && bl[0] == 1, "backlinks come from the same identity only")
	bl2 := backlinks(notes[:], 2, "northwind")
	check(len(bl2) == 1 && bl2[0] == 3, "and the work note's backlink is the work standup")
}

test_query :: proc() {
	q := parse_query("lisbon tag:travel #2026 in:camille is:pinned when:today", context.temp_allocator)
	check(len(q.words) == 1 && q.words[0] == "lisbon", "plain words")
	check(len(q.tags) == 2, "tag: and # both name tags")
	check_eq(q.ident, "camille", "in: names an identity")
	check(q.pinned, "is:pinned")
	check(len(q.unknown) == 1 && q.unknown[0] == "when:today", "an operator it does not know is reported")
	q2 := parse_query("http://example.com 10:30", context.temp_allocator)
	check(len(q2.unknown) == 0 && len(q2.words) == 2, "a URL and a time are words, not operators")

	notes := make([dynamic]Note, context.temp_allocator)
	for x in ([?]struct {
		ident: int,
		path:  string,
		body:  string,
	}{{0, "/p/a.md", "# Lisbon trip\n\n#travel\n"}, {1, "/w/b.md", "# Budget\n\nlisbon offsite costs\n"}, {0, "/p/c.md", "# Groceries\n"}}) {
		n := note_from_text(x.path, base_name(x.path), x.body, {})
		n.ident = x.ident
		append(&notes, n)
	}
	handles := []string{"camille", "northwind"}
	hits := search_notes(notes[:], handles, parse_query("lisbon"))
	check(len(hits) == 2, "a word is found in both identities")
	check(len(hits) == 2 && hits[0].note == 0 && hits[0].in_title, "a title hit ranks first")
	check(len(search_notes(notes[:], handles, parse_query("lisbon in:northwind"))) == 1, "in: narrows to one identity")
	check(len(search_notes(notes[:], handles, parse_query("#travel"))) == 1, "a tag finds the tagged note")
	check(len(search_notes(notes[:], handles, parse_query("lisbon groceries"))) == 0, "every word must match")
}

test_idents :: proc() {
	home := fmt.tprintf("/tmp/palmy-notes-idents-%d", os.get_pid())
	defer os.remove_all(home)
	os.make_directory_all(fmt.tprintf("%s/camille", home))
	os.make_directory_all(fmt.tprintf("%s/northwind", home))
	os.make_directory_all(fmt.tprintf("%s/.hidden", home))
	ident_bind(fmt.tprintf("%s/northwind", home), "6f1c0c55-1111-4111-8111-111111111111", "northwind", "Northwind", "blue", "work")
	ident_bind(fmt.tprintf("%s/camille", home), "6f1c0c55-2222-4222-8222-222222222222", "camille", "Camille Roux", "teal", "personal")

	saved_one := strings.clone(os.get_env("PALMY_NOTES_DIR", context.temp_allocator), context.temp_allocator)
	saved_root := strings.clone(os.get_env("PALM_NOTES_ROOT", context.temp_allocator), context.temp_allocator)
	saved_scope := strings.clone(os.get_env("PALM_IDENTITY", context.temp_allocator), context.temp_allocator)
	defer {
		_ = os.set_env("PALMY_NOTES_DIR", saved_one)
		_ = os.set_env("PALM_NOTES_ROOT", saved_root)
		_ = os.set_env("PALM_IDENTITY", saved_scope)
	}
	_ = os.unset_env("PALMY_NOTES_DIR")
	_ = os.set_env("PALM_NOTES_ROOT", home)
	_ = os.unset_env("PALM_IDENTITY")

	ids := idents_load(context.temp_allocator)
	check(len(ids) == 2, "one identity per folder, hidden folders skipped")
	if len(ids) == 2 {
		check_eq(ids[0].handle, "camille", "personal sorts before work")
		check_eq(ids[0].name, "Camille Roux", "the display name comes from identity.json")
		check_eq(ids[1].color, "blue", "and so does the colour")
		check(ident_bound(ids[1]), "a folder with identity.json is bound to the cloud")
	}
	_ = os.set_env("PALM_IDENTITY", "northwind")
	scoped := idents_load(context.temp_allocator)
	check(len(scoped) == 1 && scoped[0].handle == "northwind", "a scoped process sees its own identity's folder and nothing else")
	_ = os.set_env("PALM_IDENTITY", "nobody")
	none := idents_load(context.temp_allocator)
	check(len(none) == 0, "a scope with no folder here sees nothing, not a default")
	check(ident_find(ids[:], "Northwind") == 1 && ident_find(ids[:], "work") == 1, "an identity is found by handle, name or kind")
	check(identity_hex("teal", false) != identity_hex("teal", true), "identity colours have a light and a dark value")
}

test_store_folders :: proc() {
	root := fmt.tprintf("/tmp/palmy-notes-folders-%d", os.get_pid())
	os.make_directory_all(root)
	defer os.remove_all(root)
	p, ok := store_create_in(root, "Travel", "# Lisbon trip\n\n#travel\n")
	check(ok && strings.has_suffix(p, "/Travel/lisbon-trip.md"), "a note is created in a notebook folder")
	_, ok2 := store_create_in(root, "", "# Inbox item\n")
	check(ok2, "and one in the inbox")
	shared_dir := fmt.tprintf("%s/%s/alice", root, SHARED_DIR)
	os.make_directory_all(shared_dir)
	_ = os.write_entire_file(fmt.tprintf("%s/plan.md", shared_dir), transmute([]u8)string("---\nid: 6f1c0c55-3333-4333-8333-333333333333\nshared_from: alice\naccess: read\n---\n\n# Alice's plan\n"))
	all := store_load(root)
	defer notes_free(&all)
	check(len(all) == 3, "all three are loaded")
	var_trip := -1
	for n, i in all {
		if n.title == "Lisbon trip" {var_trip = i}
	}
	check(var_trip >= 0 && all[var_trip].notebook == "Travel", "its notebook is its folder")
	check(var_trip >= 0 && len(all[var_trip].tags) == 1, "its #tag is a tag")
	check(var_trip >= 0 && is_uuid(all[var_trip].meta.id), "and it has an id from birth")
	for n in all {
		if n.title == "Alice's plan" {
			check(n.shared && n.meta.access == "read", "a note under Shared/ is someone else's, with its access")
		}
	}
	books := notebooks_of(all[:], 0)
	check(len(books) == 1 && books[0].name == "Travel", "notebooks leave out the inbox and Shared/")

	if var_trip >= 0 {
		tp, tok := store_trash(root, all[var_trip])
		check(tok && strings.contains(tp, "/.trash/Travel/"), "trash keeps the notebook under .trash/")
		again := store_load(root)
		defer notes_free(&again)
		for n in again {
			if n.title == "Lisbon trip" {
				check(n.trashed && n.notebook == "Travel", "a trashed note knows where it came from")
				rp, rok := store_restore(root, n)
				check(rok && strings.has_suffix(rp, "/Travel/lisbon-trip.md"), "and restore puts it back")
			}
		}
	}
}
