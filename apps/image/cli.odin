package main

// The command-line front end of the image viewer.
//
// Every command goes through core.odin, the procedures the viewer itself uses:
// `info` and `metadata` are its properties panel, `list` is its grid in the
// order the grid shows, `thumbnail` is the grid's thumbnail filter, `rotate`
// is its R key, and `render` is the viewer drawn offscreen, the same frame the
// window would paint. Decoding is the viewer's stb_image; writing is
// stb_image_write, to PNG, JPEG, BMP or TGA, chosen by the output's extension.
//
// Nothing is overwritten unless --overwrite says so, and --dry-run reports the
// size the output would have without writing it.

import "core:fmt"
import "core:os"
import "core:time"
import kit "kit:."
import p "palmy:."
import sc "shadcn:."

// ---------------------------------------------------------------------------
// What the commands print
// ---------------------------------------------------------------------------

INFO_FIELDS :: []kit.Field {
	{name = "path", kind = .String},
	{name = "name", kind = .String},
	{name = "format", kind = .String, help = "read from the bytes, not the extension"},
	{name = "decodable", kind = .Bool},
	{name = "width", kind = .Int},
	{name = "height", kind = .Int},
	{name = "channels", kind = .Int, help = "what the file stores: 1 grey … 4 RGBA"},
	{name = "channels_text", kind = .String},
	{name = "aspect", kind = .String},
	{name = "megapixels", kind = .Float},
	{name = "bytes", kind = .Int},
	{name = "size_text", kind = .String},
	{name = "bits_per_pixel", kind = .Float},
	{name = "modified", kind = .String, help = "UTC, ISO 8601"},
}

META_ITEM :: []kit.Field {
	{name = "key", kind = .String, help = "stable: make, model, date_taken, orientation, dpi, gps, text:<keyword>, …"},
	{name = "label", kind = .String},
	{name = "value", kind = .String},
}

METADATA_FIELDS :: []kit.Field {
	{name = "path", kind = .String},
	{name = "format", kind = .String},
	{name = "count", kind = .Int},
	{name = "entries", kind = .Array, of = META_ITEM},
}

LIST_FIELDS :: []kit.Field {
	{name = "dir", kind = .String},
	{name = "count", kind = .Int},
	{
		name = "images",
		kind = .Array,
		of = {
			{name = "name", kind = .String},
			{name = "path", kind = .String},
			{name = "format", kind = .String},
			{name = "width", kind = .Int},
			{name = "height", kind = .Int},
			{name = "bytes", kind = .Int},
		},
	},
}

WROTE_FIELDS :: []kit.Field {
	{name = "input", kind = .String},
	{name = "output", kind = .String},
	{name = "format", kind = .String, help = "what was written: png, jpg, bmp, tga"},
	{name = "width", kind = .Int},
	{name = "height", kind = .Int},
	{name = "bytes", kind = .Int, help = "the file written; 0 under --dry-run"},
}

RENDER_FIELDS :: []kit.Field {
	{name = "media", kind = .String},
	{name = "output", kind = .String},
	{name = "view", kind = .String, help = "library, viewer or grid"},
	{name = "width", kind = .Int},
	{name = "height", kind = .Int},
}

FORMATS_FIELDS :: []kit.Field {
	{name = "decode", kind = .Array, of = {{kind = .String}}},
	{name = "encode", kind = .Array, of = {{kind = .String}}},
}

// ---------------------------------------------------------------------------
// The declaration
// ---------------------------------------------------------------------------

@(private = "file")
OUT_FLAGS :: []kit.Param {
	{name = "overwrite", kind = .Bool, help = "replace the output if it exists"},
	{name = "quality", kind = .Int, def = "90", help = "JPEG quality, 1-100"},
}

@(private = "file")
COMMANDS := []kit.Command {
	{
		verb = "info",
		summary = "what the properties panel shows: format from the bytes, size, channels, aspect",
		effect = .Read,
		args = {{name = "file", kind = .Path, required = true}},
		out = INFO_FIELDS,
		examples = {"image info photo.jpg --json"},
		run = cmd_info,
	},
	{
		verb = "metadata",
		summary = "what the file says about itself: EXIF (camera, date taken, exposure, GPS), PNG text, resolution",
		effect = .Read,
		aliases = {"meta", "exif"},
		args = {{name = "file", kind = .Path, required = true}},
		out = METADATA_FIELDS,
		examples = {"image metadata photo.jpg --json"},
		run = cmd_metadata,
	},
	{
		verb = "list",
		summary = "the images in a folder, in the order the grid shows them (shot-9 before shot-10)",
		effect = .Read,
		args = {{name = "dir", kind = .Path, help = "the folder; the working directory when omitted"}},
		out = LIST_FIELDS,
		examples = {"image list --json", "image list ~/Pictures --json"},
		run = cmd_list,
	},
	{
		verb = "convert",
		summary = "re-encode to the format the output's extension names",
		effect = .Mutate,
		args = {{name = "input", kind = .Path, required = true}, {name = "output", kind = .Path, required = true}},
		flags = OUT_FLAGS,
		out = WROTE_FIELDS,
		examples = {"image convert photo.png photo.jpg --quality 85 --json"},
		run = cmd_convert,
	},
	{
		verb = "resize",
		summary = "scale to --width and/or --height (keeping the aspect when one is given), or by --scale",
		effect = .Mutate,
		args = {{name = "input", kind = .Path, required = true}, {name = "output", kind = .Path, required = true}},
		flags = {
			{name = "width", kind = .Int, aliases = {"w"}, help = "pixels"},
			{name = "height", kind = .Int, aliases = {"h"}, help = "pixels"},
			{name = "scale", kind = .Float, help = "a factor: 0.5 halves it"},
			{name = "overwrite", kind = .Bool, help = "replace the output if it exists"},
			{name = "quality", kind = .Int, def = "90", help = "JPEG quality, 1-100"},
		},
		out = WROTE_FIELDS,
		examples = {"image resize photo.jpg small.jpg --width 800 --json", "image resize icon.png icon@2x.png --scale 2 --json"},
		run = cmd_resize,
	},
	{
		verb = "crop",
		summary = "cut out a rectangle, clipped to the image",
		effect = .Mutate,
		args = {{name = "input", kind = .Path, required = true}, {name = "output", kind = .Path, required = true}},
		flags = {
			{name = "left", kind = .Int, def = "0", aliases = {"x"}, help = "x of the top-left corner"},
			{name = "top", kind = .Int, def = "0", aliases = {"y"}, help = "y of the top-left corner"},
			{name = "width", kind = .Int, required = true, aliases = {"w"}},
			{name = "height", kind = .Int, required = true, aliases = {"h"}},
			{name = "overwrite", kind = .Bool, help = "replace the output if it exists"},
			{name = "quality", kind = .Int, def = "90", help = "JPEG quality, 1-100"},
		},
		out = WROTE_FIELDS,
		examples = {"image crop photo.jpg face.jpg --left 120 --top 40 --width 300 --height 300 --json"},
		run = cmd_crop,
	},
	{
		verb = "rotate",
		summary = "turn by quarter turns, as the viewer's R does, and/or mirror",
		effect = .Mutate,
		args = {{name = "input", kind = .Path, required = true}, {name = "output", kind = .Path, required = true}},
		flags = {
			{name = "degrees", kind = .Enum, values = {"0", "90", "180", "270", "-90"}, def = "90", help = "clockwise"},
			{name = "flip", kind = .Enum, values = {"none", "horizontal", "vertical"}, def = "none", help = "mirror after turning"},
			{name = "overwrite", kind = .Bool, help = "replace the output if it exists"},
			{name = "quality", kind = .Int, def = "90", help = "JPEG quality, 1-100"},
		},
		out = WROTE_FIELDS,
		examples = {"image rotate scan.png scan-upright.png --degrees 270 --json"},
		run = cmd_rotate,
	},
	{
		verb = "thumbnail",
		summary = "a thumbnail no bigger than --size on its longest edge, with the grid's own box filter",
		effect = .Mutate,
		aliases = {"thumb"},
		args = {{name = "input", kind = .Path, required = true}, {name = "output", kind = .Path, required = true}},
		flags = {
			{name = "size", kind = .Int, def = "240", help = "longest edge in pixels (the grid uses 240)"},
			{name = "overwrite", kind = .Bool, help = "replace the output if it exists"},
			{name = "quality", kind = .Int, def = "90", help = "JPEG quality, 1-100"},
		},
		out = WROTE_FIELDS,
		examples = {"image thumbnail photo.jpg thumb.png --size 128 --json"},
		run = cmd_thumbnail,
	},
	{
		verb = "render",
		summary = "draw the viewer offscreen on a file or folder and write the frame as PNG (no window)",
		effect = .Mutate,
		args = {
			{name = "media", kind = .Path, help = "an image (viewer) or a folder (grid); omit for the library"},
			{name = "output", kind = .Path, required = true, help = "the PNG to write"},
		},
		flags = {
			{name = "seconds", kind = .Float, def = "1.5", help = "how long to let decoding and thumbnails run first"},
			{name = "keys", kind = .String, help = "comma-separated steps: grid, viewer, info, next, prev, rot, zoom, fit, actual, sel<N>"},
			{name = "overwrite", kind = .Bool, help = "replace the output if it exists"},
		},
		out = RENDER_FIELDS,
		examples = {"image render photo.jpg view.png --keys rot --json"},
		run = cmd_render,
	},
	{
		verb = "formats",
		summary = "what can be read, and what can be written",
		effect = .Read,
		out = FORMATS_FIELDS,
		examples = {"image formats --json"},
		run = cmd_formats,
	},
}

@(private = "file")
g_surface: kit.Surface

surface :: proc() -> ^kit.Surface {
	if g_surface.noun == "" {
		g_surface = kit.Surface {
			noun       = "image",
			summary    = "an image viewer: inspect, convert, resize, crop, rotate, thumbnail and render pictures",
			gui        = true,
			takes_path = true,
			selftest   = cli_selftest,
			notes      = SURFACE_NOTES,
			commands   = COMMANDS,
		}
	}
	return &g_surface
}

@(private = "file")
SURFACE_NOTES :: `Reads PNG, JPEG, BMP, GIF (first frame), TGA, PSD, HDR and PNM; writes PNG,
JPEG, BMP and TGA, chosen by the output's extension. JPEG and BMP have no alpha, so
transparency is laid over white. An output that exists is refused unless --overwrite.
A bare path opens the window: a file in the viewer, a folder in the grid. The older
image <media> --shot out.png [seconds] [keys] still renders offscreen.`

cli_selftest :: proc() -> int {
	run_selftest()
	return failures == 0 ? 0 : 1
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

@(private = "file")
iso :: proc(info: Image_Info) -> string {
	y, mo, d := time.date(info.mtime)
	h, mi, sec := time.clock(info.mtime)
	return fmt.tprintf("%04d-%02d-%02dT%02d:%02d:%02dZ", y, int(mo), d, h, mi, sec)
}

// load decodes the input, or records why not.
@(private = "file")
load :: proc(c: ^kit.Call) -> (img: p.Image, code: int) {
	path := kit.cli_str(c, "input")
	if !os.exists(path) {
		return {}, kit.cli_failf(c, kit.EXIT_NOT_FOUND, "%s does not exist", path)
	}
	if os.is_directory(path) {
		return {}, kit.cli_failf(c, kit.EXIT_USAGE, "%s is a folder", path)
	}
	got, ok := p.load_image(path)
	if !ok {
		return {}, kit.cli_failf(c, kit.EXIT_FAILED, "%s is not an image this can decode", path)
	}
	return got, kit.EXIT_OK
}

// out_check refuses an output it cannot write before any work is done.
@(private = "file")
out_check :: proc(c: ^kit.Call, out: string) -> int {
	if encode_format(out) == "" {
		return kit.cli_failf(c, kit.EXIT_USAGE, "cannot write .%s; the output must end in .png, .jpg, .bmp or .tga", ext_of(out))
	}
	if os.exists(out) && !kit.cli_bool(c, "overwrite") {
		code := kit.cli_failf(c, kit.EXIT_FAILED, "%s exists (pass --overwrite to replace it)", out)
		kit.cli_err_field(c, "reason", "exists")
		return code
	}
	if os.is_directory(out) {
		return kit.cli_failf(c, kit.EXIT_USAGE, "%s is a folder", out)
	}
	return kit.EXIT_OK
}

// write ends every command that produces an image.
@(private = "file")
write :: proc(c: ^kit.Call, img: p.Image) -> int {
	out := kit.cli_str(c, "output")
	bytes := 0
	if !c.dry_run {
		if ok, why := img_save(img, out, kit.cli_int(c, "quality", 90)); !ok {
			return kit.cli_fail(c, kit.EXIT_FAILED, why)
		}
		if fi, err := os.stat(out, context.temp_allocator); err == nil {
			bytes = int(fi.size)
		}
	}
	kit.jset_str(c.out, "input", kit.cli_str(c, "input"))
	kit.jset_str(c.out, "output", out)
	kit.jset_str(c.out, "format", encode_format(out))
	kit.jset_int(c.out, "width", img.w)
	kit.jset_int(c.out, "height", img.h)
	kit.jset_int(c.out, "bytes", bytes)
	return kit.EXIT_OK
}

// ---------------------------------------------------------------------------
// Reading
// ---------------------------------------------------------------------------

@(private = "file")
cmd_info :: proc(c: ^kit.Call) -> int {
	path := kit.cli_str(c, "file")
	info, ok := image_info(path)
	if !ok {
		return kit.cli_failf(c, kit.EXIT_NOT_FOUND, "%s does not exist or is a folder", path)
	}
	kit.jset_str(c.out, "path", path)
	kit.jset_str(c.out, "name", info.name)
	kit.jset_str(c.out, "format", info.format)
	kit.jset_bool(c.out, "decodable", info.decodable)
	kit.jset_int(c.out, "width", info.w)
	kit.jset_int(c.out, "height", info.h)
	kit.jset_int(c.out, "channels", info.channels)
	kit.jset_str(c.out, "channels_text", info.decodable ? channels_label(info.channels) : "")
	kit.jset_str(c.out, "aspect", aspect_label(info.w, info.h))
	kit.jset_num(c.out, "megapixels", f64(info.w) * f64(info.h) / 1e6)
	kit.jset_int(c.out, "bytes", int(info.size))
	kit.jset_str(c.out, "size_text", human_bytes(info.size))
	kit.jset_num(c.out, "bits_per_pixel", bits_per_pixel(info))
	kit.jset_str(c.out, "modified", iso(info))
	return kit.EXIT_OK
}

@(private = "file")
cmd_metadata :: proc(c: ^kit.Call) -> int {
	path := kit.cli_str(c, "file")
	info, ok := image_info(path)
	if !ok {
		return kit.cli_failf(c, kit.EXIT_NOT_FOUND, "%s does not exist or is a folder", path)
	}
	m := image_metadata(path, context.temp_allocator)
	arr := kit.jarr()
	for e in m {
		o := kit.jobj()
		kit.jset_str(o, "key", e.key)
		kit.jset_str(o, "label", e.label)
		kit.jset_str(o, "value", e.value)
		kit.jpush(arr, o)
	}
	kit.jset_str(c.out, "path", path)
	kit.jset_str(c.out, "format", info.format)
	kit.jset_int(c.out, "count", len(m))
	kit.jset(c.out, "entries", arr)
	return kit.EXIT_OK
}

@(private = "file")
cmd_list :: proc(c: ^kit.Call) -> int {
	dir := kit.cli_str(c, "dir")
	if dir == "" {
		dir = "."
	}
	dir = absolute(dir)
	if !os.is_directory(dir) {
		return kit.cli_failf(c, kit.EXIT_NOT_FOUND, "%s is not a folder", dir)
	}
	shots := scan_dir(dir, context.temp_allocator)
	arr := kit.jarr()
	for &s in shots {
		probe(&s)
		o := kit.jobj()
		kit.jset_str(o, "name", s.name)
		kit.jset_str(o, "path", s.path)
		kit.jset_str(o, "format", s.format)
		kit.jset_int(o, "width", s.w)
		kit.jset_int(o, "height", s.h)
		kit.jset_int(o, "bytes", int(s.size))
		kit.jpush(arr, o)
	}
	kit.jset_str(c.out, "dir", dir)
	kit.jset_int(c.out, "count", len(shots))
	kit.jset(c.out, "images", arr)
	return kit.EXIT_OK
}

@(private = "file")
cmd_formats :: proc(c: ^kit.Call) -> int {
	d, e := kit.jarr(), kit.jarr()
	for f in DECODE_FORMATS {
		kit.jpush(d, kit.jstr(f))
	}
	for f in ENCODE_FORMATS {
		kit.jpush(e, kit.jstr(f))
	}
	kit.jset(c.out, "decode", d)
	kit.jset(c.out, "encode", e)
	return kit.EXIT_OK
}

// ---------------------------------------------------------------------------
// Writing
// ---------------------------------------------------------------------------

@(private = "file")
cmd_convert :: proc(c: ^kit.Call) -> int {
	if code := out_check(c, kit.cli_str(c, "output")); code != kit.EXIT_OK {
		return code
	}
	img, code := load(c)
	if code != kit.EXIT_OK {
		return code
	}
	return write(c, img)
}

@(private = "file")
cmd_resize :: proc(c: ^kit.Call) -> int {
	if code := out_check(c, kit.cli_str(c, "output")); code != kit.EXIT_OK {
		return code
	}
	has_w, has_h, has_s := kit.cli_has(c, "width"), kit.cli_has(c, "height"), kit.cli_has(c, "scale")
	if !has_w && !has_h && !has_s {
		return kit.cli_fail(c, kit.EXIT_USAGE, "resize needs --width, --height or --scale")
	}
	if has_s && (has_w || has_h) {
		return kit.cli_fail(c, kit.EXIT_USAGE, "--scale or --width/--height, not both")
	}
	img, code := load(c)
	if code != kit.EXIT_OK {
		return code
	}
	w, h := img.w, img.h
	switch {
	case has_s:
		f := kit.cli_f64(c, "scale")
		w, h = int(f64(img.w) * f + 0.5), int(f64(img.h) * f + 0.5)
	case has_w && has_h:
		w, h = kit.cli_int(c, "width"), kit.cli_int(c, "height")
	case has_w:
		w = kit.cli_int(c, "width")
		h = int(f64(img.h) * f64(w) / f64(img.w) + 0.5)
	case:
		h = kit.cli_int(c, "height")
		w = int(f64(img.w) * f64(h) / f64(img.h) + 0.5)
	}
	if w < 1 || h < 1 || w > 32768 || h > 32768 {
		return kit.cli_failf(c, kit.EXIT_USAGE, "%d × %d is not a size this makes (1 to 32768 a side)", w, h)
	}
	return write(c, img_resize(img, w, h))
}

@(private = "file")
cmd_crop :: proc(c: ^kit.Call) -> int {
	if code := out_check(c, kit.cli_str(c, "output")); code != kit.EXIT_OK {
		return code
	}
	img, code := load(c)
	if code != kit.EXIT_OK {
		return code
	}
	out, ok := img_crop(img, kit.cli_int(c, "left"), kit.cli_int(c, "top"), kit.cli_int(c, "width"), kit.cli_int(c, "height"))
	if !ok {
		return kit.cli_failf(c, kit.EXIT_USAGE, "that rectangle is outside the %d × %d image", img.w, img.h)
	}
	return write(c, out)
}

@(private = "file")
cmd_rotate :: proc(c: ^kit.Call) -> int {
	if code := out_check(c, kit.cli_str(c, "output")); code != kit.EXIT_OK {
		return code
	}
	img, code := load(c)
	if code != kit.EXIT_OK {
		return code
	}
	q := 0
	switch kit.cli_str(c, "degrees") {
	case "90":
		q = 1
	case "180":
		q = 2
	case "270", "-90":
		q = 3
	}
	out, _ := rotated(img, q)
	switch kit.cli_str(c, "flip") {
	case "horizontal":
		out = img_flip(out, false)
	case "vertical":
		out = img_flip(out, true)
	}
	return write(c, out)
}

@(private = "file")
cmd_thumbnail :: proc(c: ^kit.Call) -> int {
	if code := out_check(c, kit.cli_str(c, "output")); code != kit.EXIT_OK {
		return code
	}
	size := kit.cli_int(c, "size", THUMB_MAX)
	if size < 1 || size > 8192 {
		return kit.cli_fail(c, kit.EXIT_USAGE, "--size is 1 to 8192")
	}
	img, code := load(c)
	if code != kit.EXIT_OK {
		return code
	}
	return write(c, img_thumbnail(img, size))
}

@(private = "file")
cmd_render :: proc(c: ^kit.Call) -> int {
	out := kit.cli_str(c, "output")
	if ext_of(out) != "png" {
		return kit.cli_fail(c, kit.EXIT_USAGE, "render writes a PNG; name the output .png")
	}
	if os.exists(out) && !kit.cli_bool(c, "overwrite") {
		code := kit.cli_failf(c, kit.EXIT_FAILED, "%s exists (pass --overwrite to replace it)", out)
		kit.cli_err_field(c, "reason", "exists")
		return code
	}
	media := kit.cli_str(c, "media")
	if media != "" && !os.exists(media) {
		return kit.cli_failf(c, kit.EXIT_NOT_FOUND, "%s does not exist", media)
	}
	st := st_make()
	views := [View]string {
		.Library = "library",
		.Viewer  = "viewer",
		.Grid    = "grid",
	}
	if !c.dry_run {
		sc.register_shadcn_theme()
		register_dark_theme()
		st_open(&st, media)
		defer loader_destroy(&st.ld)
		st.view_rect = shot_view_rect()
		run_shot(&st, out, kit.cli_f64(c, "seconds", 1.5), kit.cli_str(c, "keys"), true)
		if !os.exists(out) {
			return kit.cli_failf(c, kit.EXIT_FAILED, "could not write %s", out)
		}
	}
	kit.jset_str(c.out, "media", media)
	kit.jset_str(c.out, "output", out)
	kit.jset_str(c.out, "view", views[st.view])
	kit.jset_int(c.out, "width", WIN_W)
	kit.jset_int(c.out, "height", WIN_H)
	return kit.EXIT_OK
}
