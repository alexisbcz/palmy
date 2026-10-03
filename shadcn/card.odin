package shadcn

// Card, from app/components/ui/card.tsx.
//
// `--card-spacing` is `--spacing(4)` by default and `--spacing(3)` at
// `data-[size=sm]`; it drives the card's vertical padding, the gap between
// slots, and the horizontal padding of every slot. The CSS variable is resolved
// here into explicit utilities instead.
//
// `has-data-[slot=card-footer]:pb-0` drops the bottom padding when a footer is
// present, because the footer paints its own.

import p "palmy:."

Card_Size :: enum {
	Default,
	SM,
}

CARD_BASE ::
	"flex-col overflow-hidden rounded-xl bg-card text-sm text-card-foreground " +
	"ring-1 ring-foreground/10"

card_open :: proc(ui: ^p.Ctx, size := Card_Size.Default, has_footer := false, class := "") -> int {
	idx := p.div(ui, CARD_BASE)
	p.apply(ui, size == .SM ? "gap-3 py-3" : "gap-4 py-4")
	if has_footer {
		p.apply(ui, "pb-0")
	}
	p.apply(ui, class)
	return idx
}

card_end :: proc(ui: ^p.Ctx) {
	p.end(ui)
}

card_pad_class :: proc(size: Card_Size) -> string {
	return size == .SM ? "px-3" : "px-4"
}

// card_header_open is the `grid auto-rows-min items-start gap-1` header. With a
// CardAction the grid becomes `grid-cols-[1fr_auto]`, which is a row of two
// cells: the title/description stack, then the action.
//
// With an action the call sequence is
//
//	card_header_open(ui, size, true)
//	  card_title(...); card_description(...)
//	card_header_text_end(ui)
//	card_action_open(ui); ...; card_action_end(ui)
//	card_header_end(ui)
card_header_open :: proc(ui: ^p.Ctx, size := Card_Size.Default, with_action := false) -> int {
	idx := with_action ? p.row(ui, "items-start gap-1") : p.col(ui, "gap-1")
	p.apply(ui, card_pad_class(size))
	if with_action {
		// The title/description stack is the `1fr` column.
		p.col(ui, "flex-1 gap-1")
	}
	return idx
}

card_header_text_end :: proc(ui: ^p.Ctx) {
	p.end(ui)
}

// card_action is `col-start-2 row-span-2 row-start-1 self-start justify-self-end`.
card_action_open :: proc(ui: ^p.Ctx) -> int {
	return p.div(ui, "self-start items-end")
}

card_action_end :: proc(ui: ^p.Ctx) {
	p.end(ui)
}

card_header_end :: proc(ui: ^p.Ctx) {
	p.end(ui)
}

card_title :: proc(ui: ^p.Ctx, label: string, size := Card_Size.Default) {
	p.text(ui, label, "font-medium leading-snug")
	p.apply(ui, size == .SM ? "text-sm" : "text-base")
	p.apply(ui, "leading-snug")
}

card_description :: proc(ui: ^p.Ctx, label: string) {
	p.text(ui, label, "text-sm text-muted-foreground")
}

card_content :: proc(ui: ^p.Ctx, label: string, size := Card_Size.Default) {
	p.div(ui, card_pad_class(size))
	defer p.end(ui)
	p.text(ui, label, "text-sm")
}

CARD_FOOTER_BASE :: "flex-row items-center rounded-b-xl border-t border-border bg-muted/50"

card_footer_open :: proc(ui: ^p.Ctx, size := Card_Size.Default) -> int {
	idx := p.div(ui, CARD_FOOTER_BASE)
	p.apply(ui, size == .SM ? "p-3" : "p-4")
	return idx
}

card_footer_end :: proc(ui: ^p.Ctx) {
	p.end(ui)
}
