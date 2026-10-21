package main

// The command-line front end of the colour picker: `palm color …`.
//
// Nothing here has maths or storage of its own. A colour argument is read by
// parse_color, the same procedure behind the window's Ctrl+V; the notations
// printed are fmt_hex/fmt_rgb/fmt_hsl/fmt_oklch, what Ctrl+1..4 copy; the
// contrast figures are the contrast card's contrast_ratio and wcag_grade; the
// palette is palette.odin, which the window's Ctrl+S and Delete also go
// through; `sample` reads a pixel with pixel_at, the loupe's own sampler; and
// `pick` is the window's F3 — capture_screen and cursor_pos — so with no
// compositor or no grim it says unavailable rather than guessing.
//
// The palette is the one thing written, at
// ~/.local/share/palmy-colorpick/palette, and only by save, remove and clear.

import "core:fmt"
import "core:os"
import "core:strings"
import kit "kit:."
import p "palmy:."

// ---------------------------------------------------------------------------
// What the commands print
// ---------------------------------------------------------------------------

COLOR_FIELDS :: []kit.Field {
	{name = "input", kind = .String, help = "what was given"},
	{name = "notation", kind = .String, help = "how it was read: hex, rgb, hsl or oklch"},
	{name = "hex", kind = .String, help = "#rrggbb, what Ctrl+1 copies"},
	{name = "rgb", kind = .String, help = "rgb(r, g, b), Ctrl+2"},
	{name = "hsl", kind = .String, help = "hsl(h, s%, l%), Ctrl+3"},
	{name = "oklch", kind = .String, help = "oklch(L C H), Ctrl+4; as written when the input was oklch"},
	{name = "css_var", kind = .String},
	{name = "r", kind = .Int},
	{name = "g", kind = .Int},
	{name = "b", kind = .Int},
	{name = "in_gamut", kind = .Bool, help = "false for an oklch() outside sRGB; the other notations are then the clipped colour"},
	{name = "luminance", kind = .Float, help = "WCAG relative luminance, 0..1"},
	{name = "ink", kind = .String, help = "black or white, whichever reads better on it (the swatch's own choice)"},
}

CONTRAST_FIELDS :: []kit.Field {
	{name = "foreground", kind = .String, help = "hex"},
	{name = "background", kind = .String, help = "hex"},
	{name = "ratio", kind = .Float, help = "WCAG 2.1, 1..21"},
	{name = "ratio_text", kind = .String, help = "as the contrast card shows it: 4.54:1"},
	{name = "normal", kind = .String, help = "body text: AAA, AA or fail"},
	{name = "large", kind = .String, help = "large text and UI components: AAA, AA or fail"},
}

SWATCH_FIELDS :: []kit.Field {
	{name = "index", kind = .Int, help = "0 is the newest, the first swatch in the window"},
	{name = "hex", kind = .String},
	{name = "oklch", kind = .String},
}

PALETTE_FIELDS :: []kit.Field {
	{name = "path", kind = .String},
	{name = "count", kind = .Int},
	{name = "capacity", kind = .Int},
	{name = "colors", kind = .Array, of = SWATCH_FIELDS},
}

SAVED_FIELDS :: []kit.Field {
	{name = "hex", kind = .String},
	{name = "index", kind = .Int, help = "where it is now; 0 for a new colour"},
	{name = "already", kind = .Bool, help = "it was in the palette already, which is left as it was"},
	{name = "count", kind = .Int},
	{name = "path", kind = .String},
}

REMOVED_FIELDS :: []kit.Field {
	{name = "hex", kind = .String},
	{name = "count", kind = .Int, help = "what is left"},
	{name = "path", kind = .String},
}

CLEARED_FIELDS :: []kit.Field {
	{name = "removed", kind = .Int},
	{name = "path", kind = .String},
}

SAMPLE_FIELDS :: []kit.Field {
	{name = "source", kind = .String, help = "the image, or \"screen\""},
	{name = "x", kind = .Int},
	{name = "y", kind = .Int},
	{name = "width", kind = .Int, help = "of the image or the capture"},
	{name = "height", kind = .Int},
	{name = "hex", kind = .String},
	{name = "rgb", kind = .String},
	{name = "oklch", kind = .String},
}

// ---------------------------------------------------------------------------
// The declaration
// ---------------------------------------------------------------------------

@(private = "file")
COMMANDS := []kit.Command {
	{
		verb = "convert",
		summary = "one colour in every notation the editor shows: hex, rgb, hsl, oklch",
		effect = .Read,
		args = {{name = "color", kind = .String, required = true, help = "#3b82f6, 3b82f6, #38f, rgb(59 130 246), hsl(217 91% 60%), oklch(0.62 0.19 260)"}},
		out = COLOR_FIELDS,
		examples = {"color convert \"#3b82f6\" --json", "color convert \"oklch(0.7 0.4 150)\" --json"},
		run = cmd_convert,
	},
	{
		verb = "contrast",
		summary = "the WCAG contrast ratio of text on a background, and its grades",
		effect = .Read,
		args = {
			{name = "foreground", kind = .String, required = true},
			{name = "background", kind = .String, required = true},
		},
		out = CONTRAST_FIELDS,
		examples = {"color contrast \"#767676\" white --json", "color contrast \"rgb(255 255 255)\" \"#3b82f6\" --json"},
		run = cmd_contrast,
	},
	{
		verb = "palette",
		summary = "the saved palette, newest first, as the window's strip shows it",
		effect = .Read,
		aliases = {"list"},
		out = PALETTE_FIELDS,
		examples = {"color palette --json"},
		run = cmd_palette,
	},
	{
		verb = "save",
		summary = "put a colour first in the palette (the window's Ctrl+S); a duplicate stays where it is",
		effect = .Idempotent,
		aliases = {"add"},
		args = {{name = "color", kind = .String, required = true}},
		out = SAVED_FIELDS,
		examples = {"color save \"#e11d48\" --json"},
		run = cmd_save,
	},
	{
		verb = "remove",
		summary = "take one colour out of the palette (Delete on a swatch)",
		effect = .Mutate,
		aliases = {"rm"},
		args = {{name = "color", kind = .String, required = true, help = "a colour, matched by its 8-bit value"}},
		out = REMOVED_FIELDS,
		examples = {"color remove \"#e11d48\" --json"},
		run = cmd_remove,
	},
	{
		verb = "clear",
		summary = "empty the palette",
		effect = .Destructive,
		out = CLEARED_FIELDS,
		examples = {"color clear --yes --json"},
		run = cmd_clear,
	},
	{
		verb = "sample",
		summary = "the colour of one pixel of an image, read the way the loupe reads the screen",
		effect = .Read,
		args = {{name = "image", kind = .Path, required = true}},
		flags = {
			// Not --x/--y: the kit reads `--y` as its own `-y` (--yes).
			{name = "left", kind = .Int, def = "0", help = "x, from the left edge"},
			{name = "top", kind = .Int, def = "0", help = "y, from the top edge"},
		},
		out = SAMPLE_FIELDS,
		examples = {"color sample screenshot.png --left 40 --top 12 --json"},
		run = cmd_sample,
	},
	{
		verb = "pick",
		summary = "the colour on screen under the pointer, or at --left/--top (the window's F3; needs grim)",
		effect = .Read,
		flags = {
			{name = "left", kind = .Int, help = "x in the capture; with --top, instead of the pointer"},
			{name = "top", kind = .Int, help = "y in the capture"},
		},
		out = SAMPLE_FIELDS,
		examples = {"color pick --json", "color pick --left 100 --top 100 --json"},
		run = cmd_pick,
	},
}

@(private = "file")
g_surface: kit.Surface

surface :: proc() -> ^kit.Surface {
	if g_surface.noun == "" {
		g_surface = kit.Surface {
			noun     = "color",
			summary  = "a colour picker: convert between notations, check contrast, keep a palette, sample pixels",
			gui      = true,
			selftest = cli_selftest,
			notes    = SURFACE_NOTES,
			commands = COMMANDS,
		}
	}
	return &g_surface
}

@(private = "file")
SURFACE_NOTES :: `A colour is any notation the editor writes or reads: #rgb, #rrggbb (the # is
optional; quote it in a shell), rgb(), hsl() or oklch(), with commas or spaces.
The palette is ~/.local/share/palmy-colorpick/palette, shared with the window.
pick reads the screen through grim and the pointer through hyprctl; without a
compositor or grim it is unavailable (6). colorpick --shots <dir> still renders
the window offscreen.`

cli_selftest :: proc() -> int {
	fails := selftest()
	fails += cli_core_selftest()
	return fails == 0 ? 0 : 1
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

@(private = "file")
colour_arg :: proc(c: ^kit.Call, name: string) -> (pc: Parsed_Color, code: int) {
	text := kit.cli_str(c, name)
	got, ok := parse_color(text)
	if !ok {
		code = kit.cli_failf(c, kit.EXIT_USAGE, "%q is not a colour: give #rrggbb, rgb(), hsl() or oklch()", text)
		kit.cli_err_field(c, "given", text)
		return {}, code
	}
	return got, kit.EXIT_OK
}

fmt_lch :: proc(lch: [3]f32, al := context.temp_allocator) -> string {
	return fmt.aprintf("oklch(%.4f %.4f %.2f)", lch[0], lch[1], lch[2], allocator = al)
}

// colour_json fills the shape COLOR_FIELDS declares.
@(private = "file")
colour_json :: proc(o: ^kit.Json, input: string, pc: Parsed_Color) {
	b := to_bytes(pc.rgb)
	kit.jset_str(o, "input", input)
	kit.jset_str(o, "notation", pc.notation)
	kit.jset_str(o, "hex", fmt_hex(pc.rgb))
	kit.jset_str(o, "rgb", fmt_rgb(pc.rgb))
	kit.jset_str(o, "hsl", fmt_hsl(pc.rgb))
	kit.jset_str(o, "oklch", pc.notation == "oklch" ? fmt_lch(pc.lch) : fmt_oklch(pc.rgb))
	kit.jset_str(o, "css_var", pc.notation == "oklch" ? fmt.tprintf("--color: %s;", fmt_lch(pc.lch)) : fmt_css_var(pc.rgb))
	kit.jset_int(o, "r", int(b[0]))
	kit.jset_int(o, "g", int(b[1]))
	kit.jset_int(o, "b", int(b[2]))
	kit.jset_bool(o, "in_gamut", pc.in_gamut)
	kit.jset_num(o, "luminance", round_to(relative_luminance(pc.rgb), 10000))
	kit.jset_str(o, "ink", ink_for(pc.rgb) == p.BLACK ? "black" : "white")
}

@(private = "file")
round_to :: proc(v: f32, scale: f64) -> f64 {
	// In f64: an f32 widened after rounding prints as 0.23929999768733978.
	return f64(i64(f64(v) * scale + 0.5)) / scale
}

// pixel_at reads one pixel of a decoded image, clamped to its edges. The
// loupe's sample_at and `color sample` both read through it.
pixel_at :: proc(img: p.Image, x, y: int) -> [3]u8 {
	if img.w <= 0 || img.h <= 0 {
		return {0, 0, 0}
	}
	cx := clamp(x, 0, img.w - 1)
	cy := clamp(y, 0, img.h - 1)
	v := img.px[cy * img.w + cx]
	return {u8(v >> 16), u8(v >> 8), u8(v)}
}

@(private = "file")
sample_json :: proc(c: ^kit.Call, source: string, x, y, w, h: int, px: [3]u8) {
	rgb := from_bytes(px)
	kit.jset_str(c.out, "source", source)
	kit.jset_int(c.out, "x", x)
	kit.jset_int(c.out, "y", y)
	kit.jset_int(c.out, "width", w)
	kit.jset_int(c.out, "height", h)
	kit.jset_str(c.out, "hex", fmt_hex(rgb))
	kit.jset_str(c.out, "rgb", fmt_rgb(rgb))
	kit.jset_str(c.out, "oklch", fmt_oklch(rgb))
}

// ---------------------------------------------------------------------------
// The commands
// ---------------------------------------------------------------------------

@(private = "file")
cmd_convert :: proc(c: ^kit.Call) -> int {
	pc, code := colour_arg(c, "color")
	if code != kit.EXIT_OK {
		return code
	}
	colour_json(c.out, kit.cli_str(c, "color"), pc)
	if !pc.in_gamut {
		kit.cli_note(c, "outside sRGB: hex, rgb and hsl are the clipped colour")
	}
	return kit.EXIT_OK
}

// named lets contrast take the two words a person reaches for first.
@(private = "file")
named :: proc(c: ^kit.Call, name: string) -> (pc: Parsed_Color, code: int) {
	switch strings.to_lower(strings.trim_space(kit.cli_str(c, name)), context.temp_allocator) {
	case "white":
		return {rgb = {1, 1, 1}, notation = "hex", in_gamut = true}, kit.EXIT_OK
	case "black":
		return {rgb = {0, 0, 0}, notation = "hex", in_gamut = true}, kit.EXIT_OK
	}
	return colour_arg(c, name)
}

@(private = "file")
cmd_contrast :: proc(c: ^kit.Call) -> int {
	fg, code := named(c, "foreground")
	if code != kit.EXIT_OK {
		return code
	}
	bg, code2 := named(c, "background")
	if code2 != kit.EXIT_OK {
		return code2
	}
	r := contrast_ratio(fg.rgb, bg.rgb)
	kit.jset_str(c.out, "foreground", fmt_hex(fg.rgb))
	kit.jset_str(c.out, "background", fmt_hex(bg.rgb))
	kit.jset_num(c.out, "ratio", round_to(r, 100))
	kit.jset_str(c.out, "ratio_text", fmt.tprintf("%.2f:1", r))
	kit.jset_str(c.out, "normal", wcag_grade(r, false))
	kit.jset_str(c.out, "large", wcag_grade(r, true))
	return kit.EXIT_OK
}

@(private = "file")
cmd_palette :: proc(c: ^kit.Call) -> int {
	pal := make([dynamic][3]u8, context.temp_allocator)
	palette_read(&pal)
	arr := kit.jarr()
	for b, i in pal {
		s := kit.jobj()
		kit.jset_int(s, "index", i)
		kit.jset_str(s, "hex", fmt_hex(from_bytes(b)))
		kit.jset_str(s, "oklch", fmt_oklch(from_bytes(b)))
		kit.jpush(arr, s)
	}
	kit.jset_str(c.out, "path", palette_path())
	kit.jset_int(c.out, "count", len(pal))
	kit.jset_int(c.out, "capacity", PALETTE_CAP)
	kit.jset(c.out, "colors", arr)
	return kit.EXIT_OK
}

@(private = "file")
no_home :: proc(c: ^kit.Call) -> int {
	return kit.cli_fail(c, kit.EXIT_UNAVAILABLE, "no home directory to keep the palette in")
}

@(private = "file")
cmd_save :: proc(c: ^kit.Call) -> int {
	pc, code := colour_arg(c, "color")
	if code != kit.EXIT_OK {
		return code
	}
	if palette_path() == "" {
		return no_home(c)
	}
	pal := make([dynamic][3]u8, context.temp_allocator)
	palette_read(&pal)
	at, already := palette_add(&pal, to_bytes(pc.rgb))
	if !already && !c.dry_run && !palette_write(pal[:]) {
		return kit.cli_failf(c, kit.EXIT_FAILED, "could not write %s", palette_path())
	}
	kit.jset_str(c.out, "hex", fmt_hex(pc.rgb))
	kit.jset_int(c.out, "index", at)
	kit.jset_bool(c.out, "already", already)
	kit.jset_int(c.out, "count", len(pal))
	kit.jset_str(c.out, "path", palette_path())
	return kit.EXIT_OK
}

@(private = "file")
cmd_remove :: proc(c: ^kit.Call) -> int {
	pc, code := colour_arg(c, "color")
	if code != kit.EXIT_OK {
		return code
	}
	if palette_path() == "" {
		return no_home(c)
	}
	pal := make([dynamic][3]u8, context.temp_allocator)
	palette_read(&pal)
	i, found := palette_index(pal[:], to_bytes(pc.rgb))
	if !found {
		return kit.cli_failf(c, kit.EXIT_NOT_FOUND, "%s is not in the palette", fmt_hex(pc.rgb))
	}
	palette_remove_at(&pal, i)
	if !c.dry_run && !palette_write(pal[:]) {
		return kit.cli_failf(c, kit.EXIT_FAILED, "could not write %s", palette_path())
	}
	kit.jset_str(c.out, "hex", fmt_hex(pc.rgb))
	kit.jset_int(c.out, "count", len(pal))
	kit.jset_str(c.out, "path", palette_path())
	return kit.EXIT_OK
}

@(private = "file")
cmd_clear :: proc(c: ^kit.Call) -> int {
	if palette_path() == "" {
		return no_home(c)
	}
	pal := make([dynamic][3]u8, context.temp_allocator)
	palette_read(&pal)
	if !c.dry_run && len(pal) > 0 && !palette_write({}) {
		return kit.cli_failf(c, kit.EXIT_FAILED, "could not write %s", palette_path())
	}
	kit.jset_int(c.out, "removed", len(pal))
	kit.jset_str(c.out, "path", palette_path())
	return kit.EXIT_OK
}

@(private = "file")
cmd_sample :: proc(c: ^kit.Call) -> int {
	path := kit.cli_str(c, "image")
	if !os.exists(path) {
		return kit.cli_failf(c, kit.EXIT_NOT_FOUND, "%s does not exist", path)
	}
	if os.is_directory(path) {
		return kit.cli_failf(c, kit.EXIT_USAGE, "%s is a folder", path)
	}
	img, ok := p.load_image(path, context.temp_allocator)
	if !ok || img.w <= 0 || img.h <= 0 {
		return kit.cli_failf(c, kit.EXIT_FAILED, "%s is not an image this can decode", path)
	}
	x := kit.cli_int(c, "left", 0)
	y := kit.cli_int(c, "top", 0)
	if x < 0 || y < 0 || x >= img.w || y >= img.h {
		code := kit.cli_failf(c, kit.EXIT_USAGE, "%d, %d is outside the %d x %d image", x, y, img.w, img.h)
		kit.cli_err_field(c, "width", img.w)
		kit.cli_err_field(c, "height", img.h)
		return code
	}
	sample_json(c, path, x, y, img.w, img.h, pixel_at(img, x, y))
	return kit.EXIT_OK
}

@(private = "file")
cmd_pick :: proc(c: ^kit.Call) -> int {
	if os.get_env("WAYLAND_DISPLAY", context.temp_allocator) == "" {
		return kit.cli_fail(c, kit.EXIT_UNAVAILABLE, "no Wayland session to capture (WAYLAND_DISPLAY is unset)")
	}
	st := St {
		have_grim = kit.has_tool("grim"),
		have_hypr = kit.has_tool("hyprctl"),
	}
	if !st.have_grim {
		return kit.cli_fail(c, kit.EXIT_UNAVAILABLE, "grim is not installed")
	}
	if !capture_screen(&st) {
		return kit.cli_fail(c, kit.EXIT_UNAVAILABLE, "grim could not capture the screen")
	}
	defer p.image_destroy(&st.shot.img)
	x, y: int
	if kit.cli_has(c, "left") || kit.cli_has(c, "top") {
		x, y = kit.cli_int(c, "left", 0), kit.cli_int(c, "top", 0)
	} else {
		cx, cy, ok := cursor_pos(&st)
		if !ok {
			return kit.cli_fail(c, kit.EXIT_UNAVAILABLE, "no pointer position (hyprctl); pass --left and --top")
		}
		x, y = cx, cy
	}
	x = clamp(x, 0, st.shot.img.w - 1)
	y = clamp(y, 0, st.shot.img.h - 1)
	// A read stays a read: F3 also files the colour in the palette, and here
	// that is `color save` with what this printed.
	sample_json(c, "screen", x, y, st.shot.img.w, st.shot.img.h, pixel_at(st.shot.img, x, y))
	return kit.EXIT_OK
}
