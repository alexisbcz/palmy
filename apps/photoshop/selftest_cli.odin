package main

// The command line, driven in-process through the kit (`kit.cli_capture`).
//
// What matters here is that a command and the window are one implementation.
// So each editing command is checked twice: against the editor's own path run
// in-process (an St, open_file, the dialog's commit), where the PNG it wrote
// must match byte for byte, and against a value worked out independently —
// an inverted pixel is 255 minus the original, a blur confined to a selection
// leaves every pixel outside it alone. The refusals are checked to refuse and
// to leave the disk as it was.

import "core:encoding/json"
import "core:fmt"
import "core:os"
import kit "kit:."
import p "palmy:."

@(private = "file")
CLI_DIR :: "/tmp/palmy-photoshop-cli-selftest"

@(private = "file")
run :: proc(argv: ..string) -> (code: int, text: string, doc: json.Object) {
	line := make([dynamic]string, 0, len(argv) + 1, context.temp_allocator)
	append(&line, ..argv)
	append(&line, "--json")
	code, text, _ = kit.cli_capture(surface(), line[:], context.temp_allocator)
	if v, err := json.parse_string(text, json.DEFAULT_SPECIFICATION, true, context.temp_allocator); err == nil {
		doc, _ = v.(json.Object)
	}
	return
}

@(private = "file")
valid :: proc(text: string, fields: []kit.Field) -> bool {
	problems := kit.cli_validate_output(text, fields, context.temp_allocator)
	for pr in problems {
		fmt.eprintfln("        %s", pr)
	}
	return len(problems) == 0
}

@(private = "file")
path_in :: proc(name: string) -> string {
	return fmt.tprintf("%s/%s", CLI_DIR, name)
}

@(private = "file")
num :: proc(o: json.Object, key: string) -> int {
	#partial switch v in o[key] {
	case json.Integer:
		return int(v)
	case json.Float:
		return int(v)
	}
	return -1
}

@(private = "file")
str :: proc(o: json.Object, key: string) -> string {
	if s, ok := o[key].(json.String); ok {
		return string(s)
	}
	return ""
}

// pixels loads a written PNG the way the editor reads one.
@(private = "file")
pixels :: proc(path: string) -> (px: []u32, w, h: int, ok: bool) {
	img, good := p.load_image(path, context.temp_allocator)
	if !good {
		return
	}
	return img.px, img.w, img.h, true
}

// in_process opens the source as the window does and returns the St, for an
// edit to be run on it through the GUI's own procedures.
@(private = "file")
in_process :: proc(st: ^St, src: string) -> bool {
	st_init(st)
	return open_file(st, src)
}

@(private = "file")
composite_of :: proc(st: ^St) -> []u32 {
	doc_dirty_all(&st.doc)
	doc_composite(&st.doc)
	return st.doc.comp
}

@(private = "file")
same :: proc(a, b: []u32) -> (equal: bool, first: int) {
	if len(a) != len(b) {
		return false, -1
	}
	for i in 0 ..< len(a) {
		if a[i] != b[i] {
			return false, i
		}
	}
	return true, 0
}

test_cli :: proc() {
	fmt.println("  the command line")
	_ = os.remove_all(CLI_DIR)
	_ = os.make_directory_all(CLI_DIR)
	defer os.remove_all(CLI_DIR)
	// Never the real audit log.
	os.set_env("PALM_AUDIT", path_in("audit.jsonl"))

	// A source with structure: a gradient, a hard-edged block, and a column
	// of a second colour, so a blur and a fill both have edges to meet.
	W, H :: 48, 32
	src := path_in("src.png")
	{
		rgba := make([]u8, W * H * 4, context.temp_allocator)
		for y in 0 ..< H {
			for x in 0 ..< W {
				i := (y * W + x) * 4
				r, g, b := u8(x * 5), u8(y * 7), u8(120)
				if x >= 30 && x < 40 && y >= 8 && y < 24 {
					r, g, b = 250, 240, 10
				}
				if x < 6 {
					r, g, b = 20, 20, 200
				}
				rgba[i], rgba[i + 1], rgba[i + 2], rgba[i + 3] = r, g, b, 255
			}
		}
		check(p.write_png_rgba(src, rgba, W, H), "the source PNG is written")
	}
	orig, _, _, _ := pixels(src)

	// new: File > New, through new_document and save_to.
	{
		code, text, o := run("new", path_in("blank.png"), "--width", "40", "--height", "30", "--fill", "#336699")
		check(code == 0, "new exits 0, got %d: %s", code, text)
		check(valid(text, WROTE_FIELDS), "new prints the declared shape")
		check(str(o, "operation") == "New", "new names the operation New, got %q", str(o, "operation"))
		px, w, h, ok := pixels(path_in("blank.png"))
		check(ok && w == 40 && h == 30, "the new canvas is 40x30, got %dx%d", w, h)
		all := ok
		for v in px {
			if v != 0xff_336699 {
				all = false
			}
		}
		check(all, "every pixel of the new canvas is the fill colour")
		code, _, _ = run("new", path_in("clear.png"), "--width", "8", "--height", "8", "--fill", "transparent")
		cpx, _, _, cok := pixels(path_in("clear.png"))
		check(code == 0 && cok && cpx[0] >> 24 == 0, "--fill transparent makes a transparent canvas")
	}

	// adjust: the dialog's commit, byte-identical to the window's path, and
	// equal to the adjustment worked out on the raw pixels.
	{
		code, text, o := run("adjust", src, path_in("bc.png"), "--kind", "brightness-contrast", "--brightness", "30", "--contrast", "20")
		check(code == 0, "adjust exits 0, got %d: %s", code, text)
		check(valid(text, WROTE_FIELDS), "adjust prints the declared shape")
		check(str(o, "operation") == "Brightness / Contrast", "adjust is recorded as the dialog's undo label, got %q", str(o, "operation"))
		got, _, _, _ := pixels(path_in("bc.png"))

		st: St
		check(in_process(&st, src), "the source opens in-process")
		v := adjust_defaults(.Brightness_Contrast)
		v[0], v[1] = 30, 20
		commit_adjust(&st, .Brightness_Contrast, v)
		eq, at := same(got, composite_of(&st))
		check(eq, "adjust on the command line == Apply in the dialog (first difference at %d)", at)
		check(hist_undo_label(&st.hist) == "Brightness / Contrast", "the in-process commit made one undo entry")

		ref := make([]u32, W * H, context.temp_allocator)
		apply_adjust(.Brightness_Contrast, v, ref, orig, W, {0, 0, W, H})
		eq, at = same(got, ref)
		check(eq, "adjust == apply_adjust on the raw pixels (first difference at %d)", at)
		check(num(o, "changed") > 0 && num(o, "changed") <= W * H, "adjust reports how many pixels changed: %d", num(o, "changed"))
		doc_free(&st.doc)
		hist_free(&st.hist)
	}

	// invert, against arithmetic: 255 minus each channel, alpha untouched.
	{
		code, _, _ := run("adjust", src, path_in("inv.png"), "--kind", "invert")
		got, _, _, _ := pixels(path_in("inv.png"))
		ok := code == 0 && len(got) == len(orig)
		if ok {
			for v, i in orig {
				if got[i] != (v & 0xff00_0000) | (~v & 0x00ff_ffff) {
					ok = false
				}
			}
		}
		check(ok, "invert gives 255 minus every channel and keeps alpha")
	}

	// filter, confined to a region: nothing outside it moves, something
	// inside does, and the window's path agrees.
	{
		code, text, o := run("filter", src, path_in("blur.png"), "--kind", "blur", "--radius", "3", "--region", "24,4,20,24")
		check(code == 0, "filter exits 0, got %d: %s", code, text)
		check(valid(text, WROTE_FIELDS), "filter prints the declared shape")
		check(str(o, "region") == "24,4,20,24", "the region is reported as the selection, got %q", str(o, "region"))
		got, _, _, _ := pixels(path_in("blur.png"))
		outside_same, inside_changed := true, false
		for y in 0 ..< H {
			for x in 0 ..< W {
				i := y * W + x
				inside := x >= 24 && x < 44 && y >= 4 && y < 28
				if !inside && got[i] != orig[i] {
					outside_same = false
				}
				if inside && got[i] != orig[i] {
					inside_changed = true
				}
			}
		}
		check(outside_same, "a filter confined to --region leaves every pixel outside it alone")
		check(inside_changed, "and changes pixels inside it")

		st: St
		in_process(&st, src)
		select_rect(&st, 24, 4, 20, 24)
		commit_filter(&st, .Gaussian_Blur, {0 = 3})
		eq, at := same(got, composite_of(&st))
		check(eq, "filter on the command line == the Filter dialog with that marquee (first difference at %d)", at)
		doc_free(&st.doc)
		hist_free(&st.hist)
	}

	// fill: the bucket stops at the edge of the yellow block.
	{
		code, text, _ := run("fill", src, path_in("fill.png"), "--left", "35", "--top", "15", "--color", "#00ff00", "--tolerance", "8")
		check(code == 0, "fill exits 0, got %d: %s", code, text)
		got, _, _, _ := pixels(path_in("fill.png"))
		in_block, outside := true, true
		for y in 0 ..< H {
			for x in 0 ..< W {
				i := y * W + x
				block := x >= 30 && x < 40 && y >= 8 && y < 24
				if block && got[i] != 0xff_00ff00 {
					in_block = false
				}
				if !block && got[i] != orig[i] {
					outside = false
				}
			}
		}
		check(in_block, "fill covers the whole contiguous block")
		check(outside, "and nothing beyond its edge")
	}

	// pick and info, the reads.
	{
		code, text, o := run("pick", src, "--left", "35", "--top", "10")
		check(code == 0 && valid(text, PICK_FIELDS), "pick exits 0 with the declared shape: %s", text)
		check(str(o, "color") == "#FAF00A", "pick reads the block's colour, got %q", str(o, "color"))
		code, text, o = run("info", path_in("blank.png"))
		check(code == 0 && valid(text, INFO_FIELDS), "info exits 0 with the declared shape")
		check(num(o, "width") == 40 && num(o, "opaque") == 1200, "info counts 40 wide and 1200 opaque pixels")
		check(str(o, "mean") == "#336699", "info's mean of a flat canvas is its colour, got %q", str(o, "mean"))
		sum := 0
		if arr, ok := o["histogram"].(json.Array); ok {
			check(len(arr) == 256, "the histogram has 256 bins")
			for b in arr {
				if n, isint := b.(json.Integer); isint {
					sum += int(n)
				}
			}
		}
		check(sum == 1200, "the histogram counts every opaque pixel once: %d", sum)
		code, text, o = run("adjustments")
		check(code == 0 && valid(text, OPS_FIELDS) && num(o, "count") == 9, "adjustments lists all nine operations")
	}

	// Refusals, and that they leave the disk alone.
	{
		before, _ := os.read_entire_file_from_path(path_in("bc.png"), context.temp_allocator)
		code, _, o := run("adjust", src, path_in("bc.png"), "--kind", "invert")
		after, _ := os.read_entire_file_from_path(path_in("bc.png"), context.temp_allocator)
		check(code == kit.EXIT_FAILED && str(o, "reason") == "exists", "an existing output is refused (exit %d)", code)
		check(string(before) == string(after), "and is left as it was")
		code, _, _ = run("adjust", src, path_in("bc.png"), "--kind", "invert", "--overwrite")
		check(code == 0, "--overwrite replaces it")

		code, _, o = run("adjust", src, path_in("x.png"), "--kind", "brightness-contrast", "--brightness", "500")
		check(code == kit.EXIT_USAGE && str(o, "flag") == "brightness", "a value outside the dialog's range is a usage error (exit %d)", code)
		code, _, o = run("adjust", src, path_in("x.png"), "--kind", "brightness-contrast", "--gamma", "2")
		check(code == kit.EXIT_USAGE && str(o, "flag") == "gamma", "a parameter of another kind is refused, not ignored (exit %d)", code)
		code, _, o = run("filter", src, path_in("x.jpg"), "--kind", "blur")
		check(code == kit.EXIT_USAGE && str(o, "reason") == "not_png", "a non-PNG output is a usage error: the only encoder is PNG")
		code, _, _ = run("filter", path_in("nope.png"), path_in("x.png"), "--kind", "blur")
		check(code == kit.EXIT_NOT_FOUND, "a missing input is not found (exit %d)", code)
		code, _, _ = run("filter", src, path_in("x.png"), "--kind", "blur", "--region", "900,900,10,10")
		check(code == kit.EXIT_USAGE, "a region outside the image is a usage error (exit %d)", code)
		check(!os.exists(path_in("x.png")), "no refused command wrote anything")

		code, _, o = run("filter", src, path_in("dry.png"), "--kind", "emboss", "--dry-run")
		check(code == 0 && !os.exists(path_in("dry.png")) && num(o, "bytes") == 0, "--dry-run reports and writes nothing")

		code, _, _ = kit.cli_capture(surface(), {"frobnicate", "--json"}, context.temp_allocator)
		check(code == kit.EXIT_USAGE, "a mistyped verb is a usage error, not a window (exit %d)", code)
		_, handled := kit.cli_args(surface(), {src})
		check(!handled, "a path on disk is left for the window to open")
	}
}
