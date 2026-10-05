// Inline images.
//
// An image is a `Para_Kind.Image` paragraph: the paragraph's alignment places
// it, `scale` sizes it against its intrinsic pixel size, and the layout gives
// it one line box as tall as the picture. That means pagination comes free —
// the existing "this line does not fit, start a page" rule in `layout_doc`
// moves a tall image down without knowing it is an image — and so does the
// caret, which sits before or after the image paragraph the way it sits either
// side of any other block.
//
// ## Why the original bytes are kept
//
// `bytes` holds the file exactly as it was read, and `px` holds the decoded
// pixels. Both are needed, for different consumers:
//
//   * the window and the PNG export need `px`, because they composite;
//   * .docx, .odt and .rtf want the *original* file, because they embed the
//     picture as a part and a reader expects a real PNG or JPEG;
//   * the PDF wants the original for a JPEG — `/DCTDecode` takes the bytes in
//     as-is, which is both smaller and lossless-relative-to-the-source — and
//     the decoded pixels for a PNG, because Odin's core has an inflate but no
//     deflate, so a PNG cannot be re-wrapped and has to go in as RGB under
//     `/RunLengthDecode`.
//
// A document that has been through the JSON format carries the bytes base64'd,
// so a .json round trip keeps the picture rather than a path that may not
// exist on the next machine.
package main

import "core:os"
import "core:strings"
import p "palmy:."

// IMAGE_MAX_W is the widest a picture is drawn at: the content measure. A
// picture wider than the page is scaled down to it rather than clipped.
IMAGE_MAX_W :: CONTENT_W

Image_Format :: enum u8 {
	Unknown,
	PNG,
	JPEG,
}

Doc_Image :: struct {
	path:  string, // where it came from, for the status line and re-export
	alt:   string, // alternative text, which every export carries
	bytes: []u8, // the original file, verbatim
	kind:  Image_Format,
	w, h:  int, // intrinsic pixel size
	scale: f32, // 1 = intrinsic size at 96 dpi; 0 is read as 1
	px:    []u32, // decoded 0xAARRGGBB, w*h, or nil if it would not decode
}

image_destroy :: proc(im: ^Doc_Image) {
	delete(im.path)
	delete(im.alt)
	delete(im.bytes)
	delete(im.px)
	im^ = {}
}

image_clone :: proc(im: ^Doc_Image) -> Doc_Image {
	out := Doc_Image {
		path  = strings.clone(im.path),
		alt   = strings.clone(im.alt),
		kind  = im.kind,
		w     = im.w,
		h     = im.h,
		scale = im.scale,
	}
	if len(im.bytes) > 0 {
		out.bytes = make([]u8, len(im.bytes))
		copy(out.bytes, im.bytes)
	}
	if len(im.px) > 0 {
		out.px = make([]u32, len(im.px))
		copy(out.px, im.px)
	}
	return out
}

// image_sniff identifies a file from its first bytes rather than its name,
// because the extension is a hint and the magic is the fact.
image_sniff :: proc(data: []u8) -> Image_Format {
	if len(data) >= 8 &&
	   data[0] == 0x89 &&
	   data[1] == 'P' &&
	   data[2] == 'N' &&
	   data[3] == 'G' &&
	   data[4] == 0x0d &&
	   data[5] == 0x0a &&
	   data[6] == 0x1a &&
	   data[7] == 0x0a {
		return .PNG
	}
	if len(data) >= 3 && data[0] == 0xff && data[1] == 0xd8 && data[2] == 0xff {
		return .JPEG
	}
	return .Unknown
}

image_mime :: proc(k: Image_Format) -> string {
	switch k {
	case .PNG:
		return "image/png"
	case .JPEG:
		return "image/jpeg"
	case .Unknown:
	}
	return "application/octet-stream"
}

image_ext :: proc(k: Image_Format) -> string {
	switch k {
	case .PNG:
		return "png"
	case .JPEG:
		return "jpeg"
	case .Unknown:
	}
	return "bin"
}

// image_from_bytes builds an image from file bytes already in hand, decoding
// them through palmy. It is the one constructor: `image_load` reads a file and
// hands the bytes here, and the JSON reader base64-decodes and does the same,
// so a picture is identical however it arrived.
image_from_bytes :: proc(data: []u8, path := "", alt := "", scale := f32(1)) -> (Doc_Image, bool) {
	kind := image_sniff(data)
	if kind == .Unknown {
		return {}, false
	}
	img, decoded := p.decode_image(data)
	if !decoded || img.w <= 0 || img.h <= 0 {
		return {}, false
	}
	defer p.image_destroy(&img)

	out := Doc_Image {
		path  = strings.clone(path),
		alt   = strings.clone(alt == "" ? base_name(path) : alt),
		kind  = kind,
		w     = img.w,
		h     = img.h,
		scale = scale <= 0 ? 1 : scale,
	}
	out.bytes = make([]u8, len(data))
	copy(out.bytes, data)
	out.px = make([]u32, img.w * img.h)
	copy(out.px, img.px[:img.w * img.h])
	return out, true
}

image_load :: proc(path: string, scale := f32(1)) -> (Doc_Image, bool) {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		return {}, false
	}
	return image_from_bytes(data, path, base_name(path), scale)
}

// image_para_make is the paragraph an insert produces.
image_para_make :: proc(im: Doc_Image, align := Align.Center) -> Paragraph {
	pa := para_make(.Image)
	pa.align = align
	pa.img = new(Doc_Image)
	pa.img^ = im
	return pa
}

// ---------------------------------------------------------------------------
// Sizing
// ---------------------------------------------------------------------------

// image_draw_size is the box the picture occupies in layout pixels. Two caps
// apply, in this order: the content measure, so it never runs into the margin,
// and the content height, so a picture always fits on a page of its own rather
// than being unplaceable.
// `measure` and `maxh` default to the page's own text area. A picture inside
// a table cell is capped by the cell instead — the same two rules, against a
// smaller box, which is all "a picture in a cell" needs from the sizing.
image_draw_size :: proc(im: ^Doc_Image, measure := f32(IMAGE_MAX_W), maxh := f32(CONTENT_H)) -> (w, h: f32) {
	if im == nil || im.w <= 0 || im.h <= 0 {
		return 0, 0
	}
	s := im.scale <= 0 ? f32(1) : im.scale
	w = f32(im.w) * s
	h = f32(im.h) * s
	lim_w := max(measure, 8)
	lim_h := max(maxh, 8)
	if w > lim_w {
		k := lim_w / w
		w *= k
		h *= k
	}
	if h > lim_h {
		k := lim_h / h
		w *= k
		h *= k
	}
	return max(w, 1), max(h, 1)
}

// image_para_size answers for a paragraph, including the placeholder box an
// image that would not decode is given — a document that moved between
// machines should say what it is missing rather than silently closing up.
image_para_size :: proc(pa: ^Paragraph, measure := f32(IMAGE_MAX_W), maxh := f32(CONTENT_H)) -> (w, h: f32) {
	if pa.img == nil {
		return min(160, measure), 90
	}
	return image_draw_size(pa.img, measure, maxh)
}

// image_x is the picture's left edge within the text area, from the
// paragraph's own alignment. Justified reads as centred, which is the only
// sensible thing a single box can do with it.
image_x :: proc(pa: ^Paragraph, w: f32, measure := f32(CONTENT_W)) -> f32 {
	switch pa.align {
	case .Center, .Justify:
		return max(0, (measure - w) / 2)
	case .Right:
		return max(0, measure - w)
	case .Left:
	}
	return 0
}

image_set_scale :: proc(im: ^Doc_Image, s: f32) {
	if im == nil {
		return
	}
	im.scale = clamp(s, 0.05, 8)
}
