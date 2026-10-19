package palmy

import "core:math"
import "core:strings"
import "core:time"

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

// The caret's blink, in seconds: on for BLINK_ON out of every BLINK_PERIOD.
BLINK_PERIOD :: 1.06
BLINK_ON :: 0.6

// caret_on says whether a blinking caret is lit this frame, and arranges for
// the frame on which it next changes. Only that frame: between the two edges
// the loop sleeps, where pinning it at vsync to watch a clock -- which is
// how carets here used to blink -- repainted the whole window sixty times a
// second for as long as a field held focus.
//
// It counts from the last press or keystroke on a real monotonic clock, so a
// caret is solid while someone types and `tick`'s clamped `dt` cannot stretch
// the blink. Offscreen there is no clock to wake on, and it reads the
// renderer's synthetic time instead, which keeps captures deterministic.
caret_on :: proc(ctx: ^Ctx) -> bool {
	if ctx.app == nil {
		return math.mod_f64(ctx.now, BLINK_PERIOD) < BLINK_ON
	}
	phase := math.mod_f64(time.duration_seconds(time.tick_since(ctx.caret_epoch)), BLINK_PERIOD)
	on := phase < BLINK_ON
	next := (on ? BLINK_ON : BLINK_PERIOD) - phase
	wake_after(ctx, time.Duration(next * f64(time.Second)) + time.Millisecond)
	return on
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

	if w.tab_in {
		// Reached with Tab: the caret goes to the end, where typing appends.
		w.tab_in = false
		w.cursor = len(buf)
		w.affinity = .Upstream
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
		if caret_on(ctx) {
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

// ---------------------------------------------------------------------------
// The multi-line field
//
// `text_field` is one line that scrolls sideways. A notes box, a composer or a
// commit message is a different shape: the text wraps to the width it is given,
// Enter puts in a newline instead of submitting, and the caret has to live in
// two coordinate systems at once -- the byte offset the buffer uses, and the
// (visual row, x) the screen uses.
//
// Four applications had already written this before palmy had it, and the
// shape here is theirs: `apps/notes/wrap.odin` for the two-way caret
// conversion, `apps/editor/buffer.odin` for the line array, and
// `apps/docs/layout.odin` for the warning that a naive re-wrap of a whole
// document costs 33 ms a keystroke.
//
// THE PARTITION, which is what makes the round trip exact.
//
// `text_rows` returns rows that tile the buffer: row 0 starts at byte 0, each
// row's `next` is the following row's `from`, and the last row's `next` is the
// end of the text. `to` is where the drawn text stops, and `next - to` is the
// separator the break consumed -- one byte for a '\n', one byte for the space a
// soft break ate, zero at the end. Because a break always consumes exactly one
// byte, no byte offset is claimed by two rows, and `text_row_of` has one
// answer for every offset rather than the "which side of the wrap did you
// mean" ambiguity a toolkit usually has to carry a second affinity flag for.
// ---------------------------------------------------------------------------

// Text_Row is one visual line: the bytes it draws, and where the next row
// starts. `hard` says the row ended at a newline or at the end of the text
// rather than at a soft wrap.
//
// `dir` is the base direction of the *paragraph* the row came from, resolved
// once over the whole paragraph and carried on every row of it, which is what
// `layout.odin` does and what stops a right-to-left paragraph flipping on the
// one row that happens to start with a Latin word. Measuring, hit testing,
// caret placement and selection all read it, so they cannot disagree with each
// other. See the note on `text_rows` for where they can still disagree with
// the drawing.
Text_Row :: struct {
	from: int,
	to:   int,
	next: int,
	hard: bool,
	dir:  Bidi_Direction,
}

@(private)
area_row_width :: proc(ctx: ^Ctx, str: string, s: Style, dir: Bidi_Direction) -> f32 {
	return text_width(
		ctx.fonts,
		str,
		s.font_size,
		s.family,
		s.weight,
		s.tracking_em * s.font_size,
		s.slant,
		s.tabular,
		dir,
	)
}

// text_rows breaks `text` into the visual rows a field of `width` pixels would
// draw it on, honouring explicit newlines. A width of zero or less means no
// wrapping, which is also what the first frame of a field gets, before it has
// been laid out and knows how wide it is.
//
// The rows are allocated from `alloc`; a widget passes the frame arena.
//
// WHERE THIS IS STILL WRONG, and what would fix it.
//
// Every row is measured with its paragraph's direction, which is right. Every
// row is *drawn* as its own text node, and `wrap_text` resolves a node's
// direction from that node's own string, which for a mixed paragraph can come
// out different. Nothing in `Style` can override it, so a wrapped paragraph
// that mixes directions can be drawn with a row at the wrong base direction
// while the caret is placed at the right one. For text that is all one
// direction -- which is every row of every application in this repository
// today -- the two agree exactly and `text_simple` short-circuits both.
//
// The fix is a text-direction field on `Style` (`dir-ltr` / `dir-rtl` /
// `dir-auto`) that `wrap_text` passes to `text_base_dir` instead of `.Auto`.
// That is a change to `class.odin` and `layout.odin`, which this file does not
// own, so it is reported rather than made.
text_rows :: proc(
	ctx: ^Ctx,
	text: string,
	width: f32,
	s: Style,
	alloc := context.allocator,
) -> []Text_Row {
	rows := make([dynamic]Text_Row, alloc)

	at := 0
	for {
		nl := strings.index_byte(text[at:], '\n')
		para_end := nl < 0 ? len(text) : at + nl
		after := nl < 0 ? para_end : para_end + 1
		para := text[at:para_end]
		// Once per paragraph, not once per row: resolved over the whole
		// paragraph and carried on every row of it.
		dir := text_base_dir(para)

		if width <= 0 || s.nowrap || area_row_width(ctx, para, s, dir) <= width {
			append(&rows, Text_Row{at, para_end, after, true, dir})
		} else {
			// Greedy word wrap, the same rule `wrap_text` uses, so that the
			// rows this hands back are the rows the text nodes below will
			// actually draw. A word wider than the field overflows rather than
			// being chopped, which is what a URL wants.
			start := at
			last_break := -1
			i := at
			for i <= para_end {
				at_end := i == para_end
				if !at_end && text[i] != ' ' {
					i += 1
					continue
				}
				if area_row_width(ctx, text[start:i], s, dir) > width && last_break > start {
					append(&rows, Text_Row{start, last_break, last_break + 1, false, dir})
					start = last_break + 1
					last_break = -1
					i = start
					continue
				}
				if at_end {
					append(&rows, Text_Row{start, para_end, after, true, dir})
					break
				}
				last_break = i
				i += 1
			}
		}

		if nl < 0 {
			break
		}
		at = after
	}

	if len(rows) == 0 {
		append(&rows, Text_Row{0, 0, 0, true, .LTR})
	}
	return rows[:]
}

// text_row_of is the row a byte offset sits on. Every offset has exactly one
// answer; see the note on the partition above.
text_row_of :: proc(rows: []Text_Row, at: int) -> int {
	if len(rows) == 0 {
		return 0
	}
	lo, hi := 0, len(rows) - 1
	for lo < hi {
		mid := (lo + hi + 1) / 2
		if rows[mid].from <= at {
			lo = mid
		} else {
			hi = mid - 1
		}
	}
	return lo
}

// text_row_caret is the screen position of a byte offset: which row it is on,
// and how far along that row it sits. `affinity` only matters where the text
// reorders.
text_row_caret :: proc(
	ctx: ^Ctx,
	text: string,
	rows: []Text_Row,
	at: int,
	affinity: Caret_Affinity,
	s: Style,
) -> (
	row: int,
	x: f32,
) {
	if len(rows) == 0 {
		return 0, 0
	}
	row = text_row_of(rows, clamp(at, 0, len(text)))
	r := rows[row]
	line := text[r.from:r.to]
	i := clamp(at - r.from, 0, len(line))
	x = text_caret_x(
		ctx.fonts,
		line,
		i,
		s.font_size,
		affinity,
		s.family,
		s.weight,
		s.tracking_em * s.font_size,
		s.slant,
		s.tabular,
		r.dir,
	)
	return
}

// text_row_index_at inverts `text_row_caret`: the byte offset nearest to `x` on
// a given row. A click, a drag and a vertical move all land here.
text_row_index_at :: proc(
	ctx: ^Ctx,
	text: string,
	rows: []Text_Row,
	row: int,
	x: f32,
	s: Style,
) -> (
	index: int,
	affinity: Caret_Affinity,
) {
	if len(rows) == 0 {
		return 0, .Downstream
	}
	r := rows[clamp(row, 0, len(rows) - 1)]
	line := text[r.from:r.to]
	i, aff := text_index_at_affinity(
		ctx.fonts,
		line,
		s.font_size,
		x,
		s.family,
		s.weight,
		s.tracking_em * s.font_size,
		s.slant,
		s.tabular,
		r.dir,
	)
	return r.from + clamp(i, 0, len(line)), aff
}

@(private)
AREA_BASE :: "flex-col items-stretch w-full h-32 px-3 py-2 rounded-lg cursor-text " +
	// Same reasoning as FIELD_BASE: a self-contained light field first, so the
	// widget is readable with no theme registered, then the tokens, which win
	// wherever a theme defines them and are dropped where it does not.
	"overflow-hidden text-sm transition border " +
	"bg-white text-slate-900 border-slate-400 hover:border-slate-500 focus:border-indigo-400 " +
	"bg-background text-foreground border-input hover:border-ring focus:border-ring"

// Area_Caret is the bit of a text area's state that `Widget` has no room for:
// the goal column a run of vertical moves remembers.
@(private)
Area_Caret :: struct {
	goal: f32,
	have: bool,
}

@(private)
area_place :: proc(w: ^Widget, ac: ^Area_Caret, at: int, aff: Caret_Affinity, extend: bool) {
	w.cursor = at
	w.affinity = aff
	if !extend {
		w.sel = at
	}
	// Any horizontal move forgets the goal column; only Up, Down and the page
	// keys keep it, and they set it again themselves.
	ac.have = false
}

@(private)
area_cut :: proc(buf: ^[dynamic]u8, w: ^Widget, ac: ^Area_Caret, lo, hi: int) {
	remove_range(buf, lo, hi)
	w.cursor, w.sel = lo, lo
	w.affinity = .Downstream
	ac.have = false
}

@(private)
area_hit :: proc(
	ctx: ^Ctx,
	text: string,
	rows: []Text_Row,
	s: Style,
	rect: Rect,
	scroll: [2]f32,
	lh: f32,
	at: [2]f32,
) -> (
	int,
	Caret_Affinity,
) {
	ox := rect.x + s.border_w[LEFT] + s.pad[LEFT] - scroll.x
	oy := rect.y + s.border_w[TOP] + s.pad[TOP] - scroll.y
	row := int(math.floor((at.y - oy) / max(lh, 1)))
	row = clamp(row, 0, len(rows) - 1)
	return text_row_index_at(ctx, text, rows, row, at.x - ox, s)
}

// text_area edits a byte buffer in place across as many lines as it needs. It
// is `text_field`'s multi-line sibling: the text wraps to the field's width,
// Enter inserts a newline rather than submitting, Up and Down move by *visual*
// row with a remembered goal column, Home and End go to the ends of the visual
// row, and the view scrolls to follow the caret.
//
//	buf := palmy.state(ui, "notes", [dynamic]u8{})
//	if palmy.text_area(ui, buf, "Notes", "h-40") { dirty = true }
//
// Selection is an anchor alongside the caret: Shift with any movement extends
// it, typing or deleting replaces it, and a drag sets it. Ctrl A and Ctrl E are
// the ends of the visual row, matching `text_field`; Ctrl Shift A selects
// everything and Ctrl K kills to the end of the row.
//
// It returns whether the buffer changed this frame. There is no `submitted`:
// Enter belongs to the text, so a form that wants a submit key gives it one of
// its own, as `vault` does with Ctrl S.
text_area :: proc(
	ctx: ^Ctx,
	buf: ^[dynamic]u8,
	placeholder: string = "",
	class: string = "",
) -> (
	changed: bool,
) {
	idx := push_styled(ctx, .Box, AREA_BASE, class)
	id := ctx.nodes[idx].id
	ctx.nodes[idx].interactive = true
	ctx.nodes[idx].focusable = true
	append(&ctx.stack, idx)
	defer end(ctx)

	w := widget_of(ctx, id)
	s := ctx.nodes[idx].style
	ac := state(ctx, "caret", Area_Caret{})
	lh := line_height_of(s)

	rect := rect_of(ctx, id)
	inner_w := max(0, rect.w - s.pad[LEFT] - s.pad[RIGHT] - s.border_w[LEFT] - s.border_w[RIGHT])
	inner_h := max(0, rect.h - s.pad[TOP] - s.pad[BOTTOM] - s.border_w[TOP] - s.border_w[BOTTOM])
	// Before the first layout the field has no width, and wrapping to zero
	// would put every rune on a row of its own. One unwrapped frame is the
	// better wrong answer.
	avail := inner_w > 1 ? inner_w : -1

	has_focus := ctx.focus == id
	if ctx.clicked == id {
		ctx.focus = id
		has_focus = true
	}

	if w.tab_in {
		// Reached with Tab: the caret at the end, nothing selected.
		w.tab_in = false
		w.cursor, w.sel = len(buf), len(buf)
		w.affinity = .Upstream
		ac.have = false
	}
	w.cursor = clamp(w.cursor, 0, len(buf))
	w.sel = clamp(w.sel, 0, len(buf))

	rows := text_rows(ctx, string(buf[:]), avail, s, ctx.alloc)

	if has_focus {
		if typed := typed_text(ctx); len(typed) > 0 {
			if lo, hi := min(w.cursor, w.sel), max(w.cursor, w.sel); hi > lo {
				area_cut(buf, w, ac, lo, hi)
			}
			inject_at_elems(buf, w.cursor, ..transmute([]u8)typed)
			w.cursor += len(typed)
			w.sel = w.cursor
			// The caret follows what was just typed, which is its trailing
			// edge -- the one thing that stays true in a mixed line.
			w.affinity = .Upstream
			ac.have = false
			changed = true
			rows = text_rows(ctx, string(buf[:]), avail, s, ctx.alloc)
		}

		for k in ctx.input.keys {
			extend := .Shift in k.mods
			ctrl := .Ctrl in k.mods
			lo := min(w.cursor, w.sel)
			hi := max(w.cursor, w.sel)
			row, cx := text_row_caret(ctx, string(buf[:]), rows, w.cursor, w.affinity, s)
			dirty := false

			switch k.sym {
			case KEY_BACKSPACE:
				if hi > lo {
					area_cut(buf, w, ac, lo, hi)
					dirty = true
				} else if w.cursor > 0 {
					n := rune_back(buf[:], w.cursor)
					area_cut(buf, w, ac, w.cursor - n, w.cursor)
					dirty = true
				}
			case KEY_DELETE:
				if hi > lo {
					area_cut(buf, w, ac, lo, hi)
					dirty = true
				} else if w.cursor < len(buf) {
					n := rune_forward(buf[:], w.cursor)
					area_cut(buf, w, ac, w.cursor, w.cursor + n)
					dirty = true
				}
			case KEY_RETURN, KEY_KP_ENTER:
				// The whole point of the widget: Enter is a character.
				if hi > lo {
					area_cut(buf, w, ac, lo, hi)
				}
				inject_at_elem(buf, w.cursor, u8('\n'))
				w.cursor += 1
				w.sel = w.cursor
				w.affinity = .Downstream
				ac.have = false
				dirty = true
			case KEY_LEFT, KEY_RIGHT:
				step: Caret_Step = k.sym == KEY_LEFT ? .Left : .Right
				if !extend && hi > lo {
					// An unshifted arrow collapses a selection to the edge it
					// points at rather than moving off it.
					area_place(w, ac, step == .Left ? lo : hi, step == .Left ? .Downstream : .Upstream, false)
					break
				}
				// Within the row, not across the whole buffer: a row is what
				// gets laid out, so it is the only string whose visual order
				// is defined. `text_caret_move` handing back the offset it was
				// given is the signal that the caret is at the edge of that
				// row and the move belongs to the adjacent one.
				r := rows[row]
				line := string(buf[r.from:r.to])
				local := clamp(w.cursor - r.from, 0, len(line))
				at, aff := text_caret_move(
					ctx.fonts,
					line,
					local,
					s.font_size,
					step,
					w.affinity,
					s.family,
					s.weight,
					s.tracking_em * s.font_size,
					s.slant,
					s.tabular,
					r.dir,
				)
				if at != local {
					area_place(w, ac, r.from + at, aff, extend)
					break
				}
				// Off the edge. Which row that is depends on the direction the
				// row runs in: in a right-to-left row the visual left edge is
				// the end of the text, so Left goes forwards.
				forward := (step == .Right) != (r.dir == .RTL)
				switch {
				case forward && row + 1 < len(rows):
					area_place(w, ac, rows[row + 1].from, .Downstream, extend)
				case !forward && row > 0:
					area_place(w, ac, rows[row - 1].to, .Upstream, extend)
				case extend:
					// Already at the end of the text; keep the anchor.
					area_place(w, ac, w.cursor, w.affinity, true)
				}
			case KEY_UP, KEY_DOWN, KEY_PAGE_UP, KEY_PAGE_DOWN:
				// The goal column survives a run of vertical moves, so
				// down-then-up returns to where it started even across a short
				// row in between. That round trip is asserted.
				goal := ac.have ? ac.goal : cx
				step := 1
				if k.sym == KEY_PAGE_UP || k.sym == KEY_PAGE_DOWN {
					step = max(1, int(inner_h / max(lh, 1)) - 1)
				}
				if k.sym == KEY_UP || k.sym == KEY_PAGE_UP {
					step = -step
				}
				target := row + step
				switch {
				case target < 0:
					// Off the top: the start of the text, which is what makes
					// Up useful on row 0 and what every editor does.
					w.cursor, w.affinity = 0, .Downstream
				case target >= len(rows):
					w.cursor, w.affinity = len(buf), .Upstream
				case:
					w.cursor, w.affinity = text_row_index_at(
						ctx,
						string(buf[:]),
						rows,
						target,
						goal,
						s,
					)
				}
				if !extend {
					w.sel = w.cursor
				}
				ac.goal, ac.have = goal, true
			case KEY_HOME:
				at := ctrl ? 0 : rows[text_row_of(rows, w.cursor)].from
				area_place(w, ac, at, .Downstream, extend)
			case KEY_END:
				at := ctrl ? len(buf) : rows[text_row_of(rows, w.cursor)].to
				area_place(w, ac, at, .Upstream, extend)
			case 'a':
				if ctrl && extend {
					w.sel = 0
					w.cursor = len(buf)
					w.affinity = .Upstream
					ac.have = false
				} else if ctrl {
					area_place(w, ac, rows[text_row_of(rows, w.cursor)].from, .Downstream, false)
				}
			case 'e':
				if ctrl {
					area_place(w, ac, rows[text_row_of(rows, w.cursor)].to, .Upstream, false)
				}
			case 'u':
				if ctrl {
					clear(buf)
					w.cursor, w.sel = 0, 0
					w.affinity = .Downstream
					ac.have = false
					dirty = true
				}
			case 'k':
				if ctrl {
					// Kill to the end of the visual row, or swallow the break
					// when the caret is already sitting there.
					r := rows[text_row_of(rows, w.cursor)]
					stop := w.cursor >= r.to ? min(r.next, len(buf)) : r.to
					if stop > w.cursor {
						area_cut(buf, w, ac, w.cursor, stop)
						dirty = true
					}
				}
			}

			if dirty {
				changed = true
				w.cursor = clamp(w.cursor, 0, len(buf))
				w.sel = clamp(w.sel, 0, len(buf))
				rows = text_rows(ctx, string(buf[:]), avail, s, ctx.alloc)
			}
		}
	}

	// The pointer. A press places the caret and drops the anchor there; holding
	// and moving extends the selection, which is the one thing a text widget
	// cannot fake with clicks alone.
	if rect.w > 0 && len(rows) > 0 {
		if ctx.input.pressed[.Left] && ctx.hot == id {
			at, aff := area_hit(ctx, string(buf[:]), rows, s, rect, w.scroll, lh, ctx.input.mouse)
			area_place(w, ac, at, aff, false)
			w.drag = ctx.input.mouse
		} else if ctx.active == id && ctx.input.down[.Left] && ctx.input.mouse != w.drag {
			at, aff := area_hit(ctx, string(buf[:]), rows, s, rect, w.scroll, lh, ctx.input.mouse)
			w.cursor, w.affinity = at, aff
			ac.have = false
		}
		// The wheel, which the generic scroll path does not deliver here
		// because this field is not a scroll container: it clips and shifts its
		// own content so that the text, the selection and the caret move
		// together.
		if ctx.hot == id && ctx.input.scroll.y != 0 {
			w.scroll.y -= ctx.input.scroll.y * 2.5
		}
	}

	total_h := f32(len(rows)) * lh
	caret_row, caret_x := text_row_caret(ctx, string(buf[:]), rows, w.cursor, w.affinity, s)

	// Follow the caret. Vertically by row; horizontally only for a word too
	// long to wrap, which is the one way text can leave the right edge.
	if inner_h > 0 {
		top_y := f32(caret_row) * lh
		if top_y < w.scroll.y {
			w.scroll.y = top_y
		}
		if top_y + lh > w.scroll.y + inner_h {
			w.scroll.y = top_y + lh - inner_h
		}
	}
	w.scroll.y = clamp(w.scroll.y, 0, max(0, total_h - inner_h))
	if inner_w > 0 {
		if caret_x - w.scroll.x > inner_w - 2 {
			w.scroll.x = caret_x - inner_w + 2
		}
		if caret_x < w.scroll.x {
			w.scroll.x = caret_x
		}
	}
	w.scroll.x = max(0, w.scroll.x)
	// Recorded even though this field clips rather than scrolls: it is what
	// `paint_scrollbar` reads, so a caller who adds `overflow-scroll` to the
	// class gets an indicator that matches the scrolling done above.
	w.view = {inner_w, inner_h}
	w.over = {0, max(0, total_h - inner_h)}

	// The body: one node per visual row, each `whitespace-nowrap`, so that what
	// is on screen is exactly the rows measured above. Letting one text node
	// wrap itself would be fewer nodes and a second, independent wrapper for
	// the caret to disagree with.
	// Nothing inside the field animates its colour, and the `transition` the
	// field itself carries must not be inherited down here.
	//
	// This is not a nicety. Node ids are a per-depth sequence number hashed
	// with the parent, so the frame a selection appears, every node after the
	// first highlight rectangle at that depth shifts onto the id its
	// neighbour had -- and inherits that neighbour's animation state. A row
	// box landing on a highlight's id paints the highlight's grey across its
	// whole width and then fades it out, which looks like the entire line
	// flashing every time a drag begins. Snapping instead is also what a
	// caret and a selection should do.
	body := push_styled(ctx, .Box, "flex-col items-stretch shrink-0 w-full", "")
	ctx.nodes[body].style.margin[TOP] = -w.scroll.y
	ctx.nodes[body].style.margin[LEFT] = -w.scroll.x
	ctx.nodes[body].style.transition = 0
	append(&ctx.stack, body)

	text_str := string(buf[:])
	show_placeholder := len(text_str) == 0 && placeholder != ""
	sel_lo := min(w.cursor, w.sel)
	sel_hi := max(w.cursor, w.sel)

	for r, ri in rows {
		line := text_str[r.from:r.to]
		rowi := push_styled(ctx, .Box, "relative flex-row items-start shrink-0 w-full", "")
		ctx.nodes[rowi].style.h = px(lh)
		append(&ctx.stack, rowi)

		if sel_hi > sel_lo && sel_hi > r.from && sel_lo <= r.to {
			a := clamp(sel_lo - r.from, 0, len(line))
			b := clamp(sel_hi - r.from, 0, len(line))
			spans: [4]Text_Span
			n := text_selection_spans(
				ctx.fonts,
				line,
				a,
				b,
				s.font_size,
				spans[:],
				s.family,
				s.weight,
				s.tracking_em * s.font_size,
				s.slant,
				s.tabular,
				r.dir,
			)
			// A selection that runs on past this row covers the break too,
			// which is not a glyph and so has no span of its own.
			if sel_hi > r.to {
				if n == 0 {
					spans[0] = Text_Span{area_row_width(ctx, line, s, r.dir), 0}
					n = 1
				}
				spans[n - 1].w += 5
			}
			for si in 0 ..< n {
				sp := spans[si]
				sel := push_styled(ctx, .Box, "absolute", "")
				ctx.nodes[sel].style.bg = flat(fade(s.fg, 0.22))
				ctx.nodes[sel].style.inset[LEFT] = px(sp.x)
				ctx.nodes[sel].style.w = px(max(sp.w, 1))
				ctx.nodes[sel].style.inset[TOP] = px(0)
				ctx.nodes[sel].style.h = px(lh)
			}
		}

		t := text(ctx, line, "whitespace-nowrap")
		ctx.nodes[t].style.shrink = 0
		if show_placeholder && ri == 0 {
			ctx.nodes[t].text = clone_frame(ctx, placeholder)
			// A placeholder is the field's own colour at half strength, which
			// is what a browser's preflight does.
			ctx.nodes[t].style.fg = fade(s.fg, 0.5)
		}

		// The caret is drawn here and nowhere else. It blinks on
		// `caret_on`'s schedule, which wakes the loop once per edge rather
		// than holding it at vsync.
		if has_focus && ri == caret_row && caret_on(ctx) {
			caret := push_styled(ctx, .Box, "absolute w-[1.5]", "")
			ctx.nodes[caret].style.bg = flat(s.fg)
			// Positioned with `inset`, not `margin`: an absolutely positioned
			// child resolves `inset` against its containing block and ignores
			// margins, which is why `slider`'s knob walks off the end of its
			// track.
			ctx.nodes[caret].style.inset[LEFT] = px(caret_x)
			ctx.nodes[caret].style.inset[TOP] = px(1)
			ctx.nodes[caret].style.h = px(max(lh - 2, 2))
		}

		end(ctx)
	}

	end(ctx) // body
	return changed
}

// text_area_string is a convenience wrapper for a Builder-backed area.
text_area_string :: proc(
	ctx: ^Ctx,
	b: ^strings.Builder,
	placeholder := "",
	class := "",
) -> (
	changed: bool,
) {
	return text_area(ctx, &b.buf, placeholder, class)
}
