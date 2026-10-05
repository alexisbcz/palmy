// `track shots <dir>`: render the window offscreen and write PNGs.
//
// No compositor and no window: the same `keys` and `frame` the window runs,
// driven through palmy's offscreen renderer, against a private store written
// under the output directory. Nothing in a picture comes from the person's
// own tracker.
package main

import "core:fmt"
import "core:os"
import "core:strings"
import kit "kit:."
import p "palmy:."
import sc "shadcn:."

SHOT_W :: 1280
SHOT_H :: 820

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
}

// shots renders every view. When `PALM_TRACK_DIR` already points somewhere
// with issues in it, those are what gets drawn — which is how the TODO.md
// import is photographed. Otherwise a fixture graph is written first, chosen
// to have the shapes a layered drawing has to survive: a diamond, a long
// edge spanning three columns, a fan-out and a fan-in.
shots :: proc(dir: string, identity: string) -> int {
	if err := os.make_directory_all(dir, os.perm(0o700)); err != nil && !os.exists(dir) {
		fmt.eprintfln("track shots: cannot create %s", dir)
		return 0
	}
	if os.get_env("PALM_TRACK_DIR", context.temp_allocator) == "" {
		store := fmt.tprintf("%s/.store", dir)
		shot_fixture(store)
		_ = os.set_env("PALM_TRACK_DIR", store)
	}

	off := p.offscreen_create(
		SHOT_W,
		SHOT_H,
		1,
		"w-full h-full flex-col bg-background text-foreground overflow-hidden",
	)
	defer p.offscreen_destroy(off)
	shot_fonts(off)

	a := new(App_State)
	a.identity = identity
	a.zoom = 0
	a.detail = true
	a.store = store_open(a.identity)
	a.graph = graph_build(&a.store)
	app_rebuild_dag(a)
	select_first(a)

	n := 0
	step :: proc(off: ^p.Offscreen, a: ^App_State) {
		ui := p.offscreen_begin(off)
		keys(ui, a)
		frame(ui, a)
		p.offscreen_end(off)
	}
	settle :: proc(off: ^p.Offscreen, a: ^App_State, times := 3) {
		for _ in 0 ..< times {
			step(off, a)
		}
	}
	shot :: proc(off: ^p.Offscreen, dir, name: string, n: ^int) {
		path := fmt.tprintf("%s/%s", dir, name)
		if p.offscreen_write_png(off, path) {
			n^ += 1
			fmt.printfln("  %s", path)
		} else {
			fmt.eprintfln("  could not write %s", path)
		}
	}

	a.view = .Ready
	settle(off, a)
	shot(off, dir, "app-track.png", &n)

	a.view = .List
	settle(off, a)
	shot(off, dir, "02-track-list.png", &n)

	a.view = .Board
	settle(off, a)
	shot(off, dir, "03-track-board.png", &n)

	a.view = .Graph
	settle(off, a)
	shot(off, dir, "04-track-graph.png", &n)

	// The graph with a node selected, which is the state the edge
	// highlighting exists for: one issue's own edges in full strength, the
	// rest faded.
	if len(a.store.issues) > 2 {
		best, most := 0, -1
		for i in 0 ..< len(a.store.issues) {
			score := len(a.graph.dependants[i]) + len(a.graph.deps[i])
			if score > most {
				best, most = i, score
			}
		}
		a.sel = best
		settle(off, a)
		shot(off, dir, "05-track-graph-focus.png", &n)
	}

	// The graph with the closed issues shown too, which is denser and the
	// harder case for the layout.
	a.show_closed = true
	app_rebuild_dag(a)
	settle(off, a)
	shot(off, dir, "06-track-graph-all.png", &n)
	a.show_closed = false
	app_rebuild_dag(a)

	// The detail pane on an issue that carries a prompt, which is the
	// agent-facing half of the application.
	a.view = .List
	for &it, i in a.store.issues {
		if it.prompt != "" {
			a.sel = i
			break
		}
	}
	settle(off, a)
	shot(off, dir, "07-track-prompt.png", &n)

	// And one carrying a stale verification, which is the point of the whole
	// application and should be visible without reading any text.
	for &it, i in a.store.issues {
		if it.verdict == .Stale {
			a.sel = i
			break
		}
	}
	settle(off, a)
	shot(off, dir, "08-track-stale.png", &n)

	return n
}

// shot_fixture writes a graph with the shapes a layered drawing has to
// survive. Invented entirely.
shot_fixture :: proc(dir: string) {
	_ = os.make_directory_all(dir, os.perm(0o700))
	Fix :: struct {
		id, title, state, project, assignee, labels, deps, verify, verified: string,
		prompt: string,
	}
	fixtures := [?]Fix {
		{"P1", "Frame loop wakes from another thread", "done", "Toolkit", "agent:claude", "toolkit", "", "", "", ""},
		{"P2", "One-shot timer on the frame loop", "done", "Toolkit", "agent:claude", "toolkit", "P1", "", "", ""},
		{"P3", "flex-wrap rows report their real height", "doing", "Toolkit", "alex", "toolkit, layout", "", "test -d palmy", "true", ""},
		{"P4", "Multi-line text area", "todo", "Toolkit", "", "toolkit, text", "P3", "", "", `Add a multi-line text area to palmy, in `+"`palmy/widgets.odin`"+`.

Four applications have already solved parts of this and you should read them
rather than invent.

  - the caret round trip over every rune boundary
  - the lines partition the text exactly

Report the assertion count.`},
		{"P5", "Interactive input, slider and progress", "todo", "Toolkit", "agent:claude", "toolkit", "P4", "", "", ""},
		{"P6", "Wire bidi into the text path", "todo", "Toolkit", "", "toolkit, text, rtl", "P2, P4", "! grep -q bidi_resolve palmy/font.odin", "stale", ""},
		{"P7", "Parity covers palmy's own widgets", "todo", "Tests", "", "tests", "P5", "", "", ""},
		{"P8", "The shared CLI convention", "review", "CLI", "agent:claude", "cli", "P1", "test -f apps/kit/cli.odin", "true", ""},
		{"P9", "Bring the applications up to it", "todo", "CLI", "", "cli", "P8", "", "", ""},
		{"P10", "Declarative package layer", "todo", "Packages", "agent:claude", "packages", "P8", "", "", ""},
		{"P11", "Composer drafts autosave", "todo", "Applications", "", "mail", "P4", "", "", ""},
		{"P12", "Address autocomplete", "todo", "Applications", "", "mail", "P4, P5", "", "", ""},
		{"P13", "Regex find in documents", "todo", "Applications", "", "docs", "P5", "", "", ""},
		{"P14", "Arabic and Hebrew books read correctly", "blocked", "Applications", "", "reader, rtl", "P6", "", "", ""},
		{"P15", "Filenames in the picker read correctly", "blocked", "Applications", "", "picker, rtl", "P6", "", "", ""},
		{"P16", "The web backend", "todo", "Ports", "", "long", "P7, P9", "", "", ""},
		{"P17", "Emoji ZWJ sequences", "wontfix", "Known-unfixed", "", "typography", "", "", "", ""},
		{"P18", "DHT and PEX in torrent", "wontfix", "Known-unfixed", "", "torrent", "", "", "", ""},
	}
	for f in fixtures {
		it := Issue {
			id       = f.id,
			title    = f.title,
			state    = f.state,
			project  = f.project,
			assignee = f.assignee,
			labels   = split_list(f.labels, context.temp_allocator),
			deps     = split_list(f.deps, context.temp_allocator),
			verify   = f.verify,
			prompt   = f.prompt,
			created  = "2026-10-01T09:00:00Z",
			updated  = "2026-10-05T09:00:00Z",
		}
		switch f.verified {
		case "true":
			it.verdict = .True
			it.checked = "2026-10-05T09:00:00Z"
		case "stale":
			it.verdict = .Stale
			it.checked = "2026-10-05T09:00:00Z"
		}
		path := fmt.tprintf("%s/%s-%s.md", dir, f.id, slug(f.title))
		_ = os.write_entire_file(path, transmute([]u8)issue_text(&it, context.temp_allocator))
	}
	sp := fmt.tprintf("%s/%s", dir, STATES_FILE)
	if !os.exists(sp) {
		_ = os.write_entire_file(sp, transmute([]u8)string(STATES_TEMPLATE))
	}
	_ = strings.has_prefix("", "")
}
