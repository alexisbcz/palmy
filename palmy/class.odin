package palmy

import "core:strconv"
import "core:strings"

Direction :: enum u8 {
	Row,
	Col,
}

Align :: enum u8 {
	Auto,
	Start,
	Center,
	End,
	Stretch,
	Baseline,
}

Justify :: enum u8 {
	Start,
	Center,
	End,
	Between,
	Around,
	Evenly,
}

Position :: enum u8 {
	Relative,
	Absolute,
}

Text_Align :: enum u8 {
	// Start is the default, and the only value that depends on the text: it
	// resolves to the side the paragraph's base direction begins from, so
	// Hebrew and Arabic align right without anything being set. `text-left`
	// still means left for everything, which is what a caller asking for it
	// wants. Start must stay first so that it is the zero value.
	Start,
	// End is Start's opposite: the side the base direction finishes at.
	End,
	Left,
	Center,
	Right,
}

Overflow :: enum u8 {
	Visible,
	Hidden,
	Scroll,
}

// Cursor names the pointer shape an element asks for. They map onto
// cursor-shape-v1, so the compositor draws its own themed cursor.
Cursor :: enum u8 {
	Inherit,
	Default,
	Pointer,
	Text,
	Crosshair,
	Move,
	Wait,
	Progress,
	Help,
	Not_Allowed,
	Grab,
	Grabbing,
	Col_Resize,
	Row_Resize,
}

Text_Transform :: enum u8 {
	None,
	Upper,
	Lower,
}

Dim_Kind :: enum u8 {
	Auto,
	Px,
	Pct,
	Screen,
}

Dim :: struct {
	kind: Dim_Kind,
	v:    f32,
}

AUTO :: Dim{}

px :: proc "contextless" (v: f32) -> Dim {
	return {.Px, v}
}

pct :: proc "contextless" (v: f32) -> Dim {
	return {.Pct, v}
}

Shadow :: struct {
	y:     f32,
	blur:  f32,
	spread: f32,
	color: Color,
}

// Side indices for padding, margin, border and inset: top, right, bottom, left.
TOP :: 0
RIGHT :: 1
BOTTOM :: 2
LEFT :: 3

// Style is the fully resolved appearance and layout of one node. Anything the
// class parser can express lives here, and the fields marked "inherited" flow
// down to children the way they do in CSS.
Style :: struct {
	// Layout
	hidden:        bool,
	dir:           Direction,
	items:         Align,
	self:          Align,
	justify:       Justify,
	wrap:          bool,
	gap:           [2]f32,
	grow:          f32,
	shrink:        f32,
	basis:         Dim,
	w, h:          Dim,
	min_w, min_h:  Dim,
	max_w, max_h:  Dim,
	pad:           [4]f32,
	margin:        [4]f32,
	margin_auto_x: bool,
	position:      Position,
	inset:         [4]Dim,
	grid_cols:     int,
	overflow:      Overflow,
	z:             int,

	// Paint
	bg:            Paint,
	ring:          f32,   // width of a ring drawn outside the border box
	ring_col:      Color,
	bg_clip_pad:   bool,  // background-clip: padding-box
	border_w:      [4]f32,
	border_col:    Color,
	radius:        Radius,
	shadow:        Shadow,
	opacity:       f32, // inherited

	// Text (inherited)
	fg:            Color,
	font_size:     f32,
	leading:       f32, // multiple of font_size
	leading_px:    f32, // absolute override, 0 when unused
	weight:        Font_Weight,
	family:        Font_Family,
	slant:         Font_Slant,
	// tabular asks for `font-variant-numeric: tabular-nums`: every digit the
	// same advance, so a clock, a byte counter or a rate readout stops moving
	// sideways as its digits change.
	tabular:       bool,
	// A stroke around every glyph, which is what a subtitle needs over a busy
	// frame. Zero width is no outline, so it costs nothing when unused.
	outline_w:     f32,
	outline_col:   Color,
	text_align:    Text_Align,
	tracking_em:   f32,
	transform:     Text_Transform,
	nowrap:        bool,
	truncate:      bool,
	strike:        bool,
	underline:     bool,

	// Behaviour
	transition:    f32, // seconds, 0 disables
	cursor:        Cursor,
	no_hit:        bool, // pointer-events: none
}

// Interaction is the state a node was in when it was last on screen. The class
// parser uses it to decide whether `hover:` and friends apply.
Interaction :: struct {
	hover:    bool,
	active:   bool,
	focus:    bool,
	disabled: bool,
}

// style_default is the root style: the CSS initial values, adjusted to
// Tailwind's preflight (no margins, border-box sizing everywhere).
style_default :: proc() -> Style {
	return Style {
		dir = .Col,
		items = .Stretch,
		self = .Auto,
		justify = .Start,
		shrink = 1,
		opacity = 1,
		fg = Color{229, 231, 235, 255}, // gray-200, a readable default on dark
		font_size = 16,
		leading = 1.5,
		border_col = Color{63, 63, 70, 255},
	}
}

// inherit copies the properties that cascade from a parent to a child.
@(private)
inherit :: proc(parent: Style) -> Style {
	s := style_default()
	s.fg = parent.fg
	s.font_size = parent.font_size
	s.leading = parent.leading
	s.leading_px = parent.leading_px
	s.weight = parent.weight
	s.family = parent.family
	s.slant = parent.slant
	s.tabular = parent.tabular
	s.outline_w = parent.outline_w
	s.outline_col = parent.outline_col
	s.text_align = parent.text_align
	s.tracking_em = parent.tracking_em
	s.transform = parent.transform
	s.opacity = parent.opacity
	s.transition = parent.transition
	s.nowrap = parent.nowrap
	return s
}

// ---------------------------------------------------------------------------
// Class parsing
// ---------------------------------------------------------------------------

// apply_classes walks a Tailwind-style class list and folds each utility into
// the style. Variant prefixes (`hover:`, `active:`, `focus:`, `disabled:`) are
// applied only when the node is in that state, and later tokens win, so
// "bg-slate-800 hover:bg-slate-700" behaves exactly as it reads.
apply_classes :: proc(s: ^Style, class: string, st: Interaction) {
	rest := class
	for len(rest) > 0 {
		// Split on whitespace without allocating.
		start := 0
		for start < len(rest) && is_space(rest[start]) {
			start += 1
		}
		if start >= len(rest) {
			break
		}
		end := start
		for end < len(rest) && !is_space(rest[end]) {
			end += 1
		}
		token := rest[start:end]
		rest = rest[end:]

		// Resolve any variant prefixes.
		active := true
		for {
			colon := strings.index_byte(token, ':')
			if colon < 0 {
				break
			}
			variant := token[:colon]
			token = token[colon + 1:]
			switch variant {
			case "hover":
				active &= st.hover && !st.disabled
			case "active":
				active &= st.active && !st.disabled
			case "focus":
				active &= st.focus
			case "focus-visible":
				active &= st.focus
			case "disabled":
				active &= st.disabled
			case "enabled":
				active &= !st.disabled
			case:
				active = false // unknown variant: ignore the utility
			}
		}
		if active && len(token) > 0 {
			apply_token(s, token)
		}
	}
}

@(private)
is_space :: proc "contextless" (c: u8) -> bool {
	return c == ' ' || c == '\t' || c == '\n' || c == '\r'
}

// scale resolves Tailwind's spacing scale: `4` is 16px, `0.5` is 2px, `px` is
// 1px, and `[12]` is an exact pixel value.
@(private)
scale :: proc(t: string) -> (f32, bool) {
	if t == "px" {
		return 1, true
	}
	if t == "auto" {
		return 0, false
	}
	if len(t) >= 3 && t[0] == '[' && t[len(t) - 1] == ']' {
		v, ok := strconv.parse_f32(t[1:len(t) - 1])
		return v, ok
	}
	v, ok := strconv.parse_f32(t)
	return v * 4, ok
}

@(private)
dim_of :: proc(t: string) -> (Dim, bool) {
	switch t {
	case "full":
		return pct(100), true
	case "auto":
		return AUTO, true
	case "screen":
		return {.Screen, 0}, true
	case "min", "fit", "max":
		return AUTO, true
	case "none":
		return AUTO, true
	}
	if slash := strings.index_byte(t, '/'); slash > 0 {
		a, aok := strconv.parse_f32(t[:slash])
		b, bok := strconv.parse_f32(t[slash + 1:])
		if aok && bok && b != 0 {
			return pct(a / b * 100), true
		}
		return AUTO, false
	}
	if v, ok := scale(t); ok {
		return px(v), true
	}
	return AUTO, false
}

@(private)
radius_of :: proc(t: string) -> (f32, bool) {
	if r, found := theme_radius(t); found {
		return r, true
	}
	switch t {
	case "":
		return 4, true
	case "none":
		return 0, true
	case "sm":
		return 2, true
	case "md":
		return 6, true
	case "lg":
		return 8, true
	case "xl":
		return 12, true
	case "2xl":
		return 16, true
	case "3xl":
		return 24, true
	case "full":
		return 9999, true
	}
	if len(t) >= 3 && t[0] == '[' {
		return scale(t)
	}
	return 0, false
}

@(private)
font_size_of :: proc(t: string) -> (size: f32, leading: f32, ok: bool) {
	if s, l, found := theme_text(t); found {
		return s, l, true
	}
	switch t {
	case "xs":
		return 12, 16.0 / 12, true
	case "sm":
		return 14, 20.0 / 14, true
	case "base":
		return 16, 1.5, true
	case "lg":
		return 18, 28.0 / 18, true
	case "xl":
		return 20, 28.0 / 20, true
	case "2xl":
		return 24, 32.0 / 24, true
	case "3xl":
		return 30, 36.0 / 30, true
	case "4xl":
		return 36, 40.0 / 36, true
	case "5xl":
		return 48, 1, true
	case "6xl":
		return 60, 1, true
	case "7xl":
		return 72, 1, true
	case "8xl":
		return 96, 1, true
	case "9xl":
		return 128, 1, true
	}
	if len(t) >= 3 && t[0] == '[' {
		if v, vok := scale(t); vok {
			return v, 1.3, true
		}
	}
	return 0, 0, false
}

@(private)
set_sides :: proc(dst: ^[4]f32, which: string, v: f32) {
	switch which {
	case "":
		dst^ = {v, v, v, v}
	case "x":
		dst[LEFT], dst[RIGHT] = v, v
	case "y":
		dst[TOP], dst[BOTTOM] = v, v
	case "t":
		dst[TOP] = v
	case "r":
		dst[RIGHT] = v
	case "b":
		dst[BOTTOM] = v
	case "l":
		dst[LEFT] = v
	case "s":
		dst[LEFT] = v
	case "e":
		dst[RIGHT] = v
	}
}

@(private)
set_corners :: proc(dst: ^Radius, which: string, v: f32) {
	switch which {
	case "":
		dst^ = {v, v, v, v}
	case "t":
		dst[0], dst[1] = v, v
	case "b":
		dst[2], dst[3] = v, v
	case "l":
		dst[0], dst[3] = v, v
	case "r":
		dst[1], dst[2] = v, v
	case "tl":
		dst[0] = v
	case "tr":
		dst[1] = v
	case "br":
		dst[2] = v
	case "bl":
		dst[3] = v
	}
}

// apply_token folds a single utility class into the style.
@(private)
apply_token :: proc(s: ^Style, t: string) {
	// Exact matches first; these are the most common utilities.
	switch t {
	case "flex":
		return
	case "flex-row":
		s.dir = .Row
		return
	case "flex-col":
		s.dir = .Col
		return
	case "flex-wrap":
		s.wrap = true
		return
	case "flex-nowrap":
		s.wrap = false
		return
	case "flex-1":
		s.grow, s.shrink, s.basis = 1, 1, px(0)
		return
	case "flex-auto":
		s.grow, s.shrink, s.basis = 1, 1, AUTO
		return
	case "flex-initial":
		s.grow, s.shrink = 0, 1
		return
	case "flex-none":
		s.grow, s.shrink = 0, 0
		return
	case "grow":
		s.grow = 1
		return
	case "grow-0":
		s.grow = 0
		return
	case "shrink":
		s.shrink = 1
		return
	case "shrink-0":
		s.shrink = 0
		return
	case "hidden":
		s.hidden = true
		return
	case "bg-clip-padding":
		s.bg_clip_pad = true
		return
	case "bg-clip-border", "bg-clip-content":
		s.bg_clip_pad = false
		return
	case "block", "inline-flex", "inline-block", "inline", "contents", "table":
		return
	case "grid", "inline-grid":
		// A single-column grid is a column of boxes; multi-column grids are
		// approximated by `grid-cols-*` below.
		s.dir = .Col
		return
	case "select-none", "select-text", "select-all", "outline-none", "outline-hidden",
	     "isolate", "antialiased", "subpixel-antialiased", "appearance-none",
	     "pointer-events-auto", "will-change-transform", "touch-none":
		return
	case "pointer-events-none":
		s.no_hit = true
		return
	case "fixed", "sticky":
		s.position = .Absolute
		return
	case "ring":
		// Tailwind v4 made the bare `ring` utility one pixel.
		s.ring = 1
		return
	case "ring-0":
		s.ring = 0
		return
	case "relative":
		s.position = .Relative
		return
	case "absolute":
		s.position = .Absolute
		return
	case "border":
		s.border_w = {1, 1, 1, 1}
		return
	case "rounded":
		r, found := theme_radius("")
		if !found {
			r = 4
		}
		s.radius = {r, r, r, r}
		return
	case "uppercase":
		s.transform = .Upper
		return
	case "lowercase":
		s.transform = .Lower
		return
	case "normal-case":
		s.transform = .None
		return
	case "truncate":
		s.truncate = true
		s.nowrap = true
		return
	case "line-through":
		s.strike = true
		return
	case "underline":
		s.underline = true
		return
	case "no-underline":
		s.strike, s.underline = false, false
		return
	case "whitespace-nowrap":
		s.nowrap = true
		return
	case "whitespace-normal":
		s.nowrap = false
		return
	case "transition", "transition-all", "transition-colors", "transition-opacity":
		if s.transition == 0 {
			s.transition = 0.15
		}
		return
	case "transition-none":
		s.transition = 0
		return
	case "mx-auto":
		s.margin_auto_x = true
		return
	case "cursor-default":
		s.cursor = .Default
		return
	case "cursor-pointer":
		s.cursor = .Pointer
		return
	case "cursor-text":
		s.cursor = .Text
		return
	case "cursor-crosshair":
		s.cursor = .Crosshair
		return
	case "cursor-move":
		s.cursor = .Move
		return
	case "cursor-wait":
		s.cursor = .Wait
		return
	case "cursor-progress":
		s.cursor = .Progress
		return
	case "cursor-help":
		s.cursor = .Help
		return
	case "cursor-not-allowed":
		s.cursor = .Not_Allowed
		return
	case "cursor-grab":
		s.cursor = .Grab
		return
	case "cursor-grabbing":
		s.cursor = .Grabbing
		return
	case "cursor-col-resize":
		s.cursor = .Col_Resize
		return
	case "cursor-row-resize":
		s.cursor = .Row_Resize
		return
	case "overflow-hidden", "overflow-y-hidden", "overflow-x-hidden":
		s.overflow = .Hidden
		return
	case "overflow-auto", "overflow-scroll", "overflow-y-auto", "overflow-y-scroll":
		s.overflow = .Scroll
		return
	case "shadow":
		s.shadow = {1, 4, 0, hexa(0x0000_0026)}
		return
	case "shadow-none":
		s.shadow = {}
		return
	case "font-mono":
		s.family = .Mono
		return
	case "font-sans":
		s.family = .Sans
		return
	case "font-bold", "font-extrabold", "font-black":
		s.weight = .Bold
		return
	case "font-semibold":
		s.weight = .Semibold
		return
	case "font-medium":
		s.weight = .Medium
		return
	case "font-normal", "font-light", "font-thin":
		s.weight = .Regular
		return
	case "italic":
		s.slant = .Italic
		return
	case "not-italic":
		s.slant = .Upright
		return
	case "tabular-nums":
		s.tabular = true
		return
	case "proportional-nums", "normal-nums":
		s.tabular = false
		return
	case "text-outline-none":
		s.outline_w = 0
		return
	case "oldstyle-nums", "lining-nums", "diagonal-fractions", "stacked-fractions",
	     "ordinal", "slashed-zero":
		// The rest of font-variant-numeric needs OpenType feature substitution,
		// which stb_truetype has no GSUB for. Accepted and ignored rather than
		// treated as an unknown class.
		return
	case "text-start":
		s.text_align = .Start
		return
	case "text-end":
		s.text_align = .End
		return
	case "text-left":
		s.text_align = .Left
		return
	case "text-center":
		s.text_align = .Center
		return
	case "text-right":
		s.text_align = .Right
		return
	case "inset-0":
		s.inset = {px(0), px(0), px(0), px(0)}
		return
	}

	// Prefixed utilities.
	if v, ok := strip(t, "items-"); ok {
		s.items = align_of_name(v, s.items)
		return
	}
	if v, ok := strip(t, "self-"); ok {
		s.self = align_of_name(v, s.self)
		return
	}
	if v, ok := strip(t, "justify-"); ok {
		switch v {
		case "start":
			s.justify = .Start
		case "center":
			s.justify = .Center
		case "end":
			s.justify = .End
		case "between":
			s.justify = .Between
		case "around":
			s.justify = .Around
		case "evenly":
			s.justify = .Evenly
		}
		return
	}
	if v, ok := strip(t, "gap-x-"); ok {
		if n, nok := scale(v); nok {s.gap.x = n}
		return
	}
	if v, ok := strip(t, "gap-y-"); ok {
		if n, nok := scale(v); nok {s.gap.y = n}
		return
	}
	if v, ok := strip(t, "gap-"); ok {
		if n, nok := scale(v); nok {s.gap = {n, n}}
		return
	}

	// Sizing.
	if v, ok := strip(t, "min-w-"); ok {
		if d, dok := dim_of(v); dok {s.min_w = d}
		return
	}
	if v, ok := strip(t, "min-h-"); ok {
		if d, dok := dim_of(v); dok {s.min_h = d}
		return
	}
	if v, ok := strip(t, "max-w-"); ok {
		if d, dok := dim_of(v); dok {s.max_w = d}
		return
	}
	if v, ok := strip(t, "max-h-"); ok {
		if d, dok := dim_of(v); dok {s.max_h = d}
		return
	}
	if v, ok := strip(t, "basis-"); ok {
		if d, dok := dim_of(v); dok {s.basis = d}
		return
	}
	if v, ok := strip(t, "size-"); ok {
		if d, dok := dim_of(v); dok {
			s.w, s.h = d, d
		}
		return
	}
	if v, ok := strip(t, "w-"); ok {
		if d, dok := dim_of(v); dok {s.w = d}
		return
	}
	if v, ok := strip(t, "h-"); ok {
		if d, dok := dim_of(v); dok {s.h = d}
		return
	}

	// Spacing. Padding and margin share the side-suffix grammar.
	if strings.has_prefix(t, "p") {
		if side, val, ok := split_sided(t, "p"); ok {
			if n, nok := scale(val); nok {
				set_sides(&s.pad, side, n)
				return
			}
		}
	}
	if strings.has_prefix(t, "m") {
		if side, val, ok := split_sided(t, "m"); ok {
			if val == "auto" {
				if side == "x" || side == "" {
					s.margin_auto_x = true
				}
				return
			}
			if n, nok := scale(val); nok {
				set_sides(&s.margin, side, n)
				return
			}
		}
	}

	// Position offsets.
	if v, ok := strip(t, "top-"); ok {
		if d, dok := dim_of(v); dok {s.inset[TOP] = d}
		return
	}
	if v, ok := strip(t, "right-"); ok {
		if d, dok := dim_of(v); dok {s.inset[RIGHT] = d}
		return
	}
	if v, ok := strip(t, "bottom-"); ok {
		if d, dok := dim_of(v); dok {s.inset[BOTTOM] = d}
		return
	}
	if v, ok := strip(t, "left-"); ok {
		if d, dok := dim_of(v); dok {s.inset[LEFT] = d}
		return
	}
	if v, ok := strip(t, "z-"); ok {
		if n, nok := strconv.parse_int(v); nok {s.z = n}
		return
	}

	// Colors and gradients.
	if v, ok := strip(t, "bg-gradient-to-"); ok {
		s.bg.gradient = true
		s.bg.vertical = v == "b" || v == "t"
		return
	}
	if v, ok := strip(t, "bg-"); ok {
		if c, cok := parse_color(v); cok {
			s.bg.color = c
			if !s.bg.gradient {
				s.bg.color2 = c
			}
			return
		}
	}
	if v, ok := strip(t, "from-"); ok {
		if c, cok := parse_color(v); cok {
			s.bg.color = c
			s.bg.gradient = true
			return
		}
	}
	if v, ok := strip(t, "to-"); ok {
		if c, cok := parse_color(v); cok {
			s.bg.color2 = c
			s.bg.gradient = true
			return
		}
	}
	if v, ok := strip(t, "border-"); ok {
		// border-<color>, border-<width> or border-<side>-<width|color>
		if c, cok := parse_color(v); cok {
			s.border_col = c
			return
		}
		if n, nok := border_width(v); nok {
			s.border_w = {n, n, n, n}
			return
		}
		side := v
		rest := ""
		if dash := strings.index_byte(v, '-'); dash > 0 {
			side, rest = v[:dash], v[dash + 1:]
		}
		if len(side) <= 2 {
			if c, cok := parse_color(rest); cok {
				s.border_col = c
				return
			}
			n, nok := border_width(rest)
			if !nok {
				n, nok = 1, true
			}
			if nok {
				set_sides(&s.border_w, side, n)
				return
			}
		}
		return
	}
	if v, ok := strip(t, "rounded-"); ok {
		if r, rok := radius_of(v); rok {
			s.radius = {r, r, r, r}
			return
		}
		if dash := strings.index_byte(v, '-'); dash > 0 {
			if r, rok := radius_of(v[dash + 1:]); rok {
				set_corners(&s.radius, v[:dash], r)
				return
			}
		}
		return
	}

	// `text-outline-*` is palmy's own, and has to be matched before the
	// `text-` namespace below or `outline-2` is tried as a size and a colour
	// and then silently dropped.
	if v, ok := strip(t, "text-outline-"); ok {
		if c, cok := parse_color(v); cok {
			s.outline_col = c
			if s.outline_w == 0 {
				s.outline_w = 1
			}
			return
		}
		if n, nok := scale_px(v); nok {
			s.outline_w = n
			if s.outline_col.a == 0 {
				s.outline_col = Color{0, 0, 0, 255}
			}
		}
		return
	}

	// Text: size wins over color, matching Tailwind's own namespace split.
	if v, ok := strip(t, "text-"); ok {
		if size, lead, sok := font_size_of(v); sok {
			s.font_size = size
			s.leading = lead
			s.leading_px = 0
			return
		}
		if c, cok := parse_color(v); cok {
			s.fg = c
			return
		}
	}
	if v, ok := strip(t, "leading-"); ok {
		switch v {
		case "none":
			s.leading, s.leading_px = 1, 0
		case "tight":
			s.leading, s.leading_px = 1.25, 0
		case "snug":
			s.leading, s.leading_px = 1.375, 0
		case "normal":
			s.leading, s.leading_px = 1.5, 0
		case "relaxed":
			s.leading, s.leading_px = 1.625, 0
		case "loose":
			s.leading, s.leading_px = 2, 0
		case:
			if n, nok := scale(v); nok {s.leading_px = n}
		}
		return
	}
	if v, ok := strip(t, "tracking-"); ok {
		switch v {
		case "tighter":
			s.tracking_em = -0.05
		case "tight":
			s.tracking_em = -0.025
		case "normal":
			s.tracking_em = 0
		case "wide":
			s.tracking_em = 0.025
		case "wider":
			s.tracking_em = 0.05
		case "widest":
			s.tracking_em = 0.1
		}
		return
	}
	if v, ok := strip(t, "ring-offset-"); ok {
		_ = v // ring offsets are not modelled; the ring sits on the border box
		return
	}
	if v, ok := strip(t, "ring-"); ok {
		if n, nok := strconv.parse_f32(v); nok {
			s.ring = n
			return
		}
		if col, cok := parse_color(v); cok {
			s.ring_col = col
			if s.ring == 0 {
				s.ring = 1
			}
			return
		}
		return
	}
	if v, ok := strip(t, "grid-cols-"); ok {
		// Approximated as a wrapping row of equal-width cells.
		if n, nok := strconv.parse_f32(v); nok && n > 0 {
			s.dir = .Row
			s.wrap = true
			s.grid_cols = int(n)
		}
		return
	}
	if v, ok := strip(t, "outline-"); ok {
		_ = v
		return
	}
	if v, ok := strip(t, "shadow-"); ok {
		switch v {
		case "sm":
			s.shadow = {1, 3, 0, hexa(0x0000_001a)}
		case "md":
			s.shadow = {4, 10, -1, hexa(0x0000_0024)}
		case "lg":
			s.shadow = {10, 20, -3, hexa(0x0000_002e)}
		case "xl":
			s.shadow = {20, 32, -5, hexa(0x0000_0033)}
		case "2xl":
			s.shadow = {25, 55, -12, hexa(0x0000_0047)}
		case:
			if c, cok := parse_color(v); cok {
				s.shadow.color = c
				if s.shadow.blur == 0 {
					s.shadow = {1, 4, 0, c}
				}
			}
		}
		return
	}
	if v, ok := strip(t, "opacity-"); ok {
		if n, nok := strconv.parse_f32(v); nok {
			s.opacity *= clamp(n / 100, 0, 1)
		}
		return
	}
	if v, ok := strip(t, "duration-"); ok {
		if n, nok := strconv.parse_f32(v); nok {
			s.transition = n / 1000
		}
		return
	}
}

// scale_px reads a literal pixel count, the way Tailwind's border and ring
// widths do, rather than a spacing step: `text-outline-2` is a 2px stroke.
@(private)
scale_px :: proc(t: string) -> (f32, bool) {
	if len(t) >= 3 && t[0] == '[' && t[len(t) - 1] == ']' {
		return scale(t)
	}
	return strconv.parse_f32(t)
}

@(private)
strip :: proc(t, prefix: string) -> (string, bool) {
	if strings.has_prefix(t, prefix) {
		return t[len(prefix):], true
	}
	return "", false
}

// split_sided breaks "px-4" into ("x", "4") and "p-4" into ("", "4").
@(private)
split_sided :: proc(t, base: string) -> (side, value: string, ok: bool) {
	if !strings.has_prefix(t, base) {
		return "", "", false
	}
	rest := t[len(base):]
	dash := strings.index_byte(rest, '-')
	if dash < 0 {
		return "", "", false
	}
	side = rest[:dash]
	value = rest[dash + 1:]
	switch side {
	case "", "x", "y", "t", "r", "b", "l", "s", "e":
		return side, value, true
	}
	return "", "", false
}

@(private)
border_width :: proc(t: string) -> (f32, bool) {
	// Border widths are literal pixels in Tailwind, not spacing steps.
	switch t {
	case "0":
		return 0, true
	case "2":
		return 2, true
	case "4":
		return 4, true
	case "8":
		return 8, true
	}
	if len(t) >= 3 && t[0] == '[' {
		return scale(t)
	}
	return 0, false
}

@(private)
align_of_name :: proc(v: string, fallback: Align) -> Align {
	switch v {
	case "start", "flex-start":
		return .Start
	case "center":
		return .Center
	case "end", "flex-end":
		return .End
	case "stretch":
		return .Stretch
	case "baseline":
		return .Baseline
	case "auto":
		return .Auto
	}
	return fallback
}
