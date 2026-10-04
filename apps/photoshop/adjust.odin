package main

// Adjustments: per-pixel tone and colour maps over the active layer.
//
// Each one is driven by up to four parameters and applied from a snapshot taken
// when its dialog opened, so a live preview is a recompute of f(snapshot) and
// never a compounding of f(f(snapshot)) — the mistake that makes a preview
// drift as you drag a slider.
//
// Brightness/Contrast and Levels are channel-independent, so they go through a
// 256-entry lookup table built once per parameter change: a 1024x768 layer is
// then three table reads per pixel instead of three transcendental functions.
// Hue/Saturation is not separable and is computed per pixel in HSL.

import "core:math"

Adjust_Kind :: enum u8 {
	Brightness_Contrast,
	Hue_Sat,
	Levels,
}

ADJUST_NAMES := [Adjust_Kind]string {
	.Brightness_Contrast = "Brightness / Contrast",
	.Hue_Sat             = "Hue / Saturation",
	.Levels              = "Levels",
}

Param :: struct {
	name: string,
	lo:   f32,
	hi:   f32,
	step: f32,
	def:  f32,
	unit: string,
}

MAX_PARAMS :: 5

Adjust_Spec :: struct {
	n:      int,
	params: [MAX_PARAMS]Param,
}

adjust_spec :: proc(k: Adjust_Kind) -> Adjust_Spec {
	switch k {
	case .Brightness_Contrast:
		return {
			n = 2,
			params = {
				0 = {"Brightness", -100, 100, 1, 0, ""},
				1 = {"Contrast", -100, 100, 1, 0, ""},
				2 = {}, 3 = {}, 4 = {},
			},
		}
	case .Hue_Sat:
		return {
			n = 3,
			params = {
				0 = {"Hue", -180, 180, 1, 0, "°"},
				1 = {"Saturation", -100, 100, 1, 0, ""},
				2 = {"Lightness", -100, 100, 1, 0, ""},
				3 = {}, 4 = {},
			},
		}
	case .Levels:
		return {
			n = 5,
			params = {
				0 = {"Input black", 0, 254, 1, 0, ""},
				1 = {"Input white", 1, 255, 1, 255, ""},
				2 = {"Gamma", 0.1, 4, 0.05, 1, ""},
				3 = {"Output black", 0, 255, 1, 0, ""},
				4 = {"Output white", 0, 255, 1, 255, ""},
			},
		}
	}
	return {}
}

adjust_defaults :: proc(k: Adjust_Kind) -> (v: [MAX_PARAMS]f32) {
	sp := adjust_spec(k)
	for i in 0 ..< sp.n {
		v[i] = sp.params[i].def
	}
	return
}

// ---------------------------------------------------------------------------
// Lookup tables
// ---------------------------------------------------------------------------

// brightness_contrast_lut maps 0..255 through a linear contrast pivot at
// mid-grey followed by a brightness offset. The factor is 1/(1-t) above zero so
// that +100 is a hard clip and the curve is continuous at t = 0.
brightness_contrast_lut :: proc(brightness, contrast: f32) -> (lut: [256]u8) {
	t := clamp(contrast / 100, -1, 1)
	factor := t >= 0 ? 1 / max(1 - t, 0.01) : 1 + t
	off := brightness / 100
	for i in 0 ..< 256 {
		x := f32(i) / 255
		y := (x - 0.5) * factor + 0.5 + off
		lut[i] = u8(clamp(y * 255 + 0.5, 0, 255))
	}
	return
}

// levels_lut is the classic five-control curve: remap the input range, apply
// gamma, then remap into the output range.
levels_lut :: proc(in_black, in_white, gamma, out_black, out_white: f32) -> (lut: [256]u8) {
	ib := clamp(in_black, 0, 254)
	iw := max(clamp(in_white, 1, 255), ib + 1)
	g := max(gamma, 0.01)
	ob := clamp(out_black, 0, 255)
	ow := clamp(out_white, 0, 255)
	for i in 0 ..< 256 {
		x := clamp((f32(i) - ib) / (iw - ib), 0, 1)
		y := math.pow(x, 1 / g)
		lut[i] = u8(clamp((ob + y * (ow - ob)) + 0.5, 0, 255))
	}
	return
}

apply_lut :: proc(dst, src: []u32, w: int, r: Rect_I, lut: [256]u8) {
	for y in r.y0 ..< r.y1 {
		srow := src[y * w:]
		drow := dst[y * w:]
		for x in r.x0 ..< r.x1 {
			v := srow[x]
			drow[x] =
				(v & 0xff00_0000) |
				(u32(lut[(v >> 16) & 0xff]) << 16) |
				(u32(lut[(v >> 8) & 0xff]) << 8) |
				u32(lut[v & 0xff])
		}
	}
}

// ---------------------------------------------------------------------------
// Hue / saturation
// ---------------------------------------------------------------------------

apply_hue_sat :: proc(dst, src: []u32, w: int, r: Rect_I, hue, sat, light: f32) {
	sm := 1 + clamp(sat, -100, 100) / 100
	lt := clamp(light, -100, 100) / 100
	for y in r.y0 ..< r.y1 {
		srow := src[y * w:]
		drow := dst[y * w:]
		for x in r.x0 ..< r.x1 {
			v := srow[x]
			if v & 0xff00_0000 == 0 {
				drow[x] = v
				continue
			}
			rf := f32((v >> 16) & 0xff) / 255
			gf := f32((v >> 8) & 0xff) / 255
			bf := f32(v & 0xff) / 255
			h, s, l := rgb_to_hsl(rf, gf, bf)
			h += hue
			for h < 0 {h += 360}
			for h >= 360 {h -= 360}
			s = clamp(s * sm, 0, 1)
			if lt >= 0 {
				l = l + (1 - l) * lt
			} else {
				l = l * (1 + lt)
			}
			nr, ng, nb := hsl_to_rgb(h, s, clamp(l, 0, 1))
			drow[x] =
				(v & 0xff00_0000) |
				(u32(clamp(nr * 255 + 0.5, 0, 255)) << 16) |
				(u32(clamp(ng * 255 + 0.5, 0, 255)) << 8) |
				u32(clamp(nb * 255 + 0.5, 0, 255))
		}
	}
}

// ---------------------------------------------------------------------------
// The dispatcher
// ---------------------------------------------------------------------------

apply_adjust :: proc(k: Adjust_Kind, v: [MAX_PARAMS]f32, dst, src: []u32, w: int, r: Rect_I) {
	switch k {
	case .Brightness_Contrast:
		apply_lut(dst, src, w, r, brightness_contrast_lut(v[0], v[1]))
	case .Levels:
		apply_lut(dst, src, w, r, levels_lut(v[0], v[1], v[2], v[3], v[4]))
	case .Hue_Sat:
		apply_hue_sat(dst, src, w, r, v[0], v[1], v[2])
	}
}

// ---------------------------------------------------------------------------
// One-shot adjustments
// ---------------------------------------------------------------------------

// invert_region flips RGB and leaves alpha alone, which is what Ctrl-I does in
// every editor: inverting alpha would turn a transparent layer opaque.
invert_region :: proc(dst, src: []u32, w: int, r: Rect_I) {
	for y in r.y0 ..< r.y1 {
		srow := src[y * w:]
		drow := dst[y * w:]
		for x in r.x0 ..< r.x1 {
			v := srow[x]
			drow[x] = (v & 0xff00_0000) | (~v & 0x00ff_ffff)
		}
	}
}

// desaturate_region replaces each pixel with its Rec. 709 luma.
desaturate_region :: proc(dst, src: []u32, w: int, r: Rect_I) {
	for y in r.y0 ..< r.y1 {
		srow := src[y * w:]
		drow := dst[y * w:]
		for x in r.x0 ..< r.x1 {
			v := srow[x]
			g := u32(
				clamp(
					LUMA_R * f32((v >> 16) & 0xff) +
					LUMA_G * f32((v >> 8) & 0xff) +
					LUMA_B * f32(v & 0xff) +
					0.5,
					0,
					255,
				),
			)
			drow[x] = (v & 0xff00_0000) | (g << 16) | (g << 8) | g
		}
	}
}

// ---------------------------------------------------------------------------
// Histogram
// ---------------------------------------------------------------------------

// histogram counts luma over the opaque part of a region, for the Levels panel.
histogram :: proc(src: []u32, w: int, r: Rect_I) -> (bins: [256]u32, peak: u32) {
	for y in r.y0 ..< r.y1 {
		row := src[y * w:]
		for x in r.x0 ..< r.x1 {
			v := row[x]
			if v & 0xff00_0000 == 0 {
				continue
			}
			l := u32(
				clamp(
					LUMA_R * f32((v >> 16) & 0xff) +
					LUMA_G * f32((v >> 8) & 0xff) +
					LUMA_B * f32(v & 0xff) +
					0.5,
					0,
					255,
				),
			)
			bins[l] += 1
		}
	}
	for b in bins {
		if b > peak {
			peak = b
		}
	}
	return
}
