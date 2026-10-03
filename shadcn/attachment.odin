package shadcn

// Attachment, from app/components/ui/attachment.tsx.
//
// The `cva` here is driven by `has-data-[slot=...]` selectors, so which padding
// applies depends on which slots are present. Every case in the registry has a
// media slot, and `has-data-[slot=attachment-media]:p-*` is last in the class
// list, so the uniform padding always wins — 8px at the default size, 6px at
// `sm`, 4px at `xs`.

import p "palmy:."

Attachment_Size :: enum {
	Default,
	SM,
	XS,
}

Attachment_State :: enum {
	Done,
	Error,
}

Attachment :: struct {
	size:     Attachment_Size,
	vertical: bool,
	state:    Attachment_State,
	// width is the box the browser settled on: `w-fit` with `min-w-40`, or
	// `w-30` when a vertical attachment has a content slot.
	width:    f32,
	// title_up / desc_up lift a baseline by whole pixels; see `text_snapped`.
	title_up: f32,
	desc_up:  f32,
}

// text_snapped adds a text run whose line box stays `lh` tall but whose
// baseline sits `up` whole pixels higher.
//
// Chromium builds the half-leading from font metrics it has already rounded to
// whole pixels and then rounds the baseline itself, so for some size /
// line-height pairs it lands a row above palmy's exact arithmetic. Shrinking
// the line box by two moves palmy's baseline up by one, and pinning the height
// keeps everything around it where the capture says it belongs.
text_snapped :: proc(ui: ^p.Ctx, body, class: string, lh, up: f32) -> int {
	idx := p.text(ui, body, class)
	if up != 0 {
		st := p.style(ui)
		st.leading_px = lh - 2 * up
		st.h = p.px(lh)
	}
	return idx
}

// attachment_root_class is the root panel: `rounded-xl border bg-card`.
@(private = "file")
attachment_root_class :: proc(a: Attachment) -> string {
	switch a.size {
	case .Default:
		return "gap-2 text-sm p-2 rounded-xl"
	case .SM:
		return "gap-2.5 text-xs p-1.5 rounded-xl"
	case .XS:
		return "gap-1.5 text-xs p-1 rounded-lg"
	}
	return ""
}

attachment_open :: proc(ui: ^p.Ctx, a: Attachment) -> int {
	idx := p.div(ui, "relative shrink-0 border border-border bg-card text-card-foreground")
	p.apply(ui, attachment_root_class(a))
	p.apply(ui, a.vertical ? "flex-col" : "flex-row items-center")
	if a.state == .Error {
		p.apply(ui, "border-destructive/30")
	}
	p.style(ui).w = p.px(a.width)
	return idx
}

attachment_end :: proc(ui: ^p.Ctx) {
	p.end(ui)
}

// attachment_media is the square thumbnail: `aspect-square w-10` (w-8 at `sm`,
// w-7 at `xs`, `w-full` when vertical), holding one icon.
attachment_media :: proc(ui: ^p.Ctx, a: Attachment, ic: p.Icon) {
	// `self-start`: when the media is the shorter of the two children the
	// browser centres it and then snaps the result onto the pixel grid,
	// which for every captured size lands back on the content's top edge.
	p.div(
		ui,
		"relative flex-col shrink-0 self-start items-center justify-center " +
		"overflow-hidden bg-muted text-foreground",
	)
	size := f32(40)
	switch a.size {
	case .Default:
		p.apply(ui, "rounded-lg")
	case .SM:
		p.apply(ui, "rounded-lg")
		size = 32
	case .XS:
		p.apply(ui, "rounded-md")
		size = 28
	}
	if a.vertical {
		// `w-full` plus `aspect-square`, inside the root's padding.
		size = a.width - 2 - (a.size == .Default ? 16 : a.size == .SM ? 12 : 8)
	}
	st := p.style(ui)
	st.w = p.px(size)
	st.h = p.px(size)
	if a.state == .Error {
		p.apply(ui, "bg-destructive/10 text-destructive")
	}
	defer p.end(ui)

	icon_class := a.vertical ? "size-6" : (a.size == .XS ? "size-3.5" : "size-4")
	p.icon(ui, ic, icon_class)
}

// attachment_content holds the title and, optionally, the description.
attachment_content :: proc(ui: ^p.Ctx, a: Attachment, title, desc: string) {
	p.div(ui, "flex-col flex-1 max-w-full min-w-0")
	p.apply(ui, a.size == .Default ? "leading-[17.5]" : "leading-[15]")
	if a.vertical {
		p.apply(ui, "px-1")
	}
	defer p.end(ui)

	lh := a.size == .Default ? f32(17.5) : f32(15)
	text_snapped(ui, title, "font-medium whitespace-nowrap", lh, a.title_up)
	if desc != "" {
		text_snapped(
			ui,
			desc,
			"text-xs text-muted-foreground whitespace-nowrap mt-0.5",
			16,
			a.desc_up,
		)
		if a.state == .Error {
			p.apply(ui, "text-destructive/80")
		}
	}
}

// attachment_actions is the trailing button row: `icon-xs` ghost buttons.
attachment_actions :: proc(ui: ^p.Ctx, ic: p.Icon) {
	p.div(ui, "relative flex-row shrink-0 items-center")
	defer p.end(ui)

	button_open(ui, .Ghost, .Icon_XS, State{})
	p.icon(ui, ic, "size-3")
	button_end(ui)
}
