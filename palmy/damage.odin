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
// PALMY_DAMAGE=off restores whole-surface damage on every frame.

import "base:runtime"
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
}

damage_destroy :: proc(d: ^Damage_State) {
	delete(d.shadow)
	delete(d.rects)
	d^ = {}
}

// frame_damage compares buffer `px` (bw x bh) with the last frame sent and
// fills d.rects with what changed; it returns false when nothing did. The
// shadow copy is brought up to date as a side effect, so it must be called
// only for a frame that is then actually sent (or skipped because it is
// identical).
frame_damage :: proc(d: ^Damage_State, px: []u32, bw, bh: int) -> (changed: bool) {
	clear(&d.rects)
	if !d.checked {
		d.checked = true
		d.disabled = os.get_env("PALMY_DAMAGE", context.temp_allocator) == "off"
	}
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
		}
		append(&d.rects, Damage_Rect{0, 0, bw, bh})
		return true
	}

	cur: Damage_Rect
	open := false
	last := -DAMAGE_ROW_GAP - 1
	for y in 0 ..< bh {
		row := px[y * bw:(y + 1) * bw]
		old := d.shadow[y * bw:(y + 1) * bw]
		if runtime.memory_equal(raw_data(row), raw_data(old), bw * size_of(u32)) {
			continue
		}
		x0 := 0
		for x0 < bw && row[x0] == old[x0] {
			x0 += 1
		}
		x1 := bw - 1
		for x1 > x0 && row[x1] == old[x1] {
			x1 -= 1
		}
		copy(old[x0:x1 + 1], row[x0:x1 + 1])
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
	return len(d.rects) > 0
}
