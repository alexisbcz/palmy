package main

// Filters: real convolution.
//
// Two decisions matter here and both are easy to get wrong.
//
// **Premultiply before blurring.** A straight-alpha layer stores a colour even
// where alpha is zero, and that colour is usually black. Averaging it in pulls
// a dark halo out of every soft edge. So every neighbourhood operation runs on
// premultiplied samples and unpremultiplies at the end, which is what makes a
// blurred brush stroke fade out instead of fading to black.
//
// **Separate the gaussian.** A 2D gaussian is the outer product of two 1D
// gaussians, so a radius-20 blur is 2x41 taps per pixel rather than 1681. At
// 786k pixels that is the difference between 60 ms and 2.5 seconds.

import "core:math"

Filter_Kind :: enum u8 {
	Gaussian_Blur,
	Sharpen,
	Edge_Detect,
	Emboss,
}

FILTER_NAMES := [Filter_Kind]string {
	.Gaussian_Blur = "Gaussian Blur",
	.Sharpen       = "Sharpen (unsharp mask)",
	.Edge_Detect   = "Edge Detect (Sobel)",
	.Emboss        = "Emboss",
}

filter_spec :: proc(k: Filter_Kind) -> Adjust_Spec {
	switch k {
	case .Gaussian_Blur:
		return {n = 1, params = {0 = {"Radius", 0.5, 40, 0.5, 4, " px"}, 1 = {}, 2 = {}, 3 = {}, 4 = {}}}
	case .Sharpen:
		return {
			n = 2,
			params = {
				0 = {"Radius", 0.5, 12, 0.5, 2, " px"},
				1 = {"Amount", 0, 300, 5, 100, "%"},
				2 = {}, 3 = {}, 4 = {},
			},
		}
	case .Edge_Detect:
		return {n = 1, params = {0 = {"Strength", 10, 400, 10, 100, "%"}, 1 = {}, 2 = {}, 3 = {}, 4 = {}}}
	case .Emboss:
		return {
			n = 2,
			params = {
				0 = {"Strength", 10, 400, 10, 100, "%"},
				1 = {"Angle", 0, 315, 45, 135, "°"},
				2 = {}, 3 = {}, 4 = {},
			},
		}
	}
	return {}
}

filter_defaults :: proc(k: Filter_Kind) -> (v: [MAX_PARAMS]f32) {
	sp := filter_spec(k)
	for i in 0 ..< sp.n {
		v[i] = sp.params[i].def
	}
	return
}

// ---------------------------------------------------------------------------
// The gaussian kernel
// ---------------------------------------------------------------------------

// gaussian_kernel builds a normalised half-kernel of taps for a given radius.
// sigma = radius/2 is the usual convention (Photoshop's "radius" is roughly
// 2 sigma), and the kernel is cut at the radius, so `sum(w) == 1` exactly after
// normalisation — the property that keeps a blur from changing a region's mean
// brightness.
gaussian_kernel :: proc(radius: f32, allocator := context.allocator) -> (w: []f32, k: int) {
	k = max(1, int(math.ceil(radius)))
	sigma := max(radius, 0.1) / 2
	w = make([]f32, 2 * k + 1, allocator)
	total: f32 = 0
	for i in -k ..= k {
		x := f32(i)
		v := math.exp(-(x * x) / (2 * sigma * sigma))
		w[i + k] = v
		total += v
	}
	for i in 0 ..< len(w) {
		w[i] /= total
	}
	return
}

// ---------------------------------------------------------------------------
// Premultiplied working buffers
// ---------------------------------------------------------------------------

// Pm is a premultiplied f32 plane, the space every neighbourhood filter here
// works in.
Pm :: struct {
	r, g, b, a: []f32,
	w, h:       int,
}

pm_make :: proc(w, h: int, allocator := context.allocator) -> Pm {
	return Pm {
		r = make([]f32, w * h, allocator),
		g = make([]f32, w * h, allocator),
		b = make([]f32, w * h, allocator),
		a = make([]f32, w * h, allocator),
		w = w,
		h = h,
	}
}

pm_from :: proc(src: []u32, w, h: int, allocator := context.allocator) -> Pm {
	o := pm_make(w, h, allocator)
	for i in 0 ..< w * h {
		v := src[i]
		af := f32((v >> 24) & 0xff) / 255
		o.a[i] = af
		o.r[i] = f32((v >> 16) & 0xff) / 255 * af
		o.g[i] = f32((v >> 8) & 0xff) / 255 * af
		o.b[i] = f32(v & 0xff) / 255 * af
	}
	return o
}

// pm_to unpremultiplies back into 0xAARRGGBB, writing only inside `r`.
pm_to :: proc(dst: []u32, src: Pm, r: Rect_I) {
	for y in r.y0 ..< r.y1 {
		for x in r.x0 ..< r.x1 {
			i := y * src.w + x
			af := clamp(src.a[i], 0, 1)
			if af <= 0.0001 {
				dst[i] = 0
				continue
			}
			dst[i] =
				(u32(af * 255 + 0.5) << 24) |
				(u32(clamp(src.r[i] / af, 0, 1) * 255 + 0.5) << 16) |
				(u32(clamp(src.g[i] / af, 0, 1) * 255 + 0.5) << 8) |
				u32(clamp(src.b[i] / af, 0, 1) * 255 + 0.5)
		}
	}
}

// blur_plane runs one separable pass over a single plane.
//
// Each pass is split into three spans. Only the k pixels at each end can reach
// past the edge, so only those pay for the clamp; the middle — which is the
// whole image at any sane radius — is a straight contiguous dot product, which
// is what a compiler can actually make fast. Bounds checking is off here
// because the indices are derived from the span, not from data.
@(private = "file")
blur_plane :: proc(dst, src, tmp: []f32, w, h: int, kern: []f32, k: int) {
	n := 2 * k + 1

	// Horizontal.
	#no_bounds_check for y in 0 ..< h {
		row := y * w
		mid0 := min(k, w)
		mid1 := max(mid0, w - k)
		for x in 0 ..< mid0 {
			acc: f32 = 0
			for i in 0 ..< n {
				acc += src[row + clamp(x + i - k, 0, w - 1)] * kern[i]
			}
			tmp[row + x] = acc
		}
		for x in mid0 ..< mid1 {
			acc: f32 = 0
			base := row + x - k
			for i in 0 ..< n {
				acc += src[base + i] * kern[i]
			}
			tmp[row + x] = acc
		}
		for x in mid1 ..< w {
			acc: f32 = 0
			for i in 0 ..< n {
				acc += src[row + clamp(x + i - k, 0, w - 1)] * kern[i]
			}
			tmp[row + x] = acc
		}
	}

	// Vertical. Walking a column with a stride of `w` misses the cache on every
	// tap, so the loop is turned inside out: for each output row, each tap adds
	// one whole source row into an accumulator. Same number of multiplies,
	// entirely sequential memory, and the compiler can vectorise it.
	acc := make([]f32, w, context.temp_allocator)
	#no_bounds_check for y in 0 ..< h {
		for x in 0 ..< w {
			acc[x] = 0
		}
		for i in 0 ..< n {
			sy := clamp(y + i - k, 0, h - 1)
			kv := kern[i]
			srow := tmp[sy * w:]
			for x in 0 ..< w {
				acc[x] += srow[x] * kv
			}
		}
		copy(dst[y * w:][:w], acc[:w])
	}
}

// pm_blur gaussian-blurs every plane in place.
//
// A fully opaque layer — a photograph, the usual case — has a constant alpha
// plane, and blurring a constant is a quarter of the work for none of the
// result. So that plane is checked first and skipped.
pm_blur :: proc(p: ^Pm, radius: f32) {
	kern, k := gaussian_kernel(radius, context.temp_allocator)
	tmp := make([]f32, p.w * p.h, context.temp_allocator)
	for plane in ([3][]f32{p.r, p.g, p.b}) {
		blur_plane(plane, plane, tmp, p.w, p.h, kern, k)
	}
	flat := true
	for v in p.a {
		if v < 0.999 {
			flat = false
			break
		}
	}
	if !flat {
		blur_plane(p.a, p.a, tmp, p.w, p.h, kern, k)
	}
}

// ---------------------------------------------------------------------------
// The filters
// ---------------------------------------------------------------------------

// filter_blur: separable gaussian over the whole layer, written back inside the
// region. Blurring the whole layer and clipping the write is deliberate — it is
// what lets a selection's edge pull in colour from outside it, as Photoshop's
// does, rather than treating the selection as an island.
filter_blur :: proc(dst, src: []u32, w, h: int, r: Rect_I, radius: f32) {
	pm := pm_from(src, w, h, context.temp_allocator)
	pm_blur(&pm, radius)
	pm_to(dst, pm, r)
}

// filter_sharpen is an unsharp mask: dst = src + amount * (src - blur(src)).
// Done in premultiplied space so a soft edge sharpens rather than ringing into
// its own transparency.
filter_sharpen :: proc(dst, src: []u32, w, h: int, r: Rect_I, radius, amount_pct: f32) {
	base := pm_from(src, w, h, context.temp_allocator)
	blur := pm_from(src, w, h, context.temp_allocator)
	pm_blur(&blur, radius)
	amt := amount_pct / 100

	out := pm_make(w, h, context.temp_allocator)
	for i in 0 ..< w * h {
		out.r[i] = base.r[i] + amt * (base.r[i] - blur.r[i])
		out.g[i] = base.g[i] + amt * (base.g[i] - blur.g[i])
		out.b[i] = base.b[i] + amt * (base.b[i] - blur.b[i])
		// Alpha is left alone: sharpening the matte makes edges crawl.
		out.a[i] = base.a[i]
	}
	// Premultiplied channels must not exceed alpha, or unpremultiply clips to a
	// flat colour and the highlight turns into a plateau.
	for i in 0 ..< w * h {
		a := out.a[i]
		out.r[i] = clamp(out.r[i], 0, a)
		out.g[i] = clamp(out.g[i], 0, a)
		out.b[i] = clamp(out.b[i], 0, a)
	}
	pm_to(dst, out, r)
}

SOBEL_X := [9]f32{-1, 0, 1, -2, 0, 2, -1, 0, 1}
SOBEL_Y := [9]f32{-1, -2, -1, 0, 0, 0, 1, 2, 1}

// filter_edges is the Sobel gradient magnitude of the layer's luma, written as
// a grey image that keeps the original alpha. sqrt(gx^2 + gy^2), not the
// absolute-sum approximation.
filter_edges :: proc(dst, src: []u32, w, h: int, r: Rect_I, strength_pct: f32) {
	lum := make([]f32, w * h, context.temp_allocator)
	for i in 0 ..< w * h {
		v := src[i]
		af := f32((v >> 24) & 0xff) / 255
		// Premultiplied luma: a transparent pixel contributes no edge.
		lum[i] =
			(LUMA_R * f32((v >> 16) & 0xff) +
				LUMA_G * f32((v >> 8) & 0xff) +
				LUMA_B * f32(v & 0xff)) /
			255 *
			af
	}
	k := strength_pct / 100
	for y in r.y0 ..< r.y1 {
		for x in r.x0 ..< r.x1 {
			gx, gy: f32
			for j in -1 ..= 1 {
				sy := clamp(y + j, 0, h - 1)
				for i in -1 ..= 1 {
					sx := clamp(x + i, 0, w - 1)
					v := lum[sy * w + sx]
					t := (j + 1) * 3 + (i + 1)
					gx += v * SOBEL_X[t]
					gy += v * SOBEL_Y[t]
				}
			}
			m := clamp(math.sqrt(gx * gx + gy * gy) * k, 0, 1)
			g := u32(m * 255 + 0.5)
			dst[y * w + x] = (src[y * w + x] & 0xff00_0000) | (g << 16) | (g << 8) | g
		}
	}
}

// filter_emboss is a directional 3x3 difference biased to mid-grey: the
// kernel's weights sum to zero, so a flat area lands exactly on 128 and only
// slopes facing the light get brighter.
filter_emboss :: proc(dst, src: []u32, w, h: int, r: Rect_I, strength_pct, angle_deg: f32) {
	// The kernel is +1 on the lit side, -1 on the opposite side.
	rad := angle_deg * math.PI / 180
	dx := int(math.round(math.cos(rad)))
	dy := int(math.round(-math.sin(rad)))
	k := strength_pct / 100

	lum := make([]f32, w * h, context.temp_allocator)
	for i in 0 ..< w * h {
		v := src[i]
		lum[i] =
			(LUMA_R * f32((v >> 16) & 0xff) +
				LUMA_G * f32((v >> 8) & 0xff) +
				LUMA_B * f32(v & 0xff)) /
			255
	}
	for y in r.y0 ..< r.y1 {
		for x in r.x0 ..< r.x1 {
			ax := clamp(x + dx, 0, w - 1)
			ay := clamp(y + dy, 0, h - 1)
			bx := clamp(x - dx, 0, w - 1)
			by := clamp(y - dy, 0, h - 1)
			d := (lum[ay * w + ax] - lum[by * w + bx]) * k
			g := u32(clamp(0.5 + d, 0, 1) * 255 + 0.5)
			dst[y * w + x] = (src[y * w + x] & 0xff00_0000) | (g << 16) | (g << 8) | g
		}
	}
}

apply_filter :: proc(k: Filter_Kind, v: [MAX_PARAMS]f32, dst, src: []u32, w, h: int, r: Rect_I) {
	switch k {
	case .Gaussian_Blur:
		filter_blur(dst, src, w, h, r, v[0])
	case .Sharpen:
		filter_sharpen(dst, src, w, h, r, v[0], v[1])
	case .Edge_Detect:
		filter_edges(dst, src, w, h, r, v[0])
	case .Emboss:
		filter_emboss(dst, src, w, h, r, v[0], v[1])
	}
}
