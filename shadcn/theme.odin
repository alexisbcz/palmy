package shadcn

// The shadcn `base-nova` theme with the neutral base colour, registered as
// palmy design tokens so component code can use the same class names the TSX
// uses: `bg-primary`, `text-muted-foreground`, `rounded-lg`.
//
// Values are the oklch variables from app/app.css converted to sRGB. They are
// checked against the browser's own computed styles by tools/check-theme.mjs.

import p "palmy:."

// register_shadcn_theme registers the token palette. Pass `dark = true` for a
// login screen, a launcher floating over the desktop, or anything else that has
// to read on a dark background — the values are shadcn's own `.dark` block,
// converted from oklch the same way the light ones were.
register_shadcn_theme :: proc(dark := false) {
	c :: p.hex

	if dark {
		register_shadcn_dark()
		register_shared_radii()
		return
	}

	p.register_color("background", c(0xffffff))
	p.register_color("foreground", c(0x0a0a0a))
	p.register_color("card", c(0xffffff))
	p.register_color("card-foreground", c(0x0a0a0a))
	p.register_color("popover", c(0xffffff))
	p.register_color("popover-foreground", c(0x0a0a0a))
	p.register_color("primary", c(0x171717))
	p.register_color("primary-foreground", c(0xfafafa))
	p.register_color("secondary", c(0xf5f5f5))
	p.register_color("secondary-foreground", c(0x171717))
	p.register_color("muted", c(0xf5f5f5))
	p.register_color("muted-foreground", c(0x737373))
	p.register_color("accent", c(0xf5f5f5))
	p.register_color("accent-foreground", c(0x171717))
	p.register_color("destructive", c(0xe7000b))
	p.register_color("destructive-foreground", c(0xfafafa))
	p.register_color("border", c(0xe5e5e5))
	p.register_color("input", c(0xe5e5e5))
	p.register_color("ring", c(0xa1a1a1))
	p.register_color("sidebar", c(0xfafafa))
	p.register_color("sidebar-foreground", c(0x0a0a0a))
	p.register_color("sidebar-border", c(0xe5e5e5))
	p.register_color("sidebar-accent", c(0xf5f5f5))
	p.register_color("sidebar-accent-foreground", c(0x171717))
	p.register_color("chart-1", c(0xd4d4d4))
	p.register_color("chart-2", c(0x737373))
	p.register_color("chart-3", c(0x545454))
	p.register_color("chart-4", c(0x454545))
	p.register_color("chart-5", c(0x2c2c2c))

	register_shared_radii()
}

// register_shared_radii is the same scale in both themes: --radius is
// 0.625rem and every step is a multiple of it.
@(private)
register_shared_radii :: proc() {
	RADIUS :: f32(10)
	p.register_radius("sm", RADIUS * 0.6)
	p.register_radius("md", RADIUS * 0.8)
	p.register_radius("lg", RADIUS)
	p.register_radius("xl", RADIUS * 1.4)
	p.register_radius("2xl", RADIUS * 1.8)
	p.register_radius("3xl", RADIUS * 2.2)
	p.register_radius("4xl", RADIUS * 2.6)
}

@(private)
register_shadcn_dark :: proc() {
	c :: p.hex

	p.register_color("background", c(0x0a0a0a))
	p.register_color("foreground", c(0xfafafa))
	p.register_color("card", c(0x171717))
	p.register_color("card-foreground", c(0xfafafa))
	p.register_color("popover", c(0x171717))
	p.register_color("popover-foreground", c(0xfafafa))
	p.register_color("primary", c(0xe5e5e5))
	p.register_color("primary-foreground", c(0x171717))
	p.register_color("secondary", c(0x262626))
	p.register_color("secondary-foreground", c(0xfafafa))
	p.register_color("muted", c(0x262626))
	p.register_color("muted-foreground", c(0xa1a1a1))
	p.register_color("accent", c(0x262626))
	p.register_color("accent-foreground", c(0xfafafa))
	p.register_color("destructive", c(0xff6467))
	p.register_color("destructive-foreground", c(0xfafafa))
	p.register_color("ring", c(0x737373))
	p.register_color("sidebar", c(0x171717))
	p.register_color("sidebar-foreground", c(0xfafafa))
	p.register_color("sidebar-accent", c(0x262626))
	p.register_color("sidebar-accent-foreground", c(0xfafafa))

	// In the dark theme shadcn makes the border and input hairlines white at
	// low alpha rather than a flat grey, so they lift off whatever is behind.
	p.register_color("border", p.Color{255, 255, 255, 26})  // white / 10%
	p.register_color("input", p.Color{255, 255, 255, 38})   // white / 15%
	p.register_color("sidebar-border", p.Color{255, 255, 255, 26})

	p.register_color("chart-1", c(0xd4d4d4))
	p.register_color("chart-2", c(0x8e8e8e))
	p.register_color("chart-3", c(0x707070))
	p.register_color("chart-4", c(0x5e5e5e))
	p.register_color("chart-5", c(0x434343))
}
