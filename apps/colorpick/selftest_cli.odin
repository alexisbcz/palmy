package main

// The third part of `colorpick --selftest`: the shared core, and the command
// line over it, run in process with no window.
//
// It runs in a scratch HOME with a scratch $PALM_AUDIT, so the palette it
// saves, removes and clears is never the person's, and nothing it does reaches
// the real audit log. The point it holds is that the window and `palm color`
// are one implementation: a colour saved from the command line is the first
// swatch a window loads, and what the CLI reads is what Ctrl+V pastes.

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import kit "kit:."
import p "palmy:."

@(private = "file")
fails: int
@(private = "file")
checks: int

@(private = "file")
ok :: proc(cond: bool, format: string, args: ..any) {
	checks += 1
	if !cond {
		fails += 1
		fmt.printf("FAIL  ")
		fmt.printfln(format, ..args)
	}
}

@(private = "file")
SCRATCH :: "/tmp/palmy-colorpick-cli-selftest"

// run is one command line through the real kit, its JSON parsed.
@(private = "file")
run :: proc(argv: ..string) -> (code: int, doc: json.Object, text: string) {
	c, v, t := kit.cli_capture_json(surface(), argv, context.temp_allocator)
	obj, _ := v.(json.Object)
	return c, obj, t
}

@(private = "file")
str :: proc(o: json.Object, k: string) -> string {
	s, _ := o[k].(json.String)
	return string(s)
}

@(private = "file")
num :: proc(o: json.Object, k: string) -> f64 {
	#partial switch v in o[k] {
	case json.Integer:
		return f64(v)
	case json.Float:
		return f64(v)
	}
	return -1
}

@(private = "file")
valid :: proc(text: string, fields: []kit.Field, what: string) {
	problems := kit.cli_validate_output(text, fields, context.temp_allocator)
	ok(len(problems) == 0, "%s does not match its declared output: %v", what, problems)
}

cli_core_selftest :: proc() -> int {
	fails = 0
	checks = 0
	g_test = true

	_ = os.remove_all(SCRATCH)
	_ = os.make_directory_all(SCRATCH)
	old_home := strings.clone(os.get_env("HOME", context.temp_allocator))
	old_audit := strings.clone(os.get_env("PALM_AUDIT", context.temp_allocator))
	old_way := strings.clone(os.get_env("WAYLAND_DISPLAY", context.temp_allocator))
	_ = os.set_env("HOME", SCRATCH)
	_ = os.set_env("PALM_AUDIT", SCRATCH + "/audit.jsonl")
	defer {
		_ = os.set_env("HOME", old_home)
		if old_audit == "" {_ = os.unset_env("PALM_AUDIT")} else {_ = os.set_env("PALM_AUDIT", old_audit)}
		if old_way != "" {_ = os.set_env("WAYLAND_DISPLAY", old_way)}
		_ = os.remove_all(SCRATCH)
	}

	// -------------------------------------------------------------------
	fmt.println("\n-- parse_color: every notation the editor writes")
	{
		Case :: struct {
			in_:      string,
			notation: string,
			hex:      string,
		}
		for c in ([?]Case {
			{"#3b82f6", "hex", "#3b82f6"},
			{"3B82F6", "hex", "#3b82f6"},
			{"#38f", "hex", "#3388ff"},
			{"rgb(59, 130, 246)", "rgb", "#3b82f6"},
			{"rgb(59 130 246 / 50%)", "rgb", "#3b82f6"},
			{"rgba(59,130,246,0.5)", "rgb", "#3b82f6"},
			{"RGB(100%, 0%, 0%)", "rgb", "#ff0000"},
			{"hsl(217.2, 91.2%, 59.8%)", "hsl", "#3b82f6"},
			{"hsl(0deg 100% 50%)", "hsl", "#ff0000"},
			{"hsl(-120, 100%, 50%)", "hsl", "#0000ff"},
			{"oklch(0.62796 0.25768 29.234)", "oklch", "#ff0000"},
			{"oklch(62.796% 0.25768 29.234)", "oklch", "#ff0000"},
		}) {
			pc, good := parse_color(c.in_)
			ok(good, "parse_color(%q) should read", c.in_)
			ok(pc.notation == c.notation, "parse_color(%q) read it as %q, expected %q", c.in_, pc.notation, c.notation)
			ok(fmt_hex(pc.rgb) == c.hex, "parse_color(%q) = %s, expected %s", c.in_, fmt_hex(pc.rgb), c.hex)
		}
		for bad in ([?]string{"", "nonsense", "rgb(1, 2)", "rgb(a, b, c)", "hsl(1 2 3", "lab(50 20 30)", "#12345"}) {
			_, good := parse_color(bad)
			ok(!good, "parse_color(%q) must refuse", bad)
		}
		wide, _ := parse_color("oklch(0.7 0.4 150)")
		ok(!wide.in_gamut, "oklch(0.7 0.4 150) is outside sRGB and must say so")
		ok(abs(wide.lch[1] - 0.4) < 1e-6, "the chroma as written is kept (%g), not the clipped one", wide.lch[1])

		// Whatever Ctrl+1..4 copies, Ctrl+V (and every command) reads back
		// as the same 8-bit colour.
		worst := 0
		for r := 0; r < 256; r += 17 {
			for g := 0; g < 256; g += 51 {
				for b := 0; b < 256; b += 85 {
					src := [3]u8{u8(r), u8(g), u8(b)}
					for m in Model {
						text := ""
						switch m {
						case .Hex:
							text = fmt_hex(from_bytes(src))
						case .Rgb:
							text = fmt_rgb(from_bytes(src))
						case .Hsl:
							text = fmt_hsl(from_bytes(src))
						case .Oklch:
							text = fmt_oklch(from_bytes(src))
						}
						pc, good := parse_color(text)
						if !good {
							worst = 999
							continue
						}
						got := to_bytes(pc.rgb)
						for i in 0 ..< 3 {
							worst = max(worst, abs(int(got[i]) - int(src[i])))
						}
					}
				}
			}
		}
		ok(worst <= 1, "every copied notation should paste back within one 8-bit step, worst was %d", worst)
	}

	// -------------------------------------------------------------------
	fmt.println("-- the window's paste goes through the same parser")
	{
		st := St{palette = make([dynamic][3]u8, context.temp_allocator)}
		for i in 0 ..< FIELD_N {
			st.bufs[i] = make([dynamic]u8, context.temp_allocator)
		}
		resync(&st, .Hex)
		// The editor's own rgb() copy used to be refused on paste: the old
		// Ctrl+V read hex and nothing else.
		ok(take_colour_text(&st, "rgb(255, 0, 0)"), "pasting rgb(255, 0, 0) should be taken")
		ok(buf_str(&st, 0) == "#ff0000", "after pasting rgb() the hex field should read #ff0000, shows %q", buf_str(&st, 0))
		ok(take_colour_text(&st, "hsl(120, 100%, 25%)"), "pasting an hsl() should be taken")
		ok(buf_str(&st, 0) == "#008000", "after pasting hsl() the hex field should read #008000, shows %q", buf_str(&st, 0))
		ok(take_colour_text(&st, "oklch(0.7 0.4 150)"), "pasting an oklch() should be taken")
		ok(st.src == .Oklch && !st.in_gamut, "an out-of-gamut oklch() pastes into the OKLCH fields and is flagged")
		ok(buf_str(&st, 8) == "0.4000", "the pasted chroma is kept as written, the C field shows %q", buf_str(&st, 8))
		ok(!take_colour_text(&st, "not a colour"), "nonsense must not be pasted")
	}

	// -------------------------------------------------------------------
	fmt.println("-- convert and contrast")
	{
		code, doc, text := run("convert", "#3b82f6")
		ok(code == 0, "convert should succeed, exit %d: %s", code, text)
		valid(text, COLOR_FIELDS, "convert")
		ok(str(doc, "rgb") == "rgb(59, 130, 246)", "convert rgb is %q", str(doc, "rgb"))
		ok(str(doc, "hsl") == "hsl(217.2, 91.2%, 59.8%)", "convert hsl is %q", str(doc, "hsl"))
		ok(strings.has_prefix(str(doc, "oklch"), "oklch(0.62"), "convert oklch is %q", str(doc, "oklch"))
		ok(str(doc, "ink") == "black", "black reads better on blue-500 by WCAG, convert says %q", str(doc, "ink"))

		code, doc, text = run("convert", "oklch(0.7 0.4 150)")
		ok(code == 0, "convert of an out-of-gamut oklch should still succeed, exit %d", code)
		ok(strings.contains(text, "\"in_gamut\": false"), "and say in_gamut false: %s", text)
		ok(str(doc, "oklch") == "oklch(0.7000 0.4000 150.00)", "the oklch is as written, got %q", str(doc, "oklch"))

		code, doc, text = run("convert", "bogus")
		ok(code == kit.EXIT_USAGE, "a non-colour is a usage error, exit %d", code)
		ok(str(doc, "given") == "bogus", "the refusal names what was given: %s", text)

		code, doc, text = run("contrast", "#767676", "white")
		ok(code == 0, "contrast should succeed, exit %d: %s", code, text)
		valid(text, CONTRAST_FIELDS, "contrast")
		ok(abs(num(doc, "ratio") - 4.54) < 0.006, "#767676 on white is the 4.54:1 boundary, got %v", num(doc, "ratio"))
		ok(str(doc, "normal") == "AA" && str(doc, "large") == "AAA", "4.54:1 is AA body, AAA large: %s / %s", str(doc, "normal"), str(doc, "large"))
		_, doc, _ = run("contrast", "#777777", "#ffffff")
		ok(str(doc, "normal") == "fail", "#777 on white just fails AA body text, got %q", str(doc, "normal"))
	}

	// -------------------------------------------------------------------
	fmt.println("-- the palette, one store for the window and the command line")
	{
		code, doc, text := run("palette")
		ok(code == 0 && num(doc, "count") == 0, "a fresh HOME has an empty palette: %s", text)
		valid(text, PALETTE_FIELDS, "palette")
		ok(strings.has_prefix(str(doc, "path"), SCRATCH), "the palette lives under the scratch HOME, not the real one: %q", str(doc, "path"))

		code, doc, text = run("save", "#e11d48")
		ok(code == 0 && num(doc, "index") == 0, "save puts a colour first: %s", text)
		valid(text, SAVED_FIELDS, "save")
		ok(strings.contains(text, "\"already\": false"), "the first save was new: %s", text)
		_, _, _ = run("save", "rgb(34, 197, 94)")
		_, doc, text = run("save", "#E11D48")
		ok(strings.contains(text, "\"already\": true") && num(doc, "index") == 1, "saving it again leaves it where it is (index 1): %s", text)

		_, _, text = run("save", "#000000", "--dry-run")
		ok(strings.contains(text, "\"dry_run\": true"), "a dry run says so: %s", text)

		data, _ := os.read_entire_file_from_path(SCRATCH + "/.local/share/palmy-colorpick/palette", context.temp_allocator)
		ok(string(data) == "#22c55e\n#e11d48\n", "the file holds the two saved colours, newest first, and not the dry run: %q", string(data))

		// The window loads what the command line saved, first swatch first.
		st := St{palette = make([dynamic][3]u8, context.temp_allocator)}
		load_palette(&st)
		ok(len(st.palette) == 2 && st.palette[0] == {0x22, 0xc5, 0x5e}, "the window should load the CLI's palette, newest first: %v", st.palette[:])

		// And a colour the window saves is what the command line lists.
		st.rgb = from_bytes({0x34, 0x65, 0xf1})
		for i in 0 ..< FIELD_N {
			st.bufs[i] = make([dynamic]u8, context.temp_allocator)
		}
		resync(&st, .Hex)
		save_to_palette(&st, nil)
		_, doc, text = run("palette")
		ok(num(doc, "count") == 3, "the CLI should see the window's save, count %v", num(doc, "count"))
		ok(strings.index(text, "#3465f1") < strings.index(text, "#22c55e"), "and list it first: %s", text)

		code, doc, text = run("remove", "#22c55e")
		ok(code == 0 && num(doc, "count") == 2, "remove takes one out: %s", text)
		valid(text, REMOVED_FIELDS, "remove")
		code, _, _ = run("remove", "#22c55e")
		ok(code == kit.EXIT_NOT_FOUND, "removing it again is not found, exit %d", code)

		code, _, _ = run("clear")
		ok(code == kit.EXIT_NEEDS_YES, "clear refuses without --yes, exit %d", code)
		_, doc, _ = run("palette")
		ok(num(doc, "count") == 2, "a refused clear leaves the palette alone, count %v", num(doc, "count"))
		code, doc, text = run("clear", "--yes")
		ok(code == 0 && num(doc, "removed") == 2, "clear --yes empties it: %s", text)
		valid(text, CLEARED_FIELDS, "clear")
		_, doc, _ = run("palette")
		ok(num(doc, "count") == 0, "and it is empty, count %v", num(doc, "count"))

		audit, aerr := os.read_entire_file_from_path(SCRATCH + "/audit.jsonl", context.temp_allocator)
		ok(aerr == nil && strings.contains(string(audit), "\"verb\": \"clear\""), "the audit went to the scratch $PALM_AUDIT")
	}

	// -------------------------------------------------------------------
	fmt.println("-- sample: a pixel of an image, through the loupe's sampler")
	{
		w, h := 8, 4
		rgba := make([]u8, w * h * 4, context.temp_allocator)
		for y in 0 ..< h {
			for x in 0 ..< w {
				i := (y * w + x) * 4
				rgba[i + 0] = u8(x * 30)
				rgba[i + 1] = u8(y * 60)
				rgba[i + 2] = 0x80
				rgba[i + 3] = 0xff
			}
		}
		png := SCRATCH + "/grid.png"
		ok(p.write_png_rgba(png, rgba, w, h), "the fixture PNG should be written")
		code, doc, text := run("sample", png, "--left", "5", "--top", "2")
		ok(code == 0, "sample should succeed, exit %d: %s", code, text)
		valid(text, SAMPLE_FIELDS, "sample")
		ok(str(doc, "hex") == "#967880", "pixel (5, 2) is #967880, sample says %q", str(doc, "hex"))
		ok(num(doc, "width") == 8 && num(doc, "height") == 4, "the image is 8 x 4")
		code, _, _ = run("sample", png, "--left", "8", "--top", "0")
		ok(code == kit.EXIT_USAGE, "a pixel outside the image is a usage error, exit %d", code)
		code, _, _ = run("sample", SCRATCH + "/missing.png")
		ok(code == kit.EXIT_NOT_FOUND, "a missing image is not found, exit %d", code)
	}

	// -------------------------------------------------------------------
	fmt.println("-- pick: unavailable, honestly, with no compositor")
	{
		_ = os.unset_env("WAYLAND_DISPLAY")
		code, doc, text := run("pick")
		ok(code == kit.EXIT_UNAVAILABLE, "pick with no Wayland session is unavailable (6), exit %d", code)
		ok(str(doc, "error") != "", "and says so in the documented error object: %s", text)
	}

	fmt.printfln("\n%s  %d CLI and core checks, %d failure(s)", fails == 0 ? "PASS" : "FAILED", checks, fails)
	return fails
}
