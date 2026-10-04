package main

// `image --selftest` checks the parts of the viewer that are arithmetic rather
// than pixels: the ordering a folder is browsed in, the format sniffer, the box
// filter behind every thumbnail, the rotation, and the zoom/pan transform.
// Those are the places where a wrong answer is silent — a thumbnail that is
// subtly wrong still looks like a thumbnail.

import "core:fmt"
import "core:os"
import "core:strings"
import p "palmy:."

checks: int
failures: int

check :: proc(ok: bool, what: string) {
	checks += 1
	if !ok {
		failures += 1
		fmt.printfln("  FAIL  %s", what)
	}
}

run_selftest :: proc() {
	test_paths()
	test_natural_order()
	test_sniff()
	test_format_helpers()
	test_downscale()
	test_rotate()
	test_transform()

	fmt.printfln(
		"image selftest: %d checks, %d failures",
		checks,
		failures,
	)
}

// ---------------------------------------------------------------------------

test_paths :: proc() {
	check(base_of("/a/b/c.png") == "c.png", "base_of takes the last component")
	check(base_of("c.png") == "c.png", "base_of of a bare name is the name")
	check(base_of("/c.png") == "c.png", "base_of at the root")
	check(base_of("/a/b/") == "", "base_of of a trailing slash is empty")
	check(dir_of("/a/b/c.png") == "/a/b", "dir_of drops the last component")
	check(dir_of("/c.png") == "/", "dir_of at the root is the root")
	check(dir_of("c.png") == ".", "dir_of of a bare name is the cwd")
	check(ext_of("/a/B.PNG") == "png", "ext_of lowercases")
	check(ext_of("/a/b") == "", "a name with no dot has no extension")
	check(ext_of("/a/.hidden") == "", "a leading dot is not an extension")
	check(ext_of("a.tar.gz") == "gz", "ext_of takes the last dot")
}

test_natural_order :: proc() {
	// The whole point: 9 before 10, which plain string order gets wrong.
	check(natural_less("shot-9.png", "shot-10.png"), "9 sorts before 10")
	check(!natural_less("shot-10.png", "shot-9.png"), "and not the other way")
	check(natural_less("shot-009.png", "shot-10.png"), "leading zeros do not change the value")
	check(!natural_less("shot-10.png", "shot-009.png"), "nor in reverse")
	check(natural_less("a.png", "b.png"), "letters still compare as letters")
	check(natural_less("IMG_1.png", "img_2.png"), "case is ignored")
	check(!natural_less("x.png", "x.png"), "a name is not less than itself")
	check(natural_less("x.png", "x1.png"), "a prefix sorts first")
	check(natural_less("1.png", "2.png"), "bare numbers compare numerically")
	check(natural_less("v2-9.png", "v2-10.png"), "the second number run is compared too")
	check(natural_less("v2-9.png", "v10-1.png"), "the first run decides when it differs")

	// A total order: sorting must not depend on the comparison order.
	names := [?]string{"b10", "B9", "a2", "a10", "A1", "c", "b2"}
	bad := 0
	for x in names {
		for y in names {
			if natural_less(x, y) && natural_less(y, x) {
				bad += 1
			}
		}
	}
	check(bad == 0, "natural_less is antisymmetric over a mixed sample")
}

test_sniff :: proc() {
	dir := fmt.tprintf("%s/palmy-image-selftest", os.temp_dir(context.temp_allocator))
	_ = os.make_directory_all(dir)
	defer _ = os.remove_all(dir)

	write :: proc(dir, name: string, bytes: []u8) -> string {
		path := fmt.tprintf("%s/%s", dir, name)
		_ = os.write_entire_file(path, bytes)
		return path
	}

	png := write(dir, "a.png", {0x89, 'P', 'N', 'G', 0x0d, 0x0a, 0x1a, 0x0a, 0, 0, 0, 13})
	jpg := write(dir, "b.jpg", {0xff, 0xd8, 0xff, 0xe0, 0, 16, 'J', 'F', 'I', 'F', 0})
	gif := write(dir, "c.gif", {'G', 'I', 'F', '8', '9', 'a', 1, 0, 1, 0, 0, 0, 0})
	bmp := write(dir, "d.bmp", {'B', 'M', 60, 0, 0, 0, 0, 0, 0, 0, 54, 0, 0, 0})
	txt := write(dir, "e.png", transmute([]u8)string("this is not an image at all\n"))

	check(sniff_format(png) == "PNG", "a PNG header sniffs as PNG")
	check(sniff_format(jpg) == "JPEG", "a JPEG header sniffs as JPEG")
	check(sniff_format(gif) == "GIF", "a GIF header sniffs as GIF")
	check(sniff_format(bmp) == "BMP", "a BMP header sniffs as BMP")
	// The extension lies here, and the sniffer has to not believe it.
	check(sniff_format(txt) == "", "a text file named .png sniffs as nothing")
	check(sniff_format(fmt.tprintf("%s/missing.png", dir)) == "", "a missing file sniffs as nothing")

	// probe fills the struct and marks the undecodable one.
	bad := Shot{path = txt, name = "e.png"}
	probe(&bad)
	check(bad.probed, "probe marks the shot as probed")
	check(bad.broken, "a text file is marked broken")

	check(p.is_image_path("x.JPEG"), "is_image_path ignores case")
	check(!p.is_image_path("x.txt"), "a .txt is not an image path")
}

test_format_helpers :: proc() {
	check(human_bytes(512) == "512 B", "bytes under 1 KB")
	check(human_bytes(2048) == "2.0 KB", "kilobytes")
	check(human_bytes(3 * 1024 * 1024) == "3.0 MB", "megabytes")
	check(strings.has_suffix(human_bytes(5 * 1024 * 1024 * 1024), "GB"), "gigabytes")
	check(gcd(1920, 1080) == 120, "gcd(1920,1080)")
	check(gcd(7, 0) == 7, "gcd with zero")
	check(aspect_label(1920, 1080) == "16:9", "1920x1080 is 16:9")
	check(aspect_label(1024, 1024) == "1:1", "a square is 1:1")
	check(aspect_label(0, 0) == "—", "no dimensions, no aspect")
	// 1214x1295 has no small ratio, so it falls back to a decimal.
	check(strings.has_suffix(aspect_label(1214, 1295), ":1"), "an awkward ratio falls back to N:1")
	check(channels_label(4) == "4 · RGBA", "four channels are RGBA")
	check(channels_label(1) == "1 · grey", "one channel is grey")
	check(strings.contains(human_pixels(1920, 1080), "2.1 MP"), "megapixels are reported")
}

// ---------------------------------------------------------------------------

px_of :: proc(a, r, g, b: u32) -> u32 {
	return (a << 24) | (r << 16) | (g << 8) | b
}

test_downscale :: proc() {
	// A 4x2 image whose left half is 100 and right half is 200. Halving the
	// width means each output column covers two source columns of the same
	// value, so the halves survive; a filter that sampled one pixel per cell
	// would pass this too, which is what the next case is for.
	src := p.Image {
		px              = []u32{
			px_of(255, 100, 100, 100),
			px_of(255, 100, 100, 100),
			px_of(255, 200, 200, 200),
			px_of(255, 200, 200, 200),
			px_of(255, 100, 100, 100),
			px_of(255, 100, 100, 100),
			px_of(255, 200, 200, 200),
			px_of(255, 200, 200, 200),
		},
		w               = 4,
		h               = 2,
		source_channels = 3,
	}
	out := downscale(src, 2)
	defer delete(out.px)
	check(out.w == 2 && out.h == 1, "4x2 downscaled to a longest edge of 2 is 2x1")
	r0 := (out.px[0] >> 16) & 0xff
	r1 := (out.px[1] >> 16) & 0xff
	check(r0 == 100, "the left half keeps its own value")
	check(r1 == 200, "the right half keeps its own value")

	// Now 2x1 of mixed pixels into 1x1: a real average.
	mix := p.Image {
		px = []u32{px_of(255, 0, 0, 0), px_of(255, 200, 100, 50)},
		w = 2,
		h = 1,
		source_channels = 3,
	}
	one := downscale(mix, 1)
	defer delete(one.px)
	check(one.w == 1 && one.h == 1, "2x1 downscales to 1x1")
	check((one.px[0] >> 16) & 0xff == 100, "red averages to 100")
	check((one.px[0] >> 8) & 0xff == 50, "green averages to 50")
	check(one.px[0] & 0xff == 25, "blue averages to 25")

	// A transparent neighbour must not drag an opaque pixel toward black.
	alpha := p.Image {
		px = []u32{px_of(255, 255, 255, 255), px_of(0, 0, 0, 0)},
		w = 2,
		h = 1,
		source_channels = 4,
	}
	a1 := downscale(alpha, 1)
	defer delete(a1.px)
	check((a1.px[0] >> 16) & 0xff == 255, "colour is weighted by alpha, so white stays white")
	check((a1.px[0] >> 24) & 0xff == 127, "alpha itself averages")

	// Aspect ratio survives the longest-edge clamp.
	wide := p.Image {
		px = make([]u32, 1000 * 250),
		w = 1000,
		h = 250,
		source_channels = 3,
	}
	defer delete(wide.px)
	t := downscale(wide, 240)
	defer delete(t.px)
	check(t.w == 240, "the long edge lands on the limit")
	check(t.h == 60, "the short edge keeps the 4:1 ratio")

	// Already small enough: left alone.
	small := p.Image{px = make([]u32, 9), w = 3, h = 3, source_channels = 3}
	defer delete(small.px)
	s2 := downscale(small, 240)
	defer delete(s2.px)
	check(s2.w == 3 && s2.h == 3, "an image under the limit is not enlarged")
}

test_rotate :: proc() {
	// 2x3, numbered so every pixel can be followed round the turn.
	src := p.Image {
		px = []u32{1, 2, 3, 4, 5, 6},
		w = 2,
		h = 3,
		source_channels = 3,
	}
	one := rotate90(src)
	defer delete(one.px)
	check(one.w == 3 && one.h == 2, "a quarter turn swaps the dimensions")
	// (x,y) -> (h-1-y, x): source (0,0)=1 lands at (2,0).
	check(one.px[0 * one.w + 2] == 1, "the top-left pixel moves to the top-right")
	check(one.px[1 * one.w + 2] == 2, "the pixel to its right moves below it")
	check(one.px[0 * one.w + 0] == 5, "the bottom-left pixel moves to the top-left")

	// Four turns is the identity, which is the property the viewer relies on.
	cur := src
	owned := false
	for _ in 0 ..< 4 {
		nxt := rotate90(cur)
		if owned {
			delete(cur.px)
		}
		cur = nxt
		owned = true
	}
	same := cur.w == src.w && cur.h == src.h
	for i in 0 ..< len(src.px) {
		if cur.px[i] != src.px[i] {
			same = false
		}
	}
	check(same, "four quarter turns are the identity")
	delete(cur.px)

	// `rotated` must not allocate for the common case.
	r0, owned0 := rotated(src, 0)
	check(!owned0 && r0.w == src.w, "rotating by zero returns the original untouched")
	_, owned4 := rotated(src, 4)
	check(!owned4, "a whole turn is also free")
	r3, owned3 := rotated(src, -1)
	check(owned3 && r3.w == 3 && r3.h == 2, "a negative turn normalises to three quarters")
	if owned3 {
		delete(r3.px)
	}
}

test_transform :: proc() {
	st := St {
		view_rect = {0, 0, 1000, 500},
		fit       = true,
		scale     = 1,
	}
	big := p.Image{w = 2000, h = 1000}
	small := p.Image{w = 100, h = 50}

	check(fit_scale(&st, big) == 0.5, "a 2000-wide image fits a 1000-wide box at 50%")
	check(fit_scale(&st, small) == 1, "fitting never magnifies past 100%")
	check(effective_scale(&st, big) == 0.5, "fit mode uses the fitted scale")

	st.fit = false
	st.scale = 2
	check(effective_scale(&st, big) == 2, "manual mode uses the manual scale")

	// Panning is bounded by how far the picture actually overflows. The
	// transform reads the *displayed* image, which is the decode turned by
	// `rot`, so the test has to set that up rather than just `shown`.
	st.cur = big
	st.cur_ok = true
	st.cur_idx = 0
	st.rot = 0
	check(display(&st).w == 2000, "display returns the decode when the rotation is zero")
	st.shown = big
	st.scale = 1 // 2000x1000 inside 1000x500: 500 and 250 of slack each way
	st.pan = {9999, 9999}
	clamp_pan(&st, big)
	check(st.pan.x == 500, "pan stops at half the horizontal overflow")
	check(st.pan.y == 250, "pan stops at half the vertical overflow")
	st.pan = {-9999, -9999}
	clamp_pan(&st, big)
	check(st.pan.x == -500 && st.pan.y == -250, "and at the other edge")

	// An image smaller than the viewport cannot be panned at all.
	st.cur = small
	st.cur_idx = 1
	st.shown = small
	st.scale = 1
	st.pan = {100, 100}
	clamp_pan(&st, small)
	check(st.pan == {0, 0}, "a picture that fits is centred and cannot be dragged")
	check(!pannable(&st), "and reports itself as not pannable")

	st.cur = big
	st.cur_idx = 0
	st.shown = big
	st.scale = 1
	check(pannable(&st), "a picture larger than the viewport is pannable")

	// The zoom ladder stays inside its limits.
	st.scale = ZOOM_MAX
	zoom_by(&st, ZOOM_STEP)
	check(st.scale == ZOOM_MAX, "zooming in stops at the maximum")
	st.scale = ZOOM_MIN
	zoom_by(&st, 1 / ZOOM_STEP)
	check(st.scale == ZOOM_MIN, "zooming out stops at the minimum")
	set_zoom(&st, 1)
	check(st.scale == 1 && !st.fit, "setting a zoom leaves fit mode")
}
