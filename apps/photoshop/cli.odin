package main

// The command-line front end of the editor.
//
// Nothing below edits a pixel itself. Every command opens its input through
// open_file — the Open dialog's procedure, so the document is the one the
// window would show — and runs the editor's own operation on it:
//
//   adjust      commit_adjust, which is the Adjust dialog's preview_begin,
//               refresh_preview and preview_commit in one go; invert and
//               desaturate are run_pixel_op, the menu items
//   filter      commit_filter, the same for the Filter dialog
//   fill        do_fill, the paint bucket
//   pick        pick_at, the eyedropper, on the composite
//   new         new_document, the New dialog
//   info        histogram, the Levels panel's
//
// and writes the result through save_to, Ctrl-S's procedure. --region is the
// marquee (select_rect): an operation touches only the selection, exactly as
// in the window. The only encoder is PNG, so an output that is not .png is a
// usage error before any work is done, and an output that exists is refused
// unless --overwrite.

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import kit "kit:."

// ---------------------------------------------------------------------------
// What the commands print
// ---------------------------------------------------------------------------

WROTE_FIELDS :: []kit.Field {
	{name = "input", kind = .String, help = "\"\" for `new`"},
	{name = "output", kind = .String},
	{name = "operation", kind = .String, help = "the undo label the window would show: \"Gaussian Blur\", \"Fill\", …"},
	{name = "width", kind = .Int},
	{name = "height", kind = .Int},
	{name = "region", kind = .String, help = "x,y,w,h actually touched (the selection, clipped), or \"all\""},
	{name = "changed", kind = .Int, help = "pixels whose value changed"},
	{name = "bytes", kind = .Int, help = "the PNG written; 0 under --dry-run"},
}

INFO_FIELDS :: []kit.Field {
	{name = "path", kind = .String},
	{name = "width", kind = .Int},
	{name = "height", kind = .Int},
	{name = "opaque", kind = .Int, help = "pixels with any alpha"},
	{name = "transparent", kind = .Int, help = "pixels with zero alpha"},
	{name = "mean", kind = .String, help = "mean colour of the opaque pixels, #RRGGBB"},
	{name = "mean_luma", kind = .Float, help = "0-255, Rec. 709"},
	{name = "histogram", kind = .Array, of = {{kind = .Int}}, help = "256 luma bins over the opaque pixels, as the Levels panel counts them"},
	{name = "peak", kind = .Int, help = "the largest bin"},
}

PICK_FIELDS :: []kit.Field {
	{name = "path", kind = .String},
	{name = "left", kind = .Int},
	{name = "top", kind = .Int},
	{name = "pixel", kind = .String, help = "the composite at that point, #RRGGBBAA"},
	{name = "alpha", kind = .Int},
	{name = "picked", kind = .Bool, help = "the eyedropper takes it: false on a fully transparent pixel"},
	{name = "color", kind = .String, opt = true, help = "what the eyedropper sets the foreground to, #RRGGBB"},
}

PARAM_ITEM :: []kit.Field {
	{name = "flag", kind = .String},
	{name = "name", kind = .String},
	{name = "min", kind = .Float},
	{name = "max", kind = .Float},
	{name = "step", kind = .Float},
	{name = "default", kind = .Float},
	{name = "unit", kind = .String},
}

OP_ITEM :: []kit.Field {
	{name = "verb", kind = .String, help = "adjust or filter"},
	{name = "kind", kind = .String, help = "what --kind takes"},
	{name = "name", kind = .String, help = "as the menu names it"},
	{name = "params", kind = .Array, of = PARAM_ITEM},
}

OPS_FIELDS :: []kit.Field {
	{name = "count", kind = .Int},
	{name = "operations", kind = .Array, of = OP_ITEM},
}

// ---------------------------------------------------------------------------
// The kinds, as --kind spells them
// ---------------------------------------------------------------------------

ADJUST_KINDS :: []string{"brightness-contrast", "hue-saturation", "levels", "invert", "desaturate"}
FILTER_KINDS :: []string{"blur", "sharpen", "edges", "emboss"}

// What --kind calls each one, and the flag each parameter is set by, in the
// order adjust_spec / filter_spec list them.
ADJUST_KIND_NAME := [Adjust_Kind]string {
	.Brightness_Contrast = "brightness-contrast",
	.Hue_Sat             = "hue-saturation",
	.Levels              = "levels",
}

FILTER_KIND_NAME := [Filter_Kind]string {
	.Gaussian_Blur = "blur",
	.Sharpen       = "sharpen",
	.Edge_Detect   = "edges",
	.Emboss        = "emboss",
}

ADJUST_PARAM_FLAGS := [Adjust_Kind][]string {
	.Brightness_Contrast = {"brightness", "contrast"},
	.Hue_Sat             = {"hue", "saturation", "lightness"},
	.Levels              = {"in-black", "in-white", "gamma", "out-black", "out-white"},
}

FILTER_PARAM_FLAGS := [Filter_Kind][]string {
	.Gaussian_Blur = {"radius"},
	.Sharpen       = {"radius", "amount"},
	.Edge_Detect   = {"strength"},
	.Emboss        = {"strength", "angle"},
}

ALL_ADJUST_FLAGS :: []string{"brightness", "contrast", "hue", "saturation", "lightness", "in-black", "in-white", "gamma", "out-black", "out-white"}
ALL_FILTER_FLAGS :: []string{"radius", "amount", "strength", "angle"}

// ---------------------------------------------------------------------------
// The declaration
// ---------------------------------------------------------------------------

@(private = "file")
COMMANDS := []kit.Command {
	{
		verb = "info",
		summary = "size, transparency, mean colour and the Levels panel's luma histogram",
		effect = .Read,
		args = {{name = "image", kind = .Path, required = true}},
		out = INFO_FIELDS,
		examples = {"photoshop info photo.png --json"},
		run = cmd_info,
	},
	{
		verb = "adjustments",
		summary = "every adjustment and filter, with each parameter's flag, range and default",
		effect = .Read,
		aliases = {"operations"},
		out = OPS_FIELDS,
		examples = {"photoshop adjustments --json"},
		run = cmd_adjustments,
	},
	{
		verb = "adjust",
		summary = "an Image > Adjustments item, applied as the dialog's Apply would",
		effect = .Mutate,
		args = {{name = "input", kind = .Path, required = true}, {name = "output", kind = .Path, required = true, help = "a .png"}},
		flags = {
			{name = "kind", kind = .Enum, values = ADJUST_KINDS, required = true},
			{name = "brightness", kind = .Float, help = "brightness-contrast: -100..100"},
			{name = "contrast", kind = .Float, help = "brightness-contrast: -100..100"},
			{name = "hue", kind = .Float, help = "hue-saturation: -180..180 degrees"},
			{name = "saturation", kind = .Float, help = "hue-saturation: -100..100"},
			{name = "lightness", kind = .Float, help = "hue-saturation: -100..100"},
			{name = "in-black", kind = .Float, help = "levels: 0..254"},
			{name = "in-white", kind = .Float, help = "levels: 1..255"},
			{name = "gamma", kind = .Float, help = "levels: 0.1..4"},
			{name = "out-black", kind = .Float, help = "levels: 0..255"},
			{name = "out-white", kind = .Float, help = "levels: 0..255"},
			{name = "region", kind = .String, help = "x,y,w,h: the selection to confine it to"},
			{name = "overwrite", kind = .Bool, help = "replace the output if it exists"},
		},
		out = WROTE_FIELDS,
		examples = {
			"photoshop adjust photo.png brighter.png --kind brightness-contrast --brightness 20 --contrast 10 --json",
			"photoshop adjust photo.png grey.png --kind desaturate --region 0,0,200,100 --json",
		},
		run = cmd_adjust,
	},
	{
		verb = "filter",
		summary = "a Filter menu item: gaussian blur, unsharp mask, Sobel edges, emboss",
		effect = .Mutate,
		args = {{name = "input", kind = .Path, required = true}, {name = "output", kind = .Path, required = true, help = "a .png"}},
		flags = {
			{name = "kind", kind = .Enum, values = FILTER_KINDS, required = true},
			{name = "radius", kind = .Float, help = "blur: 0.5..40 px; sharpen: 0.5..12 px"},
			{name = "amount", kind = .Float, help = "sharpen: 0..300 %"},
			{name = "strength", kind = .Float, help = "edges, emboss: 10..400 %"},
			{name = "angle", kind = .Float, help = "emboss: 0..315 degrees"},
			{name = "region", kind = .String, help = "x,y,w,h: the selection to confine it to"},
			{name = "overwrite", kind = .Bool, help = "replace the output if it exists"},
		},
		out = WROTE_FIELDS,
		examples = {"photoshop filter photo.png soft.png --kind blur --radius 6 --json"},
		run = cmd_filter,
	},
	{
		verb = "fill",
		summary = "the paint bucket: flood-fill the contiguous area around a point",
		effect = .Mutate,
		args = {{name = "input", kind = .Path, required = true}, {name = "output", kind = .Path, required = true, help = "a .png"}},
		flags = {
			// Not --x/--y: the kit reads `--y` as its own -y (C3).
			{name = "left", kind = .Int, required = true, help = "x of the seed pixel"},
			{name = "top", kind = .Int, required = true, help = "y of the seed pixel"},
			{name = "color", kind = .String, def = "#e11d48", help = "#rgb, #rrggbb or #rrggbbaa"},
			{name = "tolerance", kind = .Int, def = "32", help = "0..255, the largest channel difference still filled"},
			{name = "region", kind = .String, help = "x,y,w,h: the selection the fill may not leave"},
			{name = "overwrite", kind = .Bool, help = "replace the output if it exists"},
		},
		out = WROTE_FIELDS,
		examples = {"photoshop fill photo.png filled.png --left 10 --top 10 --color \"#3b82f6\" --json"},
		run = cmd_fill,
	},
	{
		verb = "pick",
		summary = "the eyedropper: the composite colour at a point",
		effect = .Read,
		args = {{name = "image", kind = .Path, required = true}},
		flags = {{name = "left", kind = .Int, required = true}, {name = "top", kind = .Int, required = true}},
		out = PICK_FIELDS,
		examples = {"photoshop pick photo.png --left 10 --top 20 --json"},
		run = cmd_pick,
	},
	{
		verb = "new",
		summary = "a blank document, as File > New makes it, saved as PNG",
		effect = .Mutate,
		args = {{name = "output", kind = .Path, required = true, help = "a .png"}},
		flags = {
			{name = "width", kind = .Int, def = "1024", help = "1..16384"},
			{name = "height", kind = .Int, def = "768", help = "1..16384"},
			{name = "fill", kind = .String, def = "white", help = "white, transparent, or a colour (#rrggbb)"},
			{name = "overwrite", kind = .Bool, help = "replace the output if it exists"},
		},
		out = WROTE_FIELDS,
		examples = {"photoshop new canvas.png --width 640 --height 480 --fill \"#0f172a\" --json"},
		run = cmd_new,
	},
}

@(private = "file")
g_surface: kit.Surface

surface :: proc() -> ^kit.Surface {
	if g_surface.noun == "" {
		g_surface = kit.Surface {
			noun       = "photoshop",
			summary    = "a raster image editor: adjustments, filters, fill and the eyedropper over PNG",
			gui        = true,
			takes_path = true,
			takes_word = kit.cli_word_is_path,
			selftest   = cli_selftest,
			notes      = SURFACE_NOTES,
			commands   = COMMANDS,
		}
	}
	return &g_surface
}

@(private = "file")
SURFACE_NOTES :: `Each command opens its input as the Open dialog does (a one-layer document) and
runs the editor's own operation; the output is the flattened composite, written as
Ctrl-S writes it — PNG only. --region x,y,w,h is the marquee selection. An output
that exists is refused unless --overwrite. A bare path opens the window on it; the
older --shot and --bench modes still render offscreen.`

cli_selftest :: proc() -> int {
	return selftest() ? 0 : 1
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

@(private = "file")
fresh :: proc(st: ^St) {
	st_init(st)
}

@(private = "file")
release :: proc(st: ^St) {
	doc_free(&st.doc)
	hist_free(&st.hist)
	stroke_free(&st.stroke)
	delete(st.prev_base)
	st.prev_base = nil
}

// load opens a file the way the Open dialog does, or records why not.
@(private = "file")
load :: proc(c: ^kit.Call, st: ^St, name: string) -> int {
	path := kit.cli_str(c, name)
	if !os.exists(path) {
		return kit.cli_failf(c, kit.EXIT_NOT_FOUND, "%s does not exist", path)
	}
	if os.is_directory(path) {
		return kit.cli_failf(c, kit.EXIT_USAGE, "%s is a folder", path)
	}
	if !open_file(st, path) {
		return kit.cli_failf(c, kit.EXIT_FAILED, "%s is not an image this can decode", path)
	}
	return kit.EXIT_OK
}

// out_check refuses an output before any work is done.
@(private = "file")
out_check :: proc(c: ^kit.Call) -> int {
	out := kit.cli_str(c, "output")
	if !strings.has_suffix(strings.to_lower(out, context.temp_allocator), ".png") {
		code := kit.cli_failf(c, kit.EXIT_USAGE, "%s: the only encoder here is PNG, so the output must end in .png", out)
		kit.cli_err_field(c, "reason", "not_png")
		return code
	}
	if os.is_directory(out) {
		return kit.cli_failf(c, kit.EXIT_USAGE, "%s is a folder", out)
	}
	if os.exists(out) && !kit.cli_bool(c, "overwrite") {
		code := kit.cli_failf(c, kit.EXIT_FAILED, "%s exists (pass --overwrite to replace it)", out)
		kit.cli_err_field(c, "reason", "exists")
		return code
	}
	return kit.EXIT_OK
}

// parse_region reads `x,y,w,h`.
parse_region :: proc(s: string) -> (x, y, w, h: int, ok: bool) {
	parts := strings.split(s, ",", context.temp_allocator)
	if len(parts) != 4 {
		return
	}
	v: [4]int
	for part, i in parts {
		n, good := strconv.parse_int(strings.trim_space(part))
		if !good {
			return
		}
		v[i] = n
	}
	if v[2] <= 0 || v[3] <= 0 {
		return
	}
	return v[0], v[1], v[2], v[3], true
}

// apply_region turns --region into the selection, as the marquee would.
@(private = "file")
apply_region :: proc(c: ^kit.Call, st: ^St) -> int {
	if !kit.cli_has(c, "region") {
		return kit.EXIT_OK
	}
	x, y, w, h, ok := parse_region(kit.cli_str(c, "region"))
	if !ok {
		return kit.cli_failf(c, kit.EXIT_USAGE, "--region is x,y,w,h with a positive width and height, not %q", kit.cli_str(c, "region"))
	}
	if !select_rect(st, x, y, w, h) {
		return kit.cli_failf(c, kit.EXIT_USAGE, "--region %s lies outside the %dx%d image", kit.cli_str(c, "region"), st.doc.w, st.doc.h)
	}
	return kit.EXIT_OK
}

@(private = "file")
region_text :: proc(st: ^St) -> string {
	if !st.has_sel {
		return "all"
	}
	r := clip_rect(st)
	return fmt.tprintf("%d,%d,%d,%d", r.x0, r.y0, r.x1 - r.x0, r.y1 - r.y0)
}

// param_values reads the flags for one adjustment or filter: the spec's
// defaults, each given flag checked against the spec's range, and a flag that
// belongs to another kind refused rather than silently ignored.
@(private = "file")
param_values :: proc(
	c: ^kit.Call,
	kind_name: string,
	sp: Adjust_Spec,
	defaults: [MAX_PARAMS]f32,
	mine: []string,
	all: []string,
) -> (
	v: [MAX_PARAMS]f32,
	code: int,
) {
	v = defaults
	for f in all {
		if !kit.cli_has(c, f) {
			continue
		}
		at := -1
		for m, i in mine {
			if m == f {
				at = i
			}
		}
		if at < 0 {
			code = kit.cli_failf(c, kit.EXIT_USAGE, "--%s does not apply to --kind %s", f, kind_name)
			kit.cli_err_field(c, "flag", f)
			return
		}
		pm := sp.params[at]
		x := f32(kit.cli_f64(c, f))
		if x < pm.lo || x > pm.hi {
			code = kit.cli_failf(c, kit.EXIT_USAGE, "--%s %v is outside %v..%v", f, x, pm.lo, pm.hi)
			kit.cli_err_field(c, "flag", f)
			return
		}
		v[at] = x
	}
	return v, kit.EXIT_OK
}

// finish compares the layer with what it was,
// writes through save_to (unless --dry-run) and fills the result.
@(private = "file")
finish :: proc(c: ^kit.Call, st: ^St, input: string, before: []u32, label_over := "", changed_over := -1) -> int {
	out := kit.cli_str(c, "output")
	l := active_layer(&st.doc)
	changed := 0
	if l != nil && before != nil {
		for i in 0 ..< min(len(before), len(l.px)) {
			if before[i] != l.px[i] {
				changed += 1
			}
		}
	}
	bytes := 0
	if !c.dry_run {
		if !save_to(st, out) {
			return kit.cli_fail(c, kit.EXIT_FAILED, toast_text(st))
		}
		if fi, err := os.stat(out, context.temp_allocator); err == nil {
			bytes = int(fi.size)
		}
	}
	label := label_over != "" ? label_over : hist_undo_label(&st.hist)
	if changed_over >= 0 {
		changed = changed_over
	}
	kit.jset_str(c.out, "input", input)
	kit.jset_str(c.out, "output", out)
	kit.jset_str(c.out, "operation", label)
	kit.jset_int(c.out, "width", st.doc.w)
	kit.jset_int(c.out, "height", st.doc.h)
	kit.jset_str(c.out, "region", region_text(st))
	kit.jset_int(c.out, "changed", changed)
	kit.jset_int(c.out, "bytes", bytes)
	return kit.EXIT_OK
}

// layer_copy is the active layer's pixels before the edit, for `changed`.
@(private = "file")
layer_copy :: proc(st: ^St) -> []u32 {
	l := active_layer(&st.doc)
	if l == nil {
		return nil
	}
	out := make([]u32, len(l.px), context.temp_allocator)
	copy(out, l.px)
	return out
}

// ---------------------------------------------------------------------------
// The commands
// ---------------------------------------------------------------------------

cmd_info :: proc(c: ^kit.Call) -> int {
	st: St
	fresh(&st)
	defer release(&st)
	if code := load(c, &st, "image"); code != kit.EXIT_OK {
		return code
	}
	d := &st.doc
	doc_dirty_all(d)
	doc_composite(d)
	bins, peak := histogram(d.comp, d.w, {0, 0, d.w, d.h})

	opaque := 0
	sum: [3]f64
	luma := 0.0
	for v in d.comp {
		if v & 0xff00_0000 == 0 {
			continue
		}
		opaque += 1
		r, g, b, _ := unpack_argb(v)
		sum += {f64(r), f64(g), f64(b)}
		luma += f64(LUMA_R) * f64(r) + f64(LUMA_G) * f64(g) + f64(LUMA_B) * f64(b)
	}
	mean := "#000000"
	if opaque > 0 {
		n := f64(opaque)
		mean = fmt.tprintf("#%02X%02X%02X", u8(sum[0] / n + 0.5), u8(sum[1] / n + 0.5), u8(sum[2] / n + 0.5))
		luma /= n
	}
	hist := kit.jarr()
	for b in bins {
		kit.jpush(hist, kit.jint(int(b)))
	}
	kit.jset_str(c.out, "path", d.path)
	kit.jset_int(c.out, "width", d.w)
	kit.jset_int(c.out, "height", d.h)
	kit.jset_int(c.out, "opaque", opaque)
	kit.jset_int(c.out, "transparent", d.w * d.h - opaque)
	kit.jset_str(c.out, "mean", mean)
	kit.jset_num(c.out, "mean_luma", f64(int(luma * 100 + 0.5)) / 100)
	kit.jset(c.out, "histogram", hist)
	kit.jset_int(c.out, "peak", int(peak))
	return kit.EXIT_OK
}

cmd_adjustments :: proc(c: ^kit.Call) -> int {
	ops := kit.jarr()
	add :: proc(ops: ^kit.Json, verb, kind, name: string, sp: Adjust_Spec, flags: []string) {
		o := kit.jobj()
		kit.jset_str(o, "verb", verb)
		kit.jset_str(o, "kind", kind)
		kit.jset_str(o, "name", name)
		ps := kit.jarr()
		for i in 0 ..< sp.n {
			pm := sp.params[i]
			q := kit.jobj()
			kit.jset_str(q, "flag", fmt.tprintf("--%s", flags[i]))
			kit.jset_str(q, "name", pm.name)
			kit.jset_num(q, "min", f64(pm.lo))
			kit.jset_num(q, "max", f64(pm.hi))
			kit.jset_num(q, "step", f64(pm.step))
			kit.jset_num(q, "default", f64(pm.def))
			kit.jset_str(q, "unit", strings.trim_space(pm.unit))
			kit.jpush(ps, q)
		}
		kit.jset(o, "params", ps)
		kit.jpush(ops, o)
	}
	for k in Adjust_Kind {
		add(ops, "adjust", ADJUST_KIND_NAME[k], ADJUST_NAMES[k], adjust_spec(k), ADJUST_PARAM_FLAGS[k])
	}
	add(ops, "adjust", "invert", "Invert", {}, nil)
	add(ops, "adjust", "desaturate", "Desaturate", {}, nil)
	for k in Filter_Kind {
		add(ops, "filter", FILTER_KIND_NAME[k], FILTER_NAMES[k], filter_spec(k), FILTER_PARAM_FLAGS[k])
	}
	kit.jset_int(c.out, "count", kit.jlen(ops))
	kit.jset(c.out, "operations", ops)
	return kit.EXIT_OK
}

cmd_adjust :: proc(c: ^kit.Call) -> int {
	kind := kit.cli_str(c, "kind")
	st: St
	fresh(&st)
	defer release(&st)

	// Parameters are checked before the image is decoded: a bad flag is a
	// usage error whatever the input is.
	v: [MAX_PARAMS]f32
	pixel_op: Pixel_Op
	ak := Adjust_Kind.Brightness_Contrast
	switch kind {
	case "invert", "desaturate":
		pixel_op = kind == "invert" ? invert_region : desaturate_region
		if _, code := param_values(c, kind, {}, {}, nil, ALL_ADJUST_FLAGS); code != kit.EXIT_OK {
			return code
		}
	case:
		for k in Adjust_Kind {
			if ADJUST_KIND_NAME[k] == kind {
				ak = k
			}
		}
		code: int
		v, code = param_values(c, kind, adjust_spec(ak), adjust_defaults(ak), ADJUST_PARAM_FLAGS[ak], ALL_ADJUST_FLAGS)
		if code != kit.EXIT_OK {
			return code
		}
		if ak == .Levels && v[1] <= v[0] {
			return kit.cli_failf(c, kit.EXIT_USAGE, "--in-white %v must be above --in-black %v", v[1], v[0])
		}
	}

	if code := out_check(c); code != kit.EXIT_OK {
		return code
	}
	if code := load(c, &st, "input"); code != kit.EXIT_OK {
		return code
	}
	if code := apply_region(c, &st); code != kit.EXIT_OK {
		return code
	}
	before := layer_copy(&st)
	if pixel_op != nil {
		run_pixel_op(&st, pixel_op, kind == "invert" ? "Invert" : "Desaturate")
	} else {
		commit_adjust(&st, ak, v)
	}
	return finish(c, &st, kit.cli_str(c, "input"), before)
}

cmd_filter :: proc(c: ^kit.Call) -> int {
	kind := kit.cli_str(c, "kind")
	fk := Filter_Kind.Gaussian_Blur
	for k in Filter_Kind {
		if FILTER_KIND_NAME[k] == kind {
			fk = k
		}
	}
	v, code := param_values(c, kind, filter_spec(fk), filter_defaults(fk), FILTER_PARAM_FLAGS[fk], ALL_FILTER_FLAGS)
	if code != kit.EXIT_OK {
		return code
	}
	if code = out_check(c); code != kit.EXIT_OK {
		return code
	}
	st: St
	fresh(&st)
	defer release(&st)
	if code = load(c, &st, "input"); code != kit.EXIT_OK {
		return code
	}
	if code = apply_region(c, &st); code != kit.EXIT_OK {
		return code
	}
	before := layer_copy(&st)
	commit_filter(&st, fk, v)
	return finish(c, &st, kit.cli_str(c, "input"), before)
}

cmd_fill :: proc(c: ^kit.Call) -> int {
	color, ok := parse_hex(kit.cli_str(c, "color"))
	if !ok {
		return kit.cli_failf(c, kit.EXIT_USAGE, "--color %q is not #rgb, #rrggbb or #rrggbbaa", kit.cli_str(c, "color"))
	}
	tol := kit.cli_int(c, "tolerance", 32)
	if tol < 0 || tol > 255 {
		return kit.cli_failf(c, kit.EXIT_USAGE, "--tolerance %d is outside 0..255", tol)
	}
	if code := out_check(c); code != kit.EXIT_OK {
		return code
	}
	st: St
	fresh(&st)
	defer release(&st)
	if code := load(c, &st, "input"); code != kit.EXIT_OK {
		return code
	}
	x, y := kit.cli_int(c, "left"), kit.cli_int(c, "top")
	if x < 0 || y < 0 || x >= st.doc.w || y >= st.doc.h {
		return kit.cli_failf(c, kit.EXIT_USAGE, "%d,%d is outside the %dx%d image", x, y, st.doc.w, st.doc.h)
	}
	if code := apply_region(c, &st); code != kit.EXIT_OK {
		return code
	}
	// The bucket's own settings: the foreground colour, full opacity, and
	// the tolerance `[`/`]` adjust in the window.
	st.fg = color
	st.brush.opacity = 1
	st.brush.flow_tol = f32(tol)
	before := layer_copy(&st)
	do_fill(&st, x, y)
	return finish(c, &st, kit.cli_str(c, "input"), before, "Fill")
}

cmd_pick :: proc(c: ^kit.Call) -> int {
	st: St
	fresh(&st)
	defer release(&st)
	if code := load(c, &st, "image"); code != kit.EXIT_OK {
		return code
	}
	d := &st.doc
	x, y := kit.cli_int(c, "left"), kit.cli_int(c, "top")
	if x < 0 || y < 0 || x >= d.w || y >= d.h {
		return kit.cli_failf(c, kit.EXIT_USAGE, "%d,%d is outside the %dx%d image", x, y, d.w, d.h)
	}
	doc_dirty_all(d)
	doc_composite(d)
	raw := d.comp[y * d.w + x]
	r, g, b, a := unpack_argb(raw)
	v, picked := pick_at(&st, x, y)
	kit.jset_str(c.out, "path", d.path)
	kit.jset_int(c.out, "left", x)
	kit.jset_int(c.out, "top", y)
	kit.jset_str(c.out, "pixel", fmt.tprintf("#%02X%02X%02X%02X", r, g, b, a))
	kit.jset_int(c.out, "alpha", int(a))
	kit.jset_bool(c.out, "picked", picked)
	if picked {
		kit.jset_str(c.out, "color", hex_string(v, context.temp_allocator))
	}
	return kit.EXIT_OK
}

cmd_new :: proc(c: ^kit.Call) -> int {
	if code := out_check(c); code != kit.EXIT_OK {
		return code
	}
	w, h := kit.cli_int(c, "width", 1024), kit.cli_int(c, "height", 768)
	if w < 1 || h < 1 || w > 16384 || h > 16384 {
		return kit.cli_failf(c, kit.EXIT_USAGE, "%dx%d is outside 1..16384 on a side", w, h)
	}
	st: St
	fresh(&st)
	defer release(&st)
	mode := 0
	switch fill := kit.cli_str(c, "fill"); fill {
	case "white", "":
	case "transparent":
		mode = 1
	case:
		v, ok := parse_hex(fill)
		if !ok {
			return kit.cli_failf(c, kit.EXIT_USAGE, "--fill is white, transparent or a colour, not %q", fill)
		}
		st.bg = v
		mode = 2
	}
	new_document(&st, w, h, mode)
	// No undo entry is made by New, so the label is the dialog's own name.
	return finish(c, &st, "", nil, "New", w * h)
}
