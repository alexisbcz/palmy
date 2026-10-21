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
	// The size this image presents: what layout measures and what `draw_image`
	// maps the destination rectangle onto. For a view (see `image_window`) it
	// is the size of the window after it has been turned, not the size of the
	// pixel buffer.
	w, h:  int,
	// What the file claimed, for a properties panel.
	source_channels: int,

	// A view onto someone else's pixels, all zero for an ordinary image.
	// `stride` is the row length of the buffer, `ox`/`oy` the window's origin
	// in it, and `turns` the clockwise quarter turns to read it through.
	// `image_window` fills these in; nothing else needs to look at them.
	stride: int,
	ox, oy: int,
	turns:  u8,
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

// image_destroy frees the pixels. A view from `image_window` borrows another
// image's buffer, so destroying one is a no-op rather than a double free.
image_destroy :: proc(img: ^Image) {
	if img.stride == 0 {
		delete(img.px)
	}
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

// ---------------------------------------------------------------------------
// Views: a window onto an image, turned, with no copy.
//
// `image` reported both of these as missing: a viewer that rotates had to
// build the rotated pixels itself, and one that pans had to drive the canvas
// directly. A view is a plain `Image` that borrows the original's buffer, so
// it goes anywhere an image goes -- `p.image`, `draw_image`, `fitted_rect` --
// and costs nothing to make or to throw away.
//
//	p.image(ui, p.image_rotated(photo, turns), "w-full h-full", .Contain)
//	p.image(ui, p.image_window(photo, px, py, vw, vh, turns), "...", .Fill)
//
// Views do not stack: each one is described against the original pixels, so
// `image_rotated(image_rotated(img, 1), 1)` is a quarter turn, not a half.
// Chain the turns instead. A view must outlive nothing -- it holds no memory
// of its own -- and `image_destroy` on one is a no-op.
// ---------------------------------------------------------------------------

// image_source returns the pixel buffer's own geometry, which is the image
// itself unless it is a view.
@(private)
image_source :: proc "contextless" (img: Image) -> (sw, sh: int) {
	if img.stride > 0 {
		sw = img.stride
		sh = img.stride > 0 ? len(img.px) / img.stride : 0
		return
	}
	return img.w, img.h
}

// image_rotated returns a view of the whole image, turned clockwise by
// `quarter_turns` (negative turns anticlockwise). A quarter turn swaps `w`
// and `h`, so layout and object-fit see the turned shape.
image_rotated :: proc "contextless" (img: Image, quarter_turns: int) -> Image {
	sw, sh := image_source(img)
	return image_window_src(img, 0, 0, sw, sh, quarter_turns, true)
}

// image_window returns a view of one rectangle of the image, turned clockwise
// by `quarter_turns`. The rectangle is in the *turned* image's pixels, which
// is what panning a rotated picture means: `x` and `y` are how far into the
// picture the window starts as you see it, not as it is stored.
//
// A window that runs off the edge is clamped to the image, so a pan can be
// driven straight from a scroll offset without the caller checking bounds.
image_window :: proc "contextless" (img: Image, x, y, w, h: int, quarter_turns: int = 0) -> Image {
	return image_window_src(img, x, y, w, h, quarter_turns, false)
}

@(private)
image_window_src :: proc "contextless" (img: Image, x, y, w, h: int, quarter_turns: int, whole: bool) -> Image {
	sw, sh := image_source(img)
	if sw <= 0 || sh <= 0 || len(img.px) < sw * sh {
		return {}
	}
	q := u8(((quarter_turns % 4) + 4) % 4)

	// The size the whole buffer presents once turned.
	fw, fh := sw, sh
	if q == 1 || q == 3 {
		fw, fh = sh, sw
	}

	cx, cy, cw, ch := 0, 0, fw, fh
	if !whole {
		cx, cy = clamp(x, 0, fw), clamp(y, 0, fh)
		cw = clamp(w, 0, fw - cx)
		ch = clamp(h, 0, fh - cy)
		if cw <= 0 || ch <= 0 {
			return {}
		}
	}

	// Where that window sits in the stored buffer, undoing the turn.
	out := img
	out.px = img.px
	out.stride = sw
	out.turns = q
	out.w, out.h = cw, ch
	switch q {
	case 0:
		out.ox, out.oy = cx, cy
	case 1:
		out.ox, out.oy = cy, fw - (cx + cw)
	case 2:
		out.ox, out.oy = fw - (cx + cw), fh - (cy + ch)
	case 3:
		out.ox, out.oy = fh - (cy + ch), cx
	}
	return out
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

	b := rect_intersect(dst, draw_clip(c))
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

	if img.turns == 1 || img.turns == 3 {
		// A quarter-turned view reads across the source's rows, so walking the
		// destination in columns is what keeps the source reads sequential.
		// The destination writes scatter instead, but there is one of those
		// per pixel against four bilinear taps.
		for x in x0 ..< x1 {
			u := (f32(x) + 0.5 - dst.x) * sx - 0.5
			for y in y0 ..< y1 {
				v := (f32(y) + 0.5 - dst.y) * sy - 0.5
				col := nearest ? sample_nearest(img, u, v) : sample_bilinear(img, u, v)
				if col.a == 0 {
					continue
				}
				blend(c, x, y, col, opacity)
			}
		}
		return
	}

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

// view_uv maps a point in what the image presents to a point in the stored
// buffer's own axes, relative to the view's origin. It is the identity for an
// ordinary image.
@(private)
view_uv :: #force_inline proc "contextless" (img: Image, u, v: f32) -> (f32, f32) {
	switch img.turns {
	case 1:
		return v, f32(img.w - 1) - u
	case 2:
		return f32(img.w - 1) - u, f32(img.h - 1) - v
	case 3:
		return f32(img.h - 1) - v, u
	}
	return u, v
}

// view_texel reads one stored pixel. Taps are clamped to the whole buffer
// rather than to the window, so a window's edge samples its real neighbours
// instead of smearing its own border -- panning stays continuous.
@(private)
view_texel :: #force_inline proc "contextless" (img: Image, sw, sh, x, y: int) -> u32 {
	stride := img.stride > 0 ? img.stride : img.w
	cx := clamp(img.ox + x, 0, sw - 1)
	cy := clamp(img.oy + y, 0, sh - 1)
	return img.px[cy * stride + cx]
}

@(private)
sample_nearest :: proc "contextless" (img: Image, u, v: f32) -> Color {
	sw, sh := image_source(img)
	su, sv := view_uv(img, u, v)
	p := view_texel(img, sw, sh, int(su + 0.5), int(sv + 0.5))
	return {u8(p >> 16), u8(p >> 8), u8(p), u8(p >> 24)}
}

@(private)
sample_bilinear :: proc "contextless" (img: Image, u_in, v_in: f32) -> Color {
	sw, sh := image_source(img)
	u, v := view_uv(img, u_in, v_in)
	x0 := int(math.floor(u))
	y0 := int(math.floor(v))
	fx := u - f32(x0)
	fy := v - f32(y0)

	px :: proc "contextless" (img: Image, sw, sh, x, y: int) -> [4]f32 {
		p := view_texel(img, sw, sh, x, y)
		// Weight colour by alpha so transparent pixels do not bleed their
		// colour into opaque neighbours.
		a := f32((p >> 24) & 0xff)
		return {f32((p >> 16) & 0xff) * a, f32((p >> 8) & 0xff) * a, f32(p & 0xff) * a, a}
	}

	c00 := px(img, sw, sh, x0, y0)
	c10 := px(img, sw, sh, x0 + 1, y0)
	c01 := px(img, sw, sh, x0, y0 + 1)
	c11 := px(img, sw, sh, x0 + 1, y0 + 1)

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
