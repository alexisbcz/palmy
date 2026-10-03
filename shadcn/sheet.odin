package shadcn

// Sheet and drawer, from app/components/ui/sheet.tsx and drawer.tsx. Both are
// edge-anchored panels with a header, a footer pushed down by `mt-auto`, and a
// single hairline on the edge they slide in from. palmy has no `mt-auto`, so a
// `flex-1` spacer stands in: the resulting positions are identical.

import p "palmy:."

Side :: enum {
	Right,
	Bottom,
}

SHEET_BASE :: "flex-col gap-4 bg-popover text-sm text-popover-foreground shadow-lg"

sheet_content_open :: proc(ui: ^p.Ctx, side: Side) -> int {
	idx := p.div(ui, SHEET_BASE)
	switch side {
	case .Right:
		p.apply(ui, "h-full w-full border-l border-border", idx)
	case .Bottom:
		p.apply(ui, "w-full border-t border-border", idx)
	}
	return idx
}

sheet_header_open :: proc(ui: ^p.Ctx) -> int {
	return p.col(ui, "gap-0.5 p-4")
}

sheet_footer_open :: proc(ui: ^p.Ctx) -> int {
	return p.col(ui, "gap-2 p-4")
}

sheet_title :: proc(ui: ^p.Ctx, s: string) {
	p.text(ui, s, "text-base font-medium text-foreground")
}

sheet_description :: proc(ui: ^p.Ctx, s: string) {
	p.text(ui, s, "text-sm text-muted-foreground")
}

// sheet_spacer replaces the footer's `mt-auto`.
sheet_spacer :: proc(ui: ^p.Ctx) {
	p.div(ui, "flex-1")
	p.end(ui)
}

DRAWER_BASE :: "flex-col bg-popover text-sm text-popover-foreground"

drawer_content_open :: proc(ui: ^p.Ctx, side: Side) -> int {
	idx := p.div(ui, DRAWER_BASE)
	switch side {
	case .Right:
		p.apply(ui, "h-full w-full rounded-l-xl border-l border-border", idx)
	case .Bottom:
		p.apply(ui, "w-full rounded-t-xl border-t border-border", idx)
	}
	return idx
}

// The popup's inner `<DrawerPrimitive.Content>` is `flex-1 flex-col
// overflow-hidden rounded-[inherit]`.
drawer_body_open :: proc(ui: ^p.Ctx, side: Side) -> int {
	idx := p.col(ui, "flex-1 overflow-hidden")
	switch side {
	case .Right:
		p.apply(ui, "rounded-l-xl", idx)
	case .Bottom:
		p.apply(ui, "rounded-t-xl", idx)
	}
	return idx
}

// `p-4 pb-0`, and `text-center` when the drawer slides on the y axis.
drawer_header_open :: proc(ui: ^p.Ctx, centered: bool) -> int {
	idx := p.col(ui, "shrink-0 gap-0.5 p-4 pb-0")
	if centered {
		p.apply(ui, "text-center", idx)
	}
	return idx
}

// `mt-auto p-4 pt-0 gap-2`.
drawer_footer_open :: proc(ui: ^p.Ctx) -> int {
	return p.col(ui, "shrink-0 gap-2 p-4 pt-0")
}
