package main

// Undo/redo.
//
// Two kinds of edit, because an editor's changes come in two shapes:
//
//   Pixels — a rectangle of one layer, with the bytes before and after. A brush
//     stroke records one of these for the whole stroke, not one per sample, so
//     Ctrl-Z undoes a stroke and not a dab.
//   Meta  — the shape of the stack: order, names, visibility, opacity, blend,
//     which layer is active. A few dozen bytes. Layer pixels live in the pool
//     and are never destroyed, so deleting a layer and undoing it is index work
//     and the pixels are still there.
//
// The stack is bounded at HIST_MAX entries; the oldest is dropped and its
// buffers freed. A 1024x768 stroke across the whole canvas is 3 MB per side, so
// 48 entries is a worst case of a few hundred MB and a typical case of a few.

HIST_MAX :: 48

Edit_Kind :: enum u8 {
	Pixels,
	Meta,
}

Layer_Meta :: struct {
	pool:     int,
	name:     [NAME_CAP]u8,
	name_len: int,
	visible:  bool,
	opacity:  f32,
	blend:    Blend,
}

Meta_Snap :: struct {
	order:  []Layer_Meta,
	active: int,
}

Edit :: struct {
	kind:  Edit_Kind,
	label: string,

	// Pixels
	pool:   int,
	r:      Rect_I,
	before: []u32,
	after:  []u32,

	// Meta
	mb, ma: Meta_Snap,
}

History :: struct {
	entries: [dynamic]Edit,
	// Index of the next slot to write: everything below is undoable, everything
	// at or above is redoable.
	head:    int,
}

hist_init :: proc(h: ^History) {
	h.entries = make([dynamic]Edit, 0, HIST_MAX)
	h.head = 0
}

@(private = "file")
edit_free :: proc(e: ^Edit) {
	delete(e.before)
	delete(e.after)
	delete(e.mb.order)
	delete(e.ma.order)
	e^ = {}
}

hist_free :: proc(h: ^History) {
	for &e in h.entries {
		edit_free(&e)
	}
	delete(h.entries)
}

hist_can_undo :: proc(h: ^History) -> bool {return h.head > 0}
hist_can_redo :: proc(h: ^History) -> bool {return h.head < len(h.entries)}

hist_undo_label :: proc(h: ^History) -> string {
	return h.head > 0 ? h.entries[h.head - 1].label : ""
}

// hist_push drops any redo tail, appends, and trims the front.
hist_push :: proc(h: ^History, e: Edit) {
	for len(h.entries) > h.head {
		last := len(h.entries) - 1
		edit_free(&h.entries[last])
		pop(&h.entries)
	}
	append(&h.entries, e)
	for len(h.entries) > HIST_MAX {
		edit_free(&h.entries[0])
		ordered_remove(&h.entries, 0)
	}
	h.head = len(h.entries)
}

// ---------------------------------------------------------------------------
// Snapshots
// ---------------------------------------------------------------------------

meta_capture :: proc(d: ^Doc) -> Meta_Snap {
	out := Meta_Snap {
		order  = make([]Layer_Meta, len(d.order)),
		active = d.active,
	}
	for pi, i in d.order {
		l := d.pool[pi]
		out.order[i] = {
			pool     = pi,
			name     = l.name,
			name_len = l.name_len,
			visible  = l.visible,
			opacity  = l.opacity,
			blend    = l.blend,
		}
	}
	return out
}

meta_apply :: proc(d: ^Doc, s: Meta_Snap) {
	resize(&d.order, len(s.order))
	for m, i in s.order {
		d.order[i] = m.pool
		l := &d.pool[m.pool]
		l.name = m.name
		l.name_len = m.name_len
		l.visible = m.visible
		l.opacity = m.opacity
		l.blend = m.blend
	}
	d.active = clamp(s.active, 0, max(0, len(d.order) - 1))
	doc_dirty_all(d)
}

// ---------------------------------------------------------------------------
// Recording
// ---------------------------------------------------------------------------

// push_pixel_edit records a change to one layer's rectangle. `before` must have
// been captured before the change; `after` is read out here.
push_pixel_edit :: proc(h: ^History, d: ^Doc, pool: int, r_in: Rect_I, before: []u32, label: string) {
	r := rect_i_clip(r_in, d.w, d.h)
	if rect_i_empty(r) || before == nil {
		delete(before)
		return
	}
	hist_push(
		h,
		Edit {
			kind   = .Pixels,
			label  = label,
			pool   = pool,
			r      = r,
			before = before,
			after  = copy_region(d.pool[pool].px, d.w, r),
		},
	)
}

// push_meta_edit records a structural change. `before` comes from
// `meta_capture` taken ahead of the change.
push_meta_edit :: proc(h: ^History, d: ^Doc, before: Meta_Snap, label: string) {
	hist_push(h, Edit{kind = .Meta, label = label, mb = before, ma = meta_capture(d)})
}

// ---------------------------------------------------------------------------
// Replay
// ---------------------------------------------------------------------------

hist_undo :: proc(h: ^History, d: ^Doc) -> (label: string, ok: bool) {
	if h.head <= 0 {
		return "", false
	}
	h.head -= 1
	e := &h.entries[h.head]
	switch e.kind {
	case .Pixels:
		paste_region(d.pool[e.pool].px, d.w, e.r, e.before)
		layer_touch(d, e.pool, e.r)
	case .Meta:
		meta_apply(d, e.mb)
		for m in e.mb.order {
			d.pool[m.pool].thumb_old = true
		}
	}
	d.saved = false
	return e.label, true
}

hist_redo :: proc(h: ^History, d: ^Doc) -> (label: string, ok: bool) {
	if h.head >= len(h.entries) {
		return "", false
	}
	e := &h.entries[h.head]
	h.head += 1
	switch e.kind {
	case .Pixels:
		paste_region(d.pool[e.pool].px, d.w, e.r, e.after)
		layer_touch(d, e.pool, e.r)
	case .Meta:
		meta_apply(d, e.ma)
		for m in e.ma.order {
			d.pool[m.pool].thumb_old = true
		}
	}
	d.saved = false
	return e.label, true
}

// hist_bytes is what the status bar reports, so the bound is visible rather
// than asserted.
hist_bytes :: proc(h: ^History) -> int {
	n := 0
	for e in h.entries {
		n += (len(e.before) + len(e.after)) * 4
		n += (len(e.mb.order) + len(e.ma.order)) * size_of(Layer_Meta)
	}
	return n
}
