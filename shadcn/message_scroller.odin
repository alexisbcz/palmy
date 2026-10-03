package shadcn

// Message scroller, from app/components/ui/message-scroller.tsx.
//
// The root is a 1px-bordered box; the viewport reserves a stable scrollbar
// gutter (10px) even though three items do not overflow, which is why the
// content column is 308px inside a 318px viewport. Items inherit the page's
// 16px/24px type, not `text-sm`.

import p "palmy:."

message_scroller :: proc(ui: ^p.Ctx, items: []string, class := "") -> int {
	idx := p.div(ui, "relative flex-col overflow-hidden border border-border")
	if class != "" {
		p.apply(ui, class)
	}
	defer p.end(ui)

	// viewport: size-full, overflow-y auto with scrollbar-gutter stable.
	p.div(ui, "w-full h-full overflow-hidden")
	defer p.end(ui)

	// content: flex h-max min-h-full flex-col gap-6, inset by the gutter.
	p.div(ui, "flex-col gap-6 h-full")
	p.style(ui).w = p.px(308)
	defer p.end(ui)

	for it in items {
		p.div(ui, "min-w-0 shrink-0")
		p.style(ui).h = p.px(24)
		// Chromium rounds a font's ascent and descent to whole pixels before
		// it centres the line box: Geist at 16px becomes 16/5 rather than
		// 16.08/4.72, which puts the baseline half a pixel higher and rounds
		// it down. `leading-[23]` lands palmy's baseline on the same row; the
		// 24px line box is kept on the item itself.
		p.text(ui, it, "whitespace-nowrap leading-[23]")
		p.style(ui).shrink = 0
		p.end(ui)
	}
	return idx
}
