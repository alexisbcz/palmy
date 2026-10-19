// The window's state and every action it can take. The frame (ui.odin) only
// draws this; the keyboard (keys.odin) only calls these.
package main

import "core:fmt"
import "core:os"
import "core:strings"
import ck "../cloudkit"
import vcard "../../cloud/dav/vcard"
import dc "../../cloud/dav/client"
import kit "kit:."
import p "palmy:."

Pane :: enum u8 {
	Sidebar,
	List,
}

Mode :: enum u8 {
	Normal,
	Search,
	Edit,
	Confirm_Delete,
	Groups,
	Group_Name,
	Merge,
	Sign_In,
	Help,
	Import,
	Export,
}

Side_Kind :: enum u8 {
	All,
	Ident,
	Book,
	Group,
}

Side_Item :: struct {
	kind:   Side_Kind,
	handle: string,
	book:   int,
	group:  int,
}

Row_Kind :: enum u8 {
	Given,
	Family,
	Org,
	Title,
	Email,
	Phone,
	Birthday,
	Note,
}

ROW_LABELS := [Row_Kind]string {
	.Given    = "First name",
	.Family   = "Last name",
	.Org      = "Company",
	.Title    = "Job title",
	.Email    = "Email",
	.Phone    = "Phone",
	.Birthday = "Birthday",
	.Note     = "Note",
}

ROW_HINTS := [Row_Kind]string {
	.Given    = "Ada",
	.Family   = "Lovelace",
	.Org      = "Optional",
	.Title    = "Optional",
	.Email    = "name@example.org",
	.Phone    = "+44 20 7946 0000",
	.Birthday = "YYYY-MM-DD or --MM-DD",
	.Note     = "Optional",
}

TYPES := [?]string{"home", "work", "cell", "other"}

Form_Row :: struct {
	kind: Row_Kind,
	buf:  [dynamic]u8,
	type: string,
}

Form :: struct {
	editing: int, // contact index, -1 for new
	book:    int,
	rows:    [dynamic]Form_Row,
	field:   int,
	err:     string,
}

App_State :: struct {
	st:         ^Store,
	side:       [dynamic]Side_Item,
	side_sel:   int,
	list_sel:   int,
	sel_uid:    string, // follows the selection across reloads
	pane:       Pane,
	mode:       Mode,
	query:      [dynamic]u8,
	form:       Form,
	confirm:    bool,
	groups_sel: int,
	name_buf:   [dynamic]u8,
	name_group: int, // -1 new group, else the group being renamed
	merge_sel:  int,
	merge_swap: bool,
	email:      [dynamic]u8,
	password:   [dynamic]u8,
	signin_fld: int,
	signin_err: string,
	path:       [dynamic]u8,
	version3:   bool,
	swallow:    bool,
	toast:      string,
	toast_at:   f64,
	want_quit:  bool,
	synced_at:  string,
	fixture:    bool, // screenshots: no account, no sync
}

note :: proc(s: ^App_State, msg: string) {
	delete(s.toast)
	s.toast = strings.clone(msg)
	s.toast_at = 0
}

run_window :: proc() -> int {
	s := new(App_State)
	s.st = store_make()
	s.name_group = -1
	s.form.editing = -1
	a, err := dc.open("contacts")
	if !dc.ok(err) {
		fmt.eprintfln("contacts: %s", err.message)
		return 2
	}
	s.st.acct = a
	if dc.signed_in(a) {
		reload(s, true)
	} else {
		s.mode = .Sign_In
	}

	app, serr := kit.start(
		{
			title = "Contacts",
			app_id = "palm-contacts",
			width = 1240,
			height = 800,
			min_width = 900,
			min_height = 540,
			root_class = "w-full h-full bg-background text-foreground",
		},
		os.get_env("PALM_DARK", context.temp_allocator) == "1",
	)
	if serr != "" {
		fmt.eprintfln("contacts: %s", serr)
		return 1
	}
	defer p.destroy(app)
	for ui in p.frames(app) {
		keys(ui, s)
		frame(ui, s)
		if s.want_quit {
			p.quit_app(app)
		}
	}
	return 0
}

// reload reads the store again (syncing first when asked) and keeps the
// selection on the same contact.
reload :: proc(s: ^App_State, sync_first: bool) {
	load(s.st, "", sync_first)
	if sync_first && s.st.online {
		s.synced_at = "synced"
	} else if !s.st.online {
		s.synced_at = "offline"
	}
	reselect(s)
}

reselect :: proc(s: ^App_State) {
	if s.sel_uid == "" {
		return
	}
	list := current_list(s)
	for idx, k in list {
		if s.st.contacts[idx].card.uid == s.sel_uid {
			s.list_sel = k
			return
		}
	}
}

// do_sync pushes and pulls everything, then re-reads the cards.
do_sync :: proc(s: ^App_State) {
	if s.fixture || s.st.acct == nil {
		return
	}
	if !s.st.online {
		reload(s, true)
		note(s, s.st.online ? "Back online, synced" : "Still offline: edits are kept and will sync")
		return
	}
	r := sync_all(s.st)
	read_cards(s.st)
	reselect(s)
	if r.failed > 0 {
		s.synced_at = "sync failed"
		note(s, fmt.tprintf("Sync failed: %s", s.st.err))
		return
	}
	s.synced_at = "synced"
	if r.conflicts > 0 {
		note(s, fmt.tprintf("Synced; %d edit(s) lost to newer server copies (kept as .conflict)", r.conflicts))
	} else if r.pushed + r.pulled + r.removed > 0 {
		note(s, fmt.tprintf("Synced: %d up, %d down, %d removed", r.pushed, r.pulled, r.removed))
	}
}

// after_write syncs a change straight away when online.
after_write :: proc(s: ^App_State, msg: string) {
	note(s, msg)
	if !s.fixture && s.st.online {
		r := sync_all(s.st)
		read_cards(s.st)
		reselect(s)
		if r.failed > 0 {
			note(s, fmt.tprintf("%s — saved here; sync failed", msg))
		}
	}
}

// ---------------------------------------------------------------------------
// The sidebar and the list
// ---------------------------------------------------------------------------

build_side :: proc(s: ^App_State) {
	clear(&s.side)
	if len(s.st.idents) > 1 {
		append(&s.side, Side_Item{kind = .All, book = -1, group = -1})
	}
	for id in s.st.idents {
		append(&s.side, Side_Item{kind = .Ident, handle = id.handle, book = -1, group = -1})
		for b, bi in s.st.books {
			if b.handle != id.handle {
				continue
			}
			append(&s.side, Side_Item{kind = .Book, handle = id.handle, book = bi, group = -1})
			for c, ci in s.st.contacts {
				if c.book == bi && is_group(c) {
					append(&s.side, Side_Item{kind = .Group, handle = id.handle, book = bi, group = ci})
				}
			}
		}
	}
	s.side_sel = clamp(s.side_sel, 0, max(0, len(s.side) - 1))
}

current_filter :: proc(s: ^App_State) -> Filter {
	f := Filter{book = -1, group = -1, query = string(s.query[:])}
	if s.side_sel < len(s.side) {
		it := s.side[s.side_sel]
		switch it.kind {
		case .All:
		case .Ident:
			f.handle = it.handle
		case .Book:
			f.handle = it.handle
			f.book = it.book
		case .Group:
			f.handle = it.handle
			f.book = it.book
			f.group = it.group
		}
	}
	return f
}

current_list :: proc(s: ^App_State) -> []int {
	return visible(s.st, current_filter(s))
}

selected :: proc(s: ^App_State) -> (int, bool) {
	list := current_list(s)
	if len(list) == 0 {
		return -1, false
	}
	s.list_sel = clamp(s.list_sel, 0, len(list) - 1)
	return list[s.list_sel], true
}

// target_book is where a new contact or an import goes: the selected book,
// else the first own book of the selected identity, else the first own one.
target_book :: proc(s: ^App_State) -> int {
	f := current_filter(s)
	if f.book >= 0 && !s.st.books[f.book].readonly {
		return f.book
	}
	return find_book(s.st, "", f.handle)
}

ident_color :: proc(s: ^App_State, handle: string) -> string {
	if id := ident_of(s.st, handle); id != nil && id.color != "" {
		return id.color
	}
	return "slate"
}

initials :: proc(c: Contact) -> string {
	if c.card.given != "" || c.card.family != "" {
		a := first_rune(c.card.given)
		b := first_rune(c.card.family)
		return strings.to_upper(strings.concatenate({a, b}, context.temp_allocator), context.temp_allocator)
	}
	name := display(c)
	parts := strings.fields(name, context.temp_allocator)
	if len(parts) >= 2 {
		return strings.to_upper(strings.concatenate({first_rune(parts[0]), first_rune(parts[len(parts) - 1])}, context.temp_allocator), context.temp_allocator)
	}
	return strings.to_upper(first_rune(name), context.temp_allocator)
}

first_rune :: proc(s: string) -> string {
	for r, i in s {
		_ = r
		end := i + 1
		for end < len(s) && (s[end] & 0xc0) == 0x80 {
			end += 1
		}
		return s[i:end]
	}
	return ""
}

// ---------------------------------------------------------------------------
// The form
// ---------------------------------------------------------------------------

set_buf :: proc(b: ^[dynamic]u8, v: string) {
	clear(b)
	append(b, ..transmute([]u8)v)
}

add_row :: proc(f: ^Form, kind: Row_Kind, value := "", type := "") {
	r := Form_Row{kind = kind, type = type}
	append(&r.buf, ..transmute([]u8)value)
	// Keep emails and phones together, after their kind.
	at := len(f.rows)
	for row, i in f.rows {
		if int(row.kind) > int(kind) {
			at = i
			break
		}
	}
	inject_at(&f.rows, at, r)
	f.field = at
}

open_form :: proc(s: ^App_State, editing: int) {
	f := &s.form
	for &r in f.rows {
		delete(r.buf)
	}
	clear(&f.rows)
	f.editing = editing
	f.err = ""
	f.field = 0
	s.mode = .Edit
	s.swallow = true
	card: vcard.Card
	if editing >= 0 {
		card = s.st.contacts[editing].card
		f.book = s.st.contacts[editing].book
	} else {
		f.book = target_book(s)
	}
	add_row(f, .Given, card.given)
	add_row(f, .Family, card.family)
	add_row(f, .Org, card.org)
	add_row(f, .Title, card.title)
	for e in card.emails {
		add_row(f, .Email, e.value, len(e.types) > 0 ? e.types[0] : "other")
	}
	if len(card.emails) == 0 {
		add_row(f, .Email, "", "home")
	}
	for ph in card.phones {
		t := "other"
		for ty in ph.types {
			if ty != "voice" {
				t = ty
				break
			}
		}
		add_row(f, .Phone, ph.value, t)
	}
	if len(card.phones) == 0 {
		add_row(f, .Phone, "", "cell")
	}
	add_row(f, .Birthday, card.bday)
	add_row(f, .Note, card.note)
	f.field = 0
	if editing < 0 && card.given == "" && card.family == "" && f.book < 0 {
		f.err = "There is no address book you can write to here"
	}
}

commit_form :: proc(s: ^App_State) {
	f := &s.form
	card: vcard.Card
	if f.editing >= 0 {
		card = s.st.contacts[f.editing].card
	} else {
		card.version = "4.0"
		card.kind = "individual"
	}
	emails := make([dynamic]vcard.Typed)
	phones := make([dynamic]vcard.Typed)
	for r in f.rows {
		v := strings.trim_space(string(r.buf[:]))
		switch r.kind {
		case .Given:
			card.given = v
		case .Family:
			card.family = v
		case .Org:
			card.org = v
		case .Title:
			card.title = v
		case .Birthday:
			card.bday = v
		case .Note:
			card.note = v
		case .Email:
			if v != "" {
				if !strings.contains(v, "@") {
					f.err = fmt.aprintf("%q is not an email address", v)
					return
				}
				types := r.type == "" || r.type == "other" ? []string{} : []string{strings.clone(r.type)}
				append(&emails, vcard.Typed{value = strings.clone(v), types = types})
			}
		case .Phone:
			if v != "" {
				types := r.type == "" || r.type == "other" ? []string{} : []string{strings.clone(r.type)}
				append(&phones, vcard.Typed{value = strings.clone(v), types = types})
			}
		}
	}
	card.emails = emails[:]
	card.phones = phones[:]
	card.fn = strings.trim_space(fmt.aprintf("%s %s", card.given, card.family))
	if card.fn == "" {
		card.fn = card.org
	}
	if card.fn == "" && len(card.emails) > 0 {
		card.fn = card.emails[0].value
	}
	if card.fn == "" {
		f.err = "A contact needs a name, a company or an email"
		return
	}
	idx, err := save(s.st, f.book, card, f.editing)
	if err != "" {
		f.err = err
		return
	}
	s.sel_uid = strings.clone(s.st.contacts[idx].card.uid)
	s.mode = .Normal
	after_write(s, fmt.tprintf(f.editing >= 0 ? "Saved \"%s\"" : "Added \"%s\"", card.fn))
	reselect(s)
}

// ---------------------------------------------------------------------------
// Other actions
// ---------------------------------------------------------------------------

delete_selected :: proc(s: ^App_State) {
	i, ok := selected(s)
	if !ok {
		return
	}
	name := strings.clone(display(s.st.contacts[i]), context.temp_allocator)
	if err := remove(s.st, i); err != "" {
		note(s, err)
		return
	}
	after_write(s, fmt.tprintf("Deleted \"%s\"", name))
}

// groups_here lists the groups of the selected contact's book.
groups_here :: proc(s: ^App_State) -> []int {
	out := make([dynamic]int, 0, 4, context.temp_allocator)
	i, ok := selected(s)
	if !ok {
		return out[:]
	}
	for c, k in s.st.contacts {
		if is_group(c) && c.book == s.st.contacts[i].book {
			append(&out, k)
		}
	}
	return out[:]
}

toggle_group :: proc(s: ^App_State, g: int) {
	i, ok := selected(s)
	if !ok {
		return
	}
	on := !in_group(s.st, g, s.st.contacts[i])
	uid := strings.clone(s.st.contacts[i].card.uid, context.temp_allocator)
	gname := strings.clone(display(s.st.contacts[g]), context.temp_allocator)
	if err := set_member(s.st, g, i, on); err != "" {
		note(s, err)
		return
	}
	s.sel_uid = strings.clone(uid)
	after_write(s, on ? fmt.tprintf("Added to %s", gname) : fmt.tprintf("Removed from %s", gname))
}

commit_group_name :: proc(s: ^App_State) {
	name := strings.trim_space(string(s.name_buf[:]))
	if name == "" {
		return
	}
	if s.name_group >= 0 {
		if err := rename_group(s.st, s.name_group, name); err != "" {
			note(s, err)
			return
		}
		after_write(s, fmt.tprintf("Renamed to \"%s\"", name))
	} else {
		book := -1
		if i, ok := selected(s); ok {
			book = s.st.contacts[i].book
		} else {
			book = target_book(s)
		}
		if book < 0 || s.st.books[book].readonly {
			note(s, "No address book you can write to here")
			return
		}
		g, err := new_group(s.st, book, name)
		if err != "" {
			note(s, err)
			return
		}
		_ = g
		after_write(s, fmt.tprintf("Made the group \"%s\"", name))
	}
	s.mode = s.name_group >= 0 ? .Normal : .Groups
}

merge_selected :: proc(s: ^App_State) {
	pairs := duplicates(s.st, Filter{handle = current_filter(s).handle, book = -1, group = -1})
	if len(pairs) == 0 {
		return
	}
	d := pairs[clamp(s.merge_sel, 0, len(pairs) - 1)]
	keep, drop := d.a, d.b
	if s.merge_swap {
		keep, drop = drop, keep
	}
	name := strings.clone(display(s.st.contacts[keep]), context.temp_allocator)
	uid := strings.clone(s.st.contacts[keep].card.uid)
	if err := merge(s.st, keep, drop); err != "" {
		note(s, err)
		return
	}
	s.sel_uid = uid
	s.merge_swap = false
	after_write(s, fmt.tprintf("Merged into \"%s\"", name))
	if len(duplicates(s.st, Filter{handle = current_filter(s).handle, book = -1, group = -1})) == 0 {
		s.mode = .Normal
	}
}

do_import :: proc(s: ^App_State) {
	path := strings.trim_space(string(s.path[:]))
	path = expand_home(path)
	data, err := os.read_entire_file_from_path(path, context.temp_allocator)
	if err != nil {
		note(s, fmt.tprintf("Cannot read %s", path))
		return
	}
	b := target_book(s)
	if b < 0 {
		note(s, "No address book you can write to here")
		return
	}
	r, ierr := import_vcf(s.st, b, string(data))
	if ierr != "" {
		note(s, ierr)
		return
	}
	s.mode = .Normal
	after_write(s, fmt.tprintf("Imported %d new, %d updated, %d skipped", r.added, r.updated, r.skipped))
}

do_export :: proc(s: ^App_State) {
	path := expand_home(strings.trim_space(string(s.path[:])))
	f := current_filter(s)
	f.query = ""
	idx := make([dynamic]int, 0, 16, context.temp_allocator)
	append(&idx, ..visible(s.st, f))
	if f.group < 0 {
		for c, i in s.st.contacts {
			if is_group(c) && (f.book < 0 || c.book == f.book) && (f.handle == "" || s.st.books[c.book].handle == f.handle) {
				append(&idx, i)
			}
		}
	}
	text := export_vcf(s.st, idx[:], s.version3 ? "3.0" : "4.0", context.temp_allocator)
	if os.write_entire_file(path, transmute([]u8)text) != nil {
		note(s, fmt.tprintf("Cannot write %s", path))
		return
	}
	s.mode = .Normal
	note(s, fmt.tprintf("Exported %d cards to %s", len(idx), path))
}

expand_home :: proc(path: string) -> string {
	if strings.has_prefix(path, "~/") {
		return strings.concatenate({os.get_env("HOME", context.temp_allocator), path[1:]}, context.temp_allocator)
	}
	return path
}

do_sign_in :: proc(s: ^App_State) {
	a := s.st.acct
	if a == nil {
		return
	}
	e := ck.sign_in(a.cloud, strings.trim_space(string(s.email[:])), string(s.password[:]))
	if !ck.ok(e) {
		s.signin_err = strings.clone(e.message != "" ? e.message : "Sign-in failed")
		return
	}
	clear(&s.password)
	s.signin_err = ""
	s.mode = .Normal
	reload(s, true)
	note(s, fmt.tprintf("Signed in: %d identities", len(s.st.idents)))
}
