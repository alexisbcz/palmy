package palmy

import "core:fmt"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:strings"
import ef "vendor:stb/easy_font"
import tt "vendor:stb/truetype"

Font_Family :: enum u8 {
	Sans,
	Mono,
}

// Font_Weight covers the four weights real interfaces use. shadcn leans on
// medium and semibold constantly, and collapsing them onto regular/bold is
// visible immediately in a side-by-side.
Font_Weight :: enum u8 {
	Regular,  // 400
	Medium,   // 500
	Semibold, // 600
	Bold,     // 700
}

@(private)
Face :: struct {
	data:       []u8,
	info:       tt.fontinfo,
	ok:         bool,
	synth_bold: bool,
	path:       string,
}

@(private)
Glyph_Key :: struct {
	family: Font_Family,
	weight: Font_Weight,
	// Size in eighths of a pixel. Rounding to whole pixels would rasterise
	// `text-[0.8rem]` (12.8px) at 13px, making every glyph 1.5% too large and
	// disagreeing with the width the layout already measured.
	size_q: u16,
	phase:  u8, // horizontal subpixel phase, see SUBPIXEL_PHASES
	cp:     rune,
}

@(private)
SIZE_STEPS :: 8

// Browsers position glyphs at subpixel offsets. Rasterizing a few phases per
// glyph and picking the nearest reproduces that, instead of snapping every pen
// position to a whole pixel and drifting against the reference.
SUBPIXEL_PHASES :: 3

@(private)
Glyph :: struct {
	mask:    []u8,
	w, h:    int,
	xoff:    int,
	yoff:    int,
	advance: f32,
}

// Fonts owns the loaded faces and a cache of rasterized glyphs, keyed by
// family, weight, integer pixel size and codepoint.
Fonts :: struct {
	faces:  [Font_Family][Font_Weight]Face,
	glyphs: map[Glyph_Key]Glyph,
	any:    bool,

	// Kerning is on by default because it is better typography. It can be
	// turned off to match a renderer that has it disabled — CSS
	// `font-kerning: none`, for instance.
	no_kerning: bool,
}

// Metrics describes a font at one size, in pixels.
Metrics :: struct {
	ascent:  f32,
	descent: f32,
	line:    f32,
}

// Candidate font files, most preferred first. Anything installed on a typical
// desktop will match one of these; PALMY_FONT and PALMY_FONT_MONO override.
@(private)
SANS_CANDIDATES := [?]string {
	"Inter-Regular",
	"InterVariable",
	"Inter_18pt-Regular",
	"SourceSans3-Regular",
	"Cantarell-Regular",
	"DejaVuSans",
	"NotoSans-Regular",
	"Roboto-Regular",
	"LiberationSans-Regular",
	"Ubuntu-R",
	"FreeSans",
}

@(private)
SANS_MEDIUM_CANDIDATES := [?]string {
	"Inter-Medium",
	"Inter_18pt-Medium",
	"Geist-500",
	"SourceSans3-Medium",
	"NotoSans-Medium",
	"Roboto-Medium",
	"DejaVuSans",
}

@(private)
SANS_SEMIBOLD_CANDIDATES := [?]string {
	"Inter-SemiBold",
	"Inter_18pt-SemiBold",
	"Geist-600",
	"SourceSans3-SemiBold",
	"NotoSans-SemiBold",
	"Roboto-Medium",
	"DejaVuSans-Bold",
}

@(private)
SANS_BOLD_CANDIDATES := [?]string {
	"Inter-Bold",
	"Inter_18pt-Bold",
	"SourceSans3-Bold",
	"Cantarell-Bold",
	"DejaVuSans-Bold",
	"NotoSans-Bold",
	"Roboto-Bold",
	"LiberationSans-Bold",
	"Ubuntu-B",
	"FreeSansBold",
}

@(private)
MONO_CANDIDATES := [?]string {
	"JetBrainsMono-Regular",
	"JetBrainsMonoNerdFont-Regular",
	"FiraCode-Regular",
	"Hack-Regular",
	"DejaVuSansMono",
	"LiberationMono-Regular",
	"NotoSansMono-Regular",
	"UbuntuMono-R",
}

@(private)
MONO_BOLD_CANDIDATES := [?]string {
	"JetBrainsMono-Bold",
	"JetBrainsMonoNerdFont-Bold",
	"FiraCode-Bold",
	"Hack-Bold",
	"DejaVuSansMono-Bold",
	"LiberationMono-Bold",
	"NotoSansMono-Bold",
	"UbuntuMono-B",
}

fonts_init :: proc(f: ^Fonts) {
	f.glyphs = make(map[Glyph_Key]Glyph)

	files := scan_font_files()
	defer {
		for p in files {
			delete(p)
		}
		delete(files)
	}

	load_env :: proc(f: ^Fonts, fam: Font_Family, wt: Font_Weight, env: string) -> bool {
		path := os.get_env(env, context.temp_allocator)
		if path == "" {
			return false
		}
		return face_load(&f.faces[fam][wt], path)
	}

	if !load_env(f, .Sans, .Regular, "PALMY_FONT") {
		pick_face(&f.faces[.Sans][.Regular], files, SANS_CANDIDATES[:])
	}
	if !load_env(f, .Sans, .Medium, "PALMY_FONT_MEDIUM") {
		pick_face(&f.faces[.Sans][.Medium], files, SANS_MEDIUM_CANDIDATES[:])
	}
	if !load_env(f, .Sans, .Semibold, "PALMY_FONT_SEMIBOLD") {
		pick_face(&f.faces[.Sans][.Semibold], files, SANS_SEMIBOLD_CANDIDATES[:])
	}
	if !load_env(f, .Sans, .Bold, "PALMY_FONT_BOLD") {
		pick_face(&f.faces[.Sans][.Bold], files, SANS_BOLD_CANDIDATES[:])
	}
	if !load_env(f, .Mono, .Regular, "PALMY_FONT_MONO") {
		pick_face(&f.faces[.Mono][.Regular], files, MONO_CANDIDATES[:])
	}
	pick_face(&f.faces[.Mono][.Bold], files, MONO_BOLD_CANDIDATES[:])

	fill_weight_gaps(f)
	f.any = f.faces[.Sans][.Regular].ok
}

// fill_weight_gaps resolves every empty slot to the nearest available weight,
// synthesising bold only as a last resort.
@(private)
fill_weight_gaps :: proc(f: ^Fonts) {
	// Mono falls back to sans before anything else.
	for wt in Font_Weight {
		if !f.faces[.Mono][wt].ok && f.faces[.Sans][wt].ok {
			f.faces[.Mono][wt] = f.faces[.Sans][wt]
		}
	}

	for fam in Font_Family {
		// Preference order for each missing weight, nearest first.
		order := [Font_Weight][]Font_Weight {
			.Regular  = {.Medium, .Semibold, .Bold},
			.Medium   = {.Regular, .Semibold, .Bold},
			.Semibold = {.Bold, .Medium, .Regular},
			.Bold     = {.Semibold, .Medium, .Regular},
		}
		for wt in Font_Weight {
			if f.faces[fam][wt].ok {
				continue
			}
			for alt in order[wt] {
				if f.faces[fam][alt].ok {
					f.faces[fam][wt] = f.faces[fam][alt]
					// Only fake weight when stepping up from a lighter face.
					f.faces[fam][wt].synth_bold = wt > alt && (wt == .Bold || wt == .Semibold)
					break
				}
			}
		}
	}
}

// load_font pins one font file to a family and weight, overriding discovery.
// The parity renderer uses it to load exactly the files the browser loads.
load_font :: proc(f: ^Fonts, path: string, fam: Font_Family, wt: Font_Weight) -> bool {
	face: Face
	if !face_load(&face, path) {
		return false
	}
	f.faces[fam][wt] = face
	f.any = true
	return true
}

fonts_destroy :: proc(f: ^Fonts) {
	for _, g in f.glyphs {
		delete(g.mask)
	}
	delete(f.glyphs)

	// Faces can alias each other, so free each distinct data block once.
	freed: [dynamic][]u8
	defer delete(freed)
	for fam in Font_Family {
		for wt in Font_Weight {
			face := &f.faces[fam][wt]
			if face.data == nil {
				continue
			}
			seen := false
			for d in freed {
				if raw_data(d) == raw_data(face.data) {
					seen = true
					break
				}
			}
			if !seen {
				append(&freed, face.data)
				delete(face.data)
				delete(face.path)
			}
			face.data = nil
		}
	}
}

@(private)
font_dirs :: proc() -> []string {
	home := os.get_env("HOME", context.temp_allocator)
	dirs := make([dynamic]string, context.temp_allocator)
	append(&dirs, "/usr/share/fonts", "/usr/local/share/fonts", "/run/current-system/sw/share/X11/fonts")
	if home != "" {
		append(&dirs, fmt.tprintf("%s/.local/share/fonts", home), fmt.tprintf("%s/.fonts", home))
	}
	return dirs[:]
}

// scan_font_files walks the usual font directories, a few levels deep.
@(private)
scan_font_files :: proc() -> [dynamic]string {
	out := make([dynamic]string)
	walk :: proc(dir: string, depth: int, out: ^[dynamic]string) {
		if depth > 4 {
			return
		}
		handle, err := os.open(dir)
		if err != nil {
			return
		}
		defer os.close(handle)
		entries, rerr := os.read_dir(handle, -1, context.temp_allocator)
		if rerr != nil {
			return
		}
		for e in entries {
			if e.type == .Directory {
				walk(e.fullpath, depth + 1, out)
				continue
			}
			ext := strings.to_lower(filepath.ext(e.name), context.temp_allocator)
			if ext == ".ttf" || ext == ".otf" {
				append(out, strings.clone(e.fullpath))
			}
		}
	}
	for d in font_dirs() {
		walk(d, 0, &out)
	}
	return out
}

@(private)
pick_face :: proc(face: ^Face, files: [dynamic]string, candidates: []string) {
	// Exact stem match in candidate order, so preference is respected.
	for want in candidates {
		for path in files {
			stem := filepath.stem(path)
			if stem == want {
				if face_load(face, path) {
					return
				}
			}
		}
	}
	// Then a looser match on the stem.
	for want in candidates {
		for path in files {
			if strings.contains(filepath.stem(path), want) {
				if face_load(face, path) {
					return
				}
			}
		}
	}
}

@(private)
face_load :: proc(face: ^Face, path: string) -> bool {
	data, rerr := os.read_entire_file_from_path(path, context.allocator)
	if rerr != nil {
		return false
	}
	if !tt.InitFont(&face.info, raw_data(data), 0) {
		delete(data)
		return false
	}
	face.data = data
	face.path = strings.clone(path)
	face.ok = true
	return true
}

// font_path reports which file backs a family and weight, for diagnostics.
font_path :: proc(f: ^Fonts, fam: Font_Family, wt: Font_Weight) -> string {
	return f.faces[fam][wt].path
}

@(private)
face_scale :: proc(face: ^Face, size: f32) -> f32 {
	return tt.ScaleForMappingEmToPixels(&face.info, size)
}

// font_metrics returns the ascent, descent and natural line height in pixels.
font_metrics :: proc(f: ^Fonts, size: f32, fam := Font_Family.Sans, wt := Font_Weight.Regular) -> Metrics {
	face := &f.faces[fam][wt]
	if !face.ok {
		return {ascent = size * 0.75, descent = size * 0.25, line = size * 1.4}
	}
	a, d, g: i32
	tt.GetFontVMetrics(&face.info, &a, &d, &g)
	s := face_scale(face, size)
	return {ascent = f32(a) * s, descent = f32(-d) * s, line = f32(a - d + g) * s}
}

@(private)
glyph_for :: proc(f: ^Fonts, cp: rune, size: f32, fam: Font_Family, wt: Font_Weight, phase: u8 = 0) -> ^Glyph {
	key := Glyph_Key {
		family = fam,
		weight = wt,
		size_q = u16(clamp(size * SIZE_STEPS + 0.5, 1, 65535)),
		phase  = phase % SUBPIXEL_PHASES,
		cp     = cp,
	}
	if g, found := &f.glyphs[key]; found {
		return g
	}

	face := &f.faces[fam][wt]
	g: Glyph
	if face.ok {
		exact := f32(key.size_q) / SIZE_STEPS
		s := face_scale(face, exact)
		adv, lsb: i32
		tt.GetCodepointHMetrics(&face.info, cp, &adv, &lsb)
		g.advance = f32(adv) * s

		shift := f32(key.phase) / SUBPIXEL_PHASES

		x0, y0, x1, y1: i32
		tt.GetCodepointBitmapBoxSubpixel(&face.info, cp, s, s, shift, 0, &x0, &y0, &x1, &y1)
		g.w, g.h = int(x1 - x0), int(y1 - y0)
		g.xoff, g.yoff = int(x0), int(y0)
		if g.w > 0 && g.h > 0 {
			g.mask = make([]u8, g.w * g.h)
			tt.MakeCodepointBitmapSubpixel(
				&face.info,
				raw_data(g.mask),
				i32(g.w),
				i32(g.h),
				i32(g.w),
				s,
				s,
				shift,
				0,
				cp,
			)
		}
	}

	f.glyphs[key] = g
	return &f.glyphs[key]
}

// text_width measures a single line of text in pixels.
text_width :: proc(f: ^Fonts, text: string, size: f32, fam := Font_Family.Sans, wt := Font_Weight.Regular, tracking: f32 = 0) -> f32 {
	face := &f.faces[fam][wt]
	if !face.ok {
		return f32(ef.width(text)) * fallback_scale(size) + f32(len(text)) * tracking
	}
	s := face_scale(face, size)
	total := f32(0)
	prev := rune(0)
	for r in text {
		adv, lsb: i32
		tt.GetCodepointHMetrics(&face.info, r, &adv, &lsb)
		total += f32(adv) * s
		if prev != 0 && !f.no_kerning {
			total += f32(tt.GetCodepointKernAdvance(&face.info, prev, r)) * s
		}
		total += tracking
		prev = r
	}
	if face.synth_bold {
		total += size * 0.02
	}
	return total
}

@(private)
fallback_scale :: proc(size: f32) -> f32 {
	return size / 10
}

// draw_text draws one line with its baseline at `y`, returning the advance.
draw_text :: proc(
	c: ^Canvas,
	f: ^Fonts,
	text: string,
	x, y: f32,
	size: f32,
	col: Color,
	fam := Font_Family.Sans,
	wt := Font_Weight.Regular,
	tracking: f32 = 0,
) -> f32 {
	face := &f.faces[fam][wt]
	if !face.ok {
		return draw_text_fallback(c, text, x, y, size, col)
	}

	face_s := face_scale(face, size)
	pen := x
	prev := rune(0)

	for r in text {
		if prev != 0 && !f.no_kerning {
			pen += f32(tt.GetCodepointKernAdvance(&face.info, prev, r)) * face_s
		}

		// Split the pen into a whole pixel and a subpixel phase.
		base := math.floor(pen)
		frac := pen - base
		phase := u8(clamp(frac * SUBPIXEL_PHASES, 0, SUBPIXEL_PHASES - 1))

		g := glyph_for(f, r, size, fam, wt, phase)
		if g.mask != nil {
			px := int(base) + g.xoff
			py := int(math.round(y)) + g.yoff
			blit_mask(c, px, py, g.mask, g.w, g.h, col)
			if face.synth_bold {
				// Emulate weight by overprinting one pixel to the right.
				blit_mask(c, px + 1, py, g.mask, g.w, g.h, col)
			}
		}
		pen += g.advance + tracking
		prev = r
	}
	return pen - x
}

// draw_text_fallback renders with the built-in vector-segment font, used only
// when no font file could be found on the system.
@(private)
draw_text_fallback :: proc(c: ^Canvas, text: string, x, y, size: f32, col: Color) -> f32 {
	quads: [4096]ef.Quad = ---
	s := fallback_scale(size)
	n := ef.print_quad_buffer(0, 0, text, {col.r, col.g, col.b, col.a}, quads[:], s)
	top := y - 7 * s
	for q in quads[:n] {
		tl := q.tl.v
		br := q.br.v
		fill_rect(c, {x + tl.x, top + tl.y, max(br.x - tl.x, 1), max(br.y - tl.y, 1)}, col)
	}
	return f32(ef.width(text)) * s
}

// text_index_at maps a pixel offset back to a byte index in the string — which
// is what every text cursor needs: clicking into a paragraph, dragging a
// selection, or deciding where a caret lands after a vertical move.
//
// The returned index is always on a rune boundary, and is the *nearest*
// boundary to `x` rather than the one before it, so clicking the right half of
// a character puts the caret after it.
text_index_at :: proc(
	f: ^Fonts,
	text: string,
	size: f32,
	x: f32,
	fam := Font_Family.Sans,
	wt := Font_Weight.Regular,
	tracking: f32 = 0,
) -> int {
	if x <= 0 || len(text) == 0 {
		return 0
	}

	face := &f.faces[fam][wt]
	if !face.ok {
		// Fallback metrics: the built-in font is fixed-advance enough that
		// proportional placement would be a lie.
		adv := fallback_scale(size) * 6
		if adv <= 0 {
			return 0
		}
		idx := int(x / adv + 0.5)
		return clamp(idx, 0, len(text))
	}

	s := face_scale(face, size)
	pen := f32(0)
	prev := rune(0)
	last_index := 0

	for r, i in text {
		adv, lsb: i32
		tt.GetCodepointHMetrics(&face.info, r, &adv, &lsb)
		step := f32(adv) * s + tracking
		if prev != 0 && !f.no_kerning {
			step += f32(tt.GetCodepointKernAdvance(&face.info, prev, r)) * s
		}

		// Past the midpoint of this glyph the caret belongs after it.
		if x < pen + step/2 {
			return i
		}
		pen += step
		prev = r
		last_index = i + rune_len(r)
	}
	return last_index
}

@(private)
rune_len :: proc(r: rune) -> int {
	switch {
	case r < 0x80:
		return 1
	case r < 0x800:
		return 2
	case r < 0x10000:
		return 3
	}
	return 4
}

// text_width_upto measures the string up to a byte index, which is where a
// caret at that index sits. Pair it with `text_index_at` for round trips.
text_width_upto :: proc(
	f: ^Fonts,
	text: string,
	index: int,
	size: f32,
	fam := Font_Family.Sans,
	wt := Font_Weight.Regular,
	tracking: f32 = 0,
) -> f32 {
	i := clamp(index, 0, len(text))
	return text_width(f, text[:i], size, fam, wt, tracking)
}
