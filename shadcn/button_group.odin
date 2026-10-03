package shadcn

// Button group, from app/components/ui/button-group.tsx.
//
// The cva string is a pile of child selectors; resolved for a row of N items
// they come to: every item loses the trailing corners, the last one gets them
// back, and every item after the first loses its leading corners and its
// leading border so neighbours share one hairline.

import p "palmy:."

Group_Pos :: enum {
	First,
	Middle,
	Last,
	Only,
}

button_group_open :: proc(ui: ^p.Ctx, vertical := false) {
	p.div(ui, vertical ? "flex-col w-fit items-stretch" : "flex-row w-fit items-stretch")
}

button_group_close :: proc(ui: ^p.Ctx) {
	p.end(ui)
}

// group_edge_class returns the corner and shared-border overrides for one
// slot in the group.
group_edge_class :: proc(pos: Group_Pos, vertical: bool) -> string {
	if vertical {
		switch pos {
		case .Only:
			return ""
		case .First:
			return "rounded-b-none"
		case .Middle:
			return "rounded-t-none rounded-b-none border-t-0"
		case .Last:
			return "rounded-t-none border-t-0"
		}
	}
	switch pos {
	case .Only:
		return ""
	case .First:
		return "rounded-r-none"
	case .Middle:
		return "rounded-r-none rounded-l-none border-l-0"
	case .Last:
		return "rounded-l-none border-l-0"
	}
	return ""
}

// group_seam_cover paints over the border edge the group is supposed to drop.
//
// palmy renders a border whose four widths differ as four plain rectangles, so
// a slot with `border-l-0` and `rounded-r-lg` comes out with square corners.
// The last slot therefore keeps a uniform border — which palmy strokes as a
// proper rounded rect — and the edge CSS removes is painted back out in the
// button's own background colour. The result is pixel-identical to the TSX.
group_seam_cover :: proc(ui: ^p.Ctx, vertical: bool) {
	p.div(ui, "absolute bg-background")
	st := p.style(ui)
	if vertical {
		// Insets are measured from the content box, so they carry the 1px
		// border and the 10px horizontal padding back out.
		st.h = p.px(1)
		st.inset[p.TOP] = p.px(-1)
		st.inset[p.LEFT] = p.px(-10)
		st.inset[p.RIGHT] = p.px(-10)
	} else {
		st.w = p.px(1)
		st.inset[p.LEFT] = p.px(-10)
		st.inset[p.TOP] = p.px(0)
		st.inset[p.BOTTOM] = p.px(0)
	}
	p.end(ui)
}

// button_group_button is an outline Button sitting in the group.
button_group_button :: proc(ui: ^p.Ctx, label: string, pos: Group_Pos, vertical := false) {
	button_open(ui, .Outline, .Default, State{})
	p.apply(ui, "flex-row")
	p.apply(ui, group_edge_class(pos, vertical))
	if pos == .Last {
		// The uniform border adds a pixel on the main axis of a row, so the
		// leading padding gives it back and the content box stays put.
		p.apply(ui, vertical ? "border" : "border pl-[9]")
		group_seam_cover(ui, vertical)
	}
	p.text(ui, label, "whitespace-nowrap")
	// Chromium rounds the font's ascent and descent to whole pixels before it
	// lays out a line box, so its baseline is half a pixel below palmy's. In a
	// slot with no top border the content box starts at a half pixel and that
	// difference flips the glyph rounding, which a pixel of margin undoes.
	if vertical && pos == .Middle {
		p.style(ui).margin[p.TOP] = 1
	}
	p.style(ui).shrink = 0
	button_end(ui)
}

BUTTON_GROUP_TEXT ::
	"flex-row items-center gap-2 rounded-lg border border-border bg-muted px-2.5 " +
	"text-sm font-medium"

button_group_text :: proc(ui: ^p.Ctx, label: string, pos: Group_Pos, vertical := false) {
	p.div(ui, BUTTON_GROUP_TEXT)
	p.apply(ui, group_edge_class(pos, vertical))
	p.text(ui, label, "whitespace-nowrap")
	p.style(ui).shrink = 0
	p.end(ui)
}

// button_group_separator is a Separator: `self-stretch bg-input` with a
// one-pixel margin on the cross axis so it stops short of the rounded ends.
button_group_separator :: proc(ui: ^p.Ctx, vertical := true) {
	if vertical {
		p.div(ui, "w-px bg-input self-stretch my-px shrink-0")
	} else {
		p.div(ui, "h-px bg-input self-stretch mx-px shrink-0")
	}
	p.end(ui)
}
