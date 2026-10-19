package main

// `files --shots <dir>`: render the browser offscreen and write PNGs.
//
// The directory it browses is a fabricated tree built fresh for the shot, and
// `HOME` is pointed at its root, so the breadcrumb says "Home" and no part of
// the machine this ran on reaches an image. Nothing of the real user's is ever
// opened, listed or stat'd.

import "core:fmt"
import "core:os"
import "core:strings"
import kit "kit:."
import p "palmy:."
import sc "shadcn:."
import "core:time"

SHOT_W :: 1180
SHOT_H :: 760

// The fixture tree lives outside the output directory on purpose: the
// inspector prints the absolute path of the selected file, and the output
// directory a harness hands us is not something to render into a picture.
SHOT_ROOT :: "/tmp/palmy-shot-fixtures/files"

shots :: proc(dir: string) -> int {
	if err := os.make_directory_all(dir, os.perm(0o700)); err != nil && !os.exists(dir) {
		fmt.eprintfln("files: could not create %s", dir)
		return 1
	}
	home := shot_tree()
	if home == "" {
		return 1
	}
	_ = os.set_env("HOME", home)

	off := p.offscreen_create(
		SHOT_W,
		SHOT_H,
		1,
		"w-full h-full flex-col bg-background text-foreground overflow-hidden",
	)
	defer p.offscreen_destroy(off)
	shot_fonts(&off.fonts)
	sc.register_shadcn_theme(false)
	p.set_text_gamma(1.8)
	p.register_color("selection", p.hex(SELECTION))

	// Offscreen there is no window, but `handle_keys` wants an `^p.App` for
	// the one Ctrl-Q path. A stand-in with the font table and the window size
	// is everything the drawing code actually reads.
	app := new(p.App)
	defer free(app)
	app.win.width, app.win.height, app.win.scale = SHOT_W, SHOT_H, 1
	app.fonts = off.fonts

	st := State{}
	st.tz_offset = local_offset()
	st.now = time.now()
	build_places(&st)
	go_to(&st, strings.clone(fmt.tprintf("%s/Documents", home)))
	sync_place(&st)
	st.pane = .Files

	step :: proc(off: ^p.Offscreen, app: ^p.App, st: ^State) {
		ui := p.offscreen_begin(off)
		measure(ui, st)
		handle_keys(ui, st, app)
		frame(ui, st)
		p.offscreen_end(off)
	}

	n := 0
	shot :: proc(off: ^p.Offscreen, dir, name: string, n: ^int) {
		out := fmt.tprintf("%s/%s.png", dir, name)
		if p.offscreen_write_png(off, out) {
			n^ += 1
			fmt.printfln("  %s", out)
		}
	}

	// The list view, a file selected, the inspector open: the representative
	// picture of a file browser.
	st.sel = 4
	st.inspector = true
	step(off, app, &st)
	step(off, app, &st)
	shot(off, dir, "app-files", &n)

	// The icon grid.
	set_view(&st, .Grid)
	st.sel = 2
	step(off, app, &st)
	step(off, app, &st)
	shot(off, dir, "02-files-grid", &n)

	// Live filtering, back in the list.
	set_view(&st, .List)
	st.pane = .Search
	st.swallow = false
	p.type_text(off, "re")
	step(off, app, &st)
	step(off, app, &st)
	shot(off, dir, "03-files-filter", &n)

	// The context menu, drawn in-window because there is no xdg_popup.
	clear(&st.filter)
	st.pane = .Files
	rebuild(&st)
	st.sel = 1
	st.menu_open = true
	st.menu_sel = 0
	st.menu_at = {470, 250}
	step(off, app, &st)
	step(off, app, &st)
	shot(off, dir, "04-files-menu", &n)

	// One level up, so the breadcrumb has more than one crumb to elide.
	st.menu_open = false
	st.inspector = false
	go_to(&st, strings.clone(home))
	sync_place(&st)
	st.sel = 0
	step(off, app, &st)
	step(off, app, &st)
	shot(off, dir, "05-files-home", &n)

	// Drive: two fabricated identities' folders, as palm-drive identities and
	// status would describe them (no palm-drive is run), with a sync badge on
	// each row and the Drive group of the context menu.
	{
		alice := fmt.tprintf("%s/Drive/alice", home)
		work := fmt.tprintf("%s/Drive/alice.northwind", home)
		_ = os.make_directory_all(fmt.tprintf("%s/Q3 Board pack", alice), os.perm(0o700))
		_ = os.make_directory_all(work, os.perm(0o700))
		for f in ([?]string{"notes.md", "report.txt", "report (conflicted copy, laptop, 2026-10-19 14.03).txt", "budget.xlsx"}) {
			_ = os.write_entire_file(fmt.tprintf("%s/%s", alice, f), transmute([]u8)string("palmy fixture\n"))
		}
		// fmt reads braces as its own, so the JSON is put together by hand.
		ids := strings.concatenate({
			`{"ok":true,"identities":[{"handle":"alice","name":"Alice","kind":"personal","root":"`, alice,
			`"},{"handle":"alice.northwind","name":"Northwind","kind":"work","root":"`, work, `"}]}`,
		}, context.temp_allocator)
		st.drive.ids = drive_parse_identities(ids)
		for id in st.drive.ids {
			append(&st.places, Place{id.name, id.root, ICON_CLOUD, drive_tint(id.kind), "Drive"})
		}
		status := strings.concatenate({
			`{"identities":[{"handle":"alice","root":"`, alice,
			`","offline":false,"actions":["would Upload_Change notes.md","would Conflict report.txt","would Download Q3 Board pack/deck.pptx"]}]}`,
		}, context.temp_allocator)
		st.drive.offline = drive_parse_status(status, &st.drive.badges, &st.drive.known)
		go_to(&st, strings.clone(alice))
		sync_place(&st)
		st.sel = 2
		st.menu_open = true
		st.menu_sel = 0
		st.menu_at = {520, 200}
		step(off, app, &st)
		step(off, app, &st)
		shot(off, dir, "06-files-drive", &n)
		st.menu_open = false
	}

	fmt.printfln("files --shots: %d PNGs in %s", n, dir)
	return 0
}

// ---------------------------------------------------------------------------
// The fabricated tree
// ---------------------------------------------------------------------------

shot_tree :: proc() -> string {
	root := SHOT_ROOT
	if err := os.make_directory_all(root, os.perm(0o700)); err != nil && !os.exists(root) {
		fmt.eprintfln("files: could not create %s", root)
		return ""
	}

	dir :: proc(path: string) {
		_ = os.make_directory_all(path, os.perm(0o700))
	}
	file :: proc(path: string, size: int, text: string) {
		b := strings.builder_make(context.temp_allocator)
		strings.write_string(&b, text)
		for strings.builder_len(b) < size {
			strings.write_string(&b, "palmy fixture content, generated for a screenshot.\n")
		}
		_ = os.write_entire_file(path, transmute([]u8)strings.to_string(b))
	}

	for name in ([?]string {
		"Desktop",
		"Documents",
		"Downloads",
		"Pictures",
		"Music",
		"Videos",
		"Projects",
		"Work",
	}) {
		dir(fmt.tprintf("%s/%s", root, name))
	}

	docs := fmt.tprintf("%s/Documents", root)
	for name in ([?]string{"Archive", "Invoices", "Drafts", "Reference"}) {
		dir(fmt.tprintf("%s/%s", docs, name))
	}
	for e in ([?]struct {
		name: string,
		size: int,
	} {
		{"Annual Review.pdf", 184_320},
		{"Budget Forecast.xlsx", 42_900},
		{"Lease Agreement.docx", 31_400},
		{"Meeting Notes.md", 4_100},
		{"Onboarding.pptx", 920_600},
		{"Quarterly Figures.csv", 12_800},
		{"Reading List.txt", 2_200},
		{"Roadmap Sketch.png", 256_700},
		{"Site Backup.tar.gz", 2_310_000},
		{"Soundcheck.flac", 1_480_000},
		{"Timelapse.mp4", 7_840_000},
		{"build.sh", 1_900},
		{"palette.css", 7_600},
		{"renderer.odin", 23_500},
		{".editorconfig", 320},
	}) {
		file(fmt.tprintf("%s/%s", docs, e.name), e.size, fmt.tprintf("# %s\n\n", e.name))
	}

	// A little depth elsewhere, so the sidebar places are not all empty.
	for e in ([?]struct {
		dir:  string,
		name: string,
		size: int,
	} {
		{"Downloads", "installer.pkg", 44_000},
		{"Downloads", "wallpaper.jpg", 820_000},
		{"Pictures", "harbour.jpg", 1_240_000},
		{"Pictures", "sketch.svg", 18_000},
		{"Music", "overture.mp3", 5_600_000},
		{"Videos", "demo.webm", 9_200_000},
		{"Projects", "notes.md", 3_300},
		{"Desktop", "todo.txt", 800},
	}) {
		file(fmt.tprintf("%s/%s/%s", root, e.dir, e.name), e.size, "")
	}

	return strings.clone(root)
}

// ---------------------------------------------------------------------------
// Fonts, exactly as `kit.start` loads them
// ---------------------------------------------------------------------------

shot_fonts :: proc(fonts: ^p.Fonts) {
	for pair in ([?]struct {
		file: string,
		wt:   p.Font_Weight,
	}{
		{"Geist-400.ttf", .Regular},
		{"Geist-500.ttf", .Medium},
		{"Geist-600.ttf", .Semibold},
		{"Geist-700.ttf", .Bold},
	}) {
		p.load_font(fonts, fmt.tprintf("%s/%s", kit.FONT_DIR, pair.file), .Sans, pair.wt)
	}
	for wt in p.Font_Weight {
		p.use_synthetic_italic(fonts, .Sans, wt)
	}
	for path in ([?]string {
		"/usr/share/fonts/TTF/JetBrainsMonoNerdFont-Regular.ttf",
		"/usr/share/fonts/TTF/DejaVuSansMono.ttf",
		"/usr/share/fonts/liberation/LiberationMono-Regular.ttf",
	}) {
		if p.load_font(fonts, path, .Mono, .Regular) {
			p.load_font(fonts, path, .Mono, .Medium)
			p.load_font(fonts, path, .Mono, .Semibold)
			p.load_font(fonts, path, .Mono, .Bold)
			break
		}
	}
}
