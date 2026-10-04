package palmy

import "core:strings"

// Flexbox layout.
//
// Two passes, both recursive. `measure` walks down with the space available and
// returns the size each subtree wants; `arrange` walks down again handing out
// final rectangles, resolving grow, shrink, justification and alignment.
// Sizes are logical pixels; `box-sizing: border-box` is assumed throughout,
// which is what Tailwind's preflight sets.

@(private)
INDEFINITE :: f32(-1)

@(private)
line_height_of :: proc(s: Style) -> f32 {
	return s.leading_px > 0 ? s.leading_px : s.font_size * s.leading
}

@(private)
resolve_dim :: proc(ctx: ^Ctx, d: Dim, parent: f32, axis: int) -> f32 {
	switch d.kind {
	case .Px:
		return d.v
	case .Pct:
		return parent >= 0 ? parent * d.v / 100 : INDEFINITE
	case .Screen:
		return ctx.viewport[axis]
	case .Auto:
		return INDEFINITE
	}
	return INDEFINITE
}

@(private)
frame_of :: proc(s: Style) -> [2]f32 {
	return {
		s.pad[LEFT] + s.pad[RIGHT] + s.border_w[LEFT] + s.border_w[RIGHT],
		s.pad[TOP] + s.pad[BOTTOM] + s.border_w[TOP] + s.border_w[BOTTOM],
	}
}

@(private)
margin_of :: proc(s: Style, axis: int) -> f32 {
	return axis == 0 ? s.margin[LEFT] + s.margin[RIGHT] : s.margin[TOP] + s.margin[BOTTOM]
}

@(private)
clamp_dim :: proc(ctx: ^Ctx, v: f32, lo, hi: Dim, parent: f32, axis: int) -> f32 {
	out := v
	if l := resolve_dim(ctx, lo, parent, axis); l != INDEFINITE {
		out = max(out, l)
	}
	if h := resolve_dim(ctx, hi, parent, axis); h != INDEFINITE {
		out = min(out, h)
	}
	return out
}

// ---------------------------------------------------------------------------
// Text
// ---------------------------------------------------------------------------

// wrap_text breaks a string into lines that fit `max_w`, honouring explicit
// newlines. A negative width means "do not wrap".
@(private)
wrap_text :: proc(ctx: ^Ctx, n: ^Node, max_w: f32) -> [2]f32 {
	s := n.style
	tracking := s.tracking_em * s.font_size
	lh := line_height_of(s)

	lines := make([dynamic]Text_Line, ctx.alloc)

	emit :: proc(ctx: ^Ctx, lines: ^[dynamic]Text_Line, str: string, s: Style, tracking: f32) {
		w := text_width(ctx.fonts, str, s.font_size, s.family, s.weight, tracking)
		append(lines, Text_Line{text = str, width = w})
	}

	widest := f32(0)
	paragraphs := strings.split(n.text, "\n", ctx.alloc)
	for para in paragraphs {
		if max_w < 0 || s.nowrap {
			emit(ctx, &lines, para, s, tracking)
			continue
		}
		if text_width(ctx.fonts, para, s.font_size, s.family, s.weight, tracking) <= max_w {
			emit(ctx, &lines, para, s, tracking)
			continue
		}

		// Greedy word wrap. Words longer than the line are left to overflow,
		// which is the least surprising behaviour for things like URLs.
		start := 0
		last_break := -1
		i := 0
		for i <= len(para) {
			at_end := i == len(para)
			if !at_end && para[i] != ' ' {
				i += 1
				continue
			}
			candidate := para[start:i]
			w := text_width(ctx.fonts, candidate, s.font_size, s.family, s.weight, tracking)
			if w > max_w && last_break > start {
				emit(ctx, &lines, para[start:last_break], s, tracking)
				start = last_break + 1
				last_break = -1
				i = start
				continue
			}
			if at_end {
				emit(ctx, &lines, candidate, s, tracking)
				break
			}
			last_break = i
			i += 1
		}
	}

	for l in lines {
		widest = max(widest, l.width)
	}
	n.lines = lines[:]
	return {widest, f32(len(lines)) * lh}
}

// ---------------------------------------------------------------------------
// Measure
// ---------------------------------------------------------------------------

@(private)
measure :: proc(ctx: ^Ctx, idx: int, avail: [2]f32) -> [2]f32 {
	n := &ctx.nodes[idx]
	s := n.style
	if s.hidden {
		n.content = {0, 0}
		return n.content
	}

	fr := frame_of(s)

	// Definite sizes short-circuit the content measurement for that axis.
	own := [2]f32{resolve_dim(ctx, s.w, avail.x, 0), resolve_dim(ctx, s.h, avail.y, 1)}
	inner := [2]f32{INDEFINITE, INDEFINITE}
	for a in 0 ..< 2 {
		if own[a] != INDEFINITE {
			inner[a] = max(0, own[a] - fr[a])
		} else if avail[a] != INDEFINITE {
			inner[a] = max(0, avail[a] - fr[a] - margin_of(s, a))
		}
	}

	content := [2]f32{0, 0}

	switch n.kind {
	case .Text:
		// Prefer the width this node actually had last frame: layouts are
		// stable, so this makes wrapping converge immediately instead of
		// lagging a frame behind grow and shrink.
		wrap_w := inner.x
		if w, found := ctx.widgets[n.id]; found && w.rect.w > 0 {
			hint := w.rect.w - fr.x
			wrap_w = wrap_w == INDEFINITE ? hint : min(wrap_w, hint)
		}
		if s.max_w.kind != .Auto {
			if m := resolve_dim(ctx, s.max_w, avail.x, 0); m != INDEFINITE {
				wrap_w = wrap_w == INDEFINITE ? m - fr.x : min(wrap_w, m - fr.x)
			}
		}
		content = wrap_text(ctx, n, wrap_w)

	case .Custom:
		content = {0, 0}

	case .Icon:
		// An icon behaves like an inline square the size of the text.
		content = {s.font_size, s.font_size}

	case .Image:
		// An image's intrinsic size is its pixel size, as in CSS.
		content = {f32(n.img.w), f32(n.img.h)}

	case .Box:
		main := s.dir == .Row ? 0 : 1
		cross := 1 - main
		gap_main := s.dir == .Row ? s.gap.x : s.gap.y
		gap_cross := s.dir == .Row ? s.gap.y : s.gap.x

		run_main := f32(0)
		run_cross := f32(0)
		total_cross := f32(0)
		count := 0
		lines := 1

		for c := n.first_child; c >= 0; c = ctx.nodes[c].next {
			cs := ctx.nodes[c].style
			if cs.hidden {
				continue
			}

			// A child only sees definite space on the cross axis when it is
			// going to be stretched into it. Otherwise it is shrink-to-fit,
			// and percentages behave as `auto` while measuring, the same way
			// CSS resolves intrinsic sizes.
			child_avail := inner
			align := cs.self != .Auto ? cs.self : s.items
			cross_dim := cross == 0 ? cs.w : cs.h
			if cross_dim.kind == .Auto && align != .Stretch {
				child_avail[cross] = INDEFINITE
			}

			kid := measure(ctx, c, child_avail)
			if cs.position == .Absolute {
				continue
			}

			kid_main := kid[main] + margin_of(cs, main)
			kid_cross := kid[cross] + margin_of(cs, cross)

			if s.wrap && count > 0 && inner[main] != INDEFINITE &&
			   run_main + gap_main + kid_main > inner[main] {
				// Start a new flex line.
				total_cross += run_cross + gap_cross
				run_cross = 0
				run_main = 0
				lines += 1
			}
			if run_main > 0 {
				run_main += gap_main
			}
			run_main += kid_main
			run_cross = max(run_cross, kid_cross)
			content[main] = max(content[main], run_main)
			count += 1
		}
		total_cross += run_cross
		content[cross] = total_cross
	}

	// Fold in padding and borders, then the node's own constraints.
	for a in 0 ..< 2 {
		if own[a] != INDEFINITE {
			content[a] = own[a]
		} else {
			content[a] += fr[a]
		}
		lo := a == 0 ? s.min_w : s.min_h
		hi := a == 0 ? s.max_w : s.max_h
		content[a] = clamp_dim(ctx, content[a], lo, hi, avail[a], a)
	}

	n.content = content
	return content
}


// baseline_of returns the distance from an element's top edge to the baseline
// of its first line of text, which is what `items-baseline` aligns on. Boxes
// delegate to their first text descendant; anything with no text falls back to
// its bottom edge, the way CSS does.
@(private)
baseline_of :: proc(ctx: ^Ctx, idx: int, height: f32) -> f32 {
	i := idx
	offset := f32(0)
	for depth := 0; i >= 0 && depth < 8; depth += 1 {
		n := &ctx.nodes[i]
		s := n.style
		offset += s.border_w[TOP] + s.pad[TOP]
		if n.kind == .Text {
			m := font_metrics(ctx.fonts, s.font_size, s.family, s.weight)
			lh := line_height_of(s)
			return offset + (lh - (m.ascent + m.descent)) / 2 + m.ascent
		}
		i = n.first_child
	}
	return height
}

// ---------------------------------------------------------------------------
// Arrange
// ---------------------------------------------------------------------------

@(private)
Child_Box :: struct {
	idx:   int,
	base:  f32,
	size:  [2]f32,
	line:  int,
}

@(private)
arrange :: proc(ctx: ^Ctx, idx: int, box: Rect, clip: Rect) {
	n := &ctx.nodes[idx]
	s := n.style
	n.rect = box
	n.clip = clip
	if s.hidden {
		return
	}

	if n.kind == .Text {
		// Re-wrap if the final width turned out narrower than measured.
		inner_w := box.w - frame_of(s).x
		if !s.nowrap && inner_w > 0 {
			size := wrap_text(ctx, n, inner_w)
			n.content.y = size.y + frame_of(s).y
		}
		return
	}
	if n.first_child < 0 {
		return
	}

	fr := frame_of(s)
	cb := Rect {
		box.x + s.border_w[LEFT] + s.pad[LEFT],
		box.y + s.border_w[TOP] + s.pad[TOP],
		max(0, box.w - fr.x),
		max(0, box.h - fr.y),
	}

	child_clip := clip
	if s.overflow != .Visible {
		child_clip = rect_intersect(clip, box)
	}

	main := s.dir == .Row ? 0 : 1
	cross := 1 - main
	gap_main := s.dir == .Row ? s.gap.x : s.gap.y
	gap_cross := s.dir == .Row ? s.gap.y : s.gap.x
	avail_main := cb.w if main == 0 else cb.h
	avail_cross := cb.h if main == 0 else cb.w

	kids := make([dynamic]Child_Box, 0, n.n_children, context.temp_allocator)
	abs := make([dynamic]int, 0, 4, context.temp_allocator)

	// Collect flex items and group them into lines.
	line := 0
	line_main := f32(0)
	for c := n.first_child; c >= 0; c = ctx.nodes[c].next {
		cs := ctx.nodes[c].style
		if cs.hidden {
			continue
		}
		if cs.position == .Absolute {
			append(&abs, c)
			continue
		}

		base := ctx.nodes[c].content[main]

		// Re-resolve a definite main-axis size against the space this
		// container actually got. `measure` resolved it against the space the
		// container was *offered*, which near the root is the whole window, so
		// a percentage -- `h-full` on a child of a column -- came back as the
		// window height and then survived into `arrange` as the item's base.
		// For a pixel size this recomputes the same number; only percentages
		// move, which is the case that was wrong.
		if d := main == 0 ? cs.w : cs.h; d.kind == .Pct {
			if v := resolve_dim(ctx, d, avail_main, main); v != INDEFINITE {
				base = v
			}
		}
		if b := resolve_dim(ctx, cs.basis, avail_main, main); b != INDEFINITE {
			base = b + (main == 0 ? frame_of(cs).x : frame_of(cs).y)
		}
		base = clamp_dim(
			ctx,
			base,
			main == 0 ? cs.min_w : cs.min_h,
			main == 0 ? cs.max_w : cs.max_h,
			avail_main,
			main,
		)

		item_main := base + margin_of(cs, main)
		if s.wrap && len(kids) > 0 && line_main + gap_main + item_main > avail_main {
			line += 1
			line_main = 0
		}
		if line_main > 0 {
			line_main += gap_main
		}
		line_main += item_main

		append(&kids, Child_Box{idx = c, base = base, line = line})
	}

	n_lines := line + 1

	// Resolve each line independently: grow or shrink to the container, then
	// size the cross axis.
	line_cross := make([]f32, n_lines, context.temp_allocator)
	line_offset := make([]f32, n_lines, context.temp_allocator)

	for ln in 0 ..< n_lines {
		used := f32(0)
		grow_sum := f32(0)
		shrink_weight := f32(0)
		count := 0
		for &k in kids {
			if k.line != ln {
				continue
			}
			cs := ctx.nodes[k.idx].style
			used += k.base + margin_of(cs, main)
			grow_sum += cs.grow
			shrink_weight += cs.shrink * k.base
			count += 1
		}
		if count > 1 {
			used += gap_main * f32(count - 1)
		}

		free := avail_main - used
		for &k in kids {
			if k.line != ln {
				continue
			}
			cs := ctx.nodes[k.idx].style
			size := k.base
			if free > 0 && cs.grow > 0 && grow_sum > 0 {
				size += free * cs.grow / grow_sum
			} else if free < 0 && cs.shrink > 0 && shrink_weight > 0 {
				size += free * (cs.shrink * k.base) / shrink_weight

				// CSS gives flex items an automatic minimum size: they refuse
				// to shrink below their own content unless they are able to
				// scroll or clip it. Without this a scrolling column squashes
				// its contents instead of overflowing them.
				min_dim := main == 0 ? cs.min_w : cs.min_h
				if min_dim.kind == .Auto && cs.overflow == .Visible {
					size = max(size, ctx.nodes[k.idx].content[main])
				}
			}
			size = clamp_dim(
				ctx,
				max(size, 0),
				main == 0 ? cs.min_w : cs.min_h,
				main == 0 ? cs.max_w : cs.max_h,
				avail_main,
				main,
			)

			// Cross axis.
			align := cs.self != .Auto ? cs.self : s.items
			cross_size := resolve_dim(
				ctx,
				main == 0 ? cs.h : cs.w,
				avail_cross,
				cross,
			)
			if cross_size == INDEFINITE {
				if align == .Stretch && !s.wrap {
					cross_size = max(0, avail_cross - margin_of(cs, cross))
				} else {
					cross_size = ctx.nodes[k.idx].content[cross]
				}
			}
			cross_size = clamp_dim(
				ctx,
				cross_size,
				main == 0 ? cs.min_h : cs.min_w,
				main == 0 ? cs.max_h : cs.max_w,
				avail_cross,
				cross,
			)

			k.size[main] = size
			k.size[cross] = cross_size
			line_cross[ln] = max(line_cross[ln], cross_size + margin_of(cs, cross))
		}
	}

	// Stack the lines along the cross axis.
	off := f32(0)
	for ln in 0 ..< n_lines {
		line_offset[ln] = off
		off += line_cross[ln] + gap_cross
	}
	content_cross := off - gap_cross if n_lines > 0 else 0

	// Scrolling containers can overflow along the main axis.
	scroll := [2]f32{0, 0}
	if s.overflow == .Scroll {
		w := widget_of(ctx, n.id)
		content_main := f32(0)
		for k in kids {
			cs := ctx.nodes[k.idx].style
			content_main += k.size[main] + margin_of(cs, main)
		}
		if len(kids) > 1 {
			content_main += gap_main * f32(len(kids) - 1)
		}
		over := [2]f32{}
		over[main] = max(0, content_main - avail_main)
		over[cross] = max(0, content_cross - avail_cross)
		w.scroll.x = clamp(w.scroll.x, 0, over.x)
		w.scroll.y = clamp(w.scroll.y, 0, over.y)
		w.over = over
		w.view = {cb.w, cb.h}
		scroll = w.scroll
	}

	for ln in 0 ..< n_lines {
		// Justify along the main axis.
		used := f32(0)
		count := 0
		for k in kids {
			if k.line != ln {
				continue
			}
			used += k.size[main] + margin_of(ctx.nodes[k.idx].style, main)
			count += 1
		}
		if count == 0 {
			continue
		}
		used += gap_main * f32(count - 1)
		free := max(0, avail_main - used)

		// Elements aligned on the baseline share the deepest one in the line.
		max_base := f32(0)
		if main == 0 {
			for k in kids {
				if k.line != ln {
					continue
				}
				cs := ctx.nodes[k.idx].style
				align := cs.self != .Auto ? cs.self : s.items
				if align == .Baseline {
					max_base = max(max_base, baseline_of(ctx, k.idx, k.size[cross]))
				}
			}
		}

		cursor := f32(0)
		between := gap_main
		switch s.justify {
		case .Start:
		case .Center:
			cursor = free / 2
		case .End:
			cursor = free
		case .Between:
			if count > 1 {
				between += free / f32(count - 1)
			}
		case .Around:
			if count > 0 {
				between += free / f32(count)
				cursor = between / 2 - gap_main / 2
			}
		case .Evenly:
			if count > 0 {
				between += free / f32(count + 1)
				cursor = between - gap_main
			}
		}

		for k in kids {
			if k.line != ln {
				continue
			}
			cs := ctx.nodes[k.idx].style
			align := cs.self != .Auto ? cs.self : s.items

			// A single flex line is positioned against the container's content
			// box, not against its own tallest child: CSS lets an oversized
			// item overhang symmetrically rather than pinning it to the top.
			extent := n_lines == 1 ? avail_cross : line_cross[ln]
			cross_pos := line_offset[ln]
			slack := extent - (k.size[cross] + margin_of(cs, cross))
			switch align {
			case .Center:
				cross_pos += slack / 2
			case .End:
				cross_pos += slack
			case .Baseline:
				if main == 0 {
					cross_pos += max(0, max_base - baseline_of(ctx, k.idx, k.size[cross]))
				}
			case .Start, .Stretch, .Auto:
			}

			// Horizontal centering via `mx-auto`.
			if cs.margin_auto_x {
				if main == 0 {
					cursor += free / 2
					free = 0
				} else {
					// In a column, `mx-auto` centres within the line.
					cross_pos = line_offset[ln] + max(0, (extent - k.size[cross]) / 2)
				}
			}

			pos := [2]f32{}
			pos[main] = cursor + (main == 0 ? cs.margin[LEFT] : cs.margin[TOP])
			pos[cross] = cross_pos + (cross == 0 ? cs.margin[LEFT] : cs.margin[TOP])

			kid_box := Rect {
				cb.x + pos.x - scroll.x,
				cb.y + pos.y - scroll.y,
				k.size.x,
				k.size.y,
			}
			arrange(ctx, k.idx, kid_box, child_clip)

			cursor += k.size[main] + margin_of(cs, main) + between
		}
	}

	// Absolutely positioned children resolve against the padding box, which is
	// what CSS uses for a containing block — the padding counts as space they
	// can be placed into, unlike for flow children.
	pb := Rect {
		box.x + s.border_w[LEFT],
		box.y + s.border_w[TOP],
		max(0, box.w - s.border_w[LEFT] - s.border_w[RIGHT]),
		max(0, box.h - s.border_w[TOP] - s.border_w[BOTTOM]),
	}
	for c in abs {
		cs := ctx.nodes[c].style
		kw := resolve_dim(ctx, cs.w, pb.w, 0)
		kh := resolve_dim(ctx, cs.h, pb.h, 1)
		l := resolve_dim(ctx, cs.inset[LEFT], pb.w, 0)
		r := resolve_dim(ctx, cs.inset[RIGHT], pb.w, 0)
		t := resolve_dim(ctx, cs.inset[TOP], pb.h, 1)
		b := resolve_dim(ctx, cs.inset[BOTTOM], pb.h, 1)

		if kw == INDEFINITE {
			kw = l != INDEFINITE && r != INDEFINITE ? max(0, pb.w - l - r) : ctx.nodes[c].content.x
		}
		if kh == INDEFINITE {
			kh = t != INDEFINITE && b != INDEFINITE ? max(0, pb.h - t - b) : ctx.nodes[c].content.y
		}
		x := pb.x + (l != INDEFINITE ? l : (r != INDEFINITE ? pb.w - r - kw : 0))
		y := pb.y + (t != INDEFINITE ? t : (b != INDEFINITE ? pb.h - b - kh : 0))

		arrange(ctx, c, {x, y, kw, kh}, child_clip)
	}
}

// layout_tree lays out the whole frame into the window.
@(private)
layout_tree :: proc(ctx: ^Ctx, viewport: Rect) {
	if len(ctx.nodes) == 0 {
		return
	}
	measure(ctx, 0, {viewport.w, viewport.h})
	arrange(ctx, 0, viewport, viewport)

	// Record geometry for next frame's hit testing.
	for &n in ctx.nodes {
		w := widget_of(ctx, n.id)
		w.rect = n.rect
		w.clip = n.clip
	}
}
