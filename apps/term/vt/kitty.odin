package vt

import "core:bytes"
import "core:compress/zlib"
import "core:fmt"
import "core:image"
import "core:image/png"
import "core:strings"

// ---------------------------------------------------------------------------
// The Kitty graphics protocol.
//
// `ESC _ G <key>=<value>,... ; <base64 payload> ESC \`. What is here:
//
//   a=t transmit, a=T transmit and display, a=p place, a=d delete, a=q query.
//   f=24 RGB, f=32 RGBA, f=100 PNG (8- and 16-bit, any colour type).
//   t=d direct, t=f file, t=t temporary file, t=s shared memory; o=z zlib.
//   Chunked transfers (m=1 ... m=0), with every chunk decoded as it arrives.
//   Placement: x,y,w,h source rectangle, c,r size in cells, X,Y offset in the
//   first cell, C=1 to leave the cursor where it was, z-index, and p= ids so a
//   placement can be replaced or deleted on its own.
//   Delete: a, i, n, c, p, q, x, y, z and r, in both cases: lower case
//   removes placements, upper case also frees the images they leave unused.
//   Replies, honouring q=1 and q=2, in the protocol's own words (ENOENT,
//   EINVAL, ENODATA, EBADPNG, EFBIG ...), and only when an id was given.
//
// What is not: animation (a=f, a=a, a=c), Unicode placeholders (U=1) and
// relative placements (P=, Q=). They answer ENOTSUP rather than doing
// something half right. The oracle for all of this is kitty 0.32 itself,
// driven by the escape streams `kitten icat` writes; see apps/term/testdata.
//
// File transfers are the part with teeth: the terminal reads a path the
// program names. The engine never opens a file itself -- it asks
// Graphics.load_file, and apps/term's kitty_read_file decides (regular files
// only, never under /proc, /sys or /dev, size-capped, and a temporary file is
// deleted only if it is in a temporary directory and says it is one).
// ---------------------------------------------------------------------------

Kitty_Cmd :: struct {
	action:         u8, // a
	medium:         u8, // t
	compression:    u8, // o
	delete_what:    u8, // d
	format:         int, // f
	width, height:  int, // s, v
	size, offset:   int, // S, O
	id, number:     u32, // i, I
	placement:      u32, // p
	more:           int, // m
	quiet:          int, // q
	sx, sy, sw, sh: int, // x, y, w, h
	ox, oy:         int, // X, Y
	cols, rows:     int, // c, r
	no_move:        int, // C
	z:              i32, // z
	unicode:        int, // U
	parent:         u32, // P
}

Kitty_Load :: struct {
	active:  bool,
	cmd:     Kitty_Cmd,
	data:    [dynamic]u8,
	too_big: bool,
	bad:     bool,
}

kitty_load_reset :: proc(l: ^Kitty_Load) {
	delete(l.data)
	l^ = {}
}

// kitty_parse_control reads the key=value list before the payload.
kitty_parse_control :: proc(s: string) -> (c: Kitty_Cmd, ok: bool) {
	c.action = 't'
	c.medium = 'd'
	c.format = 32
	c.delete_what = 'a'
	rest := s
	for len(rest) > 0 {
		item := rest
		if i := strings.index_byte(rest, ','); i >= 0 {
			item = rest[:i]
			rest = rest[i + 1:]
		} else {
			rest = ""
		}
		if len(item) < 3 || item[1] != '=' {
			if len(item) == 0 {
				continue
			}
			return c, false
		}
		k := item[0]
		v := item[2:]
		num, nok := parse_int_signed(v)
		ch := v[0]
		switch k {
		case 'a': c.action = ch
		case 't': c.medium = ch
		case 'o': c.compression = ch
		case 'd': c.delete_what = ch
		case 'f': c.format = num
		case 's': c.width = num
		case 'v': c.height = num
		case 'S': c.size = num
		case 'O': c.offset = num
		case 'i': c.id = u32(max(num, 0))
		case 'I': c.number = u32(max(num, 0))
		case 'p': c.placement = u32(max(num, 0))
		case 'm': c.more = num
		case 'q': c.quiet = num
		case 'x': c.sx = num
		case 'y': c.sy = num
		case 'w': c.sw = num
		case 'h': c.sh = num
		case 'X': c.ox = num
		case 'Y': c.oy = num
		case 'c': c.cols = num
		case 'r': c.rows = num
		case 'C': c.no_move = num
		case 'z': c.z = i32(num)
		case 'U': c.unicode = num
		case 'P': c.parent = u32(max(num, 0))
		case 'Q', 'H', 'V':
		case:
		}
		if !nok && k != 'a' && k != 't' && k != 'o' && k != 'd' {
			return c, false
		}
	}
	return c, true
}

@(private = "file")
parse_int_signed :: proc(s: string) -> (int, bool) {
	if len(s) == 0 {
		return 0, false
	}
	neg := false
	i := 0
	if s[0] == '-' {
		neg = true
		i = 1
	}
	if i >= len(s) {
		return 0, false
	}
	v := 0
	for ; i < len(s); i += 1 {
		d := s[i]
		if d < '0' || d > '9' {
			return 0, false
		}
		v = min(v * 10 + int(d - '0'), 1 << 31)
	}
	return neg ? -v : v, true
}

// ---------------------------------------------------------------------------

@(private = "file")
kitty_reply :: proc(t: ^Terminal, c: Kitty_Cmd, msg: string) {
	if c.id == 0 && c.number == 0 {
		return
	}
	is_ok := msg == "OK"
	if c.quiet >= 2 || (c.quiet == 1 && is_ok) {
		return
	}
	reply(t, "\x1b_G")
	if c.id != 0 {
		reply(t, "i=")
		reply_u32(t, c.id)
	}
	if c.number != 0 {
		reply(t, c.id != 0 ? ",I=" : "I=")
		reply_u32(t, c.number)
	}
	if c.placement != 0 {
		reply(t, ",p=")
		reply_u32(t, c.placement)
	}
	reply(t, ";")
	reply(t, msg)
	reply(t, "\x1b\\")
}

// kitty_command runs one APC G string (without the G).
kitty_command :: proc(t: ^Terminal, body: []u8) {
	s := string(body)
	ctrl := s
	payload := ""
	if i := strings.index_byte(s, ';'); i >= 0 {
		ctrl = s[:i]
		payload = s[i + 1:]
	}
	c, ok := kitty_parse_control(ctrl)
	l := &t.gfx.kitty

	// A continuation chunk belongs to the transfer in progress whatever
	// keys it repeats; only `m` (and `q`) mean anything in it.
	if l.active {
		kitty_take_chunk(t, payload)
		if ok && c.more == 1 {
			return
		}
		cmd := l.cmd
		data := l.data
		too_big, bad := l.too_big, l.bad
		l.data = nil
		l.active = false
		defer delete(data)
		if too_big {
			kitty_reply(t, cmd, "EFBIG:the transmission is larger than the image budget")
			return
		}
		if bad {
			kitty_reply(t, cmd, "EINVAL:the payload is not valid base64")
			return
		}
		kitty_execute(t, cmd, data[:])
		return
	}
	if !ok {
		kitty_reply(t, c, "EINVAL:malformed control data")
		return
	}

	switch c.action {
	case 't', 'T', 'q':
		if c.more == 1 {
			l.active = true
			l.cmd = c
			l.data = make([dynamic]u8)
			kitty_take_chunk(t, payload)
			return
		}
		data, dok := base64_decode(payload)
		defer delete(data)
		if !dok {
			kitty_reply(t, c, "EINVAL:the payload is not valid base64")
			return
		}
		kitty_execute(t, c, data)
	case 'p':
		kitty_place(t, c)
	case 'd':
		kitty_delete(t, c)
	case:
		kitty_reply(t, c, "ENOTSUP:animation and composition are not supported")
	}
}

@(private = "file")
kitty_take_chunk :: proc(t: ^Terminal, payload: string) {
	l := &t.gfx.kitty
	if l.too_big || l.bad {
		return
	}
	// Each chunk is decoded on its own, as the protocol requires chunks to
	// be whole base64 groups; the base64 text is never kept.
	data, ok := base64_decode(payload)
	defer delete(data)
	if !ok {
		l.bad = true
		return
	}
	if len(l.data) + len(data) > t.gfx.budget {
		l.too_big = true
		delete(l.data)
		l.data = make([dynamic]u8)
		return
	}
	append(&l.data, ..data)
}

// kitty_execute handles a complete transmission (or query).
@(private = "file")
kitty_execute :: proc(t: ^Terminal, c_in: Kitty_Cmd, payload: []u8) {
	c := c_in
	g := &t.gfx
	if c.unicode != 0 || c.parent != 0 {
		kitty_reply(t, c, "ENOTSUP:unicode placeholders and relative placements are not supported")
		return
	}

	// 1. The bytes, from wherever the medium says.
	raw := payload
	owned: []u8
	defer delete(owned)
	switch c.medium {
	case 'd':
	case 'f', 't', 's':
		if g.load_file == nil {
			kitty_reply(t, c, "EBADF:file transfer is not allowed here")
			return
		}
		data, err := g.load_file(string(payload), c.medium, c.offset, c.size, g.budget)
		if err != "" {
			kitty_reply(t, c, err)
			return
		}
		owned = data
		raw = data
	case:
		kitty_reply(t, c, "EINVAL:unknown transmission medium")
		return
	}

	// 2. Decompress, under an allocator that will not go past the budget.
	inflated: bytes.Buffer
	defer bytes.buffer_destroy(&inflated)
	if c.compression == 'z' {
		cap := Capped{parent = context.allocator, limit = g.budget + 1024}
		ca := capped_allocator(&cap)
		inflated.buf.allocator = ca
		expected := -1
		if c.format != 100 && c.width > 0 && c.height > 0 {
			expected = c.width * c.height * (c.format == 24 ? 3 : 4)
		}
		{
			context.allocator = ca
			if zlib.inflate(raw, &inflated, false, expected) != nil {
				kitty_reply(t, c, "EINVAL:the zlib data did not decompress")
				return
			}
		}
		raw = inflated.buf[:]
	} else if c.compression != 0 {
		kitty_reply(t, c, "EINVAL:unknown compression")
		return
	}

	// 3. Decode into pixels.
	w, h: int
	px: []u32
	switch c.format {
	case 24, 32:
		bpp := c.format / 8
		w, h = c.width, c.height
		if w <= 0 || h <= 0 {
			kitty_reply(t, c, "EINVAL:the width and height must be given for raw pixels")
			return
		}
		if !image_fits(g, w, h) {
			kitty_reply(t, c, "EFBIG:the image is larger than the image budget")
			return
		}
		need := w * h * bpp
		if len(raw) < need {
			kitty_reply(t, c, fmt.tprintf("ENODATA:Insufficient image data: %d < %d", len(raw), need))
			return
		}
		px = make([]u32, w * h)
		for i in 0 ..< w * h {
			b := raw[i * bpp:]
			a := bpp == 4 ? u32(b[3]) : 255
			px[i] = a << 24 | u32(b[0]) << 16 | u32(b[1]) << 8 | u32(b[2])
		}
	case 100:
		pw, ph, perr := png_decode(raw, g.budget)
		if perr != "" {
			kitty_reply(t, c, perr)
			return
		}
		px, w, h = pw, ph.x, ph.y
	case:
		kitty_reply(t, c, "EINVAL:unknown format")
		return
	}

	if c.action == 'q' {
		delete(px)
		kitty_reply(t, c, "OK")
		return
	}

	// An image transmitted with nothing to call it by and nowhere to show
	// it could never be used; it is not kept.
	if c.action == 't' && c.id == 0 && c.number == 0 {
		delete(px)
		return
	}

	// 4. Keep it. An image sent under an id that is already taken replaces
	// the old one, placements and all.
	if c.id == 0 && c.number != 0 {
		c.id = kitty_free_id(g)
	}
	if old := image_by_id(g, c.id); old != nil {
		image_delete(t, old)
	}
	img := image_add(t, px, w, h, c.id == 0)
	if img == nil {
		kitty_reply(t, c, "EFBIG:the image is larger than the image budget")
		return
	}
	img.id = c.id
	img.number = c.number

	if c.action == 'T' {
		if msg := kitty_put(t, c, img); msg != "OK" {
			kitty_reply(t, c, msg)
			return
		}
	}
	kitty_reply(t, c, "OK")
}

@(private = "file")
kitty_free_id :: proc(g: ^Graphics) -> u32 {
	for {
		g.next_id += 1
		if g.next_id == 0 || g.next_id >= 1 << 31 {
			g.next_id = 1
		}
		if image_by_id(g, g.next_id) == nil {
			return g.next_id
		}
	}
}

// png_decode turns a PNG into straight-alpha ARGB. The header is checked
// against the budget before anything is inflated.
png_decode :: proc(data: []u8, budget: int) -> (px: []u32, size: [2]int, err: string) {
	if len(data) < 24 || string(data[1:4]) != "PNG" || string(data[12:16]) != "IHDR" {
		return nil, {}, "EBADPNG:not a PNG"
	}
	be32 :: proc(b: []u8) -> int {
		return int(b[0]) << 24 | int(b[1]) << 16 | int(b[2]) << 8 | int(b[3])
	}
	w := be32(data[16:])
	h := be32(data[20:])
	if w <= 0 || h <= 0 || w > MAX_IMAGE_SIDE || h > MAX_IMAGE_SIDE || w * h * 4 > budget {
		return nil, {}, "EFBIG:the image is larger than the image budget"
	}
	cap := Capped{parent = context.allocator, limit = budget * 2 + 4096}
	ca := capped_allocator(&cap)
	img, perr := png.load_from_bytes(data, {.alpha_add_if_missing}, ca)
	if perr != nil || img == nil {
		if img != nil {
			png.destroy(img)
		}
		return nil, {}, "EBADPNG:the PNG did not decode"
	}
	defer png.destroy(img)
	if img.width != w || img.height != h || img.channels < 3 {
		return nil, {}, "EBADPNG:the PNG did not decode"
	}
	px = make([]u32, w * h)
	ch := img.channels
	buf := img.pixels.buf[:]
	if img.depth == 16 {
		// Sixteen bits a channel, stored as native-endian u16s; the top
		// byte is the eight-bit value.
		need := w * h * ch * 2
		if len(buf) < need {
			delete(px)
			return nil, {}, "EBADPNG:the PNG did not decode"
		}
		v := ([^]u16)(raw_data(buf))
		for i in 0 ..< w * h {
			o := i * ch
			a := ch == 4 ? u32(v[o + 3] >> 8) : 255
			px[i] = a << 24 | u32(v[o] >> 8) << 16 | u32(v[o + 1] >> 8) << 8 | u32(v[o + 2] >> 8)
		}
	} else {
		need := w * h * ch
		if img.depth != 8 || len(buf) < need {
			delete(px)
			return nil, {}, "EBADPNG:the PNG did not decode"
		}
		for i in 0 ..< w * h {
			o := i * ch
			a := ch == 4 ? u32(buf[o + 3]) : 255
			px[i] = a << 24 | u32(buf[o]) << 16 | u32(buf[o + 1]) << 8 | u32(buf[o + 2])
		}
	}
	_ = image.Image{}
	return px, {w, h}, ""
}

// ---------------------------------------------------------------------------
// Placing
// ---------------------------------------------------------------------------

@(private = "file")
kitty_place :: proc(t: ^Terminal, c: Kitty_Cmd) {
	if c.unicode != 0 || c.parent != 0 {
		kitty_reply(t, c, "ENOTSUP:unicode placeholders and relative placements are not supported")
		return
	}
	img: ^Image
	if c.id != 0 {
		img = image_by_id(&t.gfx, c.id)
	} else if c.number != 0 {
		img = image_by_number(&t.gfx, c.number)
	}
	if img == nil {
		kitty_reply(t, c, "ENOENT:no such image")
		return
	}
	c := c
	if c.id == 0 {
		c.id = img.id
	}
	kitty_reply(t, c, kitty_put(t, c, img))
}

// kitty_put makes a placement of an image at the cursor.
@(private = "file")
kitty_put :: proc(t: ^Terminal, c: Kitty_Cmd, img: ^Image) -> string {
	g := &t.gfx
	if c.placement != 0 {
		// Placing under a placement id that is in use moves it.
		doomed := false
		for pl in g.placements {
			if pl.img == img && pl.id == c.placement {
				pl.doomed = true
				doomed = true
			}
		}
		if doomed {
			purge_doomed(t)
		}
	}
	pl := placement_new(g, img)
	pl.id = c.placement
	pl.z = c.z
	sx := clamp(c.sx, 0, img.w)
	sy := clamp(c.sy, 0, img.h)
	sw := c.sw > 0 ? min(c.sw, img.w - sx) : img.w - sx
	sh := c.sh > 0 ? min(c.sh, img.h - sy) : img.h - sy
	if sw <= 0 || sh <= 0 {
		placement_drop_unattached(pl)
		return "EINVAL:the source rectangle is empty"
	}
	pl.sx, pl.sy, pl.sw, pl.sh = sx, sy, sw, sh
	pl.ox = clamp(c.ox, 0, pl.cw - 1)
	pl.oy = clamp(c.oy, 0, pl.ch - 1)
	// c and r scale: both given, the image fills that many cells exactly;
	// one given, the other follows the aspect ratio.
	switch {
	case c.cols > 0 && c.rows > 0:
		pl.dw = c.cols * pl.cw - pl.ox
		pl.dh = c.rows * pl.ch - pl.oy
	case c.cols > 0:
		pl.dw = c.cols * pl.cw - pl.ox
		pl.dh = max(1, sh * pl.dw / sw)
	case c.rows > 0:
		pl.dh = c.rows * pl.ch - pl.oy
		pl.dw = max(1, sw * pl.dh / sh)
	case:
		pl.dw, pl.dh = sw, sh
	}
	pl.dw = max(pl.dw, 1)
	pl.dh = max(pl.dh, 1)
	placement_layout(pl)
	place_at_cursor(t, pl, false, false, c.no_move == 1)
	return "OK"
}

// place_at_cursor attaches a placement to the rows it covers, starting at the
// cursor.
//
// Moving the cursor follows the oracle for each protocol. Sixel (foot): the
// rows below are reached by line feeds, so an image at the bottom scrolls the
// screen, and the cursor ends on the image's last row in its first column.
// Kitty (kitty): the same line feeds, and the cursor ends on the last row one
// column past the image -- or, with C=1, nothing moves or scrolls and rows
// past the bottom are cut off. Sixel display mode (DECSDM, mode 80) puts the
// image at the top left and leaves the cursor alone.
place_at_cursor :: proc(t: ^Terminal, pl: ^Placement, sixel, display_mode: bool, no_move := false) {
	s := screen(t)
	x0 := t.cursor.x
	if t.cursor.pending {
		x0 = t.cols - 1
	}
	if display_mode {
		for k in 0 ..< min(pl.rows, t.rows) {
			attach_one(t, &s.lines[k], pl, 0, k)
		}
	} else if no_move {
		for k in 0 ..< pl.rows {
			y := t.cursor.y + k
			if y >= t.rows {
				break
			}
			attach_one(t, &s.lines[y], pl, x0, k)
		}
	} else {
		for k in 0 ..< pl.rows {
			attach_one(t, &s.lines[t.cursor.y], pl, x0, k)
			if k < pl.rows - 1 {
				cursor_down_scroll(t)
			}
		}
		t.cursor.pending = false
		if sixel {
			t.cursor.x = x0
		} else {
			t.cursor.x = min(x0 + pl.cols, t.cols - 1)
		}
	}
	placement_drop_unattached(pl)
	screen_mark_all_dirty(s)
}

@(private = "file")
attach_one :: proc(t: ^Terminal, r: ^Row, pl: ^Placement, x0, k: int) {
	if pl.sixel {
		// Sixel replaces what was under it: the text, and the part of any
		// older Sixel image it covers.
		x1 := min(x0 + pl.cols, len(r.cells))
		row_cut(r, x0, x1)
		b := blank_cell(Pen{})
		for x in x0 ..< x1 {
			r.cells[x] = b
		}
	}
	row_attach(r, pl, x0, k)
}

// ---------------------------------------------------------------------------
// Deleting
// ---------------------------------------------------------------------------

@(private = "file")
kitty_delete :: proc(t: ^Terminal, c: Kitty_Cmd) {
	g := &t.gfx
	what := c.delete_what
	free_images := what >= 'A' && what <= 'Z'
	lower := free_images ? what + 32 : what

	// Cell-based targets look at the active screen, the way the protocol
	// defines them: a placement matches if any of its cells does.
	cell_match :: proc(t: ^Terminal, pred: proc(t: ^Terminal, c: Kitty_Cmd, pl: ^Placement, x, y: int) -> bool, c: Kitty_Cmd) {
		s := screen(t)
		for r, y in s.lines {
			for f in r.frags {
				for x in int(f.col + f.from) ..< int(f.col + f.to) {
					if pred(t, c, f.pl, x, y) {
						f.pl.doomed = true
						break
					}
				}
			}
		}
	}

	switch lower {
	case 'a':
		vis := make([dynamic]^Placement, context.temp_allocator)
		placements_visible(t, &vis)
		for pl in vis {
			pl.doomed = true
		}
	case 'i', 'n':
		img: ^Image
		if lower == 'i' {
			img = image_by_id(g, c.id)
		} else {
			img = image_by_number(g, c.number)
		}
		if img == nil {
			return
		}
		for pl in g.placements {
			if pl.img == img && (c.placement == 0 || pl.id == c.placement) {
				pl.doomed = true
			}
		}
		if free_images && c.placement == 0 {
			image_delete(t, img)
			return
		}
	case 'c':
		cell_match(t, proc(t: ^Terminal, c: Kitty_Cmd, pl: ^Placement, x, y: int) -> bool {
			return x == t.cursor.x && y == t.cursor.y
		}, c)
	case 'p':
		cell_match(t, proc(t: ^Terminal, c: Kitty_Cmd, pl: ^Placement, x, y: int) -> bool {
			return x == c.sx - 1 && y == c.sy - 1
		}, c)
	case 'q':
		cell_match(t, proc(t: ^Terminal, c: Kitty_Cmd, pl: ^Placement, x, y: int) -> bool {
			return x == c.sx - 1 && y == c.sy - 1 && pl.z == c.z
		}, c)
	case 'x':
		cell_match(t, proc(t: ^Terminal, c: Kitty_Cmd, pl: ^Placement, x, y: int) -> bool {
			return x == c.sx - 1
		}, c)
	case 'y':
		cell_match(t, proc(t: ^Terminal, c: Kitty_Cmd, pl: ^Placement, x, y: int) -> bool {
			return y == c.sy - 1
		}, c)
	case 'z':
		for pl in g.placements {
			if pl.z == c.z && !pl.sixel {
				pl.doomed = true
			}
		}
	case 'r':
		for pl in g.placements {
			if pl.img != nil && int(pl.img.id) >= c.sx && int(pl.img.id) <= c.sy && pl.img.id != 0 {
				pl.doomed = true
			}
		}
	case:
		return
	}

	// Sixel images are not the Kitty protocol's to delete.
	for pl in g.placements {
		if pl.sixel {
			pl.doomed = false
		}
	}

	// Remember which images lost placements, so upper case can free them.
	touched := make([dynamic]^Image, context.temp_allocator)
	for pl in g.placements {
		if pl.doomed && !pl.img.anonymous {
			append(&touched, pl.img)
		}
	}
	purge_doomed(t)
	if free_images {
		for img in touched {
			still := false
			for x in g.images {
				if x == img {
					still = true
					break
				}
			}
			if still && img.placements == 0 {
				image_delete(t, img)
			}
		}
	}
}
