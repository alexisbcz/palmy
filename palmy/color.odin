package palmy

import "core:strconv"
import "core:strings"

// A color in non-premultiplied sRGB with 8 bits per channel.
Color :: struct {
	r, g, b, a: u8,
}

TRANSPARENT :: Color{0, 0, 0, 0}
WHITE       :: Color{255, 255, 255, 255}
BLACK       :: Color{0, 0, 0, 255}

// CURRENT is what `current` resolves to before an element knows its own text
// colour -- CSS's `currentColor`. It is a stand-in, not a colour: the node
// builder swaps it for the inherited text colour as each element is built, so
// it never reaches the canvas. Its alpha is zero, so if one ever did escape it
// would draw nothing rather than draw something wrong.
//
// `current/50` is this with half in the green channel; `is_current` reads the
// marker and `current_over` does the substitution.
CURRENT :: Color{1, 255, 1, 0}

// is_current reports whether a colour is the `currentColor` stand-in.
is_current :: proc "contextless" (c: Color) -> bool {
	return c.a == 0 && c.r == CURRENT.r && c.b == CURRENT.b
}

// current_over resolves the stand-in against the text colour it stands for,
// keeping whatever opacity the token asked for.
current_over :: proc "contextless" (c, fg: Color) -> Color {
	if !is_current(c) {
		return c
	}
	return fade(fg, f32(c.g) / 255)
}

// hex takes 0xRRGGBB and returns an opaque color.
hex :: proc "contextless" (v: u32) -> Color {
	return {u8(v >> 16), u8(v >> 8), u8(v), 255}
}

// hexa takes 0xRRGGBBAA -- alpha is the LOW byte, not the high one. A canvas
// word is 0xAARRGGBB, so the two orders differ and reading one as the other is
// silent: 0x08ffffff meant as 3% white comes back as opaque cyan.
hexa :: proc "contextless" (v: u32) -> Color {
	return {u8(v >> 24), u8(v >> 16), u8(v >> 8), u8(v)}
}

rgba :: proc "contextless" (r, g, b: u8, a: u8 = 255) -> Color {
	return {r, g, b, a}
}

// fade scales a color's alpha by `f` (0..1).
fade :: proc "contextless" (c: Color, f: f32) -> Color {
	out := c
	out.a = u8(clamp(f32(c.a) * f, 0, 255))
	return out
}

// mix linearly interpolates between two colors, including their alpha.
mix :: proc "contextless" (a, b: Color, t: f32) -> Color {
	k := clamp(t, 0, 1)
	l :: proc "contextless" (x, y: u8, t: f32) -> u8 {
		return u8(f32(x) + (f32(y) - f32(x)) * t + 0.5)
	}
	return {l(a.r, b.r, k), l(a.g, b.g, k), l(a.b, b.b, k), l(a.a, b.a, k)}
}

// luminance is the perceptual brightness of a color, 0..1. Handy for deciding
// whether text on top of it should be light or dark.
luminance :: proc "contextless" (c: Color) -> f32 {
	return (0.2126 * f32(c.r) + 0.7152 * f32(c.g) + 0.0722 * f32(c.b)) / 255
}

@(private)
hue_index :: proc(name: string) -> int {
	for h, i in HUES {
		if h.name == name {
			return i
		}
	}
	return -1
}

@(private)
shade_index :: proc(n: int) -> int {
	shades := SHADES
	for s, i in shades {
		if s == n {
			return i
		}
	}
	return -1
}

// parse_color resolves a Tailwind-style color token.
//
//	white            black            transparent
//	slate-900        indigo-400       rose-500/60
//	[#1e293b]        [#1e293b80]      [0f172a]
//
// A `/NN` suffix sets the alpha as a percentage, matching Tailwind's opacity modifier.
parse_color :: proc(token: string) -> (color: Color, ok: bool) {
	body := token
	alpha := f32(1)

	if slash := strings.last_index_byte(body, '/'); slash >= 0 {
		pct, pok := strconv.parse_int(body[slash + 1:])
		if !pok {
			return {}, false
		}
		alpha = clamp(f32(pct) / 100, 0, 1)
		body = body[:slash]
	}

	// A project token wins over the built-in palette.
	if tc, found := theme_color(body); found {
		color = tc
		if alpha < 1 {
			color = fade(color, alpha)
		}
		return color, true
	}

	switch body {
	case "transparent":
		return TRANSPARENT, true
	case "white":
		color = WHITE
	case "black":
		color = BLACK
	case "current":
		// `currentColor`: the element's own text colour, which is not known
		// here. `push_node` substitutes it once the element's classes have all
		// been applied, so `border-current` on a chip follows the button it
		// sits in instead of being restated per variant.
		out := CURRENT
		out.g = u8(clamp(alpha * 255, 0, 255))
		return out, true
	case "inherit":
		// `inherit` is per-property -- `bg-inherit` is the parent's
		// background, not its text colour -- and nothing here tracks that, so
		// it stays unhandled rather than quietly meaning something else.
		return {}, false
	case:
		if len(body) >= 2 && body[0] == '[' && body[len(body) - 1] == ']' {
			// Arbitrary value: [#rrggbb], [#rrggbbaa] or the same without the '#'.
			raw := body[1:len(body) - 1]
			raw = strings.trim_prefix(raw, "#")
			v, vok := strconv.parse_u64_of_base(raw, 16)
			if !vok {
				return {}, false
			}
			switch len(raw) {
			case 6:
				color = hex(u32(v))
			case 8:
				color = hexa(u32(v))
			case 3:
				// #abc -> #aabbcc
				r := u8((v >> 8) & 0xf)
				g := u8((v >> 4) & 0xf)
				b := u8(v & 0xf)
				color = {r * 17, g * 17, b * 17, 255}
			case:
				return {}, false
			}
		} else {
			dash := strings.last_index_byte(body, '-')
			if dash < 0 {
				return {}, false
			}
			hi := hue_index(body[:dash])
			if hi < 0 {
				return {}, false
			}
			n, nok := strconv.parse_int(body[dash + 1:])
			if !nok {
				return {}, false
			}
			si := shade_index(n)
			if si < 0 {
				return {}, false
			}
			color = hex(HUES[hi].shades[si])
		}
	}

	if alpha < 1 {
		color = fade(color, alpha)
	}
	return color, true
}
