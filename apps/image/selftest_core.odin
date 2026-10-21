package main

// The image core (core.odin) with no window — pixels, encoding, metadata, the
// viewer's own Ctrl-S over them — and the command line over all of it.

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import kit "kit:."
import p "palmy:."

checkf :: proc(ok: bool, format: string, args: ..any) {
	check(ok, fmt.tprintf(format, ..args))
}

@(private = "file")
RED :: 0xffff0000
@(private = "file")
BLUE :: 0xff0000ff

@(private = "file")
le16 :: proc(b: ^[dynamic]u8, v: int) {
	append(b, u8(v), u8(v >> 8))
}

@(private = "file")
le32 :: proc(b: ^[dynamic]u8, v: int) {
	append(b, u8(v), u8(v >> 8), u8(v >> 16), u8(v >> 24))
}

@(private = "file")
be32w :: proc(b: ^[dynamic]u8, v: int) {
	append(b, u8(v >> 24), u8(v >> 16), u8(v >> 8), u8(v))
}

// exif_app1 builds a little-endian EXIF block the way a camera writes one:
// IFD0 with Make, Orientation and a pointer to the Exif IFD, which holds the
// date taken, ISO and the aperture as a rational.
@(private = "file")
exif_app1 :: proc() -> []u8 {
	t := make([dynamic]u8, context.temp_allocator)
	append(&t, 'I', 'I')
	le16(&t, 42)
	le32(&t, 8)
	// IFD0 at 8: three entries.
	ifd0_size := 2 + 3 * 12 + 4
	make_at := 8 + ifd0_size // "Palmy\0" lives after IFD0
	exif_at := make_at + 6
	le16(&t, 3)
	le16(&t, 0x010f); le16(&t, 2); le32(&t, 6); le32(&t, make_at)
	le16(&t, 0x0112); le16(&t, 3); le32(&t, 1); le16(&t, 6); le16(&t, 0)
	le16(&t, 0x8769); le16(&t, 4); le32(&t, 1); le32(&t, exif_at)
	le32(&t, 0)
	append(&t, 'P', 'a', 'l', 'm', 'y', 0)
	// Exif IFD: three entries, then the date and the rational.
	exif_size := 2 + 3 * 12 + 4
	date_at := exif_at + exif_size
	rat_at := date_at + 20
	le16(&t, 3)
	le16(&t, 0x9003); le16(&t, 2); le32(&t, 20); le32(&t, date_at)
	le16(&t, 0x8827); le16(&t, 3); le32(&t, 1); le16(&t, 200); le16(&t, 0)
	le16(&t, 0x829d); le16(&t, 5); le32(&t, 1); le32(&t, rat_at)
	le32(&t, 0)
	append(&t, ..transmute([]u8)string("2026:10:21 09:30:00\x00"))
	le32(&t, 28)
	le32(&t, 10)

	seg := make([dynamic]u8, context.temp_allocator)
	append(&seg, 0xff, 0xe1)
	n := 2 + 6 + len(t)
	append(&seg, u8(n >> 8), u8(n))
	append(&seg, ..transmute([]u8)string("Exif\x00\x00"))
	append(&seg, ..t[:])
	return seg[:]
}

// png_chunk is a PNG chunk with a dummy CRC: stb_image does not check it, and
// neither does the metadata reader.
@(private = "file")
png_chunk :: proc(kind: string, data: []u8) -> []u8 {
	c := make([dynamic]u8, context.temp_allocator)
	be32w(&c, len(data))
	append(&c, ..transmute([]u8)kind)
	append(&c, ..data)
	be32w(&c, 0)
	return c[:]
}

@(private = "file")
splice :: proc(path: string, at: int, extra: []u8) {
	data, _ := os.read_entire_file_from_path(path, context.temp_allocator)
	out := make([dynamic]u8, context.temp_allocator)
	append(&out, ..data[:at])
	append(&out, ..extra)
	append(&out, ..data[at:])
	_ = os.write_entire_file(path, out[:])
}

@(private = "file")
same_px :: proc(a, b: p.Image) -> bool {
	if a.w != b.w || a.h != b.h {
		return false
	}
	for v, i in a.px[:a.w * a.h] {
		if v != b.px[i] {
			return false
		}
	}
	return true
}

test_core :: proc() {
	dir := fmt.tprintf("/tmp/image-selftest-core-%d", os.get_pid())
	_ = os.remove_all(dir)
	_ = os.make_directory_all(dir)
	defer os.remove_all(dir)

	// --- pixels ---------------------------------------------------------------
	{
		src := p.Image{px = []u32{RED, BLUE}, w = 2, h = 1, source_channels = 4}
		up := img_resize(src, 4, 1)
		check(up.w == 4 && up.px[0] == RED && up.px[3] == BLUE, "resize up: bilinear keeps the ends")
		mid := (up.px[1] >> 16) & 0xff
		checkf(mid > 0 && mid < 255, "resize up: and blends between them (%d)", mid)
		down := img_resize(up, 2, 1)
		check(down.w == 2 && down.h == 1, "resize down: box filter")

		grid := img_new(4, 3)
		for i in 0 ..< 12 {grid.px[i] = u32(i)}
		c, ok := img_crop(grid, 1, 1, 2, 2)
		check(ok && c.w == 2 && c.h == 2 && c.px[0] == 5 && c.px[3] == 10, "crop: the rectangle's pixels")
		c, ok = img_crop(grid, 3, 2, 10, 10)
		check(ok && c.w == 1 && c.h == 1 && c.px[0] == 11, "crop: clipped to the image")
		_, ok = img_crop(grid, 9, 9, 2, 2)
		check(!ok, "crop: outside is refused")
		h := img_flip(grid, false)
		check(h.px[0] == 3 && h.px[4] == 7, "flip: left-right")
		v := img_flip(grid, true)
		check(v.px[0] == 8 && v.px[11] == 3, "flip: top-bottom")
		w, hh := fit_size(4000, 3000, 240)
		check(w == 240 && hh == 180, "fit_size: the longest edge")
		t := img_thumbnail(grid, 2)
		check(t.w == 2 && t.h == 1, "thumbnail: is the grid's downscale")
	}

	// --- encoding round trips ---------------------------------------------------
	{
		img := p.Image{px = []u32{RED, BLUE, 0x80_00ff00, 0x00_000000, 0xff_ffffff, 0xff_123456}, w = 3, h = 2, source_channels = 4}
		for ext in ([?]string{"png", "tga"}) {
			path := fmt.tprintf("%s/rt.%s", dir, ext)
			ok, why := img_save(img, path)
			back, lok := p.load_image(path)
			checkf(ok && lok && same_px(img, back), "save .%s: reads back the same pixels, alpha too (%s)", ext, why)
		}
		ok, _ := img_save(img, fmt.tprintf("%s/rt.bmp", dir))
		back, _ := p.load_image(fmt.tprintf("%s/rt.bmp", dir))
		check(ok && back.px[0] == RED && back.px[3] & 0xffffff == 0xffffff, "save .bmp: opaque, transparency laid over white")
		ok, _ = img_save(img, fmt.tprintf("%s/rt.jpg", dir), 95)
		back, _ = p.load_image(fmt.tprintf("%s/rt.jpg", dir))
		check(ok && back.w == 3 && (back.px[3] & 0xff) > 200, "save .jpg: decodes, the transparent pixel is near white")
		ok2, why := img_save(img, fmt.tprintf("%s/x.webp", dir))
		checkf(!ok2 && strings.contains(why, "png"), "save: an unknown extension says what it can write (%s)", why)
		check(encode_format("A.JPEG") == "jpg", "encode_format: by extension, any case")
	}

	// --- metadata ----------------------------------------------------------------
	{
		img := img_new(8, 4)
		for &v in img.px {v = BLUE}
		png := fmt.tprintf("%s/meta.png", dir)
		img_save(img, png)
		phys := make([dynamic]u8, context.temp_allocator)
		be32w(&phys, 5669) // 144 dpi in pixels per metre
		be32w(&phys, 5669)
		append(&phys, 1)
		extra := make([dynamic]u8, context.temp_allocator)
		append(&extra, ..png_chunk("tEXt", transmute([]u8)string("Title\x00Harbour at dawn")))
		append(&extra, ..png_chunk("pHYs", phys[:]))
		splice(png, 33, extra[:]) // straight after IHDR
		m := image_metadata(png, context.temp_allocator)
		checkf(meta_value(m[:], "text:Title") == "Harbour at dawn", "metadata: PNG tEXt (%v)", len(m))
		checkf(meta_value(m[:], "dpi") == "144 dpi", "metadata: PNG pHYs as dpi (%q)", meta_value(m[:], "dpi"))
		check(meta_value(m[:], "color_type") == "RGBA", "metadata: PNG colour type")
		_, still := p.load_image(png)
		check(still, "and the file still decodes")

		jpg := fmt.tprintf("%s/meta.jpg", dir)
		img_save(img, jpg)
		splice(jpg, 2, exif_app1()) // straight after SOI
		m = image_metadata(jpg, context.temp_allocator)
		checkf(meta_value(m[:], "make") == "Palmy", "metadata: EXIF Make (%q)", meta_value(m[:], "make"))
		checkf(meta_value(m[:], "orientation") == "rotated 90° clockwise", "metadata: EXIF Orientation 6 (%q)", meta_value(m[:], "orientation"))
		checkf(meta_value(m[:], "date_taken") == "2026:10:21 09:30:00", "metadata: the Exif IFD's date taken (%q)", meta_value(m[:], "date_taken"))
		check(meta_value(m[:], "iso") == "200", "metadata: ISO")
		checkf(meta_value(m[:], "f_number") == "f/2.8", "metadata: aperture as a rational (%q)", meta_value(m[:], "f_number"))
		_, jstill := p.load_image(jpg)
		check(jstill, "and the JPEG still decodes")
		check(len(image_metadata(fmt.tprintf("%s/rt.bmp", dir), context.temp_allocator)) == 0, "metadata: a BMP has none, and that is not an error")

		// The properties panel reads the same thing.
		s := Shot{path = jpg, name = "meta.jpg"}
		probe(&s)
		info, _ := image_info(jpg)
		check(s.format == info.format && s.w == info.w && s.h == info.h && s.ch == info.channels, "probe (the panel) == image_info (the command)")
		check(meta_value(s.meta[:], "make") == "Palmy", "and the panel has the metadata too")
		_, missing := image_info(fmt.tprintf("%s/none.png", dir))
		check(!missing, "image_info: a missing file")
	}

	// --- the viewer's Ctrl-S, with no window ---------------------------------------
	{
		src := fmt.tprintf("%s/pic.png", dir)
		img := p.Image{px = []u32{RED, BLUE, BLUE, BLUE, BLUE, BLUE}, w = 3, h = 2, source_channels = 4}
		img_save(img, src)
		check(base_of(copy_path(src, 1)) == "pic (rotated 90°).png", "copy_path: named for the turn")
		check(base_of(copy_path(src, 4)) == "pic (copy).png", "copy_path: a whole turn is a copy")
		st := st_make()
		st.shots = []Shot{{path = src, name = "pic.png"}}
		st.sel = 0
		st.cur_idx = 0
		st.cur, _ = p.load_image(src)
		st.cur_ok = true
		st.rot = 1
		out, ok, why := save_copy(&st)
		back, _ := p.load_image(out)
		checkf(ok && back.w == 2 && back.h == 3 && back.px[1] == RED, "Ctrl-S: writes the picture turned as shown (%s)", why)
		check(base_of(copy_path(src, 1)) == "pic (rotated 90° 2).png", "copy_path: and never over the last one")
	}
}

// ---------------------------------------------------------------------------
// The command line
// ---------------------------------------------------------------------------

@(private = "file")
self_exe :: proc() -> string {
	if path, err := os.get_executable_path(context.temp_allocator); err == nil {
		return path
	}
	return os.args[0]
}

@(private = "file")
run :: proc(dir: string, args: ..string) -> (out: string, code: int) {
	line := strings.builder_make(context.temp_allocator)
	strings.write_string(&line, fmt.tprintf("cd %q && WAYLAND_DISPLAY= DISPLAY= PALM_AUDIT=%q/audit.jsonl", dir, dir))
	strings.write_string(&line, fmt.tprintf(" %q", self_exe()))
	for a in args {
		strings.write_string(&line, fmt.tprintf(" %q", a))
	}
	state, sout, _, err := os.process_exec({command = {"sh", "-c", strings.to_string(line)}}, context.temp_allocator)
	if err != nil {
		return "", -1
	}
	return string(sout), state.exit_code
}

@(private = "file")
valid :: proc(out: string, fields: []kit.Field) -> bool {
	return len(kit.cli_validate_output(out, fields, context.temp_allocator)) == 0
}

test_cli :: proc() {
	dir := fmt.tprintf("/tmp/image-selftest-cli-%d", os.get_pid())
	_ = os.remove_all(dir)
	_ = os.make_directory_all(dir)
	defer os.remove_all(dir)
	at :: proc(dir, name: string) -> string {return fmt.tprintf("%s/%s", dir, name)}

	src := img_new(64, 40)
	for y in 0 ..< 40 {
		for x in 0 ..< 64 {
			src.px[y * 64 + x] = 0xff000000 | u32(x * 4) << 16 | u32(y * 6) << 8 | 0x40
		}
	}
	img_save(src, at(dir, "shot-10.png"))
	img_save(src, at(dir, "shot-9.png"))
	img_save(src, at(dir, "photo.jpg"))

	sf := surface()
	check(sf.noun == "image" && sf.gui && sf.takes_path && sf.selftest != nil, "cli: the surface is image, with a window")
	for cmd in sf.commands {
		check(cmd.run != nil && cmd.summary != "" && len(cmd.out) > 0 && len(cmd.examples) > 0, fmt.tprintf("cli: %s is implemented, summarised, declares output, has an example", cmd.verb))
		for ex in cmd.examples {
			words := kit.cli_split_example(ex, context.temp_allocator)
			args := make([dynamic]string, context.temp_allocator)
			for w in words[1:] {append(&args, w)}
			append(&args, "--parse-only")
			_, code := run(dir, ..args[:])
			check(words[0] == "image" && code == 0, fmt.tprintf("cli: the example %q parses", ex))
		}
	}
	{
		out, code := run(dir, "--schema")
		_, perr := json.parse(transmute([]u8)out, .JSON, true, context.temp_allocator)
		check(code == 0 && perr == nil, "cli: --schema is JSON")
	}

	// --- reads --------------------------------------------------------------------
	{
		out, code := run(dir, "info", "photo.jpg", "--json")
		check(code == 0 && valid(out, INFO_FIELDS) && strings.contains(out, `"format": "JPEG"`) && strings.contains(out, `"width": 64`), "cli: info --json, format from the bytes")
		out, code = run(dir, "metadata", "photo.jpg", "--json")
		check(code == 0 && valid(out, METADATA_FIELDS), "cli: metadata --json")
		out, code = run(dir, "list", "--json")
		check(code == 0 && valid(out, LIST_FIELDS) && strings.contains(out, `"count": 3`), "cli: list --json")
		i9, i10 := strings.index(out, "shot-9.png"), strings.index(out, "shot-10.png")
		check(i9 >= 0 && i10 > i9, "cli: list is in the grid's order: shot-9 before shot-10")
		out, code = run(dir, "formats", "--json")
		check(code == 0 && valid(out, FORMATS_FIELDS), "cli: formats --json")
		_, code = run(dir, "info", "nope.png", "--json")
		check(code == kit.EXIT_NOT_FOUND, "cli: a missing file exits 3")
	}

	// --- writes -------------------------------------------------------------------
	{
		out, code := run(dir, "thumbnail", "shot-9.png", "t.png", "--size", "16", "--json")
		check(code == 0 && valid(out, WROTE_FIELDS), "cli: thumbnail --json")
		t, _ := p.load_image(at(dir, "t.png"))
		check(same_px(t, downscale(src, 16)), "cli: the thumbnail is, pixel for pixel, the grid's downscale")
		_, code = run(dir, "rotate", "shot-9.png", "r.png", "--degrees", "270", "--json")
		r, _ := p.load_image(at(dir, "r.png"))
		r3, _ := rotated(src, 3)
		check(code == 0 && same_px(r, r3), "cli: rotate 270 is the viewer's rotation, three quarter turns")
		_, code = run(dir, "resize", "shot-9.png", "half.png", "--width", "32", "--json")
		hlf, _ := p.load_image(at(dir, "half.png"))
		check(code == 0 && hlf.w == 32 && hlf.h == 20, "cli: resize --width keeps the aspect")
		_, code = run(dir, "crop", "shot-9.png", "c.png", "--left", "10", "--top", "5", "--width", "8", "--height", "4", "--json")
		cr, _ := p.load_image(at(dir, "c.png"))
		check(code == 0 && cr.w == 8 && cr.h == 4 && cr.px[0] == src.px[5 * 64 + 10], "cli: crop")
		_, code = run(dir, "convert", "shot-9.png", "s.bmp", "--json")
		check(code == 0 && sniff_format(at(dir, "s.bmp")) == "BMP", "cli: convert by extension")

		before, _ := os.read_entire_file_from_path(at(dir, "t.png"), context.temp_allocator)
		out, code = run(dir, "thumbnail", "shot-10.png", "t.png", "--json")
		check(code == kit.EXIT_FAILED && strings.contains(out, `"reason": "exists"`), "cli: an existing output is refused")
		after, _ := os.read_entire_file_from_path(at(dir, "t.png"), context.temp_allocator)
		check(string(before) == string(after), "cli: and left alone")
		_, code = run(dir, "thumbnail", "shot-10.png", "t.png", "--overwrite", "--json")
		check(code == 0, "cli: --overwrite replaces it")
		out, code = run(dir, "resize", "shot-9.png", "dry.png", "--scale", "2", "--dry-run", "--json")
		check(code == 0 && !os.exists(at(dir, "dry.png")) && strings.contains(out, `"width": 128`), "cli: --dry-run reports the size and writes nothing")
		_, code = run(dir, "convert", "shot-9.png", "x.webp", "--json")
		check(code == kit.EXIT_USAGE, "cli: an output it cannot write is a usage error")
		_, code = run(dir, "resize", "shot-9.png", "n.png", "--json")
		check(code == kit.EXIT_USAGE, "cli: resize with no size is a usage error")
	}

	// --- render, new and old -----------------------------------------------------------
	{
		out, code := run(dir, "render", "shot-9.png", "v.png", "--seconds", "0.4", "--json")
		w, h, _, ok := p.image_size(at(dir, "v.png"))
		check(code == 0 && valid(out, RENDER_FIELDS) && ok && w == WIN_W && h == WIN_H, "cli: render writes the viewer's frame, window-sized")
		check(strings.has_prefix(strings.trim_space(out), "{"), "cli: render's report stays off stdout under --json")
		_, code = run(dir, "shot-9.png", "--shot", "old.png", "0.4")
		check(code == 0 && os.exists(at(dir, "old.png")), "cli: the older <media> --shot out.png [seconds] still renders")
		_, code = run(dir, "rendr")
		check(code == kit.EXIT_USAGE, "cli: a mistyped verb is a usage error, not a window")
		audit, _ := os.read_entire_file_from_path(at(dir, "audit.jsonl"), context.temp_allocator)
		check(strings.contains(string(audit), `"verb":"thumbnail"`) && !strings.contains(string(audit), `"verb":"info"`), "cli: writes are audited, reads are not")
	}
}
