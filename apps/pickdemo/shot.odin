package main

// `pickdemo --shots <dir>`: render the file dialog offscreen and write PNGs.
//
// The picker's whole job is to browse a filesystem, so a screenshot of it is
// exactly the kind of picture that leaks somebody's file names. This never
// looks at the real home directory: it builds a fixture tree under the output
// directory, points `HOME` at it, and drives the dialog there. Every path the
// dialog prints is therefore under that fixture, and shown as `~/...`.

import "core:fmt"
import "core:os"
import "core:strings"
import kit "kit:."
import p "palmy:."
import sc "shadcn:."

SHOT_W :: 1100
SHOT_H :: 720

// shot_load_fonts loads exactly the faces `kit.start` gives a window.
shot_load_fonts :: proc(f: ^p.Fonts) {
	for pair in ([?]struct {
		file: string,
		wt:   p.Font_Weight,
	}{
		{"Geist-400.ttf", .Regular},
		{"Geist-500.ttf", .Medium},
		{"Geist-600.ttf", .Semibold},
		{"Geist-700.ttf", .Bold},
	}) {
		p.load_font(f, fmt.tprintf("%s/%s", kit.FONT_DIR, pair.file), .Sans, pair.wt)
	}
	for wt in p.Font_Weight {
		p.use_synthetic_italic(f, .Sans, wt)
	}
	for path in ([?]string {
		"/usr/share/fonts/TTF/JetBrainsMonoNerdFont-Regular.ttf",
		"/usr/share/fonts/TTF/DejaVuSansMono.ttf",
		"/usr/share/fonts/liberation/LiberationMono-Regular.ttf",
	}) {
		if p.load_font(f, path, .Mono, .Regular) {
			p.load_font(f, path, .Mono, .Medium)
			p.load_font(f, path, .Mono, .Semibold)
			p.load_font(f, path, .Mono, .Bold)
			break
		}
	}
}

// shot_file writes a file of `size` bytes, creating its directory.
shot_file :: proc(path: string, size: int) {
	if at := strings.last_index(path, "/"); at > 0 {
		_ = os.make_directory_all(path[:at])
	}
	buf := make([]u8, size, context.temp_allocator)
	for i in 0 ..< size {
		buf[i] = 'x'
	}
	_ = os.write_entire_file(path, buf)
}

// shot_fixture is the tree the dialogs browse: the same one fixture.sh builds
// for the recorded demo, written from inside the binary so a shot needs no
// shell script and so the tree is always under the output directory.
shot_fixture :: proc(root: string) {
	for d in ([?]string {
		"Desktop",
		"Documents",
		"Downloads",
		"Music",
		"Pictures",
		"Videos",
		"Projects",
		"Photographs/Raw",
		".config",
	}) {
		_ = os.make_directory_all(fmt.tprintf("%s/%s", root, d))
	}

	f :: proc(root, rel: string, size: int) {
		shot_file(fmt.tprintf("%s/%s", root, rel), size)
	}

	f(root, "Photographs/sunset-over-the-harbour.png", 412000)
	f(root, "Photographs/harbour-at-dawn.jpg", 2380000)
	f(root, "Photographs/lighthouse.png", 861000)
	f(root, "Photographs/contact-sheet.pdf", 54000)
	f(root, "Photographs/notes-from-the-shoot.txt", 1800)
	f(root, "Photographs/résumé-du-voyage.txt", 940)
	f(root, "Photographs/日本-2026.jpg", 1740000)
	f(
		root,
		"Photographs/a-photograph-whose-filename-is-far-longer-than-any-column-could-ever-show-and-has-to-be-ellipsized.jpg",
		96000,
	)
	f(root, "Photographs/.hidden-contact-sheet.png", 1200)
	f(root, "Photographs/sunset.png", 310000)
	f(root, "Photographs/Raw/IMG_0001.dng", 2400000)
	f(root, "Photographs/Raw/IMG_0002.dng", 2340000)

	f(root, "Documents/annual-report.pdf", 180000)
	f(root, "Documents/invoice-2026-03.pdf", 42000)
	f(root, "Documents/letter.odt", 19000)
	f(root, "Documents/budget.csv", 3400)

	f(root, "Downloads/palmy-0.9.tar.gz", 840000)
	f(root, "Downloads/font-sample.ttf", 220000)
	f(root, "Music/overture.flac", 3800000)
	f(root, "Projects/notes.md", 2100)
	f(root, "Projects/main.odin", 14000)
	f(root, "sunset.png", 310000)
	f(root, "README.txt", 760)
}

shots :: proc(dir: string) -> int {
	if err := os.make_directory_all(dir); err != nil && !os.exists(dir) {
		fmt.eprintfln("pickdemo --shots: cannot create %s", dir)
		return 1
	}

	// Cloned, not temp: `p.offscreen_end` frees the temp allocator between
	// frames, so a tprintf string held across shots would dangle.
	root := strings.clone(fmt.tprintf("%s/.pickdemo-home", dir))
	shot_fixture(root)

	// The picker reads $HOME for its Home place, its crumbs and its `~`
	// abbreviation. Pointing it at the fixture is what keeps the real home
	// out of the picture entirely — there is no path in these PNGs that is
	// not inside the tree just built.
	_ = os.set_env("HOME", root)
	_ = os.set_env("XDG_CONFIG_HOME", fmt.tprintf("%s/.config", root))

	off := p.offscreen_create(SHOT_W, SHOT_H, 1, "w-full h-full bg-background text-foreground")
	defer p.offscreen_destroy(off)
	shot_load_fonts(&off.fonts)
	sc.register_shadcn_theme(false)
	p.set_text_gamma(1.8)

	d := Demo{}
	d.start = strings.clone(root)
	d.label = strings.clone("Nothing chosen yet")
	d.hint = strings.clone("Ctrl O to open, Ctrl S to save, Ctrl D for a folder")
	defer kit.pick_destroy(&d.pick)

	step :: proc(off: ^p.Offscreen, d: ^Demo) {
		ui := p.offscreen_begin(off)
		if kit.pick_active(&d.pick) {
			if res, done := kit.pick_draw(ui, &d.pick); done {
				take(d, res)
			}
		}
		body(ui, d)
		p.offscreen_end(off)
	}

	steps :: proc(off: ^p.Offscreen, d: ^Demo, n: int) {
		for _ in 0 ..< n {
			step(off, d)
		}
	}

	n := 0
	shot :: proc(off: ^p.Offscreen, dir, name: string, n: ^int) {
		out := fmt.tprintf("%s/%s.png", dir, name)
		if p.offscreen_write_png(off, out) {
			n^ += 1
			fmt.printfln("  %s", out)
		}
	}

	// 1. The dialog open on the fixture, which is the component this
	//    application exists to show.
	open_one(&d)
	steps(off, &d, 2)
	p.press_key(off, p.KEY_DOWN)
	steps(off, &d, 2)
	shot(off, dir, "app-pickdemo", &n)

	// 2. Inside a folder, with a filter applied and a file selected.
	kit.pick_go(&d.pick, fmt.tprintf("%s/Photographs", root))
	kit.pick_set_filter(&d.pick, 1) // Images
	steps(off, &d, 2)
	p.press_key(off, p.KEY_DOWN)
	p.press_key(off, p.KEY_DOWN)
	steps(off, &d, 2)
	shot(off, dir, "02-pickdemo-filtered", &n)

	// 3. Several files marked, which is the Open_Files mode.
	kit.pick_cancel(&d.pick)
	steps(off, &d, 2)
	open_many(&d)
	steps(off, &d, 2)
	kit.pick_go(&d.pick, fmt.tprintf("%s/Photographs", root))
	steps(off, &d, 2)
	for _ in 0 ..< 3 {
		p.press_key(off, p.KEY_SPACE)
		steps(off, &d, 1)
		p.press_key(off, p.KEY_DOWN)
		steps(off, &d, 1)
	}
	steps(off, &d, 1)
	shot(off, dir, "03-pickdemo-multiple", &n)

	// 4. Save As, over a name that already exists: the overwrite confirm.
	kit.pick_cancel(&d.pick)
	steps(off, &d, 2)
	save_as(&d)
	steps(off, &d, 2)
	clear(&d.pick.name_buf)
	append(&d.pick.name_buf, "sunset.png")
	d.pick.name_cur = len(d.pick.name_buf)
	d.pick.name_anchor = d.pick.name_cur
	steps(off, &d, 2)
	p.press_key(off, p.KEY_RETURN)
	steps(off, &d, 2)
	shot(off, dir, "04-pickdemo-overwrite", &n)

	// 5. The host window with a result in it. The dialog hands back an
	//    absolute path; the demo prints it, and here that path is inside the
	//    fixture, so it is shown the way the dialog itself shows a path.
	kit.pick_cancel(&d.pick)
	steps(off, &d, 2)
	delete(d.label)
	d.label = strings.clone(
		kit.pick_abbreviate(
			fmt.tprintf("%s/Photographs/sunset-over-the-harbour.png", root),
			"",
			context.temp_allocator,
		),
	)
	steps(off, &d, 2)
	shot(off, dir, "05-pickdemo-host", &n)

	fmt.printfln("pickdemo --shots: %d PNGs in %s", n, dir)
	return 0
}
