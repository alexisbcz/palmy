package shadcn

// Breadcrumb, from app/components/ui/breadcrumb.tsx.
//
// `<nav>` carries nothing visual, so the root here is the `<ol>`: a wrapping
// row of items with a 6px gap.

import p "palmy:."

BREADCRUMB_LIST ::
	"flex-row flex-wrap items-center gap-1.5 text-sm text-muted-foreground"

breadcrumb_open :: proc(ui: ^p.Ctx) {
	p.div(ui, "")
	p.div(ui, BREADCRUMB_LIST)
}

breadcrumb_close :: proc(ui: ^p.Ctx) {
	p.end(ui)
	p.end(ui)
}

// breadcrumb_link is BreadcrumbItem + BreadcrumbLink.
breadcrumb_link :: proc(ui: ^p.Ctx, label: string) {
	p.div(ui, "flex-row items-center gap-1")
	p.text(ui, label, "whitespace-nowrap")
	p.style(ui).shrink = 0
	p.end(ui)
}

// breadcrumb_page is the current page: same box, foreground colour.
breadcrumb_page :: proc(ui: ^p.Ctx, label: string) {
	p.div(ui, "flex-row items-center gap-1")
	p.text(ui, label, "whitespace-nowrap text-foreground")
	p.style(ui).shrink = 0
	p.end(ui)
}

// breadcrumb_separator is the `<li>` wrapping a 14px chevron.
breadcrumb_separator :: proc(ui: ^p.Ctx) {
	p.div(ui, "flex-row items-center")
	p.icon(ui, ICON_CHEVRON_RIGHT, "size-3.5")
	p.end(ui)
}

// breadcrumb_ellipsis is `flex size-5 items-center justify-center` with a
// 16px ellipsis inside.
breadcrumb_ellipsis :: proc(ui: ^p.Ctx) {
	p.div(ui, "flex-row items-center")
	p.div(ui, "flex-row size-5 items-center justify-center")
	p.icon(ui, ICON_ELLIPSIS, "size-4")
	p.end(ui)
	p.end(ui)
}
