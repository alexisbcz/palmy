package main

// `archive --shots <dir>`: render the interface offscreen and write PNGs.
//
// No compositor and no window: the same tree, layout and rasterizer the window
// uses, painted into a pixel buffer. It is the quick way to check that the tree
// view, the side panel and the confirmation dialog still line up.
//
// The archive it opens is built here, in a scratch directory of its own, from
// files this proc wrote. Nothing of the user's is listed, read or extracted,
// and no path from the user's home directory reaches a pixel.

import "core:fmt"
import "core:os"
import "core:strings"
import kit "kit:."
import p "palmy:."

// A neutral scratch directory, deliberately not under the user's home or
// under the output directory: `st.archive` and `st.dest` are drawn in the
// header and the side panel, so both have to be paths that are safe to show.
SHOT_WORK :: "/tmp/palmy-archive-shot"

shot_fonts :: proc(f: ^p.Fonts) {
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

// shot_fixture writes a small tree and packs it with bsdtar. The only command
// run is one that creates a file in SHOT_WORK.
shot_fixture :: proc() -> string {
	_ = os.remove_all(SHOT_WORK)
	_ = os.make_directory_all(fmt.tprintf("%s/src/palmy-demo/src", SHOT_WORK))
	_ = os.make_directory_all(fmt.tprintf("%s/src/palmy-demo/docs", SHOT_WORK))
	_ = os.make_directory_all(fmt.tprintf("%s/src/palmy-demo/assets/icons", SHOT_WORK))

	write :: proc(rel: string, body: string) {
		_ = os.write_entire_file(fmt.tprintf("%s/src/palmy-demo/%s", SHOT_WORK, rel), transmute([]u8)body)
	}
	write("README.md", "# palmy-demo\n\nA fixture tree, written by `archive --shots`.\n")
	write("LICENSE", strings.repeat("MIT, with the usual paragraph of disclaimer.\n", 24, context.temp_allocator))
	write("src/main.odin", "package main\n\nmain :: proc() {}\n")
	write("src/render.odin", strings.repeat("// one line of the renderer\n", 300, context.temp_allocator))
	write("src/shade.odin", strings.repeat("// a shading helper\n", 140, context.temp_allocator))
	write("docs/guide.md", strings.repeat("A paragraph of the guide.\n\n", 90, context.temp_allocator))
	write("docs/changelog.md", "## 0.2\n\n- the tree view\n- the confirmation step\n")
	write("assets/icons/folder.svg", "<svg viewBox=\"0 0 24 24\"></svg>\n")
	write("assets/icons/file.svg", "<svg viewBox=\"0 0 24 24\"></svg>\n")
	write("assets/logo.png", strings.repeat("x", 4096, context.temp_allocator))

	out := fmt.tprintf("%s/palmy-demo.zip", SHOT_WORK)
	if _, ok := kit.run({"bsdtar", "-a", "-c", "-f", out, "-C", fmt.tprintf("%s/src", SHOT_WORK), "palmy-demo"}, context.temp_allocator);
	   !ok {
		return ""
	}
	// Cloned: `offscreen_end` resets the temp allocator every frame, so a
	// tprintf string handed across two shots would dangle.
	return strings.clone(out)
}

shots :: proc(dir: string) -> int {
	if err := os.make_directory_all(dir, os.perm(0o755)); err != nil && !os.exists(dir) {
		fmt.eprintfln("archive: cannot create %s", dir)
		return 1
	}
	if !kit.has_tool("bsdtar") {
		fmt.eprintln("archive --shots: bsdtar is not installed")
		return 1
	}

	zip := shot_fixture()
	if zip == "" {
		fmt.eprintln("archive --shots: could not build the fixture archive")
		return 1
	}
	items, lerr := list_archive(zip)
	if lerr != "" {
		fmt.eprintfln("archive --shots: listing the fixture failed: %s", lerr)
		return 1
	}

	off := p.offscreen_create(
		WIN_W,
		WIN_H,
		1,
		"w-full h-full flex-col bg-background text-foreground overflow-hidden",
	)
	defer p.offscreen_destroy(off)
	shot_fonts(&off.fonts)
	register_dark_theme()
	p.set_text_gamma(1.8)

	st := St {
		rows       = make([dynamic]Row),
		owned      = make([dynamic]string),
		marks      = make(map[string]bool),
		filter     = make([dynamic]u8),
		edit       = make([dynamic]u8),
		found      = make([dynamic]string),
		stage      = make([dynamic]string),
		have_tar   = true,
		items      = items,
		archive    = strings.clone(zip),
		dest       = strings.clone(fmt.tprintf("%s/out/palmy-demo", SHOT_WORK)),
		mode       = .Browse,
		create_src = strings.clone(fmt.tprintf("%s/src/palmy-demo", SHOT_WORK)),
		create_out = strings.clone(fmt.tprintf("%s/out/palmy-demo.tar.zst", SHOT_WORK)),
	}

	step :: proc(off: ^p.Offscreen, st: ^St) {
		ui := p.offscreen_begin(off)
		collect(st, nil)
		handle_keys(ui, nil, st)
		rebuild_rows(st)
		build(ui, st)
		p.offscreen_end(off)
	}

	shot :: proc(off: ^p.Offscreen, dir, name: string) {
		out := fmt.tprintf("%s/%s.png", dir, name)
		p.offscreen_write_png(off, out)
		fmt.printfln("  %s", out)
	}

	// Descend into the tree so the list has real rows, and mark two of them so
	// the side panel shows a selection rather than "everything".
	step(off, &st)
	p.press_key(off, p.KEY_RETURN) // into palmy-demo/
	step(off, &st)
	p.press_key(off, p.KEY_SPACE) // mark assets/, and advance
	step(off, &st)
	p.press_key(off, p.KEY_SPACE) // mark docs/
	step(off, &st)
	p.press_key(off, p.KEY_DOWN)
	step(off, &st)
	step(off, &st)
	shot(off, dir, "app-archive")

	// The confirmation step, which is the one screen worth looking at twice.
	p.press_key(off, 'e')
	step(off, &st)
	step(off, &st)
	shot(off, dir, "02-archive-confirm")
	p.press_key(off, p.KEY_ESCAPE)
	step(off, &st)

	// The filter, typed into the real buffer.
	p.press_key(off, '/')
	step(off, &st)
	p.type_text(off, "md")
	step(off, &st)
	step(off, &st)
	shot(off, dir, "03-archive-filter")
	p.press_key(off, p.KEY_ESCAPE)
	step(off, &st)

	// The create pane, over the fixture tree.
	p.press_key(off, 'n')
	step(off, &st)
	step(off, &st)
	shot(off, dir, "04-archive-create")
	p.press_key(off, p.KEY_ESCAPE)
	step(off, &st)

	_ = os.remove_all(SHOT_WORK)
	return 0
}
