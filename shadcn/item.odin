package shadcn

// Item, from app/components/ui/item.tsx.
//
// ItemMedia carries `group-has-data-[slot=item-description]/item:self-start`
// and `:translate-y-0.5`. The translate is a paint offset in CSS; a 2px top
// margin lands in the same place because the content stack is taller than the
// media, so the row's height does not change.

import p "palmy:."

Item_Variant :: enum {
	Default,
	Outline,
	Muted,
}

Item_Size :: enum {
	Default,
	SM,
	XS,
}

ITEM_BASE :: "flex-row w-full flex-wrap items-center rounded-lg border text-sm"

item_variant_class :: proc(v: Item_Variant) -> string {
	switch v {
	case .Default:
		return "border-transparent"
	case .Outline:
		return "border-border"
	case .Muted:
		return "border-transparent bg-muted/50"
	}
	return ""
}

item_size_class :: proc(s: Item_Size) -> string {
	switch s {
	case .Default, .SM:
		return "gap-2.5 px-3 py-2.5"
	case .XS:
		return "gap-2 px-2.5 py-2"
	}
	return ""
}

item_open :: proc(
	ui: ^p.Ctx,
	v := Item_Variant.Default,
	s := Item_Size.Default,
	class := "",
) -> int {
	idx := p.div(ui, ITEM_BASE)
	p.apply(ui, item_variant_class(v))
	p.apply(ui, item_size_class(s))
	p.apply(ui, class)
	return idx
}

item_end :: proc(ui: ^p.Ctx) {
	p.end(ui)
}

// item_media_icon is `variant="icon"`: a shrink-to-fit box around a 16px glyph.
item_media_icon :: proc(ui: ^p.Ctx, ic: p.Icon) {
	p.div(ui, "flex-row shrink-0 items-center justify-center gap-2 self-start mt-0.5")
	defer p.end(ui)
	p.icon(ui, ic, "size-4 shrink-0")
}

item_content_open :: proc(ui: ^p.Ctx, s := Item_Size.Default) -> int {
	return p.col(ui, s == .XS ? "flex-1 gap-0" : "flex-1 gap-1")
}

item_content_end :: proc(ui: ^p.Ctx) {
	p.end(ui)
}

// `line-clamp-1 flex w-fit items-center gap-2 text-sm leading-snug font-medium`
item_title :: proc(ui: ^p.Ctx, label: string) {
	p.text(ui, label, "self-start text-sm leading-snug font-medium whitespace-nowrap")
}

// `line-clamp-2 text-left text-sm leading-normal text-muted-foreground`, and
// `group-data-[size=xs]/item:text-xs`.
item_description :: proc(ui: ^p.Ctx, label: string, s := Item_Size.Default) {
	p.text(ui, label, "text-muted-foreground leading-normal")
	p.apply(ui, s == .XS ? "text-xs" : "text-sm")
	p.apply(ui, "leading-normal")
}

item_actions_open :: proc(ui: ^p.Ctx) -> int {
	return p.row(ui, "items-center gap-2")
}

item_actions_end :: proc(ui: ^p.Ctx) {
	p.end(ui)
}
