package shadcn

// Menubar, from app/components/ui/menubar.tsx. The popup inherits its classes
// from dropdown-menu.tsx, since MenubarContent/MenubarItem wrap those.

import p "palmy:."

MENUBAR_BAR :: "flex-row h-8 items-center gap-0.5 rounded-lg border border-border p-[3]"

MENUBAR_TRIGGER ::
	"flex-row items-center rounded-sm px-1.5 py-[2] text-sm font-medium"

menubar_open :: proc(ui: ^p.Ctx) {
	p.div(ui, MENUBAR_BAR)
}

menubar_close :: proc(ui: ^p.Ctx) {
	p.end(ui)
}

// menubar_trigger is a menu name in the bar. An open menu gets
// `aria-expanded:bg-muted`.
menubar_trigger :: proc(ui: ^p.Ctx, label: string, open := false) {
	p.div(ui, MENUBAR_TRIGGER)
	if open {
		p.apply(ui, "bg-muted")
	}
	p.text(ui, label, "whitespace-nowrap")
	p.style(ui).shrink = 0
	p.end(ui)
}

MENUBAR_CONTENT ::
	"flex-col min-w-36 rounded-lg bg-popover p-1 text-popover-foreground " +
	"shadow-md ring-1 ring-foreground/10"

MENUBAR_ITEM ::
	"flex-row items-center justify-between gap-1.5 rounded-md px-1.5 py-1 text-sm"

menubar_content_open :: proc(ui: ^p.Ctx) {
	p.div(ui, MENUBAR_CONTENT)
}

menubar_content_close :: proc(ui: ^p.Ctx) {
	p.end(ui)
}

// menubar_item is one row of the popup. The shortcut is `ml-auto`, which with
// exactly two children is `justify-between`.
menubar_item :: proc(ui: ^p.Ctx, label: string, shortcut := "") {
	p.div(ui, MENUBAR_ITEM)
	p.text(ui, label, "whitespace-nowrap")
	p.style(ui).shrink = 0
	if shortcut != "" {
		p.text(ui, shortcut, "text-xs tracking-widest text-muted-foreground whitespace-nowrap")
		p.style(ui).shrink = 0
	}
	p.end(ui)
}

// menubar_separator is `-mx-1 my-1 h-px bg-border`; palmy's class parser has
// no negative spacing, so the margins are set on the style.
menubar_separator :: proc(ui: ^p.Ctx) {
	p.div(ui, "h-px bg-border")
	st := p.style(ui)
	st.margin = {4, -4, 4, -4}
	p.end(ui)
}
