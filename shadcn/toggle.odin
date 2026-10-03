package shadcn

// Toggle and ToggleGroup, from app/components/ui/toggle.tsx and
// toggle-group.tsx.
//
// The default variant has no border at all (36x32 for a 16px icon with
// px-2.5); only `outline` adds one, which is why toggle-outline is 38 wide.
// `spacing={0}` joins the items: rounded-none px-2, the outer corners rounded
// back on, and every item but the first loses its leading border.

import p "palmy:."

Toggle_Variant :: enum {
	Default,
	Outline,
}

Toggle_Size :: enum {
	Default,
	SM,
	LG,
}

TOGGLE_BASE ::
	"flex-row shrink-0 items-center justify-center gap-1 rounded-lg text-sm " +
	"font-medium whitespace-nowrap outline-none"

toggle_size_class :: proc(s: Toggle_Size) -> string {
	switch s {
	case .Default:
		return "h-8 min-w-8 px-2.5"
	case .SM:
		return "h-7 min-w-7 rounded-md px-2.5 text-[12.8] leading-[19.2]"
	case .LG:
		return "h-9 min-w-9 px-2.5"
	}
	return ""
}

// Joined is how a toggle-group item with spacing 0 differs from a loose one.
Joined :: enum {
	No,
	First,
	Middle,
	Last,
	Only,
}

toggle_open :: proc(
	ui: ^p.Ctx,
	pressed: bool,
	v := Toggle_Variant.Default,
	s := Toggle_Size.Default,
	st := State{},
	join := Joined.No,
	vertical := false,
) -> int {
	idx := p.div(ui, TOGGLE_BASE)
	p.apply(ui, toggle_size_class(s))
	if v == .Outline {
		p.apply(ui, "border border-input")
	}
	if pressed {
		p.apply(ui, "bg-muted")
	}
	if join != .No {
		p.apply(ui, "rounded-none px-2")
		sm := s == .SM
		first := join == .First || join == .Only
		last := join == .Last || join == .Only
		if vertical {
			if v == .Outline && !first {
				p.apply(ui, "border-t-0")
			}
			if first {
				p.apply(ui, sm ? "rounded-t-md" : "rounded-t-lg")
			}
			if last {
				p.apply(ui, sm ? "rounded-b-md" : "rounded-b-lg")
			}
		} else {
			if v == .Outline && !first {
				p.apply(ui, "border-l-0")
			}
			if first {
				p.apply(ui, sm ? "rounded-l-md" : "rounded-l-lg")
			}
			if last {
				p.apply(ui, sm ? "rounded-r-md" : "rounded-r-lg")
			}
		}
	}
	if st.focus {
		p.apply(ui, "border-ring ring-3 ring-ring/50")
	}
	if st.disabled {
		p.apply(ui, "opacity-50")
	}
	return idx
}

toggle_end :: proc(ui: ^p.Ctx) {
	p.end(ui)
}

// toggle is the text-label case.
toggle :: proc(
	ui: ^p.Ctx,
	text: string,
	pressed := false,
	v := Toggle_Variant.Default,
	s := Toggle_Size.Default,
	st := State{},
) {
	toggle_open(ui, pressed, v, s, st)
	p.text(ui, text, "whitespace-nowrap")
	p.style(ui).shrink = 0
	toggle_end(ui)
}

// toggle_group_open is the `gap-[--spacing(spacing)]` wrapper; spacing 2 is the
// default and resolves to 8px.
toggle_group_open :: proc(ui: ^p.Ctx, spacing := 2, vertical := false) -> int {
	idx := p.div(ui, "flex-row items-center rounded-lg")
	if vertical {
		p.apply(ui, "flex-col items-stretch")
	}
	p.style(ui).gap = {f32(spacing) * 4, f32(spacing) * 4}
	return idx
}

toggle_group_end :: proc(ui: ^p.Ctx) {
	p.end(ui)
}
