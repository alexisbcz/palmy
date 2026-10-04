package main

// Colour, in the two spaces an image editor actually needs.
//
// HSV is what a picker is: a hue strip and a saturation/value square is a
// cylinder sliced open, and nothing else maps so directly onto two draggable
// widgets. HSL is what a Hue/Saturation adjustment is: shifting lightness has
// to be symmetric about mid-grey, which HSV's value is not.
//
// Everything here round-trips, and `selftest.odin` checks that over the whole
// 8-bit cube at a stride rather than on a handful of samples.

import "core:fmt"
import "core:strings"

// ---------------------------------------------------------------------------
// Packing
// ---------------------------------------------------------------------------

pack_argb :: proc "contextless" (r, g, b, a: u8) -> u32 {
	return (u32(a) << 24) | (u32(r) << 16) | (u32(g) << 8) | u32(b)
}

unpack_argb :: proc "contextless" (v: u32) -> (r, g, b, a: u8) {
	return u8((v >> 16) & 0xff), u8((v >> 8) & 0xff), u8(v & 0xff), u8((v >> 24) & 0xff)
}

// to_palmy converts a document pixel to the colour type the rasterizer takes.
to_palmy :: proc "contextless" (v: u32) -> (r, g, b, a: u8) {
	return unpack_argb(v)
}

// ---------------------------------------------------------------------------
// HSV
// ---------------------------------------------------------------------------

// rgb_to_hsv takes channels in 0..1 and returns h in degrees 0..360, s and v in
// 0..1. A neutral reports hue 0 rather than the arctangent of two rounding
// errors, so the readout does not jitter on grey.
rgb_to_hsv :: proc "contextless" (r, g, b: f32) -> (h, s, v: f32) {
	mx := max(r, max(g, b))
	mn := min(r, min(g, b))
	v = mx
	d := mx - mn
	s = mx <= 0 ? 0 : d / mx
	if d <= 0 {
		return 0, s, v
	}
	switch mx {
	case r:
		h = (g - b) / d
		if h < 0 {h += 6}
	case g:
		h = (b - r) / d + 2
	case:
		h = (r - g) / d + 4
	}
	h *= 60
	if h < 0 {h += 360}
	if h >= 360 {h -= 360}
	return h, s, v
}

hsv_to_rgb :: proc "contextless" (h, s, v: f32) -> (r, g, b: f32) {
	hh := h
	for hh < 0 {hh += 360}
	for hh >= 360 {hh -= 360}
	c := v * clamp(s, 0, 1)
	seg := hh / 60
	i := int(seg)
	f := seg - f32(i)
	p0 := v - c
	q := v - c * f
	t := v - c * (1 - f)
	switch i {
	case 0:
		return v, t, p0
	case 1:
		return q, v, p0
	case 2:
		return p0, v, t
	case 3:
		return p0, q, v
	case 4:
		return t, p0, v
	}
	return v, p0, q
}

// ---------------------------------------------------------------------------
// HSL
// ---------------------------------------------------------------------------

rgb_to_hsl :: proc "contextless" (r, g, b: f32) -> (h, s, l: f32) {
	mx := max(r, max(g, b))
	mn := min(r, min(g, b))
	l = (mx + mn) / 2
	d := mx - mn
	if d <= 0 {
		return 0, 0, l
	}
	s = l > 0.5 ? d / (2 - mx - mn) : d / (mx + mn)
	switch mx {
	case r:
		h = (g - b) / d
		if h < 0 {h += 6}
	case g:
		h = (b - r) / d + 2
	case:
		h = (r - g) / d + 4
	}
	h *= 60
	if h >= 360 {h -= 360}
	return h, s, l
}

hsl_to_rgb :: proc "contextless" (h, s, l: f32) -> (r, g, b: f32) {
	if s <= 0 {
		return l, l, l
	}
	q := l < 0.5 ? l * (1 + s) : l + s - l * s
	p0 := 2 * l - q
	hk := h / 360
	for hk < 0 {hk += 1}
	for hk >= 1 {hk -= 1}
	ch :: proc "contextless" (p0, q, t_in: f32) -> f32 {
		t := t_in
		if t < 0 {t += 1}
		if t > 1 {t -= 1}
		if t < 1.0 / 6 {return p0 + (q - p0) * 6 * t}
		if t < 1.0 / 2 {return q}
		if t < 2.0 / 3 {return p0 + (q - p0) * (2.0 / 3 - t) * 6}
		return p0
	}
	return ch(p0, q, hk + 1.0 / 3), ch(p0, q, hk), ch(p0, q, hk - 1.0 / 3)
}

// ---------------------------------------------------------------------------
// Luma
// ---------------------------------------------------------------------------

// LUMA_R/G/B are Rec. 709, which is the right weighting for sRGB primaries and
// the one Photoshop's own desaturate uses.
LUMA_R :: f32(0.2126)
LUMA_G :: f32(0.7152)
LUMA_B :: f32(0.0722)

luma8 :: proc "contextless" (r, g, b: u8) -> f32 {
	return (LUMA_R * f32(r) + LUMA_G * f32(g) + LUMA_B * f32(b)) / 255
}

// ---------------------------------------------------------------------------
// Hex
// ---------------------------------------------------------------------------

hex_string :: proc(v: u32, allocator := context.allocator) -> string {
	r, g, b, _ := unpack_argb(v)
	return fmt.aprintf("#%02X%02X%02X", r, g, b, allocator = allocator)
}

// parse_hex accepts #rgb, #rrggbb and #rrggbbaa, with or without the hash.
parse_hex :: proc(s_in: string) -> (v: u32, ok: bool) {
	s := strings.trim_space(s_in)
	s = strings.trim_prefix(s, "#")
	digit :: proc(c: u8) -> (int, bool) {
		switch {
		case c >= '0' && c <= '9':
			return int(c - '0'), true
		case c >= 'a' && c <= 'f':
			return int(c - 'a') + 10, true
		case c >= 'A' && c <= 'F':
			return int(c - 'A') + 10, true
		}
		return 0, false
	}
	nib := make([]int, len(s), context.temp_allocator)
	for i in 0 ..< len(s) {
		d, good := digit(s[i])
		if !good {
			return 0, false
		}
		nib[i] = d
	}
	switch len(s) {
	case 3:
		return pack_argb(
			u8(nib[0] * 17),
			u8(nib[1] * 17),
			u8(nib[2] * 17),
			255,
		), true
	case 6:
		return pack_argb(
			u8(nib[0] * 16 + nib[1]),
			u8(nib[2] * 16 + nib[3]),
			u8(nib[4] * 16 + nib[5]),
			255,
		), true
	case 8:
		return pack_argb(
			u8(nib[0] * 16 + nib[1]),
			u8(nib[2] * 16 + nib[3]),
			u8(nib[4] * 16 + nib[5]),
			u8(nib[6] * 16 + nib[7]),
		), true
	}
	return 0, false
}

// SWATCHES is the strip under the picker: the primaries and secondaries, a
// greyscale ramp, and the handful of mid-tones that are awkward to dial in.
SWATCHES := [?]u32 {
	0xff000000,
	0xff404040,
	0xff808080,
	0xffc0c0c0,
	0xffffffff,
	0xffe11d48,
	0xfff97316,
	0xfffacc15,
	0xff22c55e,
	0xff14b8a6,
	0xff3b82f6,
	0xff6366f1,
	0xff8b5cf6,
	0xffec4899,
	0xff78350f,
	0xff064e3b,
}
