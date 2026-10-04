package palmy

import "core:math"
import "core:strings"

// push_styled applies palmy's own defaults first and the caller's classes
// second, so anything you write wins over the built-in look.
@(private)
push_styled :: proc(ctx: ^Ctx, kind: Node_Kind, base, user: string, disabled := false) -> int {
	idx := push_node(ctx, kind, base, disabled)
	if user != "" {
		apply_classes(
			&ctx.nodes[idx].style,
			user,
			interaction_of(ctx, ctx.nodes[idx].id, disabled),
		)
	}
	return idx
}

// clickable marks an element as interactive and reports a completed click.
// This is how a plain `div` becomes a card you can press:
//
//	palmy.div(ui, "p-4 bg-slate-900 hover:bg-slate-800 rounded-xl transition")
//	if palmy.clickable(ui) { open(item) }
//	palmy.text(ui, item.name)
//	palmy.end(ui)
clickable :: proc(ctx: ^Ctx, idx := -1) -> bool {
	i := idx >= 0 ? idx : top(ctx)
	if i < 0 || i >= len(ctx.nodes) {
		return false
	}
	ctx.nodes[i].interactive = true
	return ctx.clicked == ctx.nodes[i].id
}

// focusable puts an element in the Tab order and lets it take keyboard focus.
// Pair it with `activated` for a control that works without a pointer.
focusable :: proc(ctx: ^Ctx, idx := -1) {
	i := idx >= 0 ? idx : top(ctx)
	if i < 0 || i >= len(ctx.nodes) {
		return
	}
	ctx.nodes[i].interactive = true
	ctx.nodes[i].focusable = true
}

// activated reports a click, or Enter/Space while the element holds focus —
// the behaviour a button is expected to have.
activated :: proc(ctx: ^Ctx, idx := -1) -> bool {
	i := idx >= 0 ? idx : top(ctx)
	if i < 0 || i >= len(ctx.nodes) {
		return false
	}
	id := ctx.nodes[i].id
	if ctx.focus == id && (key_pressed(ctx, KEY_RETURN) || key_pressed(ctx, KEY_SPACE)) {
		return true
	}
	return ctx.clicked == id
}

// is_hovered and is_active report the pointer state of an element, as of the
// frame that is being built.
is_hovered :: proc(ctx: ^Ctx, idx := -1) -> bool {
	i := idx >= 0 ? idx : top(ctx)
	return i >= 0 && i < len(ctx.nodes) && ctx.hot == ctx.nodes[i].id
}

is_active :: proc(ctx: ^Ctx, idx := -1) -> bool {
	i := idx >= 0 ? idx : top(ctx)
	return i >= 0 && i < len(ctx.nodes) && ctx.active == ctx.nodes[i].id
}

// focused reports whether an element holds keyboard focus.
focused :: proc(ctx: ^Ctx, idx := -1) -> bool {
	i := idx >= 0 ? idx : top(ctx)
	return i >= 0 && i < len(ctx.nodes) && ctx.focus == ctx.nodes[i].id
}

@(private)
BUTTON_BASE :: "flex-row items-center justify-center shrink-0 px-4 py-2 rounded-lg " +
	"bg-slate-800 hover:bg-slate-700 active:bg-slate-900 border border-slate-700 " +
	"text-slate-100 text-sm font-semibold transition duration-120 cursor-pointer disabled:opacity-40 disabled:cursor-not-allowed"

// button draws a pressable button and returns true on the frame it is clicked.
//
//	if palmy.button(ui, "Save", "bg-indigo-500 hover:bg-indigo-400 border-indigo-400") {
//		save()
//	}
button :: proc(ctx: ^Ctx, label: string, class: string = "", disabled := false) -> bool {
	idx := push_styled(ctx, .Box, BUTTON_BASE, class, disabled)
	id := ctx.nodes[idx].id
	ctx.nodes[idx].interactive = !disabled
	ctx.nodes[idx].focusable = !disabled

	append(&ctx.stack, idx)
	t := text(ctx, label, "whitespace-nowrap")
	ctx.nodes[t].style.shrink = 0
	end(ctx)

	if disabled {
		return false
	}
	if ctx.focus == id && (key_pressed(ctx, KEY_RETURN) || key_pressed(ctx, KEY_SPACE)) {
		return true
	}
	return ctx.clicked == id
}

// checkbox toggles the bool it is given, and returns true when it changed.
checkbox :: proc(ctx: ^Ctx, label: string, value: ^bool, class: string = "") -> bool {
	idx := push_styled(ctx, .Box, "flex-row items-center gap-2.5 shrink-0 cursor-pointer", class)
	id := ctx.nodes[idx].id
	ctx.nodes[idx].interactive = true
	ctx.nodes[idx].focusable = true
	append(&ctx.stack, idx)

	changed := ctx.clicked == id
	if !changed && ctx.focus == id && (key_pressed(ctx, KEY_SPACE) || key_pressed(ctx, KEY_RETURN)) {
		changed = true
	}
	if changed {
		value^ = !value^
	}

	box_class := "size-[18] rounded-md bg-slate-900 border border-slate-600 hover:border-slate-400 transition shrink-0"
	if value^ {
		box_class = "size-[18] rounded-md bg-indigo-500 border border-indigo-400 transition shrink-0"
	}
	mark := push_styled(ctx, .Custom, box_class, "")
	ctx.nodes[mark].custom = Custom_Fn(check_mark)
	ctx.nodes[mark].user = rawptr(value)

	if label != "" {
		text(ctx, label, "text-sm")
	}
	end(ctx)
	return changed
}

@(private)
check_mark :: proc(c: ^Canvas, r: Rect, on: ^bool) {
	if !on^ {
		return
	}
	s := min(r.w, r.h)
	t := max(s * 0.14, 1.1)
	draw_line(c, r.x + s * 0.24, r.y + s * 0.52, r.x + s * 0.44, r.y + s * 0.72, t, WHITE)
	draw_line(c, r.x + s * 0.44, r.y + s * 0.72, r.x + s * 0.78, r.y + s * 0.28, t, WHITE)
}

// toggle is a switch. It animates its knob between the two positions.
toggle :: proc(ctx: ^Ctx, value: ^bool, class: string = "") -> bool {
	idx := push_styled(
		ctx,
		.Box,
		"relative shrink-0 w-11 h-6 rounded-full transition duration-150 " +
		"bg-slate-700 hover:bg-slate-600 cursor-pointer",
		class,
	)
	id := ctx.nodes[idx].id
	ctx.nodes[idx].interactive = true
	ctx.nodes[idx].focusable = true
	if value^ {
		apply_classes(&ctx.nodes[idx].style, "bg-indigo-500 hover:bg-indigo-400", interaction_of(ctx, id))
	}
	append(&ctx.stack, idx)

	changed := ctx.clicked == id
	if !changed && ctx.focus == id && key_pressed(ctx, KEY_SPACE) {
		changed = true
	}
	if changed {
		value^ = !value^
	}

	pos := state(ctx, "palmy.toggle.pos", f32(0))
	target := value^ ? f32(1) : 0
	k := clamp(1 - math.exp_f32(-10 * ctx.dt), 0, 1)
	pos^ += (target - pos^) * k
	if abs(target - pos^) > 0.002 {
		ctx.animating = true
	} else {
		pos^ = target
	}

	knob := push_styled(ctx, .Box, "absolute size-5 rounded-full bg-white shadow-sm", "")
	ctx.nodes[knob].style.inset[TOP] = px(2)
	ctx.nodes[knob].style.inset[LEFT] = px(2 + pos^ * 20)

	end(ctx)
	return changed
}

// slider drags `value` between `low` and `high`, returning true while it moves.
slider :: proc(ctx: ^Ctx, value: ^f32, low, high: f32, class: string = "") -> bool {
	idx := push_styled(
		ctx,
		.Box,
		"relative h-5 flex-1 items-center justify-start flex-row cursor-pointer",
		class,
	)
	id := ctx.nodes[idx].id
	ctx.nodes[idx].interactive = true
	ctx.nodes[idx].focusable = true
	append(&ctx.stack, idx)

	track := rect_of(ctx, id)
	changed := false
	if ctx.active == id && track.w > 1 {
		t := clamp((ctx.input.mouse.x - track.x) / track.w, 0, 1)
		nv := low + (high - low) * t
		if nv != value^ {
			value^ = nv
			changed = true
		}
	}
	if ctx.focus == id {
		step := (high - low) / 50
		if key_pressed(ctx, KEY_LEFT) {
			value^ = max(low, value^ - step)
			changed = true
		}
		if key_pressed(ctx, KEY_RIGHT) {
			value^ = min(high, value^ + step)
			changed = true
		}
	}
	frac := high > low ? clamp((value^ - low) / (high - low), 0, 1) : 0

	// Track, filled portion, knob.
	t := push_styled(ctx, .Box, "absolute h-1.5 rounded-full bg-slate-700", "")
	ctx.nodes[t].style.inset[LEFT] = px(0)
	ctx.nodes[t].style.inset[RIGHT] = px(0)
	ctx.nodes[t].style.self = .Center

	f := push_styled(ctx, .Box, "absolute h-1.5 rounded-full bg-indigo-500", "")
	ctx.nodes[f].style.inset[LEFT] = px(0)
	ctx.nodes[f].style.w = pct(frac * 100)

	k := push_styled(
		ctx,
		.Box,
		"absolute size-4 rounded-full bg-white shadow-sm border border-slate-300",
		"",
	)
	ctx.nodes[k].style.inset[LEFT] = pct(frac * 100)
	ctx.nodes[k].style.margin[LEFT] = -8

	end(ctx)
	return changed
}

// progress draws a determinate bar; `frac` is 0..1.
progress :: proc(ctx: ^Ctx, frac: f32, class: string = "") -> int {
	// Same reasoning as FIELD_BASE: a built-in fallback, then theme tokens that
	// win where they are defined. The track was `bg-slate-800` and the bar
	// `bg-indigo-500`, both invisible-to-wrong on a light theme.
	idx := push_styled(
		ctx,
		.Box,
		"h-2 w-full rounded-full overflow-hidden bg-slate-300 bg-secondary",
		class,
	)
	append(&ctx.stack, idx)
	bar := push_styled(ctx, .Box, "h-full rounded-full transition bg-indigo-500 bg-primary", "")
	ctx.nodes[bar].style.w = pct(clamp(frac, 0, 1) * 100)
	end(ctx)
	return idx
}

// The built-in palette classes come first as a fallback for an app that
// registers no theme at all; the tokens after them win wherever a theme
// defines them, and are simply skipped where it does not (parse_color reports
// an unknown token as not-ok and the class is dropped, so a partial palette
// degrades to the fallback rather than to an invisible field).
//
// These were `bg-slate-900 border-slate-700 focus:border-indigo-400`, which
// hardcoded a dark palette: on a light theme the field rendered as a navy box
// with near-black text in it. shadcn's own input (`sc.input`) is the reference
// here -- transparent fill, `border-input`, `border-ring` on focus.
@(private)
FIELD_BASE :: "flex-row items-center h-10 px-3 rounded-lg cursor-text " +
	"overflow-hidden text-sm transition border " +
	// The fallback is a self-contained light field -- fill, text and border
	// together -- so it stays readable on a page of any colour when no theme is
	// registered. An earlier attempt used a transparent fill and inherited the
	// text colour, which looked right under a shadcn theme and rendered
	// slate-200 text on a white page without one: invisible.
	"bg-white text-slate-900 border-slate-400 hover:border-slate-500 focus:border-indigo-400 " +
	// Tokens override all three where a theme defines them. parse_color reports
	// an unknown token as not-ok and the class is dropped, so a partial palette
	// falls back rather than losing a colour it needs.
	"bg-background text-foreground border-input hover:border-ring focus:border-ring"

// text_field edits a byte buffer in place. It returns whether the text changed
// this frame and whether Enter was pressed.
//
//	buf := palmy.state(ui, "name", [dynamic]u8{})
//	changed, submitted := palmy.text_field(ui, buf, "Your name")
// `mask` replaces every rune on screen when set, for a password field. The
// buffer still holds the real bytes; only the drawing is substituted, and the
// caret is positioned from the masked text so it tracks correctly.
text_field :: proc(
	ctx: ^Ctx,
	buf: ^[dynamic]u8,
	placeholder: string = "",
	class: string = "",
	mask: rune = 0,
) -> (changed: bool, submitted: bool) {
	idx := push_styled(ctx, .Box, FIELD_BASE, class)
	id := ctx.nodes[idx].id
	ctx.nodes[idx].interactive = true
	ctx.nodes[idx].focusable = true
	append(&ctx.stack, idx)
	defer end(ctx)

	w := widget_of(ctx, id)
	s := ctx.nodes[idx].style
	has_focus := ctx.focus == id

	if ctx.clicked == id {
		ctx.focus = id
		has_focus = true
	}

	w.cursor = clamp(w.cursor, 0, len(buf))

	// One direction for the whole field, resolved from everything in it, so
	// that the caret, the arrow keys and the drawn text cannot disagree about
	// which way the line runs.
	field_dir := text_base_dir(string(buf[:]))

	if has_focus {
		// Printable input.
		if typed := typed_text(ctx); len(typed) > 0 {
			inject_at_elems(buf, w.cursor, ..transmute([]u8)typed)
			w.cursor += len(typed)
			// The caret follows what was just typed, which is the trailing
			// edge of it -- the one thing that stays true in a mixed line.
			w.affinity = .Upstream
			changed = true
		}
		for k in ctx.input.keys {
			switch k.sym {
			case KEY_BACKSPACE:
				if w.cursor > 0 {
					n := rune_back(buf[:], w.cursor)
					remove_range(buf, w.cursor - n, w.cursor)
					w.cursor -= n
					changed = true
				}
			case KEY_DELETE:
				if w.cursor < len(buf) {
					n := rune_forward(buf[:], w.cursor)
					remove_range(buf, w.cursor, w.cursor + n)
					changed = true
				}
			case KEY_LEFT:
				// Visual movement, not logical: the left arrow moves the caret
				// left on screen. In a right-to-left run that means the byte
				// offset goes up, and across a boundary it can jump. For text
				// that cannot reorder this is exactly rune_back.
				if mask != 0 {
					// A masked field draws one repeated glyph, so its visual
					// order is its logical order whatever the buffer holds.
					if w.cursor > 0 {
						w.cursor -= rune_back(buf[:], w.cursor)
					}
					w.affinity = .Downstream
					break
				}
				w.cursor, w.affinity = text_caret_move(
					ctx.fonts,
					string(buf[:]),
					w.cursor,
					s.font_size,
					.Left,
					w.affinity,
					s.family,
					s.weight,
					s.tracking_em * s.font_size,
					s.slant,
					s.tabular,
					field_dir,
				)
			case KEY_RIGHT:
				if mask != 0 {
					if w.cursor < len(buf) {
						w.cursor += rune_forward(buf[:], w.cursor)
					}
					w.affinity = .Upstream
					break
				}
				w.cursor, w.affinity = text_caret_move(
					ctx.fonts,
					string(buf[:]),
					w.cursor,
					s.font_size,
					.Right,
					w.affinity,
					s.family,
					s.weight,
					s.tracking_em * s.font_size,
					s.slant,
					s.tabular,
					field_dir,
				)
			case KEY_HOME:
				w.cursor = 0
				w.affinity = .Downstream
			case KEY_END:
				w.cursor = len(buf)
				w.affinity = .Upstream
			case KEY_RETURN, KEY_KP_ENTER:
				submitted = true
			case 'a':
				if .Ctrl in k.mods {
					w.cursor = 0
					w.affinity = .Downstream
				}
			case 'e':
				if .Ctrl in k.mods {
					w.cursor = len(buf)
					w.affinity = .Upstream
				}
			case 'u':
				if .Ctrl in k.mods {
					clear(buf)
					w.cursor = 0
					w.affinity = .Downstream
					changed = true
				}
			}
		}
	}

	content := string(buf[:])
	if mask != 0 && len(content) > 0 {
		runes := 0
		for _ in content {
			runes += 1
		}
		masked := strings.builder_make(ctx.alloc)
		for _ in 0 ..< runes {
			strings.write_rune(&masked, mask)
		}
		content = strings.to_string(masked)
	}
	show_placeholder := len(content) == 0 && placeholder != ""

	// Keep the caret in view by sliding the text inside the clipped field.
	caret_prefix := string(buf[:w.cursor])
	if mask != 0 {
		runes := 0
		for _ in caret_prefix {
			runes += 1
		}
		mb := strings.builder_make(ctx.alloc)
		for _ in 0 ..< runes {
			strings.write_rune(&mb, mask)
		}
		caret_prefix = strings.to_string(mb)
	}
	// Not the width of the prefix. Once text can reorder, the characters
	// before the caret in the string are not the characters to the left of it
	// on screen, so the prefix width is the wrong number -- it measures glyphs
	// that may be drawn to the caret's right. text_caret_x walks the visual
	// runs instead and returns the edge of the run the index actually sits in,
	// which is why it needs to know which side of the index was meant.
	//
	// A masked field is measured on the mask, not the buffer: what is on
	// screen is what the caret has to agree with.
	caret_x := text_caret_x(
		ctx.fonts,
		mask != 0 ? content : string(buf[:]),
		mask != 0 ? len(caret_prefix) : w.cursor,
		s.font_size,
		w.affinity,
		s.family,
		s.weight,
		s.tracking_em * s.font_size,
		s.slant,
		s.tabular,
		mask != 0 ? .LTR : field_dir,
	)
	inner_w := max(0, rect_of(ctx, id).w - s.pad[LEFT] - s.pad[RIGHT] - 2)
	if caret_x - w.scroll.x > inner_w {
		w.scroll.x = caret_x - inner_w
	}
	if caret_x < w.scroll.x {
		w.scroll.x = caret_x
	}
	w.scroll.x = max(0, w.scroll.x)

	shown := content
	t := text(ctx, shown, "whitespace-nowrap")
	if show_placeholder {
		shown = placeholder
		ctx.nodes[t].text = clone_frame(ctx, placeholder)
		// A placeholder is the field's own colour at half strength, which is
		// what a browser's preflight does and what any theme expects.
		ctx.nodes[t].style.fg = fade(s.fg, 0.5)
	}
	ctx.nodes[t].style.shrink = 0
	ctx.nodes[t].style.margin[LEFT] = -w.scroll.x

	if has_focus {
		// A blinking caret, which is also what keeps this element animating.
		ctx.animating = true
		if math.mod_f32(f32(ctx.now), 1.06) < 0.6 {
			caret := push_styled(ctx, .Box, "absolute w-[1.5]", "")
			// The caret takes the text colour, so it is correct on any theme.
			ctx.nodes[caret].style.bg = flat(s.fg)
			ctx.nodes[caret].style.inset[LEFT] = px(s.pad[LEFT] + caret_x - w.scroll.x)
			ctx.nodes[caret].style.inset[TOP] = px(s.pad[TOP] + 3)
			ctx.nodes[caret].style.inset[BOTTOM] = px(s.pad[BOTTOM] + 3)
		}
	}

	return changed, submitted
}

@(private)
rune_back :: proc(b: []u8, at: int) -> int {
	i := at - 1
	for i > 0 && b[i] & 0xc0 == 0x80 {
		i -= 1
	}
	return max(1, at - i)
}

@(private)
rune_forward :: proc(b: []u8, at: int) -> int {
	i := at + 1
	for i < len(b) && b[i] & 0xc0 == 0x80 {
		i += 1
	}
	return min(i, len(b)) - at
}

// text_field_string is a convenience wrapper for a Builder-backed field.
text_field_string :: proc(
	ctx: ^Ctx,
	b: ^strings.Builder,
	placeholder := "",
	class := "",
	mask: rune = 0,
) -> (changed: bool, submitted: bool) {
	return text_field(ctx, &b.buf, placeholder, class, mask)
}
