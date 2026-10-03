package shadcn

// Navigation menu, from app/components/ui/navigation-menu.tsx.

import p "palmy:."

NAV_TRIGGER ::
	"flex-row h-9 items-center justify-center rounded-lg px-2.5 py-1.5 " +
	"text-sm font-medium"

navigation_menu_open :: proc(ui: ^p.Ctx) {
	p.div(ui, "flex-row relative items-center justify-center") // <nav>
	p.div(ui, "flex-row items-center justify-center") // <ul>
}

navigation_menu_close :: proc(ui: ^p.Ctx) {
	p.end(ui)
	p.end(ui)
}

// navigation_menu_trigger is one top-level entry.
//
// The TSX writes `{children}{" "}` before the chevron. Flex wraps the two
// contiguous text runs into one anonymous item whose trailing space is then
// stripped at the end of the line, so the label measures on its own.
//
// The chevron is `relative top-px`: palmy only offsets absolutely positioned
// nodes, and under `items-center` a margin moves a box by half its value, so
// two pixels of top margin reproduce the one-pixel nudge exactly.
navigation_menu_trigger :: proc(ui: ^p.Ctx, label: string, open := false) {
	p.div(ui, "relative") // <li>
	p.div(ui, NAV_TRIGGER)
	if open {
		p.apply(ui, "bg-muted/50")
	}
	p.text(ui, label, "whitespace-nowrap")
	p.style(ui).shrink = 0
	p.icon(ui, ICON_CHEVRON_DOWN, "size-3 ml-1 shrink-0")
	p.style(ui).margin[p.TOP] = 2
	p.end(ui)
	p.end(ui)
}

NAV_LINK :: "flex-row items-center gap-2 rounded-md p-2 text-sm"

// navigation_menu_content_open is NavigationMenuContent: `h-full w-auto p-1`.
// The popup's own background and ring belong to the positioner, which the case
// does not capture.
navigation_menu_content_open :: proc(ui: ^p.Ctx) {
	p.div(ui, "flex-col p-1")
}

navigation_menu_content_close :: proc(ui: ^p.Ctx) {
	p.end(ui)
}

navigation_menu_link :: proc(ui: ^p.Ctx, label: string, ic: p.Icon) {
	p.div(ui, NAV_LINK)
	p.icon(ui, ic, "size-4 shrink-0")
	p.text(ui, label, "whitespace-nowrap")
	p.style(ui).shrink = 0
	p.end(ui)
}
