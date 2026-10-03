package shadcn

// Sidebar, from app/components/ui/sidebar.tsx, in the `collapsible="none"`
// shape the cases use: a plain `flex h-full w-(--sidebar-width) flex-col
// bg-sidebar` panel, 16rem wide.

import p "palmy:."

SIDEBAR_ROOT :: "flex-col w-64 bg-sidebar text-sidebar-foreground border border-border"

sidebar_open :: proc(ui: ^p.Ctx, height_class: string) {
	p.div(ui, SIDEBAR_ROOT)
	p.apply(ui, height_class)
}

sidebar_close :: proc(ui: ^p.Ctx) {
	p.end(ui)
}

// Header and footer share `flex flex-col gap-2 p-2`.
sidebar_header_open :: proc(ui: ^p.Ctx) {
	p.div(ui, "flex-col gap-2 p-2")
}

sidebar_footer_open :: proc(ui: ^p.Ctx) {
	p.div(ui, "flex-col gap-2 p-2")
}

sidebar_section_close :: proc(ui: ^p.Ctx) {
	p.end(ui)
}

// sidebar_separator is a Separator with `mx-2 w-auto`, but the primitive's
// `data-horizontal:w-full` is an attribute selector and so wins on
// specificity: the rule really is `w-full` plus an 8px margin, and the line
// runs a little past the panel's right edge.
sidebar_separator :: proc(ui: ^p.Ctx) {
	p.div(ui, "h-px w-full mx-2 bg-sidebar-border")
	p.end(ui)
}

sidebar_content_open :: proc(ui: ^p.Ctx) {
	p.div(ui, "flex-col flex-1 min-h-0")
}

sidebar_group_open :: proc(ui: ^p.Ctx) {
	p.div(ui, "relative flex-col w-full min-w-0 p-2")
}

sidebar_group_content_open :: proc(ui: ^p.Ctx) {
	p.div(ui, "flex-col w-full text-sm")
}

sidebar_group_label :: proc(ui: ^p.Ctx, label: string) {
	p.div(ui, "flex-row h-8 shrink-0 items-center rounded-md px-2 text-xs font-medium text-sidebar-foreground/70")
	p.text(ui, label, "whitespace-nowrap")
	p.style(ui).shrink = 0
	p.end(ui)
}

sidebar_menu_open :: proc(ui: ^p.Ctx) {
	p.div(ui, "flex-col w-full min-w-0")
}

sidebar_menu_item_open :: proc(ui: ^p.Ctx) {
	p.div(ui, "relative flex-col")
}

sidebar_close_one :: proc(ui: ^p.Ctx) {
	p.end(ui)
}

// `p-2` is written as `px-2` on purpose. The button's height is fixed, so the
// vertical padding only shrinks the content box; CSS then centres a 20px line
// box inside 16px and lets it overflow, while palmy's `items-center` never
// goes negative and pins the text to the top. Dropping the vertical padding
// leaves both the icon and the text exactly where CSS puts them.
SIDEBAR_MENU_BUTTON ::
	"flex-row w-full items-center gap-2 overflow-hidden rounded-md px-2 text-left text-sm"

// sidebar_menu_button is SidebarMenuButton. `size="lg"` is `h-12`, the default
// is `h-8`, and `isActive` switches to the accent background with medium text.
sidebar_menu_button :: proc(
	ui: ^p.Ctx,
	label: string,
	ic: p.Icon,
	active := false,
	large := false,
) {
	p.div(ui, SIDEBAR_MENU_BUTTON)
	p.apply(ui, large ? "h-12" : "h-8")
	if active {
		p.apply(ui, "bg-sidebar-accent font-medium text-sidebar-accent-foreground")
	}
	p.icon(ui, ic, "size-4 shrink-0")
	p.text(ui, label, "whitespace-nowrap")
	p.style(ui).shrink = 0
	p.end(ui)
}

// sidebar_menu_badge floats against the menu item, not the button:
// `absolute right-1`, and `top-1.5` for a default-size button.
sidebar_menu_badge :: proc(ui: ^p.Ctx, label: string, active := false) {
	p.div(ui, "absolute right-1 top-1.5 flex-row h-5 min-w-5 items-center justify-center rounded-md px-1 text-xs font-medium")
	p.apply(ui, active ? "text-sidebar-accent-foreground" : "text-sidebar-foreground")
	p.text(ui, label, "whitespace-nowrap")
	p.style(ui).shrink = 0
	p.end(ui)
}

// sidebar_menu_sub_open is `mx-3.5 translate-x-px ... border-l px-2.5 py-0.5`.
// palmy has no transforms, so the single pixel is folded into the margins,
// which keeps both the left edge and the width exact.
sidebar_menu_sub_open :: proc(ui: ^p.Ctx) {
	p.div(ui, "flex-col min-w-0 gap-1 border-l border-sidebar-border px-2.5 py-0.5")
	st := p.style(ui)
	st.margin[p.LEFT] = 15
	st.margin[p.RIGHT] = 13
}

SIDEBAR_SUB_BUTTON ::
	"flex-row h-7 min-w-0 items-center gap-2 overflow-hidden rounded-md px-2 " +
	"text-sm text-sidebar-foreground"

// sidebar_menu_sub_button carries `-translate-x-px`, folded into its margins.
sidebar_menu_sub_button :: proc(ui: ^p.Ctx, label: string, active := false) {
	p.div(ui, "relative flex-col") // <li>
	p.div(ui, SIDEBAR_SUB_BUTTON)
	if active {
		p.apply(ui, "bg-sidebar-accent text-sidebar-accent-foreground")
	}
	st := p.style(ui)
	st.margin[p.LEFT] = -1
	st.margin[p.RIGHT] = 1
	p.text(ui, label, "whitespace-nowrap")
	p.style(ui).shrink = 0
	p.end(ui)
	p.end(ui)
}
