package main

// palmy colour picker.
//
// Three things make a colour picker worth keeping: it can take a colour off the
// screen, it can express that colour in whatever notation the thing you are
// typing into wants, and it tells you whether text will be legible on it.
//
// Screen picking goes through `grim`: the compositor hands over a PNG, palmy
// decodes it, and the pixel under a keyboard-driven crosshair is read straight
// out of the decoded buffer. There is no screen-colour-picker portal here and
// no pointer-grab protocol in palmy, so a magnifier the arrow keys drive is not
// a compromise — it is more precise than a cursor.
//
// The conversions are in color.odin and are checked by `colorpick --selftest`.
//
// The same core is the command line, `palm color` (cli.odin): parse_color reads
// what Ctrl+V pastes and what every command is given, palette.odin is the
// palette both Ctrl+S and `color save` write, and pixel_at is the loupe's
// sampler and `color sample`'s.

import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"
import "core:time"
import kit "kit:."
import p "palmy:."
import sc "shadcn:."

WIN_W :: 1060
WIN_H :: 720

PALETTE_CAP :: 48

// The caret's blink, and how much of each cycle it is lit.
CARET_PERIOD :: 1.1
CARET_ON :: 0.62

// Nothing here reads `ui.now`. palmy clamps `dt` to 0.1s so that a stalled
// frame cannot teleport an animation, which means `ui.now` only tracks real
// time while frames are frequent. This window now draws twice a second when
// it is idle, so a timer hung off `ui.now` would run at a third of real
// speed: a four-second toast would linger for twelve. Everything timed here
// is timed against a real monotonic clock instead.
START_TICK := time.tick_now()

mono :: proc() -> f64 {
	return time.duration_seconds(time.tick_since(START_TICK))
}

// secs turns a number of seconds into a wake delay.
secs :: proc(s: f64) -> time.Duration {
	return time.Duration(max(s, 0) * f64(time.Second))
}

Mode :: enum u8 {
	Editor,
	Screen,
}

Pane :: enum u8 {
	Fields,
	Palette,
}

Model :: enum u8 {
	Hex,
	Rgb,
	Hsl,
	Oklch,
}

MODEL_LABEL := [Model]string {
	.Hex   = "Hex",
	.Rgb   = "RGB",
	.Hsl   = "HSL",
	.Oklch = "OKLCH",
}

// F describes one editable component. `step`/`big` are what Left/Right and
// Shift-Left/Right move it by, in the units the field displays.
F :: struct {
	model:     Model,
	comp:      int,
	label:     string,
	suffix:    string,
	lo, hi:    f32,
	step, big: f32,
	digits:    int,
	wide:      bool, // lays out across the whole row (hex only)
}

FIELDS := [?]F {
	{model = .Hex, label = "HEX", wide = true},
	{model = .Rgb, comp = 0, label = "R", lo = 0, hi = 255, step = 1, big = 16, digits = 0},
	{model = .Rgb, comp = 1, label = "G", lo = 0, hi = 255, step = 1, big = 16, digits = 0},
	{model = .Rgb, comp = 2, label = "B", lo = 0, hi = 255, step = 1, big = 16, digits = 0},
	{model = .Hsl, comp = 0, label = "H", suffix = "°", lo = 0, hi = 360, step = 1, big = 15, digits = 1},
	{model = .Hsl, comp = 1, label = "S", suffix = "%", lo = 0, hi = 100, step = 1, big = 10, digits = 1},
	{model = .Hsl, comp = 2, label = "L", suffix = "%", lo = 0, hi = 100, step = 1, big = 10, digits = 1},
	{model = .Oklch, comp = 0, label = "L", lo = 0, hi = 1, step = 0.005, big = 0.05, digits = 4},
	{model = .Oklch, comp = 1, label = "C", lo = 0, hi = 0.45, step = 0.002, big = 0.02, digits = 4},
	{model = .Oklch, comp = 2, label = "H", suffix = "°", lo = 0, hi = 360, step = 1, big = 15, digits = 2},
}

FIELD_N :: len(FIELDS)

Shot :: struct {
	img:   p.Image,
	ok:    bool,
	path:  string,
	taken: f64,
}

St :: struct {
	// The colour, in three representations. `src` says which one is
	// authoritative, so editing hue at zero saturation does not snap back to 0.
	rgb:       [3]f32,
	hsl:       [3]f32,
	lch:       [3]f32,
	src:       Model,
	in_gamut:  bool,

	mode:      Mode,
	pane:      Pane,
	sel:       int, // focused field
	bufs:      [FIELD_N][dynamic]u8,
	hex_caret: int,

	palette:   [dynamic][3]u8,
	pal_sel:   int,

	// Screen picking.
	shot:      Shot,
	px:        int,
	py:        int,
	zoom:      int,
	shot_rect: p.Rect, // where the screenshot landed last frame

	toast:     string,
	toast_t:   f64,
	have_clip: bool,
	have_grim: bool,
	have_hypr: bool,
}

// g_test / g_test_clip make the clipboard write observable instead of real.
g_test: bool
g_test_clip: string

main :: proc() {
	args := os.args[1:]
	// `colorpick --shots <dir>` renders the interface offscreen: see
	// shot.odin. It opens no window and never captures the screen. It is the
	// one older flag kept outside the convention, as image keeps --shot.
	for a, i in args {
		if a == "--shots" || a == "-shots" {
			if i + 1 >= len(args) {
				fmt.eprintln("colorpick --shots <dir>")
				os.exit(2)
			}
			os.exit(shots(args[i + 1]))
		}
	}
	// Everything else with arguments is `palm color …` (cli.odin), including
	// --selftest. No arguments opens the window.
	if code, handled := kit.cli(surface()); handled {
		os.exit(code)
	}

	app, err := kit.start(
		{
			title = "Colour",
			app_id = "palmy",
			width = WIN_W,
			height = WIN_H,
			min_width = 820,
			min_height = 560,
			root_class = "w-full h-full flex-col bg-background text-foreground overflow-hidden",
		},
	)
	if err != "" {
		fmt.eprintfln("colorpick: %s", err)
		os.exit(1)
	}
	defer p.destroy(app)

	register_dark_theme()

	st := St {
		rgb       = {0x3b / 255.0, 0x82 / 255.0, 0xf6 / 255.0}, // tailwind blue-500
		zoom      = 12,
		have_clip = kit.has_tool("wl-copy"),
		have_grim = kit.has_tool("grim"),
		have_hypr = kit.has_tool("hyprctl"),
		palette   = make([dynamic][3]u8),
	}
	for i in 0 ..< FIELD_N {
		st.bufs[i] = make([dynamic]u8)
	}
	resync(&st, .Hex)
	st.hex_caret = len(st.bufs[0])
	load_palette(&st)

	for ui in p.frames(app) {
		free_all(context.temp_allocator)

		handle_keys(ui, app, &st)

		switch st.mode {
		case .Editor:
			build_editor(ui, &st)
		case .Screen:
			build_screen(ui, &st)
		}

		if st.toast != "" {
			if mono() > st.toast_t {
				st.toast = ""
			} else {
				// One frame when it expires, rather than every frame until
				// it does. `p.redraw` here meant the window repainted at the
				// display rate for the whole four seconds a toast was up.
				p.wake_after(ui, secs(st.toast_t - mono()))
			}
		}
	}
}

register_dark_theme :: proc() {
	c :: p.hex
	p.register_color("background", c(0x0a0a0a))
	p.register_color("foreground", c(0xfafafa))
	p.register_color("card", c(0x141414))
	p.register_color("card-foreground", c(0xfafafa))
	p.register_color("popover", c(0x1c1c1c))
	p.register_color("popover-foreground", c(0xfafafa))
	p.register_color("primary", c(0xfafafa))
	p.register_color("primary-foreground", c(0x171717))
	p.register_color("secondary", c(0x262626))
	p.register_color("secondary-foreground", c(0xfafafa))
	p.register_color("muted", c(0x1f1f1f))
	p.register_color("muted-foreground", c(0xa1a1a1))
	p.register_color("accent", c(0x303033))
	p.register_color("accent-foreground", c(0xfafafa))
	p.register_color("destructive", c(0xff6467))
	p.register_color("destructive-foreground", c(0xfafafa))
	p.register_color("border", c(0x2c2c2c))
	p.register_color("input", c(0x2c2c2c))
	p.register_color("ring", c(0x8e8e8e))
}

// ---------------------------------------------------------------------------
// The model
// ---------------------------------------------------------------------------

// resync recomputes every representation from whichever one just changed, and
// refreshes the text in every field except the one being typed into.
resync :: proc(st: ^St, from: Model, keep_focus := false) {
	st.src = from
	st.in_gamut = true
	switch from {
	case .Hex, .Rgb:
		st.hsl = srgb_to_hsl(st.rgb)
		st.lch = srgb_to_oklch(st.rgb)
	case .Hsl:
		st.rgb = hsl_to_srgb(st.hsl)
		st.lch = srgb_to_oklch(st.rgb)
	case .Oklch:
		st.rgb, st.in_gamut = oklch_to_srgb(st.lch)
		st.hsl = srgb_to_hsl(st.rgb)
	}
	for i in 0 ..< FIELD_N {
		if keep_focus && i == st.sel {
			continue
		}
		set_buf(st, i, field_text(st, i))
	}
}

field_value :: proc(st: ^St, i: int) -> f32 {
	f := FIELDS[i]
	switch f.model {
	case .Hex:
		return 0
	case .Rgb:
		return f32(to_bytes(st.rgb)[f.comp])
	case .Hsl:
		return f.comp == 0 ? st.hsl[0] : st.hsl[f.comp] * 100
	case .Oklch:
		return st.lch[f.comp]
	}
	return 0
}

set_field_value :: proc(st: ^St, i: int, v_in: f32) {
	f := FIELDS[i]
	v := clamp(v_in, f.lo, f.hi)
	if f.model == .Hsl && f.comp == 0 || f.model == .Oklch && f.comp == 2 {
		v = math.mod_f32(math.mod_f32(v_in, 360) + 360, 360)
	}
	switch f.model {
	case .Hex:
	case .Rgb:
		b := to_bytes(st.rgb)
		b[f.comp] = u8(clamp(v, 0, 255) + 0.5)
		st.rgb = from_bytes(b)
	case .Hsl:
		st.hsl[f.comp] = f.comp == 0 ? v : v / 100
	case .Oklch:
		st.lch[f.comp] = v
	}
	resync(st, f.model, true)
}

field_text :: proc(st: ^St, i: int, al := context.temp_allocator) -> string {
	f := FIELDS[i]
	if f.model == .Hex {
		return fmt_hex(st.rgb, al)
	}
	v := field_value(st, i)
	switch f.digits {
	case 0:
		return fmt.aprintf("%d", int(v + 0.5), allocator = al)
	case 1:
		return fmt.aprintf("%.1f", v, allocator = al)
	case 2:
		return fmt.aprintf("%.2f", v, allocator = al)
	}
	return fmt.aprintf("%.4f", v, allocator = al)
}

set_buf :: proc(st: ^St, i: int, s: string) {
	clear(&st.bufs[i])
	append(&st.bufs[i], ..transmute([]u8)s)
	if i == 0 {
		st.hex_caret = min(st.hex_caret, len(st.bufs[i]))
	}
}

buf_str :: proc(st: ^St, i: int) -> string {
	return string(st.bufs[i][:])
}

// commit_buf parses whatever is in the focused field. An unparseable field is
// left alone rather than snapped back, so a half-typed "#3b8" does not fight
// the keyboard.
commit_buf :: proc(st: ^St, i: int) {
	f := FIELDS[i]
	s := buf_str(st, i)
	if f.model == .Hex {
		if rgb, ok := parse_hex(s); ok {
			st.rgb = rgb
			resync(st, .Hex, true)
		}
		return
	}
	if v, ok := parse_number(s); ok {
		set_field_value(st, i, v)
	}
}

format_for :: proc(st: ^St, m: Model, al := context.temp_allocator) -> string {
	switch m {
	case .Hex:
		return fmt_hex(st.rgb, al)
	case .Rgb:
		return fmt_rgb(st.rgb, al)
	case .Hsl:
		return fmt_hsl(st.rgb, al)
	case .Oklch:
		return fmt_oklch(st.rgb, al)
	}
	return ""
}

// ---------------------------------------------------------------------------
// Keyboard
// ---------------------------------------------------------------------------

handle_keys :: proc(ui: ^p.Ctx, app: ^p.App, st: ^St) {
	if st.mode == .Screen {
		screen_keys(ui, st)
		return
	}

	if p.key_pressed(ui, p.KEY_ESCAPE) {
		quit(app)
		return
	}
	if p.shortcut(ui, 'q', {.Ctrl}) {
		quit(app)
		return
	}

	if p.key_pressed(ui, p.KEY_F2) {
		pick_from_screen(st, ui)
		return
	}
	if p.key_pressed(ui, p.KEY_F3) {
		pick_under_cursor(st, ui)
		return
	}
	if p.key_pressed(ui, p.KEY_TAB) {
		st.pane = st.pane == .Fields ? .Palette : .Fields
		if st.pane == .Palette && len(st.palette) == 0 {
			st.pane = .Fields
			toast(st, ui, "The palette is empty — Ctrl+S saves the current colour")
		}
		return
	}

	// Copy, in any format.
	if p.shortcut(ui, 'c', {.Ctrl}) {
		m := st.pane == .Palette ? Model.Hex : FIELDS[st.sel].model
		copy_format(st, ui, m)
		return
	}
	for m, k in ([?]Model{.Hex, .Rgb, .Hsl, .Oklch}) {
		if p.shortcut(ui, u32('1') + u32(k), {.Ctrl}) {
			copy_format(st, ui, m)
			return
		}
	}
	if p.shortcut(ui, 's', {.Ctrl}) {
		save_to_palette(st, ui)
		return
	}
	if p.shortcut(ui, 'v', {.Ctrl}) {
		paste_colour(st, ui)
		return
	}

	if st.pane == .Palette {
		palette_keys(ui, st)
		return
	}

	// Field selection.
	if p.key_pressed(ui, p.KEY_DOWN) {
		commit_buf(st, st.sel)
		st.sel = (st.sel + 1) % FIELD_N
		set_buf(st, st.sel, field_text(st, st.sel))
		st.hex_caret = len(st.bufs[st.sel])
		return
	}
	if p.key_pressed(ui, p.KEY_UP) {
		commit_buf(st, st.sel)
		st.sel = (st.sel - 1 + FIELD_N) % FIELD_N
		set_buf(st, st.sel, field_text(st, st.sel))
		st.hex_caret = len(st.bufs[st.sel])
		return
	}

	f := FIELDS[st.sel]

	// Numeric fields are spinners: Left and Right move the value. The hex
	// field is a text field, so there they move the caret.
	if f.model != .Hex {
		d := f32(0)
		if n := p.key_count(ui, p.KEY_RIGHT); n > 0 {
			d += f32(n) * (.Shift in ui.input.mods ? f.big : f.step)
		}
		if n := p.key_count(ui, p.KEY_LEFT); n > 0 {
			d -= f32(n) * (.Shift in ui.input.mods ? f.big : f.step)
		}
		if d != 0 {
			commit_buf(st, st.sel)
			set_field_value(st, st.sel, field_value(st, st.sel) + d)
			set_buf(st, st.sel, field_text(st, st.sel))
			return
		}
	}

	edit_field(ui, st)
}

// edit_field is a text field written by hand, because the app wants the
// keyboard without any element taking focus, and wants every keystroke to
// re-derive the other nine fields.
edit_field :: proc(ui: ^p.Ctx, st: ^St) {
	f := FIELDS[st.sel]
	buf := &st.bufs[st.sel]
	changed := false
	hex := f.model == .Hex

	if typed := p.typed_text(ui); len(typed) > 0 {
		for i in 0 ..< len(typed) {
			ch := typed[i]
			keep := hex ? is_hex_char(ch) : is_num_char(ch)
			if !keep {
				continue
			}
			at := hex ? clamp(st.hex_caret, 0, len(buf)) : len(buf)
			if len(buf) >= (hex ? 7 : 9) {
				continue
			}
			inject_at(buf, at, ch)
			if hex {
				st.hex_caret = at + 1
			}
			changed = true
		}
	}

	for k in ui.input.keys {
		if .Ctrl in k.mods {
			continue
		}
		switch k.sym {
		case p.KEY_BACKSPACE:
			at := hex ? clamp(st.hex_caret, 0, len(buf)) : len(buf)
			if at > 0 {
				ordered_remove(buf, at - 1)
				if hex {st.hex_caret = at - 1}
				changed = true
			}
		case p.KEY_DELETE:
			at := hex ? clamp(st.hex_caret, 0, len(buf)) : len(buf)
			if at < len(buf) {
				ordered_remove(buf, at)
				changed = true
			}
		case p.KEY_LEFT:
			if hex && st.hex_caret > 0 {st.hex_caret -= 1}
		case p.KEY_RIGHT:
			if hex && st.hex_caret < len(buf) {st.hex_caret += 1}
		case p.KEY_HOME:
			if hex {st.hex_caret = 0}
		case p.KEY_END:
			if hex {st.hex_caret = len(buf)}
		case p.KEY_RETURN, p.KEY_KP_ENTER:
			commit_buf(st, st.sel)
			set_buf(st, st.sel, field_text(st, st.sel))
			st.hex_caret = len(st.bufs[st.sel])
			save_to_palette(st, ui)
			return
		}
	}

	if changed {
		commit_buf(st, st.sel)
	}
}

is_hex_char :: proc(c: u8) -> bool {
	switch c {
	case '0' ..= '9', 'a' ..= 'f', 'A' ..= 'F', '#':
		return true
	}
	return false
}

is_num_char :: proc(c: u8) -> bool {
	return c >= '0' && c <= '9' || c == '.'
}

palette_keys :: proc(ui: ^p.Ctx, st: ^St) {
	if len(st.palette) == 0 {
		st.pane = .Fields
		return
	}
	st.pal_sel = clamp(st.pal_sel, 0, len(st.palette) - 1)

	if p.key_pressed(ui, p.KEY_RIGHT) {
		st.pal_sel = (st.pal_sel + 1) % len(st.palette)
	}
	if p.key_pressed(ui, p.KEY_LEFT) {
		st.pal_sel = (st.pal_sel - 1 + len(st.palette)) % len(st.palette)
	}
	if p.key_pressed(ui, p.KEY_RETURN) || p.key_pressed(ui, p.KEY_KP_ENTER) {
		st.rgb = from_bytes(st.palette[st.pal_sel])
		resync(st, .Hex)
		st.pane = .Fields
		toast(st, ui, fmt.tprintf("Loaded %s", fmt_hex(st.rgb)))
	}
	if p.key_pressed(ui, p.KEY_DELETE, false) ||
	   p.key_pressed(ui, p.KEY_BACKSPACE, false) {
		palette_remove_at(&st.palette, st.pal_sel)
		st.pal_sel = clamp(st.pal_sel, 0, max(0, len(st.palette) - 1))
		save_palette(st)
		if len(st.palette) == 0 {
			st.pane = .Fields
		}
		toast(st, ui, "Removed from palette")
	}
}

// ---------------------------------------------------------------------------
// Actions
// ---------------------------------------------------------------------------

toast :: proc(st: ^St, ui: ^p.Ctx, msg: string) {
	if st.toast != "" {
		delete(st.toast)
	}
	st.toast = strings.clone(msg)
	st.toast_t = mono() + 4
	if ui != nil {
		p.wake_after(ui, secs(4))
	}
}

// quit is nil-safe so the headless self-test can drive `handle_keys` with no
// window behind it.
quit :: proc(app: ^p.App) {
	if app != nil {
		p.quit_app(app)
	}
}

copy_format :: proc(st: ^St, ui: ^p.Ctx, m: Model) {
	text := st.pane == .Palette && len(st.palette) > 0 \
		? fmt_hex(from_bytes(st.palette[clamp(st.pal_sel, 0, len(st.palette) - 1)])) \
		: format_for(st, m)
	// A test must not reach out and change the user's real clipboard.
	if g_test {
		if g_test_clip != "" {delete(g_test_clip)}
		g_test_clip = strings.clone(text)
		toast(st, ui, fmt.tprintf("Copied %s", text))
		return
	}
	if !st.have_clip {
		toast(st, ui, "wl-copy is not installed")
		return
	}
	if copy_detached(text) {
		toast(st, ui, fmt.tprintf("Copied %s", text))
	} else {
		toast(st, ui, "wl-copy could not be started")
	}
}

// kit.clipboard_set runs `wl-copy` through os.process_exec, which captures the
// child's stdout and stderr and waits for them to reach EOF. wl-copy forks a
// daemon that keeps owning the selection — and keeps those pipes open — until
// something else takes the clipboard, so process_exec never returns and the
// frame loop stops forever. The compositor puts up "Application Not
// Responding" a few seconds later.
//
// Starting it detached is what the launcher does, and it is the only thing that
// works. This is a gap in apps/kit, reported rather than patched.
copy_detached :: proc(text: string) -> bool {
	return kit.launch({"wl-copy", "--", text})
}

paste_colour :: proc(st: ^St, ui: ^p.Ctx) {
	text, ok := kit.clipboard_get(context.temp_allocator)
	if !ok || text == "" {
		toast(st, ui, "Nothing on the clipboard")
		return
	}
	if take_colour_text(st, text) {
		toast(st, ui, fmt.tprintf("Pasted %s", fmt_hex(st.rgb)))
		return
	}
	toast(st, ui, fmt.tprintf("Not a colour: %s", trunc(text, 32)))
}

// take_colour_text makes a colour written in any notation the editor itself
// writes the current one: what Ctrl+1..4 copied comes back with Ctrl+V, and
// it is the same parse_color every CLI command reads its colours with. An
// oklch() outside sRGB keeps its OKLCH fields and is flagged out of gamut,
// exactly as typing it into those fields would be.
take_colour_text :: proc(st: ^St, text: string) -> bool {
	pc, good := parse_color(text)
	if !good {
		return false
	}
	if pc.notation == "oklch" {
		st.lch = pc.lch
		resync(st, .Oklch)
	} else {
		st.rgb = pc.rgb
		resync(st, .Hex)
	}
	return true
}

save_to_palette :: proc(st: ^St, ui: ^p.Ctx) {
	at, already := palette_add(&st.palette, to_bytes(st.rgb))
	st.pal_sel = at
	if already {
		toast(st, ui, fmt.tprintf("%s is already in the palette", fmt_hex(st.rgb)))
		return
	}
	save_palette(st)
	toast(st, ui, fmt.tprintf("%s saved to the palette", fmt_hex(st.rgb)))
}

trunc :: proc(s: string, n: int) -> string {
	if len(s) <= n {
		return s
	}
	return fmt.tprintf("%s…", s[:n])
}

// ---------------------------------------------------------------------------
// Screen picking
// ---------------------------------------------------------------------------

shot_path :: proc() -> string {
	dir := os.get_env("XDG_RUNTIME_DIR", context.temp_allocator)
	if dir == "" {
		dir = "/tmp"
	}
	return fmt.tprintf("%s/palmy-colorpick-shot.png", dir)
}

// capture_screen asks grim for every output as one PNG and decodes it. This is
// the only way to read a pixel: there is no screencopy client in palmy and
// Hyprland's screen-colour-picker portal is not reachable from here.
capture_screen :: proc(st: ^St) -> bool {
	if !st.have_grim {
		return false
	}
	if st.shot.ok {
		p.image_destroy(&st.shot.img)
		st.shot.ok = false
	}
	path := shot_path()
	if _, ok := kit.run({"grim", "--", path}, context.temp_allocator); !ok {
		return false
	}
	img, ok := p.load_image(path)
	// The capture is a picture of the whole screen, so it does not linger on
	// disk: it is decoded into memory and the file is removed immediately.
	_ = os.remove(path)
	if !ok {
		return false
	}
	st.shot.img = img
	st.shot.ok = true
	st.shot.path = path
	return true
}

pick_from_screen :: proc(st: ^St, ui: ^p.Ctx) {
	if !capture_screen(st) {
		toast(st, ui, st.have_grim ? "grim could not capture the screen" : "grim is not installed")
		return
	}
	st.px = st.shot.img.w / 2
	st.py = st.shot.img.h / 2
	if x, y, ok := cursor_pos(st); ok {
		st.px = clamp(x, 0, st.shot.img.w - 1)
		st.py = clamp(y, 0, st.shot.img.h - 1)
	}
	st.mode = .Screen
}

// cursor_pos asks Hyprland where the pointer is, in the same global coordinate
// space grim captures. It is the difference between "pick a pixel" and "pick
// the pixel I am pointing at".
cursor_pos :: proc(st: ^St) -> (x, y: int, ok: bool) {
	if !st.have_hypr {
		return
	}
	out, good := kit.run({"hyprctl", "cursorpos"}, context.temp_allocator)
	if !good {
		return
	}
	parts := strings.split(out, ",", context.temp_allocator)
	if len(parts) != 2 {
		return
	}
	xv, ok1 := parse_number(parts[0])
	yv, ok2 := parse_number(parts[1])
	if !ok1 || !ok2 {
		return
	}
	return int(xv), int(yv), true
}

pick_under_cursor :: proc(st: ^St, ui: ^p.Ctx) {
	if !capture_screen(st) {
		toast(st, ui, st.have_grim ? "grim could not capture the screen" : "grim is not installed")
		return
	}
	x, y, ok := cursor_pos(st)
	if !ok {
		toast(st, ui, "hyprctl could not report the cursor position")
		return
	}
	st.px = clamp(x, 0, st.shot.img.w - 1)
	st.py = clamp(y, 0, st.shot.img.h - 1)
	take_sample(st, ui)
}

sample_at :: proc(st: ^St, x, y: int) -> [3]u8 {
	if !st.shot.ok {
		return {0, 0, 0}
	}
	return pixel_at(st.shot.img, x, y)
}

take_sample :: proc(st: ^St, ui: ^p.Ctx) {
	b := sample_at(st, st.px, st.py)
	st.rgb = from_bytes(b)
	resync(st, .Hex)
	st.mode = .Editor
	save_to_palette(st, ui)
	toast(st, ui, fmt.tprintf("Picked %s at %d, %d", fmt_hex(st.rgb), st.px, st.py))
}

screen_keys :: proc(ui: ^p.Ctx, st: ^St) {
	if p.key_pressed(ui, p.KEY_ESCAPE) {
		st.mode = .Editor
		return
	}
	if p.key_pressed(ui, p.KEY_RETURN) || p.key_pressed(ui, p.KEY_KP_ENTER) ||
	   p.key_pressed(ui, p.KEY_SPACE) {
		take_sample(st, ui)
		return
	}
	if p.key_pressed(ui, p.KEY_F2) {
		if capture_screen(st) {
			toast(st, ui, "Recaptured")
		}
		return
	}
	if p.shortcut(ui, 'c', {.Ctrl}) {
		b := sample_at(st, st.px, st.py)
		if copy_detached(fmt_hex(from_bytes(b))) {
			toast(st, ui, fmt.tprintf("Copied %s", fmt_hex(from_bytes(b))))
		}
		return
	}

	step := 1
	if .Shift in ui.input.mods {step = 10}
	if .Ctrl in ui.input.mods {step = 50}

	st.px += step * (p.key_count(ui, p.KEY_RIGHT) - p.key_count(ui, p.KEY_LEFT))
	st.py += step * (p.key_count(ui, p.KEY_DOWN) - p.key_count(ui, p.KEY_UP))

	if p.key_pressed(ui, '+') || p.key_pressed(ui, '=') {
		st.zoom = min(st.zoom + 2, 40)
	}
	if p.key_pressed(ui, '-') {
		st.zoom = max(st.zoom - 2, 2)
	}

	if st.shot.ok {
		st.px = clamp(st.px, 0, st.shot.img.w - 1)
		st.py = clamp(st.py, 0, st.shot.img.h - 1)
	}
}

// ---------------------------------------------------------------------------
// Persistence: palette.odin, shared with the command line.
// ---------------------------------------------------------------------------

load_palette :: proc(st: ^St) {
	palette_read(&st.palette)
}

save_palette :: proc(st: ^St) {
	palette_write(st.palette[:])
}

// ---------------------------------------------------------------------------
// The editor view
// ---------------------------------------------------------------------------

build_editor :: proc(ui: ^p.Ctx, st: ^St) {
	header(ui, st)

	p.row(ui, "w-full flex-1 min-h-0 gap-4 p-4")
	preview_column(ui, st)
	fields_column(ui, st)
	p.end(ui)

	palette_strip(ui, st)
	footer(ui, st)
}

header :: proc(ui: ^p.Ctx, st: ^St) {
	p.row(ui, "w-full h-[52] shrink-0 items-center gap-3 px-4 border-b border-border")
	defer p.end(ui)

	p.div(ui, "size-7 shrink-0 flex-row items-center justify-center rounded-lg bg-muted ring-1 ring-border")
	p.icon(ui, IC_PIPETTE, "size-4 text-foreground")
	p.end(ui)

	p.text(ui, "Colour", "text-sm font-semibold whitespace-nowrap")
	p.style(ui).shrink = 0

	sw := p.div(ui, "size-5 shrink-0 rounded-md ring-1 ring-border")
	p.style(ui, sw).bg = p.flat(cur_color(st))
	p.end(ui)

	p.text(ui, fmt_hex(st.rgb), "text-xs text-muted-foreground font-mono whitespace-nowrap")
	p.style(ui).shrink = 0

	p.spacer(ui)

	if !st.in_gamut {
		sc.badge(ui, "Out of sRGB gamut", .Destructive)
	}
	if st.shot.ok {
		sc.badge(ui, fmt.tprintf("Capture %dx%d", st.shot.img.w, st.shot.img.h), .Secondary)
	}
	if !st.have_grim {
		sc.badge(ui, "grim missing", .Outline)
	}
}

cur_color :: proc(st: ^St) -> p.Color {
	b := to_bytes(st.rgb)
	return p.rgba(b[0], b[1], b[2])
}

preview_column :: proc(ui: ^p.Ctx, st: ^St) {
	p.col(ui, "flex-1 min-w-0 min-h-0 gap-4")
	defer p.end(ui)

	// The swatch. Big, because judging a colour off a 16px chip is guesswork.
	sw := p.div(ui, "w-full flex-1 min-h-[90] flex-col justify-end p-5 rounded-xl ring-1 ring-border overflow-hidden")
	p.style(ui, sw).bg = p.flat(cur_color(st))

	ink := ink_for(st.rgb)
	p.text(ui, fmt_hex(st.rgb), "text-4xl font-semibold font-mono whitespace-nowrap")
	p.style(ui).fg = ink
	p.text(ui, fmt_oklch(st.rgb), "text-xs whitespace-nowrap")
	s := p.style(ui)
	s.fg = ink
	s.opacity = 0.75
	p.end(ui)

	contrast_card(ui, st)
}

// ink_for picks black or white for text drawn on the colour, by WCAG contrast —
// the same decision the readout below is reporting on.
ink_for :: proc(rgb: [3]f32) -> p.Color {
	return contrast_ratio(rgb, {0, 0, 0}) >= contrast_ratio(rgb, {1, 1, 1}) ? p.BLACK : p.WHITE
}

contrast_card :: proc(ui: ^p.Ctx, st: ^St) {
	p.col(ui, "w-full shrink-0 gap-2 p-3 rounded-xl bg-card ring-1 ring-border")
	defer p.end(ui)

	p.row(ui, "w-full items-center gap-2")
	p.icon(ui, IC_CONTRAST, "size-3.5 shrink-0 text-muted-foreground")
	p.text(ui, "Contrast", "text-xs font-semibold uppercase tracking-wide text-muted-foreground whitespace-nowrap")
	p.style(ui).shrink = 0
	p.spacer(ui)
	p.text(ui, "WCAG 2.1 · body / large", "text-[11] text-muted-foreground whitespace-nowrap")
	p.style(ui).shrink = 0
	p.end(ui)

	contrast_row(ui, st, "on black", {0, 0, 0}, p.BLACK)
	contrast_row(ui, st, "on white", {1, 1, 1}, p.WHITE)

	p.text(
		ui,
		"4.5:1 passes AA for body text, 3:1 for large text; 7:1 is AAA.",
		"text-[11] text-muted-foreground",
	)
}

contrast_row :: proc(ui: ^p.Ctx, st: ^St, label: string, other: [3]f32, other_c: p.Color) {
	ratio := contrast_ratio(st.rgb, other)

	p.row(ui, "w-full h-9 shrink-0 items-center gap-3 px-3 rounded-lg ring-1 ring-border overflow-hidden")
	defer p.end(ui)
	p.style(ui).bg = p.flat(other_c)

	// Sample text in the picked colour on the reference background, which is
	// the thing the number is about.
	p.text(ui, "Sample Aa", "text-sm font-medium whitespace-nowrap")
	ss := p.style(ui)
	ss.fg = cur_color(st)
	ss.shrink = 0

	p.spacer(ui)

	p.textf(ui, "text-xs font-mono whitespace-nowrap", "%.2f:1", ratio)
	ts := p.style(ui)
	ts.fg = other_c == p.BLACK ? p.hex(0xa1a1a1) : p.hex(0x52525b)
	ts.shrink = 0

	for pair in ([?]struct {
		name:  string,
		large: bool,
	}{{"body", false}, {"large", true}}) {
		g := wcag_grade(ratio, pair.large)
		p.row(ui, "shrink-0 items-center gap-1 h-5 px-1.5 rounded-md")
		gs := p.style(ui)
		ok := g != "fail"
		gs.bg = p.flat(ok ? p.hexa(0x16a34a33) : p.hexa(0xdc262633))
		p.icon(ui, ok ? IC_CHECK : IC_X, "size-3 shrink-0")
		p.style(ui).fg = ok ? p.hex(0x4ade80) : p.hex(0xf87171)
		p.textf(ui, "text-[10] font-semibold whitespace-nowrap", "%s %s", g, pair.name)
		is := p.style(ui)
		is.fg = ok ? p.hex(0x4ade80) : p.hex(0xf87171)
		is.shrink = 0
		p.end(ui)
	}
	_ = label
}

// fields_column scrolls, because the compositor tiles this window to whatever
// height it likes and four format groups do not always fit. The selected field
// is kept on screen with palmy's `scroll_into_view`, so arrowing down past the
// bottom scrolls rather than hiding the thing you are editing.
fields_column :: proc(ui: ^p.Ctx, st: ^St) {
	list := p.col(ui, "w-[380] shrink-0 min-h-0 gap-3 pr-1 overflow-scroll")

	sel_node := -1
	g := group(ui, st, .Hex, IC_HASH, 0, 1)
	if st.sel == 0 {sel_node = g}
	g = group(ui, st, .Rgb, IC_BLEND, 1, 3)
	if st.sel >= 1 && st.sel <= 3 {sel_node = g}
	g = group(ui, st, .Hsl, IC_DROPLET, 4, 3)
	if st.sel >= 4 && st.sel <= 6 {sel_node = g}
	g = group(ui, st, .Oklch, IC_APERTURE, 7, 3)
	if st.sel >= 7 {sel_node = g}

	p.end(ui)

	if st.pane == .Fields && sel_node >= 0 {
		p.scroll_into_view(ui, p.node_id(ui, list), p.node_id(ui, sel_node), 8)
	}
}

group :: proc(ui: ^p.Ctx, st: ^St, m: Model, ic: p.Icon, first, count: int) -> int {
	focused := st.pane == .Fields && st.sel >= first && st.sel < first + count
	root := p.col(ui, "w-full shrink-0 gap-1.5 p-2.5 rounded-xl bg-card ring-1 transition")
	p.apply(ui, focused ? "ring-ring" : "ring-border")
	defer p.end(ui)

	p.row(ui, "w-full items-center gap-2")
	p.icon(ui, ic, "size-3.5 shrink-0 text-muted-foreground")
	p.text(
		ui,
		MODEL_LABEL[m],
		"text-[11] font-semibold uppercase tracking-wide text-muted-foreground whitespace-nowrap",
	)
	p.style(ui).shrink = 0
	p.spacer(ui)
	p.text(ui, format_for(st, m), "text-[11] font-mono text-muted-foreground whitespace-nowrap truncate")
	p.style(ui).shrink = 0
	if st.src == m {
		sc.badge(ui, "source", .Secondary)
	}
	p.end(ui)

	p.row(ui, "w-full gap-2")
	for i in first ..< first + count {
		field_box(ui, st, i)
	}
	p.end(ui)

	return root
}

field_box :: proc(ui: ^p.Ctx, st: ^St, i: int) {
	f := FIELDS[i]
	on := st.pane == .Fields && st.sel == i

	p.key(ui, f.label)
	p.col(ui, f.wide ? "flex-1 gap-1" : "flex-1 min-w-0 gap-1")
	defer p.end(ui)

	// The hex group's header already says "Hex"; repeating it over the only
	// field in it is noise.
	if !f.wide {
		p.row(ui, "items-center gap-1")
		p.text(ui, f.label, "text-[10] font-medium text-muted-foreground whitespace-nowrap")
		p.style(ui).shrink = 0
		if f.suffix != "" {
			p.text(ui, f.suffix, "text-[10] text-muted-foreground whitespace-nowrap")
			p.style(ui).shrink = 0
		}
		p.end(ui)
	}

	idx := p.row(ui, "w-full h-8 items-center px-2.5 rounded-md bg-background ring-1 transition overflow-hidden")
	p.apply(ui, on ? "ring-ring" : "ring-border", idx)
	txt := buf_str(st, i)
	p.text(ui, txt == "" ? "—" : txt, "text-sm font-mono whitespace-nowrap")
	p.style(ui).shrink = 0

	// A caret, but only in the hex field — the numeric fields are spinners and
	// a blinking bar in them would promise arrow-key editing that is bound to
	// the value instead.
	if on && f.model == .Hex && ui.input.focused {
		// A blink is two frames per cycle, not sixty. Marking the window
		// animating for it cost a third of a core for as long as the hex
		// field was focused -- which is the default state of the app, so
		// colorpick burned that from the moment it opened. Ask for one frame
		// at the next edge of the blink instead.
		phase := math.mod_f32(f32(mono()), CARET_PERIOD)
		lit := phase < CARET_ON
		next := lit ? CARET_ON - phase : CARET_PERIOD - phase
		p.wake_after(ui, secs(f64(next)))
		if lit {
			w := p.text_width(ui.fonts, txt[:clamp(st.hex_caret, 0, len(txt))], 14, .Mono, .Regular)
			car := p.div(ui, "absolute w-[2] rounded-full bg-foreground")
			cs := p.style(ui, car)
			cs.inset[p.LEFT] = p.px(10 + w)
			cs.inset[p.TOP] = p.px(6)
			cs.h = p.px(18)
			p.end(ui)
		}
	}
	p.end(ui)
}

palette_strip :: proc(ui: ^p.Ctx, st: ^St) {
	p.col(ui, "w-full shrink-0 gap-2 px-4 pb-3")
	defer p.end(ui)

	p.row(ui, "w-full items-center gap-2")
	p.icon(ui, IC_PALETTE, "size-3.5 shrink-0 text-muted-foreground")
	p.text(ui, "Palette", "text-[11] font-semibold uppercase tracking-wide text-muted-foreground whitespace-nowrap")
	p.style(ui).shrink = 0
	p.textf(ui, "text-[11] text-muted-foreground whitespace-nowrap", "%d of %d", len(st.palette), PALETTE_CAP)
	p.style(ui).shrink = 0
	p.spacer(ui)
	if st.pane == .Palette {
		sc.badge(ui, "Enter loads · Del removes", .Secondary)
	} else {
		p.row(ui, "shrink-0 items-center gap-1")
		sc.kbd(ui, "Tab")
		p.text(ui, "focus palette", "text-[11] text-muted-foreground whitespace-nowrap")
		p.style(ui).shrink = 0
		p.end(ui)
	}
	p.end(ui)

	if len(st.palette) == 0 {
		p.row(ui, "w-full h-10 items-center gap-2 px-3 rounded-lg border border-dashed border-border")
		p.icon(ui, IC_PLUS, "size-3.5 shrink-0 text-muted-foreground")
		p.text(
			ui,
			"Nothing saved yet — Ctrl+S keeps the current colour, F2 picks one off the screen",
			"text-xs text-muted-foreground whitespace-nowrap truncate",
		)
		p.end(ui)
		return
	}

	p.row(ui, "w-full h-10 shrink-0 gap-1.5 overflow-hidden")
	for c, i in st.palette {
		if i >= 24 {
			break
		}
		on := st.pane == .Palette && i == st.pal_sel
		p.key(ui, fmt.tprintf("sw%d", i))
		sw := p.div(ui, "h-full flex-1 min-w-[18] rounded-md ring-1 transition")
		p.apply(ui, on ? "ring-2 ring-ring" : "ring-border", sw)
		p.style(ui, sw).bg = p.flat(p.rgba(c[0], c[1], c[2]))
		if p.clickable(ui, sw) {
			st.rgb = from_bytes(c)
			resync(st, .Hex)
			st.pal_sel = i
		}
		p.end(ui)
	}
	p.end(ui)
}

footer :: proc(ui: ^p.Ctx, st: ^St) {
	p.row(ui, "w-full h-[34] shrink-0 items-center gap-3 px-4 border-t border-border")
	defer p.end(ui)

	if st.toast != "" {
		p.icon(ui, IC_INFO, "size-3.5 shrink-0 text-muted-foreground")
		p.text(ui, st.toast, "flex-1 text-xs text-muted-foreground whitespace-nowrap truncate")
		return
	}

	hint(ui, "F2", "", "Pick from screen")
	hint(ui, "F3", "", "Under cursor")
	hint(ui, "Up", "Down", "Field")
	if st.pane == .Fields && FIELDS[st.sel].model != .Hex {
		hint(ui, "Left", "Right", "Adjust")
	}
	hint(ui, "Ctrl", "C", "Copy")
	hint(ui, "Ctrl", "S", "Save")
	p.spacer(ui)
	hint(ui, "Esc", "", "Quit")
}

hint :: proc(ui: ^p.Ctx, k1, k2, label: string) {
	p.row(ui, "shrink-0 items-center gap-1")
	defer p.end(ui)
	sc.kbd(ui, k1)
	if k2 != "" {
		sc.kbd(ui, k2)
	}
	p.text(ui, label, "text-[11] text-muted-foreground whitespace-nowrap")
	p.style(ui).shrink = 0
}

// ---------------------------------------------------------------------------
// The screen-picking view
// ---------------------------------------------------------------------------

build_screen :: proc(ui: ^p.Ctx, st: ^St) {
	p.row(ui, "w-full h-[52] shrink-0 items-center gap-3 px-4 border-b border-border")
	p.icon(ui, IC_CROSSHAIR, "size-4 shrink-0 text-foreground")
	p.text(ui, "Pick from screen", "text-sm font-semibold whitespace-nowrap")
	p.style(ui).shrink = 0
	p.textf(
		ui,
		"text-xs text-muted-foreground font-mono whitespace-nowrap",
		"%d, %d",
		st.px,
		st.py,
	)
	p.style(ui).shrink = 0
	p.spacer(ui)
	sc.badge(ui, fmt.tprintf("%dx zoom", st.zoom), .Secondary)
	p.end(ui)

	p.row(ui, "w-full flex-1 min-h-0 gap-4 p-4")

	// The capture, with a crosshair. Drawn through `pixels` rather than
	// `image` because the marker has to land on an exact source pixel, and the
	// element only knows where the image was fitted once it is drawing.
	p.pixels(ui, "flex-1 min-w-0 h-full rounded-xl overflow-hidden bg-muted", st, draw_capture)

	// The loupe, which is the part that makes a single pixel pickable.
	p.col(ui, "w-[300] shrink-0 h-full gap-3")
	p.pixels(ui, "w-full h-[300] shrink-0 rounded-xl overflow-hidden ring-1 ring-border", st, draw_loupe)

	b := sample_at(st, st.px, st.py)
	rgbf := from_bytes(b)

	p.col(ui, "w-full shrink-0 gap-2 p-3 rounded-xl bg-card ring-1 ring-border")
	p.row(ui, "w-full h-14 items-center justify-center rounded-lg ring-1 ring-border")
	p.style(ui).bg = p.flat(p.rgba(b[0], b[1], b[2]))
	p.text(ui, fmt_hex(rgbf), "text-base font-semibold font-mono whitespace-nowrap")
	p.style(ui).fg = ink_for(rgbf)
	p.end(ui)

	for s in ([?]string{fmt_rgb(rgbf), fmt_hsl(rgbf), fmt_oklch(rgbf)}) {
		p.text(ui, s, "text-[11] font-mono text-muted-foreground whitespace-nowrap truncate")
	}
	p.end(ui)

	p.spacer(ui)
	p.end(ui)
	p.end(ui)

	p.row(ui, "w-full h-[34] shrink-0 items-center gap-3 px-4 border-t border-border")
	if st.toast != "" {
		p.icon(ui, IC_INFO, "size-3.5 shrink-0 text-muted-foreground")
		p.text(ui, st.toast, "flex-1 text-xs text-muted-foreground whitespace-nowrap truncate")
	} else {
		hint(ui, "Arrows", "", "Move 1px")
		hint(ui, "Shift", "Arrows", "10px")
		hint(ui, "Ctrl", "Arrows", "50px")
		hint(ui, "+", "-", "Zoom")
		hint(ui, "Enter", "", "Take it")
		p.spacer(ui)
		hint(ui, "F2", "", "Recapture")
		hint(ui, "Esc", "", "Back")
	}
	p.end(ui)
}

draw_capture :: proc(c: ^p.Canvas, r: p.Rect, st: ^St) {
	if !st.shot.ok {
		p.fill_rect(c, r, p.hex(0x1f1f1f))
		return
	}
	dst := p.fitted_rect(f32(st.shot.img.w), f32(st.shot.img.h), r, .Contain)
	p.push_clip(c, r)
	p.fill_rect(c, r, p.hex(0x0a0a0a))
	p.draw_image(c, st.shot.img, dst)
	st.shot_rect = dst

	sx := dst.w / f32(st.shot.img.w)
	sy := dst.h / f32(st.shot.img.h)
	cx := dst.x + (f32(st.px) + 0.5) * sx
	cy := dst.y + (f32(st.py) + 0.5) * sy

	// Crosshair: a dark line with a light one on top, so it is visible against
	// whatever it is lying over.
	p.fill_rect(c, {dst.x, cy - 1, dst.w, 3}, p.hexa(0x00000066))
	p.fill_rect(c, {cx - 1, dst.y, 3, dst.h}, p.hexa(0x00000066))
	p.fill_rect(c, {dst.x, cy, dst.w, 1}, p.hexa(0xffffffcc))
	p.fill_rect(c, {cx, dst.y, 1, dst.h}, p.hexa(0xffffffcc))
	p.stroke_round_rect(c, {cx - 7, cy - 7, 15, 15}, {2, 2, 2, 2}, 1, p.hexa(0xffffffee))
	p.pop_clip(c)
}

// draw_loupe magnifies the capture around the crosshair with nearest-neighbour
// sampling and draws a pixel grid, so "the pixel under the cross" is
// unambiguous rather than a guess at a blurry centre.
draw_loupe :: proc(c: ^p.Canvas, r: p.Rect, st: ^St) {
	if !st.shot.ok {
		p.fill_rect(c, r, p.hex(0x1f1f1f))
		return
	}
	img := st.shot.img
	cell := f32(max(st.zoom, 2))
	// Odd counts, so there is a true centre cell for the pixel being sampled.
	cols := max(1, int(r.w / cell))
	rows := max(1, int(r.h / cell))
	if cols % 2 == 0 {cols -= 1}
	if rows % 2 == 0 {rows -= 1}
	ox := r.x + (r.w - f32(cols) * cell) * 0.5
	oy := r.y + (r.h - f32(rows) * cell) * 0.5

	p.push_clip(c, r)
	p.fill_rect(c, r, p.hex(0x0a0a0a))

	for gy in 0 ..< rows {
		iy := st.py + gy - rows / 2
		for gx in 0 ..< cols {
			ix := st.px + gx - cols / 2
			if ix < 0 || iy < 0 || ix >= img.w || iy >= img.h {
				continue
			}
			v := img.px[iy * img.w + ix]
			col := p.rgba(u8(v >> 16), u8(v >> 8), u8(v))
			p.fill_rect(c, {ox + f32(gx) * cell, oy + f32(gy) * cell, cell, cell}, col)
		}
	}

	// A faint grid once the cells are big enough to have edges.
	if cell >= 6 {
		for gy in 0 ..= rows {
			p.fill_rect(c, {ox, oy + f32(gy) * cell, f32(cols) * cell, 1}, p.hexa(0x00000022))
		}
		for gx in 0 ..= cols {
			p.fill_rect(c, {ox + f32(gx) * cell, oy, 1, f32(rows) * cell}, p.hexa(0x00000022))
		}
	}

	// The centre cell, outlined twice for contrast.
	bx := ox + f32(cols / 2) * cell
	by := oy + f32(rows / 2) * cell
	p.stroke_round_rect(c, {bx - 1, by - 1, cell + 2, cell + 2}, {0, 0, 0, 0}, 1, p.hexa(0x000000cc))
	p.stroke_round_rect(c, {bx, by, cell, cell}, {0, 0, 0, 0}, 1, p.hexa(0xffffffff))
	p.pop_clip(c)
}
