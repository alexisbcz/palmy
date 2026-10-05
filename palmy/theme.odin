package palmy

import "core:strings"

// ---------------------------------------------------------------------------
// Design tokens.
//
// Tailwind lets a project rename the scales with `@theme`, and real design
// systems always do: shadcn writes `bg-primary` and `rounded-lg`, where
// `primary` is a project colour and `lg` is a project radius rather than
// Tailwind's default 8px. Registering tokens here lets class strings be written
// exactly as the design system writes them.
//
//	palmy.register_color("primary", palmy.hex(0x171717))
//	palmy.register_radius("lg", 10)
//	palmy.div(ui, "bg-primary rounded-lg")
// ---------------------------------------------------------------------------

@(private)
Theme :: struct {
	colors: map[string]Color,
	radii:  map[string]f32,
	sizes:  map[string][2]f32, // font size, line height multiple
	init:   bool,
}

@(private)
theme: Theme

@(private)
theme_ensure :: proc() {
	if theme.init {
		return
	}
	theme.colors = make(map[string]Color)
	theme.radii = make(map[string]f32)
	theme.sizes = make(map[string][2]f32)
	theme.init = true
}

// register_color adds a named colour usable anywhere a colour is accepted:
// `bg-<name>`, `text-<name>`, `border-<name>`, `ring-<name>`, and with an
// opacity suffix such as `bg-<name>/50`.
register_color :: proc(name: string, c: Color) {
	theme_ensure()
	key, found := find_key(theme.colors, name)
	if !found {
		key = strings.clone(name)
	}
	theme.colors[key] = c
}

// register_radius overrides one step of the radius scale. Use "" for the bare
// `rounded` utility.
register_radius :: proc(name: string, px: f32) {
	theme_ensure()
	key, found := find_key(theme.radii, name)
	if !found {
		key = strings.clone(name)
	}
	theme.radii[key] = px
}

// register_text overrides one step of the font size scale, as `text-<name>`.
// `leading` is a multiple of the font size.
//
// Registered tokens live for the life of the process, like a Tailwind config.
// `reset_theme` frees them, but nothing else does.
register_text :: proc(name: string, size, leading: f32) {
	theme_ensure()
	key, found := find_key(theme.sizes, name)
	if !found {
		key = strings.clone(name)
	}
	theme.sizes[key] = {size, leading}
}

// reset_theme drops every registered token.
reset_theme :: proc() {
	if !theme.init {
		return
	}
	for k in theme.colors {
		delete(k)
	}
	for k in theme.radii {
		delete(k)
	}
	for k in theme.sizes {
		delete(k)
	}
	clear(&theme.colors)
	clear(&theme.radii)
	clear(&theme.sizes)
}

@(private)
find_key :: proc(m: $T/map[string]$V, name: string) -> (string, bool) {
	for k in m {
		if k == name {
			return k, true
		}
	}
	return "", false
}

// theme_color reads back a colour registered with `register_color`, and
// reports whether there was one. It is the route for an application that has
// to paint something itself -- a chart series, a canvas, a `pixels` widget --
// in the same colours its class strings use.
//
//	if c, ok := palmy.theme_color("primary"); ok {
//		palmy.fill_rect(canvas, bar, c)
//	}
//
// `parse_color` resolves the whole token language, including the palette and
// `/50` opacity, and looks here first; this is only the registered tokens.
theme_color :: proc(name: string) -> (Color, bool) {
	if !theme.init {
		return {}, false
	}
	c, found := theme.colors[name]
	return c, found
}

// theme_radius reads back a radius registered with `register_radius`, for the
// same reason as `theme_color`: a widget drawing its own rounded box should
// round it by the project's `lg`, not by a number copied into the app.
theme_radius :: proc(name: string) -> (f32, bool) {
	if !theme.init {
		return 0, false
	}
	r, found := theme.radii[name]
	return r, found
}

// theme_text reads back a font size registered with `register_text`.
theme_text :: proc(name: string) -> (size, leading: f32, ok: bool) {
	if !theme.init {
		return 0, 0, false
	}
	v, found := theme.sizes[name]
	return v[0], v[1], found
}
