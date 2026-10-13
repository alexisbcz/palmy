// frame.odin — the server-side decorations: their geometry, what a point on
// them means, and how they are drawn.
//
// Geometry and hit testing are one table, because what the pointer can do at
// a point and what the frame shows there must never disagree. The frame is
// the title bar plus a border; around it, outside the visible frame, is an
// invisible 8 px resize margin (part of the shadow), so an edge is easy to
// catch without a frame that is fat to look at (UX.md P0-6). Corners are
// 16 px L-shaped areas. A tiled window offers only the edges that mean
// something to the layout — the master/stack boundary — and a maximized,
// fullscreen or fixed-size window offers none.
//
// Drawing follows UX.md P0-9: focused and unfocused frames differ in title
// bar colour, text colour, outline and shadow, so focus reads at a glance;
// floating windows have 10 px rounded corners that clip the client's own
// pixels; maximized and tiled windows are square and shadowless.
package wm

import "core:fmt"
import "core:math"
import "core:strings"
import "core:unicode/utf8"
import p "palmy:."

RESIZE_OUT :: 8 // invisible margin outside the frame
RESIZE_IN :: 4 // band inside the frame on the sides, bottom and title top
RESIZE_CORNER :: 16
FRAME_RADIUS :: 10

BTN_W :: 28
BTN_H :: 24
BTN_GAP :: 2
BTN_PAD :: 6

Frame_Btn :: enum u8 {
	None,
	Close,
	Maximize,
	Minimize,
}

Region :: enum u8 {
	None,
	Title,
	Content,
	Close,
	Maximise,
	Minimise,
	Edge,
}

region_of_btn :: proc(b: Frame_Btn) -> Region {
	switch b {
	case .Close:
		return .Close
	case .Maximize:
		return .Maximise
	case .Minimize:
		return .Minimise
	case .None:
	}
	return .None
}

btn_of_region :: proc(r: Region) -> Frame_Btn {
	#partial switch r {
	case .Close:
		return .Close
	case .Maximise:
		return .Maximize
	case .Minimise:
		return .Minimize
	}
	return .None
}

// ---------------------------------------------------------------------------
// Geometry
// ---------------------------------------------------------------------------

content_rect :: proc(t: ^Toplevel) -> p.Rect {
	return {f32(t.x), f32(t.y), f32(t.w), f32(t.h)}
}

// The title bar height and the border width come from the config, and a rule
// can switch either off for one application, so these are per window.
title_rect :: proc(t: ^Toplevel) -> p.Rect {
	bw := ws_border(t)
	th := ws_title_h(t)
	return {f32(t.x - bw), f32(t.y - th), f32(t.w + 2 * bw), f32(th)}
}

frame_rect :: proc(t: ^Toplevel) -> p.Rect {
	bw := ws_border(t)
	th := ws_title_h(t)
	return {f32(t.x - bw), f32(t.y - th), f32(t.w + 2 * bw), f32(t.h + th + bw)}
}

// frame_buttons_extent is how much of the title bar the buttons take on each
// side, which is what the title text and a drag's grab point must avoid.
frame_buttons_extent :: proc(t: ^Toplevel) -> (left, right: int) {
	n := server.cfg.buttons_n
	if n == 0 || ws_title_h(t) == 0 {
		return 0, 0
	}
	w := BTN_PAD + n * BTN_W + (n - 1) * BTN_GAP
	if server.cfg.buttons_left {
		return w, 0
	}
	return 0, w
}

// frame_btn_rect is the hit target of one frame button (28 x 24, larger than
// its 16 px glyph), laid out in the configured order (`buttons =`).
frame_btn_rect :: proc(t: ^Toplevel, which: Frame_Btn) -> (p.Rect, bool) {
	c := &server.cfg
	if ws_title_h(t) == 0 {
		return {}, false
	}
	tr := title_rect(t)
	n := c.buttons_n
	for i in 0 ..< n {
		if c.buttons[i] != which {
			continue
		}
		x: f32
		if c.buttons_left {
			x = tr.x + BTN_PAD + f32(i * (BTN_W + BTN_GAP))
		} else {
			x = tr.x + tr.w - BTN_PAD - f32((n - i) * BTN_W + (n - 1 - i) * BTN_GAP)
		}
		return {x, tr.y + (tr.h - BTN_H) / 2, BTN_W, BTN_H}, true
	}
	return {}, false
}

// button_rect is the old name for the same thing, by the old numbering
// (0 close, 1 maximise, 2 minimise), which the offscreen shots still use.
button_rect :: proc(t: ^Toplevel, which: int) -> p.Rect {
	b := which == 0 ? Frame_Btn.Close : (which == 1 ? Frame_Btn.Maximize : Frame_Btn.Minimize)
	r, _ := frame_btn_rect(t, b)
	return r
}

frame_btn_enabled :: proc(t: ^Toplevel, b: Frame_Btn) -> bool {
	if b == .Maximize {
		return !win_fixed(t)
	}
	return true
}

// tile_split_edges are the edges of a tiled window that resize the layout
// rather than the window: the master column's right edge and the stack
// column's left edge, in the master layout. Every other edge of a tiled
// window is fixed by its neighbours or the screen.
tile_split_edges :: proc(s: ^Server, t: ^Toplevel) -> Edges {
	idx := ws_index_of(s, t)
	if idx < 0 {
		return {}
	}
	ws := &s.workspaces[idx]
	if !ws.tiling || tile_layout_name(ws.layout) != "master" {
		return {}
	}
	wins := tile_windows(s, idx)
	mc := clamp(ws.master_count, 1, max(len(wins), 1))
	if len(wins) <= mc {
		return {}
	}
	for w, i in wins {
		if w == t {
			return i < mc ? {.Right} : {.Left}
		}
	}
	return {}
}

// frame_edges_allowed is the set of edges the pointer may resize from.
frame_edges_allowed :: proc(s: ^Server, t: ^Toplevel) -> Edges {
	if t.maximized || ws_fullscreen(t) || win_fixed(t) || session.kiosk {
		return {}
	}
	if ws_in_layout(s, t) {
		return tile_split_edges(s, t)
	}
	return {.Left, .Right, .Top, .Bottom}
}

// frame_edges_at is the pure part of the hit test: which resize edges a
// point selects, for a frame rectangle. Outside the frame the margin is
// `outer` px; inside it is `inner` px on the sides and bottom and along the
// top of the title bar. Corners widen to `corner` px along both edges.
frame_edges_at :: proc(fr: p.Rect, px, py: f32, outer, inner, corner: f32) -> (Edges, bool) {
	o := p.rect_inset(fr, -outer)
	if !p.rect_contains(o, px, py) {
		return {}, false
	}
	e: Edges
	if px < fr.x + inner {e += {.Left}}
	if px >= fr.x + fr.w - inner {e += {.Right}}
	if py < fr.y + inner {e += {.Top}}
	if py >= fr.y + fr.h - inner {e += {.Bottom}}
	if e == {} {
		return {}, true
	}
	// The L-shaped corners: a point on one edge band near the other edge
	// takes both.
	if .Left in e || .Right in e {
		if py < fr.y + corner {e += {.Top}}
		if py >= fr.y + fr.h - corner {e += {.Bottom}}
	}
	if .Top in e || .Bottom in e {
		if px < fr.x + corner {e += {.Left}}
		if px >= fr.x + fr.w - corner {e += {.Right}}
	}
	return e, true
}

hit_window :: proc(s: ^Server, t: ^Toplevel, mx, my: int) -> (Region, Edges) {
	px := f32(mx)
	py := f32(my)
	fr := frame_rect(t)
	allowed := frame_edges_allowed(s, t)
	outer := f32(allowed == {} ? 0 : RESIZE_OUT)
	// A tiled window's margin must not reach into its neighbour across a
	// 6 px gap; half the gap is its own.
	if ws_in_layout(s, t) && allowed != {} {
		outer = f32(max(s.cfg.gaps_in / 2, 2))
	}
	e, near := frame_edges_at(fr, px, py, outer, RESIZE_IN, RESIZE_CORNER)
	if !near {
		return .None, {}
	}
	inside := p.rect_contains(fr, px, py)
	if e != {} {
		e &= allowed
		if e != {} {
			return .Edge, e
		}
		if !inside {
			return .None, {}
		}
	}
	if !inside {
		return .None, {}
	}
	for b in ([3]Frame_Btn{.Close, .Maximize, .Minimize}) {
		if r, ok := frame_btn_rect(t, b); ok && p.rect_contains(r, px, py) {
			return region_of_btn(b), {}
		}
	}
	if p.rect_contains(title_rect(t), px, py) && ws_title_h(t) > 0 {
		return .Title, {}
	}
	return .Content, {}
}

window_at :: proc(s: ^Server, mx, my: int) -> (^Toplevel, Region, Edges) {
	// A window lifted over the floating ones (ix_reveal) is hit where it is
	// drawn: on top.
	if t := ix_lifted(s); t != nil {
		if r, e := hit_window(s, t, mx, my); r != .None {
			return t, r, e
		}
	}
	#reverse for t in s.stack {
		if !t.mapped || t.minimized {
			continue
		}
		if r, e := hit_window(s, t, mx, my); r != .None {
			return t, r, e
		}
	}
	return nil, .None, {}
}

// ---------------------------------------------------------------------------
// Colours (UX.md P0-9)
// ---------------------------------------------------------------------------

DESK_TOP :: 0x0b1020
DESK_BOT :: 0x1e1b4b
BAR_BG :: 0x0a0a0c
FRAME_ON :: 0x27272a
FRAME_OFF :: 0x18181b
TEXT_ON :: 0xfafafa
TEXT_OFF :: 0x71717a
ACCENT :: 0x6366f1

// with_alpha mixes an 0xRRGGBB colour with an alpha in 0..1.
with_alpha :: proc(rgb: u32, a: f32) -> p.Color {
	c := p.hex(rgb)
	c.a = u8(clamp(a, 0, 1) * 255 + 0.5)
	return c
}

// app_hue is a stable colour per application, for the monogram icon.
app_hue :: proc(key: string) -> u32 {
	PALETTE := [?]u32{0x6366f1, 0x0ea5e9, 0x10b981, 0xf59e0b, 0xef4444, 0xa855f7, 0x14b8a6, 0xec4899}
	h := u32(2166136261)
	for c in transmute([]u8)key {
		h = (h ~ u32(c)) * 16777619
	}
	return PALETTE[h % len(PALETTE)]
}

// app_letter is the monogram: the first letter of the app's name, skipping
// a "palmy-" or reverse-DNS prefix, so palmy-term reads T and org.foo.Bar B.
app_letter :: proc(t: ^Toplevel) -> string {
	src := t.app_id != "" ? t.app_id : t.title
	if i := strings.last_index_byte(src, '.'); i >= 0 && i + 1 < len(src) {
		src = src[i + 1:]
	}
	src = strings.trim_prefix(src, "palmy-")
	for r in src {
		if (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') || (r >= '0' && r <= '9') {
			buf: [4]u8
			up := r >= 'a' && r <= 'z' ? r - 32 : r
			b, n := utf8.encode_rune(up)
			copy(buf[:], b[:n])
			return strings.clone(string(buf[:n]), context.temp_allocator)
		}
	}
	return "?"
}

// draw_app_icon draws a window's icon: a rounded monogram in the app's hue.
// (A .desktop Icon= lookup would decode SVGs on the compositor's thread for
// a 16 px square; the monogram is the spec's fallback and costs nothing.)
draw_app_icon :: proc(cv: ^p.Canvas, f: ^p.Fonts, t: ^Toplevel, x, y, size: f32, alpha: f32 = 1) {
	key := t.app_id != "" ? t.app_id : t.title
	col := with_alpha(app_hue(key), alpha)
	p.fill_round_rect(cv, {x, y, size, size}, {size * 0.28, size * 0.28, size * 0.28, size * 0.28}, col)
	l := app_letter(t)
	fs := size * 0.62
	w := p.text_width(f, l, fs, .Sans, .Bold)
	p.draw_text(cv, f, l, x + (size - w) / 2, y + size * 0.5 + fs * 0.36, fs, with_alpha(0xffffff, alpha * 0.95), .Sans, .Bold)
}

// ellipsize_middle shortens text to fit `avail` by cutting its middle, so
// both the document name and the app name survive:
// "Documents — …report.txt".
ellipsize_middle :: proc(f: ^p.Fonts, text: string, size: f32, wt: p.Font_Weight, avail: f32) -> string {
	if p.text_width(f, text, size, .Sans, wt) <= avail {
		return text
	}
	runes := utf8.string_to_runes(text, context.temp_allocator)
	n := len(runes)
	if n <= 2 || avail <= 0 {
		return ""
	}
	keep := n - 1
	for keep > 1 {
		head := (keep + 1) / 2
		tail := keep - head
		s := fmt.tprintf("%s…%s", utf8.runes_to_string(runes[:head], context.temp_allocator), utf8.runes_to_string(runes[n - tail:], context.temp_allocator))
		if p.text_width(f, s, size, .Sans, wt) <= avail {
			return s
		}
		keep -= 1
	}
	return "…"
}

// ellipsize_end is the taskbar's flavour: there the start of the title is
// what tells entries apart.
ellipsize_end :: proc(f: ^p.Fonts, text: string, size: f32, wt: p.Font_Weight, avail: f32) -> string {
	if p.text_width(f, text, size, .Sans, wt) <= avail {
		return text
	}
	runes := utf8.string_to_runes(text, context.temp_allocator)
	for k := len(runes) - 1; k > 0; k -= 1 {
		s := fmt.tprintf("%s…", utf8.runes_to_string(runes[:k], context.temp_allocator))
		if p.text_width(f, s, size, .Sans, wt) <= avail {
			return s
		}
	}
	return ""
}

// ---------------------------------------------------------------------------
// Drawing
// ---------------------------------------------------------------------------

// frame_flat says whether a window is drawn square and without a shadow:
// maximized, fullscreen and tiled windows sit edge to edge with their
// neighbours or the screen, and rounded corners there are only gaps.
frame_flat :: proc(s: ^Server, t: ^Toplevel) -> bool {
	return t.maximized || ws_fullscreen(t) || ws_in_layout(s, t)
}

draw_window :: proc(s: ^Server, app: ^p.App, cv: ^p.Canvas, t: ^Toplevel, shadow := true) {
	// A kiosk client is the whole screen: no shadow, no ring, no frame.
	if session.kiosk || ws_fullscreen(t) {
		p.push_clip(cv, content_rect(t))
		if t.xdg != nil && t.xdg.surf != nil {
			blit_surface(cv, t.xdg.surf, t.x, t.y)
		}
		p.pop_clip(cv)
		return
	}
	f := &app.fonts
	focused := s.focus == t
	fr := frame_rect(t)
	th := f32(ws_title_h(t))
	bw := f32(ws_border(t))
	flat := frame_flat(s, t)
	r := f32(flat ? 0 : FRAME_RADIUS)
	m := ws_win(t)

	if shadow && !flat {
		if focused {
			ring_shadow(cv, fr, {r, r, r, r}, 32, 0, {0, 12}, p.hexa(0x0000008c))
			p.stroke_round_rect(cv, p.rect_inset(fr, -1), {r + 1, r + 1, r + 1, r + 1}, 1, with_alpha(s.cfg.border_focus, 0.15))
		} else {
			ring_shadow(cv, fr, {r, r, r, r}, 12, 0, {0, 4}, p.hexa(0x00000059))
		}
	}

	// Frame plate. Only the title bar and the border are painted: the
	// client's own pixels cover everything inside.
	plate := p.hex(focused ? FRAME_ON : FRAME_OFF)
	if th > 0 {
		p.fill_round_rect(cv, {fr.x, fr.y, fr.w, th + 2}, {r, r, 0, 0}, plate)
	}
	edge := focused ? with_alpha(s.cfg.border_focus, 0.7) : p.hex(s.cfg.border_unfocus)
	if bw > 0 && flat {
		p.fill_rect(cv, {fr.x, f32(t.y), bw, f32(t.h) + bw}, edge)
		p.fill_rect(cv, {f32(t.x + t.w), f32(t.y), bw, f32(t.h) + bw}, edge)
		p.fill_rect(cv, {fr.x, f32(t.y + t.h), fr.w, bw}, edge)
	}

	// Client pixels, with the frame's rounded bottom corners cut out of them
	// (and the top ones too when a rule removed the title bar).
	if t.xdg != nil && t.xdg.surf != nil {
		cr := content_rect(t)
		blit_rounded(cv, t.xdg.surf, t.x, t.y, cr, th > 0 ? 0 : r, r)
	}

	if th > 0 {
		draw_title(s, app, cv, t, focused)
	}

	// Outline last, so it sits over both the bar and the client pixels.
	p.stroke_round_rect(cv, fr, {r, r, r, r}, 1, edge)
	_ = m
}

draw_title :: proc(s: ^Server, app: ^p.App, cv: ^p.Canvas, t: ^Toplevel, focused: bool) {
	f := &app.fonts
	tr := title_rect(t)
	m := ws_win(t)
	if focused {
		p.fill_rect(cv, {tr.x + 1, tr.y + tr.h - 1, tr.w - 2, 1}, p.hex(0x3f3f46))
	} else {
		p.fill_rect(cv, {tr.x + 1, tr.y + tr.h - 1, tr.w - 2, 1}, p.hex(0x27272a))
	}

	// The title is centred on the frame with the icon to its left, and
	// shortened in the middle rather than run into the buttons.
	bl, br := frame_buttons_extent(t)
	side := f32(max(bl, br) + 8)
	pin_w := f32(m.on_top ? 18 : 0)
	avail := tr.w - 2 * side - 22 - pin_w
	size := f32(12.5)
	label := ellipsize_middle(f, title_of(t), size, .Semibold, avail)
	tw := p.text_width(f, label, size, .Sans, .Semibold)
	total := 16 + 6 + tw + pin_w
	x := tr.x + (tr.w - total) / 2
	x = max(x, tr.x + f32(bl) + 8)
	cy := tr.y + tr.h / 2
	p.push_clip(cv, tr)
	draw_app_icon(cv, f, t, x, cy - 8, 16, focused ? 1 : 0.55)
	x += 22
	p.draw_text(cv, f, label, x, cy + 4.5, size, p.hex(focused ? TEXT_ON : TEXT_OFF), .Sans, .Semibold)
	if m.on_top {
		draw_pin(cv, x + tw + 8, cy - 6, focused ? 0xa5b4fc : 0x71717a)
	}
	p.pop_clip(cv)

	for b in ([3]Frame_Btn{.Close, .Maximize, .Minimize}) {
		if rr, ok := frame_btn_rect(t, b); ok {
			draw_frame_btn(s, cv, t, b, rr, focused)
		}
	}
}

// draw_pin is the always-on-top marker in the title bar.
draw_pin :: proc(cv: ^p.Canvas, x, y: f32, col: u32) {
	c := p.hex(col)
	p.fill_circle(cv, x + 5, y + 4, 3.2, c)
	p.draw_line(cv, x + 5, y + 6, x + 5, y + 12, 1.4, c)
	p.draw_line(cv, x + 1.5, y + 7.5, x + 8.5, y + 7.5, 1.4, c)
}

// draw_frame_btn draws one button in its state: rest, hover, pressed or
// disabled (UX.md P0-8). Unfocused windows' buttons stay visible at 60%.
draw_frame_btn :: proc(s: ^Server, cv: ^p.Canvas, t: ^Toplevel, b: Frame_Btn, r: p.Rect, focused: bool) {
	enabled := frame_btn_enabled(t, b)
	hot := enabled && s.hover_t == t && s.hover_btn == int(b)
	down := hot && ix.mode == .Button && ix.t == t && ix.btn_down == b
	plate := r
	plate.x += 1
	plate.w -= 2
	plate.y += 1
	plate.h -= 2
	glyph := u32(0xa1a1aa)
	alpha := f32(focused ? 1 : 0.6)
	switch {
	case !enabled:
		alpha *= 0.35
	case hot && b == .Close:
		p.fill_round_rect(cv, plate, {6, 6, 6, 6}, p.hex(down ? 0xb20008 : 0xe7000b))
		glyph = 0xffffff
		alpha = 1
	case hot:
		p.fill_round_rect(cv, plate, {6, 6, 6, 6}, p.hexa(down ? 0xffffff0d : 0xffffff1a))
		glyph = 0xfafafa
		alpha = 1
	}
	gl := with_alpha(glyph, alpha)
	cx := r.x + r.w / 2
	cy := r.y + r.h / 2
	switch b {
	case .Close:
		p.draw_line(cv, cx - 4, cy - 4, cx + 4, cy + 4, 1.3, gl)
		p.draw_line(cv, cx + 4, cy - 4, cx - 4, cy + 4, 1.3, gl)
	case .Maximize:
		if t.maximized {
			// Restore: two overlapping squares.
			p.stroke_round_rect(cv, {cx - 4.5, cy - 2.5, 7, 7}, {1.5, 1.5, 1.5, 1.5}, 1.2, gl)
			p.draw_line(cv, cx - 2, cy - 4.5, cx + 4.5, cy - 4.5, 1.2, gl)
			p.draw_line(cv, cx + 4.5, cy - 4.5, cx + 4.5, cy + 2, 1.2, gl)
		} else {
			p.stroke_round_rect(cv, {cx - 4.5, cy - 4.5, 9, 9}, {1.5, 1.5, 1.5, 1.5}, 1.2, gl)
		}
	case .Minimize:
		p.draw_line(cv, cx - 4.5, cy + 0.5, cx + 4.5, cy + 0.5, 1.3, gl)
	case .None:
	}
}

frame_btn_label :: proc(s: ^Server, t: ^Toplevel, b: Frame_Btn) -> string {
	switch b {
	case .Close:
		return label_with_key(s, "Close", .Close, 0)
	case .Maximize:
		return label_with_key(s, t.maximized ? "Restore" : "Maximize", .Toggle_Maximize, 0)
	case .Minimize:
		return label_with_key(s, "Minimize", .Minimize, 0)
	case .None:
	}
	return ""
}

// draw_tooltip is the button tooltip (600 ms of hover), drawn above every
// window so a neighbour cannot cover it.
draw_tooltip :: proc(s: ^Server, app: ^p.App, cv: ^p.Canvas, text: string, anchor: p.Rect) {
	f := &app.fonts
	tw := p.text_width(f, text, 12, .Sans, .Medium)
	w := tw + 16
	h := f32(24)
	x := anchor.x + anchor.w / 2 - w / 2
	y := anchor.y + anchor.h + 6
	x = clamp(x, 4, f32(cv.w) - w - 4)
	if y + h > f32(cv.h) - 4 {
		y = anchor.y - h - 6
	}
	r := p.Rect{x, y, w, h}
	p.drop_shadow(cv, r, {6, 6, 6, 6}, 10, 0, {0, 3}, p.hexa(0x00000080))
	p.fill_round_rect(cv, r, {6, 6, 6, 6}, p.hex(0x18181b))
	p.stroke_round_rect(cv, r, {6, 6, 6, 6}, 1, p.hex(0x3f3f46))
	p.draw_text(cv, f, text, x + 8, y + 16, 12, p.hex(0xe4e4e7), .Sans, .Medium)
}

// ring_shadow draws a drop shadow only in the band around a window.
//
// The interior is about to be covered by the client's own pixels, and the
// signed-distance evaluation is the expensive part of the frame, so skipping
// it there is most of the compositor's frame budget.
ring_shadow :: proc(cv: ^p.Canvas, r: p.Rect, rad: p.Radius, blur, spread: f32, offset: [2]f32, col: p.Color) {
	pad := blur + spread + 2
	o := p.Rect{r.x + offset.x - pad, r.y + offset.y - pad, r.w + 2 * pad, r.h + 2 * pad}
	inset := max(rad[0], rad[2], 1)
	in_ := p.rect_inset(r, inset)
	strips := [4]p.Rect {
		{o.x, o.y, o.w, in_.y - o.y},
		{o.x, in_.y + in_.h, o.w, p.rect_bottom(o) - (in_.y + in_.h)},
		{o.x, in_.y, in_.x - o.x, in_.h},
		{in_.x + in_.w, in_.y, p.rect_right(o) - (in_.x + in_.w), in_.h},
	}
	for st in strips {
		if st.w <= 0 || st.h <= 0 {
			continue
		}
		p.push_clip(cv, st)
		p.drop_shadow(cv, r, rad, blur, spread, offset, col)
		p.pop_clip(cv)
	}
}

// corner_inset is how far in from the side a rounded corner of radius r
// starts on row `dy` (0 at the corner's outermost row).
corner_inset :: proc(r: f32, dy: int) -> int {
	if r <= 0 {
		return 0
	}
	yy := r - (f32(dy) + 0.5)
	if yy <= 0 {
		return 0
	}
	return int(math.ceil(r - math.sqrt(max(r * r - yy * yy, 0)) - 0.25))
}

// blit_rounded copies a client's pixels with rounded corners cut out of the
// top (r_top) and bottom (r_bot) of `clip`: the body in one blit, and each
// corner row as its own narrowed blit — a per-row span table, which costs a
// few dozen extra row copies and no per-pixel test.
blit_rounded :: proc(cv: ^p.Canvas, surf: ^Surface, ox, oy: int, clip: p.Rect, r_top, r_bot: f32) {
	rt := int(r_top)
	rb := int(r_bot)
	body := clip
	body.y += f32(rt)
	body.h -= f32(rt + rb)
	if body.h > 0 {
		p.push_clip(cv, body)
		blit_surface(cv, surf, ox, oy)
		p.pop_clip(cv)
	}
	for dy in 0 ..< rt {
		in_ := f32(corner_inset(r_top, dy))
		row := p.Rect{clip.x + in_, clip.y + f32(dy), clip.w - 2 * in_, 1}
		p.push_clip(cv, row)
		blit_surface(cv, surf, ox, oy)
		p.pop_clip(cv)
	}
	for dy in 0 ..< rb {
		in_ := f32(corner_inset(r_bot, dy))
		row := p.Rect{clip.x + in_, clip.y + clip.h - 1 - f32(dy), clip.w - 2 * in_, 1}
		p.push_clip(cv, row)
		blit_surface(cv, surf, ox, oy)
		p.pop_clip(cv)
	}
}
