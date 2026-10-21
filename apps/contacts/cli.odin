// `contacts <verb>`: the command line over the same model the window uses.
//
// Scope follows docs/PALM-CLI.md: PALM_IDENTITY selects the session scoped to
// one identity (the server then lists nothing else), and --identity narrows
// an unscoped session to one identity. Naming a book of another identity
// from inside a scope is a refusal, exit 5.
package main

import "core:fmt"
import "core:os"
import "core:strings"
import ck "../cloudkit"
import vcard "../../cloud/dav/vcard"
import dc "../../cloud/dav/client"
import kit "kit:."

@(private = "file")
CONTACT_FIELDS :: []kit.Field {
	{name = "uid", kind = .String},
	{name = "name", kind = .String},
	{name = "identity", kind = .String},
	{name = "book", kind = .String},
	{name = "org", kind = .String, opt = true},
	{name = "emails", kind = .Array, of = {{kind = .String}}},
	{name = "phones", kind = .Array, of = {{kind = .String}}},
}

@(private = "file")
COMMANDS := []kit.Command {
	{
		verb = "signin",
		summary = "sign this machine in (the same session Accounts and Calendar use)",
		effect = .Mutate,
		args = {{name = "email", kind = .String, required = true}},
		flags = {
			{name = "password", kind = .String, secret = true, help = "development stacks only; prefer --password-file"},
			{name = "password-file", kind = .Path, help = "a file holding the password"},
		},
		out = {{name = "email", kind = .String}},
		examples = {"contacts signin alex@example.org --password-file ~/.pw"},
		run = cmd_signin,
	},
	{
		verb = "books",
		summary = "the address books every identity in scope reaches, own and shared",
		effect = .Read,
		out = {{name = "books", kind = .Array, of = {
			{name = "identity", kind = .String},
			{name = "book", kind = .String, help = "<identity>/<segment>, what --book takes"},
			{name = "name", kind = .String},
			{name = "access", kind = .String, help = "owner | read | read-write"},
			{name = "owner", kind = .String},
			{name = "contacts", kind = .Int},
			{name = "groups", kind = .Int},
		}}},
		examples = {"contacts books --json", "PALM_IDENTITY=work contacts books"},
		run = cmd_books,
	},
	{
		verb = "list",
		summary = "contacts, sorted by name",
		effect = .Read,
		flags = {
			{name = "book", kind = .String, help = "<identity>/<segment>"},
			{name = "group", kind = .String, help = "a group's name or UID"},
			{name = "search", kind = .String, help = "name, email, phone or organisation"},
		},
		out = {{name = "contacts", kind = .Array, of = CONTACT_FIELDS}, {name = "count", kind = .Int}},
		examples = {"contacts list --json", "contacts list --search grace", "contacts list --identity alice-work"},
		run = cmd_list,
	},
	{
		verb = "show",
		summary = "one contact, every field, and the vCard",
		effect = .Read,
		args = {{name = "uid", kind = .String, required = true}},
		out = {
			{name = "uid", kind = .String}, {name = "name", kind = .String}, {name = "identity", kind = .String},
			{name = "book", kind = .String}, {name = "groups", kind = .Array, of = {{kind = .String}}},
			{name = "vcard", kind = .String},
		},
		examples = {"contacts show 3b0c… --json"},
		run = cmd_show,
	},
	{
		verb = "add",
		summary = "a new contact",
		effect = .Mutate,
		flags = {
			{name = "name", kind = .String, help = "full name; the last word is the family name", required = true},
			{name = "email", kind = .String, help = "comma-separated"},
			{name = "phone", kind = .String, help = "comma-separated"},
			{name = "org", kind = .String},
			{name = "title", kind = .String},
			{name = "note", kind = .String},
			{name = "book", kind = .String, help = "<identity>/<segment>; default: the first own book in scope"},
		},
		out = CONTACT_FIELDS,
		examples = {"contacts add --name \"Ada Lovelace\" --email ada@example.org --book alice/default"},
		run = cmd_add,
	},
	{
		verb = "edit",
		summary = "change fields of a contact; unknown vCard properties are kept",
		effect = .Mutate,
		args = {{name = "uid", kind = .String, required = true}},
		flags = {
			{name = "name", kind = .String},
			{name = "org", kind = .String},
			{name = "title", kind = .String},
			{name = "note", kind = .String},
			{name = "birthday", kind = .String, help = "YYYY-MM-DD or --MM-DD"},
			{name = "add-email", kind = .String},
			{name = "remove-email", kind = .String},
			{name = "add-phone", kind = .String},
			{name = "remove-phone", kind = .String},
			{name = "type", kind = .Enum, values = {"work", "home", "cell", "other"}, help = "type for --add-email / --add-phone", def = "other"},
		},
		out = CONTACT_FIELDS,
		examples = {"contacts edit 3b0c… --add-phone \"+44 20 7946 0000\" --type cell"},
		run = cmd_edit,
	},
	{
		verb = "delete",
		summary = "delete a contact (and take it out of its groups)",
		effect = .Destructive,
		args = {{name = "uid", kind = .String, required = true}},
		out = {{name = "deleted", kind = .String}},
		examples = {"contacts delete 3b0c… --yes"},
		run = cmd_delete,
	},
	{
		verb = "groups",
		summary = "the groups (vCard KIND:group) in scope",
		effect = .Read,
		flags = {{name = "book", kind = .String}},
		out = {{name = "groups", kind = .Array, of = {
			{name = "uid", kind = .String}, {name = "name", kind = .String}, {name = "identity", kind = .String},
			{name = "book", kind = .String}, {name = "members", kind = .Array, of = {{kind = .String}}},
		}}},
		examples = {"contacts groups --json"},
		run = cmd_groups,
	},
	{
		verb = "group",
		summary = "create or rename a group, or add or remove a member",
		effect = .Mutate,
		args = {
			{name = "action", kind = .Enum, values = {"create", "rename", "add", "remove"}, required = true},
			{name = "group", kind = .String, required = true, help = "create: the new name; otherwise the group's name or UID"},
			{name = "value", kind = .String, help = "rename: the new name; add/remove: the contact's UID"},
		},
		flags = {{name = "book", kind = .String, help = "create: where; default the first own book in scope"}},
		out = {{name = "uid", kind = .String}, {name = "name", kind = .String}, {name = "members", kind = .Array, of = {{kind = .String}}}},
		examples = {"contacts group create \"Climbing club\" --book alice/default", "contacts group add \"Climbing club\" 3b0c…"},
		run = cmd_group,
	},
	{
		verb = "group-delete",
		summary = "delete a group (its members stay)",
		effect = .Destructive,
		args = {{name = "group", kind = .String, required = true}},
		out = {{name = "deleted", kind = .String}},
		examples = {"contacts group-delete \"Climbing club\" --yes"},
		run = cmd_group_delete,
	},
	{
		verb = "duplicates",
		summary = "pairs that look like the same person: same email, phone or name, in one book",
		effect = .Read,
		flags = {{name = "book", kind = .String}},
		out = {{name = "pairs", kind = .Array, of = {
			{name = "keep", kind = .String}, {name = "drop", kind = .String},
			{name = "keep_name", kind = .String}, {name = "drop_name", kind = .String},
			{name = "reason", kind = .String}, {name = "book", kind = .String},
		}}},
		examples = {"contacts duplicates --json"},
		run = cmd_duplicates,
	},
	{
		verb = "merge",
		summary = "fold DROP into KEEP: union the fields, repoint groups, delete DROP",
		effect = .Destructive,
		args = {{name = "keep", kind = .String, required = true}, {name = "drop", kind = .String, required = true}},
		out = CONTACT_FIELDS,
		examples = {"contacts merge 3b0c… 9f1e… --yes"},
		run = cmd_merge,
	},
	{
		verb = "import",
		summary = "read a .vcf (vCard 3.0 and 4.0) into an address book",
		effect = .Mutate,
		args = {{name = "file", kind = .Path, required = true}},
		flags = {{name = "book", kind = .String}},
		out = {{name = "added", kind = .Int}, {name = "updated", kind = .Int}, {name = "skipped", kind = .Int}, {name = "book", kind = .String}},
		examples = {"contacts import ~/Downloads/cards.vcf --book alice/default"},
		run = cmd_import,
	},
	{
		verb = "export",
		summary = "write contacts as .vcf",
		effect = .Read,
		flags = {
			{name = "book", kind = .String},
			{name = "group", kind = .String},
			{name = "out", kind = .Path, help = "a file; standard output when absent"},
			{name = "version", kind = .Enum, values = {"4.0", "3.0"}, def = "4.0"},
		},
		out = {{name = "count", kind = .Int}, {name = "out", kind = .String}},
		examples = {"contacts export --book alice/default --out alice.vcf", "contacts export --version 3.0 --out apple.vcf"},
		run = cmd_export,
	},
	{
		verb = "sync",
		summary = "push local edits and pull server changes, every book in scope",
		effect = .Idempotent,
		out = {
			{name = "pushed", kind = .Int}, {name = "pulled", kind = .Int}, {name = "removed", kind = .Int},
			{name = "conflicts", kind = .Int}, {name = "failed", kind = .Int},
		},
		examples = {"contacts sync --json"},
		run = cmd_sync,
	},
}

@(private = "file")
g_surface: kit.Surface

surface :: proc() -> ^kit.Surface {
	if g_surface.noun == "" {
		g_surface = kit.Surface {
			noun     = "contacts",
			summary  = "address books per identity, over CardDAV",
			gui      = true,
			selftest = run_selftest,
			notes    = SURFACE_NOTES,
			commands = COMMANDS,
		}
	}
	return &g_surface
}

@(private = "file")
SURFACE_NOTES :: `The account is cloudkit's ($PALM_CLOUD_URL, tokens in ~/.local/share/palm/cloud);
the CardDAV server is $PALM_DAV_URL (default http://127.0.0.1:59580); local copies
live in ~/.local/share/palm/dav (or $PALM_DAV_CACHE) and work offline.
Every mutating verb writes the local copy and then syncs.`

// ---------------------------------------------------------------------------
// Shared prologue
// ---------------------------------------------------------------------------

@(private = "file")
open_store :: proc(c: ^kit.Call, want_session := true) -> (st: ^Store, code: int) {
	a, err := dc.open("contacts")
	if !dc.ok(err) {
		return nil, kit.cli_fail(c, kit.EXIT_USAGE, err.message)
	}
	st = store_make()
	st.acct = a
	if want_session && !dc.signed_in(a) {
		return st, kit.cli_fail(c, kit.EXIT_UNAVAILABLE, "not signed in: run `contacts signin EMAIL` or sign in with Accounts")
	}
	only := ""
	if os.get_env("PALM_IDENTITY", context.temp_allocator) == "" {
		only = c.identity
	}
	// Pull before answering, so the CLI reports what the server has now;
	// offline, the local copies answer.
	load(st, only, sync_first = true)
	if len(st.idents) == 0 {
		if c.identity != "" {
			code = kit.cli_fail(c, kit.EXIT_OUT_OF_SCOPE, fmt.tprintf("%q is not an identity of this account", c.identity))
			return st, code
		}
		return st, kit.cli_fail(c, kit.EXIT_UNAVAILABLE, st.err != "" ? st.err : "no identities (offline, and nothing cached)")
	}
	if !st.online {
		kit.cli_note(c, "contacts: %s — using the local copies", st.err)
	}
	return st, kit.EXIT_OK
}

// book_arg resolves --book, refusing (exit 5) a book of an identity outside
// the scope in force.
@(private = "file")
book_arg :: proc(c: ^kit.Call, st: ^Store, flag := "book") -> (int, int) {
	spec := kit.cli_str(c, flag)
	if slash := strings.index_byte(spec, '/'); slash > 0 {
		h := spec[:slash]
		if ident_of(st, h) == nil {
			code := kit.cli_fail(c, kit.EXIT_OUT_OF_SCOPE, fmt.tprintf("%q is not in scope", h))
			kit.cli_err_field(c, "identity", c.identity == "" ? "unscoped" : c.identity)
			kit.cli_err_field(c, "requested", h)
			return -1, code
		}
	}
	b := find_book(st, spec)
	if b < 0 {
		return -1, kit.cli_fail(c, kit.EXIT_NOT_FOUND, spec == "" ? "no address book in scope" : fmt.tprintf("no address book %q", spec))
	}
	return b, kit.EXIT_OK
}

@(private = "file")
book_id :: proc(st: ^Store, b: int) -> string {
	return fmt.tprintf("%s/%s", st.books[b].handle, st.books[b].remote.seg)
}

@(private = "file")
contact_json :: proc(st: ^Store, i: int) -> ^kit.Json {
	c := st.contacts[i]
	o := kit.jobj()
	kit.jset_str(o, "uid", c.card.uid)
	kit.jset_str(o, "name", display(c))
	kit.jset_str(o, "identity", st.books[c.book].handle)
	kit.jset_str(o, "book", book_id(st, c.book))
	if c.card.org != "" {
		kit.jset_str(o, "org", c.card.org)
	}
	em := kit.jarr()
	for e in c.card.emails {
		kit.jpush(em, kit.jstr(e.value))
	}
	kit.jset(o, "emails", em)
	ph := kit.jarr()
	for p in c.card.phones {
		kit.jpush(ph, kit.jstr(p.value))
	}
	kit.jset(o, "phones", ph)
	return o
}

@(private = "file")
fill_contact :: proc(c: ^kit.Call, st: ^Store, i: int) {
	src := contact_json(st, i)
	for k, n in src.keys {
		kit.jset(c.out, k, src.items[n])
	}
}

@(private = "file")
find_contact :: proc(c: ^kit.Call, st: ^Store, uid: string) -> (int, int) {
	for x, i in st.contacts {
		if x.card.uid == uid || strings.has_prefix(x.card.uid, uid) && len(uid) >= 6 {
			if is_group(x) {
				continue
			}
			return i, kit.EXIT_OK
		}
	}
	return -1, kit.cli_fail(c, kit.EXIT_NOT_FOUND, fmt.tprintf("no contact %q in scope", uid))
}

@(private = "file")
find_group :: proc(st: ^Store, key: string) -> int {
	for x, i in st.contacts {
		if is_group(x) && (x.card.uid == key || strings.equal_fold(display(x), key)) {
			return i
		}
	}
	return -1
}

@(private = "file")
finish_write :: proc(c: ^kit.Call, st: ^Store) {
	r := sync_all(st)
	if r.failed > 0 {
		kit.cli_note(c, "contacts: saved locally; sync failed (%s) — `contacts sync` will retry", st.err)
	}
}

@(private = "file")
split_list :: proc(s: string) -> []string {
	out := make([dynamic]string, 0, 2)
	for p in strings.split(s, ",") {
		if t := strings.trim_space(p); t != "" {
			append(&out, t)
		}
	}
	return out[:]
}

@(private = "file")
split_name :: proc(card: ^vcard.Card, full: string) {
	n := strings.trim_space(full)
	card.fn = n
	if sp := strings.last_index_byte(n, ' '); sp > 0 {
		card.given = strings.trim_space(n[:sp])
		card.family = n[sp + 1:]
	} else {
		card.given = n
		card.family = ""
	}
}

// ---------------------------------------------------------------------------
// Verbs
// ---------------------------------------------------------------------------

@(private = "file")
cmd_signin :: proc(c: ^kit.Call) -> int {
	a, err := dc.open("contacts")
	if !dc.ok(err) {
		return kit.cli_fail(c, kit.EXIT_USAGE, err.message)
	}
	pw := kit.cli_str(c, "password")
	if f := kit.cli_str(c, "password-file"); f != "" {
		data, rerr := os.read_entire_file_from_path(f, context.temp_allocator)
		if rerr != nil {
			return kit.cli_fail(c, kit.EXIT_NOT_FOUND, "cannot read the password file")
		}
		pw = strings.trim_right(string(data), "\r\n")
	}
	if pw == "" {
		pw = os.get_env("PALM_CLOUD_PASSWORD", context.temp_allocator)
	}
	if pw == "" {
		return kit.cli_fail(c, kit.EXIT_USAGE, "a password is needed: --password-file, PALM_CLOUD_PASSWORD or --password")
	}
	if c.dry_run {
		kit.jset_str(c.out, "email", kit.cli_str(c, "email"))
		return kit.EXIT_OK
	}
	if e := ck.sign_in(a.cloud, kit.cli_str(c, "email"), pw); !ck.ok(e) {
		code := e.kind == .Unavailable ? kit.EXIT_UNAVAILABLE : kit.EXIT_FAILED
		return kit.cli_fail(c, code, e.message)
	}
	kit.jset_str(c.out, "email", kit.cli_str(c, "email"))
	return kit.EXIT_OK
}

@(private = "file")
cmd_books :: proc(c: ^kit.Call) -> int {
	st, code := open_store(c)
	if code != kit.EXIT_OK {
		return code
	}
	arr := kit.jarr()
	for b, i in st.books {
		people, groups := 0, 0
		for x in st.contacts {
			if x.book == i {
				if is_group(x) {
					groups += 1
				} else {
					people += 1
				}
			}
		}
		o := kit.jobj()
		kit.jset_str(o, "identity", b.handle)
		kit.jset_str(o, "book", book_id(st, i))
		kit.jset_str(o, "name", book_label(st, i))
		kit.jset_str(o, "access", b.remote.access)
		kit.jset_str(o, "owner", b.remote.owner)
		kit.jset_int(o, "contacts", people)
		kit.jset_int(o, "groups", groups)
		kit.jpush(arr, o)
	}
	kit.jset(c.out, "books", arr)
	return kit.EXIT_OK
}

@(private = "file")
cmd_list :: proc(c: ^kit.Call) -> int {
	st, code := open_store(c)
	if code != kit.EXIT_OK {
		return code
	}
	f := Filter{book = -1, group = -1, query = kit.cli_str(c, "search")}
	if kit.cli_has(c, "book") {
		b, bc := book_arg(c, st)
		if bc != kit.EXIT_OK {
			return bc
		}
		f.book = b
	}
	if g := kit.cli_str(c, "group"); g != "" {
		f.group = find_group(st, g)
		if f.group < 0 {
			return kit.cli_fail(c, kit.EXIT_NOT_FOUND, fmt.tprintf("no group %q", g))
		}
	}
	arr := kit.jarr()
	list := visible(st, f)
	for i in list {
		kit.jpush(arr, contact_json(st, i))
	}
	kit.jset(c.out, "contacts", arr)
	kit.jset_int(c.out, "count", len(list))
	return kit.EXIT_OK
}

@(private = "file")
cmd_show :: proc(c: ^kit.Call) -> int {
	st, code := open_store(c)
	if code != kit.EXIT_OK {
		return code
	}
	i, fc := find_contact(c, st, kit.cli_str(c, "uid"))
	if fc != kit.EXIT_OK {
		return fc
	}
	x := st.contacts[i]
	kit.jset_str(c.out, "uid", x.card.uid)
	kit.jset_str(c.out, "name", display(x))
	kit.jset_str(c.out, "identity", st.books[x.book].handle)
	kit.jset_str(c.out, "book", book_id(st, x.book))
	gs := kit.jarr()
	for g in groups_of(st, x.book, x.card.uid) {
		kit.jpush(gs, kit.jstr(display(st.contacts[g])))
	}
	kit.jset(c.out, "groups", gs)
	kit.jset_str(c.out, "vcard", card_text(x.card, context.temp_allocator))
	return kit.EXIT_OK
}

@(private = "file")
cmd_add :: proc(c: ^kit.Call) -> int {
	st, code := open_store(c)
	if code != kit.EXIT_OK {
		return code
	}
	b, bc := book_arg(c, st)
	if bc != kit.EXIT_OK {
		return bc
	}
	card := vcard.Card{version = "4.0", kind = "individual"}
	split_name(&card, kit.cli_str(c, "name"))
	card.org = kit.cli_str(c, "org")
	card.title = kit.cli_str(c, "title")
	card.note = kit.cli_str(c, "note")
	emails := make([dynamic]vcard.Typed)
	for e in split_list(kit.cli_str(c, "email")) {
		append(&emails, vcard.Typed{value = e})
	}
	phones := make([dynamic]vcard.Typed)
	for p in split_list(kit.cli_str(c, "phone")) {
		append(&phones, vcard.Typed{value = p, types = []string{"cell"}})
	}
	card.emails = emails[:]
	card.phones = phones[:]
	if c.dry_run {
		kit.jset_str(c.out, "name", card.fn)
		kit.jset_str(c.out, "book", book_id(st, b))
		return kit.EXIT_OK
	}
	i, err := save(st, b, card)
	if err != "" {
		return kit.cli_fail(c, kit.EXIT_FAILED, err)
	}
	finish_write(c, st)
	fill_contact(c, st, i)
	return kit.EXIT_OK
}

@(private = "file")
cmd_edit :: proc(c: ^kit.Call) -> int {
	st, code := open_store(c)
	if code != kit.EXIT_OK {
		return code
	}
	i, fc := find_contact(c, st, kit.cli_str(c, "uid"))
	if fc != kit.EXIT_OK {
		return fc
	}
	card := st.contacts[i].card
	if kit.cli_has(c, "name") {
		split_name(&card, kit.cli_str(c, "name"))
	}
	if kit.cli_has(c, "org") {
		card.org = kit.cli_str(c, "org")
	}
	if kit.cli_has(c, "title") {
		card.title = kit.cli_str(c, "title")
	}
	if kit.cli_has(c, "note") {
		card.note = kit.cli_str(c, "note")
	}
	if kit.cli_has(c, "birthday") {
		card.bday = strings.trim_space(kit.cli_str(c, "birthday"))
	}
	ty := kit.cli_str(c, "type")
	types := ty == "other" ? []string{} : []string{ty}
	emails := make([dynamic]vcard.Typed)
	for e in card.emails {
		if !strings.equal_fold(e.value, kit.cli_str(c, "remove-email")) {
			append(&emails, e)
		}
	}
	if e := kit.cli_str(c, "add-email"); e != "" {
		append(&emails, vcard.Typed{value = e, types = types})
	}
	phones := make([dynamic]vcard.Typed)
	rm := vcard.normalise_phone(kit.cli_str(c, "remove-phone"))
	for p in card.phones {
		if rm == "" || vcard.normalise_phone(p.value) != rm {
			append(&phones, p)
		}
	}
	if p := kit.cli_str(c, "add-phone"); p != "" {
		append(&phones, vcard.Typed{value = p, types = types})
	}
	card.emails = emails[:]
	card.phones = phones[:]
	if c.dry_run {
		fill_contact(c, st, i)
		return kit.EXIT_OK
	}
	if _, err := save(st, st.contacts[i].book, card, i); err != "" {
		return kit.cli_fail(c, kit.EXIT_FAILED, err)
	}
	finish_write(c, st)
	fill_contact(c, st, i)
	return kit.EXIT_OK
}

@(private = "file")
cmd_delete :: proc(c: ^kit.Call) -> int {
	st, code := open_store(c)
	if code != kit.EXIT_OK {
		return code
	}
	i, fc := find_contact(c, st, kit.cli_str(c, "uid"))
	if fc != kit.EXIT_OK {
		return fc
	}
	uid := strings.clone(st.contacts[i].card.uid, context.temp_allocator)
	kit.jset_str(c.out, "deleted", uid)
	if c.dry_run {
		return kit.EXIT_OK
	}
	if err := remove(st, i); err != "" {
		return kit.cli_fail(c, kit.EXIT_FAILED, err)
	}
	finish_write(c, st)
	return kit.EXIT_OK
}

@(private = "file")
group_json :: proc(st: ^Store, g: int) -> ^kit.Json {
	x := st.contacts[g]
	o := kit.jobj()
	kit.jset_str(o, "uid", x.card.uid)
	kit.jset_str(o, "name", display(x))
	kit.jset_str(o, "identity", st.books[x.book].handle)
	kit.jset_str(o, "book", book_id(st, x.book))
	ms := kit.jarr()
	for m in x.card.members {
		u := member_uid(m)
		if k := find_uid(st, u); k >= 0 {
			kit.jpush(ms, kit.jstr(display(st.contacts[k])))
		} else {
			kit.jpush(ms, kit.jstr(u))
		}
	}
	kit.jset(o, "members", ms)
	return o
}

@(private = "file")
cmd_groups :: proc(c: ^kit.Call) -> int {
	st, code := open_store(c)
	if code != kit.EXIT_OK {
		return code
	}
	book := -1
	if kit.cli_has(c, "book") {
		b, bc := book_arg(c, st)
		if bc != kit.EXIT_OK {
			return bc
		}
		book = b
	}
	arr := kit.jarr()
	for x, i in st.contacts {
		if is_group(x) && (book < 0 || x.book == book) {
			kit.jpush(arr, group_json(st, i))
		}
	}
	kit.jset(c.out, "groups", arr)
	return kit.EXIT_OK
}

@(private = "file")
cmd_group :: proc(c: ^kit.Call) -> int {
	st, code := open_store(c)
	if code != kit.EXIT_OK {
		return code
	}
	action := kit.cli_str(c, "action")
	key := kit.cli_str(c, "group")
	value := kit.cli_str(c, "value")
	g := -1
	switch action {
	case "create":
		b, bc := book_arg(c, st)
		if bc != kit.EXIT_OK {
			return bc
		}
		if c.dry_run {
			kit.jset_str(c.out, "name", key)
			return kit.EXIT_OK
		}
		idx, err := new_group(st, b, key)
		if err != "" {
			return kit.cli_fail(c, kit.EXIT_FAILED, err)
		}
		g = idx
	case "rename", "add", "remove":
		g = find_group(st, key)
		if g < 0 {
			return kit.cli_fail(c, kit.EXIT_NOT_FOUND, fmt.tprintf("no group %q", key))
		}
		if value == "" {
			return kit.cli_fail(c, kit.EXIT_USAGE, action == "rename" ? "rename needs the new name" : "give the contact's UID")
		}
		if c.dry_run {
			break
		}
		if action == "rename" {
			if err := rename_group(st, g, value); err != "" {
				return kit.cli_fail(c, kit.EXIT_FAILED, err)
			}
		} else {
			ci, fc := find_contact(c, st, value)
			if fc != kit.EXIT_OK {
				return fc
			}
			if err := set_member(st, g, ci, action == "add"); err != "" {
				return kit.cli_fail(c, kit.EXIT_FAILED, err)
			}
		}
	}
	if !c.dry_run {
		finish_write(c, st)
	}
	o := group_json(st, g)
	for k, n in o.keys {
		if k == "uid" || k == "name" || k == "members" {
			kit.jset(c.out, k, o.items[n])
		}
	}
	return kit.EXIT_OK
}

@(private = "file")
cmd_group_delete :: proc(c: ^kit.Call) -> int {
	st, code := open_store(c)
	if code != kit.EXIT_OK {
		return code
	}
	g := find_group(st, kit.cli_str(c, "group"))
	if g < 0 {
		return kit.cli_fail(c, kit.EXIT_NOT_FOUND, "no such group")
	}
	kit.jset_str(c.out, "deleted", st.contacts[g].card.uid)
	if c.dry_run {
		return kit.EXIT_OK
	}
	if err := remove(st, g); err != "" {
		return kit.cli_fail(c, kit.EXIT_FAILED, err)
	}
	finish_write(c, st)
	return kit.EXIT_OK
}

@(private = "file")
cmd_duplicates :: proc(c: ^kit.Call) -> int {
	st, code := open_store(c)
	if code != kit.EXIT_OK {
		return code
	}
	f := Filter{book = -1, group = -1}
	if kit.cli_has(c, "book") {
		b, bc := book_arg(c, st)
		if bc != kit.EXIT_OK {
			return bc
		}
		f.book = b
	}
	arr := kit.jarr()
	for d in duplicates(st, f) {
		o := kit.jobj()
		kit.jset_str(o, "keep", st.contacts[d.a].card.uid)
		kit.jset_str(o, "drop", st.contacts[d.b].card.uid)
		kit.jset_str(o, "keep_name", display(st.contacts[d.a]))
		kit.jset_str(o, "drop_name", display(st.contacts[d.b]))
		kit.jset_str(o, "reason", d.reason)
		kit.jset_str(o, "book", book_id(st, st.contacts[d.a].book))
		kit.jpush(arr, o)
	}
	kit.jset(c.out, "pairs", arr)
	return kit.EXIT_OK
}

@(private = "file")
cmd_merge :: proc(c: ^kit.Call) -> int {
	st, code := open_store(c)
	if code != kit.EXIT_OK {
		return code
	}
	k, kc := find_contact(c, st, kit.cli_str(c, "keep"))
	if kc != kit.EXIT_OK {
		return kc
	}
	d, dcode := find_contact(c, st, kit.cli_str(c, "drop"))
	if dcode != kit.EXIT_OK {
		return dcode
	}
	if k == d {
		return kit.cli_fail(c, kit.EXIT_USAGE, "a contact does not merge with itself")
	}
	keep_uid := strings.clone(st.contacts[k].card.uid, context.temp_allocator)
	if c.dry_run {
		fill_contact(c, st, k)
		return kit.EXIT_OK
	}
	if err := merge(st, k, d); err != "" {
		return kit.cli_fail(c, kit.EXIT_FAILED, err)
	}
	finish_write(c, st)
	fill_contact(c, st, find_uid(st, keep_uid))
	return kit.EXIT_OK
}

@(private = "file")
cmd_import :: proc(c: ^kit.Call) -> int {
	data, err := os.read_entire_file_from_path(kit.cli_str(c, "file"), context.temp_allocator)
	if err != nil {
		return kit.cli_fail(c, kit.EXIT_NOT_FOUND, "cannot read the file")
	}
	st, code := open_store(c)
	if code != kit.EXIT_OK {
		return code
	}
	b, bc := book_arg(c, st)
	if bc != kit.EXIT_OK {
		return bc
	}
	kit.jset_str(c.out, "book", book_id(st, b))
	if c.dry_run {
		cards, _ := vcard.parse_all(string(data))
		kit.jset_int(c.out, "added", len(cards))
		return kit.EXIT_OK
	}
	r, ierr := import_vcf(st, b, string(data))
	if ierr != "" {
		return kit.cli_fail(c, kit.EXIT_FAILED, ierr)
	}
	finish_write(c, st)
	kit.jset_int(c.out, "added", r.added)
	kit.jset_int(c.out, "updated", r.updated)
	kit.jset_int(c.out, "skipped", r.skipped)
	return kit.EXIT_OK
}

@(private = "file")
cmd_export :: proc(c: ^kit.Call) -> int {
	st, code := open_store(c)
	if code != kit.EXIT_OK {
		return code
	}
	book := -1
	if kit.cli_has(c, "book") {
		b, bc := book_arg(c, st)
		if bc != kit.EXIT_OK {
			return bc
		}
		book = b
	}
	group := -1
	if g := kit.cli_str(c, "group"); g != "" {
		group = find_group(st, g)
		if group < 0 {
			return kit.cli_fail(c, kit.EXIT_NOT_FOUND, fmt.tprintf("no group %q", g))
		}
	}
	idx := make([dynamic]int)
	append(&idx, ..visible(st, Filter{book = book, group = group}))
	if group < 0 {
		for x, i in st.contacts {
			if is_group(x) && (book < 0 || x.book == book) {
				append(&idx, i)
			}
		}
	}
	text := export_vcf(st, idx[:], kit.cli_str(c, "version"))
	out := kit.cli_str(c, "out")
	kit.jset_int(c.out, "count", len(idx))
	kit.jset_str(c.out, "out", out == "" ? "-" : out)
	if out == "" {
		if !c.json {
			fmt.print(text)
			c.out = kit.jobj() // the cards are the output
		}
		return kit.EXIT_OK
	}
	if os.write_entire_file(out, transmute([]u8)text) != nil {
		return kit.cli_fail(c, kit.EXIT_FAILED, "cannot write the file")
	}
	return kit.EXIT_OK
}

@(private = "file")
cmd_sync :: proc(c: ^kit.Call) -> int {
	st, code := open_store(c)
	if code != kit.EXIT_OK {
		return code
	}
	if !st.online {
		return kit.cli_fail(c, kit.EXIT_UNAVAILABLE, st.err)
	}
	r := Sync_Report{}
	if !c.dry_run {
		r = sync_all(st)
	}
	kit.jset_int(c.out, "pushed", r.pushed)
	kit.jset_int(c.out, "pulled", r.pulled)
	kit.jset_int(c.out, "removed", r.removed)
	kit.jset_int(c.out, "conflicts", r.conflicts)
	kit.jset_int(c.out, "failed", r.failed)
	if r.failed > 0 {
		return kit.cli_fail(c, kit.EXIT_FAILED, st.err)
	}
	return kit.EXIT_OK
}
