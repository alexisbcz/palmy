package palmy

import "core:math"
import "core:os"
import "core:strings"
import stbi "vendor:stb/image"

// ---------------------------------------------------------------------------
// Images.
//
// Decoding goes through stb_image, which covers PNG, JPEG, BMP, GIF, TGA, PSD,
// PNM and HDR — everything a desktop actually opens by double-clicking. Pixels
// are kept as straight (non-premultiplied) 0xAARRGGBB so they composite through
// the same path as every other surface palmy draws.
// ---------------------------------------------------------------------------

Image :: struct {
	px:    []u32,
	w, h:  int,
	// What the file claimed, for a properties panel.
	source_channels: int,
}

// load_image decodes a file from disk.
load_image :: proc(path: string, allocator := context.allocator) -> (img: Image, ok: bool) {
	data, err := os.read_entire_file_from_path(path, context.temp_allocator)
	if err != nil {
		return {}, false
	}
	return decode_image(data, allocator)
}

// decode_image decodes an already-loaded file.
decode_image :: proc(data: []u8, allocator := context.allocator) -> (img: Image, ok: bool) {
	if len(data) == 0 {
		return {}, false
	}
	w, h, comp: i32
	raw := stbi.load_from_memory(raw_data(data), i32(len(data)), &w, &h, &comp, 4)
	if raw == nil || w <= 0 || h <= 0 {
		return {}, false
	}
	defer stbi.image_free(raw)

	n := int(w) * int(h)
	img.px = make([]u32, n, allocator)
	img.w, img.h = int(w), int(h)
	img.source_channels = int(comp)

	// stb gives RGBA bytes; pack to the 0xAARRGGBB the canvas uses.
	src := raw[:n * 4]
	for i in 0 ..< n {
		r := u32(src[i * 4 + 0])
		g := u32(src[i * 4 + 1])
		b := u32(src[i * 4 + 2])
		a := u32(src[i * 4 + 3])
		img.px[i] = (a << 24) | (r << 16) | (g << 8) | b
	}
	return img, true
}

// image_size reads the dimensions without decoding the pixels, which is what a
// file browser wants for a listing.
image_size :: proc(path: string) -> (w, h, channels: int, ok: bool) {
	data, err := os.read_entire_file_from_path(path, context.temp_allocator)
	if err != nil {
		return 0, 0, 0, false
	}
	x, y, c: i32
	if stbi.info_from_memory(raw_data(data), i32(len(data)), &x, &y, &c) == 0 {
		return 0, 0, 0, false
	}
	return int(x), int(y), int(c), true
}

image_destroy :: proc(img: ^Image) {
	delete(img.px)
	img^ = {}
}

// is_image_path is a cheap extension check, for deciding whether to try.
is_image_path :: proc(path: string) -> bool {
	lower := strings.to_lower(path, context.temp_allocator)
	for ext in ([?]string {
		".png", ".jpg", ".jpeg", ".bmp", ".gif", ".tga", ".psd", ".hdr",
		".pnm", ".ppm", ".pgm", ".jfif",
	}) {
		if strings.has_suffix(lower, ext) {
			return true
		}
	}
	return false
}

// Fit decides how an image fills the box it is given, matching CSS object-fit.
Fit :: enum u8 {
	Contain, // whole image visible, letterboxed
	Cover,   // box filled, overflow cropped
	Fill,    // stretched to the box
	None,    // natural size, centred
}

// fitted_rect computes where an image lands inside a box under a fit mode.
fitted_rect :: proc(img_w, img_h: f32, box: Rect, fit: Fit, zoom: f32 = 1) -> Rect {
	if img_w <= 0 || img_h <= 0 {
		return box
	}
	w, h: f32
	switch fit {
	case .Fill:
		w, h = box.w, box.h
	case .None:
		w, h = img_w, img_h
	case .Cover:
		s := max(box.w / img_w, box.h / img_h)
		w, h = img_w * s, img_h * s
	case .Contain:
		s := min(box.w / img_w, box.h / img_h)
		w, h = img_w * s, img_h * s
	}
	w *= zoom
	h *= zoom
	return Rect{box.x + (box.w - w) / 2, box.y + (box.h - h) / 2, w, h}
}

// draw_image scales an image into a destination rectangle. Sampling is
// bilinear when scaling down or up smoothly, and nearest when magnified past
// 2x so that a zoomed-in photo shows its actual pixels rather than mush.
draw_image :: proc(c: ^Canvas, img: Image, dst: Rect, opacity: f32 = 1) {
	if img.w <= 0 || img.h <= 0 || dst.w <= 0 || dst.h <= 0 || opacity <= 0.002 {
		return
	}

	b := rect_intersect(dst, c.clip)
	if b.w <= 0 || b.h <= 0 {
		return
	}

	sx := f32(img.w) / dst.w
	sy := f32(img.h) / dst.h
	nearest := sx < 0.5 && sy < 0.5 // magnified more than 2x

	x0 := int(math.floor(b.x))
	y0 := int(math.floor(b.y))
	x1 := int(math.ceil(rect_right(b)))
	y1 := int(math.ceil(rect_bottom(b)))

	for y in y0 ..< y1 {
		v := (f32(y) + 0.5 - dst.y) * sy - 0.5
		for x in x0 ..< x1 {
			u := (f32(x) + 0.5 - dst.x) * sx - 0.5
			col := nearest ? sample_nearest(img, u, v) : sample_bilinear(img, u, v)
			if col.a == 0 {
				continue
			}
			blend(c, x, y, col, opacity)
		}
	}
}

@(private)
sample_nearest :: proc "contextless" (img: Image, u, v: f32) -> Color {
	x := clamp(int(u + 0.5), 0, img.w - 1)
	y := clamp(int(v + 0.5), 0, img.h - 1)
	p := img.px[y * img.w + x]
	return {u8(p >> 16), u8(p >> 8), u8(p), u8(p >> 24)}
}

@(private)
sample_bilinear :: proc "contextless" (img: Image, u, v: f32) -> Color {
	x0 := int(math.floor(u))
	y0 := int(math.floor(v))
	fx := u - f32(x0)
	fy := v - f32(y0)

	px :: proc "contextless" (img: Image, x, y: int) -> [4]f32 {
		cx := clamp(x, 0, img.w - 1)
		cy := clamp(y, 0, img.h - 1)
		p := img.px[cy * img.w + cx]
		// Weight colour by alpha so transparent pixels do not bleed their
		// colour into opaque neighbours.
		a := f32((p >> 24) & 0xff)
		return {f32((p >> 16) & 0xff) * a, f32((p >> 8) & 0xff) * a, f32(p & 0xff) * a, a}
	}

	c00 := px(img, x0, y0)
	c10 := px(img, x0 + 1, y0)
	c01 := px(img, x0, y0 + 1)
	c11 := px(img, x0 + 1, y0 + 1)

	top := c00 * (1 - fx) + c10 * fx
	bot := c01 * (1 - fx) + c11 * fx
	out := top * (1 - fy) + bot * fy

	if out.w < 0.5 {
		return {}
	}
	inv := 1 / out.w
	return {
		u8(clamp(out.x * inv, 0, 255)),
		u8(clamp(out.y * inv, 0, 255)),
		u8(clamp(out.z * inv, 0, 255)),
		u8(clamp(out.w, 0, 255)),
	}
}

// write_png_rgba saves raw RGBA bytes as a PNG. Handy for screenshots, and for
// any app that needs to export what it drew.
write_png_rgba :: proc(path: string, rgba: []u8, w, h: int) -> bool {
	if len(rgba) < w * h * 4 || w <= 0 || h <= 0 {
		return false
	}
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	return stbi.write_png(cpath, i32(w), i32(h), 4, raw_data(rgba), i32(w * 4)) != 0
}
