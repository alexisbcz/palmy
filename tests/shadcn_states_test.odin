// shadcn's interactive states, reached for real and compared byte for byte.
//
// The parity suite draws every interaction state by *declaring* it:
// `sc.button(ui, "Button", .Default, .Default, sc.State{hover = true})`, and
// measures that against Chromium's capture of the same button with a real
// pointer over it. What it cannot see is whether an application, which gets
// its state from palmy -- a pointer over the node, Tab moving focus, a click,
// keystrokes into a field -- ends up drawing the same pixels. A 78-assertion
// harness proved that once and was lost with the scratchpad it lived in. This
// is its replacement, in the tree.
//
// Every case below is one of parity's interaction cases (the `@hover`,
// `@focus` and `@typed` captures harness/interact.mjs takes, `toggle-pressed`
// and `collapsible-open`), framed exactly as parity/odin/render frames it --
// the same canvas, the same offset and width from the capture's geometry, the
// same pinned Geist with kerning off, the same 1.8 text gamma, the shadcn
// light theme. For each it renders three things:
//
//   static  parity's own draw call, the declared state;
//   rest    the same widget built the way an application builds it, with its
//           state read from palmy, before anything has happened;
//   live    that widget after palmy has been driven into the state: the
//           pointer moved over it, Tab pressed, "Hello" typed, a click --
//           then left to settle, since the state change starts transitions.
//
// and asserts: palmy reports the state; live == static, byte for byte; rest
// != static, so the state is visible and the equality could fail; and, where
// parity has rendered this tree (parity/out/odin/<id>.png after
// `tools/diff-all.sh`, or $PARITY_ODIN_DIR, e.g. the build VM's
// ~/palmy-env/baseline/odin), static == parity's PNG, byte for byte, so the
// framing here is the one parity measures. Where no render exists that last
// check is skipped and the test log says so; the others always run.
//
// The open states of menus, selects, comboboxes, hover cards and the
// navigation menu are not here: each is a composition drawn from an `open`
// bool the application owns, with no widget-level interaction to drive, so a
// test of them would only be testing itself.
//
// WHY THE RENDERING HAPPENS IN @(init)
//
// The shadcn theme and the text gamma are process-wide, and the test runner
// runs tests on parallel threads. Registering the theme while other tests ran
// would race on palmy's token map (palmy_test.odin records it crashing the
// suite), and it would quietly change what widgets_test's "no theme" checks
// measure. So all rendering is done here, before the runner starts its
// threads; then the theme is reset, the two token sets other tests register
// from their own @(init) are registered again (whichever order the init
// procedures ran in), and the gamma goes back to 1. The @(test) procedures
// only read the stored results, and one of them checks the cleanup held.
package palmy_tests

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:encoding/json"
import "core:math"
import "core:os"
import "core:strings"
import "core:testing"
import stbi "vendor:stb/image"
import p "../palmy"
import sc "shadcn:."

@(private = "file")
TESTS_DIR :: #directory

@(private = "file")
Drive :: enum {
	Hover,
	Focus,
	Typed,
	Click,
}

// Live is the application's side: what it remembers between frames.
@(private = "file")
Live :: struct {
	hover, focus: bool,
	pressed:      bool, // a toggle's state, flipped by activation
	open:         bool, // a collapsible's state, flipped by activation
	buf:          [dynamic]u8,
	idx:          int, // the interactive node, as of the last frame
}

@(private = "file")
State_Case :: struct {
	id:          string,
	drive:       Drive,
	static_draw: proc(ui: ^p.Ctx),
	live_draw:   proc(ui: ^p.Ctx, l: ^Live),
	init_buf:    string,
	// invisible: the state has no look of its own. shadcn's checkbox and
	// switch style focus but not hover, so for those the check is the other
	// way round: hovered for real, they must draw exactly what they draw at
	// rest.
	invisible:   bool,
}

@(private = "file")
Result :: struct {
	id:          string,
	drive:       Drive,
	invisible:   bool,
	framed:      bool,
	reached:     bool, // palmy reported the state the driver asked for
	live_diff:   int, // pixels where live != static
	rest_diff:   int, // pixels where rest != static
	parity:      enum {
		Absent,
		Match,
		Mismatch,
		Wrong_Size,
	},
	parity_diff: int,
	parity_path: string,
}

@(private = "file")
g_results: [dynamic]Result
@(private = "file")
g_theme_restored: bool

// hit marks a node interactive and focusable, as an application does for
// anything it wants pointer and keyboard state from, and reads that state.
@(private = "file")
hit :: proc(ui: ^p.Ctx, l: ^Live, idx: int) {
	p.focusable(ui, idx)
	l.idx = idx
	l.hover = p.is_hovered(ui, idx)
	l.focus = p.focused(ui, idx)
}

@(private = "file")
button_case :: proc "contextless" ($ID: string, $V: sc.Variant, $D: Drive) -> State_Case {
	return {
		id = ID,
		drive = D,
		static_draw = proc(ui: ^p.Ctx) {
			sc.button(ui, "Button", V, .Default, D == .Hover ? sc.State{hover = true} : sc.State{focus = true})
		},
		live_draw = proc(ui: ^p.Ctx, l: ^Live) {
			idx := p.node_count(ui)
			// The state the application drew with is the one palmy reported
			// last frame: immediate mode's one-frame lag, settled below.
			sc.button(ui, "Button", V, .Default, sc.State{hover = l.hover, focus = l.focus})
			hit(ui, l, idx)
		},
	}
}

@(private = "file")
CASES := [?]State_Case {
	button_case("button-default@hover", .Default, .Hover),
	button_case("button-default@focus", .Default, .Focus),
	button_case("button-secondary@hover", .Secondary, .Hover),
	button_case("button-outline@hover", .Outline, .Hover),
	button_case("button-destructive@hover", .Destructive, .Hover),
	button_case("button-ghost@hover", .Ghost, .Hover),
	{
		id = "checkbox-default@hover",
		drive = .Hover,
		invisible = true,
		static_draw = proc(ui: ^p.Ctx) {sc.checkbox(ui, .Off, sc.State{hover = true})},
		live_draw = proc(ui: ^p.Ctx, l: ^Live) {
			idx := p.node_count(ui)
			sc.checkbox(ui, .Off, sc.State{hover = l.hover, focus = l.focus})
			hit(ui, l, idx)
		},
	},
	{
		id = "checkbox-default@focus",
		drive = .Focus,
		static_draw = proc(ui: ^p.Ctx) {sc.checkbox(ui, .Off, sc.State{focus = true})},
		live_draw = proc(ui: ^p.Ctx, l: ^Live) {
			idx := p.node_count(ui)
			sc.checkbox(ui, .Off, sc.State{hover = l.hover, focus = l.focus})
			hit(ui, l, idx)
		},
	},
	{
		id = "switch-off@hover",
		drive = .Hover,
		invisible = true,
		static_draw = proc(ui: ^p.Ctx) {sc.switch_(ui, false, .Default, sc.State{hover = true})},
		live_draw = proc(ui: ^p.Ctx, l: ^Live) {
			idx := p.node_count(ui)
			sc.switch_(ui, false, .Default, sc.State{hover = l.hover, focus = l.focus})
			hit(ui, l, idx)
		},
	},
	{
		id = "switch-off@focus",
		drive = .Focus,
		static_draw = proc(ui: ^p.Ctx) {sc.switch_(ui, false, .Default, sc.State{focus = true})},
		live_draw = proc(ui: ^p.Ctx, l: ^Live) {
			idx := p.node_count(ui)
			sc.switch_(ui, false, .Default, sc.State{hover = l.hover, focus = l.focus})
			hit(ui, l, idx)
		},
	},
	// The inputs: parity captures the display form (a picture of a field);
	// an application uses the editing form, palmy.text_field in shadcn's
	// clothes. Here the editing form is focused with Tab and typed into, and
	// has to come out as the picture -- with the caret in its off phase, the
	// one thing a capture of a blinking field cannot pin.
	{
		id = "input-default@focus",
		drive = .Focus,
		init_buf = "Ada Lovelace",
		static_draw = proc(ui: ^p.Ctx) {sc.input(ui, "Ada Lovelace", "", sc.State{focus = true})},
		live_draw = proc(ui: ^p.Ctx, l: ^Live) {
			idx := p.node_count(ui)
			sc.input(ui, &l.buf, "")
			l.idx = idx
			l.focus = p.focused(ui, idx)
		},
	},
	{
		id = "input-placeholder@focus",
		drive = .Focus,
		static_draw = proc(ui: ^p.Ctx) {sc.input(ui, "", "Email address", sc.State{focus = true})},
		live_draw = proc(ui: ^p.Ctx, l: ^Live) {
			idx := p.node_count(ui)
			sc.input(ui, &l.buf, "Email address")
			l.idx = idx
			l.focus = p.focused(ui, idx)
		},
	},
	{
		id = "input-placeholder@typed",
		drive = .Typed,
		static_draw = proc(ui: ^p.Ctx) {sc.input(ui, "Hello", "", sc.State{focus = true})},
		live_draw = proc(ui: ^p.Ctx, l: ^Live) {
			idx := p.node_count(ui)
			sc.input(ui, &l.buf, "Email address")
			l.idx = idx
			l.focus = p.focused(ui, idx)
		},
	},
	// Pressed and open: a click flips the application's bool, and the pointer
	// then leaves, since the capture has no pointer over it.
	{
		id = "toggle-pressed",
		drive = .Click,
		static_draw = proc(ui: ^p.Ctx) {
			sc.toggle_open(ui, true)
			p.icon(ui, sc.ICON_BOLD, "size-4")
			sc.toggle_end(ui)
		},
		live_draw = proc(ui: ^p.Ctx, l: ^Live) {
			idx := sc.toggle_open(ui, l.pressed)
			p.icon(ui, sc.ICON_BOLD, "size-4")
			sc.toggle_end(ui)
			p.focusable(ui, idx)
			l.idx = idx
			if p.activated(ui, idx) {
				l.pressed = !l.pressed
			}
		},
	},
	{
		id = "collapsible-open",
		drive = .Click,
		static_draw = proc(ui: ^p.Ctx) {sc.collapsible(ui, "Details", "Four files changed.", true)},
		live_draw = proc(ui: ^p.Ctx, l: ^Live) {
			idx := p.node_count(ui)
			sc.collapsible(ui, "Details", "Four files changed.", l.open)
			trigger := idx + 1 // the column, then the trigger button
			p.focusable(ui, trigger)
			l.idx = trigger
			if p.activated(ui, trigger) {
				l.open = !l.open
			}
		},
	},
}

// ---------------------------------------------------------------------------
// Framing, exactly as parity/odin/render does it
// ---------------------------------------------------------------------------

@(private = "file")
Frame :: struct {
	cw, ch:     int,
	w, dx, dy:  f32,
}

@(private = "file")
png_dims :: proc(path: string) -> (w, h: int, ok: bool) {
	data, err := os.read_entire_file_from_path(path, context.temp_allocator)
	if err != nil {
		return 0, 0, false
	}
	x, y, comp: i32
	if stbi.info_from_memory(raw_data(data), i32(len(data)), &x, &y, &comp) == 0 {
		return 0, 0, false
	}
	return int(x), int(y), true
}

@(private = "file")
parity_dir :: proc() -> string {
	return fmt.aprintf("%s../parity", TESTS_DIR)
}

// parity_render is where parity's own PNG of this case would be.
@(private = "file")
parity_render :: proc(id: string) -> string {
	if d := os.get_env("PARITY_ODIN_DIR", context.temp_allocator); d != "" {
		return fmt.aprintf("%s/%s.png", strings.trim_suffix(d, "/"), id)
	}
	return fmt.aprintf("%s/out/odin/%s.png", parity_dir(), id)
}

@(private = "file")
frame_of :: proc(id: string) -> (f: Frame, ok: bool) {
	data, err := os.read_entire_file_from_path(fmt.tprintf("%s/out/web/%s.json", parity_dir(), id), context.temp_allocator)
	if err != nil {
		return {}, false
	}
	v, perr := json.parse(data, allocator = context.temp_allocator)
	if perr != nil {
		return {}, false
	}
	obj, is := v.(json.Object)
	if !is {
		return {}, false
	}
	rect, has := obj["rect"].(json.Object)
	if !has {
		return {}, false
	}
	fw, _ := rect["w"].(json.Float)
	fh, _ := rect["h"].(json.Float)
	if off, has_off := obj["cropOffset"].(json.Object); has_off {
		ox, _ := off["x"].(json.Float)
		oy, _ := off["y"].(json.Float)
		f.dx, f.dy = f32(ox), f32(oy)
	}
	f.w = f32(fw)
	// The canvas is the reference image's size: parity's own render if there
	// is one, else the browser capture, else the element's box rounded up.
	if w, h, got := png_dims(parity_render(id)); got {
		f.cw, f.ch = w, h
	} else if w2, h2, got2 := png_dims(fmt.tprintf("%s/out/web/%s.png", parity_dir(), id)); got2 {
		f.cw, f.ch = w2, h2
	} else {
		f.cw, f.ch = int(math.ceil(f64(fw))), int(math.ceil(f64(fh)))
	}
	return f, fw > 0 && fh > 0
}

@(private = "file")
pin_fonts :: proc(f: ^p.Fonts) {
	f.no_kerning = true
	for pair in ([?]struct {
			file: string,
			wt:   p.Font_Weight,
		}{{"Geist-400.ttf", .Regular}, {"Geist-500.ttf", .Medium}, {"Geist-600.ttf", .Semibold}, {"Geist-700.ttf", .Bold}}) {
		path := fmt.tprintf("%s/web/public/fonts/%s", parity_dir(), pair.file)
		p.load_font(f, path, .Sans, pair.wt)
		p.load_font(f, path, .Mono, pair.wt)
	}
}

@(private = "file")
new_canvas :: proc(f: Frame) -> ^p.Offscreen {
	off := p.offscreen_create(f.cw, f.ch, 1, "bg-white text-foreground")
	p.offscreen_viewport(off, f32(f.cw), f32(f.ch))
	pin_fonts(&off.fonts)
	return off
}

// placed is parity's draw_case_frame: the component where the browser put it,
// at the width its container had.
@(private = "file")
placed_open :: proc(ui: ^p.Ctx, f: Frame) {
	p.div(ui, "absolute")
	p.style(ui).inset[p.LEFT] = p.px(f.dx)
	p.style(ui).inset[p.TOP] = p.px(f.dy)
	p.style(ui).w = p.px(f.w)
}

@(private = "file")
snapshot :: proc(off: ^p.Offscreen) -> []u32 {
	px := p.offscreen_pixels(off)
	out := make([]u32, len(px))
	copy(out, px)
	return out
}

@(private = "file")
count_diff :: proc(a, b: []u32) -> int {
	if len(a) != len(b) {
		return max(len(a), len(b))
	}
	n := 0
	for v, i in a {
		if v & 0xffffff != b[i] & 0xffffff {
			n += 1
		}
	}
	return n
}

// ---------------------------------------------------------------------------
// The rendering, once, before the test runner starts its threads
// ---------------------------------------------------------------------------

@(init)
render_shadcn_states :: proc "contextless" () {
	context = runtime.default_context()
	g_results = make([dynamic]Result)

	sc.register_shadcn_theme()
	p.set_text_gamma(1.8)

	for c in CASES {
		r := Result {
			id        = c.id,
			drive     = c.drive,
			invisible = c.invisible,
		}
		f, ok := frame_of(c.id)
		r.framed = ok
		if !ok {
			append(&g_results, r)
			free_all(context.temp_allocator)
			continue
		}

		// static: parity's own two frames.
		static_px: []u32
		{
			off := new_canvas(f)
			for _ in 0 ..< 2 {
				ui := p.offscreen_begin(off)
				placed_open(ui, f)
				c.static_draw(ui)
				p.end(ui)
				p.offscreen_end(off)
			}
			static_px = snapshot(off)
			r.parity_path = parity_render(c.id)
			if data, err := os.read_entire_file_from_path(r.parity_path, context.temp_allocator); err == nil {
				x, y, comp: i32
				img := stbi.load_from_memory(raw_data(data), i32(len(data)), &x, &y, &comp, 4)
				if img == nil || int(x) != f.cw || int(y) != f.ch {
					r.parity = .Wrong_Size
				} else {
					n := 0
					for i in 0 ..< int(x * y) {
						rgb := u32(img[i * 4]) << 16 | u32(img[i * 4 + 1]) << 8 | u32(img[i * 4 + 2])
						if rgb != static_px[i] & 0xffffff {
							n += 1
						}
					}
					r.parity_diff = n
					r.parity = n == 0 ? .Match : .Mismatch
				}
				if img != nil {
					stbi.image_free(img)
				}
			}
			p.offscreen_destroy(off)
		}

		// rest, then live: one application, driven.
		{
			off := new_canvas(f)
			l := Live{}
			l.buf = make([dynamic]u8)
			append(&l.buf, c.init_buf)
			frame :: proc(off: ^p.Offscreen, f: Frame, c: State_Case, l: ^Live) {
				ui := p.offscreen_begin(off)
				placed_open(ui, f)
				c.live_draw(ui, l)
				p.end(ui)
				p.offscreen_end(off)
			}
			// The caret blinks on ctx.now; every snapshot is taken in its off
			// phase (0.6 s into a 1.06 s period), the phase a field's picture
			// shows.
			caret_off :: proc(off: ^p.Offscreen) {
				off.ctx.now = math.floor(off.ctx.now / 1.06) * 1.06 + 1.06 + 0.8 - f64(off.dt)
			}
			for _ in 0 ..< 2 {
				frame(off, f, c, &l)
			}
			caret_off(off)
			frame(off, f, c, &l)
			rest_px := snapshot(off)

			target := p.node_rect(&off.ctx, l.idx)
			centre := [2]f32{target.x + target.w / 2, target.y + target.h / 2}
			switch c.drive {
			case .Hover:
				p.move_pointer(off, centre.x, centre.y)
			case .Focus:
				p.press_key(off, p.KEY_TAB)
			case .Typed:
				p.press_key(off, p.KEY_TAB)
				frame(off, f, c, &l)
				p.type_text(off, "Hello")
			case .Click:
				p.move_pointer(off, centre.x, centre.y)
				frame(off, f, c, &l)
				p.press(off)
				frame(off, f, c, &l)
				p.release(off)
				frame(off, f, c, &l)
				// Away, and off the canvas: the capture has no pointer on it.
				p.move_pointer(off, f32(f.cw) + 40, f32(f.ch) + 40)
			}
			// Settle: the state change starts colour transitions, and the
			// application's state lags palmy's by a frame.
			for _ in 0 ..< 40 {
				frame(off, f, c, &l)
			}
			caret_off(off)
			frame(off, f, c, &l)
			live_px := snapshot(off)

			switch c.drive {
			case .Hover:
				r.reached = l.hover
			case .Focus:
				r.reached = l.focus
			case .Typed:
				r.reached = l.focus && string(l.buf[:]) == "Hello"
			case .Click:
				r.reached = l.pressed || l.open
			}
			r.live_diff = count_diff(live_px, static_px)
			r.rest_diff = count_diff(rest_px, static_px)
			delete(rest_px)
			delete(live_px)
			delete(l.buf)
			p.offscreen_destroy(off)
		}
		delete(static_px)
		append(&g_results, r)
		free_all(context.temp_allocator)
	}

	// Put the process back the way every other test expects it.
	p.reset_theme()
	register_field_theme_tokens()
	register_token_test_tokens()
	p.set_text_gamma(1.0)
	_, primary := p.theme_color("primary")
	_, field := p.theme_color("tfield-light-ink")
	_, tok := p.theme_color("tok-primary")
	g_theme_restored = !primary && field && tok
}

// ---------------------------------------------------------------------------
// The assertions
// ---------------------------------------------------------------------------

@(test)
test_shadcn_states_render_identically_when_reached_for_real :: proc(t: ^testing.T) {
	testing.expect_value(t, len(g_results), len(CASES))
	compared, absent := 0, 0
	for r in g_results {
		if !testing.expectf(t, r.framed, "%s: parity's geometry for the case is readable", r.id) {
			continue
		}
		testing.expectf(t, r.reached, "%s: palmy reported the %v state after it was driven there", r.id, r.drive)
		testing.expectf(
			t,
			r.live_diff == 0,
			"%s: the widget driven into the state draws what the declared state draws (%d pixels differ)",
			r.id,
			r.live_diff,
		)
		if r.invisible {
			testing.expectf(t, r.rest_diff == 0, "%s: a state shadcn gives no look draws exactly what rest draws (%d pixels differ)", r.id, r.rest_diff)
		} else {
			testing.expectf(t, r.rest_diff > 0, "%s: and the state is visible -- at rest it draws differently", r.id)
		}
		switch r.parity {
		case .Absent:
			absent += 1
		case .Match, .Mismatch, .Wrong_Size:
			compared += 1
			testing.expectf(
				t,
				r.parity == .Match,
				"%s: the declared state is parity's own render, byte for byte (%v, %d pixels differ from %s)",
				r.id,
				r.parity,
				r.parity_diff,
				r.parity_path,
			)
		}
	}
	if absent > 0 {
		log.infof("%d of %d cases had no parity render to compare with (run parity/tools/diff-all.sh, or set PARITY_ODIN_DIR)", absent, len(g_results))
	}
	log.infof("%d cases compared with parity's renders byte for byte", compared)
}

@(test)
test_shadcn_states_leave_the_theme_as_they_found_it :: proc(t: ^testing.T) {
	testing.expect(t, g_theme_restored, "the shadcn theme is gone and the other tests' tokens are back after the state renders")
}
