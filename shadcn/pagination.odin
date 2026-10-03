package shadcn

// Pagination, from app/components/ui/pagination.tsx.
//
// Every control is a Button underneath: the numbered links are `size="icon"`,
// ghost unless they are the current page, and the previous/next links are
// default-size ghost buttons whose leading (trailing) padding is cut to 6px by
// `pl-1.5!` (`pr-1.5!`).

import p "palmy:."

PAGINATION_CONTENT :: "flex-row items-center gap-0.5"

pagination_open :: proc(ui: ^p.Ctx) {
	p.div(ui, "flex-row w-full justify-center")
	p.div(ui, PAGINATION_CONTENT)
}

pagination_close :: proc(ui: ^p.Ctx) {
	p.end(ui)
	p.end(ui)
}

// pagination_link is one numbered page. `isActive` switches the Button from
// ghost to outline, which is what draws the box around the current page.
pagination_link :: proc(ui: ^p.Ctx, label: string, active := false) {
	p.div(ui, "") // <li>
	button_open(ui, active ? .Outline : .Ghost, .Icon, State{})
	p.apply(ui, "flex-row")
	p.text(ui, label, "whitespace-nowrap")
	p.style(ui).shrink = 0
	button_end(ui)
	p.end(ui)
}

pagination_previous :: proc(ui: ^p.Ctx, label := "Previous") {
	p.div(ui, "")
	button_open(ui, .Ghost, .Default, State{})
	p.apply(ui, "flex-row pl-1.5")
	p.icon(ui, ICON_CHEVRON_LEFT, "size-4")
	p.text(ui, label, "whitespace-nowrap")
	p.style(ui).shrink = 0
	button_end(ui)
	p.end(ui)
}

pagination_next :: proc(ui: ^p.Ctx, label := "Next") {
	p.div(ui, "")
	button_open(ui, .Ghost, .Default, State{})
	p.apply(ui, "flex-row pr-1.5")
	p.text(ui, label, "whitespace-nowrap")
	p.style(ui).shrink = 0
	p.icon(ui, ICON_CHEVRON_RIGHT, "size-4")
	button_end(ui)
	p.end(ui)
}

pagination_ellipsis :: proc(ui: ^p.Ctx) {
	p.div(ui, "")
	p.div(ui, "flex-row size-8 items-center justify-center")
	p.icon(ui, ICON_ELLIPSIS, "size-4")
	p.end(ui)
	p.end(ui)
}
