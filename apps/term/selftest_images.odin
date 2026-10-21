package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/linux"
import "core:time"
import p "palmy:."
import vt "./vt"

// ---------------------------------------------------------------------------
// The image protocols.
//
// The numbers these assert come from the oracles, not from this code:
//
//   foot 1.16.2 (cell 6x13) rendering testdata/foot-gradient.six after
//   "A\r\nxyz" put the cursor at row 5, column 4, and drew the pixels quoted
//   below (read out of a grim screenshot of foot on a headless sway).
//
//   kitty 0.32.2 (cell 8x17) running the same probe with the icat streams in
//   testdata answered and moved its cursor exactly as quoted, and drew the
//   16-bit PNG with the pixel values quoted. A 64x48 block of our render was
//   compared with kitty's screenshot pixel for pixel: identical.
// ---------------------------------------------------------------------------

FOOT_SIXEL :: #load("testdata/foot-gradient.six")
GRADIENT_PNG :: #load("testdata/gradient.png")
ICAT_STREAM :: #load("testdata/icat-stream.esc")
ICAT_PLACE :: #load("testdata/icat-place.esc")
ICAT_Z :: #load("testdata/icat-z.esc")
KITTY_RGBA_ZLIB :: #load("testdata/kitty-rgba-zlib.esc")
ZLIB_BOMB :: #load("testdata/zlib-bomb.esc")
RGBA8_PNG :: #load("testdata/rgba8.png")

@(private = "file")
feed_b :: proc(t: ^vt.Terminal, b: []u8) {
	vt.terminal_feed(t, b)
}

@(private = "file")
take :: proc(t: ^vt.Terminal) -> string {
	out := vt.terminal_take_output(t)
	s := strings.clone(string(out), context.temp_allocator)
	delete(out)
	return s
}

@(private = "file")
near :: proc(got, want: u32, tol: int) -> bool {
	for sh in ([]uint{0, 8, 16}) {
		a := int(got >> sh & 0xFF)
		b := int(want >> sh & 0xFF)
		if abs(a - b) > tol {
			return false
		}
	}
	return true
}

@(private = "file")
px_at :: proc(img: ^vt.Image, x, y: int) -> u32 {
	if img == nil || x < 0 || y < 0 || x >= img.w || y >= img.h {
		return 0
	}
	return img.px[y * img.w + x]
}

@(private = "file")
frag_count :: proc(t: ^vt.Terminal, y: int) -> int {
	s := vt.screen(t)
	if y < 0 || y >= len(s.lines) {
		return 0
	}
	return len(s.lines[y].frags)
}

@(private = "file")
kitty :: proc(ctrl: string, payload := "") -> string {
	if payload == "" {
		return fmt.tprintf("\x1b_G%s\x1b\\", ctrl)
	}
	return fmt.tprintf("\x1b_G%s;%s\x1b\\", ctrl, payload)
}

@(private = "file")
b64 :: proc(data: []u8) -> string {
	return base64_encode(data, context.temp_allocator)
}

// A solid w x h RGB image as a Kitty direct transmission payload.
@(private = "file")
solid_rgb :: proc(w, h: int, r, g, bl: u8) -> string {
	data := make([]u8, w * h * 3, context.temp_allocator)
	for i in 0 ..< w * h {
		data[i * 3] = r
		data[i * 3 + 1] = g
		data[i * 3 + 2] = bl
	}
	return b64(data)
}

test_graphics :: proc() {
	test_parser_apc()
	test_sixel_foot()
	test_sixel_engine()
	test_kitty_oracle()
	test_kitty_engine()
	test_kitty_files()
	test_image_memory()
	test_image_render()
}

@(private = "file")
test_parser_apc :: proc() {
	eq_s(
		strings.join(apc_actions("\x1b_Gi=1;AAAA\x1b\\"), "|", context.temp_allocator),
		"apc Gi=1;AAAA|esc \\",
		"an APC string is captured, not dropped",
	)
	eq_s(
		strings.join(apc_actions("\x9fGa=q\x9c"), "|", context.temp_allocator),
		"apc Ga=q",
		"the eight-bit APC and ST",
	)
	eq_s(
		strings.join(apc_actions("\x1b_Gx\x18ok"), "|", context.temp_allocator),
		"print o|print k",
		"CAN abandons an APC",
	)
}

@(private = "file")
Apc_Capture :: struct {
	acts: [dynamic]string,
}

@(private = "file")
apc_actions :: proc(input: string) -> []string {
	c := new(Apc_Capture, context.temp_allocator)
	c.acts = make([dynamic]string, context.temp_allocator)
	par: vt.Parser
	vt.parser_init(&par, {user = c, fn = proc(user: rawptr, a: vt.Action) {
		c := (^Apc_Capture)(user)
		#partial switch a.kind {
		case .Apc_Dispatch:
			append(&c.acts, fmt.tprintf("apc %s", string(a.osc)))
		case .Print:
			append(&c.acts, fmt.tprintf("print %c", a.cp))
		case .Esc_Dispatch:
			append(&c.acts, fmt.tprintf("esc %c", rune(a.b)))
		}
	}})
	defer vt.parser_destroy(&par)
	vt.parse(&par, transmute([]u8)input)
	return c.acts[:]
}

// Sixel, against foot.
@(private = "file")
test_sixel_foot :: proc() {
	t: vt.Terminal
	vt.terminal_init(&t, 80, 24, 100)
	defer vt.terminal_destroy(&t)
	vt.terminal_set_cell_size(&t, 6, 13) // foot's cell on the headless sway

	feed(&t, "\x1b[c")
	eq_s(take(&t), "\x1b[?62;4;22c", "DA1 says Sixel (4), as foot's does")
	feed(&t, "\x1b[16t")
	eq_s(take(&t), "\x1b[6;13;6t", "the cell size in pixels, as foot reports it")
	feed(&t, "\x1b[14t")
	eq_s(take(&t), fmt.tprintf("\x1b[4;%d;%dt", 24 * 13, 80 * 6), "the text area in pixels")

	feed(&t, "A\r\nxyz")
	feed_b(&t, FOOT_SIXEL)
	x, y := vt.terminal_cursor(&t)
	// foot: before (2;4), after (5;4) -- the cursor ends on the image's last
	// row (48 px over 13 px cells is four rows), in the column it started.
	eq_i(y, 4, "after a Sixel image the cursor is on its last row (foot: row 5)")
	eq_i(x, 3, "in the column the image started in (foot: column 4)")
	eq_i(len(t.gfx.images), 1, "one image")
	img := len(t.gfx.images) > 0 ? t.gfx.images[0] : nil
	if img == nil {
		return
	}
	eq_i(img.w, 64, "the image is 64 pixels wide")
	eq_i(img.h, 48, "and 48 tall")
	// Pixel values foot drew, read from its screenshot. A Sixel colour is
	// a percentage, so the conversion back to 0..255 may differ by one.
	check(near(px_at(img, 0, 0), 0xF70000, 2), "top left is foot's red, got %06x", px_at(img, 0, 0) & 0xFFFFFF)
	check(near(px_at(img, 16, 16), 0xF7F700, 2), "the square is foot's yellow, got %06x", px_at(img, 16, 16) & 0xFFFFFF)
	check(near(px_at(img, 32, 24), 0x77007F, 2), "the middle is foot's purple, got %06x", px_at(img, 32, 24) & 0xFFFFFF)
	check(near(px_at(img, 40, 10), 0xC60030, 2), "and so is (40,10), got %06x", px_at(img, 40, 10) & 0xFFFFFF)
	check(near(px_at(img, 63, 30), 0x5900A0, 2), "and (63,30), got %06x", px_at(img, 63, 30) & 0xFFFFFF)
	for row in 1 ..= 4 {
		check(frag_count(&t, row) == 1, "screen row %d shows a slice of the image", row)
	}
	eq_i(frag_count(&t, 5), 0, "the row after it does not")
	eq_s(line(&t, 1), "xyz", "the text left of the image is untouched")

	// Text printed over a Sixel image cuts it, as in foot's screenshot.
	feed(&t, "B")
	s := vt.screen(&t)
	f := s.lines[4].frags
	check(len(f) == 1 && f[0].from == 1 && f[0].to == 11, "the B cut the first column out of the last row")
}

@(private = "file")
test_sixel_engine :: proc() {
	t: vt.Terminal
	vt.terminal_init(&t, 20, 5, 100)
	defer vt.terminal_destroy(&t)
	vt.terminal_set_cell_size(&t, 10, 20)

	// XTSMGRAPHICS: colour registers and geometry.
	feed(&t, "\x1b[?1;1;0S")
	eq_s(take(&t), "\x1b[?1;0;256S", "256 colour registers")
	feed(&t, "\x1b[?2;1;0S")
	eq_s(take(&t), "\x1b[?2;0;200;100S", "the largest Sixel image is the screen")
	feed(&t, "\x1b[?3;1;0S")
	eq_s(take(&t), "\x1b[?3;1;0S", "an unknown item is an error")

	// Colours: RGB in percent, and HLS with DEC's hue (0 is blue, 120 red).
	feed(&t, "\x1bP0;1;0q#1;2;100;0;0#2;1;120;50;100#3;1;0;50;100#1~#2~#3~\x1b\\")
	img := len(t.gfx.images) > 0 ? t.gfx.images[len(t.gfx.images) - 1] : nil
	check(img != nil && img.w == 3 && img.h == 6, "a 3x6 image from three sixels")
	if img != nil {
		eq_i(int(px_at(img, 0, 0)), int(0xFFFF0000), "#1;2;100;0;0 is red")
		eq_i(int(px_at(img, 1, 5)), int(0xFFFF0000), "HLS hue 120 is red too")
		eq_i(int(px_at(img, 2, 3)), int(0xFF0000FF), "and HLS hue 0 is blue")
	}

	// Repeats, carriage return, new band, and transparency.
	vt.terminal_reset(&t)
	feed(&t, "\x1bP0;1;0q#1;2;0;100;0!5@$#2;2;0;0;100!2A-!3~\x1b\\")
	img = len(t.gfx.images) > 0 ? t.gfx.images[0] : nil
	check(img != nil && img.w == 5 && img.h == 12, "!5 repeats, - starts a second band")
	if img != nil {
		eq_i(int(px_at(img, 4, 0)), int(0xFF00FF00), "the fifth repeated pixel")
		eq_i(int(px_at(img, 1, 1)), int(0xFF0000FF), "$ went back and painted over")
		eq_i(int(px_at(img, 4, 1)), 0, "P2=1: an unpainted pixel is transparent")
		eq_i(int(px_at(img, 2, 6)), int(0xFF0000FF), "the colour carries into the second band")
	}
	vt.terminal_reset(&t)
	feed(&t, "\x1bPq#1;2;0;100;0@$\x1b\\")
	img = len(t.gfx.images) > 0 ? t.gfx.images[0] : nil
	if img != nil {
		eq_i(int(px_at(img, 0, 0)), int(0xFF00FF00), "P2=0 still paints what was painted")
	}
	vt.terminal_reset(&t)
	feed(&t, "\x1bPq\"1;1;4;6#1;2;0;100;0@\x1b\\")
	img = len(t.gfx.images) > 0 ? t.gfx.images[0] : nil
	check(img != nil && img.w == 4 && img.h == 6, "the raster declares 4x6")
	if img != nil {
		bg := vt.terminal_bg(&t)
		want := 0xFF00_0000 | u32(bg[0]) << 16 | u32(bg[1]) << 8 | u32(bg[2])
		eq_i(int(px_at(img, 3, 5)), int(want), "P2=0 fills the raster with the background")
	}

	// An image at the bottom scrolls the screen, and the rows carry it.
	vt.terminal_reset(&t)
	feed(&t, "1\r\n2\r\n3\r\n4\r\n5")
	feed(&t, "\x1bPq#1;2;100;0;0!10~-!10~-!10~-!10~-!10~-!10~-!10~-!10~-!10~-!10~\x1b\\") // 10x60: three rows
	_, y := vt.terminal_cursor(&t)
	eq_i(y, 4, "the cursor is on the bottom row")
	eq_s(line(&t, 2), "5", "the screen scrolled two lines to fit the image")
	check(frag_count(&t, 2) == 1 && frag_count(&t, 3) == 1 && frag_count(&t, 4) == 1, "the image is on the last three rows")
	s := vt.screen(&t)
	check(len(s.lines[2].frags) == 1 && s.lines[2].frags[0].row == 0, "its first slice is on row 3")

	// DECSDM puts it at the top left and moves nothing.
	vt.terminal_reset(&t)
	feed(&t, "\x1b[3;5H\x1b[?80h\x1bPq#1;2;100;0;0~\x1b\\")
	x, y2 := vt.terminal_cursor(&t)
	check(x == 4 && y2 == 2, "DECSDM leaves the cursor where it was")
	eq_i(frag_count(&t, 0), 1, "and puts the image on the top row")
	feed(&t, "\x1b[?80l")

	// A new Sixel image replaces one it covers completely.
	vt.terminal_reset(&t)
	feed(&t, "\x1bPq#1;2;100;0;0!10~\x1b\\\r")
	feed(&t, "\x1bPq#1;2;0;100;0!10~\x1b\\\r")
	eq_i(len(t.gfx.images), 1, "redrawing a Sixel image in place does not stack copies")
	eq_i(frag_count(&t, 0), 1, "one slice on the row")

	// Erasing a line cuts it; ED 2 removes it; RIS forgets everything.
	feed(&t, "\x1b[1;1H\x1b[K")
	eq_i(len(t.gfx.images), 0, "EL over a whole Sixel image removes it")
	feed(&t, "\x1bPq#1;2;100;0;0!10~\x1b\\")
	feed(&t, "\x1b[2J")
	eq_i(len(t.gfx.images), 0, "ED 2 removes images on the screen")
	eq_i(t.gfx.bytes, 0, "and their pixels")
	feed(&t, "\x1bPq#1;2;100;0;0!10~\x1b\\\x1bc")
	eq_i(len(t.gfx.images), 0, "RIS removes images")

	// The alternate screen keeps its own images, and loses them on re-entry.
	feed(&t, "\x1b[?1049h\x1bPq#1;2;100;0;0!10~\x1b\\")
	eq_i(len(t.gfx.images), 1, "an image on the alternate screen")
	feed(&t, "\x1b[?1049l")
	eq_i(frag_count(&t, 0), 0, "the primary screen does not show it")
	feed(&t, "\x1b[?1049h")
	eq_i(len(t.gfx.images), 0, "and it is gone when the alternate screen is cleared")
	feed(&t, "\x1b[?1049l")
}

// The Kitty protocol, against kitty: the same probe, the same answers.
@(private = "file")
test_kitty_oracle :: proc() {
	t: vt.Terminal
	vt.terminal_init(&t, 80, 24, 100)
	defer vt.terminal_destroy(&t)
	vt.terminal_set_cell_size(&t, 8, 17) // kitty's cell, font_size 10

	pos :: proc(t: ^vt.Terminal) -> [2]int {
		x, y := vt.terminal_cursor(t)
		return {y + 1, x + 1} // CPR order, one based, as the probe recorded
	}
	feed(&t, "A\r\nxyz")
	eq_i(pos(&t)[1], 4, "probe start: (2;4)")
	feed_b(&t, ICAT_STREAM)
	check(pos(&t) == {5, 1}, "after icat (stream): kitty (5;1), got %v", pos(&t))
	feed(&t, "B")
	feed_b(&t, KITTY_RGBA_ZLIB)
	eq_s(take(&t), "\x1b_Gi=7;OK\x1b\\", "chunked zlib RGBA: kitty answers i=7;OK")
	check(pos(&t) == {5, 4}, "the cursor moved past the 2-cell image: kitty (5;4), got %v", pos(&t))
	feed(&t, "C")
	feed(&t, kitty("a=t,f=24,s=10,v=10,i=9", solid_rgb(10, 10, 0, 0, 255)))
	eq_s(take(&t), "\x1b_Gi=9;OK\x1b\\", "transmit only: i=9;OK")
	check(pos(&t) == {5, 5}, "and nothing moved: kitty (5;5), got %v", pos(&t))
	feed(&t, kitty("a=p,i=9,p=1,c=4,r=2"))
	eq_s(take(&t), "\x1b_Gi=9,p=1;OK\x1b\\", "place it 4x2: i=9,p=1;OK")
	check(pos(&t) == {6, 9}, "cursor after a 4x2 placement: kitty (6;9), got %v", pos(&t))
	feed(&t, "D")
	feed(&t, kitty("a=q,i=31,s=1,v=1,f=24", "AAAA"))
	eq_s(take(&t), "\x1b_Gi=31;OK\x1b\\", "a query: i=31;OK")
	eq_i(int(uintptr(vt.image_by_id(&t.gfx, 31))), 0, "a query stores nothing")
	feed(&t, kitty("a=T,f=24,s=10,v=10,i=11", b64(make([]u8, 5, context.temp_allocator))))
	eq_s(
		take(&t),
		"\x1b_Gi=11;ENODATA:Insufficient image data: 5 < 300\x1b\\",
		"short data: kitty's own error, word for word",
	)
	feed_b(&t, ICAT_Z)
	check(pos(&t) == {9, 1}, "icat -z -1: kitty (9;1), got %v", pos(&t))
	feed(&t, "zz")
	feed_b(&t, ICAT_PLACE)
	check(pos(&t) == {3, 42}, "icat --place uses C=1: the cursor stays at kitty's (3;42), got %v", pos(&t))

	// The 16-bit PNG icat sent, decoded: kitty's pixels, exactly.
	var_img: ^vt.Image
	for img in t.gfx.images {
		if img.w == 64 && img.h == 48 {
			var_img = img
			break
		}
	}
	check(var_img != nil, "the icat PNG is held")
	eq_i(int(px_at(var_img, 0, 0) & 0xFFFFFF), 0xFF0000, "PNG pixel (0,0) is kitty's red")
	eq_i(int(px_at(var_img, 16, 16) & 0xFFFFFF), 0xFFFF00, "(16,16) kitty's yellow")
	eq_i(int(px_at(var_img, 32, 24) & 0xFFFFFF), 0x7D0082, "(32,24) kitty's purple")
	eq_i(int(px_at(var_img, 63, 47) & 0xFFFFFF), 0x0000FF, "(63,47) kitty's blue")
	eq_i(int(px_at(var_img, 40, 10) & 0xFFFFFF), 0xC90036, "(40,10) kitty's crimson")

	// z: the -z -1 placement is below the text, the others above it.
	zs := 0
	for pl in t.gfx.placements {
		if pl.z < 0 {
			zs += 1
		}
	}
	eq_i(zs, 1, "one placement below the text")
}

@(private = "file")
test_kitty_engine :: proc() {
	t: vt.Terminal
	vt.terminal_init(&t, 40, 10, 100)
	defer vt.terminal_destroy(&t)
	vt.terminal_set_cell_size(&t, 10, 20)

	// Quiet: q=1 drops OK but not errors, q=2 drops both, no id no reply.
	feed(&t, kitty("a=t,f=24,s=2,v=2,i=1,q=1", solid_rgb(2, 2, 1, 2, 3)))
	eq_s(take(&t), "", "q=1 suppresses OK")
	feed(&t, kitty("a=p,i=99,q=1"))
	eq_s(take(&t), "\x1b_Gi=99;ENOENT:no such image\x1b\\", "but not an error")
	feed(&t, kitty("a=p,i=99,q=2"))
	eq_s(take(&t), "", "q=2 suppresses errors too")
	feed(&t, kitty("a=T,f=24,s=2,v=2", solid_rgb(2, 2, 1, 2, 3)))
	eq_s(take(&t), "", "no id, no reply")
	feed(&t, kitty("a=t,f=24,s=2,v=2,I=5", solid_rgb(2, 2, 1, 2, 3)))
	r := take(&t)
	check(strings.has_prefix(r, "\x1b_Gi=") && strings.contains(r, ",I=5;OK"), "an image number gets an id assigned: %q", r)

	// Sizing in cells: c alone keeps the aspect ratio.
	vt.terminal_reset(&t)
	feed(&t, kitty("a=t,f=24,s=40,v=20,i=3", solid_rgb(40, 20, 9, 9, 9)))
	feed(&t, kitty("a=p,i=3,c=8,C=1"))
	pl := len(t.gfx.placements) > 0 ? t.gfx.placements[0] : nil
	check(pl != nil && pl.cols == 8 && pl.rows == 2 && pl.dw == 80 && pl.dh == 40, "c=8: 80x40 in 8x2 cells")
	x, y := vt.terminal_cursor(&t)
	check(x == 0 && y == 0, "C=1 leaves the cursor alone")
	// Source rectangle and offset.
	feed(&t, kitty("a=p,i=3,p=2,x=10,y=5,w=20,h=10,X=3,Y=4,C=1"))
	var_pl: ^vt.Placement
	for q in t.gfx.placements {
		if q.id == 2 {
			var_pl = q
		}
	}
	check(var_pl != nil && var_pl.sx == 10 && var_pl.sw == 20 && var_pl.ox == 3 && var_pl.oy == 4, "x,y,w,h and X,Y are kept")
	check(var_pl != nil && var_pl.cols == 3 && var_pl.rows == 1, "a 20x10 crop offset by (3,4) covers 3x1 cells")

	// Re-placing under the same p moves it rather than adding one.
	feed(&t, "\x1b[5;5H")
	feed(&t, kitty("a=p,i=3,p=2,C=1"))
	n := 0
	for q in t.gfx.placements {
		if q.id == 2 {
			n += 1
		}
	}
	eq_i(n, 1, "p=2 placed again is moved, not duplicated")
	eq_i(frag_count(&t, 4), 1, "it is on row 5 now")

	// Deleting. Lower case keeps the image, upper case frees it.
	feed(&t, kitty("a=d,d=i,i=3"))
	eq_i(len(t.gfx.placements), 0, "d=i removes the placements of image 3")
	check(vt.image_by_id(&t.gfx, 3) != nil, "but keeps the image")
	feed(&t, kitty("a=p,i=3,C=1"))
	eq_i(len(t.gfx.placements), 1, "so it can be placed again")
	feed(&t, kitty("a=d,d=I,i=3"))
	check(vt.image_by_id(&t.gfx, 3) == nil, "d=I frees it")
	eq_i(t.gfx.bytes, 0, "and its pixels")

	vt.terminal_reset(&t)
	feed(&t, kitty("a=t,f=24,s=10,v=20,i=4", solid_rgb(10, 20, 1, 1, 1)))
	feed(&t, "\x1b[1;1H")
	feed(&t, kitty("a=p,i=4,p=1,C=1"))
	feed(&t, "\x1b[1;5H")
	feed(&t, kitty("a=p,i=4,p=2,C=1,z=5"))
	feed(&t, "\x1b[3;9H")
	feed(&t, kitty("a=p,i=4,p=3,C=1"))
	eq_i(len(t.gfx.placements), 3, "three placements")
	feed(&t, kitty("a=d,d=p,x=5,y=1"))
	eq_i(len(t.gfx.placements), 2, "d=p deletes the one covering cell (5,1)")
	feed(&t, kitty("a=d,d=z,z=5"))
	eq_i(len(t.gfx.placements), 2, "d=z with no match deletes nothing")
	feed(&t, kitty("a=d,d=x,x=9"))
	eq_i(len(t.gfx.placements), 1, "d=x deletes the one in column 9")
	feed(&t, "\x1b[1;1H")
	feed(&t, kitty("a=d,d=c"))
	eq_i(len(t.gfx.placements), 0, "d=c deletes the one under the cursor")
	feed(&t, kitty("a=p,i=4,C=1"))
	feed(&t, kitty("a=d"))
	eq_i(len(t.gfx.placements), 0, "a bare a=d deletes everything visible")
	check(vt.image_by_id(&t.gfx, 4) != nil, "without freeing the image")
	feed(&t, kitty("a=p,i=4,C=1"))
	feed(&t, kitty("a=d,d=A"))
	eq_i(len(t.gfx.images), 0, "d=A frees what it unplaced")

	// A Kitty delete never touches a Sixel image.
	feed(&t, "\x1bPq#1;2;100;0;0~\x1b\\")
	feed(&t, kitty("a=d,d=A"))
	eq_i(len(t.gfx.images), 1, "Sixel images are not the Kitty protocol's to delete")

	// Things this does not do say so.
	feed(&t, kitty("a=f,i=4"))
	r = take(&t)
	check(strings.contains(r, "ENOTSUP"), "animation answers ENOTSUP: %q", r)
	feed(&t, kitty("a=T,f=24,s=1,v=1,i=8,U=1", "AAAA"))
	r = take(&t)
	check(strings.contains(r, "ENOTSUP"), "unicode placeholders answer ENOTSUP: %q", r)
	feed(&t, kitty("a=T,f=24,s=1,v=1,i=8", "!!!!"))
	r = take(&t)
	check(strings.contains(r, "EINVAL"), "bad base64 answers EINVAL: %q", r)
	feed(&t, kitty("a=T,f=100,i=8", b64(transmute([]u8)string("not a png at all, really"))))
	r = take(&t)
	check(strings.contains(r, "EBADPNG"), "a non-PNG answers EBADPNG: %q", r)

	// An 8-bit RGBA PNG keeps its alpha.
	vt.terminal_reset(&t)
	feed(&t, kitty("a=t,f=100,i=12", b64(RGBA8_PNG)))
	eq_s(take(&t), "\x1b_Gi=12;OK\x1b\\", "an 8-bit RGBA PNG")
	img := vt.image_by_id(&t.gfx, 12)
	check(img != nil && img.w == 16 && img.h == 8, "16x8")
	if img != nil {
		eq_i(int(px_at(img, 0, 0)), int(0xFFFFFF00), "the opaque yellow corner")
		a := px_at(img, 10, 5) >> 24
		check(a >= 126 && a <= 129, "the half-transparent blue keeps alpha 128 (got %d)", a)
	}
}

@(private = "file")
test_kitty_files :: proc() {
	t: vt.Terminal
	vt.terminal_init(&t, 40, 10, 100)
	defer vt.terminal_destroy(&t)

	feed(&t, kitty("a=t,t=f,i=1,f=100", b64(transmute([]u8)string("/tmp/x.png"))))
	eq_s(take(&t), "\x1b_Gi=1;EBADF:file transfer is not allowed here\x1b\\", "with no loader, files are refused")

	t.gfx.load_file = kitty_read_file
	dir := os.get_env("TMPDIR", context.temp_allocator)
	if dir == "" {
		dir = "/tmp"
	}
	pid := linux.getpid()
	plain := fmt.tprintf("%s/term-selftest-%d.png", dir, pid)
	temp := fmt.tprintf("%s/term-selftest-%d-tty-graphics-protocol.png", dir, pid)
	_ = os.write_entire_file(plain, GRADIENT_PNG)
	_ = os.write_entire_file(temp, GRADIENT_PNG)
	defer os.remove(plain)
	defer os.remove(temp)

	feed(&t, kitty("a=t,t=f,i=2,f=100", b64(transmute([]u8)plain)))
	eq_s(take(&t), "\x1b_Gi=2;OK\x1b\\", "t=f reads a PNG from a file")
	img := vt.image_by_id(&t.gfx, 2)
	check(img != nil && px_at(img, 16, 16) & 0xFFFFFF == 0xFFFF00, "the same pixels as the stream")
	check(os.exists(plain), "and leaves the file alone")

	feed(&t, kitty("a=t,t=t,i=3,f=100", b64(transmute([]u8)temp)))
	eq_s(take(&t), "\x1b_Gi=3;OK\x1b\\", "t=t reads a temporary file")
	check(!os.exists(temp), "and deletes it, as the protocol says")

	feed(&t, kitty("a=t,t=t,i=4,f=100", b64(transmute([]u8)plain)))
	r := take(&t)
	check(strings.contains(r, "EPERM"), "t=t refuses a file not named as a temporary one: %q", r)
	check(os.exists(plain), "and does not delete it")

	feed(&t, kitty("a=t,t=f,i=5,f=100", b64(transmute([]u8)string("/proc/self/environ"))))
	r = take(&t)
	check(strings.contains(r, "EBADF") || strings.contains(r, "EPERM"), "nothing under /proc is read: %q", r)
	link := fmt.tprintf("%s/term-selftest-%d-link.png", dir, pid)
	os.remove(link)
	clink := strings.clone_to_cstring(link, context.temp_allocator)
	linux.symlink("/proc/self/status", clink)
	defer os.remove(link)
	feed(&t, kitty("a=t,t=f,i=6,f=100", b64(transmute([]u8)link)))
	r = take(&t)
	check(strings.contains(r, "EPERM"), "not even through a symlink: %q", r)
	feed(&t, kitty("a=t,t=f,i=7,f=100", b64(transmute([]u8)dir)))
	r = take(&t)
	check(strings.contains(r, "EBADF"), "a directory is not a regular file: %q", r)
	feed(&t, kitty("a=t,t=f,i=8,f=100", b64(transmute([]u8)string("relative.png"))))
	r = take(&t)
	check(strings.contains(r, "EINVAL"), "a relative path is refused: %q", r)
	fifo := fmt.tprintf("%s/term-selftest-%d.fifo", dir, pid)
	os.remove(fifo)
	cfifo := strings.clone_to_cstring(fifo, context.temp_allocator)
	linux.mknod(cfifo, linux.S_IFIFO | {.IRUSR, .IWUSR}, 0)
	defer os.remove(fifo)
	start := time.now()
	feed(&t, kitty("a=t,t=f,i=9,f=100", b64(transmute([]u8)fifo)))
	r = take(&t)
	check(strings.contains(r, "EBADF") && time.since(start) < time.Second, "a FIFO is refused without blocking: %q", r)

	// Offset and size select part of a file.
	raw := fmt.tprintf("%s/term-selftest-%d.rgb", dir, pid)
	data := make([]u8, 16 + 12, context.temp_allocator)
	for i in 16 ..< 28 {
		data[i] = 200
	}
	_ = os.write_entire_file(raw, data)
	defer os.remove(raw)
	feed(&t, kitty("a=t,t=f,i=10,f=24,s=2,v=2,O=16,S=12", b64(transmute([]u8)raw)))
	eq_s(take(&t), "\x1b_Gi=10;OK\x1b\\", "O= and S= pick the pixels out of a larger file")
	img = vt.image_by_id(&t.gfx, 10)
	check(img != nil && px_at(img, 1, 1) == 0xFFC8C8C8, "and they are the right pixels")
}

@(private = "file")
test_image_memory :: proc() {
	t: vt.Terminal
	vt.terminal_init(&t, 20, 4, 6)
	defer vt.terminal_destroy(&t)
	vt.terminal_set_cell_size(&t, 10, 20)
	eq_i(t.gfx.budget, 32 * 1024 * 1024, "the budget is 32 MiB a terminal")

	// Scroll-out: an image that leaves the far end of the scrollback goes.
	feed(&t, "\x1bPq#1;2;100;0;0!10~\x1b\\\r\n")
	eq_i(len(t.gfx.images), 1, "a Sixel image")
	for i in 0 ..< 5 {
		feed(&t, fmt.tprintf("line %d\r\n", i))
	}
	eq_i(len(t.gfx.images), 1, "still held while it is in the scrollback")
	for i in 0 ..< 20 {
		feed(&t, fmt.tprintf("more %d\r\n", i))
	}
	eq_i(len(t.gfx.images), 0, "evicted when it scrolls out of the history")
	eq_i(t.gfx.bytes, 0, "its pixels are released")
	eq_i(len(t.gfx.placements), 0, "and its placement")

	// The budget: the oldest unplaced image goes first, then the oldest.
	vt.terminal_reset(&t)
	t.gfx.budget = 3 * 100 * 100 * 4
	for i in 1 ..= 3 {
		feed(&t, kitty(fmt.tprintf("a=t,f=24,s=100,v=100,i=%d", i), solid_rgb(100, 100, u8(i), 0, 0)))
	}
	feed(&t, kitty("a=p,i=1,C=1"))
	eq_i(len(t.gfx.images), 3, "three images fill the budget")
	feed(&t, kitty("a=t,f=24,s=100,v=100,i=4", solid_rgb(100, 100, 4, 0, 0)))
	check(vt.image_by_id(&t.gfx, 2) == nil, "a fourth evicts the oldest unplaced one (2)")
	check(vt.image_by_id(&t.gfx, 1) != nil, "not the older one that is on screen (1)")
	check(t.gfx.bytes <= t.gfx.budget, "the pixels stay within the budget")
	eq_i(t.gfx.evicted, 1, "one eviction")
	feed(&t, kitty("a=t,f=24,s=200,v=200,i=5", solid_rgb(200, 200, 5, 0, 0)))
	r := take(&t)
	check(strings.contains(r, "i=5;EFBIG"), "an image larger than the whole budget is refused: %q", r)
	check(vt.image_by_id(&t.gfx, 1) != nil, "and evicts nothing on its way out")

	// A chunked transfer cannot park more than the budget either.
	vt.terminal_reset(&t)
	t.gfx.budget = 1000
	feed(&t, kitty("a=t,f=24,s=20,v=20,i=6,m=1", solid_rgb(20, 20, 1, 1, 1)))
	feed(&t, kitty("m=0", solid_rgb(20, 20, 1, 1, 1)))
	r = take(&t)
	check(strings.contains(r, "EFBIG"), "an over-budget chunked transfer is refused: %q", r)
	eq_i(len(t.gfx.kitty.data), 0, "and nothing of it is kept")

	// A decompression bomb stops at the budget.
	vt.terminal_reset(&t)
	t.gfx.budget = 32 * 1024 * 1024
	start := time.now()
	feed_b(&t, ZLIB_BOMB)
	r = take(&t)
	check(strings.contains(r, "i=77;EINVAL"), "64 MiB of zeros in 65 KB of zlib is refused: %q", r)
	check(time.since(start) < 5 * time.Second, "promptly")
	eq_i(len(t.gfx.images), 0, "and nothing is held")

	// Sixel stops growing at the budget instead of allocating past it.
	vt.terminal_reset(&t)
	t.gfx.budget = 64 * 64 * 4
	feed(&t, "\x1bPq#1;2;100;0;0!200~\x1b\\")
	img := len(t.gfx.images) > 0 ? t.gfx.images[0] : nil
	check(img == nil || img.w * img.h * 4 <= t.gfx.budget, "an oversized Sixel image is clipped to the budget")
	feed(&t, "\x1bPq\"1;1;20000;20000#1~\x1b\\")
	check(t.gfx.bytes <= t.gfx.budget, "a 20000x20000 raster declaration allocates nothing past it")
	t.gfx.budget = 32 * 1024 * 1024

	// Reflow keeps images with their rows.
	vt.terminal_reset(&t)
	feed(&t, "abc\r\n\x1bPq#1;2;100;0;0!10~\x1b\\\r\nxyz")
	vt.terminal_resize(&t, 10, 4)
	eq_i(len(t.gfx.images), 1, "a narrower window keeps the image")
	found := -1
	s := vt.screen(&t)
	for r, i in s.lines {
		if len(r.frags) > 0 {
			found = i
		}
	}
	check(found >= 0 && found + 1 < len(s.lines) && line(&t, found + 1) == "xyz", "on the row above xyz, where it was")
	vt.terminal_resize(&t, 30, 6)
	eq_i(len(t.gfx.placements), 1, "and a wider one")
}

// The renderer draws images into the pixel cache, under or over the text.
@(private = "file")
test_image_render :: proc() {
	fonts: p.Fonts
	p.fonts_init(&fonts)
	defer p.fonts_destroy(&fonts)
	r := Grid_Renderer {
		fonts = &fonts,
	}
	renderer_metrics(&r, 14, 1)
	renderer_resize(&r, 10, 3)
	defer renderer_destroy(&r)

	t: vt.Terminal
	vt.terminal_init(&t, 10, 3, 10)
	defer vt.terminal_destroy(&t)
	vt.terminal_set_cell_size(&t, r.cell_w, r.cell_h)

	// An opaque green square, two cells, above the text (z=0) on row 1.
	w := r.cell_w * 2
	h := r.cell_h
	feed(&t, kitty(fmt.tprintf("a=T,f=24,s=%d,v=%d,i=1", w, h), solid_rgb(w, h, 0, 255, 0)))
	feed(&t, "\r\x1b[2;1H")
	// The same, below the text (z=-1), with text printed into it.
	feed(&t, kitty(fmt.tprintf("a=T,f=24,s=%d,v=%d,i=2,z=-1", w, h), solid_rgb(w, h, 0, 0, 255)))
	feed(&t, "\r\x1b[2;1H@@")
	renderer_draw(&r, &t, {}, false, true)

	at :: proc(r: ^Grid_Renderer, x, y: int) -> u32 {
		return r.px[y * r.w + x]
	}
	eq_i(int(at(&r, r.cell_w / 2, r.cell_h / 2)), int(0xFF00FF00), "z=0 draws the image over the cell")
	ink := 0
	blue := 0
	for y in r.cell_h ..< r.cell_h * 2 {
		for x in 0 ..< r.cell_w {
			v := at(&r, x, y)
			if v == 0xFF0000FF {
				blue += 1
			} else {
				ink += 1
			}
		}
	}
	check(blue > 0 && ink > 0, "z=-1 is under the text: blue around the glyph, the glyph on top (%d blue, %d ink)", blue, ink)
	check(at(&r, r.cell_w * 3, r.cell_h / 2) != 0xFF00FF00, "nothing past the image's two cells")

	// Font size changes scale it with the cells.
	r2 := Grid_Renderer {
		fonts = &fonts,
	}
	renderer_metrics(&r2, 28, 1)
	renderer_resize(&r2, 10, 3)
	defer renderer_destroy(&r2)
	renderer_draw(&r2, &t, {}, false, true)
	eq_i(int(r2.px[(r2.cell_h / 2) * r2.w + r2.cell_w * 2 - 2]), int(0xFF00FF00), "at twice the font it still covers two cells")
}

