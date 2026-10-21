package vt

import "base:runtime"

// ---------------------------------------------------------------------------
// Images on the grid: what Sixel and the Kitty graphics protocol share.
//
// An image is pixels. A placement is one appearance of an image on the grid:
// which part of it, how large, at which z. A placement is not stored at a
// screen position. It is cut into one fragment per text row it covers, and
// each fragment is attached to that row -- the same Row that holds the cells.
//
// That one decision is what makes images behave like text without any code
// of their own. A row that scrolls carries its fragments with it; a row that
// a scroll region or an IL/DL moves moves them too; a row pushed into the
// scrollback takes them there, and a row trimmed off the far end of the
// scrollback releases them, which is how an image is evicted on scroll-out.
// The alternative -- placements anchored at absolute line numbers -- gets the
// scrollback right and every other kind of scroll wrong.
//
// Fragments are reference counted: a placement goes when its last fragment
// does, and an anonymous image (every Sixel image, and a Kitty image sent
// without an id) goes with its last placement. A Kitty image with an id
// outlives its placements, as the protocol says, so it can be placed again;
// those are the first to go when the budget is exceeded.
//
// The budget. Every terminal -- every pane -- holds at most
// GRAPHICS_BUDGET bytes of decoded pixels (32 MiB: four 1920x1080 frames).
// A new image that does not fit evicts the oldest images, unplaced ones
// first; an image that would not fit in an empty budget is refused outright.
// The compressed or base64 bytes of a transmission still in flight count
// against the same number, so a client cannot park unbounded data in an
// unfinished chunked transfer either.
// ---------------------------------------------------------------------------

GRAPHICS_BUDGET :: 32 * 1024 * 1024
// No side of an image may exceed this, whatever the budget says. It keeps a
// width*height product from overflowing before it is compared to anything.
MAX_IMAGE_SIDE :: 10_000

Image :: struct {
	id:         u32, // Kitty i=, or 0
	number:     u32, // Kitty I=, or 0
	w, h:       int,
	px:         []u32, // 0xAARRGGBB, straight alpha
	placements: int,
	seq:        u64,
	// Goes away with its last placement: every Sixel image, and a Kitty
	// image transmitted without an id, which nothing can name again.
	anonymous:  bool,
}

Placement :: struct {
	gfx:            ^Graphics,
	img:            ^Image,
	id:             u32, // Kitty p=, or 0
	refs:           int, // fragments that point here
	// The part of the image shown, in image pixels.
	sx, sy, sw, sh: int,
	// Offset of the image inside its first cell, in pixels (Kitty X=, Y=).
	ox, oy:         int,
	// The size it is shown at, in pixels at the cell size it was placed at.
	// The renderer scales by the ratio of the current cell size to cw/ch, so
	// an image grows and shrinks with the font the way the text does.
	dw, dh:         int,
	cw, ch:         int,
	cols, rows:     int,
	z:              i32,
	// Sixel images are cut by text and erasure printed over them; Kitty
	// images are not.
	sixel:          bool,
	doomed:         bool,
}

// Frag is one text row's share of a placement. `row` is which cell row of
// the placement it shows; `from` and `to` are the placement-relative columns
// still visible, which is how printing over part of a Sixel image cuts it.
Frag :: struct {
	pl:       ^Placement,
	col:      i32,
	row:      i32,
	from, to: i32,
}

Graphics :: struct {
	images:     [dynamic]^Image,
	placements: [dynamic]^Placement,
	bytes:      int, // decoded pixels held, in bytes
	budget:     int,
	seq:        u64,
	next_id:    u32,
	// The cell size images are measured against, in pixels. The front end
	// sets it from the font; headless, a 10x20 cell is assumed.
	cell_w:     int,
	cell_h:     int,
	// Counters the self-test reads.
	evicted:    int,
	refused:    int,
	// Set whenever an image appears, moves or goes, so the front end knows
	// to repaint rows it would otherwise think were clean.
	changed:    bool,
	kitty:      Kitty_Load,
	// How a Kitty file transfer reads a file. Left nil, file transfers are
	// refused: the engine does not touch the filesystem on its own, and the
	// front end decides what it may read (see kitty_read_file in apps/term).
	load_file:  proc(path: string, medium: u8, offset, size, limit: int) -> (data: []u8, err: string),
}

graphics_init :: proc(g: ^Graphics) {
	g.images = make([dynamic]^Image)
	g.placements = make([dynamic]^Placement)
	g.budget = GRAPHICS_BUDGET
	g.cell_w = 10
	g.cell_h = 20
}

graphics_destroy :: proc(g: ^Graphics) {
	for img in g.images {
		delete(img.px)
		free(img)
	}
	for pl in g.placements {
		free(pl)
	}
	delete(g.images)
	delete(g.placements)
	kitty_load_reset(&g.kitty)
	g.bytes = 0
}

// terminal_set_cell_size tells the engine how large a cell is in pixels,
// which is what an image's size in cells is worked out from and what CSI 14 t
// and 16 t report.
terminal_set_cell_size :: proc(t: ^Terminal, w, h: int) {
	if w > 0 && h > 0 {
		t.gfx.cell_w = w
		t.gfx.cell_h = h
	}
}

// graphics_take_changed reports, and clears, whether images moved since the
// last call.
graphics_take_changed :: proc(t: ^Terminal) -> bool {
	c := t.gfx.changed
	t.gfx.changed = false
	return c
}

// ---------------------------------------------------------------------------
// Images
// ---------------------------------------------------------------------------

// image_fits reports whether an image of this size could ever be held.
image_fits :: proc(g: ^Graphics, w, h: int) -> bool {
	if w <= 0 || h <= 0 || w > MAX_IMAGE_SIDE || h > MAX_IMAGE_SIDE {
		return false
	}
	return w * h * 4 <= g.budget
}

// image_add takes ownership of `px` and makes room for it in the budget.
// It returns nil, and frees the pixels, when the image can never fit.
image_add :: proc(t: ^Terminal, px: []u32, w, h: int, anonymous: bool) -> ^Image {
	g := &t.gfx
	if !image_fits(g, w, h) || len(px) != w * h {
		delete(px)
		g.refused += 1
		return nil
	}
	need := w * h * 4
	for g.bytes + need > g.budget && len(g.images) > 0 {
		before := g.bytes
		image_evict(t, pick_victim(g))
		if g.bytes == before {
			// Nothing came free. That would be a bookkeeping bug, but a
			// terminal that spins forever on one is worse than one that
			// goes over its budget once.
			break
		}
	}
	img := new(Image)
	img^ = Image {
		w         = w,
		h         = h,
		px        = px,
		anonymous = anonymous,
	}
	g.seq += 1
	img.seq = g.seq
	append(&g.images, img)
	g.bytes += need
	return img
}

// pick_victim chooses what goes when the budget is full: the oldest image
// nothing shows, and failing that the oldest image.
@(private = "file")
pick_victim :: proc(g: ^Graphics) -> ^Image {
	best: ^Image
	for img in g.images {
		if img.placements == 0 && (best == nil || img.seq < best.seq) {
			best = img
		}
	}
	if best != nil {
		return best
	}
	for img in g.images {
		if best == nil || img.seq < best.seq {
			best = img
		}
	}
	return best
}

// image_free releases an image's pixels. Its placements must already be gone.
@(private = "file")
image_free :: proc(g: ^Graphics, img: ^Image) {
	for x, i in g.images {
		if x == img {
			unordered_remove(&g.images, i)
			break
		}
	}
	g.bytes -= img.w * img.h * 4
	delete(img.px)
	free(img)
	g.changed = true
}

// image_evict removes an image and every placement of it, wherever on the
// screens or in the scrollback those are.
image_evict :: proc(t: ^Terminal, img: ^Image) {
	if img == nil {
		return
	}
	t.gfx.evicted += 1
	image_delete(t, img)
}

image_delete :: proc(t: ^Terminal, img: ^Image) {
	if img.placements == 0 {
		image_free(&t.gfx, img)
		return
	}
	// Doom every placement and let the last one take the image with it.
	img.anonymous = true
	for pl in t.gfx.placements {
		if pl.img == img {
			pl.doomed = true
		}
	}
	purge_doomed(t)
}

image_by_id :: proc(g: ^Graphics, id: u32) -> ^Image {
	if id == 0 {
		return nil
	}
	for img in g.images {
		if img.id == id {
			return img
		}
	}
	return nil
}

// image_by_number finds the newest image with a Kitty image number.
image_by_number :: proc(g: ^Graphics, n: u32) -> ^Image {
	best: ^Image
	for img in g.images {
		if img.number == n && n != 0 && (best == nil || img.seq > best.seq) {
			best = img
		}
	}
	return best
}

// ---------------------------------------------------------------------------
// Placements and fragments
// ---------------------------------------------------------------------------

placement_new :: proc(g: ^Graphics, img: ^Image) -> ^Placement {
	pl := new(Placement)
	pl.gfx = g
	pl.img = img
	pl.sw, pl.sh = img.w, img.h
	pl.dw, pl.dh = img.w, img.h
	pl.cw, pl.ch = g.cell_w, g.cell_h
	img.placements += 1
	append(&g.placements, pl)
	return pl
}

// placement_layout works out how many cells a placement covers.
placement_layout :: proc(pl: ^Placement) {
	pl.cols = max(1, (pl.ox + pl.dw + pl.cw - 1) / pl.cw)
	pl.rows = max(1, (pl.oy + pl.dh + pl.ch - 1) / pl.ch)
}

@(private = "file")
placement_unref :: proc(pl: ^Placement) {
	pl.refs -= 1
	if pl.refs > 0 {
		return
	}
	g := pl.gfx
	for x, i in g.placements {
		if x == pl {
			unordered_remove(&g.placements, i)
			break
		}
	}
	img := pl.img
	free(pl)
	g.changed = true
	if img != nil {
		img.placements -= 1
		if img.placements <= 0 && img.anonymous {
			image_free(g, img)
		}
	}
}

// placement_drop_unattached removes a placement that never got a fragment,
// which happens when it lands entirely outside the screen.
placement_drop_unattached :: proc(pl: ^Placement) {
	if pl.refs == 0 {
		pl.refs = 1
		placement_unref(pl)
	}
}

// row_attach puts one row's share of a placement on a row.
row_attach :: proc(r: ^Row, pl: ^Placement, col, row: int) {
	f := Frag {
		pl   = pl,
		col  = i32(col),
		row  = i32(row),
		from = 0,
		to   = i32(pl.cols),
	}
	if pl.sixel {
		// A new Sixel image replaces an old one it covers completely, the
		// way it would on a terminal that keeps one bitmap: without this an
		// application redrawing an image in place stacks copies forever.
		i := 0
		for i < len(r.frags) {
			o := r.frags[i]
			lo := o.col + o.from
			hi := o.col + o.to
			if o.pl.sixel && lo >= f.col && hi <= f.col + f.to {
				frags_remove(r, i)
				continue
			}
			i += 1
		}
	}
	n := make([]Frag, len(r.frags) + 1)
	copy(n, r.frags)
	n[len(r.frags)] = f
	delete(r.frags)
	r.frags = n
	pl.refs += 1
	r.dirty = true
	pl.gfx.changed = true
}

@(private = "file")
frags_remove :: proc(r: ^Row, i: int) {
	pl := r.frags[i].pl
	copy(r.frags[i:], r.frags[i + 1:])
	if len(r.frags) == 1 {
		delete(r.frags)
		r.frags = nil
	} else {
		r.frags = r.frags[:len(r.frags) - 1]
	}
	r.dirty = true
	placement_unref(pl)
}

// row_release drops every fragment on a row. Everything that destroys or
// blanks a row goes through here, which is what keeps the counts honest.
row_release :: proc(r: ^Row) {
	if r.frags == nil {
		return
	}
	frags := r.frags
	r.frags = nil
	for f in frags {
		placement_unref(f.pl)
	}
	delete(frags)
	r.dirty = true
}

// row_cut removes columns [x0, x1) of every Sixel fragment on a row: text
// printed or erased over a Sixel image replaces that part of it.
row_cut :: proc(r: ^Row, x0, x1: int) {
	if r.frags == nil {
		return
	}
	i := 0
	for i < len(r.frags) {
		f := r.frags[i]
		if !f.pl.sixel {
			i += 1
			continue
		}
		lo := int(f.col + f.from)
		hi := int(f.col + f.to)
		if x1 <= lo || x0 >= hi {
			i += 1
			continue
		}
		left := Frag{pl = f.pl, col = f.col, row = f.row, from = f.from, to = i32(x0) - f.col}
		right := Frag{pl = f.pl, col = f.col, row = f.row, from = i32(x1) - f.col, to = f.to}
		keep_left := left.to > left.from
		keep_right := right.to > right.from
		switch {
		case keep_left && keep_right:
			r.frags[i] = left
			n := make([]Frag, len(r.frags) + 1)
			copy(n, r.frags[:i + 1])
			n[i + 1] = right
			copy(n[i + 2:], r.frags[i + 1:])
			delete(r.frags)
			r.frags = n
			f.pl.refs += 1
			i += 2
		case keep_left:
			r.frags[i] = left
			i += 1
		case keep_right:
			r.frags[i] = right
			i += 1
		case:
			frags_remove(r, i)
			continue
		}
		r.dirty = true
	}
}

// purge_doomed removes every fragment of every doomed placement from both
// screens and the scrollback.
purge_doomed :: proc(t: ^Terminal) {
	purge := proc(rows: []Row) {
		for &r in rows {
			if r.frags == nil {
				continue
			}
			i := 0
			for i < len(r.frags) {
				if r.frags[i].pl.doomed {
					frags_remove(&r, i)
					continue
				}
				i += 1
			}
		}
	}
	purge(t.primary.lines[:])
	purge(t.primary.scrollback[:])
	purge(t.alt.lines[:])
	// A doomed placement with no fragments left anywhere is already gone;
	// one that never had any is dropped here.
	i := 0
	for i < len(t.gfx.placements) {
		pl := t.gfx.placements[i]
		if pl.doomed && pl.refs == 0 {
			placement_drop_unattached(pl)
			continue
		}
		i += 1
	}
	t.gfx.changed = true
	screen_mark_all_dirty(&t.primary)
	screen_mark_all_dirty(&t.alt)
}

// placements_visible collects the placements with a fragment on the active
// screen, which is what Kitty's "visible" delete targets mean.
placements_visible :: proc(t: ^Terminal, out: ^[dynamic]^Placement) {
	s := screen(t)
	for r in s.lines {
		for f in r.frags {
			found := false
			for x in out {
				if x == f.pl {
					found = true
					break
				}
			}
			if !found {
				append(out, f.pl)
			}
		}
	}
}

// ---------------------------------------------------------------------------
// A capped allocator.
//
// zlib and PNG both decompress, and a decompressor that is handed a small
// stream can be asked to produce gigabytes. Odin's inflate grows its output
// buffer until a compile-time limit of 4 GiB. Running the decoders under an
// allocator that refuses any single allocation larger than the budget turns a
// decompression bomb into an ordinary decode error.
// ---------------------------------------------------------------------------

Capped :: struct {
	parent: runtime.Allocator,
	limit:  int,
}

capped_allocator :: proc(c: ^Capped) -> runtime.Allocator {
	return runtime.Allocator{procedure = capped_proc, data = c}
}

@(private = "file")
capped_proc :: proc(
	data: rawptr,
	mode: runtime.Allocator_Mode,
	size, alignment: int,
	old_memory: rawptr,
	old_size: int,
	loc := #caller_location,
) -> (
	[]byte,
	runtime.Allocator_Error,
) {
	c := (^Capped)(data)
	#partial switch mode {
	case .Alloc, .Alloc_Non_Zeroed, .Resize, .Resize_Non_Zeroed:
		if size > c.limit {
			return nil, .Out_Of_Memory
		}
	}
	return c.parent.procedure(c.parent.data, mode, size, alignment, old_memory, old_size, loc)
}
