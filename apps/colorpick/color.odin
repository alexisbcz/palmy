package main

// Colour spaces.
//
// Everything here is plain maths on f32 triples. The canonical value an editor
// holds is non-linear sRGB in 0..1; every other space is derived from it and
// can be edited in place, which is what "live conversion between formats"
// actually requires.
//
// The OKLab matrices are Björn Ottosson's, verbatim. They are worth stating
// rather than hiding behind a library, because the whole point of OKLCH is that
// a lightness step looks like a lightness step — and that only holds if the
// cube roots and the transfer function are both right.
//
// `selftest()` at the bottom checks the round trips and a set of published
// reference values. `colorpick --selftest` runs it without opening a window.

import "core:fmt"
import "core:math"
import "core:strconv"
import "core:strings"

// ---------------------------------------------------------------------------
// sRGB transfer function
// ---------------------------------------------------------------------------

// srgb_to_linear undoes the sRGB electro-optical transfer function. The linear
// segment near black is not a rounding of the power curve; it is part of the
// standard, and dropping it visibly shifts dark colours.
srgb_to_linear :: proc(c: f32) -> f32 {
	if c <= 0.04045 {
		return c / 12.92
	}
	return math.pow((c + 0.055) / 1.055, 2.4)
}

linear_to_srgb :: proc(c: f32) -> f32 {
	if c <= 0.0031308 {
		return c * 12.92
	}
	return 1.055 * math.pow(c, 1.0 / 2.4) - 0.055
}

// ---------------------------------------------------------------------------
// OKLab / OKLCH
// ---------------------------------------------------------------------------

// linear_to_oklab: linear sRGB -> OKLab. The first matrix lands in a cone-like
// LMS space, the cube root makes it perceptually uniform, the second matrix
// rotates it into opponent axes.
linear_to_oklab :: proc(rgb: [3]f32) -> [3]f32 {
	r, g, b := rgb[0], rgb[1], rgb[2]

	l := 0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b
	m := 0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b
	s := 0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b

	l_ := cbrt(l)
	m_ := cbrt(m)
	s_ := cbrt(s)

	return {
		0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_,
		1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_,
		0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_,
	}
}

oklab_to_linear :: proc(lab: [3]f32) -> [3]f32 {
	L, a, b := lab[0], lab[1], lab[2]

	l_ := L + 0.3963377774 * a + 0.2158037573 * b
	m_ := L - 0.1055613458 * a - 0.0638541728 * b
	s_ := L - 0.0894841775 * a - 1.2914855480 * b

	l := l_ * l_ * l_
	m := m_ * m_ * m_
	s := s_ * s_ * s_

	return {
		+4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
		-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
		-0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s,
	}
}

// cbrt has to keep the sign: the LMS values are non-negative for in-gamut
// colours, but an out-of-gamut OKLCH round trip produces negatives and
// `pow(x, 1/3)` on a negative is NaN.
cbrt :: proc(x: f32) -> f32 {
	if x < 0 {
		return -math.pow(-x, 1.0 / 3.0)
	}
	return math.pow(x, 1.0 / 3.0)
}

// srgb_to_oklch returns L in 0..1, C in 0..~0.4 and H in degrees 0..360.
srgb_to_oklch :: proc(rgb: [3]f32) -> [3]f32 {
	lin := [3]f32 {
		srgb_to_linear(rgb[0]),
		srgb_to_linear(rgb[1]),
		srgb_to_linear(rgb[2]),
	}
	lab := linear_to_oklab(lin)
	c := math.sqrt(lab[1] * lab[1] + lab[2] * lab[2])
	h := math.to_degrees(math.atan2(lab[2], lab[1]))
	if h < 0 {
		h += 360
	}
	// A neutral has no hue; reporting the arctangent of two rounding errors as
	// a hue makes the readout jitter for every shade of grey.
	if c < 1e-6 {
		h = 0
	}
	return {lab[0], c, h}
}

// oklch_to_srgb converts back. `in_gamut` is false when the result had to be
// clipped, which is the honest answer for most of the OKLCH volume: the sRGB
// cube is a small, lumpy subset of it.
oklch_to_srgb :: proc(lch: [3]f32) -> (rgb: [3]f32, in_gamut: bool) {
	rad := math.to_radians(lch[2])
	lab := [3]f32{lch[0], lch[1] * math.cos(rad), lch[1] * math.sin(rad)}
	lin := oklab_to_linear(lab)

	in_gamut = true
	for i in 0 ..< 3 {
		v := linear_to_srgb(lin[i])
		if v < -0.0005 || v > 1.0005 {
			in_gamut = false
		}
		rgb[i] = clamp(v, 0, 1)
	}
	return
}

// ---------------------------------------------------------------------------
// HSL
// ---------------------------------------------------------------------------

// srgb_to_hsl returns H in degrees, S and L in 0..1.
srgb_to_hsl :: proc(rgb: [3]f32) -> [3]f32 {
	r, g, b := rgb[0], rgb[1], rgb[2]
	mx := max(r, g, b)
	mn := min(r, g, b)
	l := (mx + mn) * 0.5
	d := mx - mn
	if d < 1e-7 {
		return {0, 0, l}
	}
	s := l > 0.5 ? d / (2 - mx - mn) : d / (mx + mn)
	h: f32
	switch mx {
	case r:
		h = (g - b) / d + (g < b ? 6 : 0)
	case g:
		h = (b - r) / d + 2
	case:
		h = (r - g) / d + 4
	}
	return {h * 60, s, l}
}

hsl_to_srgb :: proc(hsl: [3]f32) -> [3]f32 {
	h := math.mod_f32(math.mod_f32(hsl[0], 360) + 360, 360) / 360
	s := clamp(hsl[1], 0, 1)
	l := clamp(hsl[2], 0, 1)
	if s < 1e-7 {
		return {l, l, l}
	}
	q := l < 0.5 ? l * (1 + s) : l + s - l * s
	p := 2 * l - q
	return {hue_channel(p, q, h + 1.0 / 3.0), hue_channel(p, q, h), hue_channel(p, q, h - 1.0 / 3.0)}
}

@(private = "file")
hue_channel :: proc(p, q, t_in: f32) -> f32 {
	t := t_in
	if t < 0 {t += 1}
	if t > 1 {t -= 1}
	switch {
	case t < 1.0 / 6.0:
		return p + (q - p) * 6 * t
	case t < 1.0 / 2.0:
		return q
	case t < 2.0 / 3.0:
		return p + (q - p) * (2.0 / 3.0 - t) * 6
	}
	return p
}

// ---------------------------------------------------------------------------
// WCAG contrast
// ---------------------------------------------------------------------------

// relative_luminance is WCAG 2.1's definition: the ITU-R BT.709 luma
// coefficients applied to linearised channels.
relative_luminance :: proc(rgb: [3]f32) -> f32 {
	return 0.2126 * srgb_to_linear(rgb[0]) +
		0.7152 * srgb_to_linear(rgb[1]) +
		0.0722 * srgb_to_linear(rgb[2])
}

contrast_ratio :: proc(a, b: [3]f32) -> f32 {
	la := relative_luminance(a)
	lb := relative_luminance(b)
	hi := max(la, lb)
	lo := min(la, lb)
	return (hi + 0.05) / (lo + 0.05)
}

// WCAG thresholds: 4.5 for body text, 3 for large text or UI components, 7 for
// AAA body text.
wcag_grade :: proc(ratio: f32, large: bool) -> string {
	if large {
		if ratio >= 4.5 {return "AAA"}
		if ratio >= 3.0 {return "AA"}
		return "fail"
	}
	if ratio >= 7.0 {return "AAA"}
	if ratio >= 4.5 {return "AA"}
	return "fail"
}

// ---------------------------------------------------------------------------
// Bytes, hex and formatting
// ---------------------------------------------------------------------------

to_bytes :: proc(rgb: [3]f32) -> [3]u8 {
	return {
		u8(clamp(rgb[0], 0, 1) * 255 + 0.5),
		u8(clamp(rgb[1], 0, 1) * 255 + 0.5),
		u8(clamp(rgb[2], 0, 1) * 255 + 0.5),
	}
}

from_bytes :: proc(b: [3]u8) -> [3]f32 {
	return {f32(b[0]) / 255, f32(b[1]) / 255, f32(b[2]) / 255}
}

fmt_hex :: proc(rgb: [3]f32, al := context.temp_allocator) -> string {
	b := to_bytes(rgb)
	return fmt.aprintf("#%02x%02x%02x", b[0], b[1], b[2], allocator = al)
}

fmt_rgb :: proc(rgb: [3]f32, al := context.temp_allocator) -> string {
	b := to_bytes(rgb)
	return fmt.aprintf("rgb(%d, %d, %d)", b[0], b[1], b[2], allocator = al)
}

fmt_hsl :: proc(rgb: [3]f32, al := context.temp_allocator) -> string {
	h := srgb_to_hsl(rgb)
	return fmt.aprintf(
		"hsl(%.1f, %.1f%%, %.1f%%)",
		round1(h[0]),
		round1(h[1] * 100),
		round1(h[2] * 100),
		allocator = al,
	)
}

fmt_oklch :: proc(rgb: [3]f32, al := context.temp_allocator) -> string {
	o := srgb_to_oklch(rgb)
	return fmt.aprintf(
		"oklch(%.4f %.4f %.2f)",
		o[0],
		o[1],
		o[2],
		allocator = al,
	)
}

// fmt_css_vars is what someone actually pastes into a stylesheet.
fmt_css_var :: proc(rgb: [3]f32, al := context.temp_allocator) -> string {
	return fmt.aprintf("--color: %s;", fmt_oklch(rgb, context.temp_allocator), allocator = al)
}

round1 :: proc(v: f32) -> f32 {
	return math.round(v * 10) / 10
}

// parse_hex accepts #rgb, #rrggbb, with or without the hash, and tolerates
// whitespace — pasting from anywhere should work.
parse_hex :: proc(s_in: string) -> (rgb: [3]f32, ok: bool) {
	s := strings.trim_space(s_in)
	s = strings.trim_prefix(s, "#")
	if len(s) == 3 {
		out: [3]f32
		for i in 0 ..< 3 {
			v, good := hex_digit(s[i])
			if !good {
				return {}, false
			}
			out[i] = f32(v * 17) / 255
		}
		return out, true
	}
	if len(s) == 6 {
		out: [3]f32
		for i in 0 ..< 3 {
			hi, ok1 := hex_digit(s[i * 2])
			lo, ok2 := hex_digit(s[i * 2 + 1])
			if !ok1 || !ok2 {
				return {}, false
			}
			out[i] = f32(hi * 16 + lo) / 255
		}
		return out, true
	}
	return {}, false
}

@(private = "file")
hex_digit :: proc(c: u8) -> (int, bool) {
	switch c {
	case '0' ..= '9':
		return int(c - '0'), true
	case 'a' ..= 'f':
		return int(c - 'a' + 10), true
	case 'A' ..= 'F':
		return int(c - 'A' + 10), true
	}
	return 0, false
}

parse_number :: proc(s: string) -> (f32, bool) {
	t := strings.trim_space(s)
	t = strings.trim_suffix(t, "%")
	t = strings.trim_space(t)
	if t == "" {
		return 0, false
	}
	v, ok := strconv.parse_f64(t)
	return f32(v), ok
}

// parse_color reads any notation the editor writes: hex (#rgb, #rrggbb, with or
// without the hash), rgb()/rgba(), hsl()/hsla() and oklch(). Commas, spaces
// and a CSS "/ alpha" tail are all accepted, and the alpha is ignored — the
// editor has no alpha channel. It is what the window's Ctrl+V and every CLI
// command that takes a colour go through, so the two cannot disagree on what
// a colour is. `notation` says which form was read; `in_gamut` is false only
// for an oklch() outside sRGB, whose rgb is then the clipped colour.
Parsed_Color :: struct {
	rgb:      [3]f32, // sRGB 0..1, clipped
	lch:      [3]f32, // the OKLCH as written, for an oklch() (else derived)
	notation: string, // hex, rgb, hsl or oklch
	in_gamut: bool,
}

parse_color :: proc(s_in: string) -> (pc: Parsed_Color, ok: bool) {
	rgb, notation, inside, lch, good := parse_color_parts(s_in)
	if !good {
		return {}, false
	}
	if notation != "oklch" {
		lch = srgb_to_oklch(rgb)
	}
	return {rgb = rgb, lch = lch, notation = notation, in_gamut = inside}, true
}

@(private = "file")
parse_color_parts :: proc(s_in: string) -> (rgb: [3]f32, notation: string, in_gamut: bool, lch: [3]f32, ok: bool) {
	s := strings.to_lower(strings.trim_space(s_in), context.temp_allocator)
	if h, good := parse_hex(s); good {
		return h, "hex", true, {}, true
	}
	open := strings.index_byte(s, '(')
	if open <= 0 || !strings.has_suffix(s, ")") {
		return
	}
	fn := strings.trim_space(s[:open])
	body := s[open + 1:len(s) - 1]
	if slash := strings.index_byte(body, '/'); slash >= 0 {
		body = body[:slash]
	}
	spaced, _ := strings.replace_all(body, ",", " ", context.temp_allocator)
	parts := strings.fields(spaced, context.temp_allocator)
	if len(parts) == 4 && (fn == "rgba" || fn == "hsla") {
		parts = parts[:3] // the legacy comma form's alpha
	}
	if len(parts) != 3 {
		return
	}
	// num reads one component; a percentage is scaled to `pct_full`.
	num :: proc(t: string, pct_full: f32) -> (f32, bool) {
		u := strings.trim_suffix(t, "deg")
		pct := strings.has_suffix(u, "%")
		v, good := parse_number(u)
		if !good {
			return 0, false
		}
		return pct ? v / 100 * pct_full : v, true
	}
	switch fn {
	case "rgb", "rgba":
		out: [3]f32
		for i in 0 ..< 3 {
			v, good := num(parts[i], 255)
			if !good {
				return
			}
			out[i] = clamp(v, 0, 255) / 255
		}
		return out, "rgb", true, {}, true
	case "hsl", "hsla":
		h, g1 := num(parts[0], 360)
		sat, g2 := num(parts[1], 100)
		l, g3 := num(parts[2], 100)
		if !g1 || !g2 || !g3 {
			return
		}
		h = math.mod_f32(math.mod_f32(h, 360) + 360, 360)
		return hsl_to_srgb({h, clamp(sat, 0, 100) / 100, clamp(l, 0, 100) / 100}), "hsl", true, {}, true
	case "oklch":
		l, g1 := num(parts[0], 1)
		c, g2 := num(parts[1], 0.4) // CSS: 100% chroma is 0.4
		h, g3 := num(parts[2], 360)
		if !g1 || !g2 || !g3 {
			return
		}
		h = math.mod_f32(math.mod_f32(h, 360) + 360, 360)
		w := [3]f32{clamp(l, 0, 1), max(c, 0), h}
		out, inside := oklch_to_srgb(w)
		return out, "oklch", inside, w, true
	}
	return
}

// ---------------------------------------------------------------------------
// Self test
// ---------------------------------------------------------------------------

// selftest checks the conversions against published reference values and
// verifies that every space round trips. It returns the number of failures and
// prints each line, pass or fail, so the output is a record rather than a
// claim.
selftest :: proc() -> int {
	fails := 0
	g_checks = 0

	check :: proc(fails: ^int, name: string, got, want, tol: f32) {
		d := abs(got - want)
		pass := d <= tol
		g_checks += 1
		if !pass {
			fails^ += 1
		}
		fmt.printfln(
			"%s  %-34s got %12.6f  want %12.6f  (tol %g, diff %.6g)",
			pass ? "ok  " : "FAIL",
			name,
			got,
			want,
			tol,
			d,
		)
	}

	fmt.println("-- sRGB transfer function")
	check(&fails, "linear(0.5)", srgb_to_linear(0.5), 0.2140411, 1e-5)
	check(&fails, "srgb(0.2140411)", linear_to_srgb(0.2140411), 0.5, 1e-5)
	check(&fails, "linear(0.04045) linear segment", srgb_to_linear(0.04045), 0.003131, 1e-5)

	// Ottosson's own reference: pure sRGB primaries in OKLCH, as the CSS Color
	// 4 spec and every browser's devtools report them.
	fmt.println("\n-- OKLCH of the sRGB primaries")
	refs := [?]struct {
		name:  string,
		rgb:   [3]f32,
		l, c, h: f32,
	} {
		{"#ffffff white", {1, 1, 1}, 1.0, 0.0, 0.0},
		{"#000000 black", {0, 0, 0}, 0.0, 0.0, 0.0},
		{"#ff0000 red", {1, 0, 0}, 0.62796, 0.25768, 29.234},
		{"#00ff00 green", {0, 1, 0}, 0.86644, 0.29483, 142.495},
		{"#0000ff blue", {0, 0, 1}, 0.45201, 0.31321, 264.052},
		{"#808080 mid grey", {128.0 / 255, 128.0 / 255, 128.0 / 255}, 0.59987, 0.0, 0.0},
	}
	for r in refs {
		o := srgb_to_oklch(r.rgb)
		check(&fails, fmt.tprintf("%s L", r.name), o[0], r.l, 5e-4)
		check(&fails, fmt.tprintf("%s C", r.name), o[1], r.c, 5e-4)
		if r.c > 0.01 {
			check(&fails, fmt.tprintf("%s H", r.name), o[2], r.h, 0.02)
		}
	}

	// The shadcn destructive token, which is authored in OKLCH, has to come
	// back as the sRGB the browser computes.
	fmt.println("\n-- oklch() -> sRGB (shadcn --destructive)")
	{
		rgb, in_gamut := oklch_to_srgb({0.577, 0.245, 27.325})
		b := to_bytes(rgb)
		fmt.printfln(
			"     oklch(0.577 0.245 27.325) -> #%02x%02x%02x  in_gamut=%v",
			b[0],
			b[1],
			b[2],
			in_gamut,
		)
		// Chromium computes rgb(231, 0, 11) for this token.
		check(&fails, "destructive R", f32(b[0]), 231, 1.5)
		check(&fails, "destructive G", f32(b[1]), 0, 1.5)
		check(&fails, "destructive B", f32(b[2]), 11, 1.5)
	}

	fmt.println("\n-- HSL reference values")
	{
		h := srgb_to_hsl({1, 0, 0})
		check(&fails, "#ff0000 H", h[0], 0, 1e-4)
		check(&fails, "#ff0000 S", h[1], 1, 1e-4)
		check(&fails, "#ff0000 L", h[2], 0.5, 1e-4)

		h2 := srgb_to_hsl(from_bytes({0x3b, 0x82, 0xf6})) // tailwind blue-500
		// Cross-checked against Python's colorsys.rgb_to_hls for the same
		// bytes: H 217.21925, S 0.9121951, L 0.5980392.
		check(&fails, "#3b82f6 H", h2[0], 217.21925, 1e-3)
		check(&fails, "#3b82f6 S", h2[1], 0.9121951, 1e-5)
		check(&fails, "#3b82f6 L", h2[2], 0.5980392, 1e-5)

		back := hsl_to_srgb({217.21925, 0.9121951, 0.5980392})
		bb := to_bytes(back)
		check(&fails, "#3b82f6 HSL round trip R", f32(bb[0]), 0x3b, 1)
		check(&fails, "#3b82f6 HSL round trip G", f32(bb[1]), 0x82, 1)
		check(&fails, "#3b82f6 HSL round trip B", f32(bb[2]), 0xf6, 1)
	}

	fmt.println("\n-- WCAG contrast")
	check(&fails, "white vs black", contrast_ratio({1, 1, 1}, {0, 0, 0}), 21.0, 1e-3)
	check(&fails, "self vs self", contrast_ratio({0.4, 0.2, 0.7}, {0.4, 0.2, 0.7}), 1.0, 1e-5)
	// #767676 on white is the canonical 4.5:1 boundary from the WCAG docs.
	check(
		&fails,
		"#767676 vs white",
		contrast_ratio(from_bytes({0x76, 0x76, 0x76}), {1, 1, 1}),
		4.54,
		0.01,
	)

	fmt.println("\n-- exhaustive round trips over all 16.7M sRGB values would")
	fmt.println("   take a while, so step the cube by 5 (140608 colours)")
	{
		worst_ok, worst_hsl := 0, 0
		n := 0
		for r := 0; r < 256; r += 5 {
			for g := 0; g < 256; g += 5 {
				for b := 0; b < 256; b += 5 {
					src := [3]u8{u8(r), u8(g), u8(b)}
					rgb := from_bytes(src)
					n += 1

					o := srgb_to_oklch(rgb)
					back, _ := oklch_to_srgb(o)
					bo := to_bytes(back)

					h := srgb_to_hsl(rgb)
					hb := to_bytes(hsl_to_srgb(h))

					for i in 0 ..< 3 {
						worst_ok = max(worst_ok, abs(int(bo[i]) - int(src[i])))
						worst_hsl = max(worst_hsl, abs(int(hb[i]) - int(src[i])))
					}
				}
			}
		}
		fmt.printfln("     %d colours tested", n)
		check(&fails, "worst OKLCH round-trip error (8-bit)", f32(worst_ok), 0, 1)
		check(&fails, "worst HSL round-trip error (8-bit)", f32(worst_hsl), 0, 1)
	}

	ui_checks, ui_fails := ui_selftest()
	fails += ui_fails

	fmt.printfln(
		"\n%s  %d checks, %d failure(s)",
		fails == 0 ? "PASS" : "FAILED",
		g_checks + ui_checks,
		fails,
	)
	return fails
}

// g_checks counts the numeric comparisons above, so the two halves of the
// self-test can report one total.
g_checks: int
