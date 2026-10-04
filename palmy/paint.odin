package palmy

import "core:math"

@(private)
dev_rect :: proc(r: Rect, s: f32) -> Rect {
	return {r.x * s, r.y * s, r.w * s, r.h * s}
}

@(private)
dev_radius :: proc(r: Radius, s: f32) -> Radius {
	return {r[0] * s, r[1] * s, r[2] * s, r[3] * s}
}

@(private)
with_opacity :: proc(c: Color, o: f32) -> Color {
	return o >= 1 ? c : fade(c, o)
}

// animate eases the painted colors toward the style's targets, which is what
// makes `transition hover:bg-indigo-400` fade instead of snap.
@(private)
animate :: proc(ctx: ^Ctx, n: ^Node) -> (bg: Paint, fg, border: Color) {
	s := n.style
	bg = s.bg
	fg = s.fg
	border = s.border_col

	if s.transition <= 0 {
		return
	}

	w := widget_of(ctx, n.id)
	if !w.anim.init {
		w.anim = {bg = s.bg.color, bg2 = s.bg.color2, fg = s.fg, border = s.border_col, init = true}
		return
	}

	k := 1 - math.exp_f32(-6 * ctx.dt / s.transition)
	k = clamp(k, 0, 1)

	before := w.anim
	w.anim.bg = mix(w.anim.bg, s.bg.color, k)
	w.anim.bg2 = mix(w.anim.bg2, s.bg.color2, k)
	w.anim.fg = mix(w.anim.fg, s.fg, k)
	w.anim.border = mix(w.anim.border, s.border_col, k)

	same :: proc(a, b: Color) -> bool {
		return a.r == b.r && a.g == b.g && a.b == b.b && a.a == b.a
	}
	// Did this frame actually move anything? `mix` rounds to a u8, so once a
	// channel is one step from its target and k is small the result rounds
	// back to where it started and the colour can never close the gap. The old
	// test asked whether the gap was wider than two summed across RGBA, which
	// a stalled transition sitting one step out on three channels fails
	// forever: the element then repainted at vsync for as long as it was
	// hovered, and never reached its colour. Asking whether progress was made
	// is the question that terminates.
	progressed :=
		!same(before.bg, w.anim.bg) ||
		!same(before.bg2, w.anim.bg2) ||
		!same(before.fg, w.anim.fg) ||
		!same(before.border, w.anim.border)

	arrived :=
		same(w.anim.bg, s.bg.color) &&
		same(w.anim.bg2, s.bg.color2) &&
		same(w.anim.fg, s.fg) &&
		same(w.anim.border, s.border_col)

	if !arrived && progressed {
		ctx.animating = true
	} else {
		// Either it is there, or it cannot get closer: snap and stop asking
		// for frames.
		w.anim.bg, w.anim.bg2 = s.bg.color, s.bg.color2
		w.anim.fg, w.anim.border = s.fg, s.border_col
	}

	bg.color = w.anim.bg
	bg.color2 = w.anim.bg2
	fg = w.anim.fg
	border = w.anim.border
	return
}

@(private)
paint_tree :: proc(ctx: ^Ctx, c: ^Canvas) {
	if len(ctx.nodes) == 0 {
		return
	}
	paint_node(ctx, c, 0)
}

@(private)
paint_node :: proc(ctx: ^Ctx, c: ^Canvas, idx: int) {
	n := &ctx.nodes[idx]
	s := n.style
	if s.hidden || s.opacity <= 0.004 {
		return
	}

	sc := c.scale
	r := dev_rect(n.rect, sc)
	rad := dev_radius(clamp_radius(n.rect, s.radius), sc)

	clip := dev_rect(n.clip, sc)
	push_clip(c, clip)
	defer pop_clip(c)

	if r.w > 0 && r.h > 0 && !rect_overlaps(r, c.clip) {
		return // fully clipped away
	}

	bg, fg, border := animate(ctx, n)
	o := s.opacity

	// A ring is a box-shadow spread in CSS: it sits outside the border box and
	// is not clipped by it, so it is drawn against the parent's clip.
	if s.ring > 0 && s.ring_col.a > 0 {
		pop_clip(c)
		push_clip(c, dev_rect(ctx.nodes[max(n.parent, 0)].clip, sc))
		rw := s.ring * sc
		outer := Rect{r.x - rw, r.y - rw, r.w + 2 * rw, r.h + 2 * rw}
		orad := Radius{rad[0] + rw, rad[1] + rw, rad[2] + rw, rad[3] + rw}
		stroke_round_rect(c, outer, orad, rw, with_opacity(s.ring_col, o))
		pop_clip(c)
		push_clip(c, clip)
	}

	// Shadow, then background, then border: the usual CSS paint order.
	if s.shadow.color.a > 0 && (s.shadow.blur > 0 || s.shadow.spread != 0) {
		// A shadow escapes its own clip, so draw it against the parent's.
		pop_clip(c)
		push_clip(c, dev_rect(ctx.nodes[max(n.parent, 0)].clip, sc))
		drop_shadow(
			c,
			r,
			rad,
			s.shadow.blur * sc,
			s.shadow.spread * sc,
			{0, s.shadow.y * sc},
			with_opacity(s.shadow.color, o),
		)
		pop_clip(c)
		push_clip(c, clip)
	}

	if bg.color.a > 0 || (bg.gradient && bg.color2.a > 0) {
		p := bg
		p.color = with_opacity(p.color, o)
		p.color2 = with_opacity(p.color2, o)

		// `background-clip: padding-box` keeps the fill inside the border, so a
		// transparent border lets whatever is behind show through at the edge.
		fill_r, fill_rad := r, rad
		if s.bg_clip_pad {
			bw := s.border_w
			fill_r = Rect {
				r.x + bw[LEFT] * sc,
				r.y + bw[TOP] * sc,
				max(0, r.w - (bw[LEFT] + bw[RIGHT]) * sc),
				max(0, r.h - (bw[TOP] + bw[BOTTOM]) * sc),
			}
			fill_rad = Radius {
				max(0, rad[0] - bw[TOP] * sc),
				max(0, rad[1] - bw[TOP] * sc),
				max(0, rad[2] - bw[BOTTOM] * sc),
				max(0, rad[3] - bw[BOTTOM] * sc),
			}
		}
		fill_round_rect_paint(c, fill_r, fill_rad, p)
	}

	if border.a > 0 {
		bw := s.border_w
		if bw[TOP] == bw[RIGHT] && bw[TOP] == bw[BOTTOM] && bw[TOP] == bw[LEFT] {
			if bw[TOP] > 0 {
				stroke_round_rect(c, r, rad, bw[TOP] * sc, with_opacity(border, o))
			}
		} else {
			// Individual edges: draw each as a plain rectangle.
			col := with_opacity(border, o)
			if bw[TOP] > 0 {
				fill_rect(c, {r.x, r.y, r.w, bw[TOP] * sc}, col)
			}
			if bw[BOTTOM] > 0 {
				fill_rect(c, {r.x, rect_bottom(r) - bw[BOTTOM] * sc, r.w, bw[BOTTOM] * sc}, col)
			}
			if bw[LEFT] > 0 {
				fill_rect(c, {r.x, r.y, bw[LEFT] * sc, r.h}, col)
			}
			if bw[RIGHT] > 0 {
				fill_rect(c, {rect_right(r) - bw[RIGHT] * sc, r.y, bw[RIGHT] * sc, r.h}, col)
			}
		}
	}

	switch n.kind {
	case .Image:
		if n.img.w > 0 && n.img.h > 0 {
			inner := Rect {
				r.x + (s.border_w[LEFT] + s.pad[LEFT]) * sc,
				r.y + (s.border_w[TOP] + s.pad[TOP]) * sc,
				max(0, r.w - frame_of(s).x * sc),
				max(0, r.h - frame_of(s).y * sc),
			}
			// An image is clipped to its own box unless told otherwise, so a
			// `cover` fit crops rather than spilling over its neighbours.
			if s.overflow != .Visible || n.fit == .Cover || n.zoom > 1 {
				push_clip(c, rect_intersect(c.clip, inner))
			}
			z := n.zoom <= 0 ? 1 : n.zoom
			dst := fitted_rect(f32(n.img.w), f32(n.img.h), inner, n.fit, z)
			draw_image(c, n.img, dst, o)
			if s.overflow != .Visible || n.fit == .Cover || n.zoom > 1 {
				pop_clip(c)
			}
		}

	case .Icon:
		inner := Rect {
			r.x + (s.border_w[LEFT] + s.pad[LEFT]) * sc,
			r.y + (s.border_w[TOP] + s.pad[TOP]) * sc,
			max(0, r.w - frame_of(s).x * sc),
			max(0, r.h - frame_of(s).y * sc),
		}
		side := min(inner.w, inner.h)
		draw_icon(
			c,
			&ctx.icons,
			n.icon,
			inner.x + (inner.w - side) / 2,
			inner.y + (inner.h - side) / 2,
			side,
			with_opacity(fg, o),
			n.icon_turns,
		)

	case .Text:
		paint_text(ctx, c, n, with_opacity(fg, o))
	case .Custom:
		if n.custom != nil {
			inner := Rect {
				r.x + (s.border_w[LEFT] + s.pad[LEFT]) * sc,
				r.y + (s.border_w[TOP] + s.pad[TOP]) * sc,
				max(0, r.w - frame_of(s).x * sc),
				max(0, r.h - frame_of(s).y * sc),
			}
			push_clip(c, s.overflow != .Visible ? rect_intersect(c.clip, r) : c.clip)
			n.custom(c, inner, n.user)
			pop_clip(c)
		}
	case .Box:
	}

	paint_children(ctx, c, n)
	paint_scrollbar(ctx, c, n, sc)
}

@(private)
paint_children :: proc(ctx: ^Ctx, c: ^Canvas, n: ^Node) {
	if n.first_child < 0 {
		return
	}

	// Children, in document order unless z-index says otherwise.
	needs_sort := false
	for k := n.first_child; k >= 0; k = ctx.nodes[k].next {
		if ctx.nodes[k].style.z != 0 {
			needs_sort = true
			break
		}
	}

	if !needs_sort {
		for k := n.first_child; k >= 0; k = ctx.nodes[k].next {
			paint_node(ctx, c, k)
		}
		return
	}

	order := make([dynamic]int, 0, n.n_children, context.temp_allocator)
	for k := n.first_child; k >= 0; k = ctx.nodes[k].next {
		append(&order, k)
	}
	// A stable insertion sort by z-index; child counts here are small.
	for i in 1 ..< len(order) {
		j := i
		for j > 0 && ctx.nodes[order[j - 1]].style.z > ctx.nodes[order[j]].style.z {
			order[j - 1], order[j] = order[j], order[j - 1]
			j -= 1
		}
	}
	for k in order {
		paint_node(ctx, c, k)
	}
}

// paint_scrollbar draws a slim indicator over a scrolling region. It appears
// only when there is something to scroll to.
@(private)
paint_scrollbar :: proc(ctx: ^Ctx, c: ^Canvas, n: ^Node, sc: f32) {
	if n.style.overflow != .Scroll {
		return
	}
	w, found := ctx.widgets[n.id]
	if !found || w.over.y <= 0.5 || w.view.y <= 0 {
		return
	}

	track := w.view.y * sc
	thumb := max(track * (w.view.y / (w.view.y + w.over.y)), 24 * sc)
	t := clamp(w.scroll.y / w.over.y, 0, 1)

	s := n.style
	x := (n.rect.x + n.rect.w - s.border_w[RIGHT]) * sc - 7 * sc
	y := (n.rect.y + s.border_w[TOP] + s.pad[TOP]) * sc + (track - thumb) * t

	r := Rect{x, y, 4 * sc, thumb}
	rad := Radius{2 * sc, 2 * sc, 2 * sc, 2 * sc}
	fill_round_rect(c, r, rad, Color{148, 163, 184, 90}) // slate-400, faint
}

@(private)
paint_text :: proc(ctx: ^Ctx, c: ^Canvas, n: ^Node, col: Color) {
	s := n.style
	if len(n.lines) == 0 || col.a == 0 {
		return
	}
	sc := c.scale
	fr := frame_of(s)
	inner := Rect {
		n.rect.x + s.border_w[LEFT] + s.pad[LEFT],
		n.rect.y + s.border_w[TOP] + s.pad[TOP],
		max(0, n.rect.w - fr.x),
		max(0, n.rect.h - fr.y),
	}

	size := s.font_size * sc
	m := font_metrics(ctx.fonts, size, s.family, s.weight, s.slant)
	lh := line_height_of(s) * sc
	tracking := s.tracking_em * size

	y := inner.y * sc
	for line, i in n.lines {
		baseline := y + (lh - (m.ascent + m.descent)) / 2 + m.ascent
		w := line.width * sc

		// Start and End are the only alignments that depend on the text: they
		// resolve against the paragraph's base direction, so a Hebrew or
		// Arabic paragraph sits on the right without anything being set.
		align_x :: proc(s: Style, inner_w, w: f32, rtl: bool) -> f32 {
			switch s.text_align {
			case .Center:
				return (inner_w - w) / 2
			case .Right:
				return inner_w - w
			case .Left:
				return 0
			case .Start:
				return rtl ? inner_w - w : 0
			case .End:
				return rtl ? 0 : inner_w - w
			}
			return 0
		}

		rtl := line.dir == .RTL
		x := inner.x * sc + align_x(s, inner.w * sc, w, rtl)

		str := line.text
		if s.truncate && w > inner.w * sc && len(str) > 0 {
			str = truncate_to(ctx, str, inner.w * sc, size, s, tracking, line.dir)
			tw := text_width(
				ctx.fonts,
				str,
				size,
				s.family,
				s.weight,
				tracking,
				s.slant,
				s.tabular,
				line.dir,
			)
			x = inner.x * sc + align_x(s, inner.w * sc, tw, rtl)
		}

		// An outline is a style, so it is drawn by the same call rather than by
		// the caller painting the run again in another colour.
		outline := Text_Outline{}
		if s.outline_w > 0 && s.outline_col.a > 0 {
			outline = {width = s.outline_w * sc, color = with_opacity(s.outline_col, s.opacity)}
		}
		adv := draw_text(
			c,
			ctx.fonts,
			str,
			x,
			baseline,
			size,
			col,
			s.family,
			s.weight,
			tracking,
			s.slant,
			s.tabular,
			outline,
			line.dir,
		)

		if s.strike || s.underline {
			thickness := max(size * 0.07, 1)
			if s.strike {
				fill_rect(c, {x, baseline - m.ascent * 0.32, adv, thickness}, col)
			}
			if s.underline {
				fill_rect(c, {x, baseline + m.descent * 0.35, adv, thickness}, col)
			}
		}

		y += lh
		_ = i
	}
}

// truncate_to shortens a string so that it fits, with a trailing ellipsis.
@(private)
// The `dir` is the paragraph's, not the substring's. Measuring str[:i] with
// .Auto re-infers a direction from whatever the prefix happens to contain, so
// a Latin prefix of a Hebrew paragraph would be measured as a left-to-right
// run and budgeted wrongly. Passing the paragraph's direction keeps every
// measurement here in the same frame of reference as the line it belongs to.
//
// Known limit: this cuts the *logical* prefix. For a wholly right-to-left
// paragraph that is right, since the logical prefix is the visual right-hand
// side and the neutral ellipsis resolves to the paragraph level on the left.
// For a line mixing directions it is not: the kept prefix can reorder once the
// ellipsis is appended and re-resolved. Truncating over text_glyphs visually
// is the correct fix and is not done here.
truncate_to :: proc(
	ctx: ^Ctx,
	str: string,
	max_w, size: f32,
	s: Style,
	tracking: f32,
	dir := Bidi_Direction.Auto,
) -> string {
	ell := "…"
	ew := text_width(
		ctx.fonts,
		ell,
		size,
		s.family,
		s.weight,
		tracking,
		s.slant,
		s.tabular,
		dir,
	)
	if ew >= max_w {
		return ""
	}
	budget := max_w - ew
	end := 0
	for i in 0 ..< len(str) {
		// Only cut on rune boundaries.
		if str[i] & 0xc0 == 0x80 {
			continue
		}
		if text_width(
			   ctx.fonts,
			   str[:i],
			   size,
			   s.family,
			   s.weight,
			   tracking,
			   s.slant,
			   s.tabular,
			   dir,
		   ) >
		   budget {
			break
		}
		end = i
	}
	return concat_frame(ctx, str[:end], ell)
}

@(private)
concat_frame :: proc(ctx: ^Ctx, a, b: string) -> string {
	out := make([]u8, len(a) + len(b), ctx.alloc)
	copy(out[:], a)
	copy(out[len(a):], b)
	return string(out)
}
