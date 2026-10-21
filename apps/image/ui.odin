package main

// The three screens: the viewer, the folder grid and the library.

import "core:fmt"
import "core:math"
import "core:strings"
import p "palmy:."
import sc "shadcn:."

TOPBAR_H :: f32(56)
STATUS_H :: f32(30)
GRID_PAD :: f32(14)
GRID_CELL :: f32(176)
GRID_GAP :: f32(12)

// ---------------------------------------------------------------------------
// Viewer
// ---------------------------------------------------------------------------

build_viewer :: proc(ui: ^p.Ctx, st: ^St) {
	size := p.size(ui)
	show_strip := st.strip && len(st.shots) > 1
	st.view_rect = {
		0,
		TOPBAR_H,
		size.x - (st.info ? PANEL_W + 1 : 0),
		size.y - TOPBAR_H - STATUS_H - (show_strip ? STRIP_H + 1 : 0),
	}
	st.shown = display(st)

	top_bar(ui, st)

	p.row(ui, "w-full flex-1 min-h-0 overflow-hidden")
	{
		p.col(ui, "flex-1 min-w-0 min-h-0 overflow-hidden")
		{
			p.col(ui, "w-full flex-1 min-h-0 relative overflow-hidden bg-[#0c0c0e]")
			if st.cur_ok && st.shown.w > 0 {
				idx := p.pixels(ui, "w-full flex-1 min-h-0 cursor-grab", st, draw_canvas)
				pointer_pan(ui, st, idx)
				zoom_hud(ui, st)
			} else if s := current_shot(st); s == nil {
				viewer_empty(ui, st)
			} else if st.cur_idx != st.sel {
				decoding_state(ui, st, s)
			} else {
				broken_state(ui, st, s)
			}
			p.end(ui)

			if show_strip {
				thumb_strip(ui, st)
			}
		}
		p.end(ui)

		if st.info {
			info_panel(ui, st)
		}
	}
	p.end(ui)

	status_bar(ui, st)
}

// draw_canvas is the viewer proper: a checkerboard for transparency, the
// picture at whatever scale and offset the transform says, and a hairline so a
// white photo on a dark background still has an edge.
draw_canvas :: proc(c: ^p.Canvas, r: p.Rect, st: ^St) {
	img := st.shown
	if img.w <= 0 {
		return
	}
	s := effective_scale(st, img) * c.scale
	w := f32(img.w) * s
	h := f32(img.h) * s
	cx := r.x + r.w / 2 + st.pan.x * c.scale
	cy := r.y + r.h / 2 + st.pan.y * c.scale
	dst := p.Rect{math.round(cx - w / 2), math.round(cy - h / 2), w, h}

	vis := p.rect_intersect(dst, r)
	if vis.w <= 0 || vis.h <= 0 {
		return
	}

	if img.source_channels == 2 || img.source_channels == 4 {
		checkerboard(c, vis)
	}
	p.draw_image(c, img, dst)
	p.stroke_round_rect(c, dst, {0, 0, 0, 0}, 1 * c.scale, p.Color{255, 255, 255, 28})
}

checkerboard :: proc(c: ^p.Canvas, r: p.Rect) {
	cell := 12 * c.scale
	a := p.Color{38, 38, 42, 255}
	b := p.Color{28, 28, 32, 255}
	y0 := int(math.floor(r.y / cell))
	y1 := int(math.ceil(p.rect_bottom(r) / cell))
	x0 := int(math.floor(r.x / cell))
	x1 := int(math.ceil(p.rect_right(r) / cell))
	for gy in y0 ..< y1 {
		for gx in x0 ..< x1 {
			q := p.rect_intersect(
				p.Rect{f32(gx) * cell, f32(gy) * cell, cell, cell},
				r,
			)
			if q.w > 0 && q.h > 0 {
				p.fill_rect(c, q, (gx + gy) % 2 == 0 ? a : b)
			}
		}
	}
}

// pointer_pan is drag-to-pan. The demo cannot synthesise clicks, but a viewer
// that only pans from the keyboard is not a viewer.
pointer_pan :: proc(ui: ^p.Ctx, st: ^St, idx: int) {
	if !p.clickable(ui, idx) && !p.is_active(ui, idx) {
		if !p.mouse_down(ui) {
			st.drag = false
		}
	}
	m := p.mouse_pos(ui)
	if p.is_active(ui, idx) {
		if !st.drag {
			st.drag = true
			st.drag_from = m
			st.drag_pan = st.pan
		}
		st.pan = st.drag_pan + (m - st.drag_from)
		clamp_pan(st, st.shown)
	} else if !p.mouse_down(ui) {
		st.drag = false
	}
}

// zoom_hud is the floating scale readout, shown only while it is not the
// boring answer.
zoom_hud :: proc(ui: ^p.Ctx, st: ^St) {
	if st.fit && !pannable(st) {
		return
	}
	s := effective_scale(st, st.shown)
	box := p.div(
		ui,
		"absolute flex-row items-center gap-2 h-7 px-2.5 rounded-lg bg-background/80 border border-border z-20",
	)
	bs := p.style(ui, box)
	bs.inset[p.LEFT] = p.px(12)
	bs.inset[p.BOTTOM] = p.px(12)
	p.icon(ui, pannable(st) ? IC_MOVE : IC_ZOOM_IN, "size-3.5 text-muted-foreground shrink-0")
	p.textf(ui, "text-xs font-medium whitespace-nowrap", "%d%%", int(math.round(s * 100)))
	p.style(ui).shrink = 0
	if pannable(st) {
		p.text(ui, "arrows pan", "text-[11] text-muted-foreground whitespace-nowrap")
		p.style(ui).shrink = 0
	}
	p.end(ui)
}

viewer_empty :: proc(ui: ^p.Ctx, st: ^St) {
	p.col(ui, "flex-1 w-full items-center justify-center gap-3")
	defer p.end(ui)
	p.div(ui, "size-14 flex-row items-center justify-center rounded-2xl bg-muted ring-1 ring-border")
	p.icon(ui, IC_IMAGE_OFF, "size-6 text-muted-foreground")
	p.end(ui)
	p.text(ui, "Nothing to show", "text-sm font-medium")
	p.text(ui, "This folder has no images palmy can decode", "text-xs text-muted-foreground")
}

decoding_state :: proc(ui: ^p.Ctx, st: ^St, s: ^Shot) {
	p.col(ui, "flex-1 w-full items-center justify-center gap-4")
	defer p.end(ui)

	// A skeleton in the picture's own aspect ratio, so the layout does not
	// jump when the pixels land.
	probe(s)
	if s.w > 0 && s.h > 0 {
		box := min(st.view_rect.w * 0.6, st.view_rect.h * 0.6)
		w := box
		h := box
		if s.w >= s.h {
			h = box * f32(s.h) / f32(s.w)
		} else {
			w = box * f32(s.w) / f32(s.h)
		}
		p.div(ui, "rounded-xl bg-muted/60 border border-border")
		ss := p.style(ui)
		ss.w = p.px(math.round(w))
		ss.h = p.px(math.round(h))
		p.end(ui)
	}

	p.row(ui, "items-center gap-2")
	sc.spinner(ui, "size-4 text-muted-foreground")
	p.textf(ui, "text-xs text-muted-foreground whitespace-nowrap", "Decoding %s…", s.name)
	p.style(ui).shrink = 0
	p.end(ui)
}

broken_state :: proc(ui: ^p.Ctx, st: ^St, s: ^Shot) {
	probe(s)
	p.col(ui, "flex-1 w-full items-center justify-center p-8")
	defer p.end(ui)

	p.col(ui, "w-[420] max-w-full gap-4 p-6 rounded-2xl bg-card border border-border")
	defer p.end(ui)

	p.row(ui, "items-center gap-3")
	p.div(ui, "size-10 shrink-0 flex-row items-center justify-center rounded-xl bg-destructive/10 ring-1 ring-destructive/30")
	p.icon(ui, IC_TRIANGLE_ALERT, "size-5 text-destructive")
	p.end(ui)
	p.col(ui, "flex-1 min-w-0 gap-0.5")
	p.text(ui, "Can’t display this image", "text-sm font-semibold")
	p.text(ui, s.name, "text-xs text-muted-foreground truncate")
	p.end(ui)
	p.end(ui)

	reason := "stb_image could not decode the file"
	if s.format == "" {
		reason = "the bytes do not match any format palmy decodes"
	} else {
		reason = fmt.tprintf("the header says %s, but decoding failed — the file looks truncated or corrupt", s.format)
	}
	p.text(ui, reason, "text-xs text-muted-foreground")

	sc.separator(ui)

	p.col(ui, "gap-1.5")
	meta_line(ui, "Size on disk", human_bytes(s.size))
	meta_line(ui, "Extension", strings.to_upper(ext_of(s.path), context.temp_allocator))
	meta_line(ui, "Detected", s.format == "" ? "unrecognised" : s.format)
	p.end(ui)

	p.row(ui, "items-center gap-1.5 pt-1")
	sc.kbd(ui, "Right")
	p.text(ui, "skip to the next picture", "text-[11] text-muted-foreground whitespace-nowrap")
	p.style(ui).shrink = 0
	p.end(ui)
}

// ---------------------------------------------------------------------------
// Chrome
// ---------------------------------------------------------------------------

top_bar :: proc(ui: ^p.Ctx, st: ^St) {
	p.row(ui, "w-full shrink-0 items-center gap-3 px-3 border-b border-border bg-card/40")
	p.style(ui).h = p.px(TOPBAR_H)
	defer p.end(ui)

	s := current_shot(st)

	p.div(ui, "size-9 shrink-0 flex-row items-center justify-center rounded-lg bg-muted ring-1 ring-border")
	p.icon(ui, st.cur_ok ? IC_FILE_IMAGE : IC_IMAGE, "size-[18] text-muted-foreground")
	p.end(ui)

	p.col(ui, "flex-1 min-w-0 gap-px overflow-hidden")
	if s != nil {
		p.text(ui, s.name, "text-sm font-medium truncate")
		p.row(ui, "w-full min-w-0 items-center gap-2 overflow-hidden")
		if s.w > 0 {
			p.textf(ui, "text-[11] text-muted-foreground whitespace-nowrap", "%d × %d", s.w, s.h)
			p.style(ui).shrink = 0
		}
		p.text(ui, home_relative(st.dir), "flex-1 min-w-0 text-[11] text-muted-foreground truncate")
		p.end(ui)
	} else {
		p.text(ui, "No image", "text-sm font-medium")
	}
	p.end(ui)

	// Position in the folder.
	if len(st.shots) > 0 {
		p.row(ui, "shrink-0 items-center gap-1.5 h-7 px-2 rounded-lg bg-muted/60 border border-border")
		tool_icon(ui, IC_CHEVRON_LEFT, "Previous")
		p.textf(
			ui,
			"text-xs font-medium tabular-nums whitespace-nowrap",
			"%d / %d",
			st.sel + 1,
			len(st.shots),
		)
		p.style(ui).shrink = 0
		tool_icon(ui, IC_CHEVRON_RIGHT, "Next")
		p.end(ui)
	}

	if s != nil && s.format != "" {
		sc.badge(ui, s.format, .Secondary)
	}

	p.row(ui, "shrink-0 items-center gap-1")
	chrome_button(ui, st, IC_ZOOM_OUT, false)
	if st.cur_ok {
		p.textf(
			ui,
			"w-[46] text-center text-[11] text-muted-foreground tabular-nums whitespace-nowrap",
			"%d%%",
			int(math.round(effective_scale(st, st.shown) * 100)),
		)
		p.style(ui).shrink = 0
	}
	chrome_button(ui, st, IC_ZOOM_IN, false)
	chrome_button(ui, st, IC_EXPAND, st.fit)
	chrome_button(ui, st, IC_ROTATE_CW, st.rot % 4 != 0)
	chrome_button(ui, st, IC_LAYOUT_GRID, false)
	chrome_button(ui, st, IC_INFO, st.info)
	p.end(ui)
}

// chrome_button draws one of the top-bar tools. It is clickable for real use
// and shows the keyboard shortcut in the status bar, which is what the demo
// drives.
chrome_button :: proc(ui: ^p.Ctx, st: ^St, ic: p.Icon, on: bool) {
	idx := p.div(
		ui,
		"size-8 shrink-0 flex-row items-center justify-center rounded-lg border border-transparent transition cursor-pointer",
	)
	p.apply(ui, on ? "bg-accent border-border text-foreground" : "text-muted-foreground hover:bg-muted hover:text-foreground", idx)
	if p.clickable(ui, idx) {
		switch ic.name {
		case "zoom-in":
			zoom_by(st, ZOOM_STEP)
		case "zoom-out":
			zoom_by(st, 1 / ZOOM_STEP)
		case "expand":
			st.fit = true
			st.pan = {}
		case "rotate-cw":
			st.rot += 1
			st.pan = {}
		case "layout-grid":
			st.view = .Grid
			keep_grid_visible(st)
		case "info":
			st.info = !st.info
		}
	}
	p.icon(ui, ic, "size-4")
	p.end(ui)
}

tool_icon :: proc(ui: ^p.Ctx, ic: p.Icon, _: string) {
	p.icon(ui, ic, "size-3.5 shrink-0 text-muted-foreground")
}

status_bar :: proc(ui: ^p.Ctx, st: ^St) {
	p.row(ui, "w-full shrink-0 items-center gap-3 px-3 border-t border-border bg-card/40")
	p.style(ui).h = p.px(STATUS_H)
	defer p.end(ui)

	if st.toast != "" {
		p.icon(ui, IC_INFO, "size-3.5 shrink-0 text-muted-foreground")
		p.text(ui, st.toast, "flex-1 text-[11] text-muted-foreground truncate")
		return
	}

	if pannable(st) {
		hint(ui, "Arrows", "", "Pan")
		hint(ui, "n", "p", "Next / prev")
	} else {
		hint(ui, "Left", "Right", "Browse")
	}
	hint(ui, "+", "−", "Zoom")
	hint(ui, "0", "", "Fit")
	hint(ui, "1", "", "100%")
	hint(ui, "r", "", "Rotate")
	hint(ui, "g", "", "Grid")
	hint(ui, "i", "", "Info")
	p.spacer(ui)

	done, total, avg := loader_stats(&st.ld)
	if done < total {
		p.row(ui, "shrink-0 items-center gap-1.5")
		sc.spinner(ui, "size-3 text-muted-foreground")
		p.textf(
			ui,
			"text-[11] text-muted-foreground tabular-nums whitespace-nowrap",
			"thumbnails %d/%d",
			done,
			total,
		)
		p.style(ui).shrink = 0
		p.end(ui)
	} else if st.cur_ms > 0 {
		p.textf(
			ui,
			"text-[11] text-muted-foreground tabular-nums whitespace-nowrap",
			"decoded in %.0f ms · avg thumb %.0f ms",
			st.cur_ms,
			avg,
		)
		p.style(ui).shrink = 0
	}
}

hint :: proc(ui: ^p.Ctx, k1, k2, label: string) {
	p.row(ui, "shrink-0 items-center gap-1")
	defer p.end(ui)
	sc.kbd(ui, k1)
	if k2 != "" {
		sc.kbd(ui, k2)
	}
	p.text(ui, label, "text-[11] text-muted-foreground whitespace-nowrap")
	p.style(ui).shrink = 0
}

// ---------------------------------------------------------------------------
// Properties
// ---------------------------------------------------------------------------

info_panel :: proc(ui: ^p.Ctx, st: ^St) {
	p.col(ui, "h-full shrink-0 border-l border-border bg-card/30 overflow-hidden")
	p.style(ui).w = p.px(PANEL_W)
	defer p.end(ui)

	p.row(ui, "w-full h-10 shrink-0 items-center gap-2 px-3.5 border-b border-border")
	p.icon(ui, IC_INFO, "size-3.5 shrink-0 text-muted-foreground")
	p.text(ui, "Properties", "flex-1 text-xs font-semibold uppercase tracking-wider")
	sc.kbd(ui, "i")
	p.end(ui)

	s := current_shot(st)
	if s == nil {
		p.col(ui, "flex-1 items-center justify-center p-4")
		p.text(ui, "No file selected", "text-xs text-muted-foreground")
		p.end(ui)
		return
	}
	probe(s)

	p.col(ui, "flex-1 min-h-0 p-3.5 gap-4 overflow-hidden")
	defer p.end(ui)

	meta_group(ui, "File")
	meta_line(ui, "Name", s.name)
	meta_line(ui, "Folder", home_relative(st.dir))
	meta_line(ui, "Size", human_bytes(s.size))
	meta_line(ui, "Modified", human_time(s.mtime))

	meta_group(ui, "Image")
	if s.broken {
		meta_line(ui, "Status", "undecodable")
	} else {
		meta_line(ui, "Format", s.format == "" ? "—" : s.format)
		meta_line(ui, "Dimensions", human_pixels(s.w, s.h))
		meta_line(ui, "Aspect", aspect_label(s.w, s.h))
		meta_line(ui, "Channels", channels_label(s.ch))
		bpp := bits_per_pixel({size = s.size, w = s.w, h = s.h})
		meta_line(ui, "Stored at", fmt.tprintf("%.2f bits/px", bpp))
	}

	// What the file says about itself, the entries `image metadata` prints
	// (core.odin). Only the ones a person scans for; the command has the rest.
	shown := 0
	for key in ([?]string{"make", "model", "date_taken", "date_time", "exposure", "f_number", "iso", "focal_length", "orientation", "dpi", "gps", "software"}) {
		for e in s.meta {
			if e.key == key && shown < 7 {
				if shown == 0 {
					meta_group(ui, "Metadata")
				}
				meta_line(ui, e.label, e.value)
				shown += 1
			}
		}
	}

	meta_group(ui, "View")
	meta_line(
		ui,
		"Scale",
		fmt.tprintf(
			"%d%%%s",
			int(math.round(effective_scale(st, st.shown) * 100)),
			st.fit ? " (fit)" : "",
		),
	)
	meta_line(ui, "Rotation", fmt.tprintf("%d°", (((st.rot % 4) + 4) % 4) * 90))
	if st.cur_ok {
		meta_line(
			ui,
			"In memory",
			human_bytes(i64(st.cur.w) * i64(st.cur.h) * 4),
		)
		meta_line(ui, "Decode", fmt.tprintf("%.1f ms", st.cur_ms))
	}

	p.spacer(ui)
	done, total, avg := loader_stats(&st.ld)
	p.col(ui, "gap-1.5 pt-2 border-t border-border")
	meta_line(ui, "Folder", fmt.tprintf("%d images", len(st.shots)))
	meta_line(ui, "Thumbnails", fmt.tprintf("%d of %d", done, total))
	if avg > 0 {
		meta_line(ui, "Avg thumb", fmt.tprintf("%.0f ms", avg))
	}
	p.end(ui)
}

meta_group :: proc(ui: ^p.Ctx, label: string) {
	p.text(
		ui,
		label,
		"text-[10] font-semibold uppercase tracking-widest text-muted-foreground/70 pt-1",
	)
}

meta_line :: proc(ui: ^p.Ctx, key, value: string) {
	p.row(ui, "w-full items-baseline gap-3")
	defer p.end(ui)
	p.text(ui, key, "w-[88] shrink-0 text-[11] text-muted-foreground whitespace-nowrap")
	p.text(ui, value, "flex-1 min-w-0 text-[11] font-medium truncate")
}

// ---------------------------------------------------------------------------
// Thumbnail strip
// ---------------------------------------------------------------------------

thumb_strip :: proc(ui: ^p.Ctx, st: ^St) {
	p.row(ui, "w-full shrink-0 items-center gap-2 px-2 border-t border-border bg-card/20 overflow-hidden")
	p.style(ui).h = p.px(STRIP_H)
	defer p.end(ui)

	// The strip is a window over the folder that follows the selection, which
	// is the only scrolling model that needs no retained state.
	cell := f32(106)
	size := p.size(ui)
	vis := max(1, int((size.x - 16) / cell))
	top := clamp(st.sel - vis / 2, 0, max(0, len(st.shots) - vis))
	last := min(top + vis, len(st.shots))
	loader_set_hint(&st.ld, top + vis / 2)

	for i in top ..< last {
		p.key(ui, st.shots[i].name)
		thumb_cell(ui, st, i, 96, 72)
	}
}

thumb_cell :: proc(ui: ^p.Ctx, st: ^St, i: int, w, h: f32) {
	sel := i == st.sel
	idx := p.div(
		ui,
		"shrink-0 flex-col items-center justify-center rounded-lg overflow-hidden border transition cursor-pointer",
	)
	p.apply(ui, sel ? "border-primary bg-accent" : "border-border/60 bg-muted/40 hover:border-border", idx)
	s := p.style(ui, idx)
	s.w = p.px(w)
	s.h = p.px(h)
	if p.clickable(ui, idx) {
		st.sel = i
		st.rot = 0
		st.fit = true
		st.pan = {}
		loader_want(&st.ld, i)
	}
	defer p.end(ui)

	img, state := loader_thumb(&st.ld, i)
	switch state {
	case .Ready:
		p.image(ui, img, "w-full h-full", .Cover)
	case .Failed:
		p.icon(ui, IC_FILE_X, "size-4 text-muted-foreground/60")
	case .Empty, .Queued:
		p.div(ui, "w-full h-full bg-muted/50")
		p.end(ui)
	}
}

// ---------------------------------------------------------------------------
// Grid
// ---------------------------------------------------------------------------

keep_grid_visible :: proc(st: ^St) {
	cols := max(1, st.grid_cols)
	rows := max(1, st.grid_rows)
	if st.sel < 0 {
		return
	}
	r := st.sel / cols
	if r < st.grid_top {
		st.grid_top = r
	}
	if r >= st.grid_top + rows {
		st.grid_top = r - rows + 1
	}
	total := (len(st.shots) + cols - 1) / cols
	st.grid_top = clamp(st.grid_top, 0, max(0, total - rows))
}

build_grid :: proc(ui: ^p.Ctx, st: ^St) {
	size := p.size(ui)
	avail_w := size.x - (st.info ? PANEL_W + 1 : 0) - 2 * GRID_PAD
	cols := max(1, int((avail_w + GRID_GAP) / (GRID_CELL + GRID_GAP)))
	cell_w := (avail_w - f32(cols - 1) * GRID_GAP) / f32(cols)
	cell_h := math.round(cell_w * 0.74) + 26
	avail_h := size.y - TOPBAR_H - STATUS_H - 2 * GRID_PAD
	rows := max(1, int((avail_h + GRID_GAP) / (cell_h + GRID_GAP)))
	// Spread the slack over the rows that fit rather than leaving a band of
	// empty background under the last one.
	cell_h = min(cell_h * 1.6, (avail_h - f32(rows - 1) * GRID_GAP) / f32(rows))
	st.grid_cols = cols
	st.grid_rows = rows
	keep_grid_visible(st)
	st.shown = {}

	grid_bar(ui, st)

	p.row(ui, "w-full flex-1 min-h-0 overflow-hidden")
	{
		p.col(ui, "flex-1 min-w-0 min-h-0 overflow-hidden")
		p.style(ui).pad = {GRID_PAD, GRID_PAD, GRID_PAD, GRID_PAD}
		p.style(ui).gap = {GRID_GAP, GRID_GAP}

		if len(st.shots) == 0 {
			viewer_empty(ui, st)
		} else {
			first := st.grid_top * cols
			loader_set_hint(&st.ld, first + cols * rows / 2)
			for r in 0 ..< rows {
				p.row(ui, "w-full shrink-0")
				p.style(ui).gap = {GRID_GAP, GRID_GAP}
				for c in 0 ..< cols {
					i := first + r * cols + c
					if i >= len(st.shots) {
						// A spacer keeps the last row's cells the same width
						// as every other row's.
						p.div(ui, "shrink-0")
						p.style(ui).w = p.px(cell_w)
						p.end(ui)
						continue
					}
					p.key(ui, st.shots[i].name)
					grid_cell(ui, st, i, cell_w, cell_h)
				}
				p.end(ui)
			}
		}
		p.end(ui)

		if st.info {
			info_panel(ui, st)
		}
	}
	p.end(ui)

	status_bar_grid(ui, st)
}

grid_cell :: proc(ui: ^p.Ctx, st: ^St, i: int, w, h: f32) {
	sel := i == st.sel
	idx := p.div(ui, "shrink-0 flex-col gap-1.5 p-1.5 rounded-xl border transition cursor-pointer")
	p.apply(
		ui,
		sel ? "border-primary bg-accent" : "border-transparent hover:bg-muted/60 hover:border-border/60",
		idx,
	)
	s := p.style(ui, idx)
	s.w = p.px(w)
	s.h = p.px(h)
	if p.clickable(ui, idx) {
		st.sel = i
		st.view = .Viewer
		st.rot = 0
		st.fit = true
		st.pan = {}
		loader_want(&st.ld, i)
	}
	defer p.end(ui)

	p.div(ui, "w-full flex-1 min-h-0 flex-row items-center justify-center rounded-lg overflow-hidden bg-[#0c0c0e] ring-1 ring-border/60")
	img, state := loader_thumb(&st.ld, i)
	switch state {
	case .Ready:
		p.image(ui, img, "w-full h-full", .Contain)
	case .Failed:
		p.icon(ui, IC_FILE_X, "size-5 text-muted-foreground/60")
	case .Empty, .Queued:
		p.div(ui, "w-full h-full bg-muted/40")
		p.end(ui)
	}
	p.end(ui)

	p.text(
		ui,
		st.shots[i].name,
		sel \
		? "w-full shrink-0 text-[11] font-medium truncate" \
		: "w-full shrink-0 text-[11] text-muted-foreground truncate",
	)
}

grid_bar :: proc(ui: ^p.Ctx, st: ^St) {
	p.row(ui, "w-full shrink-0 items-center gap-3 px-3 border-b border-border bg-card/40")
	p.style(ui).h = p.px(TOPBAR_H)
	defer p.end(ui)

	p.div(ui, "size-9 shrink-0 flex-row items-center justify-center rounded-lg bg-muted ring-1 ring-border")
	p.icon(ui, IC_FOLDER_OPEN, "size-[18] text-muted-foreground")
	p.end(ui)

	p.col(ui, "flex-1 min-w-0 gap-px")
	p.text(ui, base_of(st.dir), "text-sm font-medium truncate")
	p.textf(
		ui,
		"text-[11] text-muted-foreground truncate",
		"%s · %d images",
		home_relative(st.dir),
		len(st.shots),
	)
	p.end(ui)

	if s := current_shot(st); s != nil {
		sc.badge(ui, fmt.tprintf("%d / %d", st.sel + 1, len(st.shots)), .Secondary)
	}
	p.row(ui, "shrink-0 items-center gap-1")
	chrome_button(ui, st, IC_INFO, st.info)
	p.end(ui)
}

status_bar_grid :: proc(ui: ^p.Ctx, st: ^St) {
	p.row(ui, "w-full shrink-0 items-center gap-3 px-3 border-t border-border bg-card/40")
	p.style(ui).h = p.px(STATUS_H)
	defer p.end(ui)

	hint(ui, "Arrows", "", "Move")
	hint(ui, "Enter", "", "Open")
	hint(ui, "i", "", "Info")
	hint(ui, "Esc", "", "Library")
	p.spacer(ui)

	done, total, _ := loader_stats(&st.ld)
	if done < total {
		p.row(ui, "shrink-0 items-center gap-1.5")
		sc.spinner(ui, "size-3 text-muted-foreground")
		p.textf(
			ui,
			"text-[11] text-muted-foreground tabular-nums whitespace-nowrap",
			"decoding thumbnails %d/%d",
			done,
			total,
		)
		p.style(ui).shrink = 0
		p.end(ui)
	} else {
		p.textf(
			ui,
			"text-[11] text-muted-foreground tabular-nums whitespace-nowrap",
			"%d thumbnails ready",
			done,
		)
		p.style(ui).shrink = 0
	}
}

// ---------------------------------------------------------------------------
// Library
// ---------------------------------------------------------------------------

build_library_ui :: proc(ui: ^p.Ctx, st: ^St) {
	size := p.size(ui)
	st.shown = {}

	p.row(ui, "w-full shrink-0 items-center gap-3 px-4 border-b border-border bg-card/40")
	p.style(ui).h = p.px(TOPBAR_H)
	p.div(ui, "size-9 shrink-0 flex-row items-center justify-center rounded-lg bg-muted ring-1 ring-border")
	p.icon(ui, IC_IMAGE, "size-[18] text-muted-foreground")
	p.end(ui)
	p.col(ui, "flex-1 min-w-0 gap-px")
	p.text(ui, "Images", "text-sm font-semibold")
	p.text(ui, "Pick a folder, or pass a file on the command line", "text-[11] text-muted-foreground")
	p.end(ui)
	p.end(ui)

	if st.cur_err != "" {
		p.row(ui, "w-full shrink-0 items-center gap-2.5 px-4 py-2.5 border-b border-border bg-destructive/10")
		p.icon(ui, IC_TRIANGLE_ALERT, "size-4 shrink-0 text-destructive")
		p.text(ui, st.cur_err, "flex-1 text-xs text-destructive truncate")
		p.end(ui)
	}

	rows_h := size.y - TOPBAR_H - STATUS_H - (st.cur_err != "" ? 41 : 0) - 24
	st.lib_vis = max(1, int(rows_h / 56))
	if st.lib_sel < st.lib_top {
		st.lib_top = st.lib_sel
	}
	if st.lib_sel >= st.lib_top + st.lib_vis {
		st.lib_top = st.lib_sel - st.lib_vis + 1
	}
	st.lib_top = clamp(st.lib_top, 0, max(0, len(st.rows) - st.lib_vis))

	p.col(ui, "w-full flex-1 min-h-0 px-3 py-3 gap-0.5 overflow-hidden")
	{
		if len(st.rows) == 0 {
			p.col(ui, "flex-1 items-center justify-center gap-3")
			p.div(ui, "size-14 flex-row items-center justify-center rounded-2xl bg-muted ring-1 ring-border")
			p.icon(ui, IC_FOLDER, "size-6 text-muted-foreground")
			p.end(ui)
			p.text(ui, "No pictures found", "text-sm font-medium")
			p.text(
				ui,
				"Looked in ~/Pictures, ~/Downloads, ~/Desktop and $PALMY_IMAGE_DIR",
				"text-xs text-muted-foreground",
			)
			p.end(ui)
		} else {
			last := min(st.lib_top + st.lib_vis, len(st.rows))
			for i in st.lib_top ..< last {
				p.key(ui, fmt.tprintf("row-%d", i))
				library_row(ui, st, i)
			}
		}
	}
	p.end(ui)

	p.row(ui, "w-full shrink-0 items-center gap-3 px-3 border-t border-border bg-card/40")
	p.style(ui).h = p.px(STATUS_H)
	hint(ui, "↑", "↓", "Move")
	hint(ui, "Enter", "", "Open")
	hint(ui, "Esc", "", "Quit")
	p.spacer(ui)
	p.text(ui, "palmy image", "text-[11] text-muted-foreground whitespace-nowrap")
	p.end(ui)
}

library_row :: proc(ui: ^p.Ctx, st: ^St, i: int) {
	r := st.rows[i]
	if r.kind == .Header {
		p.row(ui, "w-full h-7 shrink-0 items-end px-2 pb-1")
		p.text(
			ui,
			r.text,
			"text-[10] font-semibold uppercase tracking-widest text-muted-foreground/70",
		)
		p.end(ui)
		return
	}

	sel := i == st.lib_sel
	idx := p.div(ui, "flex-row w-full h-[52] shrink-0 items-center gap-3 px-2.5 rounded-xl border transition cursor-pointer")
	p.apply(ui, sel ? "bg-accent border-border" : "border-transparent hover:bg-muted/60", idx)
	if p.clickable(ui, idx) {
		st.lib_sel = i
		open_row(st)
	}
	if st.moved && p.is_hovered(ui, idx) {
		st.lib_sel = i
	}
	defer p.end(ui)

	if sel {
		bar := p.div(ui, "absolute w-[3] rounded-full bg-primary")
		bs := p.style(ui, bar)
		bs.inset[p.LEFT] = p.px(0)
		bs.inset[p.TOP] = p.px(15)
		bs.h = p.px(22)
		p.end(ui)
	}

	p.div(ui, "size-9 shrink-0 flex-row items-center justify-center rounded-lg bg-muted ring-1 ring-border")
	p.icon(ui, r.ic, sel ? "size-4 text-foreground" : "size-4 text-muted-foreground")
	p.end(ui)

	p.col(ui, "flex-1 min-w-0 gap-px")
	p.text(ui, r.text, sel ? "text-sm font-medium truncate" : "text-sm truncate")
	p.text(ui, r.sub, "text-[11] text-muted-foreground truncate")
	p.end(ui)

	if r.kind == .Place {
		sc.badge(ui, fmt.tprintf("%d", r.count), .Outline)
	}
	if sel {
		sc.kbd(ui, "Enter")
	}
}
