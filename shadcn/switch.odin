package shadcn

// Switch, from app/components/ui/switch.tsx.
//
// The track is a hard-coded `h-[18.4px] w-[32px]` (or 14x24 for `sm`) with a
// transparent 1px border, so the thumb sits inside a 30x16.4 content box.
// The TSX moves the thumb with `translate-x-[calc(100%-2px)]`, which lands it
// flush against the content box's right edge — `justify-end` does the same
// thing without needing transforms.

import p "palmy:."

Switch_Size :: enum {
	Default,
	SM,
}

SWITCH_BASE :: "relative flex-row shrink-0 items-center rounded-full border border-transparent"

switch_ :: proc(ui: ^p.Ctx, on: bool, size := Switch_Size.Default, st := State{}) {
	p.div(ui, SWITCH_BASE)
	switch size {
	case .Default:
		p.apply(ui, "h-[18.4] w-[32]")
	case .SM:
		p.apply(ui, "h-[14] w-[24]")
	}
	p.apply(ui, on ? "bg-primary" : "bg-input")
	if on {
		p.apply(ui, "justify-end")
	}
	if st.focus {
		p.apply(ui, "border-ring ring-3 ring-ring/50")
	}
	if st.disabled {
		p.apply(ui, "opacity-50")
	}
	defer p.end(ui)

	p.div(ui, size == .SM ? "size-3 rounded-full bg-background" : "size-4 rounded-full bg-background")
	p.style(ui).shrink = 0
	// CSS `opacity` composites the whole switch as one group, so the thumb
	// stays pure white over a faded track. palmy inherits opacity per node and
	// would blend the thumb into the track underneath it, so put it back.
	p.style(ui).opacity = 1
	p.end(ui)
}
