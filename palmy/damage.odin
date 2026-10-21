package palmy

// Damage: telling the compositor which pixels of a frame changed.
//
// Every frame is painted whole into a free buffer, so the buffer itself
// cannot say what is new. A copy of the last frame the compositor was given
// can: the rows that differ from it, grouped into a few rectangles, are the
// frame's damage, and a frame with none is not sent at all. The comparison
// is a row-by-row memcmp, about a third of a millisecond for a 1000x640
// window, which a compositor that repaints only damage (apps/wm on bare
// metal) earns back many times over: a key typed into a terminal is one
// line of cells instead of the whole surface.
//
// A frame that differs from the last in a few places is also *painted* only
// there: see "Partial repaint" below. A blinking caret used to cost a whole
// software repaint twice a second for as long as a field held focus.
//
// PALMY_DAMAGE=off restores whole-surface damage on every frame (and so whole
// repaints). PALMY_DAMAGE=full keeps the damage but repaints every frame
// whole. PALMY_DAMAGE=verify repaints partially, then paints the frame whole
// as well and reports on stderr any pixel the two disagree on.

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:os"
import "core:time"

// Damage_Rect is a changed region in buffer pixels.
Damage_Rect :: struct {
	x, y, w, h: int,
}

// Changed rows separated by fewer unchanged rows than this join one
// rectangle; more rectangles than MAX_DAMAGE_RECTS become their union.
@(private)
DAMAGE_ROW_GAP :: 8
@(private)
MAX_DAMAGE_RECTS :: 16

// How long an unchanged frame holds the loop when nothing paces it: a frame
// that is not committed gets no frame callback, and an animating app would
// otherwise repaint as fast as the CPU allows to find nothing new.
@(private)
SKIP_HOLD_MS :: 16

// Damage_State, frame_damage and damage_destroy are public only so the tests
// can drive them; a window keeps its own.
Damage_State :: struct {
	shadow:   []u32, // the last frame the server was given
	w, h:     int,
	disabled: bool,
	checked:  bool,
	rects:    [dynamic]Damage_Rect,
	// After a skipped frame, the loop waits until then before painting the
	// next one (frame_hold_ms).
	hold_until: time.Time,
	skipped:  u64,

	// Which frame the shadow holds, counted in frames that changed something,
	// and the union of each recent frame's damage by that count. A buffer
	// coming back from the server is brought up to date from these.
	serial:   u64,
	history:  [DAMAGE_HISTORY]Damage_Rect,
	// The partial repaint's knowledge of what it painted; see below.
	repaint:  Repaint_State,
	mode:     Repaint_Mode,
	// Set by a partial repaint for the frame it painted: nothing outside it
	// can differ from the shadow, so the comparison looks only inside.
	hint:     Damage_Rect,
	hinted:   bool,
}

damage_destroy :: proc(d: ^Damage_State) {
	delete(d.shadow)
	delete(d.rects)
	repaint_destroy(&d.repaint)
	d^ = {}
}

@(private)
DAMAGE_HISTORY :: 8

// Repaint_Mode is PALMY_DAMAGE.
Repaint_Mode :: enum u8 {
	Partial, // the default: repaint what changed
	Off,     // no damage tracking, no partial repaint
	Full,    // damage tracking, every frame painted whole
	Verify,  // partial, checked against a whole paint
}

// frame_damage compares buffer `px` (bw x bh) with the last frame sent and
// fills d.rects with what changed; it returns false when nothing did. The
// shadow copy is brought up to date as a side effect, so it must be called
// only for a frame that is then actually sent (or skipped because it is
// identical).
frame_damage :: proc(d: ^Damage_State, px: []u32, bw, bh: int) -> (changed: bool) {
	clear(&d.rects)
	damage_mode(d)
	hint, hinted := d.hint, d.hinted
	d.hinted = false
	n := bw * bh
	if bw <= 0 || bh <= 0 || len(px) < n {
		return true
	}
	if d.disabled || d.w != bw || d.h != bh || len(d.shadow) != n {
		// A new size (or no previous frame): everything is new.
		if !d.disabled {
			delete(d.shadow)
			d.shadow = make([]u32, n)
			copy(d.shadow, px[:n])
			d.w, d.h = bw, bh
			d.serial += 1
			d.history[d.serial % DAMAGE_HISTORY] = {0, 0, bw, bh}
			// Every buffer's age is relative to a shadow that no longer exists.
			d.repaint.bufs = {}
		}
		append(&d.rects, Damage_Rect{0, 0, bw, bh})
		return true
	}

	// The rows and columns to compare: everything, or only what a partial
	// repaint wrote. Outside its limit the buffer was copied from the shadow,
	// so comparing there finds nothing at the price of a whole-frame memcmp.
	ry0, ry1, rx0, rx1 := 0, bh, 0, bw
	if hinted {
		ry0, ry1 = clamp(hint.y, 0, bh), clamp(hint.y + hint.h, 0, bh)
		rx0, rx1 = clamp(hint.x, 0, bw), clamp(hint.x + hint.w, 0, bw)
		if rx0 >= rx1 {
			ry1 = ry0
		}
	}

	cur: Damage_Rect
	open := false
	last := -DAMAGE_ROW_GAP - 1
	for y in ry0 ..< ry1 {
		row := px[y * bw + rx0:y * bw + rx1]
		old := d.shadow[y * bw + rx0:y * bw + rx1]
		if runtime.memory_equal(raw_data(row), raw_data(old), len(row) * size_of(u32)) {
			continue
		}
		x0 := 0
		for x0 < len(row) && row[x0] == old[x0] {
			x0 += 1
		}
		x1 := len(row) - 1
		for x1 > x0 && row[x1] == old[x1] {
			x1 -= 1
		}
		copy(old[x0:x1 + 1], row[x0:x1 + 1])
		x0 += rx0
		x1 += rx0
		if open && y - last <= DAMAGE_ROW_GAP {
			right := max(cur.x + cur.w, x1 + 1)
			cur.x = min(cur.x, x0)
			cur.w = right - cur.x
			cur.h = y + 1 - cur.y
		} else {
			if open {
				append(&d.rects, cur)
			}
			cur = {x0, y, x1 + 1 - x0, 1}
			open = true
		}
		last = y
	}
	if open {
		append(&d.rects, cur)
	}
	if len(d.rects) > MAX_DAMAGE_RECTS {
		u := d.rects[0]
		for r in d.rects[1:] {
			right := max(u.x + u.w, r.x + r.w)
			bottom := max(u.y + u.h, r.y + r.h)
			u.x = min(u.x, r.x)
			u.y = min(u.y, r.y)
			u.w = right - u.x
			u.h = bottom - u.y
		}
		clear(&d.rects)
		append(&d.rects, u)
	}
	if len(d.rects) > 0 {
		d.serial += 1
		d.history[d.serial % DAMAGE_HISTORY] = rect_union_all(d.rects[:])
	}
	return len(d.rects) > 0
}

@(private)
damage_mode :: proc(d: ^Damage_State) {
	if d.checked {
		return
	}
	d.checked = true
	switch os.get_env("PALMY_DAMAGE", context.temp_allocator) {
	case "off":
		d.mode = .Off
		d.disabled = true
	case "full":
		d.mode = .Full
	case "verify":
		d.mode = .Verify
	}
}

@(private)
rect_union_all :: proc(rs: []Damage_Rect) -> Damage_Rect {
	if len(rs) == 0 {
		return {}
	}
	u := rs[0]
	for r in rs[1:] {
		u = damage_union(u, r)
	}
	return u
}

@(private)
damage_union :: proc "contextless" (a, b: Damage_Rect) -> Damage_Rect {
	if a.w <= 0 || a.h <= 0 {
		return b
	}
	if b.w <= 0 || b.h <= 0 {
		return a
	}
	x0, y0 := min(a.x, b.x), min(a.y, b.y)
	x1, y1 := max(a.x + a.w, b.x + b.w), max(a.y + a.h, b.y + b.h)
	return {x0, y0, x1 - x0, y1 - y0}
}

// ---------------------------------------------------------------------------
// Partial repaint
//
// palmy is immediate mode: every frame rebuilds the tree and, until this, every
// frame painted all of it. Damage made the *compositor's* share of a small
// change small; the client still rasterised the whole window to find it. For a
// blinking caret that is two whole repaints a second, all for a 2x20 pixel bar
// -- the 2-8% of a core a focused field cost on the frame-loop verification.
//
// The previous frame's tree is still there (`ctx.prev`, kept for hit testing),
// laid out, its strings alive in the old arena. So after layout the two trees
// are compared node by node, and what differs is the damage:
//
//   - a node present in both whose painted inputs differ -- rect, clip, style,
//     text lines, icon, its parent's clip (rings and shadows paint against it);
//   - a leaf in one and not the other: the caret appearing and disappearing,
//     which is the case this exists for;
//   - a `pixels` or `image` node, always, unless the caller said what its
//     drawing depends on (`paint_key`) and that has not changed. palmy cannot
//     see inside an image buffer someone else rewrites (a video frame) or a
//     drawing procedure, so it does not guess;
//   - a scrollbar whose thumb moved.
//
// Each changed node contributes its ink -- its box grown by its ring, shadow
// and any text that overhangs it, cut to the clips it can paint inside -- in
// both frames. Anything structural it cannot explain (two different subtrees,
// a transition still moving, a different font set, a new size, a frame it did
// not paint, a translucent root) and the frame is painted whole, as before.
//
// The repaint itself is the ordinary painter with the canvas `limit` set to
// the damage: every node is visited and decides exactly what it would decide in
// a whole frame, and only the pixels inside the limit are written. Text and
// `pixels` nodes whose ink misses the limit are not drawn at all, which is
// where the time goes. The buffer is first brought up to the last frame sent,
// from the shadow, using the damage history for the rows it is behind by.
//
// PALMY_DAMAGE=verify paints every partial frame whole as well and prints any
// pixel the two disagree on. tests/partial_repaint_test.odin asserts they
// agree, pixel for pixel, for the cases above.
// ---------------------------------------------------------------------------

Repaint_State :: struct {
	frame:      u64, // ctx.frame of the tree last painted; 0 for none
	animating:  bool,
	fonts_gen:  u64,
	no_kern:    bool,
	scale:      f32,
	w, h:       int,
	thumbs:     [dynamic]Repaint_Thumb,
	scratch:    [dynamic]Repaint_Thumb,
	bufs:       [4]Repaint_Buf,
	verify_px:  []u32,

	// What happened, for tests and for PALMY_TRACE_LOOP.
	partial:    u64,
	whole:      u64,
	mismatched: u64,
	last:       Damage_Rect, // the last partial frame's limit
	why:        string,      // why the last frame was painted whole
}

@(private)
Repaint_Thumb :: struct {
	id: u64,
	r:  Rect,
}

// Repaint_Buf is how up to date a buffer is: it holds the frame whose serial
// this is. A buffer being painted is forgotten until it is sent.
@(private)
Repaint_Buf :: struct {
	px:     rawptr,
	serial: u64,
}

@(private)
repaint_destroy :: proc(r: ^Repaint_State) {
	delete(r.thumbs)
	delete(r.scratch)
	delete(r.verify_px)
	r^ = {}
}

// paint_key says what a `pixels` or `image` node's drawing depends on: two
// frames that give the node the same non-zero key, the same box and the same
// style draw the same pixels. With it, a frame in which only something else
// changed -- a caret blinking beside a canvas -- does not repaint the canvas.
//
//	idx := palmy.pixels(ui, "w-full h-full", st, canvas_draw)
//	palmy.paint_key(ui, hash_of(st.deck_rev, st.slide, st.sel, st.zoom), idx)
//
// A wrong key is a stale picture, so leave it out rather than guess: an
// unkeyed node is simply repainted. A key of zero is the same as none. A
// keyed node outside the part of the frame being repainted is not drawn at
// all, so its procedure is not called on that frame: anything it records as
// it draws (where it put the content, for hit testing) must come out the same
// for the same key, which it does when the key covers everything it reads.
paint_key :: proc(ctx: ^Ctx, key: u64, idx := -1) {
	i := idx >= 0 ? idx : ctx.last
	if i >= 0 && i < len(ctx.nodes) {
		ctx.nodes[i].paint_key = key
	}
}

// repaint_stats reports how many frames this window painted partially and
// whole, and how many partial frames PALMY_DAMAGE=verify caught disagreeing.
repaint_stats :: proc(app: ^App) -> (partial, whole, mismatched: u64) {
	if app == nil {
		return
	}
	r := &app.win.damage.repaint
	return r.partial, r.whole, r.mismatched
}

// repaint_region decides whether this frame can be painted as a change to the
// last one, and returns the rectangle to repaint in device pixels. An empty
// rectangle with ok means nothing visible changed.
@(private)
repaint_region :: proc(r: ^Repaint_State, ctx: ^Ctx, c: ^Canvas) -> (region: Damage_Rect, ok: bool) {
	fail :: proc(r: ^Repaint_State, why: string) -> (Damage_Rect, bool) {
		r.why = why
		return {}, false
	}
	switch {
	case r.frame == 0 || ctx.frame != r.frame + 1:
		return fail(r, "the last frame built was not painted")
	case r.animating:
		return fail(r, "a transition was moving")
	case ctx.fonts == nil || r.fonts_gen != ctx.fonts.generation || r.no_kern != ctx.fonts.no_kerning:
		return fail(r, "the fonts changed")
	case r.scale != c.scale || r.w != c.w || r.h != c.h:
		return fail(r, "the size changed")
	case len(ctx.nodes) == 0 || len(ctx.prev) == 0:
		return fail(r, "no tree")
	}

	// The whole-frame paint covers every pixel only because the root is an
	// opaque rectangle over the canvas; under a translucent root it blends
	// onto whatever the buffer held, and a repaint onto the last frame would
	// not reproduce that.
	root := &ctx.nodes[0]
	rs := root.style
	if rs.hidden || rs.opacity < 1 || rs.bg.color.a != 255 || (rs.bg.gradient && rs.bg.color2.a != 255) ||
	   rs.radius != {} || root.rect.x > 0 || root.rect.y > 0 ||
	   root.rect.w * c.scale < f32(c.w) || root.rect.h * c.scale < f32(c.h) {
		return fail(r, "the root is not an opaque rectangle over the canvas")
	}

	cur, old := ctx.nodes[:], ctx.prev[:]
	sc := c.scale
	u: Damage_Rect
	add :: proc(u: ^Damage_Rect, nodes: []Node, i: int, sc: f32, fonts: ^Fonts) {
		u^ = damage_union(u^, node_ink_device(nodes, i, sc, fonts))
	}

	i, j := 0, 0
	for i < len(cur) || j < len(old) {
		if i < len(cur) && j < len(old) && cur[i].id == old[j].id {
			if !node_paints_same(cur, i, old, j) {
				add(&u, cur, i, sc, ctx.fonts)
				add(&u, old, j, sc, ctx.fonts)
			}
			i += 1
			j += 1
			continue
		}
		// One leaf inserted or removed, and everything after it lines up
		// again. The tree also changed shape around it -- a parent has one
		// child more -- but child counts are not painted.
		if i < len(cur) && cur[i].first_child < 0 && (i + 1 < len(cur) ? j < len(old) && cur[i + 1].id == old[j].id : j == len(old)) {
			add(&u, cur, i, sc, ctx.fonts)
			i += 1
			continue
		}
		if j < len(old) && old[j].first_child < 0 && (j + 1 < len(old) ? i < len(cur) && old[j + 1].id == cur[i].id : i == len(cur)) {
			add(&u, old, j, sc, ctx.fonts)
			j += 1
			continue
		}
		return fail(r, "the tree changed shape")
	}

	// Scrollbars are drawn from widget state, not from the node.
	clear(&r.scratch)
	scrollbar_thumbs(ctx, sc, &r.scratch)
	for t in r.scratch {
		was, found := thumb_of(r.thumbs[:], t.id)
		if !found || was != t.r {
			u = damage_union(u, damage_from(t.r, c))
			if found {
				u = damage_union(u, damage_from(was, c))
			}
		}
	}
	for t in r.thumbs {
		if _, found := thumb_of(r.scratch[:], t.id); !found {
			u = damage_union(u, damage_from(t.r, c))
		}
	}

	u = damage_clamp(u, c.w, c.h)
	// Past half the window a whole paint costs about the same and needs no
	// copy from the shadow first.
	if u.w * u.h * 2 > c.w * c.h {
		return fail(r, "most of the window changed")
	}
	return u, true
}

@(private)
thumb_of :: proc(ts: []Repaint_Thumb, id: u64) -> (Rect, bool) {
	for t in ts {
		if t.id == id {
			return t.r, true
		}
	}
	return {}, false
}

@(private)
damage_clamp :: proc "contextless" (u: Damage_Rect, w, h: int) -> Damage_Rect {
	x0, y0 := clamp(u.x, 0, w), clamp(u.y, 0, h)
	x1, y1 := clamp(u.x + u.w, 0, w), clamp(u.y + u.h, 0, h)
	if x1 <= x0 || y1 <= y0 {
		return {}
	}
	return {x0, y0, x1 - x0, y1 - y0}
}

// damage_from rounds a device-pixel rectangle out to whole pixels, with one to
// spare for antialiasing that reaches past a fractional edge.
@(private)
damage_from :: proc(r: Rect, c: ^Canvas) -> Damage_Rect {
	if r.w <= 0 || r.h <= 0 {
		return {}
	}
	x0 := int(math.floor(r.x)) - 1
	y0 := int(math.floor(r.y)) - 1
	x1 := int(math.ceil(r.x + r.w)) + 1
	y1 := int(math.ceil(r.y + r.h)) + 1
	return {x0, y0, x1 - x0, y1 - y0}
}

// node_paints_same compares everything paint_node reads from a node. Style is
// compared as bytes: it holds no pointers, and a difference in padding can
// only make two equal styles look different, which costs a little damage and
// is never wrong.
@(private)
node_paints_same :: proc(an: []Node, i: int, bn: []Node, j: int) -> bool {
	a, b := &an[i], &bn[j]
	if a.kind != b.kind || a.rect != b.rect || a.clip != b.clip {
		return false
	}
	if !runtime.memory_equal(&a.style, &b.style, size_of(Style)) {
		return false
	}
	pa := a.parent >= 0 ? an[a.parent].clip : Rect{}
	pb := b.parent >= 0 ? bn[b.parent].clip : Rect{}
	if pa != pb {
		return false
	}
	switch a.kind {
	case .Box:
	case .Text:
		if len(a.lines) != len(b.lines) {
			return false
		}
		for l, k in a.lines {
			m := b.lines[k]
			if l.width != m.width || l.dir != m.dir || l.text != m.text {
				return false
			}
		}
	case .Icon:
		x, y := a.icon, b.icon
		if a.icon_turns != b.icon_turns || x.d != y.d || x.view != y.view || x.stroke != y.stroke || x.fill != y.fill {
			return false
		}
	case .Image:
		x, y := a.img, b.img
		if a.paint_key == 0 || a.paint_key != b.paint_key || a.fit != b.fit || a.zoom != b.zoom ||
		   raw_data(x.px) != raw_data(y.px) || x.w != y.w || x.h != y.h ||
		   x.stride != y.stride || x.ox != y.ox || x.oy != y.oy || x.turns != y.turns {
			return false
		}
	case .Custom:
		if a.paint_key == 0 || a.paint_key != b.paint_key || a.custom != b.custom || a.user != b.user {
			return false
		}
	}
	return true
}

// node_ink is where a node can put pixels, in logical pixels: its box, grown by
// its ring, its shadow and text that overhangs it, and cut to the clips it
// paints inside -- its own, or its parent's for a ring or a shadow.
@(private)
node_ink :: proc(nodes: []Node, i: int, fonts: ^Fonts) -> Rect {
	n := &nodes[i]
	s := n.style
	r := n.rect
	b := r
	if s.ring > 0 {
		b = rect_union(b, rect_inset(r, -s.ring))
	}
	if s.shadow.color.a > 0 {
		grow := s.shadow.spread + s.shadow.blur + 1
		b = rect_union(b, rect_inset(Rect{r.x, r.y + s.shadow.y, r.w, r.h}, -max(grow, 0)))
	}
	switch n.kind {
	case .Text:
		// Lines are aligned inside the box and may be wider than it; glyphs
		// overhang their advance by a fraction of the size, outlines by their
		// width. A size each way covers all of it.
		widest := f32(0)
		for l in n.lines {
			widest = max(widest, l.width)
		}
		m := s.font_size + s.outline_w + 2
		tall := max(r.h, f32(len(n.lines)) * line_height_of(s))
		x0 := min(r.x, r.x + r.w - widest) - m
		x1 := max(r.x + r.w, r.x + widest) + m
		b = rect_union(b, Rect{x0, r.y - m, x1 - x0, tall + 2 * m})
	case .Custom:
		// A drawing procedure is clipped to its box only with overflow
		// hidden; otherwise it may draw anywhere inside the node's clip.
		if s.overflow == .Visible {
			b = rect_union(b, n.clip)
		}
	case .Image:
		// Contain and Fill land inside the box; None at natural size, or a
		// zoom, can spill out of it unless the node clips.
		if s.overflow == .Visible && n.fit == .None || s.overflow == .Visible && n.fit != .Cover && n.zoom > 1 {
			b = rect_union(b, n.clip)
		}
	case .Box, .Icon:
	}
	parent := n.parent >= 0 ? nodes[n.parent].clip : n.clip
	return rect_intersect(b, rect_union(n.clip, parent))
}

@(private)
node_ink_device :: proc(nodes: []Node, i: int, sc: f32, fonts: ^Fonts) -> Damage_Rect {
	r := node_ink(nodes, i, fonts)
	if r.w <= 0 || r.h <= 0 {
		return {}
	}
	d := dev_rect(r, sc)
	x0 := int(math.floor(d.x)) - 1
	y0 := int(math.floor(d.y)) - 1
	x1 := int(math.ceil(d.x + d.w)) + 1
	y1 := int(math.ceil(d.y + d.h)) + 1
	return {x0, y0, x1 - x0, y1 - y0}
}

@(private)
rect_union :: proc "contextless" (a, b: Rect) -> Rect {
	if a.w <= 0 || a.h <= 0 {
		return b
	}
	if b.w <= 0 || b.h <= 0 {
		return a
	}
	x0, y0 := min(a.x, b.x), min(a.y, b.y)
	x1, y1 := max(a.x + a.w, b.x + b.w), max(a.y + a.h, b.y + b.h)
	return {x0, y0, x1 - x0, y1 - y0}
}

// repaint_note records what was just painted: the tree, the faces, the size
// and where the scrollbars were. Called after every painted frame, whole or
// partial.
@(private)
repaint_note :: proc(r: ^Repaint_State, ctx: ^Ctx, c: ^Canvas) {
	r.frame = ctx.frame
	r.animating = ctx.animating
	if ctx.fonts != nil {
		r.fonts_gen = ctx.fonts.generation
		r.no_kern = ctx.fonts.no_kerning
	}
	r.scale, r.w, r.h = c.scale, c.w, c.h
	clear(&r.thumbs)
	scrollbar_thumbs(ctx, c.scale, &r.thumbs)
}

// damage_forget_buffer marks a buffer as holding nothing known, before it is
// painted into: until it is sent its contents match no frame.
@(private)
damage_forget_buffer :: proc(d: ^Damage_State, px: []u32) {
	for &b in d.repaint.bufs {
		if b.px == raw_data(px) {
			b = {}
		}
	}
}

// damage_sent_buffer records that a buffer now holds the frame the shadow
// holds: it was just presented, or it was identical and skipped.
@(private)
damage_sent_buffer :: proc(d: ^Damage_State, px: []u32) {
	if d.shadow == nil {
		return
	}
	slot := -1
	for b, k in d.repaint.bufs {
		if b.px == raw_data(px) {
			slot = k
			break
		}
	}
	if slot < 0 {
		// A free slot, else the stalest.
		slot = 0
		for b, k in d.repaint.bufs {
			if b.px == nil {
				slot = k
				break
			}
			if b.serial < d.repaint.bufs[slot].serial {
				slot = k
			}
		}
	}
	d.repaint.bufs[slot] = {raw_data(px), d.serial}
}

// damage_restore brings a buffer up to the last frame sent, from the shadow:
// only the rows it is behind by, when the history still has them.
@(private)
damage_restore :: proc(d: ^Damage_State, px: []u32, w, h: int) -> bool {
	n := w * h
	if d.disabled || d.shadow == nil || d.w != w || d.h != h || len(d.shadow) != n || len(px) < n {
		return false
	}
	have := u64(0)
	known := false
	for b in d.repaint.bufs {
		if b.px == raw_data(px) {
			have, known = b.serial, true
		}
	}
	if known && have == d.serial {
		return true
	}
	if !known || d.serial - have > DAMAGE_HISTORY - 1 {
		copy(px[:n], d.shadow[:n])
		return true
	}
	for s := have + 1; s <= d.serial; s += 1 {
		u := damage_clamp(d.history[s % DAMAGE_HISTORY], w, h)
		for y in u.y ..< u.y + u.h {
			copy(px[y * w + u.x:y * w + u.x + u.w], d.shadow[y * w + u.x:y * w + u.x + u.w])
		}
	}
	return true
}

// paint_frame lays nothing out; it paints the laid-out tree into `c`, partially
// when it can. `d` may be nil (no shadow: the canvas must already hold the
// previous frame, as an offscreen canvas does). Returns the region repainted
// and whether the frame was partial.
@(private)
paint_frame :: proc(ctx: ^Ctx, c: ^Canvas, d: ^Damage_State, r: ^Repaint_State, keep: bool) -> (region: Damage_Rect, partial: bool) {
	mode := Repaint_Mode.Partial
	if d != nil {
		damage_mode(d)
		mode = d.mode
	}
	if mode == .Partial || mode == .Verify {
		if region, partial = repaint_region(r, ctx, c); partial {
			if d != nil && !damage_restore(d, c.px, c.w, c.h) {
				partial = false
				r.why = "the buffer could not be brought up to date"
			} else if d == nil && !keep {
				partial = false
				r.why = "the canvas does not hold the last frame"
			}
		}
	} else {
		r.why = "PALMY_DAMAGE asks for whole frames"
	}
	if d != nil {
		// Whatever it held, it is about to hold this frame, which is not sent
		// yet.
		damage_forget_buffer(d, c.px)
	}

	if !partial {
		paint_tree(ctx, c)
		r.whole += 1
		repaint_note(r, ctx, c)
		return {}, false
	}

	r.partial += 1
	r.last = region
	// Verifying paints the frame twice, and painting advances transitions
	// (`animate`). The second paint has to start from where the first did,
	// or it shows a transition one step further on and reports that as a
	// difference.
	before: map[u64]Anim
	if mode == .Verify {
		before = make(map[u64]Anim, len(ctx.widgets), context.temp_allocator)
		for id, w in ctx.widgets {
			before[id] = w.anim
		}
	}
	if region.w > 0 && region.h > 0 {
		c.limit = {f32(region.x), f32(region.y), f32(region.w), f32(region.h)}
		c.limited = true
		paint_tree(ctx, c)
		c.limited = false
	}
	if d != nil {
		d.hint, d.hinted = region, mode != .Verify
	}
	if mode == .Verify {
		for id, &w in ctx.widgets {
			if a, found := before[id]; found {
				w.anim = a
			}
		}
		repaint_verify(ctx, c, r, region)
	}
	repaint_note(r, ctx, c)
	return region, true
}

// repaint_verify paints the frame whole into a scratch canvas and compares.
// A disagreement is reported and the whole paint is kept, so the screen is
// right either way.
@(private)
repaint_verify :: proc(ctx: ^Ctx, c: ^Canvas, r: ^Repaint_State, region: Damage_Rect) {
	n := c.w * c.h
	if len(r.verify_px) != n {
		delete(r.verify_px)
		r.verify_px = make([]u32, n)
	}
	vc := canvas_from(r.verify_px, c.w, c.h, c.scale)
	defer canvas_destroy(&vc)
	paint_tree(ctx, &vc)
	bad := 0
	lo, hi := [2]int{c.w, c.h}, [2]int{-1, -1}
	for y in 0 ..< c.h {
		for x in 0 ..< c.w {
			if c.px[y * c.w + x] != vc.px[y * c.w + x] {
				bad += 1
				lo = {min(lo.x, x), min(lo.y, y)}
				hi = {max(hi.x, x), max(hi.y, y)}
			}
		}
	}
	if bad > 0 {
		r.mismatched += 1
		fmt.eprintfln(
			"palmy: partial repaint of %v differs from a whole paint in %d pixels, within (%d,%d)-(%d,%d)",
			region,
			bad,
			lo.x,
			lo.y,
			hi.x,
			hi.y,
		)
		copy(c.px[:n], vc.px[:n])
	}
}
