package shadcn

// Badge, from app/components/ui/badge.tsx.

import p "palmy:."

// Icon_Ref keeps the signature readable; palmy icons are plain values.
Icon_Ref :: p.Icon

BADGE_BASE ::
	"inline-flex flex-row h-5 w-fit shrink-0 items-center justify-center gap-1 overflow-hidden " +
	"rounded-4xl border border-transparent px-2 py-0.5 text-xs font-medium whitespace-nowrap"

badge_variant_class :: proc(v: Variant) -> string {
	switch v {
	case .Default:
		return "bg-primary text-primary-foreground"
	case .Secondary:
		return "bg-secondary text-secondary-foreground"
	case .Destructive:
		return "bg-destructive/10 text-destructive"
	case .Outline:
		return "border-border text-foreground"
	case .Ghost:
		return "text-foreground"
	case .Link:
		return "text-primary"
	}
	return ""
}

badge :: proc(ui: ^p.Ctx, label: string, v := Variant.Default) {
	p.div(ui, BADGE_BASE)
	p.apply(ui, badge_variant_class(v))
	defer p.end(ui)

	p.text(ui, label, "whitespace-nowrap")
	p.style(ui).shrink = 0
}

// badge_icon is a badge with a leading icon, which shadcn sizes at 12px and
// pads asymmetrically (`has-data-[icon=inline-start]:pl-1.5`).
badge_icon :: proc(ui: ^p.Ctx, label: string, ic: Icon_Ref, v := Variant.Default) {
	p.div(ui, BADGE_BASE)
	p.apply(ui, badge_variant_class(v))
	p.apply(ui, "pl-1.5")
	defer p.end(ui)

	p.icon(ui, ic, "size-3 shrink-0")
	p.text(ui, label, "whitespace-nowrap")
	p.style(ui).shrink = 0
}
