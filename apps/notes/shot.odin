// `notes shots <dir>`: render the interface offscreen and write PNGs, light
// and dark.
//
// No compositor and no window: the same `measure`/`keys`/`frame` the window
// runs, driven through palmy's offscreen renderer, over a fixture written
// into the output directory — three identities (personal, work, project),
// notebooks, tags, links, a carried note and a note shared from someone else.
// Nothing is read from the user's own notes, and sync is off: the sync state
// line is set to what a signed-in device shows. The pictures of two people
// editing at once come from real sessions (`record.sh`), not from here.
package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import kit "kit:."
import p "palmy:."
import prose "../prose"
import sc "shadcn:."

SHOT_W :: 1320
SHOT_H :: 820

// shot_fonts loads exactly what `kit.start` gives a window, into the
// offscreen font table: a screenshot in a different face proves nothing.
shot_fonts :: proc(off: ^p.Offscreen, dark := false) {
	for pair in ([?]struct {
		file: string,
		wt:   p.Font_Weight,
	}{
		{"Geist-400.ttf", .Regular},
		{"Geist-500.ttf", .Medium},
		{"Geist-600.ttf", .Semibold},
		{"Geist-700.ttf", .Bold},
	}) {
		p.load_font(&off.fonts, fmt.tprintf("%s/%s", kit.FONT_DIR, pair.file), .Sans, pair.wt)
	}
	for wt in p.Font_Weight {
		p.use_synthetic_italic(&off.fonts, .Sans, wt)
	}
	for path in ([?]string {
		"/usr/share/fonts/TTF/JetBrainsMonoNerdFont-Regular.ttf",
		"/usr/share/fonts/TTF/DejaVuSansMono.ttf",
		"/usr/share/fonts/liberation/LiberationMono-Regular.ttf",
	}) {
		if p.load_font(&off.fonts, path, .Mono, .Regular) {
			p.load_font(&off.fonts, path, .Mono, .Medium)
			p.load_font(&off.fonts, path, .Mono, .Semibold)
			p.load_font(&off.fonts, path, .Mono, .Bold)
			break
		}
	}
	sc.register_shadcn_theme(dark)
	p.set_text_gamma(1.8)
	register_colors(dark)
}

Fixture_Note :: struct {
	ident:    string,
	notebook: string,
	name:     string,
	front:    string, // extra front matter lines
	body:     string,
}

FIXTURE_IDS := [?][5]string {
	{"camille", "Camille Roux", "teal", "personal", "6f1c0c55-0000-4000-8000-00000000c0de"},
	{"northwind", "Northwind", "blue", "work", "6f1c0c55-0000-4000-8000-00000000ab1e"},
	{"halcyon", "Halcyon", "violet", "project", "6f1c0c55-0000-4000-8000-0000000fee15"},
}

FIXTURE_NOTES := [?]Fixture_Note {
	{"camille", "Kitchen", "bread-that-actually-worked", "", `# Bread that actually worked

500 g flour, 350 g water, 10 g salt, 100 g starter at its peak.

Four folds, forty minutes apart. Shape cold, bake at 240 °C with steam for twenty minutes and 210 °C without for twenty more. The crumb opened up because the dough was *colder*, not wetter. #baking
`},
	{"camille", "", "reading-list", "", `# Reading list

- *The Elements of Typographic Style*, for the chapter on measure
- Knuth & Plass, "Breaking Paragraphs into Lines"
- [x] Raster Tragedy, parts one and two
`},
	{"camille", "Home", "garden-plan-for-spring", "", `# Garden plan for spring

Three raised beds running north to south, so nothing shades its neighbour before noon. Broad beans in February, chard in March. #garden
`},
	{"camille", "Travel", "restaurants-in-lisbon", "", `# Restaurants in Lisbon

- Prado, for the terrace, book ahead
- Taberna da Rua das Flores, no bookings, go at 19:00
- A Cevicheria, if the queue is short

Back to [[Lisbon trip]].
`},
	{"camille", "", "packing-list", "carried_from: northwind/6f1c0c55-0000-4000-8000-0000000000aa\n", `# Packing list

- badge
- laptop charger
- the Q4 deck on a stick
- swimming things, it is still warm in October
`},
	{"camille", "Shared/alice.martin", "book-club-picks", "shared_from: alice.martin\naccess: edit\n", `# Book club picks

Alice's list for the winter. Add yours under hers.

- *Piranesi*, Susanna Clarke
- *The Dispossessed*, Ursula K. Le Guin
`},
	{"camille", "Travel/2026", "lisbon-trip", "pinned: true\ntags: [travel]\n", `# Lisbon trip

Flights on **Friday**, 07:40 from Orly, back Monday evening. The hotel is near Alfama; the rest is in [[Restaurants in Lisbon]] and [[Packing list]].

## To book

- [x] the hotel near Alfama
- [ ] a table at Prado for Saturday (ask for the terrace)
- [ ] the 28 tram, early, before it fills up

## Ideas

> Pastéis at Manteigaria, not the queue at Belém.

The Gulbenkian is free on Sundays after 14:00. A ` + "`Viva Viagem`" + ` card for the metro, topped up with *zapping*. #travel #lisbon
`},
	{"northwind", "Engineering", "wayland-surface-notes", "", `# Wayland surface notes

A **surface** is not a window until a role is attached to it.

1. ` + "`wl_compositor.create_surface`" + `
2. ` + "`xdg_wm_base.get_xdg_surface`" + `
3. commit, *then* wait for the first configure

- [x] Does a fractional scale change the buffer size?
- [ ] Measure a full damage region against a partial one
`},
	{"northwind", "", "meeting-tuesday", "", `# Meeting, Tuesday

Agreed: the parity harness measures, it does not decide. See [[Q4 plan]].

- Fonts stay pinned to the versions in the repository
- No screenshot is checked in that was rendered from real data
`},
	{"northwind", "", "quarterly-update", "", `# Quarterly update

We will utilize the synergy going forward in order to leverage our core competencies, and it is my understanding that a decision was taken to commence the project prior to the end of the quarter.

- Obviously we should just run the migration
- The the plan is clearly very simple
`},
	{"northwind", "Projects", "standup-notes", "", `# Standup notes

- Sync server: snapshots every 200 updates, measured
- [[Q4 plan]] review moved to Thursday
- [ ] Ines: the offline merge demo #q4
`},
	{"northwind", "Projects", "q4-plan", "tags: [q4]\n", `# Q4 plan

Three things this quarter, in this order:

1. **Offline first** for notes and documents: edits on two devices merge
2. Sharing that is a row you can revoke, never a link left open
3. Search that never leaves the machine

## Open

- [ ] Decide the retention for the update log (30 days?)
- [x] Pick the CRDT: keep the Odin one, measured against Yjs
- [ ] Ask legal about the export format

Discussed at [[Standup notes]]. My own trip that week is in [[camille:Lisbon trip]], which stays in my personal notes. #q4
`},
	{"halcyon", "", "launch-checklist", "pinned: true\n", `# Launch checklist

- [x] Domain and mail for halcyon.dev
- [ ] Pricing page: see [[Pricing ideas]]
- [ ] Privacy notice in plain words
`},
	{"halcyon", "", "pricing-ideas", "", `# Pricing ideas

One plan, priced per person, with every identity included. No seat games.
`},
}

// shot_fixture writes the notes the shots show. Invented entirely: no file
// is read from anywhere else on the machine.
shot_fixture :: proc(dir: string) -> string {
	root := strings.clone(fmt.tprintf("%s/.store/Notes", dir))
	os.remove_all(root)
	for id in FIXTURE_IDS {
		r := fmt.tprintf("%s/%s", root, id[0])
		os.make_directory_all(r)
		ident_bind(r, id[4], id[0], id[1], id[2], id[3])
	}
	for f, i in FIXTURE_NOTES {
		folder := f.notebook == "" ? fmt.tprintf("%s/%s", root, f.ident) : fmt.tprintf("%s/%s/%s", root, f.ident, f.notebook)
		os.make_directory_all(folder)
		front := fmt.tprintf("---\nid: 6f1c0c55-0000-4000-8000-%012d\n%s---\n\n", i + 1, f.front)
		path := fmt.tprintf("%s/%s.md", folder, f.name)
		if werr := os.write_entire_file(path, transmute([]u8)strings.concatenate({front, f.body}, context.temp_allocator)); werr != nil {
			fmt.eprintfln("notes shots: could not write %s", path)
		}
		// store_load orders by mtime: stagger them, newest last in the table.
		time.sleep(15 * time.Millisecond)
	}
	return root
}

Shooter :: struct {
	off:  ^p.Offscreen,
	nt:   ^Notes,
	dir:  string,
	dark: bool,
	n:    int,
}

shot_step :: proc(s: ^Shooter) {
	ui := p.offscreen_begin(s.off)
	s.nt.now = time.now()
	measure(ui, s.nt)
	keys(ui, s.nt, nil)
	frame(ui, s.nt)
	p.offscreen_end(s.off)
}

// Two frames before every write: hover and hit testing run against the
// previous frame, so the second one is the settled picture.
shot_settle :: proc(s: ^Shooter, n := 3) {
	for _ in 0 ..< n {
		shot_step(s)
	}
	// Hover and selection colours ease over 150 ms; a picture taken
	// mid-fade shows the previous selection as a ghost.
	time.sleep(260 * time.Millisecond)
	shot_step(s)
	shot_step(s)
}

shot_write :: proc(s: ^Shooter, name: string) {
	path := fmt.tprintf("%s/%s%s.png", s.dir, name, s.dark ? "-dark" : "")
	if p.offscreen_write_png(s.off, path) {
		s.n += 1
		fmt.printfln("  %s", path)
	} else {
		fmt.eprintfln("  could not write %s", path)
	}
}

shot_open :: proc(nt: ^Notes, title: string) {
	for v, i in nt.vis {
		if nt.all[v].title == title {
			nt.sel = i
			open_sel(nt)
			return
		}
	}
}

shot_view :: proc(nt: ^Notes, ident: int, section: Section, name := "") {
	set_view(nt, View{ident = ident, section = section, name = name})
	build_side(nt)
	set_view(nt, View{ident = ident, section = section, name = name})
}

shots :: proc(dir: string) -> int {
	if err := os.make_directory_all(dir, os.perm(0o700)); err != nil && !os.exists(dir) {
		fmt.eprintfln("notes shots: cannot create %s", dir)
		return 1
	}
	root := shot_fixture(dir)
	defer delete(root)
	saved_root := strings.clone(os.get_env("PALM_NOTES_ROOT", context.temp_allocator), context.temp_allocator)
	saved_one := strings.clone(os.get_env("PALMY_NOTES_DIR", context.temp_allocator), context.temp_allocator)
	saved_scope := strings.clone(os.get_env("PALM_IDENTITY", context.temp_allocator), context.temp_allocator)
	_ = os.set_env("PALM_NOTES_ROOT", root)
	_ = os.set_env("PALM_NOTES_NO_SYNC", "1")
	_ = os.unset_env("PALMY_NOTES_DIR")
	_ = os.unset_env("PALM_IDENTITY")
	defer {
		_ = os.set_env("PALM_NOTES_ROOT", saved_root)
		_ = os.set_env("PALMY_NOTES_DIR", saved_one)
		_ = os.set_env("PALM_IDENTITY", saved_scope)
		_ = os.unset_env("PALM_NOTES_NO_SYNC")
	}

	total := 0
	for dark in ([2]bool{false, true}) {
		total += shot_set(dir, dark)
	}
	total += shot_capture(dir)
	fmt.printfln("notes shots: %d PNGs in %s", total, dir)
	return 0
}

shot_set :: proc(dir: string, dark: bool) -> int {
	off := p.offscreen_create(SHOT_W, SHOT_H, 1, "w-full h-full flex-col bg-background text-foreground overflow-hidden")
	defer p.offscreen_destroy(off)
	shot_fonts(off, dark)

	nt := new(Notes)
	defer free(nt)
	nt.dark = dark
	nt.tz = 0
	nt.now = time.now()
	nt.backlinks = true
	nt.pane = .List
	nt.view = View{ident = -1, section = .All}
	buf_init_empty(&nt.buf)
	prose_init(nt)
	defer prose_destroy(nt)
	defer kit.pick_destroy(&nt.pick)
	reload(nt)
	nt.sync.ran = true
	nt.sync.online = true
	nt.sync.account = strings.clone("signed in")
	nt.sync.last_ok = time.now()
	nt.pr.on = false

	s := Shooter{off = off, nt = nt, dir = dir, dark = dark}

	// 1. One identity: the note open, formatted as it is written, backlinks.
	shot_view(nt, 0, .All)
	shot_open(nt, "Lisbon trip")
	nt.pane = .Editor
	nt.cur = {2, 41}
	shot_settle(&s)
	shot_write(&s, "01-camille-lisbon")

	// 2. All identities: every row labelled, the band in every colour.
	nt.pane = .List
	shot_view(nt, -1, .All)
	shot_open(nt, "Q4 plan")
	shot_settle(&s)
	shot_write(&s, "02-all-identities")

	// 3. Search across identities, labelled, with the honesty line.
	nt.mode = .Search
	clear(&nt.query)
	append(&nt.query, ..transmute([]u8)string("plan"))
	refilter(nt)
	open_sel(nt)
	shot_settle(&s)
	shot_write(&s, "03-search-every-identity")
	// The same search inside one identity says what else exists, not what.
	shot_view(nt, 1, .All)
	append(&nt.query, ..transmute([]u8)string(""))
	refilter(nt)
	open_sel(nt)
	shot_settle(&s)
	shot_write(&s, "04-search-in-northwind")
	clear(&nt.query)
	nt.mode = .Normal
	refilter(nt)

	// 5. Share, from the owner's identity.
	shot_view(nt, 0, .All)
	shot_open(nt, "Lisbon trip")
	nt.mode = .Share
	clear(&nt.share_handle)
	append(&nt.share_handle, ..transmute([]u8)string("bob.okafor"))
	nt.share_edit = true
	clear(&nt.people)
	append(&nt.people, Person{"camille", "Camille Roux", "teal", "owner"}, Person{"alice.martin", "Alice Martin", "indigo", "read"})
	shot_settle(&s)
	shot_write(&s, "05-share")
	nt.mode = .Normal

	// 6. Carry, from work to personal.
	shot_view(nt, 1, .All)
	shot_open(nt, "Standup notes")
	nt.mode = .Carry
	nt.carry_to = 0
	shot_settle(&s)
	shot_write(&s, "06-carry")
	nt.mode = .Normal

	// 7. A new note in All identities asks as whom.
	shot_view(nt, -1, .All)
	shot_open(nt, "Launch checklist")
	nt.mode = .Choose_Identity
	nt.choose_sel = -1
	shot_settle(&s)
	shot_write(&s, "07-new-as-whom")
	nt.mode = .Normal

	// 8. A note shared with this identity.
	shot_view(nt, 0, .Shared)
	shot_open(nt, "Book club picks")
	nt.pane = .List
	shot_settle(&s)
	shot_write(&s, "08-shared-with-me")

	// 9. The keys.
	shot_view(nt, 0, .All)
	shot_open(nt, "Lisbon trip")
	nt.mode = .Help
	shot_settle(&s)
	shot_write(&s, "09-keys")
	nt.mode = .Normal

	// 10. The writing coach, in a work memo.
	shot_view(nt, 1, .All)
	shot_open(nt, "Quarterly update")
	nt.pane = .Editor
	nt.pr.on = true
	if i := prose.pack_index(&nt.pr.eng, "Business"); i >= 0 {
		nt.pr.style = i
	}
	prose_invalidate(nil, nt)
	prose_force(nt)
	nt.pr.mark = 0
	for a, i in nt.pr.alerts {
		if a.has_fix {
			nt.pr.mark = i
			break
		}
	}
	if a, ok := prose_mark(nt); ok {
		nt.cur = doc_pos(nt, a.from)
	}
	shot_settle(&s, 4)
	shot_write(&s, "10-writing-coach")
	nt.pr.on = false
	nt.pr.mark = -1

	// 11–12. Narrower windows: the sidebar becomes a drawer, then one pane.
	n := s.n
	shot_narrow(dir, dark, 940, 760, "11-two-panes", proc(nt: ^Notes) {
		shot_view(nt, 0, .Notebook, "Travel")
		shot_open(nt, "Lisbon trip")
	}, &n)
	shot_narrow(dir, dark, 420, 820, "12-phone-list", proc(nt: ^Notes) {
		shot_view(nt, 0, .All)
		nt.pane = .List
	}, &n)
	shot_narrow(dir, dark, 420, 820, "13-phone-note", proc(nt: ^Notes) {
		shot_view(nt, 0, .All)
		shot_open(nt, "Lisbon trip")
		nt.pane = .Editor
		nt.backlinks = false
	}, &n)
	return n
}

shot_narrow :: proc(dir: string, dark: bool, w, h: int, name: string, setup: proc(nt: ^Notes), count: ^int) {
	off := p.offscreen_create(w, h, 1, "w-full h-full flex-col bg-background text-foreground overflow-hidden")
	defer p.offscreen_destroy(off)
	shot_fonts(off, dark)
	nt := new(Notes)
	defer free(nt)
	nt.dark = dark
	nt.backlinks = true
	nt.view = View{ident = -1, section = .All}
	buf_init_empty(&nt.buf)
	prose_init(nt)
	defer prose_destroy(nt)
	reload(nt)
	nt.sync.ran = true
	nt.sync.online = true
	nt.sync.account = strings.clone("signed in")
	nt.sync.last_ok = time.now()
	nt.pr.on = false
	setup(nt)
	s := Shooter{off = off, nt = nt, dir = dir, dark = dark}
	shot_settle(&s)
	shot_write(&s, name)
	count^ += s.n
}

// shot_capture renders the quick capture window.
shot_capture :: proc(dir: string) -> int {
	n := 0
	for dark in ([2]bool{false, true}) {
		off := p.offscreen_create(560, 300, 1, "w-full h-full flex-col bg-background text-foreground overflow-hidden")
		shot_fonts(off, dark)
		c := Capture{}
		capture_init(&c, dark)
		c.sel = 0
		append(&c.text, ..transmute([]u8)string("Call the plumber about the boiler\nBefore Thursday; the number is on the fridge."))
		for _ in 0 ..< 3 {
			ui := p.offscreen_begin(off)
			capture_frame(ui, &c)
			p.offscreen_end(off)
		}
		path := fmt.tprintf("%s/14-quick-capture%s.png", dir, dark ? "-dark" : "")
		if p.offscreen_write_png(off, path) {
			n += 1
			fmt.printfln("  %s", path)
		}
		p.offscreen_destroy(off)
	}
	return n
}
