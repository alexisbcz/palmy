// `notes --shots <dir>`: render the interface offscreen and write PNGs.
//
// No compositor and no window: the same `measure`/`keys`/`frame` the window
// runs, driven through palmy's offscreen renderer. The notes it shows are
// written into a private store under the output directory first, so the
// user's own notebook is never anywhere near a picture.
package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import kit "kit:."
import p "palmy:."
import prose "../prose"
import sc "shadcn:."

SHOT_W :: 1150
SHOT_H :: 760

// shot_fonts loads exactly what `kit.start` gives a window, into the
// offscreen font table: a screenshot in a different face proves nothing.
shot_fonts :: proc(off: ^p.Offscreen) {
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
	sc.register_shadcn_theme(false)
	p.set_text_gamma(1.8)
	p.register_color("accent-blue", p.hex(ACCENT))
	prose_register_colors()
}

// shot_fixture writes the notebook the shots show. Invented entirely: no file
// is read from anywhere else on the machine.
shot_fixture :: proc(dir: string) -> string {
	// The path is laid out so the header's `short_home` shortens it to
	// `~/.local/share/palmy-notes` — the directory a real run would use,
	// without the real home being involved.
	store := strings.clone(fmt.tprintf("%s/.store/.local/share/%s", dir, DIR_NAME))
	_ = os.make_directory_all(store, os.perm(0o700))

	Fixture :: struct {
		name: string,
		body: string,
	}
	fixtures := [?]Fixture {
		{
			"wayland-surface-notes",
			`# Wayland surface notes

A **surface** is not a window until a role is attached to it. The sequence
that actually matters, in order:

1. ` + "`wl_compositor.create_surface`" + `
2. ` + "`xdg_wm_base.get_xdg_surface`" + `
3. ` + "`xdg_surface.get_toplevel`" + `
4. commit, *then* wait for the first configure

> Committing a buffer before the first configure is the mistake that costs
> an afternoon: the compositor is within its rights to ignore it.

## Open questions

- [x] Does a fractional scale change the buffer size, or only the viewport?
- [ ] Which of the two is authoritative when both are advertised?
- [ ] Measure the cost of a full damage region against a partial one
`,
		},
		{
			"reading-list",
			`# Reading list

- *The Elements of Typographic Style* — for the chapter on measure
- Knuth & Plass, "Breaking Paragraphs into Lines" (1981)
- UAX #9, the bidirectional algorithm, which is shorter than it looks
- Anything at all on subpixel positioning that is not a forum post

## Finished

- [x] Raster Tragedy, parts one and two
- [x] The original Blinn note on gamma
`,
		},
		{
			"garden-plan-for-spring",
			`# Garden plan for spring

Three raised beds, 1.2 m by 2.4 m, running north to south so nothing
shades its neighbour before noon.

| bed | crop | sown |
| --- | --- | --- |
| one | broad beans | February |
| two | chard, then beans | March |
| three | tomatoes under cover | April |

Soak the bean seed overnight. The chard goes in thin and gets thinned
again rather than sown thin, because germination is unreliable in cold
soil.
`,
		},
		{
			"bread-that-actually-worked",
			`# Bread that actually worked

500 g flour, 350 g water, 10 g salt, 100 g starter at its peak.

Autolyse the flour and water for an hour. Add the starter, then the salt.
Four folds, forty minutes apart. Shape cold, bake at 240 C with steam for
twenty minutes and 210 C without for twenty more.

The crumb was open at last because the dough was *colder*, not because it
was wetter. Keep it at 22 C and stop chasing hydration.
`,
		},
		{
			"quarterly-update",
			`# Quarterly update

We will utilize the synergy going forward in order to leverage our core
competencies, and it is my understanding that a decision was taken to
commence the project prior to the end of the quarter.

It is important to note that the implementation of the comprehensive
methodological framework necessitates substantial deliberation. The
chairman will circle back with the team at the end of the day.

- Obviously we should just run the migration
- The the plan is clearly very simple

` + "```" + `
utilize(very, really);   // a code sample is not prose
` + "```" + `

See http://example.com/utilize/very for the original proposal.
`,
		},
		{
			"meeting-tuesday",
			`# Meeting, Tuesday

Agreed: the parity harness measures, it does not decide. A number that
moves without a reason attached to it goes back to whoever moved it.

- Fonts stay pinned to the versions in the repository
- Text gamma is 1.8 everywhere, including offscreen
- No screenshot is checked in that was rendered from anybody's real data
`,
		},
	}
	for f in fixtures {
		path := unique_path(store, f.name, "")
		defer delete(path)
		if werr := os.write_entire_file(path, transmute([]u8)f.body); werr != nil {
			fmt.eprintfln("notes --shots: could not write %s", path)
		}
		// store_load orders by mtime, so stagger them a little rather than
		// leaving five files written in the same millisecond.
		time.sleep(12 * time.Millisecond)
	}
	return store
}

shots :: proc(dir: string) -> int {
	if err := os.make_directory_all(dir, os.perm(0o700)); err != nil && !os.exists(dir) {
		fmt.eprintfln("notes --shots: cannot create %s", dir)
		return 1
	}
	store := shot_fixture(dir)
	defer delete(store)

	off := p.offscreen_create(
		SHOT_W,
		SHOT_H,
		1,
		"w-full h-full flex-col bg-background text-foreground overflow-hidden",
	)
	defer p.offscreen_destroy(off)
	shot_fonts(off)

	nt := Notes{}
	nt.dir = strings.clone(store)
	nt.tz = 0
	nt.now = time.now()
	buf_init_empty(&nt.buf)
	// The writing coach is part of the application, so the pictures get it
	// exactly as a window would: the same engine, the same packs.
	prose_init(&nt)
	defer prose_destroy(&nt)
	reload(&nt)
	// The Markdown-heavy note, so the picture shows headings, a quote, a code
	// span and task boxes rather than three plain paragraphs.
	for row, i in nt.vis {
		if nt.all[row].title == "Wayland surface notes" {
			nt.sel = i
		}
	}
	open_sel(&nt)
	nt.pane = .Editor
	defer kit.pick_destroy(&nt.pick)

	step :: proc(off: ^p.Offscreen, nt: ^Notes) {
		ui := p.offscreen_begin(off)
		nt.now = time.now()
		measure(ui, nt)
		keys(ui, nt, nil)
		frame(ui, nt)
		p.offscreen_end(off)
	}

	// Two frames before every write: hover and hit testing run against the
	// previous frame, so the second one is the settled picture.
	settle :: proc(off: ^p.Offscreen, nt: ^Notes, n := 2) {
		for _ in 0 ..< n {
			step(off, nt)
		}
	}

	n := 0
	// `shot` takes the name by value and formats into temp, which is safe
	// because nothing of it is held past the write: `p.offscreen_end` frees
	// the temp allocator on the next frame.
	shot :: proc(off: ^p.Offscreen, dir, name: string, n: ^int) {
		path := fmt.tprintf("%s/%s", dir, name)
		if p.offscreen_write_png(off, path) {
			n^ += 1
			fmt.printfln("  %s", path)
		} else {
			fmt.eprintfln("  could not write %s", path)
		}
	}

	// The editor, on the first note, which is the application doing its job.
	settle(off, &nt, 3)
	shot(off, dir, "app-notes.png", &n)

	// The Markdown preview of the same note.
	nt.preview = true
	settle(off, &nt, 3)
	shot(off, dir, "02-notes-preview.png", &n)
	nt.preview = false

	// Search, which runs over the body of every note and not just the titles.
	nt.mode = .Search
	nt.pane = .List
	p.type_text(off, "bean")
	settle(off, &nt, 3)
	refilter(&nt)
	settle(off, &nt, 2)
	shot(off, dir, "03-notes-search.png", &n)

	// The keyboard sheet.
	clear(&nt.query)
	refilter(&nt)
	nt.mode = .Help
	settle(off, &nt, 3)
	shot(off, dir, "04-notes-keys.png", &n)
	nt.mode = .Normal

	// ---- the writing coach ---------------------------------------------
	// A note with something wrong with it, under two different style packs,
	// with one mark selected and the report open. Every alert in these
	// pictures was produced by the engine over the fixture above.
	for row, i in nt.vis {
		if nt.all[row].title == "Quarterly update" {
			nt.sel = i
		}
	}
	open_sel(&nt)
	nt.pane = .Editor
	nt.preview = false
	nt.pr.on = true

	shot_style :: proc(nt: ^Notes, name: string) {
		if i := prose.pack_index(&nt.pr.eng, name); i >= 0 {
			nt.pr.style = i
		}
		prose_invalidate(nil, nt)
		prose_force(nt)
	}

	// Business: the pack for a memo.
	shot_style(&nt, "Business")
	nt.pr.mark = -1
	settle(off, &nt, 3)
	shot(off, dir, "05-notes-prose-business.png", &n)

	// One mark selected, with its explanation and the rewrite it offers. The
	// first alert that has a fix is chosen, because a panel that says "no
	// mechanical rewrite" is the less interesting half of the feature.
	nt.pr.mark = 0
	for a, i in nt.pr.alerts {
		if a.has_fix {
			nt.pr.mark = i
			break
		}
	}
	if a, ok := prose_mark(&nt); ok {
		nt.cur = doc_pos(&nt, a.from)
	}
	settle(off, &nt, 3)
	shot(off, dir, "06-notes-prose-explain.png", &n)

	// The writing report.
	nt.pr.show_report = true
	settle(off, &nt, 4)
	shot(off, dir, "07-notes-prose-report.png", &n)
	nt.pr.show_report = false

	// The same note under Concise, which flags a different set entirely.
	shot_style(&nt, "Concise")
	nt.pr.mark = -1
	settle(off, &nt, 3)
	shot(off, dir, "08-notes-prose-concise.png", &n)

	// The style picker, which is where the feature starts.
	nt.mode = .Styles
	nt.pr.pick_sel = 1
	settle(off, &nt, 3)
	shot(off, dir, "09-notes-prose-styles.png", &n)
	nt.mode = .Normal

	fmt.printfln("notes --shots: %d PNGs in %s", n, dir)
	return 0
}
