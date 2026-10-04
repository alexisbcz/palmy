package palmy

import "core:os"
import "core:path/filepath"
import "core:strings"
import stbi "vendor:stb/image"

// ---------------------------------------------------------------------------
// Colour-bitmap emoji (CBDT/CBLC).
//
// The fallback chain cannot help here. The only emoji font normally installed
// on Linux is NotoColorEmoji, and it has no `glyf` table, no `loca` and no
// `CFF ` — there are no outlines in the file at all. Its glyphs are PNGs, one
// per emoji, indexed by two tables Apple invented for `sbix`-era bitmap fonts
// and Google standardised as CBLC/CBDT:
//
//	CBLC  one bitmapSizeTable per strike (NotoColorEmoji ships one, 109ppem),
//	      each pointing at index subtables that map a *range* of glyph ids to
//	      offsets into CBDT.
//	CBDT  the image data: a few bytes of per-glyph metrics, a length, and a PNG.
//
// stb_truetype refuses the file outright, so this is a small sfnt reader of its
// own: the table directory, `cmap` (formats 4 and 12), `hmtx` for advances, and
// the two bitmap tables. The PNGs go through the stb_image already vendored for
// `load_image`, get box-filtered down to the text size once, and are cached.
//
// What this does not do is shape. Without GSUB there is no way to join
// `U+1F468 U+200D U+1F4BB` into one "man technologist" glyph, so a ZWJ sequence
// renders as its parts and a skin-tone modifier renders as a colour swatch
// after the base emoji. The joiners and variation selectors themselves draw
// nothing (see `is_ignorable`), so the result is readable rather than a row of
// boxes — which is what it was before.
// ---------------------------------------------------------------------------

@(private)
Emoji_Key :: struct {
	cp:   rune,
	size: u16, // target height in whole pixels
}

@(private)
Emoji_Bitmap :: struct {
	img: Image,
	// Metrics in strike pixels, i.e. at `ppem` pixels per em. The destination
	// rectangle is derived from these and the exact text size, so the cached
	// image can be quantised without the placement being quantised with it.
	bx, by: f32,
	bw, bh: f32,
	ok:     bool,
}

@(private)
Emoji_Range :: struct {
	first, last:  u32, // glyph ids, inclusive
	index_format: u16,
	image_format: u16,
	image_offset: u32, // into CBDT
	array_off:    int, // the index arrays, absolute in the file
	image_size:   u32, // index formats 2 and 5: every glyph the same size
	m_height:     f32, // index formats 2 and 5 carry the metrics themselves
	m_width:      f32,
	m_bx, m_by:   f32,
}

Emoji_Font :: struct {
	data: []u8,
	path: string,
	ok:   bool,

	upem:         f32,
	num_hmetrics: u32,
	hmtx:         int,
	cmap4:        int, // 0 when absent
	cmap12:       int,
	cbdt:         int,

	ppem:   f32,
	ranges: [dynamic]Emoji_Range,

	cache: map[Emoji_Key]Emoji_Bitmap,
}

// Emoji fonts, most preferred first. PALMY_FONT_EMOJI overrides.
@(private)
EMOJI_CANDIDATES := [?]string {
	"NotoColorEmoji",
	"NotoColorEmoji-Regular",
	"Twemoji",
	"TwemojiMozilla",
	"OpenMoji-color-cbdt",
	"OpenMoji-Color",
	"AppleColorEmoji",
	"SegoeUIEmoji",
	"seguiemj",
	"JoyPixels",
	"EmojiOneColor",
}

@(private)
emoji_init :: proc(e: ^Emoji_Font, files: [dynamic]string) {
	e.cache = make(map[Emoji_Key]Emoji_Bitmap)
	e.ranges = make([dynamic]Emoji_Range)

	if path := os.get_env("PALMY_FONT_EMOJI", context.temp_allocator); path != "" {
		if emoji_load(e, path) {
			return
		}
	}
	for want in EMOJI_CANDIDATES {
		for path in files {
			if filepath.stem(path) != want {
				continue
			}
			if emoji_load(e, path) {
				return
			}
		}
	}
}

// load_emoji_font pins the colour-bitmap emoji font, overriding discovery.
load_emoji_font :: proc(f: ^Fonts, path: string) -> bool {
	emoji_destroy(&f.emoji)
	f.emoji.cache = make(map[Emoji_Key]Emoji_Bitmap)
	f.emoji.ranges = make([dynamic]Emoji_Range)
	return emoji_load(&f.emoji, path)
}

// emoji_font_path reports which file backs colour emoji, or "" for none.
emoji_font_path :: proc(f: ^Fonts) -> string {
	return f.emoji.ok ? f.emoji.path : ""
}

@(private)
emoji_destroy :: proc(e: ^Emoji_Font) {
	for _, bm in e.cache {
		delete(bm.img.px)
	}
	delete(e.cache)
	delete(e.ranges)
	if e.data != nil {
		delete(e.data)
		e.data = nil
	}
	if e.path != "" {
		delete(e.path)
		e.path = ""
	}
	e.ok = false
}

// ---------------------------------------------------------------------------
// Big-endian readers. Every one is bounds-checked and returns zero past the
// end, so a truncated or hostile font file produces no glyphs rather than a
// read out of bounds.
// ---------------------------------------------------------------------------

@(private)
sfnt_u8 :: #force_inline proc "contextless" (d: []u8, o: int) -> u32 {
	if o < 0 || o >= len(d) {
		return 0
	}
	return u32(d[o])
}

@(private)
sfnt_u16 :: #force_inline proc "contextless" (d: []u8, o: int) -> u32 {
	if o < 0 || o + 2 > len(d) {
		return 0
	}
	return u32(d[o]) << 8 | u32(d[o + 1])
}

@(private)
sfnt_i8 :: #force_inline proc "contextless" (d: []u8, o: int) -> i32 {
	return i32(i8(sfnt_u8(d, o)))
}

@(private)
sfnt_u32 :: #force_inline proc "contextless" (d: []u8, o: int) -> u32 {
	if o < 0 || o + 4 > len(d) {
		return 0
	}
	return u32(d[o]) << 24 | u32(d[o + 1]) << 16 | u32(d[o + 2]) << 8 | u32(d[o + 3])
}

// ---------------------------------------------------------------------------
// Loading
// ---------------------------------------------------------------------------

@(private)
emoji_load :: proc(e: ^Emoji_Font, path: string) -> bool {
	data, rerr := os.read_entire_file_from_path(path, context.allocator)
	if rerr != nil {
		return false
	}
	e.data = data
	if !emoji_parse(e) {
		delete(e.data)
		e.data = nil
		clear(&e.ranges)
		return false
	}
	e.path = strings.clone(path)
	e.ok = true
	return true
}

@(private)
emoji_parse :: proc(e: ^Emoji_Font) -> bool {
	d := e.data
	if len(d) < 12 {
		return false
	}
	// A collection begins with 'ttcf' and a list of font offsets; take the
	// first font, the same way face_load does.
	base := 0
	if string(d[0:4]) == "ttcf" {
		base = int(sfnt_u32(d, 12))
	}
	num := int(sfnt_u16(d, base + 4))
	if num <= 0 || num > 512 {
		return false
	}

	find :: proc(d: []u8, base, num: int, tag: string) -> (off, length: int) {
		for i in 0 ..< num {
			rec := base + 12 + 16 * i
			if rec + 16 > len(d) {
				return 0, 0
			}
			if string(d[rec:rec + 4]) == tag {
				return int(sfnt_u32(d, rec + 8)), int(sfnt_u32(d, rec + 12))
			}
		}
		return 0, 0
	}

	cblc, _ := find(d, base, num, "CBLC")
	cbdt, _ := find(d, base, num, "CBDT")
	if cblc == 0 || cbdt == 0 {
		return false
	}
	e.cbdt = cbdt

	head, _ := find(d, base, num, "head")
	if head == 0 {
		return false
	}
	e.upem = f32(sfnt_u16(d, head + 18))
	if e.upem <= 0 {
		e.upem = 1000
	}

	hhea, _ := find(d, base, num, "hhea")
	e.num_hmetrics = sfnt_u16(d, hhea + 34)
	e.hmtx, _ = find(d, base, num, "hmtx")

	cmap, _ := find(d, base, num, "cmap")
	if cmap == 0 {
		return false
	}
	ntab := int(sfnt_u16(d, cmap + 2))
	for i in 0 ..< ntab {
		rec := cmap + 4 + 8 * i
		off := cmap + int(sfnt_u32(d, rec + 4))
		switch sfnt_u16(d, off) {
		case 12:
			e.cmap12 = off
		case 4:
			if e.cmap4 == 0 {
				e.cmap4 = off
			}
		}
	}
	if e.cmap4 == 0 && e.cmap12 == 0 {
		return false
	}

	// Pick the largest strike: emoji are nearly always scaled down, and a
	// box filter down from a bigger bitmap beats interpolating up from a
	// smaller one.
	nsizes := int(sfnt_u32(d, cblc + 4))
	if nsizes <= 0 || nsizes > 64 {
		return false
	}
	best := -1
	best_ppem := u32(0)
	for s in 0 ..< nsizes {
		b := cblc + 8 + 48 * s
		ppem := sfnt_u8(d, b + 45)
		if sfnt_u8(d, b + 46) != 32 {
			continue // not a colour strike
		}
		if ppem > best_ppem {
			best, best_ppem = s, ppem
		}
	}
	if best < 0 {
		return false
	}
	e.ppem = f32(best_ppem)

	b := cblc + 8 + 48 * best
	ist_array := cblc + int(sfnt_u32(d, b + 0))
	n_ist := int(sfnt_u32(d, b + 8))
	if n_ist <= 0 || n_ist > 1 << 16 {
		return false
	}

	for k in 0 ..< n_ist {
		rec := ist_array + 8 * k
		first := sfnt_u16(d, rec + 0)
		last := sfnt_u16(d, rec + 2)
		add := int(sfnt_u32(d, rec + 4))
		hdr := ist_array + add
		r := Emoji_Range {
			first        = first,
			last         = last,
			index_format = u16(sfnt_u16(d, hdr + 0)),
			image_format = u16(sfnt_u16(d, hdr + 2)),
			image_offset = sfnt_u32(d, hdr + 4),
			array_off    = hdr + 8,
		}
		switch r.index_format {
		case 1, 3:
			// offsetArray follows the header directly.
		case 2:
			r.image_size = sfnt_u32(d, hdr + 8)
			r.m_height = f32(sfnt_u8(d, hdr + 12))
			r.m_width = f32(sfnt_u8(d, hdr + 13))
			r.m_bx = f32(sfnt_i8(d, hdr + 14))
			r.m_by = f32(sfnt_i8(d, hdr + 15))
		case:
			// Formats 4 and 5 are sparse glyph-id lists. No shipping colour
			// emoji font uses them; skipping the range is better than
			// mis-reading it.
			continue
		}
		append(&e.ranges, r)
	}
	return len(e.ranges) > 0
}

// ---------------------------------------------------------------------------
// Lookup
// ---------------------------------------------------------------------------

@(private)
emoji_glyph :: proc(e: ^Emoji_Font, r: rune) -> u32 {
	if !e.ok || r <= 0 {
		return 0
	}
	d := e.data
	cp := u32(r)

	if e.cmap12 != 0 {
		n := int(sfnt_u32(d, e.cmap12 + 12))
		lo, hi := 0, n - 1
		for lo <= hi {
			mid := (lo + hi) / 2
			g := e.cmap12 + 16 + 12 * mid
			start := sfnt_u32(d, g + 0)
			end := sfnt_u32(d, g + 4)
			switch {
			case cp < start:
				hi = mid - 1
			case cp > end:
				lo = mid + 1
			case:
				return sfnt_u32(d, g + 8) + (cp - start)
			}
		}
	}

	if e.cmap4 != 0 && cp <= 0xffff {
		seg2 := int(sfnt_u16(d, e.cmap4 + 6))
		ends := e.cmap4 + 14
		starts := ends + seg2 + 2
		deltas := starts + seg2
		ranges := deltas + seg2
		for i := 0; i < seg2 / 2; i += 1 {
			if cp > sfnt_u16(d, ends + 2 * i) {
				continue
			}
			start := sfnt_u16(d, starts + 2 * i)
			if cp < start {
				break
			}
			ro := sfnt_u16(d, ranges + 2 * i)
			if ro == 0 {
				return (cp + sfnt_u16(d, deltas + 2 * i)) & 0xffff
			}
			g := sfnt_u16(d, ranges + 2 * i + int(ro) + 2 * int(cp - start))
			if g == 0 {
				return 0
			}
			return (g + sfnt_u16(d, deltas + 2 * i)) & 0xffff
		}
	}
	return 0
}

@(private)
emoji_range_for :: proc(e: ^Emoji_Font, gid: u32) -> ^Emoji_Range {
	for &r in e.ranges {
		if gid >= r.first && gid <= r.last {
			return &r
		}
	}
	return nil
}

// emoji_has reports whether the colour font can draw this codepoint. It is the
// last thing `resolve_rune` tries, so a codepoint with both a text and an emoji
// presentation keeps whichever outline face carries it.
@(private)
emoji_has :: proc(e: ^Emoji_Font, r: rune) -> bool {
	if !e.ok {
		return false
	}
	gid := emoji_glyph(e, r)
	if gid == 0 {
		return false
	}
	return emoji_range_for(e, gid) != nil
}

// emoji_advance is the font's own advance for this codepoint, in pixels.
@(private)
emoji_advance :: proc(e: ^Emoji_Font, r: rune, size: f32) -> f32 {
	if !e.ok || e.hmtx == 0 || e.num_hmetrics == 0 {
		return size
	}
	gid := emoji_glyph(e, r)
	i := min(gid, e.num_hmetrics - 1)
	units := f32(sfnt_u16(e.data, e.hmtx + 4 * int(i)))
	if units <= 0 {
		return size
	}
	return units / e.upem * size
}

// ---------------------------------------------------------------------------
// Rasterising
// ---------------------------------------------------------------------------

@(private)
emoji_bitmap :: proc(e: ^Emoji_Font, r: rune, size: f32) -> ^Emoji_Bitmap {
	key := Emoji_Key{cp = r, size = u16(clamp(size + 0.5, 1, 4096))}
	if bm, found := &e.cache[key]; found {
		return bm
	}
	// Decoded once per (codepoint, whole-pixel size) and then kept, miss or
	// hit: a glyph the font cannot draw must not be re-decoded every frame.
	e.cache[key] = emoji_decode(e, r, key)
	return &e.cache[key]
}

@(private)
emoji_decode :: proc(e: ^Emoji_Font, r: rune, key: Emoji_Key) -> (bm: Emoji_Bitmap) {
	gid := emoji_glyph(e, r)
	rng := emoji_range_for(e, gid)
	if rng == nil {
		return
	}
	d := e.data

	// Where in CBDT this glyph's record starts, and how long it is.
	start, end: u32
	switch rng.index_format {
	case 1:
		i := int(gid - rng.first)
		start = sfnt_u32(d, rng.array_off + 4 * i)
		end = sfnt_u32(d, rng.array_off + 4 * (i + 1))
	case 3:
		i := int(gid - rng.first)
		start = sfnt_u16(d, rng.array_off + 2 * i)
		end = sfnt_u16(d, rng.array_off + 2 * (i + 1))
	case 2:
		start = rng.image_size * (gid - rng.first)
		end = start + rng.image_size
	}
	if end <= start {
		return
	}

	p := e.cbdt + int(rng.image_offset) + int(start)
	png_at, png_len: int
	switch rng.image_format {
	case 17: // smallGlyphMetrics, then a length and a PNG
		bm.bh = f32(sfnt_u8(d, p + 0))
		bm.bw = f32(sfnt_u8(d, p + 1))
		bm.bx = f32(sfnt_i8(d, p + 2))
		bm.by = f32(sfnt_i8(d, p + 3))
		png_len = int(sfnt_u32(d, p + 5))
		png_at = p + 9
	case 18: // bigGlyphMetrics, then a length and a PNG
		bm.bh = f32(sfnt_u8(d, p + 0))
		bm.bw = f32(sfnt_u8(d, p + 1))
		bm.bx = f32(sfnt_i8(d, p + 2))
		bm.by = f32(sfnt_i8(d, p + 3))
		png_len = int(sfnt_u32(d, p + 8))
		png_at = p + 12
	case 19: // the metrics live in the index subtable
		bm.bh, bm.bw = rng.m_height, rng.m_width
		bm.bx, bm.by = rng.m_bx, rng.m_by
		png_len = int(sfnt_u32(d, p + 0))
		png_at = p + 4
	case:
		return
	}
	if png_len <= 0 || png_at < 0 || png_at + png_len > len(d) {
		return
	}

	sw, sh, comp: i32
	raw := stbi.load_from_memory(raw_data(d[png_at:]), i32(png_len), &sw, &sh, &comp, 4)
	if raw == nil || sw <= 0 || sh <= 0 {
		return
	}
	defer stbi.image_free(raw)
	src := raw[:int(sw) * int(sh) * 4]

	// The metrics are in strike pixels and the PNG should match them, but a
	// few fonts round differently; trust the PNG for the shape and keep the
	// metrics' aspect by scaling them to it.
	if bm.bw <= 0 || bm.bh <= 0 {
		bm.bw, bm.bh = f32(sw), f32(sh)
		bm.by = bm.bh
	}

	// Target size at this text size. Box-filter down to it once, so a 109px
	// bitmap drawn at 14px is averaged rather than point-sampled; leave an
	// upscale to draw_image, whose bilinear filter is the better choice there.
	k := f32(key.size) / e.ppem
	dw := max(1, int(bm.bw * k + 0.5))
	dh := max(1, int(bm.bh * k + 0.5))
	if dw >= int(sw) || dh >= int(sh) {
		dw, dh = int(sw), int(sh)
	}

	bm.img.w, bm.img.h = dw, dh
	bm.img.source_channels = int(comp)
	bm.img.px = box_filter_rgba(src, int(sw), int(sh), dw, dh)
	bm.ok = true
	return
}

// box_filter_rgba averages each destination pixel's whole source footprint,
// weighting colour by alpha so transparent pixels do not bleed into opaque
// neighbours. Point-sampling an 8x minification is where emoji turn to confetti.
@(private)
box_filter_rgba :: proc(src: []u8, sw, sh, dw, dh: int) -> []u32 {
	out := make([]u32, dw * dh)
	for dy in 0 ..< dh {
		y0 := dy * sh / dh
		y1 := max(y0 + 1, (dy + 1) * sh / dh)
		for dx in 0 ..< dw {
			x0 := dx * sw / dw
			x1 := max(x0 + 1, (dx + 1) * sw / dw)
			sr, sg, sb, sa, n: u32
			for sy in y0 ..< y1 {
				for sx in x0 ..< x1 {
					i := (sy * sw + sx) * 4
					if i + 4 > len(src) {
						continue
					}
					a := u32(src[i + 3])
					sr += u32(src[i + 0]) * a
					sg += u32(src[i + 1]) * a
					sb += u32(src[i + 2]) * a
					sa += a
					n += 1
				}
			}
			if n == 0 {
				continue
			}
			a := sa / n
			r, g, b: u32
			if sa > 0 {
				r, g, b = sr / sa, sg / sa, sb / sa
			}
			out[dy * dw + dx] = (a << 24) | (min(r, 255) << 16) | (min(g, 255) << 8) | min(b, 255)
		}
	}
	return out
}

// emoji_draw blits one colour emoji with its left edge at `pen` and its
// baseline at `baseline`.
@(private)
emoji_draw :: proc(c: ^Canvas, e: ^Emoji_Font, r: rune, pen, baseline, size: f32, alpha: u8) {
	if !e.ok || alpha == 0 {
		return
	}
	bm := emoji_bitmap(e, r, size)
	if bm == nil || !bm.ok || bm.img.w <= 0 {
		return
	}
	k := size / e.ppem
	dst := Rect {
		pen + bm.bx * k,
		baseline - bm.by * k,
		bm.bw * k,
		bm.bh * k,
	}
	draw_image(c, bm.img, dst, f32(alpha) / 255)
}

// emoji_strike_ppem reports the pixel size of the strike in use, for
// diagnostics and tests. Zero means no emoji font was found.
emoji_strike_ppem :: proc(f: ^Fonts) -> f32 {
	return f.emoji.ok ? f.emoji.ppem : 0
}

// ---------------------------------------------------------------------------
// Presentation
//
// Whether a codepoint *wants* to be an emoji is a property of the codepoint,
// not of the fonts installed. U+2600 ☀ and U+2764 ❤ are text by default and
// should keep whatever outline face carries them; U+1F600 😀 and U+1F44D 👍 are
// emoji by default, and must not be served by the line-art copy that a symbol
// fallback such as Symbola happens to have — which is exactly what happened
// before this table existed.
//
// Either default can be overridden in the string: a trailing U+FE0F asks for
// the emoji form, U+FE0E for the text form. That is why those two runes are
// looked for one rune ahead rather than simply skipped.
// ---------------------------------------------------------------------------

// Unicode's Emoji_Presentation=Yes set, as ranges. Sourced from emoji-data.txt;
// the long tail above U+1F000 is nearly all of the plane, so it is listed as a
// handful of spans rather than hundreds of singletons.
@(private)
EMOJI_PRESENTATION := [?][2]rune {
	{0x231a, 0x231b},
	{0x23e9, 0x23ec},
	{0x23f0, 0x23f0},
	{0x23f3, 0x23f3},
	{0x25fd, 0x25fe},
	{0x2614, 0x2615},
	{0x2648, 0x2653},
	{0x267f, 0x267f},
	{0x2693, 0x2693},
	{0x26a1, 0x26a1},
	{0x26aa, 0x26ab},
	{0x26bd, 0x26be},
	{0x26c4, 0x26c5},
	{0x26ce, 0x26ce},
	{0x26d4, 0x26d4},
	{0x26ea, 0x26ea},
	{0x26f2, 0x26f3},
	{0x26f5, 0x26f5},
	{0x26fa, 0x26fa},
	{0x26fd, 0x26fd},
	{0x2705, 0x2705},
	{0x270a, 0x270b},
	{0x2728, 0x2728},
	{0x274c, 0x274c},
	{0x274e, 0x274e},
	{0x2753, 0x2755},
	{0x2757, 0x2757},
	{0x2795, 0x2797},
	{0x27b0, 0x27b0},
	{0x27bf, 0x27bf},
	{0x2b1b, 0x2b1c},
	{0x2b50, 0x2b50},
	{0x2b55, 0x2b55},
	{0x1f004, 0x1f004},
	{0x1f0cf, 0x1f0cf},
	{0x1f18e, 0x1f18e},
	{0x1f191, 0x1f19a},
	{0x1f1e6, 0x1f1ff},
	{0x1f201, 0x1f201},
	{0x1f21a, 0x1f21a},
	{0x1f22f, 0x1f22f},
	{0x1f232, 0x1f236},
	{0x1f238, 0x1f23a},
	{0x1f250, 0x1f251},
	{0x1f300, 0x1f320},
	{0x1f32d, 0x1f335},
	{0x1f337, 0x1f37c},
	{0x1f37e, 0x1f393},
	{0x1f3a0, 0x1f3ca},
	{0x1f3cf, 0x1f3d3},
	{0x1f3e0, 0x1f3f0},
	{0x1f3f4, 0x1f3f4},
	{0x1f3f8, 0x1f43e},
	{0x1f440, 0x1f440},
	{0x1f442, 0x1f4fc},
	{0x1f4ff, 0x1f53d},
	{0x1f54b, 0x1f54e},
	{0x1f550, 0x1f567},
	{0x1f57a, 0x1f57a},
	{0x1f595, 0x1f596},
	{0x1f5a4, 0x1f5a4},
	{0x1f5fb, 0x1f64f},
	{0x1f680, 0x1f6c5},
	{0x1f6cc, 0x1f6cc},
	{0x1f6d0, 0x1f6d2},
	{0x1f6d5, 0x1f6d7},
	{0x1f6dc, 0x1f6df},
	{0x1f6eb, 0x1f6ec},
	{0x1f6f4, 0x1f6fc},
	{0x1f7e0, 0x1f7eb},
	{0x1f7f0, 0x1f7f0},
	{0x1f90c, 0x1f93a},
	{0x1f93c, 0x1f945},
	{0x1f947, 0x1f9ff},
	{0x1fa70, 0x1fa7c},
	{0x1fa80, 0x1fa89},
	{0x1fa8f, 0x1fac6},
	{0x1face, 0x1fadc},
	{0x1fadf, 0x1fae9},
	{0x1faf0, 0x1faf8},
}

// is_emoji_presentation reports whether this codepoint defaults to the colour
// emoji form. Latin, CJK and every punctuation mark exit on the first compare.
@(private)
is_emoji_presentation :: proc "contextless" (r: rune) -> bool {
	if r < 0x231a {
		return false
	}
	for span in EMOJI_PRESENTATION {
		if r < span[0] {
			return false // the table is sorted
		}
		if r <= span[1] {
			return true
		}
	}
	return false
}

// VS16 (U+FE0F) and VS15 (U+FE0E) are three bytes each in UTF-8, so the
// lookahead is a byte compare rather than a decode — this sits in the inner
// loop of every measurement.
@(private)
VS16_UTF8 :: "️"
@(private)
VS15_UTF8 :: "︎"

@(private)
emoji_requested :: proc "contextless" (s: string, at: int) -> bool {
	return at + 3 <= len(s) && s[at] == 0xef && s[at + 1] == 0xb8 && s[at + 2] == 0x8f
}

@(private)
text_requested :: proc "contextless" (s: string, at: int) -> bool {
	return at + 3 <= len(s) && s[at] == 0xef && s[at + 1] == 0xb8 && s[at + 2] == 0x8e
}

// prefers_emoji decides, for the rune at byte `at`, whether the colour font
// should be consulted before the outline fallback chain.
@(private)
prefers_emoji :: proc "contextless" (s: string, at: int, r: rune) -> bool {
	if r < 0x231a {
		return false // no codepoint below this has an emoji form at all
	}
	next := at + rune_len(r)
	if text_requested(s, next) {
		return false
	}
	return is_emoji_presentation(r) || emoji_requested(s, next)
}
