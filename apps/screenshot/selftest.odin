package main

// `screenshot --selftest` — headless, no compositor, no grim, no slurp.
//
// Everything here is the geometry and the filenames: hyprctl's monitor
// document, slurp's rectangle, the arithmetic that confines a rectangle to the
// desktop, the dated filename, and — the one that is a safety property rather
// than a convenience — that saving never names a file that already exists.
//
// No capture is taken. The interface is driven for real, but Return and Space
// are never pressed, because those run grim.

import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"
import "core:time"
import p "palmy:."
import sc "shadcn:."

@(private = "file")
checks := 0
@(private = "file")
failures := 0

@(private = "file")
check :: proc(ok: bool, what: string, args: ..any) {
	checks += 1
	if !ok {
		failures += 1
		fmt.printf("  FAIL  %s\n", fmt.tprintf(what, ..args))
	}
}

@(private = "file")
eq_s :: proc(got, want: string, what: string) {
	checks += 1
	if got != want {
		failures += 1
		fmt.printf("  FAIL  %s: got %q, want %q\n", what, got, want)
	}
}

@(private = "file")
eq_i :: proc(got, want: int, what: string) {
	checks += 1
	if got != want {
		failures += 1
		fmt.printf("  FAIL  %s: got %d, want %d\n", what, got, want)
	}
}

@(private = "file")
eq_r :: proc(got, want: Rect, what: string) {
	checks += 1
	if got != want {
		failures += 1
		fmt.printf("  FAIL  %s: got %s, want %s\n", what, geom_arg(got), geom_arg(want))
	}
}

@(private = "file")
near :: proc(a, b: f32, what: string, tol: f32 = 1e-4) {
	checks += 1
	if math.abs(a - b) > tol {
		failures += 1
		fmt.printf("  FAIL  %s: got %.4f, want %.4f\n", what, a, b)
	}
}

@(private = "file")
section :: proc(name: string) {
	fmt.printf("\n%s\n", name)
}

selftest :: proc() {
	t0 := time.now()
	fmt.println("screenshot self-test")

	test_outputs()
	test_outputs_malformed()
	test_geom()
	test_geom_math()
	test_filenames()
	test_no_overwrite()
	test_save_copy()
	test_sizes()
	test_interface()

	ms := time.duration_milliseconds(time.since(t0))
	fmt.printf("\n%d assertions, %d failures, %.0f ms\n", checks, failures, ms)
	if failures > 0 {
		os.exit(1)
	}
}

// ---------------------------------------------------------------------------
// hyprctl monitors -j
// ---------------------------------------------------------------------------

// Verbatim from this machine, trimmed of the mode list. The nested
// activeWorkspace is the whole reason this fixture is long: it has a "name" of
// its own, three keys before `scale` and `focused`.
@(private = "file")
MONITORS :: `[{
    "id": 1,
    "name": "HDMI-A-2",
    "description": "Philips Consumer Electronics Company PHL 243V7 UK02109006822",
    "make": "Philips Consumer Electronics Company",
    "model": "PHL 243V7",
    "serial": "UK02109006822",
    "width": 1920,
    "height": 1080,
    "physicalWidth": 530,
    "physicalHeight": 300,
    "refreshRate": 60.00000,
    "x": 0,
    "y": 0,
    "activeWorkspace": {
        "id": 8,
        "name": "8"
    },
    "specialWorkspace": {
        "id": 0,
        "name": ""
    },
    "reserved": [0, 26, 0, 0],
    "scale": 1,
    "transform": 0,
    "focused": true,
    "dpmsStatus": true,
    "vrr": false,
    "availableModes": ["1920x1080@60.00Hz","1280x720@50.00Hz"],
    "mirrorOf": "none",
    "disabled": false
},{
    "id": 2,
    "name": "DP-1",
    "description": "Dell Inc. DELL U2720Q",
    "width": 3840,
    "height": 2160,
    "x": 1920,
    "y": -200,
    "activeWorkspace": { "id": 2, "name": "2" },
    "scale": 2.000000,
    "focused": false,
    "availableModes": []
}]`

test_outputs :: proc() {
	section("hyprctl monitors -j")

	outs := parse_outputs(MONITORS, context.allocator)
	defer {
		for o in outs {
			delete(o.name)
			delete(o.desc)
		}
		delete(outs)
	}

	eq_i(len(outs), 2, "two monitors")
	if len(outs) != 2 {
		return
	}

	eq_s(outs[0].name, "HDMI-A-2", "the first monitor's name")
	eq_s(
		outs[0].desc,
		"Philips Consumer Electronics Company PHL 243V7 UK02109006822",
		"its description",
	)
	eq_i(outs[0].w, 1920, "its width")
	eq_i(outs[0].h, 1080, "its height")
	eq_i(outs[0].x, 0, "its x")
	eq_i(outs[0].y, 0, "its y")
	// These two are the fields that a reader which stops at the nested
	// activeWorkspace never sees at all.
	near(outs[0].scale, 1, "its scale, read past the nested workspace object")
	check(outs[0].focused, "and its focus flag, likewise")

	eq_s(outs[1].name, "DP-1", "the second monitor's name")
	eq_i(outs[1].w, 3840, "its width")
	eq_i(outs[1].x, 1920, "it is placed to the right")
	eq_i(outs[1].y, -200, "and a little higher — a negative coordinate is normal")
	near(outs[1].scale, 2, "a fractional scale reads as a number, not as zero")
	check(!outs[1].focused, "it is not focused")

	// The nested workspaces must not have become monitors of their own.
	for o in outs {
		check(o.name != "8" && o.name != "2", "a workspace name is not a monitor, got %q", o.name)
	}
}

test_outputs_malformed :: proc() {
	section("hyprctl output that is not what it should be")

	empty := parse_outputs("[]", context.allocator)
	eq_i(len(empty), 0, "an empty array yields no outputs")
	delete(empty)

	none := parse_outputs("", context.allocator)
	eq_i(len(none), 0, "an empty document yields no outputs")
	delete(none)

	prose := parse_outputs("Hyprland is not running", context.allocator)
	eq_i(len(prose), 0, "an error message yields no outputs")
	delete(prose)

	// Truncated mid-object: whatever is incomplete has no usable size, so it
	// is dropped rather than reported as a 0x0 monitor.
	cut := parse_outputs(`[{"name": "HDMI-A-2", "width": 1920, "hei`, context.allocator)
	eq_i(len(cut), 0, "a monitor truncated before its height is dropped")
	delete(cut)

	// Truncated after a complete monitor: the complete one survives.
	half := parse_outputs(
		`[{"name": "A", "width": 800, "height": 600, "x": 0, "y": 0, "scale": 1},{"name": "B"`,
		context.allocator,
	)
	eq_i(len(half), 1, "the complete monitor before the truncation survives")
	if len(half) == 1 {
		eq_s(half[0].name, "A", "and it is the right one")
		near(half[0].scale, 1, "with its scale")
		delete(half[0].name)
		delete(half[0].desc)
	}
	delete(half)

	// A monitor with no scale at all: 1, not 0. A zero scale divides.
	noscale := parse_outputs(`[{"name":"A","width":800,"height":600}]`, context.allocator)
	if eq_i(len(noscale), 1, "the monitor parsed"); len(noscale) == 1 {
		near(noscale[0].scale, 1, "a missing scale defaults to 1 rather than 0")
		delete(noscale[0].name)
		delete(noscale[0].desc)
	}
	delete(noscale)

	// A disabled monitor reports 0x0 and cannot be captured.
	off := parse_outputs(`[{"name":"HDMI-A-1","width":0,"height":0,"disabled":true}]`, context.allocator)
	eq_i(len(off), 0, "a monitor with no size is not offered as a capture target")
	delete(off)

	// A name containing an escaped quote must not end the string early.
	odd := parse_outputs(
		`[{"name":"A\"B","description":"x","width":100,"height":100}]`,
		context.allocator,
	)
	if len(odd) == 1 {
		eq_i(odd[0].w, 100, "a field after an escaped quote is still found")
		delete(odd[0].name)
		delete(odd[0].desc)
	}
	delete(odd)
}

// ---------------------------------------------------------------------------
// slurp's rectangle
// ---------------------------------------------------------------------------

test_geom :: proc() {
	section("slurp geometry")

	r, ok := parse_geom("1234,56 800x600")
	check(ok, "slurp's own spelling parses")
	eq_r(r, Rect{1234, 56, 800, 600}, "the rectangle")

	r2, ok2 := parse_geom("0,0 1920x1080\n")
	check(ok2, "a trailing newline is tolerated")
	eq_r(r2, Rect{0, 0, 1920, 1080}, "a whole output")

	// A rectangle on a monitor placed left of the origin.
	r3, ok3 := parse_geom("-1920,-200 640x480")
	check(ok3, "negative origins parse")
	eq_r(r3, Rect{-1920, -200, 640, 480}, "the rectangle")

	// Extra whitespace, which a shell wrapper adds.
	r4, ok4 := parse_geom("  10,20 30x40  ")
	check(ok4, "surrounding whitespace is trimmed")
	eq_r(r4, Rect{10, 20, 30, 40}, "the rectangle")

	// slurp prints one line; anything after it is noise.
	r5, ok5 := parse_geom("10,20 30x40\nselection cancelled")
	check(ok5, "only the first line is read")
	eq_r(r5, Rect{10, 20, 30, 40}, "the rectangle")

	bad := [?]struct {
		text: string,
		what: string,
	} {
		{"", "an empty answer"},
		{"\n", "a bare newline"},
		{"selection cancelled", "a message instead of a rectangle"},
		{"1234,56", "an origin with no size"},
		{"1234 56 800x600", "an origin with no comma"},
		{"1234,56 800", "a size with no x"},
		{"1234,56 800x", "a size truncated after the x"},
		{",56 800x600", "a missing x coordinate"},
		{"1234,56 0x600", "a zero width"},
		{"1234,56 800x0", "a zero height"},
		{"1234,56 -8x600", "a negative width"},
		{"a,b cxd", "letters where the numbers go"},
		{"1234,56 800x60", "a plausible but short read is still read"},
	}
	for c in bad {
		_, got := parse_geom(c.text)
		if c.text == "1234,56 800x60" {
			// The last one is the exception: it is a *valid* rectangle that
			// merely looks like a truncated one. There is no way to tell, and
			// refusing it would refuse real selections.
			check(got, "%s parses — it is indistinguishable from a real one", c.what)
			continue
		}
		check(!got, "%s is refused", c.what)
	}

	// geom_arg and parse_geom are each other's inverse.
	for want in ([?]Rect{{0, 0, 1, 1}, {1920, 0, 1920, 1080}, {-5, -7, 13, 17}}) {
		back, good := parse_geom(geom_arg(want))
		check(good, "%s round-trips", geom_arg(want))
		eq_r(back, want, "and comes back the same")
	}
	eq_s(geom_arg(Rect{1234, 56, 800, 600}), "1234,56 800x600", "grim's -g spelling")
}

test_geom_math :: proc() {
	section("confining a rectangle to the desktop")

	outs := []Output {
		{name = "HDMI-A-2", w = 1920, h = 1080, x = 0, y = 0, scale = 1},
		{name = "DP-1", w = 3840, h = 2160, x = 1920, y = -200, scale = 2},
	}

	b, ok := outputs_bounds(outs)
	check(ok, "a desktop with monitors has bounds")
	// x from 0 to 5760, y from -200 to 1960.
	eq_r(b, Rect{0, -200, 5760, 2160}, "the union of both monitors")

	one, _ := outputs_bounds(outs[:1])
	eq_r(one, Rect{0, 0, 1920, 1080}, "a single monitor is its own bounds")

	_, none := outputs_bounds(nil)
	check(!none, "no monitors means no bounds, rather than a 0x0 rectangle")

	// Wholly inside: unchanged.
	r, inside := rect_clamp(Rect{100, 100, 200, 200}, b)
	check(inside, "a rectangle inside the desktop overlaps it")
	eq_r(r, Rect{100, 100, 200, 200}, "and is unchanged")

	// Hanging off the right and bottom.
	r2, in2 := rect_clamp(Rect{5600, 1800, 400, 400}, b)
	check(in2, "a rectangle hanging off the edge still overlaps")
	eq_r(r2, Rect{5600, 1800, 160, 160}, "and is cut at the edge")

	// Hanging off the top-left, into the gap above HDMI-A-2.
	r3, in3 := rect_clamp(Rect{-50, -400, 200, 300}, b)
	check(in3, "a rectangle above the origin still overlaps")
	eq_r(r3, Rect{0, -200, 150, 100}, "and is cut at two edges at once")

	// Exactly the desktop.
	r4, in4 := rect_clamp(b, b)
	check(in4, "the desktop clamps to itself")
	eq_r(r4, b, "unchanged")

	// Entirely off the desktop: a saved region after a monitor is unplugged.
	_, out5 := rect_clamp(Rect{9000, 9000, 100, 100}, b)
	check(!out5, "a rectangle wholly off the desktop does not overlap")
	_, out6 := rect_clamp(Rect{-500, 0, 100, 100}, b)
	check(!out6, "nor one wholly to the left")
	// Touching but not overlapping: a rectangle that ends exactly where the
	// desktop begins has no pixels in it.
	_, out7 := rect_clamp(Rect{-100, 0, 100, 100}, b)
	check(!out7, "a rectangle that only touches the edge has no pixels")

	// Which monitor is a rectangle on?
	eq_i(output_containing(outs, Rect{100, 100, 200, 200}), 0, "a rectangle on the first monitor")
	eq_i(output_containing(outs, Rect{3000, 500, 200, 200}), 1, "one on the second")
	eq_i(output_containing(outs, Rect{9000, 9000, 10, 10}), -1, "one on neither")
	// Centre on the boundary: 1900 + 40/2 = 1920, the first pixel of DP-1.
	eq_i(output_containing(outs, Rect{1900, 0, 40, 40}), 1, "a rectangle straddling the seam")
	eq_i(output_containing(nil, Rect{0, 0, 1, 1}), -1, "no monitors, no answer")

	eq_r(output_rect(outs[1]), Rect{1920, -200, 3840, 2160}, "an output as a rectangle")
}

// ---------------------------------------------------------------------------
// Filenames
// ---------------------------------------------------------------------------

test_filenames :: proc() {
	section("filenames")

	name := stamp("screenshot")
	defer delete(name)
	// screenshot-2026-10-04_12-27-03.png — the convention already in use on
	// this machine, so a capture from this tool sorts with the others.
	check(strings.has_prefix(name, "screenshot-"), "the prefix, got %q", name)
	check(strings.has_suffix(name, ".png"), "the extension, got %q", name)
	eq_i(len(name), len("screenshot-")+len("2026-10-04_12-27-03")+len(".png"), "its length")
	body := name[len("screenshot-"):len(name) - 4]
	eq_i(len(body), 19, "the stamp is 19 characters")
	for i in 0 ..< len(body) {
		c := body[i]
		switch i {
		case 4, 7:
			check(c == '-', "a dash separates the date at %d, got %q", i, rune(c))
		case 10:
			check(c == '_', "an underscore separates date from time, got %q", rune(c))
		case 13, 16:
			check(c == '-', "a dash separates the time at %d, got %q", i, rune(c))
		case:
			check(c >= '0' && c <= '9', "a digit at %d, got %q", i, rune(c))
		}
	}
	// The year is this century and the month is a month: a formatter that
	// prints the enum rather than its number produces "October" here.
	year := body[:4]
	check(year >= "2020" && year <= "2099", "a plausible year, got %q", year)
	month := body[5:7]
	check(month >= "01" && month <= "12", "a month between 01 and 12, got %q", month)

	// A different prefix.
	other := stamp("region")
	defer delete(other)
	check(strings.has_prefix(other, "region-"), "the prefix is what was asked for, got %q", other)

	// Two stamps taken in the same second are the same string — which is
	// exactly why unique_path exists.
	a := stamp("x")
	b := stamp("x")
	defer delete(a)
	defer delete(b)
	eq_s(a, b, "two stamps in the same second collide")

	// The temporary path is per-process, so two copies of this tool running at
	// once cannot overwrite each other's captures.
	t0 := temp_path(0)
	t1 := temp_path(1)
	defer delete(t0)
	defer delete(t1)
	check(strings.has_prefix(t0, "/tmp/palmy-screenshot-"), "the temp prefix, got %q", t0)
	check(t0 != t1, "two captures get two paths")
	check(strings.contains(t0, fmt.tprintf("-%d-", os.get_pid())), "and the pid is in the name")

	dir := pictures_dir()
	check(strings.has_suffix(dir, "/Pictures"), "the output directory, got %q", dir)

	eq_s(mode_label(.Screen), "Whole screen", "mode 1")
	eq_s(mode_label(.Output), "One output", "mode 2")
	eq_s(mode_label(.Region), "Region", "mode 3")
}

// ---------------------------------------------------------------------------
// Never overwrite
//
// The tool writes only into its own output directory, and even there it will
// not replace a file that is already present.
// ---------------------------------------------------------------------------

test_no_overwrite :: proc() {
	section("saving never replaces a file")

	dir := fmt.tprintf("/tmp/palmy-screenshot-selftest-%d", os.get_pid())
	_ = os.make_directory_all(dir)
	// Clean up: this is the test's own directory and nothing else's.
	defer {_ = os.remove_all(dir)}

	name := "screenshot-2026-10-04_12-27-03.png"

	// Nothing there: the plain name.
	first := unique_path(dir, name)
	defer delete(first)
	eq_s(first, fmt.tprintf("%s/%s", dir, name), "an unused name is used as it is")

	// Put a file there — somebody else's, with contents worth not losing.
	precious := "do not lose me"
	check(
		os.write_entire_file(first, transmute([]u8)precious) == nil,
		"the fixture file was written",
	)

	second := unique_path(dir, name)
	defer delete(second)
	check(second != first, "a taken name is not reused")
	eq_s(second, fmt.tprintf("%s/screenshot-2026-10-04_12-27-03-2.png", dir), "the next one")
	check(!os.exists(second), "and the name it picked is free")

	check(os.write_entire_file(second, transmute([]u8){'x'}) == nil, "and can be written")
	third := unique_path(dir, name)
	defer delete(third)
	eq_s(third, fmt.tprintf("%s/screenshot-2026-10-04_12-27-03-3.png", dir), "and the one after")

	// The original is untouched, byte for byte.
	back, rerr := os.read_entire_file_from_path(first, context.temp_allocator)
	check(rerr == nil, "the first file is still readable")
	eq_s(string(back), precious, "and its contents are unchanged")

	// A name with no extension still gets a suffix rather than a dot.
	plain := unique_path(dir, "shot")
	defer delete(plain)
	eq_s(plain, fmt.tprintf("%s/shot", dir), "an unused extensionless name")
	check(os.write_entire_file(plain, transmute([]u8){'y'}) == nil, "written")
	plain2 := unique_path(dir, "shot")
	defer delete(plain2)
	eq_s(plain2, fmt.tprintf("%s/shot-2", dir), "and the next extensionless name")

	// A dotfile: the leading dot is part of the name, not an extension.
	dotted := unique_path(dir, ".hidden.png")
	defer delete(dotted)
	eq_s(dotted, fmt.tprintf("%s/.hidden.png", dir), "a dotfile name")
}

test_save_copy :: proc() {
	section("copying a capture out of /tmp")

	dir := fmt.tprintf("/tmp/palmy-screenshot-selftest-copy-%d", os.get_pid())
	_ = os.make_directory_all(dir)
	src := fmt.tprintf("%s/src.png", dir)
	dst := fmt.tprintf("%s/dst.png", dir)
	defer {_ = os.remove_all(dir)}

	// Not a real PNG; save_copy moves bytes and does not care.
	payload := "\x89PNG\r\n\x1a\n and then some bytes"
	check(os.write_entire_file(src, transmute([]u8)payload) == nil, "the source was written")

	ok, err := save_copy(src, dst)
	check(ok, "the copy succeeded: %s", err)
	back, rerr := os.read_entire_file_from_path(dst, context.temp_allocator)
	check(rerr == nil, "the copy is readable")
	eq_s(string(back), payload, "byte for byte")

	// The source is still there: a capture stays viewable in the preview
	// whether or not it has been saved, and /tmp is cleaned up on exit.
	check(os.exists(src), "the original is still in /tmp")
	eq_i(int(file_bytes(src)), len(payload), "and is the size it was")

	// A source that does not exist fails rather than writing an empty file.
	ok2, _ := save_copy(fmt.tprintf("%s/missing.png", dir), fmt.tprintf("%s/never.png", dir))
	check(!ok2, "copying a capture that is not there fails")
	check(!os.exists(fmt.tprintf("%s/never.png", dir)), "and writes nothing")

	eq_i(int(file_bytes("/tmp/definitely-not-a-file-here")), 0, "a missing file is zero bytes")
}

test_sizes :: proc() {
	section("sizes and delays")

	eq_s(human_bytes(0), "0 B", "nothing")
	eq_s(human_bytes(512), "512 B", "under a kilobyte")
	eq_s(human_bytes(1023), "1023 B", "just under")
	eq_s(human_bytes(1024), "1 kB", "exactly a kilobyte")
	eq_s(human_bytes(1536), "2 kB", "rounded")
	eq_s(human_bytes(1 << 20), "1.0 MB", "exactly a megabyte")
	eq_s(human_bytes(3 * (1 << 20) + (1 << 19)), "3.5 MB", "three and a half")

	m := Model{}
	eq_i(delay_secs(&m), 0, "no delay to start")
	for want in ([?]int{3, 5, 10, 0, 3}) {
		m.delay_at += 1
		eq_i(delay_secs(&m), want, "the delay cycles")
	}
	// The index is taken modulo the choice count, so it can be advanced
	// forever without going out of bounds.
	m.delay_at = 1 << 20
	check(delay_secs(&m) >= 0, "a wildly advanced delay index is still in range")
}

// ---------------------------------------------------------------------------
// The interface
//
// Return and Space are never pressed: they run grim.
// ---------------------------------------------------------------------------

@(private = "file")
step :: proc(off: ^p.Offscreen, m: ^Model) {
	ui := p.offscreen_begin(off)
	keys(ui, nil, m)
	build(ui, m)
	p.offscreen_end(off)
}

test_interface :: proc() {
	section("the interface, with no compositor")

	sc.register_shadcn_theme(false)
	p.set_text_gamma(1.8)
	off := p.offscreen_create(WIN_W, WIN_H, 1, "w-full h-full bg-background text-foreground")
	defer p.offscreen_destroy(off)
	load_selftest_fonts(&off.fonts)

	m := new(Model)
	defer free(m)
	m.sel = -1
	m.img_for = -1
	m.zoom = 1
	m.mode = .Screen
	m.have_grim = true
	m.have_slurp = true
	m.have_wlcopy = true
	m.outputs = parse_outputs(MONITORS, context.allocator)
	defer {
		for o in m.outputs {
			delete(o.name)
			delete(o.desc)
		}
		delete(m.outputs)
	}

	before := g_log_count

	step(off, m)
	step(off, m)
	check(ink(off) > 0.01, "the window drew something (ink %.3f)", ink(off))

	// Modes.
	p.press_key(off, '3')
	step(off, m)
	check(m.mode == .Region, "3 selects region mode, got %v", m.mode)
	p.press_key(off, '2')
	step(off, m)
	check(m.mode == .Output, "2 selects output mode, got %v", m.mode)
	p.press_key(off, 'o')
	step(off, m)
	eq_i(m.out_at, 1, "O cycles to the second output")
	p.press_key(off, 'o')
	step(off, m)
	eq_i(m.out_at, 0, "and wraps back to the first")
	p.press_key(off, '1')
	step(off, m)
	check(m.mode == .Screen, "1 goes back to the whole screen")

	// The delay.
	p.press_key(off, 't')
	step(off, m)
	eq_i(delay_secs(m), 3, "T sets a three second delay")
	for want in ([?]int{5, 10, 0}) {
		p.press_key(off, 't')
		step(off, m)
		eq_i(delay_secs(m), want, "and T again")
	}

	// A with no region saved says so and starts nothing.
	check(!m.have_region, "no region is saved yet")
	p.press_key(off, 'a')
	step(off, m)
	check(m.phase == .Idle, "A with no saved region starts no capture")
	check(!job_busy(), "and leaves no job running")

	// Zoom, with nothing to zoom.
	p.press_key(off, '=')
	step(off, m)
	near(m.zoom, 1.5, "= magnifies")
	p.press_key(off, '=')
	step(off, m)
	near(m.zoom, 2.25, "and again")
	p.press_key(off, '-')
	step(off, m)
	near(m.zoom, 1.5, "- shrinks")
	p.press_key(off, 'f')
	step(off, m)
	near(m.zoom, 1, "F fits")
	for _ in 0 ..< 20 {
		p.press_key(off, '=')
		step(off, m)
	}
	check(m.zoom <= 16, "zoom stops at 16x, got %.2f", m.zoom)
	for _ in 0 ..< 30 {
		p.press_key(off, '-')
		step(off, m)
	}
	check(m.zoom >= 1, "and does not go below 1x, got %.2f", m.zoom)

	// Moving the selection with no captures must not index past the end.
	p.press_key(off, p.KEY_DOWN)
	step(off, m)
	eq_i(m.sel, -1, "Down with nothing captured selects nothing")
	p.press_key(off, 'x')
	step(off, m)
	eq_i(m.n_shots, 0, "and discarding nothing discards nothing")

	// Saving with nothing captured must not write a file.
	p.press_key(off, 's')
	step(off, m)
	eq_i(g_log_count, before, "saving with nothing captured writes nothing")

	// The overlays.
	p.press_key(off, 'g')
	step(off, m)
	check(m.log_open, "G opened the command log")
	p.press_key(off, '1')
	step(off, m)
	check(m.mode == .Screen, "mode keys do nothing while the log is open")
	p.press_key(off, p.KEY_ESCAPE)
	step(off, m)
	check(!m.log_open, "Escape closed it")

	p.press_key(off, '?')
	step(off, m)
	check(m.help_open, "? opened the key list")
	p.press_key(off, p.KEY_ESCAPE)
	step(off, m)
	check(!m.help_open, "Escape closed it")

	// Nothing above ran grim, slurp or wl-copy.
	check(!job_busy(), "no job was ever started")
	eq_i(g_log_count, before, "no command was logged, because none was run")

	if shot := os.get_env("SHOT_SELFTEST_PNG", context.temp_allocator); shot != "" {
		p.offscreen_write_png(off, shot)
		fmt.printf("  wrote %s\n", shot)
	}
}

// ---------------------------------------------------------------------------
// `screenshot --shot out.png`
// ---------------------------------------------------------------------------

shot :: proc(path: string, keys_to_press: []u32 = nil) {
	sc.register_shadcn_theme(false)
	p.set_text_gamma(1.8)
	off := p.offscreen_create(WIN_W, WIN_H, 1, "w-full h-full bg-background text-foreground")
	defer p.offscreen_destroy(off)
	load_selftest_fonts(&off.fonts)

	m := new(Model)
	defer free(m)
	m.sel = -1
	m.img_for = -1
	m.zoom = 1
	m.mode = .Screen
	m.outputs = read_outputs()
	m.have_grim = have("grim")
	m.have_slurp = have("slurp")
	m.have_wlcopy = have("wl-copy")

	step(off, m)
	step(off, m)
	for k in keys_to_press {
		p.press_key(off, k)
		step(off, m)
	}
	step(off, m)
	if p.offscreen_write_png(off, path) {
		fmt.eprintfln("[screenshot] wrote %s", path)
	}
}

@(private = "file")
ink :: proc(off: ^p.Offscreen) -> f32 {
	px := p.offscreen_pixels(off)
	if len(px) == 0 {
		return 0
	}
	bg := px[0]
	n := 0
	for v in px {
		if v != bg {
			n += 1
		}
	}
	return f32(n) / f32(len(px))
}

FONT_DIR :: "/home/alex/Work/palmy/parity/web/public/fonts"
MONO_CANDIDATES := [?]string {
	"/usr/share/fonts/TTF/JetBrainsMonoNerdFont-Regular.ttf",
	"/usr/share/fonts/TTF/DejaVuSansMono.ttf",
	"/usr/share/fonts/liberation/LiberationMono-Regular.ttf",
}

load_selftest_fonts :: proc(f: ^p.Fonts) {
	for pair in ([?]struct {
		file: string,
		wt:   p.Font_Weight,
	}{
		{"Geist-400.ttf", .Regular},
		{"Geist-500.ttf", .Medium},
		{"Geist-600.ttf", .Semibold},
		{"Geist-700.ttf", .Bold},
	}) {
		p.load_font(f, fmt.tprintf("%s/%s", FONT_DIR, pair.file), .Sans, pair.wt)
	}
	for path in MONO_CANDIDATES {
		if p.load_font(f, path, .Mono, .Regular) {
			p.load_font(f, path, .Mono, .Medium)
			p.load_font(f, path, .Mono, .Semibold)
			p.load_font(f, path, .Mono, .Bold)
			break
		}
	}
}
