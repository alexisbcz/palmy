// The image core, with no window: what the viewer does to pixels and what it
// knows about a file, as plain procedures over `p.Image` and paths.
//
// The viewer calls these — its thumbnails are `img_thumbnail`, its rotation is
// `rotated`, its properties panel reads `image_info` and `image_metadata`, and
// Ctrl-S saves a copy through `img_save` — and so does the command line
// (cli.odin): `image thumbnail` is the grid's thumbnail filter, `image rotate`
// the viewer's rotation, `image info` the properties panel. Decoding is the
// same stb_image the viewer has always used (through palmy), and encoding is
// stb_image_write, which palmy already links for its own PNG screenshots.
//
// It stays inside apps/image for now; the pixel operations and the EXIF reader
// would be at home in a shared package later.
package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import p "palmy:."
import stbi "vendor:stb/image"

// ---------------------------------------------------------------------------
// Describing a file
// ---------------------------------------------------------------------------

Image_Info :: struct {
	path:      string,
	name:      string,
	size:      i64, // bytes on disk
	mtime:     time.Time,
	format:    string, // from the bytes, not the name: "PNG", "JPEG", …
	w, h:      int,
	channels:  int, // what the file stores: 1 grey … 4 RGBA
	decodable: bool, // stb_image can read the header
}

// image_info reads what can be known without decoding the pixels: the
// properties panel's File and Image groups.
image_info :: proc(path: string) -> (info: Image_Info, ok: bool) {
	fi, err := os.stat(path, context.temp_allocator)
	if err != nil || fi.type == .Directory {
		return {}, false
	}
	info.path = path
	info.name = base_of(path)
	info.size = fi.size
	info.mtime = fi.modification_time
	info.format = sniff_format(path)
	w, h, ch, good := p.image_size(path)
	if good {
		info.w, info.h, info.channels = w, h, ch
		info.decodable = true
		if info.format == "" {
			info.format = strings.to_upper(ext_of(path), context.temp_allocator)
		}
	}
	return info, true
}

// bits_per_pixel is how much of the file each pixel costs, which is the
// panel's "Stored at" — a quick read on how hard a file is compressed.
bits_per_pixel :: proc(info: Image_Info) -> f64 {
	if info.w <= 0 || info.h <= 0 {
		return 0
	}
	return f64(info.size) * 8 / (f64(info.w) * f64(info.h))
}

// ---------------------------------------------------------------------------
// Metadata: PNG text chunks and pHYs, JPEG JFIF and EXIF
// ---------------------------------------------------------------------------

Meta_Entry :: struct {
	key:   string, // stable, snake_case: make, model, date_taken, dpi, text:Title, …
	label: string, // for a person: "Camera make"
	value: string,
}

@(private = "file")
be16 :: proc(b: []u8, i: int) -> int {
	return int(b[i]) << 8 | int(b[i + 1])
}

@(private = "file")
be32 :: proc(b: []u8, i: int) -> int {
	return int(b[i]) << 24 | int(b[i + 1]) << 16 | int(b[i + 2]) << 8 | int(b[i + 3])
}

@(private = "file")
add_meta :: proc(out: ^[dynamic]Meta_Entry, key, label, value: string, allocator := context.allocator) {
	v := strings.trim_space(value)
	if v == "" {
		return
	}
	for e in out {
		if e.key == key {
			return // the first one wins: IFD0 over a later duplicate
		}
	}
	append(out, Meta_Entry{strings.clone(key, allocator), strings.clone(label, allocator), strings.clone(v, allocator)})
}

// latin1 turns PNG tEXt's ISO-8859-1 into UTF-8.
@(private = "file")
latin1 :: proc(b: []u8) -> string {
	sb := strings.builder_make(context.temp_allocator)
	for c in b {
		strings.write_rune(&sb, rune(c))
	}
	return strings.to_string(sb)
}

// image_metadata reads the metadata a file carries. It never decodes pixels and
// never fails: a file with none, or one it cannot parse, has none.
image_metadata :: proc(path: string, allocator := context.allocator) -> [dynamic]Meta_Entry {
	out := make([dynamic]Meta_Entry, allocator)
	data, err := os.read_entire_file_from_path(path, context.temp_allocator)
	if err != nil || len(data) < 8 {
		return out
	}
	switch {
	case len(data) > 8 && string(data[1:4]) == "PNG":
		png_meta(data, &out, allocator)
	case data[0] == 0xff && data[1] == 0xd8:
		jpeg_meta(data, &out, allocator)
	}
	return out
}

@(private = "file")
png_meta :: proc(b: []u8, out: ^[dynamic]Meta_Entry, allocator := context.allocator) {
	i := 8
	for i + 8 <= len(b) {
		n := be32(b, i)
		kind := string(b[i + 4:i + 8])
		if n < 0 || i + 8 + n > len(b) {
			return
		}
		d := b[i + 8:i + 8 + n]
		switch kind {
		case "IHDR":
			if n >= 13 {
				add_meta(out, "bit_depth", "Bit depth", fmt.tprintf("%d", d[8]), allocator)
				ct := ""
				switch d[9] {
				case 0:
					ct = "greyscale"
				case 2:
					ct = "RGB"
				case 3:
					ct = "palette"
				case 4:
					ct = "greyscale + alpha"
				case 6:
					ct = "RGBA"
				case:
					ct = fmt.tprintf("%d", d[9])
				}
				add_meta(out, "color_type", "Colour type", ct, allocator)
				add_meta(out, "interlaced", "Interlaced", d[12] == 1 ? "Adam7" : "no", allocator)
			}
		case "pHYs":
			if n >= 9 && d[8] == 1 {
				x := f64(be32(d, 0)) * 0.0254
				y := f64(be32(d, 4)) * 0.0254
				add_meta(out, "dpi", "Resolution", x == y ? fmt.tprintf("%.0f dpi", x) : fmt.tprintf("%.0f × %.0f dpi", x, y), allocator)
			}
		case "tEXt":
			if z := index_zero(d); z > 0 {
				key := latin1(d[:z])
				add_meta(out, fmt.tprintf("text:%s", key), key, latin1(d[z + 1:]), allocator)
			}
		case "iTXt":
			// keyword\0 compressed method lang\0 translated\0 text
			if z := index_zero(d); z > 0 && z + 3 <= len(d) && d[z + 1] == 0 {
				key := string(d[:z])
				rest := d[z + 3:]
				if l := index_zero(rest); l >= 0 {
					rest = rest[l + 1:]
					if t := index_zero(rest); t >= 0 {
						add_meta(out, fmt.tprintf("text:%s", key), key, string(rest[t + 1:]), allocator)
					}
				}
			}
		case "tIME":
			if n >= 7 {
				add_meta(out, "modified", "Modified (PNG)", fmt.tprintf("%04d-%02d-%02d %02d:%02d:%02d", be16(d, 0), d[2], d[3], d[4], d[5], d[6]), allocator)
			}
		case "gAMA":
			if n >= 4 {
				add_meta(out, "gamma", "Gamma", fmt.tprintf("%.5f", f64(be32(d, 0)) / 100000), allocator)
			}
		case "sRGB":
			add_meta(out, "color_space", "Colour space", "sRGB", allocator)
		case "iCCP":
			if z := index_zero(d); z > 0 {
				add_meta(out, "icc_profile", "ICC profile", string(d[:z]), allocator)
			}
		case "eXIf":
			tiff_meta(d, out, allocator)
		case "IEND":
			return
		}
		i += 12 + n
	}
}

@(private = "file")
index_zero :: proc(b: []u8) -> int {
	for c, i in b {
		if c == 0 {
			return i
		}
	}
	return -1
}

@(private = "file")
jpeg_meta :: proc(b: []u8, out: ^[dynamic]Meta_Entry, allocator := context.allocator) {
	i := 2
	for i + 4 <= len(b) {
		if b[i] != 0xff {
			return
		}
		marker := b[i + 1]
		if marker == 0xd8 || marker == 0x01 || (marker >= 0xd0 && marker <= 0xd7) {
			i += 2
			continue
		}
		if marker == 0xda || marker == 0xd9 {
			return // the scan: no more headers
		}
		n := be16(b, i + 2)
		if n < 2 || i + 2 + n > len(b) {
			return
		}
		d := b[i + 4:i + 2 + n]
		switch {
		case marker == 0xe0 && len(d) >= 12 && string(d[:5]) == "JFIF\x00":
			if d[7] == 1 {
				add_meta(out, "dpi", "Resolution", fmt.tprintf("%d dpi", be16(d, 8)), allocator)
			} else if d[7] == 2 {
				add_meta(out, "dpi", "Resolution", fmt.tprintf("%.0f dpi", f64(be16(d, 8)) * 2.54), allocator)
			}
		case marker == 0xe1 && len(d) > 6 && string(d[:6]) == "Exif\x00\x00":
			tiff_meta(d[6:], out, allocator)
		case marker == 0xe2 && len(d) > 12 && string(d[:12]) == "ICC_PROFILE\x00":
			add_meta(out, "icc_profile", "ICC profile", "embedded", allocator)
		case marker == 0xfe:
			add_meta(out, "comment", "Comment", string(d), allocator)
		case marker >= 0xc0 && marker <= 0xcf && marker != 0xc4 && marker != 0xc8 && marker != 0xcc && len(d) >= 6:
			add_meta(out, "bit_depth", "Bit depth", fmt.tprintf("%d", d[0]), allocator)
			add_meta(out, "progressive", "Progressive", marker == 0xc2 ? "yes" : "no", allocator)
			add_meta(out, "components", "Components", fmt.tprintf("%d", d[5]), allocator)
		}
		i += 2 + n
	}
}

// Tiff is a TIFF header's byte order over the bytes, which is all EXIF is.
@(private = "file")
Tiff :: struct {
	b:  []u8,
	le: bool,
}

@(private = "file")
t16 :: proc(t: Tiff, i: int) -> int {
	if i < 0 || i + 2 > len(t.b) {
		return 0
	}
	return t.le ? int(t.b[i]) | int(t.b[i + 1]) << 8 : be16(t.b, i)
}

@(private = "file")
t32 :: proc(t: Tiff, i: int) -> int {
	if i < 0 || i + 4 > len(t.b) {
		return 0
	}
	if t.le {
		return int(t.b[i]) | int(t.b[i + 1]) << 8 | int(t.b[i + 2]) << 16 | int(t.b[i + 3]) << 24
	}
	return be32(t.b, i)
}

@(private = "file")
Tag :: struct {
	tag, kind, count: int,
	at:               int, // where the value is: inline or at the offset
}

@(private = "file")
ifd_tags :: proc(t: Tiff, off: int) -> []Tag {
	out := make([dynamic]Tag, context.temp_allocator)
	n := t16(t, off)
	if off <= 0 || n <= 0 || n > 512 || off + 2 + n * 12 > len(t.b) {
		return nil
	}
	for k in 0 ..< n {
		e := off + 2 + k * 12
		tag := Tag{t16(t, e), t16(t, e + 2), t32(t, e + 4), e + 8}
		sizes := [?]int{0, 1, 1, 2, 4, 8, 1, 1, 2, 4, 8, 4, 8}
		unit := tag.kind < len(sizes) ? sizes[tag.kind] : 1
		if unit * tag.count > 4 {
			tag.at = t32(t, e + 8)
		}
		append(&out, tag)
	}
	return out[:]
}

@(private = "file")
tag_ascii :: proc(t: Tiff, g: Tag) -> string {
	if g.at < 0 || g.at + g.count > len(t.b) {
		return ""
	}
	s := string(t.b[g.at:g.at + g.count])
	if z := strings.index_byte(s, 0); z >= 0 {
		s = s[:z]
	}
	return s
}

@(private = "file")
tag_rational :: proc(t: Tiff, g: Tag, k := 0) -> f64 {
	at := g.at + k * 8
	d := t32(t, at + 4)
	if d == 0 {
		return 0
	}
	return f64(t32(t, at)) / f64(d)
}

@(private = "file")
tag_int :: proc(t: Tiff, g: Tag) -> int {
	return g.kind == 3 ? t16(t, g.at) : t32(t, g.at)
}

ORIENTATIONS :: [9]string {
	"",
	"normal",
	"mirrored",
	"rotated 180°",
	"mirrored vertically",
	"mirrored, rotated 90° anticlockwise",
	"rotated 90° clockwise",
	"mirrored, rotated 90° clockwise",
	"rotated 90° anticlockwise",
}

@(private = "file")
tiff_meta :: proc(b: []u8, out: ^[dynamic]Meta_Entry, allocator := context.allocator) {
	if len(b) < 8 {
		return
	}
	t := Tiff{b, b[0] == 'I'}
	if t16(t, 2) != 42 {
		return
	}
	exif_off, gps_off := 0, 0
	for g in ifd_tags(t, t32(t, 4)) {
		switch g.tag {
		case 0x010f:
			add_meta(out, "make", "Camera make", tag_ascii(t, g), allocator)
		case 0x0110:
			add_meta(out, "model", "Camera model", tag_ascii(t, g), allocator)
		case 0x010e:
			add_meta(out, "description", "Description", tag_ascii(t, g), allocator)
		case 0x0112:
			o := tag_int(t, g)
			names := ORIENTATIONS
			add_meta(out, "orientation", "Orientation", o >= 1 && o <= 8 ? names[o] : fmt.tprintf("%d", o), allocator)
		case 0x0131:
			add_meta(out, "software", "Software", tag_ascii(t, g), allocator)
		case 0x0132:
			add_meta(out, "date_time", "Date", tag_ascii(t, g), allocator)
		case 0x013b:
			add_meta(out, "artist", "Artist", tag_ascii(t, g), allocator)
		case 0x8298:
			add_meta(out, "copyright", "Copyright", tag_ascii(t, g), allocator)
		case 0x8769:
			exif_off = tag_int(t, g)
		case 0x8825:
			gps_off = tag_int(t, g)
		}
	}
	for g in ifd_tags(t, exif_off) {
		switch g.tag {
		case 0x9003:
			add_meta(out, "date_taken", "Taken", tag_ascii(t, g), allocator)
		case 0x829a:
			v := tag_rational(t, g)
			add_meta(out, "exposure", "Exposure", v > 0 && v < 1 ? fmt.tprintf("1/%.0f s", 1 / v) : fmt.tprintf("%g s", v), allocator)
		case 0x829d:
			add_meta(out, "f_number", "Aperture", fmt.tprintf("f/%.1f", tag_rational(t, g)), allocator)
		case 0x8827:
			add_meta(out, "iso", "ISO", fmt.tprintf("%d", tag_int(t, g)), allocator)
		case 0x920a:
			add_meta(out, "focal_length", "Focal length", fmt.tprintf("%.0f mm", tag_rational(t, g)), allocator)
		case 0xa434:
			add_meta(out, "lens", "Lens", tag_ascii(t, g), allocator)
		}
	}
	lat, lon: f64
	lat_ref, lon_ref := "", ""
	have_lat, have_lon := false, false
	for g in ifd_tags(t, gps_off) {
		switch g.tag {
		case 1:
			lat_ref = tag_ascii(t, g)
			if lat_ref == "" && g.count <= 4 {lat_ref = string(t.b[g.at:g.at + 1])}
		case 2:
			lat = tag_rational(t, g, 0) + tag_rational(t, g, 1) / 60 + tag_rational(t, g, 2) / 3600
			have_lat = true
		case 3:
			lon_ref = tag_ascii(t, g)
			if lon_ref == "" && g.count <= 4 {lon_ref = string(t.b[g.at:g.at + 1])}
		case 4:
			lon = tag_rational(t, g, 0) + tag_rational(t, g, 1) / 60 + tag_rational(t, g, 2) / 3600
			have_lon = true
		}
	}
	if have_lat && have_lon {
		if lat_ref == "S" {lat = -lat}
		if lon_ref == "W" {lon = -lon}
		add_meta(out, "gps", "Location", fmt.tprintf("%.6f, %.6f", lat, lon), allocator)
	}
}

// meta_value is one entry's value, or "".
meta_value :: proc(m: []Meta_Entry, key: string) -> string {
	for e in m {
		if e.key == key {
			return e.value
		}
	}
	return ""
}

// ---------------------------------------------------------------------------
// Pixels
// ---------------------------------------------------------------------------

// img_new is a blank image of a size, owned by the caller.
img_new :: proc(w, h: int, channels := 4, allocator := context.allocator) -> p.Image {
	return p.Image{px = make([]u32, max(0, w * h), allocator), w = w, h = h, source_channels = channels}
}

// fit_size scales (w, h) so the longest edge is `longest`, never up.
fit_size :: proc(w, h, longest: int) -> (int, int) {
	if max(w, h) <= longest || longest <= 0 {
		return w, h
	}
	if w >= h {
		return longest, max(1, h * longest / w)
	}
	return max(1, w * longest / h), longest
}

// downscale is the grid's thumbnail: a box filter to a longest edge, never
// enlarging. `image thumbnail` is this.
downscale :: proc(src: p.Image, longest: int) -> p.Image {
	if src.w <= 0 || src.h <= 0 {
		return {}
	}
	dw, dh := fit_size(src.w, src.h, longest)
	return resize_box(src, dw, dh)
}

img_thumbnail :: downscale

// resize_box is a box filter, which is the right answer for making an image
// smaller: it averages every source pixel that lands in the target cell, so
// fine detail turns into tone instead of aliasing into noise.
resize_box :: proc(src: p.Image, dw, dh: int) -> p.Image {
	if src.w <= 0 || src.h <= 0 || dw <= 0 || dh <= 0 {
		return {}
	}
	out := img_new(dw, dh, src.source_channels)
	for y in 0 ..< dh {
		y0 := y * src.h / dh
		y1 := max(y0 + 1, (y + 1) * src.h / dh)
		for x in 0 ..< dw {
			x0 := x * src.w / dw
			x1 := max(x0 + 1, (x + 1) * src.w / dw)
			ar, ag, ab, aa: u32
			n: u32
			for sy in y0 ..< y1 {
				row := src.px[sy * src.w:]
				for sx in x0 ..< x1 {
					v := row[sx]
					a := (v >> 24) & 0xff
					// Weight colour by alpha so a transparent border does not
					// drag the edge pixels toward black.
					ar += ((v >> 16) & 0xff) * a
					ag += ((v >> 8) & 0xff) * a
					ab += (v & 0xff) * a
					aa += a
					n += 1
				}
			}
			if n == 0 || aa == 0 {
				out.px[y * dw + x] = 0
				continue
			}
			out.px[y * dw + x] = ((aa / n) << 24) | ((ar / aa) << 16) | ((ag / aa) << 8) | (ab / aa)
		}
	}
	return out
}

// resize_bilinear is for making an image larger, where a box filter would
// only repeat pixels: each target pixel samples the four nearest sources.
resize_bilinear :: proc(src: p.Image, dw, dh: int) -> p.Image {
	if src.w <= 0 || src.h <= 0 || dw <= 0 || dh <= 0 {
		return {}
	}
	out := img_new(dw, dh, src.source_channels)
	for y in 0 ..< dh {
		fy := max(0, (f32(y) + 0.5) * f32(src.h) / f32(dh) - 0.5)
		y0 := min(int(fy), src.h - 1)
		y1 := min(y0 + 1, src.h - 1)
		ty := fy - f32(y0)
		for x in 0 ..< dw {
			fx := max(0, (f32(x) + 0.5) * f32(src.w) / f32(dw) - 0.5)
			x0 := min(int(fx), src.w - 1)
			x1 := min(x0 + 1, src.w - 1)
			tx := fx - f32(x0)
			c00, c10 := src.px[y0 * src.w + x0], src.px[y0 * src.w + x1]
			c01, c11 := src.px[y1 * src.w + x0], src.px[y1 * src.w + x1]
			v: u32
			for shift in ([?]u32{24, 16, 8, 0}) {
				top := chan(c00, shift) * (1 - tx) + chan(c10, shift) * tx
				bot := chan(c01, shift) * (1 - tx) + chan(c11, shift) * tx
				v |= u32(clamp(top * (1 - ty) + bot * ty + 0.5, 0, 255)) << shift
			}
			out.px[y * dw + x] = v
		}
	}
	return out
}

@(private = "file")
chan :: proc(c, s: u32) -> f32 {
	return f32((c >> s) & 0xff)
}

// img_resize picks the filter: box when every edge shrinks, bilinear when any
// grows.
img_resize :: proc(src: p.Image, dw, dh: int) -> p.Image {
	if dw <= src.w && dh <= src.h {
		return resize_box(src, dw, dh)
	}
	return resize_bilinear(src, dw, dh)
}

// img_crop copies a rectangle out, clipped to the image.
img_crop :: proc(src: p.Image, x, y, w, h: int) -> (out: p.Image, ok: bool) {
	x0, y0 := max(0, x), max(0, y)
	x1, y1 := min(src.w, x + w), min(src.h, y + h)
	if x1 <= x0 || y1 <= y0 {
		return {}, false
	}
	out = img_new(x1 - x0, y1 - y0, src.source_channels)
	for row in y0 ..< y1 {
		copy(out.px[(row - y0) * out.w:][:out.w], src.px[row * src.w + x0:][:out.w])
	}
	return out, true
}

// img_flip mirrors left-right, or top-bottom.
img_flip :: proc(src: p.Image, vertical: bool) -> p.Image {
	out := img_new(src.w, src.h, src.source_channels)
	for y in 0 ..< src.h {
		for x in 0 ..< src.w {
			sx, sy := vertical ? x : src.w - 1 - x, vertical ? src.h - 1 - y : y
			out.px[y * src.w + x] = src.px[sy * src.w + sx]
		}
	}
	return out
}

// rotate90 turns an image a quarter turn clockwise. palmy's image element has
// no transform, so a viewer that rotates has to produce the rotated pixels.
rotate90 :: proc(src: p.Image) -> p.Image {
	if src.w <= 0 || src.h <= 0 {
		return {}
	}
	out := p.Image {
		px              = make([]u32, src.w * src.h),
		w               = src.h,
		h               = src.w,
		source_channels = src.source_channels,
	}
	for y in 0 ..< src.h {
		row := src.px[y * src.w:]
		// (x, y) -> (h-1-y, x)
		dx := src.h - 1 - y
		for x in 0 ..< src.w {
			out.px[x * out.w + dx] = row[x]
		}
	}
	return out
}

// rotated builds the image for a quarter-turn count, 0 returning the original
// untouched so the common case allocates nothing. The viewer's R key and
// `image rotate` are both this.
rotated :: proc(src: p.Image, quarters: int) -> (out: p.Image, owned: bool) {
	q := ((quarters % 4) + 4) % 4
	if q == 0 || src.w <= 0 {
		return src, false
	}
	cur := src
	mine := false
	for _ in 0 ..< q {
		nxt := rotate90(cur)
		if mine {
			p.image_destroy(&cur)
		}
		cur = nxt
		mine = true
	}
	return cur, mine
}

// ---------------------------------------------------------------------------
// Encoding
// ---------------------------------------------------------------------------

// copy_path is where the viewer's Ctrl-S puts a copy of `src` turned by
// `quarters`: beside it, as PNG, under a name that is free.
copy_path :: proc(src: string, quarters: int) -> string {
	q := ((quarters % 4) + 4) % 4
	name := base_of(src)
	stem := name
	if dot := strings.last_index_byte(name, '.'); dot > 0 {
		stem = name[:dot]
	}
	tag := q == 0 ? "copy" : fmt.tprintf("rotated %d°", q * 90)
	dir := dir_of(src)
	cand := fmt.tprintf("%s/%s (%s).png", dir, stem, tag)
	for n := 2; os.exists(cand) && n < 10_000; n += 1 {
		cand = fmt.tprintf("%s/%s (%s %d).png", dir, stem, tag, n)
	}
	return cand
}

ENCODE_FORMATS :: [?]string{"png", "jpg", "bmp", "tga"}
DECODE_FORMATS :: [?]string{"png", "jpg", "bmp", "gif", "tga", "psd", "hdr", "pnm"}

// encode_format is the writer for a path's extension, or "".
encode_format :: proc(path: string) -> string {
	switch ext_of(path) {
	case "png":
		return "png"
	case "jpg", "jpeg", "jfif":
		return "jpg"
	case "bmp":
		return "bmp"
	case "tga":
		return "tga"
	}
	return ""
}

// img_save writes an image in the format its extension names. JPEG and BMP
// have no alpha here, so transparent pixels are laid over white first — the
// way they would look on a page — rather than coming out black.
img_save :: proc(img: p.Image, path: string, quality := 90) -> (ok: bool, why: string) {
	format := encode_format(path)
	if format == "" {
		return false, fmt.tprintf("cannot write .%s; use one of png, jpg, bmp, tga", ext_of(path))
	}
	if img.w <= 0 || img.h <= 0 {
		return false, "there is no image to write"
	}
	opaque := format == "jpg" || format == "bmp"
	comp := opaque ? 3 : 4
	buf := make([]u8, img.w * img.h * comp, context.temp_allocator)
	for v, i in img.px[:img.w * img.h] {
		r, g, b, a := (v >> 16) & 0xff, (v >> 8) & 0xff, v & 0xff, (v >> 24) & 0xff
		if opaque {
			r = (r * a + 255 * (255 - a)) / 255
			g = (g * a + 255 * (255 - a)) / 255
			b = (b * a + 255 * (255 - a)) / 255
			buf[i * 3 + 0], buf[i * 3 + 1], buf[i * 3 + 2] = u8(r), u8(g), u8(b)
		} else {
			buf[i * 4 + 0], buf[i * 4 + 1], buf[i * 4 + 2], buf[i * 4 + 3] = u8(r), u8(g), u8(b), u8(a)
		}
	}
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	w, h := i32(img.w), i32(img.h)
	res: i32
	switch format {
	case "png":
		res = stbi.write_png(cpath, w, h, i32(comp), raw_data(buf), w * i32(comp))
	case "jpg":
		res = stbi.write_jpg(cpath, w, h, i32(comp), raw_data(buf), i32(clamp(quality, 1, 100)))
	case "bmp":
		res = stbi.write_bmp(cpath, w, h, i32(comp), raw_data(buf))
	case "tga":
		res = stbi.write_tga(cpath, w, h, i32(comp), raw_data(buf))
	}
	if res == 0 {
		return false, fmt.tprintf("could not write %s", path)
	}
	return true, ""
}
