// `contacts --shots <dir>`: the window, offscreen, light and dark.
//
// No compositor, no account, no server: the same `keys` and `frame` the
// window runs, over in-memory address books filled with invented people.
package main

import "core:fmt"
import "core:os"
import vcard "../../cloud/dav/vcard"
import kit "kit:."
import p "palmy:."
import sc "shadcn:."

SHOT_W :: 1240
SHOT_H :: 800

@(private = "file")
shot_fonts :: proc(off: ^p.Offscreen, dark: bool) {
	for pair in ([?]struct {
		file: string,
		wt:   p.Font_Weight,
	}{{"Geist-400.ttf", .Regular}, {"Geist-500.ttf", .Medium}, {"Geist-600.ttf", .Semibold}, {"Geist-700.ttf", .Bold}}) {
		p.load_font(&off.fonts, fmt.tprintf("%s/%s", kit.FONT_DIR, pair.file), .Sans, pair.wt)
	}
	for wt in p.Font_Weight {
		p.use_synthetic_italic(&off.fonts, .Sans, wt)
	}
	for path in ([?]string{"/usr/share/fonts/TTF/JetBrainsMonoNerdFont-Regular.ttf", "/usr/share/fonts/TTF/DejaVuSansMono.ttf"}) {
		if p.load_font(&off.fonts, path, .Mono, .Regular) {
			p.load_font(&off.fonts, path, .Mono, .Medium)
			p.load_font(&off.fonts, path, .Mono, .Semibold)
			p.load_font(&off.fonts, path, .Mono, .Bold)
			break
		}
	}
	sc.register_shadcn_theme(dark)
	p.set_text_gamma(1.8)
}

// fixtures fills a store with invented people across three books.
fixtures :: proc() -> ^Store {
	st := store_make()
	context.allocator = store_alloc(st)
	append(&st.idents, Ident{"alice", "Alice Martin", "indigo", "personal"}, Ident{"alice-work", "Alice (Northwind)", "emerald", "work"})
	home := fixture_book(st, "alice", "default", "Contacts", "owner")
	shared := fixture_book(st, "alice", "bob~default", "Family (bob)", "read")
	work := fixture_book(st, "alice-work", "default", "Northwind", "owner")
	T :: vcard.Typed
	// Fixed UIDs, so every capture is the same picture; the read-only share
	// is filled with the flag down, since save rightly refuses to write it.
	add :: proc(st: ^Store, b: int, given, family, org, title: string, emails, phones: []T, note := "", bday := "", city := "") -> int {
		c := vcard.Card{given = given, family = family, org = org, title = title, emails = emails, phones = phones, note = note, bday = bday, version = "4.0"}
		c.uid = fmt.aprintf("0000%04d-f1x7-4000-8000-%012d", len(st.contacts) + 1, len(st.contacts) + 1)
		if city != "" {
			a := make([]vcard.Address, 1)
			a[0] = vcard.Address{types = []string{"home"}, street = "14 Rue des Lilas", locality = city, postcode = "75020", country = "France"}
			c.addresses = a
		}
		ro := st.books[b].readonly
		st.books[b].readonly = false
		i, _ := save(st, b, c)
		st.books[b].readonly = ro
		return i
	}
	group :: proc(st: ^Store, b: int, name: string) -> int {
		i, _ := save(st, b, vcard.Card{fn = name, kind = "group", version = "4.0", uid = fmt.aprintf("0000%04d-6r0u-4000-8000-%012d", len(st.contacts) + 1, len(st.contacts) + 1)})
		return i
	}
	inès := add(st, home, "Inès", "Moreau", "Atelier Moreau", "Ceramicist",
		{{value = "ines@atelier-moreau.example", types = {"work"}, pref = true}, {value = "ines.moreau@mail.example", types = {"home"}}},
		{{value = "+33 6 12 34 56 78", types = {"cell"}}, {value = "+33 1 43 55 20 10", types = {"work"}}},
		"Met at the Belleville open studios. Prefers calls after 4pm.", "1988-04-12", "Paris")
	tomas := add(st, home, "Tomás", "Herrera", "", "", {{value = "tomas.h@mail.example"}}, {{value = "+34 612 555 018", types = {"cell"}}})
	add(st, home, "Mei", "Lin", "Lantern Books", "Editor", {{value = "mei@lantern.example", types = {"work"}}}, {})
	add(st, home, "Kwame", "Asante", "", "", {{value = "kwame.asante@mail.example"}}, {{value = "+44 7700 900123", types = {"cell"}}}, bday = "--0921")
	add(st, home, "Sofia", "Lindqvist", "", "", {{value = "sofia.l@mail.example"}}, {})
	dup := add(st, home, "Ines", "Moreau", "", "", {{value = "INES@atelier-moreau.example"}}, {{value = "+33 1 43 55 20 10"}})
	_ = dup
	add(st, shared, "Hélène", "Okafor", "", "", {{value = "helene@okafor.example"}}, {{value = "+234 803 555 0142", types = {"home"}}})
	add(st, shared, "Daniel", "Okafor", "", "", {{value = "dan@okafor.example"}}, {})
	add(st, work, "Priya", "Raman", "Northwind", "Head of Design", {{value = "priya.raman@northwind.example", types = {"work"}}}, {{value = "+1 415 555 0148", types = {"work"}}})
	add(st, work, "Jonas", "Weber", "Northwind", "Staff engineer", {{value = "jonas.weber@northwind.example", types = {"work"}}}, {})
	add(st, work, "Amara", "Okonjo", "Lagos Rowing Club", "Partner", {{value = "amara@rowing.example"}}, {{value = "+234 801 555 0199", types = {"cell"}}})
	add(st, work, "Yuki", "Tanaka", "Kiso Partners", "Account lead", {{value = "yuki@kiso.example", types = {"work"}}}, {})
	g := group(st, home, "Climbing club")
	set_member(st, g, find_uid(st, st.contacts[inès].card.uid), true)
	set_member(st, g, find_uid(st, st.contacts[tomas].card.uid), true)
	g2 := group(st, home, "Studio neighbours")
	set_member(st, g2, find_uid(st, st.contacts[inès].card.uid), true)
	g3 := group(st, work, "Design review")
	_ = g3
	return st
}

shots :: proc(dir: string) -> int {
	if err := os.make_directory_all(dir, os.perm(0o755)); err != nil && !os.exists(dir) {
		fmt.eprintfln("contacts --shots: cannot create %s", dir)
		return 1
	}
	n := 0
	for dark in ([?]bool{false, true}) {
		off := p.offscreen_create(SHOT_W, SHOT_H, 1, "w-full h-full flex-col bg-background text-foreground overflow-hidden")
		shot_fonts(off, dark)
		s := new(App_State)
		s.st = fixtures()
		s.fixture = true
		s.form.editing = -1
		s.name_group = -1
		s.pane = .List
		suffix := dark ? "dark" : "light"

		step :: proc(off: ^p.Offscreen, s: ^App_State) {
			ui := p.offscreen_begin(off)
			keys(ui, s)
			frame(ui, s)
			p.offscreen_end(off)
		}
		settle :: proc(off: ^p.Offscreen, s: ^App_State) {
			for _ in 0 ..< 3 {
				step(off, s)
			}
		}
		shot :: proc(off: ^p.Offscreen, dir, name: string, n: ^int) {
			path := fmt.tprintf("%s/%s", dir, name)
			if p.offscreen_write_png(off, path) {
				n^ += 1
				fmt.printfln("  %s", path)
			}
		}
		select_uid :: proc(s: ^App_State, given: string) {
			for idx, k in current_list(s) {
				if s.st.contacts[idx].card.given == given {
					s.list_sel = k
					s.sel_uid = s.st.contacts[idx].card.uid
				}
			}
		}

		// The overlay of every identity, Inès selected.
		build_side(s)
		s.side_sel = 0
		select_uid(s, "Inès")
		settle(off, s)
		shot(off, dir, fmt.tprintf("01-all-identities-%s.png", suffix), &n)

		// The edit form.
		open_form(s, find_uid(s.st, s.sel_uid))
		s.swallow = false
		s.form.field = 4
		settle(off, s)
		shot(off, dir, fmt.tprintf("02-edit-%s.png", suffix), &n)
		s.mode = .Normal

		// A group in the sidebar, then the groups sheet.
		for it, k in s.side {
			if it.kind == .Group {
				s.side_sel = k
				break
			}
		}
		s.list_sel = 0
		s.pane = .Sidebar
		settle(off, s)
		s.pane = .List
		select_uid(s, "Inès")
		s.mode = .Groups
		settle(off, s)
		shot(off, dir, fmt.tprintf("03-groups-%s.png", suffix), &n)
		s.mode = .Normal

		// Duplicates, from the "All" view.
		s.side_sel = 0
		s.mode = .Merge
		settle(off, s)
		shot(off, dir, fmt.tprintf("04-duplicates-%s.png", suffix), &n)
		s.mode = .Normal

		// The work identity alone, with the read-only share visible in the
		// sidebar.
		for it, k in s.side {
			if it.kind == .Ident && it.handle == "alice-work" {
				s.side_sel = k
			}
		}
		s.list_sel = 1
		settle(off, s)
		shot(off, dir, fmt.tprintf("05-work-identity-%s.png", suffix), &n)

		// Signed out.
		s2 := new(App_State)
		s2.st = store_make()
		s2.fixture = true
		s2.mode = .Sign_In
		append(&s2.email, ..transmute([]u8)string("alice@example.test"))
		append(&s2.password, ..transmute([]u8)string("correct horse"))
		s2.signin_fld = 1
		settle(off, s2)
		shot(off, dir, fmt.tprintf("06-sign-in-%s.png", suffix), &n)

		p.offscreen_destroy(off)
	}
	fmt.printfln("contacts --shots: %d PNGs in %s", n, dir)
	return 0
}
