// `contacts --selftest`: the model, offline. Cards go through the same save
// path the window and the CLI use, on in-memory books.
package main

import "core:fmt"
import "core:os"
import "core:strings"
import ical "../../cloud/dav/ical"
import vcard "../../cloud/dav/vcard"
import dc "../../cloud/dav/client"
import kit "kit:."

@(private = "file")
checks, failures: int

@(private = "file")
check :: proc(ok: bool, what: string) {
	checks += 1
	if !ok {
		failures += 1
		fmt.printfln("  FAIL  %s", what)
	}
}

// fixture_book adds an in-memory book.
fixture_book :: proc(st: ^Store, handle, seg, name, access: string) -> int {
	context.allocator = store_alloc(st)
	append(&st.books, Book {
		handle = handle,
		remote = dc.Remote{href = fmt.aprintf("/dav/addressbooks/%s/%s/", handle, seg), kind = "addressbook", handle = handle,
			seg = seg, display_name = name, access = access, owner = handle},
		readonly = access == "read",
	})
	return len(st.books) - 1
}

MIXED_VCF :: "BEGIN:VCARD\r\nVERSION:3.0\r\nPRODID:-//Apple Inc.//iPhone OS 17.0//EN\r\n" +
	"N:Okonjo;Amara;;;\r\nFN:Amara Okonjo\r\nORG:Lagos Rowing Club;\r\n" +
	"EMAIL;type=INTERNET;type=HOME;type=pref:amara@rowing.example\r\n" +
	"TEL;type=CELL;type=VOICE:+234 801 555 0199\r\nX-ABLabel:rowing\r\nUID:amara-3\r\nEND:VCARD\r\n" +
	"BEGIN:VCARD\r\nVERSION:4.0\r\nFN:Teodor Varga\r\nN:Varga;Teodor;;;\r\n" +
	"EMAIL;TYPE=work:teo@studio.example\r\nEND:VCARD\r\n" +
	"BEGIN:VCARD\r\nVERSION:2.1\r\nFN:Too Old\r\nEND:VCARD\r\n"

run_selftest :: proc() -> int {
	st := store_make()
	context.allocator = store_alloc(st)
	a := fixture_book(st, "alice", "default", "Contacts", "owner")
	w := fixture_book(st, "alice-work", "default", "Contacts", "owner")
	shared := fixture_book(st, "alice", "bob~default", "Contacts (bob)", "read")
	append(&st.idents, Ident{"alice", "Alice Martin", "indigo", "personal"}, Ident{"alice-work", "Alice (Northwind)", "emerald", "work"})

	// A card round-trips through Card and back, unknown properties kept.
	apple := "BEGIN:VCARD\r\nVERSION:3.0\r\nN:Lovelace;Ada;;;\r\nFN:Ada Lovelace\r\nTEL;type=CELL:+44 20 7946 0000\r\nX-SOCIALPROFILE;type=mastodon:@ada\r\nUID:ada-1\r\nEND:VCARD\r\n"
	comp, _, ok := ical.parse_one(apple)
	check(ok, "an Apple 3.0 card parses")
	ada := vcard.from_component(comp)
	i, err := save(st, a, ada)
	check(err == "" && i >= 0, "a card saves into a book")
	text := card_text(st.contacts[i].card)
	check(strings.contains(text, "VERSION:3.0"), "an edited 3.0 card stays 3.0")
	check(strings.contains(text, "X-SOCIALPROFILE"), "unknown properties survive an edit")
	card := st.contacts[i].card
	card.org = "Analytical Engines"
	save(st, a, card, i)
	check(st.contacts[i].card.org == "Analytical Engines", "an edit replaces in place")
	check(st.contacts[i].card.uid == "ada-1", "and keeps the UID")

	// New contacts get a UID and a name.
	j, _ := save(st, a, vcard.Card{given = "Grace", family = "Hopper", emails = []vcard.Typed{{value = "grace@navy.example"}}})
	check(len(st.contacts[j].card.uid) == 36, "a new contact gets a UUID")
	check(st.contacts[j].name == strings.concatenate({st.contacts[j].card.uid, ".vcf"}, context.temp_allocator), "named <uid>.vcf")
	check(display(st.contacts[j]) == "Grace Hopper", "the display name comes from N")

	// A read-only share refuses writes.
	_, rerr := save(st, shared, vcard.Card{fn = "Nope"})
	check(rerr != "", "a read-only book refuses a new card")

	// Sorting and search.
	save(st, w, vcard.Card{given = "Zoe", family = "Abbott", org = "Northwind", phones = []vcard.Typed{{value = "+1 (415) 555-0100"}}})
	all := visible(st, Filter{book = -1, group = -1})
	check(len(all) == 3, "three individuals across both identities")
	check(display(st.contacts[all[0]]) == "Zoe Abbott", "sorted by family name first")
	check(initial(st.contacts[all[0]]) == "A", "sectioned by the family initial")
	only_work := visible(st, Filter{handle = "alice-work", book = -1, group = -1})
	check(len(only_work) == 1, "an identity filter shows only that identity")
	check(len(visible(st, Filter{book = -1, group = -1, query = "4155550"})) == 1, "search matches phone digits")
	check(len(visible(st, Filter{book = -1, group = -1, query = "NAVY"})) == 1, "search matches email, case-insensitively")
	check(len(visible(st, Filter{book = -1, group = -1, query = "engines"})) == 1, "search matches organisation")

	// Groups.
	g, gerr := new_group(st, a, "Climbing club")
	check(gerr == "" && is_group(st.contacts[g]), "a group is a KIND:group card")
	check(set_member(st, g, find_uid(st, "ada-1"), true) == "", "add a member")
	check(set_member(st, g, find_uid(st, "ada-1"), true) == "", "adding twice is harmless")
	check(len(st.contacts[g].card.members) == 1, "and holds one member")
	check(st.contacts[g].card.members[0] == "urn:uuid:ada-1", "as urn:uuid")
	gtext := card_text(st.contacts[g].card)
	check(strings.contains(gtext, "KIND:group") && strings.contains(gtext, "MEMBER:urn:uuid:ada-1"), "written as vCard 4 KIND/MEMBER")
	check(len(visible(st, Filter{book = -1, group = g})) == 1, "the list filters by group")
	check(len(groups_of(st, a, "ada-1")) == 1, "a contact knows its groups")
	work_contact := find_uid(st, st.contacts[visible(st, Filter{handle = "alice-work", book = -1, group = -1})[0]].card.uid)
	check(set_member(st, g, work_contact, true) != "", "a group refuses a contact from another identity")
	check(rename_group(st, g, "Bouldering") == "" && display(st.contacts[g]) == "Bouldering", "rename a group")

	// Duplicates and merge.
	dup, _ := save(st, a, vcard.Card{fn = "Ada King", emails = []vcard.Typed{{value = "ADA@engines.example"}}, phones = []vcard.Typed{{value = "+44 20 7946 0000"}}, note = "met at the Royal Society"})
	card = st.contacts[find_uid(st, "ada-1")].card
	card.emails = []vcard.Typed{{value = "ada@engines.example"}}
	save(st, a, card, find_uid(st, "ada-1"))
	dup_uid := strings.clone(st.contacts[dup].card.uid)
	set_member(st, g, dup, true)
	pairs := duplicates(st, Filter{book = -1, group = -1})
	check(len(pairs) == 1, "one duplicate pair")
	if len(pairs) == 1 {
		check(pairs[0].reason == "email", "found by email, case-insensitively")
	}
	check(merge(st, find_uid(st, "ada-1"), find_uid(st, dup_uid)) == "", "merge")
	survivor := st.contacts[find_uid(st, "ada-1")].card
	check(find_uid(st, dup_uid) < 0, "the dropped card is gone")
	check(len(survivor.emails) == 1, "emails are unioned without repeats")
	check(len(survivor.phones) == 1, "phones match by digits")
	check(survivor.note == "met at the Royal Society", "an empty note is filled")
	check(survivor.org == "Analytical Engines", "kept fields are not overwritten")
	members := st.contacts[find_uid(st, st.contacts[g].card.uid)].card.members
	check(len(members) == 1 && members[0] == "urn:uuid:ada-1", "group references move to the survivor, once")
	check(len(duplicates(st, Filter{book = -1, group = -1})) == 0, "no duplicates left")

	// Import a mixed file.
	r, ierr := import_vcf(st, w, MIXED_VCF)
	check(ierr == "", "a mixed .vcf imports")
	check(r.added == 2 && r.skipped == 1, fmt.tprintf("two added, the 2.1 card skipped (%v)", r))
	amara := find_uid(st, "amara-3")
	check(amara >= 0 && st.contacts[amara].card.org == "Lagos Rowing Club", "the 3.0 card's fields come through")
	teo := -1
	for c, k in st.contacts {
		if display(c) == "Teodor Varga" {
			teo = k
		}
	}
	check(teo >= 0 && len(st.contacts[teo].card.uid) == 36, "a card without UID gets one")
	r2, _ := import_vcf(st, w, MIXED_VCF)
	check(r2.updated == 1 && r2.added == 1, "importing again updates by UID (a UID-less card is new again)")
	_, roerr := import_vcf(st, shared, MIXED_VCF)
	check(roerr != "", "importing into a read-only book is refused")

	// Export.
	out := export_vcf(st, visible(st, Filter{handle = "alice", book = -1, group = -1}), "4.0", context.temp_allocator)
	check(strings.count(out, "BEGIN:VCARD") == 2, "export writes one card per contact")
	back, bok := vcard.parse_all(out)
	check(bok && len(back) == 2, "the export reads back")
	out3 := export_vcf(st, {amara}, "3.0", context.temp_allocator)
	check(strings.contains(out3, "VERSION:3.0") && strings.contains(out3, "TYPE=INTERNET"), "export as 3.0 for older clients")

	// Delete takes a contact out of its groups.
	check(remove(st, find_uid(st, "ada-1")) == "", "delete")
	gi := -1
	for c, k in st.contacts {
		if is_group(c) {
			gi = k
		}
	}
	check(gi >= 0 && len(st.contacts[gi].card.members) == 0, "a deleted contact leaves its groups")
	check(find_book(st, "alice-work/default") == w, "a book resolves by identity/segment")
	check(find_book(st, "", "alice") == a, "the default book is the first own one")

	test_password_secret()

	if failures == 0 {
		fmt.printfln("contacts selftest: %d checks passed", checks)
		return 0
	}
	fmt.printfln("contacts selftest: %d checks, %d FAILED", checks, failures)
	return 1
}

// test_password_secret: --password is declared secret, so the audit log, the
// --json result and a refusal all carry <redacted> where it was. Run in
// process against a scratch HOME, so no real session is read.
test_password_secret :: proc() {
	dir := "/tmp/palmy-contacts-selftest-secret"
	_ = os.remove_all(dir)
	_ = os.make_directory_all(dir)
	audit := fmt.tprintf("%s/audit.jsonl", dir)
	keys := [?]string{"HOME", "XDG_CONFIG_HOME", "XDG_DATA_HOME", "PALM_AUDIT"}
	old: [len(keys)]string
	for k, i in keys {
		old[i] = strings.clone(os.get_env(k, context.temp_allocator))
		_ = os.set_env(k, k == "PALM_AUDIT" ? audit : dir)
	}
	defer for k, i in keys {
		_ = os.set_env(k, old[i])
	}
	_, out, _ := kit.cli_capture(surface(), {"signin", "a@b.test", "--password", "hunter2-7319", "--dry-run", "--json"})
	raw, _ := os.read_entire_file_from_path(audit, context.temp_allocator)
	log := string(raw)
	check(strings.contains(log, `"verb":"signin"`), "signin is audited")
	check(!strings.contains(log, "hunter2-7319") && strings.contains(log, "<redacted>"), "but its --password is not: <redacted> in its place")
	check(!strings.contains(out, "hunter2-7319"), "nor is it in what signin prints")
}
