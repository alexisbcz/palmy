// The address books and what is in them: one model for the window and the
// command line, so the two cannot disagree.
//
// Where the data lives: the davclient cache (cloud/dav/client). Every
// address book an identity reaches is a directory of .vcf files there; this
// model reads them, writes edits back into them (marked dirty), and `sync`
// reconciles them with the server over CardDAV. With no account (the
// screenshots, the self-test) the same model runs on in-memory books.
//
// Everything a Store holds is allocated from its own arena, so a reload —
// after a sync, say — is dropping the arena and reading again.
package main

import "base:runtime"
import "core:crypto"
import "core:encoding/uuid"
import "core:fmt"
import "core:mem/virtual"
import ck "../cloudkit"
import "core:os"
import "core:slice"
import "core:strings"
import ical "../../cloud/dav/ical"
import vcard "../../cloud/dav/vcard"
import dc "../../cloud/dav/client"

Ident :: struct {
	handle:       string,
	display_name: string,
	color:        string, // a Tailwind palette name
	kind:         string,
}

Book :: struct {
	handle:   string, // the identity whose home lists it
	remote:   dc.Remote,
	local:    ^dc.Local, // nil for an in-memory book
	readonly: bool,
}

Contact :: struct {
	book: int,
	name: string, // the resource name, <uid>.vcf
	card: vcard.Card,
}

Store :: struct {
	arena:    virtual.Arena,
	acct:     ^dc.Account, // nil offline / fixtures
	idents:   [dynamic]Ident,
	books:    [dynamic]Book,
	contacts: [dynamic]Contact, // individuals and groups
	online:   bool,
	err:      string, // the last sync or load problem, for the status bar
}

store_alloc :: proc(st: ^Store) -> runtime.Allocator {
	return virtual.arena_allocator(&st.arena)
}
store_make :: proc() -> ^Store {
	st := new(Store)
	_ = virtual.arena_init_growing(&st.arena)
	context.allocator = store_alloc(st)
	st.idents = make([dynamic]Ident, 0, 4)
	st.books = make([dynamic]Book, 0, 4)
	st.contacts = make([dynamic]Contact, 0, 64)
	return st
}

store_reset :: proc(st: ^Store) {
	acct := st.acct
	online := st.online
	virtual.arena_destroy(&st.arena)
	st^ = {}
	_ = virtual.arena_init_growing(&st.arena)
	context.allocator = store_alloc(st)
	st.acct = acct
	st.online = online
	st.idents = make([dynamic]Ident, 0, 4)
	st.books = make([dynamic]Book, 0, 4)
	st.contacts = make([dynamic]Contact, 0, 64)
}

ident_of :: proc(st: ^Store, handle: string) -> ^Ident {
	for &i in st.idents {
		if i.handle == handle {
			return &i
		}
	}
	return nil
}

// ---------------------------------------------------------------------------
// Loading from the cache, and syncing it
// ---------------------------------------------------------------------------

// load reads identities and books from the server when it can, from the
// cache when it cannot, then every card from the cache. `only` narrows to
// one identity (the CLI's --identity; PALM_IDENTITY narrows the session
// itself, so the server would not list the others anyway).
load :: proc(st: ^Store, only := "", sync_first := false) {
	store_reset(st)
	context.allocator = store_alloc(st)
	a := st.acct
	if a == nil {
		return
	}
	st.online = false
	if dc.signed_in(a) {
		if e := dc.load_identities(a); dc.ok(e) {
			st.online = true
			for i in a.idents {
				append(&st.idents, Ident{strings.clone(i.handle), strings.clone(i.display_name), strings.clone(i.color), strings.clone(i.kind)})
			}
			idents_save(a, st.idents[:])
		} else {
			st.err = fmt.aprintf("offline: %s", e.message)
		}
	}
	if !st.online {
		idents_load(a, &st.idents)
	}
	if only != "" {
		for i := 0; i < len(st.idents); {
			if st.idents[i].handle != only {
				ordered_remove(&st.idents, i)
			} else {
				i += 1
			}
		}
	}
	for i in st.idents {
		remotes: []dc.Remote
		if st.online {
			list, e := dc.discover(a, i.handle, "addressbook")
			if dc.ok(e) {
				remotes = list
				dc.remotes_save(a, i.handle, "addressbook", list)
			} else {
				st.err = fmt.aprintf("could not list %s's address books: %s", i.handle, e.message)
				remotes = dc.remotes_load(a, i.handle, "addressbook")
			}
		} else {
			remotes = dc.remotes_load(a, i.handle, "addressbook")
		}
		for rm in remotes {
			l := dc.local_open(dc.cache_dir(a, i.handle, "addressbook", rm.seg), rm)
			if l.remote.href == "" {
				l.remote = rm
			}
			append(&st.books, Book{handle = i.handle, remote = l.remote, local = l, readonly = rm.access == "read"})
		}
	}
	if sync_first && st.online {
		sync_all(st)
	}
	read_cards(st)
}

read_cards :: proc(st: ^Store) {
	context.allocator = store_alloc(st)
	clear(&st.contacts)
	for &b, bi in st.books {
		if b.local == nil {
			continue
		}
		for it in dc.local_items(b.local) {
			c, _, ok := ical.parse_one(it.data)
			if !ok || c.name != "VCARD" {
				continue
			}
			append(&st.contacts, Contact{book = bi, name = it.name, card = vcard.from_component(c)})
		}
	}
}

Sync_Report :: struct {
	pushed, pulled, removed, conflicts, failed: int,
}

// sync_all pushes local edits and pulls server changes for every book.
sync_all :: proc(st: ^Store) -> Sync_Report {
	context.allocator = store_alloc(st)
	r: Sync_Report
	if st.acct == nil || !st.online {
		return r
	}
	for &b in st.books {
		if b.local == nil {
			continue
		}
		s, e := dc.sync(st.acct, b.local)
		if !dc.ok(e) {
			r.failed += 1
			st.err = fmt.aprintf("sync %s/%s: %s", b.handle, b.remote.seg, e.message)
			continue
		}
		r.pushed += s.pushed
		r.pulled += s.pulled
		r.removed += s.removed
		r.conflicts += s.conflicts
	}
	return r
}

// The identity list, cached so an offline start still knows the colours.
@(private = "file")
idents_save :: proc(a: ^dc.Account, list: []Ident) {
	_ = ck.make_dirs(a.cache, os.perm(0o700))
	sb := strings.builder_make(context.temp_allocator)
	for i in list {
		fmt.sbprintf(&sb, "%s\t%s\t%s\t%s\n", i.handle, i.display_name, i.color, i.kind)
	}
	_ = os.write_entire_file(fmt.tprintf("%s/identities", a.cache), transmute([]u8)strings.to_string(sb))
}

@(private = "file")
idents_load :: proc(a: ^dc.Account, out: ^[dynamic]Ident) {
	data, err := os.read_entire_file_from_path(fmt.tprintf("%s/identities", a.cache), context.temp_allocator)
	if err != nil {
		return
	}
	rest := string(data)
	for line in strings.split_lines_iterator(&rest) {
		c := strings.split(line, "\t", context.temp_allocator)
		if len(c) >= 4 {
			append(out, Ident{strings.clone(c[0]), strings.clone(c[1]), strings.clone(c[2]), strings.clone(c[3])})
		}
	}
}

// ---------------------------------------------------------------------------
// Queries
// ---------------------------------------------------------------------------

is_group :: proc(c: Contact) -> bool {
	return c.card.kind == "group"
}

display :: proc(c: Contact) -> string {
	return vcard.display_name(c.card)
}

// sort_key is family, given, then the display name, case-folded.
sort_key :: proc(c: Contact, allocator := context.temp_allocator) -> string {
	if c.card.family != "" || c.card.given != "" {
		return strings.to_lower(fmt.tprintf("%s %s %s", c.card.family, c.card.given, display(c)), allocator)
	}
	return strings.to_lower(display(c), allocator)
}

// initial is the section letter a list puts a contact under.
initial :: proc(c: Contact) -> string {
	k := sort_key(c)
	for r in k {
		if (r >= 'a' && r <= 'z') {
			return fmt.tprintf("%c", r - 32)
		}
		if r > 127 {
			return strings.to_upper(fmt.tprintf("%c", r), context.temp_allocator)
		}
		return "#"
	}
	return "#"
}

matches :: proc(c: Contact, q: string) -> bool {
	if q == "" {
		return true
	}
	n := strings.to_lower(q, context.temp_allocator)
	hay := []string{display(c), c.card.org, c.card.title, c.card.nickname}
	for h in hay {
		if strings.contains(strings.to_lower(h, context.temp_allocator), n) {
			return true
		}
	}
	for e in c.card.emails {
		if strings.contains(strings.to_lower(e.value, context.temp_allocator), n) {
			return true
		}
	}
	digits := vcard.normalise_phone(q, context.temp_allocator)
	for p in c.card.phones {
		if len(digits) >= 3 && strings.contains(vcard.normalise_phone(p.value, context.temp_allocator), digits) {
			return true
		}
	}
	return false
}

member_uid :: proc(m: string) -> string {
	v := strings.trim_space(m)
	if strings.has_prefix(strings.to_lower(v, context.temp_allocator), "urn:uuid:") {
		return v[9:]
	}
	return v
}

// groups_of lists the group contacts (indices) in a book that name `uid`.
groups_of :: proc(st: ^Store, book: int, uid: string, allocator := context.temp_allocator) -> []int {
	out := make([dynamic]int, 0, 2, allocator)
	for g, i in st.contacts {
		if g.book != book || !is_group(g) {
			continue
		}
		for m in g.card.members {
			if member_uid(m) == uid {
				append(&out, i)
				break
			}
		}
	}
	return out[:]
}

in_group :: proc(st: ^Store, group: int, c: Contact) -> bool {
	g := st.contacts[group]
	if g.book != c.book {
		return false
	}
	for m in g.card.members {
		if member_uid(m) == c.card.uid {
			return true
		}
	}
	return false
}

find_uid :: proc(st: ^Store, uid: string) -> int {
	for c, i in st.contacts {
		if c.card.uid == uid {
			return i
		}
	}
	return -1
}

// Filter is what the list shows.
Filter :: struct {
	handle: string, // "" all identities
	book:   int, // -1 every book
	group:  int, // -1 no group filter
	query:  string,
}

// visible returns the individuals the filter admits, sorted.
visible :: proc(st: ^Store, f: Filter, allocator := context.temp_allocator) -> []int {
	out := make([dynamic]int, 0, len(st.contacts), allocator)
	for c, i in st.contacts {
		if is_group(c) {
			continue
		}
		if f.handle != "" && st.books[c.book].handle != f.handle {
			continue
		}
		if f.book >= 0 && c.book != f.book {
			continue
		}
		if f.group >= 0 && !in_group(st, f.group, c) {
			continue
		}
		if !matches(c, f.query) {
			continue
		}
		append(&out, i)
	}
	Sorter :: struct {
		st: ^Store,
	}
	keys := make([]string, len(st.contacts), context.temp_allocator)
	for i in out {
		keys[i] = sort_key(st.contacts[i])
	}
	g_sort_keys = keys
	slice.sort_by(out[:], proc(a, b: int) -> bool {return g_sort_keys[a] < g_sort_keys[b]})
	return out[:]
}

@(private = "file")
g_sort_keys: []string

// ---------------------------------------------------------------------------
// Writing
// ---------------------------------------------------------------------------

new_uid :: proc(allocator := context.allocator) -> string {
	context.random_generator = crypto.random_generator()
	id := uuid.generate_v4()
	return strings.to_lower(uuid.to_string(id, allocator), allocator)
}

// card_text writes a card in the version it came in (a 3.0 card from Apple
// stays 3.0 when edited here), 4.0 for new ones.
card_text :: proc(c: vcard.Card, allocator := context.allocator) -> string {
	v := c.version == "3.0" ? "3.0" : "4.0"
	return ical.write(vcard.to_component(c, v), allocator)
}

// save writes a card into a book (new when `index` is -1) and re-reads it,
// so what the model holds is exactly what will be uploaded. Returns the
// contact's index.
save :: proc(st: ^Store, book: int, card: vcard.Card, index := -1) -> (int, string) {
	context.allocator = store_alloc(st)
	if book < 0 || book >= len(st.books) {
		return -1, "no such address book"
	}
	if st.books[book].readonly {
		return -1, "this address book is shared with you read-only"
	}
	c := card
	if c.uid == "" {
		c.uid = new_uid()
	}
	text := card_text(c)
	comp, _, ok := ical.parse_one(text)
	if !ok {
		return -1, "the card could not be written"
	}
	name := index >= 0 ? st.contacts[index].name : strings.concatenate({safe_name(c.uid), ".vcf"})
	if l := st.books[book].local; l != nil {
		if !dc.local_write(l, name, text) {
			return -1, "could not write the local copy"
		}
	}
	entry := Contact{book = book, name = name, card = vcard.from_component(comp)}
	if index >= 0 {
		st.contacts[index] = entry
		return index, ""
	}
	append(&st.contacts, entry)
	return len(st.contacts) - 1, ""
}

safe_name :: proc(uid: string) -> string {
	sb := strings.builder_make()
	for ch in transmute([]u8)uid {
		switch ch {
		case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9', '-', '_', '.':
			strings.write_byte(&sb, ch)
		case:
			strings.write_byte(&sb, '_')
		}
	}
	return strings.to_string(sb)
}

// remove deletes a contact, and takes it out of its book's groups.
remove :: proc(st: ^Store, index: int) -> string {
	context.allocator = store_alloc(st)
	c := st.contacts[index]
	if st.books[c.book].readonly {
		return "this address book is shared with you read-only"
	}
	uid := c.card.uid
	book := c.book
	if l := st.books[book].local; l != nil {
		dc.local_delete(l, c.name)
	}
	ordered_remove(&st.contacts, index)
	if c.card.kind != "group" {
		for g, gi in st.contacts {
			if !is_group(g) || g.book != book {
				continue
			}
			kept := make([dynamic]string, 0, len(g.card.members))
			for m in g.card.members {
				if member_uid(m) != uid {
					append(&kept, m)
				}
			}
			if len(kept) != len(g.card.members) {
				card := g.card
				card.members = kept[:]
				save(st, book, card, gi)
			}
		}
	}
	return ""
}

// ---------------------------------------------------------------------------
// Groups
// ---------------------------------------------------------------------------

new_group :: proc(st: ^Store, book: int, name: string) -> (int, string) {
	return save(st, book, vcard.Card{fn = name, kind = "group", version = "4.0"})
}

rename_group :: proc(st: ^Store, group: int, name: string) -> string {
	card := st.contacts[group].card
	card.fn = name
	card.family = ""
	card.given = ""
	_, err := save(st, st.contacts[group].book, card, group)
	return err
}

// set_member adds or removes a contact from a group in the same book.
set_member :: proc(st: ^Store, group, contact: int, on: bool) -> string {
	context.allocator = store_alloc(st)
	g := st.contacts[group]
	c := st.contacts[contact]
	if g.book != c.book {
		return "a group holds contacts from its own address book"
	}
	members := make([dynamic]string, 0, len(g.card.members) + 1)
	has := false
	for m in g.card.members {
		if member_uid(m) == c.card.uid {
			has = true
			if !on {
				continue
			}
		}
		append(&members, m)
	}
	if on && !has {
		append(&members, strings.concatenate({"urn:uuid:", c.card.uid}))
	}
	if has == on {
		return ""
	}
	card := g.card
	card.members = members[:]
	_, err := save(st, g.book, card, group)
	return err
}

// ---------------------------------------------------------------------------
// Duplicates and merging
// ---------------------------------------------------------------------------

Dup :: struct {
	a, b:   int, // contact indices, a sorts first
	reason: string, // "email" | "phone" | "name"
}

duplicates :: proc(st: ^Store, f: Filter, allocator := context.temp_allocator) -> []Dup {
	out := make([dynamic]Dup, 0, 4, allocator)
	list := visible(st, Filter{handle = f.handle, book = f.book, group = -1})
	for i in 0 ..< len(list) {
		for j in i + 1 ..< len(list) {
			a := st.contacts[list[i]]
			b := st.contacts[list[j]]
			if a.book != b.book {
				continue
			}
			if r := dup_reason(a, b); r != "" {
				// Offer to keep the fuller card; a tie keeps the first.
				if richness(b.card) > richness(a.card) {
					append(&out, Dup{list[j], list[i], r})
				} else {
					append(&out, Dup{list[i], list[j], r})
				}
			}
		}
	}
	return out[:]
}

// richness counts what a card carries, to pick which of two to keep.
richness :: proc(c: vcard.Card) -> int {
	n := len(c.emails) + len(c.phones) + len(c.addresses) + len(c.urls)
	for f in ([]string{c.org, c.title, c.bday, c.note, c.nickname, c.photo}) {
		if f != "" {
			n += 1
		}
	}
	return n
}

dup_reason :: proc(a, b: Contact) -> string {
	for ea in a.card.emails {
		for eb in b.card.emails {
			if ea.value != "" && strings.equal_fold(strings.trim_space(ea.value), strings.trim_space(eb.value)) {
				return "email"
			}
		}
	}
	for pa in a.card.phones {
		na := vcard.normalise_phone(pa.value, context.temp_allocator)
		if len(na) < 5 {
			continue
		}
		for pb in b.card.phones {
			if na == vcard.normalise_phone(pb.value, context.temp_allocator) {
				return "phone"
			}
		}
	}
	if strings.equal_fold(strings.trim_space(display(a)), strings.trim_space(display(b))) {
		return "name"
	}
	return ""
}

// merged is `keep` with everything `drop` adds: the union of emails, phones,
// addresses, URLs and categories, empty fields filled, notes joined.
merged :: proc(keep, drop: vcard.Card) -> vcard.Card {
	m := keep
	fill :: proc(dst: ^string, src: string) {
		if strings.trim_space(dst^) == "" {
			dst^ = src
		}
	}
	fill(&m.fn, drop.fn)
	fill(&m.given, drop.given)
	fill(&m.family, drop.family)
	fill(&m.additional, drop.additional)
	fill(&m.prefix, drop.prefix)
	fill(&m.suffix, drop.suffix)
	fill(&m.nickname, drop.nickname)
	fill(&m.org, drop.org)
	fill(&m.title, drop.title)
	fill(&m.bday, drop.bday)
	fill(&m.photo, drop.photo)
	if drop.note != "" && drop.note != keep.note {
		m.note = keep.note == "" ? drop.note : strings.concatenate({keep.note, "\n\n", drop.note})
	}
	emails := make([dynamic]vcard.Typed, 0, len(keep.emails) + len(drop.emails))
	append(&emails, ..keep.emails)
	for e in drop.emails {
		dup := false
		for x in emails {
			if strings.equal_fold(x.value, e.value) {
				dup = true
			}
		}
		if !dup {
			append(&emails, e)
		}
	}
	m.emails = emails[:]
	phones := make([dynamic]vcard.Typed, 0, len(keep.phones) + len(drop.phones))
	append(&phones, ..keep.phones)
	for p in drop.phones {
		dup := false
		for x in phones {
			if vcard.normalise_phone(x.value, context.temp_allocator) == vcard.normalise_phone(p.value, context.temp_allocator) {
				dup = true
			}
		}
		if !dup {
			append(&phones, p)
		}
	}
	m.phones = phones[:]
	urls := make([dynamic]vcard.Typed, 0, len(keep.urls) + len(drop.urls))
	append(&urls, ..keep.urls)
	for u in drop.urls {
		dup := false
		for x in urls {
			if x.value == u.value {
				dup = true
			}
		}
		if !dup {
			append(&urls, u)
		}
	}
	m.urls = urls[:]
	addrs := make([dynamic]vcard.Address, 0, len(keep.addresses) + len(drop.addresses))
	append(&addrs, ..keep.addresses)
	for a in drop.addresses {
		dup := false
		for x in addrs {
			if strings.equal_fold(x.street, a.street) && strings.equal_fold(x.locality, a.locality) {
				dup = true
			}
		}
		if !dup {
			append(&addrs, a)
		}
	}
	m.addresses = addrs[:]
	cats := make([dynamic]string, 0, len(keep.categories) + len(drop.categories))
	append(&cats, ..keep.categories)
	for cat in drop.categories {
		if !slice.contains(cats[:], cat) {
			append(&cats, cat)
		}
	}
	m.categories = cats[:]
	return m
}

// merge folds contact `drop` into `keep` (same book): the survivor keeps its
// UID, groups that named `drop` name `keep` instead, `drop` is deleted.
merge :: proc(st: ^Store, keep, drop: int) -> string {
	context.allocator = store_alloc(st)
	k := st.contacts[keep]
	d := st.contacts[drop]
	if k.book != d.book {
		return "only contacts in the same address book merge"
	}
	if st.books[k.book].readonly {
		return "this address book is shared with you read-only"
	}
	if _, err := save(st, k.book, merged(k.card, d.card), keep); err != "" {
		return err
	}
	keep_uid := k.card.uid
	drop_uid := d.card.uid
	for g, gi in st.contacts {
		if !is_group(g) || g.book != k.book {
			continue
		}
		changed := false
		has_keep := false
		members := make([dynamic]string, 0, len(g.card.members))
		for mm in g.card.members {
			u := member_uid(mm)
			if u == drop_uid {
				changed = true
				continue
			}
			if u == keep_uid {
				has_keep = true
			}
			append(&members, mm)
		}
		if changed {
			if !has_keep {
				append(&members, strings.concatenate({"urn:uuid:", keep_uid}))
			}
			card := g.card
			card.members = members[:]
			save(st, g.book, card, gi)
		}
	}
	// The drop's index is still valid: saves above replaced in place.
	idx := find_uid(st, drop_uid)
	if idx >= 0 {
		if l := st.books[d.book].local; l != nil {
			dc.local_delete(l, st.contacts[idx].name)
		}
		ordered_remove(&st.contacts, idx)
	}
	return ""
}

// ---------------------------------------------------------------------------
// Import and export
// ---------------------------------------------------------------------------

Import_Report :: struct {
	added, updated, skipped: int,
}

// import_vcf reads a .vcf (any mix of 3.0 and 4.0) into a book. A card whose
// UID is already in the book is merged into it; one with no UID gets one.
import_vcf :: proc(st: ^Store, book: int, text: string) -> (r: Import_Report, err: string) {
	context.allocator = store_alloc(st)
	if book < 0 || book >= len(st.books) {
		return r, "no such address book"
	}
	if st.books[book].readonly {
		return r, "this address book is shared with you read-only"
	}
	cards, ok := vcard.parse_all(text)
	if !ok {
		return r, "the file is not vCard"
	}
	for comp in cards {
		if !strings.contains(ical.value(comp, "VERSION"), "3.0") && !strings.contains(ical.value(comp, "VERSION"), "4.0") {
			r.skipped += 1
			continue
		}
		card := vcard.from_component(comp)
		if card.uid == "" {
			card.uid = new_uid()
		}
		existing := -1
		for c, i in st.contacts {
			if c.book == book && c.card.uid == card.uid {
				existing = i
			}
		}
		if existing >= 0 {
			if _, e := save(st, book, merged(st.contacts[existing].card, card), existing); e != "" {
				r.skipped += 1
			} else {
				r.updated += 1
			}
			continue
		}
		if _, e := save(st, book, card); e != "" {
			r.skipped += 1
		} else {
			r.added += 1
		}
	}
	return r, ""
}

// export_vcf writes contacts (and groups) as one .vcf.
export_vcf :: proc(st: ^Store, indices: []int, version := "4.0", allocator := context.allocator) -> string {
	sb := strings.builder_make(allocator)
	for i in indices {
		c := st.contacts[i]
		strings.write_string(&sb, ical.write(vcard.to_component(c.card, version), context.temp_allocator))
	}
	return strings.to_string(sb)
}

// book_label is what the sidebar and the CLI call a book.
book_label :: proc(st: ^Store, b: int) -> string {
	bk := st.books[b]
	name := bk.remote.display_name != "" ? bk.remote.display_name : bk.remote.seg
	return name
}

// find_book resolves "handle/seg", "seg" (first match in scope) or "".
find_book :: proc(st: ^Store, spec: string, handle := "") -> int {
	if spec == "" {
		for b, i in st.books {
			if (handle == "" || b.handle == handle) && !b.readonly && b.remote.access == "owner" {
				return i
			}
		}
		return -1
	}
	h := handle
	seg := spec
	if slash := strings.index_byte(spec, '/'); slash >= 0 {
		h = spec[:slash]
		seg = spec[slash + 1:]
	}
	for b, i in st.books {
		if (h == "" || b.handle == h) && (b.remote.seg == seg || book_label(st, i) == seg) {
			return i
		}
	}
	return -1
}
