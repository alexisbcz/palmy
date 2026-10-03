package shadcn

// Avatar, from app/components/ui/avatar.tsx. Only the initials fallback is
// used by the parity cases, so no image path is modelled.
//
// Two shapes here are drawn as stacked filled discs rather than with `border`
// or `ring`:
//
//   * the root's hairline, which in the TSX is an `after:` pseudo-element
//     (`absolute inset-0 rounded-full border border-border`);
//   * `ring-2 ring-background`, the white separator between stacked avatars.
//
// palmy's `stroke_round_rect` skips the middle rows of a ring as a fast path
// that assumes straight sides, which is right for a rounded rectangle and wrong
// for a circle: on a 32px round avatar everything but the two extreme columns
// is dropped. A disc of the outer colour with a smaller disc of the inner
// colour on top produces exactly the same pixels and does not depend on that
// path. The root therefore carries no background of its own; every layer is an
// absolutely positioned child, which also keeps the content box 32px wide so
// the badge's `right-0 bottom-0` lands where CSS puts it.

import p "palmy:."

Avatar_Size :: enum {
	Default,
	SM,
	LG,
}

avatar_size_class :: proc(s: Avatar_Size) -> string {
	switch s {
	case .Default:
		return "size-8"
	case .SM:
		return "size-6"
	case .LG:
		return "size-10"
	}
	return "size-8"
}

// `group-data-[size=sm]/avatar:text-xs`; the other sizes keep `text-sm`.
avatar_text_class :: proc(s: Avatar_Size) -> string {
	return s == .SM ? "text-xs" : "text-sm"
}

// A 2px disc outset on every side: `ring-2 ring-background`.
RING_2 :: "absolute top-[-2] right-[-2] bottom-[-2] left-[-2] rounded-full bg-background"

// avatar_open leaves the root open so a badge can be added; `avatar_end` closes
// it. `ringed` is the `*:data-[slot=avatar]:ring-2 ring-background` an
// AvatarGroup puts on its children.
avatar_open :: proc(ui: ^p.Ctx, size := Avatar_Size.Default, ringed := false, class := "") -> int {
	idx := p.div(ui, "relative flex-row shrink-0 items-center justify-center select-none")
	p.apply(ui, avatar_size_class(size))
	p.apply(ui, class)

	if ringed {
		p.div(ui, RING_2)
		p.end(ui)
	}
	// The `after:` hairline, then the fallback's own `bg-muted` on top of it.
	p.div(ui, "absolute inset-0 rounded-full bg-border")
	p.end(ui)
	p.div(ui, "absolute top-px right-px bottom-px left-px rounded-full bg-muted")
	p.end(ui)
	return idx
}

// avatar_fallback is the initials span: `flex size-full items-center
// justify-center rounded-full bg-muted text-sm text-muted-foreground`.
avatar_fallback :: proc(ui: ^p.Ctx, initials: string, size := Avatar_Size.Default) {
	p.text(ui, initials, "text-muted-foreground whitespace-nowrap")
	p.apply(ui, avatar_text_class(size))
	p.style(ui).shrink = 0
}

avatar_end :: proc(ui: ^p.Ctx) {
	p.end(ui)
}

avatar :: proc(ui: ^p.Ctx, initials: string, size := Avatar_Size.Default, ringed := false, class := "") {
	avatar_open(ui, size, ringed, class)
	avatar_fallback(ui, initials, size)
	avatar_end(ui)
}

// avatar_badge is `absolute right-0 bottom-0 z-10 size-2.5 rounded-full
// bg-primary ring-2 ring-background`.
avatar_badge :: proc(ui: ^p.Ctx, size := Avatar_Size.Default) {
	p.div(ui, "absolute right-0 bottom-0 z-10")
	switch size {
	case .SM:
		p.apply(ui, "size-2")
	case .Default:
		p.apply(ui, "size-2.5")
	case .LG:
		p.apply(ui, "size-3")
	}
	p.div(ui, RING_2)
	p.end(ui)
	p.div(ui, "absolute inset-0 rounded-full bg-primary")
	p.end(ui)
	p.end(ui)
}

avatar_group_open :: proc(ui: ^p.Ctx, class := "") -> int {
	idx := p.div(ui, "flex-row")
	p.apply(ui, class)
	return idx
}

avatar_group_end :: proc(ui: ^p.Ctx) {
	p.end(ui)
}

// avatar_group_count is the trailing "+3" chip: an avatar-shaped box with the
// white ring but without the `after:` hairline.
avatar_group_count :: proc(ui: ^p.Ctx, label: string, class := "") {
	p.div(ui, "relative flex-row shrink-0 items-center justify-center size-8 text-sm")
	p.apply(ui, class)
	defer p.end(ui)

	p.div(ui, RING_2)
	p.end(ui)
	p.div(ui, "absolute inset-0 rounded-full bg-muted")
	p.end(ui)

	p.text(ui, label, "text-muted-foreground whitespace-nowrap")
	p.style(ui).shrink = 0
}
