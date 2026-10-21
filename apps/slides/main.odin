package main

// palmy slides — a presentation editor.
//
//   slides                        open the built-in deck in the window
//   slides deck.json              open a deck
//   slides <command> ...          the command line; `slides --help` lists it
//   slides --selftest             the headless test suite
//
// Three panes: the slide sorter on the left with live thumbnails, the canvas in
// the middle, the inspector on the right. Presenting opens a second surface —
// a fullscreen wlr-layer-shell overlay — in this same process, and returns to
// the editor when it closes.
//
// Everything is reachable from the keyboard, because this compositor cannot
// synthesize a pointer click; the mouse paths are there for a real user, and
// the keys are what the demo drives. The command line (cli.odin) drives the
// same `invoke` the keys do, on a deck with no window.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import kit "kit:."
import p "palmy:."
import collabui "../../cloud/collab/ui"

tprintf :: fmt.tprintf

MAX_THUMBS :: 64

Mode :: enum u8 {
	Browse, // the editor, nothing capturing the keyboard
	Text, // editing an element's text in place
	Notes, // editing the slide's speaker notes
	Menu, // the command menu has the keyboard
	Help, // the cheatsheet is up
}

Drag :: enum u8 {
	None,
	Move,
	Resize,
}

// Prop is the inspector row the +/- keys act on. One adjustable property at a
// time is what makes a keyboard-only inspector workable.
Prop :: enum u8 {
	Fill,
	Fill_Alpha,
	Stroke,
	Stroke_Width,
	Radius,
	Opacity,
	Rotation,
	Style,
	Size,
	Align,
	Valign,
}

PROP_NAMES := [Prop]string {
	.Fill         = "Fill",
	.Fill_Alpha   = "Fill alpha",
	.Stroke       = "Stroke",
	.Stroke_Width = "Stroke width",
	.Radius       = "Corner radius",
	.Opacity      = "Opacity",
	.Rotation     = "Rotation",
	.Style        = "Text style",
	.Size         = "Text size",
	.Align        = "Align",
	.Valign       = "Vertical align",
}

// Editor is the text buffer behind in-place editing and the notes pane. palmy's
// `text_field` is single line and owns its own focus, which is not what editing
// a text box on a canvas needs, so the caret model lives here.
Editor :: struct {
	buf:   [dynamic]u8,
	caret: int,
}

// Thumb gives `p.pixels` a stable pointer per sorter row.
Thumb :: struct {
	st: ^St,
	i:  int,
}

St :: struct {
	deck:         Deck,
	path:         string,
	exe_dir:      string,
	imgs:         Img_Cache,
	fonts:        ^p.Fonts,

	slide:        int,
	sel:          int, // selected element, -1 for none
	mode:         Mode,
	prop:         Prop,
	ed:           Editor,

	snap:         bool,
	guides:       [dynamic]Guide,

	// Canvas geometry from the last painted frame, so the pointer can be
	// mapped back into slide coordinates.
	canvas:       p.Rect,
	canvas_sc:    f32,

	drag:         Drag,
	handle:       int,
	grab:         [2]f32, // where in the element the grab started, slide units
	orig:         Element,

	undo:         [dynamic]Deck,
	redo:         [dynamic]Deck,
	last_push:    f64,
	toast:        string,
	toast_t:      f64,
	dirty:        bool,
	quit_armed:   bool,

	menu_i:       int,
	help_top:     int,

	// Projector
	want_present: bool,
	pres_start:   f64,
	pres_notes:   bool,
	pres_black:   bool,

	sorter_w:     f32,
	inspect_w:    f32,
	thumb_w:      f32,
	thumbs:       [MAX_THUMBS]Thumb,
	sorter_top:   int,
	sorter_vis:   int,
	show_notes:   bool,
	footer:       bool,
	mouse:        [2]f32,
	moved:        bool,
	started:      bool,
	quit:         bool,

	collab_args:  collabui.Args,
}

// state_new is the editor's state with no window behind it: what a fresh
// window starts from, and what every command of the command line runs on.
state_new :: proc(exe_dir: string) -> ^St {
	st := new(St)
	st.exe_dir = exe_dir
	st.imgs = img_cache_make(exe_dir)
	st.guides = make([dynamic]Guide)
	st.sel = -1
	st.snap = true
	st.footer = true
	st.show_notes = true
	st.path = default_deck_path()
	return st
}

main :: proc() {
	// --collab and its companions (--as, --title, --link, --script,
	// --offline) belong to the window. Anything else goes to the command line
	// untouched: collabui.parse_args takes a --title wherever it finds one,
	// and `slides add deck.json --title Agenda` needs it.
	collab_line := false
	for a in os.args[1:] {
		if a == "--collab" {
			collab_line = true
		}
	}
	ca: collabui.Args
	args := os.args[1:]
	if collab_line {
		rest_args: [dynamic]string
		ca, rest_args = collabui.parse_args(os.args[1:])
		args = rest_args[:]
	} else if code, handled := kit.cli_args(surface(), args); handled {
		// The command line answers everything except an empty line and a
		// bare deck path, which are the window's.
		os.exit(code)
	}

	exe_dir := exe_directory()
	st := state_new(exe_dir)

	// What is left is the window's: a deck path, and — kept so that every
	// invocation that worked before still does — the older spellings after
	// it (`slides deck.json --pdf out.pdf`). With no path first, those are
	// commands, and the kit has already run them.
	deck_path := ""
	out_file := ""
	mode := ""
	for i := 0; i < len(args); i += 1 {
		a := args[i]
		switch {
		case a == "--export", a == "--pptx", a == "--pdf", a == "--shots":
			mode = a[2:]
			if i + 1 < len(args) && !strings.has_prefix(args[i + 1], "--") {
				out_file = args[i + 1]
				i += 1
			}
		case strings.has_prefix(a, "--"):
			fmt.eprintfln("slides: unknown option %s (slides --help lists the commands)", a)
			os.exit(2)
		case:
			deck_path = a
		}
	}

	if deck_path != "" {
		// The kit's takes_word has refused a first word that is not a file,
		// but a --collab line never reaches the kit, and the deck may be a
		// later word. A deck that is not there is an error, not an empty
		// editor.
		if !os.exists(deck_path) {
			fmt.eprintfln("slides: %q is neither a command nor a deck (slides --help lists the commands)", deck_path)
			os.exit(kit.EXIT_USAGE)
		}
		d, err := load_deck(deck_path)
		if err != "" {
			fmt.eprintfln("slides: %s", err)
			os.exit(1)
		}
		st.deck = d
		st.path = strings.clone(deck_path)
	} else {
		st.deck = fixture_deck()
	}

	switch mode {
	case "export", "pptx", "pdf":
		f: Export_Format = mode == "pptx" ? .Pptx : (mode == "pdf" ? .Pdf : .Png)
		out := out_file
		if out == "" {
			out = f == .Png ? default_export_dir() : tprintf("%s/deck.%s", default_export_dir(context.temp_allocator), mode)
		}
		fonts: p.Fonts
		fonts_headless(&fonts)
		n, err := deck_export(&st.deck, out, f, &fonts, &st.imgs)
		if err != "" {
			fmt.eprintfln("slides: %s", err)
			os.exit(1)
		}
		if f == .Png {
			fmt.printfln("exported %d slides and a contact sheet to %s", n - 1, out)
		} else {
			fmt.printfln("wrote %s (%d slides)", out, len(st.deck.slides))
		}
		return
	case "shots":
		os.exit(shots(out_file != "" ? out_file : "slides-shots"))
	}

	if ca.doc != "" {
		st.collab_args = ca
		if ca.script != "" {
			os.exit(run_script(st, ca))
		}
	}

	// The editor and the projector are two surfaces, opened one at a time in
	// this one process: palmy is one window per process, and a layer-shell
	// overlay cannot be a child of a toplevel.
	for !st.quit {
		run_editor(st)
		if st.want_present && !st.quit {
			st.want_present = false
			run_present(st)
		}
	}
}

// exe_directory is where the binary lives, which is where the built-in deck's
// pictures are looked for. The kernel's answer first: argv[0] is only a name
// when the binary was found on $PATH or run by `palm`.
exe_directory :: proc() -> string {
	exe := os.args[0]
	if path, err := os.get_executable_path(context.temp_allocator); err == nil && path != "" {
		exe = path
	}
	if slash := strings.last_index_byte(exe, '/'); slash > 0 {
		return strings.clone(exe[:slash])
	}
	return strings.clone(".")
}

// ---------------------------------------------------------------------------
// The editor window
// ---------------------------------------------------------------------------

run_editor :: proc(st: ^St) {
	app, err := kit.start(
		{
			title = "palmy slides",
			app_id = "palmy",
			width = 1320,
			height = 860,
			min_width = 900,
			min_height = 600,
			root_class = "w-full h-full flex-col bg-background text-foreground overflow-hidden",
		},
		true,
	)
	if err != "" {
		fmt.eprintfln("slides: %s", err)
		os.exit(1)
	}
	defer p.destroy(app)
	register_chrome_theme()

	// A new window restarts the frame clock, so a toast from before the
	// projector would otherwise hang around until the new clock caught up.
	st.toast = ""

	st.fonts = &app.fonts
	if st.collab_args.doc != "" && !collab.on {
		if e := collab_start(st, app, st.collab_args); e != "" {
			fmt.eprintfln("slides: %s", e)
			os.exit(1)
		}
	} else if collab.on && collab.ui.sess != nil {
		collab.ui.sess.cfg.wake_ctx = app
	}
	for i in 0 ..< MAX_THUMBS {
		st.thumbs[i] = {st, i}
	}

	for ui in p.frames(app) {
		free_all(context.temp_allocator)
		st.fonts = ui.fonts

		st.moved = st.started && st.mouse != p.mouse_pos(ui)
		st.mouse = p.mouse_pos(ui)
		st.started = true

		clamp_state(st)
		handle_keys(ui, app, st)
		collab_tick(ui, st)
		clamp_state(st)
		build(ui, st)
		mouse_edit(ui, st)

		// The caret blinks through `caret_on` (see `build`), which wakes the
		// loop once per blink edge; the toast expires with one wake at its
		// deadline. Both used to hold the editor at vsync.
		if st.toast != "" {
			left := st.toast_t - now_s(ui)
			if left <= 0 {
				// This frame still drew the toast; one more takes it off
				// the screen.
				st.toast = ""
				p.redraw(ui)
			} else {
				p.wake_after(ui, secs(left) + time.Millisecond)
			}
		}
		if st.want_present || st.quit {
			p.quit_app(app)
		}
	}
	// A window closed by the compositor is a quit unless we are off to present.
	if !st.want_present {
		st.quit = true
	}
}

clamp_state :: proc(st: ^St) {
	if len(st.deck.slides) == 0 {
		append(&st.deck.slides, slide_make(.Title))
	}
	st.slide = clamp(st.slide, 0, len(st.deck.slides) - 1)
	s := cur_slide(st)
	if st.sel >= len(s.elems) {
		st.sel = len(s.elems) - 1
	}
	if st.sel < 0 {
		st.sel = -1
		if st.mode == .Text {
			st.mode = .Browse
		}
	}
}

cur_slide :: proc(st: ^St) -> ^Slide {
	return &st.deck.slides[clamp(st.slide, 0, len(st.deck.slides) - 1)]
}

cur_elem :: proc(st: ^St) -> ^Element {
	s := cur_slide(st)
	if st.sel < 0 || st.sel >= len(s.elems) {
		return nil
	}
	return &s.elems[st.sel]
}

// toast takes a nil context so that the headless tests can drive the same
// commands the keyboard does.
toast :: proc(st: ^St, ui: ^p.Ctx, msg: string) {
	st.toast = strings.clone(msg, context.allocator)
	st.toast_t = ui == nil ? 0 : now_s(ui) + 3.5
}

// Nothing that times anything here reads `ui.now` in a window: palmy clamps
// `dt` to 0.1 s so a stalled frame cannot teleport an animation, which means
// `ui.now` only tracks real time while frames are frequent, and this window
// now sleeps between events. A presenter clock run off it would gain a tenth
// of a second per tick. Offscreen there is no window to wake and `ui.now` is
// the renderer's synthetic time, which keeps the tests deterministic.
START_TICK := time.tick_now()

now_s :: proc(ui: ^p.Ctx) -> f64 {
	if ui == nil || ui.app == nil {
		return ui == nil ? 0 : ui.now
	}
	return time.duration_seconds(time.tick_since(START_TICK))
}

// secs turns a number of seconds into a wake delay.
secs :: proc(s: f64) -> time.Duration {
	return time.Duration(max(s, 0) * f64(time.Second))
}

// register_chrome_theme is the shadcn dark palette with a workspace colour
// added: the canvas behind a slide has to be darker than any panel, the way
// every editor's artboard background is.
register_chrome_theme :: proc() {
	c :: p.hex
	p.register_color("background", c(0x0c0c0e))
	p.register_color("foreground", c(0xfafafa))
	p.register_color("card", c(0x16161a))
	p.register_color("card-foreground", c(0xfafafa))
	p.register_color("popover", c(0x1c1c20))
	p.register_color("popover-foreground", c(0xfafafa))
	p.register_color("primary", c(0xfafafa))
	p.register_color("primary-foreground", c(0x171717))
	p.register_color("secondary", c(0x242429))
	p.register_color("secondary-foreground", c(0xfafafa))
	p.register_color("muted", c(0x1d1d21))
	p.register_color("muted-foreground", c(0x9b9ba4))
	p.register_color("accent", c(0x2e2e35))
	p.register_color("accent-foreground", c(0xfafafa))
	p.register_color("destructive", c(0xff6467))
	p.register_color("destructive-foreground", c(0xfafafa))
	p.register_color("border", c(0x27272c))
	p.register_color("input", c(0x27272c))
	p.register_color("ring", c(0x6366f1))
	p.register_color("workspace", c(0x06060a))
}

// ---------------------------------------------------------------------------
// The projector
//
// A fullscreen wlr-layer-shell overlay with an exclusive keyboard grab: that is
// what a presentation is, and it is also the most invasive thing this program
// does, because while it is up it owns every key on the machine. Escape, q and
// F5 all leave, and the surface goes away with the process whatever happens.
// ---------------------------------------------------------------------------

run_present :: proc(st: ^St) {
	app, err := kit.start(
		{
			title = "palmy slides projector",
			app_id = "palmy-slides-projector",
			// 0x0 anchored to all four edges is how a layer surface asks for
			// the whole output; the compositor answers with the real size.
			width = 0,
			height = 0,
			root_class = "w-full h-full bg-black overflow-hidden",
			layer = true,
			layer_level = .Overlay,
			layer_keyboard = .Exclusive,
			layer_anchor = {.Top, .Bottom, .Left, .Right},
			exclusive_zone = -1,
		},
		true,
	)
	if err != "" {
		fmt.eprintfln("slides: cannot open the projector: %s", err)
		return
	}
	defer p.destroy(app)
	register_chrome_theme()
	st.fonts = &app.fonts
	st.pres_black = false
	st.pres_start = 0
	st.toast = ""

	for ui in p.frames(app) {
		free_all(context.temp_allocator)
		st.fonts = ui.fonts

		if p.key_pressed(ui, p.KEY_ESCAPE) ||
		   p.key_pressed(ui, 'q') ||
		   p.key_pressed(ui, p.KEY_F5) {
			p.quit_app(app)
		}
		// Counted, not tested: a presenter tapping space three times in a
		// second must not lose a slide to a frame boundary.
		fwd :=
			p.key_count(ui, p.KEY_RIGHT) +
			p.key_count(ui, p.KEY_DOWN) +
			p.key_count(ui, p.KEY_SPACE) +
			p.key_count(ui, p.KEY_RETURN) +
			p.key_count(ui, p.KEY_PAGE_DOWN)
		back :=
			p.key_count(ui, p.KEY_LEFT) +
			p.key_count(ui, p.KEY_UP) +
			p.key_count(ui, p.KEY_BACKSPACE) +
			p.key_count(ui, p.KEY_PAGE_UP)
		if fwd > 0 {
			st.slide = min(st.slide + fwd, len(st.deck.slides) - 1)
		}
		if back > 0 {
			st.slide = max(st.slide - back, 0)
		}
		if p.key_pressed(ui, p.KEY_HOME) {
			st.slide = 0
		}
		if p.key_pressed(ui, p.KEY_END) {
			st.slide = len(st.deck.slides) - 1
		}
		if p.key_pressed(ui, p.KEY_TAB) {
			st.pres_notes = !st.pres_notes
		}
		if p.key_pressed(ui, 'b') {
			st.pres_black = !st.pres_black
		}
		st.sel = -1
		if st.pres_start == 0 {
			st.pres_start = max(now_s(ui), 1e-9)
		}

		build_present(ui, st)
	}
}
