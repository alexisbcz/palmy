// desktop.odin — composing a frame: the wallpaper, each output's bar and
// windows, and the overlays above them.
//
// The order, bottom to top: wallpaper; layer surfaces below the windows; per
// output the bar, the windows bottom to top (with the snap preview slipped
// in just under the window being dragged), the welcome card or the empty
// workspace label, the toast and the debug HUD; layer surfaces above the
// windows; then the compositor's own overlays — the switcher, the overview,
// the cheat sheet, menus, tooltips; and the drag-and-drop icon last of all.
//
// The wallpaper (UX.md P1-3) is rasterized once per output size: a picture
// from `wallpaper =`, a flat `wallpaper_color`, or by default a generated
// diagonal gradient with two soft glows and a faint noise dither, so the
// gradient does not band on an 8-bit output. The dot grid it replaces read
// as graph paper.
package wm

import "core:fmt"
import "core:math"
import "core:time"
import p "palmy:."

// ---------------------------------------------------------------------------
// Wallpaper
// ---------------------------------------------------------------------------

// wall_hash is a cheap, stable per-pixel noise in 0..1.
wall_hash :: proc(x, y: int) -> f32 {
	h := u32(x) * 374761393 + u32(y) * 668265263
	h = (h ~ (h >> 13)) * 1274126177
	h ~= h >> 16
	return f32(h & 0xffff) / 65535
}

// wall_pixel is the generated wallpaper at (x, y) of a w x h output.
wall_pixel :: proc(x, y, w, h: int) -> u32 {
	fx := f32(x) / f32(max(w, 1))
	fy := f32(y) / f32(max(h, 1))
	t := clamp((fx * 0.45 + fy * 0.55), 0, 1)
	// Base: #0b1020 → #1e1b4b along the diagonal.
	r := 0x0b + (0x1e - 0x0b) * t
	g := 0x10 + (0x1b - 0x10) * t
	b := 0x20 + (0x4b - 0x20) * t
	// Two very soft glows: the accent top-left, teal bottom-right.
	big := f32(max(w, h))
	d1 := math.sqrt(math.pow(f32(x) - f32(w) * 0.18, 2) + math.pow(f32(y) - f32(h) * 0.12, 2)) / (big * 0.55)
	d2 := math.sqrt(math.pow(f32(x) - f32(w) * 0.85, 2) + math.pow(f32(y) - f32(h) * 0.92, 2)) / (big * 0.5)
	g1 := 0.12 * math.exp(-d1 * d1 * 2.2)
	g2 := 0.08 * math.exp(-d2 * d2 * 2.2)
	r = r * (1 - g1 - g2) + 0x63 * g1 + 0x0d * g2
	g = g * (1 - g1 - g2) + 0x66 * g1 + 0x94 * g2
	b = b * (1 - g1 - g2) + 0xf1 * g1 + 0x88 * g2
	// Triangular dither of about one level, which is what keeps an 8-bit
	// gradient from showing steps.
	n := (wall_hash(x, y) + wall_hash(y + 7919, x + 104729) - 1) * 1.2
	ri := u32(clamp(r + n, 0, 255))
	gi := u32(clamp(g + n, 0, 255))
	bi := u32(clamp(b + n, 0, 255))
	return 0xff00_0000 | (ri << 16) | (gi << 8) | bi
}

wall_img: p.Image
wall_img_path: string
wall_img_ok: bool

// build_desktop rasterizes the wallpaper once per size.
build_desktop :: proc(s: ^Server, w, h: int) {
	if s.bg_w == w && s.bg_h == h && s.bg != nil {
		return
	}
	delete(s.bg)
	s.bg = make([]u32, w * h)
	s.bg_w, s.bg_h = w, h

	if s.cfg.wallpaper != "" && s.cfg.wallpaper != wall_img_path {
		if wall_img_ok {
			p.image_destroy(&wall_img)
		}
		delete(wall_img_path)
		wall_img_path = fmt.aprintf("%s", s.cfg.wallpaper)
		wall_img, wall_img_ok = p.load_image(s.cfg.wallpaper)
		if !wall_img_ok {
			fmt.eprintfln("wm: wallpaper %s could not be read; using the generated one", s.cfg.wallpaper)
		}
	}
	switch {
	case s.cfg.wallpaper_flat:
		v := 0xff00_0000 | s.cfg.wallpaper_color
		for i in 0 ..< len(s.bg) {
			s.bg[i] = v
		}
	case s.cfg.wallpaper != "" && wall_img_ok:
		for y in 0 ..< h {
			for x in 0 ..< w {
				s.bg[y * w + x] = 0xff0b1020
			}
		}
		bc := p.canvas_from(s.bg, w, h)
		defer p.canvas_destroy(&bc)
		iw, ih := f32(wall_img.w), f32(wall_img.h)
		switch s.cfg.wallpaper_mode {
		case .Fill:
			sc := max(f32(w) / iw, f32(h) / ih)
			p.draw_image(&bc, wall_img, {(f32(w) - iw * sc) / 2, (f32(h) - ih * sc) / 2, iw * sc, ih * sc})
		case .Fit:
			sc := min(f32(w) / iw, f32(h) / ih)
			p.draw_image(&bc, wall_img, {(f32(w) - iw * sc) / 2, (f32(h) - ih * sc) / 2, iw * sc, ih * sc})
		case .Center:
			p.draw_image(&bc, wall_img, {(f32(w) - iw) / 2, (f32(h) - ih) / 2, iw, ih})
		case .Tile:
			for ty := f32(0); ty < f32(h); ty += ih {
				for tx := f32(0); tx < f32(w); tx += iw {
					p.draw_image(&bc, wall_img, {tx, ty, iw, ih})
				}
			}
		}
	case:
		for y in 0 ..< h {
			row := s.bg[y * w:][:w]
			for x in 0 ..< w {
				row[x] = wall_pixel(x, y, w, h)
			}
		}
	}
}

// ---------------------------------------------------------------------------
// The frame
// ---------------------------------------------------------------------------

draw :: proc(s: ^Server, app: ^p.App, cv: ^p.Canvas) {
	t0 := time.tick_now()
	ws_ensure(s)
	menu_app = app
	anim_app = app
	clear(&bar_hits)

	wm_reset_clip(cv)
	build_desktop(s, cv.w, cv.h)
	if bare_out.clipping {
		// Only the damaged rectangle: the rest of the scene is already right.
		c := cv.clip
		x0, y0 := max(int(c.x), 0), max(int(c.y), 0)
		x1, y1 := min(int(c.x + c.w), cv.w), min(int(c.y + c.h), cv.h)
		for y in y0 ..< y1 {
			copy(cv.px[y * cv.w + x0:y * cv.w + x1], s.bg[y * cv.w + x0:y * cv.w + x1])
		}
	} else {
		copy(cv.px[:cv.w * cv.h], s.bg)
	}

	layer_arrange(s)
	if lock_active() {
		lock_draw(s, app, cv)
		return
	}
	layer_draw(s, cv, false)

	for o, oi in s.outputs {
		if !o.enabled {
			continue
		}
		idx := ws_active_of_output(s, oi)
		wm_reset_clip(cv)
		p.push_clip(cv, {f32(o.x), f32(o.y), f32(o.w), f32(o.h)})

		draw_bar(s, app, cv, oi, idx)
		if overview_active(s, oi) {
			overview_draw(s, app, cv, oi)
			p.pop_clip(cv)
			continue
		}
		// The empty-workspace label and the welcome card belong to the
		// desktop, so they go down before the windows: the last window's
		// close animation then fades out over them, not under them.
		stack := ws_stack(s, idx)
		if len(stack) == 0 && !session.kiosk && !anim_ws_busy() {
			// The welcome card is for an empty *session*. A workspace you
			// have just switched to that happens to be empty, while three
			// windows run next door, gets a quiet label instead.
			if ws_total_windows(s) == 0 {
				draw_welcome(s, app, cv, o)
			} else {
				draw_empty_workspace(s, app, cv, o, idx)
			}
		}
		if !anim_ws_draw(s, app, cv, oi, idx) {
			draw_workspace(s, app, cv, idx, 0)
		}
		draw_toast(s, app, cv, o)
		draw_debug_hud(s, app, cv, o)
		p.pop_clip(cv)
	}
	wm_reset_clip(cv)
	layer_draw(s, cv, true)
	popup_draw(s, cv)

	switcher_draw(s, app, cv)
	cheat_draw(s, app, cv)
	draw_menu(s, app, cv)
	if text, r, ok := ix_tooltip(s); ok {
		draw_tooltip(s, app, cv, text, r)
	}

	// The drag icon follows the cursor above everything, including overlays.
	dnd_draw(s, cv)
	anim_frame_done(s, f64(time.duration_milliseconds(time.tick_since(t0))))
}

// draw_workspace draws one workspace's windows, shifted horizontally by dx
// (the workspace-switch slide), with the snap preview and the drop target
// in their place in the stacking.
draw_workspace :: proc(s: ^Server, app: ^p.App, cv: ^p.Canvas, idx: int, dx: int) {
	stack := ws_stack(s, idx)
	dragging := s.drag == .Move && idx == s.cur_ws ? s.drag_t : nil
	// A tiled window the keyboard just focused under floating windows is
	// lifted over them while it keeps focus (interact.odin, ix_reveal):
	// drawn last, whole, rather than seen through translucent windows.
	// It is lifted only over the floating band: always-on-top and
	// fullscreen windows stay above it, or "on top" would mean nothing.
	lifted := idx == s.cur_ws ? ix_lifted(s) : nil
	// A window on its way to the taskbar is drawn over everything else on
	// the workspace: the layout reflows into its place in the same frame,
	// and drawn in its old place in the stacking it would shrink unseen
	// behind the tile that takes its room.
	leaving := make([dynamic]^Toplevel, 0, 2, context.temp_allocator)
	for t in stack {
		if lifted != nil && ws_layer(s, t) >= 2 {
			draw_window_at(s, app, cv, lifted, dx)
			lifted = nil
		}
		if !t.mapped || t == lifted {
			continue
		}
		if t.minimized && !anim_has(t) {
			continue
		}
		if t.minimized {
			append(&leaving, t)
			continue
		}
		if t == dragging {
			draw_snap_preview(s, cv)
		}
		if t == ix.drop_t && dragging != nil {
			fr := frame_rect(t)
			draw_window_at(s, app, cv, t, dx)
			p.stroke_round_rect(cv, p.rect_inset(fr, -2), {4, 4, 4, 4}, 2, p.hex(ACCENT))
			continue
		}
		draw_window_at(s, app, cv, t, dx)
	}
	if lifted != nil {
		draw_window_at(s, app, cv, lifted, dx)
	}
	for t in leaving {
		draw_window_at(s, app, cv, t, dx)
	}
	if dx == 0 {
		anim_draw_ghosts(s, cv, idx)
	}
}

// draw_window_at draws a window through whatever is in effect for it: an
// animation, a rule's opacity, or plainly.
draw_window_at :: proc(s: ^Server, app: ^p.App, cv: ^p.Canvas, t: ^Toplevel, dx: int) {
	if dx != 0 {
		t.x += dx
		defer t.x -= dx
		draw_window_at(s, app, cv, t, 0)
		return
	}
	if anim_draw_window(s, app, cv, t) {
		return
	}
	alpha := f32(1)
	if m, ok := ws_peek(t); ok && m.opacity > 0 && m.opacity < 1 {
		alpha = m.opacity
	}
	if alpha < 1 {
		draw_window_alpha(s, app, cv, t, alpha)
		return
	}
	draw_window(s, app, cv, t)
}

// draw_snap_preview is the translucent target rectangle of a snap, which
// grows out of the pointer over 120 ms once the pointer has rested in a
// zone (UX.md P0-5).
draw_snap_preview :: proc(s: ^Server, cv: ^p.Canvas) {
	if ix.snap == .None || !ix.snap_shown || s.drag_t == nil {
		return
	}
	t := s.drag_t
	oi := ws_output_at(s, s_pointer.x, s_pointer.y)
	fr := snap_frame(ix.snap, tile_area(s, oi), ws_work_area(s, oi), s.cfg.gaps_in)
	target := p.Rect{f32(fr.x), f32(fr.y), f32(fr.w), f32(fr.h)}
	if ix.snap == .Maximize {
		target = p.rect_inset(target, f32(s.cfg.gaps_out))
	}
	k := f32(1)
	if anim_mode(s) == .On {
		k = ease_out(f32(clamp((wall_now() - ix.preview_at) / 0.12, 0, 1)))
		if k < 1 {
			anim_keep_going()
		}
	}
	from := ix.preview_from
	r := p.Rect {
		from.x + (target.x - from.x) * k,
		from.y + (target.y - from.y) * k,
		from.w + (target.w - from.w) * k,
		from.h + (target.h - from.h) * k,
	}
	p.fill_round_rect(cv, r, {12, 12, 12, 12}, with_alpha(ACCENT, 0.18))
	p.stroke_round_rect(cv, r, {12, 12, 12, 12}, 1, with_alpha(ACCENT, 0.6))
	_ = t
}

draw_welcome :: proc(s: ^Server, app: ^p.App, cv: ^p.Canvas, o: Ws_Output) {
	f := &app.fonts
	cx := f32(o.x) + f32(o.w) / 2
	cy := f32(o.y) + f32(o.h) / 2
	hint := "right-click the desktop to begin"
	if k := menu_spawn_key(s, "term"); k != "" {
		hint = fmt.tprintf("press %s for a terminal", k)
	}
	more := "right-click the desktop for more"
	if k := key_for_act(s, .Cheat_Sheet, 0); k != "" {
		more = fmt.tprintf("right-click the desktop for more  ·  %s lists every shortcut", k)
	}
	lines := [?]struct {
		text: string,
		size: f32,
		wt:   p.Font_Weight,
		col:  u32,
	} {
		{session.bare ? "Palmframe" : "A Wayland compositor, nested", 28, .Bold, 0xe8e8ef},
		{hint, 14, .Medium, 0xa5b4fc},
		{more, 12.5, .Regular, 0x8b8b93},
		{s.cfg.loaded ? fmt.tprintf("configuration: %s", s.cfg.path) : fmt.tprintf("no %s — built-in defaults", s.cfg.path), 11.5, .Regular, 0x5b5b66},
	}
	y := cy - 44
	for l in lines {
		w := p.text_width(f, l.text, l.size, .Sans, l.wt)
		p.draw_text(cv, f, l.text, cx - w / 2, y, l.size, p.hex(l.col), .Sans, l.wt)
		y += l.size + 16
	}
}

draw_empty_workspace :: proc(s: ^Server, app: ^p.App, cv: ^p.Canvas, o: Ws_Output, idx: int) {
	f := &app.fonts
	label := fmt.tprintf("workspace %s", s.workspaces[idx].name)
	w := p.text_width(f, label, 15, .Sans, .Medium)
	cx := f32(o.x) + f32(o.w) / 2
	cy := f32(o.y) + f32(o.h) / 2
	p.draw_text(cv, f, label, cx - w / 2, cy, 15, p.hex(0x6b6b80), .Sans, .Medium)
	sub := "empty"
	sw := p.text_width(f, sub, 12)
	p.draw_text(cv, f, sub, cx - sw / 2, cy + 22, 12, p.hex(0x4b4b5c))
}
