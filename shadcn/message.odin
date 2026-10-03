package shadcn

// Message, from app/components/ui/message.tsx.
//
// `data-[align=end]:flex-row-reverse` only matters when there is an avatar; the
// end-aligned case in the registry has none, so the reversal shows up purely as
// `self-end` on the content's children.

import p "palmy:."

MESSAGE_BASE :: "group/message relative flex-row w-full min-w-0 gap-2 text-sm"

message_open :: proc(ui: ^p.Ctx, align_end := false, class := "") -> int {
	idx := p.div(ui, MESSAGE_BASE)
	p.apply(ui, align_end ? "flex-row-reverse" : "")
	if class != "" {
		p.apply(ui, class)
	}
	return idx
}

message_end :: proc(ui: ^p.Ctx) {
	p.end(ui)
}

// message_avatar is `w-fit min-w-8 ... self-end rounded-full bg-muted`: as wide
// as its initials but never under 32px, and as tall as one line of text.
message_avatar :: proc(ui: ^p.Ctx, initials: string, lift: f32 = 0) {
	p.div(
		ui,
		"flex-row min-w-8 shrink-0 items-center justify-center self-end " +
		"overflow-hidden rounded-full bg-muted",
	)
	// `lift` pulls the bottom-aligned avatar back onto the whole pixel the
	// browser snapped it to, when the row's own height is fractional.
	p.style(ui).margin[p.BOTTOM] = lift
	defer p.end(ui)
	p.text(ui, initials, "")
	p.style(ui).shrink = 0
}

message_content_open :: proc(ui: ^p.Ctx) -> int {
	return p.div(ui, "flex-1 flex-col w-full min-w-0 gap-2.5")
}

message_content_end :: proc(ui: ^p.Ctx) {
	p.end(ui)
}

// message_header / message_footer are the `px-3 text-xs font-medium` captions
// above and below the bubble.
message_caption :: proc(ui: ^p.Ctx, label: string, align_end := false) {
	p.div(
		ui,
		"flex-row max-w-full min-w-0 items-center px-3 text-xs font-medium text-muted-foreground",
	)
	p.apply(ui, align_end ? "self-end" : "self-start")
	defer p.end(ui)
	p.text(ui, label, "")
	p.style(ui).shrink = 0
}
