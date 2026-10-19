// `forge shots <dir> [--dark]`: render the window offscreen and write PNGs.
//
// The pictures are of a real forge: the same session rules as the window
// (FORGE_TOKEN, PALM_IDENTITY, or the person's own session), against the
// stack and the forge server cloud/forge/demo.sh leaves running. Nothing is
// mocked; what a screenshot shows is what the database let that session see.
package main

import "core:fmt"
import "core:os"
import "core:strings"
import wire "forge:wire"
import kit "kit:."
import p "palmy:."
import sc "shadcn:."

SHOT_W :: 1320
SHOT_H :: 860

// how far the review-comment shot scrolls the files view
scroll_px := 640

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
	for path in ([?]string{"/usr/share/fonts/TTF/JetBrainsMonoNerdFont-Regular.ttf", "/usr/share/fonts/TTF/DejaVuSansMono.ttf", "/usr/share/fonts/liberation/LiberationMono-Regular.ttf"}) {
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

shots :: proc(dir: string, dark: bool) -> int {
	if err := os.make_directory_all(dir); err != nil && !os.exists(dir) {
		fmt.eprintfln("forge shots: cannot create %s", dir)
		return 0
	}
	off := p.offscreen_create(SHOT_W, SHOT_H, 1, "w-full h-full flex-col bg-background text-foreground overflow-hidden")
	defer p.offscreen_destroy(off)
	shot_fonts(off, dark)

	a := new(App)
	a.dark = dark
	app_init(a)
	if a.err != "" {
		fmt.eprintfln("forge shots: %s", a.err)
	}
	suffix := "dark" if dark else "light"
	n := 0
	settle :: proc(off: ^p.Offscreen, a: ^App) {
		for _ in 0 ..< 3 {
			ui := p.offscreen_begin(off)
			frame(ui, a)
			p.offscreen_end(off)
		}
	}
	snap :: proc(off: ^p.Offscreen, a: ^App, dir, name, suffix: string, n: ^int) {
		settle(off, a)
		path := fmt.tprintf("%s/%s-%s.png", dir, name, suffix)
		if p.offscreen_write_png(off, path) {
			n^ += 1
			fmt.printfln("  %s", path)
		}
	}

	// the repository with the most going on
	best, score := 0, -1
	for r, i in wire.arr(a.repos) {
		s := wire.num(r, "open_pulls") * 10 + wire.num(r, "open_issues") + (5 if wire.str(r, "role") == "admin" else 0)
		if s > score {
			best, score = i, s
		}
	}
	if want := os.get_env("FORGE_SHOT_REPO", context.temp_allocator); want != "" {
		for r, i in wire.arr(a.repos) {
			if fmt.tprintf("%s/%s", wire.str(r, "owner_handle"), wire.str(r, "name")) == want {
				best = i
			}
		}
	}
	go_repo(a, best, .Code)
	snap(off, a, dir, "01-code", suffix, &n)

	// a source file, highlighted: at the top level, or one directory down
	is_source :: proc(name: string) -> bool {
		return strings.has_suffix(name, ".odin") || strings.has_suffix(name, ".c") || strings.has_suffix(name, ".py")
	}
	found := ""
	for e in wire.arr(a.tree, "entries") {
		if wire.str(e, "type") == "blob" && is_source(wire.str(e, "name")) {
			found = strings.clone(wire.str(e, "name"))
			break
		}
	}
	if found == "" {
		for e in wire.arr(a.tree, "entries") {
			if wire.str(e, "type") != "tree" {
				continue
			}
			dir_name := strings.clone(wire.str(e, "name"))
			sub := get_tree(&a.cl, a.ref, "", dir_name).value
			for s in wire.arr(sub, "entries") {
				if wire.str(s, "type") == "blob" && is_source(wire.str(s, "name")) {
					found = fmt.aprintf("%s/%s", dir_name, wire.str(s, "name"))
					break
				}
			}
			if found != "" {
				break
			}
		}
	}
	if found != "" {
		a.path = found
		load_page(a)
		snap(off, a, dir, "02-file", suffix, &n)
		a.path = ""
	}

	go_repo(a, best, .Commits)
	snap(off, a, dir, "03-commits", suffix, &n)
	if cs := wire.arr(a.commits, "commits"); len(cs) > 0 {
		open_commit(a, wire.str(cs[0], "sha"))
		snap(off, a, dir, "04-commit-diff", suffix, &n)
	}

	go_repo(a, best, .Issues)
	snap(off, a, dir, "05-issues", suffix, &n)
	if xs := wire.arr(a.items); len(xs) > 0 {
		open_item(a, xs[len(xs) - 1])
		snap(off, a, dir, "06-issue", suffix, &n)
	}

	go_repo(a, best, .Pulls)
	snap(off, a, dir, "07-pulls", suffix, &n)
	pulls := wire.arr(a.items)
	// an open pull request if there is one, else the most recent
	pick := -1
	for x, i in pulls {
		if wire.str(x, "state") == "open" {
			pick = i
			break
		}
	}
	if pick < 0 && len(pulls) > 0 {
		pick = 0
	}
	if pick >= 0 {
		open_item(a, pulls[pick])
		a.pull_view = .Conversation
		snap(off, a, dir, "08-pull", suffix, &n)
		a.pull_view = .Files
		snap(off, a, dir, "09-pull-files", suffix, &n)
		// further down: the review's line comment, under its line
		settle(off, a)
		p.move_pointer(off, 760, 600)
		p.scroll_by(off, 0, f32(scroll_px))
		snap(off, a, dir, "10-pull-review-comment", suffix, &n)
		p.scroll_by(off, 0, -f32(scroll_px))
		a.pull_view = .Conversation
	}

	go_repo(a, best, .Settings)
	snap(off, a, dir, "11-settings", suffix, &n)

	a.screen = .Tokens
	load_page(a)
	snap(off, a, dir, "12-tokens", suffix, &n)

	a.screen = .New_Repo
	append(&a.name_buf, ..transmute([]u8)string("field-notes"))
	snap(off, a, dir, "13-new-repo", suffix, &n)
	clear(&a.name_buf)

	a.screen = .Activity
	load_page(a)
	snap(off, a, dir, "14-activity", suffix, &n)
	return n
}
