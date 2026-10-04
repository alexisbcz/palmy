package main

// palmy photoshop — a raster image editor.
//
// Layers with blend modes, a brush, adjustments, filters, undo and a colour
// picker, over palmy's software rasterizer. The document is a stack of RGBA
// buffers this app owns outright; palmy's part is the window, the widget layer
// and `p.pixels`, which hands over the window's own memory so the composite is
// blitted straight into the frame the compositor is about to show. There is no
// intermediate image, no texture upload and no GPU.
//
//   doc.odin        layers, blend modes, the cached composite
//   tools.odin      brush strokes, flood fill, move
//   adjust.odin     tone and colour maps
//   filters.odin    separable gaussian, unsharp, sobel, emboss
//   history.odin    bounded undo/redo
//   color.odin      HSV / HSL / hex
//   view.odin       the canvas: zoom, pan, checkerboard, overlays
//   ui.odin         the chrome: tool palette, layers panel, status bar
//   overlay.odin    menus and dialogs, drawn in-window (palmy has no popups)
//   files.odin      opening and saving
//   selftest.odin   `--selftest`, the headless assertions
//
// Everything is keyboard-reachable. `?` lists the shortcuts.

import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"
import "core:time"
import kit "kit:."
import p "palmy:."

WIN_W :: 1360
WIN_H :: 860

PALETTE_W :: 56
PANEL_W :: 272
TOPBAR_H :: 44
OPTBAR_H :: 38
STATUS_H :: 26

ZOOM_MIN :: f32(0.02)
ZOOM_MAX :: f32(32)
ZOOM_STEP :: f32(1.25)

KEY_KP_ADD :: 0xffab
KEY_KP_SUB :: 0xffad

TOAST_CAP :: 96

Overlay :: enum u8 {
	None,
	Help,
	New_Doc,
	Open,
	Save_As,
	Picker,
	Adjust_Menu,
	Adjust,
	Filter_Menu,
	Filter,
	Layer_Menu,
	Rename,
}

St :: struct {
	doc:  Doc,
	hist: History,

	// Tools
	tool:      Tool,
	tool_held: Tool, // what to go back to when space-pan ends
	spacing:   bool,
	brush:     Brush,
	fg, bg:    u32,

	// View
	zoom:     f32,
	pan:      [2]f32,
	view:     p.Rect, // the canvas element, logical pixels
	want_fit: bool,
	scale_px: f32,

	// Selection, in document pixels
	sel:     Rect_I,
	has_sel: bool,

	// Drag
	stroke:     Stroke,
	drag:       bool,
	drag_kind:  Tool,
	from_doc:   [2]f32,
	from_scr:   [2]f32,
	from_pan:   [2]f32,
	move_base:  []u32,
	move_pool:  int,
	move_off:   [2]int,
	fill_stack: [dynamic][2]int,

	// Where the pointer is, in document pixels, for the brush ring
	cursor_doc: [2]f32,
	over_canvas: bool,

	// The keyboard cursor: where Return acts when there is no pointer. Arrows
	// move it, and it is what makes every tool reachable without a mouse.
	kb:        [2]f32,
	kb_live:   bool, // a keyboard brush stroke is down
	kb_sel:    bool, // a keyboard selection is being dragged
	kb_anchor: [2]f32,

	// Overlays
	ov:       Overlay,
	ov_sel:   int,
	adj_kind: Adjust_Kind,
	adj_v:    [MAX_PARAMS]f32,
	flt_kind: Filter_Kind,
	flt_v:    [MAX_PARAMS]f32,

	// Live preview: the active layer as it was when the dialog opened.
	prev_base:  []u32,
	prev_pool:  int,
	prev_stale: bool,
	prev_ms:    f64,

	// Colour picker
	pick_h, pick_s, pick_v: f32,
	pick_bg:                bool,

	// Dialog fields
	new_w, new_h: int,
	new_fill:     int, // 0 white, 1 transparent, 2 background colour
	path_buf:     [dynamic]u8,
	name_buf:     [dynamic]u8,
	files:        []Entry,
	files_dir:    string,

	// The shared Open/Save dialog, and what it was opened for. See pick.odin.
	// Named apart from the colour `pick_*` fields above, which are a different
	// kind of picking entirely.
	fpick:        kit.Pick,
	fpick_use:    File_Pick,

	// Panel thumbnails, one draw context per pool slot (`p.pixels` holds the
	// pointer until paint, so it cannot live in the frame arena).
	thumbs:    [MAX_LAYERS]Thumb_View,
	focus_sent: bool,
	hist_bins: [256]u32,
	hist_peak: u32,

	// Chrome. The toast lives in a fixed buffer because it outlives the frame
	// that raised it.
	toast_buf: [TOAST_CAP]u8,
	toast_len: int,
	toast_at:  f64,

	// Instrumentation, shown in the status bar.
	comp_px:  int,
	comp_ms:  f64,
	blit_ms:  f64,
	frame_ms: f64,
	blit_px:  int,

	mouse:   [2]f32,
	started: bool,
}

// st_init sets the defaults the app and the offscreen renderer share.
st_init :: proc(st: ^St) {
	st^ = St {
		tool      = .Brush,
		tool_held = .Brush,
		brush     = {size = 36, hardness = 0.65, opacity = 1, flow_tol = 32},
		fg        = 0xff_e11d48,
		bg        = 0xff_ffffff,
		zoom      = 1,
		want_fit  = true,
		scale_px  = 1,
		new_w     = 1024,
		new_h     = 768,
		move_pool = -1,
		prev_pool = -1,
	}
	st.fill_stack = make([dynamic][2]int, 0, 1024)
	st.path_buf = make([dynamic]u8, 0, 256)
	defer kit.pick_destroy(&st.fpick)
	st.name_buf = make([dynamic]u8, 0, 64)
	hist_init(&st.hist)
	sync_picker_from(st, st.fg)
}

main :: proc() {
	args := os.args[1:]
	for a, i in args {
		if a == "--selftest" {
			os.exit(selftest() ? 0 : 1)
		}
		if a == "--shot" {
			os.exit(shot_main(args[i:]) ? 0 : 1)
		}
		if a == "--bench" {
			os.exit(bench_main() ? 0 : 1)
		}
	}

	app, err := kit.start(
		{
			title = "Photoshop",
			app_id = "palmy",
			width = WIN_W,
			height = WIN_H,
			root_class = "w-full h-full flex-col bg-background text-foreground overflow-hidden relative",
		},
		true, // the dark theme: an editor's chrome must not bias the pixels
	)
	if err != "" {
		fmt.eprintfln("photoshop: %s", err)
		os.exit(1)
	}
	defer p.destroy(app)
	register_editor_theme()

	st: St
	st_init(&st)

	// A path argument opens that file; otherwise a starter document, because an
	// editor with no document is a dialog, not an editor.
	target := ""
	for a in args {
		if !strings.has_prefix(a, "-") {
			target = a
			break
		}
	}
	if target != "" && !open_file(&st, target) {
		new_document(&st, 1024, 768, 0)
		toast(&st, fmt.tprintf("could not decode %s", base_of(target)))
	} else if target == "" {
		new_document(&st, 1024, 768, 0)
		starter_content(&st)
	}
	defer doc_free(&st.doc)
	defer hist_free(&st.hist)
	defer stroke_free(&st.stroke)

	for ui in p.frames(app) {
		t_frame := time.tick_now()
		free_all(context.temp_allocator)
		st.scale_px = f32(p.window_scale(ui))
		st.mouse = p.mouse_pos(ui)
		st.started = true

		handle_keys(ui, app, &st)
		refresh_preview(&st)

		build_ui(ui, &st)
		pick_overlay(ui, &st)

		// The composite is folded here, at the end of the build, because the
		// canvas element's draw procedure does not run until palmy paints — so
		// anything a tool did during this frame is still in time.
		t_comp := time.tick_now()
		st.comp_px = doc_composite(&st.doc)
		if st.comp_px > 0 {
			st.comp_ms = time.duration_milliseconds(time.tick_since(t_comp))
		}

		if st.drag || st.toast_len > 0 {
			p.redraw(ui)
		}
		if st.toast_len > 0 && p.elapsed(ui) > f32(st.toast_at) + 2.6 {
			toast_clear(&st)
		}
		st.frame_ms = time.duration_milliseconds(time.tick_since(t_frame))
	}
}

// register_editor_theme darkens the shadcn dark tokens a little further and
// gives the app a neutral grey chrome. An editor's panels must not tint the
// user's judgement of the pixels next to them, which is why Photoshop's own
// interface is grey and why nothing here is.
register_editor_theme :: proc() {
	c :: p.hex
	p.register_color("background", c(0x1c1c1f))
	p.register_color("foreground", c(0xe8e8ea))
	p.register_color("card", c(0x232327))
	p.register_color("card-foreground", c(0xe8e8ea))
	p.register_color("popover", c(0x2a2a2f))
	p.register_color("popover-foreground", c(0xf2f2f4))
	p.register_color("primary", c(0x3b82f6))
	p.register_color("primary-foreground", c(0xf8fafc))
	p.register_color("secondary", c(0x323238))
	p.register_color("secondary-foreground", c(0xe8e8ea))
	p.register_color("muted", c(0x2b2b31))
	p.register_color("muted-foreground", c(0x9b9ba3))
	p.register_color("accent", c(0x3a3a42))
	p.register_color("accent-foreground", c(0xf8f8fa))
	p.register_color("destructive", c(0xf87171))
	p.register_color("destructive-foreground", c(0x1c1c1f))
	p.register_color("border", c(0x3a3a40))
	p.register_color("input", c(0x3a3a40))
	p.register_color("ring", c(0x60a5fa))
}

// ---------------------------------------------------------------------------
// Documents
// ---------------------------------------------------------------------------

new_document :: proc(st: ^St, w, h: int, fill_mode: int) {
	doc_free(&st.doc)
	hist_free(&st.hist)
	hist_init(&st.hist)
	stroke_free(&st.stroke)
	doc_init(&st.doc, max(1, w), max(1, h))

	fill: u32 = 0xff_ffffff
	name := "Background"
	switch fill_mode {
	case 1:
		fill = 0
		name = "Layer 1"
	case 2:
		fill = st.bg
	}
	doc_insert(&st.doc, doc_new_layer(&st.doc, name, fill), 0)
	st.doc.path = ""
	st.doc.saved = false
	st.has_sel = false
	st.sel = {}
	st.want_fit = true
	st.pan = {}
	kb_center(st)
}

// starter_content is the document the app opens with when nothing was asked
// for: three layers that already show what the editor does, so the first thing
// on screen is a composite rather than a white rectangle.
starter_content :: proc(st: ^St) {
	d := &st.doc
	b := &d.pool[d.order[0]]
	// A soft vertical gradient on the background.
	for y in 0 ..< d.h {
		t := f32(y) / f32(d.h - 1)
		r := u32(clamp(250 - 70 * t, 0, 255))
		g := u32(clamp(250 - 40 * t, 0, 255))
		bl := u32(clamp(252 - 10 * t, 0, 255))
		row := b.px[y * d.w:]
		for x in 0 ..< d.w {
			row[x] = 0xff00_0000 | (r << 16) | (g << 8) | bl
		}
	}
	b.thumb_old = true

	// A disc on its own layer, so the blend-mode demo has something to blend.
	shape := doc_new_layer(d, "Disc")
	{
		l := &d.pool[shape]
		cx, cy := f32(d.w) * 0.38, f32(d.h) * 0.46
		rad := f32(min(d.w, d.h)) * 0.3
		for y in 0 ..< d.h {
			fy := f32(y) + 0.5 - cy
			row := l.px[y * d.w:]
			for x in 0 ..< d.w {
				fx := f32(x) + 0.5 - cx
				dd := math.sqrt(fx * fx + fy * fy)
				cov := clamp(rad - dd, 0, 1)
				if cov <= 0 {
					continue
				}
				a := u32(cov * 255)
				row[x] = (a << 24) | 0x00_f97316
			}
		}
		l.opacity = 0.9
	}
	doc_insert(d, shape, 1)

	// And a rectangle above it set to Multiply.
	bars := doc_new_layer(d, "Bars")
	{
		l := &d.pool[bars]
		for y in int(f32(d.h) * 0.3) ..< int(f32(d.h) * 0.72) {
			row := l.px[y * d.w:]
			for x in int(f32(d.w) * 0.46) ..< int(f32(d.w) * 0.88) {
				row[x] = 0xff_3b82f6
			}
		}
		l.blend = .Multiply
	}
	doc_insert(d, bars, 2)
	d.active = 2
	doc_dirty_all(d)
}

// ---------------------------------------------------------------------------
// View transform
// ---------------------------------------------------------------------------

fit_zoom :: proc(st: ^St) -> f32 {
	if st.doc.w <= 0 || st.view.w <= 4 {
		return 1
	}
	return min(st.view.w / f32(st.doc.w), st.view.h / f32(st.doc.h)) * 0.94
}

do_fit :: proc(st: ^St) {
	st.zoom = clamp(fit_zoom(st), ZOOM_MIN, ZOOM_MAX)
	st.pan = {}
	st.want_fit = false
}

set_zoom :: proc(st: ^St, z: f32) {
	st.zoom = clamp(z, ZOOM_MIN, ZOOM_MAX)
	st.want_fit = false
}

// doc_origin is where document pixel (0,0) sits in logical window coordinates.
doc_origin :: proc(st: ^St) -> [2]f32 {
	w := f32(st.doc.w) * st.zoom
	h := f32(st.doc.h) * st.zoom
	cx := st.view.x + st.view.w / 2 + st.pan.x
	cy := st.view.y + st.view.h / 2 + st.pan.y
	return {cx - w / 2, cy - h / 2}
}

screen_to_doc :: proc(st: ^St, pt: [2]f32) -> [2]f32 {
	o := doc_origin(st)
	return {(pt.x - o.x) / st.zoom, (pt.y - o.y) / st.zoom}
}

// ---------------------------------------------------------------------------
// Selection
// ---------------------------------------------------------------------------

// clip_rect is the region a tool is allowed to touch: the selection, or the
// whole document.
clip_rect :: proc(st: ^St) -> Rect_I {
	if !st.has_sel {
		return {0, 0, st.doc.w, st.doc.h}
	}
	return rect_i_clip(st.sel, st.doc.w, st.doc.h)
}

select_all :: proc(st: ^St) {
	st.sel = {0, 0, st.doc.w, st.doc.h}
	st.has_sel = true
}

deselect :: proc(st: ^St) {
	st.has_sel = false
	st.sel = {}
}

// ---------------------------------------------------------------------------
// Layers
// ---------------------------------------------------------------------------

add_layer :: proc(st: ^St) {
	d := &st.doc
	if len(d.order) >= MAX_LAYERS {
		toast(st, "layer limit reached")
		return
	}
	before := meta_capture(d)
	name := fmt.tprintf("Layer %d", len(d.pool) + 1)
	doc_insert(d, doc_new_layer(d, name), d.active + 1)
	push_meta_edit(&st.hist, d, before, "New layer")
	toast(st, "new layer")
}

duplicate_layer :: proc(st: ^St) {
	d := &st.doc
	src := active_pool(d)
	if src < 0 || len(d.order) >= MAX_LAYERS {
		return
	}
	before := meta_capture(d)
	name := fmt.tprintf("%s copy", layer_name(&d.pool[src]))
	ni := doc_new_layer(d, name)
	copy(d.pool[ni].px, d.pool[src].px)
	d.pool[ni].opacity = d.pool[src].opacity
	d.pool[ni].blend = d.pool[src].blend
	doc_insert(d, ni, d.active + 1)
	push_meta_edit(&st.hist, d, before, "Duplicate layer")
	toast(st, "layer duplicated")
}

delete_layer :: proc(st: ^St) {
	d := &st.doc
	if len(d.order) <= 1 {
		toast(st, "a document needs one layer")
		return
	}
	before := meta_capture(d)
	doc_remove_at(d, d.active)
	push_meta_edit(&st.hist, d, before, "Delete layer")
	toast(st, "layer deleted")
}

move_layer :: proc(st: ^St, delta: int) {
	d := &st.doc
	to := d.active + delta
	if to < 0 || to >= len(d.order) {
		return
	}
	before := meta_capture(d)
	d.order[d.active], d.order[to] = d.order[to], d.order[d.active]
	d.active = to
	doc_dirty_all(d)
	push_meta_edit(&st.hist, d, before, "Reorder layer")
}

toggle_visible :: proc(st: ^St) {
	d := &st.doc
	l := active_layer(d)
	if l == nil {
		return
	}
	before := meta_capture(d)
	l.visible = !l.visible
	doc_dirty_all(d)
	push_meta_edit(&st.hist, d, before, l.visible ? "Show layer" : "Hide layer")
}

nudge_opacity :: proc(st: ^St, delta: f32) {
	d := &st.doc
	l := active_layer(d)
	if l == nil {
		return
	}
	before := meta_capture(d)
	l.opacity = clamp(l.opacity + delta, 0, 1)
	doc_dirty_all(d)
	push_meta_edit(&st.hist, d, before, "Layer opacity")
}

cycle_blend :: proc(st: ^St, delta: int) {
	d := &st.doc
	l := active_layer(d)
	if l == nil {
		return
	}
	before := meta_capture(d)
	n := len(Blend)
	l.blend = Blend((int(l.blend) + delta + n) % n)
	doc_dirty_all(d)
	push_meta_edit(&st.hist, d, before, "Blend mode")
	toast(st, fmt.aprintf("%s: %s", layer_name(l), BLEND_NAMES[l.blend]))
}

set_blend :: proc(st: ^St, b: Blend) {
	d := &st.doc
	l := active_layer(d)
	if l == nil || l.blend == b {
		return
	}
	before := meta_capture(d)
	l.blend = b
	doc_dirty_all(d)
	push_meta_edit(&st.hist, d, before, "Blend mode")
}

// ---------------------------------------------------------------------------
// Edits that need no dialog
// ---------------------------------------------------------------------------

Pixel_Op :: proc(dst, src: []u32, w: int, r: Rect_I)

run_pixel_op :: proc(st: ^St, op: Pixel_Op, label: string) {
	d := &st.doc
	pool := active_pool(d)
	if pool < 0 {
		return
	}
	r := clip_rect(st)
	if rect_i_empty(r) {
		return
	}
	before := copy_region(d.pool[pool].px, d.w, r)
	// src == dst is fine for a point operation.
	op(d.pool[pool].px, d.pool[pool].px, d.w, r)
	layer_touch(d, pool, r)
	push_pixel_edit(&st.hist, d, pool, r, before, label)
	toast(st, label)
}

// ---------------------------------------------------------------------------
// Live preview for the adjustment and filter dialogs
// ---------------------------------------------------------------------------

preview_begin :: proc(st: ^St) {
	d := &st.doc
	pool := active_pool(d)
	if pool < 0 {
		return
	}
	if len(st.prev_base) != d.w * d.h {
		delete(st.prev_base)
		st.prev_base = make([]u32, d.w * d.h)
	}
	copy(st.prev_base, d.pool[pool].px)
	st.prev_pool = pool
	st.prev_stale = true
}

// refresh_preview recomputes f(snapshot) into the layer whenever a parameter
// changed. Always from the snapshot, never from the previous preview, so
// dragging a slider back and forth lands exactly where it started.
refresh_preview :: proc(st: ^St) {
	if !st.prev_stale || st.prev_pool < 0 {
		return
	}
	st.prev_stale = false
	d := &st.doc
	r := clip_rect(st)
	t0 := time.tick_now()
	switch st.ov {
	case .Adjust:
		apply_adjust(st.adj_kind, st.adj_v, d.pool[st.prev_pool].px, st.prev_base, d.w, r)
	case .Filter:
		apply_filter(st.flt_kind, st.flt_v, d.pool[st.prev_pool].px, st.prev_base, d.w, d.h, r)
	case .None, .Help, .New_Doc, .Open, .Save_As, .Picker, .Adjust_Menu, .Filter_Menu, .Layer_Menu, .Rename:
		return
	}
	st.prev_ms = time.duration_milliseconds(time.tick_since(t0))
	layer_touch(d, st.prev_pool, r)
}

preview_commit :: proc(st: ^St, label: string) {
	if st.prev_pool < 0 {
		return
	}
	d := &st.doc
	r := clip_rect(st)
	before := copy_region(st.prev_base, d.w, r)
	push_pixel_edit(&st.hist, d, st.prev_pool, r, before, label)
	st.prev_pool = -1
	toast(st, label)
}

preview_cancel :: proc(st: ^St) {
	if st.prev_pool < 0 {
		return
	}
	d := &st.doc
	copy(d.pool[st.prev_pool].px, st.prev_base)
	layer_touch(d, st.prev_pool, {0, 0, d.w, d.h})
	st.prev_pool = -1
}

// ---------------------------------------------------------------------------
// Toast
// ---------------------------------------------------------------------------

// toast copies into a fixed buffer owned by the state. The obvious
// `strings.clone(s, context.temp_allocator)` dangles: the message outlives the
// frame it was raised in, and the frame arena is reset at the top of the next
// one.
toast :: proc(st: ^St, s: string) {
	n := min(len(s), TOAST_CAP)
	copy(st.toast_buf[:], s[:n])
	st.toast_len = n
	st.toast_at = 0
}

toast_text :: proc(st: ^St) -> string {
	return string(st.toast_buf[:st.toast_len])
}

toast_clear :: proc(st: ^St) {
	st.toast_len = 0
}

// ---------------------------------------------------------------------------
// Keyboard
// ---------------------------------------------------------------------------

handle_keys :: proc(ui: ^p.Ctx, app: ^p.App, st: ^St) {
	// The file dialog owns the keyboard while it is up; it reads its own
	// input in `pick_overlay`, during the draw pass.
	if kit.pick_active(&st.fpick) {
		return
	}
	st.toast_at = min(st.toast_at, f64(p.elapsed(ui)))
	if st.toast_len > 0 && st.toast_at == 0 {
		st.toast_at = f64(p.elapsed(ui))
	}

	// An overlay owns the keyboard while it is up.
	if st.ov != .None {
		overlay_keys(ui, st)
		return
	}

	mods := ui.input.mods

	// Space is a held modifier for panning, as it is in every editor.
	if p.key_pressed(ui, p.KEY_SPACE, false) && !st.spacing {
		st.spacing = true
		st.tool_held = st.tool
		st.tool = .Pan
	}
	if st.spacing && !p.pressed_key(app, p.KEY_SPACE) {
		st.spacing = false
		st.tool = st.tool_held
	}

	if p.shortcut(ui, 'z', {.Ctrl}) {
		if label, ok := hist_undo(&st.hist, &st.doc); ok {
			toast(st, fmt.tprintf("undo %s", label))
		} else {
			toast(st, "nothing to undo")
		}
		return
	}
	if p.shortcut(ui, 'Z', {.Ctrl, .Shift}) || p.shortcut(ui, 'z', {.Ctrl, .Shift}) {
		if label, ok := hist_redo(&st.hist, &st.doc); ok {
			toast(st, fmt.tprintf("redo %s", label))
		} else {
			toast(st, "nothing to redo")
		}
		return
	}

	if p.shortcut(ui, 'n', {.Ctrl}) {
		open_overlay(st, .New_Doc)
		return
	}
	if p.shortcut(ui, 'o', {.Ctrl}) {
		begin_pick(st, .Open)
		return
	}
	if p.shortcut(ui, 's', {.Ctrl}) {
		save_or_ask(st)
		return
	}
	if p.shortcut(ui, 'S', {.Ctrl, .Shift}) || p.shortcut(ui, 's', {.Ctrl, .Shift}) {
		begin_pick(st, .Save_As)
		return
	}
	if p.shortcut(ui, 'q', {.Ctrl}) {
		p.quit_app(app)
		return
	}

	// Layers.
	if p.shortcut(ui, 'N', {.Ctrl, .Shift}) || p.shortcut(ui, 'n', {.Ctrl, .Shift}) {
		add_layer(st)
		return
	}
	if p.shortcut(ui, 'j', {.Ctrl}) {
		duplicate_layer(st)
		return
	}
	if p.shortcut(ui, p.KEY_DELETE, {.Ctrl}) || p.shortcut(ui, p.KEY_BACKSPACE, {.Ctrl}) {
		delete_layer(st)
		return
	}
	if p.shortcut(ui, 'i', {.Ctrl}) {
		run_pixel_op(st, invert_region, "Invert")
		return
	}
	if p.shortcut(ui, 'U', {.Ctrl, .Shift}) || p.shortcut(ui, 'u', {.Ctrl, .Shift}) {
		run_pixel_op(st, desaturate_region, "Desaturate")
		return
	}
	if p.shortcut(ui, 'a', {.Ctrl}) {
		select_all(st)
		toast(st, "select all")
		return
	}
	if p.shortcut(ui, 'd', {.Ctrl}) {
		deselect(st)
		toast(st, "deselect")
		return
	}
	if p.shortcut(ui, '0', {.Ctrl}) {
		do_fit(st)
		toast(st, "fit")
		return
	}
	if p.shortcut(ui, '1', {.Ctrl}) {
		set_zoom(st, 1)
		st.pan = {}
		toast(st, "100%")
		return
	}

	if .Ctrl in mods {
		// Ctrl+PageUp/PageDown reorders, as the menus say.
		if p.key_pressed(ui, p.KEY_PAGE_UP, false) {
			move_layer(st, 1)
			return
		}
		if p.key_pressed(ui, p.KEY_PAGE_DOWN, false) {
			move_layer(st, -1)
			return
		}
		return // any other Ctrl chord is not ours
	}

	// Undo and redo also answer to a single key. Ctrl-Z is the shortcut people
	// expect and it is above; `u` and `y` are here because a one-key undo is
	// genuinely useful while the other hand is on the tablet — and because the
	// compositor build used for recording cannot synthesise a modifier chord,
	// so without them the demo could not show undo at all.
	if p.key_pressed(ui, 'u', false) {
		if label, ok := hist_undo(&st.hist, &st.doc); ok {
			toast(st, fmt.tprintf("undo %s", label))
		} else {
			toast(st, "nothing to undo")
		}
		return
	}
	if p.key_pressed(ui, 'y', false) {
		if label, ok := hist_redo(&st.hist, &st.doc); ok {
			toast(st, fmt.tprintf("redo %s", label))
		} else {
			toast(st, "nothing to redo")
		}
		return
	}

	// Tools.
	if p.key_pressed(ui, 'b', false) {set_tool(st, .Brush)}
	if p.key_pressed(ui, 'e', false) {set_tool(st, .Eraser)}
	if p.key_pressed(ui, 'g', false) {set_tool(st, .Fill)}
	if p.key_pressed(ui, 'i', false) {set_tool(st, .Eyedropper)}
	if p.key_pressed(ui, 'm', false) {set_tool(st, .Select)}
	if p.key_pressed(ui, 'v', false) {set_tool(st, .Move)}
	if p.key_pressed(ui, 'h', false) {set_tool(st, .Pan)}

	// Brush size and hardness.
	if p.key_pressed(ui, '[') {
		st.brush.size = clamp(st.brush.size * 0.8 - 0.5, BRUSH_MIN, BRUSH_MAX)
		toast(st, fmt.tprintf("brush %.0f px", st.brush.size))
	}
	if p.key_pressed(ui, ']') {
		st.brush.size = clamp(st.brush.size * 1.25 + 0.5, BRUSH_MIN, BRUSH_MAX)
		toast(st, fmt.tprintf("brush %.0f px", st.brush.size))
	}
	if p.key_pressed(ui, '{') {
		st.brush.hardness = clamp(st.brush.hardness - 0.1, 0, 1)
		toast(st, fmt.tprintf("hardness %.0f%%", st.brush.hardness * 100))
	}
	if p.key_pressed(ui, '}') {
		st.brush.hardness = clamp(st.brush.hardness + 0.1, 0, 1)
		toast(st, fmt.tprintf("hardness %.0f%%", st.brush.hardness * 100))
	}

	// Opacity on the number row, Photoshop's own mapping.
	for n in 0 ..= 9 {
		if p.key_pressed(ui, u32('0' + n), false) {
			st.brush.opacity = n == 0 ? 1 : f32(n) / 10
			toast(st, fmt.tprintf("opacity %.0f%%", st.brush.opacity * 100))
		}
	}

	// Colour.
	if p.key_pressed(ui, 'x', false) {
		st.fg, st.bg = st.bg, st.fg
		sync_picker_from(st, st.fg)
		toast(st, "swapped colours")
	}
	if p.key_pressed(ui, 'd', false) {
		st.fg, st.bg = 0xff_000000, 0xff_ffffff
		sync_picker_from(st, st.fg)
		toast(st, "default colours")
	}
	if p.key_pressed(ui, 'c', false) {
		st.pick_bg = false
		sync_picker_from(st, st.fg)
		open_overlay(st, .Picker)
		return
	}

	// Menus and dialogs.
	if p.key_pressed(ui, 'a', false) {
		open_overlay(st, .Adjust_Menu)
		return
	}
	if p.key_pressed(ui, 'f', false) {
		open_overlay(st, .Filter_Menu)
		return
	}
	if p.key_pressed(ui, 'l', false) {
		open_overlay(st, .Layer_Menu)
		return
	}
	if p.key_pressed(ui, 'o', false) {
		begin_pick(st, .Open)
		return
	}
	if p.key_pressed(ui, 'r', false) {
		start_rename(st)
		return
	}
	if p.key_pressed(ui, '?', false) || p.key_pressed(ui, p.KEY_F1, false) {
		open_overlay(st, .Help)
		return
	}

	// Zoom.
	if p.key_pressed(ui, '+') || p.key_pressed(ui, '=') || p.key_pressed(ui, KEY_KP_ADD) {
		set_zoom(st, st.zoom * ZOOM_STEP)
	}
	if p.key_pressed(ui, '-') || p.key_pressed(ui, KEY_KP_SUB) {
		set_zoom(st, st.zoom / ZOOM_STEP)
	}

	// Layer selection, and nudging the active layer.
	if p.key_pressed(ui, p.KEY_PAGE_UP, false) {
		st.doc.active = min(st.doc.active + 1, len(st.doc.order) - 1)
	}
	if p.key_pressed(ui, p.KEY_PAGE_DOWN, false) {
		st.doc.active = max(st.doc.active - 1, 0)
	}
	if p.key_pressed(ui, '/', false) {
		toggle_visible(st)
	}
	if p.key_pressed(ui, ';') {
		nudge_opacity(st, -0.1)
	}
	if p.key_pressed(ui, '\'') {
		nudge_opacity(st, 0.1)
	}
	if p.key_pressed(ui, ',', false) {
		cycle_blend(st, -1)
	}
	if p.key_pressed(ui, '.', false) {
		cycle_blend(st, 1)
	}

	// Arrows are the keyboard's pointer. With the Move tool they nudge the
	// layer, which is what a drag with that tool does; with every other tool
	// they move the keyboard cursor, and Return acts with the current tool
	// where it sits. That is what makes an editor usable without a mouse —
	// painting included.
	dx := p.key_count(ui, p.KEY_RIGHT) - p.key_count(ui, p.KEY_LEFT)
	dy := p.key_count(ui, p.KEY_DOWN) - p.key_count(ui, p.KEY_UP)
	if dx != 0 || dy != 0 {
		if st.tool == .Move {
			k := .Shift in mods ? 10 : 1
			nudge_layer(st, dx * k, dy * k)
		} else {
			kb_move(st, dx, dy, .Shift in mods)
		}
	}

	if p.key_pressed(ui, p.KEY_RETURN, false) || p.key_pressed(ui, p.KEY_KP_ENTER, false) {
		kb_act(st)
	}

	if p.key_pressed(ui, p.KEY_ESCAPE, false) {
		if st.kb_live {
			kb_end_stroke(st)
		} else if st.kb_sel {
			st.kb_sel = false
		} else if st.has_sel {
			deselect(st)
			toast(st, "deselect")
		}
	}
}

// ---------------------------------------------------------------------------
// The keyboard cursor
// ---------------------------------------------------------------------------

kb_center :: proc(st: ^St) {
	st.kb = {f32(st.doc.w) / 2, f32(st.doc.h) / 2}
	st.kb_live = false
	st.kb_sel = false
}

// kb_step is the distance one arrow press covers. While a stroke is down it is
// the brush diameter, so consecutive presses lay overlapping dabs and the
// interpolation between them is the thing doing the work — exactly as a fast
// pointer drag would.
kb_step :: proc(st: ^St) -> f32 {
	if st.kb_live {
		return clamp(st.brush.size, 8, 96)
	}
	return 24
}

kb_move :: proc(st: ^St, dx, dy: int, big: bool) {
	d := &st.doc
	step := kb_step(st) * (big ? 4 : 1)
	st.kb.x = clamp(st.kb.x + f32(dx) * step, 0, f32(d.w))
	st.kb.y = clamp(st.kb.y + f32(dy) * step, 0, f32(d.h))

	if st.kb_live {
		r := stroke_to(&st.stroke, d, st.brush, st.kb, st.fg, clip_rect(st))
		layer_touch(d, st.stroke.pool, r)
	}
	if st.kb_sel {
		st.sel = rect_i_clip(
			{
				int(min(st.kb_anchor.x, st.kb.x)),
				int(min(st.kb_anchor.y, st.kb.y)),
				int(max(st.kb_anchor.x, st.kb.x)),
				int(max(st.kb_anchor.y, st.kb.y)),
			},
			d.w,
			d.h,
		)
		st.has_sel = !rect_i_empty(st.sel)
	}
}

kb_end_stroke :: proc(st: ^St) {
	if !st.kb_live {
		return
	}
	st.kb_live = false
	pool, bbox, base, ok := stroke_end(&st.stroke)
	if ok {
		push_pixel_edit(
			&st.hist,
			&st.doc,
			pool,
			bbox,
			copy_region(base, st.doc.w, bbox),
			st.tool == .Eraser ? "Erase" : "Brush",
		)
		toast(st, fmt.tprintf("stroke: %d samples, %d stamps", st.stroke.samples, st.stroke.stamps))
	}
}

// kb_act is Return: the keyboard's click.
kb_act :: proc(st: ^St) {
	d := &st.doc
	switch st.tool {
	case .Brush, .Eraser:
		if st.kb_live {
			kb_end_stroke(st)
			return
		}
		if st.drag {
			return
		}
		stroke_begin(&st.stroke, d, st.tool == .Eraser)
		st.kb_live = true
		r := stroke_to(&st.stroke, d, st.brush, st.kb, st.fg, clip_rect(st))
		layer_touch(d, st.stroke.pool, r)
		toast(st, "painting \u2014 arrows draw, Return lifts the brush")
	case .Fill:
		do_fill(st, int(st.kb.x), int(st.kb.y))
	case .Eyedropper:
		pick_at(st, int(st.kb.x), int(st.kb.y))
	case .Select:
		if st.kb_sel {
			st.kb_sel = false
			toast(st, fmt.tprintf("selection %d x %d", st.sel.x1 - st.sel.x0, st.sel.y1 - st.sel.y0))
			return
		}
		st.kb_sel = true
		st.kb_anchor = st.kb
		st.sel = {int(st.kb.x), int(st.kb.y), int(st.kb.x), int(st.kb.y)}
		toast(st, "selecting \u2014 arrows size it, Return finishes")
	case .Move:
		toast(st, "arrows nudge the active layer")
	case .Pan:
		do_fit(st)
		toast(st, "fit")
	}
}

set_tool :: proc(st: ^St, t: Tool) {
	if st.tool == t {
		return
	}
	// A keyboard stroke belongs to the tool that started it.
	kb_end_stroke(st)
	st.kb_sel = false
	st.tool = t
	st.tool_held = t
	toast(st, TOOL_NAMES[t])
}

// nudge_layer is the keyboard half of the Move tool: the same code path the
// drag takes, so a nudge and a drag produce the same history entry shape.
nudge_layer :: proc(st: ^St, dx, dy: int) {
	d := &st.doc
	pool := active_pool(d)
	if pool < 0 {
		return
	}
	sel := st.has_sel ? rect_i_clip(st.sel, d.w, d.h) : Rect_I{}
	r := moved_bounds(sel, d.w, d.h, dx, dy)
	before := copy_region(d.pool[pool].px, d.w, r)

	base := make([]u32, d.w * d.h, context.temp_allocator)
	copy(base, d.pool[pool].px)
	if st.has_sel {
		translate_region(d.pool[pool].px, base, d.w, d.h, sel, dx, dy)
		st.sel = {sel.x0 + dx, sel.y0 + dy, sel.x1 + dx, sel.y1 + dy}
	} else {
		translate_layer(d.pool[pool].px, base, d.w, d.h, dx, dy)
	}
	layer_touch(d, pool, {0, 0, d.w, d.h})
	push_pixel_edit(&st.hist, d, pool, r, before, "Move")
}

// ---------------------------------------------------------------------------
// Pointer on the canvas
// ---------------------------------------------------------------------------

// canvas_input is the pointer half of every tool. palmy reports press, hold and
// release against the previous frame's geometry, which is all a drag needs: the
// press frame starts the gesture, every frame with the button down extends it,
// and the frame the button comes up commits it to history.
canvas_input :: proc(ui: ^p.Ctx, st: ^St, idx: int) {
	d := &st.doc
	hot := p.is_hovered(ui, idx)
	act := p.is_active(ui, idx)
	st.over_canvas = hot
	st.cursor_doc = screen_to_doc(st, st.mouse)

	if wh := p.wheel(ui); wh.y != 0 && hot {
		if .Ctrl in ui.input.mods {
			set_zoom(st, st.zoom * math.pow(ZOOM_STEP, wh.y))
		} else {
			st.pan.y += wh.y * 40
			st.pan.x += wh.x * 40
		}
	}

	pt := st.cursor_doc

	if act && !st.drag {
		// Press. A keyboard stroke owns the same buffers, so it ends here.
		kb_end_stroke(st)
		st.drag = true
		st.drag_kind = st.tool
		st.from_doc = pt
		st.from_scr = st.mouse
		st.from_pan = st.pan
		switch st.tool {
		case .Brush:
			stroke_begin(&st.stroke, d, false)
			r := stroke_to(&st.stroke, d, st.brush, pt, st.fg, clip_rect(st))
			layer_touch(d, st.stroke.pool, r)
		case .Eraser:
			stroke_begin(&st.stroke, d, true)
			r := stroke_to(&st.stroke, d, st.brush, pt, st.fg, clip_rect(st))
			layer_touch(d, st.stroke.pool, r)
		case .Fill:
			do_fill(st, int(pt.x), int(pt.y))
			st.drag = false
		case .Eyedropper:
			pick_at(st, int(pt.x), int(pt.y))
		case .Select:
			st.sel = {int(pt.x), int(pt.y), int(pt.x), int(pt.y)}
			st.has_sel = false
		case .Move:
			pool := active_pool(d)
			if pool >= 0 {
				if len(st.move_base) != d.w * d.h {
					delete(st.move_base)
					st.move_base = make([]u32, d.w * d.h)
				}
				copy(st.move_base, d.pool[pool].px)
				st.move_pool = pool
				st.move_off = {}
			}
		case .Pan:
		}
		return
	}

	if st.drag && act {
		// Hold.
		switch st.drag_kind {
		case .Brush, .Eraser:
			r := stroke_to(&st.stroke, d, st.brush, pt, st.fg, clip_rect(st))
			layer_touch(d, st.stroke.pool, r)
		case .Eyedropper:
			pick_at(st, int(pt.x), int(pt.y))
		case .Select:
			st.sel = {
				int(math.floor(min(st.from_doc.x, pt.x))),
				int(math.floor(min(st.from_doc.y, pt.y))),
				int(math.ceil(max(st.from_doc.x, pt.x))),
				int(math.ceil(max(st.from_doc.y, pt.y))),
			}
			st.sel = rect_i_clip(st.sel, d.w, d.h)
			st.has_sel = !rect_i_empty(st.sel)
		case .Move:
			if st.move_pool >= 0 {
				dx := int(math.round(pt.x - st.from_doc.x))
				dy := int(math.round(pt.y - st.from_doc.y))
				if dx != st.move_off.x || dy != st.move_off.y {
					st.move_off = {dx, dy}
					sel := st.has_sel ? rect_i_clip(st.sel, d.w, d.h) : Rect_I{}
					if st.has_sel {
						translate_region(d.pool[st.move_pool].px, st.move_base, d.w, d.h, sel, dx, dy)
					} else {
						translate_layer(d.pool[st.move_pool].px, st.move_base, d.w, d.h, dx, dy)
					}
					layer_touch(d, st.move_pool, {0, 0, d.w, d.h})
				}
			}
		case .Pan:
			st.pan = st.from_pan + (st.mouse - st.from_scr)
			st.want_fit = false
		case .Fill:
		}
		return
	}

	if st.drag && !act {
		// Release.
		st.drag = false
		switch st.drag_kind {
		case .Brush, .Eraser:
			pool, bbox, base, ok := stroke_end(&st.stroke)
			if ok {
				before := copy_region(base, d.w, bbox)
				push_pixel_edit(
					&st.hist,
					d,
					pool,
					bbox,
					before,
					st.drag_kind == .Eraser ? "Erase" : "Brush",
				)
			}
		case .Move:
			if st.move_pool >= 0 && (st.move_off.x != 0 || st.move_off.y != 0) {
				sel := st.has_sel ? rect_i_clip(st.sel, d.w, d.h) : Rect_I{}
				r := moved_bounds(sel, d.w, d.h, st.move_off.x, st.move_off.y)
				before := copy_region(st.move_base, d.w, r)
				push_pixel_edit(&st.hist, d, st.move_pool, r, before, "Move")
				if st.has_sel {
					st.sel = {
						sel.x0 + st.move_off.x,
						sel.y0 + st.move_off.y,
						sel.x1 + st.move_off.x,
						sel.y1 + st.move_off.y,
					}
				}
			}
			st.move_pool = -1
		case .Select:
			if rect_i_area(st.sel) < 4 {
				deselect(st)
			} else {
				toast(st, fmt.tprintf("selection %dx%d", st.sel.x1 - st.sel.x0, st.sel.y1 - st.sel.y0))
			}
		case .Fill, .Eyedropper, .Pan:
		}
	}
}

do_fill :: proc(st: ^St, x, y: int) {
	d := &st.doc
	pool := active_pool(d)
	if pool < 0 || x < 0 || y < 0 || x >= d.w || y >= d.h {
		return
	}
	clip := clip_rect(st)
	// The tolerance test runs against the layer's own pixels, so a fill behaves
	// the same whether the layers below it are visible or not.
	before_full := make([]u32, d.w * d.h, context.temp_allocator)
	copy(before_full, d.pool[pool].px)

	color := pack_argb(
		u8((st.fg >> 16) & 0xff),
		u8((st.fg >> 8) & 0xff),
		u8(st.fg & 0xff),
		u8(clamp(f32((st.fg >> 24) & 0xff) * st.brush.opacity + 0.5, 0, 255)),
	)
	r := flood_fill(d.pool[pool].px, d.w, d.h, x, y, color, u32(st.brush.flow_tol), clip, &st.fill_stack)
	if rect_i_empty(r) {
		toast(st, "nothing to fill there")
		return
	}
	before := copy_region(before_full, d.w, r)
	layer_touch(d, pool, r)
	push_pixel_edit(&st.hist, d, pool, r, before, "Fill")
	toast(st, fmt.tprintf("filled %d px", rect_i_area(r)))
}

pick_at :: proc(st: ^St, x, y: int) {
	d := &st.doc
	if x < 0 || y < 0 || x >= d.w || y >= d.h {
		return
	}
	// The eyedropper samples the composite, which is what the user sees.
	v := d.comp[y * d.w + x]
	if (v >> 24) & 0xff == 0 {
		return
	}
	v |= 0xff00_0000
	if st.pick_bg {
		st.bg = v
	} else {
		st.fg = v
	}
	sync_picker_from(st, v)
	toast(st, hex_string(v, context.temp_allocator))
}

sync_picker_from :: proc(st: ^St, v: u32) {
	r, g, b, _ := unpack_argb(v)
	st.pick_h, st.pick_s, st.pick_v = rgb_to_hsv(f32(r) / 255, f32(g) / 255, f32(b) / 255)
}

picker_color :: proc(st: ^St) -> u32 {
	r, g, b := hsv_to_rgb(st.pick_h, st.pick_s, st.pick_v)
	return pack_argb(
		u8(clamp(r * 255 + 0.5, 0, 255)),
		u8(clamp(g * 255 + 0.5, 0, 255)),
		u8(clamp(b * 255 + 0.5, 0, 255)),
		255,
	)
}
