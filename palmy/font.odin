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

// Font_Slant is the second axis of a face, and it is not a weight. Emphasis in
// running text — markdown `*emphasis*`, a Quote block, an italic spreadsheet
// cell — is a slant; rendering it as semibold upright is the wrong glyphs, and
// parking a real italic file in an unused `Mono/Medium` slot is a workaround
// for a missing axis rather than a design.
Font_Slant :: enum u8 {
	Upright,
	Italic,
}

@(private)
Face :: struct {
	data:       []u8,
	info:       tt.fontinfo,
	ok:         bool,
	synth_bold: bool,
	// synth_oblique marks a face that is *not* italic: it is the upright face,
	// and the glyph cache shears its coverage mask to fake a slant. It is only
	// ever set when the family has no real italic file at any weight — a real
	// italic at a neighbouring weight always wins, because a sheared upright is
	// a transform of the wrong outlines and looks it (`a` never becomes `a`,
	// the stems stay the wrong thickness, and the sidebearings are off).
	synth_oblique: bool,
	path:       string,
}

@(private)
Glyph_Key :: struct {
	family: Font_Family,
	weight: Font_Weight,
	slant:  Font_Slant,
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

// OBLIQUE_SKEW is the shear used when a family has no italic file at all. It
// is Skia's fake-italic skew, so synthesised emphasis leans by the same amount
// a browser's does.
OBLIQUE_SKEW :: f32(0.25)

@(private)
Glyph :: struct {
	mask:    []u8,
	w, h:    int,
	xoff:    int,
	yoff:    int,
	advance: f32,
}

// Tab_Key keys the tabular-figure slot cache. The size is the exact f32, not
// the quantised one: the slot has to be the same number every procedure that
// measures or draws this run computes, and two sizes that quantise together
// would otherwise share one slot and disagree by a fraction of a pixel.
@(private)
Tab_Key :: struct {
	family: Font_Family,
	weight: Font_Weight,
	slant:  Font_Slant,
	size:   u32, // f32 bits
}

// Owned_Font is one font file read from disk. Faces alias these freely — six
// slots routinely point at one file — and an application may replace a face
// with `load_font` after discovery, so ownership lives here rather than in the
// faces, and `fonts_destroy` frees each block exactly once.
@(private)
Owned_Font :: struct {
	data: []u8,
	path: string,
}

// Fonts owns the loaded faces and a cache of rasterized glyphs, keyed by
// family, weight, slant, integer pixel size and codepoint.
Fonts :: struct {
	faces:  [Font_Family][Font_Weight][Font_Slant]Face,
	glyphs: map[Glyph_Key]Glyph,
	any:    bool,

	// Kerning is on by default because it is better typography. It can be
	// turned off to match a renderer that has it disabled — CSS
	// `font-kerning: none`, for instance.
	no_kerning: bool,

	// Faces consulted, in order, for a codepoint the chosen family does not
	// cover. A text face carries a few hundred glyphs; a CJK subject line, a
	// filename with a fullwidth colon or a stray arrow is outside all of them
	// and would otherwise render as .notdef boxes.
	fallbacks: [dynamic]Face,

	// Colour-bitmap emoji. No vector rasterizer can draw these, so they go
	// through a separate path — see emoji.odin.
	emoji: Emoji_Font,

	// Dilated copies of the glyph masks, for outlined text.
	outlines: map[Outline_Key]Glyph,

	// Widest-digit advance per (family, weight, slant, size).
	tab_slots: map[Tab_Key]f32,

	owned: [dynamic]Owned_Font,
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

// The italic halves of the lists above. `-Oblique` is the same axis under a
// different name: DejaVu, Cantarell and the URW families all spell it that way.
@(private)
SANS_ITALIC_CANDIDATES := [?]string {
	"Inter-Italic",
	"Inter_18pt-Italic",
	"InterVariable-Italic",
	"SourceSans3-It",
	"Cantarell-Oblique",
	"NotoSans-Italic",
	"DejaVuSans-Oblique",
	"Roboto-Italic",
	"LiberationSans-Italic",
	"Ubuntu-RI",
	"FreeSansOblique",
	"NimbusSans-Italic",
}

@(private)
SANS_MEDIUM_ITALIC_CANDIDATES := [?]string {
	"Inter-MediumItalic",
	"Inter_18pt-MediumItalic",
	"Geist-500-Italic",
	"SourceSans3-MediumIt",
	"NotoSans-MediumItalic",
	"Roboto-MediumItalic",
	"DejaVuSans-Oblique",
}

@(private)
SANS_SEMIBOLD_ITALIC_CANDIDATES := [?]string {
	"Inter-SemiBoldItalic",
	"Inter_18pt-SemiBoldItalic",
	"Geist-600-Italic",
	"SourceSans3-SemiBoldIt",
	"NotoSans-SemiBoldItalic",
	"DejaVuSans-BoldOblique",
}

@(private)
SANS_BOLD_ITALIC_CANDIDATES := [?]string {
	"Inter-BoldItalic",
	"Inter_18pt-BoldItalic",
	"SourceSans3-BoldIt",
	"NotoSans-BoldItalic",
	"DejaVuSans-BoldOblique",
	"Roboto-BoldItalic",
	"LiberationSans-BoldItalic",
	"Ubuntu-BI",
	"FreeSansBoldOblique",
}

@(private)
MONO_ITALIC_CANDIDATES := [?]string {
	"JetBrainsMono-Italic",
	"JetBrainsMonoNerdFont-Italic",
	"FiraCode-Italic",
	"Hack-Italic",
	"DejaVuSansMono-Oblique",
	"LiberationMono-Italic",
	"NotoSansMono-Italic",
	"UbuntuMono-RI",
}

@(private)
MONO_BOLD_ITALIC_CANDIDATES := [?]string {
	"JetBrainsMono-BoldItalic",
	"JetBrainsMonoNerdFont-BoldItalic",
	"Hack-BoldItalic",
	"DejaVuSansMono-BoldOblique",
	"LiberationMono-BoldItalic",
	"NotoSansMono-BoldItalic",
	"UbuntuMono-BI",
}

fonts_init :: proc(f: ^Fonts) {
	f.glyphs = make(map[Glyph_Key]Glyph)
	f.outlines = make(map[Outline_Key]Glyph)
	f.tab_slots = make(map[Tab_Key]f32)
	f.owned = make([dynamic]Owned_Font)

	files := scan_font_files()
	defer {
		for p in files {
			delete(p)
		}
		delete(files)
	}

	load_env :: proc(f: ^Fonts, fam: Font_Family, wt: Font_Weight, sl: Font_Slant, env: string) -> bool {
		path := os.get_env(env, context.temp_allocator)
		if path == "" {
			return false
		}
		return face_load(f, &f.faces[fam][wt][sl], path)
	}

	if !load_env(f, .Sans, .Regular, .Upright, "PALMY_FONT") {
		pick_face(f, &f.faces[.Sans][.Regular][.Upright], files, SANS_CANDIDATES[:])
	}
	if !load_env(f, .Sans, .Medium, .Upright, "PALMY_FONT_MEDIUM") {
		pick_face(f, &f.faces[.Sans][.Medium][.Upright], files, SANS_MEDIUM_CANDIDATES[:])
	}
	if !load_env(f, .Sans, .Semibold, .Upright, "PALMY_FONT_SEMIBOLD") {
		pick_face(f, &f.faces[.Sans][.Semibold][.Upright], files, SANS_SEMIBOLD_CANDIDATES[:])
	}
	if !load_env(f, .Sans, .Bold, .Upright, "PALMY_FONT_BOLD") {
		pick_face(f, &f.faces[.Sans][.Bold][.Upright], files, SANS_BOLD_CANDIDATES[:])
	}
	if !load_env(f, .Mono, .Regular, .Upright, "PALMY_FONT_MONO") {
		pick_face(f, &f.faces[.Mono][.Regular][.Upright], files, MONO_CANDIDATES[:])
	}
	pick_face(f, &f.faces[.Mono][.Bold][.Upright], files, MONO_BOLD_CANDIDATES[:])

	if !load_env(f, .Sans, .Regular, .Italic, "PALMY_FONT_ITALIC") {
		pick_face(f, &f.faces[.Sans][.Regular][.Italic], files, SANS_ITALIC_CANDIDATES[:])
	}
	if !load_env(f, .Sans, .Medium, .Italic, "PALMY_FONT_MEDIUM_ITALIC") {
		pick_face(f, &f.faces[.Sans][.Medium][.Italic], files, SANS_MEDIUM_ITALIC_CANDIDATES[:])
	}
	if !load_env(f, .Sans, .Semibold, .Italic, "PALMY_FONT_SEMIBOLD_ITALIC") {
		pick_face(f, &f.faces[.Sans][.Semibold][.Italic], files, SANS_SEMIBOLD_ITALIC_CANDIDATES[:])
	}
	if !load_env(f, .Sans, .Bold, .Italic, "PALMY_FONT_BOLD_ITALIC") {
		pick_face(f, &f.faces[.Sans][.Bold][.Italic], files, SANS_BOLD_ITALIC_CANDIDATES[:])
	}
	if !load_env(f, .Mono, .Regular, .Italic, "PALMY_FONT_MONO_ITALIC") {
		pick_face(f, &f.faces[.Mono][.Regular][.Italic], files, MONO_ITALIC_CANDIDATES[:])
	}
	pick_face(f, &f.faces[.Mono][.Bold][.Italic], files, MONO_BOLD_ITALIC_CANDIDATES[:])

	fill_weight_gaps(f)
	fill_slant_gaps(f)
	f.any = f.faces[.Sans][.Regular][.Upright].ok

	// Load every fallback that is present, not just the first: one family
	// rarely covers CJK and Arabic and arrows at once.
	f.fallbacks = make([dynamic]Face)
	for cand in FALLBACK_CANDIDATES {
		fb: Face
		pick_face(f, &fb, files, {cand})
		if !fb.ok {
			continue
		}
		// Only skip a file already in the chain. Deliberately NOT skipping one
		// that currently backs a primary face: an application replaces the
		// primaries after fonts_init -- kit.start swaps in Geist -- so a
		// fallback dropped because it matched the *system-picked* primary
		// leaves a hole once that primary is gone. That cost accented Greek
		// in the mail client, where DejaVuSans was both the initial primary
		// and the only face carrying those codepoints.
		dup := false
		for &have in f.fallbacks {
			if have.path == fb.path {
				dup = true
			}
		}
		if dup {
			continue
		}
		append(&f.fallbacks, fb)
	}

	// Emoji last, after every outline face: a codepoint with both a text and an
	// emoji presentation (☀, ✔, ➜) keeps its text glyph, which is what a
	// browser does without a variation selector asking otherwise.
	emoji_init(&f.emoji, files)
}

// fill_weight_gaps resolves every empty upright slot to the nearest available
// weight, synthesising bold only as a last resort.
@(private)
fill_weight_gaps :: proc(f: ^Fonts) {
	// Mono falls back to sans before anything else.
	for wt in Font_Weight {
		if !f.faces[.Mono][wt][.Upright].ok && f.faces[.Sans][wt][.Upright].ok {
			f.faces[.Mono][wt][.Upright] = f.faces[.Sans][wt][.Upright]
		}
	}

	for fam in Font_Family {
		// Preference order for each missing weight, nearest first.
		order := weight_order()
		for wt in Font_Weight {
			if f.faces[fam][wt][.Upright].ok {
				continue
			}
			for alt in order[wt] {
				if f.faces[fam][alt][.Upright].ok {
					f.faces[fam][wt][.Upright] = f.faces[fam][alt][.Upright]
					// Only fake weight when stepping up from a lighter face.
					f.faces[fam][wt][.Upright].synth_bold = wt > alt && (wt == .Bold || wt == .Semibold)
					break
				}
			}
		}
	}
}

@(private)
weight_order :: proc() -> [Font_Weight][]Font_Weight {
	return {
		.Regular  = {.Medium, .Semibold, .Bold},
		.Medium   = {.Regular, .Semibold, .Bold},
		.Semibold = {.Bold, .Medium, .Regular},
		.Bold     = {.Semibold, .Medium, .Regular},
	}
}

// fill_slant_gaps resolves the italic slots, and the order it tries things in
// is the whole point: a real italic face at a neighbouring weight beats a
// sheared upright at the exact weight, and an italic request never resolves to
// nothing — worst case it is the upright face, leaning.
@(private)
fill_slant_gaps :: proc(f: ^Fonts) {
	// Mono italic borrows sans italic before anything else, mirroring upright.
	for wt in Font_Weight {
		if !f.faces[.Mono][wt][.Italic].ok && f.faces[.Sans][wt][.Italic].ok {
			f.faces[.Mono][wt][.Italic] = f.faces[.Sans][wt][.Italic]
		}
	}

	order := weight_order()
	for fam in Font_Family {
		for wt in Font_Weight {
			if f.faces[fam][wt][.Italic].ok {
				continue
			}
			// 1. a real italic file at the nearest weight, faking weight the
			//    same way the upright plane does.
			real := false
			for alt in order[wt] {
				if f.faces[fam][alt][.Italic].ok {
					f.faces[fam][wt][.Italic] = f.faces[fam][alt][.Italic]
					f.faces[fam][wt][.Italic].synth_bold = wt > alt && (wt == .Bold || wt == .Semibold)
					real = true
					break
				}
			}
			if real {
				continue
			}
			// 2. last resort: the upright face, sheared by the glyph cache.
			//    This is a fake and is recorded as one; `font_is_synthetic`
			//    reports it so an application can say so in a font picker.
			up := f.faces[fam][wt][.Upright]
			if up.ok {
				f.faces[fam][wt][.Italic] = up
				f.faces[fam][wt][.Italic].synth_oblique = true
			}
		}
	}
}

// load_font pins one font file to a family, weight and slant, overriding
// discovery. The parity renderer uses it to load exactly the files the browser
// loads.
load_font :: proc(f: ^Fonts, path: string, fam: Font_Family, wt: Font_Weight, sl := Font_Slant.Upright) -> bool {
	face: Face
	if !face_load(f, &face, path) {
		return false
	}
	f.faces[fam][wt][sl] = face
	f.any = true
	return true
}

// use_synthetic_italic replaces a family/weight's italic slot with a sheared
// copy of its own upright face, discarding whatever real italic discovery
// found. An application that swaps its primaries for a family shipping no
// italic wants exactly this: a sheared Geist still reads as Geist, where a real
// Noto Sans Italic set beside Geist reads as a bug.
use_synthetic_italic :: proc(f: ^Fonts, fam: Font_Family, wt: Font_Weight) -> bool {
	up := f.faces[fam][wt][.Upright]
	if !up.ok {
		return false
	}
	f.faces[fam][wt][.Italic] = up
	f.faces[fam][wt][.Italic].synth_oblique = true
	return true
}

// font_is_synthetic reports whether a slot is being faked rather than loaded:
// a bold overprinted from a lighter face, or an italic sheared from upright.
font_is_synthetic :: proc(f: ^Fonts, fam: Font_Family, wt: Font_Weight, sl := Font_Slant.Upright) -> (bold, oblique: bool) {
	face := f.faces[fam][wt][sl]
	return face.synth_bold, face.synth_oblique
}

fonts_destroy :: proc(f: ^Fonts) {
	for _, g in f.glyphs {
		delete(g.mask)
	}
	delete(f.glyphs)
	for _, g in f.outlines {
		delete(g.mask)
	}
	delete(f.outlines)
	delete(f.tab_slots)

	// Faces and fallbacks only ever alias `owned`, so one pass frees
	// everything exactly once however many slots pointed at a file.
	for o in f.owned {
		delete(o.data)
		delete(o.path)
	}
	delete(f.owned)
	f.faces = {}
	delete(f.fallbacks)

	emoji_destroy(&f.emoji)
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
			// .ttc is a TrueType collection. It was excluded here, which meant
			// the only CJK font on a typical Linux install -- shipped solely as
			// NotoSansCJK-*.ttc -- was never even offered to the loader, and
			// every CJK string rendered as .notdef boxes. face_load resolves
			// the collection offset.
			if ext == ".ttf" || ext == ".otf" || ext == ".ttc" {
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
pick_face :: proc(f: ^Fonts, face: ^Face, files: [dynamic]string, candidates: []string) {
	// Exact stem match in candidate order, so preference is respected.
	for want in candidates {
		for path in files {
			stem := filepath.stem(path)
			if stem == want {
				if face_load(f, face, path) {
					return
				}
			}
		}
	}
	// Then a looser match on the stem.
	for want in candidates {
		for path in files {
			if strings.contains(filepath.stem(path), want) {
				if face_load(f, face, path) {
					return
				}
			}
		}
	}
}

// Fallback faces, most preferred first. These are broad-coverage families
// rather than text faces: what matters is that between them they cover the
// scripts a desktop actually meets. Emoji are deliberately absent -- the only
// emoji font usually installed is NotoColorEmoji, which is CBDT/CBLC colour
// bitmaps with no `glyf` table, so stb_truetype cannot rasterize it and it is
// loaded through the separate path in emoji.odin instead.
@(private)
FALLBACK_CANDIDATES := [?]string {
	"NotoSansCJK-Regular", // .ttc; needs the collection offset above
	"NotoSansCJKjp-Regular",
	"NotoSansCJKsc-Regular",
	"NotoSerifCJK-Regular",
	"NotoSansArabic-Regular",
	"NotoSansHebrew-Regular",
	"NotoSansThai-Regular",
	"NotoSansDevanagari-Regular",
	"NotoSansSymbols2-Regular",
	"NotoSansMath-Regular",
	"DejaVuSans", // arrows, box drawing, a lot of symbols
	"FreeSerif",
	"Symbola",
}

// load_fallback_font appends a face to the fallback chain. An application only
// needs this for a script the automatic scan did not find a font for; the
// chain is searched in the order faces are added.
load_fallback_font :: proc(f: ^Fonts, path: string) -> bool {
	face: Face
	if !face_load(f, &face, path) {
		return false
	}
	append(&f.fallbacks, face)
	return true
}

// Resolved says which rasterizer will draw a rune: a vector face, a colour
// bitmap from the emoji font, or nothing at all.
@(private)
Resolved :: struct {
	face:  ^Face,
	emoji: bool,
	blank: bool, // a default-ignorable: advances nothing, draws nothing
}

// resolve_rune picks what will actually draw `r`: the requested face when it
// has the glyph, then the fallback chain, then the colour-bitmap emoji font.
//
// Resolution is deterministic for a given codepoint, which is what lets the
// glyph cache stay keyed on (family, weight, slant, size, phase, codepoint)
// without recording which face served it.
@(private)
resolve_rune :: proc(
	f: ^Fonts,
	fam: Font_Family,
	wt: Font_Weight,
	sl: Font_Slant,
	r: rune,
	prefer_emoji := false,
) -> Resolved {
	face := &f.faces[fam][wt][sl]
	if is_ignorable(r) {
		return {face = face, blank = true}
	}
	// A codepoint whose Unicode default is the colour form, or one followed by
	// U+FE0F, goes to the emoji font ahead of everything else. Otherwise a
	// symbol fallback that happens to carry a line-art 👍 wins, and the result
	// is a black-and-white outline where the application asked for an emoji.
	if prefer_emoji && emoji_has(&f.emoji, r) {
		return {face = face, emoji = true}
	}
	if !face.ok {
		return {face = face}
	}
	if tt.FindGlyphIndex(&face.info, r) != 0 {
		return {face = face}
	}
	// A space is not in every face and does not need to be: it draws nothing,
	// and taking its advance from a fallback would change the metrics of text
	// that is otherwise entirely in the primary face.
	if r == ' ' || r == '\t' {
		return {face = face}
	}
	for &fb in f.fallbacks {
		if fb.ok && tt.FindGlyphIndex(&fb.info, r) != 0 {
			return {face = &fb}
		}
	}
	if emoji_has(&f.emoji, r) {
		return {face = face, emoji = true}
	}
	return {face = face}
}

// face_for_rune is resolve_rune without the emoji branch, kept for callers that
// only want a vector face.
@(private)
face_for_rune :: proc(f: ^Fonts, fam: Font_Family, wt: Font_Weight, r: rune, sl := Font_Slant.Upright) -> ^Face {
	return resolve_rune(f, fam, wt, sl, r).face
}

// is_ignorable covers the format controls that appear inside real strings and
// must not become tofu: zero-width joiners and the variation selectors that
// emoji sequences are glued together with, which palmy cannot shape but can at
// least decline to draw a box for.
@(private)
is_ignorable :: proc "contextless" (r: rune) -> bool {
	switch {
	case r >= 0x200b && r <= 0x200f: // ZWSP, ZWNJ, ZWJ, LRM, RLM
		return true
	case r == 0x2060, r == 0xfeff: // word joiner, BOM
		return true
	case r >= 0xfe00 && r <= 0xfe0f: // variation selectors 1-16
		return true
	}
	return false
}

@(private)
face_load :: proc(f: ^Fonts, face: ^Face, path: string) -> bool {
	data, rerr := os.read_entire_file_from_path(path, context.allocator)
	if rerr != nil {
		return false
	}
	// A TrueType *collection* (.ttc) packs several fonts into one file and
	// begins with a header rather than a font, so offset 0 is not a font and
	// InitFont refuses it. GetFontOffsetForIndex returns where font `index`
	// actually starts, and for a plain .ttf it returns 0 -- so this is right
	// for both. Without it the only CJK font on a typical Linux box,
	// NotoSansCJK-*.ttc, simply cannot be loaded.
	offset := tt.GetFontOffsetForIndex(raw_data(data), 0)
	if offset < 0 || !tt.InitFont(&face.info, raw_data(data), offset) {
		delete(data)
		return false
	}
	face.data = data
	face.path = strings.clone(path)
	face.ok = true
	append(&f.owned, Owned_Font{data = data, path = face.path})
	return true
}

// font_path reports which file backs a family, weight and slant.
font_path :: proc(f: ^Fonts, fam: Font_Family, wt: Font_Weight, sl := Font_Slant.Upright) -> string {
	return f.faces[fam][wt][sl].path
}

@(private)
face_scale :: proc(face: ^Face, size: f32) -> f32 {
	return tt.ScaleForMappingEmToPixels(&face.info, size)
}

// font_metrics returns the ascent, descent and natural line height in pixels.
font_metrics :: proc(
	f: ^Fonts,
	size: f32,
	fam := Font_Family.Sans,
	wt := Font_Weight.Regular,
	sl := Font_Slant.Upright,
) -> Metrics {
	face := &f.faces[fam][wt][sl]
	if !face.ok {
		return {ascent = size * 0.75, descent = size * 0.25, line = size * 1.4}
	}
	a, d, g: i32
	tt.GetFontVMetrics(&face.info, &a, &d, &g)
	s := face_scale(face, size)
	return {ascent = f32(a) * s, descent = f32(-d) * s, line = f32(a - d + g) * s}
}

@(private)
glyph_for :: proc(
	f: ^Fonts,
	cp: rune,
	size: f32,
	fam: Font_Family,
	wt: Font_Weight,
	phase: u8 = 0,
	sl := Font_Slant.Upright,
) -> ^Glyph {
	return glyph_for_key(f, glyph_key(cp, size, fam, wt, phase, sl))
}

@(private)
glyph_key :: proc(cp: rune, size: f32, fam: Font_Family, wt: Font_Weight, phase: u8, sl: Font_Slant) -> Glyph_Key {
	return Glyph_Key {
		family = fam,
		weight = wt,
		slant  = sl,
		size_q = u16(clamp(size * SIZE_STEPS + 0.5, 1, 65535)),
		phase  = phase % SUBPIXEL_PHASES,
		cp     = cp,
	}
}

@(private)
glyph_for_key :: proc(f: ^Fonts, key: Glyph_Key) -> ^Glyph {
	if g, found := &f.glyphs[key]; found {
		return g
	}

	rs := resolve_rune(f, key.family, key.weight, key.slant, key.cp)
	face := rs.face
	g: Glyph
	if face.ok && !rs.emoji && !rs.blank {
		exact := f32(key.size_q) / SIZE_STEPS
		s := face_scale(face, exact)
		adv, lsb: i32
		tt.GetCodepointHMetrics(&face.info, key.cp, &adv, &lsb)
		g.advance = f32(adv) * s

		shift := f32(key.phase) / SUBPIXEL_PHASES

		x0, y0, x1, y1: i32
		tt.GetCodepointBitmapBoxSubpixel(&face.info, key.cp, s, s, shift, 0, &x0, &y0, &x1, &y1)
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
				key.cp,
			)
		}
		// A family with no italic file at any weight gets its emphasis by
		// shearing the upright coverage mask. The advance is left alone, which
		// is what Skia does for fake italic, so measurement is unaffected.
		if face.synth_oblique && g.mask != nil {
			shear_glyph(&g, OBLIQUE_SKEW)
		}
	}

	f.glyphs[key] = g
	return &f.glyphs[key]
}

// shear_glyph leans a coverage mask to the right, horizontally resampling each
// row so the slant is subpixel-accurate rather than a staircase. The shift is
// proportional to the distance above the baseline, which for a mask row `ry` is
// `-(yoff + ry)` — yoff is negative above the baseline.
@(private)
shear_glyph :: proc(g: ^Glyph, skew: f32) {
	if g.mask == nil || g.w <= 0 || g.h <= 0 {
		return
	}
	shift_at :: proc(g: ^Glyph, ry: int, skew: f32) -> f32 {
		y := f32(g.yoff + ry) + 0.5
		return -y * skew
	}

	lo := shift_at(g, 0, skew)
	hi := lo
	for ry in 1 ..< g.h {
		s := shift_at(g, ry, skew)
		lo = min(lo, s)
		hi = max(hi, s)
	}
	pad_l := int(math.floor(lo))
	pad_r := int(math.ceil(hi))
	nw := g.w + (pad_r - pad_l) + 1
	if nw <= 0 {
		return
	}

	out := make([]u8, nw * g.h)
	for ry in 0 ..< g.h {
		dx := shift_at(g, ry, skew) - f32(pad_l)
		base := int(math.floor(dx))
		frac := dx - f32(base)
		src := g.mask[ry * g.w:][:g.w]
		dst := out[ry * nw:][:nw]
		for sx in 0 ..< g.w {
			v := f32(src[sx])
			a := v * (1 - frac)
			b := v * frac
			if i := sx + base; i >= 0 && i < nw {
				dst[i] = u8(min(255, f32(dst[i]) + a + 0.5))
			}
			if i := sx + base + 1; i >= 0 && i < nw {
				dst[i] = u8(min(255, f32(dst[i]) + b + 0.5))
			}
		}
	}

	delete(g.mask)
	g.mask = out
	g.xoff += pad_l
	g.w = nw
}

// ---------------------------------------------------------------------------
// Tabular figures
//
// `tabular-nums` asks for `font-variant-numeric: tabular-nums`, which selects
// the font's own `tnum` feature. stb_truetype has no GSUB, so there is no
// feature to select; what the feature does, though, is give every digit the
// same advance. Measuring the widest digit at this exact size and advancing all
// ten by it — each glyph centred in its slot — is the same arithmetic the font
// would have done, and it is what stops a running clock or a byte counter from
// jittering sideways as its digits change.
// ---------------------------------------------------------------------------

@(private)
DIGITS := [10]rune{'0', '1', '2', '3', '4', '5', '6', '7', '8', '9'}

@(private)
is_digit :: proc "contextless" (r: rune) -> bool {
	return r >= '0' && r <= '9'
}

// tabular_slot is the advance every digit gets: the widest of the ten at this
// size. Cached, because it is three dozen metric lookups and every measure and
// every draw of the same run needs the identical number.
@(private)
tabular_slot :: proc(f: ^Fonts, fam: Font_Family, wt: Font_Weight, sl: Font_Slant, size: f32) -> f32 {
	key := Tab_Key{family = fam, weight = wt, slant = sl, size = transmute(u32)size}
	if v, found := f.tab_slots[key]; found {
		return v
	}
	widest := f32(0)
	for d in DIGITS {
		rs := resolve_rune(f, fam, wt, sl, d)
		if !rs.face.ok || rs.emoji || rs.blank {
			continue
		}
		s := face_scale(rs.face, size)
		adv, lsb: i32
		tt.GetCodepointHMetrics(&rs.face.info, d, &adv, &lsb)
		widest = max(widest, f32(adv) * s)
	}
	f.tab_slots[key] = widest
	return widest
}

// text_width measures a single line of text in pixels.
text_width :: proc(
	f: ^Fonts,
	text: string,
	size: f32,
	fam := Font_Family.Sans,
	wt := Font_Weight.Regular,
	tracking: f32 = 0,
	sl := Font_Slant.Upright,
	tabular := false,
) -> f32 {
	face := &f.faces[fam][wt][sl]
	if !face.ok {
		return f32(ef.width(text)) * fallback_scale(size) + f32(len(text)) * tracking
	}
	slot := tabular ? tabular_slot(f, fam, wt, sl, size) : 0
	total := f32(0)
	prev := rune(0)
	prev_face: ^Face = nil
	for r, i in text {
		// Must resolve exactly as draw_text does, or measured width and drawn
		// width disagree and every caret, wrap point and centred label is off.
		rs := resolve_rune(f, fam, wt, sl, r, prefers_emoji(text, i, r))
		if rs.blank {
			prev, prev_face = 0, nil
			continue
		}
		if rs.emoji {
			total += emoji_advance(&f.emoji, r, size) + tracking
			prev, prev_face = 0, nil
			continue
		}
		rf := rs.face
		if tabular && is_digit(r) {
			total += slot + tracking
			prev, prev_face = r, rf
			continue
		}
		s := face_scale(rf, size)
		adv, lsb: i32
		tt.GetCodepointHMetrics(&rf.info, r, &adv, &lsb)
		total += f32(adv) * s
		if prev != 0 && !f.no_kerning && prev_face == rf && !(tabular && is_digit(prev)) {
			total += f32(tt.GetCodepointKernAdvance(&rf.info, prev, r)) * s
		}
		total += tracking
		prev = r
		prev_face = rf
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
	sl := Font_Slant.Upright,
	tabular := false,
	outline := Text_Outline{},
) -> f32 {
	face := &f.faces[fam][wt][sl]
	if !face.ok {
		return draw_text_fallback(c, text, x, y, size, col)
	}

	slot := tabular ? tabular_slot(f, fam, wt, sl, size) : 0
	stroke := outline.width > 0 && outline.color.a > 0
	pen := x
	prev := rune(0)
	prev_face: ^Face = nil

	for r, i in text {
		// Each rune is drawn by whichever face actually has it, so the scale
		// and the kern pair must both come from that face -- units per em
		// differ between families, and a kern pair only means anything when
		// both runes come from the same face.
		rs := resolve_rune(f, fam, wt, sl, r, prefers_emoji(text, i, r))
		if rs.blank {
			prev, prev_face = 0, nil
			continue
		}
		if rs.emoji {
			adv := emoji_advance(&f.emoji, r, size)
			emoji_draw(c, &f.emoji, r, pen, y, size, col.a)
			pen += adv + tracking
			prev, prev_face = 0, nil
			continue
		}

		rf := rs.face
		face_s := face_scale(rf, size)
		if prev != 0 && !f.no_kerning && prev_face == rf && !(tabular && (is_digit(prev) || is_digit(r))) {
			pen += f32(tt.GetCodepointKernAdvance(&rf.info, prev, r)) * face_s
		}

		// A tabular digit sits centred in its slot, which is where the font's
		// own `tnum` figures sit. The advance comes from the same `slot` the
		// measurement used, so the two cannot drift apart.
		gpen := pen
		step := f32(0)
		if tabular && is_digit(r) {
			adv, lsb: i32
			tt.GetCodepointHMetrics(&rf.info, r, &adv, &lsb)
			gpen = pen + (slot - f32(adv) * face_s) / 2
			step = slot
		}

		// Split the pen into a whole pixel and a subpixel phase.
		base := math.floor(gpen)
		frac := gpen - base
		phase := u8(clamp(frac * SUBPIXEL_PHASES, 0, SUBPIXEL_PHASES - 1))

		key := glyph_key(r, size, fam, wt, phase, sl)
		if stroke {
			o := outline_glyph_for(f, key, outline.width)^
			if o.mask != nil {
				ox := int(base) + o.xoff
				oy := int(math.round(y)) + o.yoff
				blit_mask(c, ox, oy, o.mask, o.w, o.h, outline.color)
				if rf.synth_bold {
					// The fill is overprinted a pixel right, so the stroke has
					// to be too or it stops short of the glyph on that side.
					blit_mask(c, ox + 1, oy, o.mask, o.w, o.h, outline.color)
				}
			}
		}
		g := glyph_for_key(f, key)^
		if g.mask != nil {
			px := int(base) + g.xoff
			py := int(math.round(y)) + g.yoff
			blit_mask(c, px, py, g.mask, g.w, g.h, col)
			if rf.synth_bold {
				// Emulate weight by overprinting one pixel to the right.
				blit_mask(c, px + 1, py, g.mask, g.w, g.h, col)
			}
		}
		pen += (step > 0 ? step : g.advance) + tracking
		prev = r
		prev_face = rf
	}
	// The same allowance text_width makes for an overprinted bold, so the
	// advance a caller gets back -- an underline's length, a caret's resting
	// place -- is the number the measurement already committed to.
	if face.synth_bold {
		pen += size * 0.02
	}
	return pen - x
}

// draw_text_outlined draws a line with a stroke around every glyph, which is
// what a subtitle needs to stay legible over any frame behind it.
//
// The stroke is the glyph's own coverage mask dilated by `width`, computed once
// per (glyph, size, width) and cached. Drawing the run eight times at offsets
// costs eight rasterisations and still leaves an octagonal halo at the joins;
// this costs one, and the join is round.
draw_text_outlined :: proc(
	c: ^Canvas,
	f: ^Fonts,
	text: string,
	x, y: f32,
	size: f32,
	col: Color,
	outline_col: Color,
	outline_w: f32,
	fam := Font_Family.Sans,
	wt := Font_Weight.Regular,
	tracking: f32 = 0,
	sl := Font_Slant.Upright,
	tabular := false,
) -> f32 {
	return draw_text(
		c, f, text, x, y, size, col, fam, wt, tracking, sl, tabular,
		Text_Outline{width = outline_w, color = outline_col},
	)
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
	sl := Font_Slant.Upright,
	tabular := false,
) -> int {
	if x <= 0 || len(text) == 0 {
		return 0
	}

	face := &f.faces[fam][wt][sl]
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

	slot := tabular ? tabular_slot(f, fam, wt, sl, size) : 0
	pen := f32(0)
	prev := rune(0)
	prev_face: ^Face = nil
	last_index := 0

	for r, i in text {
		rs := resolve_rune(f, fam, wt, sl, r, prefers_emoji(text, i, r))
		step := f32(0)
		switch {
		case rs.blank:
			step = 0
		case rs.emoji:
			step = emoji_advance(&f.emoji, r, size) + tracking
		case tabular && is_digit(r):
			step = slot + tracking
		case:
			rf := rs.face
			s := face_scale(rf, size)
			adv, lsb: i32
			tt.GetCodepointHMetrics(&rf.info, r, &adv, &lsb)
			step = f32(adv) * s + tracking
			if prev != 0 && !f.no_kerning && prev_face == rf && !(tabular && is_digit(prev)) {
				step += f32(tt.GetCodepointKernAdvance(&rf.info, prev, r)) * s
			}
		}

		// Past the midpoint of this glyph the caret belongs after it.
		if x < pen + step/2 {
			return i
		}
		pen += step
		if rs.blank || rs.emoji {
			prev, prev_face = 0, nil
		} else {
			prev, prev_face = r, rs.face
		}
		last_index = i + rune_len(r)
	}
	return last_index
}

@(private)
rune_len :: proc "contextless" (r: rune) -> int {
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
	sl := Font_Slant.Upright,
	tabular := false,
) -> f32 {
	i := clamp(index, 0, len(text))
	return text_width(f, text[:i], size, fam, wt, tracking, sl, tabular)
}
