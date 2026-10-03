package shadcn

// Button, translated from app/components/ui/button.tsx.
//
// The class strings below are the same utilities the TSX applies, in the same
// order, so the two can be diffed by eye as well as by pixels.

import p "palmy:."

Variant :: enum {
	Default,
	Outline,
	Secondary,
	Ghost,
	Destructive,
	Link,
}

Size :: enum {
	Default,
	XS,
	SM,
	LG,
	Icon,
	Icon_XS,
	Icon_SM,
	Icon_LG,
}

// State mirrors the pseudo-classes a case can ask for.
State :: struct {
	hover:    bool,
	focus:    bool,
	disabled: bool,
	invalid:  bool, // aria-invalid
}

BUTTON_BASE ::
	"inline-flex flex-row shrink-0 items-center justify-center rounded-lg border border-transparent bg-clip-padding " +
	"text-sm font-medium whitespace-nowrap transition-all outline-none select-none cursor-pointer"

button_variant_class :: proc(v: Variant, st: State) -> string {
	switch v {
	case .Default:
		return st.hover ? "bg-primary/80 text-primary-foreground" : "bg-primary text-primary-foreground"
	case .Outline:
		if st.hover {
			return "border-border bg-muted text-foreground"
		}
		return "border-border bg-background text-foreground"
	case .Secondary:
		// hover is color-mix(secondary, foreground 5%) = #e9e9e9.
		return st.hover ? "bg-[#e9e9e9] text-secondary-foreground" : "bg-secondary text-secondary-foreground"
	case .Ghost:
		return st.hover ? "bg-muted text-foreground" : "text-foreground"
	case .Destructive:
		return st.hover ? "bg-destructive/20 text-destructive" : "bg-destructive/10 text-destructive"
	case .Link:
		return st.hover ? "text-primary underline" : "text-primary"
	}
	return ""
}

button_size_class :: proc(s: Size) -> string {
	switch s {
	case .Default:
		return "h-8 gap-1.5 px-2.5"
	case .XS:
		return "h-6 gap-1 rounded-md px-2 text-xs"
	case .SM:
		return "h-7 gap-1 rounded-md px-2.5 text-[12.8] leading-[19.2]"
	case .LG:
		return "h-9 gap-1.5 px-2.5"
	case .Icon:
		return "size-8"
	case .Icon_XS:
		return "size-6 rounded-md"
	case .Icon_SM:
		return "size-7 rounded-md"
	case .Icon_LG:
		return "size-9"
	}
	return ""
}

// button opens a button and leaves it open, so a caller can place an icon
// or label inside; `button_end` closes it.
button_open :: proc(ui: ^p.Ctx, v: Variant, s: Size, st: State) -> int {
	idx := p.div(ui, BUTTON_BASE)
	p.apply(ui, button_variant_class(v, st))
	p.apply(ui, button_size_class(s))
	if st.focus {
		p.apply(ui, "border-ring ring-3 ring-ring/50")
	}
	if st.disabled {
		p.apply(ui, "opacity-50")
	}
	return idx
}

button_end :: proc(ui: ^p.Ctx) {
	p.end(ui)
}

// button is the common case: a button with a text label.
button :: proc(ui: ^p.Ctx, label: string, v := Variant.Default, s := Size.Default, st := State{}) {
	button_open(ui, v, s, st)
	if label != "" {
		p.text(ui, label, "whitespace-nowrap")
		p.style(ui).shrink = 0
	}
	button_end(ui)
}
